use super::*;
use crate::{
    sandbox::processes::State,
    store::{Db, Store},
    workspace_memory::tests::Fixture,
};
use std::sync::atomic::{AtomicU32, AtomicUsize, Ordering};

fn owner(pid: u32) -> ObserverIdentity {
    ObserverIdentity {
        version: 1,
        boot_id: "11111111-2222-3333-4444-555555555555".into(),
        observer_namespace: 10,
        pid,
        start_ticks: 100,
    }
}
fn kernel() -> Identity {
    static NEXT: AtomicU32 = AtomicU32::new(20);
    let id = NEXT.fetch_add(1, Ordering::Relaxed);
    Identity {
        boot_id: owner(100).boot_id,
        observer_namespace: 10,
        namespace: u64::from(id),
        pid: id,
        start_ticks: 100,
    }
}
fn seed(
    db: &Connection,
    session: &str,
    id: &str,
    incarnation: &str,
    identity: Option<&ObserverIdentity>,
    state: State,
) {
    let write = |db: &Connection| -> ApiResult<()> {
        if let Some(identity) = identity {
            record(db, incarnation, identity)?;
        }
        let kernel = serde_json::to_string(&kernel()).unwrap();
        let state = if state == State::Terminated {
            "terminated"
        } else {
            "running"
        };
        db.execute("INSERT INTO sandbox_launches(launch_id,session_id,workspace_id,runner_epoch,incarnation,state,identity_json,created_at,updated_at,guard_state,resource_kind) VALUES(?1,?2,'repo',0,?3,?4,?5,1,1,'released','terminal')",params![id,session,incarnation,state,kernel])?;
        db.execute(
            "INSERT INTO terminal_runs VALUES(?1,?2,'repo','/repo',?3,'unconfirmed',1,1)",
            params![id, session, incarnation],
        )?;
        Ok(())
    };
    if db.is_autocommit() {
        store::atomic(db, write).unwrap()
    } else {
        write(db).unwrap()
    }
}
fn fence(f: &Fixture, session: &str) {
    let db = f.node.db.lock();
    let row = db.get_session(session).unwrap();
    let lease = db.acquire_lease(session, "phone", true, 60_000).unwrap();
    crate::execution_fences::accept(
        &db,
        "alice",
        session,
        &crate::execution_fences::Intent {
            operation_id: format!("recover-{session}"),
            plan_hash: "a".repeat(64),
            expected_workspace_id: row.workspace_id,
            expected_runner_epoch: row.runner_epoch,
            preflight: None,
        },
        "phone",
        lease.generation,
    )
    .unwrap();
}
fn status(db: &Connection, id: &str) -> String {
    db.query_row("SELECT state FROM terminal_runs WHERE id=?1", [id], |r| {
        r.get(0)
    })
    .unwrap()
}
fn gone() -> Check {
    Arc::new(|_| Ok(true))
}

#[tokio::test]
async fn dual_proof_recovery_is_idempotent_and_does_not_reopen_the_source() {
    let f = Fixture::new().await;
    seed(
        &f.node.db.lock(),
        &f.current,
        "old-terminal",
        "old-node",
        Some(&owner(100)),
        State::Terminated,
    );
    let user = f.dir.join("user-kept");
    std::fs::write(&user, "later user edits").unwrap();
    fence(&f, &f.current);
    recover_with(&f.node, &f.current, gone()).await.unwrap();
    recover_with(
        &f.node,
        &f.current,
        Arc::new(|_| panic!("settled rows must not probe again")),
    )
    .await
    .unwrap();
    {
        let db = f.node.db.lock();
        assert_eq!(status(&db, "old-terminal"), "settled");
        assert_eq!(
            db.query_row(
                "SELECT state FROM terminal_io_owners WHERE incarnation='old-node'",
                [],
                |r| r.get::<_, String>(0)
            )
            .unwrap(),
            "gone"
        );
        assert!(crate::execution_fences::require_open(&db, &f.current).is_err());
        assert!(
            db.execute("UPDATE terminal_runs SET state='running'", [])
                .is_err()
        );
        assert!(
            db.execute("UPDATE terminal_io_owners SET state='captured'", [])
                .is_err()
        );
        assert!(
            db.execute("UPDATE terminal_io_owners SET identity_json='{}'", [])
                .is_err()
        );
        assert!(db.execute("DELETE FROM terminal_io_owners", []).is_err());
    }
    assert_eq!(std::fs::read_to_string(user).unwrap(), "later user edits");
    f.node.terminals.require_settled(&f.current).unwrap();
    f.node.close().await;
}
#[tokio::test]
async fn alive_missing_unknown_and_unretired_resources_remain_unconfirmed() {
    let f = Fixture::new().await;
    {
        let db = f.node.db.lock();
        seed(
            &db,
            &f.current,
            "alive",
            "alive-node",
            Some(&owner(100)),
            State::Terminated,
        );
        seed(
            &db,
            &f.current,
            "unknown",
            "unknown-node",
            Some(&owner(101)),
            State::Terminated,
        );
        seed(
            &db,
            &f.current,
            "missing",
            "missing-node",
            None,
            State::Terminated,
        );
        seed(
            &db,
            &f.current,
            "kernel-running",
            "running-node",
            Some(&owner(102)),
            State::Running,
        );
        db.execute("INSERT INTO terminal_runs VALUES('legacy',?1,'repo','/repo','legacy-node','unconfirmed',1,1)",[&f.current]).unwrap();
    }
    fence(&f, &f.current);
    recover_with(
        &f.node,
        &f.current,
        Arc::new(|identity| match identity.pid {
            100 => Ok(false),
            101 => Err(std::io::Error::from(std::io::ErrorKind::PermissionDenied)),
            _ => panic!("unretired kernels must not be considered"),
        }),
    )
    .await
    .unwrap();
    {
        let db = f.node.db.lock();
        for id in ["alive", "unknown", "missing", "kernel-running", "legacy"] {
            assert_eq!(status(&db, id), "unconfirmed");
        }
        assert_eq!(
            db.query_row(
                "SELECT count(*) FROM terminal_io_owners WHERE state='gone'",
                [],
                |r| r.get::<_, i64>(0)
            )
            .unwrap(),
            0
        );
    }
    assert_eq!(
        f.node
            .terminals
            .require_settled(&f.current)
            .unwrap_err()
            .code,
        "terminal_stop_unconfirmed"
    );
    f.node.close().await;
}
#[tokio::test]
async fn malformed_and_mismatched_owner_evidence_is_not_a_pid_probe() {
    let f = Fixture::new().await;
    {
        let db = f.node.db.lock();
        let mut boot = owner(100);
        boot.boot_id = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee".into();
        let mut view = owner(101);
        view.observer_namespace = 99;
        seed(
            &db,
            &f.current,
            "boot",
            "boot-node",
            Some(&boot),
            State::Terminated,
        );
        seed(
            &db,
            &f.current,
            "view",
            "view-node",
            Some(&view),
            State::Terminated,
        );
        seed(
            &db,
            &f.current,
            "shape",
            "shape-node",
            None,
            State::Terminated,
        );
        db.execute(
            "INSERT INTO terminal_io_owners VALUES('shape-node','{}','captured',1,1)",
            [],
        )
        .unwrap();
        seed(
            &db,
            &f.current,
            "version",
            "version-node",
            None,
            State::Terminated,
        );
        let mut version = owner(103);
        version.version = 2;
        db.execute(
            "INSERT INTO terminal_io_owners VALUES('version-node',?1,'captured',1,1)",
            [serde_json::to_string(&version).unwrap()],
        )
        .unwrap();
    }
    fence(&f, &f.current);
    recover_with(
        &f.node,
        &f.current,
        Arc::new(|_| panic!("untrusted owner identity reached a process probe")),
    )
    .await
    .unwrap();
    assert!(f.node.terminals.require_settled(&f.current).is_err());
    f.node.close().await;
}
#[tokio::test]
async fn recovery_requires_its_own_source_fence_even_when_the_same_owner_is_gone() {
    let f = Fixture::new().await;
    let peer = f
        .node
        .db
        .lock()
        .create_session("repo", "/peer", "alice")
        .unwrap();
    {
        let db = f.node.db.lock();
        seed(
            &db,
            &f.current,
            "source",
            "shared-old-node",
            Some(&owner(100)),
            State::Terminated,
        );
        seed(
            &db,
            &peer.id,
            "peer",
            "shared-old-node",
            Some(&owner(100)),
            State::Terminated,
        );
    }
    assert!(
        recover_with(
            &f.node,
            &f.current,
            Arc::new(|_| panic!("unfenced recovery touched a PID"))
        )
        .await
        .is_err()
    );
    fence(&f, &peer.id);
    recover_with(&f.node, &peer.id, gone()).await.unwrap();
    assert_eq!(status(&f.node.db.lock(), "peer"), "settled");
    assert_eq!(status(&f.node.db.lock(), "source"), "unconfirmed");
    assert!(recover_with(&f.node, &f.current, gone()).await.is_err());
    fence(&f, &f.current);
    recover_with(
        &f.node,
        &f.current,
        Arc::new(|_| panic!("retained gone evidence must not re-probe")),
    )
    .await
    .unwrap();
    assert_eq!(status(&f.node.db.lock(), "source"), "settled");
    f.node.close().await;
}
#[tokio::test]
async fn failed_settlement_commit_retains_both_unknown_states_for_retry() {
    let f = Fixture::new().await;
    seed(
        &f.node.db.lock(),
        &f.current,
        "retry",
        "old-node",
        Some(&owner(100)),
        State::Terminated,
    );
    fence(&f, &f.current);
    f.node.db.lock().execute_batch("CREATE TRIGGER fail_owner_receipt BEFORE UPDATE OF state ON terminal_runs WHEN NEW.state='settled' BEGIN SELECT RAISE(ABORT,'disk full'); END;").unwrap();
    assert!(recover_with(&f.node, &f.current, gone()).await.is_err());
    {
        let db = f.node.db.lock();
        assert_eq!(status(&db, "retry"), "unconfirmed");
        assert_eq!(
            db.query_row("SELECT state FROM terminal_io_owners", [], |r| r
                .get::<_, String>(0))
                .unwrap(),
            "captured"
        );
        db.execute_batch("DROP TRIGGER fail_owner_receipt").unwrap();
    }
    recover_with(&f.node, &f.current, gone()).await.unwrap();
    assert_eq!(status(&f.node.db.lock(), "retry"), "settled");
    f.node.close().await;
}
#[tokio::test]
async fn early_unresolved_owners_do_not_starve_large_later_retired_history() {
    let f = Fixture::new().await;
    {
        let db = f.node.db.lock();
        store::atomic(&db, |db| {
            for n in 0..130 {
                seed(
                    db,
                    &f.current,
                    &format!("alive-{n}"),
                    "alive",
                    Some(&owner(100)),
                    State::Terminated,
                );
            }
            for n in 0..1200 {
                seed(
                    db,
                    &f.current,
                    &format!("retired-{n}"),
                    "retired",
                    Some(&owner(200)),
                    State::Terminated,
                );
            }
            Ok(())
        })
        .unwrap();
    }
    fence(&f, &f.current);
    let calls = Arc::new(AtomicUsize::new(0));
    let counted = calls.clone();
    recover_with(
        &f.node,
        &f.current,
        Arc::new(move |owner| {
            counted.fetch_add(1, Ordering::SeqCst);
            Ok(owner.pid == 200)
        }),
    )
    .await
    .unwrap();
    {
        let db = f.node.db.lock();
        assert_eq!(
            db.query_row(
                "SELECT count(*) FROM terminal_runs WHERE state='settled'",
                [],
                |r| r.get::<_, i64>(0)
            )
            .unwrap(),
            1200
        );
        assert_eq!(
            db.query_row(
                "SELECT count(*) FROM terminal_runs WHERE state='unconfirmed'",
                [],
                |r| r.get::<_, i64>(0)
            )
            .unwrap(),
            130
        );
    }
    assert_eq!(calls.load(Ordering::SeqCst), 2);
    f.node.close().await;
}
#[test]
fn ownership_capture_is_immutable_and_an_atomic_reservation_prerequisite() {
    let db = Db::memory();
    let db = db.lock();
    assert!(record(&db, "node", &owner(100)).is_err()); // Must share the launch transaction.
    store::atomic(&db, |db| record(db, "node", &owner(100))).unwrap();
    store::atomic(&db, |db| record(db, "node", &owner(100))).unwrap();
    assert!(store::atomic(&db, |db| record(db, "node", &owner(101))).is_err());
    assert_eq!(
        db.query_row("SELECT count(*) FROM terminal_io_owners", [], |r| r
            .get::<_, i64>(0))
            .unwrap(),
        1
    );
    let mut invalid = owner(102);
    invalid.version = 2;
    assert!(store::atomic(&db, |db| record(db, "another", &invalid)).is_err());
}
#[test]
fn migration_never_invents_old_owner_or_io_closure_evidence() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("node.sqlite");
    {
        let db = Db::open(&file).unwrap();
        let db = db.lock();
        seed(
            &db,
            "old-session",
            "old-terminal",
            "old-node",
            Some(&owner(100)),
            State::Terminated,
        );
        db.execute_batch(include_str!("../remove_io_owners.sql"))
            .unwrap();
        db.pragma_update(None, "user_version", 2025).unwrap();
    }
    let db = Db::open(&file).unwrap();
    let db = db.lock();
    assert_eq!(
        db.query_row("SELECT count(*) FROM terminal_io_owners", [], |r| r
            .get::<_, i64>(0))
            .unwrap(),
        0
    );
    assert_eq!(status(&db, "old-terminal"), "unconfirmed");
    assert!(
        db.execute(
            "UPDATE terminal_runs SET state='settled' WHERE id='old-terminal'",
            []
        )
        .is_err()
    );
}
