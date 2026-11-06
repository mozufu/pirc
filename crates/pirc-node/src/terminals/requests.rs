//! Durable work-terminal admission before asynchronous preparation. Only the first
//! submission schedules work; request loss, retries and restart only read facts.
use super::*;
use crate::{
    router::Response,
    services::Node,
    util::{now_ms, payload_hash},
};
use futures_util::FutureExt;
use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Value, json};
use std::panic::AssertUnwindSafe;

pub(super) struct Permit {
    owner: String,
    session: String,
    request: String,
    client: String,
    generation: i64,
    hash: String,
    cols: u16,
    rows: u16,
}
fn key(request: &str) -> ApiResult<()> {
    if request.is_empty()
        || request.len() > 128
        || !request
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"_-".contains(&b))
    {
        return Err(ApiError::invalid_input());
    }
    Ok(())
}
struct Saved {
    incarnation: String,
    hash: String,
    state: String,
    error: Option<String>,
    run: Option<String>,
    terminal: Option<String>,
}
fn saved(db: &Connection, owner: &str, session: &str, request: &str) -> ApiResult<Option<Saved>> {
    Ok(db.query_row("SELECT incarnation,intent_hash,state,error_code,run_id,terminal_id FROM terminal_work_requests WHERE owner_user=?1 AND session_id=?2 AND request_id=?3",params![owner,session,request],|r|Ok(Saved{incarnation:r.get(0)?,hash:r.get(1)?,state:r.get(2)?,error:r.get(3)?,run:r.get(4)?,terminal:r.get(5)?})).optional()?)
}
fn capture(
    node: &Node,
    db: &Connection,
    permit: &Permit,
    cwd: &Path,
) -> ApiResult<(String, String, i64)> {
    db.claim_session(&permit.session, &permit.owner, false)?;
    db.validate_lease(&permit.session, &permit.client, permit.generation)?;
    crate::execution_fences::require_open(db, &permit.session)?;
    Binding::capture(node, db, &permit.session, cwd)?;
    let row = db.get_session(&permit.session)?;
    let workspace = db.get_workspace(&row.workspace_id)?;
    let hash = payload_hash(
        &json!({"version":1,"path":"isolated_work","owner":permit.owner,"session":permit.session,"request":permit.request,"incarnation":node.incarnation,"workspace":workspace.id,"workspacePath":workspace.canonical_path,"cwd":cwd,"epoch":row.runner_epoch,"sessionPath":row.private_session_path,"mode":node.workspace_mode(&workspace)?,"shell":default_shell(node.config.terminal_shell.as_deref(),node.env.get("SHELL")),"client":permit.client,"generation":permit.generation,"cols":permit.cols,"rows":permit.rows}),
    );
    Ok((hash, workspace.id, row.runner_epoch))
}
fn reply(node: &Node, db: &Connection, request: &str, saved: Saved) -> ApiResult<Value> {
    let terminal = saved
        .terminal
        .as_ref()
        .and_then(|id| node.terminals.registry().terminals.get(id).cloned())
        .filter(|entry| entry.record.as_ref().map(|r| &r.0) == saved.run.as_ref())
        .map(|entry| entry.state().info.clone());
    let state = if let Some(run) = &saved.run {
        let state: String =
            db.query_row("SELECT state FROM terminal_runs WHERE id=?1", [run], |r| {
                r.get(0)
            })?;
        match state.as_str() {
            "running" | "launching"
                if terminal.is_none()
                    || saved.incarnation != node.incarnation
                    || saved.state == "outcome_unknown" =>
            {
                "outcome_unknown".into()
            }
            _ => state,
        }
    } else if saved.state != "accepted" {
        saved.state
    } else if saved.incarnation != node.incarnation {
        "outcome_unknown".into()
    } else {
        "preparing".into()
    };
    Ok(
        json!({"workRequest":{"version":1,"requestId":request,"state":state,"errorCode":saved.error,"terminalId":saved.terminal},"terminal":terminal}),
    )
}
pub(crate) fn status(node: &Node, owner: &str, session: &str, request: &str) -> ApiResult<Value> {
    key(request)?;
    let db = node.db.lock();
    db.claim_session(session, owner, false)?;
    let saved = saved(&db, owner, session, request)?
        .ok_or_else(|| ApiError::not_found("Work terminal request not found"))?;
    reply(node, &db, request, saved)
}
fn capacity(node: &Node, db: &Connection, session: &str) -> ApiResult<()> {
    // Use the existing terminal limits before detached async preparation too.
    // Admission holds the same DB mutex as linking a worker to its live entry.
    let (mut total,mut own):(usize,usize)=db.query_row("SELECT count(*),coalesce(sum(session_id=?2),0) FROM terminal_work_requests WHERE incarnation=?1 AND state='accepted' AND run_id IS NULL",params![node.incarnation,session],|r|Ok((r.get(0)?,r.get(1)?)))?;
    for entry in node.terminals.registry().terminals.values() {
        let state = entry.state();
        if !state.info.exited {
            total += 1;
            own += usize::from(state.info.session_id == session);
        }
    }
    if own >= PER_SESSION {
        return Err(ApiError::conflict(format!(
            "At most {PER_SESSION} terminals per session"
        )));
    }
    if total >= TOTAL {
        return Err(ApiError::conflict("Too many open or preparing terminals"));
    }
    Ok(())
}
pub(crate) async fn create(
    node: &Node,
    owner: &str,
    session: &str,
    cwd: &Path,
    request: &str,
    control: (&str, i64),
    size: (Option<i64>, Option<i64>),
) -> ApiResult<Response> {
    key(request)?;
    let mut permit = Permit {
        owner: owner.into(),
        session: session.into(),
        request: request.into(),
        client: control.0.into(),
        generation: control.1,
        hash: String::new(),
        cols: clamp(size.0.map_or(80., |n| n as f64), 20, 500, 80),
        rows: clamp(size.1.map_or(24., |n| n as f64), 5, 200, 24),
    };
    {
        let db = node.db.lock();
        let (hash, workspace, epoch) = capture(node, &db, &permit, cwd)?;
        if let Some(saved) = saved(&db, owner, session, request)? {
            if saved.hash != hash {
                return Err(ApiError::new(
                    409,
                    "work_terminal_request_conflict",
                    "This request belongs to a different terminal intent; query its original result",
                ));
            }
            return Ok(Response::json(reply(node, &db, request, saved)?));
        }
        capacity(node, &db, session)?;
        db.execute("INSERT INTO terminal_work_requests VALUES(?1,?2,?3,?4,?5,?6,?7,?8,'accepted',NULL,NULL,NULL,?9)",params![owner,session,request,node.incarnation,workspace,epoch,cwd.to_string_lossy(),hash,now_ms()])?;
        permit.hash = hash;
    }
    let node = node.clone();
    let cwd = cwd.to_owned();
    // Dropping the HTTP waiter does not cancel the one admitted worker.
    let task = tokio::spawn(async move {
        let owner = permit.owner.clone();
        let session = permit.session.clone();
        let request = permit.request.clone();
        let client = permit.client.clone();
        let generation = permit.generation;
        let cols = permit.cols;
        let rows = permit.rows;
        let result = AssertUnwindSafe(node.terminals.create_isolated_selected(
            &session,
            &cwd,
            Some(i64::from(cols)),
            Some(i64::from(rows)),
            (&client, generation),
            Some(permit),
        ))
        .catch_unwind()
        .await;
        match result {
            Ok(Ok(_)) => {}
            Ok(Err(error)) => {
                let db = node.db.lock();
                if !db.is_autocommit() {
                    return Err(ApiError::internal());
                }
                db.execute("UPDATE terminal_work_requests SET state='not_started',error_code=?4 WHERE owner_user=?1 AND session_id=?2 AND request_id=?3 AND state='accepted' AND run_id IS NULL",params![owner,session,request,error.code.as_ref()])?;
            }
            Err(_) => {
                let db = node.db.lock();
                if !db.is_autocommit() {
                    return Err(ApiError::internal());
                }
                db.execute("UPDATE terminal_work_requests SET state='outcome_unknown',error_code='terminal_start_unconfirmed' WHERE owner_user=?1 AND session_id=?2 AND request_id=?3 AND state='accepted'",params![owner,session,request])?;
            }
        }
        status(&node, &owner, &session, &request).map(|value| Response::status(201, value))
    });
    task.await.map_err(|_| ApiError::internal())?
}
pub(super) fn link(
    db: &Connection,
    node: &Node,
    permit: &Permit,
    terminal: &TerminalInfo,
    record: &journal::Record,
) -> ApiResult<()> {
    if db.is_autocommit() {
        return Err(ApiError::internal());
    }
    let (hash, _, _) = capture(node, db, permit, Path::new(&terminal.cwd))?;
    let row = saved(db, &permit.owner, &permit.session, &permit.request)?
        .ok_or_else(ApiError::internal)?;
    if permit.session != terminal.session_id
        || permit.hash != hash
        || row.hash != hash
        || row.incarnation != node.incarnation
        || row.state != "accepted"
        || row.run.is_some()
    {
        return Err(ApiError::conflict(
            "The work terminal request changed before reservation",
        ));
    }
    let n=db.execute("UPDATE terminal_work_requests SET run_id=?4,terminal_id=?5 WHERE owner_user=?1 AND session_id=?2 AND request_id=?3 AND state='accepted' AND run_id IS NULL",params![permit.owner,permit.session,permit.request,record.0,terminal.id])?;
    if n != 1 {
        return Err(ApiError::internal());
    }
    Ok(())
}

#[cfg(test)]
mod tests;
