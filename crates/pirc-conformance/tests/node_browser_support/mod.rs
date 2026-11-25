//! Shared by the `node_browser` scenarios: a real node with its real
//! Chromium, driven by the test playing the gateway ([`FakeGateway`] +
//! [`LoneNode`], as in `node_link_side.rs`), the fixture pages of the
//! browser golden corpus (`crates/pirc-node/tests/fixtures/browser`) served
//! on loopback, and a viewer stream over the node link.
//!
//! The scenarios need a Chromium: `PIRC_BROWSER_EXECUTABLE`, else the first
//! of `chromium`, `chromium-browser`, `google-chrome-stable`, `google-chrome`,
//! `microsoft-edge` on `PATH` (as the node itself looks), else the macOS
//! application bundles. Without one they are skipped with a message, also
//! under `PIRC_CONFORMANCE_REQUIRED`, but not under `PIRC_BROWSER_REQUIRED=1`
//! (CI): then the Chromium must be `PIRC_BROWSER_EXECUTABLE`, an existing
//! file (no fallback to another browser on `PATH`), and the recording
//! scenario's ffmpeg must be found; anything missing fails the scenario.

#![allow(dead_code)]

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use axum::Router;
use axum::body::Body;
use axum::extract::Query;
use axum::http::{Response, StatusCode, Uri};
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use pirc_conformance::{FakeGateway, LoneNode, NodeOptions, Transcript};
use serde_json::{Value, json};

use crate::node_link_side_support::{Gateway, last_message, models, registered};

/// The fake model, accepting images (screenshots reach it as image blocks).
fn image_models() -> Value {
    let mut models = models("fake", "fake-model", "low");
    models["providers"]["fake"]["models"][0]["input"] = json!(["text", "image"]);
    models
}

/// How long one agent turn (a `ptc` script of browser calls) may take.
pub const TURN: Duration = Duration::from_secs(120);

/// The fixture pages of the browser golden corpus.
pub fn pages_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../pirc-node/tests/fixtures/browser/pages")
}

/// `PIRC_BROWSER_REQUIRED=1`: a missing Chromium or ffmpeg fails instead
/// of skipping.
pub fn required() -> bool {
    std::env::var_os("PIRC_BROWSER_REQUIRED").is_some_and(|value| value == "1")
}

/// The Chromium the scenarios use, found the way the node finds one.
pub fn browser_executable() -> Option<PathBuf> {
    if required() {
        let explicit = std::env::var_os("PIRC_BROWSER_EXECUTABLE")
            .filter(|path| !path.is_empty())
            .expect("PIRC_BROWSER_REQUIRED=1 needs PIRC_BROWSER_EXECUTABLE");
        let explicit = PathBuf::from(explicit);
        assert!(
            explicit.is_absolute() && explicit.is_file(),
            "PIRC_BROWSER_EXECUTABLE={explicit:?} is not an absolute path to a file"
        );
        return Some(explicit);
    }
    if let Some(path) = std::env::var_os("PIRC_BROWSER_EXECUTABLE").filter(|p| !p.is_empty()) {
        let path = PathBuf::from(path);
        return Some(if path.is_absolute() {
            path
        } else {
            on_path(&path.display().to_string())?
        });
    }
    [
        "chromium",
        "chromium-browser",
        "google-chrome-stable",
        "google-chrome",
        "microsoft-edge",
    ]
    .iter()
    .find_map(|name| on_path(name))
    .or_else(|| {
        [
            "/Applications/Chromium.app/Contents/MacOS/Chromium",
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        ]
        .iter()
        .map(PathBuf::from)
        .find(|path| path.is_file())
    })
}

/// `ffmpeg` for recordings: `PIRC_FFMPEG`, else `ffmpeg` on `PATH`.
pub fn ffmpeg() -> Option<PathBuf> {
    match std::env::var_os("PIRC_FFMPEG").filter(|p| !p.is_empty()) {
        Some(path) if Path::new(&path).is_absolute() => Some(PathBuf::from(path)),
        Some(path) => on_path(&path.to_string_lossy()),
        None => on_path("ffmpeg"),
    }
}

fn on_path(name: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path)
        .map(|dir| dir.join(name))
        .find(|candidate| candidate.is_file())
}

/// The fixture server: `127.0.0.1:<port>` (`{{HOST_A}}` in the pages) and
/// `localhost:<port>` (`{{HOST_B}}`) are two sites on one port; see the
/// corpus README for the routes.
pub struct Site {
    pub port: u16,
    task: tokio::task::JoinHandle<()>,
}

impl Site {
    pub async fn start() -> Self {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("fixture server");
        let port = listener.local_addr().unwrap().port();
        let app = Router::new().fallback(
            move |uri: Uri, Query(query): Query<HashMap<String, String>>| async move {
                serve(port, &uri, &query).await
            },
        );
        let task = tokio::spawn(async move {
            axum::serve(listener, app).await.expect("fixture server");
        });
        Self { port, task }
    }

    /// `http://127.0.0.1:<port><path>`
    pub fn a(&self, path: &str) -> String {
        format!("http://127.0.0.1:{}{path}", self.port)
    }

    /// `http://localhost:<port><path>`
    pub fn b(&self, path: &str) -> String {
        format!("http://localhost:{}{path}", self.port)
    }
}

impl Drop for Site {
    fn drop(&mut self) {
        self.task.abort();
    }
}

async fn serve(port: u16, uri: &Uri, query: &HashMap<String, String>) -> Response<Body> {
    let path = uri.path();
    let response = Response::builder();
    if path == "/slow" {
        let ms = query
            .get("ms")
            .and_then(|ms| ms.parse::<u64>().ok())
            .unwrap_or(0)
            .min(10_000);
        tokio::time::sleep(Duration::from_millis(ms)).await;
        return response
            .header("content-type", "text/plain; charset=utf-8")
            .header("cache-control", "no-store")
            .body(Body::from(query.get("text").cloned().unwrap_or_default()))
            .unwrap();
    }
    if path == "/redirect" {
        return response
            .status(StatusCode::FOUND)
            .header("location", query.get("to").map_or("/", String::as_str))
            .body(Body::empty())
            .unwrap();
    }
    if let Some(code) = path
        .strip_prefix("/status/")
        .filter(|code| code.len() == 3)
        .and_then(|code| code.parse::<u16>().ok())
    {
        return response
            .status(code)
            .header("content-type", "text/html; charset=utf-8")
            .body(Body::from(format!(
                "<!doctype html><title>Status {code}</title><p>Status {code}</p>"
            )))
            .unwrap();
    }
    let name = &path[1..];
    let page = name.strip_suffix(".html").is_some_and(|stem| {
        !stem.is_empty()
            && stem
                .bytes()
                .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
    });
    if page && let Ok(html) = std::fs::read_to_string(pages_dir().join(name)) {
        let html = html
            .replace("{{HOST_A}}", &format!("127.0.0.1:{port}"))
            .replace("{{HOST_B}}", &format!("localhost:{port}"))
            .replace("{{PORT}}", &port.to_string());
        return response
            .header("content-type", "text/html; charset=utf-8")
            .header("cache-control", "no-store")
            .body(Body::from(html))
            .unwrap();
    }
    response
        .status(StatusCode::NOT_FOUND)
        .header("content-type", "text/plain; charset=utf-8")
        .body(Body::from("Not found"))
        .unwrap()
}

/// A node with a browser, registered with the test's gateway, its fixture
/// site, and a transcript that writes the site's port as `<site-port>`.
pub struct Browsing {
    pub gw: Gateway,
    pub site: Site,
    pub node: LoneNode,
    pub t: Transcript,
}

/// The node's browser settings: everything explicit, because the node's
/// environment is cleared.
fn browser_env(executable: &Path, extra: &[(&'static str, String)]) -> Vec<(&'static str, String)> {
    let mut env = vec![
        // This fixture plays the UI without its periodic control heartbeat.
        // A scenario spans several TURNs; lease expiry is covered separately.
        // Keep only this test node's lease alive through the browser workflow.
        ("PIRC_LEASE_TTL_MS", (TURN.as_millis() * 10).to_string()),
        ("PIRC_BROWSER", "true".to_owned()),
        ("PIRC_BROWSER_EXECUTABLE", executable.display().to_string()),
        // The fixture sites; `*.localhost` names stay refused.
        (
            "PIRC_BROWSER_ALLOW_PRIVATE",
            "127.0.0.1,localhost".to_owned(),
        ),
        // Refused as the gateway's other host names are.
        ("PIRC_BROWSER_BLOCK_HOSTS", "gateway.localhost".to_owned()),
        // `{run_dir}`: the node's run directory (see `Cluster::spawn_node`).
        (
            "PIRC_BROWSER_PROFILES_DIR",
            "{run_dir}/browser-profiles".to_owned(),
        ),
        (
            "PIRC_BROWSER_VIEWPORT",
            format!("{}x{}", VIEWPORT.0, VIEWPORT.1),
        ),
    ];
    if let Some(ffmpeg) = ffmpeg() {
        env.push(("PIRC_FFMPEG", ffmpeg.display().to_string()));
    }
    for (name, value) in extra {
        env.retain(|(existing, _)| existing != name);
        env.push((name, value.clone()));
    }
    env
}

/// Start the site and a node with a browser, and register the node; `None`
/// (test skipped) without a Chromium or without executables under test.
pub async fn start(chat_node: bool, extra: &[(&'static str, String)]) -> Option<Browsing> {
    let Some(executable) = browser_executable() else {
        eprintln!(
            "no Chromium found (PIRC_BROWSER_EXECUTABLE, chromium on PATH); \
             skipping browser conformance test"
        );
        return None;
    };
    let site = Site::start().await;
    let server = FakeGateway::bind().await;
    let node = LoneNode::start_with(
        server.port(),
        NodeOptions {
            chat_node,
            env: browser_env(&executable, extra),
            ..NodeOptions::default()
        },
    )?;
    let mut literals = node.volatile();
    literals.push((format!(":{}", site.port), ":<site-port>"));
    literals.push((format!("%3A{}", site.port), "%3A<site-port>"));
    let t = Transcript::new(literals);
    let mut gw = Gateway::new(server.accept().await);
    gw.link.recv().await;
    gw.link.send(&registered(image_models(), json!({}))).await;
    gw.wait(|frame| frame["type"] == "activity").await;
    Some(Browsing { gw, site, node, t })
}

impl Browsing {
    /// Create a session in `workspace`, take control: `(id, generation)`.
    pub async fn session(&mut self, workspace: &str) -> (String, Value) {
        let created = self
            .gw
            .ask(
                "POST",
                "/api/session-creations/internal",
                Some(json!({ "workspaceId": workspace })),
            )
            .await;
        let session = created["data"]["body"]["session"]["id"]
            .as_str()
            .unwrap_or_else(|| panic!("no session: {created}"))
            .to_owned();
        let acquired = self
            .gw
            .ask(
                "POST",
                &format!("/api/sessions/{session}/control/acquire"),
                Some(json!({ "clientId": "browser" })),
            )
            .await;
        (
            session,
            acquired["data"]["body"]["lease"]["generation"].clone(),
        )
    }

    /// The next `model_start`, within [`TURN`].
    pub async fn model_start(&mut self) -> Value {
        wait_frame(&mut self.gw, TURN, |frame| frame["type"] == "model_start").await
    }

    /// Answer `start` with a `ptc` call running `body` (see [`script`]) and
    /// return the next model request and the script's outcomes.
    pub async fn run(&mut self, start: &Value, call_id: &str, body: &str) -> (Value, Value) {
        self.gw
            .reply_tool(start, call_id, "ptc", json!({ "code": script(body) }))
            .await;
        let next = self.model_start().await;
        let outcome = ptc_outcome(&next);
        (next, outcome)
    }
}

/// The earliest frame satisfying `wanted` that a viewer's wait has already
/// set aside in `link.skipped`, else the next one within `deadline` (others
/// go to `link.skipped`, where a [`Viewer`] finds its frames).
pub async fn wait_frame(
    gw: &mut Gateway,
    deadline: Duration,
    wanted: impl Fn(&Value) -> bool,
) -> Value {
    if let Some(index) = gw.link.skipped.iter().position(&wanted) {
        return gw.link.skipped.remove(index);
    }
    match tokio::time::timeout(deadline, gw.link.recv_where(wanted)).await {
        Ok(frame) => frame,
        Err(_) => panic!("timed out waiting for a node frame"),
    }
}

/// A `ptc` script: `body` calls `call('<name>', args)` for each tool call
/// (recording `{ call, args, data, attachments }` or `{ call, args, error }`)
/// and may use `ref(result, regex)`, the ref on the first snapshot line of
/// `result` matching `regex`. The script returns the recorded outcomes.
/// Capability names must be literals in `tools.call`, so each
/// `call('<name>', args)` becomes `record('<name>', args, await
/// tools.call('<name>', args))` (`args` is evaluated twice: keep it pure).
pub fn script(body: &str) -> String {
    format!(
        r#"const out = [];
const record = (name, args, r) => {{
  out.push(r.ok ? {{ call: name, args, data: r.data, attachments: r.attachments }} : {{ call: name, args, error: r.error }});
  return r;
}};
const ref = (r, pattern) => {{
  const text = (r.ok && r.data && r.data.snapshot && r.data.snapshot.text) || '';
  const line = text.split('\n').find((l) => new RegExp(pattern).test(l) && /\[ref=/.test(l));
  return line ? /\[ref=([a-z0-9]+)\]/.exec(line)[1] : 'no-such-ref';
}};
{}
return JSON.stringify(out);"#,
        literal_calls(body)
    )
}

/// `call('<name>', args)` → `record('<name>', args, await tools.call('<name>', args))`.
fn literal_calls(body: &str) -> String {
    let mut out = String::new();
    let mut rest = body;
    while let Some(at) = rest.find("call('") {
        // Not `tools.call(`.
        if rest[..at].ends_with('.') {
            out.push_str(&rest[..at + 6]);
            rest = &rest[at + 6..];
            continue;
        }
        out.push_str(&rest[..at]);
        let after = &rest[at + 6..];
        let quote = after.find('\'').expect("capability name");
        let name = &after[..quote];
        let args_start = after[quote..].find(", ").expect("arguments") + quote + 2;
        let mut depth = 1;
        let mut end = args_start;
        for (index, c) in after[args_start..].char_indices() {
            match c {
                '(' => depth += 1,
                ')' => depth -= 1,
                _ => {}
            }
            if depth == 0 {
                end = args_start + index;
                break;
            }
        }
        let args = &after[args_start..end];
        out.push_str(&format!(
            "record('{name}', {args}, await tools.call('{name}', {args}))"
        ));
        rest = &after[end + 1..];
    }
    out.push_str(rest);
    out
}

/// The outcome of the `ptc` call the model request `start` answers: the
/// script's recorded calls (parsed out of the agent's untrusted-content
/// envelope, whose notice is kept), or the tool result as it is. A call's
/// `data.text` (the agent's text for the model, covered by the agent
/// scenarios) is left out.
pub fn ptc_outcome(start: &Value) -> Value {
    let message = last_message(start);
    let content = message["content"].as_array().cloned().unwrap_or_default();
    let text = content
        .first()
        .and_then(|block| block["text"].as_str())
        .unwrap_or_default();
    let (notice, inner) = match (text.find("<<<PTC_RESULT"), text.find("<<<END_PTC_RESULT")) {
        (Some(open), Some(close)) => {
            let body = &text[open..close];
            let body = body.split_once('\n').map_or("", |(_, rest)| rest);
            (Some(text[..open].trim_end()), body.trim_end())
        }
        _ => (None, text),
    };
    match serde_json::from_str::<Value>(inner) {
        Ok(Value::Array(mut calls)) => {
            for call in &mut calls {
                if let Some(data) = call.get_mut("data").and_then(Value::as_object_mut) {
                    data.remove("text");
                }
            }
            let mut outcome = json!({ "calls": attachments(&images(&Value::Array(calls))) });
            if let Some(notice) = notice {
                outcome["notice"] = json!(notice);
            }
            if content.len() > 1 {
                outcome["more content"] = images(&json!(content[1..]));
            }
            outcome
        }
        _ => images(&mask_web_results(
            json!({ "toolName": message["toolName"], "isError": message["isError"],
                "content": content }),
        )),
    }
}

/// Image descriptors of `ptc` operations (`{ handle, mimeType, bytes }`):
/// the handle (a hash of the bytes) becomes `<attachment>`, and a size over
/// 1000 bytes `<over 1000>`.
fn attachments(value: &Value) -> Value {
    match value {
        Value::Array(items) => items.iter().map(attachments).collect(),
        Value::Object(object) if object.contains_key("handle") && object.contains_key("bytes") => {
            let mut object = object.clone();
            object.insert("handle".to_owned(), json!("<attachment>"));
            if object["bytes"].as_u64().is_some_and(|bytes| bytes > 1000) {
                object.insert("bytes".to_owned(), json!("<over 1000>"));
            }
            Value::Object(object)
        }
        Value::Object(object) => Value::Object(
            object
                .iter()
                .map(|(key, item)| (key.clone(), attachments(item)))
                .collect(),
        ),
        _ => value.clone(),
    }
}

/// The random fence id of the agent's web results.
pub fn mask_web_results(value: Value) -> Value {
    let fence = regex::Regex::new(r"(WEB_RESULTS|PTC_RESULT) id=[0-9a-f]{12}").unwrap();
    serde_json::from_str(&fence.replace_all(&value.to_string(), "$1 id=<fence>")).unwrap()
}

/// `value` with base64 JPEG and WebM data replaced by `<jpeg WxH>` and
/// `<webm>`: what an image is, not its bytes.
pub fn images(value: &Value) -> Value {
    match value {
        Value::String(text) => match media(text) {
            Some(kind) => json!(kind),
            None => value.clone(),
        },
        Value::Array(items) => items.iter().map(images).collect(),
        Value::Object(object) => Value::Object(
            object
                .iter()
                .map(|(key, item)| (key.clone(), images(item)))
                .collect(),
        ),
        _ => value.clone(),
    }
}

fn media(text: &str) -> Option<String> {
    if text.len() < 64 {
        return None;
    }
    let data = text
        .strip_prefix("data:")
        .and_then(|rest| rest.split_once(";base64,"))
        .map_or(text, |(_, data)| data);
    let bytes = STANDARD.decode(data).ok()?;
    if bytes.starts_with(&[0x1a, 0x45, 0xdf, 0xa3]) {
        return Some("<webm>".to_owned());
    }
    let (width, height) = jpeg_size(&bytes)?;
    Some(format!("<jpeg {width}x{height}>"))
}

/// A baseline or progressive JPEG's size, from its first SOF marker.
pub fn jpeg_size(bytes: &[u8]) -> Option<(u16, u16)> {
    if !bytes.starts_with(&[0xff, 0xd8]) {
        return None;
    }
    let mut at = 2;
    while at + 9 < bytes.len() {
        if bytes[at] != 0xff {
            return None;
        }
        let marker = bytes[at + 1];
        let length = u16::from_be_bytes([bytes[at + 2], bytes[at + 3]]) as usize;
        if (0xc0..=0xcf).contains(&marker) && ![0xc4, 0xc8, 0xcc].contains(&marker) {
            let height = u16::from_be_bytes([bytes[at + 5], bytes[at + 6]]);
            let width = u16::from_be_bytes([bytes[at + 7], bytes[at + 8]]);
            return Some((width, height));
        }
        at += 2 + length;
    }
    None
}

/// The side panel's browser socket, relayed over the node link
/// (`terminal_open` with `kind: "browser"`). Live `frame`s are kept as
/// `<jpeg WxH>` summaries.
pub struct Viewer {
    pub stream: String,
    pub frames: Vec<Value>,
    /// Frames a wait has returned.
    taken: Vec<bool>,
    /// Waits look at frames from here on ([`Viewer::now`]).
    floor: usize,
    pub closed: Option<Value>,
}

impl Viewer {
    pub async fn open(gw: &mut Gateway, stream: &str, session: &str) -> Self {
        gw.link
            .send(&json!({ "type": "terminal_open", "streamId": stream,
                "user": pirc_conformance::USER, "sessionId": session,
                "terminalId": "browser", "kind": "browser" }))
            .await;
        Self {
            stream: stream.to_owned(),
            frames: Vec::new(),
            taken: Vec::new(),
            floor: 0,
            closed: None,
        }
    }

    pub async fn input(&self, gw: &mut Gateway, message: Value) {
        gw.link
            .send(&json!({ "type": "terminal_input", "streamId": self.stream,
                "message": message }))
            .await;
    }

    pub async fn close(&self, gw: &mut Gateway) {
        gw.link
            .send(&json!({ "type": "terminal_close", "streamId": self.stream }))
            .await;
    }

    /// Move this stream's frames out of `link.skipped`.
    pub fn absorb(&mut self, gw: &mut Gateway) {
        let stream = self.stream.clone();
        let mut kept = Vec::new();
        for frame in gw.link.skipped.drain(..) {
            if frame["streamId"] != stream.as_str() {
                kept.push(frame);
            } else if frame["type"] == "terminal_frame" {
                self.frames.push(images(&frame["frame"]));
                self.taken.push(false);
            } else if frame["type"] == "terminal_closed" {
                self.closed = Some(json!({ "code": frame["code"], "reason": frame["reason"] }));
            } else {
                kept.push(frame);
            }
        }
        gw.link.skipped = kept;
    }

    /// The earliest frame since the floor ([`Viewer::now`]) that no wait
    /// has returned yet and that satisfies `wanted`; waits for it.
    pub async fn wait(&mut self, gw: &mut Gateway, wanted: impl Fn(&Value) -> bool) -> Value {
        let deadline = Instant::now() + TURN;
        loop {
            self.absorb(gw);
            let found = (self.floor..self.frames.len())
                .find(|&index| !self.taken[index] && wanted(&self.frames[index]));
            if let Some(index) = found {
                self.taken[index] = true;
                return self.frames[index].clone();
            }
            let left = deadline.saturating_duration_since(Instant::now());
            assert!(
                !left.is_zero(),
                "timed out waiting for a browser frame; got {}",
                self.summary()
            );
            match tokio::time::timeout(left, gw.link.recv()).await {
                Ok(frame) => gw.link.skipped.push(frame),
                Err(_) => panic!(
                    "timed out waiting for a browser frame; got {}",
                    self.summary()
                ),
            }
        }
    }

    /// Later waits only look at frames from now on: call before the action
    /// whose frames a test waits for. Returns the floor, for [`Viewer::of`].
    pub fn now(&mut self, gw: &mut Gateway) -> usize {
        self.absorb(gw);
        self.floor = self.frames.len();
        self.floor
    }

    /// The frames of `kinds` since `from` (an index into `frames`).
    pub fn of(&self, from: usize, kinds: &[&str]) -> Vec<Value> {
        self.frames[from..]
            .iter()
            .filter(|frame| kinds.iter().any(|kind| frame["type"] == *kind))
            .cloned()
            .collect()
    }

    fn summary(&self) -> String {
        let mut text = format!("({} frames, floor {})", self.frames.len(), self.floor);
        for frame in &self.frames[self.floor..] {
            let mut line = frame.to_string();
            line.truncate(300);
            text.push('\n');
            text.push_str(&line);
        }
        text
    }
}

/// A `state` frame satisfying `wanted` on its state.
pub fn state(wanted: impl Fn(&Value) -> bool) -> impl Fn(&Value) -> bool {
    move |frame: &Value| frame["type"] == "state" && wanted(&frame["state"])
}

/// A `log_entry` frame whose action is `action`.
pub fn entry(action: &str) -> impl Fn(&Value) -> bool + '_ {
    move |frame: &Value| frame["type"] == "log_entry" && frame["entry"]["action"] == action
}

/// A frame of type `kind`.
pub fn kind(kind: &str) -> impl Fn(&Value) -> bool + '_ {
    move |frame: &Value| frame["type"] == kind
}

/// The browsers' viewport (`PIRC_BROWSER_VIEWPORT`).
pub const VIEWPORT: (u16, u16) = (1280, 800);

/// A live `frame` whose image has the viewport's size. Chromium may
/// capture a screencast's first frames before the viewport emulation's
/// resize (their metadata already says the viewport's size); Playwright
/// hands them on, so the TS node may send one first.
pub fn viewport_frame(frame: &Value) -> bool {
    frame["type"] == "frame" && frame["data"] == format!("<jpeg {}x{}>", VIEWPORT.0, VIEWPORT.1)
}
