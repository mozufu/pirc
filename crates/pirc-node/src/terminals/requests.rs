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
use std::{panic::AssertUnwindSafe, time::Duration};

/// 2: unresolved-request listing, host/work result parity, required request
/// identity for isolated work and a bounded first reply. 3: acknowledgement of
/// unconfirmed starts and specific not-found/capacity error codes.
pub(crate) const VERSION: u8 = 3;
/// How long the first submission waits for its worker. It stays below the
/// Gateway relay timeout (30 s), so a slow preparation answers `202 preparing`
/// instead of an ambiguous relay timeout; the worker keeps running.
pub(crate) const REPLY_WAIT: Duration = Duration::from_secs(20);
/// Default and largest page of unresolved request results.
const PAGE: usize = 50;
const MAX_PAGE: usize = 100;

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
    acknowledged: Option<i64>,
}
/// A request ID this owner never submitted for the session (not a missing session).
pub(super) fn not_found() -> ApiError {
    ApiError::new(
        404,
        "terminal_request_not_found",
        "No terminal request with this ID was admitted for this session",
    )
}
/// Terminal quota, distinct from request conflicts.
pub(super) fn capacity_error(message: impl Into<String>) -> ApiError {
    ApiError::new(409, "terminal_capacity", message)
}
fn saved(db: &Connection, owner: &str, session: &str, request: &str) -> ApiResult<Option<Saved>> {
    Ok(db.query_row("SELECT incarnation,intent_hash,state,error_code,run_id,terminal_id,acknowledged_at FROM terminal_work_requests WHERE owner_user=?1 AND session_id=?2 AND request_id=?3",params![owner,session,request],|r|Ok(Saved{incarnation:r.get(0)?,hash:r.get(1)?,state:r.get(2)?,error:r.get(3)?,run:r.get(4)?,terminal:r.get(5)?,acknowledged:r.get(6)?})).optional()?)
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
        json!({"workRequest":{"version":1,"requestId":request,"state":state,"errorCode":saved.error,"terminalId":saved.terminal,"acknowledgedAt":saved.acknowledged},"terminal":terminal}),
    )
}
pub(crate) fn status(node: &Node, owner: &str, session: &str, request: &str) -> ApiResult<Value> {
    key(request)?;
    let db = node.db.lock();
    db.claim_session(session, owner, false)?;
    let saved = saved(&db, owner, session, request)?.ok_or_else(not_found)?;
    reply(node, &db, request, saved)
}
/// Hide an `outcome_unknown` request from discovery, once. This is a retained
/// user decision, not closure: the outcome, run and transition blocks stay.
pub(crate) fn acknowledge(
    node: &Node,
    owner: &str,
    session: &str,
    host: bool,
    request: &str,
    client: &str,
) -> ApiResult<Value> {
    key(request)?;
    let db = node.db.lock();
    db.claim_session(session, owner, false)?;
    let read = |db: &Connection| -> ApiResult<(Value, bool)> {
        if host {
            let review = super::host::load(db, owner, session, request)?.ok_or_else(not_found)?;
            let done = review.acknowledged.is_some();
            Ok((super::host::response(node, db, &review)?, done))
        } else {
            let row = saved(db, owner, session, request)?.ok_or_else(not_found)?;
            let done = row.acknowledged.is_some();
            Ok((reply(node, db, request, row)?, done))
        }
    };
    let (result, done) = read(&db)?;
    if done {
        return Ok(result);
    }
    let state = result["workRequest"]["state"]
        .as_str()
        .or_else(|| result["hostManagement"]["state"].as_str());
    if state != Some("outcome_unknown") {
        return Err(ApiError::new(
            409,
            "terminal_request_not_unknown",
            "Only a terminal request whose start is unconfirmed can be acknowledged",
        ));
    }
    let table = if host {
        "terminal_host_requests"
    } else {
        "terminal_work_requests"
    };
    let changed = db.execute(
        &format!("UPDATE {table} SET acknowledged_at=?4,acknowledged_by=?5 WHERE owner_user=?1 AND session_id=?2 AND request_id=?3 AND acknowledged_at IS NULL"),
        params![owner, session, request, now_ms(), client],
    )?;
    if changed != 1 {
        return Err(ApiError::internal());
    }
    Ok(read(&db)?.0)
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
        return Err(capacity_error(format!(
            "At most {PER_SESSION} terminals per session"
        )));
    }
    if total >= TOTAL {
        return Err(capacity_error("Too many open or preparing terminals"));
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
    create_waiting(
        node, owner, session, cwd, request, control, size, REPLY_WAIT,
    )
    .await
}
#[allow(clippy::too_many_arguments)]
pub(super) async fn create_waiting(
    node: &Node,
    owner: &str,
    session: &str,
    cwd: &Path,
    request: &str,
    control: (&str, i64),
    size: (Option<i64>, Option<i64>),
    wait: Duration,
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
        db.execute("INSERT INTO terminal_work_requests(owner_user,session_id,request_id,incarnation,workspace_id,runner_epoch,cwd,intent_hash,state,error_code,run_id,terminal_id,created_at) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,'accepted',NULL,NULL,NULL,?9)",params![owner,session,request,node.incarnation,workspace,epoch,cwd.to_string_lossy(),hash,now_ms()])?;
        permit.hash = hash;
    }
    let reader = node.clone();
    let (owner, session, request) = (owner.to_owned(), session.to_owned(), request.to_owned());
    let node = node.clone();
    let cwd = cwd.to_owned();
    // Dropping the HTTP waiter does not cancel the one admitted worker.
    let mut task = tokio::spawn(async move {
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
    match tokio::time::timeout(wait, &mut task).await {
        Ok(joined) => joined.map_err(|_| ApiError::internal())?,
        // Still preparing: the detached worker owns the outcome; clients query.
        Err(_) => status(&reader, &owner, &session, &request).map(|v| Response::status(202, v)),
    }
}
/// Record why a reserved terminal did not start, in its own transaction with
/// the `not_started` run outcome. Only the request linked to that run changes.
pub(super) fn start_failed(db: &Connection, run: &str, code: &str) -> ApiResult<()> {
    if db.is_autocommit() {
        return Err(ApiError::internal());
    }
    db.execute("UPDATE terminal_work_requests SET error_code=?2 WHERE run_id=?1 AND state='accepted' AND error_code IS NULL",params![run,code])?;
    db.execute(
        "UPDATE terminal_host_requests SET error_code=?2 WHERE run_id=?1 AND error_code IS NULL",
        params![run, code],
    )?;
    Ok(())
}
fn cursor(text: &str) -> ApiResult<(i64, String, String)> {
    let mut parts = text.splitn(3, '.');
    let (Some(at), Some(kind), Some(request)) = (parts.next(), parts.next(), parts.next()) else {
        return Err(ApiError::invalid_input());
    };
    let at = at.parse::<i64>().map_err(|_| ApiError::invalid_input())?;
    if !["host", "work"].contains(&kind) {
        return Err(ApiError::invalid_input());
    }
    key(request)?;
    Ok((at, kind.into(), request.into()))
}
/// One owner's work and host requests that still need a client decision:
/// `preparing`, `review` or `outcome_unknown`. Pages follow the raw keyset, so a
/// page may hold fewer items than the limit; continue while `next` is present.
pub(crate) fn unresolved(
    node: &Node,
    owner: &str,
    session: &str,
    after: Option<&str>,
    limit: Option<&str>,
) -> ApiResult<Value> {
    let after = after.map(cursor).transpose()?;
    let limit = match limit {
        None => PAGE,
        Some(text) => text
            .parse::<usize>()
            .ok()
            .filter(|n| (1..=MAX_PAGE).contains(n))
            .ok_or_else(ApiError::invalid_input)?,
    };
    let db = node.db.lock();
    db.claim_session(session, owner, false)?;
    let (at, kind, request) = after.unwrap_or((i64::MIN, String::new(), String::new()));
    let live = "SELECT id FROM terminal_runs WHERE state IN ('launching','running')";
    let rows: Vec<(i64, String, String)> = db
        .prepare(&format!("SELECT created_at,kind,request_id FROM (
             SELECT created_at,'host' kind,request_id FROM terminal_host_requests WHERE owner_user=?1 AND session_id=?2
              AND acknowledged_at IS NULL
              AND ((run_id IS NULL AND incarnation=?3 AND expires_at>?4) OR run_id IN ({live}))
             UNION ALL
             SELECT created_at,'work' kind,request_id FROM terminal_work_requests WHERE owner_user=?1 AND session_id=?2
              AND acknowledged_at IS NULL
              AND ((run_id IS NULL AND state!='not_started') OR run_id IN ({live})))
             WHERE (created_at,kind,request_id)>(?5,?6,?7) ORDER BY created_at,kind,request_id LIMIT ?8"))?
        .query_map(
            params![owner, session, node.incarnation, now_ms(), at, kind, request, limit as i64],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )?
        .collect::<Result<_, _>>()?;
    let mut items = Vec::new();
    for (_, kind, request) in &rows {
        let item = if kind == "work" {
            let row = saved(&db, owner, session, request)?.ok_or_else(ApiError::internal)?;
            reply(node, &db, request, row)?
        } else {
            let row =
                super::host::load(&db, owner, session, request)?.ok_or_else(ApiError::internal)?;
            super::host::response(node, &db, &row)?
        };
        let state = item["workRequest"]["state"]
            .as_str()
            .or_else(|| item["hostManagement"]["state"].as_str());
        if matches!(state, Some("preparing" | "review" | "outcome_unknown")) {
            items.push(item);
        }
    }
    let next = (rows.len() == limit)
        .then(|| {
            rows.last()
                .map(|(at, kind, request)| format!("{at}.{kind}.{request}"))
        })
        .flatten();
    Ok(json!({"terminalRequests":{"version":1,"items":items,"next":next}}))
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
