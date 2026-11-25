//! Runtime inference inputs, independent of provider catalogs and persistence DTOs.
//!
//! Resolution preserves the selected route's legacy behavior. It deliberately
//! does not parse URLs, resolve placeholders or validate headers: those operations
//! remain lazy so stale/cancelled requests never invoke host lookup callbacks.

use indexmap::IndexMap;
use pirc_llm_types::{Message, Model, ModelApi, Provider, ThinkingLevel, ToolChoice, ToolSpec};
use serde_json::{Map, Value};

use crate::Route;

/// A single selected endpoint, not a provider catalog. Headers may contain secrets.
#[derive(Clone, PartialEq)]
pub struct ResolvedEndpoint {
    pub api: ModelApi,
    pub canonical_provider: String,
    /// Actual POST base URL for this route.
    pub base_url: String,
    /// Base URL used for OpenCode routing detection. Native routes historically
    /// honor a model URL here, but not for the actual POST destination.
    pub opencode_base_url: String,
    pub headers: IndexMap<String, String>,
    pub compat: Map<String, Value>,
    pub opencode_go: Option<bool>,
    /// Managed subscription routes require a resolved credential rather than a keyless placeholder.
    pub managed_credentials: bool,
}

impl ResolvedEndpoint {
    /// Construct a standalone endpoint without a catalog or host-specific defaults.
    /// Customize headers/compatibility explicitly before borrowing it in a request.
    pub fn new(
        api: ModelApi,
        canonical_provider: impl Into<String>,
        base_url: impl Into<String>,
    ) -> Self {
        let base_url = base_url.into();
        Self {
            api,
            canonical_provider: canonical_provider.into(),
            opencode_base_url: base_url.clone(),
            base_url,
            headers: IndexMap::new(),
            compat: Map::new(),
            opencode_go: None,
            managed_credentials: false,
        }
    }

    /// Project configuration DTOs once, preserving native/Pi override differences.
    pub fn from_legacy(
        route: Route,
        provider_name: &str,
        provider: &Provider,
        model: &Model,
    ) -> Self {
        let native = matches!(route, Route::Chat | Route::NativeAnthropic);
        let effective_url = model.base_url.as_ref().unwrap_or(&provider.base_url);
        let mut headers = provider.headers.clone();
        if !native && let Some(extra) = &model.headers {
            headers.extend(
                extra
                    .iter()
                    .map(|(key, value)| (key.clone(), value.clone())),
            );
        }
        let mut compat = provider.compat.clone();
        compat.extend(
            model
                .compat
                .iter()
                .map(|(key, value)| (key.clone(), value.clone())),
        );
        Self {
            api: model.api.unwrap_or(provider.api),
            canonical_provider: model
                .canonical_provider
                .as_ref()
                .or(provider.pi_provider.as_ref())
                .map_or_else(|| provider_name.to_owned(), Clone::clone),
            base_url: if native {
                provider.base_url.clone()
            } else {
                effective_url.clone()
            },
            opencode_base_url: effective_url.clone(),
            headers,
            compat,
            opencode_go: provider.opencode_go,
            managed_credentials: provider
                .pi_provider
                .as_deref()
                .is_some_and(|name| !name.is_empty()),
        }
    }
}

/// Runtime metadata for one model; no endpoint overrides, keys or model list.
#[derive(Clone, Debug, PartialEq)]
pub struct ResolvedModel {
    pub id: String,
    pub reasoning: bool,
    pub thinking_level_map: Option<IndexMap<String, Option<String>>>,
    pub input: Vec<String>,
    pub max_tokens: u64,
}

impl ResolvedModel {
    /// Construct metadata for a text-only model with reasoning disabled.
    pub fn new(id: impl Into<String>, max_tokens: u64) -> Self {
        Self {
            id: id.into(),
            reasoning: false,
            thinking_level_map: None,
            input: vec!["text".to_owned()],
            max_tokens,
        }
    }

    /// The reasoning levels this model offers, in order.
    pub fn thinking_levels(&self) -> Vec<ThinkingLevel> {
        pirc_llm_types::model_thinking_levels(self.reasoning, self.thinking_level_map.as_ref())
    }

    /// Whether this model accepts `level` without clamping.
    pub fn supports_thinking_level(&self, level: ThinkingLevel) -> bool {
        pirc_llm_types::supports_thinking_level(level, self.thinking_level_map.as_ref())
    }

    /// The level a request uses after clamping to this model's levels.
    pub fn effective_thinking_level(&self, level: ThinkingLevel) -> Option<ThinkingLevel> {
        pirc_llm_types::effective_thinking_level(
            self.reasoning,
            self.thinking_level_map.as_ref(),
            level,
        )
    }
}

impl From<&Model> for ResolvedModel {
    fn from(model: &Model) -> Self {
        Self {
            id: model.id.clone(),
            reasoning: model.reasoning,
            thinking_level_map: model.thinking_level_map.clone(),
            input: model.input.clone(),
            max_tokens: model.max_tokens,
        }
    }
}

/// Borrowed request authentication. Debug never prints a token.
#[derive(Clone, Copy, Default, PartialEq, Eq)]
pub enum Auth<'a> {
    #[default]
    None,
    Key(&'a str),
}

impl<'a> Auth<'a> {
    pub fn as_key(self) -> Option<&'a str> {
        match self {
            Self::None => None,
            Self::Key(key) => Some(key),
        }
    }
}

impl std::fmt::Debug for Auth<'_> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::None => f.write_str("None"),
            Self::Key(_) => f.write_str("Key(<redacted>)"),
        }
    }
}

/// Conversation inputs are borrowed; constructing a request does not clone history.
#[derive(Clone, Copy, Default)]
pub struct Context<'a> {
    pub system_prompt: &'a str,
    pub messages: &'a [Message],
    pub tools: &'a [ToolSpec],
}

/// Per-run policy, separate from endpoint/model configuration.
#[derive(Clone, Copy)]
pub struct RequestOptions<'a> {
    pub thinking: ThinkingLevel,
    /// Host-supplied opaque cache identity.
    pub session_id: &'a str,
    /// Exact host fingerprint, only used by the Codex route.
    pub codex_user_agent: &'a str,
    pub max_tokens: Option<u64>,
    pub tool_choice: Option<ToolChoice>,
    /// Explicit host lookup; the transport does not read environment variables.
    pub resolve_variable: &'a (dyn Fn(&str) -> Option<String> + Sync),
}

impl Default for RequestOptions<'_> {
    fn default() -> Self {
        Self {
            thinking: ThinkingLevel::Off,
            session_id: "",
            codex_user_agent: "",
            max_tokens: None,
            tool_choice: None,
            resolve_variable: &|_| None,
        }
    }
}

/// Inference input without a full Provider/Model catalog DTO.
///
/// Endpoint/model configuration can be retained across runs while history and
/// cache identity are borrowed for each call. Authentication is interpreted by
/// the selected wire API (for example an Anthropic key is not a Bearer header).
///
/// ```
/// use pirc_llm::{Auth, Context, ResolvedEndpoint, ResolvedModel, RunRequest};
/// use pirc_llm::types::ModelApi;
///
/// let endpoint = ResolvedEndpoint::new(
///     ModelApi::OpenaiCompletions, "openai", "https://api.openai.com/v1",
/// );
/// let model = ResolvedModel::new("host-selected-model", 4096);
/// let mut request = RunRequest::new("my-provider", &endpoint, &model);
/// request.context = Context { system_prompt: "Be helpful", ..Context::default() };
/// request.options.session_id = "host-owned-cache-identity";
/// request.auth = Auth::Key("host-resolved-key");
/// // transport.run_request(Route::Completions, &request, cancel, &mut on_delta).await;
/// ```
pub struct RunRequest<'a> {
    pub provider_name: &'a str,
    pub endpoint: &'a ResolvedEndpoint,
    pub model: &'a ResolvedModel,
    pub auth: Auth<'a>,
    pub context: Context<'a>,
    pub options: RequestOptions<'a>,
}

impl<'a> RunRequest<'a> {
    /// Start with borrowed endpoint/model metadata and empty/default run inputs.
    pub fn new(
        provider_name: &'a str,
        endpoint: &'a ResolvedEndpoint,
        model: &'a ResolvedModel,
    ) -> Self {
        Self {
            provider_name,
            endpoint,
            model,
            auth: Auth::None,
            context: Context::default(),
            options: RequestOptions::default(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn route_projection_preserves_native_and_pi_overrides() {
        let provider: Provider = serde_json::from_value(json!({
            "api":"openai-chat","baseUrl":"https://provider.invalid",
            "piProvider":"canonical","headers":{"x-test":"provider"},
            "compat":{"flag":false,"kept":1},
            "models":[{"id":"m","baseUrl":"https://model.invalid/{VARIABLE}",
                "headers":{"x-test":"model"},"compat":{"flag":true}}]
        }))
        .unwrap();
        let model = &provider.models[0];
        for route in [Route::Chat, Route::NativeAnthropic] {
            let endpoint = ResolvedEndpoint::from_legacy(route, "host", &provider, model);
            assert_eq!(endpoint.base_url, provider.base_url);
            assert_eq!(
                endpoint.opencode_base_url,
                model.base_url.as_deref().unwrap()
            );
            assert_eq!(endpoint.headers["x-test"], "provider");
            assert_eq!(endpoint.compat["flag"], true);
            assert_eq!(endpoint.compat["kept"], 1);
        }
        let endpoint = ResolvedEndpoint::from_legacy(Route::Completions, "host", &provider, model);
        assert_eq!(endpoint.base_url, model.base_url.as_deref().unwrap());
        assert_eq!(endpoint.headers["x-test"], "model");
        assert_eq!(endpoint.canonical_provider, "canonical");
    }

    #[test]
    fn runtime_request_does_not_need_a_catalog_or_owned_conversation() {
        let endpoint = ResolvedEndpoint {
            api: ModelApi::OpenaiCompletions,
            canonical_provider: "openai".to_owned(),
            base_url: "https://endpoint.invalid".to_owned(),
            opencode_base_url: "https://endpoint.invalid".to_owned(),
            headers: IndexMap::new(),
            compat: Map::new(),
            opencode_go: None,
            managed_credentials: false,
        };
        let model = ResolvedModel {
            id: "model".to_owned(),
            reasoning: false,
            thinking_level_map: None,
            input: vec!["text".to_owned()],
            max_tokens: 1024,
        };
        let history = [Message::User {
            content: pirc_llm_types::UserContent::Text("hello".to_owned()),
            timestamp: 0,
        }];
        let cache_id = String::from("borrowed-cache");
        let mut request = RunRequest::new("host", &endpoint, &model);
        request.context.messages = &history;
        request.options.session_id = &cache_id;
        assert!(std::ptr::eq(
            request.context.messages.as_ptr(),
            history.as_ptr()
        ));
        assert_eq!(request.options.session_id.as_ptr(), cache_id.as_ptr());
        assert_eq!(request.auth, Auth::None);
    }

    #[test]
    fn auth_debug_is_redacted() {
        assert_eq!(format!("{:?}", Auth::Key("secret")), "Key(<redacted>)");
        assert_eq!(Auth::Key("secret").as_key(), Some("secret"));
    }
    #[cfg(feature = "openai-chat")]
    #[tokio::test(flavor = "current_thread")]
    async fn standalone_runtime_request_executes_without_catalog_dtos() {
        use crate::{Termination, Transport};
        use axum::{Router, extract::State, http::HeaderMap, routing::post};
        use tokio::sync::watch;

        async fn respond(
            State(sent): State<tokio::sync::mpsc::Sender<String>>,
            headers: HeaderMap,
        ) -> impl axum::response::IntoResponse {
            sent.send(headers["authorization"].to_str().unwrap().to_owned())
                .await
                .unwrap();
            (
                [("content-type", "text/event-stream")],
                "data: {\"choices\":[{\"delta\":{\"content\":\"hello\"}}]}\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n",
            )
        }
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let (sent, mut received) = tokio::sync::mpsc::channel(1);
        let server = tokio::spawn(async move {
            axum::serve(
                listener,
                Router::new()
                    .route("/chat/completions", post(respond))
                    .with_state(sent),
            )
            .await
            .unwrap();
        });
        let tls = rustls::ClientConfig::builder_with_provider(std::sync::Arc::new(
            rustls::crypto::ring::default_provider(),
        ))
        .with_safe_default_protocol_versions()
        .unwrap()
        .with_root_certificates(rustls::RootCertStore::empty())
        .with_no_client_auth();
        let client = reqwest::Client::builder()
            .no_proxy()
            .tls_backend_preconfigured(tls)
            .build()
            .unwrap();
        let endpoint = ResolvedEndpoint::new(
            ModelApi::OpenaiChat,
            "standalone",
            format!("http://{address}"),
        );
        let model = ResolvedModel::new("synthetic", 128);
        let mut request = RunRequest::new("host", &endpoint, &model);
        request.auth = Auth::Key("synthetic-key");
        let (_cancel, receiver) = watch::channel(0);
        let mut partials = Vec::new();
        let outcome = Transport::new(client, false)
            .run_request(Route::Chat, &request, receiver, &mut |delta, partial| {
                partials.push((delta.clone(), partial.clone()))
            })
            .await;
        assert!(matches!(outcome.termination, Termination::Finished));
        assert_eq!(
            received.recv().await.as_deref(),
            Some("Bearer synthetic-key")
        );
        assert!(!partials.is_empty());
        assert_eq!(
            serde_json::to_value(outcome.message.content).unwrap(),
            json!([{"type":"text","text":"hello"}])
        );
        server.abort();
    }
}
