use super::*;
use crate::{
    execution_fences,
    sandbox::{BoxFuture, PrepareInput, Prepared, ReadonlyInput, Sandbox, SandboxStatus},
    store::ModeId,
};
use std::{
    path::PathBuf,
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    time::Duration,
};

async fn fixture() -> (tempfile::TempDir, Node, SessionRow, Access, PathBuf) {
    let (dir, node) = crate::app::tests::workspace_test_node().await;
    let root = dir.path().canonicalize().unwrap().join("repository");
    std::fs::create_dir(&root).unwrap();
    let session = {
        let db = node.db.lock();
        db.add_workspace(
            "repo",
            "test-node",
            "Repo",
            root.to_str().unwrap(),
            ModeId::new("directory").unwrap(),
        )
        .unwrap();
        db.create_session("repo", "/private/session", "test-user")
            .unwrap()
    };
    let workspace = node.db.lock().get_workspace("repo").unwrap();
    let mode = node.workspace_mode(&workspace).unwrap();
    let access = Access::new(
        node.clone(),
        "test-user".into(),
        session.clone(),
        workspace,
        mode,
    );
    (dir, node, session, access, root)
}
fn fence(node: &Node, session: &SessionRow) {
    let db = node.db.lock();
    let lease = db
        .acquire_lease(&session.id, "phone", true, 60_000)
        .unwrap();
    execution_fences::accept(
        &db,
        "test-user",
        &session.id,
        &execution_fences::Intent {
            operation_id: "panel-transition".into(),
            plan_hash: "a".repeat(64),
            expected_workspace_id: session.workspace_id.clone(),
            expected_runner_epoch: session.runner_epoch,
            preflight: None,
        },
        "phone",
        lease.generation,
    )
    .unwrap();
}

#[tokio::test]
async fn access_is_environment_scoped_and_does_not_require_the_controller_lease() {
    let (_dir, node, session, access, root) = fixture().await;
    std::fs::write(root.join("user.txt"), "preserve later user edits").unwrap();
    node.db
        .lock()
        .acquire_lease(&session.id, "different-device", false, 60_000)
        .unwrap();
    assert!(access.run(|| Ok(())).is_ok());
    let peer = node
        .db
        .lock()
        .create_session("repo", "/private/peer", "test-user")
        .unwrap();
    let mut peer_access = access.clone();
    peer_access.session = peer;
    fence(&node, &session);
    assert_eq!(
        access
            .run::<()>(|| panic!("revoked reads must not run"))
            .unwrap_err()
            .code,
        "environment_transition_pending"
    );
    assert!(peer_access.run(|| Ok(())).is_ok());
    assert_eq!(
        std::fs::read_to_string(root.join("user.txt")).unwrap(),
        "preserve later user edits"
    );
    node.close().await;
}

#[tokio::test]
async fn late_results_and_errors_are_discarded_after_revocation() {
    for fail in [false, true] {
        let (_dir, node, session, access, _root) = fixture().await;
        let result = access
            .inspect(async {
                tokio::task::yield_now().await;
                fence(&node, &session);
                if fail {
                    Err(ApiError::bad_request("private stderr"))
                } else {
                    Ok("private late output")
                }
            })
            .await
            .unwrap_err();
        assert_eq!(result.code, "environment_transition_pending");
        assert!(!result.message.contains("private"));
        node.close().await;
    }
}

#[tokio::test]
async fn workspace_epoch_mode_and_deletion_changes_invalidate_a_captured_read() {
    let (_dir, node, session, access, _root) = fixture().await;
    node.db
        .lock()
        .execute(
            "UPDATE sessions SET runner_epoch=runner_epoch+1 WHERE id=?",
            [&session.id],
        )
        .unwrap();
    assert_eq!(access.run(|| Ok(())).unwrap_err().code, "stale_environment");
    node.db
        .lock()
        .execute(
            "UPDATE sessions SET runner_epoch=runner_epoch-1 WHERE id=?",
            [&session.id],
        )
        .unwrap();
    let original = node.db.lock().get_workspace("repo").unwrap();
    node.db
        .lock()
        .execute(
            "UPDATE workspaces SET canonical_path='/other' WHERE id='repo'",
            [],
        )
        .unwrap();
    assert_eq!(access.run(|| Ok(())).unwrap_err().code, "stale_environment");
    node.db
        .lock()
        .execute(
            "UPDATE workspaces SET canonical_path=? WHERE id='repo'",
            [&original.canonical_path],
        )
        .unwrap();
    let mut mode = access.mode.clone();
    mode.workspace_memory = !mode.workspace_memory;
    node.replace_modes(vec![mode]).await;
    assert_eq!(access.run(|| Ok(())).unwrap_err().code, "stale_environment");
    node.replace_modes(vec![access.mode.clone()]).await;
    assert!(access.run(|| Ok(())).is_ok());
    node.db
        .lock()
        .begin_session_deletion(&session.id, "test-user")
        .unwrap();
    assert!(access.run(|| Ok(())).is_err());
    node.close().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn synchronous_read_and_fence_have_one_ordered_boundary() {
    let (_dir, node, session, access, _root) = fixture().await;
    let (entered, in_read) = std::sync::mpsc::channel();
    let (release, released) = std::sync::mpsc::channel();
    let reader = access.clone();
    let task = std::thread::spawn(move || {
        reader.run(|| {
            entered.send(()).unwrap();
            released.recv_timeout(Duration::from_secs(3)).unwrap();
            Ok(())
        })
    });
    in_read.recv_timeout(Duration::from_secs(3)).unwrap();
    let node_copy = node.clone();
    let session_copy = session.clone();
    let (started, starting) = std::sync::mpsc::channel();
    let transition = std::thread::spawn(move || {
        started.send(()).unwrap();
        fence(&node_copy, &session_copy);
    });
    starting.recv_timeout(Duration::from_secs(3)).unwrap();
    assert!(!transition.is_finished());
    release.send(()).unwrap();
    task.join().unwrap().unwrap();
    transition.join().unwrap();
    assert_eq!(
        access.run(|| Ok(())).unwrap_err().code,
        "environment_transition_pending"
    );
    node.close().await;
}

struct TestSandbox {
    node: Node,
    session: SessionRow,
    at_check: bool,
    at_prepare: bool,
    prepared: AtomicUsize,
    cleaned: Arc<AtomicUsize>,
    marker: PathBuf,
    close_output: bool,
}
impl Sandbox for TestSandbox {
    fn check(&self) -> BoxFuture<'_, SandboxStatus> {
        Box::pin(async {
            tokio::task::yield_now().await;
            if self.at_check {
                fence(&self.node, &self.session);
            }
            SandboxStatus::Active {
                description: "test".into(),
            }
        })
    }
    fn prepare(&self, _: PrepareInput) -> BoxFuture<'_, ApiResult<Prepared>> {
        unreachable!()
    }
    fn prepare_readonly(&self, _: ReadonlyInput) -> BoxFuture<'_, ApiResult<Prepared>> {
        Box::pin(async {
            self.prepared.fetch_add(1, Ordering::SeqCst);
            tokio::task::yield_now().await;
            if self.at_prepare {
                fence(&self.node, &self.session);
            }
            let cleaned = self.cleaned.clone();
            let script = if self.close_output {
                "printf '%s' \"$$\" > \"$1\"; exec sleep 30 1>&- 2>&-"
            } else {
                "printf '%s' \"$$\" > \"$1\"; printf 'private before revocation'; exec sleep 30"
            };
            Ok(Prepared::new(
                "/bin/sh".into(),
                vec![
                    "-c".into(),
                    script.into(),
                    "test".into(),
                    self.marker.clone().into_os_string(),
                ],
                vec![],
                Default::default(),
                vec![],
                None,
                move || {
                    cleaned.fetch_add(1, Ordering::SeqCst);
                },
            ))
        })
    }
}

#[tokio::test]
async fn revoked_probe_and_preparation_never_launch_git_or_report_an_empty_repository() {
    for at_check in [true, false] {
        let (_dir, node, session, access, root) = fixture().await;
        let sandbox = TestSandbox {
            node: node.clone(),
            session,
            at_check,
            at_prepare: !at_check,
            prepared: AtomicUsize::new(0),
            cleaned: Arc::new(AtomicUsize::new(0)),
            marker: root.join("spawned"),
            close_output: false,
        };
        let env = super::super::inspect::ChildEnv::new();
        let error = access
            .inspect(super::super::inspect::git_status(&sandbox, &root, &env))
            .await
            .unwrap_err();
        assert_eq!(error.code, "environment_transition_pending");
        assert!(!sandbox.marker.exists());
        assert_eq!(
            sandbox.prepared.load(Ordering::SeqCst),
            usize::from(!at_check)
        );
        assert_eq!(
            sandbox.cleaned.load(Ordering::SeqCst),
            usize::from(!at_check)
        );
        node.close().await;
    }
}

#[tokio::test]
async fn running_git_is_killed_and_reaped_without_publishing_stale_output() {
    for close_output in [false, true] {
        let (_dir, node, session, access, root) = fixture().await;
        let marker = root.join("started");
        let sandbox = Arc::new(TestSandbox {
            node: node.clone(),
            session: session.clone(),
            at_check: false,
            at_prepare: false,
            prepared: AtomicUsize::new(0),
            cleaned: Arc::new(AtomicUsize::new(0)),
            marker: marker.clone(),
            close_output,
        });
        let child_sandbox = sandbox.clone();
        let task = tokio::spawn(async move {
            let env =
                super::super::inspect::ChildEnv::from([("PATH".into(), "/usr/bin:/bin".into())]);
            access
                .inspect(super::super::inspect::git_log(
                    child_sandbox.as_ref(),
                    &root,
                    &env,
                    0,
                    10,
                ))
                .await
        });
        let pid = tokio::time::timeout(Duration::from_secs(3), async {
            loop {
                if let Ok(raw) = std::fs::read_to_string(&marker)
                    && let Ok(pid) = raw.parse::<i32>()
                {
                    break pid;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
        fence(&node, &session);
        let error = tokio::time::timeout(Duration::from_secs(3), task)
            .await
            .unwrap()
            .unwrap()
            .unwrap_err();
        assert_eq!(error.code, "environment_transition_pending");
        assert_eq!(
            nix::sys::signal::kill(nix::unistd::Pid::from_raw(pid), None),
            Err(nix::errno::Errno::ESRCH)
        );
        assert_eq!(sandbox.cleaned.load(Ordering::SeqCst), 1);
        node.close().await;
    }
}
