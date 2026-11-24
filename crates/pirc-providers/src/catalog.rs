//! pi-ai's built-in model catalog (`getProviders`/`getModels`), embedded as
//! the snapshot `scripts/model-catalog.ts` generates from the pinned pi-ai
//! package plus the separately pinned OpenCode live catalog. It feeds API-key
//! presets and the subscription (OAuth) catalogs.

use std::sync::LazyLock;

use indexmap::IndexMap;
use pirc_protocol::ModelApi;
use serde::Deserialize;
use serde_json::{Map, Value};

const SNAPSHOT: &str = include_str!("../catalog.json");

/// A model's public price, in US dollars per million tokens.
#[derive(Clone, Copy, Debug, PartialEq, Deserialize, serde::Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ModelCost {
    pub input: f64,
    pub output: f64,
    pub cache_read: f64,
    pub cache_write: f64,
}

impl ModelCost {
    /// Whether the source lists the model as free (all zero), which for
    /// subscription catalogs means "no per-token price", not "costs nothing".
    pub fn is_zero(&self) -> bool {
        self.input == 0.0 && self.output == 0.0 && self.cache_read == 0.0 && self.cache_write == 0.0
    }
}

/// One catalog model (pi-ai's `Model`).
#[derive(Clone, Debug, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CatalogModel {
    pub id: String,
    pub name: String,
    pub api: ModelApi,
    pub provider: String,
    pub base_url: String,
    pub reasoning: bool,
    pub input: Vec<String>,
    pub context_window: u64,
    pub max_tokens: u64,
    #[serde(default)]
    pub headers: Option<IndexMap<String, String>>,
    #[serde(default)]
    pub compat: Option<Map<String, Value>>,
    #[serde(default)]
    pub thinking_level_map: Option<IndexMap<String, Option<String>>>,
    /// The catalog's price; absent when the source has none.
    #[serde(default)]
    pub cost: Option<ModelCost>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Snapshot {
    pi_ai: String,
    providers: IndexMap<String, Vec<CatalogModel>>,
}

static CATALOG: LazyLock<Snapshot> =
    LazyLock::new(|| serde_json::from_str(SNAPSHOT).expect("the embedded catalog parses"));

/// The pi-ai version the snapshot was generated from.
pub fn catalog_version() -> &'static str {
    &CATALOG.pi_ai
}

/// Catalog provider IDs in pi-ai's order, followed by additional pinned catalogs.
pub fn catalog_providers() -> impl Iterator<Item = &'static str> {
    CATALOG.providers.keys().map(String::as_str)
}

/// `getModels(provider)`: empty for an unknown provider.
pub fn catalog_models(provider: &str) -> &'static [CatalogModel] {
    CATALOG.providers.get(provider).map_or(&[], Vec::as_slice)
}

/// The catalog price of `provider`/`id`, if the catalog lists one.
pub fn catalog_price(provider: &str, id: &str) -> Option<ModelCost> {
    catalog_models(provider)
        .iter()
        .find(|model| model.id == id)
        .and_then(|model| model.cost)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn snapshot_parses_with_the_subscription_catalogs() {
        assert_eq!(catalog_version(), "1.3.0");
        for provider in ["anthropic", "openai-codex", "github-copilot", "openai"] {
            assert!(!catalog_models(provider).is_empty(), "{provider}");
        }
        assert!(catalog_models("google").is_empty());
        assert!(catalog_models("unknown").is_empty());
        let first = &catalog_models("anthropic")[0];
        assert_eq!(first.provider, "anthropic");
        assert_eq!(first.api, ModelApi::AnthropicMessages);
        // pi-ai's provider order.
        assert_eq!(catalog_providers().next(), Some("anthropic"));
    }

    #[test]
    fn prices_come_from_the_pinned_catalog() {
        let price = catalog_price("anthropic", "claude-fable-5").unwrap();
        assert_eq!(
            price,
            ModelCost {
                input: 10.0,
                output: 50.0,
                cache_read: 1.0,
                cache_write: 12.5
            }
        );
        assert!(!price.is_zero());
        assert_eq!(catalog_price("anthropic", "no-such-model"), None);
        // The live OpenCode catalog carries no prices.
        assert!(
            catalog_models("opencode")
                .iter()
                .all(|model| model.cost.is_none())
        );
    }
}
