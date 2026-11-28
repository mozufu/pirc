//! Auto mode (`agent/auto-mode/index.ts`, `rules.ts`): a pre-execution
//! filter for shell actions (`bash`, `background_task` start/write) and for
//! `ptc` scripts, which only the user's deny-list can stop.
//!
//! 1. Static rules ([`rules::classify_shell`]) sort the action into read /
//!    write / danger, or `unknown`. The user's deny-list
//!    (`features.autoMode.deny`) is matched first and always means danger.
//! 2. `unknown` actions go to a model classifier ([`classifier`]; models
//!    from `features.autoMode`, then the session model). It sees the
//!    human's recent requests and the session handoff facts the human is the
//!    source of, never tool output. If no model answers, the action is
//!    treated as a write.
//! 3. `danger` needs a human: with a UI the user confirms; headless agents
//!    are refused.
//! 4. Anything that may write takes the node's write lease first: only the
//!    known targets when the rules know every path a command writes, else
//!    the working directory.
//!
//! That is the `auto` approval mode, the default. The node config
//! (`features.autoMode.mode`) and each session ([`AgentHost::approval_mode`])
//! may pick another (security audit L14):
//!
//! - `read-only`: only actions the rules judge read-only run; anything else,
//!   and every `write`/`edit`, waits for the user (headless agents are
//!   refused). No classifier model is asked.
//! - `full-access`: no classification gate at all.
//!
//! In every mode the deny-list still asks the user and writes still take the
//! lease; the OS sandbox does not depend on the mode.
//!
//! Keystrokes for a tty task are judged together with the rest of the line
//! they belong to, so a command cannot be smuggled in one harmless-looking
//! fragment at a time.

pub mod classifier;
pub mod rules;

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

use indexmap::IndexMap;
use pirc_policy::resolve_path;
use pirc_protocol::ThinkingLevel;
use serde_json::{Map, Value};

use crate::host::AgentHost;
use crate::signal::AbortSignal;
use crate::tools::js::{self, JsRegex};
use crate::ui::{DialogOptions, NotifyLevel};
use classifier::{ClassifyResult, ModelChoice, classify_with_model};
use rules::{Classification, RuleContext, Verdict, classify_shell, compile_deny, deny_match};

/// How much an agent may do without asking (`features.autoMode.mode`, or
/// a session's own choice).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum ApprovalMode {
    /// Only read-only actions run without the user.
    ReadOnly,
    /// Rules, then the classifier; only danger asks.
    #[default]
    Auto,
    /// No classification gate (the deny-list and the lease remain).
    FullAccess,
}

impl ApprovalMode {
    pub const ALL: [Self; 3] = [Self::ReadOnly, Self::Auto, Self::FullAccess];

    pub fn as_str(self) -> &'static str {
        match self {
            Self::ReadOnly => "read-only",
            Self::Auto => "auto",
            Self::FullAccess => "full-access",
        }
    }

    pub fn parse(text: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|mode| mode.as_str() == text)
    }
}

/// `AutoModeSettings`: `features.autoMode` without the deny-list.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AutoModeSettings {
    /// The node's default approval mode (`mode`; the retired `enabled`
    /// maps `false` to full access and `true` to auto, and `mode` wins).
    pub mode: ApprovalMode,
    /// Send statically unclear actions to a model; false treats them as
    /// writes. Auto mode only.
    pub use_model: bool,
    /// Show the classifier the session handoff facts (the human's earlier
    /// constraints and decisions).
    pub use_memory: bool,
    /// Classifier model; defaults to the session model.
    pub model: Option<ModelChoice>,
    pub fallback_models: Vec<ModelChoice>,
    pub timeout_ms: u64,
}

impl Default for AutoModeSettings {
    fn default() -> Self {
        Self {
            mode: ApprovalMode::Auto,
            use_model: true,
            use_memory: true,
            model: None,
            fallback_models: Vec::new(),
            timeout_ms: 30_000,
        }
    }
}

/// `modelChoice.safeParse(value)`.
fn model_choice(value: &Value) -> Option<ModelChoice> {
    let Value::Object(choice) = value else {
        return None;
    };
    let text = |key: &str| match choice.get(key) {
        Some(Value::String(s)) if !s.is_empty() => Some(s.clone()),
        _ => None,
    };
    let thinking = match choice.get("thinking") {
        None => None,
        Some(level @ Value::String(_)) => {
            Some(serde_json::from_value::<ThinkingLevel>(level.clone()).ok()?)
        }
        Some(_) => return None,
    };
    Some(ModelChoice {
        provider: text("provider")?,
        id: text("id")?,
        thinking,
    })
}

/// `z.array(modelChoice)`: `None` when any item is invalid.
fn model_choices(value: &Value) -> Option<Vec<ModelChoice>> {
    value.as_array()?.iter().map(model_choice).collect()
}

/// `autoModeSettings(features)`: all-or-nothing, so a broken setting
/// elsewhere restores the defaults.
pub fn auto_mode_settings(features: &Map<String, Value>) -> AutoModeSettings {
    let defaults = AutoModeSettings::default();
    let settings = match features.get("autoMode") {
        Some(Value::Object(settings)) => settings,
        _ => return defaults,
    };
    let mut parsed = defaults.clone();
    let mut legacy = None;
    let mut mode = None;
    for (key, value) in settings {
        let valid = match key.as_str() {
            "mode" => value
                .as_str()
                .and_then(ApprovalMode::parse)
                .map(|chosen| mode = Some(chosen)),
            // Before the modes: `enabled: false` turned every check off.
            "enabled" => value.as_bool().map(|flag| {
                legacy = Some(if flag {
                    ApprovalMode::Auto
                } else {
                    ApprovalMode::FullAccess
                })
            }),
            "useModel" => value.as_bool().map(|flag| parsed.use_model = flag),
            "useMemory" => value.as_bool().map(|flag| parsed.use_memory = flag),
            "model" => model_choice(value).map(|choice| parsed.model = Some(choice)),
            "fallbackModels" => {
                model_choices(value).map(|choices| parsed.fallback_models = choices)
            }
            "timeoutMs" => value
                .as_f64()
                .filter(|ms| ms.fract() == 0.0 && *ms > 0.0 && *ms <= 120_000.0)
                .map(|ms| parsed.timeout_ms = ms as u64),
            _ => Some(()),
        };
        if valid.is_none() {
            return defaults;
        }
    }
    parsed.mode = mode.or(legacy).unwrap_or_default();
    parsed
}

/// Session entry recording the approval mode the user chose for a session.
pub const APPROVAL_MODE_ENTRY: &str = "agent.approvalMode";

/// The approval mode a session's branch records, if the user chose one.
pub fn recorded_approval_mode(
    branch: &[crate::session_store::SessionEntry],
) -> Option<ApprovalMode> {
    branch.iter().rev().find_map(|entry| match &entry.data {
        crate::session_store::EntryData::Custom { custom_type, data }
            if custom_type == APPROVAL_MODE_ENTRY =>
        {
            data.get("mode")
                .and_then(Value::as_str)
                .and_then(ApprovalMode::parse)
        }
        _ => None,
    })
}

/// The node's default approval mode for new sessions.
pub fn default_approval_mode(features: &Map<String, Value>) -> ApprovalMode {
    auto_mode_settings(features).mode
}

/// `features.autoMode.enabled` is set: the node config uses the retired
/// switch (a warning says to use `mode`).
pub fn uses_retired_enabled(features: &Map<String, Value>) -> bool {
    features
        .get("autoMode")
        .and_then(|mode| mode.get("enabled"))
        .is_some()
}

/// `autoModeSettings(features).useModel` (default true).
pub fn auto_mode_use_model(features: &Map<String, Value>) -> bool {
    auto_mode_settings(features).use_model
}

/// `classifierChoices`: auto mode's own models (the session model is
/// appended later).
pub fn classifier_choices(features: &Map<String, Value>) -> Vec<ModelChoice> {
    let settings = auto_mode_settings(features);
    settings
        .model
        .into_iter()
        .chain(settings.fallback_models)
        .collect()
}

/// `autoModeDeny(features)`: the user's deny-list, read on its own so a
/// mistake elsewhere in the settings cannot drop it; a bare string counts
/// as one pattern.
pub fn auto_mode_deny(features: &Map<String, Value>) -> Vec<String> {
    match features.get("autoMode").and_then(|mode| mode.get("deny")) {
        Some(Value::String(pattern)) => vec![pattern.clone()],
        Some(Value::Array(items)) => items
            .iter()
            .filter_map(|item| item.as_str().map(str::to_owned))
            .collect(),
        _ => Vec::new(),
    }
}

/// What kind of shell action a call performs.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ActionKind {
    Command,
    Script,
    Input,
}

/// `ShellAction`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ShellAction {
    pub tool: String,
    pub kind: ActionKind,
    pub text: String,
    pub cwd: String,
}

/// Where a decision came from.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Source {
    Rules,
    Model,
    Fallback,
}

/// `AutoModeDecision`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Decision {
    pub classification: Classification,
    pub source: Source,
}

/// Model verdicts kept (read/write only).
const CACHE_LIMIT: usize = 256;
/// Unsubmitted tty input kept per task (the current line).
const INPUT_LINE_LIMIT: usize = 4_096;
const INPUT_TASK_LIMIT: usize = 64;
const TRUNCATED: &str = "⟨earlier keystrokes truncated⟩";
const CTRL_C: &str = "⟨Ctrl-C⟩";

/// `visibleKeys`: control keys become `⟨Ctrl-X⟩` (`⟨Esc⟩`, `⟨Tab⟩` …) so
/// neither the rules nor the model mistake them for text.
pub fn visible_keys(input: &str) -> String {
    let normalized = input.replace("\r\n", "\n").replace('\r', "\n");
    let mut out = String::new();
    for c in normalized.chars() {
        let code = c as u32;
        if code <= 0x08 || (0x0b..=0x1f).contains(&code) || code == 0x7f || c == '\t' {
            let name = match c {
                '\u{1b}' => "Esc".to_owned(),
                '\u{7f}' | '\u{08}' => "Backspace".to_owned(),
                '\t' => "Tab".to_owned(),
                _ => format!(
                    "Ctrl-{}",
                    char::from_u32(code + 64).expect("an ASCII letter")
                ),
            };
            out.push_str(&format!("⟨{name}⟩"));
        } else {
            out.push(c);
        }
    }
    out
}

struct PendingLine {
    text: String,
    truncated: bool,
}

/// `String(args.id ?? '')`.
fn id_of(args: &Map<String, Value>) -> String {
    match args.get("id") {
        None | Some(Value::Null) => String::new(),
        Some(value) => js::string_of(value),
    }
}

/// `AutoMode`.
#[derive(Default)]
pub struct AutoMode {
    /// Model verdicts that need no human (read/write), by kind + cwd +
    /// action.
    cache: RefCell<IndexMap<String, Decision>>,
    /// Per tty task: what was typed since the last Enter (or Ctrl-C).
    lines: RefCell<IndexMap<String, PendingLine>>,
    /// Per tty task: writes are judged one at a time, in order.
    input_gates: RefCell<HashMap<String, Rc<tokio::sync::Mutex<()>>>>,
    warned_deny: RefCell<String>,
    warned_failure: std::cell::Cell<bool>,
}

impl AutoMode {
    pub fn new() -> Self {
        Self::default()
    }

    fn deny(&self, host: &dyn AgentHost) -> Vec<JsRegex> {
        let (deny, invalid) = compile_deny(&auto_mode_deny(&host.config().features));
        let key = invalid.join("\n");
        if !key.is_empty() && *self.warned_deny.borrow() != key {
            *self.warned_deny.borrow_mut() = key;
            host.ui().notify(
                &format!(
                    "Auto mode: deny-list pattern(s) are not valid regular expressions and are matched as plain text: {}",
                    invalid.join(", ")
                ),
                NotifyLevel::Warning,
            );
        }
        deny
    }

    /// Static verdict for an action.
    fn rules_verdict(&self, host: &dyn AgentHost, action: &ShellAction) -> Classification {
        let deny = self.deny(host);
        if action.kind == ActionKind::Script {
            return deny_match(&action.text, &deny).unwrap_or_else(|| Classification {
                verdict: Verdict::Read,
                reason: "a ptc script has no authority of its own; its operations are checked one by one".to_owned(),
                denied: false,
                writes: None,
            });
        }
        let config = host.config();
        let guard = host.guard();
        let rules = classify_shell(
            &action.text,
            &RuleContext {
                cwd: &action.cwd,
                roots: guard.allowed_roots(),
                protected_paths: &config.protected_paths,
                home: None,
                deny: &deny,
            },
        );
        if action.kind == ActionKind::Input
            && action.text.contains('⟨')
            && matches!(rules.verdict, Verdict::Read | Verdict::Write)
        {
            return Classification {
                verdict: Verdict::Unknown,
                reason: "the keystrokes include terminal control keys (editing, completion or history) or are partly shown".to_owned(),
                denied: false,
                writes: None,
            };
        }
        rules
    }

    /// `actionFor`: the action a tool call would perform, or `None` when
    /// auto mode does not gate it.
    pub fn action_for(
        &self,
        host: &dyn AgentHost,
        tool: &str,
        args: &Map<String, Value>,
    ) -> Option<ShellAction> {
        let cwd = host.config().workspace.clone();
        let action = |kind, text: &str, cwd: String| {
            Some(ShellAction {
                tool: tool.to_owned(),
                kind,
                text: text.to_owned(),
                cwd,
            })
        };
        match (tool, args.get("action")) {
            ("bash", _) => match args.get("command") {
                Some(Value::String(command)) => action(ActionKind::Command, command, cwd),
                _ => None,
            },
            // Scripts run isolated; their operations are gated one by one.
            ("ptc", _) => match args.get("code") {
                Some(Value::String(code)) => action(ActionKind::Script, code, cwd),
                _ => None,
            },
            ("background_task", Some(Value::String(kind))) if kind == "start" => {
                let Some(Value::String(command)) = args.get("command") else {
                    return None;
                };
                let dir = match args.get("cwd") {
                    None | Some(Value::Null) => ".".to_owned(),
                    Some(value) => js::string_of(value),
                };
                let dir = dir.strip_prefix('@').unwrap_or(&dir);
                action(ActionKind::Command, command, resolve_path(&cwd, dir))
            }
            ("background_task", Some(Value::String(kind))) if kind == "write" => {
                let Some(Value::String(input)) = args.get("input") else {
                    return None;
                };
                let lines = self.lines.borrow();
                let line = lines.get(&id_of(args));
                let text = format!(
                    "{}{}",
                    line.map_or("", |line| line.text.as_str()),
                    visible_keys(input)
                );
                let text = if line.is_some_and(|line| line.truncated) {
                    format!("{TRUNCATED}{text}")
                } else {
                    text
                };
                action(ActionKind::Input, &text, cwd)
            }
            _ => None,
        }
    }

    /// Remember the unsubmitted part of a tty task's input after it was let
    /// through.
    fn typed(&self, args: &Map<String, Value>, action: &ShellAction) {
        let id = id_of(args);
        let mut truncated = action.text.starts_with(TRUNCATED);
        let mut text = action
            .text
            .strip_prefix(TRUNCATED)
            .unwrap_or(&action.text)
            .to_owned();
        // Enter submits the line; Ctrl-C discards it.
        let submitted = text
            .rfind('\n')
            .map_or(0, |index| index + 1)
            .max(text.rfind(CTRL_C).map_or(0, |index| index + CTRL_C.len()));
        if submitted > 0 {
            text = text[submitted..].to_owned();
            truncated = false;
        }
        let mut lines = self.lines.borrow_mut();
        lines.shift_remove(&id);
        if text.is_empty() {
            return;
        }
        if js::len16(&text) > INPUT_LINE_LIMIT {
            text = js::tail16(&text, INPUT_LINE_LIMIT).to_owned();
            truncated = true;
        }
        if lines.len() >= INPUT_TASK_LIMIT {
            lines.shift_remove_index(0);
        }
        lines.insert(id, PendingLine { text, truncated });
    }

    /// `classify`: the decision for an action. `Err` when `signal` was
    /// aborted while the classifier model was asked.
    pub async fn classify(
        &self,
        host: &dyn AgentHost,
        action: &ShellAction,
        signal: &AbortSignal,
    ) -> Result<Decision, String> {
        let settings = auto_mode_settings(&host.config().features);
        let rules = self.rules_verdict(host, action);
        let decided = |classification| Decision {
            classification,
            source: Source::Rules,
        };
        // The deny-list is the user's own rule: it holds in every mode.
        if rules.denied {
            return Ok(decided(rules));
        }
        // No classifier outside auto mode. Full access: a lease decision
        // only, so anything not clearly read-only writes. Read-only: an
        // unclear action is a write, which asks the user there.
        let mode = host.approval_mode();
        let lease_only = match mode {
            ApprovalMode::Auto => false,
            ApprovalMode::ReadOnly => rules.verdict == Verdict::Unknown,
            ApprovalMode::FullAccess => !matches!(rules.verdict, Verdict::Read | Verdict::Write),
        };
        if lease_only {
            return Ok(decided(Classification {
                verdict: Verdict::Write,
                reason: rules.reason,
                denied: false,
                writes: None,
            }));
        }
        if mode != ApprovalMode::Auto || rules.verdict != Verdict::Unknown {
            return Ok(decided(rules));
        }
        let fallback = |reason| Decision {
            classification: Classification {
                verdict: Verdict::Write,
                reason,
                denied: false,
                writes: None,
            },
            source: Source::Fallback,
        };
        if !settings.use_model {
            return Ok(fallback(format!("{} (model check disabled)", rules.reason)));
        }
        // Rules (and the deny-list) run before the cache, so a cached model
        // verdict never outlives a newly added deny pattern.
        let kind = match action.kind {
            ActionKind::Command => "command",
            ActionKind::Script => "script",
            ActionKind::Input => "input",
        };
        let key = format!("{kind}\0{}\0{}", action.cwd, action.text);
        if let Some(cached) = self.cache.borrow().get(&key) {
            return Ok(cached.clone());
        }
        let result = classify_with_model(
            host,
            action,
            &rules.reason,
            &classifier_choices(&host.config().features),
            signal,
            settings.timeout_ms,
            settings.use_memory,
        )
        .await?;
        let (verdict, reason) = match result {
            ClassifyResult::Ok {
                verdict, reason, ..
            } => (verdict, reason),
            ClassifyResult::Failed(error) => {
                if !self.warned_failure.replace(true) {
                    host.ui().notify(
                        &format!(
                            "Auto mode: classifier unavailable ({error}); treating unclear shell actions as writes"
                        ),
                        NotifyLevel::Warning,
                    );
                }
                return Ok(fallback(format!(
                    "{}; classifier unavailable",
                    rules.reason
                )));
            }
        };
        self.warned_failure.set(false);
        let decision = Decision {
            classification: Classification {
                verdict,
                reason,
                denied: false,
                writes: None,
            },
            source: Source::Model,
        };
        if verdict != Verdict::Danger {
            let mut cache = self.cache.borrow_mut();
            if cache.len() >= CACHE_LIMIT {
                cache.shift_remove_index(0);
            }
            cache.insert(key, decision.clone());
        }
        Ok(decision)
    }

    /// `gate`: `Ok(Some(refusal))` for the model, `Ok(None)` when the call
    /// may run (after taking the write lease when needed), `Err` when the
    /// lease was refused.
    pub async fn gate(
        &self,
        host: &dyn AgentHost,
        tool: &str,
        args: &Map<String, Value>,
        signal: &AbortSignal,
    ) -> Result<Option<String>, String> {
        // Keystrokes for one task are judged one write at a time: concurrent
        // writes must not split a line into pieces judged apart.
        let input = tool == "background_task"
            && matches!(args.get("action"), Some(Value::String(action)) if action == "write");
        if !input {
            return self.gate_now(host, tool, args, signal).await;
        }
        let id = id_of(args);
        let gate = self
            .input_gates
            .borrow_mut()
            .entry(id.clone())
            .or_default()
            .clone();
        let result = {
            let _turn = gate.lock().await;
            self.gate_now(host, tool, args, signal).await
        };
        // Only the map and this call hold it: nobody else is waiting.
        if Rc::strong_count(&gate) == 2 {
            self.input_gates.borrow_mut().remove(&id);
        }
        result
    }

    async fn gate_now(
        &self,
        host: &dyn AgentHost,
        tool: &str,
        args: &Map<String, Value>,
        signal: &AbortSignal,
    ) -> Result<Option<String>, String> {
        let mode = host.approval_mode();
        if mode == ApprovalMode::ReadOnly && matches!(tool, "write" | "edit") {
            // The file tools take their own lease; read-only asks first.
            let path = args.get("path").map(js::string_of).unwrap_or_default();
            let request = Approval {
                label: "File change",
                tool,
                place: &host.config().workspace,
                text: &path,
                reason: &format!("{tool} changes {path}"),
                read_only: true,
            };
            return Ok(self.approve(host, &request, signal).await);
        }
        let Some(action) = self.action_for(host, tool, args) else {
            return Ok(None);
        };
        let decision = self.classify(host, &action, signal).await?;
        let verdict = decision.classification.verdict;
        let ask = match mode {
            ApprovalMode::ReadOnly => verdict != Verdict::Read,
            ApprovalMode::Auto | ApprovalMode::FullAccess => verdict == Verdict::Danger,
        };
        if ask {
            let request = Approval {
                label: match action.kind {
                    ActionKind::Input => "Input",
                    ActionKind::Script => "Script",
                    ActionKind::Command => "Command",
                },
                tool: &action.tool,
                place: &action.cwd,
                text: &action.text,
                reason: &decision.classification.reason,
                read_only: verdict != Verdict::Danger,
            };
            if let Some(refusal) = self.approve(host, &request, signal).await {
                return Ok(Some(refusal));
            }
        }
        if decision.classification.verdict != Verdict::Read {
            for target in lease_targets(&action, &decision) {
                host.acquire_write(&target, signal).await?;
            }
        }
        if action.kind == ActionKind::Input {
            self.typed(args, &action);
        }
        Ok(None)
    }

    async fn approve(
        &self,
        host: &dyn AgentHost,
        request: &Approval<'_>,
        signal: &AbortSignal,
    ) -> Option<String> {
        let advice = "Do not try to reach the same effect another way; explain what you intended and ask the user to run or approve it.";
        let reason = request.reason;
        if !host.has_ui() {
            return Some(if request.read_only {
                format!(
                    "{reason}. This session is in read-only mode: anything that may change files needs a human, and this agent has no UI. {advice}"
                )
            } else {
                format!(
                    "{reason}. Dangerous actions need a human and this agent has no UI. {advice}"
                )
            });
        }
        // Clients show this frame in their own words (`apps/app/lib/src/known_text.dart`,
        // `KnownText.kt`): change it there too.
        let message = format!(
            "{} ({}, in {}):\n\n{}\n\nReason: {reason}",
            request.label,
            request.tool,
            request.place,
            js::head16(request.text, 4_000)
        );
        let answer = host
            .ui()
            .confirm(
                if request.read_only {
                    pirc_protocol::READ_ONLY_APPROVAL_TITLE
                } else {
                    pirc_protocol::AUTO_MODE_APPROVAL_TITLE
                },
                &message,
                DialogOptions {
                    signal: Some(signal.clone()),
                    ..DialogOptions::default()
                },
            )
            .await;
        if answer == Some(true) {
            return None;
        }
        Some(format!(
            "{reason}. The user {} it. {advice}",
            if answer == Some(false) {
                "declined"
            } else {
                "did not approve"
            }
        ))
    }
}

/// What the user is asked to allow.
struct Approval<'a> {
    label: &'a str,
    tool: &'a str,
    /// The working directory (or workspace) it acts in.
    place: &'a str,
    text: &'a str,
    reason: &'a str,
    /// Asked because of read-only mode, not because it is dangerous.
    read_only: bool,
}

/// What a writing action's lease must cover: the exact targets when the
/// static rules know every path a command writes, else its whole working
/// directory. Keystrokes are excluded: their shell may have moved.
fn lease_targets(action: &ShellAction, decision: &Decision) -> Vec<String> {
    let classification = &decision.classification;
    if action.kind == ActionKind::Command
        && decision.source == Source::Rules
        && classification.verdict == Verdict::Write
        && let Some(writes) = classification.writes.as_ref().filter(|w| !w.is_empty())
    {
        let mut unique: Vec<String> = Vec::new();
        for target in writes {
            if !unique.contains(target) {
                unique.push(target.clone());
            }
        }
        return unique;
    }
    vec![action.cwd.clone()]
}

#[cfg(test)]
mod tests;
