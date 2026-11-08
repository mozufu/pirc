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

    async fn acquire(api: &Api, headers: &Headers, id: &str, client: &str) -> Value {
        ok(
            api,
            headers,
            "POST",
            &format!("/api/sessions/{id}/control/acquire"),
            json!({"clientId":client,"force":true}),
        )
        .await["lease"]["generation"]
            .clone()
    }
    fn switching() -> GatewayOptions {
        GatewayOptions {
            env: vec![("PIRC_ENVIRONMENT_SWITCHING", "1".to_owned())],
            second_workspace: true,
            ..GatewayOptions::default()
        }
    }
    async fn receipt(api: &Api, headers: &Headers, id: &str, op: &str) -> Value {
        get(
            api,
            headers,
            &format!("/api/sessions/{id}/environment-transitions/receipts/{op}"),
        )
        .await
    }
    async fn advance(
        api: &Api,
        headers: &Headers,
        id: &str,
        op: &str,
        generation: &Value,
    ) -> Value {
        ok(
            api,
            headers,
            "POST",
            &format!("/api/sessions/{id}/environment-transitions/{op}/advance"),
            json!({"clientId":"web","generation":generation}),
        )
        .await
    }
    async fn workspace(api: &Api, headers: &Headers, id: &str) -> Value {
        get(api, headers, &format!("/api/sessions/{id}/environment")).await["binding"]["execution"]
            .clone()
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_gateway_crash_after_confirmation_is_finished_by_the_recovery_sweep() {
        let Some(mut cluster) = Cluster::start_with(switching()).await else {
            return;
        };
        let headers = browser_headers();
        let (id, generation) = conversation(&cluster.api(), &headers).await;
        confirm(&cluster.api(), &headers, &id, &generation, "move-crash").await;
        // No client calls advance: the restarted Gateway resumes on its own.
        cluster.restart_gateway(true).await;
        let api = cluster.api();
        let mut state = Value::Null;
        for _ in 0..200 {
            state = receipt(&api, &headers, &id, "move-crash").await["transition"]["state"].clone();
            if state == "installed" {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        }
        assert_eq!(state, "installed");
        let execution = workspace(&api, &headers, &id).await;
        assert_eq!(execution["workspaceId"], TARGET_WORKSPACE_ID);
        assert_eq!(execution["generation"], 2);
        let _ = generation;
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn an_offline_node_keeps_the_switch_pending_and_a_restarted_node_finishes_it() {
        let Some(mut cluster) = Cluster::start_with(switching()).await else {
            return;
        };
        let headers = browser_headers();
        let api = cluster.api();
        let (id, generation) = conversation(&api, &headers).await;
        confirm(&api, &headers, &id, &generation, "move-offline").await;
        cluster.stop_node(false).await;
        // Control is mirrored from the Node, so it lapses while the Node is
        // away; the read-only status keeps the fenced stage and the binding.
        let refused = api
            .send(
                "POST",
                &format!("/api/sessions/{id}/environment-transitions/move-offline/advance"),
                &headers,
                Some(json!({"clientId":"web","generation":generation})),
            )
            .await;
        assert_eq!(refused.status, 409, "{}", refused.body);
        assert_eq!(
            receipt(&api, &headers, &id, "move-offline").await["transition"]["state"],
            "node_fenced"
        );
        assert_eq!(
            workspace(&api, &headers, &id).await["workspaceId"],
            WORKSPACE_ID
        );
        // The restarted Node keeps its retained fence; nothing is lost or replayed.
        // Its controller reconnects and takes control again before continuing.
        cluster.resume_node().await;
        let generation = acquire(&api, &headers, &id, "web").await;
        let mut installed = Value::Null;
        for _ in 0..100 {
            let response = api
                .send(
                    "POST",
                    &format!("/api/sessions/{id}/environment-transitions/move-offline/advance"),
                    &headers,
                    Some(json!({"clientId":"web","generation":generation})),
                )
                .await;
            if response.status == 200 && response.body["transition"]["state"] == "installed" {
                installed = response.body;
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        }
        assert_eq!(installed["transition"]["state"], "installed", "{installed}");
        assert_eq!(
            workspace(&api, &headers, &id).await["workspaceId"],
            TARGET_WORKSPACE_ID
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn concurrent_steps_install_once_and_a_takeover_moves_control() {
        let Some(cluster) = Cluster::start_with(switching()).await else {
            return;
        };
        let headers = browser_headers();
        let api = cluster.api();
        let (id, generation) = conversation(&api, &headers).await;
        confirm(&api, &headers, &id, &generation, "move-twice").await;
        let (a, b) = tokio::join!(
            advance(&api, &headers, &id, "move-twice", &generation),
            advance(&api, &headers, &id, "move-twice", &generation)
        );
        for result in [&a, &b] {
            assert_eq!(result["transition"]["state"], "installed", "{result}");
        }
        // One installation: the binding advanced by exactly one generation.
        assert_eq!(workspace(&api, &headers, &id).await["generation"], 2);

        // Another device takes control: the first device's steps are refused
        // and only the new controller can continue the switch.
        let (other, generation) = conversation(&api, &headers).await;
        confirm(&api, &headers, &other, &generation, "move-takeover").await;
        let tablet = acquire(&api, &headers, &other, "tablet").await;
        let stale = api
            .send(
                "POST",
                &format!("/api/sessions/{other}/environment-transitions/move-takeover/advance"),
                &headers,
                Some(json!({"clientId":"web","generation":generation})),
            )
            .await;
        assert_eq!(stale.status, 409, "{}", stale.body);
        assert_eq!(
            workspace(&api, &headers, &other).await["workspaceId"],
            WORKSPACE_ID
        );
        let continued = ok(
            &api,
            &headers,
            "POST",
            &format!("/api/sessions/{other}/environment-transitions/move-takeover/advance"),
            json!({"clientId":"tablet","generation":tablet}),
        )
        .await;
        assert_eq!(continued["transition"]["state"], "installed", "{continued}");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn cancel_after_the_drain_keeps_the_original_workspace_and_reopens_work() {
        let Some(cluster) = Cluster::start_with(switching()).await else {
            return;
        };
        let headers = browser_headers();
        let api = cluster.api();
        let (id, generation) = conversation(&api, &headers).await;
        cluster.llm.push([Reply::Text("Replied.".into())]);
        settle_prompt(&api, &headers, &id, &generation, "before-cancel").await;
        confirm(&api, &headers, &id, &generation, "move-cancel").await;
        let waiting = advance(&api, &headers, &id, "move-cancel", &generation).await;
        assert_eq!(
            waiting["progress"]["revocation"]["status"], "unproven",
            "{waiting}"
        );
        let released = ok(
            &api,
            &headers,
            "POST",
            &format!("/api/sessions/{id}/environment-transitions/move-cancel/cancel"),
            json!({"clientId":"web","generation":generation}),
        )
        .await;
        assert_eq!(released["transition"]["state"], "released", "{released}");
        let execution = workspace(&api, &headers, &id).await;
        assert_eq!(execution["workspaceId"], WORKSPACE_ID);
        assert_eq!(execution["generation"], 1);
        // Work resumes on the original binding; stopped work is not restarted.
        cluster.llm.push([Reply::Text("Replied.".into())]);
        settle_prompt(&api, &headers, &id, &generation, "after-cancel").await;
        let late = api
            .send(
                "POST",
                &format!("/api/sessions/{id}/environment-transitions/move-cancel/acknowledge"),
                &headers,
                Some(json!({"digest":waiting["progress"]["revocation"]["digest"],"clientId":"web","generation":generation})),
            )
            .await;
        assert_eq!(late.status, 409, "{}", late.body);
    }

    /// Switching with C1 operation authority and a short device lease.
    fn with_authority(secs: &str, lease_ms: &str) -> GatewayOptions {
        GatewayOptions {
            env: vec![
                ("PIRC_ENVIRONMENT_SWITCHING", "1".to_owned()),
                ("PIRC_TRANSITION_AUTHORITY_SECONDS", secs.to_owned()),
            ],
            node_env: vec![("PIRC_LEASE_TTL_MS", lease_ms.to_owned())],
            second_workspace: true,
            ..GatewayOptions::default()
        }
    }
    async fn until_installed(api: &Api, headers: &Headers, id: &str, op: &str) -> Value {
        let mut last = Value::Null;
        for _ in 0..200 {
            last = receipt(api, headers, id, op).await;
            if last["transition"]["state"] == "installed" {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        }
        last
    }

    /// O1: confirm, then every client goes away and control expires. The
    /// backend finishes exactly one binding update with operation authority.
    #[tokio::test(flavor = "multi_thread")]
    async fn o1_a_confirmed_switch_finishes_after_control_expires_and_clients_close() {
        let Some(mut cluster) = Cluster::start_with(with_authority("60", "1500")).await else {
            return;
        };
        let headers = browser_headers();
        let (id, generation) = conversation(&cluster.api(), &headers).await;
        let accepted = confirm(&cluster.api(), &headers, &id, &generation, "move-o1").await;
        assert_eq!(accepted["authority"]["revision"], 1, "{accepted}");
        assert_eq!(accepted["authority"]["state"], "active");
        // No renewal: the device lease lapses; then the Gateway restarts.
        tokio::time::sleep(std::time::Duration::from_millis(2_000)).await;
        cluster.restart_gateway(true).await;
        let api = cluster.api();
        let finished = until_installed(&api, &headers, &id, "move-o1").await;
        assert_eq!(finished["transition"]["state"], "installed", "{finished}");
        let environment = get(&api, &headers, &format!("/api/sessions/{id}/environment")).await;
        assert_eq!(
            environment["binding"]["execution"]["workspaceId"],
            TARGET_WORKSPACE_ID
        );
        assert_eq!(environment["binding"]["execution"]["generation"], 2);
        assert_eq!(
            environment["lastFinishedTransition"]["operationId"],
            "move-o1"
        );
        assert!(!finished.to_string().contains("token\""));
    }

    /// O2 and O6: the Node is away past the lease and the authority deadline.
    /// Nothing installs; the current controller must reauthorize to continue.
    #[tokio::test(flavor = "multi_thread")]
    async fn o2_o6_expired_authority_needs_reauthorization_before_installing() {
        let Some(mut cluster) = Cluster::start_with(with_authority("3", "1500")).await else {
            return;
        };
        let headers = browser_headers();
        let api = cluster.api();
        let (id, generation) = conversation(&api, &headers).await;
        confirm(&api, &headers, &id, &generation, "move-o6").await;
        cluster.stop_node(false).await;
        tokio::time::sleep(std::time::Duration::from_millis(3_500)).await;
        cluster.resume_node().await;
        // Give the reconnect pass time to run; it may drain but cannot install.
        tokio::time::sleep(std::time::Duration::from_millis(1_500)).await;
        let waiting = receipt(&api, &headers, &id, "move-o6").await;
        assert_eq!(waiting["transition"]["state"], "node_fenced", "{waiting}");
        assert_eq!(waiting["authority"]["state"], "expired");
        assert_eq!(waiting["authority"]["reauthorizationRequired"], true);
        assert_eq!(
            workspace(&api, &headers, &id).await["workspaceId"],
            WORKSPACE_ID
        );
        let generation = acquire(&api, &headers, &id, "web").await;
        let renewed = ok(
            &api,
            &headers,
            "POST",
            &format!("/api/sessions/{id}/environment-transitions/move-o6/reauthorize"),
            json!({"clientId":"web","generation":generation}),
        )
        .await;
        assert_eq!(renewed["authority"]["revision"], 2, "{renewed}");
        let finished = if renewed["transition"]["state"] == "installed" {
            renewed
        } else {
            until_installed(&api, &headers, &id, "move-o6").await
        };
        assert_eq!(finished["transition"]["state"], "installed", "{finished}");
        assert_eq!(
            workspace(&api, &headers, &id).await["workspaceId"],
            TARGET_WORKSPACE_ID
        );
    }
}
