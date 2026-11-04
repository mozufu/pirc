use super::*;
use crate::{
    router::Body,
    store::{Db, ModeId},
};
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
                url: format!("/api/session-creations/{op}/cancel"),
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
#[test]
fn cancellation_before_allocation_is_durable_and_never_creates_storage_or_a_session() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("node.sqlite");
    let db = Db::open(&path).unwrap();
    setup(&db.lock());
    let row = fence(&mut db.lock(), "alice", &input()).unwrap();
    assert!(row.complete);
    assert!(row.session_id.is_none());
    drop(db);
    let db = Db::open(&path).unwrap();
    assert!(
        read(&db.lock(), "alice", "creation-1")
            .unwrap()
            .unwrap()
            .complete
    );
    assert_eq!(
        super::super::reserve(&mut db.lock(), "alice", &input())
            .unwrap_err()
            .code,
        "creation_cancelled"
    );
    assert_eq!(
        super::super::initialize(&mut db.lock(), "alice", &input(), dir.path())
            .unwrap_err()
            .code,
        "creation_cancelled"
    );
    assert_eq!(count(&db.lock(), "sessions"), 0);
    assert_eq!(count(&db.lock(), "session_creations"), 0);
    let mut changed = input();
    changed.submission_hash = "b".repeat(64);
    assert_eq!(
        fence(&mut db.lock(), "alice", &changed).unwrap_err().status,
        409
    );
    assert!(super::super::reserve(&mut db.lock(), "bob", &input()).is_ok());
}
#[test]
fn independent_connections_serialize_cancellation_with_allocation() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("node.sqlite");
    let db = Db::open(&path).unwrap();
    setup(&db.lock());
    drop(db);
    let barrier = std::sync::Barrier::new(2);
    std::thread::scope(|scope| {
        let init = scope.spawn(|| {
            let db = Db::open(&path).unwrap();
            barrier.wait();
            let _ = super::super::reserve(&mut db.lock(), "alice", &input());
            let _ = super::super::initialize(&mut db.lock(), "alice", &input(), dir.path());
        });
        let cancel = scope.spawn(|| {
            let db = Db::open(&path).unwrap();
            barrier.wait();
            fence(&mut db.lock(), "alice", &input()).unwrap();
        });
        init.join().unwrap();
        cancel.join().unwrap();
    });
    let db = Db::open(&path).unwrap();
    assert!(require_live(&db.lock(), "alice", &input()).is_err());
    let row = super::super::read(&db.lock(), "alice", "creation-1").unwrap();
    if let Some(row) = row {
        assert!(matches!(
            current(&db.lock(), "alice", row).unwrap().state,
            State::Deleting | State::Deleted
        ));
    }
}
#[tokio::test]
async fn ready_cancellation_deletes_only_owned_session_data_and_never_the_workspace() {
    let (_dir, node, session) = super::super::uploads::tests::node().await;
    let workspace = node.db.lock().get_workspace("repo").unwrap();
    let sentinel = std::path::Path::new(&workspace.canonical_path).join("keep.txt");
    std::fs::write(&sentinel, "user file").unwrap();
    let private = node
        .db
        .lock()
        .get_session(&session)
        .unwrap()
        .private_session_path;
    std::fs::write(
        std::path::Path::new(&private).join("session.jsonl"),
        "owned transcript",
    )
    .unwrap();
    let response = call(&node, HttpMethod::Post, "creation-1", "test-user").await;
    assert_eq!(response.status, 200, "{response:?}");
    assert_eq!(response.body.unwrap()["cancellation"]["complete"], true);
    assert!(!std::path::Path::new(&private).exists());
    assert_eq!(std::fs::read_to_string(sentinel).unwrap(), "user file");
    assert!(node.db.lock().get_session(&session).is_err());
    assert_eq!(
        call(&node, HttpMethod::Get, "creation-1", "another-user")
            .await
            .status,
        403
    );
    assert_eq!(
        call(&node, HttpMethod::Post, "creation-1", "test-user")
            .await
            .status,
        200
    );
    assert!(
        read(&node.db.lock(), "another-user", "creation-1")
            .unwrap()
            .is_none()
    );
    let mut req = crate::router::Request {
        method: HttpMethod::Post,
        path: String::new(),
        query: vec![],
        params: vec![],
        user: "test-user".into(),
        body: Body::Json(
            json!({"operationId":"creation-1","workspaceId":"repo","submissionHash":"a".repeat(64)}),
        ),
    };
    assert_eq!(
        super::super::prepare(node.clone(), req.clone())
            .await
            .unwrap_err()
            .code,
        "creation_cancelled"
    );
    req.body = Body::Json(
        json!({"commandId":"late","submissionHash":"a".repeat(64),"model":{"provider":"fake","id":"m"},"thinking":"low","message":"never","clientId":"phone","generation":1}),
    );
    req.params = vec![("id".into(), "creation-1".into())];
    assert_eq!(
        super::super::admission::submit(node.clone(), req)
            .await
            .unwrap()
            .body
            .unwrap()["admission"]["state"],
        "deleted"
    );
    assert!(node.runners.get(&session).is_none());
    node.close().await;
}
#[tokio::test]
async fn missing_mode_keeps_cleanup_pending_but_fences_the_session_and_retry_finishes() {
    let (_dir, node, session) = super::super::uploads::tests::node().await;
    let modes = node.modes.read().unwrap().clone();
    node.modes.write().unwrap().clear();
    let response = call(&node, HttpMethod::Post, "creation-1", "test-user").await;
    assert_eq!(response.status, 200, "{response:?}");
    assert_eq!(response.body.unwrap()["cancellation"]["complete"], false);
    assert!(node.db.lock().require_session_available(&session).is_err());
    *node.modes.write().unwrap() = modes;
    let response = call(&node, HttpMethod::Post, "creation-1", "test-user").await;
    assert_eq!(response.body.unwrap()["cancellation"]["complete"], true);
    node.close().await;
}
#[tokio::test]
async fn a_reserved_crash_orphan_is_removed_only_when_empty() {
    let (_dir, node, _session) = super::super::uploads::tests::node().await;
    let mut original = input();
    original.operation_id = "reserved".into();
    let row = super::super::reserve(&mut node.db.lock(), "test-user", &original).unwrap();
    let path = node.config.sessions_dir.join(&row.session_id);
    std::fs::create_dir(&path).unwrap();
    std::fs::write(path.join("keep.txt"), "unexpected data").unwrap();
    let first = call(&node, HttpMethod::Post, "reserved", "test-user").await;
    assert_eq!(first.body.unwrap()["cancellation"]["complete"], false);
    assert_eq!(
        std::fs::read_to_string(path.join("keep.txt")).unwrap(),
        "unexpected data"
    );
    std::fs::remove_file(path.join("keep.txt")).unwrap();
    let second = call(&node, HttpMethod::Post, "reserved", "test-user").await;
    assert_eq!(second.body.unwrap()["cancellation"]["complete"], true);
    assert!(!path.exists());
    node.close().await;
}
#[test]
fn migration_from_2006_preserves_existing_creation_and_receipts() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("node.sqlite");
    let db = Db::open(&path).unwrap();
    setup(&db.lock());
    let original = super::super::reserve(&mut db.lock(), "alice", &input()).unwrap();
    db.lock()
        .execute_batch(concat!(include_str!("../../host_commands/remove_approval.sql"), "DROP TRIGGER browser_groups_identity; DROP TRIGGER browser_groups_terminal; DROP TRIGGER browser_groups_retained; DROP TABLE browser_groups; DROP TRIGGER terminal_runs_identity; DROP TRIGGER terminal_runs_terminal; DROP TRIGGER terminal_runs_retained; DROP TABLE terminal_runs; DROP TRIGGER host_resources_immutable; DROP TRIGGER host_resources_retained; DROP TABLE host_command_resources; DROP INDEX host_commands_pending; DROP TRIGGER host_command_identity; DROP TRIGGER host_command_terminal; DROP TRIGGER host_command_retained; DROP TABLE host_command_runs; DROP TRIGGER sandbox_launch_identity; DROP TRIGGER sandbox_kernel_identity; DROP TRIGGER sandbox_launch_terminal; DROP TRIGGER sandbox_launch_retained; DROP TABLE sandbox_launches; DROP TRIGGER execution_fence_identity; DROP TRIGGER execution_fence_retained; DROP TRIGGER execution_fence_session_deleted; DROP INDEX execution_fence_active; DROP TABLE execution_fences; DROP TRIGGER upload_origin_capture; DROP TRIGGER upload_origin_immutable; DROP TRIGGER upload_origin_remove; DROP TRIGGER upload_record_immutable; DROP TABLE upload_origins; DROP TRIGGER command_environment_immutable; DROP TABLE command_environments; DROP TABLE creation_admission_attempts; DROP TABLE creation_pre_stops; DROP TABLE creation_cancellations; PRAGMA user_version=2006;"))
        .unwrap();
    drop(db);
    let db = Db::open(&path).unwrap();
    assert_eq!(
        super::super::read(&db.lock(), "alice", "creation-1")
            .unwrap()
            .unwrap()
            .session_id,
        original.session_id
    );
    assert_eq!(count(&db.lock(), "creation_cancellations"), 0);
}
