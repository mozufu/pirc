//! Node-owned state remains writable through the private channel while the
//! same native sandbox refuses ordinary tool writes. Only synthetic data.
#![cfg(any(target_os = "linux", target_os = "macos"))]
use pirc_config::{Env, NodeConfig};
use pirc_node::sandbox::{PrepareInput, Sandbox};
use serde_json::{Value, json};
use std::{fs, path::PathBuf, process::Stdio, sync::Arc, time::Duration};
use tokio::io::AsyncWriteExt;
mod persistence_support;
mod scratch_support;

#[test]
#[ignore = "private subprocess worker, invoked by native_state_custody"]
fn persistence_worker() {
    use pirc_agent::{
        session_store::{EntryData, SessionStore},
        state_io,
    };
    use std::io::BufRead;
    let line = std::io::stdin().lock().lines().next().unwrap().unwrap();
    let input: Value = serde_json::from_str(&line).unwrap();
    let dir = PathBuf::from(input["dir"].as_str().unwrap());
    let memory = PathBuf::from(input["memory"].as_str().unwrap());
    state_io::configure(Some(
        serde_json::from_value(input["persistence"].clone()).unwrap(),
    ))
    .unwrap();
    for path in [
        dir.join("session.jsonl"),
        dir.join("context.json"),
        memory.join("key.jsonl"),
    ] {
        assert!(
            fs::write(&path, "forged").is_err(),
            "tool could rewrite {}",
            path.display()
        );
    }
    let mut store = SessionStore::open(dir.clone(), "/workspace").unwrap();
    store
        .append(EntryData::Custom {
            custom_type: "background-state".into(),
            data: json!({"status":"finished"}),
        })
        .unwrap();
    let snapshot = json!({"version":1,"sections":[],"tools":[],"usage":{},"model":{},"prompt":"x".repeat(300_000)});
    pirc_agent::context::write_context(&dir, &snapshot).unwrap();
    assert_eq!(
        pirc_agent::context::read_context(&dir).unwrap(),
        Some(snapshot)
    );
    let team = dir.join("team/worker");
    state_io::create_dir_all(&team).unwrap();
    state_io::write(&team.join("metadata.json"), b"{\"ok\":true}").unwrap();
    let ledger = pirc_agent::features::memory::workspace::WorkspaceLedger::new(
        memory.display().to_string(),
        "key".into(),
        "/workspace".into(),
    );
    let _lock = ledger
        .try_lock()
        .unwrap()
        .expect("read-only ledger can still be locked");
    assert!(
        ledger
            .append(&json!({"type":"test-memory","source":"synthetic"}))
            .is_err(),
        "repository commits require host source and authority validation"
    );
    assert!(
        state_io::write(&memory.join("key.jsonl"), b"forged").is_err(),
        "ledger is append only"
    );
    assert!(state_io::write(&dir.join("../outside"), b"escape").is_err());
}

#[tokio::test]
async fn native_state_custody() {
    #[cfg(target_os = "linux")]
    if pirc_node::sandbox::linux::find_bwrap(&Env::from_process()).is_none() {
        eprintln!("skipped: bubblewrap unavailable; native state custody not tested");
        return;
    }
    // Not the cargo target directory: its path may hold a space or be too long for
    // the Unix socket bound below (`scratch_support`).
    let temp = scratch_support::scratch_dir("cu-");
    let root = temp.path().canonicalize().unwrap();
    let home = root.join("home");
    let cwd = root.join("workspace");
    fs::create_dir(&home).unwrap();
    fs::create_dir(&cwd).unwrap();
    let vars = [
        ("HOME", home.display().to_string()),
        ("PIRC_NODE_ID", "custody".into()),
        ("PIRC_ALLOWED_USERS", "test-user".into()),
        ("PIRC_NODE_TOKEN", "0123456789abcdef0123456789abcdef".into()),
        ("PIRC_DAEMON_URL", "ws://127.0.0.1:8787".into()),
        ("PIRC_STATE_DIR", root.join("state").display().to_string()),
        ("PIRC_CONFIG_DIR", root.join("config").display().to_string()),
        ("PIRC_BROWSER", "false".into()),
        ("PATH", std::env::var("PATH").unwrap_or_default()),
    ];
    let env = Env::new(vars.iter().map(|(k, v)| (*k, v.as_str())), &root);
    let mut config = NodeConfig::load(&env, pirc_protocol::NodeRole::Node).unwrap();
    config.agent_command = std::env::current_exe().unwrap().display().to_string();
    config.agent_args = vec!["agent".into()]; // production builtin policy
    let dir = config.sessions_dir.join("pi_custody");
    let memory = config.workspace_memory_dir.clone();
    fs::create_dir_all(&dir).unwrap();
    fs::create_dir_all(&memory).unwrap();
    let ledger = memory.join("key.jsonl");
    fs::write(&ledger, "").unwrap();
    let socket_dir = root.join("state/inference");
    fs::create_dir_all(&socket_dir).unwrap();
    let socket = socket_dir.join("socket");
    let address = pirc_protocol::SocketPath::new(&socket).unwrap();
    let listener = tokio::net::UnixListener::bind(&address.path).unwrap();
    let writes = Arc::new(pirc_node::persistence::Writes::default());
    let lease = writes
        .register(socket.to_str().unwrap(), &dir, Some(&ledger))
        .unwrap();
    let serving = persistence_support::serve(listener, writes);
    #[cfg(target_os = "macos")]
    let sandbox = pirc_node::sandbox::macos::MacSandbox::new(config.clone(), env.clone());
    #[cfg(target_os = "linux")]
    let sandbox = pirc_node::sandbox::linux::NativeSandbox::new(
        config.clone(),
        env.clone(),
        PathBuf::from(env!("CARGO_BIN_EXE_pirc-node")),
    );
    let mut prepared = sandbox
        .prepare(PrepareInput {
            grants: Vec::new(),
            session_id: "pi_custody".into(),
            workspace_root: cwd.clone(),
            session_dir: dir.clone(),
            inference_socket: Some(socket),
            protected_paths: vec![],
            workspace_memory_file: Some(ledger.clone()),
            recovery: None,
        })
        .await
        .unwrap();
    assert_eq!(prepared.args.pop().unwrap(), "agent");
    prepared.args.extend(
        ["--ignored", "--exact", "persistence_worker", "--nocapture"]
            .into_iter()
            .map(Into::into),
    );
    let mut command = prepared.command().unwrap();
    command
        .env_clear()
        .env("PATH", std::env::var("PATH").unwrap_or_default())
        .env("HOME", &home)
        .envs(prepared.env.iter().map(|(k, v)| (k, v)))
        .current_dir(&cwd)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    let mut child = command.spawn().unwrap();
    let input = json!({"dir":dir,"memory":memory,"persistence":lease.config});
    child
        .stdin
        .take()
        .unwrap()
        .write_all(format!("{input}\n").as_bytes())
        .await
        .unwrap();
    let output = tokio::time::timeout(Duration::from_secs(40), child.wait_with_output())
        .await
        .unwrap()
        .unwrap();
    serving.abort();
    prepared.cleanup();
    assert!(
        output.status.success(),
        "{}\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(
        fs::read_to_string(dir.join("session.jsonl"))
            .unwrap()
            .contains("background-state")
    );
    assert!(fs::read_to_string(ledger).unwrap().is_empty());
    assert_eq!(
        fs::read_to_string(dir.join("team/worker/metadata.json")).unwrap(),
        "{\"ok\":true}"
    );
}
