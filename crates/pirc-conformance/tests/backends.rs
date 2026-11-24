//! The model-backend settings routes (`apps/gateway/src/backends/routes.ts`,
//! `service.ts`, `discovery.ts`): the file-managed `fake` provider next to
//! web-managed ("UI") backends, model discovery and connection tests against
//! the fake model server, the default model, a real run through a UI backend,
//! SIGHUP reloads of the models file, and the provider-auth routes up to the
//! point where a real login would start.
//!
//! What reached the fake provider (path, query and credential headers) is
//! recorded after each step as "<step>: provider saw".

use std::time::{Duration, Instant};

use pirc_conformance::{
    Cluster, ModelsReply, Reply, Response, Transcript, WORKSPACE_ID, browser_headers,
};
use regex::Regex;
use serde_json::{Value, json};

/// A connection test's timing, which differs on every run.
fn timed(mut response: Response) -> Response {
    if let Some(body) = response.body.as_object_mut() {
        if body.get("latencyMs").is_some_and(Value::is_u64) {
            body.insert("latencyMs".to_owned(), json!("<ms>"));
        }
        if let Some(message) = body.get("message").and_then(Value::as_str) {
            let pattern = Regex::new(r" answered in \d+ ms\.$").unwrap();
            let message = pattern
                .replace(message, " answered in <ms> ms.")
                .into_owned();
            body.insert("message".to_owned(), json!(message));
        }
    }
    response
}

/// A local URL nothing listens on.
fn unreachable_url() -> String {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    drop(listener);
    format!("http://127.0.0.1:{port}/v1")
}

fn settled(frame: &Value) -> bool {
    frame["type"] == "pi_event" && frame["data"]["type"] == "agent_settled"
}

#[ignore = "pirc 2: needs a session created through first-send instead of the removed POST /api/sessions; rewritten after M4 (plans/roadmap.md M2.9)"]
#[tokio::test(flavor = "multi_thread")]
async fn backends() {
    let Some(cluster) = Cluster::start().await else {
        return;
    };
    let api = cluster.api();
    let headers = browser_headers();
    let llm = cluster.llm.base_url();
    let unreachable = unreachable_url();
    let mut literals = cluster.volatile();
    literals.push((cluster.llm.root_url(), "<llm-root>"));
    literals.push((unreachable.clone(), "<unreachable>"));
    let mut t = Transcript::new(literals);

    macro_rules! call {
        ($step:expr, $method:expr, $path:expr, $body:expr) => {{
            let target = String::from($path);
            let response = timed(api.send($method, &target, &headers, $body).await);
            t.response($step, &format!("{} {}", $method, target), &response);
            let seen = cluster.llm.take_seen();
            if !seen.is_empty() {
                t.note(&format!("{}: provider saw", $step), json!(seen));
            }
            response
        }};
    }

    // 1. The starting state: one file-managed provider.
    call!("providers", "GET", "/api/providers", None);
    let presets = api
        .send("GET", "/api/providers/presets", &headers, None)
        .await;
    t.note("presets", presets_summary(&presets));
    call!("models", "GET", "/api/models", None);

    // 4. Creating web-managed backends.
    let ui = json!({
        "id": "ui", "api": "openai-completions", "baseUrl": llm, "apiKey": "ui-key",
        "models": [
            { "id": "ui-model", "reasoning": true },
            { "id": "ui-small", "name": "UI small", "contextWindow": 1000, "maxTokens": 100,
                "input": ["text", "image"] },
        ],
    });
    let with = |base: &Value, change: &dyn Fn(&mut Value)| {
        let mut value = base.clone();
        change(&mut value);
        value
    };
    call!(
        "create a UI backend",
        "POST",
        "/api/providers",
        Some(ui.clone())
    );
    call!(
        "create it again",
        "POST",
        "/api/providers",
        Some(ui.clone())
    );
    for (step, id) in [
        ("an ID with bad characters", json!("bad id!")),
        ("an ID starting with a dash", json!("-ui")),
        ("an ID of 81 characters", json!("a".repeat(81))),
        ("the reserved ID default-model", json!("default-model")),
        ("the reserved ID __proto__", json!("__proto__")),
        ("the reserved ID constructor", json!("constructor")),
        ("a numeric ID", json!(7)),
        ("the file-managed ID", json!("fake")),
    ] {
        call!(
            step,
            "POST",
            "/api/providers",
            Some(with(&ui, &|b| b["id"] = id.clone()))
        );
    }
    call!(
        "the file-managed ID with an invalid body",
        "POST",
        "/api/providers",
        Some(json!({ "id": "fake" }))
    );
    let other = with(&ui, &|b| b["id"] = json!("other"));
    let invalid_bodies: Vec<(&str, Value)> = vec![
        (
            "duplicate model IDs",
            with(&other, &|b| {
                b["models"] = json!([{ "id": "m" }, { "id": "m", "name": "again" }])
            }),
        ),
        ("no models", with(&other, &|b| b["models"] = json!([]))),
        (
            "a zero context window",
            with(&other, &|b| b["models"][0]["contextWindow"] = json!(0)),
        ),
        (
            "fractional max tokens",
            with(&other, &|b| b["models"][0]["maxTokens"] = json!(1.5)),
        ),
        (
            "an empty input list",
            with(&other, &|b| b["models"][0]["input"] = json!([])),
        ),
        (
            "an unknown input kind",
            with(&other, &|b| b["models"][0]["input"] = json!(["audio"])),
        ),
        (
            "an empty model name",
            with(&other, &|b| b["models"][0]["name"] = json!("")),
        ),
        (
            "an unknown model field",
            with(&other, &|b| b["models"][0]["cost"] = json!(1)),
        ),
        (
            "an unknown field",
            with(&other, &|b| b["headers"] = json!({ "x": "y" })),
        ),
        (
            "an unknown api",
            with(&other, &|b| b["api"] = json!("openai-codex-responses")),
        ),
        (
            "an ftp base URL",
            with(&other, &|b| b["baseUrl"] = json!("ftp://example.com/v1")),
        ),
        (
            "a base URL with a query",
            with(&other, &|b| {
                b["baseUrl"] = json!("https://example.com/v1?x=1")
            }),
        ),
        (
            "a base URL with a hash",
            with(&other, &|b| {
                b["baseUrl"] = json!("https://example.com/v1#x")
            }),
        ),
        (
            "a base URL with credentials",
            with(&other, &|b| {
                b["baseUrl"] = json!("https://user:pass@example.com/v1")
            }),
        ),
        // zod runs the URL refinement (`new URL`) even after `.url()`
        // failed, and the TypeError is a 500.
        (
            "a base URL that is not a URL",
            with(&other, &|b| b["baseUrl"] = json!("not a url")),
        ),
        (
            "an unknown preset",
            with(&other, &|b| b["preset"] = json!("nope")),
        ),
        (
            "a preset that is not from the catalog",
            with(&other, &|b| b["preset"] = json!("ollama")),
        ),
        (
            "a preset whose api differs",
            with(&other, &|b| b["preset"] = json!("openai")),
        ),
    ];
    for (step, body) in invalid_bodies {
        call!(step, "POST", "/api/providers", Some(body));
    }
    call!("no body", "POST", "/api/providers", None);
    let preset = json!({
        "id": "openai-preset", "api": "openai-responses", "baseUrl": llm,
        "apiKey": "preset-key", "preset": "openai",
        "models": [
            { "id": "gpt-5-mini", "reasoning": true, "contextWindow": 400000,
                "maxTokens": 128000, "input": ["text", "image"] },
            { "id": "not-in-the-catalog" },
        ],
    });
    call!(
        "create from the openai preset",
        "POST",
        "/api/providers",
        Some(preset.clone())
    );

    // 5. Updating and deleting.
    let mut update = ui.clone();
    update.as_object_mut().unwrap().remove("id");
    update.as_object_mut().unwrap().remove("apiKey");
    update["models"][1]["name"] = json!("UI small, renamed");
    call!(
        "update without apiKey keeps the key",
        "PUT",
        "/api/providers/ui",
        Some(update.clone())
    );
    let mut cleared = preset.clone();
    cleared.as_object_mut().unwrap().remove("id");
    cleared["apiKey"] = json!("");
    call!(
        "update with an empty apiKey clears it",
        "PUT",
        "/api/providers/openai-preset",
        Some(cleared)
    );
    call!(
        "update an unknown backend",
        "PUT",
        "/api/providers/nope",
        Some(update.clone())
    );
    call!(
        "update the file-managed backend",
        "PUT",
        "/api/providers/fake",
        Some(update.clone())
    );
    call!(
        "update with a reserved ID",
        "PUT",
        "/api/providers/constructor",
        Some(update.clone())
    );
    call!(
        "update with an invalid body",
        "PUT",
        "/api/providers/ui",
        Some(json!({ "api": "openai-completions" }))
    );
    call!("update without a body", "PUT", "/api/providers/ui", None);
    call!(
        "delete an unknown backend",
        "DELETE",
        "/api/providers/nope",
        None
    );
    call!(
        "delete the file-managed backend",
        "DELETE",
        "/api/providers/fake",
        None
    );
    call!(
        "delete an OAuth backend that is not connected",
        "DELETE",
        "/api/providers/oauth:anthropic",
        None
    );
    call!(
        "delete an unknown OAuth backend",
        "DELETE",
        "/api/providers/oauth:nope",
        None
    );
    call!(
        "delete with an ID over 100 characters",
        "DELETE",
        format!("/api/providers/{}", "x".repeat(101)),
        None
    );

    // 2. Discovery.
    let probe = json!({ "api": "openai-completions", "baseUrl": llm, "apiKey": "probe-key" });
    let openai_list = json!({ "object": "list", "data": [
        { "id": "b-model", "object": "model", "context_length": 131072,
            "top_provider": { "context_length": 1, "max_completion_tokens": 8192 },
            "architecture": { "input_modalities": ["text", "image"] },
            "supported_parameters": ["tools", "reasoning"] },
        { "id": "a-model", "name": "A Model", "context_window": 4096,
            "max_output_tokens": 1024 },
        { "id": "b-model", "name": "duplicate, ignored" },
        { "object": "model" },
        { "id": 42, "name": "named-by-name" },
        { "id": "bad\u{1}id" },
        { "id": "c-model", "name": "bad\u{7}name", "display_name": "C Display",
            "max_model_len": 100000001, "max_completion_tokens": 0 },
        { "id": "d-model", "name": "d-model", "context_length": 1.5,
            "max_context_length": 2048, "top_provider": { "context_length": 9999 },
            "supported_parameters": "reasoning", "architecture": { "input_modalities": "image" } },
        { "model": "from-model-field" },
        { "id": "Zeta" },
        { "id": "alpha" },
        "a string",
        null,
    ] });
    t.note("scripted OpenAI model list", openai_list.clone());
    cluster
        .llm
        .push_models([ModelsReply::Json(200, openai_list)]);
    call!(
        "discover an OpenAI-style list",
        "POST",
        "/api/providers/discover",
        Some(probe.clone())
    );
    let ollama = json!({ "models": [
        { "name": "llama3:8b", "model": "llama3:8b", "size": 1 },
        { "model": "only-model" },
        { "name": "named" , "details": {} },
    ] });
    t.note("scripted Ollama model list", ollama.clone());
    cluster.llm.push_models([ModelsReply::Json(200, ollama)]);
    call!(
        "discover an Ollama-style list (openai-chat, no key)",
        "POST",
        "/api/providers/discover",
        Some(json!({ "api": "openai-chat", "baseUrl": llm }))
    );
    cluster.llm.push_models([ModelsReply::Json(
        200,
        json!([{ "id": "bare" }, { "id": "bare" }]),
    )]);
    call!(
        "discover a bare array (openai-responses, trailing slashes)",
        "POST",
        "/api/providers/discover",
        Some(
            json!({ "api": "openai-responses", "baseUrl": format!("{llm}//"), "apiKey": "probe-key" })
        )
    );
    for (step, reply) in [
        (
            "an unrecognized object",
            ModelsReply::Json(200, json!({ "object": "list" })),
        ),
        (
            "data that is not a list",
            ModelsReply::Json(200, json!({ "data": {} })),
        ),
        (
            "an empty list",
            ModelsReply::Json(200, json!({ "data": [] })),
        ),
        ("invalid JSON", ModelsReply::Raw(200, "not json".to_owned())),
        (
            "HTTP 401",
            ModelsReply::Json(401, json!({ "error": "secret upstream text" })),
        ),
        ("HTTP 403", ModelsReply::Raw(403, "forbidden".to_owned())),
        ("HTTP 404", ModelsReply::Raw(404, "not found".to_owned())),
        ("HTTP 429", ModelsReply::Raw(429, "slow down".to_owned())),
        ("HTTP 500", ModelsReply::Raw(500, "boom".to_owned())),
        ("HTTP 503", ModelsReply::Raw(503, "unavailable".to_owned())),
        (
            "a redirect",
            ModelsReply::Redirect("https://elsewhere.example/v1/models".to_owned()),
        ),
    ] {
        cluster.llm.push_models([reply]);
        call!(
            &format!("discover: {step}"),
            "POST",
            "/api/providers/discover",
            Some(probe.clone())
        );
    }
    call!(
        "discover: an unreachable endpoint",
        "POST",
        "/api/providers/discover",
        Some(with(&probe, &|b| b["baseUrl"] = json!(unreachable)))
    );
    cluster.llm.push_models([ModelsReply::Json(
        200,
        json!({ "data": [{ "id": "claude-x", "type": "model", "display_name": "Claude X" }],
            "has_more": false }),
    )]);
    call!(
        "discover through the Anthropic API",
        "POST",
        "/api/providers/discover",
        Some(
            json!({ "api": "anthropic-messages", "baseUrl": cluster.llm.root_url(),
            "apiKey": "anthropic-key" })
        )
    );
    cluster.llm.push_models([ModelsReply::Json(
        200,
        json!({ "data": [
            { "id": "gpt-4o-mini" },
            { "id": "gpt-5-mini", "name": "Renamed by the endpoint", "context_length": 5 },
            { "id": "not-in-the-catalog", "context_length": 5 },
        ] }),
    )]);
    call!(
        "discover with the openai preset",
        "POST",
        "/api/providers/discover",
        Some(
            json!({ "api": "openai-responses", "baseUrl": llm, "apiKey": "probe-key",
            "preset": "openai" })
        )
    );
    cluster
        .llm
        .push_models([ModelsReply::Json(200, json!({ "data": [{ "id": "m" }] }))]);
    call!(
        "discover with an unknown preset",
        "POST",
        "/api/providers/discover",
        Some(with(&probe, &|b| b["preset"] = json!("nope")))
    );
    for (step, body) in [
        (
            "an ftp base URL",
            with(&probe, &|b| b["baseUrl"] = json!("ftp://example.com/v1")),
        ),
        (
            "a base URL with a query",
            with(&probe, &|b| b["baseUrl"] = json!(format!("{llm}?x=1"))),
        ),
        (
            "a base URL with a hash",
            with(&probe, &|b| b["baseUrl"] = json!(format!("{llm}#x"))),
        ),
        (
            "a base URL with credentials",
            with(&probe, &|b| {
                b["baseUrl"] = json!("http://user:pass@127.0.0.1:1/v1")
            }),
        ),
        (
            "not a URL",
            with(&probe, &|b| b["baseUrl"] = json!("not a url")),
        ),
        (
            "an unknown field",
            with(&probe, &|b| b["models"] = json!([])),
        ),
        (
            "an unknown api",
            with(&probe, &|b| b["api"] = json!("gemini")),
        ),
        ("no base URL", json!({ "api": "openai-completions" })),
    ] {
        call!(
            &format!("discover: {step}"),
            "POST",
            "/api/providers/discover",
            Some(body)
        );
    }
    call!("discover: no body", "POST", "/api/providers/discover", None);
    let malformed = api
        .send_bytes(
            "POST",
            "/api/providers/discover",
            &headers,
            Some("application/json"),
            b"{".to_vec(),
        )
        .await;
    t.response(
        "discover: malformed JSON",
        "POST /api/providers/discover",
        &malformed,
    );
    let reuse = json!({ "api": "openai-completions", "baseUrl": llm });
    call!(
        "discover reusing the saved key of a UI backend",
        "POST",
        "/api/providers/discover",
        Some(with(&reuse, &|b| b["backendId"] = json!("ui")))
    );
    call!(
        "discover with an empty key and a UI backend's ID",
        "POST",
        "/api/providers/discover",
        Some(with(&reuse, &|b| {
            b["backendId"] = json!("ui");
            b["apiKey"] = json!("");
        }))
    );
    call!(
        "discover with the file-managed backend's ID (its key is not reused)",
        "POST",
        "/api/providers/discover",
        Some(with(&reuse, &|b| b["backendId"] = json!("fake")))
    );
    call!(
        "discover with an unknown backend ID",
        "POST",
        "/api/providers/discover",
        Some(with(&reuse, &|b| b["backendId"] = json!("nope")))
    );

    // 3. Connection tests.
    let test = json!({ "api": "openai-completions", "baseUrl": llm, "apiKey": "test-key-2",
        "model": { "id": "probe-model", "reasoning": true } });
    let before = cluster.llm.requests().len();
    call!(
        "test a connection",
        "POST",
        "/api/providers/test",
        Some(test.clone())
    );
    t.note(
        "test a connection: request body",
        json!(cluster.llm.requests()[before..]),
    );
    cluster
        .llm
        .push([Reply::Status(500, "secret upstream text".to_owned())]);
    call!(
        "test a connection: HTTP 500",
        "POST",
        "/api/providers/test",
        Some(test.clone())
    );
    cluster.llm.push([Reply::Status(401, "bad key".to_owned())]);
    call!(
        "test a connection: HTTP 401",
        "POST",
        "/api/providers/test",
        Some(test.clone())
    );
    call!(
        "test a connection: an unreachable endpoint",
        "POST",
        "/api/providers/test",
        Some(with(&test, &|b| b["baseUrl"] = json!(unreachable)))
    );
    call!(
        "test a connection reusing a UI backend's key",
        "POST",
        "/api/providers/test",
        Some(with(&test, &|b| {
            b.as_object_mut().unwrap().remove("apiKey");
            b["backendId"] = json!("ui");
        }))
    );
    call!(
        "test a connection with the file-managed backend's ID",
        "POST",
        "/api/providers/test",
        Some(with(&test, &|b| {
            b.as_object_mut().unwrap().remove("apiKey");
            b["backendId"] = json!("fake");
        }))
    );
    for (step, body) in [
        (
            "no model",
            with(&test, &|b| {
                b.as_object_mut().unwrap().remove("model");
            }),
        ),
        (
            "an unknown model field",
            with(&test, &|b| b["model"]["cost"] = json!(1)),
        ),
        (
            "a base URL that is not a URL",
            with(&test, &|b| b["baseUrl"] = json!("not a url")),
        ),
        (
            "an unknown preset",
            with(&test, &|b| b["preset"] = json!("nope")),
        ),
        (
            "an unknown field",
            with(&test, &|b| b["models"] = json!([])),
        ),
    ] {
        call!(
            &format!("test a connection: {step}"),
            "POST",
            "/api/providers/test",
            Some(body)
        );
    }

    // 6. The default model.
    let default = json!({ "provider": "openai-preset", "id": "gpt-5-mini", "thinking": "high" });
    call!(
        "set the default model",
        "PUT",
        "/api/providers/default-model",
        Some(default.clone())
    );
    call!("models with that default", "GET", "/api/models", None);
    for (step, body) in [
        (
            "an unknown model",
            json!({ "provider": "openai-preset", "id": "nope" }),
        ),
        (
            "an unknown provider",
            json!({ "provider": "nope", "id": "gpt-5-mini" }),
        ),
        ("an extra field", with(&default, &|b| b["extra"] = json!(1))),
        (
            "an unknown thinking level",
            with(&default, &|b| b["thinking"] = json!("max")),
        ),
        ("a string", json!("openai-preset/gpt-5-mini")),
    ] {
        call!(
            &format!("default model: {step}"),
            "PUT",
            "/api/providers/default-model",
            Some(body)
        );
    }
    call!(
        "clear the default model (null)",
        "PUT",
        "/api/providers/default-model",
        Some(Value::Null)
    );
    call!(
        "set it again",
        "PUT",
        "/api/providers/default-model",
        Some(default.clone())
    );
    call!(
        "clear the default model (no body)",
        "PUT",
        "/api/providers/default-model",
        None
    );
    call!(
        "set it once more",
        "PUT",
        "/api/providers/default-model",
        Some(default.clone())
    );
    call!(
        "delete the default model's backend",
        "DELETE",
        "/api/providers/openai-preset",
        None
    );
    call!("models after the delete", "GET", "/api/models", None);

    // 7. A real run through a UI backend uses that backend's own key.
    call!(
        "make a UI backend's model the default",
        "PUT",
        "/api/providers/default-model",
        Some(json!({ "provider": "ui", "id": "ui-model", "thinking": "high" }))
    );
    let created = api
        .send(
            "POST",
            "/api/sessions",
            &headers,
            Some(json!({ "workspaceId": WORKSPACE_ID })),
        )
        .await;
    assert_eq!(created.status, 201, "{}", created.body);
    let id = created.body["session"]["id"].as_str().unwrap().to_owned();
    let session = format!("/api/sessions/{id}");
    let acquired = api
        .send(
            "POST",
            &format!("{session}/control/acquire"),
            &headers,
            Some(json!({ "clientId": "browser" })),
        )
        .await;
    let generation = acquired.body["lease"]["generation"].clone();
    let snapshot = api
        .send("GET", &format!("{session}/snapshot"), &headers, None)
        .await;
    t.note("the new session's agent", snapshot.body["agent"].clone());
    let watermark = &snapshot.body["watermark"];
    let cursor = format!("{}:{}", watermark["epoch"], watermark["sequence"]);
    let mut live = api
        .connect(
            &format!("/api/events?sessionId={id}&cursor={cursor}"),
            &headers,
        )
        .await
        .open();
    cluster
        .llm
        .push([Reply::Text("Hello through the UI backend.".to_owned())]);
    let before = cluster.llm.requests().len();
    let path = format!("{session}/commands");
    let sent = api
        .send(
            "POST",
            &path,
            &headers,
            Some(json!({
                "commandId": "command-1", "clientId": "browser", "generation": generation,
                "payload": { "type": "prompt", "message": "Say hello" },
            })),
        )
        .await;
    t.response("prompt", &format!("POST {path}"), &sent);
    let streamed = live.until(settled).await;
    live.close().await;
    let reply = streamed
        .iter()
        .rev()
        .find(|frame| frame["data"]["type"] == "message_end")
        .map(|frame| {
            let message = &frame["data"]["message"];
            json!({ "provider": message["provider"], "model": message["model"],
                "api": message["api"], "stopReason": message["stopReason"],
                "errorMessage": message["errorMessage"], "content": message["content"] })
        });
    t.note("the run's assistant message", json!(reply));
    let requests: Vec<Value> = cluster.llm.requests()[before..]
        .iter()
        .map(|body| json!({ "model": body["model"], "reasoning_effort": body["reasoning_effort"] }))
        .collect();
    t.note("the run: model requests", json!(requests));
    t.note("the run: provider saw", json!(cluster.llm.take_seen()));

    // 8. SIGHUP reloads the models file; file-managed providers win.
    let second = json!({ "id": "second", "api": "openai-completions", "baseUrl": llm,
        "apiKey": "shadow-key", "models": [{ "id": "ui-only-model" }] });
    call!(
        "create a UI backend named like a later file provider",
        "POST",
        "/api/providers",
        Some(second)
    );
    let file = cluster.models_file().to_owned();
    let mut models: Value = serde_json::from_slice(&std::fs::read(&file).unwrap()).unwrap();
    models["providers"]["second"] = json!({ "api": "openai-completions", "baseUrl": llm,
        "apiKey": "second-key", "models": [{ "id": "second-model", "name": "Second" }] });
    std::fs::write(&file, serde_json::to_vec_pretty(&models).unwrap()).unwrap();
    cluster.reload_gateway();
    let deadline = Instant::now() + Duration::from_secs(10);
    let reloaded = loop {
        let response = api.send("GET", "/api/providers", &headers, None).await;
        let shadowed = response.body["providers"]
            .as_array()
            .unwrap()
            .iter()
            .any(|provider| provider["id"] == "second" && provider["source"] == "file");
        if shadowed {
            break response;
        }
        assert!(
            Instant::now() < deadline,
            "SIGHUP did not reload the models file"
        );
        tokio::time::sleep(Duration::from_millis(50)).await;
    };
    t.response(
        "providers after SIGHUP (the file provider shadows the UI one)",
        "GET /api/providers",
        &reloaded,
    );
    call!("models after SIGHUP", "GET", "/api/models", None);
    call!(
        "update the shadowed backend",
        "PUT",
        "/api/providers/second",
        Some(json!({ "api": "openai-completions", "baseUrl": llm,
            "models": [{ "id": "x" }] }))
    );
    call!(
        "delete the shadowed backend",
        "DELETE",
        "/api/providers/second",
        None
    );
    call!(
        "discover with the shadowed backend's ID (its saved key is not reused)",
        "POST",
        "/api/providers/discover",
        Some(json!({ "api": "openai-completions", "baseUrl": llm, "backendId": "second" }))
    );
    for invalid in [
        "{ not json".to_owned(),
        json!({ "providers": { "broken": { "api": "nope" } } }).to_string(),
    ] {
        std::fs::write(&file, invalid).unwrap();
        cluster.reload_gateway();
        // Nothing observable says the reload was refused; give it time.
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
    let after = api.send("GET", "/api/providers", &headers, None).await;
    t.note(
        "invalid models files on SIGHUP leave the providers unchanged",
        json!({ "status": after.status, "unchanged": after.body == reloaded.body }),
    );

    // Backend IDs that are also static route names: Fastify routes each
    // method on its own, so PUT and DELETE still reach the backend.
    let named = |id: &str| {
        json!({ "id": id, "api": "openai-completions", "baseUrl": llm,
            "models": [{ "id": "m" }] })
    };
    for id in ["test", "discover", "presets"] {
        call!(
            &format!("create a backend named {id}"),
            "POST",
            "/api/providers",
            Some(named(id))
        );
        call!(
            &format!("edit the backend named {id}"),
            "PUT",
            format!("/api/providers/{id}"),
            Some(json!({ "api": "openai-completions", "baseUrl": llm,
                "models": [{ "id": "m2" }] }))
        );
        call!(
            &format!("delete the backend named {id}"),
            "DELETE",
            format!("/api/providers/{id}"),
            None
        );
        call!(
            &format!("delete {id} again"),
            "DELETE",
            format!("/api/providers/{id}"),
            None
        );
    }
    call!(
        "delete default-model",
        "DELETE",
        "/api/providers/default-model",
        None
    );
    call!(
        "edit a backend named presets that does not exist",
        "PUT",
        "/api/providers/presets",
        None
    );
    call!(
        "GET a static route of another method",
        "GET",
        "/api/providers/test",
        None
    );
    call!(
        "create a backend named ab",
        "POST",
        "/api/providers",
        Some(named("ab"))
    );
    call!(
        "delete it by an escaped ID",
        "DELETE",
        "/api/providers/%61b",
        None
    );

    // 9. Provider authorization, without starting a real login.
    let long = "x".repeat(101);
    let at_limit = "x".repeat(100);
    for (step, body) in [
        ("an unknown provider", Some(json!({ "providerId": "nope" }))),
        (
            "github-copilot without policy consent",
            Some(json!({ "providerId": "github-copilot" })),
        ),
        (
            "github-copilot with policyConsent false",
            Some(json!({ "providerId": "github-copilot", "policyConsent": false })),
        ),
        (
            "an extra field",
            Some(json!({ "providerId": "anthropic", "extra": 1 })),
        ),
        ("no providerId", Some(json!({ "policyConsent": true }))),
        ("an empty providerId", Some(json!({ "providerId": "" }))),
        ("no body", None),
    ] {
        call!(
            &format!("start a login: {step}"),
            "POST",
            "/api/provider-auth/sessions",
            body
        );
    }
    call!(
        "status of an unknown login",
        "GET",
        "/api/provider-auth/sessions/nope",
        None
    );
    call!(
        "cancel an unknown login",
        "DELETE",
        "/api/provider-auth/sessions/nope",
        None
    );
    call!(
        "answer an unknown login",
        "POST",
        "/api/provider-auth/sessions/nope/input",
        Some(json!({ "promptId": "p", "value": "v" }))
    );
    call!(
        "answer an unknown login with an invalid body",
        "POST",
        "/api/provider-auth/sessions/nope/input",
        Some(json!({ "promptId": "p", "extra": 1 }))
    );
    call!(
        "status of a login with a 100-character ID",
        "GET",
        format!("/api/provider-auth/sessions/{at_limit}"),
        None
    );
    call!(
        "status of a login with a 101-character ID",
        "GET",
        format!("/api/provider-auth/sessions/{long}"),
        None
    );
    call!(
        "answer a login with a 101-character ID",
        "POST",
        format!("/api/provider-auth/sessions/{long}/input"),
        Some(json!({ "promptId": "p" }))
    );
    call!("providers at the end", "GET", "/api/providers", None);

    insta::assert_json_snapshot!("backends", t.into_value());
}

/// The presets are pi-ai's whole catalog (hundreds of models): their order
/// and fields are recorded with model counts, plus the full model lists of
/// a few small ones.
fn presets_summary(response: &Response) -> Value {
    let presets = response.body["presets"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    let full = ["deepseek", "kimi-coding", "ollama"];
    json!({
        "status": response.status,
        "headers": response.headers.iter().map(|(name, value)| format!("{name}: {value}"))
            .collect::<Vec<_>>(),
        "presets": presets.iter().map(|preset| {
            let mut entry = preset.clone();
            let models = entry["models"].as_array().cloned().unwrap_or_default();
            let id = preset["id"].as_str().unwrap_or_default();
            if !full.contains(&id) {
                entry["models"] = json!({ "count": models.len(),
                    "first": models.first(), "ids": models.iter().map(|m| &m["id"])
                        .collect::<Vec<_>>() });
            }
            entry
        }).collect::<Vec<_>>(),
    })
}
