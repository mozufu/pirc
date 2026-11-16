//! Subscription logins (`/api/provider-auth/sessions*`,
//! `backends/service.ts`) up to the point where a provider would be
//! contacted: the authorization pages, prompts, pasted-callback checks,
//! cancellation, sign-out during a login and the localhost callback server.
//! The callback servers listen on their fixed ports (53692, 1455).

use std::time::Duration;

use pirc_conformance::{Api, Cluster, GatewayOptions, Response, Transcript, browser_headers};
use regex::Regex;
use serde_json::{Value, json};

/// The random parts of an authorization URL (PKCE challenge, state).
fn mask_url(url: &str) -> String {
    let challenge = Regex::new(r"code_challenge=[A-Za-z0-9_-]{43}").unwrap();
    let state = Regex::new(r"([?&])state=[A-Za-z0-9_-]+").unwrap();
    let url = challenge.replace_all(url, "code_challenge=<challenge>");
    state.replace_all(&url, "${1}state=<state>").into_owned()
}

fn mask(mut value: Value) -> Value {
    if let Some(url) = value
        .pointer_mut("/auth/url")
        .and_then(|url| url.as_str().map(mask_url))
    {
        value["auth"]["url"] = json!(url);
    }
    value
}

fn masked(response: Response) -> Response {
    Response {
        body: mask(response.body.clone()),
        ..response
    }
}

/// Poll a login until `ready` holds.
async fn poll(api: &Api, id: &str, ready: impl Fn(&Value) -> bool) -> Value {
    let path = format!("/api/provider-auth/sessions/{id}");
    for _ in 0..400 {
        let view = api.send("GET", &path, &browser_headers(), None).await.body;
        if ready(&view) {
            return view;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    panic!("login {id} never got ready");
}

fn param(url: &str, name: &str) -> String {
    reqwest::Url::parse(url)
        .unwrap()
        .query_pairs()
        .find(|(key, _)| key == name)
        .map(|(_, value)| value.into_owned())
        .unwrap()
}

/// A request to a callback server: its status and the page's message.
async fn callback(url: &str) -> Value {
    let response = reqwest::Client::builder()
        .no_proxy()
        .build()
        .unwrap()
        .get(url)
        .send()
        .await
        .unwrap();
    let status = response.status().as_u16();
    let content_type = response
        .headers()
        .get("content-type")
        .map(|v| v.to_str().unwrap().to_owned());
    let page = response.text().await.unwrap();
    let text = |pattern: &str| {
        Regex::new(pattern)
            .unwrap()
            .captures(&page)
            .map(|captures| captures[1].to_owned())
    };
    json!({ "status": status, "contentType": content_type,
        "title": text(r"<title>([^<]*)</title>"), "message": text(r"<p>([^<]*)</p>"),
        "details": text(r#"<div class="details">([^<]*)</div>"#) })
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn provider_auth() {
    let Some(cluster) = Cluster::start_with(GatewayOptions {
        without_node: true,
        ..GatewayOptions::default()
    })
    .await
    else {
        return;
    };
    let api = cluster.api();
    let headers = browser_headers();
    let mut t = Transcript::new(cluster.volatile());
    macro_rules! call {
        ($step:expr, $method:expr, $path:expr, $body:expr) => {{
            let path = String::from($path);
            let response = masked(api.send($method, &path, &headers, $body).await);
            t.response($step, &format!("{} {path}", $method), &response);
            response
        }};
    }

    // ---- Anthropic: PKCE with a pasted callback URL ----
    let started = call!(
        "start an Anthropic login",
        "POST",
        "/api/provider-auth/sessions",
        Some(json!({ "providerId": "anthropic" }))
    );
    let id = started.body["id"].as_str().unwrap().to_owned();
    let session = format!("/api/provider-auth/sessions/{id}");
    let view = poll(&api, &id, |view| {
        view["prompts"].as_array().is_some_and(|p| p.len() == 1)
    })
    .await;
    t.note(
        "the login waits for the pasted callback URL",
        mask(view.clone()),
    );
    let url = view["auth"]["url"].as_str().unwrap().to_owned();
    let (redirect, state) = (param(&url, "redirect_uri"), param(&url, "state"));
    let prompt = view["prompts"][0]["id"].as_str().unwrap().to_owned();
    call!(
        "a second Anthropic login",
        "POST",
        "/api/provider-auth/sessions",
        Some(json!({ "providerId": "anthropic" }))
    );
    for (step, value) in [
        ("paste a bare code", json!("the-code")),
        (
            "paste another state",
            json!(format!("{redirect}?code=c&state=other")),
        ),
        ("paste no code", json!(format!("{redirect}?state={state}"))),
        (
            "paste two codes",
            json!(format!("{redirect}?code=a&code=b&state={state}")),
        ),
        (
            "paste another host",
            json!(format!(
                "http://127.0.0.1:53692/callback?code=c&state={state}"
            )),
        ),
        (
            "paste another path",
            json!(format!("http://localhost:53692/other?code=c&state={state}")),
        ),
        (
            "paste with a fragment",
            json!(format!("{redirect}?code=c&state={state}#x")),
        ),
        ("paste nothing", json!("   ")),
    ] {
        call!(
            step,
            "POST",
            format!("{session}/input"),
            Some(json!({ "promptId": prompt, "value": value }))
        );
    }
    call!(
        "answer without a value",
        "POST",
        format!("{session}/input"),
        Some(json!({ "promptId": prompt }))
    );
    call!(
        "answer an unknown prompt",
        "POST",
        format!("{session}/input"),
        Some(json!({ "promptId": "nope", "value": "x" }))
    );

    // The browser lands on the callback server when it runs on this machine.
    let port_url = "http://127.0.0.1:53692";
    t.note(
        "the callback server: another state",
        callback(&format!("{port_url}/callback?code=c&state=other")).await,
    );
    t.note(
        "the callback server: no code",
        callback(&format!("{port_url}/callback?state={state}")).await,
    );
    t.note(
        "the callback server: an error from Anthropic",
        callback(&format!("{port_url}/callback?error=access_denied")).await,
    );
    t.note(
        "the callback server: another path",
        callback(&format!("{port_url}/elsewhere")).await,
    );
    call!("still pending", "GET", session.clone(), None);
    call!("cancel it", "DELETE", session.clone(), None);
    call!(
        "answer after cancelling",
        "POST",
        format!("{session}/input"),
        Some(json!({ "promptId": prompt, "value": format!("{redirect}?code=c&state={state}") }))
    );
    call!("cancel it again", "DELETE", session.clone(), None);
    call!("its status", "GET", session.clone(), None);

    // ---- Codex: the same flow with its own state ----
    let started = call!(
        "start a Codex login",
        "POST",
        "/api/provider-auth/sessions",
        Some(json!({ "providerId": "openai-codex", "policyConsent": true }))
    );
    let codex = started.body["id"].as_str().unwrap().to_owned();
    let view = poll(&api, &codex, |view| {
        view["prompts"].as_array().is_some_and(|p| p.len() == 1)
    })
    .await;
    t.note("the Codex login", mask(view.clone()));
    let url = view["auth"]["url"].as_str().unwrap().to_owned();
    let state = param(&url, "state");
    t.note(
        "the Codex callback server: another state",
        callback("http://127.0.0.1:1455/auth/callback?code=c&state=other").await,
    );
    t.note(
        "the Codex callback server: no code",
        callback(&format!(
            "http://127.0.0.1:1455/auth/callback?state={state}"
        ))
        .await,
    );
    let prompt = view["prompts"][0]["id"].as_str().unwrap().to_owned();
    call!(
        "paste the Anthropic callback into Codex",
        "POST",
        format!("/api/provider-auth/sessions/{codex}/input"),
        Some(json!({ "promptId": prompt,
            "value": format!("http://localhost:53692/callback?code=c&state={state}") }))
    );
    // Signing out of an account cancels its login.
    call!(
        "sign out of Codex during the login",
        "DELETE",
        "/api/providers/oauth:openai-codex",
        None
    );
    call!(
        "the Codex login after signing out",
        "GET",
        format!("/api/provider-auth/sessions/{codex}"),
        None
    );

    // ---- GitHub Copilot: the enterprise domain prompt ----
    let started = call!(
        "start a Copilot login",
        "POST",
        "/api/provider-auth/sessions",
        Some(json!({ "providerId": "github-copilot", "policyConsent": true }))
    );
    let copilot = started.body["id"].as_str().unwrap().to_owned();
    let view = poll(&api, &copilot, |view| {
        view["prompts"].as_array().is_some_and(|p| p.len() == 1)
    })
    .await;
    t.note("the Copilot login asks for a domain", view.clone());
    let prompt = view["prompts"][0]["id"].as_str().unwrap().to_owned();
    for (step, value) in [
        ("a domain with a path", "ghe.example/path"),
        ("a domain over HTTP", "http://ghe.example"),
        ("a domain with a port", "ghe.example:8443"),
        ("a domain with credentials", "https://u:p@ghe.example"),
        ("a domain with a query", "ghe.example?x=1"),
    ] {
        call!(
            step,
            "POST",
            format!("/api/provider-auth/sessions/{copilot}/input"),
            Some(json!({ "promptId": prompt, "value": value }))
        );
    }
    call!(
        "cancel the Copilot login",
        "DELETE",
        format!("/api/provider-auth/sessions/{copilot}"),
        None
    );
    call!("providers after the logins", "GET", "/api/providers", None);

    insta::assert_json_snapshot!("provider_auth", t.into_value());
}
