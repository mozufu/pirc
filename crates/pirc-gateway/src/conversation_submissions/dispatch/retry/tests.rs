use super::*;
use crate::conversation_submissions::dispatch::{
    reserve as initial,
    tests::{control, evidence, operation, ready},
};
use crate::conversation_submissions::{
    acceptance::tests::{connected, identity},
    tests::{call, count},
};
use std::sync::{Arc, Mutex};
pub(super) async fn rejected(disk: bool) -> (AppState, tempfile::TempDir, Send) {
    let (app, dir, _session) = ready(disk).await;
    let send = initial(&app, &identity(), "draft-1", &control())
        .unwrap()
        .unwrap();
    let mut proof = evidence(&send.request, "rejected");
    proof["operationId"] = json!(operation(&app));
    apply(&app, &identity(), "draft-1", &proof).unwrap();
    (app, dir, send)
}
pub(super) fn input(first: &Send, id: &str) -> Retry {
    Retry {
        retry_id: id.into(),
        previous_command_id: first.command.clone(),
        client_id: "phone".into(),
        generation: 1,
    }
}
pub(super) fn body(input: &Retry) -> Value {
    json!({"retryId":input.retry_id,"previousCommandId":input.previous_command_id,"clientId":input.client_id,"generation":input.generation})
}
pub(super) fn node(
    app: &AppState,
    first: &Send,
    lose: bool,
    receive: bool,
    capable: bool,
) -> Arc<Mutex<Vec<(HttpMethod, String)>>> {
    let calls = Arc::new(Mutex::new(vec![]));
    let record = calls.clone();
    let creation = operation(app);
    let mut first_proof = evidence(&first.request, "rejected");
    first_proof["operationId"] = json!(creation);
    let proofs = Arc::new(Mutex::new(std::collections::HashMap::from([(
        first.command.clone(),
        first_proof,
    )])));
    app.nodes.set_test_node(connected(), move |request| {
        record
            .lock()
            .unwrap()
            .push((request.method, request.url.clone()));
        if request.url.ends_with("/capabilities") {
            return Ok(pirc_protocol::NodeHttpResponse {
                status: 200,
                body: Some({
                    let mut caps = crate::conversation_submissions::acceptance::tests::caps();
                    caps["canRetryInitialAdmission"] = json!(capable);
                    caps
                }),
            });
        }
        if request.method == HttpMethod::Post {
            assert!(request.url.ends_with("/admission/retry"));
            let input = &request.payload.as_ref().unwrap()["admission"];
            if receive {
                let mut proof = evidence(input, "accepted");
                proof["operationId"] = json!(creation);
                proofs
                    .lock()
                    .unwrap()
                    .insert(input["commandId"].as_str().unwrap().into(), proof);
            }
            if lose {
                return Err(ApiError::new(503, "node_timeout", "Synthetic lost reply"));
            }
        }
        let key = if request.method == HttpMethod::Post {
            request.payload.as_ref().unwrap()["admission"]["commandId"]
                .as_str()
                .unwrap()
                .to_owned()
        } else {
            request.url.rsplit('/').next().unwrap().to_owned()
        };
        let proof = proofs.lock().unwrap().get(&key).cloned();
        Ok(pirc_protocol::NodeHttpResponse {
            status: if proof.is_some() { 200 } else { 404 },
            body: proof.map(|p| json!({"admission":p})),
        })
    });
    calls
}
#[tokio::test]
async fn a_retry_keeps_public_binding_input_and_old_receipt_and_has_one_identity() {
    let (app, _dir, first) = rejected(false).await;
    let retry = input(&first, "retry-a");
    let send = reserve(&app, &identity(), "draft-1", &retry)
        .unwrap()
        .unwrap();
    assert_eq!(send.session, first.session);
    assert_eq!(send.payload, first.payload);
    assert_eq!(send.hash, first.hash);
    assert_ne!(send.command, first.command);
    assert_eq!(send.request["model"], first.request["model"]);
    assert_eq!(send.request["uploadIds"], first.request["uploadIds"]);
    let db = app.db.lock();
    assert_eq!(count(&db, "sessions"), 1);
    assert_eq!(count(&db, "commands"), 2);
    assert_eq!(count(&db, "conversation_submission_retry_attempts"), 1);
    assert_eq!(db.get_command(&first.command).unwrap().status, "rejected");
    let immutable: String = db
        .query_row(
            "SELECT command_id FROM conversation_submissions WHERE operation_id='draft-1'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(immutable, first.command);
    drop(db);
    app.db.lock().execute("DELETE FROM leases", []).unwrap();
    assert!(
        reserve(&app, &identity(), "draft-1", &retry)
            .unwrap()
            .is_none()
    );
}
#[tokio::test]
async fn lost_reply_reconciles_exact_retry_and_duplicate_posts_do_not_relay_or_take_control() {
    let (app, _dir, first) = rejected(false).await;
    let calls = node(&app, &first, true, true, true);
    let retry = input(&first, "retry-a");
    let (code, value) = call(
        &app,
        "POST",
        "/api/conversation-submissions/draft-1/retry",
        Some("alice"),
        None,
        Some(body(&retry)),
    )
    .await;
    assert_eq!(code, 200, "{value}");
    assert_eq!(value["preparation"]["state"], "outcome_unknown");
    let command = value["preparation"]["messageAdmission"]["commandId"]
        .as_str()
        .unwrap()
        .to_owned();
    app.db.lock().execute("DELETE FROM leases", []).unwrap();
    let (code, value) = call(
        &app,
        "POST",
        "/api/conversation-submissions/draft-1/retry",
        Some("alice"),
        None,
        Some(body(&retry)),
    )
    .await;
    assert_eq!(code, 200, "{value}");
    assert_eq!(value["preparation"]["state"], "admitted");
    assert_eq!(
        value["preparation"]["messageAdmission"]["retryId"],
        "retry-a"
    );
    assert_eq!(
        value["preparation"]["messageAdmission"]["retryEligible"],
        false
    );
    let recorded = calls.lock().unwrap();
    assert_eq!(
        recorded
            .iter()
            .filter(|(m, _)| *m == HttpMethod::Post)
            .count(),
        1
    );
    assert!(recorded.iter().any(|(m,url)|*m==HttpMethod::Get && url.ends_with(&format!("/attempts/{command}"))));
    assert_eq!(count(&app.db.lock(), "leases"), 0);
}
#[tokio::test]
async fn absent_retry_receipt_never_uses_the_old_rejection_as_permission_to_resend() {
    let (app, _dir, first) = rejected(false).await;
    let calls = node(&app, &first, true, false, true);
    let retry = input(&first, "retry-a");
    for _ in 0..3 {
        let (code, value) = call(
            &app,
            "POST",
            "/api/conversation-submissions/draft-1/retry",
            Some("alice"),
            None,
            Some(body(&retry)),
        )
        .await;
        assert_eq!(code, 200, "{value}");
        assert_eq!(value["preparation"]["state"], "outcome_unknown");
    }
    assert_eq!(
        calls
            .lock()
            .unwrap()
            .iter()
            .filter(|(m, _)| *m == HttpMethod::Post)
            .count(),
        1
    );
    assert_eq!(count(&app.db.lock(), "commands"), 2);
    assert_eq!(count(&app.db.lock(), "conversation_submission_cleanup"), 0);
}
#[tokio::test]
async fn unsupported_node_is_refused_before_reserving_any_new_attempt() {
    let (app, _dir, first) = rejected(false).await;
    let calls = node(&app, &first, false, false, false);
    let (code, value) = call(
        &app,
        "POST",
        "/api/conversation-submissions/draft-1/retry",
        Some("alice"),
        None,
        Some(body(&input(&first, "retry-a"))),
    )
    .await;
    assert_eq!(code, 409, "{value}");
    assert_eq!(value["error"]["code"], "initial_retry_unsupported");
    assert_eq!(count(&app.db.lock(), "commands"), 1);
    assert_eq!(
        count(&app.db.lock(), "conversation_submission_retry_attempts"),
        0
    );
    assert!(
        calls
            .lock()
            .unwrap()
            .iter()
            .all(|(m, _)| *m == HttpMethod::Get)
    );
}
#[tokio::test]
async fn stale_answers_and_failures_cannot_overwrite_a_new_attempt() {
    let (app, _dir, first) = rejected(false).await;
    let next = reserve(&app, &identity(), "draft-1", &input(&first, "retry-a"))
        .unwrap()
        .unwrap();
    let mut old = evidence(&first.request, "rejected");
    old["operationId"] = json!(operation(&app));
    apply_for(&app, &identity(), "draft-1", Some(&first.command), &old).unwrap();
    failure_for(&app, &identity(), "draft-1", Some(&first.command), "late").unwrap();
    assert_eq!(
        read(&app.db.lock(), "alice", "draft-1")
            .unwrap()
            .unwrap()
            .state,
        "dispatched"
    );
    let mut good = evidence(&next.request, "accepted");
    good["operationId"] = json!(operation(&app));
    apply_for(&app, &identity(), "draft-1", Some(&next.command), &good).unwrap();
    apply_for(&app, &identity(), "draft-1", Some(&first.command), &old).unwrap();
    failure_for(&app, &identity(), "draft-1", Some(&first.command), "late").unwrap();
    assert_eq!(
        lookup(&app.db.lock(), "alice", "draft-1").unwrap().state,
        Phase::Admitted
    );
    assert_eq!(
        app.db.lock().get_command(&first.command).unwrap().status,
        "rejected"
    );
}
#[tokio::test]
async fn mode_model_control_stop_and_device_revocation_block_new_retry_reservations() {
    for change in ["mode", "model", "lease", "stop", "device", "unknown"] {
        let (app, _dir, first) = rejected(false).await;
        let mut who = identity();
        match change {
            "mode" => {
                app.db
                    .lock()
                    .execute("UPDATE workspaces SET kind='gone'", [])
                    .unwrap();
            }
            "model" => {
                app.backends
                    .set_baseline(serde_json::from_value(json!({"providers":{}})).unwrap());
            }
            "lease" => {
                app.db.lock().execute("DELETE FROM leases", []).unwrap();
            }
            "stop" => {
                note_stop(&app.db.lock(), &first.session, "alice").unwrap();
            }
            "device" => who.device_id = Some("revoked".into()),
            _ => {
                app.db.lock().execute("UPDATE conversation_submission_dispatches SET state='outcome_unknown',outcome='outcome_unknown'",[]).unwrap();
            }
        }
        assert!(
            reserve(&app, &who, "draft-1", &input(&first, "retry-a")).is_err(),
            "{change}"
        );
        assert_eq!(count(&app.db.lock(), "commands"), 1);
        assert_eq!(
            count(&app.db.lock(), "conversation_submission_retry_attempts"),
            0
        );
    }
}
#[tokio::test(flavor = "multi_thread")]
async fn concurrent_clients_can_reserve_only_one_successor_of_the_same_rejection() {
    let (app, _dir, first) = rejected(false).await;
    let previous = first.command.clone();
    let barrier = Arc::new(std::sync::Barrier::new(2));
    let mut tasks = vec![];
    for id in ["retry-a", "retry-b"] {
        let app = app.clone();
        let previous = previous.clone();
        let barrier = barrier.clone();
        tasks.push(tokio::task::spawn_blocking(move || {
            barrier.wait();
            reserve(
                &app,
                &identity(),
                "draft-1",
                &Retry {
                    retry_id: id.into(),
                    previous_command_id: previous,
                    client_id: "phone".into(),
                    generation: 1,
                },
            )
        }));
    }
    let mut wins = 0;
    for task in tasks {
        if task.await.unwrap().is_ok() {
            wins += 1;
        }
    }
    assert_eq!(wins, 1);
    assert_eq!(count(&app.db.lock(), "commands"), 2);
    assert_eq!(
        count(&app.db.lock(), "conversation_submission_retry_attempts"),
        1
    );
}

#[tokio::test]
async fn only_a_new_known_rejected_successor_advances_the_monotonic_attempt_number() {
    let (app, _dir, first) = rejected(false).await;
    assert_eq!(
        lookup(&app.db.lock(), "alice", "draft-1")
            .unwrap()
            .message_admission
            .unwrap()
            .attempt_number,
        0
    );
    let a = input(&first, "retry-a");
    let second = reserve(&app, &identity(), "draft-1", &a).unwrap().unwrap();
    assert_eq!(
        current_number(&app.db.lock(), "alice", "draft-1", &second.command).unwrap(),
        1
    );
    let mut proof = evidence(&second.request, "rejected");
    proof["operationId"] = json!(operation(&app));
    apply_for(&app, &identity(), "draft-1", Some(&second.command), &proof).unwrap();
    let third = reserve(&app, &identity(), "draft-1", &input(&second, "retry-b"))
        .unwrap()
        .unwrap();
    assert_eq!(
        current_number(&app.db.lock(), "alice", "draft-1", &third.command).unwrap(),
        2
    );
    assert!(reserve(&app, &identity(), "draft-1", &a).unwrap().is_none());
    let row = lookup(&app.db.lock(), "alice", "draft-1").unwrap();
    assert_eq!(row.message_admission.unwrap().attempt_number, 2);
    assert_eq!(count(&app.db.lock(), "commands"), 3);
}

#[tokio::test]
async fn unreceived_retry_reconciles_a_global_stop_without_claiming_its_predecessor_proves_non_admission()
 {
    let (app, _dir, first) = rejected(false).await;
    let next = reserve(&app, &identity(), "draft-1", &input(&first, "retry-a"))
        .unwrap()
        .unwrap();
    note_stop(&app.db.lock(), &first.session, "alice").unwrap();
    let mut stopped = evidence(&first.request, "rejected");
    stopped["operationId"] = json!(operation(&app));
    stopped["stopRequested"] = json!(true);
    stopped["stopConfirmed"] = json!(true);
    stopped["state"] = json!("stopped");
    let proof = stopped.clone();
    let calls = Arc::new(Mutex::new(vec![]));
    let record = calls.clone();
    app.nodes.set_test_node(connected(), move |r| {
        record.lock().unwrap().push((r.method, r.url.clone()));
        Ok(pirc_protocol::NodeHttpResponse {
            status: if r.url.ends_with("/admission") {
                200
            } else {
                404
            },
            body: Some(json!({"admission":proof})),
        })
    });
    let row = reconcile(&app, &identity(), "draft-1").await.unwrap();
    assert_eq!(row.state, Phase::Stopped);
    let admission = row.message_admission.unwrap();
    assert!(admission.stop_confirmed);
    assert_eq!(admission.outcome, "outcome_unknown");
    assert_eq!(admission.command_id.as_deref(), Some(next.command.as_str()));
    assert!(
        calls
            .lock()
            .unwrap()
            .iter()
            .all(|(m, _)| *m == HttpMethod::Get)
    );
    observe_stop(
        &app,
        &identity(),
        &first.session,
        &json!({"initialAdmission":stopped}),
    )
    .unwrap();
    super::super::super::acceptance::require_initial_submission_complete(
        &app.db.lock(),
        &first.session,
    )
    .unwrap();
    let mut admitted = evidence(&next.request, "accepted");
    admitted["operationId"] = json!(operation(&app));
    apply_for(&app, &identity(), "draft-1", Some(&next.command), &admitted).unwrap();
    assert_eq!(
        lookup(&app.db.lock(), "alice", "draft-1").unwrap().state,
        Phase::Admitted
    );
    assert_eq!(
        app.db.lock().get_command(&next.command).unwrap().status,
        "accepted"
    );
}

#[tokio::test]
async fn an_unrelated_command_or_hash_cannot_confirm_a_missing_retry_stop() {
    let (app, _dir, first) = rejected(false).await;
    let _next = reserve(&app, &identity(), "draft-1", &input(&first, "retry-a"))
        .unwrap()
        .unwrap();
    let mut stopped = evidence(&first.request, "rejected");
    stopped["operationId"] = json!(operation(&app));
    stopped["stopRequested"] = json!(true);
    stopped["stopConfirmed"] = json!(true);
    stopped["state"] = json!("stopped");
    for field in ["operationId", "sessionId", "inputHash", "command"] {
        let mut bad = stopped.clone();
        if field == "command" {
            bad["command"]["id"] = json!("unrelated");
        } else {
            bad[field] = json!("unrelated");
        }
        assert!(apply_global_fence(&app, &identity(), "draft-1", &bad).is_err());
    }
    assert!(
        !read(&app.db.lock(), "alice", "draft-1")
            .unwrap()
            .unwrap()
            .confirmed
    );
}

#[tokio::test]
async fn restart_before_relay_retains_the_same_retry_identity_and_an_unknown_outcome() {
    let (app, _dir, first) = rejected(true).await;
    let retry = input(&first, "retry-a");
    let next = reserve(&app, &identity(), "draft-1", &retry)
        .unwrap()
        .unwrap();
    let db = crate::db::Db::open(&app.config.state_dir.join("gateway.sqlite")).unwrap();
    let conn = db.lock();
    conn.recover_startup().unwrap();
    let row = lookup(&conn, "alice", "draft-1").unwrap();
    assert_eq!(row.state, Phase::OutcomeUnknown);
    assert_eq!(row.session_id, first.session);
    let admission = row.message_admission.unwrap();
    assert_eq!(admission.command_id.as_deref(), Some(next.command.as_str()));
    assert_eq!(admission.retry_id.as_deref(), Some("retry-a"));
    assert_eq!(admission.attempt_number, 1);
    assert!(!admission.retry_eligible);
    assert!(known(&conn, "alice", "draft-1", &retry).unwrap());
    assert_eq!(conn.get_command(&first.command).unwrap().status, "rejected");
    assert_eq!(
        conn.get_command(&next.command).unwrap().status,
        "outcome_unknown"
    );
    assert_eq!(count(&conn, "commands"), 2);
    assert_eq!(count(&conn, "leases"), 0);
}

#[tokio::test]
async fn retry_identity_get_is_owned_read_only_and_keeps_an_unreceived_attempt_unknown() {
    let (app, _dir, first) = rejected(false).await;
    let next = reserve(&app, &identity(), "draft-1", &input(&first, "retry-a"))
        .unwrap()
        .unwrap();
    let calls = node(&app, &first, false, false, true);
    let (code, value) = call(
        &app,
        "GET",
        "/api/conversation-submissions/draft-1/retries/retry-a",
        Some("alice"),
        None,
        None,
    )
    .await;
    assert_eq!(code, 200, "{value}");
    assert_eq!(value["retry"]["commandId"], next.command);
    assert_eq!(value["retry"]["attemptNumber"], 1);
    assert_eq!(value["retry"]["status"], "outcome_unknown");
    assert_eq!(value["preparation"]["state"], "outcome_unknown");
    assert!(
        calls
            .lock()
            .unwrap()
            .iter()
            .all(|(m, _)| *m == HttpMethod::Get)
    );
    let (code, _) = call(
        &app,
        "GET",
        "/api/conversation-submissions/draft-1/retries/missing",
        Some("alice"),
        None,
        None,
    )
    .await;
    assert_eq!(code, 404);
    let (code, _) = call(
        &app,
        "GET",
        "/api/conversation-submissions/draft-1/retries/retry-a",
        Some("bob"),
        None,
        None,
    )
    .await;
    assert!(code >= 400);
    assert_eq!(count(&app.db.lock(), "commands"), 2);
    assert_eq!(
        count(&app.db.lock(), "conversation_submission_retry_attempts"),
        1
    );
}

#[tokio::test]
async fn retry_requires_the_full_workflow_and_pins_its_capability_connection() {
    for reconnect in [false, true] {
        let (app, _dir, first) = rejected(false).await;
        let weak = Arc::downgrade(&app);
        app.nodes.set_test_node(connected(), move |r| {
            assert_eq!(r.method, HttpMethod::Get);
            assert_eq!(r.url, "/api/session-creations/capabilities");
            let mut caps = crate::conversation_submissions::acceptance::tests::caps();
            caps["canRetryInitialAdmission"] = json!(true);
            if reconnect {
                weak.upgrade()
                    .unwrap()
                    .nodes
                    .set_test_node(connected(), |_| {
                        panic!("replacement must not receive retry input")
                    });
            } else {
                caps.as_object_mut()
                    .unwrap()
                    .remove("canStopBeforeAllocation");
            }
            Ok(pirc_protocol::NodeHttpResponse {
                status: 200,
                body: Some(caps),
            })
        });
        let input = input(&first, "new-retry");
        let (status, result) = call(
            &app,
            "POST",
            "/api/conversation-submissions/draft-1/retry",
            Some("alice"),
            None,
            Some(body(&input)),
        )
        .await;
        assert_eq!(status, 409, "{result}");
        assert_eq!(
            result["error"]["code"],
            if reconnect {
                "node_connection_changed"
            } else {
                "first_send_unsupported"
            }
        );
        assert_eq!(
            count(&app.db.lock(), "conversation_submission_retry_attempts"),
            0
        );
        assert_eq!(
            lookup(&app.db.lock(), "alice", "draft-1").unwrap().state,
            Phase::AdmissionFailed
        );
    }
}

#[tokio::test]
async fn a_retry_that_never_left_the_link_consumes_no_attempt_and_keeps_the_rejection() {
    let (app, _dir, first) = rejected(false).await;
    let seen = Arc::new(Mutex::new(0usize));
    let count_posts = seen.clone();
    app.nodes.set_test_node(connected(), move |request| {
        if request.url.ends_with("/capabilities") {
            let mut caps = crate::conversation_submissions::acceptance::tests::caps();
            caps["canRetryInitialAdmission"] = json!(true);
            return Ok(pirc_protocol::NodeHttpResponse {
                status: 200,
                body: Some(caps),
            });
        }
        assert!(request.url.ends_with("/admission/retry"));
        *count_posts.lock().unwrap() += 1;
        Err(ApiError::new(409, "node_connection_changed", "replaced").unsent())
    });
    let retry = input(&first, "retry-a");
    let (code, value) = call(
        &app,
        "POST",
        "/api/conversation-submissions/draft-1/retry",
        Some("alice"),
        None,
        Some(body(&retry)),
    )
    .await;
    assert_eq!(code, 200, "{value}");
    let prep = &value["preparation"];
    assert_eq!(prep["state"], "admission_failed", "{value}");
    assert_eq!(prep["deliveryError"], "first_message_not_sent");
    assert_eq!(prep["messageAdmission"]["commandId"], first.command);
    assert_eq!(prep["messageAdmission"]["attemptNumber"], 0);
    assert_eq!(prep["messageAdmission"]["retryEligible"], true);
    let db = app.db.lock();
    assert_eq!(count(&db, "conversation_submission_retry_attempts"), 0);
    assert_eq!(count(&db, "commands"), 1);
    assert_eq!(db.get_command(&first.command).unwrap().status, "rejected");
    assert_eq!(*seen.lock().unwrap(), 1);
}
