use super::*;
use crate::store::{Db, ModeId};
use std::sync::Arc;
fn setup(db: &Connection) -> (String, String) {
    db.add_workspace(
        "repo",
        "node",
        "Repo",
        "/repo",
        ModeId::new("directory").unwrap(),
    )
    .unwrap();
    let a = db.create_session("repo", "/private/a", "alice").unwrap();
    let b = db.create_session("repo", "/private/b", "alice").unwrap();
    db.increment_epoch(&a.id).unwrap();
    db.increment_epoch(&b.id).unwrap();
    (a.id, b.id)
}
fn identity(pid: u32) -> Identity {
    Identity {
        boot_id: "11111111-2222-3333-4444-555555555555".into(),
        observer_namespace: 10,
        namespace: 11,
        pid,
        start_ticks: 100,
    }
}
fn snapshot(state: State, pid: u32) -> Snapshot {
    Snapshot {
        state,
        identity: Some(identity(pid)),
    }
}

#[test]
fn spawn_reservation_survives_restart_and_absence_never_means_termination() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("node.sqlite");
    let (a, b, launch, failed) = {
        let db = Db::open(&path).unwrap();
        let db = db.lock();
        let (a, b) = setup(&db);
        let launch = reserve(&db, &a, "repo", 1, "incarnation-a").unwrap();
        let failed = reserve(&db, &b, "repo", 1, "incarnation-a").unwrap();
        not_started(&db, &failed).unwrap();
        (a, b, launch, failed)
    };
    let db = Db::open(&path).unwrap();
    let db = db.lock();
    assert_eq!(summary(&db, &a).unwrap().unresolved, 1);
    assert_eq!(summary(&db, &b).unwrap().not_started, 1);
    observe(
        &db,
        &launch,
        &Snapshot {
            state: State::Terminated,
            identity: None,
        },
    )
    .unwrap();
    assert_eq!(summary(&db, &a).unwrap().unresolved, 1);
    observe(&db, &failed, &snapshot(State::Running, 25)).unwrap();
    assert_eq!(summary(&db, &b).unwrap().not_started, 1);
    // Deletion removes conversation data, not the process evidence needed to
    // avoid treating an untracked orphan as a clean source environment.
    db.begin_session_deletion(&a, "alice").unwrap();
    db.finish_session_deletion(&a).unwrap();
    assert_eq!(summary(&db, &a).unwrap().unresolved, 1);
    assert!(db.execute("DELETE FROM sandbox_launches", []).is_err());
}

#[test]
fn immutable_identity_and_terminal_proof_survive_late_observers_and_new_generations() {
    let db = Db::memory();
    let db = db.lock();
    let (a, b) = setup(&db);
    let old = reserve(&db, &a, "repo", 1, "one").unwrap();
    observe(&db, &old, &snapshot(State::Running, 22)).unwrap();
    let mut wrong = old.clone();
    wrong.incarnation = "another node process".into();
    assert!(observe(&db, &wrong, &snapshot(State::Terminated, 22)).is_err());
    assert!(observe(&db, &old, &snapshot(State::Terminated, 99)).is_err());
    observe(
        &db,
        &old,
        &Snapshot {
            state: State::Terminated,
            identity: None,
        },
    )
    .unwrap();
    assert_eq!(summary(&db, &a).unwrap().terminated, 0);
    observe(&db, &old, &snapshot(State::Terminated, 22)).unwrap();
    db.increment_epoch(&a).unwrap();
    let current = reserve(&db, &a, "repo", 2, "two").unwrap();
    let peer = reserve(&db, &b, "repo", 1, "two").unwrap();
    observe(&db, &old, &snapshot(State::Running, 22)).unwrap();
    observe(&db, &current, &snapshot(State::Running, 23)).unwrap();
    observe(&db, &peer, &snapshot(State::Running, 24)).unwrap();
    assert_eq!(
        summary(&db, &a).unwrap(),
        Summary {
            launches: 2,
            terminated: 1,
            unresolved: 1,
            ..Default::default()
        }
    );
    assert_eq!(summary(&db, &b).unwrap().unresolved, 1);
    assert!(
        db.execute("UPDATE sandbox_launches SET runner_epoch=123", [])
            .is_err()
    );
    assert!(
        db.execute(
            "UPDATE sandbox_launches SET identity_json='{}' WHERE launch_id=?1",
            [&old.id]
        )
        .is_err()
    );
    assert!(
        db.execute(
            "UPDATE sandbox_launches SET state='running' WHERE launch_id=?1",
            [&old.id]
        )
        .is_err()
    );
}

#[test]
fn migration_retains_legacy_uncertainty_without_fencing_ordinary_sessions() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("node.sqlite");
    let (a, b) = {
        let db = Db::open(&path).unwrap();
        let db = db.lock();
        let (a, b) = setup(&db);
        db.execute_batch(concat!(
            include_str!("../host_commands/remove_schema.sql"),
            include_str!("remove_schema.sql"),
            "PRAGMA user_version=2012;"
        ))
        .unwrap();
        (a, b)
    };
    let db = Db::open(&path).unwrap();
    let db = db.lock();
    for session in [&a, &b] {
        assert_eq!(summary(&db, session).unwrap().legacy_untracked, 1);
        assert_eq!(summary(&db, session).unwrap().unresolved, 1);
        crate::execution_fences::require_open(&db, session).unwrap();
    }
    let fresh = db
        .create_session("repo", "/private/fresh", "alice")
        .unwrap();
    assert_eq!(summary(&db, &fresh.id).unwrap(), Summary::default());
    assert!(
        db.execute(
            "UPDATE sandbox_launches SET state='terminated',identity_json='{}'",
            []
        )
        .is_err()
    );
    assert_eq!(db.get_session(&a).unwrap().runner_epoch, 1);
}

#[test]
fn parallel_agent_observers_cannot_regress_another_launch_or_its_termination() {
    let db = Arc::new(Db::memory());
    let (a, b) = setup(&db.lock());
    let one = reserve(&db.lock(), &a, "repo", 1, "one").unwrap();
    let two = reserve(&db.lock(), &b, "repo", 1, "one").unwrap();
    std::thread::scope(|scope| {
        for (launch, pid) in [(one.clone(), 22), (two.clone(), 23)] {
            let db = db.clone();
            scope.spawn(move || {
                for _ in 0..50 {
                    observe(&db.lock(), &launch, &snapshot(State::Running, pid)).unwrap();
                }
                observe(&db.lock(), &launch, &snapshot(State::Terminated, pid)).unwrap();
                observe(&db.lock(), &launch, &snapshot(State::Running, pid)).unwrap();
            });
        }
    });
    assert_eq!(summary(&db.lock(), &a).unwrap().terminated, 1);
    assert_eq!(summary(&db.lock(), &b).unwrap().terminated, 1);
}

#[test]
fn reconciliation_requires_a_fence_and_pages_history_without_touching_a_peer() {
    let db = Db::memory();
    let db = db.lock();
    let (a, b) = setup(&db);
    for epoch in 1..=130 {
        if epoch > 1 {
            db.increment_epoch(&a).unwrap();
        }
        let launch = reserve_with_guard(&db, &a, "repo", epoch, "old-node", true).unwrap();
        observe(&db, &launch, &snapshot(State::Running, epoch as u32 + 20)).unwrap();
        db.execute(
            "UPDATE sandbox_launches SET updated_at=?2 WHERE launch_id=?1",
            params![launch.id, epoch],
        )
        .unwrap();
    }
    let peer = reserve(&db, &b, "repo", 1, "peer-node").unwrap();
    observe(&db, &peer, &snapshot(State::Running, 999)).unwrap();
    assert!(pending(&db, &a).is_err());
    let control = db.acquire_lease(&a, "phone", false, 60_000).unwrap();
    crate::execution_fences::accept(
        &db,
        "alice",
        &a,
        &crate::execution_fences::Intent {
            operation_id: "switch".into(),
            plan_hash: "a".repeat(64),
            expected_workspace_id: "repo".into(),
            expected_runner_epoch: 130,
            preflight: None,
        },
        "phone",
        control.generation,
    )
    .unwrap();
    // Another session cannot borrow A's accepted transition to kill processes.
    assert!(pending(&db, &b).is_err());
    assert!(reserve(&db, &a, "repo", 130, "new-node").is_err());
    let mut observed = std::collections::HashSet::new();
    for expected in [64, 64, 2] {
        let batch = pending(&db, &a).unwrap();
        assert_eq!(batch.len(), expected);
        for (launch, identity) in batch {
            assert_eq!(launch.session, a);
            assert!(observed.insert(launch.id.clone()));
            observe(
                &db,
                &launch,
                &Snapshot {
                    state: State::Terminated,
                    identity: Some(identity),
                },
            )
            .unwrap();
        }
    }
    assert!(pending(&db, &a).unwrap().is_empty());
    assert_eq!(summary(&db, &a).unwrap().terminated, 130);
    assert_eq!(summary(&db, &a).unwrap().guarded_not_released, 130);
    assert_eq!(summary(&db, &b).unwrap().unresolved, 1);
    assert_eq!(summary(&db, &b).unwrap().terminated, 0);
}

#[test]
fn unresolved_reconciliation_does_not_starve_later_launches() {
    let db = Db::memory();
    let db = db.lock();
    let (a, _) = setup(&db);
    for epoch in 1..=65 {
        if epoch > 1 {
            db.increment_epoch(&a).unwrap();
        }
        let launch = reserve(&db, &a, "repo", epoch, "old-node").unwrap();
        if epoch == 1 {
            db.execute("UPDATE sandbox_launches SET state='unconfirmed',identity_json='{}' WHERE launch_id=?1", [&launch.id]).unwrap();
        } else {
            observe(&db, &launch, &snapshot(State::Running, epoch as u32 + 20)).unwrap();
        }
        db.execute(
            "UPDATE sandbox_launches SET updated_at=?2 WHERE launch_id=?1",
            params![launch.id, epoch],
        )
        .unwrap();
    }
    let control = db.acquire_lease(&a, "phone", false, 60_000).unwrap();
    crate::execution_fences::accept(
        &db,
        "alice",
        &a,
        &crate::execution_fences::Intent {
            operation_id: "switch".into(),
            plan_hash: "a".repeat(64),
            expected_workspace_id: "repo".into(),
            expected_runner_epoch: 65,
            preflight: None,
        },
        "phone",
        control.generation,
    )
    .unwrap();
    let first = pending_page(&db, &a, 0, i64::MAX).unwrap();
    assert_eq!(first.len(), 64);
    let after = first.last().unwrap().0;
    assert!(first[0].2.is_none()); // Corrupt evidence is not a signaling target.
    for (_, launch, identity) in first {
        let Some(identity) = identity else { continue };
        observe(
            &db,
            &launch,
            &Snapshot {
                state: State::Unconfirmed,
                identity: Some(identity),
            },
        )
        .unwrap();
    }
    let next = pending_page(&db, &a, after, i64::MAX).unwrap();
    assert_eq!(next.len(), 1);
    assert_eq!(next[0].1.epoch, 65);
    assert_eq!(summary(&db, &a).unwrap().unresolved, 65);
    assert_eq!(summary(&db, &a).unwrap().terminated, 0);
}

fn guard_state(db: &Connection, launch: &Launch) -> String {
    db.query_row(
        "SELECT guard_state FROM sandbox_launches WHERE launch_id=?1",
        [&launch.id],
        |r| r.get(0),
    )
    .unwrap()
}
#[test]
fn guard_release_requires_durable_identity_and_never_replays() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("node.db");
    let (a, launch) = {
        let db = Db::open(&path).unwrap();
        let db = db.lock();
        let (a, _) = setup(&db);
        let launch = reserve_with_guard(&db, &a, "repo", 1, "one", true).unwrap();
        assert!(
            authorize(
                &db,
                &launch,
                "repo",
                &Snapshot {
                    state: State::Running,
                    identity: None
                }
            )
            .is_err()
        );
        assert_eq!(guard_state(&db, &launch), "waiting");
        // Release cannot be deferred inside somebody else's uncommitted transaction.
        assert!(
            crate::store::atomic(&db, |tx| authorize(
                tx,
                &launch,
                "repo",
                &snapshot(State::Running, 22)
            ))
            .is_err()
        );
        db.execute_batch("CREATE TRIGGER fail_guard BEFORE UPDATE OF guard_state ON sandbox_launches BEGIN SELECT RAISE(ABORT,'disk full'); END;").unwrap();
        assert!(authorize(&db, &launch, "repo", &snapshot(State::Running, 22)).is_err());
        assert_eq!(saved(&db, &launch).unwrap(), ("launching".into(), None));
        db.execute_batch("DROP TRIGGER fail_guard;").unwrap();
        authorize(&db, &launch, "repo", &snapshot(State::Running, 22)).unwrap();
        assert_eq!(guard_state(&db, &launch), "released");
        assert!(authorize(&db, &launch, "repo", &snapshot(State::Running, 22)).is_err());
        deny(&db, &launch).unwrap();
        assert_eq!(guard_state(&db, &launch), "released");
        (a, launch)
    };
    let db = Db::open(&path).unwrap();
    let db = db.lock();
    assert_eq!(guard_state(&db, &launch), "released");
    assert_eq!(
        saved(&db, &launch).unwrap().1,
        Some(serde_json::to_string(&identity(22)).unwrap())
    );
    assert_eq!(summary(&db, &a).unwrap().unresolved, 1);
    assert!(authorize(&db, &launch, "repo", &snapshot(State::Running, 22)).is_err());
}
#[test]
fn fence_denies_unreleased_launch_after_restart_without_inventing_kernel_exit() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("node.db");
    let (a, b, launch, peer) = {
        let db = Db::open(&path).unwrap();
        let db = db.lock();
        let (a, b) = setup(&db);
        let launch = reserve_with_guard(&db, &a, "repo", 1, "old-node", true).unwrap();
        let peer = reserve_with_guard(&db, &b, "repo", 1, "old-node", true).unwrap();
        (a, b, launch, peer)
    };
    let db = Db::open(&path).unwrap();
    let db = db.lock();
    let control = db.acquire_lease(&a, "phone", false, 60_000).unwrap();
    crate::execution_fences::accept(
        &db,
        "alice",
        &a,
        &crate::execution_fences::Intent {
            operation_id: "switch".into(),
            plan_hash: "a".repeat(64),
            expected_workspace_id: "repo".into(),
            expected_runner_epoch: 1,
            preflight: None,
        },
        "phone",
        control.generation,
    )
    .unwrap();
    assert!(authorize(&db, &launch, "repo", &snapshot(State::Running, 22)).is_err());
    assert!(pending(&db, &a).unwrap().is_empty());
    assert_eq!(guard_state(&db, &launch), "denied");
    assert_eq!(guard_state(&db, &peer), "waiting");
    assert_eq!(summary(&db, &a).unwrap().guarded_not_released, 1);
    assert_eq!(summary(&db, &a).unwrap().terminated, 0);
    assert_eq!(summary(&db, &a).unwrap().unresolved, 1);
    authorize(&db, &peer, "repo", &snapshot(State::Running, 23)).unwrap();
    assert_eq!(summary(&db, &b).unwrap().guarded_not_released, 0);
    assert!(
        db.execute(
            "UPDATE sandbox_launches SET guard_state='waiting' WHERE launch_id=?1",
            [launch.id]
        )
        .is_err()
    );
}
#[test]
fn migration_never_infers_a_guard_for_prior_launches() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("node.db");
    let launch = {
        let db = Db::open(&path).unwrap();
        let db = db.lock();
        let (a, _) = setup(&db);
        let launch = reserve(&db, &a, "repo", 1, "legacy").unwrap();
        db.execute_batch(include_str!("../host_commands/remove_schema.sql"))
            .unwrap();
        db.execute_batch("DROP TRIGGER sandbox_guard_monotonic; DROP INDEX sandbox_guard_pending; ALTER TABLE sandbox_launches DROP COLUMN guard_state; PRAGMA user_version=2013;").unwrap();
        launch
    };
    let db = Db::open(&path).unwrap();
    let db = db.lock();
    assert_eq!(guard_state(&db, &launch), "untracked");
    assert!(authorize(&db, &launch, "repo", &snapshot(State::Running, 22)).is_err());
    assert_eq!(saved(&db, &launch).unwrap().1, None);
    assert_eq!(
        summary(&db, &launch.session).unwrap().guarded_not_released,
        0
    );
}

#[test]
fn agent_epoch_dedup_does_not_consume_independent_terminal_slots() {
    let db = Db::memory();
    let db = db.lock();
    let (session, _) = setup(&db);
    let agent = reserve_with_guard(&db, &session, "repo", 1, "node", true).unwrap();
    let a = reserve_terminal(&db, &session, "repo", 1, "node").unwrap();
    let b = reserve_terminal(&db, &session, "repo", 1, "node").unwrap();
    assert_ne!(agent.id, a.id);
    assert_ne!(a.id, b.id);
    assert!(reserve_with_guard(&db, &session, "repo", 1, "node", true).is_err());
    assert_eq!(
        db.query_row(
            "SELECT count(*) FROM sandbox_launches WHERE resource_kind='terminal'",
            [],
            |r| r.get::<_, i64>(0)
        )
        .unwrap(),
        2
    );
    let running = snapshot(State::Running, 22);
    authorize(&db, &a, "repo", &running).unwrap();
    assert!(authorize(&db, &a, "repo", &running).is_err());
    assert_eq!(
        db.query_row(
            "SELECT guard_state FROM sandbox_launches WHERE launch_id=?1",
            [&b.id],
            |r| r.get::<_, String>(0)
        )
        .unwrap(),
        "waiting"
    );
    assert!(
        db.execute(
            "UPDATE sandbox_launches SET resource_kind='agent' WHERE launch_id=?1",
            [&a.id]
        )
        .is_err()
    );
    let mut forged = a.clone();
    forged.kind = Kind::Agent;
    assert!(observe(&db, &forged, &snapshot(State::Terminated, 22)).is_err());
}

#[test]
fn terminal_settlement_does_not_retire_agent_or_peer_terminal_in_the_same_epoch() {
    let db = Db::memory();
    let db = db.lock();
    let (session, _) = setup(&db);
    let agent = reserve_with_guard(&db, &session, "repo", 1, "node", true).unwrap();
    let a = reserve_terminal(&db, &session, "repo", 1, "node").unwrap();
    let b = reserve_terminal(&db, &session, "repo", 1, "node").unwrap();
    authorize(&db, &agent, "repo", &snapshot(State::Running, 21)).unwrap();
    authorize(&db, &a, "repo", &snapshot(State::Running, 22)).unwrap();
    authorize(&db, &b, "repo", &snapshot(State::Running, 23)).unwrap();
    observe(&db, &a, &snapshot(State::Terminated, 22)).unwrap();
    assert_eq!(summary(&db, &session).unwrap().terminated, 1);
    assert_eq!(saved(&db, &agent).unwrap().0, "running");
    assert_eq!(saved(&db, &b).unwrap().0, "running");
    let lease = db.acquire_lease(&session, "phone", false, 60_000).unwrap();
    crate::execution_fences::accept(
        &db,
        "alice",
        &session,
        &crate::execution_fences::Intent {
            operation_id: "resource-kinds".into(),
            plan_hash: "a".repeat(64),
            expected_workspace_id: "repo".into(),
            expected_runner_epoch: 1,
            preflight: None,
        },
        "phone",
        lease.generation,
    )
    .unwrap();
    let pending = pending(&db, &session).unwrap();
    assert_eq!(pending.len(), 2);
    assert!(
        pending
            .iter()
            .any(|(launch, _)| launch.kind == Kind::Agent && launch.id == agent.id)
    );
    assert!(
        pending
            .iter()
            .any(|(launch, _)| launch.kind == Kind::Terminal && launch.id == b.id)
    );
}

fn old_resource_schema(db: &Connection) {
    db.execute_batch(include_str!("../terminals/remove_io_owners.sql"))
        .unwrap();
    db.execute_batch(include_str!("remove_schema.sql")).unwrap();
    db.execute_batch(concat!(
        include_str!("schema.sql"),
        include_str!("guard.sql")
    ))
    .unwrap();
    db.pragma_update(None, "user_version", 2024).unwrap();
}
#[test]
fn resource_kind_migration_uses_retained_matching_origins_and_preserves_observations() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("node.sqlite");
    let session = {
        let db = Db::open(&path).unwrap();
        let db = db.lock();
        old_resource_schema(&db);
        let (session, _) = setup(&db);
        let kernel = serde_json::to_string(&identity(22)).unwrap();
        db.execute("INSERT INTO sandbox_launches VALUES('old-agent',?1,'repo',1,'old-node','running',?2,1,2,'released')",params![session,kernel]).unwrap();
        db.execute("INSERT INTO sandbox_launches VALUES('old-terminal',?1,'repo',0,'old-node','unconfirmed',?2,3,4,'denied')",params![session,kernel]).unwrap();
        db.execute("INSERT INTO terminal_runs(id,session_id,workspace_id,cwd,incarnation,state,created_at,updated_at) VALUES('old-terminal',?1,'repo','/repo','old-node','unconfirmed',3,4)",[&session]).unwrap();
        db.execute("INSERT INTO sandbox_launches VALUES('mismatch',?1,'repo',2,'old-node','launching',NULL,5,6,'waiting')",[&session]).unwrap();
        db.execute("INSERT INTO terminal_runs(id,session_id,workspace_id,cwd,incarnation,state,created_at,updated_at) VALUES('mismatch',?1,'another-workspace','/repo','old-node','running',5,6)",[&session]).unwrap();
        session
    };
    let db = Db::open(&path).unwrap();
    let db = db.lock();
    let mut statement=db.prepare("SELECT launch_id,resource_kind,state,guard_state,identity_json,created_at,updated_at FROM sandbox_launches ORDER BY launch_id").unwrap();
    let rows = statement
        .query_map([], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
                r.get::<_, String>(3)?,
                r.get::<_, Option<String>>(4)?,
                r.get::<_, i64>(5)?,
                r.get::<_, i64>(6)?,
            ))
        })
        .unwrap()
        .collect::<Result<Vec<_>, _>>()
        .unwrap();
    assert_eq!(
        rows[0],
        (
            "mismatch".into(),
            "agent".into(),
            "launching".into(),
            "waiting".into(),
            None,
            5,
            6
        )
    );
    assert_eq!(rows[1].1, "agent");
    assert_eq!(rows[1].2, "running");
    assert_eq!(rows[1].3, "released");
    assert_eq!(rows[2].1, "terminal");
    assert_eq!(rows[2].2, "unconfirmed");
    assert_eq!(rows[2].3, "denied");
    assert_eq!(
        rows[1].4,
        Some(serde_json::to_string(&identity(22)).unwrap())
    );
    assert_eq!(rows[1].4, rows[2].4);
    assert!(reserve_terminal(&db, &session, "repo", 1, "new-node").is_ok());
    assert!(reserve_with_guard(&db, &session, "repo", 1, "new-node", true).is_err());
    assert!(db.execute("DELETE FROM sandbox_launches", []).is_err());
}
#[test]
fn failed_resource_migration_rolls_back_schema_version_rows_and_guards() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("node.sqlite");
    {
        let db = Db::open(&path).unwrap();
        let db = db.lock();
        old_resource_schema(&db);
        db.execute("INSERT INTO sandbox_launches VALUES('keep','session','repo',0,'old-node','launching',NULL,1,1,'waiting')",[]).unwrap();
        db.execute_batch("CREATE TABLE sandbox_launches_before_resources(sentinel TEXT)")
            .unwrap();
    }
    assert!(Db::open(&path).is_err());
    let raw = Connection::open(&path).unwrap();
    assert_eq!(
        raw.pragma_query_value(None, "user_version", |r| r.get::<_, i64>(0))
            .unwrap(),
        2024
    );
    assert_eq!(
        raw.query_row(
            "SELECT guard_state FROM sandbox_launches WHERE launch_id='keep'",
            [],
            |r| r.get::<_, String>(0)
        )
        .unwrap(),
        "waiting"
    );
    assert!(
        raw.execute("UPDATE sandbox_launches SET guard_state='untracked'", [])
            .is_err()
    );
    raw.execute_batch("DROP TABLE sandbox_launches_before_resources")
        .unwrap();
    drop(raw);
    let db = Db::open(&path).unwrap();
    let db = db.lock();
    assert_eq!(
        db.query_row(
            "SELECT resource_kind FROM sandbox_launches WHERE launch_id='keep'",
            [],
            |r| r.get::<_, String>(0)
        )
        .unwrap(),
        "agent"
    );
}

#[tokio::test]
async fn saved_retirement_processes_later_pages_before_reporting_malformed_evidence() {
    let f = crate::workspace_memory::tests::Fixture::new().await;
    let later;
    let peer_launch;
    {
        let db = f.node.db.lock();
        for _ in 0..130 {
            let launch = reserve_terminal(&db, &f.current, "repo", 0, "old-node").unwrap();
            db.execute("UPDATE sandbox_launches SET state='unconfirmed',identity_json='{}' WHERE launch_id=?1", [&launch.id]).unwrap();
        }
        later = reserve_terminal(&db, &f.current, "repo", 0, "old-node").unwrap();
        observe(&db, &later, &snapshot(State::Running, 100)).unwrap();
        let peer = db.create_session("repo", "/peer", "alice").unwrap();
        peer_launch = reserve_terminal(&db, &peer.id, "repo", 0, "old-node").unwrap();
        observe(&db, &peer_launch, &snapshot(State::Running, 101)).unwrap();
        let control = db.acquire_lease(&f.current, "phone", true, 60_000).unwrap();
        crate::execution_fences::accept(
            &db,
            "alice",
            &f.current,
            &crate::execution_fences::Intent {
                operation_id: "retire-corrupt-history".into(),
                plan_hash: "a".repeat(64),
                expected_workspace_id: "repo".into(),
                expected_runner_epoch: 0,
                preflight: None,
            },
            "phone",
            control.generation,
        )
        .unwrap();
    }
    assert!(retire_saved(&f.node, &f.current).await.is_err());
    {
        let db = f.node.db.lock();
        // Synthetic foreign-boot evidence cannot signal or prove termination;
        // its changed state proves the later page was nevertheless observed.
        assert_eq!(saved(&db, &later).unwrap().0, "unconfirmed");
        assert_eq!(saved(&db, &peer_launch).unwrap().0, "running");
        assert_eq!(summary(&db, &f.current).unwrap().unresolved, 131);
        assert_eq!(summary(&db, &f.current).unwrap().terminated, 0);
    }
    f.node.close().await;
}
