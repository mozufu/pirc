use super::*;
use crate::store::{Db, ModeId};

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
fn input() -> TransferInput {
    TransferInput {
        submission_hash: "a".repeat(64),
        name: "notes.txt".into(),
        mime: "text/plain".into(),
        size: 4,
        digest: sha256_hex(b"test"),
    }
}
fn creation(db: &mut Connection, sessions: &FsPath) -> Creation {
    setup(db);
    let input = super::super::Input {
        operation_id: "creation-1".into(),
        workspace_id: "repo".into(),
        submission_hash: "a".repeat(64),
    };
    super::super::reserve(db, "alice", &input).unwrap();
    super::super::initialize(db, "alice", &input, sessions).unwrap()
}
fn count(db: &Connection, table: &str) -> i64 {
    db.query_row(&format!("SELECT count(*) FROM {table}"), [], |r| r.get(0))
        .unwrap()
}
#[test]
fn receipt_and_file_are_stable_across_retries_and_database_reopening() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("node.sqlite");
    let first = {
        let db = Db::open(&path).unwrap();
        let mut conn = db.lock();
        creation(&mut conn, dir.path());
        reserve(
            &mut conn,
            "alice",
            "creation-1",
            "file-1",
            &input(),
            b"test",
        )
        .unwrap();
        initialize(
            &mut conn,
            "alice",
            "creation-1",
            "file-1",
            &input(),
            b"test",
            dir.path(),
        )
        .unwrap()
        .upload
        .unwrap()
    };
    let db = Db::open(&path).unwrap();
    let mut conn = db.lock();
    let second = initialize(
        &mut conn,
        "alice",
        "creation-1",
        "file-1",
        &input(),
        b"test",
        dir.path(),
    )
    .unwrap();
    assert_eq!(second.upload.as_ref(), Some(&first));
    assert!(second.ready);
    assert_eq!(count(&conn, "uploads"), 1);
    assert_eq!(count(&conn, "creation_uploads"), 1);
    assert_eq!(
        fs::read(dir.path().join(&first.storage_name)).unwrap(),
        b"test"
    );
    assert_eq!(count(&conn, "runs"), 0);
    assert_eq!(count(&conn, "commands"), 0);
}
#[test]
fn valid_partial_prefix_recovers_a_crash_without_replacing_unexpected_bytes() {
    let db = Db::memory();
    let mut conn = db.lock();
    let dir = tempfile::tempdir().unwrap();
    creation(&mut conn, dir.path());
    let record = reserve(
        &mut conn,
        "alice",
        "creation-1",
        "file-1",
        &input(),
        b"test",
    )
    .unwrap();
    let path = dir.path().join(format!(
        "{}.part",
        record.upload.as_ref().unwrap().storage_name
    ));
    OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&path)
        .unwrap()
        .write_all(b"te")
        .unwrap();
    let done = initialize(
        &mut conn,
        "alice",
        "creation-1",
        "file-1",
        &input(),
        b"test",
        dir.path(),
    )
    .unwrap();
    assert!(done.ready);
    assert!(!path.exists());
    assert_eq!(
        fs::read(dir.path().join(&done.upload.as_ref().unwrap().storage_name)).unwrap(),
        b"test"
    );
    fs::write(
        dir.path().join(&done.upload.as_ref().unwrap().storage_name),
        b"user",
    )
    .unwrap();
    assert_eq!(
        initialize(
            &mut conn,
            "alice",
            "creation-1",
            "file-1",
            &input(),
            b"test",
            dir.path()
        )
        .unwrap_err()
        .status,
        503
    );
    assert_eq!(
        fs::read(dir.path().join(&done.upload.as_ref().unwrap().storage_name)).unwrap(),
        b"user"
    );
}
#[test]
fn conflicting_manifest_and_other_owner_do_not_retarget_the_original() {
    let db = Db::memory();
    let mut conn = db.lock();
    let dir = tempfile::tempdir().unwrap();
    creation(&mut conn, dir.path());
    let first = reserve(
        &mut conn,
        "alice",
        "creation-1",
        "file-1",
        &input(),
        b"test",
    )
    .unwrap();
    assert_eq!(
        reserve(&mut conn, "bob", "creation-1", "file-1", &input(), b"test")
            .unwrap_err()
            .status,
        404
    );
    for variant in 0..4 {
        let mut changed = input();
        match variant {
            0 => changed.name = "other.txt".into(),
            1 => changed.mime = "application/octet-stream".into(),
            2 => changed.digest = sha256_hex(b"body"),
            _ => changed.submission_hash = "b".repeat(64),
        };
        assert_eq!(
            reserve(
                &mut conn,
                "alice",
                "creation-1",
                "file-1",
                &changed,
                b"test"
            )
            .unwrap_err()
            .status,
            409
        );
    }
    assert_eq!(
        read(&conn, "alice", "creation-1", "file-1")
            .unwrap()
            .unwrap()
            .upload,
        first.upload
    );
    assert_eq!(count(&conn, "uploads"), 0);
}

pub(crate) async fn node() -> (tempfile::TempDir, Node, String) {
    let (dir, node) = crate::app::tests::workspace_test_node().await;
    let work = dir.path().canonicalize().unwrap().join("repository");
    fs::create_dir(&work).unwrap();
    node.db
        .lock()
        .add_workspace(
            "repo",
            "test-node",
            "Repo",
            work.to_str().unwrap(),
            ModeId::new("directory").unwrap(),
        )
        .unwrap();
    let request = crate::router::Request {
        method: pirc_protocol::HttpMethod::Post,
        path: String::new(),
        query: vec![],
        params: vec![],
        user: "test-user".into(),
        body: Body::Json(
            json!({"operationId":"creation-1","workspaceId":"repo","submissionHash":"a".repeat(64)}),
        ),
    };
    let response = super::super::prepare(node.clone(), request).await.unwrap();
    let id = response.body.unwrap()["creation"]["sessionId"]
        .as_str()
        .unwrap()
        .to_owned();
    (dir, node, id)
}
async fn call(
    node: &Node,
    method: pirc_protocol::HttpMethod,
    url: &str,
    user: &str,
    bytes: Option<&[u8]>,
    mime: &str,
) -> pirc_protocol::NodeHttpResponse {
    use base64::Engine;
    node.router
        .handle(
            node,
            pirc_protocol::NodeHttpRequest {
                method,
                url: url.into(),
                user: user.into(),
                payload: None,
                body_base64: bytes.map(|b| base64::engine::general_purpose::STANDARD.encode(b)),
                content_type: Some(mime.into()),
            },
        )
        .await
}
fn url(bytes: &[u8], name: &str) -> String {
    let query = url::form_urlencoded::Serializer::new(String::new())
        .append_pair("submissionHash", &"a".repeat(64))
        .append_pair("sha256", &sha256_hex(bytes))
        .append_pair("byteSize", &bytes.len().to_string())
        .append_pair("filename", name)
        .finish();
    format!("/api/session-creations/creation-1/attachments/file-1?{query}")
}
#[tokio::test]
async fn router_transfer_lookup_and_legacy_upload_keep_the_same_kind_and_metadata() {
    use pirc_protocol::HttpMethod::{Get, Post, Put};
    let (_dir, node, session) = node().await;
    let caps = call(
        &node,
        Get,
        "/api/session-creations/capabilities",
        "test-user",
        None,
        "",
    )
    .await;
    assert_eq!(caps.status, 200);
    assert_eq!(caps.body.unwrap()["canTransferAttachments"], true);
    let path = url(b"test", "notes.txt");
    let first = call(&node, Put, &path, "test-user", Some(b"test"), "text/plain").await;
    assert_eq!(first.status, 200, "{first:?}");
    let receipt = first.body.unwrap()["creationAttachment"].clone();
    assert_eq!(receipt["state"], "ready");
    assert_eq!(receipt["upload"]["sha256"], sha256_hex(b"test"));
    assert_eq!(
        call(&node, Put, &path, "test-user", Some(b"test"), "text/plain")
            .await
            .body
            .unwrap()["creationAttachment"],
        receipt
    );
    assert_eq!(
        call(
            &node,
            Get,
            "/api/session-creations/creation-1/attachments/file-1",
            "test-user",
            None,
            ""
        )
        .await
        .body
        .unwrap()["creationAttachment"],
        receipt
    );
    let legacy = call(
        &node,
        Post,
        &format!("/api/sessions/{session}/uploads?filename=notes.txt"),
        "test-user",
        Some(b"test"),
        "text/plain",
    )
    .await;
    assert_eq!(legacy.status, 201);
    let legacy = legacy.body.unwrap()["upload"].clone();
    for key in ["mimeType", "byteSize", "kind", "filename"] {
        assert_eq!(legacy[key], receipt["upload"][key], "{key}");
    }
    assert_eq!(count(&node.db.lock(), "runs"), 0);
    assert_eq!(count(&node.db.lock(), "commands"), 0);
    node.close().await;
}
#[tokio::test]
async fn malformed_bytes_and_queries_never_reserve_transfers() {
    use pirc_protocol::HttpMethod::Put;
    let (_dir, node, _session) = node().await;
    let path = url(b"test", "notes.txt");
    for (path, bytes, mime, status) in [
        (path.clone(), b"oops".as_slice(), "text/plain", 409),
        (
            format!("{path}&filename=other"),
            b"test".as_slice(),
            "text/plain",
            400,
        ),
        (
            format!("{path}&unknown=x"),
            b"test".as_slice(),
            "text/plain",
            400,
        ),
        (
            url(b"test", "../secret"),
            b"test".as_slice(),
            "text/plain",
            400,
        ),
        (
            url(b"GIF89a...", "image.gif"),
            b"GIF89a...".as_slice(),
            "image/png",
            400,
        ),
    ] {
        let result = call(&node, Put, &path, "test-user", Some(bytes), mime).await;
        assert_eq!(result.status, status, "{result:?}");
    }
    assert_eq!(
        call(&node, Put, &path, "other-user", Some(b"test"), "text/plain")
            .await
            .status,
        403
    );
    assert_eq!(count(&node.db.lock(), "creation_uploads"), 0);
    assert_eq!(count(&node.db.lock(), "uploads"), 0);
    node.close().await;
}
#[tokio::test]
async fn deletion_cleans_ready_and_reserved_bytes_and_scrubs_metadata_before_retry() {
    use pirc_protocol::HttpMethod::{Get, Put};
    let (_dir, node, session) = node().await;
    let path = url(b"test", "private-name.txt");
    let ready = call(&node, Put, &path, "test-user", Some(b"test"), "text/plain").await;
    assert_eq!(ready.status, 200);
    let first = read(&node.db.lock(), "test-user", "creation-1", "file-1")
        .unwrap()
        .unwrap()
        .upload
        .unwrap();
    let second = {
        let mut db = node.db.lock();
        reserve(
            &mut db,
            "test-user",
            "creation-1",
            "file-2",
            &input(),
            b"test",
        )
        .unwrap()
        .upload
        .unwrap()
    };
    let orphan = node
        .config
        .uploads_dir
        .join(format!("{}.part", second.storage_name));
    OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&orphan)
        .unwrap()
        .write_all(b"te")
        .unwrap();
    assert_eq!(
        remove_session_files(&node, &session).unwrap_err().status,
        409
    );
    node.db
        .lock()
        .begin_session_deletion(&session, "test-user")
        .unwrap();
    remove_session_files(&node, &session).unwrap();
    node.db.lock().finish_session_deletion(&session).unwrap();
    assert!(!node.config.uploads_dir.join(first.storage_name).exists());
    assert!(!orphan.exists());
    assert_eq!(count(&node.db.lock(), "uploads"), 0);
    assert_eq!(
        node.db
            .lock()
            .query_row(
                "SELECT count(*) FROM creation_uploads WHERE upload_json IS NOT NULL",
                [],
                |r| r.get::<_, i64>(0)
            )
            .unwrap(),
        0
    );
    let status = call(
        &node,
        Get,
        "/api/session-creations/creation-1/attachments/file-1",
        "test-user",
        None,
        "",
    )
    .await;
    assert_eq!(status.status, 200);
    let status = status.body.unwrap()["creationAttachment"].clone();
    assert_eq!(status["state"], "deleted");
    assert_eq!(status["upload"], json!({"id":first.id}));
    assert_eq!(
        call(&node, Put, &path, "test-user", Some(b"test"), "text/plain")
            .await
            .body
            .unwrap()["creationAttachment"],
        status
    );
    assert_eq!(count(&node.db.lock(), "uploads"), 0);
    node.close().await;
}
#[test]
fn missing_ready_files_and_unexpected_partial_bytes_are_not_recreated_or_overwritten() {
    let db = Db::memory();
    let mut conn = db.lock();
    let dir = tempfile::tempdir().unwrap();
    creation(&mut conn, dir.path());
    let reserved = reserve(
        &mut conn,
        "alice",
        "creation-1",
        "file-1",
        &input(),
        b"test",
    )
    .unwrap()
    .upload
    .unwrap();
    let partial = dir.path().join(format!("{}.part", reserved.storage_name));
    OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&partial)
        .unwrap()
        .write_all(b"user")
        .unwrap();
    assert_eq!(
        initialize(
            &mut conn,
            "alice",
            "creation-1",
            "file-1",
            &input(),
            b"test",
            dir.path()
        )
        .unwrap_err()
        .status,
        503
    );
    assert_eq!(fs::read(&partial).unwrap(), b"user");
    fs::remove_file(&partial).unwrap();
    initialize(
        &mut conn,
        "alice",
        "creation-1",
        "file-1",
        &input(),
        b"test",
        dir.path(),
    )
    .unwrap();
    let file = dir.path().join(&reserved.storage_name);
    fs::remove_file(&file).unwrap();
    assert_eq!(
        initialize(
            &mut conn,
            "alice",
            "creation-1",
            "file-1",
            &input(),
            b"test",
            dir.path()
        )
        .unwrap_err()
        .status,
        503
    );
    assert!(!file.exists());
}
#[test]
fn concurrent_independent_connections_keep_one_upload_id() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("node.sqlite");
    creation(&mut Db::open(&path).unwrap().lock(), dir.path());
    let barrier = std::sync::Barrier::new(4);
    let ids = std::thread::scope(|scope| {
        let threads = (0..4)
            .map(|_| {
                scope.spawn(|| {
                    let db = Db::open(&path).unwrap();
                    barrier.wait();
                    let mut conn = db.lock();
                    reserve(
                        &mut conn,
                        "alice",
                        "creation-1",
                        "file-1",
                        &input(),
                        b"test",
                    )
                    .unwrap();
                    initialize(
                        &mut conn,
                        "alice",
                        "creation-1",
                        "file-1",
                        &input(),
                        b"test",
                        dir.path(),
                    )
                    .unwrap()
                    .upload
                    .unwrap()
                    .id
                })
            })
            .collect::<Vec<_>>();
        threads
            .into_iter()
            .map(|h| h.join().unwrap())
            .collect::<Vec<_>>()
    });
    assert!(ids.iter().all(|id| id == &ids[0]));
    assert_eq!(count(&Db::open(&path).unwrap().lock(), "uploads"), 1);
}

#[test]
fn reserved_creation_from_another_owner_blocks_project_deletion() {
    let db = Db::memory();
    let mut conn = db.lock();
    setup(&conn);
    let input = super::super::Input {
        operation_id: "other-draft".into(),
        workspace_id: "repo".into(),
        submission_hash: "a".repeat(64),
    };
    super::super::reserve(&mut conn, "bob", &input).unwrap();
    assert_eq!(
        conn.begin_workspace_deletion("repo", "alice")
            .unwrap_err()
            .status,
        403
    );
    assert_eq!(count(&conn, "workspace_deletions"), 0);
    conn.begin_workspace_deletion("repo", "bob").unwrap();
    assert_eq!(count(&conn, "workspace_deletions"), 1);
}
#[tokio::test]
async fn image_transfer_uses_the_legacy_sniffed_type_and_missing_storage_fails_closed() {
    use pirc_protocol::HttpMethod::{Get, Post, Put};
    let (_dir, node, session) = node().await;
    let bytes = b"GIF89a...";
    let first = call(
        &node,
        Put,
        &url(bytes, "image.gif"),
        "test-user",
        Some(bytes),
        "application/octet-stream",
    )
    .await;
    assert_eq!(first.status, 200, "{first:?}");
    let receipt = first.body.unwrap()["creationAttachment"].clone();
    assert_eq!(receipt["upload"]["mimeType"], "image/gif");
    assert_eq!(receipt["upload"]["kind"], "image");
    let legacy = call(
        &node,
        Post,
        &format!("/api/sessions/{session}/uploads?filename=image.gif"),
        "test-user",
        Some(bytes),
        "application/octet-stream",
    )
    .await;
    assert_eq!(legacy.status, 201);
    let legacy = legacy.body.unwrap()["upload"].clone();
    for key in ["mimeType", "byteSize", "kind", "filename"] {
        assert_eq!(legacy[key], receipt["upload"][key], "{key}");
    }
    let upload = read(&node.db.lock(), "test-user", "creation-1", "file-1")
        .unwrap()
        .unwrap()
        .upload
        .unwrap();
    fs::remove_file(node.config.uploads_dir.join(upload.storage_name)).unwrap();
    assert_eq!(
        call(
            &node,
            Get,
            "/api/session-creations/creation-1/attachments/file-1",
            "test-user",
            None,
            ""
        )
        .await
        .status,
        503
    );
    assert_eq!(
        call(
            &node,
            Put,
            &url(bytes, "image.gif"),
            "test-user",
            Some(bytes),
            "application/octet-stream"
        )
        .await
        .status,
        503
    );
    node.close().await;
}

#[test]
fn sqlite_failure_after_file_publication_reuses_the_original_reserved_upload() {
    let db = Db::memory();
    let mut conn = db.lock();
    let dir = tempfile::tempdir().unwrap();
    creation(&mut conn, dir.path());
    let record = reserve(
        &mut conn,
        "alice",
        "creation-1",
        "file-1",
        &input(),
        b"test",
    )
    .unwrap();
    let upload = record.upload.unwrap();
    conn.execute_batch("CREATE TRIGGER fail_transfer BEFORE INSERT ON uploads BEGIN SELECT RAISE(FAIL,'injected transfer failure'); END;").unwrap();
    assert!(
        initialize(
            &mut conn,
            "alice",
            "creation-1",
            "file-1",
            &input(),
            b"test",
            dir.path()
        )
        .is_err()
    );
    assert_eq!(count(&conn, "uploads"), 0);
    assert!(
        !read(&conn, "alice", "creation-1", "file-1")
            .unwrap()
            .unwrap()
            .ready
    );
    let file = dir.path().join(&upload.storage_name);
    assert_eq!(fs::read(&file).unwrap(), b"test");
    let modified = fs::metadata(&file).unwrap().modified().unwrap();
    conn.execute_batch("DROP TRIGGER fail_transfer;").unwrap();
    let retry = initialize(
        &mut conn,
        "alice",
        "creation-1",
        "file-1",
        &input(),
        b"test",
        dir.path(),
    )
    .unwrap();
    assert_eq!(retry.upload.as_ref().unwrap().id, upload.id);
    assert_eq!(fs::metadata(&file).unwrap().modified().unwrap(), modified);
    assert_eq!(count(&conn, "uploads"), 1);
}
#[test]
fn symlinks_and_fifos_are_refused_without_following_or_blocking() {
    use std::os::unix::fs::symlink;
    let db = Db::memory();
    let mut conn = db.lock();
    let dir = tempfile::tempdir().unwrap();
    creation(&mut conn, dir.path());
    let upload = reserve(
        &mut conn,
        "alice",
        "creation-1",
        "file-1",
        &input(),
        b"test",
    )
    .unwrap()
    .upload
    .unwrap();
    let target = dir.path().join(&upload.storage_name);
    let outside = dir.path().join("user-data");
    fs::write(&outside, b"test").unwrap();
    symlink(&outside, &target).unwrap();
    assert_eq!(
        initialize(
            &mut conn,
            "alice",
            "creation-1",
            "file-1",
            &input(),
            b"test",
            dir.path()
        )
        .unwrap_err()
        .status,
        503
    );
    assert_eq!(fs::read(&outside).unwrap(), b"test");
    fs::remove_file(&target).unwrap();
    nix::unistd::mkfifo(
        &target,
        nix::sys::stat::Mode::S_IRUSR | nix::sys::stat::Mode::S_IWUSR,
    )
    .unwrap();
    assert_eq!(
        initialize(
            &mut conn,
            "alice",
            "creation-1",
            "file-1",
            &input(),
            b"test",
            dir.path()
        )
        .unwrap_err()
        .status,
        503
    );
    assert_eq!(count(&conn, "uploads"), 0);
}
#[test]
fn attachment_count_is_bounded_before_files_are_written() {
    let db = Db::memory();
    let mut conn = db.lock();
    let dir = tempfile::tempdir().unwrap();
    creation(&mut conn, dir.path());
    for i in 0..16 {
        reserve(
            &mut conn,
            "alice",
            "creation-1",
            &format!("file-{i}"),
            &input(),
            b"test",
        )
        .unwrap();
    }
    assert_eq!(
        reserve(
            &mut conn,
            "alice",
            "creation-1",
            "file-17",
            &input(),
            b"test"
        )
        .unwrap_err()
        .status,
        400
    );
    assert_eq!(count(&conn, "creation_uploads"), 16);
    assert_eq!(count(&conn, "uploads"), 0);
}
#[tokio::test]
async fn authorized_delete_route_cleans_transfer_files_and_preserves_workspace_data() {
    use pirc_protocol::HttpMethod::{Delete, Get, Put};
    let (dir, node, session) = node().await;
    // A configured Work mode may opt into conversation deletion without
    // deleting the mounted workspace. Exercise the actual DELETE handler.
    node.modes
        .write()
        .unwrap()
        .get_mut(&ModeId::new("directory").unwrap())
        .unwrap()
        .delete_sessions = true;
    let original = dir
        .path()
        .canonicalize()
        .unwrap()
        .join("repository/user.txt");
    fs::write(&original, b"keep user edits").unwrap();
    let path = url(b"test", "notes.txt");
    assert_eq!(
        call(&node, Put, &path, "test-user", Some(b"test"), "text/plain")
            .await
            .status,
        200
    );
    let upload = read(&node.db.lock(), "test-user", "creation-1", "file-1")
        .unwrap()
        .unwrap()
        .upload
        .unwrap();
    let result = call(
        &node,
        Delete,
        &format!("/api/sessions/{session}"),
        "test-user",
        None,
        "",
    )
    .await;
    assert_eq!(result.status, 204, "{result:?}");
    assert!(!node.config.uploads_dir.join(upload.storage_name).exists());
    assert_eq!(fs::read(&original).unwrap(), b"keep user edits");
    let status = call(
        &node,
        Get,
        "/api/session-creations/creation-1/attachments/file-1",
        "test-user",
        None,
        "",
    )
    .await;
    assert_eq!(status.status, 200);
    assert_eq!(
        status.body.unwrap()["creationAttachment"]["state"],
        "deleted"
    );
    assert!(
        read(&node.db.lock(), "test-user", "creation-1", "file-1")
            .unwrap()
            .unwrap()
            .upload
            .is_none()
    );
    node.close().await;
}
#[test]
fn deletion_and_transfer_on_independent_connections_do_not_revive_the_session() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("node.sqlite");
    let session = {
        let db = Db::open(&path).unwrap();
        let mut conn = db.lock();
        let creation = creation(&mut conn, dir.path());
        reserve(
            &mut conn,
            "alice",
            "creation-1",
            "file-1",
            &input(),
            b"test",
        )
        .unwrap();
        creation.session_id
    };
    let barrier = std::sync::Barrier::new(2);
    std::thread::scope(|scope| {
        let transfer = scope.spawn(|| {
            let db = Db::open(&path).unwrap();
            barrier.wait();
            let result = initialize(
                &mut db.lock(),
                "alice",
                "creation-1",
                "file-1",
                &input(),
                b"test",
                dir.path(),
            );
            if let Err(error) = result {
                assert_eq!(error.status, 409);
            }
        });
        let delete = scope.spawn(|| {
            let db = Db::open(&path).unwrap();
            barrier.wait();
            db.lock().begin_session_deletion(&session, "alice").unwrap();
        });
        transfer.join().unwrap();
        delete.join().unwrap();
    });
    let db = Db::open(&path).unwrap();
    let mut conn = db.lock();
    assert_eq!(
        initialize(
            &mut conn,
            "alice",
            "creation-1",
            "file-1",
            &input(),
            b"test",
            dir.path()
        )
        .unwrap_err()
        .status,
        409
    );
    assert!(count(&conn, "uploads") <= 1);
}

#[tokio::test]
async fn a_ready_retry_is_a_read_even_after_its_mode_was_removed() {
    use pirc_protocol::HttpMethod::{Get, Put};
    let (_dir, node, _session) = node().await;
    let path = url(b"test", "notes.txt");
    let first = call(&node, Put, &path, "test-user", Some(b"test"), "text/plain").await;
    assert_eq!(first.status, 200);
    node.replace_modes(vec![]).await;
    let retry = call(&node, Put, &path, "test-user", Some(b"test"), "text/plain").await;
    assert_eq!(retry.status, 200);
    assert_eq!(retry.body, first.body);
    let lookup = call(
        &node,
        Get,
        "/api/session-creations/creation-1/attachments/file-1",
        "test-user",
        None,
        "",
    )
    .await;
    assert_eq!(lookup.body, first.body);
    assert_eq!(count(&node.db.lock(), "uploads"), 1);
    node.close().await;
}

#[tokio::test]
async fn raw_transport_preserves_json_mime_and_rejects_ambiguous_metadata() {
    use pirc_protocol::HttpMethod::{Get, Put};
    let (_dir, node, _session) = node().await;
    let caps = call(
        &node,
        Get,
        "/api/session-creations/capabilities",
        "test-user",
        None,
        "",
    )
    .await;
    assert_eq!(caps.body.unwrap()["attachmentMimeInQuery"], true);
    let bytes = b"{\"native\":true}\n";
    let path = format!("{}&mimeType=application%2Fjson", url(bytes, "data.json"));
    for (path, mime) in [
        (
            format!("{path}&mimeType=text%2Fplain"),
            "application/octet-stream",
        ),
        (path.clone(), "text/plain"),
    ] {
        assert_eq!(
            call(&node, Put, &path, "test-user", Some(bytes), mime)
                .await
                .status,
            400
        );
    }
    assert_eq!(count(&node.db.lock(), "creation_uploads"), 0);
    let first = call(
        &node,
        Put,
        &path,
        "test-user",
        Some(bytes),
        "application/octet-stream",
    )
    .await;
    assert_eq!(first.status, 200, "{first:?}");
    let receipt = first.body.unwrap()["creationAttachment"].clone();
    assert_eq!(receipt["upload"]["mimeType"], "application/json");
    assert_eq!(receipt["upload"]["kind"], "file");
    assert_eq!(receipt["upload"]["sha256"], sha256_hex(bytes));
    let retry = call(
        &node,
        Put,
        &path,
        "test-user",
        Some(bytes),
        "application/octet-stream",
    )
    .await;
    assert_eq!(retry.body.unwrap()["creationAttachment"], receipt);
    assert_eq!(count(&node.db.lock(), "uploads"), 1);
    assert_eq!(count(&node.db.lock(), "commands"), 0);
    node.close().await;
}
