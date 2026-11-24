//! Helpers for HTTP-level tests: an app whose backends serve given models, and
//! one request through the whole router with a browser or device identity.

use std::sync::Arc;

use serde_json::Value;

use crate::app::{App, AppState};
use crate::db::Db;

/// An app on an in-memory database whose file-managed providers are `models`
/// (the `providers` object of a models file).
pub fn app_with_models(providers: Value) -> (AppState, tempfile::TempDir) {
    let dir = tempfile::tempdir().unwrap();
    let state = dir.path().join("state");
    let env = pirc_config::Env::new(
        [
            (
                "PIRC_NODE_TOKENS",
                r#"{"node":"0123456789abcdef0123456789abcdef"}"#,
            ),
            ("PIRC_TRUSTED_PROXIES", "127.0.0.1"),
            ("PIRC_PROXY_SECRET_REQUIRED", "false"),
            ("PIRC_ALLOWED_ORIGINS", "https://a.example"),
            ("PIRC_ALLOWED_HOSTS", "a.example"),
            ("PIRC_ALLOWED_USERS", "alice,bob"),
            ("PIRC_STATE_DIR", state.to_str().unwrap()),
            ("PIRC_CONFIG_DIR", dir.path().to_str().unwrap()),
            ("PIRC_TIMEZONE", "UTC"),
            ("HOME", "/home/test"),
        ],
        "/work",
    );
    let models = serde_json::from_value(serde_json::json!({ "providers": providers })).unwrap();
    let backends = pirc_providers::backends::BackendService::open(&state, models).unwrap();
    let app = App::new(
        pirc_config::GatewayConfig::load(&env).unwrap(),
        Arc::new(Db::memory()),
        backends,
        crate::app::test_modes(),
    );
    (app, dir)
}

/// One request as `user` from the browser (or with a device `token`).
pub async fn call(
    app: &AppState,
    method: &str,
    path: &str,
    user: Option<&str>,
    token: Option<&str>,
    body: Option<Value>,
) -> (u16, Value) {
    use tower::ServiceExt;
    let mut req = axum::http::Request::builder()
        .method(method)
        .uri(path)
        .header("host", "a.example")
        .header(crate::capabilities::HEADER, "test/2")
        .header(
            crate::request_shape::REQUEST_HEADER,
            crate::request_shape::REQUEST_VALUE,
        )
        .extension(axum::extract::ConnectInfo(
            "127.0.0.1:40000".parse::<std::net::SocketAddr>().unwrap(),
        ));
    if token.is_none() {
        req = req.header("origin", "https://a.example");
    }
    if let Some(user) = user {
        req = req.header("x-pirc-user", user);
    }
    if let Some(token) = token {
        req = req.header("authorization", format!("Bearer {token}"));
    }
    let bytes = match body {
        Some(body) => {
            req = req.header("content-type", "application/json");
            body.to_string()
        }
        None => String::new(),
    };
    let response = crate::app::router(app.clone())
        .oneshot(req.body(axum::body::Body::from(bytes)).unwrap())
        .await
        .unwrap();
    let code = response.status().as_u16();
    let bytes = axum::body::to_bytes(response.into_body(), 4 * 1024 * 1024)
        .await
        .unwrap();
    (code, serde_json::from_slice(&bytes).unwrap_or(Value::Null))
}
