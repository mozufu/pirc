//! Connected nodes (`apps/gateway/src/daemon/nodes.ts`): registration and
//! heartbeats on `/node/connect`, request/response correlation for relayed
//! browser requests, relayed terminal and browser streams, agent requests
//! and multiplexed inference.
//!
//! What the TS registry reported through callbacks (`onRegister`,
//! `onEvent`, ...) goes to the [`App`] methods in `node_events.rs`. The
//! registry's lock is never held while they run.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use axum::extract::ws::WebSocket;
use pirc_protocol::{
    AssistantDelta, InferenceRequest, Message, NODE_FRAME_MAX_BYTES, NODE_PROTOCOL_VERSION,
    NodeHttpRequest, NodeHttpResponse, NodeMessage, NodeRole, PROTOCOL_MISMATCH_CLOSE, PotsRequest,
    RegisteredWorkspace, Registration,
};
use serde::Serialize;
use serde_json::{Value, json};
use subtle::ConstantTimeEq;
use tokio::sync::oneshot;
use tokio::task::AbortHandle;

use crate::app::{App, AppState};
use crate::error::{ApiError, ApiResult};
use crate::util::{now_ms, uuid};
use crate::ws::{Outbox, Received, receive};

/// Preserve the legacy ACK shape except for a bounded, endpoint-specific quota hint.
pub(crate) fn mirror_ack(key: &str, offset: u64, end: u64, result: ApiResult<u64>) -> Value {
    let rejected = result
        .as_ref()
        .err()
        .is_some_and(|e| e.code == "memory_mirror_quota_exceeded");
    let mut ack =
        json!({"type":"memory_mirror_ack","ledgerKey":key,"watermark":result.unwrap_or(offset)});
    if rejected {
        ack["rejectedEnd"] = json!(end);
    }
    ack
}

/// Requests waiting on one node; each node has its own allowance, so a
/// busy or stalled node cannot starve the others (security audit L7).
const MAX_PENDING_REQUESTS: usize = 100;
const MAX_PENDING_REGISTRATIONS: usize = 100;
/// Terminal and browser-view streams open on one node.
const MAX_TERMINAL_STREAMS: usize = 64;
/// Agent requests the gateway works on at once for one node.
const MAX_AGENT_REQUESTS: usize = 32;
const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);
/// Largest browser→node relayed message: terminal input and browser-view input.
pub const TERMINAL_MESSAGE_MAX_BYTES: usize = 1024 * 1024;
pub const BROWSER_MESSAGE_MAX_BYTES: usize = 64 * 1024;
/// Bytes queued on a node link before further sends fail (their sender, not the link).
const NODE_SEND_BUFFER_MAX_BYTES: usize = 4 * NODE_FRAME_MAX_BYTES;
/// Reserve one small detach frame per admitted stream, even behind a congested link.
const STREAM_CLOSE_RESERVE_BYTES: usize = MAX_TERMINAL_STREAMS * 256;

pub const INFERENCE_REQUEST_MAX_BYTES: usize = 8 * 1024 * 1024;
pub const INFERENCE_BUFFER_MAX_BYTES: usize = 16 * 1024 * 1024;
pub const INFERENCE_STREAM_MAX_BYTES: usize = 256 * 1024 * 1024;
pub const INFERENCE_MAX_REQUESTS: usize = 32;
const INFERENCE_MAX_TOTAL: usize = 128;
pub const INFERENCE_TIMEOUT: Duration = Duration::from_secs(10 * 60);

/// `area.action` operations agents may ask the gateway for.
pub const AGENT_OP_MAX_LENGTH: usize = 64;
pub const AGENT_REQUEST_MAX_BYTES: usize = 65_536;

/// Why a frame was not sent.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum SendFailure {
    TooLarge,
    Backpressure,
    Failed,
}

/// One WebSocket connection of a node.
pub struct Link {
    id: u64,
    outbox: Arc<Outbox>,
}

impl Link {
    /// Send one frame. A frame the node would reject (over its frame limit:
    /// it would close the whole link) or one that would pile up behind a
    /// stalled link fails only its sender.
    fn send(&self, frame: &Value, reserve: usize) -> Result<(), SendFailure> {
        let text = frame.to_string();
        if text.len() > NODE_FRAME_MAX_BYTES {
            return Err(SendFailure::TooLarge);
        }
        if self.outbox.buffered() + text.len() > NODE_SEND_BUFFER_MAX_BYTES + reserve {
            return Err(SendFailure::Backpressure);
        }
        if self.outbox.send(text) {
            Ok(())
        } else {
            Err(SendFailure::Failed)
        }
    }

    pub fn close(&self, code: u16, reason: &str) {
        self.outbox.close(code, reason);
    }
}

/// In-process identity of one registered connection, never a reusable Node ID.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct NodeConnection(u64);

/// Raised only before a request is queued on the link (see `correlated_request`).
fn connection_changed() -> ApiError {
    ApiError::new(
        409,
        "node_connection_changed",
        "The Node reconnected; check the saved operation before continuing",
    )
    .unsent()
}

/// A registered node as `/api/nodes` lists it.
#[derive(Clone, Debug)]
pub struct ConnectedNode {
    pub id: String,
    pub role: NodeRole,
    pub modes: Vec<pirc_protocol::ModeId>,
    pub workspaces: Vec<RegisteredWorkspace>,
    pub connected_at: i64,
    pub last_seen_at: i64,
    /// The node's whole answer for each workspace added through
    /// `POST /api/workspaces` since it registered, by id: the TS gateway
    /// listed that answer as it was (with `canonicalPath`, `defaults` and
    /// `hostId`), and registered workspaces with their frame's fields only.
    pub added: HashMap<String, Value>,
}

impl Serialize for ConnectedNode {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        use serde::ser::SerializeStruct;
        let workspaces: Vec<Value> = self
            .workspaces
            .iter()
            .map(|workspace| match self.added.get(&workspace.id) {
                Some(raw) => raw.clone(),
                None => serde_json::to_value(workspace).unwrap_or(Value::Null),
            })
            .collect();
        let mut node = serializer.serialize_struct("ConnectedNode", 6)?;
        node.serialize_field("id", &self.id)?;
        node.serialize_field("role", &self.role)?;
        // The mode ids this node accepts (`PIRC_MODES`), for create dialogs.
        node.serialize_field("modes", &self.modes)?;
        node.serialize_field("workspaces", &workspaces)?;
        node.serialize_field("connectedAt", &self.connected_at)?;
        node.serialize_field("lastSeenAt", &self.last_seen_at)?;
        node.end()
    }
}

/// The browser side of a relayed terminal or browser stream.
pub trait StreamHandlers: Send + Sync {
    fn on_frame(&self, frame: Value);
    fn on_close(&self, code: u16, reason: &str);
}

struct Connection {
    link: Arc<Link>,
    node: ConnectedNode,
}

struct Pending {
    node_id: String,
    reply: oneshot::Sender<ApiResult<NodeHttpResponse>>,
}

struct Stream {
    node_id: String,
    link: Arc<Link>,
    handlers: Arc<dyn StreamHandlers>,
}

struct Running {
    node_id: String,
    task: AbortHandle,
}

#[derive(Default)]
struct State {
    connections: HashMap<String, Connection>,
    #[cfg(test)]
    test_connections: HashMap<String, ConnectedNode>,
    #[cfg(test)]
    test_connection_ids: HashMap<String, NodeConnection>,
    #[cfg(test)]
    test_request: Option<Arc<dyn Fn(NodeHttpRequest) -> ApiResult<NodeHttpResponse> + Send + Sync>>,
    #[cfg(test)]
    test_pots: Option<Arc<dyn Fn(PotsRequest) -> ApiResult<NodeHttpResponse> + Send + Sync>>,
    pending_registrations: usize,
    requests: HashMap<String, Pending>,
    streams: HashMap<String, Stream>,
    inferences: HashMap<(String, String), Running>,
    agent_requests: HashMap<String, usize>,
}

#[derive(Default)]
pub struct NodeRegistry {
    state: Mutex<State>,
    next_link: AtomicU64,
}

/// Constant-time comparison of a node's bearer token with its secret.
pub fn valid_node_token(
    tokens: &indexmap::IndexMap<String, String>,
    node_id: &str,
    token: &str,
) -> bool {
    let Some(expected) = tokens.get(node_id) else {
        return false;
    };
    if token.is_empty() || token.len() > 4096 || token.len() != expected.len() {
        return false;
    }
    bool::from(token.as_bytes().ct_eq(expected.as_bytes()))
}

fn too_many_streams() -> ApiError {
    ApiError::new(503, "node_error", "Too many open terminal streams")
}

pub fn node_offline() -> ApiError {
    ApiError::new(503, "node_offline", "Node is offline")
}

impl State {
    /// Requests pending on `node_id`.
    fn requests_on(&self, node_id: &str) -> usize {
        self.requests
            .values()
            .filter(|pending| pending.node_id == node_id)
            .count()
    }

    /// Streams open on `node_id`.
    fn streams_on(&self, node_id: &str) -> usize {
        self.streams
            .values()
            .filter(|stream| stream.node_id == node_id)
            .count()
    }
}

impl NodeRegistry {
    fn lock(&self) -> MutexGuard<'_, State> {
        self.state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn link_of(state: &State, node_id: &str) -> ApiResult<Arc<Link>> {
        state
            .connections
            .get(node_id)
            .filter(|connection| connection.link.outbox.is_open())
            .map(|connection| connection.link.clone())
            .ok_or_else(node_offline)
    }

    pub fn get(&self, node_id: &str) -> Option<ConnectedNode> {
        let state = self.lock();
        state
            .connections
            .get(node_id)
            .map(|connection| connection.node.clone())
            .or_else(|| {
                #[cfg(test)]
                {
                    state.test_connections.get(node_id).cloned()
                }
                #[cfg(not(test))]
                {
                    None
                }
            })
    }

    pub fn list(&self) -> Vec<ConnectedNode> {
        let state = self.lock();
        let mut nodes: Vec<_> = state
            .connections
            .values()
            .map(|connection| connection.node.clone())
            .collect();
        #[cfg(test)]
        nodes.extend(state.test_connections.values().cloned());
        nodes.sort_by_key(|node| node.connected_at);
        nodes
    }

    pub fn count(&self) -> usize {
        let state = self.lock();
        state.connections.len() + {
            #[cfg(test)]
            {
                state.test_connections.len()
            }
            #[cfg(not(test))]
            {
                0
            }
        }
    }

    #[cfg(test)]
    pub(crate) fn set_test_node(
        &self,
        node: ConnectedNode,
        request: impl Fn(NodeHttpRequest) -> ApiResult<NodeHttpResponse> + Send + Sync + 'static,
    ) {
        let mut state = self.lock();
        state.test_connection_ids.insert(
            node.id.clone(),
            NodeConnection(self.next_link.fetch_add(1, Ordering::Relaxed)),
        );
        state.test_connections.insert(node.id.clone(), node);
        state.test_request = Some(Arc::new(request));
    }

    #[cfg(test)]
    pub(crate) fn set_test_pots(
        &self,
        request: impl Fn(PotsRequest) -> ApiResult<NodeHttpResponse> + Send + Sync + 'static,
    ) {
        self.lock().test_pots = Some(Arc::new(request));
    }

    /// `raw` is the node's answer the workspace was parsed from, listed
    /// as it is (see [`ConnectedNode::added`]).
    pub fn add_workspace(
        &self,
        node_id: &str,
        workspace: RegisteredWorkspace,
        raw: Value,
    ) -> ApiResult<()> {
        let mut state = self.lock();
        #[cfg(test)]
        if let Some(node) = state.test_connections.get_mut(node_id) {
            if let Some(existing) = node
                .workspaces
                .iter_mut()
                .find(|item| item.id == workspace.id)
            {
                *existing = workspace.clone();
            } else {
                node.workspaces.push(workspace.clone());
            }
            node.added.insert(workspace.id, raw);
            return Ok(());
        }
        let node = &mut state
            .connections
            .get_mut(node_id)
            .ok_or_else(node_offline)?
            .node;
        if !node.workspaces.iter().any(|item| item.id == workspace.id) {
            node.added.insert(workspace.id.clone(), raw);
            node.workspaces.push(workspace);
        }
        Ok(())
    }

    /// A continuation can add a private workspace without reconnecting. Keep
    /// the live registry in step with the node's durable response.
    pub fn upsert_workspace(
        &self,
        node_id: &str,
        workspace: RegisteredWorkspace,
        raw: Value,
    ) -> ApiResult<()> {
        let mut state = self.lock();
        #[cfg(test)]
        if let Some(node) = state.test_connections.get_mut(node_id) {
            if let Some(existing) = node
                .workspaces
                .iter_mut()
                .find(|item| item.id == workspace.id)
            {
                *existing = workspace.clone();
            } else {
                node.workspaces.push(workspace.clone());
            }
            node.added.insert(workspace.id, raw);
            return Ok(());
        }
        let node = &mut state
            .connections
            .get_mut(node_id)
            .ok_or_else(node_offline)?
            .node;
        if let Some(existing) = node
            .workspaces
            .iter_mut()
            .find(|item| item.id == workspace.id)
        {
            *existing = workspace.clone();
        } else {
            node.workspaces.push(workspace.clone());
        }
        node.added.insert(workspace.id, raw);
        Ok(())
    }

    /// Forget a workspace the node deleted (a chat project), until it registers again.
    pub fn remove_workspace(&self, node_id: &str, local_id: &str) {
        let mut state = self.lock();
        if let Some(connection) = state.connections.get_mut(node_id) {
            let node = &mut connection.node;
            node.workspaces.retain(|item| item.id != local_id);
            node.added.remove(local_id);
        }
    }

    /// Capture the connection whose capabilities are about to be checked.
    pub(crate) fn connection(&self, node_id: &str) -> ApiResult<NodeConnection> {
        let state = self.lock();
        #[cfg(test)]
        if let Some(id) = state.test_connection_ids.get(node_id) {
            return Ok(*id);
        }
        Ok(NodeConnection(Self::link_of(&state, node_id)?.id))
    }

    /// Reject a completed probe whose connection has already been replaced,
    /// before reserving a command. The send itself checks atomically again.
    pub(crate) fn require_connection(
        &self,
        node_id: &str,
        expected: NodeConnection,
    ) -> ApiResult<()> {
        if self.connection(node_id)? != expected {
            return Err(connection_changed());
        }
        Ok(())
    }

    /// Send only to the connection that supplied the checked capabilities.
    pub(crate) async fn request_on(
        &self,
        node_id: &str,
        connection: NodeConnection,
        data: NodeHttpRequest,
    ) -> ApiResult<NodeHttpResponse> {
        self.request_scoped(node_id, Some(connection), data).await
    }

    /// Replay an HTTP request on the node. `Ok` with the node's status and
    /// body (4xx/5xx included); `Err` only when the transport fails, in
    /// which case the outcome on the node is unknown.
    pub async fn request(
        &self,
        node_id: &str,
        data: NodeHttpRequest,
    ) -> ApiResult<NodeHttpResponse> {
        self.request_scoped(node_id, None, data).await
    }

    async fn request_scoped(
        &self,
        node_id: &str,
        connection: Option<NodeConnection>,
        data: NodeHttpRequest,
    ) -> ApiResult<NodeHttpResponse> {
        #[cfg(test)]
        {
            let test_request = {
                let state = self.lock();
                if connection.is_some_and(|id| {
                    state
                        .test_connection_ids
                        .get(node_id)
                        .is_some_and(|current| id != *current)
                }) {
                    return Err(connection_changed());
                }
                state
                    .test_connections
                    .contains_key(node_id)
                    .then(|| state.test_request.clone())
                    .flatten()
            };
            if let Some(test_request) = test_request {
                return test_request(data);
            }
        }
        self.correlated_request(
            node_id,
            "request",
            serde_json::to_value(data).map_err(|_| ApiError::internal())?,
            connection,
        )
        .await
    }

    /// Host-only pots commands are separate link frames, never relayed HTTP.
    pub(crate) async fn pots_request(
        &self,
        node_id: &str,
        data: PotsRequest,
    ) -> ApiResult<NodeHttpResponse> {
        #[cfg(test)]
        {
            let handler = self.lock().test_pots.clone();
            if let Some(handler) = handler {
                return handler(data);
            }
        }
        self.correlated_request(
            node_id,
            "pots_request",
            serde_json::to_value(data).map_err(|_| ApiError::internal())?,
            None,
        )
        .await
    }

    async fn correlated_request(
        &self,
        node_id: &str,
        kind: &str,
        data: Value,
        connection: Option<NodeConnection>,
    ) -> ApiResult<NodeHttpResponse> {
        let request_id = uuid();
        let (reply, answer) = oneshot::channel();
        {
            let mut state = self.lock();
            // Every early return below happens before the frame is queued on the
            // link and before the request is registered as pending: no copy of
            // it can reach the Node, so each is marked `unsent`. Everything
            // after the registration (timeout, link loss) leaves it unmarked.
            if state.requests_on(node_id) >= MAX_PENDING_REQUESTS {
                return Err(
                    ApiError::new(503, "node_error", "Too many pending node requests").unsent(),
                );
            }
            let link = Self::link_of(&state, node_id).map_err(ApiError::unsent)?;
            if connection.is_some_and(|expected| expected.0 != link.id) {
                return Err(connection_changed());
            }
            let frame = json!({ "type": kind, "requestId": request_id, "data": data });
            if let Err(failure) = link.send(&frame, 0) {
                return Err(match failure {
                    SendFailure::TooLarge => ApiError::new(
                        413,
                        "payload_too_large",
                        "Request is too large to relay to the node",
                    ),
                    SendFailure::Backpressure => {
                        ApiError::new(503, "node_error", "Node link is congested; try again")
                    }
                    SendFailure::Failed => {
                        ApiError::new(503, "node_offline", "Node connection failed")
                    }
                }
                .unsent());
            }
            state.requests.insert(
                request_id.clone(),
                Pending {
                    node_id: node_id.to_owned(),
                    reply,
                },
            );
        }
        /// Forgets the request however this future ends (dropped included).
        struct Forget<'a>(&'a NodeRegistry, &'a str);
        impl Drop for Forget<'_> {
            fn drop(&mut self) {
                self.0.lock().requests.remove(self.1);
            }
        }
        let _forget = Forget(self, &request_id);
        let outcome = tokio::time::timeout(REQUEST_TIMEOUT, answer).await;
        match outcome {
            Ok(Ok(result)) => result,
            Ok(Err(_)) => Err(ApiError::new(
                503,
                "node_offline",
                "Node disconnected; outcome may be unknown",
            )),
            Err(_) => Err(ApiError::new(
                504,
                "node_timeout",
                "Node response timed out; outcome may be unknown",
            )),
        }
    }

    /// Relay a browser terminal (or browser view) WebSocket to the node.
    pub fn open_stream(
        self: &Arc<Self>,
        node_id: &str,
        target: Value,
        browser: bool,
        handlers: Arc<dyn StreamHandlers>,
    ) -> ApiResult<RelayedStream> {
        let stream_id = uuid();
        let link = {
            let mut state = self.lock();
            let link = Self::link_of(&state, node_id)?;
            if state.streams_on(node_id) >= MAX_TERMINAL_STREAMS {
                return Err(too_many_streams());
            }
            state.streams.insert(
                stream_id.clone(),
                Stream {
                    node_id: node_id.to_owned(),
                    link: link.clone(),
                    handlers,
                },
            );
            link
        };
        let mut frame = json!({ "type": "terminal_open", "streamId": stream_id });
        if let (Some(frame), Value::Object(target)) = (frame.as_object_mut(), target) {
            frame.extend(target);
        }
        if let Err(failure) = link.send(&frame, 0) {
            self.fail_stream(&stream_id, failure);
        }
        Ok(RelayedStream {
            registry: Arc::downgrade(self),
            stream_id,
            link,
            max_bytes: if browser {
                BROWSER_MESSAGE_MAX_BYTES
            } else {
                TERMINAL_MESSAGE_MAX_BYTES
            },
        })
    }

    fn fail_stream(&self, stream_id: &str, failure: SendFailure) {
        let (code, reason) = if failure == SendFailure::Failed {
            (1011, "node connection failed")
        } else {
            (1013, "node link congested")
        };
        self.end_stream(stream_id, true, Some((code, reason)));
    }

    /// One finalizer for local detach, remote close and link loss. Never kills the shell.
    fn end_stream(&self, stream_id: &str, detach: bool, close: Option<(u16, &str)>) {
        let Some(stream) = self.lock().streams.remove(stream_id) else {
            return;
        };
        if detach && stream.link.outbox.is_open() {
            let frame = json!({ "type": "terminal_close", "streamId": stream_id });
            if stream
                .link
                .send(&frame, STREAM_CLOSE_RESERVE_BYTES)
                .is_err()
            {
                // Close this original link: its teardown detaches every
                // subscription. Never send an old stream's close on a new link.
                stream.link.close(1013, "stream cleanup failed");
            }
        }
        if let Some((code, reason)) = close {
            stream.handlers.on_close(code, reason);
        }
    }

    /// The node is gone: its requests, streams and inferences fail.
    fn fail_node(&self, node_id: &str) {
        let (streams, inferences) = {
            let mut state = self.lock();
            let inferences: Vec<_> = state
                .inferences
                .extract_if(|_, running| running.node_id == node_id)
                .map(|(_, running)| running.task)
                .collect();
            let requests: Vec<_> = state
                .requests
                .extract_if(|_, pending| pending.node_id == node_id)
                .map(|(_, pending)| pending.reply)
                .collect();
            for reply in requests {
                let _ = reply.send(Err(ApiError::new(
                    503,
                    "node_offline",
                    "Node disconnected; outcome may be unknown",
                )));
            }
            let streams: Vec<String> = state
                .streams
                .iter()
                .filter(|(_, stream)| stream.node_id == node_id)
                .map(|(id, _)| id.clone())
                .collect();
            (streams, inferences)
        };
        for task in inferences {
            task.abort();
        }
        for stream_id in streams {
            self.end_stream(&stream_id, false, Some((1012, "node disconnected")));
        }
    }

    /// Push the current providers to every node.
    pub fn broadcast(&self, frame: &Value) {
        let links: Vec<_> = self
            .lock()
            .connections
            .values()
            .map(|connection| connection.link.clone())
            .collect();
        for link in links {
            if link.outbox.is_open() {
                let _ = link.send(frame, 0);
            }
        }
    }

    pub fn close_all(&self) {
        let node_ids: Vec<String> = self.lock().connections.keys().cloned().collect();
        for node_id in &node_ids {
            self.fail_node(node_id);
        }
        let links: Vec<_> = self
            .lock()
            .connections
            .drain()
            .map(|(_, connection)| connection.link)
            .collect();
        for link in links {
            link.close(1001, "daemon shutting down");
        }
    }

    fn cancel_inference(&self, node_id: &str, request_id: &str) {
        let running = self
            .lock()
            .inferences
            .remove(&(node_id.to_owned(), request_id.to_owned()));
        if let Some(running) = running {
            running.task.abort();
        }
    }

    /// Release the chat node: the link closes and its sessions go offline.
    pub fn disconnect(&self, app: &App, node_id: &str) {
        let Some(connection) = self.lock().connections.remove(node_id) else {
            return;
        };
        self.fail_node(node_id);
        app.on_node_disconnect(node_id);
        connection.link.close(4000, "chat node binding released");
    }
}

/// The gateway's handle on a relayed stream.
pub struct RelayedStream {
    registry: std::sync::Weak<NodeRegistry>,
    stream_id: String,
    link: Arc<Link>,
    max_bytes: usize,
}

impl RelayedStream {
    /// Forward one browser message (already parsed JSON).
    pub fn send(&self, message: &Value) {
        let Some(registry) = self.registry.upgrade() else {
            return;
        };
        if !registry.lock().streams.contains_key(&self.stream_id) {
            return;
        }
        if message.to_string().len() > self.max_bytes {
            registry.end_stream(&self.stream_id, true, Some((1009, "message too large")));
            return;
        }
        let frame =
            json!({ "type": "terminal_input", "streamId": self.stream_id, "message": message });
        if let Err(failure) = self.link.send(&frame, 0) {
            registry.fail_stream(&self.stream_id, failure);
        }
    }

    /// Detach (the browser left).
    pub fn close(&self) {
        if let Some(registry) = self.registry.upgrade() {
            registry.end_stream(&self.stream_id, true, None);
        }
    }
}

// ---- the link -------------------------------------------------------------

/// Serve one `/node/connect` socket of `node_id` (credentials already checked).
pub async fn serve(app: AppState, node_id: String, socket: WebSocket) {
    let (outbox, mut stream) = Outbox::start(socket);
    let admitted = {
        let mut state = app.nodes.lock();
        let admitted = state.pending_registrations < MAX_PENDING_REGISTRATIONS;
        if admitted {
            state.pending_registrations += 1;
        }
        admitted
    };
    if !admitted {
        outbox.close(1013, "too many pending registrations");
        receive(&outbox, &mut stream, |_| {}).await;
        return;
    }
    let link = Arc::new(Link {
        id: app.nodes.next_link.fetch_add(1, Ordering::Relaxed),
        outbox: outbox.clone(),
    });
    // 10 s to register, then at most 45 s between heartbeats.
    let seen = Arc::new(Mutex::new((Instant::now(), false)));
    let watchdog = {
        let outbox = outbox.clone();
        let seen = seen.clone();
        tokio::spawn(async move {
            let mut interval = tokio::time::interval(Duration::from_secs(5));
            loop {
                interval.tick().await;
                let (last, registered) = *seen.lock().unwrap_or_else(|p| p.into_inner());
                let limit = Duration::from_secs(if registered { 45 } else { 10 });
                if last.elapsed() > limit {
                    outbox.close(4001, "heartbeat timeout");
                    return;
                }
            }
        })
    };
    let mut session = LinkSession {
        app: app.clone(),
        node_id,
        link,
        registered: false,
        seen,
    };
    receive(&outbox, &mut stream, |received| session.handle(received)).await;
    watchdog.abort();
    session.closed();
}

struct LinkSession {
    app: AppState,
    node_id: String,
    link: Arc<Link>,
    registered: bool,
    seen: Arc<Mutex<(Instant, bool)>>,
}

/// Limits the TS schemas put on node frames (`protocol-schema.ts`).
fn within_limits(message: &NodeMessage) -> bool {
    let chars = |text: &str| text.chars().count();
    match message {
        NodeMessage::Register(_) => false,
        NodeMessage::ModelStart {
            request_id,
            request,
            session,
        } => {
            (1..=100).contains(&chars(request_id))
                && (1..=200).contains(&chars(session))
                && valid_inference_request(request)
        }
        NodeMessage::ModelCancel { request_id } => (1..=100).contains(&chars(request_id)),
        NodeMessage::Activity { sessions } => {
            sessions.len() <= 10_000 && sessions.iter().all(|item| chars(&item.id) <= 200)
        }
        NodeMessage::MemoryMirror {
            ledger_key, lines, ..
        } => {
            ledger_key.len() == 16
                && ledger_key
                    .bytes()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
                && lines.len() <= 10_000
        }
        NodeMessage::AgentRequest {
            request_id,
            session_id,
            op,
            ..
        } => {
            (1..=100).contains(&chars(request_id))
                && (1..=200).contains(&chars(session_id))
                && chars(op) <= 1000
        }
        _ => true,
    }
}

fn valid_inference_request(request: &InferenceRequest) -> bool {
    let chars = |text: &str| text.chars().count();
    (1..=200).contains(&chars(&request.provider_name))
        && (1..=500).contains(&chars(&request.model_id))
        && request.messages.len() <= 20_000
        && request.tools.len() <= 1000
        && request
            .tools
            .iter()
            .all(|tool| (1..=200).contains(&chars(&tool.name)))
        && (1..=500).contains(&chars(&request.session_id))
        && request
            .max_tokens
            .is_none_or(|max| (1..=1_000_000).contains(&max))
}

/// A workspace ID and the names of roles (`protocol-schema.ts`).
/// Drop a repository key that is not one a node could have made
/// ([`pirc_protocol::valid_repo`]).
pub fn sanitize_repo(workspace: &mut RegisteredWorkspace) {
    if workspace
        .repo
        .as_deref()
        .is_some_and(|repo| !pirc_protocol::valid_repo(repo))
    {
        workspace.repo = None;
    }
}

fn valid_registration(registration: &Registration) -> bool {
    let chars = |text: &str| text.chars().count();
    let role_name = |name: &str| {
        let mut bytes = name.bytes();
        bytes.next().is_some_and(|b| b.is_ascii_lowercase())
            && name.len() <= 40
            && bytes.all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_' || b == b'-')
    };
    let mut ids = std::collections::HashSet::new();
    registration.workspaces.len() <= 100
        && registration.workspaces.iter().all(|workspace| {
            ids.insert(workspace.id.as_str())
                && pirc_config::valid_node_id(&workspace.id)
                && (1..=200).contains(&chars(&workspace.display_name))
                && workspace.roles.as_ref().is_none_or(|roles| {
                    roles.len() <= 50
                        && roles.iter().all(|role| {
                            role_name(&role.name)
                                && role.description.as_ref().is_none_or(|d| chars(d) <= 500)
                                && role.models.as_ref().is_none_or(|models| {
                                    models.len() <= 20 && models.iter().all(|m| chars(m) <= 200)
                                })
                                && role.thinking.as_ref().is_none_or(|t| chars(t) <= 20)
                                && role.tools.as_ref().is_none_or(|tools| {
                                    tools.len() <= 64 && tools.iter().all(|t| chars(t) <= 64)
                                })
                                && role.source.as_ref().is_none_or(|s| s == "workspace")
                                && role
                                    .overrides
                                    .as_ref()
                                    .is_none_or(|o| o == "node" || o == "builtin")
                        })
                })
        })
}

impl LinkSession {
    fn touch(&self, registered: bool) {
        *self.seen.lock().unwrap_or_else(|p| p.into_inner()) = (Instant::now(), registered);
    }

    fn close(&self, code: u16, reason: &str) {
        self.link.close(code, reason);
    }

    fn send(&self, frame: Value) {
        let _ = self.link.send(&frame, 0);
    }

    fn handle(&mut self, received: Received) {
        if !self.link.outbox.is_open() {
            return;
        }
        let text = match received {
            Received::TooLarge => return self.close(1009, "message too large"),
            Received::Text(text) => text,
            Received::Binary(bytes) => String::from_utf8_lossy(&bytes).into_owned(),
        };
        if text.len() > NODE_FRAME_MAX_BYTES {
            return self.close(1009, "message too large");
        }
        let Ok(message) = serde_json::from_str::<Value>(&text) else {
            return self.close(1007, "invalid JSON");
        };
        if !self.registered {
            return self.register(message);
        }
        let current = self
            .app
            .nodes
            .lock()
            .connections
            .get(&self.node_id)
            .is_some_and(|connection| connection.link.id == self.link.id);
        if !current {
            return self.close(4000, "replaced by new connection");
        }
        match serde_json::from_value::<NodeMessage>(message) {
            Ok(message) if within_limits(&message) => self.dispatch(message),
            _ => self.close(1008, "unsupported message"),
        }
    }

    fn register(&mut self, message: Value) {
        let mismatch = |protocol: Option<i64>| {
            format!(
                "node protocol {} != daemon {NODE_PROTOCOL_VERSION}",
                protocol.unwrap_or(1)
            )
        };
        // The envelope first, so an old node learns about the version.
        if message.get("type").and_then(Value::as_str) == Some("register") {
            let protocol = message.get("protocol");
            let integer = protocol.and_then(|value| {
                value.as_i64().or_else(|| {
                    value
                        .as_f64()
                        .filter(|f| f.fract() == 0.0)
                        .map(|f| f as i64)
                })
            });
            let envelope_ok = protocol.is_none() || integer.is_some();
            if envelope_ok && integer != Some(i64::from(NODE_PROTOCOL_VERSION)) {
                return self.close(PROTOCOL_MISMATCH_CLOSE, &mismatch(integer));
            }
        }
        let mut parsed = match serde_json::from_value::<NodeMessage>(message) {
            Ok(NodeMessage::Register(registration)) if valid_registration(&registration) => {
                registration
            }
            _ => return self.close(1008, "invalid registration"),
        };
        if parsed.protocol != Some(i64::from(NODE_PROTOCOL_VERSION)) {
            return self.close(PROTOCOL_MISMATCH_CLOSE, &mismatch(parsed.protocol));
        }
        // A repository key the gateway would not store is not relayed to
        // browsers either; the workspace itself is still registered.
        for workspace in &mut parsed.workspaces {
            sanitize_repo(workspace);
            if !self
                .app
                .mode(&workspace.mode)
                .is_some_and(|mode| mode.repository)
            {
                workspace.repo = None;
            }
        }
        if parsed
            .workspaces
            .iter()
            .any(|workspace| !parsed.modes.contains(&workspace.mode))
        {
            return self.close(1008, "workspace mode is not accepted by node");
        }
        if !self.app.accept_node_role(&self.node_id, parsed.role) {
            self.send(json!({
                "type": "registration_error",
                "status": 409,
                "code": "chat_node_exists",
                "message": "A different chat node is bound to this gateway. Release it in Settings → Assistant first.",
            }));
            return self.close(4409, "chat_node_exists");
        }
        self.registered = true;
        let registry = &self.app.nodes;
        {
            let mut state = registry.lock();
            state.pending_registrations = state.pending_registrations.saturating_sub(1);
        }
        let previous = registry
            .lock()
            .connections
            .get(&self.node_id)
            .map(|c| c.link.clone());
        if let Some(previous) = previous {
            self.app.on_node_disconnect(&self.node_id);
            previous.close(4000, "replaced by new connection");
            // The TS gateway's `ws` emitted the old socket's close at once,
            // while it was still the registered one: a second disconnect.
            // Reproduced, since clients see its events.
            registry.lock().connections.remove(&self.node_id);
            registry.fail_node(&self.node_id);
            self.app.on_node_disconnect(&self.node_id);
            registry.fail_node(&self.node_id);
        }
        self.touch(true);
        let stamp = now_ms();
        let node = ConnectedNode {
            id: self.node_id.clone(),
            role: parsed.role,
            modes: parsed.modes,
            workspaces: parsed.workspaces,
            connected_at: stamp,
            last_seen_at: stamp,
            added: HashMap::new(),
        };
        // `registered` is queued before the node can be found for relays:
        // a node drops every frame that comes before it (the TS gateway sent
        // synchronously, so no request could overtake it).
        let frame = json!({
            "type": "registered",
            "nodeId": self.node_id,
            "models": self.app.public_models(),
            "mirrors": self.app.mirror_watermarks(&self.node_id),
        });
        self.send(frame);
        self.send(json!({"type":"modes", "modes":self.app.public_modes()}));
        registry.lock().connections.insert(
            self.node_id.clone(),
            Connection {
                link: self.link.clone(),
                node: node.clone(),
            },
        );
        self.app.on_node_register(&node);
    }

    fn dispatch(&mut self, message: NodeMessage) {
        let app = &self.app;
        let node_id = self.node_id.as_str();
        match message {
            NodeMessage::Register(_) => {}
            NodeMessage::ModelStart {
                request_id,
                request,
                session,
            } => start_inference(app, node_id, &self.link, request_id, request, session),
            NodeMessage::ModelCancel { request_id } => {
                app.nodes.cancel_inference(node_id, &request_id);
            }
            NodeMessage::Heartbeat => {
                self.touch(true);
                if let Some(connection) = app.nodes.lock().connections.get_mut(node_id) {
                    connection.node.last_seen_at = now_ms();
                }
                self.send(json!({ "type": "heartbeat_ack" }));
            }
            NodeMessage::Response { request_id, data } => {
                let mut state = app.nodes.lock();
                if state
                    .requests
                    .get(&request_id)
                    .is_some_and(|pending| pending.node_id == node_id)
                    && let Some(pending) = state.requests.remove(&request_id)
                {
                    let _ = pending.reply.send(Ok(data));
                }
            }
            NodeMessage::Event { session_id, event } => {
                app.on_node_event(node_id, &session_id, event);
            }
            NodeMessage::Activity { sessions } => app.on_node_activity(node_id, &sessions),
            NodeMessage::AgentRequest {
                request_id,
                session_id,
                op,
                args,
            } => answer_agent(app, node_id, &self.link, request_id, session_id, op, args),
            NodeMessage::MemoryMirror {
                ledger_key,
                offset,
                end,
                reset,
                lines,
            } => {
                let result = app.on_mirror(
                    node_id,
                    &ledger_key,
                    offset,
                    end,
                    reset.unwrap_or(false),
                    &lines,
                );
                self.send(mirror_ack(&ledger_key, offset, end, result));
            }
            NodeMessage::TerminalFrame { stream_id, frame } => {
                let handlers = app
                    .nodes
                    .lock()
                    .streams
                    .get(&stream_id)
                    .filter(|stream| stream.node_id == node_id)
                    .map(|stream| stream.handlers.clone());
                if let Some(handlers) = handlers {
                    handlers.on_frame(frame.unwrap_or(Value::Null));
                }
            }
            NodeMessage::TerminalClosed {
                stream_id,
                code,
                reason,
            } => {
                let ours = app
                    .nodes
                    .lock()
                    .streams
                    .get(&stream_id)
                    .is_some_and(|stream| stream.node_id == node_id);
                if ours {
                    let code = u16::try_from(code).unwrap_or(1011);
                    app.nodes
                        .end_stream(&stream_id, false, Some((code, &reason)));
                }
            }
        }
    }

    /// The socket ended.
    fn closed(&self) {
        let registry = &self.app.nodes;
        if !self.registered {
            let mut state = registry.lock();
            state.pending_registrations = state.pending_registrations.saturating_sub(1);
            return;
        }
        let current = {
            let mut state = registry.lock();
            let current = state
                .connections
                .get(&self.node_id)
                .is_some_and(|connection| connection.link.id == self.link.id);
            if current {
                state.connections.remove(&self.node_id);
            }
            current
        };
        if current {
            registry.fail_node(&self.node_id);
            self.app.on_node_disconnect(&self.node_id);
        }
    }
}

fn agent_error(status: u16, code: &str, message: &str) -> (u16, Value) {
    (
        status,
        json!({ "error": { "code": code, "message": message } }),
    )
}

/// `^[a-z][a-zA-Z0-9]*(?:\.[a-z][a-zA-Z0-9]*)+$`
fn valid_op(op: &str) -> bool {
    let parts: Vec<&str> = op.split('.').collect();
    parts.len() >= 2
        && parts.iter().all(|part| {
            let mut bytes = part.bytes();
            bytes.next().is_some_and(|b| b.is_ascii_lowercase())
                && bytes.all(|b| b.is_ascii_alphanumeric())
        })
}

/// The op and args come from an agent: a bad value is answered with an
/// error, not treated as a protocol violation that closes the link.
fn answer_agent(
    app: &AppState,
    node_id: &str,
    link: &Arc<Link>,
    request_id: String,
    session_id: String,
    op: String,
    args: Option<Value>,
) {
    let reply = {
        let link = link.clone();
        move |(status, body): (u16, Value)| {
            if !link.outbox.is_open() {
                return;
            }
            let frame = json!({ "type": "agent_response", "requestId": request_id, "status": status, "body": body });
            if link.send(&frame, 0) == Err(SendFailure::TooLarge) {
                let (status, body) =
                    agent_error(413, "payload_too_large", "Gateway answer is too large");
                let _ = link.send(
                    &json!({ "type": "agent_response", "requestId": request_id, "status": status, "body": body }),
                    0,
                );
            }
        }
    };
    {
        let mut state = app.nodes.lock();
        let in_flight = state.agent_requests.get(node_id).copied().unwrap_or(0);
        if in_flight >= MAX_AGENT_REQUESTS {
            drop(state);
            return reply(agent_error(
                429,
                "too_many_requests",
                "Too many gateway requests are in flight for this node",
            ));
        }
        if op.chars().count() > AGENT_OP_MAX_LENGTH || !valid_op(&op) {
            drop(state);
            return reply(agent_error(
                400,
                "invalid_input",
                "A gateway operation is named like area.action",
            ));
        }
        let args = args.clone().unwrap_or_else(|| json!({}));
        if args.to_string().len() > AGENT_REQUEST_MAX_BYTES {
            drop(state);
            return reply(agent_error(
                413,
                "payload_too_large",
                "Gateway request arguments are too large",
            ));
        }
        state
            .agent_requests
            .insert(node_id.to_owned(), in_flight + 1);
    }
    let app = app.clone();
    let node_id = node_id.to_owned();
    tokio::spawn(async move {
        let args = args.unwrap_or_else(|| json!({}));
        let answer = tokio::spawn({
            let app = app.clone();
            let node_id = node_id.clone();
            async move { crate::agent_ops::run(&app, &node_id, &session_id, &op, args).await }
        })
        .await
        .unwrap_or_else(|_| agent_error(500, "internal_error", "The gateway operation failed"));
        {
            let mut state = app.nodes.lock();
            let left = state.agent_requests.get(&node_id).copied().unwrap_or(1) - 1;
            if left > 0 {
                state.agent_requests.insert(node_id.clone(), left);
            } else {
                state.agent_requests.remove(&node_id);
            }
        }
        reply(answer);
    });
}

/// Send an inference event to the node, tagged with its request id;
/// `false` when the link is gone or the frame would not fit.
fn send_inference(link: &Link, request_id: &str, mut event: Value) -> bool {
    if !link.outbox.is_open() {
        return false;
    }
    event["requestId"] = json!(request_id);
    let text = event.to_string();
    if text.len() > NODE_FRAME_MAX_BYTES
        || link.outbox.buffered() + text.len() > INFERENCE_BUFFER_MAX_BYTES
    {
        return false;
    }
    link.outbox.send(text)
}

fn model_error(code: &str) -> Value {
    json!({ "type": "model_error", "code": code })
}

fn start_inference(
    app: &AppState,
    node_id: &str,
    link: &Arc<Link>,
    request_id: String,
    request: InferenceRequest,
    node_session: String,
) {
    let key = (node_id.to_owned(), request_id.clone());
    let mut state = app.nodes.lock();
    // A duplicate ID must never replace or route into another active stream.
    if state.inferences.contains_key(&key) {
        drop(state);
        return link.close(1008, "duplicate inference request");
    }
    let per_node = state
        .inferences
        .values()
        .filter(|running| running.node_id == node_id)
        .count();
    let request_bytes = serde_json::to_string(&request).map_or(usize::MAX, |text| text.len());
    if state.inferences.len() >= INFERENCE_MAX_TOTAL
        || per_node >= INFERENCE_MAX_REQUESTS
        || request_bytes > INFERENCE_REQUEST_MAX_BYTES
    {
        drop(state);
        if !send_inference(link, &request_id, model_error("limit_exceeded")) {
            link.close(1013, "inference buffer limit");
        }
        return;
    }
    // Registered before the task can finish, under the same lock.
    let (stop, stopped) = oneshot::channel::<()>();
    let task = tokio::spawn({
        let app = app.clone();
        let link = link.clone();
        let key = key.clone();
        async move {
            let finish = |event: Value| {
                if app.nodes.lock().inferences.remove(&key).is_none() {
                    return;
                }
                if !send_inference(&link, &key.1, event)
                    && !send_inference(&link, &key.1, model_error("limit_exceeded"))
                {
                    link.close(1013, "inference buffer limit");
                }
            };
            let mut stop = Some(stop);
            let mut bytes = 0usize;
            let mut on_delta = |delta: &AssistantDelta, _: &pirc_protocol::AssistantMessage| {
                if stop.is_none() {
                    return;
                }
                let event = json!({ "type": "model_delta", "delta": delta });
                bytes += event.to_string().len();
                if (bytes > INFERENCE_STREAM_MAX_BYTES || !send_inference(&link, &key.1, event))
                    && let Some(stop) = stop.take()
                {
                    let _ = stop.send(());
                }
            };
            let run = app
                .inference
                .run(app.backends.as_ref(), &request, &key.0, &mut on_delta);
            tokio::select! {
                biased;
                _ = stopped => finish(model_error("limit_exceeded")),
                message = run => {
                    crate::usage::record(
                        &app,
                        &key.0,
                        &node_session,
                        &request,
                        &message,
                    );
                    if message.stop_reason == pirc_protocol::StopReason::Error {
                        // Already a fixed classification (status included
                        // when known), never an upstream body.
                        crate::log::warn(&format!(
                            "inference for node {} failed: {}/{}: {}",
                            key.0,
                            request.provider_name,
                            request.model_id,
                            message.error_message.as_deref().unwrap_or("no error message")
                        ));
                    }
                    finish(json!({ "type": "model_end", "message": Message::Assistant(message) }));
                }
                () = tokio::time::sleep(INFERENCE_TIMEOUT) => {
                    crate::log::warn(&format!(
                        "inference for node {} timed out: {}/{}",
                        key.0, request.provider_name, request.model_id
                    ));
                    finish(model_error("timeout"));
                }
            }
        }
    });
    state.inferences.insert(
        key,
        Running {
            node_id: node_id.to_owned(),
            task: task.abort_handle(),
        },
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pending_requests_are_counted_per_node() {
        let mut state = State::default();
        for (index, node_id) in ["a", "a", "b"].into_iter().enumerate() {
            let (reply, _) = oneshot::channel();
            state.requests.insert(
                index.to_string(),
                Pending {
                    node_id: node_id.to_owned(),
                    reply,
                },
            );
        }
        assert_eq!(state.requests_on("a"), 2);
        assert_eq!(state.requests_on("b"), 1);
        assert_eq!(state.requests_on("c"), 0);
        assert_eq!(state.streams_on("a"), 0);
    }
    fn link_registry(
        id: u64,
    ) -> (
        NodeRegistry,
        Arc<Link>,
        tokio::sync::mpsc::UnboundedReceiver<crate::ws::Outgoing>,
    ) {
        let registry = NodeRegistry::default();
        let (outbox, receiver) = Outbox::detached();
        let link = Arc::new(Link { id, outbox });
        registry.lock().connections.insert(
            "node".into(),
            Connection {
                link: link.clone(),
                node: ConnectedNode {
                    id: "node".into(),
                    role: NodeRole::Node,
                    modes: vec![],
                    workspaces: vec![],
                    connected_at: 0,
                    last_seen_at: 0,
                    added: HashMap::new(),
                },
            },
        );
        (registry, link, receiver)
    }
    fn request(payload: Option<Value>) -> NodeHttpRequest {
        NodeHttpRequest {
            method: pirc_protocol::HttpMethod::Post,
            url: "/x".into(),
            user: "alice".into(),
            payload,
            body_base64: None,
            content_type: None,
        }
    }

    #[tokio::test]
    async fn a_request_that_fails_before_it_is_queued_is_typed_as_not_sent() {
        // No connection at all.
        let none = NodeRegistry::default();
        let error = none.request("node", request(None)).await.unwrap_err();
        assert_eq!(error.code, "node_offline");
        assert!(error.is_not_sent());

        // The connection the caller checked was replaced.
        let (registry, link, mut receiver) = link_registry(7);
        let error = registry
            .request_on("node", NodeConnection(6), request(None))
            .await
            .unwrap_err();
        assert_eq!(error.code, "node_connection_changed");
        assert!(error.is_not_sent());

        // Too large for one frame.
        let big = request(Some(json!("x".repeat(NODE_FRAME_MAX_BYTES))));
        let error = registry.request("node", big).await.unwrap_err();
        assert_eq!(error.code, "payload_too_large");
        assert!(error.is_not_sent());

        // A congested link shares its error code with other failures: the
        // classification is carried by type, not by this string.
        link.outbox.pretend_buffered(NODE_SEND_BUFFER_MAX_BYTES);
        let error = registry.request("node", request(None)).await.unwrap_err();
        assert_eq!(error.code, "node_error");
        assert!(error.is_not_sent());
        assert!(
            !too_many_streams().is_not_sent(),
            "same code, different cause"
        );

        // A link that is already closing.
        let (registry, link, mut closed_receiver) = link_registry(8);
        link.outbox.close(1000, "bye");
        let error = registry.request("node", request(None)).await.unwrap_err();
        assert!(error.is_not_sent());

        // Nothing was queued, and no request was left registered.
        assert!(receiver.try_recv().is_err());
        assert!(matches!(
            closed_receiver.try_recv(),
            Ok(crate::ws::Outgoing::Close(..))
        ));
        assert!(closed_receiver.try_recv().is_err());
        assert!(registry.lock().requests.is_empty());
    }

    #[tokio::test]
    async fn a_request_that_was_queued_and_then_lost_is_not_typed_as_not_sent() {
        let (registry, _link, mut receiver) = link_registry(3);
        let registry = Arc::new(registry);
        let waiting = {
            let registry = registry.clone();
            tokio::spawn(async move { registry.request("node", request(None)).await })
        };
        // The frame is in the queue and the request registered.
        let frame = loop {
            if let Ok(frame) = receiver.try_recv() {
                break frame;
            }
            tokio::task::yield_now().await;
        };
        assert!(matches!(frame, crate::ws::Outgoing::Text(_)));
        assert_eq!(registry.lock().requests.len(), 1);
        // The link drops while the request is pending: the outcome is unknown.
        registry.fail_node("node");
        let error = waiting.await.unwrap().unwrap_err();
        assert_eq!(error.code, "node_offline");
        assert!(!error.is_not_sent());
        assert!(registry.lock().requests.is_empty());
    }

    #[test]
    fn mirror_quota_hint_is_optional_and_only_identifies_the_rejected_endpoint() {
        let legacy = json!({"type":"memory_mirror_ack","ledgerKey":"key","watermark":10});
        assert_eq!(mirror_ack("key", 0, 10, Ok(10)), legacy);
        let ack: pirc_protocol::GatewayMessage = serde_json::from_value(legacy.clone()).unwrap();
        assert_eq!(serde_json::to_value(ack).unwrap(), legacy);
        let ordinary = mirror_ack("key", 10, 20, Err(ApiError::invalid_input()));
        assert!(ordinary.get("rejectedEnd").is_none());
        let quota = mirror_ack(
            "key",
            10,
            20,
            Err(ApiError::new(413, "memory_mirror_quota_exceeded", "quota")),
        );
        assert_eq!(quota["watermark"], 10);
        assert_eq!(quota["rejectedEnd"], 20);
        let decoded: pirc_protocol::GatewayMessage = serde_json::from_value(quota.clone()).unwrap();
        assert_eq!(serde_json::to_value(decoded).unwrap(), quota);
    }
}
