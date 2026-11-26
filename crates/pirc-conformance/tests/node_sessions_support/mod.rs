//! Shared by `node_sessions` and `node_terminals`: a fake model whose
//! replies can be held open mid-stream (so commands meet a running agent),
//! a cluster on it, and helpers for sessions, commands and transcripts.
//!
//! The cluster's own [`pirc_conformance::FakeLlm`] streams every reply at
//! once; [`HeldLlm`] streams the same OpenAI-compatible chunk layout but
//! stops after the first content chunk of a [`Step::Held`] reply until its
//! [`Hold`] is released.

#![allow(dead_code)]

use std::collections::VecDeque;
use std::convert::Infallible;
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use axum::Router;
use axum::body::{Body, Bytes};
use axum::extract::State;
use axum::http::{StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::routing::post;
use pirc_conformance::{
    Api, Cluster, FirstSend, GatewayOptions, Response as ApiResponse, Started, WORKSPACE_ID,
    WebSocket, browser_headers,
};
use serde_json::{Value, json};
use tokio::net::TcpListener;
use tokio::sync::watch;
use tokio::task::JoinHandle;

/// How long a test polls for a state before failing.
pub const DEADLINE: Duration = Duration::from_secs(20);

/// Keeps a [`Step::Held`] reply open until released.
#[derive(Clone)]
pub struct Hold(Arc<watch::Sender<bool>>);

impl Default for Hold {
    fn default() -> Self {
        Self::new()
    }
}

impl Hold {
    pub fn new() -> Self {
        Self(Arc::new(watch::channel(false).0))
    }

    pub fn release(&self) {
        self.0.send_replace(true);
    }

    async fn wait(&self) {
        let mut receiver = self.0.subscribe();
        let _ = receiver.wait_for(|open| *open).await;
    }
}

/// One scripted model reply.
#[derive(Clone)]
pub enum Step {
    /// Stream this text (two content chunks) and stop.
    Text(String),
    /// Call one tool with these arguments.
    Tool {
        id: String,
        name: String,
        args: Value,
    },
    /// A non-streaming HTTP error with this body.
    Status(u16, String),
    /// Stream the first chunk of the reply, then wait for the hold.
    Held(Hold, Box<Step>),
}

impl Step {
    pub fn text(text: &str) -> Self {
        Self::Text(text.to_owned())
    }

    pub fn held(hold: &Hold, step: Step) -> Self {
        Self::Held(hold.clone(), Box::new(step))
    }

    /// A `ptc` call running one capability (`ptcCall` in the TS tests).
    pub fn ptc(id: &str, name: &str, args: Value) -> Self {
        let code = format!(
            "const r = await tools.call({}, {args});\nif (!r.ok) throw new PtcError(r.error);\nreturn r.data.text;",
            json!(name)
        );
        Self::Tool {
            id: id.to_owned(),
            name: "ptc".to_owned(),
            args: json!({ "code": code }),
        }
    }
}

#[derive(Default)]
struct Script {
    queue: VecDeque<Step>,
    requests: Vec<Value>,
}

/// The fake model server; stops when dropped.
pub struct HeldLlm {
    url: String,
    script: Arc<Mutex<Script>>,
    task: JoinHandle<()>,
}

impl HeldLlm {
    pub async fn start() -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
        let url = format!("http://{}", listener.local_addr().unwrap());
        let script = Arc::new(Mutex::new(Script::default()));
        let app = Router::new()
            .route("/v1/chat/completions", post(complete))
            .with_state(script.clone());
        let task = tokio::spawn(async move {
            let _ = axum::serve(listener, app).await;
        });
        Self { url, script, task }
    }

    pub fn base_url(&self) -> String {
        format!("{}/v1", self.url)
    }

    /// Queue replies; once empty, every request gets "default reply".
    pub fn push(&self, steps: impl IntoIterator<Item = Step>) {
        self.script.lock().unwrap().queue.extend(steps);
    }

    pub fn requests(&self) -> Vec<Value> {
        self.script.lock().unwrap().requests.clone()
    }

    /// Wait until `count` requests have arrived.
    pub async fn wait_requests(&self, count: usize) {
        poll("model requests", || async {
            (self.requests().len() >= count).then_some(())
        })
        .await;
    }
}

impl Drop for HeldLlm {
    fn drop(&mut self) {
        self.task.abort();
    }
}

async fn complete(State(script): State<Arc<Mutex<Script>>>, body: Bytes) -> Response {
    let step = {
        let mut script = script.lock().unwrap();
        script
            .requests
            .push(serde_json::from_slice(&body).unwrap_or(Value::Null));
        script
            .queue
            .pop_front()
            .unwrap_or_else(|| Step::text("default reply"))
    };
    let (hold, step) = match step {
        Step::Held(hold, inner) => (Some(hold), *inner),
        other => (None, other),
    };
    if let Step::Status(status, body) = step {
        if let Some(hold) = hold {
            hold.wait().await;
        }
        let status = StatusCode::from_u16(status).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);
        return (status, body).into_response();
    }
    let events = chunks(&step);
    let stream = futures_util::stream::unfold(
        (events.into_iter().enumerate(), hold),
        |(mut events, hold)| async move {
            let (index, event) = events.next()?;
            if index == 1
                && let Some(hold) = &hold
            {
                hold.wait().await;
            }
            tokio::time::sleep(Duration::from_millis(1)).await;
            Some((Ok::<_, Infallible>(Bytes::from(event)), (events, hold)))
        },
    );
    (
        [(header::CONTENT_TYPE, "text/event-stream")],
        Body::from_stream(stream),
    )
        .into_response()
}

/// The chunk layout of `pirc_conformance::FakeLlm`.
fn chunks(step: &Step) -> Vec<String> {
    let chunk = |delta: Value, finish: Value| {
        let data = json!({ "choices": [{ "index": 0, "delta": delta, "finish_reason": finish }] });
        format!("data: {data}\n\n")
    };
    let mut out = Vec::new();
    match step {
        Step::Text(text) => {
            let chars: Vec<char> = text.chars().collect();
            let half = chars.len().div_ceil(2);
            for part in [&chars[..half], &chars[half..]] {
                if !part.is_empty() {
                    let part: String = part.iter().collect();
                    out.push(chunk(json!({ "content": part }), Value::Null));
                }
            }
            out.push(chunk(json!({}), json!("stop")));
        }
        Step::Tool { id, name, args } => {
            let args = args.to_string();
            let split = args.char_indices().nth(5).map_or(args.len(), |(i, _)| i);
            out.push(chunk(
                json!({ "tool_calls": [{ "index": 0, "id": id, "type": "function",
                    "function": { "name": name, "arguments": "" } }] }),
                Value::Null,
            ));
            for part in [&args[..split], &args[split..]] {
                out.push(chunk(
                    json!({ "tool_calls": [{ "index": 0, "function": { "arguments": part } }] }),
                    Value::Null,
                ));
            }
            out.push(chunk(json!({}), json!("tool_calls")));
        }
        Step::Status(..) | Step::Held(..) => unreachable!("handled before streaming"),
    }
    let usage = json!({ "choices": [], "usage": { "prompt_tokens": 100, "completion_tokens": 10,
        "total_tokens": 110, "prompt_tokens_details": { "cached_tokens": 40 } } });
    out.push(format!("data: {usage}\n\n"));
    out.push("data: [DONE]\n\n".to_owned());
    out
}

/// A cluster whose gateway's only provider is `llm` (provider `fake`,
/// model `fake-model`, the default with thinking `low`, as the cluster's
/// own models file), and a second model `other-model`.
pub async fn held_cluster(
    llm: &HeldLlm,
    models_dir: &Path,
    mut options: GatewayOptions,
) -> Option<Cluster> {
    let models = models_dir.join("models.json");
    std::fs::write(
        &models,
        serde_json::to_vec_pretty(&json!({
            "providers": { "fake": {
                "api": "openai-completions",
                "baseUrl": llm.base_url(),
                "apiKey": "test-key",
                "models": [
                    { "id": "fake-model", "reasoning": true, "contextWindow": 100000,
                        "maxTokens": 1000 },
                    { "id": "other-model", "reasoning": true, "contextWindow": 100000,
                        "maxTokens": 1000 },
                ],
            } },
            "defaultModel": { "provider": "fake", "id": "fake-model", "thinking": "low" },
        }))
        .unwrap(),
    )
    .unwrap();
    options
        .env
        .push(("PIRC_MODELS_FILE", models.display().to_string()));
    // These transcripts exercise commands, not the platform-specific warning
    // about srt's shared /tmp. Keep test temporary files inside the fixture.
    if !options.node_env.iter().any(|(name, _)| *name == "TMPDIR") {
        options.node_env.push(("TMPDIR", "{run_dir}".into()));
    }
    Cluster::start_with(options).await
}

/// Poll `check` until it yields a value, or panic after [`DEADLINE`].
pub async fn poll<T, F, Fut>(what: &str, mut check: F) -> T
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = Option<T>>,
{
    let deadline = Instant::now() + DEADLINE;
    loop {
        if let Some(value) = check().await {
            return value;
        }
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
}

/// One browser session on the cluster's directory workspace.
pub struct Session {
    pub api: Api,
    pub id: String,
    pub base: String,
    pub client: String,
    pub generation: Value,
    binding: Value,
    commands: usize,
}

impl Session {
    fn from_started(api: &Api, started: Started) -> Self {
        Self {
            api: api.clone(),
            base: started.base,
            id: started.id,
            client: started.client_id,
            generation: started.generation,
            binding: Value::Null,
            commands: 0,
        }
    }

    /// Create an idle session through first-send (the first message is
    /// fenced, so no run starts). Control is already held by `client`.
    pub async fn create(api: &Api) -> (Self, ApiResponse) {
        let started = FirstSend::browser(api)
            .workspace(WORKSPACE_ID)
            .start_idle()
            .await;
        let response = started.response.clone();
        (Self::from_started(api, started), response)
    }

    /// Create a session through first-send with `message` as its first
    /// message, wait for the reply, and hold control.
    pub async fn start(api: &Api, message: &str) -> (Self, ApiResponse) {
        let started = FirstSend::browser(api)
            .workspace(WORKSPACE_ID)
            .message(message)
            .start()
            .await;
        let response = started.response.clone();
        (Self::from_started(api, started), response)
    }

    /// An existing session, e.g. one the backend created (no control taken yet).
    pub fn existing(api: &Api, id: &str) -> Self {
        Self {
            api: api.clone(),
            base: format!("/api/sessions/{id}"),
            id: id.to_owned(),
            client: "browser".to_owned(),
            generation: Value::Null,
            binding: Value::Null,
            commands: 0,
        }
    }

    pub async fn acquire(&mut self) -> ApiResponse {
        let acquired = self
            .post(
                "/control/acquire",
                json!({ "clientId": self.client.clone() }),
            )
            .await;
        self.generation = acquired.body["lease"]["generation"].clone();
        acquired
    }

    /// `GET <session><path>`
    pub async fn get(&self, path: &str) -> ApiResponse {
        self.api
            .send(
                "GET",
                &format!("{}{path}", self.base),
                &browser_headers(),
                None,
            )
            .await
    }

    /// `POST <session><path>`
    pub async fn post(&self, path: &str, body: Value) -> ApiResponse {
        self.api
            .send(
                "POST",
                &format!("{}{path}", self.base),
                &browser_headers(),
                Some(body),
            )
            .await
    }

    /// `POST <session>/interactions/<interaction>/answer`
    pub async fn post_answer(&self, interaction: &str, body: Value) -> ApiResponse {
        self.post(&format!("/interactions/{interaction}/answer"), body)
            .await
    }

    pub async fn snapshot(&self) -> ApiResponse {
        self.get("/snapshot").await
    }

    /// A command with the next id (`c1`, `c2`, …) under the held lease.
    pub async fn command(&mut self, payload: Value) -> ApiResponse {
        self.commands += 1;
        let id = format!("c{}", self.commands);
        self.command_with(&id, payload).await
    }

    pub async fn command_with(&self, id: &str, payload: Value) -> ApiResponse {
        let stop = matches!(payload["type"].as_str(), Some("stop" | "stop_transition"));
        let binding = if stop {
            Value::Null
        } else {
            let environment = self.get("/environment").await;
            assert_eq!(environment.status, 200, "{}", environment.body);
            environment.body["binding"].clone()
        };
        let mut body = json!({ "commandId": id, "clientId": self.client.clone(),
            "payload": payload });
        if !stop {
            body["generation"] = self.generation.clone();
            body["expectedBinding"] = binding;
        }
        self.post("/commands", body).await
    }

    /// A live `/api/events` socket from the session's current watermark.
    pub async fn events(&self) -> WebSocket {
        let snapshot = self.snapshot().await;
        let watermark = &snapshot.body["watermark"];
        let path = format!(
            "/api/events?sessionId={}&cursor={}:{}",
            self.id, watermark["epoch"], watermark["sequence"]
        );
        self.api.connect(&path, &browser_headers()).await.open()
    }

    /// Poll the snapshot until `check` holds; returns that snapshot.
    pub async fn snapshot_until(&self, what: &str, check: impl Fn(&Value) -> bool) -> ApiResponse {
        poll(what, || async {
            let snapshot = self.snapshot().await;
            check(&snapshot.body).then_some(snapshot)
        })
        .await
    }
}

/// An event frame in brief: its type, and for agent events the agent's
/// event type (with the streamed delta's kind for `message_update`).
pub fn brief(frame: &Value) -> Value {
    let kind = frame["type"].as_str().unwrap_or_default();
    let data = &frame["data"];
    match kind {
        "pi_event" => {
            let agent = data["type"].as_str().unwrap_or_default();
            match agent {
                "message_update" => json!(format!(
                    "pi_event:message_update:{}",
                    data["assistantMessageEvent"]["type"]
                        .as_str()
                        .unwrap_or_default()
                )),
                "message_start" | "message_end" => json!(format!(
                    "pi_event:{agent}:{}",
                    data["message"]["role"].as_str().unwrap_or_default()
                )),
                _ => json!(format!("pi_event:{agent}")),
            }
        }
        _ => json!(kind),
    }
}

/// Frames that depend on how the agent's stderr was chunked or on timers:
/// a tool's progress (`tool_execution_update`) is throttled to one per
/// 100 ms of wall-clock time.
pub fn incidental(frame: &Value) -> bool {
    frame["type"] == "runner_stderr" || agent_event(frame, "tool_execution_update")
}

/// Read frames until `done` holds, without incidental ones.
pub async fn read_until(socket: &mut WebSocket, done: impl Fn(&Value) -> bool) -> Vec<Value> {
    socket
        .until(|frame| !incidental(frame) && done(frame))
        .await
        .into_iter()
        .filter(|frame| !incidental(frame))
        .collect()
}

pub fn agent_event(frame: &Value, kind: &str) -> bool {
    frame["type"] == "pi_event" && frame["data"]["type"] == kind
}

/// Number keys ending in `Ms` (script timings) become `<ms>`.
pub fn mask_times(value: &mut Value) {
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

/// Replace substrings everywhere in a JSON value (keys too).
pub fn replace_all(value: &Value, replacements: &[(String, String)]) -> Value {
    let text = |text: &str| {
        replacements
            .iter()
            .fold(text.to_owned(), |text, (from, to)| text.replace(from, to))
    };
    match value {
        Value::String(s) => Value::String(text(s)),
        Value::Array(items) => items
            .iter()
            .map(|item| replace_all(item, replacements))
            .collect(),
        Value::Object(object) => Value::Object(
            object
                .iter()
                .map(|(key, item)| (text(key), replace_all(item, replacements)))
                .collect(),
        ),
        other => other.clone(),
    }
}
