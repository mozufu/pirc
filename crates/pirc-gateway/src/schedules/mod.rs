//! Scheduled agent runs (`apps/gateway/src/daemon/schedules.ts`,
//! `schedule-routes.ts`, the schedule parts of `daemon/app.ts`;
//! docs/guides/schedules.md) and their agent operations (`schedule.*` in
//! `daemon/agent-ops.ts`).
//!
//! The gateway keeps each user's schedules and one timer for the earliest
//! due one. When one falls due it starts a new session in the schedule's
//! workspace, delivers the prompt as a `scheduled-run` custom message
//! (never the user's words), and follows the session until it finishes,
//! fails or waits for the user.
//!
//! Nothing runs that the user did not allow:
//! - schedules an agent proposes (or changes) wait for the user's approval
//!   in that session;
//! - a fire time the gateway slept through, or whose node was offline, is
//!   recorded as a `missed` run and only runs when the user allows it;
//! - a fire time while the previous run still goes is `skipped`.
//!
//! The TS class ran each method without interruption on one thread. Here
//! each runs with the database locked ([`with`]); what it sets off (hints,
//! events, pushes, dispatches) is collected and done once the lock is
//! released, in the same order.

mod api;
pub(crate) mod cron;
mod fields;
mod ops;
mod timer;

use axum::Router;
use rusqlite::{Connection, OptionalExtension, Row, params};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

use crate::app::{App, AppState};
use crate::db::{Capability, Session, Store, Workspace, atomic, sql_text_enum};
use crate::dispatch::{clip, one_line, redact_secrets, workspace_online};
use crate::error::{ApiError, ApiResult};
use crate::push::PushMessage;
use crate::util::{hex, now_ms, random_bytes};

pub use cron::{Zone, format_time};
pub use ops::{Op, parse_op, run_op};
pub(crate) use timer::arm;
pub use timer::start;

pub const THINKING_LEVELS: &[&str] = &["off", "minimal", "low", "medium", "high", "xhigh", "max"];
/// Which runs push a notification: every outcome, only the ones needing the user, or none.
pub const NOTIFY_LEVELS: &[&str] = &["all", "problems", "none"];

pub const PROMPT_MAX_CHARS: usize = 20_000;
const TITLE_MAX_CHARS: usize = 80;
/// Stored in full up to this sanity cap; readers page through it.
const RESULT_MAX_CHARS: usize = 200_000;
/// How much of each run's result the run list (UI) carries.
const RESULT_VIEW_CHARS: usize = 4000;
/// One `schedule` result read.
pub const RESULT_CHUNK_CHARS: usize = 12_000;
const PENDING_MAX: usize = 10;
const SCHEDULES_MAX: i64 = 100;
const RUNS_KEPT: i64 = 50;
/// A fire time the timer reaches later than this was slept through: missed, not run.
const DEFAULT_GRACE_MS: i64 = 120_000;
const OPEN_RUNS: &str = "('running','waiting_input')";

/// A schedule's `status` column.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ScheduleStatus {
    Active,
    Paused,
    /// A one-shot that fired (a new `runAt` makes it active again).
    Done,
}

impl ScheduleStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Active => "active",
            Self::Paused => "paused",
            Self::Done => "done",
        }
    }

    fn parse(text: &str) -> Option<Self> {
        match text {
            "active" => Some(Self::Active),
            "paused" => Some(Self::Paused),
            "done" => Some(Self::Done),
            _ => None,
        }
    }
}

/// A run's `status` column (`OPEN_RUNS` are `Running` and `WaitingInput`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum RunStatus {
    Running,
    WaitingInput,
    Completed,
    Failed,
    /// Due while the gateway was down or its node offline; the user allows
    /// or dismisses it.
    Missed,
    Dismissed,
    /// Due while the previous run was still going.
    Skipped,
}

impl RunStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Running => "running",
            Self::WaitingInput => "waiting_input",
            Self::Completed => "completed",
            Self::Failed => "failed",
            Self::Missed => "missed",
            Self::Dismissed => "dismissed",
            Self::Skipped => "skipped",
        }
    }

    fn parse(text: &str) -> Option<Self> {
        match text {
            "running" => Some(Self::Running),
            "waiting_input" => Some(Self::WaitingInput),
            "completed" => Some(Self::Completed),
            "failed" => Some(Self::Failed),
            "missed" => Some(Self::Missed),
            "dismissed" => Some(Self::Dismissed),
            "skipped" => Some(Self::Skipped),
            _ => None,
        }
    }

    /// Still going: the agent runs or waits for the user.
    pub fn is_open(self) -> bool {
        matches!(self, Self::Running | Self::WaitingInput)
    }
}

sql_text_enum!(ScheduleStatus);
sql_text_enum!(RunStatus);

/// `/api/schedules*`.
pub fn routes() -> Router<AppState> {
    api::routes()
}

/// Read-only calendar projection. Forecasts never dispatch or advance a task.
/// Only positively identified automatic runs share a forecast's identity.
pub fn calendar_projection(
    conn: &Connection,
    user: &str,
    from: i64,
    to: i64,
    now: i64,
    after: Option<&(i64, String)>,
    mut emit: impl FnMut(Value),
) -> ApiResult<()> {
    let mut statement = conn.prepare("SELECT * FROM schedules WHERE owner_user=? ORDER BY id")?;
    let schedules = statement
        .query_map([user], Schedule::from_row)?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    for schedule in schedules {
        let mut view = schedule.json();
        if let Ok(workspace) = conn.get_workspace(&schedule.spec.workspace_id) {
            view.insert("workspace".into(),json!({"id":workspace.id,"name":workspace.display_name,"kind":workspace.mode,"node":workspace.host_id}));
        }
        let mut recorded = std::collections::HashSet::new();
        let mut runs=conn.prepare("SELECT * FROM schedule_runs WHERE schedule_id=? AND owner_user=? AND due_at>=? AND due_at<? ORDER BY due_at,id")?;
        for result in runs.query_map(params![schedule.id, user, from, to], |r| {
            Ok((Run::from_row(r)?, r.get::<_, Option<String>>("origin")?))
        })? {
            let (run, origin) = result?;
            let id = if origin.as_deref() == Some("scheduled") {
                recorded.insert(run.due_at);
                format!("schedule:{}:{}", schedule.id, run.due_at)
            } else {
                format!("run:{}", run.id)
            };
            emit(
                json!({"id":id,"type":"schedule","sourceId":schedule.id,"title":schedule.spec.title,
                "startAt":run.due_at,"endAt":run.due_at,"allDay":false,"timezone":schedule.spec.timezone,
                "originalStart":run.due_at.to_string(),"revision":schedule.updated_at,"state":run.status,
                "schedule":view,"run":run.json(),"origin":origin}),
            );
        }
        if schedule.status != ScheduleStatus::Active {
            continue;
        }
        let mut last = from
            .max(now)
            .max(after.map_or(from, |v| v.0))
            .saturating_sub(1);
        let mut emitted = 0;
        while let Some(at) = fire(&schedule.spec, last)? {
            if at >= to {
                break;
            }
            if at <= last {
                return Err(ApiError::internal());
            }
            last = at;
            if recorded.contains(&at) {
                continue;
            }
            let id = format!("schedule:{}:{}", schedule.id, at);
            if after.is_some_and(|after| (at, id.clone()) <= *after) {
                continue;
            }
            emit(json!({"id":id,"type":"schedule","sourceId":schedule.id,
                "title":schedule.spec.title,"startAt":at,"endAt":at,"allDay":false,"timezone":schedule.spec.timezone,
                "originalStart":at.to_string(),"revision":schedule.updated_at,"state":"planned","schedule":view}));
            emitted += 1;
            // One more than a response page per source suffices to merge the
            // next global page. The caller returns an explicit continuation.
            if emitted > crate::calendar::PAGE_SIZE {
                break;
            }
        }
    }
    Ok(())
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ModelRef {
    pub provider: String,
    pub id: String,
}

/// What a schedule does and when; everything the user approves.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Spec {
    pub workspace_id: String,
    pub title: String,
    pub prompt: String,
    /// 5-field cron expression, or `None` for a one-shot.
    pub cron: Option<String>,
    /// The one-shot's time (ms), or `None` for cron.
    pub run_at: Option<i64>,
    /// IANA time zone the cron expression (or a one-shot's wall time) is read in.
    pub timezone: String,
    pub model: Option<ModelRef>,
    pub thinking: Option<String>,
    pub notify: String,
}

#[derive(Clone, Debug)]
pub struct Schedule {
    pub id: String,
    pub owner_user: String,
    pub spec: Spec,
    pub status: ScheduleStatus,
    pub next_run_at: Option<i64>,
    /// The chat whose agent proposed it; `None` when the user made it.
    pub created_by_session: Option<String>,
    pub created_at: i64,
    pub updated_at: i64,
}

impl Schedule {
    fn from_row(row: &Row<'_>) -> rusqlite::Result<Self> {
        let model: Option<String> = row.get("model_json")?;
        Ok(Self {
            id: row.get("id")?,
            owner_user: row.get("owner_user")?,
            spec: Spec {
                workspace_id: row.get("workspace_id")?,
                title: row.get("title")?,
                prompt: row.get("prompt")?,
                cron: row.get("cron")?,
                run_at: row.get("run_at")?,
                timezone: row.get("timezone")?,
                model: model
                    .filter(|text| !text.is_empty())
                    .and_then(|text| serde_json::from_str(&text).ok()),
                thinking: row.get("thinking")?,
                notify: row
                    .get::<_, Option<String>>("notify")?
                    .unwrap_or_else(|| "all".into()),
            },
            status: row.get("status")?,
            next_run_at: row.get("next_run_at")?,
            created_by_session: row.get("created_by_session")?,
            created_at: row.get("created_at")?,
            updated_at: row.get("updated_at")?,
        })
    }

    /// The schedule as clients see it (`Schedule` in the TS gateway).
    fn json(&self) -> Map<String, Value> {
        let spec = &self.spec;
        let value = json!({
            "id": self.id,
            "ownerUser": self.owner_user,
            "workspaceId": spec.workspace_id,
            "title": spec.title,
            "prompt": spec.prompt,
            "cron": spec.cron,
            "runAt": spec.run_at,
            "timezone": spec.timezone,
            "model": spec.model,
            "thinking": spec.thinking,
            "notify": spec.notify,
            "status": self.status,
            "nextRunAt": self.next_run_at,
            "createdBySession": self.created_by_session,
            "createdAt": self.created_at,
            "updatedAt": self.updated_at,
        });
        match value {
            Value::Object(map) => map,
            _ => Map::new(),
        }
    }
}

#[derive(Clone, Debug)]
pub struct Run {
    pub id: String,
    pub schedule_id: String,
    pub owner_user: String,
    /// The fire time it belongs to (for a manual run, when it was asked for).
    pub due_at: i64,
    pub status: RunStatus,
    pub session_id: Option<String>,
    pub result: Option<String>,
    pub started_at: Option<i64>,
    pub finished_at: Option<i64>,
    pub created_at: i64,
}

impl Run {
    fn from_row(row: &Row<'_>) -> rusqlite::Result<Self> {
        Ok(Self {
            id: row.get("id")?,
            schedule_id: row.get("schedule_id")?,
            owner_user: row.get("owner_user")?,
            due_at: row.get("due_at")?,
            status: row.get("status")?,
            session_id: row.get("session_id")?,
            result: row.get("result")?,
            started_at: row.get("started_at")?,
            finished_at: row.get("finished_at")?,
            created_at: row.get("created_at")?,
        })
    }

    fn json(&self) -> Map<String, Value> {
        let value = json!({
            "id": self.id,
            "scheduleId": self.schedule_id,
            "ownerUser": self.owner_user,
            "dueAt": self.due_at,
            "status": self.status,
            "sessionId": self.session_id,
            "result": self.result,
            "startedAt": self.started_at,
            "finishedAt": self.finished_at,
            "createdAt": self.created_at,
        });
        match value {
            Value::Object(map) => map,
            _ => Map::new(),
        }
    }
}

#[derive(Clone, Debug)]
struct Proposal {
    id: String,
    owner_user: String,
    session_id: String,
    schedule_id: Option<String>,
    spec: Spec,
    /// Approving deletes `schedule_id` (and `spec` is what it was) instead
    /// of saving `spec`.
    delete: bool,
    status: String,
    expires_at: i64,
    created_at: i64,
}

/// A change to a schedule, as the user, the UI or an agent writes it.
#[derive(Clone, Debug, Default)]
pub struct Input {
    /// Workspace id (or, for agents, a directory workspace's unique name).
    pub workspace: Option<String>,
    pub title: Option<String>,
    pub prompt: Option<String>,
    pub cron: Option<String>,
    /// One-shot time: ISO 8601; without an offset it is wall time in `timezone`.
    pub at: Option<String>,
    pub timezone: Option<String>,
    /// `Some(None)`: cleared.
    pub model: Option<Option<ModelRef>>,
    pub thinking: Option<Option<String>>,
    pub notify: Option<String>,
}

/// UTF-16 length, as JavaScript counts.
fn units(text: &str) -> usize {
    text.encode_utf16().count()
}

fn invalid(message: impl Into<String>) -> ApiError {
    ApiError::new(400, "invalid_input", message)
}

fn zone_of(timezone: &str) -> Option<Zone> {
    Zone::parse(timezone)
}

/// The next fire time strictly after `from`, or `None` when there is none;
/// `Err` with croner's message for a bad expression.
pub fn next_fire(spec: &Spec, from: i64) -> Result<Option<i64>, String> {
    match &spec.cron {
        Some(expression) => {
            let zone = zone_of(&spec.timezone).ok_or_else(|| {
                format!(
                    "CronDate: Failed to convert date to timezone '{}'.",
                    spec.timezone
                )
            })?;
            cron::Cron::new(expression, zone)
                .map(|cron| cron.next_run(from, zone))
                .map_err(|error| error.0)
        }
        None => Ok(spec.run_at.filter(|at| *at > from)),
    }
}

/// [`next_fire`] where the expression was checked before: a failure is internal.
fn fire(spec: &Spec, from: i64) -> ApiResult<Option<i64>> {
    next_fire(spec, from).map_err(|message| {
        crate::log::error(&format!("schedule fire time: {message}"));
        ApiError::internal()
    })
}

/// `formatTime` with the spec's zone (UTC if it no longer parses).
fn format_in(at: i64, timezone: &str) -> String {
    format_time(at, zone_of(timezone).unwrap_or(Zone::Fixed(0)), timezone)
}

fn run_message(schedule: &Schedule, run: &Run) -> String {
    format!(
        "Scheduled task “{}” (schedule {}, due {}), set up and approved by the user. Nobody is watching this session live:\n\n{}\n\nDo it here. End with a short summary of what you did and anything that needs the user: they read it in the schedule's run history.",
        schedule.spec.title,
        schedule.id,
        format_in(run.due_at, &schedule.spec.timezone),
        schedule.spec.prompt
    )
}

// ---------- effects ----------

/// What a method sets off, done after the database is unlocked.
enum Effect {
    /// The user's schedules or runs changed: clients reload (`schedules=1`).
    Hint(String),
    /// Re-arm the timer.
    Arm,
    Event {
        session_id: String,
        epoch: i64,
        kind: &'static str,
        data: Value,
    },
    Push(String, PushMessage),
    Dispatch(Box<(Schedule, Run, Workspace)>),
}

#[derive(Default)]
struct Fx(Vec<Effect>);

impl Fx {
    fn hint(&mut self, user: &str) {
        self.0.push(Effect::Hint(user.to_owned()));
    }

    /// `this.changed(user)`: the hint, and the timer re-armed.
    fn changed(&mut self, user: &str) {
        self.hint(user);
        self.0.push(Effect::Arm);
    }
}

fn apply_effects(app: &AppState, fx: Fx) {
    for effect in fx.0 {
        match effect {
            Effect::Hint(user) => app.schedules_changed(&user),
            Effect::Arm => timer::arm(app),
            Effect::Event {
                session_id,
                epoch,
                kind,
                data,
            } => {
                app.events.publish(&session_id, epoch, kind, data);
            }
            Effect::Push(user, message) => crate::push::notify(app, &user, message),
            Effect::Dispatch(job) => {
                let (schedule, run, workspace) = *job;
                tokio::spawn(timer::dispatch(app.clone(), schedule, run, workspace));
            }
        }
    }
}

/// Run `body` with the database locked, then do what it set off (also
/// when it failed partway, as the TS code had done it by then).
fn with<T>(app: &AppState, body: impl FnOnce(&mut Ctx<'_>) -> ApiResult<T>) -> ApiResult<T> {
    let mut fx = Fx::default();
    let result = {
        let conn = app.db.lock();
        let mut ctx = Ctx {
            app,
            conn: &conn,
            fx: &mut fx,
        };
        body(&mut ctx)
    };
    apply_effects(app, fx);
    result
}

/// [`with`] for reads that set nothing off.
fn read<T>(app: &App, body: impl FnOnce(&mut Ctx<'_>) -> ApiResult<T>) -> ApiResult<T> {
    let mut fx = Fx::default();
    let conn = app.db.lock();
    let mut ctx = Ctx {
        app,
        conn: &conn,
        fx: &mut fx,
    };
    let result = body(&mut ctx);
    debug_assert!(fx.0.is_empty(), "a read set something off");
    result
}

/// Finds the workspace a reference names.
type Resolver<'a> = &'a dyn Fn(&Connection, &str) -> ApiResult<Workspace>;

/// The scheduler's methods over one locked connection.
struct Ctx<'a> {
    app: &'a App,
    conn: &'a Connection,
    fx: &'a mut Fx,
}

impl Ctx<'_> {
    // ---------- reading ----------

    fn row(&self, id: &str) -> ApiResult<Option<Schedule>> {
        Ok(self
            .conn
            .query_row(
                "SELECT * FROM schedules WHERE id=?",
                [id],
                Schedule::from_row,
            )
            .optional()?)
    }

    fn run_row(&self, id: &str) -> ApiResult<Option<Run>> {
        Ok(self
            .conn
            .query_row(
                "SELECT * FROM schedule_runs WHERE id=?",
                [id],
                Run::from_row,
            )
            .optional()?)
    }

    fn get(&self, user: &str, id: &str) -> ApiResult<Schedule> {
        match self.row(id)? {
            Some(schedule) if schedule.owner_user == user => Ok(schedule),
            _ => Err(ApiError::not_found(format!("No schedule {id}"))),
        }
    }

    fn list(&self, user: &str) -> ApiResult<Vec<Schedule>> {
        let mut statement = self
            .conn
            .prepare("SELECT * FROM schedules WHERE owner_user=? ORDER BY created_at")?;
        let rows = statement.query_map([user], Schedule::from_row)?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    /// Newest first.
    fn runs(&self, user: &str, schedule_id: &str) -> ApiResult<Vec<Run>> {
        self.get(user, schedule_id)?;
        let mut statement = self.conn.prepare(
            "SELECT * FROM schedule_runs WHERE schedule_id=? ORDER BY created_at DESC, rowid DESC LIMIT ?",
        )?;
        let rows = statement.query_map(params![schedule_id, RUNS_KEPT], Run::from_row)?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    fn last_run(&self, schedule_id: &str) -> ApiResult<Option<Run>> {
        Ok(self
            .conn
            .query_row(
                "SELECT * FROM schedule_runs WHERE schedule_id=? ORDER BY created_at DESC, rowid DESC LIMIT 1",
                [schedule_id],
                Run::from_row,
            )
            .optional()?)
    }

    /// A session a scheduled run started: its agent may not schedule more.
    fn is_run_session(&self, session_id: &str) -> ApiResult<bool> {
        Ok(self
            .conn
            .query_row(
                "SELECT 1 FROM schedule_runs WHERE session_id=? LIMIT 1",
                [session_id],
                |_| Ok(()),
            )
            .optional()?
            .is_some())
    }

    /// What clients show of a schedule.
    fn view(&self, schedule: &Schedule) -> ApiResult<Value> {
        let last = self.last_run(&schedule.id)?;
        let attention: i64 = self.conn.query_row(
            "SELECT COUNT(*) AS n FROM schedule_runs WHERE schedule_id=? AND status IN ('missed','waiting_input')",
            [&schedule.id],
            |row| row.get(0),
        )?;
        let mut view = schedule.json();
        view.insert(
            "workspace".into(),
            self.workspace_view(&schedule.spec.workspace_id),
        );
        view.insert(
            "lastRun".into(),
            match last {
                Some(run) => self.run_view(&run),
                None => Value::Null,
            },
        );
        // Runs waiting for the user: missed ones to allow, and ones waiting for an answer.
        view.insert("attention".into(), json!(attention));
        Ok(Value::Object(view))
    }

    fn run_view(&self, run: &Run) -> Value {
        let mut view = run.json();
        if let Some(result) = &run.result {
            let length = units(result);
            if length > RESULT_VIEW_CHARS {
                view.insert("result".into(), json!(clip(result, RESULT_VIEW_CHARS)));
                view.insert("resultChars".into(), json!(length));
            }
        }
        view.insert(
            "session".into(),
            match &run.session_id {
                Some(session_id) => json!(self.session_name(session_id)),
                None => Value::Null,
            },
        );
        Value::Object(view)
    }

    /// The user's run `id`, owner-checked.
    fn get_run(&self, user: &str, id: &str) -> ApiResult<Run> {
        match self.run_row(id)? {
            Some(run) if run.owner_user == user => Ok(run),
            _ => Err(ApiError::not_found(format!("No run {id}"))),
        }
    }

    /// A run's result from `offset`, in chunks, with `nextOffset` until the end.
    fn run_result(&self, run: &Run, offset: f64) -> ApiResult<Value> {
        let result: Vec<u16> = run.result.as_deref().unwrap_or("").encode_utf16().collect();
        let length = result.len();
        if offset > length as f64 {
            return Err(invalid(format!("offset exceeds result length {length}")));
        }
        let offset = offset as usize;
        let end = length.min(offset + RESULT_CHUNK_CHARS);
        let mut body = Map::new();
        body.insert("id".into(), json!(run.id));
        body.insert("schedule".into(), json!(run.schedule_id));
        body.insert("status".into(), json!(run.status));
        if let Some(session_id) = &run.session_id {
            body.insert("session".into(), json!(self.session_name(session_id)));
        }
        body.insert(
            "result".into(),
            json!(String::from_utf16_lossy(&result[offset..end])),
        );
        body.insert("resultOffset".into(), json!(offset));
        body.insert("resultChars".into(), json!(length));
        if end < length {
            body.insert("nextOffset".into(), json!(end));
        }
        Ok(Value::Object(body))
    }

    /// What an agent sees of a schedule.
    fn brief(&self, schedule: &Schedule) -> ApiResult<Value> {
        let spec = &schedule.spec;
        let last = self.last_run(&schedule.id)?;
        let mut brief = Map::new();
        brief.insert("id".into(), json!(schedule.id));
        brief.insert("title".into(), json!(spec.title));
        brief.insert("workspace".into(), json!(self.label(&spec.workspace_id)));
        brief.insert("when".into(), json!(describe_when(spec)));
        brief.insert("status".into(), json!(schedule.status));
        if let Some(next) = schedule.next_run_at {
            brief.insert("nextRun".into(), json!(format_in(next, &spec.timezone)));
        }
        if let Some(model) = &spec.model {
            brief.insert(
                "model".into(),
                json!(format!("{}/{}", model.provider, model.id)),
            );
        }
        if let Some(thinking) = spec.thinking.as_ref().filter(|t| !t.is_empty()) {
            brief.insert("thinking".into(), json!(thinking));
        }
        if spec.notify != "all" {
            brief.insert("notify".into(), json!(spec.notify));
        }
        brief.insert("prompt".into(), json!(clip(&spec.prompt, 300)));
        if let Some(last) = last {
            let mut run = Map::new();
            run.insert("id".into(), json!(last.id));
            run.insert("status".into(), json!(last.status));
            run.insert("due".into(), json!(format_in(last.due_at, &spec.timezone)));
            if let Some(result) = last.result.as_ref().filter(|r| !r.is_empty()) {
                run.insert("result".into(), json!(clip(result, 300)));
                if units(result) > 300 {
                    run.insert("resultChars".into(), json!(units(result)));
                }
            }
            brief.insert("lastRun".into(), Value::Object(run));
        }
        Ok(Value::Object(brief))
    }

    // ---------- validation ----------

    /// The spec `input` makes of `base` (or a new one). Fails on anything
    /// that would not run: a bad expression, time zone or model, a one-shot
    /// in the past.
    fn resolve(
        &self,
        user: &str,
        input: &Input,
        base: Option<&Spec>,
        resolve_workspace: Resolver<'_>,
        redact: bool,
    ) -> ApiResult<Spec> {
        let text = |value: &Option<String>| -> Option<String> {
            value.as_ref().map(|value| {
                let value = if redact {
                    redact_secrets(value)
                } else {
                    value.clone()
                };
                cron::js_trim(&value).to_owned()
            })
        };
        let prompt = text(&input.prompt)
            .or_else(|| base.map(|base| base.prompt.clone()))
            .unwrap_or_default();
        if prompt.is_empty() {
            return Err(invalid("prompt is required"));
        }
        if units(&prompt) > PROMPT_MAX_CHARS {
            return Err(ApiError::new(
                413,
                "payload_too_large",
                format!("A prompt holds at most {PROMPT_MAX_CHARS} characters"),
            ));
        }
        let timezone = input
            .timezone
            .as_deref()
            .map(cron::js_trim)
            .filter(|zone| !zone.is_empty())
            .map(str::to_owned)
            .or_else(|| {
                base.map(|base| base.timezone.clone())
                    .filter(|zone| !zone.is_empty())
            })
            .unwrap_or_else(|| self.app.config.timezone.clone());
        let Some(zone) = zone_of(&timezone) else {
            return Err(invalid(format!("Unknown time zone {timezone}")));
        };

        let mut workspace_id = base.map(|base| base.workspace_id.clone());
        if let Some(reference) = input
            .workspace
            .as_deref()
            .map(cron::js_trim)
            .filter(|reference| !reference.is_empty())
        {
            workspace_id = Some(resolve_workspace(self.conn, reference)?.id);
        }
        let Some(workspace_id) = workspace_id.filter(|id| !id.is_empty()) else {
            return Err(invalid("workspace is required"));
        };
        if !self.app.config.auth.allowed_users.contains(user) {
            return Err(ApiError::new(403, "forbidden", "Not allowed"));
        }

        let cron_input = input
            .cron
            .as_deref()
            .map(cron::js_trim)
            .filter(|text| !text.is_empty());
        let at_input = input
            .at
            .as_deref()
            .map(cron::js_trim)
            .filter(|text| !text.is_empty());
        if cron_input.is_some() && at_input.is_some() {
            return Err(invalid("Give either cron or at, not both"));
        }
        let mut cron_text = base.and_then(|base| base.cron.clone());
        let mut run_at = base.and_then(|base| base.run_at);
        if let Some(expression) = cron_input {
            if cron::field_count(expression) != 5 {
                return Err(invalid(
                    "cron needs 5 fields: minute hour day-of-month month day-of-week",
                ));
            }
            cron_text = Some(expression.to_owned());
            run_at = None;
        } else if let Some(at) = at_input {
            run_at = Some(parse_at(at, zone)?);
            cron_text = None;
        } else if run_at.is_some()
            && let (Some(given), Some(base)) = (
                input.timezone.as_deref().filter(|zone| !zone.is_empty()),
                base,
            )
            && given != base.timezone
        {
            return Err(invalid(
                "Changing the time zone of a one-shot needs its time (at) again",
            ));
        }
        if cron_text.is_none() && run_at.is_none() {
            return Err(invalid("Give cron (repeating) or at (once)"));
        }
        let now = now_ms();
        if let Some(expression) = &cron_text {
            let probe = Spec {
                workspace_id: String::new(),
                title: String::new(),
                prompt: String::new(),
                cron: Some(expression.clone()),
                run_at: None,
                timezone: timezone.clone(),
                model: None,
                thinking: None,
                notify: String::new(),
            };
            match next_fire(&probe, now) {
                Ok(Some(_)) => {}
                Ok(None) => return Err(invalid(format!("cron \"{expression}\" never fires"))),
                Err(message) => {
                    return Err(invalid(format!("Invalid cron \"{expression}\": {message}")));
                }
            }
        } else if let Some(at) = run_at.filter(|at| *at <= now) {
            return Err(invalid(format!(
                "{} is in the past",
                format_time(at, zone, &timezone)
            )));
        }

        let model = match &input.model {
            None => base.and_then(|base| base.model.clone()),
            Some(model) => model.clone(),
        };
        if let Some(model) = &model {
            let known = self
                .app
                .models()
                .providers
                .get(&model.provider)
                .is_some_and(|provider| provider.models.iter().any(|m| m.id == model.id));
            if !known {
                return Err(invalid(format!(
                    "Unknown model {}/{}",
                    model.provider, model.id
                )));
            }
        }
        let thinking = match &input.thinking {
            None => base.and_then(|base| base.thinking.clone()),
            Some(thinking) => thinking.clone(),
        };
        if let Some(thinking) = &thinking
            && !THINKING_LEVELS.contains(&thinking.as_str())
        {
            return Err(invalid(format!(
                "thinking is one of {}",
                THINKING_LEVELS.join(", ")
            )));
        }

        let title = text(&input.title)
            .filter(|title| !title.is_empty())
            .or_else(|| {
                base.map(|base| base.title.clone())
                    .filter(|title| !title.is_empty())
            })
            .unwrap_or_else(|| prompt.split('\n').next().unwrap_or_default().to_owned());
        let title = clip(&one_line(&title), TITLE_MAX_CHARS);
        let notify = input
            .notify
            .clone()
            .or_else(|| base.map(|base| base.notify.clone()))
            .unwrap_or_else(|| "all".into());
        if !NOTIFY_LEVELS.contains(&notify.as_str()) {
            return Err(invalid(format!(
                "notify is one of {}",
                NOTIFY_LEVELS.join(", ")
            )));
        }
        Ok(Spec {
            workspace_id,
            title,
            prompt,
            cron: cron_text,
            run_at,
            timezone,
            model,
            thinking,
            notify,
        })
    }

    // ---------- changing schedules ----------

    /// The user makes a schedule directly (web, Android, slash command).
    fn create(
        &mut self,
        user: &str,
        input: &Input,
        resolve_workspace: Resolver<'_>,
    ) -> ApiResult<Schedule> {
        let count: i64 = self.conn.query_row(
            "SELECT COUNT(*) AS n FROM schedules WHERE owner_user=?",
            [user],
            |row| row.get(0),
        )?;
        if count >= SCHEDULES_MAX {
            return Err(ApiError::new(
                429,
                "too_many_requests",
                format!("At most {SCHEDULES_MAX} schedules"),
            ));
        }
        let spec = self.resolve(user, input, None, resolve_workspace, false)?;
        // A workspace with schedules disabled runs none, whoever creates them.
        self.conn
            .require_workspace_capability(&spec.workspace_id, Capability::Schedules)?;
        self.insert(user, &spec, None)
    }

    fn update(
        &mut self,
        user: &str,
        id: &str,
        input: &Input,
        resolve_workspace: Resolver<'_>,
    ) -> ApiResult<Schedule> {
        let schedule = self.get(user, id)?;
        let spec = self.resolve(user, input, Some(&schedule.spec), resolve_workspace, false)?;
        self.conn
            .require_workspace_capability(&spec.workspace_id, Capability::Schedules)?;
        self.apply(&schedule, &spec)
    }

    fn pause(&mut self, user: &str, id: &str) -> ApiResult<Schedule> {
        let schedule = self.get(user, id)?;
        if schedule.status == ScheduleStatus::Active {
            self.set_status(&schedule, ScheduleStatus::Paused, schedule.next_run_at)?;
        }
        self.must_row(id)
    }

    /// Runs again from now on; fire times while paused are not made up.
    fn resume(&mut self, user: &str, id: &str) -> ApiResult<Schedule> {
        let schedule = self.get(user, id)?;
        if schedule.status == ScheduleStatus::Active {
            return Ok(schedule);
        }
        self.require_capability(&schedule)?;
        let Some(next) = fire(&schedule.spec, now_ms())? else {
            return Err(ApiError::new(
                409,
                "conflict",
                "Its one-shot time has passed: give it a new time (at) instead",
            ));
        };
        self.set_status(&schedule, ScheduleStatus::Active, Some(next))?;
        self.must_row(id)
    }

    /// Deletes the schedule and its history; sessions it started stay.
    fn delete(&mut self, user: &str, id: &str) -> ApiResult<()> {
        let schedule = self.get(user, id)?;
        atomic(self.conn, |conn| {
            conn.execute("DELETE FROM schedule_runs WHERE schedule_id=?", [id])?;
            conn.execute("DELETE FROM schedules WHERE id=?", [id])?;
            Ok(())
        })?;
        for proposal in self.proposal_rows("schedule_id=? AND status='pending'", &[&id])? {
            self.close_proposal(&proposal, "expired")?;
        }
        self.fx.changed(&schedule.owner_user);
        Ok(())
    }

    fn must_row(&self, id: &str) -> ApiResult<Schedule> {
        self.row(id)?
            .ok_or_else(|| ApiError::not_found(format!("No schedule {id}")))
    }

    fn insert(
        &mut self,
        user: &str,
        spec: &Spec,
        created_by_session: Option<&str>,
    ) -> ApiResult<Schedule> {
        let id = self.new_id("schedules", "s")?;
        let at = now_ms();
        self.conn.execute(
            "INSERT INTO schedules (id,owner_user,workspace_id,title,prompt,cron,run_at,timezone,model_json,thinking,notify,status,next_run_at,created_by_session,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,'active',?,?,?,?)",
            params![
                id,
                user,
                spec.workspace_id,
                spec.title,
                spec.prompt,
                spec.cron,
                spec.run_at,
                spec.timezone,
                model_json(spec),
                spec.thinking,
                spec.notify,
                fire(spec, at)?,
                created_by_session,
                at,
                at,
            ],
        )?;
        self.fx.changed(user);
        self.must_row(&id)
    }

    fn apply(&mut self, schedule: &Schedule, spec: &Spec) -> ApiResult<Schedule> {
        // A new one-shot time makes a finished one-shot active again.
        let status = if schedule.status == ScheduleStatus::Done {
            ScheduleStatus::Active
        } else {
            schedule.status
        };
        self.conn.execute(
            "UPDATE schedules SET workspace_id=?,title=?,prompt=?,cron=?,run_at=?,timezone=?,model_json=?,thinking=?,notify=?,status=?,next_run_at=?,updated_at=? WHERE id=?",
            params![
                spec.workspace_id,
                spec.title,
                spec.prompt,
                spec.cron,
                spec.run_at,
                spec.timezone,
                model_json(spec),
                spec.thinking,
                spec.notify,
                status,
                fire(spec, now_ms())?,
                now_ms(),
                schedule.id,
            ],
        )?;
        self.fx.changed(&schedule.owner_user);
        self.must_row(&schedule.id)
    }

    fn set_status(
        &mut self,
        schedule: &Schedule,
        status: ScheduleStatus,
        next_run_at: Option<i64>,
    ) -> ApiResult<()> {
        self.conn.execute(
            "UPDATE schedules SET status=?, next_run_at=?, updated_at=? WHERE id=?",
            params![status, next_run_at, now_ms(), schedule.id],
        )?;
        self.fx.changed(&schedule.owner_user);
        Ok(())
    }

    // ---------- an agent's proposals ----------

    /// An agent proposes a schedule (or a change to `schedule_id`); the user
    /// approves it in `session`'s chat. Validated now, so the agent hears of
    /// mistakes at once; nothing changes before the user says yes.
    fn propose(
        &mut self,
        user: &str,
        session: &Session,
        input: &Input,
        resolve_workspace: Resolver<'_>,
        schedule_id: Option<&str>,
    ) -> ApiResult<(String, Spec)> {
        let base = match schedule_id {
            Some(id) => Some(self.get(user, id)?),
            None => None,
        };
        let spec = self.resolve(
            user,
            input,
            base.as_ref().map(|base| &base.spec),
            resolve_workspace,
            true,
        )?;
        let id = self.insert_proposal(user, session, schedule_id, &spec, "save")?;
        Ok((id, spec))
    }

    /// An agent proposes deleting `schedule` (L10); the user approves it in
    /// `session`'s chat, and nothing is deleted before.
    fn propose_delete(
        &mut self,
        user: &str,
        session: &Session,
        schedule: &Schedule,
    ) -> ApiResult<String> {
        self.insert_proposal(user, session, Some(&schedule.id), &schedule.spec, "delete")
    }

    fn insert_proposal(
        &mut self,
        user: &str,
        session: &Session,
        schedule_id: Option<&str>,
        spec: &Spec,
        operation: &str,
    ) -> ApiResult<String> {
        let waiting = self
            .proposal_rows("owner_user=? AND status='pending'", &[&user])?
            .len();
        if waiting >= PENDING_MAX {
            return Err(ApiError::new(
                429,
                "too_many_requests",
                format!("{waiting} schedule proposals already wait for the user's approval"),
            ));
        }
        let id = self.new_id("schedule_proposals", "p")?;
        let at = now_ms();
        self.conn.execute(
            "INSERT INTO schedule_proposals (id,owner_user,session_id,schedule_id,spec_json,status,expires_at,created_at,operation) VALUES (?,?,?,?,?,'pending',?,?,?)",
            params![
                id,
                user,
                session.id,
                schedule_id,
                serde_json::to_string(spec).unwrap_or_default(),
                at + self.app.config.proposal_ttl_ms as i64,
                at,
                operation,
            ],
        )?;
        let proposal = self
            .proposal_rows("id=?", &[&id])?
            .into_iter()
            .next()
            .ok_or_else(ApiError::internal)?;
        let data = self.interaction_of(&proposal)?;
        self.fx.0.push(Effect::Event {
            session_id: session.id.clone(),
            epoch: session.runner_epoch,
            kind: "interaction_created",
            data,
        });
        Ok(id)
    }

    /// Confirmations waiting in a chat, shaped like a node's interactions.
    fn pending_interactions(&self, session_id: &str) -> ApiResult<Vec<Value>> {
        self.proposal_rows(
            "session_id=? AND status='pending' AND expires_at>?",
            &[&session_id, &now_ms()],
        )?
        .iter()
        .map(|proposal| self.interaction_of(proposal))
        .collect()
    }

    /// The user answered a confirmation in chat `session_id`. `None` when
    /// `interaction_id` is not one of this chat's proposals.
    fn answer(
        &mut self,
        session_id: &str,
        interaction_id: &str,
        user: &str,
        answer: Option<&Value>,
    ) -> ApiResult<Option<Value>> {
        let Some(proposal) = self
            .proposal_rows("id=?", &[&interaction_id])?
            .into_iter()
            .next()
        else {
            return Ok(None);
        };
        if proposal.session_id != session_id {
            return Ok(None);
        }
        if proposal.owner_user != user {
            return Err(ApiError::new(
                403,
                "forbidden",
                "Schedule belongs to another user",
            ));
        }
        if proposal.status != "pending" || proposal.expires_at <= now_ms() {
            return Err(ApiError::new(
                409,
                "stale_interaction",
                "This schedule can no longer be answered",
            ));
        }
        let approved =
            answer.and_then(|answer| answer.get("confirmed")) == Some(&Value::Bool(true));
        if !approved {
            self.close_proposal(&proposal, "rejected")?;
            return Ok(Some(
                json!({ "interactionId": interaction_id, "status": "answered" }),
            ));
        }
        self.conn
            .require_session_capability(session_id, Capability::Schedules)?;
        if proposal.delete {
            let id = proposal.schedule_id.clone().unwrap_or_default();
            // Closed first: deleting expires the schedule's pending proposals.
            self.close_proposal(&proposal, "approved")?;
            self.delete(user, &id).map_err(|error| {
                if error.status == 500 {
                    error
                } else {
                    ApiError::new(
                        409,
                        "conflict",
                        format!("Could not delete the schedule: {}", error.message),
                    )
                }
            })?;
            return Ok(Some(json!({
                "interactionId": interaction_id,
                "status": "answered",
                "scheduleId": id,
                "deleted": true,
            })));
        }
        let saved = match &proposal.schedule_id {
            Some(schedule_id) => self.get(user, schedule_id).and_then(|current| {
                let spec = self.recheck(user, &proposal.spec)?;
                self.apply(&current, &spec)
            }),
            None => self
                .recheck(user, &proposal.spec)
                .and_then(|spec| self.insert(user, &spec, Some(session_id))),
        };
        let schedule = match saved {
            Ok(schedule) => schedule,
            Err(error) => {
                self.close_proposal(&proposal, "rejected")?;
                // Storage failures stay internal, as a thrown non-ApiError did.
                if error.status == 500 {
                    return Err(error);
                }
                return Err(ApiError::new(
                    409,
                    "conflict",
                    format!("Could not save the schedule: {}", error.message),
                ));
            }
        };
        self.close_proposal(&proposal, "approved")?;
        Ok(Some(json!({
            "interactionId": interaction_id,
            "status": "answered",
            "scheduleId": schedule.id,
        })))
    }

    /// The approved spec still holds (a one-shot may have passed while it waited).
    fn recheck(&self, user: &str, spec: &Spec) -> ApiResult<Spec> {
        let workspace_id = spec.workspace_id.clone();
        self.resolve(
            user,
            &Input::default(),
            Some(spec),
            &move |conn: &Connection, _: &str| conn.get_workspace(&workspace_id),
            false,
        )
    }

    fn sweep(&mut self) -> ApiResult<()> {
        for proposal in self.proposal_rows("status='pending' AND expires_at<=?", &[&now_ms()])? {
            self.close_proposal(&proposal, "expired")?;
        }
        Ok(())
    }

    fn close_proposal(&mut self, proposal: &Proposal, status: &str) -> ApiResult<()> {
        let changed = self.conn.execute(
            "UPDATE schedule_proposals SET status=? WHERE id=? AND status='pending'",
            params![status, proposal.id],
        )?;
        if changed == 0 {
            return Ok(());
        }
        // The chat may be gone.
        if let Ok(chat) = self.conn.get_session(&proposal.session_id) {
            self.fx.0.push(Effect::Event {
                session_id: chat.id,
                epoch: chat.runner_epoch,
                kind: "interaction_answered",
                data: json!({ "interactionId": proposal.id, "interactionEpoch": 0 }),
            });
        }
        Ok(())
    }

    fn proposal_rows(
        &self,
        filter: &str,
        values: &[&dyn rusqlite::ToSql],
    ) -> ApiResult<Vec<Proposal>> {
        let mut statement = self.conn.prepare(&format!(
            "SELECT * FROM schedule_proposals WHERE {filter} ORDER BY created_at"
        ))?;
        let rows = statement.query_map(values, |row| {
            Ok((
                Proposal {
                    id: row.get("id")?,
                    owner_user: row.get("owner_user")?,
                    session_id: row.get("session_id")?,
                    schedule_id: row.get("schedule_id")?,
                    spec: Spec {
                        workspace_id: String::new(),
                        title: String::new(),
                        prompt: String::new(),
                        cron: None,
                        run_at: None,
                        timezone: String::new(),
                        model: None,
                        thinking: None,
                        notify: String::new(),
                    },
                    delete: row.get::<_, String>("operation")? == "delete",
                    status: row.get("status")?,
                    expires_at: row.get("expires_at")?,
                    created_at: row.get("created_at")?,
                },
                row.get::<_, String>("spec_json")?,
            ))
        })?;
        let mut proposals = Vec::new();
        for row in rows {
            let (mut proposal, spec) = row?;
            proposal.spec = serde_json::from_str(&spec).map_err(|error| {
                crate::log::error(&format!("schedule proposal {}: {error}", proposal.id));
                ApiError::internal()
            })?;
            proposals.push(proposal);
        }
        Ok(proposals)
    }

    fn interaction_of(&self, proposal: &Proposal) -> ApiResult<Value> {
        let spec = &proposal.spec;
        let current = match &proposal.schedule_id {
            Some(id) => self.row(id)?,
            None => None,
        };
        if proposal.delete {
            let title = current
                .as_ref()
                .map_or(&spec.title, |current| &current.spec.title);
            let message = [
                title.clone(),
                String::new(),
                format!("Where: {}", self.label(&spec.workspace_id)),
                format!("When: {}", describe_when(spec)),
                String::new(),
                "The schedule and its run history are deleted; run sessions stay.".to_owned(),
            ]
            .join("\n");
            return Ok(json!({
                "id": proposal.id,
                "rpcId": proposal.id,
                "sessionId": proposal.session_id,
                "runnerEpoch": 0,
                "kind": "confirm",
                "status": "pending",
                "request": {
                    "method": "confirm",
                    "title": format!("Delete the schedule “{title}”?"),
                    "message": message,
                    "confirmLabel": "Delete",
                    "cancelLabel": "Keep it",
                },
                "expiresAt": proposal.expires_at,
                "createdAt": proposal.created_at,
            }));
        }
        let next = fire(spec, now_ms())?;
        let mut lines = vec![
            spec.title.clone(),
            String::new(),
            format!(
                "Where: {} (a new session each run)",
                self.label(&spec.workspace_id)
            ),
            format!(
                "When: {}{}",
                describe_when(spec),
                next.map(|next| format!("; next {}", format_in(next, &spec.timezone)))
                    .unwrap_or_default()
            ),
        ];
        let thinking = spec.thinking.as_ref().filter(|t| !t.is_empty());
        if spec.model.is_some() || thinking.is_some() {
            lines.push(format!(
                "Model: {}{}",
                spec.model
                    .as_ref()
                    .map(|model| format!("{}/{}", model.provider, model.id))
                    .unwrap_or_else(|| "default".into()),
                thinking
                    .map(|thinking| format!(", thinking {thinking}"))
                    .unwrap_or_default()
            ));
        }
        if spec.notify != "all" {
            lines.push(format!(
                "Notifications: {}",
                if spec.notify == "none" {
                    "none"
                } else {
                    "only when it needs you"
                }
            ));
        }
        lines.push(String::new());
        lines.push(spec.prompt.clone());
        Ok(json!({
            "id": proposal.id,
            "rpcId": proposal.id,
            "sessionId": proposal.session_id,
            "runnerEpoch": 0,
            "kind": "confirm",
            "status": "pending",
            "request": {
                "method": "confirm",
                "title": match &current {
                    Some(current) => format!("Change the schedule “{}”?", current.spec.title),
                    None => "Schedule this task?".to_owned(),
                },
                "message": lines.join("\n"),
                "confirmLabel": if current.is_some() { "Save" } else { "Schedule" },
                "cancelLabel": "Don't",
            },
            "expiresAt": proposal.expires_at,
            "createdAt": proposal.created_at,
        }))
    }

    // ---------- the timer ----------

    /// Handle every schedule that is due now.
    fn tick(&mut self, grace: i64) -> ApiResult<()> {
        let at = now_ms();
        let due: Vec<Schedule> = {
            let mut statement = self.conn.prepare(
                "SELECT * FROM schedules WHERE status='active' AND next_run_at IS NOT NULL AND next_run_at<=? ORDER BY next_run_at",
            )?;
            let rows = statement.query_map([at], Schedule::from_row)?;
            rows.collect::<rusqlite::Result<_>>()?
        };
        for schedule in due {
            if let Err(error) = self.fall(&schedule, at, grace) {
                crate::log::warn(&format!(
                    "schedule {}: could not handle its fire time: {}",
                    schedule.id, error.message
                ));
            }
        }
        self.fx.0.push(Effect::Arm);
        Ok(())
    }

    fn fall(&mut self, schedule: &Schedule, at: i64, grace: i64) -> ApiResult<()> {
        // A removal probe is temporary: leave its due time and history intact
        // until the probe either commits removal or rolls its fence back.
        let checking: bool = self.conn.query_row("SELECT EXISTS(SELECT 1 FROM workspace_removals WHERE workspace_id=? AND status='checking')", [&schedule.spec.workspace_id], |row| row.get(0))?;
        if checking {
            return Ok(());
        }
        let due_at = schedule.next_run_at.unwrap_or(at);
        // The latest fire time that has passed: several slept through count once.
        let mut latest = due_at;
        let mut next = fire(&schedule.spec, due_at)?;
        let mut i = 0;
        while let Some(time) = next.filter(|time| *time <= at && i < 10_000) {
            latest = time;
            next = fire(&schedule.spec, time)?;
            i += 1;
        }
        let next = fire(&schedule.spec, at)?;
        self.conn.execute(
            "UPDATE schedules SET next_run_at=?, status=?, updated_at=? WHERE id=?",
            params![
                next,
                if next.is_none() {
                    ScheduleStatus::Done
                } else {
                    ScheduleStatus::Active
                },
                at,
                schedule.id
            ],
        )?;

        let workspace = self.conn.get_workspace(&schedule.spec.workspace_id).ok();
        let allowed = self
            .app
            .config
            .auth
            .allowed_users
            .contains(&schedule.owner_user);
        if !allowed || workspace.is_none() {
            let result = if workspace.is_some() {
                "Its owner may no longer use the gateway; the schedule is paused."
            } else {
                "Its workspace no longer exists; the schedule is paused."
            };
            self.insert_run(
                schedule,
                latest,
                RunStatus::Failed,
                Some(result),
                None,
                Some(at),
            )?;
            return self.set_status(schedule, ScheduleStatus::Paused, next);
        }
        if at - latest > grace {
            self.insert_run(
                schedule,
                latest,
                RunStatus::Missed,
                Some("The gateway was not running at this time. Allow the run to start it now."),
                None,
                None,
            )?;
            self.fx.hint(&schedule.owner_user);
            return Ok(());
        }
        self.start(schedule, latest, None, false).map(|_| ())
    }

    // ---------- runs ----------

    /// The user runs a schedule now, or allows one of its missed runs
    /// (`missed_run_id`). Unlike a timed run it fails loudly: the node is
    /// offline, or the previous run still goes.
    fn run_now(&mut self, user: &str, id: &str, missed_run_id: Option<&str>) -> ApiResult<Run> {
        let schedule = self.get(user, id)?;
        let mut due_at = now_ms();
        if let Some(missed_id) = missed_run_id {
            match self.run_row(missed_id)? {
                Some(missed) if missed.schedule_id == id && missed.status == RunStatus::Missed => {
                    due_at = missed.due_at;
                }
                _ => {
                    return Err(ApiError::not_found(format!(
                        "No missed run {missed_id} of schedule {id}"
                    )));
                }
            }
        }
        self.start(&schedule, due_at, missed_run_id, true)
    }

    /// The user lets a missed run go.
    fn dismiss(&mut self, user: &str, id: &str, run_id: &str) -> ApiResult<Run> {
        self.get(user, id)?;
        let changed = self.conn.execute(
            "UPDATE schedule_runs SET status='dismissed', finished_at=? WHERE id=? AND schedule_id=? AND status='missed'",
            params![now_ms(), run_id, id],
        )?;
        if changed == 0 {
            return Err(ApiError::not_found(format!(
                "No missed run {run_id} of schedule {id}"
            )));
        }
        self.fx.hint(user);
        self.run_row(run_id)?.ok_or_else(ApiError::internal)
    }

    fn require_capability(&self, schedule: &Schedule) -> ApiResult<()> {
        self.conn
            .require_workspace_capability(&schedule.spec.workspace_id, Capability::Schedules)?;
        if let Some(session_id) = &schedule.created_by_session {
            self.conn
                .require_session_capability(session_id, Capability::Schedules)?;
        }
        Ok(())
    }

    fn start(
        &mut self,
        schedule: &Schedule,
        due_at: i64,
        existing_run_id: Option<&str>,
        manual: bool,
    ) -> ApiResult<Run> {
        if let Err(error) = self.require_capability(schedule) {
            if manual {
                return Err(error);
            }
            let run = self.insert_run(
                schedule,
                due_at,
                RunStatus::Failed,
                Some(&error.message),
                None,
                Some(now_ms()),
            )?;
            self.set_status(schedule, ScheduleStatus::Paused, schedule.next_run_at)?;
            self.fx.hint(&schedule.owner_user);
            return Ok(run);
        }
        let open: Option<String> = self
            .conn
            .query_row(
                &format!(
                    "SELECT id FROM schedule_runs WHERE schedule_id=? AND status IN {OPEN_RUNS} LIMIT 1"
                ),
                [&schedule.id],
                |row| row.get(0),
            )
            .optional()?;
        let workspace = self.conn.get_workspace(&schedule.spec.workspace_id)?;
        let online = workspace_online(self.app, &workspace);
        if manual && let Some(open) = &open {
            return Err(ApiError::new(
                409,
                "conflict",
                format!("Its run {open} is still going"),
            ));
        }
        if manual && !online {
            return Err(ApiError::new(
                503,
                "node_offline",
                format!("{} is offline", workspace.host_id),
            ));
        }
        if let Some(open) = open {
            let run = self.insert_run(
                schedule,
                due_at,
                RunStatus::Skipped,
                Some(&format!("The previous run ({open}) was still going.")),
                None,
                Some(now_ms()),
            )?;
            self.fx.hint(&schedule.owner_user);
            return Ok(run);
        }
        if !online {
            let run = self.insert_run(
                schedule,
                due_at,
                RunStatus::Missed,
                Some(&format!(
                    "{} was offline. Allow the run to start it now.",
                    workspace.host_id
                )),
                None,
                None,
            )?;
            self.fx.hint(&schedule.owner_user);
            return Ok(run);
        }
        let run = match existing_run_id {
            Some(existing) => {
                self.conn.execute(
                    "UPDATE schedule_runs SET status='running', result=NULL, started_at=? WHERE id=? AND status='missed'",
                    params![now_ms(), existing],
                )?;
                self.run_row(existing)?.ok_or_else(ApiError::internal)?
            }
            None => self.insert_run(
                schedule,
                due_at,
                RunStatus::Running,
                None,
                Some(now_ms()),
                None,
            )?,
        };
        if manual && existing_run_id.is_none() {
            self.conn.execute(
                "UPDATE schedule_runs SET origin='manual' WHERE id=?",
                [&run.id],
            )?;
        }
        self.fx.hint(&schedule.owner_user);
        self.fx.0.push(Effect::Dispatch(Box::new((
            schedule.clone(),
            run.clone(),
            workspace,
        ))));
        Ok(run)
    }

    fn set_run_status(&mut self, run: &Run, status: RunStatus) -> ApiResult<()> {
        // A progress snapshot can arrive after deletion has settled this run.
        let changed = self.conn.execute(
            "UPDATE schedule_runs SET status=? WHERE id=? AND session_id=? AND status=?",
            params![status, run.id, run.session_id, run.status],
        )?;
        if changed == 0 {
            return Ok(());
        }
        self.fx.hint(&run.owner_user);
        self.announce(&run.id)
    }

    /// Push what the user asked to hear about (the schedule's `notify`).
    fn announce(&mut self, run_id: &str) -> ApiResult<()> {
        let Some(run) = self.run_row(run_id)? else {
            return Ok(());
        };
        let Some(schedule) = self.row(&run.schedule_id)? else {
            return Ok(());
        };
        if schedule.spec.notify == "none" {
            return Ok(());
        }
        let problem = matches!(
            run.status,
            RunStatus::Failed | RunStatus::WaitingInput | RunStatus::Missed
        );
        if !problem && !(run.status == RunStatus::Completed && schedule.spec.notify == "all") {
            return Ok(());
        }
        let what = match run.status {
            RunStatus::Completed => "finished",
            RunStatus::Failed => "failed",
            RunStatus::Missed => "was missed",
            RunStatus::WaitingInput => "is waiting for you",
            // Not announced (the check above).
            RunStatus::Running | RunStatus::Dismissed | RunStatus::Skipped => run.status.as_str(),
        };
        let message = PushMessage {
            title: format!("{} {what}", schedule.spec.title),
            body: match run.status {
                RunStatus::Missed => "Allow it to run it now, or dismiss it.",
                RunStatus::WaitingInput => "The scheduled run needs your answer to go on.",
                _ => "Scheduled run: open it to read the result.",
            }
            .to_owned(),
            // One notification per run session: its "waiting" push is the same one.
            tag: match &run.session_id {
                Some(session_id) => format!("session:{session_id}"),
                None => format!("run:{}", run.id),
            },
            target: match &run.session_id {
                Some(session_id) if run.status != RunStatus::Missed => {
                    json!({ "sessionId": session_id })
                }
                _ => json!({ "schedules": true, "scheduleId": schedule.id }),
            },
            interaction: None,
        };
        self.fx
            .0
            .push(Effect::Push(schedule.owner_user.clone(), message));
        Ok(())
    }

    fn finish(&mut self, id: &str, status: RunStatus, result: &str) -> ApiResult<()> {
        let run = self.run_row(id)?;
        let changed = self.conn.execute(
            &format!(
                "UPDATE schedule_runs SET status=?, result=?, finished_at=? WHERE id=? AND status IN {OPEN_RUNS}"
            ),
            params![
                status,
                clip(&redact_secrets(result), RESULT_MAX_CHARS),
                now_ms(),
                id
            ],
        )?;
        if changed > 0
            && let Some(run) = run
        {
            self.fx.hint(&run.owner_user);
            self.announce(id)?;
        }
        Ok(())
    }

    fn insert_run(
        &mut self,
        schedule: &Schedule,
        due_at: i64,
        status: RunStatus,
        result: Option<&str>,
        started_at: Option<i64>,
        finished_at: Option<i64>,
    ) -> ApiResult<Run> {
        let id = self.new_id("schedule_runs", "r")?;
        self.conn.execute(
            "INSERT INTO schedule_runs (id,schedule_id,owner_user,due_at,status,result,started_at,finished_at,created_at,origin) VALUES (?,?,?,?,?,?,?,?,?,'scheduled')",
            params![
                id,
                schedule.id,
                schedule.owner_user,
                due_at,
                status,
                result,
                started_at,
                finished_at,
                now_ms()
            ],
        )?;
        // Keep the newest runs; open and missed ones stay until they are handled.
        self.conn.execute(
            &format!(
                "DELETE FROM schedule_runs WHERE schedule_id=? AND status NOT IN ('running','waiting_input','missed') AND id NOT IN (SELECT id FROM schedule_runs WHERE schedule_id=? ORDER BY created_at DESC, rowid DESC LIMIT {RUNS_KEPT})"
            ),
            params![schedule.id, schedule.id],
        )?;
        if matches!(status, RunStatus::Missed | RunStatus::Failed) {
            self.announce(&id)?;
        }
        self.run_row(&id)?.ok_or_else(ApiError::internal)
    }

    // ---------- helpers ----------

    fn workspace_view(&self, workspace_id: &str) -> Value {
        match self.conn.get_workspace(workspace_id) {
            Ok(workspace) => json!({
                "id": workspace.id,
                "name": workspace.display_name,
                "mode": workspace.mode,
                "kind": self.app.mode(&workspace.mode).map(|mode| match mode.workdir {
                    pirc_protocol::mode::Workdir::PerSession => "chat",
                    _ => "directory",
                }),
                "available": self.app.mode(&workspace.mode).is_some(),
                "node": workspace.host_id,
                "online": workspace_online(self.app, &workspace),
            }),
            Err(_) => json!({
                "id": workspace_id, "name": workspace_id, "kind": null, "node": null, "online": false,
            }),
        }
    }

    fn label(&self, workspace_id: &str) -> String {
        match self.conn.get_workspace(workspace_id) {
            Ok(workspace) => format!("{} on {}", workspace.display_name, workspace.host_id),
            Err(_) => workspace_id.to_owned(),
        }
    }

    fn session_name(&self, session_id: &str) -> Option<String> {
        self.conn
            .get_session(session_id)
            .ok()
            .map(|session| session.name)
    }

    fn new_id(&self, table: &str, prefix: &str) -> ApiResult<String> {
        loop {
            let id = format!("{prefix}{}", hex(&random_bytes::<4>()));
            let exists = self
                .conn
                .query_row(&format!("SELECT 1 FROM {table} WHERE id=?"), [&id], |_| {
                    Ok(())
                })
                .optional()?;
            if exists.is_none() {
                return Ok(id);
            }
        }
    }
}

fn model_json(spec: &Spec) -> Option<String> {
    spec.model
        .as_ref()
        .and_then(|model| serde_json::to_string(model).ok())
}

fn describe_when(spec: &Spec) -> String {
    match &spec.cron {
        Some(expression) => format!("cron \"{expression}\" ({})", spec.timezone),
        None => format!(
            "once at {}",
            format_in(spec.run_at.unwrap_or_default(), &spec.timezone)
        ),
    }
}

fn parse_at(at: &str, zone: Zone) -> ApiResult<i64> {
    cron::Cron::new(at, zone)
        .ok()
        .and_then(|cron| cron.next_run(0, zone))
        .ok_or_else(|| {
            invalid(format!(
                "at must be an ISO 8601 time like 2026-10-01T09:00, not {at}"
            ))
        })
}

// ---------- the hooks the core calls ----------

/// Schedule proposals of this session waiting for the user, as interactions.
pub fn pending_interactions(app: &App, session_id: &str) -> Vec<Value> {
    read(app, |ctx| ctx.pending_interactions(session_id)).unwrap_or_default()
}

/// Answer a schedule proposal's confirmation; `None` when it is not one.
pub fn answer(
    app: &AppState,
    session_id: &str,
    interaction_id: &str,
    user: &str,
    answer: Option<&Value>,
) -> ApiResult<Option<Value>> {
    with(app, |ctx| {
        ctx.answer(session_id, interaction_id, user, answer)
    })
}

#[cfg(test)]
mod tests;
