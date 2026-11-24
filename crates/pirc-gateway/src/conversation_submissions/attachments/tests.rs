use super::super::tests::{app, count, disk_app, input};
use super::*;
use crate::db::Db;

fn prepared(app: &AppState) -> Input {
    let mut input = input();
    input.submission.attachments[0].sha256 = sha256_hex(b"test");
    reserve(&mut app.db.lock(), "alice", &input).unwrap();
    input
}
fn file(app: &AppState, operation: &str) -> PathBuf {
    let row = lookup(&app.db.lock(), "alice", operation).unwrap();
    root(app).join(row.session_id).join("file-1.bin")
}
#[test]
fn immutable_file_retries_and_receipts_survive_response_loss_and_restart() {
    let (app, _dir) = disk_app();
    let path = app.config.state_dir.join("gateway.sqlite");
    prepared(&app);
    let first = stage(&app, "alice", "draft-1", "file-1", b"test").unwrap();
    assert_eq!(first.staged_attachment_ids, ["file-1"]);
    let location = file(&app, "draft-1");
    assert_eq!(fs::read(&location).unwrap(), b"test");
    stage(&app, "alice", "draft-1", "file-1", b"test").unwrap();
    assert_eq!(
        count(&app.db.lock(), "conversation_submission_attachments"),
        1
    );
    assert_eq!(fs::read_dir(location.parent().unwrap()).unwrap().count(), 1);
    assert_eq!(count(&app.db.lock(), "sessions"), 0);
    assert_eq!(count(&app.db.lock(), "commands"), 0);
    let reopened = Db::open(&path).unwrap();
    assert_eq!(
        lookup(&reopened.lock(), "alice", "draft-1")
            .unwrap()
            .staged_attachment_ids,
        ["file-1"]
    );
    assert_eq!(
        fs::metadata(&location).unwrap().permissions().mode() & 0o777,
        0o600
    );
    assert_eq!(
        fs::metadata(location.parent().unwrap())
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o700
    );
}
#[test]
fn wrong_owner_manifest_size_or_checksum_never_writes_a_file() {
    let (app, _dir) = app();
    prepared(&app);
    for (owner, id, bytes, status) in [
        ("bob", "file-1", b"test".as_slice(), 404),
        ("alice", "missing", b"test".as_slice(), 404),
        ("alice", "file-1", b"bad!".as_slice(), 409),
        ("alice", "file-1", b"bad".as_slice(), 409),
    ] {
        assert_eq!(
            stage(&app, owner, "draft-1", id, bytes).unwrap_err().status,
            status
        );
    }
    assert!(!root(&app).exists());
    assert_eq!(
        count(&app.db.lock(), "conversation_submission_attachments"),
        0
    );
}
#[test]
fn crash_after_complete_file_before_receipt_is_adopted_without_overwriting() {
    let (app, _dir) = app();
    prepared(&app);
    stage(&app, "alice", "draft-1", "file-1", b"test").unwrap();
    app.db
        .lock()
        .execute("DELETE FROM conversation_submission_attachments", [])
        .unwrap();
    let location = file(&app, "draft-1");
    let before = fs::metadata(&location).unwrap().modified().unwrap();
    stage(&app, "alice", "draft-1", "file-1", b"test").unwrap();
    assert_eq!(fs::metadata(&location).unwrap().modified().unwrap(), before);
    assert_eq!(
        count(&app.db.lock(), "conversation_submission_attachments"),
        1
    );
    // Unexpected content is left intact, rather than silently replaced.
    fs::write(&location, b"oops").unwrap();
    assert_eq!(
        stage(&app, "alice", "draft-1", "file-1", b"test")
            .unwrap_err()
            .status,
        503
    );
    assert_eq!(fs::read(&location).unwrap(), b"oops");
    assert!(
        lookup(&app.db.lock(), "alice", "draft-1")
            .unwrap()
            .staged_attachment_ids
            .is_empty()
    );
}
#[test]
fn cancellation_keeps_a_durable_cleanup_job_and_retry_cannot_revive_files() {
    let (app, _dir) = app();
    prepared(&app);
    stage(&app, "alice", "draft-1", "file-1", b"test").unwrap();
    let location = file(&app, "draft-1");
    let cancelled = cancel(&app.db.lock(), "alice", "draft-1").unwrap();
    assert!(cancelled.cleanup_pending);
    assert!(cancelled.staged_attachment_ids.is_empty());
    assert!(location.exists());
    assert_eq!(sweep(&app, now_ms()).unwrap(), 1);
    assert!(!location.exists());
    assert!(
        !lookup(&app.db.lock(), "alice", "draft-1")
            .unwrap()
            .cleanup_pending
    );
    assert_eq!(
        stage(&app, "alice", "draft-1", "file-1", b"test")
            .unwrap_err()
            .status,
        409
    );
    assert!(!location.exists());
    cancel(&app.db.lock(), "alice", "draft-1").unwrap();
    assert_eq!(sweep(&app, now_ms()).unwrap(), 0);
}
#[test]
fn seven_day_expiry_removes_only_unaccepted_bytes_and_preserves_the_draft() {
    let (app, _dir) = app();
    let input = prepared(&app);
    stage(&app, "alice", "draft-1", "file-1", b"test").unwrap();
    let location = file(&app, "draft-1");
    let deadline = lookup(&app.db.lock(), "alice", "draft-1")
        .unwrap()
        .attachments_expires_at
        .unwrap();
    assert!(deadline >= now_ms() + RETENTION_MS - 1000);
    assert_eq!(sweep(&app, deadline - 1).unwrap(), 0);
    assert!(location.exists());
    assert_eq!(sweep(&app, deadline).unwrap(), 1);
    assert!(!location.exists());
    let row = lookup(&app.db.lock(), "alice", "draft-1").unwrap();
    assert_eq!(row.state, Phase::Preparing);
    assert_eq!(row.submission.unwrap().message, input.submission.message);
    assert!(row.staged_attachment_ids.is_empty());
    assert_eq!(row.attachments_expired_at, Some(deadline));
    let restaged = stage(&app, "alice", "draft-1", "file-1", b"test").unwrap();
    assert_eq!(restaged.staged_attachment_ids, ["file-1"]);
    assert!(restaged.attachments_expired_at.is_none());
}
#[test]
fn expiry_cleans_an_unreceipted_crash_orphan_too() {
    let (app, _dir) = app();
    prepared(&app);
    stage(&app, "alice", "draft-1", "file-1", b"test").unwrap();
    app.db
        .lock()
        .execute("DELETE FROM conversation_submission_attachments", [])
        .unwrap();
    let location = file(&app, "draft-1");
    let dir = location.parent().unwrap();
    fs::write(
        dir.join(".file-1.01234567-89ab-cdef-0123-456789abcdef.part"),
        b"partial",
    )
    .unwrap();
    let deadline = lookup(&app.db.lock(), "alice", "draft-1")
        .unwrap()
        .attachments_expires_at
        .unwrap();
    assert_eq!(sweep(&app, deadline).unwrap(), 1);
    assert!(!dir.exists());
}
#[test]
fn cleanup_refuses_unknown_files_and_symlinked_directories() {
    use std::os::unix::fs::symlink;
    let (app, dir) = app();
    prepared(&app);
    stage(&app, "alice", "draft-1", "file-1", b"test").unwrap();
    let location = file(&app, "draft-1");
    let unknown = location.parent().unwrap().join("user.txt");
    fs::write(&unknown, b"user data").unwrap();
    cancel(&app.db.lock(), "alice", "draft-1").unwrap();
    assert_eq!(sweep(&app, now_ms()).unwrap(), 0);
    assert!(location.exists());
    assert_eq!(fs::read(&unknown).unwrap(), b"user data");
    fs::remove_file(&unknown).unwrap();
    fs::remove_file(&location).unwrap();
    fs::remove_dir(location.parent().unwrap()).unwrap();
    let outside = dir.path().join("outside");
    fs::create_dir(&outside).unwrap();
    fs::write(outside.join("file-1.bin"), b"user data").unwrap();
    symlink(&outside, location.parent().unwrap()).unwrap();
    assert_eq!(sweep(&app, now_ms()).unwrap(), 0);
    assert_eq!(fs::read(outside.join("file-1.bin")).unwrap(), b"user data");
}
#[test]
fn deleted_workspaces_queue_bytes_without_touching_other_operations() {
    let (app, _dir) = app();
    prepared(&app);
    stage(&app, "alice", "draft-1", "file-1", b"test").unwrap();
    let first = file(&app, "draft-1");
    let mut other = input();
    other.operation_id = "other".into();
    other.submission.workspace_id = "node:other".into();
    other.submission.attachments[0].sha256 = sha256_hex(b"test");
    reserve(&mut app.db.lock(), "alice", &other).unwrap();
    stage(&app, "alice", "other", "file-1", b"test").unwrap();
    let kept = file(&app, "other");
    app.db
        .lock()
        .begin_workspace_deletion("node:repo", "alice")
        .unwrap();
    sweep(&app, now_ms()).unwrap();
    assert!(!first.exists());
    assert_eq!(fs::read(&kept).unwrap(), b"test");
}

fn separate_connection(app: &AppState) -> AppState {
    crate::app::App::new(
        app.config.clone(),
        Arc::new(Db::open(&app.config.database_path).unwrap()),
        app.backends.clone(),
        crate::app::test_modes(),
    )
}
#[test]
fn independent_connections_upload_once_and_cancellation_wins_without_revival() {
    let (app, _dir) = disk_app();
    prepared(&app);
    let apps = (0..4)
        .map(|_| separate_connection(&app))
        .collect::<Vec<_>>();
    let barrier = std::sync::Barrier::new(4);
    std::thread::scope(|scope| {
        let handles = apps
            .iter()
            .map(|app| {
                scope.spawn(|| {
                    barrier.wait();
                    stage(app, "alice", "draft-1", "file-1", b"test").unwrap();
                })
            })
            .collect::<Vec<_>>();
        for handle in handles {
            handle.join().unwrap();
        }
    });
    let location = file(&app, "draft-1");
    assert_eq!(fs::read_dir(location.parent().unwrap()).unwrap().count(), 1);
    assert_eq!(
        count(&app.db.lock(), "conversation_submission_attachments"),
        1
    );
    let barrier = std::sync::Barrier::new(2);
    std::thread::scope(|scope| {
        let upload = scope.spawn(|| {
            barrier.wait();
            let result = stage(&apps[0], "alice", "draft-1", "file-1", b"test");
            if let Err(error) = result {
                assert_eq!(error.code, "submission_cancelled");
            }
        });
        let discard = scope.spawn(|| {
            barrier.wait();
            cancel(&apps[1].db.lock(), "alice", "draft-1").unwrap();
        });
        upload.join().unwrap();
        discard.join().unwrap();
    });
    assert_eq!(
        lookup(&app.db.lock(), "alice", "draft-1").unwrap().state,
        Phase::Cancelled
    );
    sweep(&app, now_ms()).unwrap();
    assert!(!location.exists());
    assert_eq!(
        count(&app.db.lock(), "conversation_submission_attachments"),
        0
    );
}

#[test]
fn schema_1012_migration_preserves_prepared_identity_and_adds_empty_staging() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("gateway.sqlite");
    let prior = Connection::open(&path).unwrap();
    prior
        .execute_batch(concat!(
            include_str!("../../schema.sql"),
            include_str!("../../calendar/schema.sql"),
            include_str!("../../pots/schema.sql"),
            include_str!("../schema.sql"),
            "PRAGMA user_version=1012;"
        ))
        .unwrap();
    super::super::tests::setup(&prior);
    let input = input();
    prior.execute("INSERT INTO conversation_submissions(owner_user,operation_id,workspace_id,node_id,local_workspace_id,session_id,node_operation_id,command_id,submission_hash,payload_json,state,created_at,updated_at) VALUES('alice','draft-1','node:repo','node','repo','session_previous','creation_previous','command_previous',?1,?2,'preparing',1,1)",params![input.hash(),serde_json::to_string(&input.submission).unwrap()]).unwrap();
    drop(prior);
    let db = Db::open(&path).unwrap();
    let row = reserve(&mut db.lock(), "alice", &input).unwrap();
    assert_eq!(row.session_id, "session_previous");
    assert!(row.staged_attachment_ids.is_empty());
    assert!(row.attachments_expires_at.is_none());
    assert_eq!(count(&db.lock(), "conversation_submission_cleanup"), 0);
    cancel(&db.lock(), "alice", "draft-1").unwrap();
    assert_eq!(count(&db.lock(), "conversation_submission_cleanup"), 1);
}

#[tokio::test]
async fn startup_worker_recovers_cancelled_files_after_database_reopen() {
    let (app, _dir) = disk_app();
    prepared(&app);
    stage(&app, "alice", "draft-1", "file-1", b"test").unwrap();
    let location = file(&app, "draft-1");
    cancel(&app.db.lock(), "alice", "draft-1").unwrap();
    let restarted = separate_connection(&app);
    start_cleanup(&restarted);
    tokio::time::timeout(Duration::from_secs(2), async {
        loop {
            if !lookup(&restarted.db.lock(), "alice", "draft-1")
                .unwrap()
                .cleanup_pending
            {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap();
    assert!(!location.exists());
}

#[tokio::test]
async fn raw_json_attachment_round_trips_through_paired_device_http() {
    use tower::ServiceExt;
    let (app, _dir) = app();
    let (_, token) = app.devices.create("alice", "Android").unwrap();
    let mut input = input();
    let bytes = b"{\"draft\":true}";
    input.submission.attachments[0].name = "data.json".into();
    input.submission.attachments[0].mime_type = "application/json".into();
    input.submission.attachments[0].byte_size = bytes.len() as u64;
    input.submission.attachments[0].sha256 = sha256_hex(bytes);
    reserve(&mut app.db.lock(), "alice", &input).unwrap();
    for (user, content_type, content, expected) in [
        ("bob", "application/octet-stream", bytes.as_slice(), 404),
        ("alice", "application/json", bytes.as_slice(), 400),
        ("alice", "application/octet-stream", b"bad".as_slice(), 409),
        ("native", "application/octet-stream", bytes.as_slice(), 200),
        ("alice", "application/octet-stream", bytes.as_slice(), 200),
    ] {
        let mut request = axum::http::Request::builder()
            .header(crate::capabilities::HEADER, "test/2")
            .method("PUT")
            .uri("/api/conversation-submissions/draft-1/attachments/file-1")
            .header("host", "a.example")
            .header(
                crate::request_shape::REQUEST_HEADER,
                crate::request_shape::REQUEST_VALUE,
            )
            .header("content-type", content_type)
            .extension(axum::extract::ConnectInfo(
                "127.0.0.1:40000".parse::<std::net::SocketAddr>().unwrap(),
            ));
        request = if user == "native" {
            request.header("authorization", format!("Bearer {token}"))
        } else {
            request
                .header("x-pirc-user", user)
                .header("origin", "https://a.example")
        };
        let response = crate::app::router(app.clone())
            .oneshot(
                request
                    .body(axum::body::Body::from(content.to_vec()))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(
            response.status().as_u16(),
            expected,
            "{user} {content_type}"
        );
        if expected == 200 {
            let body = axum::body::to_bytes(response.into_body(), 1024 * 1024)
                .await
                .unwrap();
            let body: Value = serde_json::from_slice(&body).unwrap();
            assert_eq!(
                body["preparation"]["stagedAttachmentIds"],
                json!(["file-1"])
            );
            assert_eq!(body["preparation"]["accepted"], false);
        }
    }
    assert_eq!(fs::read(file(&app, "draft-1")).unwrap(), bytes);
    assert_eq!(count(&app.db.lock(), "sessions"), 0);
}

#[test]
fn failed_cleanup_page_does_not_starve_later_owned_files() {
    let (app, _dir) = app();
    let mut last = None;
    for i in 0..33 {
        let mut input = input();
        input.operation_id = format!("batch-{i}");
        input.submission.attachments[0].sha256 = sha256_hex(b"test");
        reserve(&mut app.db.lock(), "alice", &input).unwrap();
        stage(&app, "alice", &input.operation_id, "file-1", b"test").unwrap();
        let location = file(&app, &input.operation_id);
        if i < 32 {
            fs::write(location.parent().unwrap().join("user.txt"), b"preserve").unwrap();
        } else {
            last = Some(location);
        }
        cancel(&app.db.lock(), "alice", &input.operation_id).unwrap();
        app.db
            .lock()
            .execute(
                "UPDATE conversation_submission_cleanup SET created_at=?1 WHERE operation_id=?2",
                params![i, input.operation_id],
            )
            .unwrap();
    }
    assert_eq!(sweep(&app, 1000).unwrap(), 0);
    assert_eq!(sweep(&app, 1001).unwrap(), 1);
    assert!(!last.unwrap().exists());
    assert_eq!(count(&app.db.lock(), "conversation_submission_cleanup"), 32);
}

#[test]
fn staging_refuses_symlinked_files_and_does_not_modify_their_target() {
    use std::os::unix::fs::symlink;
    let (app, dir) = app();
    prepared(&app);
    stage(&app, "alice", "draft-1", "file-1", b"test").unwrap();
    let location = file(&app, "draft-1");
    fs::remove_file(&location).unwrap();
    let outside = dir.path().join("user-file");
    fs::write(&outside, b"test").unwrap();
    symlink(&outside, &location).unwrap();
    assert_eq!(
        stage(&app, "alice", "draft-1", "file-1", b"test")
            .unwrap_err()
            .status,
        503
    );
    assert_eq!(fs::read(&outside).unwrap(), b"test");
    assert!(
        fs::symlink_metadata(&location)
            .unwrap()
            .file_type()
            .is_symlink()
    );
}
