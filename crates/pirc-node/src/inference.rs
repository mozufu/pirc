//! The agents' inference endpoint (`node/inference.ts`): a private HTTP/1.1
//! server on a Unix socket that relays model calls to the gateway over the
//! link. Each runner receives a revocable session/workspace/epoch capability.
//! Owner: **runner**.
//!
//! The server is hand-written over `tokio::net::UnixListener` (model endpoints
//! plus separately scoped persistence, with the agent's own client in
//! `pirc_agent::remote`), so the node links no HTTP server stack. It takes
//! one request per connection and closes it after the response; request
//! bodies may be `Content-Length` or `chunked`.
//!
//! What it reproduces: directory `<state>/i-XXXXXX` (0700) with `socket`
//! (0600); runner-scoped 32-byte hex tokens checked as `Bearer` in constant time; 64
//! connections, 30 s for headers and body; `GET /models` (the current
//! catalog, `no-store`; over 16 MiB: 503 `limit_exceeded`) and
//! `POST /inference` (8 MiB body, 429 beyond [`INFERENCE_MAX_REQUESTS`],
//! an [`InferenceRequest`] or 400 `invalid_request`); errors as NDJSON
//! `{"type":"model_error","code":...}`; an accepted request streams NDJSON
//! with a node-generated request id, `model_start` through
//! [`crate::link::LinkSender::send_inference`], a 10-minute deadline, and
//! `model_cancel` exactly once when the agent goes away, the deadline
//! passes or a limit is hit (never after [`InferenceServer::disconnect`] or
//! a refused start). Golden cases: the node half of
//! `inference-transport.test.ts` (`tests` below).
//!
//! Node's own HTTP behavior is reproduced only where a client sees it:
//! a head over 16 KiB is answered 431, an unparsable request 400, and a
//! request not complete within 30 s loses its connection.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};
use std::time::Duration;

use pirc_agent::messages::js::utf16_len;
use pirc_protocol::{
    GatewayMessage, INFERENCE_BUFFER_MAX_BYTES, INFERENCE_MAX_REQUESTS,
    INFERENCE_REQUEST_MAX_BYTES, INFERENCE_STREAM_MAX_BYTES, INFERENCE_TIMEOUT_MS, InferenceConfig,
    InferenceErrorCode, InferenceRequest, Models, NodeMessage,
};
use serde_json::{Value, json};
use subtle::ConstantTimeEq;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::{mpsc, watch};
use tokio::task::AbortHandle;
use tokio::time::Instant;

use crate::services::WeakNode;
use crate::util::{hex, random_bytes, uuid};

mod authority;
pub(crate) use authority::Lease;
use authority::{Gate, Identity, Scope};

/// `server.maxConnections`.
const MAX_CONNECTIONS: usize = 64;
/// `headersTimeout`, `requestTimeout` and the body's `setTimeout`.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);
/// Node's default `maxHeaderSize`.
const HEAD_MAX_BYTES: usize = 16 * 1024;
/// A pause after a failed `accept` (fd exhaustion must not spin a worker).
const ACCEPT_BACKOFF: Duration = Duration::from_millis(100);
/// How long a closing connection may still write (a stream's final
/// `model_error`; TS ended responses before `closeAllConnections`).
const CLOSE_FLUSH: Duration = Duration::from_millis(100);
/// Hex digits of a chunk size (Node's parser refuses more than a `u64`).
const CHUNK_SIZE_MAX_DIGITS: usize = 16;

pub struct InferenceServer {
    node: WeakNode,
    relay: OnceLock<Arc<Relay>>,
}

impl InferenceServer {
    pub fn new(node: WeakNode) -> Self {
        Self {
            node,
            relay: OnceLock::new(),
        }
    }

    /// Listen before the link connects. Endpoint metadata has no credential;
    /// each configure line gets its runner's lease. Sandbox policy uses the path.
    pub async fn start(&self) -> Result<InferenceConfig, String> {
        let node = self.node.upgrade().ok_or("the node is gone")?;
        let state_dir = node.config.state_dir.clone();
        drop(node);
        let (sender, models) = (self.node.clone(), self.node.clone());
        let relay = Relay::start(
            &state_dir,
            Arc::new(move |message| {
                sender
                    .upgrade()
                    .is_some_and(|node| node.link.send_inference(message))
            }),
            Arc::new(move || {
                models
                    .upgrade()
                    .map(|node| node.models.current())
                    .unwrap_or_else(|| crate::models::ModelStore::new().current())
            }),
            Duration::from_millis(INFERENCE_TIMEOUT_MS),
            authority::node_gate(self.node.clone()),
        )
        .await?;
        let config = relay.config.clone();
        if self.relay.set(relay).is_err() {
            return Err("the inference socket is already listening".to_owned());
        }
        Ok(config)
    }

    /// One capability for one runner epoch; never distribute the Node endpoint
    /// metadata token as authority. Missing only in lightweight test fixtures.
    pub(crate) fn runner(
        &self,
        session: &str,
        workspace: &str,
        epoch: i64,
        mode: &pirc_protocol::Mode,
    ) -> Option<Lease> {
        self.relay.get().map(|relay| {
            relay.register(Identity {
                session: session.into(),
                workspace: workspace.into(),
                epoch,
                mode: mode.clone(),
            })
        })
    }

    pub(crate) fn revoke_session(&self, session: &str) {
        if let Some(relay) = self.relay.get() {
            relay.revoke_session(session);
        }
    }

    pub(crate) fn persistence(
        &self,
        root: &Path,
        ledger: Option<&Path>,
    ) -> Result<crate::persistence::Lease, String> {
        let relay = self.relay.get().ok_or("Inference transport unavailable")?;
        relay
            .persistence
            .register(&relay.config.socket_path, root, ledger)
            .map_err(|_| "Cannot prepare private persistence".to_owned())
    }

    /// A `model_delta`, `model_end` or `model_error` frame from the
    /// gateway (other frames are ignored).
    pub fn receive(&self, frame: GatewayMessage) {
        if let Some(relay) = self.relay.get() {
            relay.receive(frame);
        }
    }

    /// The link dropped: every stream ends with `unavailable`, without
    /// `model_cancel`.
    pub fn disconnect(&self) {
        if let Some(relay) = self.relay.get() {
            relay.disconnect();
        }
    }

    /// Node shutdown: streams end with `unavailable` and `model_cancel`;
    /// connections close; the socket directory is removed.
    pub async fn close(&self) {
        if let Some(relay) = self.relay.get() {
            relay.close().await;
        }
    }
}

type Sender = Arc<dyn Fn(&NodeMessage) -> bool + Send + Sync>;
type GetModels = Arc<dyn Fn() -> Models + Send + Sync>;

/// What a stream's connection writes next.
enum Out {
    Line(String),
    /// The last line; the response ends.
    End(String),
}

struct Pending {
    scope: Arc<Scope>,
    out: mpsc::UnboundedSender<Out>,
    /// Bytes handed to the connection and not yet written
    /// (`response.writableLength`).
    queued: Arc<AtomicUsize>,
    /// Everything this stream carried so far.
    bytes: usize,
    timer: Option<AbortHandle>,
}

#[derive(Default)]
struct State {
    pending: HashMap<String, Pending>,
    scopes: HashMap<String, Arc<Scope>>,
    receiving: usize,
    closed: bool,
}

/// `startNodeInference`'s server, apart from the node (tests drive it with
/// their own `send` and catalog).
pub(crate) struct Relay {
    pub(crate) config: InferenceConfig,
    directory: PathBuf,
    send: Sender,
    get_models: GetModels,
    gate: Gate,
    timeout: Duration,
    state: Mutex<State>,
    connections: AtomicUsize,
    shutdown: watch::Sender<bool>,
    accept: Mutex<Option<tokio::task::JoinHandle<()>>>,
    persistence: Arc<crate::persistence::Writes>,
}

fn error_line(code: InferenceErrorCode) -> String {
    let mut line = json!({ "type": "model_error", "code": code }).to_string();
    line.push('\n');
    line
}

/// `mkdtemp(<dir>/i-)`: a new private directory.
fn make_directory(state_dir: &Path) -> Result<PathBuf, String> {
    use std::os::unix::fs::DirBuilderExt;
    let describe = |error: std::io::Error| format!("{}: {error}", state_dir.display());
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(state_dir)
        .map_err(describe)?;
    const LETTERS: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    loop {
        let suffix: String = random_bytes::<6>()
            .iter()
            .map(|byte| LETTERS[usize::from(*byte) % LETTERS.len()] as char)
            .collect();
        let directory = state_dir.join(format!("i-{suffix}"));
        match std::fs::DirBuilder::new().mode(0o700).create(&directory) {
            Ok(()) => return Ok(directory),
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(describe(error)),
        }
    }
}

impl Relay {
    async fn start(
        state_dir: &Path,
        send: Sender,
        get_models: GetModels,
        timeout: Duration,
        gate: Gate,
    ) -> Result<Arc<Self>, String> {
        use std::os::unix::fs::PermissionsExt;
        let directory = make_directory(state_dir)?;
        let config = InferenceConfig {
            socket_path: directory.join("socket").to_string_lossy().into_owned(),
            // Endpoint metadata has no usable Node-wide bearer credential.
            token: String::new(),
        };
        let listener = match pirc_protocol::SocketPath::new(Path::new(&config.socket_path))
            .and_then(|bind| UnixListener::bind(&bind.path))
            .and_then(|listener| {
                std::fs::set_permissions(
                    &config.socket_path,
                    std::fs::Permissions::from_mode(0o600),
                )
                .map(|()| listener)
            }) {
            Ok(listener) => listener,
            Err(error) => {
                let _ = std::fs::remove_dir_all(&directory);
                return Err(format!("{}: {error}", config.socket_path));
            }
        };
        let (shutdown, _) = watch::channel(false);
        let relay = Arc::new(Self {
            config,
            directory,
            send,
            get_models,
            gate,
            timeout,
            state: Mutex::default(),
            connections: AtomicUsize::new(0),
            shutdown,
            accept: Mutex::new(None),
            persistence: Arc::default(),
        });
        let accepting = tokio::spawn(accept(relay.clone(), listener));
        *relay
            .accept
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(accepting);
        Ok(relay)
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        self.state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// `send`: a failing sender is a refused frame.
    fn send(&self, message: &NodeMessage) -> bool {
        std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| (self.send)(message)))
            .unwrap_or(false)
    }

    fn remove(&self, request_id: &str) -> Option<Pending> {
        let pending = self.lock().pending.remove(request_id)?;
        if let Some(timer) = &pending.timer {
            timer.abort();
        }
        Some(pending)
    }

    fn fail(&self, request_id: &str, code: InferenceErrorCode, cancel: bool) {
        let Some(pending) = self.remove(request_id) else {
            return;
        };
        if cancel {
            self.send(&NodeMessage::ModelCancel {
                request_id: request_id.to_owned(),
            });
        }
        let _ = pending.out.send(Out::End(error_line(code)));
    }

    /// The agent's response closed before the stream ended.
    fn gone(&self, request_id: &str) {
        if self.remove(request_id).is_some() {
            self.send(&NodeMessage::ModelCancel {
                request_id: request_id.to_owned(),
            });
        }
    }

    pub(crate) fn receive(&self, frame: GatewayMessage) {
        let (request_id, event, end) = match frame {
            GatewayMessage::ModelDelta { request_id, delta } => (
                request_id,
                json!({ "type": "model_delta", "delta": delta }),
                false,
            ),
            GatewayMessage::ModelEnd {
                request_id,
                message,
            } => (
                request_id,
                json!({ "type": "model_end", "message": message }),
                true,
            ),
            GatewayMessage::ModelError { request_id, code } => (
                request_id,
                json!({ "type": "model_error", "code": code }),
                true,
            ),
            _ => return,
        };
        let mut line = event.to_string();
        line.push('\n');
        let size = line.len();
        let over = {
            let mut state = self.lock();
            let Some(pending) = state.pending.get_mut(&request_id) else {
                return;
            };
            pending.bytes += size;
            size > INFERENCE_BUFFER_MAX_BYTES
                || pending.queued.load(Ordering::Acquire) + size > INFERENCE_BUFFER_MAX_BYTES
                || pending.bytes > INFERENCE_STREAM_MAX_BYTES
        };
        if over {
            self.fail(&request_id, InferenceErrorCode::LimitExceeded, true);
            return;
        }
        if end {
            if let Some(pending) = self.remove(&request_id) {
                let _ = pending.out.send(Out::End(line));
            }
        } else if let Some(pending) = self.lock().pending.get(&request_id) {
            pending.queued.fetch_add(size, Ordering::AcqRel);
            let _ = pending.out.send(Out::Line(line));
        }
    }

    pub(crate) fn disconnect(&self) {
        let ids: Vec<String> = self.lock().pending.keys().cloned().collect();
        for id in ids {
            self.fail(&id, InferenceErrorCode::Unavailable, false);
        }
    }

    pub(crate) async fn close(&self) {
        let ids: Vec<String> = {
            let mut state = self.lock();
            if state.closed {
                return;
            }
            state.closed = true;
            state.pending.keys().cloned().collect()
        };
        for id in ids {
            self.fail(&id, InferenceErrorCode::Unavailable, true);
        }
        self.shutdown.send_replace(true);
        let accepting = self
            .accept
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .take();
        if let Some(accepting) = accepting {
            let _ = accepting.await;
        }
        let _ = tokio::fs::remove_dir_all(&self.directory).await;
    }
}

/// One counted connection: uncounted when its task ends, panics or is
/// dropped.
struct Connection(Arc<Relay>);

impl Drop for Connection {
    fn drop(&mut self) {
        self.0.connections.fetch_sub(1, Ordering::AcqRel);
    }
}

/// A request whose body is being read (`receiving`), counted the same way.
struct Receiving<'a>(&'a Relay);

impl Drop for Receiving<'_> {
    fn drop(&mut self) {
        self.0.lock().receiving -= 1;
    }
}

async fn accept(relay: Arc<Relay>, listener: UnixListener) {
    let mut shutdown = relay.shutdown.subscribe();
    loop {
        let accepted = tokio::select! {
            accepted = listener.accept() => accepted,
            _ = shutdown.wait_for(|closing| *closing) => return,
        };
        let Ok((stream, _)) = accepted else {
            tokio::time::sleep(ACCEPT_BACKOFF).await;
            continue;
        };
        // Over the limit, Node destroys the new socket at once.
        if relay.connections.fetch_add(1, Ordering::AcqRel) >= MAX_CONNECTIONS {
            relay.connections.fetch_sub(1, Ordering::AcqRel);
            drop(stream);
            continue;
        }
        let counted = Connection(relay.clone());
        tokio::spawn(async move {
            let relay = counted.0.clone();
            let mut shutdown = relay.shutdown.subscribe();
            let mut stream = stream;
            let serving = serve(&relay, &mut stream);
            tokio::pin!(serving);
            let closing = tokio::select! {
                () = &mut serving => false,
                _ = shutdown.wait_for(|closing| *closing) => true,
            };
            // `closeAllConnections` (streams were failed first): what they
            // still have to write gets a moment.
            if closing {
                let _ = tokio::time::timeout(CLOSE_FLUSH, &mut serving).await;
            }
            drop(counted);
        });
    }
}

/// A parsed request head.
struct Head {
    method: String,
    target: String,
    headers: Vec<(String, String)>,
}

impl Head {
    fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(key, _)| key.eq_ignore_ascii_case(name))
            .map(|(_, value)| value.as_str())
    }
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack
        .windows(needle.len())
        .position(|window| window == needle)
}

fn reason(status: u16) -> &'static str {
    match status {
        200 => "OK",
        400 => "Bad Request",
        401 => "Unauthorized",
        404 => "Not Found",
        408 => "Request Timeout",
        413 => "Payload Too Large",
        429 => "Too Many Requests",
        431 => "Request Header Fields Too Large",
        503 => "Service Unavailable",
        _ => "Error",
    }
}

async fn respond(stream: &mut UnixStream, status: u16, content_type: Option<&str>, body: &[u8]) {
    let mut head = format!("HTTP/1.1 {status} {}\r\n", reason(status));
    if let Some(content_type) = content_type {
        head.push_str(&format!(
            "Content-Type: {content_type}\r\nCache-Control: no-store\r\n"
        ));
    }
    head.push_str(&format!(
        "Content-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    ));
    let mut bytes = head.into_bytes();
    bytes.extend_from_slice(body);
    let _ = stream.write_all(&bytes).await;
    let _ = stream.shutdown().await;
}

/// `error(response, status, code)`: NDJSON even for 4xx.
async fn error(stream: &mut UnixStream, status: u16, code: InferenceErrorCode) {
    respond(
        stream,
        status,
        Some("application/x-ndjson"),
        error_line(code).as_bytes(),
    )
    .await;
}

/// Read until the head ends; `Err(status)` answers it plainly.
async fn read_head(stream: &mut UnixStream, buffer: &mut Vec<u8>) -> Result<Head, Option<u16>> {
    let end = loop {
        if let Some(end) = find(buffer, b"\r\n\r\n") {
            break end;
        }
        if buffer.len() > HEAD_MAX_BYTES {
            return Err(Some(431));
        }
        let mut chunk = [0; 8192];
        match stream.read(&mut chunk).await {
            Ok(0) | Err(_) => return Err(None),
            Ok(read) => buffer.extend_from_slice(&chunk[..read]),
        }
    };
    if end > HEAD_MAX_BYTES {
        return Err(Some(431));
    }
    let head = String::from_utf8_lossy(&buffer[..end]).into_owned();
    buffer.drain(..end + 4);
    let mut lines = head.split("\r\n");
    let mut request_line = lines.next().unwrap_or_default().split(' ');
    let (Some(method), Some(target), Some(version), None) = (
        request_line.next(),
        request_line.next(),
        request_line.next(),
        request_line.next(),
    ) else {
        return Err(Some(400));
    };
    if !version.starts_with("HTTP/1.") || method.is_empty() || target.is_empty() {
        return Err(Some(400));
    }
    let mut headers = Vec::new();
    for line in lines {
        let Some((name, value)) = line.split_once(':') else {
            return Err(Some(400));
        };
        headers.push((name.trim().to_owned(), value.trim().to_owned()));
    }
    Ok(Head {
        method: method.to_owned(),
        target: target.to_owned(),
        headers,
    })
}

/// Why a body could not be read.
enum BodyError {
    TooLarge,
    /// Malformed framing, the connection's end, or an I/O error.
    Broken,
}

async fn fill(stream: &mut UnixStream, buffer: &mut Vec<u8>) -> Result<(), BodyError> {
    let mut chunk = [0; 64 * 1024];
    match stream.read(&mut chunk).await {
        Ok(0) | Err(_) => Err(BodyError::Broken),
        Ok(read) => {
            buffer.extend_from_slice(&chunk[..read]);
            Ok(())
        }
    }
}

/// The request body, at most [`INFERENCE_REQUEST_MAX_BYTES`].
async fn read_body(
    stream: &mut UnixStream,
    head: &Head,
    mut buffer: Vec<u8>,
) -> Result<Vec<u8>, BodyError> {
    let chunked = head.header("transfer-encoding").is_some_and(|coding| {
        coding
            .rsplit(',')
            .next()
            .is_some_and(|last| last.trim().eq_ignore_ascii_case("chunked"))
    });
    if !chunked {
        let length = match head.header("content-length") {
            None => 0,
            Some(length) => length.parse::<usize>().map_err(|_| BodyError::Broken)?,
        };
        if length > INFERENCE_REQUEST_MAX_BYTES {
            return Err(BodyError::TooLarge);
        }
        while buffer.len() < length {
            fill(stream, &mut buffer).await?;
        }
        buffer.truncate(length);
        return Ok(buffer);
    }
    let mut body = Vec::new();
    loop {
        let line_end = loop {
            if let Some(end) = find(&buffer, b"\r\n") {
                break end;
            }
            if buffer.len() > 8192 {
                return Err(BodyError::Broken);
            }
            fill(stream, &mut buffer).await?;
        };
        let size_text = String::from_utf8_lossy(&buffer[..line_end]).into_owned();
        let size_text = size_text.split(';').next().unwrap_or_default().trim();
        if size_text.is_empty()
            || size_text.len() > CHUNK_SIZE_MAX_DIGITS
            || !size_text.bytes().all(|byte| byte.is_ascii_hexdigit())
        {
            return Err(BodyError::Broken);
        }
        let size = usize::from_str_radix(size_text, 16).map_err(|_| BodyError::Broken)?;
        buffer.drain(..line_end + 2);
        if size == 0 {
            return Ok(body);
        }
        // Never `body.len() + size`: an agent-chosen size could overflow.
        if size > INFERENCE_REQUEST_MAX_BYTES - body.len() {
            return Err(BodyError::TooLarge);
        }
        while buffer.len() < size + 2 {
            fill(stream, &mut buffer).await?;
        }
        body.extend_from_slice(&buffer[..size]);
        buffer.drain(..size + 2);
    }
}

/// `inferenceRequestSchema`: the shape (serde, strict at the top) and the
/// lengths serde does not check, in UTF-16 units.
pub(crate) fn inference_request(value: Value) -> Option<InferenceRequest> {
    let request: InferenceRequest = serde_json::from_value(value).ok()?;
    let within = |text: &str, max: usize| (1..=max).contains(&utf16_len(text));
    let valid = within(&request.provider_name, 200)
        && within(&request.model_id, 500)
        && request.messages.len() <= 20_000
        && request.tools.len() <= 1000
        && request.tools.iter().all(|tool| within(&tool.name, 200))
        && within(&request.session_id, 500)
        && request
            .max_tokens
            .is_none_or(|max| (1..=1_000_000).contains(&max));
    valid.then_some(request)
}

/// One connection: one request, then closed.
async fn serve(relay: &Arc<Relay>, stream: &mut UnixStream) {
    let deadline = Instant::now() + REQUEST_TIMEOUT;
    let mut buffer = Vec::new();
    let head = match tokio::time::timeout_at(deadline, read_head(stream, &mut buffer)).await {
        Ok(Ok(head)) => head,
        Ok(Err(Some(status))) => return respond(stream, status, None, b"").await,
        Ok(Err(None)) | Err(_) => return,
    };
    if head.method == "POST" && head.target == "/persistence" {
        let token = head
            .header("authorization")
            .unwrap_or_default()
            .strip_prefix("Bearer ")
            .unwrap_or_default()
            .to_owned();
        if relay.lock().closed || !relay.persistence.authorized(&token) {
            return error(stream, 401, InferenceErrorCode::Unavailable).await;
        }
        let body = match tokio::time::timeout_at(deadline, read_body(stream, &head, buffer)).await {
            Ok(Ok(body)) => body,
            _ => return error(stream, 400, InferenceErrorCode::InvalidRequest).await,
        };
        let Ok(value) = serde_json::from_slice(&body) else {
            return error(stream, 400, InferenceErrorCode::InvalidRequest).await;
        };
        let writes = relay.persistence.clone();
        let result =
            tokio::task::spawn_blocking(move || writes.apply_response(&token, value)).await;
        let (status, body) = match result {
            Ok(Ok(value)) => (200, value),
            failure => {
                let text = match failure {
                    Ok(Err(e)) => e.to_string(),
                    _ => String::new(),
                };
                let code = text.split(':').next().unwrap_or("");
                let safe = if code.starts_with("writer_")
                    || code.starts_with("journal_")
                    || code.starts_with("invalid_")
                    || code == "commit_outcome_unknown_reopen"
                {
                    code
                } else {
                    "persistence_refused"
                };
                (400, serde_json::json!({"ok":false,"error":safe}))
            }
        };
        return respond(
            stream,
            status,
            Some("application/json"),
            &serde_json::to_vec(&body).unwrap(),
        )
        .await;
    }
    let Some(scope) = relay.authenticate(head.header("authorization").unwrap_or_default()) else {
        return error(stream, 401, InferenceErrorCode::Unavailable).await;
    };
    if relay.lock().closed {
        return error(stream, 503, InferenceErrorCode::Unavailable).await;
    }
    if head.method == "GET" && head.target == "/models" {
        let mut models = None;
        if !relay.authorized(&scope, &mut || {
            let mut catalog = (relay.get_models)();
            catalog.inference = Some(scope.config.clone());
            models = Some(catalog);
        }) {
            return error(stream, 401, InferenceErrorCode::Unavailable).await;
        }
        let body = serde_json::to_vec(&models).unwrap_or_default();
        if body.len() > INFERENCE_BUFFER_MAX_BYTES {
            return error(stream, 503, InferenceErrorCode::LimitExceeded).await;
        }
        return respond(stream, 200, Some("application/json"), &body).await;
    }
    if head.method != "POST" || head.target != "/inference" {
        return error(stream, 404, InferenceErrorCode::InvalidRequest).await;
    }
    let admitted = {
        let mut state = relay.lock();
        let admitted = state.pending.len() + state.receiving < INFERENCE_MAX_REQUESTS;
        if admitted {
            state.receiving += 1;
        }
        admitted
    };
    if !admitted {
        return error(stream, 429, InferenceErrorCode::LimitExceeded).await;
    }
    let receiving = Receiving(relay);
    let body = tokio::time::timeout_at(deadline, read_body(stream, &head, buffer)).await;
    drop(receiving);
    let body = match body {
        Ok(Ok(body)) => body,
        Ok(Err(BodyError::TooLarge)) => {
            return error(stream, 413, InferenceErrorCode::LimitExceeded).await;
        }
        // `request.destroy()`: the connection goes without an answer.
        Ok(Err(BodyError::Broken)) | Err(_) => return,
    };
    if relay.lock().closed {
        return;
    }
    let Some(request) = serde_json::from_slice::<Value>(&body)
        .ok()
        .and_then(inference_request)
    else {
        return error(stream, 400, InferenceErrorCode::InvalidRequest).await;
    };
    stream_response(relay, stream, request, scope).await;
}

/// An accepted request: the NDJSON stream of its relay.
async fn stream_response(
    relay: &Arc<Relay>,
    stream: &mut UnixStream,
    request: InferenceRequest,
    scope: Arc<Scope>,
) {
    let head = "HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\n\
                Cache-Control: no-store\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n";
    if stream.write_all(head.as_bytes()).await.is_err() {
        return;
    }
    let request_id = uuid();
    let (out, mut lines) = mpsc::unbounded_channel();
    let queued = Arc::new(AtomicUsize::new(0));
    let mut revoked = scope.revoked.subscribe();
    let start = NodeMessage::ModelStart {
        request_id: request_id.clone(),
        request,
        session: scope.identity.session.clone(),
    };
    let admitted = relay.authorized(&scope, &mut || {
        relay.lock().pending.insert(
            request_id.clone(),
            Pending {
                scope: scope.clone(),
                out: out.clone(),
                queued: queued.clone(),
                bytes: 0,
                timer: None,
            },
        );
        // The scope and database fence span enqueue: revoke cannot cancel a
        // request before its start or allow a body read to resume old authority.
        if !relay.send(&start) {
            relay.fail(&request_id, InferenceErrorCode::Unavailable, false);
            return;
        }
        let timer = {
            let timeout = relay.timeout;
            let weak = Arc::downgrade(relay);
            let id = request_id.clone();
            tokio::spawn(async move {
                tokio::time::sleep(timeout).await;
                if let Some(relay) = weak.upgrade() {
                    relay.fail(&id, InferenceErrorCode::Timeout, true);
                }
            })
            .abort_handle()
        };
        if let Some(pending) = relay.lock().pending.get_mut(&request_id) {
            pending.timer = Some(timer);
        } else {
            timer.abort();
        }
    });
    if !admitted {
        let _ = out.send(Out::End(error_line(InferenceErrorCode::Unavailable)));
    }
    drop(out);
    let mut probe = [0; 1024];
    loop {
        tokio::select! {
            biased;
            _ = async { let _ = revoked.wait_for(|revoked| *revoked).await; } => {
                // Discard queued old-generation output. Bytes already written
                // to the OS socket cannot be recalled; this is not tool revocation.
                let line = error_line(InferenceErrorCode::Unavailable);
                let chunk = format!("{:x}\r\n{}\r\n0\r\n\r\n", line.len(), line);
                let _ = tokio::time::timeout(CLOSE_FLUSH, stream.write_all(chunk.as_bytes())).await;
                let _ = stream.shutdown().await;
                return relay.gone(&request_id);
            }
            next = lines.recv() => {
                let (line, last) = match next {
                    Some(Out::Line(line)) => (line, false),
                    Some(Out::End(line)) => (line, true),
                    None => (String::new(), true),
                };
                let mut chunk = Vec::with_capacity(line.len() + 16);
                if !line.is_empty() {
                    chunk.extend_from_slice(format!("{:x}\r\n", line.len()).as_bytes());
                    chunk.extend_from_slice(line.as_bytes());
                    chunk.extend_from_slice(b"\r\n");
                }
                if last {
                    chunk.extend_from_slice(b"0\r\n\r\n");
                }
                let written = tokio::select! {
                    biased;
                    _ = async { let _ = revoked.wait_for(|revoked| *revoked).await; } => {
                        // A partial chunk cannot safely be followed by a new
                        // NDJSON frame. Close instead of forwarding its remainder.
                        let _ = stream.shutdown().await;
                        return relay.gone(&request_id);
                    }
                    written = stream.write_all(&chunk) => written,
                };
                if !last {
                    queued.fetch_sub(line.len(), Ordering::AcqRel);
                }
                if written.is_err() {
                    return relay.gone(&request_id);
                }
                if last {
                    let _ = stream.shutdown().await;
                    return;
                }
            }
            read = stream.read(&mut probe) => {
                // The agent closed its end (an abort): `response.on('close')`.
                if matches!(read, Ok(0) | Err(_)) {
                    return relay.gone(&request_id);
                }
            }
        }
    }
}

#[cfg(test)]
mod tests;
