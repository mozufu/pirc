//! `pirc-node`'s configuration: the node half of `apps/gateway/src/config.ts`
//! (`loadNodeConfig`, `parseWorkspaces`, `defaultAgentCommand`) and
//! `node/browser-executable.ts`.
//!
//! The role is the executable's subcommand (`pirc-node` or `pirc-node chat`),
//! never the environment: `PIRC_CHAT` is refused, as in TS.

use std::collections::HashSet;
use std::path::{Path, PathBuf};

use pirc_protocol::{ModeId, NodeRole};
use serde_json::{Map, Value};

use crate::{
    ConfigError, Env, StateDirs, allowed_users, bool_var, csv, default_config_dir, error, integer,
    make_private_dir, upload_limit, valid_node_id,
};

/// The chat node's workspace that holds each pot's own session.
pub const POTS_WORKSPACE_ID: &str = "pots";

/// Hostnames that may use plain `ws://` (`new URL(...).hostname` keeps the
/// brackets of an IPv6 address).
const LOOPBACK_HOSTS: [&str; 3] = ["127.0.0.1", "[::1]", "localhost"];

/// A workspace the node starts with (`PIRC_WORKSPACES`); more can be added
/// from the web client.
#[derive(Clone, Debug, PartialEq)]
pub struct ConfigWorkspace {
    pub id: String,
    /// Gateway-owned mode id; no capability definitions are stored here.
    pub mode: ModeId,
    /// Canonical: absolute, symlinks resolved (`realpathSync`).
    pub path: PathBuf,
    pub display_name: String,
    pub defaults: Map<String, Value>,
}

/// `PIRC_BROWSER_VIEWPORT`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Viewport {
    pub width: u32,
    pub height: u32,
}

/// The agent browser's settings (ported from `BrowserSettings` of the TS
/// node). `PIRC_PLAYWRIGHT_CORE` is not read: the Rust node has no
/// Playwright.
#[derive(Clone, Debug, PartialEq)]
pub struct BrowserSettings {
    /// `PIRC_BROWSER` (default on).
    pub enabled: bool,
    /// `PIRC_BROWSER_EXECUTABLE`, else the first Chromium found.
    pub executable: Option<PathBuf>,
    /// `PIRC_FFMPEG`, default `ffmpeg`.
    pub ffmpeg: String,
    /// `PIRC_BROWSER_PROFILES_DIR`, default `<state>/browser`. Private to the
    /// node (the sandbox hides it from agents).
    pub profiles_dir: PathBuf,
    /// `PIRC_BROWSER_IDLE_MS`, default 30 minutes.
    pub idle_ms: u64,
    pub viewport: Viewport,
    /// Private hosts the agent's browser may reach anyway (`PIRC_BROWSER_ALLOW_PRIVATE`).
    pub allow_private_hosts: Vec<String>,
    /// The gateway's own host (from `PIRC_DAEMON_URL`): never a browsing target.
    pub gateway_host: String,
    /// `PIRC_BROWSER_BLOCK_HOSTS`.
    pub blocked_hosts: Vec<String>,
}

/// The OS sandbox every agent runs in. It cannot be turned off.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SandboxSettings {
    /// `PIRC_SANDBOX_SRT`: an external srt-compatible wrapper (`--settings
    /// <file> --control-fd 3 -- <cmd>`), the development stand-in the
    /// conformance harness uses. Without it the node uses its native backend.
    pub srt: Option<String>,
}

/// `pirc-node`: runs agents, terminals and workspace inspection locally and
/// connects out to the gateway. It never listens on a port.
#[derive(Clone, Debug)]
pub struct NodeConfig {
    pub role: NodeRole,
    /// Mode ids this node accepts (`PIRC_MODES`, comma separated).
    pub modes: Vec<ModeId>,
    pub node_id: String,
    pub node_token: String,
    /// `ws://` or `wss://` (`PIRC_DAEMON_URL`); plain `ws://` only to loopback
    /// unless `PIRC_ALLOW_INSECURE_NODE_TRANSPORT` is set.
    pub daemon_url: String,
    /// Users the gateway may act for on this node.
    pub allowed_users: HashSet<String>,
    pub state_dir: PathBuf,
    pub database_path: PathBuf,
    pub sessions_dir: PathBuf,
    pub uploads_dir: PathBuf,
    /// `$PIRC_CONFIG_DIR`, default `~/.config/.pirc` (the agent's `config.json`,
    /// assistant prompts), as `defaultConfigDir` gives it (not resolved).
    pub config_dir: PathBuf,
    /// Executable for per-session agents (`PIRC_AGENT_COMMAND`, default this
    /// executable).
    pub agent_command: String,
    /// Arguments before the agent flags (`PIRC_AGENT_ARGS`, a JSON array,
    /// default `["agent"]`).
    pub agent_args: Vec<String>,
    pub workspaces: Vec<ConfigWorkspace>,
    /// Where this node's agents keep workspace memory (`PIRC_WORKSPACE_MEMORY_DIR`,
    /// default `<state>/workspace-memory`), mirrored to the gateway.
    pub workspace_memory_dir: PathBuf,
    /// How often the mirror looks for new workspace memory (`PIRC_MEMORY_MIRROR_MS`, 30 s).
    pub memory_mirror_ms: u64,
    pub event_buffer_size: usize,
    /// Longest line an agent may write on stdout (`PIRC_RPC_MAX_LINE_BYTES`, 1 MiB).
    pub rpc_max_line_bytes: usize,
    pub upload_max_bytes: usize,
    /// Interactive shells in the web side panel (`PIRC_TERMINALS`, default on).
    pub terminals_enabled: bool,
    /// `PIRC_TERMINAL_SHELL`, default `$SHELL`.
    pub terminal_shell: Option<String>,
    /// Folders under which conversations may be granted access
    /// (`PIRC_GRANT_ROOTS`, a JSON array of absolute paths). Empty: none.
    pub grant_roots: Vec<std::path::PathBuf>,
    pub browser: BrowserSettings,
    pub sandbox: SandboxSettings,
    pub lease_ttl_ms: u64,
    pub interaction_ttl_ms: u64,
    pub shutdown_grace_ms: u64,
}

impl NodeConfig {
    pub fn chat(&self) -> bool {
        self.role == NodeRole::Chat
    }

    /// Read the configuration for `role` and create the state directories
    /// (state, uploads and sessions, mode 0700).
    pub fn load(env: &Env, role: NodeRole) -> Result<Self, ConfigError> {
        if env.get("PIRC_CHAT").is_some() {
            return error(
                "PIRC_CHAT was removed; run `pirc-node chat` for the chat role or `pirc-node` for a coding node",
            );
        }
        // The node sets PIRC_SANDBOX=srt for its agents; only the old opt-out is refused.
        if env.get("PIRC_SANDBOX") == Some("off") {
            return error(
                "PIRC_SANDBOX=off was removed: agents always run in the sandbox, and a node without a working one starts no agents",
            );
        }
        let node_id = env
            .get("PIRC_NODE_ID")
            .filter(|id| valid_node_id(id))
            .ok_or_else(|| ConfigError("Invalid PIRC_NODE_ID".into()))?
            .to_owned();
        let node_token = env
            .get("PIRC_NODE_TOKEN")
            .filter(|token| token.encode_utf16().count() >= 32)
            .ok_or_else(|| ConfigError("PIRC_NODE_TOKEN must be at least 32 characters".into()))?
            .to_owned();
        let daemon_url = env
            .get("PIRC_DAEMON_URL")
            .filter(|url| url.starts_with("ws://") || url.starts_with("wss://"))
            .ok_or_else(|| ConfigError("PIRC_DAEMON_URL must be a ws(s):// URL".into()))?
            .to_owned();
        let gateway_host = url::Url::parse(&daemon_url)
            .ok()
            .and_then(|url| url.host_str().map(str::to_owned))
            .ok_or_else(|| {
                ConfigError(format!("PIRC_DAEMON_URL is not a valid URL: {daemon_url}"))
            })?;
        // Plain ws:// never leaves the machine when the gateway is on loopback.
        if !daemon_url.starts_with("wss://")
            && !LOOPBACK_HOSTS.contains(&gateway_host.as_str())
            && !bool_var(env.get("PIRC_ALLOW_INSECURE_NODE_TRANSPORT"), false)
        {
            return error(
                "Node transport requires wss:// off loopback (or explicit development-only insecure override)",
            );
        }
        let dirs = StateDirs::create(env)?;
        let sessions_dir = env
            .get("PIRC_SESSIONS_DIR")
            .map_or_else(|| dirs.state_dir.join("sessions"), |dir| env.resolve(dir));
        make_private_dir(&sessions_dir)?;
        let workspaces = parse_workspaces(env)?;
        if role == NodeRole::Chat && !workspaces.is_empty() {
            return error(
                "PIRC_WORKSPACES must be empty on the chat node (pirc-node chat): it hosts pots only",
            );
        }
        let modes = accepted_modes(env.get("PIRC_MODES"), role)?;
        for workspace in &workspaces {
            if !modes.contains(&workspace.mode) {
                return error(format!(
                    "workspace {} uses mode {} not accepted by PIRC_MODES",
                    workspace.id, workspace.mode
                ));
            }
        }
        let allowed_users = allowed_users(env)?;
        let (agent_command, agent_args) = agent_command(env)?;
        let upload_max_bytes = upload_limit(env)?;
        let truthy = |name: &str| env.get(name).filter(|value| !value.is_empty());
        let browser = BrowserSettings {
            enabled: bool_var(env.get("PIRC_BROWSER"), true),
            executable: find_browser_executable(env, truthy("PIRC_BROWSER_EXECUTABLE")),
            ffmpeg: truthy("PIRC_FFMPEG").unwrap_or("ffmpeg").to_owned(),
            profiles_dir: env
                .get("PIRC_BROWSER_PROFILES_DIR")
                .map_or_else(|| dirs.state_dir.join("browser"), |dir| env.resolve(dir)),
            idle_ms: integer(env.get("PIRC_BROWSER_IDLE_MS"), 30 * 60_000),
            viewport: viewport(env.get("PIRC_BROWSER_VIEWPORT")),
            allow_private_hosts: csv(env.get("PIRC_BROWSER_ALLOW_PRIVATE")).collect(),
            gateway_host,
            blocked_hosts: csv(env.get("PIRC_BROWSER_BLOCK_HOSTS")).collect(),
        };
        Ok(Self {
            role,
            modes,
            node_id,
            node_token,
            daemon_url,
            allowed_users,
            workspace_memory_dir: env.get("PIRC_WORKSPACE_MEMORY_DIR").map_or_else(
                || dirs.state_dir.join("workspace-memory"),
                |dir| env.resolve(dir),
            ),
            state_dir: dirs.state_dir,
            database_path: dirs.database_path,
            sessions_dir,
            uploads_dir: dirs.uploads_dir,
            config_dir: default_config_dir(env),
            agent_command,
            agent_args,
            workspaces,
            memory_mirror_ms: integer(env.get("PIRC_MEMORY_MIRROR_MS"), 30_000),
            event_buffer_size: integer(env.get("PIRC_EVENT_BUFFER_SIZE"), 1000) as usize,
            rpc_max_line_bytes: integer(env.get("PIRC_RPC_MAX_LINE_BYTES"), 1_048_576) as usize,
            upload_max_bytes,
            terminals_enabled: bool_var(env.get("PIRC_TERMINALS"), true),
            terminal_shell: truthy("PIRC_TERMINAL_SHELL").map(str::to_owned),
            grant_roots: env
                .get("PIRC_GRANT_ROOTS")
                .and_then(|text| serde_json::from_str::<Vec<String>>(text).ok())
                .unwrap_or_default()
                .into_iter()
                .map(std::path::PathBuf::from)
                .filter(|path| path.is_absolute())
                .collect(),
            browser,
            sandbox: SandboxSettings {
                srt: truthy("PIRC_SANDBOX_SRT").map(str::to_owned),
            },
            lease_ttl_ms: integer(env.get("PIRC_LEASE_TTL_MS"), 30_000),
            interaction_ttl_ms: integer(env.get("PIRC_INTERACTION_TTL_MS"), 3_600_000),
            shutdown_grace_ms: integer(env.get("PIRC_SHUTDOWN_GRACE_MS"), 5_000),
        })
    }
}

/// Accepted ids, not definitions. An explicitly empty list grants no modes.
fn accepted_modes(value: Option<&str>, role: NodeRole) -> Result<Vec<ModeId>, ConfigError> {
    let Some(value) = value else {
        return Ok(vec![
            ModeId::new(if role == NodeRole::Chat {
                "pot"
            } else {
                "directory"
            })
            .expect("default mode id"),
        ]);
    };
    if value.trim().is_empty() {
        return Ok(Vec::new());
    }
    let mut modes = Vec::new();
    for value in value.split(',').map(str::trim) {
        let mode =
            ModeId::new(value).map_err(|error| ConfigError(format!("PIRC_MODES: {error}")))?;
        if modes.contains(&mode) {
            return error(format!("PIRC_MODES: duplicate mode id {mode}"));
        }
        modes.push(mode);
    }
    Ok(modes)
}

/// `PIRC_WORKSPACES`: a JSON array of `{id?, mode?, path, displayName?, defaults?}`
/// (unknown keys ignored). Paths are made canonical, so each must exist.
pub fn parse_workspaces(env: &Env) -> Result<Vec<ConfigWorkspace>, ConfigError> {
    let parsed: Value = serde_json::from_str(env.get("PIRC_WORKSPACES").unwrap_or("[]"))
        .map_err(|error| ConfigError(format!("PIRC_WORKSPACES is not valid JSON: {error}")))?;
    let Value::Array(items) = parsed else {
        return error("PIRC_WORKSPACES must be a JSON array of workspaces");
    };
    let mut workspaces = Vec::with_capacity(items.len());
    for (index, item) in items.iter().enumerate() {
        let invalid = |what: &str| ConfigError(format!("PIRC_WORKSPACES[{index}]: {what}"));
        let Value::Object(item) = item else {
            return Err(invalid("must be an object"));
        };
        let optional_string = |key: &str| match item.get(key) {
            None => Ok(None),
            Some(Value::String(text)) if !text.is_empty() => Ok(Some(text.as_str())),
            Some(_) => Err(invalid(&format!("{key} must be a non-empty string"))),
        };
        let id = optional_string("id")?;
        if id.is_some_and(|id| !valid_node_id(id)) {
            return Err(invalid("id must match ^[a-zA-Z0-9_-]{1,100}$"));
        }
        let mode = ModeId::new(optional_string("mode")?.unwrap_or("directory"))
            .map_err(|error| invalid(&error))?;
        let path = optional_string("path")?.ok_or_else(|| invalid("path is required"))?;
        let display_name = optional_string("displayName")?;
        let defaults = match item.get("defaults") {
            None => Map::new(),
            Some(Value::Object(defaults)) => defaults.clone(),
            Some(_) => return Err(invalid("defaults must be an object")),
        };
        let resolved = std::fs::canonicalize(env.resolve(path))
            .map_err(|error| invalid(&format!("{path}: {error}")))?;
        workspaces.push(ConfigWorkspace {
            mode,
            id: id.map_or_else(|| format!("workspace-{}", index + 1), str::to_owned),
            display_name: display_name.map_or_else(
                || {
                    resolved
                        .file_name()
                        .map_or_else(String::new, |name| name.to_string_lossy().into_owned())
                },
                str::to_owned,
            ),
            path: resolved,
            defaults,
        });
    }
    Ok(workspaces)
}

/// `defaultAgentCommand`: `PIRC_AGENT_COMMAND` with `PIRC_AGENT_ARGS`
/// (default `["agent"]`), else this executable's `agent` subcommand. Both
/// roles run the same executable, so the role does not change it.
fn agent_command(env: &Env) -> Result<(String, Vec<String>), ConfigError> {
    let Some(command) = env
        .get("PIRC_AGENT_COMMAND")
        .filter(|value| !value.is_empty())
    else {
        let exe = std::env::current_exe()
            .map_err(|error| ConfigError(format!("cannot locate this executable: {error}")))?;
        return Ok((exe.display().to_string(), vec!["agent".to_owned()]));
    };
    let args = match env.get("PIRC_AGENT_ARGS").filter(|value| !value.is_empty()) {
        None => vec!["agent".to_owned()],
        Some(text) => serde_json::from_str::<Vec<String>>(text).map_err(|_| {
            ConfigError("PIRC_AGENT_ARGS must be a JSON array of strings".to_owned())
        })?,
    };
    Ok((command.to_owned(), args))
}

/// `1280x800` style browser viewport: 3 or 4 digits each, clamped to
/// 320..3840 x 240..2160; anything else is 1280x800.
fn viewport(value: Option<&str>) -> Viewport {
    let digits = |text: &str| {
        ((3..=4).contains(&text.len()) && text.bytes().all(|b| b.is_ascii_digit()))
            .then(|| text.parse::<u32>().ok())
            .flatten()
    };
    value
        .and_then(|value| value.split_once('x'))
        .and_then(|(width, height)| Some((digits(width)?, digits(height)?)))
        .map_or(
            Viewport {
                width: 1280,
                height: 800,
            },
            |(width, height)| Viewport {
                width: width.clamp(320, 3840),
                height: height.clamp(240, 2160),
            },
        )
}

/// `findBrowserExecutable`: the explicit path, else the first Chromium on
/// `PATH`, else a macOS application bundle.
fn find_browser_executable(env: &Env, explicit: Option<&str>) -> Option<PathBuf> {
    if let Some(explicit) = explicit {
        return Some(PathBuf::from(explicit));
    }
    for name in [
        "chromium",
        "chromium-browser",
        "google-chrome-stable",
        "google-chrome",
        "microsoft-edge",
    ] {
        if let Some(found) = which(env, name) {
            return Some(found);
        }
    }
    [
        "/Applications/Chromium.app/Contents/MacOS/Chromium",
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    ]
    .into_iter()
    .map(PathBuf::from)
    .find(|candidate| candidate.is_file())
}

/// `Bun.which`: the first executable file named `name` on `$PATH`.
fn which(env: &Env, name: &str) -> Option<PathBuf> {
    use std::os::unix::fs::PermissionsExt;
    let executable = |path: &Path| {
        path.metadata()
            .is_ok_and(|meta| meta.is_file() && meta.permissions().mode() & 0o111 != 0)
    };
    env.get("PATH")?
        .split(':')
        .filter(|dir| !dir.is_empty())
        .map(|dir| env.resolve(dir).join(name))
        .find(|candidate| executable(candidate))
}

#[cfg(test)]
mod tests {
    use super::*;

    const TOKEN: &str = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx";

    /// `nodeEnvironment()` of role-executables.test.ts.
    fn node_env<'a>(state: &'a str, extra: &[(&'a str, &'a str)]) -> Env {
        let mut vars = vec![
            ("PIRC_NODE_ID", "test-node"),
            ("PIRC_NODE_TOKEN", TOKEN),
            ("PIRC_DAEMON_URL", "ws://127.0.0.1:8787"),
            ("PIRC_ALLOWED_USERS", "test-user"),
            ("PIRC_STATE_DIR", state),
            ("PIRC_BROWSER", "false"),
            ("HOME", "/home/test"),
            ("PATH", ""),
        ];
        for (name, value) in extra {
            vars.retain(|(existing, _)| existing != name);
            vars.push((name, value));
        }
        Env::new(vars, "/work")
    }

    fn fails(env: &Env, role: NodeRole, message: &str) {
        let error = NodeConfig::load(env, role).unwrap_err();
        assert!(
            error.0.contains(message),
            "{error} should contain {message}"
        );
    }

    // role-executables.test.ts: "fixes config.chat and the agent command from the <role> executable role"
    #[test]
    fn role_fixes_chat_and_the_agent_command() {
        let dir = tempfile::tempdir().unwrap();
        let exe = std::env::current_exe().unwrap().display().to_string();
        for role in [NodeRole::Chat, NodeRole::Node] {
            let config =
                NodeConfig::load(&node_env(dir.path().to_str().unwrap(), &[]), role).unwrap();
            assert_eq!(config.chat(), role == NodeRole::Chat);
            assert_eq!(config.agent_command, exe);
            assert_eq!(config.agent_args, ["agent"]);
        }
    }

    // "rejects legacy PIRC_CHAT=<value> for <role>"
    #[test]
    fn rejects_legacy_pirc_chat() {
        for role in [NodeRole::Chat, NodeRole::Node] {
            for value in ["", "0", "1", "false", "true"] {
                fails(
                    &Env::new([("PIRC_CHAT", value)], "/work"),
                    role,
                    "PIRC_CHAT was removed",
                );
            }
        }
    }

    // "rejects project workspaces for chat but retains them on a project node"
    #[test]
    fn workspaces_belong_to_coding_nodes() {
        let dir = tempfile::tempdir().unwrap();
        let state = dir.path().to_str().unwrap();
        let workspaces = format!(r#"[{{"id":"project","path":{state:?}}}]"#);
        let env = node_env(state, &[("PIRC_WORKSPACES", &workspaces)]);
        fails(&env, NodeRole::Chat, "PIRC_WORKSPACES must be empty");
        let config = NodeConfig::load(&env, NodeRole::Node).unwrap();
        assert_eq!(config.workspaces[0].id, "project");
    }

    // "retains an explicit external agent command override"
    #[test]
    fn external_agent_command() {
        let dir = tempfile::tempdir().unwrap();
        let env = node_env(
            dir.path().to_str().unwrap(),
            &[
                ("PIRC_AGENT_COMMAND", "external-agent"),
                ("PIRC_AGENT_ARGS", r#"["rpc"]"#),
            ],
        );
        let config = NodeConfig::load(&env, NodeRole::Chat).unwrap();
        assert_eq!(config.agent_command, "external-agent");
        assert_eq!(config.agent_args, ["rpc"]);
        let env = node_env(
            dir.path().to_str().unwrap(),
            &[("PIRC_AGENT_COMMAND", "external-agent")],
        );
        assert_eq!(
            NodeConfig::load(&env, NodeRole::Node).unwrap().agent_args,
            ["agent"]
        );
    }

    #[test]
    fn defaults_and_directories() {
        let dir = tempfile::tempdir().unwrap();
        let state = dir.path().join("state");
        let config =
            NodeConfig::load(&node_env(state.to_str().unwrap(), &[]), NodeRole::Node).unwrap();
        assert_eq!(config.database_path, state.join("gateway.sqlite"));
        assert_eq!(config.sessions_dir, state.join("sessions"));
        assert!(config.sessions_dir.is_dir());
        assert!(config.uploads_dir.is_dir());
        assert_eq!(config.workspace_memory_dir, state.join("workspace-memory"));
        assert_eq!(config.config_dir, PathBuf::from("/home/test/.config/.pirc"));
        assert_eq!(config.memory_mirror_ms, 30_000);
        assert_eq!(config.rpc_max_line_bytes, 1_048_576);
        assert_eq!(config.upload_max_bytes, 10_485_760);
        assert!(config.terminals_enabled);
        assert_eq!(config.lease_ttl_ms, 30_000);
        assert_eq!(config.interaction_ttl_ms, 3_600_000);
        assert_eq!(config.shutdown_grace_ms, 5_000);
        assert_eq!(config.sandbox, SandboxSettings::default());
        assert!(!config.browser.enabled);
        // Nothing on the (empty) `PATH`: only an installed macOS bundle.
        let bundle = [
            "/Applications/Chromium.app/Contents/MacOS/Chromium",
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        ]
        .into_iter()
        .map(PathBuf::from)
        .find(|candidate| candidate.is_file());
        assert_eq!(config.browser.executable, bundle);
        assert_eq!(config.browser.gateway_host, "127.0.0.1");
        assert_eq!(config.browser.profiles_dir, state.join("browser"));
        assert_eq!(config.browser.ffmpeg, "ffmpeg");
        assert_eq!(
            config.browser.viewport,
            Viewport {
                width: 1280,
                height: 800
            }
        );
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(&state).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o700);
    }

    #[test]
    fn refusals() {
        let dir = tempfile::tempdir().unwrap();
        let state = dir.path().to_str().unwrap();
        let node = |extra: &[(&str, &str)], message: &str| {
            fails(&node_env(state, extra), NodeRole::Node, message);
        };
        node(&[("PIRC_SANDBOX", "off")], "PIRC_SANDBOX=off was removed");
        node(&[("PIRC_NODE_ID", "a b")], "Invalid PIRC_NODE_ID");
        node(&[("PIRC_NODE_TOKEN", "short")], "at least 32 characters");
        node(&[("PIRC_DAEMON_URL", "http://x")], "ws(s):// URL");
        node(&[("PIRC_DAEMON_URL", "WS://127.0.0.1")], "ws(s):// URL");
        node(
            &[("PIRC_DAEMON_URL", "ws://gateway.example:8787")],
            "requires wss:// off loopback",
        );
        node(&[("PIRC_ALLOWED_USERS", " ")], "PIRC_ALLOWED_USERS");
        node(&[("PIRC_UPLOAD_MAX_BYTES", "99999999")], "cannot exceed");
        node(
            &[("PIRC_AGENT_COMMAND", "a"), ("PIRC_AGENT_ARGS", "{}")],
            "PIRC_AGENT_ARGS",
        );
        node(&[("PIRC_WORKSPACES", "{}")], "JSON array");
        node(
            &[("PIRC_WORKSPACES", r#"[{"id":"x"}]"#)],
            "path is required",
        );
        node(
            &[("PIRC_WORKSPACES", r#"[{"id":"a b","path":"/"}]"#)],
            "id must match",
        );
        node(
            &[("PIRC_WORKSPACES", r#"[{"path":"/does/not/exist/pirc"}]"#)],
            "/does/not/exist/pirc",
        );
    }

    #[test]
    fn transports() {
        let dir = tempfile::tempdir().unwrap();
        let state = dir.path().to_str().unwrap();
        for url in [
            "ws://localhost:1",
            "ws://[::1]:1",
            "wss://gateway.example",
            "ws://127.0.0.1",
        ] {
            let env = node_env(state, &[("PIRC_DAEMON_URL", url)]);
            assert!(NodeConfig::load(&env, NodeRole::Node).is_ok(), "{url}");
        }
        let env = node_env(
            state,
            &[
                ("PIRC_DAEMON_URL", "ws://gateway.example"),
                ("PIRC_ALLOW_INSECURE_NODE_TRANSPORT", "yes"),
            ],
        );
        let config = NodeConfig::load(&env, NodeRole::Node).unwrap();
        assert_eq!(config.browser.gateway_host, "gateway.example");
        let env = node_env(state, &[("PIRC_DAEMON_URL", "ws://[::1]:8787")]);
        let config = NodeConfig::load(&env, NodeRole::Node).unwrap();
        assert_eq!(config.browser.gateway_host, "[::1]");
    }

    #[test]
    fn workspaces() {
        let dir = tempfile::tempdir().unwrap();
        let state = dir.path().join("state");
        let project = dir.path().join("project");
        std::fs::create_dir(&project).unwrap();
        let link = dir.path().join("link");
        std::os::unix::fs::symlink(&project, &link).unwrap();
        let value = serde_json::json!([
            { "path": link, "ignored": true },
            { "id": "named", "path": project, "displayName": "Named", "defaults": { "a": 1 } },
        ])
        .to_string();
        let env = node_env(state.to_str().unwrap(), &[("PIRC_WORKSPACES", &value)]);
        let config = NodeConfig::load(&env, NodeRole::Node).unwrap();
        let canonical = std::fs::canonicalize(&project).unwrap();
        assert_eq!(
            config.workspaces,
            [
                ConfigWorkspace {
                    id: "workspace-1".into(),
                    mode: ModeId::new("directory").unwrap(),
                    path: canonical.clone(),
                    display_name: "project".into(),
                    defaults: Map::new(),
                },
                ConfigWorkspace {
                    id: "named".into(),
                    mode: ModeId::new("directory").unwrap(),
                    path: canonical,
                    display_name: "Named".into(),
                    defaults: serde_json::json!({ "a": 1 }).as_object().unwrap().clone(),
                },
            ]
        );
    }

    #[test]
    fn mode_acceptance_is_explicit_and_validated() {
        assert_eq!(
            accepted_modes(None, NodeRole::Chat).unwrap()[0].as_str(),
            "pot"
        );
        assert_eq!(
            accepted_modes(None, NodeRole::Node).unwrap()[0].as_str(),
            "directory"
        );
        assert!(accepted_modes(Some(""), NodeRole::Node).unwrap().is_empty());
        let ids = accepted_modes(Some("directory, review"), NodeRole::Node).unwrap();
        assert_eq!(
            ids.iter().map(ModeId::as_str).collect::<Vec<_>>(),
            ["directory", "review"]
        );
        for invalid in ["review,review", "UPPER", "../review", "review,"] {
            assert!(
                accepted_modes(Some(invalid), NodeRole::Node).is_err(),
                "{invalid}"
            );
        }
        let dir = tempfile::tempdir().unwrap();
        let project = dir.path().join("project");
        std::fs::create_dir(&project).unwrap();
        let workspaces = serde_json::json!([{"path":project,"mode":"review"}]).to_string();
        let state = dir.path().join("state");
        let env = node_env(state.to_str().unwrap(), &[("PIRC_WORKSPACES", &workspaces)]);
        assert!(
            NodeConfig::load(&env, NodeRole::Node)
                .unwrap_err()
                .to_string()
                .contains("not accepted")
        );
        let env = node_env(
            state.to_str().unwrap(),
            &[
                ("PIRC_WORKSPACES", &workspaces),
                ("PIRC_MODES", "directory,review"),
            ],
        );
        assert_eq!(
            NodeConfig::load(&env, NodeRole::Node).unwrap().workspaces[0]
                .mode
                .as_str(),
            "review"
        );
    }

    #[test]
    fn browser_settings() {
        let dir = tempfile::tempdir().unwrap();
        let state = dir.path().to_str().unwrap();
        let bin = dir.path().join("bin");
        std::fs::create_dir(&bin).unwrap();
        let chromium = bin.join("chromium-browser");
        std::fs::write(&chromium, "").unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&chromium, std::fs::Permissions::from_mode(0o755)).unwrap();
        let path = format!("/nonexistent:{}", bin.display());
        let env = node_env(
            state,
            &[
                ("PATH", &path),
                ("PIRC_BROWSER_VIEWPORT", "9999x100"),
                ("PIRC_BROWSER_BLOCK_HOSTS", "a.example, b.example"),
                ("PIRC_FFMPEG", ""),
            ],
        );
        let config = NodeConfig::load(&env, NodeRole::Node).unwrap();
        assert_eq!(config.browser.executable, Some(chromium));
        assert_eq!(config.browser.ffmpeg, "ffmpeg");
        assert_eq!(config.browser.blocked_hosts, ["a.example", "b.example"]);
        assert_eq!(
            config.browser.viewport,
            Viewport {
                width: 3840,
                height: 240
            }
        );
        let env = node_env(state, &[("PIRC_BROWSER_EXECUTABLE", "/opt/chrome")]);
        let config = NodeConfig::load(&env, NodeRole::Node).unwrap();
        assert_eq!(
            config.browser.executable,
            Some(PathBuf::from("/opt/chrome"))
        );
        for bad in ["12x800", "1280x800x", "1280*800", "12800x800"] {
            assert_eq!(
                viewport(Some(bad)),
                Viewport {
                    width: 1280,
                    height: 800
                },
                "{bad}"
            );
        }
    }
}
