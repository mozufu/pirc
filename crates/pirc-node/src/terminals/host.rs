//! Human-only, exact-review host terminal admission. The review is consumed with
//! the durable launch reservation. Query/retry never spawns an accepted run again.
use super::*;
use crate::{
    router::Response,
    services::Node,
    util::{now_ms, payload_hash, prefix_uuid},
};
use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Value, json};

pub(super) struct Grant {
    id: String,
    owner: String,
    request: String,
    hash: String,
    client: String,
    generation: i64,
}
pub(super) struct Review {
    id: String,
    request: String,
    error: Option<String>,
    pub(super) acknowledged: Option<i64>,
    incarnation: String,
    hash: String,
    details: Value,
    expires: i64,
    run: Option<String>,
    terminal: Option<String>,
}
fn required() -> ApiError {
    ApiError::new(
        409,
        "host_terminal_review_required",
        "Host management needs a current, explicitly confirmed Node review of this terminal and environment",
    )
}
fn text<'a>(body: &'a Value, key: &str) -> ApiResult<&'a str> {
    body.get(key)
        .and_then(Value::as_str)
        .filter(|s| {
            !s.is_empty()
                && s.len() <= 128
                && s.bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"_-".contains(&b))
        })
        .ok_or_else(ApiError::invalid_input)
}
pub(super) fn load(
    db: &Connection,
    owner: &str,
    session: &str,
    request: &str,
) -> ApiResult<Option<Review>> {
    db.query_row("SELECT id,incarnation,intent_hash,review_json,expires_at,run_id,terminal_id,error_code,acknowledged_at FROM terminal_host_requests WHERE owner_user=?1 AND session_id=?2 AND request_id=?3",params![owner,session,request],|r| {
        let json: String=r.get(3)?;
        Ok((r.get(0)?,r.get(1)?,r.get(2)?,json,r.get(4)?,r.get(5)?,r.get(6)?,r.get(7)?,r.get(8)?))
    }).optional()?.map(|(id,incarnation,hash,json,expires,run,terminal,error,acknowledged)| {
        Ok(Review{id,request:request.into(),error,acknowledged,incarnation,hash,details:serde_json::from_str(&json).map_err(|_|ApiError::internal())?,expires,run,terminal})
    }).transpose()
}
/// Stored digest includes private binding/mode/control inputs; only the minimal
/// human review is returned to clients. No credential or private session path.
fn capture(
    node: &Node,
    db: &Connection,
    session: &str,
    cwd: &Path,
    grant: &Grant,
    size: (u16, u16),
) -> ApiResult<(String, Value)> {
    db.claim_session(session, &grant.owner, false)?;
    db.validate_lease(session, &grant.client, grant.generation)?;
    crate::execution_fences::require_open(db, session)?;
    Binding::capture(node, db, session, cwd)?;
    let row = db.get_session(session)?;
    let workspace = db.get_workspace(&row.workspace_id)?;
    let mode = node.workspace_mode(&workspace)?;
    let shell = default_shell(node.config.terminal_shell.as_deref(), node.env.get("SHELL"));
    let details = json!({"version":1,"executionPath":"host_management","workspaceId":workspace.id,"cwd":cwd,"shell":shell,"cols":size.0,"rows":size.1,"runnerEpoch":row.runner_epoch,
        "warning":"Runs with the Node account's host permissions. Detached jobs and external effects may survive closing this terminal and keep workspace switching blocked."});
    let hash = payload_hash(
        &json!({"review":details,"owner":grant.owner,"session":session,"request":grant.request,"incarnation":node.incarnation,"workspacePath":workspace.canonical_path,"sessionPath":row.private_session_path,"mode":mode,"client":grant.client,"generation":grant.generation}),
    );
    Ok((hash, details))
}
pub(super) fn response(node: &Node, db: &Connection, review: &Review) -> ApiResult<Value> {
    let terminal = review
        .terminal
        .as_ref()
        .and_then(|id| node.terminals.registry().terminals.get(id).cloned())
        .filter(|entry| entry.record.as_ref().map(|r| &r.0) == review.run.as_ref())
        .map(|entry| entry.state().info.clone());
    let state = if let Some(run) = &review.run {
        let saved: String =
            db.query_row("SELECT state FROM terminal_runs WHERE id=?1", [run], |r| {
                r.get(0)
            })?;
        match saved.as_str() {
            "launching" | "running"
                if terminal.is_none() || review.incarnation != node.incarnation =>
            {
                "outcome_unknown".to_owned()
            }
            _ => saved,
        }
    } else if review.incarnation != node.incarnation {
        "stale".into()
    } else if review.expires <= now_ms() {
        "expired".into()
    } else {
        "review".into()
    };
    Ok(
        json!({"hostManagement":{"version":1,"requestId":review.request,"id":review.id,"reviewHash":review.hash,"review":review.details,"expiresAt":review.expires,"state":state,"errorCode":review.error,"terminalId":review.terminal,"acknowledgedAt":review.acknowledged},"terminal":terminal}),
    )
}
pub(crate) fn status(node: &Node, owner: &str, session: &str, request: &str) -> ApiResult<Value> {
    text(&json!({"requestId":request}), "requestId")?;
    let db = node.db.lock();
    db.claim_session(session, owner, false)?;
    let review = load(&db, owner, session, request)?.ok_or_else(super::requests::not_found)?;
    response(node, &db, &review)
}
fn insert(
    db: &Connection,
    node: &Node,
    grant: &Grant,
    session: &str,
    hash: &str,
    details: &Value,
    at: i64,
) -> ApiResult<()> {
    let id = prefix_uuid("host_terminal");
    let expires =
        at.saturating_add(i64::try_from(node.config.interaction_ttl_ms).unwrap_or(i64::MAX));
    db.execute(
        "INSERT INTO terminal_host_requests(id,owner_user,session_id,request_id,incarnation,intent_hash,review_json,created_at,expires_at) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9)",
        params![
            id,
            grant.owner,
            session,
            grant.request,
            node.incarnation,
            hash,
            details.to_string(),
            at,
            expires
        ],
    )?;
    Ok(())
}
/// Called only through authenticated human panel routes, never agent-side RPC.
pub(crate) fn handle(
    node: &Node,
    owner: &str,
    session: &str,
    cwd: &Path,
    body: &Value,
    control: (&str, i64),
    size: (Option<i64>, Option<i64>),
) -> ApiResult<Response> {
    let request = text(body, "requestId")?;
    let action = text(body, "action")?;
    let mut grant = Grant {
        id: String::new(),
        owner: owner.into(),
        request: request.into(),
        hash: String::new(),
        client: control.0.into(),
        generation: control.1,
    };
    let size = (
        clamp(size.0.map_or(80., |n| n as f64), 20, 500, 80),
        clamp(size.1.map_or(24., |n| n as f64), 5, 200, 24),
    );
    if action == "review" {
        let db = node.db.lock();
        let (hash, details) = capture(node, &db, session, cwd, &grant, size)?;
        if let Some(review) = load(&db, owner, session, request)? {
            if review.hash != hash {
                return Err(required());
            }
            return Ok(Response::json(response(node, &db, &review)?));
        }
        insert(&db, node, &grant, session, &hash, &details, now_ms())?;
        let review = load(&db, owner, session, request)?.ok_or_else(ApiError::internal)?;
        return Ok(Response::json(response(node, &db, &review)?));
    }
    if action != "confirm" || body.get("confirmed") != Some(&Value::Bool(true)) {
        return Err(required());
    }
    grant.id = text(body, "reviewId")?.into();
    grant.hash = text(body, "reviewHash")?.into();
    {
        let db = node.db.lock();
        db.validate_lease(session, control.0, control.1)?;
        let review = load(&db, owner, session, request)?.ok_or_else(required)?;
        if review.id != grant.id || review.hash != grant.hash {
            return Err(required());
        }
        if review.run.is_some() {
            return Ok(Response::json(response(node, &db, &review)?));
        }
    }
    let launched = node.terminals.create_selected(
        session,
        cwd,
        Some(i64::from(size.0)),
        Some(i64::from(size.1)),
        control,
        Some(grant),
    );
    if let Err(error) = launched {
        // Another confirmation may have consumed the review while this caller
        // waited for admission/quota. A failed spawn also keeps that same attempt.
        let db = node.db.lock();
        if let Some(review) = load(&db, owner, session, request)?
            && review.run.is_some()
        {
            return Ok(Response::json(response(node, &db, &review)?));
        }
        return Err(error);
    }
    Ok(Response::status(
        201,
        status(node, owner, session, request)?,
    ))
}
pub(super) fn consume(
    db: &Connection,
    node: &Node,
    grant: &Grant,
    terminal: &TerminalInfo,
    record: &journal::Record,
) -> ApiResult<()> {
    if db.is_autocommit() {
        return Err(ApiError::internal());
    }
    let review =
        load(db, &grant.owner, &terminal.session_id, &grant.request)?.ok_or_else(required)?;
    let (hash, _) = capture(
        node,
        db,
        &terminal.session_id,
        Path::new(&terminal.cwd),
        grant,
        (terminal.cols, terminal.rows),
    )?;
    if review.id != grant.id
        || review.hash != grant.hash
        || hash != review.hash
        || review.incarnation != node.incarnation
        || review.expires <= now_ms()
        || review.run.is_some()
    {
        return Err(required());
    }
    let n = db.execute(
        "UPDATE terminal_host_requests SET run_id=?2,terminal_id=?3 WHERE id=?1 AND run_id IS NULL",
        params![grant.id, record.0, terminal.id],
    )?;
    if n != 1 {
        return Err(required());
    }
    Ok(())
}

#[cfg(test)]
mod tests;
