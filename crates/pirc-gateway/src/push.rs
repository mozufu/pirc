//! Push notifications to browsers and phones
//! (`apps/gateway/src/daemon/push.ts`, `push-routes.ts`): Web Push to
//! browsers, and the same protocol to phones through UnifiedPush. Payloads
//! are encrypted for the subscriber (RFC 8291, `aes128gcm`) and signed with
//! the gateway's VAPID key (RFC 8292), as the `web-push` library did, so the
//! push service relays them without reading them. They still say little: a
//! title, a short line and where to open, never an agent's answer.

use std::collections::BTreeMap;
use std::fs;
use std::io::Write;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use aes_gcm::aead::Aead;
use aes_gcm::{Aes128Gcm, KeyInit, Nonce};
use axum::Router;
use axum::extract::{Extension, State};
use axum::routing::{get, post};
use base64::Engine;
use base64::engine::DecodePaddingMode;
use base64::engine::general_purpose::{GeneralPurpose, GeneralPurposeConfig, URL_SAFE_NO_PAD};
use hkdf::Hkdf;
use p256::ecdsa::signature::Signer;
use p256::ecdsa::{Signature, SigningKey};
use p256::elliptic_curve::sec1::ToEncodedPoint;
use p256::{PublicKey, SecretKey};
use pirc_config::Env;
use pirc_config::text::is_space as js_space;
use rusqlite::{OptionalExtension, Row, params};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::Sha256;
use url::Url;

use crate::app::{App, AppState, ReqBody};
use crate::auth::Identity;
use crate::db::Db;
use crate::error::{ApiError, ApiResult, json_response};
use crate::http::{no_content, ok};
use crate::routes::Handled;
use crate::util::{new_id, now_ms, present, random_bytes};

mod interactions;
mod preferences;
mod summary;

#[cfg(not(test))]
use interactions::watch_interactions;
pub use interactions::{answered_by, single_choices};
#[cfg(test)]
use interactions::{answered_message, hex_utf8, waiting_message, watch_interactions};

pub use preferences::{Category, Decision, Level, LockScreen, Preferences};

/// One notification (`PushMessage`): `target` is what it opens:
/// `{sessionId}`, `{schedules: true, scheduleId?, runId?}`, `{calendar: true, …}`,
/// `{potId, threadId}`, `{activityNotificationId}`, `{approvalId}` or
/// `{budgetRequestId}`.
#[derive(Clone, Debug)]
pub struct PushMessage {
    pub title: String,
    pub body: String,
    /// Notifications with the same tag replace each other on the device.
    pub tag: String,
    pub target: Value,
    /// Every sender names its category; each target's preferences decide
    /// what happens with it. Only the test notification has none.
    pub category: Option<Category>,
    /// Exact question metadata for create/revoke pushes. Refresh hints omit the tuple.
    pub interaction: Option<InteractionPush>,
}

#[derive(Clone, Debug, Default)]
pub struct InteractionPush {
    pub kind: &'static str,
    pub session_id: String,
    pub interaction_id: Option<String>,
    pub interaction_epoch: Option<String>,
    /// When the question stops taking answers.
    pub expires_at: Option<i64>,
    /// The options of a single-choice question with at most 3 of them.
    pub choices: Vec<Choice>,
    /// Who answered (`{deviceName, at}`), on `interaction_answered`.
    pub answered_by: Option<Value>,
}

/// An option a notification can answer with: `id` is the answer's value.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Choice {
    pub id: String,
    pub label: String,
}

/// How one target gets a notification.
#[derive(Clone, Copy, Debug, Default)]
struct Delivery {
    silent: bool,
    lock_screen: Option<LockScreen>,
}

/// A push service's answer before giving up on it for this message.
const SEND_TIMEOUT: Duration = Duration::from_secs(10);
/// How long a push service keeps an undelivered message (a phone offline for a while).
const TTL_SECONDS: u32 = 24 * 3600;
/// Consecutive failures after which a subscription is dropped.
const MAX_FAILURES: i64 = 20;
/// `web-push`'s VAPID JWT lifetime (12 hours).
const VAPID_EXPIRATION_SECONDS: i64 = 12 * 60 * 60;
/// `http_ece`'s record size; payloads are far smaller, so one record.
const RECORD_SIZE: usize = 4096;
/// Per record: the delimiter byte and the AES-GCM tag.
const RECORD_OVERHEAD: usize = 1 + 16;
/// The endpoints `web-push` sends GCM's own authorization to (never VAPID).
const GCM_ENDPOINT: &str = "https://android.googleapis.com/gcm/send";

// ---------------------------------------------------------------------------
// VAPID keys

/// The gateway's VAPID key pair, URL-safe base64 without padding: the
/// uncompressed P-256 public point (65 bytes) and the private scalar (32).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VapidKeys {
    pub public_key: String,
    pub private_key: String,
}

/// A fresh key pair (`webpush.generateVAPIDKeys`).
pub fn generate_vapid_keys() -> VapidKeys {
    let secret = loop {
        if let Ok(secret) = SecretKey::from_slice(&random_bytes::<32>()) {
            break secret;
        }
    };
    VapidKeys {
        public_key: URL_SAFE_NO_PAD.encode(secret.public_key().to_encoded_point(false).as_bytes()),
        private_key: URL_SAFE_NO_PAD.encode(secret.to_bytes()),
    }
}

/// The gateway's VAPID key pair (`loadVapidKeys`): from
/// `PIRC_VAPID_PUBLIC_KEY` and `PIRC_VAPID_PRIVATE_KEY`, else made once and
/// kept in `<stateDir>/vapid.json`. A new key pair invalidates every
/// subscription, so it must outlive restarts.
pub fn load_vapid_keys(state_dir: &Path, env: &Env) -> Result<VapidKeys, String> {
    let var = |name: &str| {
        env.get(name)
            .map(|value| value.trim_matches(js_space))
            .filter(|value| !value.is_empty())
    };
    let public_key = var("PIRC_VAPID_PUBLIC_KEY");
    let private_key = var("PIRC_VAPID_PRIVATE_KEY");
    if public_key.is_some() || private_key.is_some() {
        let (Some(public_key), Some(private_key)) = (public_key, private_key) else {
            return Err(
                "Set both PIRC_VAPID_PUBLIC_KEY and PIRC_VAPID_PRIVATE_KEY, or neither".into(),
            );
        };
        return Ok(VapidKeys {
            public_key: public_key.to_owned(),
            private_key: private_key.to_owned(),
        });
    }
    let file = state_dir.join("vapid.json");
    if file.exists() {
        let text = fs::read_to_string(&file)
            .map_err(|error| format!("cannot read {}: {error}", file.display()))?;
        let stored: Value = serde_json::from_str(&text)
            .map_err(|error| format!("{} is not JSON: {error}", file.display()))?;
        let field = |name: &str| {
            stored
                .get(name)
                .and_then(Value::as_str)
                .filter(|value| !value.is_empty())
                .map(str::to_owned)
        };
        return match (field("publicKey"), field("privateKey")) {
            (Some(public_key), Some(private_key)) => Ok(VapidKeys {
                public_key,
                private_key,
            }),
            _ => Err(format!("{} holds no VAPID key pair", file.display())),
        };
    }
    let keys = generate_vapid_keys();
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(state_dir)
        .map_err(|error| format!("cannot create {}: {error}", state_dir.display()))?;
    let mut out = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&file)
        .map_err(|error| format!("cannot create {}: {error}", file.display()))?;
    out.write_all(serde_json::to_string(&keys).unwrap_or_default().as_bytes())
        .map_err(|error| format!("cannot write {}: {error}", file.display()))?;
    Ok(keys)
}

// ---------------------------------------------------------------------------
// Web Push (what `web-push`'s `generateRequestDetails` and `http_ece` did)

/// `Buffer.from(text, 'base64url')`: either alphabet's padding, trailing
/// bits and a dangling last character are tolerated.
fn decode_base64url(text: &str) -> Result<Vec<u8>, String> {
    const LENIENT: GeneralPurpose = GeneralPurpose::new(
        &base64::alphabet::URL_SAFE,
        GeneralPurposeConfig::new()
            .with_decode_allow_trailing_bits(true)
            .with_decode_padding_mode(DecodePaddingMode::Indifferent),
    );
    let mut text = text
        .trim_end_matches('=')
        .replace('+', "-")
        .replace('/', "_");
    if text.len() % 4 == 1 {
        text.pop();
    }
    LENIENT
        .decode(text)
        .map_err(|error| format!("invalid base64: {error}"))
}

/// `urlBase64Helper.validate`.
fn is_url_base64(text: &str) -> bool {
    !text.is_empty()
        && text
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

/// `info` for the key derivation of RFC 8291 section 3.4.
fn webpush_info(ua_public: &[u8], as_public: &[u8]) -> Vec<u8> {
    let mut info = b"WebPush: info\0".to_vec();
    info.extend_from_slice(ua_public);
    info.extend_from_slice(as_public);
    info
}

/// The content encryption key and nonce of an `aes128gcm` message (RFC 8188).
fn content_key(ikm: &[u8], salt: &[u8]) -> ([u8; 16], [u8; 12]) {
    let prk = Hkdf::<Sha256>::new(Some(salt), ikm);
    let mut key = [0; 16];
    let mut nonce = [0; 12];
    prk.expand(b"Content-Encoding: aes128gcm\0", &mut key)
        .expect("16 bytes is a valid HKDF length");
    prk.expand(b"Content-Encoding: nonce\0", &mut nonce)
        .expect("12 bytes is a valid HKDF length");
    (key, nonce)
}

/// The nonce of record `counter`: the base nonce XOR the counter.
fn record_nonce(base: &[u8; 12], counter: u64) -> [u8; 12] {
    let mut nonce = *base;
    for (byte, counter_byte) in nonce[4..].iter_mut().zip(counter.to_be_bytes()) {
        *byte ^= counter_byte;
    }
    nonce
}

/// RFC 8291 encryption of `plaintext` for the subscriber's `p256dh` key
/// and `auth` secret, from `local` (the ephemeral key) with `salt`: the
/// `aes128gcm` header (salt, record size, key id = `local`'s public key)
/// and records of 4096 bytes, no padding.
pub fn encrypt(
    ua_public: &[u8],
    auth: &[u8],
    plaintext: &[u8],
    salt: &[u8; 16],
    local: &SecretKey,
) -> Result<Vec<u8>, String> {
    let ua = PublicKey::from_sec1_bytes(ua_public)
        .map_err(|_| "The subscription p256dh value is not a P-256 public key".to_owned())?;
    let shared = p256::ecdh::diffie_hellman(local.to_nonzero_scalar(), ua.as_affine());
    let local_public = local.public_key().to_encoded_point(false);
    let mut ikm = [0; 32];
    Hkdf::<Sha256>::new(Some(auth), shared.raw_secret_bytes())
        .expand(&webpush_info(ua_public, local_public.as_bytes()), &mut ikm)
        .expect("32 bytes is a valid HKDF length");
    let (key, base_nonce) = content_key(&ikm, salt);
    let cipher = Aes128Gcm::new(&key.into());

    let mut out = Vec::with_capacity(86 + plaintext.len() + RECORD_OVERHEAD);
    out.extend_from_slice(salt);
    out.extend_from_slice(&(RECORD_SIZE as u32).to_be_bytes());
    out.push(local_public.as_bytes().len() as u8);
    out.extend_from_slice(local_public.as_bytes());
    let chunk = RECORD_SIZE - RECORD_OVERHEAD;
    let mut start = 0;
    let mut counter = 0;
    loop {
        let end = start + chunk;
        let last = end >= plaintext.len();
        let mut record = plaintext[start..end.min(plaintext.len())].to_vec();
        record.push(if last { 2 } else { 1 });
        let nonce = record_nonce(&base_nonce, counter);
        let sealed = cipher
            .encrypt(Nonce::from_slice(&nonce), record.as_slice())
            .map_err(|_| "encryption failed".to_owned())?;
        out.extend_from_slice(&sealed);
        if last {
            return Ok(out);
        }
        start = end;
        counter += 1;
    }
}

/// `encryptionHelper.encrypt` with a new ephemeral key and salt.
fn encrypt_for(p256dh: &str, auth: &str, payload: &str) -> Result<Vec<u8>, String> {
    let ua_public = decode_base64url(p256dh)?;
    if ua_public.len() != 65 {
        return Err("The subscription p256dh value should be 65 bytes long.".into());
    }
    let auth = decode_base64url(auth)?;
    if auth.len() < 16 {
        return Err("The subscription auth key should be at least 16 bytes long".into());
    }
    let local = loop {
        if let Ok(secret) = SecretKey::from_slice(&random_bytes::<32>()) {
            break secret;
        }
    };
    encrypt(
        &ua_public,
        &auth,
        payload.as_bytes(),
        &random_bytes::<16>(),
        &local,
    )
}

/// The push service's origin as `web-push` wrote the JWT's `aud`:
/// `url.parse`'s protocol and host (an explicit port kept, even the default).
fn audience(endpoint: &str) -> Result<String, String> {
    let url =
        // The message names the host only: the endpoint is a capability URL.
        Url::parse(endpoint).map_err(|_| format!("VAPID audience is not a url. {}", host_of(endpoint)))?;
    let host = url.host_str().unwrap_or_default();
    let authority = endpoint
        .split_once("://")
        .map_or("", |(_, rest)| rest)
        .split(['/', '?', '#'])
        .next()
        .unwrap_or_default();
    let authority = authority
        .rsplit_once('@')
        .map_or(authority, |(_, host)| host);
    let after_host = authority
        .rfind(']')
        .map_or(authority, |at| &authority[at..]);
    let port = after_host
        .rsplit_once(':')
        .map(|(_, port)| port)
        .filter(|port| !port.is_empty() && port.bytes().all(|b| b.is_ascii_digit()));
    Ok(match port {
        Some(port) => format!("{}://{host}:{port}", url.scheme()),
        None => format!("{}://{host}", url.scheme()),
    })
}

/// `vapidHelper.getVapidHeaders` for `aes128gcm`: `vapid t=<JWT>, k=<key>`.
pub fn vapid_authorization(
    audience: &str,
    subject: &str,
    keys: &VapidKeys,
    now_ms: i64,
) -> Result<String, String> {
    let parsed =
        Url::parse(subject).map_err(|_| format!("Vapid subject is not a valid URL. {subject}"))?;
    if !matches!(parsed.scheme(), "https" | "mailto") {
        return Err(format!(
            "Vapid subject is not an https: or mailto: URL. {subject}"
        ));
    }
    if parsed.host_str() == Some("localhost") {
        crate::log::warn(
            "Vapid subject points to a localhost web URI, which is unsupported by Apple's push \
             notification server and will result in a BadJwtToken error when sending notifications.",
        );
    }
    if !is_url_base64(&keys.public_key) {
        return Err("Vapid public key must be a URL safe Base 64 (without \"=\")".into());
    }
    if decode_base64url(&keys.public_key)?.len() != 65 {
        return Err("Vapid public key should be 65 bytes long when decoded.".into());
    }
    if !is_url_base64(&keys.private_key) {
        return Err("Vapid private key must be a URL safe Base 64 (without \"=\")".into());
    }
    let private = decode_base64url(&keys.private_key)?;
    if private.len() != 32 {
        return Err("Vapid private key should be 32 bytes long when decoded.".into());
    }
    let signer =
        SigningKey::from_slice(&private).map_err(|_| "Invalid VAPID private key".to_owned())?;
    let header = URL_SAFE_NO_PAD.encode(r#"{"typ":"JWT","alg":"ES256"}"#);
    let claims = json!({
        "aud": audience,
        "exp": now_ms.div_euclid(1000) + VAPID_EXPIRATION_SECONDS,
        "sub": subject,
    });
    let input = format!("{header}.{}", URL_SAFE_NO_PAD.encode(claims.to_string()));
    let signature: Signature = signer.sign(input.as_bytes());
    let jwt = format!("{input}.{}", URL_SAFE_NO_PAD.encode(signature.to_bytes()));
    Ok(format!("vapid t={jwt}, k={}", keys.public_key))
}

/// The `Topic` header allows at most 32 URL-safe base64 characters.
pub fn topic_of(tag: &str) -> String {
    let mut hash: i32 = 0;
    // `for (const char of tag)` with `char.charCodeAt(0)`: per code point,
    // its first UTF-16 unit.
    for c in tag.chars() {
        let mut units = [0; 2];
        let first = c.encode_utf16(&mut units)[0];
        hash = hash.wrapping_mul(31).wrapping_add(i32::from(first));
    }
    let topic = format!(
        "t{}{}",
        base36(u64::from(hash as u32)),
        base36(tag.encode_utf16().count() as u64)
    );
    topic.chars().take(32).collect()
}

fn base36(mut n: u64) -> String {
    const DIGITS: &[u8] = b"0123456789abcdefghijklmnopqrstuvwxyz";
    let mut out = Vec::new();
    loop {
        out.push(DIGITS[(n % 36) as usize]);
        n /= 36;
        if n == 0 {
            break;
        }
    }
    out.reverse();
    String::from_utf8(out).unwrap_or_default()
}

/// `clip` in UTF-16 units: at most `max`, cut with an ellipsis (JS strings
/// may end in half a surrogate pair, so the result stays UTF-16).
fn clip(text: &str, max: usize) -> Vec<u16> {
    let mut units: Vec<u16> = text.encode_utf16().collect();
    if units.len() <= max {
        return units;
    }
    units.truncate(max - 1);
    // `trimEnd()`: JS whitespace (all of it in the BMP).
    while units
        .last()
        .and_then(|&unit| char::from_u32(u32::from(unit)))
        .is_some_and(js_space)
    {
        units.pop();
    }
    units.push(0x2026);
    units
}

/// `JSON.stringify` of a JS string (lone surrogates escaped).
fn js_json_string(units: &[u16]) -> String {
    let mut out = String::with_capacity(units.len() + 2);
    out.push('"');
    for decoded in char::decode_utf16(units.iter().copied()) {
        match decoded {
            Ok('"') => out.push_str("\\\""),
            Ok('\\') => out.push_str("\\\\"),
            Ok('\u{8}') => out.push_str("\\b"),
            Ok('\u{c}') => out.push_str("\\f"),
            Ok('\n') => out.push_str("\\n"),
            Ok('\r') => out.push_str("\\r"),
            Ok('\t') => out.push_str("\\t"),
            Ok(c) if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            Ok(c) => out.push(c),
            Err(lone) => out.push_str(&format!("\\u{:04x}", lone.unpaired_surrogate())),
        }
    }
    out.push('"');
    out
}

/// A payload stays well inside one `aes128gcm` record (4096 bytes less the
/// header and tag), so no push service refuses it for its size.
const MAX_PAYLOAD_BYTES: usize = 3072;

/// What the subscriber decrypts: `{title, body, tag, target, at}`, the
/// category, the target's lock screen setting and question details. It holds
/// no secret: the app reads the state before it shows any answer. Past
/// [`MAX_PAYLOAD_BYTES`] the choices go first, then the body shortens.
fn payload(message: &PushMessage, at: i64, delivery: Delivery) -> String {
    let full = payload_text(message, at, delivery, BODY_UNITS);
    if full.len() <= MAX_PAYLOAD_BYTES {
        return full;
    }
    let mut smaller = message.clone();
    if let Some(interaction) = smaller.interaction.as_mut() {
        interaction.choices.clear();
    }
    for body_units in [BODY_UNITS, 80] {
        let text = payload_text(&smaller, at, delivery, body_units);
        if text.len() <= MAX_PAYLOAD_BYTES {
            return text;
        }
    }
    smaller.body.clear();
    payload_text(&smaller, at, delivery, BODY_UNITS)
}

/// A push body's length, in UTF-16 units.
const BODY_UNITS: usize = 240;

fn payload_text(message: &PushMessage, at: i64, delivery: Delivery, body_units: usize) -> String {
    let tag: Vec<u16> = message.tag.encode_utf16().collect();
    let mut extra = String::new();
    if let Some(category) = message.category {
        extra.push_str(&format!(",\"category\":\"{}\"", category.as_str()));
    }
    if let Some(lock_screen) = delivery.lock_screen {
        extra.push_str(&format!(",\"lockScreen\":\"{}\"", lock_screen.as_str()));
    }
    if delivery.silent {
        extra.push_str(",\"silent\":true");
    }
    let interaction = message
        .interaction
        .as_ref()
        .map(|interaction| {
            let mut fields = format!(
                ",\"kind\":{},\"sessionId\":{}",
                serde_json::to_string(interaction.kind).unwrap_or_else(|_| "null".into()),
                serde_json::to_string(&interaction.session_id).unwrap_or_else(|_| "null".into()),
            );
            if let Some(id) = &interaction.interaction_id {
                fields.push_str(&format!(
                    ",\"interactionId\":{}",
                    serde_json::to_string(id).unwrap_or_else(|_| "null".into()),
                ));
            }
            if let Some(epoch) = &interaction.interaction_epoch {
                fields.push_str(&format!(
                    ",\"interactionEpoch\":{}",
                    serde_json::to_string(epoch).unwrap_or_else(|_| "null".into()),
                ));
            }
            if let Some(expires_at) = interaction.expires_at {
                fields.push_str(&format!(",\"expiresAt\":{expires_at}"));
            }
            if !interaction.choices.is_empty() {
                fields.push_str(&format!(
                    ",\"choices\":{}",
                    serde_json::to_string(&interaction.choices).unwrap_or_else(|_| "[]".into()),
                ));
            }
            if let Some(answered_by) = &interaction.answered_by {
                fields.push_str(&format!(",\"answeredBy\":{answered_by}"));
            }
            fields
        })
        .unwrap_or_default();
    format!(
        r#"{{"title":{},"body":{},"tag":{},"target":{},"at":{at}{extra}{interaction}}}"#,
        js_json_string(&clip(&message.title, 120)),
        js_json_string(&clip(&message.body, body_units)),
        js_json_string(&tag),
        serde_json::to_string(&message.target).unwrap_or_else(|_| "null".into()),
    )
}

// ---------------------------------------------------------------------------
// Subscriptions

/// A subscription as the routes accept it (`subscriptionBody`).
#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SubscriptionInput {
    pub endpoint: String,
    pub keys: SubscriptionKeys,
    /// `web` (a browser) or `unifiedpush` (the Android app); default `web`.
    #[serde(default, deserialize_with = "present")]
    pub kind: Option<String>,
    /// Shown in the list of places that get notifications.
    #[serde(default, deserialize_with = "present")]
    pub name: Option<String>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SubscriptionKeys {
    pub p256dh: String,
    pub auth: String,
}

/// `^[A-Za-z0-9_-]{min,max}={0,2}$`
fn key_shaped(text: &str, min: usize, max: usize) -> bool {
    let body = text.trim_end_matches('=');
    text.len() - body.len() <= 2
        && (min..=max).contains(&body.len())
        && body
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

use pirc_config::text::utf16_len;

impl SubscriptionInput {
    /// The zod schema's checks; `name` comes back trimmed.
    fn validate(mut self) -> ApiResult<Self> {
        let endpoint_ok = utf16_len(&self.endpoint) <= 2000 && Url::parse(&self.endpoint).is_ok();
        let keys_ok = key_shaped(&self.keys.p256dh, 80, 100) && key_shaped(&self.keys.auth, 16, 32);
        let kind = self.kind.get_or_insert_with(|| "web".into());
        let kind_ok = kind == "web" || kind == "unifiedpush";
        if let Some(name) = &mut self.name {
            *name = name.trim_matches(js_space).to_owned();
        }
        let name_ok = self
            .name
            .as_deref()
            .is_none_or(|name| utf16_len(name) <= 100);
        if endpoint_ok && keys_ok && kind_ok && name_ok {
            Ok(self)
        } else {
            Err(ApiError::invalid_input())
        }
    }
}

struct SubscriptionRow {
    id: String,
    endpoint: String,
    p256dh: String,
    auth: String,
    kind: String,
    name: Option<String>,
    created_at: i64,
    last_success_at: Option<i64>,
    failures: i64,
    preferences: Preferences,
    revision: i64,
    summary_mark: i64,
    /// A summary is due at the next tick (quiet hours ended by a change).
    summary_now: bool,
}

impl SubscriptionRow {
    fn from_row(row: &Row<'_>) -> rusqlite::Result<Self> {
        let quiet = match (
            row.get::<_, Option<String>>("quiet_start")?,
            row.get::<_, Option<String>>("quiet_end")?,
        ) {
            (Some(start), Some(end)) => preferences::ClockTime::parse(&start)
                .zip(preferences::ClockTime::parse(&end))
                .map(|(start, end)| preferences::QuietHours { start, end }),
            _ => None,
        };
        let preferences = Preferences {
            levels: preferences::levels_from_json(&row.get::<_, String>("levels_json")?),
            quiet_hours: quiet,
            time_zone: row.get("time_zone")?,
            lock_screen: LockScreen::parse(&row.get::<_, String>("lock_screen")?)
                .unwrap_or(LockScreen::Title),
            digest_at: preferences::ClockTime::parse(&row.get::<_, String>("digest_at")?)
                .unwrap_or(preferences::ClockTime::DIGEST_DEFAULT),
        };
        Ok(Self {
            preferences,
            revision: row.get("revision")?,
            summary_mark: row.get("summary_mark")?,
            summary_now: row.get::<_, i64>("summary_now")? != 0,
            id: row.get("id")?,
            endpoint: row.get("endpoint")?,
            p256dh: row.get("p256dh")?,
            auth: row.get("auth")?,
            kind: row.get("kind")?,
            name: row.get("name")?,
            created_at: row.get("created_at")?,
            last_success_at: row.get("last_success_at")?,
            failures: row.get("failures")?,
        })
    }
}

/// `new URL(endpoint).host`.
fn host_of(endpoint: &str) -> String {
    let Ok(url) = Url::parse(endpoint) else {
        return String::new();
    };
    match (url.host_str(), url.port()) {
        (Some(host), Some(port)) => format!("{host}:{port}"),
        (Some(host), None) => host.to_owned(),
        _ => String::new(),
    }
}

/// A push request's headers, in the order `web-push` set them.
type Headers = Vec<(&'static str, String)>;

/// Push notifications for the users of one gateway (`Push`).
pub struct Push {
    db: Arc<Db>,
    vapid: VapidKeys,
    /// `mailto:` or `https:` contact the push services may use (PIRC_VAPID_SUBJECT).
    subject: String,
    /// Plain http endpoints are refused unless this allows them (tests, loopback distributors).
    allow_http: bool,
    /// A new target's time zone until it sets its own (`PIRC_TIMEZONE`).
    time_zone: String,
    client: reqwest::Client,
    /// Held while summaries are read, sent and settled, so two calls never
    /// send the same items.
    summaries: tokio::sync::Mutex<()>,
}

/// A target as its owner sees it: where it is, how it is doing and its
/// notification preferences.
fn subscription_view(row: SubscriptionRow) -> Value {
    let host = host_of(&row.endpoint);
    let levels: serde_json::Map<String, Value> = row
        .preferences
        .levels
        .iter()
        .map(|(category, level)| (category.as_str().to_owned(), json!(level)))
        .collect();
    json!({
        "id": row.id,
        "kind": row.kind,
        "name": row.name.unwrap_or_else(|| host.clone()),
        "host": host,
        "createdAt": row.created_at,
        "lastSuccessAt": row.last_success_at,
        "failing": row.failures > 0,
        "levels": levels,
        "quietHours": row.preferences.quiet_hours,
        "timeZone": row.preferences.time_zone,
        "lockScreen": row.preferences.lock_screen,
        "digestAt": row.preferences.digest_at,
        "revision": row.revision,
    })
}

impl Push {
    pub fn new(db: Arc<Db>, vapid: VapidKeys, subject: String, allow_http: bool) -> Self {
        // ring, as in pirc-providers: no aws-lc.
        let _ = rustls::crypto::ring::default_provider().install_default();
        // Direct connections, as Node's fetch made them (no proxy variables).
        let client = reqwest::Client::builder()
            .no_proxy()
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .expect("the HTTP client builds with the ring provider installed");
        Self {
            db,
            vapid,
            subject,
            allow_http,
            time_zone: "UTC".to_owned(),
            client,
            summaries: tokio::sync::Mutex::new(()),
        }
    }

    /// New targets start in `zone` (an IANA name or offset) until they set
    /// their own.
    pub fn with_time_zone(mut self, zone: &str) -> Self {
        if crate::schedules::Zone::parse(zone).is_some() {
            zone.clone_into(&mut self.time_zone);
        }
        self
    }

    pub fn public_key(&self) -> &str {
        &self.vapid.public_key
    }

    /// Where the user gets notifications (endpoints are shown by host only).
    pub fn list(&self, user: &str) -> ApiResult<Vec<Value>> {
        let conn = self.db.lock();
        prune(&conn)?;
        let mut statement = conn
            .prepare("SELECT * FROM push_subscriptions WHERE owner_user=? ORDER BY created_at")?;
        let rows = statement
            .query_map([user], SubscriptionRow::from_row)?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(rows.into_iter().map(subscription_view).collect())
    }

    /// Change one target's preferences. `patch.revision` must be the
    /// target's current revision, so two devices cannot overwrite each
    /// other's change unseen.
    pub fn update_preferences(
        &self,
        user: &str,
        id: &str,
        patch: &preferences::PreferencesPatch,
    ) -> ApiResult<Value> {
        self.update_preferences_at(user, id, patch, now_ms())
    }

    /// [`Push::update_preferences`] as of `now`. A new digest time, quiet
    /// hours or time zone counts summary moments from `now` on, so a moment
    /// of the new settings that fell between the last summary and now is
    /// not sent at once. Quiet hours that this change ends (removed, or no
    /// longer covering `now`) end now: what they held goes out next tick.
    pub fn update_preferences_at(
        &self,
        user: &str,
        id: &str,
        patch: &preferences::PreferencesPatch,
        now: i64,
    ) -> ApiResult<Value> {
        let conn = self.db.lock();
        prune(&conn)?;
        let row = conn
            .query_row(
                "SELECT * FROM push_subscriptions WHERE id=? AND owner_user=?",
                [id, user],
                SubscriptionRow::from_row,
            )
            .optional()?
            .ok_or_else(|| ApiError::not_found("Push subscription not found"))?;
        if row.revision != patch.revision {
            return Err(ApiError::new(
                409,
                "revision_mismatch",
                "These notification settings changed elsewhere; read them again",
            )
            .with_details(json!({ "subscription": subscription_view(row) })));
        }
        let next = patch.apply(&row.preferences)?;
        let old = &row.preferences;
        let timing = next.digest_at != old.digest_at
            || next.quiet_hours != old.quiet_hours
            || next.time_zone != old.time_zone;
        let quiet_ended = old.quiet_at(now) && !next.quiet_at(now);
        let levels: BTreeMap<&str, Level> = next
            .levels
            .iter()
            .map(|(category, level)| (category.as_str(), *level))
            .collect();
        conn.execute(
            "UPDATE push_subscriptions SET levels_json=?3, quiet_start=?4, quiet_end=?5, time_zone=?6,
               lock_screen=?7, digest_at=?8, revision=revision+1,
               summary_mark=CASE WHEN ?10 THEN ?11 ELSE summary_mark END,
               summary_now=CASE WHEN ?12 THEN 1 ELSE summary_now END
             WHERE id=?1 AND owner_user=?2 AND revision=?9",
            params![
                id,
                user,
                serde_json::to_string(&levels).unwrap_or_else(|_| "{}".into()),
                next.quiet_hours.map(|quiet| quiet.start.text()),
                next.quiet_hours.map(|quiet| quiet.end.text()),
                next.time_zone,
                next.lock_screen.as_str(),
                next.digest_at.text(),
                patch.revision,
                timing,
                now,
                quiet_ended,
            ],
        )?;
        let row = conn.query_row(
            "SELECT * FROM push_subscriptions WHERE id=?",
            [id],
            SubscriptionRow::from_row,
        )?;
        Ok(subscription_view(row))
    }

    /// Add or refresh a subscription; one endpoint belongs to one user.
    pub fn subscribe(
        &self,
        user: &str,
        input: &SubscriptionInput,
        device_id: Option<&str>,
    ) -> ApiResult<Value> {
        let url = Url::parse(&input.endpoint).map_err(|_| ApiError::invalid_input())?;
        if url.scheme() != "https" && !(self.allow_http && url.scheme() == "http") {
            return Err(ApiError::new(
                400,
                "invalid_input",
                "A push endpoint must use https",
            ));
        }
        if !url.username().is_empty() || url.password().is_some_and(|password| !password.is_empty())
        {
            return Err(ApiError::new(
                400,
                "invalid_input",
                "A push endpoint cannot carry credentials",
            ));
        }
        let id = {
            let conn = self.db.lock();
            let existing: Option<(String, String)> = conn
                .query_row(
                    "SELECT id, owner_user FROM push_subscriptions WHERE endpoint=?",
                    [&input.endpoint],
                    |row| Ok((row.get(0)?, row.get(1)?)),
                )
                .optional()?;
            let id = match existing {
                Some((id, owner)) if owner == user => id,
                Some((id, _)) => {
                    conn.execute("DELETE FROM push_subscriptions WHERE id=?", [&id])?;
                    new_id("push")
                }
                None => new_id("push"),
            };
            let name = input
                .name
                .as_deref()
                .filter(|name| !name.is_empty())
                .map(|name| String::from_utf16_lossy(&clip(name, 100)));
            let stamp = now_ms();
            // A refreshed subscription keeps its preferences.
            conn.execute(
                "INSERT INTO push_subscriptions (id,owner_user,endpoint,p256dh,auth,kind,name,device_id,created_at,failures,
                   time_zone,summary_mark)
                 VALUES (?,?,?,?,?,?,?,?,?,0,?,?)
                 ON CONFLICT(endpoint) DO UPDATE SET p256dh=excluded.p256dh, auth=excluded.auth, kind=excluded.kind,
                   name=excluded.name, device_id=excluded.device_id, failures=0",
                params![
                    id,
                    user,
                    input.endpoint,
                    input.keys.p256dh,
                    input.keys.auth,
                    input.kind.as_deref().unwrap_or("web"),
                    name,
                    device_id,
                    stamp,
                    self.time_zone,
                    stamp,
                ],
            )?;
            id
        };
        self.list(user)?
            .into_iter()
            .find(|item| item["id"] == id.as_str())
            .ok_or_else(ApiError::internal)
    }

    /// Stop notifying one endpoint (by endpoint, as the device knows it) or
    /// subscription id.
    pub fn unsubscribe(
        &self,
        user: &str,
        endpoint: Option<&str>,
        id: Option<&str>,
    ) -> ApiResult<bool> {
        let changes = self.db.lock().execute(
            "DELETE FROM push_subscriptions WHERE owner_user=? AND (endpoint=? OR id=?)",
            params![user, endpoint.unwrap_or_default(), id.unwrap_or_default()],
        )?;
        Ok(changes > 0)
    }

    /// Send `message` to every place `user` gets notifications; how many
    /// took it. Never fails: a push that cannot be delivered is only
    /// logged, and dead endpoints go.
    pub async fn notify(self: &Arc<Self>, user: &str, message: &PushMessage) -> usize {
        self.notify_at(user, message, now_ms()).await
    }

    /// [`Push::notify`] as of `now`: each target's preferences decide whether
    /// the message goes now, silently, or waits for a summary.
    pub async fn notify_at(self: &Arc<Self>, user: &str, message: &PushMessage, now: i64) -> usize {
        let rows = {
            let conn = self.db.lock();
            let rows = prune(&conn).and_then(|()| {
                conn.prepare("SELECT * FROM push_subscriptions WHERE owner_user=?")?
                    .query_map([user], SubscriptionRow::from_row)?
                    .collect::<rusqlite::Result<Vec<_>>>()
            });
            match rows {
                Ok(rows) => rows,
                Err(error) => {
                    crate::log::warn(&format!("push: cannot read subscriptions: {error}"));
                    return 0;
                }
            }
        };
        let topic = Arc::new(topic_of(&message.tag));
        let update = message
            .interaction
            .as_ref()
            .is_some_and(|interaction| interaction.kind != "interaction_created");
        let mut sends = tokio::task::JoinSet::new();
        for row in rows {
            let decision = match message.category {
                Some(category) => row.preferences.decide(category, update, now),
                None => Decision::Send,
            };
            let silent = match decision {
                Decision::Send => false,
                Decision::SendSilent => true,
                Decision::Hold | Decision::Digest => {
                    self.keep_for_summary(&row.id, message, now);
                    continue;
                }
                Decision::Skip => continue,
            };
            let delivery = Delivery {
                silent,
                lock_screen: Some(row.preferences.lock_screen),
            };
            let payload = payload(message, now_ms(), delivery);
            let push = self.clone();
            let topic = topic.clone();
            sends.spawn(async move { push.send(row, &payload, &topic).await });
        }
        let mut delivered = 0;
        while let Some(sent) = sends.join_next().await {
            delivered += usize::from(sent.unwrap_or(false));
        }
        delivered
    }

    /// The request `web-push` would make: its headers and encrypted body.
    fn request(
        &self,
        row: &SubscriptionRow,
        payload: &str,
        topic: &str,
    ) -> Result<(Headers, Vec<u8>), String> {
        let body = encrypt_for(&row.p256dh, &row.auth, payload)?;
        let mut headers = vec![
            ("TTL", TTL_SECONDS.to_string()),
            ("Content-Type", "application/octet-stream".to_owned()),
            ("Content-Encoding", "aes128gcm".to_owned()),
        ];
        if row.endpoint.starts_with(GCM_ENDPOINT) {
            crate::log::warn(
                "Attempt to send push notification to GCM endpoint, but no GCM key is defined.",
            );
        } else {
            headers.push((
                "Authorization",
                vapid_authorization(
                    &audience(&row.endpoint)?,
                    &self.subject,
                    &self.vapid,
                    now_ms(),
                )?,
            ));
        }
        headers.push(("Urgency", "normal".to_owned()));
        headers.push(("Topic", topic.to_owned()));
        Ok((headers, body))
    }

    async fn send(&self, row: SubscriptionRow, payload: &str, topic: &str) -> bool {
        let outcome = match self.request(&row, payload, topic) {
            Ok((headers, body)) => {
                let mut request = self
                    .client
                    .post(&row.endpoint)
                    .timeout(SEND_TIMEOUT)
                    .body(body);
                for (name, value) in headers {
                    request = request.header(name, value);
                }
                match request.send().await {
                    Ok(response) => Ok(response.status().as_u16()),
                    Err(_) => Err("push service unreachable".to_owned()),
                }
            }
            Err(error) => Err(error),
        };
        let conn = self.db.lock();
        let failure = match outcome {
            Ok(404 | 410) => {
                let _ = conn.execute("DELETE FROM push_subscriptions WHERE id=?", [&row.id]);
                return false;
            }
            Ok(status) if (200..300).contains(&status) => {
                let _ = conn.execute(
                    "UPDATE push_subscriptions SET last_success_at=?, failures=0 WHERE id=?",
                    params![now_ms(), row.id],
                );
                return true;
            }
            Ok(status) => format!("push service answered {status}"),
            Err(error) => error,
        };
        let _ = conn.execute(
            "UPDATE push_subscriptions SET failures=failures+1 WHERE id=?",
            [&row.id],
        );
        let _ = conn.execute(
            "DELETE FROM push_subscriptions WHERE id=? AND failures>=?",
            params![row.id, MAX_FAILURES],
        );
        drop(conn);
        crate::log::warn(&format!(
            "push to {} failed: {failure}",
            host_of(&row.endpoint)
        ));
        false
    }
}

/// A phone's subscription goes with its device token.
fn prune(conn: &rusqlite::Connection) -> rusqlite::Result<()> {
    conn.execute(
        "DELETE FROM push_subscriptions WHERE device_id IS NOT NULL AND device_id NOT IN (SELECT id FROM device_tokens)",
        [],
    )
    .map(drop)
}

/// The gateway's push state, made from its configuration on first use (at
/// startup, by [`start`]).
fn state(app: &App) -> Result<Arc<Push>, String> {
    if let Some(push) = app.slots.get::<Push>() {
        return Ok(push);
    }
    let vapid = load_vapid_keys(&app.config.state_dir, &Env::from_process())?;
    Ok(app.slots.get_or_init(|| {
        Push::new(
            app.db.clone(),
            vapid,
            app.config.vapid_subject.clone(),
            app.config.push_allow_http,
        )
        .with_time_zone(&app.config.timezone)
    }))
}

fn push_of(app: &App) -> ApiResult<Arc<Push>> {
    state(app).map_err(|error| {
        crate::log::error(&format!("push: {error}"));
        ApiError::internal()
    })
}

// ---------------------------------------------------------------------------
// The gateway's interface

/// `/api/push*`.
pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/api/push", get(get_push))
        .route(
            "/api/push/subscriptions",
            post(add_subscription).delete(remove_subscription),
        )
        .route(
            "/api/push/subscriptions/{id}",
            axum::routing::patch(update_subscription),
        )
        .route("/api/push/test", post(test_push))
}

/// Load the VAPID keys and start watching for interactions that need the
/// user (`watchInteractions`). Keys that cannot be loaded stop the gateway,
/// as they stopped `createApp`.
/// Fails, before the gateway listens, on unusable VAPID keys.
pub fn start(app: &AppState) -> Result<(), String> {
    let push = state(app)?;
    watch_interactions(&app.events, app.db.clone(), push.clone());
    summary::start(push);
    Ok(())
}

/// Send `message` to every subscription of `user`, in the background.
pub fn notify(app: &App, user: &str, message: PushMessage) {
    let Ok(push) = push_of(app) else {
        return;
    };
    let Ok(runtime) = tokio::runtime::Handle::try_current() else {
        return;
    };
    let (push, user) = (push.clone(), user.to_owned());
    runtime.spawn(async move { push.notify(&user, &message).await });
}

/// The key a browser subscribes with, and where notifications go now.
async fn get_push(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
) -> Handled {
    let push = push_of(&app)?;
    Ok(ok(json!({
        "publicKey": push.public_key(),
        "subscriptions": push.list(&identity.user)?,
    })))
}

/// A device token subscribes its own phone, and the subscription goes with
/// the token.
async fn add_subscription(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    ReqBody(body): ReqBody,
) -> Handled {
    let input = body.parse::<SubscriptionInput>()?.validate()?;
    let subscription =
        push_of(&app)?.subscribe(&identity.user, &input, identity.device_id.as_deref())?;
    Ok(json_response(201, &json!({ "subscription": subscription })))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RemoveBody {
    #[serde(default, deserialize_with = "present")]
    endpoint: Option<String>,
    #[serde(default, deserialize_with = "present")]
    id: Option<String>,
}

/// Change one target's notification preferences, at the revision read.
async fn update_subscription(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    axum::extract::Path(id): axum::extract::Path<String>,
    ReqBody(body): ReqBody,
) -> Handled {
    if utf16_len(&id) > 100 {
        return Err(ApiError::invalid_input().into());
    }
    let patch: preferences::PreferencesPatch = body.parse()?;
    let subscription = push_of(&app)?.update_preferences(&identity.user, &id, &patch)?;
    Ok(ok(json!({ "subscription": subscription })))
}

async fn remove_subscription(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    ReqBody(body): ReqBody,
) -> Handled {
    let RemoveBody { endpoint, id } = body.parse()?;
    let fits = |value: &Option<String>, max: usize| {
        value.as_deref().is_none_or(|value| utf16_len(value) <= max)
    };
    // `.refine((body) => body.endpoint || body.id)`: an empty string is no reference.
    let given = |value: &Option<String>| value.as_deref().is_some_and(|value| !value.is_empty());
    if !fits(&endpoint, 2000) || !fits(&id, 100) || !(given(&endpoint) || given(&id)) {
        return Err(ApiError::invalid_input().into());
    }
    push_of(&app)?.unsubscribe(&identity.user, endpoint.as_deref(), id.as_deref())?;
    Ok(no_content())
}

/// A test notification to every place; answers how many took it.
async fn test_push(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    ReqBody(_): ReqBody,
) -> Handled {
    let delivered = push_of(&app)?
        .notify(
            &identity.user,
            &PushMessage {
                title: "pirc notifications work".into(),
                body: "Scheduled runs and anything waiting for you will show up here.".into(),
                tag: "test".into(),
                target: json!({ "schedules": true }),
                // Shows whatever the settings are.
                category: None,
                interaction: None,
            },
        )
        .await;
    Ok(ok(json!({ "delivered": delivered })))
}

#[cfg(test)]
pub(crate) mod tests;
