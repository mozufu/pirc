//! The node's half of the node link and its side channels, with the test
//! playing the gateway (`apps/gateway/src/node/runtime.ts`,
//! `agent-gateway.ts`, `inference.ts`, `memory-mirror.ts`, `runner.ts`,
//! `write-broker.ts`): what the node ignores, closes and drops; reconnecting
//! and registering again; `models` frames; relayed requests the router
//! refuses; `activity` with runs and write leases; the agent's
//! `agent_request`s; inference errors and cancellation; and the workspace
//! memory mirror with its acknowledgements.

mod node_link_side_support;

use std::fs;
use std::path::Path;
use std::time::{Duration, Instant};

use node_link_side_support::{
    Gateway, activity_of, last_message, models, provider_entry, registered, settled_in,
    sorted_keys, without_details,
};
use pirc_conformance::{FakeGateway, LoneNode, NodeOptions, Transcript, USER};
use serde_json::{Value, json};

/// The relayed `response` frames among `frames`, by request id.
fn response_ids(frames: &[Value]) -> Vec<Value> {
    frames
        .iter()
        .filter(|frame| frame["type"] == "response")
        .map(|frame| frame["requestId"].clone())
        .collect()
}

/// The random fence id of the agent's web results.
fn mask_web_results(value: Value) -> Value {
    let fence = regex::Regex::new(r"WEB_RESULTS id=[0-9a-f]{12}").unwrap();
    serde_json::from_str(&fence.replace_all(&value.to_string(), "WEB_RESULTS id=<fence>")).unwrap()
}

/// The model the agent asked for, and its thinking level.
fn model_of(start: &Value) -> Value {
    let request = &start["request"];
    json!({ "providerName": request["providerName"], "modelId": request["modelId"],
        "thinking": request["thinking"] })
}

/// A 1×1 PNG.
const PNG: &str = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";

#[tokio::test(flavor = "multi_thread")]
async fn node_link_side_link() {
    let server = FakeGateway::bind().await;
    let Some(node) = LoneNode::start(server.port()) else {
        return;
    };
    let mut t = Transcript::new(node.volatile());
    let mut gw = Gateway::new(server.accept().await);
    let register = gw.link.recv().await;

    // Before `registered`, requests are dropped, and a registration error
    // only gets logged: the link stays open.
    let early = json!({ "method": "GET", "url": "/api/workspaces/test/project-config",
        "user": USER });
    gw.link
        .send(&json!({ "type": "request", "requestId": "early-1", "data": early }))
        .await;
    gw.link
        .send(
            &json!({ "type": "registration_error", "status": 409, "code": "conflict",
            "message": "Another node holds this id" }),
        )
        .await;
    gw.link
        .send(&json!({ "type": "request", "requestId": "early-2", "data": early }))
        .await;
    gw.link
        .send(&registered(models("fake", "fake-model", "low"), json!({})))
        .await;
    let first = gw.link.recv().await;
    t.note(
        "after registered, the node first sends its activity (no sessions yet)",
        first,
    );
    let listed = gw
        .ask("GET", "/api/workspaces/test/project-config", None)
        .await;
    t.note(
        "a request after registered is answered",
        listed["data"].clone(),
    );

    // Frames the link schema refuses, and unknown frames, are ignored.
    for raw in [
        json!({ "type": "no_such_frame" }),
        json!({ "type": "request", "requestId": "no-data" }),
        json!({ "type": "request", "requestId": "not-api",
            "data": { "method": "GET", "url": "/health", "user": USER } }),
        json!({ "type": "request", "requestId": "bad-method",
            "data": { "method": "HEAD", "url": "/api/sessions", "user": USER } }),
        json!({ "type": "request", "requestId": "no-user",
            "data": { "method": "GET", "url": "/api/sessions", "user": "" } }),
        json!({ "type": "agent_response", "requestId": "unknown", "status": 200 }),
        json!({ "type": "memory_mirror_ack", "ledgerKey": "not-a-key", "watermark": -1 }),
        json!({ "type": "model_end", "requestId": "unknown", "message": {} }),
        json!([1, 2, 3]),
        json!("text"),
    ] {
        gw.link.send_raw(&raw.to_string()).await;
    }
    // Unknown envelope keys are stripped, not refused.
    gw.link
        .send_raw(
            &json!({ "type": "request", "requestId": "extra-keys", "extra": true,
                "data": { "method": "GET", "url": "/api/workspaces/test/project-config",
                    "user": USER, "extra": true } })
            .to_string(),
        )
        .await;
    let extra = gw
        .wait(|frame| frame["type"] == "response" && frame["requestId"] == "extra-keys")
        .await;
    t.note(
        "a request with unknown keys is answered",
        extra["data"].clone(),
    );

    // Relayed requests the node's router refuses or answers unusually.
    let (session, _) = gw.session().await;
    let uploads = format!("/api/sessions/{session}/uploads");
    let mut relayed = Vec::new();
    for (what, data) in [
        (
            "an image upload (bodyBase64 and contentType)",
            json!({ "method": "POST", "url": uploads, "user": USER, "bodyBase64": PNG,
                "contentType": "image/png" }),
        ),
        (
            "an image upload without a content type (application/octet-stream)",
            json!({ "method": "POST", "url": uploads, "user": USER, "bodyBase64": PNG }),
        ),
        (
            "an image declared as another image type",
            json!({ "method": "POST", "url": uploads, "user": USER, "bodyBase64": PNG,
                "contentType": "image/jpeg" }),
        ),
        (
            "a generic file upload",
            json!({ "method": "POST", "url": format!("{uploads}?filename=dir%2Fnotes.txt"),
                "user": USER, "bodyBase64": "aGVsbG8K", "contentType": "text/plain" }),
        ),
        (
            "a generic file without a filename",
            json!({ "method": "POST", "url": uploads, "user": USER,
                "bodyBase64": "aGVsbG8K", "contentType": "text/plain" }),
        ),
        (
            "an empty upload",
            json!({ "method": "POST", "url": uploads, "user": USER, "bodyBase64": "",
                "contentType": "image/png" }),
        ),
        (
            "an upload as a JSON payload",
            json!({ "method": "POST", "url": uploads, "user": USER,
                "payload": { "data": PNG } }),
        ),
        (
            "an unknown route",
            json!({ "method": "GET", "url": "/api/nope", "user": USER }),
        ),
        (
            "an unknown method on a known path",
            json!({ "method": "PUT", "url": "/api/sessions", "user": USER, "payload": {} }),
        ),
        (
            "a user the node does not allow",
            json!({ "method": "GET", "url": "/api/sessions", "user": "mallory@example.com" }),
        ),
        (
            "a user the node does not allow, on an unknown route",
            json!({ "method": "GET", "url": "/api/nope", "user": "mallory@example.com" }),
        ),
        (
            "a JSON body that does not parse",
            json!({ "method": "POST", "url": "/api/sessions", "user": USER,
                "bodyBase64": "eyJ3b3Jrc3BhY2VJZCI6", "contentType": "application/json" }),
        ),
        (
            "an empty JSON body",
            json!({ "method": "POST", "url": "/api/sessions", "user": USER,
                "bodyBase64": "", "contentType": "application/json" }),
        ),
        (
            "a JSON body as bodyBase64",
            json!({ "method": "POST", "url": "/api/sessions", "user": USER,
                "bodyBase64": "eyJ3b3Jrc3BhY2VJZCI6ICJub3BlIn0=",
                "contentType": "application/json" }),
        ),
        (
            "no payload where a body is required",
            json!({ "method": "POST", "url": "/api/sessions", "user": USER }),
        ),
        (
            "an unknown session",
            json!({ "method": "GET", "url": "/api/sessions/session_nope/snapshot",
                "user": USER }),
        ),
    ] {
        let exchanged = gw.exchange(data).await;
        relayed.push(json!({ "case": what, "exchange": exchanged }));
    }
    t.note("relayed requests", json!(relayed));
    t.note(
        "requests sent before registered, or refused by the link schema, never got an answer",
        json!(response_ids(&gw.link.skipped)),
    );

    // Invalid JSON closes the link (1007); the node connects again after
    // about 3 s and registers again.
    gw.link.send_raw("{not json").await;
    let closed_at = Instant::now();
    let closed = gw.link.closed().await;
    t.note(
        "invalid JSON: the node closes the link",
        json!({ "close": closed.map(|(code, reason)| json!({ "code": code, "reason": reason })) }),
    );
    let mut gw = Gateway::new(server.accept().await);
    let again = gw.link.recv().await;
    t.note(
        "the node connects again and registers",
        json!({
            "not before 2.5 s": closed_at.elapsed() >= Duration::from_millis(2500),
            "register is the same as before": again == register,
            "type": again["type"],
        }),
    );

    // A second `registered` with another catalog: new agents use it.
    gw.link
        .send(&registered(
            models("second", "second-model", "high"),
            json!({}),
        ))
        .await;
    let first = gw.link.recv().await;
    t.note(
        "after registering again, the activity (the earlier session has no run)",
        first,
    );
    let (second, generation) = gw.session().await;
    gw.prompt(&second, &generation, "command-1", "Hello").await;
    let start = gw.model_start().await;
    t.note(
        "a new session's model request uses the catalog of the second registered",
        model_of(&start),
    );
    gw.reply_text(&start, "Hello.").await;
    gw.wait(settled_in(&second)).await;

    // A `models` frame replaces the catalog for new agents.
    let mut third = models("third", "third-model", "medium");
    third["providers"]["second"] = provider_entry("second-model");
    gw.link
        .send(&json!({ "type": "models", "models": third }))
        .await;
    let (other, other_generation) = gw.session().await;
    let reused = gw
        .prompt(&other, &other_generation, "command-1", "Hello")
        .await;
    t.note(
        "command ids are the node's, not the session's: reusing one in another session",
        reused["data"].clone(),
    );
    gw.prompt(&other, &other_generation, "command-2", "Hello")
        .await;
    let start = gw.model_start().await;
    t.note(
        "after a models frame, a new session's model request uses the new default",
        model_of(&start),
    );
    gw.reply_text(&start, "Hello.").await;
    gw.wait(settled_in(&other)).await;
    gw.prompt(&second, &generation, "command-3", "Again").await;
    let start = gw.model_start().await;
    t.note(
        "the earlier session's running agent keeps its model",
        model_of(&start),
    );
    gw.reply_text(&start, "Again.").await;
    gw.wait(settled_in(&second)).await;

    // The gateway closes the link: the node connects again.
    gw.link.close(1001, "gateway restarting").await;
    let closed_at = Instant::now();
    let mut gw = Gateway::new(server.accept().await);
    let again = gw.link.recv().await;
    t.note(
        "the gateway closes the link: the node connects again and registers",
        json!({
            "not before 2.5 s": closed_at.elapsed() >= Duration::from_millis(2500),
            "type": again["type"],
            "workspaces": again["workspaces"],
        }),
    );
    insta::assert_json_snapshot!("node_link_side_link", t.into_value());
}

/// The `pi_event` data of `frames` in `session`.
fn pi_events<'a>(frames: &'a [Value], session: &'a str) -> impl Iterator<Item = &'a Value> {
    frames
        .iter()
        .filter(move |frame| {
            frame["type"] == "event"
                && frame["sessionId"] == session
                && frame["event"]["type"] == "pi_event"
        })
        .map(|frame| &frame["event"]["data"])
}

/// The last assistant message the agent reported in `session`.
fn final_message(frames: &[Value], session: &str) -> Value {
    pi_events(frames, session)
        .filter(|data| data["type"] == "message_end" && data["message"]["role"] == "assistant")
        .last()
        .map(|data| data["message"].clone())
        .unwrap_or(Value::Null)
}

/// The kinds of node events (`type`, and a `pi_event`'s own type) in `session`.
fn event_kinds(frames: &[Value], session: &str) -> Vec<String> {
    frames
        .iter()
        .filter(|frame| frame["type"] == "event" && frame["sessionId"] == session)
        .map(|frame| {
            let event = &frame["event"];
            match event["type"].as_str() {
                Some("pi_event") => {
                    format!("pi_event {}", event["data"]["type"].as_str().unwrap_or("?"))
                }
                Some(other) => other.to_owned(),
                None => "?".to_owned(),
            }
        })
        .collect()
}

/// The report's "N bytes scanned", which depends on the run directory's
/// path (the session files hold it).
fn scanned_bytes(text: &str) -> String {
    let Some(end) = text.find(" bytes scanned") else {
        return text.to_owned();
    };
    let start = text[..end]
        .rfind(|c: char| !(c.is_ascii_digit() || c == ','))
        .map_or(0, |i| i + 1);
    format!("{}<bytes>{}", &text[..start], &text[end..])
}

/// A recap's model request: its one message is JSON with the evidence the
/// node collected. Entry ids are random, and the order of entries and
/// sessions follows timestamps that can tie, so both are sorted here.
fn recap_request(start: &Value) -> Value {
    let request = &start["request"];
    let messages = request["messages"].as_array().cloned().unwrap_or_default();
    let mut last = messages.last().cloned().unwrap_or(Value::Null);
    if let Some(content) = last["content"].as_str()
        && let Ok(mut parsed) = serde_json::from_str::<Value>(content)
    {
        // The session files hold the run directory's path.
        if parsed["evidence"]["scannedBytes"].is_number() {
            parsed["evidence"]["scannedBytes"] = json!("<depends on the run directory>");
        }
        if let Some(sessions) = parsed["evidence"]["sessions"].as_array_mut() {
            for session in sessions.iter_mut() {
                if let Some(entries) = session["evidence"].as_array_mut() {
                    for entry in entries.iter_mut() {
                        entry["entryId"] = json!("<entry>");
                    }
                    entries.sort_by_key(|entry| entry.to_string());
                }
            }
            sessions.sort_by_key(|session| session["evidence"].to_string());
        }
        last["content"] = parsed;
    }
    let tools: Vec<&Value> = request["tools"]
        .as_array()
        .map(|tools| tools.iter().map(|tool| &tool["name"]).collect())
        .unwrap_or_default();
    json!({ "message count": messages.len(), "last message": last, "tools": tools,
        "toolChoice": request["toolChoice"] })
}

#[tokio::test(flavor = "multi_thread")]
async fn node_link_side_runs() {
    let server = FakeGateway::bind().await;
    // This transcript checks run events, not the platform-specific warning
    // about srt's shared /tmp. Keep its temp parent in the fixture's private
    // /var/tmp root so macOS and Linux exercise the same warning-free layout.
    let Some(node) = LoneNode::start_with(
        server.port(),
        NodeOptions {
            env: vec![("TMPDIR", "{run_dir}".into())],
            ..Default::default()
        },
    ) else {
        return;
    };
    let mut t = Transcript::new(node.volatile());
    let mut gw = Gateway::new(server.accept().await);
    gw.link.recv().await;
    gw.link
        .send(&registered(models("fake", "fake-model", "low"), json!({})))
        .await;
    gw.wait(|frame| frame["type"] == "activity").await;

    // A run that writes: its open run, then its write lease, in `activity`
    // (coalesced on a 100 ms timer: frames in between are not recorded).
    let (writer, writer_generation) = gw.session().await;
    gw.prompt(&writer, &writer_generation, "writer-1", "Write notes")
        .await;
    let start = gw.model_start().await;
    t.note(
        "model_start: a request id the node chose",
        json!({ "requestId": start["requestId"], "keys": sorted_keys(&start) }),
    );
    let running = gw
        .take(|frame| activity_of(frame, &writer).is_some_and(|entry| entry["run"] == "running"))
        .await;
    t.note("activity: the run is open", running);
    gw.reply_tool(
        &start,
        "w1",
        "write",
        json!({ "path": "notes.txt", "content": "noted\n" }),
    )
    .await;
    let start = gw.model_start().await;
    t.note("the write's result", last_message(&start));
    let leased = gw
        .take(|frame| activity_of(frame, &writer).is_some_and(|entry| entry["writeLease"] == true))
        .await;
    t.note("activity: the run holds a write lease", leased);

    // Another session cannot write where the first one holds its lease.
    let (other, other_generation) = gw.session().await;
    gw.prompt(&other, &other_generation, "other-1", "Write notes too")
        .await;
    let other_start = gw.model_start().await;
    let both = gw
        .take(|frame| {
            activity_of(frame, &other).is_some_and(|entry| entry["run"] == "running")
                && activity_of(frame, &writer).is_some_and(|entry| entry["writeLease"] == true)
        })
        .await;
    // The entries' order is not stable (nor part of the contract).
    t.note(
        "activity: both runs open, one lease",
        json!({ "sessions": both["sessions"].as_array().map(Vec::len),
            "writer": activity_of(&both, &writer), "other": activity_of(&both, &other) }),
    );
    gw.reply_tool(
        &other_start,
        "w2",
        "write",
        json!({ "path": "notes.txt", "content": "mine\n" }),
    )
    .await;
    let other_start = gw.model_start().await;
    t.note(
        "the other session's write is refused while the lease is held",
        last_message(&other_start),
    );
    gw.reply_text(&other_start, "Could not write.").await;
    gw.wait(settled_in(&other)).await;

    // The agent's gateway tools: `agent_request` frames, answered.
    gw.reply_tool(&start, "s1", "web_search", json!({ "query": "bun test" }))
        .await;
    let request = gw.wait(|frame| frame["type"] == "agent_request").await;
    t.note("agent_request (web_search)", request.clone());
    gw.link
        .send(
            &json!({ "type": "agent_response", "requestId": request["requestId"],
            "status": 200, "body": { "result": { "results": [
                { "title": "Bun test", "url": "https://bun.sh/docs/test",
                  "highlights": ["Run tests with bun test."] } ] } } }),
        )
        .await;
    let start = gw.model_start().await;
    t.note(
        "the agent's tool result for a success",
        mask_web_results(last_message(&start)),
    );

    gw.reply_tool(&start, "s2", "web_search", json!({ "query": "down" }))
        .await;
    let request = gw.wait(|frame| frame["type"] == "agent_request").await;
    gw.link
        .send(
            &json!({ "type": "agent_response", "requestId": request["requestId"],
            "status": 502, "body": { "error": { "code": "upstream_error",
                "message": "Search provider failed", "details": { "attempts": 2 } } } }),
        )
        .await;
    let start = gw.model_start().await;
    t.note("the agent's tool result for an error", last_message(&start));

    gw.reply_tool(&start, "s3", "web_search", json!({ "query": "odd" }))
        .await;
    let request = gw.wait(|frame| frame["type"] == "agent_request").await;
    gw.link
        .send(
            &json!({ "type": "agent_response", "requestId": request["requestId"],
            "status": 500 }),
        )
        .await;
    let start = gw.model_start().await;
    t.note(
        "the agent's tool result for an error without a body",
        last_message(&start),
    );
    gw.reply_text(&start, "Done.").await;
    gw.wait(settled_in(&writer)).await;
    let idle = gw
        .take(|frame| {
            frame["type"] == "activity" && frame["sessions"].as_array().is_some_and(Vec::is_empty)
        })
        .await;
    t.note("activity: both runs settled, the lease released", idle);

    // `/recap` collects its evidence on the node itself (`recap.collect`
    // never reaches the gateway), then asks the model.
    let (recap, recap_generation) = gw.session().await;
    gw.link.skipped.clear();
    gw.prompt(&recap, &recap_generation, "recap-1", "/recap 7")
        .await;
    let start = gw.model_start().await;
    t.note("the recap's model request", recap_request(&start));
    gw.reply_text(&start, "Wrote notes; searched the web.")
        .await;
    // A command, not a run: it ends with its report, without agent_settled.
    let report = gw
        .wait(|frame| {
            frame["type"] == "event"
                && frame["sessionId"] == recap.as_str()
                && frame["event"]["data"]["type"] == "message_end"
                && frame["event"]["data"]["message"]["customType"] == "recap.report"
        })
        .await;
    let mut message = report["event"]["data"]["message"].clone();
    if let Some(content) = message["content"].as_str() {
        message["content"] = json!(scanned_bytes(content));
    }
    t.note("the recap's report", message);
    t.note(
        "no agent_request reached the gateway for the recap",
        json!(
            gw.link
                .skipped
                .iter()
                .any(|frame| frame["type"] == "agent_request")
        ),
    );

    // A failed model request (`model_error` from the gateway).
    let (failing, failing_generation) = gw.session().await;
    gw.link.skipped.clear();
    gw.prompt(&failing, &failing_generation, "failing-1", "Fail")
        .await;
    let start = gw.model_start().await;
    gw.link
        .send(
            &json!({ "type": "model_error", "requestId": start["requestId"],
            "code": "inference_failed" }),
        )
        .await;
    gw.wait(settled_in(&failing)).await;
    t.note(
        "model_error: the run's events",
        json!(event_kinds(&gw.link.skipped, &failing)),
    );
    t.note(
        "model_error: the agent's final message",
        final_message(&gw.link.skipped, &failing),
    );

    // Stopping a run during a stream: the node cancels the model request.
    gw.link.skipped.clear();
    gw.prompt(&failing, &failing_generation, "failing-2", "Stream")
        .await;
    let start = gw.model_start().await;
    for delta in [
        json!({ "type": "text_start", "contentIndex": 0 }),
        json!({ "type": "text_delta", "contentIndex": 0, "delta": "Partial" }),
    ] {
        gw.link
            .send(
                &json!({ "type": "model_delta", "requestId": start["requestId"],
                "delta": delta }),
            )
            .await;
    }
    gw.wait(|frame| {
        frame["type"] == "event"
            && frame["event"]["data"]["type"] == "message_update"
            && frame["sessionId"] == failing.as_str()
    })
    .await;
    let stopped = gw
        .command(
            &failing,
            &failing_generation,
            "failing-3",
            json!({ "type": "stop" }),
        )
        .await;
    t.note("stop", stopped["data"].clone());
    let cancel = gw.take(|frame| frame["type"] == "model_cancel").await;
    t.note(
        "model_cancel names the request being streamed",
        json!({ "frame": cancel, "same request": cancel["requestId"] == start["requestId"] }),
    );
    gw.take(settled_in(&failing)).await;
    t.note(
        "stopped: the agent's final message",
        final_message(&gw.link.skipped, &failing),
    );
    insta::assert_json_snapshot!("node_link_side_runs", t.into_value());
}

const LEDGER_A: &str = "aaaaaaaaaaaaaaaa";
const LEDGER_B: &str = "bbbbbbbbbbbbbbbb";
const LEDGER_C: &str = "cccccccccccccccc";

/// A workspace-memory item as the agent's ledger holds it.
fn ledger_item(id: &str, content: &str) -> Value {
    json!({
        "id": id, "content": content, "relevance": "high", "timestamp": "2026-09-27 10:00",
        "sessionId": "agent-internal-id", "sessionDir": "/secret/sessions/pi_one",
        "sourceMemoryIds": ["aaaaaaaaaaaa"],
        "git": { "head": "abcdef123456", "branch": "main", "dirty": false,
            "worktree": "/secret/worktree" },
        "tokenCount": 10,
    })
}

fn ledger_line(value: Value) -> String {
    format!("{value}\n")
}

fn append(file: &Path, text: &str) {
    use std::io::Write;
    fs::OpenOptions::new()
        .append(true)
        .open(file)
        .unwrap()
        .write_all(text.as_bytes())
        .unwrap();
}

fn is_mirror(frame: &Value) -> bool {
    frame["type"] == "memory_mirror"
}

fn mirror_of(key: &'static str) -> impl Fn(&Value) -> bool {
    move |frame: &Value| is_mirror(frame) && frame["ledgerKey"] == key
}

#[tokio::test(flavor = "multi_thread")]
async fn node_link_side_mirror() {
    let server = FakeGateway::bind().await;
    let Some(node) = LoneNode::start_with(
        server.port(),
        NodeOptions {
            env: vec![("PIRC_MEMORY_MIRROR_MS", "100".to_owned())],
            ..NodeOptions::default()
        },
    ) else {
        return;
    };
    let mut t = Transcript::new(node.volatile());
    let mut gw = Gateway::new(server.accept().await);
    gw.link.recv().await;

    // The ledgers, written before the node registers (it scans only then):
    // `<state>/workspace-memory/<key>.jsonl`.
    let dir = node.dir.path().join("node-state/workspace-memory");
    fs::create_dir_all(dir.join("pi_session")).unwrap();
    fs::write(dir.join("context.json"), r#"{"text":"private context"}"#).unwrap();
    fs::write(dir.join("pi_session/context.json"), "{}").unwrap();
    fs::write(
        dir.join("ABCDEFABCDEFABCD.jsonl"),
        ledger_line(json!({ "type": "cleared", "at": 1 })),
    )
    .unwrap();
    let a = dir.join(format!("{LEDGER_A}.jsonl"));
    let first = ledger_line(json!({ "type": "recorded", "at": 1,
        "items": [ledger_item("a00000000001", "Staging first")] }));
    let second = ledger_line(json!({ "type": "retired", "at": 2, "ids": ["a00000000001"],
        "reason": "superseded" }));
    let partial = json!({ "type": "recorded", "at": 3,
        "items": [ledger_item("a00000000002", "Later")] })
    .to_string();
    fs::write(&a, format!("{first}{second}{partial}")).unwrap();
    let b = dir.join(format!("{LEDGER_B}.jsonl"));
    let kept = ledger_line(json!({ "type": "recorded", "at": 1,
        "items": [ledger_item("b00000000001", "Kept")] }));
    fs::write(&b, &kept).unwrap();
    let c = dir.join(format!("{LEDGER_C}.jsonl"));
    let forgotten = ledger_line(json!({ "type": "retired", "at": 4, "ids": ["c00000000001"],
        "reason": "forgotten" }));
    fs::write(&c, &forgotten).unwrap();

    // The gateway holds all of B, and more of C than there is (C shrank).
    gw.link
        .send(&registered(
            models("fake", "fake-model", "low"),
            json!({ LEDGER_B: kept.len(), LEDGER_C: forgotten.len() + 1000 }),
        ))
        .await;
    let activity = gw.wait(|frame| frame["type"] == "activity").await;
    // Sent before the activity, one per ledger, in directory order (sorted here).
    let mut mirrored: Vec<Value> = gw.link.skipped.drain(..).filter(is_mirror).collect();
    mirrored.sort_by_key(|frame| frame["ledgerKey"].as_str().unwrap_or_default().to_owned());
    t.note(
        "after registered: a frame per ledger with lines after the gateway's offset, then the activity",
        json!({ "frames": mirrored, "then": activity }),
    );
    let a_end = mirrored
        .iter()
        .find(|frame| frame["ledgerKey"] == LEDGER_A)
        .map(|frame| frame["end"].clone())
        .unwrap();

    // One frame at a time: nothing more for A until the gateway acknowledges it.
    append(&a, "\n");
    gw.link.drain(Duration::from_millis(600)).await;
    t.note(
        "unacknowledged: no second frame for the ledger",
        json!(
            gw.link
                .skipped
                .iter()
                .filter(|frame| is_mirror(frame))
                .count()
        ),
    );
    gw.link
        .send(&json!({ "type": "memory_mirror_ack", "ledgerKey": LEDGER_A, "watermark": a_end }))
        .await;
    let next = gw.take(mirror_of(LEDGER_A)).await;
    t.note(
        "acknowledged: the rest of the ledger, now complete",
        next.clone(),
    );

    // A half-written line waits for its end.
    append(&a, &json!({ "type": "cleared", "at": 5 }).to_string());
    gw.link
        .send(&json!({ "type": "memory_mirror_ack", "ledgerKey": LEDGER_A,
            "watermark": next["end"] }))
        .await;
    gw.link.drain(Duration::from_millis(600)).await;
    t.note(
        "a line without its newline is not sent",
        json!(
            gw.link
                .skipped
                .iter()
                .filter(|frame| is_mirror(frame))
                .count()
        ),
    );
    append(&a, "\n");
    let cleared = gw.take(mirror_of(LEDGER_A)).await;
    t.note(
        "its newline written: sent on the next scan",
        cleared.clone(),
    );

    // The ledger shrank below the acknowledged offset: it starts over.
    gw.link
        .send(&json!({ "type": "memory_mirror_ack", "ledgerKey": LEDGER_A,
            "watermark": cleared["end"] }))
        .await;
    // Replaced whole (renamed over it), so no scan sees it half-written.
    let replacement = dir.join("replacement.tmp");
    fs::write(
        &replacement,
        ledger_line(json!({ "type": "cleared", "at": 6 })),
    )
    .unwrap();
    fs::rename(&replacement, &a).unwrap();
    gw.link.drain(Duration::from_millis(400)).await;
    assert!(!gw.link.skipped.iter().any(mirror_of(LEDGER_A)));
    t.note(
        "a shrunk ledger is withheld; prior gateway revocations are retained",
        json!(true),
    );

    // The gateway's acknowledgement decides where the node resumes.
    gw.link
        .send(&json!({ "type": "memory_mirror_ack", "ledgerKey": LEDGER_B, "watermark": 0 }))
        .await;
    gw.link.drain(Duration::from_millis(300)).await;
    t.note(
        "a stale lower acknowledgement cannot regress the in-flight checkpoint",
        json!(true),
    );
    gw.link.skipped.clear();
    gw.link
        .send(
            &json!({ "type": "memory_mirror_ack", "ledgerKey": "dddddddddddddddd",
            "watermark": 0 }),
        )
        .await;
    gw.link.drain(Duration::from_millis(300)).await;
    t.note(
        "an acknowledgement for a ledger the node does not have: nothing",
        json!(
            gw.link
                .skipped
                .iter()
                .filter(|frame| is_mirror(frame))
                .count()
        ),
    );

    // After a reconnect the node starts from what `registered` says again.
    gw.link.close(1001, "gateway restarting").await;
    let mut gw = Gateway::new(server.accept().await);
    gw.link.recv().await;
    gw.link
        .send(&registered(
            models("fake", "fake-model", "low"),
            json!({ LEDGER_A: 0, LEDGER_B: kept.len(), LEDGER_C: forgotten.len() }),
        ))
        .await;
    gw.wait(|frame| frame["type"] == "activity").await;
    let mut mirrored: Vec<Value> = gw.link.skipped.drain(..).filter(is_mirror).collect();
    // Directory iteration order is not part of the mirror protocol.
    mirrored.sort_by_key(|frame| frame["ledgerKey"].as_str().unwrap_or_default().to_owned());
    t.note(
        "registered again: only what the gateway lacks",
        json!(mirrored),
    );
    insta::assert_json_snapshot!("node_link_side_mirror", t.into_value());
}

/// A `ptc` script that calls each of `calls` and returns their outcomes as JSON.
fn ptc_script(calls: &[(&str, Value)]) -> Value {
    let mut code = String::from("const out = [];\n");
    for (name, args) in calls {
        code.push_str(&format!(
            "out.push(await tools.call({}, {args}));\n",
            json!(name)
        ));
    }
    code.push_str("return JSON.stringify(out);");
    json!({ "code": code })
}

fn node_event<'a>(kind: &'a str, session: &'a str) -> impl Fn(&Value) -> bool + 'a {
    move |frame: &Value| {
        frame["type"] == "event" && frame["sessionId"] == session && frame["event"]["type"] == kind
    }
}

/// A `ptc` call's result without its run details (timings).
fn ptc_result(start: &Value) -> Value {
    let message = last_message(start);
    json!({ "toolName": message["toolName"], "isError": message["isError"],
        "content": message["content"] })
}

/// A control-fd line (srt settings) with only what does not depend on the
/// host: the network section whole, and of the filesystem lists the paths
/// inside the run directory (the inference socket's random directory
/// masked). Host paths (`/run/user/<uid>`, existing system sockets, the
/// agent's random `/tmp/pirc-*`) are left out.
fn control_line(line: &Value, root: &Path) -> Value {
    let root = root.canonicalize().unwrap().display().to_string();
    let mut filesystem = serde_json::Map::new();
    if let Some(lists) = line["filesystem"].as_object() {
        for (key, value) in lists {
            let kept = match value.as_array() {
                Some(paths) => json!(
                    paths
                        .iter()
                        .filter_map(Value::as_str)
                        .filter(|path| path.starts_with(&root))
                        .map(mask_inference_dir)
                        .collect::<Vec<_>>()
                ),
                None => value.clone(),
            };
            filesystem.insert(key.clone(), kept);
        }
    }
    let mut network = line["network"].clone();
    // These are backend-specific; assert them instead of recording a Linux
    // default in an otherwise platform-independent transport transcript.
    if cfg!(target_os = "linux") {
        assert_eq!(network["allowAllUnixSockets"], true);
    } else {
        let sockets = network["allowUnixSockets"].as_array().unwrap();
        assert_eq!(sockets.len(), 1);
        let socket = sockets[0].as_str().unwrap();
        assert!(
            socket.starts_with(&format!("{root}/node-state/i-")) && socket.ends_with("/socket")
        );
    }
    network
        .as_object_mut()
        .unwrap()
        .remove("allowAllUnixSockets");
    network.as_object_mut().unwrap().remove("allowUnixSockets");
    json!({ "keys": sorted_keys(line), "network": network,
        "allowPty": line["allowPty"], "filesystem (inside the run directory)": filesystem })
}

fn mask_inference_dir(path: &str) -> String {
    match path.find("/node-state/i-") {
        Some(at) if path.len() == at + "/node-state/i-".len() + 6 => {
            format!("{}/node-state/i-<random>", &path[..at])
        }
        _ => path.to_owned(),
    }
}

/// The control-fd lines the fake srt kept, once there are `count` of them.
async fn control_lines(node: &LoneNode, count: usize) -> Vec<Value> {
    let file = node.dir.path().join(pirc_conformance::FAKE_SRT_CONTROL_LOG);
    let deadline = Instant::now() + node_link_side_support::DEADLINE;
    loop {
        let text = fs::read_to_string(&file).unwrap_or_default();
        let lines: Vec<Value> = text
            .lines()
            .map(|line| serde_json::from_str(line).unwrap_or_else(|_| json!(line)))
            .collect();
        if lines.len() >= count && text.ends_with('\n') {
            return lines;
        }
        assert!(
            Instant::now() < deadline,
            "the fake srt got {} control lines, not {count}",
            lines.len()
        );
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn node_link_side_sandbox() {
    let server = FakeGateway::bind().await;
    let Some(node) = LoneNode::start(server.port()) else {
        return;
    };
    let mut t = Transcript::new(node.volatile());
    let mut gw = Gateway::new(server.accept().await);
    gw.link.recv().await;
    gw.link
        .send(&registered(models("fake", "fake-model", "low"), json!({})))
        .await;
    gw.wait(|frame| frame["type"] == "activity").await;
    let (session, generation) = gw.session().await;
    let answer_url = |id: &Value| {
        format!(
            "/api/sessions/{session}/interactions/{}/answer",
            id.as_str().unwrap_or_default()
        )
    };

    // A network approval: the node asks the human itself.
    gw.prompt(&session, &generation, "sandbox-1", "Reach out")
        .await;
    let start = gw.model_start().await;
    gw.reply_tool(
        &start,
        "n1",
        "ptc",
        ptc_script(&[(
            "sandbox_allow_domains",
            json!({ "domains": ["API.example.com", "api.example.com"],
                "reason": "fetch the schema" }),
        )]),
    )
    .await;
    let created = gw.wait(node_event("interaction_created", &session)).await;
    t.note(
        "the node's own question (an interaction_created event)",
        created["event"]["data"].clone(),
    );
    let waiting = gw
        .take(|frame| {
            activity_of(frame, &session).is_some_and(|entry| entry["run"] == "waiting_input")
        })
        .await;
    t.note("activity: the run waits for the human", waiting);
    let interaction = created["event"]["data"]["id"].clone();
    let snapshot = gw
        .ask("GET", &format!("/api/sessions/{session}/snapshot"), None)
        .await;
    t.note(
        "the snapshot's interactions",
        snapshot["data"]["body"]["interactions"].clone(),
    );
    let answered = gw
        .ask(
            "POST",
            &answer_url(&interaction),
            Some(json!({ "clientId": "browser", "generation": generation,
                "answer": { "confirmed": true } })),
        )
        .await;
    t.note("approve", answered["data"].clone());
    let event = gw.take(node_event("interaction_answered", &session)).await;
    t.note("interaction_answered", event["event"]["data"].clone());
    let start = gw.model_start().await;
    t.note("the agent's result", ptc_result(&start));
    let lines = control_lines(&node, 1).await;
    t.note(
        "the line the node wrote to srt's control fd: the settings with the approved domain",
        json!(
            lines
                .iter()
                .map(|line| control_line(line, node.dir.path()))
                .collect::<Vec<_>>()
        ),
    );
    let again = gw
        .ask(
            "POST",
            &answer_url(&interaction),
            Some(json!({ "clientId": "browser", "generation": generation,
                "answer": { "confirmed": true } })),
        )
        .await;
    t.note("answering it again", without_details(&again["data"]));
    let unknown = gw
        .ask(
            "POST",
            &format!("/api/sessions/{session}/interactions/interaction_nope/answer"),
            Some(json!({ "clientId": "browser", "generation": generation,
                "answer": { "confirmed": true } })),
        )
        .await;
    t.note(
        "answering an unknown interaction",
        without_details(&unknown["data"]),
    );

    // Allowed already (a default domain, the approved one) or invalid: no question.
    gw.reply_tool(
        &start,
        "n2",
        "ptc",
        ptc_script(&[
            (
                "sandbox_allow_domains",
                json!({ "domains": ["github.com"], "reason": "clone" }),
            ),
            (
                "sandbox_allow_domains",
                json!({ "domains": ["api.example.com"], "reason": "again" }),
            ),
            (
                "sandbox_allow_domains",
                json!({ "domains": ["bad domain"], "reason": "typo" }),
            ),
            (
                "sandbox_allow_domains",
                json!({ "domains": [], "reason": "none" }),
            ),
        ]),
    )
    .await;
    let start = gw.model_start().await;
    t.note("allowed already, or invalid", ptc_result(&start));

    // Declined.
    gw.reply_tool(
        &start,
        "n3",
        "ptc",
        ptc_script(&[(
            "sandbox_allow_domains",
            json!({ "domains": ["evil.example.net"], "reason": "x" }),
        )]),
    )
    .await;
    let created = gw.wait(node_event("interaction_created", &session)).await;
    let declined = gw
        .ask(
            "POST",
            &answer_url(&created["event"]["data"]["id"]),
            Some(json!({ "clientId": "browser", "generation": generation,
                "answer": { "confirmed": false } })),
        )
        .await;
    t.note("decline", declined["data"].clone());
    let start = gw.model_start().await;
    t.note(
        "the agent's result for a declined domain",
        ptc_result(&start),
    );

    // A command outside the sandbox, declined; and one with a cwd outside
    // the workspace, refused without a question. (An approved one would
    // run `/bin/bash`, which this machine may not have.)
    gw.reply_tool(
        &start,
        "x1",
        "ptc",
        ptc_script(&[(
            "unsandboxed_bash",
            json!({ "command": "touch denied.txt", "reason": "nix build" }),
        )]),
    )
    .await;
    let created = gw.wait(node_event("interaction_created", &session)).await;
    t.note(
        "the node's question for a command",
        created["event"]["data"]["request"].clone(),
    );
    let leased = gw
        .take(|frame| {
            activity_of(frame, &session)
                .is_some_and(|entry| entry["run"] == "waiting_input" && entry["writeLease"] == true)
        })
        .await;
    t.note(
        "activity: waiting, with the workspace's write lease",
        leased,
    );
    // Declined through the gateway-only route that answers a delegated
    // session's confirmation relayed to its chat: no lease, yes or no only.
    let relayed_url =
        answer_url(&created["event"]["data"]["id"]).replace("/answer", "/relayed-answer");
    let not_a_confirmation = gw
        .ask(
            "POST",
            &relayed_url,
            Some(json!({ "answer": { "value": "yes" } })),
        )
        .await;
    assert_eq!(
        not_a_confirmation["data"]["status"], 400,
        "{not_a_confirmation}"
    );
    let relayed = gw
        .ask(
            "POST",
            &relayed_url,
            Some(json!({ "answer": { "confirmed": false } })),
        )
        .await;
    assert_eq!(relayed["data"]["status"], 200, "{relayed}");
    assert_eq!(relayed["data"]["body"]["status"], "answered", "{relayed}");
    let start = gw.model_start().await;
    t.note(
        "the agent's result for a declined command",
        ptc_result(&start),
    );
    gw.link.skipped.clear();
    gw.reply_tool(
        &start,
        "x2",
        "ptc",
        ptc_script(&[(
            "unsandboxed_bash",
            json!({ "command": "true", "cwd": "/", "reason": "x" }),
        )]),
    )
    .await;
    let start = gw.model_start().await;
    t.note("a cwd outside the workspace", ptc_result(&start));
    t.note(
        "no question for it",
        json!(
            gw.link
                .skipped
                .iter()
                .any(node_event("interaction_created", &session))
        ),
    );
    gw.reply_text(&start, "Done.").await;
    gw.wait(settled_in(&session)).await;
    t.note(
        "declines write nothing to the control fd",
        json!(control_lines(&node, 1).await.len()),
    );
    let denied = node.dir.path().join("workspace/denied.txt").exists();
    t.note("the declined command did not run", json!(!denied));
    insta::assert_json_snapshot!("node_link_side_sandbox", t.into_value());
}

/// A gateway refusing the node's credentials (close 4401) is reported once,
/// not on every retry, and again only after the node has registered in
/// between: a wrong token used to be retried silently forever.
#[tokio::test(flavor = "multi_thread")]
async fn node_link_side_reports_refused_credentials() {
    let server = FakeGateway::bind().await;
    let Some(node) = LoneNode::start(server.port()) else {
        return;
    };
    let reports = |node: &LoneNode| {
        node.log()
            .matches("the gateway refused this node's credentials (closed 4401)")
            .count()
    };
    let refuse = async |server: &FakeGateway| {
        let mut link = server.accept().await;
        link.recv().await;
        link.close(4401, "invalid node credentials").await;
    };
    refuse(&server).await;
    refuse(&server).await;
    // Each retry follows the handling of the refusal before it.
    let mut gw = Gateway::new(server.accept().await);
    assert_eq!(reports(&node), 1, "{}", node.log());
    gw.link.recv().await;
    gw.link
        .send(&registered(models("fake", "fake-model", "low"), json!({})))
        .await;
    // A relayed request is answered once the node has registered.
    gw.ask("GET", "/api/workspaces", None).await;
    gw.link.close(1000, "restart").await;
    refuse(&server).await;
    let _next = server.accept().await;
    assert_eq!(reports(&node), 2, "{}", node.log());
}

/// Real Node + Agent/PTC + relayed human confirmation, with a fake gateway/model.
/// The approved shell writes only this fixture; duplicate devices cannot replay it.
#[tokio::test]
async fn node_link_side_host_management() {
    let server = FakeGateway::bind().await;
    let Some(node) = LoneNode::start(server.port()) else {
        return;
    };
    let mut gw = Gateway::new(server.accept().await);
    gw.link.recv().await;
    gw.link
        .send(&registered(models("fake", "fake-model", "low"), json!({})))
        .await;
    gw.wait(|frame| frame["type"] == "activity").await;
    let (session, generation) = gw.session().await;
    let marker = node.dir.path().join("workspace/host-management-once.txt");
    let peer = node.dir.path().join("workspace/user-kept.txt");
    fs::write(&peer, "keep later user changes").unwrap();
    gw.prompt(
        &session,
        &generation,
        "host-management",
        "Run the requested host command",
    )
    .await;
    let start = gw.model_start().await;
    gw.reply_tool(&start,"host-1","ptc",ptc_script(&[("unsandboxed_bash",json!({
        "command":"printf 'approved\n' >> host-management-once.txt","reason":"explicit host administration test"
    }))])).await;
    let created = gw.wait(node_event("interaction_created", &session)).await;
    let interaction = &created["event"]["data"];
    assert_eq!(
        interaction["request"]["title"],
        "Allow host management for this command?"
    );
    assert!(
        interaction["request"]["message"]
            .as_str()
            .unwrap()
            .contains("Detached jobs")
    );
    assert!(
        !marker.exists(),
        "The host command ran before the user's answer"
    );
    let path = format!(
        "/api/sessions/{session}/interactions/{}/answer",
        interaction["id"].as_str().unwrap()
    );
    let answer = json!({"clientId":"browser","generation":generation,"answer":{"confirmed":true}});
    let response = gw.ask("POST", &path, Some(answer.clone())).await;
    assert_eq!(response["data"]["status"], 200, "{response}");
    let duplicate = gw.ask("POST", &path, Some(answer)).await;
    assert_eq!(duplicate["data"]["status"], 409, "{duplicate}");
    let start = gw.model_start().await;
    let result = ptc_result(&start);
    assert_eq!(result["isError"], false, "{result}");
    assert_eq!(fs::read_to_string(&marker).unwrap(), "approved\n");
    assert_eq!(
        fs::read_to_string(&peer).unwrap(),
        "keep later user changes"
    );
    gw.reply_text(&start, "Done.").await;
    gw.wait(settled_in(&session)).await;
    assert_eq!(fs::read_to_string(marker).unwrap(), "approved\n");
}
