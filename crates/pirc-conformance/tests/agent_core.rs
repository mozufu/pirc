//! The agent alone (features off), with the test playing its node: the
//! historical core baseline (docs/development/historical-records.md). The loop, the RPC
//! commands, tool calls and their failures, queues and model failures.

use pirc_conformance::{AgentOptions, AgentRun, ModelReply, Recorder};
use serde_json::{Value, json};

fn tools(calls: &[(&str, &str, Value)]) -> ModelReply {
    ModelReply::Tools(
        calls
            .iter()
            .map(|(id, name, args)| ((*id).to_owned(), (*name).to_owned(), args.clone()))
            .collect(),
    )
}

/// A prompt and everything the agent does until it settles.
async fn turn(agent: &mut AgentRun, r: &mut Recorder, step: &str, message: &str) {
    let response = agent
        .call(json!({ "type": "prompt", "message": message }))
        .await;
    r.note(&format!("{step}: response"), response);
    let events = agent.settle().await;
    r.turn(step, agent, events);
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_text_turn() {
    let Some(mut agent) = AgentRun::start(AgentOptions::default()).await else {
        return;
    };
    let mut r = Recorder::new(&agent);
    let state = agent.call(json!({ "type": "get_state" })).await;
    r.note("state before", state);
    agent.push([ModelReply::Text("Hello from the fake model.".to_owned())]);
    turn(&mut agent, &mut r, "first prompt", "Say hello").await;
    agent.push([ModelReply::Thinking(
        "The user wants more.".to_owned(),
        "More, then.".to_owned(),
    )]);
    turn(&mut agent, &mut r, "second prompt", "And again").await;
    let messages = agent.call(json!({ "type": "get_messages" })).await;
    r.note("messages", messages);
    let state = agent.call(json!({ "type": "get_state" })).await;
    r.note("state after", state);
    r.session(&agent);
    r.note("exit code", json!(agent.finish().await));
    insta::assert_json_snapshot!("agent_text_turn", r.into_value());
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_rpc_commands() {
    let Some(mut agent) = AgentRun::start(AgentOptions::default()).await else {
        return;
    };
    let mut r = Recorder::new(&agent);
    for (step, command) in [
        ("commands", json!({ "type": "get_commands" })),
        ("models", json!({ "type": "get_available_models" })),
        (
            "an unknown model",
            json!({ "type": "set_model", "provider": "fake", "modelId": "nope" }),
        ),
        (
            "switch model",
            json!({ "type": "set_model", "provider": "fake", "modelId": "small-model" }),
        ),
        (
            "thinking high",
            json!({ "type": "set_thinking_level", "level": "high" }),
        ),
        (
            "thinking max",
            json!({ "type": "set_thinking_level", "level": "max" }),
        ),
        (
            "an unknown thinking level",
            json!({ "type": "set_thinking_level", "level": "huge" }),
        ),
        (
            "name the session",
            json!({ "type": "set_session_name", "name": "Conformance" }),
        ),
        ("state", json!({ "type": "get_state" })),
        ("panel state", json!({ "type": "get_panel_state" })),
        ("context before any turn", json!({ "type": "get_context" })),
        ("an unknown command", json!({ "type": "teleport" })),
        ("clear an empty queue", json!({ "type": "clear_queue" })),
        ("abort while idle", json!({ "type": "abort" })),
        (
            "send_now without a queue",
            json!({ "type": "send_now", "message": "x" }),
        ),
        (
            "send_now with a bad index",
            json!({ "type": "send_now", "queue": "steering", "index": -1, "message": "x" }),
        ),
        (
            "send_now of nothing queued",
            json!({ "type": "send_now", "queue": "followUp", "index": 0, "message": "x" }),
        ),
        (
            "deliver without content",
            json!({ "type": "deliver", "message": { "customType": "note" } }),
        ),
    ] {
        let response = agent.call(command).await;
        r.note(step, response);
    }
    agent.send_raw("{not json\n").await;
    let parse = agent.until(|line| line["type"] == "response").await;
    r.note("a line that is not JSON", json!(parse));
    // A delivered message wakes the agent.
    let response = agent
        .call(
            json!({ "type": "deliver", "message": { "customType": "delegation",
            "content": "Your delegated task finished.", "details": { "taskId": "t1" } } }),
        )
        .await;
    r.note("deliver", response);
    let events = agent.settle().await;
    r.turn("delivered message", &agent, events);
    let context = agent.call(json!({ "type": "get_context" })).await;
    r.note("context after a turn", context);
    agent.push([ModelReply::Text("Still here.".to_owned())]);
    let response = agent
        .call(json!({ "type": "prompt", "message": "Hi", "streamingBehavior": "steer" }))
        .await;
    r.note("prompt with a streaming behavior while idle", response);
    let events = agent.settle().await;
    r.turn("that prompt", &agent, events);
    r.session(&agent);
    insta::assert_json_snapshot!("agent_rpc_commands", r.into_value());
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_tool_round() {
    let Some(mut agent) = AgentRun::start(AgentOptions {
        files: vec![
            (
                "README.md".to_owned(),
                "conformance\nsecond line\n".to_owned(),
            ),
            (
                "src/lib.rs".to_owned(),
                "pub fn answer() -> u32 {\n    42\n}\n".to_owned(),
            ),
            ("src/notes.md".to_owned(), "# Notes\n".to_owned()),
        ],
        ..AgentOptions::default()
    })
    .await
    else {
        return;
    };
    let mut r = Recorder::new(&agent);
    agent.push([
        tools(&[
            ("c1", "read", json!({ "path": "README.md" })),
            ("c2", "ls", json!({})),
            ("c3", "find", json!({ "pattern": "**/*.md" })),
            ("c4", "grep", json!({ "pattern": "answer", "path": "src" })),
            (
                "c5",
                "read",
                json!({ "path": "src/lib.rs", "offset": 2, "limit": 1 }),
            ),
        ]),
        tools(&[
            (
                "c6",
                "write",
                json!({ "path": "notes.txt", "content": "first\n" }),
            ),
            (
                "c7",
                "edit",
                json!({ "path": "README.md", "oldText": "second line", "newText": "changed line" }),
            ),
            ("c8", "bash", json!({ "command": "printf 'from bash\\n'" })),
        ]),
        ModelReply::Text("Done.".to_owned()),
    ]);
    turn(&mut agent, &mut r, "tools", "Look around and change things").await;
    for file in ["notes.txt", "README.md"] {
        let content = std::fs::read_to_string(agent.workspace.join(file)).unwrap();
        r.note(&format!("{file} afterwards"), json!(content));
    }
    r.session(&agent);
    insta::assert_json_snapshot!("agent_tool_round", r.into_value());
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_tool_errors() {
    let Some(mut agent) = AgentRun::start(AgentOptions::default()).await else {
        return;
    };
    let mut r = Recorder::new(&agent);
    let workspace = agent.workspace.display().to_string();
    agent.answers.lock().unwrap().refuse_leases = vec![workspace];
    agent.push([
        tools(&[
            ("e1", "teleport", json!({})),
            ("e2", "read", json!({})),
            ("e3", "read", json!({ "path": "missing.txt" })),
            (
                "e4",
                "read",
                json!({ "path": "README.md", "extra": true, "limit": null }),
            ),
            (
                "e5",
                "edit",
                json!({ "path": "README.md", "oldText": "absent", "newText": "x" }),
            ),
            (
                "e6",
                "write",
                json!({ "path": "/etc/pirc-conformance", "content": "x" }),
            ),
            (
                "e7",
                "write",
                json!({ "path": "refused.txt", "content": "x" }),
            ),
            (
                "e8",
                "bash",
                json!({ "command": "printf 'failing\\n'; exit 3" }),
            ),
            ("e9", "ptc_docs", json!({ "names": ["read", "nope"] })),
            ("e10", "read", json!({ "path": "../outside.txt" })),
        ]),
        ModelReply::Text("Noted.".to_owned()),
    ]);
    turn(&mut agent, &mut r, "failing tools", "Try things that fail").await;
    r.session(&agent);
    insta::assert_json_snapshot!("agent_tool_errors", r.into_value());
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_queues() {
    let Some(mut agent) = AgentRun::start(AgentOptions::default()).await else {
        return;
    };
    let mut r = Recorder::new(&agent);

    // A steer and a follow-up while a tool runs.
    agent.push([
        ModelReply::tool("q1", "bash", json!({ "command": "sleep 1" })),
        ModelReply::Text("Saw the steer.".to_owned()),
        ModelReply::Text("Saw the follow-up.".to_owned()),
    ]);
    let response = agent
        .call(json!({ "type": "prompt", "message": "Wait a second" }))
        .await;
    r.note("prompt", response);
    let mut events = agent
        .until(|line| line["type"] == "tool_execution_start")
        .await;
    for (step, command) in [
        (
            "steer",
            json!({ "type": "steer", "message": "Also check the tests" }),
        ),
        (
            "follow up",
            json!({ "type": "follow_up", "message": "Then summarize" }),
        ),
        (
            "prompt while running",
            json!({ "type": "prompt", "message": "Ignored" }),
        ),
    ] {
        let response = agent.call(command).await;
        r.note(step, response);
    }
    events.extend(agent.settle().await);
    events.retain(|line| line["type"] != "response");
    r.turn("steer and follow-up", &agent, events);

    // Cleared queue, then send_now interrupting a model call.
    agent.push([
        ModelReply::tool("q2", "bash", json!({ "command": "sleep 1" })),
        ModelReply::Hang("Thinking about".to_owned()),
        ModelReply::Text("Interrupted, then answered.".to_owned()),
    ]);
    agent
        .call(json!({ "type": "prompt", "message": "Long work" }))
        .await;
    let mut events = agent
        .until(|line| line["type"] == "tool_execution_start")
        .await;
    agent
        .call(json!({ "type": "follow_up", "message": "Dropped" }))
        .await;
    let cleared = agent.call(json!({ "type": "clear_queue" })).await;
    r.note("clear the queue", cleared);
    events.extend(
        agent
            .until(|line| {
                line["type"] == "message_update"
                    && line["assistantMessageEvent"]["type"] == "text_delta"
            })
            .await,
    );
    agent
        .call(json!({ "type": "follow_up", "message": "Right now" }))
        .await;
    let sent = agent
        .call(
            json!({ "type": "send_now", "queue": "followUp", "index": 0, "message": "Right now" }),
        )
        .await;
    r.note("send now", sent);
    events.extend(agent.settle().await);
    events.retain(|line| line["type"] != "response");
    r.turn("cleared queue and send now", &agent, events);

    // Abort while the model streams.
    agent.push([ModelReply::Hang("Partial".to_owned())]);
    agent
        .call(json!({ "type": "prompt", "message": "Never finish" }))
        .await;
    let mut events = agent
        .until(|line| {
            line["type"] == "message_update"
                && line["assistantMessageEvent"]["type"] == "text_delta"
        })
        .await;
    let aborted = agent.call(json!({ "type": "abort" })).await;
    r.note("abort", aborted);
    events.extend(agent.settle().await);
    events.retain(|line| line["type"] != "response");
    r.turn("abort", &agent, events);

    // The next prompt learns about the interrupted reply.
    agent.push([ModelReply::Text("Resumed.".to_owned())]);
    turn(&mut agent, &mut r, "after the abort", "Go on").await;
    r.session(&agent);
    insta::assert_json_snapshot!("agent_queues", r.into_value());
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_model_failures() {
    let Some(mut agent) = AgentRun::start(AgentOptions::default()).await else {
        return;
    };
    let mut r = Recorder::new(&agent);
    agent.push([ModelReply::Failed(
        "Model provider request failed (HTTP 400).".to_owned(),
    )]);
    turn(&mut agent, &mut r, "a failed reply", "Fail").await;
    agent.push([
        ModelReply::Error("timeout".to_owned()),
        ModelReply::Text("Recovered.".to_owned()),
    ]);
    turn(&mut agent, &mut r, "a retried timeout", "Retry").await;
    agent.push([ModelReply::Raw(vec![
        json!({ "type": "model_delta", "delta": { "type": "text_start", "contentIndex": 0 } }),
    ])]);
    turn(&mut agent, &mut r, "a stream that ends early", "Truncate").await;
    r.session(&agent);
    insta::assert_json_snapshot!("agent_model_failures", r.into_value());
}
