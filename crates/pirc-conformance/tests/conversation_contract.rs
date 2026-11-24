//! Real Gateway/Node proof that an old/cached client cannot start the new flow.
use pirc_conformance::{CHATS_WORKSPACE_ID, Cluster, GatewayOptions, HOST, browser_headers};
use serde_json::json;
#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn old_clients_can_inspect_but_cannot_allocate_or_dispatch_new_first_send() {
    let Some(cluster) = Cluster::start_with(GatewayOptions {
        chat_node: true,
        agent_core_only: true,
        ..Default::default()
    })
    .await
    else {
        return;
    };
    let api = cluster.api();
    let old = browser_headers();
    let mut current = old.clone();
    current.push(("x-pirc-first-send-contract", "2".into()));
    let cap = api
        .send(
            "GET",
            "/api/conversation-submissions/capabilities",
            &old,
            None,
        )
        .await;
    assert_eq!(cap.status, 200);
    assert_eq!(cap.body["canSubmit"], false);
    assert_eq!(cap.body["clientContract"], 0);
    let cap = api
        .send(
            "GET",
            "/api/conversation-submissions/capabilities",
            &current,
            None,
        )
        .await;
    assert_eq!(cap.body["clientContract"], 2);
    assert_eq!(cap.body["requiredClientContract"], 2);
    assert_eq!(cap.body["canSubmit"], true);
    let body = json!({"operationId":"mixed-version","submission":{"workspaceId":CHATS_WORKSPACE_ID,"message":"Do not dispatch through old code","attachments":[]}});
    let rejected = api
        .send(
            "POST",
            "/api/conversation-submissions/prepare",
            &old,
            Some(body.clone()),
        )
        .await;
    assert_eq!(rejected.status, 409);
    assert_eq!(
        rejected.body["error"]["code"],
        "first_send_client_upgrade_required"
    );
    let prepared = api
        .send(
            "POST",
            "/api/conversation-submissions/prepare",
            &current,
            Some(body),
        )
        .await;
    assert_eq!(prepared.status, 200, "{}", prepared.body);
    let path = "/api/conversation-submissions/mixed-version";
    assert_eq!(api.send("GET", path, &old, None).await.status, 200);
    for endpoint in ["accept", "materialize", "dispatch"] {
        let r = api
            .send(
                "POST",
                &format!("{path}/{endpoint}"),
                &old,
                Some(json!({"clientId":"old-cached-true","generation":1})),
            )
            .await;
        assert_eq!(r.status, 409, "{}", r.body);
        assert_eq!(
            r.body["error"]["code"],
            "first_send_client_upgrade_required"
        );
    }
    let sessions = api.send("GET", "/api/sessions", &old, None).await;
    assert_eq!(sessions.body["sessions"].as_array().unwrap().len(), 0);
    assert!(cluster.llm.requests().is_empty());
    // Ordinary legacy conversation creation retains its existing API.
    let legacy = api
        .send(
            "POST",
            "/api/sessions",
            &old,
            Some(json!({"workspaceId":CHATS_WORKSPACE_ID})),
        )
        .await;
    assert_eq!(legacy.status, 201, "{}", legacy.body);
    assert!(cluster.llm.requests().is_empty());
    // A paired client has the same compatibility boundary without a Web page.
    let paired = api
        .send(
            "POST",
            "/api/devices",
            &old,
            Some(json!({"name":"mixed-version"})),
        )
        .await;
    let device = vec![
        ("host", HOST.into()),
        (
            "authorization",
            format!("Bearer {}", paired.body["token"].as_str().unwrap()),
        ),
    ];
    assert_eq!(
        api.send("POST", &format!("{path}/accept"), &device, None)
            .await
            .status,
        409
    );
    assert_eq!(api.send("GET", path, &device, None).await.status, 200);
}
