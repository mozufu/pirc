//! Repository memory settings (`features.workspaceMemory`). Fields are
//! parsed independently; a malformed control flag fails closed.

use pirc_protocol::ThinkingLevel;
use serde_json::{Map, Value};

use crate::config::thinking_level;

pub(crate) const THINKING_CHOICES: [&str; 7] =
    ["off", "minimal", "low", "medium", "high", "xhigh", "max"];
pub(crate) const MODEL_KEYS: [&str; 3] = ["provider", "id", "thinking"];
pub(crate) const WORKSPACE_KEYS: [&str; 7] = [
    "enabled",
    "passive",
    "model",
    "fallbackModels",
    "maxTokens",
    "rateLimitCooldownMs",
    "missingModelPolicy",
];

/// `ModelChoice`.
#[derive(Clone, Debug, PartialEq)]
pub struct ModelChoice {
    pub provider: String,
    pub id: String,
    pub thinking: Option<ThinkingLevel>,
}

/// `workspaceMemorySchema`.
#[derive(Clone, Debug, PartialEq)]
pub struct WorkspaceSettings {
    /// Whether repository extraction and its prompt block run.
    pub enabled: bool,
    /// Budget for the notes shown to the session, and the extraction's target.
    pub max_tokens: u64,
}

/// The repository-memory settings.
#[derive(Clone, Debug, PartialEq)]
pub struct WorkspaceMemoryConfig {
    /// Automatic extraction does not start; commands still work.
    pub passive: bool,
    pub model: Option<ModelChoice>,
    pub fallback_models: Vec<ModelChoice>,
    /// `missingModelPolicy: 'error'`: a configured model (preferred or
    /// fallback) that does not resolve stops extraction with a visible
    /// error, instead of falling back to the session model.
    pub strict_models: bool,
    pub rate_limit_cooldown_ms: u64,
    pub workspace: WorkspaceSettings,
}

impl Default for WorkspaceMemoryConfig {
    fn default() -> Self {
        Self {
            passive: false,
            model: None,
            fallback_models: Vec::new(),
            strict_models: false,
            rate_limit_cooldown_ms: 900_000,
            workspace: WorkspaceSettings {
                enabled: true,
                max_tokens: 3_000,
            },
        }
    }
}

/// A model choice of valid settings.
pub(crate) fn model_choice(value: &Value) -> ModelChoice {
    let text = |key: &str| value[key].as_str().unwrap_or_default().to_owned();
    ModelChoice {
        provider: text("provider"),
        id: text("id"),
        thinking: value["thinking"].as_str().and_then(thinking_level),
    }
}

fn valid_model(v: &Value) -> bool {
    v["provider"].as_str().is_some_and(|s| !s.is_empty())
        && v["id"].as_str().is_some_and(|s| !s.is_empty())
        && v.get("thinking")
            .is_none_or(|t| t.as_str().is_some_and(|s| THINKING_CHOICES.contains(&s)))
}

/// `workspaceConfigFrom(features)`.
pub fn workspace_config_from(features: &Map<String, Value>) -> WorkspaceMemoryConfig {
    let mut config = WorkspaceMemoryConfig::default();
    let Some(raw) = features.get("workspaceMemory") else {
        return config;
    };
    if !raw.is_object() {
        // A malformed object must never turn repository memory on.
        config.workspace.enabled = false;
        config.passive = true;
        return config;
    }
    let boolean = |value: &Value, key: &str, out: &mut bool, fallback: bool| {
        if let Some(value) = value.get(key) {
            *out = value.as_bool().unwrap_or(fallback);
        }
    };
    let number = |value: &Value, key: &str| {
        value
            .get(key)
            .and_then(Value::as_f64)
            .filter(|v| v.is_finite() && *v > 0.0 && v.fract() == 0.0 && *v <= u64::MAX as f64)
    };
    let positive = |value: &Value, key: &str, out: &mut u64| {
        if let Some(value) = number(value, key) {
            *out = value as u64;
        }
    };
    boolean(raw, "enabled", &mut config.workspace.enabled, false);
    boolean(raw, "passive", &mut config.passive, true);
    positive(raw, "maxTokens", &mut config.workspace.max_tokens);
    positive(
        raw,
        "rateLimitCooldownMs",
        &mut config.rate_limit_cooldown_ms,
    );
    config.strict_models = raw["missingModelPolicy"] == "error";
    config.model = raw
        .get("model")
        .filter(|v| valid_model(v))
        .map(model_choice);
    if let Some(models) = raw.get("fallbackModels").and_then(Value::as_array) {
        config.fallback_models = models
            .iter()
            .filter(|v| valid_model(v))
            .map(model_choice)
            .collect();
    }
    config
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn parse(memory: Value) -> WorkspaceMemoryConfig {
        let features = json!({ "workspaceMemory": memory });
        workspace_config_from(features.as_object().unwrap())
    }

    #[test]
    fn reads_valid_settings_and_resets_invalid_ones() {
        assert_eq!(
            workspace_config_from(&Map::new()),
            WorkspaceMemoryConfig::default()
        );
        let disabled = parse(json!({ "enabled": false }));
        assert!(!disabled.workspace.enabled);
        assert!(disabled.fallback_models.is_empty());
        let reset = parse(json!({
            "enabled": false, "maxTokens": 42,
            "fallbackModels": [{ "provider": "fake", "id": "model" },
                { "provider": "", "id": "private-model-value" }],
        }));
        assert!(!reset.workspace.enabled);
        assert_eq!(reset.workspace.max_tokens, 42);
        assert_eq!(reset.fallback_models.len(), 1);
        let unknown = parse(json!({
            "enabled": false, "maxTokens": 123, "legacy": "secret-value",
            "model": { "provider": "p", "id": "m", "thinking": "max", "extra": "secret-value" },
            "fallbackModels": [{ "provider": "p", "id": "fallback", "typo": "secret-value" }],
        }));
        assert!(!unknown.workspace.enabled);
        assert_eq!(unknown.workspace.max_tokens, 123);
        assert_eq!(unknown.model.unwrap().thinking, Some(ThinkingLevel::Max));
        assert_eq!(
            unknown.fallback_models,
            [ModelChoice {
                provider: "p".to_owned(),
                id: "fallback".to_owned(),
                thinking: None
            }]
        );
        for value in [json!(false), json!([]), json!("private-whole-object")] {
            let config = parse(value);
            assert!(!config.workspace.enabled && config.passive);
        }
    }

    #[test]
    fn reads_the_missing_model_policy() {
        assert!(!WorkspaceMemoryConfig::default().strict_models);
        assert!(!parse(json!({ "missingModelPolicy": "fallback" })).strict_models);
        assert!(parse(json!({ "missingModelPolicy": "error" })).strict_models);
    }

    #[test]
    fn malformed_control_flags_fail_closed_without_resetting_valid_fields() {
        let config = parse(json!({"enabled": "bad", "maxTokens": 123}));
        assert!(!config.workspace.enabled);
        assert_eq!(config.workspace.max_tokens, 123);
        for input in [json!({ "passive": "bad" }), json!(false)] {
            assert!(parse(input).passive);
        }
    }

    #[test]
    fn reads_workspace_budget_and_cooldown() {
        let config = parse(json!({
            "maxTokens": 40000,
            "rateLimitCooldownMs": 60000,
        }));
        assert_eq!(config.workspace.max_tokens, 40000);
        assert_eq!(config.rate_limit_cooldown_ms, 60000);
    }
}
