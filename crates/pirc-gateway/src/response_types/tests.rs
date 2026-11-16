use axum::Router;
use axum::http::{Request, StatusCode, header};
use axum::middleware;
use axum::response::IntoResponse;
use axum::routing::{MethodRouter, get};
use pirc_protocol::{NodeHttpRequest, NodeHttpResponse, NodeRole};
use serde_json::{Value, json};
use tower::ServiceExt;

use super::*;
use crate::db::Store as _;
use crate::request_shape::tests::{USER, fixture};

async fn answer(router: Router, path: &str) -> Response {
    router
        .oneshot(
            Request::builder()
                .uri(path)
                .body(axum::body::Body::empty())
                .unwrap(),
        )
        .await
        .unwrap()
}

fn typed(content_type: &'static str) -> MethodRouter {
    get(move || async move {
        let mut response = "<script>alert(1)</script>".into_response();
        response
            .headers_mut()
            .insert(header::CONTENT_TYPE, HeaderValue::from_static(content_type));
        response
    })
}

#[tokio::test]
async fn renderable_or_scriptable_types_never_leave_the_gateway() {
    let router = Router::new()
        .route("/html", get(typed("text/html")))
        .route("/html-charset", get(typed("Text/HTML; charset=utf-8")))
        .route("/xhtml", get(typed("application/xhtml+xml")))
        .route("/xml", get(typed("text/xml")))
        .route("/js", get(typed("text/javascript")))
        .route("/app-js", get(typed("application/javascript")))
        .route("/svg", get(typed("image/svg+xml")))
        .route("/pdf", get(typed("application/pdf")))
        .route("/octet", get(typed("application/octet-stream")))
        .route("/json", get(typed("application/json; charset=utf-8")))
        .route("/text", get(typed("text/plain; charset=utf-8")))
        .route("/webm", get(typed("video/webm")))
        .layer(middleware::from_fn(guard));
    for path in [
        "/html",
        "/html-charset",
        "/xhtml",
        "/xml",
        "/js",
        "/app-js",
        "/svg",
        "/pdf",
        "/octet",
    ] {
        let response = answer(router.clone(), path).await;
        assert_eq!(
            response.status(),
            StatusCode::INTERNAL_SERVER_ERROR,
            "{path}"
        );
        assert_eq!(
            response.headers()[header::CONTENT_TYPE],
            "application/json; charset=utf-8",
            "{path}"
        );
        assert_eq!(
            response.headers()[header::X_CONTENT_TYPE_OPTIONS],
            "nosniff"
        );
        let body = axum::body::to_bytes(response.into_body(), 4096)
            .await
            .unwrap();
        assert!(!String::from_utf8_lossy(&body).contains("script"), "{path}");
    }
    for path in ["/json", "/text", "/webm"] {
        let response = answer(router.clone(), path).await;
        assert_eq!(response.status(), StatusCode::OK, "{path}");
        assert_eq!(
            response.headers()[header::X_CONTENT_TYPE_OPTIONS],
            "nosniff"
        );
    }
}

/// Every reply of the real router, whatever produced it, carries the header and
/// an allowed type (or none, for an empty body).
#[tokio::test]
async fn replies_of_the_router_are_allowed_types_with_nosniff() {
    let (app, _dir) = fixture();
    let mut seen = std::collections::BTreeSet::new();
    let cases: [(&str, &str, bool); 5] = [
        ("GET", "/api/health", true),
        ("GET", "/api/nodes", true),
        ("POST", "/api/not/a/route", true),
        ("GET", "/api/not/a/route", true),
        ("POST", "/api/push/test", false),
    ];
    for (method, path, authenticated) in cases {
        let request = Request::builder()
            .method(method)
            .uri(path)
            .header("host", "a.example")
            .header("origin", "https://a.example")
            .extension(axum::extract::ConnectInfo(
                "127.0.0.1:40000".parse::<std::net::SocketAddr>().unwrap(),
            ));
        let request = if authenticated {
            request.header("x-pirc-user", USER)
        } else {
            request
        };
        let response = crate::app::router(app.clone())
            .oneshot(request.body(axum::body::Body::empty()).unwrap())
            .await
            .unwrap();
        assert_eq!(
            response.headers()[header::X_CONTENT_TYPE_OPTIONS],
            "nosniff",
            "{method} {path}"
        );
        if let Some(value) = response.headers().get(header::CONTENT_TYPE) {
            seen.insert(media_type(value));
        }
    }
    assert!(
        seen.iter()
            .all(|kind| ALLOWED_RESPONSE_TYPES.contains(&kind.as_str()))
    );
}

/// A node's answer is a status and a JSON value; it cannot name a content type.
/// A string body that is a page stays text.
#[tokio::test]
async fn a_node_cannot_make_the_gateway_relay_a_page() {
    let (app, _dir) = fixture();
    let user = USER;
    app.db
        .lock()
        .sync_remote_workspaces(
            "work",
            &[(
                "chats".into(),
                "Chats".into(),
                pirc_protocol::ModeId::new("chat").unwrap(),
            )],
        )
        .unwrap();
    let session = app
        .db
        .lock()
        .create_session("work:chats", "node://work/r1", "work", "r1", user)
        .unwrap()
        .id;
    for body in [
        Value::String("<!doctype html><script>alert(1)</script>".into()),
        json!({ "contentType": "text/html", "body": "<script>alert(1)</script>" }),
    ] {
        let node_body = body.clone();
        app.nodes.set_test_node(
            crate::nodes::ConnectedNode {
                id: "work".into(),
                role: NodeRole::Node,
                modes: vec![pirc_protocol::ModeId::new("chat").unwrap()],
                workspaces: vec![],
                added: Default::default(),
                connected_at: 0,
                last_seen_at: 0,
            },
            move |_: NodeHttpRequest| {
                Ok(NodeHttpResponse {
                    status: 200,
                    body: Some(node_body.clone()),
                })
            },
        );
        let request = Request::builder()
            .uri(format!("/api/sessions/{session}/files"))
            .header("host", "a.example")
            .header("x-pirc-user", user)
            .extension(axum::extract::ConnectInfo(
                "127.0.0.1:40000".parse::<std::net::SocketAddr>().unwrap(),
            ));
        let response = crate::app::router(app.clone())
            .oneshot(request.body(axum::body::Body::empty()).unwrap())
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let kind = response.headers()[header::CONTENT_TYPE]
            .to_str()
            .unwrap()
            .to_owned();
        assert!(
            kind == "text/plain; charset=utf-8" || kind == "application/json; charset=utf-8",
            "{kind}"
        );
        assert_eq!(
            response.headers()[header::X_CONTENT_TYPE_OPTIONS],
            "nosniff"
        );
    }
}
