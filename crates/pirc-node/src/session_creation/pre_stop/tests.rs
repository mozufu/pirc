use super::*;
use crate::store::{Db, ModeId};
use pirc_protocol::{HttpMethod, NodeHttpRequest};
fn input() -> Input {
    Input {
        operation_id: "creation-1".into(),
        workspace_id: "repo".into(),
        submission_hash: "a".repeat(64),
    }
}
fn setup(db: &Connection) {
    db.add_workspace(
        "repo",
        "node",
        "Repo",
        "/repo",
        ModeId::new("directory").unwrap(),
    )
    .unwrap();
}
fn count(db: &Connection, table: &str) -> i64 {
    db.query_row(&format!("SELECT count(*) FROM {table}"), [], |r| r.get(0))
        .unwrap()
}
fn flags(db: &Connection, session: &str) -> (bool, bool) {
    db.query_row(
        "SELECT stop_requested,stop_confirmed FROM creation_initial_admissions WHERE session_id=?1",
        [session],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )
    .unwrap()
}
fn ready(db: &mut Connection, path: &Path) -> Creation {
    setup(db);
    super::super::reserve(db, "alice", &input()).unwrap();
    super::super::initialize(db, "alice", &input(), path).unwrap()
}
fn initial(db: &Connection, row: &Creation) {
    db.receive_command(
        "first-command",
        &row.session_id,
        "h",
        &json!({"type":"prompt","message":"first"}),
    )
    .unwrap();
    db.execute("INSERT INTO creation_initial_admissions(owner_user,operation_id,session_id,command_id,input_hash,created_at,updated_at) VALUES('alice','creation-1',?1,'first-command','hash',1,1)",[&row.session_id]).unwrap();
}
#[test]
fn stop_before_allocation_survives_reopen_without_a_session_or_storage() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("node.sqlite");
    let db = Db::open(&path).unwrap();
    setup(&db.lock());
    let row = fence(&mut db.lock(), "alice", &input()).unwrap();
    assert!(row.confirmed);
    assert!(row.session_id.is_none());
    for table in [
        "session_creations",
        "sessions",
        "commands",
        "creation_initial_admissions",
        "runs",
        "uploads",
    ] {
        assert_eq!(count(&db.lock(), table), 0);
    }
    drop(db);
    let db = Db::open(&path).unwrap();
    assert!(
        read(&db.lock(), "alice", "creation-1")
            .unwrap()
            .unwrap()
            .confirmed
    );
    assert!(read(&db.lock(), "bob", "creation-1").unwrap().is_none());
    assert!(
        fence(&mut db.lock(), "alice", &input())
            .unwrap()
            .session_id
            .is_none()
    );
    assert_eq!(count(&db.lock(), "creation_pre_stops"), 1);
    assert!(
        !dir.path()
            .read_dir()
            .unwrap()
            .any(|r| r.unwrap().file_type().unwrap().is_dir())
    );
}
#[test]
fn later_explicit_allocation_prepares_blank_storage_but_cannot_admit_the_old_first_message() {
    let db = Db::memory();
    let dir = tempfile::tempdir().unwrap();
    setup(&db.lock());
    fence(&mut db.lock(), "alice", &input()).unwrap();
    let row = super::super::reserve(&mut db.lock(), "alice", &input()).unwrap();
    assert_eq!(flags(&db.lock(), &row.session_id), (true, true));
    assert_eq!(count(&db.lock(), "sessions"), 0);
    assert!(!dir.path().join(&row.session_id).exists());
    let row = super::super::initialize(&mut db.lock(), "alice", &input(), dir.path()).unwrap();
    assert_eq!(row.state, State::Ready);
    assert_eq!(count(&db.lock(), "sessions"), 1);
    assert!(super::super::admission::require_generic(&db.lock(), &row.session_id).is_ok());
    assert_eq!(
        super::super::admission::require_sendable(
            &db.lock(),
            &row.session_id,
            "first-command",
            "alice"
        )
        .unwrap_err()
        .code,
        "first_message_stopped"
    );
    assert_eq!(count(&db.lock(), "commands"), 0);
    assert_eq!(count(&db.lock(), "runs"), 0);
}
#[test]
fn a_reserved_creation_can_be_stopped_without_publishing_storage() {
    let db = Db::memory();
    setup(&db.lock());
    let row = super::super::reserve(&mut db.lock(), "alice", &input()).unwrap();
    assert_eq!(
        fence(&mut db.lock(), "alice", &input())
            .unwrap()
            .session_id
            .as_deref(),
        Some(row.session_id.as_str())
    );
    assert_eq!(flags(&db.lock(), &row.session_id), (true, true));
    assert_eq!(count(&db.lock(), "sessions"), 0);
    assert_eq!(count(&db.lock(), "commands"), 0);
}
#[test]
fn stopping_a_ready_creation_preserves_history_files_and_workspace_contents() {
    let db = Db::memory();
    let dir = tempfile::tempdir().unwrap();
    let row = ready(&mut db.lock(), dir.path());
    let storage = dir.path().join(&row.session_id);
    std::fs::write(storage.join("session.jsonl"), "existing history").unwrap();
    std::fs::write(dir.path().join("user-sentinel"), "keep").unwrap();
    fence(&mut db.lock(), "alice", &input()).unwrap();
    assert_eq!(
        std::fs::read_to_string(storage.join("session.jsonl")).unwrap(),
        "existing history"
    );
    assert_eq!(
        std::fs::read_to_string(dir.path().join("user-sentinel")).unwrap(),
        "keep"
    );
    assert_eq!(count(&db.lock(), "sessions"), 1);
    assert_eq!(count(&db.lock(), "session_deletions"), 0);
    assert_eq!(count(&db.lock(), "workspace_deletions"), 0);
}
#[test]
fn an_existing_initial_command_is_never_misreported_as_a_pre_admission_stop() {
    let db = Db::memory();
    let dir = tempfile::tempdir().unwrap();
    let row = ready(&mut db.lock(), dir.path());
    initial(&db.lock(), &row);
    let error = fence(&mut db.lock(), "alice", &input()).unwrap_err();
    assert_eq!(error.code, "initial_admission_exists");
    assert_eq!(count(&db.lock(), "creation_pre_stops"), 0);
    assert_eq!(flags(&db.lock(), &row.session_id), (false, false));
    assert_eq!(
        db.lock().get_command("first-command").unwrap().status,
        crate::store::CommandStatus::Received
    );
}
#[test]
fn an_already_confirmed_ordinary_stop_is_reused_and_never_aborts_later_work() {
    let db = Db::memory();
    let dir = tempfile::tempdir().unwrap();
    let row = ready(&mut db.lock(), dir.path());
    initial(&db.lock(), &row);
    super::super::admission::request_stop(&db.lock(), &row.session_id, "alice").unwrap();
    super::super::admission::confirm_stop(&db.lock(), &row.session_id).unwrap();
    db.lock()
        .receive_command(
            "later-message",
            &row.session_id,
            "later",
            &json!({"type":"prompt","message":"new user work"}),
        )
        .unwrap();
    let before = db.lock().get_command("later-message").unwrap();
    fence(&mut db.lock(), "alice", &input()).unwrap();
    fence(&mut db.lock(), "alice", &input()).unwrap();
    assert_eq!(db.lock().get_command("later-message").unwrap(), before);
    assert_eq!(count(&db.lock(), "commands"), 2);
    assert_eq!(count(&db.lock(), "creation_pre_stops"), 1);
}
#[test]
fn a_stopped_identity_rejects_a_changed_manifest_or_workspace() {
    let db = Db::memory();
    setup(&db.lock());
    fence(&mut db.lock(), "alice", &input()).unwrap();
    for field in ["workspace", "hash"] {
        let mut changed = input();
        if field == "workspace" {
            changed.workspace_id = "other".into();
        } else {
            changed.submission_hash = "b".repeat(64);
        }
        assert_eq!(
            fence(&mut db.lock(), "alice", &changed).unwrap_err().status,
            409
        );
        assert_eq!(
            super::super::reserve(&mut db.lock(), "alice", &changed)
                .unwrap_err()
                .status,
            409
        );
    }
    assert!(fence(&mut db.lock(), "bob", &input()).is_ok());
}
#[test]
fn reservation_and_stop_serialize_across_independent_connections() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("node.sqlite");
    let db = Db::open(&path).unwrap();
    setup(&db.lock());
    drop(db);
    let barrier = std::sync::Barrier::new(2);
    std::thread::scope(|scope| {
        let allocation = scope.spawn(|| {
            let db = Db::open(&path).unwrap();
            barrier.wait();
            super::super::reserve(&mut db.lock(), "alice", &input()).unwrap();
            super::super::initialize(&mut db.lock(), "alice", &input(), dir.path()).unwrap();
        });
        let stop = scope.spawn(|| {
            let db = Db::open(&path).unwrap();
            barrier.wait();
            fence(&mut db.lock(), "alice", &input()).unwrap();
        });
        allocation.join().unwrap();
        stop.join().unwrap();
    });
    let db = Db::open(&path).unwrap();
    let row = read(&db.lock(), "alice", "creation-1").unwrap().unwrap();
    assert_eq!(
        flags(&db.lock(), row.session_id.as_deref().unwrap()),
        (true, true)
    );
    assert_eq!(count(&db.lock(), "commands"), 0);
}
#[test]
fn malformed_input_cannot_install_a_fence() {
    let db = Db::memory();
    setup(&db.lock());
    let mut malformed = input();
    malformed.operation_id = "../other".into();
    assert_eq!(
        fence(&mut db.lock(), "alice", &malformed)
            .unwrap_err()
            .status,
        400
    );
    let mut malformed = input();
    malformed.submission_hash = "not-a-hash".into();
    assert_eq!(
        fence(&mut db.lock(), "alice", &malformed)
            .unwrap_err()
            .status,
        400
    );
    assert_eq!(count(&db.lock(), "creation_pre_stops"), 0);
}
#[test]
fn a_stop_does_not_rebind_a_previously_cancelled_creation() {
    let db = Db::memory();
    setup(&db.lock());
    db.lock().execute("INSERT INTO creation_cancellations(owner_user,operation_id,workspace_id,submission_hash,complete,created_at,updated_at) VALUES('alice','creation-1','repo',?1,1,1,1)", [input().submission_hash]).unwrap();
    let mut different = input();
    different.submission_hash = "b".repeat(64);
    assert_eq!(
        fence(&mut db.lock(), "alice", &different)
            .unwrap_err()
            .status,
        409
    );
    assert!(fence(&mut db.lock(), "alice", &input()).unwrap().confirmed);
    assert_eq!(
        super::super::reserve(&mut db.lock(), "alice", &input())
            .unwrap_err()
            .code,
        "creation_cancelled"
    );
}
async fn call(
    node: &Node,
    method: HttpMethod,
    op: &str,
    user: &str,
) -> pirc_protocol::NodeHttpResponse {
    node.router
        .handle(
            node,
            NodeHttpRequest {
                method,
                url: format!("/api/session-creations/{op}/stop"),
                user: user.into(),
                payload: if method == HttpMethod::Post {
                    Some(json!({"workspaceId":"repo","submissionHash":"a".repeat(64)}))
                } else {
                    None
                },
                body_base64: None,
                content_type: None,
            },
        )
        .await
}
#[tokio::test]
async fn http_stop_and_status_require_the_same_owner_and_do_not_start_a_runner() {
    let (_dir, node, _session) = super::super::uploads::tests::node().await;
    assert_eq!(
        call(&node, HttpMethod::Get, "never-created", "test-user")
            .await
            .status,
        404
    );
    let response = call(&node, HttpMethod::Post, "never-created", "test-user").await;
    assert_eq!(response.status, 200, "{response:?}");
    let proof = &response.body.unwrap()["stop"];
    assert_eq!(proof["confirmed"], true);
    assert!(proof["sessionId"].is_null());
    assert_eq!(
        call(&node, HttpMethod::Get, "never-created", "test-user")
            .await
            .status,
        200
    );
    assert_eq!(
        call(&node, HttpMethod::Get, "never-created", "other-user")
            .await
            .status,
        403
    );
    assert_eq!(count(&node.db.lock(), "runs"), 0);
    assert_eq!(count(&node.db.lock(), "commands"), 0);
}
#[tokio::test]
async fn delayed_initial_admission_is_fenced_without_model_inference_or_a_lease() {
    let (_dir, node, session) = super::super::uploads::tests::node().await;
    assert_eq!(
        call(&node, HttpMethod::Post, "creation-1", "test-user")
            .await
            .status,
        200
    );
    let response=node.router.handle(&node,NodeHttpRequest { method:HttpMethod::Post,url:"/api/session-creations/creation-1/admission".into(),user:"test-user".into(),payload:Some(json!({"commandId":"first-message","submissionHash":"a".repeat(64),"model":{"provider":"fake","id":"m"},"thinking":"low","message":"late first prompt","uploadIds":[],"clientId":"phone","generation":1})),body_base64:None,content_type:None }).await;
    assert_eq!(response.status, 200, "{response:?}");
    assert_eq!(response.body.unwrap()["admission"]["state"], "stopped");
    assert!(node.runners.get(&session).is_none());
    assert_eq!(count(&node.db.lock(), "commands"), 0);
}

#[test]
fn private_recovery_workspace_owner_is_checked_before_creating_any_fence() {
    let db = Db::memory();
    setup(&db.lock());
    db.lock().execute("INSERT INTO checkpoint_intents(job,owner,source_session,capture,expected_revision,accept_unresolved,scope_json,created_at) VALUES('job','alice','source','capture',1,0,'[]',0)", []).unwrap();
    db.lock().execute("INSERT INTO checkpoint_workspaces(workspace_id,job,owner,session_id,created_at) VALUES('repo','job','alice','recovery',0)", []).unwrap();
    assert_eq!(
        fence(&mut db.lock(), "bob", &input()).unwrap_err().status,
        404
    );
    assert_eq!(count(&db.lock(), "creation_pre_stops"), 0);
    assert!(fence(&mut db.lock(), "alice", &input()).unwrap().confirmed);
}
#[test]
fn a_conflicting_existing_session_owner_cannot_be_stopped() {
    let db = Db::memory();
    let dir = tempfile::tempdir().unwrap();
    let row = ready(&mut db.lock(), dir.path());
    db.lock()
        .execute(
            "UPDATE sessions SET owner_user='bob' WHERE id=?1",
            [&row.session_id],
        )
        .unwrap();
    assert_eq!(
        fence(&mut db.lock(), "alice", &input()).unwrap_err().status,
        403
    );
    assert_eq!(count(&db.lock(), "creation_pre_stops"), 0);
    assert_eq!(count(&db.lock(), "creation_initial_admissions"), 0);
}
#[test]
fn initial_intake_and_stop_have_one_winner_across_independent_connections() {
    // Use separate SQLite connections to exercise the write transaction that
    // protects mirror + initial command intake, rather than just a Rust mutex.
    for _ in 0..8 {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("node.sqlite");
        let db = Db::open(&path).unwrap();
        let creation = ready(&mut db.lock(), dir.path());
        drop(db);
        let barrier = std::sync::Barrier::new(2);
        let (intake, stopped) = std::thread::scope(|scope| {
            let intake = scope.spawn(|| {
                let db = Db::open(&path).unwrap();
                barrier.wait();
                let mut conn = db.lock();
                let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate).unwrap();
                mirror(&tx, "alice", &creation).unwrap();
                let is_stopped: bool = tx.query_row("SELECT EXISTS(SELECT 1 FROM creation_initial_admissions WHERE owner_user='alice' AND operation_id='creation-1' AND stop_requested=1)", [], |r| r.get(0)).unwrap();
                if !is_stopped { initial(&tx, &creation); }
                tx.commit().unwrap();
                !is_stopped
            });
            let stopped = scope.spawn(|| {
                let db = Db::open(&path).unwrap();
                barrier.wait();
                fence(&mut db.lock(), "alice", &input())
            });
            (intake.join().unwrap(), stopped.join().unwrap())
        });
        let db = Db::open(&path).unwrap();
        if intake {
            assert_eq!(stopped.unwrap_err().code, "initial_admission_exists");
            assert_eq!(count(&db.lock(), "commands"), 1);
            assert_eq!(count(&db.lock(), "creation_pre_stops"), 0);
            assert_eq!(flags(&db.lock(), &creation.session_id), (false, false));
        } else {
            assert!(stopped.unwrap().confirmed);
            assert_eq!(count(&db.lock(), "commands"), 0);
            assert_eq!(count(&db.lock(), "creation_pre_stops"), 1);
            assert_eq!(flags(&db.lock(), &creation.session_id), (true, true));
        }
    }
}
#[tokio::test]
async fn stop_still_fences_when_workspace_mode_is_no_longer_available() {
    let (_dir, node, session) = super::super::uploads::tests::node().await;
    node.db
        .lock()
        .execute(
            "UPDATE workspaces SET kind='no-longer-configured' WHERE id='repo'",
            [],
        )
        .unwrap();
    let response = call(&node, HttpMethod::Post, "creation-1", "test-user").await;
    assert_eq!(response.status, 200, "{response:?}");
    assert_eq!(flags(&node.db.lock(), &session), (true, true));
    assert!(node.runners.get(&session).is_none());
    assert_eq!(count(&node.db.lock(), "commands"), 0);
}

#[tokio::test]
async fn cancellation_after_a_pre_allocation_stop_cannot_rebind_the_manifest() {
    let (_dir, node, _session) = super::super::uploads::tests::node().await;
    assert_eq!(
        call(&node, HttpMethod::Post, "never-created", "test-user")
            .await
            .status,
        200
    );
    for (hash, expected) in [("b".repeat(64), 409), ("a".repeat(64), 200)] {
        let response = node
            .router
            .handle(
                &node,
                NodeHttpRequest {
                    method: HttpMethod::Post,
                    url: "/api/session-creations/never-created/cancel".into(),
                    user: "test-user".into(),
                    payload: Some(json!({"workspaceId":"repo","submissionHash":hash})),
                    body_base64: None,
                    content_type: None,
                },
            )
            .await;
        assert_eq!(response.status, expected, "{response:?}");
    }
    assert_eq!(count(&node.db.lock(), "creation_pre_stops"), 1);
    assert_eq!(count(&node.db.lock(), "creation_cancellations"), 1);
    let input = Input {
        operation_id: "never-created".into(),
        ..input()
    };
    assert_eq!(
        super::super::reserve(&mut node.db.lock(), "test-user", &input)
            .unwrap_err()
            .code,
        "creation_cancelled"
    );
}
