//! Native work terminals use the existing policy, terminal and kernel journals.
//! Source acceptance/Stop can fence startup; no keyboard bytes grant execution.
use super::*;
use crate::sandbox::{PrepareInput, Prepared, processes::State};
use std::{io::PipeWriter, path::PathBuf, process::ExitStatus};
use tokio::sync::oneshot;

pub(super) struct Work {
    pub request: Option<requests::Permit>,
    pub owner: crate::sandbox::processes::ObserverIdentity,
    pub prepared: Prepared,
    pub gate: Option<PipeWriter>,
    pub client: String,
    pub generation: i64,
    pub ready: oneshot::Sender<ApiResult<()>>,
}
impl Terminals {
    /// Opt-in path until client mode selection/default rollout is complete.
    /// Unsupported backends never run an unsandboxed replacement.
    pub async fn create_isolated(
        &self,
        session: &str,
        cwd: &Path,
        cols: Option<i64>,
        rows: Option<i64>,
        control: (&str, i64),
    ) -> ApiResult<TerminalInfo> {
        self.create_isolated_selected(session, cwd, cols, rows, control, None)
            .await
    }
    pub(super) async fn create_isolated_selected(
        &self,
        session: &str,
        cwd: &Path,
        cols: Option<i64>,
        rows: Option<i64>,
        control: (&str, i64),
        request: Option<requests::Permit>,
    ) -> ApiResult<TerminalInfo> {
        let node = self.node.upgrade().ok_or_else(ApiError::internal)?;
        let (workspace, row, mode) = {
            let db = node.db.lock();
            crate::execution_fences::require_open(&db, session)?;
            db.validate_lease(session, control.0, control.1)?;
            Binding::capture(&node, &db, session, cwd)?;
            let row = db.get_session(session)?;
            let workspace = db.get_workspace(&row.workspace_id)?;
            let mode = node.workspace_mode(&workspace)?;
            (workspace, row, mode)
        };
        if !node.sandbox.isolated_terminals() {
            return Err(ApiError::new(
                503,
                "isolated_terminal_unavailable",
                "This backend cannot launch a guarded isolated work terminal; no host command was started",
            ));
        }
        let owner = node.sandbox.terminal_io_owner().map_err(|_| {
            ApiError::new(
                503,
                "isolated_terminal_unavailable",
                "The terminal I/O owner could not be captured; no terminal was started",
            )
        })?;
        let shell = default_shell(node.config.terminal_shell.as_deref(), node.env.get("SHELL"));
        // C6a: read before the await; no database guard is held across it.
        let grants = crate::grants::active(&node.db.lock(), session)?;
        let prepared = node
            .sandbox
            .prepare_terminal(
                PrepareInput {
                    grants,
                    recovery: None,
                    session_id: session.into(),
                    workspace_root: cwd.into(),
                    session_dir: row.private_session_path.into(),
                    inference_socket: None,
                    protected_paths: crate::chat::project_instructions_path(&workspace, &mode)
                        .into_iter()
                        .collect(),
                    workspace_memory_file: None,
                    project_files_dir: crate::project_files::existing_files_dir(&workspace, &mode),
                },
                PathBuf::from(&shell),
            )
            .await?;
        let (ready, answered) = oneshot::channel();
        let mut env = pirc_config::env_allowlist::without_secrets(&node.env, &[]);
        env.insert("HOME".into(), node.env.home().display().to_string());
        let info = {
            let db = node.db.lock();
            db.validate_lease(session, control.0, control.1)?;
            crate::execution_fences::require_open(&db, session)?;
            let binding = Binding::capture(&node, &db, session, cwd)?;
            // An environment replacement during prepare must not inherit this plan.
            if db.get_session(session)?.workspace_id != workspace.id
                || db.get_workspace(&workspace.id)?.mode != workspace.mode
                || db.get_workspace(&workspace.id)?.canonical_path != workspace.canonical_path
                || node.workspace_mode(&workspace)? != mode
            {
                return Err(ApiError::conflict(
                    "The work terminal environment changed during preparation",
                ));
            }
            self.spawn(
                session,
                cwd,
                cols.map_or(80.0, |n| n as f64),
                rows.map_or(24.0, |n| n as f64),
                &shell,
                Environment {
                    host: None,
                    work: Some(Work {
                        request,
                        owner,
                        prepared,
                        gate: None,
                        client: control.0.into(),
                        generation: control.1,
                        ready,
                    }),
                    vars: env,
                    binding: Some(binding),
                    journal: Some((&node, &db)),
                },
            )?
        };
        answered.await.map_err(|_| journal::unresolved())??;
        Ok(info)
    }
}

async fn release(
    node: &WeakNode,
    entry: &Entry,
    work: &Work,
    launch: &crate::process_journal::Launch,
) -> ApiResult<()> {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(6);
    let mut stop = entry.stopping.subscribe();
    loop {
        let node = node.upgrade().ok_or_else(journal::unresolved)?;
        if node.closing() || *stop.borrow() {
            return Err(journal::unresolved());
        }
        let snapshot = work.prepared.process_snapshot();
        {
            let db = node.db.lock();
            let binding = entry.binding.as_ref().ok_or_else(ApiError::internal)?;
            binding.check(&node, &db, &launch.session)?;
            db.validate_lease(&launch.session, &work.client, work.generation)?;
            if snapshot.state != State::Observing {
                let workspace = db.get_workspace(&binding.workspace)?;
                let modes = node.modes.read().unwrap_or_else(|e| e.into_inner());
                if modes.get(&workspace.mode) != Some(&binding.mode) {
                    return Err(ApiError::conflict(
                        "The work terminal mode changed before launch permission",
                    ));
                }
                // Close/queued input and permission release share this entry lock.
                let state = entry.state();
                if state.closing || *stop.borrow() {
                    return Err(journal::unresolved());
                }
                crate::process_journal::authorize(&db, launch, &workspace.id, &snapshot)?;
                crate::sandbox::launch_guard::release(
                    work.gate.as_ref().ok_or_else(journal::unresolved)?,
                )
                .map_err(|_| journal::unresolved())?;
                return Ok(());
            }
        }
        if tokio::time::Instant::now() >= deadline {
            return Err(journal::unresolved());
        }
        drop(node);
        tokio::select! {
            _=async { let _=stop.wait_for(|v|*v).await; }=>return Err(journal::unresolved()),
            ()=tokio::time::sleep(Duration::from_millis(10))=>{},
        }
    }
}

pub(super) async fn observe(
    node: &WeakNode,
    entry: &Arc<Entry>,
    child: Box<dyn process_wrap::tokio::ChildWrapper>,
    mut work: Work,
    launch: crate::process_journal::Launch,
) -> ApiResult<ExitStatus> {
    let allowed = release(node, entry, &work, &launch).await;
    work.gate.take(); // EOF refuses an uncommitted launch, without consuming PTY input.
    if allowed.is_err() {
        if let Some(node) = node.upgrade() {
            let _ = crate::process_journal::deny(&node.db.lock(), &launch);
        }
        work.prepared.terminate_processes();
        let _state = entry.state();
        entry.stopping.send_replace(true);
    }
    let _ = work.ready.send(allowed);
    let mut stop = entry.stopping.subscribe();
    let observed = supervision::observe(child, entry.stopping.subscribe());
    tokio::pin!(observed);
    let result = tokio::select! {
        result=&mut observed=>result,
        _=async { let _=stop.wait_for(|v|*v).await; }=>{
            work.prepared.terminate_processes();
            observed.await
        }
    };
    work.prepared.terminate_processes();
    let state = work.prepared.wait_processes(KILL_GRACE).await;
    let has_identity = work.prepared.process_snapshot().identity.is_some();
    let saved = node
        .upgrade()
        .ok_or_else(journal::unresolved)
        .and_then(|node| {
            crate::process_journal::observe(
                &node.db.lock(),
                &launch,
                &work.prepared.process_snapshot(),
            )
        });
    work.prepared.cleanup();
    saved?;
    if state != State::Terminated || !has_identity {
        return Err(journal::unresolved());
    }
    result
}
