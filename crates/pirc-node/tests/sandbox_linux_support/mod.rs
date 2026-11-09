//! A node layout for the native sandbox's tests (`sandbox_linux_*.rs`):
//! state, config, home, workspace and temp directories outside `/tmp` (a
//! write root of every session), and a [`NativeSandbox`] over them.

#![allow(dead_code)] // Each test file uses part of it.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use pirc_config::{Env, NodeConfig};
use pirc_node::error::ApiError;
use pirc_node::sandbox::linux::{NativeSandbox, find_bwrap};
use pirc_node::sandbox::{PrepareInput, Prepared, Sandbox};
use pirc_protocol::NodeRole;

pub struct Fixture {
    pub root: PathBuf,
    pub config: NodeConfig,
    pub env: Env,
    pub sandbox: NativeSandbox,
    vars: Vec<(String, String)>,
    /// `TMPDIR`.
    pub tmp: tempfile::TempDir,
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

pub fn path(root: &Path, rest: &str) -> String {
    root.join(rest).display().to_string()
}

/// Whether bubblewrap is on `PATH` (says so when it is not).
pub fn have_bwrap() -> bool {
    let path_var = std::env::var("PATH").unwrap_or_default();
    let found = find_bwrap(&Env::new([("PATH", path_var.as_str())], "/")).is_some();
    if !found {
        eprintln!("skipped: bwrap is not on PATH, so the native sandbox cannot be tested here");
    }
    found
}

/// A fixture under `base` (default: the target's temp directory) whose
/// agent is `/bin/sh`, or `None` without bubblewrap. `config_json` is the
/// agent config.
pub fn fixture_in(base: Option<&Path>, name: &str, config_json: &str) -> Option<Fixture> {
    fixture_env(base, name, config_json, &[])
}

/// [`fixture_in`] with `extra` in the node's environment.
pub fn fixture_env(
    base: Option<&Path>,
    name: &str,
    config_json: &str,
    extra: &[(&str, &str)],
) -> Option<Fixture> {
    if !have_bwrap() {
        return None;
    }
    let base = base.map_or_else(
        || PathBuf::from(env!("CARGO_TARGET_TMPDIR")),
        Path::to_path_buf,
    );
    let guard = serial();
    let root = base.join(format!("sandbox-linux-{name}"));
    let _ = fs::remove_dir_all(&root);
    for dir in [
        "home/.ssh",
        "state",
        "config",
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
    fs::write(root.join("config/config.json"), config_json).unwrap();
    let path_var = std::env::var("PATH").unwrap_or_default();
    let (home, state, config_dir) = (
        path(&root, "home"),
        path(&root, "state"),
        path(&root, "config"),
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
    let vars: Vec<(String, String)> = vars
        .iter()
        .chain(extra)
        .map(|(k, v)| ((*k).to_owned(), (*v).to_owned()))
        .collect();
    let env = Env::new(vars.iter().map(|(k, v)| (k.as_str(), v.as_str())), &root);
    let mut config = NodeConfig::load(&env, NodeRole::Node).unwrap();
    config.agent_command = "/bin/sh".to_owned();
    config.agent_args = Vec::new();
    let sandbox = NativeSandbox::new(
        config.clone(),
        env.clone(),
        PathBuf::from(env!("CARGO_BIN_EXE_pirc-node")),
    );
    Some(Fixture {
        root,
        config,
        env,
        sandbox,
        vars,
        tmp: tmp_dir,
        _serial: guard,
    })
}

/// [`fixture_in`] with no network allowed but `localhost`.
pub fn fixture(name: &str) -> Option<Fixture> {
    fixture_in(
        None,
        name,
        r#"{"sandbox":{"network":{"defaultDomains":false,"allowedDomains":["localhost"]}}}"#,
    )
}

impl Fixture {
    /// Another backend over this layout, with `config` and `PATH`.
    pub fn native(&self, config: NodeConfig, path_var: &str) -> NativeSandbox {
        let vars = self
            .vars
            .iter()
            .map(|(k, v)| (k.as_str(), if k == "PATH" { path_var } else { v.as_str() }));
        NativeSandbox::new(
            config,
            Env::new(vars, &self.root),
            PathBuf::from(env!("CARGO_BIN_EXE_pirc-node")),
        )
    }

    /// The input of a session of the workspace.
    pub fn input(&self, session: &str, inference_socket: Option<PathBuf>) -> PrepareInput {
        let session_dir = self.config.sessions_dir.join(session);
        fs::create_dir_all(&session_dir).unwrap();
        PrepareInput {
            grants: Vec::new(),
            session_id: session.to_owned(),
            workspace_root: self.root.join("workspace"),
            session_dir,
            inference_socket,
            protected_paths: Vec::new(),
            workspace_memory_file: None,
            project_files_dir: None,
            recovery: None,
        }
    }

    pub async fn try_prepare(&self, session: &str) -> Result<Prepared, ApiError> {
        self.sandbox.prepare(self.input(session, None)).await
    }

    /// `script` as the agent (`/bin/sh -c <script>`): its exit code.
    pub async fn sh(&self, script: &str) -> i32 {
        let prepared = self.try_prepare("pi_sh").await.unwrap();
        let code = run(&prepared, &["-c", script], &self.root.join("workspace")).await;
        prepared.cleanup();
        code
    }
}

/// Run `prepared` with `args` appended in `cwd`: its exit code.
pub async fn run(prepared: &Prepared, args: &[&str], cwd: &Path) -> i32 {
    let mut command = prepared.command().unwrap();
    command
        .args(args)
        .envs(prepared.env.iter().map(|(k, v)| (k, v)))
        .current_dir(cwd)
        .stdin(Stdio::null())
        .kill_on_drop(true);
    let status = tokio::time::timeout(Duration::from_secs(30), command.status())
        .await
        .unwrap()
        .unwrap();
    status.code().unwrap_or(-1)
}

/// Whether `path` is gone within two seconds: a session's placeholders
/// are removed on the blocking pool a moment after its cleanup.
pub async fn gone(path: &Path) -> bool {
    for _ in 0..200 {
        if std::fs::symlink_metadata(path).is_err() {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    false
}
