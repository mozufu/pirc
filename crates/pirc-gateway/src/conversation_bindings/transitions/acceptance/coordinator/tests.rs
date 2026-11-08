use super::super::super::tests::{app, identity, input, node};
use super::*;
use crate::db::Lease;
use std::sync::{Arc, Mutex};

/// A Node stand-in that keeps one fence's state, like Node schema 2032.
#[derive(Default)]
struct Fake {
    intent: Value,
    state: &'static str,
    unproven: bool,
    acknowledged: bool,
    wrong_target: bool,
    calls: Vec<String>,
    payloads: Vec<(String, Value)>,
    release_pending: bool,
    cancel_requested: bool,
    installed_target: Value,
}
const DIGEST: &str = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";
fn receipt(f: &Fake, payload: &Value) -> Value {
    let status = if f.unproven { "unproven" } else { "confirmed" };
    let installed = f.state == "installed";
    let target = if f.wrong_target {
        json!("elsewhere")
    } else if payload["targetWorkspaceId"].is_null() {
        f.installed_target.clone()
    } else {
        payload["targetWorkspaceId"].clone()
    };
    json!({"transition":{"intent":f.intent,"state":f.state,"targetInstalled":installed,
        "revocationConfirmed":installed && !f.unproven,
        "revocation":if f.state=="supervisor_drained"{json!({"status":status,"digest":DIGEST,"itemsTotal":1,"confirmsContainment":false,
            "items":[{"kind":"platform_containment","id":"Private","reason":"descendants_not_contained","acknowledgeable":true}]})}else{Value::Null},
        "installation":if installed{json!({"generation":2,"fromWorkspaceId":"repo","toWorkspaceId":target,"revocation":status,"environmentEvent":"pending"})}else{Value::Null},
        "cancellation":if f.cancel_requested{json!({"requestedAt":1,"pendingReason":if f.release_pending{json!("resources_unresolved")}else{Value::Null}})}else{Value::Null},
        "private":"/private/node/path"}})
}
fn ok(body: Value) -> ApiResult<NodeHttpResponse> {
    Ok(NodeHttpResponse {
        status: 200,
        body: Some(body),
    })
}
fn fake(app: &AppState, unproven: bool) -> Arc<Mutex<Fake>> {
    let state = Arc::new(Mutex::new(Fake {
        state: "none",
        unproven,
        ..Fake::default()
    }));
    let shared = state.clone();
    app.nodes.set_test_node(node(), move |r| {
        let mut f = shared.lock().unwrap();
        let payload = r.payload.clone().unwrap_or(Value::Null);
        if r.url.contains("/evaluations/") {
            f.calls.push(format!("evaluation {}", r.url.rsplit('/').next().unwrap_or_default()));
            return ok(json!({"evaluation":{"evaluationId":"ev-0123","digest":DIGEST,"status":"unproven","itemsTotal":2,
                "items":[{"kind":"host_command","id":"private-run","reason":"host_effects_may_survive","acknowledgeable":true,"inherited":true,"generation":1}],
                "next":"1"}}));
        }
        if r.method == HttpMethod::Get {
            // Read-only refresh: not a recorded step.
            return ok(receipt(&f, &Value::Null));
        }
        let step = r.url.rsplit('/').next().unwrap_or_default().to_owned();
        f.calls.push(step.clone());
        f.payloads.push((step.clone(), payload.clone()));
        match step.as_str() {
            "execution-fences" => {
                f.intent = payload["intent"].clone();
                f.state = "fenced";
            }
            "drain" if f.state == "fenced" => f.state = "supervisor_drained",
            "drain" if f.cancel_requested && !f.release_pending && f.state == "supervisor_drained" => {
                f.state = "released"
            }
            "acknowledge" => {
                if payload["digest"] != DIGEST {
                    return Ok(NodeHttpResponse {
                        status: 409,
                        body: Some(json!({"error":{"code":"revocation_digest_changed","message":"changed","details":{"digest":DIGEST}}})),
                    });
                }
                f.acknowledged = true;
            }
            "install" if f.state == "supervisor_drained" => {
                if f.unproven && !f.acknowledged {
                    return Ok(NodeHttpResponse {
                        status: 409,
                        body: Some(json!({"error":{"code":"revocation_unconfirmed","message":"no","details":{"status":"unproven","digest":DIGEST}}})),
                    });
                }
                f.state = "installed";
                f.installed_target = payload["targetWorkspaceId"].clone();
            }
            "release" if f.state != "installed" => {
                f.cancel_requested = true;
                if !f.release_pending {
                    f.state = "released";
                }
            }
            _ => {}
        }
        ok(receipt(&f, &payload))
    });
    state
}
/// An accepted transition with its Node fence, from `node:repo` to `node:target`.
async fn fenced(app: &AppState, id: &str, unproven: bool) -> Arc<Mutex<Fake>> {
    let state = fake(app, unproven);
    let row = {
        let db = app.db.lock();
        db.mirror_lease(
            id,
            &Lease {
                client_id: "phone".into(),
                generation: 1,
                expires_at: now_ms() + 60000,
            },
            "alice",
            false,
        )
        .unwrap();
        super::super::super::reserve(&db, "alice", id, &input(&db, id)).unwrap()
    };
    let confirmation = Confirmation {
        plan_hash: row.plan_hash.clone(),
        observation_hash: "reviewed".into(),
        client_id: "phone".into(),
        generation: 1,
    };
    let observation = json!({"status":"observed","observationHash":"reviewed","observation":{"policiesMatch":true,"overlap":false,"sourceResource":{"state":"observed"},"targetResource":{"state":"observed"},"activity":{"fenced":false,"pendingRecords":false},"nodeRunnerEpoch":777,"nodeEvidenceHash":"a".repeat(64)}});
    let mapping = receipts::access_at(app, &app.db.lock(), &identity(), &row).unwrap();
    let connection = app.nodes.connection("node").unwrap();
    reserve(
        app,
        &identity(),
        &row,
        &confirmation,
        &observation,
        &mapping,
        connection,
    )
    .unwrap();
    let result = dispatch_once(app, &identity(), id, "move-1", connection)
        .await
        .unwrap();
    assert_eq!(result["transition"]["state"], "node_fenced", "{result}");
    state
}
fn lease() -> Option<(String, i64)> {
    Some(("phone".into(), 1))
}
fn workspace(app: &AppState, id: &str) -> String {
    app.db.lock().get_session(id).unwrap().workspace_id
}

#[tokio::test]
async fn a_confirmed_drain_installs_and_moves_the_binding_once() {
    let (app, _dir, id) = app();
    let node = fenced(&app, &id, false).await;
    let before = app.db.lock().get_session(&id).unwrap().binding;
    let result = advance(&app, &identity(), &id, "move-1", lease())
        .await
        .unwrap();
    assert_eq!(result["transition"]["state"], "installed", "{result}");
    assert_eq!(result["transition"]["targetInstalled"], true);
    assert_eq!(result["transition"]["revocationConfirmed"], true);
    assert_eq!(
        result["progress"]["installation"]["revocation"],
        "confirmed"
    );
    assert!(!result.to_string().contains("Private") && !result.to_string().contains("/private"));
    assert_eq!(workspace(&app, &id), "node:target");
    let after = app.db.lock().get_session(&id).unwrap().binding;
    assert_ne!(after, before);
    receipts::require_open(&app.db.lock(), &id).unwrap();
    assert!(
        super::super::super::active(&app.db.lock(), "alice", &id)
            .unwrap()
            .is_none()
    );
    // Later calls only read: no second drain or installation.
    advance(&app, &identity(), &id, "move-1", lease())
        .await
        .unwrap();
    let calls = node.lock().unwrap().calls.clone();
    assert_eq!(calls, ["execution-fences", "drain", "install"]);
    let late = cancel(&app, &identity(), &id, "move-1", ("phone".into(), 1)).await;
    assert_eq!(late.unwrap_err().code, "transition_installed");
}

#[tokio::test]
async fn unproven_evidence_waits_for_an_acknowledgement_of_its_digest() {
    let (app, _dir, id) = app();
    let node = fenced(&app, &id, true).await;
    let waiting = advance(&app, &identity(), &id, "move-1", lease())
        .await
        .unwrap();
    assert_eq!(waiting["transition"]["state"], "node_fenced");
    let revocation = &waiting["progress"]["revocation"];
    assert_eq!(revocation["status"], "unproven");
    assert_eq!(revocation["digest"], DIGEST);
    assert_eq!(
        revocation["items"],
        json!([{"kind":"platform_containment","reason":"descendants_not_contained","acknowledgeable":true,"inherited":false,"generation":null}])
    );
    assert_eq!(workspace(&app, &id), "node:repo");
    receipts::require_open(&app.db.lock(), &id).unwrap_err();
    let wrong = acknowledge(
        &app,
        &identity(),
        &id,
        "move-1",
        Acknowledge {
            digest: "e".repeat(64),
            evaluation_id: None,
            client_id: "phone".into(),
            generation: 1,
        },
    )
    .await;
    assert_eq!(wrong.unwrap_err().code, "revocation_digest_changed");
    let installed = acknowledge(
        &app,
        &identity(),
        &id,
        "move-1",
        Acknowledge {
            digest: DIGEST.into(),
            evaluation_id: None,
            client_id: "phone".into(),
            generation: 1,
        },
    )
    .await
    .unwrap();
    assert_eq!(installed["transition"]["state"], "installed");
    assert_eq!(installed["transition"]["revocationConfirmed"], false);
    assert_eq!(
        installed["progress"]["installation"]["revocation"],
        "unproven"
    );
    assert_eq!(workspace(&app, &id), "node:target");
    assert!(node.lock().unwrap().acknowledged);
}

#[tokio::test]
async fn cancel_before_dispatch_or_after_the_fence_keeps_the_original_binding() {
    let (app, _dir, id) = app();
    let node = fenced(&app, &id, true).await;
    advance(&app, &identity(), &id, "move-1", lease())
        .await
        .unwrap();
    let released = cancel(&app, &identity(), &id, "move-1", ("phone".into(), 1))
        .await
        .unwrap();
    assert_eq!(released["transition"]["state"], "released");
    assert_eq!(workspace(&app, &id), "node:repo");
    receipts::require_open(&app.db.lock(), &id).unwrap();
    // Further steps only read the ended transition.
    advance(&app, &identity(), &id, "move-1", lease())
        .await
        .unwrap();
    assert_eq!(
        node.lock().unwrap().calls,
        ["execution-fences", "drain", "install", "release"]
    );
}

#[tokio::test]
async fn steps_need_current_control_and_a_receipt_for_the_reviewed_target() {
    let (app, _dir, id) = app();
    let node = fenced(&app, &id, false).await;
    let stale = advance(&app, &identity(), &id, "move-1", Some(("tablet".into(), 9))).await;
    assert!(stale.is_err());
    assert_eq!(node.lock().unwrap().calls, ["execution-fences"]);
    node.lock().unwrap().wrong_target = true;
    let invalid = advance(&app, &identity(), &id, "move-1", lease()).await;
    assert_eq!(invalid.unwrap_err().code, "invalid_transition_receipt");
    assert_eq!(workspace(&app, &id), "node:repo");
    assert_eq!(
        status(&app, &identity(), &id, "move-1").unwrap()["transition"]["state"],
        "node_fenced"
    );
}

#[tokio::test]
async fn an_undispatched_acceptance_is_cancelled_without_any_node_request() {
    let (app, _dir, id) = app();
    let node = fake(&app, false);
    let row = {
        let db = app.db.lock();
        db.mirror_lease(
            &id,
            &Lease {
                client_id: "phone".into(),
                generation: 1,
                expires_at: now_ms() + 60000,
            },
            "alice",
            false,
        )
        .unwrap();
        super::super::super::reserve(&db, "alice", &id, &input(&db, &id)).unwrap()
    };
    let confirmation = Confirmation {
        plan_hash: row.plan_hash.clone(),
        observation_hash: "reviewed".into(),
        client_id: "phone".into(),
        generation: 1,
    };
    let observation = json!({"status":"observed","observationHash":"reviewed","observation":{"policiesMatch":true,"overlap":false,"sourceResource":{"state":"observed"},"targetResource":{"state":"observed"},"activity":{"fenced":false,"pendingRecords":false},"nodeRunnerEpoch":777,"nodeEvidenceHash":"a".repeat(64)}});
    let mapping = receipts::access_at(&app, &app.db.lock(), &identity(), &row).unwrap();
    reserve(
        &app,
        &identity(),
        &row,
        &confirmation,
        &observation,
        &mapping,
        app.nodes.connection("node").unwrap(),
    )
    .unwrap();
    let released = cancel(&app, &identity(), &id, "move-1", ("phone".into(), 1))
        .await
        .unwrap();
    assert_eq!(released["transition"]["state"], "released");
    // A delayed dispatch can no longer send: its accepted row is gone.
    let after = dispatch_once(
        &app,
        &identity(),
        &id,
        "move-1",
        app.nodes.connection("node").unwrap(),
    )
    .await
    .unwrap();
    assert_eq!(after["transition"]["state"], "released");
    assert!(node.lock().unwrap().calls.is_empty());
    receipts::require_open(&app.db.lock(), &id).unwrap();
}

async fn until_state(app: &AppState, id: &str, wanted: &str) -> bool {
    for _ in 0..100 {
        if status(app, &identity(), id, "move-1").unwrap()["transition"]["state"] == wanted {
            return true;
        }
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }
    false
}
#[tokio::test]
async fn the_recovery_sweep_installs_only_already_authorized_steps() {
    let (app, _dir, id) = app();
    let node = fenced(&app, &id, false).await;
    start(&app);
    assert!(until_state(&app, &id, "installed").await);
    assert_eq!(workspace(&app, &id), "node:target");
    assert_eq!(
        node.lock().unwrap().calls,
        ["execution-fences", "drain", "install"]
    );
}
#[tokio::test]
async fn the_recovery_sweep_never_acknowledges_unproven_evidence() {
    let (app, _dir, id) = app();
    let node = fenced(&app, &id, true).await;
    start(&app);
    for _ in 0..100 {
        if node.lock().unwrap().calls.len() >= 3 {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }
    let calls = node.lock().unwrap().calls.clone();
    assert_eq!(calls, ["execution-fences", "drain", "install"]);
    assert!(!node.lock().unwrap().acknowledged);
    assert_eq!(
        status(&app, &identity(), &id, "move-1").unwrap()["transition"]["state"],
        "node_fenced"
    );
    assert_eq!(workspace(&app, &id), "node:repo");
}

#[tokio::test]
async fn the_read_only_receipt_shows_progress_without_control_or_node_calls() {
    let (app, _dir, id) = app();
    let node = fenced(&app, &id, true).await;
    advance(&app, &identity(), &id, "move-1", lease())
        .await
        .unwrap();
    let calls = node.lock().unwrap().calls.len();
    // Another device takes control; the first one can still read everything.
    app.db
        .lock()
        .mirror_lease(
            &id,
            &Lease {
                client_id: "tablet".into(),
                generation: 2,
                expires_at: now_ms() + 60000,
            },
            "alice",
            false,
        )
        .unwrap();
    let read = status_if_present(&app, &identity(), &id, "move-1")
        .unwrap()
        .unwrap();
    assert_eq!(read["transition"]["state"], "node_fenced");
    assert_eq!(read["progress"]["revocation"]["status"], "unproven");
    assert_eq!(read["progress"]["revocation"]["digest"], DIGEST);
    assert!(read["progress"]["observedAt"].is_i64());
    assert_eq!(node.lock().unwrap().calls.len(), calls);
}

#[tokio::test]
async fn a_finished_switch_stays_discoverable_after_it_leaves_active_status() {
    use super::super::super::tests::http;
    let (app, _dir, id) = app();
    fenced(&app, &id, false).await;
    advance(&app, &identity(), &id, "move-1", lease())
        .await
        .unwrap();
    let (status, environment) =
        http(&app, &format!("/api/sessions/{id}/environment"), None, None).await;
    assert_eq!(status, 200, "{environment}");
    assert!(environment["activeTransition"].is_null());
    let last = &environment["lastFinishedTransition"];
    assert_eq!(last["operationId"], "move-1");
    assert_eq!(last["state"], "installed");
    assert_eq!(last["targetWorkspaceId"], "node:target");
    assert_eq!(last["revocationConfirmed"], true);
    let (status, page) = http(
        &app,
        &format!("/api/sessions/{id}/environment-transitions?limit=1"),
        None,
        None,
    )
    .await;
    assert_eq!(status, 200, "{page}");
    assert_eq!(page["transitions"]["items"][0]["operationId"], "move-1");
    let next = page["transitions"]["next"].as_str().unwrap().to_owned();
    let (_, rest) = http(
        &app,
        &format!("/api/sessions/{id}/environment-transitions?limit=1&cursor={next}"),
        None,
        None,
    )
    .await;
    assert_eq!(rest["transitions"]["items"], json!([]));
    assert!(rest["transitions"]["next"].is_null());
    for query in ["limit=0", "limit=101", "cursor=bad", "other=1"] {
        let (status, _) = http(
            &app,
            &format!("/api/sessions/{id}/environment-transitions?{query}"),
            None,
            None,
        )
        .await;
        assert_eq!(status, 400, "{query}");
    }
    assert!(!page.to_string().contains("Private"));
}

#[tokio::test]
async fn active_transitions_name_their_target_and_a_bare_fence_needs_reconciliation() {
    let (app, _dir, id) = app();
    fenced(&app, &id, true).await;
    let active = super::super::super::active(&app.db.lock(), "alice", &id)
        .unwrap()
        .unwrap();
    assert_eq!(active["state"], "node_fenced");
    assert_eq!(active["targetWorkspaceId"], "node:target");
    assert!(active.get("safeActions").is_none());

    // A Node fence recorded without any Gateway acceptance is not consent.
    let (app, _dir, id) = super::super::super::tests::app();
    {
        let db = app.db.lock();
        super::super::super::reserve(&db, "alice", &id, &input(&db, &id)).unwrap();
        db.execute(
            "INSERT INTO conversation_node_fences VALUES('alice','move-1',?1,?2,'fenced',1)",
            params![id, "f".repeat(64)],
        )
        .unwrap();
    }
    let bare = super::super::super::active(&app.db.lock(), "alice", &id)
        .unwrap()
        .unwrap();
    assert_eq!(bare["state"], "reconciliation_required");
    assert_eq!(bare["recoveryReason"], "no_gateway_acceptance");
    assert_eq!(bare["safeActions"], json!(["reconcile"]));
    assert_eq!(bare["targetWorkspaceId"], "node:target");
    let advance = advance(&app, &identity(), &id, "move-1", None).await;
    assert!(advance.is_err());
}

/// An acceptance whose single dispatch never ran, as after a failed confirm.
fn accepted_only(app: &AppState, id: &str) -> Arc<Mutex<Fake>> {
    let node = fake(app, false);
    let row = {
        let db = app.db.lock();
        db.mirror_lease(
            id,
            &Lease {
                client_id: "phone".into(),
                generation: 1,
                expires_at: now_ms() + 60000,
            },
            "alice",
            false,
        )
        .unwrap();
        super::super::super::reserve(&db, "alice", id, &input(&db, id)).unwrap()
    };
    let confirmation = Confirmation {
        plan_hash: row.plan_hash.clone(),
        observation_hash: "reviewed".into(),
        client_id: "phone".into(),
        generation: 1,
    };
    let observation = json!({"status":"observed","observationHash":"reviewed","observation":{"policiesMatch":true,"overlap":false,"sourceResource":{"state":"observed"},"targetResource":{"state":"observed"},"activity":{"fenced":false,"pendingRecords":false},"nodeRunnerEpoch":777,"nodeEvidenceHash":"a".repeat(64)}});
    let mapping = receipts::access_at(app, &app.db.lock(), &identity(), &row).unwrap();
    reserve(
        app,
        &identity(),
        &row,
        &confirmation,
        &observation,
        &mapping,
        app.nodes.connection("node").unwrap(),
    )
    .unwrap();
    node
}
#[tokio::test]
async fn an_undispatched_acceptance_is_sent_once_and_continues() {
    let (app, _dir, id) = app();
    let node = accepted_only(&app, &id);
    let result = advance(&app, &identity(), &id, "move-1", lease())
        .await
        .unwrap();
    assert_eq!(result["transition"]["state"], "installed", "{result}");
    assert_eq!(
        node.lock().unwrap().calls,
        ["execution-fences", "drain", "install"]
    );
}
#[tokio::test]
async fn an_undispatched_acceptance_that_cannot_be_sent_asks_for_review() {
    let (app, _dir, id) = app();
    let node = accepted_only(&app, &id);
    // Control moved on before the dispatch could run.
    app.db
        .lock()
        .mirror_lease(
            &id,
            &Lease {
                client_id: "tablet".into(),
                generation: 2,
                expires_at: now_ms() + 60000,
            },
            "alice",
            false,
        )
        .unwrap();
    let result = advance(&app, &identity(), &id, "move-1", None)
        .await
        .unwrap();
    assert_eq!(result["transition"]["state"], "accepted", "{result}");
    assert_eq!(result["progress"]["stage"], "review_required");
    assert_eq!(result["progress"]["safeActions"], json!(["cancel"]));
    assert!(result["progress"]["waitReason"].is_string());
    assert!(node.lock().unwrap().calls.is_empty());
    let cancelled = cancel(&app, &identity(), &id, "move-1", ("tablet".into(), 2))
        .await
        .unwrap();
    assert_eq!(cancelled["transition"]["state"], "released");
    assert!(node.lock().unwrap().calls.is_empty());
    receipts::require_open(&app.db.lock(), &id).unwrap();
}

#[tokio::test]
async fn missing_transition_objects_have_family_specific_codes() {
    use super::super::super::tests::http;
    let (app, _dir, id) = app();
    fake(&app, false);
    let base = format!("/api/sessions/{id}/environment-transitions");
    let (status, preview) = http(&app, &format!("{base}/previews/nothing"), None, None).await;
    assert_eq!(
        (status, preview["error"]["code"].clone()),
        (404, json!("preview_not_found"))
    );
    let (status, receipt) = http(&app, &format!("{base}/receipts/nothing"), None, None).await;
    assert_eq!(
        (status, receipt["error"]["code"].clone()),
        (404, json!("receipt_not_found"))
    );
    app.db
        .lock()
        .mirror_lease(
            &id,
            &Lease {
                client_id: "phone".into(),
                generation: 1,
                expires_at: now_ms() + 60000,
            },
            "alice",
            false,
        )
        .unwrap();
    let (status, accepted) = http(
        &app,
        &format!("{base}/nothing/advance"),
        Some(json!({"clientId":"phone","generation":1})),
        None,
    )
    .await;
    assert_eq!(
        (status, accepted["error"]["code"].clone()),
        (404, json!("acceptance_not_found"))
    );
}

fn payload(node: &Arc<Mutex<Fake>>, step: &str) -> Value {
    node.lock()
        .unwrap()
        .payloads
        .iter()
        .rev()
        .find(|(s, _)| s == step)
        .map(|(_, p)| p.clone())
        .unwrap_or(Value::Null)
}
fn take_control(app: &AppState, id: &str) {
    app.db
        .lock()
        .mirror_lease(
            id,
            &Lease {
                client_id: "tablet".into(),
                generation: 2,
                expires_at: now_ms() + 60000,
            },
            "alice",
            false,
        )
        .unwrap();
}
#[tokio::test]
async fn operation_authority_finishes_a_switch_after_control_moved_on() {
    let (app, _dir, id) =
        super::super::super::tests::app_with(&[("PIRC_TRANSITION_AUTHORITY_SECONDS", "60")]);
    let node = accepted_only(&app, &id);
    authority::issue(&app.db.lock(), "alice", &id, "move-1", 60).unwrap();
    dispatch_once(
        &app,
        &identity(),
        &id,
        "move-1",
        app.nodes.connection("node").unwrap(),
    )
    .await
    .unwrap();
    // The Node receives only the hash of the authority with its fence.
    let grant = payload(&node, "execution-fences")["operationAuthority"].clone();
    assert_eq!(grant["revision"], 1);
    assert_eq!(grant["tokenHash"].as_str().unwrap().len(), 64);
    assert!(grant.get("token").is_none());
    // Every device closed or another took over: the backend still finishes.
    take_control(&app, &id);
    let result = advance(&app, &identity(), &id, "move-1", None)
        .await
        .unwrap();
    assert_eq!(result["transition"]["state"], "installed", "{result}");
    let install = payload(&node, "install");
    assert_eq!(install["operationAuthority"]["revision"], 1);
    assert!(install["operationAuthority"]["token"].is_string());
    assert!(install.get("clientId").is_none());
    assert_eq!(result["authority"]["state"], "active");
    assert!(
        !result
            .to_string()
            .contains(install["operationAuthority"]["token"].as_str().unwrap())
    );
}
#[tokio::test]
async fn expired_authority_waits_until_the_current_controller_reauthorizes() {
    let (app, _dir, id) =
        super::super::super::tests::app_with(&[("PIRC_TRANSITION_AUTHORITY_SECONDS", "1")]);
    let node = accepted_only(&app, &id);
    authority::issue(&app.db.lock(), "alice", &id, "move-1", 1).unwrap();
    dispatch_once(
        &app,
        &identity(),
        &id,
        "move-1",
        app.nodes.connection("node").unwrap(),
    )
    .await
    .unwrap();
    tokio::time::sleep(std::time::Duration::from_millis(1_100)).await;
    let waiting = advance(&app, &identity(), &id, "move-1", None)
        .await
        .unwrap();
    assert_eq!(waiting["transition"]["state"], "node_fenced", "{waiting}");
    assert_eq!(waiting["authority"]["state"], "expired");
    assert_eq!(waiting["authority"]["reauthorizationRequired"], true);
    assert!(!node.lock().unwrap().calls.contains(&"install".to_owned()));
    // Reauthorization needs the current controller.
    take_control(&app, &id);
    let stranger = reauthorize(&app, &identity(), &id, "move-1", ("phone".into(), 1)).await;
    assert!(stranger.is_err());
    let renewed = reauthorize(&app, &identity(), &id, "move-1", ("tablet".into(), 2))
        .await
        .unwrap();
    assert_eq!(renewed["transition"]["state"], "installed", "{renewed}");
    assert_eq!(payload(&node, "authority")["grant"]["revision"], 2);
    assert_eq!(
        payload(&node, "install")["operationAuthority"]["revision"],
        2
    );
    assert_eq!(renewed["authority"]["revision"], 2);
}
#[tokio::test]
async fn reauthorization_needs_a_configured_policy() {
    let (app, _dir, id) = app();
    accepted_only(&app, &id);
    let refused = reauthorize(&app, &identity(), &id, "move-1", ("phone".into(), 1)).await;
    assert_eq!(refused.unwrap_err().code, "operation_authority_unavailable");
}
#[tokio::test]
async fn reauthorization_refuses_when_the_reviewed_plan_is_gone() {
    let (app, _dir, id) =
        super::super::super::tests::app_with(&[("PIRC_TRANSITION_AUTHORITY_SECONDS", "60")]);
    accepted_only(&app, &id);
    authority::issue(&app.db.lock(), "alice", &id, "move-1", 60).unwrap();
    // A removed review (for example a deleted target) is a material change.
    app.db
        .lock()
        .execute("DELETE FROM conversation_transition_previews", [])
        .unwrap();
    let refused = reauthorize(&app, &identity(), &id, "move-1", ("phone".into(), 1)).await;
    assert_eq!(refused.unwrap_err().code, "plan_changed");
    assert_eq!(
        authority::status(&app.db.lock(), "alice", "move-1").unwrap()["revision"],
        1
    );
}

#[tokio::test]
async fn evaluation_pages_are_relayed_read_only_without_private_ids() {
    use super::super::super::tests::http;
    let (app, _dir, id) = app();
    let node = fenced(&app, &id, true).await;
    let base = format!("/api/sessions/{id}/environment-transitions/move-1/evaluations");
    let (status, page) = http(&app, &format!("{base}/ev-0123?limit=1"), None, None).await;
    assert_eq!(status, 200, "{page}");
    let e = &page["evaluation"];
    assert_eq!(
        (
            e["evaluationId"].clone(),
            e["itemsTotal"].clone(),
            e["next"].clone()
        ),
        (json!("ev-0123"), json!(2), json!("1"))
    );
    assert_eq!(e["items"][0]["kind"], "host_command");
    assert_eq!(e["items"][0]["inherited"], true);
    assert!(!page.to_string().contains("private-run"));
    assert!(
        node.lock()
            .unwrap()
            .calls
            .iter()
            .any(|c| c == "evaluation ev-0123?limit=1")
    );
    for bad in ["not-an-id", "ev-xyz", "ev-0123?other=1"] {
        let (status, _) = http(&app, &format!("{base}/{bad}"), None, None).await;
        assert_eq!(status, 400, "{bad}");
    }
}

#[tokio::test]
async fn a_pending_cancellation_never_installs_and_completes_through_the_drain() {
    let (app, _dir, id) = app();
    let node = fenced(&app, &id, false).await;
    node.lock().unwrap().release_pending = true;
    let pending = cancel(&app, &identity(), &id, "move-1", ("phone".into(), 1))
        .await
        .unwrap();
    assert_eq!(pending["transition"]["state"], "node_fenced", "{pending}");
    assert!(pending["cancellation"]["requestedAt"].is_i64());
    assert_eq!(
        pending["progress"]["cancellation"]["pendingReason"],
        "resources_unresolved"
    );
    // The confirmed revocation would otherwise install; the intent forbids it.
    advance(&app, &identity(), &id, "move-1", None)
        .await
        .unwrap();
    assert!(!node.lock().unwrap().calls.contains(&"install".to_owned()));
    node.lock().unwrap().release_pending = false;
    let done = advance(&app, &identity(), &id, "move-1", None)
        .await
        .unwrap();
    assert_eq!(done["transition"]["state"], "released", "{done}");
    assert_eq!(workspace(&app, &id), "node:repo");
    assert!(!node.lock().unwrap().calls.contains(&"install".to_owned()));
}

#[tokio::test]
async fn client_reported_contract_gaps_are_closed() {
    use super::super::super::tests::http;
    let (app, _dir, id) =
        super::super::super::tests::app_with(&[("PIRC_TRANSITION_AUTHORITY_SECONDS", "60")]);
    fake(&app, false);
    // Paging an evaluation of an operation that was never accepted is a 404.
    let (status, missing) = http(
        &app,
        &format!("/api/sessions/{id}/environment-transitions/nothing/evaluations/ev-0123"),
        None,
        None,
    )
    .await;
    assert_eq!(
        (status, missing["error"]["code"].clone()),
        (404, json!("acceptance_not_found"))
    );
    // Node refusals the clients act on keep their codes (and 403 for a bad token).
    for (status, code) in [
        (403, "operation_authority_invalid"),
        (409, "transition_cancel_requested"),
    ] {
        let error = node_error(&NodeHttpResponse {
            status,
            body: Some(json!({"error":{"code":code,"message":"refused"}})),
        });
        assert_eq!((error.status, error.code), (status, code));
    }
    // A read-only status never moves the authority clock watermark.
    accepted_only(&app, &id);
    authority::issue(&app.db.lock(), "alice", &id, "move-1", 60).unwrap();
    let clock = |app: &AppState| -> Option<i64> {
        app.db
            .lock()
            .query_row(
                "SELECT max_seen_at FROM conversation_authority_clock",
                [],
                |r| r.get(0),
            )
            .optional()
            .unwrap()
    };
    let before = clock(&app);
    status_if_present(&app, &identity(), &id, "move-1").unwrap();
    assert_eq!(clock(&app), before);
}
