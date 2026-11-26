//! The gateway's side of the node link (`/node/connect`), with the test
//! acting as a node: registration, heartbeats, relaying a browser request
//! and publishing a node event (`apps/gateway/src/daemon/nodes.ts`).

use pirc_conformance::{
    Cluster, FirstSend, GatewayOptions, NODE_ID, NODE_TOKEN, Transcript, WebSocket,
    assert_gateway_frame, assert_node_frame, browser_headers,
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

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
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
    let (started, ()) = tokio::join!(
        FirstSend::new(&api, &browser)
            .workspace("test:ws")
            .start_idle(),
        pirc_conformance::serve_first_send_idle(&mut node, "remote-1"),
    );
    let session = started.id;

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
    let reached = events
        .until(|frame| frame["type"] == "pi_event")
        .await
        .pop()
        .expect("event");
    t.note("a node event reaches the browser", reached);
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
