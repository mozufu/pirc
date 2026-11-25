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
use super::store::{self, Pot, PotInput, PotPatch, PotState, ScopeKind, Settings};
use super::threads;
use crate::app::{AppState, ReqBody};
use crate::auth::Identity;
use crate::db::Store;
use crate::error::{ApiError, ApiResult};

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/api/pots", get(list).post(create))
        .route("/api/pots/settings", get(settings).patch(update_settings))
        .route("/api/pots/{id}", get(read).patch(update))
        .route("/api/pots/{id}/pause", post(pause))
        .route("/api/pots/{id}/resume", post(resume))
        .route("/api/pots/{id}/restore", post(restore))
        .route("/api/pots/{id}/thread", get(direct_thread))
        .route("/api/threads", get(list_threads).post(create_group))
        .route(
            "/api/threads/{id}",
            get(read_thread).patch(update_thread).delete(delete_thread),
        )
        .route("/api/threads/{id}/read", post(read_thread_now))
        .route(
            "/api/threads/{id}/messages",
            get(list_messages).post(post_message),
        )
        .route("/api/activity", get(list_activity))
        .route("/api/pots/{id}/held", get(held_items))
        .route("/api/pots/{id}/memory", get(pot_memory))
        .route(
            "/api/pots/{id}/memory/{entry}",
            axum::routing::delete(forget_pot_memory),
        )
        .route("/api/pots/{id}/retire/preview", post(retire_preview))
        .route("/api/pots/{id}/retire", post(retire_pot))
        .route("/api/handovers", get(list_handovers).post(create_handover))
        .route("/api/handovers/{id}", get(read_handover))
        .route("/api/handovers/{id}/confirm", post(confirm_handover))
        .route("/api/handovers/{id}/reject", post(reject_handover))
        .route("/api/observation-notifications", get(list_notifications))
        .route(
            "/api/observation-notifications/{id}/read",
            post(read_notification),
        )
        .route("/api/pot-works", get(list_works))
        .route("/api/pot-works/{id}", get(read_work))
        .route("/api/pot-works/{id}/take-over", post(take_over_work))
        .route("/api/pots/{id}/view", get(pot_view))
        .route("/api/model-approvals", get(list_approvals))
        .route("/api/model-approvals/{id}", get(read_approval))
        .route("/api/model-approvals/{id}/answer", post(answer_approval))
        .route("/api/budget-requests", get(list_budget_requests))
        .route("/api/budget-requests/{id}", get(read_budget_request))
        .route(
            "/api/budget-requests/{id}/answer",
            post(answer_budget_request),
        )
        .route("/api/causal-roots/{id}", get(read_causal_root))
        .route("/api/causal-roots/{id}/resume", post(resume_causal_root))
        .route("/api/causal-roots/{id}/stop", post(stop_causal_root))
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
    if let Some(image) = &input.profile.avatar_image {
        crate::images::require_owned(&app.db.lock(), &identity.user, image)?;
    }
    for scope in &input.permissions.observe {
        match scope.kind {
            ScopeKind::Workspace | ScopeKind::Project if !scope.r#ref.is_empty() => {
                app.db.lock().get_workspace(&scope.r#ref)?;
                crate::routes::require_workspace_visible(app, identity, &scope.r#ref)?;
            }
            ScopeKind::Session => {
                let owned = app
                    .db
                    .lock()
                    .get_session(&scope.r#ref)
                    .ok()
                    .is_some_and(|s| s.owner_user.as_deref() == Some(identity.user.as_str()));
                if !owned {
                    return Err(ApiError::new(
                        400,
                        "invalid_input",
                        "An observed session must be one of yours",
                    ));
                }
            }
            _ => {}
        }
    }
    Ok(())
}

/// A pot as lists and screens read it: the stored input plus what it is doing
/// now, what waits for the user and what is left of its budget.
fn public(app: &AppState, conn: &rusqlite::Connection, owner: &str, pot: &Pot) -> Value {
    let mut value = serde_json::to_value(pot).unwrap_or_default();
    let live = pot
        .session_id
        .as_deref()
        .and_then(|session| conn.get_session(session).ok().map(|s| (s.node_id, s.id)));
    let running = live.is_some_and(|(node, session)| {
        app.activity_of(node.as_deref(), &session)
            .is_some_and(|activity| activity.run.is_some())
    });
    let delivering: i64 = conn
        .query_row(
            "SELECT count(*) FROM pot_wakes WHERE pot_id=?1 AND state IN ('delivering','delivered')",
            [&pot.id],
            |r| r.get(0),
        )
        .unwrap_or(0);
    value["status"] = json!(if pot.state != PotState::Active {
        "unavailable"
    } else if running || delivering > 0 {
        "working"
    } else {
        "idle"
    });
    let count = |sql: &str| -> i64 { conn.query_row(sql, [&pot.id], |r| r.get(0)).unwrap_or(0) };
    value["needsYou"] = json!(
        count("SELECT count(*) FROM model_approvals WHERE pot_id=?1 AND state='pending'")
            + count("SELECT count(*) FROM budget_requests WHERE pot_id=?1 AND state='pending'")
            + count("SELECT count(*) FROM pot_handovers WHERE from_pot_id=?1 AND state='proposed'")
            + count(
                "SELECT count(*) FROM causal_roots WHERE initiator_pot=?1 AND state='suspended'"
            )
    );
    if let Ok(status) =
        super::budget::status_for(conn, owner, &pot.id, app.config.timezone.as_str())
    {
        value["budgetLeft"] = json!({
            "moneyMicros": status["money"]["remainingMicros"],
            "tokens": status["tokens"]["remaining"],
        });
    }
    value
}

fn ok(app: &AppState, conn: &rusqlite::Connection, owner: &str, pot: &Pot) -> axum::Json<Value> {
    axum::Json(json!({ "pot": public(app, conn, owner, pot) }))
}

async fn list(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
) -> ApiResult<axum::Json<Value>> {
    let conn = app.db.lock();
    let pots: Vec<Value> = store::list(&conn, &identity.user)?
        .iter()
        .map(|pot| public(&app, &conn, &identity.user, pot))
        .collect();
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
    let shown = public(&app, &app.db.lock(), &identity.user, &pot);
    app.pots_changed(&identity.user);
    app.activity_changed(&identity.user);
    Ok((
        axum::http::StatusCode::CREATED,
        axum::Json(json!({ "pot": shown })),
    ))
}

async fn read(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(id): Path<String>,
) -> ApiResult<axum::Json<Value>> {
    let conn = app.db.lock();
    let pot = store::read(&conn, &identity.user, &id)?;
    Ok(ok(&app, &conn, &identity.user, &pot))
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
    let shown = public(&app, &app.db.lock(), &identity.user, &pot);
    app.pots_changed(&identity.user);
    app.activity_changed(&identity.user);
    Ok(axum::Json(json!({ "pot": shown })))
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
    let shown = public(app, &app.db.lock(), &identity.user, &pot);
    app.pots_changed(&identity.user);
    app.activity_changed(&identity.user);
    if pot.state == PotState::Active {
        super::runtime::kick(app, &identity.user, id);
    }
    Ok(axum::Json(json!({ "pot": shown })))
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
    let posted = threads::post_user(
        &app.db.lock(),
        &identity.user,
        &id,
        &input.body,
        input.mentions,
        input.all,
    )?;
    for pot in &posted.woken {
        super::runtime::kick(&app, &identity.user, pot);
    }
    app.threads_changed(&identity.user);
    app.causal_roots_changed(&identity.user);
    Ok((
        axum::http::StatusCode::CREATED,
        axum::Json(json!({
            "message": posted.message,
            "woken": posted.woken,
            "refused": posted.refused,
        })),
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
    app.causal_roots_changed(&identity.user);
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
    app.causal_roots_changed(&identity.user);
    super::runtime::kick(&app, &identity.user, &request.pot_id);
    Ok(axum::Json(json!({ "budgetRequest": request })))
}

async fn read_work(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(id): Path<String>,
) -> ApiResult<axum::Json<Value>> {
    let work = super::work::read(&app.db.lock(), &identity.user, &id)?;
    Ok(axum::Json(json!({ "work": work })))
}

async fn read_approval(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(id): Path<String>,
) -> ApiResult<axum::Json<Value>> {
    let approval = approvals::read(&app.db.lock(), &identity.user, &id)?;
    Ok(axum::Json(json!({ "approval": approval })))
}

async fn read_budget_request(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(id): Path<String>,
) -> ApiResult<axum::Json<Value>> {
    let request = budget::read(&app.db.lock(), &identity.user, &id)?;
    Ok(axum::Json(json!({ "budgetRequest": request })))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct NotificationFilter {
    state: Option<String>,
}

async fn list_notifications(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    axum::extract::Query(filter): axum::extract::Query<NotificationFilter>,
) -> ApiResult<axum::Json<Value>> {
    let notifications =
        super::observe::notifications(&app.db.lock(), &identity.user, filter.state.as_deref())?;
    Ok(axum::Json(json!({ "notifications": notifications })))
}

async fn read_notification(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(id): Path<String>,
) -> ApiResult<axum::Json<Value>> {
    let notification = super::observe::mark_read(&app.db.lock(), &identity.user, &id)?;
    app.notifications_changed(&identity.user);
    Ok(axum::Json(json!({ "notification": notification })))
}

async fn held_items(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(id): Path<String>,
) -> ApiResult<axum::Json<Value>> {
    let items = super::handover::held(&app.db.lock(), &identity.user, &id)?;
    Ok(axum::Json(json!({ "items": items })))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct HandoverFilter {
    state: Option<String>,
}

async fn list_handovers(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    axum::extract::Query(filter): axum::extract::Query<HandoverFilter>,
) -> ApiResult<axum::Json<Value>> {
    let handovers = super::handover::list(&app.db.lock(), &identity.user, filter.state.as_deref())?;
    Ok(axum::Json(json!({ "handovers": handovers })))
}

async fn create_handover(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    ReqBody(body): ReqBody,
) -> ApiResult<(axum::http::StatusCode, axum::Json<Value>)> {
    let input: super::handover::NewHandover = body.parse()?;
    let handover = super::handover::propose(
        &app.db.lock(),
        &identity.user,
        input,
        super::handover::ProposedBy::User,
    )?;
    app.pots_changed(&identity.user);
    app.activity_changed(&identity.user);
    Ok((
        axum::http::StatusCode::CREATED,
        axum::Json(json!({ "handover": handover })),
    ))
}

async fn read_handover(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(id): Path<String>,
) -> ApiResult<axum::Json<Value>> {
    let handover = super::handover::get(&app.db.lock(), &identity.user, &id)?;
    Ok(axum::Json(json!({ "handover": handover })))
}

async fn confirm_handover(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(id): Path<String>,
    body: ReqBody,
) -> ApiResult<axum::Json<Value>> {
    let Revision { revision } = body.0.parse()?;
    let (handover, kick) =
        super::handover::confirm(&mut app.db.lock(), &identity.user, &id, revision)?;
    app.pots_changed(&identity.user);
    app.activity_changed(&identity.user);
    if let Some(pot) = kick {
        super::runtime::kick(&app, &identity.user, &pot);
    }
    Ok(axum::Json(json!({ "handover": handover })))
}

async fn reject_handover(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(id): Path<String>,
) -> ApiResult<axum::Json<Value>> {
    let handover = super::handover::reject(&app.db.lock(), &identity.user, &id)?;
    app.pots_changed(&identity.user);
    Ok(axum::Json(json!({ "handover": handover })))
}

async fn retire_preview(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(id): Path<String>,
    ReqBody(body): ReqBody,
) -> ApiResult<axum::Json<Value>> {
    let plan: super::retire::Plan = body.parse()?;
    Ok(axum::Json(super::retire::preview(
        &app.db.lock(),
        &identity.user,
        &id,
        &plan,
    )?))
}

async fn retire_pot(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(id): Path<String>,
    ReqBody(body): ReqBody,
) -> ApiResult<axum::Json<Value>> {
    let input: super::retire::Retire = body.parse()?;
    let retired = super::retire::retire(&mut app.db.lock(), &identity.user, &id, input)?;
    for pot in &retired.woken {
        super::runtime::kick(&app, &identity.user, pot);
    }
    if let Some(session) = &retired.session_id {
        delete_pot_session(&app, &identity.user, session).await;
    }
    app.pots_changed(&identity.user);
    app.threads_changed(&identity.user);
    app.activity_changed(&identity.user);
    Ok(axum::Json(retired.result))
}

/// A deleted pot's session goes too; a node that cannot be reached leaves it
/// marked as being deleted.
async fn delete_pot_session(app: &AppState, owner: &str, session_id: &str) {
    let session = match app.db.lock().get_session(session_id) {
        Ok(session) => session,
        Err(_) => return,
    };
    if let Err(error) = app.db.lock().begin_session_deletion(session_id, owner) {
        crate::log::warn(&format!("pot session {session_id}: {}", error.message));
        return;
    }
    let (Some(node), Some(remote)) = (&session.node_id, &session.pi_session_id) else {
        return;
    };
    let deleted = crate::dispatch::node_request(
        app,
        node,
        owner,
        pirc_protocol::HttpMethod::Delete,
        format!(
            "/api/sessions/{}",
            crate::routes::urlencoding_component(remote)
        ),
        None,
    )
    .await;
    if let Err(failure) = deleted {
        crate::log::warn(&format!("pot session {session_id}: {}", failure.0));
        return;
    }
    let conn = app.db.lock();
    let finished = crate::db::atomic(&conn, |conn| {
        app.forget_session_memory(conn, owner, session_id)?;
        conn.finish_session_deletion(session_id)
    });
    if let Err(error) = finished {
        crate::log::warn(&format!("pot session {session_id}: {}", error.message));
    }
    app.events.forget(session_id);
    app.sessions_changed(Some(owner));
}

async fn read_causal_root(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(id): Path<String>,
) -> ApiResult<axum::Json<Value>> {
    let root = super::roots::read(&app.db.lock(), &identity.user, &id)?;
    Ok(axum::Json(json!({ "causalRoot": root })))
}

/// The user resumes a suspended root; its queued wakes may deliver again.
async fn resume_causal_root(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(id): Path<String>,
) -> ApiResult<axum::Json<Value>> {
    let (root, pots) = {
        let conn = app.db.lock();
        let root = super::roots::resume(&conn, &identity.user, &id)?;
        let pots = super::roots::queued_pots(&conn, &id)?;
        (root, pots)
    };
    for pot in &pots {
        super::runtime::kick(&app, &identity.user, pot);
    }
    app.causal_roots_changed(&identity.user);
    app.activity_changed(&identity.user);
    Ok(axum::Json(json!({ "causalRoot": root, "kicked": pots })))
}

/// The user stops a root; its queued wakes fail. A pot cannot do either.
async fn stop_causal_root(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(id): Path<String>,
) -> ApiResult<axum::Json<Value>> {
    let root = super::roots::stop(&app.db.lock(), &identity.user, &id)?;
    app.causal_roots_changed(&identity.user);
    app.activity_changed(&identity.user);
    Ok(axum::Json(json!({ "causalRoot": root })))
}

async fn pot_memory(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(id): Path<String>,
) -> ApiResult<axum::Json<Value>> {
    let notes = super::memory::list(&app.db.lock(), &identity.user, &id)?;
    Ok(axum::Json(
        json!({ "notes": notes, "budget": super::memory::BUDGET }),
    ))
}

async fn forget_pot_memory(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path((id, entry)): Path<(String, String)>,
) -> ApiResult<axum::http::StatusCode> {
    super::memory::forget(&app.db.lock(), &identity.user, &id, &entry)?;
    app.pots_changed(&identity.user);
    Ok(axum::http::StatusCode::NO_CONTENT)
}

async fn update_thread(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(id): Path<String>,
    ReqBody(body): ReqBody,
) -> ApiResult<axum::Json<Value>> {
    let patch: threads::GroupPatch = body.parse()?;
    let thread = threads::update_group(&app.db.lock(), &identity.user, &id, patch)?;
    app.threads_changed(&identity.user);
    Ok(axum::Json(json!({ "thread": thread })))
}

async fn delete_thread(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(id): Path<String>,
) -> ApiResult<axum::http::StatusCode> {
    threads::delete_group(&app.db.lock(), &identity.user, &id)?;
    app.threads_changed(&identity.user);
    Ok(axum::http::StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ReadPosition {
    seq: i64,
}

async fn read_thread_now(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(id): Path<String>,
    ReqBody(body): ReqBody,
) -> ApiResult<axum::Json<Value>> {
    let ReadPosition { seq } = body.parse()?;
    let thread = threads::mark_read(&app.db.lock(), &identity.user, &id, seq)?;
    Ok(axum::Json(json!({ "thread": thread })))
}
