//! Environment configuration, ported from `apps/gateway/src/config.ts` (and
//! the path helpers of `models.ts`): the gateway's here, the node's in
//! [`node`], and the environment allowlist of the processes a node starts in
//! [`env_allowlist`].
//!
//! Parsing follows the TypeScript rules exactly, including their leniency:
//! a numeric variable that is not a positive integer silently takes its
//! default, as `z.coerce.number().int().positive().catch(fallback)` does.

use std::collections::{BTreeMap, HashSet};
use std::fmt;
use std::path::{Component, Path, PathBuf};

use indexmap::{IndexMap, IndexSet};
use serde_json::Value;

pub mod env_allowlist;
pub mod frontmatter;
pub mod modes;
pub mod node;
pub mod private_files;
pub mod registry;
pub mod text;

pub use node::{
    BrowserSettings, CHAT_WORKSPACE_ID, ConfigWorkspace, NodeConfig, SandboxSettings, Viewport,
};

const DAY_MS: u64 = 24 * 60 * 60 * 1000;
/// Node transport frames are capped at 16 MiB; a base64 upload (4/3 larger) must fit in one.
pub const MAX_UPLOAD_BYTES: u64 = 11 * 1024 * 1024;

/// A configuration error: the executable prints it and exits.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ConfigError(pub String);

impl fmt::Display for ConfigError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for ConfigError {}

fn error<T>(message: impl Into<String>) -> Result<T, ConfigError> {
    Err(ConfigError(message.into()))
}

/// The process environment (or a test's).
#[derive(Clone, Debug, Default)]
pub struct Env {
    vars: BTreeMap<String, String>,
    cwd: PathBuf,
}

impl Env {
    pub fn from_process() -> Self {
        Self {
            vars: std::env::vars_os()
                .filter_map(|(name, value)| {
                    Some((name.into_string().ok()?, value.into_string().ok()?))
                })
                .collect(),
            cwd: std::env::current_dir().unwrap_or_else(|_| PathBuf::from("/")),
        }
    }

    /// A test environment: these variables, relative paths resolved against `cwd`.
    pub fn new<'a>(
        vars: impl IntoIterator<Item = (&'a str, &'a str)>,
        cwd: impl Into<PathBuf>,
    ) -> Self {
        Self {
            vars: vars
                .into_iter()
                .map(|(name, value)| (name.to_owned(), value.to_owned()))
                .collect(),
            cwd: cwd.into(),
        }
    }

    pub fn get(&self, name: &str) -> Option<&str> {
        self.vars.get(name).map(String::as_str)
    }

    /// Every variable, by name.
    pub fn vars(&self) -> impl Iterator<Item = (&str, &str)> {
        self.vars
            .iter()
            .map(|(name, value)| (name.as_str(), value.as_str()))
    }

    /// `path.resolve`: absolute and lexically normalized.
    pub fn resolve(&self, path: impl AsRef<Path>) -> PathBuf {
        normalize(&self.cwd.join(path))
    }

    /// `os.homedir()`: `$HOME`.
    pub fn home(&self) -> PathBuf {
        PathBuf::from(self.get("HOME").unwrap_or("/"))
    }
}

/// Lexical normalization of an absolute path (`.` and `..` removed).
fn normalize(path: &Path) -> PathBuf {
    let mut out = PathBuf::from("/");
    for component in path.components() {
        match component {
            Component::Normal(part) => out.push(part),
            Component::ParentDir => {
                out.pop();
            }
            Component::RootDir | Component::CurDir | Component::Prefix(_) => {}
        }
    }
    out
}

/// Comma-separated values, trimmed, empty ones dropped.
fn csv(value: Option<&str>) -> impl Iterator<Item = String> + '_ {
    value
        .unwrap_or_default()
        .split(',')
        .map(str::trim)
        .filter(|item| !item.is_empty())
        .map(str::to_owned)
}

pub fn bool_var(value: Option<&str>, fallback: bool) -> bool {
    value.map_or(fallback, |value| {
        matches!(value.to_lowercase().as_str(), "1" | "true" | "yes")
    })
}

/// A positive integer, else `fallback` (`z.coerce.number().int().positive().catch()`).
pub fn integer(value: Option<&str>, fallback: u64) -> u64 {
    value.and_then(js_positive_integer).unwrap_or(fallback)
}

/// `Number(text)` when it is a positive safe integer.
fn js_positive_integer(text: &str) -> Option<u64> {
    let text = text.trim();
    let number = if let Some(hex) = text.strip_prefix("0x").or_else(|| text.strip_prefix("0X")) {
        u64::from_str_radix(hex, 16).ok()? as f64
    } else if let Some(octal) = text.strip_prefix("0o").or_else(|| text.strip_prefix("0O")) {
        u64::from_str_radix(octal, 8).ok()? as f64
    } else if let Some(binary) = text.strip_prefix("0b").or_else(|| text.strip_prefix("0B")) {
        u64::from_str_radix(binary, 2).ok()? as f64
    } else if text
        .chars()
        .all(|c| c.is_ascii_digit() || "+-.eE".contains(c))
        && !text.is_empty()
    {
        text.parse::<f64>().ok()?
    } else {
        return None;
    };
    // Larger than u64 saturates, so a limit check still refuses it.
    (number.is_finite() && number > 0.0 && number.fract() == 0.0).then_some(number as u64)
}

/// `^[a-zA-Z0-9_-]{1,100}$`: node and workspace IDs.
pub fn valid_node_id(id: &str) -> bool {
    (1..=100).contains(&id.len())
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

/// `$PIRC_CONFIG_DIR`, default `~/.config/.pirc`.
pub fn default_config_dir(env: &Env) -> PathBuf {
    env.get("PIRC_CONFIG_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| env.home().join(".config").join(".pirc"))
}

/// `$PIRC_MODELS_FILE`, default `$PIRC_CONFIG_DIR/models.json`.
pub fn default_models_file(env: &Env) -> PathBuf {
    env.get("PIRC_MODELS_FILE")
        .map(PathBuf::from)
        .unwrap_or_else(|| default_config_dir(env).join("models.json"))
}

/// `~` and `~/…` against `$HOME`.
pub fn expand_home(env: &Env, value: &str) -> PathBuf {
    if value == "~" {
        env.home()
    } else if let Some(rest) = value.strip_prefix("~/") {
        env.home().join(rest)
    } else {
        PathBuf::from(value)
    }
}

/// Browser-facing authentication: identity comes from a trusted forward-auth proxy.
#[derive(Clone, Debug)]
pub struct BrowserAuth {
    pub trusted_proxies: HashSet<String>,
    pub allowed_users: HashSet<String>,
    /// In configuration order: the first is the default push contact.
    pub allowed_origins: IndexSet<String>,
    pub allowed_hosts: HashSet<String>,
    /// Lowercase header name.
    pub identity_header: String,
    /// Shared secret the proxy proves itself with (`PIRC_PROXY_SECRET`,
    /// sent as `x-pirc-proxy-secret`).
    pub proxy_secret: Option<String>,
}

/// `pirc-gateway`: the central daemon. It serves the browser API, never runs
/// agents, and routes every session to the node that owns it.
#[derive(Clone, Debug)]
pub struct GatewayConfig {
    pub host: String,
    pub port: u16,
    pub state_dir: PathBuf,
    pub database_path: PathBuf,
    pub uploads_dir: PathBuf,
    pub auth: BrowserAuth,
    /// Node ID → shared secret; at least one node is required.
    pub node_tokens: IndexMap<String, String>,
    pub event_buffer_size: usize,
    pub websocket_max_buffered_bytes: usize,
    pub upload_max_bytes: usize,
    /// A device token dies after this long without use (PIRC_DEVICE_TOKEN_IDLE_DAYS).
    pub device_token_idle_ms: u64,
    /// A device token dies this long after pairing (PIRC_DEVICE_TOKEN_MAX_DAYS).
    pub device_token_max_age_ms: u64,
    /// Providers and default model pushed to every node (PIRC_MODELS_FILE).
    pub models_file: PathBuf,
    /// Gateway-owned mode definitions (`$PIRC_CONFIG_DIR/modes`).
    pub modes_dir: PathBuf,
    /// Characters of the assistant's memory per user (USER entries, MEMORY notes).
    pub memory_budget_user: usize,
    pub memory_budget_note: usize,
    /// How long a delegation waits for the user's approval (PIRC_DELEGATION_TTL_MS).
    pub delegation_ttl_ms: u64,
    /// Exa key for agents' web_search (EXA_API_KEY); without it web search is off.
    pub exa_api_key: Option<String>,
    /// Default IANA time zone of schedules agents create (`PIRC_TIMEZONE`, else the system's).
    pub timezone: String,
    /// Contact for push services (`PIRC_VAPID_SUBJECT`, default the first allowed origin).
    pub vapid_subject: String,
    /// Accept plain-http push endpoints (`PIRC_PUSH_ALLOW_HTTP`).
    pub push_allow_http: bool,
    /// Let users confirm conversation environment transitions
    /// (`PIRC_ENVIRONMENT_SWITCHING`, default off).
    pub environment_switching: bool,
    /// How long one confirmed transition may continue without a device holding
    /// control (`PIRC_TRANSITION_AUTHORITY_SECONDS`). Unset or 0 keeps operation
    /// authority disabled; no default duration is chosen.
    pub transition_authority_secs: Option<u64>,
}

impl GatewayConfig {
    /// Read the configuration and create the state directories (mode 0700).
    pub fn load(env: &Env) -> Result<Self, ConfigError> {
        for legacy in ["PIRC_WORKSPACES", "PIRC_NODE_ID"] {
            if env.get(legacy).is_some_and(|value| !value.is_empty()) {
                return error(format!(
                    "{legacy} belongs to `pirc-node`; the gateway never runs agents itself"
                ));
            }
        }
        let node_tokens = node_tokens(env.get("PIRC_NODE_TOKENS"))?;
        let trusted_proxies: HashSet<_> = csv(env.get("PIRC_TRUSTED_PROXIES")).collect();
        let allowed_origins: IndexSet<_> = csv(env.get("PIRC_ALLOWED_ORIGINS")).collect();
        let allowed_hosts: HashSet<_> = csv(env.get("PIRC_ALLOWED_HOSTS")).collect();
        if trusted_proxies.is_empty() {
            return error("PIRC_TRUSTED_PROXIES must explicitly name at least one proxy address");
        }
        if allowed_origins.is_empty() {
            return error("PIRC_ALLOWED_ORIGINS must explicitly name at least one exact origin");
        }
        if allowed_hosts.is_empty() {
            return error("PIRC_ALLOWED_HOSTS must explicitly name at least one exact Host value");
        }
        let days = |name: &str, fallback: u64| {
            integer(env.get(name), fallback)
                .checked_mul(DAY_MS)
                .ok_or_else(|| ConfigError(format!("{name} is too large")))
        };
        let device_token_idle_ms = days("PIRC_DEVICE_TOKEN_IDLE_DAYS", 7)?;
        let device_token_max_age_ms = days("PIRC_DEVICE_TOKEN_MAX_DAYS", 30)?;
        if device_token_idle_ms > device_token_max_age_ms {
            return error("PIRC_DEVICE_TOKEN_IDLE_DAYS cannot exceed PIRC_DEVICE_TOKEN_MAX_DAYS");
        }
        let allowed_users = allowed_users(env)?;
        let proxy_secret = proxy_secret(env.get("PIRC_PROXY_SECRET"))?;
        if proxy_secret.is_none() && bool_var(env.get("PIRC_PROXY_SECRET_REQUIRED"), true) {
            return error(
                "PIRC_PROXY_SECRET is required: set a secret of at least 32 characters and have \
                 the reverse proxy send it as x-pirc-proxy-secret. Only for development without a \
                 proxy, set PIRC_PROXY_SECRET_REQUIRED=false",
            );
        }
        let upload_max_bytes = upload_limit(env)?;
        let port = integer(env.get("PIRC_PORT"), 8787);
        let port = u16::try_from(port)
            .map_err(|_| ConfigError(format!("PIRC_PORT {port} is not a TCP port")))?;
        let timezone = timezone(env.get("PIRC_TIMEZONE"), env.get("TZ"))?;
        let vapid_subject = vapid_subject(env.get("PIRC_VAPID_SUBJECT"), &allowed_origins[0])?;
        let dirs = StateDirs::create(env)?;
        Ok(Self {
            host: env.get("PIRC_HOST").unwrap_or("127.0.0.1").to_owned(),
            port,
            state_dir: dirs.state_dir,
            database_path: dirs.database_path,
            uploads_dir: dirs.uploads_dir,
            auth: BrowserAuth {
                trusted_proxies,
                allowed_users,
                allowed_origins,
                allowed_hosts,
                identity_header: env
                    .get("PIRC_IDENTITY_HEADER")
                    .unwrap_or("x-pirc-user")
                    .to_lowercase(),
                proxy_secret,
            },
            node_tokens,
            event_buffer_size: integer(env.get("PIRC_EVENT_BUFFER_SIZE"), 1000) as usize,
            websocket_max_buffered_bytes: integer(env.get("PIRC_WS_MAX_BUFFERED_BYTES"), 1_048_576)
                as usize,
            upload_max_bytes,
            device_token_idle_ms,
            device_token_max_age_ms,
            models_file: env.resolve(default_models_file(env)),
            modes_dir: env.resolve(modes::default_modes_dir(env)),
            memory_budget_user: integer(env.get("PIRC_MEMORY_USER_CHARS"), 2000) as usize,
            memory_budget_note: integer(env.get("PIRC_MEMORY_NOTE_CHARS"), 8000) as usize,
            delegation_ttl_ms: integer(env.get("PIRC_DELEGATION_TTL_MS"), 3_600_000),
            exa_api_key: env
                .get("EXA_API_KEY")
                .map(str::trim)
                .filter(|key| !key.is_empty())
                .map(str::to_owned),
            timezone,
            vapid_subject,
            push_allow_http: bool_var(env.get("PIRC_PUSH_ALLOW_HTTP"), false),
            environment_switching: bool_var(env.get("PIRC_ENVIRONMENT_SWITCHING"), false),
            transition_authority_secs: env
                .get("PIRC_TRANSITION_AUTHORITY_SECONDS")
                .and_then(|value| value.trim().parse::<u64>().ok())
                .filter(|secs| *secs > 0),
        })
    }
}

/// `PIRC_NODE_TOKENS`: a JSON object of node ID → secret of at least 32 characters.
fn node_tokens(value: Option<&str>) -> Result<IndexMap<String, String>, ConfigError> {
    let parsed: Value = serde_json::from_str(value.unwrap_or("{}"))
        .map_err(|error| ConfigError(format!("PIRC_NODE_TOKENS is not valid JSON: {error}")))?;
    let Value::Object(entries) = parsed else {
        return error("PIRC_NODE_TOKENS must be a JSON object of node ID to token");
    };
    let mut tokens = IndexMap::new();
    for (node_id, token) in entries {
        let Some(token) = token.as_str().filter(|token| token.chars().count() >= 32) else {
            return error(
                "PIRC_NODE_TOKENS: every token must be a string of at least 32 characters",
            );
        };
        if !valid_node_id(&node_id) {
            return error("Invalid node ID");
        }
        if tokens.values().any(|existing| existing == token) {
            return error("Node tokens must be unique");
        }
        tokens.insert(node_id, token.to_owned());
    }
    if tokens.is_empty() {
        return error("The gateway requires PIRC_NODE_TOKENS to accept at least one node");
    }
    Ok(tokens)
}

fn allowed_users(env: &Env) -> Result<HashSet<String>, ConfigError> {
    let users: HashSet<_> = csv(env.get("PIRC_ALLOWED_USERS")).collect();
    if users.is_empty() {
        return error("PIRC_ALLOWED_USERS must explicitly name at least one user");
    }
    Ok(users)
}

fn upload_limit(env: &Env) -> Result<usize, ConfigError> {
    let limit = integer(env.get("PIRC_UPLOAD_MAX_BYTES"), 10_485_760);
    if limit > MAX_UPLOAD_BYTES {
        return error(format!(
            "PIRC_UPLOAD_MAX_BYTES cannot exceed {MAX_UPLOAD_BYTES} (node frame limit)"
        ));
    }
    Ok(limit as usize)
}

/// Required unless `PIRC_PROXY_SECRET_REQUIRED=false`; a short secret is refused.
fn proxy_secret(value: Option<&str>) -> Result<Option<String>, ConfigError> {
    let secret = value.unwrap_or_default().trim();
    if secret.is_empty() {
        return Ok(None);
    }
    if secret.chars().count() < 32 {
        return error("PIRC_PROXY_SECRET must be at least 32 characters");
    }
    Ok(Some(secret.to_owned()))
}

/// An IANA time zone (`PIRC_TIMEZONE`), else the system's (`$TZ` first, as
/// `Intl` does), else UTC. Names match case-insensitively, as in `Intl`;
/// the given spelling is kept.
fn timezone(value: Option<&str>, tz: Option<&str>) -> Result<String, ConfigError> {
    let given = |value: Option<&str>| {
        value
            .map(str::trim)
            .filter(|zone| !zone.is_empty())
            .map(str::to_owned)
    };
    let known = |zone: &String| chrono_tz::Tz::from_str_insensitive(zone).is_ok();
    // Only PIRC_TIMEZONE is refused; an unusable $TZ falls back to UTC, as in `Intl`.
    let zone = match (given(value), tz) {
        (Some(zone), _) => zone,
        (None, Some(tz)) => given(Some(tz.strip_prefix(':').unwrap_or(tz)))
            .filter(known)
            .unwrap_or_else(|| "UTC".to_owned()),
        (None, None) => iana_time_zone::get_timezone()
            .ok()
            .filter(known)
            .unwrap_or_else(|| "UTC".to_owned()),
    };
    if chrono_tz::Tz::from_str_insensitive(&zone).is_err() {
        return error(format!("PIRC_TIMEZONE: unknown time zone {zone}"));
    }
    Ok(zone)
}

/// Push services want a way to reach the sender: a `mailto:` or `https:` URL.
fn vapid_subject(value: Option<&str>, origin: &str) -> Result<String, ConfigError> {
    let subject = value
        .map(str::trim)
        .filter(|subject| !subject.is_empty())
        .unwrap_or(origin);
    let no_space = |text: &str| !text.is_empty() && !text.chars().any(text::is_space);
    let valid = if let Some(address) = subject.strip_prefix("mailto:") {
        // `\S+@\S+`: some `@` with non-space text on both sides.
        no_space(address)
            && address
                .match_indices('@')
                .any(|(at, _)| at > 0 && at + 1 < address.len())
    } else if let Some(rest) = subject.strip_prefix("https://") {
        no_space(rest)
    } else {
        false
    };
    if !valid {
        return error(format!(
            "PIRC_VAPID_SUBJECT must be a mailto: or https: URL (the default is the first allowed origin, {origin})"
        ));
    }
    Ok(subject.to_owned())
}

struct StateDirs {
    state_dir: PathBuf,
    uploads_dir: PathBuf,
    database_path: PathBuf,
}

impl StateDirs {
    fn create(env: &Env) -> Result<Self, ConfigError> {
        let state_dir = env.resolve(env.get("PIRC_STATE_DIR").unwrap_or(".state"));
        make_private_dir(&state_dir)?;
        let uploads_dir = env
            .get("PIRC_UPLOADS_DIR")
            .map_or_else(|| state_dir.join("uploads"), |dir| env.resolve(dir));
        make_private_dir(&uploads_dir)?;
        let database_path = env.get("PIRC_DATABASE_PATH").map_or_else(
            || state_dir.join("gateway.sqlite"),
            |file| env.resolve(file),
        );
        Ok(Self {
            state_dir,
            uploads_dir,
            database_path,
        })
    }
}

/// `mkdirSync(dir, { recursive: true, mode: 0o700 })`: new directories only get the mode.
fn make_private_dir(dir: &Path) -> Result<(), ConfigError> {
    use std::os::unix::fs::DirBuilderExt;
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(dir)
        .map_err(|error| ConfigError(format!("cannot create {}: {error}", dir.display())))
}

#[cfg(test)]
mod tests {
    use super::*;

    const TOKENS: &str = r#"{"n1":"0123456789abcdef0123456789abcdef"}"#;

    fn base<'a>(dir: &'a str, extra: &[(&'a str, &'a str)]) -> Env {
        let mut vars = vec![
            ("PIRC_NODE_TOKENS", TOKENS),
            ("PIRC_TRUSTED_PROXIES", "127.0.0.1, ::1"),
            (
                "PIRC_ALLOWED_ORIGINS",
                "https://a.example,https://b.example",
            ),
            ("PIRC_ALLOWED_HOSTS", "a.example"),
            ("PIRC_ALLOWED_USERS", "u@example.com"),
            ("PIRC_STATE_DIR", dir),
            ("PIRC_TIMEZONE", "UTC"),
            ("HOME", "/home/test"),
            ("PIRC_PROXY_SECRET", "0123456789abcdef0123456789abcdef"),
        ];
        for (name, value) in extra {
            vars.retain(|(existing, _)| existing != name);
            vars.push((name, value));
        }
        Env::new(vars, "/work")
    }

    #[test]
    fn defaults() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("state");
        let config = GatewayConfig::load(&base(path.to_str().unwrap(), &[])).unwrap();
        assert_eq!(config.port, 8787);
        assert_eq!(config.host, "127.0.0.1");
        assert_eq!(config.database_path, path.join("gateway.sqlite"));
        assert!(path.join("uploads").is_dir());
        assert_eq!(config.vapid_subject, "https://a.example");
        assert_eq!(config.auth.identity_header, "x-pirc-user");
        assert_eq!(config.device_token_idle_ms, 7 * DAY_MS);
        assert_eq!(config.upload_max_bytes, 10_485_760);
        assert_eq!(
            config.models_file,
            PathBuf::from("/home/test/.config/.pirc/models.json")
        );
        assert!(config.auth.trusted_proxies.contains("::1"));
    }

    #[test]
    fn the_proxy_secret_is_required_unless_explicitly_waived() {
        let dir = tempfile::tempdir().unwrap();
        let dir = dir.path().to_str().unwrap();
        let config = GatewayConfig::load(&base(dir, &[])).unwrap();
        assert_eq!(
            config.auth.proxy_secret.as_deref(),
            Some("0123456789abcdef0123456789abcdef")
        );
        for unset in ["", "   "] {
            let error =
                GatewayConfig::load(&base(dir, &[("PIRC_PROXY_SECRET", unset)])).unwrap_err();
            assert!(error.0.contains("PIRC_PROXY_SECRET is required"), "{error}");
        }
        let error = GatewayConfig::load(&base(
            dir,
            &[
                ("PIRC_PROXY_SECRET", ""),
                ("PIRC_PROXY_SECRET_REQUIRED", "yes"),
            ],
        ))
        .unwrap_err();
        assert!(error.0.contains("PIRC_PROXY_SECRET is required"), "{error}");
        let waived = GatewayConfig::load(&base(
            dir,
            &[
                ("PIRC_PROXY_SECRET", ""),
                ("PIRC_PROXY_SECRET_REQUIRED", "false"),
            ],
        ))
        .unwrap();
        assert!(waived.auth.proxy_secret.is_none());
    }

    #[test]
    fn refusals() {
        let dir = tempfile::tempdir().unwrap();
        let dir = dir.path().to_str().unwrap();
        let fails = |extra: &[(&str, &str)], message: &str| {
            let error = GatewayConfig::load(&base(dir, extra)).unwrap_err();
            assert!(
                error.0.contains(message),
                "{error} should contain {message}"
            );
        };
        fails(&[("PIRC_NODE_TOKENS", "{}")], "at least one node");
        fails(&[("PIRC_NODE_TOKENS", r#"{"n":"short"}"#)], "32 characters");
        fails(
            &[(
                "PIRC_NODE_TOKENS",
                r#"{"a b":"0123456789abcdef0123456789abcdef"}"#,
            )],
            "Invalid node ID",
        );
        fails(
            &[(
                "PIRC_NODE_TOKENS",
                r#"{"a":"0123456789abcdef0123456789abcdef","b":"0123456789abcdef0123456789abcdef"}"#,
            )],
            "unique",
        );
        fails(&[("PIRC_WORKSPACES", "[]")], "belongs to `pirc-node`");
        fails(&[("PIRC_ALLOWED_USERS", " , ")], "PIRC_ALLOWED_USERS");
        fails(&[("PIRC_PROXY_SECRET", "short")], "PIRC_PROXY_SECRET");
        fails(&[("PIRC_UPLOAD_MAX_BYTES", "99999999")], "cannot exceed");
        fails(&[("PIRC_TIMEZONE", "Mars/Base")], "unknown time zone");
        fails(&[("PIRC_UPLOAD_MAX_BYTES", "1e20")], "cannot exceed");
        fails(&[("PIRC_DEVICE_TOKEN_MAX_DAYS", "1e30")], "too large");
        fails(&[("PIRC_VAPID_SUBJECT", "http://x")], "PIRC_VAPID_SUBJECT");
        fails(
            &[("PIRC_DEVICE_TOKEN_IDLE_DAYS", "40")],
            "cannot exceed PIRC_DEVICE_TOKEN_MAX_DAYS",
        );
    }

    #[test]
    fn lenient_integers() {
        assert_eq!(integer(Some("12"), 5), 12);
        assert_eq!(integer(Some(" 12 "), 5), 12);
        assert_eq!(integer(Some("1e3"), 5), 1000);
        assert_eq!(integer(Some("0x10"), 5), 16);
        assert_eq!(integer(Some("1e20"), 5), u64::MAX);
        assert_eq!(integer(Some("0"), 5), 5);
        assert_eq!(integer(Some("-3"), 5), 5);
        assert_eq!(integer(Some("1.5"), 5), 5);
        assert_eq!(integer(Some("12abc"), 5), 5);
        assert_eq!(integer(Some(""), 5), 5);
        assert_eq!(integer(None, 5), 5);
    }

    #[test]
    fn time_zones() {
        assert_eq!(timezone(Some("asia/tokyo"), None).unwrap(), "asia/tokyo");
        assert_eq!(timezone(None, Some(":Asia/Taipei")).unwrap(), "Asia/Taipei");
        assert_eq!(timezone(Some("UTC"), Some("Asia/Taipei")).unwrap(), "UTC");
        assert_eq!(timezone(None, Some(":/etc/localtime")).unwrap(), "UTC");
        assert_eq!(timezone(None, Some("CET-1")).unwrap(), "UTC");
    }

    #[test]
    fn subjects() {
        assert!(vapid_subject(Some("mailto:a@b"), "x").is_ok());
        assert!(vapid_subject(Some("mailto:@b"), "x").is_err());
        assert!(vapid_subject(Some("https://x y"), "x").is_err());
        assert_eq!(vapid_subject(None, "https://o").unwrap(), "https://o");
    }
}
