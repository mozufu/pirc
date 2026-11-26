//! Schedules in the web and Android apps (`schedule-routes.ts`). The
//! user's own changes need no approval; only an agent's do.

use axum::Router;
use axum::extract::{Extension, Path, State};
use axum::routing::{get, post};
use rusqlite::Connection;
use serde_json::{Value, json};

use super::fields::{Mismatch, object, route_input};
use super::with;
use crate::app::{AppState, ReqBody};
use crate::auth::Identity;
use crate::db::{Store, Workspace};
use crate::error::{ApiError, ApiResult, json_response};
use crate::http::{Body, no_content, ok};
use crate::routes::Handled;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/api/schedules", get(list).post(create))
        .route(
            "/api/schedules/{id}",
            get(show).patch(update).delete(remove),
        )
        .route("/api/schedules/{id}/run", post(run))
        .route("/api/schedules/{id}/runs/{run_id}", get(show_run))
        .route("/api/schedules/{id}/runs/{run_id}/dismiss", post(dismiss))
}

fn invalid(_: Mismatch) -> ApiError {
    ApiError::invalid_input()
}

/// `idParams`: 1–40 characters.
fn param(id: &str) -> ApiResult<()> {
    if (1..=40).contains(&super::units(id)) {
        Ok(())
    } else {
        Err(ApiError::invalid_input())
    }
}

fn workspace(conn: &Connection, reference: &str) -> ApiResult<Workspace> {
    conn.get_workspace(reference)
}

const FIELDS: &[&str] = &[
    "title", "prompt", "cron", "at", "timezone", "model", "thinking", "notify",
];

async fn list(State(app): State<AppState>, Extension(identity): Extension<Identity>) -> Handled {
    let schedules = with(&app, |ctx| {
        ctx.list(&identity.user)?
            .iter()
            .map(|schedule| ctx.view(schedule))
            .collect::<ApiResult<Vec<Value>>>()
    })?;
    Ok(ok(
        json!({ "schedules": schedules, "timezone": app.config.timezone }),
    ))
}

async fn create(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    ReqBody(body): ReqBody,
) -> Handled {
    let Body::Json(value) = &body else {
        return Err(ApiError::invalid_input().into());
    };
    let allowed: Vec<&str> = std::iter::once("workspaceId")
        .chain(FIELDS.iter().copied())
        .collect();
    let fields = object(value, &allowed).map_err(invalid)?;
    let workspace_id = fields.required("workspaceId", 1, 300).map_err(invalid)?;
    let mut input = route_input(&fields, true).map_err(invalid)?;
    input.workspace = Some(workspace_id);
    let view = with(&app, |ctx| {
        let schedule = ctx.create(&identity.user, &input, &workspace)?;
        ctx.view(&schedule)
    })?;
    Ok(json_response(201, &json!({ "schedule": view })))
}

async fn show(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(id): Path<String>,
    ReqBody(_): ReqBody,
) -> Handled {
    param(&id)?;
    let user = &identity.user;
    let body = with(&app, |ctx| {
        let schedule = ctx.view(&ctx.get(user, &id)?)?;
        let runs: Vec<Value> = ctx
            .runs(user, &id)?
            .iter()
            .map(|run| ctx.run_view(run))
            .collect();
        Ok(json!({ "schedule": schedule, "runs": runs }))
    })?;
    Ok(ok(body))
}

async fn update(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(id): Path<String>,
    ReqBody(body): ReqBody,
) -> Handled {
    param(&id)?;
    let Body::Json(value) = &body else {
        return Err(ApiError::invalid_input().into());
    };
    let allowed: Vec<&str> = ["workspaceId", "status"]
        .into_iter()
        .chain(FIELDS.iter().copied())
        .collect();
    let fields = object(value, &allowed).map_err(invalid)?;
    let workspace_id = fields.string("workspaceId", 1, 300).map_err(invalid)?;
    let mut input = route_input(&fields, false).map_err(invalid)?;
    let status = fields
        .choice("status", &["active", "paused"])
        .map_err(invalid)?;
    let user = &identity.user;
    let view = with(&app, |ctx| {
        let mut schedule = ctx.get(user, &id)?;
        let changes = workspace_id.is_some()
            || input.title.is_some()
            || input.prompt.is_some()
            || input.cron.is_some()
            || input.at.is_some()
            || input.timezone.is_some()
            || input.model.is_some()
            || input.thinking.is_some()
            || input.notify.is_some();
        if changes {
            input.workspace = workspace_id.clone();
            schedule = ctx.update(user, &id, &input, &workspace)?;
        }
        match status.as_deref() {
            Some("paused") => schedule = ctx.pause(user, &id)?,
            Some("active") => schedule = ctx.resume(user, &id)?,
            _ => {}
        }
        ctx.view(&schedule)
    })?;
    Ok(ok(json!({ "schedule": view })))
}

async fn remove(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(id): Path<String>,
    ReqBody(_): ReqBody,
) -> Handled {
    param(&id)?;
    with(&app, |ctx| ctx.delete(&identity.user, &id))?;
    Ok(no_content())
}

/// Run it now, or allow a missed run (`runId`).
async fn run(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(id): Path<String>,
    ReqBody(body): ReqBody,
) -> Handled {
    param(&id)?;
    // `request.body ?? {}`: no body, or a JSON `null`, is an empty one.
    let empty = json!({});
    let value = match &body {
        Body::None | Body::Json(Value::Null) => &empty,
        Body::Json(value) => value,
        Body::Raw { .. } => return Err(ApiError::invalid_input().into()),
    };
    let fields = object(value, &["runId"]).map_err(invalid)?;
    let run_id = fields.string("runId", 1, 40).map_err(invalid)?;
    let view = with(&app, |ctx| {
        let run = ctx.run_now(&identity.user, &id, run_id.as_deref())?;
        Ok(ctx.run_view(&run))
    })?;
    Ok(json_response(202, &json!({ "run": view })))
}

/// One run's state, time and reason, without the schedule's other runs.
async fn show_run(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path((id, run_id)): Path<(String, String)>,
) -> Handled {
    param(&id)?;
    param(&run_id)?;
    let run = super::run_state(&app, &identity.user, &id, &run_id)?;
    Ok(ok(json!({ "run": run })))
}

async fn dismiss(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path((id, run_id)): Path<(String, String)>,
    ReqBody(_): ReqBody,
) -> Handled {
    param(&id)?;
    param(&run_id)?;
    let view = with(&app, |ctx| {
        let run = ctx.dismiss(&identity.user, &id, &run_id)?;
        Ok(ctx.run_view(&run))
    })?;
    Ok(ok(json!({ "run": view })))
}
