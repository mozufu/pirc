//! Neutral model identifiers and compatibility configuration DTOs.
//! Provider/model configuration is not guaranteed to be secret-free.

use indexmap::IndexMap;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum ModelApi {
    /// Legacy name of `openai-completions`.
    OpenaiChat,
    AnthropicMessages,
    OpenaiCompletions,
    OpenaiResponses,
    OpenaiCodexResponses,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ThinkingLevel {
    Off,
    Minimal,
    Low,
    Medium,
    High,
    Xhigh,
    Max,
}

/// The reasoning levels in increasing effort; `xhigh` and `max` are opt-in.
pub const THINKING_LEVELS: [ThinkingLevel; 6] = [
    ThinkingLevel::Minimal,
    ThinkingLevel::Low,
    ThinkingLevel::Medium,
    ThinkingLevel::High,
    ThinkingLevel::Xhigh,
    ThinkingLevel::Max,
];

impl ThinkingLevel {
    /// The serialized name (`"max"`), also used as the `thinkingLevelMap` key.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Off => "off",
            Self::Minimal => "minimal",
            Self::Low => "low",
            Self::Medium => "medium",
            Self::High => "high",
            Self::Xhigh => "xhigh",
            Self::Max => "max",
        }
    }
}

/// The levels a reasoning model offers, in order. A `thinkingLevelMap` entry
/// hides a level when it is `null`; missing `off` through `high` entries use
/// the provider default, while `xhigh` and `max` must be mapped explicitly.
pub fn model_thinking_levels(
    reasoning: bool,
    map: Option<&IndexMap<String, Option<String>>>,
) -> Vec<ThinkingLevel> {
    if !reasoning {
        return Vec::new();
    }
    THINKING_LEVELS
        .into_iter()
        .filter(|level| supports(*level, map))
        .collect()
}

/// Whether `model` accepts `level` without clamping.
pub fn supports_thinking_level(
    level: ThinkingLevel,
    map: Option<&IndexMap<String, Option<String>>>,
) -> bool {
    if level == ThinkingLevel::Off {
        return true;
    }
    supports(level, map)
}

fn supports(level: ThinkingLevel, map: Option<&IndexMap<String, Option<String>>>) -> bool {
    match (level, map) {
        (ThinkingLevel::Off, _) => true,
        // `xhigh` and `max` are opt-in: only an explicit string offers them.
        (ThinkingLevel::Xhigh | ThinkingLevel::Max, Some(map)) => {
            map.get(level.as_str()).is_some_and(Option::is_some)
        }
        (ThinkingLevel::Xhigh | ThinkingLevel::Max, None) => false,
        (_, Some(map)) => map.get(level.as_str()) != Some(&None),
        (_, None) => true,
    }
}

/// The level a request uses: `level` itself when supported, else the nearest
/// lower supported level (falling back upward when none is lower). `Xhigh` on
/// a model that only offers `max` keeps the old meaning and uses `Max`.
/// `None` when the model has no thinking or the request is `Off`.
pub fn effective_thinking_level(
    reasoning: bool,
    map: Option<&IndexMap<String, Option<String>>>,
    level: ThinkingLevel,
) -> Option<ThinkingLevel> {
    if !reasoning || level == ThinkingLevel::Off {
        return None;
    }
    if supports(level, map) {
        return Some(level);
    }
    if level == ThinkingLevel::Xhigh && supports(ThinkingLevel::Max, map) {
        return Some(ThinkingLevel::Max);
    }
    let requested = THINKING_LEVELS
        .iter()
        .position(|candidate| *candidate == level)?;
    if let Some(lower) = THINKING_LEVELS[..requested]
        .iter()
        .rev()
        .find(|candidate| supports(**candidate, map))
    {
        return Some(*lower);
    }
    THINKING_LEVELS[requested + 1..]
        .iter()
        .find(|candidate| supports(**candidate, map))
        .copied()
}

/// Provider configuration as data only. May contain credentials in headers or `api_key`.
/// Runtime clients, credential lookup and persistence belong to the host/transport layer.
#[derive(Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Provider {
    pub api: ModelApi,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pi_provider: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub opencode_go: Option<bool>,
    pub base_url: String,
    #[serde(default)]
    pub headers: IndexMap<String, String>,
    #[serde(default)]
    pub compat: Map<String, Value>,
    pub models: Vec<Model>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub api_key: Option<String>,
}

/// Model metadata and optional endpoint overrides; headers may contain credentials.
#[derive(Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Model {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub api: Option<ModelApi>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub base_url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub canonical_provider: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub headers: Option<IndexMap<String, String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub thinking_level_map: Option<IndexMap<String, Option<String>>>,
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default = "default_context_window")]
    pub context_window: u64,
    #[serde(default = "default_max_tokens")]
    pub max_tokens: u64,
    #[serde(default)]
    pub reasoning: bool,
    #[serde(default = "default_input")]
    pub input: Vec<String>,
    #[serde(default)]
    pub compat: Map<String, Value>,
}

impl Model {
    /// The reasoning levels this model offers, in order; empty without
    /// thinking.
    pub fn thinking_levels(&self) -> Vec<ThinkingLevel> {
        model_thinking_levels(self.reasoning, self.thinking_level_map.as_ref())
    }

    /// The level a request uses after clamping to this model's levels.
    pub fn effective_thinking_level(&self, level: ThinkingLevel) -> Option<ThinkingLevel> {
        effective_thinking_level(self.reasoning, self.thinking_level_map.as_ref(), level)
    }
}

fn default_context_window() -> u64 {
    200_000
}
fn default_max_tokens() -> u64 {
    32_000
}
fn default_input() -> Vec<String> {
    vec!["text".to_owned()]
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ModelRef {
    pub provider: String,
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub thinking: Option<ThinkingLevel>,
}

/// Debug output never shows credentials.
impl std::fmt::Debug for Provider {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Provider")
            .field("api", &self.api)
            .field("pi_provider", &self.pi_provider)
            .field("opencode_go", &self.opencode_go)
            .field("base_url", &self.base_url)
            .field("headers", &self.headers.keys().collect::<Vec<_>>())
            .field("compat", &self.compat)
            .field("models", &self.models)
            .field("api_key", &self.api_key.as_ref().map(|_| "<redacted>"))
            .finish()
    }
}

impl std::fmt::Debug for Model {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let headers = self.headers.as_ref().map(|h| h.keys().collect::<Vec<_>>());
        f.debug_struct("Model")
            .field("api", &self.api)
            .field("base_url", &self.base_url)
            .field("canonical_provider", &self.canonical_provider)
            .field("headers", &headers)
            .field("thinking_level_map", &self.thinking_level_map)
            .field("id", &self.id)
            .field("name", &self.name)
            .field("context_window", &self.context_window)
            .field("max_tokens", &self.max_tokens)
            .field("reasoning", &self.reasoning)
            .field("input", &self.input)
            .field("compat", &self.compat)
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn map(entries: &[(&str, Option<&str>)]) -> Option<IndexMap<String, Option<String>>> {
        Some(
            entries
                .iter()
                .map(|(level, effort)| ((*level).to_owned(), effort.map(str::to_owned)))
                .collect(),
        )
    }

    fn model(reasoning: bool, map: Option<IndexMap<String, Option<String>>>) -> Model {
        Model {
            api: None,
            base_url: None,
            canonical_provider: None,
            headers: None,
            thinking_level_map: map,
            id: "m".to_owned(),
            name: None,
            context_window: 1,
            max_tokens: 1,
            reasoning,
            input: vec!["text".to_owned()],
            compat: Map::new(),
        }
    }

    #[test]
    fn max_serializes_and_orders_after_xhigh() {
        assert_eq!(
            serde_json::to_value(ThinkingLevel::Max).unwrap(),
            json!("max")
        );
        assert_eq!(
            THINKING_LEVELS.map(ThinkingLevel::as_str),
            ["minimal", "low", "medium", "high", "xhigh", "max"]
        );
    }

    #[test]
    fn levels_follow_the_map_and_non_reasoning_models_have_none() {
        assert_eq!(
            model(false, map(&[("max", Some("max"))])).thinking_levels(),
            []
        );
        assert_eq!(
            model(true, None).thinking_levels(),
            [
                ThinkingLevel::Minimal,
                ThinkingLevel::Low,
                ThinkingLevel::Medium,
                ThinkingLevel::High
            ]
        );
        assert_eq!(
            model(true, map(&[("minimal", None), ("max", Some("max"))])).thinking_levels(),
            [
                ThinkingLevel::Low,
                ThinkingLevel::Medium,
                ThinkingLevel::High,
                ThinkingLevel::Max
            ]
        );
        // `xhigh` and `max` are opt-in, a null mapping hides a default level.
        assert_eq!(
            model(true, map(&[("xhigh", Some("xhigh")), ("max", Some("max"))])).thinking_levels(),
            [
                ThinkingLevel::Minimal,
                ThinkingLevel::Low,
                ThinkingLevel::Medium,
                ThinkingLevel::High,
                ThinkingLevel::Xhigh,
                ThinkingLevel::Max
            ]
        );
    }

    #[test]
    fn unsupported_levels_clamp_to_the_nearest_lower_one() {
        let clamped = |levels: Option<IndexMap<String, Option<String>>>, level| {
            model(true, levels).effective_thinking_level(level)
        };
        let max_only = || map(&[("max", Some("max"))]);
        assert_eq!(
            clamped(max_only(), ThinkingLevel::Xhigh),
            Some(ThinkingLevel::Max)
        );
        assert_eq!(
            clamped(max_only(), ThinkingLevel::Max),
            Some(ThinkingLevel::Max)
        );
        assert_eq!(
            clamped(map(&[("xhigh", Some("xhigh"))]), ThinkingLevel::Max),
            Some(ThinkingLevel::Xhigh)
        );
        assert_eq!(clamped(None, ThinkingLevel::Max), Some(ThinkingLevel::High));
        assert_eq!(
            clamped(map(&[("low", None), ("medium", None)]), ThinkingLevel::Low),
            Some(ThinkingLevel::Minimal)
        );
        // Only levels above the request exist: clamp upward.
        assert_eq!(
            clamped(
                map(&[
                    ("minimal", None),
                    ("low", None),
                    ("medium", None),
                    ("high", Some("high"))
                ]),
                ThinkingLevel::Minimal
            ),
            Some(ThinkingLevel::High)
        );
        assert_eq!(clamped(None, ThinkingLevel::Off), None);
        assert_eq!(
            model(false, None).effective_thinking_level(ThinkingLevel::High),
            None
        );
    }
}
