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
        observe(&db, &launch, &snapshot(State::Running, epoch as u32 + 20)).unwrap();
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
    let first = pending(&db, &a).unwrap();
    assert_eq!(first.len(), 64);
    for (launch, identity) in first {
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
    let next = pending(&db, &a).unwrap();
    assert_eq!(next[0].0.epoch, 65);
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
