use super::*;

#[test]
fn wal_mode_retries_until_a_concurrent_write_transaction_finishes() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("node.sqlite");
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
    let path = dir.path().join("node.sqlite");
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
fn opens_private_and_refuses_other_databases() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("gateway.sqlite");
    let db = Db::open(&path).unwrap();
    let version: i64 = db
        .lock()
        .pragma_query_value(None, "user_version", |row| row.get(0))
        .unwrap();
    assert_eq!(version, SCHEMA_VERSION);
    let journal: String = db
        .lock()
        .pragma_query_value(None, "journal_mode", |row| row.get(0))
        .unwrap();
    assert_eq!(journal, "wal");
    drop(db);
    use std::os::unix::fs::PermissionsExt;
    let mode = std::fs::metadata(&path).unwrap().permissions().mode();
    assert_eq!(mode & 0o777, 0o600);
    // Opening again keeps it.
    Db::open(&path).unwrap();
    refuse_typescript_database(&path).unwrap();

    for (version, message) in [
        (19, "TypeScript node"),
        (1000, "pirc-gateway database"),
        (5000, "does not know"),
    ] {
        let other = dir.path().join(format!("{version}.sqlite"));
        let connection = Connection::open(&other).unwrap();
        connection
            .execute_batch(&format!(
                "CREATE TABLE t (x); PRAGMA user_version = {version};"
            ))
            .unwrap();
        drop(connection);
        let error = Db::open(&other).err().unwrap();
        assert!(error.contains(message), "{error}");
    }
    assert!(
        refuse_typescript_database(&dir.path().join("19.sqlite"))
            .unwrap_err()
            .contains("upgrade notes")
    );
    let unversioned = dir.path().join("unversioned.sqlite");
    Connection::open(&unversioned)
        .unwrap()
        .execute_batch("CREATE TABLE t (x);")
        .unwrap();
    assert!(
        Db::open(&unversioned)
            .err()
            .unwrap()
            .contains("no pirc schema version")
    );
}

/// Columns of every table and the indexes.
fn columns(connection: &Connection) -> Vec<String> {
    let mut statement = connection
        .prepare(
            "SELECT m.name || '.' || p.name || ':' || p.type FROM sqlite_master m, \
                 pragma_table_info(m.name) p WHERE m.type='table' ORDER BY m.name, p.cid",
        )
        .unwrap();
    let mut out: Vec<String> = statement
        .query_map([], |row| row.get(0))
        .unwrap()
        .map(Result::unwrap)
        .collect();
    let mut indexes = connection
        .prepare(
            "SELECT name FROM sqlite_master WHERE type='index' AND sql IS NOT NULL ORDER BY name",
        )
        .unwrap();
    out.extend(
        indexes
            .query_map([], |row| row.get::<_, String>(0))
            .unwrap()
            .map(Result::unwrap),
    );
    out
}

#[test]
fn migrates_the_first_node_schema() {
    // Schema 2000: no upload provenance, no project fence.
    let first = SCHEMA
            .replace(include_str!("pots.sql"), "")
            .replace(include_str!("session_creations.sql"), "")
            .replace(include_str!("creation_uploads.sql"), "")
            .replace(include_str!("creation_admissions.sql"), "")
        .replace(include_str!("creation_cancellations.sql"), "")
        .replace(include_str!("creation_pre_stops.sql"), "")
        .replace(include_str!("creation_admission_attempts.sql"), "")
        .replace(include_str!("../command_environment.sql"), "")
        .replace(include_str!("../upload_origins.sql"), "")
        .replace(include_str!("../execution_fences/schema.sql"), "")
        .replace(include_str!("../process_journal/schema.sql"), "")
        .replace(include_str!("../process_journal/guard.sql"), "")
        .replace(include_str!("../host_commands/schema.sql"), "")
        .replace(include_str!("../host_commands/resources.sql"), "")
        .replace(include_str!("../terminals/journal.sql"), "")
        .replace(include_str!("../browser/journal.sql"), "")
        .replace(include_str!("../host_commands/approval.sql"), "")
        .replace(include_str!("../process_journal/resource_kinds.sql"), "")
        .replace(include_str!("../terminals/io_owners.sql"), "")
        .replace(include_str!("../terminals/host.sql"), "")
        .replace(include_str!("../terminals/requests.sql"), "")
        .replace(include_str!("../terminals/request_results.sql"), "")
        .replace(include_str!("../terminals/request_acknowledgements.sql"), "")
        .replace(include_str!("../execution_fences/binding_generations.sql"), "")
        .replace(include_str!("../execution_fences/installation.sql"), "")
        .replace(include_str!("../execution_fences/authority.sql"), "")
            .replace(
                "  kind TEXT NOT NULL DEFAULT 'image',\n  -- Where it was uploaded; it is usable in that workspace only and is\n  -- deleted with it. NULL for uploads older than schema 2001.\n  workspace_id TEXT,\n  session_id TEXT\n);\nCREATE INDEX uploads_workspace ON uploads(workspace_id);",
                "  kind TEXT NOT NULL DEFAULT 'image'\n);",
            );
    let fence = first.find("-- A chat project being deleted").unwrap();
    let end = fence + first[fence..].find("\n);\n").unwrap() + "\n);\n".len();
    let first = format!("{}{}", &first[..fence], &first[end..]);
    assert!(
        !first.contains("workspace_deletions") && !first.contains("uploads_workspace"),
        "schema.sql changed: update this test"
    );
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("node.sqlite");
    let old = Connection::open(&path).unwrap();
    old.execute_batch(&format!(
        "BEGIN; {first}\nPRAGMA user_version = {FIRST_SCHEMA_VERSION}; COMMIT;"
    ))
    .unwrap();
    old.execute(
        "INSERT INTO uploads (id,owner_user,mime_type,byte_size,storage_name,sha256,created_at) \
             VALUES ('upload_old','u','image/png',1,'old.bin','s',0)",
        [],
    )
    .unwrap();
    drop(old);
    let db = Db::open(&path).unwrap();
    let connection = db.lock();
    let version: i64 = connection
        .pragma_query_value(None, "user_version", |row| row.get(0))
        .unwrap();
    assert_eq!(version, SCHEMA_VERSION);
    assert_eq!(
        connection.get_upload("upload_old").unwrap().workspace_id,
        None
    );
    assert_eq!(columns(&connection), columns(&Db::memory().lock()));
}

#[test]
fn a_project_being_deleted_is_fenced() {
    let db = Db::memory();
    let connection = db.lock();
    connection
        .add_workspace(
            "p",
            "node",
            "P",
            "/state/chat/p",
            ModeId::new("chat").unwrap(),
        )
        .unwrap();
    let session = connection.create_session("p", "/private/1", "u").unwrap();
    let upload = UploadRow {
        id: "upload_1".into(),
        owner_user: "u".into(),
        mime_type: "image/png".into(),
        byte_size: 1,
        storage_name: "a.bin".into(),
        sha256: "s".into(),
        kind: UploadKind::Image,
        filename: None,
        workspace_id: Some("p".into()),
        session_id: Some(session.id.clone()),
    };
    connection.create_upload(&upload).unwrap();
    assert_eq!(
        connection
            .begin_workspace_deletion("p", "v")
            .unwrap_err()
            .status,
        403
    );
    connection.begin_workspace_deletion("p", "u").unwrap();
    connection.begin_workspace_deletion("p", "u").unwrap();
    assert!(connection.list_workspaces().unwrap().is_empty());
    assert_eq!(connection.get_workspace("p").unwrap_err().status, 409);
    assert_eq!(
        connection
            .create_session("p", "/private/2", "u")
            .unwrap_err()
            .status,
        409
    );
    assert_eq!(
        connection
            .claim_session(&session.id, "u", false)
            .unwrap_err()
            .status,
        409
    );
    assert_eq!(connection.workspace_uploads("p").unwrap(), [upload]);
    // Not before its chats are gone.
    assert_eq!(
        connection
            .finish_workspace_deletion("p")
            .unwrap_err()
            .status,
        500
    );
    connection.finish_session_deletion(&session.id).unwrap();
    connection.finish_workspace_deletion("p").unwrap();
    assert!(connection.find_workspace("p").unwrap().is_none());
    assert_eq!(connection.get_upload("upload_1").unwrap_err().status, 404);
    assert_eq!(
        connection.workspace_deletion("p").unwrap().unwrap().status,
        DeletionStatus::Deleted
    );
}

fn store_with_session() -> (Db, String) {
    let db = Db::memory();
    let connection = db.lock();
    connection
        .add_workspace("w", "node", "W", "/w", ModeId::new("directory").unwrap())
        .unwrap();
    let session = connection.create_session("w", "/private/1", "u").unwrap();
    drop(connection);
    (db, session.id)
}

#[test]
fn stored_mode_ids_never_widen_to_directory() {
    let db = Db::memory();
    let db = db.lock();
    let custom = ModeId::new("research").unwrap();
    db.add_workspace("custom", "node", "Custom", "/custom", custom.clone())
        .unwrap();
    assert_eq!(db.list_workspaces().unwrap()[0].mode, custom);
    check_role(&db.list_workspaces().unwrap(), &[custom]).unwrap();
    assert!(
        check_role(
            &db.list_workspaces().unwrap(),
            &[ModeId::new("directory").unwrap()]
        )
        .is_err()
    );
    db.execute("UPDATE workspaces SET kind='INVALID' WHERE id='custom'", [])
        .unwrap();
    assert!(db.get_workspace("custom").is_err());
}

#[test]
fn workspaces_and_role_pin() {
    let db = Db::memory();
    let db = db.lock();
    db.add_workspace("b", "node", "B", "/b", ModeId::new("directory").unwrap())
        .unwrap();
    assert_eq!(
        db.add_workspace(
            "b",
            "node",
            "Other",
            "/c",
            ModeId::new("directory").unwrap()
        )
        .unwrap_err()
        .message,
        "Workspace ID or path is already registered"
    );
    assert_eq!(
        db.add_workspace("c", "node", "C", "/b", ModeId::new("directory").unwrap())
            .unwrap_err()
            .status,
        409
    );
    db.sync_workspaces(
        "node",
        &[pirc_config::ConfigWorkspace {
            mode: ModeId::new("directory").unwrap(),
            id: "a".into(),
            path: "/a".into(),
            display_name: "A".into(),
            defaults: serde_json::json!({ "x": 1 }).as_object().unwrap().clone(),
        }],
    )
    .unwrap();
    let listed = db.list_workspaces().unwrap();
    assert_eq!(
        listed.iter().map(|w| w.id.as_str()).collect::<Vec<_>>(),
        ["a", "b"]
    );
    assert_eq!(listed[0].defaults["x"], 1);
    check_role(&listed, &[ModeId::new("directory").unwrap()]).unwrap();
    assert!(
        check_role(&listed, &[ModeId::new("chat").unwrap()])
            .unwrap_err()
            .contains("incompatible with configured accepted modes")
    );
    let chat = db
        .ensure_chat_workspace("chats", "node", "Chats", "/s/chat/chats")
        .unwrap();
    assert_eq!(chat.mode, ModeId::new("chat").unwrap());
    assert_eq!(
        db.get_workspace("nope").unwrap_err().message,
        "Workspace not found"
    );
    // Capability authorization belongs to the catalog-aware route, not SQL storage.
    db.set_workspace_trust("chats", Some("h"), "u").unwrap();
    db.set_workspace_trust("a", Some("h"), "u").unwrap();
    assert_eq!(db.get_workspace_trust("a").unwrap().as_deref(), Some("h"));
    db.set_workspace_trust("a", None, "u").unwrap();
    assert_eq!(db.get_workspace_trust("a").unwrap(), None);
}

#[test]
fn sessions_names_and_deletion() {
    let (db, id) = store_with_session();
    let db = db.lock();
    let session = db.get_session(&id).unwrap();
    assert_eq!(
        (session.name.as_str(), session.name_source),
        (PLACEHOLDER_SESSION_NAME, NameSource::Auto)
    );
    assert!(db.auto_rename_session(&id, "Title").unwrap());
    assert!(!db.auto_rename_session(&id, "Title").unwrap());
    db.rename_session(&id, "Mine").unwrap();
    assert!(!db.auto_rename_session(&id, "Other").unwrap());
    assert_eq!(db.get_session(&id).unwrap().name, "Mine");
    assert_eq!(
        db.claim_session(&id, "v", false).unwrap_err().message,
        "Session belongs to another user"
    );
    db.claim_session(&id, "u", false).unwrap();
    assert_eq!(db.increment_epoch(&id).unwrap(), 1);
    assert_eq!(db.finish_session_deletion(&id).unwrap_err().status, 500);
    db.begin_session_deletion(&id, "u").unwrap();
    assert_eq!(
        db.claim_session(&id, "u", false).unwrap_err().message,
        "This chat is being deleted. Retry Delete to finish cleanup."
    );
    db.claim_session(&id, "u", true).unwrap();
    db.create_run(&id).unwrap();
    db.finish_session_deletion(&id).unwrap();
    assert_eq!(db.get_session(&id).unwrap_err().status, 404);
    assert_eq!(
        db.session_deletion(&id).unwrap(),
        Some(SessionDeletion {
            owner_user: "u".into(),
            status: DeletionStatus::Deleted,
        })
    );
}

#[test]
fn runs_commands_and_recovery() {
    let (db, id) = store_with_session();
    let db = db.lock();
    let run = db.create_run(&id).unwrap();
    assert_eq!(
        db.create_run(&id).unwrap_err().message,
        "Session already has an active run"
    );
    db.update_run(&run, RunStatus::Running, None).unwrap();
    db.update_run(&run, RunStatus::Failed, Some("boom"))
        .unwrap();
    let latest = db.latest_run(&id).unwrap().unwrap();
    assert_eq!(latest.status, RunStatus::Failed);
    assert_eq!(latest.failure_reason.as_deref(), Some("boom"));
    assert!(latest.started_at.is_some() && latest.ended_at.is_some());
    // An auto-retry runs again: the end and the failure go.
    db.update_run(&run, RunStatus::Running, None).unwrap();
    let latest = db.latest_run(&id).unwrap().unwrap();
    assert_eq!((latest.ended_at, latest.failure_reason), (None, None));
    assert_eq!(
        db.get_session(&id).unwrap().run_status,
        Some(RunStatus::Running)
    );
    assert_eq!(
        db.active_runs().unwrap(),
        [(id.clone(), RunStatus::Running)]
    );

    let payload = serde_json::json!({ "type": "stop" });
    let (row, duplicate) = db.receive_command("c", &id, "h", &payload).unwrap();
    assert!(!duplicate);
    assert_eq!(
        (row.status, &row.payload),
        (CommandStatus::Received, &payload)
    );
    assert!(db.receive_command("c", &id, "h", &payload).unwrap().1);
    assert_eq!(
        db.receive_command("c", &id, "other", &payload)
            .unwrap_err()
            .message,
        "commandId was already used with a different payload"
    );
    db.update_command("c", CommandStatus::Dispatched, None, None)
        .unwrap();
    let interaction = db
        .create_interaction(&id, 1, "rpc", "select", &Map::new(), now_ms() + 60_000)
        .unwrap();
    db.acquire_lease(&id, "browser", false, 60_000).unwrap();
    db.set_runner_state(&id, RunnerState::Ready).unwrap();

    let recovery = db.recover_startup().unwrap();
    assert_eq!(
        recovery,
        Recovery {
            interrupted_runs: 1,
            stale_interactions: 1,
            unknown_commands: 1
        }
    );
    let latest = db.latest_run(&id).unwrap().unwrap();
    assert_eq!(latest.status, RunStatus::Interrupted);
    assert_eq!(latest.failure_reason.as_deref(), Some("node restarted"));
    assert_eq!(
        db.get_interaction(&interaction.id).unwrap().status,
        InteractionStatus::Stale
    );
    let command = db.get_command("c").unwrap();
    assert_eq!(command.status, CommandStatus::OutcomeUnknown);
    assert_eq!(
        command.error.as_deref(),
        Some("node restarted before RPC acceptance was recorded")
    );
    assert_eq!(db.get_lease(&id).unwrap(), None);
    let session = db.get_session(&id).unwrap();
    assert!(session.partial_output_lost);
    assert_eq!(session.runner_state, RunnerState::Stopped);
    db.update_command(
        "c",
        CommandStatus::Accepted,
        Some(&serde_json::json!({ "ok": true })),
        None,
    )
    .unwrap();
    assert_eq!(
        db.get_command("c").unwrap().result,
        serde_json::json!({ "ok": true })
    );
    assert_eq!(
        db.get_command("nope").unwrap_err().message,
        "Command not found"
    );
}

#[test]
fn leases_and_interactions() {
    let (db, id) = store_with_session();
    let db = db.lock();
    let lease = db.acquire_lease(&id, "a", false, 60_000).unwrap();
    assert_eq!(lease.generation, 1);
    assert_eq!(
        db.acquire_lease(&id, "b", false, 60_000)
            .unwrap_err()
            .message,
        "Another client holds control"
    );
    assert_eq!(
        db.acquire_lease(&id, "a", false, 60_000)
            .unwrap()
            .generation,
        2
    );
    let forced = db.acquire_lease(&id, "b", true, 60_000).unwrap();
    assert_eq!(forced.generation, 3);
    assert_eq!(
        db.validate_lease(&id, "a", 2).unwrap_err().code,
        "lost_control"
    );
    db.heartbeat_lease(&id, "b", 3, 1_000).unwrap();
    let view = db.get_lease(&id).unwrap().unwrap();
    assert!(!view.expired);
    db.release_lease(&id, "b", 3).unwrap();
    assert_eq!(db.get_lease(&id).unwrap(), None);
    assert_eq!(
        db.acquire_lease("nope", "a", false, 1).unwrap_err().status,
        404
    );

    let later = now_ms() + 60_000;
    let first = db
        .create_interaction(&id, 1, "r1", "confirm", &Map::new(), later)
        .unwrap();
    db.create_interaction(&id, 1, "r2", "input", &Map::new(), later)
        .unwrap();
    db.create_interaction(&id, 1, "r3", "input", &Map::new(), now_ms() - 1)
        .unwrap();
    let pending = db.pending_interactions(&id).unwrap();
    assert_eq!(
        pending
            .iter()
            .map(|i| i.rpc_id.as_str())
            .collect::<Vec<_>>(),
        ["r1", "r2"]
    );
    assert_eq!(
        db.claim_interaction(&first.id, &id, 2, &Value::Null)
            .unwrap_err()
            .message,
        "Interaction is no longer answerable"
    );
    db.claim_interaction(&first.id, &id, 1, &serde_json::json!({ "confirmed": true }))
        .unwrap();
    assert_eq!(
        db.claim_interaction(&first.id, &id, 1, &Value::Null)
            .unwrap_err()
            .code,
        "stale_interaction"
    );
    assert!(
        db.cancel_interaction_by_rpc_id(&id, 1, "r2")
            .unwrap()
            .is_some()
    );
    assert_eq!(db.cancel_interaction_by_rpc_id(&id, 1, "r2").unwrap(), None);
    db.create_interaction(&id, 1, "r4", "input", &Map::new(), later)
        .unwrap();
    db.stale_epoch_interactions(&id, 2).unwrap();
    assert!(db.pending_interactions(&id).unwrap().is_empty());
    assert_eq!(db.get_interaction("nope").unwrap_err().status, 404);

    let upload = UploadRow {
        id: "upload_1".into(),
        owner_user: "u".into(),
        mime_type: "text/plain".into(),
        byte_size: 3,
        storage_name: "x.bin".into(),
        sha256: "s".into(),
        kind: UploadKind::File,
        filename: Some("a.txt".into()),
        workspace_id: None,
        session_id: None,
    };
    db.create_upload(&upload).unwrap();
    assert_eq!(db.get_upload("upload_1").unwrap(), upload);
    assert_eq!(
        db.get_upload("nope").unwrap_err().message,
        "Upload not found"
    );
}

#[test]
fn sessions_serialize_as_the_public_row() {
    let row = SessionRow {
        id: "session_1".into(),
        workspace_id: "w".into(),
        node_id: None,
        owner_user: Some("u".into()),
        name: PLACEHOLDER_SESSION_NAME.into(),
        name_source: NameSource::Auto,
        runner_state: RunnerState::Stopped,
        run_status: Some(RunStatus::WaitingInput),
        runner_epoch: 0,
        pinned_at: None,
        settled_at: None,
        unread: false,
        created_at: 1,
        updated_at: 2,
        private_session_path: "/secret".into(),
        pi_session_id: Some("pi".into()),
        partial_output_lost: true,
    };
    assert_eq!(
        serde_json::to_value(&row).unwrap(),
        serde_json::json!({ "id": "session_1", "workspaceId": "w", "nodeId": null,
                "name": "New session", "nameSource": "auto", "runnerState": "stopped",
                "runStatus": "waiting_input", "runnerEpoch": 0, "pinnedAt": null,
                "settledAt": null, "unread": false, "createdAt": 1, "updatedAt": 2 })
    );
    Db::memory();
}
