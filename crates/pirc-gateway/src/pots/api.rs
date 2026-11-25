//! `/api/pots`: create, read, update and pause pots, the owner's pot
//! settings, threads, and model approvals (plans/pots.md, API sketch). Device
//! tokens may use these like a browser; every query is scoped to the signed-in
//! owner.

use axum::Router;
use axum::extract::{Extension, Path, State};
use axum::routing::{get, post};
use serde::Deserialize;
use serde_json::{Value, json};

use super::approvals::{self, Answer, ApprovalState};
use super::budget::{self, RequestState};
use super::store::{self, Pot, PotInput, PotPatch, PotState, Settings};
use super::threads;
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
        .route("/api/pots/{id}/thread", get(direct_thread))
        .route("/api/threads", get(list_threads).post(create_group))
        .route("/api/threads/{id}", get(read_thread))
        .route(
            "/api/threads/{id}/messages",
            get(list_messages).post(post_message),
        )
        .route("/api/activity", get(list_activity))
        .route("/api/pot-works", get(list_works))
        .route("/api/pot-works/{id}/take-over", post(take_over_work))
        .route("/api/pots/{id}/view", get(pot_view))
        .route("/api/model-approvals", get(list_approvals))
        .route("/api/model-approvals/{id}/answer", post(answer_approval))
        .route("/api/budget-requests", get(list_budget_requests))
        .route(
            "/api/budget-requests/{id}/answer",
            post(answer_budget_request),
        )
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
    app.activity_changed(&identity.user);
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
    app.activity_changed(&identity.user);
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
    app.activity_changed(&identity.user);
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

async fn direct_thread(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(id): Path<String>,
) -> ApiResult<axum::Json<Value>> {
    let thread = threads::direct(&app.db.lock(), &identity.user, &id)?;
    Ok(axum::Json(json!({ "thread": thread })))
}

async fn list_threads(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
) -> ApiResult<axum::Json<Value>> {
    let threads = threads::list(&app.db.lock(), &identity.user)?;
    Ok(axum::Json(json!({ "threads": threads })))
}

async fn create_group(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    ReqBody(body): ReqBody,
) -> ApiResult<(axum::http::StatusCode, axum::Json<Value>)> {
    let input: threads::GroupInput = body.parse()?;
    let thread = threads::create_group(&app.db.lock(), &identity.user, input)?;
    app.threads_changed(&identity.user);
    Ok((
        axum::http::StatusCode::CREATED,
        axum::Json(json!({ "thread": thread })),
    ))
}

async fn read_thread(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(id): Path<String>,
) -> ApiResult<axum::Json<Value>> {
    let thread = threads::get(&app.db.lock(), &identity.user, &id)?;
    Ok(axum::Json(json!({ "thread": thread })))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Page {
    before: Option<i64>,
}

async fn list_messages(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(id): Path<String>,
    axum::extract::Query(page): axum::extract::Query<Page>,
) -> ApiResult<axum::Json<Value>> {
    let messages = threads::messages(&app.db.lock(), &identity.user, &id, page.before)?;
    Ok(axum::Json(json!({ "messages": messages })))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct NewMessage {
    body: String,
    #[serde(default)]
    mentions: Vec<String>,
    #[serde(default)]
    all: bool,
}

async fn post_message(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(id): Path<String>,
    ReqBody(body): ReqBody,
) -> ApiResult<(axum::http::StatusCode, axum::Json<Value>)> {
    let input: NewMessage = body.parse()?;
    let (message, woken) = threads::post_user(
        &app.db.lock(),
        &identity.user,
        &id,
        &input.body,
        input.mentions,
        input.all,
    )?;
    for pot in &woken {
        super::runtime::kick(&app, &identity.user, pot);
    }
    app.threads_changed(&identity.user);
    Ok((
        axum::http::StatusCode::CREATED,
        axum::Json(json!({ "message": message, "woken": woken })),
    ))
}

#[derive(Deserialize)]
struct ApprovalFilter {
    state: Option<String>,
}

async fn list_approvals(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    axum::extract::Query(filter): axum::extract::Query<ApprovalFilter>,
) -> ApiResult<axum::Json<Value>> {
    let state = match filter.state.as_deref() {
        None => None,
        Some(value) => Some(ApprovalState::parse(value).ok_or_else(|| {
            ApiError::new(
                400,
                "invalid_input",
                "state is pending, allowed_once, denied or used",
            )
        })?),
    };
    let approvals = approvals::list(&app.db.lock(), &identity.user, state)?;
    Ok(axum::Json(json!({ "approvals": approvals })))
}

async fn answer_approval(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(id): Path<String>,
    ReqBody(body): ReqBody,
) -> ApiResult<axum::Json<Value>> {
    let input: Answer = body.parse()?;
    let approval = approvals::answer(&mut app.db.lock(), &identity.user, &id, input)?;
    app.approvals_changed(&identity.user);
    app.activity_changed(&identity.user);
    super::runtime::kick(&app, &identity.user, &approval.pot_id);
    Ok(axum::Json(json!({ "approval": approval })))
}

async fn list_activity(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    axum::extract::Query(query): axum::extract::Query<super::activity::Query>,
) -> ApiResult<axum::Json<super::activity::Page>> {
    Ok(axum::Json(super::activity::list(
        &app.db.lock(),
        &identity.user,
        &query,
    )?))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ViewPage {
    before: Option<String>,
}

async fn pot_view(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(id): Path<String>,
    axum::extract::Query(page): axum::extract::Query<ViewPage>,
) -> ApiResult<axum::Json<super::view::View>> {
    Ok(axum::Json(super::view::view(
        &app.db.lock(),
        &identity.user,
        &id,
        page.before.as_deref(),
    )?))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WorkFilter {
    pot_id: Option<String>,
}

async fn list_works(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    axum::extract::Query(filter): axum::extract::Query<WorkFilter>,
) -> ApiResult<axum::Json<Value>> {
    let works = super::work::list(&app.db.lock(), &identity.user, filter.pot_id.as_deref())?;
    Ok(axum::Json(json!({ "works": works })))
}

async fn take_over_work(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(id): Path<String>,
) -> ApiResult<axum::Json<Value>> {
    let work = super::work::take_over(&app.db.lock(), &identity.user, &id)?;
    app.pots_changed(&identity.user);
    super::runtime::kick(&app, &identity.user, &work.pot_id);
    Ok(axum::Json(json!({ "work": work })))
}

#[derive(Deserialize)]
struct BudgetFilter {
    state: Option<String>,
}

async fn list_budget_requests(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    axum::extract::Query(filter): axum::extract::Query<BudgetFilter>,
) -> ApiResult<axum::Json<Value>> {
    let state = match filter.state.as_deref() {
        None => None,
        Some(value) => Some(RequestState::parse(value).ok_or_else(|| {
            ApiError::new(
                400,
                "invalid_input",
                "state is pending, approved, approved_amount or denied",
            )
        })?),
    };
    let requests = budget::list(&app.db.lock(), &identity.user, state)?;
    Ok(axum::Json(json!({ "budgetRequests": requests })))
}

async fn answer_budget_request(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(id): Path<String>,
    ReqBody(body): ReqBody,
) -> ApiResult<axum::Json<Value>> {
    let input: budget::Answer = body.parse()?;
    let request = budget::answer(&mut app.db.lock(), &identity.user, &id, input)?;
    app.budget_requests_changed(&identity.user);
    app.threads_changed(&identity.user);
    app.activity_changed(&identity.user);
    super::runtime::kick(&app, &identity.user, &request.pot_id);
    Ok(axum::Json(json!({ "budgetRequest": request })))
}
