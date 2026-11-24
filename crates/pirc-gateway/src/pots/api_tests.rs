use super::*;
use crate::{
    app::{App, AppState},
    db::{Db, Store},
};
use pirc_config::{Env, GatewayConfig};
use serde_json::{Value, json};
use std::sync::Arc;

pub(super) fn fixture() -> (AppState, tempfile::TempDir) {
    let dir = tempfile::tempdir().unwrap();
    let state = dir.path().join("state");
    let env = Env::new(
        [
            (
                "PIRC_NODE_TOKENS",
                r#"{"work":"0123456789abcdef0123456789abcdef"}"#,
            ),
            ("PIRC_TRUSTED_PROXIES", "127.0.0.1"),
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
    let app = App::new(
        GatewayConfig::load(&env).unwrap(),
        Arc::new(Db::memory()),
        pirc_providers::backends::BackendService::open(&state, crate::app::empty_models()).unwrap(),
        crate::app::test_modes(),
    );
    app.db
        .lock()
        .sync_remote_workspaces(
            "work",
            &[(
                "repo".into(),
                "Repo".into(),
                pirc_protocol::ModeId::new("directory").unwrap(),
            )],
        )
        .unwrap();
    (app, dir)
}
async fn call(
    router: &axum::Router,
    method: &str,
    path: &str,
    user: Option<&str>,
    token: Option<&str>,
    input: Option<Value>,
) -> axum::response::Response {
    use tower::ServiceExt;
    let mut request = axum::http::Request::builder()
        .header(crate::capabilities::HEADER, "test/2")
        .method(method)
        .uri(path)
        .header("host", "a.example")
        .header("origin", "https://a.example")
        .extension(axum::extract::ConnectInfo(
            "127.0.0.1:40000".parse::<std::net::SocketAddr>().unwrap(),
        ));
    if let Some(user) = user {
        request = request.header("x-pirc-user", user);
    }
    if let Some(token) = token {
        request = request.header("authorization", format!("Bearer {token}"));
    }
    let body = match input {
        Some(input) => {
            request = request.header("content-type", "application/json");
            axum::body::Body::from(input.to_string())
        }
        None => axum::body::Body::empty(),
    };
    router
        .clone()
        .oneshot(request.body(body).unwrap())
        .await
        .unwrap()
}
async fn body(response: axum::response::Response) -> Value {
    serde_json::from_slice(
        &axum::body::to_bytes(response.into_body(), 1024 * 1024)
            .await
            .unwrap(),
    )
    .unwrap()
}
fn spec() -> Value {
    json!({"idempotencyKey":"watch-1","purpose":"Watch input blockers","scopes":[{"workspaceId":"work:repo","access":"progress"}],"budgets":{"observations":2,"dispatches":0,"concurrency":1}})
}

#[tokio::test]
async fn http_owner_scoping_authentication_and_strict_intents() {
    let (app, _dir) = fixture();
    let router = crate::app::router(app.clone());
    let unauth = call(&router, "GET", "/api/pots", None, None, None).await;
    assert_eq!(unauth.status(), 401);
    assert_eq!(unauth.headers()["cache-control"], "no-store");
    let created = call(
        &router,
        "POST",
        "/api/pots/responsibilities",
        Some("alice"),
        None,
        Some(spec()),
    )
    .await;
    assert_eq!(created.status(), 201);
    assert_eq!(created.headers()["cache-control"], "no-store");
    let created = body(created).await;
    let id = created["responsibility"]["id"].as_str().unwrap();
    assert_eq!(created["responsibility"]["enabled"], false);
    let again = body(
        call(
            &router,
            "POST",
            "/api/pots/responsibilities",
            Some("alice"),
            None,
            Some(spec()),
        )
        .await,
    )
    .await;
    assert_eq!(again, created);
    let resource = format!("/api/pots/responsibilities/{id}");
    assert_eq!(
        call(&router, "GET", &resource, Some("bob"), None, None)
            .await
            .status(),
        404
    );
    let (_, token) = app.devices.create("alice", "phone").unwrap();
    let phone = call(&router, "GET", &resource, None, Some(&token), None).await;
    assert_eq!(phone.status(), 200);
    assert_eq!(body(phone).await, created);
    let mut forged = spec();
    forged["actor"] = json!("user");
    assert_eq!(
        call(
            &router,
            "POST",
            "/api/pots/responsibilities",
            Some("alice"),
            None,
            Some(forged)
        )
        .await
        .status(),
        400
    );
    assert_eq!(
        call(
            &router,
            "POST",
            "/api/pots/suggestions",
            Some("alice"),
            None,
            Some(json!({"actor":"pots","content":"run this"}))
        )
        .await
        .status(),
        404
    );
    let owner = body(call(&router, "GET", "/api/pots", Some("alice"), None, None).await).await;
    let other = body(call(&router, "GET", "/api/pots", Some("bob"), None, None).await).await;
    assert_ne!(owner["accountKey"], other["accountKey"]);
    assert_eq!(owner["executionAvailable"], true);
    assert_eq!(other["responsibilities"], json!([]));
    assert_eq!(
        call(
            &router,
            "GET",
            "/api/pots?limit=101",
            Some("alice"),
            None,
            None
        )
        .await
        .status(),
        400
    );
}

#[tokio::test]
async fn host_events_make_one_suggestion_and_tracking_never_dispatches() {
    let (app, _dir) = fixture();
    let session = app
        .db
        .lock()
        .create_session("work:repo", "node://work/worker", "work", "worker", "alice")
        .unwrap();
    let router = crate::app::router(app.clone());
    let created = body(
        call(
            &router,
            "POST",
            "/api/pots/responsibilities",
            Some("alice"),
            None,
            Some(spec()),
        )
        .await,
    )
    .await;
    let id = created["responsibility"]["id"].as_str().unwrap();
    let control = format!("/api/pots/responsibilities/{id}/control");
    let activate =
        json!({"expectedRevision":1,"expectedGeneration":1,"action":{"type":"activate"}});
    assert_eq!(
        call(
            &router,
            "POST",
            &control,
            Some("alice"),
            None,
            Some(activate)
        )
        .await
        .status(),
        200
    );
    // Authenticated host mapping is required: a different node/remote is ignored.
    let event = json!({"type":"interaction_created","data":{"id":"input-1","status":"pending","expiresAt":i64::MAX,"request":{"message":"private raw dialog"}}});
    app.on_node_event("wrong", "worker", event.as_object().unwrap().clone());
    let expired = json!({"type":"interaction_created","data":{"id":"expired","status":"pending","expiresAt":1}});
    app.on_node_event("work", "worker", expired.as_object().unwrap().clone());
    let forged = json!({"type":"pi_event","data":{"type":"interaction_created","id":"forged","status":"pending","expiresAt":i64::MAX}});
    app.on_node_event("work", "worker", forged.as_object().unwrap().clone());
    assert!(
        list_suggestions(&app.db.lock(), "alice", 100)
            .unwrap()
            .is_empty()
    );
    for _ in 0..2 {
        app.on_node_event("work", "worker", event.as_object().unwrap().clone());
    }
    let snapshot = body(call(&router, "GET", "/api/pots", Some("alice"), None, None).await).await;
    assert_eq!(snapshot["suggestions"].as_array().unwrap().len(), 1);
    assert!(!snapshot.to_string().contains("private raw dialog"));
    assert_eq!(snapshot["responsibilities"][0]["observationsUsed"], 1);
    let suggestion = &snapshot["suggestions"][0];
    let suggestion_id = suggestion["id"].as_str().unwrap();
    let path = format!("/api/pots/suggestions/{suggestion_id}/track");
    let first = body(
        call(
            &router,
            "POST",
            &path,
            Some("alice"),
            None,
            Some(json!({"expectedRevision":1,"commandId":"phone"})),
        )
        .await,
    )
    .await;
    let second = body(
        call(
            &router,
            "POST",
            &path,
            Some("alice"),
            None,
            Some(json!({"expectedRevision":1,"commandId":"web"})),
        )
        .await,
    )
    .await;
    assert_eq!(first, second);
    assert_eq!(first["task"]["executionSessionId"], Value::Null);
    let task_id = first["task"]["id"].as_str().unwrap();
    let start = format!("/api/pots/tasks/{task_id}/start");
    let refused = call(
        &router,
        "POST",
        &start,
        Some("alice"),
        None,
        Some(json!({"expectedRevision":1,"expectedGeneration":1,"commandId":"start-1"})),
    )
    .await;
    assert_eq!(refused.status(), 400);
    assert_eq!(body(refused).await["error"]["code"], "invalid_input");
    assert_eq!(app.db.lock().list_sessions().unwrap().len(), 1);
    let answer = json!({"type":"interaction_answered","data":{"interactionId":"input-1"}});
    app.on_node_event("work", "worker", answer.as_object().unwrap().clone());
    assert_eq!(
        get_suggestion(&app.db.lock(), "alice", suggestion_id)
            .unwrap()
            .disposition,
        Disposition::NeedsRefresh
    );
    assert_eq!(
        get_task(&app.db.lock(), "alice", task_id).unwrap().status,
        TaskStatus::Tracked
    );
    assert_eq!(
        get_task(&app.db.lock(), "alice", task_id)
            .unwrap()
            .target_session_id,
        session.id
    );
    // Same Node connection, different runner: lifecycle invalidation does not
    // wait for a reconnect/Gateway epoch change or complete a tracked task.
    let new_event = json!({"type":"interaction_created","data":{"id":"input-2","status":"pending","expiresAt":i64::MAX}});
    app.on_node_event("work", "worker", new_event.as_object().unwrap().clone());
    assert!(
        list_suggestions(&app.db.lock(), "alice", 100)
            .unwrap()
            .iter()
            .any(|s| s.disposition == Disposition::Pending)
    );
    let restarted = json!({"type":"runner_ready"});
    app.on_node_event("work", "worker", restarted.as_object().unwrap().clone());
    assert!(
        !list_suggestions(&app.db.lock(), "alice", 100)
            .unwrap()
            .iter()
            .any(|s| s.disposition == Disposition::Pending)
    );
    assert_eq!(
        get_task(&app.db.lock(), "alice", task_id).unwrap().status,
        TaskStatus::Tracked
    );
}
