//! What the srt and native backends share (`node/sandbox.ts`): the cached
//! probe, a session's policy with its warnings, and its temporary
//! directory. Owner: **sandbox** (M6); M7: `readonly_session` is **hardening**'s.

use std::future::Future;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use pirc_config::{Env, NodeConfig};
use pirc_policy::session::{
    NetworkPolicy, Platform, SessionPolicy, SessionPolicyInput, read_agent_config, session_policy,
};
use pirc_policy::{is_inside, real_resolve};
use tokio::io::AsyncReadExt;

use super::{PrepareInput, SandboxStatus};
use crate::error::{ApiError, ApiResult};

/// How long a probe may take before it counts as failed.
pub const PROBE_TIMEOUT: Duration = Duration::from_secs(30);
/// How long a failed probe stands before the next agent start probes again
/// (`PROBE_RETRY_MS`).
pub const PROBE_RETRY: Duration = Duration::from_secs(30);

/// `NodeSandbox.check`'s cache: a success holds for the node's life, a
/// failure for [`PROBE_RETRY`]. Concurrent checks share one probe (TS
/// shared the promise).
#[derive(Default)]
pub struct ProbeCache {
    state: tokio::sync::Mutex<Option<(SandboxStatus, Option<Instant>)>>,
}

impl ProbeCache {
    pub async fn get<F, Fut>(&self, probe: F) -> SandboxStatus
    where
        F: FnOnce() -> Fut,
        Fut: Future<Output = SandboxStatus>,
    {
        let mut state = self.state.lock().await;
        if let Some((status, failed_at)) = &*state
            && failed_at.is_none_or(|at| at.elapsed() <= PROBE_RETRY)
        {
            return status.clone();
        }
        let status = probe().await;
        let failed_at = matches!(status, SandboxStatus::Unavailable { .. }).then(Instant::now);
        *state = Some((status.clone(), failed_at));
        status
    }
}

/// Run a probe command (`<name>` in the reasons) and judge it as TS's
/// `probe` did: exit 0 within [`PROBE_TIMEOUT`] is a working sandbox;
/// otherwise the last three lines of its output say why.
///
/// Reasons keep TS's words; a spawn failure carries Rust's error text.
pub async fn run_probe(
    name: &str,
    mut command: tokio::process::Command,
    description: String,
) -> SandboxStatus {
    command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(error) => {
            return SandboxStatus::Unavailable {
                reason: format!("{name}: {error}"),
            };
        }
    };
    // Both streams into one buffer, the last 2,000 characters kept.
    let output = Arc::new(Mutex::new(String::new()));
    let mut readers = Vec::new();
    let streams: [Option<Box<dyn tokio::io::AsyncRead + Unpin + Send>>; 2] = [
        child.stdout.take().map(|s| Box::new(s) as _),
        child.stderr.take().map(|s| Box::new(s) as _),
    ];
    for mut stream in streams.into_iter().flatten() {
        let output = output.clone();
        readers.push(tokio::spawn(async move {
            let mut buffer = [0u8; 4096];
            while let Ok(read) = stream.read(&mut buffer).await {
                if read == 0 {
                    break;
                }
                let mut text = output.lock().unwrap_or_else(|p| p.into_inner());
                text.push_str(&String::from_utf8_lossy(&buffer[..read]));
                let count = text.chars().count();
                if count > 2000 {
                    let cut = text
                        .char_indices()
                        .nth(count - 2000)
                        .map_or(0, |(at, _)| at);
                    text.drain(..cut);
                }
            }
        }));
    }
    let status = match tokio::time::timeout(PROBE_TIMEOUT, child.wait()).await {
        Err(_) => {
            let _ = child.start_kill();
            for reader in readers {
                reader.abort();
            }
            return SandboxStatus::Unavailable {
                reason: format!("{name} did not answer within 30 seconds"),
            };
        }
        Ok(Err(error)) => {
            return SandboxStatus::Unavailable {
                reason: format!("{name}: {error}"),
            };
        }
        Ok(Ok(status)) => status,
    };
    // TS judged on `exit` with what had arrived; give the pipes a moment
    // to drain, without waiting on a grandchild that keeps them open.
    for reader in readers {
        let _ = tokio::time::timeout(Duration::from_secs(1), reader).await;
    }
    if status.success() {
        return SandboxStatus::Active { description };
    }
    let text = output.lock().unwrap_or_else(|p| p.into_inner()).clone();
    let lines: Vec<&str> = text.trim().split('\n').collect();
    let tail = lines[lines.len().saturating_sub(3)..].join(" ");
    let code = status
        .code()
        .map_or_else(|| "null".to_owned(), |code| code.to_string());
    SandboxStatus::Unavailable {
        reason: format!(
            "{name} cannot sandbox on this host (exit {code}): {}",
            if tail.is_empty() { "no output" } else { &tail }
        ),
    }
}

/// `os.tmpdir()`: `$TMPDIR`, `$TMP`, `$TEMP` or `/tmp`, without a trailing
/// slash.
pub fn tmpdir(env: &Env) -> PathBuf {
    let dir = ["TMPDIR", "TMP", "TEMP"]
        .iter()
        .find_map(|name| env.get(name).filter(|value| !value.is_empty()))
        .unwrap_or("/tmp");
    let trimmed = if dir.len() > 1 {
        dir.trim_end_matches('/')
    } else {
        dir
    };
    PathBuf::from(if trimmed.is_empty() { "/" } else { trimmed })
}

/// `mkdtempSync(<base>/<prefix>)`: a new 0700 directory with six random
/// characters after `prefix`.
pub fn make_temp_dir(base: &Path, prefix: &str) -> std::io::Result<PathBuf> {
    const CHARS: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    loop {
        let random = crate::util::random_bytes::<6>();
        let suffix: String = random
            .iter()
            .map(|byte| CHARS[usize::from(*byte) % CHARS.len()] as char)
            .collect();
        let dir = base.join(format!("{prefix}{suffix}"));
        match std::fs::DirBuilder::new().mode(0o700).create(&dir) {
            Ok(()) => return Ok(dir),
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(error) => return Err(error),
        }
    }
}

/// The node's private parent of every session's temporary directory,
/// `<TMPDIR>/pirc-n-XXXXXX` (0700), made on first use and made again when
/// it is gone or no longer the node's own private directory. Not TS's,
/// whose session directories sat side by side in `TMPDIR`: every sandbox
/// runs as the node's uid and may read the filesystem and write `/tmp`,
/// so their 0700 mode kept no session from another's files and proxy
/// socket. The parent is one of every session's private directories
/// (closed to reads, its own temporary directory reopened). What keeps a
/// session out of the others' depends on the backend:
///
/// - Linux, native and srt: an empty tmpfs over the parent, so neither
///   reads nor writes reach the others' directories.
/// - macOS, native: the read deny, and a write deny on the parent but for
///   the session's own directory (`macos::profile::TempParent`).
/// - macOS, srt: the read deny only. With the parent in a write root
///   (`TMPDIR` unset or `/tmp`), a session can write into the directories
///   of sessions started after it; [`NodeTmp::with_writable_siblings`]
///   makes [`session`] warn about it.
///
/// Its name is short, as the sessions' are (macOS's 104-byte socket
/// paths). Registered parents remain after shutdown to keep peer mount plans valid.
#[derive(Clone)]
pub struct NodeTmp(Arc<NodeTmpDir>);

struct NodeTmpDir {
    base: PathBuf,
    config: NodeConfig,
    env: Env,
    dir: Mutex<Option<PathBuf>>,
    /// The backend's sandboxes do not keep writes out of the parent.
    writable_siblings: bool,
}

impl NodeTmp {
    /// For a backend whose sandboxes keep each session out of the others'
    /// temporary directories.
    pub fn new(config: &NodeConfig, env: &Env) -> Self {
        Self::with(config, env, false)
    }

    /// For a backend whose sandboxes hide the parent from reads only (srt
    /// on macOS): [`session`] warns when the parent lies in a write root.
    pub fn with_writable_siblings(config: &NodeConfig, env: &Env) -> Self {
        Self::with(config, env, true)
    }

    fn with(config: &NodeConfig, env: &Env, writable_siblings: bool) -> Self {
        Self(Arc::new(NodeTmpDir {
            base: tmpdir(env),
            config: config.clone(),
            env: env.clone(),
            dir: Mutex::new(None),
            writable_siblings,
        }))
    }

    /// The parent, made when needed.
    pub fn dir(&self) -> std::io::Result<PathBuf> {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};
        let mut dir = self.0.dir.lock().unwrap_or_else(|p| p.into_inner());
        let private = |path: &Path| {
            std::fs::symlink_metadata(path).is_ok_and(|meta| {
                meta.is_dir()
                    && meta.uid() == nix::unistd::getuid().as_raw()
                    && meta.permissions().mode() & 0o077 == 0
            })
        };
        if let Some(existing) = dir.as_deref()
            && private(existing)
        {
            pirc_config::registry::register_node(&self.0.config, &self.0.env, Some(existing))?;
            return Ok(existing.to_path_buf());
        }
        let made = make_temp_dir(&self.0.base, "pirc-n-")?;
        if let Err(error) =
            pirc_config::registry::register_node(&self.0.config, &self.0.env, Some(&made))
        {
            let _ = std::fs::remove_dir(&made);
            return Err(error);
        }
        *dir = Some(made.clone());
        Ok(made)
    }

    /// A new session temporary directory in the parent, and the parent.
    pub fn make_session_dir(&self) -> std::io::Result<(PathBuf, PathBuf)> {
        let parent = self.dir()?;
        let tmp = make_temp_dir(&parent, "pirc-")?;
        Ok((tmp, parent))
    }
}

// Registered parents remain present after shutdown: another sandbox may have
// planned a denial mount there. SessionTmp still removes each session's content.

/// Tool caches belong to this sandbox; none can poison a host build/browser.
/// The programs create these directories lazily, and SessionTmp removes them.
pub fn private_cache_env(tmp: &str) -> Vec<(String, String)> {
    [
        ("XDG_CACHE_HOME", "cache"),
        ("CARGO_HOME", "cargo"),
        ("BUN_INSTALL_CACHE_DIR", "bun"),
        ("npm_config_cache", "npm"),
        ("NPM_CONFIG_CACHE", "npm"),
        ("YARN_CACHE_FOLDER", "yarn"),
        ("PIP_CACHE_DIR", "pip"),
        ("GOCACHE", "go-build"),
        ("GOMODCACHE", "go-mod"),
        ("GRADLE_USER_HOME", "gradle"),
    ]
    .into_iter()
    .map(|(key, leaf)| (key.to_owned(), format!("{tmp}/{leaf}")))
    .collect()
}

/// `<state>/sandbox`, made 0700 when missing.
pub fn sandbox_state_dir(config: &NodeConfig) -> std::io::Result<PathBuf> {
    let dir = config.state_dir.join("sandbox");
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(&dir)?;
    Ok(dir)
}

/// `sandboxBinDir`: where TS's built-in srt kept its seccomp helper. The
/// Rust node has none, but the directory stays in the policy as a
/// read-only directory, so the policy (and the srt settings the
/// conformance scenarios record) keeps TS's shape.
pub fn sandbox_bin_dir(config: &NodeConfig) -> PathBuf {
    config.state_dir.join("sandbox").join("bin")
}

/// A session's (or read-only command's) temporary directory, removed when
/// dropped: a prepare future dropped mid-await (node shutdown during a
/// probe) leaves nothing behind. The backends move it into
/// [`super::Prepared`]'s cleanup, which removes it at the latest.
#[derive(Debug)]
pub struct SessionTmp(PathBuf);

impl SessionTmp {
    pub fn new(dir: PathBuf) -> Self {
        Self(dir)
    }
}

impl std::ops::Deref for SessionTmp {
    type Target = Path;

    fn deref(&self) -> &Path {
        &self.0
    }
}

impl Drop for SessionTmp {
    fn drop(&mut self) {
        Session::remove_tmp(&self.0);
    }
}

/// A session's policy and what goes with it, before the backend wraps it.
pub struct Session {
    /// The session's own temporary directory (`CLAUDE_CODE_TMPDIR`).
    pub tmp: SessionTmp,
    pub policy: SessionPolicy,
    pub warnings: Vec<String>,
}

impl Session {
    /// Remove the temporary directory (a failed start, or the cleanup).
    pub fn remove_tmp(tmp: &Path) {
        let _ = std::fs::remove_dir_all(tmp);
    }
}

fn text(path: &Path) -> String {
    path.display().to_string()
}

/// [`session`] on tokio's blocking pool: it reads the agent config, makes
/// directories and resolves dozens of paths.
pub async fn spawn_session(
    config: &NodeConfig,
    env: &Env,
    node_tmp: &NodeTmp,
    input: &PrepareInput,
) -> ApiResult<Session> {
    let (config, env, node_tmp, input) =
        (config.clone(), env.clone(), node_tmp.clone(), input.clone());
    tokio::task::spawn_blocking(move || session(&config, &env, &node_tmp, &input))
        .await
        .map_err(|_| ApiError::internal())?
}

/// [`readonly_session`] on tokio's blocking pool.
pub async fn spawn_readonly_session(
    config: &NodeConfig,
    env: &Env,
    node_tmp: &NodeTmp,
    input: &super::ReadonlyInput,
) -> ApiResult<Session> {
    let (config, env, node_tmp, input) =
        (config.clone(), env.clone(), node_tmp.clone(), input.clone());
    tokio::task::spawn_blocking(move || readonly_session(&config, &env, &node_tmp, &input))
        .await
        .map_err(|_| ApiError::internal())?
}

/// Make a session's workspace-memory ledger when it is missing: the
/// sandbox opens that one file (bubblewrap binds only what exists), not
/// the directory. Never through a symlink, and only a regular file of this
/// account with no other name: an agent of an older node could write the
/// whole directory, and a hard link it left there would open another file
/// to the session.
fn ensure_ledger(file: &Path) -> std::io::Result<()> {
    use nix::fcntl::OFlag;
    use std::os::unix::fs::MetadataExt;
    if let Some(dir) = file.parent() {
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(dir)?;
    }
    let opened = std::fs::OpenOptions::new()
        .append(true)
        .create(true)
        .mode(0o600)
        .custom_flags((OFlag::O_NOFOLLOW | OFlag::O_NONBLOCK | OFlag::O_NOCTTY).bits())
        .open(file)?;
    let meta = opened.metadata()?;
    if !meta.is_file() {
        return Err(std::io::Error::other("not a regular file"));
    }
    if meta.nlink() != 1 || meta.uid() != nix::unistd::getuid().as_raw() {
        return Err(std::io::Error::other(
            "not a file of this account with one name",
        ));
    }
    Ok(())
}

/// The first half of `NodeSandbox.prepare`: read the agent config, make
/// the session's temporary directory, build the policy and the warnings.
pub fn session(
    config: &NodeConfig,
    env: &Env,
    node_tmp: &NodeTmp,
    input: &PrepareInput,
) -> ApiResult<Session> {
    let home = text(&env.home());
    let agent_config = read_agent_config(&text(&config.config_dir), &home);
    // The session's own temporary directory: TMPDIR inside the sandbox,
    // and the only temp dir it may write besides /tmp. Kept short: srt may
    // put Unix sockets there, and macOS caps their paths at 104 bytes.
    let (tmp, parent) = node_tmp.make_session_dir().map_err(|error| {
        crate::log::error(&format!(
            "cannot make the session's temp directory: {error}"
        ));
        ApiError::internal()
    })?;
    let tmp = SessionTmp::new(tmp);
    let mut warnings = Vec::new();
    if let Some(problem) = &agent_config.problem {
        warnings.push(format!("Sandbox settings ignored: {problem}"));
    }
    let private_dirs = private_dirs(config, env, &parent);
    let mut registered_dirs = registered_private_dirs(env)?;
    registered_dirs.extend(private_dirs.iter().cloned());
    // Recovery roots are node-owned private state. All cooperating nodes must
    // reject ordinary/nested-root execution, which would bypass the writer lock.
    let recovery_stores: Vec<String> = registered_dirs
        .iter()
        .map(|dir| real_resolve(&text(&Path::new(dir).join("checkpoints/workspaces"))))
        // No phantom deny paths/placeholders in nodes that have never prepared
        // a recovery. The registered private state still closes the whole tree.
        .filter(|dir| Path::new(dir).is_dir())
        .collect();
    let root = real_resolve(&text(&input.workspace_root));
    if input.recovery.is_none() && recovery_stores.iter().any(|dir| is_inside(&root, dir)) {
        return Err(ApiError::bad_request(
            "Recovery execution requires a fresh isolated continuation ticket",
        ));
    }
    if let Some(ticket) = &input.recovery {
        ticket
            .check_session(&input.session_id)
            .map_err(ApiError::bad_request)?;
    }
    if input.recovery.is_some() && input.workspace_memory_file.is_some() {
        return Err(ApiError::bad_request(
            "Recovery must start without inherited memory or project state",
        ));
    }
    let workspace_memory_file =
        input
            .workspace_memory_file
            .as_deref()
            .and_then(|file| match ensure_ledger(file) {
                Ok(()) => Some(text(file)),
                Err(error) => {
                    warnings.push(format!(
                        "Workspace memory is unavailable: cannot open {}: {error}",
                        file.display()
                    ));
                    None
                }
            });
    let brokered = config.agent_args.first().is_some_and(|arg| arg == "agent");
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(&input.session_dir)
        .map_err(|_| ApiError::internal())?;
    let mut protected_paths: Vec<String> = input.protected_paths.iter().map(|p| text(p)).collect();
    if brokered {
        protected_paths.push(text(&input.session_dir));
        protected_paths.extend(workspace_memory_file.iter().cloned());
    }
    let mut policy_input = SessionPolicyInput {
        config: agent_config.sandbox,
        config_dir: agent_config.config_dir,
        home,
        private_dirs: registered_dirs,
        workspace_root: text(&input.workspace_root),
        allowed_paths: agent_config.allowed_paths,
        session_dir: text(&input.session_dir),
        workspace_memory_file,
        inference_socket: input.inference_socket.as_deref().map(text),
        tmp_dirs: vec![text(&tmp), "/tmp".to_owned()],
        protected_paths,
        read_only_dirs: [text(&sandbox_bin_dir(config))].into_iter().collect(),
        platform: Platform::current(),
        uid: nix::unistd::getuid().as_raw(),
        ssh_auth_sock: env.get("SSH_AUTH_SOCK").map(str::to_owned),
    };
    // C6a: explicit grants join the same policy every backend enforces. A deny
    // closes reads and writes and overrides any overlapping grant.
    for grant in &input.grants {
        let path = text(&grant.path);
        match grant.access {
            crate::grants::Access::Write => policy_input.allowed_paths.push(path),
            crate::grants::Access::Read => policy_input.read_only_dirs.push(path),
            crate::grants::Access::Deny => {
                policy_input.config.filesystem.deny_read.push(path.clone());
                policy_input.config.filesystem.deny_write.push(path);
            }
        }
    }
    // Explicitly keep recovery stores closed even for a broadly writable
    // workspace containing the state directory. Reopen only a ticket's root.
    for store in recovery_stores {
        policy_input.config.filesystem.deny_read.push(store.clone());
        let keep = input
            .recovery
            .as_ref()
            .map(|r| text(r.root()))
            .into_iter()
            .collect::<Vec<_>>();
        policy_input
            .config
            .filesystem
            .deny_write
            .extend(pirc_policy::session::deny_write_around(&store, &keep));
    }
    if let Some(recovery) = &input.recovery {
        recovery
            .constrain(&mut policy_input)
            .map_err(ApiError::bad_request)?;
    }
    let policy = match session_policy(&policy_input) {
        Ok(policy) => policy,
        Err(error) => {
            // TS threw here (and left the temp directory behind).
            Session::remove_tmp(&tmp);
            crate::log::error(&format!(
                "cannot build the session's sandbox policy: {error}"
            ));
            return Err(ApiError::internal());
        }
    };
    // The temp parent may sit in a write root (`/tmp`) by design, where
    // the backend keeps writes out of it ([`NodeTmp`]); otherwise it is
    // exposed as state is.
    let node_tmp_dir = real_resolve(&text(&parent));
    let private_dirs: Vec<String> = private_dirs.iter().map(|dir| real_resolve(dir)).collect();
    let inside = |dir: &str, root: &str| is_inside(dir, root) && dir != root;
    let exposed = |dir_filter: &dyn Fn(&String) -> bool| -> Vec<&str> {
        policy
            .paths
            .allow_write
            .iter()
            .filter(|root| {
                let root = real_resolve(root);
                private_dirs
                    .iter()
                    .filter(|dir| dir_filter(dir))
                    .any(|dir| inside(dir, &root))
            })
            .map(String::as_str)
            .collect()
    };
    let state = exposed(&|dir| *dir != node_tmp_dir);
    if !state.is_empty() {
        warnings.push(format!(
            "pirc's state lies inside a writable path of this session ({}). What exists now is protected, but anything the node creates there later (other sessions) is not: move PIRC_STATE_DIR out of it.",
            state.join(", ")
        ));
    }
    let temp = exposed(&|dir| *dir == node_tmp_dir);
    if node_tmp.0.writable_siblings && !temp.is_empty() {
        warnings.push(format!(
            "pirc's temporary directory lies inside a writable path of this session ({}), and this sandbox does not keep sessions out of each other's temporary directories there: set the node's TMPDIR outside it.",
            temp.join(", ")
        ));
    }
    Ok(Session {
        tmp,
        policy,
        warnings,
    })
}

/// The node's private directories: closed to reads (`deny_read`) unless
/// the policy reopens a part. `node_tmp` is [`NodeTmp`]'s parent.
///
/// As spelled: `session_policy` resolves them for its lists, and keeps a
/// spelling through symlinks in `linked_denies`, which the native Linux
/// backend checks for links the agent could replace.
fn private_dirs(config: &NodeConfig, env: &Env, node_tmp: &Path) -> Vec<String> {
    pirc_config::registry::node_private_dirs(config, env)
        .into_iter()
        .chain([node_tmp.to_path_buf()])
        .map(|dir| text(&dir))
        .collect()
}

fn registered_private_dirs(env: &Env) -> ApiResult<Vec<String>> {
    pirc_config::registry::private_dirs(env).map_err(|error| {
        crate::log::error(&format!("cannot read private-directory registry: {error}"));
        ApiError::internal()
    })
}

/// The policy and temporary directory of a read-only command for
/// `input.workspace_root` ([`super::Sandbox::prepare_readonly`], the Git
/// panel's `git`, security audit S8). Owner: **hardening** (M7).
///
/// Reads are a session's: `session_policy` with [`session`]'s inputs, the
/// workspace standing in for the session directory (there is no session
/// of its own, so nothing is reopened beyond what the workspace's sessions
/// share), no inference socket. Writes are removed but a fresh temporary
/// directory (`allow_write` and `shared_write` are only `tmp`, not `/tmp`
/// nor the cache directories, `deny_write` is empty as nothing else is
/// writable); the network is closed (no domains, no local binding, no Unix
/// sockets); `.git/config` is never writable. A problem in the agent
/// config is a warning, as for a session.
pub fn readonly_session(
    config: &NodeConfig,
    env: &Env,
    node_tmp: &NodeTmp,
    input: &super::ReadonlyInput,
) -> ApiResult<Session> {
    let home = text(&env.home());
    let agent_config = read_agent_config(&text(&config.config_dir), &home);
    let (tmp, parent) = node_tmp.make_session_dir().map_err(|error| {
        crate::log::error(&format!(
            "cannot make a read-only sandbox's temp directory: {error}"
        ));
        ApiError::internal()
    })?;
    let tmp = SessionTmp::new(tmp);
    let mut warnings = Vec::new();
    if let Some(problem) = &agent_config.problem {
        warnings.push(format!("Sandbox settings ignored: {problem}"));
    }
    let workspace = text(&input.workspace_root);
    let mut private_dirs = private_dirs(config, env, &parent);
    private_dirs.extend(registered_private_dirs(env)?);
    let policy_input = SessionPolicyInput {
        config: agent_config.sandbox,
        config_dir: agent_config.config_dir,
        home,
        private_dirs,
        workspace_root: workspace.clone(),
        allowed_paths: agent_config.allowed_paths,
        session_dir: workspace,
        workspace_memory_file: None,
        inference_socket: None,
        tmp_dirs: vec![text(&tmp)],
        protected_paths: Vec::new(),
        read_only_dirs: vec![text(&sandbox_bin_dir(config))],
        platform: Platform::current(),
        uid: nix::unistd::getuid().as_raw(),
        ssh_auth_sock: env.get("SSH_AUTH_SOCK").map(str::to_owned),
    };
    let mut policy = match session_policy(&policy_input) {
        Ok(policy) => policy,
        Err(error) => {
            Session::remove_tmp(&tmp);
            crate::log::error(&format!("cannot build a read-only sandbox policy: {error}"));
            return Err(ApiError::internal());
        }
    };
    let writable = real_resolve(&text(&tmp));
    policy.paths.allow_write = vec![writable.clone()];
    policy.paths.deny_write = Vec::new();
    policy.paths.shared_write = Some(vec![writable]);
    policy.network = NetworkPolicy::default();
    policy.allow_git_config = false;
    Ok(Session {
        tmp,
        policy,
        warnings,
    })
}

/// A node configuration in a temporary directory, for the backends' tests.
#[cfg(test)]
pub(super) mod test_support {
    use std::path::Path;

    use pirc_config::{Env, NodeConfig};
    use pirc_protocol::NodeRole;

    /// `<root>/workspace` (with a file), `<root>/home`, `<root>/state`,
    /// `<root>/config` and `<root>/tmp` (`TMPDIR`); `extra` adds variables.
    pub fn node(root: &Path, extra: &[(&str, &str)]) -> (NodeConfig, Env) {
        for dir in ["workspace", "home", "state", "config", "tmp"] {
            std::fs::create_dir_all(root.join(dir)).unwrap();
        }
        std::fs::write(root.join("workspace/README.md"), "hi\n").unwrap();
        let path = |name: &str| root.join(name).display().to_string();
        let (home, state, config, tmp) = (path("home"), path("state"), path("config"), path("tmp"));
        let mut vars = vec![
            ("PIRC_NODE_ID", "test-node"),
            ("PIRC_NODE_TOKEN", "0123456789abcdef0123456789abcdef"),
            ("PIRC_DAEMON_URL", "ws://127.0.0.1:8787"),
            ("PIRC_ALLOWED_USERS", "test-user"),
            ("PIRC_STATE_DIR", state.as_str()),
            ("PIRC_CONFIG_DIR", config.as_str()),
            ("PIRC_BROWSER", "false"),
            ("HOME", home.as_str()),
            ("TMPDIR", tmp.as_str()),
        ];
        vars.extend_from_slice(extra);
        let env = Env::new(vars, root);
        (NodeConfig::load(&env, NodeRole::Node).unwrap(), env)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn readonly_sessions_read_as_a_session_and_write_only_their_temp_dir() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        std::fs::create_dir_all(root.join("config")).unwrap();
        std::fs::write(
            root.join("config/config.json"),
            r#"{"allowedPaths":["~"],"sandbox":{"network":{"allowedDomains":["example.com"],"allowLocalBinding":true},"filesystem":{"denyRead":["~/secret"],"allowWrite":["/var/tmp"]}}}"#,
        )
        .unwrap();
        let (config, env) = test_support::node(&root, &[]);
        let node_tmp = NodeTmp::new(&config, &env);
        let workspace = root.join("workspace");
        let input = super::super::ReadonlyInput {
            workspace_root: workspace.clone(),
            command: vec!["git".into()],
        };
        let Session {
            tmp,
            policy,
            warnings,
        } = readonly_session(&config, &env, &node_tmp, &input).unwrap();
        assert!(warnings.is_empty(), "{warnings:?}");
        assert!(tmp.is_dir() && tmp.starts_with(root.join("tmp")), "{tmp:?}");
        let text = |path: &Path| path.display().to_string();
        // Writes: the temp directory only.
        assert_eq!(policy.paths.allow_write, [text(&tmp)]);
        assert_eq!(policy.paths.shared_write, Some(vec![text(&tmp)]));
        assert!(policy.paths.deny_write.is_empty());
        assert!(!policy.allow_git_config);
        assert_eq!(policy.network, NetworkPolicy::default());
        // Reads: a session's.
        assert!(policy.paths.allow_read.contains(&text(&workspace)));
        // The node's temp parent is private, its own temp dir read back.
        let parent = tmp.parent().unwrap().to_path_buf();
        assert!(policy.paths.allow_read.contains(&text(&tmp)));
        for denied in [root.join("state"), root.join("home/secret"), parent] {
            assert!(
                policy.paths.deny_read.contains(&text(&denied)),
                "{denied:?} in {:?}",
                policy.paths.deny_read
            );
        }
        Session::remove_tmp(&tmp);

        // A broken agent config warns and keeps the defaults.
        std::fs::write(root.join("config/config.json"), r#"{"sandbox":{"x":1}}"#).unwrap();
        let session = readonly_session(&config, &env, &node_tmp, &input).unwrap();
        assert_eq!(session.warnings.len(), 1, "{:?}", session.warnings);
        Session::remove_tmp(&session.tmp);
    }

    #[test]
    fn folder_grants_join_the_session_policy_and_deny_wins() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        let (config, env) = test_support::node(&root, &[]);
        let node_tmp = NodeTmp::new(&config, &env);
        let workspace = root.join("workspace");
        let shared = root.join("shared");
        let secret = workspace.join("secrets");
        for path in [&workspace, &shared, &secret] {
            std::fs::create_dir_all(path).unwrap();
        }
        let grant = |path: &Path, access| crate::grants::FolderGrant {
            grant_id: "g".into(),
            path: path.to_path_buf(),
            access,
            created_at: 1,
        };
        let input = super::super::PrepareInput {
            grants: vec![
                grant(&shared, crate::grants::Access::Write),
                grant(&secret, crate::grants::Access::Deny),
            ],
            recovery: None,
            session_id: "s".into(),
            workspace_root: workspace.clone(),
            session_dir: root.join("state/sessions/s"),
            inference_socket: None,
            protected_paths: Vec::new(),
            workspace_memory_file: None,
        };
        let Session { tmp, policy, .. } = session(&config, &env, &node_tmp, &input).unwrap();
        let text = |path: &Path| path.display().to_string();
        assert!(
            policy.paths.allow_write.contains(&text(&shared)),
            "{:?}",
            policy.paths.allow_write
        );
        // A deny inside the writable workspace closes reads and writes there.
        assert!(
            policy.paths.deny_read.contains(&text(&secret)),
            "{:?}",
            policy.paths.deny_read
        );
        assert!(
            policy.paths.deny_write.contains(&text(&secret)),
            "{:?}",
            policy.paths.deny_write
        );
        Session::remove_tmp(&tmp);
    }

    #[test]
    fn session_temp_dirs_share_the_nodes_private_parent() {
        use std::os::unix::fs::PermissionsExt;
        // The node's temp parent in `/tmp`, a write root of every session;
        // its state preferably outside it (the target directory).
        let base = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../target");
        std::fs::create_dir_all(&base).unwrap();
        let dir = tempfile::tempdir_in(&base).unwrap();
        let root = dir.path().canonicalize().unwrap();
        let state_in_tmp = is_inside(&text(&root), &real_resolve("/tmp"));
        let (config, env) = test_support::node(&root, &[("TMPDIR", "/tmp")]);
        let node_tmp = NodeTmp::new(&config, &env);
        let input = |name: &str| PrepareInput {
            grants: Vec::new(),
            session_id: name.to_owned(),
            workspace_root: root.join("workspace"),
            session_dir: config.sessions_dir.join(name),
            inference_socket: None,
            protected_paths: Vec::new(),
            workspace_memory_file: None,
            recovery: None,
        };
        let a = session(&config, &env, &node_tmp, &input("pi_a")).unwrap();
        let b = session(&config, &env, &node_tmp, &input("pi_b")).unwrap();
        let parent = a.tmp.parent().unwrap().to_path_buf();
        assert_eq!(b.tmp.parent(), Some(parent.as_path()));
        let name = parent.file_name().unwrap().to_string_lossy().into_owned();
        assert!(name.starts_with("pirc-n-") && name.len() == 13, "{name}");
        let mode = std::fs::metadata(&parent).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o700);
        // Inside `/tmp`, a write root of every session, by design: no
        // warning about it. A checkout under `/tmp` puts the node's state
        // there too, which warns as it should.
        let expected: &[&str] = if state_in_tmp {
            &["pirc's state lies inside a writable path of this session"]
        } else {
            &[]
        };
        assert_eq!(a.warnings.len(), expected.len(), "{:?}", a.warnings);
        for (warning, start) in a.warnings.iter().zip(expected) {
            assert!(warning.starts_with(start), "{warning}");
        }
        // The policy holds resolved paths (`/tmp` is `/private/tmp` on
        // macOS).
        let resolved = |tmp: &Path| real_resolve(&text(&tmp.join("x")));
        for (own, other) in [(&a, &b), (&b, &a)] {
            let paths = &own.policy.paths;
            assert!(pirc_policy::read_allowed(paths, &resolved(&own.tmp)));
            assert!(pirc_policy::write_allowed(paths, &resolved(&own.tmp)));
            assert!(!pirc_policy::read_allowed(paths, &resolved(&other.tmp)));
        }
        // A parent that is gone is made again.
        Session::remove_tmp(&a.tmp);
        Session::remove_tmp(&b.tmp);
        std::fs::remove_dir(&parent).unwrap();
        let c = session(&config, &env, &node_tmp, &input("pi_c")).unwrap();
        assert!(c.tmp.is_dir());
        Session::remove_tmp(&c.tmp);
        let parent = c.tmp.parent().unwrap().to_path_buf();
        drop(node_tmp);
        assert!(parent.exists(), "registered parent remains for peer mounts");
        std::fs::remove_dir(parent).unwrap();
    }

    #[test]
    fn a_temp_parent_in_a_write_root_warns_where_sandboxes_let_writes_in() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        // The node's `TMPDIR` is a write root of the session, as `/tmp` is.
        std::fs::create_dir_all(root.join("config")).unwrap();
        let settings = serde_json::json!({
            "sandbox": {"filesystem": {"allowWrite": [text(&root.join("tmp"))]}}
        });
        std::fs::write(root.join("config/config.json"), settings.to_string()).unwrap();
        let (config, env) = test_support::node(&root, &[]);
        let input = PrepareInput {
            grants: Vec::new(),
            session_id: "pi_a".to_owned(),
            workspace_root: root.join("workspace"),
            session_dir: config.sessions_dir.join("pi_a"),
            inference_socket: None,
            protected_paths: Vec::new(),
            workspace_memory_file: None,
            recovery: None,
        };
        let temp_warning = |node_tmp: &NodeTmp| {
            let session = session(&config, &env, node_tmp, &input).unwrap();
            Session::remove_tmp(&session.tmp);
            // Only this warning: the checkout (and so `root`) may itself
            // lie in a write root, which warns about the node's state.
            session
                .warnings
                .iter()
                .any(|warning| warning.contains("pirc's temporary directory"))
        };
        assert!(!temp_warning(&NodeTmp::new(&config, &env)));
        assert!(temp_warning(&NodeTmp::with_writable_siblings(
            &config, &env
        )));
    }

    /// A session gets its own ledger back from the workspace-memory
    /// directory, wherever `PIRC_WORKSPACE_MEMORY_DIR` puts it, and nothing
    /// else there; a ledger planted as a symlink or a hard link is refused
    /// with a warning.
    #[test]
    fn a_session_opens_only_its_own_ledger() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        let memory = root.join("elsewhere/memory");
        let memory_text = text(&memory);
        let (config, env) =
            test_support::node(&root, &[("PIRC_WORKSPACE_MEMORY_DIR", &memory_text)]);
        assert_eq!(config.workspace_memory_dir, memory);
        let node_tmp = NodeTmp::new(&config, &env);
        let input = |file: &str| PrepareInput {
            grants: Vec::new(),
            session_id: "pi_a".to_owned(),
            workspace_root: root.join("workspace"),
            session_dir: config.sessions_dir.join("pi_a"),
            inference_socket: None,
            protected_paths: Vec::new(),
            workspace_memory_file: Some(memory.join(file)),
            recovery: None,
        };
        // Another repository's ledger (one not yet made would be writable
        // where the directory lies in a write root, such as `/tmp` here
        // on Linux: an accepted gap of private state there).
        std::fs::create_dir_all(&memory).unwrap();
        std::fs::write(memory.join("other.jsonl"), "").unwrap();
        let opened = session(&config, &env, &node_tmp, &input("k.jsonl")).unwrap();
        Session::remove_tmp(&opened.tmp);
        let paths = &opened.policy.paths;
        let own = text(&memory.join("k.jsonl"));
        let other = text(&memory.join("other.jsonl"));
        assert!(memory.join("k.jsonl").is_file(), "made by the node");
        assert!(pirc_policy::read_allowed(paths, &own));
        assert!(
            !pirc_policy::write_allowed(paths, &own),
            "builtin agent persists through the node"
        );
        assert!(!pirc_policy::read_allowed(paths, &other));
        assert!(!pirc_policy::write_allowed(paths, &other));

        std::fs::write(root.join("secret"), "x").unwrap();
        std::os::unix::fs::symlink(root.join("secret"), memory.join("link.jsonl")).unwrap();
        std::fs::hard_link(root.join("secret"), memory.join("hard.jsonl")).unwrap();
        for planted in ["link.jsonl", "hard.jsonl"] {
            let refused = session(&config, &env, &node_tmp, &input(planted)).unwrap();
            Session::remove_tmp(&refused.tmp);
            assert!(
                refused
                    .warnings
                    .iter()
                    .any(|warning| warning.starts_with("Workspace memory is unavailable")),
                "{planted}: {:?}",
                refused.warnings
            );
            let refused_paths = &refused.policy.paths;
            let planted_path = text(&memory.join(planted));
            assert!(!refused_paths.allow_write.contains(&planted_path));
            assert!(!refused_paths.allow_read.contains(&planted_path));
            assert!(
                !pirc_policy::read_allowed(refused_paths, &text(&memory.join(planted))),
                "{planted}"
            );
        }
    }

    #[test]
    fn tmpdir_follows_node() {
        let env = |vars: &[(&str, &str)]| Env::new(vars.iter().copied(), "/");
        assert_eq!(tmpdir(&env(&[])), PathBuf::from("/tmp"));
        assert_eq!(tmpdir(&env(&[("TMPDIR", "/x/")])), PathBuf::from("/x"));
        assert_eq!(
            tmpdir(&env(&[("TMP", "/y"), ("TEMP", "/z")])),
            PathBuf::from("/y")
        );
        assert_eq!(tmpdir(&env(&[("TMPDIR", "/")])), PathBuf::from("/"));
    }

    #[test]
    fn temp_dirs_are_private_and_distinct() {
        use std::os::unix::fs::PermissionsExt;
        let base = tempfile::tempdir().unwrap();
        let a = make_temp_dir(base.path(), "pirc-").unwrap();
        let b = make_temp_dir(base.path(), "pirc-").unwrap();
        assert_ne!(a, b);
        let name = a.file_name().unwrap().to_string_lossy().into_owned();
        assert!(name.starts_with("pirc-") && name.len() == 11, "{name}");
        let mode = std::fs::metadata(&a).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o700);
    }

    #[tokio::test]
    async fn probes_are_cached_and_failures_retried_after_30_seconds() {
        let cache = ProbeCache::default();
        let calls = std::sync::atomic::AtomicUsize::new(0);
        let failing = || async {
            calls.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            SandboxStatus::Unavailable {
                reason: "no".into(),
            }
        };
        cache.get(failing).await;
        cache.get(failing).await;
        assert_eq!(calls.load(std::sync::atomic::Ordering::SeqCst), 1);
        // `Instant` is the std one: the paused tokio clock does not move
        // it, so the retry is checked through the cache's own state.
        *cache.state.lock().await = Some((
            SandboxStatus::Unavailable {
                reason: "no".into(),
            },
            Instant::now().checked_sub(PROBE_RETRY + Duration::from_millis(1)),
        ));
        let ok = || async {
            calls.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            SandboxStatus::Active {
                description: "yes".into(),
            }
        };
        assert!(matches!(cache.get(ok).await, SandboxStatus::Active { .. }));
        assert!(matches!(
            cache.get(failing).await,
            SandboxStatus::Active { .. }
        ));
        assert_eq!(calls.load(std::sync::atomic::Ordering::SeqCst), 2);
    }

    #[tokio::test]
    async fn probe_reasons_read_as_in_typescript() {
        let mut command = tokio::process::Command::new("/bin/sh");
        command.args([
            "-c",
            "echo one; echo two >&2; echo three; echo four; exit 3",
        ]);
        let status = run_probe("srt", command, "x".into()).await;
        let SandboxStatus::Unavailable { reason } = status else {
            panic!("{status:?}");
        };
        // The streams interleave; the last three lines are joined.
        assert!(
            reason.starts_with("srt cannot sandbox on this host (exit 3): "),
            "{reason}"
        );
        assert_eq!(reason.matches(' ').count(), 10, "{reason}");
        let mut quiet = tokio::process::Command::new("/bin/sh");
        quiet.args(["-c", "exit 1"]);
        assert_eq!(
            run_probe("srt", quiet, "x".into()).await,
            SandboxStatus::Unavailable {
                reason: "srt cannot sandbox on this host (exit 1): no output".into()
            }
        );
        let mut ok = tokio::process::Command::new("/bin/sh");
        ok.args(["-c", "exit 0"]);
        assert_eq!(
            run_probe("srt", ok, "ready".into()).await,
            SandboxStatus::Active {
                description: "ready".into()
            }
        );
        let missing = tokio::process::Command::new("/nonexistent/srt");
        let SandboxStatus::Unavailable { reason } = run_probe("srt", missing, "x".into()).await
        else {
            panic!()
        };
        assert!(reason.starts_with("srt: "), "{reason}");
    }
}
