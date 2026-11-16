//! Scheduled agent runs (`apps/gateway/src/daemon/schedules.ts`,
//! `schedule-routes.ts`, the `schedule.*` agent operations), with the test
//! acting as the node: the REST routes and their validation, running a
//! schedule now and following its session to the end, a run that waits
//! for the user, fails or cannot start, a one-shot the timer fires, a
//! missed run while the node is offline, an agent's proposals answered in
//! the chat, and the `schedules_changed` hints.
//!
//! Nothing waits for a cron time: runs are started now, or one-shots are
//! set a moment ahead. The gateway's short ids (`s…`, `r…`, `p…`) and the
//! wall times that depend on today are normalized here.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use pirc_conformance::{
    Api, Cluster, GatewayOptions, NODE_ID, NODE_TOKEN, Response, Transcript, WebSocket,
    assert_node_frame, browser_headers,
};
use regex::Regex;
use serde_json::{Value, json};
use tokio::sync::mpsc;

fn node_headers() -> Vec<(&'static str, String)> {
    vec![
        ("x-pirc-node-id", NODE_ID.to_owned()),
        ("authorization", format!("Bearer {NODE_TOKEN}")),
    ]
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64
}

/// (year, month, day) of days since 1970-01-01.
fn civil(days: i64) -> (i64, i64, i64) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    (yoe + era * 400 + i64::from(m <= 2), m, d)
}

/// `YYYY-MM-DDTHH:MM:SS` in UTC, without an offset.
fn iso(ms: i64) -> String {
    let (y, m, d) = civil(ms.div_euclid(86_400_000));
    let s = ms.rem_euclid(86_400_000) / 1000;
    format!(
        "{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}",
        s / 3600,
        s / 60 % 60,
        s % 60
    )
}

/// The dates (`YYYY-MM-DD`) from three days ago to ten days ahead: wall
/// times on them depend on when the test runs.
fn near_dates() -> Vec<String> {
    let today = now_ms().div_euclid(86_400_000);
    (today - 3..=today + 10)
        .map(|day| {
            let (y, m, d) = civil(day);
            format!("{y:04}-{m:02}-{d:02}")
        })
        .collect()
}

/// Placeholders for the gateway's short ids and today's wall times, before
/// the shared normalizer.
struct Local {
    ids: HashMap<String, String>,
    counts: HashMap<char, usize>,
    id: Regex,
    wall: Regex,
    near: Vec<String>,
}

impl Local {
    fn new() -> Self {
        Self {
            ids: HashMap::new(),
            counts: HashMap::new(),
            id: Regex::new(r"\b[spr][0-9a-f]{8}\b").unwrap(),
            wall: Regex::new(r"\b(\d{4}-\d{2}-\d{2}) \d{2}:\d{2}\b").unwrap(),
            near: near_dates(),
        }
    }

    fn text(&mut self, text: &str) -> String {
        let walls = self
            .wall
            .replace_all(text, |captures: &regex::Captures<'_>| {
                if self.near.contains(&captures[1].to_owned()) {
                    "<wall-time>".to_owned()
                } else {
                    captures[0].to_owned()
                }
            });
        let found: Vec<String> = self
            .id
            .find_iter(&walls)
            .map(|found| found.as_str().to_owned())
            .collect();
        let mut out = walls.into_owned();
        for id in found {
            let placeholder = match self.ids.get(&id) {
                Some(placeholder) => placeholder.clone(),
                None => {
                    let kind = id.chars().next().unwrap();
                    let count = self.counts.entry(kind).or_default();
                    *count += 1;
                    let name = match kind {
                        's' => "schedule",
                        'r' => "run",
                        _ => "proposal",
                    };
                    let placeholder = format!("<{name}:{count}>");
                    self.ids.insert(id.clone(), placeholder.clone());
                    placeholder
                }
            };
            out = self
                .id
                .replace_all(&out, |captures: &regex::Captures<'_>| {
                    if captures[0] == id {
                        placeholder.clone()
                    } else {
                        captures[0].to_owned()
                    }
                })
                .into_owned();
        }
        out
    }

    fn value(&mut self, value: &Value) -> Value {
        match value {
            Value::String(text) => Value::String(self.text(text)),
            Value::Array(items) => items.iter().map(|item| self.value(item)).collect(),
            Value::Object(object) => Value::Object(
                object
                    .iter()
                    .map(|(key, item)| (key.clone(), self.value(item)))
                    .collect(),
            ),
            other => other.clone(),
        }
    }
}

/// How the fake node answers for a run session, by the session's name.
#[derive(Clone)]
enum Mode {
    /// The agent finished with this answer.
    Succeeded(&'static str),
    /// The agent asks the user something.
    Waiting,
    /// The run failed with this reason after this answer.
    Failed(&'static str, &'static str),
    /// The node refuses the delivery.
    RefuseDelivery,
}

#[derive(Default)]
struct NodeState {
    /// Relayed requests not yet recorded.
    relayed: Vec<Value>,
    /// `agent_response` frames by request id.
    answers: HashMap<String, Value>,
    sessions: usize,
    /// A session's name and the run delivered into it.
    names: HashMap<String, String>,
    runs: HashMap<String, String>,
    /// Sessions a run was delivered into, in order.
    deliveries: Vec<String>,
    modes: HashMap<String, Mode>,
}

struct FakeNode {
    frames: mpsc::UnboundedSender<Option<Value>>,
    task: tokio::task::JoinHandle<()>,
}

fn reply(request: &Value, state: &mut NodeState) -> Value {
    let method = request["method"].as_str().unwrap_or_default();
    let url = request["url"].as_str().unwrap_or_default().to_owned();
    let ok = |body: Value| json!({ "status": 200, "body": body });
    let remote = url
        .strip_prefix("/api/sessions/")
        .map(|rest| rest.split('/').next().unwrap_or_default().to_owned())
        .unwrap_or_default();
    match method {
        "POST" if url == "/api/sessions" => {
            state.sessions += 1;
            json!({ "status": 201, "body": { "session": { "id": format!("remote-{}", state.sessions) } } })
        }
        "PATCH" => {
            if let Some(name) = request["payload"]["name"].as_str() {
                state.names.insert(remote.clone(), name.to_owned());
            }
            ok(json!({ "session": { "id": remote } }))
        }
        "POST" if url.ends_with("/deliver") => {
            let name = state.names.get(&remote).cloned().unwrap_or_default();
            if let Some(run) = request["payload"]["details"]["runId"].as_str() {
                state.runs.insert(remote.clone(), run.to_owned());
                state.deliveries.push(remote.clone());
            }
            if matches!(state.modes.get(&name), Some(Mode::RefuseDelivery)) {
                return json!({ "status": 409, "body": { "error": {
                    "code": "conflict", "message": "agent busy" } } });
            }
            ok(json!({ "delivered": true }))
        }
        "GET" if url.ends_with("/snapshot") => {
            let name = state.names.get(&remote).cloned().unwrap_or_default();
            let run = state.runs.get(&remote).cloned().unwrap_or_default();
            let ours = json!({ "role": "custom", "customType": "scheduled-run",
                "details": { "runId": run } });
            let answer = |text: &str| {
                json!({ "role": "assistant",
                "content": [{ "type": "text", "text": text }] })
            };
            let (history, interactions, run) = match state.modes.get(&name) {
                Some(Mode::Succeeded(text)) => (
                    json!([ours, answer(text)]),
                    json!([]),
                    json!({ "status": "succeeded", "createdAt": now_ms() }),
                ),
                Some(Mode::Waiting) => (
                    json!([ours]),
                    json!([{ "id": "question-1", "kind": "confirm" }]),
                    json!({ "status": "waiting_input", "createdAt": now_ms() }),
                ),
                Some(Mode::Failed(reason, text)) => (
                    json!([ours, answer(text)]),
                    json!([]),
                    json!({ "status": "failed", "failureReason": reason, "createdAt": now_ms() }),
                ),
                _ => (json!([]), json!([]), Value::Null),
            };
            ok(json!({
                "session": { "id": remote, "runnerState": "ready", "name": name },
                "history": history, "interactions": interactions, "run": run,
                "watermark": { "epoch": 1, "sequence": 1 },
            }))
        }
        "POST" if url.ends_with("/control/acquire") => ok(json!({ "lease": {
            "clientId": request["payload"]["clientId"],
            "generation": request["payload"]["generation"].as_u64().unwrap_or(0) + 1,
            "expiresAt": 4_000_000_000_000u64 } })),
        _ => ok(json!({ "relayed": true })),
    }
}

impl FakeNode {
    /// Register as the node, with two directory workspaces, and answer
    /// every relayed request from `state`.
    async fn connect(api: &Api, state: Arc<Mutex<NodeState>>) -> Self {
        let mut socket: WebSocket = api.connect("/node/connect", &node_headers()).await.open();
        let register = json!({
            "type": "register", "role": "node", "protocol": pirc_protocol::NODE_PROTOCOL_VERSION, "modes": ["directory"],
            "workspaces": [
                { "id": "ws", "displayName": "Fake workspace", "mode": "directory" },
                { "id": "other", "displayName": "Other", "mode": "directory" },
            ],
        });
        assert_node_frame(&register);
        socket.send_json(&register).await;
        assert_eq!(socket.next_json().await.unwrap()["type"], "registered");
        let (frames, mut outgoing) = mpsc::unbounded_channel::<Option<Value>>();
        let task = tokio::spawn(async move {
            loop {
                tokio::select! {
                    frame = socket.next_json() => {
                        let Ok(frame) = frame else { return };
                        let answer = {
                            let mut state = state.lock().unwrap();
                            match frame["type"].as_str() {
                                Some("request") => {
                                    state.relayed.push(frame["data"].clone());
                                    Some(json!({ "type": "response", "requestId": frame["requestId"],
                                        "data": reply(&frame["data"], &mut state) }))
                                }
                                Some("agent_response") => {
                                    let id = frame["requestId"].as_str().unwrap_or_default().to_owned();
                                    state.answers.insert(id, frame.clone());
                                    None
                                }
                                _ => None,
                            }
                        };
                        if let Some(answer) = answer {
                            socket.send_json(&answer).await;
                        }
                    }
                    outgoing = outgoing.recv() => match outgoing {
                        Some(Some(frame)) => {
                            assert_node_frame(&frame);
                            socket.send_json(&frame).await;
                        }
                        _ => {
                            socket.close().await;
                            return;
                        }
                    }
                }
            }
        });
        Self { frames, task }
    }

    fn send(&self, frame: Value) {
        self.frames.send(Some(frame)).unwrap();
    }

    fn event(&self, remote: &str, kind: &str, data: Value) {
        self.send(json!({ "type": "event", "sessionId": remote,
            "event": { "type": kind, "data": data } }));
    }

    /// The agent of `remote` settled: the gateway reads the session again.
    fn settled(&self, remote: &str) {
        self.event(remote, "pi_event", json!({ "type": "agent_settled" }));
    }

    async fn close(self) {
        let _ = self.frames.send(None);
        let _ = self.task.await;
    }
}

/// Poll until `probe` gives a value.
async fn eventually<T>(what: &str, mut probe: impl AsyncFnMut() -> Option<T>) -> T {
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        if let Some(value) = probe().await {
            return value;
        }
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
}

struct Scenario {
    api: Api,
    t: Transcript,
    local: Local,
    state: Arc<Mutex<NodeState>>,
    requests: usize,
    /// Deliveries [`Scenario::delivered`] has seen.
    deliveries: usize,
}

impl Scenario {
    async fn call(
        &mut self,
        step: &str,
        method: &str,
        path: &str,
        body: Option<Value>,
    ) -> Response {
        let response = self.api.send(method, path, &browser_headers(), body).await;
        self.record(step, method, path, &response);
        response
    }

    fn record(&mut self, step: &str, method: &str, path: &str, response: &Response) {
        let local = Response {
            status: response.status,
            headers: response.headers.clone(),
            body: self.local.value(&response.body),
        };
        let request = self.local.text(&format!("{method} {path}"));
        self.t.response(step, &request, &local);
    }

    fn note(&mut self, step: &str, value: Value) {
        let value = self.local.value(&value);
        self.t.note(step, value);
    }

    /// Record (and forget) what the node was asked since the last time.
    fn relayed(&mut self, step: &str) {
        let requests = std::mem::take(&mut self.state.lock().unwrap().relayed);
        self.note(&format!("{step}: relayed"), json!(requests));
    }

    fn forget_relayed(&mut self) {
        self.state.lock().unwrap().relayed.clear();
    }

    /// An agent's operation from the session `remote` of the node.
    async fn op(
        &mut self,
        node: &FakeNode,
        step: &str,
        remote: &str,
        op: &str,
        args: Value,
    ) -> Value {
        self.requests += 1;
        let id = format!("agent-{}", self.requests);
        node.send(
            json!({ "type": "agent_request", "requestId": id, "sessionId": remote,
            "op": op, "args": args }),
        );
        let state = self.state.clone();
        let answer = eventually("an agent response", async || {
            state.lock().unwrap().answers.remove(&id)
        })
        .await;
        self.note(
            step,
            json!({ "op": op, "status": answer["status"], "body": answer["body"] }),
        );
        answer["body"].clone()
    }

    /// Runs of schedule `id`, newest first.
    async fn runs(&self, id: &str) -> Vec<Value> {
        let response = self
            .api
            .send(
                "GET",
                &format!("/api/schedules/{id}"),
                &browser_headers(),
                None,
            )
            .await;
        response.body["runs"]
            .as_array()
            .cloned()
            .unwrap_or_default()
    }

    /// Wait until the newest run of `id` has `status`.
    async fn run_reaches(&self, id: &str, status: &str) -> Value {
        eventually(&format!("a {status} run"), async || {
            let runs = self.runs(id).await;
            runs.first().filter(|run| run["status"] == status).cloned()
        })
        .await
    }

    /// The node has delivered a new run into a session named `name`: its remote id.
    async fn delivered(&mut self, name: &str) -> String {
        let state = self.state.clone();
        let seen = self.deliveries;
        let remote = eventually("a delivery", async || {
            let state = state.lock().unwrap();
            state.deliveries[seen..]
                .iter()
                .find(|remote| state.names.get(*remote).map(String::as_str) == Some(name))
                .cloned()
        })
        .await;
        self.deliveries = self.state.lock().unwrap().deliveries.len();
        remote
    }

    fn mode(&self, name: &str, mode: Mode) {
        self.state
            .lock()
            .unwrap()
            .modes
            .insert(name.to_owned(), mode);
    }

    /// Send a marker event on `remote`; record what `socket` received up to it.
    async fn drain(&mut self, node: &FakeNode, socket: &mut WebSocket, remote: &str, step: &str) {
        node.event(remote, "marker", json!(step));
        let frames = socket
            .until(|frame| frame["type"] == "marker" && frame["data"] == step)
            .await;
        self.note(&format!("{step}: the hint socket"), json!(frames));
    }
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn schedules() {
    let Some(cluster) = Cluster::start_with(GatewayOptions {
        without_node: true,
        ..Default::default()
    })
    .await
    else {
        return;
    };
    let api = cluster.api();
    let state = Arc::new(Mutex::new(NodeState::default()));
    let mut s = Scenario {
        api: api.clone(),
        t: Transcript::new(cluster.volatile()),
        local: Local::new(),
        state: state.clone(),
        requests: 0,
        deliveries: 0,
    };
    let node = FakeNode::connect(&api, state.clone()).await;

    // A session to watch the hints on (remote-1); its agent proposes later.
    let created = s
        .call(
            "a session for the hints",
            "POST",
            "/api/sessions",
            Some(json!({ "workspaceId": "test:ws" })),
        )
        .await;
    let chat = created.body["session"]["id"].as_str().unwrap().to_owned();
    s.forget_relayed();
    let hints = format!("/api/events?sessionId={chat}&schedules=1");
    let mut socket = api.connect(&hints, &browser_headers()).await.open();

    // ---------- the routes ----------

    s.call("no schedules yet", "GET", "/api/schedules", None)
        .await;
    let base = json!({ "workspaceId": "test:ws", "prompt": "x" });
    let with = |extra: Value| {
        let mut body = base.clone();
        for (key, value) in extra.as_object().unwrap() {
            body[key] = value.clone();
        }
        body
    };
    for (step, body) in [
        (
            "no prompt",
            json!({ "workspaceId": "test:ws", "cron": "0 9 * * *" }),
        ),
        (
            "an unknown key",
            with(json!({ "cron": "0 9 * * *", "extra": 1 })),
        ),
        (
            "an unknown thinking level",
            with(json!({ "cron": "0 9 * * *", "thinking": "huge" })),
        ),
        (
            "a model without an id",
            with(json!({ "cron": "0 9 * * *", "model": { "provider": "fake" } })),
        ),
        (
            "a null notify",
            with(json!({ "cron": "0 9 * * *", "notify": null })),
        ),
        ("four cron fields", with(json!({ "cron": "0 9 * *" }))),
        ("six cron fields", with(json!({ "cron": "0 0 9 * * *" }))),
        (
            "a minute out of range",
            with(json!({ "cron": "61 9 * * *" })),
        ),
        ("a zero step", with(json!({ "cron": "*/0 9 * * *" }))),
        (
            "a bad nth weekday",
            with(json!({ "cron": "0 9 * * MON#6" })),
        ),
        (
            "a day that never comes",
            with(json!({ "cron": "0 9 30 2 *" })),
        ),
        (
            "an unknown time zone",
            with(json!({ "cron": "0 9 * * *", "timezone": "Mars/Base" })),
        ),
        (
            "a time in the past",
            with(json!({ "at": "2020-01-01T00:00" })),
        ),
        (
            "a cron expression as the time",
            with(json!({ "at": "0 9 * * *" })),
        ),
        ("not a time", with(json!({ "at": "tomorrow" }))),
        (
            "a time without minutes",
            with(json!({ "at": "2040-01-01T9:00" })),
        ),
        (
            "both cron and at",
            with(json!({ "cron": "0 9 * * *", "at": "2040-01-01T09:00" })),
        ),
        (
            "an unknown model",
            with(json!({ "cron": "0 9 * * *", "model": { "provider": "fake", "id": "nope" } })),
        ),
        ("neither cron nor at", base.clone()),
        (
            "a blank prompt",
            with(json!({ "prompt": "  ", "cron": "0 9 * * *" })),
        ),
        (
            "a long prompt",
            with(json!({ "prompt": "x".repeat(20_001), "cron": "0 9 * * *" })),
        ),
        (
            "an unknown workspace",
            with(json!({ "workspaceId": "nope", "cron": "0 9 * * *" })),
        ),
    ] {
        s.call(step, "POST", "/api/schedules", Some(body)).await;
    }
    s.drain(&node, &mut socket, "remote-1", "refused").await;

    let nightly = s
        .call(
            "a schedule",
            "POST",
            "/api/schedules",
            Some(json!({ "workspaceId": "test:ws", "title": "Nightly check",
                "prompt": "Run the test suite.", "cron": "30 9 * * 1-5", "timezone": " asia/taipei ",
                "model": { "provider": "fake", "id": "fake-model" }, "thinking": "high",
                "notify": "problems" })),
        )
        .await;
    let nightly = nightly.body["schedule"]["id"].as_str().unwrap().to_owned();
    s.drain(&node, &mut socket, "remote-1", "created").await;
    let once = s
        .call(
            "a one-shot, with an offset",
            "POST",
            "/api/schedules",
            Some(
                json!({ "workspaceId": "test:ws", "prompt": "  Once.\nSecond line  ",
                "at": "2040-01-01T09:00+08:00" }),
            ),
        )
        .await;
    let once = once.body["schedule"]["id"].as_str().unwrap().to_owned();
    s.call("both listed", "GET", "/api/schedules", None).await;
    s.call(
        "one with its runs",
        "GET",
        &format!("/api/schedules/{nightly}"),
        None,
    )
    .await;
    s.call("an unknown one", "GET", "/api/schedules/sdeadbeef", None)
        .await;
    s.call(
        "a long id",
        "GET",
        &format!("/api/schedules/{}", "s".repeat(41)),
        None,
    )
    .await;
    let path = format!("/api/schedules/{nightly}");
    s.call(
        "change its time, zone and thinking",
        "PATCH",
        &path,
        Some(json!({ "cron": "0 9 * * *", "timezone": "UTC", "thinking": null })),
    )
    .await;
    s.call(
        "a one-shot's zone without its time",
        "PATCH",
        &format!("/api/schedules/{once}"),
        Some(json!({ "timezone": "Asia/Taipei" })),
    )
    .await;
    s.call("pause", "PATCH", &path, Some(json!({ "status": "paused" })))
        .await;
    s.call(
        "resume",
        "PATCH",
        &path,
        Some(json!({ "status": "active" })),
    )
    .await;
    s.call("nothing to change", "PATCH", &path, Some(json!({})))
        .await;
    s.call(
        "an unknown status",
        "PATCH",
        &path,
        Some(json!({ "status": "done" })),
    )
    .await;
    s.call(
        "a title, no model and no notifications",
        "PATCH",
        &format!("/api/schedules/{once}"),
        Some(json!({ "title": "  Far \n away  ", "model": null, "notify": "none" })),
    )
    .await;
    s.drain(&node, &mut socket, "remote-1", "changed").await;
    s.call("delete", "DELETE", &format!("/api/schedules/{once}"), None)
        .await;
    s.call("deleted", "GET", &format!("/api/schedules/{once}"), None)
        .await;
    s.drain(&node, &mut socket, "remote-1", "deleted").await;
    s.call(
        "dismiss a run that was not missed",
        "POST",
        &format!("{path}/runs/rdeadbeef/dismiss"),
        None,
    )
    .await;
    s.call(
        "allow a run that was not missed",
        "POST",
        &format!("{path}/run"),
        Some(json!({ "runId": "rdeadbeef" })),
    )
    .await;
    s.call(
        "run with an unknown key",
        "POST",
        &format!("{path}/run"),
        Some(json!({ "now": true })),
    )
    .await;
    s.drain(&node, &mut socket, "remote-1", "refused runs")
        .await;
    socket.close().await;

    // ---------- runs ----------

    // Run now: a new session named after it gets the prompt, on its model.
    s.mode("Nightly check", Mode::Succeeded("All green."));
    s.call(
        "run it now",
        "POST",
        &format!("{path}/run"),
        Some(json!({})),
    )
    .await;
    let remote = s.delivered("Nightly check").await;
    s.relayed("run it now");
    s.call("running", "GET", &path, None).await;
    node.settled(&remote);
    s.run_reaches(&nightly, "completed").await;
    s.relayed("the agent settled");
    s.call("completed", "GET", &path, None).await;

    // A run that waits for the user, then fails.
    s.mode("Nightly check", Mode::Waiting);
    s.call("run it again", "POST", &format!("{path}/run"), None)
        .await;
    let remote = s.delivered("Nightly check").await;
    node.settled(&remote);
    s.run_reaches(&nightly, "waiting_input").await;
    s.forget_relayed();
    s.call("waiting for the user", "GET", "/api/schedules", None)
        .await;
    s.call(
        "run it while it waits",
        "POST",
        &format!("{path}/run"),
        Some(json!({})),
    )
    .await;
    s.mode("Nightly check", Mode::Failed("boom", "Partial work."));
    node.settled(&remote);
    s.run_reaches(&nightly, "failed").await;
    s.forget_relayed();
    s.call("failed", "GET", &path, None).await;

    // The node refuses the delivery.
    let broken = s
        .call(
            "a schedule its node refuses",
            "POST",
            "/api/schedules",
            Some(
                json!({ "workspaceId": "test:ws", "title": "Broken", "prompt": "Break.",
                "cron": "0 9 * * *" }),
            ),
        )
        .await;
    let broken = broken.body["schedule"]["id"].as_str().unwrap().to_owned();
    s.mode("Broken", Mode::RefuseDelivery);
    s.call(
        "run it",
        "POST",
        &format!("/api/schedules/{broken}/run"),
        Some(json!({})),
    )
    .await;
    s.run_reaches(&broken, "failed").await;
    s.forget_relayed();
    s.call(
        "it could not start",
        "GET",
        &format!("/api/schedules/{broken}"),
        None,
    )
    .await;

    // A one-shot a moment ahead: the timer runs it, then it is done.
    s.mode("Soon", Mode::Succeeded("Done soon."));
    let soon = s
        .call(
            "a one-shot a moment ahead",
            "POST",
            "/api/schedules",
            Some(
                json!({ "workspaceId": "test:ws", "title": "Soon", "prompt": "Soon.",
                "at": iso(now_ms() + 1500), "timezone": "UTC" }),
            ),
        )
        .await;
    let soon = soon.body["schedule"]["id"].as_str().unwrap().to_owned();
    let remote = s.delivered("Soon").await;
    node.settled(&remote);
    s.run_reaches(&soon, "completed").await;
    s.forget_relayed();
    s.call(
        "the timer ran it",
        "GET",
        &format!("/api/schedules/{soon}"),
        None,
    )
    .await;

    // Its node is offline when it falls due: missed, until the user lets it go.
    node.close().await;
    eventually("the node to leave", async || {
        let health = api
            .send("GET", "/api/health", &browser_headers(), None)
            .await;
        (health.body["nodes"] == 0).then_some(())
    })
    .await;
    let offline = s
        .call(
            "a one-shot while the node is away",
            "POST",
            "/api/schedules",
            Some(
                json!({ "workspaceId": "test:ws", "title": "Offline", "prompt": "Wait.",
                "at": iso(now_ms() + 1500), "timezone": "UTC" }),
            ),
        )
        .await;
    let offline = offline.body["schedule"]["id"].as_str().unwrap().to_owned();
    let missed = s.run_reaches(&offline, "missed").await;
    let missed = missed["id"].as_str().unwrap().to_owned();
    s.call("missed", "GET", "/api/schedules", None).await;
    let offline_path = format!("/api/schedules/{offline}");
    s.call(
        "allow it while the node is away",
        "POST",
        &format!("{offline_path}/run"),
        Some(json!({ "runId": missed })),
    )
    .await;
    s.call(
        "let it go",
        "POST",
        &format!("{offline_path}/runs/{missed}/dismiss"),
        None,
    )
    .await;
    s.call(
        "let it go again",
        "POST",
        &format!("{offline_path}/runs/{missed}/dismiss"),
        None,
    )
    .await;

    // ---------- an agent's proposals ----------

    let node = FakeNode::connect(&api, state.clone()).await;
    // Let the reconnection settle before watching the hints.
    tokio::time::sleep(Duration::from_millis(300)).await;
    s.forget_relayed();
    let mut socket = api.connect(&hints, &browser_headers()).await.open();
    s.drain(&node, &mut socket, "remote-1", "watching").await;

    s.op(
        &node,
        "the agent lists them",
        "remote-1",
        "schedule.list",
        json!({}),
    )
    .await;
    let proposed = s
        .op(
            &node,
            "the agent proposes one",
            "remote-1",
            "schedule.create",
            json!({ "prompt": "Lint the repo.", "title": "Lint", "cron": "0 9 * * *",
                "notify": "problems" }),
        )
        .await;
    let proposal = proposed["result"]["proposalId"]
        .as_str()
        .unwrap()
        .to_owned();
    s.op(
        &node,
        "in another workspace",
        "remote-1",
        "schedule.create",
        json!({ "workspace": "test:other", "prompt": "x", "cron": "0 9 * * *" }),
    )
    .await;
    s.op(
        &node,
        "with a model",
        "remote-1",
        "schedule.create",
        json!({ "prompt": "x", "cron": "0 9 * * *", "model": "fake/fake-model" }),
    )
    .await;
    s.op(
        &node,
        "with a bad expression",
        "remote-1",
        "schedule.create",
        json!({ "prompt": "x", "cron": "bad" }),
    )
    .await;
    s.drain(&node, &mut socket, "remote-1", "proposed").await;
    s.call(
        "the chat shows the proposal",
        "GET",
        &format!("/api/sessions/{chat}/snapshot"),
        None,
    )
    .await;
    let lease = s
        .call(
            "take control",
            "POST",
            &format!("/api/sessions/{chat}/control/acquire"),
            Some(json!({ "clientId": "browser" })),
        )
        .await;
    s.forget_relayed();
    let generation = lease.body["lease"]["generation"].clone();
    let answer = |id: &str, confirmed: bool| {
        (
            format!("/api/sessions/{chat}/interactions/{id}/answer"),
            json!({ "clientId": "browser", "generation": generation, "answer": { "confirmed": confirmed } }),
        )
    };
    let (target, body) = answer(&proposal, true);
    let approved = s
        .call("approve it", "POST", &target, Some(body.clone()))
        .await;
    let lint = approved.body["scheduleId"].as_str().unwrap().to_owned();
    s.drain(&node, &mut socket, "remote-1", "approved").await;
    s.call("approve it again", "POST", &target, Some(body))
        .await;
    s.call(
        "the new schedule",
        "GET",
        &format!("/api/schedules/{lint}"),
        None,
    )
    .await;

    let change = s
        .op(
            &node,
            "the agent proposes a change",
            "remote-1",
            "schedule.update",
            json!({ "id": lint, "cron": "0 10 * * *" }),
        )
        .await;
    let change = change["result"]["proposalId"].as_str().unwrap().to_owned();
    let (target, body) = answer(&change, false);
    s.call("decline it", "POST", &target, Some(body)).await;
    s.drain(&node, &mut socket, "remote-1", "declined").await;
    s.op(
        &node,
        "pause",
        "remote-1",
        "schedule.pause",
        json!({ "id": lint }),
    )
    .await;
    s.op(
        &node,
        "resume",
        "remote-1",
        "schedule.resume",
        json!({ "id": lint }),
    )
    .await;
    s.op(
        &node,
        "an unknown one",
        "remote-1",
        "schedule.pause",
        json!({ "id": "sdeadbeef" }),
    )
    .await;
    let last = s.runs(&nightly).await;
    let run = last[1]["id"].as_str().unwrap().to_owned();
    s.op(
        &node,
        "a run's result",
        "remote-1",
        "schedule.result",
        json!({ "id": run }),
    )
    .await;
    s.op(
        &node,
        "past its end",
        "remote-1",
        "schedule.result",
        json!({ "id": run, "offset": 1000 }),
    )
    .await;
    s.op(
        &node,
        "the list now",
        "remote-1",
        "schedule.list",
        json!({}),
    )
    .await;
    s.drain(&node, &mut socket, "remote-1", "managed").await;
    socket.close().await;

    // The agent runs it; that run's session may not schedule more.
    s.mode("Lint", Mode::Succeeded("Linted."));
    s.op(
        &node,
        "the agent runs it",
        "remote-1",
        "schedule.run",
        json!({ "id": lint }),
    )
    .await;
    let remote = s.delivered("Lint").await;
    for (step, op, args) in [
        (
            "a run proposes",
            "schedule.create",
            json!({ "prompt": "Again.", "cron": "* * * * *" }),
        ),
        ("a run resumes", "schedule.resume", json!({ "id": lint })),
        ("a run runs", "schedule.run", json!({ "id": lint })),
        (
            "a run asks to delete",
            "schedule.delete",
            json!({ "id": lint }),
        ),
    ] {
        s.op(&node, step, &remote, op, args).await;
    }
    node.settled(&remote);
    s.run_reaches(&lint, "completed").await;
    s.forget_relayed();
    // Deleting is a proposal the user approves (security audit L10).
    let deletion = s
        .op(
            &node,
            "the agent proposes deleting it",
            "remote-1",
            "schedule.delete",
            json!({ "id": lint }),
        )
        .await;
    let deletion = deletion["result"]["proposalId"]
        .as_str()
        .unwrap()
        .to_owned();
    s.call(
        "it waits for the user",
        "GET",
        &format!("/api/schedules/{lint}"),
        None,
    )
    .await;
    let (target, body) = answer(&deletion, true);
    s.call("approve the deletion", "POST", &target, Some(body))
        .await;
    s.call("delete the rest", "DELETE", &path, None).await;
    s.call("what is left", "GET", "/api/schedules", None).await;

    node.close().await;
    insta::assert_json_snapshot!("schedules", s.t.into_value());
}
