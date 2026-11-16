//! Device tokens for the native client: pairing, what a token may reach,
//! and revocation closing the device's open sockets
//! (`apps/gateway/src/daemon/devices.ts`).

use pirc_conformance::{Cluster, HOST, Transcript, WORKSPACE_ID, browser_headers};
use serde_json::json;

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn device_token_lifecycle() {
    let Some(cluster) = Cluster::start().await else {
        return;
    };
    let api = cluster.api();
    let browser = browser_headers();
    let mut t = Transcript::new(cluster.volatile());

    let created = api
        .send(
            "POST",
            "/api/sessions",
            &browser,
            Some(json!({ "workspaceId": WORKSPACE_ID })),
        )
        .await;
    let session = created.body["session"]["id"].as_str().unwrap().to_owned();

    let paired = api
        .send(
            "POST",
            "/api/devices",
            &browser,
            Some(json!({ "name": "Phone" })),
        )
        .await;
    t.response("pair a device", "POST /api/devices", &paired);
    // Timestamps are placeholders in the transcript; the lifetime is not.
    let device = &paired.body["device"];
    t.note(
        "expiresAt - createdAt (ms): 7 days without use",
        json!(device["expiresAt"].as_u64().unwrap() - device["createdAt"].as_u64().unwrap()),
    );
    let token = paired.body["token"].as_str().unwrap().to_owned();
    let device_id = paired.body["device"]["id"].as_str().unwrap().to_owned();

    let invalid = api
        .send(
            "POST",
            "/api/devices",
            &browser,
            Some(json!({ "name": "Phone", "extra": true })),
        )
        .await;
    t.response("pair with an unknown field", "POST /api/devices", &invalid);

    let listed = api.send("GET", "/api/devices", &browser, None).await;
    t.response("list devices", "GET /api/devices", &listed);

    // No Origin: a bearer token is never sent ambiently.
    let device = vec![
        ("host", HOST.to_owned()),
        ("authorization", format!("Bearer {token}")),
    ];
    for (method, path) in [
        ("GET", "/api/sessions"),
        ("GET", "/api/devices"),
        ("GET", "/api/providers"),
        ("GET", "/api/provider-auth/sessions"),
    ] {
        let response = api.send(method, path, &device, None).await;
        t.response(
            &format!("device token: {method} {path}"),
            &format!("{method} {path}"),
            &response,
        );
    }
    let response = api
        .send(
            "DELETE",
            &format!("/api/devices/{device_id}"),
            &device,
            None,
        )
        .await;
    t.response(
        "device token revoking itself",
        "DELETE /api/devices/<device>",
        &response,
    );

    let mut socket = api
        .connect(&format!("/api/events?sessionId={session}"), &device)
        .await
        .open();
    // The upgrade completes before event-socket authentication and tracking.
    // A pong proves the receive loop has started before we revoke the token.
    socket.ping().await;
    let revoked = api
        .send(
            "DELETE",
            &format!("/api/devices/{device_id}"),
            &browser,
            None,
        )
        .await;
    t.response(
        "revoke the device",
        &format!("DELETE /api/devices/{device_id}"),
        &revoked,
    );
    let (code, reason) = socket.closed().await;
    t.note(
        "the device's event socket closes",
        json!({ "closed": code, "reason": reason }),
    );

    let after = api.send("GET", "/api/sessions", &device, None).await;
    t.response("revoked token", "GET /api/sessions", &after);
    let listed = api.send("GET", "/api/devices", &browser, None).await;
    t.response("list devices after revoking", "GET /api/devices", &listed);
    let again = api
        .send(
            "DELETE",
            &format!("/api/devices/{device_id}"),
            &browser,
            None,
        )
        .await;
    t.response(
        "revoke again",
        &format!("DELETE /api/devices/{device_id}"),
        &again,
    );

    insta::assert_json_snapshot!("device_token_lifecycle", t.into_value());
}
