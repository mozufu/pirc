//! The node's side of the node link, with the test acting as the gateway:
//! what a real node sends when it registers, answers relayed requests, runs
//! its agent's model request through the gateway and reports the agent's
//! events. Every frame is also checked against `pirc-protocol`.

use std::time::{SystemTime, UNIX_EPOCH};

use pirc_conformance::{FakeGateway, LoneNode, NODE_ID, NODE_TOKEN, Transcript, USER};
use serde_json::{Value, json};

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_millis() as u64
}

fn sorted_keys(value: &Value) -> Vec<&String> {
    let mut keys: Vec<&String> = value.as_object().unwrap().keys().collect();
    keys.sort();
    keys
}

fn settled(frame: &Value) -> bool {
    frame["type"] == "event"
        && frame["event"]["type"] == "pi_event"
        && frame["event"]["data"]["type"] == "agent_settled"
}

/// Answer one agent request as the Gateway would.
async fn answer(link: &mut pirc_conformance::NodeLink, frame: &Value) {
    let args = &frame["args"];
    let result = match frame["op"].as_str() {
        Some("command.authority") => {
            json!({ "commandId": args["commandId"], "binding": args["binding"] })
        }
        _ => json!({ "owner": USER, "version": 2, "watermark": 0,
            "digest": null, "legacyProjection": "" }),
    };
    link.send(
        &json!({ "type": "agent_response", "requestId": frame["requestId"],
            "status": 200, "body": { "result": result } }),
    )
    .await;
}

/// The next frame satisfying `wanted`, answering the agent's own Gateway reads,
/// including requests the command receipt already passed over.
async fn recv_answering(
    link: &mut pirc_conformance::NodeLink,
    wanted: impl Fn(&Value) -> bool,
) -> Value {
    loop {
        if let Some(index) = link.skipped.iter().position(&wanted) {
            return link.skipped.remove(index);
        }
        if let Some(index) = link
            .skipped
            .iter()
            .position(|frame| frame["type"] == "agent_request")
        {
            let frame = link.skipped.remove(index);
            answer(link, &frame).await;
            continue;
        }
        let frame = link.recv().await;
        if frame["type"] == "agent_request" {
            answer(link, &frame).await;
            continue;
        }
        if wanted(&frame) {
            return frame;
        }
        link.skipped.push(frame);
    }
}

/// Send a request, answering the agent's Gateway reads until its response.
async fn request_answering(link: &mut pirc_conformance::NodeLink, id: &str, data: Value) -> Value {
    link.send(&json!({ "type": "request", "requestId": id, "data": data }))
        .await;
    loop {
        let frame = link.recv().await;
        if frame["type"] == "agent_request" {
            answer(link, &frame).await;
            continue;
        }
        if frame["type"] == "response" && frame["requestId"] == id {
            return frame;
        }
        link.skipped.push(frame);
    }
}

/// The secret-free catalog the gateway projects for nodes.
fn models() -> Value {
    json!({
        "providers": { "fake": {
            "api": "openai-completions",
            "baseUrl": "https://gateway.invalid",
            "headers": {},
            "compat": {},
            "models": [{ "id": "fake-model", "contextWindow": 100000, "maxTokens": 1000,
                "reasoning": true, "input": ["text"], "compat": {} }],
        } },
        "defaultModel": { "provider": "fake", "id": "fake-model", "thinking": "low" },
    })
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn node_side_link() {
    let gateway = FakeGateway::bind().await;
    let Some(node) = LoneNode::start(gateway.port()) else {
        return;
    };
    let mut t = Transcript::new(node.volatile());
    let mut link = gateway.accept().await;

    t.note(
        "handshake",
        json!({
            "x-pirc-node-id": link.header("x-pirc-node-id"),
            "authorization is the node token":
                link.header("authorization") == Some(format!("Bearer {NODE_TOKEN}").as_str()),
        }),
    );
    let register = link.recv().await;
    t.note("register", register);
    link.send(
        &json!({ "type": "registered", "nodeId": NODE_ID, "models": models(),
        "mirrors": {} }),
    )
    .await;

    let created = link
        .request(
            "request-1",
            json!({ "method": "POST", "url": "/api/session-creations/internal", "user": USER,
                "payload": { "workspaceId": "test" } }),
        )
        .await;
    t.note("create a session", created.clone());
    let session = created["data"]["body"]["session"]["id"]
        .as_str()
        .unwrap()
        .to_owned();

    let acquired = link
        .request(
            "request-2",
            json!({ "method": "POST", "url": format!("/api/sessions/{session}/control/acquire"),
                "user": USER, "payload": { "clientId": "browser" } }),
        )
        .await;
    t.note("acquire control", acquired.clone());
    let generation = acquired["data"]["body"]["lease"]["generation"].clone();

    let binding = json!({ "version": 1,
        "membership": { "revision": 1, "legacyWorkspaceId": "test" },
        "execution": { "generation": 1, "workspaceId": "test",
            "nodeId": NODE_ID, "modeId": "directory" } });
    let prompted = request_answering(
        &mut link,
        "request-3",
        json!({ "method": "POST", "url": format!("/api/sessions/{session}/commands"),
            "user": USER, "payload": { "commandId": "command-1", "clientId": "browser",
                "generation": generation, "commandEnvironment": binding,
                "payload": { "type": "prompt", "message": "Say hello" } } }),
    )
    .await;
    t.note("prompt", prompted);

    // The agent's model request, which the gateway runs for it.
    let start = recv_answering(&mut link, |frame| frame["type"] == "model_start").await;
    let request = &start["request"];
    let tools: Vec<&Value> = request["tools"]
        .as_array()
        .unwrap()
        .iter()
        .map(|tool| &tool["name"])
        .collect();
    t.note(
        "model request (system prompt and tool contracts belong to the agent port)",
        json!({
            "keys": sorted_keys(request),
            "providerName": request["providerName"],
            "modelId": request["modelId"],
            "thinking": request["thinking"],
            // The agent's own session id, not the node's.
            "sessionId": request["sessionId"],
            "messages": request["messages"],
            "tools": tools,
            "has a system prompt": request["systemPrompt"].as_str().is_some_and(|p| !p.is_empty()),
        }),
    );
    let id = start["requestId"].clone();
    let text = "Hello through the gateway.";
    for delta in [
        json!({ "type": "text_start", "contentIndex": 0 }),
        json!({ "type": "text_delta", "contentIndex": 0, "delta": "Hello through " }),
        json!({ "type": "text_delta", "contentIndex": 0, "delta": "the gateway." }),
        json!({ "type": "text_end", "contentIndex": 0, "content": text }),
    ] {
        link.send(&json!({ "type": "model_delta", "requestId": id, "delta": delta }))
            .await;
    }
    link.send(&json!({
        "type": "model_end",
        "requestId": id,
        "message": {
            "role": "assistant",
            "content": [{ "type": "text", "text": text }],
            "api": "openai-completions",
            "provider": "fake",
            "model": "fake-model",
            "usage": { "input": 60, "output": 10, "cacheRead": 40, "cacheWrite": 0,
                "totalTokens": 110 },
            "stopReason": "stop",
            "timestamp": now_ms(),
        },
    }))
    .await;

    link.skipped.clear();
    recv_answering(&mut link, settled).await;
    let events: Vec<Value> = link
        .skipped
        .iter()
        .filter(|frame| frame["type"] == "event")
        .cloned()
        .collect();
    t.note(
        "event frame",
        json!({
            "keys": sorted_keys(&events[0]),
            "event keys": sorted_keys(&events[0]["event"]),
            "sessionId is the node session":
                events.iter().all(|frame| frame["sessionId"] == session.as_str()),
        }),
    );
    let assistant = events
        .iter()
        .rev()
        .find(|frame| frame["event"]["data"]["type"] == "message_end")
        .map(|frame| frame["event"]["data"]["message"].clone());
    t.note("the agent's final message", json!(assistant));

    let snapshot = link
        .request(
            "request-4",
            json!({ "method": "GET", "url": format!("/api/sessions/{session}/snapshot"),
                "user": USER }),
        )
        .await;
    t.note("snapshot", snapshot["data"]["body"]["history"].clone());

    // Activity and mirror frames come on timers, so which of them arrive
    // during the run is not stable; only that they are well-formed (checked
    // as each was received).
    insta::assert_json_snapshot!("node_side_link", t.into_value());
}
