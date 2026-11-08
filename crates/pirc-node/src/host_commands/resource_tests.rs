use super::tests::{origin, start};
use super::*;
use crate::{
    store::{Db, Store},
    workspace_memory::tests::Fixture,
    write_broker::WriteGrant,
};
use std::path::{Path, PathBuf};

fn root(f: &Fixture) -> PathBuf {
    f.node
        .db
        .lock()
        .get_workspace("repo")
        .unwrap()
        .canonical_path
        .into()
}
fn peer(f: &Fixture) -> String {
    let db = f.node.db.lock();
    // Different workspace IDs do not make nested filesystem roots independent.
    let path = PathBuf::from(db.get_workspace("repo").unwrap().canonical_path).join("nested");
    std::fs::create_dir(&path).unwrap();
    db.add_workspace(
        "alias",
        "memory-test",
        "Alias",
        path.to_str().unwrap(),
        crate::store::ModeId::new("directory").unwrap(),
    )
    .unwrap();
    db.create_session("alias", "/unused-peer", "alice")
        .unwrap()
        .id
}
fn blocked(grant: WriteGrant) {
    assert!(
        matches!(grant, WriteGrant::Blocked { ref code, .. } if code == "host_write_pending"),
        "{grant:?}"
    );
}

#[tokio::test]
async fn agent_release_retains_host_ranges_and_independent_work_continues() {
    let f = Fixture::new().await;
    let peer = peer(&f);
    let work = root(&f);
    let outside = f.dir.join("separate-leased-file");
    assert_eq!(
        f.node.writes.acquire(&f.current, &outside),
        WriteGrant::Granted
    );
    let (_tx, rx) = watch::channel(false);
    let ticket = start(&f, &f.current, "resource-owner", "exec /bin/sleep 30", rx).unwrap();
    f.node.writes.release(&f.current); // Agent settled/runner cleanup is independent.
    assert!(f.node.writes.leases(&f.current).is_empty());
    assert!(f.node.writes.holders().unwrap().contains(&f.current));
    blocked(f.node.writes.acquire(&peer, &work.join("user-file")));
    blocked(f.node.writes.acquire(&peer, &outside));
    assert_eq!(
        f.node.writes.acquire(&peer, &f.dir.join("unrelated")),
        WriteGrant::Granted
    );
    assert_eq!(
        f.node.writes.acquire(&f.current, &work),
        WriteGrant::Granted
    );
    f.node.writes.release(&f.current);
    f.node.host_commands.cancel_epoch(&f.current, 0);
    ticket.result().await.unwrap();
    assert!(!f.node.writes.holders().unwrap().contains(&f.current));
    assert_eq!(f.node.writes.acquire(&peer, &work), WriteGrant::Granted);
    f.node.close().await;
}

#[tokio::test]
async fn new_epoch_and_failed_outcome_cannot_inherit_a_host_claim() {
    let f = Fixture::new().await;
    let work = root(&f);
    let (_tx, rx) = watch::channel(false);
    let ticket = start(&f, &f.current, "running", "exec /bin/sleep 30", rx.clone()).unwrap();
    f.node.db.lock().increment_epoch(&f.current).unwrap();
    blocked(f.node.writes.acquire(&f.current, &work));
    f.node.host_commands.cancel_epoch(&f.current, 0);
    ticket.result().await.unwrap();
    f.node.db.lock().execute_batch("CREATE TRIGGER fail_resource_outcome BEFORE UPDATE OF state ON host_command_runs WHEN NEW.state='settled' BEGIN SELECT RAISE(ABORT,'storage failure'); END;").unwrap();
    assert!(
        start(&f, &f.current, "outcome-fails", "true", rx)
            .unwrap()
            .result()
            .await
            .is_err()
    );
    // Same incarnation and epoch are insufficient once the observer is gone.
    blocked(f.node.writes.acquire(&f.current, &work));
    assert!(f.node.writes.holders().unwrap().contains(&f.current));
    f.node.close().await;
}

#[tokio::test]
async fn resource_failure_rolls_back_admission_and_never_spawns() {
    let f = Fixture::new().await;
    let marker = f.dir.join("not-created");
    f.node.db.lock().execute_batch("CREATE TRIGGER fail_resource BEFORE INSERT ON host_command_resources BEGIN SELECT RAISE(ABORT,'full'); END;").unwrap();
    let (_tx, rx) = watch::channel(false);
    assert!(
        start(
            &f,
            &f.current,
            "no-snapshot",
            &format!("touch '{}'", marker.display()),
            rx
        )
        .is_err()
    );
    assert_eq!(summary(&f.node.db.lock(), &f.current).unwrap().launches, 0);
    assert!(!marker.exists());
    f.node.close().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn competing_host_and_peer_lease_have_exactly_one_admission() {
    let f = Fixture::new().await;
    let peer = peer(&f);
    let work = root(&f);
    let origin = origin(&f, &f.current, "race");
    let (_tx, rx) = watch::channel(false);
    let barrier = std::sync::Barrier::new(2);
    let runtime = tokio::runtime::Handle::current();
    let (host, lease) = std::thread::scope(|scope| {
        let host = scope.spawn(|| {
            let _runtime = runtime.enter();
            let mut command =
                crate::runner::host::command(&f.node.env, "exec /bin/sleep 30", &work);
            barrier.wait();
            f.node
                .host_commands
                .start(&f.node, &f.node.db.lock(), origin, &mut command, rx)
        });
        let lease = scope.spawn(|| {
            barrier.wait();
            f.node.writes.acquire(&peer, &work)
        });
        (host.join().unwrap(), lease.join().unwrap())
    });
    assert_ne!(host.is_ok(), lease == WriteGrant::Granted);
    if let Ok(ticket) = host {
        blocked(lease);
        f.node.host_commands.cancel_epoch(&f.current, 0);
        ticket.result().await.unwrap();
    } else {
        assert_eq!(host.err().unwrap().code, "host_write_conflict");
    }
    f.node.close().await;
}

fn record(db: &Connection, id: &str, state: &str, path: Option<&str>) {
    db.execute("INSERT INTO host_command_runs(id,session_id,workspace_id,runner_epoch,incarnation,request_id,state,created_at,updated_at) VALUES(?1,'old-session','old-workspace',2,'old-node',?1,?2,1,1)", params![id,state]).unwrap();
    if let Some(path) = path {
        resources::record(db, id, &[path.into()]).unwrap();
    }
}
#[test]
fn restart_keeps_original_ranges_even_without_session_or_workspace() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("node.db");
    {
        let db = Db::open(&file).unwrap();
        record(&db.lock(), "pending", "running", Some("/original/repo"));
    }
    let db = Db::open(&file).unwrap();
    let db = db.lock();
    assert_eq!(
        resources::require_available(&db, Path::new("/original/repo/file"), None)
            .unwrap_err()
            .code,
        "host_write_pending"
    );
    resources::require_available(&db, Path::new("/unrelated"), None).unwrap();
    assert_eq!(resources::holders(&db).unwrap(), ["old-session"]);
    assert!(
        db.execute(
            r#"UPDATE host_command_resources SET paths_json='["/other"]'"#,
            []
        )
        .is_err()
    );
    assert!(
        db.execute("DELETE FROM host_command_resources", [])
            .is_err()
    );
}
#[test]
fn migration_does_not_invent_ranges_for_legacy_commands() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("node.db");
    {
        let db = Db::open(&file).unwrap();
        let db = db.lock();
        record(&db, "legacy", "running", None);
        db.execute_batch(include_str!("../terminals/remove_journal.sql"))
            .unwrap();
        db.execute_batch(include_str!("remove_resources.sql"))
            .unwrap();
        db.execute_batch("PRAGMA user_version=2015").unwrap();
    }
    let db = Db::open(&file).unwrap();
    let db = db.lock();
    assert_eq!(
        db.query_row("SELECT count(*) FROM host_command_resources", [], |r| r
            .get::<_, i64>(0))
            .unwrap(),
        0
    );
    assert_eq!(
        resources::require_available(&db, Path::new("/any/path"), None)
            .unwrap_err()
            .code,
        "host_write_pending"
    );
    db.execute(
        "UPDATE host_command_runs SET state='settled' WHERE id='legacy'",
        [],
    )
    .unwrap();
    resources::require_available(&db, Path::new("/any/path"), None).unwrap();
}
#[test]
fn malformed_snapshots_and_lost_inventory_fail_closed() {
    for snapshot in ["[]", "[1]", r#"["relative"]"#] {
        let db = Db::memory();
        let db = db.lock();
        record(&db, "bad", "unconfirmed", None);
        db.execute(
            "INSERT INTO host_command_resources VALUES('bad',?1)",
            [snapshot],
        )
        .unwrap();
        assert_eq!(
            resources::require_available(&db, Path::new("/any"), None)
                .unwrap_err()
                .code,
            "host_write_pending"
        );
    }
    let db = Db::memory();
    let db = db.lock();
    db.execute_batch(include_str!("remove_resources.sql"))
        .unwrap();
    assert!(resources::require_available(&db, Path::new("/any"), None).is_err());
}
#[test]
fn large_settled_history_uses_pending_inventory_without_false_conflicts() {
    let db = Db::memory();
    let db = db.lock();
    db.execute_batch("WITH RECURSIVE n(v) AS (SELECT 1 UNION ALL SELECT v+1 FROM n WHERE v<10000) INSERT INTO host_command_runs(id,session_id,workspace_id,runner_epoch,incarnation,request_id,state,created_at,updated_at) SELECT 'done-'||v,'old','repo',0,'previous','request-'||v,'settled',1,1 FROM n;").unwrap();
    // Old settled rows do not need fabricated path metadata.
    resources::require_available(&db, Path::new("/repo"), None).unwrap();
    record(&db, "pending", "running", Some("/repo"));
    assert!(resources::require_available(&db, Path::new("/repo/file"), None).is_err());
    let plan:Vec<String> = db.prepare("EXPLAIN QUERY PLAN SELECT h.id,r.paths_json FROM host_command_runs h LEFT JOIN host_command_resources r ON r.run_id=h.id WHERE h.state IN ('launching','running','unconfirmed')").unwrap().query_map([],|r|r.get(3)).unwrap().collect::<Result<_,_>>().unwrap();
    assert!(
        plan.iter().any(|s| s.contains("host_commands_pending")),
        "{plan:?}"
    );
}
