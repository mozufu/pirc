//! Durable group observations, not OS-wide browser containment evidence.
use super::BrowserTarget;
use crate::{
    error::{ApiError, ApiResult},
    services::Node,
    util::{now_ms, uuid},
};
use rusqlite::{Connection, params};
use serde::Serialize;

pub(super) struct Record(pub String);
pub(crate) fn unresolved() -> ApiError {
    ApiError::new(
        503,
        "browser_stop_unconfirmed",
        "The browser has not been confirmed stopped; its session data is retained",
    )
}
impl Record {
    pub(super) fn reserve(node: &Node, db: &Connection, target: &BrowserTarget) -> ApiResult<Self> {
        if !db.is_autocommit() {
            return Err(ApiError::internal());
        }
        require_settled(db, &target.session_id, None)?;
        let id = uuid();
        let at = now_ms();
        db.execute(
            "INSERT INTO browser_groups(id,session_id,workspace_id,root,incarnation,state,created_at,updated_at) VALUES(?1,?2,?3,?4,?5,'active',?6,?6)",
            params![
                id,
                target.session_id,
                target.workspace_id,
                target.root.to_string_lossy(),
                node.incarnation,
                at
            ],
        )?;
        Ok(Self(id))
    }
    pub(super) fn finish(&self, db: &Connection, confirmed: bool) -> ApiResult<()> {
        let state = if confirmed { "settled" } else { "unconfirmed" };
        let changed = db.execute(
            "UPDATE browser_groups SET state=?2,updated_at=?3 WHERE id=?1 AND state='active'",
            params![self.0, state, now_ms()],
        )?;
        if changed != 1 {
            return Err(unresolved());
        }
        Ok(())
    }
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Summary {
    groups: u64,
    observers_settled: u64,
    unresolved: u64,
    history_complete: bool,
}
pub(crate) fn summary(db: &Connection, session: &str) -> ApiResult<Summary> {
    Ok(db.query_row("SELECT count(*),coalesce(sum(state='settled'),0),coalesce(sum(state!='settled'),0) FROM browser_groups WHERE session_id=?1",[session],|r|Ok(Summary{groups:r.get(0)?,observers_settled:r.get(1)?,unresolved:r.get(2)?,history_complete:false}))?)
}
pub(super) fn require_settled(
    db: &Connection,
    session: &str,
    current: Option<&str>,
) -> ApiResult<()> {
    let pending:bool=db.query_row("SELECT EXISTS(SELECT 1 FROM browser_groups WHERE session_id=?1 AND state!='settled' AND (?2 IS NULL OR id!=?2))",params![session,current],|r|r.get(0))?;
    if pending { Err(unresolved()) } else { Ok(()) }
}
