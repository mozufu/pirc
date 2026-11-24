//! Paired clients Stop an unallocated first input through real Gateway/Node
//! processes. No live Web page/event connection or native management grant is present.
use pirc_conformance::{
    CHATS_WORKSPACE_ID, Cluster, GatewayOptions, HOST, Reply, Response, browser_headers,
};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::time::{Duration, Instant};
fn ok(r: Response, status: u16) -> Value {
    assert_eq!(r.status, status, "{}", r.body);
    r.body
}
async fn device(cluster: &Cluster, name: &str) -> (Vec<(&'static str, String)>, String) {
    let paired = ok(
        cluster
            .api()
            .send(
                "POST",
                "/api/devices",
                &browser_headers(),
                Some(json!({"name":name})),
            )
            .await,
        201,
    );
    (
        vec![
            ("host", HOST.into()),
            ("x-pirc-first-send-contract", "2".into()),
            (
                "authorization",
                format!("Bearer {}", paired["token"].as_str().unwrap()),
            ),
        ],
        paired["device"]["id"].as_str().unwrap().to_owned(),
    )
}
#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn unmapped_stop_survives_offline_takeover_restart_and_allows_only_explicit_new_work() {
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
    let (first, _) = device(&cluster, "phone-stop").await;
    let (second, second_id) = device(&cluster, "other-device-stop").await;
    let bytes = b"original first-input file stays available\n";
    let manifest = json!({"operationId":"pending-stop","submission":{"workspaceId":CHATS_WORKSPACE_ID,"message":"Never execute this old first input","attachments":[{"id":"original-file","name":"notes.txt","mimeType":"text/plain","byteSize":bytes.len(),"sha256":format!("{:x}",Sha256::digest(bytes))}]}});
    let path = "/api/conversation-submissions/pending-stop";
    let preparation = ok(
        api.send(
            "POST",
            "/api/conversation-submissions/prepare",
            &first,
            Some(manifest),
        )
        .await,
        200,
    );
    let session = preparation["preparation"]["sessionId"]
        .as_str()
        .unwrap()
        .to_owned();
    ok(
        api.send_bytes(
            "PUT",
            &format!("{path}/attachments/original-file"),
            &first,
            Some("application/octet-stream"),
            bytes.to_vec(),
        )
        .await,
        200,
    );
    ok(
        api.send("POST", &format!("{path}/accept"), &first, None)
            .await,
        202,
    );
    cluster.stop_node(true).await;
    let one = ok(
        api.send(
            "POST",
            &format!("{path}/stop-control/acquire"),
            &first,
            Some(json!({"clientId":"phone"})),
        )
        .await,
        200,
    );
    assert_eq!(one["scope"], "pending_first_send_stop");
    let old_generation = one["lease"]["generation"].clone();
    ok(
        api.send(
            "POST",
            &format!("{path}/stop-control/acquire"),
            &second,
            Some(json!({"clientId":"other"})),
        )
        .await,
        409,
    );
    let takeover = ok(
        api.send(
            "POST",
            &format!("{path}/stop-control/acquire"),
            &second,
            Some(json!({"clientId":"other","force":true})),
        )
        .await,
        200,
    );
    let generation = takeover["lease"]["generation"].clone();
    assert!(generation.as_i64().unwrap() > old_generation.as_i64().unwrap());
    ok(
        api.send(
            "POST",
            &format!("{path}/stop"),
            &first,
            Some(json!({"clientId":"phone","generation":old_generation})),
        )
        .await,
        409,
    );
    let queued = ok(
        api.send(
            "POST",
            &format!("{path}/stop"),
            &second,
            Some(json!({"clientId":"other","generation":generation})),
        )
        .await,
        202,
    );
    assert_eq!(queued["preparation"]["state"], "stopping");
    assert_eq!(queued["preparation"]["nodeMapped"], false);
    assert_eq!(
        queued["preparation"]["messageAdmission"]["stopConfirmed"],
        false
    );
    // Revocation prevents fresh requests, but does not undo the already
    // authorized narrow Stop job. Recovery uses another live paired client.
    ok(
        api.send(
            "DELETE",
            &format!("/api/devices/{second_id}"),
            &browser_headers(),
            None,
        )
        .await,
        204,
    );
    ok(
        api.send(
            "POST",
            &format!("{path}/stop"),
            &second,
            Some(json!({"clientId":"other","generation":generation})),
        )
        .await,
        401,
    );
    cluster.restart_gateway(true).await;
    let pending = ok(
        api.send("GET", &format!("{path}/receipt"), &first, None)
            .await,
        200,
    );
    assert_eq!(pending["preparation"]["state"], "stopping");
    assert!(cluster.llm.requests().is_empty());
    cluster.resume_node().await;
    let until = Instant::now() + Duration::from_secs(15);
    loop {
        let receipt = ok(
            api.send("GET", &format!("{path}/receipt"), &first, None)
                .await,
            200,
        );
        if receipt["preparation"]["state"] == "stopped" {
            assert_eq!(receipt["preparation"]["nodeMapped"], false);
            assert_eq!(
                receipt["preparation"]["messageAdmission"]["stopConfirmed"],
                true
            );
            break;
        }
        assert!(Instant::now() < until, "Stop stayed unconfirmed: {receipt}");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert!(cluster.llm.requests().is_empty());
    // Stop itself did not allocate storage. Explicit continuation prepares that
    // same blank conversation without promoting the old first-input files.
    let ready = ok(
        api.send("POST", &format!("{path}/materialize"), &first, None)
            .await,
        200,
    );
    assert_eq!(ready["preparation"]["state"], "stopped");
    assert_eq!(ready["preparation"]["nodeMapped"], true);
    assert_eq!(ready["preparation"]["sessionId"], session);
    let uploads = cluster.dir.path().join("node-state/uploads");
    assert!(std::fs::read_dir(uploads).unwrap().next().is_none());
    let retained = ok(api.send("GET", path, &first, None).await, 200);
    assert_eq!(
        retained["preparation"]["submission"]["message"],
        "Never execute this old first input"
    );
    assert_eq!(
        retained["preparation"]["submission"]["attachments"][0]["id"],
        "original-file"
    );
    assert_eq!(
        std::fs::read(
            cluster
                .dir
                .path()
                .join("gateway-state/submission-staging")
                .join(&session)
                .join("original-file.bin")
        )
        .unwrap(),
        bytes
    );
    let late = ok(
        api.send(
            "POST",
            &format!("{path}/dispatch"),
            &first,
            Some(json!({"clientId":"other","generation":generation})),
        )
        .await,
        200,
    );
    assert_eq!(late["preparation"]["state"], "stopped");
    assert!(cluster.llm.requests().is_empty());
    // The pre-allocation lease cannot substitute for the Node command lease.
    ok(api.send("POST",&format!("/api/sessions/{session}/commands"),&first,Some(json!({"commandId":"wrong-scope","clientId":"other","generation":generation,"payload":{"type":"prompt","message":"Should require Node control"}}))).await,409);
    let node_control = ok(
        api.send(
            "POST",
            &format!("/api/sessions/{session}/control/acquire"),
            &first,
            Some(json!({"clientId":"phone"})),
        )
        .await,
        200,
    );
    cluster
        .llm
        .push([Reply::Text("Only deliberate new work".into())]);
    ok(api.send("POST",&format!("/api/sessions/{session}/commands"),&first,Some(json!({"commandId":"new-after-stop","clientId":"phone","generation":node_control["lease"]["generation"],"payload":{"type":"prompt","message":"A deliberate new message"}}))).await,202);
    let until = Instant::now() + Duration::from_secs(10);
    while cluster.llm.requests().is_empty() {
        assert!(Instant::now() < until, "new work was not admitted");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let sent = cluster.llm.requests();
    assert_eq!(sent.len(), 1);
    assert!(
        sent[0]["messages"]
            .to_string()
            .contains("A deliberate new message")
    );
    assert!(
        !sent[0]["messages"]
            .to_string()
            .contains("Never execute this old first input")
    );
    cluster.restart_node(true).await;
    cluster.restart_gateway(true).await;
    let stopped = ok(
        api.send("GET", &format!("{path}/receipt"), &first, None)
            .await,
        200,
    );
    assert_eq!(stopped["preparation"]["state"], "stopped");
    assert_eq!(stopped["preparation"]["nodeMapped"], true);
    let snapshot = ok(
        api.send(
            "GET",
            &format!("/api/sessions/{session}/snapshot"),
            &first,
            None,
        )
        .await,
        200,
    );
    let history = snapshot["history"].to_string();
    assert!(history.contains("A deliberate new message"));
    assert!(!history.contains("Never execute this old first input"));
    assert_eq!(cluster.llm.requests().len(), 1);
}
