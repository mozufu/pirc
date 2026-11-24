//! The agent (`agent/agent.ts`): queues, the run loop, model calls with
//! retries and role fallbacks, tool execution through the policy chain
//! (validation, hooks, auto mode, write lease), and the API the RPC layer
//! drives. Built-in features (todo, goal, …) hook in where the TS agent
//! called them (`crate::feature`).

use std::cell::{Cell, RefCell};
use std::collections::{HashMap, HashSet};
use std::rc::{Rc, Weak};
use std::time::Duration;

use indexmap::IndexMap;
use pirc_policy::PathGuard;
use pirc_protocol::{
    AssistantContent, AssistantMessage, Message, ModelRef, Models, StopReason, ThinkingLevel,
    ToolChoice, ToolSpec, UserBlock, UserContent,
};
use serde_json::{Map, Value, json};
use tokio::sync::{Notify, oneshot};

use crate::auto_mode::{
    APPROVAL_MODE_ENTRY, ApprovalMode, AutoMode, default_approval_mode, recorded_approval_mode,
};
use crate::capabilities::{Capabilities, capability_for_tool};
use crate::compaction::{self, CompactionReason, CompactionSettings};
use crate::config::{AgentConfig, session_settings};
use crate::context::{self, ContextInput, PromptSection, join_prompt};
use crate::feature::{BeforeStart, Feature, PromptAddition};
use crate::hooks::{HookName, HookRunner};
use crate::host::AgentHost;
use crate::messages::empty_usage;
use crate::ptc::{self, CapabilityRegistry, DIRECT_CAPABILITIES, WRAPPER_NAMES};
use crate::roles::{AgentRole, expand_models, read_roles};
use crate::rpc::Write;
use crate::run_loop::{CallEnd, Reply, RunLoop};
use crate::session_store::{EntryData, OPERATION_ENTRY, SessionEntry, SessionStore};
use crate::signal::{AbortController, AbortSignal};
use crate::stream::{StreamFn, StreamRequest};
use crate::tools::{AcquireWrite, HumanWait, Tool, ToolContext, ToolResult};
use crate::ui::{Choice, DialogOptions, NotifyLevel, Ui};
use crate::{LocalBoxFuture, now_ms};
use pirc_agent_loop::{
    CallKey, NotRun, ToolCall, ToolOutcome, WaitReason, WaitToken, is_context_overflow,
};

/// Session entry recording the role a session started in.
const ROLE_ENTRY: &str = "agent.role";
const RETRY_DELAYS: [u64; 3] = [2_000, 5_000, 15_000];
const INTERRUPTED_PARTIAL_CHARS: usize = 2000;

/// `AgentOptions`.
pub struct AgentOptions {
    pub config: AgentConfig,
    pub capabilities: Capabilities,
    /// A chat project's instructions from the node.
    pub project_instructions: Option<String>,
    /// A role from the configure line.
    pub role: Option<AgentRole>,
    pub store: SessionStore,
    /// Events and side-channel requests (stdout).
    pub emit: Write,
    pub ui: Rc<dyn Ui>,
    pub has_ui: bool,
    pub tools: Vec<Rc<dyn Tool>>,
    /// Built-in features, in hook order.
    pub features: Vec<Rc<dyn Feature>>,
    /// The write-lease transport (`processWriteLease`); `None` grants all.
    pub acquire_write: Option<AcquireWrite>,
    /// Only these capabilities (a restricted kind).
    pub allowed_tools: Option<Vec<String>>,
    /// Test seam: the model.
    pub stream_override: Option<Rc<dyn StreamFn>>,
}

/// Which queue `send_now` takes from.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Queue {
    Steering,
    FollowUp,
}

/// Who named the session.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NameSource {
    User,
    Auto,
}

impl NameSource {
    fn as_str(self) -> &'static str {
        match self {
            Self::User => "user",
            Self::Auto => "auto",
        }
    }
}

/// A message from outside the conversation (`deliver`).
#[derive(Clone, Debug, PartialEq)]
pub struct Delivery {
    pub custom_type: String,
    pub content: String,
    pub display: bool,
    pub details: Option<Value>,
}

/// `QueueItem`.
#[derive(Clone, Debug)]
enum QueueItem {
    User {
        text: String,
        images: Vec<UserBlock>,
    },
    Custom(Box<Message>),
}

/// `ResolvedModel`.
#[derive(Clone)]
pub struct ResolvedModel {
    pub provider_name: String,
    pub provider: pirc_protocol::Provider,
    pub model: pirc_protocol::Model,
}

/// Runs on the final reply just before its `message_end`; an error ends
/// the call without that `message_end` (TS: a throw out of `beforeEnd`).
pub type BeforeEnd = Box<dyn FnMut(&AssistantMessage) -> Result<(), String>>;

/// Options of one model call (`stream`'s options).
#[derive(Default)]
pub struct StreamOptions {
    /// Emit `message_*` events (default true).
    pub quiet: bool,
    pub max_tokens: Option<u64>,
    pub tool_choice: Option<ToolChoice>,
    /// Appended after the history, not persisted.
    pub extra_messages: Vec<Message>,
    /// Only context entries before this entry id.
    pub up_to: Option<String>,
    pub thinking: Option<ThinkingLevel>,
    /// `retries: false`.
    pub no_retries: bool,
    pub refresh_prompt: bool,
    /// Persist the reply just before its `message_end`, so an event is never
    /// ahead of the session file.
    pub before_end: Option<BeforeEnd>,
    /// The run's own reply: its progress goes to the run's agent loop.
    pub progress: bool,
}

/// `Agent`.
pub struct Agent {
    weak: Weak<Agent>,
    capabilities: RefCell<Capabilities>,
    project_instructions: Option<String>,
    role: RefCell<Option<AgentRole>>,
    config: Rc<AgentConfig>,
    /// The gateway's live public catalog (`refreshModels` replaces it).
    models: RefCell<Models>,
    store: RefCell<SessionStore>,
    guard: Rc<PathGuard>,
    hooks: HookRunner,
    auto_mode: AutoMode,
    /// The approval mode the user chose for this session (or a team child
    /// got from its parent); `None` follows the node's default.
    approval_mode: Cell<Option<ApprovalMode>>,
    /// Custom entries admitted during the current run that the user
    /// approved as their own requests (a delegated task with
    /// `details.asUserRequest`): auto mode's classifier reads them as user
    /// requests until the run ends.
    run_user_requests: RefCell<Vec<String>>,
    /// The user's own words a delegated task carried (`details.userRequests`,
    /// verified in their chat by its agent): the classifier reads them as
    /// user requests until the run ends.
    run_user_quotes: RefCell<Vec<String>>,
    /// The UI with dialogs linked to the operation that opens them.
    ui: Rc<dyn Ui>,
    has_ui: bool,
    emit_raw: Write,
    /// Internal capabilities, by name.
    tools: RefCell<IndexMap<String, Rc<dyn Tool>>>,
    /// `ptc` and `ptc_docs`.
    wrappers: RefCell<IndexMap<String, Rc<dyn Tool>>>,
    registry: CapabilityRegistry,
    stream_override: Option<Rc<dyn StreamFn>>,
    write_lease: Option<AcquireWrite>,
    steering: RefCell<Vec<QueueItem>>,
    follow_ups: RefCell<Vec<QueueItem>>,
    running: Cell<bool>,
    /// A run task is alive (`runPromise`).
    run_active: Cell<bool>,
    run_done: Notify,
    controller: RefCell<Option<AbortController>>,
    /// Aborts only the current model call and tool batch.
    turn: RefCell<Option<AbortController>>,
    /// `sendNow` arrived between turns.
    interrupt_pending: Cell<bool>,
    extra_system_prompt: RefCell<String>,
    /// What features added to the system prompt for the latest run.
    feature_prompts: RefCell<IndexMap<String, Vec<PromptSection>>>,
    dirty_prompts: RefCell<HashSet<String>>,
    last_context: RefCell<Option<Value>>,
    compacting: RefCell<Option<AbortController>>,
    pub(crate) usage_context: RefCell<Option<compaction::UsageContext>>,
    closed: Cell<bool>,
    model_ref: RefCell<Option<(String, String)>>,
    thinking: Cell<ThinkingLevel>,
    session_name: RefCell<Option<String>>,
    name_source: Cell<Option<NameSource>>,
    /// Side-panel sections changed since the last [`Agent::flush_panel`].
    changed_sections: RefCell<Vec<String>>,
    /// Operations still running (`activeOperations`). Work an operation
    /// started may outlive it and keep its scope ([`OPERATION_SCOPE`]); only
    /// a live operation is named on a dialog.
    active_operations: RefCell<HashSet<String>>,
    /// The model call each running `ptc` operation belongs to.
    operation_parents: RefCell<HashMap<String, String>>,
    /// The running run's progression ([`crate::run_loop`]).
    run_loop: RefCell<Option<RunLoop>>,
    features: Vec<Rc<dyn Feature>>,
    /// Wakes [`Agent::wait_for_completion`] (`completionWake`).
    completion_wake: Notify,
    completion_waiting: RefCell<Vec<String>>,
    completion_revision: Cell<u64>,
    /// The latest completion wait waited for a feature.
    completion_waited: Cell<bool>,
    /// Dialogs and other waits for a human now open (`openDialogs`).
    open_dialogs: Cell<usize>,
    human_wait_listeners: RefCell<Vec<(u64, HumanWaitListener)>>,
    next_listener: Cell<u64>,
    /// Capabilities started by `ptc` executions still running, one set per
    /// execution (`runningScripts`): their results are not in the session
    /// yet, so features that judge where content came from (memory
    /// provenance) consult this too.
    running_scripts: RefCell<Vec<ScriptCapabilities>>,
}

/// The features' start of a run: `start_features`' outcome and the
/// prompt sections they added.
type StartResult = (Result<(), String>, Vec<PromptSection>);
type AdmissionReceipt = oneshot::Sender<Result<(), String>>;

/// A journal append may have reached disk before returning an error. Neither
/// RPC nor its caller may turn this into a safely retryable rejection.
pub(crate) const ADMISSION_OUTCOME_UNKNOWN: &str =
    "Message admission could not be confirmed; inspect the conversation before retrying.";

/// What of a run's start is left for the run task.
enum Start {
    Failed(String),
    /// No features: the queued items still to admit when `beforePrompt`
    /// hooks made admitting wait.
    Admit(Option<Vec<QueueItem>>),
    /// The features' start, under way.
    Starting(LocalBoxFuture<'static, StartResult>),
}

/// Told whether a human is being asked (`onHumanWait`).
pub type HumanWaitListener = Rc<dyn Fn(bool)>;

/// The capability names one running `ptc` execution started.
pub type ScriptCapabilities = Rc<RefCell<Vec<String>>>;

/// `sanitizeHistory`: every tool call has a result and no result is
/// orphaned, so providers accept the history.
pub fn sanitize_history(messages: &[Message]) -> Vec<Message> {
    pirc_agent_loop::history::project(messages, now_ms())
}

/// JavaScript's `String.prototype.length` slicing, by UTF-16 units.
fn slice16(text: &str, max: usize) -> (String, bool) {
    let mut units = 0;
    let mut out = String::new();
    for c in text.chars() {
        units += c.len_utf16();
        if units > max {
            return (out, true);
        }
        out.push(c);
    }
    (out, false)
}

/// `interruptedNote`: tell the model its reply was cut off by the user.
fn interrupted_note(message: &AssistantMessage) -> QueueItem {
    let partial: String = message
        .content
        .iter()
        .filter_map(|part| match part {
            AssistantContent::Text { text, .. } => Some(text.as_str()),
            _ => None,
        })
        .collect();
    let partial = js_trim(&partial);
    let (mut shown, cut) = slice16(partial, INTERRUPTED_PARTIAL_CHARS);
    if cut {
        shown.push('…');
    }
    let content = if shown.is_empty() {
        "[Your previous response was interrupted by the user before it produced any text.]"
            .to_owned()
    } else {
        format!("[Your previous response was interrupted by the user.] Partial output:\n\n{shown}")
    };
    QueueItem::Custom(Box::new(Message::Custom {
        custom_type: "interrupted".to_owned(),
        content,
        display: false,
        details: None,
        timestamp: now_ms(),
    }))
}

/// `/name args` (`/^\/([a-z][\w:-]*)(?:\s+([\s\S]*))?$/i` on the trimmed
/// text): the name and the trimmed arguments.
fn parse_command(text: &str) -> Option<(String, String)> {
    use std::sync::LazyLock;
    static COMMAND: LazyLock<regex_lite::Regex> = LazyLock::new(|| {
        regex_lite::Regex::new(
            r"(?s)^/([A-Za-z][A-Za-z0-9_:-]*)(?:[\t\n\x0B\x0C\r \u{a0}\u{1680}\u{2000}-\u{200a}\u{2028}\u{2029}\u{202f}\u{205f}\u{3000}\u{feff}]+(.*))?$",
        )
        .unwrap()
    });
    let found = COMMAND.captures(js_trim(text))?;
    let name = found.get(1).map_or("", |m| m.as_str()).to_owned();
    let args = js_trim(found.get(2).map_or("", |m| m.as_str())).to_owned();
    Some((name, args))
}

use crate::tools::js::trim as js_trim;

/// `lenientArgs`: a direct call's arguments as `main` accepted them before
/// schemas were checked: null for an optional argument means absent, and a
/// closed schema ignores unknown keys.
pub fn lenient_args(tool: Option<&Rc<dyn Tool>>, args: &Map<String, Value>) -> Map<String, Value> {
    let Some(tool) = tool else {
        return args.clone();
    };
    let schema = tool.parameters();
    let Some(properties) = schema.get("properties").and_then(Value::as_object) else {
        return args.clone();
    };
    if args.contains_key("__invalid_json") {
        return args.clone();
    }
    let required: Vec<&str> = schema
        .get("required")
        .and_then(Value::as_array)
        .map(|items| items.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default();
    let closed = schema.get("additionalProperties") == Some(&Value::Bool(false));
    args.iter()
        .filter(|(key, value)| {
            !(value.is_null() && !required.contains(&key.as_str()))
                && (!closed || properties.contains_key(*key))
        })
        .map(|(key, value)| (key.clone(), value.clone()))
        .collect()
}

fn text_block(text: impl Into<String>) -> UserBlock {
    UserBlock::Text {
        text: text.into(),
        text_signature: None,
    }
}

fn thinking_name(level: ThinkingLevel) -> &'static str {
    match level {
        ThinkingLevel::Off => "off",
        ThinkingLevel::Minimal => "minimal",
        ThinkingLevel::Low => "low",
        ThinkingLevel::Medium => "medium",
        ThinkingLevel::High => "high",
        ThinkingLevel::Xhigh => "xhigh",
    }
}

fn parse_thinking(level: &str) -> Option<ThinkingLevel> {
    serde_json::from_value(json!(level)).ok()
}

/// Waits until a run has ended (`idle`).
async fn sleep_or_abort(ms: u64, signal: &AbortSignal) {
    tokio::select! {
        () = tokio::time::sleep(Duration::from_millis(ms)) => {}
        () = signal.cancelled() => {}
    }
}

/// The UI with dialogs linked to the direct tool call that opens them and
/// counted as waits for a human (`trackDialogs`), so a running `ptc`
/// script's active-time budget pauses while a human answers.
struct TrackingUi {
    inner: Rc<dyn Ui>,
    agent: Weak<Agent>,
}

impl TrackingUi {
    /// The linked options, and the wait counted from now until the dialog's
    /// future is done (or dropped).
    fn link(&self, mut opts: DialogOptions) -> (DialogOptions, DialogWait) {
        let Some(agent) = self.agent.upgrade() else {
            return (opts, (HumanWait::none(), None));
        };
        if opts.tool_call_id.is_none() {
            opts.tool_call_id = agent.current_operation();
        }
        let reason = if APPROVAL_GATE.try_with(|()| ()).is_ok() {
            WaitReason::Approval
        } else {
            WaitReason::Other("dialog".to_owned())
        };
        let call_wait = agent.loop_wait(reason, opts.tool_call_id.as_deref());
        (opts, (agent.human_wait(), call_wait))
    }
}

/// What a dialog holds while it is open: the human wait, and the running
/// call's wait if the dialog is the call's.
type DialogWait = (HumanWait, Option<LoopWait>);

/// A wait of the run's running call, told to its agent loop; it ends when
/// dropped.
struct LoopWait {
    agent: Weak<Agent>,
    token: WaitToken,
}

impl Drop for LoopWait {
    fn drop(&mut self) {
        if let Some(agent) = self.agent.upgrade() {
            agent.with_run_loop(|run_loop| run_loop.end_wait(&self.token));
        }
    }
}

/// Clears the run's agent loop when the run ends, however it ends.
struct RunLoopGuard<'a>(&'a RefCell<Option<RunLoop>>);

impl Drop for RunLoopGuard<'_> {
    fn drop(&mut self) {
        *self.0.borrow_mut() = None;
    }
}

/// `future`, holding `wait` until it is done.
fn while_waiting<'a, T: 'a>(
    future: LocalBoxFuture<'a, T>,
    wait: DialogWait,
) -> LocalBoxFuture<'a, T> {
    Box::pin(async move {
        let value = future.await;
        drop(wait);
        value
    })
}

impl Ui for TrackingUi {
    fn select<'a>(
        &'a self,
        title: &'a str,
        options: &'a [String],
        opts: DialogOptions,
    ) -> LocalBoxFuture<'a, Option<String>> {
        let (opts, wait) = self.link(opts);
        while_waiting(self.inner.select(title, options, opts), wait)
    }
    fn choose<'a>(
        &'a self,
        title: &'a str,
        options: &'a [Choice],
        multiple: bool,
        opts: DialogOptions,
    ) -> LocalBoxFuture<'a, Option<Vec<String>>> {
        let (opts, wait) = self.link(opts);
        while_waiting(self.inner.choose(title, options, multiple, opts), wait)
    }
    fn confirm<'a>(
        &'a self,
        title: &'a str,
        message: &'a str,
        opts: DialogOptions,
    ) -> LocalBoxFuture<'a, Option<bool>> {
        let (opts, wait) = self.link(opts);
        while_waiting(self.inner.confirm(title, message, opts), wait)
    }
    fn input<'a>(
        &'a self,
        title: &'a str,
        placeholder: Option<&'a str>,
        opts: DialogOptions,
    ) -> LocalBoxFuture<'a, Option<String>> {
        let (opts, wait) = self.link(opts);
        while_waiting(self.inner.input(title, placeholder, opts), wait)
    }
    fn editor<'a>(
        &'a self,
        title: &'a str,
        prefill: Option<&'a str>,
        opts: DialogOptions,
    ) -> LocalBoxFuture<'a, Option<String>> {
        let (opts, wait) = self.link(opts);
        while_waiting(self.inner.editor(title, prefill, opts), wait)
    }
    fn notify(&self, message: &str, level: NotifyLevel) {
        self.inner.notify(message, level);
    }
    fn set_status(&self, key: &str, text: Option<&str>) {
        self.inner.set_status(key, text);
    }
    fn set_widget(&self, key: &str, lines: Option<&[String]>) {
        self.inner.set_widget(key, lines);
    }
}

/// Ends a [`Agent::run_operation`] for observers when dropped, also when
/// the operation's future is dropped before it finished.
struct OperationEnd {
    agent: Weak<Agent>,
    parent_tool_call_id: String,
    operation_id: String,
    name: String,
    shown: Value,
    signal: AbortSignal,
    result: Option<ToolResult>,
}

impl Drop for OperationEnd {
    fn drop(&mut self) {
        let Some(agent) = self.agent.upgrade() else {
            return;
        };
        let result = self.result.take().unwrap_or_else(|| {
            ToolResult::error(if self.signal.aborted() {
                "Cancelled"
            } else {
                "The operation failed unexpectedly"
            })
        });
        agent.end_operation(
            &self.parent_tool_call_id,
            &self.operation_id,
            &self.name,
            std::mem::take(&mut self.shown),
            result,
        );
    }
}

/// Clears `compacting` when dropped.
struct CompactingGuard<'a>(&'a RefCell<Option<AbortController>>);

impl Drop for CompactingGuard<'_> {
    fn drop(&mut self) {
        *self.0.borrow_mut() = None;
    }
}

/// How far a capability call got (`OperationStage`): `Executed` means the
/// tool ran (its result may still be an error); the others mean it never
/// started.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OperationStage {
    Unavailable,
    Invalid,
    Denied,
    /// Held back by its caller ([`OperationOptions::withheld`]), e.g. after
    /// an earlier refusal.
    Withheld,
    Refused,
    Cancelled,
    Threw,
    Executed,
}

/// `OperationOptions`.
#[derive(Clone, Default)]
pub struct OperationOptions {
    /// Runs once the call has passed every check, with the name and
    /// arguments it will run with, right before the tool executes (a ptc
    /// execution takes its write slot here). `Err` stops the call as
    /// cancelled.
    pub before_execute: Option<BeforeExecute>,
    /// Checked before approval is asked and again right before the tool
    /// runs: a reason to hold the call back (a ptc script after one of its
    /// operations was refused), or `None`.
    pub withheld: Option<Withheld>,
}

/// [`OperationOptions::before_execute`].
pub type BeforeExecute =
    Rc<dyn Fn(String, Map<String, Value>) -> crate::LocalBoxFuture<'static, Result<(), ()>>>;
/// [`OperationOptions::withheld`].
pub type Withheld = Rc<dyn Fn(&str, &Map<String, Value>) -> Option<String>>;

/// `OperationOutcome`: how an operation ended. `hook_output`: what
/// `afterTool` hooks printed (also appended to the result), so a ptc result
/// can show it to the model even when the script drops the text.
#[derive(Clone, Debug)]
pub struct OperationOutcome {
    pub stage: OperationStage,
    pub result: ToolResult,
    pub hook_output: Option<String>,
}

tokio::task_local! {
    /// The `ptc` operation (or direct core call) running in this task's
    /// current future (`operationScope`): dialogs it opens are linked to it.
    static OPERATION_SCOPE: String;
    /// The run's model call this task's current future runs: its waits are
    /// told to the run's agent loop.
    static LOOP_CALL: CallKey;
    /// Inside the auto-mode gate: a dialog there asks for approval.
    static APPROVAL_GATE: ();
}

/// Longest argument string kept in operation events and session entries,
/// and the total (`RECORDED_STRING_CHARS`, `RECORDED_ARGS_CHARS`).
const RECORDED_STRING_CHARS: usize = 16_384;
const RECORDED_ARGS_CHARS: usize = 65_536;

/// `recordedArgs(args)`: arguments as recorded for an operation, long
/// strings cut and the whole bounded.
pub fn recorded_args(args: &Map<String, Value>) -> Value {
    fn cut(value: &Value, depth: usize) -> Value {
        match value {
            Value::String(text) => {
                let length = crate::tools::js::len16(text);
                if length > RECORDED_STRING_CHARS {
                    let (head, _) = slice16(text, 4096);
                    Value::String(format!("{head}…[{length} characters, truncated]"))
                } else {
                    value.clone()
                }
            }
            Value::Array(_) | Value::Object(_) if depth >= 4 => {
                let json = crate::tools::js::stringify(value);
                let length = crate::tools::js::len16(&json);
                if length > 1024 {
                    let (head, _) = slice16(&json, 1024);
                    Value::String(format!("{head}…[{length} characters, truncated]"))
                } else {
                    value.clone()
                }
            }
            Value::Array(items) => {
                let mut out: Vec<Value> = items
                    .iter()
                    .take(200)
                    .map(|item| cut(item, depth + 1))
                    .collect();
                if items.len() > 200 {
                    out.push(json!(format!("…[{} more items]", items.len() - 200)));
                }
                Value::Array(out)
            }
            Value::Object(object) => Value::Object(
                object
                    .iter()
                    .map(|(key, item)| (key.clone(), cut(item, depth + 1)))
                    .collect(),
            ),
            _ => value.clone(),
        }
    }
    let bounded = cut(&Value::Object(args.clone()), 0);
    let size = crate::tools::js::len16(&crate::tools::js::stringify(&bounded));
    if size <= RECORDED_ARGS_CHARS {
        bounded
    } else {
        json!({ "truncated": true, "characters": size })
    }
}

impl Agent {
    pub fn new(mut options: AgentOptions) -> Rc<Self> {
        crate::config::apply_mode_features(&mut options.config.features, &options.config.mode);
        // Keep disabled feature instances: their own settings gate tools and
        // hooks, while diagnostics and management commands remain available.
        // In particular, malformed memory settings must retain their validator's
        // fallback behavior rather than losing the feature wholesale.
        let config = Rc::new(options.config);
        let guard = Rc::new(PathGuard::new(
            &config.workspace,
            &config.path_policy,
            &config.protected_paths,
        ));
        let session_id = options.store.session_id();
        let agent = Rc::new_cyclic(|weak: &Weak<Agent>| {
            let ui: Rc<dyn Ui> = Rc::new(TrackingUi {
                inner: options.ui.clone(),
                agent: weak.clone(),
            });
            let warn_ui = options.ui.clone();
            let mut base = Map::new();
            base.insert("sessionId".to_owned(), json!(session_id));
            base.insert("cwd".to_owned(), json!(config.workspace));
            let hooks = HookRunner::new(
                config.hooks.clone(),
                config.workspace.clone(),
                config.env.clone(),
                base,
                Rc::new(move |message: &str| warn_ui.notify(message, NotifyLevel::Warning)),
            );
            let mut tools = IndexMap::new();
            for tool in options.tools {
                if !WRAPPER_NAMES.contains(&tool.name()) {
                    tools.insert(tool.name().to_owned(), tool);
                }
            }
            Agent {
                weak: weak.clone(),
                capabilities: RefCell::new(options.capabilities),
                project_instructions: options.project_instructions,
                role: RefCell::new(options.role),
                models: RefCell::new(config.models.clone()),
                config: config.clone(),
                store: RefCell::new(options.store),
                guard,
                hooks,
                auto_mode: AutoMode::new(),
                approval_mode: Cell::new(None),
                run_user_requests: RefCell::new(Vec::new()),
                run_user_quotes: RefCell::new(Vec::new()),
                ui,
                has_ui: options.has_ui,
                emit_raw: options.emit,
                tools: RefCell::new(tools),
                wrappers: RefCell::new(IndexMap::new()),
                registry: CapabilityRegistry::new(session_id.clone()),
                stream_override: options.stream_override,
                write_lease: options.acquire_write,
                steering: RefCell::new(Vec::new()),
                follow_ups: RefCell::new(Vec::new()),
                running: Cell::new(false),
                run_active: Cell::new(false),
                run_done: Notify::new(),
                controller: RefCell::new(None),
                turn: RefCell::new(None),
                interrupt_pending: Cell::new(false),
                extra_system_prompt: RefCell::new(String::new()),
                feature_prompts: RefCell::new(IndexMap::new()),
                dirty_prompts: RefCell::new(HashSet::new()),
                last_context: RefCell::new(None),
                compacting: RefCell::new(None),
                usage_context: RefCell::new(None),
                closed: Cell::new(false),
                model_ref: RefCell::new(None),
                thinking: Cell::new(ThinkingLevel::Medium),
                session_name: RefCell::new(None),
                name_source: Cell::new(None),
                changed_sections: RefCell::new(Vec::new()),
                active_operations: RefCell::new(HashSet::new()),
                operation_parents: RefCell::new(HashMap::new()),
                run_loop: RefCell::new(None),
                features: options.features,
                completion_wake: Notify::new(),
                completion_waiting: RefCell::new(Vec::new()),
                completion_revision: Cell::new(0),
                completion_waited: Cell::new(false),
                open_dialogs: Cell::new(0),
                human_wait_listeners: RefCell::new(Vec::new()),
                next_listener: Cell::new(0),
                running_scripts: RefCell::new(Vec::new()),
            }
        });
        // The wrappers are never capabilities: no recursive dispatch.
        for feature in agent.features.clone() {
            for tool in feature.tools(&agent) {
                if !WRAPPER_NAMES.contains(&tool.name()) {
                    agent
                        .tools
                        .borrow_mut()
                        .insert(tool.name().to_owned(), tool);
                }
            }
        }
        let host: Weak<dyn AgentHost> = {
            let weak: Weak<Agent> = Rc::downgrade(&agent);
            weak
        };
        for tool in ptc::model_tools(host, Rc::downgrade(&agent)) {
            agent
                .wrappers
                .borrow_mut()
                .insert(tool.name().to_owned(), tool);
        }
        // Apply the mode first: every later role/CLI/recorded allowlist can
        // only narrow it. PTC wrappers dispatch through this same operation map.
        if let Some(allowed) = &agent.config.mode.tools {
            agent.restrict_tools(allowed);
        }
        if let Some(allowed) = options.allowed_tools {
            agent.restrict_tools(&allowed);
        }
        agent.restore_settings();
        // A session started in a role keeps its role (and allowlist) on restart.
        if let Some((role, tools)) = agent.recorded_role()
            && agent.role.borrow().is_none()
        {
            *agent.role.borrow_mut() = Some(role);
            if let Some(tools) = tools {
                agent.restrict_tools(&tools);
            }
        }
        agent
    }

    /// `emit`: nothing once shut down.
    pub fn emit(&self, event: Value) {
        if !self.closed.get() {
            (self.emit_raw)(event);
        }
    }

    pub fn config(&self) -> Rc<AgentConfig> {
        self.config.clone()
    }

    /// Notify the user (`ui.notify`), e.g. the config's warnings.
    pub fn notify_warning(&self, message: &str) {
        self.ui.notify(message, NotifyLevel::Warning);
    }

    /// `init`: the `sessionStart` hooks, then the features'; `Err` ends the
    /// agent at startup.
    pub async fn init(self: &Rc<Self>) -> Result<(), String> {
        let extra = self.hooks.collect(HookName::SessionStart, Map::new()).await;
        *self.extra_system_prompt.borrow_mut() = extra;
        for feature in self.features.clone() {
            feature.init(self).await?;
        }
        Ok(())
    }

    fn restore_settings(&self) {
        let branch = self.store.borrow().branch();
        let (model, thinking) = {
            let models = self.models.borrow();
            session_settings(&branch, self.config.default_model.as_ref(), &models)
        };
        if model.is_some() {
            *self.model_ref.borrow_mut() = model;
        }
        self.thinking.set(thinking);
        self.approval_mode.set(recorded_approval_mode(&branch));
        if let Some(entry) = branch
            .iter()
            .rev()
            .find(|entry| matches!(entry.data, EntryData::SessionInfo { .. }))
            && let EntryData::SessionInfo { name, source } = &entry.data
        {
            *self.session_name.borrow_mut() = Some(name.clone());
            self.name_source
                .set(Some(if source.as_deref() == Some("auto") {
                    NameSource::Auto
                } else {
                    NameSource::User
                }));
        }
    }

    pub fn is_running(&self) -> bool {
        self.running.get()
    }

    /// Queued items, user and custom (`pendingCount`).
    pub fn pending_count(&self) -> usize {
        self.steering.borrow().len() + self.follow_ups.borrow().len()
    }

    /// The built-in features this agent runs, in hook order.
    pub fn features(&self) -> &[Rc<dyn Feature>] {
        &self.features
    }

    /// Some feature will start another run after this one settles
    /// (`Feature::will_continue`).
    pub fn will_continue(self: &Rc<Self>) -> bool {
        self.features
            .iter()
            .any(|feature| feature.will_continue(self))
    }

    /// Feature state changed: recheck completion without polling or calling
    /// the model (`completionChanged`).
    pub fn completion_changed(&self) {
        self.completion_revision
            .set(self.completion_revision.get() + 1);
        self.completion_wake.notify_waiters();
    }

    /// Remove only matching queued custom notifications; never human input
    /// (`discardNotifications`).
    pub fn discard_notifications(&self, predicate: impl Fn(&Message) -> bool) {
        let keep = |item: &QueueItem| match item {
            QueueItem::Custom(message) => !predicate(message),
            QueueItem::User { .. } => true,
        };
        self.steering.borrow_mut().retain(keep);
        self.follow_ups.borrow_mut().retain(keep);
    }

    /// `teamBatchSize`: how many adjacent team events lead the follow-up
    /// queue (at most 50, and past the first at most 40,000 bytes); a human
    /// follow-up is never reordered.
    fn team_batch_size(&self) -> usize {
        let follow_ups = self.follow_ups.borrow();
        let mut count = 0;
        let mut bytes = 0;
        while count < 50 {
            let Some(QueueItem::Custom(message)) = follow_ups.get(count) else {
                break;
            };
            if !matches!(&**message, Message::Custom { custom_type, .. } if custom_type == "agent-team")
            {
                break;
            }
            bytes +=
                crate::tools::js::stringify(&serde_json::to_value(&**message).unwrap_or_default())
                    .len();
            if count > 0 && bytes > 40_000 {
                break;
            }
            count += 1;
        }
        count
    }

    /// `waitForCompletion`: while features report blockers (team workers),
    /// wait for a change, up to `limits.completionWaitMs`; then tell the
    /// model what is still pending. True when the wait timed out.
    async fn wait_for_completion(self: &Rc<Self>, signal: &AbortSignal) -> bool {
        let deadline = tokio::time::Instant::now()
            + Duration::from_millis(self.config.limits.completion_wait_ms);
        let timed_out = loop {
            if signal.aborted() || self.pending_count() > 0 {
                break false;
            }
            let revision = self.completion_revision.get();
            let blockers: Vec<String> = self
                .features
                .iter()
                .flat_map(|feature| feature.completion_blockers(self))
                .collect();
            if blockers.is_empty() {
                break false;
            }
            *self.completion_waiting.borrow_mut() = blockers.clone();
            self.ui.set_status(
                "completion-wait",
                Some(&format!("Waiting for team: {}", blockers.join(", "))),
            );
            if tokio::time::Instant::now() >= deadline {
                let _ = self.deliver(
                    Delivery {
                        custom_type: "completion-timeout".to_owned(),
                        content: format!(
                            "Team completion wait timed out. These workers have NOT completed: {}. Report the pending work honestly; do not claim completion. Workers were not stopped.",
                            blockers.join(", ")
                        ),
                        display: true,
                        details: None,
                    },
                    false,
                    true,
                );
                break true;
            }
            let woken = self.completion_wake.notified();
            if signal.aborted()
                || self.pending_count() > 0
                || revision != self.completion_revision.get()
            {
                continue;
            }
            tokio::select! {
                () = woken => {}
                () = tokio::time::sleep_until(deadline.max(tokio::time::Instant::now() + Duration::from_millis(1))) => {}
                () = signal.cancelled() => {}
            }
        };
        let waited = !self.completion_waiting.borrow().is_empty();
        if waited {
            self.ui.set_status("completion-wait", None);
        }
        self.completion_waiting.borrow_mut().clear();
        if waited {
            // Woken by a feature (team events): let what it spawned (panel
            // flushes, a broker's next step) run before the run goes on.
            crate::yield_once().await;
        }
        self.completion_waited.set(waited);
        timed_out
    }

    /// Start a wait for a human (`humanWait`); it ends when the guard drops.
    pub fn human_wait(&self) -> HumanWait {
        let agent = self.weak.clone();
        HumanWait::new(Rc::new(move |delta: isize| {
            if let Some(agent) = agent.upgrade() {
                agent.human_wait_changed(delta);
            }
        }))
    }

    fn human_wait_changed(&self, delta: isize) {
        let before = self.open_dialogs.get() > 0;
        self.open_dialogs
            .set(self.open_dialogs.get().saturating_add_signed(delta));
        let after = self.open_dialogs.get() > 0;
        if before != after {
            let listeners: Vec<Rc<dyn Fn(bool)>> = self
                .human_wait_listeners
                .borrow()
                .iter()
                .map(|(_, listener)| listener.clone())
                .collect();
            for listener in listeners {
                listener(after);
            }
        }
    }

    /// Listen for "a human is being asked" (`onHumanWait`); told at once if
    /// one is. The id unsubscribes ([`Agent::off_human_wait`]).
    pub fn on_human_wait(&self, listener: Rc<dyn Fn(bool)>) -> u64 {
        let id = self.next_listener.get();
        self.next_listener.set(id + 1);
        self.human_wait_listeners
            .borrow_mut()
            .push((id, listener.clone()));
        if self.open_dialogs.get() > 0 {
            listener(true);
        }
        id
    }

    pub fn off_human_wait(&self, id: u64) {
        self.human_wait_listeners
            .borrow_mut()
            .retain(|(listener, _)| *listener != id);
    }

    /// `currentOperation`: the operation running in this task's current
    /// future, if it is still live (dialogs are linked to it).
    pub fn current_operation(&self) -> Option<String> {
        let id = OPERATION_SCOPE.try_with(Clone::clone).ok()?;
        self.active_operations.borrow().contains(&id).then_some(id)
    }

    /// `f` on the running run's agent loop, if a run is running.
    fn with_run_loop<T>(&self, f: impl FnOnce(&mut RunLoop) -> T) -> Option<T> {
        self.run_loop.try_borrow_mut().ok()?.as_mut().map(f)
    }

    /// A step of the run's agent loop; the run owns one while it runs.
    fn progression<T>(
        &self,
        f: impl FnOnce(&mut RunLoop) -> Result<T, String>,
    ) -> Result<T, String> {
        self.with_run_loop(f)
            .unwrap_or_else(|| Err("agent loop state: no run".to_owned()))
    }

    /// The running call waits for `reason` until the guard drops. The call
    /// is the one this task runs, else the one `operation` (a dialog's or
    /// lease's operation id) is or belongs to; other waits are not a call's.
    fn loop_wait(&self, reason: WaitReason, operation: Option<&str>) -> Option<LoopWait> {
        let key = LOOP_CALL.try_with(|key| *key).ok().or_else(|| {
            let operation = operation?;
            let parents = self.operation_parents.borrow();
            let id = parents.get(operation).map_or(operation, String::as_str);
            self.run_loop.try_borrow().ok()?.as_ref()?.running_call(id)
        })?;
        let token = self
            .with_run_loop(|run_loop| run_loop.wait(key, reason))
            .flatten()?;
        Some(LoopWait {
            agent: self.weak.clone(),
            token,
        })
    }

    /// Record a running `ptc` execution's capabilities (`runningScripts.add`).
    pub fn add_running_script(&self, names: ScriptCapabilities) {
        self.running_scripts.borrow_mut().push(names);
    }

    /// `runningScripts.delete`.
    pub fn remove_running_script(&self, names: &ScriptCapabilities) {
        self.running_scripts
            .borrow_mut()
            .retain(|item| !Rc::ptr_eq(item, names));
    }

    /// Capability names started by `ptc` executions still running.
    pub fn running_script_capabilities(&self) -> Vec<String> {
        self.running_scripts
            .borrow()
            .iter()
            .flat_map(|names| names.borrow().clone())
            .collect()
    }

    /// The session's current branch (`store.branch()`).
    pub fn branch(&self) -> Vec<SessionEntry> {
        self.store.borrow().branch()
    }

    /// Append a session entry (`store.append`); `Err` with the file
    /// system's error text.
    pub fn append_entry(&self, data: EntryData) -> Result<SessionEntry, String> {
        self.store.borrow_mut().append(data)
    }

    /// The newest entry of a type on the branch (`store.latest`).
    pub fn latest_entry(&self, type_name: &str) -> Option<SessionEntry> {
        self.store.borrow().latest(type_name)
    }

    /// Custom entries of a type on the branch (`store.customEntries`).
    pub fn custom_entries(&self, custom_type: &str) -> Vec<SessionEntry> {
        self.store.borrow().custom_entries(custom_type)
    }

    /// The session directory (`store.dir`).
    pub fn session_dir(&self) -> std::path::PathBuf {
        self.store.borrow().dir.clone()
    }

    /// The session file (`store.file`).
    pub fn session_file(&self) -> std::path::PathBuf {
        self.store.borrow().file.clone()
    }

    /// The gateway's policy for this project (`capabilities`).
    pub fn capabilities(&self) -> Capabilities {
        self.capabilities.borrow().clone()
    }

    /// Replace the gateway's policy (`agent.capabilities = …`): a chat
    /// reads its current one from the gateway.
    pub fn set_capabilities(&self, capabilities: Capabilities) {
        *self.capabilities.borrow_mut() = capabilities;
    }

    /// The path guard (`guard`).
    pub fn path_guard(&self) -> Rc<PathGuard> {
        self.guard.clone()
    }

    /// The capability registry (`capabilityRegistry`).
    pub fn registry(&self) -> &CapabilityRegistry {
        &self.registry
    }

    /// The current thinking level.
    pub fn thinking(&self) -> ThinkingLevel {
        self.thinking.get()
    }

    /// `isCompacting`.
    pub fn is_compacting(&self) -> bool {
        self.compacting.borrow().is_some()
    }

    /// Whether a human can answer dialogs (`hasUI`).
    pub fn has_ui(&self) -> bool {
        self.has_ui
    }

    /// `getTool`: a capability, unless the gateway's policy disables it.
    pub fn get_tool(&self, name: &str) -> Option<Rc<dyn Tool>> {
        if self
            .config
            .mode
            .tools
            .as_ref()
            .is_some_and(|allowed| !allowed.iter().any(|tool| tool == name))
        {
            return None;
        }
        if let Some(capability) = capability_for_tool(name)
            && !self.capabilities.borrow().allows(capability)
        {
            return None;
        }
        self.tools.borrow().get(name).cloned()
    }

    /// `toolList`: available internal capabilities.
    pub fn available_tools(&self) -> Vec<Rc<dyn Tool>> {
        let names: Vec<String> = self.tools.borrow().keys().cloned().collect();
        names
            .iter()
            .filter_map(|name| self.get_tool(name))
            .collect()
    }

    /// `directToolList`.
    pub fn direct_tools(&self) -> Vec<Rc<dyn Tool>> {
        DIRECT_CAPABILITIES
            .iter()
            .filter_map(|name| {
                let tool = self.get_tool(name)?;
                let same = self
                    .tools
                    .borrow()
                    .get(*name)
                    .is_some_and(|own| Rc::ptr_eq(own, &tool));
                same.then_some(tool)
            })
            .collect()
    }

    /// `modelToolList`: `ptc` and `ptc_docs` when any capability is
    /// available, then the direct core capabilities.
    fn model_tool_list(&self) -> Vec<Rc<dyn Tool>> {
        if self.available_tools().is_empty() {
            return Vec::new();
        }
        let mut list: Vec<Rc<dyn Tool>> = self.wrappers.borrow().values().cloned().collect();
        list.extend(self.direct_tools());
        list
    }

    /// `resolveModel`.
    pub fn resolve_model(
        &self,
        reference: Option<(String, String)>,
    ) -> Result<ResolvedModel, String> {
        let reference = reference.or_else(|| self.model_ref.borrow().clone());
        let Some((provider_name, id)) = reference else {
            return Err("No model configured. Add providers to the gateway models.json".to_owned());
        };
        let models = self.models.borrow();
        let provider = models.providers.get(&provider_name);
        let model = provider.and_then(|p| p.models.iter().find(|m| m.id == id));
        match (provider, model) {
            (Some(provider), Some(model)) => Ok(ResolvedModel {
                provider_name,
                provider: provider.clone(),
                model: model.clone(),
            }),
            _ => Err(format!("Unknown model {provider_name}/{id}")),
        }
    }

    /// `availableModels`: `listModels(config.models)`.
    pub fn available_models(&self) -> Vec<Value> {
        let models = self.models.borrow();
        models
            .providers
            .iter()
            .flat_map(|(provider, config)| {
                config.models.iter().map(move |model| {
                    json!({ "provider": provider, "id": model.id,
                        "name": model.name.as_ref().unwrap_or(&model.id),
                        "contextWindow": model.context_window, "maxTokens": model.max_tokens,
                        "reasoning": model.reasoning, "input": model.input })
                })
            })
            .collect()
    }

    /// `state()` (`get_state`).
    pub fn state(&self) -> Value {
        let model = self.resolve_model(None).ok().map(|resolved| {
            json!({ "provider": resolved.provider_name, "id": resolved.model.id,
                "name": resolved.model.name.as_ref().unwrap_or(&resolved.model.id),
                "contextWindow": resolved.model.context_window,
                "reasoning": resolved.model.reasoning })
        });
        let store = self.store.borrow();
        json!({
            "sessionId": store.session_id(),
            "sessionFile": store.file.display().to_string(),
            "sessionName": *self.session_name.borrow(),
            "sessionNameSource": self.name_source.get().map(NameSource::as_str),
            "model": model,
            "thinkingLevel": thinking_name(self.thinking.get()),
            "approvalMode": self.approval_mode().as_str(),
            "defaultApprovalMode": default_approval_mode(&self.config.features).as_str(),
            "isStreaming": self.running.get(),
            "completionWaiting": *self.completion_waiting.borrow(),
            "isCompacting": self.compacting.borrow().is_some(),
            "messageCount": store.all_messages().len(),
            "pendingMessageCount": self.pending_count(),
        })
    }

    /// Append a session entry; `Err` with the file system's error text.
    fn append(&self, data: EntryData) -> Result<String, String> {
        self.store.borrow_mut().append(data).map(|entry| entry.id)
    }

    pub fn set_model(&self, provider: &str, id: &str) -> Result<(), String> {
        self.resolve_model(Some((provider.to_owned(), id.to_owned())))?;
        *self.model_ref.borrow_mut() = Some((provider.to_owned(), id.to_owned()));
        self.append(EntryData::ModelChange {
            provider: provider.to_owned(),
            model_id: id.to_owned(),
        })?;
        Ok(())
    }

    /// `restrictTools`: keep only the named capabilities.
    fn restrict_tools(&self, names: &[String]) {
        let ignored: Vec<&String> = names
            .iter()
            .filter(|name| WRAPPER_NAMES.contains(&name.as_str()))
            .collect();
        let unknown: Vec<&String> = names
            .iter()
            .filter(|name| {
                !WRAPPER_NAMES.contains(&name.as_str()) && !self.tools.borrow().contains_key(*name)
            })
            .collect();
        self.tools
            .borrow_mut()
            .retain(|name, _| names.iter().any(|allowed| allowed == name));
        let unique = |items: Vec<&String>| {
            let mut out: Vec<&str> = Vec::new();
            for item in items {
                if !out.contains(&item.as_str()) {
                    out.push(item);
                }
            }
            out.join(", ")
        };
        if !ignored.is_empty() {
            self.ui.notify(
                &format!(
                    "Tool list: {} ignored; ptc and ptc_docs come with any capability",
                    unique(ignored)
                ),
                NotifyLevel::Warning,
            );
        }
        if !unknown.is_empty() {
            self.ui.notify(
                &format!(
                    "Tool list: unknown or unavailable capabilities {} grant nothing",
                    unique(unknown)
                ),
                NotifyLevel::Warning,
            );
        }
    }

    /// The role recorded on the branch, with its tool allowlist.
    fn recorded_role(&self) -> Option<(AgentRole, Option<Vec<String>>)> {
        let branch = self.store.borrow().branch();
        let data = branch.iter().rev().find_map(|entry| match &entry.data {
            EntryData::Custom { custom_type, data } if custom_type == ROLE_ENTRY => Some(data),
            _ => None,
        })?;
        let name = data.get("name")?.as_str()?.to_owned();
        let strings = |value: Option<&Value>| -> Option<Vec<String>> {
            value?.as_array().map(|items| {
                items
                    .iter()
                    .filter_map(|item| item.as_str().map(str::to_owned))
                    .collect()
            })
        };
        Some((
            AgentRole {
                name,
                instructions: data
                    .get("instructions")
                    .and_then(Value::as_str)
                    .map(str::to_owned),
                models: strings(data.get("models")),
            },
            strings(data.get("tools")),
        ))
    }

    /// `nextFallback`: the next catalog model after the current one along
    /// the role's model patterns.
    fn next_fallback(&self) -> Option<(String, String)> {
        let patterns = self.role.borrow().as_ref()?.models.clone()?;
        if patterns.is_empty() {
            return None;
        }
        let (provider, id) = self.model_ref.borrow().clone()?;
        let candidates = expand_models(&patterns, &self.models.borrow());
        match candidates
            .iter()
            .position(|(p, m)| *p == provider && *m == id)
        {
            Some(index) => candidates.get(index + 1).cloned(),
            None => {
                let known = self
                    .models
                    .borrow()
                    .providers
                    .get(&provider)
                    .is_some_and(|p| p.models.iter().any(|m| m.id == id));
                if known {
                    None
                } else {
                    candidates.first().cloned()
                }
            }
        }
    }

    /// `fallBack`: switch to the next fallback model; false when none. A
    /// failure to record the switch ends the call (TS: `setModel` throws).
    fn fall_back(&self, reason: &str) -> Result<bool, String> {
        let Some((provider, id)) = self.next_fallback() else {
            return Ok(false);
        };
        let from = self
            .model_ref
            .borrow()
            .as_ref()
            .map_or_else(|| "none".to_owned(), |(p, m)| format!("{p}/{m}"));
        self.set_model(&provider, &id)?;
        let (reason, _) = slice16(reason, 200);
        self.ui.notify(
            &format!("Model {from} failed ({reason}); switching to {provider}/{id}"),
            NotifyLevel::Warning,
        );
        Ok(true)
    }

    /// `setRole`: start this session in one of the workspace's roles.
    pub fn set_role(&self, name: &str) -> Result<(), String> {
        let current = self
            .role
            .borrow()
            .clone()
            .or_else(|| self.recorded_role().map(|(role, _)| role));
        if let Some(current) = current {
            if current.name == name {
                return Ok(());
            }
            return Err(format!(
                "This session already runs in role {}",
                current.name
            ));
        }
        if self
            .store
            .borrow()
            .branch()
            .iter()
            .any(|entry| matches!(entry.data, EntryData::Message(_)))
        {
            return Err("A role can only be set before the session starts".to_owned());
        }
        let roles = read_roles(&self.config.role_dirs)?;
        let Some(preset) = roles.get(name).cloned() else {
            let available: Vec<&str> = roles.keys().map(String::as_str).collect();
            return Err(format!(
                "Unknown role: {name}; available: {}",
                available.join(", ")
            ));
        };
        if let Some(patterns) = &preset.models {
            let candidates = expand_models(patterns, &self.models.borrow());
            let Some((provider, id)) = candidates.first().cloned() else {
                return Err(format!(
                    "No model matches role {name}: {}",
                    patterns.join(", ")
                ));
            };
            self.set_model(&provider, &id)?;
        }
        if let Some(thinking) = &preset.thinking {
            self.set_thinking(if thinking == "max" { "xhigh" } else { thinking })?;
        }
        let mut data = Map::new();
        data.insert("name".to_owned(), json!(name));
        if let Some(instructions) = &preset.instructions {
            data.insert("instructions".to_owned(), json!(instructions));
        }
        if let Some(tools) = &preset.tools {
            data.insert("tools".to_owned(), json!(tools));
        }
        if let Some(models) = &preset.models {
            data.insert("models".to_owned(), json!(models));
        }
        self.append(EntryData::Custom {
            custom_type: ROLE_ENTRY.to_owned(),
            data: Value::Object(data),
        })?;
        *self.role.borrow_mut() = Some(AgentRole {
            name: name.to_owned(),
            instructions: preset.instructions.clone(),
            models: preset.models.clone(),
        });
        if let Some(tools) = &preset.tools {
            self.restrict_tools(tools);
        }
        Ok(())
    }

    /// The session's approval mode: its own, else the node's default.
    pub fn approval_mode(&self) -> ApprovalMode {
        self.approval_mode
            .get()
            .unwrap_or_else(|| default_approval_mode(&self.config.features))
    }

    /// The user switches this session's approval mode (`set_approval_mode`);
    /// recorded, so it survives a restart, and passed on to the team.
    pub fn set_approval_mode(self: &Rc<Self>, mode: &str) -> Result<(), String> {
        let parsed = ApprovalMode::parse(mode).ok_or_else(|| {
            format!("Unknown approval mode {mode}: one of read-only, auto, full-access")
        })?;
        self.append(EntryData::Custom {
            custom_type: APPROVAL_MODE_ENTRY.to_owned(),
            data: json!({ "mode": parsed.as_str() }),
        })?;
        self.approval_mode.set(Some(parsed));
        self.emit(json!({ "type": "approval_mode_changed", "mode": parsed.as_str() }));
        for feature in &self.features {
            feature.approval_mode_changed(self, parsed);
        }
        Ok(())
    }

    pub fn set_thinking(&self, level: &str) -> Result<(), String> {
        let parsed =
            parse_thinking(level).ok_or_else(|| format!("Unknown thinking level {level}"))?;
        self.thinking.set(parsed);
        self.append(EntryData::ThinkingLevelChange {
            thinking_level: level.to_owned(),
        })?;
        Ok(())
    }

    pub fn session_name(&self) -> Option<String> {
        self.session_name.borrow().clone()
    }

    pub fn set_name(&self, name: &str, source: NameSource) -> Result<(), String> {
        if self.session_name.borrow().as_deref() == Some(name)
            && self.name_source.get() == Some(source)
        {
            return Ok(());
        }
        *self.session_name.borrow_mut() = Some(name.to_owned());
        self.name_source.set(Some(source));
        self.append(EntryData::SessionInfo {
            name: name.to_owned(),
            source: Some(source.as_str().to_owned()),
        })?;
        self.emit(json!({ "type": "session_name_changed", "name": name,
            "source": source.as_str() }));
        Ok(())
    }

    fn queue_texts(items: &[QueueItem]) -> Vec<String> {
        items
            .iter()
            .filter_map(|item| match item {
                QueueItem::User { text, .. } => Some(text.clone()),
                QueueItem::Custom(_) => None,
            })
            .collect()
    }

    fn emit_queue(&self) {
        let steering = Self::queue_texts(&self.steering.borrow());
        let follow_up = Self::queue_texts(&self.follow_ups.borrow());
        self.emit(json!({ "type": "queue_update", "steering": steering, "followUp": follow_up }));
    }

    /// `clearQueue`: `{steering, followUp}` texts.
    pub fn clear_queue(self: &Rc<Self>) -> Value {
        let cleared = json!({ "steering": Self::queue_texts(&self.steering.borrow()),
            "followUp": Self::queue_texts(&self.follow_ups.borrow()) });
        let notifications: Vec<Message> = self
            .steering
            .borrow()
            .iter()
            .chain(self.follow_ups.borrow().iter())
            .filter_map(|item| match item {
                QueueItem::Custom(message) => Some((**message).clone()),
                QueueItem::User { .. } => None,
            })
            .collect();
        for feature in &self.features {
            feature.notifications_cleared(self, &notifications);
        }
        self.steering.borrow_mut().clear();
        self.follow_ups.borrow_mut().clear();
        self.emit_queue();
        cleared
    }

    /// `tryCommand`: run `/name args` if a feature registered it (names may
    /// be namespaced, e.g. `om:status`); true when handled.
    fn try_command(self: &Rc<Self>, text: &str) -> bool {
        let Some((name, args)) = parse_command(text) else {
            return false;
        };
        let Some(feature) = self
            .features
            .iter()
            .find(|feature| {
                feature
                    .commands()
                    .iter()
                    .any(|command| command.name == name)
            })
            .cloned()
        else {
            return false;
        };
        let agent = self.clone();
        crate::spawn_eager(async move {
            if let Err(error) = feature.run_command(&agent, &name, args).await {
                agent.ui.notify(&error, NotifyLevel::Error);
            }
        });
        true
    }

    /// `panelState`: side-panel state contributed by features, merged.
    pub fn panel_state(self: &Rc<Self>) -> Value {
        let mut out = Map::new();
        for feature in &self.features {
            if let Some(panel) = feature.panel(self) {
                out.extend(panel);
            }
        }
        Value::Object(out)
    }

    /// A side-panel section changed; the client hears about it at the next
    /// [`Agent::flush_panel`], once for all sections changed by then.
    pub fn panel_changed(&self, section: &str) {
        let mut sections = self.changed_sections.borrow_mut();
        if !sections.iter().any(|s| s == section) {
            sections.push(section.to_owned());
        }
    }

    /// Emit one `panel_changed` for the sections changed since the last
    /// flush, if any. Called where a stretch of work ends and the client
    /// should refresh: before the model request, after a stream, at a
    /// retry's wait, after a tool or command, after a feature's event.
    pub fn flush_panel(&self) {
        let sections = std::mem::take(&mut *self.changed_sections.borrow_mut());
        if !sections.is_empty() {
            self.emit(json!({ "type": "panel_changed", "sections": sections }));
        }
    }

    /// `commandList`: the features' slash commands.
    pub fn command_list(&self) -> Vec<Value> {
        self.features
            .iter()
            .flat_map(|feature| feature.commands())
            .map(|command| {
                json!({ "name": command.name, "description": command.description,
                    "source": "extension" })
            })
            .collect()
    }

    /// `userInput`: a human submitted input.
    fn user_input(self: &Rc<Self>, text: &str) {
        for feature in &self.features {
            feature.user_input(self, text);
        }
    }

    fn user_item(text: String, images: Vec<UserBlock>) -> QueueItem {
        QueueItem::User { text, images }
    }

    /// Regenerate from an already persisted user-message branch.
    pub fn resume_branch(self: &Rc<Self>) -> Result<(), String> {
        if self.running.get() {
            return Err("Agent is already running".into());
        }
        if !matches!(self.all_messages().last(), Some(Message::User { .. })) {
            return Err("Branch must end with a user message".into());
        }
        self.start_run(Vec::new());
        Ok(())
    }

    /// Start a run; `Err` while one is active. Internal callers acknowledge
    /// scheduling here; the RPC path uses `prompt_admitted` to await storage.
    pub fn prompt(self: &Rc<Self>, text: String, images: Vec<UserBlock>) -> Result<(), String> {
        self.begin_prompt(text, images, None)
    }

    /// RPC acknowledgement waits for initial admission, including deferred
    /// feature/hook context. It does not wait for inference or tool execution.
    pub(crate) async fn prompt_admitted(
        self: &Rc<Self>,
        text: String,
        images: Vec<UserBlock>,
    ) -> Result<(), String> {
        let (receipt, answer) = oneshot::channel();
        self.begin_prompt(text, images, Some(receipt))?;
        match answer.await {
            Ok(Ok(())) => Ok(()),
            // A panic, cancellation or partial journal write is not proof that
            // nothing was admitted. Preserve the caller's operation identity.
            _ => Err(ADMISSION_OUTCOME_UNKNOWN.to_owned()),
        }
    }

    fn begin_prompt(
        self: &Rc<Self>,
        text: String,
        images: Vec<UserBlock>,
        receipt: Option<AdmissionReceipt>,
    ) -> Result<(), String> {
        if self.try_command(&text) {
            if let Some(receipt) = receipt {
                let _ = receipt.send(Ok(()));
            }
            return Ok(());
        }
        if self.running.get() {
            return Err("Agent is already running; use steer or follow_up".to_owned());
        }
        self.user_input(&text);
        self.start_run_receipted(vec![Self::user_item(text, images)], receipt);
        Ok(())
    }

    pub fn steer(self: &Rc<Self>, text: String, images: Vec<UserBlock>) {
        if self.try_command(&text) {
            return;
        }
        self.user_input(&text);
        let item = Self::user_item(text, images);
        if !self.running.get() {
            return self.start_run(vec![item]);
        }
        self.steering.borrow_mut().push(item);
        self.completion_changed();
        self.emit_queue();
    }

    pub fn follow_up(self: &Rc<Self>, text: String, images: Vec<UserBlock>) {
        if self.try_command(&text) {
            return;
        }
        self.user_input(&text);
        let item = Self::user_item(text, images);
        if !self.running.get() {
            return self.start_run(vec![item]);
        }
        self.follow_ups.borrow_mut().push(item);
        self.completion_changed();
        self.emit_queue();
    }

    /// `sendNow`: deliver the `index`th queued user message now.
    pub fn send_now(self: &Rc<Self>, queue: Queue, index: usize, text: &str) -> Result<(), String> {
        let list = match queue {
            Queue::Steering => &self.steering,
            Queue::FollowUp => &self.follow_ups,
        };
        let item = {
            let mut list = list.borrow_mut();
            let at = list
                .iter()
                .enumerate()
                .filter(|(_, item)| matches!(item, QueueItem::User { .. }))
                .map(|(i, _)| i)
                .nth(index);
            match at.map(|at| (at, &list[at])) {
                Some((at, QueueItem::User { text: queued, .. })) if queued == text => {
                    list.remove(at)
                }
                _ => return Err("That message is no longer queued".to_owned()),
            }
        };
        if !self.running.get() {
            self.emit_queue();
            self.start_run(vec![item]);
            return Ok(());
        }
        self.steering.borrow_mut().insert(0, item);
        self.emit_queue();
        self.completion_changed();
        let turn = self.turn.borrow().clone();
        match turn {
            Some(turn) => turn.abort(),
            None => self.interrupt_pending.set(true),
        }
        Ok(())
    }

    /// `deliver`: queued while running; idle, it starts a run or is
    /// recorded without one.
    pub fn deliver(
        self: &Rc<Self>,
        delivery: Delivery,
        trigger_turn: bool,
        follow_up: bool,
    ) -> Result<(), String> {
        // A trusted notice with an ID is applied once: a retransmission after a
        // lost reply, or to a restarted agent, finds it in the saved transcript.
        if let Some(notice) = delivery
            .details
            .as_ref()
            .and_then(|details| details.get("noticeId"))
            .and_then(Value::as_str)
        {
            let applied = self.branch().iter().any(|entry| {
                matches!(&entry.data, EntryData::Message(Message::Custom { custom_type, details: Some(details), .. })
                    if *custom_type == delivery.custom_type
                        && details.get("noticeId").and_then(Value::as_str) == Some(notice))
            });
            if applied {
                return Ok(());
            }
        }
        let message = Message::Custom {
            custom_type: delivery.custom_type,
            content: delivery.content,
            display: delivery.display,
            details: delivery.details,
            timestamp: now_ms(),
        };
        let item = QueueItem::Custom(Box::new(message.clone()));
        if self.running.get() {
            if follow_up {
                self.follow_ups.borrow_mut().push(item);
            } else {
                self.steering.borrow_mut().push(item);
            }
            self.completion_changed();
            return Ok(());
        }
        if trigger_turn {
            self.start_run(vec![item]);
        } else {
            self.append_message(message)?;
        }
        Ok(())
    }

    pub fn abort(self: &Rc<Self>) {
        for feature in &self.features {
            feature.abort(self);
        }
        // Clones first: abort listeners must be free to touch the agent.
        let controller = self.controller.borrow().clone();
        if let Some(controller) = controller {
            controller.abort();
        }
        let compacting = self.compacting.borrow().clone();
        if let Some(compacting) = compacting {
            compacting.abort();
        }
    }

    /// Resolves once no run is active (`idle`).
    pub async fn idle(&self) {
        loop {
            let done = self.run_done.notified();
            if !self.run_active.get() {
                return;
            }
            done.await;
        }
    }

    /// `appendMessage`: written, then announced.
    pub fn append_message(&self, message: Message) -> Result<String, String> {
        let id = self.append(EntryData::Message(message.clone()))?;
        let value = serde_json::to_value(&message).unwrap_or_default();
        self.emit(json!({ "type": "message_start", "message": value }));
        self.emit(json!({ "type": "message_end", "message": value }));
        Ok(id)
    }

    /// `startRun`. The TS agent ran `run()` at once up to its first await:
    /// `agent_start` and, without `beforePrompt` hooks (whose processes
    /// are that await), the admitted messages go out before the command
    /// that started the run is answered.
    fn start_run(self: &Rc<Self>, initial: Vec<QueueItem>) {
        self.start_run_receipted(initial, None);
    }

    fn start_run_receipted(
        self: &Rc<Self>,
        initial: Vec<QueueItem>,
        mut receipt: Option<AdmissionReceipt>,
    ) {
        self.running.set(true);
        self.run_active.set(true);
        let controller = AbortController::new();
        *self.controller.borrow_mut() = Some(controller.clone());
        self.emit(json!({ "type": "agent_start" }));
        // Features' `before_model_start` comes first and may wait, so with
        // features everything is admitted in the run task.
        let with_features = !self.features.is_empty();
        // Panel changes that led to this run (a feature's wake-up) reach
        // the client before the run's own events.
        if with_features {
            self.flush_panel();
        }
        // Only a user item awaits (`beforePrompt` hooks run before it), so
        // the items before the first one are admitted at once either way.
        let mut now = initial;
        let later = if with_features {
            std::mem::take(&mut now)
        } else if self.hooks.has(HookName::BeforePrompt) {
            let first_user = now
                .iter()
                .position(|item| matches!(item, QueueItem::User { .. }))
                .unwrap_or(now.len());
            now.split_off(first_user)
        } else {
            Vec::new()
        };
        let admitted = self.admit_now(now);
        // Keep synchronous admission/response ordering when no feature or hook
        // deferred it. On failure the spawned task only settles; it cannot infer
        // from old history after failing to append the new user's message.
        if (admitted.is_err() || (!with_features && later.is_empty()))
            && let Some(receipt) = receipt.take()
        {
            let _ = receipt.send(admitted.clone());
        }
        let start = match admitted {
            Err(error) => {
                self.start_failed(&error);
                Start::Failed(error)
            }
            Ok(()) if with_features => {
                let agent = self.clone();
                Start::Starting(Box::pin(async move {
                    let mut extra_prompt = Vec::new();
                    let result = agent.start_features(later, &mut extra_prompt).await;
                    (result, extra_prompt)
                }))
            }
            Ok(()) => Start::Admit((!later.is_empty()).then_some(later)),
        };
        let agent = self.clone();
        tokio::task::spawn_local(async move {
            let run = agent.clone();
            let signal = controller.signal();
            // A panic is a bug; it ends the run like a crash.
            let outcome =
                tokio::task::spawn_local(async move { run.run(signal, start, receipt).await })
                    .await;
            let error = match outcome {
                Ok(Ok(())) => None,
                Ok(Err(error)) => Some(error),
                // The payload may quote session content and is stored by
                // the node; it stays in the panic message on stderr.
                Err(_) => Some("internal error".to_owned()),
            };
            if let Some(error) = error {
                let message = format!("Agent loop crashed: {error}");
                agent.emit(json!({ "type": "agent_error", "error": message }));
                agent.ui.notify(&message, NotifyLevel::Error);
            }
            agent.running.set(false);
            // The user's approval of a delegated task covered this run only.
            agent.run_user_requests.borrow_mut().clear();
            agent.run_user_quotes.borrow_mut().clear();
            *agent.controller.borrow_mut() = None;
            agent.run_active.set(false);
            agent.run_done.notify_waiters();
            agent.settle(&controller.signal()).await;
        });
    }

    /// The start of a run with features: their `beforeAgentStart` in order
    /// (system prompt sections into `extra_prompt`, hidden messages after
    /// the run's first item), then admission. A failing feature skips the
    /// admission, as the TS agent's `try` did.
    async fn start_features(
        self: &Rc<Self>,
        mut items: Vec<QueueItem>,
        extra_prompt: &mut Vec<PromptSection>,
    ) -> Result<(), String> {
        let mut hidden = Vec::new();
        let signal = self
            .controller
            .borrow()
            .as_ref()
            .map(|c| c.signal())
            .unwrap_or_else(AbortSignal::never);
        for feature in self.features.clone() {
            self.dirty_prompts.borrow_mut().remove(feature.name());
            let result = feature.before_model_start(self, &signal).await?;
            let mut sections = Vec::new();
            if let Some(BeforeStart {
                system_prompt,
                messages,
            }) = result
            {
                match system_prompt {
                    Some(PromptAddition::Text(text)) if !text.is_empty() => {
                        sections.push(PromptSection::new(
                            feature.name(),
                            feature.name(),
                            &format!("feature:{}", feature.name()),
                            text,
                        ))
                    }
                    Some(PromptAddition::Sections(found)) => sections = found,
                    _ => {}
                }
                hidden.extend(messages);
            }
            if !signal.aborted() && !self.dirty_prompts.borrow().contains(feature.name()) {
                extra_prompt.extend(sections.clone());
                self.feature_prompts
                    .borrow_mut()
                    .insert(feature.name().into(), sections);
            }
        }
        let rest = if items.is_empty() {
            Vec::new()
        } else {
            items.split_off(1)
        };
        items.extend(
            hidden
                .into_iter()
                .map(|message| QueueItem::Custom(Box::new(message))),
        );
        items.extend(rest);
        self.admit(items).await
    }

    /// Report a failed start; the caller ends the run before inference.
    fn start_failed(&self, error: &str) {
        self.ui
            .notify(&format!("Failed to start run: {error}"), NotifyLevel::Error);
    }

    async fn settle(self: &Rc<Self>, signal: &AbortSignal) {
        self.emit(json!({ "type": "agent_settled" }));
        if self.hooks.has(HookName::AgentSettled) {
            let agent = self.clone();
            let count = self.store.borrow().all_messages().len();
            tokio::task::spawn_local(async move {
                let mut data = Map::new();
                data.insert("messageCount".to_owned(), json!(count));
                agent.hooks.run(HookName::AgentSettled, data, None).await;
            });
        }
        for feature in self.features.clone() {
            if let Err(error) = feature.settled_with_signal(self, signal).await {
                self.ui.notify(
                    &format!("{}: {error}", feature.name()),
                    NotifyLevel::Warning,
                );
            }
        }
        // A feature (e.g. background completion) may have queued work while settling.
        if !self.running.get() && self.pending_count() > 0 {
            let mut next = std::mem::take(&mut *self.steering.borrow_mut());
            next.append(&mut self.follow_ups.borrow_mut());
            self.emit_queue();
            self.start_run(next);
        }
    }

    /// `admitted`: tell the features a message reached model history.
    fn admitted(&self, message: &Message) {
        let Some(agent) = self.weak.upgrade() else {
            return;
        };
        for feature in &self.features {
            feature.message_admitted(&agent, message);
        }
    }

    /// One queued item into the session, without hooks.
    fn admit_item(&self, item: QueueItem) -> Result<(), String> {
        match item {
            QueueItem::Custom(message) => {
                let id = self.append_message((*message).clone())?;
                if let Message::Custom {
                    custom_type,
                    details: Some(details),
                    ..
                } = &*message
                    && custom_type == "assistant-delegation"
                {
                    if details.get("asUserRequest") == Some(&Value::Bool(true)) {
                        self.run_user_requests.borrow_mut().push(id);
                    }
                    if let Some(quotes) = details.get("userRequests").and_then(Value::as_array) {
                        self.run_user_quotes.borrow_mut().extend(
                            quotes
                                .iter()
                                .filter_map(Value::as_str)
                                .filter(|quote| !quote.trim().is_empty())
                                .map(str::to_owned),
                        );
                    }
                }
                self.admitted(&message);
            }
            QueueItem::User { text, images } => {
                let content = if images.is_empty() {
                    UserContent::Text(text)
                } else {
                    let mut blocks = vec![text_block(text)];
                    blocks.extend(images);
                    UserContent::Blocks(blocks)
                };
                self.append_message(Message::User {
                    content,
                    timestamp: now_ms(),
                })?;
            }
        }
        Ok(())
    }

    /// `admit` when no `beforePrompt` hook runs: nothing to wait for.
    fn admit_now(&self, items: Vec<QueueItem>) -> Result<(), String> {
        items.into_iter().try_for_each(|item| self.admit_item(item))
    }

    /// `admit`: `beforePrompt` hooks add hidden context before each prompt.
    async fn admit(&self, items: Vec<QueueItem>) -> Result<(), String> {
        for item in items {
            if let QueueItem::User { text, .. } = &item
                && self.hooks.has(HookName::BeforePrompt)
            {
                let mut data = Map::new();
                data.insert("prompt".to_owned(), json!(text));
                let extra = self.hooks.collect(HookName::BeforePrompt, data).await;
                if !extra.is_empty() {
                    self.append_message(Message::Custom {
                        custom_type: "hook-context".to_owned(),
                        content: crate::hooks::fence_output(HookName::BeforePrompt, &extra),
                        display: false,
                        details: None,
                        timestamp: now_ms(),
                    })?;
                }
            }
            self.admit_item(item)?;
        }
        Ok(())
    }

    /// The system prompt with the latest run's feature additions.
    pub fn system_prompt(&self) -> String {
        join_prompt(&self.prompt_sections())
    }

    /// `promptSections`.
    pub fn prompt_sections(&self) -> Vec<PromptSection> {
        let mut sections = self.config.system_prompt.clone();
        let extra = self.extra_system_prompt.borrow();
        if !extra.is_empty() {
            sections.push(PromptSection::new(
                "hook:sessionStart",
                "Session start hook",
                "hook",
                crate::hooks::fence_output(HookName::SessionStart, &extra),
            ));
        }
        for feature in &self.features {
            if let Some(block) = self.feature_prompts.borrow().get(feature.name()) {
                sections.extend(block.iter().cloned());
            }
        }
        if let Some(index) = ptc::capability_index_prompt(self) {
            sections.push(PromptSection::new(
                "capabilities",
                "Capabilities",
                "built-in",
                index,
            ));
        }
        sections.push(PromptSection::new(
            "cwd",
            "Working directory",
            "built-in",
            format!("Current working directory: {}", self.config.workspace),
        ));
        sections
    }

    fn save_context(&self, snapshot: Value) {
        if context::write_context(&self.store.borrow().dir, &snapshot).is_err() {
            self.ui.notify(
                "Unable to persist the context snapshot; the live inspector is still available.",
                NotifyLevel::Warning,
            );
        }
        *self.last_context.borrow_mut() = Some(snapshot);
        self.panel_changed("context");
    }

    /// The latest context snapshot (`lastContext`).
    pub fn last_context(&self) -> Option<Value> {
        self.last_context.borrow().clone()
    }

    pub(crate) fn tool_specs(&self) -> Vec<ToolSpec> {
        self.model_tool_list()
            .iter()
            .map(|tool| ToolSpec {
                name: tool.name().to_owned(),
                description: tool.description().to_owned(),
                parameters: tool.parameters().clone(),
            })
            .collect()
    }

    pub fn prompt_invalidated(&self, name: &str) -> bool {
        self.dirty_prompts.borrow().contains(name)
    }
    pub fn invalidate_prompt(&self, name: &str) {
        self.feature_prompts.borrow_mut().shift_remove(name);
        if self.features.iter().any(|f| f.name() == name) {
            self.dirty_prompts.borrow_mut().insert(name.into());
        }
    }
    async fn refresh_dirty(self: &Rc<Self>, signal: &AbortSignal) -> Result<(), String> {
        while !signal.aborted() && !self.dirty_prompts.borrow().is_empty() {
            for f in self.features.clone() {
                if !self.dirty_prompts.borrow_mut().remove(f.name()) {
                    continue;
                }
                let block = f.before_turn(self, signal).await?;
                if !signal.aborted()
                    && !self.dirty_prompts.borrow().contains(f.name())
                    && let Some(block) = block
                {
                    self.feature_prompts
                        .borrow_mut()
                        .insert(f.name().into(), block);
                }
            }
        }
        Ok(())
    }
    fn main_identity(&self) -> String {
        let resolved = self.resolve_model(None).ok();
        serde_json::json!([
            resolved.as_ref().map(|r| compaction::request_identity(
                r,
                &compaction::main_budget(self, r, &self.compaction_settings())
            )),
            self.system_prompt(),
            self.tool_specs(),
            self.branch().last().map(|e| &e.id),
            self.config.features.get("compaction"),
            self.config.features.get("observationalMemory")
        ])
        .to_string()
    }
    async fn prepare_main(
        self: &Rc<Self>,
        signal: &AbortSignal,
        prepared: Option<&str>,
    ) -> Result<String, String> {
        loop {
            self.refresh_route().await?;
            self.refresh_dirty(signal).await?;
            if signal.aborted() {
                return Err("Aborted".into());
            }
            let identity = self.main_identity();
            if prepared == Some(&identity) {
                return Ok(identity);
            }
            self.maybe_compact(signal).await?;
            if self.dirty_prompts.borrow().is_empty() && self.main_identity() == identity {
                return Ok(identity);
            }
        }
    }

    /// `compactionSettings`.
    pub fn compaction_settings(&self) -> CompactionSettings {
        let mut settings = CompactionSettings::from_features(&self.config.features);
        if self
            .config
            .features
            .get("compaction")
            .and_then(|v| v.get("reserveTokens"))
            .is_none()
            && let Ok(r) = self.resolve_model(None)
        {
            settings.reserve_tokens = settings
                .reserve_tokens
                .min(r.model.context_window / 4)
                .max(r.model.max_tokens);
        }
        settings
    }

    /// Manual compaction (`compact`), only while idle.
    pub async fn compact(self: &Rc<Self>, instructions: Option<String>) -> Result<Value, String> {
        if self.running.get() {
            return Err("Cannot compact while the agent is running".to_owned());
        }
        if self.compacting.borrow().is_some() {
            return Err("Compaction already in progress".to_owned());
        }
        let controller = AbortController::new();
        let _compacting = self.compacting_guard(controller.clone());
        let result = compaction::run_compaction(
            self,
            CompactionReason::Manual,
            &controller.signal(),
            instructions,
            &self.compaction_settings(),
        )
        .await?;
        if !result.ok {
            return Err(result
                .error
                .unwrap_or_else(|| "Compaction failed".to_owned()));
        }
        Ok(result.to_json())
    }

    /// Compact before a turn when the context is near the window.
    async fn maybe_compact(self: &Rc<Self>, signal: &AbortSignal) -> Result<(), String> {
        let settings = self.compaction_settings();
        if !settings.enabled {
            return Ok(());
        }
        let Ok(resolved) = self.resolve_model(None) else {
            return Ok(());
        };
        let budget = compaction::main_budget(self, &resolved, &settings);
        let basis = compaction::request_identity(&resolved, &budget);
        let used = compaction::input_tokens(self);
        let memory = crate::features::memory::memory_config(self);
        let explicit = self
            .config
            .features
            .get("observationalMemory")
            .and_then(Value::as_object)
            .is_some_and(|m| {
                [
                    "compactAfterTokens",
                    "compactAfterTokensMode",
                    "compactAfterTokensRatio",
                ]
                .iter()
                .any(|k| m.contains_key(*k))
            });
        let threshold = if explicit
            && memory.enabled
            && !memory.passive
            && self
                .config
                .features
                .get("compaction")
                .and_then(|v| v.get("reserveTokens"))
                .is_none()
        {
            budget.input.min(crate::features::memory::compact_threshold(
                &memory,
                Some(budget.window),
            ))
        } else {
            budget.input
        };
        if used <= threshold {
            return Ok(());
        }
        let result = self
            .with_compacting(signal, |inner| async move {
                compaction::run_compaction(
                    self,
                    CompactionReason::Threshold,
                    &inner,
                    None,
                    &settings,
                )
                .await
            })
            .await?;
        if !result.ok {
            let error = result.error.unwrap_or_default();
            if error == "handoff_model_changed" {
                if !self.dirty_prompts.borrow().is_empty() {
                    return Ok(());
                }
                if let Ok(current) = self.resolve_model(None) {
                    if compaction::request_identity(
                        &current,
                        &compaction::main_budget(self, &current, &self.compaction_settings()),
                    ) != basis
                    {
                        return Ok(());
                    }
                } else {
                    return Ok(());
                }
            }
            if error == "Nothing to compact" && used <= budget.input {
                return Ok(());
            }
            return Err(format!("Automatic compaction stopped: {error}"));
        }
        Ok(())
    }

    async fn with_compacting<'a, T, F>(
        &'a self,
        signal: &AbortSignal,
        work: impl FnOnce(AbortSignal) -> F,
    ) -> T
    where
        F: std::future::Future<Output = T> + 'a,
    {
        let controller = AbortController::child_of(signal);
        let _compacting = self.compacting_guard(controller.clone());
        work(controller.signal()).await
    }

    /// `compacting` while the guard lives (`finally` in the TS agent).
    fn compacting_guard(&self, controller: AbortController) -> CompactingGuard<'_> {
        *self.compacting.borrow_mut() = Some(controller);
        CompactingGuard(&self.compacting)
    }

    /// `refreshModels`: the node's current public catalog.
    pub async fn refresh_models(&self) {
        let _ = self.refresh_route().await;
    }
    pub async fn refresh_route(&self) -> Result<(), String> {
        let Some(inference) = self.config.models.inference.clone() else {
            return Ok(());
        };
        let latest = crate::remote::fetch_remote_models(&inference)
            .await
            .map_err(|_| "Model route unavailable")?;
        {
            let mut models = self.models.borrow_mut();
            models.providers = latest.providers.clone();
            models.default_model = latest.default_model.clone();
        }
        if self.model_ref.borrow().is_none() {
            let fallback: Option<ModelRef> = self
                .config
                .default_model
                .clone()
                .or(latest.default_model.clone());
            let first = latest.providers.iter().next().and_then(|(name, provider)| {
                provider
                    .models
                    .first()
                    .map(|m| (name.clone(), m.id.clone()))
            });
            *self.model_ref.borrow_mut() = fallback.map(|f| (f.provider, f.id)).or(first);
        }
        Ok(())
    }

    /// `streamFunction`: the gateway's inference (tests may override it).
    pub fn stream_function(&self) -> Rc<dyn StreamFn> {
        if let Some(stream) = &self.stream_override {
            return stream.clone();
        }
        match &self.config.models.inference {
            Some(inference) => Rc::new(crate::remote::RemoteStream {
                config: inference.clone(),
            }),
            None => Rc::new(NoInference),
        }
    }

    fn context_for(&self, up_to: Option<&str>) -> Vec<Message> {
        let entries = self.store.borrow().context_entries();
        let end = match up_to {
            None | Some("end") => entries.len(),
            Some(id) => entries
                .iter()
                .position(|(entry_id, _)| entry_id == id)
                .unwrap_or(entries.len()),
        };
        entries
            .into_iter()
            .take(end)
            .map(|(_, message)| message)
            .collect()
    }

    /// The memory a folded compaction (observational memory) shows, when
    /// its summary is among the request's `messages`.
    fn memory_tokens(&self, messages: &[Message]) -> u64 {
        let branch = self.store.borrow().branch();
        let Some(compaction) = branch
            .iter()
            .rev()
            .find(|entry| matches!(entry.data, EntryData::Compaction { .. }))
        else {
            return 0;
        };
        let EntryData::Compaction {
            summary, details, ..
        } = &compaction.data
        else {
            return 0;
        };
        let shown = messages.iter().any(|message| {
            matches!(message, Message::CompactionSummary { summary: shown, timestamp, .. }
                if shown == summary && *timestamp == compaction.timestamp)
        });
        if !shown || !crate::features::memory::ledger::is_folded_details(details.as_ref()) {
            return 0;
        }
        crate::features::memory::panel::visible_memory_tokens(&branch) as u64
    }

    /// `stream`: one model call with retries and role fallbacks; emits
    /// the streaming events.
    pub async fn stream(
        &self,
        system_prompt: &str,
        signal: &AbortSignal,
        mut options: StreamOptions,
    ) -> Result<AssistantMessage, String> {
        let mut request_prompt = system_prompt.to_owned();
        let mut prepared: Option<String> = None;
        let mut resolved = match self.resolve_model(None) {
            Ok(resolved) => resolved,
            Err(error) => {
                if options.no_retries || !self.fall_back(&error)? {
                    return Err(error);
                }
                self.resolve_model(None)?
            }
        };
        let mut stream_fn = self.stream_function();
        let emit = !options.quiet;
        let mut attempt: usize = 0;
        loop {
            if options.refresh_prompt {
                let agent = self.weak.upgrade().ok_or("Agent stopped")?;
                match agent.prepare_main(signal, prepared.as_deref()).await {
                    Ok(value) => prepared = Some(value),
                    Err(_) if signal.aborted() => {
                        let mut message = agent.empty_assistant();
                        message.stop_reason = StopReason::Aborted;
                        return Ok(message);
                    }
                    Err(error) => return Err(error),
                }
                resolved = self.resolve_model(None)?;
                stream_fn = self.stream_function();
                request_prompt = self.system_prompt();
            }
            let timestamp = now_ms();
            if emit {
                self.emit(
                    json!({ "type": "message_start", "message": { "role": "assistant",
                    "content": [], "timestamp": timestamp, "provider": resolved.provider_name,
                    "model": resolved.model.id } }),
                );
            }
            if options.progress {
                let api = resolved.model.api.unwrap_or(resolved.provider.api);
                let skeleton = AssistantMessage {
                    api: serde_json::to_value(api)
                        .ok()
                        .and_then(|api| api.as_str().map(str::to_owned))
                        .unwrap_or_default(),
                    provider: resolved.provider_name.clone(),
                    model: resolved.model.id.clone(),
                    timestamp,
                    ..self.empty_assistant()
                };
                self.with_run_loop(|run_loop| run_loop.attempt(skeleton));
            }
            let mut messages = sanitize_history(&self.context_for(options.up_to.as_deref()));
            messages.extend(options.extra_messages.iter().cloned());
            let tools = self.tool_specs();
            let sections = self.prompt_sections();
            let shown = if join_prompt(&sections) == request_prompt {
                sections
            } else {
                vec![PromptSection::new(
                    "request",
                    "Request system prompt",
                    "built-in",
                    &request_prompt,
                )]
            };
            let memory_tokens = self.memory_tokens(&messages);
            let snapshot = context::capture_context(ContextInput {
                sections: &shown,
                tools: &tools,
                messages: &messages,
                provider: &resolved.provider_name,
                model_id: &resolved.model.id,
                context_window: Some(resolved.model.context_window).filter(|window| *window > 0),
                memory_tokens,
                capabilities: Some(self.registry.summaries(&self.available_tools())),
            });
            let snapshot_id = snapshot.get("id").cloned();
            self.save_context(snapshot.clone());
            // Panel changes so far reach the client before the stream.
            self.flush_panel();
            let thinking = if resolved.model.reasoning {
                options.thinking.unwrap_or(self.thinking.get())
            } else {
                ThinkingLevel::Off
            };
            let request = StreamRequest {
                purpose: pirc_protocol::RequestPurpose::Turn,
                provider_name: resolved.provider_name.clone(),
                provider: resolved.provider.clone(),
                model: resolved.model.clone(),
                system_prompt: request_prompt.clone(),
                messages,
                tools,
                thinking,
                session_id: self.store.borrow().session_id(),
                signal: signal.clone(),
                max_tokens: options.max_tokens.filter(|n| *n > 0),
                tool_choice: options.tool_choice,
            };
            let progress = options.progress;
            let mut on_delta = |delta: &pirc_protocol::AssistantDelta| {
                if emit {
                    self.emit(json!({ "type": "message_update",
                        "assistantMessageEvent": delta }));
                }
                if progress {
                    self.with_run_loop(|run_loop| run_loop.delta(delta));
                }
            };
            let estimate = compaction::request_input(self, &request.messages);
            if options.refresh_prompt
                && estimate.max(compaction::input_tokens(self))
                    > compaction::main_budget(self, &resolved, &self.compaction_settings()).input
            {
                return Err("Main request exceeds the effective context budget".into());
            }
            let mut message = stream_fn.stream(request, &mut on_delta).await;
            if self
                .last_context
                .borrow()
                .as_ref()
                .and_then(|s| s.get("id").cloned())
                == snapshot_id
            {
                self.save_context(context::with_reported_usage(&snapshot, &message.usage));
            }
            message.timestamp = timestamp;
            message.completed_at = Some(now_ms());
            let retryable = message.stop_reason == StopReason::Error
                && !options.no_retries
                && !signal.aborted()
                && message
                    .error_message
                    .as_deref()
                    .is_some_and(pirc_agent_loop::is_retryable)
                && !message.content.iter().any(
                    |part| matches!(part, AssistantContent::Text { text, .. } if !text.is_empty()),
                );
            if retryable && self.fall_back(message.error_message.as_deref().unwrap_or("error"))? {
                if emit {
                    self.emit_end(&message);
                }
                resolved = self.resolve_model(None)?;
                stream_fn = self.stream_function();
                attempt = 0;
                continue;
            }
            let retry = retryable && attempt < RETRY_DELAYS.len();
            if !retry {
                if options.refresh_prompt
                    && message.stop_reason != StopReason::Error
                    && message.usage.total_tokens > 0
                {
                    *self.usage_context.borrow_mut() = Some(compaction::UsageContext {
                        message: message.clone(),
                        prefix: serde_json::json!([request_prompt, self.tool_specs()]).to_string(),
                        identity: compaction::route_identity(&resolved),
                        estimated_input: estimate,
                    });
                }
                if let Some(before_end) = options.before_end.as_mut()
                    && let Err(error) = before_end(&message)
                {
                    self.flush_panel();
                    return Err(error);
                }
                if emit {
                    self.emit_end(&message);
                }
                self.flush_panel();
                return Ok(message);
            }
            if emit {
                self.emit_end(&message);
            }
            let delay = RETRY_DELAYS[attempt];
            self.emit(json!({ "type": "auto_retry_start", "attempt": attempt + 1,
                "maxAttempts": RETRY_DELAYS.len(), "delayMs": delay,
                "errorMessage": message.error_message }));
            self.flush_panel();
            sleep_or_abort(delay, signal).await;
            self.emit(
                json!({ "type": "auto_retry_end", "success": !signal.aborted(),
                "attempt": attempt + 1 }),
            );
            if signal.aborted() {
                message.stop_reason = StopReason::Aborted;
                return Ok(message);
            }
            attempt += 1;
        }
    }

    fn emit_end(&self, message: &AssistantMessage) {
        let mut value = serde_json::to_value(message).unwrap_or_default();
        if let Some(object) = value.as_object_mut() {
            let mut with_role = Map::new();
            with_role.insert("role".to_owned(), json!("assistant"));
            with_role.extend(std::mem::take(object));
            *object = with_role;
        }
        self.emit(json!({ "type": "message_end", "message": value }));
    }

    /// The run after its start (`run`): `start` says what of the start is
    /// still to do.
    async fn run(
        self: &Rc<Self>,
        signal: AbortSignal,
        start: Start,
        receipt: Option<AdmissionReceipt>,
    ) -> Result<(), String> {
        let initial = match start {
            Start::Failed(error) => Err(error),
            Start::Admit(None) => Ok(()),
            Start::Admit(Some(items)) => tokio::select! {
                biased;
                _ = signal.cancelled() => Err("Run interrupted before admission".to_owned()),
                result = self.admit(items) => result,
            }
            .inspect_err(|e| self.start_failed(e)),
            Start::Starting(started) => tokio::select! {
                biased;
                _ = signal.cancelled() => Err("Run interrupted before admission".to_owned()),
                (result, _) = started => result,
            }
            .inspect_err(|e| self.start_failed(e)),
        };
        if let Some(receipt) = receipt {
            let _ = receipt.send(initial.clone());
        }
        // Any failed initial admission stops this run. Some refusals (such as a
        // stale writer) occur before SessionStore marks a write as uncertain.
        // Those must not run the model on the previous conversation either.
        if initial.is_err() || self.store.borrow().write_failed() {
            *self.turn.borrow_mut() = None;
            self.interrupt_pending.set(false);
            self.emit(json!({ "type": "agent_end", "willRetry": false }));
            return Ok(());
        }
        let max_turns = self.config.limits.max_turns;
        let mut turns: u64 = 0;
        let mut overflow_retried = false;
        let mut completion_timed_out = false;
        let mut produced: Vec<Message> = Vec::new();
        *self.run_loop.borrow_mut() = Some(RunLoop::new());
        let _run_loop = RunLoopGuard(&self.run_loop);
        while !signal.aborted() {
            turns += 1;
            if turns > max_turns {
                self.ui.notify(
                    &format!("Stopped after {max_turns} turns"),
                    NotifyLevel::Warning,
                );
                break;
            }
            // Team reports are safe at tool boundaries. Admit them before the
            // next model call so a final synthesis cannot overlook
            // already-queued results.
            let team_batch = self.team_batch_size();
            if team_batch > 0 {
                let items: Vec<QueueItem> =
                    self.follow_ups.borrow_mut().drain(..team_batch).collect();
                self.admit(items).await?;
            }
            *self.turn.borrow_mut() = None;
            if signal.aborted() {
                break;
            }
            if self.interrupt_pending.replace(false) {
                let items = std::mem::take(&mut *self.steering.borrow_mut());
                self.emit_queue();
                self.admit(items).await?;
            }
            let turn = AbortController::child_of(&signal);
            *self.turn.borrow_mut() = Some(turn.clone());
            let turn_signal = turn.signal();
            let interrupted = || turn_signal.aborted() && !signal.aborted();
            self.emit(json!({ "type": "turn_start" }));
            let settings = self.compaction_settings();
            let compacts_instead = |reply: &AssistantMessage, retried: bool| {
                is_context_overflow(reply) && !retried && settings.enabled
            };
            let persisted = Rc::new(Cell::new(false));
            let marker = persisted.clone();
            let agent = self.clone();
            let retried = overflow_retried;
            let settings_enabled = settings.enabled;
            let before_end: BeforeEnd = Box::new(move |reply| {
                if is_context_overflow(reply) && !retried && settings_enabled {
                    return Ok(());
                }
                agent.append(EntryData::Message(Message::Assistant(reply.clone())))?;
                marker.set(true);
                Ok(())
            });
            let prompt = self.system_prompt();
            let ticket = self.progression(RunLoop::request)?;
            let message = self
                .stream(
                    &prompt,
                    &turn_signal,
                    StreamOptions {
                        before_end: Some(before_end),
                        refresh_prompt: true,
                        progress: true,
                        ..StreamOptions::default()
                    },
                )
                .await?;
            let reply =
                self.progression(|run_loop| run_loop.reply(ticket, &message, interrupted()))?;
            if !persisted.get() && compacts_instead(&message, overflow_retried) {
                overflow_retried = true;
                self.emit(json!({ "type": "turn_end" }));
                let result = self
                    .with_compacting(&signal, |inner| async move {
                        compaction::run_compaction(
                            self,
                            CompactionReason::Overflow,
                            &inner,
                            None,
                            &settings,
                        )
                        .await
                    })
                    .await?;
                if result.ok {
                    self.progression(RunLoop::compacted)?;
                    continue;
                }
            }
            if !persisted.get() {
                self.append(EntryData::Message(Message::Assistant(message.clone())))?;
            }
            produced.push(Message::Assistant(message.clone()));
            // Only a tool-use reply has calls; they run one at a time.
            match reply {
                Reply::Tools(calls) => {
                    for call in &calls {
                        let (result, end) = self
                            .run_call(
                                &call.id,
                                &call.name,
                                call.arguments.clone(),
                                Some(call),
                                &turn_signal,
                                &signal,
                            )
                            .await?;
                        self.progression(|run_loop| run_loop.tool_result(call, &result, end))?;
                    }
                }
                Reply::Unchecked(calls) => {
                    for (id, name, arguments) in calls {
                        let (result, _) = self
                            .run_call(&id, &name, arguments, None, &turn_signal, &signal)
                            .await?;
                        self.with_run_loop(|run_loop| run_loop.unchecked_result(result));
                    }
                }
                Reply::Nothing => {}
            }
            self.emit(json!({ "type": "turn_end" }));
            for feature in self.features.clone() {
                feature.turn_end(self, &message).await?;
            }
            if message.stop_reason == StopReason::Error {
                break;
            }
            if message.stop_reason == StopReason::Aborted && !interrupted() {
                break;
            }
            if !self.steering.borrow().is_empty() {
                let mut items = std::mem::take(&mut *self.steering.borrow_mut());
                self.interrupt_pending.set(false);
                self.emit_queue();
                if message.stop_reason == StopReason::Aborted {
                    items.insert(0, interrupted_note(&message));
                }
                self.admit(items).await?;
                continue;
            }
            if message.stop_reason == StopReason::ToolUse {
                continue;
            }
            if turns >= max_turns {
                self.ui.notify(
                    &format!("Stopped after {max_turns} turns; team work may still be pending."),
                    NotifyLevel::Warning,
                );
                break;
            }
            // Set only by a wait in this iteration.
            self.completion_waited.set(false);
            if self.pending_count() == 0 && !completion_timed_out {
                completion_timed_out = self.wait_for_completion(&signal).await;
            }
            if signal.aborted() {
                break;
            }
            if self.follow_ups.borrow().is_empty() {
                for feature in self.features.clone() {
                    feature.agent_end(self, &produced).await?;
                }
            }
            if self.pending_count() > 0 {
                let count = self.team_batch_size().max(1);
                let mut items = std::mem::take(&mut *self.steering.borrow_mut());
                let take = count.min(self.follow_ups.borrow().len());
                items.extend(self.follow_ups.borrow_mut().drain(..take));
                self.emit_queue();
                self.admit(items).await?;
                if self.completion_waited.replace(false) {
                    // What the woken features spawned meanwhile runs first.
                    crate::yield_once().await;
                }
                continue;
            }
            break;
        }
        self.progression(|run_loop| run_loop.close(signal.aborted(), now_ms()))?;
        *self.turn.borrow_mut() = None;
        self.interrupt_pending.set(false);
        self.emit(json!({ "type": "agent_end", "willRetry": false }));
        Ok(())
    }

    /// One call of a reply: run, or recorded as not run once its turn was
    /// aborted (`signal` is the run's). `checked`: the agent loop's call,
    /// whose waits it is told.
    async fn run_call(
        &self,
        id: &str,
        name: &str,
        arguments: Map<String, Value>,
        checked: Option<&ToolCall>,
        turn_signal: &AbortSignal,
        signal: &AbortSignal,
    ) -> Result<(Message, CallEnd), String> {
        if turn_signal.aborted() {
            let reason = if signal.aborted() {
                NotRun::Aborted
            } else {
                NotRun::Interrupted
            };
            let result = ToolOutcome::not_run(reason, now_ms()).message(id, name);
            self.append_message(result.clone())?;
            self.admitted(&result);
            return Ok((result, CallEnd::Skipped));
        }
        let execute = self.execute_tool(id, name, arguments, turn_signal);
        let result = match checked {
            Some(call) => {
                self.with_run_loop(|run_loop| run_loop.start_call(call));
                LOOP_CALL.scope(call.key, execute).await?
            }
            None => execute.await?,
        };
        let end = if turn_signal.aborted() {
            CallEnd::RanAborted
        } else {
            CallEnd::Ran
        };
        Ok((result, end))
    }

    fn record_result(&self, id: &str, name: &str, result: ToolResult) -> Result<Message, String> {
        let content = if result.content.is_empty() {
            vec![text_block("(no output)")]
        } else {
            result.content
        };
        let message = Message::ToolResult {
            tool_call_id: id.to_owned(),
            tool_name: name.to_owned(),
            content,
            details: result.details,
            is_error: result.is_error,
            timestamp: now_ms(),
        };
        self.append_message(message.clone())?;
        self.admitted(&message);
        Ok(message)
    }

    /// `acquireWrite`: the write lease for the allowed root containing
    /// `file` (none for shared roots).
    pub async fn acquire_write(&self, file: &str, signal: &AbortSignal) -> Result<(), String> {
        let Some(root) = self.guard.lease_root(file) else {
            return Ok(());
        };
        let Some(lease) = self.write_lease.clone() else {
            return Ok(());
        };
        if signal.aborted() {
            return Err("The operation was aborted.".to_owned());
        }
        let _wait = self.loop_wait(
            WaitReason::Resource(format!("write lease: {root}")),
            self.current_operation().as_deref(),
        );
        tokio::select! {
            result = lease(root) => result,
            () = signal.cancelled() => Err("Aborted".to_owned()),
        }
    }

    fn tool_context(
        &self,
        tool_call_id: &str,
        signal: &AbortSignal,
        on_update: Rc<dyn Fn(ToolResult)>,
    ) -> ToolContext {
        let agent = self.weak.clone();
        let lease_signal = signal.clone();
        ToolContext {
            cwd: self.config.workspace.clone(),
            config: self.config.clone(),
            guard: self.guard.clone(),
            signal: signal.clone(),
            tool_call_id: tool_call_id.to_owned(),
            ui: self.ui.clone(),
            has_ui: self.has_ui,
            env: self.config.env.clone(),
            acquire_write: Rc::new(move |file: String| {
                let agent = agent.clone();
                let signal = lease_signal.clone();
                Box::pin(async move {
                    match agent.upgrade() {
                        Some(agent) => agent.acquire_write(&file, &signal).await,
                        None => Err("Aborted".to_owned()),
                    }
                })
            }),
            update: on_update,
            human_wait: {
                let agent = self.weak.clone();
                Rc::new(move || match agent.upgrade() {
                    Some(agent) => agent.human_wait(),
                    None => HumanWait::none(),
                })
            },
        }
    }

    /// `invokeOperation`: availability, then the policy chain (argument
    /// validation, hooks, validation of hook-rewritten arguments, auto mode
    /// and the write lease), then the tool. `stage` tells how far it got.
    pub async fn invoke_operation(
        &self,
        name: &str,
        raw_args: Map<String, Value>,
        signal: &AbortSignal,
        tool_call_id: &str,
        on_update: Rc<dyn Fn(ToolResult)>,
        options: OperationOptions,
    ) -> OperationOutcome {
        let unavailable = |text: String| OperationOutcome {
            stage: OperationStage::Unavailable,
            result: ToolResult::error(text),
            hook_output: None,
        };
        let tool = self.get_tool(name);
        if tool.is_none()
            && let Some(capability) = capability_for_tool(name)
            && self.tools.borrow().contains_key(name)
        {
            return unavailable(format!(
                "The {capability} capability is disabled for this project; {name} is unavailable. Ask the user to enable it in the project settings if needed."
            ));
        }
        let Some(tool) = tool else {
            return unavailable(format!("Unknown tool: {name}"));
        };
        self.run_tool(&tool, raw_args, signal, tool_call_id, on_update, options)
            .await
    }

    /// `runOperation`: one `ptc` operation, observable like a direct call
    /// (docs/architecture/ptc.md): `tool_execution_*` events under
    /// the capability's name, linked to the `ptc` call by
    /// `parentToolCallId`, and a `ptc.operation` session entry with the
    /// result as the tool returned it (never a `message`: the model sees
    /// only what the script returns). Dialogs it opens carry its id.
    pub async fn run_operation(
        &self,
        parent_tool_call_id: &str,
        name: &str,
        args: Map<String, Value>,
        signal: &AbortSignal,
        operation_id: &str,
        options: OperationOptions,
    ) -> OperationOutcome {
        // What observers and the session see of the arguments: bounded, since
        // a script can pass large arguments without the model writing them
        // out (the operation gets them in full).
        let shown = recorded_args(&args);
        self.emit(
            json!({ "type": "tool_execution_start", "toolCallId": operation_id,
            "toolName": name, "args": shown, "parentToolCallId": parent_tool_call_id }),
        );
        let last_update = Rc::new(Cell::new(0u64));
        let weak = self.weak.clone();
        let (call_id, tool_name, update_args, parent) = (
            operation_id.to_owned(),
            name.to_owned(),
            shown.clone(),
            parent_tool_call_id.to_owned(),
        );
        let on_update: Rc<dyn Fn(ToolResult)> = Rc::new(move |partial: ToolResult| {
            let now = now_ms();
            if now.saturating_sub(last_update.get()) < 100 {
                return;
            }
            last_update.set(now);
            if let Some(agent) = weak.upgrade() {
                agent.emit(
                    json!({ "type": "tool_execution_update", "toolCallId": call_id,
                    "toolName": tool_name, "args": update_args,
                    "partialResult": partial.observed().to_json(), "parentToolCallId": parent }),
                );
            }
        });
        self.active_operations
            .borrow_mut()
            .insert(operation_id.to_owned());
        self.operation_parents
            .borrow_mut()
            .insert(operation_id.to_owned(), parent_tool_call_id.to_owned());
        // Always ended for observers, even if the operation's future is
        // dropped (the TS `finally`).
        let ended = OperationEnd {
            agent: self.weak.clone(),
            parent_tool_call_id: parent_tool_call_id.to_owned(),
            operation_id: operation_id.to_owned(),
            name: name.to_owned(),
            shown,
            signal: signal.clone(),
            result: None,
        };
        let outcome = OPERATION_SCOPE
            .scope(
                operation_id.to_owned(),
                self.invoke_operation(name, args, signal, operation_id, on_update, options),
            )
            .await;
        let mut ended = ended;
        ended.result = Some(outcome.result.clone());
        drop(ended);
        outcome
    }

    /// The end of [`Agent::run_operation`]: the `ptc.operation` entry, the
    /// `tool_execution_end` event and the `operation_recorded` hooks.
    fn end_operation(
        &self,
        parent_tool_call_id: &str,
        operation_id: &str,
        name: &str,
        shown: Value,
        result: ToolResult,
    ) {
        self.active_operations.borrow_mut().remove(operation_id);
        self.operation_parents.borrow_mut().remove(operation_id);
        let mut result = result.observed();
        if crate::handoff::replay_tool(name)
            || self
                .running_script_capabilities()
                .iter()
                .any(|n| crate::handoff::replay_tool(n))
        {
            let mut details = result
                .details
                .and_then(|v| v.as_object().cloned())
                .unwrap_or_default();
            details.insert("memoryReplay".into(), json!(true));
            result.details = Some(Value::Object(details));
        }
        let content = if result.content.is_empty() {
            vec![text_block("(no output)")]
        } else {
            result.content.clone()
        };
        let mut entry = Map::new();
        entry.insert("parentToolCallId".to_owned(), json!(parent_tool_call_id));
        entry.insert("toolCallId".to_owned(), json!(operation_id));
        entry.insert("toolName".to_owned(), json!(name));
        entry.insert("args".to_owned(), shown);
        entry.insert(
            "content".to_owned(),
            serde_json::to_value(&content).unwrap_or_default(),
        );
        if let Some(details) = &result.details {
            entry.insert("details".to_owned(), details.clone());
        }
        entry.insert("isError".to_owned(), json!(result.is_error));
        entry.insert("timestamp".to_owned(), json!(now_ms()));
        let entry = Value::Object(entry);
        // Written before it is announced, like messages: a snapshot is never
        // behind the events.
        if let Err(error) = self.append(EntryData::Custom {
            custom_type: OPERATION_ENTRY.to_owned(),
            data: entry.clone(),
        }) {
            eprintln!("could not record operation {operation_id}: {error}");
        }
        self.emit(
            json!({ "type": "tool_execution_end", "toolCallId": operation_id,
            "toolName": name, "result": result.to_json(), "isError": result.is_error,
            "parentToolCallId": parent_tool_call_id }),
        );
        if let Some(agent) = self.weak.upgrade() {
            for feature in self.features.clone() {
                feature.operation_recorded(&agent, &entry);
            }
        }
    }

    /// `runTool`: validation, `beforeTool` hooks, validation of rewritten
    /// arguments, the caller's hold (`withheld`), auto mode and the write
    /// lease, `beforeExecute`, the tool, `afterTool`.
    async fn run_tool(
        &self,
        tool: &Rc<dyn Tool>,
        raw_args: Map<String, Value>,
        signal: &AbortSignal,
        tool_call_id: &str,
        on_update: Rc<dyn Fn(ToolResult)>,
        options: OperationOptions,
    ) -> OperationOutcome {
        let name = tool.name().to_owned();
        let fail = |stage, text: String| OperationOutcome {
            stage,
            result: ToolResult::error(text),
            hook_output: None,
        };
        let cancelled = || {
            fail(
                OperationStage::Cancelled,
                "Cancelled before it started".to_owned(),
            )
        };
        if let Some(raw) = raw_args.get("__invalid_json") {
            let shown = match raw {
                Value::String(text) => text.clone(),
                other => other.to_string(),
            };
            let (shown, _) = slice16(&shown, 500);
            return fail(
                OperationStage::Invalid,
                format!("Invalid JSON arguments for {name}: {shown}"),
            );
        }
        let invalid = |args: &Map<String, Value>, what: &str| {
            let errors = ptc::validate_schema(&Value::Object(args.clone()), tool.parameters());
            (!errors.is_empty())
                .then(|| format!("Invalid {what} for {name}: {}", errors.join("; ")))
        };
        if let Some(problem) = invalid(&raw_args, "arguments") {
            return fail(OperationStage::Invalid, problem);
        }
        if signal.aborted() {
            return cancelled();
        }
        let gate = self.hooks.before_tool(&name, raw_args.clone()).await;
        if signal.aborted() {
            return cancelled();
        }
        let args = match gate {
            Ok(args) => args,
            Err(reason) => {
                return fail(OperationStage::Denied, format!("Blocked by hook: {reason}"));
            }
        };
        if args != raw_args
            && let Some(problem) = invalid(&args, "hook-rewritten arguments")
        {
            return fail(OperationStage::Invalid, problem);
        }
        let held = || {
            options
                .withheld
                .as_ref()
                .and_then(|withheld| withheld(&name, &args))
        };
        if let Some(reason) = held() {
            return fail(OperationStage::Withheld, reason);
        }
        // Auto mode judges the final (hook-rewritten) arguments and takes the
        // write lease.
        let refusal = match APPROVAL_GATE
            .scope((), self.auto_mode.gate(self, &name, &args, signal))
            .await
        {
            Ok(refusal) => refusal,
            Err(error) => {
                if signal.aborted() {
                    return cancelled();
                }
                return fail(OperationStage::Refused, error);
            }
        };
        // An approval cancelled with the call is not a denial, and never
        // consent.
        if signal.aborted() {
            return cancelled();
        }
        if let Some(refusal) = refusal {
            return fail(
                OperationStage::Denied,
                format!("Blocked by auto mode: {refusal}"),
            );
        }
        if let Some(before) = &options.before_execute
            && before(name.clone(), args.clone()).await.is_err()
        {
            return cancelled();
        }
        // Nothing runs once the call was cancelled, wherever it was waiting.
        if signal.aborted() {
            return cancelled();
        }
        if let Some(reason) = held() {
            return fail(OperationStage::Withheld, reason);
        }
        let ctx = self.tool_context(tool_call_id, signal, on_update);
        let (stage, mut result) = match tool.execute(args.clone(), ctx).await {
            Ok(result) => (OperationStage::Executed, result),
            Err(error) => {
                let (shown, _) = slice16(&format!("tool {name} threw: {error}\n"), 8192);
                eprint!("{shown}");
                (OperationStage::Threw, ToolResult::error(error))
            }
        };
        let mut hook_output = None;
        if self.hooks.has(HookName::AfterTool) {
            let output: String = result
                .content
                .iter()
                .filter_map(|part| match part {
                    UserBlock::Text { text, .. } => Some(text.as_str()),
                    UserBlock::Image { .. } => None,
                })
                .collect();
            let (output, _) = slice16(&output, 65_536);
            let mut data = Map::new();
            data.insert("tool".to_owned(), json!(name));
            data.insert("args".to_owned(), Value::Object(args));
            data.insert("isError".to_owned(), json!(result.is_error));
            data.insert("output".to_owned(), json!(output));
            let printed: Vec<String> = self
                .hooks
                .run(HookName::AfterTool, data, Some(&name))
                .await
                .into_iter()
                .filter(|item| item.exit_code == Some(0) && !js_trim(&item.stdout).is_empty())
                .map(|item| js_trim(&item.stdout).to_owned())
                .collect();
            if !printed.is_empty() {
                let printed = printed.join("\n");
                result
                    .content
                    .push(text_block(format!("\n[hook]\n{printed}")));
                hook_output = Some(printed);
            }
        }
        OperationOutcome {
            stage,
            result,
            hook_output,
        }
    }

    /// `invokeModelTool`: only the model-facing tools exist at this level.
    async fn invoke_model_tool(
        &self,
        id: &str,
        name: &str,
        arguments: Map<String, Value>,
        signal: &AbortSignal,
        on_update: Rc<dyn Fn(ToolResult)>,
    ) -> ToolResult {
        let wrapper = self.wrappers.borrow().get(name).cloned();
        if let Some(wrapper) = wrapper
            && !self.available_tools().is_empty()
        {
            return self
                .run_tool(
                    &wrapper,
                    arguments,
                    signal,
                    id,
                    on_update,
                    OperationOptions::default(),
                )
                .await
                .result;
        }
        // A direct core capability: the same policy chain as a ptc
        // operation, in an operation scope so the dialogs it opens name its
        // call; typed data stays here. A core capability disabled by policy
        // gets the same explanation as from a script.
        let direct = self.direct_tools().iter().any(|tool| tool.name() == name)
            || (DIRECT_CAPABILITIES.contains(&name)
                && self.tools.borrow().contains_key(name)
                && capability_for_tool(name).is_some());
        if direct {
            let args = lenient_args(self.get_tool(name).as_ref(), &arguments);
            self.active_operations.borrow_mut().insert(id.to_owned());
            let forward = on_update.clone();
            let observed: Rc<dyn Fn(ToolResult)> =
                Rc::new(move |partial: ToolResult| forward(partial.observed()));
            let result = OPERATION_SCOPE
                .scope(
                    id.to_owned(),
                    self.invoke_operation(
                        name,
                        args,
                        signal,
                        id,
                        observed,
                        OperationOptions::default(),
                    ),
                )
                .await
                .result
                .observed();
            self.active_operations.borrow_mut().remove(id);
            return result;
        }
        let text = if self.get_tool(name).is_some() {
            format!(
                "{name} is not a direct tool: call it from a ptc script, e.g. ptc({{ code: \"return await tools.{name}({{ … }})\" }}). ptc_docs({{ names: [\"{name}\"] }}) shows its arguments."
            )
        } else {
            let names: Vec<String> = self
                .model_tool_list()
                .iter()
                .map(|tool| tool.name().to_owned())
                .collect();
            let listed = if names.is_empty() {
                "none".to_owned()
            } else {
                names.join(", ")
            };
            format!("Unknown tool: {name}. The tools are {listed}.")
        };
        ToolResult::error(text)
    }

    async fn execute_tool(
        &self,
        id: &str,
        name: &str,
        arguments: Map<String, Value>,
        signal: &AbortSignal,
    ) -> Result<Message, String> {
        self.emit(
            json!({ "type": "tool_execution_start", "toolCallId": id, "toolName": name,
            "args": arguments }),
        );
        let last_update = Rc::new(Cell::new(0u64));
        let weak = self.weak.clone();
        let (call_id, tool_name, shown_args) = (id.to_owned(), name.to_owned(), arguments.clone());
        let on_update: Rc<dyn Fn(ToolResult)> = Rc::new(move |partial: ToolResult| {
            let now = now_ms();
            if now.saturating_sub(last_update.get()) < 100 {
                return;
            }
            last_update.set(now);
            if let Some(agent) = weak.upgrade() {
                agent.emit(
                    json!({ "type": "tool_execution_update", "toolCallId": call_id,
                    "toolName": tool_name, "args": shown_args,
                    "partialResult": partial.to_json() }),
                );
            }
        });
        let result = self
            .invoke_model_tool(id, name, arguments, signal, on_update)
            .await;
        self.emit(
            json!({ "type": "tool_execution_end", "toolCallId": id, "toolName": name,
            "result": result.to_json(), "isError": result.is_error }),
        );
        self.record_result(id, name, result)
    }

    /// Every message on the branch (`get_messages`).
    pub fn all_messages(&self) -> Vec<Message> {
        self.store.borrow().all_messages()
    }

    /// The session's context entries (compaction).
    pub fn session_id(&self) -> String {
        self.store.borrow().session_id()
    }
    pub(crate) fn reopen_session(&self) -> Result<(), String> {
        let dir = self.session_dir();
        let next = SessionStore::open(dir, &self.config.workspace)?;
        *self.store.borrow_mut() = next;
        Ok(())
    }

    pub fn context_entries(&self) -> Vec<(String, Message)> {
        self.store.borrow().context_entries()
    }

    /// Append a compaction entry; its id.
    pub fn append_compaction(
        &self,
        summary: &str,
        first_kept_entry_id: &str,
        tokens_before: u64,
        details: Option<Value>,
    ) -> Result<String, String> {
        self.append(EntryData::Compaction {
            summary: summary.to_owned(),
            first_kept_entry_id: first_kept_entry_id.to_owned(),
            tokens_before,
            details,
        })
    }

    pub fn ui(&self) -> Rc<dyn Ui> {
        self.ui.clone()
    }

    pub async fn shutdown(self: &Rc<Self>) {
        self.abort();
        self.idle().await;
        for feature in self.features.clone() {
            feature.shutdown(self).await;
        }
        self.closed.set(true);
    }

    /// The role this agent runs in.
    pub fn role(&self) -> Option<AgentRole> {
        self.role.borrow().clone()
    }

    /// A chat project's instructions (the M5 feature reads them).
    pub fn project_instructions(&self) -> Option<&str> {
        self.project_instructions.as_deref()
    }

    /// The current model reference.
    pub fn model_ref(&self) -> Option<(String, String)> {
        self.model_ref.borrow().clone()
    }

    pub fn empty_assistant(&self) -> AssistantMessage {
        AssistantMessage {
            content: Vec::new(),
            api: String::new(),
            provider: String::new(),
            model: String::new(),
            usage: empty_usage(),
            stop_reason: StopReason::Stop,
            error_message: None,
            timestamp: now_ms(),
            completed_at: None,
            canonical_provider: None,
            response_id: None,
            response_model: None,
        }
    }
}

/// No inference configured (a standalone agent; the node always sends one).
struct NoInference;

impl StreamFn for NoInference {
    fn stream<'a>(
        &'a self,
        request: StreamRequest,
        _on_delta: &'a mut dyn FnMut(&pirc_protocol::AssistantDelta),
    ) -> LocalBoxFuture<'a, AssistantMessage> {
        Box::pin(async move {
            AssistantMessage {
                content: Vec::new(),
                api: request
                    .model
                    .api
                    .map_or_else(|| api_name(request.provider.api), api_name)
                    .to_owned(),
                provider: request.provider_name,
                model: request.model.id,
                usage: empty_usage(),
                stop_reason: StopReason::Error,
                error_message: Some("Gateway inference is unavailable".to_owned()),
                timestamp: now_ms(),
                completed_at: None,
                canonical_provider: None,
                response_id: None,
                response_model: None,
            }
        })
    }
}

fn api_name(api: pirc_protocol::ModelApi) -> &'static str {
    use pirc_protocol::ModelApi;
    match api {
        ModelApi::OpenaiChat => "openai-chat",
        ModelApi::AnthropicMessages => "anthropic-messages",
        ModelApi::OpenaiCompletions => "openai-completions",
        ModelApi::OpenaiResponses => "openai-responses",
        ModelApi::OpenaiCodexResponses => "openai-codex-responses",
    }
}

impl AgentHost for Agent {
    fn config(&self) -> Rc<AgentConfig> {
        self.config.clone()
    }
    fn guard(&self) -> Rc<PathGuard> {
        self.guard.clone()
    }
    fn ui(&self) -> Rc<dyn Ui> {
        self.ui.clone()
    }
    fn has_ui(&self) -> bool {
        self.has_ui
    }
    fn session_id(&self) -> String {
        self.store.borrow().session_id()
    }
    fn acquire_write<'a>(
        &'a self,
        file: &'a str,
        signal: &'a AbortSignal,
    ) -> LocalBoxFuture<'a, Result<(), String>> {
        Box::pin(Agent::acquire_write(self, file, signal))
    }
    fn tool_list(&self) -> Vec<Rc<dyn Tool>> {
        self.available_tools()
    }
    fn direct_tool_list(&self) -> Vec<Rc<dyn Tool>> {
        self.direct_tools()
    }
    fn resolve_model(&self, reference: Option<(String, String)>) -> Result<ResolvedModel, String> {
        Agent::resolve_model(self, reference)
    }
    fn stream_function(&self) -> Option<Rc<dyn StreamFn>> {
        Some(Agent::stream_function(self))
    }
    fn context_entries(&self) -> Vec<(String, Message)> {
        Agent::context_entries(self)
    }
    fn branch(&self) -> Vec<SessionEntry> {
        Agent::branch(self)
    }
    fn approval_mode(&self) -> ApprovalMode {
        Agent::approval_mode(self)
    }
    fn run_user_requests(&self) -> Vec<String> {
        self.run_user_requests.borrow().clone()
    }
    fn run_user_quotes(&self) -> Vec<String> {
        self.run_user_quotes.borrow().clone()
    }
}

#[cfg(test)]
mod tests;
