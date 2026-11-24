use super::super::tests::{app, http, identity, input, node};
use super::*;
use crate::db::{Db, Lease};
use pirc_protocol::NodeHttpResponse;
use std::sync::{
    Arc,
    atomic::{AtomicUsize, Ordering},
};

fn setup(
    app: &AppState,
    id: &str,
) -> (
    Preview,
    Confirmation,
    Value,
    (String, String, String, String),
) {
    app.nodes.set_test_node(node(), |_| {
        Ok(NodeHttpResponse {
            status: 404,
            body: None,
        })
    });
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
    let row = super::super::reserve(&db, "alice", id, &input(&db, id)).unwrap();
    let confirmation = Confirmation {
        plan_hash: row.plan_hash.clone(),
        observation_hash: "reviewed".into(),
        client_id: "phone".into(),
        generation: 1,
    };
    let observation = json!({"status":"observed","observationHash":"reviewed","observation":{"policiesMatch":true,"overlap":false,"sourceResource":{"state":"observed"},"targetResource":{"state":"observed"},"activity":{"fenced":false,"pendingRecords":false},"nodeRunnerEpoch":777,"nodeEvidenceHash":"a".repeat(64)}});
    let mapping = receipts::access_at(app, &db, &identity(), &row).unwrap();
    (row, confirmation, observation, mapping)
}
fn count(db: &Connection) -> i64 {
    db.query_row(
        "SELECT count(*) FROM conversation_transition_acceptances",
        [],
        |r| r.get(0),
    )
    .unwrap()
}
fn receipt(intent: Value) -> NodeHttpResponse {
    NodeHttpResponse {
        status: 200,
        body: Some(
            json!({"transition":{"intent":intent,"state":"fenced","revocationConfirmed":false,"targetInstalled":false,"private":"not exposed"}}),
        ),
    }
}
#[tokio::test]
async fn committed_intent_precedes_the_only_post_and_duplicates_only_read() {
    let (app, _dir, id) = app();
    let (row, c, o, m) = setup(&app, &id);
    let original = app.db.lock().get_session(&id).unwrap();
    let (s, duplicate) = reserve(
        &app,
        &identity(),
        &row,
        &c,
        &o,
        &m,
        app.nodes.connection("node").unwrap(),
    )
    .unwrap();
    assert!(!duplicate);
    assert_eq!(s.state, "accepted");
    assert_eq!(
        receipts::require_open(&app.db.lock(), &id)
            .unwrap_err()
            .code,
        "environment_transition_pending"
    );
    assert_eq!(
        crate::conversation_bindings::commands::receive(
            &app.db.lock(),
            &original,
            "alice",
            "new-work",
            &json!({"type":"prompt","message":"must not start"}),
            Some(&original.binding)
        )
        .unwrap_err()
        .code,
        "environment_transition_pending"
    );
    assert!(app.db.lock().get_command("new-work").is_err());
    let posts = Arc::new(AtomicUsize::new(0));
    let seen = posts.clone();
    let db = app.db.clone();
    let session = id.clone();
    app.nodes.set_test_node(node(), move |r| {
        assert_eq!(r.method, HttpMethod::Post);
        assert_eq!(r.url, "/api/sessions/Private/execution-fences");
        let db = db.lock();
        assert_eq!(
            saved(&db, "alice", &session, "move-1")
                .unwrap()
                .unwrap()
                .state,
            "outcome_unknown"
        );
        assert!(receipts::require_open(&db, &session).is_err());
        seen.fetch_add(1, Ordering::SeqCst);
        Ok(receipt(r.payload.unwrap()["intent"].clone()))
    });
    let connection = app.nodes.connection("node").unwrap();
    let result = dispatch_once(&app, &identity(), &id, &row.operation_id, connection)
        .await
        .unwrap();
    assert_eq!(result["transition"]["state"], "node_fenced");
    assert_eq!(result["transition"]["revocationConfirmed"], false);
    assert!(!result.to_string().contains("private"));
    assert!(
        reserve(
            &app,
            &identity(),
            &row,
            &c,
            &o,
            &m,
            app.nodes.connection("node").unwrap()
        )
        .unwrap()
        .1
    );
    dispatch_once(&app, &identity(), &id, &row.operation_id, connection)
        .await
        .unwrap();
    assert_eq!(posts.load(Ordering::SeqCst), 1);
    assert_eq!(
        app.db.lock().get_session(&id).unwrap().binding,
        original.binding
    );
    let peer = app
        .db
        .lock()
        .create_session("node:repo", "node://node/peer", "node", "Peer", "alice")
        .unwrap();
    receipts::require_open(&app.db.lock(), &peer.id).unwrap();
    crate::conversation_bindings::commands::receive(
        &app.db.lock(),
        &original,
        "alice",
        "stop",
        &json!({"type":"stop"}),
        None,
    )
    .unwrap();
}
#[tokio::test]
async fn unknown_post_survives_restart_target_deletion_and_read_only_recovery() {
    let (app, dir, id) = app();
    let (row, c, o, m) = setup(&app, &id);
    reserve(
        &app,
        &identity(),
        &row,
        &c,
        &o,
        &m,
        app.nodes.connection("node").unwrap(),
    )
    .unwrap();
    let intent = frozen(&app.db.lock(), "alice", &id, "move-1")
        .unwrap()
        .intent;
    let posts = Arc::new(AtomicUsize::new(0));
    let calls = posts.clone();
    app.nodes.set_test_node(node(), move |r| {
        assert_eq!(r.method, HttpMethod::Post);
        calls.fetch_add(1, Ordering::SeqCst);
        Err(ApiError::new(
            503,
            "lost_response",
            "Node may have accepted",
        ))
    });
    let result = dispatch_once(
        &app,
        &identity(),
        &id,
        "move-1",
        app.nodes.connection("node").unwrap(),
    )
    .await
    .unwrap();
    assert_eq!(result["transition"]["state"], "outcome_unknown");
    let path = dir.path().join("reopened.sqlite");
    {
        let db = app.db.lock();
        db.execute("VACUUM INTO ?", [path.to_str().unwrap()])
            .unwrap();
    }
    let reopened = Db::open(&path).unwrap();
    assert_eq!(
        saved(&reopened.lock(), "alice", &id, "move-1")
            .unwrap()
            .unwrap()
            .state,
        "outcome_unknown"
    );
    assert!(receipts::require_open(&reopened.lock(), &id).is_err());
    app.db
        .lock()
        .execute("DELETE FROM workspaces WHERE id='node:target'", [])
        .unwrap();
    assert!(super::super::read(&app.db.lock(), "alice", &id, "move-1").is_err());
    app.nodes.set_test_node(node(), move |r| {
        assert_eq!(r.method, HttpMethod::Get);
        Ok(receipt(intent.clone()))
    });
    assert_eq!(
        reconcile(&app, &identity(), &id, "move-1")
            .await
            .unwrap()
            .unwrap()["transition"]["state"],
        "node_fenced"
    );
    assert_eq!(posts.load(Ordering::SeqCst), 1);
    let (device, token) = app.devices.create("alice", "Android").unwrap();
    let route = format!("/api/sessions/{id}/environment-transitions/receipts/move-1");
    let environment = format!("/api/sessions/{id}/environment");
    let native_environment = http(&app, &environment, None, Some(&token)).await;
    assert_eq!(native_environment.0, 200);
    assert_eq!(
        native_environment.1["activeTransition"]["operationId"],
        "move-1"
    );
    assert_eq!(
        native_environment.1["activeTransition"]["state"],
        "node_fenced"
    );
    assert!(!native_environment.1.to_string().contains("frozenJson"));
    assert_eq!(
        native_environment,
        http(&app, &environment, None, None).await
    );
    let web = http(&app, &route, None, None).await;
    let native = http(&app, &route, None, Some(&token)).await;
    assert_eq!(web.0, 200);
    assert_eq!(web, native);
    assert_eq!(web.1["transition"]["state"], "node_fenced");
    let retry = format!("/api/sessions/{id}/environment-transitions/previews/move-1/confirm");
    let web_retry = http(&app, &retry, Some(serde_json::to_value(&c).unwrap()), None).await;
    let native_retry = http(
        &app,
        &retry,
        Some(serde_json::to_value(&c).unwrap()),
        Some(&token),
    )
    .await;
    assert_eq!(web_retry.0, 200);
    assert_eq!(web_retry, native_retry);
    let mut changed = serde_json::to_value(&c).unwrap();
    changed["observationHash"] = json!("changed");
    assert_eq!(http(&app, &retry, Some(changed), None).await.0, 409);
    app.devices.revoke("alice", &device.id).unwrap();
    assert_eq!(http(&app, &route, None, Some(&token)).await.0, 401);
}
#[tokio::test]
async fn missing_receipt_and_replacement_connection_never_clear_or_resubmit() {
    let (app, _dir, id) = app();
    let (row, c, o, m) = setup(&app, &id);
    reserve(
        &app,
        &identity(),
        &row,
        &c,
        &o,
        &m,
        app.nodes.connection("node").unwrap(),
    )
    .unwrap();
    app.nodes.set_test_node(node(), |r| {
        assert_eq!(r.method, HttpMethod::Get);
        Ok(NodeHttpResponse {
            status: 404,
            body: None,
        })
    });
    let missing = reconcile(&app, &identity(), &id, "move-1")
        .await
        .unwrap()
        .unwrap();
    assert_eq!(missing["transition"]["state"], "accepted");
    assert_eq!(missing["reconciliationState"], "receipt_unavailable");
    let original = app.nodes.connection("node").unwrap();
    let nodes = app.nodes.clone();
    app.nodes
        .set_test_node(node(), |_| panic!("stale connection must not dispatch"));
    assert!(
        dispatch_once(&app, &identity(), &id, "move-1", original)
            .await
            .is_err()
    );
    let intent = frozen(&app.db.lock(), "alice", &id, "move-1")
        .unwrap()
        .intent;
    app.nodes.set_test_node(node(), move |r| {
        assert_eq!(r.method, HttpMethod::Get);
        nodes.set_test_node(node(), |_| {
            Ok(NodeHttpResponse {
                status: 404,
                body: None,
            })
        });
        Ok(receipt(intent.clone()))
    });
    assert_eq!(
        reconcile(&app, &identity(), &id, "move-1")
            .await
            .unwrap()
            .unwrap()["transition"]["state"],
        "accepted"
    );
    assert!(receipts::require_open(&app.db.lock(), &id).is_err());
}
#[test]
fn stale_review_lease_and_failed_commit_never_accept() {
    let (app, _dir, id) = app();
    let (row, mut c, mut o, m) = setup(&app, &id);
    c.generation = 2;
    assert!(
        reserve(
            &app,
            &identity(),
            &row,
            &c,
            &o,
            &m,
            app.nodes.connection("node").unwrap()
        )
        .is_err()
    );
    c.generation = 1;
    o["observationHash"] = json!("changed");
    assert_eq!(
        reserve(
            &app,
            &identity(),
            &row,
            &c,
            &o,
            &m,
            app.nodes.connection("node").unwrap()
        )
        .unwrap_err()
        .code,
        "transition_review_changed"
    );
    o["observationHash"] = json!("reviewed");
    app.db.lock().execute_batch("CREATE TRIGGER refuse_accept BEFORE INSERT ON conversation_transition_acceptances BEGIN SELECT RAISE(ABORT,'disk full'); END;").unwrap();
    assert!(
        reserve(
            &app,
            &identity(),
            &row,
            &c,
            &o,
            &m,
            app.nodes.connection("node").unwrap()
        )
        .is_err()
    );
    assert_eq!(count(&app.db.lock()), 0);
    receipts::require_open(&app.db.lock(), &id).unwrap();
}
#[test]
fn concurrent_acceptance_has_one_identity_and_cannot_reopen_or_change_intent() {
    let (app, _dir, id) = app();
    let (row, c, o, m) = setup(&app, &id);
    let results = std::thread::scope(|s| {
        (0..4)
            .map(|_| {
                s.spawn(|| {
                    reserve(
                        &app,
                        &identity(),
                        &row,
                        &c,
                        &o,
                        &m,
                        app.nodes.connection("node").unwrap(),
                    )
                    .unwrap()
                    .1
                })
            })
            .collect::<Vec<_>>()
            .into_iter()
            .map(|t| t.join().unwrap())
            .collect::<Vec<_>>()
    });
    assert_eq!(results.iter().filter(|&&dup| !dup).count(), 1);
    assert_eq!(count(&app.db.lock()), 1);
    let changed = Confirmation {
        observation_hash: "other".into(),
        ..c
    };
    assert_eq!(
        reserve(
            &app,
            &identity(),
            &row,
            &changed,
            &o,
            &m,
            app.nodes.connection("node").unwrap()
        )
        .unwrap_err()
        .code,
        "conflict"
    );
    let db = app.db.lock();
    assert!(
        db.execute(
            "UPDATE conversation_transition_acceptances SET frozen_json='{}'",
            []
        )
        .is_err()
    );
    assert!(
        db.execute(
            "UPDATE conversation_transition_acceptances SET state='deleted',frozen_json=NULL",
            []
        )
        .is_err()
    );
    db.execute(
        "UPDATE conversation_transition_acceptances SET state='outcome_unknown'",
        [],
    )
    .unwrap();
    assert!(
        db.execute(
            "UPDATE conversation_transition_acceptances SET state='accepted'",
            []
        )
        .is_err()
    );
    assert!(
        db.execute("DELETE FROM conversation_transition_acceptances", [])
            .is_err()
    );
}
#[tokio::test]
async fn mismatched_node_intent_and_revoked_device_keep_unknown_fence() {
    let (app, _dir, id) = app();
    let (row, c, o, m) = setup(&app, &id);
    reserve(
        &app,
        &identity(),
        &row,
        &c,
        &o,
        &m,
        app.nodes.connection("node").unwrap(),
    )
    .unwrap();
    let mut intent = frozen(&app.db.lock(), "alice", &id, "move-1")
        .unwrap()
        .intent;
    intent["preflight"]["evidenceHash"] = json!("b".repeat(64));
    app.nodes
        .set_test_node(node(), move |_| Ok(receipt(intent.clone())));
    assert_eq!(
        dispatch_once(
            &app,
            &identity(),
            &id,
            "move-1",
            app.nodes.connection("node").unwrap()
        )
        .await
        .unwrap_err()
        .code,
        "invalid_transition_receipt"
    );
    assert_eq!(
        saved(&app.db.lock(), "alice", &id, "move-1")
            .unwrap()
            .unwrap()
            .state,
        "outcome_unknown"
    );
    let intent = frozen(&app.db.lock(), "alice", &id, "move-1")
        .unwrap()
        .intent;
    let (device, _) = app.devices.create("alice", "Phone").unwrap();
    let devices = app.devices.clone();
    let revoked = device.id.clone();
    let mut caller = identity();
    caller.device_id = Some(device.id);
    app.nodes.set_test_node(node(), move |_| {
        devices.revoke("alice", &revoked).unwrap();
        Ok(receipt(intent.clone()))
    });
    assert_eq!(
        reconcile(&app, &caller, &id, "move-1")
            .await
            .unwrap_err()
            .status,
        401
    );
    assert_eq!(
        saved(&app.db.lock(), "alice", &id, "move-1")
            .unwrap()
            .unwrap()
            .state,
        "outcome_unknown"
    );
}
#[tokio::test]
async fn public_confirmation_is_gated_and_never_records_or_dispatches() {
    let (app, _dir, id) = app();
    let (_row, c, _o, _m) = setup(&app, &id);
    app.nodes
        .set_test_node(node(), |_| panic!("public confirmation must stay disabled"));
    let result = http(
        &app,
        &format!("/api/sessions/{id}/environment-transitions/previews/move-1/confirm"),
        Some(serde_json::to_value(c).unwrap()),
        None,
    )
    .await;
    assert_eq!(result.0, 409);
    assert_eq!(
        result.1["error"]["code"],
        "transition_coordinator_unavailable"
    );
    assert_eq!(count(&app.db.lock()), 0);
}

#[tokio::test]
async fn changed_policy_and_control_before_first_dispatch_cannot_send() {
    for change_policy in [true, false] {
        let (app, _dir, id) = app();
        let (row, c, o, m) = setup(&app, &id);
        let connection = app.nodes.connection("node").unwrap();
        reserve(&app, &identity(), &row, &c, &o, &m, connection).unwrap();
        if change_policy {
            app.db
                .lock()
                .patch_workspace_capabilities(
                    "node:target",
                    &serde_json::from_value::<crate::db::CapabilitiesPatch>(
                        json!({"web_search":false}),
                    )
                    .unwrap(),
                )
                .unwrap();
        } else {
            app.db
                .lock()
                .mirror_lease(
                    &id,
                    &Lease {
                        client_id: "other-device".into(),
                        generation: 2,
                        expires_at: now_ms() + 60000,
                    },
                    "alice",
                    false,
                )
                .unwrap();
        }
        assert!(
            dispatch_once(&app, &identity(), &id, "move-1", connection)
                .await
                .is_err()
        );
        assert_eq!(
            saved(&app.db.lock(), "alice", &id, "move-1")
                .unwrap()
                .unwrap()
                .state,
            "accepted"
        );
        assert!(receipts::require_open(&app.db.lock(), &id).is_err());
    }
}

#[tokio::test]
async fn failed_pre_send_and_receipt_commits_preserve_unknown_outcome() {
    for fail_before_send in [true, false] {
        let (app, _dir, id) = app();
        let (row, c, o, m) = setup(&app, &id);
        reserve(
            &app,
            &identity(),
            &row,
            &c,
            &o,
            &m,
            app.nodes.connection("node").unwrap(),
        )
        .unwrap();
        app.nodes.set_test_node(node(), move |r| {
            assert!(
                !fail_before_send,
                "A failed journal update must never reach Node"
            );
            Ok(receipt(r.payload.unwrap()["intent"].clone()))
        });
        app.db.lock().execute_batch(if fail_before_send {
            "CREATE TRIGGER fail_dispatch BEFORE UPDATE OF state ON conversation_transition_acceptances WHEN NEW.state='outcome_unknown' BEGIN SELECT RAISE(ABORT,'disk full'); END;"
        }else{
            "CREATE TRIGGER fail_receipt BEFORE INSERT ON conversation_node_fences BEGIN SELECT RAISE(ABORT,'disk full'); END;"
        }).unwrap();
        assert!(
            dispatch_once(
                &app,
                &identity(),
                &id,
                "move-1",
                app.nodes.connection("node").unwrap()
            )
            .await
            .is_err()
        );
        let db = app.db.lock();
        assert_eq!(
            saved(&db, "alice", &id, "move-1").unwrap().unwrap().state,
            if fail_before_send {
                "accepted"
            } else {
                "outcome_unknown"
            }
        );
        assert_eq!(
            db.query_row("SELECT count(*) FROM conversation_node_fences", [], |r| r
                .get::<_, i64>(
                0
            ))
            .unwrap(),
            0
        );
        assert!(receipts::require_open(&db, &id).is_err());
    }
}
