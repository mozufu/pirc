//! The agent's side channels (`grantWrite`, `forwardGateway`,
//! `handleBrowser`, `handleSandbox`, `confirmFromNode` of `PiRunner`). The
//! runner names the session, so an agent only ever acts as its own.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use pirc_agent::messages::js::{stringify, trim, utf16_len, utf16_prefix};
use pirc_protocol::{AGENT_OP_MAX_LENGTH, AGENT_REQUEST_MAX_BYTES, valid_agent_op};
use serde_json::{Map, Value, json};
use tokio::sync::{oneshot, watch};

use super::process::{Inner, NODE_DIALOG_PREFIX, Runner, SideRequest, session_root};
use super::reducer::js_string;
use crate::browser::{BrowserService, BrowserTarget};
use crate::services::Node;
use crate::store::{RunStatus, Store};
use crate::util::{now_ms, uuid};
use crate::write_broker::WriteGrant;

/// Gateway requests one session may have in flight.
const MAX_GATEWAY_REQUESTS: usize = 8;
/// Browser requests one session may have in flight (handoff waits count).
const MAX_BROWSER_REQUESTS: usize = 4;
/// Sandbox requests (approvals, unsandboxed commands) one session may have in flight.
const MAX_SANDBOX_REQUESTS: usize = 4;

/// A sandbox request's task's handle on it: its id, and its entry's abort
/// channel (also the entry's identity).
pub(super) struct Side {
    pub id: String,
    pub abort: Arc<watch::Sender<bool>>,
}

/// `typeof id === 'string' && id && id.length <= 100`.
fn request_id(message: &Map<String, Value>) -> Option<String> {
    match message.get("id") {
        Some(Value::String(id)) if !id.is_empty() && utf16_len(id) <= 100 => Some(id.clone()),
        _ => None,
    }
}

/// `Buffer.byteLength(JSON.stringify(args))`.
fn json_bytes(value: &Value) -> usize {
    stringify(value).len()
}

/// `path.resolve` of an absolute path.
fn lexical(path: &Path) -> PathBuf {
    let mut out = PathBuf::from("/");
    for component in path.components() {
        match component {
            std::path::Component::Normal(part) => out.push(part),
            std::path::Component::ParentDir => {
                out.pop();
            }
            _ => {}
        }
    }
    out
}

impl Runner {
    pub(crate) fn checkpoint_scope(
        &self,
        node: &Node,
    ) -> Result<crate::checkpoints::Scope, String> {
        use crate::checkpoints::Scope;
        if self.lock().closed {
            return Err("checkpoint runner is closed".into());
        }
        let mode = node.session_mode(&self.session_id).map_err(|e| e.message)?;
        if mode.workdir != pirc_protocol::mode::Workdir::Workspace {
            return Err("checkpoint capture is for Work directories only".into());
        }
        let run = self
            .lock()
            .current_run
            .clone()
            .ok_or("no active checkpoint run")?;
        let db = node.db.lock();
        let session = db.get_session(&self.session_id).map_err(|e| e.message)?;
        if session.runner_epoch != self.epoch || session.workspace_id != self.workspace.id {
            return Err("stale checkpoint runner".into());
        }
        Scope {
            node: node.config.node_id.clone(),
            owner: session.owner_user.ok_or("checkpoint owner unavailable")?,
            workspace: self.workspace.id.clone(),
            session: self.session_id.clone(),
            epoch: self.epoch,
            run,
            root: self.workspace.canonical_path.clone().into(),
            device: 0,
            inode: 0,
            policy: self.prepared.policy.paths.clone(),
        }
        .bind_root()
    }

    /// Answer the agent's `write_lease_request` from the node-wide broker.
    pub(super) fn grant_write(
        &self,
        node: &Node,
        message: &Map<String, Value>,
    ) -> Result<(), String> {
        let Some(Value::String(id)) = message.get("id") else {
            return Ok(());
        };
        let mut response = Map::new();
        response.insert("type".into(), json!("write_lease_response"));
        response.insert("id".into(), json!(id));
        if let Err(error) = crate::execution_fences::require_open(&node.db.lock(), &self.session_id)
        {
            response.insert("granted".into(), json!(false));
            response.insert("error".into(), json!(error.message));
            self.reply(Value::Object(response));
            return Ok(());
        }
        match message.get("path").and_then(Value::as_str) {
            Some(path) if Path::new(path).is_absolute() => {
                let canonical =
                    std::fs::canonicalize(path).unwrap_or_else(|_| lexical(Path::new(path)));
                match node
                    .writes
                    .acquire_for(&self.session_id, self.epoch, &canonical)
                {
                    WriteGrant::Granted => {
                        response.insert("granted".into(), json!(true));
                    }
                    WriteGrant::Blocked { code, message } => {
                        response.insert("granted".into(), json!(false));
                        response.insert("code".into(), json!(code));
                        response.insert("error".into(), json!(message));
                    }
                    WriteGrant::Refused { holder, path } => {
                        let holder = match node.db.lock().get_session(&holder) {
                            Ok(session) => format!("\"{}\" ({holder})", session.name),
                            // Session row gone; keep the id.
                            Err(_) => holder,
                        };
                        response.insert("granted".into(), json!(false));
                        response.insert(
                            "error".into(),
                            json!(format!(
                                "{path} is being written by session {holder}; wait until its run finishes"
                            )),
                        );
                    }
                }
            }
            _ => {
                response.insert("granted".into(), json!(false));
                response.insert(
                    "error".into(),
                    json!("write_lease_request needs an absolute path"),
                );
            }
        }
        self.reply(Value::Object(response));
        Ok(())
    }

    fn gateway_reply(&self, id: &str, response: Value) {
        let mut reply = json!({ "type": "gateway_response", "id": id });
        if let (Value::Object(reply), Value::Object(response)) = (&mut reply, response) {
            reply.extend(response);
        }
        self.reply(reply);
    }

    fn gateway_fail(
        &self,
        id: &str,
        status: u16,
        code: &str,
        message: &str,
        details: Option<Value>,
    ) {
        let mut error = json!({ "status": status, "code": code, "message": message });
        if let Some(details) = details {
            error["details"] = details;
        }
        self.gateway_reply(id, json!({ "ok": false, "error": error }));
    }

    /// Pass the agent's `gateway_request` to the gateway (or answer
    /// `recap.collect` here).
    pub(super) fn forward_gateway(self: &Arc<Self>, message: &Map<String, Value>) {
        let Some(id) = request_id(message) else {
            return;
        };
        let op = match message.get("op") {
            Some(Value::String(op))
                if utf16_len(op) <= AGENT_OP_MAX_LENGTH && valid_agent_op(op) =>
            {
                op.clone()
            }
            _ => {
                return self.gateway_fail(
                    &id,
                    400,
                    "invalid_input",
                    "A gateway operation is named like area.action",
                    None,
                );
            }
        };
        let args = match message.get("args") {
            None | Some(Value::Null) => json!({}),
            Some(args) => args.clone(),
        };
        if json_bytes(&args) > AGENT_REQUEST_MAX_BYTES {
            return self.gateway_fail(
                &id,
                413,
                "payload_too_large",
                "Gateway request arguments are too large",
                None,
            );
        }
        {
            let mut inner = self.lock();
            if inner.gateway_requests >= MAX_GATEWAY_REQUESTS {
                drop(inner);
                return self.gateway_fail(
                    &id,
                    429,
                    "too_many_requests",
                    "Too many gateway requests are in flight",
                    None,
                );
            }
            inner.gateway_requests += 1;
        }
        let runner = self.clone();
        tokio::spawn(async move {
            if op.starts_with("workspace.") || op.starts_with("history.") {
                let result = runner.memory_operation(&op, &args).await;
                match result {
                    Ok(value) => runner.gateway_reply(&id, json!({"ok":true,"result":value})),
                    Err(error) => runner.gateway_fail(
                        &id,
                        error.status,
                        &error.code,
                        &error.message,
                        error.details.map(|d| *d),
                    ),
                }
                runner.lock().gateway_requests -= 1;
                return;
            }
            // Never forward checkpoint operations to another node/gateway.
            // The runner supplies identity and the effective sandbox policy.
            if op.starts_with("checkpoint.") {
                let answer = match runner.node() {
                    Some(node) => match node.checkpoints.clone() {
                        Some(service) => service.request(node, runner.clone(), op, args).await,
                        None => Err("checkpoint capture disabled".into()),
                    },
                    None => Err("checkpoint node unavailable".into()),
                };
                match answer {
                    Ok(result) => runner.gateway_reply(&id, json!({"ok":true,"result":result})),
                    Err(error) => {
                        runner.gateway_fail(&id, 409, "checkpoint_unavailable", &error, None)
                    }
                }
                runner.lock().gateway_requests -= 1;
                return;
            }
            // Local-only: historical evidence never passes through the
            // gateway transport. The runner binds identity; the caller
            // cannot supply a workspace or source path.
            if op == "recap.collect" {
                let collected = match runner.node() {
                    Some(node) => {
                        let session = runner.session_id.clone();
                        tokio::task::spawn_blocking(move || {
                            crate::recap::collect_recap(&node, &session, &args)
                        })
                        .await
                        .ok()
                    }
                    None => None,
                };
                match collected {
                    Some(Ok(result)) => {
                        runner.gateway_reply(&id, json!({ "ok": true, "result": result }));
                    }
                    Some(Err(error)) => {
                        runner.gateway_fail(&id, error.status, &error.code, &error.message, None);
                    }
                    None => runner.gateway_fail(
                        &id,
                        500,
                        "recap_failed",
                        "Could not collect workspace recap evidence",
                        None,
                    ),
                }
                runner.lock().gateway_requests -= 1;
                return;
            }
            let answer = match runner.node() {
                Some(node) => {
                    node.agent_gateway
                        .request(&runner.session_id, &op, args)
                        .await
                }
                None => crate::agent_gateway::agent_error(
                    503,
                    "gateway_offline",
                    "This node is not connected to the gateway",
                    None,
                ),
            };
            runner.lock().gateway_requests -= 1;
            let body = &answer.body;
            if (200..300).contains(&answer.status) {
                let result = match body.get("result") {
                    None | Some(Value::Null) => Value::Null,
                    Some(result) => result.clone(),
                };
                return runner.gateway_reply(&id, json!({ "ok": true, "result": result }));
            }
            let error = body.get("error");
            let code = error
                .and_then(|error| error.get("code"))
                .and_then(Value::as_str)
                .unwrap_or("internal_error");
            let text = error
                .and_then(|error| error.get("message"))
                .and_then(Value::as_str)
                .map_or_else(
                    || format!("The gateway answered {}", answer.status),
                    str::to_owned,
                );
            let details = error.and_then(|error| error.get("details")).cloned();
            runner.gateway_fail(&id, answer.status, code, &text, details);
        });
    }

    async fn memory_operation(
        self: &Arc<Self>,
        op: &str,
        args: &Value,
    ) -> crate::error::ApiResult<Value> {
        use crate::workspace_memory as memory;
        let node = self
            .node()
            .ok_or_else(|| crate::error::ApiError::runner_unavailable("Runner ended"))?;
        let work = op.starts_with("workspace.");
        let initial = memory::scope(&node, &self.session_id, &self.mode, self.epoch, work)?;
        let remote = if work {
            let answer = node
                .agent_gateway
                .request(
                    &self.session_id,
                    "workspace.mirrorState",
                    json!({"ledgerKey":initial.key}),
                )
                .await;
            if answer.status != 200 {
                return Err(crate::error::ApiError::new(
                    503,
                    "workspace_authority_unavailable",
                    "Repository memory authority is unavailable",
                ));
            }
            if answer.body["result"]["owner"] != initial.owner {
                return Err(crate::error::ApiError::forbidden("Memory owner changed"));
            }
            answer.body["result"].clone()
        } else {
            let answer = node
                .agent_gateway
                .request(&self.session_id, "history.authority", json!({}))
                .await;
            if answer.status != 200 || answer.body["result"]["owner"] != initial.owner {
                return Err(crate::error::ApiError::forbidden(
                    "History authority is unavailable",
                ));
            }
            Value::Null
        };
        let runner = self.clone();
        let read_op = op.to_owned();
        let read_args = args.clone();
        let op = op.to_owned();
        let args = args.clone();
        let expected = initial.clone();
        let (result, mut view) = tokio::task::spawn_blocking(move || {
            // The existing runner lifecycle mutex serializes writes with teardown/replacement.
            let guard = runner.lock();
            if guard.closed {
                return Err(crate::error::ApiError::runner_unavailable("Runner ended"));
            }
            let current =
                memory::scope(&node, &runner.session_id, &runner.mode, runner.epoch, work)?;
            if current != expected {
                return Err(crate::error::ApiError::forbidden(
                    "Memory authority changed",
                ));
            }
            if work {
                if [
                    "workspace.cold",
                    "workspace.clear",
                    "workspace.forget",
                    "workspace.commit",
                    "workspace.open",
                ]
                .contains(&op.as_str())
                {
                    memory::open_writer(&node, &current, &args, op == "workspace.open")?;
                }
                let snapshot = memory::snapshot(&node, &current)?;
                memory::mirror_check(&snapshot, &remote, &memory::path(&node, &current))?;
            }
            let view = memory::View::new(&node, &current, work)?;
            let value = memory::execute(&view, &op, &args)?;
            if memory::scope(&node, &runner.session_id, &runner.mode, runner.epoch, work)?
                != expected
            {
                return Err(crate::error::ApiError::forbidden(
                    "Memory authority changed",
                ));
            }
            Ok((value, view))
        })
        .await
        .map_err(|_| crate::error::ApiError::internal())??;
        // Permission changes during a host read or a durable commit are checked before delivery.
        let node = self
            .node()
            .ok_or_else(|| crate::error::ApiError::runner_unavailable("Runner ended"))?;
        if work {
            let answer = node
                .agent_gateway
                .request(
                    &self.session_id,
                    "workspace.mirrorState",
                    json!({"ledgerKey":initial.key}),
                )
                .await;
            if answer.status != 200 {
                return Err(crate::error::ApiError::new(
                    503,
                    "workspace_authority_unavailable",
                    "Memory authority changed before delivery",
                ));
            }
            if answer.body["result"]["owner"] != initial.owner {
                return Err(crate::error::ApiError::forbidden("Memory owner changed"));
            }
            let state = memory::snapshot(&node, &initial)?;
            memory::mirror_check(
                &state,
                &answer.body["result"],
                &memory::path(&node, &initial),
            )?;
            node.mirror.scan();
        }
        if !work {
            let answer = node
                .agent_gateway
                .request(&self.session_id, "history.authority", json!({}))
                .await;
            if answer.status != 200 || answer.body["result"]["owner"] != initial.owner {
                return Err(crate::error::ApiError::forbidden(
                    "History authority changed before delivery",
                ));
            }
        }
        let guard = self.lock();
        if guard.closed
            || memory::scope(&node, &self.session_id, &self.mode, self.epoch, work)? != initial
        {
            return Err(crate::error::ApiError::forbidden(
                "Memory authority changed before delivery",
            ));
        }
        // Mutation acknowledgements also contain source-bound control metadata.
        view.revalidate(work)?;
        if [
            "workspace.context",
            "workspace.next",
            "workspace.recall",
            "history.read",
            "history.search",
        ]
        .contains(&read_op.as_str())
        {
            return memory::execute(&view, &read_op, &read_args);
        }
        Ok(result)
    }

    fn browser_fail(&self, id: &str, status: u16, code: &str, message: &str) {
        self.reply(json!({ "type": "browser_response", "id": id, "ok": false,
            "error": { "status": status, "code": code, "message": message } }));
    }

    /// Answer the agent's `browser_request` from the node's browser.
    pub(super) fn handle_browser(
        self: &Arc<Self>,
        message: &Map<String, Value>,
    ) -> Result<(), String> {
        if request_id(message).is_none() {
            return Ok(());
        }
        let Some(node) = self.node() else {
            return Ok(());
        };
        if let Err(error) = node.session_mode(&self.session_id) {
            self.browser_fail(
                &request_id(message).unwrap_or_default(),
                error.status,
                &error.code,
                &error.message,
            );
            return Ok(());
        }
        self.handle_browser_with(&node.browser, message)
    }

    /// [`Runner::handle_browser`] from `browser`.
    fn handle_browser_with(
        self: &Arc<Self>,
        browser: &Arc<dyn BrowserService>,
        message: &Map<String, Value>,
    ) -> Result<(), String> {
        if let Some(node) = self.node()
            && node.session_mode(&self.session_id).ok().as_ref() != Some(&self.mode)
        {
            return Err("Mode is unavailable or changed".into());
        }
        let Some(id) = request_id(message) else {
            return Ok(());
        };
        if !browser.enabled() {
            let error = crate::browser::unavailable();
            self.browser_fail(&id, error.status, &error.code, &error.message);
            return Ok(());
        }
        let op = match message.get("op").and_then(Value::as_str) {
            Some(op)
                if (1..=40).contains(&op.len())
                    && op.bytes().all(|b| b.is_ascii_lowercase() || b == b'_') =>
            {
                op.to_owned()
            }
            _ => {
                self.browser_fail(&id, 400, "invalid_input", "Unknown browser operation");
                return Ok(());
            }
        };
        let args = match message.get("args") {
            Some(args @ (Value::Object(_) | Value::Array(_))) => args.clone(),
            _ => json!({}),
        };
        if json_bytes(&args) > AGENT_REQUEST_MAX_BYTES {
            self.browser_fail(
                &id,
                413,
                "payload_too_large",
                "Browser request arguments are too large",
            );
            return Ok(());
        }
        if self.lock().browser_requests.len() >= MAX_BROWSER_REQUESTS {
            self.browser_fail(
                &id,
                429,
                "too_many_requests",
                "Too many browser requests are in flight",
            );
            return Ok(());
        }
        let root = session_root(&self.workspace, &self.session_id, &self.mode)
            .map_err(|error| error.message)?;
        let target = BrowserTarget {
            session_id: self.session_id.clone(),
            workspace_id: self.workspace.id.clone(),
            root,
        };
        // `browser_cancel` aborts through `abort` and leaves the entry: the
        // request keeps its slot until the browser settles it, and still
        // answers (the agent ignores it), as TS did.
        let (abort, aborted) = watch::channel(false);
        let abort = Arc::new(abort);
        let runner = self.clone();
        let browser = browser.clone();
        let request = id.clone();
        let entry = abort.clone();
        let mut inner = self.lock();
        let task = tokio::spawn(async move {
            let caller = crate::browser::effects::Caller::Agent {
                epoch: runner.epoch,
                abort: entry.clone(),
            };
            let answer = crate::browser::effects::from(
                caller,
                browser.handle_with_abort(target, op, args, aborted),
            )
            .await;
            match answer {
                Ok(result) => runner.reply(
                    json!({ "type": "browser_response", "id": request, "ok": true, "result": result }),
                ),
                Err(error) => runner.browser_fail(&request, error.status, &error.code, &error.message),
            }
            let mut inner = runner.lock();
            if inner
                .browser_requests
                .get(&request)
                .is_some_and(|current| Arc::ptr_eq(&current.abort, &entry))
            {
                inner.browser_requests.remove(&request);
            }
        });
        inner.browser_requests.insert(
            id,
            SideRequest {
                abort,
                dialog: None,
                task: Some(task.abort_handle()),
            },
        );
        Ok(())
    }

    /// The agent's `browser_cancel`: the request's abort fires; its entry
    /// stays until the operation settles (its task removes it), holding its
    /// in-flight slot as in TS.
    pub(super) fn cancel_browser(&self, message: &Map<String, Value>) {
        if let Some(Value::String(id)) = message.get("id")
            && let Some(request) = self.lock().browser_requests.get(id)
        {
            request.abort.send_replace(true);
        }
    }

    /// `confirmFromNode`: ask the human, from the node itself (the agent
    /// is sandboxed and may be steered by what it reads, so its own
    /// dialogs cannot grant anything). No when unanswered within the
    /// interaction TTL, withdrawn by the agent, or the runner stops.
    ///
    /// TS opened the dialog synchronously while handling the request, so a
    /// `sandbox_cancel` always found it. Here the dialog opens in the
    /// request's task, possibly after the cancel: a request already
    /// withdrawn (its entry gone or replaced) is answered no without a
    /// dialog, and one withdrawn while the dialog opens has it withdrawn.
    async fn confirm_from_node(
        &self,
        side: &Side,
        title: &str,
        message: &str,
        tool_call_id: Option<String>,
        host_intent: Option<&str>,
    ) -> Result<Option<String>, String> {
        if !self.side_live(&self.lock(), side) {
            return Ok(None);
        }
        let node = self.node().ok_or("The node is closing")?;
        let rpc_id = format!("{NODE_DIALOG_PREFIX}{}", uuid());
        let mut dialog = Map::new();
        dialog.insert("type".into(), json!("extension_ui_request"));
        dialog.insert("id".into(), json!(rpc_id));
        dialog.insert("method".into(), json!("confirm"));
        dialog.insert("title".into(), json!(title));
        dialog.insert("message".into(), json!(message));
        if let Some(tool_call_id) = tool_call_id {
            dialog.insert("toolCallId".into(), json!(tool_call_id));
        }
        let ttl = node.config.interaction_ttl_ms;
        let interaction_id;
        {
            // Created and announced as one step for snapshots, like an
            // agent's own dialog (`Runner::state_at`).
            let _view = self.view();
            let db = node.db.lock();
            let interaction = crate::store::atomic(&db, |db| {
                let interaction = db.create_interaction(
                    &self.session_id,
                    self.epoch,
                    &rpc_id,
                    "confirm",
                    &dialog,
                    now_ms().saturating_add(i64::try_from(ttl).unwrap_or(i64::MAX)),
                )?;
                if let Some(intent_hash) = host_intent {
                    crate::host_commands::approval::record(
                        db,
                        &node,
                        crate::host_commands::approval::Request {
                            session: &self.session_id,
                            workspace: &self.workspace.id,
                            epoch: self.epoch,
                            request: &side.id,
                            intent_hash,
                        },
                        &interaction.id,
                    )?;
                }
                Ok(interaction)
            })
            .map_err(|error| error.message)?;
            interaction_id = interaction.id.clone();
            drop(db);
            self.publish(
                "interaction_created",
                serde_json::to_value(&interaction).unwrap_or_default(),
            );
            let _ = self.update_current_run(RunStatus::WaitingInput);
        }
        let (answer, answered) = oneshot::channel();
        {
            let mut inner = self.lock();
            if !self.side_live(&inner, side) {
                drop(inner);
                // The runner stopped or the agent withdrew the request
                // while the dialog opened: withdraw it at once.
                self.lock().node_dialogs.insert(rpc_id.clone(), answer);
                self.withdraw(&rpc_id);
                return Ok(None);
            }
            inner.node_dialogs.insert(rpc_id.clone(), answer);
            // Linked under the same lock: a later cancel withdraws it.
            if let Some(entry) = inner.sandbox_requests.get_mut(&side.id) {
                entry.dialog = Some(rpc_id.clone());
            }
        }
        drop(node);
        match tokio::time::timeout(Duration::from_millis(ttl), answered).await {
            Ok(Ok(true)) => Ok(Some(interaction_id)),
            Ok(Ok(false)) => Ok(None),
            // Withdrawn (the dialog's sender went with it).
            Ok(Err(_)) => Ok(None),
            Err(_) => {
                self.withdraw(&rpc_id);
                Ok(None)
            }
        }
    }

    /// Whether `side` is still in flight: the runner runs, the agent has not
    /// withdrawn it, and no later request took over its id.
    fn side_live(&self, inner: &Inner, side: &Side) -> bool {
        !inner.closed
            && !*side.abort.borrow()
            && inner
                .sandbox_requests
                .get(&side.id)
                .is_some_and(|entry| Arc::ptr_eq(&entry.abort, &side.abort))
    }

    fn sandbox_fail(&self, id: &str, code: &str, message: &str) {
        self.reply(json!({ "type": "sandbox_response", "id": id, "ok": false,
            "error": { "code": code, "message": message } }));
    }

    fn sandbox_ok(&self, id: &str, result: Value) {
        self.reply(json!({ "type": "sandbox_response", "id": id, "ok": true, "result": result }));
    }

    /// The agent's `sandbox_request`: `network` (allow more domains for
    /// this session) or `exec` (run one command outside the sandbox). Both
    /// need the human's yes, asked by the node.
    pub(super) fn handle_sandbox(
        self: &Arc<Self>,
        message: &Map<String, Value>,
    ) -> Result<(), String> {
        if let Some(node) = self.node()
            && node.workspace_mode(&self.workspace).ok().as_ref() != Some(&self.mode)
        {
            return Err("Mode is unavailable or changed".into());
        }
        let Some(id) = request_id(message) else {
            return Ok(());
        };
        let args = match message.get("args") {
            Some(args @ (Value::Object(_) | Value::Array(_))) => args.clone(),
            _ => json!({}),
        };
        if json_bytes(&args) > AGENT_REQUEST_MAX_BYTES {
            self.sandbox_fail(
                &id,
                "payload_too_large",
                "Sandbox request arguments are too large",
            );
            return Ok(());
        }
        if self.lock().sandbox_requests.len() >= MAX_SANDBOX_REQUESTS {
            self.sandbox_fail(
                &id,
                "too_many_requests",
                "Too many sandbox requests are in flight",
            );
            return Ok(());
        }
        let reason = match args.get("reason") {
            Some(Value::String(reason)) if !trim(reason).is_empty() => {
                utf16_prefix(trim(reason), 500).to_owned()
            }
            _ => "(no reason given)".to_owned(),
        };
        // Only a link for the client (the ptc operation asking); it grants nothing.
        let tool_call_id = self.running_operation(message.get("toolCallId"));
        match message.get("op").and_then(Value::as_str) {
            Some("network") => {
                let mut domains: Vec<String> = Vec::new();
                if let Some(Value::Array(items)) = args.get("domains") {
                    for item in items {
                        let domain = trim(&js_string(Some(item))).to_lowercase();
                        if !domains.contains(&domain) {
                            domains.push(domain);
                        }
                    }
                }
                if domains.is_empty() || domains.len() > 10 {
                    self.sandbox_fail(&id, "invalid_input", "Name one to ten domains");
                    return Ok(());
                }
                if let Some(bad) = domains
                    .iter()
                    .find(|domain| !pirc_policy::session::valid_domain(domain))
                {
                    self.sandbox_fail(&id, "invalid_input", &format!("Not a domain: {bad}"));
                    return Ok(());
                }
                if !self.prepared.has_control() {
                    self.sandbox_fail(
                        &id,
                        "sandbox_error",
                        "The sandbox's control channel is closed",
                    );
                    return Ok(());
                }
                let missing: Vec<String> = {
                    let inner = self.lock();
                    let allowed = &self.prepared.policy.network.allowed_domains;
                    domains
                        .iter()
                        .filter(|domain| {
                            !allowed.contains(domain) && !inner.approved_domains.contains(*domain)
                        })
                        .cloned()
                        .collect()
                };
                if missing.is_empty() {
                    self.sandbox_ok(&id, json!({ "granted": domains }));
                    return Ok(());
                }
                let text = [
                    format!(
                        "The agent asks to reach {} from its sandbox.",
                        missing.join(", ")
                    ),
                    format!("Reason: {reason}"),
                    "Approving allows these hosts for the rest of this session.".to_owned(),
                ]
                .join("\n\n");
                self.start_sandbox(id, move |runner, side| async move {
                    let confirmed = runner
                        .confirm_from_node(
                            &side,
                            "Allow network access?",
                            &text,
                            tool_call_id,
                            None,
                        )
                        .await?;
                    if confirmed.is_none() {
                        runner.sandbox_ok(&side.id, json!({ "granted": [], "denied": missing }));
                        return Ok(());
                    }
                    {
                        let node = runner.node().ok_or("The node is closing")?;
                        crate::execution_fences::require_open(&node.db.lock(), &runner.session_id)
                            .map_err(|e| e.message)?;
                        let mut inner = runner.lock();
                        inner.approved_domains.extend(missing.iter().cloned());
                        let approved: Vec<String> =
                            inner.approved_domains.iter().cloned().collect();
                        // Under the lock: both backends replace the whole
                        // set, so an older, smaller one must never land last.
                        runner.prepared.approve_domains(&approved)?;
                    }
                    runner.sandbox_ok(&side.id, json!({ "granted": domains }));
                    Ok(())
                });
            }
            Some("exec") => {
                let command = args
                    .get("command")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_owned();
                if trim(&command).is_empty() || utf16_len(&command) > 20_000 {
                    self.sandbox_fail(
                        &id,
                        "invalid_input",
                        "command must be a non-empty string (at most 20000 characters)",
                    );
                    return Ok(());
                }
                let root = session_root(&self.workspace, &self.session_id, &self.mode)
                    .map_err(|error| error.message)?;
                let root = pirc_policy::real_resolve(&root.to_string_lossy());
                let relative = match args.get("cwd") {
                    Some(Value::String(cwd)) if !cwd.is_empty() => cwd.clone(),
                    _ => ".".to_owned(),
                };
                let cwd = pirc_policy::real_resolve(
                    &lexical(&Path::new(&root).join(relative)).to_string_lossy(),
                );
                let is_dir = std::fs::metadata(&cwd).is_ok_and(|stat| stat.is_dir());
                if !pirc_policy::is_inside(&cwd, &root) || !is_dir {
                    self.sandbox_fail(
                        &id,
                        "invalid_input",
                        &format!("cwd must be a directory inside {root}"),
                    );
                    return Ok(());
                }
                let timeout = args
                    .get("timeoutMs")
                    .and_then(Value::as_f64)
                    .unwrap_or(120_000.0)
                    .clamp(1000.0, 3_600_000.0);
                let text = [
                    format!("$ {command}"),
                    format!("in {cwd}"),
                    format!("Reason: {reason}"),
                    "Host management: this command runs outside workspace isolation with this node account's rights (without the node's own secrets). Detached jobs or external effects may survive its shell; a workspace switch remains blocked while their retirement is unconfirmed.".to_owned(),
                ]
                .join("\n\n");
                self.start_sandbox(id, move |runner, side| async move {
                    let timeout = Duration::from_millis(timeout as u64);
                    let intent = runner.host_intent(&side, &command, &cwd, timeout)?;
                    let approval = runner
                        .confirm_from_node(
                            &side,
                            "Allow host management for this command?",
                            &text,
                            tool_call_id,
                            Some(&intent),
                        )
                        .await?;
                    let Some(approval) = approval else {
                        runner.sandbox_fail(
                            &side.id,
                            "denied",
                            "The user did not approve running this outside the sandbox",
                        );
                        return Ok(());
                    };
                    let ticket = runner
                        .start_host(&side, &command, &cwd, timeout, &approval)
                        .map_err(|error| error.message)?;
                    let result = ticket.result().await.map_err(|error| error.message)?;
                    runner.sandbox_ok(&side.id, result);
                    Ok(())
                });
            }
            _ => self.sandbox_fail(&id, "invalid_input", "Unknown sandbox operation"),
        }
        Ok(())
    }

    /// Fingerprint the host-selected binding and exact command, not model labels.
    /// The private approval row stores only this digest, never command contents.
    pub(super) fn host_intent(
        &self,
        side: &Side,
        text: &str,
        cwd: &str,
        timeout: Duration,
    ) -> Result<String, String> {
        use sha2::{Digest, Sha256};
        let root =
            session_root(&self.workspace, &self.session_id, &self.mode).map_err(|e| e.message)?;
        let body = json!([
            1,
            self.session_id,
            self.workspace.id,
            self.workspace.canonical_path,
            self.epoch,
            self.mode,
            root,
            side.id,
            text,
            cwd,
            timeout.as_millis()
        ]);
        Ok(format!("{:x}", Sha256::digest(body.to_string().as_bytes())))
    }

    /// Revalidate the approved origin at the effect boundary. The same DB lock
    /// serializes transition acceptance; the runner lock serializes withdrawal.
    pub(super) fn start_host(
        &self,
        side: &Side,
        text: &str,
        cwd: &str,
        timeout: Duration,
        approval: &str,
    ) -> crate::error::ApiResult<crate::host_commands::Ticket> {
        use crate::error::ApiError;
        let node = self
            .node()
            .ok_or_else(|| ApiError::runner_unavailable("The node is closing"))?;
        let mut command = super::host::command(&node.env, text, Path::new(cwd));
        let db = node.db.lock();
        db.require_session_available(&self.session_id)?;
        crate::execution_fences::require_open(&db, &self.session_id)?;
        let row = db.get_session(&self.session_id)?;
        let workspace = db.get_workspace(&row.workspace_id)?;
        if row.runner_epoch != self.epoch
            || row.workspace_id != self.workspace.id
            || workspace.canonical_path != self.workspace.canonical_path
            || node.workspace_mode(&workspace)? != self.mode
        {
            return Err(ApiError::conflict(
                "The approved execution environment changed",
            ));
        }
        let root = session_root(&workspace, &self.session_id, &self.mode)?;
        let root = pirc_policy::real_resolve(&root.to_string_lossy());
        if pirc_policy::real_resolve(cwd) != cwd
            || !pirc_policy::is_inside(cwd, &root)
            || !Path::new(cwd).is_dir()
        {
            return Err(ApiError::conflict("The approved command directory changed"));
        }
        // A mode update uses a separate lock from the persisted binding. Hold
        // its read guard through spawn as well; recheck after acquiring it so a
        // concurrent mode replacement cannot land between validation and exec.
        let modes = node.modes.read().unwrap_or_else(|error| error.into_inner());
        let mut installed = modes
            .get(&workspace.mode)
            .cloned()
            .ok_or_else(|| ApiError::conflict("The approved mode is unavailable"))?;
        if node
            .recovery_roots
            .read()
            .unwrap_or_else(|error| error.into_inner())
            .contains_key(&workspace.id)
        {
            installed.workspace_memory = false;
        }
        if installed != self.mode {
            return Err(ApiError::conflict("The approved execution mode changed"));
        }
        // Memory operations hold this lifecycle lock before taking DB admission.
        // Never wait in the opposite order; no journal entry or spawn exists yet.
        let inner = match self.inner.try_lock() {
            Ok(inner) => inner,
            Err(std::sync::TryLockError::Poisoned(inner)) => inner.into_inner(),
            Err(std::sync::TryLockError::WouldBlock) => {
                return Err(ApiError::new(
                    409,
                    "host_admission_busy",
                    "The agent is updating its state; retry the host command after it finishes",
                ));
            }
        };
        if !self.side_live(&inner, side) {
            return Err(ApiError::conflict("The host command was withdrawn"));
        }
        node.host_commands.start(
            &node,
            &db,
            crate::host_commands::Origin {
                authority: crate::host_commands::approval::Authority::HostManagement {
                    interaction: approval.to_owned(),
                    intent_hash: self
                        .host_intent(side, text, cwd, timeout)
                        .map_err(|_| ApiError::internal())?,
                },
                session: self.session_id.clone(),
                workspace: workspace.id,
                epoch: self.epoch,
                request: side.id.clone(),
                timeout,
                root: root.into(),
            },
            &mut command,
            side.abort.subscribe(),
        )
    }

    /// `start(work)`: the request is in flight until `work` ends; a thrown
    /// error is `sandbox_error`.
    fn start_sandbox<F, Fut>(self: &Arc<Self>, id: String, work: F)
    where
        F: FnOnce(Arc<Runner>, Side) -> Fut + Send + 'static,
        Fut: std::future::Future<Output = Result<(), String>> + Send,
    {
        let side = Side {
            id,
            abort: Arc::new(watch::channel(false).0),
        };
        self.lock().sandbox_requests.insert(
            side.id.clone(),
            SideRequest {
                abort: side.abort.clone(),
                dialog: None,
                task: None,
            },
        );
        let runner = self.clone();
        tokio::spawn(async move {
            let (id, abort) = (side.id.clone(), side.abort.clone());
            if let Err(error) = work(runner.clone(), side).await {
                runner.sandbox_fail(&id, "sandbox_error", &error);
            }
            // Only its own entry: a later request may have taken the id
            // (TS deleted that one too, leaving it uncancellable).
            let mut inner = runner.lock();
            if inner
                .sandbox_requests
                .get(&id)
                .is_some_and(|entry| Arc::ptr_eq(&entry.abort, &abort))
            {
                inner.sandbox_requests.remove(&id);
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;
    use std::sync::Mutex;

    use pirc_policy::session::SessionPolicy;
    use tokio::sync::mpsc;

    use super::super::process::Outbound;
    use super::*;
    use crate::browser::{BoxFuture, Detach, FrameSink};
    use crate::error::{ApiError, ApiResult};
    use crate::sandbox::Prepared;
    use crate::store::{ModeId, Workspace};

    #[tokio::test]
    async fn checkpoint_rpc_binds_real_node_authority_and_rejects_forged_or_stale_requests() {
        use crate::checkpoints::{FileVersion, digest};
        use pirc_config::{Env, NodeConfig};
        use pirc_protocol::NodeRole;
        // Short socket names on macOS. This node has no link, live agent,
        // provider or browser; only its owned state and in-process RPC handlers.
        let dir = tempfile::tempdir_in("/tmp").unwrap();
        let root = dir.path().canonicalize().unwrap();
        let state = root.join("state");
        let work = root.join("work");
        std::fs::create_dir(&work).unwrap();
        let state_text = state.display().to_string();
        let config_text = root.join("config").display().to_string();
        let home = root.display().to_string();
        let env = Env::new(
            [
                ("HOME", home.as_str()),
                ("PIRC_STATE_DIR", state_text.as_str()),
                ("PIRC_CONFIG_DIR", config_text.as_str()),
                ("PIRC_NODE_ID", "checkpoint-test"),
                ("PIRC_NODE_TOKEN", "0123456789abcdef0123456789abcdef"),
                ("PIRC_DAEMON_URL", "ws://127.0.0.1:8787"),
                ("PIRC_ALLOWED_USERS", "owner"),
                ("PIRC_BROWSER", "false"),
                ("PIRC_CHECKPOINT_WORKSPACES", "[\"w\"]"),
            ],
            &root,
        );
        let config = NodeConfig::load(&env, NodeRole::Node).unwrap();
        let node = crate::services::Services::start(config, env).await.unwrap();
        node.replace_modes(vec![pirc_protocol::mode::default_work()])
            .await;
        let (workspace, session, run) = {
            let db = node.db.lock();
            let workspace = db
                .add_workspace(
                    "w",
                    "checkpoint-test",
                    "test",
                    work.to_str().unwrap(),
                    ModeId::new("directory").unwrap(),
                )
                .unwrap();
            let session = db
                .create_session("w", state.join("sessions/test").to_str().unwrap(), "owner")
                .unwrap();
            assert_eq!(db.increment_epoch(&session.id).unwrap(), 1);
            let run = db.create_run(&session.id).unwrap();
            (workspace, session, run)
        };
        let mut policy = SessionPolicy::default();
        policy.paths.allow_write.push(work.display().to_string());
        let external = root.join("external");
        std::fs::create_dir(&external).unwrap();
        policy
            .paths
            .allow_write
            .push(external.display().to_string());
        policy.paths.deny_read.push(state_text);
        let prepared = Prepared::new(
            "/bin/false".into(),
            Vec::new(),
            Vec::new(),
            policy,
            Vec::new(),
            None,
            || {},
        );
        let (runner, _replies) = Runner::detached(&session.id, workspace, prepared);
        runner.set_run(&run);
        let capture = node.checkpoints.clone().unwrap();
        let file = work.join("main");
        std::fs::write(&file, "dirty user bytes").unwrap();
        let args = json!({"path":file,"tool":"edit","expected":digest(b"dirty user bytes")});
        let mut forged = args.clone();
        forged["owner"] = json!("forged");
        assert!(
            capture
                .clone()
                .request(
                    node.clone(),
                    runner.clone(),
                    "checkpoint.begin".into(),
                    forged
                )
                .await
                .is_err()
        );
        let response = capture
            .clone()
            .request(
                node.clone(),
                runner.clone(),
                "checkpoint.begin".into(),
                args,
            )
            .await
            .unwrap();
        let operation = response["operation"].as_str().unwrap().to_owned();
        std::fs::write(&file, "agent postimage").unwrap();
        assert!(
            capture
                .clone()
                .request(
                    node.clone(),
                    runner.clone(),
                    "checkpoint.finish".into(),
                    json!({"operation":operation,"succeeded":true,"path":"/outside"})
                )
                .await
                .is_err()
        );
        capture
            .clone()
            .request(
                node.clone(),
                runner.clone(),
                "checkpoint.finish".into(),
                json!({"operation":operation,"succeeded":true}),
            )
            .await
            .unwrap();
        let scope = runner.checkpoint_scope(&node).unwrap();
        let ops = capture.journal.operations(&scope).unwrap();
        let FileVersion::File { ref hash, .. } = ops[0].before else {
            panic!("missing dirty baseline")
        };
        assert_eq!(
            capture.journal.read_blob(hash).unwrap(),
            b"dirty user bytes"
        );
        assert_eq!(ops.len(), 1);
        assert_eq!(scope.owner, "owner");
        let excluded = capture
            .clone()
            .request(
                node.clone(),
                runner.clone(),
                "checkpoint.begin".into(),
                json!({"path":external.join("main"),"tool":"write","expected":null}),
            )
            .await
            .unwrap();
        assert_eq!(excluded["excluded"], "outside_workspace");
        assert!(capture.journal.info(&scope).unwrap().unwrap().gaps);
        assert!(
            !external.join("main").exists(),
            "classification never grants or performs a file write"
        );
        node.db.lock().increment_epoch(&session.id).unwrap();
        assert!(
            capture
                .clone()
                .request(
                    node.clone(),
                    runner.clone(),
                    "checkpoint.finish".into(),
                    json!({"operation":operation,"succeeded":true})
                )
                .await
                .is_err()
        );
        assert_eq!(std::fs::read(file).unwrap(), b"agent postimage");
        node.close().await;
    }

    /// A browser whose operations (named by `args.tag`) settle only when the
    /// test releases them, whether or not they were aborted (as the
    /// manager's do): it reports `started <tag>` and `aborted <tag>`.
    struct GatedBrowser {
        gates: Mutex<HashMap<String, oneshot::Sender<ApiResult<Value>>>>,
        seen: mpsc::UnboundedSender<String>,
    }

    impl GatedBrowser {
        fn release(&self, tag: &str, result: ApiResult<Value>) {
            let gate = self.gates.lock().unwrap().remove(tag);
            gate.expect("an operation waiting").send(result).unwrap();
        }
    }

    impl BrowserService for GatedBrowser {
        fn enabled(&self) -> bool {
            true
        }

        fn handle(&self, _: BrowserTarget, _: String, _: Value) -> BoxFuture<'_, ApiResult<Value>> {
            unreachable!("the runner aborts through handle_with_abort")
        }

        fn handle_with_abort(
            &self,
            _: BrowserTarget,
            _: String,
            args: Value,
            mut abort: watch::Receiver<bool>,
        ) -> BoxFuture<'_, ApiResult<Value>> {
            let tag = args["tag"].as_str().unwrap().to_owned();
            let (gate, settled) = oneshot::channel();
            self.gates.lock().unwrap().insert(tag.clone(), gate);
            let _ = self.seen.send(format!("started {tag}"));
            Box::pin(async move {
                let mut settled = settled;
                let mut aborted = false;
                loop {
                    tokio::select! {
                        result = &mut settled => return result.unwrap(),
                        changed = abort.changed(), if !aborted => {
                            if changed.is_err() || *abort.borrow() {
                                aborted = true;
                                let _ = self.seen.send(format!("aborted {tag}"));
                            }
                        }
                    }
                }
            })
        }

        fn attach(&self, _: &str, _: FrameSink) -> Detach {
            unreachable!()
        }

        fn input(&self, _: BrowserTarget, _: Value) -> BoxFuture<'_, ApiResult<Option<Value>>> {
            unreachable!()
        }

        fn close_session(&self, _: &str) -> BoxFuture<'_, ApiResult<()>> {
            unreachable!()
        }

        fn shutdown(&self) -> BoxFuture<'_, ()> {
            unreachable!()
        }
    }

    struct Agent {
        runner: Arc<Runner>,
        browser: Arc<GatedBrowser>,
        replies: mpsc::UnboundedReceiver<Outbound>,
        seen: mpsc::UnboundedReceiver<String>,
    }

    impl Agent {
        fn new() -> Self {
            let workspace = Workspace {
                id: "w".into(),
                host_id: "h".into(),
                display_name: "w".into(),
                canonical_path: "/".into(),
                defaults: Map::new(),
                mode: ModeId::new("directory").unwrap(),
            };
            let prepared = Prepared::new(
                "/bin/false".into(),
                Vec::new(),
                Vec::new(),
                SessionPolicy::default(),
                Vec::new(),
                None,
                || {},
            );
            let (runner, replies) = Runner::detached("s", workspace, prepared);
            let (seen_tx, seen) = mpsc::unbounded_channel();
            let browser = Arc::new(GatedBrowser {
                gates: Mutex::default(),
                seen: seen_tx,
            });
            Self {
                runner,
                browser,
                replies,
                seen,
            }
        }

        fn request(&self, id: &str, tag: &str) {
            let browser: Arc<dyn BrowserService> = self.browser.clone();
            let message = json!({ "type": "browser_request", "id": id, "op": "snapshot",
                "args": { "tag": tag } });
            self.runner
                .handle_browser_with(&browser, message.as_object().unwrap())
                .unwrap();
        }

        fn cancel(&self, id: &str) {
            let message = json!({ "type": "browser_cancel", "id": id });
            self.runner.cancel_browser(message.as_object().unwrap());
        }

        async fn seen(&mut self) -> String {
            tokio::time::timeout(Duration::from_secs(5), self.seen.recv())
                .await
                .expect("the browser within 5 s")
                .unwrap()
        }

        async fn reply(&mut self) -> Value {
            let line = tokio::time::timeout(Duration::from_secs(5), self.replies.recv())
                .await
                .expect("a reply within 5 s")
                .unwrap();
            serde_json::from_str(&line.line).unwrap()
        }

        fn in_flight(&self) -> Vec<String> {
            let mut ids: Vec<String> = self
                .runner
                .lock()
                .browser_requests
                .keys()
                .cloned()
                .collect();
            ids.sort();
            ids
        }

        /// Wait until exactly `expected` are in flight.
        async fn settled(&self, expected: &[&str]) {
            tokio::time::timeout(Duration::from_secs(5), async {
                while self.in_flight() != expected {
                    tokio::time::sleep(Duration::from_millis(5)).await;
                }
            })
            .await
            .expect("the request settled within 5 s");
        }
    }

    fn aborted() -> ApiError {
        ApiError::new(499, "aborted", "Aborted")
    }

    /// `browser_cancel` aborts the operation but keeps its slot until the
    /// operation settles, and its late reply still goes out (TS).
    #[tokio::test]
    async fn a_cancelled_browser_request_keeps_its_slot_until_it_settles() {
        let mut agent = Agent::new();
        for n in 1..=4 {
            agent.request(&format!("r{n}"), &format!("t{n}"));
            assert_eq!(agent.seen().await, format!("started t{n}"));
        }
        agent.cancel("r1");
        assert_eq!(agent.seen().await, "aborted t1");
        // Still in flight: the cancelled request's entry survives.
        assert_eq!(agent.in_flight(), ["r1", "r2", "r3", "r4"]);
        // A fifth request while the cancelled one runs.
        agent.request("r5", "t5");
        assert_eq!(
            agent.reply().await,
            json!({ "type": "browser_response", "id": "r5", "ok": false, "error": {
                "status": 429, "code": "too_many_requests",
                "message": "Too many browser requests are in flight" } })
        );
        // The operation settles: its late reply goes out, the slot is free.
        agent.browser.release("t1", Err(aborted()));
        assert_eq!(
            agent.reply().await,
            json!({ "type": "browser_response", "id": "r1", "ok": false, "error": {
                "status": 499, "code": "aborted", "message": "Aborted" } })
        );
        agent.settled(&["r2", "r3", "r4"]).await;
        agent.request("r6", "t6");
        assert_eq!(agent.seen().await, "started t6");
        for n in [2, 3, 4, 6] {
            agent
                .browser
                .release(&format!("t{n}"), Ok(json!({ "n": n })));
            assert_eq!(
                agent.reply().await,
                json!({ "type": "browser_response", "id": format!("r{n}"), "ok": true,
                    "result": { "n": n } })
            );
        }
        agent.settled(&[]).await;
        assert!(agent.seen.try_recv().is_err());
    }

    /// A request that settles after a later one took its id leaves the later
    /// one's entry (`Arc::ptr_eq`).
    #[tokio::test]
    async fn a_settled_browser_request_removes_only_its_own_entry() {
        let mut agent = Agent::new();
        agent.request("r", "first");
        assert_eq!(agent.seen().await, "started first");
        agent.cancel("r");
        assert_eq!(agent.seen().await, "aborted first");
        agent.request("r", "second");
        assert_eq!(agent.seen().await, "started second");
        agent.browser.release("first", Err(aborted()));
        assert_eq!(agent.reply().await["error"]["status"], 499);
        // Give the first task time to (wrongly) remove the entry.
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert_eq!(agent.in_flight(), ["r"]);
        // The entry is the second request's: a cancel reaches it.
        agent.cancel("r");
        assert_eq!(agent.seen().await, "aborted second");
        agent.browser.release("second", Ok(json!(2)));
        assert_eq!(agent.reply().await["result"], 2);
        agent.settled(&[]).await;
    }

    #[test]
    fn request_ids_and_paths() {
        let message = |id: Value| {
            let mut map = Map::new();
            map.insert("id".into(), id);
            map
        };
        assert_eq!(request_id(&message(json!("a"))), Some("a".into()));
        assert_eq!(request_id(&message(json!(""))), None);
        assert_eq!(request_id(&message(json!("x".repeat(101)))), None);
        assert_eq!(request_id(&message(json!(1))), None);
        assert_eq!(lexical(Path::new("/a/./b/../c")), PathBuf::from("/a/c"));
        assert_eq!(json_bytes(&json!({ "a": "é" })), 10);
    }
}
