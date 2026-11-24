use super::*;

fn with_workspace(db: &Db) {
    db.lock()
        .sync_remote_workspaces(
            "n1",
            &[("w".into(), "W".into(), ModeId::new("chat").unwrap())],
        )
        .unwrap();
}

#[test]
fn wal_mode_retries_until_a_concurrent_write_transaction_finishes() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("gateway.sqlite");
    let blocker = Connection::open(&path).unwrap();
    let connection = Connection::open(&path).unwrap();
    blocker.execute_batch("BEGIN IMMEDIATE").unwrap();

    let (busy_tx, busy_rx) = std::sync::mpsc::channel();
    let release = std::thread::spawn(move || {
        busy_rx
            .recv()
            .expect("WAL switch attempted while the write lock is held");
        blocker.execute_batch("ROLLBACK").unwrap();
    });
    let mut busy_seen = false;
    let result = enable_wal_mode_with_retry(&connection, &path, || {
        busy_seen = true;
        let _ = busy_tx.send(());
    });
    // Unblock the holder if initialization failed before reaching its retry
    // callback.
    let _ = busy_tx.send(());
    release.join().unwrap();
    result.unwrap();
    assert!(
        busy_seen,
        "the held SQLite write lock must trigger the bounded retry"
    );

    let mode: String = connection
        .pragma_query_value(None, "journal_mode", |row| row.get(0))
        .unwrap();
    assert_eq!(mode, "wal");

    let busy_timeout: i64 = connection
        .pragma_query_value(None, "busy_timeout", |row| row.get(0))
        .unwrap();
    assert_eq!(busy_timeout, SQLITE_BUSY_TIMEOUT.as_millis() as i64);
}

#[test]
fn concurrent_opens_create_the_schema_once() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("gateway.sqlite");
    let barrier = std::sync::Barrier::new(8);
    std::thread::scope(|scope| {
        let opens: Vec<_> = (0..8)
            .map(|_| {
                scope.spawn(|| {
                    barrier.wait();
                    Db::open(&path).map(drop)
                })
            })
            .collect();
        for open in opens {
            open.join().unwrap().unwrap();
        }
    });
    let db = Db::open(&path).unwrap();
    let version: i64 = db
        .lock()
        .pragma_query_value(None, "user_version", |row| row.get(0))
        .unwrap();
    assert_eq!(version, SCHEMA_VERSION);
    let fresh = Db::memory();
    let tables = |db: &Db| -> Vec<String> {
        let connection = db.lock();
        let mut statement = connection
            .prepare("SELECT name FROM sqlite_master ORDER BY name")
            .unwrap();
        statement
            .query_map([], |row| row.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap()
    };
    assert_eq!(tables(&db), tables(&fresh));
}

#[test]
fn refuses_databases_from_earlier_releases() {
    for version in [19, 1000, 1034] {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("gateway.sqlite");
        let old = Connection::open(&path).unwrap();
        old.execute_batch(&format!(
            "CREATE TABLE workspaces (id TEXT); PRAGMA user_version = {version};"
        ))
        .unwrap();
        drop(old);
        let error = Db::open(&path).err().unwrap();
        assert!(error.contains("earlier pirc"), "{error}");
        assert!(error.contains("upgrades.md"), "{error}");
        assert!(refuse_earlier_database(&path).is_err());
    }
}

#[test]
fn refuses_unversioned_databases() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("other.sqlite");
    Connection::open(&path)
        .unwrap()
        .execute_batch("CREATE TABLE x (y TEXT);")
        .unwrap();
    assert!(Db::open(&path).err().unwrap().contains("no pirc schema"));
}

#[test]
fn deleted_content_is_zeroed() {
    let dir = tempfile::tempdir().unwrap();
    let sentinel = "forgotten-memory-sentinel-7f3a";
    let written = |db: &Connection, path: &Path| {
        db.execute_batch("CREATE TABLE scratch (x TEXT);").unwrap();
        db.execute("INSERT INTO scratch VALUES (?)", [sentinel.repeat(20)])
            .unwrap();
        db.execute("DELETE FROM scratch", []).unwrap();
        db.query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |_| Ok(()))
            .unwrap();
        let bytes = std::fs::read(path).unwrap();
        bytes
            .windows(sentinel.len())
            .any(|window| window == sentinel.as_bytes())
    };
    let path = dir.path().join("db.sqlite");
    let db = Db::open(&path).unwrap();
    let on: i64 = db
        .lock()
        .pragma_query_value(None, "secure_delete", |row| row.get(0))
        .unwrap();
    assert_eq!(on, 1);
    assert!(!written(&db.lock(), &path));
    // Without the pragma the text would stay in the file.
    let plain_path = dir.path().join("plain.sqlite");
    let plain = Connection::open(&plain_path).unwrap();
    plain.pragma_update(None, "journal_mode", "WAL").unwrap();
    plain.pragma_update(None, "secure_delete", "OFF").unwrap();
    assert!(written(&plain, &plain_path));
}

#[test]
fn creates_and_reopens() {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("gateway.sqlite");
    drop(Db::open(&path).unwrap());
    let db = Db::open(&path).unwrap();
    let version: i64 = db
        .lock()
        .pragma_query_value(None, "user_version", |row| row.get(0))
        .unwrap();
    assert_eq!(version, SCHEMA_VERSION);
    let mode = std::fs::metadata(&path).unwrap().permissions().mode();
    assert_eq!(mode & 0o777, 0o600);
}

#[test]
fn startup_rejects_commands_that_were_received_but_never_dispatched() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("gateway.sqlite");
    let payload = json!({ "type": "prompt" });
    let session = {
        let db = Db::open(&path).unwrap();
        with_workspace(&db);
        let conn = db.lock();
        let session = conn
            .create_session("n1:w", "node://n1/r1", "n1", "r1", "u")
            .unwrap();
        for id in ["unsent", "sent", "answered", "refused"] {
            conn.receive_command(id, &session.id, "h", &payload)
                .unwrap();
        }
        conn.update_command("sent", "dispatched", None, None)
            .unwrap();
        conn.update_command("answered", "accepted", Some(&json!({ "ok": true })), None)
            .unwrap();
        conn.update_command("refused", "rejected", None, Some("Node is offline"))
            .unwrap();
        assert_eq!(conn.get_command("unsent").unwrap().status, "received");
        session
    };

    // The process "restarts": a new Db on the same file, then startup recovery.
    let db = Db::open(&path).unwrap();
    let recovered = db.lock().recover_startup().unwrap();
    assert_eq!(recovered.rejected_commands, 1);
    assert_eq!(recovered.unknown_commands, 1);
    let conn = db.lock();
    let unsent = conn.get_command("unsent").unwrap();
    assert_eq!(unsent.status, "rejected");
    assert_eq!(
        unsent.error.as_deref(),
        Some("gateway restarted before dispatch")
    );
    // Only the unsent command changed; everything that may have reached a Node
    // keeps its own recovery rule.
    assert_eq!(conn.get_command("sent").unwrap().status, "outcome_unknown");
    assert_eq!(conn.get_command("answered").unwrap().status, "accepted");
    let refused = conn.get_command("refused").unwrap();
    assert_eq!(refused.status, "rejected");
    assert_eq!(refused.error.as_deref(), Some("Node is offline"));

    // Sending the same commandId again is a duplicate that reports the rejection;
    // it neither re-executes nor changes the command, and a different payload
    // under that id is still a conflict.
    let (again, duplicate) = conn
        .receive_command("unsent", &session.id, "h", &payload)
        .unwrap();
    assert!(duplicate);
    assert_eq!(again.status, "rejected");
    assert_eq!(
        conn.receive_command("unsent", &session.id, "other", &payload)
            .unwrap_err()
            .code,
        "conflict"
    );

    // A second recovery changes nothing.
    let again = conn.recover_startup().unwrap();
    assert_eq!(again.rejected_commands, 0);
}

#[test]
fn sessions() {
    let db = Db::memory();
    with_workspace(&db);
    let conn = db.lock();
    let session = conn
        .create_session("n1:w", "node://n1/r1", "n1", "r1", "u")
        .unwrap();
    let public = session.public();
    assert_eq!(public["name"], "New session");
    assert_eq!(public["nameSource"], "auto");
    assert_eq!(public["nodeId"], "n1");
    assert!(public.get("ownerUser").is_none());
    assert!(public.get("piSessionId").is_none());
    assert_eq!(
        conn.resolve_remote_session("n1", "r1").unwrap().as_deref(),
        Some(session.id.as_str())
    );
    assert!(conn.auto_rename_session(&session.id, "Title").unwrap());
    conn.rename_session(&session.id, "Mine").unwrap();
    assert!(!conn.auto_rename_session(&session.id, "Other").unwrap());
    assert_eq!(
        conn.claim_session(&session.id, "v", false)
            .unwrap_err()
            .code,
        "forbidden"
    );
    assert!(!conn.mark_session_read(&session.id).unwrap());
    conn.mark_session_activity(&session.id).unwrap();
    assert!(conn.get_session(&session.id).unwrap().unread);
    assert!(conn.mark_session_read(&session.id).unwrap());
    let flagged = conn
        .set_session_flags(&session.id, Some(true), None)
        .unwrap();
    assert!(flagged.pinned_at.is_some() && flagged.settled_at.is_none());
    assert_eq!(conn.increment_epoch(&session.id).unwrap(), 1);
    conn.begin_session_deletion(&session.id, "u").unwrap();
    assert_eq!(
        conn.claim_session(&session.id, "u", false)
            .unwrap_err()
            .code,
        "conflict"
    );
    assert_eq!(conn.resolve_remote_session("n1", "r1").unwrap(), None);
    conn.finish_session_deletion(&session.id).unwrap();
    assert_eq!(
        conn.session_deletion(&session.id).unwrap().unwrap().status,
        DeletionStatus::Deleted
    );
}

#[test]
fn a_project_being_deleted_is_fenced_and_stays_deleted() {
    let db = Db::memory();
    with_workspace(&db);
    let conn = db.lock();
    let mine = conn
        .create_session("n1:w", "node://n1/r1", "n1", "r1", "u")
        .unwrap();
    assert_eq!(
        conn.workspace_session_ids("n1:w").unwrap(),
        std::slice::from_ref(&mine.id)
    );
    let theirs = conn
        .create_session("n1:w", "node://n1/r2", "n1", "r2", "v")
        .unwrap();
    assert_eq!(
        conn.begin_workspace_deletion("n1:w", "u").unwrap_err().code,
        "forbidden"
    );
    assert!(conn.workspace_deletion("n1:w").unwrap().is_none());
    conn.execute("DELETE FROM sessions WHERE id=?", [&theirs.id])
        .unwrap();
    conn.begin_workspace_deletion("n1:w", "u").unwrap();
    // Idempotent.
    conn.begin_workspace_deletion("n1:w", "u").unwrap();
    assert_eq!(conn.get_workspace("n1:w").unwrap_err().code, "conflict");
    assert!(conn.find_workspace("n1:w").unwrap().is_some());
    assert!(conn.list_workspaces().unwrap().is_empty());
    assert_eq!(
        conn.create_session("n1:w", "node://n1/r3", "n1", "r3", "u")
            .unwrap_err()
            .code,
        "conflict"
    );
    // Its chats are fenced too.
    assert_eq!(conn.resolve_remote_session("n1", "r1").unwrap(), None);
    assert_eq!(
        conn.claim_session(&mine.id, "u", false).unwrap_err().code,
        "conflict"
    );
    // Listed as unfinished, for its owner.
    let deleting: Vec<String> = conn
        .deleting_workspaces()
        .unwrap()
        .into_iter()
        .map(|workspace| workspace.id)
        .collect();
    assert_eq!(deleting, ["n1:w"]);
    // Once gone, the node announcing it again does not bring it back.
    conn.finish_session_deletion(&mine.id).unwrap();
    // Preserve historical deletion metadata; memory ownership now uses each
    // version's frozen origin rather than this session's last workspace.
    let deleted_workspace: String = conn
        .query_row(
            "SELECT workspace_id FROM session_deletions WHERE session_id=?",
            [&mine.id],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(deleted_workspace, "n1:w");
    conn.execute("DELETE FROM workspaces WHERE id='n1:w'", [])
        .unwrap();
    conn.sync_remote_workspaces(
        "n1",
        &[("w".into(), "W".into(), ModeId::new("chat").unwrap())],
    )
    .unwrap();
    assert!(conn.find_workspace("n1:w").unwrap().is_none());
    // Others still sync.
    conn.sync_remote_workspaces(
        "n1",
        &[("x".into(), "X".into(), ModeId::new("chat").unwrap())],
    )
    .unwrap();
    assert!(conn.find_workspace("n1:x").unwrap().is_some());
}

#[test]
fn commands_and_leases() {
    let db = Db::memory();
    with_workspace(&db);
    let conn = db.lock();
    let session = conn
        .create_session("n1:w", "node://n1/r1", "n1", "r1", "u")
        .unwrap();
    let payload = json!({ "type": "prompt" });
    let (_, duplicate) = conn
        .receive_command("c1", &session.id, "h", &payload)
        .unwrap();
    assert!(!duplicate);
    assert!(
        conn.receive_command("c1", &session.id, "h", &payload)
            .unwrap()
            .1
    );
    assert_eq!(
        conn.receive_command("c1", &session.id, "other", &payload)
            .unwrap_err()
            .code,
        "conflict"
    );
    conn.update_command("c1", "accepted", Some(&json!({ "ok": true })), None)
        .unwrap();
    assert_eq!(conn.get_command("c1").unwrap().result["ok"], true);

    let lease = Lease {
        client_id: "b".into(),
        generation: 1,
        expires_at: now_ms() + 60_000,
    };
    conn.mirror_lease(&session.id, &lease, "u", false).unwrap();
    conn.validate_lease(&session.id, "b", 1).unwrap();
    conn.validate_lease_user(&session.id, "u").unwrap();
    assert!(conn.validate_lease(&session.id, "b", 2).is_err());
    assert!(conn.mirror_lease(&session.id, &lease, "v", false).is_err());
    conn.mirror_lease(&session.id, &lease, "v", true).unwrap();
    assert_eq!(conn.get_lease(&session.id).unwrap()["expired"], false);
    conn.clear_remote_lease(&session.id).unwrap();
    assert_eq!(conn.get_lease(&session.id).unwrap(), Value::Null);
}

#[test]
fn capabilities() {
    let db = Db::memory();
    with_workspace(&db);
    let conn = db.lock();
    assert_eq!(
        conn.get_workspace_capabilities("n1:w").unwrap(),
        Capabilities::default()
    );
    let patch: CapabilitiesPatch = serde_json::from_value(json!({ "web_search": false })).unwrap();
    let policy = conn.patch_workspace_capabilities("n1:w", &patch).unwrap();
    assert!(!policy.web_search && policy.delegation);
    assert_eq!(
        conn.require_workspace_capability("n1:w", Capability::WebSearch)
            .unwrap_err()
            .code,
        "capability_disabled"
    );
    assert_eq!(
        json!(policy),
        json!({ "version": 1, "delegation": true, "memory_search": true,
                "remote_recall": true, "schedules": true, "web_search": false,
                "delegation_approval": "always" })
    );
    // Policies stored before the approval setting read as `always`.
    conn.execute(
        "UPDATE workspace_capabilities SET policy_json=? WHERE workspace_id='n1:w'",
        [
            json!({ "version": 1, "delegation": true, "memory_search": true,
                "remote_recall": true, "schedules": true, "web_search": false })
            .to_string(),
        ],
    )
    .unwrap();
    assert_eq!(
        conn.get_workspace_capabilities("n1:w")
            .unwrap()
            .delegation_approval,
        DelegationApproval::Always
    );
    let patch: CapabilitiesPatch =
        serde_json::from_value(json!({ "delegation_approval": "untrusted" })).unwrap();
    let policy = conn.patch_workspace_capabilities("n1:w", &patch).unwrap();
    assert_eq!(policy.delegation_approval, DelegationApproval::Untrusted);
    assert!(!policy.web_search);
    assert!(
        serde_json::from_value::<CapabilitiesPatch>(json!({ "delegation_approval": "sometimes" }))
            .is_err()
    );
    assert!(serde_json::from_value::<CapabilitiesPatch>(json!({ "version": 2 })).is_err());
    assert!(serde_json::from_value::<CapabilitiesPatch>(json!({ "other": 1 })).is_err());
    assert!(serde_json::from_value::<CapabilitiesPatch>(json!({ "schedules": null })).is_err());
}

#[test]
fn atomic_write_reserves_before_reading_across_connections() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("gateway.sqlite");
    let first = Db::open(&path).unwrap();
    first
        .lock()
        .execute_batch(
            "CREATE TABLE atomic_probe(value INTEGER); INSERT INTO atomic_probe VALUES(0);",
        )
        .unwrap();
    let (ready_tx, ready_rx) = std::sync::mpsc::channel();
    let (start_tx, start_rx) = std::sync::mpsc::channel();
    let (done_tx, done_rx) = std::sync::mpsc::channel();
    std::thread::scope(|scope| {
        let path = &path;
        let second = scope.spawn(move || {
            let db = Db::open(path).unwrap();
            ready_tx.send(()).unwrap();
            start_rx.recv().unwrap();
            atomic(&db.lock(), |conn| {
                let value: i64 =
                    conn.query_row("SELECT value FROM atomic_probe", [], |r| r.get(0))?;
                conn.execute("UPDATE atomic_probe SET value=?1", [value + 1])?;
                Ok(())
            })
            .unwrap();
            done_tx.send(()).unwrap();
        });
        ready_rx.recv().unwrap();
        atomic(&first.lock(), |conn| {
            let value: i64 = conn.query_row("SELECT value FROM atomic_probe", [], |r| r.get(0))?;
            start_tx.send(()).unwrap();
            assert!(
                done_rx
                    .recv_timeout(std::time::Duration::from_millis(30))
                    .is_err(),
                "second writer must wait for this read/mutation transaction"
            );
            conn.execute("UPDATE atomic_probe SET value=?1", [value + 1])?;
            Ok(())
        })
        .unwrap();
        second.join().unwrap();
    });
    assert_eq!(
        first
            .lock()
            .query_row("SELECT value FROM atomic_probe", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        2
    );
}

#[test]
fn nested_atomic_failure_preserves_the_callers_transaction() {
    let mut conn = Connection::open_in_memory().unwrap();
    conn.execute_batch("CREATE TABLE atomic_probe(value INTEGER);")
        .unwrap();
    let outer = conn.transaction().unwrap();
    outer
        .execute("INSERT INTO atomic_probe VALUES(1)", [])
        .unwrap();
    let result: ApiResult<()> = atomic(&outer, |db| {
        db.execute("INSERT INTO atomic_probe VALUES(2)", [])?;
        Err(ApiError::invalid_input())
    });
    assert!(result.is_err());
    assert!(!outer.is_autocommit());
    assert_eq!(
        outer
            .query_row("SELECT sum(value) FROM atomic_probe", [], |r| r
                .get::<_, i64>(0))
            .unwrap(),
        1
    );
    outer.commit().unwrap();
    assert_eq!(
        conn.query_row("SELECT sum(value) FROM atomic_probe", [], |r| r
            .get::<_, i64>(0))
            .unwrap(),
        1
    );
}

#[test]
fn a_database_from_a_newer_gateway_is_refused_and_left_untouched() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("gateway.sqlite");
    drop(Db::open(&path).unwrap());
    let newer = SCHEMA_VERSION + 1;
    let connection = Connection::open(&path).unwrap();
    connection
        .execute_batch(&format!("PRAGMA user_version = {newer};"))
        .unwrap();
    drop(connection);
    let error = Db::open(&path).err().unwrap();
    assert!(error.contains("newer than this gateway"), "{error}");
    let version: i64 = Connection::open(&path)
        .unwrap()
        .pragma_query_value(None, "user_version", |row| row.get(0))
        .unwrap();
    assert_eq!(version, newer);
}
