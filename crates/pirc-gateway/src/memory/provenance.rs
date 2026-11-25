//! Server-authored origins captured in the same transaction as a memory write.
//! These are not grants or inferred historical project ownership.
use crate::{
    conversation_bindings::policies,
    db::Version1,
    error::{ApiError, ApiResult},
};
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Snapshot {
    version: Version1,
    #[serde(flatten)]
    pub source: Source,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(
    tag = "kind",
    rename_all = "snake_case",
    rename_all_fields = "camelCase"
)]
pub enum Source {
    Unknown,
    User,
    Session {
        session_id: String,
        membership_revision: i64,
        project_workspace_id: Option<String>,
        membership_resolution: String,
        binding_generation: i64,
        execution_workspace_id: String,
        node_id: Option<String>,
        mode_id: String,
        mode_policy_revision: Option<i64>,
        workspace_policy_revision: i64,
    },
}

impl Snapshot {
    fn unknown() -> Self {
        Self {
            version: Version1,
            source: Source::Unknown,
        }
    }
}

pub fn from_session(conn: &Connection, user: &str, session_id: &str) -> ApiResult<Snapshot> {
    // Old imports/store fixtures may name a session that no longer exists. Do
    // not reassign it using sources_json, a project label or today's membership.
    let exists = conn
        .query_row(
            "SELECT 1 FROM sessions WHERE id=?",
            [session_id],
            |_| Ok(()),
        )
        .optional()?
        .is_some();
    if !exists {
        return Ok(Snapshot::unknown());
    }
    let state = policies::environment(conn, user, session_id)?;
    Ok(Snapshot {
        version: Version1,
        source: Source::Session {
            session_id: session_id.to_owned(),
            membership_revision: state.project.revision,
            project_workspace_id: state.project.workspace_id,
            membership_resolution: state.project.resolution,
            binding_generation: state.binding.execution.generation,
            execution_workspace_id: state.binding.execution.workspace_id,
            node_id: state.binding.execution.node_id,
            mode_id: state.binding.execution.mode_id,
            mode_policy_revision: state.mode_policy.map(|m| m.revision),
            workspace_policy_revision: state.workspace_policy.revision,
        },
    })
}

pub fn from_actor(conn: &Connection, user: &str, actor: &str) -> ApiResult<Snapshot> {
    if let Some(id) = actor.strip_prefix("session:") {
        return from_session(conn, user, id);
    }
    Ok(Snapshot {
        version: Version1,
        source: if actor == format!("user:{user}") {
            Source::User
        } else {
            Source::Unknown
        },
    })
}

pub(super) fn decode(value: Option<String>) -> ApiResult<Snapshot> {
    value
        .map(|json| serde_json::from_str(&json).map_err(|_| ApiError::internal()))
        .transpose()
        .map(|s| s.unwrap_or_else(Snapshot::unknown))
}

pub fn proposal(conn: &Connection, user: &str, id: &str) -> ApiResult<Snapshot> {
    let json=conn.query_row("SELECT c.origin_json FROM memory_proposals p LEFT JOIN memory_proposal_contexts c ON c.proposal_id=p.id WHERE p.id=? AND p.owner_user=?",[id,user],|r|r.get::<_,Option<String>>(0))?;
    decode(json)
}

pub fn version(
    conn: &Connection,
    user: &str,
    id: &str,
    revision: Option<i64>,
) -> ApiResult<Snapshot> {
    let json=conn.query_row("SELECT c.origin_json FROM memory_log l LEFT JOIN memory_version_contexts c ON c.log_seq=l.seq WHERE l.owner_user=? AND l.entry_id=? AND (? IS NULL OR l.revision=?) AND l.content IS NOT NULL ORDER BY l.seq DESC LIMIT 1",params![user,id,revision,revision],|r|r.get::<_,Option<String>>(0)).optional()?.flatten();
    decode(json)
}

pub fn record_proposal(conn: &Connection, id: &str, snapshot: &Snapshot) -> ApiResult<()> {
    conn.execute(
        "INSERT INTO memory_proposal_contexts VALUES(?,?)",
        params![
            id,
            serde_json::to_string(snapshot).map_err(|_| ApiError::internal())?
        ],
    )?;
    Ok(())
}
pub fn record_version(conn: &Connection, seq: i64, snapshot: &Snapshot) -> ApiResult<()> {
    conn.execute(
        "INSERT INTO memory_version_contexts VALUES(?,?)",
        params![
            seq,
            serde_json::to_string(snapshot).map_err(|_| ApiError::internal())?
        ],
    )?;
    Ok(())
}

#[cfg(test)]
mod tests;
