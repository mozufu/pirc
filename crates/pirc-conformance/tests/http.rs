//! What the gateway answers around its routes rather than in them: unknown
//! routes and methods, request bodies it cannot or will not parse, the body
//! size limit and the error shape (`apps/gateway/src/http.ts`,
//! `apps/gateway/src/errors.ts`).

use pirc_conformance::{Cluster, GatewayOptions, Transcript, browser_headers};
use serde_json::json;

/// `PIRC_UPLOAD_MAX_BYTES`, the gateway's body limit, in this scenario.
const BODY_LIMIT: usize = 4096;

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn http_edges() {
    let Some(cluster) = Cluster::start_with(GatewayOptions {
        without_node: true,
        env: vec![("PIRC_UPLOAD_MAX_BYTES", BODY_LIMIT.to_string())],
        ..GatewayOptions::default()
    })
    .await
    else {
        return;
    };
    let api = cluster.api();
    let mut t = Transcript::new(cluster.volatile());
    let browser = browser_headers();
    let anonymous: Vec<_> = browser
        .iter()
        .filter(|(name, _)| *name != "x-pirc-user")
        .cloned()
        .collect();

    let health = api.send("GET", "/api/health", &browser, None).await;
    t.response("health", "GET /api/health", &health);
    let query = api.send("GET", "/api/health?x=1", &browser, None).await;
    t.response("health with a query", "GET /api/health?x=1", &query);
    let unknown = api.send("GET", "/api/nope", &browser, None).await;
    t.response("unknown route", "GET /api/nope", &unknown);
    let outside = api.send("GET", "/nope", &browser, None).await;
    t.response("unknown route outside /api", "GET /nope", &outside);
    let unknown = api.send("GET", "/api/nope", &anonymous, None).await;
    t.response("unknown route, no identity", "GET /api/nope", &unknown);
    let method = api.send("PUT", "/api/health", &browser, None).await;
    t.response("unknown method", "PUT /api/health", &method);
    let node = api.send("GET", "/node/connect", &browser, None).await;
    t.response("node link without upgrade", "GET /node/connect", &node);

    // Scoped `no-store` replies and Fastify's 414 for a path parameter over
    // 100 characters (before authentication, without `no-store`).
    let long = "x".repeat(101);
    for (step, method, path, headers) in [
        (
            "memory, no identity",
            "GET",
            "/api/memory".to_owned(),
            &anonymous,
        ),
        (
            "memory history, no identity",
            "GET",
            "/api/memory/entries/e1/history".to_owned(),
            &anonymous,
        ),
        (
            "schedules, no identity",
            "GET",
            "/api/schedules".to_owned(),
            &anonymous,
        ),
        (
            "long memory id",
            "POST",
            format!("/api/memory/entries/{long}/forget"),
            &browser,
        ),
        (
            "long memory id, no identity",
            "GET",
            format!("/api/memory/entries/{long}/history"),
            &anonymous,
        ),
        (
            "long device id",
            "DELETE",
            format!("/api/devices/{long}"),
            &browser,
        ),
        (
            "long schedule id",
            "GET",
            format!("/api/schedules/{long}"),
            &browser,
        ),
        (
            "long run id",
            "POST",
            format!("/api/schedules/s1/runs/{long}/dismiss"),
            &browser,
        ),
    ] {
        let response = api.send(method, &path, headers, None).await;
        t.response(
            step,
            &format!("{method} {}", path.replace(&long, "<101 x>")),
            &response,
        );
    }

    let post = |content_type: Option<&'static str>, body: &[u8]| {
        let api = api.clone();
        let browser = browser.clone();
        let body = body.to_vec();
        async move {
            api.send_bytes(
                "POST",
                "/api/conversation-submissions/prepare",
                &browser,
                content_type,
                body,
            )
            .await
        }
    };
    let cases: [(&str, Option<&'static str>, Vec<u8>); 9] = [
        (
            "valid JSON, unknown workspace",
            Some("application/json"),
            br#"{"workspaceId":"missing"}"#.to_vec(),
        ),
        (
            "JSON with a charset",
            Some("application/json; charset=utf-8"),
            br#"{"workspaceId":"missing"}"#.to_vec(),
        ),
        ("invalid JSON", Some("application/json"), b"{".to_vec()),
        ("empty JSON body", Some("application/json"), Vec::new()),
        ("JSON array", Some("application/json"), b"[]".to_vec()),
        (
            "JSON as text/plain",
            Some("text/plain"),
            br#"{"workspaceId":"missing"}"#.to_vec(),
        ),
        (
            "JSON without a content type",
            None,
            br#"{"workspaceId":"missing"}"#.to_vec(),
        ),
        (
            "JSON over the body limit",
            Some("application/json"),
            json!({ "workspaceId": "x".repeat(BODY_LIMIT) })
                .to_string()
                .into_bytes(),
        ),
        (
            "bytes over the body limit",
            Some("application/octet-stream"),
            vec![0; BODY_LIMIT + 1],
        ),
    ];
    for (step, content_type, body) in cases {
        let response = post(content_type, &body).await;
        t.response(
            step,
            "POST /api/conversation-submissions/prepare",
            &response,
        );
    }

    insta::assert_json_snapshot!("http_edges", t.into_value());
}
