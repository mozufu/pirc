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
    }
}
