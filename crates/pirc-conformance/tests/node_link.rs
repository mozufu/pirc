//! The gateway's side of the node link (`/node/connect`), with the test
//! acting as a node: registration, heartbeats, relaying a browser request
//! and publishing a node event (`apps/gateway/src/daemon/nodes.ts`).

use pirc_conformance::{
    Cluster, GatewayOptions, NODE_ID, NODE_TOKEN, Transcript, WebSocket, assert_gateway_frame,
    assert_node_frame, browser_headers,
};
use serde_json::{Value, json};

fn node_headers(token: &str) -> Vec<(&'static str, String)> {
    vec![
        ("x-pirc-node-id", NODE_ID.to_owned()),
        ("authorization", format!("Bearer {token}")),
    ]
}

/// Send a well-formed node frame, checking it against `pirc-protocol` too.
async fn send(socket: &mut WebSocket, frame: &Value) {
    assert_node_frame(frame);
    socket.send_json(frame).await;
}

/// The gateway's next frame, checked against `pirc-protocol`.
async fn receive(socket: &mut WebSocket, what: &str) -> Value {
    let frame = socket.next_json().await.expect(what);
    assert_gateway_frame(&frame);
    frame
}

fn register(protocol: Value) -> Value {
    json!({
        "type": "register",
        "role": "node",
        "protocol": protocol,
        "modes": ["directory"],
        "workspaces": [{ "id": "ws", "displayName": "Fake workspace", "mode": "directory" }],
    })
}

#[ignore = "pirc 2: needs a session created through first-send instead of the removed POST /api/sessions; rewritten after M4 (plans/roadmap.md M2.9)"]
#[tokio::test(flavor = "multi_thread")]
async fn node_link() {
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

    let mut socket = api
        .connect("/node/connect", &node_headers("wrong-token"))
        .await
        .open();
    let (code, reason) = socket.closed().await;
    t.note(
        "wrong node token",
        json!({ "closed": code, "reason": reason }),
    );
    // The gateway says so, naming the node id and not the token, once a
    // minute at most (`/node/connect` is outside the forward-auth).
    let refusals = |log: &str| {
        log.lines()
            .filter(|line| line.contains("refused a node connection"))
            .map(str::to_owned)
            .collect::<Vec<_>>()
    };
    let logged = refusals(&cluster.gateway_log());
    assert_eq!(logged.len(), 1, "{}", cluster.gateway_log());
    assert!(
        logged[0].contains(&format!("node id \\\"{NODE_ID}\\\"")),
        "{}",
        logged[0]
    );
    assert!(!logged[0].contains("wrong-token"), "{}", logged[0]);
    let mut again = api
        .connect("/node/connect", &node_headers("wrong-token-2"))
        .await
        .open();
    again.closed().await;
    assert_eq!(refusals(&cluster.gateway_log()).len(), 1);

    for (step, frame) in [
        ("older protocol", register(json!(9))),
        ("no protocol", {
            let mut frame = register(Value::Null);
            frame.as_object_mut().unwrap().remove("protocol");
            frame
        }),
        (
            "invalid registration",
            json!({ "type": "register", "role": "node", "protocol": pirc_protocol::NODE_PROTOCOL_VERSION }),
        ),
    ] {
        let mut socket = api
            .connect("/node/connect", &node_headers(NODE_TOKEN))
            .await
            .open();
        socket.send_json(&frame).await;
        let (code, reason) = socket.closed().await;
        if let Some(old_protocol) = match step {
            "older protocol" => Some(9),
            "no protocol" => Some(1),
            _ => None,
        } {
            assert_eq!(code, pirc_protocol::PROTOCOL_MISMATCH_CLOSE);
            assert_eq!(
                reason,
                format!(
                    "node protocol {old_protocol} != daemon {}",
                    pirc_protocol::NODE_PROTOCOL_VERSION
                ),
            );
        }
        t.note(step, json!({ "closed": code, "reason": reason }));
    }

    let mut node = api
        .connect("/node/connect", &node_headers(NODE_TOKEN))
        .await
        .open();
    send(
        &mut node,
        &register(json!(pirc_protocol::NODE_PROTOCOL_VERSION)),
    )
    .await;
    let registered = receive(&mut node, "registered").await;
    t.note("register", registered);
    assert_eq!(receive(&mut node, "modes").await["type"], "modes");

    send(&mut node, &json!({ "type": "heartbeat" })).await;
    t.note("heartbeat", receive(&mut node, "heartbeat_ack").await);

    let nodes = api.send("GET", "/api/nodes", &browser, None).await;
    t.response("list nodes", "GET /api/nodes", &nodes);
    let workspaces = api.send("GET", "/api/workspaces", &browser, None).await;
    t.response("list workspaces", "GET /api/workspaces", &workspaces);

    // A browser request the gateway relays to the node, answered by the test.
    let browser_api = api.clone();
    let browser_for_task = browser.clone();
    let create = tokio::spawn(async move {
        browser_api
            .send(
                "POST",
                "/api/sessions",
                &browser_for_task,
                Some(json!({ "workspaceId": "test:ws" })),
            )
            .await
    });
    let request = receive(&mut node, "relayed request").await;
    t.note("relayed request", request.clone());
    send(
        &mut node,
        &json!({
        "type": "response",
        "requestId": request["requestId"],
        "data": { "status": 201, "body": { "session": { "id": "remote-1" } } },
        }),
    )
    .await;
    let created = create.await.unwrap();
    t.response(
        "create a session on the node",
        "POST /api/sessions",
        &created,
    );
    let session = created.body["session"]["id"].as_str().unwrap().to_owned();

    let mut events = api
        .connect(&format!("/api/events?sessionId={session}"), &browser)
        .await
        .open();
    send(
        &mut node,
        &json!({
        "type": "event",
        "sessionId": "remote-1",
        "event": { "type": "pi_event", "data": { "type": "agent_start" } },
        }),
    )
    .await;
    t.note(
        "a node event reaches the browser",
        events.next_json().await.expect("event"),
    );
    events.close().await;

    let mut replacement = api
        .connect("/node/connect", &node_headers(NODE_TOKEN))
        .await
        .open();
    send(
        &mut replacement,
        &register(json!(pirc_protocol::NODE_PROTOCOL_VERSION)),
    )
    .await;
    let (code, reason) = node.closed().await;
    t.note(
        "a second connection replaces the first",
        json!({ "closed": code, "reason": reason }),
    );
    let registered = receive(&mut replacement, "registered").await;
    t.note("the replacement registers", registered);

    replacement
        .send_json(&json!({ "type": "something_else" }))
        .await;
    let (code, reason) = replacement.closed().await;
    t.note(
        "unsupported message",
        json!({ "closed": code, "reason": reason }),
    );

    insta::assert_json_snapshot!("node_link", t.into_value());
}
