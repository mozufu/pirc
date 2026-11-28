//! The netio area of the native browser against a real Chromium: the host
//! guard on requests and WebSockets (`engine::network`), keyboard and
//! mouse (`engine::input`), screenshots and the screencast. Each test
//! launches Chromium as the engine does and drives one CDP page session
//! directly (the page/frame layer is tested elsewhere).
//!
//! Skipped, with a message, when no Chromium is found (`chromium`,
//! `chromium-browser`, `google-chrome-stable`, `google-chrome`,
//! `microsoft-edge` on PATH, or the macOS application bundles), or
//! `PIRC_BROWSER_EXECUTABLE`; with `PIRC_BROWSER_REQUIRED=1` (CI) they fail
//! instead, and use `PIRC_BROWSER_EXECUTABLE` only.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use pirc_node::browser::BoxFuture;
use pirc_node::browser::engine::LoadState;
use pirc_node::browser::engine::cdp::{Connection, Session};
use pirc_node::browser::engine::context::{Context, LaunchOptions};
use pirc_node::browser::engine::launch;
use pirc_node::browser::engine::network::{self, TargetKind};
use pirc_node::browser::engine::screencast::{
    self, ScreencastFrame, ScreencastOptions, ScreencastState,
};
use pirc_node::browser::engine::screenshot::{self, ScreenshotOptions};
use pirc_node::browser::hosts::{HostGuard, blocked_error};
use pirc_node::browser::manager::BrowserManager;
use pirc_node::browser::{BrowserService, BrowserTarget};
use serde_json::{Value, json};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

/// `PIRC_BROWSER_REQUIRED=1` (CI): nothing is skipped. The Chromium must be
/// `PIRC_BROWSER_EXECUTABLE`, an existing file (no fallback to another
/// browser on `PATH`), and a missing one fails the test.
fn required() -> bool {
    std::env::var_os("PIRC_BROWSER_REQUIRED").is_some_and(|value| value == "1")
}

/// Under [`required`], the explicit Chromium, or a panic.
fn required_chromium() -> Option<PathBuf> {
    if !required() {
        return None;
    }
    let explicit = std::env::var_os("PIRC_BROWSER_EXECUTABLE")
        .filter(|path| !path.is_empty())
        .expect("PIRC_BROWSER_REQUIRED=1 needs PIRC_BROWSER_EXECUTABLE");
    assert!(
        Path::new(&explicit).is_file(),
        "PIRC_BROWSER_EXECUTABLE={explicit:?} is not a file"
    );
    Some(explicit.into())
}

fn chromium() -> Option<PathBuf> {
    if let Some(explicit) = required_chromium() {
        return Some(explicit);
    }
    if let Some(explicit) = std::env::var_os("PIRC_BROWSER_EXECUTABLE") {
        return Some(explicit.into());
    }
    let path = std::env::var_os("PATH")?;
    for name in [
        "chromium",
        "chromium-browser",
        "google-chrome-stable",
        "google-chrome",
        "microsoft-edge",
    ] {
        for dir in std::env::split_paths(&path) {
            let candidate = dir.join(name);
            if candidate.is_file() {
                return Some(candidate);
            }
        }
    }
    [
        "/Applications/Chromium.app/Contents/MacOS/Chromium",
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    ]
    .into_iter()
    .map(PathBuf::from)
    .find(|candidate| candidate.is_file())
}

struct Browser {
    _launched: launch::Launched,
    _profile: tempfile::TempDir,
    connection: Arc<Connection>,
}

impl Browser {
    fn start() -> Option<Self> {
        let Some(executable) = chromium() else {
            eprintln!("skipped: no Chromium found");
            return None;
        };
        let profile = tempfile::tempdir().unwrap();
        let env: BTreeMap<String, String> = std::env::vars()
            .filter(|(name, _)| matches!(name.as_str(), "PATH" | "HOME" | "TMPDIR" | "LANG"))
            .collect();
        let launched = launch::launch(&executable, profile.path(), &env).unwrap();
        let connection = launched.connection.clone();
        Some(Self {
            _launched: launched,
            _profile: profile,
            connection,
        })
    }

    /// A new page target attached in flat mode, with Page, Runtime and
    /// Network enabled.
    async fn page(&self) -> Session {
        let browser = self.connection.browser();
        let target = browser
            .call("Target.createTarget", json!({ "url": "about:blank" }))
            .await
            .unwrap();
        let attached = browser
            .call(
                "Target.attachToTarget",
                json!({ "targetId": target["targetId"], "flatten": true }),
            )
            .await
            .unwrap();
        let session = self
            .connection
            .session(attached["sessionId"].as_str().unwrap());
        for method in ["Page.enable", "Runtime.enable", "Network.enable"] {
            session.call(method, json!({})).await.unwrap();
        }
        session
    }
}

/// Navigate and wait for `load`.
async fn goto(session: &Session, url: &str) {
    let mut events = session.listen();
    session
        .call("Page.navigate", json!({ "url": url }))
        .await
        .unwrap();
    tokio::time::timeout(Duration::from_secs(10), async {
        while let Some(event) = events.recv().await {
            if event.method == "Page.loadEventFired" {
                return;
            }
        }
    })
    .await
    .expect("load");
}

/// `Runtime.evaluate` with `awaitPromise`, by value.
async fn eval(session: &Session, expression: &str) -> Value {
    let result = session
        .call(
            "Runtime.evaluate",
            json!({ "expression": expression, "awaitPromise": true, "returnByValue": true }),
        )
        .await
        .unwrap();
    assert!(
        result.get("exceptionDetails").is_none(),
        "{expression}: {result}"
    );
    result["result"]["value"].clone()
}

/// A tiny HTTP server: `GET /` pages from `routes`, every request line
/// recorded.
#[derive(Clone)]
struct Server {
    port: u16,
    hits: Arc<Mutex<Vec<String>>>,
}

type Routes = Arc<dyn Fn(&str) -> (u16, Vec<(String, String)>, String) + Send + Sync>;

async fn serve(address: &str, routes: Routes) -> Option<Server> {
    let listener = TcpListener::bind(address).await.ok()?;
    let port = listener.local_addr().unwrap().port();
    let hits: Arc<Mutex<Vec<String>>> = Arc::default();
    let recorded = hits.clone();
    tokio::spawn(async move {
        loop {
            let Ok((mut stream, _)) = listener.accept().await else {
                return;
            };
            let routes = routes.clone();
            let recorded = recorded.clone();
            tokio::spawn(async move {
                let mut buffer = Vec::new();
                let mut chunk = [0u8; 4096];
                while !buffer.windows(4).any(|w| w == b"\r\n\r\n") {
                    match stream.read(&mut chunk).await {
                        Ok(0) | Err(_) => return,
                        Ok(n) => buffer.extend_from_slice(&chunk[..n]),
                    }
                }
                let head = String::from_utf8_lossy(&buffer).into_owned();
                let line = head.lines().next().unwrap_or_default().to_owned();
                recorded.lock().unwrap().push(line.clone());
                if head.to_ascii_lowercase().contains("upgrade: websocket") {
                    // Hand the socket to tungstenite with the bytes read so far.
                    let stream = Prefixed { buffer, stream };
                    if let Ok(mut ws) = tokio_tungstenite::accept_async(stream).await {
                        use futures_util::{SinkExt, StreamExt};
                        while let Some(Ok(message)) = ws.next().await {
                            if message.is_text() && ws.send(message).await.is_err() {
                                break;
                            }
                        }
                    }
                    return;
                }
                let path = line.split(' ').nth(1).unwrap_or("/").to_owned();
                let (status, headers, body) = routes(&path);
                let mut response = format!(
                    "HTTP/1.1 {status} X\r\ncontent-length: {}\r\nconnection: close\r\n",
                    body.len()
                );
                for (name, value) in headers {
                    response.push_str(&format!("{name}: {value}\r\n"));
                }
                response.push_str("\r\n");
                response.push_str(&body);
                let _ = stream.write_all(response.as_bytes()).await;
            });
        }
    });
    Some(Server { port, hits })
}

impl Server {
    fn hits(&self) -> Vec<String> {
        self.hits.lock().unwrap().clone()
    }
}

/// A stream that replays already-read bytes first.
struct Prefixed {
    buffer: Vec<u8>,
    stream: tokio::net::TcpStream,
}

impl tokio::io::AsyncRead for Prefixed {
    fn poll_read(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        buf: &mut tokio::io::ReadBuf<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        if !self.buffer.is_empty() {
            let n = self.buffer.len().min(buf.remaining());
            buf.put_slice(&self.buffer[..n]);
            self.buffer.drain(..n);
            return std::task::Poll::Ready(Ok(()));
        }
        std::pin::Pin::new(&mut self.stream).poll_read(cx, buf)
    }
}

impl tokio::io::AsyncWrite for Prefixed {
    fn poll_write(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        buf: &[u8],
    ) -> std::task::Poll<std::io::Result<usize>> {
        std::pin::Pin::new(&mut self.stream).poll_write(cx, buf)
    }
    fn poll_flush(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        std::pin::Pin::new(&mut self.stream).poll_flush(cx)
    }
    fn poll_shutdown(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        std::pin::Pin::new(&mut self.stream).poll_shutdown(cx)
    }
}

fn html(body: &str) -> (u16, Vec<(String, String)>, String) {
    (
        200,
        vec![("content-type".into(), "text/html".into())],
        body.to_owned(),
    )
}

/// 127.0.0.1 is allowed, every other private address blocked (127.0.0.2
/// stands for "a private host").
fn guard() -> Arc<HostGuard> {
    Arc::new(HostGuard::from_policy(
        &["127.0.0.1"],
        None,
        &[],
        pirc_node::browser::hosts::system_resolver(),
    ))
}

// ---- network ---------------------------------------------------------------

#[tokio::test(flavor = "multi_thread")]
async fn guards_requests_websockets_and_service_workers() {
    let Some(browser) = Browser::start() else {
        return;
    };
    // The "private" server; on hosts without 127.0.0.2 (macOS) the blocked
    // requests are told apart by their error only.
    let private = serve("127.0.0.2:0", Arc::new(|_| html("private"))).await;
    let private_port = private.as_ref().map_or(9, |server| server.port);
    let other = serve("127.0.0.1:0", Arc::new(|_| html("other")))
        .await
        .unwrap();
    let other_port = other.port;
    let public = serve(
        "127.0.0.1:0",
        Arc::new(move |path| match path {
            "/redirect" => (
                302,
                vec![(
                    "location".into(),
                    format!("http://127.0.0.2:{private_port}/hop"),
                )],
                String::new(),
            ),
            "/redirect-doc" => (
                302,
                vec![(
                    "location".into(),
                    format!("http://127.0.0.2:{private_port}/hopdoc#part"),
                )],
                String::new(),
            ),
            "/redirect-post" => (
                307,
                vec![(
                    "location".into(),
                    format!("http://127.0.0.2:{private_port}/post-hop"),
                )],
                String::new(),
            ),
            "/worker.js" => (
                200,
                vec![("content-type".into(), "text/javascript".into())],
                format!(
                    "onmessage = async () => {{ try {{ await fetch('http://127.0.0.2:{private_port}/worker'); postMessage('ok'); }} catch (e) {{ postMessage('blocked'); }} }};"
                ),
            ),
            "/sw.js" => (
                200,
                vec![("content-type".into(), "text/javascript".into())],
                String::new(),
            ),
            _ => html("<title>public</title>"),
        }),
    )
    .await
    .unwrap();
    let page = browser.page().await;
    let mut network_events = page.listen();
    let guard = guard();
    let _installed = network::install(&page, TargetKind::Page, guard.clone())
        .await
        .unwrap();
    let base = format!("http://127.0.0.1:{}", public.port);
    goto(&page, &format!("{base}/")).await;
    assert_eq!(eval(&page, "document.title").await, "public");

    // A subresource to a blocked host fails BlockedByClient and never
    // reaches it.
    let blocked = format!("http://127.0.0.2:{private_port}/fetch");
    assert_eq!(
        eval(
            &page,
            &format!("fetch('{blocked}').then(() => 'ok', () => 'blocked')")
        )
        .await,
        "blocked"
    );
    let mut reason = None;
    while let Ok(Some(event)) =
        tokio::time::timeout(Duration::from_secs(5), network_events.recv()).await
    {
        if event.method == "Network.loadingFailed" {
            reason = event.params["errorText"].as_str().map(str::to_owned);
            break;
        }
    }
    // Chromium names the client that blocked it.
    assert_eq!(
        reason.as_deref(),
        Some("net::ERR_BLOCKED_BY_CLIENT.Inspector")
    );

    // A dedicated worker's requests pause on the page's session.
    let worker = eval(
        &page,
        "new Promise(resolve => { const w = new Worker('/worker.js'); w.onmessage = e => resolve(e.data); w.postMessage(0); })",
    )
    .await;
    assert_eq!(worker, "blocked");

    // Allowed hosts load; a CORS preflight is answered as Playwright does
    // (never sent).
    let cross = format!("http://127.0.0.1:{other_port}/cors");
    let status = eval(
        &page,
        &format!(
            "fetch('{cross}', {{ method: 'PUT', headers: {{ 'x-pirc': '1' }} }}).then(r => 'ok ' + r.status, e => 'error ' + e)"
        ),
    )
    .await;
    // The real response lacks CORS headers, so the page sees a failure;
    // what matters is that the PUT was sent and the OPTIONS was not.
    assert!(status.as_str().unwrap().starts_with("error"), "{status}");
    let hits = other.hits();
    assert!(
        hits.iter().any(|hit| hit.starts_with("PUT /cors")),
        "{hits:?}"
    );
    assert!(
        !hits.iter().any(|hit| hit.starts_with("OPTIONS")),
        "{hits:?}"
    );

    // Redirect hops are checked, a document's too (both tighter than TS);
    // a document's refused hop is remembered for the manager's error text.
    let fetched = eval(
        &page,
        &format!("fetch('{base}/redirect').then(() => 'ok', () => 'error')"),
    )
    .await;
    assert_eq!(fetched, "error");
    // Learn the frame id while it is still attached to this page. Some
    // Chromium versions move a cross-site error frame out of the parent's
    // CDP frame tree, even though the guard refused the navigation.
    let mut frames = page.listen();
    eval(
        &page,
        "document.body.append(document.createElement('iframe')); 0",
    )
    .await;
    let frame = tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            let event = frames.recv().await.expect("CDP events");
            if event.method == "Page.frameAttached" {
                break event.params["frameId"].as_str().unwrap().to_owned();
            }
        }
    })
    .await
    .expect("iframe attached");
    let navigation = page
        .call(
            "Page.navigate",
            json!({ "frameId": frame, "url": format!("{base}/redirect-doc") }),
        )
        .await
        .unwrap();
    assert!(
        navigation["errorText"]
            .as_str()
            .is_some_and(|error| error.starts_with("net::ERR_BLOCKED_BY_CLIENT")),
        "{navigation}"
    );
    assert_eq!(
        guard.refused_hop(&frame),
        Some((
            format!("http://127.0.0.2:{private_port}/hopdoc#part"),
            "127.0.0.2 is a loopback address".to_owned()
        ))
    );
    // A form POST through a public 307 (which keeps the method and body).
    eval(
        &page,
        &format!(
            "new Promise(resolve => {{ const f = document.createElement('iframe'); f.name = 'post'; document.body.append(f); f.onload = () => resolve(0); const form = document.createElement('form'); form.method = 'POST'; form.action = '{base}/redirect-post'; form.target = 'post'; const input = document.createElement('input'); input.name = 'a'; input.value = 'secret'; form.append(input); document.body.append(form); form.submit(); }})"
        ),
    )
    .await;
    assert!(
        public
            .hits()
            .iter()
            .any(|hit| hit.starts_with("POST /redirect-post ")),
        "{:?}",
        public.hits()
    );
    if let Some(private) = &private {
        let hits = private.hits();
        assert!(
            !hits.iter().any(|hit| hit.contains("/hop")
                || hit.contains("/post-hop")
                || hit.contains("/fetch")
                || hit.contains("/worker")),
            "{hits:?}"
        );
    }

    // WebSockets: blocked ones close with 1008, allowed ones echo.
    let closed = eval(
        &page,
        &format!(
            "new Promise(resolve => {{ const ws = new WebSocket('ws://127.0.0.2:{private_port}/'); ws.onopen = () => resolve('open'); ws.onclose = e => resolve([e.code, e.reason, e.wasClean, ws.readyState].join(' ')); }})"
        ),
    )
    .await;
    assert_eq!(closed, "1008 blocked by pirc true 3");
    let echoed = eval(
        &page,
        &format!(
            "new Promise(resolve => {{ const ws = new WebSocket('ws://127.0.0.1:{other_port}/'); ws.onopen = () => ws.send('hi'); ws.onmessage = e => {{ resolve(e.data); ws.close(); }}; ws.onclose = e => resolve('closed ' + e.code); }})"
        ),
    )
    .await;
    assert_eq!(echoed, "hi");

    // Service workers are blocked as Playwright's `serviceWorkers: 'block'`.
    let registered = eval(
        &page,
        "navigator.serviceWorker.register('/sw.js').then(r => String(r))",
    )
    .await;
    assert_eq!(registered, "undefined");
}

/// Auto-attach every target of the browser as the context does: service
/// workers get the guard (a pirc deviation), then everything runs.
fn auto_attach(browser: &Browser) -> tokio::task::JoinHandle<()> {
    let connection = browser.connection.clone();
    let root = connection.browser();
    let mut events = root.listen();
    tokio::spawn(async move {
        let mut installed = Vec::new();
        while let Some(event) = events.recv().await {
            if event.method != "Target.attachedToTarget" {
                continue;
            }
            let session = connection.session(event.params["sessionId"].as_str().unwrap());
            if event.params["targetInfo"]["type"] == "service_worker" {
                installed.push(
                    network::install(&session, TargetKind::ServiceWorker, guard())
                        .await
                        .unwrap(),
                );
            }
            let _ = session
                .call("Runtime.runIfWaitingForDebugger", json!({}))
                .await;
        }
    })
}

#[tokio::test(flavor = "multi_thread")]
async fn guards_a_service_worker_that_registers_anyway() {
    let Some(browser) = Browser::start() else {
        return;
    };
    let private = serve("127.0.0.2:0", Arc::new(|_| html("private"))).await;
    let private_port = private.as_ref().map_or(9, |server| server.port);
    let public = serve(
        "127.0.0.1:0",
        Arc::new(move |path| match path {
            "/sw.js" => (
                200,
                vec![("content-type".into(), "text/javascript".into())],
                format!(
                    "self.onmessage = async e => {{ let r; try {{ await fetch('http://127.0.0.2:{private_port}/sw'); r = 'ok'; }} catch (x) {{ r = 'blocked'; }} e.source.postMessage(r); }};"
                ),
            ),
            _ => html("<title>public</title>"),
        }),
    )
    .await
    .unwrap();
    let watcher = auto_attach(&browser);
    browser
        .connection
        .browser()
        .call(
            "Target.setAutoAttach",
            json!({ "autoAttach": true, "waitForDebuggerOnStart": true, "flatten": true }),
        )
        .await
        .unwrap();
    let page = browser.page().await;
    let _installed = network::install(&page, TargetKind::Page, guard())
        .await
        .unwrap();
    goto(&page, &format!("http://127.0.0.1:{}/", public.port)).await;
    // The prototype's `register` is not replaced by Playwright's init script.
    let answer = eval(
        &page,
        "ServiceWorkerContainer.prototype.register.call(navigator.serviceWorker, '/sw.js')
            .then(() => navigator.serviceWorker.ready)
            .then(r => new Promise(resolve => {
                navigator.serviceWorker.onmessage = e => resolve(e.data);
                r.active.postMessage(0);
            }))",
    )
    .await;
    assert_eq!(answer, "blocked");
    if let Some(private) = private {
        assert!(private.hits().is_empty(), "{:?}", private.hits());
    }
    watcher.abort();
}

/// A guarded context as the manager launches it ([`Context::launch`]).
async fn guarded_context() -> Option<(Arc<Context>, tempfile::TempDir)> {
    let Some(executable) = chromium() else {
        eprintln!("skipped: no Chromium found");
        return None;
    };
    let profile = tempfile::tempdir().unwrap();
    let env: BTreeMap<String, String> = std::env::vars()
        .filter(|(name, _)| {
            matches!(
                name.as_str(),
                "PATH" | "HOME" | "TMPDIR" | "LANG" | "FONTCONFIG_FILE" | "XDG_RUNTIME_DIR"
            )
        })
        .collect();
    let context = Context::launch(
        &executable,
        profile.path(),
        LaunchOptions {
            viewport: (1280, 800),
            env,
        },
        guard(),
    )
    .await
    .expect("launch");
    Some((context, profile))
}

/// A shared worker's requests pause on no target session (not even its
/// own): the context's browser-session backstop checks them.
#[tokio::test(flavor = "multi_thread")]
async fn guards_shared_workers_through_the_browser_session() {
    let private = serve("127.0.0.2:0", Arc::new(|_| html("private"))).await;
    let private_port = private.as_ref().map_or(9, |server| server.port);
    let public = serve(
        "127.0.0.1:0",
        Arc::new(move |path| match path {
            "/shared.js" => (
                200,
                vec![("content-type".into(), "text/javascript".into())],
                format!(
                    "onconnect = async e => {{ const r = []; for (const url of ['http://127.0.0.2:{private_port}/shared-fetch', '/allowed']) {{ try {{ await fetch(url, {{ mode: 'no-cors', method: 'POST', body: 'x' }}); r.push('ok'); }} catch (x) {{ r.push('blocked'); }} }} e.ports[0].postMessage(r.join(' ')); }};"
                ),
            ),
            _ => html("<title>public</title>"),
        }),
    )
    .await
    .unwrap();
    let Some((context, _profile)) = guarded_context().await else {
        return;
    };
    let page = context.new_page().await.unwrap();
    page.goto(
        &format!("http://127.0.0.1:{}/", public.port),
        LoadState::Load,
        Duration::from_secs(10),
    )
    .await
    .unwrap();
    let answer = page
        .evaluate(
            "() => new Promise(resolve => { const w = new SharedWorker('/shared.js'); w.port.onmessage = e => resolve(e.data); })",
            Value::Null,
        )
        .await
        .unwrap();
    assert_eq!(answer, "blocked ok");
    assert!(
        public
            .hits()
            .iter()
            .any(|hit| hit.starts_with("POST /allowed ")),
        "{:?}",
        public.hits()
    );
    if let Some(private) = private {
        assert!(private.hits().is_empty(), "{:?}", private.hits());
    }
    context.close().await;
}

/// SIGKILL the renderers of `context`'s browser (found by its process
/// group): its pages, and the workers they run, crash.
fn kill_renderers(context: &Context) {
    let group = context.pid().unwrap().to_string();
    let listing = std::process::Command::new("ps")
        .args(["-A", "-o", "pid=,pgid=,command="])
        .output()
        .unwrap();
    let mut killed = 0;
    for line in String::from_utf8_lossy(&listing.stdout).lines() {
        let mut fields = line.split_whitespace();
        let (Some(pid), Some(pgid)) = (fields.next(), fields.next()) else {
            continue;
        };
        if pgid == group && line.contains("--type=renderer") {
            let _ = nix::sys::signal::kill(
                nix::unistd::Pid::from_raw(pid.parse().unwrap()),
                nix::sys::signal::Signal::SIGKILL,
            );
            killed += 1;
        }
    }
    assert!(killed > 0, "no renderer found");
}

/// A real service worker restarting (M8 covered the restart with a fake
/// CDP browser): stopped and woken again, then killed with its renderer and
/// started again by a new page, it is still guarded. The worker reports a
/// start id with each answer, so each step is a new worker instance.
/// `localhost` stands for the private host: refused by the guard, yet
/// reachable on every host, so its server sees any request that gets
/// through.
#[tokio::test(flavor = "multi_thread")]
async fn a_restarted_service_worker_is_still_guarded() {
    let private = serve("127.0.0.1:0", Arc::new(|_| html("private")))
        .await
        .unwrap();
    let private_port = private.port;
    let public = serve(
        "127.0.0.1:0",
        Arc::new(move |path| match path {
            "/sw.js" => (
                200,
                vec![("content-type".into(), "text/javascript".into())],
                format!(
                    "const started = Math.random().toString(36).slice(2); self.onmessage = async e => {{ let r; try {{ await fetch('http://localhost:{private_port}/sw-' + e.data); r = 'ok'; }} catch (x) {{ r = 'blocked'; }} e.source.postMessage(started + ' ' + r); }};"
                ),
            ),
            _ => html("<title>public</title>"),
        }),
    )
    .await
    .unwrap();
    let Some((context, _profile)) = guarded_context().await else {
        return;
    };
    let url = format!("http://127.0.0.1:{}/", public.port);
    let open = async |context: &Context| {
        let page = context.new_page().await.unwrap();
        page.goto(&url, LoadState::Load, Duration::from_secs(10))
            .await
            .unwrap();
        page
    };
    // The prototype's `register`: the context blocks the page's own.
    let ask = async |page: &pirc_node::browser::engine::page::Page,
                     step: &str|
           -> (String, String) {
        // A worker left paused never answers: fail rather than hang.
        let answer = tokio::time::timeout(Duration::from_secs(20), page
            .evaluate(
                "step => ServiceWorkerContainer.prototype.register.call(navigator.serviceWorker, '/sw.js')
                    .then(() => navigator.serviceWorker.ready)
                    .then(r => new Promise(resolve => {
                        navigator.serviceWorker.onmessage = e => resolve(e.data);
                        r.active.postMessage(step);
                    }))",
                json!(step),
            ))
            .await
            .unwrap_or_else(|_| panic!("{step}: no answer"))
            .unwrap();
        let answer = answer.as_str().unwrap().to_owned();
        let (started, result) = answer.split_once(' ').unwrap();
        (started.to_owned(), result.to_owned())
    };
    let page = open(&context).await;
    let (first, result) = ask(&page, "first").await;
    assert_eq!(result, "blocked");

    // Stopped, then started again by the next message.
    page.session()
        .call("ServiceWorker.enable", json!({}))
        .await
        .unwrap();
    page.session()
        .call("ServiceWorker.stopAllWorkers", json!({}))
        .await
        .unwrap();
    let (stopped, result) = ask(&page, "stopped").await;
    assert_ne!(stopped, first, "the worker was not restarted");
    assert_eq!(result, "blocked");

    // Killed with its renderer; a new page starts it again elsewhere.
    kill_renderers(&context);
    // Once the page has seen the crash (and Chromium has let the spare
    // renderer it killed too go), a new page gets a new renderer.
    let crashed = async {
        while page.evaluate("() => 1", Value::Null).await.is_ok() {
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    };
    tokio::time::timeout(Duration::from_secs(10), crashed)
        .await
        .expect("the page did not crash");
    tokio::time::sleep(Duration::from_millis(500)).await;
    let page = open(&context).await;
    let (crashed, result) = ask(&page, "crashed").await;
    assert_ne!(crashed, stopped, "the worker was not restarted");
    assert_eq!(result, "blocked");

    assert!(private.hits().is_empty(), "{:?}", private.hits());
    context.close().await;
}

/// A navigation refused at a redirect hop fails with the error TS gave
/// once Playwright had followed the hop (`assertAllowed` naming the URL
/// the frame landed on, then `about:blank`), through `goto` and through
/// a frame, and nothing reaches the blocked host.
#[tokio::test(flavor = "multi_thread")]
async fn names_a_refused_redirect_hop_as_ts() {
    let Some(executable) = chromium() else {
        eprintln!("skipped: no Chromium found");
        return;
    };
    let private = serve("127.0.0.2:0", Arc::new(|_| html("private"))).await;
    let private_port = private.as_ref().map_or(9, |server| server.port);
    let hop = format!("http://127.0.0.2:{private_port}/landed?x=1#part");
    let location = hop.clone();
    let public = serve(
        "127.0.0.1:0",
        Arc::new(move |path| match path {
            "/redirect" => (
                302,
                vec![("location".into(), location.clone())],
                String::new(),
            ),
            "/framed" => html("<title>Framed</title><iframe src=\"/redirect\"></iframe>"),
            _ => html("<title>public</title>"),
        }),
    )
    .await
    .unwrap();
    let root = tempfile::tempdir().unwrap();
    for dir in ["state", "config", "home", "work"] {
        std::fs::create_dir_all(root.path().join(dir)).unwrap();
    }
    let path = |name: &str| root.path().join(name).display().to_string();
    let (state, config, home) = (path("state"), path("config"), path("home"));
    let executable = executable.display().to_string();
    let inherited = std::env::var("PATH").unwrap_or_default();
    let env = pirc_config::Env::new(
        [
            ("PATH", inherited.as_str()),
            ("PIRC_NODE_ID", "test-node"),
            ("PIRC_NODE_TOKEN", "0123456789abcdef0123456789abcdef"),
            ("PIRC_DAEMON_URL", "ws://127.0.0.1:8787"),
            ("PIRC_ALLOWED_USERS", "test-user"),
            ("PIRC_STATE_DIR", state.as_str()),
            ("PIRC_CONFIG_DIR", config.as_str()),
            ("HOME", home.as_str()),
            ("PIRC_BROWSER_EXECUTABLE", executable.as_str()),
            ("PIRC_BROWSER_ALLOW_PRIVATE", "127.0.0.1"),
        ],
        root.path(),
    );
    let config = pirc_config::NodeConfig::load(&env, pirc_protocol::NodeRole::Node).unwrap();
    let manager = BrowserManager::new(&config, &env);
    let target = BrowserTarget {
        session_id: "s1".into(),
        workspace_id: "w1".into(),
        root: root.path().join("work"),
    };
    let expected = blocked_error(&hop, "127.0.0.2 is a loopback address");
    let base = format!("http://127.0.0.1:{}", public.port);
    for page in ["/redirect", "/framed"] {
        let error = manager
            .handle(
                target.clone(),
                "navigate".into(),
                json!({ "url": format!("{base}{page}") }),
            )
            .await
            .expect_err(page);
        assert_eq!(
            (error.status, &*error.code, &error.message),
            (expected.status, &*expected.code, &expected.message),
            "{page}"
        );
        let status = manager
            .handle(target.clone(), "status".into(), json!({}))
            .await
            .unwrap();
        assert_eq!(status["url"], "about:blank", "{page}");
    }
    if let Some(private) = private {
        assert!(private.hits().is_empty(), "{:?}", private.hits());
    }
    manager.shutdown().await;
}

// ---- input ------------------------------------------------------------------

/// The input fixture: every key, input and mouse event logged.
const INPUT_PAGE: &str = r#"<textarea id=t></textarea><div id=d style="width:300px;height:300px;overflow:scroll"><div style="height:2000px"></div></div>
<script>
window.__log = [];
const mods = e => (e.altKey?'A':'')+(e.ctrlKey?'C':'')+(e.metaKey?'M':'')+(e.shiftKey?'S':'');
for (const type of ['keydown','keyup','keypress']) addEventListener(type, e => __log.push([type, e.key, e.code, e.keyCode, e.location, e.repeat, mods(e)]), true);
addEventListener('input', e => __log.push(['input', e.inputType, e.data]), true);
for (const type of ['mousedown','mouseup','mousemove','click','dblclick','contextmenu','auxclick']) addEventListener(type, e => __log.push([type, e.button, e.buttons, e.clientX, e.clientY, e.detail, mods(e)]), true);
addEventListener('wheel', e => __log.push(['wheel', e.deltaX, e.deltaY, e.clientX, e.clientY, mods(e)]), true);
</script>"#;

/// What Playwright 1.63.0 logged for [`drive_input`]'s calls (Linux,
/// Chromium 153, `launchPersistentContext({headless: true, viewport:
/// {width: 1280, height: 800}})`), recorded with this bun script run from
/// the repository root with the dev shell's Chromium in `CHROME`:
///
/// ```ts
/// import { chromium } from 'playwright-core';
/// const ctx = await chromium.launchPersistentContext(dir, { headless: true,
///   executablePath: process.env.CHROME, viewport: { width: 1280, height: 800 } });
/// const page = ctx.pages()[0];
/// await page.goto('data:text/html,' + encodeURIComponent(INPUT_PAGE));
/// await page.evaluate(() => document.getElementById('t').focus());
/// // the calls of `drive_input`, with `page.keyboard` / `page.mouse`
/// const log = await page.evaluate(() => window.__log);
/// console.log(JSON.stringify({ value1, value2, error, log }));
/// ```
#[cfg(not(target_os = "macos"))]
const INPUT_EXPECTED: &str = r#"{"value1":"aaAbbHi!\n\n+é😀x","value2":"","error":"press: Unknown key: \"Foo\"","log":[
["keydown","a","KeyA",65,0,false,""],
["keypress","a","KeyA",97,0,false,""],
["input","insertText","a"],
["keyup","a","KeyA",65,0,false,""],
["keydown","Shift","ShiftLeft",16,1,false,"S"],
["keydown","a","KeyA",65,0,false,"S"],
["keypress","a","KeyA",97,0,false,"S"],
["input","insertText","a"],
["keyup","a","KeyA",65,0,false,"S"],
["keyup","Shift","ShiftLeft",16,1,false,""],
["keydown","Shift","ShiftLeft",16,1,false,"S"],
["keydown","A","KeyA",65,0,false,"S"],
["keypress","A","KeyA",65,0,false,"S"],
["input","insertText","A"],
["keyup","A","KeyA",65,0,false,"S"],
["keyup","Shift","ShiftLeft",16,1,false,""],
["keydown","b","KeyB",66,0,false,""],
["keypress","b","KeyB",98,0,false,""],
["input","insertText","b"],
["keydown","b","KeyB",66,0,true,""],
["keypress","b","KeyB",98,0,true,""],
["input","insertText","b"],
["keyup","b","KeyB",66,0,false,""],
["keydown","H","KeyH",72,0,false,""],
["keypress","H","KeyH",72,0,false,""],
["input","insertText","H"],
["keyup","H","KeyH",72,0,false,""],
["keydown","i","KeyI",73,0,false,""],
["keypress","i","KeyI",105,0,false,""],
["input","insertText","i"],
["keyup","i","KeyI",73,0,false,""],
["keydown","!","Digit1",49,0,false,""],
["keypress","!","Digit1",33,0,false,""],
["input","insertText","!"],
["keyup","!","Digit1",49,0,false,""],
["keydown","Enter","Enter",13,0,false,""],
["keypress","Enter","Enter",13,0,false,""],
["input","insertLineBreak",null],
["keyup","Enter","Enter",13,0,false,""],
["input","insertText","é"],
["input","insertText","😀"],
["keydown","x","KeyX",88,0,false,""],
["keypress","x","KeyX",120,0,false,""],
["input","insertText","x"],
["keyup","x","KeyX",88,0,false,""],
["keydown","Shift","ShiftLeft",16,1,false,"S"],
["keydown","7","Numpad7",36,3,false,"S"],
["keyup","7","Numpad7",36,1,false,"S"],
["keyup","Shift","ShiftLeft",16,1,false,""],
["keydown","Home","Numpad7",36,3,false,""],
["keyup","Home","Numpad7",36,1,false,""],
["keydown","Enter","NumpadEnter",13,3,false,""],
["keypress","Enter","NumpadEnter",13,3,false,""],
["input","insertLineBreak",null],
["keyup","Enter","NumpadEnter",13,1,false,""],
["keydown","Shift","ShiftLeft",16,1,false,"S"],
["keydown","+","Equal",187,0,false,"S"],
["keypress","+","Equal",43,0,false,"S"],
["input","insertText","+"],
["keyup","+","Equal",187,0,false,"S"],
["keyup","Shift","ShiftLeft",16,1,false,""],
["keydown","Control","ControlLeft",17,1,false,"C"],
["keydown","ArrowLeft","ArrowLeft",37,0,false,"C"],
["keyup","ArrowLeft","ArrowLeft",37,0,false,"C"],
["keyup","Control","ControlLeft",17,1,false,""],
["keydown","Control","ControlLeft",17,1,false,"C"],
["keydown","a","KeyA",65,0,false,"C"],
["keyup","a","KeyA",65,0,false,"C"],
["keyup","Control","ControlLeft",17,1,false,""],
["keydown","Backspace","Backspace",8,0,false,""],
["input","deleteContentBackward",null],
["keyup","Backspace","Backspace",8,0,false,""],
["mousemove",0,0,50,400,0,""],
["mousedown",0,1,50,400,1,""],
["mousemove",0,1,60,410,0,""],
["mouseup",0,0,60,410,1,""],
["click",0,0,60,410,1,""],
["mousedown",0,1,60,410,1,""],
["mouseup",0,0,60,410,1,""],
["click",0,0,60,410,1,""],
["mousedown",0,1,60,410,2,""],
["mouseup",0,0,60,410,2,""],
["click",0,0,60,410,2,""],
["dblclick",0,0,60,410,2,""],
["mousedown",2,2,60,410,1,""],
["contextmenu",2,2,60,410,0,""],
["mouseup",2,0,60,410,1,""],
["auxclick",2,0,60,410,1,""],
["mousemove",0,0,70,420,0,""],
["mousedown",0,1,70,420,1,""],
["mouseup",0,0,70,420,1,""],
["click",0,0,70,420,1,""],
["mousedown",0,1,70,420,2,""],
["mouseup",0,0,70,420,2,""],
["click",0,0,70,420,2,""],
["dblclick",0,0,70,420,2,""],
["keydown","Shift","ShiftLeft",16,1,false,"S"],
["mousemove",0,0,5,5,0,"S"],
["mousedown",0,1,5,5,1,"S"],
["mouseup",0,0,5,5,1,"S"],
["click",0,0,5,5,1,"S"],
["keyup","Shift","ShiftLeft",16,1,false,""],
["mousemove",0,0,100,100,0,""],
["wheel",0,120,100,100,""]
]}"#;

async fn drive_input(page: &Session) -> Value {
    use pirc_node::browser::engine::MouseButton;
    use pirc_node::browser::engine::input::{Keyboard, Mouse};
    let kb = Keyboard::new(page.clone());
    let m = Mouse::new(page.clone());
    let zero = Duration::ZERO;
    eval(page, "document.getElementById('t').focus()").await;
    kb.press("a", zero).await.unwrap();
    kb.press("Shift+a", zero).await.unwrap();
    kb.press("Shift+KeyA", zero).await.unwrap();
    kb.down("b").await.unwrap();
    kb.down("b").await.unwrap();
    kb.up("b").await.unwrap();
    kb.type_text("Hi!\n", zero).await.unwrap();
    kb.insert_text("é").await.unwrap();
    kb.type_text("😀x", zero).await.unwrap();
    kb.press("Shift+Numpad7", zero).await.unwrap();
    kb.press("Numpad7", zero).await.unwrap();
    kb.press("NumpadEnter", zero).await.unwrap();
    kb.press("Shift++", zero).await.unwrap();
    kb.press("ControlOrMeta+ArrowLeft", zero).await.unwrap();
    let value1 = eval(page, "document.getElementById('t').value").await;
    kb.press("Control+a", zero).await.unwrap();
    kb.press("Backspace", zero).await.unwrap();
    let value2 = eval(page, "document.getElementById('t').value").await;
    let error = kb.press("Foo", zero).await.unwrap_err().message;
    m.move_to(50.0, 400.0, kb.modifiers()).await.unwrap();
    m.down(MouseButton::Left, 1, kb.modifiers()).await.unwrap();
    m.move_to(60.0, 410.0, kb.modifiers()).await.unwrap();
    m.up(MouseButton::Left, 1, kb.modifiers()).await.unwrap();
    m.down(MouseButton::Left, 1, kb.modifiers()).await.unwrap();
    m.up(MouseButton::Left, 1, kb.modifiers()).await.unwrap();
    m.down(MouseButton::Left, 2, kb.modifiers()).await.unwrap();
    m.up(MouseButton::Left, 2, kb.modifiers()).await.unwrap();
    m.down(MouseButton::Right, 1, kb.modifiers()).await.unwrap();
    m.up(MouseButton::Right, 1, kb.modifiers()).await.unwrap();
    m.click(70.0, 420.0, MouseButton::Left, 2, kb.modifiers())
        .await
        .unwrap();
    kb.down("Shift").await.unwrap();
    m.click(5.0, 5.0, MouseButton::Left, 1, kb.modifiers())
        .await
        .unwrap();
    kb.up("Shift").await.unwrap();
    m.move_to(100.0, 100.0, kb.modifiers()).await.unwrap();
    m.wheel(0.0, 120.0, kb.modifiers()).await.unwrap();
    tokio::time::sleep(Duration::from_millis(200)).await;
    let log = eval(page, "window.__log").await;
    json!({ "value1": value1, "value2": value2, "error": error, "log": log })
}

#[tokio::test(flavor = "multi_thread")]
async fn types_and_clicks_as_playwright() {
    let Some(browser) = Browser::start() else {
        return;
    };
    let page = browser.page().await;
    page.call(
        "Emulation.setDeviceMetricsOverride",
        json!({ "mobile": false, "width": 1280, "height": 800, "deviceScaleFactor": 1,
            "screenOrientation": { "angle": 0, "type": "landscapePrimary" } }),
    )
    .await
    .unwrap();
    goto(&page, &format!("data:text/html,{}", urlencode(INPUT_PAGE))).await;
    let actual = drive_input(&page).await;
    assert_eq!(actual["error"], "press: Unknown key: \"Foo\"");
    #[cfg(not(target_os = "macos"))]
    {
        let expected: Value = serde_json::from_str(INPUT_EXPECTED).unwrap();
        assert_eq!(actual["value1"], expected["value1"]);
        assert_eq!(actual["value2"], expected["value2"]);
        let (actual, expected) = (
            actual["log"].as_array().unwrap(),
            expected["log"].as_array().unwrap(),
        );
        for (i, (a, e)) in actual.iter().zip(expected).enumerate() {
            assert_eq!(a, e, "event {i}");
        }
        assert_eq!(actual.len(), expected.len());
    }
}

fn urlencode(text: &str) -> String {
    text.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                (b as char).to_string()
            }
            _ => format!("%{b:02X}"),
        })
        .collect()
}

// ---- screenshots and the screencast ------------------------------------------

/// A bare page session as a screenshot surface (main frame only, main
/// world).
struct SessionSurface(Session);

impl screenshot::Surface for SessionSurface {
    fn session(&self) -> &Session {
        &self.0
    }

    fn viewport(&self) -> Option<(u32, u32)> {
        Some((1280, 800))
    }

    fn device_scale_factor(&self) -> Option<f64> {
        Some(1.0)
    }

    fn in_all_frames<'a>(&'a self, function: &'a str) -> BoxFuture<'a, ()> {
        Box::pin(async move {
            let _ = self.in_main_frame(function).await;
        })
    }

    fn in_main_frame<'a>(
        &'a self,
        function: &'a str,
    ) -> BoxFuture<'a, pirc_node::browser::engine::Result<Value>> {
        Box::pin(async move {
            let result = self
                .0
                .call(
                    "Runtime.evaluate",
                    json!({ "expression": format!("({function})()"), "awaitPromise": true,
                        "returnByValue": true }),
                )
                .await?;
            Ok(result["result"]["value"].clone())
        })
    }
}

/// A JPEG's size from its first SOF marker.
fn jpeg_size(jpeg: &[u8]) -> (u32, u32) {
    assert_eq!(&jpeg[..2], [0xff, 0xd8], "not a JPEG");
    let mut at = 2;
    while at + 9 < jpeg.len() {
        assert_eq!(jpeg[at], 0xff);
        let marker = jpeg[at + 1];
        let length = usize::from(u16::from_be_bytes([jpeg[at + 2], jpeg[at + 3]]));
        if matches!(marker, 0xc0..=0xc3) {
            let height = u16::from_be_bytes([jpeg[at + 5], jpeg[at + 6]]);
            let width = u16::from_be_bytes([jpeg[at + 7], jpeg[at + 8]]);
            return (u32::from(width), u32::from(height));
        }
        at += 2 + length;
    }
    panic!("no SOF marker");
}

async fn viewport_page(browser: &Browser, body: &str) -> Session {
    let page = browser.page().await;
    page.call(
        "Emulation.setDeviceMetricsOverride",
        json!({ "mobile": false, "width": 1280, "height": 800, "deviceScaleFactor": 1,
            "screenOrientation": { "angle": 0, "type": "landscapePrimary" } }),
    )
    .await
    .unwrap();
    goto(&page, &format!("data:text/html,{}", urlencode(body))).await;
    page
}

#[tokio::test(flavor = "multi_thread")]
async fn takes_screenshots_as_playwright() {
    let Some(browser) = Browser::start() else {
        return;
    };
    let page = viewport_page(
        &browser,
        "<body style='margin:0'><textarea id=t style='caret-color: red'></textarea><div style='height:3000px;width:100px;background:#08f'></div></body>",
    )
    .await;
    eval(&page, "document.getElementById('t').focus()").await;
    let surface = SessionSurface(page.clone());
    let options = ScreenshotOptions {
        quality: 70,
        full_page: false,
        timeout: Duration::from_secs(15),
    };
    let viewport = screenshot::capture_on(&surface, options).await.unwrap();
    assert_eq!(jpeg_size(&viewport), (1280, 800));
    let full = screenshot::capture_on(
        &surface,
        ScreenshotOptions {
            full_page: true,
            ..options
        },
    )
    .await
    .unwrap();
    // The textarea's line plus the 3000 px block.
    let (width, height) = jpeg_size(&full);
    assert_eq!(width, 1280);
    assert!(height > 3000, "{height}");
    let small = screenshot::capture_on(
        &surface,
        ScreenshotOptions {
            quality: 10,
            ..options
        },
    )
    .await
    .unwrap();
    assert!(small.len() < viewport.len());
    // The caret is hidden only while capturing.
    assert_eq!(
        eval(
            &page,
            "[document.getElementById('t').style.caretColor, typeof window.__pwCleanupScreenshot].join()"
        )
        .await,
        "red,undefined"
    );
    let error = screenshot::capture_on(
        &surface,
        ScreenshotOptions {
            timeout: Duration::from_millis(1),
            ..options
        },
    )
    .await
    .unwrap_err();
    assert_eq!(error.message, "screenshot: Timeout 1ms exceeded.");
}

#[tokio::test(flavor = "multi_thread")]
async fn streams_the_screencast_and_stops() {
    let Some(browser) = Browser::start() else {
        return;
    };
    let page = viewport_page(&browser, "<h1 id=h>0</h1>").await;
    let state = ScreencastState::default();
    let frames: Arc<Mutex<Vec<ScreencastFrame>>> = Arc::default();
    let sink = {
        let frames = frames.clone();
        Arc::new(move |frame: ScreencastFrame| frames.lock().unwrap().push(frame))
    };
    // Odd sizes are rounded down to even ones.
    let options = ScreencastOptions {
        width: 641,
        height: 401,
        quality: 60,
    };
    screencast::start_on(&page, &state, options, sink.clone())
        .await
        .unwrap();
    assert!(state.is_running());
    // Frames keep coming while the page changes (each is acknowledged).
    for i in 1..=5 {
        eval(
            &page,
            &format!("document.getElementById('h').textContent = '{i}'"),
        )
        .await;
        tokio::time::sleep(Duration::from_millis(150)).await;
    }
    let received = frames.lock().unwrap().clone();
    assert!(received.len() >= 2, "{} frames", received.len());
    for frame in &received {
        assert_eq!((frame.width, frame.height), (1280, 800));
        assert_eq!(jpeg_size(&frame.jpeg), (640, 400));
    }
    screencast::stop_on(&page, &state).await.unwrap();
    assert!(!state.is_running());
    tokio::time::sleep(Duration::from_millis(200)).await;
    let stopped = frames.lock().unwrap().len();
    eval(&page, "document.getElementById('h').textContent = 'after'").await;
    tokio::time::sleep(Duration::from_millis(400)).await;
    assert_eq!(frames.lock().unwrap().len(), stopped);
    // A restart with other options.
    screencast::start_on(
        &page,
        &state,
        ScreencastOptions {
            width: 320,
            height: 200,
            quality: 60,
        },
        sink,
    )
    .await
    .unwrap();
    eval(&page, "document.getElementById('h').textContent = 'again'").await;
    tokio::time::sleep(Duration::from_millis(400)).await;
    let last = frames.lock().unwrap().last().cloned().unwrap();
    assert_eq!(jpeg_size(&last.jpeg), (320, 200));
    screencast::stop_on(&page, &state).await.unwrap();
}

#[tokio::test(flavor = "multi_thread")]
async fn concurrent_screencast_restarts_leave_one_running() {
    let Some(browser) = Browser::start() else {
        return;
    };
    let page = viewport_page(&browser, "<h1 id=h>0</h1>").await;
    let state = ScreencastState::default();
    let sink = |count: &Arc<Mutex<usize>>| {
        let count = count.clone();
        Arc::new(move |_: ScreencastFrame| *count.lock().unwrap() += 1)
    };
    let options = ScreencastOptions {
        width: 640,
        height: 400,
        quality: 60,
    };
    let counts: Vec<Arc<Mutex<usize>>> = (0..4).map(|_| Arc::default()).collect();
    screencast::start_on(&page, &state, options, sink(&counts[0]))
        .await
        .unwrap();
    // Two restarts at once: the first stops the running one, the second
    // finds none to stop; both start.
    let (a, b) = tokio::join!(
        screencast::start_on(&page, &state, options, sink(&counts[1])),
        screencast::start_on(&page, &state, options, sink(&counts[2])),
    );
    a.unwrap();
    b.unwrap();
    screencast::stop_on(&page, &state).await.unwrap();
    assert!(!state.is_running());
    screencast::start_on(&page, &state, options, sink(&counts[3]))
        .await
        .unwrap();
    let before: Vec<usize> = counts.iter().map(|count| *count.lock().unwrap()).collect();
    for i in 1..=5 {
        eval(
            &page,
            &format!("document.getElementById('h').textContent = '{i}'"),
        )
        .await;
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    let after: Vec<usize> = counts.iter().map(|count| *count.lock().unwrap()).collect();
    assert!(after[3] > before[3], "the running screencast gets frames");
    assert_eq!(after[..3], before[..3], "no earlier sink gets frames");
    screencast::stop_on(&page, &state).await.unwrap();
}
