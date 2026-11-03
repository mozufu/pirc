//! Authority for workspace inspection, captured before any asynchronous wait.
//! Reading does not require the control lease. A captured environment cannot
//! follow a changed workspace or continue after its durable admission fence.
use crate::{
    error::{ApiError, ApiResult},
    services::Node,
    store::{SessionRow, Store, Workspace},
};
use std::future::Future;

#[derive(Clone)]
pub(super) struct Access {
    node: Node,
    owner: String,
    session: SessionRow,
    workspace: Workspace,
    mode: pirc_protocol::Mode,
}
impl Access {
    pub(super) fn new(
        node: Node,
        owner: String,
        session: SessionRow,
        workspace: Workspace,
        mode: pirc_protocol::Mode,
    ) -> Self {
        Self {
            node,
            owner,
            session,
            workspace,
            mode,
        }
    }
    pub(super) fn run<T>(&self, effect: impl FnOnce() -> ApiResult<T>) -> ApiResult<T> {
        let db = self.node.db.lock();
        if self.node.closing() {
            return Err(ApiError::runner_unavailable("Node is stopping"));
        }
        let current = db.claim_session(&self.session.id, &self.owner, false)?;
        crate::execution_fences::require_open(&db, &current.id)?;
        let workspace = db.get_workspace(&current.workspace_id)?;
        if current.workspace_id != self.session.workspace_id
            || current.runner_epoch != self.session.runner_epoch
            || current.private_session_path != self.session.private_session_path
            || workspace.canonical_path != self.workspace.canonical_path
            || workspace.host_id != self.workspace.host_id
            || workspace.mode != self.workspace.mode
            || self.node.workspace_mode(&workspace)? != self.mode
        {
            return Err(stale());
        }
        // Match the browser gate's DB -> catalog -> recovery lock order. These
        // locks cover bounded synchronous reads/spawn/publication, never await.
        let modes = self.node.modes.read().unwrap_or_else(|e| e.into_inner());
        let recovery = self
            .node
            .recovery_roots
            .read()
            .unwrap_or_else(|e| e.into_inner());
        let mut mode = modes.get(&workspace.mode).cloned().ok_or_else(stale)?;
        if recovery.contains_key(&workspace.id) {
            mode.workspace_memory = false;
        }
        if mode != self.mode {
            return Err(stale());
        }
        effect()
    }
    pub(super) async fn inspect<T>(
        &self,
        future: impl Future<Output = ApiResult<T>>,
    ) -> ApiResult<T> {
        self.run(|| Ok(()))?;
        let result = CURRENT.scope(self.clone(), future).await;
        // Also suppress stale error bodies, which can contain repository output.
        self.run(|| result)
    }
}
fn stale() -> ApiError {
    ApiError::new(
        409,
        "stale_environment",
        "The workspace changed; refresh the panel",
    )
}
tokio::task_local! { static CURRENT: Access; }
pub(super) fn run<T>(effect: impl FnOnce() -> ApiResult<T>) -> ApiResult<T> {
    match CURRENT.try_with(Clone::clone) {
        Ok(access) => access.run(effect),
        // Checkpoint inspection has its own admission/isolation scope. It does
        // not inherit a UI request or fabricate a viewer's authority.
        Err(_) => effect(),
    }
}
pub(super) fn check() -> ApiResult<()> {
    run(|| Ok(()))
}

#[cfg(test)]
mod tests;
