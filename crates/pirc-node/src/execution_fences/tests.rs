use super::*;
use crate::store::{Db, ModeId};

fn setup(db: &Connection) -> (String, Intent, i64) {
    db.add_workspace(
        "repo",
        "node",
        "Repo",
        "/repo",
        ModeId::new("directory").unwrap(),
    )
    .unwrap();
    let s = db
        .create_session("repo", "/private/session", "alice")
        .unwrap();
    let lease = db.acquire_lease(&s.id, "phone", false, 60_000).unwrap();
    (
        s.id,
        Intent {
            operation_id: "transition-1".into(),
            plan_hash: "a".repeat(64),
            expected_workspace_id: "repo".into(),
            expected_runner_epoch: s.runner_epoch,
        },
        lease.generation,
    )
}
#[test]
fn receipt_survives_restart_takeover_and_deletion_without_releasing_the_fence() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("node.db");
    let (session, intent, generation) = {
        let db = Db::open(&path).unwrap();
        let db = db.lock();
        let (session, intent, generation) = setup(&db);
        let r = accept(&db, "alice", &session, &intent, "phone", generation).unwrap();
        assert_eq!(r.state, "fenced");
        assert!(!r.revocation_confirmed && !r.target_installed);
        assert_eq!(
            require_open(&db, &session).unwrap_err().code,
            "environment_transition_pending"
        );
        // Context/control records remain readable; no source binding is rewritten.
        assert_eq!(
            db.claim_session(&session, "alice", false)
                .unwrap()
                .workspace_id,
            "repo"
        );
        db.acquire_lease(&session, "web", true, 60_000).unwrap();
        let replay = accept(&db, "alice", &session, &intent, "phone", generation).unwrap();
        assert_eq!(
            serde_json::to_value(&r).unwrap(),
            serde_json::to_value(&replay).unwrap()
        );
        (session, intent, generation)
    };
    let db = Db::open(&path).unwrap();
    let db = db.lock();
    assert!(require_open(&db, &session).is_err());
    let mut changed = intent.clone();
    changed.plan_hash = "b".repeat(64);
    assert!(accept(&db, "alice", &session, &changed, "phone", generation).is_err());
    assert!(
        receipt(&db, "bob", &session, &intent.operation_id)
            .unwrap()
            .is_none()
    );
    assert!(
        db.execute("UPDATE execution_fences SET intent_json='{}'", [])
            .is_err()
    );
    assert!(db.execute("DELETE FROM execution_fences", []).is_err());
    db.begin_session_deletion(&session, "alice").unwrap();
    db.finish_session_deletion(&session).unwrap();
    assert_eq!(
        accept(&db, "alice", &session, &intent, "phone", generation)
            .unwrap()
            .state,
        "deleted"
    );
    assert!(db.get_session(&session).is_err());
}
#[test]
fn stale_unauthorized_and_failed_acceptance_leave_no_fence() {
    let db = Db::memory();
    let db = db.lock();
    let (session, intent, generation) = setup(&db);
    let mut stale = intent.clone();
    stale.expected_runner_epoch += 1;
    assert_eq!(
        accept(&db, "alice", &session, &stale, "phone", generation)
            .unwrap_err()
            .code,
        "stale_environment"
    );
    assert!(accept(&db, "bob", &session, &intent, "phone", generation).is_err());
    assert!(accept(&db, "alice", &session, &intent, "other-device", generation).is_err());
    let mut invalid = intent.clone();
    invalid.plan_hash = "not-a-hash".into();
    assert!(accept(&db, "alice", &session, &invalid, "phone", generation).is_err());
    db.execute_batch("CREATE TRIGGER fail_fence BEFORE INSERT ON execution_fences BEGIN SELECT RAISE(ABORT,'disk full'); END;").unwrap();
    assert!(accept(&db, "alice", &session, &intent, "phone", generation).is_err());
    assert!(require_open(&db, &session).is_ok());
    assert!(
        receipt(&db, "alice", &session, &intent.operation_id)
            .unwrap()
            .is_none()
    );
}
#[test]
fn concurrent_transition_intents_have_one_winner_and_preserve_other_sessions() {
    let db = std::sync::Arc::new(Db::memory());
    let (session, intent, generation) = setup(&db.lock());
    let peer = db.lock().create_session("repo", "/peer", "alice").unwrap();
    let barrier = std::sync::Arc::new(std::sync::Barrier::new(3));
    let handles = (0..2)
        .map(|n| {
            let db = db.clone();
            let barrier = barrier.clone();
            let session = session.clone();
            let mut intent = intent.clone();
            intent.operation_id = format!("switch-{n}");
            std::thread::spawn(move || {
                barrier.wait();
                accept(&db.lock(), "alice", &session, &intent, "phone", generation)
            })
        })
        .collect::<Vec<_>>();
    barrier.wait();
    let outcomes = handles
        .into_iter()
        .map(|h| h.join().unwrap())
        .collect::<Vec<_>>();
    assert_eq!(outcomes.iter().filter(|r| r.is_ok()).count(), 1);
    assert!(require_open(&db.lock(), &session).is_err());
    assert!(require_open(&db.lock(), &peer.id).is_ok());
    assert_eq!(
        db.lock().get_session(&peer.id).unwrap().workspace_id,
        "repo"
    );
}
#[test]
fn migration_does_not_invent_historical_transition_fences() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("node.db");
    let session = {
        let db = Db::open(&path).unwrap();
        let db = db.lock();
        let (session, _, _) = setup(&db);
        db.execute_batch(concat!(
            include_str!("../host_commands/remove_schema.sql"),
            include_str!("../process_journal/remove_schema.sql"),
            include_str!("remove_schema.sql")
        ))
        .unwrap();
        db.execute_batch("PRAGMA user_version=2011;").unwrap();
        session
    };
    let db = Db::open(&path).unwrap();
    let db = db.lock();
    assert!(require_open(&db, &session).is_ok());
    let count: i64 = db
        .query_row("SELECT COUNT(*) FROM execution_fences", [], |r| r.get(0))
        .unwrap();
    assert_eq!(count, 0);
    assert_eq!(db.get_session(&session).unwrap().workspace_id, "repo");
}
#[tokio::test]
async fn draining_is_idempotent_does_not_touch_files_and_never_claims_revocation() {
    let f = crate::workspace_memory::tests::Fixture::new().await;
    let row = f.node.db.lock().get_session(&f.current).unwrap();
    let workspace = f.node.db.lock().get_workspace("repo").unwrap();
    let user_file = std::path::Path::new(&workspace.canonical_path).join("user.txt");
    std::fs::write(&user_file, b"later user edits").unwrap();
    {
        let mut history =
            pirc_agent::session_store::SessionStore::open(f.dir.clone(), &workspace.canonical_path)
                .unwrap();
        history
            .append(pirc_agent::session_store::EntryData::Message(
                pirc_protocol::Message::User {
                    content: pirc_protocol::UserContent::Text(
                        "Retain this original conversation context".into(),
                    ),
                    timestamp: 1,
                },
            ))
            .unwrap();
    }
    let history_before =
        serde_json::to_value(pirc_agent::session_store::read_session_history(&f.dir).unwrap())
            .unwrap();
    assert!(
        history_before
            .to_string()
            .contains("Retain this original conversation context")
    );

    let peer = f
        .node
        .db
        .lock()
        .create_session("repo", "/peer", "alice")
        .unwrap();
    let lease = f
        .node
        .db
        .lock()
        .acquire_lease(&f.current, "phone", false, 60_000)
        .unwrap();
    let intent = Intent {
        operation_id: "drain".into(),
        plan_hash: "a".repeat(64),
        expected_workspace_id: "repo".into(),
        expected_runner_epoch: row.runner_epoch,
    };
    accept(
        &f.node.db.lock(),
        "alice",
        &f.current,
        &intent,
        "phone",
        lease.generation,
    )
    .unwrap();
    let (a, b) = tokio::join!(
        drain(&f.node, "alice", &f.current, "drain"),
        drain(&f.node, "alice", &f.current, "drain")
    );
    for r in [a.unwrap(), b.unwrap()] {
        assert_eq!(r.state, "supervisor_drained");
        assert!(!r.revocation_confirmed && !r.target_installed);
    }
    assert!(require_open(&f.node.db.lock(), &f.current).is_err());
    assert!(f.node.session_mode(&peer.id).is_ok());
    assert_eq!(std::fs::read(&user_file).unwrap(), b"later user edits");
    assert_eq!(
        serde_json::to_value(pirc_agent::session_store::read_session_history(&f.dir).unwrap())
            .unwrap(),
        history_before
    );
    assert!(
        f.node
            .db
            .lock()
            .claim_session(&f.current, "alice", false)
            .is_ok()
    );
    f.node.close().await;
}

#[tokio::test]
async fn failed_or_panicked_participant_does_not_skip_other_stops() {
    use tokio::sync::oneshot;
    let (release, held) = oneshot::channel();
    let (observed, stopped) = oneshot::channel();
    let task = tokio::spawn(settle_all([
        async {
            held.await.unwrap();
            Ok(())
        }
        .boxed(),
        async {
            Err(ApiError::new(
                503,
                "host_stop_unconfirmed",
                "synthetic observer failure",
            ))
        }
        .boxed(),
        async {
            panic!("synthetic observer panic");
            #[allow(unreachable_code)]
            Ok(())
        }
        .boxed(),
        async {
            observed.send(()).unwrap();
            Ok(())
        }
        .boxed(),
    ]));
    tokio::time::timeout(Duration::from_secs(1), stopped)
        .await
        .unwrap()
        .unwrap();
    assert!(
        !task.is_finished(),
        "pending participant must not be reported as stopped"
    );
    release.send(()).unwrap();
    assert_eq!(
        task.await.unwrap().unwrap_err().code,
        "host_stop_unconfirmed"
    );
    let panic_only = settle_all([
        async {
            panic!("synthetic sole failure");
            #[allow(unreachable_code)]
            Ok(())
        }
        .boxed(),
        async { Ok(()) }.boxed(),
    ])
    .await
    .unwrap_err();
    assert_eq!(panic_only.code, ApiError::internal().code);
}

#[tokio::test]
async fn unknown_host_history_does_not_leave_live_terminals_running() {
    let f = crate::workspace_memory::tests::Fixture::new().await;
    let row = f.node.db.lock().get_session(&f.current).unwrap();
    let root: std::path::PathBuf = f
        .node
        .db
        .lock()
        .get_workspace("repo")
        .unwrap()
        .canonical_path
        .into();
    let lease = f
        .node
        .db
        .lock()
        .acquire_lease(&f.current, "phone", false, 60_000)
        .unwrap();
    f.node
        .terminals
        .create(&f.current, &root, None, None, ("phone", lease.generation))
        .unwrap();
    let peer = f
        .node
        .db
        .lock()
        .create_session("repo", "/unused-peer", "alice")
        .unwrap();
    let peer_lease = f
        .node
        .db
        .lock()
        .acquire_lease(&peer.id, "phone", false, 60_000)
        .unwrap();
    let peer_terminal = f
        .node
        .terminals
        .create(
            &peer.id,
            &root,
            None,
            None,
            ("phone", peer_lease.generation),
        )
        .unwrap();
    f.node.db.lock().execute(
        "INSERT INTO host_command_runs VALUES('lost',?1,'repo',0,'previous-incarnation','request','running',1,1)", [&f.current],
    ).unwrap();
    accept(
        &f.node.db.lock(),
        "alice",
        &f.current,
        &Intent {
            operation_id: "unknown-host".into(),
            plan_hash: "a".repeat(64),
            expected_workspace_id: "repo".into(),
            expected_runner_epoch: row.runner_epoch,
        },
        "phone",
        lease.generation,
    )
    .unwrap();
    for _ in 0..2 {
        let result = drain(&f.node, "alice", &f.current, "unknown-host")
            .await
            .unwrap();
        assert_eq!(result.state, "blocked");
        assert_eq!(result.error_code.as_deref(), Some("host_stop_unconfirmed"));
        assert!(!result.revocation_confirmed && !result.target_installed);
        let receipt = serde_json::to_value(result).unwrap();
        assert_eq!(receipt["hostCommands"]["unresolved"], 1);
        assert_eq!(receipt["terminals"]["observersSettled"], 1);
        assert_eq!(receipt["terminals"]["unresolved"], 0);
        assert!(f.node.terminals.list(&f.current).is_empty());
        assert_eq!(f.node.terminals.list(&peer.id)[0].id, peer_terminal.id);
        assert!(require_open(&f.node.db.lock(), &f.current).is_err());
    }
    f.node.close().await;
}
