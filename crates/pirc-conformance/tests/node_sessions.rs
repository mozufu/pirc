//! Session routes and the runner's command handling on a real node
//! (`apps/gateway/src/node/app.ts`, `runner.ts`, `reducer.ts`), through a
//! real gateway: rename, delete, control leases, every command type while
//! the agent runs (with the fake model held mid-reply), the run's outcome
//! on provider errors and retries, agent dialogs answered as interactions,
//! and what a snapshot reports once the runner is gone. Recorded from the
//! TS node (docs/development/historical-records.md).

mod node_sessions_support;

use std::path::Path;

use nix::sys::signal::{Signal, kill};
use nix::unistd::Pid;
use node_sessions_support::{
    HeldLlm, Hold, Session, Step, agent_event, brief, held_cluster, mask_times, poll, read_until,
};
use pirc_conformance::{Cluster, GatewayOptions, Transcript, USER, WORKSPACE_ID, browser_headers};
use serde_json::{Value, json};

/// Allowed by the gateway of `node_session_routes`, unknown to its node.
const STRANGER: &str = "stranger@example.com";

/// The settled-run frames in brief, for the transcript.
fn briefs(frames: &[Value]) -> Value {
    json!(frames.iter().map(brief).collect::<Vec<_>>())
}

/// The parts of a snapshot these scenarios are about.
fn state(snapshot: &Value) -> Value {
    let mut picked = json!({
        "runnerState": snapshot["session"]["runnerState"],
        "run": snapshot["run"],
        "queue": snapshot["queue"],
        "partialMessage": snapshot["partialMessage"],
        "operations": snapshot["operations"],
        "interactions": snapshot["interactions"],
        "agent": snapshot["agent"],
        "history": snapshot["history"],
        "partialOutputLost": snapshot["partialOutputLost"],
        "sandbox": snapshot["sandbox"],
    });
    mask_times(&mut picked);
    picked
}

/// The held reply's first chunk has reached the snapshot's partial message.
fn streaming(snapshot: &Value) -> bool {
    snapshot["partialMessage"]["content"]["0"]["text"].is_string()
}

/// The user and assistant texts a model request carried, in order.
fn conversation(request: &Value) -> Value {
    let messages = request["messages"].as_array().cloned().unwrap_or_default();
    json!(
        messages
            .iter()
            .filter(|m| m["role"] != "system" && m["role"] != "developer")
            .map(|m| {
                let content = match &m["content"] {
                    Value::String(text) => json!(text),
                    Value::Array(parts) => {
                        json!(parts.iter().map(|p| p["text"].clone()).collect::<Vec<_>>())
                    }
                    other => other.clone(),
                };
                json!({ "role": m["role"], "content": content })
            })
            .collect::<Vec<_>>()
    )
}

/// The node's agent process: the one started with `--mode rpc
/// --session-dir <node-state>/sessions/…`. One session per test runs an
/// agent, so it is that session's.
#[cfg(not(target_os = "macos"))]
fn agent_pid(root: &Path) -> Option<i32> {
    let sessions = root.join("node-state/sessions");
    let sessions = sessions.to_str().unwrap();
    for entry in std::fs::read_dir("/proc").ok()?.flatten() {
        let Ok(pid) = entry.file_name().to_string_lossy().parse::<i32>() else {
            continue;
        };
        let Ok(raw) = std::fs::read(entry.path().join("cmdline")) else {
            continue;
        };
        let args: Vec<String> = raw
            .split(|byte| *byte == 0)
            .map(|arg| String::from_utf8_lossy(arg).into_owned())
            .collect();
        let named = args
            .windows(2)
            .any(|pair| pair[0] == "--session-dir" && pair[1].starts_with(sessions));
        if named && args.iter().any(|arg| arg == "rpc") {
            return Some(pid);
        }
    }
    None
}

// macOS has no /proc. Only match this fixture's private session path and
// the RPC agent arguments; never terminate an unrelated user process.
#[cfg(target_os = "macos")]
fn agent_pid(root: &Path) -> Option<i32> {
    let sessions = root.join("node-state/sessions");
    let output = std::process::Command::new("/bin/ps")
        .args(["-axo", "pid=,command="])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    for line in String::from_utf8_lossy(&output.stdout).lines() {
        let args: Vec<_> = line.split_whitespace().collect();
        if args
            .windows(2)
            .any(|pair| pair[0] == "--session-dir" && Path::new(pair[1]).starts_with(&sessions))
            && args.windows(2).any(|pair| pair == ["--mode", "rpc"])
        {
            return args.first()?.parse().ok();
        }
    }
    None
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn node_session_routes() {
    // The gateway lets a second user in; the node does not know them.
    let Some(cluster) = Cluster::start_with(GatewayOptions {
        env: vec![("PIRC_ALLOWED_USERS", format!("{USER},{STRANGER}"))],
        ..GatewayOptions::default()
    })
    .await
    else {
        return;
    };
    let api = cluster.api();
    let headers = browser_headers();
    let mut t = Transcript::new(cluster.volatile());
    let (mut session, created) = Session::create(&api).await;
    t.response(
        "first send",
        "POST /api/conversation-submissions/:id/dispatch",
        &created,
    );
    let base = session.base.clone();

    // Renaming (the gateway relays only `name`; pin and settle are its own).
    for (step, body) in [
        ("rename", json!({ "name": "  First name  " })),
        ("rename to blanks", json!({ "name": "   " })),
        ("rename to an empty name", json!({ "name": "" })),
        (
            "rename to 200 characters",
            json!({ "name": "n".repeat(200) }),
        ),
        (
            "rename to 201 characters",
            json!({ "name": "n".repeat(201) }),
        ),
        ("rename to a number", json!({ "name": 7 })),
        ("pin", json!({ "pinned": true })),
        (
            "rename and unpin",
            json!({ "name": "Second name", "pinned": false }),
        ),
        ("settle", json!({ "settled": true })),
        ("nothing to update", json!({})),
    ] {
        let answer = api.send("PATCH", &base, &headers, Some(body)).await;
        t.response(step, "PATCH /api/sessions/:id", &answer);
    }
    let listed = api.send("GET", "/api/sessions", &headers, None).await;
    t.note(
        "the listed session after the renames",
        listed.body["sessions"][0].clone(),
    );
    // Control leases.
    t.response(
        "control before anyone takes it",
        "GET /api/sessions/:id/control",
        &session.get("/control").await,
    );
    session.generation = json!(1);
    let command = session
        .command_with("no-lease", json!({ "type": "clear_queue" }))
        .await;
    t.response(
        "a command before taking control",
        "POST /api/sessions/:id/commands",
        &command,
    );
    let acquired = session.acquire().await;
    t.response(
        "acquire control (browser)",
        "POST /api/sessions/:id/control/acquire",
        &acquired,
    );
    t.response(
        "control while held",
        "GET /api/sessions/:id/control",
        &session.get("/control").await,
    );
    let again = session
        .post("/control/acquire", json!({ "clientId": "browser" }))
        .await;
    t.response(
        "the holder acquires again",
        "POST /api/sessions/:id/control/acquire",
        &again,
    );
    let first_generation = acquired.body["lease"]["generation"].clone();
    let current = again.body["lease"]["generation"].clone();
    for (step, body) in [
        ("another client acquires", json!({ "clientId": "phone" })),
        (
            "another client acquires with force: false",
            json!({ "clientId": "phone", "force": false }),
        ),
        ("an empty client id", json!({ "clientId": "" })),
        (
            "a 201-character client id",
            json!({ "clientId": "c".repeat(201) }),
        ),
        ("no client id", json!({})),
    ] {
        let answer = session.post("/control/acquire", body).await;
        t.response(step, "POST /api/sessions/:id/control/acquire", &answer);
    }
    for (step, body) in [
        (
            "heartbeat with the superseded generation",
            json!({ "clientId": "browser", "generation": first_generation }),
        ),
        (
            "heartbeat from another client",
            json!({ "clientId": "phone", "generation": current }),
        ),
        (
            "heartbeat without a generation",
            json!({ "clientId": "browser" }),
        ),
        (
            "heartbeat with generation 0",
            json!({ "clientId": "browser", "generation": 0 }),
        ),
        (
            "heartbeat",
            json!({ "clientId": "browser", "generation": current }),
        ),
    ] {
        let answer = session.post("/control/heartbeat", body).await;
        t.response(step, "POST /api/sessions/:id/control/heartbeat", &answer);
    }
    session.generation = current.clone();
    let stale = session
        .command_with("stale", json!({ "type": "set_thinking", "level": "high" }))
        .await;
    t.response(
        "the holder's command",
        "POST /api/sessions/:id/commands",
        &stale,
    );
    let forced = session
        .post(
            "/control/acquire",
            json!({ "clientId": "phone", "force": true }),
        )
        .await;
    t.response(
        "another client takes control with force",
        "POST /api/sessions/:id/control/acquire",
        &forced,
    );
    let command = session
        .command_with("after-force", json!({ "type": "clear_queue" }))
        .await;
    t.response(
        "a command from the client that lost control",
        "POST /api/sessions/:id/commands",
        &command,
    );
    let unauthorized = session
        .post(
            "/commands",
            json!({ "commandId": "no-generation", "clientId": "browser",
                "payload": { "type": "clear_queue" } }),
        )
        .await;
    t.response(
        "a command without a generation",
        "POST /api/sessions/:id/commands",
        &unauthorized,
    );
    let released = session
        .post(
            "/control/release",
            json!({ "clientId": "browser", "generation": current }),
        )
        .await;
    t.response(
        "the client that lost control releases",
        "POST /api/sessions/:id/control/release",
        &released,
    );
    let phone = forced.body["lease"]["generation"].clone();
    let released = session
        .post(
            "/control/release",
            json!({ "clientId": "phone", "generation": phone }),
        )
        .await;
    t.response(
        "the holder releases",
        "POST /api/sessions/:id/control/release",
        &released,
    );
    t.response(
        "control after release",
        "GET /api/sessions/:id/control",
        &session.get("/control").await,
    );
    let released = session
        .post(
            "/control/release",
            json!({ "clientId": "phone", "generation": phone }),
        )
        .await;
    t.response(
        "release again",
        "POST /api/sessions/:id/control/release",
        &released,
    );
    session.client = "phone".to_owned();
    session.generation = phone;
    let command = session
        .command_with("after-release", json!({ "type": "clear_queue" }))
        .await;
    t.response(
        "a command after release",
        "POST /api/sessions/:id/commands",
        &command,
    );
    let acquired = session.acquire().await;
    t.response(
        "acquire again after release",
        "POST /api/sessions/:id/control/acquire",
        &acquired,
    );
    let snapshot = session.snapshot().await;
    t.note(
        "the holder's command started an agent: the snapshot reports it",
        json!({ "runnerState": snapshot.body["session"]["runnerState"],
            "run": snapshot.body["run"], "agent": snapshot.body["agent"],
            "sandbox": snapshot.body["sandbox"] }),
    );
    for (step, path) in [
        (
            "unknown session control",
            "/api/sessions/session_missing/control",
        ),
        (
            "unknown session snapshot",
            "/api/sessions/session_missing/snapshot",
        ),
    ] {
        let answer = api.send("GET", path, &headers, None).await;
        t.response(step, &format!("GET {path}"), &answer);
    }
    let stranger: Vec<(&str, String)> = headers
        .iter()
        .map(|(name, value)| {
            let value = if *name == "x-pirc-user" {
                STRANGER.to_owned()
            } else {
                value.clone()
            };
            (*name, value)
        })
        .collect();
    let prepared = api
        .send(
            "POST",
            "/api/conversation-submissions/prepare",
            &stranger,
            Some(json!({ "operationId": "stranger-first", "submission": {
                "workspaceId": WORKSPACE_ID, "message": "Hello" } })),
        )
        .await;
    assert_eq!(prepared.status, 200, "{}", prepared.body);
    let refused = api
        .send(
            "POST",
            "/api/conversation-submissions/stranger-first/accept",
            &stranger,
            None,
        )
        .await;
    assert_eq!(refused.status, 403, "{}", refused.body);
    t.response(
        "a user the gateway allows but the node does not is refused by first-send",
        "POST /api/conversation-submissions/stranger-first/accept",
        &refused,
    );
    let foreign = api
        .send("GET", &format!("{base}/snapshot"), &stranger, None)
        .await;
    t.response(
        "that user reads this session",
        "GET /api/sessions/:id/snapshot",
        &foreign,
    );
    let deleted = api.send("DELETE", &base, &headers, None).await;
    t.response(
        "delete a directory conversation",
        "DELETE /api/sessions/:id",
        &deleted,
    );
    let missing = api
        .send("DELETE", "/api/sessions/session_missing", &headers, None)
        .await;
    t.response(
        "delete an unknown session",
        "DELETE /api/sessions/session_missing",
        &missing,
    );
    insta::assert_json_snapshot!("node_session_routes", t.into_value());
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn node_session_commands() {
    let llm = HeldLlm::start().await;
    let models = tempfile::tempdir().unwrap();
    let Some(cluster) = held_cluster(&llm, models.path(), GatewayOptions::default()).await else {
        return;
    };
    let api = cluster.api();
    let headers = browser_headers();
    let mut volatile = cluster.volatile();
    volatile.push((llm.base_url(), "<llm>"));
    let mut t = Transcript::new(volatile);
    let (mut s, _) = Session::create(&api).await;
    s.acquire().await;
    let snapshot = s.snapshot().await;
    t.note(
        "before any prompt: no runner, the settings the first agent will use",
        state(&snapshot.body),
    );
    let mut events = s.events().await;

    // A run held mid-reply.
    let first = Hold::new();
    let second = Hold::new();
    llm.push([
        Step::held(&first, Step::text("First answer.")),
        Step::held(&second, Step::text("Second answer.")),
    ]);
    let sent = s
        .command(json!({ "type": "prompt", "message": "p1" }))
        .await;
    t.response(
        "prompt (held mid-reply)",
        "POST /api/sessions/:id/commands",
        &sent,
    );
    let streamed = read_until(&mut events, |f| {
        agent_event(f, "message_update")
            && f["data"]["assistantMessageEvent"]["type"] == "text_delta"
    })
    .await;
    t.note("events until the first delta", briefs(&streamed));
    let snapshot = s.snapshot_until("the partial message", streaming).await;
    t.note("snapshot while the reply streams", state(&snapshot.body));
    let busy = s
        .command(json!({ "type": "prompt", "message": "p2" }))
        .await;
    t.response(
        "a second prompt while running",
        "POST /api/sessions/:id/commands",
        &busy,
    );
    let duplicate = s
        .command_with("c2", json!({ "type": "prompt", "message": "p2" }))
        .await;
    t.response(
        "the refused prompt's id again",
        "POST /api/sessions/:id/commands",
        &duplicate,
    );
    let steer = s.command(json!({ "type": "steer", "message": "s1" })).await;
    t.response("steer", "POST /api/sessions/:id/commands", &steer);
    let follow = s
        .command(json!({ "type": "follow_up", "message": "f1" }))
        .await;
    t.response("follow_up", "POST /api/sessions/:id/commands", &follow);
    let queued = read_until(&mut events, |f| {
        agent_event(f, "queue_update")
            && f["data"]["followUp"]
                .as_array()
                .is_some_and(|q| !q.is_empty())
    })
    .await;
    t.note("events for the queued messages", json!(queued));
    let snapshot = s
        .snapshot_until("both queues", |b| {
            b["queue"]["followUp"]
                .as_array()
                .is_some_and(|q| !q.is_empty())
        })
        .await;
    t.note("queue in the snapshot", snapshot.body["queue"].clone());

    for (step, payload) in [
        (
            "send_now with a negative index",
            json!({ "type": "send_now", "queue": "steering", "index": -1, "message": "s1" }),
        ),
        (
            "send_now with an unknown queue",
            json!({ "type": "send_now", "queue": "later", "index": 0, "message": "s1" }),
        ),
        (
            "send_now without a message",
            json!({ "type": "send_now", "queue": "steering", "index": 0 }),
        ),
        (
            "send_now for a message no longer queued",
            json!({ "type": "send_now", "queue": "steering", "index": 3, "message": "s1" }),
        ),
        (
            "send_now naming another text",
            json!({ "type": "send_now", "queue": "steering", "index": 0, "message": "other" }),
        ),
        ("an unknown command type", json!({ "type": "dance" })),
        ("an empty prompt", json!({ "type": "steer", "message": "" })),
    ] {
        let answer = s.command(payload).await;
        t.response(step, "POST /api/sessions/:id/commands", &answer);
    }
    let cleared = s.command(json!({ "type": "clear_queue" })).await;
    t.response("clear_queue", "POST /api/sessions/:id/commands", &cleared);
    let snapshot = s
        .snapshot_until("an empty queue", |b| {
            b["queue"] == json!({ "steering": [], "followUp": [] })
        })
        .await;
    t.note("queue after clear_queue", snapshot.body["queue"].clone());
    s.command(json!({ "type": "follow_up", "message": "f2" }))
        .await;
    s.command(json!({ "type": "steer", "message": "s2" })).await;
    s.snapshot_until("f2 and s2 queued", |b| {
        b["queue"] == json!({ "steering": ["s2"], "followUp": ["f2"] })
    })
    .await;
    let now = s
        .command(json!({ "type": "send_now", "queue": "followUp", "index": 0, "message": "f2" }))
        .await;
    t.response(
        "send_now the queued follow-up (interrupts the reply)",
        "POST /api/sessions/:id/commands",
        &now,
    );
    llm.wait_requests(2).await;
    first.release();
    let interrupted = read_until(&mut events, |f| {
        agent_event(f, "message_update")
            && f["data"]["assistantMessageEvent"]["type"] == "text_delta"
    })
    .await;
    t.note(
        "events from send_now until the next reply streams",
        briefs(&interrupted),
    );
    t.note(
        "the next model request carries the sent message first",
        conversation(&llm.requests()[1]),
    );
    let snapshot = s
        .snapshot_until("the second partial message", streaming)
        .await;
    t.note("snapshot during the second reply", state(&snapshot.body));

    // Stop: clears the queue, then aborts.
    s.command(json!({ "type": "follow_up", "message": "f3" }))
        .await;
    s.snapshot_until("f3 queued", |b| b["queue"]["followUp"] == json!(["f3"]))
        .await;
    let stopped = s.command(json!({ "type": "stop" })).await;
    t.response("stop", "POST /api/sessions/:id/commands", &stopped);
    let settled = read_until(&mut events, |f| agent_event(f, "agent_settled")).await;
    t.note("events until the stopped run settles", briefs(&settled));
    second.release();
    let snapshot = s
        .snapshot_until("the stopped run", |b| b["run"]["status"] != "running")
        .await;
    t.note("snapshot after stop", state(&snapshot.body));
    let idle = s.command(json!({ "type": "stop" })).await;
    t.response("stop while idle", "POST /api/sessions/:id/commands", &idle);
    let cleared = s.command(json!({ "type": "clear_queue" })).await;
    t.response(
        "clear_queue while idle",
        "POST /api/sessions/:id/commands",
        &cleared,
    );
    let now = s
        .command(json!({ "type": "send_now", "queue": "steering", "index": 0, "message": "x" }))
        .await;
    t.response(
        "send_now while idle and nothing queued",
        "POST /api/sessions/:id/commands",
        &now,
    );

    // Steering and a follow-up delivered in order after a held reply.
    let third = Hold::new();
    llm.push([
        Step::held(&third, Step::text("Third answer.")),
        Step::text("Steered."),
        Step::text("Followed."),
    ]);
    s.command(json!({ "type": "prompt", "message": "p3" }))
        .await;
    s.snapshot_until("the third partial message", streaming)
        .await;
    s.command(json!({ "type": "follow_up", "message": "f4" }))
        .await;
    s.command(json!({ "type": "steer", "message": "s4" })).await;
    s.snapshot_until("s4 and f4 queued", |b| {
        b["queue"] == json!({ "steering": ["s4"], "followUp": ["f4"] })
    })
    .await;
    third.release();
    let delivered = read_until(&mut events, |f| agent_event(f, "agent_settled")).await;
    t.note(
        "events from the queued prompt's run (steer, then follow-up)",
        briefs(&delivered),
    );
    let requests = llm.requests();
    t.note(
        "model requests of that run",
        json!(
            requests[requests.len() - 3..]
                .iter()
                .map(conversation)
                .collect::<Vec<_>>()
        ),
    );

    // Model and thinking level.
    for (step, payload) in [
        (
            "set_model to an unknown model",
            json!({ "type": "set_model", "provider": "fake", "modelId": "missing" }),
        ),
        (
            "set_model to an unknown provider",
            json!({ "type": "set_model", "provider": "nobody", "modelId": "fake-model" }),
        ),
        (
            "set_model without a model id",
            json!({ "type": "set_model", "provider": "fake" }),
        ),
        (
            "set_model",
            json!({ "type": "set_model", "provider": "fake", "modelId": "other-model" }),
        ),
        (
            "set_thinking to an unknown level",
            json!({ "type": "set_thinking", "level": "extreme" }),
        ),
        (
            "set_thinking",
            json!({ "type": "set_thinking", "level": "high" }),
        ),
    ] {
        let answer = s.command(payload).await;
        t.response(step, "POST /api/sessions/:id/commands", &answer);
    }
    let snapshot = s.snapshot().await;
    t.note(
        "model and thinking level of the live agent",
        snapshot.body["agent"].clone(),
    );

    // Command ids are idempotent per payload.
    let payload = json!({ "type": "set_thinking", "level": "medium" });
    let once = s.command_with("dup", payload.clone()).await;
    t.response("a command", "POST /api/sessions/:id/commands", &once);
    let twice = s.command_with("dup", payload).await;
    t.response(
        "the same id and payload",
        "POST /api/sessions/:id/commands",
        &twice,
    );
    let other = s
        .command_with("dup", json!({ "type": "set_thinking", "level": "low" }))
        .await;
    t.response(
        "the same id with another payload",
        "POST /api/sessions/:id/commands",
        &other,
    );
    let reordered = s
        .command_with("dup", json!({ "level": "medium", "type": "set_thinking" }))
        .await;
    t.response(
        "the same id and payload with keys reordered",
        "POST /api/sessions/:id/commands",
        &reordered,
    );
    s.command(json!({ "type": "set_thinking", "level": "high" }))
        .await;

    // A rename reaches the live agent.
    let renamed = api
        .send(
            "PATCH",
            &s.base,
            &headers,
            Some(json!({ "name": "Live rename" })),
        )
        .await;
    // Only the name: the gateway's `unread` and `runStatus` follow the
    // node's activity reports, coalesced on a timer.
    let session = &renamed.body["session"];
    t.note(
        "rename with a live agent (PATCH /api/sessions/:id)",
        json!({ "status": renamed.status, "name": session["name"],
            "nameSource": session["nameSource"] }),
    );
    let frames = read_until(&mut events, |f| f["type"] == "session_renamed").await;
    t.note("the rename's events", json!(frames));

    // The runner dies mid-run: no runner is live for the snapshot.
    let fourth = Hold::new();
    llm.push([Step::held(&fourth, Step::text("Never finished."))]);
    let before = llm.requests().len();
    s.command(json!({ "type": "prompt", "message": "p4" }))
        .await;
    llm.wait_requests(before + 1).await;
    s.snapshot_until("the fourth partial message", streaming)
        .await;
    let root = cluster.dir.path().canonicalize().unwrap();
    let pid = poll("the agent process", || async { agent_pid(&root) }).await;
    kill(Pid::from_raw(pid), Signal::SIGKILL).unwrap();
    let exited = read_until(&mut events, |f| f["type"] == "runner_exit").await;
    t.note(
        "events when the agent is killed",
        json!(
            exited
                .iter()
                .map(|f| if f["type"] == "runner_exit" {
                    f["data"].clone()
                } else {
                    brief(f)
                })
                .collect::<Vec<_>>()
        ),
    );
    fourth.release();
    let snapshot = s
        .snapshot_until("no live runner", |b| {
            b["session"]["runnerState"] == "failed"
        })
        .await;
    t.note(
        "snapshot without a runner: history from the session file, settings the next agent will use",
        state(&snapshot.body),
    );
    let epoch = snapshot.body["watermark"]["epoch"].clone();

    // The next prompt starts another runner that continues the transcript.
    llm.push([Step::text("Back again.")]);
    let sent = s
        .command(json!({ "type": "prompt", "message": "p5" }))
        .await;
    t.response(
        "prompt after the runner died",
        "POST /api/sessions/:id/commands",
        &sent,
    );
    let resumed = read_until(&mut events, |f| agent_event(f, "agent_settled")).await;
    t.note("events of the next runner's run", briefs(&resumed));
    t.note(
        "its model request continues the transcript",
        conversation(llm.requests().last().unwrap()),
    );
    let snapshot = s.snapshot().await;
    t.note(
        "the snapshot after it",
        json!({ "state": state(&snapshot.body),
            "watermark epoch changed": snapshot.body["watermark"]["epoch"] != epoch }),
    );
    events.close().await;
    insta::assert_json_snapshot!("node_session_commands", t.into_value());
}

/// Each assistant message's outcome and each retry event, in order.
fn outcomes(frames: &[Value]) -> Value {
    json!(
        frames
            .iter()
            .filter_map(|f| {
                if agent_event(f, "message_end") && f["data"]["message"]["role"] == "assistant" {
                    let message = &f["data"]["message"];
                    Some(json!({ "assistant": { "stopReason": message["stopReason"],
                        "errorMessage": message["errorMessage"], "content": message["content"] } }))
                } else if agent_event(f, "auto_retry_start") || agent_event(f, "auto_retry_end") {
                    Some(f["data"].clone())
                } else {
                    None
                }
            })
            .collect::<Vec<_>>()
    )
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn node_session_failures() {
    let llm = HeldLlm::start().await;
    let models = tempfile::tempdir().unwrap();
    let Some(cluster) = held_cluster(&llm, models.path(), GatewayOptions::default()).await else {
        return;
    };
    let api = cluster.api();
    let mut volatile = cluster.volatile();
    volatile.push((llm.base_url(), "<llm>"));
    let mut t = Transcript::new(volatile);
    let (mut s, _) = Session::create(&api).await;
    s.acquire().await;
    let mut events = s.events().await;

    // The gateway reports provider errors generically (upstream bodies may
    // hold secrets), without the HTTP status: an overloaded 503 is not one
    // the agent retries, and the run fails with that message.
    llm.push([Step::Status(503, "overloaded".to_owned())]);
    let sent = s
        .command(json!({ "type": "prompt", "message": "hello" }))
        .await;
    t.response("prompt", "POST /api/sessions/:id/commands", &sent);
    let failed = read_until(&mut events, |f| agent_event(f, "agent_settled")).await;
    t.note("events of the failing run", briefs(&failed));
    t.note(
        "assistant messages and retries of the failing run",
        outcomes(&failed),
    );
    let snapshot = s.snapshot().await;
    t.note("snapshot after the failed run", state(&snapshot.body));

    // A body that reads as a rate limit is retried (after the agent's first
    // 2 s delay), and the run recovers: it does not stay failed.
    llm.push([
        Step::Status(400, r#"{"error":{"message":"quota exhausted"}}"#.to_owned()),
        Step::text("Recovered."),
    ]);
    let sent = s
        .command(json!({ "type": "prompt", "message": "again" }))
        .await;
    t.response("prompt", "POST /api/sessions/:id/commands", &sent);
    let retried = read_until(&mut events, |f| agent_event(f, "agent_settled")).await;
    t.note("events of the retried run", briefs(&retried));
    t.note(
        "assistant messages and retries of the retried run",
        outcomes(&retried),
    );
    let snapshot = s.snapshot().await;
    t.note("snapshot after the recovered run", state(&snapshot.body));
    t.note("model requests", json!(llm.requests().len()));
    events.close().await;
    insta::assert_json_snapshot!("node_session_failures", t.into_value());
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn node_session_interactions() {
    let llm = HeldLlm::start().await;
    let models = tempfile::tempdir().unwrap();
    let Some(cluster) = held_cluster(&llm, models.path(), GatewayOptions::default()).await else {
        return;
    };
    let api = cluster.api();
    let mut volatile = cluster.volatile();
    volatile.push((llm.base_url(), "<llm>"));
    let mut t = Transcript::new(volatile);
    let (mut s, _) = Session::create(&api).await;
    s.acquire().await;
    let mut events = s.events().await;
    let control =
        |s: &Session| json!({ "clientId": s.client.clone(), "generation": s.generation.clone() });
    let with = |s: &Session, answer: Value| {
        let mut body = control(s);
        body["answer"] = answer;
        body
    };

    let none = s
        .post_answer(
            "interaction_missing",
            with(&s, json!({ "cancelled": true })),
        )
        .await;
    t.response(
        "answer before any agent runs",
        "POST /api/sessions/:id/interactions/interaction_missing/answer",
        &none,
    );

    llm.push([
        Step::ptc(
            "q",
            "ask_user_question",
            json!({ "questions": [{ "question": "Color?", "multiSelect": true,
                "options": [{ "label": "red" }, { "label": "blue" }] }] }),
        ),
        Step::text("Noted."),
        Step::ptc(
            "q2",
            "ask_user_question",
            json!({ "questions": [{ "question": "Name?" }] }),
        ),
        Step::ptc(
            "q3",
            "ask_user_question",
            json!({ "questions": [{ "question": "Size?", "options": [{ "label": "S" },
                { "label": "L" }] }] }),
        ),
        Step::text("Cancelled, fine."),
    ]);
    let sent = s
        .command(json!({ "type": "prompt", "message": "ask" }))
        .await;
    t.response("prompt", "POST /api/sessions/:id/commands", &sent);
    let opened = read_until(&mut events, |f| f["type"] == "interaction_created").await;
    t.note("events until the dialog opens", briefs(&opened));
    let mut created = opened.last().unwrap()["data"].clone();
    mask_times(&mut created);
    t.note("interaction_created", created);
    let snapshot = s.snapshot().await;
    t.note("snapshot with the dialog open", state(&snapshot.body));
    let interaction = snapshot.body["interactions"][0]["id"]
        .as_str()
        .unwrap()
        .to_owned();

    for (step, id, body) in [
        (
            "answer an unknown interaction",
            "interaction_missing".to_owned(),
            with(&s, json!({ "value": "red" })),
        ),
        (
            "answer with an invalid answer",
            interaction.clone(),
            with(&s, json!({ "value": 7 })),
        ),
        ("answer without an answer", interaction.clone(), control(&s)),
        (
            "answer without a generation",
            interaction.clone(),
            json!({ "clientId": s.client.clone(),
                "answer": { "value": "red, blue", "values": ["red", "blue"] } }),
        ),
        (
            "answer again with a stale generation",
            interaction.clone(),
            json!({ "clientId": s.client.clone(), "generation": 99,
                "answer": { "value": "red" } }),
        ),
        (
            "answer twice",
            interaction.clone(),
            with(&s, json!({ "value": "red" })),
        ),
    ] {
        let answered = s.post_answer(&id, body).await;
        t.response(
            step,
            "POST /api/sessions/:id/interactions/:interactionId/answer",
            &answered,
        );
    }
    let settled = read_until(&mut events, |f| agent_event(f, "agent_settled")).await;
    t.note("events after the answer", briefs(&settled));
    t.note(
        "interaction_answered",
        json!(
            settled
                .iter()
                .filter(|f| f["type"] == "interaction_answered")
                .map(|f| f["data"].clone())
                .collect::<Vec<_>>()
        ),
    );
    let snapshot = s.snapshot().await;
    let result = snapshot.body["history"]
        .as_array()
        .unwrap()
        .iter()
        .find(|m| m["role"] == "toolResult" && m["toolName"] == "ptc")
        .cloned()
        .unwrap_or_default();
    let mut result = json!({ "content": result["content"], "isError": result["isError"],
        "toolCallId": result["toolCallId"] });
    mask_times(&mut result);
    t.note("the question tool's result in history", result);
    let again = s
        .post_answer(&interaction, with(&s, json!({ "value": "red" })))
        .await;
    t.response(
        "answer after the run settled",
        "POST /api/sessions/:id/interactions/:interactionId/answer",
        &again,
    );

    // A dialog withdrawn by stop.
    s.command(json!({ "type": "prompt", "message": "ask again" }))
        .await;
    let opened = read_until(&mut events, |f| f["type"] == "interaction_created").await;
    t.note("events until the second dialog opens", briefs(&opened));
    let second = opened.last().unwrap()["data"]["id"]
        .as_str()
        .unwrap_or_default()
        .to_owned();
    let stopped = s.command(json!({ "type": "stop" })).await;
    t.response(
        "stop with the dialog open",
        "POST /api/sessions/:id/commands",
        &stopped,
    );
    let settled = read_until(&mut events, |f| agent_event(f, "agent_settled")).await;
    t.note("events after stop", briefs(&settled));
    t.note(
        "interaction_answered on stop",
        json!(
            settled
                .iter()
                .filter(|f| f["type"] == "interaction_answered")
                .map(|f| f["data"].clone())
                .collect::<Vec<_>>()
        ),
    );
    let snapshot = s.snapshot().await;
    t.note(
        "interactions after stop",
        snapshot.body["interactions"].clone(),
    );
    let late = s
        .post_answer(&second, with(&s, json!({ "value": "Ann" })))
        .await;
    t.response(
        "answer the withdrawn dialog",
        "POST /api/sessions/:id/interactions/:interactionId/answer",
        &late,
    );

    // A dialog the user cancels.
    s.command(json!({ "type": "prompt", "message": "ask a third time" }))
        .await;
    let opened = read_until(&mut events, |f| f["type"] == "interaction_created").await;
    let third = opened.last().unwrap()["data"]["id"]
        .as_str()
        .unwrap_or_default()
        .to_owned();
    let cancelled = s
        .post_answer(&third, with(&s, json!({ "cancelled": true })))
        .await;
    t.response(
        "cancel the dialog",
        "POST /api/sessions/:id/interactions/:interactionId/answer",
        &cancelled,
    );
    let settled = read_until(&mut events, |f| agent_event(f, "agent_settled")).await;
    t.note("events after cancelling", briefs(&settled));
    let snapshot = s.snapshot().await;
    let result = snapshot.body["history"]
        .as_array()
        .unwrap()
        .iter()
        .rev()
        .find(|m| m["role"] == "toolResult" && m["toolName"] == "ptc")
        .cloned()
        .unwrap_or_default();
    let mut result = json!({ "content": result["content"], "isError": result["isError"],
        "toolCallId": result["toolCallId"] });
    mask_times(&mut result);
    t.note("the cancelled question's result", result);
    events.close().await;
    insta::assert_json_snapshot!("node_session_interactions", t.into_value());
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn node_session_interaction_answer_race_across_devices() {
    let llm = HeldLlm::start().await;
    let models = tempfile::tempdir().unwrap();
    let Some(cluster) = held_cluster(&llm, models.path(), GatewayOptions::default()).await else {
        return;
    };
    let api = cluster.api();
    let (mut browser, _) = Session::create(&api).await;
    assert_eq!(browser.acquire().await.status, 200);
    let mut events = browser.events().await;

    llm.push([
        Step::ptc(
            "question",
            "ask_user_question",
            json!({ "questions": [{ "question": "Continue?" }] }),
        ),
        Step::text("Completed."),
    ]);
    assert_eq!(
        browser
            .command(json!({ "type": "prompt", "message": "ask" }))
            .await
            .status,
        202
    );
    let opened = read_until(&mut events, |frame| frame["type"] == "interaction_created").await;
    let row = &opened.last().expect("question event")["data"];
    let interaction_id = row["id"].as_str().expect("interaction id").to_owned();
    let interaction_epoch = row["runnerEpoch"].clone();

    // A second device takes the lease while the original browser still has
    // the old question open. Both clients submit at once with their own lease.
    let phone_lease = browser
        .post(
            "/control/acquire",
            json!({ "clientId": "phone", "force": true }),
        )
        .await;
    assert_eq!(phone_lease.status, 200);
    let phone_generation = phone_lease.body["lease"]["generation"].clone();
    let answer_path = format!("{}/interactions/{interaction_id}/answer", browser.base);
    let browser_body = json!({
        "clientId": browser.client,
        "answer": { "value": "yes" },
    });
    let phone_body = json!({
        "clientId": "phone",
        "answer": { "value": "yes" },
    });
    let headers = browser_headers();
    let (browser_answer, phone_answer) = tokio::join!(
        api.send("POST", &answer_path, &headers, Some(browser_body)),
        api.send("POST", &answer_path, &headers, Some(phone_body)),
    );

    // Either device may answer without holding control; the first answer is
    // kept and the other is refused because the question is no longer open.
    let answers = [&browser_answer, &phone_answer];
    assert_eq!(
        answers.iter().filter(|answer| answer.status == 200).count(),
        1,
        "browser: {:?}, phone: {:?}",
        browser_answer.body,
        phone_answer.body
    );
    let rejected = answers
        .iter()
        .find(|answer| answer.status == 409)
        .expect("one answer is refused");
    assert_eq!(rejected.body["error"]["code"], "stale_interaction");
    let winner = if browser_answer.status == 200 {
        browser.client.clone()
    } else {
        "phone".to_owned()
    };
    let settled = read_until(&mut events, |frame| agent_event(frame, "agent_settled")).await;
    let answered = settled
        .iter()
        .filter(|frame| frame["type"] == "interaction_answered")
        .collect::<Vec<_>>();
    assert_eq!(answered.len(), 1, "settled frames: {settled:?}");
    assert_eq!(answered[0]["data"]["interactionId"], interaction_id);
    assert_eq!(answered[0]["data"]["interactionEpoch"], interaction_epoch);
    assert_eq!(answered[0]["data"]["status"], "answered");
    assert_eq!(answered[0]["data"]["answeredBy"], winner);
    assert!(answered[0]["data"]["resolvedAt"].is_number());

    // Two tabs that share the current lease can still race to answer a
    // question. The interaction row claim is single-use even when both HTTP
    // requests carry identical, otherwise-valid control credentials.
    browser.client = "phone".to_owned();
    browser.generation = phone_generation.clone();
    llm.push([
        Step::ptc(
            "question-2",
            "ask_user_question",
            json!({ "questions": [{ "question": "Continue again?" }] }),
        ),
        Step::text("Completed again."),
    ]);
    assert_eq!(
        browser
            .command_with(
                "phone-prompt-2",
                json!({ "type": "prompt", "message": "ask again" }),
            )
            .await
            .status,
        202
    );
    let second_opened =
        read_until(&mut events, |frame| frame["type"] == "interaction_created").await;
    let second_row = &second_opened.last().expect("second question event")["data"];
    let second_id = second_row["id"].as_str().expect("second interaction id");
    let second_epoch = second_row["runnerEpoch"].clone();
    let second_path = format!("{}/interactions/{second_id}/answer", browser.base);
    let duplicate_body = json!({
        "clientId": browser.client,
        "answer": { "value": "yes" },
    });
    let (first_duplicate, second_duplicate) = tokio::join!(
        api.send("POST", &second_path, &headers, Some(duplicate_body.clone())),
        api.send("POST", &second_path, &headers, Some(duplicate_body)),
    );
    let responses = [&first_duplicate, &second_duplicate];
    assert_eq!(
        responses
            .iter()
            .filter(|response| response.status == 200)
            .count(),
        1
    );
    assert_eq!(
        responses
            .iter()
            .filter(|response| response.status == 409)
            .count(),
        1
    );
    let rejected = responses
        .iter()
        .find(|response| response.status == 409)
        .unwrap();
    assert_eq!(rejected.body["error"]["code"], "stale_interaction");
    let second_settled = read_until(&mut events, |frame| agent_event(frame, "agent_settled")).await;
    let second_answered = second_settled
        .iter()
        .filter(|frame| frame["type"] == "interaction_answered")
        .collect::<Vec<_>>();
    assert_eq!(
        second_answered.len(),
        1,
        "settled frames: {second_settled:?}"
    );
    assert_eq!(second_answered[0]["data"]["interactionId"], second_id);
    assert_eq!(second_answered[0]["data"]["interactionEpoch"], second_epoch);
    assert_eq!(second_answered[0]["data"]["status"], "answered");
    assert_eq!(second_answered[0]["data"]["answeredBy"], "phone");
    assert!(second_answered[0]["data"]["resolvedAt"].is_number());
    events.close().await;
}
