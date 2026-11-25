//! Pot activity (plans/pots.md, Activity and point of view): one row per thing a
//! pot did or that happened to it, written by the Gateway code that did it
//! through [`log`]. A row snapshots the pot's name and color, so it still reads
//! after the pot is deleted; the owner's retention removes old rows.

use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};

use crate::app::App;
use crate::error::{ApiError, ApiResult};
use crate::util::{new_id, now_ms};

/// The longest summary kept; longer ones are cut at a character boundary.
pub const MAX_SUMMARY: usize = 400;

// Kinds are written as their steps land (plans/roadmap.md M4 steps 5–10).
#[allow(dead_code)]
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Kind {
    Created,
    Updated,
    Paused,
    Resumed,
    Archived,
    Restored,
    Deleted,
    Dm,
    GroupMessage,
    Assign,
    WorkOpened,
    WorkInstruction,
    FileRead,
    ThinkingAdjust,
    Fallback,
    AutonomyChanged,
    ReminderSet,
    Review,
    HandoverProposed,
    AwaitingConfirm,
    AwaitingApproval,
    ApprovalAnswered,
    ForwardedToUser,
    BudgetRequest,
    BudgetExhausted,
    LoopGuard,
}

impl Kind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Created => "created",
            Self::Updated => "updated",
            Self::Paused => "paused",
            Self::Resumed => "resumed",
            Self::Archived => "archived",
            Self::Restored => "restored",
            Self::Deleted => "deleted",
            Self::Dm => "dm",
            Self::GroupMessage => "group_message",
            Self::Assign => "assign",
            Self::WorkOpened => "work_opened",
            Self::WorkInstruction => "work_instruction",
            Self::FileRead => "file_read",
            Self::ThinkingAdjust => "thinking_adjust",
            Self::Fallback => "fallback",
            Self::AutonomyChanged => "autonomy_changed",
            Self::ReminderSet => "reminder_set",
            Self::Review => "review",
            Self::HandoverProposed => "handover_proposed",
            Self::AwaitingConfirm => "awaiting_confirm",
            Self::AwaitingApproval => "awaiting_approval",
            Self::ApprovalAnswered => "approval_answered",
            Self::ForwardedToUser => "forwarded_to_user",
            Self::BudgetRequest => "budget_request",
            Self::BudgetExhausted => "budget_exhausted",
            Self::LoopGuard => "loop_guard",
        }
    }
}

/// Who or what the pot acted toward.
#[allow(dead_code)] // Work sessions and workspaces arrive with M4 steps 6b and 9.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", content = "id", rename_all = "snake_case")]
pub enum Counterpart {
    User,
    Pot(String),
    WorkSession(String),
    Workspace(String),
    System,
}

impl Counterpart {
    fn columns(&self) -> (&'static str, Option<&str>) {
        match self {
            Self::User => ("user", None),
            Self::Pot(id) => ("pot", Some(id)),
            Self::WorkSession(id) => ("work_session", Some(id)),
            Self::Workspace(id) => ("workspace", Some(id)),
            Self::System => ("system", None),
        }
    }
}

/// What an activity row points at; absent fields are left out.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Refs {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub thread: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub approval: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub handover: Option<String>,
    /// A budget request id, or the key of a logged exhaustion window.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub budget: Option<String>,
    /// A causal root (`plans/pots.md`, Budgets and the causal root).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub root: Option<String>,
}

/// One activity to record.
#[derive(Clone, Debug)]
pub struct Entry {
    pub kind: Kind,
    pub counterpart: Option<Counterpart>,
    /// Up to two short lines for the user; cut to [`MAX_SUMMARY`].
    pub summary: String,
    pub refs: Refs,
    pub causal_root: Option<String>,
}

impl Entry {
    pub fn new(kind: Kind, summary: impl Into<String>) -> Self {
        Self {
            kind,
            counterpart: None,
            summary: summary.into(),
            refs: Refs::default(),
            causal_root: None,
        }
    }

    pub fn toward(mut self, counterpart: Counterpart) -> Self {
        self.counterpart = Some(counterpart);
        self
    }

    pub fn refs(mut self, refs: Refs) -> Self {
        self.refs = refs;
        self
    }

    pub fn root(mut self, causal_root: Option<&str>) -> Self {
        self.causal_root = causal_root.map(str::to_owned);
        self
    }
}

fn clip(summary: &str) -> String {
    let summary = summary.trim();
    match summary.char_indices().nth(MAX_SUMMARY) {
        Some((cut, _)) => summary[..cut].to_owned(),
        None => summary.to_owned(),
    }
}

/// Record an activity of the owner's pot, inside the caller's transaction when
/// it has one. Returns the row's id. Callers that hold the app also call
/// [`App::activity_changed`] (or use [`App::log_activity`]).
pub fn log(conn: &Connection, owner: &str, pot_id: &str, entry: Entry) -> ApiResult<String> {
    let summary = clip(&entry.summary);
    if summary.is_empty() {
        return Err(ApiError::new(
            400,
            "invalid_input",
            "An activity needs a summary",
        ));
    }
    let (counterpart_kind, counterpart_id) = match &entry.counterpart {
        Some(counterpart) => {
            let (kind, id) = counterpart.columns();
            (Some(kind), id)
        }
        None => (None, None),
    };
    let id = new_id("act");
    let inserted = conn.execute(
        "INSERT INTO pot_activity(id,owner_user,pot_id,pot_name,pot_avatar_color,at,kind,
           counterpart_kind,counterpart_id,summary,refs_json,causal_root)
         SELECT ?1,?2,id,name,avatar_color,?4,?5,?6,?7,?8,?9,?10 FROM pots WHERE id=?3 AND owner_user=?2",
        params![
            id,
            owner,
            pot_id,
            now_ms(),
            entry.kind.as_str(),
            counterpart_kind,
            counterpart_id,
            summary,
            serde_json::to_string(&entry.refs).expect("refs serialize"),
            entry.causal_root,
        ],
    )?;
    if inserted != 1 {
        return Err(ApiError::not_found("Pot not found"));
    }
    Ok(id)
}

impl App {
    /// [`log`], then tell the owner's clients (`activity=1`).
    #[allow(dead_code)] // For writers outside a store transaction (M4 steps 6b–10).
    pub fn log_activity(&self, owner: &str, pot_id: &str, entry: Entry) -> ApiResult<String> {
        let id = log(&self.db.lock(), owner, pot_id, entry)?;
        self.activity_changed(owner);
        Ok(id)
    }
}

/// One activity row as clients see it.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Activity {
    pub id: String,
    /// `None` once the pot is deleted; the name and color remain.
    pub pot_id: Option<String>,
    pub pot_name: String,
    pub pot_avatar_color: u8,
    pub at: i64,
    pub kind: String,
    pub counterpart: Option<CounterpartView>,
    pub summary: String,
    pub refs: Refs,
    pub causal_root: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct CounterpartView {
    pub kind: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
}

/// Filters for [`list`]; every field narrows the result.
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Query {
    pub pot_id: Option<String>,
    /// Comma-separated kinds.
    pub kind: Option<String>,
    /// Inclusive lower bound, epoch ms.
    pub since: Option<i64>,
    /// Exclusive upper bound, epoch ms.
    pub until: Option<i64>,
    /// The last id of the previous page.
    pub before: Option<String>,
    pub limit: Option<u32>,
}

pub const PAGE: u32 = 50;
pub const MAX_PAGE: u32 = 200;

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Page {
    pub activity: Vec<Activity>,
    /// Pass as `before` for the next (older) page; absent on the last page.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub next_before: Option<String>,
}

const KINDS: &[&str] = &[
    "created",
    "updated",
    "paused",
    "resumed",
    "archived",
    "restored",
    "deleted",
    "dm",
    "group_message",
    "assign",
    "work_opened",
    "work_instruction",
    "file_read",
    "thinking_adjust",
    "fallback",
    "autonomy_changed",
    "reminder_set",
    "review",
    "handover_proposed",
    "awaiting_confirm",
    "awaiting_approval",
    "approval_answered",
    "forwarded_to_user",
    "budget_request",
    "budget_exhausted",
    "loop_guard",
];

fn invalid(message: &str) -> ApiError {
    ApiError::new(400, "invalid_input", message)
}

fn activity_row(r: &rusqlite::Row) -> rusqlite::Result<Activity> {
    let refs: String = r.get(9)?;
    let counterpart_kind: Option<String> = r.get(6)?;
    Ok(Activity {
        id: r.get(0)?,
        pot_id: r.get(1)?,
        pot_name: r.get(2)?,
        pot_avatar_color: r.get(3)?,
        at: r.get(4)?,
        kind: r.get(5)?,
        counterpart: counterpart_kind.map(|kind| CounterpartView {
            kind,
            id: r.get(7).ok().flatten(),
        }),
        summary: r.get(8)?,
        refs: serde_json::from_str(&refs).unwrap_or_default(),
        causal_root: r.get(10)?,
    })
}

/// The owner's activity, newest first.
pub fn list(conn: &Connection, owner: &str, query: &Query) -> ApiResult<Page> {
    let limit = query.limit.unwrap_or(PAGE);
    if !(1..=MAX_PAGE).contains(&limit) {
        return Err(invalid("limit is 1 to 200"));
    }
    let mut sql = String::from(
        "SELECT id,pot_id,pot_name,pot_avatar_color,at,kind,counterpart_kind,counterpart_id,summary,refs_json,causal_root
         FROM pot_activity WHERE owner_user=?",
    );
    let mut args: Vec<rusqlite::types::Value> = vec![owner.to_owned().into()];
    if let Some(pot) = &query.pot_id {
        sql.push_str(" AND pot_id=?");
        args.push(pot.clone().into());
    }
    if let Some(kinds) = &query.kind {
        let kinds: Vec<&str> = kinds
            .split(',')
            .map(str::trim)
            .filter(|k| !k.is_empty())
            .collect();
        if kinds.is_empty() || kinds.len() > KINDS.len() || kinds.iter().any(|k| !KINDS.contains(k))
        {
            return Err(invalid("Unknown activity kind"));
        }
        sql.push_str(&format!(
            " AND kind IN ({})",
            vec!["?"; kinds.len()].join(",")
        ));
        args.extend(kinds.iter().map(|k| (*k).to_owned().into()));
    }
    if let Some(since) = query.since {
        sql.push_str(" AND at>=?");
        args.push(since.into());
    }
    if let Some(until) = query.until {
        sql.push_str(" AND at<?");
        args.push(until.into());
    }
    if let Some(before) = &query.before {
        let cursor: Option<(i64, i64)> = conn
            .query_row(
                "SELECT at,rowid FROM pot_activity WHERE id=?1 AND owner_user=?2",
                params![before, owner],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?;
        let (at, rowid) = cursor.ok_or_else(|| invalid("Unknown page cursor"))?;
        sql.push_str(" AND (at<? OR (at=? AND rowid<?))");
        args.extend([at.into(), at.into(), rowid.into()]);
    }
    sql.push_str(" ORDER BY at DESC, rowid DESC LIMIT ?");
    args.push(i64::from(limit + 1).into());
    let mut activity: Vec<Activity> = conn
        .prepare(&sql)?
        .query_map(rusqlite::params_from_iter(args), activity_row)?
        .collect::<Result<_, _>>()?;
    let next_before = if activity.len() > limit as usize {
        activity.truncate(limit as usize);
        activity.last().map(|a| a.id.clone())
    } else {
        None
    };
    Ok(Page {
        activity,
        next_before,
    })
}

/// Remove rows older than each owner's retention (default 90 days).
pub fn sweep(conn: &Connection, now: i64) -> rusqlite::Result<usize> {
    conn.execute(
        "DELETE FROM pot_activity WHERE at < ?1 - 86400000 * COALESCE(
           (SELECT activity_retention_days FROM pot_settings s WHERE s.owner_user=pot_activity.owner_user), 90)",
        [now],
    )
}

/// Sweep retention hourly.
pub fn start(app: &crate::app::AppState) {
    let app = app.clone();
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(std::time::Duration::from_secs(3600));
        loop {
            interval.tick().await;
            if let Err(error) = sweep(&app.db.lock(), now_ms()) {
                crate::log::warn(&format!("pot activity retention: {error}"));
            }
            if let Err(error) = super::retire::sweep(&app.db.lock(), now_ms()) {
                crate::log::warn(&format!("deleted pots' threads retention: {error}"));
            }
        }
    });
}
