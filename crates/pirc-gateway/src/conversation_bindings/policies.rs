//! Durable configured policy, deliberately separate from Node enforcement.
use std::collections::BTreeSet;

use axum::{
    Extension, Json,
    extract::{Path, State},
};
use pirc_config::modes::ModeCatalog;
use pirc_protocol::Mode;
use rusqlite::{Connection, OptionalExtension, params};
use serde::Serialize;

use super::Binding;
use crate::{
    app::AppState,
    auth::Identity,
    db::{Capabilities, Store, atomic},
    error::{ApiError, ApiResult},
};

/// Catalog installation and membership resolution commit together. An invalid
/// reload or a failed write leaves both the prior definitions and versions intact.
pub fn install_catalog(conn: &Connection, catalog: &ModeCatalog) -> ApiResult<()> {
    for (id, mode) in &catalog.modes {
        mode.validate().map_err(|_| ApiError::internal())?;
        if id != &mode.id {
            return Err(ApiError::internal());
        }
    }
    atomic(conn, |tx| {
        let mut ids = tx
            .prepare("SELECT mode_id FROM current_mode_policies")?
            .query_map([], |r| r.get::<_, String>(0))?
            .collect::<Result<BTreeSet<_>, _>>()?;
        ids.extend(catalog.modes.keys().map(ToString::to_string));
        for id in ids {
            let desired = catalog
                .modes
                .iter()
                .find(|(key, _)| key.as_str() == id)
                .map(|(_, mode)| serde_json::to_string(mode).map_err(|_| ApiError::internal()))
                .transpose()?;
            let old: Option<(i64, Option<String>)> = tx
                .query_row(
                    "SELECT revision,mode_json FROM current_mode_policies WHERE mode_id=?",
                    [&id],
                    |r| Ok((r.get(0)?, r.get(1)?)),
                )
                .optional()?;
            if old.as_ref().map(|(_, json)| json) == Some(&desired) {
                continue;
            }
            tx.execute(
                "INSERT INTO mode_policy_versions VALUES(?,?,?)",
                params![id, old.map_or(1, |(revision, _)| revision + 1), desired],
            )?;
        }
        tx.execute(
            "UPDATE binding_catalog_state SET initialized=1 WHERE id=1",
            [],
        )?;
        tx.execute_batch(include_str!("reconcile_memberships.sql"))?;
        Ok(())
    })
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectMembership {
    pub revision: i64,
    pub workspace_id: Option<String>,
    /// `mode_unavailable` may retain the last known project; it grants nothing.
    pub resolution: String,
}

#[derive(Debug, Serialize)]
pub struct ModePolicy {
    pub revision: i64,
    pub definition: Option<Mode>,
}

#[derive(Debug, Serialize)]
pub struct WorkspacePolicy {
    pub revision: i64,
    pub capabilities: Capabilities,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Environment {
    version: u8,
    pub session_id: String,
    pub binding: Binding,
    pub project: ProjectMembership,
    pub mode_policy: Option<ModePolicy>,
    pub workspace_policy: WorkspacePolicy,
    /// Never label a configured version as installed or safe to execute. U4 must
    /// replace this boundary with an acknowledged effect fence before switching.
    enforcement: &'static str,
}

/// Read one coherent database snapshot even if another connection patches policy.
/// No Node connection or private session allocation is needed for this read.
pub fn environment(conn: &Connection, user: &str, id: &str) -> ApiResult<Environment> {
    atomic(conn, |tx| {
        let session = tx.claim_session(id, user, false)?;
        if !tx.checkpoint_workspace_visible_to_user(&session.workspace_id, user)? {
            return Err(ApiError::not_found("Workspace not found"));
        }
        let project = tx.query_row(
            "SELECT revision,project_workspace_id,resolution FROM conversation_project_memberships WHERE session_id=?",
            [id], |r| Ok(ProjectMembership { revision:r.get(0)?,workspace_id:r.get(1)?,resolution:r.get(2)? }),
        )?;
        let mode: Option<(i64, Option<String>)> = tx
            .query_row(
                "SELECT revision,mode_json FROM current_mode_policies WHERE mode_id=?",
                [&session.binding.execution.mode_id],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?;
        let mode_policy = mode
            .map(|(revision, json)| -> ApiResult<ModePolicy> {
                Ok(ModePolicy {
                    revision,
                    definition: json
                        .map(|j| serde_json::from_str(&j).map_err(|_| ApiError::internal()))
                        .transpose()?,
                })
            })
            .transpose()?;
        let (revision, json): (i64, String) = tx.query_row(
            "SELECT revision,policy_json FROM current_workspace_policies WHERE workspace_id=?",
            [&session.binding.execution.workspace_id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )?;
        Ok(Environment {
            version: 1,
            session_id: session.id,
            binding: session.binding,
            project,
            mode_policy,
            workspace_policy: WorkspacePolicy {
                revision,
                capabilities: serde_json::from_str(&json).map_err(|_| ApiError::internal())?,
            },
            enforcement: "not_tracked",
        })
    })
}

pub async fn get_environment(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(id): Path<String>,
) -> ApiResult<Json<serde_json::Value>> {
    let db = app.db.lock();
    crate::auth::require_current_device(&app, &db, &identity)?;
    let result = atomic(&db, |tx| {
        let mut result = serde_json::to_value(environment(tx, &identity.user, &id)?)
            .map_err(|_| ApiError::internal())?;
        result["activeTransition"] =
            serde_json::to_value(super::transitions::active(tx, &identity.user, &id)?)
                .map_err(|_| ApiError::internal())?;
        result["lastFinishedTransition"] =
            serde_json::to_value(super::transitions::last_finished(tx, &identity.user, &id)?)
                .map_err(|_| ApiError::internal())?;
        Ok(result)
    })?;
    Ok(Json(result))
}

#[cfg(test)]
mod tests;
