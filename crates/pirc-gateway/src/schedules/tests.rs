//! The scheduler's logic without nodes (`schedules.integration.test.ts`,
//! the parts that need no agent): validation, missed, skipped and failed
//! runs, proposals and their expiry, result paging and agents' scope. The
//! black-box scenario with a node is `crates/pirc-conformance/tests/schedules.rs`.

use std::sync::Arc;

use pirc_config::{Env, GatewayConfig};
use pirc_providers::backends::BackendService;
use serde_json::{Value, json};

use super::fields::object;
use super::{Ctx, Input, RunStatus, ScheduleStatus, Spec, with};
use crate::agent_ops::OpContext;
use crate::app::{App, AppState};
use crate::db::{Db, ModeId, Store};
use crate::error::{ApiError, ApiResult};
use crate::util::now_ms;

const USER: &str = "u@example.com";

struct Fixture {
    app: AppState,
    _dir: tempfile::TempDir,
}

fn fixture() -> Fixture {
    let dir = tempfile::tempdir().unwrap();
    let state = dir.path().join("state");
    let env = Env::new(
        [
            (
                "PIRC_NODE_TOKENS",
                r#"{"work":"0123456789abcdef0123456789abcdef"}"#,
            ),
            ("PIRC_TRUSTED_PROXIES", "127.0.0.1"),
            ("PIRC_PROXY_SECRET_REQUIRED", "false"),
            ("PIRC_ALLOWED_ORIGINS", "https://a.example"),
            ("PIRC_ALLOWED_HOSTS", "a.example"),
            ("PIRC_ALLOWED_USERS", USER),
            ("PIRC_STATE_DIR", state.to_str().unwrap()),
            ("PIRC_CONFIG_DIR", dir.path().to_str().unwrap()),
            ("PIRC_TIMEZONE", "UTC"),
            ("PIRC_DELEGATION_TTL_MS", "60000"),
            ("HOME", "/home/test"),
        ],
        "/work",
    );
    let config = GatewayConfig::load(&env).unwrap();
    let models = serde_json::from_value(json!({ "providers": { "gw": {
        "api": "openai-completions", "baseUrl": "http://127.0.0.1:9/v1",
        "models": [{ "id": "model-a" }] } } }))
    .unwrap();
    let backends = BackendService::open(&state, models).unwrap();
    let app = App::new(
        config,
        Arc::new(Db::memory()),
        backends,
        crate::app::test_modes(),
    );
    {
        let conn = app.db.lock();
        for (node, id, name, kind) in [
            ("work", "test", "Test", ModeId::new("directory").unwrap()),
            ("lab", "test", "Lab", ModeId::new("directory").unwrap()),
            ("home", "chats", "Chats", ModeId::new("chat").unwrap()),
        ] {
            conn.sync_remote_workspaces(node, &[(id.into(), name.into(), kind)])
                .unwrap();
        }
    }
    Fixture { app, _dir: dir }
}

#[test]
fn reload_keeps_valid_edits_and_skips_invalid_files() {
    let f = fixture();
    std::fs::create_dir_all(&f.app.config.modes_dir).unwrap();
    for (name, text) in pirc_config::modes::DEFAULT_MODE_FILES {
        std::fs::write(f.app.config.modes_dir.join(name), text).unwrap();
    }
    let chat_file = f.app.config.modes_dir.join("chat.md");
    let text = std::fs::read_to_string(&chat_file).unwrap();
    std::fs::write(
        &chat_file,
        text.replace("delegate: true", "delegate: false")
            .replace("schedule_scope: any", "schedule_scope: own"),
    )
    .unwrap();
    std::fs::write(
        f.app.config.modes_dir.join("broken.md"),
        "---\nunknown: true\n---\n",
    )
    .unwrap();
    f.app.reload_modes();
    let catalog = f.app.catalog();
    assert_eq!(catalog.warnings.len(), 1);
    assert!(!catalog.modes[&ModeId::new("chat").unwrap()].delegate);
    assert_eq!(catalog.modes.len(), 3);
    std::fs::remove_file(chat_file).unwrap();
    f.app.reload_modes();
    assert!(f.app.mode(&ModeId::new("chat").unwrap()).is_none());
}

#[test]
fn missing_and_custom_modes_never_fall_back() {
    let f = fixture();
    let mode_id = ModeId::new("research").unwrap();
    f.app
        .db
        .lock()
        .sync_remote_workspaces(
            "work",
            &[("custom".into(), "Custom".into(), mode_id.clone())],
        )
        .unwrap();
    let workspace = f.app.db.lock().get_workspace("work:custom").unwrap();
    assert_eq!(workspace.mode, mode_id);
    assert_eq!(
        f.app.require_mode(&workspace).unwrap_err().code,
        "mode_unavailable"
    );
    let mut catalog = crate::app::test_modes();
    let mut mode = pirc_protocol::mode::default_chat();
    mode.id = mode_id.clone();
    mode.delegate = false;
    catalog.modes.insert(mode_id.clone(), mode);
    *f.app.modes.write().unwrap() = Arc::new(catalog);
    assert!(!f.app.require_mode(&workspace).unwrap().delegate);
    let session = f
        .app
        .db
        .lock()
        .create_session(&workspace.id, "node://work/custom", "work", "custom", USER)
        .unwrap();
    assert!(f.app.require_writable(&session).is_ok());
    *f.app.modes.write().unwrap() = Arc::new(crate::app::test_modes());
    assert_eq!(
        f.app.require_writable(&session).unwrap_err().code,
        "mode_unavailable"
    );
    assert!(f.app.db.lock().get_session(&session.id).is_ok());
}

fn route(conn: &rusqlite::Connection, reference: &str) -> ApiResult<crate::db::Workspace> {
    conn.get_workspace(reference)
}

fn input(value: Value) -> Input {
    let Ok(body) = object(
        &value,
        &[
            "workspace",
            "title",
            "prompt",
            "cron",
            "at",
            "timezone",
            "model",
            "thinking",
            "notify",
        ],
    ) else {
        panic!("not an input: {value}");
    };
    let Ok(mut input) = super::fields::route_input(&body, false) else {
        panic!("not an input: {value}");
    };
    input.workspace = body.string("workspace", 1, 300).ok().flatten();
    input
}

fn create(app: &AppState, value: Value) -> ApiResult<super::Schedule> {
    with(app, |ctx| ctx.create(USER, &input(value), &route))
}

fn message<T: std::fmt::Debug>(result: ApiResult<T>) -> (u16, String) {
    let error: ApiError = result.unwrap_err();
    (error.status, error.message)
}

fn sql(app: &App, statement: &str, values: impl rusqlite::Params) {
    app.db.lock().execute(statement, values).unwrap();
}

fn runs(app: &AppState, id: &str) -> Vec<super::Run> {
    with(app, |ctx| ctx.runs(USER, id)).unwrap()
}

fn tick(app: &AppState) {
    with(app, |ctx: &mut Ctx<'_>| ctx.tick(super::DEFAULT_GRACE_MS)).unwrap();
}

/// Hourly, half an hour away from now: its latest fire time is always long past.
fn hourly() -> String {
    let minute = (now_ms() / 60_000 + 30) % 60;
    format!("{minute} * * * *")
}

#[tokio::test]
async fn validates_input() {
    let f = fixture();
    let soon = chrono::DateTime::from_timestamp_millis(now_ms() + 60_000)
        .unwrap()
        .format("%Y-%m-%dT%H:%M:%S")
        .to_string();
    for (payload, expected) in [
        (
            json!({ "cron": "0 9 * *" }),
            "cron needs 5 fields: minute hour day-of-month month day-of-week",
        ),
        (
            json!({ "cron": "0 9 * * * *" }),
            "cron needs 5 fields: minute hour day-of-month month day-of-week",
        ),
        (
            json!({ "cron": "61 9 * * *" }),
            "Invalid cron \"61 9 * * *\": CronPattern: Invalid value for minute: 61",
        ),
        (
            json!({ "cron": "0 9 30 2 *" }),
            "cron \"0 9 30 2 *\" never fires",
        ),
        (
            json!({ "cron": "0 9 * * *", "timezone": "Mars/Base" }),
            "Unknown time zone Mars/Base",
        ),
        (
            json!({ "at": "2020-01-01T00:00" }),
            "2020-01-01 00:00 (UTC) is in the past",
        ),
        (
            json!({ "at": "tomorrow" }),
            "at must be an ISO 8601 time like 2026-10-01T09:00, not tomorrow",
        ),
        (
            json!({ "cron": "0 9 * * *", "at": soon }),
            "Give either cron or at, not both",
        ),
        (
            json!({ "cron": "0 9 * * *", "model": { "provider": "gw", "id": "nope" } }),
            "Unknown model gw/nope",
        ),
        (json!({}), "Give cron (repeating) or at (once)"),
        (json!({ "prompt": "  " }), "prompt is required"),
    ] {
        let mut value = json!({ "workspace": "work:test", "prompt": "x" });
        for (key, item) in payload.as_object().unwrap() {
            value[key] = item.clone();
        }
        assert_eq!(message(create(&f.app, value)), (400, expected.to_owned()));
    }
    assert_eq!(
        message(create(
            &f.app,
            json!({ "workspace": "work:test", "prompt": "x".repeat(20_001), "cron": "0 9 * * *" })
        )),
        (413, "A prompt holds at most 20000 characters".to_owned())
    );
    assert_eq!(
        message(create(
            &f.app,
            json!({ "workspace": "nope", "prompt": "x", "cron": "0 9 * * *" })
        )),
        (404, "Workspace not found".to_owned())
    );

    let schedule = create(
        &f.app,
        json!({ "workspace": "work:test", "prompt": "Check it.\nThoroughly.", "cron": "30 9 * * 1-5",
            "timezone": " asia/taipei ", "model": { "provider": "gw", "id": "model-a" },
            "thinking": "high", "notify": "problems" }),
    )
    .unwrap();
    assert_eq!(schedule.spec.title, "Check it.");
    assert_eq!(schedule.spec.timezone, "asia/taipei");
    assert_eq!(schedule.status, ScheduleStatus::Active);
    assert!(schedule.next_run_at.unwrap() > now_ms());
    // A one-shot's zone cannot change without its time.
    let once = create(
        &f.app,
        json!({ "workspace": "work:test", "prompt": "Once.", "at": "2040-01-01T09:00+08:00" }),
    )
    .unwrap();
    assert_eq!(once.spec.run_at, Some(2_208_992_400_000));
    assert_eq!(
        message(with(&f.app, |ctx| ctx.update(
            USER,
            &once.id,
            &input(json!({ "timezone": "Asia/Taipei" })),
            &route
        ))),
        (
            400,
            "Changing the time zone of a one-shot needs its time (at) again".to_owned()
        )
    );
    let brief = with(&f.app, |ctx| ctx.brief(&schedule)).unwrap();
    assert_eq!(brief["when"], "cron \"30 9 * * 1-5\" (asia/taipei)");
    assert_eq!(brief["workspace"], "Test on work");
    assert_eq!(brief["model"], "gw/model-a");
    assert_eq!(brief["notify"], "problems");
    assert!(
        brief["nextRun"]
            .as_str()
            .unwrap()
            .ends_with(" 09:30 (asia/taipei)")
    );
}

#[tokio::test]
async fn records_missed_runs_after_downtime() {
    let f = fixture();
    let schedule = create(
        &f.app,
        json!({ "workspace": "work:test", "prompt": "Summarize.", "cron": hourly() }),
    )
    .unwrap();
    sql(
        &f.app,
        "UPDATE schedules SET next_run_at=? WHERE id=?",
        rusqlite::params![now_ms() - 3_600_000, schedule.id],
    );
    tick(&f.app);
    let listed = runs(&f.app, &schedule.id);
    assert_eq!(
        listed.len(),
        1,
        "several slept-through fire times count once"
    );
    let missed = &listed[0];
    assert_eq!(missed.status, RunStatus::Missed);
    assert_eq!(missed.session_id, None);
    assert!(now_ms() - missed.due_at < 3_600_000);
    assert!(now_ms() - missed.due_at > 20 * 60_000);
    let current = with(&f.app, |ctx| ctx.get(USER, &schedule.id)).unwrap();
    assert!(current.next_run_at.unwrap() > now_ms());
    let view = with(&f.app, |ctx| ctx.view(&current)).unwrap();
    assert_eq!(view["attention"], 1);
    assert_eq!(view["lastRun"]["status"], "missed");
    // The node is offline: allowing it fails loudly.
    assert_eq!(
        message(with(&f.app, |ctx| ctx.run_now(
            USER,
            &schedule.id,
            Some(&missed.id)
        ))),
        (503, "work is offline".to_owned())
    );
    assert_eq!(
        message(with(&f.app, |ctx| ctx.run_now(
            USER,
            &schedule.id,
            Some("rnope")
        ))),
        (
            404,
            format!("No missed run rnope of schedule {}", schedule.id)
        )
    );
    let dismissed = with(&f.app, |ctx| ctx.dismiss(USER, &schedule.id, &missed.id)).unwrap();
    assert_eq!(dismissed.status, RunStatus::Dismissed);
    assert!(
        with(&f.app, |ctx| ctx.dismiss(USER, &schedule.id, &missed.id)).is_err(),
        "a run is dismissed once"
    );
}

#[tokio::test]
async fn records_offline_skipped_and_failed_runs() {
    let f = fixture();
    let schedule = create(
        &f.app,
        json!({ "workspace": "work:test", "prompt": "Check.", "cron": hourly() }),
    )
    .unwrap();
    let due = |app: &AppState| {
        sql(
            app,
            "UPDATE schedules SET next_run_at=? WHERE id=?",
            rusqlite::params![now_ms(), schedule.id],
        );
        tick(app);
    };
    // Its node is offline at the fire time: missed.
    due(&f.app);
    let offline = runs(&f.app, &schedule.id).remove(0);
    assert_eq!(offline.status, RunStatus::Missed);
    assert_eq!(
        offline.result.as_deref(),
        Some("work was offline. Allow the run to start it now.")
    );
    // A run that still goes blocks the next fire time, which is skipped.
    sql(
        &f.app,
        "UPDATE schedule_runs SET status='waiting_input' WHERE id=?",
        [&offline.id],
    );
    due(&f.app);
    let skipped = runs(&f.app, &schedule.id).remove(0);
    assert_eq!(skipped.status, RunStatus::Skipped);
    assert_eq!(
        skipped.result,
        Some(format!(
            "The previous run ({}) was still going.",
            offline.id
        ))
    );
    assert_eq!(
        message(with(&f.app, |ctx| ctx.run_now(USER, &schedule.id, None))),
        (409, format!("Its run {} is still going", offline.id))
    );
    // A finished one-shot cannot resume without a new time.
    sql(
        &f.app,
        "UPDATE schedules SET cron=NULL, run_at=?, status='paused' WHERE id=?",
        rusqlite::params![now_ms() - 1000, schedule.id],
    );
    assert_eq!(
        message(with(&f.app, |ctx| ctx.resume(USER, &schedule.id))),
        (
            409,
            "Its one-shot time has passed: give it a new time (at) instead".to_owned()
        )
    );
    // Its workspace is gone: failed, and the schedule is paused.
    sql(
        &f.app,
        "UPDATE schedules SET cron=?, run_at=NULL, status='active' WHERE id=?",
        rusqlite::params![hourly(), schedule.id],
    );
    sql(&f.app, "DELETE FROM workspaces WHERE id='work:test'", []);
    due(&f.app);
    let failed = runs(&f.app, &schedule.id).remove(0);
    assert_eq!(failed.status, RunStatus::Failed);
    assert_eq!(
        failed.result.as_deref(),
        Some("Its workspace no longer exists; the schedule is paused.")
    );
    assert_eq!(
        with(&f.app, |ctx| ctx.get(USER, &schedule.id))
            .unwrap()
            .status,
        ScheduleStatus::Paused
    );
}

fn session(app: &App, workspace: &str, remote: &str) -> crate::db::Session {
    let node = workspace.split(':').next().unwrap();
    app.db
        .lock()
        .create_session(
            workspace,
            &format!("node://{node}/{remote}"),
            node,
            remote,
            USER,
        )
        .unwrap()
}

fn context(app: &App, workspace: &str, remote: &str) -> OpContext {
    let session = session(app, workspace, remote);
    let workspace = app.db.lock().get_workspace(workspace).unwrap();
    OpContext {
        mode: app.require_mode(&workspace).unwrap(),
        session,
        workspace,
        user: USER.into(),
    }
}

async fn op(app: &AppState, context: &OpContext, name: &str, args: Value) -> ApiResult<Value> {
    let Some(Ok(parsed)) = super::parse_op(name, &args) else {
        panic!("{name} {args}: not a valid operation");
    };
    super::run_op(app, context, parsed).await
}

#[tokio::test]
async fn agents_propose_within_their_scope() {
    let f = fixture();
    let app = &f.app;
    let chat = context(app, "home:chats", "c1");
    // The assistant names a directory workspace by id or by a unique name.
    assert_eq!(
        message(
            op(
                app,
                &chat,
                "schedule.create",
                json!({ "workspace": "nowhere", "prompt": "x", "cron": "0 9 * * *" }),
            )
            .await
        ),
        (
            404,
            "No workspace nowhere. Workspaces: Lab (lab:test), Test (work:test)".to_owned()
        )
    );
    let proposed = op(
        app,
        &chat,
        "schedule.create",
        json!({ "workspace": "test", "prompt": "Check the CI dashboard.", "title": "CI check",
            "cron": "0 9 * * 1-5", "timezone": "Asia/Taipei" }),
    )
    .await
    .unwrap();
    assert_eq!(proposed["status"], "pending_approval");
    assert_eq!(proposed["title"], "CI check");
    let proposal_id = proposed["proposalId"].as_str().unwrap().to_owned();
    assert!(with(app, |ctx| ctx.list(USER)).unwrap().is_empty());
    let pending = super::pending_interactions(app, &chat.session.id);
    assert_eq!(pending.len(), 1);
    let request = &pending[0]["request"];
    assert_eq!(request["title"], "Schedule this task?");
    assert_eq!(request["confirmLabel"], "Schedule");
    let text = request["message"].as_str().unwrap();
    assert!(text.starts_with("CI check\n\nWhere: Test on work (a new session each run)\n"));
    assert!(text.contains("When: cron \"0 9 * * 1-5\" (Asia/Taipei); next "));
    assert!(!text.contains("Model:"));
    assert!(text.ends_with("\n\nCheck the CI dashboard."));

    // Only the user picks a schedule's model; mistakes come back at once.
    assert!(matches!(
        super::parse_op(
            "schedule.create",
            &json!({ "prompt": "x", "cron": "0 9 * * *", "model": "gw/model-a" })
        ),
        Some(Err(()))
    ));
    assert_eq!(
        message(
            op(
                app,
                &chat,
                "schedule.create",
                json!({ "prompt": "x", "cron": "bad" })
            )
            .await
        )
        .0,
        400
    );

    let approved = super::answer(
        app,
        &chat.session.id,
        &proposal_id,
        USER,
        Some(&json!({ "confirmed": true })),
    )
    .unwrap()
    .unwrap();
    assert_eq!(approved["status"], "answered");
    let id = approved["scheduleId"].as_str().unwrap().to_owned();
    let saved = with(app, |ctx| ctx.get(USER, &id)).unwrap();
    assert_eq!(saved.spec.workspace_id, "work:test");
    assert_eq!(
        saved.created_by_session.as_deref(),
        Some(chat.session.id.as_str())
    );
    assert_eq!(
        message(super::answer(
            app,
            &chat.session.id,
            &proposal_id,
            USER,
            Some(&json!({ "confirmed": true }))
        )),
        (409, "This schedule can no longer be answered".to_owned())
    );
    assert!(
        super::answer(app, "other", &proposal_id, USER, None)
            .unwrap()
            .is_none()
    );

    // A change is a proposal too; declined, it leaves the schedule alone.
    let change = op(
        app,
        &chat,
        "schedule.update",
        json!({ "id": id, "cron": "0 10 * * *" }),
    )
    .await
    .unwrap();
    let pending = super::pending_interactions(app, &chat.session.id);
    assert_eq!(
        pending[0]["request"]["title"],
        "Change the schedule “CI check”?"
    );
    super::answer(
        app,
        &chat.session.id,
        change["proposalId"].as_str().unwrap(),
        USER,
        Some(&json!({ "confirmed": false })),
    )
    .unwrap();
    assert_eq!(
        with(app, |ctx| ctx.get(USER, &id))
            .unwrap()
            .spec
            .cron
            .as_deref(),
        Some("0 9 * * 1-5")
    );

    let paused = op(app, &chat, "schedule.pause", json!({ "id": id }))
        .await
        .unwrap();
    assert_eq!(paused["status"], "paused");
    let listed = op(app, &chat, "schedule.list", json!({})).await.unwrap();
    assert_eq!(listed["timezone"], "UTC");
    assert_eq!(listed["schedules"][0]["workspace"], "Test on work");

    // A coding session schedules only in its own workspace, and sees only those.
    let coding = context(app, "work:test", "w1");
    let lab = context(app, "lab:test", "l1");
    assert_eq!(
        op(app, &coding, "schedule.list", json!({})).await.unwrap()["schedules"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    assert_eq!(
        message(
            op(
                app,
                &coding,
                "schedule.create",
                json!({ "workspace": "lab:test", "prompt": "x", "cron": "0 9 * * *" })
            )
            .await
        )
        .0,
        403
    );
    assert_eq!(
        op(app, &lab, "schedule.list", json!({})).await.unwrap()["schedules"],
        json!([])
    );
    assert_eq!(
        message(op(app, &lab, "schedule.delete", json!({ "id": id })).await),
        (404, format!("No schedule {id} in this workspace"))
    );
    let own = op(
        app,
        &coding,
        "schedule.create",
        json!({ "prompt": "Lint.", "cron": "0 9 * * *" }),
    )
    .await
    .unwrap();
    let dialog = super::pending_interactions(app, &coding.session.id);
    assert_eq!(dialog[0]["id"], own["proposalId"]);
    assert!(
        dialog[0]["request"]["message"]
            .as_str()
            .unwrap()
            .contains("Where: Test on work")
    );

    // A scheduled run's session cannot schedule more.
    let schedule = with(app, |ctx| ctx.get(USER, &id)).unwrap();
    with(app, |ctx| {
        ctx.insert_run(
            &schedule,
            now_ms(),
            RunStatus::Completed,
            Some("ok"),
            None,
            None,
        )?;
        Ok(())
    })
    .unwrap();
    sql(
        app,
        "UPDATE schedule_runs SET session_id=? WHERE schedule_id=?",
        rusqlite::params![coding.session.id, id],
    );
    for (name, args) in [
        (
            "schedule.create",
            json!({ "prompt": "Again.", "cron": "* * * * *" }),
        ),
        ("schedule.resume", json!({ "id": id })),
        ("schedule.run", json!({ "id": id })),
    ] {
        assert_eq!(
            message(op(app, &coding, name, args).await),
            (
                403,
                "A scheduled run cannot create, change, resume or start schedules".to_owned()
            )
        );
    }
    assert!(
        op(app, &coding, "schedule.pause", json!({ "id": id }))
            .await
            .is_ok()
    );
    // Nobody approves in a run's session, so it may not ask to delete.
    assert_eq!(
        message(op(app, &coding, "schedule.delete", json!({ "id": id })).await).0,
        403
    );

    // Deleting is a proposal the user approves (L10).
    let proposed = op(app, &chat, "schedule.delete", json!({ "id": id }))
        .await
        .unwrap();
    let proposal = proposed["proposalId"].as_str().unwrap().to_owned();
    assert_eq!(
        proposed,
        json!({ "id": id, "title": "CI check", "proposalId": proposal,
            "status": "pending_approval" })
    );
    assert!(with(app, |ctx| ctx.get(USER, &id)).is_ok());
    let dialog = super::pending_interactions(app, &chat.session.id);
    let request = &dialog.last().unwrap()["request"];
    assert_eq!(request["title"], "Delete the schedule “CI check”?");
    assert_eq!(request["confirmLabel"], "Delete");
    // Declined: it stays.
    super::answer(
        app,
        &chat.session.id,
        &proposal,
        USER,
        Some(&json!({ "confirmed": false })),
    )
    .unwrap();
    assert!(with(app, |ctx| ctx.get(USER, &id)).is_ok());
    // Approved: it is gone, with its runs.
    let proposal = op(app, &chat, "schedule.delete", json!({ "id": id }))
        .await
        .unwrap()["proposalId"]
        .as_str()
        .unwrap()
        .to_owned();
    let answered = super::answer(
        app,
        &chat.session.id,
        &proposal,
        USER,
        Some(&json!({ "confirmed": true })),
    )
    .unwrap();
    assert_eq!(answered.unwrap()["deleted"], true);
    assert_eq!(message(with(app, |ctx| ctx.get(USER, &id))).0, 404);
    let runs: i64 = app
        .db
        .lock()
        .query_row(
            "SELECT count(*) FROM schedule_runs WHERE schedule_id=?",
            [&id],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(runs, 0);
}

#[tokio::test]
async fn proposals_lapse() {
    let f = fixture();
    let chat = context(&f.app, "home:chats", "c1");
    let proposed = op(
        &f.app,
        &chat,
        "schedule.create",
        json!({ "prompt": "Later.", "cron": "0 9 * * *" }),
    )
    .await
    .unwrap();
    let id = proposed["proposalId"].as_str().unwrap();
    sql(
        &f.app,
        "UPDATE schedule_proposals SET expires_at=? WHERE id=?",
        rusqlite::params![now_ms() - 1, id],
    );
    assert!(super::pending_interactions(&f.app, &chat.session.id).is_empty());
    with(&f.app, |ctx| ctx.sweep()).unwrap();
    let status: String = f
        .app
        .db
        .lock()
        .query_row(
            "SELECT status FROM schedule_proposals WHERE id=?",
            [id],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(status, "expired");
    assert_eq!(
        message(super::answer(
            &f.app,
            &chat.session.id,
            id,
            USER,
            Some(&json!({ "confirmed": true }))
        ))
        .0,
        409
    );
    assert!(with(&f.app, |ctx| ctx.list(USER)).unwrap().is_empty());
}

#[tokio::test]
async fn pages_through_long_results() {
    let f = fixture();
    let schedule = create(
        &f.app,
        json!({ "workspace": "work:test", "title": "Report", "prompt": "Write a report.",
            "cron": hourly() }),
    )
    .unwrap();
    let long: String = (0..3000).map(|i| format!("line {i:04}\n")).collect();
    let run = with(&f.app, |ctx| {
        ctx.insert_run(
            &schedule,
            now_ms(),
            RunStatus::Running,
            None,
            Some(now_ms()),
            None,
        )
    })
    .unwrap();
    with(&f.app, |ctx| {
        ctx.finish(&run.id, RunStatus::Completed, &long)
    })
    .unwrap();
    let run = with(&f.app, |ctx| ctx.get_run(USER, &run.id)).unwrap();
    assert_eq!(run.result.as_deref(), Some(long.as_str()));
    let view = with(&f.app, |ctx| Ok(ctx.run_view(&run))).unwrap();
    assert!(view["result"].as_str().unwrap().encode_utf16().count() <= 4000);
    assert_eq!(view["resultChars"], 30_000);

    let chat = context(&f.app, "home:chats", "c1");
    let brief = op(&f.app, &chat, "schedule.list", json!({})).await.unwrap();
    assert_eq!(brief["schedules"][0]["lastRun"]["resultChars"], 30_000);
    let mut text = String::new();
    let mut offsets = Vec::new();
    let mut offset = Some(0);
    while let Some(at) = offset {
        let chunk = op(
            &f.app,
            &chat,
            "schedule.result",
            json!({ "id": run.id, "offset": at }),
        )
        .await
        .unwrap();
        text.push_str(chunk["result"].as_str().unwrap());
        offset = chunk["nextOffset"].as_u64();
        offsets.push((chunk["resultOffset"].as_u64().unwrap(), offset));
    }
    assert_eq!(text, long);
    assert_eq!(
        offsets,
        vec![(0, Some(12_000)), (12_000, Some(24_000)), (24_000, None)]
    );
    assert_eq!(
        message(
            op(
                &f.app,
                &chat,
                "schedule.result",
                json!({ "id": run.id, "offset": 30_001 })
            )
            .await
        ),
        (400, "offset exceeds result length 30000".to_owned())
    );
    let lab = context(&f.app, "lab:test", "l1");
    assert_eq!(
        message(op(&f.app, &lab, "schedule.result", json!({ "id": run.id })).await),
        (404, format!("No run {} in this workspace", run.id))
    );
}

#[test]
fn specs_round_trip_as_the_ts_gateway_stored_them() {
    let spec: Spec = serde_json::from_value(json!({
        "workspaceId": "work:test", "title": "T", "prompt": "P", "cron": null,
        "runAt": 1, "timezone": "UTC", "model": { "provider": "gw", "id": "m" },
        "thinking": null, "notify": "all" }))
    .unwrap();
    assert_eq!(
        serde_json::to_value(&spec).unwrap(),
        json!({ "workspaceId": "work:test", "title": "T", "prompt": "P", "cron": null,
            "runAt": 1, "timezone": "UTC", "model": { "provider": "gw", "id": "m" },
            "thinking": null, "notify": "all" })
    );
}

#[tokio::test]
async fn pending_workspace_removal_does_not_advance_pause_or_fail_due_schedules() {
    let f = fixture();
    let schedule = create(
        &f.app,
        json!({"workspace":"work:test", "prompt":"Summarize.", "cron":hourly()}),
    )
    .unwrap();
    let due = now_ms() - 3_600_000;
    sql(
        &f.app,
        "UPDATE schedules SET next_run_at=? WHERE id=?",
        rusqlite::params![due, schedule.id],
    );
    let before = with(&f.app, |ctx| ctx.get(USER, &schedule.id)).unwrap();
    sql(
        &f.app,
        "INSERT INTO workspace_removals (workspace_id,owner_user,removed_at,status,token) VALUES ('work:test',?,0,'checking','probe')",
        [USER],
    );
    assert_eq!(super::timer::next_due(&f.app).unwrap(), None);
    tick(&f.app);
    let checking = with(&f.app, |ctx| ctx.get(USER, &schedule.id)).unwrap();
    assert_eq!(checking.status, ScheduleStatus::Active);
    assert_eq!(checking.next_run_at, Some(due));
    assert_eq!(checking.updated_at, before.updated_at);
    assert!(runs(&f.app, &schedule.id).is_empty());
    sql(
        &f.app,
        "DELETE FROM workspace_removals WHERE token='probe'",
        [],
    );
    assert_eq!(super::timer::next_due(&f.app).unwrap(), Some(due));
    tick(&f.app);
    assert_eq!(runs(&f.app, &schedule.id).len(), 1);
    let after = with(&f.app, |ctx| ctx.get(USER, &schedule.id)).unwrap();
    assert_eq!(after.status, ScheduleStatus::Active);
    assert!(after.next_run_at.unwrap() > now_ms());
}

#[tokio::test]
async fn dismissing_a_missed_run_needs_the_request_shape() {
    use crate::request_shape::tests::{accepted_empty, identities, ok, prove_operation};
    let f = fixture();
    let who = identities(&f.app, USER);
    let seed = || {
        let schedule = create(
            &f.app,
            json!({ "workspace": "work:test", "prompt": "Summarize.", "cron": hourly() }),
        )
        .unwrap();
        sql(
            &f.app,
            "UPDATE schedules SET next_run_at=? WHERE id=?",
            rusqlite::params![now_ms() - 3_600_000, schedule.id],
        );
        tick(&f.app);
        let missed = runs(&f.app, &schedule.id).remove(0);
        assert_eq!(missed.status, RunStatus::Missed);
        format!("/api/schedules/{}/runs/{}/dismiss", schedule.id, missed.id)
    };
    let statuses = || {
        let conn = f.app.db.lock();
        let rows: Vec<(String, String)> = conn
            .prepare("SELECT id,status FROM schedule_runs ORDER BY id")
            .unwrap()
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))
            .unwrap()
            .map(Result::unwrap)
            .collect();
        json!(rows)
    };
    prove_operation(
        &f.app,
        &who,
        "POST",
        &seed,
        &statuses,
        &accepted_empty(),
        &ok,
    )
    .await;
}
