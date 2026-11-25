//! A real `pirc-node agent` under the native backend: started through
//! `NativeSandbox::prepare` as the runner starts it, configured with a fake
//! inference socket (the model's replies scripted here, as
//! `crates/pirc-conformance`'s agent harness does), and driven through its
//! tools. The Linux cases of `apps/gateway/test/sandbox-srt.integration.test.ts`
//! (a real agent under the real sandbox) and of `sandbox.integration.test.ts`
//! (no agent without a sandbox); the fake-srt cases of the latter (policy
//! rendering, approvals, unsandboxed exec) are conformance scenarios
//! (`node_*`). Skipped, with a message, where `bwrap` is not on `PATH`.
//!
//! Not ported: the `ptc` script and pseudo-terminal cases (the agent runs
//! with its features off here, and the sandbox side of both is the same
//! bubblewrap the `bash` tool runs in), and `unsandboxed_bash` (the node's
//! runner, not the sandbox).

#![cfg(target_os = "linux")]

mod sandbox_linux_support;

use std::collections::VecDeque;
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use pirc_node::sandbox::Sandbox;
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixListener;

use sandbox_linux_support::{fixture, fixture_in, gone, path};

const TIMEOUT: Duration = Duration::from_secs(60);

/// `sandbox.integration.test.ts`: "starts no agent when the sandbox is
/// unavailable".
#[tokio::test]
async fn starts_no_agent_when_the_sandbox_is_unavailable() {
    let Some(f) = fixture("unavailable") else {
        return;
    };
    let sandbox = f.native(f.config.clone(), "/nonexistent");
    let error = match sandbox.prepare(f.input("pi_none", None)).await {
        Ok(_) => panic!("an agent would start without a sandbox"),
        Err(error) => error,
    };
    assert_eq!(error.status, 503);
    assert_eq!(
        error.message,
        "Agents on this node must run in the sandbox, and it is unavailable: bubblewrap (bwrap) was not found on PATH"
    );
}

/// The gateway's public catalog for one fake provider (as the conformance
/// harness's `fake_models`).
fn models(socket: &Path) -> Value {
    json!({
        "providers": { "fake": { "api": "openai-completions", "baseUrl": "https://gateway.invalid",
            "headers": {}, "compat": {},
            "models": [{ "id": "fake-model", "name": "Fake model", "contextWindow": 100000,
                "maxTokens": 1000, "reasoning": false, "input": ["text"], "compat": {} }] } },
        "defaultModel": { "provider": "fake", "id": "fake-model" },
        "inference": { "socketPath": socket.display().to_string(), "token": "sandbox-test-token" },
    })
}

fn usage() -> Value {
    json!({ "input": 1, "output": 1, "cacheRead": 0, "cacheWrite": 0, "totalTokens": 2 })
}

/// A model reply calling `tools` (`(id, name, arguments)`), as NDJSON.
fn tool_reply(tools: &[(&str, &str, Value)]) -> Vec<Value> {
    let mut lines = Vec::new();
    let mut content = Vec::new();
    for (index, (id, name, args)) in tools.iter().enumerate() {
        let call = json!({ "type": "toolCall", "id": id, "name": name, "arguments": args });
        lines.push(json!({ "type": "model_delta", "delta": { "type": "toolcall_start", "contentIndex": index, "id": id, "toolName": name } }));
        lines.push(json!({ "type": "model_delta", "delta": { "type": "toolcall_delta", "contentIndex": index, "delta": args.to_string() } }));
        lines.push(json!({ "type": "model_delta", "delta": { "type": "toolcall_end", "contentIndex": index, "toolCall": call } }));
        content.push(call);
    }
    lines.push(
        json!({ "type": "model_end", "message": { "role": "assistant", "content": content,
        "api": "openai-completions", "provider": "fake", "model": "fake-model",
        "usage": usage(), "stopReason": "toolUse", "timestamp": 1 } }),
    );
    lines
}

fn text_reply(text: &str) -> Vec<Value> {
    vec![
        json!({ "type": "model_delta", "delta": { "type": "text_start", "contentIndex": 0 } }),
        json!({ "type": "model_delta", "delta": { "type": "text_delta", "contentIndex": 0, "delta": text } }),
        json!({ "type": "model_delta", "delta": { "type": "text_end", "contentIndex": 0, "content": text } }),
        json!({ "type": "model_end", "message": { "role": "assistant",
            "content": [{ "type": "text", "text": text }],
            "api": "openai-completions", "provider": "fake", "model": "fake-model",
            "usage": usage(), "stopReason": "stop", "timestamp": 1 } }),
    ]
}

/// The node's inference socket: `GET /models`, and `POST /inference`
/// answered with the next scripted reply (then "done").
fn serve_inference(
    socket: &Path,
    catalog: Value,
    replies: Arc<Mutex<VecDeque<Vec<Value>>>>,
    writes: Arc<pirc_node::persistence::Writes>,
) {
    let listener = UnixListener::bind(socket).unwrap();
    tokio::spawn(async move {
        while let Ok((mut stream, _)) = listener.accept().await {
            let catalog = catalog.clone();
            let replies = replies.clone();
            let writes = writes.clone();
            tokio::spawn(async move {
                let mut buffer = Vec::new();
                let mut chunk = [0u8; 8192];
                let head_end = loop {
                    if let Some(at) = buffer.windows(4).position(|w| w == b"\r\n\r\n") {
                        break at + 4;
                    }
                    match stream.read(&mut chunk).await {
                        Ok(0) | Err(_) => return,
                        Ok(read) => buffer.extend_from_slice(&chunk[..read]),
                    }
                };
                let head = String::from_utf8_lossy(&buffer[..head_end]).into_owned();
                let length: usize = head
                    .lines()
                    .find_map(|line| {
                        let (name, value) = line.split_once(':')?;
                        name.eq_ignore_ascii_case("content-length")
                            .then(|| value.trim().parse().ok())?
                    })
                    .unwrap_or(0);
                while buffer.len() < head_end + length {
                    match stream.read(&mut chunk).await {
                        Ok(0) | Err(_) => return,
                        Ok(read) => buffer.extend_from_slice(&chunk[..read]),
                    }
                }
                let body = if head.starts_with("GET /models") {
                    catalog.to_string()
                } else if head.starts_with("POST /persistence ") {
                    let token = head
                        .lines()
                        .find_map(|line| line.strip_prefix("Authorization: Bearer "))
                        .unwrap_or_default();
                    let body: Value =
                        serde_json::from_slice(&buffer[head_end..head_end + length]).unwrap();
                    writes
                        .apply_response(token, body.clone())
                        .unwrap_or_else(|error| {
                            panic!("persistence request failed: {body}: {error:?}")
                        })
                        .to_string()
                } else {
                    let reply = replies
                        .lock()
                        .unwrap()
                        .pop_front()
                        .unwrap_or_else(|| text_reply("done"));
                    reply.iter().map(|line| format!("{line}\n")).collect()
                };
                let response = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
                let _ = stream.write_all(response.as_bytes()).await;
                let _ = stream.shutdown().await;
            });
        }
    });
}

/// The synthetic peer must preserve session proofs, including when bwrap is
/// unavailable: an agent rejects an otherwise successful reply without its hash.
#[tokio::test]
async fn persistence_transport_preserves_session_snapshot_hashes() {
    let root = tempfile::tempdir().unwrap();
    let socket = root.path().join("socket");
    let writes = Arc::new(pirc_node::persistence::Writes::default());
    let lease = writes
        .register(socket.to_str().unwrap(), root.path(), None)
        .unwrap();
    serve_inference(
        &socket,
        models(&socket),
        Arc::new(Mutex::new(VecDeque::new())),
        writes,
    );
    for op in ["session_open", "session_snapshot"] {
        let body = json!({"op": op, "path": root.path().join("session.jsonl")}).to_string();
        let mut stream = tokio::net::UnixStream::connect(&socket).await.unwrap();
        stream
            .write_all(
                format!(
                    "POST /persistence HTTP/1.1\r\nAuthorization: Bearer {}\r\nContent-Length: {}\r\n\r\n{body}",
                    lease.config.token, body.len()
                )
                .as_bytes(),
            )
            .await
            .unwrap();
        let mut response = String::new();
        tokio::time::timeout(TIMEOUT, stream.read_to_string(&mut response))
            .await
            .unwrap()
            .unwrap();
        assert!(response.starts_with("HTTP/1.1 200 OK\r\n"), "{response}");
        let (_, body) = response.split_once("\r\n\r\n").unwrap();
        let reply: Value = serde_json::from_str(body).unwrap();
        assert_eq!(reply["ok"], true);
        assert_eq!(reply["hash"], pirc_agent::journal::digest(&[]), "{op}");
    }
}

/// bash for the agent's `bash` tool, which runs `/bin/bash`: on hosts
/// without one (NixOS) the sandbox gets a `/bin` holding `sh` and the bash
/// next to it (the conformance harness's shim, inside bubblewrap).
fn bin_bash_args() -> Vec<OsString> {
    if Path::new("/bin/bash").exists() {
        return Vec::new();
    }
    let sh = std::fs::canonicalize("/bin/sh").unwrap();
    let bash = sh.with_file_name("bash");
    assert!(
        bash.exists(),
        "no /bin/bash and no bash next to {}",
        sh.display()
    );
    ["--tmpfs", "/bin", "--ro-bind"]
        .into_iter()
        .map(OsString::from)
        .chain([
            sh.clone().into(),
            "/bin/sh".into(),
            "--ro-bind".into(),
            bash.into(),
            "/bin/bash".into(),
        ])
        .collect()
}

#[tokio::test]
async fn a_real_agent_is_confined() {
    let config_json = r#"{"features":{"autoMode":{"mode":"full-access","useModel":false}},"sandbox":{"network":{"defaultDomains":false}}}"#;
    let Some(f) = fixture_in(None, "agent", config_json) else {
        return;
    };
    let (root, w) = (&f.root, path(&f.root, "workspace"));
    let mut config = f.config.clone();
    config.agent_command = env!("CARGO_BIN_EXE_pirc-node").to_owned();
    config.agent_args = vec!["agent".to_owned()];
    let path_var = std::env::var("PATH").unwrap_or_default();
    let sandbox = f.native(config, &path_var);

    std::fs::create_dir_all(root.join("inference")).unwrap();
    let socket = root.join("inference/socket");
    let replies = Arc::new(Mutex::new(VecDeque::new()));
    let writes = Arc::new(pirc_node::persistence::Writes::default());
    let session_dir = f.config.sessions_dir.join("pi_agent");
    std::fs::create_dir_all(&session_dir).unwrap();
    let persistence = writes
        .register(socket.to_str().unwrap(), &session_dir, None)
        .unwrap();
    serve_inference(&socket, models(&socket), replies.clone(), writes);
    let secret = path(root, "state/secret");
    let home_probe = path(root, "home/probe");
    // Port of a host listener the agent must not reach.
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    replies.lock().unwrap().push_back(tool_reply(&[
        ("a", "bash", json!({ "command": format!("cat {secret}") })),
        ("b", "bash", json!({ "command": "echo inside > ok.txt && cat ok.txt" })),
        ("c", "bash", json!({ "command": format!("touch {home_probe}") })),
        ("d", "read", json!({ "path": secret })),
        ("e", "bash", json!({ "command": "echo x >> .git/config; echo x > .git/hooks/pre-commit; mkdir .pirc; echo x > .bashrc; echo status=$?" })),
        ("f", "bash", json!({ "command": format!("(exec 3<>/dev/tcp/127.0.0.1/{port}) 2>/dev/null; echo net=$?") })),
        ("g", "bash", json!({ "command": "echo \"backend=$PIRC_SANDBOX_BACKEND proxy=$HTTPS_PROXY\"" })),
    ]));

    let session = "pi_agent";
    let mut prepared = sandbox
        .prepare(f.input(session, Some(socket.clone())))
        .await
        .unwrap();
    let end_of_options = prepared.args.iter().position(|a| a == "--").unwrap();
    prepared
        .args
        .splice(end_of_options..end_of_options, bin_bash_args());
    let session_dir = f.config.sessions_dir.join(session);
    // Keep the production descriptor mappings, including bubblewrap's seccomp
    // filter; reconstructing just the program/args can read an unrelated fd.
    let mut command = prepared.command().unwrap();
    command
        .args(["--mode", "rpc", "--session-dir"])
        .arg(&session_dir)
        .env_clear()
        .env("PATH", &path_var)
        .env("HOME", root.join("home"))
        .env("PIRC_CONFIG_DIR", root.join("config"))
        .env("PIRC_AGENT_FEATURES", "none")
        .env(
            "PIRC_MODE",
            serde_json::to_string(&pirc_protocol::mode::default_work()).unwrap(),
        )
        .env("PIRC_SANDBOX", "srt")
        .env(
            "PIRC_SANDBOX_POLICY",
            serde_json::to_string(&prepared.policy.paths).unwrap(),
        )
        .envs(prepared.env.iter().map(|(k, v)| (k, v)))
        .current_dir(root.join("workspace"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .kill_on_drop(true);
    let mut child = command.spawn().unwrap();
    let mut stdin = child.stdin.take().unwrap();
    let mut lines = BufReader::new(child.stdout.take().unwrap()).lines();
    let mut send = async |value: Value| {
        stdin
            .write_all(format!("{value}\n").as_bytes())
            .await
            .unwrap();
    };
    send(
        json!({ "type": "configure", "models": models(&socket), "persistence": persistence.config, "capabilities": { "version": 1 } }),
    )
    .await;
    let mut next_until = async |done: &dyn Fn(&Value) -> bool| -> Value {
        loop {
            let line = tokio::time::timeout(TIMEOUT, lines.next_line())
                .await
                .expect("timed out waiting for the agent")
                .unwrap()
                .expect("the agent exited");
            let Ok(value) = serde_json::from_str::<Value>(&line) else {
                continue;
            };
            if done(&value) {
                return value;
            }
        }
    };
    // A cheap request first: the agent answers from inside the sandbox.
    send(json!({ "id": "c1", "type": "get_state" })).await;
    let state = next_until(&|v| v["type"] == "response" && v["id"] == "c1").await;
    assert_eq!(state["success"], true, "{state}");

    send(json!({ "id": "c2", "type": "prompt", "message": "probe the sandbox" })).await;
    next_until(&|v| v["type"] == "agent_settled").await;
    send(json!({ "id": "c3", "type": "get_messages" })).await;
    let messages = next_until(&|v| v["type"] == "response" && v["id"] == "c3").await;
    let result = |id: &str| -> String {
        messages["data"]["messages"]
            .as_array()
            .unwrap()
            .iter()
            .find(|m| m["role"] == "toolResult" && m["toolCallId"] == id)
            .map(|m| {
                m["content"][0]["text"]
                    .as_str()
                    .unwrap_or_default()
                    .to_owned()
            })
            .unwrap_or_else(|| panic!("no result for {id}: {messages}"))
    };
    let a = result("a");
    assert!(!a.contains("node secret"), "{a}");
    assert!(
        a.contains("No such file or directory") || a.contains("Permission denied"),
        "{a}"
    );
    assert!(result("b").contains("inside"));
    assert!(
        result("c").contains("Read-only file system"),
        "{}",
        result("c")
    );
    assert!(result("d").contains("is private"), "{}", result("d"));
    let e = result("e");
    assert!(e.contains("status=1") || e.contains("status=2"), "{e}");
    assert!(result("f").contains("net=1"), "{}", result("f"));
    assert!(
        result("g").contains("backend=native proxy=http://"),
        "{}",
        result("g")
    );

    drop(stdin);
    let _ = tokio::time::timeout(TIMEOUT, child.wait()).await;
    prepared.cleanup();
    assert_eq!(
        std::fs::read_to_string(root.join("workspace/ok.txt")).unwrap(),
        "inside\n"
    );
    assert_eq!(
        std::fs::read_to_string(root.join("workspace/.git/config")).unwrap(),
        "[core]"
    );
    assert!(!PathBuf::from(&home_probe).exists());
    for name in [".pirc", ".bashrc", ".git/hooks/pre-commit"] {
        assert!(gone(&Path::new(&w).join(name)).await, "{name}");
    }
}
