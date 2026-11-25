//! Work a pot opens and coordinates (plans/pots.md, Work dispatch).
//!
//! - `pot.work.open` creates a work session in one of the pot's `write` work
//!   locations through the internal creation entry and delivers the first
//!   instruction as a `pot-instruction` message ("From <pot>"), a custom type
//!   only the Gateway can issue. The model must be one of the pot's work
//!   models; an `ask` model first needs the user's "allow once" (approvals).
//! - `pot.work.send` delivers another instruction into work the pot opened.
//! - `pot.work.status` reads where the work stands.
//!
//! Instructions go out at most once: one whose delivery outcome is unknown is
//! `uncertain` and never re-sent. The user can take any such work over; the pot
//! is told and can no longer send into it.

use rusqlite::{Connection, OptionalExtension, Row, params};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::activity::{self, Counterpart, Entry, Kind, Refs};
use super::approvals::{self, NewApproval};
use super::delivery::{self, Sent};
use super::runtime::{self, NewWake, Source};
use super::store::{self, Access, ModelMode, PotState, Reach, THINKING};
use crate::app::App;
use crate::db::Store;
use crate::dispatch::{Progress, read_progress, start_session};
use crate::error::{ApiError, ApiResult};
use crate::util::{new_id, now_ms};

pub const MAX_INSTRUCTION: usize = 32 * 1024;
/// A work opened this recently counts as running while its run is reported.
const STARTING_MS: i64 = 2 * 60_000;
/// The longest answer `pot.work.status` returns.
const MAX_ANSWER: usize = 4000;

fn invalid(message: &str) -> ApiError {
    ApiError::new(400, "invalid_input", message)
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Work {
    pub id: String,
    pub pot_id: String,
    pub session_id: String,
    pub workspace_id: String,
    pub title: String,
    pub provider: String,
    pub model: String,
    pub thinking: Option<String>,
    pub state: String,
    pub created_at: i64,
}

const SELECT: &str = "SELECT id,pot_id,session_id,workspace_id,title,provider,model,thinking,state,created_at FROM pot_works";

fn work_row(r: &Row) -> rusqlite::Result<Work> {
    Ok(Work {
        id: r.get(0)?,
        pot_id: r.get(1)?,
        session_id: r.get(2)?,
        workspace_id: r.get(3)?,
        title: r.get(4)?,
        provider: r.get(5)?,
        model: r.get(6)?,
        thinking: r.get(7)?,
        state: r.get(8)?,
        created_at: r.get(9)?,
    })
}

/// The owner's pot-coordinated work, newest first, optionally one pot's.
pub fn list(conn: &Connection, owner: &str, pot_id: Option<&str>) -> ApiResult<Vec<Work>> {
    Ok(conn
        .prepare(&format!(
            "{SELECT} WHERE owner_user=?1 AND (?2 IS NULL OR pot_id=?2) ORDER BY created_at DESC, rowid DESC LIMIT 200"
        ))?
        .query_map(params![owner, pot_id], work_row)?
        .collect::<Result<_, _>>()?)
}

/// One of the owner's pot-coordinated works.
pub fn read(conn: &Connection, owner: &str, id: &str) -> ApiResult<Work> {
    conn.query_row(
        &format!("{SELECT} WHERE id=?1 AND owner_user=?2"),
        params![id, owner],
        work_row,
    )
    .optional()?
    .ok_or_else(|| ApiError::not_found("Work not found"))
}

/// The pot's work in `session_id`; another pot's work is not found.
fn pot_work(conn: &Connection, owner: &str, pot_id: &str, session_id: &str) -> ApiResult<Work> {
    conn.query_row(
        &format!("{SELECT} WHERE owner_user=?1 AND pot_id=?2 AND session_id=?3"),
        params![owner, pot_id, session_id],
        work_row,
    )
    .optional()?
    .ok_or_else(|| ApiError::not_found("You do not coordinate that work"))
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Open {
    pub workspace_id: String,
    pub title: String,
    pub instruction: String,
    #[serde(default)]
    pub provider: Option<String>,
    #[serde(default)]
    pub model: Option<String>,
    #[serde(default)]
    pub thinking: Option<String>,
    /// An "allow once" the user gave for this start.
    #[serde(default)]
    pub approval_id: Option<String>,
    /// Why this model, for the approval sheet.
    #[serde(default)]
    pub reason: Option<String>,
    #[serde(default)]
    pub estimate_micros: Option<u64>,
}

fn check_instruction(text: &str) -> ApiResult<&str> {
    let text = text.trim();
    if text.is_empty() || text.len() > MAX_INSTRUCTION {
        return Err(invalid("An instruction is 1 byte to 32 KiB"));
    }
    Ok(text)
}

/// Works of the pot that are running or just started.
fn running(app: &App, conn: &Connection, pot_id: &str) -> ApiResult<u32> {
    let works: Vec<(String, i64)> = conn
        .prepare("SELECT session_id, created_at FROM pot_works WHERE pot_id=?1 AND state='open'")?
        .query_map([pot_id], |r| Ok((r.get(0)?, r.get(1)?)))?
        .collect::<Result<_, _>>()?;
    let now = now_ms();
    let mut count = 0;
    for (session_id, created_at) in works {
        let node = conn.get_session(&session_id).ok().and_then(|s| s.node_id);
        let live = app
            .activity_of(node.as_deref(), &session_id)
            .is_some_and(|activity| activity.run.is_some());
        if live || now - created_at < STARTING_MS {
            count += 1;
        }
    }
    Ok(count)
}

/// What an open needs, checked before anything is created.
struct Plan {
    pot_name: String,
    workspace: crate::db::Workspace,
    provider: String,
    model: String,
    mode: ModelMode,
    thinking: Option<String>,
}

fn plan(app: &App, conn: &Connection, owner: &str, pot_id: &str, input: &Open) -> ApiResult<Plan> {
    let pot = store::read(conn, owner, pot_id)?;
    if pot.state != PotState::Active {
        return Err(ApiError::new(
            409,
            "pot_inactive",
            "A paused or archived pot opens no work",
        ));
    }
    let permissions = &pot.input.permissions;
    if permissions.reach != Reach::Work {
        return Err(ApiError::new(403, "forbidden", "You may not start work"));
    }
    let location = permissions
        .work_locations
        .iter()
        .find(|l| l.workspace_id == input.workspace_id)
        .ok_or_else(|| ApiError::new(403, "forbidden", "That is not one of your work locations"))?;
    if location.access != Access::Write {
        return Err(ApiError::new(
            403,
            "forbidden",
            "You may only read that location; work needs write access",
        ));
    }
    let title = input.title.trim();
    if title.is_empty() || title.chars().count() > 200 {
        return Err(invalid("A work title is 1 to 200 characters"));
    }
    check_instruction(&input.instruction)?;
    let models = &pot.input.models.work_models;
    let chosen = match (&input.provider, &input.model) {
        (Some(provider), Some(model)) => models
            .iter()
            .find(|m| &m.provider == provider && &m.model == model)
            .ok_or_else(|| invalid("That model is not one of your work models"))?,
        (None, None) => models
            .iter()
            .find(|m| m.mode == ModelMode::Direct)
            .ok_or_else(|| invalid("Name a work model: none of yours starts without approval"))?,
        _ => return Err(invalid("Give both provider and model, or neither")),
    };
    let thinking = match input.thinking.as_deref().map(str::trim) {
        None | Some("") => None,
        Some(level) if THINKING.contains(&level) => Some(level.to_owned()),
        Some(_) => return Err(invalid("Unknown thinking level")),
    };
    let max = permissions.max_concurrent_works;
    if running(app, conn, pot_id)? >= max {
        return Err(ApiError::new(
            409,
            "limit_reached",
            format!("You already run {max} works at once"),
        ));
    }
    let workspace = conn.get_workspace(&input.workspace_id)?;
    Ok(Plan {
        pot_name: pot.input.profile.name,
        workspace,
        provider: chosen.provider.clone(),
        model: chosen.model.clone(),
        mode: chosen.mode,
        thinking,
    })
}

fn instruction_message(
    pot_id: &str,
    pot_name: &str,
    work_id: &str,
    instruction_id: &str,
    text: &str,
) -> Value {
    json!({
        "customType": "pot-instruction",
        "content": format!(
            "Instruction from {pot_name}, a pot coordinating this work for the user:\n\n{text}"
        ),
        "details": {
            "potId": pot_id,
            "potName": pot_name,
            "workId": work_id,
            "instructionId": instruction_id,
        },
    })
}

/// Deliver one instruction into the work, recording its outcome.
async fn instruct(
    app: &App,
    owner: &str,
    work: &Work,
    pot_name: &str,
    text: &str,
    model: Option<Value>,
) -> ApiResult<Value> {
    let instruction_id = new_id("instr");
    let session = {
        let conn = app.db.lock();
        conn.execute(
            "INSERT INTO pot_work_instructions(id,work_id,body,state,created_at) VALUES(?1,?2,?3,'sending',?4)",
            params![instruction_id, work.id, text, now_ms()],
        )?;
        conn.get_session(&work.session_id)?
    };
    let mut message = instruction_message(&work.pot_id, pot_name, &work.id, &instruction_id, text);
    if let Some(model) = model {
        message["model"] = model;
        if let Some(thinking) = &work.thinking {
            message["thinking"] = json!(thinking);
        }
    }
    let sent = delivery::send(app, &session, owner, message).await;
    let (state, error) = match &sent {
        Sent::Delivered => ("delivered", None),
        Sent::Refused(reason) => ("refused", Some(reason.clone())),
        Sent::Uncertain(reason) => ("uncertain", Some(reason.clone())),
    };
    let conn = app.db.lock();
    conn.execute(
        "UPDATE pot_work_instructions SET state=?2,error=?3 WHERE id=?1",
        params![instruction_id, state, error],
    )?;
    if let Sent::Refused(reason) = &sent {
        return Err(ApiError::new(
            503,
            "not_delivered",
            format!("The instruction was not delivered: {reason}"),
        ));
    }
    let preview: String = text
        .lines()
        .next()
        .unwrap_or_default()
        .chars()
        .take(160)
        .collect();
    activity::log(
        &conn,
        owner,
        &work.pot_id,
        Entry::new(
            Kind::WorkInstruction,
            format!("To \"{}\": {preview}", work.title),
        )
        .toward(Counterpart::WorkSession(work.session_id.clone()))
        .refs(Refs {
            session: Some(work.session_id.clone()),
            ..Refs::default()
        }),
    )?;
    app.activity_changed(owner);
    Ok(json!({ "instructionId": instruction_id, "delivery": state, "error": error }))
}

pub async fn open(app: &App, owner: &str, pot_id: &str, input: Open) -> ApiResult<Value> {
    let plan = plan(app, &app.db.lock(), owner, pot_id, &input)?;
    let mut consumed = None;
    if plan.mode == ModelMode::Ask {
        match &input.approval_id {
            Some(id) => {
                approvals::consume(
                    &app.db.lock(),
                    owner,
                    id,
                    pot_id,
                    &plan.provider,
                    &plan.model,
                )?;
                consumed = Some(id.clone());
            }
            None => {
                let approval = app.request_approval(
                    owner,
                    pot_id,
                    NewApproval {
                        work_title: input.title.clone(),
                        workspace_id: input.workspace_id.clone(),
                        provider: plan.provider.clone(),
                        model: plan.model.clone(),
                        thinking: plan.thinking.clone(),
                        reason: input.reason.clone().unwrap_or_default(),
                        estimate_micros: input.estimate_micros.unwrap_or(0),
                        remaining_micros: None,
                    },
                )?;
                return Ok(json!({ "state": "awaiting_approval", "approvalId": approval.id }));
            }
        }
    }
    let title = input.title.trim();
    let session = match start_session(app, &plan.workspace, owner, title).await {
        Ok(session) => session,
        Err(failure) => {
            if let Some(id) = consumed {
                approvals::release(&app.db.lock(), owner, &id)?;
            }
            return Err(ApiError::new(
                503,
                "node_unavailable",
                format!("The work could not be started: {}", failure.0),
            ));
        }
    };
    let work = {
        let conn = app.db.lock();
        let id = new_id("work");
        let stamp = now_ms();
        conn.execute(
            "INSERT INTO pot_works(id,owner_user,pot_id,session_id,workspace_id,title,provider,model,thinking,created_at,updated_at)
             VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?10)",
            params![
                id,
                owner,
                pot_id,
                session.id,
                plan.workspace.id,
                title,
                plan.provider,
                plan.model,
                plan.thinking,
                stamp
            ],
        )?;
        activity::log(
            &conn,
            owner,
            pot_id,
            Entry::new(
                Kind::WorkOpened,
                format!("Opened \"{title}\" with {}/{}", plan.provider, plan.model),
            )
            .toward(Counterpart::Workspace(plan.workspace.id.clone()))
            .refs(Refs {
                session: Some(session.id.clone()),
                approval: consumed.clone(),
                ..Refs::default()
            }),
        )?;
        super::threads::post_card(
            &conn,
            owner,
            pot_id,
            &format!("Opened \"{title}\" in {}.", plan.workspace.id),
            super::threads::Card::Work {
                work_id: id.clone(),
                session_id: session.id.clone(),
            },
        )?;
        conn.query_row(&format!("{SELECT} WHERE id=?1"), [&id], work_row)?
    };
    app.pots_changed(owner);
    let model = json!({ "provider": plan.provider, "id": plan.model });
    let delivered = instruct(
        app,
        owner,
        &work,
        &plan.pot_name,
        input.instruction.trim(),
        Some(model),
    )
    .await;
    let delivery = match delivered {
        Ok(result) => result,
        Err(error) => json!({ "delivery": "refused", "error": error.message }),
    };
    Ok(json!({ "state": "started", "work": work, "instruction": delivery }))
}

pub async fn send(
    app: &App,
    owner: &str,
    pot_id: &str,
    session_id: &str,
    text: &str,
) -> ApiResult<Value> {
    let text = check_instruction(text)?.to_owned();
    let (work, pot_name) = {
        let conn = app.db.lock();
        let pot = store::read(&conn, owner, pot_id)?;
        (
            pot_work(&conn, owner, pot_id, session_id)?,
            pot.input.profile.name,
        )
    };
    if work.state == "taken_over" {
        return Err(ApiError::new(
            409,
            "taken_over",
            "The user took this work over",
        ));
    }
    instruct(app, owner, &work, &pot_name, &text, None).await
}

pub async fn status(app: &App, owner: &str, pot_id: &str, session_id: &str) -> ApiResult<Value> {
    let (work, last) = {
        let conn = app.db.lock();
        let work = pot_work(&conn, owner, pot_id, session_id)?;
        let last: Option<(String, String, i64)> = conn
            .query_row(
                "SELECT id,state,created_at FROM pot_work_instructions WHERE work_id=?1 ORDER BY created_at DESC, rowid DESC LIMIT 1",
                [&work.id],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .optional()?;
        (work, last)
    };
    let mut out = json!({ "work": work });
    let Some((instruction_id, delivery, sent_at)) = last else {
        out["run"] = json!("unknown");
        return Ok(out);
    };
    out["lastInstruction"] = json!({ "id": instruction_id, "delivery": delivery });
    let session = app.db.lock().get_session(session_id)?;
    let progress = read_progress(app, &session, owner, sent_at, |message| {
        message["details"]["instructionId"].as_str() == Some(instruction_id.as_str())
    })
    .await
    .map_err(|failure| ApiError::new(503, "node_unavailable", failure.0))?;
    match progress {
        Progress::Unknown => out["run"] = json!("unknown"),
        Progress::Queued => out["run"] = json!("queued"),
        Progress::Dropped => out["run"] = json!("dropped"),
        Progress::Working => out["run"] = json!("working"),
        Progress::Waiting(_) => out["run"] = json!("waiting_for_user"),
        Progress::Over {
            status,
            failure_reason,
            answer,
        } => {
            out["run"] = json!("over");
            out["status"] = json!(status);
            out["failureReason"] = json!(failure_reason);
            out["answer"] = json!(answer.chars().take(MAX_ANSWER).collect::<String>());
        }
    }
    Ok(out)
}

/// The user takes a pot's work over: the pot is told and stops sending.
pub fn take_over(conn: &Connection, owner: &str, work_id: &str) -> ApiResult<Work> {
    let work = conn
        .query_row(
            &format!("{SELECT} WHERE id=?1 AND owner_user=?2"),
            params![work_id, owner],
            work_row,
        )
        .optional()?
        .ok_or_else(|| ApiError::not_found("Work not found"))?;
    if work.state == "taken_over" {
        return Err(ApiError::new(
            409,
            "taken_over",
            "This work was already taken over",
        ));
    }
    conn.execute(
        "UPDATE pot_works SET state='taken_over',updated_at=?2 WHERE id=?1",
        params![work.id, now_ms()],
    )?;
    let thread = super::threads::direct(conn, owner, &work.pot_id)?;
    runtime::enqueue(
        conn,
        owner,
        &work.pot_id,
        NewWake {
            source: Source::Handover,
            thread_id: Some(&thread.id),
            causal_root: None,
            content: &format!(
                "The user took over the work \"{}\". Do not send into it any more; \
                 its session stays readable with work_status.",
                work.title
            ),
            details: json!({ "workId": work.id, "sessionId": work.session_id }),
        },
    )?;
    conn.query_row(&format!("{SELECT} WHERE id=?1"), [&work.id], work_row)
        .map_err(Into::into)
}
