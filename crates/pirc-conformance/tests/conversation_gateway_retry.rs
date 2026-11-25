//! Same first message/session/files across known rejection and real host restarts.
use pirc_conformance::{
    Cluster, GatewayOptions, HOST, Reply, Response, USER, WORKSPACE_ID, browser_headers,
};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::time::{Duration, Instant};
fn ok(response: Response, status: u16) -> Value {
    assert_eq!(response.status, status, "{}", response.body);
    response.body
}
fn headers(token: &str) -> Vec<(&'static str, String)> {
    vec![
        ("host", HOST.into()),
        ("authorization", format!("Bearer {token}")),
        ("x-pirc-client", pirc_conformance::CLIENT.into()),
        ("x-pirc-account", USER.replace('@', "%40")),
    ]
}
async fn lease(cluster: &Cluster, headers: &[(&str, String)], session: &str) -> Value {
    ok(
        cluster
            .api()
            .send(
                "POST",
                &format!("/api/sessions/{session}/control/acquire"),
                headers,
                Some(json!({"clientId":"phone"})),
            )
            .await,
        200,
    )["lease"]["generation"]
        .clone()
}
#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn paired_retry_reuses_the_same_conversation_and_file_and_survives_both_hosts_restarting() {
    let Some(mut cluster) = Cluster::start_with(GatewayOptions {
        agent_core_only: true,
        node_env: vec![("PIRC_AGENT_COMMAND", "{run_dir}/agent-for-retry".into())],
        ..Default::default()
    })
    .await
    else {
        return;
    };
    let paired = ok(
        cluster
            .api()
            .send(
                "POST",
                "/api/devices",
                &browser_headers(),
                Some(json!({"name":"retry-device"})),
            )
            .await,
        201,
    );
    let device = headers(paired["token"].as_str().unwrap());
    let other = ok(
        cluster
            .api()
            .send(
                "POST",
                "/api/devices",
                &browser_headers(),
                Some(json!({"name":"second-device"})),
            )
            .await,
        201,
    );
    let other = headers(other["token"].as_str().unwrap());
    let bytes = b"Original attachment remains available\n";
    let prepared=ok(cluster.api().send("POST","/api/conversation-submissions/prepare",&device,Some(json!({"operationId":"first","submission":{"workspaceId":WORKSPACE_ID,"message":"Retained first message after known refusal","model":{"provider":"fake","id":"fake-model"},"thinking":"low","attachments":[{"id":"file","name":"retained.txt","mimeType":"text/plain","byteSize":bytes.len(),"sha256":format!("{:x}",Sha256::digest(bytes))}]}}))).await,200);
    let session = prepared["preparation"]["sessionId"]
        .as_str()
        .unwrap()
        .to_owned();
    ok(
        cluster
            .api()
            .send_bytes(
                "PUT",
                "/api/conversation-submissions/first/attachments/file",
                &device,
                Some("application/octet-stream"),
                bytes.to_vec(),
            )
            .await,
        200,
    );
    ok(
        cluster
            .api()
            .send(
                "POST",
                "/api/conversation-submissions/first/accept",
                &device,
                None,
            )
            .await,
        202,
    );
    ok(
        cluster
            .api()
            .send(
                "POST",
                "/api/conversation-submissions/first/materialize",
                &device,
                None,
            )
            .await,
        200,
    );
    let generation = lease(&cluster, &device, &session).await;
    let first = ok(
        cluster
            .api()
            .send(
                "POST",
                "/api/conversation-submissions/first/dispatch",
                &device,
                Some(json!({"clientId":"phone","generation":generation})),
            )
            .await,
        200,
    );
    assert_eq!(first["preparation"]["state"], "admission_failed", "{first}");
    assert_eq!(
        first["preparation"]["messageAdmission"]["retryEligible"],
        true
    );
    let previous = first["preparation"]["messageAdmission"]["commandId"]
        .as_str()
        .unwrap()
        .to_owned();
    assert!(cluster.llm.requests().is_empty());
    // Client persisted its nonce, then died before POST: a 404 is insufficient.
    // Retire it durably before permitting any later explicit fresh attempt.
    let retired = ok(cluster.api().send(
        "POST", "/api/conversation-submissions/first/retries/unsent/retire", &device,
        Some(json!({"previousCommandId":previous,"clientId":"phone","generation":generation})),
    ).await, 200);
    let retirement = json!({"retryId":"unsent","previousCommandId":previous,"status":"not_reserved","retired":true});
    assert_eq!(retired["retry"], retirement);
    assert!(cluster.llm.requests().is_empty());
    // CI supplies a repository-relative bin dir. Resolve it through the same
    // harness path as Cluster; a relative symlink would point inside the fixture.
    let executable = pirc_conformance::bin_dir().unwrap().join("pirc-node");
    let agent = cluster.dir.path().join("agent-for-retry");
    std::os::unix::fs::symlink(executable, &agent).unwrap();
    assert!(agent.is_file(), "retry agent symlink must resolve");
    cluster.restart_node(true).await;
    cluster.restart_gateway(true).await;
    let before = ok(
        cluster
            .api()
            .send(
                "GET",
                "/api/conversation-submissions/first/receipt",
                &device,
                None,
            )
            .await,
        200,
    );
    assert_eq!(before["preparation"]["state"], "admission_failed");
    let saved = ok(
        cluster
            .api()
            .send(
                "GET",
                "/api/conversation-submissions/first/retries/unsent",
                &other,
                None,
            )
            .await,
        200,
    );
    assert_eq!(saved["retry"], retirement);
    // A request delayed across retirement and both host restarts cannot revive it.
    let late = ok(cluster.api().send("POST", "/api/conversation-submissions/first/retry", &device,
        Some(json!({"retryId":"unsent","previousCommandId":previous,"clientId":"phone","generation":generation})),
    ).await, 409);
    assert_eq!(late["error"]["code"], "retry_retired");
    assert!(cluster.llm.requests().is_empty());
    let generation = lease(&cluster, &device, &session).await;
    cluster
        .llm
        .push([Reply::Text("Retried exactly once".into())]);
    let body = json!({"retryId":"retry-a","previousCommandId":previous,"clientId":"phone","generation":generation});
    let retried = ok(
        cluster
            .api()
            .send(
                "POST",
                "/api/conversation-submissions/first/retry",
                &device,
                Some(body.clone()),
            )
            .await,
        200,
    );
    assert_eq!(retried["preparation"]["state"], "admitted", "{retried}");
    assert_eq!(retried["preparation"]["sessionId"], session);
    assert_eq!(
        retried["preparation"]["messageAdmission"]["attemptNumber"],
        1
    );
    let command = retried["preparation"]["messageAdmission"]["commandId"]
        .as_str()
        .unwrap()
        .to_owned();
    assert_ne!(command, previous);
    let until = Instant::now() + Duration::from_secs(10);
    while cluster.llm.requests().is_empty() {
        assert!(Instant::now() < until, "retry never inferred");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    // The same nonce is readable by another paired device without taking control.
    let duplicate=ok(cluster.api().send("POST","/api/conversation-submissions/first/retry",&other,Some(json!({"retryId":"retry-a","previousCommandId":previous,"clientId":"other-device","generation":999}))).await,200);
    assert_eq!(
        duplicate["preparation"]["messageAdmission"]["commandId"],
        command
    );
    let history = ok(
        cluster
            .api()
            .send(
                "GET",
                &format!("/api/sessions/{session}/snapshot"),
                &device,
                None,
            )
            .await,
        200,
    );
    assert_eq!(
        history["history"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|entry| entry["role"] == "user"
                && entry["content"]
                    .to_string()
                    .contains("Retained first message after known refusal"))
            .count(),
        1,
        "{history}"
    );
    let list = ok(
        cluster
            .api()
            .send("GET", "/api/sessions", &other, None)
            .await,
        200,
    );
    assert_eq!(list["sessions"].as_array().unwrap().len(), 1);
    let uploads = std::fs::read_dir(cluster.dir.path().join("node-state/uploads"))
        .unwrap()
        .collect::<Result<Vec<_>, _>>()
        .unwrap();
    assert_eq!(uploads.len(), 1);
    assert_eq!(std::fs::read(uploads[0].path()).unwrap(), bytes);
    let old = ok(
        cluster
            .api()
            .send(
                "GET",
                &format!("/api/sessions/{session}/commands/{previous}"),
                &other,
                None,
            )
            .await,
        200,
    );
    assert_eq!(old["command"]["status"], "rejected");
    cluster.restart_node(true).await;
    cluster.restart_gateway(true).await;
    let status = ok(
        cluster
            .api()
            .send(
                "GET",
                "/api/conversation-submissions/first/retries/retry-a",
                &other,
                None,
            )
            .await,
        200,
    );
    assert_eq!(status["retry"]["commandId"], command);
    assert_eq!(status["retry"]["attemptNumber"], 1);
    assert_eq!(status["retry"]["status"], "accepted");
    assert_eq!(status["retry"]["isCurrent"], true);
    let reserved = ok(cluster.api().send("POST", "/api/conversation-submissions/first/retries/retry-a/retire", &other,
        Some(json!({"previousCommandId":previous,"clientId":"other-device","generation":999})),
    ).await, 200);
    assert_eq!(reserved["retry"]["commandId"], command);
    assert_eq!(reserved["retry"]["status"], "accepted");
    assert_ne!(reserved["retry"]["retired"], true);
    let duplicate = ok(
        cluster
            .api()
            .send(
                "POST",
                "/api/conversation-submissions/first/retry",
                &other,
                Some(body),
            )
            .await,
        200,
    );
    assert_eq!(
        duplicate["preparation"]["messageAdmission"]["commandId"],
        command
    );
    assert_eq!(duplicate["preparation"]["state"], "admitted");
    assert_eq!(
        duplicate["preparation"]["messageAdmission"]["attemptNumber"],
        1
    );
    assert_eq!(cluster.llm.requests().len(), 1);
}
