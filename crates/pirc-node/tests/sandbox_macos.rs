//! The macOS sandbox for real: `sandbox-exec` with the session's Seatbelt
//! profile, the loopback proxy, and a shell as the agent. The macOS cases of
//! `sandbox.integration.test.ts` / `sandbox-srt.integration.test.ts`, the
//! protected paths with rename-style bypasses (security audit S7), symlinked
//! and missing paths, local binding and Unix sockets.
//!
//! Network checks run this test binary inside the sandbox as a small client
//! (the `sandbox_client` test, which does nothing unless
//! `PIRC_SANDBOX_TEST_CLIENT` is set). Seatbelt profiles do not nest: run
//! these outside any other sandbox.

#![cfg(target_os = "macos")]

use std::fs;
use std::io::{BufRead, Read, Write};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use pirc_config::{Env, NodeConfig};
use pirc_node::sandbox::macos::MacSandbox;
use pirc_node::sandbox::{PrepareInput, Prepared, ReadonlyInput, Sandbox, SandboxStatus};
use pirc_protocol::NodeRole;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};

mod persistence_support;

const CLIENT: &str = "PIRC_SANDBOX_TEST_CLIENT";

/// `user:pass@host:port` of `HTTP_PROXY`, user and password decoded.
fn proxy_from_env() -> Option<(Option<String>, String)> {
    let url = std::env::var("HTTP_PROXY").ok()?;
    let rest = url.strip_prefix("http://")?.trim_end_matches('/');
    let decode = |text: &str| {
        let bytes = text.as_bytes();
        let mut out = Vec::new();
        let mut at = 0;
        while at < bytes.len() {
            if bytes[at] == b'%'
                && let Ok(byte) = u8::from_str_radix(text.get(at + 1..at + 3).unwrap_or(""), 16)
            {
                out.push(byte);
                at += 3;
                continue;
            }
            out.push(bytes[at]);
            at += 1;
        }
        String::from_utf8(out).unwrap()
    };
    Some(match rest.rsplit_once('@') {
        Some((userinfo, address)) => {
            let (user, pass) = userinfo.split_once(':').unwrap_or((userinfo, ""));
            (
                Some(format!("{}:{}", decode(user), decode(pass))),
                address.replace("localhost", "127.0.0.1"),
            )
        }
        None => (None, rest.replace("localhost", "127.0.0.1")),
    })
}

/// Inside the sandbox: for each space-separated target, one line on
/// stdout. `direct:<port>` connects to the host's port without the proxy;
/// `bind` listens on a loopback port and connects to it; `unix:<path>`
/// sends `ping` to a Unix socket and prints the answer; `read:<path>` says
/// whether the file can be read; a URL is fetched through `HTTP_PROXY`.
/// Every target after the first waits for a line on stdin first.
#[test]
fn sandbox_client() {
    use base64::Engine as _;
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
        } else if target == "bind" {
            match std::net::TcpListener::bind("127.0.0.1:0") {
                Err(error) => format!("no bind: {:?}", error.kind()),
                Ok(listener) => {
                    let port = listener.local_addr().unwrap().port();
                    match std::net::TcpStream::connect(("127.0.0.1", port)) {
                        Ok(_) => "bound".to_owned(),
                        Err(error) => format!("bound, no connect: {:?}", error.kind()),
                    }
                }
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
            let Some((auth, address)) = proxy_from_env() else {
                panic!("no HTTP_PROXY");
            };
            match std::net::TcpStream::connect(&address) {
                Err(error) => format!("no proxy: {error}"),
                Ok(mut stream) => {
                    let host = target
                        .trim_start_matches("http://")
                        .split('/')
                        .next()
                        .unwrap();
                    let auth = auth.map_or_else(String::new, |auth| {
                        format!(
                            "Proxy-Authorization: Basic {}\r\n",
                            base64::engine::general_purpose::STANDARD.encode(auth)
                        )
                    });
                    write!(
                        stream,
                        "GET {target} HTTP/1.1\r\nHost: {host}\r\n{auth}\r\n"
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

struct Fixture {
    root: PathBuf,
    workspace: PathBuf,
    config: NodeConfig,
    sandbox: MacSandbox,
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn path(root: &Path, rest: &str) -> String {
    root.join(rest).display().to_string()
}

#[derive(Default)]
struct Options {
    /// The agent config lives in `~/.config/.pirc` and `~` is in
    /// `allowedPaths`.
    home_writable: bool,
    /// The workspace directory's name.
    workspace: Option<&'static str>,
    /// `sandbox.network` in the agent config, besides `defaultDomains:false`.
    network: Option<&'static str>,
    /// The node's `TMPDIR` instead of `<root>/tmp`.
    tmpdir: Option<&'static str>,
}

fn fixture(name: &str) -> Fixture {
    fixture_with(name, Options::default())
}

/// A node layout under the target directory (outside `/tmp`, a write root
/// of every session; short enough for Unix socket paths, which macOS caps
/// at 104 bytes).
fn fixture_with(name: &str, options: Options) -> Fixture {
    // CARGO_TARGET_DIR may itself be /tmp (a sandbox write root).
    // Keep Unix socket names short as well. /var/tmp is not a write root.
    let root = Path::new("/var/tmp").join(format!("pm-{}-{name}", std::process::id()));
    let _ = fs::remove_dir_all(&root);
    let config_rel = if options.home_writable {
        "home/.config/.pirc"
    } else {
        "config"
    };
    let workspace_name = options.workspace.unwrap_or("workspace");
    for dir in ["home/.ssh", "state", config_rel, "outside", "tmp"] {
        fs::create_dir_all(root.join(dir)).unwrap();
    }
    fs::create_dir_all(root.join(workspace_name).join(".git/hooks")).unwrap();
    let root = fs::canonicalize(&root).unwrap();
    let workspace = root.join(workspace_name);
    fs::write(root.join("home/.ssh/id_ed25519"), "secret").unwrap();
    fs::write(root.join("state/secret"), "node secret").unwrap();
    fs::write(workspace.join("README"), "hello").unwrap();
    fs::write(workspace.join(".git/config"), "[core]").unwrap();
    let allowed = if options.home_writable {
        r#""allowedPaths":["~"],"#
    } else {
        ""
    };
    let network = options
        .network
        .unwrap_or(r#""allowedDomains":["localhost"]"#);
    fs::write(
        root.join(config_rel).join("config.json"),
        format!(r#"{{{allowed}"sandbox":{{"network":{{"defaultDomains":false,{network}}}}}}}"#),
    )
    .unwrap();
    let (home, state, config_dir, tmp) = (
        path(&root, "home"),
        path(&root, "state"),
        path(&root, config_rel),
        options
            .tmpdir
            .map_or_else(|| path(&root, "tmp"), str::to_owned),
    );
    let path_var = std::env::var("PATH").unwrap_or_default();
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
    let sandbox = MacSandbox::new(config.clone(), env);
    Fixture {
        root,
        workspace,
        config,
        sandbox,
    }
}

impl Fixture {
    fn w(&self) -> String {
        self.workspace.display().to_string()
    }

    async fn prepare(&self, session: &str) -> Prepared {
        self.prepare_with(session, None, Vec::new()).await
    }

    async fn prepare_with(
        &self,
        session: &str,
        inference_socket: Option<PathBuf>,
        protected_paths: Vec<PathBuf>,
    ) -> Prepared {
        let session_dir = self.config.sessions_dir.join(session);
        fs::create_dir_all(&session_dir).unwrap();
        self.sandbox
            .prepare(PrepareInput {
                grants: Vec::new(),
                session_id: session.to_owned(),
                workspace_root: self.workspace.clone(),
                session_dir,
                inference_socket,
                protected_paths,
                workspace_memory_file: None,
                project_files_dir: None,
                recovery: None,
            })
            .await
            .unwrap()
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
            .env_clear()
            .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
            .envs(prepared.env.iter().map(|(k, v)| (k, v)))
            .current_dir(&self.workspace)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .kill_on_drop(true);
        let status = tokio::time::timeout(Duration::from_secs(30), command.status())
            .await
            .unwrap()
            .unwrap();
        prepared.cleanup();
        status.code().unwrap_or(-1)
    }

    /// Each `(name, script)` must fail; each of `allowed` must succeed.
    async fn expect(&self, refused: &[(&str, String)], allowed: &[(&str, String)]) -> Vec<String> {
        let mut failures = Vec::new();
        for (name, script) in refused {
            if self.sh(script).await == 0 {
                failures.push(format!("{name}: allowed"));
            }
        }
        for (name, script) in allowed {
            let code = self.sh(script).await;
            if code != 0 {
                failures.push(format!("{name}: exit {code}"));
            }
        }
        failures
    }
}

#[tokio::test]
async fn confines_the_agent_to_the_session_policy() {
    let f = fixture("files");
    assert!(matches!(
        f.sandbox.check().await,
        SandboxStatus::Active { .. }
    ));
    let (root, w) = (&f.root, f.w());
    let session = f.config.sessions_dir.join("pi_sh").display().to_string();
    let cases = [
        ("probe", "exit 0".to_owned(), true),
        ("read the workspace", format!("cat {w}/README"), true),
        ("write the workspace", format!("echo x > {w}/new.txt"), true),
        (
            "remove in the workspace",
            format!("echo x > {w}/gone && rm {w}/gone"),
            true,
        ),
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
            "list ~/.ssh",
            format!("ls {}/.ssh", path(root, "home")),
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
            "move the node's private state",
            format!("mv {}/secret {w}/stolen", path(root, "state")),
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
            "echo x > /tmp/pirc-macos-$$ && rm /tmp/pirc-macos-$$".to_owned(),
            true,
        ),
        ("write $TMPDIR", "echo x > \"$TMPDIR/x\"".to_owned(), true),
        (
            "TMPDIR is the session's",
            format!(
                "case \"$TMPDIR\" in {}/pirc-*) exit 0;; esac; exit 1",
                path(root, "tmp")
            ),
            true,
        ),
        (
            "signal a host process",
            format!("kill -0 {}", std::process::id()),
            false,
        ),
        (
            "a pseudo-terminal",
            "script -q /dev/null sh -c 'tty' | grep -q /dev/ttys".to_owned(),
            true,
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
    assert!(f.workspace.join("new.txt").exists());
    assert!(root.join("state/secret").exists());
    assert_eq!(
        fs::read_to_string(f.workspace.join(".git/config")).unwrap(),
        "[core]"
    );
}

/// A session reads, appends to and locks its own workspace-memory ledger
/// (the node makes it), and reaches no other file of the directory.
#[tokio::test]
async fn opens_only_its_own_workspace_memory_ledger() {
    let f = fixture("ledger");
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
            workspace_root: f.workspace.clone(),
            session_dir,
            inference_socket: None,
            protected_paths: Vec::new(),
            workspace_memory_file: Some(ledger.clone()),
            project_files_dir: None,
            recovery: None,
        })
        .await
        .unwrap();
    let (dir_text, ledger_text) = (dir.display().to_string(), ledger.display().to_string());
    // flock(2) through perl, which macOS ships (it has no flock(1)).
    let script = format!(
        r#"printf 'line\n' >> '{ledger_text}' || exit 1
        cat '{ledger_text}' >/dev/null || exit 2
        cat '{dir_text}/other.jsonl' 2>/dev/null && exit 3
        printf x 2>/dev/null >> '{dir_text}/other.jsonl' && exit 4
        touch '{dir_text}/0123456789abcdef.lock' 2>/dev/null && exit 5
        /usr/bin/perl -e 'use Fcntl ":flock"; open(F, ">>", $ARGV[0]) or exit 1; flock(F, LOCK_EX|LOCK_NB) or exit 1' '{ledger_text}' || exit 6
        exit 0"#
    );
    let mut command = prepared.command().unwrap();
    command
        .args(["-c", &script])
        .env_clear()
        .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
        .envs(prepared.env.iter().map(|(k, v)| (k, v)))
        .current_dir(&f.workspace)
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

/// A chat project's files: readable, never writable, a file the node adds
/// while the session runs is readable at once, and the rest of the
/// project's directory (its instructions) stays closed.
#[tokio::test]
async fn reads_project_files_but_never_writes_them() {
    let f = fixture("project-files");
    let project = f.config.state_dir.join("chat/workspace_p");
    let files = project.join("files");
    fs::create_dir_all(&files).unwrap();
    fs::write(files.join("a.txt"), "alpha").unwrap();
    fs::write(project.join("instructions.md"), "secret").unwrap();
    let session_dir = f.config.sessions_dir.join("pi_files");
    fs::create_dir_all(&session_dir).unwrap();
    let prepared = f
        .sandbox
        .prepare(PrepareInput {
            grants: Vec::new(),
            session_id: "pi_files".to_owned(),
            workspace_root: f.workspace.clone(),
            session_dir,
            inference_socket: None,
            protected_paths: Vec::new(),
            workspace_memory_file: None,
            project_files_dir: Some(files.clone()),
            recovery: None,
        })
        .await
        .unwrap();
    let (files_text, project_text) = (files.display().to_string(), project.display().to_string());
    let script = format!(
        r#"[ "$(cat '{files_text}/a.txt')" = alpha ] || exit 1
        ls '{files_text}' >/dev/null || exit 2
        printf x 2>/dev/null >> '{files_text}/a.txt' && exit 3
        touch '{files_text}/new.txt' 2>/dev/null && exit 4
        rm -f '{files_text}/a.txt' 2>/dev/null; [ -f '{files_text}/a.txt' ] || exit 5
        cat '{project_text}/instructions.md' 2>/dev/null && exit 6
        echo ready
        read line
        [ "$(cat '{files_text}/b.txt')" = beta ] || exit 7
        exit 0"#
    );
    let mut command = prepared.command().unwrap();
    command
        .args(["-c", &script])
        .env_clear()
        .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
        .envs(prepared.env.iter().map(|(k, v)| (k, v)))
        .current_dir(&f.workspace)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .kill_on_drop(true);
    let mut child = command.spawn().unwrap();
    let mut stdout = BufReader::new(child.stdout.take().unwrap());
    let mut line = String::new();
    tokio::time::timeout(Duration::from_secs(30), stdout.read_line(&mut line))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(line, "ready\n");
    fs::write(files.join("b.txt"), "beta").unwrap();
    let mut stdin = child.stdin.take().unwrap();
    stdin.write_all(b"go\n").await.unwrap();
    drop(stdin);
    let status = tokio::time::timeout(Duration::from_secs(30), child.wait())
        .await
        .unwrap()
        .unwrap();
    prepared.cleanup();
    assert_eq!(status.code(), Some(0));
    assert_eq!(fs::read_to_string(files.join("a.txt")).unwrap(), "alpha");
    assert!(!files.join("new.txt").exists());
}

#[tokio::test]
async fn passes_stdio_through_untouched() {
    let f = fixture("stdio");
    let prepared = f.prepare("pi_stdio").await;
    let mut command = prepared.command().unwrap();
    command
        .args([
            "-c",
            "while read line; do echo \"got $line\"; echo \"err $line\" >&2; done",
        ])
        .envs(prepared.env.iter().map(|(k, v)| (k, v)))
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
    client
        .args(&args)
        .args([
            "--exact",
            "sandbox_client",
            "--nocapture",
            "--test-threads=1",
        ])
        .env_clear()
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

/// The client on `targets`, each answer collected after a line on stdin.
async fn run_client(prepared: &Prepared, targets: &str) -> Vec<String> {
    let mut child = client(prepared, targets).spawn().unwrap();
    let mut stdin = child.stdin.take().unwrap();
    let mut lines = BufReader::new(child.stdout.take().unwrap()).lines();
    let mut results = Vec::new();
    for index in 0..targets.split(' ').count() {
        if index > 0 {
            stdin.write_all(b"\n").await.unwrap();
        }
        results.push(next_result(&mut lines).await);
    }
    assert!(child.wait().await.unwrap().success());
    results
}

#[tokio::test]
async fn reaches_the_network_only_through_the_proxy_and_approvals_widen_it_in_place() {
    let f = fixture_with(
        "network",
        Options {
            network: Some(r#""allowedDomains":["localhost"],"allowLocalBinding":false"#),
            ..Options::default()
        },
    );
    let port = upstream().await;
    let prepared = f.prepare("pi_net").await;
    assert!(prepared.has_control());
    let mut child = client(
        &prepared,
        &format!(
            "direct:{port} http://localhost:{port}/ http://127.0.0.1:{port}/ http://127.0.0.1:{port}/ bind"
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
    stdin.write_all(b"\n").await.unwrap();
    assert!(
        next().await.starts_with("no bind"),
        "no local binding without allowLocalBinding"
    );
    assert!(child.wait().await.unwrap().success());
    prepared.cleanup();
}

/// `allowLocalBinding` (pirc's default).
#[tokio::test]
async fn local_binding_opens_loopback_but_not_the_network() {
    let f = fixture("binding");
    let port = upstream().await;
    let prepared = f.prepare("pi_bind").await;
    let results = run_client(
        &prepared,
        &format!("bind direct:{port} http://127.0.0.1:{port}/"),
    )
    .await;
    assert_eq!(results[0], "bound");
    // srt's `(remote ip "localhost:*")`: every loopback port, the host's too.
    assert_eq!(results[1], "connected");
    assert_eq!(results[2], "HTTP/1.1 403 Forbidden", "the allowlist holds");
    prepared.cleanup();
}

#[tokio::test]
async fn cleanup_removes_the_session_temp_directory() {
    let f = fixture("cleanup");
    let prepared = f.prepare("pi_clean").await;
    let tmp = PathBuf::from(&prepared.env[0].1);
    assert!(tmp.exists());
    prepared.cleanup();
    assert!(!tmp.exists());
}

/// A Unix socket server answering `pong <line>`.
fn unix_server(socket: &Path) {
    let listener = std::os::unix::net::UnixListener::bind(socket).unwrap();
    std::thread::spawn(move || {
        for mut stream in listener.incoming().flatten() {
            let mut line = String::new();
            let _ = std::io::BufReader::new(&stream).read_line(&mut line);
            let _ = write!(stream, "pong {}", line.trim());
        }
    });
}

/// The node's inference socket lives in a private directory of its state,
/// which the profile denies: the policy gives that one directory back, and
/// `allowUnixSockets` that one socket. Other sockets stay unreachable.
#[tokio::test]
async fn reaches_the_inference_socket_and_no_other() {
    use std::os::unix::fs::DirBuilderExt;

    let f = fixture("inference");
    let dir = f.root.join("state/i-test");
    fs::DirBuilder::new().mode(0o700).create(&dir).unwrap();
    let socket = dir.join("socket");
    let other = f.root.join("outside/other.sock");
    let in_workspace = f.workspace.join("ws.sock");
    for path in [&socket, &other, &in_workspace] {
        assert!(path.as_os_str().len() < 104, "{}", path.display());
        unix_server(path);
    }
    // Another socket through a link in the workspace.
    let linked = f.workspace.join("l.sock");
    std::os::unix::fs::symlink(&other, &linked).unwrap();
    let prepared = f
        .prepare_with("pi_inference", Some(socket.clone()), Vec::new())
        .await;
    let results = run_client(
        &prepared,
        &format!(
            "unix:{} unix:{} unix:{} read:{} read:{} unix:{}",
            socket.display(),
            other.display(),
            in_workspace.display(),
            f.root.join("state/secret").display(),
            f.workspace.join("README").display(),
            linked.display(),
        ),
    )
    .await;
    assert_eq!(results[0], "pong ping");
    assert_eq!(
        results[1], "unreachable: PermissionDenied",
        "another socket"
    );
    assert_eq!(
        results[2], "unreachable: PermissionDenied",
        "even a readable one"
    );
    assert_eq!(
        results[3], "unreadable: PermissionDenied",
        "the rest of the state stays denied"
    );
    assert_eq!(results[4], "read");
    assert_eq!(
        results[5], "unreachable: PermissionDenied",
        "another socket through a link"
    );
    prepared.cleanup();
}

/// srt's move-blocking rules deny unlinking and creating each protected
/// path and every ancestor directory, so (unlike bind mounts on Linux,
/// security audit S7) renaming a directory above a protected path is
/// refused too. Checked here for existing and missing paths, srt's
/// protected names anywhere in the workspace, and the agent config.
#[tokio::test]
async fn protected_paths_cannot_be_renamed_or_created() {
    let f = fixture_with(
        "rename",
        Options {
            home_writable: true,
            ..Options::default()
        },
    );
    let (root, w) = (&f.root, f.w());
    let home = path(root, "home");
    fs::create_dir_all(f.workspace.join("project/docs")).unwrap();
    fs::create_dir_all(f.workspace.join("sub")).unwrap();
    let instructions = f.workspace.join("project/docs/AGENTS.md");
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
        ("remove .git", format!("rm -rf {w}/.git")),
        ("rename .git/hooks", format!("mv {w}/.git/hooks {w}/.git/h")),
        (
            "rename .git/config",
            format!("mv {w}/.git/config {w}/.git/c"),
        ),
        ("remove .git/config", format!("rm -f {w}/.git/config")),
        (
            "replace .git/config",
            format!("echo x > {w}/c && mv {w}/c {w}/.git/config"),
        ),
        ("create .pirc", format!("mkdir {w}/.pirc")),
        (
            "create .pirc by renaming",
            format!("mkdir {w}/p && mv {w}/p {w}/.pirc"),
        ),
        ("link .pirc", format!("ln -s {w}/outside {w}/.pirc")),
        ("write .bashrc", format!("echo x > {w}/.bashrc")),
        ("write a nested .zshrc", format!("echo x > {w}/sub/.zshrc")),
        (
            "write .vscode",
            format!("mkdir -p {w}/.vscode && echo x > {w}/.vscode/settings.json"),
        ),
        (
            "write a nested repository's hooks",
            format!("mkdir -p {w}/sub/.git/hooks && echo x > {w}/sub/.git/hooks/pre-commit"),
        ),
        (
            "write a nested repository's config",
            format!("mkdir -p {w}/sub/.git && echo x > {w}/sub/.git/config"),
        ),
        (
            "rename an ancestor of the project's instructions",
            format!(
                "mv {w}/project {w}/p2 && mkdir -p {w}/project/docs && echo x > {w}/project/docs/AGENTS.md"
            ),
        ),
        (
            "rename the instructions' parent",
            format!("mv {w}/project/docs {w}/project/d"),
        ),
        ("rename the workspace", format!("mv {w} {w}.moved")),
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
        (
            "rename an unprotected directory",
            format!("mkdir -p {w}/a/b && mv {w}/a {w}/a2 && rm -r {w}/a2"),
        ),
    ];
    let mut failures = Vec::new();
    for (name, script) in &refused {
        if f.sh_protecting(script, protected.clone()).await == 0 {
            failures.push(format!("{name}: allowed"));
        }
    }
    for (name, script) in &allowed {
        let code = f.sh_protecting(script, protected.clone()).await;
        if code != 0 {
            failures.push(format!("{name}: exit {code}"));
        }
    }
    assert!(failures.is_empty(), "{failures:#?}");
    assert_eq!(
        fs::read_to_string(f.workspace.join(".git/config")).unwrap(),
        "[core]"
    );
    assert_eq!(fs::read_to_string(&instructions).unwrap(), "be nice");
    for gone in [
        ".git.bak",
        "p2",
        "project/d",
        ".pirc",
        ".bashrc",
        "sub/.zshrc",
    ] {
        assert!(!f.workspace.join(gone).exists(), "{gone}");
    }
    for gone in ["home/c", "home/.config/p"] {
        assert!(!root.join(gone).exists(), "{gone}");
    }
    assert!(root.join("home/.config/.pirc/config.json").exists());
    assert!(root.join("home/new").exists());
}

/// srt keeps a symlinked spelling that leads out of its tree, but Seatbelt
/// matches the path the kernel resolved: without pirc's resolved denies,
/// `.git/config` behind a `.git` link and an rc file behind a link stayed
/// writable.
#[tokio::test]
async fn symlinked_spellings_stay_protected() {
    let f = fixture_with(
        "links",
        Options {
            home_writable: true,
            ..Options::default()
        },
    );
    let (root, w) = (&f.root, f.w());
    let repo = root.join("home/repo");
    fs::rename(f.workspace.join(".git"), &repo).unwrap();
    std::os::unix::fs::symlink(&repo, f.workspace.join(".git")).unwrap();
    // A dotfile manager's link to a file that does not exist yet.
    std::os::unix::fs::symlink(root.join("home/dotfiles/zshrc"), f.workspace.join(".zshrc"))
        .unwrap();
    fs::create_dir_all(root.join("home/dotfiles")).unwrap();
    let repo = repo.display().to_string();
    let failures = f
        .expect(
            &[
                (
                    "write .git/config through the link",
                    format!("echo x >> {w}/.git/config"),
                ),
                ("write the real config", format!("echo x >> {repo}/config")),
                (
                    "write .git/hooks through the link",
                    format!("echo x > {w}/.git/hooks/pre-commit"),
                ),
                ("rename the repository", format!("mv {repo} {repo}2")),
                ("remove the .git link", format!("rm {w}/.git")),
                ("repoint the .git link", format!("ln -sfn {w}/sub {w}/.git")),
                (
                    "create the rc file through its link",
                    format!("echo x > {w}/.zshrc"),
                ),
            ],
            &[("start", "exit 0".to_owned())],
        )
        .await;
    assert!(failures.is_empty(), "{failures:#?}");
    assert_eq!(
        fs::read_to_string(format!("{repo}/config")).unwrap(),
        "[core]"
    );
    assert!(!root.join("home/dotfiles/zshrc").exists());
}

/// The policy denies a sensitive home path by its target: with `~/.ssh`
/// linking elsewhere and `~` writable, the link itself must stay in place
/// (`SessionPolicy::linked_denies`), or the agent replaces it with a
/// directory of its own (review finding 1).
#[tokio::test]
async fn a_linked_credential_store_cannot_be_replaced() {
    let f = fixture_with(
        "sshlink",
        Options {
            home_writable: true,
            ..Options::default()
        },
    );
    let root = &f.root;
    let home = path(root, "home");
    fs::rename(root.join("home/.ssh"), root.join("outside/ssh")).unwrap();
    std::os::unix::fs::symlink(root.join("outside/ssh"), root.join("home/.ssh")).unwrap();
    // A chain: ~/.aws -> ~/hop -> outside/aws.
    fs::create_dir_all(root.join("outside/aws")).unwrap();
    std::os::unix::fs::symlink(root.join("outside/aws"), root.join("home/hop")).unwrap();
    std::os::unix::fs::symlink("hop", root.join("home/.aws")).unwrap();
    let failures = f
        .expect(
            &[
                ("read through the link", format!("cat {home}/.ssh/id_ed25519")),
                (
                    "write through the link",
                    format!("echo k > {home}/.ssh/authorized_keys"),
                ),
                (
                    "replace the link",
                    format!("rm {home}/.ssh && mkdir {home}/.ssh && echo k > {home}/.ssh/authorized_keys"),
                ),
                ("rename the link", format!("mv {home}/.ssh {home}/ssh2")),
                ("repoint the link", format!("ln -sfn {home}/x {home}/.ssh")),
                ("replace the chain's hop", format!("rm {home}/hop && mkdir {home}/hop")),
                ("rename home", format!("mv {home} {home}2")),
            ],
            &[("write home", format!("echo x > {home}/notes"))],
        )
        .await;
    assert!(failures.is_empty(), "{failures:#?}");
    assert!(
        fs::symlink_metadata(root.join("home/.ssh"))
            .unwrap()
            .is_symlink()
    );
    assert!(
        fs::symlink_metadata(root.join("home/hop"))
            .unwrap()
            .is_symlink()
    );
}

/// pirc's resolved denies name where a chain of links leads now: every
/// link in the chain stays in place, or repointing one in a writable
/// directory redirects the protected path (review finding 2).
#[tokio::test]
async fn links_in_the_middle_of_a_chain_cannot_be_repointed() {
    let f = fixture_with(
        "chain",
        Options {
            home_writable: true,
            ..Options::default()
        },
    );
    let (root, w) = (&f.root, f.w());
    let home = path(root, "home");
    // ws/.git -> ~/hop -> ~/repo (a relative hop, as a dotfile manager makes).
    fs::rename(f.workspace.join(".git"), root.join("home/repo")).unwrap();
    std::os::unix::fs::symlink("repo", root.join("home/hop")).unwrap();
    std::os::unix::fs::symlink(root.join("home/hop"), f.workspace.join(".git")).unwrap();
    // ~/.zshrc-style: ws/.bashrc -> ~/code/bashrc, ~/code -> outside/code.
    fs::create_dir_all(root.join("outside/code")).unwrap();
    fs::write(root.join("outside/code/bashrc"), "rc").unwrap();
    std::os::unix::fs::symlink(root.join("outside/code"), root.join("home/code")).unwrap();
    std::os::unix::fs::symlink(root.join("home/code/bashrc"), f.workspace.join(".bashrc")).unwrap();
    let failures = f
        .expect(
            &[
                (
                    "repoint the hop",
                    format!(
                        "mkdir -p {home}/evil && printf '[core]\\n\\thooksPath=/x\\n' > {home}/evil/config && ln -sfn evil {home}/hop"
                    ),
                ),
                ("remove the hop", format!("rm {home}/hop")),
                ("rename the hop", format!("mv {home}/hop {home}/hop2")),
                (
                    "replace the linked directory",
                    format!("rm {home}/code && mkdir -p {home}/code"),
                ),
                ("write the rc file", format!("echo x >> {w}/.bashrc")),
                ("write .git/config", format!("echo x >> {w}/.git/config")),
            ],
            &[("write home", format!("echo x > {home}/notes"))],
        )
        .await;
    assert!(failures.is_empty(), "{failures:#?}");
    assert_eq!(
        fs::read_to_string(f.workspace.join(".git/config")).unwrap(),
        "[core]"
    );
    assert_eq!(
        fs::read_to_string(root.join("outside/code/bashrc")).unwrap(),
        "rc"
    );
}

/// srt reads `[`, `*` and `?` in a rule as glob syntax, so a workspace named
/// like `notes [draft]` lost its `.pirc` deny; pirc adds the literal path.
#[tokio::test]
async fn a_workspace_with_glob_characters_keeps_its_denies() {
    let f = fixture_with(
        "glob",
        Options {
            workspace: Some("ws [d]*"),
            ..Options::default()
        },
    );
    let w = f.w();
    let failures = f
        .expect(
            &[
                ("create .pirc", format!("mkdir '{w}/.pirc'")),
                ("write .git/config", format!("echo x >> '{w}/.git/config'")),
                ("rename .git", format!("mv '{w}/.git' '{w}/g'")),
            ],
            &[
                ("write the workspace", format!("echo x > '{w}/x'")),
                ("read the workspace", format!("cat '{w}/README'")),
            ],
        )
        .await;
    assert!(failures.is_empty(), "{failures:#?}");
}

/// srt wrote rule strings as JSON, whose `\u0001`-style escapes Seatbelt
/// does not read: every deny naming a path with a control character named
/// another path (review finding 3). Also regex metacharacters, quotes, a
/// backslash and non-ASCII: srt's anchored `**/` denies still match.
#[tokio::test]
async fn a_workspace_with_control_characters_keeps_its_denies() {
    for (name, workspace) in [
        ("ctl", "home/ws\u{1}\u{1b}\t\u{7f}x"),
        ("meta", "w[s] \"q\" \\ ü*?(x)|{1}+$^."),
    ] {
        let f = fixture_with(
            name,
            Options {
                home_writable: true,
                workspace: Some(workspace),
                ..Options::default()
            },
        );
        let w = f.w();
        // The workspace as the script's `$1`: no quoting of its name.
        let sh = |script: &str| format!("set -- \"$PWD\"; {script}");
        let failures = f
            .expect(
                &[
                    ("write .git/hooks", sh("echo x > \"$1/.git/hooks/pre-commit\"")),
                    ("append .git/config", sh("echo x >> \"$1/.git/config\"")),
                    ("create .pirc", sh("mkdir \"$1/.pirc\"")),
                    ("rename .git", sh("mv \"$1/.git\" \"$1/.git2\"")),
                    ("nested .zshrc", sh("mkdir -p \"$1/sub\" && echo x > \"$1/sub/.zshrc\"")),
                    (
                        "nested hooks",
                        sh("mkdir -p \"$1/s/.git/hooks\" && echo x > \"$1/s/.git/hooks/pre-commit\""),
                    ),
                    (
                        "write .vscode",
                        sh("mkdir -p \"$1/.vscode\" && echo x > \"$1/.vscode/settings.json\""),
                    ),
                ],
                &[
                    ("write the workspace", sh("echo x > \"$1/x\"")),
                    ("read the workspace", sh("cat \"$1/README\"")),
                ],
            )
            .await;
        assert!(failures.is_empty(), "{w:?}: {failures:#?}");
        assert_eq!(
            fs::read_to_string(f.workspace.join(".git/config")).unwrap(),
            "[core]"
        );
    }
}

/// The Git panel's sandbox (security audit S8): the workspace readable,
/// nothing writable but its temp directory, no network. Not even srt's
/// default write paths (review finding 4): its home convenience
/// directories, `/tmp/claude` (shared with every session) or `/dev/tty`.
#[tokio::test]
async fn the_readonly_sandbox_reads_but_never_writes() {
    let f = fixture("readonly");
    let home = path(&f.root, "home");
    fs::create_dir_all(f.root.join("home/.claude/debug")).unwrap();
    fs::create_dir_all(f.root.join("home/.npm/_logs")).unwrap();
    let _ = fs::create_dir_all("/tmp/claude");
    // A real repository for `git status` (the fixture's `.git` is a stub).
    let init = std::process::Command::new("git")
        .args(["init", "-q"])
        .current_dir(&f.workspace)
        .status()
        .unwrap();
    assert!(init.success());
    let port = upstream().await;
    let run = async |script: String| {
        let prepared = f
            .sandbox
            .prepare_readonly(ReadonlyInput {
                workspace_root: f.workspace.clone(),
                command: vec!["/bin/sh".into(), "-c".into(), script.clone().into()],
            })
            .await
            .unwrap();
        assert!(!prepared.has_control());
        let mut command = prepared.command().unwrap();
        command
            .env_clear()
            .env("PATH", "/usr/bin:/bin")
            .envs(prepared.env.iter().map(|(k, v)| (k, v)))
            .current_dir(&f.workspace)
            .stdout(Stdio::null())
            .stderr(Stdio::piped());
        let output = command.output().await.unwrap();
        prepared.cleanup();
        let code = output.status.code().unwrap_or(-1);
        if code != 0 {
            eprintln!("{script}: {}", String::from_utf8_lossy(&output.stderr));
        }
        code
    };
    let w = f.w();
    assert_eq!(run(format!("cat {w}/README && git -C {w} status")).await, 0);
    // The narrower base (no shared memory, notifications or security
    // daemons) still runs git's reading commands.
    let commit = std::process::Command::new("git")
        .args(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q"])
        .args(["--allow-empty", "-m", "first"])
        .current_dir(&f.workspace)
        .status()
        .unwrap();
    assert!(commit.success());
    assert_eq!(
        run(format!(
            "git -C {w} log --oneline -1 && git -C {w} diff HEAD && git -C {w} show --stat HEAD"
        ))
        .await,
        0
    );
    assert_ne!(run(format!("echo x > {w}/x")).await, 0);
    assert_ne!(run(format!("echo x >> {w}/.git/config")).await, 0);
    assert_ne!(run("echo x > /tmp/pirc-ro-$$".to_owned()).await, 0);
    assert_eq!(run("echo x > \"$TMPDIR/x\"".to_owned()).await, 0);
    assert_eq!(run("echo x > /dev/null".to_owned()).await, 0);
    for script in [
        format!("echo x > {home}/.claude/debug/planted"),
        format!("mkdir {home}/.claude/debug/d"),
        format!("echo x > {home}/.npm/_logs/planted"),
        "echo x > /tmp/claude/pirc-ro-$$".to_owned(),
        "echo x > /private/tmp/claude/pirc-ro-$$".to_owned(),
        "echo x > /dev/tty".to_owned(),
    ] {
        assert_ne!(run(script.clone()).await, 0, "{script}");
    }
    assert!(!f.root.join("home/.claude/debug/planted").exists());
    // No Unix socket at all.
    let socket = f.root.join("outside/ro.sock");
    unix_server(&socket);
    assert_ne!(
        run(format!("/usr/bin/nc -U {} </dev/null", socket.display())).await,
        0,
        "no Unix socket"
    );
    assert_ne!(
        run(format!("curl -s -m 5 http://127.0.0.1:{port}/")).await,
        0,
        "no network"
    );
    assert_ne!(
        run(format!("cat {}", path(&f.root, "state/secret"))).await,
        0
    );
}

/// Two sessions of one node whose `TMPDIR` is `/tmp` (the default when it
/// is unset), a write root of every session: neither reaches the other's
/// temporary directory, whichever started first. The policy only denies
/// the node's temp parent to reads, and its write denies around it list
/// the directories that exist when it is built, so without the profile's
/// own write deny on the parent the first session could write into the
/// second's (second review, issue 2).
#[tokio::test]
async fn sessions_cannot_reach_each_others_temp_dir() {
    let f = fixture_with(
        "tmps",
        Options {
            tmpdir: Some("/tmp"),
            ..Options::default()
        },
    );
    let a = f.prepare("pi_a").await;
    let b = f.prepare("pi_b").await;
    let tmp_of = |prepared: &Prepared| {
        prepared
            .env
            .iter()
            .find(|(name, _)| name == "TMPDIR")
            .map(|(_, value)| value.clone())
            .unwrap()
    };
    let (a_tmp, b_tmp) = (tmp_of(&a), tmp_of(&b));
    let parent = Path::new(&a_tmp).parent().unwrap().display().to_string();
    assert_eq!(Path::new(&b_tmp).parent(), Some(Path::new(&parent)));
    assert!(parent.starts_with("/tmp/pirc-n-"), "{parent}");
    let run = async |prepared: &Prepared, script: &str| {
        let mut command = prepared.command().unwrap();
        command
            .args(["-c", script])
            .env_clear()
            .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
            .envs(prepared.env.iter().map(|(k, v)| (k, v)))
            .current_dir(&f.workspace)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .kill_on_drop(true);
        tokio::time::timeout(Duration::from_secs(30), command.status())
            .await
            .unwrap()
            .unwrap()
            .code()
            .unwrap_or(-1)
    };
    let mut failures = Vec::new();
    for (name, own, other) in [("a", &a, &b_tmp), ("b", &b, &a_tmp)] {
        let refused = [
            format!("echo x > {other}/planted"),
            format!("mkdir {other}/d"),
            format!("ls {other}"),
            format!("ls {parent}"),
            format!("echo x > {parent}/planted"),
            format!("mkdir {parent}/pirc-squat"),
            format!("mv {other} {parent}/moved"),
            format!("mv {parent} /tmp/pirc-moved-$$"),
            format!("rm -r {other}"),
        ];
        for script in &refused {
            if run(own, script).await == 0 {
                failures.push(format!("{name}: {script}: allowed"));
            }
        }
        let allowed = [
            "echo x > \"$TMPDIR/x\" && cat \"$TMPDIR/x\"",
            "mkdir \"$TMPDIR/d\" && mv \"$TMPDIR/d\" \"$TMPDIR/e\" && rm -r \"$TMPDIR/e\"",
            "cd \"$TMPDIR\" && rm x",
            "echo x > /tmp/pirc-macos-$$ && rm /tmp/pirc-macos-$$",
        ];
        for script in allowed {
            let code = run(own, script).await;
            if code != 0 {
                failures.push(format!("{name}: {script}: exit {code}"));
            }
        }
    }
    assert!(failures.is_empty(), "{failures:#?}");
    for tmp in [&a_tmp, &b_tmp] {
        let entries: Vec<_> = fs::read_dir(tmp).unwrap().collect();
        assert!(entries.is_empty(), "{tmp}: {entries:?}");
    }
    assert!(!Path::new(&parent).join("planted").exists());
    a.cleanup();
    b.cleanup();
}

/// A user's glob deny whose static directory is a link out of its tree:
/// the policy resolves the glob's directory (`real_resolve`), so both
/// spellings stay denied.
#[tokio::test]
async fn a_glob_deny_through_a_link_holds() {
    let f = fixture("globlink");
    let root = &f.root;
    fs::create_dir_all(root.join("outside/keys")).unwrap();
    fs::write(root.join("outside/keys/a.key"), "k").unwrap();
    std::os::unix::fs::symlink(root.join("outside"), root.join("link")).unwrap();
    fs::write(
        root.join("config/config.json"),
        format!(
            r#"{{"sandbox":{{"network":{{"defaultDomains":false,"allowedDomains":["localhost"]}},"filesystem":{{"denyRead":["{}/link/**/*.key"]}}}}}}"#,
            root.display()
        ),
    )
    .unwrap();
    let failures = f
        .expect(
            &[
                (
                    "through the link",
                    format!("cat {}", path(root, "link/keys/a.key")),
                ),
                (
                    "resolved",
                    format!("cat {}", path(root, "outside/keys/a.key")),
                ),
            ],
            &[],
        )
        .await;
    assert!(failures.is_empty(), "{failures:#?}");
}

/// `/dev/tty` stays ioctl-able in srt's base profile: pushing input into
/// the node's terminal (TIOCSTI) must still be refused, from a session and
/// from the read-only sandbox. Needs a controlling terminal (skipped
/// otherwise, as under CI).
#[tokio::test]
async fn tiocsti_into_the_nodes_terminal_is_refused() {
    if std::fs::File::open("/dev/tty").is_err() {
        eprintln!("no controlling terminal: skipped");
        return;
    }
    let f = fixture("tty");
    // TIOCSTI through perl (shipped with macOS): 3 no tty, 4 refused.
    let inject = r##"/usr/bin/perl -e 'open(my $t, "+<", "/dev/tty") or exit 3; my $c = "#"; ioctl($t, 0x80017472, $c) or exit 4; exit 0'"##;
    assert_ne!(f.sh(inject).await, 0, "from a session");
    let prepared = f
        .sandbox
        .prepare_readonly(ReadonlyInput {
            workspace_root: f.workspace.clone(),
            command: vec!["/bin/sh".into(), "-c".into(), inject.into()],
        })
        .await
        .unwrap();
    let status = prepared
        .command()
        .unwrap()
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .envs(prepared.env.iter().map(|(k, v)| (k, v)))
        .current_dir(&f.workspace)
        .status()
        .await
        .unwrap();
    prepared.cleanup();
    assert!(!status.success(), "from the read-only sandbox");
}

/// Panel git through the read-only sandbox: git's reading commands work,
/// and the sandbox's own failure is 503, never git's "no". `sandbox-exec`
/// reports its failures (a profile it refuses, `execvp` failing) on
/// stderr as `sandbox-exec: …`, which `StderrPrefixes` relies on.
#[tokio::test]
async fn panel_git_answers_503_when_the_sandbox_fails() {
    use pirc_node::panels::inspect::{ChildEnv, git_log, git_status};

    let f = fixture("panelgit");
    let w = &f.workspace;
    fs::remove_dir_all(w.join(".git")).unwrap();
    // A commit that touches a file: the panel's log is `-- .`.
    for args in [
        &["init", "-q"][..],
        &["add", "README"],
        &[
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@t",
            "commit",
            "-qm",
            "first",
        ],
    ] {
        let status = std::process::Command::new("git")
            .args(args)
            .current_dir(w)
            .status()
            .unwrap();
        assert!(status.success(), "git {args:?}");
    }
    let env = |path: &str| -> ChildEnv {
        [("PATH", path.to_owned()), ("HOME", path_of(&f, "home"))]
            .into_iter()
            .map(|(k, v)| (k.to_owned(), v))
            .collect()
    };
    let status = git_status(&f.sandbox, w, &env("/usr/bin:/bin"))
        .await
        .unwrap();
    assert_eq!(status["repo"], true, "{status}");
    let log = git_log(&f.sandbox, w, &env("/usr/bin:/bin"), 0, 10)
        .await
        .unwrap();
    assert_eq!(log["commits"][0]["subject"], "first", "{log}");

    // git off PATH: `execvp` fails inside sandbox-exec.
    let error = git_status(&f.sandbox, w, &env("/nonexistent-pirc"))
        .await
        .unwrap_err();
    assert_eq!(error.status, 503, "{error:?}");
    assert!(error.message.contains("sandbox-exec: "), "{error:?}");

    // A profile sandbox-exec refuses says so on stderr, the same way.
    let refused = std::process::Command::new(pirc_node::sandbox::macos::SANDBOX_EXEC)
        .args(["-p", "(version 1)(not-a-rule", "/usr/bin/true"])
        .output()
        .unwrap();
    assert!(!refused.status.success());
    let stderr = String::from_utf8_lossy(&refused.stderr);
    assert!(stderr.starts_with("sandbox-exec: "), "{stderr}");
}

fn path_of(f: &Fixture, rest: &str) -> String {
    path(&f.root, rest)
}

/// srt's hole that remains (as on Linux under srt): its mandatory denies
/// match `**/.git/config` and `**/.git/hooks/**` by name below the
/// workspace, but a nested repository's `.git` is not move-blocked, so the
/// agent can write a config elsewhere and rename it into place; a
/// submodule's `.git/modules/<name>/config` is not matched at all. Only the
/// workspace's own `.git/config` and `.git/hooks` are protected against
/// renames; panel git therefore runs sandboxed (security audit S8).
#[tokio::test]
async fn nested_repository_configs_are_not_protected_against_renames() {
    let f = fixture("nested");
    let w = f.w();
    let failures = f
        .expect(
            &[(
                "write a nested config directly",
                format!("mkdir -p {w}/sub/.git && echo x > {w}/sub/.git/config"),
            )],
            &[
                (
                    "swap a nested .git with a config",
                    format!(
                        "mkdir -p {w}/sub/.git && mv {w}/sub/.git {w}/sub/g && echo x > {w}/sub/g/config && mv {w}/sub/g {w}/sub/.git"
                    ),
                ),
                (
                    "write a submodule's config",
                    format!("mkdir -p {w}/.git/modules/m && echo x > {w}/.git/modules/m/config"),
                ),
            ],
        )
        .await;
    assert!(failures.is_empty(), "{failures:#?}");
    assert_eq!(
        fs::read_to_string(f.workspace.join("sub/.git/config")).unwrap(),
        "x\n"
    );
}

/// A real `pirc-node agent` starts under the profile (dyld, the runtime,
/// its config reads and session writes) and answers on its stdio.
#[tokio::test]
async fn a_real_agent_starts_and_answers() {
    let mut f = fixture("agent");
    f.config.agent_command = env!("CARGO_BIN_EXE_pirc-node").to_owned();
    f.config.agent_args = vec!["agent".to_owned()];
    let env = Env::new(
        [
            ("HOME", path(&f.root, "home").as_str()),
            ("TMPDIR", path(&f.root, "tmp").as_str()),
            ("PIRC_CONFIG_DIR", path(&f.root, "config").as_str()),
        ],
        &f.root,
    );
    f.sandbox = MacSandbox::new(f.config.clone(), env);
    let session_dir = f.config.sessions_dir.join("pi_agent");
    fs::create_dir_all(&session_dir).unwrap();
    let socket = f.root.join("state/persistence/socket");
    fs::create_dir_all(socket.parent().unwrap()).unwrap();
    let address = pirc_protocol::SocketPath::new(&socket).unwrap();
    let listener = tokio::net::UnixListener::bind(&address.path).unwrap();
    let writes = std::sync::Arc::new(pirc_node::persistence::Writes::default());
    let persistence = writes
        .register(socket.to_str().unwrap(), &session_dir, None)
        .unwrap();
    let serving = persistence_support::serve(listener, writes);
    let prepared = f.prepare_with("pi_agent", Some(socket), Vec::new()).await;
    let mut command = prepared.command().unwrap();
    command
        .args(["--mode", "rpc", "--session-dir"])
        .arg(&session_dir)
        .env_clear()
        .env("HOME", path(&f.root, "home"))
        .env("PATH", "/usr/bin:/bin")
        .env("PIRC_CONFIG_DIR", path(&f.root, "config"))
        .env("PIRC_AGENT_FEATURES", "none")
        .env(
            "PIRC_MODE",
            serde_json::to_string(&pirc_protocol::mode::default_work()).unwrap(),
        )
        .envs(prepared.env.iter().map(|(k, v)| (k, v)))
        .current_dir(&f.workspace)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    let mut child = command.spawn().unwrap();
    let mut stdin = child.stdin.take().unwrap();
    // `pirc-conformance`'s `fake_models`, without an inference socket.
    let configure = serde_json::json!({ "type": "configure", "capabilities": { "version": 1 }, "persistence": persistence.config,
        "models": {
            "providers": { "fake": { "api": "openai-completions", "baseUrl": "https://gateway.invalid",
                "headers": {}, "compat": {},
                "models": [{ "id": "fake-model", "name": "Fake model", "contextWindow": 100000,
                    "maxTokens": 1000, "reasoning": true, "input": ["text"], "compat": {} }] } },
            "defaultModel": { "provider": "fake", "id": "fake-model", "thinking": "low" } } });
    stdin
        .write_all(format!("{configure}\n{{\"type\":\"get_state\",\"id\":\"1\"}}\n").as_bytes())
        .await
        .unwrap();
    let mut lines = BufReader::new(child.stdout.take().unwrap()).lines();
    let answer = tokio::time::timeout(Duration::from_secs(30), async {
        while let Some(line) = lines.next_line().await.unwrap() {
            if line.contains("\"response\"") {
                return line;
            }
        }
        String::new()
    })
    .await
    .unwrap();
    drop(stdin);
    let mut err = String::new();
    let _ = child.kill().await;
    let _ = child.stderr.take().unwrap().read_to_string(&mut err).await;
    assert!(
        answer.contains("\"success\":true"),
        "answer: {answer:?}\nstderr: {err}"
    );
    serving.abort();
    prepared.cleanup();
}
