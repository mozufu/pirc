//! Non-destructive Work workspace removal. The node keeps its directory,
//! history and registration; only explicit Add clears the durable gateway fence.

#[cfg(test)]
mod tests;

use axum::extract::{Extension, Path, State};
use pirc_protocol::HttpMethod;
use rusqlite::{Connection, OptionalExtension, params};

use crate::app::{App, AppState};
use crate::auth::Identity;
use crate::db::{Store, Workspace, atomic};
use crate::error::{ApiError, ApiResult};
use crate::http::no_content;
use crate::routes::Handled;
use crate::util::{new_id, now_ms};

/// Any pending or completed removal fences mutations immediately.
pub fn removed(conn: &Connection, id: &str) -> ApiResult<bool> {
    Ok(conn.query_row(
        "SELECT EXISTS(SELECT 1 FROM workspace_removals WHERE workspace_id=?)",
        [id],
        |row| row.get(0),
    )?)
}

/// Presentation changes only after the authoritative probe succeeds.
pub fn completed(conn: &Connection, id: &str) -> ApiResult<bool> {
    Ok(conn.query_row(
        "SELECT EXISTS(SELECT 1 FROM workspace_removals WHERE workspace_id=? AND status='removed')",
        [id],
        |row| row.get(0),
    )?)
}

pub fn restore(conn: &Connection, id: &str, user: &str) -> ApiResult<()> {
    let checking: bool = conn.query_row("SELECT EXISTS(SELECT 1 FROM workspace_removals WHERE workspace_id=? AND status='checking')", [id], |row| row.get(0))?;
    if checking {
        return Err(ApiError::new(
            409,
            "conflict",
            "Workspace removal is being checked; retry shortly",
        ));
    }
    let other: bool = conn.query_row(
        "SELECT EXISTS(SELECT 1 FROM workspace_removals WHERE workspace_id=? AND owner_user!=?)",
        params![id, user],
        |row| row.get(0),
    )?;
    if other {
        return Err(ApiError::new(
            403,
            "forbidden",
            "Workspace was removed by another user",
        ));
    }
    conn.execute("DELETE FROM workspace_removals WHERE workspace_id=?", [id])?;
    Ok(())
}

fn removable(app: &App, workspace: &Workspace) -> ApiResult<()> {
    if workspace.local_id().is_none()
        || app
            .mode(&workspace.mode)
            .is_some_and(|mode| mode.workdir != pirc_protocol::mode::Workdir::Workspace)
    {
        return Err(ApiError::new(
            400,
            "invalid_input",
            "Only repository workspaces can be removed",
        ));
    }
    Ok(())
}

fn begin(
    app: &App,
    conn: &Connection,
    id: &str,
    user: &str,
    online: bool,
) -> ApiResult<Option<(Workspace, String)>> {
    atomic(conn, |conn| {
        if !conn.checkpoint_workspace_visible_to_user(id, user)? {
            return Err(ApiError::not_found("Workspace not found"));
        }
        let workspace = conn
            .find_workspace(id)?
            .ok_or_else(|| ApiError::not_found("Workspace not found"))?;
        removable(app, &workspace)?;
        let other: bool = conn.query_row(
            "SELECT EXISTS(SELECT 1 FROM sessions WHERE workspace_id=?1 AND (owner_user IS NULL OR owner_user!=?2)) OR EXISTS(SELECT 1 FROM schedules WHERE workspace_id=?1 AND owner_user!=?2) OR EXISTS(SELECT 1 FROM workspace_removals WHERE workspace_id=?1 AND owner_user!=?2) OR EXISTS(SELECT 1 FROM conversation_submissions WHERE workspace_id=?1 AND owner_user!=?2 AND state='preparing')",
            params![id, user], |row| row.get(0))?;
        if other {
            return Err(ApiError::new(
                403,
                "forbidden",
                "Workspace contains another user's sessions, pending conversations or schedules",
            ));
        }
        let status: Option<String> = conn
            .query_row(
                "SELECT status FROM workspace_removals WHERE workspace_id=?",
                [id],
                |row| row.get(0),
            )
            .optional()?;
        match status.as_deref() {
            Some("removed") => return Ok(None),
            Some(_) => {
                return Err(ApiError::new(
                    409,
                    "conflict",
                    "Workspace removal is being checked; retry shortly",
                ));
            }
            None => {}
        }
        if !online {
            return Err(ApiError::new(
                503,
                "node_offline",
                "Connect the device to verify this workspace is idle before removing it",
            ));
        }
        let busy: bool = conn.query_row(
            "SELECT EXISTS(SELECT 1 FROM sessions WHERE workspace_id=?1 AND runner_state NOT IN ('stopped','failed','ready')) OR EXISTS(SELECT 1 FROM schedule_runs r JOIN schedules s ON s.id=r.schedule_id WHERE s.workspace_id=?1 AND r.status IN ('running','waiting_input')) OR EXISTS(SELECT 1 FROM commands c JOIN sessions s ON s.id=c.session_id WHERE s.workspace_id=?1 AND c.status IN ('received','dispatched'))",
            [id], |row| row.get(0))?;
        let live = conn.workspace_session_ids(id)?.iter().any(|session_id| {
            app.activity_of(Some(&workspace.host_id), session_id)
                .is_some_and(|activity| activity.run.is_some() || activity.write_lease)
        });
        if busy || live {
            return Err(ApiError::new(
                409,
                "conflict",
                "Stop active sessions before removing this workspace",
            ));
        }
        let token = new_id("removal");
        conn.execute(
            "INSERT INTO workspace_removals (workspace_id,owner_user,removed_at,status,token) VALUES (?,?,?,'checking',?)",
            params![id, user, now_ms(), token],
        )?;
        Ok(Some((workspace, token)))
    })
}

fn rollback(conn: &Connection, id: &str, token: &str) -> ApiResult<()> {
    conn.execute(
        "DELETE FROM workspace_removals WHERE workspace_id=? AND status='checking' AND token=?",
        params![id, token],
    )?;
    Ok(())
}

/// Cancellation must not strand a pending fence until the next gateway restart.
struct PendingRemoval {
    app: AppState,
    id: String,
    token: String,
    armed: bool,
}

impl Drop for PendingRemoval {
    fn drop(&mut self) {
        if self.armed
            && let Err(error) = rollback(&self.app.db.lock(), &self.id, &self.token)
        {
            crate::log::warn(&format!("Failed to roll back workspace removal: {error:?}"));
        }
        if self.armed {
            crate::schedules::arm(&self.app);
        }
    }
}

fn finish(conn: &Connection, id: &str, token: &str) -> ApiResult<()> {
    atomic(conn, |conn| {
        if conn.execute("UPDATE workspace_removals SET status='removed' WHERE workspace_id=? AND status='checking' AND token=?", params![id,token])? != 1 {
            return Err(ApiError::new(409, "conflict", "Workspace removal changed; retry"));
        }
        conn.execute("UPDATE schedules SET status='paused', next_run_at=NULL, updated_at=? WHERE workspace_id=? AND status='active'", params![now_ms(), id])?;
        Ok(())
    })
}

#[cfg(test)]
fn remove(app: &App, conn: &Connection, id: &str, user: &str) -> ApiResult<()> {
    if let Some((_, token)) = begin(app, conn, id, user, true)? {
        finish(conn, id, &token)?;
    }
    Ok(())
}

pub async fn delete(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(id): Path<String>,
) -> Handled {
    let online = {
        let conn = app.db.lock();
        conn.find_workspace(&id)?
            .is_some_and(|workspace| app.nodes.get(&workspace.host_id).is_some())
    };
    let pending = begin(&app, &app.db.lock(), &id, &identity.user, online)?;
    let Some((workspace, token)) = pending else {
        return Ok(no_content());
    };
    let mut guard = PendingRemoval {
        app: app.clone(),
        id: id.clone(),
        token: token.clone(),
        armed: true,
    };
    {
        let local_id = workspace.local_id().ok_or_else(ApiError::internal)?;
        let response = app
            .relay(
                &workspace.host_id,
                &identity,
                HttpMethod::Get,
                format!(
                    "/api/workspaces/{}/removal-check",
                    crate::routes::urlencoding_component(local_id)
                ),
                None,
            )
            .await;
        match response {
            Ok(response)
                if (200..300).contains(&response.status)
                    && response
                        .body
                        .as_ref()
                        .is_some_and(|body| body["idle"] == true) => {}
            Ok(response) => {
                return Err(ApiError::new(
                    match response.status { 403 => 403, 409 => 409, _ => 502 },
                    match response.status { 403 => "forbidden", 409 => "conflict", _ => "node_error" },
                    match response.status {
                        403 => "Workspace contains another user's sessions on the device",
                        404 => "Device does not support safe workspace removal; upgrade both gateway and node",
                        _ => "Device could not confirm this workspace is idle; stop active work and retry",
                    },
                )
                .into());
            }
            Err(error) => {
                return Err(error.into());
            }
        }
    }
    finish(&app.db.lock(), &id, &token)?;
    guard.armed = false;
    crate::schedules::arm(&app);
    app.directory_changed();
    app.sessions_changed(Some(&identity.user));
    app.schedules_changed(&identity.user);
    Ok(no_content())
}
