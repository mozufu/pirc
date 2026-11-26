//! Shared by the `node_link_side*` scenarios: the test plays the gateway
//! for a real node ([`FakeGateway`] + [`LoneNode`]), relays requests to it
//! and answers its agents' model requests by hand.

#![allow(dead_code)]

use std::time::{Duration, SystemTime, UNIX_EPOCH};

use pirc_conformance::{NODE_ID, NodeLink, USER};
use serde_json::{Value, json};

/// How long a scenario waits for any one frame it expects.
pub const DEADLINE: Duration = Duration::from_secs(30);

pub fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_millis() as u64
}

pub fn sorted_keys(value: &Value) -> Vec<String> {
    let mut keys: Vec<String> = value
        .as_object()
        .map(|object| object.keys().cloned().collect())
        .unwrap_or_default();
    keys.sort();
    keys
}

/// A secret-free catalog with one provider and model, which is the default.
pub fn models(provider: &str, model: &str, thinking: &str) -> Value {
    json!({
        "providers": { provider: provider_entry(model) },
        "defaultModel": { "provider": provider, "id": model, "thinking": thinking },
    })
}

pub fn provider_entry(model: &str) -> Value {
    json!({
        "api": "openai-completions",
        "baseUrl": "https://gateway.invalid",
        "headers": {},
        "compat": {},
        "models": [{ "id": model, "contextWindow": 100000, "maxTokens": 1000,
            "reasoning": true, "input": ["text"], "compat": {} }],
    })
}

pub fn registered(models: Value, mirrors: Value) -> Value {
    json!({ "type": "registered", "nodeId": NODE_ID, "models": models, "mirrors": mirrors })
}

/// The environment a fake Gateway admits this fixture's commands in.
pub fn binding() -> Value {
    json!({ "version": 1,
        "membership": { "revision": 1, "legacyWorkspaceId": "test" },
        "execution": { "generation": 1, "workspaceId": "test",
            "nodeId": NODE_ID, "modeId": "directory" } })
}

/// `agent_settled` of `session`.
pub fn settled_in(session: &str) -> impl Fn(&Value) -> bool + '_ {
    move |frame: &Value| {
        frame["type"] == "event"
            && frame["sessionId"] == session
            && frame["event"]["type"] == "pi_event"
            && frame["event"]["data"]["type"] == "agent_settled"
    }
}

/// The gateway's end of one link, numbering its relayed requests.
pub struct Gateway {
    pub link: NodeLink,
    requests: usize,
}

impl Gateway {
    pub fn new(link: NodeLink) -> Self {
        Self { link, requests: 0 }
    }

    pub fn next_id(&mut self) -> String {
        self.requests += 1;
        format!("request-{}", self.requests)
    }

    /// Relay a request as user [`USER`] and return the node's `response` frame.
    pub async fn ask(&mut self, method: &str, url: &str, payload: Option<Value>) -> Value {
        let mut data = json!({ "method": method, "url": url, "user": USER });
        if let Some(payload) = payload {
            data["payload"] = payload;
        }
        self.relay(data).await
    }

    /// Relay `data` (a whole `request` frame's `data`).
    pub async fn relay(&mut self, data: Value) -> Value {
        let id = self.next_id();
        self.link
            .send(&json!({ "type": "request", "requestId": id, "data": data }))
            .await;
        // Prompt admission can ask Gateway for authority before acknowledging
        // the command. Service those reads while awaiting the response too.
        self.wait(|frame| frame["type"] == "response" && frame["requestId"] == id)
            .await
    }

    /// A relayed request and its answer, for a transcript.
    pub async fn exchange(&mut self, data: Value) -> Value {
        let response = self.relay(data.clone()).await;
        json!({ "request": data, "response": without_details(&response["data"]) })
    }

    /// Create a session in workspace `test` through the Node's internal entry
    /// (the test plays the Gateway), take control and return
    /// `(session id, lease generation)`.
    pub async fn session(&mut self) -> (String, Value) {
        let created = self
            .ask(
                "POST",
                "/api/session-creations/internal",
                Some(json!({ "workspaceId": "test" })),
            )
            .await;
        let session = created["data"]["body"]["session"]["id"]
            .as_str()
            .unwrap_or_else(|| panic!("no session: {created}"))
            .to_owned();
        let acquired = self
            .ask(
                "POST",
                &format!("/api/sessions/{session}/control/acquire"),
                Some(json!({ "clientId": "browser" })),
            )
            .await;
        (
            session,
            acquired["data"]["body"]["lease"]["generation"].clone(),
        )
    }

    /// Send a command; the node's `response` frame.
    pub async fn command(
        &mut self,
        session: &str,
        generation: &Value,
        command_id: &str,
        payload: Value,
    ) -> Value {
        let plain_stop = payload["type"] == json!("stop");
        let stop = matches!(payload["type"].as_str(), Some("stop" | "stop_transition"));
        let mut body = json!({ "commandId": command_id, "clientId": "browser",
            "payload": payload });
        if !plain_stop {
            body["generation"] = generation.clone();
        }
        if !stop {
            body["commandEnvironment"] = binding();
        }
        self.ask(
            "POST",
            &format!("/api/sessions/{session}/commands"),
            Some(body),
        )
        .await
    }

    pub async fn prompt(
        &mut self,
        session: &str,
        generation: &Value,
        command_id: &str,
        message: &str,
    ) -> Value {
        self.command(
            session,
            generation,
            command_id,
            json!({ "type": "prompt", "message": message }),
        )
        .await
    }

    /// The next frame satisfying `wanted` (earlier ones go to
    /// `link.skipped`), within [`DEADLINE`] in all: the node's heartbeats
    /// would otherwise keep a wait alive.
    pub async fn wait(&mut self, wanted: impl Fn(&Value) -> bool) -> Value {
        let before = self.link.skipped.len();
        let waiting = async {
            loop {
                let frame = if let Some(i) = self.link.skipped.iter().position(|f| {
                    f["type"] == "agent_request"
                        && [
                            "workspace.mirrorState",
                            "history.authority",
                            "command.authority",
                        ]
                        .contains(&f["op"].as_str().unwrap_or(""))
                }) {
                    self.link.skipped.remove(i)
                } else {
                    self.link.recv().await
                };
                if frame["type"] == "agent_request"
                    && ["workspace.mirrorState", "history.authority"]
                        .contains(&frame["op"].as_str().unwrap_or(""))
                {
                    self.link.send(&json!({"type":"agent_response","requestId":frame["requestId"],"status":200,"body":{"result":{"owner":USER,"version":2,"watermark":0,"digest":null,"legacyProjection":""}}})).await;
                    continue;
                }
                if frame["type"] == "agent_request" && frame["op"] == "command.authority" {
                    let args = &frame["args"];
                    self.link
                        .send(
                            &json!({"type":"agent_response","requestId":frame["requestId"],
                        "status":200,"body":{"result":{"commandId":args["commandId"],
                            "binding":args["binding"]}}}),
                        )
                        .await;
                    continue;
                }
                if wanted(&frame) {
                    return frame;
                }
                self.link.skipped.push(frame);
            }
        };
        match tokio::time::timeout(DEADLINE, waiting).await {
            Ok(frame) => frame,
            Err(_) => {
                let got: Vec<String> = self
                    .link
                    .skipped
                    .iter()
                    .skip(before)
                    .map(|frame| {
                        let mut text = frame.to_string();
                        text.truncate(600);
                        text
                    })
                    .collect();
                panic!(
                    "timed out waiting for a node frame; meanwhile:\n{}",
                    got.join("\n")
                )
            }
        }
    }

    /// The earliest frame satisfying `wanted` that has already arrived
    /// (taken out of `link.skipped`), else the next one.
    pub async fn take(&mut self, wanted: impl Fn(&Value) -> bool) -> Value {
        if let Some(index) = self.link.skipped.iter().position(&wanted) {
            return self.link.skipped.remove(index);
        }
        self.wait(wanted).await
    }

    /// The next `model_start` (of any session).
    pub async fn model_start(&mut self) -> Value {
        self.wait(|frame| frame["type"] == "model_start").await
    }

    async fn deltas(&mut self, id: &Value, deltas: Vec<Value>) {
        for delta in deltas {
            self.link
                .send(&json!({ "type": "model_delta", "requestId": id, "delta": delta }))
                .await;
        }
    }

    async fn end(&mut self, id: &Value, start: &Value, content: Vec<Value>, stop: &str) {
        let request = &start["request"];
        self.link
            .send(&json!({
                "type": "model_end",
                "requestId": id,
                "message": {
                    "role": "assistant",
                    "content": content,
                    "api": "openai-completions",
                    "provider": request["providerName"],
                    "model": request["modelId"],
                    "usage": { "input": 60, "output": 10, "cacheRead": 0, "cacheWrite": 0,
                        "totalTokens": 70 },
                    "stopReason": stop,
                    "timestamp": now_ms(),
                },
            }))
            .await;
    }

    /// Answer the model request `start` with `text`.
    pub async fn reply_text(&mut self, start: &Value, text: &str) {
        let id = start["requestId"].clone();
        self.deltas(
            &id,
            vec![
                json!({ "type": "text_start", "contentIndex": 0 }),
                json!({ "type": "text_delta", "contentIndex": 0, "delta": text }),
                json!({ "type": "text_end", "contentIndex": 0, "content": text }),
            ],
        )
        .await;
        self.end(
            &id,
            start,
            vec![json!({ "type": "text", "text": text })],
            "stop",
        )
        .await;
    }

    /// Answer the model request `start` with one tool call.
    pub async fn reply_tool(&mut self, start: &Value, call_id: &str, name: &str, args: Value) {
        let id = start["requestId"].clone();
        let call = json!({ "type": "toolCall", "id": call_id, "name": name, "arguments": args });
        self.deltas(
            &id,
            vec![
                json!({ "type": "toolcall_start", "contentIndex": 0, "id": call_id,
                    "toolName": name }),
                json!({ "type": "toolcall_delta", "contentIndex": 0,
                    "delta": args.to_string() }),
                json!({ "type": "toolcall_end", "contentIndex": 0, "toolCall": call }),
            ],
        )
        .await;
        self.end(&id, start, vec![call], "toolUse").await;
    }
}

/// The last message of a model request (what the agent just added).
pub fn last_message(start: &Value) -> Value {
    start["request"]["messages"]
        .as_array()
        .and_then(|messages| messages.last())
        .cloned()
        .unwrap_or(Value::Null)
}

/// A relayed response without a validation error's `details` (the
/// validation library's own report, left out of transcripts as in M0).
pub fn without_details(data: &Value) -> Value {
    let mut data = data.clone();
    if let Some(error) = data["body"]["error"].as_object_mut() {
        error.remove("details");
    }
    data
}

/// The `activity` entry of `session` in an `activity` frame.
pub fn activity_of<'a>(frame: &'a Value, session: &str) -> Option<&'a Value> {
    if frame["type"] != "activity" {
        return None;
    }
    frame["sessions"]
        .as_array()?
        .iter()
        .find(|entry| entry["id"] == session)
}
