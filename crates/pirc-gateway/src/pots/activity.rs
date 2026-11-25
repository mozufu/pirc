//! Pot activity (plans/pots.md, Activity and point of view): one row per thing a
//! pot did or that happened to it, written by the Gateway code that did it
//! through [`log`]. A row snapshots the pot's name and color, so it still reads
//! after the pot is deleted; the owner's retention removes old rows.

use rusqlite::{Connection, params};
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
