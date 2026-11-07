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
    // Node can install (2032), but confirmation stays gated at the Gateway.
    assert_eq!(
        prepared.body["nodeObservations"][0]["installsEnvironment"],
        true
    );
    assert!(
        prepared.body["blockedBy"]
            .as_array()
            .unwrap()
            .contains(&json!("environment_unchanged"))
    );
    let path = format!("{base}/environment-transitions/previews/review-existing");
    let blocked = api
        .send(
            "POST",
            &format!("{path}/confirm"),
            &headers,
            Some(json!({
                "planHash":prepared.body["preview"]["planHash"],
                "observationHash":prepared.body["resourcePreflight"]["observationHash"],
                "clientId":"review-client","generation":1
            })),
        )
        .await;
    assert_eq!(blocked.status, 409, "{}", blocked.body);
    assert_eq!(
        blocked.body["error"]["code"],
        "transition_coordinator_unavailable"
    );

    let reconcile_path = format!("{path}/reconcile");
    let absent = api
        .send("POST", &reconcile_path, &headers, Some(json!({})))
        .await;
    assert_eq!(absent.status, 200, "{}", absent.body);
    assert_eq!(absent.body["state"], "receipt_unavailable");
    assert!(absent.body["transition"].is_null());
    let receipt = api
        .send(
            "GET",
            &format!("{base}/environment-transitions/receipts/review-existing"),
            &headers,
            None,
        )
        .await;
    assert_eq!(
        receipt.status, 404,
        "A preview must not invent Node acceptance"
    );
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
    let missing = api
        .send("POST", &reconcile_path, &headers, Some(json!({})))
        .await;
    assert_eq!(missing.status, 200, "{}", missing.body);
    assert_eq!(missing.body["state"], "node_unavailable");
    assert!(missing.body["transition"].is_null());
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

mod switching {
    use pirc_conformance::{
        Api, Cluster, GatewayOptions, Reply, TARGET_WORKSPACE_ID, WORKSPACE_ID, browser_headers,
    };
    use serde_json::{Value, json};

    type Headers = Vec<(&'static str, String)>;
    async fn ok(api: &Api, headers: &Headers, method: &str, path: &str, body: Value) -> Value {
        let response = api.send(method, path, headers, Some(body)).await;
        assert!(
            response.status < 300,
            "{method} {path}: {} {}",
            response.status,
            response.body
        );
        response.body
    }
    async fn get(api: &Api, headers: &Headers, path: &str) -> Value {
        let response = api.send("GET", path, headers, None).await;
        assert_eq!(response.status, 200, "{path}: {}", response.body);
        response.body
    }
    /// A conversation on `test:test` with current control.
    async fn conversation(api: &Api, headers: &Headers) -> (String, Value) {
        let created = ok(
            api,
            headers,
            "POST",
            "/api/sessions",
            json!({"workspaceId":WORKSPACE_ID}),
        )
        .await;
        let id = created["session"]["id"].as_str().unwrap().to_owned();
        let generation = ok(
            api,
            headers,
            "POST",
            &format!("/api/sessions/{id}/control/acquire"),
            json!({"clientId":"web","force":true}),
        )
        .await["lease"]["generation"]
            .clone();
        (id, generation)
    }
    async fn settle_prompt(
        api: &Api,
        headers: &Headers,
        id: &str,
        generation: &Value,
        command: &str,
    ) {
        // Clients send the binding they show; a changed environment needs a refresh.
        let binding =
            get(api, headers, &format!("/api/sessions/{id}/environment")).await["binding"].clone();
        ok(
            api,
            headers,
            "POST",
            &format!("/api/sessions/{id}/commands"),
            json!({"commandId":command,"clientId":"web","generation":generation,"expectedBinding":binding,
                "payload":{"type":"prompt","message":command}}),
        )
        .await;
        for _ in 0..200 {
            let snapshot = get(api, headers, &format!("/api/sessions/{id}/snapshot")).await;
            if snapshot.to_string().contains("Replied.")
                && snapshot["session"]["status"] != "running"
            {
                return;
            }
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        }
        panic!("the prompt never settled");
    }
    /// Review and confirm a move to `test:target`; returns the accepted status.
    async fn confirm(
        api: &Api,
        headers: &Headers,
        id: &str,
        generation: &Value,
        op: &str,
    ) -> Value {
        let binding =
            get(api, headers, &format!("/api/sessions/{id}/environment")).await["binding"].clone();
        let preview = ok(
            api,
            headers,
            "POST",
            &format!("/api/sessions/{id}/environment-transitions/previews"),
            json!({"operationId":op,"targetWorkspaceId":TARGET_WORKSPACE_ID,"expectedBinding":binding}),
        )
        .await;
        assert_eq!(preview["canConfirm"], true, "{preview}");
        ok(
            api,
            headers,
            "POST",
            &format!("/api/sessions/{id}/environment-transitions/previews/{op}/confirm"),
            json!({"planHash":preview["preview"]["planHash"],
                "observationHash":preview["resourcePreflight"]["observationHash"],
                "clientId":"web","generation":generation}),
        )
        .await
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn an_enabled_switch_installs_after_confirmed_or_acknowledged_revocation() {
        let Some(cluster) = Cluster::start_with(GatewayOptions {
            env: vec![("PIRC_ENVIRONMENT_SWITCHING", "1".to_owned())],
            second_workspace: true,
            ..GatewayOptions::default()
        })
        .await
        else {
            return;
        };
        let headers = browser_headers();
        let api = cluster.api();

        // A conversation that never ran: nothing needs to be contained.
        let (idle, generation) = conversation(&api, &headers).await;
        let accepted = confirm(&api, &headers, &idle, &generation, "move-idle").await;
        assert_eq!(accepted["transition"]["state"], "node_fenced", "{accepted}");
        let installed = ok(
            &api,
            &headers,
            "POST",
            &format!("/api/sessions/{idle}/environment-transitions/move-idle/advance"),
            json!({"clientId":"web","generation":generation}),
        )
        .await;
        assert_eq!(installed["transition"]["state"], "installed", "{installed}");
        assert_eq!(installed["transition"]["revocationConfirmed"], true);
        let environment = get(&api, &headers, &format!("/api/sessions/{idle}/environment")).await;
        assert_eq!(
            environment["binding"]["execution"]["workspaceId"], TARGET_WORKSPACE_ID,
            "{environment}"
        );
        assert!(environment["activeTransition"].is_null());
        // The next prompt runs in the new environment, after its notice.
        cluster.llm.push([Reply::Text("Replied.".into())]);
        settle_prompt(&api, &headers, &idle, &generation, "after-move").await;
        let snapshot = get(&api, &headers, &format!("/api/sessions/{idle}/snapshot")).await;
        assert!(
            snapshot.to_string().contains("environment-change"),
            "{snapshot}"
        );

        // A conversation whose Agent ran cannot prove containment on this host.
        let (busy, generation) = conversation(&api, &headers).await;
        cluster.llm.push([Reply::Text("Replied.".into())]);
        settle_prompt(&api, &headers, &busy, &generation, "before-move").await;
        confirm(&api, &headers, &busy, &generation, "move-busy").await;
        let waiting = ok(
            &api,
            &headers,
            "POST",
            &format!("/api/sessions/{busy}/environment-transitions/move-busy/advance"),
            json!({"clientId":"web","generation":generation}),
        )
        .await;
        assert_eq!(waiting["transition"]["state"], "node_fenced", "{waiting}");
        let revocation = &waiting["progress"]["revocation"];
        assert_eq!(revocation["status"], "unproven", "{waiting}");
        assert!(
            revocation["items"]
                .as_array()
                .unwrap()
                .iter()
                .any(|item| item["kind"] == "platform_containment")
        );
        assert!(!waiting.to_string().contains("/private"));
        let blocked = api
            .send(
                "POST",
                &format!("/api/sessions/{busy}/commands"),
                &headers,
                Some(
                    json!({"commandId":"during","clientId":"web","generation":generation,
                    "payload":{"type":"prompt","message":"during"}}),
                ),
            )
            .await;
        assert_eq!(blocked.status, 409, "{}", blocked.body);
        let acknowledged = ok(
            &api,
            &headers,
            "POST",
            &format!("/api/sessions/{busy}/environment-transitions/move-busy/acknowledge"),
            json!({"digest":revocation["digest"],"clientId":"web","generation":generation}),
        )
        .await;
        assert_eq!(
            acknowledged["transition"]["state"], "installed",
            "{acknowledged}"
        );
        assert_eq!(acknowledged["transition"]["revocationConfirmed"], false);
        assert_eq!(
            acknowledged["progress"]["installation"]["revocation"],
            "unproven"
        );
        let environment = get(&api, &headers, &format!("/api/sessions/{busy}/environment")).await;
        assert_eq!(
            environment["binding"]["execution"]["workspaceId"],
            TARGET_WORKSPACE_ID
        );
    }
}
