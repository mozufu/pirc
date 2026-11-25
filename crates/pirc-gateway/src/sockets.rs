//! The gateway's WebSockets (`apps/gateway/src/daemon/app.ts`,
//! `socket-relay.ts`): a session's events (`/api/events`), terminal and
//! browser streams relayed to the node, and the node link itself.

use std::net::SocketAddr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use axum::extract::ws::{WebSocket, WebSocketUpgrade, rejection::WebSocketUpgradeRejection};
use axum::extract::{ConnectInfo, Path, State};
use axum::http::{HeaderMap, Uri};
use axum::response::Response;
use pirc_protocol::{INVALID_NODE_CREDENTIALS_CLOSE, NODE_FRAME_MAX_BYTES};
use serde_json::{Value, json};

use crate::app::{AppState, query_map};
use crate::auth::{self, Identity};
use crate::db::Store;
use crate::devices::Tracked;
use crate::error::{ApiError, ApiResult};
use crate::events::{Cursor, GatewayEvent, Subscription};
use crate::hints::HintGuard;
use crate::http::websocket_required;
use crate::nodes::{
    self, BROWSER_MESSAGE_MAX_BYTES, RelayedStream, StreamHandlers, TERMINAL_MESSAGE_MAX_BYTES,
    valid_node_token,
};
use crate::ws::{Outbox, Received, receive};

/// Browsers send nothing on the event socket; anything large is abuse.
const EVENTS_MESSAGE_MAX_BYTES: usize = 4 * 1024;
/// Only live browser frames may be skipped while this much is queued.
const BROWSER_SOCKET_BACKLOG_BYTES: usize = 2 * 1024 * 1024;
/// Largest node→browser message on a relayed stream. Nodes send terminal
/// output and replay (scrollback is 256 KiB before JSON escaping) and live-view
/// frames (JPEG, at most 1280x800); this bounds how far one message can push
/// the socket past its backlog limit, which the 16 MiB node frame cap does not.
const RELAYED_MESSAGE_MAX_BYTES: usize = 4 * 1024 * 1024;

/// The close code for a refused socket (`wsCloseCode`).
pub fn close_code(error: &ApiError) -> u16 {
    match error.status {
        401 => 4401,
        403 => 4403,
        404 => 4404,
        _ => 4400,
    }
}

/// `message.slice(0, 120)`.
fn close_reason(message: &str) -> String {
    message.chars().take(120).collect()
}

/// `epoch:sequence`, if given.
fn cursor_from(value: Option<&str>) -> ApiResult<Option<Cursor>> {
    let Some(value) = value.filter(|value| !value.is_empty()) else {
        return Ok(None);
    };
    let invalid = || ApiError::new(400, "invalid_input", "cursor must be epoch:sequence");
    let (epoch, sequence) = value.split_once(':').ok_or_else(invalid)?;
    let digits = |text: &str| !text.is_empty() && text.bytes().all(|b| b.is_ascii_digit());
    if !digits(epoch) || !digits(sequence) {
        return Err(invalid());
    }
    Ok(Some(Cursor {
        epoch: epoch.parse().map_err(|_| invalid())?,
        sequence: sequence.parse().map_err(|_| invalid())?,
    }))
}

/// One query parameter: absent, or given once (zod's `string().optional()`).
fn single<'a>(
    query: &'a std::collections::HashMap<String, Vec<String>>,
    name: &str,
) -> ApiResult<Option<&'a str>> {
    match query.get(name).map(Vec::as_slice) {
        None => Ok(None),
        Some([value]) => Ok(Some(value.as_str())),
        Some(_) => Err(ApiError::invalid_input()),
    }
}

// ---- /api/events ------------------------------------------------------------

pub async fn events(
    State(app): State<AppState>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    uri: Uri,
    upgrade: Result<WebSocketUpgrade, WebSocketUpgradeRejection>,
) -> Response {
    let Ok(upgrade) = upgrade else {
        return websocket_required();
    };
    upgrade
        .max_message_size(EVENTS_MESSAGE_MAX_BYTES)
        .on_upgrade(move |socket| run_events(app, peer, headers, uri, socket))
}

/// What an open event socket holds; dropping it unsubscribes everything.
struct EventSocket {
    _subscription: Subscription,
    _hints: Vec<HintGuard>,
    _tracked: Option<Tracked>,
}

async fn run_events(
    app: AppState,
    peer: SocketAddr,
    headers: HeaderMap,
    uri: Uri,
    socket: WebSocket,
) {
    let (outbox, mut stream) = Outbox::start(socket);
    let opened = open_events(&app, &peer, &headers, &uri, &outbox);
    if let Err(error) = &opened {
        outbox.close(close_code(error), &close_reason(&error.message));
    }
    receive(&outbox, &mut stream, |received| {
        if matches!(received, Received::TooLarge) {
            outbox.close(1009, "message too large");
        }
    })
    .await;
    drop(opened);
}

/// Send a frame unless the browser is too far behind: then a reset with the
/// stream's watermark, and the socket closes so the client resyncs.
fn send_frame(outbox: &Outbox, max_buffered: usize, frame: String, watermark: Cursor) {
    if !outbox.is_open() {
        return;
    }
    if outbox.buffered() > max_buffered {
        outbox.send(
            json!({ "type": "reset", "reason": "backpressure", "watermark": watermark })
                .to_string(),
        );
        outbox.close(1013, "resync required");
        return;
    }
    outbox.send(frame);
}

fn event_frame(event: &GatewayEvent) -> (String, Cursor) {
    (
        serde_json::to_string(event).unwrap_or_default(),
        Cursor {
            epoch: event.epoch,
            sequence: event.sequence,
        },
    )
}

fn open_events(
    app: &AppState,
    peer: &SocketAddr,
    headers: &HeaderMap,
    uri: &Uri,
    outbox: &Arc<Outbox>,
) -> ApiResult<EventSocket> {
    let identity = app.validate(peer, headers, uri, &axum::http::Method::GET, true)?;
    let query = query_map(uri);
    let session_id = single(&query, "sessionId")?
        .filter(|id| !id.is_empty())
        .ok_or_else(ApiError::invalid_input)?;
    let cursor = single(&query, "cursor")?;
    let mut flags = [false; 9];
    for (index, name) in [
        "directory",
        "memory",
        "schedules",
        "sessions",
        "pots",
        "threads",
        "approvals",
        "activity",
        "budgetRequests",
    ]
    .iter()
    .enumerate()
    {
        match single(&query, name)? {
            None => {}
            Some("1") => flags[index] = true,
            Some(_) => return Err(ApiError::invalid_input()),
        }
    }
    let session = app.claim(&identity, session_id)?.session;
    let cursor = cursor_from(cursor)?;
    let max = app.config.websocket_max_buffered_bytes;

    let listener = {
        let outbox = outbox.clone();
        Arc::new(move |event: &GatewayEvent| {
            let (frame, watermark) = event_frame(event);
            send_frame(&outbox, max, frame, watermark);
        })
    };
    let subscription = app.events.attach(
        &session.id,
        cursor,
        session.runner_epoch,
        |replay| {
            if replay.reset {
                send_frame(
                    outbox,
                    max,
                    json!({
                        "type": "reset",
                        "reason": "cursor_expired_or_epoch_changed",
                        "watermark": replay.watermark,
                    })
                    .to_string(),
                    replay.watermark,
                );
            } else {
                for event in &replay.events {
                    send_frame(outbox, max, event_frame(event).0, replay.watermark);
                }
            }
        },
        listener,
    );

    let hint = |kind: &'static str| {
        let outbox = outbox.clone();
        let events = app.events.clone();
        let (session_id, epoch) = (session.id.clone(), session.runner_epoch);
        Arc::new(move || {
            let watermark = events.watermark(&session_id, epoch);
            send_frame(&outbox, max, json!({ "type": kind }).to_string(), watermark);
        }) as crate::hints::Hint
    };
    let user = identity.user.clone();
    let mut hints = Vec::new();
    if flags[0] {
        hints.push(app.hints.directory.add((), hint("directory_changed")));
    }
    if flags[1] {
        hints.push(app.hints.memory.add(user.clone(), hint("memory_changed")));
    }
    if flags[2] {
        hints.push(
            app.hints
                .schedules
                .add(user.clone(), hint("schedules_changed")),
        );
    }
    if flags[3] {
        hints.push(
            app.hints
                .sessions
                .add(user.clone(), hint("sessions_changed")),
        );
    }
    if flags[4] {
        hints.push(app.hints.pots.add(user.clone(), hint("pots_changed")));
    }
    if flags[5] {
        hints.push(app.hints.threads.add(user.clone(), hint("threads_changed")));
    }
    if flags[6] {
        hints.push(
            app.hints
                .approvals
                .add(user.clone(), hint("approvals_changed")),
        );
    }
    if flags[8] {
        hints.push(
            app.hints
                .budget_requests
                .add(user.clone(), hint("budget_requests_changed")),
        );
    }
    if flags[7] {
        hints.push(app.hints.activity.add(user, hint("activity_changed")));
    }
    Ok(EventSocket {
        _subscription: subscription,
        _hints: hints,
        _tracked: track_device(app, &identity, outbox),
    })
}

/// Close a device's socket once its token is revoked or expires.
fn track_device(app: &AppState, identity: &Identity, outbox: &Arc<Outbox>) -> Option<Tracked> {
    let device_id = identity.device_id.as_deref()?;
    let outbox = outbox.clone();
    Some(app.devices.track(
        device_id,
        Box::new(move || outbox.close(4401, "device token revoked or expired")),
    ))
}

// ---- terminal and browser streams --------------------------------------------

pub async fn terminal_stream(
    State(app): State<AppState>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    Path((session_id, terminal_id)): Path<(String, String)>,
    headers: HeaderMap,
    uri: Uri,
    upgrade: Result<WebSocketUpgrade, WebSocketUpgradeRejection>,
) -> Response {
    let Ok(upgrade) = upgrade else {
        return websocket_required();
    };
    let target = Target {
        session_id,
        terminal_id: Some(terminal_id),
    };
    upgrade
        .max_message_size(TERMINAL_MESSAGE_MAX_BYTES)
        .on_upgrade(move |socket| relay(app, peer, headers, uri, target, socket))
}

pub async fn browser_stream(
    State(app): State<AppState>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    Path(session_id): Path<String>,
    headers: HeaderMap,
    uri: Uri,
    upgrade: Result<WebSocketUpgrade, WebSocketUpgradeRejection>,
) -> Response {
    let Ok(upgrade) = upgrade else {
        return websocket_required();
    };
    let target = Target {
        session_id,
        terminal_id: None,
    };
    upgrade
        .max_message_size(BROWSER_MESSAGE_MAX_BYTES)
        .on_upgrade(move |socket| relay(app, peer, headers, uri, target, socket))
}

struct Target {
    session_id: String,
    /// `None`: the browser live view.
    terminal_id: Option<String>,
}

/// The browser side of a relayed stream.
struct Relay {
    outbox: Arc<Outbox>,
    browser: bool,
    max_buffered: usize,
    finished: AtomicBool,
    stream: Mutex<Option<Arc<RelayedStream>>>,
    tracked: Mutex<Option<Tracked>>,
}

impl Relay {
    /// Finish once: detach from the node, stop tracking, close the socket.
    fn close(&self, code: u16, reason: &str) {
        if self.finished.swap(true, Ordering::AcqRel) {
            return;
        }
        self.done();
        self.outbox.close(code, &close_reason(reason));
    }

    fn done(&self) {
        self.finished.store(true, Ordering::Release);
        let stream = self.stream.lock().unwrap_or_else(|p| p.into_inner()).take();
        let tracked = self
            .tracked
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .take();
        if let Some(stream) = stream {
            stream.close();
        }
        drop(tracked);
    }
}

impl StreamHandlers for Relay {
    fn on_frame(&self, frame: Value) {
        if self.finished.load(Ordering::Acquire) || !self.outbox.is_open() {
            return;
        }
        let live = self.browser && frame.get("type").and_then(Value::as_str) == Some("frame");
        let text = frame.to_string();
        match relay_verdict(live, self.outbox.buffered(), text.len(), self.max_buffered) {
            Verdict::Send => {
                self.outbox.send(text);
            }
            Verdict::Skip => {}
            Verdict::Close(code, reason) => self.close(code, reason),
        }
    }

    fn on_close(&self, code: u16, reason: &str) {
        self.close(code, reason);
    }
}

#[derive(Debug, PartialEq, Eq)]
enum Verdict {
    Send,
    /// A disposable live-view frame while the socket is backed up.
    Skip,
    Close(u16, &'static str),
}

/// What to do with one node→browser message of `len` bytes while `buffered`
/// bytes are queued.
fn relay_verdict(live: bool, buffered: usize, len: usize, max_buffered: usize) -> Verdict {
    if len > RELAYED_MESSAGE_MAX_BYTES {
        return if live {
            Verdict::Skip
        } else {
            Verdict::Close(1009, "message too large")
        };
    }
    if live && buffered > BROWSER_SOCKET_BACKLOG_BYTES {
        return Verdict::Skip;
    }
    if buffered > max_buffered {
        return Verdict::Close(1013, "resync required");
    }
    Verdict::Send
}

async fn relay(
    app: AppState,
    peer: SocketAddr,
    headers: HeaderMap,
    uri: Uri,
    target: Target,
    socket: WebSocket,
) {
    let (outbox, mut stream) = Outbox::start(socket);
    let browser = target.terminal_id.is_none();
    let relay = Arc::new(Relay {
        outbox: outbox.clone(),
        browser,
        max_buffered: app.config.websocket_max_buffered_bytes,
        finished: AtomicBool::new(false),
        stream: Mutex::new(None),
        tracked: Mutex::new(None),
    });
    let opened = (|| -> ApiResult<(RelayedStream, Option<Tracked>)> {
        let identity = app.validate(&peer, &headers, &uri, &axum::http::Method::GET, true)?;
        let claimed = app.claim(&identity, &target.session_id)?;
        app.require_writable(&claimed.session)?;
        let terminal_id = match &target.terminal_id {
            None => "browser".to_owned(),
            Some(id) if (1..=100).contains(&id.chars().count()) => id.clone(),
            Some(_) => return Err(ApiError::invalid_input()),
        };
        let mut open = json!({
            "user": identity.user,
            "sessionId": claimed.pi_session_id,
            "terminalId": terminal_id,
        });
        if browser {
            open["kind"] = json!("browser");
        }
        let stream = app
            .nodes
            .open_stream(&claimed.node_id, open, browser, relay.clone())?;
        Ok((stream, track_device(&app, &identity, &outbox)))
    })();
    match opened {
        Err(error) => relay.close(close_code(&error), &error.message),
        Ok((stream, tracked)) => {
            if relay.finished.load(Ordering::Acquire) {
                // Closed while opening: let go of what arrived late.
                stream.close();
            } else {
                *relay.stream.lock().unwrap_or_else(|p| p.into_inner()) = Some(Arc::new(stream));
                *relay.tracked.lock().unwrap_or_else(|p| p.into_inner()) = tracked;
            }
        }
    }
    receive(&outbox, &mut stream, |received| {
        if relay.finished.load(Ordering::Acquire) {
            return;
        }
        let text = match received {
            Received::TooLarge => return relay.close(1009, "message too large"),
            Received::Text(text) => text,
            Received::Binary(bytes) => String::from_utf8_lossy(&bytes).into_owned(),
        };
        let session = { app.db.lock().get_session(&target.session_id) };
        let writable = session.and_then(|session| app.require_writable(&session));
        if let Err(error) = writable {
            return relay.close(close_code(&error), &error.message);
        }
        // Malformed JSON has always been ignored on these routes.
        // Sent outside the lock: a failed send ends the stream, which locks it.
        let stream = relay
            .stream
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .clone();
        if let Ok(message) = serde_json::from_str::<Value>(&text)
            && let Some(stream) = stream
        {
            stream.send(&message);
        }
    })
    .await;
    relay.done();
}

// ---- /node/connect -----------------------------------------------------------

/// Refused node connections are logged at most this often: `/node/connect`
/// is outside the browser forward-auth, so anyone who reaches it could
/// otherwise fill the log.
const REFUSED_NODE_LOG_INTERVAL: std::time::Duration = std::time::Duration::from_secs(60);

/// Log a refused node connection, naming the node id it claimed (cut short,
/// as it comes from the request) and never the token, unless one was logged
/// within [`REFUSED_NODE_LOG_INTERVAL`].
fn log_refused_node(node_id: Option<&str>) {
    static LAST: Mutex<Option<std::time::Instant>> = Mutex::new(None);
    {
        let mut last = LAST.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        if last.is_some_and(|at| at.elapsed() < REFUSED_NODE_LOG_INTERVAL) {
            return;
        }
        *last = Some(std::time::Instant::now());
    }
    let shown = match node_id {
        Some(id) => format!("{:?}", id.chars().take(64).collect::<String>()),
        None => "(none)".to_owned(),
    };
    crate::log::warn(&format!(
        "refused a node connection: no PIRC_NODE_TOKENS entry matches node id {shown} and its token \
         (closed {INVALID_NODE_CREDENTIALS_CLOSE}; further refusals within a minute are not logged)"
    ));
}

pub async fn node_connect(
    State(app): State<AppState>,
    headers: HeaderMap,
    upgrade: Result<WebSocketUpgrade, WebSocketUpgradeRejection>,
) -> Response {
    let Ok(upgrade) = upgrade else {
        return websocket_required();
    };
    let node_id = auth::header(&headers, "x-pirc-node-id");
    let token = auth::header(&headers, "authorization")
        .and_then(|value| {
            value
                .strip_prefix("Bearer ")
                .filter(|token| !token.is_empty() && !token.contains(' '))
                .map(str::to_owned)
        })
        .unwrap_or_default();
    let valid = node_id
        .as_deref()
        .is_some_and(|node_id| valid_node_token(&app.config.node_tokens, node_id, &token));
    if !valid {
        log_refused_node(node_id.as_deref());
    }
    upgrade
        .max_message_size(NODE_FRAME_MAX_BYTES)
        .max_frame_size(NODE_FRAME_MAX_BYTES)
        .on_upgrade(move |socket| async move {
            match node_id.filter(|_| valid) {
                Some(node_id) => nodes::serve(app, node_id, socket).await,
                None => {
                    let (outbox, mut stream) = Outbox::start(socket);
                    outbox.close(INVALID_NODE_CREDENTIALS_CLOSE, "invalid node credentials");
                    receive(&outbox, &mut stream, |_| {}).await;
                }
            }
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cursors() {
        assert_eq!(cursor_from(None).unwrap(), None);
        assert_eq!(cursor_from(Some("")).unwrap(), None);
        assert_eq!(
            cursor_from(Some("2:15")).unwrap(),
            Some(Cursor {
                epoch: 2,
                sequence: 15
            })
        );
        for bad in ["abc", "1:", ":1", "1:2:3", "-1:2", "1.0:2"] {
            assert!(cursor_from(Some(bad)).is_err(), "{bad}");
        }
    }

    #[test]
    fn relayed_messages_are_size_checked() {
        let max = 1024 * 1024;
        let big = RELAYED_MESSAGE_MAX_BYTES + 1;
        assert_eq!(relay_verdict(false, 0, 1000, max), Verdict::Send);
        assert_eq!(
            relay_verdict(false, 0, RELAYED_MESSAGE_MAX_BYTES, max),
            Verdict::Send
        );
        // One oversized message closes a terminal, and is dropped from the live view.
        assert_eq!(
            relay_verdict(false, 0, big, max),
            Verdict::Close(1009, "message too large")
        );
        assert_eq!(relay_verdict(true, 0, big, max), Verdict::Skip);
        // The backlog limits are unchanged.
        assert_eq!(
            relay_verdict(false, max + 1, 10, max),
            Verdict::Close(1013, "resync required")
        );
        assert_eq!(
            relay_verdict(true, BROWSER_SOCKET_BACKLOG_BYTES + 1, 10, max),
            Verdict::Skip
        );
    }
}
