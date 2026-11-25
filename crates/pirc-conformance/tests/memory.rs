//! The assistant's memory (`apps/gateway/src/daemon/memory*.ts`) and its
//! agent operations (`assistant.context`, `memory.note`,
//! `memory.proposeUser`, `memory.search`, `recall.remote` in
//! `agent-ops.ts`), with the test playing a chat node and a directory node.
//! Also the chat-workspace paths of the session routes: capabilities,
//! instructions, deleting a chat and the assistant node binding.

use std::collections::HashMap;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use pirc_conformance::{
    Api, Cluster, GatewayOptions, NODE_ID, NODE_TOKEN, Response, Transcript, WebSocket,
    assert_node_frame, browser_headers,
};
use regex::Regex;
use serde_json::{Value, json};
use tokio::sync::mpsc;

const DEV_ID: &str = "dev";
const DEV_TOKEN: &str = "conformance-dev-token-0123456789abcdef";
const CHAT_LEDGER: &str = "cccccccccccccccc";
const DEV_LEDGER: &str = "dddddddddddddddd";
// Workspace-memory note ids (hashes of their content on a real node).
const STAGED: &str = "a00000000001";
const UNREADABLE: &str = "a00000000002";
const NOBODY: &str = "a00000000003";
const NO_SESSION: &str = "a00000000004";
const DEV_NOTE: &str = "b00000000001";
const RETIRED: &str = "b00000000002";

type Answer = Box<dyn Fn(&Value) -> Value + Send + Sync>;

/// A node the test plays: relayed requests are answered with `answer` (and
/// logged); every other frame is passed on.
struct FakeNode {
    out: Option<mpsc::UnboundedSender<Value>>,
    frames: mpsc::UnboundedReceiver<Value>,
    relayed: Arc<Mutex<Vec<Value>>>,
    task: tokio::task::JoinHandle<()>,
    requests: usize,
}

enum Step {
    Out(Option<Value>),
    In(Result<Value, (u16, String)>),
}

impl FakeNode {
    /// Connect and register; returns the node and its `registered` frame.
    async fn connect(
        api: &Api,
        id: &str,
        token: &str,
        register: Value,
        answer: Answer,
    ) -> (Self, Value) {
        let headers = vec![
            ("x-pirc-node-id", id.to_owned()),
            ("authorization", format!("Bearer {token}")),
        ];
        let mut socket: WebSocket = api.connect("/node/connect", &headers).await.open();
        assert_node_frame(&register);
        socket.send_json(&register).await;
        let registered = socket.next_json().await.expect("registered");
        let (out, mut outgoing) = mpsc::unbounded_channel::<Value>();
        let (incoming, frames) = mpsc::unbounded_channel();
        let relayed = Arc::new(Mutex::new(Vec::new()));
        let log = relayed.clone();
        let task = tokio::spawn(async move {
            loop {
                let step = tokio::select! {
                    frame = outgoing.recv() => Step::Out(frame),
                    message = socket.next_json() => Step::In(message),
                };
                match step {
                    Step::Out(Some(frame)) => socket.send_json(&frame).await,
                    Step::Out(None) => {
                        socket.close().await;
                        return;
                    }
                    Step::In(Ok(frame)) if frame["type"] == "request" => {
                        log.lock().unwrap().push(frame["data"].clone());
                        let reply = json!({ "type": "response", "requestId": frame["requestId"],
                            "data": answer(&frame["data"]) });
                        socket.send_json(&reply).await;
                    }
                    Step::In(Ok(frame)) => {
                        let _ = incoming.send(frame);
                    }
                    Step::In(Err((code, reason))) => {
                        let _ = incoming
                            .send(json!({ "type": "closed", "code": code, "reason": reason }));
                        return;
                    }
                }
            }
        });
        let node = Self {
            out: Some(out),
            frames,
            relayed,
            task,
            requests: 0,
        };
        (node, registered)
    }

    fn send(&self, frame: Value) {
        assert_node_frame(&frame);
        self.out.as_ref().unwrap().send(frame).unwrap();
    }

    async fn next(&mut self, wanted: impl Fn(&Value) -> bool) -> Value {
        loop {
            let frame = tokio::time::timeout(Duration::from_secs(20), self.frames.recv())
                .await
                .expect("timed out waiting for a frame from the gateway")
                .expect("node task ended");
            if wanted(&frame) {
                return frame;
            }
        }
    }

    /// An agent operation of `session` (the node's id of it): `{status, body}`.
    async fn op(&mut self, session: &str, op: &str, args: Value) -> Value {
        self.requests += 1;
        let request_id = format!("r{}", self.requests);
        self.send(json!({ "type": "agent_request", "requestId": request_id,
            "sessionId": session, "op": op, "args": args }));
        let response = self
            .next(|frame| frame["type"] == "agent_response" && frame["requestId"] == request_id)
            .await;
        json!({ "status": response["status"], "body": response["body"] })
    }

    /// A `memory_mirror` chunk and the gateway's acknowledgement.
    async fn mirror(&mut self, frame: Value) -> Value {
        let mut frame = frame;
        frame["type"] = json!("memory_mirror");
        self.send(frame);
        self.next(|frame| frame["type"] == "memory_mirror_ack")
            .await
    }

    fn take_relayed(&self) -> Vec<Value> {
        std::mem::take(&mut *self.relayed.lock().unwrap())
    }

    /// Close the link (as the node going away).
    async fn disconnect(mut self) {
        self.out.take();
        let _ = self.task.await;
    }
}

fn lease(request: &Value) -> Value {
    json!({ "status": 200, "body": { "lease": { "clientId": request["payload"]["clientId"],
        "generation": 1, "expiresAt": 4_000_000_000_000u64 } } })
}

/// The chat node's answers. Sessions are `remote-a`, then `remote-b`.
fn chat_answer() -> Answer {
    let created = AtomicUsize::new(0);
    Box::new(move |request| {
        let method = request["method"].as_str().unwrap_or_default();
        let url = request["url"].as_str().unwrap_or_default();
        let ok = |body: Value| json!({ "status": 200, "body": body });
        match (method, url) {
            ("POST", "/api/sessions") => {
                let name = ["remote-a", "remote-b"][created.fetch_add(1, Ordering::SeqCst).min(1)];
                json!({ "status": 201, "body": { "session": { "id": name } } })
            }
            ("GET", url) if url.ends_with("/snapshot") => ok(json!({
                "session": { "id": "remote-a", "runnerState": "ready" },
                "history": [], "interactions": [{ "id": "node-interaction" }],
                "watermark": { "epoch": 0, "sequence": 0 },
            })),
            ("POST", url) if url.ends_with("/control/acquire") => lease(request),
            ("GET", "/api/workspaces/chat/instructions") => ok(json!({ "text": "Be kind." })),
            ("PATCH", "/api/workspaces/chat/instructions") => {
                ok(json!({ "text": request["payload"]["text"], "saved": true }))
            }
            ("DELETE", _) => json!({ "status": 204 }),
            ("POST", "/api/workspace-memory/recall") => {
                if request["payload"]["id"] == STAGED {
                    ok(
                        json!({ "text": "[note] Deploys go through staging first (from the session)" }),
                    )
                } else {
                    json!({ "status": 500, "body": { "error": { "code": "internal_error",
                        "message": "Internal server error" } } })
                }
            }
            _ => ok(json!({ "relayed": true })),
        }
    })
}

/// The directory node's answers: its one session is `dev-1`.
fn dev_answer() -> Answer {
    Box::new(|request| match request["method"].as_str() {
        Some("POST") if request["url"] == "/api/sessions" => {
            json!({ "status": 201, "body": { "session": { "id": "dev-1" } } })
        }
        _ => json!({ "status": 200, "body": { "relayed": true } }),
    })
}

/// Memory ids (`n…`, `u…`, `p…` and 8 hex digits) are random: they become
/// stable placeholders, numbered by first appearance.
struct Ids {
    pattern: Regex,
    seen: HashMap<String, String>,
}

impl Ids {
    fn new() -> Self {
        Self {
            pattern: Regex::new(r"\b[nup][0-9a-f]{8}\b").unwrap(),
            seen: HashMap::new(),
        }
    }

    fn text(&mut self, text: &str) -> String {
        let pattern = self.pattern.clone();
        pattern
            .replace_all(text, |found: &regex::Captures<'_>| {
                let id = found[0].to_owned();
                let count = self.seen.len() + 1;
                self.seen
                    .entry(id.clone())
                    .or_insert_with(|| format!("<{}{count}>", &id[..1]))
                    .clone()
            })
            .into_owned()
    }

    fn value(&mut self, value: &Value) -> Value {
        match value {
            Value::String(text) => Value::String(self.text(text)),
            Value::Array(items) => items.iter().map(|item| self.value(item)).collect(),
            Value::Object(object) => Value::Object(
                object
                    .iter()
                    .map(|(key, item)| (self.text(key), self.value(item)))
                    .collect(),
            ),
            other => other.clone(),
        }
    }
}

fn item(id: &str, content: &str, session: Option<&str>, timestamp: &str) -> Value {
    let mut item = json!({ "id": id, "content": content, "relevance": "high",
        "timestamp": timestamp, "sourceMemoryIds": [] });
    if let Some(session) = session {
        item["sessionId"] = json!(session);
    }
    item
}

/// Wait until the gateway no longer lists `node`.
async fn offline(api: &Api, node: &str) {
    for _ in 0..400 {
        let nodes = api
            .send("GET", "/api/nodes", &browser_headers(), None)
            .await;
        if !nodes.body["nodes"]
            .as_array()
            .unwrap()
            .iter()
            .any(|n| n["id"] == node)
        {
            return;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    panic!("{node} stayed online");
}

#[ignore = "pirc 2: assistant chat mode is removed with the feature in M4.10"]
#[tokio::test(flavor = "multi_thread")]
async fn memory() {
    let Some(cluster) = Cluster::start_with(GatewayOptions {
        without_node: true,
        env: vec![
            (
                "PIRC_NODE_TOKENS",
                json!({ NODE_ID: NODE_TOKEN, DEV_ID: DEV_TOKEN }).to_string(),
            ),
            ("PIRC_MEMORY_USER_CHARS", "80".to_owned()),
            ("PIRC_MEMORY_NOTE_CHARS", "120".to_owned()),
        ],
        ..GatewayOptions::default()
    })
    .await
    else {
        return;
    };
    let api = cluster.api();
    let browser = browser_headers();
    let mut t = Transcript::new(cluster.volatile());
    let ids = Arc::new(Mutex::new(Ids::new()));
    let chat_register = json!({
        "type": "register", "role": "chat", "protocol": pirc_protocol::NODE_PROTOCOL_VERSION, "modes": ["chat"],
        "workspaces": [{ "id": "chat", "displayName": "Assistant", "mode": "chat" }],
    });
    let (mut chat, registered) = FakeNode::connect(
        &api,
        NODE_ID,
        NODE_TOKEN,
        chat_register.clone(),
        chat_answer(),
    )
    .await;
    t.note("the chat node registers", registered);

    let mut dev: Option<FakeNode> = None;
    fn dev_relayed(dev: &Option<FakeNode>) -> Vec<Value> {
        dev.as_ref().map(FakeNode::take_relayed).unwrap_or_default()
    }
    let mut marks = 0;
    macro_rules! mask {
        ($value:expr) => {
            ids.lock().unwrap().value(&$value)
        };
    }
    macro_rules! call {
        ($step:expr, $method:expr, $path:expr, $body:expr) => {{
            let target = String::from($path);
            let response = api.send($method, &target, &browser, $body).await;
            let masked = Response {
                status: response.status,
                headers: response.headers.clone(),
                body: mask!(response.body),
            };
            let request = ids.lock().unwrap().text(&format!("{} {}", $method, target));
            t.response($step, &request, &masked);
            let mut requests: Vec<Value> = chat.take_relayed();
            requests.extend(dev_relayed(&dev));
            if !requests.is_empty() {
                t.note(&format!("{}: relayed", $step), mask!(json!(requests)));
            }
            // Memory orders by milliseconds: keep steps apart.
            tokio::time::sleep(Duration::from_millis(3)).await;
            response
        }};
    }
    macro_rules! op {
        ($step:expr, $node:expr, $session:expr, $op:expr, $args:expr) => {{
            let answer = $node.op($session, $op, $args).await;
            let mut relayed = chat.take_relayed();
            relayed.extend(dev_relayed(&dev));
            let mut observed = json!({ "op": $op, "session": $session, "answer": answer });
            if !relayed.is_empty() {
                observed["relayed"] = json!(relayed);
            }
            t.note($step, mask!(observed));
            tokio::time::sleep(Duration::from_millis(3)).await;
            answer
        }};
    }
    // Frames `socket` received up to a node event marker of `remote-a`.
    macro_rules! seen {
        ($step:expr, $socket:expr) => {{
            marks += 1;
            let marker = format!("m{marks}");
            chat.send(json!({ "type": "event", "sessionId": "remote-a",
                "event": { "type": "marker", "data": marker } }));
            let frames = $socket
                .until(|frame| frame["type"] == "marker" && frame["data"] == marker.as_str())
                .await;
            t.note($step, mask!(json!(frames)));
        }};
    }

    call!("the assistant node", "GET", "/api/assistant/node", None);
    let created = call!(
        "create a chat",
        "POST",
        "/api/sessions",
        Some(json!({ "workspaceId": "test:chat" }))
    );
    let a = created.body["session"]["id"].as_str().unwrap().to_owned();
    let created = call!(
        "create another chat",
        "POST",
        "/api/sessions",
        Some(json!({ "workspaceId": "test:chat" }))
    );
    let b = created.body["session"]["id"].as_str().unwrap().to_owned();

    // ---- chat workspace routes ----
    call!(
        "capabilities of the chat workspace",
        "GET",
        "/api/workspaces/test:chat/capabilities",
        None
    );
    call!(
        "turn remote recall off",
        "PATCH",
        "/api/workspaces/test:chat/capabilities",
        Some(json!({ "capabilities": { "remote_recall": false, "web_search": false } }))
    );
    call!(
        "an unknown capability",
        "PATCH",
        "/api/workspaces/test:chat/capabilities",
        Some(json!({ "capabilities": { "teleport": true } }))
    );
    op!(
        "recall with the capability off",
        chat,
        "remote-a",
        "recall.remote",
        json!({ "id": "0123456789ab" })
    );
    op!(
        "invalid arguments come before the capability",
        chat,
        "remote-a",
        "recall.remote",
        json!({ "id": "nope" })
    );
    call!(
        "turn it on again",
        "PATCH",
        "/api/workspaces/test:chat/capabilities",
        Some(json!({ "capabilities": { "remote_recall": true } }))
    );
    call!(
        "the chat's instructions",
        "GET",
        "/api/workspaces/test:chat/instructions",
        None
    );
    call!(
        "change them",
        "PATCH",
        "/api/workspaces/test:chat/instructions",
        Some(json!({ "text": "Be brief." }))
    );
    call!(
        "instructions that are not text",
        "PATCH",
        "/api/workspaces/test:chat/instructions",
        Some(json!({ "text": 1 }))
    );
    call!(
        "instructions with another field",
        "PATCH",
        "/api/workspaces/test:chat/instructions",
        Some(json!({ "text": "x", "extra": true }))
    );
    call!(
        "instructions of an unknown workspace",
        "GET",
        "/api/workspaces/test:nope/instructions",
        None
    );

    // ---- notes ----
    let mut live = api
        .connect(&format!("/api/events?sessionId={a}&memory=1"), &browser)
        .await
        .open();
    op!(
        "a new assistant's context",
        chat,
        "remote-a",
        "assistant.context",
        json!({})
    );
    op!(
        "context takes no arguments",
        chat,
        "remote-a",
        "assistant.context",
        json!({ "x": 1 })
    );
    let added = op!(
        "add a note",
        chat,
        "remote-a",
        "memory.note",
        json!({ "action": "add", "content": "The pirc repo\n lives on m5pro", "origins": ["assistant"],
            "entryIds": ["e1"], "quote": "it is on m5pro" })
    );
    let note_id = added["body"]["result"]["id"].as_str().unwrap().to_owned();
    seen!("a note added: memory changed", live);
    op!(
        "the same note again",
        chat,
        "remote-a",
        "memory.note",
        json!({ "action": "add", "content": "THE PIRC REPO LIVES ON M5PRO", "origins": ["assistant"] })
    );
    seen!("nothing changed", live);
    op!(
        "replace without the seen revision",
        chat,
        "remote-a",
        "memory.note",
        json!({ "action": "replace", "id": note_id, "content": "x", "baseRevision": 0,
            "origins": ["assistant"] })
    );
    op!(
        "replace",
        chat,
        "remote-a",
        "memory.note",
        json!({ "action": "replace", "id": note_id, "content": "The pirc repo lives on lumo",
            "baseRevision": 1, "origins": ["assistant", "tool:bash"] })
    );
    op!(
        "a note too large for the budget",
        chat,
        "remote-a",
        "memory.note",
        json!({ "action": "add", "content": "y".repeat(100), "origins": ["assistant"] })
    );
    op!(
        "a note too long for one entry",
        chat,
        "remote-a",
        "memory.note",
        json!({ "action": "add", "content": "z ".repeat(600), "origins": ["assistant"] })
    );
    op!(
        "a note with a secret",
        chat,
        "remote-a",
        "memory.note",
        json!({ "action": "add", "content": format!("token ghp_{}", "a".repeat(36)),
            "origins": ["user"] })
    );
    op!(
        "remove at an old revision",
        chat,
        "remote-a",
        "memory.note",
        json!({ "action": "remove", "id": note_id, "baseRevision": 1, "origins": ["assistant"] })
    );
    op!(
        "remove",
        chat,
        "remote-a",
        "memory.note",
        json!({ "action": "remove", "id": note_id, "baseRevision": 2, "origins": ["assistant"] })
    );
    op!(
        "replace a removed note",
        chat,
        "remote-a",
        "memory.note",
        json!({ "action": "replace", "id": note_id, "content": "again", "baseRevision": 3,
            "origins": ["assistant"] })
    );
    op!(
        "an unknown note",
        chat,
        "remote-a",
        "memory.note",
        json!({ "action": "replace", "id": "n00000000", "content": "x", "baseRevision": 1,
            "origins": ["assistant"] })
    );
    op!(
        "a note without origins",
        chat,
        "remote-a",
        "memory.note",
        json!({ "action": "add", "content": "x", "origins": [] })
    );
    op!(
        "a note with a null quote",
        chat,
        "remote-a",
        "memory.note",
        json!({ "action": "add", "content": "x", "origins": ["assistant"], "quote": null })
    );
    op!(
        "a note with a null base revision",
        chat,
        "remote-a",
        "memory.note",
        json!({ "action": "replace", "id": note_id, "content": "x", "baseRevision": null,
            "origins": ["assistant"] })
    );
    op!(
        "a note from the other chat",
        chat,
        "remote-b",
        "memory.note",
        json!({ "action": "add", "content": "Drafted in the other chat", "origins": ["assistant"] })
    );
    seen!("notes changed", live);

    // ---- USER proposals ----
    let proposed = op!(
        "propose a USER entry",
        chat,
        "remote-a",
        "memory.proposeUser",
        json!({ "action": "add", "content": "Prefers short answers.", "quote": "keep it short",
            "entryIds": ["e2"] })
    );
    let first = proposed["body"]["result"]["proposalId"]
        .as_str()
        .unwrap()
        .to_owned();
    seen!("a proposal: an interaction is created", live);
    op!(
        "the same proposal again",
        chat,
        "remote-a",
        "memory.proposeUser",
        json!({ "action": "add", "content": "prefers  short answers.", "quote": "keep it short",
            "entryIds": ["e2"] })
    );
    op!(
        "a proposal without the user's words",
        chat,
        "remote-a",
        "memory.proposeUser",
        json!({ "action": "add", "content": "Likes tea.", "quote": "  ", "entryIds": ["e3"] })
    );
    op!(
        "a proposal without entries",
        chat,
        "remote-a",
        "memory.proposeUser",
        json!({ "action": "add", "content": "Likes tea.", "quote": "tea", "entryIds": [] })
    );
    op!(
        "a proposal of an unknown entry",
        chat,
        "remote-a",
        "memory.proposeUser",
        json!({ "action": "remove", "id": "u00000000", "quote": "tea", "entryIds": ["e3"] })
    );
    let second = op!(
        "another proposal",
        chat,
        "remote-a",
        "memory.proposeUser",
        json!({ "action": "add", "content": "Lives in Taipei.", "quote": "I live in Taipei",
            "entryIds": ["e4"] })
    )["body"]["result"]["proposalId"]
        .as_str()
        .unwrap()
        .to_owned();
    op!(
        "a proposal too large for the budget",
        chat,
        "remote-a",
        "memory.proposeUser",
        json!({ "action": "add", "content": "w".repeat(81), "quote": "w", "entryIds": ["e5"] })
    );
    seen!("proposals changed", live);
    call!(
        // The two earlier capability patches advance the shared binding generation to 3.
        "the chat's snapshot shows the proposals",
        "GET",
        format!("/api/sessions/{a}/snapshot"),
        None
    );
    call!(
        "the other chat's snapshot",
        "GET",
        format!("/api/sessions/{b}/snapshot"),
        None
    );

    // Answering needs the control lease.
    let answer_path = |proposal: &str, revision: u32| {
        format!("/api/sessions/{a}/interactions/memory:{proposal}:{revision}/answer")
    };
    call!(
        "answer without the lease",
        "POST",
        answer_path(&first, 0),
        Some(json!({ "clientId": "browser", "generation": 1, "answer": { "confirmed": true } }))
    );
    call!(
        "acquire control",
        "POST",
        format!("/api/sessions/{a}/control/acquire"),
        Some(json!({ "clientId": "browser" }))
    );
    call!(
        "answer that is not a decision",
        "POST",
        answer_path(&first, 0),
        Some(json!({ "clientId": "browser", "generation": 1, "answer": { "confirmed": "yes" } }))
    );
    call!(
        "a card of another revision",
        "POST",
        answer_path(&first, 3),
        Some(json!({ "clientId": "browser", "generation": 1, "answer": { "confirmed": true } }))
    );
    call!(
        "approve in the chat",
        "POST",
        answer_path(&first, 0),
        Some(json!({ "clientId": "browser", "generation": 1, "answer": { "confirmed": true } }))
    );
    seen!("approved: the interaction is answered", live);
    call!(
        "approve again",
        "POST",
        answer_path(&first, 0),
        Some(json!({ "clientId": "browser", "generation": 1, "answer": { "confirmed": true } }))
    );
    op!(
        "propose what USER already says",
        chat,
        "remote-a",
        "memory.proposeUser",
        json!({ "action": "add", "content": "PREFERS SHORT ANSWERS.", "quote": "short",
            "entryIds": ["e6"] })
    );

    // ---- the memory page ----
    call!("the memory page", "GET", "/api/memory", None);
    let mut view = call!(
        "reject in Settings",
        "POST",
        format!("/api/memory/proposals/{second}/reject"),
        None
    );
    seen!("rejected in Settings", live);
    call!(
        "reject it again",
        "POST",
        format!("/api/memory/proposals/{second}/reject"),
        None
    );
    op!(
        "propose what was rejected",
        chat,
        "remote-a",
        "memory.proposeUser",
        json!({ "action": "add", "content": "Lives in Taipei.", "quote": "I live in Taipei",
            "entryIds": ["e4"] })
    );
    let user_entry = view.body["user"][0]["id"].as_str().unwrap().to_owned();
    let third = op!(
        "propose a replacement",
        chat,
        "remote-a",
        "memory.proposeUser",
        json!({ "action": "replace", "id": user_entry, "content": "Prefers very short answers.",
            "baseRevision": 1, "quote": "even shorter", "entryIds": ["e7"] })
    )["body"]["result"]["proposalId"]
        .as_str()
        .unwrap()
        .to_owned();
    op!(
        "propose the same text for the entry",
        chat,
        "remote-a",
        "memory.proposeUser",
        json!({ "action": "replace", "id": user_entry, "content": "prefers short answers.",
            "baseRevision": 1, "quote": "short", "entryIds": ["e7"] })
    );
    seen!("a replacement proposed", live);
    call!(
        "approve at another revision",
        "POST",
        format!("/api/memory/proposals/{third}/approve"),
        Some(json!({ "targetRevision": 5 }))
    );
    call!(
        "approve with another field",
        "POST",
        format!("/api/memory/proposals/{third}/approve"),
        Some(json!({ "targetRevision": 1, "extra": true }))
    );
    call!(
        "approve with a revision that is not positive",
        "POST",
        format!("/api/memory/proposals/{third}/approve"),
        Some(json!({ "targetRevision": 0 }))
    );
    call!(
        "approve in Settings",
        "POST",
        format!("/api/memory/proposals/{third}/approve"),
        Some(json!({ "targetRevision": 1 }))
    );
    seen!("approved in Settings", live);
    call!(
        "history of the USER entry",
        "GET",
        format!("/api/memory/entries/{user_entry}/history"),
        None
    );
    call!(
        "history of the removed note",
        "GET",
        format!("/api/memory/entries/{note_id}/history"),
        None
    );
    call!(
        "restore the removed note",
        "POST",
        format!("/api/memory/entries/{note_id}/restore"),
        None
    );
    call!(
        "restore its first version",
        "POST",
        format!("/api/memory/entries/{note_id}/restore"),
        Some(json!({ "revision": 1 }))
    );
    call!(
        "restore a version that has no text",
        "POST",
        format!("/api/memory/entries/{note_id}/restore"),
        Some(json!({ "revision": 3 }))
    );
    call!(
        "restore with a body that is not an object",
        "POST",
        format!("/api/memory/entries/{note_id}/restore"),
        Some(json!([1]))
    );
    view = call!(
        "forget the USER entry",
        "POST",
        format!("/api/memory/entries/{user_entry}/forget"),
        None
    );
    assert!(view.body["user"].as_array().unwrap().is_empty());
    call!(
        "forget it again",
        "POST",
        format!("/api/memory/entries/{user_entry}/forget"),
        None
    );
    call!(
        "restore a forgotten entry",
        "POST",
        format!("/api/memory/entries/{user_entry}/restore"),
        None
    );
    call!(
        "its history after forgetting",
        "GET",
        format!("/api/memory/entries/{user_entry}/history"),
        None
    );
    op!(
        "propose forgotten text",
        chat,
        "remote-a",
        "memory.proposeUser",
        json!({ "action": "add", "content": "Prefers very  short answers.", "quote": "short",
            "entryIds": ["e8"] })
    );
    seen!("forgotten", live);
    call!(
        "history of an unknown entry",
        "GET",
        "/api/memory/entries/n00000000/history",
        None
    );
    call!(
        "an id that is too long",
        "GET",
        format!("/api/memory/entries/{}/history", "x".repeat(41)),
        None
    );
    call!(
        "an id beyond the router's limit",
        "POST",
        format!("/api/memory/proposals/{}/reject", "x".repeat(101)),
        None
    );
    call!(
        "approve an unknown proposal",
        "POST",
        "/api/memory/proposals/p00000000/approve",
        None
    );
    op!(
        "the assistant's context now",
        chat,
        "remote-a",
        "assistant.context",
        json!({})
    );
    op!(
        "the other chat's context",
        chat,
        "remote-b",
        "assistant.context",
        json!({})
    );
    op!(
        "an unknown session",
        chat,
        "remote-z",
        "memory.note",
        json!({ "action": "add", "content": "x", "origins": ["assistant"] })
    );

    // A USER entry, which coding sessions read too.
    let proposed = op!(
        "a USER entry for every session",
        chat,
        "remote-a",
        "memory.proposeUser",
        json!({ "action": "add", "content": "Answers in English.", "quote": "answer in English",
            "entryIds": ["e9"] })
    );
    let english = proposed["body"]["result"]["proposalId"]
        .as_str()
        .unwrap()
        .to_owned();
    call!(
        "approve it",
        "POST",
        format!("/api/memory/proposals/{english}/approve"),
        None
    );
    seen!("approved: memory changed", live);

    // ---- workspace memory: search and recall ----
    let dev_register = json!({
        "type": "register", "role": "node", "protocol": pirc_protocol::NODE_PROTOCOL_VERSION, "modes": ["directory"],
        "workspaces": [{ "id": "repo", "displayName": "Repo", "mode": "directory",
            "repo": "github.com/me/repo" }],
    });
    let (dev_node, registered) =
        FakeNode::connect(&api, DEV_ID, DEV_TOKEN, dev_register.clone(), dev_answer()).await;
    t.note("a directory node registers", registered);
    dev = Some(dev_node);
    let dev_session = call!(
        "a session in the repository",
        "POST",
        "/api/sessions",
        Some(json!({ "workspaceId": "dev:repo" }))
    );
    {
        op!(
            "a directory session reads USER only",
            dev.as_mut().unwrap(),
            "dev-1",
            "assistant.context",
            json!({})
        );
        op!(
            "nor memory",
            dev.as_mut().unwrap(),
            "dev-1",
            "memory.note",
            json!({ "action": "add", "content": "x", "origins": ["assistant"] })
        );
        op!(
            "nor search",
            dev.as_mut().unwrap(),
            "dev-1",
            "memory.search",
            json!({ "query": "x" })
        );
        op!(
            "another node's session",
            dev.as_mut().unwrap(),
            "remote-a",
            "assistant.context",
            json!({})
        );
    }
    op!(
        "the assistant sees the workspace's repository",
        chat,
        "remote-a",
        "assistant.context",
        json!({})
    );
    let staged = item(
        STAGED,
        "Deploys go through staging first",
        Some("remote-a"),
        "2026-09-27 10:00",
    );
    let unreadable = item(
        UNREADABLE,
        "The staging database is small",
        Some("remote-a"),
        "2026-09-26 08:00",
    );
    let ack = chat
        .mirror(
            json!({ "ledgerKey": CHAT_LEDGER, "offset": 0, "end": 120, "lines": [
            { "type": "recorded", "items": [
                staged, unreadable,
                item(NOBODY, "Staging notes nobody owns", Some("unknown"), "2026-09-27 11:00"),
                item(NO_SESSION, "Staging without a session", None, "2026-09-27 11:00"),
                { "id": "not hex", "content": "staging" },
            ] },
            { "type": "bogus" },
        ] }),
        )
        .await;
    t.note("the chat node mirrors its ledger", ack);
    let ack = chat
        .mirror(json!({ "ledgerKey": CHAT_LEDGER, "offset": 60, "end": 200, "lines": [] }))
        .await;
    t.note("a chunk that does not continue it", ack);
    let ack = chat
        .mirror(
            json!({ "ledgerKey": CHAT_LEDGER, "offset": 10, "end": 20, "reset": true, "lines": [] }),
        )
        .await;
    t.note("a reset that does not start at 0", ack);
    let dev_note = item(
        DEV_NOTE,
        "Staging deploys need the VPN",
        Some("dev-1"),
        "2026-09-28 09:00",
    );
    let mut dev_with_git = dev_note.clone();
    dev_with_git["git"] = json!({ "head": "abcdef1234567890", "branch": "main", "dirty": true });
    let ack = dev
        .as_mut()
        .unwrap()
        .mirror(json!({ "ledgerKey": DEV_LEDGER, "offset": 0, "end": 80, "lines": [
            { "type": "recorded", "items": [dev_with_git,
                item(RETIRED, "A staging note that is retired", Some("dev-1"), "2026-09-28 10:00")] },
            { "type": "retired", "ids": [RETIRED], "reason": "superseded" },
        ] }))
        .await;
    t.note("the directory node mirrors its ledger", ack);
    op!(
        "search",
        chat,
        "remote-a",
        "memory.search",
        json!({ "query": "staging DEPLOYS" })
    );
    op!(
        "search one repository",
        chat,
        "remote-a",
        "memory.search",
        json!({ "query": "staging", "workspace": "repo" })
    );
    op!(
        "search with a limit",
        chat,
        "remote-a",
        "memory.search",
        json!({ "query": "staging", "limit": 1 })
    );
    op!(
        "search for nothing",
        chat,
        "remote-a",
        "memory.search",
        json!({ "query": "   " })
    );
    op!(
        "search an unknown workspace",
        chat,
        "remote-a",
        "memory.search",
        json!({ "query": "staging", "workspace": "nope" })
    );
    op!(
        "search with a limit too high",
        chat,
        "remote-a",
        "memory.search",
        json!({ "query": "staging", "limit": 21 })
    );
    op!(
        "recall: the node reads it",
        chat,
        "remote-a",
        "recall.remote",
        json!({ "id": STAGED })
    );
    op!(
        "recall: the node cannot read it",
        chat,
        "remote-a",
        "recall.remote",
        json!({ "id": UNREADABLE })
    );
    op!(
        "recall a note nobody owns",
        chat,
        "remote-a",
        "recall.remote",
        json!({ "id": NOBODY })
    );
    dev.take().unwrap().disconnect().await;
    offline(&api, DEV_ID).await;
    op!(
        "recall: the node is offline",
        chat,
        "remote-a",
        "recall.remote",
        json!({ "id": RETIRED })
    );

    // ---- deleting a chat ----
    let mut deleted = api
        .connect(&format!("/api/events?sessionId={b}"), &browser)
        .await
        .open();
    call!(
        "delete the other chat",
        "DELETE",
        format!("/api/sessions/{b}"),
        None
    );
    let frames = deleted
        .until(|frame| frame["type"] == "session_deleted")
        .await;
    t.note("its event stream", mask!(json!(frames)));
    seen!("deleting a chat changes memory", live);
    call!(
        "delete it again",
        "DELETE",
        format!("/api/sessions/{b}"),
        None
    );
    call!("what it noted is forgotten", "GET", "/api/memory", None);
    op!(
        "its agent is gone",
        chat,
        "remote-b",
        "memory.note",
        json!({ "action": "add", "content": "Drafted in the other chat", "origins": ["assistant"] })
    );
    op!(
        "and what it noted cannot be noted again",
        chat,
        "remote-a",
        "memory.note",
        json!({ "action": "add", "content": "drafted in the other chat", "origins": ["assistant"] })
    );
    call!(
        "a directory session is not deleted",
        "DELETE",
        format!(
            "/api/sessions/{}",
            dev_session.body["session"]["id"].as_str().unwrap()
        ),
        None
    );
    call!("an unknown chat", "DELETE", "/api/sessions/unknown", None);

    // ---- the assistant node ----
    call!(
        "release another node",
        "POST",
        "/api/assistant/node/release",
        Some(json!({ "nodeId": "other" }))
    );
    call!(
        "release without a node",
        "POST",
        "/api/assistant/node/release",
        Some(json!({}))
    );
    call!(
        "release the chat node",
        "POST",
        "/api/assistant/node/release",
        Some(json!({ "nodeId": NODE_ID }))
    );
    let closed = chat.next(|frame| frame["type"] == "closed").await;
    t.note("the chat node's link", closed);
    call!("no assistant node", "GET", "/api/assistant/node", None);
    let (chat_again, registered) =
        FakeNode::connect(&api, NODE_ID, NODE_TOKEN, chat_register, chat_answer()).await;
    t.note(
        "the chat node registers again: its mirrored ledger's watermark",
        registered,
    );
    chat = chat_again;
    call!(
        "the assistant node again",
        "GET",
        "/api/assistant/node",
        None
    );

    chat.disconnect().await;
    insta::assert_json_snapshot!("memory", t.into_value());
}
