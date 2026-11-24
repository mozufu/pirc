//! `/api/pots`: create, read, update and pause pots, and the owner's pot
//! settings (plans/pots.md, API sketch). Device tokens may use these like a
//! browser; every query is scoped to the signed-in owner.

use axum::Router;
use axum::extract::{Extension, Path, State};
use axum::routing::{get, post};
use serde::Deserialize;
use serde_json::{Value, json};

use super::store::{self, Pot, PotInput, PotPatch, PotState, Settings};
use crate::app::{AppState, ReqBody};
use crate::auth::Identity;
use crate::error::{ApiError, ApiResult};

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/api/pots", get(list).post(create))
        .route("/api/pots/settings", get(settings).patch(update_settings))
        .route("/api/pots/{id}", get(read).patch(update))
        .route("/api/pots/{id}/pause", post(pause))
        .route("/api/pots/{id}/resume", post(resume))
        .route("/api/pots/{id}/archive", post(archive))
        .route("/api/pots/{id}/restore", post(restore))
}

/// Models must be ones the Gateway serves; locations workspaces the owner sees.
fn check(app: &AppState, identity: &Identity, input: &PotInput) -> ApiResult<()> {
    let config = app.backends.merged();
    let served = |provider: &str, model: &str| {
        config
            .providers
            .get(provider)
            .is_some_and(|p| p.models.iter().any(|m| m.id == model))
    };
    let m = &input.models;
    let all = std::iter::once((&m.main.provider, &m.main.model))
        .chain(m.fallbacks.iter().map(|c| (&c.provider, &c.model)))
        .chain(m.work_models.iter().map(|w| (&w.provider, &w.model)));
    for (provider, model) in all {
        if !served(provider, model) {
            return Err(ApiError::new(
                400,
                "unknown_model",
                format!("{provider}/{model} is not a model this Gateway serves"),
            ));
        }
    }
    for location in &input.permissions.work_locations {
        crate::routes::require_workspace_visible(app, identity, &location.workspace_id)?;
    }
    Ok(())
}

fn ok(pot: Pot) -> axum::Json<Value> {
    axum::Json(json!({ "pot": pot }))
}

async fn list(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
) -> ApiResult<axum::Json<Value>> {
    let pots = store::list(&app.db.lock(), &identity.user)?;
    Ok(axum::Json(json!({ "pots": pots })))
}

async fn create(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    ReqBody(body): ReqBody,
) -> ApiResult<(axum::http::StatusCode, axum::Json<Value>)> {
    let input: PotInput = body.parse()?;
    check(&app, &identity, &input)?;
    let pot = store::create(&mut app.db.lock(), &identity.user, input)?;
    app.pots_changed(&identity.user);
    Ok((axum::http::StatusCode::CREATED, ok(pot)))
}

async fn read(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(id): Path<String>,
) -> ApiResult<axum::Json<Value>> {
    Ok(ok(store::read(&app.db.lock(), &identity.user, &id)?))
}

async fn update(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(id): Path<String>,
    ReqBody(body): ReqBody,
) -> ApiResult<axum::Json<Value>> {
    let patch: PotPatch = body.parse()?;
    // Check against the current pot without holding the lock (the visibility
    // check takes it); the store's revision check covers a change in between.
    let mut next = store::read(&app.db.lock(), &identity.user, &id)?.input;
    if let Some(models) = &patch.models {
        next.models = models.clone();
    }
    if let Some(permissions) = &patch.permissions {
        next.permissions = permissions.clone();
    }
    check(&app, &identity, &next)?;
    let pot = store::update(&mut app.db.lock(), &identity.user, &id, patch)?;
    app.pots_changed(&identity.user);
    Ok(ok(pot))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Revision {
    revision: i64,
}

async fn transition(
    app: &AppState,
    identity: &Identity,
    id: &str,
    body: ReqBody,
    to: PotState,
) -> ApiResult<axum::Json<Value>> {
    let Revision { revision } = body.0.parse()?;
    let pot = store::set_state(&mut app.db.lock(), &identity.user, id, revision, to)?;
    app.pots_changed(&identity.user);
    if pot.state == PotState::Active {
        super::runtime::kick(app, &identity.user, id);
    }
    Ok(ok(pot))
}

async fn pause(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(id): Path<String>,
    body: ReqBody,
) -> ApiResult<axum::Json<Value>> {
    transition(&app, &identity, &id, body, PotState::Paused).await
}

async fn resume(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(id): Path<String>,
    body: ReqBody,
) -> ApiResult<axum::Json<Value>> {
    transition(&app, &identity, &id, body, PotState::Active).await
}

async fn archive(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(id): Path<String>,
    body: ReqBody,
) -> ApiResult<axum::Json<Value>> {
    transition(&app, &identity, &id, body, PotState::Archived).await
}

async fn restore(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(id): Path<String>,
    body: ReqBody,
) -> ApiResult<axum::Json<Value>> {
    transition(&app, &identity, &id, body, PotState::Paused).await
}

async fn settings(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
) -> ApiResult<axum::Json<Value>> {
    let settings = store::settings(&app.db.lock(), &identity.user)?;
    Ok(axum::Json(json!({ "settings": settings })))
}

async fn update_settings(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    ReqBody(body): ReqBody,
) -> ApiResult<axum::Json<Value>> {
    let next: Settings = body.parse()?;
    if !matches!(next.on_exhausted.as_str(), "pause_all" | "ask") {
        return Err(ApiError::new(
            400,
            "invalid_input",
            "onExhausted is pause_all or ask",
        ));
    }
    let settings = store::update_settings(&mut app.db.lock(), &identity.user, next)?;
    app.pots_changed(&identity.user);
    Ok(axum::Json(json!({ "settings": settings })))
}
