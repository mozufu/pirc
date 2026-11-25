//! The native sandbox's network for real: bubblewrap, the bridge's two
//! ports, the proxy's HTTP and SOCKS5 sides, the environment the agent
//! gets (`GIT_SSH_COMMAND`, `ALL_PROXY`, `FTP_PROXY`), approvals and the
//! resolved-address guard. Skipped, with a message, where `bwrap` is not
//! on `PATH`; the `curl`, `ssh` and `nc` cases also where those are missing.
//!
//! The agent is `/bin/sh -c <script>`; the destinations are servers of
//! this test on the host's loopback, which the sandbox (its own network
//! namespace) reaches only through the proxy.

#![cfg(target_os = "linux")]

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use pirc_config::{Env, NodeConfig};
use pirc_node::sandbox::linux::plan::{RESOLVER_SOCKETS, WSL_INTEROP_DIR};
use pirc_node::sandbox::linux::{NativeSandbox, find_bwrap};
use pirc_node::sandbox::{PrepareInput, Prepared, ReadonlyInput, Sandbox, SandboxStatus};
use pirc_protocol::NodeRole;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};

struct Fixture {
    root: PathBuf,
    config: NodeConfig,
    sandbox: NativeSandbox,
    path: String,
    _tmp: tempfile::TempDir,
    /// Released after the fixture's directory is removed ([`serial`]).
    _serial: std::sync::MutexGuard<'static, ()>,
}

/// One fixture at a time in this binary: a plan hides every Unix socket
/// bound on the host, the other tests' included, and a fixture removed
/// (its sockets with it) while another test's sandbox starts would fail
/// that start (an accepted gap of `plan`, which a node meets only with
/// sockets that vanish within the moment between a plan and its mounts).
static SERIAL: std::sync::Mutex<()> = std::sync::Mutex::new(());

fn serial() -> std::sync::MutexGuard<'static, ()> {
    SERIAL
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

/// A node whose sessions may reach `allowed` but not `denied`, or `None`
/// without bubblewrap.
fn fixture(name: &str, allowed: &[&str], denied: &[&str]) -> Option<Fixture> {
    fixture_with(name, allowed, denied, None)
}

/// [`fixture`], its `TMPDIR` `tmp_len` bytes long when given.
fn fixture_with(
    name: &str,
    allowed: &[&str],
    denied: &[&str],
    tmp_len: Option<usize>,
) -> Option<Fixture> {
    let path_var = std::env::var("PATH").unwrap_or_default();
    if find_bwrap(&Env::new([("PATH", path_var.as_str())], "/")).is_none() {
        eprintln!("skipped: bwrap is not on PATH, so the native sandbox cannot be tested here");
        return None;
    }
    let guard = serial();
    let root = Path::new(env!("CARGO_TARGET_TMPDIR")).join(format!("sandbox-network-{name}"));
    let _ = fs::remove_dir_all(&root);
    for dir in ["home", "state", "config", "workspace"] {
        fs::create_dir_all(root.join(dir)).unwrap();
    }
    let root = fs::canonicalize(&root).unwrap();
    let list = |items: &[&str]| serde_json::to_string(items).unwrap();
    fs::write(
        root.join("config/config.json"),
        format!(
            r#"{{"sandbox":{{"network":{{"defaultDomains":false,"allowedDomains":{},"deniedDomains":{}}}}}}}"#,
            list(allowed),
            list(denied)
        ),
    )
    .unwrap();
    let dir = |rest: &str| root.join(rest).display().to_string();
    let (home, state, config_dir) = (dir("home"), dir("state"), dir("config"));
    // `TMPDIR` short and in `/tmp`, as on a node: the proxy socket's path
    // (`<TMPDIR>/pirc-n-*/pirc-*/proxy.sock`) must fit `sun_path`.
    let tmp_dir = tempfile::Builder::new()
        .prefix("pirc-t")
        .tempdir_in("/tmp")
        .unwrap();
    let mut tmp = fs::canonicalize(tmp_dir.path())
        .unwrap()
        .display()
        .to_string();
    if let Some(len) = tmp_len {
        tmp = format!("{tmp}/{}", "x".repeat(len - tmp.len() - 1));
        fs::create_dir(&tmp).unwrap();
    }
    let vars = [
        ("PIRC_NODE_ID", "test-node"),
        ("PIRC_NODE_TOKEN", "0123456789abcdef0123456789abcdef"),
        ("PIRC_DAEMON_URL", "ws://127.0.0.1:8787"),
        ("PIRC_ALLOWED_USERS", "test-user"),
        ("PIRC_STATE_DIR", state.as_str()),
        ("PIRC_CONFIG_DIR", config_dir.as_str()),
        ("PIRC_BROWSER", "false"),
        ("HOME", home.as_str()),
        ("TMPDIR", tmp.as_str()),
        ("PATH", path_var.as_str()),
    ];
    let env = Env::new(vars, &root);
    let mut config = NodeConfig::load(&env, NodeRole::Node).unwrap();
    config.agent_command = "/bin/sh".to_owned();
    config.agent_args = Vec::new();
    let sandbox = NativeSandbox::new(
        config.clone(),
        env,
        PathBuf::from(env!("CARGO_BIN_EXE_pirc-node")),
    );
    Some(Fixture {
        root,
        config,
        sandbox,
        path: path_var,
        _tmp: tmp_dir,
        _serial: guard,
    })
}

/// What a script printed and how it ended.
struct Run {
    code: i32,
    stdout: String,
    stderr: String,
}

impl Fixture {
    async fn prepare(&self, session: &str) -> Prepared {
        let session_dir = self.config.sessions_dir.join(session);
        fs::create_dir_all(&session_dir).unwrap();
        self.sandbox
            .prepare(PrepareInput {
                grants: Vec::new(),
                session_id: session.to_owned(),
                workspace_root: self.root.join("workspace"),
                session_dir,
                inference_socket: None,
                protected_paths: Vec::new(),
                workspace_memory_file: None,
                recovery: None,
            })
            .await
            .unwrap()
    }

    /// `script` as the agent of `prepared` (each run is a new sandbox on
    /// the same proxy).
    async fn run(&self, prepared: &Prepared, script: &str) -> Run {
        let mut command = prepared.command().unwrap();
        command
            .args(["-c", script])
            .envs(prepared.env.iter().map(|(k, v)| (k, v)))
            .env("PATH", &self.path)
            .current_dir(self.root.join("workspace"))
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);
        let output = tokio::time::timeout(Duration::from_secs(30), command.output())
            .await
            .expect("the sandboxed script timed out")
            .unwrap();
        Run {
            code: output.status.code().unwrap_or(-1),
            stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
            stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
        }
    }
}

/// A host server on 127.0.0.1: echoes what it reads after its first line
/// (a tunnel), or answers an HTTP request with `200 ok`.
async fn upstream() -> u16 {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    tokio::spawn(async move {
        while let Ok((stream, _)) = listener.accept().await {
            tokio::spawn(async move {
                let mut reader = BufReader::new(stream);
                let mut line = String::new();
                if reader.read_line(&mut line).await.unwrap_or(0) == 0 {
                    return;
                }
                if line.starts_with("GET ") {
                    loop {
                        let mut next = String::new();
                        if reader.read_line(&mut next).await.unwrap_or(0) == 0 || next == "\r\n" {
                            break;
                        }
                    }
                    let _ = reader
                        .into_inner()
                        .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 3\r\nConnection: close\r\n\r\nok\n")
                        .await;
                    return;
                }
                let _ = reader
                    .get_mut()
                    .write_all(format!("echo {line}").as_bytes())
                    .await;
                let mut rest = Vec::new();
                let _ = reader.read_to_end(&mut rest).await;
                let _ = reader.into_inner().write_all(&rest).await;
            });
        }
    });
    port
}

/// The `ProxyCommand` of `$GIT_SSH_COMMAND` for `host` and `port`, run
/// with `input` on stdin (the shell does what ssh would: split, expand).
fn proxy_command(host: &str, port: u16, input: &str) -> String {
    format!(
        r#"eval "set -- $GIT_SSH_COMMAND"
pc=${{7#ProxyCommand=}}
case "$pc" in *' %h %p') ;; *) echo "unexpected ProxyCommand: $pc" >&2; exit 99;; esac
printf '{input}' | eval "exec ${{pc% %h %p}} {host} {port}""#
    )
}

fn has(tool: &str, path: &str) -> bool {
    let found = path
        .split(':')
        .any(|dir| Path::new(dir).join(tool).is_file());
    if !found {
        eprintln!("skipped: {tool} is not on PATH");
    }
    found
}

/// The host's name-service sockets ([`RESOLVER_SOCKETS`]: the socket
/// itself, or the sockets in the directory).
fn resolver_sockets() -> Vec<PathBuf> {
    use std::os::unix::fs::FileTypeExt;
    let is_socket = |path: &Path| fs::metadata(path).is_ok_and(|meta| meta.file_type().is_socket());
    let mut found = Vec::new();
    for entry in RESOLVER_SOCKETS {
        let entry = Path::new(entry);
        if is_socket(entry) {
            found.push(entry.to_path_buf());
        } else if let Ok(dir) = fs::read_dir(entry) {
            found.extend(
                dir.flatten()
                    .map(|item| item.path())
                    .filter(|path| is_socket(path)),
            );
        }
    }
    found
}

/// The host's resolver daemons (nscd, systemd-resolved, ...) would resolve
/// any name for the sandbox, and their queries reach the name's
/// authoritative server whatever the allowlist says: their sockets are
/// hidden from sessions and from the read-only sandbox alike.
#[tokio::test]
async fn the_hosts_resolver_sockets_are_hidden() {
    let sockets = resolver_sockets();
    if sockets.is_empty() {
        eprintln!("skipped: this host has no name-service socket");
        return;
    }
    let Some(f) = fixture("resolver", &["localhost"], &[]) else {
        return;
    };
    // Through the host resolver when the host itself resolves the name
    // (it may be offline); the sockets' visibility either way.
    let name = "example.com";
    let resolves = has("getent", &f.path)
        && std::process::Command::new("getent")
            .args(["hosts", name])
            .stdout(Stdio::null())
            .status()
            .is_ok_and(|status| status.success());
    if !resolves {
        eprintln!("the host cannot resolve {name}: only the sockets' visibility is checked");
    }
    let mut script = String::new();
    for socket in &sockets {
        script.push_str(&format!(
            "[ -S '{0}' ] && echo 'visible {0}'\n",
            socket.display()
        ));
    }
    if resolves {
        script.push_str(&format!("getent hosts {name} && echo 'resolved {name}'\n"));
    }
    script.push_str("exit 0\n");

    let prepared = f.prepare("pi_resolver").await;
    let run = f.run(&prepared, &script).await;
    assert_eq!((run.code, run.stdout.as_str()), (0, ""), "{}", run.stderr);
    prepared.cleanup();

    let readonly = f
        .sandbox
        .prepare_readonly(ReadonlyInput {
            workspace_root: f.root.join("workspace"),
            command: vec!["/bin/sh".into(), "-c".into(), script.into()],
        })
        .await
        .unwrap();
    let output = readonly
        .command()
        .unwrap()
        .env("PATH", &f.path)
        .current_dir(f.root.join("workspace"))
        .stdin(Stdio::null())
        .output()
        .await
        .unwrap();
    assert_eq!(
        (
            output.status.code(),
            String::from_utf8_lossy(&output.stdout)
        ),
        (Some(0), "".into()),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    readonly.cleanup();
}

/// WSL's interop sockets start Windows programs outside the sandbox (past
/// the proxy too), and each new WSL session binds a new one in
/// `/run/WSL`: the directory is hidden whole, so a socket bound after the
/// plan is out of reach as well. Skipped off WSL; the later socket only
/// where this uid may write the directory.
#[tokio::test]
async fn wsl_interop_sockets_are_hidden_including_later_ones() {
    let dir = Path::new(WSL_INTEROP_DIR);
    if !dir.is_dir() {
        eprintln!("skipped: {WSL_INTEROP_DIR} does not exist (not WSL)");
        return;
    }
    let Some(f) = fixture("wsl", &["localhost"], &[]) else {
        return;
    };
    let prepared = f.prepare("pi_wsl").await;
    // After the plan, as a new terminal's interop server would.
    let later = dir.join(format!("{}_pirc_test_interop", std::process::id()));
    let _ = fs::remove_file(&later);
    let listener = std::os::unix::net::UnixListener::bind(&later);
    if listener.is_err() {
        eprintln!("cannot bind in {WSL_INTEROP_DIR}: only the plan-time sockets are checked");
    }
    let script = format!(
        "ls -A '{WSL_INTEROP_DIR}'; [ -S '{0}' ] && echo 'visible {0}'; exit 0",
        later.display()
    );
    let run = f.run(&prepared, &script).await;
    if listener.is_ok() {
        let _ = fs::remove_file(&later);
    }
    assert_eq!((run.code, run.stdout.as_str()), (0, ""), "{}", run.stderr);
    prepared.cleanup();
}

/// A descriptor bubblewrap is handed without close-on-exec (one the node
/// inherited and did not close: a PTY whose shell is outside the sandbox,
/// say) stops at the in-sandbox bridge: the agent gets stdio only, and
/// cannot write through it.
#[tokio::test]
async fn an_inherited_descriptor_does_not_reach_the_agent() {
    use std::os::fd::AsRawFd as _;

    use nix::fcntl::{FcntlArg, FdFlag, OFlag, fcntl};
    let Some(f) = fixture("inherited-fd", &["localhost"], &[]) else {
        return;
    };
    let (reader, writer) = std::io::pipe().unwrap();
    let writer = std::os::fd::OwnedFd::from(writer);
    let fd = writer.as_raw_fd();
    fcntl(&writer, FcntlArg::F_SETFD(FdFlag::empty())).unwrap();
    let prepared = f.prepare("pi_inherited_fd").await;
    let script = format!(
        // `/dev/fd/N`, not `>&N`: dash (Ubuntu's `/bin/sh`) takes one digit.
        "[ -e /dev/fd/{fd} ] && echo 'open {fd}'; echo escaped 2>/dev/null >/dev/fd/{fd}; ls /proc/self/fd >&2; exit 0"
    );
    let run = f.run(&prepared, &script).await;
    drop(writer);
    // Non-blocking: another test's child may hold the write end too.
    fcntl(&reader, FcntlArg::F_SETFL(OFlag::O_NONBLOCK)).unwrap();
    let mut buffer = [0u8; 64];
    let read = std::io::Read::read(&mut &reader, &mut buffer).unwrap_or(0);
    let written = String::from_utf8_lossy(&buffer[..read]).into_owned();
    assert_eq!(
        (run.code, run.stdout.as_str(), written.as_str()),
        (0, "", ""),
        "{}",
        run.stderr
    );
    prepared.cleanup();
}

/// Set in the sandboxed half of [`vsock_is_refused_in_the_sandbox`].
const VSOCK_CHILD: &str = "PIRC_TEST_VSOCK_CHILD";

/// The sandboxed half: what `socket(AF_VSOCK)` gives, and the process's
/// seccomp mode.
#[test]
#[ignore = "run inside the sandbox by vsock_is_refused_in_the_sandbox"]
fn vsock_child() {
    use nix::sys::socket::{AddressFamily, SockFlag, SockType, socket};
    if std::env::var_os(VSOCK_CHILD).is_none() {
        return;
    }
    let vsock = socket(
        AddressFamily::Vsock,
        SockType::Stream,
        SockFlag::empty(),
        None,
    );
    println!("@@ vsock {:?}", vsock.map(drop).map_err(|e| e as i32));
    let status = fs::read_to_string("/proc/self/status").unwrap();
    let mode = status
        .lines()
        .find(|l| l.starts_with("Seccomp:"))
        .unwrap_or_default();
    println!(
        "@@ {}",
        mode.split_whitespace().collect::<Vec<_>>().join(" ")
    );
}

/// vsock is outside every network namespace: on WSL 2 the Windows host
/// listens there, and a VM's hypervisor too. The sandbox's seccomp filter
/// refuses the socket (`EPERM`), wherever the kernel has vsock or not.
#[tokio::test]
async fn vsock_is_refused_in_the_sandbox() {
    let Some(f) = fixture("vsock", &["localhost"], &[]) else {
        return;
    };
    let exe = std::env::current_exe().unwrap();
    let script = format!(
        "{VSOCK_CHILD}=1 '{}' --exact vsock_child --ignored --nocapture --test-threads 1",
        exe.display()
    );
    let prepared = f.prepare("pi_vsock").await;
    let run = f.run(&prepared, &script).await;
    let lines: Vec<&str> = run
        .stdout
        .lines()
        .filter_map(|l| l.split_once("@@ ").map(|(_, rest)| rest))
        .collect();
    assert_eq!(
        lines,
        [
            format!("vsock Err({})", nix::libc::EPERM).as_str(),
            "Seccomp: 2"
        ],
        "{}{}",
        run.stdout,
        run.stderr
    );
    prepared.cleanup();
}

/// Every session runs as the node's uid with `/tmp` writable: the node's
/// private parent of the temp directories keeps one session from another's
/// files and proxy socket.
#[tokio::test]
async fn sessions_cannot_reach_each_others_temp_dir_or_proxy() {
    let Some(f) = fixture("neighbours", &["localhost"], &[]) else {
        return;
    };
    let port = upstream().await;
    let tmp = |prepared: &Prepared| {
        let (_, dir) = prepared
            .env
            .iter()
            .find(|(name, _)| name == "CLAUDE_CODE_TMPDIR")
            .unwrap();
        PathBuf::from(dir)
    };
    let a = f.prepare("pi_a").await;
    let b = f.prepare("pi_b").await;
    let (a_tmp, b_tmp) = (tmp(&a), tmp(&b));
    let parent = a_tmp.parent().unwrap();
    assert_eq!(b_tmp.parent(), Some(parent));
    assert!(b_tmp.join("proxy.sock").exists());
    let script = format!(
        r#"ls -a '{parent}' | grep -v '^\.\.\?$'
[ -e '{b}/proxy.sock' ] && echo 'sees the socket'
ls '{b}' 2>/dev/null && echo 'lists the directory'
(echo x > '{b}/planted') 2>/dev/null && echo 'writes the directory'
printf 'GET / HTTP/1.1\r\n\r\n' | nc -U '{b}/proxy.sock' 2>/dev/null && echo 'connects'
echo x > "$TMPDIR/own" && cat "$TMPDIR/own"
exit 0
"#,
        parent = parent.display(),
        b = b_tmp.display(),
    );
    let run = f.run(&a, &script).await;
    let own_name = a_tmp.file_name().unwrap().to_string_lossy();
    assert_eq!(
        (run.code, run.stdout.as_str()),
        (0, format!("{own_name}\nx\n").as_str()),
        "{}",
        run.stderr
    );
    assert!(!b_tmp.join("planted").exists());
    // B's proxy still serves B.
    if has("curl", &f.path) {
        let run = f
            .run(
                &b,
                &format!("curl -sS --noproxy '' --max-time 10 http://localhost:{port}/"),
            )
            .await;
        assert_eq!(run.stdout, "ok\n", "{}", run.stderr);
    }
    a.cleanup();
    b.cleanup();
}

/// The probe binds its socket where a session's goes
/// (`<TMPDIR>/pirc-n-*/pirc-*/proxy.sock`): a `TMPDIR` too long for that
/// path in `sun_path` (108 bytes) makes the backend unavailable, saying
/// why, rather than available with every start failing (second review,
/// issue 5). 80 bytes fit a socket directly in `<TMPDIR>/pirc-*`.
#[tokio::test]
async fn the_probe_checks_a_session_shaped_socket_path() {
    let Some(f) = fixture_with("long-tmp", &[], &[], Some(80)) else {
        return;
    };
    let status = f.sandbox.check().await;
    let SandboxStatus::Unavailable { reason } = status else {
        panic!("{status:?}");
    };
    assert!(
        reason.starts_with("bubblewrap: cannot bind the proxy socket /tmp/"),
        "{reason}"
    );
    assert!(reason.contains("/pirc-n-"), "{reason}");
}

#[tokio::test]
async fn ssh_style_tunnels_go_through_the_helper_and_approvals_widen_them() {
    let Some(f) = fixture("helper", &["localhost"], &[]) else {
        return;
    };
    let port = upstream().await;
    let prepared = f.prepare("pi_helper").await;
    let run = f
        .run(
            &prepared,
            &proxy_command("localhost", port, "hello\\nworld\\n"),
        )
        .await;
    assert_eq!(run.code, 0, "{}", run.stderr);
    assert_eq!(run.stdout, "echo hello\nworld\n");

    let run = f
        .run(&prepared, &proxy_command("127.0.0.1", port, "x\\n"))
        .await;
    assert_eq!(run.code, 1);
    assert!(
        run.stderr.contains(&format!(
            "CONNECT 127.0.0.1:{port}: HTTP/1.1 403 Forbidden: Connection blocked by network allowlist"
        )),
        "{}",
        run.stderr
    );
    prepared.approve_domains(&["127.0.0.1".to_owned()]).unwrap();
    let run = f
        .run(&prepared, &proxy_command("127.0.0.1", port, "x\\n"))
        .await;
    assert_eq!(
        (run.code, run.stdout.as_str()),
        (0, "echo x\n"),
        "{}",
        run.stderr
    );
    prepared.cleanup();
}

/// Whether `address` is one the resolved-address guard refuses for a name
/// that is not listed: loopback, private or link-local.
fn is_internal(address: &std::net::IpAddr) -> bool {
    match address {
        std::net::IpAddr::V4(v4) => v4.is_loopback() || v4.is_private() || v4.is_link_local(),
        std::net::IpAddr::V6(v6) => {
            v6.is_loopback() || v6.is_unique_local() || v6.is_unicast_link_local()
        }
    }
}

/// A dotted name resolving to this host only (loopback, private or
/// link-local addresses), for the resolved-address guard: the host's name
/// when dotted, `<hostname>.localdomain` or `localhost.localdomain`.
async fn dotted_name_of_this_host(hostname: &str) -> Option<String> {
    let candidates = [
        hostname.to_owned(),
        format!("{hostname}.localdomain"),
        "localhost.localdomain".to_owned(),
    ];
    for name in candidates.into_iter().filter(|name| name.contains('.')) {
        let Ok(addresses) = tokio::net::lookup_host((name.as_str(), 80)).await else {
            continue;
        };
        let addresses: Vec<_> = addresses.map(|address| address.ip()).collect();
        if !addresses.is_empty() && addresses.iter().all(is_internal) {
            return Some(name);
        }
    }
    None
}

#[tokio::test]
async fn names_resolving_to_this_host_are_refused() {
    // A name resolving to one of this host's addresses (or loopback):
    // allowing the name grants neither. srt's schema refuses a
    // single-label name, so as an approval it has no effect at all; a
    // dotted name reaches the resolved-address guard.
    let hostname = fs::read_to_string("/proc/sys/kernel/hostname")
        .map(|name| name.trim().to_ascii_lowercase())
        .unwrap_or_default();
    let dotted = dotted_name_of_this_host(&hostname).await;
    let single_label = !hostname.is_empty() && !hostname.contains('.');
    let Some(f) = fixture("resolved", &["*.localhost"], &["bad.localhost"]) else {
        return;
    };
    let port = upstream().await;
    let prepared = f.prepare("pi_resolved").await;
    let approved: Vec<String> = dotted
        .iter()
        .cloned()
        .chain(single_label.then(|| hostname.clone()))
        .collect();
    prepared.approve_domains(&approved).unwrap();
    match &dotted {
        Some(name) => {
            let run = f.run(&prepared, &proxy_command(name, port, "x\\n")).await;
            assert_eq!(run.code, 1, "{}", run.stdout);
            let expected = format!("Connection to {name} blocked: resolved to ");
            assert!(run.stderr.contains(&expected), "{}", run.stderr);
        }
        None => eprintln!(
            "NOT RUN: the resolved-address guard case (no dotted name resolves to this host here: \
             {hostname}, {hostname}.localdomain, localhost.localdomain)"
        ),
    }
    if single_label {
        let run = f
            .run(&prepared, &proxy_command(&hostname, port, "x\\n"))
            .await;
        assert_eq!(run.code, 1, "{}", run.stdout);
        assert!(
            run.stderr.contains("blocked by network allowlist"),
            "{}",
            run.stderr
        );
    }
    // `*.localhost` (which `DOMAIN_PATTERN` admits) is not an entry srt
    // takes: no `*.localhost` name is allowed.
    for name in ["app.localhost", "bad.localhost"] {
        let run = f.run(&prepared, &proxy_command(name, port, "x\\n")).await;
        assert!(
            run.stderr.contains("blocked by network allowlist"),
            "{}",
            run.stderr
        );
    }
    prepared.cleanup();
}

#[tokio::test]
async fn curl_reaches_allowed_hosts_over_http_and_socks5() {
    let Some(f) = fixture("curl", &["localhost"], &["denied.localhost"]) else {
        return;
    };
    if !has("curl", &f.path) {
        return;
    }
    let port = upstream().await;
    let prepared = f.prepare("pi_curl").await;
    // `localhost` is in NO_PROXY (it is the sandbox's own loopback):
    // `--noproxy ''` sends it to the host through the proxy anyway.
    let curl = "curl -sS --noproxy '' --max-time 10";
    let script = format!(
        r#"echo "http $({curl} http://localhost:{port}/)"
echo "all $({curl} --proxy "$ALL_PROXY" http://localhost:{port}/)"
echo "socks $({curl} --proxy "$FTP_PROXY" http://localhost:{port}/)"
echo "tunnel $({curl} --proxytunnel --proxy "$HTTPS_PROXY" http://localhost:{port}/)"
echo "denied $({curl} -o /dev/null -w '%{{http_code}}' http://denied.localhost:{port}/)"
echo "off-list $({curl} -o /dev/null -w '%{{http_code}}' http://127.0.0.1:{port}/)"
{curl} --proxy "socks5h://srt:wrong@localhost:1080" http://localhost:{port}/ || echo "bad token $?"
{curl} --proxy "http://localhost:3128" -o /dev/null -w 'no token %{{http_code}}\n' http://localhost:{port}/
"#
    );
    let run = f.run(&prepared, &script).await;
    assert_eq!(
        run.stdout,
        "http ok\nall ok\nsocks ok\ntunnel ok\ndenied 403\noff-list 403\nbad token 97\nno token 407\n",
        "{}",
        run.stderr
    );
    prepared.cleanup();
}

#[tokio::test]
async fn git_ssh_command_reaches_ssh_servers_through_the_proxy() {
    let Some(f) = fixture("ssh", &["localhost"], &[]) else {
        return;
    };
    if !has("ssh", &f.path) {
        return;
    }
    // A server that speaks SSH's identification line and records the client's.
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let (seen, mut banner) = tokio::sync::mpsc::channel::<String>(4);
    tokio::spawn(async move {
        while let Ok((stream, _)) = listener.accept().await {
            let seen = seen.clone();
            tokio::spawn(async move {
                let mut reader = BufReader::new(stream);
                let _ = reader.get_mut().write_all(b"SSH-2.0-fake\r\n").await;
                let mut line = String::new();
                let _ = reader.read_line(&mut line).await;
                let _ = seen.send(line).await;
            });
        }
    });
    let prepared = f.prepare("pi_ssh").await;
    let options = "-F /dev/null -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10";
    // As git runs it: through a shell.
    let run = f
        .run(
            &prepared,
            &format!(r#"eval "$GIT_SSH_COMMAND {options} -p {port} git@localhost true""#),
        )
        .await;
    assert_ne!(run.code, 0, "the fake server cannot finish a key exchange");
    let line = tokio::time::timeout(Duration::from_secs(5), banner.recv())
        .await
        .expect("ssh never reached the server")
        .unwrap();
    assert!(
        line.starts_with("SSH-2.0-OpenSSH"),
        "{line:?}; {}",
        run.stderr
    );

    let run = f
        .run(
            &prepared,
            &format!(r#"eval "$GIT_SSH_COMMAND {options} -p 22 git@github.com true""#),
        )
        .await;
    assert_ne!(run.code, 0);
    assert!(
        run.stderr.contains("blocked by network allowlist"),
        "{}",
        run.stderr
    );

    // srt's macOS command: nc cannot authenticate, so the proxy answers
    // with an SSH disconnect that says why.
    if has("nc", &f.path) {
        let nc = format!(
            "ssh {options} -o ProxyCommand='nc -X 5 -x localhost:1080 %h %p' -p 22 git@localhost true"
        );
        let run = f.run(&prepared, &nc).await;
        assert_ne!(run.code, 0);
        assert!(
            run.stderr.contains("This proxy requires authentication"),
            "{}",
            run.stderr
        );
    }
    prepared.cleanup();
}
