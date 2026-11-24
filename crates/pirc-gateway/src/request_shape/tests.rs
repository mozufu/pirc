//! Tests of the request-shape rule, and the harness the feature modules use to
//! prove that a request of the wrong shape changes nothing.

use super::*;
use crate::app::{App, AppState};
use crate::db::Db;
use axum::http::Request as HttpRequest;
use pirc_config::{Env, GatewayConfig};
use pirc_providers::backends::BackendService;
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;
use tower::ServiceExt;

pub(crate) const USER: &str = "u@example.com";

pub(crate) fn fixture() -> (AppState, tempfile::TempDir) {
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
            ("HOME", "/home/test"),
        ],
        "/work",
    );
    let models = serde_json::from_value(json!({ "providers": {} })).unwrap();
    let app = App::new(
        GatewayConfig::load(&env).unwrap(),
        Arc::new(Db::memory()),
        BackendService::open(&state, models).unwrap(),
        crate::app::test_modes(),
    );
    (app, dir)
}

/// Who sends a request: the proxy's forward-auth identity or a paired device.
#[derive(Clone)]
pub(crate) enum Who {
    Browser(String),
    Device(String),
}

impl Who {
    pub(crate) fn label(&self) -> &'static str {
        match self {
            Self::Browser(_) => "browser",
            Self::Device(_) => "device",
        }
    }
}

/// A browser identity and a device identity of `user`.
pub(crate) fn identities(app: &App, user: &str) -> Vec<Who> {
    let (_, token) = app.devices.create(user, "Test device").unwrap();
    vec![Who::Browser(user.to_owned()), Who::Device(token)]
}

/// The headers and body of one request, as a client or a form would send it.
#[derive(Clone)]
pub(crate) struct Probe {
    pub(crate) name: &'static str,
    pub(crate) headers: Vec<(&'static str, String)>,
    pub(crate) body: Vec<u8>,
}

pub(crate) fn probe(
    name: &'static str,
    headers: &[(&'static str, &str)],
    body: impl Into<Vec<u8>>,
) -> Probe {
    Probe {
        name,
        headers: headers
            .iter()
            .map(|(name, value)| (*name, (*value).to_owned()))
            .collect(),
        body: body.into(),
    }
}

const MULTIPART: &str = "multipart/form-data; boundary=----pirc";
const MULTIPART_BODY: &str =
    "------pirc\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nb\r\n------pirc--\r\n";

/// Every shape that carries neither the request header nor strict JSON: what
/// an HTML form sends, and forged or malformed JSON declarations.
pub(crate) fn forged() -> Vec<Probe> {
    let ct = "content-type";
    vec![
        probe("no body, no content type", &[], ""),
        probe("raw bytes, no content type", &[], "payload"),
        probe(
            "urlencoded with fields",
            &[(ct, "application/x-www-form-urlencoded")],
            "a=b&targetRevision=1",
        ),
        probe(
            "urlencoded empty",
            &[(ct, "application/x-www-form-urlencoded")],
            "",
        ),
        probe("multipart", &[(ct, MULTIPART)], MULTIPART_BODY),
        probe("text/plain with fields", &[(ct, "text/plain")], "a=b"),
        probe(
            "text/plain that looks like JSON",
            &[(ct, "text/plain")],
            "{\"a\":1}",
        ),
        probe("text/plain empty", &[(ct, "text/plain")], ""),
        probe(
            "octet-stream upload without the header",
            &[(ct, "application/octet-stream")],
            "payload",
        ),
        probe("forged json, empty body", &[(ct, "application/json")], ""),
        probe(
            "forged json, form body",
            &[(ct, "application/json")],
            "a=b&c=d",
        ),
        probe(
            "forged json, truncated",
            &[(ct, "application/json")],
            "{\"a\":",
        ),
        probe("json; empty body", &[(ct, "application/json;")], ""),
        probe("json; form body", &[(ct, "application/json;")], "a=b"),
        probe(
            "odd casing, form body",
            &[(ct, "Application/JSON; charset=utf-8")],
            "a=b",
        ),
        probe(
            "odd casing, empty body",
            &[(ct, "APPLICATION/JSON ; charset=utf-8")],
            "",
        ),
        probe(
            "duplicate content types, form body",
            &[(ct, "text/plain"), (ct, "application/json")],
            "a=b",
        ),
        probe(
            "duplicate content types, valid JSON",
            &[(ct, "text/plain"), (ct, "application/json")],
            "{}",
        ),
        probe(
            "duplicate json content types, empty",
            &[(ct, "application/json"), (ct, "application/json")],
            "",
        ),
        probe(
            "near miss media type",
            &[(ct, "application/json-patch+json")],
            "{}",
        ),
        probe("other json media type", &[(ct, "text/json")], "{}"),
        probe(
            "request header with another value",
            &[("x-pirc-request", "0")],
            "",
        ),
        probe(
            "request header with an empty value",
            &[("x-pirc-request", "")],
            "",
        ),
        probe(
            "request header with a word",
            &[("x-pirc-request", "true")],
            "",
        ),
        probe(
            "request header sent twice",
            &[("x-pirc-request", "1"), ("x-pirc-request", "1")],
            "",
        ),
        probe(
            "request header in a list",
            &[("x-pirc-request", "1, 1")],
            "",
        ),
    ]
}

/// Shapes the rule accepts for a request with no meaningful body.
pub(crate) fn accepted_empty() -> Vec<Probe> {
    vec![
        probe("request header, no body", &[("x-pirc-request", "1")], ""),
        probe("strict JSON", &[("content-type", "application/json")], "{}"),
        probe(
            "strict JSON with a charset",
            &[("content-type", "Application/JSON; charset=utf-8")],
            "{}",
        ),
    ]
}

/// A request through the whole router, as a proxy would deliver it.
pub(crate) async fn send(
    app: &AppState,
    who: &Who,
    method: &str,
    path: &str,
    probe: &Probe,
) -> (u16, Value) {
    let mut request = HttpRequest::builder()
        .header(crate::capabilities::HEADER, "test/2")
        .method(method)
        .uri(path)
        .header("host", "a.example")
        .extension(axum::extract::ConnectInfo(
            "127.0.0.1:40000".parse::<std::net::SocketAddr>().unwrap(),
        ));
    request = match who {
        Who::Browser(user) => request
            .header("origin", "https://a.example")
            .header("x-pirc-user", user),
        Who::Device(token) => request.header("authorization", format!("Bearer {token}")),
    };
    for (name, value) in &probe.headers {
        request = request.header(*name, value);
    }
    let response = crate::app::router(app.clone())
        .oneshot(
            request
                .body(axum::body::Body::from(probe.body.clone()))
                .unwrap(),
        )
        .await
        .unwrap();
    let status = response.status().as_u16();
    let bytes = axum::body::to_bytes(response.into_body(), 4 * 1024 * 1024)
        .await
        .unwrap();
    (
        status,
        serde_json::from_slice(&bytes)
            .unwrap_or_else(|_| Value::String(String::from_utf8_lossy(&bytes).into_owned())),
    )
}

pub(crate) fn is_shape_rejection(status: u16, body: &Value) -> bool {
    status == 415
        && body["error"]["code"] == SHAPE_CODE
        && body["error"]["message"] == SHAPE_MESSAGE
}

/// What one state-changing operation must show: every forged shape is
/// refused and leaves `snapshot()` unchanged, and every accepted shape works
/// and changes it. `seed` makes a fresh target (its path) each time.
pub(crate) async fn prove_operation(
    app: &AppState,
    who: &[Who],
    method: &str,
    seed: &dyn Fn() -> String,
    snapshot: &dyn Fn() -> Value,
    accepted: &[Probe],
    success: &dyn Fn(u16, &Value) -> bool,
) {
    for who in who {
        let path = seed();
        let before = snapshot();
        for forged in forged() {
            let (status, body) = send(app, who, method, &path, &forged).await;
            assert!(
                is_shape_rejection(status, &body),
                "{} {method} {path} [{}]: {status} {body}",
                who.label(),
                forged.name
            );
            assert_eq!(
                snapshot(),
                before,
                "{} {method} {path} [{}] changed state",
                who.label(),
                forged.name
            );
        }
        for (index, accepted) in accepted.iter().enumerate() {
            let path = if index == 0 { path.clone() } else { seed() };
            let before = snapshot();
            let (status, body) = send(app, who, method, &path, accepted).await;
            assert!(
                success(status, &body),
                "{} {method} {path} [{}]: {status} {body}",
                who.label(),
                accepted.name
            );
            assert_ne!(
                snapshot(),
                before,
                "{} {method} {path} [{}] changed nothing",
                who.label(),
                accepted.name
            );
        }
    }
}

pub(crate) fn ok(status: u16, _: &Value) -> bool {
    (200..300).contains(&status)
}

// ---------------------------------------------------------------------------
// The rule itself

#[test]
fn only_state_changing_methods_need_a_shape() {
    use axum::http::Method;
    for method in [Method::GET, Method::HEAD, Method::OPTIONS] {
        assert!(!is_state_changing(&method));
    }
    for method in [Method::POST, Method::PUT, Method::PATCH, Method::DELETE] {
        assert!(is_state_changing(&method));
    }
}

async fn enforce_with(method: &str, probe: &Probe) -> Result<Vec<u8>, ApiError> {
    let mut request = HttpRequest::builder()
        .header(crate::capabilities::HEADER, "test/2")
        .method(method)
        .uri("/api/x");
    for (name, value) in &probe.headers {
        request = request.header(*name, value);
    }
    let request = request
        .body(axum::body::Body::from(probe.body.clone()))
        .unwrap();
    let request = enforce(request, 1024).await?;
    let bytes = axum::body::to_bytes(request.into_body(), 1024)
        .await
        .unwrap();
    Ok(bytes.to_vec())
}

#[tokio::test]
async fn forged_shapes_are_refused_and_accepted_shapes_keep_their_body() {
    for forged in forged() {
        let error = enforce_with("POST", &forged).await.unwrap_err();
        assert_eq!(
            (error.status, error.code),
            (415, SHAPE_CODE),
            "{}",
            forged.name
        );
        // A person reads this text: it says to reload or update, not what the protocol is.
        assert_eq!(error.message, SHAPE_MESSAGE, "{}", forged.name);
    }
    assert_eq!(
        SHAPE_MESSAGE,
        "This version of the app or page is out of date. Reload the page or update the app."
    );
    for method in ["POST", "PUT", "PATCH", "DELETE"] {
        let header = probe("header", &[("x-pirc-request", "1")], "raw bytes");
        assert_eq!(enforce_with(method, &header).await.unwrap(), b"raw bytes");
        let json = probe("json", &[("content-type", "application/json")], "{\"a\":1}");
        assert_eq!(enforce_with(method, &json).await.unwrap(), b"{\"a\":1}");
    }
    // The marker lets a body through untouched, whatever its type or content.
    let marked_json = probe(
        "marker with a broken JSON declaration",
        &[
            ("x-pirc-request", "1"),
            ("content-type", "application/json"),
        ],
        "not json",
    );
    assert_eq!(
        enforce_with("POST", &marked_json).await.unwrap(),
        b"not json"
    );
    // Reads need no shape.
    for method in ["GET", "HEAD", "OPTIONS"] {
        let form = probe("form", &[("content-type", "text/plain")], "a=b");
        assert!(enforce_with(method, &form).await.is_ok());
    }
}

#[tokio::test]
async fn json_declarations_are_checked_against_their_limit() {
    let big = format!("\"{}\"", "a".repeat(2000));
    let request = HttpRequest::builder()
        .header(crate::capabilities::HEADER, "test/2")
        .method("POST")
        .uri("/api/x")
        .header("content-type", "application/json")
        .body(axum::body::Body::from(big))
        .unwrap();
    assert_eq!(
        enforce(request, 1024).await.unwrap_err().code,
        "payload_too_large"
    );
}

#[tokio::test]
async fn identity_checks_run_before_the_shape_check() {
    let (app, _dir) = fixture();
    // No identity: still 401, not a hint about the shape.
    let request = HttpRequest::builder()
        .header(crate::capabilities::HEADER, "test/2")
        .method("POST")
        .uri("/api/push/test")
        .header("host", "a.example")
        .header("origin", "https://a.example")
        .header("content-type", "text/plain")
        .extension(axum::extract::ConnectInfo(
            "127.0.0.1:40000".parse::<std::net::SocketAddr>().unwrap(),
        ))
        .body(axum::body::Body::from("a=b"))
        .unwrap();
    let response = crate::app::router(app.clone())
        .oneshot(request)
        .await
        .unwrap();
    assert_eq!(response.status().as_u16(), 401);
    // A foreign origin is refused as before.
    let mut foreign = HttpRequest::builder()
        .header(crate::capabilities::HEADER, "test/2")
        .method("POST")
        .uri("/api/push/test")
        .header("host", "a.example")
        .header("origin", "https://evil.example")
        .header("x-pirc-user", USER)
        .header("content-type", "text/plain");
    foreign = foreign.extension(axum::extract::ConnectInfo(
        "127.0.0.1:40000".parse::<std::net::SocketAddr>().unwrap(),
    ));
    let response = crate::app::router(app.clone())
        .oneshot(foreign.body(axum::body::Body::from("a=b")).unwrap())
        .await
        .unwrap();
    assert_eq!(response.status().as_u16(), 403);
    // A device cannot reach device-management routes with the right shape either.
    let who = identities(&app, USER);
    let (status, body) = send(
        &app,
        &who[1],
        "POST",
        "/api/devices",
        &probe("marked", &[("x-pirc-request", "1")], ""),
    )
    .await;
    assert_eq!(
        (status, body["error"]["code"].as_str()),
        (403, Some("forbidden"))
    );
}

// ---------------------------------------------------------------------------
// Every registered non-GET route

/// The routes of the router, read from its debug description:
/// `(method, path template)`. axum offers no route listing, so this parses
/// the `Debug` output and the test below refuses an empty or inconsistent
/// result rather than passing without checking anything.
fn registered_routes(router: &axum::Router) -> BTreeSet<(String, String)> {
    let debug = format!("{router:?}");
    let mut methods: BTreeMap<u32, Vec<String>> = BTreeMap::new();
    let table = debug.split("node: Node").next().unwrap();
    for part in table.split("RouteId(").skip(1) {
        let (id, rest) = part.split_once("): ").unwrap();
        let Some(rest) = rest.strip_prefix("MethodRouter(MethodRouter {") else {
            continue;
        };
        let rest = rest.split("fallback:").next().unwrap();
        let found: Vec<String> = rest
            .split(',')
            .filter_map(|field| field.split_once(": "))
            .filter(|(_, value)| *value == "Route")
            .map(|(name, _)| name.trim().to_ascii_uppercase())
            .collect();
        methods.insert(id.parse().unwrap(), found);
    }
    let mut paths: BTreeMap<u32, String> = BTreeMap::new();
    let nodes = debug.split("node: Node").nth(1).unwrap();
    let nodes = nodes.split("route_id_to_path").next().unwrap_or(nodes);
    for part in nodes.split("RouteId(").skip(1) {
        let Some((id, rest)) = part.split_once("): \"") else {
            continue;
        };
        let Some((path, _)) = rest.split_once('"') else {
            continue;
        };
        if let Ok(id) = id.parse() {
            paths.entry(id).or_insert_with(|| path.to_owned());
        }
    }
    assert!(
        methods.len() > 80,
        "route table not parsed: {}",
        methods.len()
    );
    let mut routes = BTreeSet::new();
    for (id, found) in methods {
        let path = paths
            .get(&id)
            .unwrap_or_else(|| panic!("route {id} has no path"));
        for method in found {
            routes.insert((method, path.clone()));
        }
    }
    routes
}

/// A path template with its parameters filled.
fn concrete(template: &str) -> String {
    template
        .split('/')
        .map(|segment| {
            if segment.starts_with("{*") {
                "a/b".to_owned()
            } else if segment.starts_with('{') {
                "p1".to_owned()
            } else {
                segment.to_owned()
            }
        })
        .collect::<Vec<_>>()
        .join("/")
}

fn is_route_not_found(status: u16, body: &Value) -> bool {
    status == 404
        && body["error"] == "Not Found"
        && body["message"]
            .as_str()
            .is_some_and(|message| message.starts_with("Route ") && message.ends_with(" not found"))
}

#[tokio::test]
async fn every_registered_state_changing_route_requires_the_request_shape() {
    let (app, _dir) = fixture();
    let routes = registered_routes(&crate::app::router(app.clone()));
    let state_changing: Vec<_> = routes
        .iter()
        .filter(|(method, _)| matches!(method.as_str(), "POST" | "PUT" | "PATCH" | "DELETE"))
        .collect();
    assert!(
        state_changing.len() > 60,
        "only {} state-changing routes found",
        state_changing.len()
    );
    // Reads are enumerated too: none of them is held to the rule.
    assert!(routes.iter().any(|(method, _)| method == "GET"));
    let who = identities(&app, USER);
    let form = probe(
        "form",
        &[("content-type", "application/x-www-form-urlencoded")],
        "a=b",
    );
    let marked = probe("marked", &[("x-pirc-request", "1")], "");
    for (method, template) in &state_changing {
        let path = concrete(template);
        for who in &who {
            let (status, body) = send(&app, who, method, &path, &form).await;
            let device_only_route = matches!(who, Who::Device(_))
                && crate::auth::percent_decode(&path)
                    .split('/')
                    .nth(2)
                    .is_some_and(|scope| {
                        ["devices", "providers", "provider-auth"].contains(&scope)
                    });
            if device_only_route {
                assert_eq!(status, 403, "{} {method} {path}", who.label());
                continue;
            }
            assert!(
                is_shape_rejection(status, &body),
                "{} {method} {path}: {status} {body}",
                who.label()
            );
        }
        // With the header the route itself answers; the registered route is
        // found, so this also shows the enumeration names real routes.
        let (status, body) = send(&app, &who[0], method, &path, &marked).await;
        assert!(
            !is_shape_rejection(status, &body) && !is_route_not_found(status, &body),
            "{method} {path} with the header: {status} {body}"
        );
    }
}

#[tokio::test]
async fn unknown_state_changing_routes_are_refused_for_their_shape_first() {
    // A route added later is covered because the rule runs before routing.
    let (app, _dir) = fixture();
    let who = identities(&app, USER);
    for method in ["POST", "PUT", "PATCH", "DELETE"] {
        for who in &who {
            let form = probe("form", &[("content-type", "text/plain")], "a=b");
            let (status, body) = send(&app, who, method, "/api/not/yet/written", &form).await;
            assert!(
                is_shape_rejection(status, &body),
                "{method} {status} {body}"
            );
            let marked = probe("marked", &[("x-pirc-request", "1")], "");
            let (status, body) = send(&app, who, method, "/api/not/yet/written", &marked).await;
            assert!(
                is_route_not_found(status, &body),
                "{method} {status} {body}"
            );
        }
    }
}

#[tokio::test]
async fn reads_need_no_shape() {
    // A form-shaped read is never refused for its shape.
    let (app, _dir) = fixture();
    let routes = registered_routes(&crate::app::router(app.clone()));
    let who = identities(&app, USER);
    let form = probe("form", &[("content-type", "text/plain")], "");
    for (method, template) in routes.iter().filter(|(method, _)| method == "GET") {
        if matches!(template.as_str(), "/api/events" | "/node/connect")
            || template.ends_with("/stream")
        {
            continue;
        }
        let (status, body) = send(&app, &who[0], method, &concrete(template), &form).await;
        assert!(!is_shape_rejection(status, &body), "GET {template}");
    }
}
