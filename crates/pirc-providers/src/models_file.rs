//! The gateway's `models.json` (`apps/gateway/src/models.ts`): loading with
//! key resolution, and the secret-free projections for nodes and browsers.

use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use indexmap::IndexMap;
use pirc_protocol::{Model, ModelApi, ModelRef, Models, Provider};
use serde::Deserialize;
use serde_json::{Map, Value, json};

/// A loaded `models.json`: providers with their keys resolved.
#[derive(Clone, Debug, PartialEq)]
pub struct ModelsFile {
    pub models: Models,
}

/// The top level is strict (`.strict()` in the zod schema).
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct FileSource {
    #[serde(default)]
    providers: IndexMap<String, Value>,
    #[serde(default)]
    default_model: Option<Value>,
}

/// A provider in `models.json`; unknown keys are ignored, as zod strips them.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ProviderSource {
    api: ModelApi,
    #[serde(default)]
    pi_provider: Option<String>,
    #[serde(default)]
    opencode_go: Option<bool>,
    base_url: String,
    #[serde(default)]
    headers: IndexMap<String, String>,
    #[serde(default)]
    compat: Map<String, Value>,
    models: Vec<Model>,
    #[serde(default)]
    api_key: Option<String>,
    #[serde(default)]
    api_key_env: Option<String>,
    #[serde(default)]
    api_key_file: Option<String>,
    #[serde(default)]
    api_key_command: Option<Vec<String>>,
}

/// `expandHome`: `~` and `~/…` are relative to `home`.
pub fn expand_home(value: &str, home: &Path) -> PathBuf {
    if value == "~" {
        home.to_path_buf()
    } else if let Some(rest) = value.strip_prefix("~/") {
        home.join(rest)
    } else {
        PathBuf::from(value)
    }
}

fn valid_url(value: &str) -> bool {
    reqwest::Url::parse(value).is_ok()
}

fn check_provider(name: &str, source: &ProviderSource) -> Result<(), String> {
    let at = |field: &str| format!("providers.{name}.{field}");
    if !valid_url(&source.base_url) {
        return Err(format!("{}: Expected a URL", at("baseUrl")));
    }
    if source.models.is_empty() {
        return Err(format!("{}: Expected at least one entry", at("models")));
    }
    if source.api_key_command.as_ref().is_some_and(Vec::is_empty) {
        return Err(format!(
            "{}: Expected at least one entry",
            at("apiKeyCommand")
        ));
    }
    for (index, model) in source.models.iter().enumerate() {
        let at = |field: &str| format!("providers.{name}.models.{index}.{field}");
        if model.base_url.as_deref().is_some_and(|url| !valid_url(url)) {
            return Err(format!("{}: Expected a URL", at("baseUrl")));
        }
        if model.id.is_empty() {
            return Err(format!("{}: Expected a non-empty string", at("id")));
        }
        if model.context_window == 0 {
            return Err(format!(
                "{}: Expected a positive number",
                at("contextWindow")
            ));
        }
        if model.max_tokens == 0 {
            return Err(format!("{}: Expected a positive number", at("maxTokens")));
        }
        if let Some(input) = model
            .input
            .iter()
            .position(|input| input != "text" && input != "image")
        {
            return Err(format!(
                "{}.{input}: Expected 'text' or 'image'",
                at("input")
            ));
        }
    }
    Ok(())
}

/// A failed read as text, naming the path.
fn read_error(error: &std::io::Error, path: &Path) -> String {
    format!("open '{}': {error}", path.display())
}

/// The `apiKeyCommand` process: the gateway's environment without pirc's
/// own secrets (node tokens, the VAPID private key, the proxy secret, the
/// web search key). Everything else stays, since a key command may
/// legitimately need its own credentials (a password manager's token, a
/// GnuPG home).
fn key_command(
    program: &Path,
    args: &[String],
    vars: impl IntoIterator<Item = (OsString, OsString)>,
) -> Command {
    let mut command = Command::new(program);
    command
        .args(args)
        .env_clear()
        .envs(vars.into_iter().filter(|(name, _)| {
            !name
                .to_str()
                .is_some_and(pirc_config::env_allowlist::is_secret_env)
        }));
    command
}

fn resolve_api_key(
    name: &str,
    source: &ProviderSource,
    env: &dyn Fn(&str) -> Option<String>,
    home: &Path,
) -> Result<Option<String>, String> {
    let key = if let Some(key) = source.api_key.as_ref().filter(|key| !key.is_empty()) {
        Some(key.clone())
    } else if let Some(variable) = source.api_key_env.as_ref().filter(|v| !v.is_empty()) {
        env(variable)
    } else if let Some(file) = source.api_key_file.as_ref().filter(|f| !f.is_empty()) {
        let path = expand_home(file, home);
        let bytes = std::fs::read(&path).map_err(|error| read_error(&error, &path))?;
        Some(String::from_utf8_lossy(&bytes).into_owned())
    } else if let Some([command, args @ ..]) = source.api_key_command.as_deref() {
        let program = expand_home(command, home);
        let output = key_command(&program, args, std::env::vars_os())
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .output()
            .map_err(|error| match error.kind() {
                std::io::ErrorKind::NotFound => {
                    format!("Executable not found in $PATH: \"{}\"", program.display())
                }
                _ => format!("apiKeyCommand for {name} failed: {error}"),
            })?;
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(format!(
                "apiKeyCommand for {name} failed: {}",
                crate::js::trim(&stderr)
            ));
        }
        Some(String::from_utf8_lossy(&output.stdout).into_owned())
    } else {
        None
    };
    Ok(key
        .map(|key| crate::js::trim(&key).to_owned())
        .filter(|key| !key.is_empty()))
}

/// Read and resolve the gateway's `models.json` (`loadModelsFile`). A
/// missing file is `Ok(None)`; anything invalid, including a key reference
/// that cannot be resolved, is an error whose text never contains a key.
pub fn load_models_file(
    path: &Path,
    env: &dyn Fn(&str) -> Option<String>,
    home: &Path,
) -> Result<Option<Models>, String> {
    let file = path.display();
    let text = match std::fs::read(path) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(read_error(&error, path)),
    };
    let raw: Value = serde_json::from_slice(&text)
        .map_err(|error| format!("Invalid JSON in {file}: {error}"))?;
    if !raw.is_object() {
        return Err(format!("Invalid {file}: Expected object"));
    }
    let source: FileSource =
        serde_json::from_value(raw).map_err(|error| format!("Invalid {file}: {error}"))?;
    let mut providers = Vec::with_capacity(source.providers.len());
    for (name, value) in source.providers {
        let provider: ProviderSource = serde_json::from_value(value)
            .map_err(|error| format!("Invalid {file}: providers.{name}: {error}"))?;
        check_provider(&name, &provider).map_err(|error| format!("Invalid {file}: {error}"))?;
        providers.push((name, provider));
    }
    let default_model: Option<ModelRef> = source
        .default_model
        .map(serde_json::from_value)
        .transpose()
        .map_err(|error| format!("Invalid {file}: defaultModel: {error}"))?;
    if let Some(default) = &default_model {
        let configured = providers.iter().any(|(name, provider)| {
            name == &default.provider && provider.models.iter().any(|m| m.id == default.id)
        });
        if !configured {
            return Err(format!(
                "Invalid {file}: defaultModel {}/{} is not configured",
                default.provider, default.id
            ));
        }
    }
    let mut resolved = IndexMap::with_capacity(providers.len());
    for (name, source) in providers {
        let api_key = resolve_api_key(&name, &source, env, home)?;
        let provider = Provider {
            api: source.api,
            pi_provider: source.pi_provider,
            opencode_go: source.opencode_go,
            base_url: source.base_url,
            headers: source.headers,
            compat: source.compat,
            models: source.models,
            api_key,
        };
        resolved.insert(name, provider);
    }
    Ok(Some(Models {
        providers: resolved,
        default_model,
        inference: None,
    }))
}

fn long_cache_compat(compat: &Map<String, Value>) -> Map<String, Value> {
    let mut out = Map::new();
    if let Some(value @ Value::Bool(_)) = compat.get("supportsLongCacheRetention") {
        out.insert("supportsLongCacheRetention".to_owned(), value.clone());
    }
    out
}

fn route_fingerprint(provider: &Provider, model: Option<&Model>) -> String {
    use sha2::{Digest, Sha256};
    fn clean(v: &Value) -> Value {
        match v {
            Value::Object(o) => {
                let sorted: std::collections::BTreeMap<_, _> = o
                    .iter()
                    .filter(|(k, _)| {
                        let k = k.to_ascii_lowercase();
                        !([
                            "key",
                            "token",
                            "secret",
                            "auth",
                            "cookie",
                            "credential",
                            "password",
                            "fingerprint",
                        ]
                        .iter()
                        .any(|part| k.contains(part)))
                    })
                    .map(|(k, v)| (k.clone(), clean(v)))
                    .collect();
                json!(sorted)
            }
            Value::Array(a) => json!(a.iter().map(clean).collect::<Vec<_>>()),
            _ => v.clone(),
        }
    }
    let url = model
        .and_then(|m| m.base_url.as_deref())
        .unwrap_or(&provider.base_url);
    let url = if let Ok(mut url) = reqwest::Url::parse(url) {
        let _ = url.set_username("");
        let _ = url.set_password(None);
        url.set_query(None);
        url.set_fragment(None);
        url.to_string()
    } else {
        "invalid-url".into()
    };
    let config = json!({"api":model.and_then(|m|m.api).unwrap_or(provider.api),"baseUrl":url,"piProvider":provider.pi_provider,"opencodeGo":provider.opencode_go,"providerCompat":clean(&json!(provider.compat)),"providerHeaders":clean(&json!(provider.headers)),"model":model.map(|m|json!({"id":m.id,"canonicalProvider":m.canonical_provider,"compat":clean(&json!(m.compat)),"headers":clean(&json!(m.headers)),"thinkingLevelMap":m.thinking_level_map}))});
    format!("{:x}", Sha256::digest(config.to_string().as_bytes()))
}
fn public_compat(provider: &Provider, model: Option<&Model>) -> Map<String, Value> {
    let mut compat = long_cache_compat(model.map_or(&provider.compat, |m| &m.compat));
    compat.insert(
        "pircRouteFingerprint".into(),
        json!(route_fingerprint(provider, model)),
    );
    compat
}

/// `publicModels`: an explicit allowlist; never endpoint URLs, headers,
/// compat flags (but one) or credentials.
pub fn public_models(models: &Models) -> Models {
    let providers = models
        .providers
        .iter()
        .map(|(name, provider)| {
            let models = provider
                .models
                .iter()
                .map(|model| Model {
                    api: model.api,
                    base_url: None,
                    canonical_provider: None,
                    headers: None,
                    thinking_level_map: model.thinking_level_map.clone(),
                    id: model.id.clone(),
                    name: model.name.clone(),
                    context_window: model.context_window,
                    max_tokens: model.max_tokens,
                    reasoning: model.reasoning,
                    input: model.input.clone(),
                    compat: public_compat(provider, Some(model)),
                })
                .collect();
            let provider = Provider {
                api: provider.api,
                pi_provider: None,
                opencode_go: None,
                base_url: "https://gateway.invalid".to_owned(),
                headers: IndexMap::new(),
                compat: public_compat(provider, None),
                models,
                api_key: None,
            };
            (name.clone(), provider)
        })
        .collect();
    Models {
        providers,
        default_model: models.default_model.clone(),
        inference: None,
    }
}

/// `listModels`: the public model list for the browser.
pub fn list_models(models: &Models) -> Vec<Value> {
    models
        .providers
        .iter()
        .flat_map(|(provider, config)| {
            config.models.iter().map(move |model| {
                json!({
                    "provider": provider,
                    "id": model.id,
                    "name": model.name.as_ref().unwrap_or(&model.id),
                    "contextWindow": model.context_window,
                    "maxTokens": model.max_tokens,
                    "reasoning": model.reasoning,
                    "input": model.input,
                    "thinkingLevels": model.thinking_levels(),
                })
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write(dir: &Path, name: &str, value: &Value) -> PathBuf {
        let path = dir.join(name);
        std::fs::write(&path, serde_json::to_vec(value).unwrap()).unwrap();
        path
    }

    fn no_env(_: &str) -> Option<String> {
        None
    }

    fn provider(extra: Value) -> Value {
        let mut base = json!({ "api": "openai-completions", "baseUrl": "https://api.example.com/v1",
            "models": [{ "id": "m" }] });
        base.as_object_mut()
            .unwrap()
            .extend(extra.as_object().unwrap().clone());
        base
    }

    #[test]
    fn route_fingerprint_tracks_routing_but_excludes_rotating_credentials() {
        let mut p: Provider = serde_json::from_value(provider(
            json!({"headers":{"Authorization":"Bearer first","x-region":"east"},"apiKey":"first"}),
        ))
        .unwrap();
        let first = route_fingerprint(&p, Some(&p.models[0]));
        p.api_key = Some("second".into());
        p.headers
            .insert("Authorization".into(), "Bearer second".into());
        p.base_url = "https://user:pass@api.example.com/v1?api_key=secret#token".into();
        assert_eq!(route_fingerprint(&p, Some(&p.models[0])), first);
        p.headers.insert("x-region".into(), "west".into());
        assert_ne!(route_fingerprint(&p, Some(&p.models[0])), first);
        let changed = route_fingerprint(&p, Some(&p.models[0]));
        p.models[0].base_url = Some("https://other.example.com/v1".into());
        assert_ne!(route_fingerprint(&p, Some(&p.models[0])), changed);
    }

    #[test]
    fn missing_file_is_none() {
        let dir = tempfile::tempdir().unwrap();
        let result = load_models_file(&dir.path().join("models.json"), &no_env, dir.path());
        assert_eq!(result, Ok(None));
    }

    #[test]
    fn applies_defaults_and_keeps_provider_order() {
        let dir = tempfile::tempdir().unwrap();
        let path = write(
            dir.path(),
            "models.json",
            &json!({ "providers": { "z": provider(json!({ "apiKey": " sk-z \n", "extra": 1 })),
                "a": provider(json!({})) },
                "defaultModel": { "provider": "a", "id": "m", "thinking": "high" } }),
        );
        let models = load_models_file(&path, &no_env, dir.path())
            .unwrap()
            .unwrap();
        assert_eq!(models.providers.keys().collect::<Vec<_>>(), ["z", "a"]);
        let z = &models.providers["z"];
        assert_eq!(z.api_key.as_deref(), Some("sk-z"));
        assert_eq!(models.providers["a"].api_key, None);
        let model = &z.models[0];
        assert_eq!(
            (model.context_window, model.max_tokens, model.reasoning),
            (200_000, 32_000, false)
        );
        assert_eq!(model.input, ["text"]);
        assert_eq!(models.default_model.unwrap().provider, "a");
    }

    #[test]
    fn resolves_env_file_and_command_keys() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("key.txt"), "file-key\n").unwrap();
        let path = write(
            dir.path(),
            "models.json",
            &json!({ "providers": {
                "env": provider(json!({ "apiKey": "", "apiKeyEnv": "KEY_VAR" })),
                "file": provider(json!({ "apiKeyFile": "~/key.txt" })),
                "cmd": provider(json!({ "apiKeyCommand": ["sh", "-c", "echo cmd-key"] })),
                "blank": provider(json!({ "apiKeyEnv": "EMPTY" })),
            } }),
        );
        let env = |name: &str| match name {
            "KEY_VAR" => Some("env-key".to_owned()),
            "EMPTY" => Some("  ".to_owned()),
            _ => None,
        };
        let models = load_models_file(&path, &env, dir.path()).unwrap().unwrap();
        let key = |name: &str| models.providers[name].api_key.clone();
        assert_eq!(key("env").as_deref(), Some("env-key"));
        assert_eq!(key("file").as_deref(), Some("file-key"));
        assert_eq!(key("cmd").as_deref(), Some("cmd-key"));
        assert_eq!(key("blank"), None);
    }

    #[test]
    fn key_command_drops_pirc_secrets_only() {
        let vars = [
            ("PATH", std::env::var("PATH").unwrap_or_default()),
            ("PIRC_NODE_TOKENS", "tokens".to_owned()),
            ("PIRC_VAPID_PRIVATE_KEY", "vapid".to_owned()),
            ("PIRC_PROXY_SECRET", "proxy".to_owned()),
            ("EXA_API_KEY", "exa".to_owned()),
            ("OP_SERVICE_ACCOUNT_TOKEN", "op".to_owned()),
            ("GNUPGHOME", "/gpg".to_owned()),
        ]
        .map(|(name, value)| (OsString::from(name), OsString::from(value)));
        let script = [
            "PIRC_NODE_TOKENS",
            "PIRC_VAPID_PRIVATE_KEY",
            "PIRC_PROXY_SECRET",
            "EXA_API_KEY",
            "OP_SERVICE_ACCOUNT_TOKEN",
            "GNUPGHOME",
        ]
        .map(|name| format!("${{{name}-unset}}"))
        .join(" ");
        let args = ["-c".to_owned(), format!("printf %s \"{script}\"")];
        let output = key_command(Path::new("sh"), &args, vars).output().unwrap();
        assert_eq!(
            String::from_utf8_lossy(&output.stdout),
            "unset unset unset unset op /gpg"
        );
    }

    #[test]
    fn reports_errors_without_key_values() {
        let dir = tempfile::tempdir().unwrap();
        let cases = [
            (json!({ "providers": {}, "other": 1 }), "unknown field"),
            (
                json!({ "providers": { "p": provider(json!({ "baseUrl": "nope" })) } }),
                "providers.p.baseUrl: Expected a URL",
            ),
            (
                json!({ "providers": { "p": provider(json!({ "models": [] })) } }),
                "providers.p.models",
            ),
            (
                json!({ "providers": { "p": provider(json!({})) },
                    "defaultModel": { "provider": "p", "id": "x" } }),
                "defaultModel p/x is not configured",
            ),
            (
                json!({ "providers": { "p": provider(json!({
                    "apiKeyCommand": ["sh", "-c", "echo sk-secret; echo bad >&2; exit 3"] })) } }),
                "apiKeyCommand for p failed: bad",
            ),
            (
                json!({ "providers": { "p": provider(json!({ "apiKeyFile": "~/missing" })) } }),
                "No such file or directory",
            ),
        ];
        for (index, (value, expected)) in cases.into_iter().enumerate() {
            let path = write(dir.path(), &format!("{index}.json"), &value);
            let error = load_models_file(&path, &no_env, dir.path()).unwrap_err();
            assert!(error.contains(expected), "{error}");
            assert!(!error.contains("sk-secret"), "{error}");
        }
        let path = dir.path().join("bad.json");
        std::fs::write(&path, "{").unwrap();
        let error = load_models_file(&path, &no_env, dir.path()).unwrap_err();
        assert!(error.starts_with(&format!("Invalid JSON in {}: ", path.display())));
    }

    #[test]
    fn projects_public_models_and_lists() {
        let models: Models = serde_json::from_value(json!({ "providers": { "p": {
            "api": "openai-completions", "piProvider": "openai", "baseUrl": "https://secret.example",
            "headers": { "x-secret": "h" }, "apiKey": "sk-secret",
            "compat": { "supportsLongCacheRetention": true, "supportsDeveloperRole": false },
            "models": [{ "id": "m", "name": "Model", "api": "openai-responses",
                "baseUrl": "https://model.example", "headers": { "x": "y" }, "canonicalProvider": "c",
                "thinkingLevelMap": { "off": null }, "compat": { "supportsLongCacheRetention": "yes" } },
                { "id": "n" }] } },
            "defaultModel": { "provider": "p", "id": "m" } }))
        .unwrap();
        let mut public = serde_json::to_value(public_models(&models)).unwrap();
        let p = public["providers"]["p"].as_object_mut().unwrap();
        assert_eq!(
            p["compat"]["pircRouteFingerprint"].as_str().unwrap().len(),
            64
        );
        p["compat"]
            .as_object_mut()
            .unwrap()
            .remove("pircRouteFingerprint");
        for m in p["models"].as_array_mut().unwrap() {
            m["compat"]
                .as_object_mut()
                .unwrap()
                .remove("pircRouteFingerprint");
        }
        assert_eq!(
            public,
            json!({ "providers": { "p": { "api": "openai-completions",
                "baseUrl": "https://gateway.invalid", "headers": {},
                "compat": { "supportsLongCacheRetention": true },
                "models": [
                    { "api": "openai-responses", "thinkingLevelMap": { "off": null }, "id": "m",
                      "name": "Model", "contextWindow": 200000, "maxTokens": 32000,
                      "reasoning": false, "input": ["text"], "compat": {} },
                    { "id": "n", "contextWindow": 200000, "maxTokens": 32000,
                      "reasoning": false, "input": ["text"], "compat": {} }] } },
              "defaultModel": { "provider": "p", "id": "m" } })
        );
        assert_eq!(
            list_models(&models),
            [
                json!({ "provider": "p", "id": "m", "name": "Model", "contextWindow": 200000,
                    "maxTokens": 32000, "reasoning": false, "input": ["text"],
                    "thinkingLevels": [] }),
                json!({ "provider": "p", "id": "n", "name": "n", "contextWindow": 200000,
                    "maxTokens": 32000, "reasoning": false, "input": ["text"],
                    "thinkingLevels": [] }),
            ]
        );
    }

    #[test]
    fn lists_the_thinking_levels_each_model_offers() {
        let models: Models = serde_json::from_value(json!({ "providers": { "p": {
            "api": "openai-completions", "baseUrl": "https://model.invalid",
            "models": [
                { "id": "plain", "reasoning": false },
                { "id": "default-levels", "reasoning": true },
                { "id": "both", "reasoning": true,
                    "thinkingLevelMap": {"minimal": null, "low": "low", "medium": "medium",
                        "high": "high", "xhigh": "xhigh", "max": "max"} },
                { "id": "max-only", "reasoning": true,
                    "thinkingLevelMap": {"max": "max"} },
                { "id": "no-top", "reasoning": true,
                    "thinkingLevelMap": {"xhigh": null, "max": null} },
            ] } } }))
        .unwrap();
        let levels = |id: &str| {
            list_models(&models)
                .into_iter()
                .find(|model| model["id"] == json!(id))
                .unwrap()["thinkingLevels"]
                .clone()
        };
        assert_eq!(levels("plain"), json!([]));
        assert_eq!(
            levels("default-levels"),
            json!(["minimal", "low", "medium", "high"])
        );
        assert_eq!(
            levels("both"),
            json!(["low", "medium", "high", "xhigh", "max"])
        );
        assert_eq!(
            levels("max-only"),
            json!(["minimal", "low", "medium", "high", "max"])
        );
        assert_eq!(
            levels("no-top"),
            json!(["minimal", "low", "medium", "high"])
        );
    }
}
