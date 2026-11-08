//! Read-only revocation evaluation of a session's current binding generation
//! and the unresolved risks it inherits from earlier generations (C2).
//! It reports what retained evidence can prove after a transition drain. It
//! closes, settles or acknowledges nothing, and it is never a grant.
use crate::{error::ApiResult, services::Node, util::payload_hash};
use rusqlite::{Connection, OptionalExtension};
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
    /// The binding generation the evidence ran under; None for legacy rows.
    pub generation: Option<i64>,
    /// Retained from an earlier generation and not yet positively closed (C2).
    pub inherited: bool,
}

/// Settlement of the current generation alone, reported apart from the
/// cumulative revocation over every retained risk.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Current {
    pub status: &'static str,
    pub items_total: usize,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Evaluation {
    pub version: u8,
    /// Cumulative: `pending`, `blocked`, `unproven` or `confirmed`.
    pub status: &'static str,
    pub generation: i64,
    pub coverage: String,
    pub confirms_containment: bool,
    pub current_generation: Current,
    pub items: Vec<Item>,
    pub items_total: usize,
    /// SHA-256 over every sorted item; an acknowledgement binds to it.
    pub digest: String,
    /// The immutable snapshot this evaluation is stored as (C2), once drained.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub evaluation_id: Option<String>,
    /// Every item, for the stored snapshot; receipts show only the first page.
    #[serde(skip)]
    pub all_items: Vec<Item>,
}
/// Deterministic per (operation, digest): the same set is the same evaluation.
pub(crate) fn evaluation_id(digest: &str) -> String {
    format!("ev-{}", &digest[..32])
}
/// Store the snapshot once and return its identity. Never rewritten.
pub(crate) fn snapshot(
    db: &Connection,
    owner: &str,
    op: &str,
    evaluation: &Evaluation,
) -> ApiResult<String> {
    let id = evaluation_id(&evaluation.digest);
    db.execute(
        "INSERT OR IGNORE INTO revocation_evaluations VALUES(?1,?2,?3,?4,?5,?6,?7,?8)",
        rusqlite::params![
            owner,
            op,
            id,
            evaluation.digest,
            evaluation.status,
            evaluation.items_total as i64,
            serde_json::to_string(&evaluation.all_items)
                .map_err(|_| crate::error::ApiError::internal())?,
            crate::util::now_ms()
        ],
    )?;
    Ok(id)
}

struct Generation {
    number: i64,
    workspace: String,
    coverage: String,
    start_epoch: i64,
}

type Row = (String, String, String, Option<i64>);
fn rows(db: &Connection, sql: &str, session: &str) -> ApiResult<Vec<Row>> {
    Ok(db
        .prepare(sql)?
        .query_map([session], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))
        })?
        .collect::<Result<_, _>>()?)
}
fn status_of(fence_state: &str, items: &[Item]) -> &'static str {
    if matches!(fence_state, "fenced" | "stopping") {
        "pending"
    } else if fence_state == "blocked" || items.iter().any(|item| !item.acknowledgeable) {
        "blocked"
    } else if items.is_empty() {
        "confirmed"
    } else {
        "unproven"
    }
}

/// Evaluate the current generation plus every risk inherited from earlier
/// generations (C2). Evidence is attributed by its recorded generation, never
/// by time or workspace strings; a clean new generation cannot hide an earlier
/// unresolved or unprovable effect. `fence_state` is the transition fence's
/// retained state; a drain that has not finished is always `pending`.
pub(crate) fn evaluate(
    node: &Node,
    db: &Connection,
    session: &str,
    fence_state: &str,
) -> ApiResult<Evaluation> {
    let generations: Vec<Generation> = db
        .prepare("SELECT generation,workspace_id,coverage,start_epoch FROM session_binding_generations WHERE session_id=?1 ORDER BY generation")?
        .query_map([session], |r| {
            Ok(Generation {
                number: r.get(0)?,
                workspace: r.get(1)?,
                coverage: r.get(2)?,
                start_epoch: r.get(3)?,
            })
        })?
        .collect::<Result<_, _>>()?;
    let current_number = generations.last().map_or(0, |g| g.number);
    let item = |kind, id: String, reason, acknowledgeable, generation: Option<i64>| Item {
        kind,
        id,
        reason,
        acknowledgeable,
        generation,
        inherited: generation != Some(current_number),
    };
    let mut items = Vec::new();
    let session_row: Option<(String, i64)> = db
        .query_row(
            "SELECT workspace_id,runner_epoch FROM sessions WHERE id=?1",
            [session],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()?;
    if generations.is_empty() {
        items.push(item(
            "unattributed",
            session.to_owned(),
            "no_binding_generation",
            true,
            None,
        ));
    }
    let workspace_of = |g: Option<i64>| {
        g.and_then(|g| generations.iter().find(|x| x.number == g))
            .map(|x| x.workspace.as_str())
    };
    if let (Some((workspace, _)), Some(current)) = (&session_row, generations.last())
        && *workspace != current.workspace
    {
        items.push(item(
            "unattributed",
            session.to_owned(),
            "binding_changed_without_generation",
            true,
            Some(current.number),
        ));
    }
    for g in &generations {
        if g.coverage == "legacy" {
            items.push(item(
                "legacy_history",
                format!("generation:{}", g.number),
                "launches_before_journals",
                true,
                Some(g.number),
            ));
        }
    }
    // A row whose workspace is not its generation's cannot be attributed.
    let foreign = |workspace: &str, g: Option<i64>| {
        g.is_some() && workspace_of(g).is_some_and(|w| w != workspace)
    };
    let confirms_containment = node.sandbox.contains_descendants();
    // Agent and isolated-terminal kernel scopes. Without kernel containment a
    // launch has no scope to observe: after the drain stopped its runner, its
    // descendants are unprovable (acknowledgeable), not merely unresolved.
    for (id, workspace, state, g) in rows(
        db,
        "SELECT launch_id,workspace_id,state||CASE WHEN identity_json IS NULL THEN ':none' ELSE ':kernel' END,binding_generation FROM sandbox_launches WHERE session_id=?1",
        session,
    )? {
        let (state, scope) = state.split_once(':').unwrap_or((state.as_str(), "none"));
        match state {
            "launching" | "running" | "unconfirmed" if !confirms_containment && scope == "none" => {
                items.push(item("sandbox_launch", id, "uncontained_launch", true, g))
            }
            "launching" | "running" | "unconfirmed" => {
                items.push(item("sandbox_launch", id, "unresolved", false, g))
            }
            "legacy_untracked" => {
                items.push(item("legacy_history", id, "untracked_launch", true, g))
            }
            _ if g.is_none() => {}
            _ if foreign(&workspace, g) => {
                items.push(item("unattributed", id, "other_workspace", true, g))
            }
            _ => {}
        }
    }
    // Approved host commands run outside the sandbox: never positively closed.
    for (id, workspace, state, g) in rows(
        db,
        "SELECT id,workspace_id,state,binding_generation FROM host_command_runs WHERE session_id=?1",
        session,
    )? {
        match state.as_str() {
            "not_started" => {}
            "launching" | "running" => items.push(item("host_command", id, "unresolved", false, g)),
            _ if foreign(&workspace, g) => {
                items.push(item("unattributed", id, "other_workspace", true, g))
            }
            _ => items.push(item(
                "host_command",
                id,
                "host_effects_may_survive",
                true,
                g,
            )),
        }
    }
    // Terminals: a kernel-scoped run settles through its scope; any other run
    // (host management or the compatibility path) is a host shell.
    for (id, workspace, state, g) in rows(
        db,
        "SELECT t.id,t.workspace_id,t.state||CASE WHEN EXISTS(SELECT 1 FROM sandbox_launches l WHERE l.launch_id=t.id AND l.resource_kind='terminal') THEN ':scoped' ELSE ':host' END,t.binding_generation FROM terminal_runs t WHERE t.session_id=?1",
        session,
    )? {
        let (state, scope) = state.split_once(':').unwrap_or((state.as_str(), "host"));
        match (state, scope) {
            ("not_started", _) => {}
            ("launching" | "running", _) | ("unconfirmed", "scoped") => {
                items.push(item("terminal", id, "unresolved", false, g))
            }
            _ if foreign(&workspace, g) => {
                items.push(item("unattributed", id, "other_workspace", true, g))
            }
            (_, "scoped") => {}
            _ => items.push(item(
                "host_terminal",
                id,
                "host_effects_may_survive",
                true,
                g,
            )),
        }
    }
    for (id, _, state, g) in rows(
        db,
        "SELECT id,workspace_id,state,binding_generation FROM browser_groups WHERE session_id=?1",
        session,
    )? {
        if state != "settled" {
            items.push(item("browser", id, "unresolved", false, g));
        }
    }
    if let Some(scopes) = node.sandbox.network_scopes() {
        let proxy = scopes.summary(session);
        if proxy.active > 0 || proxy.pending > 0 {
            items.push(item(
                "native_proxy",
                session.to_owned(),
                "unresolved",
                false,
                Some(current_number),
            ));
        }
    }
    // An Agent that ran without containment in any generation leaves
    // unprovable descendants; each generation's run is its own retained risk.
    if !confirms_containment {
        let epoch = session_row.as_ref().map_or(0, |(_, e)| *e);
        for (i, g) in generations.iter().enumerate() {
            // Installation advanced the epoch once before the next generation.
            let end = generations
                .get(i + 1)
                .map_or(epoch, |next| next.start_epoch - 1);
            if end > g.start_epoch {
                items.push(item(
                    "platform_containment",
                    format!("generation:{}", g.number),
                    "descendants_not_contained",
                    true,
                    Some(g.number),
                ));
            }
        }
    }
    items.sort();
    items.dedup();
    let status = status_of(fence_state, &items);
    let own: Vec<Item> = items.iter().filter(|i| !i.inherited).cloned().collect();
    let current_generation = Current {
        status: status_of(fence_state, &own),
        items_total: own.len(),
    };
    let digest = payload_hash(&json!({"version":2,"generation":current_number,"items":items}));
    let items_total = items.len();
    let all_items = items.clone();
    items.truncate(SHOWN);
    Ok(Evaluation {
        version: 2,
        status,
        generation: current_number,
        coverage: generations
            .last()
            .map_or_else(|| "legacy".to_owned(), |g| g.coverage.clone()),
        confirms_containment,
        current_generation,
        items,
        items_total,
        digest,
        evaluation_id: None,
        all_items,
    })
}

#[cfg(test)]
mod tests;
