//! C6a per-conversation folder grants and deny. Grants feed the existing
//! session sandbox policy, so every backend that enforces that policy enforces
//! them. A change fences immediately: the runner and isolated terminals stop and
//! the next start uses the new policy. Host execution ignores the sandbox, so
//! it is refused while any deny is active.
use crate::{
    error::{ApiError, ApiResult},
    router::{Request, Response},
    services::Node,
    store::Store,
    util::{now_ms, prefix_uuid},
};
use rusqlite::{Connection, params};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Access {
    Read,
    Write,
    Deny,
}
impl Access {
    fn text(self) -> &'static str {
        match self {
            Access::Read => "read",
            Access::Write => "write",
            Access::Deny => "deny",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FolderGrant {
    pub grant_id: String,
    pub path: PathBuf,
    pub access: Access,
    pub created_at: i64,
}

/// The conversation's active grants, oldest first.
pub(crate) fn active(db: &Connection, session: &str) -> ApiResult<Vec<FolderGrant>> {
    Ok(db
        .prepare("SELECT grant_id,path,access,created_at FROM folder_grants WHERE session_id=?1 AND revoked_at IS NULL ORDER BY created_at,grant_id")?
        .query_map([session], |r| {
            let access: String = r.get(2)?;
            Ok(FolderGrant {
                grant_id: r.get(0)?,
                path: PathBuf::from(r.get::<_, String>(1)?),
                access: match access.as_str() {
                    "write" => Access::Write,
                    "deny" => Access::Deny,
                    _ => Access::Read,
                },
                created_at: r.get(3)?,
            })
        })?
        .collect::<Result<_, _>>()?)
}
/// Whether host execution must be refused: the host ignores sandbox denies.
pub(crate) fn has_deny(db: &Connection, session: &str) -> ApiResult<bool> {
    Ok(db.query_row(
        "SELECT EXISTS(SELECT 1 FROM folder_grants WHERE session_id=?1 AND access='deny' AND revoked_at IS NULL)",
        [session],
        |r| r.get(0),
    )?)
}
pub(crate) fn require_no_deny(db: &Connection, session: &str) -> ApiResult<()> {
    if has_deny(db, session)? {
        return Err(ApiError::new(
            409,
            "folder_deny_unenforceable_on_host",
            "Host execution cannot enforce this conversation's folder deny",
        ));
    }
    Ok(())
}
/// What each grant actually allows, with honest disclosures (C6).
pub(crate) fn effective(grants: &[FolderGrant]) -> Value {
    let denied_by = |path: &Path| {
        grants
            .iter()
            .find(|g| g.access == Access::Deny && path.starts_with(&g.path))
            .map(|g| g.grant_id.clone())
    };
    let entries: Vec<Value> = grants
        .iter()
        .map(|g| {
            let deny = if g.access == Access::Deny {
                None
            } else {
                denied_by(&g.path)
            };
            let writable_via = (g.access == Access::Read)
                .then(|| {
                    grants
                        .iter()
                        .find(|w| w.access == Access::Write && g.path.starts_with(&w.path))
                        .map(|w| w.grant_id.clone())
                })
                .flatten();
            json!({"grantId":g.grant_id,"path":g.path,"access":g.access.text(),
                "effective":if deny.is_some() {"deny"} else if writable_via.is_some() {"write"} else {g.access.text()},
                "deniedBy":deny,"writableVia":writable_via})
        })
        .collect();
    json!({"version":1,"grants":entries,
        "disclosures":["reads_outside_private_dirs_are_not_restricted"],
        "hostExecutionRefused":grants.iter().any(|g| g.access == Access::Deny)})
}

fn refused(status: u16, code: &'static str, message: &str) -> ApiError {
    ApiError::new(status, code, message)
}
fn canonical(path: &str) -> ApiResult<PathBuf> {
    let path = Path::new(path);
    if !path.is_absolute() {
        return Err(ApiError::invalid_input());
    }
    let real = std::fs::canonicalize(path)
        .map_err(|_| refused(404, "folder_not_found", "The folder does not exist"))?;
    if !real.is_dir() {
        return Err(refused(
            400,
            "folder_not_a_directory",
            "Only folders can be granted",
        ));
    }
    Ok(real)
}
fn session_and_lease(
    node: &Node,
    db: &Connection,
    request: &Request,
    body: &Value,
) -> ApiResult<crate::store::SessionRow> {
    let session = db.claim_session(
        request.param("id").unwrap_or_default(),
        &request.user,
        false,
    )?;
    let client = body["clientId"]
        .as_str()
        .ok_or_else(ApiError::invalid_input)?;
    let generation = body["generation"]
        .as_i64()
        .ok_or_else(ApiError::invalid_input)?;
    db.validate_lease(&session.id, client, generation)?;
    crate::execution_fences::require_open(db, &session.id)?;
    let _ = node;
    Ok(session)
}
/// New epoch: approvals and requests of the old policy stop being valid.
fn advance_epoch(db: &Connection, session: &str) -> ApiResult<()> {
    db.execute(
        "UPDATE sessions SET runner_epoch=runner_epoch+1,updated_at=?2 WHERE id=?1",
        params![session, now_ms()],
    )?;
    let epoch = db.get_session(session)?.runner_epoch;
    db.stale_epoch_interactions(session, epoch)?;
    Ok(())
}
/// Immediate fence (decision 3): stop the runner and live terminals so the
/// next start uses the new policy. Stopped work is not restarted.
async fn fence(node: &Node, session: &str) -> Value {
    let runner = node
        .runners
        .get(session)
        .is_some_and(|runner| runner.alive());
    let runner_stopped = if runner {
        node.runners.stop_session(session).await.is_ok()
    } else {
        false
    };
    let terminals = !node.terminals.list(session).is_empty();
    let terminals_stopped = if terminals {
        node.terminals.stop_live(session).await.is_ok()
    } else {
        false
    };
    json!({"runnerWasLive":runner,"runnerStopped":runner_stopped,
        "terminalsWereLive":terminals,"terminalsStopped":terminals_stopped,
        "confirmsContainment":node.sandbox.contains_descendants()})
}
fn reply(
    node: &Node,
    session: &str,
    grant: Option<Value>,
    fence: Option<Value>,
) -> ApiResult<Response> {
    let grants = active(&node.db.lock(), session)?;
    Ok(Response::json(
        json!({"grant":grant,"effectiveAccess":effective(&grants),"fence":fence}),
    ))
}

pub async fn list(node: Node, request: Request) -> ApiResult<Response> {
    let session = node
        .db
        .lock()
        .claim_session(
            request.param("id").unwrap_or_default(),
            &request.user,
            false,
        )?
        .id;
    let grants = active(&node.db.lock(), &session)?;
    Ok(Response::json(
        json!({"grantsEnabled":!node.config.grant_roots.is_empty(),
        "effectiveAccess":effective(&grants)}),
    ))
}

pub async fn create(node: Node, request: Request) -> ApiResult<Response> {
    let body = request.json().clone();
    let access = match body["access"].as_str() {
        Some("read") => Access::Read,
        Some("write") => Access::Write,
        Some("deny") => Access::Deny,
        _ => return Err(ApiError::invalid_input()),
    };
    if node.config.grant_roots.is_empty() {
        return Err(refused(
            409,
            "folder_grants_unavailable",
            "This Node has no grant roots",
        ));
    }
    let path = canonical(body["path"].as_str().ok_or_else(ApiError::invalid_input)?)?;
    let roots: Vec<PathBuf> = node
        .config
        .grant_roots
        .iter()
        .filter_map(|root| std::fs::canonicalize(root).ok())
        .collect();
    let private = [&node.config.state_dir, &node.config.sessions_dir]
        .into_iter()
        .filter_map(|dir| std::fs::canonicalize(dir).ok())
        .any(|dir| path.starts_with(&dir) || dir.starts_with(&path));
    if private {
        return Err(refused(
            403,
            "folder_private",
            "Node state cannot be granted",
        ));
    }
    let (session, grant) = {
        let db = node.db.lock();
        let session = session_and_lease(&node, &db, &request, &body)?;
        let grants = active(&db, &session.id)?;
        let under_root = roots.iter().any(|root| path.starts_with(root));
        let workspace = db.get_workspace(&session.workspace_id)?;
        let mode = node.workspace_mode(&workspace)?;
        let cwd = crate::chat::session_root(&workspace, &session.id, &mode)?;
        let inside_workspace = std::fs::canonicalize(&cwd).is_ok_and(|cwd| path.starts_with(cwd));
        let inside_grant = grants
            .iter()
            .any(|g| g.access != Access::Deny && path.starts_with(&g.path));
        let allowed = match access {
            Access::Deny => under_root || inside_workspace || inside_grant,
            _ => under_root,
        };
        if !allowed {
            return Err(refused(
                403,
                "folder_outside_grant_roots",
                "This folder is outside the Node's grant roots",
            ));
        }
        if let Some(existing) = grants.iter().find(|g| g.path == path && g.access == access) {
            drop(db);
            return reply(&node, &session.id, Some(json!(existing)), None);
        }
        let grant = FolderGrant {
            grant_id: prefix_uuid("grant"),
            path: path.clone(),
            access,
            created_at: now_ms(),
        };
        crate::store::atomic(&db, |tx| {
            tx.execute(
                "INSERT INTO folder_grants VALUES(?1,?2,?3,?4,?5,?6,NULL)",
                params![
                    grant.grant_id,
                    session.id,
                    path.to_string_lossy(),
                    access.text(),
                    body["clientId"].as_str().unwrap_or_default(),
                    grant.created_at
                ],
            )?;
            advance_epoch(tx, &session.id)
        })?;
        (session.id, grant)
    };
    let fence = fence(&node, &session).await;
    reply(&node, &session, Some(json!(grant)), Some(fence))
}

pub async fn revoke(node: Node, request: Request) -> ApiResult<Response> {
    let body = request.json().clone();
    let id = request.param("grant").unwrap_or_default().to_owned();
    let session = {
        let db = node.db.lock();
        let session = session_and_lease(&node, &db, &request, &body)?;
        let changed = crate::store::atomic(&db, |tx| {
            let n = tx.execute(
                "UPDATE folder_grants SET revoked_at=?3 WHERE grant_id=?1 AND session_id=?2 AND revoked_at IS NULL",
                params![id, session.id, now_ms()],
            )?;
            if n == 1 {
                advance_epoch(tx, &session.id)?;
            }
            Ok(n == 1)
        })?;
        if !changed {
            let known: bool = db.query_row(
                "SELECT EXISTS(SELECT 1 FROM folder_grants WHERE grant_id=?1 AND session_id=?2)",
                params![id, session.id],
                |r| r.get(0),
            )?;
            if !known {
                return Err(refused(404, "grant_not_found", "Grant not found"));
            }
            drop(db);
            return reply(&node, &session.id, None, None);
        }
        session.id
    };
    let fence = fence(&node, &session).await;
    reply(
        &node,
        &session,
        Some(json!({"grantId":id,"revoked":true})),
        Some(fence),
    )
}

#[cfg(test)]
mod tests;
