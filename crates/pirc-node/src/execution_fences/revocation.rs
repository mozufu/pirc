//! Read-only revocation evaluation of a session's current binding generation.
//! It reports what retained evidence can prove after a transition drain. It
//! closes, settles or acknowledges nothing, and it is never a grant.
use crate::{error::ApiResult, services::Node, util::payload_hash};
use rusqlite::{Connection, OptionalExtension, params};
use serde::Serialize;
use serde_json::json;

/// Items returned in a receipt; the digest still covers every item.
const SHOWN: usize = 100;

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Item {
    pub kind: &'static str,
    pub id: String,
    pub reason: &'static str,
    /// Whether an explicit user acknowledgement may accept this item.
    pub acknowledgeable: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Evaluation {
    pub version: u8,
    /// `pending`, `blocked`, `unproven` or `confirmed`.
    pub status: &'static str,
    pub generation: i64,
    pub coverage: String,
    pub confirms_containment: bool,
    pub items: Vec<Item>,
    pub items_total: usize,
    /// SHA-256 over every sorted item; an acknowledgement binds to it.
    pub digest: String,
}

struct Generation {
    number: i64,
    workspace: String,
    coverage: String,
    start_epoch: i64,
    started_at: i64,
}

fn rows(
    db: &Connection,
    sql: &str,
    session: &str,
    started_at: i64,
) -> ApiResult<Vec<(String, String, String)>> {
    Ok(db
        .prepare(sql)?
        .query_map(params![session, started_at], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?))
        })?
        .collect::<Result<_, _>>()?)
}

/// Evaluate the current generation. `fence_state` is the transition fence's
/// retained state; a drain that has not finished is always `pending`.
pub(crate) fn evaluate(
    node: &Node,
    db: &Connection,
    session: &str,
    fence_state: &str,
) -> ApiResult<Evaluation> {
    let mut items = Vec::new();
    let unprovable = |kind, id: String, reason| Item {
        kind,
        id,
        reason,
        acknowledgeable: true,
    };
    let unresolved = |kind, id: String| Item {
        kind,
        id,
        reason: "unresolved",
        acknowledgeable: false,
    };
    let current: Option<(String, i64)> = db
        .query_row(
            "SELECT workspace_id,runner_epoch FROM sessions WHERE id=?1",
            [session],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()?;
    let generation: Option<Generation> = db
        .query_row(
            "SELECT generation,workspace_id,coverage,start_epoch,started_at FROM session_binding_generations WHERE session_id=?1 ORDER BY generation DESC LIMIT 1",
            [session],
            |r| {
                Ok(Generation {
                    number: r.get(0)?,
                    workspace: r.get(1)?,
                    coverage: r.get(2)?,
                    start_epoch: r.get(3)?,
                    started_at: r.get(4)?,
                })
            },
        )
        .optional()?;
    let generation = match generation {
        Some(generation) => generation,
        None => {
            // No recorded binding: nothing can be attributed or proven.
            items.push(unprovable(
                "unattributed",
                session.to_owned(),
                "no_binding_generation",
            ));
            Generation {
                number: 0,
                workspace: String::new(),
                coverage: "legacy".into(),
                start_epoch: 0,
                started_at: 0,
            }
        }
    };
    if generation.coverage == "legacy" {
        items.push(unprovable(
            "legacy_history",
            session.to_owned(),
            "launches_before_journals",
        ));
    }
    if let Some((workspace, _)) = &current
        && generation.number > 0
        && *workspace != generation.workspace
    {
        items.push(unprovable(
            "unattributed",
            session.to_owned(),
            "binding_changed_without_generation",
        ));
    }
    let attributed = |workspace: &str| workspace == generation.workspace;
    let confirms_containment = node.sandbox.contains_descendants();
    // Agent and isolated-terminal kernel scopes. Without kernel containment a
    // launch has no scope to observe: after the drain stopped its runner, its
    // descendants are unprovable (acknowledgeable), not merely unresolved.
    for (id, workspace, state) in rows(
        db,
        "SELECT launch_id,workspace_id,state||CASE WHEN identity_json IS NULL THEN ':none' ELSE ':kernel' END FROM sandbox_launches WHERE session_id=?1 AND created_at>=?2",
        session,
        generation.started_at,
    )? {
        let (state, scope) = state.split_once(':').unwrap_or((state.as_str(), "none"));
        match state {
            "launching" | "running" | "unconfirmed" if !confirms_containment && scope == "none" => {
                items.push(unprovable("sandbox_launch", id, "uncontained_launch"))
            }
            "launching" | "running" | "unconfirmed" => items.push(unresolved("sandbox_launch", id)),
            "legacy_untracked" => items.push(unprovable("legacy_history", id, "untracked_launch")),
            _ if !attributed(&workspace) => {
                items.push(unprovable("unattributed", id, "other_workspace"))
            }
            _ => {}
        }
    }
    // Approved host commands run outside the sandbox.
    for (id, workspace, state) in rows(
        db,
        "SELECT id,workspace_id,state FROM host_command_runs WHERE session_id=?1 AND created_at>=?2",
        session,
        generation.started_at,
    )? {
        match state.as_str() {
            "not_started" => {}
            "launching" | "running" => items.push(unresolved("host_command", id)),
            _ if !attributed(&workspace) => {
                items.push(unprovable("unattributed", id, "other_workspace"))
            }
            _ => items.push(unprovable("host_command", id, "host_effects_may_survive")),
        }
    }
    // Terminals: a kernel-scoped run settles through its scope; any other run
    // (host management or the compatibility path) is a host shell.
    for (id, workspace, state) in rows(
        db,
        "SELECT t.id,t.workspace_id,t.state||CASE WHEN EXISTS(SELECT 1 FROM sandbox_launches l WHERE l.launch_id=t.id AND l.resource_kind='terminal') THEN ':scoped' ELSE ':host' END FROM terminal_runs t WHERE t.session_id=?1 AND t.created_at>=?2",
        session,
        generation.started_at,
    )? {
        let (state, scope) = state.split_once(':').unwrap_or((state.as_str(), "host"));
        match (state, scope) {
            ("not_started", _) => {}
            ("launching" | "running", _) | ("unconfirmed", "scoped") => {
                items.push(unresolved("terminal", id))
            }
            _ if !attributed(&workspace) => {
                items.push(unprovable("unattributed", id, "other_workspace"))
            }
            (_, "scoped") => {}
            _ => items.push(unprovable("host_terminal", id, "host_effects_may_survive")),
        }
    }
    for (id, _, state) in rows(
        db,
        "SELECT id,workspace_id,state FROM browser_groups WHERE session_id=?1 AND created_at>=?2",
        session,
        generation.started_at,
    )? {
        if state != "settled" {
            items.push(unresolved("browser", id));
        }
    }
    if let Some(scopes) = node.sandbox.network_scopes() {
        let proxy = scopes.summary(session);
        if proxy.active > 0 || proxy.pending > 0 {
            items.push(unresolved("native_proxy", session.to_owned()));
        }
    }
    let ran = current
        .as_ref()
        .is_some_and(|(_, epoch)| *epoch > generation.start_epoch);
    if !confirms_containment && ran {
        items.push(unprovable(
            "platform_containment",
            session.to_owned(),
            "descendants_not_contained",
        ));
    }
    items.sort();
    items.dedup();
    let status = if matches!(fence_state, "fenced" | "stopping") {
        "pending"
    } else if fence_state == "blocked" || items.iter().any(|item| !item.acknowledgeable) {
        "blocked"
    } else if items.is_empty() {
        "confirmed"
    } else {
        "unproven"
    };
    let digest = payload_hash(&json!({"version":1,"generation":generation.number,"items":items}));
    let items_total = items.len();
    items.truncate(SHOWN);
    Ok(Evaluation {
        version: 1,
        status,
        generation: generation.number,
        coverage: generation.coverage,
        confirms_containment,
        items,
        items_total,
        digest,
    })
}

#[cfg(test)]
mod tests;
