//! One agent process per session (`node/runner.ts`: `PiRunner`,
//! `RunnerManager`, `runOnHost`). Owner: **runner**.
//!
//! The public API below (the manager, [`Runner`], [`CommandPayload`],
//! [`Delivery`]) is what core's routes and the panels call; the layout fixes
//! it, the bodies are the runner worker's. Everything else (process spawn,
//! stdout handling, side channels, run bookkeeping, host exec) is private to
//! this module and may be split into files under `runner/` freely.
//!
//! What to reproduce (see the scout notes and `runner.ts`):
//!
//! - Start (`ensure`): `require_session_available`; reuse a live runner; one
//!   start in flight per session; runner state `starting`;
//!   `node.sandbox.prepare(...)` (503 `runner_unavailable` when the sandbox
//!   is unavailable); spawn `prepared.command()` with the agent flags
//!   (`--mode rpc --session-dir <private path>`, `--continue` with a
//!   `pi_session_id`), `cwd = chat::session_root`, its own process group,
//!   the environment `without_secrets(node.env)` plus the node's variables
//!   (`PI_CODING_AGENT_SESSION_DIR`, `PIRC_WRITE_BROKER=1`, `PIRC_GATEWAY=1`,
//!   `PIRC_MODE`, `PIRC_PROJECT_TRUST` or `PIRC_PROJECT_INSTRUCTIONS`,
//!   `PIRC_WORKSPACE_MEMORY_DIR`, `PIRC_BROWSER=1|0` from
//!   `node.browser.enabled()`, `PIRC_SANDBOX=srt`, `PIRC_SANDBOX_POLICY`)
//!   and `prepared.env`; epoch from `increment_epoch`, older epochs'
//!   interactions stale; the `configure` line first, `runner_ready`, sandbox
//!   warnings as notifications, `set_session_name` for user names,
//!   `get_state` for the agent's session id.
//! - stdout through [`framing::JsonlParser`]; a framing error publishes
//!   `runner_error` and kills the process group; stderr chunks as
//!   `runner_stderr` (first 8192 UTF-16 units).
//! - The agent's lines in `handleValue` order: responses to pending
//!   requests, `extension_ui_request` (interactions; node dialogs never come
//!   from the agent), `write_lease_request` ([`crate::write_broker`]),
//!   `gateway_request` (`recap.collect` locally via [`crate::recap`], else
//!   [`crate::agent_gateway`]; 8 in flight), `browser_request` and
//!   `browser_cancel` ([`crate::browser`]; 4 in flight), `sandbox_request`
//!   (`network` approvals widening `prepared.approve_domains`, `exec` on the
//!   host after the human's yes; 4 in flight) and `sandbox_cancel`,
//!   `session_name_changed`, then everything else through the
//!   [`reducer`], run bookkeeping and a `pi_event`.
//! - Exit: kill the group, fail pending requests, cancel side requests,
//!   `prepared.cleanup()`, dispatched commands `outcome_unknown`, the open
//!   run `interrupted`, runner state `failed`, `runner_exit`; no restart.
//! - Every run or lease change is followed by `node.activity.notify_one()`.
//!
//! Golden cases: `rpc-framing.test.ts` (framing), `events-reducer.test.ts`
//! (reducer), and the runner parts of `app.integration.test.ts`,
//! `gateway-agent.integration.test.ts`, `sandbox.integration.test.ts`
//! (through the conformance scenarios).
//!
//! Where the port differs, on purpose:
//!
//! - Lines go to the agent's stdin through one writer task, in order; a
//!   failed write closes stdin for good (TS's `stdin.writable`).
//!   `answer` publishes `interaction_answered` before the answer's line is
//!   queued (or a node dialog resolved), so the event always precedes
//!   whatever the agent does next.
//! - TS ran on one thread; steps it took at once stay atomic here: an agent
//!   line is reduced and published as one step for snapshots
//!   ([`Runner::state_at`]), a new runner waits for the old one's exit to
//!   finish, and `stop` returns after it.
//! - Shutdown (the node's `closing`) refuses new starts (503
//!   `runner_unavailable`) and waits for the starts in flight before
//!   stopping every runner (TS let a start in flight outlive it).
//! - On exit the group is killed first, then the agent's last stdout lines
//!   are handled (up to a second), then the exit: `runner_exit` always comes
//!   after the agent's last events (TS's `exit` could overtake `data`).
//! - After a fatal framing error the agent's further output is not read (TS
//!   kept parsing until the exit, publishing more errors or events).
//! - A spawn failure fails the start (503 `runner_unavailable`, the sandbox
//!   cleaned up, the runner state `failed`); TS published `runner_ready`
//!   and then `runner_error` from the child's `error` event. Store failures
//!   after the agent runs are logged rather than failing the start.
//! - Starts run in their own task: a start goes on when its asker (a
//!   relayed request) goes away.

mod command_gate;
#[cfg(test)]
mod drain_tests;
pub mod framing;
pub(crate) mod host;
mod process;
pub mod reducer;
mod side;

use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use command_gate::CommandGate;
use serde::Deserialize;
use serde_json::{Map, Value, json};
use tokio::sync::watch;

use crate::error::{ApiError, ApiResult};
use crate::services::{Node, WeakNode};
use crate::store::{CommandStatus, RunStatus, RunnerState, Store, UploadKind};
pub use process::Runner;
pub use reducer::ReducedState;

/// Frozen settings for the single first-message command; callers cannot retarget
/// an existing admission identity by changing its current control lease.
#[derive(Clone, Debug)]
pub(crate) struct InitialSettings {
    pub provider: String,
    pub model_id: String,
    pub thinking: pirc_protocol::ThinkingLevel,
}

/// What a client asks a session's agent to do (`CommandPayload` in
/// `types.ts`, `commandPayload` in `node/app.ts`). Core's commands route
/// parses and validates it (lengths, counts) and stores its JSON as the
/// command's payload; the runner turns it into RPC commands.
#[derive(Clone, Debug, PartialEq, Deserialize, serde::Serialize)]
#[serde(
    tag = "type",
    rename_all = "snake_case",
    rename_all_fields = "camelCase"
)]
pub enum CommandPayload {
    Prompt {
        message: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        upload_ids: Option<Vec<String>>,
    },
    Steer {
        message: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        upload_ids: Option<Vec<String>>,
    },
    FollowUp {
        message: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        upload_ids: Option<Vec<String>>,
    },
    EditMessage {
        entry_id: String,
        message: String,
    },
    SwitchBranch {
        entry_id: String,
    },
    Stop,
    ClearQueue,
    SendNow {
        /// `steering` or `followUp`.
        queue: String,
        index: u64,
        message: String,
    },
    SetModel {
        provider: String,
        model_id: String,
    },
    SetThinking {
        /// `off`, `minimal`, `low`, `medium`, `high`, `xhigh` or `max`.
        level: String,
    },
    /// This session's approval mode (security audit L14).
    SetApprovalMode {
        /// `read-only`, `auto` or `full-access`.
        mode: String,
    },
}

/// What the gateway pushes into a session (`deliverBody`): a delegated
/// task, news of one, or a scheduled run. Validated by core.
#[derive(Clone, Debug, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Delivery {
    pub custom_type: String,
    pub content: String,
    #[serde(default)]
    pub details: Option<Map<String, Value>>,
    #[serde(default)]
    pub role: Option<String>,
    #[serde(default)]
    pub model: Option<DeliveryModel>,
    #[serde(default)]
    pub thinking: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DeliveryModel {
    pub provider: String,
    pub id: String,
}

/// A failure while dispatching: TS rethrew [`ApiError`]s to the route;
/// anything else was logged, and the route answered from the command row.
enum Failure {
    Api(ApiError),
    Other(String),
}

impl From<ApiError> for Failure {
    fn from(error: ApiError) -> Self {
        Self::Api(error)
    }
}

impl Failure {
    fn message(&self) -> String {
        match self {
            Self::Api(error) => error.message.clone(),
            Self::Other(message) => message.clone(),
        }
    }
}

use pirc_config::text::truthy;

/// `response.error ?? fallback`, as stored text.
fn error_text(response: &Map<String, Value>, fallback: &str) -> String {
    match response.get("error") {
        None | Some(Value::Null) => fallback.to_owned(),
        error => reducer::js_string(error),
    }
}

/// An admission failure may follow a partial journal commit. Never mark that
/// response retryable merely because the agent is still alive.
fn response_status(response: &Map<String, Value>) -> CommandStatus {
    if response.get("errorCode").and_then(Value::as_str) == Some("admission_outcome_unknown") {
        CommandStatus::OutcomeUnknown
    } else if truthy(response.get("success")) {
        CommandStatus::Accepted
    } else {
        CommandStatus::Rejected
    }
}

/// `path.basename`.
fn basename(text: &str) -> &str {
    text.split('/')
        .rfind(|part| !part.is_empty())
        .unwrap_or_default()
}

type Starting = watch::Receiver<Option<ApiResult<Arc<Runner>>>>;

#[derive(Default)]
struct Managed {
    runners: HashMap<String, Arc<Runner>>,
    /// Runners being prepared (the sandbox probe is async); one start per
    /// session.
    starting: HashMap<String, Starting>,
}

/// The node's agents, by session. Runners start without a limit; sessions
/// that only read never contend, and writers are serialized per path by the
/// [`crate::write_broker::WriteBroker`].
pub struct RunnerManager {
    node: WeakNode,
    state: Mutex<Managed>,
    /// Serialize all writers, including delivery, across a branch mutation
    /// and runner restart. Never hold the synchronous manager lock at await.
    commands: Mutex<HashMap<String, std::sync::Weak<CommandGate>>>,
}

impl RunnerManager {
    pub fn new(node: WeakNode) -> Self {
        Self {
            node,
            state: Mutex::default(),
            commands: Mutex::default(),
        }
    }

    fn lock(&self) -> MutexGuard<'_, Managed> {
        self.state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn command_lock(&self, session_id: &str) -> Arc<CommandGate> {
        let mut commands = self
            .commands
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if let Some(lock) = commands.get(session_id).and_then(std::sync::Weak::upgrade) {
            return lock;
        }
        commands.retain(|_, lock| lock.strong_count() > 0);
        let lock = Arc::new(CommandGate::default());
        commands.insert(session_id.to_owned(), Arc::downgrade(&lock));
        lock
    }

    fn node(&self) -> ApiResult<Node> {
        self.node
            .upgrade()
            .ok_or_else(|| ApiError::runner_unavailable("Runner is not available"))
    }

    /// `runners.get(id)`: the session's runner until it exits.
    pub fn get(&self, session_id: &str) -> Option<Arc<Runner>> {
        self.lock().runners.get(session_id).cloned()
    }

    /// Removal must not mistake a start waiting to update its database row
    /// for idle. Avoid lock inversion with the store: uncertainty is busy.
    pub(crate) fn is_starting(&self, session_id: &str) -> bool {
        let state = match self.state.try_lock() {
            Ok(state) => state,
            Err(std::sync::TryLockError::Poisoned(state)) => state.into_inner(),
            Err(std::sync::TryLockError::WouldBlock) => return true,
        };
        state.starting.contains_key(session_id)
    }

    /// Called with the caller's lifecycle lock held. The manager can be busy
    /// starting a runner while waiting for that same lock, so neither lock may
    /// be acquired by waiting here. Uncertain state counts as an active writer.
    pub(crate) fn may_be_alive(&self, session_id: &str) -> bool {
        let state = match self.state.try_lock() {
            Ok(state) => state,
            Err(std::sync::TryLockError::Poisoned(state)) => state.into_inner(),
            Err(std::sync::TryLockError::WouldBlock) => return true,
        };
        state.starting.contains_key(session_id)
            || state
                .runners
                .get(session_id)
                .is_some_and(|r| r.may_be_alive())
    }

    /// A runner exited (its `onExit`).
    pub(crate) fn exited(&self, runner: &Runner) {
        {
            let mut state = self.lock();
            if state
                .runners
                .get(&runner.session_id)
                .is_some_and(|current| std::ptr::eq(Arc::as_ptr(current), runner))
            {
                state.runners.remove(&runner.session_id);
            }
        }
        if let Some(node) = runner.node() {
            node.writes.release(&runner.session_id);
        }
    }

    /// `ensure`: the live runner, or the one start in flight, or a new one.
    async fn ensure(&self, session_id: &str) -> ApiResult<Arc<Runner>> {
        let node = self.node()?;
        node.db.lock().require_session_available(session_id)?;
        node.session_mode(session_id)?;
        let mut starting = loop {
            let exiting = {
                let mut state = self.lock();
                // Checked under the manager's lock: `shutdown` sees every
                // start that got past it.
                if node.closing() {
                    return Err(ApiError::runner_unavailable("Runner is not available"));
                }
                match state.runners.get(session_id).cloned() {
                    Some(runner) if runner.alive() => {
                        if node.workspace_mode(&runner.workspace)? != runner.mode {
                            return Err(ApiError::runner_unavailable(
                                "Mode changed; runner is stopping",
                            ));
                        }
                        return Ok(runner);
                    }
                    // Its exit is under way (TS's was one synchronous step):
                    // the new agent starts after the old teardown (state,
                    // `runner_exit`, leases), which would otherwise hit it.
                    Some(runner) => runner,
                    None => break Self::start_slot(&mut state, &node, session_id),
                }
            };
            exiting.wait_exited().await;
            // `onExit` removed it; never spin on one left behind.
            let mut state = self.lock();
            if state
                .runners
                .get(session_id)
                .is_some_and(|current| Arc::ptr_eq(current, &exiting))
            {
                state.runners.remove(session_id);
            }
        };
        let result = starting
            .wait_for(Option::is_some)
            .await
            .map_err(|_| ApiError::runner_unavailable("Runner is not available"))?;
        result.clone().expect("a finished start")
    }

    /// The session's start in flight, or a new one (under the manager's lock).
    fn start_slot(state: &mut Managed, node: &Node, session_id: &str) -> Starting {
        if let Some(starting) = state.starting.get(session_id) {
            return starting.clone();
        }
        let (done, starting) = watch::channel(None);
        state
            .starting
            .insert(session_id.to_owned(), starting.clone());
        // Its own task: a start goes on when its asker goes away.
        let id = session_id.to_owned();
        let node = node.clone();
        tokio::spawn(async move {
            use futures_util::FutureExt;
            // A panic must not leave the slot behind.
            let result = std::panic::AssertUnwindSafe(start(&node, &id))
                .catch_unwind()
                .await
                .unwrap_or_else(|_| Err(ApiError::runner_unavailable("Runner is not available")));
            {
                let mut state = node.runners.lock();
                state.starting.remove(&id);
                if let Ok(runner) = &result {
                    state.runners.insert(id, runner.clone());
                }
            }
            done.send_replace(Some(result));
        });
        starting
    }

    /// `dispatch`: start the agent if needed and send the command (the
    /// command row is already `received`; this moves it through
    /// `dispatched` to `accepted`, `rejected` or `outcome_unknown`). The
    /// agent's response line. An `Err` is what TS threw as an `ApiError`
    /// (the route answers it); other failures are logged and answered
    /// `Ok` with an empty map, and the route reads the command row.
    pub async fn dispatch(
        &self,
        session_id: &str,
        command_id: &str,
        payload: &CommandPayload,
        user: &str,
        lease: (&str, i64),
    ) -> ApiResult<Map<String, Value>> {
        self.dispatch_configured(session_id, command_id, payload, user, lease, None)
            .await
    }

    pub(crate) async fn dispatch_initial(
        &self,
        session_id: &str,
        command_id: &str,
        payload: &CommandPayload,
        user: &str,
        lease: (&str, i64),
        settings: &InitialSettings,
    ) -> ApiResult<Map<String, Value>> {
        self.dispatch_configured(session_id, command_id, payload, user, lease, Some(settings))
            .await
    }

    async fn dispatch_configured(
        &self,
        session_id: &str,
        command_id: &str,
        payload: &CommandPayload,
        user: &str,
        lease: (&str, i64),
        initial: Option<&InitialSettings>,
    ) -> ApiResult<Map<String, Value>> {
        let lock = self.command_lock(session_id);
        let _command = if matches!(payload, CommandPayload::Stop) {
            lock.stop_lock().await
        } else {
            Some(lock.lock().await)
        };
        let node = self.node()?;
        if !matches!(payload, CommandPayload::Stop) {
            crate::pots::require_generic_input(&node.db.lock(), session_id)?;
        }
        node.db
            .lock()
            .validate_lease(session_id, lease.0, lease.1)?;
        if initial.is_some() {
            crate::session_creation::admission::require_sendable(
                &node.db.lock(),
                session_id,
                command_id,
                user,
            )?;
        }
        if !matches!(payload, CommandPayload::Stop) {
            crate::command_environment::require_current(&node, session_id, command_id, lease)
                .await?;
        }
        let runner = if matches!(payload, CommandPayload::Stop) {
            self.get(session_id)
                .filter(|runner| runner.alive())
                .ok_or_else(|| ApiError::runner_unavailable("No live runner to stop"))?
        } else {
            self.ensure(session_id).await?
        };
        node.db.lock().require_session_available(session_id)?;
        if !matches!(payload, CommandPayload::Stop) {
            crate::command_environment::require_current(&node, session_id, command_id, lease)
                .await?;
        }
        let runner = match payload {
            CommandPayload::EditMessage { entry_id, message } => self
                .change_branch(&node, runner, entry_id, Some(message), lease, command_id)
                .await
                .inspect_err(|error| {
                    let _ = node.db.lock().update_command(
                        command_id,
                        CommandStatus::Rejected,
                        None,
                        Some(&error.message),
                    );
                })?,
            CommandPayload::SwitchBranch { entry_id } => self
                .change_branch(&node, runner, entry_id, None, lease, command_id)
                .await
                .inspect_err(|error| {
                    let _ = node.db.lock().update_command(
                        command_id,
                        CommandStatus::Rejected,
                        None,
                        Some(&error.message),
                    );
                })?,
            _ => runner,
        };
        node.db
            .lock()
            .validate_lease(session_id, lease.0, lease.1)?;
        if let Some(settings) = initial {
            crate::session_creation::admission::require_sendable(
                &node.db.lock(),
                session_id,
                command_id,
                user,
            )?;
            node.db
                .lock()
                .update_command(command_id, CommandStatus::Dispatched, None, None)?;
            let configured: ApiResult<()> = async {
                let commands = [
                    json!({"type":"set_model","provider":settings.provider,"modelId":settings.model_id}),
                    json!({"type":"set_thinking_level","level":settings.thinking}),
                ];
                for rpc in commands {
                    let answer = {
                        let db = node.db.lock();
                        crate::session_creation::admission::require_sendable(
                            &db, session_id, command_id, user,
                        )?;
                        db.validate_lease(session_id, lease.0, lease.1)?;
                        runner
                            .send_request(rpc.as_object().expect("literal RPC object").clone())
                            .map_err(|_| ApiError::runner_unavailable("Initial settings could not be queued"))?
                    };
                    let response = answer
                        .await
                        .map_err(|_| ApiError::runner_unavailable("Initial settings response was lost"))?
                        .map_err(|_| ApiError::runner_unavailable("Initial settings failed"))?;
                    if !truthy(response.get("success")) {
                        return Err(ApiError::new(
                            409,
                            "initial_settings_rejected",
                            "Initial model settings were refused; the message was not queued",
                        ));
                    }
                }
                node.session_mode(session_id)?;
                Ok(())
            }
            .await;
            if let Err(error) = configured {
                node.db.lock().update_command(
                    command_id,
                    CommandStatus::Rejected,
                    None,
                    Some(&error.message),
                )?;
                return Err(error);
            }
        }
        // These inputs have not reached the Agent when construction fails.
        // Persist a final rejection so receipt queries cannot mistake a failed
        // saved attachment check for a message still waiting to be delivered.
        let input_not_queued = matches!(
            payload,
            CommandPayload::Prompt { .. }
                | CommandPayload::Steer { .. }
                | CommandPayload::FollowUp { .. }
        );
        let built = build_rpc(&node, &runner, session_id, payload, user);
        let (rpc, run_id) = match built {
            Ok(built) => built,
            Err(Failure::Api(error)) => {
                if input_not_queued {
                    node.db.lock().update_command(
                        command_id,
                        CommandStatus::Rejected,
                        None,
                        Some(&error.message),
                    )?;
                }
                return Err(error);
            }
            Err(Failure::Other(message)) => {
                if input_not_queued {
                    node.db.lock().update_command(
                        command_id,
                        CommandStatus::Rejected,
                        None,
                        Some(&message),
                    )?;
                }
                crate::log::error(&format!("command dispatch failed: {message}"));
                return Ok(Map::new());
            }
        };
        node.db
            .lock()
            .update_command(command_id, CommandStatus::Dispatched, None, None)?;
        let mut admission_wait = None;
        let outcome: Result<Map<String, Value>, Failure> = async {
            if matches!(payload, CommandPayload::Stop) {
                let _host_stop = node.host_commands.stop(session_id);
                runner.cancel_sandbox_requests();
                let mut clear = Map::new();
                clear.insert("type".into(), json!("clear_queue"));
                let cleared = runner.request(clear).await?;
                if !truthy(cleared.get("success")) {
                    return Err(Failure::Other(error_text(&cleared, "clear_queue rejected")));
                }
                let mut abort = Map::new();
                abort.insert("type".into(), json!("abort"));
                let mut response = runner.request(abort).await?;
                node.host_commands.wait_session(&node, session_id).await?;
                let mut data = Map::new();
                if let Some(cleared) = cleared.get("data") {
                    data.insert("cleared".into(), cleared.clone());
                }
                response.insert("data".into(), Value::Object(data));
                Ok(response)
            } else if matches!(
                payload,
                CommandPayload::Prompt { .. }
                    | CommandPayload::Steer { .. }
                    | CommandPayload::FollowUp { .. }
            ) {
                // Keep ordinary commands/deliveries serialized. Stop can
                // overtake only once this RPC is actually queued, so it cannot
                // miss a not-yet-sent prompt or allow a model change to retarget it.
                let answer = if initial.is_some() {
                    // Synchronous enqueue shares the Stop fence's SQLite lock.
                    let db = node.db.lock();
                    crate::session_creation::admission::require_sendable(
                        &db, session_id, command_id, user,
                    )?;
                    db.validate_lease(session_id, lease.0, lease.1)?;
                    runner.send_request(rpc)?
                } else {
                    let db = node.db.lock();
                    crate::execution_fences::require_open(&db, session_id)?;
                    runner.send_request(rpc)?
                };
                admission_wait = Some(lock.admission());
                Ok(answer
                    .await
                    .map_err(|_| Failure::Other("Agent response was lost".into()))??)
            } else {
                Ok(runner.request(rpc).await?)
            }
        }
        .await;
        match outcome {
            Ok(response) => {
                let db = node.db.lock();
                let status = response_status(&response);
                if status == CommandStatus::Accepted {
                    db.update_command(
                        command_id,
                        CommandStatus::Accepted,
                        Some(&Value::Object(response.clone())),
                        None,
                    )?;
                } else {
                    db.update_command(
                        command_id,
                        status,
                        Some(&Value::Object(response.clone())),
                        Some(&error_text(&response, "Agent rejected command")),
                    )?;
                    if let Some(run) = &run_id {
                        db.update_run(
                            run,
                            if status == CommandStatus::OutcomeUnknown {
                                RunStatus::Interrupted
                            } else {
                                RunStatus::Failed
                            },
                            Some(&error_text(&response, "Agent rejected prompt")),
                        )?;
                        node.activity.notify_one();
                    }
                }
                Ok(response)
            }
            Err(failure) => {
                let message = failure.message();
                let alive = runner.alive();
                {
                    let db = node.db.lock();
                    let uncertain_stop = matches!(payload, CommandPayload::Stop)
                        && matches!(&failure, Failure::Api(error) if error.code == "host_stop_unconfirmed");
                    let status = if alive && admission_wait.is_none() && !uncertain_stop {
                        CommandStatus::Rejected
                    } else {
                        CommandStatus::OutcomeUnknown
                    };
                    db.update_command(command_id, status, None, Some(&message))?;
                    if let Some(run) = &run_id {
                        let status = if alive {
                            RunStatus::Failed
                        } else {
                            RunStatus::Interrupted
                        };
                        db.update_run(run, status, Some(&message))?;
                        node.activity.notify_one();
                    }
                }
                match failure {
                    Failure::Api(error) => Err(error),
                    Failure::Other(message) => {
                        crate::log::error(&format!("command dispatch failed: {message}"));
                        Ok(Map::new())
                    }
                }
            }
        }
    }

    /// Durable branch changes are performed only after the idle
    /// process has fully exited. The caller holds the per-session writer lock,
    /// so neither another command nor a delivery can restart it in between.
    async fn change_branch(
        &self,
        node: &Node,
        runner: Arc<Runner>,
        entry_id: &str,
        message: Option<&str>,
        lease: (&str, i64),
        command_id: &str,
    ) -> ApiResult<Arc<Runner>> {
        let session_id = runner.session_id.clone();
        let busy = || {
            ApiError::new(
                409,
                "session_busy",
                "Stop running work and clear queued messages before changing branches",
            )
        };
        let session = {
            let db = node.db.lock();
            if db
                .latest_run(&session_id)?
                .is_some_and(|run| run.status.is_open())
            {
                return Err(busy());
            }
            db.get_session(&session_id)?
        };
        let mut state = Map::new();
        state.insert("type".into(), json!("get_state"));
        let state = runner.request(state).await?;
        if !truthy(state.get("success")) {
            return Err(ApiError::runner_unavailable(
                "Cannot verify that the session is idle",
            ));
        }
        let data = state.get("data").ok_or_else(|| {
            ApiError::runner_unavailable("Cannot verify that the session is idle")
        })?;
        if branch_state_busy(data) {
            return Err(busy());
        }
        let approval_mode = data.get("approvalMode").and_then(Value::as_str);
        let reduced = runner.state();
        if reduced.partial_message.is_some()
            || !reduced.operations.is_empty()
            || !reduced.queue.steering.is_empty()
            || !reduced.queue.follow_up.is_empty()
        {
            return Err(busy());
        }
        let mut panel = Map::new();
        panel.insert("type".into(), json!("get_panel_state"));
        let panel = runner.request(panel).await?;
        if !truthy(panel.get("success")) {
            return Err(ApiError::runner_unavailable(
                "Cannot verify background tasks are idle",
            ));
        }
        if branch_background_busy(panel.get("data").unwrap_or(&Value::Null)) {
            return Err(busy());
        }
        runner
            .stop(Duration::from_millis(node.config.shutdown_grace_ms))
            .await;
        if runner.alive() {
            return Err(ApiError::runner_unavailable(
                "The chat process has not stopped yet; retry branch change",
            ));
        }
        crate::command_environment::require_current(node, &session_id, command_id, lease).await?;
        let dir = std::path::Path::new(&session.private_session_path);
        {
            let db = node.db.lock();
            db.require_session_available(&session_id)?;
            crate::execution_fences::require_open(&db, &session_id)?;
            // The controller may have expired or been replaced during idle RPCs
            // or process shutdown. Hold the DB fence through the disk mutation so
            // a competing lease acquisition cannot overtake this final check.
            db.validate_lease(&session_id, lease.0, lease.1)?;
            let result = match message {
                Some(message) => pirc_agent::session_store::edit_session_message(
                    dir,
                    entry_id,
                    message,
                    approval_mode,
                )
                .map(|_| ()),
                None => {
                    pirc_agent::session_store::select_session_branch(dir, entry_id, approval_mode)
                }
            };
            result.map_err(ApiError::bad_request)?;
        }
        node.branches.forget(dir);
        self.ensure(&session_id).await
    }

    /// `deliver`: start the agent if needed; `set_role`, `set_model`,
    /// `set_thinking_level` (each must succeed, else 503), then `deliver`.
    /// The message runs next, after any run in progress.
    pub async fn deliver(&self, session_id: &str, delivery: &Delivery) -> ApiResult<()> {
        let node = self.node()?;
        crate::session_creation::admission::require_generic(&node.db.lock(), session_id)?;
        if delivery.custom_type == "pots-dispatch" {
            return Err(ApiError::invalid_input());
        }
        crate::pots::require_generic_input(&node.db.lock(), session_id)?;
        self.deliver_checked(session_id, delivery, || {
            crate::pots::require_generic_input(&node.db.lock(), session_id)?;
            Ok(true)
        })
        .await
        .map(|_| ())
    }

    /// Claim a backend send only after startup/configuration and the command lock.
    pub(crate) async fn deliver_checked(
        &self,
        session_id: &str,
        delivery: &Delivery,
        check: impl FnOnce() -> ApiResult<bool> + Send,
    ) -> ApiResult<bool> {
        let lock = self.command_lock(session_id);
        let _command = lock.lock().await;
        let node = self.node()?;
        let runner = self.ensure(session_id).await?;
        node.db.lock().require_session_available(session_id)?;
        // The role first: the user's model and thinking level override the role's.
        let mut commands = Vec::new();
        if let Some(role) = delivery.role.as_deref().filter(|role| !role.is_empty()) {
            commands.push(json!({ "type": "set_role", "role": role }));
        }
        if let Some(model) = &delivery.model {
            commands.push(
                json!({ "type": "set_model", "provider": model.provider, "modelId": model.id }),
            );
        }
        if let Some(thinking) = delivery
            .thinking
            .as_deref()
            .filter(|level| !level.is_empty())
        {
            commands.push(json!({ "type": "set_thinking_level", "level": thinking }));
        }
        for command in commands {
            let Value::Object(command) = command else {
                continue;
            };
            let kind = command["type"].as_str().unwrap_or_default().to_owned();
            let set = runner.request(command).await?;
            if !truthy(set.get("success")) {
                return Err(ApiError::runner_unavailable(error_text(
                    &set,
                    &format!("The agent refused {kind}"),
                )));
            }
        }
        if !check()? {
            return Ok(false);
        }
        let mut message = Map::new();
        message.insert("customType".into(), json!(delivery.custom_type));
        message.insert("content".into(), json!(delivery.content));
        if let Some(details) = &delivery.details {
            message.insert("details".into(), Value::Object(details.clone()));
        }
        let mut deliver = Map::new();
        deliver.insert("type".into(), json!("deliver"));
        deliver.insert("message".into(), Value::Object(message));
        let response = runner.request(deliver).await?;
        if !truthy(response.get("success")) {
            return Err(ApiError::runner_unavailable(error_text(
                &response,
                "The agent refused the message",
            )));
        }
        Ok(true)
    }

    /// `answer`: 409 `stale_interaction` unless the session's live runner
    /// is in `epoch`; a node dialog is resolved locally, else
    /// `extension_ui_response` goes to the agent. The interaction
    /// (`interaction_id`) is already claimed by the route;
    /// `interaction_answered` is published here, before the answer reaches
    /// the agent or the node dialog.
    pub async fn answer(
        &self,
        session_id: &str,
        epoch: i64,
        rpc_id: &str,
        interaction_id: &str,
        answer: &Map<String, Value>,
    ) -> ApiResult<()> {
        self.node()?.session_mode(session_id)?;
        let runner = self.get(session_id);
        let Some(runner) = runner.filter(|runner| runner.alive() && runner.epoch() == epoch) else {
            return Err(ApiError::new(
                409,
                "stale_interaction",
                "Interaction belongs to an inactive runner epoch",
            ));
        };
        runner.answer(rpc_id, interaction_id, answer).await
    }

    /// `stopSession` (chat deletion): wait for a start in flight, stop the
    /// runner (grace `config.shutdown_grace_ms`); 503 `runner_unavailable`
    /// "The chat process has not stopped yet; retry deletion" when it lives
    /// on; release its write leases.
    pub async fn stop_session(&self, session_id: &str) -> ApiResult<()> {
        self.stop_session_checked(session_id, || Ok(())).await
    }

    /// Recheck a backend dispatch fence after waiting for startup/commands.
    pub(crate) async fn stop_session_checked(
        &self,
        session_id: &str,
        check: impl FnOnce() -> ApiResult<()> + Send,
    ) -> ApiResult<()> {
        let lock = self.command_lock(session_id);
        let _command = lock.stop_lock().await;
        let node = self.node()?;
        // A start already probing the sandbox must finish before its files
        // can be removed.
        let starting = self.lock().starting.get(session_id).cloned();
        if let Some(mut starting) = starting {
            let _ = starting.wait_for(Option::is_some).await;
        }
        check()?;
        let _host_stop = node.host_commands.stop(session_id);
        if let Some(runner) = self.get(session_id) {
            runner
                .stop(Duration::from_millis(node.config.shutdown_grace_ms))
                .await;
            if runner.alive() {
                return Err(ApiError::runner_unavailable(
                    "The chat process has not stopped yet; retry deletion",
                ));
            }
        }
        node.host_commands.wait_session(&node, session_id).await?;
        node.writes.release(session_id);
        Ok(())
    }

    /// Stop every runner, in parallel (node shutdown). Called once the
    /// node is `closing`, so no start begins after the starts in flight,
    /// which are waited for and their runners stopped too.
    pub async fn shutdown(&self) {
        let Ok(node) = self.node() else {
            return;
        };
        let grace = Duration::from_millis(node.config.shutdown_grace_ms);
        let starting: Vec<Starting> = self.lock().starting.values().cloned().collect();
        for mut starting in starting {
            let _ = starting.wait_for(Option::is_some).await;
        }
        let runners: Vec<Arc<Runner>> = self.lock().runners.values().cloned().collect();
        futures_util::future::join_all(runners.iter().map(|runner| runner.stop(grace))).await;
    }
}

fn branch_state_busy(data: &Value) -> bool {
    // Fail closed if an old agent does not provide the idle-state fields.
    data.get("isStreaming").and_then(Value::as_bool) != Some(false)
        || data.get("isCompacting").and_then(Value::as_bool) != Some(false)
        || data.get("pendingMessageCount").and_then(Value::as_u64) != Some(0)
        || data
            .get("completionWaiting")
            .is_some_and(|value| match value {
                Value::Null | Value::Bool(false) => false,
                Value::Array(items) => !items.is_empty(),
                _ => true,
            })
}

fn branch_background_busy(data: &Value) -> bool {
    data.get("backgroundTasks")
        .and_then(Value::as_array)
        .is_some_and(|tasks| {
            tasks.iter().any(|task| {
                matches!(
                    task.get("status").and_then(Value::as_str),
                    Some("running" | "stopping")
                )
            })
        })
}

/// `start`: prepare the sandbox and spawn the agent; on failure the
/// sandbox is cleaned up, leases released and the runner state `failed`.
async fn start(node: &Node, session_id: &str) -> ApiResult<Arc<Runner>> {
    let session = {
        let db = node.db.lock();
        let session = db.get_session(session_id)?;
        db.set_runner_state(session_id, RunnerState::Starting)?;
        session
    };
    let started = async {
        let workspace = node.db.lock().get_workspace(&session.workspace_id)?;
        let mode = node.workspace_mode(&workspace)?;
        let root = crate::chat::session_root(&workspace, session_id, &mode)?;
        let recovery = crate::checkpoints::continuation::runner_ticket(
            node,
            &workspace,
            session.owner_user.as_deref().unwrap_or_default(),
        )
        .await?;
        let ledger = if recovery.is_none() {
            workspace_ledger(node, &workspace, &root).await
        } else {
            None
        };
        let input = if let Some(ticket) = recovery {
            ticket.prepare_input(
                session_id.to_owned(),
                session.private_session_path.clone().into(),
                node.models.inference().map(|i| i.socket_path.into()),
            )
        } else {
            crate::sandbox::PrepareInput {
                session_id: session_id.to_owned(),
                workspace_root: root,
                session_dir: session.private_session_path.clone().into(),
                inference_socket: node
                    .models
                    .inference()
                    .map(|inference| inference.socket_path.into()),
                // The user's project instructions: never writable from the session.
                protected_paths: crate::chat::project_instructions_path(&workspace, &mode)
                    .into_iter()
                    .collect(),
                workspace_memory_file: ledger.as_ref().map(|ledger| ledger.file.clone()),
                // Read-only and shared: uploads reach the running session.
                project_files_dir: crate::project_files::existing_files_dir(&workspace, &mode),
                recovery: None,
            }
        };
        let prepared = node.sandbox.prepare(input).await?;
        if node.workspace_mode(&workspace)? != mode {
            prepared.cleanup();
            return Err(ApiError::runner_unavailable(
                "Mode changed while starting runner",
            ));
        }
        process::spawn(
            node,
            process::Spawn {
                session: session.clone(),
                mode,
                workspace,
                prepared,
                ledger,
            },
        )
        .await
    }
    .await;
    if started.is_err() {
        node.writes.release(session_id);
        let _ = node
            .db
            .lock()
            .set_runner_state(session_id, RunnerState::Failed);
    }
    started
}

/// The workspace-memory ledger of a directory workspace's session in
/// `root`, keyed from the repository's files (never by running git on the
/// host), off the async runtime. Chats keep no workspace memory.
async fn workspace_ledger(
    node: &Node,
    workspace: &crate::store::Workspace,
    root: &std::path::Path,
) -> Option<pirc_agent::features::memory::workspace::WorkspaceLedger> {
    if !node
        .workspace_mode(workspace)
        .ok()
        .is_some_and(|mode| mode.workspace_memory)
    {
        return None;
    }
    let dir = node
        .config
        .workspace_memory_dir
        .to_string_lossy()
        .into_owned();
    let root = root.to_string_lossy().into_owned();
    tokio::task::spawn_blocking(move || {
        pirc_agent::features::memory::workspace::WorkspaceLedger::for_node(dir, &root)
    })
    .await
    .ok()
}

/// The RPC command of a payload, and the run a prompt opens.
fn build_rpc(
    node: &Node,
    runner: &Runner,
    session_id: &str,
    payload: &CommandPayload,
    user: &str,
) -> Result<(Map<String, Value>, Option<String>), Failure> {
    let mut rpc = Map::new();
    let mut run_id = None;
    let kind = serde_json::to_value(payload)
        .ok()
        .and_then(|value| value["type"].as_str().map(str::to_owned))
        .unwrap_or_default();
    match payload {
        CommandPayload::Prompt {
            message,
            upload_ids,
        }
        | CommandPayload::Steer {
            message,
            upload_ids,
        }
        | CommandPayload::FollowUp {
            message,
            upload_ids,
        } => {
            let ids = upload_ids.as_deref().unwrap_or_default();
            let notes = file_attachments(node, ids, user, session_id)?;
            let message = if notes.is_empty() {
                message.clone()
            } else {
                let list: Vec<String> = notes.iter().map(|path| format!("- {path}")).collect();
                format!(
                    "{message}\n\nAttached file(s) available to read from the workspace:\n{}",
                    list.join("\n")
                )
            };
            rpc.insert("type".into(), json!(kind));
            rpc.insert("message".into(), json!(message));
            if let Some(images) = image_contents(node, ids, user, session_id)? {
                rpc.insert("images".into(), Value::Array(images));
            }
            if matches!(payload, CommandPayload::Prompt { .. }) {
                let run = node.db.lock().create_run(session_id)?;
                node.activity.notify_one();
                runner.set_run(&run);
                run_id = Some(run);
            }
        }
        CommandPayload::EditMessage { .. } => {
            rpc.insert("type".into(), json!("resume_branch"));
            let run = node.db.lock().create_run(session_id)?;
            node.activity.notify_one();
            runner.set_run(&run);
            run_id = Some(run);
        }
        CommandPayload::SwitchBranch { .. } => {
            // The new runner has already reloaded the selected branch.
            rpc.insert("type".into(), json!("get_state"));
        }
        CommandPayload::SetModel { provider, model_id } => {
            rpc.insert("type".into(), json!("set_model"));
            rpc.insert("provider".into(), json!(provider));
            rpc.insert("modelId".into(), json!(model_id));
        }
        CommandPayload::SetThinking { level } => {
            rpc.insert("type".into(), json!("set_thinking_level"));
            rpc.insert("level".into(), json!(level));
        }
        CommandPayload::SetApprovalMode { mode } => {
            rpc.insert("type".into(), json!("set_approval_mode"));
            rpc.insert("mode".into(), json!(mode));
        }
        CommandPayload::SendNow {
            queue,
            index,
            message,
        } => {
            rpc.insert("type".into(), json!("send_now"));
            rpc.insert("queue".into(), json!(queue));
            rpc.insert("index".into(), json!(index));
            rpc.insert("message".into(), json!(message));
        }
        CommandPayload::Stop | CommandPayload::ClearQueue => {
            rpc.insert("type".into(), json!(kind));
        }
    }
    Ok((rpc, run_id))
}

/// The uploads, each the user's and made in the session's workspace (an
/// upload from before schema 2001 records no workspace and is accepted).
fn uploads(
    node: &Node,
    ids: &[String],
    user: &str,
    session_id: &str,
) -> ApiResult<Vec<crate::store::UploadRow>> {
    let db = node.db.lock();
    ids.iter()
        .map(|id| crate::upload_origins::authorize(&db, session_id, user, id))
        .collect()
}

/// `imageContents`: image uploads as the agent's image blocks.
fn image_contents(
    node: &Node,
    ids: &[String],
    user: &str,
    session_id: &str,
) -> Result<Option<Vec<Value>>, Failure> {
    if ids.is_empty() {
        return Ok(None);
    }
    let mut images = Vec::new();
    for upload in uploads(node, ids, user, session_id)? {
        if upload.kind != UploadKind::Image {
            continue;
        }
        let bytes = crate::upload_origins::read_verified(&node.config.uploads_dir, &upload)?;
        use base64::Engine;
        let data = base64::engine::general_purpose::STANDARD.encode(bytes);
        images.push(json!({ "type": "image", "data": data, "mimeType": upload.mime_type }));
    }
    Ok((!images.is_empty()).then_some(images))
}

/// `fileAttachments`: non-image uploads are not sent to the model: each is
/// copied into the session's workspace (under `.pirc/uploads`, already an
/// allowed root for the agent's file tools), and the prompt points at it.
fn file_attachments(
    node: &Node,
    ids: &[String],
    user: &str,
    session_id: &str,
) -> Result<Vec<String>, Failure> {
    if ids.is_empty() {
        return Ok(Vec::new());
    }
    let files: Vec<_> = uploads(node, ids, user, session_id)?
        .into_iter()
        .filter(|upload| upload.kind == UploadKind::File)
        .collect();
    if files.is_empty() {
        return Ok(Vec::new());
    }
    let workspace = {
        let db = node.db.lock();
        let session = db.get_session(session_id)?;
        db.get_workspace(&session.workspace_id)?
    };
    // Written from outside the sandbox: no symlink below the session root
    // is followed (a cloned repository may track one).
    let mode = node.workspace_mode(&workspace)?;
    let root = crate::chat::session_root(&workspace, session_id, &mode)?;
    let dest_dir = crate::private_dir::open_dir(&root, &[".pirc", "uploads"]).map_err(|error| {
        Failure::Other(format!("{}: {error}", root.join(".pirc/uploads").display()))
    })?;
    let mut notes = Vec::new();
    for upload in files {
        let name = upload
            .filename
            .as_deref()
            .filter(|name| !name.is_empty())
            .unwrap_or(&upload.id);
        let dest_name = format!("{}-{}", upload.id, basename(name));
        let bytes = crate::upload_origins::read_verified(&node.config.uploads_dir, &upload)?;
        // An existing entry (copied for an earlier prompt) is kept.
        match crate::private_dir::create_new(&dest_dir, &dest_name) {
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(error) => {
                return Err(Failure::Other(format!(
                    ".pirc/uploads/{dest_name}: {error}"
                )));
            }
            Ok(mut dest) => {
                if let Err(error) = std::io::Write::write_all(&mut dest, &bytes) {
                    crate::private_dir::remove(&dest_dir, &dest_name);
                    return Err(Failure::Other(format!(
                        "Saved attachment could not be copied: {error}"
                    )));
                }
            }
        }
        notes.push(format!(".pirc/uploads/{dest_name}"));
    }
    Ok(notes)
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[tokio::test]
    async fn first_send_uploads_are_session_bound_while_legacy_scope_is_preserved() {
        let f = crate::workspace_memory::tests::Fixture::new().await;
        let other = f
            .node
            .db
            .lock()
            .create_session("repo", "/other-session", "alice")
            .unwrap();
        let make = |id: &str| crate::store::UploadRow {
            id: id.into(),
            owner_user: "alice".into(),
            mime_type: "text/plain".into(),
            byte_size: 4,
            storage_name: format!("{}.bin", &crate::util::sha256_hex(id)[..48]),
            sha256: crate::util::sha256_hex(b"test"),
            kind: UploadKind::File,
            filename: Some("file.txt".into()),
            workspace_id: Some("repo".into()),
            session_id: Some(f.current.clone()),
        };
        let legacy = make("legacy");
        let durable = make("durable");
        {
            let db = f.node.db.lock();
            db.create_upload(&legacy).unwrap();
            db.create_upload(&durable).unwrap();
            db.execute("INSERT INTO creation_uploads(owner_user,operation_id,attachment_id,session_id,upload_id,request_hash,upload_json,state,created_at) VALUES('alice','op','attachment',?1,'durable',?2,?3,'ready',1)",rusqlite::params![f.current,"a".repeat(64),serde_json::to_string(&durable).unwrap()]).unwrap();
        }
        assert_eq!(
            uploads(&f.node, &["durable".into()], "alice", &f.current).unwrap(),
            [durable]
        );
        assert_eq!(
            uploads(&f.node, &["durable".into()], "alice", &other.id)
                .unwrap_err()
                .status,
            403
        );
        assert_eq!(
            uploads(&f.node, &["legacy".into()], "alice", &other.id).unwrap(),
            [legacy]
        );
        f.node.close().await;
    }

    #[tokio::test]
    async fn saved_file_replay_preserves_later_edits_and_rejects_corrupted_sources() {
        let f = crate::workspace_memory::tests::Fixture::new().await;
        let upload = crate::store::UploadRow {
            id: "file".into(),
            owner_user: "alice".into(),
            mime_type: "text/plain".into(),
            byte_size: 4,
            storage_name: "saved.bin".into(),
            sha256: crate::util::sha256_hex(b"test"),
            kind: UploadKind::File,
            filename: Some("notes.txt".into()),
            workspace_id: Some("repo".into()),
            session_id: Some(f.current.clone()),
        };
        f.node.db.lock().create_upload(&upload).unwrap();
        let source = f.node.config.uploads_dir.join("saved.bin");
        std::fs::write(&source, b"test").unwrap();
        let first = file_attachments(&f.node, &["file".into()], "alice", &f.current)
            .unwrap_or_else(|_| panic!("valid saved attachment must materialize"));
        let workspace = f.node.db.lock().get_workspace("repo").unwrap();
        let root = crate::chat::session_root(&workspace, &f.current, &f.mode).unwrap();
        let copy = root.join(&first[0]);
        std::fs::write(&copy, b"later user edit").unwrap();
        assert_eq!(
            file_attachments(&f.node, &["file".into()], "alice", &f.current)
                .unwrap_or_else(|_| panic!("valid saved attachment must materialize")),
            first
        );
        assert_eq!(std::fs::read(&copy).unwrap(), b"later user edit");
        std::fs::write(&source, b"evil").unwrap();
        assert!(file_attachments(&f.node, &["file".into()], "alice", &f.current).is_err());
        assert_eq!(std::fs::read(&copy).unwrap(), b"later user edit");
        f.node.close().await;
    }

    #[test]
    fn js_helpers() {
        assert!(!truthy(None));
        assert!(!truthy(Some(&json!(0))));
        assert!(!truthy(Some(&json!(""))));
        assert!(truthy(Some(&json!(true))));
        assert!(truthy(Some(&json!({}))));
        let response = |error: Value| {
            let mut map = Map::new();
            map.insert("error".into(), error);
            map
        };
        assert_eq!(error_text(&Map::new(), "fallback"), "fallback");
        assert_eq!(error_text(&response(Value::Null), "fallback"), "fallback");
        assert_eq!(error_text(&response(json!("no")), "fallback"), "no");
        assert_eq!(basename("dir/notes.txt"), "notes.txt");
        assert_eq!(basename("a/b/"), "b");
        assert_eq!(basename("../.."), "..");
    }

    #[test]
    fn branch_changes_require_idle_state() {
        let idle = json!({ "isStreaming": false, "isCompacting": false, "pendingMessageCount": 0, "completionWaiting": [] });
        assert!(!branch_state_busy(&idle));
        assert!(branch_state_busy(&Value::Null));
        for (key, value) in [
            ("isStreaming", json!(true)),
            ("isCompacting", json!(true)),
            ("pendingMessageCount", json!(1)),
            ("completionWaiting", json!({ "reason": "waiting" })),
        ] {
            let mut state = idle.clone();
            state[key] = value;
            assert!(branch_state_busy(&state), "{key}");
        }
        assert!(!branch_background_busy(
            &json!({ "backgroundTasks": [{ "status": "completed" }] })
        ));
        for status in ["running", "stopping"] {
            assert!(branch_background_busy(
                &json!({ "backgroundTasks": [{ "status": status }] })
            ));
        }
    }

    #[tokio::test]
    async fn commands_and_deliveries_share_one_session_lock() {
        let manager = RunnerManager::new(WeakNode::new());
        let first = manager.command_lock("s");
        let second = manager.command_lock("s");
        let other = manager.command_lock("other");
        let held = first.lock().await;
        assert!(second.try_lock().is_err());
        assert!(other.try_lock().is_ok());
        drop(held);
        assert!(second.try_lock().is_ok());
    }

    #[test]
    fn ambiguous_admission_is_not_a_retryable_rejection() {
        let classify = |value: Value| response_status(value.as_object().unwrap());
        assert_eq!(classify(json!({"success":true})), CommandStatus::Accepted);
        assert_eq!(
            classify(json!({"success":false,"error":"already running"})),
            CommandStatus::Rejected
        );
        assert_eq!(
            classify(json!({"success":false,"errorCode":"admission_outcome_unknown"})),
            CommandStatus::OutcomeUnknown
        );
        // An inconsistent success must not erase a failure fence.
        assert_eq!(
            classify(json!({"success":true,"errorCode":"admission_outcome_unknown"})),
            CommandStatus::OutcomeUnknown
        );
    }

    #[test]
    fn command_payloads() {
        let parse = |value: Value| serde_json::from_value::<CommandPayload>(value).unwrap();
        assert_eq!(
            parse(json!({ "type": "follow_up", "message": "m", "uploadIds": ["u"] })),
            CommandPayload::FollowUp {
                message: "m".into(),
                upload_ids: Some(vec!["u".into()])
            }
        );
        assert_eq!(
            parse(json!({ "type": "set_model", "provider": "p", "modelId": "m" })),
            CommandPayload::SetModel {
                provider: "p".into(),
                model_id: "m".into()
            }
        );
        assert_eq!(
            serde_json::to_value(CommandPayload::SendNow {
                queue: "followUp".into(),
                index: 1,
                message: "m".into()
            })
            .unwrap(),
            json!({ "type": "send_now", "queue": "followUp", "index": 1, "message": "m" })
        );
        assert_eq!(
            parse(json!({ "type": "clear_queue" })),
            CommandPayload::ClearQueue
        );
        assert!(
            serde_json::from_value::<Delivery>(json!({ "customType": "scheduled-run",
            "content": "c", "extra": 1 }))
            .is_err()
        );
    }
}
