//! The gateway's shared state and its HTTP router
//! (`apps/gateway/src/daemon/app.ts`).

use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::{Arc, Mutex, RwLock};

use axum::Router;
use axum::extract::{ConnectInfo, FromRequest, Request, State};
use axum::http::{HeaderMap, Method, Uri, header};
use axum::middleware::{self, Next};
use axum::response::{IntoResponse, Response};
use axum::routing::{delete, get, post};
use pirc_config::GatewayConfig;
use pirc_protocol::{HttpMethod, Models, NodeHttpRequest, NodeHttpResponse};
use pirc_providers::backends::BackendService;
use serde_json::Value;

use crate::auth::{self, Identity, RequestInfo};
use crate::db::{Db, Session, Store};
use crate::devices::DeviceTokens;
use crate::error::{ApiError, ApiResult, json_response};
use crate::events::EventHub;
use crate::hints::Hints;
use crate::http::{self, Body};
use crate::management::NativeManagementGrants;
use crate::node_events::LiveActivity;
use crate::nodes::NodeRegistry;
use crate::{routes, sockets};

/// Everything the routes share.
pub struct App {
    pub config: GatewayConfig,
    pub modes: RwLock<Arc<pirc_config::modes::ModeCatalog>>,
    pub db: Arc<Db>,
    pub devices: Arc<DeviceTokens>,
    pub management: Arc<NativeManagementGrants>,
    pub events: Arc<EventHub>,
    pub hints: Hints,
    pub nodes: Arc<NodeRegistry>,
    /// Open runs and write leases each node reported, by gateway session id.
    pub activity: Mutex<HashMap<String, HashMap<String, LiveActivity>>>,
    /// Model backends: `PIRC_MODELS_FILE` (replaced on reload), web-managed
    /// backends and subscription accounts.
    pub backends: Arc<BackendService>,
    pub inference: pirc_providers::Inference,
    /// The feature modules' own state (push keys, schedulers, caches).
    pub slots: crate::slots::Slots,
}

pub type AppState = Arc<App>;

/// A claimed session together with its node.
pub struct Claimed {
    pub session: Session,
    pub node_id: String,
    pub pi_session_id: String,
}

impl App {
    /// The app around its backend settings. Backend changes cancel
    /// inference in flight and send nodes the new catalog.
    pub fn try_new(
        config: GatewayConfig,
        db: Arc<Db>,
        backends: Arc<BackendService>,
        catalog: pirc_config::modes::ModeCatalog,
    ) -> ApiResult<Arc<Self>> {
        crate::conversation_bindings::policies::install_catalog(&db.lock(), &catalog)?;
        let devices = DeviceTokens::new(
            db.clone(),
            config.device_token_idle_ms,
            config.device_token_max_age_ms,
        );
        let management = Arc::new(NativeManagementGrants::new(devices.clone()));
        let app = Arc::new(Self {
            events: EventHub::new(config.event_buffer_size),
            modes: RwLock::new(Arc::new(catalog)),
            config,
            db,
            devices,
            management,
            hints: Hints::new(),
            nodes: Arc::new(NodeRegistry::default()),
            activity: Mutex::new(HashMap::new()),
            backends,
            inference: pirc_providers::Inference::new(),
            slots: Default::default(),
        });
        let weak = Arc::downgrade(&app);
        app.backends.set_on_change(move || {
            if let Some(app) = weak.upgrade() {
                app.inference.cancel_all();
                app.nodes.broadcast(
                    &serde_json::json!({ "type": "models", "models": app.public_models() }),
                );
            }
        });
        Ok(app)
    }

    #[cfg(test)]
    pub fn new(
        config: GatewayConfig,
        db: Arc<Db>,
        backends: Arc<BackendService>,
        catalog: pirc_config::modes::ModeCatalog,
    ) -> Arc<Self> {
        Self::try_new(config, db, backends, catalog).expect("persist initial mode policies")
    }

    /// Keep lock order consistent with readers that hold the DB while consulting
    /// modes. Publish to Nodes only after both durable and in-memory state agree.
    pub(crate) fn replace_catalog(
        &self,
        catalog: pirc_config::modes::ModeCatalog,
    ) -> ApiResult<()> {
        let db = self.db.lock();
        let mut modes = self.modes.write().unwrap_or_else(|p| p.into_inner());
        crate::conversation_bindings::policies::install_catalog(&db, &catalog)?;
        *modes = Arc::new(catalog);
        Ok(())
    }

    pub fn catalog(&self) -> Arc<pirc_config::modes::ModeCatalog> {
        self.modes.read().unwrap_or_else(|p| p.into_inner()).clone()
    }

    pub fn mode(&self, id: &pirc_protocol::mode::ModeId) -> Option<pirc_protocol::Mode> {
        self.catalog().modes.get(id).cloned()
    }

    pub fn require_mode(&self, workspace: &crate::db::Workspace) -> ApiResult<pirc_protocol::Mode> {
        self.mode(&workspace.mode).ok_or_else(|| {
            ApiError::new(
                409,
                "mode_unavailable",
                format!(
                    "Workspace mode {} is unavailable; existing sessions are read-only",
                    workspace.mode
                ),
            )
        })
    }

    pub fn require_writable(&self, session: &Session) -> ApiResult<()> {
        let workspace = self.db.lock().get_workspace(&session.workspace_id)?;
        self.require_mode(&workspace).map(|_| ())
    }

    pub fn public_modes(&self) -> Vec<pirc_protocol::Mode> {
        self.catalog().modes.values().cloned().collect()
    }

    pub fn reload_modes(&self) {
        match pirc_config::modes::load_modes(&self.config.modes_dir) {
            Ok(catalog) => {
                for warning in &catalog.warnings {
                    crate::log::warn(&warning.to_string());
                }
                if let Err(error) = self.replace_catalog(catalog) {
                    crate::log::error(&format!(
                        "mode policy persistence failed; keeping previous catalog: {error}"
                    ));
                    return;
                }
                self.nodes
                    .broadcast(&serde_json::json!({"type":"modes", "modes":self.public_modes()}));
                self.directory_changed();
            }
            Err(error) => crate::log::error(&format!(
                "modes reload failed; keeping previous catalog: {error}"
            )),
        }
    }

    /// Authenticate a request's parts (`validateRequest`).
    pub fn validate(
        &self,
        peer: &SocketAddr,
        headers: &HeaderMap,
        uri: &Uri,
        method: &Method,
        require_origin: bool,
    ) -> ApiResult<Identity> {
        let peer = auth::peer_address(peer.ip());
        auth::validate_request(
            &RequestInfo {
                peer: &peer,
                headers,
                path: uri.path(),
                method,
            },
            &self.config.auth,
            self.devices.as_ref(),
            require_origin,
            self.management.as_ref(),
        )
    }

    /// The session, if the user owns it, together with its node.
    pub fn claim(&self, identity: &Identity, session_id: &str) -> ApiResult<Claimed> {
        let session = self
            .db
            .lock()
            .claim_session(session_id, &identity.user, false)?;
        match (session.node_id.clone(), session.pi_session_id.clone()) {
            (Some(node_id), Some(pi_session_id)) => Ok(Claimed {
                session,
                node_id,
                pi_session_id,
            }),
            _ => Err(ApiError::not_found("Session not found")),
        }
    }

    /// Every configured provider, keys included (gateway-side only).
    pub fn models(&self) -> Arc<Models> {
        self.backends.merged()
    }

    /// The secret-free catalog nodes receive.
    pub fn public_models(&self) -> Value {
        serde_json::to_value(pirc_providers::public_models(&self.models())).unwrap_or_default()
    }

    /// Re-read `PIRC_MODELS_FILE` (SIGHUP): in-flight inference ends, nodes
    /// get the new catalog (the change hook). A bad file keeps the previous
    /// providers.
    pub fn reload_models(&self) {
        let env = pirc_config::Env::from_process();
        match pirc_providers::load_models_file(
            &self.config.models_file,
            &|name| env.get(name).map(str::to_owned),
            &env.home(),
        ) {
            Ok(models) => self
                .backends
                .set_baseline(models.unwrap_or_else(empty_models)),
            // The same message a bad file stops the gateway with at startup.
            Err(error) => crate::log::error(&format!(
                "models reload failed; keeping the previous providers: {error}"
            )),
        }
    }

    /// Replay a request on the node as `identity`.
    pub async fn relay(
        &self,
        node_id: &str,
        identity: &Identity,
        method: HttpMethod,
        url: String,
        payload: Option<Value>,
    ) -> ApiResult<NodeHttpResponse> {
        self.nodes
            .request(
                node_id,
                NodeHttpRequest {
                    method,
                    url,
                    user: identity.user.clone(),
                    payload,
                    body_base64: None,
                    content_type: None,
                },
            )
            .await
    }
}

#[cfg(test)]
pub fn test_modes() -> pirc_config::modes::ModeCatalog {
    let mut catalog = pirc_config::modes::ModeCatalog::default();
    for mode in [
        pirc_protocol::mode::default_chat(),
        pirc_protocol::mode::default_work(),
    ] {
        catalog.modes.insert(mode.id.clone(), mode);
    }
    catalog
}

pub fn empty_models() -> Models {
    Models {
        providers: Default::default(),
        default_model: None,
        inference: None,
    }
}

/// The request body, read with the configured limit.
pub struct ReqBody(pub Body);

impl FromRequest<AppState> for ReqBody {
    type Rejection = ApiError;

    async fn from_request(request: Request, app: &AppState) -> ApiResult<Self> {
        http::read_body(request, app.config.upload_max_bytes)
            .await
            .map(Self)
    }
}

/// The query string as Fastify parsed it: every value of every name.
pub fn query_map(uri: &Uri) -> HashMap<String, Vec<String>> {
    let mut query: HashMap<String, Vec<String>> = HashMap::new();
    for (name, value) in form_urlencoded::parse(uri.query().unwrap_or_default().as_bytes()) {
        query
            .entry(name.into_owned())
            .or_default()
            .push(value.into_owned());
    }
    query
}

/// A node's answer passed through to the browser: its status and body.
pub fn forward(response: NodeHttpResponse) -> Response {
    match (response.status, response.body) {
        (204, _) | (_, None) => {
            let mut reply = axum::body::Body::empty().into_response();
            *reply.status_mut() = axum::http::StatusCode::from_u16(response.status)
                .unwrap_or(axum::http::StatusCode::BAD_GATEWAY);
            reply
        }
        (status, Some(Value::String(text))) => {
            let mut reply = text.into_response();
            *reply.status_mut() = axum::http::StatusCode::from_u16(status)
                .unwrap_or(axum::http::StatusCode::BAD_GATEWAY);
            reply.headers_mut().insert(
                header::CONTENT_TYPE,
                axum::http::HeaderValue::from_static("text/plain; charset=utf-8"),
            );
            reply
        }
        (status, Some(body)) => json_response(status, &body),
    }
}

pub fn router(app: AppState) -> Router {
    Router::new()
        .merge(crate::conversation_submissions::router())
        .merge(crate::conversation_bindings::transitions::router())
        .route("/node/connect", get(sockets::node_connect))
        .route("/api/events", get(sockets::events))
        .route(
            "/api/sessions/{id}/terminals/{terminal_id}/stream",
            get(sockets::terminal_stream),
        )
        .route(
            "/api/sessions/{id}/browser/stream",
            get(sockets::browser_stream),
        )
        .route("/api/health", get(routes::health))
        .route("/api/nodes", get(routes::list_nodes))
        .route("/api/assistant/node", get(routes::assistant_node))
        .route(
            "/api/assistant/node/release",
            post(routes::release_assistant_node),
        )
        .route("/api/assistant/prompts", get(routes::assistant_prompts))
        .route(
            "/api/assistant/prompts/{name}",
            axum::routing::put(routes::save_assistant_prompt),
        )
        .route(
            "/api/workspaces",
            get(routes::list_workspaces).post(routes::create_workspace),
        )
        .route("/api/modes", get(routes::list_modes))
        .route(
            "/api/workspaces/{workspace_id}",
            delete(crate::workspace_removal::delete),
        )
        .route(
            "/api/workspaces/{workspace_id}/capabilities",
            get(routes::get_capabilities).patch(routes::patch_capabilities),
        )
        .route(
            "/api/workspaces/{workspace_id}/links",
            get(routes::get_links).put(routes::put_links),
        )
        .route(
            "/api/workspaces/{workspace_id}/instructions",
            get(routes::get_instructions).patch(routes::patch_instructions),
        )
        .route(
            "/api/workspaces/{workspace_id}/files",
            get(routes::get_project_files)
                .post(routes::upload_project_file)
                .delete(routes::delete_project_file),
        )
        .route(
            "/api/workspaces/{workspace_id}/project-config",
            get(routes::project_config),
        )
        .route(
            "/api/workspaces/{workspace_id}/project-trust",
            post(routes::project_trust),
        )
        .route(
            "/api/sessions",
            get(routes::list_sessions).post(routes::create_session),
        )
        .route(
            "/api/sessions/{id}",
            delete(routes::delete_session).patch(routes::update_session),
        )
        .route("/api/sessions/{id}/read", post(routes::read_session))
        .route("/api/sessions/{id}/snapshot", get(routes::snapshot))
        .route(
            "/api/sessions/{id}/environment",
            get(crate::conversation_bindings::policies::get_environment),
        )
        .route("/api/sessions/{id}/commands", post(routes::command))
        .route(
            "/api/sessions/{id}/commands/{command_id}",
            get(routes::command_receipt),
        )
        .route("/api/sessions/{id}/control", get(routes::control))
        .route("/api/sessions/{id}/control/acquire", post(routes::acquire))
        .route(
            "/api/sessions/{id}/control/heartbeat",
            post(routes::heartbeat),
        )
        .route("/api/sessions/{id}/control/release", post(routes::release))
        .route(
            "/api/sessions/{id}/interactions/{interaction_id}/answer",
            post(routes::answer),
        )
        .route("/api/sessions/{id}/uploads", post(routes::upload))
        .route(
            "/api/sessions/{id}/uploads/{upload_id}/reference",
            get(crate::upload_references::get),
        )
        .route("/api/models", get(routes::list_models))
        .route("/api/sessions/{id}/git/{*rest}", get(routes::relay_get))
        .route("/api/sessions/{id}/files", get(routes::relay_get))
        .route("/api/sessions/{id}/files/content", get(routes::relay_get))
        .route("/api/sessions/{id}/panel/{*rest}", get(routes::relay_get))
        .route(
            "/api/sessions/{id}/terminals",
            get(routes::relay_get).post(routes::relay_post),
        )
        .route(
            "/api/sessions/{id}/terminals/{terminal_id}/close",
            post(routes::relay_post),
        )
        .route(
            "/api/sessions/{id}/panel/background/{task_id}/stop",
            post(routes::relay_post),
        )
        .route(
            "/api/sessions/{id}/browser/recording",
            get(routes::recording),
        )
        .merge(crate::checkpoints::routes())
        .merge(routes::feature_routes())
        .merge(crate::management::routes())
        .merge(crate::project_deletion::routes())
        .merge(crate::backends::routes())
        .fallback(not_found)
        .method_not_allowed_fallback(not_found)
        .layer(middleware::from_fn_with_state(app.clone(), authenticate))
        .layer(middleware::from_fn(crate::management::response_headers))
        .layer(middleware::from_fn(crate::features::no_store))
        // Outside `no_store`: Fastify's router refused before any scope's hooks.
        .layer(middleware::from_fn(param_length))
        .layer(middleware::from_fn(detach))
        .with_state(app)
}

/// Routes with path parameters, by method (`{name}` segments; a `{*rest}`
/// tail is not limited).
const PARAM_ROUTES: &[(&str, &str)] = &[
    ("GET", "/api/sessions/{id}/terminals/{terminal_id}/stream"),
    ("GET", "/api/sessions/{id}/browser/stream"),
    ("PUT", "/api/assistant/prompts/{name}"),
    ("DELETE", "/api/workspaces/{workspace_id}"),
    ("GET", "/api/workspaces/{workspace_id}/capabilities"),
    ("PATCH", "/api/workspaces/{workspace_id}/capabilities"),
    ("GET", "/api/workspaces/{workspace_id}/links"),
    ("PUT", "/api/workspaces/{workspace_id}/links"),
    ("GET", "/api/workspaces/{workspace_id}/instructions"),
    ("PATCH", "/api/workspaces/{workspace_id}/instructions"),
    ("GET", "/api/workspaces/{workspace_id}/files"),
    ("POST", "/api/workspaces/{workspace_id}/files"),
    ("DELETE", "/api/workspaces/{workspace_id}/files"),
    ("GET", "/api/workspaces/{workspace_id}/project-config"),
    ("POST", "/api/workspaces/{workspace_id}/project-trust"),
    ("GET", "/api/workspaces/{workspace_id}/deletion"),
    ("POST", "/api/workspaces/{workspace_id}/deletion"),
    ("DELETE", "/api/sessions/{id}"),
    ("PATCH", "/api/sessions/{id}"),
    ("POST", "/api/sessions/{id}/read"),
    ("GET", "/api/sessions/{id}/snapshot"),
    ("GET", "/api/sessions/{id}/environment"),
    (
        "POST",
        "/api/sessions/{id}/environment-transitions/previews",
    ),
    (
        "GET",
        "/api/sessions/{id}/environment-transitions/previews/{operation}",
    ),
    ("GET", "/api/sessions/{id}/checkpoints"),
    ("POST", "/api/sessions/{id}/checkpoints/{capture}/preview"),
    (
        "POST",
        "/api/sessions/{id}/checkpoints/{capture}/recoveries",
    ),
    (
        "GET",
        "/api/sessions/{id}/checkpoints/{capture}/recoveries/{job}",
    ),
    (
        "POST",
        "/api/sessions/{id}/checkpoints/{capture}/recoveries/{job}/continue",
    ),
    ("GET", "/api/sessions/{id}/checkpoints/{capture}/file"),
    ("POST", "/api/sessions/{id}/commands"),
    ("GET", "/api/sessions/{id}/commands/{command_id}"),
    ("GET", "/api/sessions/{id}/control"),
    ("POST", "/api/sessions/{id}/control/acquire"),
    ("POST", "/api/sessions/{id}/control/heartbeat"),
    ("POST", "/api/sessions/{id}/control/release"),
    (
        "POST",
        "/api/sessions/{id}/interactions/{interaction_id}/answer",
    ),
    ("POST", "/api/sessions/{id}/uploads"),
    ("GET", "/api/sessions/{id}/uploads/{upload_id}/reference"),
    ("GET", "/api/sessions/{id}/git/{*rest}"),
    ("GET", "/api/sessions/{id}/files"),
    ("GET", "/api/sessions/{id}/files/content"),
    ("GET", "/api/sessions/{id}/panel/{*rest}"),
    ("GET", "/api/sessions/{id}/terminals"),
    ("POST", "/api/sessions/{id}/terminals"),
    ("POST", "/api/sessions/{id}/terminals/{terminal_id}/close"),
    ("POST", "/api/sessions/{id}/panel/background/{task_id}/stop"),
    ("GET", "/api/sessions/{id}/browser/recording"),
    ("GET", "/api/native-management/requests/{id}"),
    ("DELETE", "/api/native-management/requests/{id}"),
    ("POST", "/api/native-management/requests/{id}/approve"),
    ("POST", "/api/native-management/requests/{id}/deny"),
    ("POST", "/api/native-management/requests/{id}/claim"),
    ("DELETE", "/api/devices/{id}"),
    ("POST", "/api/delegations/{id}/stop"),
    ("PUT", "/api/providers/{id}"),
    ("DELETE", "/api/providers/{id}"),
    ("GET", "/api/provider-auth/sessions/{id}"),
    ("DELETE", "/api/provider-auth/sessions/{id}"),
    ("POST", "/api/provider-auth/sessions/{id}/input"),
    ("GET", "/api/schedules/{id}"),
    ("GET", "/api/calendar/events/{id}"),
    ("PATCH", "/api/calendar/events/{id}"),
    ("DELETE", "/api/calendar/events/{id}"),
    ("PATCH", "/api/schedules/{id}"),
    ("DELETE", "/api/schedules/{id}"),
    ("POST", "/api/schedules/{id}/run"),
    ("POST", "/api/schedules/{id}/runs/{run_id}/dismiss"),
    ("GET", "/api/memory/entries/{id}/history"),
    ("POST", "/api/memory/proposals/{id}/approve"),
    ("POST", "/api/memory/proposals/{id}/reject"),
    ("POST", "/api/memory/entries/{id}/forget"),
    ("POST", "/api/memory/entries/{id}/restore"),
];

/// Fastify's router refuses a path parameter over 100 characters with
/// 414, before any hook runs.
fn param_too_long(method: &str, path: &str) -> bool {
    let method = if method == "HEAD" { "GET" } else { method };
    let segments: Vec<&str> = path.split('/').collect();
    PARAM_ROUTES.iter().any(|(route_method, route)| {
        if *route_method != method {
            return false;
        }
        let pattern: Vec<&str> = route.split('/').collect();
        let tail = pattern.last().is_some_and(|last| last.starts_with("{*"));
        let fits = if tail {
            segments.len() >= pattern.len()
        } else {
            segments.len() == pattern.len()
        };
        let mut long = false;
        fits && pattern.iter().zip(&segments).all(|(part, segment)| {
            if part.starts_with("{*") {
                true
            } else if part.starts_with('{') {
                long |= segment.len() > 100;
                !segment.is_empty()
            } else {
                part == segment
            }
        }) && long
    })
}

async fn param_length(request: Request, next: Next) -> Response {
    let path = request.uri().path().to_owned();
    if param_too_long(request.method().as_str(), &path) {
        return json_response(
            414,
            &serde_json::json!({
                "error": "Bad Request",
                "code": "FST_ERR_MAX_PARAM_LENGTH",
                "message": format!("'{path}' is exceeding the max param length"),
                "statusCode": 414,
            }),
        );
    }
    next.run(request).await
}

/// Fastify ran a handler to its end even when the client went away (a
/// relayed command still records its outcome). Handlers run in their own
/// task, so a dropped connection does not cancel them halfway.
async fn detach(request: Request, next: Next) -> Response {
    match tokio::spawn(next.run(request)).await {
        Ok(response) => response,
        Err(_) => ApiError::internal().into_response(),
    }
}

/// The `Upgrade` header as the TS gateway saw it (duplicates joined).
fn is_websocket_upgrade(headers: &HeaderMap) -> bool {
    auth::header(headers, header::UPGRADE.as_str())
        .is_some_and(|value| value.eq_ignore_ascii_case("websocket"))
}

/// Every route but the node link authenticates its caller before anything
/// else, unknown routes included (Fastify's `onRequest` hook).
async fn authenticate(
    State(app): State<AppState>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    mut request: Request,
    next: Next,
) -> Response {
    if request.uri().path() == "/node/connect" && is_websocket_upgrade(request.headers()) {
        return next.run(request).await;
    }
    let require_origin = auth::requires_origin(request.method());
    match app.validate(
        &peer,
        request.headers(),
        request.uri(),
        request.method(),
        require_origin,
    ) {
        Ok(identity) => {
            // Optional for legacy clients. Durable operations always send this
            // fence so changed browser cookies cannot retarget old local content.
            let expected = request.headers().get_all("x-pirc-account");
            if expected.iter().count() > 1 {
                return ApiError::invalid_input().into_response();
            }
            if let Some(expected) = expected.iter().next()
                && expected.to_str().ok()
                    != Some(crate::routes::urlencoding_component(&identity.user).as_str())
            {
                return ApiError::new(
                    409,
                    "account_changed",
                    "The signed-in account changed. Reopen this operation in its original account.",
                )
                .into_response();
            }
            request.extensions_mut().insert(identity);
            next.run(request).await
        }
        Err(error) => error.into_response(),
    }
}

/// Fastify parsed the body before it found no route: a bad one fails first.
async fn not_found(State(app): State<AppState>, request: Request) -> Response {
    let method = request.method().clone();
    let uri = request.uri().clone();
    if let Err(error) = http::read_body(request, app.config.upload_max_bytes).await {
        return error.into_response();
    }
    let target = uri
        .path_and_query()
        .map_or_else(|| uri.path().to_owned(), ToString::to_string);
    http::route_not_found(&method, &target)
}

#[cfg(test)]
mod tests {
    #[test]
    fn long_parameters() {
        let long = "x".repeat(101);
        assert!(super::param_too_long(
            "GET",
            &format!("/api/sessions/{long}/snapshot")
        ));
        assert!(!super::param_too_long(
            "GET",
            &format!("/api/sessions/{}/snapshot", "x".repeat(100))
        ));
        assert!(!super::param_too_long(
            "POST",
            &format!("/api/sessions/{long}/snapshot")
        ));
        assert!(super::param_too_long(
            "GET",
            &format!("/api/sessions/{long}/git/a/b")
        ));
        assert!(!super::param_too_long(
            "GET",
            &format!("/api/sessions/s/git/{long}")
        ));
    }
}
