//! The order of everything the agent writes, responses included: a command
//! that starts a run is answered after initial admission, including deferred
//! context hooks. Agent events retain their order; successful prompt responses
//! no longer precede the messages they acknowledge.

use pirc_conformance::{AgentOptions, AgentRun, ModelReply, Recorder};
use serde_json::{Value, json};

/// A line reduced to what identifies it in the order.
fn label(line: &Value) -> Value {
    match line["type"].as_str() {
        Some("response") => json!(format!(
            "response {} {}",
            line["command"].as_str().unwrap_or_default(),
            line["success"]
        )),
        Some("message_start" | "message_end") => json!(format!(
            "{} {}",
            line["type"].as_str().unwrap_or_default(),
            line["message"]["role"].as_str().unwrap_or_default()
        )),
        Some("message_update") => json!(format!(
            "message_update {}",
            line["assistantMessageEvent"]["type"]
                .as_str()
                .unwrap_or_default()
        )),
        Some(kind) => json!(kind),
        None => line.clone(),
    }
}

async fn lines_until_settled(agent: &mut AgentRun) -> Vec<Value> {
    agent
        .until(|line| line["type"] == "agent_settled")
        .await
        .iter()
        .map(label)
        .collect()
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_line_order() {
    let Some(mut agent) = AgentRun::start(AgentOptions::default()).await else {
        return;
    };
    let mut r = Recorder::new(&agent);
    agent.push([ModelReply::Text("Hi.".to_owned())]);
    agent
        .command(json!({ "type": "prompt", "message": "Hello" }))
        .await;
    let order = lines_until_settled(&mut agent).await;
    r.note("prompt while idle", json!(order));
    agent.push([ModelReply::Text("Steered.".to_owned())]);
    agent
        .command(json!({ "type": "steer", "message": "Now" }))
        .await;
    let order = lines_until_settled(&mut agent).await;
    r.note("steer while idle", json!(order));
    agent.push([ModelReply::Text("Delivered.".to_owned())]);
    agent
        .command(
            json!({ "type": "deliver", "message": { "customType": "note",
            "content": "From the gateway" } }),
        )
        .await;
    let order = lines_until_settled(&mut agent).await;
    r.note("deliver while idle", json!(order));
    agent.push([ModelReply::Hang("Partial".to_owned())]);
    agent
        .command(json!({ "type": "prompt", "message": "Long" }))
        .await;
    let mut order: Vec<Value> = agent
        .until(|line| line["type"] == "message_update")
        .await
        .iter()
        .map(label)
        .collect();
    agent.command(json!({ "type": "abort" })).await;
    let mut rest: Vec<Value> = agent
        .until(|line| line["type"] == "response" && line["command"] == "abort")
        .await
        .iter()
        .map(label)
        .collect();
    order.append(&mut rest);
    r.note("abort while streaming", json!(order));
    insta::assert_json_snapshot!("agent_line_order", r.into_value());
}

/// Prompt acknowledgement waits for the `beforePrompt` hook and persisted
/// user message. Deliver keeps its existing synchronous acknowledgement.
#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_line_order_with_hooks() {
    let options = AgentOptions {
        config: json!({
            "hooks": { "beforePrompt": [{ "command": "echo PROMPT-HOOK-CONTEXT" }] },
        }),
        ..AgentOptions::default()
    };
    let Some(mut agent) = AgentRun::start(options).await else {
        return;
    };
    let mut r = Recorder::new(&agent);
    agent.push([ModelReply::Text("Delivered.".to_owned())]);
    agent
        .command(
            json!({ "type": "deliver", "message": { "customType": "note",
            "content": "From the gateway" } }),
        )
        .await;
    let order = lines_until_settled(&mut agent).await;
    r.note("deliver while idle", json!(order));
    agent.push([ModelReply::Text("Hi.".to_owned())]);
    agent
        .command(json!({ "type": "prompt", "message": "Hello" }))
        .await;
    let order = lines_until_settled(&mut agent).await;
    let position = |expected: &str| {
        order
            .iter()
            .position(|line| line == expected)
            .unwrap_or_else(|| panic!("missing {expected}: {order:?}"))
    };
    assert!(position("message_end user") < position("response prompt true"));
    assert!(position("turn_start") < position("response prompt true"));
    assert!(position("response prompt true") < position("message_start assistant"));
    r.note("prompt while idle", json!(order));
    insta::assert_json_snapshot!("agent_line_order_with_hooks", r.into_value());
}
