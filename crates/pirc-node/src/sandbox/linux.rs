//! The native Linux backend (`spikes/linux-sandbox`). Owner: **linux-fs** (M7).
//!
//! bubblewrap with srt's argument order and the session policy's paths, a
//! network namespace whose only network route out is the filtering HTTP
//! and SOCKS5 proxy ([`super::proxy`]) on a Unix socket served by the node
//! itself (host daemons behind Unix sockets bound after the plan are
//! another way out: see below), and the in-sandbox bridge (`pirc-node sandbox-bridge`,
//! [`super::bridge`]) that exposes it as `127.0.0.1:3128` and `:1080` and
//! then runs the agent. The proxy's allowlist is shared with the session's
//! [`super::NetworkControl`], so an approval widens it in place (no
//! control fd). The agent's stdio passes through unchanged, and no other
//! descriptor: the node closed what it inherited at start-up and the
//! bridge closes the rest ([`super::fds`]). `--die-with-parent`, and the
//! agent runs in its own PID namespace, so killing bubblewrap (the runner's process group) ends
//! everything inside.
//!
//! Parts, each ported from sandbox-runtime 0.0.78 (Apache-2.0, see
//! `crates/pirc-node/NOTICE`):
//!
//! - [`plan`]: the filesystem arguments, M6's verdict planner with srt's
//!   `generateFilesystemArgs` cases (symlinks, missing deny paths and their
//!   placeholders, `/` expansion, `/proc` and `/dev`), the S7 pinning, and
//!   the placeholders' cleanup. A protected path reached through a symlink
//!   the agent could replace refuses the start (503): bubblewrap cannot pin
//!   a link (decided with the user, M7).
//! - [`scan`]: the mandatory deny paths of the working directory
//!   (dangerous files, `.git/hooks`, `.git/config` unless `allowGitConfig`).
//! - [`caps`]: uid 0 without `CAP_SETFCAP`, reported by the probe instead
//!   of a bubblewrap failure on every start.
//! - `args`: profiles past bubblewrap's or the kernel's argument limits.
//! - [`seccomp`]: the filter bubblewrap installs (`--seccomp`): no vsock,
//!   no io_uring. Not srt's.
//!
//! [`Sandbox::prepare_readonly`] runs one host command (panel git) under
//! bubblewrap with the read-only policy, `--unshare-net` and no proxy (the
//! name-service sockets hidden as for a session).
//!
//! # What the native backend does not enforce
//!
//! - `network`: see [`super::proxy`].
//!   `allowLocalBinding` has no effect: the agent has its own network
//!   namespace (its localhost is its own). Unix sockets are filtered by
//!   the read rules only (seccomp cannot tell their paths apart, as with
//!   srt's `allowAllUnixSockets`): `allowUnixSockets` names the ones left
//!   visible (below). The [`seccomp`] filter refuses vsock, which no
//!   network namespace covers, and io_uring.
//! - Unix sockets of host daemons bound after the plan. The read rules
//!   hide the policy's `LINUX_HOST_SOCKETS` and, beyond srt, the host's
//!   name-service sockets (`plan::RESOLVER_SOCKETS`: nscd,
//!   systemd-resolved, sssd, avahi), which would resolve any name for the
//!   agent and so leak data over DNS past the allowlist, WSL's interop
//!   directory whole (`plan::WSL_INTEROP_DIR`: its sockets, later ones
//!   included, start Windows programs outside the sandbox), the node's uid's
//!   `/tmp/ssh-*` directories (sshd's forwarded agents,
//!   `plan::SSH_AGENT_TMP`) that exist at plan time, and every other
//!   socket bound on the host at plan time (`plan::host_unix_sockets`, from
//!   `/proc/net/unix`; nodes' per-session proxy sockets excepted) but an
//!   allowlist: for a session, the inference
//!   socket, `allowUnixSockets` and the nix daemon's
//!   (`plan::NIX_DAEMON_SOCKET`, open by default so builds work; the
//!   daemon fetches past the proxy, and auto mode is the guard); for
//!   [`Sandbox::prepare_readonly`], none. `SSH_AUTH_SOCK` spelled through
//!   a link is hidden where the link leads at plan time: a socket it leads
//!   to later, or a `/tmp/ssh-*` directory made during the session, is
//!   reachable (see [`plan`]'s accepted gaps). Residual risk: a host
//!   daemon whose socket is bound after the plan, or in another network
//!   namespace, stays visible (and connectable: `connect` works on a
//!   read-only bind); one that resolves names or connects on a client's
//!   behalf is a way out past the proxy.
//! - A protected path the host replaces during a session (git's
//!   `config.lock` rename over `.git/config`, a checkout of tracked
//!   `.vscode/`, an editor's atomic save): the kernel detaches the
//!   sandbox's mount on it, and the agent can then write or read the new
//!   file. srt's too; see [`plan`]'s accepted gaps.
//! - Changes between the plan and bubblewrap's start: a symlink
//!   retargeted in between (by the host, or by another session's agent
//!   where its policy lets it write), or a hard link to a protected file
//!   made before the session (see [`plan`]'s accepted gaps).
//! - Glob patterns in the policy's paths are taken literally (srt expanded
//!   `denyRead` globs on Linux and dropped write globs); pirc's policies
//!   hold resolved paths. A missing deny path with `*`, `?` or `[` in its
//!   missing names gets no placeholder, and a warning (once per path).

mod args;
pub mod caps;
pub mod plan;
pub mod processes;
pub mod scan;
pub mod seccomp;
mod status;

use std::ffi::OsString;
use std::ops::Range;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use pirc_config::{Env, NodeConfig};
use pirc_policy::PathPolicy;
use pirc_policy::session::SessionPolicy;

use self::plan::{MountPoints, Options, Plan};
use super::common::{self, ProbeCache, Session};
use super::proxy::{self, Allowlist, ProxyListener};
use super::{
    BRIDGE_SUBCOMMAND, BoxFuture, NetworkControl, PrepareInput, Prepared, ReadonlyInput, Sandbox,
    SandboxStatus,
};
use crate::error::{ApiError, ApiResult};

/// Where the in-sandbox bridge listens for HTTP, as srt's socat did.
pub const BRIDGE_PORT: u16 = 3128;
/// Where the in-sandbox bridge listens for SOCKS5, as srt's socat did
/// (the same proxy socket: the proxy tells the protocols apart).
pub const BRIDGE_SOCKS_PORT: u16 = 1080;

/// The proxy socket's name in the session's temporary directory (srt kept
/// its sockets in the temp directory too).
const PROXY_SOCKET: &str = "proxy.sock";

/// The placeholders this node made, in `<state>/sandbox` ([`MountPoints`]).
const PLACEHOLDER_RECORD: &str = "placeholders";

/// `bwrap` on `PATH` (the node's environment), as an executable file.
pub fn find_bwrap(env: &Env) -> Option<PathBuf> {
    env.get("PATH")?
        .split(':')
        .filter(|dir| dir.starts_with('/'))
        .map(|dir| Path::new(dir).join("bwrap"))
        .find(|file| {
            std::fs::metadata(file)
                .is_ok_and(|meta| meta.is_file() && meta.permissions().mode() & 0o111 != 0)
        })
}

/// bubblewrap's options, and where the filesystem plan sits in them (what
/// goes to an `--args` file for a long profile).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BwrapArgs {
    pub options: Vec<String>,
    pub mounts: Range<usize>,
}

/// The namespaces, `/dev`, capabilities and `/proc` after the filesystem,
/// in srt's order.
fn finish(options: &mut Vec<String>) {
    options.extend(["--dev", "/dev", "--unshare-pid", "--unshare-user"].map(String::from));
    // What keeps a command running as uid 0 from unmounting a denial,
    // without srt's seccomp helper (pirc's case).
    options.extend(caps::capability_args().map(String::from));
    options.extend(["--proc", "/proc"].map(String::from));
}

/// bubblewrap's options up to the command, in srt's order (namespaces,
/// environment, filesystem, `/dev`, PID and user namespaces, capabilities,
/// `/proc`), with `filesystem` from [`plan::plan`] and the proxy
/// environment from [`proxy::env_vars`]. The proxy socket is bound after
/// the filesystem rather than before it, so no mount of the plan can cover
/// it.
pub fn bwrap_args(
    filesystem: Vec<String>,
    tmp: &str,
    socket: &str,
    proxy_env: &[(String, String)],
) -> BwrapArgs {
    let mut args: Vec<String> = ["--new-session", "--die-with-parent", "--unshare-net"]
        .map(String::from)
        .to_vec();
    args.extend(seccomp::args());
    let mut setenv: Vec<(String, String)> = vec![
        ("SANDBOX_RUNTIME".to_owned(), "1".to_owned()),
        ("TMPDIR".to_owned(), tmp.to_owned()),
    ];
    setenv.extend(common::private_cache_env(tmp));
    setenv.extend(proxy_env.iter().cloned());
    // Not srt's: says which kind of sandbox this is.
    setenv.push(("PIRC_SANDBOX_BACKEND".to_owned(), "native".to_owned()));
    for (name, value) in setenv {
        args.extend(["--setenv".to_owned(), name, value]);
    }
    let start = args.len();
    args.extend(filesystem);
    let mounts = start..args.len();
    args.extend(["--bind".to_owned(), socket.to_owned(), socket.to_owned()]);
    finish(&mut args);
    BwrapArgs {
        options: args,
        mounts,
    }
}

/// bubblewrap's options for [`Sandbox::prepare_readonly`]: no network at
/// all (no proxy socket, no proxy variables), the read-only filesystem,
/// and a status descriptor that tells bubblewrap's failures from the
/// command's (`status`).
pub fn readonly_bwrap_args(filesystem: Vec<String>, tmp: &str) -> BwrapArgs {
    let mut args: Vec<String> = ["--new-session", "--die-with-parent", "--unshare-net"]
        .map(String::from)
        .to_vec();
    args.extend(["--json-status-fd".to_owned(), status::STATUS_FD.to_string()]);
    args.extend(seccomp::args());
    for (name, value) in [
        ("SANDBOX_RUNTIME", "1"),
        ("TMPDIR", tmp),
        ("PIRC_SANDBOX_BACKEND", "native"),
    ] {
        args.extend(["--setenv".to_owned(), name.to_owned(), value.to_owned()]);
    }
    for (name, value) in common::private_cache_env(tmp) {
        args.extend(["--setenv".to_owned(), name, value]);
    }
    let start = args.len();
    args.extend(filesystem);
    let mounts = start..args.len();
    finish(&mut args);
    BwrapArgs {
        options: args,
        mounts,
    }
}

/// The filesystem plan for a policy whose agent works in `cwd`, and the
/// claim on its placeholders (recorded in `<state>/sandbox/placeholders`),
/// off the async runtime (the mandatory scan walks the workspace).
async fn plan_for(
    config: &NodeConfig,
    env: &Env,
    policy: &SessionPolicy,
    cwd: &Path,
    allowed_sockets: Vec<String>,
) -> Result<(Vec<String>, MountPoints), String> {
    let paths = policy.paths.clone();
    let config = config.clone();
    let database_dir = config.database_path.parent().map(Path::to_path_buf);
    let options = Options {
        cwd: Some(pirc_policy::real_resolve(&cwd.display().to_string())),
        allow_git_config: policy.allow_git_config,
        host_rules: true,
        // What the node itself reads and writes by these names: an agent
        // replacing a link on the way would hand the node its own config
        // (`allowedPaths`) or state. And the denies the policy lists only
        // by their targets.
        spellings: [
            Some(config.config_dir.clone()),
            Some(config.state_dir.clone()),
            Some(config.sessions_dir.clone()),
            Some(config.uploads_dir.clone()),
            database_dir,
        ]
        .into_iter()
        .flatten()
        .map(|dir| dir.display().to_string())
        .chain(
            policy
                .linked_denies
                .iter()
                .map(|entry| entry.spelled.clone()),
        )
        .collect(),
        host_sockets: pirc_policy::session::linux_host_sockets(
            nix::unistd::getuid().as_raw(),
            env.get("SSH_AUTH_SOCK"),
        ),
        bound_sockets: None,
        allowed_sockets,
        record: None,
    };
    tokio::task::spawn_blocking(move || {
        let record = match common::sandbox_state_dir(&config) {
            Ok(dir) => Some(dir.join(PLACEHOLDER_RECORD)),
            Err(error) => {
                crate::log::warn(&format!("cannot record the sandbox placeholders: {error}"));
                None
            }
        };
        if let Some(file) = &record {
            plan::sweep_record(file);
        }
        // Unreadable (a restricted `/proc`), no host socket would be
        // hidden: refuse instead.
        let bound_sockets = std::fs::read_to_string(plan::PROC_NET_UNIX).map_err(|error| {
            format!(
                "cannot list the host's Unix sockets to hide them ({}): {error}",
                plan::PROC_NET_UNIX
            )
        })?;
        let options = Options {
            record: record.clone(),
            bound_sockets: Some(bound_sockets),
            ..options
        };
        let Plan { args, mount_points } =
            plan::plan(&paths, &options).map_err(|refusal| refusal.to_string())?;
        Ok((args, MountPoints::claim(mount_points, record)))
    })
    .await
    .map_err(|error| format!("the filesystem plan failed: {error}"))?
}

/// The Unix sockets a session's agent may reach: the inference socket and
/// `allowUnixSockets` (the policy's), and the nix daemon's.
fn session_sockets(policy: &SessionPolicy) -> Vec<String> {
    let mut sockets = policy.network.allow_unix_sockets.clone();
    sockets.push(plan::NIX_DAEMON_SOCKET.to_owned());
    sockets
}

/// The native backend.
pub struct NativeSandbox {
    config: NodeConfig,
    env: Env,
    /// The `pirc-node` executable that has the `sandbox-bridge` subcommand.
    helper: PathBuf,
    probe: ProbeCache,
    /// The private parent of the sessions' temporary directories.
    node_tmp: common::NodeTmp,
    /// Connections every session's proxy may still open together.
    connections: Arc<tokio::sync::Semaphore>,
    network: proxy::Scopes,
}

impl NativeSandbox {
    pub fn new(config: NodeConfig, env: Env, helper: PathBuf) -> Self {
        let node_tmp = common::NodeTmp::new(&config, &env);
        Self {
            config,
            env,
            helper,
            probe: ProbeCache::default(),
            node_tmp,
            connections: Arc::new(tokio::sync::Semaphore::new(proxy::MAX_NODE_CONNECTIONS)),
            network: proxy::Scopes::default(),
        }
    }

    /// The proxy variables for the bridge's ports (`GIT_SSH_COMMAND` runs
    /// the helper's `sandbox-bridge connect`).
    fn proxy_env(&self, auth: &proxy::ProxyAuth) -> Vec<(String, String)> {
        let platform = proxy::EnvPlatform::Linux {
            helper: &self.helper,
        };
        proxy::env_vars(platform, BRIDGE_PORT, BRIDGE_SOCKS_PORT, auth)
    }

    /// `bwrap` with `args`, then the bridge on `socket` running `command`.
    fn command_args(
        &self,
        args: Vec<OsString>,
        socket: &Path,
        command: &[OsString],
    ) -> Vec<OsString> {
        let mut out = args;
        out.extend([
            "--".into(),
            self.helper.clone().into(),
            BRIDGE_SUBCOMMAND.into(),
            socket.into(),
            "--".into(),
        ]);
        out.extend(command.iter().cloned());
        out
    }

    /// `/bin/sh -c 'exit 0'` through the whole stack (namespaces, the
    /// bridge's listener), with nothing allowed. A uid-0 node without
    /// `CAP_SETFCAP` is told why first ([`caps::uid0_sandbox_error`]).
    async fn probe(&self) -> SandboxStatus {
        let Some(bwrap) = find_bwrap(&self.env) else {
            return SandboxStatus::Unavailable {
                reason: "bubblewrap (bwrap) was not found on PATH".to_owned(),
            };
        };
        if let Some(reason) = caps::uid0_sandbox_error(
            caps::euid(),
            caps::process_has_bounding_capability(caps::CAP_SETFCAP),
            Some(&bwrap),
        )
        .await
        {
            return SandboxStatus::Unavailable { reason };
        }
        // Removed however the probe ends (a dropped `check` too). Shaped
        // as a session's, so its socket path is as long as theirs.
        let tmp = match self.node_tmp.make_session_dir() {
            Ok((tmp, _)) => common::SessionTmp::new(tmp),
            Err(error) => {
                return SandboxStatus::Unavailable {
                    reason: format!("bubblewrap: {error}"),
                };
            }
        };
        let socket = tmp.join(PROXY_SOCKET);
        // Bound but never served: the probe only needs the file to bind.
        let status = match std::os::unix::net::UnixListener::bind(&socket) {
            Err(error) => SandboxStatus::Unavailable {
                reason: format!(
                    "bubblewrap: cannot bind the proxy socket {}: {error}",
                    socket.display()
                ),
            },
            Ok(_listener) => {
                let tmp_text = tmp.display().to_string();
                let proxy_env = self.proxy_env(&proxy::ProxyAuth::generate());
                let filesystem = plan::plan(
                    &PathPolicy::default(),
                    &Options {
                        host_rules: true,
                        ..Options::default()
                    },
                )
                .map(|plan| plan.args)
                .unwrap_or_default();
                let options = bwrap_args(
                    filesystem,
                    &tmp_text,
                    &socket.display().to_string(),
                    &proxy_env,
                );
                let args = self.command_args(
                    options.options.into_iter().map(OsString::from).collect(),
                    &socket,
                    &["/bin/sh".into(), "-c".into(), "exit 0".into()],
                );
                let mut command = tokio::process::Command::new(&bwrap);
                command.args(args);
                // The filter too: a kernel without seccomp fails the probe.
                if let Err(error) = seccomp::pass(&mut command) {
                    return SandboxStatus::Unavailable {
                        reason: format!("bubblewrap: cannot pass the seccomp filter: {error}"),
                    };
                }
                common::run_probe(
                    "bubblewrap",
                    command,
                    format!("bubblewrap: {}", bwrap.display()),
                )
                .await
            }
        };
        drop(tmp);
        status
    }

    /// bubblewrap, or 503 when the sandbox is unavailable.
    async fn bwrap(&self) -> ApiResult<PathBuf> {
        if let SandboxStatus::Unavailable { reason } = self.check().await {
            return Err(super::unavailable_error(&reason));
        }
        find_bwrap(&self.env)
            .ok_or_else(|| super::unavailable_error("bubblewrap (bwrap) was not found on PATH"))
    }

    /// [`Sandbox::prepare_readonly`] with a policy at hand (`tmp` is its
    /// temporary directory, removed by the cleanup).
    async fn readonly(
        &self,
        Session {
            tmp,
            policy,
            warnings,
        }: Session,
        workspace_root: &Path,
        command: Vec<OsString>,
    ) -> ApiResult<Prepared> {
        let fail = |tmp: &Path, error: ApiError| {
            Session::remove_tmp(tmp);
            Err(error)
        };
        let bwrap = match self.bwrap().await {
            Ok(bwrap) => bwrap,
            Err(error) => return fail(&tmp, error),
        };
        let (filesystem, mounts) =
            match plan_for(&self.config, &self.env, &policy, workspace_root, Vec::new()).await {
                Ok(plan) => plan,
                Err(reason) => return fail(&tmp, super::unavailable_error(&reason)),
            };
        let tmp_text = tmp.display().to_string();
        let options = readonly_bwrap_args(filesystem, &tmp_text);
        let mut tail: Vec<OsString> = vec!["--".into()];
        tail.extend(command);
        let invocation = match args::render(
            &bwrap,
            options.options,
            options.mounts,
            tail,
            args::byte_budget(),
            &common::tmpdir(&self.env),
        ) {
            Ok(invocation) => invocation,
            Err(reason) => return fail(&tmp, super::unavailable_error(&reason)),
        };
        caps::warn_if_setfcap_missing();
        let profile = invocation.profile;
        let temp_dir = tmp.to_path_buf();
        Ok(Prepared::new(
            invocation.program,
            invocation.args,
            Vec::new(),
            policy,
            warnings,
            None,
            move || {
                drop(profile);
                drop(mounts);
                Session::remove_tmp(&tmp);
            },
        )
        .with_temp_dir(temp_dir)
        .with_wrapper_status(Box::new(status::JsonStatus::default())))
    }

    /// [`Sandbox::prepare_readonly`] for `policy` built by the caller
    /// instead of `common::readonly_session` (tests, and callers that
    /// already hold the policy).
    pub async fn prepare_readonly_with(
        &self,
        policy: SessionPolicy,
        workspace_root: &Path,
        command: Vec<OsString>,
    ) -> ApiResult<Prepared> {
        let (tmp, _) = self.node_tmp.make_session_dir().map_err(|error| {
            crate::log::error(&format!(
                "cannot make the command's temp directory: {error}"
            ));
            ApiError::internal()
        })?;
        let session = Session {
            tmp: common::SessionTmp::new(tmp),
            policy,
            warnings: Vec::new(),
        };
        self.readonly(session, workspace_root, command).await
    }
}

impl NativeSandbox {
    async fn prepare_command(
        &self,
        input: PrepareInput,
        agent: Vec<OsString>,
        terminal: bool,
    ) -> ApiResult<Prepared> {
        let Session {
            tmp,
            policy,
            warnings,
        } = common::spawn_session(&self.config, &self.env, &self.node_tmp, &input).await?;
        let fail = |tmp: &Path, error: ApiError| {
            Session::remove_tmp(tmp);
            Err(error)
        };
        let bwrap = match self.bwrap().await {
            Ok(bwrap) => bwrap,
            Err(error) => return fail(&tmp, error),
        };
        let (filesystem, mounts) = match plan_for(
            &self.config,
            &self.env,
            &policy,
            &input.workspace_root,
            session_sockets(&policy),
        )
        .await
        {
            Ok(plan) => plan,
            Err(reason) => return fail(&tmp, super::unavailable_error(&reason)),
        };
        let socket = tmp.join(PROXY_SOCKET);
        let listener = match tokio::net::UnixListener::bind(&socket) {
            Ok(listener) => listener,
            Err(error) => {
                crate::log::error(&format!("cannot start the sandbox proxy: {error}"));
                return fail(&tmp, ApiError::internal());
            }
        };
        let tmp_text = tmp.display().to_string();
        let auth = Arc::new(proxy::ProxyAuth::generate());
        let proxy_env = self.proxy_env(&auth);
        let mut options = bwrap_args(
            filesystem,
            &tmp_text,
            &socket.display().to_string(),
            &proxy_env,
        );
        options.options.extend([
            "--json-status-fd".to_owned(),
            processes::STATUS_FD.to_string(),
        ]);
        if terminal {
            // Force the private gate inside the sandbox too. Accidentally using
            // ordinary Prepared::command or clearing caller env must fail closed.
            options.options.extend([
                "--setenv".into(),
                super::launch_guard::ENV.into(),
                super::terminal_gate::MODE.into(),
            ]);
        }
        let processes = Arc::new(processes::Scope::default());
        let tail = self.command_args(Vec::new(), &socket, &agent);
        let invocation = match args::render(
            &bwrap,
            options.options,
            options.mounts,
            tail,
            args::byte_budget(),
            &common::tmpdir(&self.env),
        ) {
            Ok(invocation) => invocation,
            Err(reason) => return fail(&tmp, super::unavailable_error(&reason)),
        };
        let allowlist = Arc::new(Allowlist::new(
            policy.network.allowed_domains.clone(),
            policy.network.denied_domains.clone(),
        ));
        let proxy = match self.network.start(
            &input.session_id,
            ProxyListener::Unix(listener),
            allowlist.clone(),
            auth,
            self.connections.clone(),
        ) {
            Ok(lease) => lease,
            Err(error) => {
                Session::remove_tmp(&tmp);
                return Err(error);
            }
        };
        caps::warn_if_setfcap_missing();
        let profile = invocation.profile;
        let prepared = Prepared::new(
            invocation.program,
            invocation.args,
            vec![("CLAUDE_CODE_TMPDIR".to_owned(), tmp_text)],
            policy,
            warnings,
            Some(Box::new(NativeControl {
                allowlist,
                authority: proxy.authority(),
                processes: processes.clone(),
            })),
            move || {
                drop(proxy);
                drop(profile);
                drop(mounts);
                Session::remove_tmp(&tmp);
            },
        )
        .with_process_scope(processes)
        .with_recovery(input.recovery);
        Ok(if terminal {
            prepared.with_terminal_guard()
        } else {
            prepared
        })
    }
}

impl Sandbox for NativeSandbox {
    fn network_scopes(&self) -> Option<&proxy::Scopes> {
        Some(&self.network)
    }
    fn check(&self) -> BoxFuture<'_, SandboxStatus> {
        Box::pin(self.probe.get(|| self.probe()))
    }

    fn isolated_terminals(&self) -> bool {
        cfg!(target_os = "linux")
    }
    fn prepare_terminal(
        &self,
        input: PrepareInput,
        shell: PathBuf,
    ) -> BoxFuture<'_, ApiResult<Prepared>> {
        Box::pin(self.prepare_command(input, vec![shell.into(), "-l".into()], true))
    }
    fn prepare(&self, input: PrepareInput) -> BoxFuture<'_, ApiResult<Prepared>> {
        let mut agent = vec![self.config.agent_command.clone().into()];
        agent.extend(self.config.agent_args.iter().map(OsString::from));
        Box::pin(self.prepare_command(input, agent, false))
    }

    fn prepare_readonly(&self, input: ReadonlyInput) -> BoxFuture<'_, ApiResult<Prepared>> {
        Box::pin(async move {
            let session =
                common::spawn_readonly_session(&self.config, &self.env, &self.node_tmp, &input)
                    .await?;
            self.readonly(session, &input.workspace_root, input.command)
                .await
        })
    }
}

/// Approvals widen the proxy's allowlist directly.
struct NativeControl {
    allowlist: Arc<Allowlist>,
    authority: Arc<proxy::Authority>,
    processes: Arc<processes::Scope>,
}

impl NetworkControl for NativeControl {
    fn prepare_terminal(
        &self,
        command: &mut tokio::process::Command,
        gate: std::os::fd::OwnedFd,
    ) -> std::io::Result<()> {
        self.processes.prepare_with_gate(command, Some(gate))
    }

    /// Map bubblewrap's seccomp filter and private process-status pipe together.
    fn prepare_command(&self, command: &mut tokio::process::Command) -> std::io::Result<()> {
        self.processes.prepare_command(command)
    }

    fn is_open(&self) -> bool {
        self.authority.is_open()
    }

    fn approve(&self, approved: &[String]) -> Result<(), String> {
        self.authority
            .admit(|| self.allowlist.set_approved(approved))
            .map_err(|_| "The sandbox network scope was revoked".to_owned())
    }
}

#[cfg(test)]
mod tests {
    use std::fs;

    use super::*;

    #[test]
    fn bwrap_arguments_keep_srts_order() {
        let proxy_env = proxy::env_vars(
            proxy::EnvPlatform::Linux {
                helper: Path::new("/bin/pirc-node"),
            },
            BRIDGE_PORT,
            BRIDGE_SOCKS_PORT,
            &proxy::ProxyAuth::generate(),
        );
        let BwrapArgs {
            options: args,
            mounts,
        } = bwrap_args(
            vec!["--ro-bind".into(), "/".into(), "/".into()],
            "/tmp/pirc-x",
            "/tmp/pirc-x/proxy.sock",
            &proxy_env,
        );
        assert_eq!(
            args[..3],
            ["--new-session", "--die-with-parent", "--unshare-net"]
        );
        assert_eq!(args[mounts], ["--ro-bind", "/", "/"]);
        assert_eq!(args[3..3 + seccomp::args().len()], seccomp::args()[..]);
        let position = |item: &str| args.iter().position(|arg| arg == item).unwrap();
        assert!(position("--setenv") < position("--ro-bind"));
        assert!(position("--ro-bind") < position("--bind"));
        assert!(position("--bind") < position("--dev"));
        assert_eq!(
            args[position("--dev")..],
            [
                "--dev",
                "/dev",
                "--unshare-pid",
                "--unshare-user",
                "--cap-drop",
                "ALL",
                "--proc",
                "/proc"
            ]
        );
        let at = position("TMPDIR");
        assert_eq!(args[at + 1], "/tmp/pirc-x");
        let at = position("HTTPS_PROXY");
        assert!(args[at + 1].starts_with("http://srt:"), "{}", args[at + 1]);
        assert!(
            args[at + 1].ends_with("@localhost:3128"),
            "{}",
            args[at + 1]
        );
    }

    #[test]
    fn the_readonly_sandbox_has_no_network_way_out() {
        let BwrapArgs {
            options: args,
            mounts,
        } = readonly_bwrap_args(
            vec!["--ro-bind".into(), "/".into(), "/".into()],
            "/tmp/pirc-y",
        );
        assert_eq!(
            args[..3],
            ["--new-session", "--die-with-parent", "--unshare-net"]
        );
        assert_eq!(args[mounts.clone()], ["--ro-bind", "/", "/"]);
        assert_eq!(args[3..5], ["--json-status-fd", "3"]);
        let seccomp = seccomp::args();
        assert_eq!(args[5..5 + seccomp.len()], seccomp[..]);
        assert!(
            !args
                .iter()
                .any(|arg| arg.contains("PROXY") || arg.ends_with(".sock"))
        );
        assert_eq!(
            args[mounts.end..],
            [
                "--dev",
                "/dev",
                "--unshare-pid",
                "--unshare-user",
                "--cap-drop",
                "ALL",
                "--proc",
                "/proc"
            ]
        );
    }

    #[test]
    fn finds_bwrap_on_path_only() {
        let dir = tempfile::tempdir().unwrap();
        let bin = dir.path().join("bin");
        fs::create_dir(&bin).unwrap();
        let path = format!("relative:{}", bin.display());
        let env = Env::new([("PATH", path.as_str())], "/");
        assert_eq!(find_bwrap(&env), None);
        fs::write(bin.join("bwrap"), "").unwrap();
        assert_eq!(find_bwrap(&env), None, "not executable");
        fs::set_permissions(bin.join("bwrap"), fs::Permissions::from_mode(0o755)).unwrap();
        assert_eq!(find_bwrap(&env), Some(bin.join("bwrap")));
        assert_eq!(find_bwrap(&Env::new([], "/")), None);
    }
}
