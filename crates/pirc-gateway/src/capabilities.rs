//! Client API versioning and the one capability document clients read.
//!
//! Every client names its API version in `X-Pirc-Client: <app>/<version>`
//! (WebSocket upgrades, which browsers cannot give custom headers, use the
//! `client` query parameter instead). A client this Gateway does not speak to
//! gets `426 client_upgrade_required`, before any handler runs. Feature support
//! is read from `GET /api/capabilities`, never inferred from a version string.
use axum::extract::{Extension, State};
use axum::http::{HeaderMap, Uri};
use serde_json::{Value, json};

use crate::app::AppState;
use crate::auth::Identity;
use crate::error::ApiError;

/// The client API this Gateway serves. Raise it when a change needs every
/// client to update; old clients are then refused, not emulated.
pub const API_VERSION: u32 = 2;
pub const HEADER: &str = "x-pirc-client";
const QUERY: &str = "client";

/// Paths a client of any version may call: liveness and this document.
fn exempt(path: &str) -> bool {
    matches!(path, "/api/health" | "/api/capabilities") || !path.starts_with("/api/")
}

fn parse(value: &str) -> Option<u32> {
    let (app, version) = value.split_once('/')?;
    let app_ok = !app.is_empty()
        && app.len() <= 40
        && app
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.'));
    let version_ok = !version.is_empty()
        && version.len() <= 6
        && !version.starts_with('0')
        && version.bytes().all(|b| b.is_ascii_digit());
    if app_ok && version_ok {
        version.parse().ok()
    } else {
        None
    }
}

fn from_query(uri: &Uri) -> Option<String> {
    uri.query()?.split('&').find_map(|pair| {
        let (key, value) = pair.split_once('=')?;
        (key == QUERY).then(|| value.replace("%2F", "/").replace("%2f", "/"))
    })
}

/// The declared client version: exactly one header, or (WebSocket upgrades
/// only) the query parameter.
fn declared(headers: &HeaderMap, uri: &Uri, websocket: bool) -> Option<u32> {
    let mut values = headers.get_all(HEADER).iter();
    match (values.next(), values.next()) {
        (Some(value), None) => parse(value.to_str().ok()?),
        (None, None) if websocket => parse(&from_query(uri)?),
        _ => None,
    }
}

pub fn require(headers: &HeaderMap, uri: &Uri, websocket: bool) -> Result<(), ApiError> {
    if exempt(uri.path()) || declared(headers, uri, websocket) == Some(API_VERSION) {
        return Ok(());
    }
    Err(ApiError::new(
        426,
        "client_upgrade_required",
        "This version of the app or web page is out of date. Update or reload it to continue.",
    ))
}

pub fn document(app: &AppState, identity: &Identity) -> Value {
    json!({
        "apiVersion": API_VERSION,
        "server": { "version": env!("CARGO_PKG_VERSION") },
        "account": { "user": identity.user },
        "features": {
            "firstSend": {
                "supported": true,
                "enabled": true,
                "version": 2,
                "attachmentRetentionDays": crate::conversation_submissions::ATTACHMENT_RETENTION_DAYS,
            },
            "environmentSwitching": {
                "supported": true,
                "enabled": app.config.environment_switching,
                "version": 1,
            },
        },
    })
}

pub async fn get(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
) -> axum::Json<Value> {
    axum::Json(document(&app, &identity))
}

#[cfg(test)]
mod tests;
