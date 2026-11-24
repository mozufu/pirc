//! Setup helpers for API-key backends (`backends/discovery.ts`): presets
//! from the embedded catalog, model discovery from an endpoint's model list,
//! and a one-off connection test. Upstream bodies, URLs and credentials are
//! never echoed; errors are curated messages the web client shows verbatim.

use std::cmp::Ordering;
use std::time::{Duration, Instant};

use pirc_protocol::{InferenceRequest, Message, ModelApi, ThinkingLevel};
use serde_json::{Map, Value, json};

use super::BackendError;
use crate::catalog::{CatalogModel, catalog_models};
use crate::inference::{Inference, Resolved};

/// The editable model fields the settings UI round-trips (`UiModel`).
#[derive(Clone, Debug, PartialEq)]
pub struct UiModel {
    pub id: String,
    pub name: Option<String>,
    pub context_window: Option<u64>,
    pub max_tokens: Option<u64>,
    pub reasoning: Option<bool>,
    pub input: Option<Vec<String>>,
}

impl UiModel {
    pub fn to_json(&self) -> Value {
        let mut out = Map::new();
        out.insert("id".to_owned(), json!(self.id));
        if let Some(name) = &self.name {
            out.insert("name".to_owned(), json!(name));
        }
        if let Some(value) = self.context_window {
            out.insert("contextWindow".to_owned(), json!(value));
        }
        if let Some(value) = self.max_tokens {
            out.insert("maxTokens".to_owned(), json!(value));
        }
        if let Some(value) = self.reasoning {
            out.insert("reasoning".to_owned(), json!(value));
        }
        if let Some(value) = &self.input {
            out.insert("input".to_owned(), json!(value));
        }
        Value::Object(out)
    }
}

/// `uiModel(model)`: a catalog model as the settings form shows it.
pub fn ui_model(model: &CatalogModel) -> UiModel {
    UiModel {
        id: model.id.clone(),
        name: (!model.name.is_empty() && model.name != model.id).then(|| model.name.clone()),
        context_window: Some(model.context_window),
        max_tokens: Some(model.max_tokens),
        reasoning: Some(model.reasoning),
        input: Some(
            model
                .input
                .iter()
                .filter(|kind| *kind == "text" || *kind == "image")
                .cloned()
                .collect(),
        ),
    }
}

/// An API-key preset (`BackendPreset`).
#[derive(Clone, Debug, PartialEq)]
pub struct BackendPreset {
    pub id: String,
    pub name: String,
    pub api: ModelApi,
    pub base_url: String,
    /// A local server that normally needs no key.
    pub keyless: bool,
    /// Models come from the catalog (and saving keeps its request compatibility).
    pub catalog: bool,
    pub models: Vec<UiModel>,
}

impl BackendPreset {
    pub fn to_json(&self) -> Value {
        let mut out = json!({ "id": self.id, "name": self.name, "api": self.api,
            "baseUrl": self.base_url });
        if self.keyless {
            out["keyless"] = json!(true);
        }
        out["catalog"] = json!(self.catalog);
        out["models"] = self.models.iter().map(UiModel::to_json).collect();
        out
    }
}

fn display_name(id: &str) -> Option<&'static str> {
    Some(match id {
        "openai" => "OpenAI",
        "anthropic" => "Anthropic",
        "openrouter" => "OpenRouter",
        "deepseek" => "DeepSeek",
        "xai" => "xAI",
        "groq" => "Groq",
        "cerebras" => "Cerebras",
        "fireworks" => "Fireworks",
        "huggingface" => "Hugging Face",
        "moonshotai" => "Moonshot AI",
        "moonshotai-cn" => "Moonshot AI (China)",
        "kimi-coding" => "Kimi Coding",
        "zai" => "Z.ai Coding Plan",
        "minimax" => "MiniMax",
        "minimax-cn" => "MiniMax (China)",
        "opencode" => "OpenCode Zen",
        "opencode-go" => "OpenCode Go",
        "vercel-ai-gateway" => "Vercel AI Gateway",
        "xiaomi" => "Xiaomi MiMo",
        _ => return None,
    })
}

/// Common services first; the rest follow alphabetically.
const ORDER: [&str; 6] = [
    "openai",
    "anthropic",
    "openrouter",
    "deepseek",
    "xai",
    "groq",
];
/// Subscription-only catalogs are handled by OAuth login, not API keys.
const EXCLUDED: [&str; 2] = ["github-copilot", "openai-codex"];

fn local_presets() -> [BackendPreset; 2] {
    let local = |id: &str, name: &str, base_url: &str| BackendPreset {
        id: id.to_owned(),
        name: name.to_owned(),
        api: ModelApi::OpenaiCompletions,
        base_url: base_url.to_owned(),
        keyless: true,
        catalog: false,
        models: Vec::new(),
    };
    [
        local("ollama", "Ollama (local)", "http://localhost:11434/v1"),
        local("lmstudio", "LM Studio (local)", "http://localhost:1234/v1"),
    ]
}

/// The order identifiers and names are listed in: case-insensitively by
/// code point, a lowercase name before its uppercase twin.
pub fn name_order(a: &str, b: &str) -> Ordering {
    a.chars()
        .flat_map(char::to_lowercase)
        .cmp(b.chars().flat_map(char::to_lowercase))
        .then_with(|| b.cmp(a))
}

fn https_template_free(url: &str) -> bool {
    url.strip_prefix("https://")
        .is_some_and(|rest| !rest.is_empty() && !rest.contains(['{', '}']))
}

/// The OpenCode catalog uses one account across three native wire APIs.
/// Only these exact endpoints may receive catalog-derived route overrides.
pub fn catalog_base_url(provider: &str, api: ModelApi) -> Option<&'static str> {
    match (provider, api) {
        ("opencode", ModelApi::OpenaiCompletions | ModelApi::OpenaiResponses) => {
            Some("https://opencode.ai/inference/openai/v1")
        }
        ("opencode", ModelApi::AnthropicMessages) => {
            Some("https://opencode.ai/inference/anthropic")
        }
        ("opencode-go", ModelApi::OpenaiCompletions | ModelApi::OpenaiResponses) => {
            Some("https://opencode.ai/inference/go/openai/v1")
        }
        ("opencode-go", ModelApi::AnthropicMessages) => {
            Some("https://opencode.ai/inference/go/anthropic")
        }
        ("openrouter", ModelApi::OpenaiCompletions) => Some("https://openrouter.ai/api/v1"),
        ("openrouter", ModelApi::AnthropicMessages) => Some("https://openrouter.ai/api"),
        ("fireworks", ModelApi::OpenaiCompletions) => Some("https://api.fireworks.ai/inference/v1"),
        ("fireworks", ModelApi::AnthropicMessages) => Some("https://api.fireworks.ai/inference"),
        _ => None,
    }
}

/// `catalogPresets`: catalog providers usable with a plain API key, then
/// local servers. Verified multi-API services retain their model-specific native routes.
pub fn catalog_presets<'a>(providers: impl Iterator<Item = &'a str>) -> Vec<BackendPreset> {
    let mut presets = Vec::new();
    for id in providers {
        if EXCLUDED.contains(&id) {
            continue;
        }
        let models = catalog_models(id);
        let routed = matches!(id, "opencode" | "opencode-go" | "openrouter" | "fireworks");
        let first = if routed {
            models
                .iter()
                .find(|model| model.api == ModelApi::OpenaiCompletions)
        } else {
            models.first()
        };
        let Some(first) = first else { continue };
        let preset_api = matches!(
            first.api,
            ModelApi::OpenaiCompletions | ModelApi::OpenaiResponses | ModelApi::AnthropicMessages
        );
        if !preset_api
            || !https_template_free(&first.base_url)
            || models.iter().any(|model| {
                if routed {
                    catalog_base_url(id, model.api) != Some(model.base_url.as_str())
                } else {
                    model.api != first.api || model.base_url != first.base_url
                }
            })
        {
            continue;
        }
        presets.push(BackendPreset {
            id: id.to_owned(),
            name: display_name(id).unwrap_or(id).to_owned(),
            api: first.api,
            base_url: first.base_url.clone(),
            keyless: false,
            catalog: true,
            models: models.iter().map(ui_model).collect(),
        });
    }
    let rank = |id: &str| ORDER.iter().position(|o| *o == id).unwrap_or(ORDER.len());
    presets.sort_by(|a, b| {
        rank(&a.id)
            .cmp(&rank(&b.id))
            .then_with(|| name_order(&a.name, &b.name))
    });
    presets.extend(local_presets());
    presets
}

/// `catalogMetadata`: gateway-only request metadata a catalog model needs.
pub fn catalog_metadata(model: &CatalogModel, into: &mut pirc_protocol::Model) {
    into.compat = model.compat.clone().unwrap_or_default();
    if let Some(headers) = &model.headers {
        into.headers = Some(headers.clone());
    }
    if let Some(map) = &model.thinking_level_map {
        into.thinking_level_map = Some(map.clone());
    }
}

/// A discovered model (`DiscoveredModel`).
#[derive(Clone, Debug, PartialEq)]
pub struct DiscoveredModel {
    pub model: UiModel,
    /// Metadata came from the catalog rather than defaults.
    pub known: bool,
}

impl DiscoveredModel {
    pub fn to_json(&self) -> Value {
        let mut out = self.model.to_json();
        out["known"] = json!(self.known);
        out
    }
}

const MAX_BODY: usize = 8 * 1024 * 1024;
const MAX_MODELS: usize = 1000;
const DISCOVERY_TIMEOUT: Duration = Duration::from_secs(15);
const TEST_TIMEOUT: Duration = Duration::from_secs(30);

fn fail(message: &str) -> BackendError {
    BackendError::new(502, "node_error", message)
}

fn unrecognized() -> BackendError {
    fail("The endpoint returned an unrecognized model list.")
}

fn http_error(status: u16) -> BackendError {
    match status {
        401 | 403 => fail(&format!(
            "The endpoint rejected the API key (HTTP {status}). Check the key and try again."
        )),
        404 => fail("This endpoint does not list its models (HTTP 404). Add model IDs manually."),
        429 => fail("The endpoint is rate limiting requests (HTTP 429). Try again later."),
        _ => fail(&format!(
            "The endpoint returned HTTP {status} when listing models."
        )),
    }
}

/// `positive(...values)`: the first JavaScript integer in 1..=1e8.
fn positive(values: &[Option<&Value>]) -> Option<u64> {
    values.iter().find_map(|value| {
        let number = (*value)?.as_f64()?;
        (number.fract() == 0.0 && number > 0.0 && number <= 100_000_000.0).then_some(number as u64)
    })
}

/// `label(value)`: 1–200 UTF-16 units without control characters.
fn label(value: Option<&Value>) -> Option<&str> {
    let text = value?.as_str()?;
    let length = super::schema::len16(text);
    ((1..=200).contains(&length) && !text.chars().any(|c| c <= '\u{1f}' || c == '\u{7f}'))
        .then_some(text)
}

/// `parseModelList`: OpenAI-style `{data}`, Ollama-style `{models}` or a
/// bare array, with optional size hints.
pub fn parse_model_list(raw: &Value) -> Result<Vec<UiModel>, BackendError> {
    let list = match raw {
        Value::Array(items) => Some(items),
        Value::Object(object) => crate::js::present(object.get("data"))
            .or_else(|| object.get("models"))
            .and_then(Value::as_array),
        _ => None,
    }
    .ok_or_else(unrecognized)?;
    let mut seen: Vec<UiModel> = Vec::new();
    for entry in list {
        // `typeof entry === 'object'`: arrays count, null does not.
        if !(entry.is_object() || entry.is_array()) {
            continue;
        }
        let field = |key: &str| entry.as_object().and_then(|object| object.get(key));
        let Some(id) = label(field("id"))
            .or_else(|| label(field("name")))
            .or_else(|| label(field("model")))
        else {
            continue;
        };
        if seen.iter().any(|model| model.id == id) {
            continue;
        }
        let name = label(field("display_name"))
            .or_else(|| label(field("name")).filter(|name| *name != id))
            .map(str::to_owned);
        let top = field("top_provider").filter(|top| top.is_object() || top.is_array());
        let top_field = |key: &str| top.and_then(Value::as_object).and_then(|t| t.get(key));
        let context_window = positive(&[
            field("context_length"),
            field("context_window"),
            field("max_context_length"),
            field("max_model_len"),
            top_field("context_length"),
        ]);
        let max_tokens = positive(&[
            top_field("max_completion_tokens"),
            field("max_output_tokens"),
            field("max_completion_tokens"),
        ]);
        let includes = |list: Option<&Value>, wanted: &str| {
            list.and_then(Value::as_array)
                .is_some_and(|items| items.iter().any(|item| item.as_str() == Some(wanted)))
        };
        let modalities = field("architecture")
            .and_then(Value::as_object)
            .and_then(|a| a.get("input_modalities"));
        seen.push(UiModel {
            id: id.to_owned(),
            name,
            context_window,
            max_tokens,
            reasoning: includes(field("supported_parameters"), "reasoning").then_some(true),
            input: includes(modalities, "image")
                .then(|| vec!["text".to_owned(), "image".to_owned()]),
        });
        if seen.len() >= MAX_MODELS {
            break;
        }
    }
    Ok(seen)
}

/// What a probe reaches.
pub struct ProbeTarget<'a> {
    pub api: ModelApi,
    pub base_url: &'a str,
    pub api_key: Option<&'a str>,
}

/// OpenCode splits inference by wire API (`/inference[/go]/{openai,anthropic}`)
/// but lists every model once per plan, at `/inference[/go]/v1/models`.
fn opencode_models_url(base: &str) -> Option<String> {
    let url = reqwest::Url::parse(base).ok()?;
    if !crate::http::is_opencode_endpoint(&url) {
        return None;
    }
    let segments: Vec<&str> = url.path_segments()?.filter(|s| !s.is_empty()).collect();
    let (plan, rest) = match segments.as_slice() {
        ["inference", "go", rest @ ..] => ("/go", rest),
        ["inference", rest @ ..] => ("", rest),
        _ => return None,
    };
    match rest {
        ["openai" | "anthropic"] | ["openai" | "anthropic", "v1"] => {
            Some(format!("https://opencode.ai/inference{plan}/v1/models"))
        }
        _ => None,
    }
}

/// `discoverModels`: list models from the endpoint itself. Redirects are
/// refused so a key is never forwarded.
pub async fn discover_models(
    client: &reqwest::Client,
    target: &ProbeTarget<'_>,
    known: impl Fn(&str) -> Option<&'static CatalogModel>,
) -> Result<Vec<DiscoveredModel>, BackendError> {
    let base = target.base_url.trim_end_matches('/');
    let anthropic = target.api == ModelApi::AnthropicMessages;
    let url = if let Some(url) = opencode_models_url(base) {
        url
    } else if anthropic {
        format!("{base}/v1/models?limit=1000")
    } else {
        format!("{base}/models")
    };
    let mut request = client.get(url).header("accept", "application/json");
    if anthropic {
        request = request.header("anthropic-version", "2023-06-01");
        if let Some(key) = target.api_key.filter(|key| !key.is_empty()) {
            request = request.header("x-api-key", key);
        }
    } else if let Some(key) = target.api_key.filter(|key| !key.is_empty()) {
        request = request.header("authorization", format!("Bearer {key}"));
    }
    let deadline = tokio::time::Instant::now() + DISCOVERY_TIMEOUT;
    let mut response = match tokio::time::timeout_at(deadline, request.send()).await {
        Err(_) => {
            return Err(BackendError::new(
                504,
                "node_timeout",
                "The endpoint did not answer within 15 seconds.",
            ));
        }
        Ok(Err(_)) => {
            return Err(fail(
                "Cannot reach the endpoint from the gateway. Check the base URL.",
            ));
        }
        Ok(Ok(response)) => response,
    };
    let status = response.status().as_u16();
    if (300..400).contains(&status) {
        return Err(fail(
            "The endpoint redirected the request. Use the final base URL.",
        ));
    }
    if !response.status().is_success() {
        return Err(http_error(status));
    }
    let mut body = Vec::new();
    loop {
        match tokio::time::timeout_at(deadline, response.chunk()).await {
            Ok(Ok(Some(chunk))) => {
                body.extend_from_slice(&chunk);
                if body.len() > MAX_BODY {
                    return Err(fail("The model list is too large to read."));
                }
            }
            Ok(Ok(None)) => break,
            // A stream cut short (or timed out) is not a model list.
            Ok(Err(_)) | Err(_) => return Err(unrecognized()),
        }
    }
    // `TextDecoder` drops a leading BOM.
    let text = String::from_utf8_lossy(&body);
    let text = text.strip_prefix('\u{feff}').unwrap_or(&text);
    let raw: Value = serde_json::from_str(text).map_err(|_| unrecognized())?;
    let mut models: Vec<DiscoveredModel> = parse_model_list(&raw)?
        .into_iter()
        .map(|model| match known(&model.id) {
            Some(entry) => {
                let mut enriched = ui_model(entry);
                if model.name.is_some() {
                    enriched.name = model.name;
                }
                DiscoveredModel {
                    model: enriched,
                    known: true,
                }
            }
            None => DiscoveredModel {
                model,
                known: false,
            },
        })
        .collect();
    models.sort_by(|a, b| name_order(&a.model.id, &b.model.id));
    Ok(models)
}

/// `ConnectionResult`.
#[derive(Clone, Debug, PartialEq)]
pub struct ConnectionResult {
    pub ok: bool,
    pub message: String,
    pub latency_ms: u64,
}

impl ConnectionResult {
    pub fn to_json(&self) -> Value {
        json!({ "ok": self.ok, "message": self.message, "latencyMs": self.latency_ms })
    }
}

/// `testConnection`: one tiny request through the transport real runs use.
pub async fn test_connection(inference: &Inference, resolved: Resolved) -> ConnectionResult {
    let started = Instant::now();
    let model_id = resolved.model.id.clone();
    let request = InferenceRequest {
        purpose: Default::default(),
        provider_name: "connection-test".to_owned(),
        model_id: model_id.clone(),
        system_prompt: "This is a connection test. Reply with OK.".to_owned(),
        messages: vec![
            serde_json::from_value::<Message>(json!({ "role": "user", "content": "ping",
                "timestamp": crate::stream::now_ms() }))
            .expect("a user message"),
        ],
        tools: Vec::new(),
        thinking: ThinkingLevel::Off,
        session_id: super::random_uuid(),
        max_tokens: Some(32),
        tool_choice: None,
    };
    let mut ignore = |_: &_, _: &_| {};
    let run = inference.run(&resolved, &request, "settings", &mut ignore);
    let outcome = tokio::time::timeout(TEST_TIMEOUT, run).await;
    let latency_ms = started.elapsed().as_millis() as u64;
    match outcome {
        Err(_) => ConnectionResult {
            ok: false,
            message: "The model did not answer within 30 seconds.".to_owned(),
            latency_ms,
        },
        Ok(message)
            if matches!(
                message.stop_reason,
                pirc_protocol::StopReason::Error | pirc_protocol::StopReason::Aborted
            ) =>
        {
            ConnectionResult {
                ok: false,
                message: message
                    .error_message
                    .unwrap_or_else(|| "Model request failed".to_owned()),
                latency_ms,
            }
        }
        Ok(_) => ConnectionResult {
            ok: true,
            message: format!("{model_id} answered in {latency_ms} ms."),
            latency_ms,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::catalog::catalog_providers;

    #[test]
    fn presets_keep_service_order_with_refreshed_catalogs() {
        let presets = catalog_presets(catalog_providers());
        let listed: Vec<String> = presets
            .iter()
            .map(|p| format!("{}|{}|{}", p.id, p.name, p.models.len()))
            .collect();
        // Service order is stable as upstream catalogs change.
        assert_eq!(
            listed,
            [
                "openai|OpenAI|44",
                "anthropic|Anthropic|17",
                "openrouter|OpenRouter|396",
                "deepseek|DeepSeek|2",
                "xai|xAI|4",
                "groq|Groq|7",
                "cerebras|Cerebras|2",
                "fireworks|Fireworks|22",
                "huggingface|Hugging Face|78",
                "kimi-coding|Kimi Coding|4",
                "minimax|MiniMax|3",
                "minimax-cn|MiniMax (China)|3",
                "moonshotai|Moonshot AI|4",
                "moonshotai-cn|Moonshot AI (China)|4",
                "opencode-go|OpenCode Go|34",
                "opencode|OpenCode Zen|72",
                "vercel-ai-gateway|Vercel AI Gateway|301",
                "xiaomi|Xiaomi MiMo|6",
                "xiaomi-token-plan-ams|xiaomi-token-plan-ams|4",
                "xiaomi-token-plan-cn|xiaomi-token-plan-cn|4",
                "xiaomi-token-plan-sgp|xiaomi-token-plan-sgp|4",
                "zai|Z.ai Coding Plan|7",
                "ollama|Ollama (local)|0",
                "lmstudio|LM Studio (local)|0",
            ]
        );
        assert_eq!(presets[0].api, ModelApi::OpenaiResponses);
        assert!(presets.last().unwrap().keyless);
    }

    #[test]
    fn name_ordering() {
        let mut ids = vec![
            "gpt-4o", "GPT-4", "gpt_4", "gpt4", "gpt-4", "o1", "gpt-4.1", "a:b", "a0",
        ];
        ids.sort_by(|a, b| name_order(a, b));
        assert_eq!(
            ids,
            [
                "a0", "a:b", "gpt-4", "GPT-4", "gpt-4.1", "gpt-4o", "gpt4", "gpt_4", "o1"
            ]
        );
    }

    #[test]
    fn parses_model_lists() {
        let models = parse_model_list(&json!({ "data": [
            { "id": "a", "context_length": 1000, "top_provider": { "max_completion_tokens": 50 },
              "architecture": { "input_modalities": ["text", "image"] },
              "supported_parameters": ["reasoning"] },
            { "id": "a" },
            { "name": "named", "display_name": "Shown" },
            { "id": 5, "model": "from-model", "name": "from-model" },
            { "id": "ctl\u{1}" },
            null, 3, [],
            { "id": "b", "context_window": 1.5, "max_context_length": 7, "max_output_tokens": 0 },
        ] }))
        .unwrap();
        let json: Vec<Value> = models.iter().map(UiModel::to_json).collect();
        assert_eq!(
            json,
            [
                json!({ "id": "a", "contextWindow": 1000, "maxTokens": 50, "reasoning": true,
                    "input": ["text", "image"] }),
                json!({ "id": "named", "name": "Shown" }),
                json!({ "id": "from-model" }),
                json!({ "id": "b", "contextWindow": 7 }),
            ]
        );
        assert_eq!(
            parse_model_list(&json!({ "data": null, "models": [{ "name": "x" }] }))
                .unwrap()
                .len(),
            1
        );
        assert_eq!(parse_model_list(&json!([{ "id": "x" }])).unwrap().len(), 1);
        for bad in [json!({}), json!("x"), json!({ "data": {} })] {
            assert!(parse_model_list(&bad).is_err(), "{bad}");
        }
        let many: Vec<Value> = (0..1200)
            .map(|i| json!({ "id": format!("m{i}") }))
            .collect();
        assert_eq!(parse_model_list(&json!(many)).unwrap().len(), MAX_MODELS);
    }

    #[test]
    fn opencode_lists_models_per_plan() {
        let zen = Some("https://opencode.ai/inference/v1/models".to_owned());
        let go = Some("https://opencode.ai/inference/go/v1/models".to_owned());
        for (base, expected) in [
            ("https://opencode.ai/inference/openai/v1", &zen),
            ("https://opencode.ai/inference/openai/v1/", &zen),
            ("https://opencode.ai/inference/anthropic", &zen),
            ("https://opencode.ai/inference/go/openai/v1", &go),
            ("https://opencode.ai/inference/go/anthropic", &go),
            ("https://opencode.ai/inference/go/anthropic/v1", &go),
            // Already list their models at `{base}/models` or `{base}/v1/models`.
            ("https://opencode.ai/inference/v1", &None),
            ("https://opencode.ai/zen/go/v1", &None),
            ("https://opencode.ai/inference/google/v1beta", &None),
            ("https://proxy.example/inference/openai/v1", &None),
        ] {
            assert_eq!(&opencode_models_url(base), expected, "{base}");
        }
    }
}
