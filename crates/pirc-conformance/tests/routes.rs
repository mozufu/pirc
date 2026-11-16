//! The gateway's session and workspace routes with the test acting as the
//! node (`apps/gateway/src/daemon/app.ts`, "browser API"): what each route
//! checks itself, what it relays to the node (and how), and how it passes
//! the node's answers on.

use std::sync::{Arc, Mutex};

use pirc_conformance::{
    Api, Cluster, GatewayOptions, NODE_ID, NODE_TOKEN, Transcript, WebSocket, assert_node_frame,
    browser_headers,
};
use serde_json::{Value, json};

fn node_headers() -> Vec<(&'static str, String)> {
    vec![
        ("x-pirc-node-id", NODE_ID.to_owned()),
        ("authorization", format!("Bearer {NODE_TOKEN}")),
    ]
}

/// The node's answer to a relayed request.
fn answer(request: &Value) -> Value {
    let method = request["method"].as_str().unwrap_or_default();
    let url = request["url"].as_str().unwrap_or_default();
    let ok = |body: Value| json!({ "status": 200, "body": body });
    match (method, url) {
        ("POST", "/api/workspaces") => json!({ "status": 201, "body": { "workspace": {
            "id": "added", "displayName": request["payload"]["displayName"], "mode": "directory", "kind": "directory" } } }),
        ("POST", "/api/sessions") => {
            json!({ "status": 201, "body": { "session": { "id": "remote-1" } } })
        }
        ("GET", url) if url.ends_with("/snapshot") => ok(json!({
            "session": { "id": "remote-1", "runnerState": "ready", "name": "node's own" },
            "history": [], "interactions": [{ "id": "node-interaction" }],
            "watermark": { "epoch": 7, "sequence": 7 },
        })),
        ("POST", url)
            if url.ends_with("/control/acquire") || url.ends_with("/control/heartbeat") =>
        {
            ok(
                json!({ "lease": { "clientId": request["payload"]["clientId"],
                "generation": request["payload"]["generation"].as_u64().unwrap_or(0) + 1,
                "expiresAt": 4_000_000_000_000u64 } }),
            )
        }
        ("POST", url) if url.ends_with("/control/release") => json!({ "status": 204 }),
        ("POST", url) if url.ends_with("/commands") => {
            match request["payload"]["payload"]["type"].as_str() {
                Some("reject") => json!({ "status": 409, "body": { "error": {
                    "code": "conflict", "message": "Rejected by the node" } } }),
                Some("rejected_with_command") => json!({ "status": 409, "body": { "command": {
                    "status": "rejected", "error": "Busy" } } }),
                _ => json!({ "status": 202, "body": { "command": {
                    "status": "accepted", "result": { "ok": true } } } }),
            }
        }
        ("PATCH", _) => ok(json!({ "session": { "id": "remote-1" } })),
        ("POST", url) if url.contains("/interactions/") => ok(json!({ "answered": true })),
        ("POST", url) if url.contains("/uploads") => json!({ "status": 201, "body": {
            "upload": { "id": "upload-1" }, "echo": {
                "contentType": request["contentType"], "bodyBase64": request["bodyBase64"] } } }),
        ("GET", url) if url.contains("/files") => json!({ "status": 200, "body": "plain text" }),
        ("GET", url) if url.contains("/git/status") => {
            json!({ "status": 500, "body": { "error": { "code": "node_error", "message": "git failed" } } })
        }
        ("POST", url) if url.contains("/terminals") => json!({ "status": 204 }),
        _ => ok(json!({ "relayed": true })),
    }
}

/// Register as the node and answer every relayed request with [`answer`];
/// the relayed requests are collected.
async fn serve_node(api: &Api) -> (Arc<Mutex<Vec<Value>>>, tokio::task::JoinHandle<()>) {
    let mut node: WebSocket = api.connect("/node/connect", &node_headers()).await.open();
    let register = json!({
        "type": "register", "role": "node", "protocol": pirc_protocol::NODE_PROTOCOL_VERSION, "modes": ["directory"],
        "workspaces": [{ "id": "ws", "displayName": "Fake workspace", "mode": "directory" }],
    });
    assert_node_frame(&register);
    node.send_json(&register).await;
    assert_eq!(node.next_json().await.unwrap()["type"], "registered");
    let seen = Arc::new(Mutex::new(Vec::new()));
    let log = seen.clone();
    let task = tokio::spawn(async move {
        while let Ok(frame) = node.next_json().await {
            if frame["type"] != "request" {
                continue;
            }
            log.lock().unwrap().push(frame["data"].clone());
            let reply = json!({ "type": "response", "requestId": frame["requestId"],
                "data": answer(&frame["data"]) });
            node.send_json(&reply).await;
        }
    });
    (seen, task)
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn session_routes() {
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
    let (relayed, node) = serve_node(&api).await;

    macro_rules! call {
        ($step:expr, $method:expr, $path:expr, $body:expr) => {{
            let target = String::from($path);
            let response = api.send($method, &target, &browser, $body).await;
            t.response($step, &format!("{} {}", $method, target), &response);
            let requests: Vec<Value> = std::mem::take(&mut *relayed.lock().unwrap());
            if !requests.is_empty() {
                t.note(&format!("{}: relayed", $step), json!(requests));
            }
            response
        }};
    }

    call!(
        "add a workspace",
        "POST",
        "/api/workspaces",
        Some(
            json!({ "nodeId": NODE_ID, "path": "  /srv/project  ", "displayName": " Project ", "extra": 1 })
        )
    );
    call!(
        "add a workspace on an unknown node",
        "POST",
        "/api/workspaces",
        Some(json!({ "nodeId": "other", "path": "/x", "displayName": "X" }))
    );
    call!(
        "add a workspace without a path",
        "POST",
        "/api/workspaces",
        Some(json!({ "nodeId": NODE_ID, "displayName": "X" }))
    );
    call!("workspaces", "GET", "/api/workspaces", None);
    call!(
        "capabilities of a directory workspace",
        "GET",
        "/api/workspaces/test:ws/capabilities",
        None
    );
    call!(
        "change them",
        "PATCH",
        "/api/workspaces/test:ws/capabilities",
        Some(json!({ "capabilities": { "web_search": false } }))
    );
    call!(
        "a directory workspace has no instructions",
        "GET",
        "/api/workspaces/test:ws/instructions",
        None
    );
    call!(
        "project config",
        "GET",
        "/api/workspaces/test:ws/project-config",
        None
    );
    call!(
        "trust with a bad hash",
        "POST",
        "/api/workspaces/test:ws/project-trust",
        Some(json!({ "trusted": true, "hash": "abc" }))
    );
    call!(
        "trust",
        "POST",
        "/api/workspaces/test:ws/project-trust",
        Some(json!({ "trusted": true, "hash": "a".repeat(64) }))
    );

    let created = call!(
        "create a session",
        "POST",
        "/api/sessions",
        Some(json!({ "workspaceId": "test:ws" }))
    );
    let session_id = created.body["session"]["id"].as_str().unwrap().to_owned();
    let path = format!("/api/sessions/{session_id}");

    call!(
        "rename, pin and settle",
        "PATCH",
        path.clone(),
        Some(json!({ "name": "  Mine  ", "pinned": true, "settled": true }))
    );
    call!("nothing to update", "PATCH", path.clone(), Some(json!({})));
    call!(
        "unpin only (not relayed)",
        "PATCH",
        path.clone(),
        Some(json!({ "pinned": false }))
    );
    call!("snapshot", "GET", format!("{path}/snapshot"), None);
    call!("no lease yet", "GET", format!("{path}/control"), None);
    let command = json!({ "commandId": "c1", "clientId": "browser", "generation": 1,
        "payload": { "type": "prompt", "message": "hi" }, "extra": true });
    call!(
        "a command without the lease",
        "POST",
        format!("{path}/commands"),
        Some(command.clone())
    );
    call!(
        "acquire control",
        "POST",
        format!("{path}/control/acquire"),
        Some(json!({ "clientId": "browser", "extra": 1 }))
    );
    call!("the lease", "GET", format!("{path}/control"), None);
    call!(
        "heartbeat with a stale generation",
        "POST",
        format!("{path}/control/heartbeat"),
        Some(json!({ "clientId": "browser", "generation": 5 }))
    );
    call!(
        "heartbeat",
        "POST",
        format!("{path}/control/heartbeat"),
        Some(json!({ "clientId": "browser", "generation": 1 }))
    );
    let command = json!({ "commandId": "c1", "clientId": "browser", "generation": 2,
        "payload": { "type": "prompt", "message": "hi" }, "extra": true });
    call!(
        "a command",
        "POST",
        format!("{path}/commands"),
        Some(command.clone())
    );
    call!(
        "the same command again",
        "POST",
        format!("{path}/commands"),
        Some(command)
    );
    call!(
        "the same id, another payload",
        "POST",
        format!("{path}/commands"),
        Some(
            json!({ "commandId": "c1", "clientId": "browser", "generation": 2,
            "payload": { "type": "stop" } })
        )
    );
    call!(
        "a command the node rejects",
        "POST",
        format!("{path}/commands"),
        Some(
            json!({ "commandId": "c2", "clientId": "browser", "generation": 2,
            "payload": { "type": "reject" } })
        )
    );
    call!(
        "a command the node rejects with a command",
        "POST",
        format!("{path}/commands"),
        Some(
            json!({ "commandId": "c3", "clientId": "browser", "generation": 2,
            "payload": { "type": "rejected_with_command" } })
        )
    );
    call!(
        "a command without a type",
        "POST",
        format!("{path}/commands"),
        Some(
            json!({ "commandId": "c4", "clientId": "browser", "generation": 2,
            "payload": {} })
        )
    );
    call!(
        "answer an interaction",
        "POST",
        format!("{path}/interactions/node-interaction/answer"),
        Some(json!({ "clientId": "browser", "generation": 2, "answer": { "ok": true } }))
    );
    let upload = api
        .send_bytes(
            "POST",
            &format!("{path}/uploads?filename=a%20b.png"),
            &browser,
            Some("image/png; charset=binary"),
            vec![1, 2, 3],
        )
        .await;
    t.response(
        "upload",
        &format!("POST {path}/uploads?filename=a%20b.png"),
        &upload,
    );
    t.note(
        "upload: relayed",
        json!(std::mem::take(&mut *relayed.lock().unwrap())),
    );
    call!(
        "an upload as JSON",
        "POST",
        format!("{path}/uploads"),
        Some(json!({ "data": "x" }))
    );
    call!(
        "files (a text answer)",
        "GET",
        format!("{path}/files?path=README.md"),
        None
    );
    call!(
        "git status (a node error)",
        "GET",
        format!("{path}/git/status"),
        None
    );
    call!(
        "a git commit",
        "GET",
        format!("{path}/git/commits/abcd1234"),
        None
    );
    call!(
        "a panel path that is not relayed",
        "GET",
        format!("{path}/git/secrets"),
        None
    );
    call!(
        "open a terminal",
        "POST",
        format!("{path}/terminals"),
        Some(json!({ "cols": 80 }))
    );
    call!(
        "stop a background task",
        "POST",
        format!("{path}/panel/background/task-1/stop"),
        None
    );
    call!(
        "release control",
        "POST",
        format!("{path}/control/release"),
        Some(json!({ "clientId": "browser", "generation": 2 }))
    );
    call!("only chats can be deleted", "DELETE", path.clone(), None);
    call!("models", "GET", "/api/models", None);
    call!(
        "models of a session",
        "GET",
        format!("/api/models?sessionId={session_id}"),
        None
    );
    call!(
        "models of an unknown session",
        "GET",
        "/api/models?sessionId=nope",
        None
    );
    call!("sessions", "GET", "/api/sessions", None);
    call!("nodes", "GET", "/api/nodes", None);
    call!("assistant node", "GET", "/api/assistant/node", None);

    node.abort();
    insta::assert_json_snapshot!("session_routes", t.into_value());
}
