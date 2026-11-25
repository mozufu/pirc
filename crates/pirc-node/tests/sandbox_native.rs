//! The native Linux sandbox for real: bubblewrap, the proxy, the bridge
//! (this package's `pirc-node sandbox-bridge`) and a shell as the agent.
//! Skipped, with a message, where `bwrap` is not on `PATH`.
//!
//! Network checks run this test binary inside the sandbox as a small HTTP
//! client (the `sandbox_client` test, which does nothing unless
//! `PIRC_SANDBOX_TEST_CLIENT` is set), since the sandbox may have no curl.

#![cfg(target_os = "linux")]

use std::fs;
use std::io::{BufRead, Read, Write};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use pirc_config::{Env, NodeConfig};
use pirc_node::sandbox::linux::{NativeSandbox, find_bwrap};
use pirc_node::sandbox::{PrepareInput, Prepared, Sandbox, SandboxStatus};
use pirc_protocol::NodeRole;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};

const CLIENT: &str = "PIRC_SANDBOX_TEST_CLIENT";

/// Inside the sandbox: for each space-separated target, one line on
/// stdout. `direct:<port>` connects to the host's port without the proxy;
/// `unix:<path>` sends `ping` to a Unix socket and prints the answer;
/// `read:<path>` says whether the file can be read; a URL is fetched
/// through the bridge. Every target after the first waits for a line on
/// stdin first.
#[test]
fn sandbox_client() {
    let Ok(targets) = std::env::var(CLIENT) else {
        return;
    };
    let stdin = std::io::stdin();
    for (index, target) in targets.split(' ').enumerate() {
        if index > 0 {
            let mut line = String::new();
            stdin.lock().read_line(&mut line).unwrap();
        }
        let result = if let Some(socket) = target.strip_prefix("unix:") {
            match std::os::unix::net::UnixStream::connect(socket) {
                Err(error) => format!("unreachable: {:?}", error.kind()),
                Ok(mut stream) => {
                    stream.write_all(b"ping\n").unwrap();
                    let mut reply = String::new();
                    let _ = stream.read_to_string(&mut reply);
                    reply.trim().to_owned()
                }
            }
        } else if let Some(file) = target.strip_prefix("read:") {
            match fs::read(file) {
                Ok(_) => "read".to_owned(),
                Err(error) => format!("unreadable: {:?}", error.kind()),
            }
        } else if let Some(port) = target.strip_prefix("direct:") {
            match std::net::TcpStream::connect_timeout(
                &format!("127.0.0.1:{port}").parse().unwrap(),
                Duration::from_secs(3),
            ) {
                Ok(_) => "connected".to_owned(),
                Err(_) => "refused".to_owned(),
            }
        } else {
            match std::net::TcpStream::connect("127.0.0.1:3128") {
                Err(error) => format!("no bridge: {error}"),
                Ok(mut stream) => {
                    let host = target
                        .trim_start_matches("http://")
                        .split('/')
                        .next()
                        .unwrap();
                    // The proxy wants the session's token, from `HTTP_PROXY`'s userinfo.
                    let proxy = std::env::var("HTTP_PROXY").unwrap_or_default();
                    let credential = proxy
                        .trim_start_matches("http://")
                        .split_once('@')
                        .map_or("", |(credential, _)| credential);
                    let authorization = pirc_node::sandbox::proxy::basic_authorization(credential);
                    write!(
                        stream,
                        "GET {target} HTTP/1.1\r\nHost: {host}\r\nProxy-Authorization: {authorization}\r\n\r\n"
                    )
                    .unwrap();
                    let mut reply = String::new();
                    let _ = stream.read_to_string(&mut reply);
                    reply.lines().next().unwrap_or_default().to_owned()
                }
            }
        };
        // libtest may print on the same line: mark the result.
        println!("@@ {result}");
        std::io::stdout().flush().unwrap();
    }
    std::process::exit(0);
}

/// Whether `path` is gone within two seconds: a session's placeholders
/// are removed on the blocking pool a moment after its cleanup.
async fn gone(path: &Path) -> bool {
    for _ in 0..200 {
        if std::fs::symlink_metadata(path).is_err() {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    false
}

struct Fixture {
    root: PathBuf,
    config: NodeConfig,
    sandbox: NativeSandbox,
    /// `TMPDIR`.
    tmp: tempfile::TempDir,
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

fn path(root: &Path, rest: &str) -> String {
    root.join(rest).display().to_string()
}

/// A node layout outside `/tmp` (a write root of every session), or `None`
/// without bubblewrap.
fn fixture(name: &str) -> Option<Fixture> {
    fixture_with(name, false)
}

/// [`fixture`]; with `home_writable`, the agent config lives in
/// `~/.config/.pirc` and puts `~` in `allowedPaths`.
fn fixture_with(name: &str, home_writable: bool) -> Option<Fixture> {
    fixture_env(name, home_writable, |_| Vec::new())
}

/// [`fixture_with`] with the node's environment extended by `extra`,
/// called with the layout's root once it exists.
fn fixture_env(
    name: &str,
    home_writable: bool,
    extra: impl FnOnce(&Path) -> Vec<(String, String)>,
) -> Option<Fixture> {
    let path_var = std::env::var("PATH").unwrap_or_default();
    let probe_env = Env::new([("PATH", path_var.as_str())], "/");
    if find_bwrap(&probe_env).is_none() {
        eprintln!("skipped: bwrap is not on PATH, so the native sandbox cannot be tested here");
        return None;
    }
    let guard = serial();
    let root = Path::new(env!("CARGO_TARGET_TMPDIR")).join(format!("sandbox-native-{name}"));
    let _ = fs::remove_dir_all(&root);
    let config_rel = if home_writable {
        "home/.config/.pirc"
    } else {
        "config"
    };
    for dir in [
        "home/.ssh",
        "state",
        config_rel,
        "workspace/.git/hooks",
        "outside",
    ] {
        fs::create_dir_all(root.join(dir)).unwrap();
    }
    let root = fs::canonicalize(&root).unwrap();
    fs::write(root.join("home/.ssh/id_ed25519"), "secret").unwrap();
    fs::write(root.join("state/secret"), "node secret").unwrap();
    fs::write(root.join("workspace/README"), "hello").unwrap();
    fs::write(root.join("workspace/.git/config"), "[core]").unwrap();
    let allowed = if home_writable {
        r#""allowedPaths":["~"],"#
    } else {
        ""
    };
    fs::write(
        root.join(config_rel).join("config.json"),
        format!(
            r#"{{{allowed}"sandbox":{{"network":{{"defaultDomains":false,"allowedDomains":["localhost"]}}}}}}"#
        ),
    )
    .unwrap();
    let (home, state, config_dir) = (
        path(&root, "home"),
        path(&root, "state"),
        path(&root, config_rel),
    );
    // `TMPDIR` short and in `/tmp`, as on a node: the proxy socket's path
    // (`<TMPDIR>/pirc-n-*/pirc-*/proxy.sock`) must fit `sun_path`.
    let tmp_dir = tempfile::Builder::new()
        .prefix("pirc-t")
        .tempdir_in("/tmp")
        .unwrap();
    let tmp = fs::canonicalize(tmp_dir.path())
        .unwrap()
        .display()
        .to_string();
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
    let extra = extra(&root);
    let vars = vars
        .into_iter()
        .chain(extra.iter().map(|(k, v)| (k.as_str(), v.as_str())));
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
        tmp: tmp_dir,
        _serial: guard,
    })
}

impl Fixture {
    async fn prepare(&self, session: &str) -> Prepared {
        self.prepare_with(session, None, Vec::new()).await
    }

    async fn prepare_with(
        &self,
        session: &str,
        inference_socket: Option<PathBuf>,
        protected_paths: Vec<PathBuf>,
    ) -> Prepared {
        self.try_prepare_with(session, inference_socket, protected_paths)
            .await
            .unwrap()
    }

    async fn try_prepare(&self, session: &str) -> Result<Prepared, pirc_node::error::ApiError> {
        self.try_prepare_with(session, None, Vec::new()).await
    }

    async fn try_prepare_with(
        &self,
        session: &str,
        inference_socket: Option<PathBuf>,
        protected_paths: Vec<PathBuf>,
    ) -> Result<Prepared, pirc_node::error::ApiError> {
        let session_dir = self.config.sessions_dir.join(session);
        fs::create_dir_all(&session_dir).unwrap();
        self.sandbox
            .prepare(PrepareInput {
                grants: Vec::new(),
                session_id: session.to_owned(),
                workspace_root: self.root.join("workspace"),
                session_dir,
                inference_socket,
                protected_paths,
                workspace_memory_file: None,
                recovery: None,
            })
            .await
    }

    /// `script` as the agent (`/bin/sh -c <script>`): its exit code.
    async fn sh(&self, script: &str) -> i32 {
        self.sh_protecting(script, Vec::new()).await
    }

    /// [`Self::sh`] with `protected` among the session's protected paths.
    async fn sh_protecting(&self, script: &str, protected: Vec<PathBuf>) -> i32 {
        let prepared = self.prepare_with("pi_sh", None, protected).await;
        let mut command = prepared.command().unwrap();
        command
            .args(["-c", script])
            .envs(prepared.env.iter().map(|(k, v)| (k, v)))
            .current_dir(self.root.join("workspace"))
            .stdin(Stdio::null())
            .kill_on_drop(true);
        let status = tokio::time::timeout(Duration::from_secs(30), command.status())
            .await
            .unwrap()
            .unwrap();
        prepared.cleanup();
        status.code().unwrap_or(-1)
    }
}

#[tokio::test]
async fn confines_the_agent_to_the_session_policy() {
    let Some(f) = fixture("files") else {
        return;
    };
    assert!(matches!(
        f.sandbox.check().await,
        SandboxStatus::Active { .. }
    ));
    let (root, w) = (&f.root, path(&f.root, "workspace"));
    let session = f.config.sessions_dir.join("pi_sh").display().to_string();
    let cases = [
        ("probe", "exit 0".to_owned(), true),
        ("read the workspace", format!("cat {w}/README"), true),
        ("write the workspace", format!("echo x > {w}/new.txt"), true),
        (
            "write outside the write roots",
            format!("echo x > {}/x", path(root, "outside")),
            false,
        ),
        (
            "write the home directory",
            format!("echo x > {}/new", path(root, "home")),
            false,
        ),
        (
            "read ~/.ssh",
            format!("cat {}/.ssh/id_ed25519", path(root, "home")),
            false,
        ),
        (
            "write ~/.ssh",
            format!("echo x > {}/.ssh/x", path(root, "home")),
            false,
        ),
        (
            "read the node's private state",
            format!("cat {}/secret", path(root, "state")),
            false,
        ),
        (
            "read and write the session dir",
            format!("echo x > {session}/f && cat {session}/f"),
            true,
        ),
        (
            "write .git/hooks",
            format!("echo x > {w}/.git/hooks/pre-commit"),
            false,
        ),
        (
            "write .git/config",
            format!("echo x >> {w}/.git/config"),
            false,
        ),
        (
            "write the config dir",
            format!("echo x > {}/x", path(root, "config")),
            false,
        ),
        (
            "write /tmp",
            "echo x > /tmp/pirc-native-$$ && rm /tmp/pirc-native-$$".to_owned(),
            true,
        ),
        ("write $TMPDIR", "echo x > \"$TMPDIR/x\"".to_owned(), true),
        (
            "TMPDIR is the session's",
            format!(
                "case \"$TMPDIR\" in {}/pirc-n-*/pirc-*) exit 0;; esac; exit 1",
                fs::canonicalize(f.tmp.path()).unwrap().display()
            ),
            true,
        ),
        (
            "see a host process",
            format!("kill -0 {}", std::process::id()),
            false,
        ),
        ("exit status passes through", "exit 7".to_owned(), false),
    ];
    let mut failures = Vec::new();
    for (name, script, expect) in &cases {
        let code = f.sh(script).await;
        if (code == 0) != *expect {
            failures.push(format!("{name}: exit {code}"));
        }
    }
    assert_eq!(f.sh("exit 7").await, 7);
    assert!(failures.is_empty(), "{failures:#?}");
    assert!(root.join("workspace/new.txt").exists());
    assert_eq!(
        fs::read_to_string(root.join("workspace/.git/config")).unwrap(),
        "[core]"
    );
}

#[tokio::test]
async fn passes_stdio_through_untouched() {
    let Some(f) = fixture("stdio") else {
        return;
    };
    let prepared = f.prepare("pi_stdio").await;
    let mut command = prepared.command().unwrap();
    command
        .args([
            "-c",
            "while read line; do echo \"got $line\"; echo \"err $line\" >&2; done",
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    let mut child = command.spawn().unwrap();
    let mut stdin = child.stdin.take().unwrap();
    stdin
        .write_all(b"{\"type\":\"a\"}\nsecond\n")
        .await
        .unwrap();
    drop(stdin);
    let mut out = String::new();
    child
        .stdout
        .take()
        .unwrap()
        .read_to_string(&mut out)
        .await
        .unwrap();
    let mut err = String::new();
    child
        .stderr
        .take()
        .unwrap()
        .read_to_string(&mut err)
        .await
        .unwrap();
    assert!(child.wait().await.unwrap().success());
    assert_eq!(out, "got {\"type\":\"a\"}\ngot second\n");
    assert_eq!(err, "err {\"type\":\"a\"}\nerr second\n");
    prepared.cleanup();
}

/// A host server answering 200 to anything.
async fn upstream() -> u16 {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    tokio::spawn(async move {
        while let Ok((mut stream, _)) = listener.accept().await {
            tokio::spawn(async move {
                let mut buffer = [0u8; 4096];
                let _ = stream.read(&mut buffer).await;
                let _ = stream
                    .write_all(
                        b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok",
                    )
                    .await;
            });
        }
    });
    port
}

/// This test binary as the agent, running [`sandbox_client`] on `targets`
/// (stdin piped, for the client's pauses between targets).
fn client(prepared: &Prepared, targets: &str) -> tokio::process::Command {
    let command = prepared.command().unwrap();
    // The agent command is /bin/sh in the fixture: swap in the client.
    let mut args: Vec<_> = command.as_std().get_args().map(|a| a.to_owned()).collect();
    let at = args.iter().rposition(|a| a == "/bin/sh").unwrap();
    args[at] = std::env::current_exe().unwrap().into_os_string();
    let mut client = tokio::process::Command::new(command.as_std().get_program());
    // The descriptor mapping is not copied with the arguments.
    prepared.prepare_command_fds(&mut client).unwrap();
    client
        .args(&args)
        .args([
            "--exact",
            "sandbox_client",
            "--nocapture",
            "--test-threads=1",
        ])
        .envs(prepared.env.iter().map(|(k, v)| (k, v)))
        .env(CLIENT, targets)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true);
    client
}

/// The client's next result line.
async fn next_result(
    lines: &mut tokio::io::Lines<BufReader<tokio::process::ChildStdout>>,
) -> String {
    // libtest prints its own lines around the test's.
    loop {
        let line = tokio::time::timeout(Duration::from_secs(20), lines.next_line())
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        if let Some((_, result)) = line.split_once("@@ ") {
            return result.to_owned();
        }
    }
}

#[tokio::test]
async fn reaches_the_network_only_through_the_proxy_and_approvals_widen_it_in_place() {
    let Some(f) = fixture("network") else {
        return;
    };
    let port = upstream().await;
    let prepared = f.prepare("pi_net").await;
    assert!(prepared.has_control());
    let mut child = client(
        &prepared,
        &format!(
            "direct:{port} http://localhost:{port}/ http://127.0.0.1:{port}/ http://127.0.0.1:{port}/"
        ),
    )
    .spawn()
    .unwrap();
    let mut stdin = child.stdin.take().unwrap();
    let mut lines = BufReader::new(child.stdout.take().unwrap()).lines();
    let mut next = async || next_result(&mut lines).await;
    assert_eq!(next().await, "refused", "no direct network");
    stdin.write_all(b"\n").await.unwrap();
    assert_eq!(next().await, "HTTP/1.1 200 OK", "an allowed domain");
    stdin.write_all(b"\n").await.unwrap();
    assert_eq!(next().await, "HTTP/1.1 403 Forbidden", "not allowed yet");
    prepared.approve_domains(&["127.0.0.1".to_owned()]).unwrap();
    stdin.write_all(b"\n").await.unwrap();
    assert_eq!(next().await, "HTTP/1.1 200 OK", "approved while it runs");
    assert!(child.wait().await.unwrap().success());
    prepared.cleanup();
}

#[tokio::test]
async fn cleanup_removes_the_session_temp_directory() {
    let Some(f) = fixture("cleanup") else {
        return;
    };
    let prepared = f.prepare("pi_clean").await;
    let tmp = PathBuf::from(&prepared.env[0].1);
    assert!(tmp.join("proxy.sock").exists());
    prepared.cleanup();
    assert!(!tmp.exists());
}

/// Renaming a directory that merely contains a mount point is allowed on
/// Linux (the mount moves with it), so every writable directory above a
/// protected path must be a mount point itself: otherwise `mv .git x;
/// mkdir .git` gives the agent a `.git/config` the host's git trusts.
#[tokio::test]
async fn protected_paths_cannot_be_renamed_away() {
    let Some(f) = fixture_with("rename", true) else {
        return;
    };
    let (root, w) = (&f.root, path(&f.root, "workspace"));
    let home = path(root, "home");
    fs::create_dir_all(root.join("workspace/project/docs")).unwrap();
    let instructions = root.join("workspace/project/docs/AGENTS.md");
    fs::write(&instructions, "be nice").unwrap();
    let protected = vec![instructions.clone()];
    let refused = [
        ("rename .git", format!("mv {w}/.git {w}/.git.bak")),
        (
            "swap .git for a copy with a filter",
            format!(
                "mv {w}/.git {w}/.git.bak; mkdir -p {w}/.git && printf '[filter \"x\"]\\n' >> {w}/.git/config"
            ),
        ),
        ("rename .git/hooks", format!("mv {w}/.git/hooks {w}/.git/h")),
        (
            "rename .git/config",
            format!("mv {w}/.git/config {w}/.git/c"),
        ),
        ("remove .git/config", format!("rm -f {w}/.git/config")),
        (
            "hard-link .git/config to write it elsewhere",
            format!("ln {w}/.git/config {w}/c && echo x >> {w}/c"),
        ),
        (
            "replace .git with a directory",
            format!("mkdir {w}/g && mv -T {w}/g {w}/.git"),
        ),
        (
            "rename an ancestor of the project's instructions",
            format!(
                "mv {w}/project {w}/p && mkdir -p {w}/project/docs && echo x > {w}/project/docs/AGENTS.md"
            ),
        ),
        (
            "rename the instructions' parent",
            format!("mv {w}/project/docs {w}/project/d"),
        ),
        (
            "rename ~/.config",
            format!(
                "mv {home}/.config {home}/c && mkdir -p {home}/.config/.pirc && echo '{{}}' > {home}/.config/.pirc/config.json"
            ),
        ),
        (
            "rename ~/.config/.pirc",
            format!("mv {home}/.config/.pirc {home}/.config/p"),
        ),
        (
            "write ~/.config/.pirc",
            format!("echo x > {home}/.config/.pirc/config.json"),
        ),
    ];
    let mut failures = Vec::new();
    for (name, script) in &refused {
        let code = f.sh_protecting(script, protected.clone()).await;
        if code == 0 {
            failures.push(format!("{name}: allowed"));
        }
    }
    // What stays writable around them.
    let allowed = [
        ("write ~", format!("echo x > {home}/new")),
        ("write in .git", format!("echo x > {w}/.git/description")),
        (
            "write next to the instructions",
            format!("echo x > {w}/project/docs/notes.md"),
        ),
        (
            "write in ~/.config",
            format!("mkdir -p {home}/.config/tool && echo x > {home}/.config/tool/rc"),
        ),
    ];
    for (name, script) in &allowed {
        let code = f.sh_protecting(script, protected.clone()).await;
        if code != 0 {
            failures.push(format!("{name}: exit {code}"));
        }
    }
    assert!(failures.is_empty(), "{failures:#?}");
    assert_eq!(
        fs::read_to_string(root.join("workspace/.git/config")).unwrap(),
        "[core]"
    );
    assert_eq!(fs::read_to_string(&instructions).unwrap(), "be nice");
    for gone in [
        "workspace/.git.bak",
        "workspace/p",
        "workspace/project/d",
        "home/c",
        "home/.config/p",
    ] {
        assert!(!root.join(gone).exists(), "{gone}");
    }
    assert!(root.join("home/.config/.pirc/config.json").exists());
    assert!(root.join("home/new").exists());
}

/// A workspace whose `.git` links to the repository elsewhere: bubblewrap
/// cannot pin the link, and the agent could replace it with a directory of
/// its own (`.git/config` with a filter the host's git runs), so the
/// session refuses to start; the same for `.pirc`. A link the agent cannot
/// replace is fine, and its target is protected.
#[tokio::test]
async fn refuses_protected_paths_behind_replaceable_symlinks() {
    let Some(f) = fixture("git-link") else {
        return;
    };
    let w = path(&f.root, "workspace");
    fs::rename(
        f.root.join("workspace/.git"),
        f.root.join("workspace/.git-real"),
    )
    .unwrap();
    std::os::unix::fs::symlink(
        f.root.join("workspace/.git-real"),
        f.root.join("workspace/.git"),
    )
    .unwrap();
    let Err(error) = f.try_prepare("pi_link").await else {
        panic!("started");
    };
    assert_eq!(error.status, 503);
    assert_eq!(
        error.message,
        format!(
            "Agents on this node must run in the sandbox, and it is unavailable: the protected path {w}/.git/hooks goes through the symbolic link {w}/.git, which the agent could replace (bubblewrap cannot pin a link); replace the link with the file or directory it points to"
        )
    );
    fs::remove_file(f.root.join("workspace/.git")).unwrap();
    fs::rename(
        f.root.join("workspace/.git-real"),
        f.root.join("workspace/.git"),
    )
    .unwrap();
    fs::create_dir_all(f.root.join("outside/pirc")).unwrap();
    std::os::unix::fs::symlink(f.root.join("outside/pirc"), f.root.join("workspace/.pirc"))
        .unwrap();
    let Err(error) = f.try_prepare("pi_link").await else {
        panic!("started");
    };
    assert!(
        error.message.contains(&format!("symbolic link {w}/.pirc,")),
        "{}",
        error.message
    );
    // Nothing left behind by the refused starts.
    assert!(!f.root.join("workspace/.bashrc").exists());
}

/// The links in the middle of a protected path's chain count too: a link
/// the agent cannot replace that leads through one it can (or through a
/// directory it can replace, left by `..`) follows whatever the agent puts
/// there. So do the links of the denies the policy lists only by their
/// targets (`~/.ssh` linking out of a writable home).
#[tokio::test]
async fn refuses_links_in_the_middle_of_a_protected_chain() {
    let Some(f) = fixture_with("chain", true) else {
        return;
    };
    let (root, home) = (&f.root, path(&f.root, "home"));
    fs::create_dir_all(root.join("workspace/project")).unwrap();
    fs::create_dir_all(root.join("home/sub")).unwrap();
    fs::write(root.join("workspace/project/AGENTS.md"), "be nice").unwrap();
    // outside/entry -> ~/hop -> workspace/project
    std::os::unix::fs::symlink(root.join("home/hop"), root.join("outside/entry")).unwrap();
    std::os::unix::fs::symlink(root.join("workspace/project"), root.join("home/hop")).unwrap();
    let refused = async |protected: &str| {
        let protected = root.join(protected);
        let Err(error) = f
            .try_prepare_with("pi_chain", None, vec![protected.clone()])
            .await
        else {
            panic!("started with {}", protected.display());
        };
        assert_eq!(error.status, 503);
        error.message
    };
    assert_eq!(
        refused("outside/entry/AGENTS.md").await,
        format!(
            "Agents on this node must run in the sandbox, and it is unavailable: the protected path {} goes through the symbolic link {home}/hop, which the agent could replace (bubblewrap cannot pin a link); replace the link with the file or directory it points to",
            path(root, "outside/entry/AGENTS.md")
        )
    );
    // outside/up -> ~/sub/../../workspace/project: `~/sub` replaced by a
    // link moves where `..` leads.
    std::os::unix::fs::symlink(
        format!("{home}/sub/../../workspace/project"),
        root.join("outside/up"),
    )
    .unwrap();
    let message = refused("outside/up/AGENTS.md").await;
    assert!(
        message.contains(&format!("goes through the directory {home}/sub ")),
        "{message}"
    );
    // A sensitive path the policy lists by its target.
    fs::rename(root.join("home/.ssh"), root.join("outside/ssh")).unwrap();
    std::os::unix::fs::symlink(root.join("outside/ssh"), root.join("home/.ssh")).unwrap();
    let Err(error) = f.try_prepare("pi_chain").await else {
        panic!("started with a replaceable ~/.ssh link");
    };
    assert!(
        error.message.contains(&format!(
            "the protected path {home}/.ssh goes through the symbolic link {home}/.ssh,"
        )),
        "{}",
        error.message
    );
    // Not replaceable: the target is protected and the session starts.
    fs::remove_file(root.join("home/.ssh")).unwrap();
    fs::rename(root.join("outside/ssh"), root.join("home/.ssh")).unwrap();
    fs::remove_file(root.join("home/hop")).unwrap();
    std::os::unix::fs::symlink(root.join("workspace/project"), root.join("outside/hop")).unwrap();
    fs::remove_file(root.join("outside/entry")).unwrap();
    std::os::unix::fs::symlink(root.join("outside/hop"), root.join("outside/entry")).unwrap();
    let protected = vec![root.join("outside/entry/AGENTS.md")];
    let code = f
        .sh_protecting(
            &format!("echo x > {}", path(root, "workspace/project/AGENTS.md")),
            protected,
        )
        .await;
    assert_ne!(code, 0);
    assert_eq!(
        fs::read_to_string(root.join("workspace/project/AGENTS.md")).unwrap(),
        "be nice"
    );
}

/// The node's private directories keep their spelling into the policy:
/// systemd's credentials directory reached through a link in a writable
/// home could be replaced by a directory of the agent's (the node's token).
#[tokio::test]
async fn refuses_a_private_dir_behind_a_replaceable_link() {
    let Some(f) = fixture_env("private-link", true, |root| {
        fs::create_dir_all(root.join("outside/creds")).unwrap();
        std::os::unix::fs::symlink(root.join("outside/creds"), root.join("home/creds")).unwrap();
        vec![("CREDENTIALS_DIRECTORY".to_owned(), path(root, "home/creds"))]
    }) else {
        return;
    };
    let creds = path(&f.root, "home/creds");
    let Err(error) = f.try_prepare("pi_private").await else {
        panic!("started");
    };
    assert_eq!(error.status, 503);
    assert_eq!(
        error.message,
        format!(
            "Agents on this node must run in the sandbox, and it is unavailable: the protected path {creds} goes through the symbolic link {creds}, which the agent could replace (bubblewrap cannot pin a link); replace the link with the file or directory it points to"
        )
    );
}

/// tmux's recipe, `SSH_AUTH_SOCK` a stable link in `/tmp` (a write root of
/// every session) to the agent's socket, starts sessions: host sockets are
/// hidden from reading, not protected for host tools. The link's target
/// at plan time is hidden, here outside every writable root
/// (`sandbox_linux_ssh_agent.rs` has it under `/tmp`).
#[tokio::test]
async fn a_linked_ssh_agent_socket_is_hidden_and_refuses_nothing() {
    let link = Path::new("/tmp").join(format!("pirc-ssh-agent-{}", std::process::id()));
    let _ = fs::remove_file(&link);
    let link_var = link.display().to_string();
    let Some(f) = fixture_env("ssh-agent", false, |_| {
        vec![("SSH_AUTH_SOCK".to_owned(), link_var.clone())]
    }) else {
        return;
    };
    let socket_path = f.root.join("outside/agent.sock");
    let listener = std::os::unix::net::UnixListener::bind(&socket_path).unwrap();
    std::thread::spawn(move || {
        for mut stream in listener.incoming().flatten() {
            let _ = stream.write_all(b"agent");
        }
    });
    std::os::unix::fs::symlink(&socket_path, &link).unwrap();
    let started = f.try_prepare("pi_ssh").await;
    let _ = fs::remove_file(&link);
    let prepared = started.unwrap();
    // The link is gone by now; the target's mount is what counts.
    let mut command = client(&prepared, &format!("unix:{}", socket_path.display()));
    command.stdin(Stdio::null());
    let mut child = command.spawn().unwrap();
    let mut lines = BufReader::new(child.stdout.take().unwrap()).lines();
    let result = next_result(&mut lines).await;
    assert!(result.starts_with("unreachable"), "{result}");
    assert!(child.wait().await.unwrap().success());
    prepared.cleanup();
}

/// Unix sockets bound on the host are hidden but the allowed ones (here
/// the inference socket).
#[tokio::test]
async fn host_unix_sockets_are_hidden_but_the_allowed() {
    let Some(f) = fixture("host-sockets") else {
        return;
    };
    // Direct Unix socket binds must fit SUN_LEN even in a deeply nested
    // checkout. Keep the host sockets outside the workspace, at short paths.
    let sockets = tempfile::Builder::new()
        .prefix("pirc-sockets-")
        .tempdir_in("/tmp")
        .unwrap();
    let serve = |name: &str| {
        let path = sockets.path().join(name);
        let listener = std::os::unix::net::UnixListener::bind(&path).unwrap();
        std::thread::spawn(move || {
            for mut stream in listener.incoming().flatten() {
                let _ = stream.write_all(b"pong");
            }
        });
        path
    };
    let (other, inference) = (serve("other.sock"), serve("inference.sock"));
    let prepared = f
        .prepare_with("pi_sockets", Some(inference.clone()), Vec::new())
        .await;
    let mut command = client(
        &prepared,
        &format!("unix:{} unix:{}", other.display(), inference.display()),
    );
    let mut child = command.spawn().unwrap();
    let mut stdin = child.stdin.take().unwrap();
    let mut lines = BufReader::new(child.stdout.take().unwrap()).lines();
    let hidden = next_result(&mut lines).await;
    assert!(hidden.starts_with("unreachable"), "{hidden}");
    stdin.write_all(b"\n").await.unwrap();
    assert_eq!(next_result(&mut lines).await, "pong");
    drop(stdin);
    assert!(child.wait().await.unwrap().success());
    prepared.cleanup();
}

/// A session reads, appends to and locks its own workspace-memory ledger
/// (the node makes it), and reaches no other file of the directory.
#[tokio::test]
async fn opens_only_its_own_workspace_memory_ledger() {
    let Some(f) = fixture("ledger") else {
        return;
    };
    let dir = f.config.workspace_memory_dir.clone();
    fs::create_dir_all(&dir).unwrap();
    fs::write(dir.join("other.jsonl"), "other\n").unwrap();
    let ledger = dir.join("0123456789abcdef.jsonl");
    let session_dir = f.config.sessions_dir.join("pi_ledger");
    fs::create_dir_all(&session_dir).unwrap();
    let prepared = f
        .sandbox
        .prepare(PrepareInput {
            grants: Vec::new(),
            session_id: "pi_ledger".to_owned(),
            workspace_root: f.root.join("workspace"),
            session_dir,
            inference_socket: None,
            protected_paths: Vec::new(),
            workspace_memory_file: Some(ledger.clone()),
            recovery: None,
        })
        .await
        .unwrap();
    let (dir_text, ledger_text) = (dir.display().to_string(), ledger.display().to_string());
    let script = format!(
        r#"printf 'line\n' >> '{ledger_text}' || exit 1
        cat '{ledger_text}' >/dev/null || exit 2
        cat '{dir_text}/other.jsonl' 2>/dev/null && exit 3
        printf x 2>/dev/null >> '{dir_text}/other.jsonl' && exit 4
        touch '{dir_text}/0123456789abcdef.lock' 2>/dev/null && exit 5
        if command -v flock >/dev/null; then flock -n '{ledger_text}' true || exit 6; fi
        exit 0"#
    );
    let mut command = prepared.command().unwrap();
    command
        .args(["-c", &script])
        .envs(prepared.env.iter().map(|(k, v)| (k, v)))
        .current_dir(f.root.join("workspace"))
        .stdin(Stdio::null())
        .kill_on_drop(true);
    let status = tokio::time::timeout(Duration::from_secs(30), command.status())
        .await
        .unwrap()
        .unwrap();
    prepared.cleanup();
    assert_eq!(status.code(), Some(0));
    assert_eq!(fs::read_to_string(&ledger).unwrap(), "line\n");
    assert_eq!(
        fs::read_to_string(dir.join("other.jsonl")).unwrap(),
        "other\n"
    );
}

/// Protected paths that do not exist yet get placeholders, so the agent
/// cannot create them, and the placeholders' parents are pinned so they
/// cannot be renamed away either. Everything bubblewrap made on the host
/// is gone after the session.
#[tokio::test]
async fn missing_protected_paths_cannot_be_created() {
    let Some(f) = fixture("missing") else {
        return;
    };
    let (root, w) = (&f.root, path(&f.root, "workspace"));
    fs::remove_dir_all(root.join("workspace/.git/hooks")).unwrap();
    fs::remove_file(root.join("workspace/.git/config")).unwrap();
    fs::create_dir_all(root.join("workspace/project")).unwrap();
    // Missing below an existing directory, and behind a dangling link in a
    // directory the agent cannot write (resolved where writes would land).
    let instructions = root.join("workspace/project/docs/AGENTS.md");
    std::os::unix::fs::symlink(root.join("workspace/later"), root.join("outside/link")).unwrap();
    let protected = vec![instructions.clone(), root.join("outside/link/CHAT.md")];
    let refused = [
        ("create .pirc", format!("mkdir {w}/.pirc")),
        (
            "create .pirc/config.json",
            format!("mkdir -p {w}/.pirc && echo '{{}}' > {w}/.pirc/config.json"),
        ),
        (
            "create .git/hooks",
            format!("mkdir -p {w}/.git/hooks && echo x > {w}/.git/hooks/pre-commit"),
        ),
        (
            "create .git/config",
            format!("printf '[core]\\n' > {w}/.git/config"),
        ),
        (
            "swap .git to create its config",
            format!("mv {w}/.git {w}/g && mkdir -p {w}/.git/hooks && echo x > {w}/.git/config"),
        ),
        ("create .bashrc", format!("echo x > {w}/.bashrc")),
        ("create .mcp.json", format!("echo '{{}}' > {w}/.mcp.json")),
        (
            "create .vscode",
            format!("mkdir -p {w}/.vscode && echo x > {w}/.vscode/tasks.json"),
        ),
        (
            "create .claude/commands",
            format!("mkdir -p {w}/.claude/commands && echo x > {w}/.claude/commands/x.md"),
        ),
        (
            "create the instructions",
            format!("mkdir -p {w}/project/docs && echo x > {w}/project/docs/AGENTS.md"),
        ),
        (
            "rename the instructions' parent to create them",
            format!(
                "mv {w}/project {w}/p && mkdir -p {w}/project/docs && echo x > {w}/project/docs/AGENTS.md"
            ),
        ),
        (
            "create through the dangling link's target",
            format!("mkdir -p {w}/later && echo x > {w}/later/CHAT.md"),
        ),
        ("remove a placeholder", format!("rm -f {w}/.bashrc")),
    ];
    let mut failures = Vec::new();
    for (name, script) in &refused {
        if f.sh_protecting(script, protected.clone()).await == 0 {
            failures.push(format!("{name}: allowed"));
        }
    }
    let allowed = [
        (
            "write the workspace",
            format!("mkdir -p {w}/src && echo x > {w}/src/main.rs"),
        ),
        ("write in .git", format!("echo x > {w}/.git/description")),
        (
            "write next to the instructions",
            format!("echo x > {w}/project/notes.md"),
        ),
    ];
    for (name, script) in &allowed {
        let code = f.sh_protecting(script, protected.clone()).await;
        if code != 0 {
            failures.push(format!("{name}: exit {code}"));
        }
    }
    assert!(failures.is_empty(), "{failures:#?}");
    for gone in [
        ".pirc",
        ".git/hooks",
        ".git/config",
        ".bashrc",
        ".mcp.json",
        ".vscode",
        ".claude",
        "project/docs",
        "later",
        "g",
        "p",
    ] {
        assert!(
            self::gone(&root.join("workspace").join(gone)).await,
            "{gone} left on the host"
        );
    }
    assert!(root.join("workspace/src/main.rs").exists());
}

/// A path denied for reading that does not exist yet cannot be created
/// (and then read) inside a writable root either: it gets a hidden
/// placeholder, gone after the session.
#[tokio::test]
async fn missing_read_denies_cannot_be_created() {
    let Some(f) = fixture_env("missing-read", false, |root| {
        let w = path(root, "workspace");
        fs::write(
            root.join("config/config.json"),
            format!(
                r#"{{"sandbox":{{"network":{{"defaultDomains":false}},"filesystem":{{"denyRead":["{w}/.env","{w}/secrets/token"]}}}}}}"#
            ),
        )
        .unwrap();
        Vec::new()
    }) else {
        return;
    };
    let w = path(&f.root, "workspace");
    let refused = [
        ("create .env", format!("echo x > {w}/.env && cat {w}/.env")),
        (
            "create secrets/token",
            format!("mkdir -p {w}/secrets && echo x > {w}/secrets/token && cat {w}/secrets/token"),
        ),
        ("remove a placeholder", format!("rm -f {w}/.env")),
    ];
    let mut failures = Vec::new();
    for (name, script) in &refused {
        if f.sh(script).await == 0 {
            failures.push(format!("{name}: allowed"));
        }
    }
    if f.sh(&format!("echo x > {w}/notes && cat {w}/notes")).await != 0 {
        failures.push("write the workspace: refused".to_owned());
    }
    assert!(failures.is_empty(), "{failures:#?}");
    for gone in [".env", "secrets"] {
        assert!(
            self::gone(&f.root.join("workspace").join(gone)).await,
            "{gone} left on the host"
        );
    }
}

/// What the mandatory scan finds below the workspace stays read-only even
/// though the policy does not list it: nested repositories' config, editor
/// settings, shell rc files and `.mcp.json`.
#[tokio::test]
async fn mandatory_deny_paths_hold() {
    let Some(f) = fixture("mandatory") else {
        return;
    };
    let (root, w) = (&f.root, path(&f.root, "workspace"));
    for (file, content) in [
        ("sub/.git/config", "[core]"),
        ("sub/.vscode/tasks.json", "{}"),
        ("sub/deeper/.bashrc", "# rc"),
        (".mcp.json", "{}"),
        (".claude/commands/deploy.md", "deploy"),
        ("node_modules/pkg/.bashrc", "# a package's"),
    ] {
        let file = root.join("workspace").join(file);
        fs::create_dir_all(file.parent().unwrap()).unwrap();
        fs::write(file, content).unwrap();
    }
    let refused = [
        (
            "nested .git/config",
            format!("echo x >> {w}/sub/.git/config"),
        ),
        ("rename a nested .git", format!("mv {w}/sub/.git {w}/sub/g")),
        (
            "nested .vscode",
            format!("echo x > {w}/sub/.vscode/launch.json"),
        ),
        (
            "nested .bashrc",
            format!("echo x >> {w}/sub/deeper/.bashrc"),
        ),
        (
            "rename the directory of a nested .bashrc",
            format!("mv {w}/sub/deeper {w}/sub/d"),
        ),
        (".mcp.json", format!("echo x >> {w}/.mcp.json")),
        (
            "a file in .claude/commands",
            format!("echo x >> {w}/.claude/commands/deploy.md"),
        ),
    ];
    let mut failures = Vec::new();
    for (name, script) in &refused {
        if f.sh(script).await == 0 {
            failures.push(format!("{name}: allowed"));
        }
    }
    // Inside node_modules: not scanned, as with srt.
    let code = f
        .sh(&format!("echo x >> {w}/node_modules/pkg/.bashrc"))
        .await;
    if code != 0 {
        failures.push(format!("node_modules: exit {code}"));
    }
    assert!(failures.is_empty(), "{failures:#?}");
    assert_eq!(
        fs::read_to_string(root.join("workspace/sub/.git/config")).unwrap(),
        "[core]"
    );
}

/// A placeholder left by a node that died (an empty read-only file the
/// node recorded) is removed at the node's first plan (and placed again
/// for the session, then removed after it); a user's own file that looks
/// the same (unrecorded) is covered but kept.
/// Two sessions of one workspace share placeholders, which stay until the
/// last one ends.
#[tokio::test]
async fn placeholders_outlive_no_session_and_are_shared() {
    use std::os::unix::fs::PermissionsExt;

    let Some(f) = fixture("placeholders") else {
        return;
    };
    let stale = f.root.join("workspace/.zprofile");
    let users = f.root.join("workspace/.zshrc");
    for file in [&stale, &users] {
        fs::write(file, "").unwrap();
        fs::set_permissions(file, fs::Permissions::from_mode(0o444)).unwrap();
    }
    let record = f.root.join("state/sandbox/placeholders");
    fs::create_dir_all(record.parent().unwrap()).unwrap();
    fs::write(&record, format!("{}\n", stale.display())).unwrap();
    let first = f.prepare("pi_one").await;
    let second = f.prepare("pi_two").await;
    let mut child = first.command().unwrap();
    let mut first_child = child
        .args(["-c", "read line"])
        .stdin(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .unwrap();
    // bubblewrap makes the placeholders as it starts.
    let bashrc = f.root.join("workspace/.bashrc");
    for _ in 0..200 {
        if bashrc.exists() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    assert!(bashrc.exists());
    let recorded = fs::read_to_string(&record).unwrap();
    assert!(
        recorded.lines().any(|line| Path::new(line) == bashrc),
        "{recorded}"
    );
    assert_eq!(
        fs::metadata(&record).unwrap().permissions().mode() & 0o777,
        0o600
    );
    assert_eq!(f.sh("exit 0").await, 0);
    drop(second);
    assert!(bashrc.exists(), "the first session still uses it");
    drop(first_child.stdin.take());
    first_child.wait().await.unwrap();
    first.cleanup();
    assert!(gone(&bashrc).await);
    assert!(gone(&stale).await);
    assert!(users.exists(), "a user's file is never removed");
    // The record is rewritten just after the removals.
    let mut recorded = String::new();
    for _ in 0..200 {
        recorded = fs::read_to_string(&record).unwrap();
        if !recorded.contains(&path(&f.root, "workspace")) {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    assert!(
        !recorded.contains(&path(&f.root, "workspace")),
        "{recorded}"
    );
}

/// A session starting while another runs sees the first one's directory
/// placeholder (`.claude`, for `.claude/commands`) as an empty directory:
/// it shares it rather than placing its own placeholders inside, so the
/// directory goes when both have ended.
#[tokio::test]
async fn overlapping_sessions_share_directory_placeholders() {
    let Some(f) = fixture("overlap") else {
        return;
    };
    let claude = f.root.join("workspace/.claude");
    let start = |prepared: &Prepared| {
        let mut command = prepared.command().unwrap();
        command
            .args(["-c", "read line; exit 0"])
            .current_dir(f.root.join("workspace"))
            .stdin(Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .unwrap()
    };
    let first = f.prepare("pi_a").await;
    let mut a = start(&first);
    for _ in 0..200 {
        if claude.exists() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    assert!(claude.is_dir());
    let second = f.prepare("pi_b").await;
    let mut b = start(&second);
    // Let the second bubblewrap set its mounts up.
    tokio::time::sleep(Duration::from_millis(300)).await;
    let inside: Vec<_> = fs::read_dir(&claude)
        .unwrap()
        .flatten()
        .map(|entry| entry.file_name())
        .collect();
    assert!(inside.is_empty(), "placed inside: {inside:?}");
    drop(a.stdin.take());
    assert!(a.wait().await.unwrap().success());
    first.cleanup();
    assert!(claude.exists(), "the second session still uses it");
    drop(b.stdin.take());
    assert!(b.wait().await.unwrap().success());
    second.cleanup();
    assert!(gone(&claude).await, ".claude left on the host");
}

/// The node's inference socket lives in a private directory of its state,
/// which the sandbox hides: the policy gives that one directory back.
#[tokio::test]
async fn reaches_the_inference_socket_inside_the_hidden_state() {
    use std::os::unix::fs::DirBuilderExt;

    let Some(f) = fixture("inference") else {
        return;
    };
    let dir = f.root.join("state/i-test");
    fs::DirBuilder::new().mode(0o700).create(&dir).unwrap();
    let socket = dir.join("socket");
    let listener = std::os::unix::net::UnixListener::bind(&socket).unwrap();
    std::thread::spawn(move || {
        for mut stream in listener.incoming().flatten() {
            let mut line = String::new();
            let _ = std::io::BufReader::new(&stream).read_line(&mut line);
            let _ = write!(stream, "pong {}", line.trim());
        }
    });
    let prepared = f
        .prepare_with("pi_inference", Some(socket.clone()), Vec::new())
        .await;
    let mut command = client(
        &prepared,
        &format!(
            "unix:{} read:{} read:{}",
            socket.display(),
            f.root.join("state/secret").display(),
            f.root.join("workspace/README").display(),
        ),
    );
    command.stdin(Stdio::null());
    let mut child = command.spawn().unwrap();
    let mut lines = BufReader::new(child.stdout.take().unwrap()).lines();
    assert_eq!(next_result(&mut lines).await, "pong ping");
    assert_eq!(
        next_result(&mut lines).await,
        "unreadable: NotFound",
        "the rest of the state stays hidden"
    );
    assert_eq!(next_result(&mut lines).await, "read");
    assert!(child.wait().await.unwrap().success());
    prepared.cleanup();
}

/// A start dropped mid-await leaves no temporary directories behind,
/// including work still running on the blocking pool.
#[tokio::test]
async fn a_dropped_start_leaves_no_temp_dir() {
    let Some(f) = fixture("dropped") else {
        return;
    };
    let tmp = f.tmp.path();
    let left = || {
        let mut left = Vec::new();
        for entry in fs::read_dir(tmp).unwrap().flatten() {
            let path = entry.path();
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.starts_with("pirc-n-") {
                left.extend(fs::read_dir(&path).unwrap().flatten().map(|e| e.path()));
            } else {
                left.push(path);
            }
        }
        left
    };
    // Observe a directory before cancelling. A fixed 1 ms timeout can
    // expire before the blocking worker starts, letting an empty-directory
    // check pass just before that detached worker creates its directory.
    let mut started = Box::pin(f.try_prepare("pi_dropped"));
    // Poll prepare once to submit its policy worker, then leave it paused
    // at that await even if the worker finishes before the next timer tick.
    tokio::select! {
        biased;
        _ = &mut started => panic!("the start finished before cancellation"),
        _ = std::future::ready(()) => {},
    }
    tokio::time::timeout(Duration::from_secs(10), async {
        while left().is_empty() {
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
    })
    .await
    .expect("the start did not create a temporary directory");
    drop(started);
    // The policy worker may still be finishing. Once its observed
    // directory disappears, no cancelled prepare future can start a probe.
    tokio::time::timeout(Duration::from_secs(2), async {
        loop {
            if left().is_empty() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .unwrap_or_else(|_| {
        panic!(
            "temporary directories left after cancellation: {:?}",
            left()
        )
    });
}

/// The actual PID namespace must retire a detached writer, not just its login
/// shell. This test runs in the existing Linux bubblewrap CI job, not on macOS.
#[tokio::test]
async fn isolated_work_terminal_guards_start_and_retires_detached_writers() {
    let Some(f) = fixture("work-terminal") else {
        return;
    };
    let workspace = f.root.join("workspace");
    let shell = workspace.join("work-shell");
    let marker = workspace.join("started");
    let detached = workspace.join("detached-output");
    let peer = f.root.join("outside/user-kept");
    fs::write(&peer, "later user change").unwrap();
    fs::write(&shell,format!("#!/bin/sh\n: </dev/tty || exit 72\ncat '{}' > '{}' 2>/dev/null || :\nprintf changed > '{}' 2>/dev/null || :\nsetsid /bin/sh -c 'exec 3>\"$1\"; while :; do printf x >&3; sleep 0.05; done' detached '{}' &\nprintf ready > '{}'\nwait\n",f.root.join("state/secret").display(),workspace.join("leaked").display(),peer.display(),detached.display(),marker.display())).unwrap();
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(&shell, fs::Permissions::from_mode(0o700)).unwrap();
    let session = f.config.sessions_dir.join("work-terminal");
    fs::create_dir_all(&session).unwrap();
    let prepared = f
        .sandbox
        .prepare_terminal(
            PrepareInput {
                grants: Vec::new(),
                recovery: None,
                session_id: "work-terminal".into(),
                workspace_root: workspace.clone(),
                session_dir: session,
                inference_socket: None,
                protected_paths: vec![],
                workspace_memory_file: None,
            },
            shell,
        )
        .await
        .unwrap();
    let (read, mut gate) = std::io::pipe().unwrap();
    let mut command = prepared.terminal_command(read.into()).unwrap();
    command
        .current_dir(&workspace)
        .env_clear()
        .env("PATH", std::env::var("PATH").unwrap_or_default())
        .env("HOME", f.root.join("home"))
        .envs(prepared.env.iter().map(|(k, v)| (k, v)))
        .env("PIRC_NATIVE_LAUNCH_GUARD", "terminal-v1");
    let (master, slave) = pirc_node::terminals::pty::open(24, 80).unwrap();
    let pump = tokio::spawn(async move {
        let mut bytes = [0u8; 4096];
        while let Ok(1..) = master.read(&mut bytes).await {}
    });
    let mut child = pirc_node::terminals::pty::spawn_isolated(slave, command).unwrap();
    prepared.process_spawned(child.id().unwrap());
    use pirc_node::sandbox::processes::State;
    tokio::time::timeout(Duration::from_secs(5), async {
        while prepared.process_scope_state() == State::Observing {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap();
    assert_eq!(prepared.process_scope_state(), State::Running);
    assert!(prepared.process_snapshot().identity.is_some());
    assert!(
        !marker.exists(),
        "Login hooks ran before the private permit"
    );
    gate.write_all(b"PIRC-LAUNCH-1\n").unwrap();
    drop(gate);
    tokio::time::timeout(Duration::from_secs(5), async {
        while !marker.exists() || fs::metadata(&detached).map_or(true, |m| m.len() == 0) {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap();
    assert_eq!(fs::read_to_string(&peer).unwrap(), "later user change");
    assert!(
        !fs::read_to_string(workspace.join("leaked"))
            .unwrap_or_default()
            .contains("node secret")
    );
    prepared.terminate_processes();
    assert_eq!(
        prepared.wait_processes(Duration::from_secs(5)).await,
        State::Terminated
    );
    tokio::time::timeout(Duration::from_secs(5), child.wait())
        .await
        .unwrap()
        .unwrap();
    let bytes = fs::metadata(&detached).unwrap().len();
    tokio::time::sleep(Duration::from_millis(150)).await;
    assert_eq!(
        fs::metadata(detached).unwrap().len(),
        bytes,
        "A detached writer survived scope retirement"
    );
    prepared.cleanup();
    pump.abort();
    let _ = pump.await;
}
