//! Durable sandbox launch evidence, not a complete environment revocation proof.
//! Reservation commits before spawn; only a failed spawn can be `not_started`.
//! Missing observations remain unresolved across Node restart and session deletion.
use crate::{
    error::{ApiError, ApiResult},
    sandbox::processes::{Identity, Snapshot, State},
    services::Node,
    store::Store,
    util::{now_ms, prefix_uuid},
};
use futures_util::{StreamExt, stream};
use rusqlite::{Connection, OptionalExtension, params};
use serde::Serialize;

#[cfg(test)]
mod tests;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Kind {
    Agent,
    Terminal,
}
impl Kind {
    fn text(self) -> &'static str {
        match self {
            Self::Agent => "agent",
            Self::Terminal => "terminal",
        }
    }
    fn parse(text: &str) -> ApiResult<Self> {
        match text {
            "agent" => Ok(Self::Agent),
            "terminal" => Ok(Self::Terminal),
            _ => Err(ApiError::internal()),
        }
    }
}
#[derive(Clone, Debug)]
pub(crate) struct Launch {
    kind: Kind,
    id: String,
    pub session: String,
    epoch: i64,
    incarnation: String,
}
impl Launch {
    pub(crate) fn id(&self) -> &str {
        &self.id
    }
}
#[derive(Clone, Default, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Summary {
    pub launches: u64,
    pub terminated: u64,
    pub not_started: u64,
    pub unresolved: u64,
    pub legacy_untracked: u64,
    pub guarded_not_released: u64,
}

#[cfg(test)]
pub(crate) fn reserve(
    db: &Connection,
    session: &str,
    workspace: &str,
    epoch: i64,
    incarnation: &str,
) -> ApiResult<Launch> {
    reserve_with_guard(db, session, workspace, epoch, incarnation, false)
}
pub(crate) fn reserve_with_guard(
    db: &Connection,
    session: &str,
    workspace: &str,
    epoch: i64,
    incarnation: &str,
    guarded: bool,
) -> ApiResult<Launch> {
    reserve_resource(
        db,
        session,
        workspace,
        epoch,
        incarnation,
        if guarded { Some(Kind::Agent) } else { None },
    )
}
/// Terminal attempts share the current agent epoch without reserving its slot.
pub(crate) fn reserve_terminal(
    db: &Connection,
    session: &str,
    workspace: &str,
    epoch: i64,
    incarnation: &str,
) -> ApiResult<Launch> {
    reserve_resource(
        db,
        session,
        workspace,
        epoch,
        incarnation,
        Some(Kind::Terminal),
    )
}
fn reserve_resource(
    db: &Connection,
    session: &str,
    workspace: &str,
    epoch: i64,
    incarnation: &str,
    guard: Option<Kind>,
) -> ApiResult<Launch> {
    let kind = guard.unwrap_or(Kind::Agent);
    db.require_session_available(session)?;
    crate::execution_fences::require_open(db, session)?;
    let current = db.get_session(session)?;
    if current.runner_epoch != epoch || current.workspace_id != workspace {
        return Err(ApiError::conflict("Sandbox launch environment changed"));
    }
    let launch = Launch {
        kind,
        id: prefix_uuid("launch_"),
        session: session.into(),
        epoch,
        incarnation: incarnation.into(),
    };
    let now = now_ms();
    db.execute(
        "INSERT INTO sandbox_launches(launch_id,session_id,workspace_id,runner_epoch,incarnation,state,identity_json,created_at,updated_at,guard_state,resource_kind) VALUES(?1,?2,?3,?4,?5,'launching',NULL,?6,?6,?7,?8)",
        params![launch.id, session, workspace, epoch, incarnation, now, if guard.is_some() {"waiting"} else {"untracked"},kind.text()],
    )?;
    Ok(launch)
}
fn saved(db: &Connection, launch: &Launch) -> ApiResult<(String, Option<String>)> {
    db.query_row("SELECT state,identity_json FROM sandbox_launches WHERE launch_id=?1 AND session_id=?2 AND runner_epoch=?3 AND incarnation=?4 AND resource_kind=?5",
        params![launch.id,launch.session,launch.epoch,launch.incarnation,launch.kind.text()], |r| Ok((r.get(0)?,r.get(1)?)))
        .optional()?.ok_or_else(ApiError::internal)
}
pub(crate) fn not_started(db: &Connection, launch: &Launch) -> ApiResult<()> {
    let (state, identity) = saved(db, launch)?;
    if state == "not_started" {
        return Ok(());
    }
    if state != "launching" || identity.is_some() {
        return Err(ApiError::internal());
    }
    db.execute(
        "UPDATE sandbox_launches SET state='not_started',updated_at=?2 WHERE launch_id=?1",
        params![launch.id, now_ms()],
    )?;
    Ok(())
}
pub(crate) fn observe(db: &Connection, launch: &Launch, snapshot: &Snapshot) -> ApiResult<()> {
    let (state, identity) = saved(db, launch)?;
    let next = snapshot
        .identity
        .as_ref()
        .map(serde_json::to_string)
        .transpose()
        .map_err(|_| ApiError::internal())?;
    if identity.is_some() && next.is_some() && identity != next {
        return Err(ApiError::conflict("Sandbox kernel identity changed"));
    }
    if matches!(
        state.as_str(),
        "terminated" | "not_started" | "legacy_untracked"
    ) {
        return Ok(());
    }
    let has_observed_identity = next.is_some();
    let next = identity.or(next);
    // Termination without a captured identity is not kernel evidence.
    let state = match (snapshot.state, has_observed_identity) {
        (State::Terminated, true) => "terminated",
        (State::Running, true) => "running",
        _ => "unconfirmed",
    };
    db.execute(
        "UPDATE sandbox_launches SET state=?2,identity_json=?3,updated_at=?4 WHERE launch_id=?1",
        params![launch.id, state, next, now_ms()],
    )?;
    Ok(())
}

/// Commit evidence before any release byte. The caller holds Node's admission
/// mutex through the subsequent nonblocking write on this launch's stdin pipe.
pub(crate) fn authorize(
    db: &Connection,
    launch: &Launch,
    workspace: &str,
    snapshot: &Snapshot,
) -> ApiResult<()> {
    if !db.is_autocommit() {
        return Err(ApiError::internal());
    }
    crate::store::atomic(db, |tx| {
        tx.require_session_available(&launch.session)?;
        crate::execution_fences::require_open(tx, &launch.session)?;
        let current = tx.get_session(&launch.session)?;
        if current.runner_epoch != launch.epoch || current.workspace_id != workspace {
            return Err(ApiError::conflict("Sandbox launch environment changed"));
        }
        if snapshot.state != State::Running || snapshot.identity.is_none() {
            return Err(ApiError::runner_unavailable(
                "Sandbox process identity was not confirmed",
            ));
        }
        observe(tx, launch, snapshot)?;
        let count=tx.execute("UPDATE sandbox_launches SET guard_state='released' WHERE launch_id=?1 AND guard_state='waiting' AND state='running'",[&launch.id])?;
        if count != 1 {
            return Err(ApiError::conflict(
                "Sandbox launch was already released or denied",
            ));
        }
        Ok(())
    })
}
pub(crate) fn deny(db: &Connection, launch: &Launch) -> ApiResult<()> {
    saved(db, launch)?;
    db.execute("UPDATE sandbox_launches SET guard_state='denied' WHERE launch_id=?1 AND guard_state='waiting'",[&launch.id])?;
    Ok(())
}

pub(crate) fn summary(db: &Connection, session: &str) -> ApiResult<Summary> {
    Ok(db.query_row("SELECT count(*),coalesce(sum(state='terminated'),0),coalesce(sum(state='not_started'),0),coalesce(sum(state NOT IN ('terminated','not_started')),0),coalesce(sum(state='legacy_untracked'),0),coalesce(sum(guard_state='denied'),0) FROM sandbox_launches WHERE session_id=?1",[session], |r| Ok(Summary {
        launches:r.get(0)?,terminated:r.get(1)?,not_started:r.get(2)?,unresolved:r.get(3)?,legacy_untracked:r.get(4)?,guarded_not_released:r.get(5)?,
    }))?)
}

/// Reconciliation is performed only within an accepted, durable transition fence.
/// Batch old launches so a very large history does not monopolize a drain. Missing
/// identities are deliberately left unresolved, never converted to successful exit.
#[cfg(test)]
fn pending(db: &Connection, session: &str) -> ApiResult<Vec<(Launch, Identity)>> {
    Ok(pending_page(db, session, 0, i64::MAX)?
        .into_iter()
        .filter_map(|(_, launch, identity)| identity.map(|identity| (launch, identity)))
        .collect())
}
fn pending_page(
    db: &Connection,
    session: &str,
    after: i64,
    ceiling: i64,
) -> ApiResult<Vec<(i64, Launch, Option<Identity>)>> {
    let fenced: bool = db.query_row(
        "SELECT EXISTS(SELECT 1 FROM execution_fences WHERE session_id=?1 AND state!='deleted')",
        [session],
        |r| r.get(0),
    )?;
    if !fenced {
        return Err(ApiError::conflict(
            "Sandbox reconciliation requires a transition fence",
        ));
    }
    // This transition prevents any future release. Missing identity still does
    // not prove kernel exit; expose the separate pre-execution denial evidence.
    db.execute("UPDATE sandbox_launches SET guard_state='denied' WHERE launch_id IN (SELECT launch_id FROM sandbox_launches WHERE session_id=?1 AND guard_state='waiting' ORDER BY created_at,rowid LIMIT 64)",[session])?;
    let mut statement = db.prepare("SELECT launch_id,runner_epoch,incarnation,identity_json,resource_kind,rowid FROM sandbox_launches WHERE session_id=?1 AND rowid>?2 AND rowid<=?3 AND state IN ('running','unconfirmed','launching') AND identity_json IS NOT NULL ORDER BY rowid LIMIT 64")?;
    let rows = statement.query_map(params![session, after, ceiling], |r| {
        Ok((
            r.get::<_, String>(0)?,
            r.get::<_, i64>(1)?,
            r.get::<_, String>(2)?,
            r.get::<_, String>(3)?,
            r.get::<_, String>(4)?,
            r.get::<_, i64>(5)?,
        ))
    })?;
    let mut out = Vec::new();
    for row in rows {
        let (id, epoch, incarnation, identity, kind, rowid) = row?;
        // Malformed evidence remains unresolved without starving later rows.
        let identity = serde_json::from_str(&identity).ok();
        out.push((
            rowid,
            Launch {
                kind: Kind::parse(&kind)?,
                id,
                session: session.into(),
                epoch,
                incarnation,
            },
            identity,
        ));
    }
    Ok(out)
}

pub(crate) async fn retire_saved(node: &Node, session: &str) -> ApiResult<()> {
    let ceiling = node.db.lock().query_row(
        "SELECT coalesce(max(rowid),0) FROM sandbox_launches WHERE session_id=?1",
        [session],
        |r| r.get::<_, i64>(0),
    )?;
    let mut after = 0;
    let mut malformed = false;
    loop {
        let rows = pending_page(&node.db.lock(), session, after, ceiling)?;
        let Some(last) = rows.last() else { break };
        after = last.0;
        malformed |= rows.iter().any(|(_, _, identity)| identity.is_none());
        let mut work = stream::iter(
            rows.into_iter()
                .filter_map(|(_, launch, identity)| identity.map(|identity| (launch, identity))),
        )
        .map(|(launch, identity)| async move {
            let state = crate::sandbox::linux::processes::retire_saved(&identity).await;
            (
                launch,
                Snapshot {
                    state,
                    identity: Some(identity),
                },
            )
        })
        .buffer_unordered(4);
        while let Some((launch, snapshot)) = work.next().await {
            observe(&node.db.lock(), &launch, &snapshot)?;
        }
        tokio::task::yield_now().await;
    }
    // Preserve failure for malformed evidence, after attempting later scopes.
    if malformed {
        Err(ApiError::internal())
    } else {
        Ok(())
    }
}
