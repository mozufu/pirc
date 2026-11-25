use super::super::side::Side;
use super::*;
use crate::workspace_memory::tests::Fixture;
use std::path::Path;

fn side(runner: &Runner) -> Side {
    let side = Side {
        id: crate::util::uuid(),
        abort: Arc::new(watch::channel(false).0),
    };
    runner.lock().sandbox_requests.insert(
        side.id.clone(),
        SideRequest {
            abort: side.abort.clone(),
            dialog: None,
            task: None,
        },
    );
    side
}
#[tokio::test]
async fn approval_cannot_outlive_runner_epoch_mode_directory_or_withdrawal() {
    let f = Fixture::new().await;
    let row = f.node.db.lock().get_session(&f.current).unwrap();
    let runner = super::memory_concurrency_tests::register(&f, row);
    let cwd = runner.workspace.canonical_path.clone();
    let request = side(&runner);
    request.abort.send_replace(true);
    assert!(
        runner
            .start_host_with_approval(&request, "true", &cwd, Duration::from_secs(5))
            .is_err()
    );
    let request = side(&runner);
    // Reusing an RPC ID cannot borrow its replacement's approval channel.
    runner.lock().sandbox_requests.insert(
        request.id.clone(),
        SideRequest {
            abort: Arc::new(watch::channel(false).0),
            dialog: None,
            task: None,
        },
    );
    assert!(
        runner
            .start_host_with_approval(&request, "true", &cwd, Duration::from_secs(5))
            .is_err()
    );
    let request = side(&runner);
    let mode_id = f.mode.id.clone();
    f.node
        .modes
        .write()
        .unwrap()
        .get_mut(&mode_id)
        .unwrap()
        .workspace_memory = false;
    assert!(
        runner
            .start_host_with_approval(&request, "true", &cwd, Duration::from_secs(5))
            .is_err()
    );
    f.node
        .modes
        .write()
        .unwrap()
        .insert(mode_id, f.mode.clone());
    let request = side(&runner);
    assert!(
        runner
            .start_host_with_approval(&request, "true", "/", Duration::from_secs(5))
            .is_err()
    );
    let sub = PathBuf::from(&cwd).join("approved");
    std::fs::create_dir(&sub).unwrap();
    std::fs::remove_dir(&sub).unwrap();
    std::os::unix::fs::symlink("/", &sub).unwrap();
    let request = side(&runner);
    assert!(
        runner
            .start_host_with_approval(
                &request,
                "true",
                sub.to_str().unwrap(),
                Duration::from_secs(5)
            )
            .is_err()
    );
    let request = side(&runner);
    let ticket = runner
        .start_host_with_approval(&request, "printf approved", &cwd, Duration::from_secs(5))
        .unwrap();
    assert_eq!(ticket.result().await.unwrap()["output"], "approved");
    let request = side(&runner);
    f.node.db.lock().increment_epoch(&f.current).unwrap();
    assert!(
        runner
            .start_host_with_approval(&request, "true", &cwd, Duration::from_secs(5))
            .is_err()
    );
    runner.exit(Some(0), None);
    f.node.close().await;
}
#[tokio::test]
async fn runner_exit_cancels_host_jobs_even_after_side_entry_is_replaced() {
    let f = Fixture::new().await;
    let row = f.node.db.lock().get_session(&f.current).unwrap();
    let runner = super::memory_concurrency_tests::register(&f, row);
    let request = side(&runner);
    let ticket = runner
        .start_host_with_approval(
            &request,
            "exec /bin/sleep 30",
            &runner.workspace.canonical_path,
            Duration::from_secs(60),
        )
        .unwrap();
    runner.lock().sandbox_requests.remove(&request.id);
    runner.exit(Some(0), None);
    let peer = f
        .node
        .db
        .lock()
        .create_session("repo", "/unused-peer", "alice")
        .unwrap();
    assert!(
        matches!(f.node.writes.acquire(&peer.id, Path::new(&runner.workspace.canonical_path)), crate::write_broker::WriteGrant::Blocked { code, .. } if code == "host_write_pending")
    );
    // Exit alone sends cancellation; a caller requiring drainage waits for the
    // Node-owned registry even though the runner and side entry are both gone.
    f.node.runners.stop_session(&f.current).await.unwrap();
    assert_eq!(ticket.result().await.unwrap()["aborted"], true);
    assert_eq!(
        f.node
            .writes
            .acquire(&peer.id, Path::new(&runner.workspace.canonical_path)),
        crate::write_broker::WriteGrant::Granted
    );
    f.node.close().await;
}

#[tokio::test]
async fn runner_stop_cancels_approved_commands_before_agent_exit() {
    let f = Fixture::new().await;
    let row = f.node.db.lock().get_session(&f.current).unwrap();
    let runner = super::memory_concurrency_tests::register(&f, row);
    let request = side(&runner);
    let ticket = runner
        .start_host_with_approval(
            &request,
            "exec /bin/sleep 30",
            &runner.workspace.canonical_path,
            Duration::from_secs(60),
        )
        .unwrap();
    // This fixture has no Agent replying to abort and no exit event. Cancellation
    // must occur when Stop begins, without waiting for either acknowledgement.
    runner.stop(Duration::from_millis(1)).await;
    assert!(!runner.lock().closed);
    assert!(*request.abort.borrow());
    assert_eq!(
        tokio::time::timeout(Duration::from_secs(4), ticket.result())
            .await
            .unwrap()
            .unwrap()["aborted"],
        true
    );
    runner.exit(Some(0), None);
    f.node.close().await;
}

#[tokio::test]
async fn host_admission_cannot_deadlock_against_memory_lifecycle_lock() {
    let f = Fixture::new().await;
    let row = f.node.db.lock().get_session(&f.current).unwrap();
    let runner = super::memory_concurrency_tests::register(&f, row);
    let request = side(&runner);
    let (send, receive) = std::sync::mpsc::channel();
    let worker = runner.clone();
    let runtime = tokio::runtime::Handle::current();
    let lifecycle = runner.lock();
    let thread = std::thread::spawn(move || {
        let _runtime = runtime.enter();
        let result = worker
            .start_host_with_approval(
                &request,
                "true",
                &worker.workspace.canonical_path,
                Duration::from_secs(5),
            )
            .map(drop)
            .map_err(|e| e.code.into_owned());
        send.send(result).unwrap();
    });
    let result = receive.recv_timeout(Duration::from_secs(3));
    // Always release/join before asserting, so a regression reports a failure
    // instead of leaving a blocked thread or preventing fixture cleanup.
    drop(lifecycle);
    thread.join().unwrap();
    assert_eq!(result.unwrap(), Err("host_admission_busy".into()));
    assert_eq!(
        f.node
            .db
            .lock()
            .query_row("SELECT count(*) FROM host_command_runs", [], |r| r
                .get::<_, i64>(0))
            .unwrap(),
        0
    );
    let request = side(&runner);
    let ticket = runner
        .start_host_with_approval(
            &request,
            "printf retry",
            &runner.workspace.canonical_path,
            Duration::from_secs(5),
        )
        .unwrap();
    assert_eq!(ticket.result().await.unwrap()["output"], "retry");
    runner.exit(Some(0), None);
    f.node.close().await;
}

impl Runner {
    fn start_host_with_approval(
        &self,
        side: &Side,
        text: &str,
        cwd: &str,
        timeout: Duration,
    ) -> crate::error::ApiResult<crate::host_commands::Ticket> {
        let node = self.node().unwrap();
        let intent = self.host_intent(side, text, cwd, timeout).unwrap();
        let approval = {
            let db = node.db.lock();
            crate::host_commands::approval::tests::issue(
                &db,
                &node,
                crate::host_commands::approval::Request {
                    session: &self.session_id,
                    workspace: &self.workspace.id,
                    epoch: self.epoch,
                    request: &side.id,
                    intent_hash: &intent,
                },
                true,
            )?
        };
        self.start_host(side, text, cwd, timeout, &approval)
    }
}

#[tokio::test]
async fn host_management_binds_the_exact_command_directory_timeout_and_side() {
    let f = Fixture::new().await;
    let row = f.node.db.lock().get_session(&f.current).unwrap();
    let runner = super::memory_concurrency_tests::register(&f, row);
    let request = side(&runner);
    let cwd = runner.workspace.canonical_path.clone();
    let timeout = Duration::from_secs(5);
    let text = "printf allowed";
    let hash = runner.host_intent(&request, text, &cwd, timeout).unwrap();
    let approval = crate::host_commands::approval::tests::issue(
        &f.node.db.lock(),
        &f.node,
        crate::host_commands::approval::Request {
            session: &f.current,
            workspace: &runner.workspace.id,
            epoch: runner.epoch,
            request: &request.id,
            intent_hash: &hash,
        },
        true,
    )
    .unwrap();
    let sub = Path::new(&cwd).join("other-directory");
    std::fs::create_dir(&sub).unwrap();
    let attempts = [
        ("printf changed", cwd.as_str(), timeout),
        (text, cwd.as_str(), timeout + Duration::from_secs(1)),
        (text, sub.to_str().unwrap(), timeout),
    ];
    for (text, cwd, timeout) in attempts {
        assert_eq!(
            runner
                .start_host(&request, text, cwd, timeout, &approval)
                .err()
                .unwrap()
                .code,
            "host_management_approval_required"
        );
    }
    let another = side(&runner);
    assert_eq!(
        runner
            .start_host(&another, text, &cwd, timeout, &approval)
            .err()
            .unwrap()
            .code,
        "host_management_approval_required"
    );
    assert_eq!(
        runner
            .start_host(&request, text, &cwd, timeout, "model-supplied-approval")
            .err()
            .unwrap()
            .code,
        "host_management_approval_required"
    );
    assert_eq!(
        runner
            .start_host(&request, text, &cwd, timeout, &approval)
            .unwrap()
            .result()
            .await
            .unwrap()["output"],
        "allowed"
    );
    runner.exit(Some(0), None);
    f.node.close().await;
}

#[tokio::test]
async fn sandbox_exec_persists_host_management_question_before_user_approval() {
    let f = Fixture::new().await;
    let row = f.node.db.lock().get_session(&f.current).unwrap();
    let runner = super::memory_concurrency_tests::register(&f, row);
    let marker = Path::new(&runner.workspace.canonical_path).join("host-management-marker");
    runner.handle_sandbox(json!({"id":"requested-host-command","op":"exec","args":{
        "command":"printf managed > host-management-marker","reason":"user requested host administration","timeoutMs":5000,"executionPath":"full-access"
    }}).as_object().unwrap()).unwrap();
    let interaction = tokio::time::timeout(Duration::from_secs(2), async {
        loop {
            let pending = f.node.db.lock().pending_interactions(&f.current).unwrap();
            if let Some(interaction) = pending.into_iter().next() {
                break interaction;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
    assert_eq!(
        interaction.request["title"],
        "Allow host management for this command?"
    );
    assert!(
        interaction.request["message"]
            .as_str()
            .unwrap()
            .contains("Detached jobs")
    );
    assert!(!marker.exists());
    let answer = json!({"confirmed":true});
    {
        let db = f.node.db.lock();
        let (path, run): (String, Option<String>) = db
        .query_row(
            "SELECT execution_path,run_id FROM host_execution_approvals WHERE interaction_id=?1",
            [&interaction.id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap();
        assert_eq!(path, "host_management");
        assert!(run.is_none());
        db.claim_interaction(&interaction.id, &f.current, runner.epoch, &answer, None)
            .unwrap();
        // A second device's stale confirmation cannot launch another command.
        assert!(
            db.claim_interaction(&interaction.id, &f.current, runner.epoch, &answer, None)
                .is_err()
        );
    }
    runner
        .answer(
            &interaction.rpc_id,
            &interaction.id,
            answer.as_object().unwrap(),
            &interaction,
        )
        .await
        .unwrap();
    tokio::time::timeout(Duration::from_secs(3),async {
        loop {
            let done:bool=f.node.db.lock().query_row("SELECT EXISTS(SELECT 1 FROM host_execution_approvals a JOIN host_command_runs h ON h.id=a.run_id WHERE a.interaction_id=?1 AND h.state='settled')",[&interaction.id],|r|r.get(0)).unwrap();
            if done { break; }
            tokio::task::yield_now().await;
        }
    }).await.unwrap();
    assert_eq!(std::fs::read_to_string(marker).unwrap(), "managed");
    runner.exit(Some(0), None);
    f.node.close().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn racing_waiters_share_one_host_approval_without_reexecuting() {
    let f = Fixture::new().await;
    let row = f.node.db.lock().get_session(&f.current).unwrap();
    let runner = super::memory_concurrency_tests::register(&f, row);
    let request = side(&runner);
    let cwd = runner.workspace.canonical_path.clone();
    let text = "printf one >> approved-once";
    let timeout = Duration::from_secs(5);
    let hash = runner.host_intent(&request, text, &cwd, timeout).unwrap();
    let approval = crate::host_commands::approval::tests::issue(
        &f.node.db.lock(),
        &f.node,
        crate::host_commands::approval::Request {
            session: &f.current,
            workspace: &runner.workspace.id,
            epoch: runner.epoch,
            request: &request.id,
            intent_hash: &hash,
        },
        true,
    )
    .unwrap();
    let mut tasks = Vec::new();
    let barrier = Arc::new(tokio::sync::Barrier::new(2));
    for _ in 0..2 {
        let runner = runner.clone();
        let request = Side {
            id: request.id.clone(),
            abort: request.abort.clone(),
        };
        let cwd = cwd.clone();
        let approval = approval.clone();
        let barrier = barrier.clone();
        tasks.push(tokio::spawn(async move {
            barrier.wait().await;
            let result = runner.start_host(&request, text, &cwd, timeout, &approval);
            match result {
                Ok(ticket) => ticket.result().await.is_ok(),
                Err(_) => false,
            }
        }));
    }
    let mut accepted = 0;
    for task in tasks {
        accepted += usize::from(task.await.unwrap());
    }
    assert_eq!(accepted, 1);
    assert_eq!(
        std::fs::read_to_string(Path::new(&cwd).join("approved-once")).unwrap(),
        "one"
    );
    runner.exit(Some(0), None);
    f.node.close().await;
}
