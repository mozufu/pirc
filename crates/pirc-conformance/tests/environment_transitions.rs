//! Real Gateway persistence/Node capability evidence for review-only transitions.
use pirc_conformance::{Cluster, WORKSPACE_ID, browser_headers};
use serde_json::json;

#[tokio::test(flavor = "multi_thread")]
async fn preview_survives_gateway_restart_and_node_offline_without_changing_binding() {
    let Some(mut cluster) = Cluster::start().await else {
        return;
    };
    let headers = browser_headers();
    let api = cluster.api();
    let created = api
        .send(
            "POST",
            "/api/sessions",
            &headers,
            Some(json!({"workspaceId":WORKSPACE_ID})),
        )
        .await;
    assert_eq!(created.status, 201, "{}", created.body);
    let id = created.body["session"]["id"].as_str().unwrap();
    let base = format!("/api/sessions/{id}");
    let before = api
        .send("GET", &format!("{base}/environment"), &headers, None)
        .await;
    assert_eq!(before.status, 200, "{}", before.body);
    let binding = before.body["binding"].clone();
    let intent = json!({"operationId":"review-existing","targetWorkspaceId":WORKSPACE_ID,"expectedBinding":binding});
    let prepared = api
        .send(
            "POST",
            &format!("{base}/environment-transitions/previews"),
            &headers,
            Some(intent.clone()),
        )
        .await;
    assert_eq!(prepared.status, 200, "{}", prepared.body);
    assert_eq!(prepared.body["canConfirm"], false);
    assert_eq!(
        prepared.body["resourcePreflight"]["status"], "observed",
        "{}",
        prepared.body
    );
    assert!(
        prepared.body["resourcePreflight"]
            .get("observation")
            .is_some()
    );
    assert_eq!(
        prepared.body["nodeObservations"][0]["confirmsRevocation"],
        false
    );
    assert_eq!(
        prepared.body["nodeObservations"][0]["installsEnvironment"],
        false
    );
    assert!(
        prepared.body["blockedBy"]
            .as_array()
            .unwrap()
            .contains(&json!("environment_unchanged"))
    );
    let path = format!("{base}/environment-transitions/previews/review-existing");
    cluster.restart_gateway(true).await;
    let api = cluster.api();
    let replay = api
        .send(
            "POST",
            &format!("{base}/environment-transitions/previews"),
            &headers,
            Some(intent),
        )
        .await;
    assert_eq!(replay.status, 200, "{}", replay.body);
    assert_eq!(replay.body["preview"], prepared.body["preview"]);
    cluster.stop_node(false).await;
    let offline = api.send("GET", &path, &headers, None).await;
    assert_eq!(offline.status, 200, "{}", offline.body);
    assert_eq!(offline.body["preview"], prepared.body["preview"]);
    assert_eq!(offline.body["canConfirm"], false);
    assert!(
        offline.body["resourcePreflight"]
            .get("observation")
            .is_none()
    );
    assert_eq!(offline.body["nodeObservations"][0]["status"], "offline");
    let after = api
        .send("GET", &format!("{base}/environment"), &headers, None)
        .await;
    assert_eq!(after.status, 200, "{}", after.body);
    assert_eq!(after.body["binding"], binding);
    cluster.resume_node().await;
    let resumed = api.send("GET", &path, &headers, None).await;
    assert_eq!(resumed.status, 200, "{}", resumed.body);
    assert_eq!(resumed.body["preview"], prepared.body["preview"]);
    assert_eq!(resumed.body["canConfirm"], false);
    // Recovery can change cached activity while retaining the same binding.
    if resumed.body["state"] == "stale" {
        assert_eq!(resumed.body["resourcePreflight"]["status"], "preview_stale");
        assert!(
            resumed.body["resourcePreflight"]
                .get("observation")
                .is_none()
        );
    } else {
        assert_eq!(resumed.body["resourcePreflight"]["status"], "observed");
    }
    let fresh=api.send("POST",&format!("{base}/environment-transitions/previews"),&headers,
        Some(json!({"operationId":"review-after-reconnect","targetWorkspaceId":WORKSPACE_ID,"expectedBinding":binding}))).await;
    assert_eq!(fresh.status, 200, "{}", fresh.body);
    assert_eq!(
        fresh.body["resourcePreflight"]["status"], "observed",
        "{}",
        fresh.body
    );
    assert_eq!(fresh.body["canConfirm"], false);
    let control = api
        .send(
            "POST",
            &format!("{base}/control/acquire"),
            &headers,
            Some(json!({"clientId":"phone"})),
        )
        .await;
    assert_eq!(control.status, 200, "{}", control.body);
    let snapshot = api
        .send("GET", &format!("{base}/snapshot"), &headers, None)
        .await;
    assert_eq!(snapshot.status, 200, "{}", snapshot.body);
    let final_environment = api
        .send("GET", &format!("{base}/environment"), &headers, None)
        .await;
    assert_eq!(final_environment.body["binding"], binding);
}
