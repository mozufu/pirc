//! The single operator's model backends (`backends/service.ts`):
//! `PIRC_MODELS_FILE` providers (file-managed, read-only, always winning),
//! web-managed API-key backends and subscription (OAuth) accounts, kept in
//! `<state>/backends/settings.json` (0600, atomic writes).

mod auth;
mod discovery;
mod oauth;
mod schema;

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock, Weak};
use std::time::Duration;

use indexmap::IndexMap;
use pirc_protocol::{Model, ModelRef, Models, Provider};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

pub use auth::{OAuthRunner, ProviderRunner};
pub use discovery::{
    BackendPreset, ConnectionResult, DiscoveredModel, UiModel, catalog_presets, name_order,
    parse_model_list,
};
pub use oauth::flows::{BoxFuture, Endpoints, LoginHooks, Prompt};
pub use oauth::{OAUTH_PROVIDERS, OAuthProviderInfo};

use crate::catalog::{CatalogModel, catalog_models, catalog_providers};
use crate::inference::{Inference, Resolve, Resolved};
use crate::models_file::public_models;

/// An error with its HTTP status and machine-readable code (`ApiError`).
/// The message is shown to users: never secrets or upstream bodies.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BackendError {
    pub status: u16,
    pub code: &'static str,
    pub message: String,
}

impl BackendError {
    pub fn new(status: u16, code: &'static str, message: impl Into<String>) -> Self {
        Self {
            status,
            code,
            message: message.into(),
        }
    }
}

impl std::fmt::Display for BackendError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

fn invalid(message: &str) -> BackendError {
    BackendError::new(400, "invalid_input", message)
}

fn invalid_settings() -> BackendError {
    invalid("Invalid backend settings")
}

/// Run a schema check of the settings form: [`schema::endpoint_throws`]
/// bodies are an internal error, anything else that fails is invalid.
fn parse<T>(input: &Value, check: impl FnOnce(&Value) -> Option<T>) -> Result<T, BackendError> {
    if schema::endpoint_throws(input) {
        return Err(BackendError::new(
            500,
            "internal_error",
            "Internal server error",
        ));
    }
    check(input).ok_or_else(invalid_settings)
}

fn conflict(message: &str) -> BackendError {
    BackendError::new(409, "conflict", message)
}

fn not_found() -> BackendError {
    BackendError::new(
        404,
        "not_found",
        "Backend or authorization session not found",
    )
}

fn closed_error() -> BackendError {
    conflict("Backend service is closed")
}

/// A random RFC 4122 version 4 UUID (`crypto.randomUUID()`).
pub fn random_uuid() -> String {
    let mut bytes = [0u8; 16];
    getrandom::fill(&mut bytes).expect("the system random number generator");
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let hex: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
    format!(
        "{}-{}-{}-{}-{}",
        &hex[..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..]
    )
}

/// Subscription credentials: `access`, `refresh` and `expires` (epoch ms),
/// plus whatever else the provider keeps (`.passthrough()`).
pub type Credentials = Map<String, Value>;

fn valid_credentials(credentials: &Credentials) -> bool {
    let text = |key: &str| {
        credentials
            .get(key)
            .and_then(Value::as_str)
            .is_some_and(|value| !value.is_empty())
    };
    text("access")
        && text("refresh")
        && credentials
            .get("expires")
            .and_then(Value::as_f64)
            .is_some_and(f64::is_finite)
}

/// What `providerSchema` checks beyond the types: URLs and at least one
/// model with a non-empty ID and positive sizes.
fn valid_provider(provider: &Provider) -> bool {
    let url = |text: &str| reqwest::Url::parse(text).is_ok();
    let inputs = |model: &Model| model.input.iter().all(|i| i == "text" || i == "image");
    url(&provider.base_url)
        && !provider.models.is_empty()
        && provider.models.iter().all(|model| {
            !model.id.is_empty()
                && model.context_window > 0
                && model.max_tokens > 0
                && model.base_url.as_deref().is_none_or(url)
                && inputs(model)
        })
}

/// `settings.json` (`diskSchema`). No `Debug`: it holds credentials.
#[derive(Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct DiskState {
    version: u8,
    #[serde(default)]
    providers: IndexMap<String, Provider>,
    oauth: IndexMap<String, Credentials>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    default_model: Option<ModelRef>,
}

impl DiskState {
    fn empty() -> Self {
        Self {
            version: 1,
            ..Self::default()
        }
    }
}

struct Inner {
    baseline: Models,
    state: DiskState,
    /// `merged()`, recomputed on every change.
    merged: Arc<Models>,
}

/// The backend settings service. Configuration changes call the change
/// hook, which cancels inference in flight and sends nodes the new catalog.
pub struct BackendService {
    file: PathBuf,
    inner: Mutex<Inner>,
    on_change: OnceLock<Box<dyn Fn() + Send + Sync>>,
    probes: AtomicUsize,
    closed: AtomicBool,
    /// Probes reach user-chosen endpoints: redirects are never followed.
    probe_client: reqwest::Client,
    presets: OnceLock<Vec<BackendPreset>>,
    /// Connection tests run on their own transports, which configuration
    /// changes (`Inference::cancel_all` of real runs) do not cancel.
    test_inference: Inference,
    weak: Weak<Self>,
    auth: Mutex<auth::AuthState>,
    runner: Arc<dyn OAuthRunner>,
    session_timeout: Duration,
}

/// Construction options; [`BackendOptions::default`] is production.
pub struct BackendOptions {
    /// Logins and refreshes (the real providers by default).
    pub runner: Option<Arc<dyn OAuthRunner>>,
    /// How long a login may stay pending (10 minutes).
    pub session_timeout: Duration,
}

impl Default for BackendOptions {
    fn default() -> Self {
        Self {
            runner: None,
            session_timeout: Duration::from_secs(10 * 60),
        }
    }
}

impl std::fmt::Debug for BackendService {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("BackendService")
            .field("file", &self.file)
            .finish_non_exhaustive()
    }
}

fn own<V>(map: &IndexMap<String, V>, key: &str) -> bool {
    map.contains_key(key)
}

/// Whether two base URLs name the same endpoint: the trailing-slash rule
/// the probes and requests already apply, then the parsed form, so only
/// scheme/host case and default ports are ignored. Path, port and scheme
/// differences are different endpoints.
fn same_base_url(saved: &str, probe: &str) -> bool {
    let (saved, probe) = (saved.trim_end_matches('/'), probe.trim_end_matches('/'));
    match (reqwest::Url::parse(saved), reqwest::Url::parse(probe)) {
        (Ok(saved), Ok(probe)) => saved == probe,
        _ => saved == probe,
    }
}

fn has_model(providers: &IndexMap<String, Provider>, reference: &ModelRef) -> bool {
    providers
        .get(&reference.provider)
        .is_some_and(|provider| provider.models.iter().any(|m| m.id == reference.id))
}

impl BackendService {
    /// Open `<state_dir>/backends/settings.json` (created on first save).
    /// An unreadable or invalid store stops the gateway.
    pub fn open(state_dir: &Path, baseline: Models) -> Result<Arc<Self>, String> {
        Self::open_with(state_dir, baseline, BackendOptions::default())
    }

    /// [`BackendService::open`] with explicit options.
    pub fn open_with(
        state_dir: &Path,
        baseline: Models,
        options: BackendOptions,
    ) -> Result<Arc<Self>, String> {
        let directory = state_dir.join("backends");
        fs::create_dir_all(&directory)
            .and_then(|()| fs::set_permissions(&directory, fs::Permissions::from_mode(0o700)))
            .map_err(|error| format!("cannot create {}: {error}", directory.display()))?;
        let file = directory.join("settings.json");
        let state = match fs::read(&file) {
            Ok(bytes) => {
                let state: DiskState = serde_json::from_slice(&bytes)
                    .ok()
                    .filter(|state: &DiskState| {
                        state.version == 1 && state.oauth.values().all(valid_credentials)
                    })
                    .ok_or("Cannot read backend credential store")?;
                fs::set_permissions(&file, fs::Permissions::from_mode(0o600))
                    .map_err(|_| "Cannot read backend credential store")?;
                state
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => DiskState::empty(),
            Err(_) => return Err("Cannot read backend credential store".to_owned()),
        };
        if !state.providers.values().all(valid_provider) {
            return Err("Cannot read backend credential store".to_owned());
        }
        if !state.providers.keys().all(|id| schema::custom_id(id)) {
            return Err("Invalid backend credential store".to_owned());
        }
        let _ = rustls::crypto::ring::default_provider().install_default();
        let probe_client = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .no_proxy()
            .build()
            .map_err(|error| format!("HTTP client: {error}"))?;
        let merged = Arc::new(merge(&baseline, &state));
        let runner = options
            .runner
            .unwrap_or_else(|| Arc::new(ProviderRunner::new(Endpoints::default())));
        Ok(Arc::new_cyclic(|weak| Self {
            file,
            inner: Mutex::new(Inner {
                baseline,
                state,
                merged,
            }),
            on_change: OnceLock::new(),
            probes: AtomicUsize::new(0),
            closed: AtomicBool::new(false),
            probe_client,
            presets: OnceLock::new(),
            test_inference: Inference::new(),
            weak: weak.clone(),
            auth: Mutex::new(auth::AuthState::default()),
            runner,
            session_timeout: options.session_timeout,
        }))
    }

    fn auth(&self) -> MutexGuard<'_, auth::AuthState> {
        self.auth
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn closed(&self) -> bool {
        self.closed.load(Ordering::SeqCst)
    }

    /// Set the change hook (once).
    pub fn set_on_change(&self, hook: impl Fn() + Send + Sync + 'static) {
        let _ = self.on_change.set(Box::new(hook));
    }

    fn lock(&self) -> MutexGuard<'_, Inner> {
        self.inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn changed(&self) {
        if let Some(hook) = self.on_change.get() {
            hook();
        }
    }

    fn check_open(&self) -> Result<(), BackendError> {
        if self.closed.load(Ordering::SeqCst) {
            Err(closed_error())
        } else {
            Ok(())
        }
    }

    /// Every provider with its credentials (`merged()`): web-managed
    /// backends, subscription accounts, then file-managed providers, which
    /// replace any of the same ID.
    pub fn merged(&self) -> Arc<Models> {
        self.lock().merged.clone()
    }

    /// The secret-free catalog for nodes and browsers (`models`).
    pub fn models(&self) -> Models {
        public_models(&self.merged())
    }

    /// Replace the file-managed providers (SIGHUP).
    pub fn set_baseline(&self, baseline: Models) {
        {
            let mut inner = self.lock();
            inner.merged = Arc::new(merge(&baseline, &inner.state));
            inner.baseline = baseline;
        }
        self.changed();
    }

    /// Write `next` atomically (0600) and make it current.
    fn commit(
        &self,
        inner: &mut MutexGuard<'_, Inner>,
        next: DiskState,
    ) -> Result<(), BackendError> {
        write_atomic(&self.file, &next).map_err(|()| {
            BackendError::new(500, "node_error", "Unable to save backend settings")
        })?;
        inner.merged = Arc::new(merge(&inner.baseline, &next));
        inner.state = next;
        Ok(())
    }

    /// Commit and notify, outside the lock.
    fn commit_and_notify(
        &self,
        mut inner: MutexGuard<'_, Inner>,
        next: DiskState,
    ) -> Result<(), BackendError> {
        self.commit(&mut inner, next)?;
        drop(inner);
        self.changed();
        Ok(())
    }

    /// `snapshot()`: the settings page's secret-free view.
    pub fn snapshot(&self) -> Value {
        let inner = self.lock();
        let config = inner.merged.clone();
        let safe = public_models(&config);
        let providers: Vec<Value> = config
            .providers
            .iter()
            .map(|(id, provider)| {
                let file = own(&inner.baseline.providers, id);
                let oauth_id = id.strip_prefix("oauth:");
                let name = oauth_id
                    .and_then(oauth::info)
                    .map_or(id.as_str(), |info| info.name);
                let source = if file {
                    "file"
                } else if oauth_id.is_some() {
                    "oauth"
                } else {
                    "ui"
                };
                let mut view = json!({ "id": id, "name": name, "source": source, "readOnly": file,
                    "api": provider.api, "opencodeGo": provider.opencode_go.unwrap_or(false) });
                if own(&inner.state.providers, id) && !file {
                    view["baseUrl"] = json!(provider.base_url);
                    if let Some(preset) = &provider.pi_provider {
                        view["preset"] = json!(preset);
                    }
                }
                view["hasApiKey"] = json!(
                    provider.api_key.as_deref().is_some_and(|k| !k.is_empty())
                        || oauth_id.is_some()
                );
                view["models"] =
                    serde_json::to_value(&safe.providers[id].models).unwrap_or_else(|_| json!([]));
                view
            })
            .collect();
        let oauth_providers: Vec<Value> = OAUTH_PROVIDERS
            .iter()
            .map(|info| {
                json!({ "id": info.id, "name": info.name, "providerId": format!("oauth:{}", info.id),
                    "connected": own(&inner.state.oauth, info.id),
                    "requiresPolicyConsent": info.id == "github-copilot",
                    "usesCallbackServer": info.uses_callback_server,
                    "modelCount": catalog_models(info.id).len() })
            })
            .collect();
        let mut out = json!({ "providers": providers, "oauthProviders": oauth_providers });
        if let Some(default) = &config.default_model {
            out["defaultModel"] = json!(default);
        }
        out
    }

    /// `presets()`: API-key presets from the catalog plus common local servers.
    pub fn presets(&self) -> &[BackendPreset] {
        self.presets
            .get_or_init(|| catalog_presets(catalog_providers()))
    }

    /// `saveProvider`: create (`create`) or replace a web-managed backend.
    /// An omitted `apiKey` keeps the saved key; an empty one clears it.
    pub fn save_provider(&self, id: &str, input: &Value, create: bool) -> Result<(), BackendError> {
        self.check_open()?;
        if !schema::custom_id(id) {
            return Err(invalid("Invalid backend ID"));
        }
        let inner = self.lock();
        if own(&inner.baseline.providers, id) {
            return Err(conflict("File-managed backends are read-only"));
        }
        if create && own(&inner.state.providers, id) {
            return Err(conflict("Backend ID already exists"));
        }
        if !create && !own(&inner.state.providers, id) {
            return Err(not_found());
        }
        let value = parse(input, schema::custom_provider)?;
        let api_key = match &value.connection.api_key {
            None => inner
                .state
                .providers
                .get(id)
                .and_then(|p| p.api_key.clone()),
            Some(key) => Some(key.clone()).filter(|key| !key.is_empty()),
        };
        let provider = self.provider_config(&value.connection, &value.models, api_key)?;
        let mut next = inner.state.clone();
        next.providers.insert(id.to_owned(), provider);
        self.commit_and_notify(inner, next)
    }

    /// `providerConfig`: a web-managed provider. With a catalog preset,
    /// models the catalog knows keep its gateway-only request metadata
    /// (compat, headers, thinking map) and requests run under the catalog
    /// provider's name.
    fn provider_config(
        &self,
        connection: &schema::Connection,
        models: &[schema::UiModelInput],
        api_key: Option<String>,
    ) -> Result<Provider, BackendError> {
        let mut known: &[CatalogModel] = &[];
        let mut catalog_routes = false;
        if let Some(preset) = &connection.preset {
            let entry = self
                .presets()
                .iter()
                .find(|item| &item.id == preset && item.catalog);
            if entry.is_none_or(|entry| entry.api != connection.api) {
                return Err(invalid("Unknown backend preset"));
            }
            known = catalog_models(preset);
            if let Some(base) = discovery::catalog_base_url(preset, connection.api) {
                let configured = connection.base_url.trim_end_matches('/');
                // A custom proxy keeps the user's endpoint and wire API. Never
                // send its credentials to an implicit catalog destination.
                let legacy = match preset.as_str() {
                    "opencode" => Some("https://opencode.ai/zen/v1"),
                    "opencode-go" => Some("https://opencode.ai/zen/go/v1"),
                    _ => None,
                };
                catalog_routes = configured == base || Some(configured) == legacy;
            }
        }
        let models = models
            .iter()
            .map(|input| {
                let mut model = Model {
                    api: None,
                    base_url: None,
                    canonical_provider: None,
                    headers: None,
                    thinking_level_map: None,
                    id: input.id.clone(),
                    name: input.name.clone(),
                    context_window: input.context_window,
                    max_tokens: input.max_tokens,
                    reasoning: input.reasoning,
                    input: input.input.clone(),
                    compat: Map::new(),
                };
                if let Some(entry) = known.iter().find(|entry| entry.id == input.id) {
                    discovery::catalog_metadata(entry, &mut model);
                    if catalog_routes {
                        model.api = Some(entry.api);
                        model.base_url = Some(entry.base_url.clone());
                    }
                }
                model
            })
            .collect();
        Ok(Provider {
            api: connection.api,
            pi_provider: connection.preset.clone(),
            opencode_go: connection.opencode_go,
            base_url: connection.base_url.clone(),
            headers: IndexMap::new(),
            compat: Map::new(),
            models,
            api_key,
        })
    }

    /// The key a probe uses: the typed one, else the saved key of the
    /// web-managed backend being edited, but only when the probe targets
    /// the endpoint (base URL and wire API) the key was saved for. Any
    /// other probe behaves as if no key were saved.
    fn probe_key(&self, probe: &schema::Probe) -> Option<String> {
        if let Some(key) = &probe.connection.api_key {
            return Some(key.clone()).filter(|key| !key.is_empty());
        }
        let id = probe.backend_id.as_deref()?;
        let inner = self.lock();
        if own(&inner.baseline.providers, id) {
            return None;
        }
        let saved = inner.state.providers.get(id)?;
        let same_endpoint = saved.api == probe.connection.api
            && same_base_url(&saved.base_url, &probe.connection.base_url);
        if same_endpoint {
            saved.api_key.clone()
        } else {
            None
        }
    }

    /// Probes reach user-chosen endpoints; a few at a time is plenty for
    /// one settings form.
    fn start_probe(&self) -> Result<ProbeSlot<'_>, BackendError> {
        self.check_open()?;
        let taken = self
            .probes
            .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |count| {
                (count < 4).then_some(count + 1)
            });
        match taken {
            Ok(_) => Ok(ProbeSlot(&self.probes)),
            Err(_) => Err(BackendError::new(
                429,
                "too_many_requests",
                "Too many backend checks; try again shortly",
            )),
        }
    }

    /// `discover`: list an unsaved (or edited) endpoint's models, enriched
    /// with catalog metadata.
    pub async fn discover(&self, input: &Value) -> Result<Vec<DiscoveredModel>, BackendError> {
        let probe = parse(input, schema::probe)?;
        let preset: &'static [CatalogModel] = probe
            .connection
            .preset
            .as_deref()
            .map_or(&[], catalog_models);
        let key = self.probe_key(&probe);
        let _slot = self.start_probe()?;
        discovery::discover_models(
            &self.probe_client,
            &discovery::ProbeTarget {
                api: probe.connection.api,
                base_url: &probe.connection.base_url,
                api_key: key.as_deref(),
            },
            |id| preset.iter().find(|model| model.id == id),
        )
        .await
    }

    /// `testProvider`: one tiny request against an unsaved (or edited)
    /// backend's model.
    pub async fn test_provider(&self, input: &Value) -> Result<ConnectionResult, BackendError> {
        let (probe, model) = parse(input, schema::connection_test)?;
        let key = self.probe_key(&probe);
        let provider = self.provider_config(&probe.connection, &[model], key)?;
        let _slot = self.start_probe()?;
        let resolved = Resolved {
            model: provider.models[0].clone(),
            api_key: provider.api_key.clone(),
            provider,
        };
        Ok(discovery::test_connection(&self.test_inference, resolved).await)
    }

    /// `deleteProvider`: a web-managed backend or a subscription account.
    pub fn delete_provider(&self, id: &str) -> Result<(), BackendError> {
        let mut auth = self.auth();
        let inner = self.lock();
        if own(&inner.baseline.providers, id) {
            return Err(conflict("File-managed backends are read-only"));
        }
        let mut next = inner.state.clone();
        if let Some(provider_id) = id.strip_prefix("oauth:") {
            if oauth::info(provider_id).is_none() {
                return Err(not_found());
            }
            // A login or refresh still in flight must not bring the account back.
            auth.sign_out(provider_id);
            next.oauth.shift_remove(provider_id);
        } else if next.providers.shift_remove(id).is_none() {
            return Err(not_found());
        }
        if next
            .default_model
            .as_ref()
            .is_some_and(|default| default.provider == id)
        {
            next.default_model = None;
        }
        drop(auth);
        self.commit_and_notify(inner, next)
    }

    /// `setDefault`: `null` clears the preferred model.
    pub fn set_default(&self, input: &Value) -> Result<(), BackendError> {
        let inner = self.lock();
        let mut next = inner.state.clone();
        if input.is_null() {
            next.default_model = None;
        } else {
            let reference = schema::model_ref(input).ok_or_else(invalid_settings)?;
            if !has_model(&inner.merged.providers, &reference) {
                return Err(invalid("Model is not configured"));
            }
            next.default_model = Some(reference);
        }
        self.commit_and_notify(inner, next)
    }

    /// `close()`: refuse further changes and probes; logins are cancelled
    /// and refreshes aborted.
    pub fn close(&self) {
        self.closed.store(true, Ordering::SeqCst);
        self.auth().close();
    }
}

/// A taken probe slot, released when dropped.
struct ProbeSlot<'a>(&'a AtomicUsize);

impl Drop for ProbeSlot<'_> {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::SeqCst);
    }
}

impl Resolve for BackendService {
    /// `resolve`: file-managed providers first, then subscription accounts
    /// (refreshed a minute before they expire), then web-managed backends.
    async fn resolve(&self, provider_name: &str, model_id: &str) -> Result<Resolved, String> {
        if self.closed() {
            return Err(closed_error().message);
        }
        let missing = || not_found().message;
        let (provider, api_key) = if let Some(id) = provider_name
            .strip_prefix("oauth:")
            .filter(|_| !own(&self.lock().baseline.providers, provider_name))
        {
            let saved = self.lock().state.oauth.get(id).cloned();
            let (Some(mut credentials), Some(_)) = (saved, oauth::info(id)) else {
                return Err(missing());
            };
            let expires = credentials
                .get("expires")
                .and_then(Value::as_f64)
                .unwrap_or(f64::NEG_INFINITY);
            if expires <= crate::stream::now_ms() as f64 + 60_000.0 {
                credentials = self
                    .refresh(id, credentials)
                    .await
                    .map_err(|error| error.message)?;
            }
            if self.closed() || !self.lock().state.oauth.contains_key(id) {
                return Err(missing());
            }
            let provider = oauth::provider_config(id, &credentials).ok_or_else(missing)?;
            let key = credentials
                .get("access")
                .and_then(Value::as_str)
                .map(str::to_owned);
            (provider, key)
        } else {
            let inner = self.lock();
            let provider = inner
                .baseline
                .providers
                .get(provider_name)
                .or_else(|| {
                    (!provider_name.starts_with("oauth:"))
                        .then(|| inner.state.providers.get(provider_name))
                        .flatten()
                })
                .cloned()
                .ok_or_else(missing)?;
            let key = provider.api_key.clone();
            (provider, key)
        };
        let model = provider
            .models
            .iter()
            .find(|model| model.id == model_id)
            .cloned()
            .ok_or_else(missing)?;
        Ok(Resolved {
            provider,
            model,
            api_key,
        })
    }
}

/// `merged()` of a baseline and a saved state.
fn merge(baseline: &Models, state: &DiskState) -> Models {
    let mut providers = state.providers.clone();
    for (id, credentials) in &state.oauth {
        if let Some(provider) = oauth::provider_config(id, credentials) {
            providers.insert(format!("oauth:{id}"), provider);
        }
    }
    for (id, provider) in &baseline.providers {
        providers.insert(id.clone(), provider.clone());
    }
    let preferred = state
        .default_model
        .as_ref()
        .or(baseline.default_model.as_ref());
    let default_model = preferred
        .filter(|reference| has_model(&providers, reference))
        .cloned();
    Models {
        providers,
        default_model,
        inference: None,
    }
}

/// Write `state` to `file` through a fresh 0600 temporary file, fsync and
/// rename; the temporary file never outlives the call.
fn write_atomic(file: &Path, state: &DiskState) -> Result<(), ()> {
    let mut temporary = file.as_os_str().to_owned();
    temporary.push(format!(".{}.tmp", random_uuid()));
    let temporary = PathBuf::from(temporary);
    let result = (|| {
        let mut handle = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&temporary)?;
        handle.write_all(&serde_json::to_vec(state).map_err(std::io::Error::other)?)?;
        handle.sync_all()?;
        drop(handle);
        fs::rename(&temporary, file)
    })();
    let _ = fs::remove_file(&temporary);
    result.map_err(|_| ())
}

#[cfg(test)]
mod tests;
