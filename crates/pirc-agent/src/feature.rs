//! Built-in extensions (`agent/feature.ts`): features are compiled into the
//! binary, and this is the small hook surface they need. Every hook has a
//! default that does nothing, so a feature implements only its own.
//!
//! The agent calls the hooks in the order of [`crate::features::
//! builtin_features`], where the TS agent did. A hook that returns `Err`
//! is what threw in TS; the agent handles it as TS handled the throw at
//! that call site (a warning, a failed start, a crashed loop).

use std::borrow::Cow;
use std::rc::Rc;

use pirc_protocol::{AssistantMessage, Message};
use serde_json::{Map, Value};

use crate::LocalBoxFuture;
use crate::agent::Agent;
use crate::auto_mode::ApprovalMode;
use crate::context::PromptSection;
use crate::signal::AbortSignal;
use crate::tools::Tool;

/// `offInChat`, generalised: a feature the session's mode leaves out
/// ([`pirc_protocol::Mode::features_off`]; chats drop coding features
/// whose tools cost context a personal assistant rarely needs).
/// `features.<key>.enabled: true` in the node's config brings one back.
pub fn off_in_mode(agent: &Agent, key: &str) -> bool {
    agent.config().feature_disabled(key)
}

/// What a feature adds to the system prompt before a run.
#[derive(Clone, Debug, PartialEq)]
pub enum PromptAddition {
    /// One section, titled and identified by the feature's name, with the
    /// source `feature:<name>`.
    Text(String),
    /// Sections as they are.
    Sections(Vec<PromptSection>),
}

/// `beforeAgentStart`'s result.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct BeforeStart {
    pub system_prompt: Option<PromptAddition>,
    /// Hidden context (custom messages), admitted after the run's first
    /// item.
    pub messages: Vec<Message>,
}

/// `CompactionPlan`: a feature's own compaction.
#[derive(Clone, Debug, PartialEq)]
pub struct CompactionPlan {
    pub summary: String,
    pub first_kept_entry_id: String,
    pub tokens_before: u64,
    pub details: Option<Value>,
}

/// `beforeCompact`'s result, when the feature takes over.
#[derive(Clone, Debug, PartialEq)]
pub enum CompactDecision {
    Plan(CompactionPlan),
    /// `{ cancel: true }`.
    Cancel,
}

/// What `beforeCompact` is told.
pub struct CompactContext<'a> {
    pub first_kept_entry_id: &'a str,
    pub tokens_before: u64,
    pub signal: &'a AbortSignal,
}

/// A slash command (`/name args`), run at once instead of reaching the
/// model.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FeatureCommand {
    /// May be namespaced (`om:workspace`). Owned when a feature makes its
    /// commands from data (`skill:<name>` for each installed skill).
    pub name: Cow<'static, str>,
    pub description: Cow<'static, str>,
}

impl FeatureCommand {
    pub fn new(
        name: impl Into<Cow<'static, str>>,
        description: impl Into<Cow<'static, str>>,
    ) -> Self {
        Self {
            name: name.into(),
            description: description.into(),
        }
    }
}

/// `Feature`. One instance per agent process; state lives in the feature
/// (`RefCell`s), as it lived in the TS feature's closure.
pub trait Feature {
    fn name(&self) -> &'static str;

    /// Capabilities the feature adds (registered after the built-in tools,
    /// before a tool allowlist applies).
    fn tools(&self, _agent: &Rc<Agent>) -> Vec<Rc<dyn Tool>> {
        Vec::new()
    }

    /// Slash commands, in registration order.
    fn commands(&self) -> Vec<FeatureCommand> {
        Vec::new()
    }

    /// Run one of [`Feature::commands`]; `args` is trimmed. `Err` is shown
    /// as an error notification.
    fn run_command<'a>(
        &'a self,
        _agent: &'a Rc<Agent>,
        _name: &'a str,
        _args: String,
    ) -> LocalBoxFuture<'a, Result<(), String>> {
        Box::pin(async { Ok(()) })
    }

    /// A human (not an extension) submitted input (slash commands
    /// excluded).
    fn user_input(&self, _agent: &Rc<Agent>, _text: &str) {}

    /// Once, after the session is loaded. `Err` ends the agent at startup.
    fn init<'a>(&'a self, _agent: &'a Rc<Agent>) -> LocalBoxFuture<'a, Result<(), String>> {
        Box::pin(async { Ok(()) })
    }

    /// Before each run: extend the system prompt or inject hidden context.
    /// `Err` fails the run's start (`Failed to start run: …`).
    fn before_agent_start<'a>(
        &'a self,
        _agent: &'a Rc<Agent>,
    ) -> LocalBoxFuture<'a, Result<Option<BeforeStart>, String>> {
        Box::pin(async { Ok(None) })
    }

    /// First-turn refresh can observe cancellation without changing older feature hooks.
    fn before_model_start<'a>(
        &'a self,
        agent: &'a Rc<Agent>,
        _signal: &'a AbortSignal,
    ) -> LocalBoxFuture<'a, Result<Option<BeforeStart>, String>> {
        self.before_agent_start(agent)
    }
    /// Replace an invalidated feature's complete owned block. None leaves it absent.
    fn before_turn<'a>(
        &'a self,
        _agent: &'a Rc<Agent>,
        _signal: &'a AbortSignal,
    ) -> LocalBoxFuture<'a, Result<Option<Vec<PromptSection>>, String>> {
        Box::pin(async { Ok(None) })
    }

    /// After each turn's `turn_end`. `Err` crashes the run.
    fn turn_end<'a>(
        &'a self,
        _agent: &'a Rc<Agent>,
        _message: &'a AssistantMessage,
    ) -> LocalBoxFuture<'a, Result<(), String>> {
        Box::pin(async { Ok(()) })
    }

    /// A message actually admitted to model history (not merely queued):
    /// custom messages and tool results.
    fn message_admitted(&self, _agent: &Rc<Agent>, _message: &Message) {}

    /// A `ptc` operation finished and was recorded (`ptc.operation` entry
    /// data; its result reaches the model only through the script).
    fn operation_recorded(&self, _agent: &Rc<Agent>, _entry: &Value) {}

    /// Required background work that prevents a clean end; empty when none.
    fn completion_blockers(&self, _agent: &Rc<Agent>) -> Vec<String> {
        Vec::new()
    }

    /// Queued custom messages removed by `clear_queue`; a feature may keep
    /// them for later.
    fn notifications_cleared(&self, _agent: &Rc<Agent>, _messages: &[Message]) {}

    /// Explicit cancellation; late feature events must not immediately
    /// restart the run.
    fn abort(&self, _agent: &Rc<Agent>) {}

    /// The run loop is about to stop (no follow-up queued); may queue
    /// follow-ups to continue it. `Err` crashes the run.
    fn agent_end<'a>(
        &'a self,
        _agent: &'a Rc<Agent>,
        _produced: &'a [Message],
    ) -> LocalBoxFuture<'a, Result<(), String>> {
        Box::pin(async { Ok(()) })
    }

    /// The feature will start another run once idle (an active goal), so
    /// end-of-run nudges such as the todo reminder can leave it to that run.
    fn will_continue(&self, _agent: &Rc<Agent>) -> bool {
        false
    }

    /// The session's approval mode changed (the user switched it).
    fn approval_mode_changed(&self, _agent: &Rc<Agent>, _mode: ApprovalMode) {}

    /// Fully idle (after `agent_settled`); may queue steer messages to wake
    /// the agent. `Err` becomes a warning `<name>: <error>`.
    fn agent_settled<'a>(
        &'a self,
        _agent: &'a Rc<Agent>,
    ) -> LocalBoxFuture<'a, Result<(), String>> {
        Box::pin(async { Ok(()) })
    }

    /// Settled work remains bound to the run that scheduled it, including an explicit stop.
    fn settled_with_signal<'a>(
        &'a self,
        agent: &'a Rc<Agent>,
        _signal: &'a AbortSignal,
    ) -> LocalBoxFuture<'a, Result<(), String>> {
        self.agent_settled(agent)
    }

    /// A custom compaction, or `None` for the default summarizer. `Err`
    /// fails the compaction with that message.
    fn before_compact<'a>(
        &'a self,
        _agent: &'a Rc<Agent>,
        _context: CompactContext<'a>,
    ) -> LocalBoxFuture<'a, Result<Option<CompactDecision>, String>> {
        Box::pin(async { Ok(None) })
    }

    /// After a compaction was recorded. `Err` becomes a warning.
    fn after_compact<'a>(
        &'a self,
        _agent: &'a Rc<Agent>,
    ) -> LocalBoxFuture<'a, Result<(), String>> {
        Box::pin(async { Ok(()) })
    }

    /// Best effort, when the agent shuts down.
    fn shutdown<'a>(&'a self, _agent: &'a Rc<Agent>) -> LocalBoxFuture<'a, ()> {
        Box::pin(async {})
    }

    /// Structured state for the web side panel (`get_panel_state`), merged
    /// across features. Call [`Agent::panel_changed`] when it changes.
    /// `None` contributes nothing (a broken panel in TS).
    fn panel(&self, _agent: &Rc<Agent>) -> Option<Map<String, Value>> {
        None
    }

    /// Extra JSONL RPC command types this feature answers.
    fn rpc_types(&self) -> &'static [&'static str] {
        &[]
    }

    /// Answer one of [`Feature::rpc_types`]: `Ok(Some(data))` is the
    /// response's `data`, `Err` its `error`.
    fn rpc<'a>(
        &'a self,
        _agent: &'a Rc<Agent>,
        _kind: &'a str,
        _command: &'a Value,
    ) -> LocalBoxFuture<'a, Result<Option<Value>, String>> {
        Box::pin(async { Err("Unsupported command".to_owned()) })
    }
}
