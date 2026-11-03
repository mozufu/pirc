//! Failures and interruption must not turn missing live entries into evidence
//! of stopped processes. All shells and files below belong to isolated fixtures.
use super::*;
use crate::{store::Db, workspace_memory::tests::Fixture};
use serde_json::{Value, json};

fn root(f: &Fixture) -> std::path::PathBuf {
    f.node
        .db
        .lock()
        .get_workspace("repo")
        .unwrap()
        .canonical_path
        .into()
}
fn status(f: &Fixture) -> Value {
    serde_json::to_value(journal::summary(&f.node.db.lock(), &f.current).unwrap()).unwrap()
}
fn open(f: &Fixture, cwd: &Path, shell: &str) -> ApiResult<TerminalInfo> {
    let original = root(f);
    let binding = Binding::capture(&f.node, &f.node.db.lock(), &f.current, &original)?;
    let db = f.node.db.lock();
    f.node.terminals.spawn(
        &f.current,
        cwd,
        80.0,
        24.0,
        shell,
        Environment {
            vars: BTreeMap::from([("HOME".into(), "/nonexistent".into())]),
            binding: Some(binding),
            journal: Some((&f.node, &db)),
        },
    )
}
async fn until_file(path: &Path) {
    tokio::time::timeout(Duration::from_secs(5), async {
        while !path.exists() {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap();
}
fn pending(f: &Fixture, state: &str) -> journal::Record {
    let db = f.node.db.lock();
    let record = journal::Record::reserve(
        &f.node,
        &db,
        &f.current,
        "repo",
        Path::new("/previous-root"),
    )
    .unwrap();
    record.finish(&db, state).unwrap();
    record
}

#[tokio::test]
async fn canceled_dispose_still_joins_the_manually_closed_shell() {
    let f = Fixture::new().await;
    let cwd = root(&f);
    let script = cwd.join("shell");
    crate::test_support::executable(
        &script,
        "#!/bin/sh\ntrap '' HUP\nprintf ready > ready\nwhile IFS= read -r line; do :; done\n",
    );
    let t = open(&f, &cwd, script.to_str().unwrap()).unwrap();
    until_file(&cwd.join("ready")).await;
    let entry = f.node.terminals.lookup(&f.current, &t.id).unwrap();
    f.node.terminals.close(&f.current, &t.id).unwrap();
    assert!(f.node.terminals.list(&f.current).is_empty());
    assert!(
        tokio::time::timeout(
            Duration::from_millis(20),
            f.node.terminals.dispose_session(&f.current)
        )
        .await
        .is_err()
    );
    assert_eq!(status(&f)["unresolved"], 1);
    assert!(!entry.state().info.exited);
    f.node.terminals.dispose_session(&f.current).await.unwrap();
    assert!(entry.state().info.exited);
    assert_eq!(
        status(&f),
        json!({"launches":1,"notStarted":0,"observersSettled":1,"unresolved":0,"historyComplete":false})
    );
    f.node.terminals.dispose_session(&f.current).await.unwrap();
    f.node.close().await;
}

#[tokio::test]
async fn launch_reservation_failure_never_starts_the_shell() {
    let f = Fixture::new().await;
    let cwd = root(&f);
    let script = cwd.join("must-not-launch");
    crate::test_support::executable(&script, "#!/bin/sh\nprintf bad > launched\n");
    f.node.db.lock().execute_batch("CREATE TRIGGER no_terminal_reservation BEFORE INSERT ON terminal_runs BEGIN SELECT RAISE(ABORT,'injected'); END;").unwrap();
    assert!(open(&f, &cwd, script.to_str().unwrap()).is_err());
    assert!(!cwd.join("launched").exists());
    assert!(f.node.terminals.registry().terminals.is_empty());
    assert_eq!(status(&f)["launches"], 0);
    f.node.close().await;
}

#[tokio::test]
async fn spawn_failure_is_not_started_and_natural_exit_is_durable() {
    let f = Fixture::new().await;
    let cwd = root(&f);
    assert!(open(&f, &cwd.join("nonexistent"), "/bin/sh").is_err());
    assert_eq!(status(&f)["notStarted"], 1);
    let script = cwd.join("exit-shell");
    crate::test_support::executable(&script, "#!/bin/sh\nexit 7\n");
    let t = open(&f, &cwd, script.to_str().unwrap()).unwrap();
    let entry = f.node.terminals.lookup(&f.current, &t.id).unwrap();
    supervision::settle(vec![entry.clone()]).await.unwrap();
    assert_eq!(entry.state().info.exit_code, Some(7));
    assert_eq!(status(&f)["observersSettled"], 1);
    // Closing an already reaped child must not schedule later numeric signals.
    f.node.terminals.close(&f.current, &t.id).unwrap();
    f.node.terminals.dispose_session(&f.current).await.unwrap();
    f.node.close().await;
}

#[tokio::test]
async fn failed_running_record_still_stops_and_observes_the_launched_child() {
    let f = Fixture::new().await;
    let cwd = root(&f);
    f.node.db.lock().execute_batch("CREATE TRIGGER no_running BEFORE UPDATE OF state ON terminal_runs WHEN NEW.state='running' BEGIN SELECT RAISE(ABORT,'injected'); END;").unwrap();
    assert!(open(&f, &cwd, "/bin/sh").is_err());
    assert!(f.node.terminals.list(&f.current).is_empty());
    f.node.terminals.dispose_session(&f.current).await.unwrap();
    assert_eq!(status(&f)["observersSettled"], 1);
    assert_eq!(status(&f)["notStarted"], 0);
    f.node.close().await;
}

#[tokio::test]
async fn failed_outcome_remains_unconfirmed_even_without_live_entries() {
    let f = Fixture::new().await;
    let cwd = root(&f);
    let t = open(&f, &cwd, "/bin/sh").unwrap();
    f.node.db.lock().execute_batch("CREATE TRIGGER no_outcome BEFORE UPDATE OF state ON terminal_runs WHEN NEW.state='settled' BEGIN SELECT RAISE(ABORT,'injected'); END;").unwrap();
    f.node.terminals.close(&f.current, &t.id).unwrap();
    assert_eq!(
        f.node
            .terminals
            .dispose_session(&f.current)
            .await
            .unwrap_err()
            .code,
        "terminal_stop_unconfirmed"
    );
    assert_eq!(status(&f)["unresolved"], 1);
    let empty = Terminals::new(Arc::downgrade(&f.node));
    assert!(empty.list(&f.current).is_empty());
    assert_eq!(
        empty.dispose_session(&f.current).await.unwrap_err().code,
        "terminal_stop_unconfirmed"
    );
    assert!(journal::require_settled(&f.node.db.lock(), "independent").is_ok());
    f.node.close().await;
}

#[tokio::test]
async fn saved_unresolved_terminal_blocks_drain_and_deletion_without_erasing_files() {
    for state in ["launching", "running", "unconfirmed"] {
        let f = Fixture::new().await;
        pending(&f, state);
        let file = f.dir.join("retained-user-file");
        std::fs::write(&file, b"user later edits").unwrap();
        let lease = f
            .node
            .db
            .lock()
            .acquire_lease(&f.current, "phone", false, 60_000)
            .unwrap();
        let intent = crate::execution_fences::Intent {
            operation_id: "move".into(),
            plan_hash: "a".repeat(64),
            expected_workspace_id: "repo".into(),
            expected_runner_epoch: 0,
            preflight: None,
        };
        crate::execution_fences::accept(
            &f.node.db.lock(),
            "alice",
            &f.current,
            &intent,
            "phone",
            lease.generation,
        )
        .unwrap();
        let receipt = crate::execution_fences::drain(&f.node, "alice", &f.current, "move")
            .await
            .unwrap();
        assert_eq!(receipt.state, "blocked");
        assert_eq!(
            receipt.error_code.as_deref(),
            Some("terminal_stop_unconfirmed")
        );
        assert!(!receipt.revocation_confirmed && !receipt.target_installed);
        assert_eq!(
            serde_json::to_value(receipt.terminals).unwrap()["unresolved"],
            1
        );
        let error = crate::app::delete_owned_session(
            f.node.clone(),
            f.current.clone(),
            "alice".into(),
            Arc::default(),
            false,
        )
        .await
        .unwrap_err();
        assert_eq!(error.code, "terminal_stop_unconfirmed");
        assert_eq!(std::fs::read(&file).unwrap(), b"user later edits");
        assert!(f.node.db.lock().get_session(&f.current).is_ok());
        f.node.close().await;
    }
}

#[tokio::test]
async fn journal_survives_reopen_and_does_not_rewrite_or_replay_outcomes() {
    let f = Fixture::new().await;
    let record = pending(&f, "running");
    let path = f.dir.join("snapshot.sqlite");
    f.node
        .db
        .lock()
        .execute("VACUUM INTO ?1", [path.to_str().unwrap()])
        .unwrap();
    {
        let db = Db::open(&path).unwrap();
        let db = db.lock();
        assert_eq!(
            journal::require_settled(&db, &f.current).unwrap_err().code,
            "terminal_stop_unconfirmed"
        );
        for sql in [
            "UPDATE terminal_runs SET cwd='/other'",
            "UPDATE terminal_runs SET incarnation='new'",
            "DELETE FROM terminal_runs",
        ] {
            assert!(db.execute(sql, []).is_err());
        }
        record.finish(&db, "unconfirmed").unwrap();
        assert!(record.finish(&db, "settled").is_err());
        assert_eq!(
            journal::require_settled(&db, &f.current).unwrap_err().code,
            "terminal_stop_unconfirmed"
        );
    }
    f.node.close().await;
}

#[test]
fn migration_does_not_invent_pre_journal_terminal_history() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("node.sqlite");
    {
        let db = Db::open(&path).unwrap();
        db.lock()
            .execute_batch(include_str!("remove_journal.sql"))
            .unwrap();
        db.lock().pragma_update(None, "user_version", 2016).unwrap();
    }
    let db = Db::open(&path).unwrap();
    let db = db.lock();
    assert_eq!(
        db.pragma_query_value(None, "user_version", |r| r.get::<_, i64>(0))
            .unwrap(),
        crate::store::SCHEMA_VERSION
    );
    assert_eq!(
        serde_json::to_value(journal::summary(&db, "old").unwrap()).unwrap(),
        json!({"launches":0,"notStarted":0,"observersSettled":0,"unresolved":0,"historyComplete":false})
    );
}
