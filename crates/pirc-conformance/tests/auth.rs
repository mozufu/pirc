//! How the gateway decides whether a browser request comes from the trusted
//! proxy and for whom (`apps/gateway/src/daemon/auth.ts`).

use pirc_conformance::{
    Api, Cluster, Connection, GatewayOptions, HOST, Transcript, browser_headers,
};
use serde_json::json;

const PROXY_SECRET: &str = "conformance-proxy-secret-0123456789abcdef";

fn without(name: &str) -> Vec<(&'static str, String)> {
    browser_headers()
        .into_iter()
        .filter(|(header, _)| *header != name)
        .collect()
}

fn with(name: &'static str, value: &str) -> Vec<(&'static str, String)> {
    let mut headers = without(name);
    headers.push((name, value.to_owned()));
    headers
}

/// A GET and a mutating route that changes nothing once authenticated (an invalid body).
async fn probe(api: &Api, t: &mut Transcript, case: &str, headers: &[(&str, String)]) {
    let get = api.send("GET", "/api/workspaces", headers, None).await;
    t.response(&format!("{case}: GET"), "GET /api/workspaces", &get);
    let post = api
        .send(
            "POST",
            "/api/conversation-submissions/prepare",
            headers,
            Some(json!({})),
        )
        .await;
    t.response(
        &format!("{case}: POST"),
        "POST /api/conversation-submissions/prepare",
        &post,
    );
}

async fn record_socket(t: &mut Transcript, step: &str, connection: Connection) {
    match connection {
        Connection::Refused(response) => t.response(step, "GET /api/events (upgrade)", &response),
        Connection::Open(mut socket) => {
            let (code, reason) = socket.closed().await;
            t.note(step, json!({ "closed": code, "reason": reason }));
        }
    }
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn browser_request_matrix() {
    let Some(cluster) = Cluster::start_with(GatewayOptions {
        without_node: true,
        ..Default::default()
    })
    .await
    else {
        return;
    };
    let api = cluster.api();
    let mut t = Transcript::new(cluster.volatile());

    probe(&api, &mut t, "proxy headers", &browser_headers()).await;
    probe(&api, &mut t, "no Origin", &without("origin")).await;
    probe(
        &api,
        &mut t,
        "Origin not allowed",
        &with("origin", "https://evil.example"),
    )
    .await;
    probe(
        &api,
        &mut t,
        "Host not allowed",
        &with("host", "evil.example"),
    )
    .await;
    probe(&api, &mut t, "no identity", &without("x-pirc-user")).await;
    probe(
        &api,
        &mut t,
        "identity not allowed",
        &with("x-pirc-user", "other@example.com"),
    )
    .await;
    let mut both = browser_headers();
    both.push((
        "authorization",
        format!("Bearer pirc_dev_{}", "a".repeat(43)),
    ));
    probe(&api, &mut t, "device token and identity", &both).await;
    let device = vec![
        ("host", HOST.to_owned()),
        ("x-pirc-client", pirc_conformance::CLIENT.to_owned()),
        (
            "authorization",
            format!("Bearer pirc_dev_{}", "a".repeat(43)),
        ),
    ];
    probe(&api, &mut t, "unknown device token", &device).await;

    let events = "/api/events?sessionId=session_missing";
    for (step, headers) in [
        ("events: unknown session", browser_headers()),
        ("events: no Origin", without("origin")),
        (
            "events: identity not allowed",
            with("x-pirc-user", "other@example.com"),
        ),
        ("events: no identity", without("x-pirc-user")),
        (
            "events: unknown device token",
            vec![
                ("host", HOST.to_owned()),
                ("x-pirc-client", pirc_conformance::CLIENT.to_owned()),
                (
                    "authorization",
                    format!("Bearer pirc_dev_{}", "a".repeat(43)),
                ),
            ],
        ),
    ] {
        let connection = api.connect(events, &headers).await;
        record_socket(&mut t, step, connection).await;
    }
    let connection = api.connect("/api/events", &browser_headers()).await;
    record_socket(&mut t, "events: no session id", connection).await;

    insta::assert_json_snapshot!("browser_request_matrix", t.into_value());
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn untrusted_peer() {
    let Some(cluster) = Cluster::start_with(GatewayOptions {
        without_node: true,
        // Not the address the test connects from.
        env: vec![("PIRC_TRUSTED_PROXIES", "192.0.2.1".to_owned())],
        ..GatewayOptions::default()
    })
    .await
    else {
        return;
    };
    let api = cluster.api();
    let mut t = Transcript::new(cluster.volatile());
    probe(
        &api,
        &mut t,
        "proxy headers from an untrusted peer",
        &browser_headers(),
    )
    .await;
    insta::assert_json_snapshot!("untrusted_peer", t.into_value());
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn proxy_secret() {
    let Some(cluster) = Cluster::start_with(GatewayOptions {
        without_node: true,
        env: vec![("PIRC_PROXY_SECRET", PROXY_SECRET.to_owned())],
        ..GatewayOptions::default()
    })
    .await
    else {
        return;
    };
    let api = cluster.api();
    let mut t = Transcript::new(cluster.volatile());
    probe(&api, &mut t, "no proxy secret", &browser_headers()).await;
    let mut wrong = browser_headers();
    wrong.push(("x-pirc-proxy-secret", format!("{PROXY_SECRET}x")));
    probe(&api, &mut t, "wrong proxy secret", &wrong).await;
    let mut right = browser_headers();
    right.push(("x-pirc-proxy-secret", PROXY_SECRET.to_owned()));
    probe(&api, &mut t, "proxy secret", &right).await;
    insta::assert_json_snapshot!("proxy_secret", t.into_value());
}
