//! `pot.*` agent operations. The pot is the one whose session is asking (the
//! Gateway maps the session; the agent never names a pot), and only sessions
//! in the `pot` mode may ask.

use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Value, json};

use super::store::{self, Pot, Reach};
use crate::agent_ops::OpContext;
use crate::app::AppState;
use crate::error::{ApiError, ApiResult};

pub enum Op {
    Context,
    Send(Send),
    WorkOpen(super::work::Open),
    WorkSend(WorkSend),
    WorkStatus(WorkStatus),
    AutonomySet(AutonomySet),
    ReminderCreate(ReminderCreate),
    ThinkingSet(ThinkingSet),
    Fallback(Fallback),
    BudgetStatus,
    BudgetRequest(super::budget::RequestInput),
    ObserveNote(super::observe::Note),
    ObserveRead(ObserveRead),
}

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ObserveRead {
    event_id: String,
}

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkSend {
    session_id: String,
    instruction: String,
}

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkStatus {
    session_id: String,
}

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Send {
    /// Another pot to message directly, or
    to_pot: Option<String>,
    /// a thread this pot belongs to.
    thread_id: Option<String>,
    body: String,
    #[serde(default)]
    mentions: Vec<String>,
}

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AutonomySet {
    /// Seconds between reviews; null (or absent) turns them off.
    interval_s: Option<i64>,
    #[serde(default)]
    reason: String,
}

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ReminderCreate {
    /// When to be woken, Unix epoch milliseconds.
    at: i64,
    note: String,
}

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ThinkingSet {
    level: String,
    #[serde(default)]
    reason: String,
}

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Fallback {
    from: ModelName,
    to: ModelName,
    #[serde(default)]
    reason: String,
}

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ModelName {
    provider: String,
    model: String,
}

impl ModelName {
    fn choice(&self) -> super::store::ModelChoice {
        super::store::ModelChoice {
            provider: self.provider.clone(),
            model: self.model.clone(),
        }
    }
}

/// `None`: not a pot operation; `Some(Err)`: invalid arguments.
pub fn parse_op(op: &str, args: &Value) -> Option<Result<Op, ()>> {
    match op {
        "pot.context" => Some(
            args.as_object()
                .filter(|a| a.is_empty())
                .map(|_| Op::Context)
                .ok_or(()),
        ),
        "pot.message.send" => Some(
            serde_json::from_value::<Send>(args.clone())
                .ok()
                .filter(|send| send.to_pot.is_some() != send.thread_id.is_some())
                .map(Op::Send)
                .ok_or(()),
        ),
        "pot.work.open" => Some(
            serde_json::from_value(args.clone())
                .map(Op::WorkOpen)
                .map_err(|_| ()),
        ),
        "pot.work.send" => Some(
            serde_json::from_value(args.clone())
                .map(Op::WorkSend)
                .map_err(|_| ()),
        ),
        "pot.work.status" => Some(
            serde_json::from_value(args.clone())
                .map(Op::WorkStatus)
                .map_err(|_| ()),
        ),
        "pot.autonomy.set" => Some(
            serde_json::from_value::<AutonomySet>(args.clone())
                .map(Op::AutonomySet)
                .map_err(|_| ()),
        ),
        "pot.reminder.create" => Some(
            serde_json::from_value::<ReminderCreate>(args.clone())
                .map(Op::ReminderCreate)
                .map_err(|_| ()),
        ),
        "pot.thinking.set" => Some(
            serde_json::from_value::<ThinkingSet>(args.clone())
                .map(Op::ThinkingSet)
                .map_err(|_| ()),
        ),
        "pot.fallback" => Some(
            serde_json::from_value::<Fallback>(args.clone())
                .map(Op::Fallback)
                .map_err(|_| ()),
        ),
        "pot.budget.status" => Some(
            args.as_object()
                .filter(|a| a.is_empty())
                .map(|_| Op::BudgetStatus)
                .ok_or(()),
        ),
        "pot.budget.request" => Some(
            serde_json::from_value::<super::budget::RequestInput>(args.clone())
                .map(Op::BudgetRequest)
                .map_err(|_| ()),
        ),
        "pot.observe.note" => Some(
            serde_json::from_value(args.clone())
                .map(Op::ObserveNote)
                .map_err(|_| ()),
        ),
        "pot.observe.read" => Some(
            serde_json::from_value(args.clone())
                .map(Op::ObserveRead)
                .map_err(|_| ()),
        ),
        _ => None,
    }
}

/// The pot whose own session `session_id` is.
pub fn pot_of_session(conn: &Connection, owner: &str, session_id: &str) -> ApiResult<Pot> {
    let id: Option<String> = conn
        .query_row(
            "SELECT p.id FROM pot_runtime r JOIN pots p ON p.id=r.pot_id
             WHERE r.session_id=?1 AND p.owner_user=?2",
            params![session_id, owner],
            |r| r.get(0),
        )
        .optional()?;
    let id = id.ok_or_else(|| ApiError::new(403, "not_a_pot", "This session is not a pot's"))?;
    store::read(conn, owner, &id)
}

/// A plain-language summary of what the pot may do, for its prompt. It
/// informs the model; the Gateway enforces the permissions themselves.
fn permission_summary(pot: &Pot) -> String {
    let p = &pot.input.permissions;
    let reach = match p.reach {
        Reach::Answer => "You may only answer when addressed.",
        Reach::Observe => "You may observe your sources and suggest, but not start work.",
        Reach::Work => "You may observe, suggest and start work in your work locations.",
    };
    let mut lines = vec![reach.to_owned()];
    if !p.observe.is_empty() {
        let scopes: Vec<String> = p
            .observe
            .iter()
            .map(|s| {
                if s.r#ref.is_empty() {
                    s.kind.as_str().to_owned()
                } else {
                    format!("{} {}", s.kind.as_str(), s.r#ref)
                }
            })
            .collect();
        lines.push(format!("You observe: {}.", scopes.join(", ")));
    }
    if !p.work_locations.is_empty() {
        let places: Vec<String> = p
            .work_locations
            .iter()
            .map(|l| format!("{} ({})", l.workspace_id, l.access.as_str()))
            .collect();
        lines.push(format!("You may work in: {}.", places.join(", ")));
        lines.push(format!(
            "At most {} work sessions at once.",
            p.max_concurrent_works
        ));
    }
    lines.push(format!(
        "Messages to other pots: sending {}, receiving {}.",
        p.dm.send.as_str(),
        p.dm.receive.as_str()
    ));
    lines.join("\n")
}

pub fn context(conn: &Connection, owner: &str, session_id: &str) -> ApiResult<Value> {
    let pot = pot_of_session(conn, owner, session_id)?;
    let work = &pot.input.work;
    let active_fallback: i64 = conn.query_row(
        "SELECT active_fallback FROM pot_runtime WHERE pot_id=?1",
        [&pot.id],
        |r| r.get(0),
    )?;
    Ok(json!({
        "pot": {
            "id": pot.id,
            "name": pot.input.profile.name,
            "personality": pot.input.profile.personality,
            "intro": work.intro,
            "workDescription": work.description,
            "responsibilities": work.responsibilities,
            "permissions": permission_summary(&pot),
        },
        "models": {
            "main": pot.input.models.main,
            "fallbacks": pot.input.models.fallbacks,
            "activeFallback": active_fallback,
            "thinking": pot.input.models.thinking,
            "thinkingAuto": pot.input.models.thinking_auto,
        },
        "user": { "name": owner },
    }))
}

pub async fn run_op(app: &AppState, context: &OpContext, op: Op) -> ApiResult<Value> {
    if !context.mode.pot {
        return Err(ApiError::new(
            403,
            "forbidden",
            "Only a pot's own session may ask",
        ));
    }
    match op {
        Op::Context => self::context(&app.db.lock(), &context.user, &context.session.id),
        Op::AutonomySet(set) => {
            let result = {
                let conn = app.db.lock();
                let pot = pot_of_session(&conn, &context.user, &context.session.id)?;
                super::autonomy::set_autonomy(
                    &conn,
                    &context.user,
                    &pot.id,
                    set.interval_s,
                    &set.reason,
                )?
            };
            app.pots_changed(&context.user);
            app.activity_changed(&context.user);
            Ok(result)
        }
        Op::ReminderCreate(reminder) => {
            let result = {
                let conn = app.db.lock();
                let pot = pot_of_session(&conn, &context.user, &context.session.id)?;
                super::autonomy::create_reminder(
                    &conn,
                    &context.user,
                    &pot.id,
                    reminder.at,
                    &reminder.note,
                )?
            };
            app.activity_changed(&context.user);
            Ok(result)
        }
        Op::ThinkingSet(set) => {
            let result = {
                let conn = app.db.lock();
                let pot = pot_of_session(&conn, &context.user, &context.session.id)?;
                super::autonomy::set_thinking(
                    &conn,
                    &context.user,
                    &pot.id,
                    &set.level,
                    &set.reason,
                )?
            };
            app.pots_changed(&context.user);
            app.activity_changed(&context.user);
            Ok(result)
        }
        Op::Fallback(fallback) => {
            let result = {
                let conn = app.db.lock();
                let pot = pot_of_session(&conn, &context.user, &context.session.id)?;
                super::autonomy::record_fallback(
                    &conn,
                    &context.user,
                    &pot.id,
                    &fallback.from.choice(),
                    &fallback.to.choice(),
                    &fallback.reason,
                )?
            };
            app.activity_changed(&context.user);
            Ok(result)
        }
        Op::Send(send) => {
            let (message, woken) = {
                let conn = app.db.lock();
                let pot = pot_of_session(&conn, &context.user, &context.session.id)?;
                let target = match (&send.to_pot, &send.thread_id) {
                    (Some(to), _) => super::threads::Target::Pot(to),
                    (_, Some(thread)) => super::threads::Target::Thread(thread),
                    _ => unreachable!("parse requires exactly one target"),
                };
                super::threads::post_pot(
                    &conn,
                    &context.user,
                    &pot.id,
                    target,
                    &send.body,
                    send.mentions,
                    None,
                )?
            };
            for pot in &woken {
                super::runtime::kick(app, &context.user, pot);
            }
            app.threads_changed(&context.user);
            app.activity_changed(&context.user);
            Ok(json!({ "message": message, "woken": woken }))
        }
        Op::WorkOpen(input) => {
            let pot = pot_of_session(&app.db.lock(), &context.user, &context.session.id)?;
            super::work::open(app, &context.user, &pot.id, input).await
        }
        Op::WorkSend(send) => {
            let pot = pot_of_session(&app.db.lock(), &context.user, &context.session.id)?;
            super::work::send(
                app,
                &context.user,
                &pot.id,
                &send.session_id,
                &send.instruction,
            )
            .await
        }
        Op::ObserveNote(note) => {
            let conn = app.db.lock();
            let pot = pot_of_session(&conn, &context.user, &context.session.id)?;
            let observation = super::observe::note(&conn, &context.user, &pot.id, note)?;
            Ok(json!({ "observation": observation }))
        }
        Op::ObserveRead(read) => {
            let pot = pot_of_session(&app.db.lock(), &context.user, &context.session.id)?;
            super::observe::read(app, &context.user, &pot.id, &read.event_id).await
        }
        Op::WorkStatus(status) => {
            let pot = pot_of_session(&app.db.lock(), &context.user, &context.session.id)?;
            super::work::status(app, &context.user, &pot.id, &status.session_id).await
        }
        Op::BudgetStatus => {
            let conn = app.db.lock();
            let pot = pot_of_session(&conn, &context.user, &context.session.id)?;
            super::budget::status_for(&conn, &context.user, &pot.id, &app.config.timezone)
        }
        Op::BudgetRequest(input) => {
            let pot_id = {
                let conn = app.db.lock();
                pot_of_session(&conn, &context.user, &context.session.id)?.id
            };
            let request = super::budget::request_with_hints(app, &context.user, &pot_id, input)?;
            Ok(json!({ "request": request }))
        }
    }
}
