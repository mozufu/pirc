//! Dedicated first-send endpoint through real Gateway, Node and Agent processes.
//! Paired requests need neither a browser connection nor a management grant.
use pirc_conformance::Reply;
use pirc_conformance::{
    CHATS_WORKSPACE_ID, Cluster, GatewayOptions, HOST, Response, browser_headers,
};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::time::{Duration, Instant};
fn ok(response: Response, status: u16) -> Value {
    assert_eq!(response.status, status, "{}", response.body);
    response.body
}
async fn setup(with_attachment: bool) -> Option<(Cluster, Vec<(&'static str, String)>, String)> {
    let cluster = Cluster::start_with(GatewayOptions {
        chat_node: true,
        agent_core_only: true,
        ..Default::default()
    })
    .await?;
    let api = cluster.api();
    let paired = ok(
        api.send(
            "POST",
            "/api/devices",
            &browser_headers(),
            Some(json!({"name":"native-admission"})),
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
    let content = b"Native attachment sentinel\n";
    let attachments = if with_attachment {
        json!([{"id":"first-file","name":"notes.txt","mimeType":"text/plain","byteSize":content.len(),"sha256":format!("{:x}",Sha256::digest(content))}])
    } else {
        json!([])
    };
    let prepared=ok(api.send("POST","/api/conversation-submissions/prepare",&headers,Some(json!({"operationId":"native-first","submission":{"workspaceId":CHATS_WORKSPACE_ID,"message":"Exact first text","model":{"provider":"fake","id":"fake-model"},"thinking":"low","attachments":attachments}}))).await,200);
    if with_attachment {
        ok(
            api.send_bytes(
                "PUT",
                "/api/conversation-submissions/native-first/attachments/first-file",
                &headers,
                Some("application/octet-stream"),
                content.to_vec(),
            )
            .await,
            200,
        );
    }
    let session = prepared["preparation"]["sessionId"]
        .as_str()
        .unwrap()
        .to_owned();
    ok(
        api.send(
            "POST",
            "/api/conversation-submissions/native-first/accept",
            &headers,
            None,
        )
        .await,
        202,
    );
    let ready = ok(
        api.send(
            "POST",
            "/api/conversation-submissions/native-first/materialize",
            &headers,
            None,
        )
        .await,
        200,
    );
    assert_eq!(ready["preparation"]["state"], "ready", "{ready}");
    Some((cluster, headers, session))
}
async fn lease(cluster: &Cluster, headers: &[(&str, String)], session: &str) -> Value {
    ok(
        cluster
            .api()
            .send(
                "POST",
                &format!("/api/sessions/{session}/control/acquire"),
                headers,
                Some(json!({"clientId":"native"})),
            )
            .await,
        200,
    )["lease"]["generation"]
        .clone()
}
async fn wait_calls(cluster: &Cluster, count: usize) {
    let until = Instant::now() + Duration::from_secs(10);
    while cluster.llm.requests().len() < count {
        assert!(
            Instant::now() < until,
            "provider never received the admitted message"
        );
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert_eq!(cluster.llm.requests().len(), count);
}
#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn initial_admission_survives_restart_and_duplicate_dispatch_never_calls_the_model_again() {
    let Some((mut cluster, headers, session)) = setup(true).await else {
        return;
    };
    cluster.llm.push([Reply::Text("Done".into())]);
    let api = cluster.api();
    let generation = lease(&cluster, &headers, &session).await;
    let input = json!({"clientId":"native","generation":generation});
    let dispatch = "/api/conversation-submissions/native-first/dispatch";
    let admitted = ok(api.send("POST", dispatch, &headers, Some(input)).await, 200);
    assert_eq!(admitted["preparation"]["state"], "admitted", "{admitted}");
    assert_eq!(
        admitted["preparation"]["messageAdmission"]["outcome"],
        "admitted"
    );
    wait_calls(&cluster, 1).await;
    let sent = cluster.llm.requests();
    assert_eq!(sent[0]["model"], "fake-model");
    assert!(
        sent[0]["messages"]
            .as_array()
            .unwrap()
            .iter()
            .any(|m| m["role"] == "user" && m["content"].to_string().contains("Exact first text"))
    );
    cluster.restart_node(true).await;
    cluster.restart_gateway(true).await;
    for _ in 0..3 {
        let receipt = ok(
            api.send(
                "GET",
                "/api/conversation-submissions/native-first/receipt",
                &headers,
                None,
            )
            .await,
            200,
        );
        assert_eq!(receipt["preparation"]["state"], "admitted");
        let retry = ok(
            api.send(
                "POST",
                dispatch,
                &headers,
                Some(json!({"clientId":"stale-other-device","generation":1})),
            )
            .await,
            200,
        );
        assert_eq!(retry["preparation"]["state"], "admitted");
    }
    let history = ok(
        api.send(
            "GET",
            &format!("/api/sessions/{session}/snapshot"),
            &headers,
            None,
        )
        .await,
        200,
    );
    let exact = history["history"]
        .as_array()
        .expect("history array")
        .iter()
        .filter(|entry| {
            entry["role"] == "user" && entry["content"].to_string().contains("Exact first text")
        })
        .count();
    assert_eq!(exact, 1, "{history}");
    assert_eq!(cluster.llm.requests().len(), 1);
    let uploads = std::fs::read_dir(cluster.dir.path().join("node-state/uploads"))
        .unwrap()
        .collect::<Result<Vec<_>, _>>()
        .unwrap();
    assert_eq!(uploads.len(), 1);
    assert_eq!(
        std::fs::read(uploads[0].path()).unwrap(),
        b"Native attachment sentinel\n"
    );
    let until = Instant::now() + Duration::from_secs(5);
    loop {
        let receipt = ok(
            api.send(
                "GET",
                "/api/conversation-submissions/native-first",
                &headers,
                None,
            )
            .await,
            200,
        );
        if receipt["preparation"]["cleanupPending"] == false {
            break;
        }
        assert!(
            Instant::now() < until,
            "accepted source cleanup did not finish"
        );
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
    assert!(
        ok(
            api.send(
                "GET",
                &format!("/api/sessions/{session}/control"),
                &headers,
                None
            )
            .await,
            200
        )["lease"]
            .is_null()
    );
}
#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn stop_before_first_send_prevents_late_dispatch_but_permits_an_explicit_new_message() {
    let Some((mut cluster, headers, session)) = setup(false).await else {
        return;
    };
    let api = cluster.api();
    let generation = lease(&cluster, &headers, &session).await;
    ok(api.send("POST",&format!("/api/sessions/{session}/commands"),&headers,Some(json!({"commandId":"stop-first","clientId":"native","generation":generation,"payload":{"type":"stop"}}))).await,202);
    cluster.restart_node(true).await;
    cluster.restart_gateway(true).await;
    let late = ok(
        api.send(
            "POST",
            "/api/conversation-submissions/native-first/dispatch",
            &headers,
            Some(json!({"clientId":"native","generation":generation})),
        )
        .await,
        200,
    );
    assert_eq!(late["preparation"]["state"], "stopped", "{late}");
    assert_eq!(
        late["preparation"]["messageAdmission"]["stopConfirmed"],
        true
    );
    assert_eq!(
        late["preparation"]["messageAdmission"]["outcome"],
        "not_admitted"
    );
    assert!(cluster.llm.requests().is_empty());
    let generation = lease(&cluster, &headers, &session).await;
    cluster
        .llm
        .push([Reply::Text("Only the new message".into())]);
    ok(api.send("POST",&format!("/api/sessions/{session}/commands"),&headers,Some(json!({"commandId":"new-explicit-message","clientId":"native","generation":generation,"payload":{"type":"prompt","message":"A deliberate replacement"}}))).await,202);
    wait_calls(&cluster, 1).await;
    assert!(
        !cluster.llm.requests()[0]["messages"]
            .to_string()
            .contains("Exact first text")
    );
    assert!(
        cluster.llm.requests()[0]["messages"]
            .to_string()
            .contains("A deliberate replacement")
    );
    let command = ok(
        api.send(
            "GET",
            &format!("/api/sessions/{session}/commands/new-explicit-message"),
            &headers,
            None,
        )
        .await,
        200,
    );
    assert_eq!(command["command"]["status"], "accepted");
}
