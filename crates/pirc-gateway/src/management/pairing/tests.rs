use std::sync::Arc;
use std::sync::atomic::{AtomicI64, Ordering};

use serde_json::{Value, json};

use super::*;
use crate::db::Db;
use crate::devices::DeviceTokens;
use crate::test_support::{app_with_models, call};

fn verifier() -> String {
    URL_SAFE_NO_PAD.encode(random_bytes::<32>())
}

fn store() -> (Arc<DeviceTokens>, NativeManagementGrants, Arc<AtomicI64>) {
    let devices = DeviceTokens::new(Arc::new(Db::memory()), 7 * 86_400_000, 30 * 86_400_000);
    let clock = Arc::new(AtomicI64::new(1_000_000));
    let read = clock.clone();
    let grants = NativeManagementGrants::with_clock(
        devices.clone(),
        Arc::new(move || read.load(Ordering::SeqCst)),
    );
    (devices, grants, clock)
}

/// One request through the router with the given headers and peer.
async fn raw(
    app: &AppState,
    method: &str,
    path: &str,
    headers: &[(&str, &str)],
    peer: &str,
    body: Option<Value>,
) -> (u16, axum::http::HeaderMap, Value) {
    use tower::ServiceExt;
    let mut request = axum::http::Request::builder()
        .method(method)
        .uri(path)
        .header(crate::capabilities::HEADER, "test/2")
        .extension(axum::extract::ConnectInfo(
            peer.parse::<std::net::SocketAddr>().unwrap(),
        ));
    for (name, value) in headers {
        request = request.header(*name, *value);
    }
    let bytes = match body {
        Some(body) => {
            request = request.header("content-type", "application/json");
            body.to_string()
        }
        None => String::new(),
    };
    let response = crate::app::router(app.clone())
        .oneshot(request.body(axum::body::Body::from(bytes)).unwrap())
        .await
        .unwrap();
    let status = response.status().as_u16();
    let headers = response.headers().clone();
    let bytes = axum::body::to_bytes(response.into_body(), 1 << 20)
        .await
        .unwrap();
    (
        status,
        headers,
        serde_json::from_slice(&bytes).unwrap_or(Value::Null),
    )
}

async fn open_request(app: &AppState, secret: &str) -> String {
    let (status, created) = call(
        app,
        "POST",
        "/api/pairing/requests",
        None,
        None,
        Some(json!({
            "deviceName": " Pixel 9 ",
            "platform": "android",
            "challenge": sha256_hex(secret),
        })),
    )
    .await;
    assert_eq!(status, 201, "{created}");
    created["id"].as_str().unwrap().to_owned()
}

async fn claim(app: &AppState, id: &str, secret: &str, code: Option<&str>) -> (u16, Value) {
    let mut body = json!({ "verifier": secret });
    if let Some(code) = code {
        body["code"] = json!(code);
    }
    call(
        app,
        "POST",
        &format!("/api/pairing/requests/{id}/claim"),
        None,
        None,
        Some(body),
    )
    .await
}

fn wrong(code: &str) -> String {
    let digit = (code.as_bytes()[0] - b'0' + 1) % 10;
    format!("{digit}{}", &code[1..])
}

#[tokio::test]
async fn an_app_pairs_after_a_browser_approves_and_the_code_matches() {
    let (app, _dir) = app_with_models(json!({}));
    let secret = verifier();
    let id = open_request(&app, &secret).await;

    // Waiting: the app learns nothing else.
    let (status, waiting) = claim(&app, &id, &secret, None).await;
    assert_eq!((status, waiting["status"].as_str()), (202, Some("pending")));
    // A code before the approval is no attempt.
    let (status, _) = claim(&app, &id, &secret, Some("123456")).await;
    assert_eq!(status, 202);

    // Only a browser identity sees or decides the request.
    let approval = format!("/api/pairing/approvals/{id}");
    let (status, _) = call(&app, "GET", &approval, None, None, None).await;
    assert_eq!(status, 401, "no identity");
    let (_, phone_token) = app.devices.create("alice", "Old phone").unwrap();
    for path in [approval.clone(), format!("{approval}/approve")] {
        let method = if path.ends_with("approve") {
            "POST"
        } else {
            "GET"
        };
        let (status, body) = call(&app, method, &path, None, Some(&phone_token), None).await;
        assert_eq!(status, 403, "device token on {path}: {body}");
    }
    let (status, body) = call(
        &app,
        "POST",
        &format!("{approval}/approve"),
        None,
        None,
        None,
    )
    .await;
    assert_eq!(status, 401, "{body}");
    let (status, shown) = call(&app, "GET", &approval, Some("alice"), None, None).await;
    assert_eq!(status, 200, "{shown}");
    assert_eq!(shown["deviceName"], "Pixel 9");
    assert_eq!(shown["platform"], "android");
    assert_eq!(shown["pairing"], json!({ "idleDays": 7, "maxDays": 30 }));
    assert_eq!(shown.get("code"), None);

    let (status, approved) = call(
        &app,
        "POST",
        &format!("{approval}/approve"),
        Some("alice"),
        None,
        None,
    )
    .await;
    assert_eq!(status, 200, "{approved}");
    assert_eq!(approved["status"], "approved");
    let code = approved["code"].as_str().unwrap().to_owned();
    assert!(valid_code(&code));
    // Bound to alice: another user no longer sees it.
    assert_eq!(
        call(&app, "GET", &approval, Some("bob"), None, None)
            .await
            .0,
        404
    );
    assert_eq!(
        call(&app, "GET", &approval, Some("alice"), None, None)
            .await
            .1["code"],
        code.as_str()
    );

    let (status, waiting) = claim(&app, &id, &secret, None).await;
    assert_eq!(
        (status, waiting["status"].as_str()),
        (202, Some("approved"))
    );
    // A wrong verifier is refused and costs no attempt.
    let (status, _) = claim(&app, &id, &verifier(), Some(&code)).await;
    assert_eq!(status, 403);
    let (status, refused) = claim(&app, &id, &secret, Some(&wrong(&code))).await;
    assert_eq!(status, 403, "{refused}");
    assert_eq!(refused["error"]["code"], "invalid_code");
    assert_eq!(refused["error"]["details"]["attemptsLeft"], 4);

    let (status, headers, paired) = raw(
        &app,
        "POST",
        &format!("/api/pairing/requests/{id}/claim"),
        &[
            ("host", "a.example"),
            (
                crate::request_shape::REQUEST_HEADER,
                crate::request_shape::REQUEST_VALUE,
            ),
        ],
        "127.0.0.1:40000",
        Some(json!({ "verifier": secret, "code": code })),
    )
    .await;
    assert_eq!(status, 200, "{paired}");
    assert_eq!(headers["cache-control"], "no-store");
    let token = paired["token"].as_str().unwrap();
    assert!(token.starts_with("pirc_dev_"));
    assert_eq!(paired["device"]["name"], "Pixel 9");
    let (status, me) = call(&app, "GET", "/api/device", None, Some(token), None).await;
    assert_eq!(status, 200, "{me}");
    assert_eq!(me["device"]["id"], paired["device"]["id"]);
    assert_eq!(app.devices.list("alice").unwrap().len(), 2);

    // Claimed once: the request has ended.
    assert_eq!(claim(&app, &id, &secret, Some(&code)).await.0, 410);
}

#[tokio::test]
async fn the_fifth_wrong_code_ends_the_request_and_a_sixth_right_one_is_refused() {
    let (app, _dir) = app_with_models(json!({}));
    let secret = verifier();
    let id = open_request(&app, &secret).await;
    let (_, approved) = call(
        &app,
        "POST",
        &format!("/api/pairing/approvals/{id}/approve"),
        Some("alice"),
        None,
        None,
    )
    .await;
    let code = approved["code"].as_str().unwrap().to_owned();
    for left in (1..5).rev() {
        let (status, body) = claim(&app, &id, &secret, Some(&wrong(&code))).await;
        assert_eq!(status, 403);
        assert_eq!(body["error"]["details"]["attemptsLeft"], left);
    }
    let (status, body) = claim(&app, &id, &secret, Some(&wrong(&code))).await;
    assert_eq!(
        (status, body["error"]["code"].as_str()),
        (410, Some("pairing_ended"))
    );
    let (status, _) = claim(&app, &id, &secret, Some(&code)).await;
    assert_eq!(status, 410, "a sixth code, even the right one");
    assert_eq!(
        call(
            &app,
            "GET",
            &format!("/api/pairing/approvals/{id}"),
            Some("alice"),
            None,
            None
        )
        .await
        .1["status"],
        "revoked"
    );
    assert!(app.devices.list("alice").unwrap().is_empty());
}

#[test]
fn concurrent_claims_get_no_more_than_five_tries() {
    let (_, grants, _) = store();
    let grants = Arc::new(grants);
    let secret = verifier();
    let created = grants
        .create_pairing("Pixel", "android", &sha256_hex(&secret))
        .unwrap();
    let code = grants
        .decide_pairing("alice", None, &created.id, true)
        .unwrap()
        .code
        .unwrap();
    let wrong = wrong(&code);
    let threads: Vec<_> = (0..12)
        .map(|_| {
            let (grants, id, secret, wrong) = (
                grants.clone(),
                created.id.clone(),
                secret.clone(),
                wrong.clone(),
            );
            std::thread::spawn(move || {
                grants
                    .claim_pairing(&id, &secret, Some(&wrong))
                    .unwrap_err()
                    .code
            })
        })
        .collect();
    let codes: Vec<&str> = threads.into_iter().map(|t| t.join().unwrap()).collect();
    assert_eq!(codes.iter().filter(|c| **c == "invalid_code").count(), 4);
    assert_eq!(codes.iter().filter(|c| **c == "pairing_ended").count(), 8);
    assert_eq!(
        grants
            .claim_pairing(&created.id, &secret, Some(&code))
            .unwrap_err()
            .status,
        410
    );
}

#[test]
fn requests_expire_after_ten_minutes_and_at_most_twenty_are_open() {
    let (_, grants, clock) = store();
    let secret = verifier();
    let first = grants
        .create_pairing("Pixel", "android", &sha256_hex(&secret))
        .unwrap();
    assert_eq!(first.expires_at - first.server_now, PAIRING_REQUEST_TTL_MS);
    assert_eq!(first.approve_path, format!("/?pairing={}", first.id));
    for _ in 1..MAX_OPEN_PAIRING_REQUESTS {
        grants
            .create_pairing("Pixel", "android", &sha256_hex(verifier()))
            .unwrap();
    }
    let refused = grants
        .create_pairing("Pixel", "android", &sha256_hex(verifier()))
        .unwrap_err();
    assert_eq!(refused.status, 429, "the 21st request");

    // Approved, then expired: the claim ends with 410 and the code is gone.
    let code = grants
        .decide_pairing("alice", None, &first.id, true)
        .unwrap()
        .code
        .unwrap();
    clock.fetch_add(PAIRING_REQUEST_TTL_MS, Ordering::SeqCst);
    let expired = grants
        .claim_pairing(&first.id, &secret, Some(&code))
        .unwrap_err();
    assert_eq!(expired.status, 410);
    let view = grants.pairing_approval("alice", None, &first.id).unwrap();
    assert_eq!(view.status, ManagementRequestStatus::Expired);
    assert_eq!(view.code, None);
    // Expired requests no longer count as open.
    grants
        .create_pairing("Pixel", "android", &sha256_hex(verifier()))
        .unwrap();
}

#[test]
fn a_denied_request_ends_and_the_ten_phone_limit_keeps_it_approved() {
    let (devices, grants, _) = store();
    let secret = verifier();
    let denied = grants
        .create_pairing("Pixel", "android", &sha256_hex(&secret))
        .unwrap();
    let view = grants
        .decide_pairing("alice", None, &denied.id, false)
        .unwrap();
    assert_eq!(view.status, ManagementRequestStatus::Denied);
    assert_eq!(
        grants
            .claim_pairing(&denied.id, &secret, None)
            .unwrap_err()
            .status,
        410
    );

    for index in 0..10 {
        devices.create("alice", &format!("d{index}")).unwrap();
    }
    let full = grants
        .create_pairing("Pixel", "android", &sha256_hex(&secret))
        .unwrap();
    let code = grants
        .decide_pairing("alice", None, &full.id, true)
        .unwrap()
        .code
        .unwrap();
    let refused = grants
        .claim_pairing(&full.id, &secret, Some(&code))
        .unwrap_err();
    assert_eq!(refused.status, 409);
    devices
        .revoke("alice", &devices.list("alice").unwrap()[0].id)
        .unwrap();
    assert!(matches!(
        grants
            .claim_pairing(&full.id, &secret, Some(&code))
            .unwrap(),
        PairingClaim::Paired { .. }
    ));
}

#[test]
fn pairing_and_management_requests_do_not_see_each_other() {
    let (devices, grants, _) = store();
    let (phone, _) = devices.create("alice", "Pixel").unwrap();
    let pairing = grants
        .create_pairing("Pixel", "android", &sha256_hex(verifier()))
        .unwrap();
    assert_eq!(
        grants.view("alice", None, &pairing.id).unwrap_err().status,
        404
    );
    assert_eq!(
        grants
            .decide("alice", None, &pairing.id, true)
            .unwrap_err()
            .status,
        404
    );
    let management = grants
        .create(
            "alice",
            &phone.id,
            &sha256_hex(verifier()),
            vec![super::super::ManagementCapability::Providers],
            false,
        )
        .unwrap();
    let id = &management.request.id;
    assert_eq!(
        grants
            .pairing_approval("alice", None, id)
            .unwrap_err()
            .status,
        404
    );
    assert_eq!(
        grants
            .decide_pairing("alice", None, id, true)
            .unwrap_err()
            .status,
        404
    );
    assert_eq!(
        grants
            .claim_pairing(id, &verifier(), None)
            .unwrap_err()
            .status,
        404
    );
}

#[tokio::test]
async fn identity_less_routes_still_need_the_proxy_and_an_allowed_host() {
    let (app, _dir) = app_with_models(json!({}));
    let body =
        json!({ "deviceName": "Pixel", "platform": "android", "challenge": sha256_hex("x") });
    let shape = (
        crate::request_shape::REQUEST_HEADER,
        crate::request_shape::REQUEST_VALUE,
    );
    let (status, _, _) = raw(
        &app,
        "POST",
        "/api/pairing/requests",
        &[("host", "a.example"), shape],
        "10.0.0.9:40000",
        Some(body.clone()),
    )
    .await;
    assert_eq!(status, 401, "an untrusted peer");
    let (status, _, _) = raw(
        &app,
        "POST",
        "/api/pairing/requests",
        &[("host", "evil.example"), shape],
        "127.0.0.1:40000",
        Some(body.clone()),
    )
    .await;
    assert_eq!(status, 403, "a Host that is not allowed");
    let (status, _, _) = raw(
        &app,
        "POST",
        "/api/pairing/requests",
        &[
            ("host", "a.example"),
            ("origin", "https://evil.example"),
            shape,
        ],
        "127.0.0.1:40000",
        Some(body.clone()),
    )
    .await;
    assert_eq!(status, 403, "an Origin that is not allowed");
    let (status, headers, created) = raw(
        &app,
        "POST",
        "/api/pairing/requests",
        &[("host", "a.example"), shape],
        "127.0.0.1:40000",
        Some(body.clone()),
    )
    .await;
    assert_eq!(status, 201, "{created}");
    assert_eq!(headers["cache-control"], "no-store");
    // Only these two routes go without an identity.
    for (method, path) in [
        ("GET", "/api/pairing/requests".to_owned()),
        (
            "POST",
            format!(
                "/api/pairing/requests/{}/claim/x",
                created["id"].as_str().unwrap()
            ),
        ),
        ("POST", "/api/pairing/approvals/x/approve".to_owned()),
    ] {
        let (status, _, _) = raw(
            &app,
            method,
            &path,
            &[
                ("host", "a.example"),
                ("origin", "https://a.example"),
                shape,
            ],
            "127.0.0.1:40000",
            None,
        )
        .await;
        assert_eq!(status, 401, "{method} {path}");
    }
    assert!(is_anonymous_route(
        &axum::http::Method::POST,
        "/api/pairing/requests/abc/claim"
    ));
    assert!(!is_anonymous_route(
        &axum::http::Method::POST,
        "/api/pairing/requests/a/b/claim"
    ));
    assert!(!is_anonymous_route(
        &axum::http::Method::GET,
        "/api/pairing/requests"
    ));
}

#[test]
fn codes_are_six_digits() {
    for _ in 0..200 {
        assert!(valid_code(&new_code()));
    }
    assert!(!valid_code("12345"));
    assert!(!valid_code("12345a"));
}

#[tokio::test]
async fn a_browser_denies_over_http_and_the_twenty_first_request_is_refused() {
    let (app, _dir) = app_with_models(json!({}));
    let secret = verifier();
    let id = open_request(&app, &secret).await;
    let deny = format!("/api/pairing/approvals/{id}/deny");
    assert_eq!(call(&app, "POST", &deny, None, None, None).await.0, 401);
    let (_, phone) = app.devices.create("alice", "Old phone").unwrap();
    assert_eq!(
        call(&app, "POST", &deny, None, Some(&phone), None).await.0,
        403
    );
    let (status, denied) = call(&app, "POST", &deny, Some("alice"), None, None).await;
    assert_eq!((status, denied["status"].as_str()), (200, Some("denied")));
    assert_eq!(denied.get("code"), None);
    assert_eq!(claim(&app, &id, &secret, None).await.0, 410);
    // A decided request cannot be decided again.
    assert_eq!(
        call(
            &app,
            "POST",
            &format!("/api/pairing/approvals/{id}/approve"),
            Some("alice"),
            None,
            None
        )
        .await
        .0,
        409
    );

    for _ in 0..MAX_OPEN_PAIRING_REQUESTS {
        open_request(&app, &verifier()).await;
    }
    let (status, refused) = call(
        &app,
        "POST",
        "/api/pairing/requests",
        None,
        None,
        Some(json!({ "deviceName": "Pixel", "platform": "android", "challenge": sha256_hex(verifier()) })),
    )
    .await;
    assert_eq!(status, 429, "{refused}");
}

#[tokio::test]
async fn a_bearer_or_a_large_body_is_refused_on_the_routes_without_identity() {
    let (app, _dir) = app_with_models(json!({}));
    let secret = verifier();
    let id = open_request(&app, &secret).await;
    let (_, real) = app.devices.create("alice", "Old phone").unwrap();
    let fake = format!("pirc_dev_{}", "x".repeat(43));
    let shape = (
        crate::request_shape::REQUEST_HEADER,
        crate::request_shape::REQUEST_VALUE,
    );
    let create =
        json!({ "deviceName": "Pixel", "platform": "android", "challenge": sha256_hex("x") });
    let claim_path = format!("/api/pairing/requests/{id}/claim");
    for token in [fake.as_str(), real.as_str(), "something-else"] {
        let bearer = format!("Bearer {token}");
        for (path, body) in [
            ("/api/pairing/requests", create.clone()),
            (claim_path.as_str(), json!({ "verifier": secret })),
        ] {
            let (status, _, body) = raw(
                &app,
                "POST",
                path,
                &[("host", "a.example"), ("authorization", &bearer), shape],
                "127.0.0.1:40000",
                Some(body),
            )
            .await;
            assert_eq!(
                (status, body["error"]["code"].as_str()),
                (401, Some("bearer_not_allowed")),
                "{token} on {path}"
            );
        }
    }
    // A body past 4 KiB is refused even with the request header.
    let mut big = create.clone();
    big["deviceName"] = json!("x".repeat(5000));
    let (status, _, _) = raw(
        &app,
        "POST",
        "/api/pairing/requests",
        &[("host", "a.example"), shape],
        "127.0.0.1:40000",
        Some(big),
    )
    .await;
    assert_eq!(status, 413);
}

#[tokio::test]
async fn a_device_name_has_no_control_or_format_characters() {
    let (app, _dir) = app_with_models(json!({}));
    for name in [
        "Pixel\u{202E}9",
        "Pi\u{200B}xel",
        "Pixel\u{0007}",
        "Pi\u{FEFF}xel",
        " ",
        &"x".repeat(101),
    ] {
        let (status, _) = call(
            &app,
            "POST",
            "/api/pairing/requests",
            None,
            None,
            Some(
                json!({ "deviceName": name, "platform": "android", "challenge": sha256_hex("x") }),
            ),
        )
        .await;
        assert_eq!(status, 400, "{name:?}");
    }
    assert_eq!(checked_device_name("  Pixel 9 Pro  "), Some("Pixel 9 Pro"));
    assert_eq!(checked_device_name("Brian’s 手機"), Some("Brian’s 手機"));
}

#[tokio::test]
async fn the_claim_returns_the_device_record_as_get_api_device_shows_it() {
    let (app, _dir) = app_with_models(json!({}));
    let secret = verifier();
    let id = open_request(&app, &secret).await;
    let (_, approved) = call(
        &app,
        "POST",
        &format!("/api/pairing/approvals/{id}/approve"),
        Some("alice"),
        None,
        None,
    )
    .await;
    let (status, paired) = claim(&app, &id, &secret, approved["code"].as_str()).await;
    assert_eq!(status, 200, "{paired}");
    let device = &paired["device"];
    let at = |key: &str| device[key].as_i64().unwrap();
    assert_eq!(
        at("expiresAt") - at("createdAt"),
        30 * 86_400_000,
        "the maximum window"
    );
    assert_eq!(at("idleExpiresAt") - at("lastUsedAt"), 7 * 86_400_000);
    let token = paired["token"].as_str().unwrap();
    let (_, read) = call(&app, "GET", "/api/device", None, Some(token), None).await;
    assert_eq!(&read["device"], device);
}
