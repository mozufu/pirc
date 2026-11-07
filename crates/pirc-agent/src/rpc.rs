//! JSONL RPC with the node (`agent/rpc.ts`): commands on stdin, responses
//! and events on stdout, and `RpcUi`, whose dialogs are
//! `extension_ui_request`s answered by `extension_ui_response`.

use std::cell::{Cell, RefCell};
use std::collections::{HashMap, VecDeque};
use std::io::Write as _;
use std::rc::Rc;
use std::time::Duration;

use pirc_protocol::{Message, UserBlock};
use serde_json::{Map, Value, json};
use tokio::sync::{Notify, mpsc, oneshot};

use crate::LocalBoxFuture;
use crate::agent::{Agent, Delivery, NameSource, Queue};
use crate::channels::NodeChannels;
use crate::ui::{Choice, DialogOptions, NotifyLevel, Ui};

/// Writes one JSON value per stdout line, in call order.
pub type Write = Rc<dyn Fn(Value)>;

/// `process.stdout.write(`${JSON.stringify(value)}\n`)`: one line, written
/// (and flushed) before this returns, so lines keep their call order.
/// Errors (the node went away) are ignored; stdin then ends too.
pub fn stdout_write() -> Write {
    Rc::new(|value: Value| {
        let mut line = serde_json::to_vec(&value).unwrap_or_default();
        line.push(b'\n');
        let mut stdout = std::io::stdout().lock();
        let _ = stdout.write_all(&line).and_then(|()| stdout.flush());
    })
}

type Responders = Rc<RefCell<HashMap<String, oneshot::Sender<Value>>>>;

/// `RpcUi`: dialogs are serialized so only one is open.
pub struct RpcUi {
    write: Write,
    pending: Responders,
    /// Dialogs waiting for their turn, in call order.
    queue: RefCell<VecDeque<u64>>,
    active: Cell<Option<u64>>,
    next_ticket: Cell<u64>,
    turn: Notify,
}

/// Gives the dialog turn up (or the place in the queue) when a dialog ends
/// or is dropped.
struct Turn<'a> {
    ui: &'a RpcUi,
    ticket: u64,
}

impl Drop for Turn<'_> {
    fn drop(&mut self) {
        let ui = self.ui;
        if ui.active.get() == Some(self.ticket) {
            ui.active.set(None);
        } else {
            ui.queue
                .borrow_mut()
                .retain(|ticket| *ticket != self.ticket);
        }
        ui.turn.notify_waiters();
    }
}

/// An `extension_ui_request` still waiting; dropping it forgets it and
/// tells the client the dialog is gone.
struct Open {
    pending: Responders,
    write: Write,
    id: String,
}

impl Drop for Open {
    fn drop(&mut self) {
        if self.pending.borrow_mut().remove(&self.id).is_some() {
            cancel_request(&self.write, &self.id);
        }
    }
}

fn cancel_request(write: &Write, target: &str) {
    write(
        json!({ "type": "extension_ui_request", "id": crate::random_uuid(),
        "method": "cancel", "targetId": target }),
    );
}

fn cancelled() -> Value {
    json!({ "cancelled": true })
}

/// JavaScript truthiness.
/// `GATEWAY_MESSAGE_LABEL`: the first line of every gateway `deliver`, so
/// a delegated task, a scheduled run or a delegation's result cannot pass
/// for the user typing in this session (L11). What the content says about
/// who approved it is the gateway's framing below the label.
pub const GATEWAY_MESSAGE_LABEL: &str = "Gateway message (pirc data, not typed by the user):";

fn gateway_message(content: &str) -> String {
    format!("{GATEWAY_MESSAGE_LABEL}\n{content}")
}

use crate::tools::js::truthy;

fn string_value(response: &Value) -> Option<String> {
    if truthy(response.get("cancelled")) {
        return None;
    }
    response
        .get("value")
        .and_then(Value::as_str)
        .map(str::to_owned)
}

impl RpcUi {
    pub fn new(write: Write) -> Rc<Self> {
        Rc::new(Self {
            write,
            pending: Rc::new(RefCell::new(HashMap::new())),
            queue: RefCell::new(VecDeque::new()),
            active: Cell::new(None),
            next_ticket: Cell::new(0),
            turn: Notify::new(),
        })
    }

    /// Queue a dialog now (call order decides the turn) and resolve with
    /// the client's response, `{cancelled: true}` when aborted or cancelled,
    /// or `{cancelled: true, timedOut: true}`.
    fn dialog(
        &self,
        request: Map<String, Value>,
        opts: DialogOptions,
    ) -> LocalBoxFuture<'_, Value> {
        let ticket = self.next_ticket.get();
        self.next_ticket.set(ticket + 1);
        self.queue.borrow_mut().push_back(ticket);
        let turn = Turn { ui: self, ticket };
        Box::pin(async move {
            loop {
                let notified = self.turn.notified();
                tokio::pin!(notified);
                notified.as_mut().enable();
                if self.active.get().is_none() && self.queue.borrow().front() == Some(&ticket) {
                    self.queue.borrow_mut().pop_front();
                    self.active.set(Some(ticket));
                    break;
                }
                notified.await;
            }
            let response = self.run(request, opts).await;
            drop(turn);
            response
        })
    }

    async fn run(&self, request: Map<String, Value>, opts: DialogOptions) -> Value {
        let DialogOptions {
            signal,
            timeout_ms,
            tool_call_id,
        } = opts;
        if signal.as_ref().is_some_and(|signal| signal.aborted()) {
            return cancelled();
        }
        let id = crate::random_uuid();
        let (sender, receiver) = oneshot::channel();
        self.pending.borrow_mut().insert(id.clone(), sender);
        let open = Open {
            pending: self.pending.clone(),
            write: self.write.clone(),
            id: id.clone(),
        };
        if let Some(signal) = &signal {
            let pending = self.pending.clone();
            let write = self.write.clone();
            let target = id.clone();
            signal.on_abort(move || {
                let sender = pending.borrow_mut().remove(&target);
                if let Some(sender) = sender {
                    let _ = sender.send(cancelled());
                    // Tell the client the dialog is gone so it can close its card.
                    cancel_request(&write, &target);
                }
            });
        }
        let timeout = timeout_ms.filter(|ms| *ms > 0);
        let mut message = Map::new();
        message.insert("type".to_owned(), json!("extension_ui_request"));
        message.insert("id".to_owned(), json!(id));
        message.extend(request);
        if let Some(ms) = timeout {
            message.insert("timeout".to_owned(), json!(ms));
        }
        // The ptc operation that asks, so clients can show it waiting there.
        if let Some(tool_call_id) = tool_call_id.filter(|id| !id.is_empty()) {
            message.insert("toolCallId".to_owned(), json!(tool_call_id));
        }
        let timer = async {
            match timeout {
                Some(ms) => tokio::time::sleep(Duration::from_millis(ms)).await,
                None => std::future::pending().await,
            }
        };
        (self.write)(Value::Object(message));
        let response = tokio::select! {
            response = receiver => response.unwrap_or_else(|_| cancelled()),
            () = timer => {
                self.pending.borrow_mut().remove(&id);
                json!({ "cancelled": true, "timedOut": true })
            }
        };
        drop(open);
        response
    }

    /// `respond`: an `extension_ui_response`.
    pub fn respond(&self, response: &Value) {
        let Some(id) = response.get("id").and_then(Value::as_str) else {
            return;
        };
        let sender = self.pending.borrow_mut().remove(id);
        if let Some(sender) = sender {
            let _ = sender.send(response.clone());
        }
    }

    /// `cancelAll`.
    pub fn cancel_all(&self) {
        let senders: Vec<_> = self.pending.borrow_mut().drain().collect();
        for (_, sender) in senders {
            let _ = sender.send(cancelled());
        }
    }
}

fn request(method: &str, fields: Vec<(&str, Value)>) -> Map<String, Value> {
    let mut map = Map::new();
    map.insert("method".to_owned(), json!(method));
    for (key, value) in fields {
        map.insert(key.to_owned(), value);
    }
    map
}

impl Ui for RpcUi {
    fn select<'a>(
        &'a self,
        title: &'a str,
        options: &'a [String],
        opts: DialogOptions,
    ) -> LocalBoxFuture<'a, Option<String>> {
        let dialog = self.dialog(
            request(
                "select",
                vec![("title", json!(title)), ("options", json!(options))],
            ),
            opts,
        );
        Box::pin(async move { string_value(&dialog.await) })
    }

    fn choose<'a>(
        &'a self,
        title: &'a str,
        options: &'a [Choice],
        multiple: bool,
        opts: DialogOptions,
    ) -> LocalBoxFuture<'a, Option<Vec<String>>> {
        let labels: Vec<&str> = options.iter().map(|o| o.label.as_str()).collect();
        let descriptions: Vec<&str> = options
            .iter()
            .map(|o| o.description.as_deref().unwrap_or(""))
            .collect();
        let mut fields = vec![
            ("title", json!(title)),
            ("options", json!(labels)),
            ("optionDescriptions", json!(descriptions)),
        ];
        if multiple {
            fields.push(("multiple", json!(true)));
        }
        let dialog = self.dialog(request("select", fields), opts);
        Box::pin(async move {
            let response = dialog.await;
            if truthy(response.get("cancelled")) {
                return None;
            }
            if let Some(values) = response.get("values").and_then(Value::as_array) {
                return Some(
                    values
                        .iter()
                        .filter_map(Value::as_str)
                        .map(str::to_owned)
                        .collect(),
                );
            }
            response
                .get("value")
                .and_then(Value::as_str)
                .map(|value| vec![value.to_owned()])
        })
    }

    fn confirm<'a>(
        &'a self,
        title: &'a str,
        message: &'a str,
        opts: DialogOptions,
    ) -> LocalBoxFuture<'a, Option<bool>> {
        let dialog = self.dialog(
            request(
                "confirm",
                vec![("title", json!(title)), ("message", json!(message))],
            ),
            opts,
        );
        Box::pin(async move {
            let response = dialog.await;
            if truthy(response.get("cancelled")) {
                None
            } else {
                Some(truthy(response.get("confirmed")))
            }
        })
    }

    fn input<'a>(
        &'a self,
        title: &'a str,
        placeholder: Option<&'a str>,
        opts: DialogOptions,
    ) -> LocalBoxFuture<'a, Option<String>> {
        let mut fields = vec![("title", json!(title))];
        if let Some(placeholder) = placeholder {
            fields.push(("placeholder", json!(placeholder)));
        }
        let dialog = self.dialog(request("input", fields), opts);
        Box::pin(async move { string_value(&dialog.await) })
    }

    fn editor<'a>(
        &'a self,
        title: &'a str,
        prefill: Option<&'a str>,
        opts: DialogOptions,
    ) -> LocalBoxFuture<'a, Option<String>> {
        let mut fields = vec![("title", json!(title))];
        if let Some(prefill) = prefill {
            fields.push(("prefill", json!(prefill)));
        }
        let dialog = self.dialog(request("editor", fields), opts);
        Box::pin(async move { string_value(&dialog.await) })
    }

    fn notify(&self, message: &str, level: NotifyLevel) {
        (self.write)(
            json!({ "type": "extension_ui_request", "id": crate::random_uuid(),
            "method": "notify", "message": message, "notifyType": level.as_str() }),
        );
    }

    fn set_status(&self, key: &str, text: Option<&str>) {
        let mut message = json!({ "type": "extension_ui_request", "id": crate::random_uuid(),
            "method": "setStatus", "statusKey": key });
        if let Some(text) = text {
            message["statusText"] = json!(text);
        }
        (self.write)(message);
    }

    fn set_widget(&self, key: &str, lines: Option<&[String]>) {
        let mut message = Map::new();
        message.insert("type".to_owned(), json!("extension_ui_request"));
        message.insert("id".to_owned(), json!(crate::random_uuid()));
        message.insert("method".to_owned(), json!("setWidget"));
        message.insert("widgetKey".to_owned(), json!(key));
        if let Some(lines) = lines {
            message.insert("widgetLines".to_owned(), json!(lines));
        }
        message.insert("widgetPlacement".to_owned(), json!("aboveEditor"));
        (self.write)(Value::Object(message));
    }
}

/// A command field as text ([`js::MISSING`] when absent).
pub(crate) fn js_string(value: Option<&Value>) -> String {
    crate::tools::js::shown(value)
}

/// `images(command)`: image blocks the command carries.
fn images(command: &Value) -> Vec<UserBlock> {
    let Some(items) = command.get("images").and_then(Value::as_array) else {
        return Vec::new();
    };
    items
        .iter()
        .filter(|image| image.get("type").and_then(Value::as_str) == Some("image"))
        .filter_map(|image| {
            let data = image.get("data")?.as_str()?;
            let mime_type = match image.get("mimeType") {
                None | Some(Value::Null) => "image/png".to_owned(),
                Some(other) => js_string(Some(other)),
            };
            Some(UserBlock::Image {
                data: data.to_owned(),
                mime_type,
            })
        })
        .collect()
}

/// Largest `get_context` answer on the RPC line (512 KiB).
const CONTEXT_MAX_BYTES: usize = 512 * 1024;

/// The agent's RPC surface as `handleCommand` drives it: [`Agent`], or a
/// stand-in in tests.
pub(crate) trait Commands: 'static {
    fn refresh_models(&self) -> LocalBoxFuture<'_, ()>;
    fn is_running(&self) -> bool;
    fn resume_branch(self: &Rc<Self>) -> Result<(), String> {
        Err("Branch resume is unsupported".into())
    }
    fn prompt(self: &Rc<Self>, text: String, images: Vec<UserBlock>) -> Result<(), String>;
    fn prompt_admitted(
        self: &Rc<Self>,
        text: String,
        images: Vec<UserBlock>,
    ) -> LocalBoxFuture<'_, Result<(), String>> {
        let result = self.prompt(text, images);
        Box::pin(async move { result })
    }
    fn steer(self: &Rc<Self>, text: String, images: Vec<UserBlock>);
    fn follow_up(self: &Rc<Self>, text: String, images: Vec<UserBlock>);
    fn abort(self: &Rc<Self>);
    fn idle(&self) -> LocalBoxFuture<'_, ()>;
    fn send_now(self: &Rc<Self>, queue: Queue, index: usize, text: &str) -> Result<(), String>;
    fn clear_queue(self: &Rc<Self>) -> Value;
    fn state(&self) -> Value;
    fn all_messages(&self) -> Vec<Message>;
    fn compact(
        self: &Rc<Self>,
        instructions: Option<String>,
    ) -> LocalBoxFuture<'_, Result<Value, String>>;
    fn command_list(&self) -> Vec<Value>;
    fn available_models(&self) -> Vec<Value>;
    fn set_model(&self, provider: &str, id: &str) -> Result<(), String>;
    fn set_thinking(&self, level: &str) -> Result<(), String>;
    fn set_approval_mode(self: &Rc<Self>, mode: &str) -> Result<(), String>;
    fn set_role(&self, name: &str) -> Result<(), String>;
    fn set_name(&self, name: &str, source: NameSource) -> Result<(), String>;
    fn last_context(&self) -> Option<Value>;
    fn panel_state(self: &Rc<Self>) -> Value;
    fn deliver(
        self: &Rc<Self>,
        delivery: Delivery,
        trigger_turn: bool,
        follow_up: bool,
    ) -> Result<(), String>;
    /// A feature's extra command (`feature.rpc`), if one answers `kind`.
    fn feature_rpc<'a>(
        self: &'a Rc<Self>,
        _kind: &'a str,
        _command: &'a Value,
    ) -> Option<LocalBoxFuture<'a, Result<Option<Value>, String>>> {
        None
    }
}

impl Commands for Agent {
    fn resume_branch(self: &Rc<Self>) -> Result<(), String> {
        Agent::resume_branch(self)
    }
    fn refresh_models(&self) -> LocalBoxFuture<'_, ()> {
        Box::pin(Agent::refresh_models(self))
    }
    fn is_running(&self) -> bool {
        Agent::is_running(self)
    }
    fn prompt(self: &Rc<Self>, text: String, images: Vec<UserBlock>) -> Result<(), String> {
        Agent::prompt(self, text, images)
    }
    fn prompt_admitted(
        self: &Rc<Self>,
        text: String,
        images: Vec<UserBlock>,
    ) -> LocalBoxFuture<'_, Result<(), String>> {
        Box::pin(Agent::prompt_admitted(self, text, images))
    }
    fn steer(self: &Rc<Self>, text: String, images: Vec<UserBlock>) {
        Agent::steer(self, text, images);
    }
    fn follow_up(self: &Rc<Self>, text: String, images: Vec<UserBlock>) {
        Agent::follow_up(self, text, images);
    }
    fn abort(self: &Rc<Self>) {
        Agent::abort(self);
    }
    fn idle(&self) -> LocalBoxFuture<'_, ()> {
        Box::pin(Agent::idle(self))
    }
    fn send_now(self: &Rc<Self>, queue: Queue, index: usize, text: &str) -> Result<(), String> {
        Agent::send_now(self, queue, index, text)
    }
    fn clear_queue(self: &Rc<Self>) -> Value {
        Agent::clear_queue(self)
    }
    fn state(&self) -> Value {
        Agent::state(self)
    }
    fn all_messages(&self) -> Vec<Message> {
        Agent::all_messages(self)
    }
    fn compact(
        self: &Rc<Self>,
        instructions: Option<String>,
    ) -> LocalBoxFuture<'_, Result<Value, String>> {
        Box::pin(Agent::compact(self, instructions))
    }
    fn command_list(&self) -> Vec<Value> {
        Agent::command_list(self)
    }
    fn available_models(&self) -> Vec<Value> {
        Agent::available_models(self)
    }
    fn set_model(&self, provider: &str, id: &str) -> Result<(), String> {
        Agent::set_model(self, provider, id)
    }
    fn set_thinking(&self, level: &str) -> Result<(), String> {
        Agent::set_thinking(self, level)
    }
    fn set_approval_mode(self: &Rc<Self>, mode: &str) -> Result<(), String> {
        Agent::set_approval_mode(self, mode)
    }
    fn set_role(&self, name: &str) -> Result<(), String> {
        Agent::set_role(self, name)
    }
    fn set_name(&self, name: &str, source: NameSource) -> Result<(), String> {
        Agent::set_name(self, name, source)
    }
    fn last_context(&self) -> Option<Value> {
        Agent::last_context(self)
    }
    fn panel_state(self: &Rc<Self>) -> Value {
        Agent::panel_state(self)
    }
    fn deliver(
        self: &Rc<Self>,
        delivery: Delivery,
        trigger_turn: bool,
        follow_up: bool,
    ) -> Result<(), String> {
        Agent::deliver(self, delivery, trigger_turn, follow_up)
    }
    fn feature_rpc<'a>(
        self: &'a Rc<Self>,
        kind: &'a str,
        command: &'a Value,
    ) -> Option<LocalBoxFuture<'a, Result<Option<Value>, String>>> {
        let feature = self
            .features()
            .iter()
            .find(|feature| feature.rpc_types().contains(&kind))?
            .clone();
        Some(Box::pin(
            async move { feature.rpc(self, kind, command).await },
        ))
    }
}

/// `handleCommand`: one RPC command; `Ok(Some(data))` is the response's
/// `data`, `Err` its `error`.
pub async fn handle_command(agent: &Rc<Agent>, command: &Value) -> Result<Option<Value>, String> {
    dispatch(agent, command).await
}

pub(crate) async fn dispatch<A: Commands>(
    agent: &Rc<A>,
    command: &Value,
) -> Result<Option<Value>, String> {
    let kind = command.get("type").and_then(Value::as_str);
    let message = command
        .get("message")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_owned();
    if matches!(
        kind,
        Some("prompt" | "set_model" | "get_available_models" | "compact")
    ) {
        agent.refresh_models().await;
    }
    match kind {
        Some("resume_branch") => {
            agent.resume_branch()?;
            Ok(None)
        }
        Some("prompt") => {
            if agent.is_running() {
                match command.get("streamingBehavior").and_then(Value::as_str) {
                    Some("followUp") => agent.follow_up(message, images(command)),
                    Some("steer") => agent.steer(message, images(command)),
                    _ => return Err("Agent is already running; use steer or follow_up".to_owned()),
                }
            } else {
                agent.prompt_admitted(message, images(command)).await?;
            }
            Ok(None)
        }
        Some("steer") => {
            if agent.is_running() {
                agent.steer(message, images(command));
            } else {
                agent.prompt_admitted(message, images(command)).await?;
            }
            Ok(None)
        }
        Some("follow_up") => {
            if agent.is_running() {
                agent.follow_up(message, images(command));
            } else {
                agent.prompt_admitted(message, images(command)).await?;
            }
            Ok(None)
        }
        Some("abort") => {
            agent.abort();
            agent.idle().await;
            Ok(None)
        }
        Some("send_now") => {
            let queue = match command.get("queue").and_then(Value::as_str) {
                Some("steering") => Queue::Steering,
                Some("followUp") => Queue::FollowUp,
                _ => return Err("send_now needs queue: steering or followUp".to_owned()),
            };
            let index = command
                .get("index")
                .and_then(Value::as_f64)
                .filter(|index| index.fract() == 0.0 && *index >= 0.0)
                .ok_or("send_now needs a non-negative integer index")?;
            // Saturates: an index past the queue is "no longer queued".
            agent.send_now(queue, index as usize, &message)?;
            Ok(None)
        }
        Some("clear_queue") => Ok(Some(agent.clear_queue())),
        Some("get_state") => Ok(Some(agent.state())),
        Some("get_messages") => Ok(Some(json!({ "messages": agent.all_messages() }))),
        Some("compact") => {
            let instructions = command
                .get("customInstructions")
                .and_then(Value::as_str)
                .map(str::to_owned);
            agent.compact(instructions).await.map(Some)
        }
        Some("get_commands") => Ok(Some(json!({ "commands": agent.command_list() }))),
        Some("get_available_models") => Ok(Some(json!({ "models": agent.available_models() }))),
        Some("set_model") => {
            let (Some(provider), Some(model_id)) = (
                command.get("provider").and_then(Value::as_str),
                command.get("modelId").and_then(Value::as_str),
            ) else {
                return Err("set_model needs provider and modelId".to_owned());
            };
            agent.set_model(provider, model_id)?;
            Ok(None)
        }
        Some("set_thinking_level") => {
            agent.set_thinking(&js_string(command.get("level")))?;
            Ok(None)
        }
        Some("set_approval_mode") => {
            agent.set_approval_mode(&js_string(command.get("mode")))?;
            Ok(None)
        }
        Some("set_role") => {
            // A delegated session's role, before its task arrives (node/runner.ts deliver).
            agent.set_role(&js_string(command.get("role")))?;
            Ok(None)
        }
        Some("set_session_name") => {
            let name = match command.get("name") {
                None | Some(Value::Null) => String::new(),
                name => js_string(name),
            };
            agent.set_name(&name, NameSource::User)?;
            Ok(None)
        }
        Some("get_context") => {
            // Large prompts use the same node-local disk snapshot, never overflow the RPC line.
            // A NaN `maxBytes` clamps to 0: nothing fits, as before.
            let limit = match command.get("maxBytes").and_then(Value::as_f64) {
                Some(max) => max.clamp(0.0, CONTEXT_MAX_BYTES as f64) as usize,
                None => CONTEXT_MAX_BYTES,
            };
            let context = agent.last_context().filter(|context| {
                serde_json::to_vec(context).is_ok_and(|bytes| bytes.len() < limit)
            });
            Ok(Some(context.unwrap_or(Value::Null)))
        }
        Some("get_panel_state") => Ok(Some(agent.panel_state())),
        Some("deliver") => {
            // A message from the gateway (a delegated task, news of a delegation):
            // shown in the chat, never the user's words, and it wakes the agent.
            let pushed = command.get("message");
            let field = |name: &str| pushed.and_then(|pushed| pushed.get(name));
            let (Some(custom_type), Some(content)) = (
                field("customType").and_then(Value::as_str),
                field("content").and_then(Value::as_str),
            ) else {
                return Err("deliver needs message.customType and message.content".to_owned());
            };
            let details = field("details")
                .filter(|details| details.is_object() || details.is_array())
                .cloned();
            // `wake: false` adds trusted context (an environment change) without a turn.
            let wake = command.get("wake").and_then(Value::as_bool).unwrap_or(true);
            agent.deliver(
                Delivery {
                    custom_type: custom_type.to_owned(),
                    content: gateway_message(content),
                    display: true,
                    details,
                },
                wake,
                true,
            )?;
            Ok(None)
        }
        _ => match kind.and_then(|kind| agent.feature_rpc(kind, command)) {
            Some(handler) => handler.await,
            None => Err(format!(
                "Unsupported command: {}",
                js_string(command.get("type"))
            )),
        },
    }
}

/// `line.trim()` is empty (JavaScript's whitespace, BOM included).
pub(crate) fn blank(line: &str) -> bool {
    line.chars().all(|c| c.is_whitespace() || c == '\u{feff}')
}

/// Stands in for a stdin line dropped for its length
/// ([`crate::run::STDIN_LINE_MAX_BYTES`]); not valid JSON, so nothing the
/// node sends can mean it.
pub const LINE_TOO_LONG: &str = "\u{0}line too long";

/// `serveRpc`: serve JSONL RPC until the input ends. `Err` is what would
/// have been thrown out of the loop (a `null` command line), which ends the
/// process without its shutdown.
pub async fn serve_rpc(
    agent: Rc<Agent>,
    ui: Rc<RpcUi>,
    channels: Rc<NodeChannels>,
    write: Write,
    lines: &mut mpsc::UnboundedReceiver<String>,
) -> Result<(), String> {
    serve(agent, ui, channels, write, lines).await
}

pub(crate) async fn serve<A: Commands>(
    agent: Rc<A>,
    ui: Rc<RpcUi>,
    channels: Rc<NodeChannels>,
    write: Write,
    lines: &mut mpsc::UnboundedReceiver<String>,
) -> Result<(), String> {
    while let Some(line) = lines.recv().await {
        if blank(&line) {
            continue;
        }
        if line == LINE_TOO_LONG {
            write(
                json!({ "type": "response", "command": "parse", "success": false,
                "error": "Line too long" }),
            );
            continue;
        }
        let Ok(command) = serde_json::from_str::<Value>(&line) else {
            write(
                json!({ "type": "response", "command": "parse", "success": false,
                "error": "Invalid JSON" }),
            );
            continue;
        };
        if command.is_null() {
            return Err("null is not an object (evaluating 'command.type')".to_owned());
        }
        let kind = command.get("type").and_then(Value::as_str).unwrap_or("");
        match kind {
            "extension_ui_response" => {
                ui.respond(&command);
                // What the answer resolved runs before the next line is read:
                // a dialog that lost a race is cancelled before a late answer
                // to it is read.
                tokio::task::yield_now().await;
                continue;
            }
            "team_result" => {
                crate::features::team::channel::parent_channel().receive(&command);
                tokio::task::yield_now().await;
                continue;
            }
            _ if channels.route(kind, &command) => {
                tokio::task::yield_now().await;
                continue;
            }
            _ => {}
        }
        let agent = agent.clone();
        let write = write.clone();
        tokio::task::spawn_local(async move {
            let outcome = dispatch(&agent, &command).await;
            write(response(&command, outcome));
        });
        // Like the TS event loop, let the command start before the next line.
        tokio::task::yield_now().await;
    }
    Ok(())
}

/// The `response` line for a command's outcome.
pub(crate) fn response(command: &Value, outcome: Result<Option<Value>, String>) -> Value {
    let mut out = Map::new();
    out.insert("type".to_owned(), json!("response"));
    if let Some(id) = command.get("id") {
        out.insert("id".to_owned(), id.clone());
    }
    if let Some(kind) = command.get("type") {
        out.insert("command".to_owned(), kind.clone());
    }
    match outcome {
        Ok(data) => {
            out.insert("success".to_owned(), json!(true));
            if let Some(data) = data {
                out.insert("data".to_owned(), data);
            }
        }
        Err(error) => {
            if error == crate::agent::ADMISSION_OUTCOME_UNKNOWN {
                out.insert("errorCode".to_owned(), json!("admission_outcome_unknown"));
            }
            out.insert("success".to_owned(), json!(false));
            out.insert("error".to_owned(), json!(error));
        }
    }
    Value::Object(out)
}

#[cfg(test)]
mod tests;
