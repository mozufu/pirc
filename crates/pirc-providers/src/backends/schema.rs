//! The zod schemas of `backends/service.ts` and `backends/routes.ts`, as
//! checks over JSON values: strict objects, UTF-16 string lengths, numbers
//! that are JavaScript integers, defaults for missing keys only.

use pirc_protocol::{ModelApi, ModelRef, ThinkingLevel};
use serde_json::{Map, Value};

pub use pirc_config::text::utf16_len as len16;

/// A strict object: `None` when `value` is not an object or has a key
/// outside `allowed`.
pub fn strict<'a>(value: &'a Value, allowed: &[&str]) -> Option<&'a Map<String, Value>> {
    let object = value.as_object()?;
    object
        .keys()
        .all(|key| allowed.contains(&key.as_str()))
        .then_some(object)
}

/// An optional field: missing is `Ok(None)`; present (`null` included) must
/// pass `check`.
pub fn optional<T>(
    object: &Map<String, Value>,
    key: &str,
    check: impl FnOnce(&Value) -> Option<T>,
) -> Result<Option<T>, ()> {
    match object.get(key) {
        None => Ok(None),
        Some(value) => check(value).map(Some).ok_or(()),
    }
}

/// `z.string().min(min).max(max)`.
pub fn string(value: &Value, min: usize, max: usize) -> Option<String> {
    let text = value.as_str()?;
    (min..=max).contains(&len16(text)).then(|| text.to_owned())
}

/// `z.number().int().positive().max(max)`.
pub fn positive_int(value: &Value, max: u64) -> Option<u64> {
    let number = value.as_f64()?;
    (number.fract() == 0.0 && number > 0.0 && number <= max as f64).then_some(number as u64)
}

/// The `customId` refinement: a backend ID the settings store accepts.
pub fn custom_id(id: &str) -> bool {
    let mut chars = id.chars();
    let Some(first) = chars.next() else {
        return false;
    };
    first.is_ascii_alphanumeric()
        && id.len() <= 80
        && chars.all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
        && !matches!(
            id,
            "__proto__" | "constructor" | "prototype" | "default-model"
        )
}

/// The `endpoint` schema: an `http:`/`https:` URL (at most 4096
/// characters) without credentials, query or fragment.
pub fn endpoint(value: &Value) -> Option<String> {
    let text = string(value, 0, 4096)?;
    let url = reqwest::Url::parse(&text).ok()?;
    let ok = matches!(url.scheme(), "http" | "https")
        && url.username().is_empty()
        && url.password().is_none_or(str::is_empty)
        && url.fragment().is_none_or(str::is_empty)
        && url.query().is_none_or(str::is_empty);
    ok.then_some(text)
}

/// Whether parsing `value` with a schema holding [`endpoint`] throws: zod
/// still runs the endpoint's refinement after `.url()` failed, and its
/// `new URL()` throws on a string that is not a URL (a 500, not a 400).
pub fn endpoint_throws(value: &Value) -> bool {
    value
        .get("baseUrl")
        .and_then(Value::as_str)
        .is_some_and(|url| value.is_object() && reqwest::Url::parse(url).is_err())
}

/// The APIs a web-managed backend may use (not the Codex subscription's).
pub fn ui_api(value: &Value) -> Option<ModelApi> {
    match value.as_str()? {
        "openai-chat" => Some(ModelApi::OpenaiChat),
        "anthropic-messages" => Some(ModelApi::AnthropicMessages),
        "openai-completions" => Some(ModelApi::OpenaiCompletions),
        "openai-responses" => Some(ModelApi::OpenaiResponses),
        _ => None,
    }
}

/// `uiModel` once parsed: the settings form's editable model fields.
#[derive(Clone, Debug, PartialEq)]
pub struct UiModelInput {
    pub id: String,
    pub name: Option<String>,
    pub context_window: u64,
    pub max_tokens: u64,
    pub reasoning: bool,
    pub input: Vec<String>,
}

/// The `uiModel` schema (strict, with its defaults).
pub fn ui_model(value: &Value) -> Option<UiModelInput> {
    let object = strict(
        value,
        &[
            "id",
            "name",
            "contextWindow",
            "maxTokens",
            "reasoning",
            "input",
        ],
    )?;
    let id = string(object.get("id")?, 1, 200)?;
    let name = optional(object, "name", |v| string(v, 1, 200)).ok()?;
    let context_window = optional(object, "contextWindow", |v| positive_int(v, 100_000_000))
        .ok()?
        .unwrap_or(200_000);
    let max_tokens = optional(object, "maxTokens", |v| positive_int(v, 10_000_000))
        .ok()?
        .unwrap_or(32_000);
    let reasoning = optional(object, "reasoning", Value::as_bool)
        .ok()?
        .unwrap_or(false);
    let input = optional(object, "input", |value| {
        let items = value.as_array()?;
        if !(1..=2).contains(&items.len()) {
            return None;
        }
        items
            .iter()
            .map(|item| match item.as_str() {
                Some(kind @ ("text" | "image")) => Some(kind.to_owned()),
                _ => None,
            })
            .collect::<Option<Vec<_>>>()
    })
    .ok()?
    .unwrap_or_else(|| vec!["text".to_owned()]);
    Some(UiModelInput {
        id,
        name,
        context_window,
        max_tokens,
        reasoning,
        input,
    })
}

/// The connection fields shared by a saved backend and a probe. No
/// `Debug`: it holds the typed key.
#[derive(Clone, PartialEq)]
pub struct Connection {
    pub api: ModelApi,
    pub base_url: String,
    pub opencode_go: Option<bool>,
    /// `None`: not given; `Some("")`: cleared.
    pub api_key: Option<String>,
    pub preset: Option<String>,
}

fn connection(object: &Map<String, Value>) -> Option<Connection> {
    Some(Connection {
        api: ui_api(object.get("api")?)?,
        base_url: endpoint(object.get("baseUrl")?)?,
        opencode_go: optional(object, "opencodeGo", Value::as_bool).ok()?,
        api_key: optional(object, "apiKey", |v| string(v, 0, 32_768)).ok()?,
        preset: optional(object, "preset", |v| string(v, 0, 100)).ok()?,
    })
}

/// `customProviderSchema`: a web-managed backend as the form saves it.
#[derive(Clone, PartialEq)]
pub struct CustomProvider {
    pub connection: Connection,
    pub models: Vec<UiModelInput>,
}

pub fn custom_provider(value: &Value) -> Option<CustomProvider> {
    let object = strict(
        value,
        &["api", "baseUrl", "opencodeGo", "apiKey", "preset", "models"],
    )?;
    let connection = connection(object)?;
    let items = object.get("models")?.as_array()?;
    if !(1..=200).contains(&items.len()) {
        return None;
    }
    let models = items.iter().map(ui_model).collect::<Option<Vec<_>>>()?;
    let unique = models
        .iter()
        .enumerate()
        .all(|(index, model)| models[..index].iter().all(|other| other.id != model.id));
    unique.then_some(CustomProvider { connection, models })
}

/// `probeSchema`: an unsaved form, optionally naming the saved backend it edits.
#[derive(Clone, PartialEq)]
pub struct Probe {
    pub connection: Connection,
    pub backend_id: Option<String>,
}

pub fn probe(value: &Value) -> Option<Probe> {
    probe_with(value, &[]).map(|(probe, _)| probe)
}

/// `testSchema`: a probe with the one model to try.
pub fn connection_test(value: &Value) -> Option<(Probe, UiModelInput)> {
    let (probe, object) = probe_with(value, &["model"])?;
    Some((probe, ui_model(object.get("model")?)?))
}

fn probe_with<'a>(value: &'a Value, extra: &[&str]) -> Option<(Probe, &'a Map<String, Value>)> {
    let mut allowed = vec![
        "api",
        "baseUrl",
        "opencodeGo",
        "apiKey",
        "preset",
        "backendId",
    ];
    allowed.extend_from_slice(extra);
    let object = strict(value, &allowed)?;
    let probe = Probe {
        connection: connection(object)?,
        backend_id: optional(object, "backendId", |v| string(v, 0, 100)).ok()?,
    };
    Some((probe, object))
}

/// `modelRefSchema.strict()`.
pub fn model_ref(value: &Value) -> Option<ModelRef> {
    let object = strict(value, &["provider", "id", "thinking"])?;
    let thinking = optional(object, "thinking", |value| {
        serde_json::from_value::<ThinkingLevel>(value.clone()).ok()
    })
    .ok()?;
    Some(ModelRef {
        provider: object.get("provider")?.as_str()?.to_owned(),
        id: object.get("id")?.as_str()?.to_owned(),
        thinking,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn backend_ids() {
        for id in ["a", "A1", "my.backend_2-x", &"a".repeat(80)] {
            assert!(custom_id(id), "{id}");
        }
        for id in [
            "",
            "-a",
            ".a",
            "a b",
            "a/b",
            "é",
            &"a".repeat(81),
            "default-model",
            "constructor",
        ] {
            assert!(!custom_id(id), "{id}");
        }
    }

    #[test]
    fn endpoints() {
        for url in [
            "http://localhost:11434/v1",
            "https://api.example.com",
            "https://a.example/?",
            "https://a.example/#",
        ] {
            assert!(endpoint(&json!(url)).is_some(), "{url}");
        }
        for url in [
            "ftp://a.example",
            "https://u:p@a.example",
            "https://u@a.example",
            "https://a.example/?q=1",
            "https://a.example/#x",
            "not a url",
        ] {
            assert!(endpoint(&json!(url)).is_none(), "{url}");
        }
        let long = format!("https://a.example/{}", "x".repeat(4096));
        assert!(endpoint(&json!(long)).is_none());
    }

    #[test]
    fn unparsable_endpoints_throw() {
        assert!(endpoint_throws(&json!({ "baseUrl": "not a url" })));
        assert!(!endpoint_throws(&json!({ "baseUrl": "ftp://a.example" })));
        assert!(!endpoint_throws(&json!({ "baseUrl": 5 })));
        assert!(!endpoint_throws(&json!(["not a url"])));
    }

    #[test]
    fn ui_models_apply_defaults_and_limits() {
        assert_eq!(
            ui_model(&json!({ "id": "m" })),
            Some(UiModelInput {
                id: "m".to_owned(),
                name: None,
                context_window: 200_000,
                max_tokens: 32_000,
                reasoning: false,
                input: vec!["text".to_owned()],
            })
        );
        let full = ui_model(&json!({ "id": "m", "name": "M", "contextWindow": 5.0,
            "maxTokens": 10_000_000, "reasoning": true, "input": ["image", "text"] }))
        .unwrap();
        assert_eq!((full.context_window, full.max_tokens), (5, 10_000_000));
        for bad in [
            json!({ "id": "" }),
            json!({ "id": "m", "extra": 1 }),
            json!({ "id": "m", "name": "" }),
            json!({ "id": "m", "name": null }),
            json!({ "id": "m", "contextWindow": 1.5 }),
            json!({ "id": "m", "contextWindow": 0 }),
            json!({ "id": "m", "maxTokens": 10_000_001 }),
            json!({ "id": "m", "input": [] }),
            json!({ "id": "m", "input": ["text", "image", "text"] }),
            json!({ "id": "m", "input": ["audio"] }),
            json!({ "id": "m", "reasoning": "yes" }),
            json!("m"),
        ] {
            assert!(ui_model(&bad).is_none(), "{bad}");
        }
    }

    #[test]
    fn providers_need_unique_models() {
        let base = json!({ "api": "openai-completions", "baseUrl": "https://a.example",
            "models": [{ "id": "a" }, { "id": "b" }] });
        assert!(custom_provider(&base).is_some());
        let mut duplicate = base.clone();
        duplicate["models"] = json!([{ "id": "a" }, { "id": "a" }]);
        assert!(custom_provider(&duplicate).is_none());
        let mut codex = base.clone();
        codex["api"] = json!("openai-codex-responses");
        assert!(custom_provider(&codex).is_none());
        let mut extra = base;
        extra["backendId"] = json!("x");
        assert!(custom_provider(&extra).is_none());
    }

    #[test]
    fn probes_and_tests() {
        let probe_body = json!({ "api": "anthropic-messages", "baseUrl": "https://a.example",
            "backendId": "x", "apiKey": "" });
        let parsed = probe(&probe_body).unwrap();
        assert_eq!(parsed.backend_id.as_deref(), Some("x"));
        assert_eq!(parsed.connection.api_key.as_deref(), Some(""));
        assert!(connection_test(&probe_body).is_none());
        let mut test = probe_body.clone();
        test["model"] = json!({ "id": "m" });
        assert!(connection_test(&test).is_some());
        assert!(probe(&test).is_none());
    }

    #[test]
    fn model_refs() {
        assert!(model_ref(&json!({ "provider": "p", "id": "m", "thinking": "high" })).is_some());
        assert!(model_ref(&json!({ "provider": "p", "id": "m", "x": 1 })).is_none());
        assert!(model_ref(&json!({ "provider": "p", "id": "m", "thinking": "max" })).is_some());
        assert!(model_ref(&json!({ "provider": "p", "id": "m", "thinking": "huge" })).is_none());
        assert!(model_ref(&json!({ "provider": "p" })).is_none());
    }
}
