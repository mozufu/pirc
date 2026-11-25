//! One agent process (`PiRunner`): spawn, the stdout lines in
//! `handleValue` order, run bookkeeping, exit and stop.

use std::collections::HashMap;
use std::path::PathBuf;
use std::process::Stdio;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use indexmap::IndexSet;
use nix::sys::signal::{Signal, kill, killpg};
use nix::unistd::Pid;
use pirc_config::env_allowlist::without_secrets;
use serde_json::{Map, Value, json};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::{mpsc, oneshot, watch};
use tokio::task::AbortHandle;

use pirc_agent::features::memory::workspace::WorkspaceLedger;

use super::framing::{JsonlParser, line};
use super::reducer::ReducedState;
use crate::error::{ApiError, ApiResult};
use crate::sandbox::Prepared;
use crate::services::{Node, WeakNode};
use crate::store::{RunStatus, RunnerState, SessionRow, Store, Workspace};
use crate::util::{head16, now_ms, prefix_uuid, uuid};

/// Interactions the node asks itself (sandbox approvals) carry rpc ids
/// with this prefix. Answers to them never reach the agent, and the agent
/// can neither open nor cancel one: its word is not the human's.
pub(super) const NODE_DIALOG_PREFIX: &str = "node-sandbox-";
const DIALOG_METHODS: [&str; 4] = ["select", "confirm", "input", "editor"];

/// A line for the agent's stdin.
pub(super) struct Outbound {
    pub line: String,
}

/// A side request of the agent in flight (`AbortController`s of TS).
pub(super) struct SideRequest {
    /// Turned true by `sandbox_cancel`, `browser_cancel` or the exit. Shared
    /// with the request's task: a later request reusing the id replaces the
    /// entry without closing this channel (a closed channel reads as an
    /// abort, and TS did not abort a replaced request). The `Arc` is also
    /// the entry's identity.
    pub abort: Arc<watch::Sender<bool>>,
    /// A node dialog it waits on, withdrawn with it.
    pub dialog: Option<String>,
    pub task: Option<AbortHandle>,
}

#[derive(Default)]
pub(super) struct Inner {
    pub closed: bool,
    pub state: ReducedState,
    pub pending: HashMap<String, oneshot::Sender<ApiResult<Map<String, Value>>>>,
    /// Node dialogs by rpc id: the human's yes or no.
    pub node_dialogs: HashMap<String, oneshot::Sender<bool>>,
    pub sandbox_requests: HashMap<String, SideRequest>,
    pub browser_requests: HashMap<String, SideRequest>,
    /// Domains the human allowed for this session, beyond the policy.
    pub approved_domains: IndexSet<String>,
    pub current_run: Option<String>,
    /// Error from the latest assistant turn; a later successful turn clears it.
    pub run_error: Option<String>,
    pub gateway_requests: usize,
}

/// One live agent process (`PiRunner`).
pub struct Runner {
    pub(super) node: WeakNode,
    pub(super) session_id: String,
    pub(super) workspace: Workspace,
    pub(super) mode: pirc_protocol::Mode,
    pub(super) epoch: i64,
    pid: Option<u32>,
    pub(super) prepared: Prepared,
    persistence: Option<crate::persistence::Lease>,
    inference: Option<crate::inference::Lease>,
    launch: Option<crate::process_journal::Launch>,
    stdin: mpsc::UnboundedSender<Outbound>,
    pub(super) inner: Mutex<Inner>,
    /// Held while one agent line is handled, and while a snapshot reads the
    /// reduced state with the stream's watermark: TS reduced and published
    /// in one synchronous step, so a snapshot's state and watermark always
    /// agreed (an event is either in both or in neither). Taken before
    /// `inner`, the store and the hub, never while holding them.
    view: Mutex<()>,
    /// Set once `wait` reaped the agent: its pid may belong to another
    /// process from then on.
    reaped: AtomicBool,
    exited: watch::Sender<bool>,
}

/// Marks the end of `exit` when dropped.
struct Exited<'a>(&'a watch::Sender<bool>);

impl Drop for Exited<'_> {
    fn drop(&mut self) {
        self.0.send_replace(true);
    }
}

fn runner_unavailable() -> ApiError {
    ApiError::runner_unavailable("Runner is not available")
}

/// A failure inside `handleValue`: TS threw, and the runner was killed.
fn thrown(error: ApiError) -> String {
    error.message
}

impl Runner {
    pub(crate) fn mode_snapshot(&self) -> &pirc_protocol::Mode {
        &self.mode
    }

    pub fn epoch(&self) -> i64 {
        self.epoch
    }

    /// False once the process exited.
    pub fn alive(&self) -> bool {
        !self.lock().closed
    }

    /// Conservative, nonblocking lifecycle check while another runner is locked.
    /// Contention (including teardown) must refuse cold cutover, never wait on
    /// a peer that may itself be checking this runner.
    pub(super) fn may_be_alive(&self) -> bool {
        match self.inner.try_lock() {
            Ok(inner) => !inner.closed,
            Err(std::sync::TryLockError::Poisoned(inner)) => !inner.into_inner().closed,
            Err(std::sync::TryLockError::WouldBlock) => true,
        }
    }

    /// For snapshots: `{active: true}` (a runner exists only inside the sandbox).
    pub fn sandbox_status(&self) -> Value {
        json!({ "active": true })
    }

    /// The reduced live state (partial message, queue, notifications,
    /// widgets, statuses, running operations), for snapshots.
    pub fn state(&self) -> ReducedState {
        self.lock().state.clone()
    }

    /// The reduced state, and whatever `read` takes from the store and
    /// the event hub, as of one point between two agent lines (and two node
    /// dialogs): every event the state, the store rows and the watermark
    /// read in `read` reflect is at or before that watermark, and every
    /// later one after it. TS built a snapshot in one tick; here `read`
    /// must not block on anything but the store and the hub.
    pub fn state_at<R>(&self, read: impl FnOnce(ReducedState) -> R) -> R {
        let _view = self.view();
        let state = self.lock().state.clone();
        read(state)
    }

    pub(super) fn lock(&self) -> MutexGuard<'_, Inner> {
        self.inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Held while one agent line is reduced, booked and published, and
    /// while a node dialog is created: see [`Runner::state_at`].
    pub(super) fn view(&self) -> MutexGuard<'_, ()> {
        self.view
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Resolves once `exit` has run to its end (teardown, bookkeeping,
    /// `runner_exit`, the manager's `onExit`).
    pub(super) async fn wait_exited(&self) {
        let mut exited = self.exited.subscribe();
        let _ = exited.wait_for(|exited| *exited).await;
    }

    pub(super) fn node(&self) -> Option<Node> {
        self.node.upgrade()
    }

    /// Whether lines can still reach the agent (`!closed && stdin.writable`).
    pub(super) fn writable(&self) -> bool {
        !self.lock().closed && !self.stdin.is_closed()
    }

    /// Queue a line for the agent's stdin (TS `stdin.write`).
    pub(super) fn write(&self, value: &Value) -> bool {
        self.stdin.send(Outbound { line: line(value) }).is_ok()
    }

    /// A side-channel answer: dropped once the agent is gone.
    pub(super) fn reply(&self, value: Value) {
        if self.writable() {
            self.write(&value);
        }
    }

    pub(super) fn publish(&self, kind: &str, data: Value) {
        if let Some(node) = self.node() {
            node.events
                .publish(&self.session_id, self.epoch, kind, data);
        }
    }

    /// `db.updateRun`, then the activity change.
    pub(super) fn update_run(
        &self,
        node: &Node,
        run_id: &str,
        status: RunStatus,
        reason: Option<&str>,
    ) -> ApiResult<()> {
        node.db.lock().update_run(run_id, status, reason)?;
        node.activity.notify_one();
        Ok(())
    }

    /// The current run moves to `status` (when there is one).
    pub(super) fn update_current_run(&self, status: RunStatus) -> ApiResult<()> {
        let run = self.lock().current_run.clone();
        match (run, self.node()) {
            (Some(run), Some(node)) => self.update_run(&node, &run, status, None),
            _ => Ok(()),
        }
    }

    /// A runner with no agent process and no node, for tests of its side
    /// channels: its stdin lines (the agent's replies) come out of the
    /// receiver.
    #[cfg(test)]
    pub(super) fn detached(
        session_id: &str,
        workspace: Workspace,
        prepared: Prepared,
    ) -> (Arc<Self>, mpsc::UnboundedReceiver<Outbound>) {
        let (stdin, lines) = mpsc::unbounded_channel();
        let runner = Arc::new(Self {
            node: WeakNode::new(),
            session_id: session_id.to_owned(),
            workspace,
            mode: pirc_protocol::mode::default_work(),
            epoch: 1,
            pid: None,
            prepared,
            persistence: None,
            inference: None,
            launch: None,
            stdin,
            inner: Mutex::default(),
            view: Mutex::default(),
            reaped: AtomicBool::new(true),
            exited: watch::channel(false).0,
        });
        (runner, lines)
    }

    pub fn set_run(&self, run_id: &str) {
        self.lock().current_run = Some(run_id.to_owned());
    }

    /// Send an RPC command (`{type, ...}`, without `id`) and wait for its
    /// `response` line (no timeout, as TS). 503 `runner_unavailable`
    /// "Runner is not available" when the process is gone, or "Runner
    /// exited (...)" when it exits first.
    pub async fn request(&self, command: Map<String, Value>) -> ApiResult<Map<String, Value>> {
        let answer = if matches!(
            command.get("type").and_then(Value::as_str),
            Some("abort" | "clear_queue" | "get_state" | "get_panel_state")
        ) {
            self.send_request(command)?
        } else {
            let node = self.node().ok_or_else(runner_unavailable)?;
            let db = node.db.lock();
            crate::execution_fences::require_open(&db, &self.session_id)?;
            self.send_request(command)?
        };
        answer.await.unwrap_or_else(|_| Err(runner_unavailable()))
    }

    /// The first half of [`Runner::request`]: the line is queued now, in
    /// order with every other line (TS wrote synchronously).
    pub(super) fn send_request(
        &self,
        mut command: Map<String, Value>,
    ) -> ApiResult<oneshot::Receiver<ApiResult<Map<String, Value>>>> {
        let request_id = prefix_uuid("rpc");
        let answer = {
            let mut inner = self.lock();
            if inner.closed || self.stdin.is_closed() {
                return Err(runner_unavailable());
            }
            let (waiter, answer) = oneshot::channel();
            inner.pending.insert(request_id.clone(), waiter);
            answer
        };
        command.insert("id".to_owned(), Value::String(request_id.clone()));
        if !self.write(&Value::Object(command)) {
            self.lock().pending.remove(&request_id);
            return Err(runner_unavailable());
        }
        Ok(answer)
    }

    /// `answer`: a node dialog is resolved here, anything else goes to the
    /// agent as `extension_ui_response`; the run is running again.
    /// `interaction_answered` is published before the answer is handed on:
    /// the writer task may give the line to the agent at once, and TS's
    /// order (the event before anything the agent does next) must hold on
    /// a multi-threaded runtime too.
    pub(super) async fn answer(
        &self,
        rpc_id: &str,
        interaction_id: &str,
        answer: &Map<String, Value>,
    ) -> ApiResult<()> {
        let answered = || {
            self.publish(
                "interaction_answered",
                json!({ "interactionId": interaction_id, "interactionEpoch": self.epoch }),
            );
        };
        let dialog = self.lock().node_dialogs.remove(rpc_id);
        if let Some(dialog) = dialog {
            answered();
            let _ = dialog.send(answer.get("confirmed") == Some(&Value::Bool(true)));
            return self.update_current_run(RunStatus::Running);
        }
        if !self.writable() {
            return Err(runner_unavailable());
        }
        let mut response = Map::new();
        response.insert("type".into(), json!("extension_ui_response"));
        response.insert("id".into(), json!(rpc_id));
        for (key, value) in answer {
            response.insert(key.clone(), value.clone());
        }
        // The interaction is already claimed: a write failing after this
        // (stdin closed in between) changes nothing that matters.
        answered();
        if !self.write(&Value::Object(response)) {
            return Err(runner_unavailable());
        }
        self.update_current_run(RunStatus::Running)
    }

    /// Signal srt with the agent and everything under it.
    pub(super) fn kill(&self, signal: Signal) {
        if signal == Signal::SIGKILL {
            self.prepared.terminate_processes();
        }
        // Once a native wrapper was reaped, its numeric PGID can be reused.
        // Retire the captured namespace handle above, never signal that stale
        // group. Missing capture remains unconfirmed; it is not a safe PID.
        if self.reaped.load(Ordering::Acquire)
            && self.prepared.process_scope_state() != crate::sandbox::processes::State::Unsupported
        {
            return;
        }
        if let Some(pid) = self.pid.and_then(|pid| i32::try_from(pid).ok()) {
            if killpg(Pid::from_raw(pid), signal).is_ok() {
                return;
            }
            // The bare pid only while the agent is unreaped: afterwards it
            // may be an unrelated process's (TS's `child.kill()` was a
            // no-op once Node had seen the exit).
            if !self.reaped.load(Ordering::Acquire) {
                let _ = kill(Pid::from_raw(pid), signal);
            }
        }
    }

    /// `fail`: report the error and kill the agent (its exit follows).
    pub(super) fn fail(&self, message: &str) {
        if !self.lock().closed {
            self.publish("runner_error", json!({ "message": message }));
            self.kill(Signal::SIGKILL);
        }
    }

    /// `stop(grace)`: ask the agent to abort, then SIGTERM, SIGKILL after
    /// `grace`, and give up waiting after twice `grace`. Once the agent is
    /// gone, returns only after its `exit` ran to its end (TS resolved on
    /// the child's `exit` event, after the runner's own teardown), so the
    /// caller never races the exit's bookkeeping.
    pub(super) async fn stop(&self, grace: Duration) {
        self.cancel_sandbox_requests();
        let mut exited = self.exited.subscribe();
        if !self.lock().closed {
            let mut abort = Map::new();
            abort.insert("type".into(), json!("abort"));
            let _ = tokio::time::timeout(grace, self.request(abort)).await;
            if !self.lock().closed {
                self.kill(Signal::SIGTERM);
            }
            let waited = tokio::time::timeout(grace, exited.wait_for(|exited| *exited))
                .await
                .is_ok();
            if !waited {
                if !self.lock().closed {
                    self.kill(Signal::SIGKILL);
                }
                let _ = tokio::time::timeout(grace, exited.wait_for(|exited| *exited)).await;
            }
        }
        // An exit under way (`closed` is its first step) is synchronous and
        // short: wait for its end.
        if self.lock().closed {
            let _ = exited.wait_for(|exited| *exited).await;
        }
    }

    /// A node dialog is withdrawn (unanswered in time, cancelled by the
    /// agent, or the runner stopped): the interaction is cancelled and the
    /// asker hears no.
    pub(super) fn withdraw(&self, rpc_id: &str) {
        let Some(dialog) = self.lock().node_dialogs.remove(rpc_id) else {
            return;
        };
        if let Some(node) = self.node() {
            let cancelled =
                node.db
                    .lock()
                    .cancel_interaction_by_rpc_id(&self.session_id, self.epoch, rpc_id);
            if let Ok(Some(interaction)) = cancelled {
                self.publish(
                    "interaction_answered",
                    json!({ "interactionId": interaction, "interactionEpoch": self.epoch, "cancelled": true }),
                );
                let _ = self.update_current_run(RunStatus::Running);
            }
        }
        let _ = dialog.send(false);
    }

    /// `controller.abort()` of a side request.
    pub(super) fn abort_side(&self, request: SideRequest) {
        if let Some(dialog) = &request.dialog {
            self.withdraw(dialog);
        }
        request.abort.send_replace(true);
    }

    pub(super) fn cancel_sandbox_requests(&self) {
        let requests = std::mem::take(&mut self.lock().sandbox_requests);
        for (_, request) in requests {
            self.abort_side(request);
        }
        if let Some(node) = self.node() {
            node.host_commands
                .cancel_epoch(&self.session_id, self.epoch);
        }
    }

    /// `exit(code, signal)`, once.
    fn exit(&self, code: Option<i32>, signal: Option<String>) {
        let (pending, browser, sandbox, dialogs, run) = {
            let mut inner = self.lock();
            if inner.closed {
                return;
            }
            inner.closed = true;
            (
                std::mem::take(&mut inner.pending),
                std::mem::take(&mut inner.browser_requests),
                std::mem::take(&mut inner.sandbox_requests),
                inner.node_dialogs.keys().cloned().collect::<Vec<_>>(),
                inner.current_run.clone(),
            )
        };
        // `ensure` and `stop` wait for this: it must come even if a step
        // below panics.
        let _exited = Exited(&self.exited);
        if let Some(lease) = &self.inference {
            lease.close();
        }
        if let Some(lease) = &self.persistence {
            lease.close();
        }
        // Whatever the agent left in its group (a busy ptc script process
        // after a crash, which cannot notice its parent is gone) goes with it.
        self.kill(Signal::SIGKILL);
        let reason = signal
            .clone()
            .or_else(|| code.map(|code| code.to_string()))
            .unwrap_or_else(|| "unknown".to_owned());
        let error = ApiError::runner_unavailable(format!("Runner exited ({reason})"));
        for (_, waiter) in pending {
            let _ = waiter.send(Err(error.clone()));
        }
        for (_, request) in browser {
            if let Some(task) = &request.task {
                task.abort();
            }
            request.abort.send_replace(true);
        }
        if let Some(node) = self.node() {
            node.host_commands
                .cancel_epoch(&self.session_id, self.epoch);
        }
        for (_, request) in sandbox {
            self.abort_side(request);
        }
        for dialog in dialogs {
            self.withdraw(&dialog);
        }
        let process_snapshot = self.prepared.process_snapshot();
        self.prepared.cleanup();
        if let Some(node) = self.node() {
            if let Some(launch) = &self.launch
                && let Err(error) =
                    crate::process_journal::observe(&node.db.lock(), launch, &process_snapshot)
            {
                crate::log::error(&format!(
                    "cannot save sandbox exit evidence: {}",
                    error.message
                ));
            }
            if let Some(capture) = &node.checkpoints {
                capture.seal(self.session_id.clone(), self.epoch, None, true);
            }
            let db = node.db.lock();
            let result = db
                .mark_dispatched_unknown(&self.session_id, &error.message)
                .and_then(|_| match &run {
                    Some(run) => db.update_run(run, RunStatus::Interrupted, Some(&error.message)),
                    None => Ok(()),
                })
                .and_then(|()| db.set_runner_state(&self.session_id, RunnerState::Failed));
            drop(db);
            if let Err(error) = result {
                crate::log::error(&format!("runner exit bookkeeping failed: {error}"));
            }
            node.activity.notify_one();
            self.publish("runner_exit", json!({ "code": code, "signal": signal }));
            node.runners.exited(self);
        }
    }

    /// `handleValue`: one line from the agent. An `Err` is fatal (TS threw
    /// out of the parser and the runner was killed).
    fn handle_value(self: &Arc<Self>, value: Value) -> Result<(), String> {
        let Value::Object(mut message) = value else {
            return Err("RPC emitted a non-object JSON value".to_owned());
        };
        let Some(node) = self.node() else {
            return Ok(());
        };
        let kind = message
            .get("type")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned();
        if kind == "response"
            && let Some(Value::String(id)) = message.get("id")
        {
            let waiter = self.lock().pending.remove(id);
            if let Some(waiter) = waiter {
                let _ = waiter.send(Ok(message));
                return Ok(());
            }
        }
        if kind == "extension_ui_request" {
            let node_dialog = |key: &str| {
                message
                    .get(key)
                    .and_then(Value::as_str)
                    .is_some_and(|id| id.starts_with(NODE_DIALOG_PREFIX))
            };
            // Only the node opens or cancels its own dialogs.
            if node_dialog("id") || node_dialog("targetId") {
                return Ok(());
            }
            let method = message
                .get("method")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned();
            if DIALOG_METHODS.contains(&method.as_str())
                && let Some(Value::String(id)) = message.get("id")
            {
                let id = id.clone();
                // The operation a dialog names is a display link only: keep it
                // only when it is one of this agent's running ptc operations.
                if message.contains_key("toolCallId") {
                    match self.running_operation(message.get("toolCallId")) {
                        Some(link) => {
                            message.insert("toolCallId".into(), Value::String(link));
                        }
                        None => {
                            message.shift_remove("toolCallId");
                        }
                    }
                }
                // The agent's number: `as` saturates, and the sum saturates
                // too (TS added floats; a huge timeout never expires).
                let timeout = match message.get("timeout").and_then(Value::as_f64) {
                    Some(timeout) if timeout > 0.0 => timeout as i64,
                    _ => i64::try_from(node.config.interaction_ttl_ms).unwrap_or(i64::MAX),
                };
                let interaction = node
                    .db
                    .lock()
                    .create_interaction(
                        &self.session_id,
                        self.epoch,
                        &id,
                        &method,
                        &message,
                        now_ms().saturating_add(timeout),
                    )
                    .map_err(thrown)?;
                self.publish(
                    "interaction_created",
                    serde_json::to_value(&interaction).unwrap_or_default(),
                );
                self.update_current_run(RunStatus::WaitingInput)
                    .map_err(thrown)?;
            } else if method == "cancel"
                && let Some(Value::String(target)) = message.get("targetId")
            {
                let cancelled = node
                    .db
                    .lock()
                    .cancel_interaction_by_rpc_id(&self.session_id, self.epoch, target)
                    .map_err(thrown)?;
                if let Some(interaction) = cancelled {
                    self.publish(
                        "interaction_answered",
                        json!({ "interactionId": interaction, "interactionEpoch": self.epoch, "cancelled": true }),
                    );
                    self.update_current_run(RunStatus::Running)
                        .map_err(thrown)?;
                }
                return Ok(());
            } else {
                self.publish("notification", Value::Object(message.clone()));
            }
        }
        match kind.as_str() {
            "write_lease_request" => return self.grant_write(&node, &message),
            "gateway_request" => {
                self.forward_gateway(&message);
                return Ok(());
            }
            "browser_request" => return self.handle_browser(&message),
            "browser_cancel" => {
                self.cancel_browser(&message);
                return Ok(());
            }
            "sandbox_request" => return self.handle_sandbox(&message),
            "sandbox_cancel" => {
                if let Some(Value::String(id)) = message.get("id") {
                    let request = self.lock().sandbox_requests.remove(id);
                    if let Some(request) = request {
                        self.abort_side(request);
                    }
                }
                return Ok(());
            }
            "session_name_changed" => {
                return crate::app::apply_session_name(
                    &node,
                    &self.session_id,
                    self.epoch,
                    &Value::Object(message),
                )
                .map_err(thrown);
            }
            _ => {}
        }
        self.lock().state.reduce(&message);
        self.bookkeeping(&node, &kind, &message).map_err(thrown)?;
        self.publish("pi_event", Value::Object(message));
        Ok(())
    }

    /// Runs follow the agent's events; only the final assistant turn decides
    /// how a run ends (a retried or recovered error must not leave it failed).
    fn bookkeeping(&self, node: &Node, kind: &str, message: &Map<String, Value>) -> ApiResult<()> {
        match kind {
            "agent_start" => {
                let run = self.lock().current_run.clone();
                let run = match run {
                    Some(run) => run,
                    None => {
                        let run = node.db.lock().create_run(&self.session_id)?;
                        node.activity.notify_one();
                        self.lock().current_run = Some(run.clone());
                        run
                    }
                };
                self.lock().run_error = None;
                if let Some(capture) = &node.checkpoints
                    && capture.enabled(&self.workspace.id)
                    && self.mode.workdir == pirc_protocol::mode::Workdir::Workspace
                    && let Err(error) = capture.start(node, self)
                {
                    crate::log::error(&error);
                }
                self.update_run(node, &run, RunStatus::Running, None)
            }
            "tool_execution_start" => {
                let tool = message
                    .get("toolName")
                    .and_then(Value::as_str)
                    .unwrap_or("unknown_tool");
                if !matches!(tool, "write" | "edit" | "read" | "ls" | "find" | "grep")
                    && let Some(capture) = &node.checkpoints
                    && capture.enabled(&self.workspace.id)
                    && self.mode.workdir == pirc_protocol::mode::Workdir::Workspace
                    && let Err(error) = capture.note(node, self, tool)
                {
                    crate::log::error(&error);
                }
                Ok(())
            }
            "agent_settled" => {
                let (run, error) = {
                    let mut inner = self.lock();
                    (inner.current_run.take(), inner.run_error.take())
                };
                if let Some(run) = run {
                    if let Some(capture) = &node.checkpoints {
                        capture.seal(
                            self.session_id.clone(),
                            self.epoch,
                            Some(run.clone()),
                            false,
                        );
                    }
                    let status = if error.is_none() {
                        RunStatus::Succeeded
                    } else {
                        RunStatus::Failed
                    };
                    self.update_run(node, &run, status, error.as_deref())?;
                }
                node.writes.release(&self.session_id);
                Ok(())
            }
            "message_end"
                if message
                    .get("message")
                    .and_then(|message| message.get("role"))
                    .and_then(Value::as_str)
                    == Some("assistant") =>
            {
                let message = &message["message"];
                let error = (message.get("stopReason").and_then(Value::as_str) == Some("error"))
                    .then(|| match message.get("errorMessage") {
                        None | Some(Value::Null) => "The agent reported an error".to_owned(),
                        Some(text) => super::reducer::js_string(Some(text)),
                    });
                let run = {
                    let mut inner = self.lock();
                    inner.run_error = error.clone();
                    inner.current_run.clone()
                };
                match (error, run) {
                    (Some(error), Some(run)) => {
                        self.update_run(node, &run, RunStatus::Failed, Some(&error))
                    }
                    _ => Ok(()),
                }
            }
            "agent_error" => {
                // The agent loop itself failed; the run ends with agent_settled.
                let error = match message.get("error") {
                    Some(Value::String(error)) => error.clone(),
                    _ => "The agent loop crashed".to_owned(),
                };
                let run = {
                    let mut inner = self.lock();
                    inner.run_error = Some(error.clone());
                    inner.current_run.clone()
                };
                match run {
                    Some(run) => self.update_run(node, &run, RunStatus::Failed, Some(&error)),
                    None => Ok(()),
                }
            }
            "auto_retry_start" => self.update_current_run(RunStatus::Running),
            _ => Ok(()),
        }
    }

    /// `runningOperation(id)`: `id` when it names a ptc operation of this
    /// agent that is still running.
    pub(super) fn running_operation(&self, id: Option<&Value>) -> Option<String> {
        let id = id?.as_str()?;
        let valid = (1..=100).contains(&id.len())
            && id
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | ':' | '.' | '-'));
        (valid
            && self
                .lock()
                .state
                .operations
                .iter()
                .any(|operation| operation.tool_call_id == id))
        .then(|| id.to_owned())
    }
}

/// `sessionRoot` with a reason for the agent.
pub(super) fn session_root(
    workspace: &Workspace,
    session_id: &str,
    mode: &pirc_protocol::Mode,
) -> ApiResult<PathBuf> {
    crate::chat::session_root(workspace, session_id, mode)
}

/// Everything a runner is spawned from.
pub(super) struct Spawn {
    pub session: SessionRow,
    pub workspace: Workspace,
    pub mode: pirc_protocol::Mode,
    pub prepared: Prepared,
    /// The workspace-memory ledger the node chose (directory workspaces):
    /// the agent is told its key, and its sandbox opens only that file.
    pub ledger: Option<WorkspaceLedger>,
}

/// `new PiRunner(...)`: spawn the agent and wire its pipes. The runner is
/// ready for requests when this returns; its lines are handled from then on.
/// The agent's process in its sandbox, and its epoch.
fn spawn_child(
    node: &Node,
    session: &SessionRow,
    workspace: &Workspace,
    mode: &pirc_protocol::Mode,
    prepared: &Prepared,
    ledger: Option<&WorkspaceLedger>,
) -> ApiResult<(tokio::process::Child, i64, crate::process_journal::Launch)> {
    let (epoch, trust) = {
        let db = node.db.lock();
        crate::execution_fences::require_open(&db, &session.id)?;
        let epoch = db.increment_epoch(&session.id)?;
        db.stale_epoch_interactions(&session.id, epoch)?;
        let trust = if mode.project_config {
            db.get_workspace_trust(&workspace.id)?
        } else {
            None
        };
        (epoch, trust.unwrap_or_default())
    };
    let root = session_root(workspace, &session.id, mode)?;
    let mut command = prepared.command().map_err(|error| {
        ApiError::runner_unavailable(format!("Runner is not available: {error}"))
    })?;
    command.args([
        "--mode",
        "rpc",
        "--session-dir",
        &session.private_session_path,
    ]);
    if session.pi_session_id.is_some() {
        command.arg("--continue");
    }
    // The node token must not reach the agent: its tools and shells run
    // whatever the model asks.
    let mut env = without_secrets(&node.env, &[]);
    env.remove("PIRC_WORKSPACE_KIND");
    let mut set = |name: &str, value: String| {
        env.insert(name.to_owned(), value);
    };
    set(
        "PI_CODING_AGENT_SESSION_DIR",
        session.private_session_path.clone(),
    );
    // Ask this node for a write lease before file-tool writes.
    set("PIRC_WRITE_BROKER", "1".into());
    // Allowlisted operations on the gateway go through this node.
    set("PIRC_GATEWAY", "1".into());
    // `chat` makes the agent a personal assistant (see chat.rs).
    set(
        "PIRC_MODE",
        serde_json::to_string(mode).map_err(|_| ApiError::internal())?,
    );
    // The project config hash the user trusted; the agent ignores
    // .pirc/config.json hooks, env and allowedPaths unless they still match.
    set("PIRC_PROJECT_TRUST", trust);
    set(
        "PIRC_WORKSPACE_MEMORY_DIR",
        node.config
            .workspace_memory_dir
            .to_string_lossy()
            .into_owned(),
    );
    // Only when the sandbox opened it (the node may have refused a planted
    // file): without the key the agent asks git, and its sandbox refuses.
    let opened = |ledger: &&WorkspaceLedger| {
        let file = pirc_policy::real_resolve(&ledger.file.to_string_lossy());
        prepared.policy.paths.allow_write.contains(&file)
    };
    if let Some(ledger) = ledger.filter(opened) {
        set("PIRC_WORKSPACE_MEMORY_KEY", ledger.key.clone());
        set("PIRC_WORKSPACE_MEMORY_ROOT", ledger.root.clone());
    }
    set(
        "PIRC_BROWSER",
        if node.browser.enabled() { "1" } else { "0" }.into(),
    );
    // This node answers sandbox_request; the file tools mirror the policy.
    set("PIRC_SANDBOX", "srt".into());
    set(
        "PIRC_SANDBOX_POLICY",
        serde_json::to_string(&prepared.policy.paths).unwrap_or_default(),
    );
    for (name, value) in &prepared.env {
        set(name, value.clone());
    }
    // Forced after repository env. Old/standalone agents and team children do
    // not gain a new capture channel merely by inheriting the node's config.
    set(
        "PIRC_CHECKPOINT_CAPTURE",
        if node
            .checkpoints
            .as_ref()
            .is_some_and(|c| c.enabled(&workspace.id))
            && mode.workdir == pirc_protocol::mode::Workdir::Workspace
        {
            "1"
        } else {
            "0"
        }
        .into(),
    );
    // Repository env must never override the gateway's mode policy.
    set(
        "PIRC_MODE",
        serde_json::to_string(mode).map_err(|_| ApiError::internal())?,
    );
    // Only native process-tracked launchers understand this trusted bridge gate.
    // Forced after all repository/prepared environment values.
    env.remove(crate::sandbox::launch_guard::ENV);
    if prepared.requires_launch_guard() {
        crate::sandbox::launch_guard::validate_bootstrap(&env)
            .map_err(|error| ApiError::runner_unavailable(error.to_string()))?;
        env.insert(crate::sandbox::launch_guard::ENV.into(), "1".into());
    }
    command
        .current_dir(&root)
        .env_clear()
        .envs(&env)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        // Its own process group, so stopping srt also stops what it sandboxes.
        .process_group(0)
        .kill_on_drop(prepared.requires_launch_guard());
    // Serialize the final spawn with transition acceptance. A start that waited
    // for sandbox preparation cannot spawn behind a durable admission fence.
    let db = node.db.lock();
    db.require_session_available(&session.id)?;
    crate::execution_fences::require_open(&db, &session.id)?;
    let launch = crate::process_journal::reserve_with_guard(
        &db,
        &session.id,
        &workspace.id,
        epoch,
        &node.incarnation,
        prepared.requires_launch_guard(),
    )?;
    let child = match command.spawn() {
        Ok(child) => child,
        Err(error) => {
            // A durable reservation is required before spawn. Only an actual
            // spawn error establishes that no process started in this attempt.
            crate::process_journal::not_started(&db, &launch)?;
            return Err(ApiError::runner_unavailable(format!(
                "Runner is not available: {error}"
            )));
        }
    };
    drop(db);
    if let Some(pid) = child.id() {
        prepared.process_spawned(pid);
    }
    Ok((child, epoch, launch))
}

pub(super) async fn spawn(node: &Node, spawn: Spawn) -> ApiResult<Arc<Runner>> {
    let Spawn {
        session,
        workspace,
        mode,
        prepared,
        ledger,
    } = spawn;
    let persistence = if node
        .config
        .agent_args
        .first()
        .is_some_and(|arg| arg == "agent")
    {
        Some(
            node.inference
                .persistence(
                    std::path::Path::new(&session.private_session_path),
                    ledger.as_ref().map(|l| l.file.as_path()),
                )
                .map_err(|_| ApiError::internal())?,
        )
    } else {
        None
    };
    let (mut child, epoch, launch) = match spawn_child(
        node,
        &session,
        &workspace,
        &mode,
        &prepared,
        ledger.as_ref(),
    ) {
        Ok(spawned) => spawned,
        Err(error) => {
            prepared.cleanup();
            return Err(error);
        }
    };
    if prepared.requires_launch_guard()
        && let Err(error) =
            release_guarded_launch(node, &prepared, &launch, &workspace, &mode, &mut child).await
    {
        // Closing stdin refuses the bridge even if PID observation failed. Kill
        // the trusted wrapper too; no agent RPC/configuration has been sent.
        let _ = crate::process_journal::deny(&node.db.lock(), &launch);
        child.stdin.take();
        prepared.terminate_processes();
        let _ = child.start_kill();
        let _ = tokio::time::timeout(Duration::from_secs(2), child.wait()).await;
        let _ =
            crate::process_journal::observe(&node.db.lock(), &launch, &prepared.process_snapshot());
        prepared.cleanup();
        return Err(error);
    }
    let pid = child.id();
    let (stdin_tx, stdin_rx) = mpsc::unbounded_channel();
    let (exited, _) = watch::channel(false);
    let runner = Arc::new(Runner {
        node: Arc::downgrade(node),
        session_id: session.id.clone(),
        workspace: workspace.clone(),
        mode: mode.clone(),
        epoch,
        pid,
        prepared,
        persistence,
        launch: Some(launch),
        inference: node
            .inference
            .runner(&session.id, &workspace.id, epoch, &mode),
        stdin: stdin_tx,
        inner: Mutex::default(),
        view: Mutex::default(),
        reaped: AtomicBool::new(false),
        exited,
    });
    tokio::spawn(observe_process_scope(runner.clone()));
    if let Some(stdin) = child.stdin.take() {
        tokio::spawn(write_stdin(stdin, stdin_rx));
    }
    // Public catalog + node-local inference transport; no provider credentials.
    let mut configure = Map::new();
    configure.insert("type".into(), json!("configure"));
    if let Some(lease) = &runner.persistence {
        configure.insert("persistence".into(), json!(lease.config));
    }
    let mut models = node.models.current();
    models.inference = runner.inference.as_ref().map(|lease| lease.config.clone());
    configure.insert(
        "models".into(),
        serde_json::to_value(models).unwrap_or_default(),
    );
    runner.write(&Value::Object(configure));

    // The agent runs: from here on a store failure is logged, not a failed start.
    if let Err(error) = node
        .db
        .lock()
        .set_runner_state(&session.id, RunnerState::Ready)
    {
        crate::log::error(&format!("runner start: {error}"));
    }
    runner.publish("runner_ready", json!({ "sandbox": { "active": true } }));
    // In the timeline, and in the snapshot for clients that connect later.
    for warning in &runner.prepared.warnings {
        let notice = json!({
            "type": "extension_ui_request",
            "id": format!("{NODE_DIALOG_PREFIX}notice-{}", uuid()),
            "method": "notify",
            "message": warning,
            "notifyType": "warning",
        });
        let _view = runner.view();
        if let Value::Object(notice) = &notice {
            runner.lock().state.reduce(notice);
        }
        runner.publish("notification", notice);
    }
    // A user-chosen name stops the agent from generating one. Written before
    // any prompt, so the agent sees it first.
    let current = node.db.lock().get_session(&session.id);
    if let Ok(current) = current
        && current.name_source == crate::store::NameSource::User
    {
        let mut rename = Map::new();
        rename.insert("type".into(), json!("set_session_name"));
        rename.insert("name".into(), json!(current.name));
        // Queued now, before any prompt; the answer does not matter.
        let _ = runner.send_request(rename);
    }
    let mut get_state = Map::new();
    get_state.insert("type".into(), json!("get_state"));
    let state = runner.send_request(get_state);
    let asking = runner.clone();
    tokio::spawn(async move {
        if let Ok(state) = state
            && let Ok(Ok(response)) = state.await
            && response.get("success") == Some(&Value::Bool(true))
            && let Some(Value::String(pi)) =
                response.get("data").and_then(|data| data.get("sessionId"))
            && !pi.is_empty()
            && let Some(node) = asking.node()
        {
            let _ = node.db.lock().set_pi_session(&asking.session_id, Some(pi));
        }
    });
    let stdout = child.stdout.take();
    let stderr = child.stderr.take();
    let max_line = node.config.rpc_max_line_bytes;
    let reading = tokio::spawn(read_stdout(runner.clone(), stdout, max_line));
    let errors = stderr.map(|stderr| tokio::spawn(read_stderr(runner.clone(), stderr)));
    tokio::spawn(wait_exit(runner.clone(), child, reading, errors));
    Ok(runner)
}

async fn release_guarded_launch(
    node: &Node,
    prepared: &Prepared,
    launch: &crate::process_journal::Launch,
    workspace: &Workspace,
    mode: &pirc_protocol::Mode,
    child: &mut tokio::process::Child,
) -> ApiResult<()> {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(6);
    loop {
        if node.closing() {
            return Err(ApiError::runner_unavailable("Node is shutting down"));
        }
        {
            let db = node.db.lock();
            db.require_session_available(&launch.session)?;
            crate::execution_fences::require_open(&db, &launch.session)?;
        }
        let snapshot = prepared.process_snapshot();
        match snapshot.state {
            crate::sandbox::processes::State::Observing
                if tokio::time::Instant::now() < deadline =>
            {
                if child
                    .try_wait()
                    .map_err(|_| ApiError::runner_unavailable("Sandbox startup wait failed"))?
                    .is_some()
                {
                    return Err(ApiError::runner_unavailable(
                        "Sandbox exited before launch permission",
                    ));
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
            _ => {
                let db = node.db.lock();
                let current = db.get_workspace(&workspace.id)?;
                if current.canonical_path != workspace.canonical_path
                    || node.workspace_mode(&current)? != *mode
                {
                    return Err(ApiError::runner_unavailable(
                        "Workspace or mode changed while waiting for launch permission",
                    ));
                }
                crate::process_journal::authorize(&db, launch, &workspace.id, &snapshot)?;
                let stdin = child.stdin.as_ref().ok_or_else(|| {
                    ApiError::runner_unavailable("Sandbox launch pipe is unavailable")
                })?;
                crate::sandbox::launch_guard::release(stdin).map_err(|_| {
                    ApiError::runner_unavailable("Sandbox launch permission was not delivered")
                })?;
                return Ok(());
            }
        }
    }
}

async fn observe_process_scope(runner: Arc<Runner>) {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(6);
    loop {
        let snapshot = runner.prepared.process_snapshot();
        if snapshot.state != crate::sandbox::processes::State::Observing
            || tokio::time::Instant::now() >= deadline
            || !runner.alive()
        {
            if let (Some(node), Some(launch)) = (runner.node(), &runner.launch)
                && let Err(error) =
                    crate::process_journal::observe(&node.db.lock(), launch, &snapshot)
            {
                crate::log::error(&format!(
                    "cannot save sandbox launch evidence: {}",
                    error.message
                ));
            }
            return;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
}

async fn write_stdin(
    mut stdin: tokio::process::ChildStdin,
    mut lines: mpsc::UnboundedReceiver<Outbound>,
) {
    while let Some(outbound) = lines.recv().await {
        if stdin.write_all(outbound.line.as_bytes()).await.is_err() {
            // `stdin.writable` is false from now on.
            lines.close();
            return;
        }
    }
}

async fn read_stdout(
    runner: Arc<Runner>,
    stdout: Option<tokio::process::ChildStdout>,
    max_line_bytes: usize,
) {
    let Some(mut stdout) = stdout else {
        return;
    };
    let mut parser = JsonlParser::new(max_line_bytes);
    let mut buffer = vec![0; 64 * 1024];
    loop {
        let read = match stdout.read(&mut buffer).await {
            Ok(0) | Err(_) => break,
            Ok(read) => read,
        };
        let handled = parser.push(&buffer[..read], |value| {
            // One line at a time, as one step for snapshots (see `view`).
            let _view = runner.view();
            runner.handle_value(value)
        });
        if let Err(error) = handled {
            // Fatal: the agent is killed. Lines it still writes are not read.
            runner.fail(&error);
            return;
        }
    }
    if let Err(error) = parser.end() {
        runner.fail(&error);
    }
}

async fn read_stderr(runner: Arc<Runner>, mut stderr: tokio::process::ChildStderr) {
    let mut buffer = vec![0; 64 * 1024];
    loop {
        match stderr.read(&mut buffer).await {
            Ok(0) | Err(_) => return,
            Ok(read) => {
                let text = String::from_utf8_lossy(&buffer[..read]);
                runner.publish("runner_stderr", json!({ "text": head16(&text, 8192) }));
            }
        }
    }
}

/// The agent exited: its group is killed, then its last stdout lines are
/// handled (up to a second), then the exit (TS's `exit` event could come
/// before the last `data`; here the lines always come first). The readers
/// are then stopped: a process outside the group holding the pipes open
/// must not feed lines in after `runner_exit`.
async fn wait_exit(
    runner: Arc<Runner>,
    mut child: tokio::process::Child,
    mut reading: tokio::task::JoinHandle<()>,
    mut errors: Option<tokio::task::JoinHandle<()>>,
) {
    use std::os::unix::process::ExitStatusExt;
    let status = child.wait().await;
    // Reaped (or `wait` failed: then no bare-pid signal either, the safe side).
    runner.reaped.store(true, Ordering::Release);
    runner.kill(Signal::SIGKILL);
    // A wrapper's exit is not evidence of descendant exit. Native Linux uses
    // the independently captured PID namespace init handle, including children
    // that left the wrapper's process group. Unknown stays unknown.
    let _ = runner.prepared.wait_processes(Duration::from_secs(2)).await;
    let drained = tokio::time::Instant::now() + Duration::from_secs(1);
    let readers = std::iter::once(&mut reading).chain(errors.as_mut());
    for reader in readers {
        if tokio::time::timeout_at(drained, &mut *reader)
            .await
            .is_err()
        {
            // Cancelled at its next read, never inside a line; awaited, so
            // nothing is handled once the exit starts.
            reader.abort();
            let _ = reader.await;
        }
    }
    let (code, signal) = match status {
        Ok(status) => (
            status.code(),
            status.signal().map(|signal| {
                Signal::try_from(signal)
                    .map(|signal| signal.as_str().to_owned())
                    .unwrap_or_else(|_| signal.to_string())
            }),
        ),
        Err(_) => (None, None),
    };
    runner.exit(code, signal);
}

#[cfg(test)]
mod memory_concurrency_tests {
    use super::*;
    use crate::workspace_memory::{self as memory, tests::Fixture};

    pub(super) fn register(f: &Fixture, row: SessionRow) -> Arc<Runner> {
        let runner = Arc::new(Runner {
            node: Arc::downgrade(&f.node),
            session_id: row.id.clone(),
            workspace: f.node.db.lock().get_workspace(&row.workspace_id).unwrap(),
            mode: f.mode.clone(),
            epoch: row.runner_epoch,
            pid: None,
            prepared: Prepared::new(
                PathBuf::new(),
                vec![],
                vec![],
                Default::default(),
                vec![],
                None,
                || {},
            ),
            persistence: None,
            inference: None,
            launch: None,
            stdin: mpsc::unbounded_channel().0,
            inner: Mutex::default(),
            view: Mutex::default(),
            reaped: AtomicBool::new(true),
            exited: watch::channel(false).0,
        });
        f.node.runners.lock().runners.insert(row.id, runner.clone());
        runner
    }

    #[tokio::test]
    async fn concurrent_cold_cutovers_refuse_peer_writers_without_locking_each_other() {
        let f = Fixture::new().await;
        let second = f.dir.with_file_name("peer");
        pirc_agent::session_store::SessionStore::open(second.clone(), "/").unwrap();
        let first = f.node.db.lock().get_session(&f.current).unwrap();
        let second = f
            .node
            .db
            .lock()
            .create_session("repo", second.to_str().unwrap(), "alice")
            .unwrap();
        let rows = [first, second];
        let runners = rows
            .into_iter()
            .map(|row| register(&f, row))
            .collect::<Vec<_>>();
        let barrier = Arc::new(std::sync::Barrier::new(2));
        let (send, receive) = std::sync::mpsc::channel();
        let mut threads = vec![];
        for runner in &runners {
            let runner = runner.clone();
            let node = f.node.clone();
            let barrier = barrier.clone();
            let send = send.clone();
            threads.push(std::thread::spawn(move || {
                let held = runner.lock();
                // Both requests hold their own actual lifecycle mutex, exactly
                // as memory_operation does before executing the host operation.
                barrier.wait();
                let scope =
                    memory::scope(&node, &runner.session_id, &runner.mode, 0, true).unwrap();
                let view = memory::View::new(&node, &scope, true).unwrap();
                let result = memory::execute(
                    &view,
                    "workspace.cold",
                    &json!({"jobId":format!("cold_{}",runner.session_id),"writersStopped":true}),
                );
                send.send(result.map_err(|e| e.code.into_owned())).unwrap();
                drop(held);
            }));
        }
        for _ in 0..2 {
            assert_eq!(
                receive
                    .recv_timeout(Duration::from_secs(5))
                    .expect("cutover deadlocked"),
                Err("workspace_writers_active".into())
            );
        }
        for thread in threads {
            thread.join().unwrap();
        }
        assert!(
            memory::snapshot(&f.node, &f.scope)
                .unwrap()
                .control
                .is_none()
        );
        // Manager contention is also conservative, and cannot recreate the
        // manager -> runner / runner -> manager lock inversion.
        {
            let held = f.node.runners.lock();
            assert!(f.node.runners.may_be_alive(&runners[1].session_id));
            drop(held);
        }
        assert!(f.node.runners.may_be_alive(&runners[1].session_id));
        runners[1].lock().closed = true;
        assert!(!f.node.runners.may_be_alive(&runners[1].session_id));
        f.node
            .runners
            .lock()
            .starting
            .insert(runners[1].session_id.clone(), watch::channel(None).1);
        assert!(f.node.runners.may_be_alive(&runners[1].session_id));
        f.node.runners.lock().starting.clear();
        let view = memory::View::new(&f.node, &f.scope, true).unwrap();
        memory::execute(
            &view,
            "workspace.cold",
            &json!({"jobId":"cold_retry","writersStopped":true}),
        )
        .unwrap();
        assert!(
            memory::snapshot(&f.node, &f.scope)
                .unwrap()
                .control
                .is_some()
        );
        // Synthetic runners have no process tasks; remove them before normal
        // service shutdown rather than waiting for a nonexistent exit signal.
        f.node.runners.lock().runners.clear();
        f.node.close().await;
    }
}

#[cfg(test)]
#[path = "admission_tests.rs"]
mod admission_tests;

#[cfg(test)]
#[path = "launch_tests.rs"]
mod launch_tests;

#[cfg(test)]
#[path = "host_admission_tests.rs"]
mod host_admission_tests;
