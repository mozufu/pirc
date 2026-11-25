//! The scheduler's background work: one timer for the earliest due
//! schedule (re-armed whenever schedules change), the proposal expiry
//! sweep, dispatching runs to their nodes, and following run sessions
//! through the event hub.
//!
//! The TS class kept its timer and pending checks in fields; the gateway's
//! `App` has none for them, so they live in a registry keyed by the app.

use std::collections::HashSet;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{Value, json};
use tokio::sync::{Notify, mpsc};

use super::{DEFAULT_GRACE_MS, OPEN_RUNS, Run, RunStatus, Schedule, read, run_message, with};
use crate::app::{App, AppState};
use crate::db::{Store, Workspace};
use crate::dispatch::{Progress, deliver, is_watched_event, read_progress, start_session};
use crate::error::ApiResult;
use crate::events::Subscription;
use crate::util::now_ms;

/// Re-check at least this often, so a suspended machine or clock change is noticed.
const MAX_SLEEP_MS: i64 = 3_600_000;
/// Events of a run session are read after this quiet time, once.
const CHECK_DELAY: Duration = Duration::from_millis(150);

struct Runtime {
    /// Wakes the timer to look at the schedules again (`arm`).
    arm: Notify,
    /// Runs with a check pending.
    checks: Mutex<HashSet<String>>,
    _events: Mutex<Option<Subscription>>,
}

fn runtime(app: &App) -> Option<Arc<Runtime>> {
    app.slots.get::<Runtime>()
}

/// Look at the schedules again (the TS `arm()`); nothing before [`start`].
pub(crate) fn arm(app: &App) {
    if let Some(runtime) = runtime(app) {
        runtime.arm.notify_one();
    }
}

/// Start the scheduler (ticks, event subscription, proposal expiry).
pub fn start(app: &AppState) {
    let runtime = Arc::new(Runtime {
        arm: Notify::new(),
        checks: Mutex::new(HashSet::new()),
        _events: Mutex::new(None),
    });
    app.slots.set(runtime.clone());
    // Listeners run under the hub's lock: only hand the session on.
    let (sender, mut sessions) = mpsc::unbounded_channel::<String>();
    let subscription = app.events.subscribe_all(Arc::new(move |event| {
        if is_watched_event(event) {
            let _ = sender.send(event.session_id.clone());
        }
    }));
    *runtime
        ._events
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(subscription);

    sweep(app);
    tick(app);

    tokio::spawn(run_timer(app.clone(), runtime.clone()));
    let period = Duration::from_millis(app.config.proposal_ttl_ms.clamp(50, 30_000));
    let sweeper = app.clone();
    tokio::spawn(async move {
        let mut interval = tokio::time::interval_at(tokio::time::Instant::now() + period, period);
        loop {
            interval.tick().await;
            sweep(&sweeper);
        }
    });
    let follower = app.clone();
    tokio::spawn(async move {
        while let Some(session_id) = sessions.recv().await {
            let open = read(&follower, |ctx| {
                let mut statement = ctx.conn.prepare(&format!(
                    "SELECT id FROM schedule_runs WHERE session_id=? AND status IN {OPEN_RUNS}"
                ))?;
                let ids = statement.query_map([&session_id], |row| row.get::<_, String>(0))?;
                Ok(ids.collect::<rusqlite::Result<Vec<_>>>()?)
            });
            for id in open.unwrap_or_default() {
                schedule_check(&follower, &runtime, id);
            }
        }
    });
}

fn sweep(app: &AppState) {
    if let Err(error) = with(app, |ctx| ctx.sweep()) {
        crate::log::warn(&format!(
            "schedule proposals: sweep failed: {}",
            error.message
        ));
    }
}

/// Handle every schedule that is due now.
pub(super) fn tick(app: &AppState) {
    if let Err(error) = with(app, |ctx| ctx.tick(DEFAULT_GRACE_MS)) {
        crate::log::warn(&format!("schedules: tick failed: {}", error.message));
    }
}

pub(super) fn next_due(app: &AppState) -> ApiResult<Option<i64>> {
    read(app, |ctx| {
        Ok(ctx.conn.query_row(
            "SELECT MIN(next_run_at) AS due FROM schedules WHERE status='active' AND next_run_at IS NOT NULL AND workspace_id NOT IN (SELECT workspace_id FROM workspace_removals WHERE status='checking')",
            [],
            |row| row.get::<_, Option<i64>>(0),
        )?)
    })
}

/// Sleep until the earliest due schedule (at most an hour), or until the
/// schedules change.
async fn run_timer(app: AppState, runtime: Arc<Runtime>) {
    loop {
        let due = next_due(&app).ok().flatten();
        match due {
            None => runtime.arm.notified().await,
            Some(due) => {
                let delay = (due - now_ms()).clamp(0, MAX_SLEEP_MS) as u64;
                tokio::select! {
                    () = runtime.arm.notified() => {}
                    () = tokio::time::sleep(Duration::from_millis(delay)) => tick(&app),
                }
            }
        }
    }
}

/// Start a run's session on its node and deliver the prompt.
pub(super) async fn dispatch(app: AppState, schedule: Schedule, run: Run, workspace: Workspace) {
    let owner = schedule.owner_user.clone();
    let outcome: Result<(), String> = async {
        with(&app, |ctx| ctx.require_capability(&schedule)).map_err(|error| error.message)?;
        let session = start_session(&app, &workspace, &owner, &schedule.spec.title)
            .await
            .map_err(|failure| failure.0)?;
        with(&app, |ctx| {
            ctx.conn.execute(
                "UPDATE schedule_runs SET session_id=? WHERE id=?",
                rusqlite::params![session.id, run.id],
            )?;
            ctx.require_capability(&schedule)
        })
        .map_err(|error| error.message)?;
        let mut message = json!({
            "customType": "scheduled-run",
            "content": run_message(&schedule, &run),
            "details": { "scheduleId": schedule.id, "runId": run.id, "title": schedule.spec.title },
        });
        if let Some(model) = &schedule.spec.model {
            message["model"] = json!(model);
        }
        if let Some(thinking) = schedule.spec.thinking.as_ref().filter(|t| !t.is_empty()) {
            message["thinking"] = json!(thinking);
        }
        deliver(&app, &session, &owner, message)
            .await
            .map_err(|failure| failure.0)?;
        app.schedules_changed(&owner);
        Ok(())
    }
    .await;
    if let Err(message) = outcome {
        let failed = with(&app, |ctx| {
            ctx.finish(
                &run.id,
                RunStatus::Failed,
                &format!("Could not start the run: {message}"),
            )
        });
        if let Err(error) = failed {
            crate::log::warn(&format!(
                "scheduled run {}: could not record its failure: {}",
                run.id, error.message
            ));
        }
    }
}

/// Read a run's session again shortly, once however many events come.
fn schedule_check(app: &AppState, runtime: &Arc<Runtime>, id: String) {
    {
        let mut checks = runtime
            .checks
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if !checks.insert(id.clone()) {
            return;
        }
    }
    let app = app.clone();
    let runtime = runtime.clone();
    tokio::spawn(async move {
        tokio::time::sleep(CHECK_DELAY).await;
        runtime
            .checks
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .remove(&id);
        if let Err(message) = check(&app, &id).await {
            crate::log::warn(&format!("scheduled run {id}: check failed: {message}"));
        }
    });
}

/// Where a run's session stands: finished, failed or waiting for the user.
pub(super) async fn check(app: &AppState, id: &str) -> Result<(), String> {
    let found = read(app, |ctx| {
        let Some(run) = ctx.run_row(id)? else {
            return Ok(None);
        };
        if !run.status.is_open() {
            return Ok(None);
        }
        let Some(session_id) = run.session_id.clone() else {
            return Ok(None);
        };
        let session = ctx.conn.get_session(&session_id)?;
        Ok(Some((run, session)))
    })
    .map_err(|error| error.message)?;
    let Some((run, session)) = found else {
        return Ok(());
    };
    let progress = read_progress(
        app,
        &session,
        &run.owner_user,
        run.started_at.unwrap_or(run.created_at),
        |message| {
            message
                .get("details")
                .and_then(|details| details.get("runId"))
                .and_then(Value::as_str)
                == Some(run.id.as_str())
        },
    )
    .await
    .map_err(|failure| failure.0)?;
    let outcome: ApiResult<()> = with(app, |ctx| match progress {
        Progress::Dropped => ctx.finish(
            id,
            RunStatus::Failed,
            "The agent stopped before it took the task",
        ),
        Progress::Waiting(_) => {
            if run.status != RunStatus::WaitingInput {
                ctx.set_run_status(&run, RunStatus::WaitingInput)?;
            }
            Ok(())
        }
        Progress::Working => {
            if run.status == RunStatus::WaitingInput {
                ctx.set_run_status(&run, RunStatus::Running)?;
            }
            Ok(())
        }
        Progress::Over {
            status,
            failure_reason,
            answer,
        } => {
            if status == "succeeded" {
                let answer = if answer.is_empty() {
                    "(no final answer)".to_owned()
                } else {
                    answer
                };
                ctx.finish(id, RunStatus::Completed, &answer)
            } else {
                let reason = failure_reason
                    .filter(|reason| !reason.is_empty())
                    .map(|reason| format!(": {reason}"))
                    .unwrap_or_default();
                let last = if answer.is_empty() {
                    String::new()
                } else {
                    format!("\n\nLast answer: {answer}")
                };
                ctx.finish(
                    id,
                    RunStatus::Failed,
                    &format!("The run {status}{reason}{last}"),
                )
            }
        }
        Progress::Unknown | Progress::Queued => Ok(()),
    });
    outcome.map_err(|error| error.message)
}
