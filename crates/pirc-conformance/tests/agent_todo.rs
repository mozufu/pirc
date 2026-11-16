//! The todo list (`agent/features/todo/`, feature `todo`) as far as it
//! goes without `ptc` scripts, with the test playing the agent's node: the
//! `/todo` slash commands and their errors, the widget, manual updates as
//! hidden context, the end-of-run reminder, restoring the list in a new
//! process (and skipping damaged history), headless agents, and chats,
//! which leave the tool out unless the config brings it back. The tool
//! itself is in `agent_todo_ptc.rs`. The historical feature baseline
//! (docs/development/historical-records.md).

use std::collections::VecDeque;

use pirc_conformance::{AgentOptions, AgentRun, Gate, ModelReply, Recorder};
use serde_json::{Value, json};

fn text(value: &str) -> ModelReply {
    ModelReply::Text(value.to_owned())
}

/// A prompt and everything until the run settles.
async fn turn(agent: &mut AgentRun, r: &mut Recorder, step: &str, message: &str) {
    let response = agent
        .call(json!({ "type": "prompt", "message": message }))
        .await;
    r.note(&format!("{step}: response"), response);
    let events = agent.settle().await;
    r.turn(step, agent, events);
}

/// A slash command: its lines up to the notification that ends it (the
/// command's response may come before or after).
async fn slash(agent: &mut AgentRun, r: &mut Recorder, message: &str) {
    slash_until(agent, r, message, "notify").await;
}

/// A slash command: its lines up to its response and a UI request of
/// `method` (a declined confirmation ends a command silently).
async fn slash_until(agent: &mut AgentRun, r: &mut Recorder, message: &str, method: &str) {
    send_until(agent, r, "prompt", message, method).await;
}

/// A command `kind` (`prompt`, or `steer` while the agent runs) with a
/// slash command, up to its response and a UI request of `method`.
async fn send_until(
    agent: &mut AgentRun,
    r: &mut Recorder,
    kind: &str,
    message: &str,
    method: &str,
) {
    let id = agent
        .command(json!({ "type": kind, "message": message }))
        .await;
    let mut lines = Vec::new();
    let (mut answered, mut ended) = (false, false);
    while !(answered && ended) {
        let line = agent.next().await.expect("the agent exited");
        answered |= line["type"] == "response" && line["id"] == id.as_str();
        ended |= line["type"] == "extension_ui_request" && line["method"] == method;
        lines.push(line);
    }
    r.note(message, json!(lines));
}

/// Lines up to the response of `command`, startup lines included.
async fn command(agent: &mut AgentRun, command: Value) -> Vec<Value> {
    let id = agent.command(command).await;
    agent
        .until(|line| line["type"] == "response" && line["id"] == id.as_str())
        .await
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_todo_commands() {
    let Some(mut agent) = AgentRun::start(AgentOptions::default().features("todo")).await else {
        return;
    };
    let mut r = Recorder::new(&agent);
    let commands = agent.call(json!({ "type": "get_commands" })).await;
    r.note("commands", commands);
    agent.answers.lock().unwrap().dialogs = VecDeque::from([json!({ "confirmed": false })]);
    for message in [
        "/todo help",
        "/todo",
        "/todo add Buy milk",
        "/todo add   Write   the tests  ",
        "/todo start 2",
        "/todo category 2 dev work",
        "/todo edit 1 Buy oat milk",
        "/todo done 1",
        "/todo list",
        "/todo category 2",
        "/todo pending 2",
        "/todo start x",
        "/todo start 01",
        "/todo start 1 2",
        "/todo frob 1",
        "/todo remove 9",
        "/todo add",
        "/todo prune extra",
    ] {
        slash(&mut agent, &mut r, message).await;
    }
    // Declined: nothing changes, nothing is said.
    slash_until(&mut agent, &mut r, "/todo clear", "confirm").await;
    slash(&mut agent, &mut r, "/todo prune").await;
    slash(&mut agent, &mut r, "/todo list").await;
    // Manual updates reach the model as hidden context; an unfinished
    // list gets one reminder at the end of the run.
    agent.push([text("Noted."), text("Still stopping.")]);
    turn(
        &mut agent,
        &mut r,
        "a run with unfinished todos",
        "what now",
    )
    .await;
    // A new human message allows another reminder.
    agent.push([text("Again."), text("Stopping.")]);
    turn(&mut agent, &mut r, "another run", "and now").await;
    // While the agent works, the list is the model's.
    let gate = Gate::new();
    agent.push([ModelReply::gated(&gate, text("Working."))]);
    let response = agent
        .call(json!({ "type": "prompt", "message": "work" }))
        .await;
    r.note("a busy run: response", response);
    // Admission responds before the run starts. Wait for its gated request so
    // startup events precede the first steer, rather than racing either steer.
    agent.wait_for_request().await;
    send_until(&mut agent, &mut r, "steer", "/todo add Later", "notify").await;
    send_until(&mut agent, &mut r, "steer", "/todo list", "notify").await;
    gate.open();
    agent.push([text("Reminded.")]);
    let events = agent.settle().await;
    r.turn("a busy run", &agent, events);
    agent
        .answers
        .lock()
        .unwrap()
        .dialogs
        .push_back(json!({ "confirmed": true }));
    slash(&mut agent, &mut r, "/todo clear").await;
    r.session(&agent);
    // Shutting down clears the widget.
    let (lines, code) = agent.close().await;
    r.note("shutdown", json!(lines));
    r.note("exit code", json!(code));
    insta::assert_json_snapshot!("agent_todo_commands", r.into_value());
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_todo_restore() {
    let options = || AgentOptions::default().features("todo");
    let Some(mut agent) = AgentRun::start(options()).await else {
        return;
    };
    let mut r = Recorder::new(&agent);
    slash(&mut agent, &mut r, "/todo add persist me").await;
    slash(&mut agent, &mut r, "/todo add and me").await;
    slash(&mut agent, &mut r, "/todo done 1").await;
    // A new process restores the list, paints it, and owes the model a
    // snapshot: with the next manual update, or else the next run.
    let Some(mut agent) = agent.restart(options()).await else {
        return;
    };
    let startup = command(&mut agent, json!({ "type": "get_state" })).await;
    r.note("restarted", json!(startup));
    slash(&mut agent, &mut r, "/todo start 2").await;
    agent.push([text("Continuing."), text("Done here.")]);
    turn(&mut agent, &mut r, "after a manual update", "continue").await;
    let Some(mut agent) = agent.restart(options()).await else {
        return;
    };
    let startup = command(&mut agent, json!({ "type": "get_state" })).await;
    r.note("restarted again", json!(startup));
    agent.push([text("Snapshot seen."), text("Still here.")]);
    turn(&mut agent, &mut r, "first run", "continue").await;
    r.session(&agent);
    insta::assert_json_snapshot!("agent_todo_restore", r.into_value());
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_todo_damaged_history() {
    let entry = |id: &str, parent: &str, data: Value| {
        json!({ "type": "custom", "customType": "local-todo-state-v1", "data": data,
            "id": id, "parentId": parent, "timestamp": 1001 })
        .to_string()
    };
    let session = [
        json!({ "type": "session", "version": 1, "sessionId": "0123456789abcdef",
            "cwd": "/elsewhere", "id": "a0000001", "parentId": null, "timestamp": 1000 })
        .to_string(),
        entry(
            "a0000002",
            "a0000001",
            json!({ "version": 1, "nextId": 3, "todos": [
                { "id": 1, "text": "kept", "status": "completed", "blockedBy": [] },
                { "id": 2, "text": "blocked", "status": "pending", "blockedBy": [1],
                  "category": "x", "activeForm": "Blocking" } ] }),
        ),
        // A cycle, then a status that does not exist: both skipped.
        entry(
            "a0000003",
            "a0000002",
            json!({ "version": 1, "nextId": 3, "todos": [
                { "id": 1, "text": "a", "status": "pending", "blockedBy": [2] },
                { "id": 2, "text": "b", "status": "pending", "blockedBy": [1] } ] }),
        ),
        entry(
            "a0000004",
            "a0000003",
            json!({ "version": 1, "nextId": 2, "todos": [
                { "id": 1, "text": "a", "status": "done", "blockedBy": [] } ] }),
        ),
    ]
    .join("\n");
    let Some(mut agent) = AgentRun::start(
        AgentOptions {
            files: vec![(
                "../session/session.jsonl".to_owned(),
                format!("{session}\n"),
            )],
            ..AgentOptions::default()
        }
        .features("todo"),
    )
    .await
    else {
        return;
    };
    let mut r = Recorder::new(&agent);
    let startup = command(&mut agent, json!({ "type": "get_state" })).await;
    r.note("startup", json!(startup));
    slash(&mut agent, &mut r, "/todo list").await;
    insta::assert_json_snapshot!("agent_todo_damaged_history", r.into_value());
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_todo_headless() {
    let Some(mut agent) = AgentRun::start(
        AgentOptions {
            args: vec!["--headless".to_owned()],
            ..AgentOptions::default()
        }
        .features("todo"),
    )
    .await
    else {
        return;
    };
    let mut r = Recorder::new(&agent);
    // No widget without a UI.
    slash(&mut agent, &mut r, "/todo add quiet").await;
    agent.push([text("Ok."), text("Ok again.")]);
    turn(&mut agent, &mut r, "a run", "go").await;
    let (lines, code) = agent.close().await;
    r.note("shutdown", json!(lines));
    r.note("exit code", json!(code));
    insta::assert_json_snapshot!("agent_todo_headless", r.into_value());
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_todo_in_chat() {
    let mut options = AgentOptions::default().features("todo");
    options.env.push((
        "PIRC_MODE".to_owned(),
        serde_json::to_string(&pirc_protocol::mode::default_chat()).unwrap(),
    ));
    let Some(mut agent) = AgentRun::start(options).await else {
        return;
    };
    let mut r = Recorder::new(&agent);
    // The tool is left out; the command stays.
    let commands = agent.call(json!({ "type": "get_commands" })).await;
    r.note("commands", commands);
    slash(&mut agent, &mut r, "/todo add in a chat").await;
    agent.push([text("Ok."), text("Ok again.")]);
    turn(&mut agent, &mut r, "a run", "go").await;
    insta::assert_json_snapshot!("agent_todo_in_chat", r.into_value());
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_todo_in_chat_enabled() {
    let mut options = AgentOptions {
        config: json!({ "features": { "todo": { "enabled": true } } }),
        ..AgentOptions::default()
    }
    .features("todo");
    options.env.push((
        "PIRC_MODE".to_owned(),
        serde_json::to_string(&pirc_protocol::mode::default_chat()).unwrap(),
    ));
    let Some(mut agent) = AgentRun::start(options).await else {
        return;
    };
    let mut r = Recorder::new(&agent);
    agent.push([text("Ok.")]);
    turn(&mut agent, &mut r, "a run", "go").await;
    insta::assert_json_snapshot!("agent_todo_in_chat_enabled", r.into_value());
}
