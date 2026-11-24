//! Terminal and browser streams the gateway relays between a browser
//! WebSocket and the node (`apps/gateway/src/daemon/socket-relay.ts`,
//! `nodes.ts`), with the test acting as the node.

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

#[ignore = "pirc 2: needs a session created through first-send instead of the removed POST /api/sessions; rewritten after M4 (plans/roadmap.md M2.9)"]
#[tokio::test(flavor = "multi_thread")]
async fn relayed_streams() {
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

    let mut node = api.connect("/node/connect", &node_headers()).await.open();
    send(
        &mut node,
        json!({ "type": "register", "role": "node", "protocol": pirc_protocol::NODE_PROTOCOL_VERSION, "modes": ["directory"],
            "workspaces": [{ "id": "ws", "displayName": "W", "mode": "directory" }] }),
    )
    .await;
    assert_eq!(
        node.next_json().await.expect("registered")["type"],
        "registered"
    );
    assert_eq!(node.next_json().await.expect("modes")["type"], "modes");
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
        json!({ "type": "response", "requestId": request["requestId"],
            "data": { "status": 201, "body": { "session": { "id": "remote-1" } } } }),
    )
    .await;
    let session = create.await.unwrap().body["session"]["id"]
        .as_str()
        .unwrap()
        .to_owned();

    // A terminal: opened, frames both ways, closed by the node.
    let mut terminal = api
        .connect(
            &format!("/api/sessions/{session}/terminals/term-1/stream"),
            &browser,
        )
        .await
        .open();
    let open = node.next_json().await.expect("terminal_open");
    t.note("the node is asked to open the terminal", open.clone());
    let stream = open["streamId"].clone();
    send(
        &mut node,
        json!({ "type": "terminal_frame", "streamId": stream, "frame": { "type": "output", "data": "$ " } }),
    )
    .await;
    t.note(
        "a node frame reaches the browser",
        terminal.next_json().await.expect("frame"),
    );
    terminal
        .send_json(&json!({ "type": "input", "data": "ls\n" }))
        .await;
    t.note(
        "browser input reaches the node",
        node.next_json().await.expect("terminal_input"),
    );
    send(
        &mut node,
        json!({ "type": "terminal_closed", "streamId": stream, "code": 4000, "reason": "shell exited" }),
    )
    .await;
    let (code, reason) = terminal.closed().await;
    t.note(
        "the node closes the terminal",
        json!({ "closed": code, "reason": reason }),
    );

    // The browser view: the browser leaves, the node is told to detach.
    let view = api
        .connect(&format!("/api/sessions/{session}/browser/stream"), &browser)
        .await
        .open();
    t.note(
        "the node is asked to open the browser view",
        node.next_json().await.expect("terminal_open"),
    );
    view.close().await;
    t.note(
        "the browser leaves",
        node.next_json().await.expect("terminal_close"),
    );

    // Refused streams.
    for (step, path, headers) in [
        (
            "unknown session",
            "/api/sessions/session_missing/terminals/t/stream".to_owned(),
            browser.clone(),
        ),
        (
            "no Origin",
            format!("/api/sessions/{session}/terminals/t/stream"),
            browser
                .iter()
                .filter(|(name, _)| *name != "origin")
                .cloned()
                .collect(),
        ),
        (
            "a terminal id over 100 characters",
            format!(
                "/api/sessions/{session}/terminals/{}/stream",
                "t".repeat(101)
            ),
            browser.clone(),
        ),
        (
            "a terminal id over 100 characters, no identity",
            format!(
                "/api/sessions/{session}/terminals/{}/stream",
                "t".repeat(101)
            ),
            browser
                .iter()
                .filter(|(name, _)| *name != "x-pirc-user")
                .cloned()
                .collect(),
        ),
    ] {
        match api.connect(&path, &headers).await {
            pirc_conformance::Connection::Open(mut socket) => {
                let (code, reason) = socket.closed().await;
                t.note(step, json!({ "closed": code, "reason": reason }));
            }
            pirc_conformance::Connection::Refused(response) => {
                t.response(step, "GET (upgrade)", &response);
            }
        }
    }
    let long = api
        .send(
            "GET",
            &format!("/api/sessions/{}/snapshot", "s".repeat(101)),
            &browser,
            None,
        )
        .await;
    t.response(
        "a session id over 100 characters",
        "GET /api/sessions/<long>/snapshot",
        &long,
    );

    // A terminal whose node goes away.
    let mut orphan = api
        .connect(
            &format!("/api/sessions/{session}/terminals/term-2/stream"),
            &browser,
        )
        .await
        .open();
    node.next_json().await.expect("terminal_open");
    node.close().await;
    let (code, reason) = orphan.closed().await;
    t.note(
        "the node disconnects",
        json!({ "closed": code, "reason": reason }),
    );

    insta::assert_json_snapshot!("relayed_streams", t.into_value());
}
