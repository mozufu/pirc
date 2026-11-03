//! Exercise the actual pre-RPC release path with a private child stdin pipe.
use super::*;
use crate::sandbox::processes::{Identity, ProcessScope, Snapshot, State};
use crate::workspace_memory::tests::Fixture;
use std::sync::atomic::AtomicUsize;
struct Scope {
    ready: AtomicBool,
    reads: AtomicUsize,
}
impl ProcessScope for Scope {
    fn spawned(&self, _: u32) {}
    fn terminate(&self) {}
    fn cleanup(&self) {}
    fn state(&self) -> State {
        if self.ready.load(Ordering::SeqCst) {
            State::Running
        } else {
            State::Observing
        }
    }
    fn snapshot(&self) -> Snapshot {
        self.reads.fetch_add(1, Ordering::SeqCst);
        Snapshot {
            state: self.state(),
            identity: self.ready.load(Ordering::SeqCst).then(|| Identity {
                boot_id: "11111111-2222-3333-4444-555555555555".into(),
                observer_namespace: 10,
                namespace: 11,
                pid: 22,
                start_ticks: 100,
            }),
        }
    }
}
fn prepared(scope: Arc<Scope>) -> Prepared {
    Prepared::new(
        PathBuf::new(),
        vec![],
        vec![],
        Default::default(),
        vec![],
        None,
        || {},
    )
    .with_process_scope(scope)
}
fn child() -> tokio::process::Child {
    tokio::process::Command::new("/bin/cat")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .unwrap()
}
fn reserve(f: &Fixture) -> crate::process_journal::Launch {
    let db = f.node.db.lock();
    let epoch = db.increment_epoch(&f.current).unwrap();
    crate::process_journal::reserve_with_guard(&db, &f.current, "repo", epoch, "unit-node", true)
        .unwrap()
}
async fn output(mut child: tokio::process::Child) -> Vec<u8> {
    child.stdin.take();
    tokio::time::timeout(Duration::from_secs(2), child.wait_with_output())
        .await
        .unwrap()
        .unwrap()
        .stdout
}
#[tokio::test]
async fn permits_only_after_commit_and_does_not_retry_on_the_same_pipe() {
    let f = Fixture::new().await;
    let launch = reserve(&f);
    let workspace = f.node.db.lock().get_workspace("repo").unwrap();
    let prepared = prepared(Arc::new(Scope {
        ready: AtomicBool::new(true),
        reads: AtomicUsize::new(0),
    }));
    let mut child = child();
    release_guarded_launch(&f.node, &prepared, &launch, &workspace, &f.mode, &mut child)
        .await
        .unwrap();
    let released:bool=f.node.db.lock().query_row("SELECT guard_state='released' AND identity_json IS NOT NULL FROM sandbox_launches WHERE session_id=?1",[&f.current],|r|r.get(0)).unwrap();
    assert!(released);
    assert!(
        release_guarded_launch(&f.node, &prepared, &launch, &workspace, &f.mode, &mut child)
            .await
            .is_err()
    );
    assert_eq!(output(child).await, crate::sandbox::launch_guard::PERMIT);
    f.node.close().await;
}
#[tokio::test]
async fn journal_failure_never_writes_permission() {
    let f = Fixture::new().await;
    let launch = reserve(&f);
    let workspace = f.node.db.lock().get_workspace("repo").unwrap();
    f.node.db.lock().execute_batch("CREATE TRIGGER fail_guard BEFORE UPDATE OF guard_state ON sandbox_launches BEGIN SELECT RAISE(ABORT,'disk full'); END;").unwrap();
    let prepared = prepared(Arc::new(Scope {
        ready: AtomicBool::new(true),
        reads: AtomicUsize::new(0),
    }));
    let mut child = child();
    assert!(
        release_guarded_launch(&f.node, &prepared, &launch, &workspace, &f.mode, &mut child)
            .await
            .is_err()
    );
    assert!(output(child).await.is_empty());
    f.node.close().await;
}
#[tokio::test]
async fn transition_during_observation_prevents_later_release() {
    let f = Fixture::new().await;
    let launch = reserve(&f);
    let workspace = f.node.db.lock().get_workspace("repo").unwrap();
    let scope = Arc::new(Scope {
        ready: AtomicBool::new(false),
        reads: AtomicUsize::new(0),
    });
    let node = f.node.clone();
    let mode = f.mode.clone();
    let prepared = prepared(scope.clone());
    let running = tokio::spawn(async move {
        let mut child = child();
        let result =
            release_guarded_launch(&node, &prepared, &launch, &workspace, &mode, &mut child).await;
        (result, output(child).await)
    });
    tokio::time::timeout(Duration::from_secs(2), async {
        while scope.reads.load(Ordering::SeqCst) == 0 {
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
    {
        let db = f.node.db.lock();
        let lease = db
            .acquire_lease(&f.current, "phone", false, 60_000)
            .unwrap();
        crate::execution_fences::accept(
            &db,
            "alice",
            &f.current,
            &crate::execution_fences::Intent {
                operation_id: "during-start".into(),
                plan_hash: "a".repeat(64),
                expected_workspace_id: "repo".into(),
                expected_runner_epoch: 1,
                preflight: None,
            },
            "phone",
            lease.generation,
        )
        .unwrap();
    }
    scope.ready.store(true, Ordering::SeqCst);
    let (result, bytes) = running.await.unwrap();
    assert_eq!(result.unwrap_err().code, "environment_transition_pending");
    assert!(bytes.is_empty());
    f.node.close().await;
}

#[tokio::test]
async fn changed_workspace_and_node_shutdown_both_refuse_release() {
    for closing in [false, true] {
        let f = Fixture::new().await;
        let launch = reserve(&f);
        let mut workspace = f.node.db.lock().get_workspace("repo").unwrap();
        let prepared = prepared(Arc::new(Scope {
            ready: AtomicBool::new(true),
            reads: AtomicUsize::new(0),
        }));
        let mut child = child();
        if closing {
            f.node.close().await;
        } else {
            workspace.canonical_path.push_str("-changed");
        }
        assert!(
            release_guarded_launch(&f.node, &prepared, &launch, &workspace, &f.mode, &mut child)
                .await
                .is_err()
        );
        assert!(output(child).await.is_empty());
        let state: String = f
            .node
            .db
            .lock()
            .query_row(
                "SELECT guard_state FROM sandbox_launches WHERE session_id=?1",
                [&f.current],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(state, "waiting");
        if !closing {
            f.node.close().await;
        }
    }
}
