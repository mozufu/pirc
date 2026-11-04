//! Minimal durable observations. No replay or signaling from saved numeric PIDs.
use crate::{
    error::{ApiError, ApiResult},
    services::Node,
    util::{now_ms, uuid},
};
use rusqlite::{Connection, params};
use serde::Serialize;
use std::path::Path;

pub(super) struct Record(pub String);
pub(super) fn unresolved() -> ApiError {
    ApiError::new(
        503,
        "terminal_stop_unconfirmed",
        "A terminal has not been confirmed stopped; reconcile its session before continuing",
    )
}
impl Record {
    /// Both rows share the actual launch identity and commit before spawn.
    pub(super) fn scoped(
        node: &Node,
        db: &Connection,
        session: &str,
        workspace: &str,
        cwd: &Path,
        launch: &crate::process_journal::Launch,
    ) -> ApiResult<Self> {
        if db.is_autocommit() {
            return Err(ApiError::internal());
        }
        let at = now_ms();
        db.execute(
            "INSERT INTO terminal_runs VALUES(?1,?2,?3,?4,?5,'launching',?6,?6)",
            params![
                launch.id(),
                session,
                workspace,
                cwd.to_string_lossy(),
                node.incarnation,
                at
            ],
        )?;
        Ok(Self(launch.id().to_owned()))
    }

    pub(super) fn reserve(
        node: &Node,
        db: &Connection,
        session: &str,
        workspace: &str,
        cwd: &Path,
    ) -> ApiResult<Self> {
        if !db.is_autocommit() {
            return Err(ApiError::internal());
        }
        Self::insert(node, db, session, workspace, cwd)
    }
    pub(super) fn reserve_atomic(
        node: &Node,
        db: &Connection,
        session: &str,
        workspace: &str,
        cwd: &Path,
    ) -> ApiResult<Self> {
        if db.is_autocommit() {
            return Err(ApiError::internal());
        }
        Self::insert(node, db, session, workspace, cwd)
    }
    fn insert(
        node: &Node,
        db: &Connection,
        session: &str,
        workspace: &str,
        cwd: &Path,
    ) -> ApiResult<Self> {
        let id = uuid();
        let at = now_ms();
        db.execute(
            "INSERT INTO terminal_runs VALUES(?1,?2,?3,?4,?5,'launching',?6,?6)",
            params![
                id,
                session,
                workspace,
                cwd.to_string_lossy(),
                node.incarnation,
                at
            ],
        )?;
        Ok(Self(id))
    }
    pub(super) fn finish(&self, db: &Connection, state: &str) -> ApiResult<()> {
        let changed = db.execute("UPDATE terminal_runs SET state=?2,updated_at=?3 WHERE id=?1 AND state IN ('launching','running')",params![self.0,state,now_ms()])?;
        if changed != 1 {
            return Err(unresolved());
        }
        Ok(())
    }
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Summary {
    launches: u64,
    not_started: u64,
    observers_settled: u64,
    unresolved: u64,
    history_complete: bool,
}
pub(crate) fn summary(db: &Connection, session: &str) -> ApiResult<Summary> {
    Ok(db.query_row("SELECT count(*),coalesce(sum(state='not_started'),0),coalesce(sum(state='settled'),0),coalesce(sum(state NOT IN ('not_started','settled')),0) FROM terminal_runs WHERE session_id=?1",[session],|r|Ok(Summary{launches:r.get(0)?,not_started:r.get(1)?,observers_settled:r.get(2)?,unresolved:r.get(3)?,history_complete:false}))?)
}
pub(super) fn require_settled(db: &Connection, session: &str) -> ApiResult<()> {
    if summary(db, session)?.unresolved > 0 {
        Err(unresolved())
    } else {
        Ok(())
    }
}
