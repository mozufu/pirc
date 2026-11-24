use super::super::acceptance::tests::{connected, identity as alice, model, prepared, register};
use super::super::tests::{app, call, count, disk_app};
use super::*;
use crate::{app::App, db::Db};
use pirc_protocol::NodeHttpResponse;
use std::sync::Mutex;
const OP: &str = "draft-1";
async fn accepted(disk: bool) -> (AppState, tempfile::TempDir, String) {
    let (app, dir) = if disk { disk_app() } else { app() };
    model(&app);
    register(&app);
    prepared(&app, false);
    let row = super::super::acceptance::accept_intent(&app, &alice(), OP)
        .await
        .unwrap();
    (app, dir, row.session_id)
}
fn held(client: &str, generation: i64) -> control::Held {
    serde_json::from_value(json!({"clientId":client,"generation":generation})).unwrap()
}
async fn take(app: &AppState, client: &str, force: bool) -> (u16, Value) {
    call(
        app,
        "POST",
        "/api/conversation-submissions/draft-1/stop-control/acquire",
        Some("alice"),
        None,
        Some(json!({"clientId":client,"force":force})),
    )
    .await
}
async fn lease(app: &AppState) -> i64 {
    let (code, body) = take(app, "phone", false).await;
    assert_eq!(code, 200, "{body}");
    assert_eq!(body["scope"], "pending_first_send_stop");
    body["lease"]["generation"].as_i64().unwrap()
}
fn proof(j: &Job, session: Option<&str>) -> Value {
    json!({"operationId":j.target.creation,"workspaceId":j.target.workspace,"submissionHash":j.target.hash,"sessionId":session,"confirmed":true})
}
fn responder(
    app: &AppState,
    value: Value,
    lost: bool,
) -> Arc<Mutex<Vec<pirc_protocol::NodeHttpRequest>>> {
    let calls = Arc::new(Mutex::new(Vec::new()));
    let recorded = calls.clone();
    app.nodes.set_test_node(connected(), move |r| {
        recorded.lock().unwrap().push(r.clone());
        if r.url.ends_with("/capabilities") {
            return Ok(NodeHttpResponse {
                status: 200,
                body: Some(json!({"version":1,"canStopBeforeAllocation":true})),
            });
        }
        assert!(r.url.ends_with("/stop"), "unexpected operation: {}", r.url);
        if lost && r.method == HttpMethod::Post {
            return Err(ApiError::new(
                503,
                "node_timeout",
                "synthetic response loss",
            ));
        }
        Ok(NodeHttpResponse {
            status: 200,
            body: Some(json!({"stop":value})),
        })
    });
    calls
}
#[tokio::test]
async fn stop_is_durable_before_any_remote_mapping_and_preserves_input() {
    let (app, _dir, session) = accepted(true).await;
    let generation = lease(&app).await;
    let calls = register(&app);
    let (code, body) = call(
        &app,
        "POST",
        "/api/conversation-submissions/draft-1/stop",
        Some("alice"),
        None,
        Some(json!({"clientId":"phone","generation":generation})),
    )
    .await;
    assert_eq!(code, 202, "{body}");
    assert_eq!(body["preparation"]["state"], "stopping");
    assert_eq!(body["preparation"]["nodeMapped"], false);
    assert_eq!(
        body["preparation"]["messageAdmission"]["stopConfirmed"],
        false
    );
    assert!(calls.lock().unwrap().is_empty());
    assert_eq!(count(&app.db.lock(), "commands"), 0);
    assert_eq!(
        count(&app.db.lock(), "conversation_submission_pending_stops"),
        1
    );
    assert_eq!(
        lookup(&app.db.lock(), "alice", OP)
            .unwrap()
            .submission
            .unwrap()
            .message,
        "Keep this first message"
    );
    assert!(
        app.db
            .lock()
            .get_session(&session)
            .unwrap()
            .pi_session_id
            .is_none()
    );
    assert!(super::super::require_initial_submission_complete(&app.db.lock(), &session).is_err());
    let j = read(&app.db.lock(), "alice", OP).unwrap().unwrap();
    complete(&app, &j, &proof(&j, None)).unwrap();
    let row = lookup(&app.db.lock(), "alice", OP).unwrap();
    assert_eq!(row.state, Phase::Stopped);
    assert!(!row.node_mapped);
    assert!(row.submission.is_some());
    assert!(super::super::require_initial_submission_complete(&app.db.lock(), &session).is_ok());
    assert_eq!(count(&app.db.lock(), "sessions"), 1);
    assert_eq!(count(&app.db.lock(), "session_deletions"), 0);
    assert!(app.db.lock().get_lease(&session).unwrap().is_null());
}
#[tokio::test]
async fn stop_control_is_explicit_scoped_and_has_monotonic_takeover_generations() {
    let (app, _dir, session) = accepted(false).await;
    let first = lease(&app).await;
    assert_eq!(take(&app, "laptop", false).await.0, 409);
    let (code, b) = take(&app, "laptop", true).await;
    assert_eq!(code, 200, "{b}");
    let second = b["lease"]["generation"].as_i64().unwrap();
    assert!(second > first);
    assert_eq!(
        queue(&app, &alice(), OP, &held("phone", first))
            .unwrap_err()
            .code,
        "control_lost"
    );
    assert_eq!(
        count(&app.db.lock(), "conversation_submission_pending_stops"),
        0
    );
    let (code, _) = call(
        &app,
        "POST",
        "/api/conversation-submissions/draft-1/stop-control/release",
        Some("alice"),
        None,
        Some(json!({"clientId":"laptop","generation":second})),
    )
    .await;
    assert_eq!(code, 200);
    assert_eq!(
        queue(&app, &alice(), OP, &held("laptop", second))
            .unwrap_err()
            .code,
        "control_lost"
    );
    let third = lease(&app).await;
    assert!(third > second);
    app.db
        .lock()
        .execute(
            "UPDATE conversation_submission_stop_controls SET expires_at=0",
            [],
        )
        .unwrap();
    assert_eq!(
        queue(&app, &alice(), OP, &held("phone", third))
            .unwrap_err()
            .code,
        "control_lost"
    );
    assert!(lease(&app).await > third);
    // This lease is never mirrored into the Node-command lease table.
    assert!(app.db.lock().get_lease(&session).unwrap().is_null());
}
#[tokio::test]
async fn wrong_owner_unaccepted_input_and_revoked_device_cannot_acquire_or_stop() {
    let (app, _dir, _) = accepted(false).await;
    let (code, _) = call(
        &app,
        "POST",
        "/api/conversation-submissions/draft-1/stop-control/acquire",
        Some("bob"),
        None,
        Some(json!({"clientId":"phone"})),
    )
    .await;
    assert_eq!(code, 404);
    let invalid = Identity {
        device_id: Some("revoked-device".into()),
        ..alice()
    };
    assert_eq!(
        owned(&app, &app.db.lock(), &invalid, OP)
            .unwrap_err()
            .status,
        401
    );
    assert_eq!(
        queue(&app, &invalid, OP, &held("phone", 1))
            .unwrap_err()
            .status,
        401
    );
    assert_eq!(
        count(&app.db.lock(), "conversation_submission_stop_controls"),
        0
    );
    assert_eq!(
        count(&app.db.lock(), "conversation_submission_pending_stops"),
        0
    );
    let other = Input {
        operation_id: "unaccepted".into(),
        ..prepared(&app, false)
    };
    reserve(&mut app.db.lock(), "alice", &other).unwrap();
    assert!(owned(&app, &app.db.lock(), &alice(), "unaccepted").is_err());
}
#[tokio::test]
async fn late_mapping_requires_fresh_node_control_instead_of_reusing_pending_control() {
    let (app, _dir, _) = accepted(false).await;
    let generation = lease(&app).await;
    super::super::acceptance::advance(&app, &alice(), OP)
        .await
        .unwrap();
    assert_eq!(
        queue(&app, &alice(), OP, &held("phone", generation))
            .unwrap_err()
            .code,
        "session_control_required"
    );
    assert_eq!(
        take(&app, "phone", true).await.1["error"]["code"],
        "session_control_required"
    );
    assert_eq!(
        count(&app.db.lock(), "conversation_submission_pending_stops"),
        0
    );
    assert_eq!(
        count(&app.db.lock(), "conversation_submission_dispatches"),
        0
    );
}
#[tokio::test]
async fn checking_a_pending_stop_is_get_only_and_never_renews_control_or_replays_input() {
    let (app, _dir, _) = accepted(false).await;
    let generation = lease(&app).await;
    queue(&app, &alice(), OP, &held("phone", generation)).unwrap();
    let j = read(&app.db.lock(), "alice", OP).unwrap().unwrap();
    let calls = responder(&app, proof(&j, None), false);
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
    assert_eq!(body["preparation"]["state"], "stopped");
    assert_eq!(calls.lock().unwrap().len(), 1);
    assert!(
        calls
            .lock()
            .unwrap()
            .iter()
            .all(|r| r.method == HttpMethod::Get && r.url.ends_with("/stop"))
    );
    assert_eq!(count(&app.db.lock(), "commands"), 0);
    assert_eq!(
        count(&app.db.lock(), "conversation_submission_pending_stops"),
        0
    );
    let expired: i64 = app
        .db
        .lock()
        .query_row(
            "SELECT expires_at FROM conversation_submission_stop_controls",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(expired, 0);
    let (_, again) = call(
        &app,
        "GET",
        "/api/conversation-submissions/draft-1/receipt",
        Some("alice"),
        None,
        None,
    )
    .await;
    assert_eq!(again["preparation"]["state"], "stopped");
    assert_eq!(calls.lock().unwrap().len(), 1);
}
#[tokio::test]
async fn unknown_stop_query_leaves_input_fenced_and_is_not_a_hidden_mutation() {
    let (app, _dir, session) = accepted(false).await;
    let generation = lease(&app).await;
    queue(&app, &alice(), OP, &held("phone", generation)).unwrap();
    let methods = Arc::new(Mutex::new(Vec::new()));
    let log = methods.clone();
    app.nodes.set_test_node(connected(), move |r| {
        log.lock().unwrap().push(r.method);
        Ok(NodeHttpResponse {
            status: 404,
            body: None,
        })
    });
    let (code, body) = call(
        &app,
        "POST",
        "/api/conversation-submissions/draft-1/dispatch",
        Some("alice"),
        None,
        Some(json!({"clientId":"stale","generation":999})),
    )
    .await;
    assert_eq!(code, 200, "{body}");
    assert_eq!(body["preparation"]["state"], "stopping");
    assert_eq!(
        body["preparation"]["messageAdmission"]["stopConfirmed"],
        false
    );
    assert!(
        methods
            .lock()
            .unwrap()
            .iter()
            .all(|m| *m == HttpMethod::Get)
    );
    assert_eq!(count(&app.db.lock(), "commands"), 0);
    assert!(super::super::require_initial_submission_complete(&app.db.lock(), &session).is_err());
}
#[tokio::test]
async fn lost_stop_reply_survives_gateway_reopen_and_queued_authority_is_narrow() {
    let (app, _dir, session) = accepted(true).await;
    let generation = lease(&app).await;
    queue(&app, &alice(), OP, &held("phone", generation)).unwrap();
    let j = read(&app.db.lock(), "alice", OP).unwrap().unwrap();
    let calls = responder(&app, proof(&j, None), true);
    sweep(&app).await.unwrap();
    assert_eq!(
        calls
            .lock()
            .unwrap()
            .iter()
            .filter(|r| r.method == HttpMethod::Post)
            .count(),
        1
    );
    assert_eq!(
        lookup(&app.db.lock(), "alice", OP).unwrap().state,
        Phase::Stopping
    );
    let fresh = App::new(
        app.config.clone(),
        Arc::new(Db::open(&app.config.state_dir.join("gateway.sqlite")).unwrap()),
        app.backends.clone(),
        crate::app::test_modes(),
    );
    let calls = responder(&fresh, proof(&j, None), false);
    sweep(&fresh).await.unwrap();
    assert_eq!(
        lookup(&fresh.db.lock(), "alice", OP).unwrap().state,
        Phase::Stopped
    );
    assert!(
        calls
            .lock()
            .unwrap()
            .iter()
            .all(|r| r.method == HttpMethod::Get || r.url.ends_with("/stop"))
    );
    assert!(fresh.db.lock().get_lease(&session).unwrap().is_null());
    assert_eq!(count(&fresh.db.lock(), "commands"), 0);
}
#[tokio::test]
async fn stopped_input_cannot_be_rebound_by_invalid_node_evidence() {
    for field in [
        "operationId",
        "workspaceId",
        "submissionHash",
        "confirmed",
        "sessionId",
    ] {
        let (app, _dir, _) = accepted(false).await;
        let generation = lease(&app).await;
        queue(&app, &alice(), OP, &held("phone", generation)).unwrap();
        let j = read(&app.db.lock(), "alice", OP).unwrap().unwrap();
        let mut wrong = proof(&j, None);
        wrong[field] = if field == "confirmed" {
            json!(false)
        } else {
            json!("../invalid")
        };
        assert_eq!(
            complete(&app, &j, &wrong).unwrap_err().code,
            "invalid_stop_receipt"
        );
        assert_eq!(
            lookup(&app.db.lock(), "alice", OP).unwrap().state,
            Phase::Stopping
        );
        assert!(pending(&app.db.lock(), "alice", OP).unwrap());
    }
}
#[tokio::test]
async fn a_stop_that_wins_before_mapping_stays_monotonic_when_mapping_later_appears() {
    let (app, _dir, _) = accepted(false).await;
    let generation = lease(&app).await;
    queue(&app, &alice(), OP, &held("phone", generation)).unwrap();
    let j = read(&app.db.lock(), "alice", OP).unwrap().unwrap();
    complete(&app, &j, &proof(&j, None)).unwrap();
    register(&app);
    let row = super::super::acceptance::advance(&app, &alice(), OP)
        .await
        .unwrap();
    assert_eq!(row.state, Phase::Stopped);
    assert!(row.node_mapped);
    assert!(row.submission.is_some());
    assert_eq!(count(&app.db.lock(), "commands"), 0);
}
#[tokio::test]
async fn delayed_null_proof_cannot_finish_after_a_known_mapping_until_matching_receipt_arrives() {
    let (app, _dir, _) = accepted(false).await;
    let generation = lease(&app).await;
    // An allocation request is already in flight when the user queues Stop.
    let weak = Arc::downgrade(&app);
    app.nodes.set_test_node(connected(), move |r| {
        if r.url == "/api/session-creations" {
            queue(
                &weak.upgrade().unwrap(),
                &alice(),
                OP,
                &held("phone", generation),
            )
            .unwrap();
        }
        Ok(super::super::acceptance::tests::fake(&r))
    });
    let row = super::super::acceptance::advance(&app, &alice(), OP)
        .await
        .unwrap();
    assert_eq!(row.state, Phase::Stopping);
    assert!(row.node_mapped);
    let j = read(&app.db.lock(), "alice", OP).unwrap().unwrap();
    assert!(complete(&app, &j, &proof(&j, None)).is_err());
    assert!(complete(&app, &j, &proof(&j, Some("wrong-session"))).is_err());
    complete(&app, &j, &proof(&j, Some("session-stable"))).unwrap();
    assert_eq!(
        lookup(&app.db.lock(), "alice", OP).unwrap().state,
        Phase::Stopped
    );
}
#[tokio::test]
async fn unsupported_node_or_started_initial_intake_does_not_fabricate_confirmation() {
    let (app, _dir, _) = accepted(false).await;
    let generation = lease(&app).await;
    queue(&app, &alice(), OP, &held("phone", generation)).unwrap();
    let methods = Arc::new(Mutex::new(Vec::new()));
    let log = methods.clone();
    app.nodes.set_test_node(connected(), move |r| {
        log.lock().unwrap().push(r.method);
        Ok(NodeHttpResponse {
            status: 200,
            body: Some(json!({"version":1})),
        })
    });
    sweep(&app).await.unwrap();
    assert_eq!(*methods.lock().unwrap(), vec![HttpMethod::Get]);
    assert_eq!(
        lookup(&app.db.lock(), "alice", OP)
            .unwrap()
            .delivery_error
            .as_deref(),
        Some("creation_stop_unsupported")
    );
    app.nodes.set_test_node(connected(), move |r| {
        Ok(NodeHttpResponse {
            status: if r.method == HttpMethod::Post {
                409
            } else {
                200
            },
            body: Some(if r.method == HttpMethod::Post {
                json!({"error":{"code":"initial_admission_exists"}})
            } else {
                json!({"version":1,"canStopBeforeAllocation":true})
            }),
        })
    });
    sweep(&app).await.unwrap();
    assert_eq!(
        lookup(&app.db.lock(), "alice", OP).unwrap().state,
        Phase::Stopping
    );
    assert!(pending(&app.db.lock(), "alice", OP).unwrap());
}
#[tokio::test]
async fn deleting_the_source_supersedes_stop_and_a_late_receipt_cannot_revive_it() {
    let (app, _dir, session) = accepted(false).await;
    let generation = lease(&app).await;
    queue(&app, &alice(), OP, &held("phone", generation)).unwrap();
    let j = read(&app.db.lock(), "alice", OP).unwrap().unwrap();
    app.db
        .lock()
        .begin_session_deletion(&session, "alice")
        .unwrap();
    assert_eq!(
        count(&app.db.lock(), "conversation_submission_pending_stops"),
        0
    );
    assert_eq!(
        count(&app.db.lock(), "conversation_submission_stop_controls"),
        0
    );
    complete(&app, &j, &proof(&j, None)).unwrap();
    assert_eq!(
        lookup(&app.db.lock(), "alice", OP).unwrap().state,
        Phase::Cancelled
    );
    assert!(
        lookup(&app.db.lock(), "alice", OP)
            .unwrap()
            .submission
            .is_none()
    );
}
#[tokio::test]
async fn duplicate_stop_after_expiry_queries_the_same_intent_without_refreshing_authority() {
    let (app, _dir, _) = accepted(false).await;
    let generation = lease(&app).await;
    queue(&app, &alice(), OP, &held("phone", generation)).unwrap();
    assert_eq!(
        queue(&app, &alice(), OP, &held("unrelated-client", 999))
            .unwrap()
            .state,
        Phase::Stopping
    );
    assert_eq!(
        count(&app.db.lock(), "conversation_submission_pending_stops"),
        1
    );
    let j = read(&app.db.lock(), "alice", OP).unwrap().unwrap();
    complete(&app, &j, &proof(&j, None)).unwrap();
    assert_eq!(
        queue(&app, &alice(), OP, &held("unrelated-client", 999))
            .unwrap()
            .state,
        Phase::Stopped
    );
    assert_eq!(
        count(&app.db.lock(), "conversation_submission_pending_stops"),
        0
    );
}
#[tokio::test]
async fn removed_mode_does_not_prevent_the_owner_from_fencing_an_unmapped_input() {
    let (app, _dir, _) = accepted(false).await;
    app.db
        .lock()
        .execute("UPDATE workspaces SET kind='removed-mode'", [])
        .unwrap();
    let generation = lease(&app).await;
    assert_eq!(
        queue(&app, &alice(), OP, &held("phone", generation))
            .unwrap()
            .state,
        Phase::Stopping
    );
}
#[tokio::test]
async fn migration_from_1016_preserves_accepted_input_and_existing_commands() {
    let (app, _dir, session) = accepted(true).await;
    app.db
        .lock()
        .receive_command("old-command", &session, "hash", &json!({"type":"stop"}))
        .unwrap();
    app.db.lock().execute_batch(concat!(include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/src/conversation_bindings/test_remove_policies.sql")), "DROP TABLE conversation_submission_retry_retirements; DROP TABLE conversation_submission_retry_attempts; DROP TRIGGER submission_pre_stop_cancelled; DROP TABLE conversation_submission_pending_stops; DROP TABLE conversation_submission_stop_controls; DROP TRIGGER IF EXISTS conversation_binding_insert; DROP TRIGGER IF EXISTS conversation_binding_mapping; DROP TRIGGER IF EXISTS conversation_binding_mode; DROP TABLE IF EXISTS conversation_bindings; PRAGMA user_version=1016;")).unwrap();
    let fresh = App::new(
        app.config.clone(),
        Arc::new(Db::open(&app.config.state_dir.join("gateway.sqlite")).unwrap()),
        app.backends.clone(),
        crate::app::test_modes(),
    );
    assert_eq!(
        fresh
            .db
            .lock()
            .get_command("old-command")
            .unwrap()
            .session_id,
        session
    );
    assert_eq!(
        fresh
            .db
            .lock()
            .query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        crate::db::SCHEMA_VERSION
    );
    let generation = lease(&fresh).await;
    let row = queue(&fresh, &alice(), OP, &held("phone", generation)).unwrap();
    assert_eq!(row.state, Phase::Stopping);
    assert!(row.submission.is_some());
}

#[tokio::test]
async fn concurrent_connections_queue_exactly_one_stop_identity() {
    let (app, _dir, _) = accepted(true).await;
    let generation = lease(&app).await;
    let path = app.config.state_dir.join("gateway.sqlite");
    let barrier = std::sync::Barrier::new(6);
    let rows = std::thread::scope(|scope| {
        (0..6)
            .map(|_| {
                scope.spawn(|| {
                    let fresh = App::new(
                        app.config.clone(),
                        Arc::new(Db::open(&path).unwrap()),
                        app.backends.clone(),
                        crate::app::test_modes(),
                    );
                    barrier.wait();
                    queue(&fresh, &alice(), OP, &held("phone", generation))
                        .unwrap()
                        .session_id
                })
            })
            .collect::<Vec<_>>()
            .into_iter()
            .map(|t| t.join().unwrap())
            .collect::<Vec<_>>()
    });
    assert!(rows.iter().all(|id| id == &rows[0]));
    assert_eq!(
        count(&app.db.lock(), "conversation_submission_pending_stops"),
        1
    );
    assert_eq!(
        count(&app.db.lock(), "conversation_submission_dispatches"),
        1
    );
    assert_eq!(count(&app.db.lock(), "commands"), 0);
}

#[tokio::test]
async fn blank_release_checks_connection_without_applying_old_attachment_limits() {
    let (app, _dir) = disk_app();
    model(&app);
    register(&app);
    prepared(&app, true);
    super::super::attachments::stage(&app, "alice", OP, "file-1", b"test").unwrap();
    let original = super::super::acceptance::accept_intent(&app, &alice(), OP)
        .await
        .unwrap();
    let generation = lease(&app).await;
    queue(&app, &alice(), OP, &held("phone", generation)).unwrap();
    let job = read(&app.db.lock(), "alice", OP).unwrap().unwrap();
    complete(&app, &job, &proof(&job, None)).unwrap();
    app.nodes.set_test_node(connected(), |r| {
        assert!(!r.url.contains("/attachments/"));
        assert!(!r.url.contains("/admission"));
        let mut result = super::super::acceptance::tests::fake(&r);
        if r.url.ends_with("/capabilities") {
            let caps = result.body.as_mut().unwrap();
            caps["maxAttachments"] = json!(0);
            caps["maxUploadBytes"] = json!(0);
        }
        Ok(result)
    });
    let released = super::super::acceptance::advance(&app, &alice(), OP)
        .await
        .unwrap();
    assert_eq!(released.state, Phase::Stopped);
    assert!(released.node_mapped);
    assert_eq!(released.session_id, original.session_id);
    assert_eq!(released.submission.unwrap().attachments.len(), 1);
    assert_eq!(
        std::fs::read(
            app.config
                .state_dir
                .join("submission-staging")
                .join(original.session_id)
                .join("file-1.bin")
        )
        .unwrap(),
        b"test"
    );
    assert_eq!(count(&app.db.lock(), "commands"), 0);
}
