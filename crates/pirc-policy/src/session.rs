//! The per-session sandbox policy a node builds for each agent, ported from
//! `apps/gateway/src/sandbox-policy.ts` (`sessionPolicy`, `denyWriteAround`,
//! `sandboxConfigSchema`, `DEFAULT_ALLOWED_DOMAINS`, `LINUX_HOST_SOCKETS`,
//! `DOMAIN_PATTERN`) and `node/sandbox.ts` (`readAgentConfig`).
//!
//! Owner: **sandbox** (M6). Pure logic: `sandbox-policy.test.ts` is its
//! golden cases. Enforcement (srt's filesystem argument generation, macOS)
//! is M7. The types below are the interface the node's sandbox backends and
//! runner code against. srt's settings (`srtSettings`) are rendered by the
//! node's srt backend (`pirc_node::sandbox::srt`).

use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::{
    CACHE_HOME_PATHS, PathPolicy, SENSITIVE_HOME_PATHS, expand_home_path, is_inside, real_resolve,
    resolve_path,
};

/// `sandbox` in the node's agent `config.json` (never the project's),
/// `sandboxConfigSchema`: strict objects, every field defaulted.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SandboxConfig {
    #[serde(default)]
    pub network: NetworkConfig,
    #[serde(default)]
    pub filesystem: FilesystemConfig,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct NetworkConfig {
    /// Include `DEFAULT_ALLOWED_DOMAINS` (default true).
    #[serde(default = "yes")]
    pub default_domains: bool,
    /// Each matches [`valid_domain`].
    #[serde(default)]
    pub allowed_domains: Vec<String>,
    #[serde(default)]
    pub denied_domains: Vec<String>,
    /// Let dev servers listen on localhost (default true).
    #[serde(default = "yes")]
    pub allow_local_binding: bool,
    /// Extra Unix sockets the agent may reach (an ssh-agent, a container
    /// engine). macOS allows connecting to them; Linux leaves them visible,
    /// read back even inside a hidden directory (the native backend hides
    /// every other socket bound on the host but the inference socket and
    /// the nix daemon's; srt allows all), and one named here is no longer
    /// hidden as a `LINUX_HOST_SOCKETS` entry.
    #[serde(default)]
    pub allow_unix_sockets: Vec<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct FilesystemConfig {
    #[serde(default)]
    pub deny_read: Vec<String>,
    #[serde(default)]
    pub allow_read: Vec<String>,
    #[serde(default)]
    pub allow_write: Vec<String>,
    #[serde(default)]
    pub deny_write: Vec<String>,
    /// Let git write `.git/config`; off keeps hooks and fsmonitor out of reach.
    #[serde(default)]
    pub allow_git_config: bool,
}

fn yes() -> bool {
    true
}

impl Default for NetworkConfig {
    fn default() -> Self {
        Self {
            default_domains: true,
            allowed_domains: Vec::new(),
            denied_domains: Vec::new(),
            allow_local_binding: true,
            allow_unix_sockets: Vec::new(),
        }
    }
}

/// The platform a policy is built for (`process.platform`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Platform {
    Linux,
    Macos,
    Other,
}

impl Platform {
    pub fn current() -> Self {
        if cfg!(target_os = "linux") {
            Self::Linux
        } else if cfg!(target_os = "macos") {
            Self::Macos
        } else {
            Self::Other
        }
    }
}

/// `SessionPolicyInput`. Paths are absolute strings, as in [`PathPolicy`];
/// the TS defaults (`os.homedir()`, `process.platform`, `process.getuid()`,
/// `$SSH_AUTH_SOCK`) are the caller's to fill in.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SessionPolicyInput {
    pub config: SandboxConfig,
    /// Base for relative paths in `config` (the agent config directory).
    pub config_dir: String,
    pub home: String,
    /// pirc state no agent reads: the node's state dir and what it keeps elsewhere.
    pub private_dirs: Vec<String>,
    /// Where the agent works (the workspace, or a chat session's directory).
    pub workspace_root: String,
    /// Other paths the agent config allows writing (global `allowedPaths`).
    pub allowed_paths: Vec<String>,
    /// The session's own state (JSONL, team dir), inside `private_dirs`.
    pub session_dir: String,
    /// The one workspace-memory ledger the session may read and append to
    /// (its repository's; the node creates it), or none (chat sessions,
    /// read-only commands). Not the directory: every repository's ledger
    /// is there.
    pub workspace_memory_file: Option<String>,
    pub inference_socket: Option<String>,
    /// Shared write roots; one inside `private_dirs` (the session's own
    /// temp dir in the node's private parent) is read back as well.
    pub tmp_dirs: Vec<String>,
    /// Files next to the session that no agent may write (a project's instructions).
    pub protected_paths: Vec<String>,
    /// Directories inside `private_dirs` the session may read but never write.
    pub read_only_dirs: Vec<String>,
    /// Linux adds `LINUX_HOST_SOCKETS` to `deny_read`.
    pub platform: Platform,
    /// For `LINUX_HOST_SOCKETS`' `$UID`.
    pub uid: u32,
    /// For the agent's ssh-agent socket.
    pub ssh_auth_sock: Option<String>,
}

/// Mounted Windows account profiles are credential stores too. Reopen a
/// workspace beneath Users normally; never expose every Windows account just
/// because the node's Linux home has a deny list. Other mount roots can still
/// be protected explicitly with denyRead.
pub fn wsl_user_dirs(mount_root: &Path, kernel_release: &str) -> Result<Vec<String>, String> {
    if !kernel_release.to_ascii_lowercase().contains("microsoft") {
        return Ok(Vec::new());
    }
    let entries = match std::fs::read_dir(mount_root) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(_) => return Err("Cannot inspect WSL Windows user directories".to_owned()),
    };
    let mut out = Vec::new();
    for entry in entries {
        let entry = entry.map_err(|_| "Cannot inspect WSL Windows user directories")?;
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
        if name.len() != 1 || !name.as_bytes()[0].is_ascii_alphabetic() {
            continue;
        }
        let users = entry.path().join("Users");
        match std::fs::metadata(&users) {
            Ok(meta) if meta.is_dir() => out.push(users.display().to_string()),
            Ok(_) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(_) => return Err("Cannot inspect WSL Windows user directories".to_owned()),
        }
    }
    out.sort();
    Ok(out)
}

fn host_wsl_user_dirs(platform: Platform) -> Result<Vec<String>, String> {
    if platform != Platform::Linux {
        return Ok(Vec::new());
    }
    #[cfg(target_os = "linux")]
    {
        let kernel = std::fs::read_to_string("/proc/sys/kernel/osrelease")
            .map_err(|_| "Cannot inspect WSL kernel identity")?;
        wsl_user_dirs(Path::new("/mnt"), &kernel)
    }
    #[cfg(not(target_os = "linux"))]
    {
        Ok(Vec::new())
    }
}

/// `SessionPolicy`. The agent gets `paths` as `PIRC_SANDBOX_POLICY` (JSON).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionPolicy {
    pub paths: PathPolicy,
    pub network: NetworkPolicy,
    pub allow_git_config: bool,
    /// Not TS's, and never serialized (not in srt's settings, not in
    /// `PIRC_SANDBOX_POLICY`): the deny entries `paths` lists by their
    /// symlink-resolved target, with the symlinks crossed on the way.
    ///
    /// `paths` names a protected path by where it leads (`~/.ssh` linking
    /// to `/elsewhere/ssh` is denied as `/elsewhere/ssh`), so a sandbox
    /// enforcing only `paths` leaves the link itself replaceable when a
    /// writable root holds it (`~` in `allowedPaths`): the agent removes the
    /// link and puts a directory of its own in its place. Each backend keeps
    /// these links in place (macOS: move-blocking denies on each link and
    /// its ancestors) or refuses to start. Only entries that cross at least
    /// one link are listed; see [`session_policy`] for which entries.
    #[serde(skip)]
    pub linked_denies: Vec<LinkedPath>,
}

/// A deny entry spelled through symlinks ([`SessionPolicy::linked_denies`]).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct LinkedPath {
    /// The entry as given: absolute, `~` expanded, symlinks unresolved.
    pub spelled: String,
    /// What the policy lists for it (`real_resolve`).
    pub target: String,
    /// [`LinkWalk::links`] of `spelled`: every symlink crossed, in order.
    pub links: Vec<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NetworkPolicy {
    pub allowed_domains: Vec<String>,
    pub denied_domains: Vec<String>,
    pub allow_local_binding: bool,
    pub allow_unix_sockets: Vec<String>,
}

/// The node's agent `config.json` as the sandbox reads it (`AgentConfigView`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AgentConfigView {
    pub config_dir: String,
    /// `allowedPaths`, resolved against `config_dir` with `~` expanded.
    pub allowed_paths: Vec<String>,
    pub sandbox: SandboxConfig,
    /// Set when `config.json` is unreadable or its `sandbox` invalid (the
    /// defaults apply), or when it still has `sandbox.enabled: false`.
    pub problem: Option<String>,
}

/// Package registries and code hosts most builds need (`DEFAULT_ALLOWED_DOMAINS`).
pub const DEFAULT_ALLOWED_DOMAINS: [&str; 30] = [
    // Git hosting
    "github.com",
    "*.github.com",
    "*.githubusercontent.com",
    "ghcr.io",
    "gitlab.com",
    "codeberg.org",
    // JavaScript
    "registry.npmjs.org",
    "registry.yarnpkg.com",
    "bun.sh",
    "jsr.io",
    "npm.jsr.io",
    // Python
    "pypi.org",
    "files.pythonhosted.org",
    // Rust
    "crates.io",
    "*.crates.io",
    "static.rust-lang.org",
    // Go
    "proxy.golang.org",
    "sum.golang.org",
    // Nix
    "cache.nixos.org",
    "channels.nixos.org",
    "releases.nixos.org",
    "tarballs.nixos.org",
    "*.cachix.org",
    // JVM and Android
    "repo.maven.apache.org",
    "repo1.maven.org",
    "plugins.gradle.org",
    "services.gradle.org",
    "dl.google.com",
    // Ruby
    "rubygems.org",
    "index.rubygems.org",
];

/// Linux: sockets that hand out the host (container engines, the system
/// and session buses, systemd), hidden from the sandbox because Unix
/// sockets cannot be filtered by path there (`LINUX_HOST_SOCKETS`). `$UID`
/// is the node account's.
pub const LINUX_HOST_SOCKETS: [&str; 23] = [
    "/var/run/docker.sock",
    "/run/docker.sock",
    "/run/docker",
    "/run/containerd",
    "/run/podman",
    "/run/crio",
    "/var/run/libvirt",
    "/run/libvirt",
    "/run/lxd",
    "/var/snap/lxd/common/lxd",
    "/run/incus",
    "/var/lib/incus/unix.socket",
    "/run/dbus/system_bus_socket",
    "/var/run/dbus/system_bus_socket",
    "/run/systemd/private",
    "/run/systemd/io.systemd.Machine",
    "/run/systemd/userdb",
    "/run/user/$UID/docker.sock",
    "/run/user/$UID/podman",
    "/run/user/$UID/bus",
    "/run/user/$UID/systemd",
    "/run/user/$UID/gnupg",
    "/run/user/$UID/keyring",
];

/// The Linux host sockets [`session_policy`] hides (those that exist, as
/// spelled): [`LINUX_HOST_SOCKETS`] for `uid`, and the ssh-agent socket.
/// Not TS's name (TS built the list inline).
pub fn linux_host_sockets(uid: u32, ssh_auth_sock: Option<&str>) -> Vec<String> {
    let uid = uid.to_string();
    LINUX_HOST_SOCKETS
        .iter()
        .map(|item| item.replacen("$UID", &uid, 1))
        .chain(
            ssh_auth_sock
                .filter(|socket| !socket.is_empty())
                .map(str::to_owned),
        )
        .collect()
}

/// `DOMAIN_PATTERN` (case-insensitive): a host with an optional `*.` prefix,
/// `localhost`, or an IPv4 address, then an optional `:port`.
///
/// The regular expression, matched by hand:
/// `^((\*\.)?([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}|(\*\.)?localhost|(\d{1,3}\.){3}\d{1,3})(:\d{1,5})?$/i`.
/// No alternative contains `:` or backtracks across a `.`, so splitting on
/// them is exact. Without the `u` flag, JS's `i` folds ASCII letters only
/// (no `ſ` for `s`, no Kelvin sign for `k`), and `\d` is ASCII.
pub fn valid_domain(domain: &str) -> bool {
    let (host, port) = match domain.split_once(':') {
        Some((host, port)) => (host, Some(port)),
        None => (domain, None),
    };
    if let Some(port) = port
        && (!(1..=5).contains(&port.len()) || !port.bytes().all(|b| b.is_ascii_digit()))
    {
        return false;
    }
    let digits =
        |part: &str| (1..=3).contains(&part.len()) && part.bytes().all(|b| b.is_ascii_digit());
    let parts: Vec<&str> = host.split('.').collect();
    if parts.len() == 4 && parts.iter().all(|part| digits(part)) {
        return true;
    }
    let host = host.strip_prefix("*.").unwrap_or(host);
    if host.eq_ignore_ascii_case("localhost") {
        return true;
    }
    let labels: Vec<&str> = host.split('.').collect();
    let Some((top, rest)) = labels.split_last() else {
        return false;
    };
    let label = |part: &str| {
        let bytes = part.as_bytes();
        (1..=63).contains(&bytes.len())
            && bytes
                .iter()
                .all(|b| b.is_ascii_alphanumeric() || *b == b'-')
            && bytes[0] != b'-'
            && bytes[bytes.len() - 1] != b'-'
    };
    !rest.is_empty()
        && rest.iter().all(|part| label(part))
        && (2..=63).contains(&top.len())
        && top.bytes().all(|b| b.is_ascii_alphabetic())
}

/// A JSON value's type name, for "Expected X, received Y".
fn received(value: &serde_json::Value) -> &'static str {
    use serde_json::Value;
    match value {
        Value::Null => "null",
        Value::Bool(_) => "boolean",
        Value::Number(_) => "number",
        Value::String(_) => "string",
        Value::Array(_) => "array",
        Value::Object(_) => "object",
    }
}

/// The problems found while the `sandbox` config is read, each as
/// `<path>: <message>` (each object's known fields in schema order, then
/// its unrecognized keys in file order).
struct Issues(Vec<String>);

impl Issues {
    fn push(&mut self, path: &[String], message: impl std::fmt::Display) {
        let path = if path.is_empty() {
            "sandbox".to_owned()
        } else {
            format!("sandbox.{}", path.join("."))
        };
        self.0.push(format!("{path}: {message}"));
    }

    /// A strict object: `Some` with its fields when `value` is an object.
    fn object<'a>(
        &mut self,
        path: &[String],
        value: &'a serde_json::Value,
    ) -> Option<&'a serde_json::Map<String, serde_json::Value>> {
        let Some(object) = value.as_object() else {
            self.push(
                path,
                format_args!("Expected object, received {}", received(value)),
            );
            return None;
        };
        Some(object)
    }

    /// The strict object's unrecognized-keys issue, after its fields'.
    fn unrecognized(
        &mut self,
        path: &[String],
        object: &serde_json::Map<String, serde_json::Value>,
        shape: &[&str],
    ) {
        let extra: Vec<String> = object
            .keys()
            .filter(|key| !shape.contains(&key.as_str()))
            .map(|key| format!("'{key}'"))
            .collect();
        if !extra.is_empty() {
            self.push(path, format_args!("Unknown key(s): {}", extra.join(", ")));
        }
    }

    fn boolean(
        &mut self,
        path: &[String],
        value: Option<&serde_json::Value>,
        fallback: bool,
    ) -> bool {
        match value {
            None => fallback,
            Some(serde_json::Value::Bool(value)) => *value,
            Some(other) => {
                self.push(
                    path,
                    format_args!("Expected boolean, received {}", received(other)),
                );
                fallback
            }
        }
    }

    /// An optional array of strings (absent gives none); `check` is each
    /// string's own rule (its message when it fails).
    fn strings(
        &mut self,
        path: &[String],
        value: Option<&serde_json::Value>,
        check: fn(&str) -> Option<&'static str>,
    ) -> Vec<String> {
        let Some(value) = value else {
            return Vec::new();
        };
        let Some(items) = value.as_array() else {
            self.push(
                path,
                format_args!("Expected array, received {}", received(value)),
            );
            return Vec::new();
        };
        let mut out = Vec::new();
        for (index, item) in items.iter().enumerate() {
            let mut at = path.to_vec();
            at.push(index.to_string());
            match item.as_str() {
                None => self.push(
                    &at,
                    format_args!("Expected string, received {}", received(item)),
                ),
                Some(text) => match check(text) {
                    Some(message) => self.push(&at, message),
                    None => out.push(text.to_owned()),
                },
            }
        }
        out
    }
}

fn domain_check(text: &str) -> Option<&'static str> {
    (!valid_domain(text)).then_some("Invalid domain")
}

fn path_check(text: &str) -> Option<&'static str> {
    text.is_empty().then_some("Expected a non-empty string")
}

const SANDBOX_SHAPE: [&str; 2] = ["network", "filesystem"];
const NETWORK_SHAPE: [&str; 5] = [
    "defaultDomains",
    "allowedDomains",
    "deniedDomains",
    "allowLocalBinding",
    "allowUnixSockets",
];
const FILESYSTEM_SHAPE: [&str; 5] = [
    "denyRead",
    "allowRead",
    "allowWrite",
    "denyWrite",
    "allowGitConfig",
];

/// The `sandbox` section of `config.json`: `None` (absent) gives the
/// defaults; `Err` lists every problem found (`<path>: <message>; ...`).
pub fn parse_sandbox_config(value: Option<&serde_json::Value>) -> Result<SandboxConfig, String> {
    let mut issues = Issues(Vec::new());
    let mut config = SandboxConfig::default();
    if let Some(value) = value
        && let Some(root) = issues.object(&[], value)
    {
        let at = |key: &str| vec![key.to_owned()];
        if let Some(network) = root.get("network") {
            let path = at("network");
            if let Some(object) = issues.object(&path, network) {
                let field = |key: &str| {
                    let mut path = path.clone();
                    path.push(key.to_owned());
                    path
                };
                config.network = NetworkConfig {
                    default_domains: issues.boolean(
                        &field("defaultDomains"),
                        object.get("defaultDomains"),
                        true,
                    ),
                    allowed_domains: issues.strings(
                        &field("allowedDomains"),
                        object.get("allowedDomains"),
                        domain_check,
                    ),
                    denied_domains: issues.strings(
                        &field("deniedDomains"),
                        object.get("deniedDomains"),
                        domain_check,
                    ),
                    allow_local_binding: issues.boolean(
                        &field("allowLocalBinding"),
                        object.get("allowLocalBinding"),
                        true,
                    ),
                    allow_unix_sockets: issues.strings(
                        &field("allowUnixSockets"),
                        object.get("allowUnixSockets"),
                        path_check,
                    ),
                };
                issues.unrecognized(&path, object, &NETWORK_SHAPE);
            }
        }
        if let Some(filesystem) = root.get("filesystem") {
            let path = at("filesystem");
            if let Some(object) = issues.object(&path, filesystem) {
                let field = |key: &str| {
                    let mut path = path.clone();
                    path.push(key.to_owned());
                    path
                };
                config.filesystem = FilesystemConfig {
                    deny_read: issues.strings(
                        &field("denyRead"),
                        object.get("denyRead"),
                        path_check,
                    ),
                    allow_read: issues.strings(
                        &field("allowRead"),
                        object.get("allowRead"),
                        path_check,
                    ),
                    allow_write: issues.strings(
                        &field("allowWrite"),
                        object.get("allowWrite"),
                        path_check,
                    ),
                    deny_write: issues.strings(
                        &field("denyWrite"),
                        object.get("denyWrite"),
                        path_check,
                    ),
                    allow_git_config: issues.boolean(
                        &field("allowGitConfig"),
                        object.get("allowGitConfig"),
                        false,
                    ),
                };
                issues.unrecognized(&path, object, &FILESYSTEM_SHAPE);
            }
        }
        issues.unrecognized(&[], root, &SANDBOX_SHAPE);
    }
    if issues.0.is_empty() {
        Ok(config)
    } else {
        Err(issues.0.join("; "))
    }
}

/// `path.resolve(p)`: absolute against the process's working directory.
fn absolute(path: &str) -> String {
    let cwd = std::env::current_dir()
        .map(|p| p.display().to_string())
        .unwrap_or_else(|_| "/".to_owned());
    resolve_path(&cwd, path)
}

/// `path.join(dir, name)`: normalized, relative when `dir` is.
fn join(dir: &str, name: &str) -> String {
    if dir.starts_with('/') {
        resolve_path(dir, name)
    } else {
        Path::new(dir).join(name).display().to_string()
    }
}

/// `readAgentConfig`: `<config_dir>/config.json`'s `allowedPaths` and
/// `sandbox`, with the legacy `sandbox.enabled` dropped. Never fails:
/// problems are reported in [`AgentConfigView::problem`].
///
/// Error texts for an unreadable or malformed file are Rust's, not Bun's.
/// A `config.json` of `null` made TS throw (`raw.allowedPaths` of null);
/// here it counts as an empty object, like any other non-object.
pub fn read_agent_config(config_dir: &str, home: &str) -> AgentConfigView {
    let file = join(config_dir, "config.json");
    let defaults = |problem: Option<String>| AgentConfigView {
        config_dir: config_dir.to_owned(),
        allowed_paths: Vec::new(),
        sandbox: SandboxConfig::default(),
        problem,
    };
    let mut raw = serde_json::Map::new();
    if Path::new(&file).exists() {
        let parsed = std::fs::read_to_string(&file)
            .map_err(|error| error.to_string())
            .and_then(|text| {
                serde_json::from_str::<serde_json::Value>(&text).map_err(|error| error.to_string())
            });
        match parsed {
            Ok(serde_json::Value::Object(object)) => raw = object,
            Ok(_) => {}
            Err(message) => return defaults(Some(format!("{file}: {message}"))),
        }
    }
    let base = absolute(config_dir);
    let allowed_paths = raw
        .get("allowedPaths")
        .and_then(serde_json::Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(serde_json::Value::as_str)
                .map(|item| resolve_path(&base, &expand_home_path(item, home)))
                .collect()
        })
        .unwrap_or_default();
    // `enabled` turned the sandbox off before it became mandatory: drop it,
    // and say so when it asked for that.
    let mut sandbox = raw.get("sandbox").cloned();
    let mut legacy = None;
    if let Some(serde_json::Value::Object(object)) = &mut sandbox
        && let Some(enabled) = object.shift_remove("enabled")
        && enabled == serde_json::Value::Bool(false)
    {
        legacy = Some(format!(
            "{file}: \"sandbox.enabled\" is no longer supported; agents always run sandboxed"
        ));
    }
    match parse_sandbox_config(sandbox.as_ref()) {
        Ok(sandbox) => AgentConfigView {
            config_dir: config_dir.to_owned(),
            allowed_paths,
            sandbox,
            problem: legacy,
        },
        // Invalid settings must not loosen anything: keep the defaults.
        Err(issues) => AgentConfigView {
            config_dir: config_dir.to_owned(),
            allowed_paths,
            sandbox: SandboxConfig::default(),
            problem: Some(format!("{file}: invalid \"sandbox\": {issues}")),
        },
    }
}

/// `denyWriteAround`: `denyWrite` entries that close `dir` except `keep`
/// (paths inside it): every entry on the way to a kept path that does not
/// lead to one. srt has no "deny except", and its `denyWrite` always wins.
/// Entries are listed in directory order, as Bun's `readdirSync` gives them.
pub fn deny_write_around(dir: &str, keep: &[String]) -> Vec<String> {
    let inner: Vec<String> = keep
        .iter()
        .filter(|item| is_inside(item, dir))
        .cloned()
        .collect();
    if inner.iter().any(|item| item == dir) {
        return Vec::new();
    }
    if inner.is_empty() {
        return vec![dir.to_owned()];
    }
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    entries
        .flatten()
        .flat_map(|entry| {
            let name = entry.file_name();
            deny_write_around(&join(dir, &name.to_string_lossy()), &inner)
        })
        .collect()
}

/// What resolving a path crosses ([`walk_links`]).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LinkWalk {
    /// Every symlink the kernel crosses resolving the path, in order and
    /// without repeats, each named with its parent directory resolved (the
    /// path that removing or renaming the link names), a dangling one
    /// included; and every directory a link's target leaves through `..`
    /// (replacing it moves where the target leads too).
    pub links: Vec<String>,
    /// The path with every symlink resolved as far as it exists, the rest
    /// appended (what the kernel resolves the path to now).
    pub target: Result<String, WalkError>,
}

/// Why [`walk_links`] stopped before the end of the path.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum WalkError {
    /// More than 40 links (a loop).
    TooManyLinks,
    /// This link's target is not UTF-8.
    NotUtf8(String),
    /// This component cannot be examined (or its link not read).
    Unreadable(String),
}

/// Resolve absolute `path` one component at a time, as the kernel does:
/// a symlink's target is walked in its place (relative to the link's
/// directory), `..` leaves the directory reached so far. Stops at the
/// first component that does not exist (or is not a directory). Not TS's.
pub fn walk_links(path: &str) -> LinkWalk {
    let mut links: Vec<String> = Vec::new();
    let note = |links: &mut Vec<String>, path: &str| {
        if !links.iter().any(|link| link == path) {
            links.push(path.to_owned());
        }
    };
    let child = |dir: &str, name: &str| {
        if dir == "/" {
            format!("/{name}")
        } else {
            format!("{dir}/{name}")
        }
    };
    let parent = |dir: &str| match dir.rfind('/') {
        Some(0) | None => "/".to_owned(),
        Some(at) => dir[..at].to_owned(),
    };
    // The components still to walk, the next one last.
    let mut pending: Vec<String> = absolute(path).split('/').rev().map(str::to_owned).collect();
    let mut cursor = String::from("/");
    let mut count = 0;
    while let Some(part) = pending.pop() {
        match part.as_str() {
            "" | "." => continue,
            ".." => {
                if cursor != "/" {
                    note(&mut links, &cursor);
                }
                cursor = parent(&cursor);
                continue;
            }
            _ => {}
        }
        let next = child(&cursor, &part);
        match std::fs::symlink_metadata(&next) {
            Ok(meta) if meta.file_type().is_symlink() => {
                note(&mut links, &next);
                count += 1;
                if count > 40 {
                    return LinkWalk {
                        links,
                        target: Err(WalkError::TooManyLinks),
                    };
                }
                let target = match std::fs::read_link(&next) {
                    Ok(target) => target,
                    Err(_) => {
                        return LinkWalk {
                            links,
                            target: Err(WalkError::Unreadable(next)),
                        };
                    }
                };
                let Some(target) = target.to_str() else {
                    return LinkWalk {
                        links,
                        target: Err(WalkError::NotUtf8(next)),
                    };
                };
                if target.starts_with('/') {
                    cursor = "/".to_owned();
                }
                pending.extend(target.split('/').rev().map(str::to_owned));
            }
            Ok(_) => cursor = next,
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::NotFound | std::io::ErrorKind::NotADirectory
                ) =>
            {
                let rest: Vec<String> = std::iter::once(part)
                    .chain(pending.into_iter().rev())
                    .collect();
                return LinkWalk {
                    links,
                    target: Ok(resolve_path(&cursor, &rest.join("/"))),
                };
            }
            Err(_) => {
                return LinkWalk {
                    links,
                    target: Err(WalkError::Unreadable(next)),
                };
            }
        }
    }
    LinkWalk {
        links,
        target: Ok(cursor),
    }
}

const MODE_PATHS_ERROR: &str = "Cannot safely inspect mode configuration paths";

/// Protect the mode catalog and the targets of its top-level `.md` files,
/// including dangling symlinks. Only directory entries and path metadata are
/// inspected: mode sources are never opened or parsed by policy/agent loading.
/// A missing catalog is allowed, but unreadable paths and link cycles fail
/// closed. `walk_links` preserves kernel ordering for symlink targets with `..`.
/// The sandbox must also pin the links of these paths via `linked_denies`.
pub fn mode_write_paths(config_dir: &str) -> Result<Vec<String>, String> {
    let dir = join(config_dir, "modes");
    let protect = |path: &str| -> Result<Vec<String>, String> {
        let walk = walk_links(path);
        let target = walk
            .target
            .map_err(|error| format!("{MODE_PATHS_ERROR}: {error:?}"))?;
        let mut paths = vec![absolute(path), target];
        // A dangling chain cannot be canonicalized by PathGuard: retain each
        // link spelling too, so replacing an intermediate link is denied.
        // `links` also records directories left by `..`; do not make those
        // whole trees read-only (one may be the writable workspace itself).
        for link in walk.links {
            let metadata = std::fs::symlink_metadata(&link)
                .map_err(|error| format!("{MODE_PATHS_ERROR}: {link}: {error}"))?;
            if metadata.file_type().is_symlink() {
                paths.push(link);
            }
        }
        Ok(paths)
    };
    let mut paths = protect(&dir)?;
    let entries = match std::fs::read_dir(&dir) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(unique(paths));
        }
        Err(error) => return Err(format!("{MODE_PATHS_ERROR}: {dir}: {error}")),
    };
    let mut files = Vec::new();
    for entry in entries {
        let entry = entry.map_err(|error| format!("{MODE_PATHS_ERROR}: {dir}: {error}"))?;
        let path = entry.path();
        if path.extension().is_some_and(|extension| extension == "md") {
            let path = path
                .to_str()
                .ok_or_else(|| format!("{MODE_PATHS_ERROR}: mode path is not UTF-8"))?;
            files.push(path.to_owned());
        }
    }
    files.sort();
    for file in files {
        paths.extend(protect(&file)?);
    }
    Ok(unique(paths))
}

/// [`LinkedPath`] for `spelled` when resolving it crosses a link.
pub fn linked_path(spelled: &str) -> Option<LinkedPath> {
    let walk = walk_links(spelled);
    (!walk.links.is_empty()).then(|| LinkedPath {
        spelled: absolute(spelled),
        target: real_resolve(spelled),
        links: walk.links,
    })
}

/// Items in first-seen order without repeats (`[...new Set(items)]`).
fn unique(items: impl IntoIterator<Item = String>) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for item in items {
        if !out.contains(&item) {
            out.push(item);
        }
    }
    out
}

/// `existsSync` (follows symlinks).
fn exists(path: &str) -> bool {
    Path::new(path).exists()
}

/// `sessionPolicy`: what one session's agent may read, write and reach.
///
/// `Err` where TS threw: a prompt configuration file behind too many (or
/// looping) symlinks, or a component of its path that cannot be examined.
/// Mode catalog metadata likewise fails closed when it cannot be inspected.
///
/// [`SessionPolicy::linked_denies`] (not TS's) covers every deny entry the
/// policy resolves: the sensitive home paths, the private dirs, the
/// read-only dirs, the protected paths, the mode catalog and its sources,
/// the agent config dir and the
/// configured `denyRead` / `denyWrite` entries.
pub fn session_policy(input: &SessionPolicyInput) -> Result<SessionPolicy, String> {
    let home = input.home.as_str();
    let config_dir = absolute(&input.config_dir);
    let configured = |items: &[String]| -> Vec<String> {
        items
            .iter()
            .map(|item| real_resolve(&resolve_path(&config_dir, &expand_home_path(item, home))))
            .collect()
    };
    let resolve_all =
        |items: &[String]| -> Vec<String> { items.iter().map(|item| real_resolve(item)).collect() };
    let workspace = real_resolve(&input.workspace_root);
    let session_dir = real_resolve(&input.session_dir);
    let memory_file: Vec<String> = input
        .workspace_memory_file
        .iter()
        .map(|file| real_resolve(file))
        .collect();
    let inference_socket = input
        .inference_socket
        .as_deref()
        .filter(|socket| !socket.is_empty());
    let socket_dir = inference_socket.map(|socket| {
        let parent = Path::new(&absolute(socket))
            .parent()
            .map_or_else(|| "/".to_owned(), |p| p.display().to_string());
        real_resolve(&parent)
    });
    let tmp_dirs = resolve_all(&input.tmp_dirs);
    let read_only_dirs = resolve_all(&input.read_only_dirs);
    let private_dirs = resolve_all(&input.private_dirs);
    let sensitive_spelled: Vec<String> = SENSITIVE_HOME_PATHS
        .iter()
        .map(|item| resolve_path(home, item))
        .filter(|item| exists(item))
        .collect();
    let sensitive: Vec<String> = sensitive_spelled
        .iter()
        .map(|item| real_resolve(item))
        .collect();
    let wsl_spelled = host_wsl_user_dirs(input.platform)?;
    let wsl_denies = resolve_all(&wsl_spelled);
    let host_sockets: Vec<String> = if input.platform == Platform::Linux {
        let allowed = configured(&input.config.network.allow_unix_sockets);
        linux_host_sockets(input.uid, input.ssh_auth_sock.as_deref())
            .into_iter()
            .filter(|item| exists(item))
            .filter(|item| !allowed.contains(&real_resolve(item)))
            .collect()
    } else {
        Vec::new()
    };
    let SandboxConfig {
        filesystem,
        network,
    } = &input.config;
    // Host caches are executable inputs to future host builds/browsers. They
    // are readable, never shared writable roots. Each sandbox gets private
    // tool cache locations beneath its own temporary directory.
    let host_caches: Vec<String> = CACHE_HOME_PATHS
        .iter()
        .map(|item| real_resolve(&resolve_path(home, item)))
        .collect();
    let shared_write = unique(tmp_dirs.iter().cloned());
    let allow_write = unique(
        [workspace.clone()]
            .into_iter()
            .chain(resolve_all(&input.allowed_paths))
            .chain([session_dir.clone()])
            .chain(memory_file.iter().cloned())
            .chain(shared_write.iter().cloned())
            .chain(configured(&filesystem.allow_write)),
    );
    // What a session may write inside the node's private dirs: its own
    // state, and its own temp dir (the node keeps every session's temp dir
    // in a private parent, so sessions cannot reach each other's).
    // Not in TS, whose temp dirs sat beside each other.
    let private_tmp_dirs: Vec<String> = tmp_dirs
        .iter()
        .filter(|tmp| private_dirs.iter().any(|dir| is_inside(tmp, dir)))
        .cloned()
        .collect();
    let own_state: Vec<String> = [workspace.clone(), session_dir.clone()]
        .into_iter()
        .chain(memory_file.iter().cloned())
        .chain(private_tmp_dirs.iter().cloned())
        .collect();
    let mode_paths = mode_write_paths(&input.config_dir)?;
    let git_dir = Path::new(&workspace).join(".git").is_dir();
    let paths = PathPolicy {
        deny_read: unique(
            private_dirs
                .iter()
                .cloned()
                .chain(sensitive.iter().cloned())
                .chain(wsl_denies)
                .chain(host_sockets)
                .chain(configured(&filesystem.deny_read)),
        ),
        // What the session needs back from inside the private dirs. A chat
        // session's directory lives in the node's state.
        allow_read: unique(
            [workspace.clone(), session_dir.clone()]
                .into_iter()
                .chain(memory_file.iter().cloned())
                .chain(socket_dir)
                // Linux hides sockets by read rules only: one the config
                // allows is read back even inside a hidden directory (an
                // ssh-agent's in `/tmp/ssh-*`).
                .chain(
                    configured(&network.allow_unix_sockets)
                        .into_iter()
                        .filter(|_| input.platform == Platform::Linux),
                )
                .chain(private_tmp_dirs)
                .chain(read_only_dirs.iter().cloned())
                .chain(configured(&filesystem.allow_read)),
        ),
        allow_write: allow_write.clone(),
        // The project's agent config; pirc keeps uploads and recordings
        // there itself, from outside the sandbox. Credential stores and the
        // node's private state stay closed even when a writable root
        // contains them (a workspace holding the state dir, `~` in
        // allowedPaths).
        deny_write: unique(
            [resolve_path(&workspace, ".pirc")]
                .into_iter()
                // A nonexistent .git must remain creatable (git init/clone).
                // Worktree .git files have no hooks/config children either.
                .chain(git_dir.then(|| resolve_path(&workspace, ".git/hooks")))
                .chain(
                    (git_dir && !filesystem.allow_git_config)
                        .then(|| resolve_path(&workspace, ".git/config")),
                )
                // User-managed global configuration stays read-only even under
                // an allowed root.
                .chain([real_resolve(&input.config_dir)])
                .chain(mode_paths.iter().cloned())
                .chain(resolve_all(&input.protected_paths))
                .chain(sensitive)
                .chain(host_caches)
                .chain(read_only_dirs)
                .chain(
                    private_dirs
                        .iter()
                        .filter(|dir| allow_write.iter().any(|root| is_inside(dir, root)))
                        .flat_map(|dir| deny_write_around(dir, &own_state)),
                )
                .chain(configured(&filesystem.deny_write)),
        ),
        shared_write: Some(shared_write),
    };
    let configured_spelled = |items: &[String]| -> Vec<String> {
        items
            .iter()
            .map(|item| resolve_path(&config_dir, &expand_home_path(item, home)))
            .collect()
    };
    let linked_denies: Vec<LinkedPath> = unique(
        sensitive_spelled
            .into_iter()
            .chain(wsl_spelled)
            .chain(input.private_dirs.iter().map(|dir| absolute(dir)))
            .chain(CACHE_HOME_PATHS.iter().map(|item| resolve_path(home, item)))
            .chain(input.read_only_dirs.iter().map(|dir| absolute(dir)))
            .chain(input.protected_paths.iter().map(|path| absolute(path)))
            .chain(mode_paths)
            .chain([config_dir.clone()])
            .chain(configured_spelled(&filesystem.deny_read))
            .chain(configured_spelled(&filesystem.deny_write)),
    )
    .iter()
    .filter_map(|spelled| linked_path(spelled))
    .collect();
    Ok(SessionPolicy {
        paths,
        linked_denies,
        network: NetworkPolicy {
            allowed_domains: unique(
                DEFAULT_ALLOWED_DOMAINS
                    .iter()
                    .filter(|_| network.default_domains)
                    .map(|item| (*item).to_owned())
                    .chain(network.allowed_domains.iter().cloned()),
            ),
            denied_domains: unique(network.denied_domains.iter().cloned()),
            allow_local_binding: network.allow_local_binding,
            allow_unix_sockets: unique(
                inference_socket
                    .iter()
                    .map(|socket| real_resolve(socket))
                    .chain(configured(&network.allow_unix_sockets)),
            ),
        },
        allow_git_config: filesystem.allow_git_config,
    })
}

/// Golden cases (the srt settings case is with the node's srt backend),
/// the sandbox config's issue reports and `DOMAIN_PATTERN` verdicts.
#[cfg(test)]
mod tests;
