//! Starting a conversation through the only creation path clients have:
//! prepare, accept, materialize, dispatch and, for a real Node, wait for the
//! first run to settle. [`FirstSend::start_idle`] fences the first message with
//! a Stop instead, for scenarios that need an empty conversation.

use std::time::{Duration, Instant};

use serde_json::{Value, json};

use crate::client::{Api, Response, WebSocket};
use crate::{WORKSPACE_ID, browser_headers};

/// How long the helper waits for a Node to finish the first run.
const DEADLINE: Duration = Duration::from_secs(30);

/// A conversation created through first-send, with control held.
pub struct Started {
    pub id: String,
    pub base: String,
    pub client_id: String,
    pub generation: Value,
    /// The dispatch response, recorded by tests that show how the session was made.
    pub response: Response,
}

/// Builder for [`FirstSend`].
pub struct FirstSend<'a> {
    api: &'a Api,
    headers: Vec<(&'static str, String)>,
    workspace: String,
    operation: String,
    message: String,
    model: Option<(String, String)>,
    thinking: Option<String>,
    client_id: String,
}

impl<'a> FirstSend<'a> {
    /// A conversation in [`WORKSPACE_ID`] for the browser behind `headers`.
    pub fn new(api: &'a Api, headers: &[(&'static str, String)]) -> Self {
        Self {
            api,
            headers: headers.to_vec(),
            workspace: WORKSPACE_ID.to_owned(),
            operation: "first-send".to_owned(),
            message: "Conformance first message.".to_owned(),
            model: None,
            thinking: None,
            client_id: "browser".to_owned(),
        }
    }

    /// The browser identity [`browser_headers`] sends.
    pub fn browser(api: &'a Api) -> Self {
        Self::new(api, &browser_headers())
    }

    pub fn workspace(mut self, workspace: impl Into<String>) -> Self {
        self.workspace = workspace.into();
        self
    }

    /// The submission identity; unique per owner and cluster.
    pub fn operation(mut self, operation: impl Into<String>) -> Self {
        self.operation = operation.into();
        self
    }

    pub fn message(mut self, message: impl Into<String>) -> Self {
        self.message = message.into();
        self
    }

    pub fn model(mut self, provider: impl Into<String>, id: impl Into<String>) -> Self {
        self.model = Some((provider.into(), id.into()));
        self
    }

    pub fn thinking(mut self, thinking: impl Into<String>) -> Self {
        self.thinking = Some(thinking.into());
        self
    }

    /// The control-lease client id (default `browser`).
    pub fn client(mut self, client: impl Into<String>) -> Self {
        self.client_id = client.into();
        self
    }

    /// Create the conversation and wait for its first run to settle.
    pub async fn start(self) -> Started {
        let (api, headers, message) =
            (self.api.clone(), self.headers.clone(), self.message.clone());
        let started = self.dispatch(false).await;
        wait_for_run(&api, &headers, &started.base, &message).await;
        started
    }

    /// Create the conversation and fence the first message with a Stop, so the
    /// session is usable immediately and no model is called.
    pub async fn start_idle(self) -> Started {
        let (api, headers, operation) = (
            self.api.clone(),
            self.headers.clone(),
            self.operation.clone(),
        );
        let started = self.dispatch(true).await;
        wait_for_state(
            &api,
            &headers,
            &operation,
            &["stopped"],
            "the first message to be fenced",
        )
        .await;
        started
    }

    async fn dispatch(self, stop_first: bool) -> Started {
        let path = format!("/api/conversation-submissions/{}", self.operation);
        let mut submission = json!({
            "workspaceId": self.workspace,
            "message": self.message,
            "attachments": [],
        });
        if let Some((provider, id)) = &self.model {
            submission["model"] = json!({ "provider": provider, "id": id });
        }
        if let Some(thinking) = &self.thinking {
            submission["thinking"] = json!(thinking);
        }
        let prepared = self
            .send(
                "POST",
                "/api/conversation-submissions/prepare",
                Some(json!({ "operationId": self.operation, "submission": submission })),
            )
            .await;
        let id = prepared["preparation"]["sessionId"]
            .as_str()
            .unwrap_or_else(|| panic!("first send prepared no session: {prepared}"))
            .to_owned();
        let base = format!("/api/sessions/{id}");
        self.send("POST", &format!("{path}/accept"), None).await;
        let ready = self
            .send("POST", &format!("{path}/materialize"), None)
            .await;
        assert_eq!(
            ready["preparation"]["state"], "ready",
            "first send did not materialize: {ready}"
        );
        let lease = self
            .send(
                "POST",
                &format!("{base}/control/acquire"),
                Some(json!({ "clientId": self.client_id })),
            )
            .await;
        let generation = lease["lease"]["generation"].clone();
        if stop_first {
            let stopped = self
                .api
                .send(
                    "POST",
                    &format!("{base}/commands"),
                    &self.headers,
                    Some(json!({
                        "commandId": format!("{}-stop", self.operation),
                        "clientId": self.client_id,
                        "generation": generation,
                        "payload": { "type": "stop" },
                    })),
                )
                .await;
            assert!(
                matches!(stopped.status, 200 | 202),
                "first-send Stop was refused: {} {}",
                stopped.status,
                stopped.body
            );
        }
        let response = self
            .api
            .send(
                "POST",
                &format!("{path}/dispatch"),
                &self.headers,
                Some(json!({ "clientId": self.client_id, "generation": generation })),
            )
            .await;
        assert_eq!(
            response.status, 200,
            "first-send dispatch failed: {} {}",
            response.status, response.body
        );
        if !stop_first {
            wait_for_state(
                self.api,
                &self.headers,
                &self.operation,
                &["admitted"],
                "the first message to be admitted",
            )
            .await;
        }
        // The tests take control themselves; keeping the helper's lease would
        // refuse their acquire with another client id.
        self.api
            .send(
                "POST",
                &format!("{base}/control/release"),
                &self.headers,
                Some(json!({ "clientId": self.client_id, "generation": generation })),
            )
            .await;
        Started {
            id,
            base,
            client_id: self.client_id,
            generation,
            response,
        }
    }

    async fn send(&self, method: &str, path: &str, body: Option<Value>) -> Value {
        let response = self.api.send(method, path, &self.headers, body).await;
        assert!(
            (200..300).contains(&response.status),
            "{method} {path}: {} {}",
            response.status,
            response.body
        );
        response.body
    }
}

async fn wait_for_state(
    api: &Api,
    headers: &[(&'static str, String)],
    operation: &str,
    states: &[&str],
    what: &str,
) -> Value {
    let deadline = Instant::now() + DEADLINE;
    loop {
        let response = api
            .send(
                "GET",
                &format!("/api/conversation-submissions/{operation}"),
                headers,
                None,
            )
            .await;
        assert_eq!(
            response.status, 200,
            "reading the submission failed: {} {}",
            response.status, response.body
        );
        let state = response.body["preparation"]["state"]
            .as_str()
            .unwrap_or_default()
            .to_owned();
        if states.contains(&state.as_str()) {
            return response.body;
        }
        assert!(
            Instant::now() < deadline,
            "timed out waiting for {what}; the submission is {state}"
        );
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
}

/// Wait until the first user message has an assistant reply and no run is live.
async fn wait_for_run(api: &Api, headers: &[(&'static str, String)], base: &str, message: &str) {
    let deadline = Instant::now() + DEADLINE;
    loop {
        let snapshot = api
            .send("GET", &format!("{base}/snapshot"), headers, None)
            .await;
        assert_eq!(
            snapshot.status, 200,
            "reading the first run failed: {} {}",
            snapshot.status, snapshot.body
        );
        if first_run_settled(&snapshot.body, message) {
            return;
        }
        assert!(
            Instant::now() < deadline,
            "the first run never settled: {}",
            snapshot.body
        );
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
}

fn first_run_settled(snapshot: &Value, message: &str) -> bool {
    let history = snapshot["history"].as_array().cloned().unwrap_or_default();
    let Some(index) = history
        .iter()
        .position(|entry| entry["role"] == "user" && text(&entry["content"]).contains(message))
    else {
        return false;
    };
    if !history[index + 1..]
        .iter()
        .any(|entry| entry["role"] == "assistant")
    {
        return false;
    }
    !matches!(
        snapshot["run"]["status"].as_str(),
        Some("queued" | "running" | "waiting_input" | "stopping")
    )
}

fn text(content: &Value) -> String {
    match content {
        Value::String(text) => text.clone(),
        Value::Array(blocks) => blocks
            .iter()
            .filter_map(|block| block["text"].as_str())
            .collect(),
        _ => String::new(),
    }
}

/// A fake Node's side of first-send, up to the Stop that fences the first
/// message: capabilities, creation and the Stop command's admission receipt.
/// Returns once the session is usable without a model run.
pub async fn serve_first_send_idle(socket: &mut WebSocket, remote_session: &str) {
    let mut creation = String::new();
    loop {
        let frame = socket.next_json().await.expect("node frame");
        if frame["type"] != "request" {
            continue;
        }
        let method = frame["data"]["method"].as_str().unwrap_or_default();
        let url = frame["data"]["url"].as_str().unwrap_or_default();
        let payload = &frame["data"]["payload"];
        let body = if url == "/api/session-creations/capabilities" {
            json!({ "version": 1, "canAllocate": true, "canTransferAttachments": true,
                "attachmentMimeInQuery": true, "canAdmitFirstMessage": true,
                "canReadFirstMessageReceipt": true, "canCancelCreation": true,
                "canStopBeforeAllocation": true, "maxUploadBytes": 1_048_576,
                "maxAttachments": 16 })
        } else if url == "/api/session-creations" {
            creation = payload["operationId"]
                .as_str()
                .unwrap_or_default()
                .to_owned();
            json!({ "creation": { "operationId": payload["operationId"],
                "workspaceId": payload["workspaceId"], "sessionId": remote_session,
                "state": "ready" }})
        } else if url.ends_with("/control/acquire") {
            json!({ "lease": { "clientId": payload["clientId"], "generation": 1,
                "expiresAt": 4_000_000_000_000u64 } })
        } else if url.ends_with("/control/release") {
            json!({})
        } else if url.ends_with("/commands") {
            assert!(
                payload["payload"]["type"] == "stop",
                "unexpected first-send command: {frame}"
            );
            json!({ "command": { "id": payload["commandId"], "sessionId": remote_session,
                    "status": "accepted" },
                "initialAdmission": stopped_admission(&creation, remote_session) })
        } else if url.contains("/admission") {
            json!({ "admission": stopped_admission(&creation, remote_session) })
        } else {
            panic!("fake node received an unexpected first-send request: {frame}");
        };
        socket
            .send_json(
                &json!({ "type": "response", "requestId": frame["requestId"],
                "data": { "status": 200, "body": body } }),
            )
            .await;
        if method == "POST" && url.ends_with("/control/release") {
            return;
        }
    }
}

fn stopped_admission(operation: &str, session: &str) -> Value {
    json!({ "operationId": operation, "sessionId": session, "state": "stopped",
        "command": null, "inputHash": null, "stopRequested": true, "stopConfirmed": true })
}
