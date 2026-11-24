use super::super::acceptance::tests::{identity, model, prepared, register};
use super::super::tests::{app, call, count, disk_app};
use super::*;
use axum::http::{HeaderMap, HeaderValue};
use tower::ServiceExt;
fn headers(values: &[&str]) -> HeaderMap {
    let mut h = HeaderMap::new();
    for v in values {
        h.append(HEADER, HeaderValue::from_str(v).unwrap());
    }
    h
}
async fn request(
    app: &AppState,
    method: &str,
    path: &str,
    values: &[&str],
    body: Option<Value>,
) -> (u16, Value) {
    let mut req = axum::http::Request::builder()
        .method(method)
        .uri(path)
        .header("host", "a.example")
        .header(
            crate::request_shape::REQUEST_HEADER,
            crate::request_shape::REQUEST_VALUE,
        )
        .header("origin", "https://a.example")
        .header("x-pirc-user", "alice")
        .header("content-type", "application/json")
        .extension(axum::extract::ConnectInfo(
            "127.0.0.1:40000".parse::<std::net::SocketAddr>().unwrap(),
        ));
    for v in values {
        req = req.header(HEADER, *v);
    }
    let response = crate::app::router(app.clone())
        .oneshot(
            req.body(axum::body::Body::from(
                body.map(|v| v.to_string()).unwrap_or_default(),
            ))
            .unwrap(),
        )
        .await
        .unwrap();
    let code = response.status().as_u16();
    let bytes = axum::body::to_bytes(response.into_body(), 4 * 1024 * 1024)
        .await
        .unwrap();
    (code, serde_json::from_slice(&bytes).unwrap_or(Value::Null))
}
#[test]
fn old_unknown_or_duplicate_client_versions_cannot_submit() {
    for values in [vec![], vec!["1"], vec!["3"], vec!["02"], vec!["2", "2"]] {
        let h = headers(&values);
        assert!(require(&h).is_err());
        let response = capabilities(&identity(), &h);
        assert_eq!(response["version"], 1);
        assert_eq!(response["requiredClientContract"], 2);
        assert_eq!(response["canSubmit"], false);
        assert_eq!(response["clientContract"], 0);
    }
    let h = headers(&["2"]);
    require(&h).unwrap();
    assert_eq!(capabilities(&identity(), &h)["canSubmit"], true);
}
#[tokio::test]
async fn stale_cached_activation_cannot_prepare_accept_materialize_or_dispatch() {
    let (app, _dir) = app();
    model(&app);
    let calls = register(&app);
    let input = super::super::tests::input();
    let body = json!({"operationId":input.operation_id,"submission":input.submission});
    for values in [vec![], vec!["1"], vec!["3"], vec!["2", "2"]] {
        let (code, error) = request(
            &app,
            "POST",
            "/api/conversation-submissions/prepare",
            &values,
            Some(body.clone()),
        )
        .await;
        assert_eq!(code, 409);
        assert_eq!(error["error"]["code"], "first_send_client_upgrade_required");
    }
    assert_eq!(count(&app.db.lock(), "conversation_submissions"), 0);
    prepared(&app, false);
    for route in ["accept", "materialize", "dispatch", "retry"] {
        let (code, error) = request(
            &app,
            "POST",
            &format!("/api/conversation-submissions/draft-1/{route}"),
            &[],
            Some(json!({"clientId":"old","generation":1})),
        )
        .await;
        assert_eq!(code, 409, "{error}");
        assert_eq!(error["error"]["code"], "first_send_client_upgrade_required");
    }
    assert!(calls.lock().unwrap().is_empty());
    assert_eq!(count(&app.db.lock(), "sessions"), 0);
    assert_eq!(count(&app.db.lock(), "commands"), 0);
    assert_eq!(
        request(
            &app,
            "GET",
            "/api/conversation-submissions/draft-1",
            &[],
            None
        )
        .await
        .0,
        200
    );
    assert_eq!(
        request(
            &app,
            "DELETE",
            "/api/conversation-submissions/draft-1",
            &[],
            None
        )
        .await
        .0,
        200
    );
}
#[tokio::test]
async fn migration_from_1017_keeps_original_intent_and_stopping_job() {
    let (app, _dir) = disk_app();
    model(&app);
    register(&app);
    prepared(&app, false);
    let original = super::super::acceptance::accept_intent(&app, &identity(), "draft-1")
        .await
        .unwrap();
    let (code, body) = call(
        &app,
        "POST",
        "/api/conversation-submissions/draft-1/stop-control/acquire",
        Some("alice"),
        None,
        Some(json!({"clientId":"phone"})),
    )
    .await;
    assert_eq!(code, 200);
    assert_eq!(
        call(
            &app,
            "POST",
            "/api/conversation-submissions/draft-1/stop",
            Some("alice"),
            None,
            Some(json!({"clientId":"phone","generation":body["lease"]["generation"]}))
        )
        .await
        .0,
        202
    );
    app.db
        .lock()
        .execute_batch(
            concat!(include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/src/conversation_bindings/test_remove_policies.sql")), "DROP TABLE conversation_submission_retry_retirements; DROP TABLE conversation_submission_retry_attempts; DROP TRIGGER IF EXISTS conversation_binding_insert; DROP TRIGGER IF EXISTS conversation_binding_mapping; DROP TRIGGER IF EXISTS conversation_binding_mode; DROP TABLE IF EXISTS conversation_bindings; PRAGMA user_version=1017;"),
        )
        .unwrap();
    let reopened = crate::db::Db::open(&app.config.state_dir.join("gateway.sqlite")).unwrap();
    let db = reopened.lock();
    assert_eq!(
        db.query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        crate::db::SCHEMA_VERSION
    );
    let row = super::super::lookup(&db, "alice", "draft-1").unwrap();
    assert_eq!(row.session_id, original.session_id);
    assert_eq!(row.state, Phase::Stopping);
    assert_eq!(row.submission.unwrap().message, "Keep this first message");
    assert_eq!(count(&db, "conversation_submission_pending_stops"), 1);
    assert_eq!(count(&db, "commands"), 0);
}

#[tokio::test]
async fn retry_retirement_requires_the_recovery_contract_before_any_mutation() {
    let (app, _dir) = app();
    for values in [vec![], vec!["1"], vec!["2", "2"]] {
        let (code, value) = request(
            &app,
            "POST",
            "/api/conversation-submissions/missing/retries/unsent/retire",
            &values,
            Some(json!({"previousCommandId":"old","clientId":"phone","generation":1})),
        )
        .await;
        assert_eq!(code, 409, "{value}");
        assert_eq!(value["error"]["code"], "first_send_client_upgrade_required");
        assert_eq!(
            count(&app.db.lock(), "conversation_submission_retry_retirements"),
            0
        );
    }
}
