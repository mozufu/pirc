//! Real Gateway/Node metadata is identical for Web and paired-device HTTP.
//! This is saved content provenance, not proof of filesystem mount revocation.
use pirc_conformance::{Api, CHATS_WORKSPACE_ID, Cluster, GatewayOptions, HOST, browser_headers};
use serde_json::json;
async fn create(api: &Api) -> String {
    let r = api
        .send(
            "POST",
            "/api/sessions",
            &browser_headers(),
            Some(json!({"workspaceId":CHATS_WORKSPACE_ID})),
        )
        .await;
    assert_eq!(r.status, 201, "{}", r.body);
    r.body["session"]["id"].as_str().unwrap().into()
}
#[ignore = "pirc 2: needs a session created through first-send instead of the removed POST /api/sessions; rewritten after M4 (plans/roadmap.md M2.9)"]
#[tokio::test(flavor = "multi_thread")]
async fn saved_upload_origin_is_shared_across_devices_and_survives_restart() {
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
    let web = browser_headers();
    let first = create(&api).await;
    let other = create(&api).await;
    let uploaded = api
        .send_bytes(
            "POST",
            &format!("/api/sessions/{first}/uploads?filename=saved.txt"),
            &web,
            Some("text/plain"),
            b"saved attachment".to_vec(),
        )
        .await;
    assert_eq!(uploaded.status, 201, "{}", uploaded.body);
    let upload = uploaded.body["upload"]["id"].as_str().unwrap();
    let path = format!("/api/sessions/{other}/uploads/{upload}/reference");
    let reference = api.send("GET", &path, &web, None).await;
    assert_eq!(reference.status, 200, "{}", reference.body);
    let r = &reference.body["reference"];
    assert_eq!(r["kind"], "saved_attachment");
    assert_eq!(r["provenance"], "recorded");
    assert_eq!(r["scope"], "workspace");
    assert_eq!(r["origin"]["sessionId"], first);
    assert_eq!(r["origin"]["workspaceId"], CHATS_WORKSPACE_ID);
    assert!(r.get("storageName").is_none());
    assert!(r.get("ownerUser").is_none());
    let pair = api
        .send(
            "POST",
            "/api/devices",
            &web,
            Some(json!({"name":"attachment-check"})),
        )
        .await;
    assert_eq!(pair.status, 201, "{}", pair.body);
    let phone = vec![
        ("host", HOST.into()),
        ("x-pirc-client", pirc_conformance::CLIENT.to_owned()),
        (
            "authorization",
            format!("Bearer {}", pair.body["token"].as_str().unwrap()),
        ),
    ];
    let mobile = api.send("GET", &path, &phone, None).await;
    assert_eq!(mobile.status, 200, "{}", mobile.body);
    assert_eq!(mobile.body, reference.body);
    cluster.restart_node(true).await;
    cluster.restart_gateway(true).await;
    let after = cluster.api().send("GET", &path, &phone, None).await;
    assert_eq!(after.status, 200, "{}", after.body);
    assert_eq!(after.body, reference.body);
    let removed = cluster
        .api()
        .send("DELETE", &format!("/api/sessions/{first}"), &web, None)
        .await;
    assert_eq!(removed.status, 204, "{}", removed.body);
    // Ordinary workspace-scoped uploads retain their existing lifetime after a
    // source chat is deleted. The now-private origin is not exposed or reassigned.
    let retained = cluster.api().send("GET", &path, &phone, None).await;
    assert_eq!(retained.status, 200, "{}", retained.body);
    assert!(retained.body["reference"]["origin"]["sessionId"].is_null());
    assert_eq!(
        retained.body["reference"]["origin"]["workspaceId"],
        CHATS_WORKSPACE_ID
    );
    assert!(cluster.llm.requests().is_empty());
}
