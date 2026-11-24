//! Browser-approved, short-lived native management grants. Request
//! challenges and grant tokens are intentionally held in memory only, so a
//! gateway restart invalidates every pending request and grant.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard};

use axum::Router;
use axum::extract::{Extension, Path, State};
use axum::http::{HeaderValue, header};
use axum::middleware::Next;
use axum::response::Response;
use axum::routing::{get, post};
use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use subtle::ConstantTimeEq;

use crate::app::{AppState, ReqBody};
use crate::auth::Identity;
use crate::devices::DeviceTokens;
use crate::error::{ApiError, ApiResult, json_response};
use crate::http::ok;
use crate::util::{now_ms, random_bytes, sha256_hex};

pub const MANAGEMENT_REQUEST_TTL_MS: i64 = 5 * 60_000;
pub const MANAGEMENT_GRANT_TTL_MS: i64 = 15 * 60_000;
const MAX_RECORDS: usize = 1000;
const MAX_REQUESTS_PER_DEVICE_WINDOW: usize = 5;
const REQUEST_RATE_WINDOW_MS: i64 = 5 * 60_000;
const TERMINAL_RETENTION_MS: i64 = 10 * 60_000;
const REQUEST_ID_LENGTH: usize = 32;
const VERIFIER_LENGTH: usize = 43;
const GRANT_TOKEN_PREFIX: &str = "pirc_mgmt_";

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum ManagementCapability {
    #[serde(rename = "providers")]
    Providers,
    /// List paired devices.
    #[serde(rename = "devices:read")]
    DevicesRead,
    /// Revoke a paired device.
    #[serde(rename = "devices:revoke")]
    DevicesRevoke,
    /// Pair a new long-lived device; the approval screen says so and shows the
    /// lifetime in [`ManagementRequestView::pairing`].
    #[serde(rename = "devices:pair")]
    DevicesPair,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum ManagementRequestStatus {
    Pending,
    Approved,
    Denied,
    Claimed,
    Revoked,
    Expired,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ManagementRequestView {
    pub id: String,
    pub status: ManagementRequestStatus,
    pub expires_at: i64,
    pub server_now: i64,
    pub device_name: String,
    pub capabilities: Vec<ManagementCapability>,
    /// Lifetime of a device this grant could pair; present with `devices:pair`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pairing: Option<PairingTerms>,
}

/// What approving `devices:pair` allows: each new device lives this long.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PairingTerms {
    pub idle_days: i64,
    pub max_days: i64,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ManagementRequestCreated {
    #[serde(flatten)]
    pub request: ManagementRequestView,
    pub verification_path: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ManagementGrant {
    pub token: String,
    pub expires_at: i64,
    pub server_now: i64,
    pub capabilities: Vec<ManagementCapability>,
}

/// An authorizer for requests that normally reject device bearer tokens.
pub trait ManagementGrantAuthorizer: Send + Sync {
    fn authorize(
        &self,
        user: &str,
        device_id: &str,
        token: &str,
        method: &str,
        pathname: &str,
    ) -> bool;
}

#[derive(Clone)]
struct ManagementRequest {
    id: String,
    owner: String,
    device_id: String,
    device_name: String,
    challenge: String,
    capabilities: Vec<ManagementCapability>,
    status: ManagementRequestStatus,
    created_at: i64,
    request_expires_at: i64,
    grant_expires_at: Option<i64>,
    grant_token_hash: Option<String>,
    cleanup_at: i64,
}

impl ManagementRequest {
    fn view(&self, stamp: i64, terms: PairingTerms) -> ManagementRequestView {
        ManagementRequestView {
            id: self.id.clone(),
            status: self.status,
            expires_at: self.grant_expires_at.unwrap_or(self.request_expires_at),
            server_now: stamp,
            device_name: self.device_name.clone(),
            capabilities: self.capabilities.clone(),
            pairing: self
                .capabilities
                .contains(&ManagementCapability::DevicesPair)
                .then_some(terms),
        }
    }

    fn is_active(&self, stamp: i64) -> bool {
        matches!(
            self.status,
            ManagementRequestStatus::Pending | ManagementRequestStatus::Approved
        ) || (self.status == ManagementRequestStatus::Claimed
            && self
                .grant_expires_at
                .is_some_and(|expires_at| expires_at > stamp))
    }
}

#[derive(Default)]
struct GrantState {
    requests: HashMap<String, ManagementRequest>,
    /// SHA-256 token hash → request ID. Raw grant credentials are never kept.
    grant_index: HashMap<String, String>,
}

/// In-memory by design. Records are bounded, only one active request/grant
/// can exist per device, and short-lived terminal records support status UI.
pub struct NativeManagementGrants {
    devices: Arc<DeviceTokens>,
    clock: Arc<dyn Fn() -> i64 + Send + Sync>,
    state: Mutex<GrantState>,
}

impl NativeManagementGrants {
    pub fn new(devices: Arc<DeviceTokens>) -> Self {
        Self::with_clock(devices, Arc::new(now_ms))
    }

    fn with_clock(devices: Arc<DeviceTokens>, clock: Arc<dyn Fn() -> i64 + Send + Sync>) -> Self {
        Self {
            devices,
            clock,
            state: Mutex::new(GrantState::default()),
        }
    }

    fn lock(&self) -> MutexGuard<'_, GrantState> {
        self.state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    fn stamp(&self) -> i64 {
        (self.clock)()
    }

    fn remove_grant(state: &mut GrantState, request_id: &str) {
        let token_hash = state
            .requests
            .get_mut(request_id)
            .and_then(|request| request.grant_token_hash.take());
        if let Some(token_hash) = token_hash {
            state.grant_index.remove(&token_hash);
        }
    }

    fn finish(
        state: &mut GrantState,
        request_id: &str,
        status: ManagementRequestStatus,
        stamp: i64,
    ) {
        let token_hash = {
            let Some(request) = state.requests.get_mut(request_id) else {
                return;
            };
            let keep_expiry = (request.status == ManagementRequestStatus::Claimed)
                .then_some(request.grant_expires_at)
                .flatten();
            let token_hash = request.grant_token_hash.take();
            request.challenge.clear();
            request.status = status;
            request.grant_expires_at = keep_expiry;
            request.cleanup_at = stamp.saturating_add(TERMINAL_RETENTION_MS);
            token_hash
        };
        if let Some(token_hash) = token_hash {
            state.grant_index.remove(&token_hash);
        }
    }

    fn refresh(
        &self,
        state: &mut GrantState,
        request_id: &str,
        stamp: i64,
        check_device: bool,
    ) -> ApiResult<()> {
        let Some(request) = state.requests.get(request_id) else {
            return Ok(());
        };
        let expiration = match request.status {
            ManagementRequestStatus::Pending | ManagementRequestStatus::Approved
                if stamp >= request.request_expires_at =>
            {
                Some(ManagementRequestStatus::Expired)
            }
            ManagementRequestStatus::Claimed
                if request
                    .grant_expires_at
                    .is_some_and(|expires_at| stamp >= expires_at) =>
            {
                Some(ManagementRequestStatus::Expired)
            }
            _ => None,
        };
        if let Some(status) = expiration {
            Self::finish(state, request_id, status, stamp);
            return Ok(());
        }
        let device = if check_device && request.is_active(stamp) {
            Some((request.owner.clone(), request.device_id.clone()))
        } else {
            None
        };
        if let Some((owner, device_id)) = device
            && self.devices.get(&owner, &device_id)?.is_none()
        {
            Self::finish(state, request_id, ManagementRequestStatus::Revoked, stamp);
        }
        Ok(())
    }

    fn sweep_locked(&self, state: &mut GrantState, stamp: i64) -> ApiResult<()> {
        let ids: Vec<String> = state.requests.keys().cloned().collect();
        for id in ids {
            self.refresh(state, &id, stamp, false)?;
        }
        let terminal: Vec<String> = state
            .requests
            .iter()
            .filter(|(_, request)| request.cleanup_at <= stamp)
            .map(|(id, _)| id.clone())
            .collect();
        for id in terminal {
            Self::remove_grant(state, &id);
            state.requests.remove(&id);
        }
        Ok(())
    }

    fn checked_id(id: &str) -> ApiResult<()> {
        if id.len() == REQUEST_ID_LENGTH && base64url_text(id) {
            Ok(())
        } else {
            Err(ApiError::invalid_input())
        }
    }

    fn owned_request(
        &self,
        state: &mut GrantState,
        owner: &str,
        device_id: Option<&str>,
        id: &str,
        stamp: i64,
    ) -> ApiResult<ManagementRequest> {
        Self::checked_id(id)?;
        self.sweep_locked(state, stamp)?;
        let request = state.requests.get(id).ok_or_else(request_not_found)?;
        if request.owner != owner
            || device_id.is_some_and(|device_id| request.device_id != device_id)
        {
            return Err(request_not_found());
        }
        self.refresh(state, id, stamp, device_id.is_none())?;
        state
            .requests
            .get(id)
            .cloned()
            .ok_or_else(request_not_found)
    }

    pub fn create(
        &self,
        owner: &str,
        device_id: &str,
        challenge: &str,
        capabilities: Vec<ManagementCapability>,
        replace: bool,
    ) -> ApiResult<ManagementRequestCreated> {
        if !valid_hex_sha256(challenge)
            || capabilities.is_empty()
            || capabilities.len() > 2
            || capabilities.iter().any(|capability| {
                capabilities
                    .iter()
                    .filter(|other| *other == capability)
                    .count()
                    > 1
            })
        {
            return Err(ApiError::invalid_input());
        }
        let device = self.devices.get(owner, device_id)?.ok_or_else(|| {
            ApiError::new(401, "unauthenticated", "Device authentication is required")
        })?;
        let stamp = self.stamp();
        let mut state = self.lock();
        self.sweep_locked(&mut state, stamp)?;

        let active: Vec<String> = state
            .requests
            .iter()
            .filter(|(_, request)| {
                request.owner == owner && request.device_id == device_id && request.is_active(stamp)
            })
            .map(|(id, _)| id.clone())
            .collect();
        if !active.is_empty() && !replace {
            return Err(ApiError::new(
                409,
                "conflict",
                "This device already has an active management request",
            ));
        }
        let recent = state
            .requests
            .values()
            .filter(|request| {
                request.owner == owner
                    && request.device_id == device_id
                    && stamp.saturating_sub(request.created_at) < REQUEST_RATE_WINDOW_MS
            })
            .count();
        if recent >= MAX_REQUESTS_PER_DEVICE_WINDOW {
            return Err(ApiError::new(
                429,
                "too_many_requests",
                "Too many management requests for this device",
            ));
        }
        if state.requests.len() >= MAX_RECORDS {
            return Err(ApiError::new(
                429,
                "too_many_requests",
                "Management authorization is temporarily busy",
            ));
        }
        for id in active {
            Self::finish(&mut state, &id, ManagementRequestStatus::Revoked, stamp);
        }

        let id = URL_SAFE_NO_PAD.encode(random_bytes::<24>());
        let request_expires_at = stamp.saturating_add(MANAGEMENT_REQUEST_TTL_MS);
        let request = ManagementRequest {
            id: id.clone(),
            owner: owner.to_owned(),
            device_id: device_id.to_owned(),
            device_name: device.name,
            challenge: challenge.to_owned(),
            capabilities: capabilities.clone(),
            status: ManagementRequestStatus::Pending,
            created_at: stamp,
            request_expires_at,
            grant_expires_at: None,
            grant_token_hash: None,
            cleanup_at: request_expires_at.saturating_add(TERMINAL_RETENTION_MS),
        };
        let view = request.view(stamp, self.devices.pairing_terms());
        state.requests.insert(id.clone(), request);
        Ok(ManagementRequestCreated {
            request: view,
            verification_path: format!("/?nativeManagement={id}"),
        })
    }

    pub fn view(
        &self,
        owner: &str,
        device_id: Option<&str>,
        id: &str,
    ) -> ApiResult<ManagementRequestView> {
        let stamp = self.stamp();
        let mut state = self.lock();
        let request = self.owned_request(&mut state, owner, device_id, id, stamp)?;
        Ok(request.view(stamp, self.devices.pairing_terms()))
    }

    pub fn decide(
        &self,
        owner: &str,
        device_id: Option<&str>,
        id: &str,
        approved: bool,
    ) -> ApiResult<ManagementRequestView> {
        if device_id.is_some() {
            return Err(ApiError::new(
                403,
                "forbidden",
                "A browser identity is required",
            ));
        }
        let stamp = self.stamp();
        let mut state = self.lock();
        let request = self.owned_request(&mut state, owner, None, id, stamp)?;
        if request.status != ManagementRequestStatus::Pending {
            return Err(ApiError::new(
                409,
                "conflict",
                "Management request is no longer pending",
            ));
        }
        let request = state.requests.get_mut(id).ok_or_else(request_not_found)?;
        request.status = if approved {
            ManagementRequestStatus::Approved
        } else {
            request.challenge.clear();
            request.cleanup_at = stamp.saturating_add(TERMINAL_RETENTION_MS);
            ManagementRequestStatus::Denied
        };
        Ok(request.view(stamp, self.devices.pairing_terms()))
    }

    pub fn claim(
        &self,
        owner: &str,
        device_id: &str,
        id: &str,
        verifier: &str,
    ) -> ApiResult<ManagementGrant> {
        let stamp = self.stamp();
        let mut state = self.lock();
        let request = self.owned_request(&mut state, owner, Some(device_id), id, stamp)?;
        if request.status != ManagementRequestStatus::Approved || !valid_verifier(verifier) {
            return Err(ApiError::new(
                409,
                "conflict",
                "Management request is not claimable",
            ));
        }
        let supplied_challenge = sha256_hex(verifier);
        if !bool::from(
            supplied_challenge
                .as_bytes()
                .ct_eq(request.challenge.as_bytes()),
        ) {
            return Err(ApiError::new(
                403,
                "forbidden",
                "Management verifier is invalid",
            ));
        }

        // The state mutex makes claim consumption atomic, including concurrent
        // redemptions from duplicate HTTP requests.
        let token = format!(
            "{GRANT_TOKEN_PREFIX}{}",
            URL_SAFE_NO_PAD.encode(crate::util::random_bytes::<32>())
        );
        let token_hash = sha256_hex(&token);
        let server_now = self.stamp();
        let expires_at = server_now.saturating_add(MANAGEMENT_GRANT_TTL_MS);
        let (capabilities, request_id) = {
            let request = state.requests.get_mut(id).ok_or_else(request_not_found)?;
            request.status = ManagementRequestStatus::Claimed;
            request.challenge.clear();
            request.grant_token_hash = Some(token_hash.clone());
            request.grant_expires_at = Some(expires_at);
            request.cleanup_at = expires_at.saturating_add(TERMINAL_RETENTION_MS);
            (request.capabilities.clone(), request.id.clone())
        };
        state.grant_index.insert(token_hash, request_id);
        Ok(ManagementGrant {
            token,
            expires_at,
            server_now,
            capabilities,
        })
    }

    pub fn cancel(
        &self,
        owner: &str,
        device_id: Option<&str>,
        id: &str,
    ) -> ApiResult<ManagementRequestView> {
        let stamp = self.stamp();
        let mut state = self.lock();
        let request = self.owned_request(&mut state, owner, device_id, id, stamp)?;
        if matches!(
            request.status,
            ManagementRequestStatus::Pending
                | ManagementRequestStatus::Approved
                | ManagementRequestStatus::Claimed
        ) {
            Self::finish(&mut state, id, ManagementRequestStatus::Revoked, stamp);
        }
        let request = state.requests.get(id).ok_or_else(request_not_found)?;
        Ok(request.view(stamp, self.devices.pairing_terms()))
    }
}

impl ManagementGrantAuthorizer for NativeManagementGrants {
    fn authorize(
        &self,
        user: &str,
        device_id: &str,
        token: &str,
        method: &str,
        pathname: &str,
    ) -> bool {
        if !valid_grant_token(token) {
            return false;
        }
        let Some(capability) = capability_for_route(method, pathname) else {
            return false;
        };
        let stamp = self.stamp();
        let mut state = self.lock();
        if self.sweep_locked(&mut state, stamp).is_err() {
            return false;
        }
        let token_hash = sha256_hex(token);
        let Some(request_id) = state.grant_index.get(&token_hash).cloned() else {
            return false;
        };
        if self.refresh(&mut state, &request_id, stamp, true).is_err() {
            return false;
        }
        let Some(request) = state.requests.get(&request_id) else {
            return false;
        };
        request.status == ManagementRequestStatus::Claimed
            && request.owner == user
            && request.device_id == device_id
            && request
                .grant_token_hash
                .as_ref()
                .is_some_and(|stored| bool::from(token_hash.as_bytes().ct_eq(stored.as_bytes())))
            && request.capabilities.contains(&capability)
    }
}

fn request_not_found() -> ApiError {
    ApiError::not_found("Management request not found")
}

fn base64url_text(value: &str) -> bool {
    value
        .bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-')
}

fn valid_hex_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn valid_verifier(value: &str) -> bool {
    value.len() == VERIFIER_LENGTH && base64url_text(value)
}

fn valid_grant_token(value: &str) -> bool {
    value
        .strip_prefix(GRANT_TOKEN_PREFIX)
        .is_some_and(|suffix| suffix.len() == 43 && base64url_text(suffix))
}

/// The exact route/method set that a browser-approved grant can access.
fn capability_for_route(method: &str, pathname: &str) -> Option<ManagementCapability> {
    let method = method.to_ascii_uppercase();
    if (method == "GET" && matches!(pathname, "/api/providers" | "/api/providers/presets"))
        || (method == "POST"
            && matches!(
                pathname,
                "/api/providers" | "/api/providers/discover" | "/api/providers/test"
            ))
        || (method == "PUT" && pathname == "/api/providers/default-model")
        || ((method == "PUT" || method == "DELETE")
            && one_segment_after(pathname, "/api/providers/"))
        || (method == "POST" && pathname == "/api/provider-auth/sessions")
        || ((method == "GET" || method == "DELETE")
            && one_segment_after(pathname, "/api/provider-auth/sessions/"))
        || (method == "POST" && one_segment_before_input(pathname))
    {
        return Some(ManagementCapability::Providers);
    }
    match method.as_str() {
        "GET" if pathname == "/api/devices" => Some(ManagementCapability::DevicesRead),
        "POST" if pathname == "/api/devices" => Some(ManagementCapability::DevicesPair),
        "DELETE" if one_segment_after(pathname, "/api/devices/") => {
            Some(ManagementCapability::DevicesRevoke)
        }
        _ => None,
    }
}

fn one_segment_after(pathname: &str, prefix: &str) -> bool {
    pathname
        .strip_prefix(prefix)
        .is_some_and(|segment| !segment.is_empty() && !segment.contains('/'))
}

fn one_segment_before_input(pathname: &str) -> bool {
    pathname
        .strip_prefix("/api/provider-auth/sessions/")
        .and_then(|rest| rest.strip_suffix("/input"))
        .is_some_and(|segment| !segment.is_empty() && !segment.contains('/'))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct CreateBody {
    challenge: String,
    capabilities: Vec<ManagementCapability>,
    #[serde(default)]
    replace: bool,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ClaimBody {
    verifier: String,
}

fn body_value<T: Serialize>(value: &T) -> Value {
    serde_json::to_value(value).unwrap_or(Value::Null)
}

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/api/native-management/requests", post(create))
        .route(
            "/api/native-management/requests/{id}",
            get(view).delete(cancel),
        )
        .route(
            "/api/native-management/requests/{id}/approve",
            post(approve),
        )
        .route("/api/native-management/requests/{id}/deny", post(deny))
        .route("/api/native-management/requests/{id}/claim", post(claim))
}

async fn create(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    ReqBody(body): ReqBody,
) -> ApiResult<Response> {
    let device_id = identity
        .device_id
        .as_deref()
        .ok_or_else(|| ApiError::new(403, "forbidden", "A paired device is required"))?;
    let body: CreateBody = body.parse()?;
    let created = app.management.create(
        &identity.user,
        device_id,
        &body.challenge,
        body.capabilities,
        body.replace,
    )?;
    Ok(json_response(201, &body_value(&created)))
}

async fn view(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(id): Path<String>,
) -> ApiResult<Response> {
    let request = app
        .management
        .view(&identity.user, identity.device_id.as_deref(), &id)?;
    Ok(ok(body_value(&request)))
}

async fn approve(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(id): Path<String>,
) -> ApiResult<Response> {
    let request =
        app.management
            .decide(&identity.user, identity.device_id.as_deref(), &id, true)?;
    Ok(ok(body_value(&request)))
}

async fn deny(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(id): Path<String>,
) -> ApiResult<Response> {
    let request =
        app.management
            .decide(&identity.user, identity.device_id.as_deref(), &id, false)?;
    Ok(ok(body_value(&request)))
}

async fn claim(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(id): Path<String>,
    ReqBody(body): ReqBody,
) -> ApiResult<Response> {
    let device_id = identity
        .device_id
        .as_deref()
        .ok_or_else(|| ApiError::new(403, "forbidden", "A paired device is required"))?;
    let body: ClaimBody = body.parse()?;
    if !valid_verifier(&body.verifier) {
        return Err(ApiError::invalid_input());
    }
    let grant = app
        .management
        .claim(&identity.user, device_id, &id, &body.verifier)?;
    Ok(ok(body_value(&grant)))
}

async fn cancel(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(id): Path<String>,
) -> ApiResult<Response> {
    let request = app
        .management
        .cancel(&identity.user, identity.device_id.as_deref(), &id)?;
    Ok(ok(body_value(&request)))
}

/// Fastify set these headers for every response in this route scope.
pub async fn response_headers(request: axum::extract::Request, next: Next) -> Response {
    let path = request.uri().path();
    let management_route = path == "/api/native-management/requests"
        || path.starts_with("/api/native-management/requests/");
    let mut response = next.run(request).await;
    if management_route {
        response
            .headers_mut()
            .insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
        response.headers_mut().insert(
            header::REFERRER_POLICY,
            HeaderValue::from_static("no-referrer"),
        );
    }
    response
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicI64, Ordering};

    use super::*;
    use crate::db::Db;

    fn verifier() -> String {
        URL_SAFE_NO_PAD.encode(crate::util::random_bytes::<32>())
    }

    fn digest(value: &str) -> String {
        sha256_hex(value)
    }

    fn setup() -> (
        Arc<DeviceTokens>,
        Arc<NativeManagementGrants>,
        Arc<AtomicI64>,
    ) {
        let db = Arc::new(Db::memory());
        let devices = DeviceTokens::new(db, 7 * 86_400_000, 30 * 86_400_000);
        let clock = Arc::new(AtomicI64::new(1_000_000));
        let clock_for_grants = clock.clone();
        let management = Arc::new(NativeManagementGrants::with_clock(
            devices.clone(),
            Arc::new(move || clock_for_grants.load(Ordering::SeqCst)),
        ));
        (devices, management, clock)
    }

    fn request(
        management: &NativeManagementGrants,
        owner: &str,
        device_id: &str,
        secret: &str,
        capabilities: Vec<ManagementCapability>,
    ) -> ManagementRequestCreated {
        management
            .create(owner, device_id, &digest(secret), capabilities, false)
            .unwrap()
    }

    fn grant(
        management: &NativeManagementGrants,
        owner: &str,
        device_id: &str,
        id: &str,
        secret: &str,
    ) -> ManagementGrant {
        management.decide(owner, None, id, true).unwrap();
        management.claim(owner, device_id, id, secret).unwrap()
    }

    #[test]
    fn browser_approval_original_device_claim_and_single_use() {
        let (devices, management, _) = setup();
        let (phone, _) = devices.create("owner", "Pixel").unwrap();
        let (other, _) = devices.create("owner", "Tablet").unwrap();
        let secret = verifier();
        let created = request(
            &management,
            "owner",
            &phone.id,
            &secret,
            vec![ManagementCapability::Providers],
        );
        assert_eq!(created.request.status, ManagementRequestStatus::Pending);
        assert_eq!(created.request.device_name, "Pixel");
        assert_eq!(
            created.verification_path,
            format!("/?nativeManagement={}", created.request.id)
        );
        assert_eq!(
            created.request.expires_at - created.request.server_now,
            MANAGEMENT_REQUEST_TTL_MS
        );
        assert!(
            management
                .view("other-owner", None, &created.request.id)
                .is_err()
        );
        assert!(
            management
                .view("owner", Some(&other.id), &created.request.id)
                .is_err()
        );
        assert_eq!(
            management
                .decide("owner", Some(&phone.id), &created.request.id, true)
                .unwrap_err()
                .status,
            403
        );
        assert!(
            management
                .claim("owner", &other.id, &created.request.id, &secret)
                .is_err()
        );
        assert_eq!(
            management
                .claim("owner", &phone.id, &created.request.id, &secret)
                .unwrap_err()
                .status,
            409
        );
        management
            .decide("owner", None, &created.request.id, true)
            .unwrap();
        assert_eq!(
            management
                .claim("owner", &phone.id, &created.request.id, &verifier())
                .unwrap_err()
                .status,
            403
        );
        let redeemed = management
            .claim("owner", &phone.id, &created.request.id, &secret)
            .unwrap();
        assert!(valid_grant_token(&redeemed.token));
        assert_eq!(
            redeemed.expires_at - redeemed.server_now,
            MANAGEMENT_GRANT_TTL_MS
        );
        assert_eq!(redeemed.capabilities, vec![ManagementCapability::Providers]);
        assert!(
            management
                .claim("owner", &phone.id, &created.request.id, &secret)
                .is_err()
        );
        assert_eq!(
            management
                .view("owner", None, &created.request.id)
                .unwrap()
                .status,
            ManagementRequestStatus::Claimed
        );
    }

    #[test]
    fn grants_are_device_owner_capability_method_and_path_scoped() {
        let (devices, management, _) = setup();
        let (phone, _) = devices.create("owner", "Pixel").unwrap();
        let (other_phone, _) = devices.create("owner", "Tablet").unwrap();
        let secret = verifier();
        let created = request(
            &management,
            "owner",
            &phone.id,
            &secret,
            vec![ManagementCapability::Providers],
        );
        let redeemed = grant(
            &management,
            "owner",
            &phone.id,
            &created.request.id,
            &secret,
        );
        let authorize = |user, device_id, method, path| {
            management.authorize(user, device_id, &redeemed.token, method, path)
        };
        assert!(authorize("owner", &phone.id, "GET", "/api/providers"));
        assert!(authorize(
            "owner",
            &phone.id,
            "POST",
            "/api/provider-auth/sessions"
        ));
        assert!(!authorize("other", &phone.id, "GET", "/api/providers"));
        assert!(!authorize(
            "owner",
            &other_phone.id,
            "GET",
            "/api/providers"
        ));
        assert!(!authorize("owner", &phone.id, "GET", "/api/devices"));
        assert!(!authorize("owner", &phone.id, "PATCH", "/api/providers/x"));
        assert!(!authorize(
            "owner",
            &phone.id,
            "GET",
            "/api/providers/x/extra"
        ));
        assert!(!authorize(
            "owner",
            &phone.id,
            "GET",
            "/api/provider-auth/sessions/x/input"
        ));
        assert!(!management.authorize("owner", &phone.id, "wrong-token", "GET", "/api/providers"));
        let restarted = NativeManagementGrants::new(devices.clone());
        assert!(!restarted.authorize("owner", &phone.id, &redeemed.token, "GET", "/api/providers"));
    }

    #[test]
    fn replacement_rate_limit_revocation_and_expiry() {
        let (devices, management, clock) = setup();
        let (phone, _) = devices.create("owner", "Pixel").unwrap();
        let secret = verifier();
        let first = request(
            &management,
            "owner",
            &phone.id,
            &secret,
            vec![ManagementCapability::DevicesRead],
        );
        let first_grant = grant(&management, "owner", &phone.id, &first.request.id, &secret);
        assert!(management.authorize(
            "owner",
            &phone.id,
            &first_grant.token,
            "GET",
            "/api/devices"
        ));

        let replacement_secret = verifier();
        let replacement = management
            .create(
                "owner",
                &phone.id,
                &digest(&replacement_secret),
                vec![ManagementCapability::Providers],
                true,
            )
            .unwrap();
        assert_eq!(
            management
                .view("owner", None, &first.request.id)
                .unwrap()
                .status,
            ManagementRequestStatus::Revoked
        );
        assert!(!management.authorize(
            "owner",
            &phone.id,
            &first_grant.token,
            "GET",
            "/api/devices"
        ));
        management
            .decide("owner", None, &replacement.request.id, true)
            .unwrap();
        let second_grant = management
            .claim(
                "owner",
                &phone.id,
                &replacement.request.id,
                &replacement_secret,
            )
            .unwrap();
        clock.fetch_add(MANAGEMENT_GRANT_TTL_MS, Ordering::SeqCst);
        assert!(!management.authorize(
            "owner",
            &phone.id,
            &second_grant.token,
            "GET",
            "/api/providers"
        ));
        assert_eq!(
            management
                .view("owner", None, &replacement.request.id)
                .unwrap()
                .status,
            ManagementRequestStatus::Expired
        );

        // Terminal outcomes count against the per-device request rate.
        for _ in 0..5 {
            let next = request(
                &management,
                "owner",
                &phone.id,
                &verifier(),
                vec![ManagementCapability::Providers],
            );
            management
                .decide("owner", None, &next.request.id, false)
                .unwrap();
        }
        assert_eq!(
            management
                .create(
                    "owner",
                    &phone.id,
                    &digest(&verifier()),
                    vec![ManagementCapability::Providers],
                    false,
                )
                .unwrap_err()
                .status,
            429
        );
    }

    #[test]
    fn pending_request_expires_at_its_deadline() {
        let (devices, management, clock) = setup();
        let (phone, _) = devices.create("owner", "Pixel").unwrap();
        let secret = verifier();
        let created = request(
            &management,
            "owner",
            &phone.id,
            &secret,
            vec![ManagementCapability::DevicesRead],
        );
        clock.fetch_add(MANAGEMENT_REQUEST_TTL_MS, Ordering::SeqCst);
        let expired = management.view("owner", None, &created.request.id).unwrap();
        assert_eq!(expired.status, ManagementRequestStatus::Expired);
        assert_eq!(expired.expires_at, created.request.expires_at);
    }

    #[test]
    fn device_capabilities_are_separate_and_pairing_shows_its_lifetime() {
        assert_eq!(
            capability_for_route("GET", "/api/devices"),
            Some(ManagementCapability::DevicesRead)
        );
        assert_eq!(
            capability_for_route("POST", "/api/devices"),
            Some(ManagementCapability::DevicesPair)
        );
        assert_eq!(
            serde_json::to_value([
                ManagementCapability::DevicesRead,
                ManagementCapability::DevicesRevoke,
                ManagementCapability::DevicesPair,
            ])
            .unwrap(),
            serde_json::json!(["devices:read", "devices:revoke", "devices:pair"])
        );
        assert!(
            serde_json::from_value::<ManagementCapability>(serde_json::json!("devices")).is_err()
        );

        let (devices, management, _) = setup();
        let (phone, _) = devices.create("owner", "Pixel").unwrap();
        let secret = verifier();
        let read_only = request(
            &management,
            "owner",
            &phone.id,
            &secret,
            vec![ManagementCapability::DevicesRead],
        );
        assert_eq!(read_only.request.pairing, None);
        let token = grant(
            &management,
            "owner",
            &phone.id,
            &read_only.request.id,
            &secret,
        )
        .token;
        assert!(management.authorize("owner", &phone.id, &token, "GET", "/api/devices"));
        assert!(!management.authorize("owner", &phone.id, &token, "POST", "/api/devices"));
        assert!(!management.authorize("owner", &phone.id, &token, "DELETE", "/api/devices/x"));

        let secret = verifier();
        let pairing = management
            .create(
                "owner",
                &phone.id,
                &digest(&secret),
                vec![ManagementCapability::DevicesPair],
                true,
            )
            .unwrap();
        assert_eq!(
            pairing.request.pairing,
            Some(PairingTerms {
                idle_days: 7,
                max_days: 30
            })
        );
    }

    #[test]
    fn device_revocation_revokes_request_and_grant() {
        let (devices, management, _) = setup();
        let (phone, _) = devices.create("owner", "Pixel").unwrap();
        let secret = verifier();
        let created = request(
            &management,
            "owner",
            &phone.id,
            &secret,
            vec![ManagementCapability::Providers],
        );
        let redeemed = grant(
            &management,
            "owner",
            &phone.id,
            &created.request.id,
            &secret,
        );
        devices.revoke("owner", &phone.id).unwrap();
        assert!(!management.authorize(
            "owner",
            &phone.id,
            &redeemed.token,
            "GET",
            "/api/providers"
        ));
        assert_eq!(
            management
                .view("owner", None, &created.request.id)
                .unwrap()
                .status,
            ManagementRequestStatus::Revoked
        );
    }

    #[test]
    fn capability_matcher_is_an_exact_method_and_route_allowlist() {
        assert_eq!(
            capability_for_route("GET", "/api/providers"),
            Some(ManagementCapability::Providers)
        );
        assert_eq!(
            capability_for_route("POST", "/api/providers/test"),
            Some(ManagementCapability::Providers)
        );
        assert_eq!(
            capability_for_route("DELETE", "/api/providers/test"),
            Some(ManagementCapability::Providers)
        );
        assert_eq!(
            capability_for_route("POST", "/api/provider-auth/sessions/abc/input"),
            Some(ManagementCapability::Providers)
        );
        assert_eq!(
            capability_for_route("DELETE", "/api/devices/device_1"),
            Some(ManagementCapability::DevicesRevoke)
        );
        for (method, path) in [
            ("HEAD", "/api/providers"),
            ("GET", "/api/providers/"),
            ("POST", "/api/devices/x"),
            ("GET", "/api/devices/x"),
            ("GET", "/api/providers/x/child"),
            ("POST", "/api/provider-auth/sessions/x/input/extra"),
        ] {
            assert_eq!(capability_for_route(method, path), None, "{method} {path}");
        }
    }
}
