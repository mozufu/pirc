//! Durable identity versions for the legacy workspace adapter. These are not
//! policy grants, runner epochs or device-control generations. Explicit project
//! membership and effect-fenced environment transitions build on this baseline.

use rusqlite::Row;
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Binding {
    version: u8,
    pub membership: Membership,
    pub execution: Execution,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Membership {
    pub revision: i64,
    /// Existing project/workspace association. Directory workspaces and the
    /// top-level chats workspace are not silently promoted to projects.
    pub legacy_workspace_id: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Execution {
    pub generation: i64,
    pub workspace_id: String,
    pub node_id: Option<String>,
    pub mode_id: String,
}

impl Binding {
    pub(crate) fn from_row(row: &Row<'_>) -> rusqlite::Result<Self> {
        Ok(Self {
            version: 1,
            membership: Membership {
                revision: row.get("membership_revision")?,
                legacy_workspace_id: row.get("legacy_workspace_id")?,
            },
            execution: Execution {
                generation: row.get("binding_generation")?,
                workspace_id: row.get("execution_workspace_id")?,
                node_id: row.get("binding_node_id")?,
                mode_id: row.get("binding_mode_id")?,
            },
        })
    }
}

pub mod commands;
pub mod policies;
pub mod transitions;

#[cfg(test)]
mod tests;
