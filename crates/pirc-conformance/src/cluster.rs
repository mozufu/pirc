//! Starting the executables under test: a gateway and, optionally, one node
//! connected to it, each in an isolated temporary directory with its own
//! `HOME`, configuration and state.

use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom, Write as _};
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use nix::sys::signal::{Signal, kill};
use nix::unistd::Pid;
use serde_json::json;
use tempfile::TempDir;

use crate::client::{Api, Response};
use crate::fake_llm::FakeLlm;

/// The one allowed user.
pub const USER: &str = "test@example.com";
/// The allowed `Host`.
pub const HOST: &str = "test.example";
/// The allowed `Origin`.
pub const ORIGIN: &str = "https://test.example";
/// The node's id and per-node secret.
pub const NODE_ID: &str = "test";
pub const NODE_TOKEN: &str = "conformance-node-token-0123456789abcdef";
/// The node's only workspace, as the gateway names it.
pub const WORKSPACE_ID: &str = "test:test";

/// Directory of the executables under test. Without it the tests that need them
/// are ignored (`build.rs`), not passed.
const BIN_DIR_VARIABLE: &str = "PIRC_CONFORMANCE_BIN_DIR";
/// Set by `bun run test:conformance` (and so CI): a missing directory is then a
/// failure, not a skip.
const REQUIRED_VARIABLE: &str = "PIRC_CONFORMANCE_REQUIRED";
/// The top-level chats workspace of a chat node, as the gateway names it.
pub const CHATS_WORKSPACE_ID: &str = "test:chats";
/// A second workspace on the same node ([`GatewayOptions::second_workspace`]).
pub const TARGET_WORKSPACE_ID: &str = "test:target";

/// Creates the executable `path` (which must not exist yet) holding
/// `contents`.
///
/// The file is written and made executable by a short-lived `sh`, never by
/// the test process: a write fd open there would be inherited by a child
/// that another test thread forks meanwhile, and exec'ing the script while
/// that child still holds it fails with ETXTBSY, "Text file busy"
/// (rust-lang/rust#114554).
pub fn write_executable(path: &Path, contents: &str) {
    assert!(!path.exists(), "{} already exists", path.display());
    let mut child = Command::new("/bin/sh")
        .args(["-c", r#"cat > "$1" && chmod 755 "$1""#, "sh"])
        .arg(path)
        .stdin(Stdio::piped())
        .spawn()
        .unwrap();
    let mut stdin = child.stdin.take().unwrap();
    stdin.write_all(contents.as_bytes()).unwrap();
    drop(stdin);
    let status = child.wait().unwrap();
    assert!(status.success(), "writing {}: {status}", path.display());
}

/// Replaces the sandbox runtime: answers the node's probe and runs the agent
/// unconfined. What the node writes to the control fd (3, runtime network
/// approvals) is appended to [`FAKE_SRT_CONTROL_LOG`] next to the script.
const FAKE_SRT: &str = r#"#!/bin/sh
while [ $# -gt 0 ]; do
  case "$1" in
    --) shift; break ;;
    --settings|--control-fd) shift 2 ;;
    *) shift ;;
  esac
done
if [ -e /dev/fd/3 ]; then
  cat <&3 >> "$(dirname "$0")/fake-srt-control.log" &
fi
exec "$@"
"#;

/// The file in a node's run directory ([`LoneNode::dir`], [`Cluster::dir`])
/// where the fake srt keeps the node's control-fd lines.
pub const FAKE_SRT_CONTROL_LOG: &str = "fake-srt-control.log";

/// Starting again with another port when the gateway exits before it
/// answers (the free port was taken in between).
const START_ATTEMPTS: usize = 3;

/// Gateway variations for tests that need a different trust configuration.
#[derive(Clone, Debug, Default)]
pub struct GatewayOptions {
    /// Extra or overriding gateway environment variables.
    pub env: Vec<(&'static str, String)>,
    /// Start no node.
    pub without_node: bool,
    /// The node's agents run without their built-in features
    /// (`PIRC_AGENT_FEATURES=none`; docs/development/historical-records.md).
    pub agent_core_only: bool,
    /// The node runs the chat role (`pirc-chat`, or `pirc-node chat`): no
    /// configured workspaces, the top-level chats workspace
    /// [`CHATS_WORKSPACE_ID`] instead of [`WORKSPACE_ID`].
    pub chat_node: bool,
    /// Extra or overriding node environment variables. `{run_dir}` in a
    /// value stands for the run directory ([`Cluster::dir`], [`LoneNode::dir`]).
    pub node_env: Vec<(&'static str, String)>,
    /// Also configure [`TARGET_WORKSPACE_ID`], a separate directory.
    pub second_workspace: bool,
}

/// How a node is started: see the fields of [`GatewayOptions`] with the same names.
#[derive(Clone, Debug, Default)]
pub struct NodeOptions {
    pub agent_core_only: bool,
    pub chat_node: bool,
    pub env: Vec<(&'static str, String)>,
    pub second_workspace: bool,
}

impl GatewayOptions {
    fn node(&self) -> NodeOptions {
        NodeOptions {
            agent_core_only: self.agent_core_only,
            chat_node: self.chat_node,
            env: self.node_env.clone(),
            second_workspace: self.second_workspace,
        }
    }
}

/// A running gateway (and node) with a fake model provider.
pub struct Cluster {
    // Field order is drop order: the node stops before the gateway, and the
    // processes before their directory is removed.
    node: Option<Process>,
    gateway: Process,
    pub llm: FakeLlm,
    pub port: u16,
    /// The gateway's `PIRC_MODELS_FILE` (`gateway-models.json`).
    models_file: PathBuf,
    /// Root of every temporary directory the processes use.
    pub dir: TempDir,
}

impl Cluster {
    /// A gateway with one node, or `None` (test skipped) when
    /// `PIRC_CONFORMANCE_BIN_DIR` is unset.
    pub async fn start() -> Option<Self> {
        Self::start_with(GatewayOptions::default()).await
    }

    pub async fn start_with(options: GatewayOptions) -> Option<Self> {
        let bin_dir = bin_dir()?;
        for attempt in 1..=START_ATTEMPTS {
            match Self::try_start(&bin_dir, &options).await {
                Ok(cluster) => return Some(cluster),
                Err(reason) if attempt < START_ATTEMPTS => {
                    eprintln!("conformance cluster: {reason}; starting again");
                }
                Err(reason) => panic!("conformance cluster: {reason}"),
            }
        }
        unreachable!("the last attempt panics")
    }

    async fn try_start(bin_dir: &Path, options: &GatewayOptions) -> Result<Self, String> {
        let (dir, root) = run_dir();
        let llm = FakeLlm::start().await.expect("fake model server");
        let port = free_port();

        let models = root.join("gateway-models.json");
        fs::write(
            &models,
            serde_json::to_vec_pretty(&json!({
                "providers": { "fake": {
                    "api": "openai-completions",
                    "baseUrl": llm.base_url(),
                    "apiKey": "test-key",
                    "models": [{ "id": "fake-model", "reasoning": true,
                        "contextWindow": 100000, "maxTokens": 1000 }],
                } },
                "defaultModel": { "provider": "fake", "id": "fake-model", "thinking": "low" },
            }))
            .unwrap(),
        )
        .unwrap();
        let node_tokens = json!({ NODE_ID: NODE_TOKEN }).to_string();
        let mut env = vec![
            ("PIRC_HOST", "127.0.0.1".to_owned()),
            ("PIRC_PORT", port.to_string()),
            ("PIRC_STATE_DIR", dir_in(&root, "gateway-state")),
            ("PIRC_TRUSTED_PROXIES", "127.0.0.1,::1".to_owned()),
            ("PIRC_IDENTITY_HEADER", "x-pirc-user".to_owned()),
            ("PIRC_ALLOWED_USERS", USER.to_owned()),
            ("PIRC_ALLOWED_ORIGINS", ORIGIN.to_owned()),
            ("PIRC_ALLOWED_HOSTS", HOST.to_owned()),
            ("PIRC_NODE_TOKENS", node_tokens),
            ("PIRC_MODELS_FILE", models.display().to_string()),
            ("PIRC_CONFIG_DIR", dir_in(&root, "gateway-config")),
            ("PIRC_TIMEZONE", "UTC".to_owned()),
        ];
        override_env(&mut env, options.env.clone());
        let gateway = Process::spawn(
            "gateway",
            &gateway_bin(bin_dir),
            &[],
            &root,
            &dir_in(&root, "gateway-home"),
            &env,
        );

        let node = if options.without_node {
            None
        } else {
            Some(Self::spawn_node(
                bin_dir,
                &root,
                &format!("ws://127.0.0.1:{port}"),
                &options.node(),
            ))
        };

        let mut cluster = Self {
            node,
            gateway,
            llm,
            port,
            models_file: models,
            dir,
        };
        cluster
            .wait_ready(if options.without_node { 0 } else { 1 })
            .await?;
        Ok(cluster)
    }

    fn spawn_node(
        bin_dir: &Path,
        root: &Path,
        gateway_url: &str,
        options: &NodeOptions,
    ) -> Process {
        let workspace = dir_in(root, "workspace");
        fs::write(Path::new(&workspace).join("README.md"), "conformance\n").unwrap();
        let config_dir = dir_in(root, "node-config");
        // Side requests would consume scripted replies; tests that need them opt in.
        fs::write(
            Path::new(&config_dir).join("config.json"),
            json!({ "features": { "sessionTitle": { "enabled": false },
                "autoMode": { "useModel": false } } })
            .to_string(),
        )
        .unwrap();
        let srt = root.join("fake-srt.sh");
        write_executable(&srt, FAKE_SRT);
        let mut env = vec![
            ("PIRC_NODE_ID", NODE_ID.to_owned()),
            ("PIRC_NODE_TOKEN", NODE_TOKEN.to_owned()),
            ("PIRC_DAEMON_URL", gateway_url.to_owned()),
            ("PIRC_ALLOWED_USERS", USER.to_owned()),
            ("PIRC_STATE_DIR", dir_in(root, "node-state")),
            ("PIRC_CONFIG_DIR", config_dir),
            ("PIRC_SANDBOX_SRT", srt.display().to_string()),
            ("PIRC_BROWSER", "false".to_owned()),
            ("PIRC_SHUTDOWN_GRACE_MS", "200".to_owned()),
        ];
        // A chat node refuses configured workspaces.
        if !options.chat_node {
            let mut workspaces = vec![json!({ "id": "test", "path": workspace,
                "displayName": "Test", "defaults": {} })];
            if options.second_workspace {
                workspaces.push(
                    json!({ "id": "target", "path": dir_in(root, "workspace-target"),
                    "displayName": "Target", "defaults": {} }),
                );
            }
            env.push(("PIRC_WORKSPACES", json!(workspaces).to_string()));
        }
        if options.agent_core_only {
            env.push(("PIRC_AGENT_FEATURES", "none".to_owned()));
        }
        override_env(&mut env, options.env.clone());
        // `{run_dir}` in a value is the node's run directory, which only
        // exists now (the browser's profiles, `node_browser.rs`).
        let run_dir = root.display().to_string();
        for (_, value) in &mut env {
            if value.contains("{run_dir}") {
                *value = value.replace("{run_dir}", &run_dir);
            }
        }
        let (program, args) = node_command(bin_dir, options.chat_node);
        Process::spawn(
            "node",
            &program,
            &args,
            root,
            &dir_in(root, "node-home"),
            &env,
        )
    }

    /// Attach this fixture's Node through a loopback fault-injection relay.
    /// Only valid for a cluster started with `without_node`; restarts reuse the
    /// same launch and state, including the relay endpoint.
    pub async fn connect_node_via(&mut self, port: u16, options: NodeOptions) {
        assert!(self.node.is_none(), "cluster already has a Node");
        self.node = Some(Self::spawn_node(
            &bin_dir().expect("fixture binaries"),
            self.dir.path(),
            &format!("ws://127.0.0.1:{port}"),
            &options,
        ));
        self.wait_ready(1).await.unwrap();
    }

    /// The gateway's models file, which a test may rewrite before
    /// [`Cluster::reload_gateway`]. It starts with one provider, `fake`
    /// (the fake model server, key `test-key`, model `fake-model`), which is
    /// also the default model.
    pub fn models_file(&self) -> &Path {
        &self.models_file
    }

    /// Send SIGHUP to the gateway (it reloads its models file). Returns at
    /// once; the reload's effect has to be polled for.
    pub fn reload_gateway(&self) {
        self.gateway.signal(Signal::SIGHUP);
    }

    /// Restart only this fixture's Gateway, preserving its SQLite/device state.
    /// The real Node reconnects over its existing WebSocket retry path.
    pub async fn restart_gateway(&mut self, crash: bool) {
        self.gateway.restart(crash);
        self.wait_ready(u64::from(
            self.node.as_ref().is_some_and(|node| !node.stopped),
        ))
        .await
        .unwrap();
    }

    /// Restart only this fixture's Node. Source files/config are never reseeded.
    /// Await the actual disconnect before starting the replacement, so a cached
    /// health result from the old registration cannot count as readiness.
    pub async fn restart_node(&mut self, crash: bool) {
        self.stop_node(crash).await;
        self.resume_node().await;
    }

    /// Stop only this fixture's Node, retaining its launch/state for recovery tests.
    pub async fn stop_node(&mut self, crash: bool) {
        self.node
            .as_mut()
            .expect("cluster has a node")
            .stop_for_restart(crash);
        let api = self.api();
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            let health = api
                .send("GET", "/api/health", &crate::browser_headers(), None)
                .await;
            if health.body["nodes"] == 0 {
                break;
            }
            assert!(Instant::now() < deadline, "old Node did not disconnect");
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    }

    /// Resume the same stopped fixture Node; never reseed its configuration/files.
    pub async fn resume_node(&mut self) {
        let old = self.node.take().expect("cluster has a stopped node");
        assert!(old.stopped, "Node must be stopped before resuming");
        self.node = Some(Process::from_launch("node", &old.launch));
        self.wait_ready(1).await.unwrap();
    }

    /// `http://127.0.0.1:<port>`
    pub fn base_url(&self) -> String {
        format!("http://127.0.0.1:{}", self.port)
    }

    pub fn api(&self) -> Api {
        Api::new(self.base_url())
    }

    /// What the gateway has logged so far (stdout and stderr).
    pub fn gateway_log(&self) -> String {
        self.gateway.read_log()
    }

    /// Values that differ between runs, to be replaced in recorded transcripts.
    pub fn volatile(&self) -> Vec<(String, &'static str)> {
        vec![
            (
                self.dir
                    .path()
                    .canonicalize()
                    .unwrap()
                    .display()
                    .to_string(),
                "<tmp>",
            ),
            (self.dir.path().display().to_string(), "<tmp>"),
            (self.llm.base_url(), "<llm>"),
            (format!("127.0.0.1:{}", self.port), "<gateway>"),
        ]
    }

    /// Wait until the gateway answers and, when a node was started, lists
    /// it. A gateway without nodes may refuse the request (tests of its
    /// trust configuration); an answer in the gateway's own shape is enough
    /// then. `Err` when the gateway exits first: its port was probably taken.
    async fn wait_ready(&mut self, nodes: u64) -> Result<(), String> {
        let api = self.api();
        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            if let Some(status) = self.gateway.exited() {
                self.gateway.dump();
                return Err(format!("the gateway exited during startup ({status})"));
            }
            if let Some(node) = &mut self.node
                && !node.stopped
                && let Some(status) = node.exited()
            {
                node.dump();
                panic!("the node exited during startup ({status})");
            }
            if let Ok(response) = api
                .try_send("GET", "/api/health", &crate::browser_headers(), None)
                .await
            {
                let ready = if nodes == 0 {
                    is_gateway_answer(&response)
                } else {
                    response.status == 200 && response.body["nodes"] == nodes
                };
                if ready {
                    return Ok(());
                }
            }
            if Instant::now() > deadline {
                self.dump_logs();
                panic!("cluster did not become ready with {nodes} node(s)");
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    }

    fn dump_logs(&self) {
        self.gateway.dump();
        if let Some(node) = &self.node {
            node.dump();
        }
    }
}

impl Drop for Cluster {
    fn drop(&mut self) {
        if std::thread::panicking() {
            self.dump_logs();
        }
        // Fields then drop in order: the node stops before the gateway.
    }
}

/// A node alone, connected to a gateway the test plays
/// ([`crate::FakeGateway`]).
pub struct LoneNode {
    process: Process,
    /// Root of the node's temporary directories.
    pub dir: TempDir,
}

impl LoneNode {
    /// Start a node against `ws://127.0.0.1:<gateway_port>`, or `None` (test
    /// skipped) when `PIRC_CONFORMANCE_BIN_DIR` is unset.
    pub fn start(gateway_port: u16) -> Option<Self> {
        Self::start_with(gateway_port, NodeOptions::default())
    }

    /// [`LoneNode::start`] with other node options.
    pub fn start_with(gateway_port: u16, options: NodeOptions) -> Option<Self> {
        let bin_dir = bin_dir()?;
        let (dir, root) = run_dir();
        let url = format!("ws://127.0.0.1:{gateway_port}");
        let process = Cluster::spawn_node(&bin_dir, &root, &url, &options);
        Some(Self { process, dir })
    }

    /// Restart this fixture's process with its original state/config. The caller
    /// accepts the replacement connection on its FakeGateway.
    pub fn restart(&mut self, crash: bool) {
        self.process.restart(crash);
    }

    /// The node's exit status, once it has exited.
    pub fn exited(&mut self) -> Option<std::process::ExitStatus> {
        self.process.exited()
    }

    /// What the node has logged so far (stdout and stderr).
    pub fn log(&self) -> String {
        self.process.read_log()
    }

    /// Values that differ between runs, to be replaced in recorded transcripts.
    pub fn volatile(&self) -> Vec<(String, &'static str)> {
        let canonical = self.dir.path().canonicalize().unwrap();
        vec![
            (canonical.display().to_string(), "<tmp>"),
            (self.dir.path().display().to_string(), "<tmp>"),
        ]
    }
}

impl Drop for LoneNode {
    fn drop(&mut self) {
        if std::thread::panicking() {
            self.process.dump();
        }
    }
}

/// A fresh run directory and its canonical path. Not under /tmp: agents may
/// write there, and the node warns when its state lies inside a path its
/// agents may write.
fn run_dir() -> (TempDir, PathBuf) {
    // A long checkout path exceeds macOS's Unix socket address limit.
    // /var/tmp keeps names short without granting /tmp's sandbox write root.
    if cfg!(target_os = "macos") {
        let dir = tempfile::Builder::new()
            .prefix("pc-")
            .tempdir_in("/var/tmp")
            .unwrap();
        let root = dir.path().canonicalize().unwrap();
        return (dir, root);
    }
    let base = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../target/conformance");
    fs::create_dir_all(&base).expect("conformance directory");
    let dir = tempfile::Builder::new()
        .prefix("run-")
        .tempdir_in(&base)
        .expect("temporary directory");
    let root = dir.path().canonicalize().expect("temporary directory path");
    (dir, root)
}

/// `/api/health` itself, or one of the gateway's own error bodies.
fn is_gateway_answer(response: &Response) -> bool {
    (response.status == 200 && response.body["ok"] == true)
        || response.body["error"]["code"].is_string()
}

/// Canonical executable directory under test, or `None` when the suite is not requested.
/// Relative paths are resolved against the repository root, not a fixture directory.
pub fn bin_dir() -> Option<PathBuf> {
    let Some(dir) = std::env::var_os(BIN_DIR_VARIABLE) else {
        // Not a silent pass where the suite must run.
        assert!(
            std::env::var_os(REQUIRED_VARIABLE).is_none(),
            "{REQUIRED_VARIABLE} is set but {BIN_DIR_VARIABLE} is not"
        );
        eprintln!("{BIN_DIR_VARIABLE} is not set; skipping conformance test");
        return None;
    };
    let dir = PathBuf::from(dir);
    // Relative paths are relative to the repository root, like `bun run` scripts.
    let dir = if dir.is_absolute() {
        dir
    } else {
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../..")
            .join(dir)
    };
    Some(
        dir.canonicalize()
            .unwrap_or_else(|error| panic!("{BIN_DIR_VARIABLE} {}: {error}", dir.display())),
    )
}

/// The gateway under test: the bin dir's.
fn gateway_bin(bin_dir: &Path) -> PathBuf {
    bin_dir.join("pirc-gateway")
}

/// The node under test and its arguments (`pirc-node [chat]`).
fn node_command(bin_dir: &Path, chat: bool) -> (PathBuf, Vec<&'static str>) {
    let args = if chat { vec!["chat"] } else { Vec::new() };
    (bin_dir.join("pirc-node"), args)
}

fn dir_in(root: &Path, name: &str) -> String {
    let dir = root.join(name);
    fs::create_dir_all(&dir).unwrap();
    dir.display().to_string()
}

fn free_port() -> u16 {
    TcpListener::bind("127.0.0.1:0")
        .and_then(|listener| listener.local_addr())
        .expect("free port")
        .port()
}

fn override_env(env: &mut Vec<(&'static str, String)>, overrides: Vec<(&'static str, String)>) {
    for (name, value) in overrides {
        env.retain(|(existing, _)| *existing != name);
        env.push((name, value));
    }
}

/// A child process logging to a file, stopped when dropped. It stays in the
/// test's process group, so an interrupted test run (Ctrl-C) stops it too.
/// Known gap: a test binary killed outright (SIGKILL) leaves its children
/// and their `target/conformance/run-*` directory behind.
struct Process {
    name: &'static str,
    child: Child,
    log: PathBuf,
    stopped: bool,
    launch: Launch,
}

#[derive(Clone)]
struct Launch {
    program: PathBuf,
    args: Vec<String>,
    root: PathBuf,
    home: String,
    env: Vec<(&'static str, String)>,
}

impl Process {
    fn spawn(
        name: &'static str,
        program: &Path,
        args: &[&str],
        root: &Path,
        home: &str,
        env: &[(&'static str, String)],
    ) -> Self {
        let log = root.join(format!("{name}.log"));
        let file = File::create(&log).unwrap();
        let child = Command::new(program)
            .args(args)
            .current_dir(root)
            .env_clear()
            .env("PATH", std::env::var_os("PATH").unwrap_or_default())
            .env("HOME", home)
            .envs(env.iter().map(|(name, value)| (name, value)))
            .stdin(Stdio::null())
            .stdout(file.try_clone().unwrap())
            .stderr(file)
            .spawn()
            .unwrap_or_else(|error| panic!("cannot start {}: {error}", program.display()));
        Self {
            name,
            child,
            log,
            stopped: false,
            launch: Launch {
                program: program.into(),
                args: args.iter().map(|s| (*s).into()).collect(),
                root: root.into(),
                home: home.into(),
                env: env.to_vec(),
            },
        }
    }

    fn stop_for_restart(&mut self, crash: bool) {
        if crash {
            let _ = self.child.kill();
            let _ = self.child.wait();
            self.stopped = true;
        } else {
            self.stop();
        }
    }
    fn restart(&mut self, crash: bool) {
        self.stop_for_restart(crash);
        let launch = self.launch.clone();
        *self = Self::from_launch(self.name, &launch);
    }
    fn from_launch(name: &'static str, launch: &Launch) -> Self {
        let args: Vec<&str> = launch.args.iter().map(String::as_str).collect();
        Self::spawn(
            name,
            &launch.program,
            &args,
            &launch.root,
            &launch.home,
            &launch.env,
        )
    }

    /// The exit status, once the process has exited.
    fn exited(&mut self) -> Option<std::process::ExitStatus> {
        self.child.try_wait().ok().flatten()
    }

    fn signal(&self, signal: Signal) {
        if !self.stopped {
            let _ = kill(Pid::from_raw(self.child.id() as i32), signal);
        }
    }

    /// SIGTERM (a node then stops its agents), then SIGKILL after a grace period.
    fn stop(&mut self) {
        if std::mem::replace(&mut self.stopped, true) {
            return;
        }
        let pid = Pid::from_raw(self.child.id() as i32);
        let _ = kill(pid, Signal::SIGTERM);
        let deadline = Instant::now() + Duration::from_secs(3);
        while Instant::now() < deadline {
            if self.exited().is_some() {
                return;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
    }

    /// The whole log so far.
    fn read_log(&self) -> String {
        std::fs::read_to_string(&self.log).unwrap_or_default()
    }

    /// The last 8 KiB of the log, for a failing test.
    fn dump(&self) {
        let Ok(mut file) = File::open(&self.log) else {
            return;
        };
        let length = file.metadata().map(|m| m.len()).unwrap_or(0);
        let _ = file.seek(SeekFrom::Start(length.saturating_sub(8192)));
        let mut tail = String::new();
        let _ = file.read_to_string(&mut tail);
        eprintln!(
            "---- {} log ({}) ----\n{tail}",
            self.name,
            self.log.display()
        );
    }
}

impl Drop for Process {
    fn drop(&mut self) {
        self.stop();
    }
}
