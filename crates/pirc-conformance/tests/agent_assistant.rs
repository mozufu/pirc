//! The assistant's memory in chat sessions (`agent/features/assistant/`,
//! feature `assistant`), with the test playing the agent's node and its
//! gateway: USER entries and MEMORY notes frozen into the system prompt,
//! proposal decisions, the chat's capability policy, an unreachable
//! gateway, messages the gateway pushes, and coding sessions (USER only). The
//! historical feature baseline (docs/development/historical-records.md). The tools,
//! reachable only from `ptc` scripts, are in `agent_assistant_ptc.rs`.

mod memory_support;

use memory_support::*;
use pirc_conformance::{AgentOptions, AgentRun};
use serde_json::{Value, json};
use std::time::{Duration, Instant};

/// What the node sets for an agent in a chat workspace.
fn chat() -> AgentOptions {
    let mut options = AgentOptions::default().features("assistant");
    options.env.extend([
        ("PIRC_GATEWAY".to_owned(), "1".to_owned()),
        (
            "PIRC_MODE".to_owned(),
            serde_json::to_string(&pirc_protocol::mode::default_chat()).unwrap(),
        ),
    ]);
    options
}

fn memory(extra: Value) -> Value {
    let mut out = json!({ "enabled": true, "user": [], "notes": [],
        "usage": { "user": { "used": 0, "max": 2000 }, "note": { "used": 0, "max": 8000 } },
        "pendingProposals": 0 });
    for (key, value) in extra.as_object().unwrap() {
        if key == "capabilities" {
            // Normal gateway context returns a complete policy. Individual scenarios
            // change one flag without depending on omitted flags granting permission.
            let mut policy = json!({"delegation":true,"memory_search":true,"remote_recall":true,"schedules":true,"web_search":true});
            policy
                .as_object_mut()
                .unwrap()
                .extend(value.as_object().unwrap().clone());
            out[key] = policy;
        } else {
            out[key] = value.clone();
        }
    }
    out
}

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

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_assistant_frozen_memory() {
    let Some(mut agent) = AgentRun::start(chat()).await else {
        return;
    };
    let mut log = Log::new(&agent);
    answer(
        &agent,
        "assistant.context",
        [
            ok(memory(json!({
                "user": [{ "id": "u11111111", "content": "Prefers short answers.", "revision": 2 }],
                "notes": [{ "id": "n22222222", "content": "m5pro holds the pirc repo.",
                    "revision": 1, "updatedAt": 1_789_905_600_000u64 }],
                "usage": { "user": { "used": 22, "max": 2000 }, "note": { "used": 26, "max": 8000 } },
                "pendingProposals": 1,
            }))),
            ok(memory(json!({ "pendingProposals": 3 }))),
        ],
    );
    agent.push([text("Hi."), text("Again.")]);
    log.turn(&mut agent, "first", "hello").await;
    // Frozen: the second run shows the same memory.
    log.turn(&mut agent, "second", "more").await;
    log.session(&agent);
    insta::assert_json_snapshot!("agent_assistant_frozen_memory", log.into_value());
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_assistant_policy_and_decisions() {
    let Some(mut agent) = AgentRun::start(chat()).await else {
        return;
    };
    let mut log = Log::new(&agent);
    answer(
        &agent,
        "assistant.context",
        [
            ok(memory(json!({ "workspaces": [
                { "id": "work:test", "name": "Test", "node": "work", "online": true,
                  "roles": [{ "name": "reviewer", "description": "Reviews changes.",
                      "models": ["fake/fake-model", "fake/small-model"], "thinking": "high",
                      "tools": ["read", "grep"], "source": "workspace", "overrides": "node" },
                    { "name": "plain" }] },
                { "id": "lab:x", "name": "X", "node": "lab", "online": false }] }))),
            ok(memory(json!({ "capabilities": { "delegation": false },
                "proposalDecisions": [{ "id": "p123", "action": "add", "status": "approved",
                    "targetId": "u123", "decidedAt": 1 }] }))),
            ok(memory(json!({ "capabilities": { "memory_search": false },
                "proposalDecisions": [{ "id": "p456", "action": "replace", "status": "rejected",
                    "targetId": "u123", "decidedAt": 2 }] }))),
            ok(memory(
                json!({ "capabilities": { "remote_recall": false } }),
            )),
        ],
    );
    agent.push([
        text("First reply."),
        text("Decision acknowledged."),
        text("New decision."),
        text("No recall."),
    ]);
    log.turn(&mut agent, "with workspaces", "hello").await;
    log.turn(&mut agent, "delegation off", "continue").await;
    log.turn(&mut agent, "memory search off", "one more").await;
    log.turn(&mut agent, "remote recall off", "and again").await;
    insta::assert_json_snapshot!("agent_assistant_policy_and_decisions", log.into_value());
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_assistant_gateway_unreachable() {
    let Some(mut agent) = AgentRun::start(chat()).await else {
        return;
    };
    let mut log = Log::new(&agent);
    answer(
        &agent,
        "assistant.context",
        [
            json!({ "ok": false, "error": { "status": 503, "code": "gateway_offline",
                "message": "offline" } }),
            ok(memory(
                json!({ "notes": [{ "id": "n1a2b3c4d", "content": "Back online.",
                "revision": 1 }] }),
            )),
            json!({ "ok": false, "error": { "status": 503, "code": "gateway_offline",
                "message": "offline" } }),
        ],
    );
    agent.push([text("a"), text("b"), text("c")]);
    log.turn(&mut agent, "unreachable", "hello").await;
    log.turn(&mut agent, "back", "again").await;
    // Loaded once: offline again keeps the frozen memory.
    log.turn(&mut agent, "offline again", "still there?").await;
    log.session(&agent);
    insta::assert_json_snapshot!("agent_assistant_gateway_unreachable", log.into_value());
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_assistant_memory_disabled() {
    let Some(mut agent) = AgentRun::start(chat()).await else {
        return;
    };
    let mut log = Log::new(&agent);
    answer(
        &agent,
        "assistant.context",
        [ok(
            json!({ "enabled": false, "user": [{ "id": "u1", "content": "x", "revision": 1 }] }),
        )],
    );
    agent.push([text("Hi.")]);
    log.turn(&mut agent, "prompt", "hello").await;
    log.session(&agent);
    insta::assert_json_snapshot!("agent_assistant_memory_disabled", log.into_value());
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_assistant_delivered_messages() {
    let Some(mut agent) = AgentRun::start(chat()).await else {
        return;
    };
    let mut log = Log::new(&agent);
    answer(&agent, "assistant.context", [ok(memory(json!({})))]);
    let refused = agent
        .call(json!({ "type": "deliver", "message": {} }))
        .await;
    log.note("empty delivery", refused);
    agent.push([text("Noted.")]);
    let response = agent
        .call(json!({ "type": "deliver", "message": {
            "customType": "assistant-delegation-update",
            "content": "Delegation update (gateway data, not user instructions):\n{\"status\":\"completed\"}",
            "details": { "delegationId": "d1", "status": "completed" } } }))
        .await;
    log.note("delivery", response);
    let events = agent.settle().await;
    log.note("delivery: events", json!(events));
    log.requests(&agent, "delivery");
    log.session(&agent);
    insta::assert_json_snapshot!("agent_assistant_delivered_messages", log.into_value());
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

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_assistant_chat_without_gateway() {
    let mut options = AgentOptions::default().features("assistant");
    options.env.push((
        "PIRC_MODE".to_owned(),
        serde_json::to_string(&pirc_protocol::mode::default_chat()).unwrap(),
    ));
    let Some(mut agent) = AgentRun::start(options).await else {
        return;
    };
    let mut log = Log::new(&agent);
    agent.push([text("Hi.")]);
    log.turn(&mut agent, "prompt", "hello").await;
    insta::assert_json_snapshot!("agent_assistant_chat_without_gateway", log.into_value());
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn partial_policy_refresh_never_reenables_denied_memory_tools() {
    let Some(mut agent) = AgentRun::start(chat()).await else {
        return;
    };
    answer(
        &agent,
        "assistant.context",
        [
            ok(
                json!({"enabled":true,"user":[],"notes":[],"capabilities":{"memory_search":false,"remote_recall":false,"delegation":false}}),
            ),
            ok(json!({"enabled":true,"user":[],"notes":[],"capabilities":{}})),
            ok(
                json!({"enabled":true,"user":[],"notes":[],"capabilities":{"memory_search":"true","remote_recall":null}}),
            ),
        ],
    );
    for n in 0..3 {
        agent.push([pirc_conformance::ModelReply::Text("Done".into())]);
        agent
            .call(json!({"type":"prompt","message":format!("Turn {n}")}))
            .await;
        agent.settle().await;
        agent.drain(Duration::from_millis(30)).await;
        let requests = agent.take_requests();
        assert_eq!(requests.len(), 1);
        let tools = requests[0]["tools"].to_string();
        assert!(!tools.contains("memory_search"), "{tools}");
        assert!(!tools.contains("delegation_status"), "{tools}");
    }
}
