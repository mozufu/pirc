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
}
const DIGEST: &str = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";
fn receipt(f: &Fake, payload: &Value) -> Value {
    let status = if f.unproven { "unproven" } else { "confirmed" };
    let installed = f.state == "installed";
    let target = if f.wrong_target {
        json!("elsewhere")
    } else {
        payload["targetWorkspaceId"].clone()
    };
    json!({"transition":{"intent":f.intent,"state":f.state,"targetInstalled":installed,
        "revocationConfirmed":installed && !f.unproven,
        "revocation":if f.state=="supervisor_drained"{json!({"status":status,"digest":DIGEST,"itemsTotal":1,"confirmsContainment":false,
            "items":[{"kind":"platform_containment","id":"Private","reason":"descendants_not_contained","acknowledgeable":true}]})}else{Value::Null},
        "installation":if installed{json!({"generation":2,"fromWorkspaceId":"repo","toWorkspaceId":target,"revocation":status,"environmentEvent":"pending"})}else{Value::Null},
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
        let step = r.url.rsplit('/').next().unwrap_or_default().to_owned();
        f.calls.push(step.clone());
        match step.as_str() {
            "execution-fences" => {
                f.intent = payload["intent"].clone();
                f.state = "fenced";
            }
            "drain" if f.state == "fenced" => f.state = "supervisor_drained",
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
            }
            "release" if f.state != "installed" => f.state = "released",
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
        json!([{"kind":"platform_containment","reason":"descendants_not_contained","acknowledgeable":true}])
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
