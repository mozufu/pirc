//! A directory workspace's main agent reads the user-approved USER memory
//! through `assistant.context` (feature `assistant`), frozen for the run and
//! without the assistant's memory tools. The test plays the agent's node and
//! gateway.

mod memory_support;

use memory_support::*;
use pirc_conformance::{AgentOptions, AgentRun};
use serde_json::{Value, json};
use std::time::{Duration, Instant};

fn ok(result: Value) -> Value {
    json!({ "ok": true, "result": result })
}

/// Queue gateway answers for `op`, used in order.
fn answer(agent: &AgentRun, op: &str, replies: impl IntoIterator<Item = Value>) {
    agent
        .answers
        .lock()
        .unwrap()
        .gateway_queue
        .entry(op.to_owned())
        .or_default()
        .extend(replies);
}

/// What the node sets for an agent in a directory workspace.
fn coding() -> AgentOptions {
    let mut options = AgentOptions::default().features("assistant");
    options
        .env
        .push(("PIRC_GATEWAY".to_owned(), "1".to_owned()));
    options
}

/// The gateway's answer to a coding session: USER only.
fn user_only(user: Value) -> Value {
    ok(json!({ "enabled": true, "user": user, "notes": null, "workspaces": null }))
}

/// A coding session starts with the approved USER entries, frozen, and
/// none of the assistant's tools.
#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_assistant_coding_session() {
    let Some(mut agent) = AgentRun::start(coding()).await else {
        return;
    };
    let mut log = Log::new(&agent);
    answer(
        &agent,
        "assistant.context",
        [
            user_only(json!([
                { "id": "u11111111", "content": "Prefers short answers.", "revision": 2 },
                { "id": "u22222222", "content": "Writes commit messages in English.", "revision": 1 },
            ])),
            user_only(json!([{ "id": "u33333333", "content": "Changed later.", "revision": 1 }])),
        ],
    );
    agent.push([text("Hi."), text("Again.")]);
    log.turn(&mut agent, "prompt", "hello").await;
    // Frozen: the second run neither asks nor shows the change.
    log.turn(&mut agent, "again", "more").await;
    log.session(&agent);
    insta::assert_json_snapshot!("agent_assistant_coding_session", log.into_value());
}

/// An unreachable gateway never holds a coding session up: it runs without
/// USER, the user is told once, and a later run loads it.
#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_assistant_coding_session_unreachable() {
    let Some(mut agent) = AgentRun::start(coding()).await else {
        return;
    };
    let mut log = Log::new(&agent);
    let offline = json!({ "ok": false, "error": { "status": 503, "code": "gateway_offline",
        "message": "offline" } });
    answer(
        &agent,
        "assistant.context",
        [
            offline.clone(),
            offline,
            user_only(
                json!([{ "id": "u11111111", "content": "Prefers short answers.",
                "revision": 2 }]),
            ),
        ],
    );
    agent.push([text("a"), text("b"), text("c")]);
    log.turn(&mut agent, "unreachable", "hello").await;
    log.turn(&mut agent, "still unreachable: not told again", "again")
        .await;
    log.turn(&mut agent, "back", "and now?").await;
    log.session(&agent);
    insta::assert_json_snapshot!(
        "agent_assistant_coding_session_unreachable",
        log.into_value()
    );
}

/// A turn of a coding session whose `assistant.context` gets no answer:
/// how long the model request came after the context request.
async fn held_turn(log: &mut Log, agent: &mut AgentRun, step: &str, message: &str) -> Duration {
    let id = agent
        .command(json!({ "type": "prompt", "message": message }))
        .await;
    // Admission waits for this context hook, so `call` would return only after
    // the timeout. Observe the request as it arrives, before awaiting the ACK.
    let mut events = agent
        .until(|line| line["type"] == "gateway_request" && line["op"] == "assistant.context")
        .await;
    let asked = Instant::now();
    agent.wait_for_request().await;
    let waited = asked.elapsed();
    events.extend(agent.until(|line| line["type"] == "agent_settled").await);
    let response = events
        .iter()
        .find(|line| line["type"] == "response" && line["id"] == id)
        .expect("prompt admission response");
    assert_eq!(response["success"], true);
    log.note(&format!("{step}: response"), response.clone());
    let events: Vec<Value> = events
        .into_iter()
        .filter(|line| line["type"] != "response")
        .collect();
    log.note(&format!("{step}: events"), json!(events));
    tokio::time::sleep(log.worker_pause).await;
    log.requests(agent, step);
    waited
}

/// A gateway that never answers holds each run of a coding session up for
/// the 3 s `assistant.context` timeout only: it runs without USER, the user
/// is told once, and the next run asks again.
#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_assistant_coding_session_context_timeout() {
    let Some(mut agent) = AgentRun::start(coding()).await else {
        return;
    };
    let mut log = Log::new(&agent);
    answer(
        &agent,
        "assistant.context",
        [json!({ "hold": true }), json!({ "hold": true })],
    );
    agent.push([text("a"), text("b")]);
    let first = held_turn(&mut log, &mut agent, "timed out", "hello").await;
    let second = held_turn(
        &mut log,
        &mut agent,
        "timed out again: not told again",
        "again",
    )
    .await;
    for waited in [first, second] {
        assert!(
            (Duration::from_millis(2500)..Duration::from_secs(10)).contains(&waited),
            "the model request came {waited:?} after the context request"
        );
    }
    log.session(&agent);
    let value = log.into_value();
    let text = value.to_string();
    assert!(
        text.contains("Unavailable; cached USER preferences are withheld."),
        "missing explicit unavailable state: {value:#}"
    );
    assert!(
        !text.contains("Prefers short answers."),
        "stale USER content was injected: {value:#}"
    );
    assert_eq!(
        text.matches("Your USER preferences could not be refreshed")
            .count(),
        1,
        "{value:#}"
    );
    assert_eq!(
        text.matches(r#""op":"assistant.context""#).count(),
        2,
        "{value:#}"
    );
    insta::assert_json_snapshot!("agent_assistant_coding_session_context_timeout", value);
}

/// A coding session with no USER entries freezes that too.
#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_assistant_coding_session_without_user() {
    let Some(mut agent) = AgentRun::start(coding()).await else {
        return;
    };
    let mut log = Log::new(&agent);
    answer(
        &agent,
        "assistant.context",
        [
            user_only(json!([])),
            user_only(json!([{ "id": "u1", "content": "Late.", "revision": 1 }])),
        ],
    );
    agent.push([text("Hi."), text("Again.")]);
    log.turn(&mut agent, "prompt", "hello").await;
    log.turn(&mut agent, "again", "more").await;
    log.session(&agent);
    insta::assert_json_snapshot!(
        "agent_assistant_coding_session_without_user",
        log.into_value()
    );
}
