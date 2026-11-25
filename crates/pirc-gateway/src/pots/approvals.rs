//! Model approvals (plans/pots.md, Models for work).
//!
//! Only models in the pot's `pot_work_models` may start work. A `direct` model
//! starts at once; an `ask` model first creates an approval the user answers
//! with deny, deny with a reason, or allow once. A reason is posted into the
//! pot's direct thread as a system message, and every answer wakes the pot.
//! "Allow once" covers exactly one start: consuming it moves the row to `used`
//! in one conditional update, so it can never start two works.

use rusqlite::{Connection, OptionalExtension, Row, TransactionBehavior, params};
use serde::{Deserialize, Serialize};
use serde_json::json;

use super::activity::{self, Counterpart, Entry, Kind, Refs};
use super::runtime::{self, NewWake, Source};
use super::store::{self, ModelMode, PotState, THINKING};
use super::threads;
use crate::app::App;
use crate::error::{ApiError, ApiResult};
use crate::util::{new_id, now_ms};

/// Pending approvals one pot may have at a time.
pub const MAX_PENDING: i64 = 20;
const MAX_REASON: usize = 2000;
const MAX_WORK_TITLE: usize = 200;
const MAX_WORKSPACE: usize = 256;
const MAX_PROVIDER: usize = 100;
const MAX_MODEL: usize = 200;

fn invalid(message: &str) -> ApiError {
    ApiError::new(400, "invalid_input", message)
}

fn text(value: &str, field: &str, min: usize, max: usize) -> ApiResult<String> {
    let value = value.trim();
    let count = value.chars().count();
    if count < min || count > max {
        return Err(invalid(&format!(
            "{field} must be {min} to {max} characters"
        )));
    }
    Ok(value.to_owned())
}

fn micros(value: u64, field: &str) -> ApiResult<i64> {
    i64::try_from(value).map_err(|_| invalid(&format!("{field} is too large")))
}

fn already_answered() -> ApiError {
    ApiError::new(
        409,
        "already_answered",
        "This approval was already answered",
    )
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ApprovalState {
    Pending,
    AllowedOnce,
    Denied,
    Used,
}

impl ApprovalState {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Pending => "pending",
            Self::AllowedOnce => "allowed_once",
            Self::Denied => "denied",
            Self::Used => "used",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "pending" => Some(Self::Pending),
            "allowed_once" => Some(Self::AllowedOnce),
            "denied" => Some(Self::Denied),
            "used" => Some(Self::Used),
            _ => None,
        }
    }
}
crate::db::sql_text_enum!(ApprovalState);

/// The user's three answers: deny (optionally with a reason), or allow once.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Decision {
    Deny,
    AllowOnce,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Answer {
    pub answer: Decision,
    #[serde(default)]
    pub reason: Option<String>,
}

/// What a pot asks before starting work with an `ask` model (built by
/// `pot.work.open`).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct NewApproval {
    pub work_title: String,
    pub workspace_id: String,
    pub provider: String,
    pub model: String,
    #[serde(default)]
    pub thinking: Option<String>,
    #[serde(default)]
    pub reason: String,
    #[serde(default)]
    pub estimate_micros: u64,
    #[serde(default)]
    pub remaining_micros: Option<u64>,
}

impl NewApproval {
    fn normalize(mut self) -> ApiResult<Self> {
        self.work_title = text(&self.work_title, "workTitle", 1, MAX_WORK_TITLE)?;
        self.workspace_id = text(&self.workspace_id, "workspaceId", 1, MAX_WORKSPACE)?;
        self.provider = text(&self.provider, "provider", 1, MAX_PROVIDER)?;
        self.model = text(&self.model, "model", 1, MAX_MODEL)?;
        self.thinking = match self.thinking.as_deref().map(str::trim) {
            None | Some("") => None,
            Some(thinking) if THINKING.contains(&thinking) => Some(thinking.to_owned()),
            Some(_) => return Err(invalid("Unknown thinking level")),
        };
        self.reason = text(&self.reason, "reason", 0, MAX_REASON)?;
        micros(self.estimate_micros, "estimateMicros")?;
        if let Some(remaining) = self.remaining_micros {
            micros(remaining, "remainingMicros")?;
        }
        Ok(self)
    }
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Approval {
    pub id: String,
    pub pot_id: String,
    pub work_title: String,
    pub workspace_id: String,
    pub provider: String,
    pub model: String,
    pub thinking: Option<String>,
    pub reason: String,
    pub estimate_micros: u64,
    pub remaining_micros: Option<u64>,
    pub state: ApprovalState,
    pub deny_reason: Option<String>,
    pub created_at: i64,
    pub answered_at: Option<i64>,
    pub used_at: Option<i64>,
}

const SELECT: &str = "SELECT id,pot_id,work_title,workspace_id,provider,model,thinking,reason,
  estimate_micros,remaining_micros,state,deny_reason,created_at,answered_at,used_at
  FROM model_approvals";

fn row(row: &Row) -> rusqlite::Result<Approval> {
    Ok(Approval {
        id: row.get(0)?,
        pot_id: row.get(1)?,
        work_title: row.get(2)?,
        workspace_id: row.get(3)?,
        provider: row.get(4)?,
        model: row.get(5)?,
        thinking: row.get(6)?,
        reason: row.get(7)?,
        estimate_micros: row.get::<_, i64>(8)? as u64,
        remaining_micros: row.get::<_, Option<i64>>(9)?.map(|v| v as u64),
        state: row.get(10)?,
        deny_reason: row.get(11)?,
        created_at: row.get(12)?,
        answered_at: row.get(13)?,
        used_at: row.get(14)?,
    })
}

fn not_found() -> ApiError {
    ApiError::not_found("Approval not found")
}

fn find(conn: &Connection, owner: &str, id: &str) -> ApiResult<Option<Approval>> {
    Ok(conn
        .query_row(
            &format!("{SELECT} WHERE id=?1 AND owner_user=?2"),
            params![id, owner],
            row,
        )
        .optional()?)
}

pub fn read(conn: &Connection, owner: &str, id: &str) -> ApiResult<Approval> {
    find(conn, owner, id)?.ok_or_else(not_found)
}

/// A pot asks to start work with an `ask` model.
pub fn request(
    conn: &Connection,
    owner: &str,
    pot_id: &str,
    input: NewApproval,
) -> ApiResult<Approval> {
    let pot = store::read(conn, owner, pot_id)?;
    if pot.state == PotState::Archived {
        return Err(ApiError::new(
            409,
            "pot_archived",
            "Restore the pot before requesting a model approval",
        ));
    }
    let input = input.normalize()?;
    let mode = pot
        .input
        .models
        .work_models
        .iter()
        .find(|work| work.provider == input.provider && work.model == input.model)
        .map(|work| work.mode);
    if mode != Some(ModelMode::Ask) {
        return Err(invalid(match mode {
            Some(ModelMode::Direct) => "That model starts work directly and needs no approval",
            _ => "That model is not one of the pot's work models",
        }));
    }
    let id = new_id("appr");
    // The limit is part of the one insert: no count-then-insert race.
    let inserted = conn.execute(
        "INSERT INTO model_approvals(id,owner_user,pot_id,work_title,workspace_id,provider,model,
          thinking,reason,estimate_micros,remaining_micros,state,created_at)
         SELECT ?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,'pending',?12
         WHERE (SELECT count(*) FROM model_approvals WHERE pot_id=?3 AND state='pending') < ?13",
        params![
            id,
            owner,
            pot_id,
            input.work_title,
            input.workspace_id,
            input.provider,
            input.model,
            input.thinking,
            input.reason,
            micros(input.estimate_micros, "estimateMicros")?,
            input
                .remaining_micros
                .map(|value| micros(value, "remainingMicros"))
                .transpose()?,
            now_ms(),
            MAX_PENDING,
        ],
    )?;
    if inserted != 1 {
        return Err(ApiError::new(
            409,
            "limit_reached",
            "This pot has the most pending approvals allowed",
        ));
    }
    activity::log(
        conn,
        owner,
        pot_id,
        Entry::new(
            Kind::AwaitingApproval,
            format!(
                "Asks to use {}/{} for \"{}\"",
                input.provider, input.model, input.work_title
            ),
        )
        .toward(Counterpart::User)
        .refs(Refs {
            approval: Some(id.clone()),
            ..Refs::default()
        }),
    )?;
    read(conn, owner, &id)
}

/// The owner's approvals, newest first, optionally only one state.
pub fn list(
    conn: &Connection,
    owner: &str,
    state: Option<ApprovalState>,
) -> ApiResult<Vec<Approval>> {
    let query = match state {
        Some(_) => {
            format!("{SELECT} WHERE owner_user=?1 AND state=?2 ORDER BY created_at DESC,rowid DESC")
        }
        None => format!("{SELECT} WHERE owner_user=?1 ORDER BY created_at DESC,rowid DESC"),
    };
    let mut statement = conn.prepare(&query)?;
    let approvals = match state {
        Some(state) => statement
            .query_map(params![owner, state], row)?
            .collect::<Result<_, _>>()?,
        None => statement
            .query_map([owner], row)?
            .collect::<Result<_, _>>()?,
    };
    Ok(approvals)
}

/// The pot reads what the user decided.
fn answer_text(approval: &Approval) -> String {
    let model = match &approval.thinking {
        Some(thinking) => format!(
            "{}/{} with thinking {thinking}",
            approval.provider, approval.model
        ),
        None => format!("{}/{}", approval.provider, approval.model),
    };
    let result = match approval.state {
        ApprovalState::AllowedOnce => {
            "allowed once; that covers one start only, and a further start needs a new approval"
                .to_owned()
        }
        ApprovalState::Denied => match &approval.deny_reason {
            Some(reason) => format!("denied with the reason: {reason}"),
            None => "denied".to_owned(),
        },
        _ => "answered".to_owned(),
    };
    format!(
        "The user answered your model approval for the work \"{}\" in {}: {result}.\n\
         Model: {model}.\n\n\
         Your final answer is posted in your direct conversation with the user.",
        approval.work_title, approval.workspace_id,
    )
}

/// Answer a pending approval. A denial's reason becomes a system message in
/// the pot's direct thread; either answer wakes the pot.
pub fn answer(conn: &mut Connection, owner: &str, id: &str, answer: Answer) -> ApiResult<Approval> {
    let reason = match &answer.reason {
        Some(reason) => Some(text(reason, "reason", 0, MAX_REASON)?).filter(|r| !r.is_empty()),
        None => None,
    };
    if answer.answer == Decision::AllowOnce && answer.reason.is_some() {
        return Err(invalid("A reason is only for a deny answer"));
    }
    let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let current = read(&tx, owner, id)?;
    if current.state != ApprovalState::Pending {
        return Err(already_answered());
    }
    let (state, deny_reason) = match answer.answer {
        Decision::Deny => (ApprovalState::Denied, reason),
        Decision::AllowOnce => (ApprovalState::AllowedOnce, None),
    };
    let changed = tx.execute(
        "UPDATE model_approvals SET state=?1,deny_reason=?2,answered_at=?3
         WHERE id=?4 AND owner_user=?5 AND state='pending'",
        params![state, deny_reason, now_ms(), id, owner],
    )?;
    if changed != 1 {
        return Err(already_answered());
    }
    let approval = read(&tx, owner, id)?;
    if let Some(reason) = &approval.deny_reason {
        threads::post_system(
            &tx,
            owner,
            &approval.pot_id,
            &format!(
                "Model approval denied for \"{}\": {reason}",
                approval.work_title
            ),
        )?;
    }
    let thread = threads::direct(&tx, owner, &approval.pot_id)?;
    runtime::enqueue(
        &tx,
        owner,
        &approval.pot_id,
        NewWake {
            source: Source::Approval,
            thread_id: Some(&thread.id),
            causal_root: None,
            content: &answer_text(&approval),
            details: json!({
                "approvalId": approval.id,
                "potId": approval.pot_id,
                "state": approval.state,
                "provider": approval.provider,
                "model": approval.model,
                "workTitle": approval.work_title,
                "workspaceId": approval.workspace_id,
            }),
        },
    )?;
    let verdict = match approval.state {
        ApprovalState::AllowedOnce => "allowed once",
        _ => "denied",
    };
    activity::log(
        &tx,
        owner,
        &approval.pot_id,
        Entry::new(
            Kind::ApprovalAnswered,
            format!(
                "The user {verdict} {}/{} for \"{}\"",
                approval.provider, approval.model, approval.work_title
            ),
        )
        .toward(Counterpart::User)
        .refs(Refs {
            approval: Some(approval.id.clone()),
            ..Refs::default()
        }),
    )?;
    tx.commit()?;
    Ok(approval)
}

/// Take an `allowed_once` approval for exactly one start. The conditional
/// update makes a second take (or another start's) fail.
pub fn consume(
    conn: &Connection,
    owner: &str,
    id: &str,
    pot_id: &str,
    provider: &str,
    model: &str,
) -> ApiResult<()> {
    let taken = conn.execute(
        "UPDATE model_approvals SET state='used',used_at=?1
         WHERE id=?2 AND owner_user=?3 AND pot_id=?4 AND provider=?5 AND model=?6
           AND state='allowed_once'",
        params![now_ms(), id, owner, pot_id, provider, model],
    )?;
    if taken == 1 {
        return Ok(());
    }
    let Some(current) = find(conn, owner, id)? else {
        return Err(not_found());
    };
    if current.pot_id != pot_id || current.provider != provider || current.model != model {
        return Err(ApiError::new(
            409,
            "approval_mismatch",
            "This approval is for other work",
        ));
    }
    Err(already_answered())
}

impl App {
    /// Request an approval and tell the owner's clients (`approvals=1`).
    /// Callers that hold the app use this; the store function alone cannot
    /// hint.
    pub fn request_approval(
        &self,
        owner: &str,
        pot_id: &str,
        input: NewApproval,
    ) -> ApiResult<Approval> {
        let approval = request(&self.db.lock(), owner, pot_id, input)?;
        self.approvals_changed(owner);
        self.activity_changed(owner);
        Ok(approval)
    }
}

/// Give back a consumed "allow once" whose start then failed, so the pot can
/// try that one start again.
pub fn release(conn: &Connection, owner: &str, id: &str) -> ApiResult<()> {
    conn.execute(
        "UPDATE model_approvals SET state='allowed_once',used_at=NULL
         WHERE id=?1 AND owner_user=?2 AND state='used'",
        params![id, owner],
    )?;
    Ok(())
}
