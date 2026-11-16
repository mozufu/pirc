//! The `/compact [instructions]` slash command (`agent/features/
//! compact.ts`, feature `compact`), with the test playing the agent's
//! node: a compaction with and without focus instructions, a new session,
//! a failing summarizer and a busy agent. The historical feature baseline
//! (docs/development/historical-records.md).

use pirc_conformance::{AgentOptions, AgentRun, Gate, ModelReply, Recorder};
use serde_json::json;

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

/// A slash command: its lines up to its response and the notification
/// that ends it.
async fn slash(agent: &mut AgentRun, r: &mut Recorder, step: &str, message: &str) {
    // A running agent takes commands as steering (a prompt is refused).
    let kind = if step == "while running" {
        "steer"
    } else {
        "prompt"
    };
    let id = agent
        .command(json!({ "type": kind, "message": message }))
        .await;
    let mut lines = Vec::new();
    let (mut answered, mut notified) = (false, false);
    while !(answered && notified) {
        let line = agent.next().await.expect("the agent exited");
        answered |= line["type"] == "response" && line["id"] == id.as_str();
        notified |= line["type"] == "extension_ui_request" && line["method"] == "notify";
        lines.push(line);
    }
    r.note(&format!("{step}: lines"), json!(lines));
}

/// A slash command, then the model requests it made.
async fn compact(agent: &mut AgentRun, r: &mut Recorder, step: &str, message: &str) {
    slash(agent, r, step, message).await;
    r.requests(&format!("{step}: model requests"), agent.take_requests());
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_compact_command() {
    let Some(mut agent) = AgentRun::start(
        AgentOptions {
            config: json!({ "features": { "compaction": { "keepRecentTokens": 1 } } }),
            ..AgentOptions::default()
        }
        .features("compact"),
    )
    .await
    else {
        return;
    };
    let mut r = Recorder::new(&agent);
    let commands = agent.call(json!({ "type": "get_commands" })).await;
    r.note("commands", commands);
    compact(&mut agent, &mut r, "a new session", "/compact").await;
    for (step, message) in [("first", "One"), ("second", "Two")] {
        agent.push([text(&format!("Reply to {message}."))]);
        turn(&mut agent, &mut r, step, message).await;
    }
    // A large reported usage: the notice formats the count for people.
    agent.push([ModelReply::Raw(vec![
        json!({ "type": "model_end", "message": {
        "role": "assistant", "content": [{ "type": "text", "text": "Reply to Three." }],
        "api": "openai-completions", "provider": "fake", "model": "fake-model",
        "usage": { "input": 1_234_000, "output": 567, "cacheRead": 0, "cacheWrite": 0,
            "totalTokens": 1_234_567 },
        "stopReason": "stop", "timestamp": 1 } }),
    ])]);
    turn(&mut agent, &mut r, "third", "Three").await;
    agent.push([text("## Goal\nCount.")]);
    compact(&mut agent, &mut r, "compact", "/compact").await;
    agent.push([text("Four.")]);
    turn(&mut agent, &mut r, "fourth", "Four").await;
    agent.push([text("## Goal\nCount, keeping the numbers.")]);
    compact(
        &mut agent,
        &mut r,
        "compact with instructions",
        "/compact   keep the numbers  ",
    )
    .await;
    agent.push([text("Five.")]);
    turn(&mut agent, &mut r, "fifth", "Five").await;
    agent.push([ModelReply::Failed(
        "Model provider request failed (HTTP 400).".to_owned(),
    )]);
    compact(&mut agent, &mut r, "a failing summary", "/compact").await;
    // Not while a run is going.
    let gate = Gate::new();
    agent.push([ModelReply::gated(&gate, text("Six."))]);
    let response = agent
        .call(json!({ "type": "prompt", "message": "Six" }))
        .await;
    r.note("a busy run: response", response);
    slash(&mut agent, &mut r, "while running", "/compact").await;
    gate.open();
    let events = agent.settle().await;
    r.turn("a busy run", &agent, events);
    r.session(&agent);
    insta::assert_json_snapshot!("agent_compact_command", r.into_value());
}
