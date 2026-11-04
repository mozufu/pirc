//! The OS sandbox every agent runs in (`node/sandbox.ts` `NodeSandbox`).
//! There is no way around it: when no backend can sandbox on this host, no
//! agent starts (503 `runner_unavailable`).
//!
//! Layout: the [`Sandbox`] trait, its input and output types and
//! [`Prepared`]'s plumbing are implemented here. M7 owners (one worker
//! each; anything else in the crate is the parent's):
//!
//! | Module | Owner |
//! | --- | --- |
//! | [`linux`] (filesystem plan, uid 0, read-only sandbox), `tests/sandbox_native.rs`, CI | **linux-fs** |
//! | [`proxy`], [`bridge`] | **network** |
//! | [`macos`], [`create`] | **macos** |
//! | [`srt`], [`unavailable`], [`common`]`::readonly_session`, `panels/inspect.rs` and its callers, `terminals.rs`, `pirc-ptc`'s guest | **hardening** |
//!
//! Backends:
//!
//! - [`srt`]: `PIRC_SANDBOX_SRT`, an external srt-compatible wrapper
//!   (`<srt> --settings <file> --control-fd 3 -- <agent...>`, settings 0600
//!   in `<state>/sandbox/<session>.json`, approvals as a whole new settings
//!   line on fd 3). The development stand-in, used by the conformance
//!   harness's fake srt. It has TS's gaps, which the native backends
//!   close: on Linux the host's name-service sockets (nscd,
//!   systemd-resolved) stay visible, since srt renders the policy's host
//!   sockets only (the native plan adds `linux::plan::RESOLVER_SOCKETS`);
//!   srt's own proxy sockets (`claude-http-*.sock`, `claude-socks-*.sock`)
//!   sit in its `os.tmpdir()`, the node's `TMPDIR`, where every srt
//!   session sees them; and on macOS a session can write into later
//!   sessions' temp directories when `TMPDIR` lies in a write root
//!   (`common::NodeTmp`, which warns).
//! - [`linux`]: the native backend from `spikes/linux-sandbox`: bubblewrap
//!   with srt's argument order, a filtering proxy in the node process whose
//!   allowlist grows in place on approval, and the in-sandbox bridge
//!   ([`bridge`], the `pirc-node sandbox-bridge` helper).
//! - [`macos`]: Seatbelt (`sandbox-exec` with srt's SBPL profile) and the
//!   same filtering proxy on a loopback TCP port.
//! - [`unavailable`]: other platforms.
//!
//! [`Sandbox::prepare_readonly`] wraps one host command (the Git panel's
//! `git`, security audit S8) in a sandbox that may read what a session of
//! the workspace may read, write nothing (but its temp directory) and reach
//! no network: no route out, and with the native Linux backend the host's
//! name-service sockets hidden too (another host daemon's visible socket
//! is the residual risk, see [`linux`]; the [`srt`] stand-in leaves them
//! visible).
//!
//! Each session's temporary directory sits in the node's private parent
//! of them all (`common::NodeTmp`), which keeps sessions out of each
//! other's directories and (native Linux) proxy sockets; how far depends
//! on the backend, see there.
//!
//! `check` probes once (`/bin/sh -c 'exit 0'` in the sandbox, 30 s
//! deadline); success holds for the node's life, a failure is probed again
//! after 30 s. `prepare` reads the agent config
//! (`pirc_policy::session::read_agent_config`), makes the session's temp
//! directory, builds the policy (`pirc_policy::session::session_policy`)
//! with the node's private directories, and warns about config problems
//! and state inside a writable path (the temp parent too, on a backend
//! that does not keep writes out of it).

pub mod bridge;
mod common;
pub mod fds;
pub(crate) mod launch_guard;
pub mod linux;
pub mod macos;
pub mod processes;
pub mod proxy;
pub mod srt;
pub(crate) mod terminal_gate;
pub mod unavailable;

use std::ffi::OsString;
use std::future::Future;
use std::path::PathBuf;
use std::pin::Pin;
use std::sync::{Arc, Mutex};

use pirc_config::{Env, NodeConfig};
use pirc_policy::session::SessionPolicy;

use crate::error::{ApiError, ApiResult};

pub type BoxFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

/// The internal subcommand the native backend runs inside the sandbox.
pub const BRIDGE_SUBCOMMAND: &str = "sandbox-bridge";

/// Whether agents can start.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SandboxStatus {
    /// `description` is logged ("agent sandbox ready").
    Active {
        description: String,
    },
    Unavailable {
        reason: String,
    },
}

/// What a session's sandbox is built from (`prepare`'s input).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PrepareInput {
    /// Trusted continuation ticket; never populated by ordinary session startup.
    pub recovery: Option<crate::checkpoints::isolation::RecoveryIsolation>,
    pub session_id: String,
    /// `chat::session_root`: the workspace, or the chat session's directory.
    pub workspace_root: PathBuf,
    /// The session's private directory (its `session.jsonl`).
    pub session_dir: PathBuf,
    /// The node's inference socket.
    pub inference_socket: Option<PathBuf>,
    /// Never writable from the session (a chat project's instructions).
    pub protected_paths: Vec<PathBuf>,
    /// The workspace-memory ledger made by the node when missing. Builtin
    /// agents read it directly and append through node persistence; the rest
    /// of the directory stays closed.
    pub workspace_memory_file: Option<PathBuf>,
    /// A chat project's files, which the session may read but never write
    /// (the node changes them while the session runs).
    pub project_files_dir: Option<PathBuf>,
}

/// A host command to run read-only ([`Sandbox::prepare_readonly`]).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ReadonlyInput {
    /// The workspace whose read policy applies (the session policy a
    /// session of it would get, every write removed).
    pub workspace_root: PathBuf,
    /// The program and its arguments. The caller sets `cwd`, environment
    /// and stdio on [`Prepared::command`].
    pub command: Vec<OsString>,
}

/// The sandbox backend.
pub trait Sandbox: Send + Sync {
    /// Guarded PTY launches with a kernel-owned descendant scope. No host fallback.
    fn isolated_terminals(&self) -> bool {
        false
    }
    fn prepare_terminal(
        &self,
        _input: PrepareInput,
        _shell: PathBuf,
    ) -> BoxFuture<'_, ApiResult<Prepared>> {
        Box::pin(async {
            Err(ApiError::new(
                503,
                "isolated_terminal_unavailable",
                "This backend cannot launch a guarded isolated work terminal",
            ))
        })
    }

    /// Native per-session proxy ownership, independent of runner cleanup.
    /// External wrappers cannot supply this proof through an empty default.
    fn network_scopes(&self) -> Option<&proxy::Scopes> {
        None
    }

    /// Whether this host can sandbox (cached as described above).
    fn check(&self) -> BoxFuture<'_, SandboxStatus>;

    /// A session's sandbox, or 503 [`unavailable_error`]. The caller calls
    /// [`Prepared::cleanup`] when the agent exits or fails to start
    /// (dropping it does too).
    fn prepare(&self, input: PrepareInput) -> BoxFuture<'_, ApiResult<Prepared>>;

    /// `input.command` read-only and without network, or 503
    /// [`unavailable_error`]. The [`Prepared`] has no network control, its
    /// args end with the command, and it says where the command may write
    /// ([`Prepared::temp_dir`]) and how to tell the sandbox's own failure
    /// from the command's exit status ([`Prepared::wrapper_failure`]);
    /// cleanup as for [`Sandbox::prepare`].
    fn prepare_readonly(&self, input: ReadonlyInput) -> BoxFuture<'_, ApiResult<Prepared>>;
}

/// How a running session's network allowlist grows: srt's fd 3, or the
/// native proxy's allowlist.
pub trait NetworkControl: Send + Sync {
    fn prepare_terminal(
        &self,
        _command: &mut tokio::process::Command,
        _gate: std::os::fd::OwnedFd,
    ) -> std::io::Result<()> {
        Err(std::io::Error::other("guarded terminals are unsupported"))
    }

    /// Called on the agent's command before it is spawned (srt: map the
    /// control pipe's read end to fd 3).
    fn prepare_command(&self, command: &mut tokio::process::Command) -> std::io::Result<()>;

    /// Whether approvals can still be applied (TS: `this.control` exists).
    fn is_open(&self) -> bool;

    /// Allow every domain in `approved` (all the session's approvals so
    /// far, as srt's settings take them) besides the policy's own.
    fn approve(&self, approved: &[String]) -> Result<(), String>;
}

/// How the caller of a read-only command tells the sandbox wrapper's own
/// failure (it never ran the command: a set-up error, `execvp` failing, a
/// path gone before it was mounted) from the command's exit status.
/// bubblewrap, `sandbox-exec` and srt exit 1 for most of their own
/// failures, which is also git's "no": read as git's, a broken sandbox
/// looked like a clean repository in the Git panel.
pub trait WrapperStatus: Send + Sync {
    /// Called on the command before it is spawned.
    fn prepare_command(&self, command: &mut tokio::process::Command) -> std::io::Result<()>;

    /// After the command exited with `code` (not 0, and not killed by the
    /// caller) and wrote `stderr`: why the sandbox failed, or `None` when
    /// the command ran.
    fn failure(&self, code: i32, stderr: &str) -> Option<String>;
}

/// [`WrapperStatus`] for wrappers that report only on stderr: a failure is
/// a non-zero exit whose stderr starts with one of the prefixes (the
/// wrapper speaks before the command can). Its first line is the reason.
/// A command that prints such a prefix itself is taken for a failed
/// sandbox, which costs it nothing but the status code.
pub struct StderrPrefixes(pub &'static [&'static str]);

impl WrapperStatus for StderrPrefixes {
    fn prepare_command(&self, command: &mut tokio::process::Command) -> std::io::Result<()> {
        let _ = command;
        Ok(())
    }

    fn failure(&self, code: i32, stderr: &str) -> Option<String> {
        let stderr = stderr.trim_start();
        (code != 0 && self.0.iter().any(|prefix| stderr.starts_with(prefix))).then(|| {
            stderr
                .lines()
                .next()
                .unwrap_or_default()
                .trim_end()
                .to_owned()
        })
    }
}

/// One session's sandbox: the command that runs the agent inside it.
pub struct Prepared {
    terminal_guard: bool,
    recovery: Mutex<Option<crate::checkpoints::isolation::RecoveryIsolation>>,
    /// The program to spawn (srt, bubblewrap).
    pub program: PathBuf,
    /// Its arguments, ending with the agent command and its arguments;
    /// the runner appends the agent's own flags.
    pub args: Vec<OsString>,
    /// Added to the agent's environment after the runner's (`CLAUDE_CODE_TMPDIR`).
    pub env: Vec<(String, String)>,
    pub policy: SessionPolicy,
    /// For the session (config problems, exposed state).
    pub warnings: Vec<String>,
    control: Option<Box<dyn NetworkControl>>,
    /// A read-only command's writable directory ([`Prepared::with_temp_dir`]).
    temp_dir: Option<PathBuf>,
    /// A read-only command's ([`Prepared::with_wrapper_status`]).
    status: Option<Box<dyn WrapperStatus>>,
    processes: Option<Arc<dyn processes::ProcessScope>>,
    cleanup: Mutex<Option<Box<dyn FnOnce() + Send>>>,
}

impl Prepared {
    pub fn new(
        program: PathBuf,
        args: Vec<OsString>,
        env: Vec<(String, String)>,
        policy: SessionPolicy,
        warnings: Vec<String>,
        control: Option<Box<dyn NetworkControl>>,
        cleanup: impl FnOnce() + Send + 'static,
    ) -> Self {
        Self {
            terminal_guard: false,
            recovery: Mutex::new(None),
            program,
            args,
            env,
            policy,
            warnings,
            control,
            temp_dir: None,
            status: None,
            processes: None,
            cleanup: Mutex::new(Some(Box::new(cleanup))),
        }
    }

    #[must_use]
    pub(crate) fn with_terminal_guard(mut self) -> Self {
        self.terminal_guard = true;
        self
    }
    #[doc(hidden)]
    pub fn terminal_command(
        &self,
        gate: std::os::fd::OwnedFd,
    ) -> std::io::Result<tokio::process::Command> {
        if !self.terminal_guard || !self.requires_launch_guard() {
            return Err(std::io::Error::other(
                "guarded terminal scope is unavailable",
            ));
        }
        let mut command = tokio::process::Command::new(&self.program);
        command.args(&self.args);
        self.control
            .as_ref()
            .ok_or_else(|| std::io::Error::other("terminal control is unavailable"))?
            .prepare_terminal(&mut command, gate)?;
        Ok(command)
    }

    #[must_use]
    pub(crate) fn with_process_scope(
        mut self,
        processes: Arc<dyn processes::ProcessScope>,
    ) -> Self {
        self.processes = Some(processes);
        self
    }

    pub(crate) fn requires_launch_guard(&self) -> bool {
        self.processes.is_some()
    }

    /// Call immediately after spawn, before anything can reap the wrapper PID.
    pub fn process_spawned(&self, pid: u32) {
        if let Some(processes) = &self.processes {
            processes.spawned(pid);
        }
    }

    /// Retire a kernel-owned process scope, if this backend captured one.
    /// This is separate from signaling the wrapper's process group.
    pub fn terminate_processes(&self) {
        if let Some(processes) = &self.processes {
            processes.terminate();
        }
    }

    pub fn process_scope_state(&self) -> processes::State {
        self.processes
            .as_ref()
            .map_or(processes::State::Unsupported, |p| p.state())
    }

    pub fn process_snapshot(&self) -> processes::Snapshot {
        self.processes.as_ref().map_or(
            processes::Snapshot {
                state: processes::State::Unsupported,
                identity: None,
            },
            |p| p.snapshot(),
        )
    }

    pub async fn wait_processes(&self, timeout: std::time::Duration) -> processes::State {
        let deadline = tokio::time::Instant::now() + timeout;
        loop {
            let state = self.process_scope_state();
            if !matches!(
                state,
                processes::State::Observing | processes::State::Running
            ) || tokio::time::Instant::now() >= deadline
            {
                return state;
            }
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
    }

    /// A read-only command's ([`Sandbox::prepare_readonly`]) one writable
    /// directory, its temp directory: the Git panel puts Git LFS's storage
    /// there.
    #[must_use]
    pub fn with_temp_dir(mut self, temp_dir: PathBuf) -> Self {
        self.temp_dir = Some(temp_dir);
        self
    }

    /// See [`Prepared::with_temp_dir`].
    pub fn temp_dir(&self) -> Option<&std::path::Path> {
        self.temp_dir.as_deref()
    }

    /// How a read-only command's wrapper reports its own failure.
    #[must_use]
    pub fn with_wrapper_status(mut self, status: Box<dyn WrapperStatus>) -> Self {
        self.status = Some(status);
        self
    }

    /// Why the sandbox itself failed, when the command exited with `code`
    /// (not 0, and not killed by the caller) and wrote `stderr`; `None`
    /// when the command ran, or nothing tells.
    pub fn wrapper_failure(&self, code: i32, stderr: &str) -> Option<String> {
        self.status.as_ref()?.failure(code, stderr)
    }

    /// `program` with `args`, prepared by the network control (or a
    /// read-only command's wrapper status). The runner sets the rest: the
    /// agent's flags, environment, `cwd`, piped stdio and its own process
    /// group.
    pub fn command(&self) -> std::io::Result<tokio::process::Command> {
        let mut command = tokio::process::Command::new(&self.program);
        command.args(&self.args);
        self.prepare_command_fds(&mut command)?;
        Ok(command)
    }

    /// When a caller rebuilds a command with different arguments, descriptor
    /// mappings must be installed again; copying argv alone is insufficient.
    pub fn prepare_command_fds(
        &self,
        command: &mut tokio::process::Command,
    ) -> std::io::Result<()> {
        if let Some(control) = &self.control {
            control.prepare_command(command)?;
        }
        if let Some(status) = &self.status {
            status.prepare_command(command)?;
        }
        Ok(())
    }

    pub(crate) fn with_recovery(
        self,
        recovery: Option<crate::checkpoints::isolation::RecoveryIsolation>,
    ) -> Self {
        *self.recovery.lock().unwrap_or_else(|p| p.into_inner()) = recovery;
        self
    }

    /// Whether network approvals can be applied.
    pub fn has_control(&self) -> bool {
        self.control
            .as_ref()
            .is_some_and(|control| control.is_open())
    }

    /// Apply the session's approved domains (all of them so far).
    pub fn approve_domains(&self, approved: &[String]) -> Result<(), String> {
        match &self.control {
            Some(control) if control.is_open() => control.approve(approved),
            _ => Err("The sandbox's control channel is closed".to_owned()),
        }
    }

    /// Remove what the session's sandbox left (settings file, temp
    /// directory, proxy). Runs once; later calls do nothing.
    pub fn cleanup(&self) {
        if let Some(processes) = &self.processes {
            processes.cleanup();
        }
        let cleanup = self
            .cleanup
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .take();
        if let Some(cleanup) = cleanup {
            cleanup();
        }
        self.recovery
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .take();
    }
}

/// A `Prepared` dropped without [`Prepared::cleanup`] (a panic between
/// `prepare` and the runner taking it) still stops the native proxy and
/// removes its files.
impl Drop for Prepared {
    fn drop(&mut self) {
        self.cleanup();
    }
}

/// What [`unavailable_error`] says before the reason.
const UNAVAILABLE: &str = "Agents on this node must run in the sandbox, and it is unavailable: ";

/// 503 `runner_unavailable` for an unavailable sandbox.
pub fn unavailable_error(reason: &str) -> ApiError {
    ApiError::runner_unavailable(format!("{UNAVAILABLE}{reason}"))
}

/// The reason of an [`unavailable_error`], for a caller that is not an
/// agent start to say in its own words; `None` for another error.
pub fn unavailable_reason(error: &ApiError) -> Option<&str> {
    if error.status != 503 {
        return None;
    }
    error.message.strip_prefix(UNAVAILABLE)
}

/// The node's backend (owner: **macos**): [`srt`] when
/// `config.sandbox.srt` is set, else [`linux`] on Linux, [`macos`] on
/// macOS, else [`unavailable`].
pub fn create(config: &NodeConfig, env: &Env) -> Arc<dyn Sandbox> {
    if let Some(srt) = &config.sandbox.srt {
        return Arc::new(srt::SrtSandbox::new(
            srt.clone(),
            config.clone(),
            env.clone(),
        ));
    }
    if cfg!(target_os = "linux") {
        // The bridge runs this very executable inside the sandbox.
        let helper = std::env::current_exe();
        // libtest has no sandbox-bridge subcommand. Native API tests provide
        // the real node binary; this override does not exist in product builds.
        #[cfg(test)]
        let helper = env
            .get("PIRC_TEST_NODE_HELPER")
            .map_or(helper, |path| Ok(PathBuf::from(path)));
        return match helper {
            Ok(helper) => Arc::new(linux::NativeSandbox::new(
                config.clone(),
                env.clone(),
                helper,
            )),
            Err(error) => Arc::new(unavailable::UnavailableSandbox::new(format!(
                "cannot find this executable for the sandbox bridge: {error}"
            ))),
        };
    }
    if cfg!(target_os = "macos") {
        return Arc::new(macos::MacSandbox::new(config.clone(), env.clone()));
    }
    Arc::new(unavailable::UnavailableSandbox::new(
        unavailable::PLATFORM_REASON,
    ))
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicUsize, Ordering};

    use super::*;

    struct Recorder(Arc<Mutex<Vec<String>>>, bool);

    impl NetworkControl for Recorder {
        fn prepare_command(&self, command: &mut tokio::process::Command) -> std::io::Result<()> {
            command.arg("--prepared");
            Ok(())
        }
        fn is_open(&self) -> bool {
            self.1
        }
        fn approve(&self, approved: &[String]) -> Result<(), String> {
            *self.0.lock().unwrap() = approved.to_vec();
            Ok(())
        }
    }

    #[test]
    fn prepared_plumbing() {
        let approved = Arc::new(Mutex::new(Vec::new()));
        let cleaned = Arc::new(AtomicUsize::new(0));
        let counter = cleaned.clone();
        let prepared = Prepared::new(
            PathBuf::from("/bin/srt"),
            vec!["--".into(), "agent".into()],
            Vec::new(),
            SessionPolicy::default(),
            Vec::new(),
            Some(Box::new(Recorder(approved.clone(), true))),
            move || {
                counter.fetch_add(1, Ordering::SeqCst);
            },
        );
        let command = prepared.command().unwrap();
        let args: Vec<_> = command.as_std().get_args().collect();
        assert_eq!(args, ["--", "agent", "--prepared"]);
        assert!(prepared.has_control());
        prepared.approve_domains(&["a.example".into()]).unwrap();
        assert_eq!(*approved.lock().unwrap(), ["a.example"]);
        prepared.cleanup();
        prepared.cleanup();
        assert_eq!(cleaned.load(Ordering::SeqCst), 1);

        let closed = Prepared::new(
            PathBuf::from("/bin/srt"),
            Vec::new(),
            Vec::new(),
            SessionPolicy::default(),
            Vec::new(),
            Some(Box::new(Recorder(approved, false))),
            || {},
        );
        assert!(!closed.has_control());
        assert_eq!(closed.temp_dir(), None);
        let closed = closed.with_temp_dir(PathBuf::from("/tmp/pirc-x"));
        assert_eq!(closed.temp_dir(), Some(std::path::Path::new("/tmp/pirc-x")));
        drop(prepared);
        assert_eq!(cleaned.load(Ordering::SeqCst), 1, "cleaned once");
        assert_eq!(
            closed.approve_domains(&[]).unwrap_err(),
            "The sandbox's control channel is closed"
        );
        assert_eq!(
            unavailable_error("no bwrap").message,
            "Agents on this node must run in the sandbox, and it is unavailable: no bwrap"
        );
        assert_eq!(
            unavailable_reason(&unavailable_error("no bwrap")),
            Some("no bwrap")
        );
        assert_eq!(unavailable_reason(&ApiError::internal()), None);
    }

    #[test]
    fn stderr_prefixes_tell_the_wrappers_failures() {
        let status = StderrPrefixes(&["sandbox-exec: "]);
        assert_eq!(
            status.failure(71, "sandbox-exec: execvp() of 'git' failed\nmore\n"),
            Some("sandbox-exec: execvp() of 'git' failed".to_owned())
        );
        assert_eq!(status.failure(1, ""), None, "git's no");
        assert_eq!(status.failure(128, "fatal: not a git repository"), None);
        assert_eq!(status.failure(0, "sandbox-exec: noise"), None);
    }

    #[test]
    fn dropping_a_prepared_sandbox_cleans_it_up() {
        let cleaned = Arc::new(AtomicUsize::new(0));
        let counter = cleaned.clone();
        let prepared = Prepared::new(
            PathBuf::from("/bin/srt"),
            Vec::new(),
            Vec::new(),
            SessionPolicy::default(),
            Vec::new(),
            None,
            move || {
                counter.fetch_add(1, Ordering::SeqCst);
            },
        );
        let unwound = std::panic::catch_unwind(std::panic::AssertUnwindSafe(move || {
            let _owned = prepared;
            panic!("spawn failed");
        }));
        assert!(unwound.is_err());
        assert_eq!(cleaned.load(Ordering::SeqCst), 1);
    }
}
