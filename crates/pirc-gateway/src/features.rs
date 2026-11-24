//! The gateway's features around sessions: device pairing here, and the
//! hooks the core calls into the assistant's memory, delegations,
//! schedules and push notifications (their own modules).

use axum::Router;
use axum::extract::{Extension, Path, State};
use axum::http::{HeaderValue, Method, header};
use axum::middleware::Next;
use axum::response::Response;
use axum::routing::{delete, get, post};
use rusqlite::Connection;
use serde::Deserialize;
use serde_json::{Value, json};

use crate::app::{App, AppState, ReqBody};
use crate::auth::Identity;
use crate::error::{ApiError, ApiResult, json_response};
use crate::http::{no_content, ok};
use crate::routes::Handled;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/api/devices", get(list_devices).post(pair_device))
        .route("/api/devices/{id}", delete(revoke_device))
        .route("/api/delegations/{id}/stop", post(stop_delegation))
        .merge(crate::memory::routes())
        .merge(crate::schedules::routes())
        .merge(crate::calendar::routes())
        .merge(crate::pots::api::routes())
        .merge(crate::push::routes())
}

/// The routes of the TS gateway's device, memory and model-backend scopes, whose
/// replies (authentication failures included) are never cached.
fn no_store_route(method: &Method, path: &str) -> bool {
    let segments: Vec<&str> = path.trim_start_matches('/').split('/').collect();
    let one = |s: &str| !s.is_empty();
    match (method.as_str(), segments.as_slice()) {
        (_, ["api", "calendar" | "pots", ..]) => true,
        // Checkpoint manifests and file previews contain private workspace data;
        // deny caching for authentication/stale/invalid responses as well.
        (_, ["api", "sessions", id, "checkpoints", ..]) => one(id),
        ("GET", ["api", "sessions", id, "environment"]) => one(id),
        ("GET" | "POST", ["api", "devices"]) => true,
        ("DELETE", ["api", "devices", id]) => one(id),
        ("GET" | "POST", ["api", "providers"]) => true,
        ("GET", ["api", "providers", "presets"]) => true,
        ("POST", ["api", "providers", "discover" | "test"]) => true,
        ("PUT" | "DELETE", ["api", "providers", id]) => one(id),
        ("POST", ["api", "provider-auth", "sessions"]) => true,
        ("GET" | "DELETE", ["api", "provider-auth", "sessions", id]) => one(id),
        ("POST", ["api", "provider-auth", "sessions", id, "input"]) => one(id),
        ("GET", ["api", "memory"]) => true,
        ("GET", ["api", "memory", "entries", id, "history"]) => one(id),
        ("POST", ["api", "memory", "proposals", id, "approve" | "reject"]) => one(id),
        ("POST", ["api", "memory", "entries", id, "forget" | "restore"]) => one(id),
        // A project deletion's preview lists memory entries.
        ("GET" | "POST", ["api", "workspaces", id, "deletion"]) => one(id),
        _ => false,
    }
}

/// Adds `cache-control: no-store` to the replies of [`no_store_route`]s.
pub async fn no_store(request: axum::extract::Request, next: Next) -> Response {
    let cached = !no_store_route(request.method(), request.uri().path());
    let mut response = next.run(request).await;
    if !cached {
        response
            .headers_mut()
            .insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    }
    response
}

/// Device management needs forward auth: a device token can neither mint
/// nor revoke tokens (the auth middleware refuses it; checked again here).
fn owner(identity: &Identity) -> ApiResult<&str> {
    if identity.device_id.is_some() && !identity.management_authorized {
        return Err(ApiError::new(
            403,
            "forbidden",
            "Device tokens cannot manage devices",
        ));
    }
    Ok(&identity.user)
}

async fn list_devices(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
) -> Handled {
    let devices = app.devices.list(owner(&identity)?)?;
    Ok(ok(json!({ "devices": devices })))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct PairBody {
    name: String,
}

async fn pair_device(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    ReqBody(body): ReqBody,
) -> Handled {
    let user = owner(&identity)?;
    let PairBody { name } = body.parse()?;
    let name = name.trim_matches(pirc_config::text::is_space);
    if !(1..=100).contains(&name.encode_utf16().count()) {
        return Err(ApiError::invalid_input().into());
    }
    let (device, token) = app.devices.create(user, name)?;
    Ok(json_response(
        201,
        &json!({ "device": device, "token": token }),
    ))
}

async fn revoke_device(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(id): Path<String>,
) -> Handled {
    let user = owner(&identity)?;
    if id.encode_utf16().count() > 200 {
        return Err(ApiError::invalid_input().into());
    }
    app.devices.revoke(user, &id)?;
    Ok(no_content())
}

/// Stop a delegation's run from the chat that started it.
async fn stop_delegation(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(id): Path<String>,
) -> Handled {
    if id.encode_utf16().count() > 40 {
        return Err(ApiError::invalid_input().into());
    }
    Ok(ok(
        crate::delegations::stop(&app, &identity.user, &id).await?
    ))
}

impl App {
    /// Memory hints (`memory=1`) for `user`, after memory's own update.
    pub fn memory_changed(&self, user: &str) {
        crate::memory::changed(self, user);
        self.hints.memory.notify(&user.to_owned());
    }

    /// Forget what the assistant's memory learned from a deleted chat (in
    /// the deletion's transaction).
    pub fn forget_session_memory(
        &self,
        conn: &Connection,
        user: &str,
        session_id: &str,
    ) -> ApiResult<()> {
        crate::memory::forget_session(self, conn, user, session_id)
    }

    /// Confirmations the gateway asks for itself (delegations, schedule and
    /// calendar proposals, memory), shown with the node's interactions.
    pub fn pending_gateway_interactions(&self, session_id: &str, user: &str) -> Vec<Value> {
        let mut pending = crate::delegations::pending_interactions(self, session_id);
        pending.extend(crate::schedules::pending_interactions(self, session_id));
        pending.extend(crate::calendar::agent::pending_interactions(
            self, session_id,
        ));
        pending.extend(crate::memory::pending_interactions(self, session_id, user));
        pending
    }

    /// Byte offsets of a node's mirrored workspace-memory ledgers.
    pub fn mirror_watermarks(&self, node_id: &str) -> Value {
        crate::memory_records::watermarks(self, node_id)
    }

    /// Store a mirrored chunk; the ledger's new watermark.
    pub fn on_mirror(
        &self,
        node_id: &str,
        ledger_key: &str,
        offset: u64,
        end: u64,
        reset: bool,
        lines: &[Value],
    ) -> ApiResult<u64> {
        crate::memory_records::ingest(self, node_id, ledger_key, offset, end, reset, lines)
    }
}

/// Answer one of the gateway's own confirmations; `None` when the interaction
/// is the node's.
pub fn answer_gateway_interaction(
    app: &AppState,
    session_id: &str,
    interaction_id: &str,
    user: &str,
    answer: Option<Value>,
) -> ApiResult<Option<Value>> {
    if let Some(answered) =
        crate::memory::answer(app, session_id, interaction_id, user, answer.as_ref())?
    {
        app.memory_changed(user);
        return Ok(Some(answered));
    }
    if let Some(answered) =
        crate::delegations::answer(app, session_id, interaction_id, user, answer.as_ref())?
    {
        return Ok(Some(answered));
    }
    if let Some(answered) =
        crate::schedules::answer(app, session_id, interaction_id, user, answer.as_ref())?
    {
        return Ok(Some(answered));
    }
    crate::calendar::agent::answer(app, session_id, interaction_id, user, answer.as_ref())
}

/// Start the features' background work; fails on unusable push keys.
pub fn start(app: &AppState) -> Result<(), String> {
    crate::push::start(app)?;
    crate::delegations::start(app);
    crate::schedules::start(app);
    crate::calendar::reminders::start(app);
    crate::pots::runtime::start(app);
    Ok(())
}
