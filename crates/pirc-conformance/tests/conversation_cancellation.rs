//! Real two-host recovery of an accepted deletion while its Node is offline.
use pirc_conformance::{
    CHATS_WORKSPACE_ID, Cluster, GatewayOptions, HOST, Response, browser_headers,
};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    fs,
    time::{Duration, Instant},
};
fn ok(r: Response, status: u16) -> Value {
    assert_eq!(r.status, status, "{}", r.body);
    r.body
}
fn files(path: &std::path::Path) -> Vec<std::path::PathBuf> {
    let mut paths = fs::read_dir(path)
        .unwrap()
        .map(|p| p.unwrap().path())
        .collect::<Vec<_>>();
    paths.sort();
    paths
}
async fn exercise(materialized: bool) {
    let Some(mut cluster) = Cluster::start_with(GatewayOptions {
        env: vec![("PIRC_FIRST_SEND", "1".into())],
        chat_node: true,
        agent_core_only: true,
        ..Default::default()
    })
    .await
    else {
        return;
    };
    let api = cluster.api();
    let paired = ok(
        api.send(
            "POST",
            "/api/devices",
            &browser_headers(),
            Some(json!({"name":"native-cancel"})),
        )
        .await,
        201,
    );
    let headers = vec![
        ("host", HOST.into()),
        ("x-pirc-first-send-contract", "2".into()),
        (
            "authorization",
            format!("Bearer {}", paired["token"].as_str().unwrap()),
        ),
    ];
    let bytes = b"retained until explicit deletion\n";
    let manifest = json!({"operationId":"native-cancel","submission":{"workspaceId":CHATS_WORKSPACE_ID,"message":"Accepted intent before a disconnect","attachments":[{"id":"file-1","name":"input.txt","mimeType":"text/plain","byteSize":bytes.len(),"sha256":format!("{:x}",Sha256::digest(bytes))}]}});
    let path = "/api/conversation-submissions/native-cancel";
    let prepared = ok(
        api.send(
            "POST",
            "/api/conversation-submissions/prepare",
            &headers,
            Some(manifest.clone()),
        )
        .await,
        200,
    );
    let session = prepared["preparation"]["sessionId"]
        .as_str()
        .unwrap()
        .to_owned();
    ok(
        api.send_bytes(
            "PUT",
            &format!("{path}/attachments/file-1"),
            &headers,
            Some("application/octet-stream"),
            bytes.to_vec(),
        )
        .await,
        200,
    );
    ok(
        api.send("POST", &format!("{path}/accept"), &headers, None)
            .await,
        202,
    );
    let uploads = cluster.dir.path().join("node-state/uploads");
    if materialized {
        let ready = ok(
            api.send("POST", &format!("{path}/materialize"), &headers, None)
                .await,
            200,
        );
        assert_eq!(ready["preparation"]["state"], "ready");
        assert_eq!(files(&uploads).len(), 1);
    }
    cluster.stop_node(true).await;
    let pending = ok(
        api.send(
            "DELETE",
            &format!("/api/sessions/{session}"),
            &headers,
            None,
        )
        .await,
        202,
    );
    assert_eq!(pending["deletion"]["cleanupPending"], true);
    cluster.restart_gateway(true).await;
    let still_pending = ok(api.send("GET", path, &headers, None).await, 200);
    assert_eq!(still_pending["preparation"]["state"], "cancelled");
    assert_eq!(still_pending["preparation"]["accepted"], true);
    assert_eq!(still_pending["preparation"]["cleanupPending"], true);
    assert!(still_pending["preparation"].get("submission").is_none());
    assert!(cluster.llm.requests().is_empty());
    cluster.resume_node().await;
    let until = Instant::now() + Duration::from_secs(15);
    loop {
        let current = ok(api.send("GET", path, &headers, None).await, 200);
        if current["preparation"]["cleanupPending"] == false {
            break;
        }
        assert!(
            Instant::now() < until,
            "cleanup remained pending: {current}"
        );
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert!(files(&uploads).is_empty());
    assert!(
        !cluster
            .dir
            .path()
            .join("gateway-state/submission-staging")
            .join(&session)
            .exists()
    );
    assert_eq!(
        fs::read_to_string(cluster.dir.path().join("workspace/README.md")).unwrap(),
        "conformance\n"
    );
    ok(
        api.send(
            "DELETE",
            &format!("/api/sessions/{session}"),
            &headers,
            None,
        )
        .await,
        204,
    );
    for endpoint in ["accept", "materialize", "dispatch"] {
        let body = if endpoint == "dispatch" {
            Some(json!({"clientId":"late-client","generation":1}))
        } else {
            None
        };
        let late = ok(
            api.send("POST", &format!("{path}/{endpoint}"), &headers, body)
                .await,
            if endpoint == "accept" { 202 } else { 200 },
        );
        assert_eq!(late["preparation"]["state"], "cancelled");
    }
    let duplicate = ok(
        api.send(
            "POST",
            "/api/conversation-submissions/prepare",
            &headers,
            Some(manifest),
        )
        .await,
        200,
    );
    assert_eq!(duplicate["preparation"]["state"], "cancelled");
    assert!(
        ok(api.send("GET", "/api/sessions", &headers, None).await, 200)["sessions"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    assert!(cluster.llm.requests().is_empty());
}
#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn deletion_without_a_known_node_session_survives_offline_and_gateway_restart() {
    exercise(false).await;
}
#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn materialized_files_are_cleaned_after_the_same_node_reconnects() {
    exercise(true).await;
}
