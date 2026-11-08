//! The node link: one outbound WebSocket to the gateway's `/node/connect`
//! (`node/runtime.ts` `connect`, the link half of `startNode`).
//!
//! Layout: [`LinkSender`], what every module sends frames with, is
//! implemented here. The client itself, [`run`], is owned by **core**.
//!
//! Hooks the client calls (each owned by the module named):
//!
//! | event | calls |
//! | --- | --- |
//! | socket open | send `register` (protocol, role, workspaces with roles), start the 15 s heartbeat |
//! | `registered` | [`LinkSender::set_registered`], `agent_gateway.connect()` (runner), `mirror.connect(mirrors)` (panels), send `activity`, `models.set(models, inference)` |
//! | `models` | `models.set(models, inference)` |
//! | `model_delta`/`model_end`/`model_error` | `inference.receive(frame)` (runner) |
//! | `request` | `router.handle` in a task, then send `response` |
//! | `terminal_open`/`terminal_input`/`terminal_close` | `streams.open`/`input`/`close` (panels) |
//! | `agent_response` | `agent_gateway.receive(...)` (runner) |
//! | `memory_mirror_ack` | `mirror.receive(ledger_key, watermark)` (panels) |
//! | socket closed | [`LinkSender::close`], `agent_gateway.disconnect()`, `mirror.disconnect()`, `inference.disconnect()`, `streams.close_all()`, reconnect in 3 s |
//!
//! Frames before `registered` are dropped; a frame that is not JSON closes
//! the socket with 1007 "invalid JSON"; one that does not parse as a
//! [`pirc_protocol::GatewayMessage`] is ignored; `registration_error` is
//! only logged.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use futures_util::{FutureExt, SinkExt, StreamExt};
use pirc_protocol::{
    GatewayMessage, INFERENCE_BUFFER_MAX_BYTES, INVALID_NODE_CREDENTIALS_CLOSE,
    NODE_FRAME_MAX_BYTES, NODE_PROTOCOL_VERSION, NodeMessage, PROTOCOL_MISMATCH_CLOSE,
    RegisteredWorkspace, Registration, SessionActivity, SessionRun, TerminalKind, WorkspaceRole,
};
use serde_json::Value;
use tokio::sync::{mpsc, watch};
use tokio_tungstenite::Connector;
use tokio_tungstenite::connect_async_tls_with_config;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::HeaderValue;
use tokio_tungstenite::tungstenite::protocol::frame::coding::CloseCode;
use tokio_tungstenite::tungstenite::protocol::{CloseFrame, WebSocketConfig};
use url::Url;

use crate::services::Node;
use crate::store::{RunStatus, Store};

/// Reconnect delay after the socket closes, whatever the reason (TS).
pub const RECONNECT_MS: u64 = 3_000;
/// `heartbeat` interval while the socket is open (the gateway drops a
/// node silent for 45 s).
pub const HEARTBEAT_MS: u64 = 15_000;
/// Run and lease changes within this window go out as one `activity` frame.
pub const ACTIVITY_COALESCE_MS: u64 = 100;
/// How long the link waits for the gateway's answer to its own close frame
/// before dropping the socket. `ws` would wait 30 s, but the TS node ran on
/// Bun, whose client closed the connection right after the close frame (the
/// recorded reconnect after "invalid JSON" came well within the gateway's
/// 20 s); a short grace keeps the handshake for a gateway that answers.
pub const CLOSE_HANDSHAKE_MS: u64 = 1_000;
/// Browser live-view frames are skipped while this much is queued on the link.
pub const BROWSER_FRAME_BACKLOG_BYTES: usize = 4 * 1024 * 1024;

/// What every module sends frames to the gateway with. Cheap to clone; the
/// frames of one sender keep their order.
///
/// Semantics of the TS socket: a frame is written only while a socket is
/// open; [`LinkSender::buffered_amount`] is `ws`'s `bufferedAmount` (bytes
/// queued but not yet written).
#[derive(Clone, Default)]
pub struct LinkSender {
    state: Arc<Mutex<LinkState>>,
}

#[derive(Default)]
struct LinkState {
    socket: Option<Socket>,
    registered: bool,
    next_id: u64,
}

struct Socket {
    id: u64,
    queue: mpsc::UnboundedSender<String>,
    buffered: Arc<AtomicUsize>,
}

/// The frames one socket's writer sends, in order (core's writer task).
pub struct LinkQueue {
    pub id: u64,
    frames: mpsc::UnboundedReceiver<String>,
    buffered: Arc<AtomicUsize>,
}

impl LinkQueue {
    /// The next frame to write; `None` once the socket was replaced or closed.
    pub async fn recv(&mut self) -> Option<String> {
        self.frames.recv().await
    }

    /// `frame` (from [`LinkQueue::recv`]) has been written to the socket.
    pub fn written(&self, frame: &str) {
        self.buffered.fetch_sub(frame.len(), Ordering::AcqRel);
    }
}

impl LinkSender {
    pub fn new() -> Self {
        Self::default()
    }

    fn lock(&self) -> MutexGuard<'_, LinkState> {
        self.state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// A new socket is open (core): it replaces any other, unregistered
    /// until [`LinkSender::set_registered`].
    pub fn open(&self) -> LinkQueue {
        let mut state = self.lock();
        state.next_id += 1;
        let (queue, frames) = mpsc::unbounded_channel();
        let buffered = Arc::new(AtomicUsize::new(0));
        state.socket = Some(Socket {
            id: state.next_id,
            queue,
            buffered: buffered.clone(),
        });
        state.registered = false;
        LinkQueue {
            id: state.next_id,
            frames,
            buffered,
        }
    }

    /// The gateway answered `registered` on socket `id` (core).
    pub fn set_registered(&self, id: u64) {
        let mut state = self.lock();
        if state.socket.as_ref().is_some_and(|socket| socket.id == id) {
            state.registered = true;
        }
    }

    /// Socket `id` closed (core). False when another socket had already
    /// replaced it: its close is not the link's.
    pub fn close(&self, id: u64) -> bool {
        let mut state = self.lock();
        if !state.socket.as_ref().is_some_and(|socket| socket.id == id) {
            return false;
        }
        state.socket = None;
        state.registered = false;
        true
    }

    pub fn is_registered(&self) -> bool {
        let state = self.lock();
        state.registered && state.socket.is_some()
    }

    /// Bytes queued on the open socket and not yet written.
    pub fn buffered_amount(&self) -> usize {
        self.lock()
            .socket
            .as_ref()
            .map_or(0, |socket| socket.buffered.load(Ordering::Acquire))
    }

    fn queue(socket: &Socket, frame: String) -> bool {
        socket.buffered.fetch_add(frame.len(), Ordering::AcqRel);
        let len = frame.len();
        if socket.queue.send(frame).is_err() {
            socket.buffered.fetch_sub(len, Ordering::AcqRel);
            return false;
        }
        true
    }

    /// `send`: written if a socket is open, registered or not (`register`,
    /// `heartbeat`, `response`, `event`, terminal frames); dropped
    /// otherwise. Returns whether it was queued.
    pub fn send(&self, message: &NodeMessage) -> bool {
        let state = self.lock();
        let Some(socket) = &state.socket else {
            return false;
        };
        Self::queue(socket, frame(message))
    }

    /// `sendAgentFrame`: frames that need a registered link (agent
    /// requests, mirrored memory). False when there is none or the frame is
    /// larger than [`NODE_FRAME_MAX_BYTES`], so the caller can answer or
    /// retry later.
    pub fn send_agent_frame(&self, message: &NodeMessage) -> bool {
        let state = self.lock();
        let (Some(socket), true) = (&state.socket, state.registered) else {
            return false;
        };
        let frame = frame(message);
        frame.len() <= NODE_FRAME_MAX_BYTES && Self::queue(socket, frame)
    }

    /// The inference relay's `send` (`model_start`, `model_cancel`): as
    /// [`LinkSender::send_agent_frame`], and false when the frame would
    /// push the socket's backlog past [`INFERENCE_BUFFER_MAX_BYTES`].
    pub fn send_inference(&self, message: &NodeMessage) -> bool {
        let state = self.lock();
        let (Some(socket), true) = (&state.socket, state.registered) else {
            return false;
        };
        let frame = frame(message);
        frame.len() <= NODE_FRAME_MAX_BYTES
            && socket.buffered.load(Ordering::Acquire) + frame.len() <= INFERENCE_BUFFER_MAX_BYTES
            && Self::queue(socket, frame)
    }
}

fn frame(message: &NodeMessage) -> String {
    serde_json::to_string(message).expect("node frames serialize")
}

/// Connect to `config.daemon_url` and keep connected until the node closes
/// (owner: **core**). Reproduce `runtime.ts`:
///
/// - URL: `/node/connect` resolved against the daemon URL; one with
///   username, password, query or fragment is refused ("Invalid daemon
///   URL"). Headers `x-pirc-node-id` and `authorization: Bearer <token>`;
///   at most [`NODE_FRAME_MAX_BYTES`] per message; `wss://` through rustls
///   (ring) with the platform's roots.
/// - On open: `register` (protocol [`pirc_protocol::NODE_PROTOCOL_VERSION`],
///   role, the store's workspaces of this node with `roles` from
///   `pirc_agent::roles` for directory workspaces, left out when they fail
///   to load), then `heartbeat` every [`HEARTBEAT_MS`].
/// - Events: every [`crate::events::EventHub`] event goes out as `event`
///   while registered (none are replayed after a reconnect).
/// - Activity: after `registered`, and [`ACTIVITY_COALESCE_MS`] after the
///   first `node.activity` notification (one timer, not reset), send
///   `activity` with every open run (`store.active_runs()`) and every
///   write-lease holder (`writes.holders()`, `writeLease: true`).
/// - The hooks of the module table above; on close, reconnect after
///   [`RECONNECT_MS`] unless the node is closing (4426 is logged as a
///   protocol mismatch first).
pub async fn run(node: Node) {
    let endpoint = match endpoint(&node.config.daemon_url) {
        Ok(endpoint) => endpoint,
        Err(error) => {
            crate::log::error(&error);
            return;
        }
    };
    let link = node.link.clone();
    let _events = node.events.subscribe_all(Arc::new(move |event| {
        if link.is_registered() {
            link.send(&NodeMessage::Event {
                session_id: event.session_id.clone(),
                event: event.to_map(),
            });
        }
    }));
    let activity = tokio::spawn(coalesce_activity(node.clone()));
    let mut terminated = node.terminated();
    // A refusal of the node's credentials is reported once, not on every
    // retry, until the node registers again.
    let mut refusal_reported = false;
    loop {
        if node.closing() {
            break;
        }
        let ended = connect(&node, &endpoint, &mut terminated).await;
        if ended.registered {
            refusal_reported = false;
        }
        if ended.close_code == Some(INVALID_NODE_CREDENTIALS_CLOSE) && !refusal_reported {
            refusal_reported = true;
            crate::log::error(&format!(
                "the gateway refused this node's credentials (closed {INVALID_NODE_CREDENTIALS_CLOSE}): \
                 PIRC_NODE_ID and PIRC_NODE_TOKEN must match an entry of the gateway's \
                 PIRC_NODE_TOKENS; retrying every {} s without logging this again",
                RECONNECT_MS / 1000
            ));
        }
        if node.closing() || *terminated.borrow() {
            break;
        }
        tokio::select! {
            () = tokio::time::sleep(Duration::from_millis(RECONNECT_MS)) => {}
            () = stopped(&mut terminated) => break,
        }
    }
    activity.abort();
}

/// `new URL('/node/connect', daemonUrl)`, refusing credentials, a query or
/// a fragment ("Invalid daemon URL").
pub fn endpoint(daemon_url: &str) -> Result<Url, String> {
    let invalid = || "Invalid daemon URL".to_owned();
    let url = Url::parse(daemon_url)
        .and_then(|base| base.join("/node/connect"))
        .map_err(|_| invalid())?;
    if !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some_and(|query| !query.is_empty())
        || url.fragment().is_some_and(|fragment| !fragment.is_empty())
    {
        return Err(invalid());
    }
    Ok(url)
}

/// The TLS settings of `wss://`: rustls with ring and the platform's roots.
fn tls() -> Result<Arc<rustls::ClientConfig>, String> {
    use rustls_platform_verifier::BuilderVerifierExt;
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let config = rustls::ClientConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .map_err(|error| error.to_string())?
        .with_platform_verifier()
        .map_err(|error| error.to_string())?
        .with_no_client_auth();
    Ok(Arc::new(config))
}

/// How a [`connect`] ended.
#[derive(Default)]
struct Ended {
    /// The gateway's close code, if it sent one.
    close_code: Option<u16>,
    /// The gateway accepted the registration on this connection.
    registered: bool,
}

/// One connection, from the handshake until the socket closes or the node
/// terminates it.
async fn connect(node: &Node, endpoint: &Url, terminated: &mut watch::Receiver<bool>) -> Ended {
    let mut request = match endpoint.as_str().into_client_request() {
        Ok(request) => request,
        Err(error) => {
            crate::log::error(&format!("node transport failure: {error}"));
            return Ended::default();
        }
    };
    let headers = request.headers_mut();
    for (name, value) in [
        ("x-pirc-node-id", node.config.node_id.clone()),
        (
            "authorization",
            format!("Bearer {}", node.config.node_token),
        ),
    ] {
        match HeaderValue::from_str(&value) {
            Ok(value) => {
                headers.insert(name, value);
            }
            Err(_) => {
                crate::log::error("node transport failure: invalid node credentials header");
                return Ended::default();
            }
        }
    }
    let connector = if endpoint.scheme() == "wss" {
        match tls() {
            Ok(config) => Some(Connector::Rustls(config)),
            Err(error) => {
                crate::log::error(&format!("node transport failure: TLS: {error}"));
                return Ended::default();
            }
        }
    } else {
        Some(Connector::Plain)
    };
    let config = WebSocketConfig::default()
        .max_message_size(Some(NODE_FRAME_MAX_BYTES))
        .max_frame_size(Some(NODE_FRAME_MAX_BYTES));
    let opened = tokio::select! {
        opened = connect_async_tls_with_config(request, Some(config), true, connector) => opened,
        () = stopped(terminated) => return Ended::default(),
    };
    let socket = match opened {
        Ok((socket, _)) => socket,
        Err(error) => {
            crate::log::warn(&format!("node transport failure: {error}"));
            return Ended::default();
        }
    };
    // Reading roles and git files is blocking IO, off the async task.
    let registration = tokio::select! {
        registration = registration(node) => registration,
        () = stopped(terminated) => return Ended::default(),
    };
    let (mut sink, mut stream) = socket.split();
    let mut queue = node.link.open();
    let id = queue.id;
    node.link.send(&NodeMessage::Register(registration));
    let start = tokio::time::Instant::now() + Duration::from_millis(HEARTBEAT_MS);
    let mut heartbeat = tokio::time::interval_at(start, Duration::from_millis(HEARTBEAT_MS));
    let mut registered = false;
    let mut close_code: Option<u16> = None;
    let mut close_reason = String::new();
    // After our own close frame, nothing more is read or sent but the
    // closing handshake, which the gateway gets [`CLOSE_HANDSHAKE_MS`] to
    // finish.
    let mut closing = false;
    let handshake = tokio::time::sleep(Duration::MAX);
    tokio::pin!(handshake);
    loop {
        tokio::select! {
            () = &mut handshake, if closing => break,
            frame = queue.recv(), if !closing => {
                let Some(frame) = frame else { break };
                let sent = sink.send(Message::text(frame.clone())).await;
                queue.written(&frame);
                if let Err(error) = sent {
                    crate::log::warn(&format!("node transport failure: {error}"));
                    break;
                }
            }
            _ = heartbeat.tick(), if !closing => {
                node.link.send(&NodeMessage::Heartbeat);
            }
            () = stopped(terminated) => {
                // `socket.terminate()`: no close frame.
                break;
            }
            message = stream.next() => {
                let text = match message {
                    None => break,
                    Some(Err(error)) => {
                        crate::log::warn(&format!("node transport failure: {error}"));
                        break;
                    }
                    Some(Ok(Message::Close(frame))) => {
                        if let Some(frame) = frame {
                            close_code = Some(frame.code.into());
                            close_reason = frame.reason.to_string();
                        }
                        if closing {
                            break;
                        }
                        continue;
                    }
                    Some(Ok(Message::Text(text))) => text.to_string(),
                    // `raw.toString()`: binary frames are read as text too.
                    Some(Ok(Message::Binary(bytes))) => String::from_utf8_lossy(&bytes).into_owned(),
                    Some(Ok(_)) => continue,
                };
                if closing {
                    continue;
                }
                let Ok(value) = serde_json::from_str::<Value>(&text) else {
                    closing = true;
                    handshake
                        .as_mut()
                        .reset(tokio::time::Instant::now() + Duration::from_millis(CLOSE_HANDSHAKE_MS));
                    let frame = CloseFrame {
                        code: CloseCode::Invalid,
                        reason: "invalid JSON".into(),
                    };
                    if sink.send(Message::Close(Some(frame))).await.is_err() {
                        break;
                    }
                    continue;
                };
                let Some(message) = gateway_message(value) else {
                    continue;
                };
                handle(node, id, &mut registered, message).await;
            }
        }
    }
    drop(sink);
    drop(stream);
    let ended = Ended {
        close_code,
        registered,
    };
    if !node.link.close(id) {
        return ended;
    }
    node.replace_modes(Vec::new()).await;
    node.agent_gateway.disconnect();
    node.mirror.disconnect();
    node.inference.disconnect();
    node.streams.close_all();
    if close_code == Some(PROTOCOL_MISMATCH_CLOSE) {
        crate::log::error(&format!(
            "daemon rejected this node protocol version; upgrade the daemon and node together: {close_reason}"
        ));
    }
    ended
}

/// A frame the link schema accepts, else `None` (ignored).
fn gateway_message(value: Value) -> Option<GatewayMessage> {
    let is_modes = value.get("type").and_then(Value::as_str) == Some("modes");
    let message = match serde_json::from_value::<GatewayMessage>(value) {
        Ok(message) => message,
        Err(error) if is_modes => {
            // An invalid catalog revokes old grants; ignoring it would keep
            // capabilities the gateway may have intended to remove.
            crate::log::warn(&format!(
                "invalid gateway modes catalog; revoking modes: {error}"
            ));
            return Some(GatewayMessage::Modes { modes: Vec::new() });
        }
        Err(_) => return None,
    };
    within_limits(&message).then_some(message)
}

/// JS string length (UTF-16 units).
fn length(text: &str) -> usize {
    text.encode_utf16().count()
}

fn request_id(id: &str) -> bool {
    (1..=100).contains(&length(id))
}

/// The refinements of `daemonMessageSchema` that serde does not express.
fn within_limits(message: &GatewayMessage) -> bool {
    match message {
        GatewayMessage::ModelDelta { request_id: id, .. }
        | GatewayMessage::ModelEnd { request_id: id, .. }
        | GatewayMessage::ModelError { request_id: id, .. }
        | GatewayMessage::AgentResponse { request_id: id, .. }
        | GatewayMessage::PotsRequest { request_id: id, .. } => request_id(id),
        GatewayMessage::MemoryMirrorAck { ledger_key, .. } => {
            ledger_key.len() == 16
                && ledger_key
                    .bytes()
                    .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        }
        GatewayMessage::Request {
            request_id: id,
            data,
        } => {
            request_id(id)
                && data.url.starts_with("/api/")
                && length(&data.url) <= 8192
                && !data.user.is_empty()
                && data
                    .content_type
                    .as_ref()
                    .is_none_or(|content_type| length(content_type) <= 200)
        }
        GatewayMessage::TerminalOpen {
            stream_id,
            user,
            session_id,
            terminal_id,
            ..
        } => {
            request_id(stream_id)
                && !user.is_empty()
                && !session_id.is_empty()
                && !terminal_id.is_empty()
        }
        GatewayMessage::RegistrationError { .. }
        | GatewayMessage::Registered { .. }
        | GatewayMessage::Modes { .. }
        | GatewayMessage::Models { .. }
        | GatewayMessage::HeartbeatAck
        | GatewayMessage::TerminalInput { .. }
        | GatewayMessage::TerminalClose { .. } => true,
    }
}

/// One frame from the gateway on socket `id`.
async fn handle(node: &Node, id: u64, registered: &mut bool, message: GatewayMessage) {
    match message {
        GatewayMessage::RegistrationError {
            status,
            code,
            message,
        } => {
            crate::log::error(&format!("{message} (status {status}, code {code})"));
            return;
        }
        GatewayMessage::Registered {
            models, mirrors, ..
        } => {
            *registered = true;
            node.link.set_registered(id);
            node.agent_gateway.connect();
            node.mirror.connect(mirrors.unwrap_or_default());
            send_activity(node);
            let providers: Vec<String> = models.providers.keys().cloned().collect();
            node.models.set(models, node.models.inference());
            crate::log::info(&format!(
                "registered with daemon {}; providers: {}",
                node.config.daemon_url,
                providers.join(", ")
            ));
            return;
        }
        _ => {}
    }
    if !*registered {
        return;
    }
    match message {
        frame @ (GatewayMessage::ModelDelta { .. }
        | GatewayMessage::ModelEnd { .. }
        | GatewayMessage::ModelError { .. }) => node.inference.receive(frame),
        GatewayMessage::Modes { modes } => {
            let unique: std::collections::BTreeSet<_> = modes.iter().map(|mode| &mode.id).collect();
            if unique.len() != modes.len() || modes.iter().any(|mode| mode.validate().is_err()) {
                node.replace_modes(Vec::new()).await;
            } else {
                node.replace_modes(modes).await;
            }
        }
        GatewayMessage::Models { models } => {
            let providers: Vec<String> = models.providers.keys().cloned().collect();
            node.models.set(models, node.models.inference());
            crate::log::info(&format!(
                "models updated by daemon; new agents use them; providers: {}",
                providers.join(", ")
            ));
        }
        GatewayMessage::PotsRequest { request_id, data } => {
            let node = node.clone();
            tokio::spawn(async move {
                let data = crate::pots::handle(&node, data).await;
                node.link.send(&NodeMessage::Response { request_id, data });
            });
        }
        GatewayMessage::Request { request_id, data } => {
            let node = node.clone();
            tokio::spawn(async move {
                let data = node.router.handle(&node, data).await;
                node.link.send(&NodeMessage::Response { request_id, data });
            });
        }
        GatewayMessage::TerminalOpen {
            stream_id,
            user,
            session_id,
            terminal_id,
            kind,
        } => node.streams.open(
            &stream_id,
            kind.unwrap_or(TerminalKind::Terminal),
            &user,
            &session_id,
            &terminal_id,
        ),
        GatewayMessage::TerminalInput { stream_id, message } => {
            node.streams.input(&stream_id, message);
        }
        GatewayMessage::TerminalClose { stream_id } => node.streams.close(&stream_id),
        GatewayMessage::AgentResponse {
            request_id,
            status,
            body,
        } => node.agent_gateway.receive(&request_id, status, body),
        GatewayMessage::MemoryMirrorAck {
            ledger_key,
            watermark,
            rejected_end,
        } => node.mirror.receive(&ledger_key, watermark, rejected_end),
        GatewayMessage::HeartbeatAck
        | GatewayMessage::RegistrationError { .. }
        | GatewayMessage::Registered { .. } => {}
    }
}

/// The `register` frame: protocol, role and this node's workspaces, each
/// directory workspace with the roles its agents can start in.
async fn registration(node: &Node) -> Registration {
    let workspaces: Vec<_> = node
        .db
        .lock()
        .list_workspaces()
        .unwrap_or_default()
        .into_iter()
        .filter(|workspace| workspace.host_id == node.config.node_id)
        .collect();
    let roots = workspaces
        .iter()
        .map(|workspace| Some(workspace.canonical_path.clone()))
        .collect();
    let details = workspace_details(node, roots).await;
    Registration {
        role: node.config.role,
        modes: node.config.modes.clone(),
        protocol: Some(i64::from(NODE_PROTOCOL_VERSION)),
        workspaces: workspaces
            .into_iter()
            .zip(details)
            .map(|(workspace, (roles, repo))| RegisteredWorkspace {
                checkpoint_private: crate::checkpoints::continuation::is_workspace(
                    &node.db.lock(),
                    &workspace.id,
                )
                .unwrap_or(true),
                id: workspace.id,
                display_name: workspace.display_name,
                mode: workspace.mode,
                roles,
                repo,
            })
            .collect(),
    }
}

/// Each directory workspace root's roles ([`workspace_roles`]) and
/// repository key (`repo::workspace_repo`), read on a blocking thread;
/// `None` for a root that is `None`, and for every root if the reads fail.
pub async fn workspace_details(
    node: &Node,
    roots: Vec<Option<String>>,
) -> Vec<(Option<Vec<WorkspaceRole>>, Option<String>)> {
    let count = roots.len();
    let config = node.config.clone();
    let read = tokio::task::spawn_blocking(move || {
        roots
            .into_iter()
            .map(|root| match root {
                Some(root) => (
                    workspace_roles(&config, &root),
                    crate::repo::workspace_repo(std::path::Path::new(&root)),
                ),
                None => (None, None),
            })
            .collect()
    });
    match read.await {
        Ok(details) => details,
        Err(error) => {
            crate::log::warn(&format!("workspace roles and repositories: {error}"));
            vec![(None, None); count]
        }
    }
}

/// `roleBriefs(loadRoles(root))`, or `None` (logged) when they do not load:
/// a delegation then cannot pick a role there.
pub fn workspace_roles(config: &pirc_config::NodeConfig, root: &str) -> Option<Vec<WorkspaceRole>> {
    let dirs = pirc_agent::roles::role_dirs(&config.config_dir.to_string_lossy(), root);
    match pirc_agent::roles::read_roles(&dirs) {
        Ok(roles) => Some(
            pirc_agent::roles::role_briefs(&roles)
                .into_iter()
                .map(|brief| WorkspaceRole {
                    name: brief.name,
                    description: brief.description,
                    models: brief.models,
                    thinking: brief.thinking,
                    tools: brief.tools,
                    source: brief.source,
                    overrides: brief.overrides,
                })
                .collect(),
        ),
        Err(error) => {
            crate::log::warn(&format!("roles of {root}: {error}"));
            None
        }
    }
}

/// Every open run and every write-lease holder, whole.
fn activity(node: &Node) -> crate::error::ApiResult<Vec<SessionActivity>> {
    let mut sessions: Vec<SessionActivity> = Vec::new();
    let runs = node.db.lock().active_runs()?;
    for (session_id, status) in runs {
        let run = match status {
            RunStatus::Queued => SessionRun::Queued,
            RunStatus::Running => SessionRun::Running,
            RunStatus::WaitingInput => SessionRun::WaitingInput,
            RunStatus::Stopping => SessionRun::Stopping,
            _ => continue,
        };
        // A later run of the same session replaces an earlier one (TS's map).
        match sessions.iter_mut().find(|entry| entry.id == session_id) {
            Some(entry) => entry.run = Some(run),
            None => sessions.push(SessionActivity {
                id: session_id,
                run: Some(run),
                write_lease: None,
            }),
        }
    }
    for holder in node.writes.holders()? {
        match sessions.iter_mut().find(|entry| entry.id == holder) {
            Some(entry) => entry.write_lease = Some(true),
            None => sessions.push(SessionActivity {
                id: holder,
                run: None,
                write_lease: Some(true),
            }),
        }
    }
    Ok(sessions)
}

fn send_activity(node: &Node) {
    if node.link.is_registered() {
        match activity(node) {
            Ok(sessions) => {
                node.link.send(&NodeMessage::Activity { sessions });
            }
            Err(error) => crate::log::warn(&format!("activity inventory unavailable: {error}")),
        };
    }
}

/// `activityChanged`: one timer of [`ACTIVITY_COALESCE_MS`] from the first
/// change; changes while it runs go out with it.
async fn coalesce_activity(node: Node) {
    loop {
        node.activity.notified().await;
        tokio::time::sleep(Duration::from_millis(ACTIVITY_COALESCE_MS)).await;
        // Changes during the window are in this frame: their stored
        // notification must not start another timer.
        let _ = node.activity.notified().now_or_never();
        send_activity(&node);
    }
}

/// Resolves once the node terminates the link.
async fn stopped(terminated: &mut watch::Receiver<bool>) {
    if terminated.wait_for(|stop| *stop).await.is_err() {
        // The node is gone: nothing will ever stop the link but this.
        std::future::pending::<()>().await;
    }
}

#[cfg(test)]
mod tests {
    use pirc_protocol::{NodeRole, Registration};

    use super::*;

    #[tokio::test]
    async fn activity_keeps_orphan_host_owners_and_propagates_inventory_failure() {
        let f = crate::workspace_memory::tests::Fixture::new().await;
        f.node.db.lock().execute("INSERT INTO host_command_runs(id,session_id,workspace_id,runner_epoch,incarnation,request_id,state,created_at,updated_at) VALUES('orphan','deleted-session','removed-workspace',0,'old-node','request','unconfirmed',1,1)",[]).unwrap();
        let rows = activity(&f.node).unwrap();
        assert!(
            rows.iter()
                .any(|r| r.id == "deleted-session" && r.write_lease == Some(true))
        );
        f.node
            .db
            .lock()
            .execute_batch(include_str!("host_commands/remove_schema.sql"))
            .unwrap();
        assert!(activity(&f.node).is_err());
        f.node.close().await;
    }

    fn register() -> NodeMessage {
        NodeMessage::Register(Registration {
            role: NodeRole::Node,
            modes: Vec::new(),
            protocol: Some(9),
            workspaces: Vec::new(),
        })
    }

    #[tokio::test]
    async fn frames_follow_the_socket() {
        let link = LinkSender::new();
        assert!(!link.send(&NodeMessage::Heartbeat));
        let mut first = link.open();
        assert!(link.send(&register()));
        assert!(!link.send_agent_frame(&NodeMessage::Heartbeat));
        assert!(!link.send_inference(&NodeMessage::Heartbeat));
        link.set_registered(first.id);
        assert!(link.is_registered());
        assert!(link.send_agent_frame(&NodeMessage::Heartbeat));
        assert_eq!(link.buffered_amount(), 93);
        let frame = first.recv().await.unwrap();
        assert!(frame.starts_with(r#"{"type":"register""#));
        first.written(&frame);
        assert_eq!(first.recv().await.unwrap(), r#"{"type":"heartbeat"}"#);
        first.written(r#"{"type":"heartbeat"}"#);
        assert_eq!(link.buffered_amount(), 0);
        // A new socket replaces the first: its close is not the link's.
        let second = link.open();
        assert!(!link.is_registered());
        assert!(first.recv().await.is_none());
        assert!(!link.close(first.id));
        assert!(link.close(second.id));
        assert!(!link.send(&NodeMessage::Heartbeat));
    }

    #[test]
    fn invalid_mode_frames_revoke_instead_of_retaining_old_grants() {
        for frame in [
            serde_json::json!({"type":"modes", "modes":[{"id":"bad"}]}),
            serde_json::json!({"type":"modes", "modes":"not-a-catalog"}),
            serde_json::json!({"type":"modes"}),
        ] {
            assert!(
                matches!(gateway_message(frame), Some(GatewayMessage::Modes { modes }) if modes.is_empty())
            );
        }
        assert!(gateway_message(serde_json::json!({"type":"unknown"})).is_none());
        let mode = pirc_protocol::mode::default_work();
        assert!(
            matches!(gateway_message(serde_json::json!({"type":"modes","modes":[mode]})), Some(GatewayMessage::Modes { modes }) if modes.len() == 1)
        );
    }

    #[test]
    fn inference_respects_the_backlog() {
        let link = LinkSender::new();
        let queue = link.open();
        link.set_registered(queue.id);
        let big = NodeMessage::ModelCancel {
            request_id: "x".repeat(INFERENCE_BUFFER_MAX_BYTES - 40),
        };
        assert!(link.send_inference(&big));
        assert!(!link.send_inference(&NodeMessage::ModelCancel {
            request_id: "y".repeat(100)
        }));
        let huge = NodeMessage::ModelCancel {
            request_id: "z".repeat(NODE_FRAME_MAX_BYTES),
        };
        assert!(!link.send_agent_frame(&huge));
        drop(queue);
        assert!(!link.send(&NodeMessage::Heartbeat));
    }
}
