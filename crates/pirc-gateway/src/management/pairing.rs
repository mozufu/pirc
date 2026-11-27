//! Pairing v2 (plans/roadmap.md M8 step 0.1): the app asks first, bound to a
//! challenge only it can answer. A browser approves the request, which binds
//! it to that user and shows a 6-digit confirmation code; the app claims a
//! device token with its verifier and that code.
//!
//! Requests live in the management request store, in memory: a restart ends
//! every open pairing request. The token is the same `pirc_dev_` token as
//! v1 (`POST /api/devices`), with the same limits.

use axum::Router;
use axum::extract::{Extension, Path, State};
use axum::response::Response;
use axum::routing::{get, post};
use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use serde::{Deserialize, Serialize};
use serde_json::json;
use subtle::ConstantTimeEq;

use super::{
    GrantState, MAX_RECORDS, ManagementRequest, ManagementRequestStatus, NativeManagementGrants,
    PairingTerms, RequestKind, TERMINAL_RETENTION_MS, body_value, valid_hex_sha256, valid_verifier,
};
use crate::app::{AppState, ReqBody};
use crate::auth::Identity;
use crate::devices::DeviceSummary;
use crate::error::{ApiError, ApiResult, json_response};
use crate::http::ok;
use crate::util::{random_bytes, sha256_hex};

/// How long a pairing request waits for its approval and claim.
pub const PAIRING_REQUEST_TTL_MS: i64 = 10 * 60_000;
/// Open (pending or approved) pairing requests at one time.
pub const MAX_OPEN_PAIRING_REQUESTS: usize = 20;
/// Wrong confirmation codes that end a request.
pub const MAX_WRONG_CODES: u32 = 5;
const MAX_PLATFORM: usize = 20;

/// The pairing part of a stored request.
#[derive(Clone)]
pub(super) struct Pairing {
    /// The browser user who approved or denied it; none while it waits.
    owner: Option<String>,
    platform: String,
    /// The confirmation code, set by the approval and cleared when the
    /// request ends.
    pub(super) code: String,
    wrong_codes: u32,
}

/// What the browser's approval page shows.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PairingApprovalView {
    pub id: String,
    pub status: ManagementRequestStatus,
    pub expires_at: i64,
    pub server_now: i64,
    pub device_name: String,
    pub platform: String,
    /// How long the paired device lives.
    pub pairing: PairingTerms,
    /// The confirmation code, only for the user who approved it and only
    /// while the app can still claim.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub code: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PairingCreated {
    pub id: String,
    pub expires_at: i64,
    pub server_now: i64,
    /// Where a browser opens the approval page.
    pub approve_path: String,
}

/// The outcome of a claim that did not fail.
#[derive(Debug)]
pub enum PairingClaim {
    /// Not approved yet, or approved and waiting for the code.
    Waiting {
        status: ManagementRequestStatus,
        expires_at: i64,
        server_now: i64,
    },
    /// The new device and its token, shown this once.
    Paired {
        owner: String,
        device: DeviceSummary,
        token: String,
    },
}

fn ended() -> ApiError {
    ApiError::new(
        410,
        "pairing_ended",
        "This pairing request was denied, expired or ended",
    )
}

fn pairing_not_found() -> ApiError {
    ApiError::not_found("Pairing request not found")
}

/// Six digits, uniform: values at or above the largest multiple of 10^6
/// below 2^32 are drawn again.
fn new_code() -> String {
    const LIMIT: u32 = 4_294_000_000;
    loop {
        let value = u32::from_le_bytes(random_bytes::<4>());
        if value < LIMIT {
            return format!("{:06}", value % 1_000_000);
        }
    }
}

fn valid_code(code: &str) -> bool {
    code.len() == 6 && code.bytes().all(|byte| byte.is_ascii_digit())
}

/// Unicode format characters (category Cf): soft hyphen, bidi marks and
/// overrides, zero-width characters, invisible operators, tags and the like.
fn is_format(c: char) -> bool {
    matches!(
        u32::from(c),
        0x00AD
            | 0x0600..=0x0605
            | 0x061C
            | 0x06DD
            | 0x070F
            | 0x0890..=0x0891
            | 0x08E2
            | 0x180E
            | 0x200B..=0x200F
            | 0x202A..=0x202E
            | 0x2060..=0x2064
            | 0x2066..=0x206F
            | 0xFEFF
            | 0xFFF9..=0xFFFB
            | 0x110BD
            | 0x110CD
            | 0x13430..=0x1343F
            | 0x1BCA0..=0x1BCA3
            | 0x1D173..=0x1D17A
            | 0xE0001
            | 0xE0020..=0xE007F
    )
}

/// A device name from a caller with no identity: 1 to 100 UTF-16 units after
/// trimming, with no control or format characters (the browser shows it on
/// the approval page, and a bidi override could disguise it).
pub(super) fn checked_device_name(name: &str) -> Option<&str> {
    let name = name.trim_matches(pirc_config::text::is_space);
    ((1..=100).contains(&name.encode_utf16().count())
        && !name.chars().any(|c| c.is_control() || is_format(c)))
    .then_some(name)
}

fn valid_platform(platform: &str) -> bool {
    (1..=MAX_PLATFORM).contains(&platform.len())
        && platform
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
}

fn browser_only(device_id: Option<&str>) -> ApiResult<()> {
    if device_id.is_some() {
        return Err(ApiError::new(
            403,
            "forbidden",
            "A browser identity is required",
        ));
    }
    Ok(())
}

impl ManagementRequest {
    fn pairing(&self) -> Option<&Pairing> {
        match &self.kind {
            RequestKind::Pairing(pairing) => Some(pairing),
            RequestKind::Management => None,
        }
    }

    fn pairing_mut(&mut self) -> Option<&mut Pairing> {
        match &mut self.kind {
            RequestKind::Pairing(pairing) => Some(pairing),
            RequestKind::Management => None,
        }
    }

    fn approval_view(&self, stamp: i64, terms: PairingTerms, user: &str) -> PairingApprovalView {
        let pairing = self.pairing();
        let code = pairing
            .filter(|pairing| {
                self.status == ManagementRequestStatus::Approved
                    && pairing.owner.as_deref() == Some(user)
                    && !pairing.code.is_empty()
            })
            .map(|pairing| pairing.code.clone());
        PairingApprovalView {
            id: self.id.clone(),
            status: self.status,
            expires_at: self.request_expires_at,
            server_now: stamp,
            device_name: self.device_name.clone(),
            platform: pairing
                .map(|pairing| pairing.platform.clone())
                .unwrap_or_default(),
            pairing: terms,
            code,
        }
    }
}

impl NativeManagementGrants {
    /// Start a pairing request. Needs no identity: the caller has no token yet.
    pub fn create_pairing(
        &self,
        device_name: &str,
        platform: &str,
        challenge: &str,
    ) -> ApiResult<PairingCreated> {
        if !valid_hex_sha256(challenge) || !valid_platform(platform) {
            return Err(ApiError::invalid_input());
        }
        let stamp = self.stamp();
        let mut state = self.lock();
        self.sweep_locked(&mut state, stamp)?;
        let open = state
            .requests
            .values()
            .filter(|request| {
                request.pairing().is_some()
                    && matches!(
                        request.status,
                        ManagementRequestStatus::Pending | ManagementRequestStatus::Approved
                    )
            })
            .count();
        if open >= MAX_OPEN_PAIRING_REQUESTS || state.requests.len() >= MAX_RECORDS {
            return Err(ApiError::new(
                429,
                "too_many_requests",
                "Too many pairing requests are open; try again in a few minutes",
            ));
        }
        let id = URL_SAFE_NO_PAD.encode(random_bytes::<24>());
        let request_expires_at = stamp.saturating_add(PAIRING_REQUEST_TTL_MS);
        state.requests.insert(
            id.clone(),
            ManagementRequest {
                id: id.clone(),
                kind: RequestKind::Pairing(Pairing {
                    owner: None,
                    platform: platform.to_owned(),
                    code: String::new(),
                    wrong_codes: 0,
                }),
                owner: String::new(),
                device_id: String::new(),
                device_name: device_name.to_owned(),
                challenge: challenge.to_owned(),
                capabilities: Vec::new(),
                status: ManagementRequestStatus::Pending,
                created_at: stamp,
                request_expires_at,
                grant_expires_at: None,
                grant_token_hash: None,
                cleanup_at: request_expires_at.saturating_add(TERMINAL_RETENTION_MS),
            },
        );
        Ok(PairingCreated {
            approve_path: format!("/?pair={id}"),
            id,
            expires_at: request_expires_at,
            server_now: stamp,
        })
    }

    /// A pairing request as `user` may see it: a waiting one is open to any
    /// allowed browser user; once decided, only to the user who decided.
    fn visible_pairing<'a>(
        &self,
        state: &'a mut GrantState,
        user: &str,
        id: &str,
        stamp: i64,
    ) -> ApiResult<&'a mut ManagementRequest> {
        Self::checked_id(id)?;
        self.sweep_locked(state, stamp)?;
        let request = state.requests.get_mut(id).ok_or_else(pairing_not_found)?;
        let visible = request
            .pairing()
            .is_some_and(|pairing| pairing.owner.as_deref().is_none_or(|owner| owner == user));
        if !visible {
            return Err(pairing_not_found());
        }
        Ok(request)
    }

    pub fn pairing_approval(
        &self,
        user: &str,
        device_id: Option<&str>,
        id: &str,
    ) -> ApiResult<PairingApprovalView> {
        browser_only(device_id)?;
        let stamp = self.stamp();
        let mut state = self.lock();
        let request = self.visible_pairing(&mut state, user, id, stamp)?;
        Ok(request.approval_view(stamp, self.devices.pairing_terms(), user))
    }

    /// Approve (binding the request to `user` and making its code) or deny.
    pub fn decide_pairing(
        &self,
        user: &str,
        device_id: Option<&str>,
        id: &str,
        approved: bool,
    ) -> ApiResult<PairingApprovalView> {
        browser_only(device_id)?;
        let stamp = self.stamp();
        let mut state = self.lock();
        let request = self.visible_pairing(&mut state, user, id, stamp)?;
        if request.status != ManagementRequestStatus::Pending {
            return Err(ApiError::new(
                409,
                "conflict",
                "Pairing request is no longer pending",
            ));
        }
        if approved {
            request.status = ManagementRequestStatus::Approved;
            if let Some(pairing) = request.pairing_mut() {
                pairing.owner = Some(user.to_owned());
                pairing.code = new_code();
            }
        } else {
            if let Some(pairing) = request.pairing_mut() {
                pairing.owner = Some(user.to_owned());
            }
            Self::finish(&mut state, id, ManagementRequestStatus::Denied, stamp);
        }
        let request = state.requests.get(id).ok_or_else(pairing_not_found)?;
        Ok(request.approval_view(stamp, self.devices.pairing_terms(), user))
    }

    /// The app asks whether it is paired. Everything happens under the store's
    /// lock, so concurrent claims cannot try more than [`MAX_WRONG_CODES`]
    /// codes or pair twice.
    pub fn claim_pairing(
        &self,
        id: &str,
        verifier: &str,
        code: Option<&str>,
    ) -> ApiResult<PairingClaim> {
        Self::checked_id(id)?;
        if !valid_verifier(verifier) || code.is_some_and(|code| !valid_code(code)) {
            return Err(ApiError::invalid_input());
        }
        let stamp = self.stamp();
        let mut state = self.lock();
        self.sweep_locked(&mut state, stamp)?;
        let request = state.requests.get_mut(id).ok_or_else(pairing_not_found)?;
        if request.pairing().is_none() {
            return Err(pairing_not_found());
        }
        if !matches!(
            request.status,
            ManagementRequestStatus::Pending | ManagementRequestStatus::Approved
        ) {
            return Err(ended());
        }
        let supplied = sha256_hex(verifier);
        if !bool::from(supplied.as_bytes().ct_eq(request.challenge.as_bytes())) {
            return Err(ApiError::new(
                403,
                "forbidden",
                "Pairing verifier is invalid",
            ));
        }
        let waiting = |request: &ManagementRequest| PairingClaim::Waiting {
            status: request.status,
            expires_at: request.request_expires_at,
            server_now: stamp,
        };
        let Some(code) = code else {
            return Ok(waiting(request));
        };
        if request.status == ManagementRequestStatus::Pending {
            return Ok(waiting(request));
        }
        let (owner, matches) = {
            let pairing = request.pairing().ok_or_else(pairing_not_found)?;
            let matches = !pairing.code.is_empty()
                && bool::from(code.as_bytes().ct_eq(pairing.code.as_bytes()));
            (pairing.owner.clone(), matches)
        };
        if !matches {
            let wrong = request.pairing_mut().map_or(MAX_WRONG_CODES, |pairing| {
                pairing.wrong_codes += 1;
                pairing.wrong_codes
            });
            if wrong >= MAX_WRONG_CODES {
                Self::finish(&mut state, id, ManagementRequestStatus::Revoked, stamp);
                return Err(ApiError::new(
                    410,
                    "pairing_ended",
                    "Too many wrong codes ended this pairing request",
                ));
            }
            return Err(
                ApiError::new(403, "invalid_code", "The confirmation code is wrong")
                    .with_details(json!({ "attemptsLeft": MAX_WRONG_CODES - wrong })),
            );
        }
        let owner = owner.ok_or_else(ApiError::internal)?;
        let name = request.device_name.clone();
        // Pair while holding the lock: a second claim waits and then finds
        // the request ended. A refused pairing (10 phones) leaves it approved.
        let (device, token) = self.devices.create(&owner, &name)?;
        Self::finish(&mut state, id, ManagementRequestStatus::Claimed, stamp);
        Ok(PairingClaim::Paired {
            owner,
            device,
            token,
        })
    }
}

/// The two routes that need no identity. They still need a trusted proxy peer
/// and an allowed `Host` (see `auth::validate_anonymous`).
pub fn is_anonymous_route(method: &axum::http::Method, path: &str) -> bool {
    if method != axum::http::Method::POST {
        return false;
    }
    if path == "/api/pairing/requests" {
        return true;
    }
    path.strip_prefix("/api/pairing/requests/")
        .and_then(|rest| rest.strip_suffix("/claim"))
        .is_some_and(|id| !id.is_empty() && !id.contains('/'))
}

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/api/pairing/requests", post(create))
        .route("/api/pairing/requests/{id}/claim", post(claim))
        .route("/api/pairing/approvals/{id}", get(view))
        .route("/api/pairing/approvals/{id}/approve", post(approve))
        .route("/api/pairing/approvals/{id}/deny", post(deny))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct CreateBody {
    device_name: String,
    platform: String,
    challenge: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ClaimBody {
    verifier: String,
    #[serde(default, deserialize_with = "crate::util::present")]
    code: Option<String>,
}

async fn create(State(app): State<AppState>, ReqBody(body): ReqBody) -> ApiResult<Response> {
    let body: CreateBody = body.parse()?;
    // The length rule of `POST /api/devices`, and no control or format
    // characters.
    let name = checked_device_name(&body.device_name).ok_or_else(ApiError::invalid_input)?;
    let created = app
        .management
        .create_pairing(name, &body.platform, &body.challenge)?;
    Ok(json_response(201, &body_value(&created)))
}

async fn claim(
    State(app): State<AppState>,
    Path(id): Path<String>,
    ReqBody(body): ReqBody,
) -> ApiResult<Response> {
    let body: ClaimBody = body.parse()?;
    match app
        .management
        .claim_pairing(&id, &body.verifier, body.code.as_deref())?
    {
        PairingClaim::Waiting {
            status,
            expires_at,
            server_now,
        } => Ok(json_response(
            202,
            &json!({ "status": status, "expiresAt": expires_at, "serverNow": server_now }),
        )),
        // The same record as `GET /api/device`.
        PairingClaim::Paired {
            owner,
            device,
            token,
        } => {
            let device =
                crate::clients::device_json(&app.db.lock(), &owner, &device.id, &app.devices)?;
            Ok(ok(json!({ "device": device, "token": token })))
        }
    }
}

async fn view(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(id): Path<String>,
) -> ApiResult<Response> {
    let view =
        app.management
            .pairing_approval(&identity.user, identity.device_id.as_deref(), &id)?;
    Ok(ok(body_value(&view)))
}

async fn approve(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(id): Path<String>,
) -> ApiResult<Response> {
    let view =
        app.management
            .decide_pairing(&identity.user, identity.device_id.as_deref(), &id, true)?;
    Ok(ok(body_value(&view)))
}

async fn deny(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(id): Path<String>,
) -> ApiResult<Response> {
    let view =
        app.management
            .decide_pairing(&identity.user, identity.device_id.as_deref(), &id, false)?;
    Ok(ok(body_value(&view)))
}

#[cfg(test)]
mod tests;
