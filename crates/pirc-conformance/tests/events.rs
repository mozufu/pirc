//! A session's event stream as the gateway keeps it (`apps/gateway/src/events.ts`
//! and `/api/events` in `daemon/app.ts`): sequences, epochs, cursors,
//! resets and the hint frames a socket opts into, with the test acting as
//! the node so every frame is under its control.

use pirc_conformance::{
    Cluster, GatewayOptions, NODE_ID, NODE_TOKEN, Transcript, WebSocket, assert_node_frame,
    browser_headers,
};
use serde_json::{Value, json};

fn node_headers() -> Vec<(&'static str, String)> {
    vec![
        ("x-pirc-node-id", NODE_ID.to_owned()),
        ("authorization", format!("Bearer {NODE_TOKEN}")),
    ]
}

async fn send(socket: &mut WebSocket, frame: Value) {
    assert_node_frame(&frame);
    socket.send_json(&frame).await;
}

async fn register(cluster: &Cluster) -> WebSocket {
    let mut node = cluster
        .api()
        .connect("/node/connect", &node_headers())
        .await
        .open();
    send(
        &mut node,
        json!({
            "type": "register",
            "role": "node",
            "protocol": pirc_protocol::NODE_PROTOCOL_VERSION, "modes": ["directory"],
            "workspaces": [{ "id": "ws", "displayName": "Fake workspace", "mode": "directory" }],
        }),
    )
    .await;
    let registered = node.next_json().await.expect("registered");
    assert_eq!(registered["type"], "registered");
    assert_eq!(node.next_json().await.expect("modes")["type"], "modes");
    node
}

fn event(kind: &str, data: Value) -> Value {
    json!({ "type": "event", "sessionId": "remote-1", "event": { "type": kind, "data": data } })
}

/// Send `frames` from the node, then a marker event; return what `socket`
/// receives up to and including the marker.
async fn exchange(
    node: &mut WebSocket,
    socket: &mut WebSocket,
    marker: &str,
    frames: Vec<Value>,
) -> Value {
    for frame in frames {
        send(node, frame).await;
    }
    send(node, event("marker", json!(marker))).await;
    json!(
        socket
            .until(|frame| frame["type"] == "marker" && frame["data"] == marker)
            .await
    )
}

#[ignore = "pirc 2: needs a session created through first-send instead of the removed POST /api/sessions; rewritten after M4 (plans/roadmap.md M2.9)"]
#[tokio::test(flavor = "multi_thread")]
async fn event_stream() {
    let Some(cluster) = Cluster::start_with(GatewayOptions {
        without_node: true,
        ..Default::default()
    })
    .await
    else {
        return;
    };
    let api = cluster.api();
    let browser = browser_headers();
    let mut t = Transcript::new(cluster.volatile());
    let mut node = register(&cluster).await;

    let create = {
        let api = api.clone();
        let browser = browser.clone();
        tokio::spawn(async move {
            api.send(
                "POST",
                "/api/sessions",
                &browser,
                Some(json!({ "workspaceId": "test:ws" })),
            )
            .await
        })
    };
    let request = node.next_json().await.expect("relayed request");
    send(
        &mut node,
        json!({
            "type": "response",
            "requestId": request["requestId"],
            "data": { "status": 201, "body": { "session": { "id": "remote-1" } } },
        }),
    )
    .await;
    let session = create.await.unwrap().body["session"]["id"]
        .as_str()
        .unwrap()
        .to_owned();

    let hints =
        format!("/api/events?sessionId={session}&directory=1&sessions=1&memory=1&schedules=1");
    let mut live = api.connect(&hints, &browser).await.open();
    let mut plain = api
        .connect(&format!("/api/events?sessionId={session}"), &browser)
        .await
        .open();

    let seen = exchange(
        &mut node,
        &mut live,
        "events",
        vec![event("pi_event", json!({ "n": 1 }))],
    )
    .await;
    t.note("a node event", seen);
    let seen = exchange(
        &mut node,
        &mut live,
        "titles",
        vec![
            event(
                "session_renamed",
                json!({ "name": "  Generated  ", "source": "auto" }),
            ),
            event(
                "session_renamed",
                json!({ "name": "Generated", "source": "auto" }),
            ),
            event("session_renamed", json!({ "name": "", "source": "auto" })),
        ],
    )
    .await;
    t.note("automatic titles: new, the same again, empty", seen);
    let seen = exchange(
        &mut node,
        &mut live,
        "activity",
        vec![
            json!({ "type": "activity", "sessions": [{ "id": "remote-1", "run": "running" }] }),
            json!({ "type": "activity", "sessions": [{ "id": "remote-1", "run": "running" }] }),
            json!({ "type": "activity", "sessions": [
                { "id": "remote-1", "run": "running", "writeLease": true },
                { "id": "unknown", "run": "running" },
            ] }),
            json!({ "type": "activity", "sessions": [] }),
        ],
    )
    .await;
    t.note(
        "a run starts, is reported again, takes a write lease and ends",
        seen,
    );
    let sessions = api.send("GET", "/api/sessions", &browser, None).await;
    t.response(
        "the finished run left the session unread",
        "GET /api/sessions",
        &sessions,
    );
    let seen = exchange(
        &mut node,
        &mut live,
        "question",
        vec![json!({ "type": "activity", "sessions": [{ "id": "remote-1", "run": "waiting_input" }] })],
    )
    .await;
    t.note("the agent asks a question", seen);
    let listed = api.send("GET", "/api/sessions", &browser, None).await;
    t.response("a live run in the list", "GET /api/sessions", &listed);
    let read = api
        .send(
            "POST",
            &format!("/api/sessions/{session}/read"),
            &browser,
            None,
        )
        .await;
    t.response(
        "read the session",
        "POST /api/sessions/<session>/read",
        &read,
    );
    let seen = exchange(&mut node, &mut live, "read", vec![]).await;
    t.note("reading it is a sessions change", seen);

    let seen = json!(
        plain
            .until(|frame| frame["type"] == "marker" && frame["data"] == "read")
            .await
    );
    t.note("a socket without hints sees only the events", seen);

    let mut from_two = api
        .connect(
            &format!("/api/events?sessionId={session}&cursor=0:2"),
            &browser,
        )
        .await
        .open();
    let seen = exchange(&mut node, &mut from_two, "replayed", vec![]).await;
    t.note("a cursor replays what followed it, then goes on live", seen);

    // A second connection replaces the node's link: the session's runner
    // goes offline and comes back in a new epoch.
    let mut replacement = register(&cluster).await;
    let (code, reason) = node.closed().await;
    t.note("the old link", json!({ "closed": code, "reason": reason }));
    let seen = exchange(&mut replacement, &mut live, "replaced", vec![]).await;
    t.note("node replaced, as the hint socket sees it", seen);

    let mut stale = api
        .connect(
            &format!("/api/events?sessionId={session}&cursor=0:4"),
            &browser,
        )
        .await
        .open();
    t.note(
        "a cursor from the old epoch",
        stale.next_json().await.expect("reset"),
    );
    let mut current = api
        .connect(
            &format!("/api/events?sessionId={session}&cursor=1:2"),
            &browser,
        )
        .await
        .open();
    let seen = exchange(&mut replacement, &mut current, "current", vec![]).await;
    t.note("a current cursor goes on live", seen);

    for (step, query) in [
        (
            "a malformed cursor",
            format!("sessionId={session}&cursor=abc"),
        ),
        (
            "an unknown hint value",
            format!("sessionId={session}&directory=yes"),
        ),
        ("an empty session id", "sessionId=".to_owned()),
    ] {
        let mut socket = api
            .connect(&format!("/api/events?{query}"), &browser)
            .await
            .open();
        let (code, reason) = socket.closed().await;
        t.note(step, json!({ "closed": code, "reason": reason }));
    }

    // Browsers send nothing on this socket; what they send is ignored. (The
    // TS gateway meant to close at 4 KiB, but its limit never took effect
    // under Bun; the Rust gateway enforces it, so it is not recorded here.)
    let mut chatty = api
        .connect(&format!("/api/events?sessionId={session}"), &browser)
        .await
        .open();
    chatty.send_json(&json!({ "type": "hello" })).await;
    let seen = exchange(&mut replacement, &mut chatty, "ignored", vec![]).await;
    t.note("a browser message is ignored", seen);

    insta::assert_json_snapshot!("event_stream", t.into_value());
}
