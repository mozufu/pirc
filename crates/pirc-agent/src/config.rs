//! The agent's configuration (`agent/config.ts`): the node's `config.json`,
//! the workspace's `.pirc/config.json` (trust-gated), the system prompt's
//! files, path policy and limits. Providers come from the gateway.

pub mod schema;
mod workspace_memory;

use std::path::Path;

use indexmap::IndexMap;
use pirc_policy::PathPolicy;
use pirc_protocol::mode::PromptSection as ModePromptSection;
use pirc_protocol::{Mode, ModelRef, Models, ThinkingLevel};
use serde_json::{Map, Value};
use sha2::{Digest, Sha256};

use crate::context::PromptSection;
use crate::messages::js;
use crate::roles::{RoleDir, RolePreset};
use crate::session_store::{EntryData, SessionEntry};
use schema::{Checker, PathPart};

pub use workspace_memory::workspace_memory_config_warning;

/// One hook (`hookSchema`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HookConfig {
    pub command: String,
    pub matcher: Option<String>,
    pub timeout_ms: u64,
}

/// `hooksSchema`.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct HooksConfig {
    pub session_start: Vec<HookConfig>,
    pub before_prompt: Vec<HookConfig>,
    pub before_tool: Vec<HookConfig>,
    pub after_tool: Vec<HookConfig>,
    pub agent_settled: Vec<HookConfig>,
}

/// The hook events, in `hooksSchema` order.
pub const HOOK_EVENTS: [&str; 5] = [
    "sessionStart",
    "beforePrompt",
    "beforeTool",
    "afterTool",
    "agentSettled",
];

impl HooksConfig {
    /// The hooks of one event (`hooks[event]`).
    pub fn list(&self, event: &str) -> &[HookConfig] {
        match event {
            "sessionStart" => &self.session_start,
            "beforePrompt" => &self.before_prompt,
            "beforeTool" => &self.before_tool,
            "afterTool" => &self.after_tool,
            "agentSettled" => &self.agent_settled,
            _ => &[],
        }
    }

    fn list_mut(&mut self, event: &str) -> &mut Vec<HookConfig> {
        match event {
            "sessionStart" => &mut self.session_start,
            "beforePrompt" => &mut self.before_prompt,
            "beforeTool" => &mut self.before_tool,
            "afterTool" => &mut self.after_tool,
            _ => &mut self.agent_settled,
        }
    }

    fn is_empty(&self) -> bool {
        HOOK_EVENTS.iter().all(|event| self.list(event).is_empty())
    }

    /// Every event, each hook `{command, matcher?, timeoutMs}` (also the
    /// node's project-config summary).
    pub fn to_value(&self) -> Value {
        let mut map = Map::new();
        for event in HOOK_EVENTS {
            let hooks = self
                .list(event)
                .iter()
                .map(|hook| {
                    let mut item = Map::new();
                    item.insert("command".into(), Value::from(hook.command.as_str()));
                    if let Some(matcher) = &hook.matcher {
                        item.insert("matcher".into(), Value::from(matcher.as_str()));
                    }
                    item.insert("timeoutMs".into(), Value::from(hook.timeout_ms));
                    Value::Object(item)
                })
                .collect();
            map.insert(event.to_owned(), Value::Array(hooks));
        }
        Value::Object(map)
    }
}

/// `limitsSchema`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Limits {
    pub bash_timeout_ms: u64,
    pub ptc_timeout_ms: u64,
    pub tool_output_bytes: u64,
    pub max_turns: u64,
    pub completion_wait_ms: u64,
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            bash_timeout_ms: 120_000,
            ptc_timeout_ms: 120_000,
            tool_output_bytes: 51_200,
            max_turns: 200,
            completion_wait_ms: 60_000,
        }
    }
}

/// `AgentConfig`.
#[derive(Clone, Debug)]
pub struct AgentConfig {
    pub config_dir: String,
    pub workspace: String,
    /// Providers and default model exactly as the gateway sent them.
    pub models: Models,
    /// The project's default model, else the gateway's.
    pub default_model: Option<ModelRef>,
    /// Canonical absolute paths the file tools may write, workspace first.
    pub allowed_paths: Vec<String>,
    /// Paths the agent may read but never write.
    pub protected_paths: Vec<String>,
    pub project_root: String,
    /// Problems shown when the session starts.
    pub warnings: Vec<String>,
    pub path_policy: PathPolicy,
    /// Inside the node's OS sandbox (`PIRC_SANDBOX=srt`).
    pub sandboxed: bool,
    pub env: Vec<(String, String)>,
    pub hooks: HooksConfig,
    pub limits: Limits,
    /// Per-feature node settings with mode defaults applied.
    pub features: Map<String, Value>,
    pub role_dirs: Vec<RoleDir>,
    pub system_prompt: Vec<PromptSection>,
    /// The validated capability snapshot supplied by the node, never read from disk.
    pub mode: Mode,
}

/// `defaultConfigDir(env)`: `$PIRC_CONFIG_DIR`, default `~/.config/.pirc`.
pub fn default_config_dir(env: &dyn Fn(&str) -> Option<String>) -> String {
    env("PIRC_CONFIG_DIR").unwrap_or_else(|| js::path_join(&[&js::home_dir(), ".config", ".pirc"]))
}

/// `expandHome(value)`.
pub fn expand_home(value: &str) -> String {
    if value == "~" {
        js::home_dir()
    } else if let Some(rest) = value.strip_prefix("~/") {
        js::path_join(&[&js::home_dir(), rest])
    } else {
        value.to_owned()
    }
}

/// `readJson(file)`: `{}` when missing.
fn read_json(file: &str) -> Result<Value, String> {
    let path = Path::new(file);
    if !path.exists() {
        return Ok(Value::Object(Map::new()));
    }
    let text = js::read_text(path)?;
    serde_json::from_str(&text).map_err(|error| format!("Invalid JSON in {file}: {error}"))
}

/// `readText(file)`: trimmed, empty when missing.
fn read_text(file: &str) -> Result<String, String> {
    let path = Path::new(file);
    if !path.exists() {
        return Ok(String::new());
    }
    Ok(js::trim(&js::read_text(path)?).to_owned())
}

/// The node's settings (`globalSchema`).
struct GlobalConfig {
    allowed_paths: Vec<String>,
    env: Vec<(String, String)>,
    hooks: HooksConfig,
    limits: Limits,
    features: Map<String, Value>,
}

fn hook(checker: &mut Checker, value: &Value) -> Option<HookConfig> {
    let map = checker.object(Some(value))?;
    let command = checker.key(map, "command", |c, v| c.string(v, Some(1)));
    let matcher = checker.key(map, "matcher", |c, v| {
        v.and_then(|v| c.string(Some(v), None))
    });
    let timeout_ms = checker.key(map, "timeoutMs", |c, v| match v {
        None => Some(10_000),
        Some(_) => c.positive_int(v, Some(600_000.0)),
    });
    Some(HookConfig {
        command: command?,
        matcher,
        timeout_ms: timeout_ms?,
    })
}

/// `hooksSchema` (`.default({})`).
fn hooks(checker: &mut Checker, value: Option<&Value>) -> HooksConfig {
    let mut out = HooksConfig::default();
    if value.is_none() {
        return out;
    }
    let Some(map) = checker.object(value) else {
        return out;
    };
    for event in HOOK_EVENTS {
        checker.key(map, event, |c, v| {
            if v.is_none() {
                return;
            }
            if let Some(items) = c.array(v) {
                for (index, item) in items.iter().enumerate() {
                    if let Some(parsed) = c.at(PathPart::Index(index), |c| hook(c, item)) {
                        out.list_mut(event).push(parsed);
                    }
                }
            }
        });
    }
    out
}

/// `limitsSchema` (`.default({})`).
fn limits(checker: &mut Checker, value: Option<&Value>) -> Limits {
    let mut out = Limits::default();
    if value.is_none() {
        return out;
    }
    let Some(map) = checker.object(value) else {
        return out;
    };
    let fields: [(&str, &mut u64, Option<f64>); 5] = [
        ("bashTimeoutMs", &mut out.bash_timeout_ms, None),
        ("ptcTimeoutMs", &mut out.ptc_timeout_ms, None),
        ("toolOutputBytes", &mut out.tool_output_bytes, None),
        ("maxTurns", &mut out.max_turns, None),
        (
            "completionWaitMs",
            &mut out.completion_wait_ms,
            Some(86_400_000.0),
        ),
    ];
    for (key, slot, max) in fields {
        checker.key(map, key, |c, v| {
            if v.is_some()
                && let Some(number) = c.positive_int(v, max)
            {
                *slot = number;
            }
        });
    }
    out
}

/// `.default([])` / `.default({})` fields.
fn defaulted<T: Default>(
    checker: &mut Checker,
    map: &Map<String, Value>,
    key: &str,
    parse: impl FnOnce(&mut Checker, Option<&Value>) -> T,
) -> T {
    checker.key(map, key, |c, v| {
        if v.is_none() {
            T::default()
        } else {
            parse(c, v)
        }
    })
}

fn parse_global(raw: &Value) -> Result<GlobalConfig, String> {
    let mut checker = Checker::default();
    let Some(map) = checker.object(Some(raw)) else {
        return Err(schema::error_message(&checker.issues));
    };
    let allowed_paths = defaulted(&mut checker, map, "allowedPaths", Checker::string_array);
    let env = defaulted(&mut checker, map, "env", Checker::string_record);
    let hooks = checker.key(map, "hooks", hooks);
    let limits = checker.key(map, "limits", limits);
    let features = defaulted(&mut checker, map, "features", |c, v| {
        c.object(v).cloned().unwrap_or_default()
    });
    if !checker.issues.is_empty() {
        return Err(schema::error_message(&checker.issues));
    }
    Ok(GlobalConfig {
        allowed_paths,
        env,
        hooks,
        limits,
        features,
    })
}

/// `modelRefSchema`.
fn model_ref(checker: &mut Checker, value: Option<&Value>) -> Option<ModelRef> {
    let map = checker.object(value)?;
    let provider = checker.key(map, "provider", |c, v| c.string(v, None));
    let id = checker.key(map, "id", |c, v| c.string(v, None));
    let thinking = checker.key(map, "thinking", |c, v| {
        v.and_then(|_| c.enumeration(v, &THINKING_LEVELS))
            .and_then(|level| thinking_level(&level))
    });
    Some(ModelRef {
        provider: provider?,
        id: id?,
        thinking,
    })
}

/// `thinkingLevels`.
pub const THINKING_LEVELS: [&str; 6] = ["off", "minimal", "low", "medium", "high", "xhigh"];

/// A thinking level by name.
pub fn thinking_level(name: &str) -> Option<ThinkingLevel> {
    serde_json::from_value(Value::from(name)).ok()
}

/// The project's `.pirc/config.json` (`ProjectConfig`): it may only extend
/// paths, env and hooks and choose a default model.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ProjectConfig {
    pub default_model: Option<ModelRef>,
    pub allowed_paths: Vec<String>,
    pub env: Vec<(String, String)>,
    pub hooks: HooksConfig,
}

/// `projectSchema.parse(raw)`.
pub fn parse_project_config(raw: &Value) -> Result<ProjectConfig, String> {
    let mut checker = Checker::default();
    let Some(map) = checker.object(Some(raw)) else {
        return Err(schema::error_message(&checker.issues));
    };
    let default_model = checker.key(map, "defaultModel", |c, v| v.and_then(|_| model_ref(c, v)));
    let allowed_paths = defaulted(&mut checker, map, "allowedPaths", Checker::string_array);
    let env = defaulted(&mut checker, map, "env", Checker::string_record);
    let hooks = checker.key(map, "hooks", hooks);
    checker.strict(map, &["defaultModel", "allowedPaths", "env", "hooks"]);
    if !checker.issues.is_empty() {
        return Err(schema::error_message(&checker.issues));
    }
    Ok(ProjectConfig {
        default_model,
        allowed_paths,
        env,
        hooks,
    })
}

/// `readProjectConfig(root)`: `<root>/.pirc/config.json`, parsed.
pub fn read_project_config(root: &str) -> Result<ProjectConfig, String> {
    parse_project_config(&read_json(&js::path_join(&[root, ".pirc", "config.json"]))?)
}

/// `ProjectTrustFields`: the project config fields that run code, widen
/// access or choose where the session's data goes (`defaultModel`, L12),
/// honoured only when the user trusted exactly these values.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ProjectTrustFields {
    pub hooks: HooksConfig,
    pub env: Vec<(String, String)>,
    pub allowed_paths: Vec<String>,
    pub default_model: Option<ModelRef>,
}

/// `projectTrustFields(project)`.
pub fn project_trust_fields(project: &ProjectConfig) -> ProjectTrustFields {
    ProjectTrustFields {
        hooks: project.hooks.clone(),
        env: project.env.clone(),
        allowed_paths: project.allowed_paths.clone(),
        default_model: project.default_model.clone(),
    }
}

/// `provider/id`.
pub fn model_label(model: &ModelRef) -> String {
    format!("{}/{}", model.provider, model.id)
}

/// `canonicalJson(value)`: keys sorted (UTF-16 order), no blanks.
fn canonical_json(value: &Value) -> String {
    match value {
        Value::Array(items) => format!(
            "[{}]",
            items
                .iter()
                .map(canonical_json)
                .collect::<Vec<_>>()
                .join(",")
        ),
        Value::Object(map) => {
            let mut entries: Vec<(&String, &Value)> = map.iter().collect();
            entries.sort_by(|(a, _), (b, _)| js::compare_utf16(a, b));
            format!(
                "{{{}}}",
                entries
                    .into_iter()
                    .map(|(key, item)| format!(
                        "{}:{}",
                        js::string_literal(key),
                        canonical_json(item)
                    ))
                    .collect::<Vec<_>>()
                    .join(",")
            )
        }
        other => js::stringify(other),
    }
}

fn env_value(env: &[(String, String)]) -> Value {
    Value::Object(
        env.iter()
            .map(|(key, value)| (key.clone(), Value::from(value.as_str())))
            .collect(),
    )
}

/// `projectTrustHash(fields)`: sha256 of the canonical JSON of the fields.
pub fn project_trust_hash(fields: &ProjectTrustFields) -> String {
    let mut map = Map::new();
    map.insert(
        "allowedPaths".into(),
        Value::from(fields.allowed_paths.clone()),
    );
    map.insert("env".into(), env_value(&fields.env));
    map.insert("hooks".into(), fields.hooks.to_value());
    // Only when set, so configs without a model keep the hash they were
    // trusted under before defaultModel was gated.
    if let Some(model) = &fields.default_model {
        map.insert(
            "defaultModel".into(),
            serde_json::to_value(model).unwrap_or(Value::Null),
        );
    }
    let canonical = canonical_json(&Value::Object(map));
    let digest = Sha256::digest(format!("pirc-project-trust-v1\n{canonical}").as_bytes());
    digest.iter().map(|byte| format!("{byte:02x}")).collect()
}

/// `projectTrustEmpty(fields)`: no hooks, env, allowed paths or model.
pub fn project_trust_empty(fields: &ProjectTrustFields) -> bool {
    fields.allowed_paths.is_empty()
        && fields.env.is_empty()
        && fields.hooks.is_empty()
        && fields.default_model.is_none()
}

/// `parseTrustHash(value)`: 64 lowercase hex digits, else nothing.
pub fn parse_trust_hash(value: Option<&str>) -> Option<String> {
    value
        .filter(|hash| {
            hash.len() == 64
                && hash
                    .bytes()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        })
        .map(str::to_owned)
}

/// `UNTRUSTED_PROJECT_WARNING`.
pub const UNTRUSTED_PROJECT_WARNING: &str = "This workspace's .pirc/config.json sets hooks, env, allowedPaths or defaultModel; they were ignored because the workspace is not trusted (or they changed since it was trusted). Review and trust them in the workspace's Settings.";

/// `features.autoMode.enabled` is still read, but the modes replaced it.
pub const RETIRED_AUTO_MODE_SWITCH: &str = "features.autoMode.enabled is retired: set features.autoMode.mode to \"read-only\", \"auto\" or \"full-access\" instead. Until then enabled: false means full-access (no approval checks) and enabled: true means auto.";

/// The warning for an untrusted project config, naming the model it would
/// have chosen (L12) so the user sees which one was not used.
pub fn untrusted_project_warning(fields: &ProjectTrustFields) -> String {
    match &fields.default_model {
        Some(model) => format!(
            "{UNTRUSTED_PROJECT_WARNING} The ignored defaultModel is {}.",
            model_label(model)
        ),
        None => UNTRUSTED_PROJECT_WARNING.to_owned(),
    }
}

const BASE_PROMPT: &str = "You are pirc, a coding agent operating inside a user's workspace through tools.
Work carefully: read before editing, keep changes minimal and verified, and report blockers honestly.
File tools can read anywhere except credential stores and pirc's private state, and write only to the workspace and explicitly allowed paths.";

/// `parsePathPolicy(PIRC_SANDBOX_POLICY)`.
fn parse_path_policy(value: Option<&str>) -> Result<Option<PathPolicy>, String> {
    let Some(text) = value.filter(|text| !text.is_empty()) else {
        return Ok(None);
    };
    let invalid = || "PIRC_SANDBOX_POLICY is not a valid path policy".to_owned();
    let raw: Value = serde_json::from_str(text).map_err(|_| invalid())?;
    let mut checker = Checker::default();
    let map = checker.object(Some(&raw)).ok_or_else(invalid)?;
    let list = |c: &mut Checker, key: &str| c.key(map, key, |c, v| c.string_array(v));
    let policy = PathPolicy {
        deny_read: list(&mut checker, "denyRead"),
        allow_read: list(&mut checker, "allowRead"),
        allow_write: list(&mut checker, "allowWrite"),
        deny_write: list(&mut checker, "denyWrite"),
        shared_write: checker.key(map, "sharedWrite", |c, v| v.map(|_| c.string_array(v))),
    };
    if !checker.issues.is_empty() {
        return Err(invalid());
    }
    Ok(Some(policy))
}

/// `{...a, ...b}` of string records: a key keeps its first place.
fn merge_env(base: &[(String, String)], extra: &[(String, String)]) -> Vec<(String, String)> {
    let mut merged: IndexMap<String, String> = base.iter().cloned().collect();
    for (key, value) in extra {
        merged.insert(key.clone(), value.clone());
    }
    merged.into_iter().collect()
}

fn truthy_env(env: &dyn Fn(&str) -> Option<String>, name: &str) -> Option<String> {
    env(name).filter(|value| !value.is_empty())
}

/// `loadAgentConfig(workspace, models, env)`.
pub fn load_agent_config(
    workspace: &str,
    models: Models,
    env: &dyn Fn(&str) -> Option<String>,
) -> Result<AgentConfig, String> {
    if env("PIRC_WORKSPACE_KIND").is_some() {
        return Err("PIRC_WORKSPACE_KIND is retired; the node must supply PIRC_MODE".into());
    }
    let mode: Mode = serde_json::from_str(
        &env("PIRC_MODE").ok_or("PIRC_MODE is required; the node must supply a validated mode")?,
    )
    .map_err(|error| format!("Invalid PIRC_MODE: {error}"))?;
    let config_dir = default_config_dir(env);
    let global = parse_global(&read_json(&js::path_join(&[&config_dir, "config.json"]))?)?;
    // Project config comes from the session's workspace only: a team child
    // in another directory keeps its parent's (H4).
    let child = truthy_env(env, "PIRC_TEAM_AGENT").is_some();
    let project_root = match truthy_env(env, "PIRC_PROJECT_ROOT") {
        Some(root) if child => js::path_resolve(&[&root]),
        _ => workspace.to_owned(),
    };
    let project_dir = js::path_join(&[&project_root, ".pirc"]);
    let parsed = if mode.project_config {
        read_project_config(&project_root)?
    } else {
        ProjectConfig::default()
    };
    // hooks / env / allowedPaths / defaultModel only when the user trusted
    // exactly these values (H3, L12).
    let fields = project_trust_fields(&parsed);
    let trusted_hash = parse_trust_hash(env("PIRC_PROJECT_TRUST").as_deref());
    let untrusted = !project_trust_empty(&fields)
        && trusted_hash.as_deref() != Some(project_trust_hash(&fields).as_str());
    let project = if untrusted {
        ProjectConfig::default()
    } else {
        parsed
    };
    let mut warnings = Vec::new();
    if untrusted && !child {
        warnings.push(untrusted_project_warning(&fields));
    }
    if let Some(warning) = workspace_memory_config_warning(&global.features) {
        warnings.push(warning);
    }
    if !child && crate::auto_mode::uses_retired_enabled(&global.features) {
        warnings.push(RETIRED_AUTO_MODE_SWITCH.to_owned());
    }
    let resolve_paths = |items: &[String], base: &str| -> Vec<String> {
        items
            .iter()
            .map(|item| js::path_resolve(&[base, &expand_home(item)]))
            .collect()
    };
    // Skills are read by the file tools but are configuration, like .pirc/.
    let skill_paths =
        crate::skills::skill_read_paths(&crate::skills::skill_roots(&config_dir, &project_root));
    let mut allowed_paths = vec![workspace.to_owned()];
    allowed_paths.extend(resolve_paths(&global.allowed_paths, &config_dir));
    allowed_paths.extend(resolve_paths(&project.allowed_paths, &project_root));
    allowed_paths.extend(skill_paths.iter().cloned());
    let mut hooks = global.hooks.clone();
    for event in HOOK_EVENTS {
        hooks
            .list_mut(event)
            .extend(project.hooks.list(event).iter().cloned());
    }
    let writable: Vec<String> = allowed_paths
        .into_iter()
        .collect::<indexmap::IndexSet<_>>()
        .into_iter()
        .collect();
    let sandboxed = env("PIRC_SANDBOX").as_deref() == Some("srt");
    let node_policy = parse_path_policy(env("PIRC_SANDBOX_POLICY").as_deref())?;
    // The node's read rules always; its write rules only when srt enforces
    // them (unsandboxed, the configured allowedPaths still apply).
    let path_policy = match node_policy {
        Some(node) => PathPolicy {
            deny_read: node.deny_read,
            allow_read: node.allow_read,
            allow_write: if sandboxed {
                node.allow_write
            } else {
                writable.clone()
            },
            deny_write: if sandboxed {
                node.deny_write
            } else {
                Vec::new()
            },
            shared_write: if sandboxed { node.shared_write } else { None },
        },
        None => pirc_policy::default_path_policy(&writable, &js::home_dir()),
    };
    let system_prompt = mode_prompt_sections(&mode, &config_dir, workspace, &project_dir)?;
    let default_model = project
        .default_model
        .clone()
        .or_else(|| models.default_model.clone());
    let mut protected_paths = vec![
        project_dir.clone(),
        js::path_join(&[workspace, ".pirc"]),
        // A hook runs as the user on the next commit.
        js::path_join(&[workspace, ".git", "hooks"]),
    ];
    protected_paths.extend(skill_paths);
    // The node's role files and chat prompts: only the user writes them.
    protected_paths.push(js::path_join(&[&config_dir, "roles"]));
    // On a shared gateway/node host these files define capability grants.
    protected_paths.extend(pirc_policy::session::mode_write_paths(&config_dir)?);
    let mut features = global.features;
    apply_mode_features(&mut features, &mode);
    Ok(AgentConfig {
        role_dirs: crate::roles::role_dirs(&config_dir, &project_root),
        config_dir,
        workspace: workspace.to_owned(),
        models,
        default_model,
        allowed_paths: writable,
        protected_paths,
        project_root,
        warnings,
        path_policy,
        sandboxed,
        env: merge_env(&global.env, &project.env),
        hooks,
        limits: global.limits,
        features,
        system_prompt,
        mode,
    })
}

/// Render only the selected sources, preserving mode order and the legacy
/// section ids/titles. An unselected file is not read (or allowed to fail startup).
fn mode_prompt_sections(
    mode: &Mode,
    config_dir: &str,
    workspace: &str,
    project_dir: &str,
) -> Result<Vec<PromptSection>, String> {
    let mut sections = Vec::new();
    for source in &mode.prompt {
        let section = match source {
            ModePromptSection::Base => {
                PromptSection::new("base", "Coding instructions", "built-in", BASE_PROMPT)
            }
            ModePromptSection::Body => PromptSection::new(
                "mode:body",
                "Mode instructions",
                &format!("mode:{}", mode.id),
                &mode.body,
            ),
            ModePromptSection::AgentsGlobal
            | ModePromptSection::AgentsWorkspace
            | ModePromptSection::AgentsProject => {
                let (dir, kind) = match source {
                    ModePromptSection::AgentsGlobal => (config_dir, "global"),
                    ModePromptSection::AgentsWorkspace => (workspace, "workspace"),
                    ModePromptSection::AgentsProject => (project_dir, "project"),
                    _ => unreachable!(),
                };
                let file = js::path_join(&[dir, "AGENTS.md"]);
                PromptSection::new(
                    &format!("agents:{kind}"),
                    &format!("AGENTS.md ({kind})"),
                    &file,
                    read_text(&file)?,
                )
            }
        };
        if !section.text.is_empty() {
            sections.push(section);
        }
    }
    Ok(sections)
}

/// Apply mode defaults without overriding an explicit node switch. Feature
/// implementations still decide runtime readiness (gateway, browser, child, etc.).
pub(crate) fn apply_mode_features(features: &mut Map<String, Value>, mode: &Mode) {
    for key in pirc_protocol::mode::FEATURE_NAMES {
        let explicit = features
            .get(*key)
            .and_then(|settings| settings.get("enabled"))
            .and_then(Value::as_bool);
        if explicit.is_some() {
            continue;
        }
        let enabled = if mode.features_on.iter().any(|name| name == key) {
            true
        } else if mode.feature_off(key) {
            false
        } else {
            continue;
        };
        let settings = features
            .entry((*key).to_owned())
            .or_insert_with(|| Value::Object(Map::new()));
        // Keep malformed node settings intact so their feature's validator can
        // report them rather than silently replacing them with defaults.
        if let Some(settings) = settings.as_object_mut() {
            settings.insert("enabled".into(), Value::Bool(enabled));
        }
    }
}

impl AgentConfig {
    /// What this session's workspace allows.
    pub fn mode(&self) -> &Mode {
        &self.mode
    }

    /// Preserve a mode's default-off switch even when a feature's settings
    /// validator falls back to its schema defaults. An explicit node opt-in
    /// still takes precedence; legacy malformed settings outside a default-off
    /// mode keep their existing fallback behavior.
    pub(crate) fn feature_disabled_by_mode(&self, key: &str) -> bool {
        self.mode.feature_off(key) && self.feature_disabled(key)
    }

    pub(crate) fn feature_disabled(&self, key: &str) -> bool {
        match self
            .features
            .get(key)
            .and_then(|settings| settings.get("enabled"))
            .and_then(Value::as_bool)
        {
            Some(enabled) => !enabled,
            None => self.mode.feature_off(key),
        }
    }
}

/// `configRoles(config)`: the roles this agent's workspace defines.
pub fn config_roles(config: &AgentConfig) -> Result<IndexMap<String, RolePreset>, String> {
    crate::roles::read_roles(&config.role_dirs)
}

/// `sessionSettings(branch, config)`: the latest recorded model and
/// thinking level, else the defaults.
pub fn session_settings(
    branch: &[SessionEntry],
    default_model: Option<&ModelRef>,
    models: &Models,
) -> (Option<(String, String)>, ThinkingLevel) {
    let change = branch.iter().rev().find_map(|entry| match &entry.data {
        EntryData::ModelChange { provider, model_id } => Some((provider.clone(), model_id.clone())),
        _ => None,
    });
    let level = branch.iter().rev().find_map(|entry| match &entry.data {
        EntryData::ThinkingLevelChange { thinking_level } => Some(thinking_level.clone()),
        _ => None,
    });
    let model = change
        .or_else(|| default_model.map(|fallback| (fallback.provider.clone(), fallback.id.clone())))
        .or_else(|| {
            let (name, provider) = models.providers.first()?;
            let first = provider.models.first()?;
            (!name.is_empty()).then(|| (name.clone(), first.id.clone()))
        });
    let thinking = match level {
        Some(level) => thinking_level(&level),
        None => default_model.and_then(|fallback| fallback.thinking),
    }
    .unwrap_or(ThinkingLevel::Medium);
    (model, thinking)
}

#[cfg(test)]
mod tests;
