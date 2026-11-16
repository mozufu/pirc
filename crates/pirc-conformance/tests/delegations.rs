//! Delegations and web search (`apps/gateway/src/daemon/delegations.ts`,
//! `web-search.ts`, their operations in `agent-ops.ts`), with the test
//! playing two nodes: `home`, the chat node whose assistant delegates, and
//! `work`, a directory node that runs the delegated task.

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use pirc_conformance::{
    Api, Cluster, GatewayOptions, Response, Transcript, WebSocket, assert_node_frame,
    browser_headers,
};
use serde_json::{Value, json};
use tokio::sync::mpsc;

const HOME_TOKEN: &str = "conformance-home-token-0123456789abcdef";
const WORK_TOKEN: &str = "conformance-work-token-0123456789abcdef";
const WAIT: Duration = Duration::from_secs(15);

/// How a fake node answers a relayed request (`{method,url,payload,...}`):
/// `{status, body}`.
type Answerer = Arc<dyn Fn(&Value) -> Value + Send + Sync>;

/// A node played by the test: relayed requests are answered by its
/// [`Answerer`] and queued for the test to look at; agent operations are
/// sent on behalf of its sessions.
struct FakeNode {
    outbox: mpsc::UnboundedSender<Value>,
    requests: mpsc::UnboundedReceiver<Value>,
    agent: mpsc::UnboundedReceiver<Value>,
    next_request: u32,
}

impl FakeNode {
    async fn connect(
        api: &Api,
        node_id: &str,
        token: &str,
        register: Value,
        answer: Answerer,
    ) -> Self {
        let headers = vec![
            ("x-pirc-node-id", node_id.to_owned()),
            ("authorization", format!("Bearer {token}")),
        ];
        let mut socket: WebSocket = api.connect("/node/connect", &headers).await.open();
        assert_node_frame(&register);
        socket.send_json(&register).await;
        let registered = socket.next_json().await.expect("registered");
        assert_eq!(registered["type"], "registered", "{registered}");
        let (outbox, mut outgoing) = mpsc::unbounded_channel::<Value>();
        let (request_log, requests) = mpsc::unbounded_channel();
        let (agent_log, agent) = mpsc::unbounded_channel();
        tokio::spawn(async move {
            loop {
                tokio::select! {
                    frame = outgoing.recv() => match frame {
                        Some(Value::Null) | None => {
                            socket.close().await;
                            return;
                        }
                        Some(frame) => socket.send_json(&frame).await,
                    },
                    frame = socket.next_json() => {
                        let Ok(frame) = frame else { return };
                        match frame["type"].as_str() {
                            Some("request") => {
                                let data = frame["data"].clone();
                                let reply = json!({ "type": "response",
                                    "requestId": frame["requestId"], "data": answer(&data) });
                                assert_node_frame(&reply);
                                socket.send_json(&reply).await;
                                let _ = request_log.send(data);
                            }
                            Some("agent_response") => {
                                let _ = agent_log.send(frame);
                            }
                            _ => {}
                        }
                    }
                }
            }
        });
        Self {
            outbox,
            requests,
            agent,
            next_request: 0,
        }
    }

    fn send(&self, frame: Value) {
        assert_node_frame(&frame);
        self.outbox.send(frame).unwrap();
    }

    fn close(&self) {
        self.outbox.send(Value::Null).unwrap();
    }

    /// The next request the gateway relayed to this node.
    async fn request(&mut self) -> Value {
        tokio::time::timeout(WAIT, self.requests.recv())
            .await
            .expect("timed out waiting for a relayed request")
            .expect("node task ended")
    }

    /// Run an agent operation for the node's session `session`: `{status, body}`.
    async fn op(&mut self, session: &str, op: &str, args: Value) -> Value {
        self.next_request += 1;
        let request_id = format!("op-{}", self.next_request);
        self.send(json!({ "type": "agent_request", "requestId": request_id,
            "sessionId": session, "op": op, "args": args }));
        let response = tokio::time::timeout(WAIT, self.agent.recv())
            .await
            .expect("timed out waiting for an agent response")
            .expect("node task ended");
        assert_eq!(response["requestId"], request_id);
        json!({ "status": response["status"], "body": response["body"] })
    }

    /// A node event for its session `session`.
    fn event(&self, session: &str, kind: &str, data: Value) {
        self.send(json!({ "type": "event", "sessionId": session,
            "event": { "type": kind, "data": data } }));
    }
}

fn ok(body: Value) -> Value {
    json!({ "status": 200, "body": body })
}

fn missing() -> Value {
    json!({ "status": 404, "body": { "error": { "code": "not_found", "message": "Not here" } } })
}

/// The chat node: one chat session, `chat-1`.
fn home_answers() -> Answerer {
    Arc::new(|request: &Value| {
        let method = request["method"].as_str().unwrap_or_default();
        let url = request["url"].as_str().unwrap_or_default();
        match (method, url) {
            ("POST", "/api/sessions") => {
                json!({ "status": 201, "body": { "session": { "id": "chat-1" } } })
            }
            ("POST", "/api/sessions/chat-1/control/acquire") => ok(json!({ "lease": {
                "clientId": request["payload"]["clientId"], "generation": 1,
                "expiresAt": 4_000_000_000_000u64 } })),
            ("GET", "/api/sessions/chat-1/snapshot") => ok(json!({
                "session": { "id": "chat-1", "runnerState": "ready", "name": "Chat" },
                "history": [], "interactions": [],
                "watermark": { "epoch": 1, "sequence": 1 },
            })),
            ("POST", "/api/sessions/chat-1/deliver") => ok(json!({ "delivered": true })),
            _ => missing(),
        }
    })
}

/// The directory node: the delegated session `task-1`, whose snapshot the
/// test sets.
fn work_answers(snapshot: Arc<Mutex<Value>>) -> Answerer {
    Arc::new(move |request: &Value| {
        let method = request["method"].as_str().unwrap_or_default();
        let url = request["url"].as_str().unwrap_or_default();
        match (method, url) {
            ("POST", "/api/sessions") => {
                json!({ "status": 201, "body": { "session": { "id": "task-1" } } })
            }
            ("PATCH", "/api/sessions/task-1") => ok(json!({ "session": { "id": "task-1" } })),
            ("POST", "/api/sessions/task-1/deliver") => ok(json!({ "delivered": true })),
            ("GET", "/api/sessions/task-1/snapshot") => ok(snapshot.lock().unwrap().clone()),
            _ => missing(),
        }
    })
}

fn home_registration() -> Value {
    json!({ "type": "register", "role": "chat", "protocol": pirc_protocol::NODE_PROTOCOL_VERSION, "modes": ["chat"],
        "workspaces": [{ "id": "chats", "displayName": "Chats", "mode": "chat" }] })
}

fn work_registration() -> Value {
    json!({ "type": "register", "role": "node", "protocol": pirc_protocol::NODE_PROTOCOL_VERSION, "modes": ["directory"],
        "workspaces": [
            { "id": "repo", "displayName": "Repo", "mode": "directory",
                "roles": [{ "name": "general", "description": "General work" }] },
        ] })
}

async fn start(ttl_ms: Option<u64>) -> Option<Cluster> {
    let mut env = vec![(
        "PIRC_NODE_TOKENS",
        json!({ "home": HOME_TOKEN, "work": WORK_TOKEN }).to_string(),
    )];
    if let Some(ttl) = ttl_ms {
        env.push(("PIRC_DELEGATION_TTL_MS", ttl.to_string()));
    }
    Cluster::start_with(GatewayOptions {
        env,
        without_node: true,
        ..GatewayOptions::default()
    })
    .await
}

/// Delegation ids are random: each becomes `<delegation:n>`.
#[derive(Default)]
struct Ids(Vec<String>);

impl Ids {
    fn learn(&mut self, id: &Value) -> String {
        let id = id.as_str().expect("a delegation id").to_owned();
        if !self.0.contains(&id) {
            self.0.push(id.clone());
        }
        id
    }

    fn scrub_text(&self, text: &str) -> String {
        let mut text = text.to_owned();
        for (at, id) in self.0.iter().enumerate() {
            text = text.replace(id, &format!("<delegation:{}>", at + 1));
        }
        text
    }

    fn scrub(&self, value: &Value) -> Value {
        match value {
            Value::String(text) => Value::String(self.scrub_text(text)),
            Value::Array(items) => items.iter().map(|item| self.scrub(item)).collect(),
            Value::Object(object) => object
                .iter()
                .map(|(key, item)| (self.scrub_text(key), self.scrub(item)))
                .collect(),
            other => other.clone(),
        }
    }
}

struct Recorder {
    t: Transcript,
    ids: Ids,
}

impl Recorder {
    fn note(&mut self, step: &str, value: Value) {
        let value = self.ids.scrub(&value);
        self.t.note(step, value);
    }

    fn response(&mut self, step: &str, request: &str, response: &Response) {
        let scrubbed = Response {
            status: response.status,
            headers: response.headers.clone(),
            body: self.ids.scrub(&response.body),
        };
        let request = self.ids.scrub_text(request);
        self.t.response(step, &request, &scrubbed);
    }
}

/// The type and data of an event (sequences depend on what else happened).
fn event_of(frame: &Value) -> Value {
    json!({ "type": frame["type"], "data": frame["data"] })
}

async fn next_event(socket: &mut WebSocket, kind: &str) -> Value {
    let frames = socket.until(|frame| frame["type"] == kind).await;
    event_of(frames.last().unwrap())
}

async fn wait_for_nodes(api: &Api, count: u64) {
    let deadline = Instant::now() + WAIT;
    loop {
        let health = api
            .send("GET", "/api/health", &browser_headers(), None)
            .await;
        if health.body["nodes"] == count {
            return;
        }
        assert!(Instant::now() < deadline, "nodes did not become {count}");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

/// Create the chat session `chat-1` and take its control; returns its gateway id.
async fn open_chat(api: &Api, home: &mut FakeNode, r: &mut Recorder) -> String {
    open_chat_in(api, home, r, "home:chats").await
}

/// [`open_chat`] in the chat workspace `workspace`.
async fn open_chat_in(api: &Api, home: &mut FakeNode, r: &mut Recorder, workspace: &str) -> String {
    let browser = browser_headers();
    let created = api
        .send(
            "POST",
            "/api/sessions",
            &browser,
            Some(json!({ "workspaceId": workspace })),
        )
        .await;
    assert_eq!(created.status, 201, "{}", created.body);
    home.request().await;
    let chat = created.body["session"]["id"].as_str().unwrap().to_owned();
    let lease = api
        .send(
            "POST",
            &format!("/api/sessions/{chat}/control/acquire"),
            &browser,
            Some(json!({ "clientId": "browser" })),
        )
        .await;
    r.response(
        "take control of the chat",
        "POST /api/sessions/<chat>/control/acquire",
        &lease,
    );
    home.request().await;
    chat
}

async fn answer(api: &Api, chat: &str, id: &str, generation: u64, answer: Value) -> Response {
    api.send(
        "POST",
        &format!("/api/sessions/{chat}/interactions/{id}/answer"),
        &browser_headers(),
        Some(json!({ "clientId": "browser", "generation": generation, "answer": answer })),
    )
    .await
}

async fn chat_interactions(api: &Api, chat: &str, home: &mut FakeNode) -> Value {
    let snapshot = api
        .send(
            "GET",
            &format!("/api/sessions/{chat}/snapshot"),
            &browser_headers(),
            None,
        )
        .await;
    home.request().await;
    snapshot.body["interactions"].clone()
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn delegations() {
    let Some(cluster) = start(None).await else {
        return;
    };
    let api = cluster.api();
    let browser = browser_headers();
    let mut r = Recorder {
        t: Transcript::new(cluster.volatile()),
        ids: Ids::default(),
    };
    let work_snapshot = Arc::new(Mutex::new(json!({})));
    let mut home = FakeNode::connect(
        &api,
        "home",
        HOME_TOKEN,
        home_registration(),
        home_answers(),
    )
    .await;
    let mut work = FakeNode::connect(
        &api,
        "work",
        WORK_TOKEN,
        work_registration(),
        work_answers(work_snapshot.clone()),
    )
    .await;
    wait_for_nodes(&api, 2).await;
    let chat = open_chat(&api, &mut home, &mut r).await;
    let mut events = api
        .connect(&format!("/api/events?sessionId={chat}"), &browser)
        .await
        .open();

    // What the assistant may not ask for.
    for (step, op, args) in [
        (
            "invalid arguments",
            "delegation.create",
            json!({ "workspace": "Repo", "task": 1 }),
        ),
        (
            "a model is the user's choice",
            "delegation.create",
            json!({ "workspace": "Repo", "task": "x", "model": "fake/fake-model" }),
        ),
        ("no workspace", "delegation.create", json!({ "task": "x" })),
        (
            "an unknown workspace",
            "delegation.create",
            json!({ "workspace": "nowhere", "task": "x" }),
        ),
        (
            "the chat workspace",
            "delegation.create",
            json!({ "workspace": "home:chats", "task": "x" }),
        ),
        (
            "an unknown role",
            "delegation.create",
            json!({ "workspace": "Repo", "task": "x", "role": "nope" }),
        ),
        (
            "an empty task",
            "delegation.create",
            json!({ "workspace": "Repo", "task": "  \n " }),
        ),
        (
            "a task over 20000 characters",
            "delegation.create",
            json!({ "workspace": "Repo", "task": "x".repeat(20_001) }),
        ),
        (
            "following up an unknown delegation",
            "delegation.create",
            json!({ "follows": "dmissing", "task": "x" }),
        ),
        (
            "an offset without an id",
            "delegation.status",
            json!({ "offset": 1 }),
        ),
        (
            "status of an unknown delegation",
            "delegation.status",
            json!({ "id": "dmissing" }),
        ),
        ("nothing delegated yet", "delegation.status", json!({})),
        ("an unknown operation", "delegation.cancel", json!({})),
    ] {
        let answer = home.op("chat-1", op, args.clone()).await;
        let args = if step == "a task over 20000 characters" {
            json!({ "workspace": "Repo", "task": "x × 20001" })
        } else {
            args
        };
        r.note(step, json!({ "op": op, "args": args, "answer": answer }));
    }

    // The assistant asks; the user sees a confirmation in the chat.
    let created = home
        .op(
            "chat-1",
            "delegation.create",
            json!({ "workspace": "repo", "task": "Fix the flaky test.\nThen report.",
                "title": "  Fix   flaky\ttest ", "role": "general" }),
        )
        .await;
    let first = r.ids.learn(&created["body"]["result"]["id"]);
    r.note("delegate to Repo as general", created);
    r.note(
        "the chat's event",
        next_event(&mut events, "interaction_created").await,
    );
    r.note(
        "the chat's snapshot shows the confirmation",
        chat_interactions(&api, &chat, &mut home).await,
    );

    // Answering needs the chat's control, and a model the gateway has.
    for (step, generation, given) in [
        ("answer without control", 2, json!({ "confirmed": true })),
        (
            "an unknown model",
            1,
            json!({ "confirmed": true, "model": { "provider": "fake", "id": "nope" } }),
        ),
        (
            "a malformed model",
            1,
            json!({ "confirmed": true, "model": "fake" }),
        ),
        (
            "an unknown thinking level",
            1,
            json!({ "confirmed": true, "model": "fake/fake-model", "thinking": "loud" }),
        ),
        (
            "approve with a model and thinking level, as the user's request for auto mode",
            1,
            json!({ "confirmed": true, "model": "fake/fake-model", "thinking": "high",
                "asUserRequest": true }),
        ),
        ("answer again", 1, json!({ "confirmed": true })),
    ] {
        let response = answer(&api, &chat, &first, generation, given).await;
        r.response(
            step,
            &format!("POST /api/sessions/<chat>/interactions/{first}/answer"),
            &response,
        );
    }
    r.note(
        "the chat's event",
        next_event(&mut events, "interaction_answered").await,
    );

    // The gateway creates and names a session on the work node and delivers the task.
    for step in [
        "work: a session is created",
        "work: it is named",
        "work: the task is delivered (details.asUserRequest: the user ticked it)",
    ] {
        let request = work.request().await;
        r.note(step, request);
    }
    r.note(
        "status while it runs",
        home.op("chat-1", "delegation.status", json!({ "id": first }))
            .await,
    );
    r.note(
        "only chats delegate",
        work.op(
            "task-1",
            "delegation.create",
            json!({ "workspace": "Repo", "task": "x" }),
        )
        .await,
    );

    // The delegated agent asks the user something: the chat hears it.
    let custom = json!({ "role": "custom", "customType": "assistant-delegation",
        "content": "the task", "details": { "delegationId": first, "title": "Fix flaky test" } });
    *work_snapshot.lock().unwrap() = json!({
        "session": { "id": "task-1" },
        "history": [custom],
        "interactions": [{ "id": "ask", "kind": "confirm" }],
        "run": { "status": "running", "createdAt": 1 },
    });
    work.event("task-1", "pi_event", json!({ "type": "agent_settled" }));
    r.note("work: the session is read", work.request().await);
    r.note(
        "the chat shows the delegated session's confirmation",
        next_event(&mut events, "interaction_created").await,
    );
    r.note("the chat hears it waits", home.request().await);

    // It finishes: the chat gets the answer.
    *work_snapshot.lock().unwrap() = json!({
        "session": { "id": "task-1" },
        "history": [
            custom,
            { "role": "assistant", "content": [{ "type": "text", "text": "Thinking." }] },
            { "role": "user", "content": "go on" },
            { "role": "assistant", "content": [{ "type": "text",
                "text": " Fixed it: sk-abcdefghijklmnopqrstuvwxyz was in the log. " }] },
        ],
        "interactions": [],
        "run": { "status": "succeeded", "createdAt": 1 },
    });
    work.event("task-1", "runner_exit", json!({ "code": 0 }));
    r.note("work: the session is read again", work.request().await);
    r.note(
        "the relayed confirmation is gone",
        next_event(&mut events, "interaction_answered").await,
    );
    r.note("the chat hears the result", home.request().await);
    r.note(
        "the delegations",
        home.op("chat-1", "delegation.status", json!({})).await,
    );
    r.note(
        "its result from an offset",
        home.op(
            "chat-1",
            "delegation.status",
            json!({ "id": first, "offset": 10 }),
        )
        .await,
    );
    r.note(
        "an offset past the result",
        home.op(
            "chat-1",
            "delegation.status",
            json!({ "id": first, "offset": 1000 }),
        )
        .await,
    );

    // Follow-ups go to the same session, in its role.
    r.note(
        "a follow-up with a role",
        home.op(
            "chat-1",
            "delegation.create",
            json!({ "follows": first, "task": "x", "role": "general" }),
        )
        .await,
    );
    let more = home
        .op(
            "chat-1",
            "delegation.create",
            json!({ "follows": first, "task": "Also update the docs." }),
        )
        .await;
    let second = r.ids.learn(&more["body"]["result"]["id"]);
    r.note("a follow-up", more);
    r.note(
        "the chat's event",
        next_event(&mut events, "interaction_created").await,
    );
    let declined = answer(&api, &chat, &second, 1, json!({ "confirmed": false })).await;
    r.response(
        "decline it",
        &format!("POST /api/sessions/<chat>/interactions/{second}/answer"),
        &declined,
    );
    r.note(
        "the chat's event",
        next_event(&mut events, "interaction_answered").await,
    );
    r.note("the chat hears it was declined", home.request().await);

    // A workspace whose node went away.
    let third_created = home
        .op(
            "chat-1",
            "delegation.create",
            json!({ "workspace": "work:repo", "task": "Tidy up." }),
        )
        .await;
    let third = r.ids.learn(&third_created["body"]["result"]["id"]);
    r.note("delegate once more", third_created);
    work.close();
    wait_for_nodes(&api, 1).await;
    r.note(
        "delegate to an offline node",
        home.op(
            "chat-1",
            "delegation.create",
            json!({ "workspace": "Repo", "task": "x" }),
        )
        .await,
    );
    let approved = answer(&api, &chat, &third, 1, json!({ "confirmed": true })).await;
    r.response(
        "approve it while the node is away",
        &format!("POST /api/sessions/<chat>/interactions/{third}/answer"),
        &approved,
    );
    r.note("the chat hears it failed", home.request().await);

    // Web search: no key on this gateway.
    for (step, args) in [
        ("web search without a key", json!({ "query": " bun test " })),
        ("web search with a blank query", json!({ "query": "  " })),
        (
            "web search with both domain lists",
            json!({ "query": "x", "includeDomains": ["a.com"], "excludeDomains": ["b.com"] }),
        ),
        (
            "web search with a bad date",
            json!({ "query": "x", "publishedAfter": "yesterday" }),
        ),
        (
            "web search with unknown arguments",
            json!({ "query": "x", "extra": 1 }),
        ),
    ] {
        let answer = home.op("chat-1", "web.search", args.clone()).await;
        r.note(step, json!({ "args": args, "answer": answer }));
    }

    // The chat's capability policy turns them off.
    let patched = api
        .send(
            "PATCH",
            "/api/workspaces/home:chats/capabilities",
            &browser,
            Some(json!({ "capabilities": { "delegation": false, "web_search": false } })),
        )
        .await;
    r.response(
        "turn delegation and web search off",
        "PATCH /api/workspaces/home:chats/capabilities",
        &patched,
    );
    for (step, op, args) in [
        (
            "delegate with delegation off",
            "delegation.create",
            json!({ "workspace": "Repo", "task": "x" }),
        ),
        ("status with delegation off", "delegation.status", json!({})),
        (
            "invalid arguments with delegation off",
            "delegation.status",
            json!({ "id": 5 }),
        ),
        (
            "web search with web search off",
            "web.search",
            json!({ "query": "x" }),
        ),
    ] {
        let answer = home.op("chat-1", op, args.clone()).await;
        r.note(step, json!({ "op": op, "args": args, "answer": answer }));
    }

    home.close();
    insta::assert_json_snapshot!("delegations", r.t.into_value());
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn delegation_expiry() {
    let Some(cluster) = start(Some(1000)).await else {
        return;
    };
    let api = cluster.api();
    let browser = browser_headers();
    let mut r = Recorder {
        t: Transcript::new(cluster.volatile()),
        ids: Ids::default(),
    };
    let mut home = FakeNode::connect(
        &api,
        "home",
        HOME_TOKEN,
        home_registration(),
        home_answers(),
    )
    .await;
    let _work = FakeNode::connect(
        &api,
        "work",
        WORK_TOKEN,
        work_registration(),
        work_answers(Arc::new(Mutex::new(json!({})))),
    )
    .await;
    wait_for_nodes(&api, 2).await;
    let chat = open_chat(&api, &mut home, &mut r).await;
    let mut events = api
        .connect(&format!("/api/events?sessionId={chat}"), &browser)
        .await
        .open();

    let created = home
        .op(
            "chat-1",
            "delegation.create",
            json!({ "workspace": "Repo", "task": "Later." }),
        )
        .await;
    let id = r.ids.learn(&created["body"]["result"]["id"]);
    r.note("delegate", created);
    r.note(
        "the chat's event",
        next_event(&mut events, "interaction_created").await,
    );
    // Nobody approves it in time.
    r.note(
        "the chat's event once it lapsed",
        next_event(&mut events, "interaction_answered").await,
    );
    r.note("the chat hears it lapsed", home.request().await);
    r.note(
        "the chat's snapshot",
        chat_interactions(&api, &chat, &mut home).await,
    );
    let late = answer(&api, &chat, &id, 1, json!({ "confirmed": true })).await;
    r.response(
        "approve it too late",
        &format!("POST /api/sessions/<chat>/interactions/{id}/answer"),
        &late,
    );
    r.note(
        "its status",
        home.op("chat-1", "delegation.status", json!({ "id": id }))
            .await,
    );

    home.close();
    insta::assert_json_snapshot!("delegation_expiry", r.t.into_value());
}

/// `PUT /api/workspaces/:id/links`, recorded.
async fn put_links(api: &Api, r: &mut Recorder, step: &str, workspace: &str, ids: Value) {
    let response = api
        .send(
            "PUT",
            &format!("/api/workspaces/{workspace}/links"),
            &browser_headers(),
            Some(json!({ "workspaceIds": ids })),
        )
        .await;
    r.response(
        step,
        &format!("PUT /api/workspaces/{workspace}/links"),
        &response,
    );
}

/// A chat project linked to directory workspaces (docs/architecture/assistant-memory.md):
/// the links its settings edit, the workspace list its assistant gets, and
/// `delegate` and `memory_search` without a workspace.
#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn project_links() {
    let Some(cluster) = start(None).await else {
        return;
    };
    let api = cluster.api();
    let browser = browser_headers();
    let mut r = Recorder {
        t: Transcript::new(cluster.volatile()),
        ids: Ids::default(),
    };
    let mut home = FakeNode::connect(
        &api,
        "home",
        HOME_TOKEN,
        json!({ "type": "register", "role": "chat",
            "protocol": pirc_protocol::NODE_PROTOCOL_VERSION, "modes": ["chat"],
            "workspaces": [
                { "id": "chats", "displayName": "Chats", "mode": "chat" },
                { "id": "trip", "displayName": "Trip", "mode": "chat" },
            ] }),
        home_answers(),
    )
    .await;
    let work = FakeNode::connect(
        &api,
        "work",
        WORK_TOKEN,
        json!({ "type": "register", "role": "node",
            "protocol": pirc_protocol::NODE_PROTOCOL_VERSION, "modes": ["directory"],
            "workspaces": [
                { "id": "repo", "displayName": "Repo", "mode": "directory",
                    "repo": "github.com/me/repo" },
                // Before Repo by name: the link puts Repo first.
                { "id": "site", "displayName": "Atlas", "mode": "directory" },
            ] }),
        work_answers(Arc::new(Mutex::new(json!({})))),
    )
    .await;
    wait_for_nodes(&api, 2).await;
    open_chat_in(&api, &mut home, &mut r, "home:trip").await;

    put_links(
        &api,
        &mut r,
        "the top-level chats have no links",
        "home:chats",
        json!(["work:repo"]),
    )
    .await;
    put_links(
        &api,
        &mut r,
        "only directory workspaces",
        "home:trip",
        json!(["home:chats"]),
    )
    .await;
    put_links(
        &api,
        &mut r,
        "an unknown workspace",
        "home:trip",
        json!(["work:nope"]),
    )
    .await;
    put_links(&api, &mut r, "link Repo", "home:trip", json!(["work:repo"])).await;
    let listed = api
        .send("GET", "/api/workspaces/home:trip/links", &browser, None)
        .await;
    r.response("the links", "GET /api/workspaces/home:trip/links", &listed);

    for (step, op, args) in [
        ("linked workspaces first", "assistant.context", json!({})),
        (
            "delegate without a workspace goes to the linked one",
            "delegation.create",
            json!({ "task": "Fix the flaky test." }),
        ),
        (
            "search the linked workspaces first",
            "memory.search",
            json!({ "query": "flaky" }),
        ),
        (
            "nothing in the linked workspaces: every workspace",
            "memory.search",
            json!({ "query": "postgres" }),
        ),
        (
            "everywhere skips the links",
            "memory.search",
            json!({ "query": "flaky", "everywhere": true }),
        ),
    ] {
        let mut answer = home.op("chat-1", op, args.clone()).await;
        if op == "delegation.create" {
            r.ids.learn(&answer["body"]["result"]["id"]);
        }
        // A delegation's date is when it was made.
        if let Some(hits) = answer["body"]["result"]["hits"].as_array_mut() {
            for hit in hits {
                hit["date"] = json!("<date>");
            }
        }
        r.note(step, json!({ "op": op, "args": args, "answer": answer }));
    }

    put_links(
        &api,
        &mut r,
        "link Site too",
        "home:trip",
        json!(["work:repo", "work:site"]),
    )
    .await;
    let several = home
        .op("chat-1", "delegation.create", json!({ "task": "x" }))
        .await;
    r.note("with several linked, delegate names one", several);

    // Linked workspaces stay listed while their node is away.
    work.close();
    wait_for_nodes(&api, 1).await;
    r.note(
        "linked workspaces offline",
        home.op("chat-1", "assistant.context", json!({})).await,
    );

    // The node is back without the one linked workspace: removed, not offline.
    let work = FakeNode::connect(
        &api,
        "work",
        WORK_TOKEN,
        json!({ "type": "register", "role": "node",
            "protocol": pirc_protocol::NODE_PROTOCOL_VERSION, "modes": ["directory"],
            "workspaces": [
                { "id": "site", "displayName": "Atlas", "mode": "directory" },
            ] }),
        work_answers(Arc::new(Mutex::new(json!({})))),
    )
    .await;
    wait_for_nodes(&api, 2).await;
    put_links(
        &api,
        &mut r,
        "link only Repo again",
        "home:trip",
        json!(["work:repo"]),
    )
    .await;
    r.note(
        "the one linked workspace was removed from its node",
        home.op("chat-1", "delegation.create", json!({ "task": "x" }))
            .await,
    );
    work.close();

    home.close();
    insta::assert_json_snapshot!("project_links", r.t.into_value());
}

/// A per-session (scratch) mode on a directory node can receive
/// delegations: the assistant sees both targets with their modes, and the
/// gateway starts the delegated session in the scratch workspace.
/// Assertion-based, so it does not depend on the recorded snapshots.
#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn delegation_to_a_per_session_workspace() {
    let Some(cluster) = start(None).await else {
        return;
    };
    let api = cluster.api();
    let browser = browser_headers();
    let modes = cluster.dir.path().join("gateway-config/modes");
    std::fs::write(
        modes.join("scratch.md"),
        "---\nlabel: Scratch\ndescription: One-off sessions in a fresh directory.\n\
         ui:\n  noun: session\nworkdir: per-session\nprompt: [base, body]\n\
         assistant: user\ndelegate_target: true\nschedule_scope: own\n---\n\
         Work in this session's own directory.\n",
    )
    .unwrap();
    cluster.reload_gateway();
    tokio::time::timeout(WAIT, async {
        loop {
            let listed = api.send("GET", "/api/modes", &browser, None).await;
            if listed.body["modes"]
                .as_array()
                .is_some_and(|modes| modes.iter().any(|mode| mode["id"] == "scratch"))
            {
                break;
            }
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
    })
    .await
    .expect("scratch mode loaded");

    let mut home = FakeNode::connect(
        &api,
        "home",
        HOME_TOKEN,
        home_registration(),
        home_answers(),
    )
    .await;
    let mut work = FakeNode::connect(
        &api,
        "work",
        WORK_TOKEN,
        json!({ "type": "register", "role": "node",
            "protocol": pirc_protocol::NODE_PROTOCOL_VERSION, "modes": ["directory", "scratch"],
            "workspaces": [
                { "id": "repo", "displayName": "Repo", "mode": "directory" },
                { "id": "scratch", "displayName": "Scratch", "mode": "scratch" },
            ] }),
        work_answers(Arc::new(Mutex::new(json!({})))),
    )
    .await;
    wait_for_nodes(&api, 2).await;

    // The node lists what it accepts; the scratch workspace is a Work one.
    let nodes = api.send("GET", "/api/nodes", &browser, None).await;
    let work_node = nodes.body["nodes"]
        .as_array()
        .and_then(|nodes| nodes.iter().find(|node| node["id"] == "work"))
        .cloned()
        .unwrap_or_else(|| panic!("work node listed: {}", nodes.body));
    assert_eq!(work_node["modes"], json!(["directory", "scratch"]));
    let workspaces = api.send("GET", "/api/workspaces", &browser, None).await;
    let scratch = workspaces.body["workspaces"]
        .as_array()
        .and_then(|items| items.iter().find(|item| item["id"] == "work:scratch"))
        .cloned()
        .unwrap_or_else(|| panic!("scratch workspace listed: {}", workspaces.body));
    assert_eq!(scratch["mode"], "scratch");
    assert_eq!(scratch["available"], true);

    let mut r = Recorder {
        t: Transcript::new(cluster.volatile()),
        ids: Ids::default(),
    };
    let chat = open_chat(&api, &mut home, &mut r).await;

    // Both targets carry their mode, so the assistant can tell them apart.
    let context = home.op("chat-1", "assistant.context", json!({})).await;
    assert_eq!(context["status"], 200, "{context}");
    let listed = context["body"]["result"]["workspaces"]
        .as_array()
        .cloned()
        .unwrap_or_else(|| panic!("workspaces in context: {context}"));
    let mode_of = |id: &str| {
        listed
            .iter()
            .find(|item| item["id"] == id)
            .map(|item| item["mode"].clone())
            .unwrap_or_else(|| panic!("{id} in {listed:?}"))
    };
    assert_eq!(
        mode_of("work:scratch"),
        json!({ "id": "scratch", "label": "Scratch",
            "description": "One-off sessions in a fresh directory." })
    );
    assert_eq!(mode_of("work:repo")["label"], "Work");

    let created = home
        .op(
            "chat-1",
            "delegation.create",
            json!({ "workspace": "work:scratch", "task": "Render a test image." }),
        )
        .await;
    assert_eq!(created["status"], 200, "{created}");
    let id = created["body"]["result"]["id"]
        .as_str()
        .unwrap_or_else(|| panic!("a delegation id: {created}"))
        .to_owned();
    let approved = answer(&api, &chat, &id, 1, json!({ "confirmed": true })).await;
    assert_eq!(approved.status, 200, "{}", approved.body);
    let session = work.request().await;
    assert_eq!(session["method"], "POST", "{session}");
    assert_eq!(session["url"], "/api/sessions", "{session}");
    assert_eq!(session["payload"]["workspaceId"], "scratch", "{session}");
    let named = work.request().await;
    assert_eq!(named["method"], "PATCH", "{named}");
    let delivered = work.request().await;
    assert_eq!(
        delivered["url"], "/api/sessions/task-1/deliver",
        "{delivered}"
    );
    assert!(
        delivered["payload"]
            .to_string()
            .contains("Render a test image."),
        "{delivered}"
    );
    work.close();
    home.close();
}

/// The directory node of [`delegation_autonomy`]: [`work_answers`], plus
/// relayed answers and the control and stop command the gateway's Stop uses.
fn autonomy_work_answers(snapshot: Arc<Mutex<Value>>) -> Answerer {
    let base = work_answers(snapshot);
    let created = Arc::new(std::sync::atomic::AtomicU32::new(0));
    Arc::new(move |request: &Value| {
        let method = request["method"].as_str().unwrap_or_default();
        let url = request["url"].as_str().unwrap_or_default();
        match (method, url) {
            // Sessions after the first get their own ids.
            ("POST", "/api/sessions")
                if created.fetch_add(1, std::sync::atomic::Ordering::SeqCst) > 0 =>
            {
                let n = created.load(std::sync::atomic::Ordering::SeqCst);
                json!({ "status": 201, "body": { "session": { "id": format!("task-{n}") } } })
            }
            ("PATCH" | "POST", _)
                if url.starts_with("/api/sessions/task-")
                    && !url.starts_with("/api/sessions/task-1/")
                    && url != "/api/sessions/task-1" =>
            {
                ok(json!({ "delivered": true }))
            }
            ("POST", "/api/sessions/task-1/interactions/interaction_1/relayed-answer") => {
                ok(json!({ "interactionId": "interaction_1", "status": "answered" }))
            }
            ("POST", "/api/sessions/task-1/control/acquire") => ok(json!({ "lease": {
                "clientId": request["payload"]["clientId"], "generation": 7,
                "expiresAt": 4_000_000_000_000u64 } })),
            ("POST", "/api/sessions/task-1/commands") => json!({ "status": 202,
                "body": { "command": { "id": request["payload"]["commandId"],
                    "status": "accepted" }, "duplicate": false } }),
            ("POST", "/api/sessions/task-1/control/release") => json!({ "status": 204 }),
            _ => base(request),
        }
    })
}

async fn set_approval(api: &Api, policy: &str) {
    let patched = api
        .send(
            "PATCH",
            "/api/workspaces/home:chats/capabilities",
            &browser_headers(),
            Some(json!({ "capabilities": { "delegation_approval": policy } })),
        )
        .await;
    assert_eq!(patched.status, 200, "{}", patched.body);
    assert_eq!(
        patched.body["capabilities"]["delegation_approval"], policy,
        "{}",
        patched.body
    );
}

/// Delegation without the approval card (plans/delegation-autonomy.md):
/// the chat workspace's `delegation_approval` policy, the untrusted-context
/// fallback, the cap on automatic delegations, verified quotes reaching the
/// delegated run, approvals relayed to the chat and answered there without
/// a lease, and Stop.
#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn delegation_autonomy() {
    let Some(cluster) = start(None).await else {
        return;
    };
    let api = cluster.api();
    let browser = browser_headers();
    let work_snapshot = Arc::new(Mutex::new(json!({})));
    let mut home = FakeNode::connect(
        &api,
        "home",
        HOME_TOKEN,
        home_registration(),
        home_answers(),
    )
    .await;
    let mut work = FakeNode::connect(
        &api,
        "work",
        WORK_TOKEN,
        work_registration(),
        autonomy_work_answers(work_snapshot.clone()),
    )
    .await;
    wait_for_nodes(&api, 2).await;
    let mut r = Recorder {
        t: Transcript::new(cluster.volatile()),
        ids: Ids::default(),
    };
    let chat = open_chat(&api, &mut home, &mut r).await;
    let mut events = api
        .connect(&format!("/api/events?sessionId={chat}"), &browser)
        .await
        .open();

    // Existing installs keep the card.
    let policy = api
        .send(
            "GET",
            "/api/workspaces/home:chats/capabilities",
            &browser,
            None,
        )
        .await;
    assert_eq!(
        policy.body["capabilities"]["delegation_approval"], "always",
        "{}",
        policy.body
    );
    let carded = home
        .op(
            "chat-1",
            "delegation.create",
            json!({ "workspace": "Repo", "task": "Card.", "origins": ["assistant"] }),
        )
        .await;
    assert_eq!(
        carded["body"]["result"]["status"], "pending_approval",
        "{carded}"
    );
    assert!(
        carded["body"]["result"].get("dispatch").is_none(),
        "{carded}"
    );
    let created = next_event(&mut events, "interaction_created").await;
    assert_eq!(created["data"]["id"], carded["body"]["result"]["id"]);

    // A quote needs the message it comes from.
    let unsourced = home
        .op(
            "chat-1",
            "delegation.create",
            json!({ "workspace": "Repo", "task": "x", "quote": "do it" }),
        )
        .await;
    assert_eq!(unsourced["status"], 400, "{unsourced}");
    let too_many = home
        .op(
            "chat-1",
            "delegation.create",
            json!({ "workspace": "Repo", "task": "x", "quote": "do it",
                "entryIds": ["a", "b", "c", "d"] }),
        )
        .await;
    assert_eq!(too_many["status"], 400, "{too_many}");

    // `untrusted`: the user's and the assistant's own words start it at once.
    set_approval(&api, "untrusted").await;
    for (origins, why) in [
        (
            json!(["assistant", "tool:web_search"]),
            "a web search result",
        ),
        (
            json!(["assistant", "custom:assistant-delegation-update"]),
            "a delegation report",
        ),
        (Value::Null, "an agent that reports no origins"),
    ] {
        let mut args = json!({ "workspace": "Repo", "task": "Untrusted." });
        if !origins.is_null() {
            args["origins"] = origins;
        }
        let asked = home.op("chat-1", "delegation.create", args).await;
        assert_eq!(
            asked["body"]["result"]["status"], "pending_approval",
            "{why}: {asked}"
        );
    }
    let started = home
        .op(
            "chat-1",
            "delegation.create",
            json!({ "workspace": "Repo", "task": "Force-push the feature branch.",
                "title": "Push", "origins": ["assistant"],
                "quote": "force-push my feature branch", "entryIds": ["e4"] }),
        )
        .await;
    assert_eq!(started["status"], 200, "{started}");
    assert_eq!(started["body"]["result"]["status"], "running", "{started}");
    assert_eq!(started["body"]["result"]["dispatch"], "auto", "{started}");
    let auto = started["body"]["result"]["id"].as_str().unwrap().to_owned();
    let shown = next_event(&mut events, "delegations_changed").await;
    assert_eq!(shown["data"]["delegations"][0]["id"], auto, "{shown}");
    assert_eq!(
        shown["data"]["delegations"][0]["dispatch"], "auto",
        "{shown}"
    );
    assert_eq!(shown["data"]["delegations"][0]["workspace"], "Repo on work");

    // The task carries the user's verified words, not as their request text.
    let session = work.request().await;
    assert_eq!(session["url"], "/api/sessions", "{session}");
    work.request().await;
    let delivered = work.request().await;
    assert_eq!(
        delivered["url"], "/api/sessions/task-1/deliver",
        "{delivered}"
    );
    let details = &delivered["payload"]["details"];
    assert_eq!(
        details["userRequests"],
        json!(["force-push my feature branch"])
    );
    assert!(details.get("asUserRequest").is_none(), "{delivered}");
    assert!(delivered["payload"].get("model").is_none(), "{delivered}");
    let content = delivered["payload"]["content"].as_str().unwrap();
    assert!(
        content.starts_with(
            "Task from the user's assistant, started under the user's delegation setting without a separate approval"
        ),
        "{content}"
    );

    // The snapshot lists it with Stop.
    let snapshot = api
        .send(
            "GET",
            &format!("/api/sessions/{chat}/snapshot"),
            &browser,
            None,
        )
        .await;
    home.request().await;
    let listed = snapshot.body["delegations"].as_array().unwrap().clone();
    assert_eq!(listed.len(), 1, "{listed:?}");
    let target = listed[0]["targetSessionId"].as_str().unwrap().to_owned();

    // The delegated session waits on an approval: the chat shows it.
    let custom = json!({ "role": "custom", "customType": "assistant-delegation",
        "content": "the task", "details": { "delegationId": auto } });
    *work_snapshot.lock().unwrap() = json!({
        "session": { "id": "task-1" },
        "history": [custom],
        "interactions": [{ "id": "interaction_1", "kind": "confirm", "runnerEpoch": 3,
            "request": { "method": "confirm",
                "title": "Auto mode: allow a potentially dangerous action?",
                "message": "git push -f origin feature" },
            "createdAt": 5 }],
        "run": { "status": "running", "createdAt": 1 },
    });
    work.event(
        "task-1",
        "interaction_created",
        json!({ "id": "interaction_1" }),
    );
    work.request().await;
    let relayed = next_event(&mut events, "interaction_created").await;
    let relay = format!("relay.{auto}.interaction_1");
    assert_eq!(
        relayed["data"],
        json!({ "id": relay, "rpcId": relay, "sessionId": chat, "runnerEpoch": 0,
            "kind": "confirm", "status": "pending",
            "request": { "method": "confirm",
                "title": "Auto mode: allow a potentially dangerous action?",
                "message": "git push -f origin feature",
                "relayed": { "sessionId": target, "sessionName": "Push",
                    "workspace": "Repo on work", "delegationId": auto } },
            "createdAt": 5 })
    );
    assert!(
        chat_interactions(&api, &chat, &mut home)
            .await
            .as_array()
            .unwrap()
            .iter()
            .any(|item| item["id"] == relay)
    );
    // Needs you can answer it from the delegated session's row.
    let sessions = api.send("GET", "/api/sessions", &browser, None).await;
    let row = sessions.body["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|session| session["id"] == target.as_str())
        .cloned()
        .unwrap();
    assert_eq!(
        row["origin"]["approval"],
        json!({ "sessionId": chat, "interactionId": relay,
            "title": "Auto mode: allow a potentially dangerous action?",
            "message": "git push -f origin feature" }),
        "{row}"
    );

    // Answered from the chat without its control: the node gets it.
    let answered = api
        .send(
            "POST",
            &format!("/api/sessions/{chat}/interactions/{relay}/answer"),
            &browser,
            Some(json!({ "answer": { "confirmed": true } })),
        )
        .await;
    assert_eq!(answered.status, 200, "{}", answered.body);
    let relayed_answer = work.request().await;
    assert_eq!(
        (
            relayed_answer["url"].clone(),
            relayed_answer["payload"].clone()
        ),
        (
            json!("/api/sessions/task-1/interactions/interaction_1/relayed-answer"),
            json!({ "answer": { "confirmed": true } })
        )
    );
    let gone = next_event(&mut events, "interaction_answered").await;
    assert_eq!(gone["data"]["interactionId"], relay);
    let again = api
        .send(
            "POST",
            &format!("/api/sessions/{chat}/interactions/{relay}/answer"),
            &browser,
            Some(json!({ "answer": { "confirmed": true } })),
        )
        .await;
    assert_eq!(again.status, 409, "{}", again.body);
    let unknown = api
        .send(
            "POST",
            &format!("/api/sessions/{chat}/interactions/relay.dnope.x/answer"),
            &browser,
            Some(json!({ "answer": { "confirmed": true } })),
        )
        .await;
    assert_eq!(unknown.status, 404, "{}", unknown.body);

    // Stop: the gateway takes the delegated session's control, stops it, lets go.
    *work_snapshot.lock().unwrap() = json!({
        "session": { "id": "task-1" }, "history": [custom], "interactions": [],
        "run": { "status": "running", "createdAt": 1 },
    });
    let stopped = api
        .send(
            "POST",
            &format!("/api/delegations/{auto}/stop"),
            &browser,
            None,
        )
        .await;
    assert_eq!(stopped.status, 200, "{}", stopped.body);
    let mut urls = Vec::new();
    while urls.len() < 3 {
        let request = work.request().await;
        let url = request["url"].as_str().unwrap().to_owned();
        if url.ends_with("/snapshot") {
            continue;
        }
        if url.ends_with("/commands") {
            assert_eq!(request["payload"]["payload"], json!({ "type": "stop" }));
            assert_eq!(request["payload"]["generation"], 7);
        }
        urls.push(url);
    }
    assert_eq!(
        urls,
        [
            "/api/sessions/task-1/control/acquire",
            "/api/sessions/task-1/commands",
            "/api/sessions/task-1/control/release"
        ]
    );
    let missing = api
        .send("POST", "/api/delegations/dnope/stop", &browser, None)
        .await;
    assert_eq!(missing.status, 404, "{}", missing.body);

    // `never`, up to the cap of automatic delegations running at once.
    set_approval(&api, "never").await;
    let mut dispatched = Vec::new();
    for _ in 0..4 {
        let created = home
            .op(
                "chat-1",
                "delegation.create",
                json!({ "workspace": "Repo", "task": "More.",
                    "origins": ["assistant", "tool:browser"] }),
            )
            .await;
        dispatched.push(created["body"]["result"]["status"].clone());
    }
    // One already runs: three more start, the fourth waits for the card.
    let all = home.op("chat-1", "delegation.status", json!({})).await;
    assert_eq!(
        dispatched,
        [
            json!("running"),
            json!("running"),
            json!("running"),
            json!("pending_approval")
        ],
        "{all}"
    );
    work.close();
    home.close();
}
