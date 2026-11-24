use super::*;
use crate::store::{Db, ModeId};

const OWNER: &str = "alice";

fn input() -> Input {
    Input {
        operation_id: "draft-123".into(),
        workspace_id: "repo".into(),
        submission_hash: "a".repeat(64),
    }
}

fn setup(db: &Connection) {
    db.add_workspace(
        "repo",
        "node",
        "Repository",
        "/repo",
        ModeId::new("directory").unwrap(),
    )
    .unwrap();
    db.add_workspace(
        "other",
        "node",
        "Other",
        "/other",
        ModeId::new("directory").unwrap(),
    )
    .unwrap();
}

fn count(db: &Connection, table: &str) -> i64 {
    db.query_row(&format!("SELECT count(*) FROM {table}"), [], |r| r.get(0))
        .unwrap()
}

#[test]
fn reservation_survives_restart_and_does_not_publish_a_session() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("node.sqlite");
    let first = {
        let db = Db::open(&path).unwrap();
        let mut conn = db.lock();
        setup(&conn);
        let row = reserve(&mut conn, OWNER, &input()).unwrap();
        assert_eq!(row.state, State::Reserved);
        assert_eq!(count(&conn, "sessions"), 0);
        row.session_id
    };
    let db = Db::open(&path).unwrap();
    let mut conn = db.lock();
    let row = reserve(&mut conn, OWNER, &input()).unwrap();
    assert_eq!(row.session_id, first);
    assert_eq!(count(&conn, "session_creations"), 1);
    let ready = initialize(&mut conn, OWNER, &input(), dir.path()).unwrap();
    assert_eq!(ready.state, State::Ready);
    assert_eq!(ready.session_id, first);
    assert_eq!(count(&conn, "sessions"), 1);
    assert_eq!(count(&conn, "runs"), 0);
    assert_eq!(count(&conn, "commands"), 0);
}

#[test]
fn lost_ready_response_and_concurrent_connections_keep_one_identity() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("node.sqlite");
    setup(&Db::open(&path).unwrap().lock());
    let barrier = std::sync::Barrier::new(6);
    let ids = std::thread::scope(|scope| {
        let handles: Vec<_> = (0..6)
            .map(|_| {
                scope.spawn(|| {
                    let db = Db::open(&path).unwrap();
                    barrier.wait();
                    let mut conn = db.lock();
                    reserve(&mut conn, OWNER, &input()).unwrap();
                    initialize(&mut conn, OWNER, &input(), dir.path())
                        .unwrap()
                        .session_id
                })
            })
            .collect();
        handles
            .into_iter()
            .map(|h| h.join().unwrap())
            .collect::<Vec<_>>()
    });
    assert!(ids.iter().all(|id| id == &ids[0]));
    let db = Db::open(&path).unwrap();
    let mut conn = db.lock();
    let row = read(&conn, OWNER, &input().operation_id).unwrap().unwrap();
    assert_eq!(row.state, State::Ready);
    let storage = dir.path().join(&row.session_id);
    std::fs::write(storage.join("session.jsonl"), "user history").unwrap();
    reserve(&mut conn, OWNER, &input()).unwrap();
    assert_eq!(
        initialize(&mut conn, OWNER, &input(), dir.path())
            .unwrap()
            .session_id,
        ids[0]
    );
    assert_eq!(
        std::fs::read_to_string(storage.join("session.jsonl")).unwrap(),
        "user history"
    );
    assert_eq!(count(&conn, "session_creations"), 1);
    assert_eq!(count(&conn, "sessions"), 1);
}

#[test]
fn identities_are_owner_scoped_and_bound_to_the_original_submission() {
    let db = Db::memory();
    let mut conn = db.lock();
    setup(&conn);
    let alice = reserve(&mut conn, OWNER, &input()).unwrap();
    assert!(read(&conn, "bob", &input().operation_id).unwrap().is_none());
    let bob = reserve(&mut conn, "bob", &input()).unwrap();
    assert_ne!(alice.session_id, bob.session_id);
    for changed in [
        Input {
            workspace_id: "other".into(),
            ..input()
        },
        Input {
            submission_hash: "b".repeat(64),
            ..input()
        },
    ] {
        assert_eq!(reserve(&mut conn, OWNER, &changed).unwrap_err().status, 409);
        assert_eq!(
            initialize(&mut conn, OWNER, &changed, Path::new("/unused"))
                .unwrap_err()
                .status,
            409
        );
    }
    let another = reserve(
        &mut conn,
        OWNER,
        &Input {
            operation_id: "draft-456".into(),
            ..input()
        },
    )
    .unwrap();
    assert_ne!(
        alice.session_id, another.session_id,
        "equal text in another draft is not a duplicate"
    );
    assert_eq!(count(&conn, "session_creations"), 3);
}

#[test]
fn storage_failure_retries_the_reserved_identity_without_publishing() {
    let db = Db::memory();
    let mut conn = db.lock();
    setup(&conn);
    let row = reserve(&mut conn, OWNER, &input()).unwrap();
    let dir = tempfile::tempdir().unwrap();
    let missing = dir.path().join("missing");
    assert_eq!(
        initialize(&mut conn, OWNER, &input(), &missing)
            .unwrap_err()
            .code,
        "creation_storage_unavailable"
    );
    assert_eq!(count(&conn, "sessions"), 0);
    assert_eq!(
        read(&conn, OWNER, &input().operation_id)
            .unwrap()
            .unwrap()
            .state,
        State::Reserved
    );
    std::fs::create_dir(&missing).unwrap();
    assert_eq!(
        initialize(&mut conn, OWNER, &input(), &missing)
            .unwrap()
            .session_id,
        row.session_id
    );
}

#[test]
fn crash_after_directory_creation_reuses_only_the_empty_reserved_directory() {
    let db = Db::memory();
    let mut conn = db.lock();
    setup(&conn);
    let row = reserve(&mut conn, OWNER, &input()).unwrap();
    let dir = tempfile::tempdir().unwrap();
    std::fs::create_dir(dir.path().join(&row.session_id)).unwrap();
    assert_eq!(
        initialize(&mut conn, OWNER, &input(), dir.path())
            .unwrap()
            .session_id,
        row.session_id
    );
}

#[test]
fn sqlite_failure_after_mkdir_rolls_back_publication_and_is_retryable() {
    let db = Db::memory();
    let mut conn = db.lock();
    setup(&conn);
    let row = reserve(&mut conn, OWNER, &input()).unwrap();
    let dir = tempfile::tempdir().unwrap();
    conn.execute_batch("CREATE TRIGGER refuse_ready BEFORE UPDATE ON session_creations BEGIN SELECT RAISE(ABORT, 'injected failure'); END;").unwrap();
    assert!(initialize(&mut conn, OWNER, &input(), dir.path()).is_err());
    assert!(dir.path().join(&row.session_id).is_dir());
    assert_eq!(count(&conn, "sessions"), 0);
    assert_eq!(
        read(&conn, OWNER, &input().operation_id)
            .unwrap()
            .unwrap()
            .state,
        State::Reserved
    );
    conn.execute_batch("DROP TRIGGER refuse_ready").unwrap();
    assert_eq!(
        initialize(&mut conn, OWNER, &input(), dir.path())
            .unwrap()
            .session_id,
        row.session_id
    );
}

#[test]
fn unexpected_content_and_symlinks_are_preserved_and_refused() {
    for symlink in [false, true] {
        let db = Db::memory();
        let mut conn = db.lock();
        setup(&conn);
        let row = reserve(&mut conn, OWNER, &input()).unwrap();
        let dir = tempfile::tempdir().unwrap();
        let storage = dir.path().join(&row.session_id);
        let outside = tempfile::tempdir().unwrap();
        if symlink {
            std::os::unix::fs::symlink(outside.path(), &storage).unwrap();
        } else {
            std::fs::create_dir(&storage).unwrap();
            std::fs::write(storage.join("keep.txt"), "user edit").unwrap();
        }
        assert_eq!(
            initialize(&mut conn, OWNER, &input(), dir.path())
                .unwrap_err()
                .code,
            "creation_storage_unavailable"
        );
        assert_eq!(count(&conn, "sessions"), 0);
        if symlink {
            assert!(
                std::fs::symlink_metadata(storage)
                    .unwrap()
                    .file_type()
                    .is_symlink()
            );
            assert_eq!(std::fs::read_dir(outside.path()).unwrap().count(), 0);
        } else {
            assert_eq!(
                std::fs::read_to_string(storage.join("keep.txt")).unwrap(),
                "user edit"
            );
        }
    }
}

#[test]
fn session_deletion_fences_delayed_retries_even_after_restart() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("node.sqlite");
    let id = {
        let db = Db::open(&path).unwrap();
        let mut conn = db.lock();
        setup(&conn);
        reserve(&mut conn, OWNER, &input()).unwrap();
        let row = initialize(&mut conn, OWNER, &input(), dir.path()).unwrap();
        conn.begin_session_deletion(&row.session_id, OWNER).unwrap();
        assert_eq!(
            reserve(&mut conn, OWNER, &input()).unwrap().state,
            State::Deleting
        );
        conn.finish_session_deletion(&row.session_id).unwrap();
        std::fs::remove_dir(dir.path().join(&row.session_id)).unwrap();
        row.session_id
    };
    let db = Db::open(&path).unwrap();
    let mut conn = db.lock();
    assert_eq!(
        reserve(&mut conn, OWNER, &input()).unwrap().state,
        State::Deleted
    );
    assert_eq!(
        initialize(&mut conn, OWNER, &input(), dir.path())
            .unwrap()
            .state,
        State::Deleted
    );
    assert_eq!(count(&conn, "sessions"), 0);
    assert!(!dir.path().join(id).exists());
}

#[test]
fn project_deletion_between_reservation_and_creation_never_allocates() {
    let db = Db::memory();
    let mut conn = db.lock();
    setup(&conn);
    let row = reserve(&mut conn, OWNER, &input()).unwrap();
    let dir = tempfile::tempdir().unwrap();
    conn.execute(
        "INSERT INTO workspace_deletions VALUES('repo',?1,'deleting',0)",
        [OWNER],
    )
    .unwrap();
    assert_eq!(
        initialize(&mut conn, OWNER, &input(), dir.path())
            .unwrap()
            .state,
        State::Deleting
    );
    assert_eq!(count(&conn, "sessions"), 0);
    assert!(!dir.path().join(row.session_id).exists());
    assert!(
        reserve(
            &mut conn,
            OWNER,
            &Input {
                operation_id: "another".into(),
                ..input()
            }
        )
        .is_err()
    );
}

#[test]
fn private_recovery_workspaces_cannot_be_reserved_by_another_user() {
    let db = Db::memory();
    let mut conn = db.lock();
    setup(&conn);
    conn.execute("INSERT INTO checkpoint_intents(job,owner,source_session,capture,expected_revision,accept_unresolved,scope_json,created_at) VALUES('job',?1,'source','capture',1,0,'[]',0)", [OWNER]).unwrap();
    conn.execute("INSERT INTO checkpoint_workspaces(workspace_id,job,owner,session_id,created_at) VALUES('repo','job',?1,'recovery',0)", [OWNER]).unwrap();
    assert!(reserve(&mut conn, "bob", &input()).is_err());
    assert_eq!(count(&conn, "session_creations"), 0);
    assert!(reserve(&mut conn, OWNER, &input()).is_ok());
}

#[test]
fn invalid_inputs_do_not_reserve_or_expose_submission_hashes() {
    for id in ["", "../escape", "has space", "slash/id", &"a".repeat(101)] {
        assert!(
            Input {
                operation_id: id.into(),
                ..input()
            }
            .validate()
            .is_err()
        );
    }
    for hash in ["", "abc", &"G".repeat(64), &"a".repeat(65)] {
        assert!(
            Input {
                submission_hash: hash.into(),
                ..input()
            }
            .validate()
            .is_err()
        );
    }
    assert!(serde_json::from_value::<Input>(json!({"operationId":"id","workspaceId":"repo","submissionHash":"a".repeat(64),"user":"bob"})).is_err());
    let db = Db::memory();
    let mut conn = db.lock();
    setup(&conn);
    let row = reserve(&mut conn, OWNER, &input()).unwrap();
    assert!(
        serde_json::to_value(row)
            .unwrap()
            .get("submissionHash")
            .is_none()
    );
}

#[test]
fn retry_never_recreates_missing_ready_storage() {
    let db = Db::memory();
    let mut conn = db.lock();
    setup(&conn);
    let dir = tempfile::tempdir().unwrap();
    reserve(&mut conn, OWNER, &input()).unwrap();
    let row = initialize(&mut conn, OWNER, &input(), dir.path()).unwrap();
    let storage = dir.path().join(row.session_id);
    std::fs::remove_dir(&storage).unwrap();
    assert_eq!(
        initialize(&mut conn, OWNER, &input(), dir.path())
            .unwrap_err()
            .code,
        "creation_storage_unavailable"
    );
    assert!(!storage.exists());
    assert_eq!(count(&conn, "sessions"), 1);
}
