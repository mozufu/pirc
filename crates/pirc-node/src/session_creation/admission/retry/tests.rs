use super::*;
use crate::router::Body;
use crate::store::{Db, Store};

fn input(command: &str, generation: i64) -> Input {
    serde_json::from_value(json!({"commandId":command,"submissionHash":"a".repeat(64),"model":{"provider":"fake","id":"m"},"thinking":"low","message":"Keep the exact first input","uploadIds":[],"clientId":"phone","generation":generation})).unwrap()
}
fn wire(input: &Input) -> Value {
    json!({"commandId":input.command_id,"submissionHash":input.submission_hash,"model":input.model,"thinking":input.thinking,"message":input.message,"uploadIds":input.upload_ids,"clientId":input.client_id,"generation":input.generation})
}
fn request(value: Value, user: &str, command: Option<&str>) -> Request {
    let mut params = vec![("id".into(), "creation-1".into())];
    if let Some(id) = command {
        params.push(("commandId".into(), id.into()));
    }
    Request {
        method: pirc_protocol::HttpMethod::Post,
        path: String::new(),
        query: vec![],
        params,
        user: user.into(),
        body: Body::Json(value),
    }
}
async fn seeded(status: CommandStatus) -> (tempfile::TempDir, Node, String, Input) {
    let (dir, node, session) = super::super::super::uploads::tests::node().await;
    let generation = node
        .db
        .lock()
        .acquire_lease(&session, "phone", false, 60_000)
        .unwrap()
        .generation;
    let first = input("first", generation);
    {
        let db = node.db.lock();
        let payload = serde_json::to_value(first.payload()).unwrap();
        db.receive_command("first", &session, &payload_hash(&payload), &payload)
            .unwrap();
        db.update_command("first", status, None, None).unwrap();
        db.execute("INSERT INTO creation_initial_admissions(owner_user,operation_id,session_id,command_id,input_hash,created_at,updated_at) VALUES('test-user','creation-1',?1,'first',?2,1,1)",params![session,first.hash()]).unwrap();
        db.execute("INSERT INTO creation_admission_attempts(owner_user,operation_id,command_id,input_hash,created_at) VALUES('test-user','creation-1','first',?1,1)",[first.hash()]).unwrap();
    }
    (dir, node, session, first)
}
fn count(db: &Connection, table: &str) -> i64 {
    db.query_row(&format!("SELECT count(*) FROM {table}"), [], |r| r.get(0))
        .unwrap()
}
#[tokio::test]
async fn rejected_attempt_reserves_once_and_stale_original_is_only_a_receipt() {
    let (_dir, node, session, first) = seeded(CommandStatus::Rejected).await;
    let next = input("second", first.generation);
    let retry_input = Retry {
        previous_command_id: "first".into(),
        admission: next,
    };
    assert_eq!(
        reserve(&node, "test-user", "creation-1", &retry_input).unwrap(),
        Some(session.clone())
    );
    assert_eq!(
        reserve(&node, "test-user", "creation-1", &retry_input).unwrap(),
        None
    );
    {
        let db = node.db.lock();
        assert_eq!(count(&db, "commands"), 2);
        assert_eq!(count(&db, "creation_admission_attempts"), 2);
        assert!(require_sendable(&db, &session, "first", "test-user").is_err());
        require_sendable(&db, &session, "second", "test-user").unwrap();
        assert!(require_generic(&db, &session).is_err());
    }
    node.db
        .lock()
        .acquire_lease(&session, "other", true, 60_000)
        .unwrap();
    let duplicate = retry(
        node.clone(),
        request(
            json!({"previousCommandId":"first","admission":wire(&retry_input.admission)}),
            "test-user",
            None,
        ),
    )
    .await
    .unwrap();
    assert_eq!(
        duplicate.body.unwrap()["admission"]["command"]["id"],
        "second"
    );
    let old = super::super::submit(node.clone(), request(wire(&first), "test-user", None))
        .await
        .unwrap();
    assert_eq!(
        old.body.unwrap()["admission"]["command"]["status"],
        "rejected"
    );
    assert!(node.runners.get(&session).is_none());
    node.close().await;
}
#[tokio::test]
async fn unknown_pending_or_accepted_work_cannot_be_retried_or_replaced() {
    for state in [
        CommandStatus::Received,
        CommandStatus::Dispatched,
        CommandStatus::OutcomeUnknown,
        CommandStatus::Accepted,
    ] {
        let (_dir, node, session, first) = seeded(state).await;
        let retry = Retry {
            previous_command_id: "first".into(),
            admission: input("second", first.generation),
        };
        assert_eq!(
            reserve(&node, "test-user", "creation-1", &retry)
                .unwrap_err()
                .code,
            "admission_not_retryable"
        );
        assert_eq!(count(&node.db.lock(), "commands"), 1);
        assert!(node.runners.get(&session).is_none());
        node.close().await;
    }
}
#[tokio::test]
async fn stop_and_current_control_fence_new_attempts_without_changing_prior_receipts() {
    let (_dir, node, session, first) = seeded(CommandStatus::Rejected).await;
    let retry = Retry {
        previous_command_id: "first".into(),
        admission: input("second", first.generation),
    };
    node.db
        .lock()
        .acquire_lease(&session, "other", true, 60_000)
        .unwrap();
    assert!(reserve(&node, "test-user", "creation-1", &retry).is_err());
    request_stop(&node.db.lock(), &session, "test-user").unwrap();
    assert_eq!(
        reserve(&node, "test-user", "creation-1", &retry)
            .unwrap_err()
            .code,
        "first_message_stopped"
    );
    assert_eq!(count(&node.db.lock(), "commands"), 1);
    node.close().await;
}
#[tokio::test]
async fn changed_input_predecessor_or_owner_never_reserves_a_replacement() {
    let (_dir, node, _session, first) = seeded(CommandStatus::Rejected).await;
    for changed in ["text", "model", "files", "predecessor"] {
        let mut retry = Retry {
            previous_command_id: "first".into(),
            admission: input("second", first.generation),
        };
        match changed {
            "text" => retry.admission.message = "different".into(),
            "model" => retry.admission.model.id = "different".into(),
            "files" => retry.admission.upload_ids = vec!["different".into()],
            _ => retry.previous_command_id = "different".into(),
        }
        assert!(reserve(&node, "test-user", "creation-1", &retry).is_err());
    }
    let retry = Retry {
        previous_command_id: "first".into(),
        admission: input("second", first.generation),
    };
    assert_eq!(
        reserve(&node, "other-user", "creation-1", &retry)
            .unwrap_err()
            .status,
        404
    );
    assert_eq!(count(&node.db.lock(), "commands"), 1);
    node.close().await;
}
#[tokio::test(flavor = "multi_thread")]
async fn concurrent_retry_ids_have_one_predecessor_winner() {
    let (_dir, node, _session, first) = seeded(CommandStatus::Rejected).await;
    let barrier = std::sync::Arc::new(std::sync::Barrier::new(2));
    let mut tasks = vec![];
    for id in ["retry-a", "retry-b"] {
        let node = node.clone();
        let barrier = barrier.clone();
        let generation = first.generation;
        tasks.push(tokio::task::spawn_blocking(move || {
            barrier.wait();
            reserve(
                &node,
                "test-user",
                "creation-1",
                &Retry {
                    previous_command_id: "first".into(),
                    admission: input(id, generation),
                },
            )
        }));
    }
    let mut won = 0;
    for task in tasks {
        if task.await.unwrap().is_ok() {
            won += 1;
        }
    }
    assert_eq!(won, 1);
    assert_eq!(count(&node.db.lock(), "commands"), 2);
    node.close().await;
}
#[tokio::test]
async fn restart_preserves_old_rejection_but_never_replays_an_unacknowledged_retry() {
    let (dir, node, session, first) = seeded(CommandStatus::Rejected).await;
    let retry = Retry {
        previous_command_id: "first".into(),
        admission: input("second", first.generation),
    };
    let _ = reserve(&node, "test-user", "creation-1", &retry).unwrap();
    node.db.lock().recover_startup().unwrap();
    assert_eq!(
        node.db.lock().get_command("first").unwrap().status,
        CommandStatus::Rejected
    );
    assert_eq!(
        node.db.lock().get_command("second").unwrap().status,
        CommandStatus::OutcomeUnknown
    );
    let response = attempt_status(
        node.clone(),
        request(Value::Null, "test-user", Some("first")),
    )
    .await
    .unwrap();
    assert_eq!(
        response.body.unwrap()["admission"]["command"]["status"],
        "rejected"
    );
    let lease = node.db.lock().get_lease(&session).unwrap();
    let _ = reserve(&node, "test-user", "creation-1", &retry).unwrap();
    assert_eq!(node.db.lock().get_lease(&session).unwrap(), lease);
    assert!(node.runners.get(&session).is_none());
    node.close().await;
    drop(dir);
}
#[test]
fn schema_2008_migration_keeps_command_and_stop_history() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("node.sqlite");
    {
        let db = Db::open(&path).unwrap();
        let conn = db.lock();
        conn.execute("INSERT INTO creation_initial_admissions(owner_user,operation_id,session_id,command_id,input_hash,stop_requested,created_at,updated_at) VALUES('alice','op','session','first','hash',1,1,1)",[]).unwrap();
        conn.execute_batch(concat!(include_str!("../../../host_commands/remove_approval.sql"), "DROP TRIGGER browser_groups_identity; DROP TRIGGER browser_groups_terminal; DROP TRIGGER browser_groups_retained; DROP TABLE browser_groups; DROP TRIGGER terminal_runs_identity; DROP TRIGGER terminal_runs_terminal; DROP TRIGGER terminal_runs_retained; DROP TABLE terminal_runs; DROP TRIGGER host_resources_immutable; DROP TRIGGER host_resources_retained; DROP TABLE host_command_resources; DROP INDEX host_commands_pending; DROP TRIGGER host_command_identity; DROP TRIGGER host_command_terminal; DROP TRIGGER host_command_retained; DROP TABLE host_command_runs; DROP TRIGGER sandbox_launch_identity; DROP TRIGGER sandbox_kernel_identity; DROP TRIGGER sandbox_launch_terminal; DROP TRIGGER sandbox_launch_retained; DROP TABLE sandbox_launches; DROP TRIGGER execution_fence_identity; DROP TRIGGER execution_fence_retained; DROP TRIGGER execution_fence_session_deleted; DROP INDEX execution_fence_active; DROP TABLE execution_fences; DROP TRIGGER upload_origin_capture; DROP TRIGGER upload_origin_immutable; DROP TRIGGER upload_origin_remove; DROP TRIGGER upload_record_immutable; DROP TABLE upload_origins; DROP TRIGGER command_environment_immutable; DROP TABLE command_environments; DROP TABLE creation_admission_attempts; PRAGMA user_version=2008;"))
            .unwrap();
    }
    let db = Db::open(&path).unwrap();
    let conn = db.lock();
    assert_eq!(count(&conn, "creation_admission_attempts"), 1);
    let (id,stop):(String,bool)=conn.query_row("SELECT command_id,stop_requested FROM creation_initial_admissions WHERE operation_id='op'",[],|r|Ok((r.get(0)?,r.get(1)?))).unwrap();
    assert_eq!(id, "first");
    assert!(stop);
}
