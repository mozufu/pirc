//! The `todo` tool (`agent/features/todo/`), with the test playing the
//! agent's node. `todo` is not a direct tool: the model reaches it only
//! from a `ptc` script, so these transcripts replay only on an agent with
//! the PTC runtime (docs/architecture/ptc.md). The slash commands are in
//! `agent_todo.rs`.

mod feature_support;

use pirc_conformance::{AgentOptions, AgentRun, ModelReply, Recorder};
use serde_json::{Value, json};

/// A `ptc` call running one capability, as `ptcCall` in the TS tests.
fn ptc(id: &str, name: &str, args: Value) -> (String, String, Value) {
    let code = format!(
        "const r = await tools.call({}, {args});\nif (!r.ok) throw new PtcError(r.error);\nreturn r.data.text;",
        json!(name)
    );
    (id.to_owned(), "ptc".to_owned(), json!({ "code": code }))
}

fn calls(calls: Vec<(String, String, Value)>) -> ModelReply {
    ModelReply::Tools(calls)
}

fn text(value: &str) -> ModelReply {
    ModelReply::Text(value.to_owned())
}

/// Script timings (`activeMs`, `durationMs`, `waitedMs`) vary between
/// runs.
fn mask_times(value: &mut Value) {
    match value {
        Value::Array(items) => items.iter_mut().for_each(mask_times),
        Value::Object(object) => {
            for (key, item) in object.iter_mut() {
                if key.ends_with("Ms") && item.is_number() {
                    *item = json!("<ms>");
                } else {
                    mask_times(item);
                }
            }
        }
        _ => {}
    }
}

/// A prompt and everything until the run settles.
async fn turn(agent: &mut AgentRun, r: &mut Recorder, step: &str, message: &str) {
    let response = agent
        .call(json!({ "type": "prompt", "message": message }))
        .await;
    r.note(&format!("{step}: response"), response);
    let events = agent.settle().await;
    record(agent, r, step, events);
}

/// Events, then the requests the agent made, with timings masked.
fn record(agent: &AgentRun, r: &mut Recorder, step: &str, events: Vec<Value>) {
    let mut events = json!(events);
    mask_times(&mut events);
    r.note(&format!("{step}: events"), events);
    let mut requests = json!(agent.take_requests());
    mask_times(&mut requests);
    let requests = match requests {
        Value::Array(items) => items,
        _ => Vec::new(),
    };
    r.requests(&format!("{step}: model requests"), requests);
}

/// The session file, with timings masked.
fn session(agent: &AgentRun, r: &mut Recorder) {
    let mut entries = json!(agent.session_entries());
    mask_times(&mut entries);
    r.note("session file", entries);
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_todo_tool() {
    let Some(mut agent) = AgentRun::start(AgentOptions::default().features("todo")).await else {
        return;
    };
    let mut r = Recorder::new(&agent);
    agent.push([
        calls(vec![ptc(
            "t1",
            "todo",
            json!({ "action": "add", "items": [{ "text": "write code", "activeForm": "Writing code" },
                { "text": "test it", "blockedBy": [1], "category": "qa" }] }),
        )]),
        calls(vec![ptc(
            "t2",
            "todo",
            json!({ "action": "update", "id": 1, "status": "in_progress" }),
        )]),
        calls(vec![ptc(
            "t3",
            "todo",
            json!({ "action": "update", "id": 2, "status": "in_progress" }),
        )]),
        calls(vec![ptc(
            "t4",
            "todo",
            json!({ "action": "update", "id": 1, "status": "completed" }),
        )]),
        calls(vec![ptc("t5", "todo", json!({ "action": "list" }))]),
        calls(vec![ptc(
            "t6",
            "todo",
            json!({ "action": "update", "id": 2, "blockedBy": [2] }),
        )]),
        calls(vec![ptc("t7", "todo", json!({ "action": "remove", "id": 1 }))]),
        calls(vec![ptc(
            "t8",
            "todo",
            json!({ "action": "add", "items": [{ "text": "x" }], "text": "y" }),
        )]),
        calls(vec![ptc(
            "t9",
            "todo",
            json!({ "action": "update", "id": 2, "category": "  " }),
        )]),
        calls(vec![ptc("t10", "todo", json!({ "action": "prune" }))]),
        text("stopping early"),
        text("still stopping"),
    ]);
    turn(&mut agent, &mut r, "plan", "plan").await;
    session(&agent, &mut r);
    insta::assert_json_snapshot!(
        "agent_todo_tool",
        feature_support::without_ptc_progress(r.into_value())
    );
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_todo_tool_after_restart() {
    let options = || AgentOptions::default().features("todo");
    let Some(mut agent) = AgentRun::start(options()).await else {
        return;
    };
    let mut r = Recorder::new(&agent);
    agent.push([
        calls(vec![ptc(
            "t",
            "todo",
            json!({ "action": "add", "text": "persist me" }),
        )]),
        calls(vec![ptc(
            "u",
            "todo",
            json!({ "action": "update", "id": 1, "status": "completed" }),
        )]),
        text("done"),
    ]);
    turn(&mut agent, &mut r, "first process", "x").await;
    let Some(mut agent) = agent.restart(options()).await else {
        return;
    };
    // The snapshot is owed once: the first tool call answers with it.
    agent.push([
        calls(vec![ptc(
            "v",
            "todo",
            json!({ "action": "add", "text": "next" }),
        )]),
        calls(vec![ptc(
            "w",
            "todo",
            json!({ "action": "update", "id": 2, "status": "completed" }),
        )]),
        text("hi"),
    ]);
    turn(&mut agent, &mut r, "second process", "continue").await;
    insta::assert_json_snapshot!(
        "agent_todo_tool_after_restart",
        feature_support::without_ptc_progress(r.into_value())
    );
}
