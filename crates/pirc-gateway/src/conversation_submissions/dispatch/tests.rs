use super::super::acceptance::tests::{connected, identity, model, prepared, register};
use super::super::tests::{app, call, count, disk_app};
use super::*;
use crate::{
    app::App,
    db::{Db, Lease},
};
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicBool, Ordering},
};

pub(super) async fn ready(on_disk: bool) -> (AppState, tempfile::TempDir, String) {
    let (app, dir) = if on_disk { disk_app() } else { app() };
    model(&app);
    register(&app);
    prepared(&app, false);
    super::super::acceptance::accept_intent(&app, &identity(), "draft-1")
        .await
        .unwrap();
    let row = super::super::acceptance::advance(&app, &identity(), "draft-1")
        .await
        .unwrap();
    app.db
        .lock()
        .mirror_lease(
            &row.session_id,
            &Lease {
                client_id: "phone".into(),
                generation: 1,
                expires_at: now_ms() + 60_000,
            },
            "alice",
            false,
        )
        .unwrap();
    (app, dir, row.session_id)
}
pub(super) fn control() -> Control {
    Control {
        client_id: "phone".into(),
        generation: 1,
    }
}
pub(super) fn evidence(request: &Value, status: &str) -> Value {
    let payload =
        json!({"type":"prompt","message":request["message"],"uploadIds":request["uploadIds"]});
    let hash = payload_hash(
        &json!({"submissionHash":request["submissionHash"],"model":request["model"],"thinking":request["thinking"],"payload":payload}),
    );
    json!({"operationId":"placeholder","sessionId":"session-stable","state":status,"inputHash":hash,"stopRequested":false,"stopConfirmed":false,"command":{"id":request["commandId"],"sessionId":"session-stable","payloadHash":payload_hash(&payload),"payload":payload,"status":status,"result":{"success":status=="accepted"},"error":null}})
}
pub(super) fn operation(app: &AppState) -> String {
    target(&app.db.lock(), "alice", "draft-1").unwrap().creation
}
fn set_node(app: &AppState, result: Value, lost: bool) -> Arc<Mutex<Vec<(HttpMethod, String)>>> {
    let requests = Arc::new(Mutex::new(Vec::new()));
    let record = requests.clone();
    let once = AtomicBool::new(lost);
    app.nodes.set_test_node(connected(), move |r| {
        if r.url.ends_with("/capabilities") {
            return Ok(super::super::acceptance::tests::fake(&r));
        }
        record.lock().unwrap().push((r.method, r.url));
        if r.method == HttpMethod::Post && once.swap(false, Ordering::SeqCst) {
            Err(ApiError::new(
                503,
                "node_timeout",
                "synthetic response loss",
            ))
        } else {
            Ok(pirc_protocol::NodeHttpResponse {
                status: 200,
                body: Some(json!({"admission":result})),
            })
        }
    });
    requests
}
#[tokio::test]
async fn sends_frozen_settings_once_and_queries_after_control_or_mode_changed() {
    let (app, _dir, session) = ready(false).await;
    let expected = specification(&app.db.lock(), "alice", "draft-1").unwrap();
    let mut proof = evidence(&expected.request, "accepted");
    proof["operationId"] = json!(operation(&app));
    let requests = set_node(&app, proof, false);
    let (code, body) = call(
        &app,
        "POST",
        "/api/conversation-submissions/draft-1/dispatch",
        Some("alice"),
        None,
        Some(json!({"clientId":"phone","generation":1})),
    )
    .await;
    assert_eq!(code, 200, "{body}");
    assert_eq!(body["preparation"]["state"], "admitted");
    assert_eq!(
        body["preparation"]["messageAdmission"]["outcome"],
        "admitted"
    );
    assert_eq!(count(&app.db.lock(), "commands"), 1);
    assert!(super::super::require_initial_submission_complete(&app.db.lock(), &session).is_ok());
    app.db.lock().execute("DELETE FROM leases", []).unwrap();
    app.db
        .lock()
        .execute("UPDATE workspaces SET kind='missing-mode'", [])
        .unwrap();
    let (code, body) = call(
        &app,
        "POST",
        "/api/conversation-submissions/draft-1/dispatch",
        Some("alice"),
        None,
        Some(json!({"clientId":"other-device","generation":999})),
    )
    .await;
    assert_eq!(code, 200);
    assert_eq!(body["preparation"]["state"], "admitted");
    assert_eq!(requests.lock().unwrap().len(), 1);
    assert_eq!(
        expected.request["model"],
        json!({"provider":"fake","id":"m"})
    );
    assert_eq!(expected.request["thinking"], "high");
    assert!(app.db.lock().get_lease(&session).unwrap().is_null());
}
#[tokio::test]
async fn lost_response_is_reconciled_read_only_without_lease_refresh_or_resending() {
    let (app, _dir, session) = ready(false).await;
    let expected = specification(&app.db.lock(), "alice", "draft-1").unwrap();
    let mut proof = evidence(&expected.request, "accepted");
    proof["operationId"] = json!(operation(&app));
    let requests = set_node(&app, proof, true);
    let (_, body) = call(
        &app,
        "POST",
        "/api/conversation-submissions/draft-1/dispatch",
        Some("alice"),
        None,
        Some(json!({"clientId":"phone","generation":1})),
    )
    .await;
    assert_eq!(body["preparation"]["state"], "outcome_unknown");
    assert!(super::super::require_initial_submission_complete(&app.db.lock(), &session).is_err());
    app.db.lock().execute("DELETE FROM leases", []).unwrap();
    let (code, body) = call(
        &app,
        "GET",
        "/api/conversation-submissions/draft-1/receipt",
        Some("alice"),
        None,
        None,
    )
    .await;
    assert_eq!(code, 200);
    assert_eq!(body["preparation"]["state"], "admitted");
    let calls = requests.lock().unwrap();
    assert_eq!(
        calls.iter().filter(|(m, _)| *m == HttpMethod::Post).count(),
        1
    );
    assert_eq!(
        calls.iter().filter(|(m, _)| *m == HttpMethod::Get).count(),
        1
    );
    assert!(app.db.lock().get_lease(&session).unwrap().is_null());
}
#[tokio::test]
async fn absent_node_receipt_stays_unknown_and_duplicate_dispatch_never_blindly_replays() {
    let (app, _dir, _session) = ready(false).await;
    let target = target(&app.db.lock(), "alice", "draft-1").unwrap();
    let requests = set_node(
        &app,
        json!({"operationId":target.creation,"sessionId":"session-stable","state":"not_submitted","command":null,"stopRequested":false,"stopConfirmed":false}),
        false,
    );
    for _ in 0..3 {
        let (_, body) = call(
            &app,
            "POST",
            "/api/conversation-submissions/draft-1/dispatch",
            Some("alice"),
            None,
            Some(json!({"clientId":"phone","generation":1})),
        )
        .await;
        assert_eq!(body["preparation"]["state"], "outcome_unknown");
    }
    assert_eq!(
        requests
            .lock()
            .unwrap()
            .iter()
            .filter(|(m, _)| *m == HttpMethod::Post)
            .count(),
        1
    );
    assert_eq!(count(&app.db.lock(), "commands"), 1);
}
#[tokio::test]
async fn independent_connections_reserve_only_one_first_dispatch() {
    let (first, _dir, _session) = ready(true).await;
    let barrier = std::sync::Barrier::new(4);
    let apps = (0..4)
        .map(|_| {
            let app = App::new(
                first.config.clone(),
                Arc::new(Db::open(&first.config.state_dir.join("gateway.sqlite")).unwrap()),
                first.backends.clone(),
                crate::app::test_modes(),
            );
            register(&app);
            app
        })
        .collect::<Vec<_>>();
    let winners = std::thread::scope(|s| {
        apps.iter()
            .map(|app| {
                let b = &barrier;
                s.spawn(move || {
                    b.wait();
                    reserve(app, &identity(), "draft-1", &control())
                        .unwrap()
                        .is_some()
                })
            })
            .collect::<Vec<_>>()
            .into_iter()
            .map(|h| h.join().unwrap())
            .filter(|won| *won)
            .count()
    });
    assert_eq!(winners, 1);
    assert_eq!(count(&first.db.lock(), "commands"), 1);
    assert_eq!(
        count(&first.db.lock(), "conversation_submission_dispatches"),
        1
    );
}
#[tokio::test]
async fn stale_or_missing_authority_does_not_even_reserve_a_command() {
    for variant in 0..3 {
        let (app, _dir, session) = ready(false).await;
        match variant {
            0 => {
                app.db.lock().execute("DELETE FROM leases", []).unwrap();
            }
            1 => {
                app.db
                    .lock()
                    .execute("UPDATE leases SET owner_user='bob'", [])
                    .unwrap();
            }
            _ => {
                app.db
                    .lock()
                    .execute("UPDATE workspaces SET kind='missing-mode'", [])
                    .unwrap();
            }
        }
        assert!(reserve(&app, &identity(), "draft-1", &control()).is_err());
        assert_eq!(count(&app.db.lock(), "commands"), 0);
        assert!(app.db.lock().get_session(&session).is_ok());
    }
}
#[tokio::test]
async fn stale_receipts_and_late_transport_errors_never_downgrade_known_admission() {
    let (app, _dir, _session) = ready(false).await;
    let send = reserve(&app, &identity(), "draft-1", &control())
        .unwrap()
        .unwrap();
    let mut accepted = evidence(&send.request, "accepted");
    accepted["operationId"] = json!(operation(&app));
    apply(&app, &identity(), "draft-1", &accepted).unwrap();
    let mut pending = evidence(&send.request, "received");
    pending["operationId"] = accepted["operationId"].clone();
    apply(&app, &identity(), "draft-1", &pending).unwrap();
    failure(&app, &identity(), "draft-1", "late_timeout").unwrap();
    assert_eq!(
        lookup(&app.db.lock(), "alice", "draft-1").unwrap().state,
        Phase::Admitted
    );
    assert_eq!(
        app.db.lock().get_command(&send.command).unwrap().status,
        "accepted"
    );
    assert_eq!(
        app.db.lock().get_command(&send.command).unwrap().result["success"],
        true
    );
}
#[tokio::test]
async fn malformed_receipts_cannot_unlock_the_first_message_fence() {
    for field in ["operationId", "sessionId", "inputHash", "payloadHash", "id"] {
        let (app, _dir, session) = ready(false).await;
        let send = reserve(&app, &identity(), "draft-1", &control())
            .unwrap()
            .unwrap();
        let mut proof = evidence(&send.request, "accepted");
        proof["operationId"] = json!(operation(&app));
        if ["payloadHash", "id"].contains(&field) {
            proof["command"][field] = json!("other");
        } else {
            proof[field] = json!("other");
        }
        assert!(apply(&app, &identity(), "draft-1", &proof).is_err());
        assert!(
            super::super::require_initial_submission_complete(&app.db.lock(), &session).is_err()
        );
    }
}
#[tokio::test]
async fn stop_before_dispatch_fences_delayed_first_sends_and_allows_explicit_new_input() {
    let (app, _dir, session) = ready(false).await;
    let proof = json!({"operationId":operation(&app),"sessionId":"session-stable","state":"stopped","command":null,"inputHash":null,"stopRequested":true,"stopConfirmed":true});
    let read_proof = proof.clone();
    app.nodes.set_test_node(connected(),move |r|{if r.method==HttpMethod::Get {return Ok(pirc_protocol::NodeHttpResponse{status:200,body:Some(json!({"admission":read_proof}))});}assert!(r.url.ends_with("/commands"));let input=r.payload.unwrap();Ok(pirc_protocol::NodeHttpResponse{status:202,body:Some(json!({"command":{"id":input["commandId"],"status":"accepted"},"initialAdmission":proof}))})});
    let(code,body)=call(&app,"POST",&format!("/api/sessions/{session}/commands"),Some("alice"),None,Some(json!({"commandId":"stop-1","clientId":"phone","generation":1,"payload":{"type":"stop"}}))).await;
    assert_eq!(code, 202, "{body}");
    let row = lookup(&app.db.lock(), "alice", "draft-1").unwrap();
    assert_eq!(row.state, Phase::Stopped);
    assert_eq!(row.message_admission.unwrap().outcome, "not_admitted");
    assert!(super::super::require_initial_submission_complete(&app.db.lock(), &session).is_ok());
    assert!(
        reserve(&app, &identity(), "draft-1", &control())
            .unwrap()
            .is_none()
    );
}
#[tokio::test]
async fn owner_hidden_receipts_and_deletion_never_revive_an_initial_command() {
    let (app, _dir, session) = ready(false).await;
    let send = reserve(&app, &identity(), "draft-1", &control())
        .unwrap()
        .unwrap();
    app.db
        .lock()
        .begin_session_deletion(&session, "alice")
        .unwrap();
    let proof = evidence(&send.request, "accepted");
    apply(&app, &identity(), "draft-1", &proof).unwrap();
    assert_eq!(
        lookup(&app.db.lock(), "alice", "draft-1").unwrap().state,
        Phase::Cancelled
    );
    assert!(
        reserve(&app, &identity(), "draft-1", &control())
            .unwrap()
            .is_none()
    );
    assert_eq!(
        call(
            &app,
            "GET",
            "/api/conversation-submissions/draft-1/receipt",
            Some("bob"),
            None,
            None
        )
        .await
        .0,
        404
    );
}
#[tokio::test]
async fn deleted_node_receipts_do_not_claim_a_message_was_never_admitted() {
    let (app, _dir, _session) = ready(false).await;
    reserve(&app, &identity(), "draft-1", &control()).unwrap();
    let result = json!({"operationId":operation(&app),"sessionId":"session-stable","state":"deleted","command":null,"stopRequested":true,"stopConfirmed":true});
    assert_eq!(
        apply(&app, &identity(), "draft-1", &result)
            .unwrap_err()
            .code,
        "node_conversation_deleted"
    );
    assert_eq!(
        lookup(&app.db.lock(), "alice", "draft-1")
            .unwrap()
            .message_admission
            .unwrap()
            .outcome,
        "pending"
    );
}

#[tokio::test]
async fn migration_from_1014_preserves_pending_acceptance_and_existing_commands() {
    let (app, _dir, session) = ready(true).await;
    let path = app.config.state_dir.join("gateway.sqlite");
    {
        let db = app.db.lock();
        db.receive_command("legacy-command", &session, "hash", &json!({"type":"stop"}))
            .unwrap();
        db.execute_batch(concat!(include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/src/conversation_bindings/test_remove_policies.sql")), "DROP TABLE conversation_submission_retry_retirements; DROP TABLE conversation_submission_retry_attempts; DROP TRIGGER submission_pre_stop_cancelled; DROP TABLE conversation_submission_pending_stops; DROP TABLE conversation_submission_stop_controls; DROP TRIGGER submission_remote_cancelled; DROP TABLE conversation_submission_remote_cleanup; DROP TRIGGER submission_dispatch_cancelled; DROP TABLE conversation_submission_dispatches; DROP TRIGGER IF EXISTS conversation_binding_insert; DROP TRIGGER IF EXISTS conversation_binding_mapping; DROP TRIGGER IF EXISTS conversation_binding_mode; DROP TABLE IF EXISTS conversation_bindings; PRAGMA user_version=1014;")).unwrap();
    }
    drop(app);
    let db = Db::open(&path).unwrap();
    let conn = db.lock();
    assert_eq!(
        conn.get_command("legacy-command").unwrap().session_id,
        session
    );
    let row = lookup(&conn, "alice", "draft-1").unwrap();
    assert_eq!(row.state, Phase::Ready);
    assert!(row.accepted);
    assert!(row.message_admission.is_none());
    assert_eq!(count(&conn, "conversation_submission_dispatches"), 0);
    assert_eq!(
        conn.query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        crate::db::SCHEMA_VERSION
    );
}
#[tokio::test]
async fn ordinary_command_lookup_is_owner_scoped_read_only_and_hidden_during_deletion() {
    let (app, _dir, session) = ready(false).await;
    let send = reserve(&app, &identity(), "draft-1", &control())
        .unwrap()
        .unwrap();
    let original = app.db.lock().get_lease(&session).unwrap();
    let remote = json!({"id":send.command,"sessionId":"session-stable","payloadHash":payload_hash(&send.payload),"status":"accepted","result":{"success":true}});
    let calls = Arc::new(Mutex::new(Vec::new()));
    let observed = calls.clone();
    app.nodes.set_test_node(connected(), move |r| {
        observed.lock().unwrap().push(r.method);
        Ok(pirc_protocol::NodeHttpResponse {
            status: 200,
            body: Some(json!({"command":remote})),
        })
    });
    let url = format!("/api/sessions/{session}/commands/{}", send.command);
    let (code, body) = call(&app, "GET", &url, Some("alice"), None, None).await;
    assert_eq!(code, 200, "{body}");
    assert_eq!(body["command"]["status"], "accepted");
    assert_eq!(app.db.lock().get_lease(&session).unwrap(), original);
    assert_eq!(*calls.lock().unwrap(), vec![HttpMethod::Get]);
    assert_eq!(
        call(&app, "GET", &url, Some("bob"), None, None).await.0,
        404
    );
    app.db
        .lock()
        .begin_session_deletion(&session, "alice")
        .unwrap();
    assert_eq!(
        call(&app, "GET", &url, Some("alice"), None, None).await.0,
        404
    );
}
#[tokio::test]
async fn a_late_network_error_cannot_undo_a_confirmed_stop() {
    let (app, _dir, session) = ready(false).await;
    note_stop(&app.db.lock(), &session, "alice").unwrap();
    let proof = json!({"operationId":operation(&app),"sessionId":"session-stable","state":"stopped","command":null,"stopRequested":true,"stopConfirmed":true});
    apply(&app, &identity(), "draft-1", &proof).unwrap();
    failure(&app, &identity(), "draft-1", "late_timeout").unwrap();
    let row = lookup(&app.db.lock(), "alice", "draft-1").unwrap();
    assert_eq!(row.state, Phase::Stopped);
    assert_eq!(row.message_admission.unwrap().outcome, "not_admitted");
}

#[tokio::test]
async fn confirmed_stop_does_not_prevent_reconciling_an_unknown_original_admission() {
    let (app, _dir, session) = ready(false).await;
    let send = reserve(&app, &identity(), "draft-1", &control())
        .unwrap()
        .unwrap();
    let mut stopped = evidence(&send.request, "outcome_unknown");
    stopped["operationId"] = json!(operation(&app));
    stopped["state"] = json!("stopped");
    stopped["stopRequested"] = json!(true);
    stopped["stopConfirmed"] = json!(true);
    apply(&app, &identity(), "draft-1", &stopped).unwrap();
    let prior = lookup(&app.db.lock(), "alice", "draft-1").unwrap();
    assert_eq!(prior.state, Phase::Stopped);
    assert_eq!(prior.message_admission.unwrap().outcome, "outcome_unknown");
    let weaker = json!({"operationId":operation(&app),"sessionId":"session-stable","state":"not_submitted","command":null,"stopRequested":false,"stopConfirmed":false});
    set_node(&app, weaker, false);
    let (_, still_unknown) = call(
        &app,
        "GET",
        "/api/conversation-submissions/draft-1/receipt",
        Some("alice"),
        None,
        None,
    )
    .await;
    assert_eq!(
        still_unknown["preparation"]["messageAdmission"]["outcome"],
        "outcome_unknown"
    );
    assert_eq!(
        still_unknown["preparation"]["messageAdmission"]["stopConfirmed"],
        true
    );
    let mut accepted = evidence(&send.request, "accepted");
    accepted["operationId"] = json!(operation(&app));
    let calls = set_node(&app, accepted, false);
    app.db.lock().execute("DELETE FROM leases", []).unwrap();
    let (code, body) = call(
        &app,
        "GET",
        "/api/conversation-submissions/draft-1/receipt",
        Some("alice"),
        None,
        None,
    )
    .await;
    assert_eq!(code, 200, "{body}");
    assert_eq!(body["preparation"]["state"], "admitted");
    assert_eq!(
        body["preparation"]["messageAdmission"]["outcome"],
        "admitted"
    );
    assert_eq!(
        body["preparation"]["messageAdmission"]["stopConfirmed"],
        true
    );
    assert_eq!(
        *calls.lock().unwrap(),
        vec![(
            HttpMethod::Get,
            format!("/api/session-creations/{}/admission", operation(&app))
        )]
    );
    assert!(app.db.lock().get_lease(&session).unwrap().is_null());
}

#[tokio::test]
async fn known_admission_still_reconciles_an_unconfirmed_later_stop() {
    let (app, _dir, session) = ready(false).await;
    let send = reserve(&app, &identity(), "draft-1", &control())
        .unwrap()
        .unwrap();
    let mut accepted = evidence(&send.request, "accepted");
    accepted["operationId"] = json!(operation(&app));
    apply(&app, &identity(), "draft-1", &accepted).unwrap();
    note_stop(&app.db.lock(), &session, "alice").unwrap();
    accepted["stopRequested"] = json!(true);
    accepted["stopConfirmed"] = json!(true);
    let calls = set_node(&app, accepted, false);
    app.db.lock().execute("DELETE FROM leases", []).unwrap();
    let (code, body) = call(
        &app,
        "GET",
        "/api/conversation-submissions/draft-1/receipt",
        Some("alice"),
        None,
        None,
    )
    .await;
    assert_eq!(code, 200, "{body}");
    assert_eq!(body["preparation"]["state"], "admitted");
    assert_eq!(
        body["preparation"]["messageAdmission"]["outcome"],
        "admitted"
    );
    assert_eq!(
        body["preparation"]["messageAdmission"]["stopConfirmed"],
        true
    );
    assert_eq!(
        *calls.lock().unwrap(),
        vec![(
            HttpMethod::Get,
            format!("/api/session-creations/{}/admission", operation(&app))
        )]
    );
    assert!(app.db.lock().get_lease(&session).unwrap().is_null());
}

#[tokio::test]
async fn ready_submission_rechecks_capabilities_and_authority_before_reserving_a_command() {
    for fault in ["unsupported", "workspace-removed", "control-lost"] {
        let (app, _dir, session) = ready(false).await;
        let weak = Arc::downgrade(&app);
        app.nodes.set_test_node(connected(), move |r| {
            assert_eq!(r.method, HttpMethod::Get);
            assert_eq!(r.url, "/api/session-creations/capabilities");
            let mut caps = super::super::acceptance::tests::caps();
            match fault {
                "unsupported" => { caps.as_object_mut().unwrap().remove("canReadFirstMessageReceipt"); }
                "workspace-removed" => { weak.upgrade().unwrap().db.lock().execute("INSERT INTO workspace_removals(workspace_id,owner_user,removed_at,status) VALUES('node:repo','alice',1,'removed')",[]).unwrap(); }
                _ => { weak.upgrade().unwrap().db.lock().execute("DELETE FROM leases",[]).unwrap(); }
            }
            Ok(pirc_protocol::NodeHttpResponse { status:200, body:Some(caps) })
        });
        let (status, body) = call(
            &app,
            "POST",
            "/api/conversation-submissions/draft-1/dispatch",
            Some("alice"),
            None,
            Some(json!({"clientId":"phone","generation":1})),
        )
        .await;
        assert_eq!(status, 409, "{body}");
        assert_eq!(count(&app.db.lock(), "commands"), 0);
        let row = lookup(&app.db.lock(), "alice", "draft-1").unwrap();
        assert_eq!(row.state, Phase::Ready);
        assert_eq!(row.session_id, session);
        assert!(row.message_admission.is_none());
    }
}

#[tokio::test]
async fn node_reconnect_during_dispatch_probe_never_sends_to_replacement() {
    let (app, _dir, _) = ready(false).await;
    let weak = Arc::downgrade(&app);
    app.nodes.set_test_node(connected(), move |r| {
        assert_eq!(r.url, "/api/session-creations/capabilities");
        weak.upgrade()
            .unwrap()
            .nodes
            .set_test_node(connected(), |_| {
                panic!("replacement must not receive stale admission")
            });
        Ok(super::super::acceptance::tests::fake(&r))
    });
    let (status, result) = call(
        &app,
        "POST",
        "/api/conversation-submissions/draft-1/dispatch",
        Some("alice"),
        None,
        Some(json!({"clientId":"phone","generation":1})),
    )
    .await;
    assert_eq!(status, 409, "{result}");
    assert_eq!(result["error"]["code"], "node_connection_changed");
    assert_eq!(count(&app.db.lock(), "commands"), 0);
    assert_eq!(
        lookup(&app.db.lock(), "alice", "draft-1").unwrap().state,
        Phase::Ready
    );
}
#[tokio::test]
async fn closing_the_rollout_after_accept_still_materializes_dispatches_and_reconciles() {
    use super::super::tests::close_rollout;
    let (app, _dir) = app();
    model(&app);
    register(&app);
    let input = prepared(&app, false);
    let session = super::super::acceptance::accept_intent(&app, &identity(), "draft-1")
        .await
        .unwrap()
        .session_id;
    // The operator restarts the Gateway with PIRC_FIRST_SEND unset.
    let app = close_rollout(app);
    assert!(!app.config.first_send);

    // Repeating the admission calls for an accepted operation is a query, not admission.
    let (code, body) = call(
        &app,
        "POST",
        "/api/conversation-submissions/draft-1/accept",
        Some("alice"),
        None,
        None,
    )
    .await;
    assert_eq!(code, 202, "{body}");
    assert_eq!(body["preparation"]["accepted"], true);
    let (code, body) = call(
        &app,
        "POST",
        "/api/conversation-submissions/prepare",
        Some("alice"),
        None,
        Some(json!({"operationId":input.operation_id,"submission":input.submission})),
    )
    .await;
    assert_eq!(code, 200, "{body}");
    assert_eq!(body["preparation"]["accepted"], true);

    let (code, body) = call(
        &app,
        "POST",
        "/api/conversation-submissions/draft-1/materialize",
        Some("alice"),
        None,
        None,
    )
    .await;
    assert_eq!(code, 200, "{body}");
    assert_eq!(body["preparation"]["state"], "ready");
    app.db
        .lock()
        .mirror_lease(
            &session,
            &Lease {
                client_id: "phone".into(),
                generation: 1,
                expires_at: now_ms() + 60_000,
            },
            "alice",
            false,
        )
        .unwrap();

    let expected = specification(&app.db.lock(), "alice", "draft-1").unwrap();
    let mut proof = evidence(&expected.request, "accepted");
    proof["operationId"] = json!(operation(&app));
    let requests = set_node(&app, proof, true);
    let (code, body) = call(
        &app,
        "POST",
        "/api/conversation-submissions/draft-1/dispatch",
        Some("alice"),
        None,
        Some(json!({"clientId":"phone","generation":1})),
    )
    .await;
    assert_eq!(code, 200, "{body}");
    assert_eq!(body["preparation"]["state"], "outcome_unknown");
    app.db.lock().execute("DELETE FROM leases", []).unwrap();
    let (code, body) = call(
        &app,
        "GET",
        "/api/conversation-submissions/draft-1/receipt",
        Some("alice"),
        None,
        None,
    )
    .await;
    assert_eq!(code, 200, "{body}");
    assert_eq!(body["preparation"]["state"], "admitted");
    assert_eq!(
        requests
            .lock()
            .unwrap()
            .iter()
            .filter(|(m, _)| *m == HttpMethod::Post)
            .count(),
        1
    );
}
