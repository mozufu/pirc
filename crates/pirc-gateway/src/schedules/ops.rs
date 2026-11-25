//! The `schedule.*` operations agents ask for (`daemon/agent-ops.ts`).
//!
//! Where a session's agent may schedule (docs/guides/schedules.md): a mode
//! with `schedule_scope: any` in any directory workspace; any other
//! session only in its own workspace. A scheduled run may not start more
//! work: no new schedules, resumes or runs from it.

use rusqlite::Connection;
use serde_json::{Value, json};

use super::fields::{Checked, agent_input, object};
use super::{Ctx, Input, Schedule, with};
use crate::agent_ops::OpContext;
use crate::app::AppState;
use crate::db::Workspace;
use crate::dispatch::resolve_directory_workspace;
use crate::error::{ApiError, ApiResult};
use pirc_protocol::mode::ScheduleScope;

pub enum Op {
    /// The user's schedules this session may manage, and the default time zone.
    List,
    /// A run's final message, in chunks.
    Result {
        id: String,
        offset: Option<f64>,
    },
    /// Propose a new schedule; it exists once the user approves it.
    Create(Box<Input>),
    /// Propose a change; it applies once the user approves it.
    Update {
        id: String,
        input: Box<Input>,
    },
    Pause(String),
    Resume(String),
    /// Propose deleting one; it is deleted once the user approves.
    Delete(String),
    /// Run a schedule now (the user's `/cron run`).
    Run(String),
}

/// `None`: no such operation; `Some(Err)`: invalid arguments.
pub fn parse_op(op: &str, args: &Value) -> Option<Result<Op, ()>> {
    let parsed: Checked<Op> = match op {
        "schedule.list" => object(args, &[]).map(|_| Op::List),
        "schedule.result" => object(args, &["id", "offset"]).and_then(|args| {
            Ok(Op::Result {
                id: args.required("id", 1, 40)?,
                offset: args.offset("offset")?,
            })
        }),
        "schedule.create" => object(
            args,
            &[
                "workspace",
                "prompt",
                "title",
                "cron",
                "at",
                "timezone",
                "notify",
            ],
        )
        .and_then(|args| agent_input(&args, true).map(|input| Op::Create(Box::new(input)))),
        "schedule.update" => object(
            args,
            &[
                "id",
                "workspace",
                "prompt",
                "title",
                "cron",
                "at",
                "timezone",
                "notify",
            ],
        )
        .and_then(|args| {
            Ok(Op::Update {
                id: args.required("id", 1, 40)?,
                input: Box::new(agent_input(&args, false)?),
            })
        }),
        "schedule.pause" | "schedule.resume" | "schedule.delete" | "schedule.run" => {
            object(args, &["id"]).and_then(|args| {
                let id = args.required("id", 1, 40)?;
                Ok(match op {
                    "schedule.pause" => Op::Pause(id),
                    "schedule.resume" => Op::Resume(id),
                    "schedule.delete" => Op::Delete(id),
                    _ => Op::Run(id),
                })
            })
        }
        _ => return None,
    };
    Some(parsed.map_err(|_| ()))
}

/// Whether the session may schedule in other workspaces.
fn schedules_anywhere(context: &OpContext) -> bool {
    context.mode.schedule_scope == ScheduleScope::Any
}

/// `scheduleScope(...).allows`.
fn allows(context: &OpContext, schedule: &Schedule) -> bool {
    schedules_anywhere(context) || schedule.spec.workspace_id == context.workspace.id
}

/// `scheduleScope(...).resolve`, worked out before the database is locked
/// (finding a directory workspace by name locks it itself).
fn scope_resolution(
    app: &AppState,
    context: &OpContext,
    reference: Option<&str>,
) -> Option<ApiResult<Workspace>> {
    let reference = super::cron::js_trim(reference?);
    if reference.is_empty() {
        return None;
    }
    let own = &context.workspace;
    if reference == own.id || reference.to_lowercase() == own.display_name.to_lowercase() {
        return Some(Ok(own.clone()));
    }
    if schedules_anywhere(context) {
        return Some(resolve_directory_workspace(app, reference));
    }
    Some(Err(ApiError::new(
        403,
        "forbidden",
        "Only the assistant schedules in other workspaces: leave workspace out to schedule here",
    )))
}

/// An agent's view of the user's schedule `id`, if its session may manage it.
fn scoped(ctx: &Ctx<'_>, context: &OpContext, id: &str) -> ApiResult<Schedule> {
    let schedule = ctx.get(&context.user, id)?;
    if !allows(context, &schedule) {
        return Err(ApiError::not_found(format!(
            "No schedule {id} in this workspace"
        )));
    }
    Ok(schedule)
}

/// A scheduled run may not start more work.
fn refuse_from_scheduled_run(ctx: &Ctx<'_>, context: &OpContext) -> ApiResult<()> {
    if ctx.is_run_session(&context.session.id)? {
        return Err(ApiError::new(
            403,
            "forbidden",
            "A scheduled run cannot create, change, resume or start schedules",
        ));
    }
    Ok(())
}

pub async fn run_op(app: &AppState, context: &OpContext, op: Op) -> ApiResult<Value> {
    let user = context.user.as_str();
    match op {
        Op::List => with(app, |ctx| {
            let schedules = ctx
                .list(user)?
                .iter()
                .filter(|schedule| allows(context, schedule))
                .map(|schedule| ctx.brief(schedule))
                .collect::<ApiResult<Vec<Value>>>()?;
            Ok(json!({ "schedules": schedules, "timezone": app.config.timezone }))
        }),
        Op::Result { id, offset } => with(app, |ctx| {
            let run = ctx.get_run(user, &id)?;
            if scoped(ctx, context, &run.schedule_id).is_err() {
                return Err(ApiError::not_found(format!(
                    "No run {id} in this workspace"
                )));
            }
            ctx.run_result(&run, offset.unwrap_or(0.0))
        }),
        Op::Create(mut input) => {
            if input.workspace.is_none() {
                input.workspace = Some(context.workspace.id.clone());
            }
            propose(app, context, *input, None)
        }
        Op::Update { id, input } => propose(app, context, *input, Some(id)),
        Op::Pause(id) => with(app, |ctx| {
            scoped(ctx, context, &id)?;
            let schedule = ctx.pause(user, &id)?;
            ctx.brief(&schedule)
        }),
        Op::Resume(id) => with(app, |ctx| {
            refuse_from_scheduled_run(ctx, context)?;
            scoped(ctx, context, &id)?;
            let schedule = ctx.resume(user, &id)?;
            ctx.brief(&schedule)
        }),
        // Deleting loses the schedule and its history: the user approves it (L10).
        Op::Delete(id) => with(app, |ctx| {
            if ctx.is_run_session(&context.session.id)? {
                return Err(ApiError::new(
                    403,
                    "forbidden",
                    "A scheduled run cannot delete schedules (nobody is there to approve it); pause it instead",
                ));
            }
            let schedule = scoped(ctx, context, &id)?;
            let proposal_id = ctx.propose_delete(user, &context.session, &schedule)?;
            Ok(json!({
                "id": id,
                "title": schedule.spec.title,
                "proposalId": proposal_id,
                "status": "pending_approval",
            }))
        }),
        Op::Run(id) => with(app, |ctx| {
            refuse_from_scheduled_run(ctx, context)?;
            scoped(ctx, context, &id)?;
            let run = ctx.run_now(user, &id, None)?;
            Ok(json!({ "runId": run.id, "status": run.status }))
        }),
    }
}

fn propose(
    app: &AppState,
    context: &OpContext,
    input: Input,
    schedule_id: Option<String>,
) -> ApiResult<Value> {
    let resolution = scope_resolution(app, context, input.workspace.as_deref());
    let resolver = move |_: &Connection, _: &str| -> ApiResult<Workspace> {
        resolution
            .clone()
            .unwrap_or_else(|| Err(ApiError::internal()))
    };
    with(app, |ctx| {
        refuse_from_scheduled_run(ctx, context)?;
        if let Some(id) = &schedule_id {
            scoped(ctx, context, id)?;
        }
        let (proposal_id, spec) = ctx.propose(
            &context.user,
            &context.session,
            &input,
            &resolver,
            schedule_id.as_deref(),
        )?;
        Ok(json!({ "proposalId": proposal_id, "status": "pending_approval", "title": spec.title }))
    })
}
