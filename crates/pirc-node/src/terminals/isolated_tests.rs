//! Real Node/journals and PTY processes with a synthetic kernel adapter. Native
//! Linux PID-namespace enforcement is a separate required backend acceptance.
use super::*;
use crate::sandbox::{
    BoxFuture, NetworkControl, PrepareInput, Prepared, ReadonlyInput, Sandbox, SandboxStatus,
    processes::{Identity, ProcessScope, Snapshot, State},
};
use crate::{
    services::{Node, Services},
    store::Store,
};
use pirc_config::{Env, NodeConfig};
use pirc_protocol::NodeRole;
use serde_json::json;
use std::{
    path::PathBuf,
    sync::atomic::{AtomicBool, AtomicUsize, Ordering},
};

#[derive(Default)]
struct Scope {
    identity_index: AtomicUsize,
    ready: AtomicBool,
    retired: AtomicBool,
    spawned: AtomicUsize,
}
impl ProcessScope for Scope {
    fn spawned(&self, _: u32) {
        self.spawned.fetch_add(1, Ordering::SeqCst);
    }
    fn terminate(&self) {
        self.retired.store(true, Ordering::SeqCst);
    }
    fn cleanup(&self) {}
    fn state(&self) -> State {
        if self.retired.load(Ordering::SeqCst) {
            State::Terminated
        } else if self.ready.load(Ordering::SeqCst) {
            State::Running
        } else {
            State::Observing
        }
    }
    fn snapshot(&self) -> Snapshot {
        Snapshot {
            state: self.state(),
            identity: self.ready.load(Ordering::SeqCst).then(|| Identity {
                boot_id: "11111111-2222-3333-4444-555555555555".into(),
                observer_namespace: 10,
                namespace: 11 + self.identity_index.load(Ordering::SeqCst) as u64,
                pid: 22 + self.identity_index.load(Ordering::SeqCst) as u32,
                start_ticks: 100 + self.identity_index.load(Ordering::SeqCst) as u64,
            }),
        }
    }
}
struct Control;
impl NetworkControl for Control {
    fn prepare_command(&self, _: &mut tokio::process::Command) -> std::io::Result<()> {
        Err(std::io::Error::other("only terminal fixture commands"))
    }
    fn prepare_terminal(
        &self,
        command: &mut tokio::process::Command,
        gate: std::os::fd::OwnedFd,
    ) -> std::io::Result<()> {
        use command_fds::{CommandFdExt, FdMapping};
        command
            .fd_mappings(vec![FdMapping {
                parent_fd: gate,
                child_fd: crate::sandbox::terminal_gate::FD,
            }])
            .map_err(std::io::Error::other)?;
        Ok(())
    }
    fn is_open(&self) -> bool {
        true
    }
    fn approve(&self, _: &[String]) -> Result<(), String> {
        Ok(())
    }
}
struct Backend {
    prepared: AtomicUsize,
    scope: Arc<Scope>,
    report: PathBuf,
}
impl Sandbox for Backend {
    fn terminal_io_owner(&self) -> std::io::Result<crate::sandbox::processes::ObserverIdentity> {
        Ok(crate::sandbox::processes::ObserverIdentity {
            version: 1,
            boot_id: "11111111-2222-3333-4444-555555555555".into(),
            observer_namespace: 10,
            pid: 999,
            start_ticks: 100,
        })
    }
    fn isolated_terminals(&self) -> bool {
        true
    }
    fn check(&self) -> BoxFuture<'_, SandboxStatus> {
        Box::pin(async {
            SandboxStatus::Active {
                description: "synthetic process scope".into(),
            }
        })
    }
    fn prepare(&self, _: PrepareInput) -> BoxFuture<'_, ApiResult<Prepared>> {
        Box::pin(async { Err(ApiError::internal()) })
    }
    fn prepare_readonly(&self, _: ReadonlyInput) -> BoxFuture<'_, ApiResult<Prepared>> {
        Box::pin(async { Err(ApiError::internal()) })
    }
    fn prepare_terminal(&self, _: PrepareInput, _: PathBuf) -> BoxFuture<'_, ApiResult<Prepared>> {
        let count = self.prepared.fetch_add(1, Ordering::SeqCst);
        let (scope, report) = if count == 0 {
            (self.scope.clone(), self.report.clone())
        } else {
            let scope = Arc::new(Scope::default());
            scope.identity_index.store(count, Ordering::SeqCst);
            scope
                .ready
                .store(self.scope.ready.load(Ordering::SeqCst), Ordering::SeqCst);
            (scope, self.report.with_extension(count.to_string()))
        };
        Box::pin(async move {
            Ok(Prepared::new(
                std::env::current_exe().unwrap(),
                vec![
                    "--exact".into(),
                    crate::sandbox::terminal_gate::tests::CHILD.into(),
                    "--ignored".into(),
                    "--nocapture".into(),
                ],
                vec![(
                    "PIRC_TEST_TERMINAL_REPORT".into(),
                    report.display().to_string(),
                )],
                Default::default(),
                vec![],
                Some(Box::new(Control)),
                || {},
            )
            .with_process_scope(scope)
            .with_terminal_guard())
        })
    }
}
struct Fixture {
    _dir: tempfile::TempDir,
    node: Node,
    session: String,
    root: PathBuf,
    report: PathBuf,
    scope: Arc<Scope>,
    generation: i64,
}
impl Fixture {
    async fn new(ready: bool) -> Self {
        let dir = tempfile::tempdir_in("/tmp").unwrap();
        let root = dir.path().canonicalize().unwrap();
        for path in ["state", "config", "home", "workspace", "session"] {
            std::fs::create_dir(root.join(path)).unwrap();
        }
        let vars = vec![
            ("PIRC_NODE_ID".into(), "isolated-test".into()),
            (
                "PIRC_NODE_TOKEN".into(),
                "0123456789abcdef0123456789abcdef".into(),
            ),
            ("PIRC_DAEMON_URL".into(), "ws://127.0.0.1:8787".into()),
            ("PIRC_BROWSER".into(), "false".into()),
            ("PIRC_ALLOWED_USERS".into(), "alice".into()),
            (
                "PIRC_STATE_DIR".into(),
                root.join("state").display().to_string(),
            ),
            (
                "PIRC_CONFIG_DIR".into(),
                root.join("config").display().to_string(),
            ),
            ("HOME".into(), root.join("home").display().to_string()),
            (
                "PIRC_WORKSPACES".into(),
                json!([{"id":"repo","path":root.join("workspace")}]).to_string(),
            ),
        ];
        let env = Env::new(
            vars.iter()
                .map(|(k, v): &(String, String)| (k.as_str(), v.as_str())),
            &root,
        );
        let config = NodeConfig::load(&env, NodeRole::Node).unwrap();
        let scope = Arc::new(Scope::default());
        scope.ready.store(ready, Ordering::SeqCst);
        let report = root.join("report");
        let node = Services::start_with_sandbox(
            config,
            env,
            Arc::new(Backend {
                prepared: AtomicUsize::new(0),
                scope: scope.clone(),
                report: report.clone(),
            }),
        )
        .await
        .unwrap();
        node.modes.write().unwrap().insert(
            crate::store::ModeId::new("directory").unwrap(),
            pirc_protocol::mode::default_work(),
        );
        let session = node
            .db
            .lock()
            .create_session("repo", root.join("session").to_str().unwrap(), "alice")
            .unwrap()
            .id;
        let generation = node
            .db
            .lock()
            .acquire_lease(&session, "phone", false, 60_000)
            .unwrap()
            .generation;
        Self {
            _dir: dir,
            node,
            session,
            root: root.join("workspace"),
            report,
            scope,
            generation,
        }
    }
    fn open(&self) -> tokio::task::JoinHandle<ApiResult<TerminalInfo>> {
        let node = self.node.clone();
        let session = self.session.clone();
        let root = self.root.clone();
        let generation = self.generation;
        tokio::spawn(async move {
            node.terminals
                .create_isolated(&session, &root, None, None, ("phone", generation))
                .await
        })
    }
}
async fn until(mut f: impl FnMut() -> bool) {
    tokio::time::timeout(Duration::from_secs(8), async {
        while !f() {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap();
}
#[tokio::test]
async fn isolated_terminal_commits_shared_scope_before_work_and_retires_both_journals() {
    let f = Fixture::new(true).await;
    let peer = f.root.join("user-kept");
    std::fs::write(&peer, "later user change").unwrap();
    let terminal = f.open().await.unwrap().unwrap();
    assert_eq!(terminal.execution_path.as_deref(), Some("isolated_work"));
    until(|| f.report.exists()).await;
    let shared:bool=f.node.db.lock().query_row("SELECT EXISTS(SELECT 1 FROM terminal_runs t JOIN sandbox_launches l ON l.launch_id=t.id WHERE t.session_id=?1 AND l.guard_state='released' AND l.identity_json IS NOT NULL)",[&f.session],|r|r.get(0)).unwrap();
    assert!(shared);
    let control = Arc::new(super::input::Control {
        client: "phone".into(),
        generation: f.generation,
        open: Arc::new(Mutex::new(true)),
        rejected: Arc::new(|error| panic!("unexpected input rejection: {error:?}")),
    });
    f.node
        .terminals
        .input_controlled(&f.session, &terminal.id, "finish\n", control)
        .unwrap();
    let entry = f.node.terminals.lookup(&f.session, &terminal.id).unwrap();
    until(|| entry.state().info.exited).await;
    {
        let db = f.node.db.lock();
        assert_eq!(
            crate::process_journal::summary(&db, &f.session)
                .unwrap()
                .terminated,
            1
        );
        assert_eq!(
            serde_json::to_value(journal::summary(&db, &f.session).unwrap()).unwrap()["observersSettled"],
            1
        );
    }
    assert_eq!(std::fs::read_to_string(peer).unwrap(), "later user change");
    f.node.close().await;
}
#[tokio::test]
async fn failed_scope_commit_never_releases_user_work() {
    let f = Fixture::new(true).await;
    f.node.db.lock().execute_batch("CREATE TRIGGER fail_permission BEFORE UPDATE OF guard_state ON sandbox_launches WHEN NEW.guard_state='released' BEGIN SELECT RAISE(ABORT,'disk full'); END;").unwrap();
    assert!(f.open().await.unwrap().is_err());
    f.node.terminals.dispose_session(&f.session).await.unwrap();
    assert!(!f.report.exists());
    assert_eq!(
        crate::process_journal::summary(&f.node.db.lock(), &f.session)
            .unwrap()
            .terminated,
        1
    );
    f.node.close().await;
}
#[tokio::test]
async fn controller_takeover_and_transition_fence_refuse_permission_during_capture() {
    for fence in [false, true] {
        let f = Fixture::new(false).await;
        let open = f.open();
        until(|| f.scope.spawned.load(Ordering::SeqCst) > 0).await;
        if fence {
            crate::execution_fences::accept(
                &f.node.db.lock(),
                "alice",
                &f.session,
                &crate::execution_fences::Intent {
                    operation_id: "while-capturing".into(),
                    plan_hash: "a".repeat(64),
                    expected_workspace_id: "repo".into(),
                    expected_runner_epoch: 0,
                    preflight: None,
                },
                "phone",
                f.generation,
            )
            .unwrap();
        } else {
            f.node
                .db
                .lock()
                .acquire_lease(&f.session, "web", true, 60_000)
                .unwrap();
        }
        assert!(open.await.unwrap().is_err());
        assert!(!f.report.exists());
        // No captured identity means no terminal/kernel closure acknowledgement.
        let _ = f.node.terminals.dispose_session(&f.session).await;
        assert_eq!(
            crate::process_journal::summary(&f.node.db.lock(), &f.session)
                .unwrap()
                .unresolved,
            1
        );
        f.node.close().await;
    }
}
#[tokio::test]
async fn unsupported_backend_does_not_open_a_host_terminal_or_create_launch_rows() {
    let f = crate::workspace_memory::tests::Fixture::new().await;
    let root = PathBuf::from(
        f.node
            .db
            .lock()
            .get_workspace("repo")
            .unwrap()
            .canonical_path,
    );
    let lease = f
        .node
        .db
        .lock()
        .acquire_lease(&f.current, "phone", false, 60_000)
        .unwrap();
    assert_eq!(
        f.node
            .terminals
            .create_isolated(&f.current, &root, None, None, ("phone", lease.generation))
            .await
            .unwrap_err()
            .code,
        "isolated_terminal_unavailable"
    );
    assert!(f.node.terminals.list(&f.current).is_empty());
    assert_eq!(
        crate::process_journal::summary(&f.node.db.lock(), &f.current)
            .unwrap()
            .launches,
        0
    );
    assert_eq!(
        serde_json::to_value(journal::summary(&f.node.db.lock(), &f.current).unwrap()).unwrap()["launches"],
        0
    );
    f.node.close().await;
}

#[tokio::test]
async fn an_agent_and_multiple_work_terminals_keep_independent_epoch_slots_and_scopes() {
    let f = Fixture::new(true).await;
    crate::process_journal::reserve_with_guard(
        &f.node.db.lock(),
        &f.session,
        "repo",
        0,
        &f.node.incarnation,
        true,
    )
    .unwrap();
    let (a, b) = tokio::join!(f.open(), f.open());
    let a = a.unwrap().unwrap();
    let b = b.unwrap().unwrap();
    assert_ne!(a.id, b.id);
    until(|| f.report.exists() && f.report.with_extension("1").exists()).await;
    assert_eq!(f.node.terminals.list(&f.session).len(), 2);
    assert_eq!(f.node.db.lock().query_row("SELECT count(DISTINCT identity_json) FROM sandbox_launches WHERE resource_kind='terminal' AND session_id=?1",[&f.session],|r|r.get::<_,i64>(0)).unwrap(),2);
    assert!(
        crate::process_journal::reserve_with_guard(
            &f.node.db.lock(),
            &f.session,
            "repo",
            0,
            &f.node.incarnation,
            true
        )
        .is_err()
    );
    let control = Arc::new(super::input::Control {
        client: "phone".into(),
        generation: f.generation,
        open: Arc::new(Mutex::new(true)),
        rejected: Arc::new(|e| panic!("peer input was rejected: {e:?}")),
    });
    let first = f.node.terminals.lookup(&f.session, &a.id).unwrap();
    let second = f.node.terminals.lookup(&f.session, &b.id).unwrap();
    f.node
        .terminals
        .input_controlled(&f.session, &a.id, "finish\n", control.clone())
        .unwrap();
    until(|| first.state().info.exited).await;
    assert!(
        !second.state().info.exited,
        "One terminal retired its peer's scope"
    );
    f.node
        .terminals
        .input_controlled(&f.session, &b.id, "finish\n", control)
        .unwrap();
    until(|| second.state().info.exited).await;
    let summary = crate::process_journal::summary(&f.node.db.lock(), &f.session).unwrap();
    assert_eq!(summary.launches, 3);
    assert_eq!(summary.terminated, 2);
    assert_eq!(summary.unresolved, 1);
    f.node.close().await;
}

#[tokio::test]
async fn owner_kernel_and_terminal_reservations_commit_together_before_spawn() {
    for table in ["terminal_io_owners", "sandbox_launches", "terminal_runs"] {
        let f = Fixture::new(true).await;
        f.node.db.lock().execute_batch(&format!("CREATE TRIGGER fail_reservation BEFORE INSERT ON {table} BEGIN SELECT RAISE(ABORT,'disk full'); END;")).unwrap();
        assert!(f.open().await.unwrap().is_err());
        assert_eq!(f.scope.spawned.load(Ordering::SeqCst), 0);
        assert!(!f.report.exists());
        {
            let db = f.node.db.lock();
            for table in ["terminal_io_owners", "sandbox_launches", "terminal_runs"] {
                assert_eq!(
                    db.query_row(&format!("SELECT count(*) FROM {table}"), [], |r| r
                        .get::<_, i64>(0))
                        .unwrap(),
                    0
                );
            }
        }
        f.node.close().await;
    }
}
