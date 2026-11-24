//! Real Gateway + Node proof for durable acceptance/attachment materialization.
//! No model is called. Command admission/client adoption remain separate gates.
use pirc_conformance::{
    CHATS_WORKSPACE_ID, Cluster, GatewayOptions, HOST, Response, browser_headers,
};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    fs,
    time::{Duration, Instant},
};
fn ok(response: Response, status: u16) -> Value {
    assert_eq!(response.status, status, "{}", response.body);
    response.body
}
fn files(path: &std::path::Path) -> Vec<std::path::PathBuf> {
    fs::read_dir(path)
        .unwrap()
        .map(|f| f.unwrap().path())
        .collect()
}
#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn accepted_intent_and_attachment_survive_both_hosts_restarting_without_execution() {
    let Some(mut cluster) = Cluster::start_with(GatewayOptions {
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
            Some(json!({"name":"native-first-send"})),
        )
        .await,
        201,
    );
    let token = paired["token"].as_str().unwrap();
    // All further requests use only the paired bearer: no Origin or browser login.
    let headers = vec![
        ("host", HOST.into()),
        ("x-pirc-first-send-contract", "2".into()),
        ("authorization", format!("Bearer {token}")),
    ];
    let path = "/api/conversation-submissions/native-draft";
    let content = b"{\"native\":true}\n";
    let manifest = json!({"operationId":"native-draft","submission":{"workspaceId":CHATS_WORKSPACE_ID,"message":"Keep this accepted message","attachments":[{"id":"json-file","name":"native.json","mimeType":"application/json","byteSize":content.len(),"sha256":format!("{:x}",Sha256::digest(content))}]}});
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
    assert_eq!(
        ok(api.send("GET", "/api/sessions", &headers, None).await, 200)["sessions"]
            .as_array()
            .unwrap()
            .len(),
        0
    );
    ok(
        api.send_bytes(
            "PUT",
            &format!("{path}/attachments/json-file"),
            &headers,
            Some("application/octet-stream"),
            content.to_vec(),
        )
        .await,
        200,
    );
    let accepted = ok(
        api.send("POST", &format!("{path}/accept"), &headers, None)
            .await,
        202,
    );
    assert_eq!(accepted["preparation"]["state"], "accepted");
    assert_eq!(accepted["preparation"]["accepted"], true);
    assert_eq!(
        ok(api.send("GET", "/api/sessions", &headers, None).await, 200)["sessions"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    cluster.restart_gateway(true).await;
    let recovered = ok(api.send("GET", path, &headers, None).await, 200);
    assert_eq!(recovered, accepted);
    let ready = ok(
        api.send("POST", &format!("{path}/materialize"), &headers, None)
            .await,
        200,
    );
    assert_eq!(ready["preparation"]["state"], "ready", "{ready}");
    assert_eq!(ready["preparation"]["sessionId"], session);
    let uploads = cluster.dir.path().join("node-state/uploads");
    let saved = files(&uploads);
    assert_eq!(saved.len(), 1);
    assert_eq!(fs::read(&saved[0]).unwrap(), content);
    cluster.restart_node(true).await;
    cluster.restart_gateway(true).await;
    assert_eq!(
        ok(
            api.send("POST", &format!("{path}/accept"), &headers, None)
                .await,
            202
        ),
        ready
    );
    assert_eq!(
        ok(
            api.send("POST", &format!("{path}/materialize"), &headers, None)
                .await,
            200
        ),
        ready
    );
    assert_eq!(files(&uploads), saved);
    // Another normal prompt cannot overtake this still-pending first message.
    let lease = ok(
        api.send(
            "POST",
            &format!("/api/sessions/{session}/control/acquire"),
            &headers,
            Some(json!({"clientId":"native-client"})),
        )
        .await,
        200,
    );
    let rejected=api.send("POST",&format!("/api/sessions/{session}/commands"),&headers,Some(json!({"commandId":"must-not-overtake","clientId":"native-client","generation":lease["lease"]["generation"],"payload":{"type":"prompt","message":"must not race the first message"}}))).await;
    assert_eq!(rejected.status, 409);
    assert_eq!(rejected.body["error"]["code"], "first_message_pending");
    assert!(cluster.llm.requests().is_empty());
    // The normal Chat deletion path cleans both hosts and delayed retries cannot revive it.
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
    assert!(files(&uploads).is_empty());
    let deleted = ok(api.send("GET", path, &headers, None).await, 200);
    assert_eq!(deleted["preparation"]["state"], "cancelled");
    assert_eq!(deleted["preparation"]["accepted"], true);
    assert!(deleted["preparation"].get("submission").is_none());
    assert_eq!(
        ok(
            api.send("POST", &format!("{path}/accept"), &headers, None)
                .await,
            202
        )["preparation"]["state"],
        "cancelled"
    );
    assert_eq!(
        ok(
            api.send("POST", &format!("{path}/materialize"), &headers, None)
                .await,
            200
        )["preparation"]["state"],
        "cancelled"
    );
    let mut changed = manifest;
    changed["submission"]["message"] = json!("different input");
    assert_eq!(
        api.send(
            "POST",
            "/api/conversation-submissions/prepare",
            &headers,
            Some(changed)
        )
        .await
        .status,
        409
    );
    cluster.restart_gateway(true).await;
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let state = ok(api.send("GET", path, &headers, None).await, 200);
        if state["preparation"]["cleanupPending"] == false {
            break;
        }
        assert!(Instant::now() < deadline, "startup cleanup did not finish");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert!(
        !cluster
            .dir
            .path()
            .join("gateway-state/submission-staging")
            .join(&session)
            .exists()
    );
    assert!(cluster.llm.requests().is_empty());
}
