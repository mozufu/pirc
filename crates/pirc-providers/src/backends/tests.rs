//! Ported from `backend-auth.test.ts` and `backend-discovery.test.ts`
//! (the store, presets and probes; logins are tested with the OAuth flows).

use std::sync::atomic::AtomicUsize;

use super::*;

const SECRET: &str = "fake-secret-token";

fn baseline() -> Models {
    serde_json::from_value(json!({
        "providers": { "file": {
            "api": "openai-chat", "baseUrl": "https://file-backend.example/v1",
            "apiKey": "file-secret", "headers": { "authorization": "file-header-secret" },
            "compat": {}, "models": [{ "id": "file-model", "contextWindow": 1000,
                "maxTokens": 100, "reasoning": false, "input": ["text"], "compat": {} }],
        } },
        "defaultModel": { "provider": "file", "id": "file-model" },
    }))
    .unwrap()
}

fn service(dir: &Path) -> (Arc<BackendService>, Arc<AtomicUsize>) {
    service_with(dir, BackendOptions::default())
}

fn service_with(dir: &Path, options: BackendOptions) -> (Arc<BackendService>, Arc<AtomicUsize>) {
    let service = BackendService::open_with(dir, baseline(), options).unwrap();
    let changes = Arc::new(AtomicUsize::new(0));
    let counter = changes.clone();
    service.set_on_change(move || {
        counter.fetch_add(1, Ordering::SeqCst);
    });
    (service, changes)
}

async fn resolve(service: &BackendService, provider: &str, model: &str) -> Resolved {
    service.resolve(provider, model).await.unwrap()
}

#[tokio::test]
async fn persists_ui_backends_privately_and_keys_are_write_only() {
    let dir = tempfile::tempdir().unwrap();
    let (backends, changes) = service(dir.path());
    let lan = |key: Option<&str>| {
        let mut body = json!({ "api": "openai-completions", "baseUrl": "http://192.168.1.5:8080/v1",
            "models": [{ "id": "local-model" }] });
        if let Some(key) = key {
            body["apiKey"] = json!(key);
        }
        body
    };
    backends
        .save_provider("lan", &lan(Some("ui-secret")), true)
        .unwrap();
    let model = json!({ "api": "openai-chat", "baseUrl": "https://x.example",
        "models": [{ "id": "m" }] });
    assert_eq!(
        backends.save_provider("file", &model, true).unwrap_err(),
        conflict("File-managed backends are read-only")
    );
    let mut credentials = model.clone();
    credentials["baseUrl"] = json!("https://u:p@x.example");
    assert_eq!(
        backends
            .save_provider("bad", &credentials, true)
            .unwrap_err(),
        invalid_settings()
    );
    let mut command = model.clone();
    command["apiKeyCommand"] = json!(["cat"]);
    assert!(backends.save_provider("cmd", &command, true).is_err());
    assert_eq!(
        backends.save_provider("lan", &model, true).unwrap_err(),
        conflict("Backend ID already exists")
    );
    assert_eq!(
        backends.save_provider("nope", &model, false).unwrap_err(),
        not_found()
    );
    assert_eq!(
        backends
            .save_provider("default-model", &model, true)
            .unwrap_err(),
        invalid("Invalid backend ID")
    );
    // Omitting the key keeps it; an empty string clears it.
    backends.save_provider("lan", &lan(None), false).unwrap();
    assert_eq!(
        resolve(&backends, "lan", "local-model")
            .await
            .api_key
            .as_deref(),
        Some("ui-secret")
    );
    let file = dir.path().join("backends/settings.json");
    let mode = |path: &Path| fs::metadata(path).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode(&file), 0o600);
    assert_eq!(mode(file.parent().unwrap()), 0o700);
    let snapshot = backends.snapshot();
    assert!(!snapshot.to_string().contains("ui-secret"));
    let view = snapshot["providers"]
        .as_array()
        .unwrap()
        .iter()
        .find(|p| p["id"] == "lan")
        .unwrap()
        .clone();
    assert_eq!(view["source"], "ui");
    assert_eq!(view["hasApiKey"], true);
    assert_eq!(view["baseUrl"], "http://192.168.1.5:8080/v1");
    backends
        .save_provider("lan", &lan(Some("")), false)
        .unwrap();
    assert_eq!(resolve(&backends, "lan", "local-model").await.api_key, None);
    backends
        .set_default(&json!({ "provider": "lan", "id": "local-model" }))
        .unwrap();
    assert_eq!(
        backends.models().default_model.unwrap().provider,
        "lan".to_owned()
    );
    assert_eq!(changes.load(Ordering::SeqCst), 4);
    assert_eq!(
        backends
            .set_default(&json!({ "provider": "lan", "id": "other" }))
            .unwrap_err(),
        invalid("Model is not configured")
    );
    assert_eq!(
        backends
            .set_default(&json!({ "provider": "lan", "id": "local-model", "x": 1 }))
            .unwrap_err(),
        invalid_settings()
    );
    // Survives a restart; deleting a backend drops a default that pointed to it.
    drop(backends);
    let (reopened, _) = service(dir.path());
    assert_eq!(
        reopened.models().default_model.unwrap().provider,
        "lan".to_owned()
    );
    reopened.delete_provider("lan").unwrap();
    assert_eq!(reopened.models().default_model, baseline().default_model);
    assert!(!fs::read_to_string(&file).unwrap().contains("lan"));
    assert_eq!(reopened.delete_provider("lan").unwrap_err(), not_found());
    assert_eq!(
        reopened.delete_provider("file").unwrap_err(),
        conflict("File-managed backends are read-only")
    );
    assert_eq!(
        reopened.delete_provider("oauth:nope").unwrap_err(),
        not_found()
    );
    reopened.delete_provider("oauth:anthropic").unwrap();
    // No temporary files are left behind.
    let names: Vec<_> = fs::read_dir(file.parent().unwrap())
        .unwrap()
        .map(|entry| entry.unwrap().file_name())
        .collect();
    assert_eq!(names, ["settings.json"]);
}

#[tokio::test]
async fn keeps_opencode_go_and_the_saved_key_across_restarts() {
    let dir = tempfile::tempdir().unwrap();
    let (backends, _) = service(dir.path());
    let input = json!({ "api": "openai-completions", "baseUrl": "https://proxy.example/v1",
        "models": [{ "id": "glm" }], "opencodeGo": true });
    let mut with_key = input.clone();
    with_key["apiKey"] = json!(SECRET);
    backends.save_provider("go", &with_key, true).unwrap();
    assert_eq!(backends.snapshot()["providers"][0]["opencodeGo"], true);
    drop(backends);
    let (reopened, _) = service(dir.path());
    assert_eq!(
        resolve(&reopened, "go", "glm").await.provider.opencode_go,
        Some(true)
    );
    let mut off = input;
    off["opencodeGo"] = json!(false);
    reopened.save_provider("go", &off, false).unwrap();
    let resolved = resolve(&reopened, "go", "glm").await;
    assert_eq!(resolved.provider.opencode_go, Some(false));
    assert_eq!(resolved.api_key.as_deref(), Some(SECRET));
}

#[test]
fn lists_every_login_without_leaking_file_credentials() {
    let dir = tempfile::tempdir().unwrap();
    let (backends, _) = service(dir.path());
    let snapshot = backends.snapshot();
    let ids: Vec<_> = snapshot["oauthProviders"]
        .as_array()
        .unwrap()
        .iter()
        .map(|p| p["id"].as_str().unwrap())
        .collect();
    assert_eq!(ids, ["anthropic", "github-copilot", "openai-codex"]);
    assert_eq!(snapshot["oauthProviders"][1]["requiresPolicyConsent"], true);
    assert_eq!(snapshot["oauthProviders"][1]["usesCallbackServer"], false);
    let providers = snapshot["providers"].as_array().unwrap();
    assert_eq!(providers.len(), 1);
    assert_eq!(providers[0]["source"], "file");
    assert_eq!(providers[0]["readOnly"], true);
    assert_eq!(providers[0]["hasApiKey"], true);
    assert!(providers[0].get("baseUrl").is_none());
    let text = format!(
        "{snapshot}{}",
        serde_json::to_string(&backends.models()).unwrap()
    );
    for secret in ["file-secret", "file-header-secret", "file-backend.example"] {
        assert!(!text.contains(secret), "{secret}");
    }
}

#[tokio::test]
async fn saving_from_a_preset_keeps_catalog_metadata_gateway_side() {
    let dir = tempfile::tempdir().unwrap();
    let (backends, _) = service(dir.path());
    let known = "deepseek/deepseek-v4-flash";
    backends
        .save_provider(
            "router",
            &json!({ "api": "openai-completions", "baseUrl": "https://openrouter.ai/api/v1",
                "apiKey": SECRET, "preset": "openrouter",
                "models": [{ "id": known }, { "id": "vendor/custom" }] }),
            true,
        )
        .unwrap();
    let resolved = resolve(&backends, "router", known).await;
    assert_eq!(resolved.provider.pi_provider.as_deref(), Some("openrouter"));
    assert_eq!(resolved.model.compat["thinkingFormat"], "openrouter");
    assert!(resolved.model.thinking_level_map.is_some());
    assert!(
        resolve(&backends, "router", "vendor/custom")
            .await
            .model
            .compat
            .is_empty()
    );
    let snapshot = backends.snapshot();
    assert_eq!(snapshot["providers"][0]["preset"], "openrouter");
    assert!(!snapshot.to_string().contains("thinkingFormat"));
    assert!(!snapshot.to_string().contains(SECRET));
    // Editing without the preset drops the catalog metadata.
    backends
        .save_provider(
            "router",
            &json!({ "api": "openai-completions", "baseUrl": "https://openrouter.ai/api/v1",
                "models": [{ "id": known }] }),
            false,
        )
        .unwrap();
    let plain = resolve(&backends, "router", known).await;
    assert_eq!(plain.provider.pi_provider, None);
    assert!(plain.model.compat.is_empty());
    assert_eq!(plain.api_key.as_deref(), Some(SECRET));
    for preset in ["ollama", "github-copilot", "nope"] {
        let body = json!({ "api": "openai-completions", "baseUrl": "https://a.example",
            "preset": preset, "models": [{ "id": "m" }] });
        assert_eq!(
            backends
                .save_provider(&format!("x-{preset}"), &body, true)
                .unwrap_err(),
            invalid("Unknown backend preset"),
            "{preset}"
        );
    }
    let mismatch = json!({ "api": "anthropic-messages", "baseUrl": "https://a.example",
        "preset": "openrouter", "models": [{ "id": "m" }] });
    assert_eq!(
        backends
            .save_provider("mismatch", &mismatch, true)
            .unwrap_err(),
        invalid("Unknown backend preset")
    );
}

#[tokio::test]
async fn file_providers_win_and_baseline_reloads_notify() {
    let dir = tempfile::tempdir().unwrap();
    let (backends, changes) = service(dir.path());
    backends
        .save_provider(
            "later",
            &json!({ "api": "openai-completions", "baseUrl": "https://ui.example",
                "apiKey": "ui-key", "models": [{ "id": "m" }] }),
            true,
        )
        .unwrap();
    let mut next = baseline();
    let mut shadow = next.providers["file"].clone();
    shadow.api_key = Some("file-key".to_owned());
    next.providers.insert("later".to_owned(), shadow);
    backends.set_baseline(next);
    assert_eq!(changes.load(Ordering::SeqCst), 2);
    let resolved = resolve(&backends, "later", "file-model").await;
    assert_eq!(resolved.api_key.as_deref(), Some("file-key"));
    let snapshot = backends.snapshot();
    let later = &snapshot["providers"][0];
    assert_eq!(
        (later["id"].as_str(), later["source"].as_str()),
        (Some("later"), Some("file"))
    );
    assert!(later.get("baseUrl").is_none());
    assert!(backends.resolve("oauth:anthropic", "m").await.is_err());
    backends.close();
    assert_eq!(
        backends.save_provider("x", &json!({}), true).unwrap_err(),
        closed_error()
    );
    assert!(backends.resolve("file", "file-model").await.is_err());
}

#[test]
fn refuses_unreadable_or_invalid_stores() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("backends/settings.json");
    fs::create_dir_all(file.parent().unwrap()).unwrap();
    for (text, error) in [
        ("{", "Cannot read backend credential store"),
        (
            r#"{"version":2,"providers":{},"oauth":{}}"#,
            "Cannot read backend credential store",
        ),
        (
            r#"{"version":1,"providers":{},"oauth":{},"extra":1}"#,
            "Cannot read backend credential store",
        ),
        (
            r#"{"version":1,"providers":{},"oauth":{"anthropic":{"access":"a"}}}"#,
            "Cannot read backend credential store",
        ),
        (
            r#"{"version":1,"providers":{"a":{"api":"openai-chat","baseUrl":"https://a","models":[]}},"oauth":{}}"#,
            "Cannot read backend credential store",
        ),
        (
            r#"{"version":1,"providers":{"a":{"api":"openai-chat","baseUrl":"nope","models":[{"id":"m"}]}},"oauth":{}}"#,
            "Cannot read backend credential store",
        ),
        (
            r#"{"version":1,"providers":{"bad id":{"api":"openai-chat","baseUrl":"https://a","models":[{"id":"m"}]}},"oauth":{}}"#,
            "Invalid backend credential store",
        ),
    ] {
        fs::write(&file, text).unwrap();
        assert_eq!(
            BackendService::open(dir.path(), baseline()).unwrap_err(),
            error,
            "{text}"
        );
    }
    fs::write(&file, r#"{"version":1,"oauth":{}}"#).unwrap();
    fs::set_permissions(&file, fs::Permissions::from_mode(0o644)).unwrap();
    BackendService::open(dir.path(), baseline()).unwrap();
    assert_eq!(
        fs::metadata(&file).unwrap().permissions().mode() & 0o777,
        0o600
    );
}

#[tokio::test]
async fn probes_reuse_only_the_edited_web_backend_key() {
    use axum::http::HeaderMap;
    use std::sync::Mutex as StdMutex;
    let seen = Arc::new(StdMutex::new(Vec::<Option<String>>::new()));
    let log = seen.clone();
    let app = axum::Router::new().route(
        "/models",
        axum::routing::get(move |headers: HeaderMap| {
            let log = log.clone();
            async move {
                log.lock().unwrap().push(
                    headers
                        .get("authorization")
                        .map(|v| v.to_str().unwrap().to_owned()),
                );
                json!({ "data": [{ "id": "z" }, { "id": "a" }] }).to_string()
            }
        }),
    );
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    tokio::spawn(async move { axum::serve(listener, app).await });

    let dir = tempfile::tempdir().unwrap();
    let (backends, _) = service(dir.path());
    backends
        .save_provider(
            "saved",
            &json!({ "api": "openai-completions", "baseUrl": base, "apiKey": SECRET,
                "models": [{ "id": "m" }] }),
            true,
        )
        .unwrap();
    let form = |extra: Value| {
        let mut body = json!({ "api": "openai-completions", "baseUrl": base });
        body.as_object_mut()
            .unwrap()
            .extend(extra.as_object().unwrap().clone());
        body
    };
    let models = backends
        .discover(&form(json!({ "backendId": "saved" })))
        .await
        .unwrap();
    let ids: Vec<_> = models.iter().map(|m| m.model.id.as_str()).collect();
    assert_eq!(ids, ["a", "z"]);
    for extra in [
        json!({ "backendId": "saved", "apiKey": "" }),
        json!({ "backendId": "saved", "apiKey": "typed" }),
        json!({ "backendId": "missing" }),
        json!({ "backendId": "file" }),
    ] {
        backends.discover(&form(extra)).await.unwrap();
    }
    assert_eq!(
        *seen.lock().unwrap(),
        [
            Some(format!("Bearer {SECRET}")),
            None,
            Some("Bearer typed".to_owned()),
            None,
            None,
        ]
    );
    assert_eq!(
        backends
            .discover(&form(json!({ "baseUrl": "ftp://a.example" })))
            .await
            .unwrap_err(),
        invalid_settings()
    );
}

/// A models endpoint that records the credential headers each request
/// carries, as `(path, authorization, x-api-key)`.
async fn credential_log_server() -> (String, Arc<std::sync::Mutex<Vec<SeenCredentials>>>) {
    use axum::http::{HeaderMap, Uri};
    let seen = Arc::new(std::sync::Mutex::new(Vec::<SeenCredentials>::new()));
    let log = seen.clone();
    let app = axum::Router::new().fallback(move |uri: Uri, headers: HeaderMap| {
        let log = log.clone();
        async move {
            let header = |name: &str| headers.get(name).map(|v| v.to_str().unwrap().to_owned());
            log.lock().unwrap().push((
                uri.path().to_owned(),
                header("authorization"),
                header("x-api-key"),
            ));
            json!({ "data": [{ "id": "a" }] }).to_string()
        }
    });
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    tokio::spawn(async move { axum::serve(listener, app).await });
    (base, seen)
}

type SeenCredentials = (String, Option<String>, Option<String>);

fn saved_for(backends: &BackendService, api: &str, base: &str) {
    let body = json!({ "api": api, "baseUrl": base, "apiKey": SECRET,
        "models": [{ "id": "m" }] });
    if backends.save_provider("saved", &body, true).is_err() {
        backends.save_provider("saved", &body, false).unwrap();
    }
}

fn reused(backends: &BackendService, api: &str, base: &str) -> Option<String> {
    let probe = parse(
        &json!({ "api": api, "baseUrl": base, "backendId": "saved" }),
        schema::probe,
    )
    .unwrap();
    backends.probe_key(&probe)
}

#[tokio::test]
async fn a_saved_key_is_not_sent_to_a_different_endpoint() {
    let (saved_base, saved_seen) = credential_log_server().await;
    let (other_base, other_seen) = credential_log_server().await;
    let dir = tempfile::tempdir().unwrap();
    let (backends, _) = service(dir.path());
    saved_for(&backends, "openai-completions", &saved_base);

    // A different base URL, no typed key: nothing credential-like is sent.
    backends
        .discover(&json!({ "api": "openai-completions", "baseUrl": other_base,
            "backendId": "saved" }))
        .await
        .unwrap();
    // The same URL but another wire API: the Anthropic header is not used either.
    backends
        .discover(&json!({ "api": "anthropic-messages", "baseUrl": saved_base,
            "backendId": "saved" }))
        .await
        .unwrap();
    assert_eq!(
        *other_seen.lock().unwrap(),
        [("/models".to_owned(), None, None)]
    );
    assert_eq!(
        *saved_seen.lock().unwrap(),
        [("/v1/models".to_owned(), None, None)]
    );

    // The same endpoint still reuses it, over the wire.
    backends
        .discover(&json!({ "api": "openai-completions", "baseUrl": saved_base,
            "backendId": "saved" }))
        .await
        .unwrap();
    assert_eq!(
        saved_seen.lock().unwrap().last().unwrap(),
        &("/models".to_owned(), Some(format!("Bearer {SECRET}")), None)
    );
}

#[test]
fn a_saved_key_is_reused_only_for_the_same_endpoint() {
    let dir = tempfile::tempdir().unwrap();
    let (backends, _) = service(dir.path());
    saved_for(
        &backends,
        "openai-completions",
        "http://Example.com:8080/v1",
    );
    let key = Some(SECRET.to_owned());
    // Equal, or equal after the crate's trailing-slash and URL-case rules.
    for base in [
        "http://example.com:8080/v1",
        "http://example.com:8080/v1/",
        "HTTP://EXAMPLE.COM:8080/v1",
    ] {
        assert_eq!(reused(&backends, "openai-completions", base), key, "{base}");
    }
    // Same host, different path, port, scheme or host; or a different wire API.
    for base in [
        "http://example.com:8080/v2",
        "http://example.com:8080",
        "http://example.com:8081/v1",
        "http://example.com/v1",
        "https://example.com:8080/v1",
        "http://example.org:8080/v1",
        "http://example.com:8080/V1",
    ] {
        assert_eq!(
            reused(&backends, "openai-completions", base),
            None,
            "{base}"
        );
    }
    assert_eq!(
        reused(&backends, "openai-chat", "http://example.com:8080/v1"),
        None
    );
    // Default ports are the same endpoint.
    saved_for(&backends, "openai-chat", "https://api.example.com");
    assert_eq!(
        reused(&backends, "openai-chat", "https://api.example.com:443/"),
        key
    );
}

#[tokio::test]
async fn discovery_refuses_redirects_and_never_echoes_bodies() {
    use axum::http::StatusCode;
    use axum::response::IntoResponse;
    use std::sync::Mutex as StdMutex;
    let reply = Arc::new(StdMutex::new(0u8));
    let state = reply.clone();
    let app = axum::Router::new().fallback(move || {
        let state = state.clone();
        async move {
            match *state.lock().unwrap() {
                0 => (StatusCode::UNAUTHORIZED, format!("bad key {SECRET}")).into_response(),
                1 => (StatusCode::FOUND, [("location", "https://evil.example")]).into_response(),
                2 => format!("<html>{SECRET}</html>").into_response(),
                3 => StatusCode::NOT_FOUND.into_response(),
                4 => StatusCode::TOO_MANY_REQUESTS.into_response(),
                6 => "\u{feff}{\"data\":[{\"id\":\"bom\"}]}".into_response(),
                _ => StatusCode::BAD_GATEWAY.into_response(),
            }
        }
    });
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    tokio::spawn(async move { axum::serve(listener, app).await });
    let dir = tempfile::tempdir().unwrap();
    let (backends, _) = service(dir.path());
    let mut messages = Vec::new();
    for step in 0..6u8 {
        *reply.lock().unwrap() = step;
        let error = backends
            .discover(&json!({ "api": "openai-chat", "baseUrl": base }))
            .await
            .unwrap_err();
        assert_eq!((error.status, error.code), (502, "node_error"));
        messages.push(error.message);
    }
    assert_eq!(
        messages,
        [
            "The endpoint rejected the API key (HTTP 401). Check the key and try again.",
            "The endpoint redirected the request. Use the final base URL.",
            "The endpoint returned an unrecognized model list.",
            "This endpoint does not list its models (HTTP 404). Add model IDs manually.",
            "The endpoint is rate limiting requests (HTTP 429). Try again later.",
            "The endpoint returned HTTP 502 when listing models.",
        ]
    );
    *reply.lock().unwrap() = 6;
    let listed = backends
        .discover(&json!({ "api": "openai-chat", "baseUrl": base }))
        .await
        .unwrap();
    assert_eq!(listed[0].model.id, "bom");
    let closed = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let unreachable = format!("http://{}", closed.local_addr().unwrap());
    drop(closed);
    let error = backends
        .discover(&json!({ "api": "anthropic-messages", "baseUrl": unreachable }))
        .await
        .unwrap_err();
    assert_eq!(
        error.message,
        "Cannot reach the endpoint from the gateway. Check the base URL."
    );
}

#[tokio::test]
async fn probes_are_limited_to_four_at_a_time() {
    let dir = tempfile::tempdir().unwrap();
    let (backends, _) = service(dir.path());
    let slots: Vec<_> = (0..4).map(|_| backends.start_probe().unwrap()).collect();
    assert_eq!(backends.start_probe().err().unwrap().status, 429);
    drop(slots);
    assert!(backends.start_probe().is_ok());
}

// ---- subscription logins (`backend-auth.test.ts`) ----

type LoginFn =
    dyn Fn(String, Arc<dyn LoginHooks>) -> BoxFuture<Result<Credentials, String>> + Send + Sync;
type RefreshFn =
    dyn Fn(String, Credentials) -> BoxFuture<Result<Credentials, String>> + Send + Sync;

struct FakeRunner {
    login: Box<LoginFn>,
    refresh: Box<RefreshFn>,
}

impl OAuthRunner for FakeRunner {
    fn login(
        &self,
        provider: String,
        hooks: Arc<dyn LoginHooks>,
    ) -> BoxFuture<Result<Credentials, String>> {
        (self.login)(provider, hooks)
    }
    fn refresh(
        &self,
        provider: String,
        credentials: Credentials,
    ) -> BoxFuture<Result<Credentials, String>> {
        (self.refresh)(provider, credentials)
    }
}

fn runner(
    login: impl Fn(String, Arc<dyn LoginHooks>) -> BoxFuture<Result<Credentials, String>>
    + Send
    + Sync
    + 'static,
) -> BackendOptions {
    runner_with(login, |_, credentials| {
        Box::pin(async move { Ok(credentials) })
    })
}

fn runner_with(
    login: impl Fn(String, Arc<dyn LoginHooks>) -> BoxFuture<Result<Credentials, String>>
    + Send
    + Sync
    + 'static,
    refresh: impl Fn(String, Credentials) -> BoxFuture<Result<Credentials, String>>
    + Send
    + Sync
    + 'static,
) -> BackendOptions {
    BackendOptions {
        runner: Some(Arc::new(FakeRunner {
            login: Box::new(login),
            refresh: Box::new(refresh),
        })),
        ..BackendOptions::default()
    }
}

fn creds(access: &str, expires: f64) -> Credentials {
    json!({ "access": access, "refresh": "refresh-secret", "expires": expires })
        .as_object()
        .unwrap()
        .clone()
}

fn later() -> f64 {
    crate::stream::now_ms() as f64 + 3_600_000.0
}

async fn until(check: impl Fn() -> bool) {
    for _ in 0..400 {
        if check() {
            return;
        }
        tokio::time::sleep(std::time::Duration::from_millis(5)).await;
    }
    assert!(check(), "condition not reached");
}

const CALLBACK: &str = "http://localhost:1455/auth/callback?code=the-code&state=abc";

/// A Codex-style flow: authorization URL, then a pasted callback URL,
/// optionally held until `hold` is notified.
fn callback_runner(hold: Option<Arc<tokio::sync::Notify>>) -> BackendOptions {
    runner(move |_, hooks| {
        let hold = hold.clone();
        Box::pin(async move {
            hooks.on_auth(
                "https://auth.example/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback&state=abc",
                Some(&format!("Sign in Bearer {SECRET}")),
            )?;
            let input = hooks.manual().await?;
            assert!(input.contains("code=the-code"));
            if let Some(hold) = hold {
                hold.notified().await;
            }
            Ok(creds(SECRET, later()))
        })
    })
}

fn connected(backends: &BackendService, id: &str) -> bool {
    backends.snapshot()["oauthProviders"]
        .as_array()
        .unwrap()
        .iter()
        .any(|p| p["id"] == id && p["connected"] == true)
}

#[tokio::test]
async fn completes_a_login_from_a_pasted_callback_url() {
    let dir = tempfile::tempdir().unwrap();
    let (backends, changes) = service_with(dir.path(), callback_runner(None));
    let view = backends.start_auth("me", "openai-codex", false).unwrap();
    assert_eq!(view["status"], "pending");
    let id = view["id"].as_str().unwrap().to_owned();
    let status = || backends.auth_status("me", &id).unwrap();
    until(|| status()["prompts"].as_array().unwrap().len() == 1).await;
    let view = status();
    assert!(
        view["auth"]["url"]
            .as_str()
            .unwrap()
            .starts_with("https://auth.example/")
    );
    assert!(
        !view["auth"]["instructions"]
            .as_str()
            .unwrap()
            .contains(SECRET)
    );
    let prompt = view["prompts"][0].clone();
    assert_eq!(prompt["kind"], "manual");
    let prompt_id = prompt["id"].as_str().unwrap();
    for bad in [
        "the-code",
        "http://localhost:1455/auth/callback?code=x&state=other",
        "http://evil.example:1455/auth/callback?code=x&state=abc",
    ] {
        let error = backends
            .auth_input("me", &id, prompt_id, Some(bad))
            .unwrap_err();
        assert!(error.message.contains("callback URL"), "{bad}");
    }
    assert_eq!(
        backends.auth_input("me", &id, prompt_id, None).unwrap_err(),
        invalid("A response is required")
    );
    assert_eq!(
        backends.auth_status("someone-else", &id).unwrap_err(),
        not_found()
    );
    backends
        .auth_input("me", &id, prompt_id, Some(CALLBACK))
        .unwrap();
    until(|| status()["status"] == "succeeded").await;
    assert_eq!(changes.load(Ordering::SeqCst), 1);
    assert_eq!(
        backends
            .auth_input("me", &id, prompt_id, Some(CALLBACK))
            .unwrap_err(),
        conflict("Authorization session is no longer pending")
    );
    let model = &crate::catalog::catalog_models("openai-codex")[0];
    let resolved = resolve(&backends, "oauth:openai-codex", &model.id).await;
    assert_eq!(resolved.api_key.as_deref(), Some(SECRET));
    assert_eq!(
        resolved.provider.pi_provider.as_deref(),
        Some("openai-codex")
    );
    assert_eq!(
        resolved.model.api,
        Some(pirc_protocol::ModelApi::OpenaiCodexResponses)
    );
    let published = format!(
        "{}{}",
        serde_json::to_string(&backends.models()).unwrap(),
        backends.snapshot()
    );
    for secret in [SECRET, "refresh-secret", "chatgpt.com"] {
        assert!(!published.contains(secret), "{secret}");
    }
    assert!(connected(&backends, "openai-codex"));
    assert!(
        backends.snapshot()["providers"]
            .as_array()
            .unwrap()
            .iter()
            .any(|p| p["id"] == "oauth:openai-codex"
                && p["source"] == "oauth"
                && p["hasApiKey"] == true)
    );
    // A second login of the same provider waits for the first to end.
    let second = backends.start_auth("me", "openai-codex", false).unwrap();
    assert_eq!(
        backends
            .start_auth("me", "openai-codex", false)
            .unwrap_err(),
        conflict("A login for this provider is already in progress")
    );
    backends
        .cancel_auth("me", second["id"].as_str().unwrap())
        .unwrap();
}

#[tokio::test]
async fn copilot_needs_consent_and_checks_its_domain_prompt() {
    let dir = tempfile::tempdir().unwrap();
    let (backends, _) = service_with(
        dir.path(),
        runner(|_, hooks| {
            Box::pin(async move {
                let domain = hooks
                    .prompt(Prompt {
                        message: "Enterprise domain".to_owned(),
                        placeholder: None,
                        allow_empty: Some(true),
                    })
                    .await?;
                hooks.on_auth(
                    "https://github.com/login/device",
                    Some("Enter code: AB12-CD34"),
                )?;
                let hold = hooks
                    .prompt(Prompt {
                        message: "Hold".to_owned(),
                        placeholder: None,
                        allow_empty: None,
                    })
                    .await?;
                let domain = if domain.is_empty() {
                    "none".to_owned()
                } else {
                    domain
                };
                Ok(creds(&format!("{domain}-{hold}"), later()))
            })
        }),
    );
    assert!(
        backends
            .start_auth("me", "github-copilot", false)
            .unwrap_err()
            .message
            .contains("consent")
    );
    let id = backends.start_auth("me", "github-copilot", true).unwrap()["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let status = || backends.auth_status("me", &id).unwrap();
    until(|| status()["prompts"].as_array().unwrap().len() == 1).await;
    let prompt = status()["prompts"][0]["id"].as_str().unwrap().to_owned();
    assert_eq!(status()["prompts"][0]["allowEmpty"], true);
    let error = backends
        .auth_input("me", &id, &prompt, Some("https://ghe.example/path"))
        .unwrap_err();
    assert!(error.message.contains("Enterprise"));
    backends.auth_input("me", &id, &prompt, Some("")).unwrap();
    until(|| status()["prompts"][0]["message"] == "Hold").await;
    // The device-flow user code is shown apart from the instructions.
    assert_eq!(
        status()["auth"],
        json!({ "url": "https://github.com/login/device",
            "instructions": "Enter code: AB12-CD34", "userCode": "AB12-CD34" })
    );
    let hold = status()["prompts"][0]["id"].as_str().unwrap().to_owned();
    assert_eq!(
        backends
            .auth_input("me", &id, &hold, Some("  "))
            .unwrap_err(),
        invalid("A response is required")
    );
    backends.auth_input("me", &id, &hold, Some("b")).unwrap();
    until(|| status()["status"] == "succeeded").await;
    let model = &crate::catalog::catalog_models("github-copilot")[0];
    let resolved = resolve(&backends, "oauth:github-copilot", &model.id).await;
    assert_eq!(resolved.api_key.as_deref(), Some("none-b"));
}

#[tokio::test]
async fn unsafe_authorization_pages_and_bad_credentials_fail_the_login() {
    let dir = tempfile::tempdir().unwrap();
    let (backends, _) = service_with(
        dir.path(),
        runner(|provider, hooks| {
            Box::pin(async move {
                if provider == "anthropic" {
                    hooks.on_auth("http://insecure.example/authorize", None)?;
                }
                Ok(Credentials::new())
            })
        }),
    );
    for provider in ["anthropic", "openai-codex"] {
        let id = backends.start_auth("me", provider, false).unwrap()["id"]
            .as_str()
            .unwrap()
            .to_owned();
        until(|| backends.auth_status("me", &id).unwrap()["status"] == "failed").await;
        assert_eq!(
            backends.auth_status("me", &id).unwrap()["error"],
            "Authorization failed. Please retry."
        );
        assert!(!connected(&backends, provider));
    }
}

#[tokio::test]
async fn cancellation_wins_over_a_late_login() {
    let dir = tempfile::tempdir().unwrap();
    let hold = Arc::new(tokio::sync::Notify::new());
    let (backends, _) = service_with(dir.path(), callback_runner(Some(hold.clone())));
    let id = backends.start_auth("me", "openai-codex", false).unwrap()["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let status = || backends.auth_status("me", &id).unwrap();
    until(|| status()["prompts"].as_array().unwrap().len() == 1).await;
    let prompt = status()["prompts"][0]["id"].as_str().unwrap().to_owned();
    backends
        .auth_input("me", &id, &prompt, Some(CALLBACK))
        .unwrap();
    assert_eq!(
        backends.cancel_auth("me", &id).unwrap()["status"],
        "cancelled"
    );
    hold.notify_waiters();
    tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    assert!(!connected(&backends, "openai-codex"));
    assert!(backends.resolve("oauth:openai-codex", "x").await.is_err());
    // A cancelled view keeps no prompts or links.
    let view = status();
    assert!(view.get("auth").is_none());
    assert!(view["prompts"].as_array().unwrap().is_empty());
}

#[tokio::test]
async fn logins_expire() {
    let dir = tempfile::tempdir().unwrap();
    let mut options = runner(|_, hooks| {
        Box::pin(async move {
            hooks.manual().await?;
            Err("unused".to_owned())
        })
    });
    options.session_timeout = std::time::Duration::from_millis(30);
    let (backends, _) = service_with(dir.path(), options);
    let id = backends.start_auth("me", "anthropic", false).unwrap()["id"]
        .as_str()
        .unwrap()
        .to_owned();
    until(|| backends.auth_status("me", &id).unwrap()["status"] == "expired").await;
}

#[tokio::test]
async fn refreshes_once_for_concurrent_requests_and_sign_out_discards_it() {
    let dir = tempfile::tempdir().unwrap();
    let refreshes = Arc::new(AtomicUsize::new(0));
    let gate = Arc::new(tokio::sync::Semaphore::new(1));
    let (counter, gated) = (refreshes.clone(), gate.clone());
    let (backends, changes) = service_with(
        dir.path(),
        runner_with(
            |_, _| Box::pin(async { Ok(creds("old", 0.0)) }),
            move |_, mut credentials| {
                let n = counter.fetch_add(1, Ordering::SeqCst) + 1;
                let gate = gated.clone();
                Box::pin(async move {
                    let _permit = gate.acquire().await.unwrap();
                    credentials.insert("access".to_owned(), json!(format!("new-{n}")));
                    credentials.insert("expires".to_owned(), json!(later()));
                    Ok(credentials)
                })
            },
        ),
    );
    let id = backends.start_auth("me", "anthropic", false).unwrap()["id"]
        .as_str()
        .unwrap()
        .to_owned();
    until(|| backends.auth_status("me", &id).unwrap()["status"] == "succeeded").await;
    let model = crate::catalog::catalog_models("anthropic")[0].id.clone();
    let (a, b) = tokio::join!(
        backends.resolve("oauth:anthropic", &model),
        backends.resolve("oauth:anthropic", &model)
    );
    assert_eq!(a.unwrap().api_key.as_deref(), Some("new-1"));
    assert_eq!(b.unwrap().api_key.as_deref(), Some("new-1"));
    assert_eq!(refreshes.load(Ordering::SeqCst), 1);
    // Refreshes are saved without a change notification.
    assert_eq!(changes.load(Ordering::SeqCst), 1);
    let file = dir.path().join("backends/settings.json");
    assert!(fs::read_to_string(&file).unwrap().contains("new-1"));

    // Force another refresh, then sign out while it is still running.
    {
        let mut inner = backends.lock();
        let mut next = inner.state.clone();
        next.oauth["anthropic"].insert("expires".to_owned(), json!(0));
        backends.commit(&mut inner, next).unwrap();
    }
    let permit = gate.clone().acquire_owned().await.unwrap();
    let pending = {
        let backends = backends.clone();
        let model = model.clone();
        tokio::spawn(async move { backends.resolve("oauth:anthropic", &model).await })
    };
    until(|| refreshes.load(Ordering::SeqCst) == 2).await;
    backends.delete_provider("oauth:anthropic").unwrap();
    drop(permit);
    let error = pending.await.unwrap().err().unwrap();
    assert!(error.contains("sign in again"), "{error}");
    assert!(!connected(&backends, "anthropic"));
    tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    assert!(!fs::read_to_string(&file).unwrap().contains("new-2"));
}

#[tokio::test]
async fn closing_cancels_logins() {
    let dir = tempfile::tempdir().unwrap();
    let (backends, _) = service_with(dir.path(), callback_runner(None));
    let id = backends.start_auth("me", "openai-codex", false).unwrap()["id"]
        .as_str()
        .unwrap()
        .to_owned();
    backends.close();
    assert_eq!(
        backends.auth_status("me", &id).unwrap()["status"],
        "cancelled"
    );
    assert_eq!(
        backends.start_auth("me", "anthropic", false).unwrap_err(),
        closed_error()
    );
}

#[tokio::test]
async fn a_refresh_with_rotated_credentials_returns_the_saved_ones() {
    let dir = tempfile::tempdir().unwrap();
    let refreshes = Arc::new(AtomicUsize::new(0));
    let counter = refreshes.clone();
    let (backends, _) = service_with(
        dir.path(),
        runner_with(
            |_, _| Box::pin(async { Ok(creds("fresh", later())) }),
            move |_, credentials| {
                counter.fetch_add(1, Ordering::SeqCst);
                Box::pin(async move { Ok(credentials) })
            },
        ),
    );
    let id = backends.start_auth("me", "anthropic", false).unwrap()["id"]
        .as_str()
        .unwrap()
        .to_owned();
    until(|| backends.auth_status("me", &id).unwrap()["status"] == "succeeded").await;
    // Credentials read before another refresh rotated them.
    let stale = creds("stale", 0.0);
    let saved = backends.refresh("anthropic", stale).await.unwrap();
    assert_eq!(saved["access"], "fresh");
    assert_eq!(refreshes.load(Ordering::SeqCst), 0);
    backends.close();
    assert!(backends.refresh("anthropic", saved).await.is_err());
}

#[tokio::test]
async fn opencode_presets_persist_native_model_routes_and_keep_custom_endpoints() {
    use pirc_protocol::ModelApi;
    let dir = tempfile::tempdir().unwrap();
    let (backends, _) = service(dir.path());
    let cases = [
        (
            "deepseek-v4.1-flash",
            ModelApi::OpenaiCompletions,
            "openai/v1",
        ),
        ("gpt-6-luna", ModelApi::OpenaiResponses, "openai/v1"),
        ("claude-haiku-5-5", ModelApi::AnthropicMessages, "anthropic"),
    ];
    for preset_id in ["opencode", "opencode-go"] {
        let preset = backends
            .presets()
            .iter()
            .find(|p| p.id == preset_id)
            .unwrap();
        let models: Vec<_> = cases
            .iter()
            .map(|(id, _, _)| {
                preset
                    .models
                    .iter()
                    .find(|m| m.id == *id)
                    .unwrap()
                    .to_json()
            })
            .collect();
        let mut body = json!({ "api": preset.api, "baseUrl": format!("{}/", preset.base_url),
            "preset": preset_id, "apiKey": SECRET, "models": models });
        backends.save_provider(preset_id, &body, true).unwrap();
        for (id, api, suffix) in cases {
            let resolved = resolve(&backends, preset_id, id).await;
            assert_eq!(resolved.model.api, Some(api));
            let plan = if preset_id == "opencode-go" {
                "/go"
            } else {
                ""
            };
            assert_eq!(
                resolved.model.base_url.as_deref(),
                Some(format!("https://opencode.ai/inference{plan}/{suffix}").as_str())
            );
            assert_eq!(resolved.api_key.as_deref(), Some(SECRET));
        }
        body["baseUrl"] = json!("https://proxy.example/custom/v1");
        let proxy_id = format!("{preset_id}-proxy");
        backends.save_provider(&proxy_id, &body, true).unwrap();
        for (id, _, _) in cases {
            let resolved = resolve(&backends, &proxy_id, id).await;
            assert_eq!(resolved.model.api, None);
            assert_eq!(resolved.model.base_url, None);
            assert_eq!(
                resolved.provider.base_url,
                "https://proxy.example/custom/v1"
            );
        }
        body["baseUrl"] = json!(if preset_id == "opencode-go" {
            "https://opencode.ai/zen/go/v1"
        } else {
            "https://opencode.ai/zen/v1"
        });
        let legacy_id = format!("{preset_id}-legacy");
        backends.save_provider(&legacy_id, &body, true).unwrap();
        assert_eq!(
            resolve(&backends, &legacy_id, "gpt-6-luna").await.model.api,
            Some(ModelApi::OpenaiResponses)
        );
    }
    let snapshot = backends.snapshot().to_string();
    assert!(!snapshot.contains(SECRET));
    assert!(!snapshot.contains("/inference/anthropic"));
    drop(backends);
    let (reopened, _) = service(dir.path());
    for preset in ["opencode", "opencode-go"] {
        assert_eq!(
            resolve(&reopened, preset, "gpt-6-luna").await.model.api,
            Some(ModelApi::OpenaiResponses)
        );
        assert_eq!(
            resolve(&reopened, &format!("{preset}-proxy"), "gpt-6-luna")
                .await
                .model
                .api,
            None
        );
    }
}

#[tokio::test]
async fn opencode_catalog_routes_stream_through_all_three_local_wire_apis() {
    use axum::body::Bytes;
    use axum::http::{HeaderMap, Uri};
    use axum::response::IntoResponse;
    use pirc_protocol::{InferenceRequest, StopReason};
    let seen = Arc::new(Mutex::new(Vec::<Value>::new()));
    let captured = seen.clone();
    let app = axum::Router::new().fallback(move |uri: Uri, headers: HeaderMap, body: Bytes| {
        let captured = captured.clone();
        async move {
            let path = uri.path();
            captured.lock().unwrap().push(json!({ "path": path,
                "session": headers.get("x-opencode-session").unwrap().to_str().unwrap(),
                "key": headers.get(if path.ends_with("/messages") { "x-api-key" } else { "authorization" }).unwrap().to_str().unwrap(),
                "body": serde_json::from_slice::<Value>(&body).unwrap() }));
            let group = if path.ends_with("/responses") { "responses" }
                else if path.ends_with("/messages") { "anthropic" } else { "completions" };
            let file = Path::new(env!("CARGO_MANIFEST_DIR")).join(format!("tests/parity/fixtures/{group}.json"));
            let fixtures: Value = serde_json::from_slice(&fs::read(file).unwrap()).unwrap();
            let chunks = fixtures[0]["responses"][0]["chunks"].as_array().unwrap()
                .iter().map(|v| v.as_str().unwrap()).collect::<String>();
            ([("content-type", "text/event-stream")], chunks).into_response()
        }
    });
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let server = tokio::spawn(async move { axum::serve(listener, app).await });
    let dir = tempfile::tempdir().unwrap();
    let (backends, _) = service(dir.path());
    let models = ["deepseek-v4.1-flash", "gpt-6-luna", "claude-haiku-5-5"];
    let preset = backends
        .presets()
        .iter()
        .find(|p| p.id == "opencode-go")
        .unwrap();
    backends.save_provider("go", &json!({ "api": preset.api, "baseUrl": preset.base_url,
        "preset": preset.id, "apiKey": SECRET,
        "models": models.iter().map(|id| preset.models.iter().find(|m| m.id == *id).unwrap().to_json()).collect::<Vec<_>>() }), true).unwrap();
    let inference = Inference::new();
    for id in models {
        let mut resolved = resolve(&backends, "go", id).await;
        let original = reqwest::Url::parse(resolved.model.base_url.as_deref().unwrap()).unwrap();
        // Preserve the catalog's entire path and API, redirecting only the
        // origin to our synthetic loopback server. No hosted inference runs.
        resolved.model.base_url = Some(format!("http://{address}{}", original.path()));
        resolved.provider.opencode_go = Some(true);
        let request: InferenceRequest = serde_json::from_value(json!({
            "providerName": "go", "modelId": id, "systemPrompt": "test",
            "messages": [{ "role": "user", "content": "synthetic ping", "timestamp": 1 }],
            "tools": [], "thinking": "off", "sessionId": "catalog-test" }))
        .unwrap();
        let reply = tokio::time::timeout(
            Duration::from_secs(5),
            inference.run(&resolved, &request, "test-node", &mut |_, _| {}),
        )
        .await
        .unwrap();
        assert_eq!(
            reply.stop_reason,
            StopReason::Stop,
            "{id}: {:?}",
            reply.error_message
        );
        assert!(
            serde_json::to_string(&reply.content)
                .unwrap()
                .contains("Hello from the fake model.")
        );
    }
    server.abort();
    let requests = seen.lock().unwrap();
    assert_eq!(requests.len(), 3);
    for ((request, id), suffix) in requests.iter().zip(models).zip([
        "openai/v1/chat/completions",
        "openai/v1/responses",
        "anthropic/v1/messages",
    ]) {
        assert_eq!(request["path"], format!("/inference/go/{suffix}"));
        assert_eq!(
            request["session"],
            json!(["test-node", "catalog-test", "go"]).to_string()
        );
        assert_eq!(request["body"]["model"], id);
        assert_eq!(
            request["key"],
            if suffix.ends_with("messages") {
                SECRET.to_owned()
            } else {
                format!("Bearer {SECRET}")
            }
        );
    }
}

#[tokio::test]
async fn refreshed_multi_api_presets_keep_native_routes_without_redirecting_custom_proxies() {
    use pirc_protocol::ModelApi;
    let dir = tempfile::tempdir().unwrap();
    let (backends, _) = service(dir.path());
    for provider in ["openrouter", "fireworks"] {
        let preset = backends
            .presets()
            .iter()
            .find(|p| p.id == provider)
            .unwrap();
        let catalog = crate::catalog::catalog_models(provider);
        let anthropic = catalog
            .iter()
            .find(|m| m.api == ModelApi::AnthropicMessages)
            .unwrap();
        let chat = catalog
            .iter()
            .find(|m| m.api == ModelApi::OpenaiCompletions)
            .unwrap();
        let mut body = json!({"api": preset.api, "baseUrl": preset.base_url,
            "preset": provider, "apiKey": SECRET,
            "models": [{"id": anthropic.id}, {"id": chat.id}]});
        backends.save_provider(provider, &body, true).unwrap();
        for expected in [anthropic, chat] {
            let resolved = resolve(&backends, provider, &expected.id).await;
            assert_eq!(resolved.model.api, Some(expected.api));
            assert_eq!(
                resolved.model.base_url.as_deref(),
                Some(expected.base_url.as_str())
            );
        }
        body["baseUrl"] = json!("https://my-proxy.example/v1");
        backends.save_provider(provider, &body, false).unwrap();
        let custom = resolve(&backends, provider, &anthropic.id).await;
        assert_eq!(custom.provider.base_url, "https://my-proxy.example/v1");
        assert_eq!(custom.model.api, None);
        assert_eq!(custom.model.base_url, None);
    }
}
