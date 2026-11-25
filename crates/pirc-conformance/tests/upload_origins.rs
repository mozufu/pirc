//! Real Gateway/Node metadata is identical for Web and paired-device HTTP.
//! This is saved content provenance, not proof of filesystem mount revocation.
use pirc_conformance::{
    Api, Cluster, FirstSend, GatewayOptions, HOST, WORKSPACE_ID, browser_headers,
};
use serde_json::json;

static NEXT_OPERATION: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(1);

async fn create(api: &Api) -> String {
    let operation = NEXT_OPERATION.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    FirstSend::browser(api)
        .workspace(WORKSPACE_ID)
        .operation(format!("first-{operation}"))
        .start_idle()
        .await
        .id
}
#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn saved_upload_origin_is_shared_across_devices_and_survives_restart() {
    let Some(mut cluster) = Cluster::start_with(GatewayOptions {
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
    assert_eq!(r["origin"]["workspaceId"], WORKSPACE_ID);
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
    assert!(cluster.llm.requests().is_empty());
}
