//! The host guard on every request and WebSocket of the context (but for
//! the accepted gaps listed at the end), as `node/browser.ts` set it up
//! with Playwright: `context.route('**/*')`
//! (the `Fetch` domain: a blocked request fails with `BlockedByClient`, the
//! rest continue; `Network.setCacheDisabled` as Playwright does while
//! routing), `context.routeWebSocket` (Playwright's main-world WebSocket
//! mock, `assets/websocket-mock.js`: a blocked socket is closed with 1008
//! "blocked by pirc", an allowed one connects), and
//! `serviceWorkers: 'block'`.
//!
//! [`install`] is called by [`super::context`] for every attached target
//! before it is let run (`Runtime.runIfWaitingForDebugger`). The caller
//! owns `Network.enable` and `Runtime.enable` (needed for
//! `Runtime.bindingCalled`); this module owns `Fetch.*`,
//! `Network.setCacheDisabled`, the bindings and the init scripts.
//!
//! What it does per target kind (Playwright 1.63.0, `crNetworkManager`,
//! `crPage` `FrameSession._initialize`, `crServiceWorker`):
//!
//! - pages and out-of-process iframes: `Network.setCacheDisabled {true}`,
//!   `Fetch.enable {handleAuthRequests: true, patterns: [{urlPattern: '*',
//!   requestStage: 'Request'}]}`, `Runtime.addBinding
//!   {name: '__playwright__binding__'}` and, in the main world with
//!   `runImmediately`, the init scripts in Playwright's order: the bindings
//!   controller, `addBinding('__pwWebSocketBinding')`, the service-worker
//!   block, the WebSocket mock.
//! - dedicated workers: `Network.setCacheDisabled {true}` only (Playwright
//!   skips `Fetch` on worker sessions: their requests pause on the page's).
//! - service workers (and shared workers): see the deviations.
//! - the browser session ([`TargetKind::Browser`], a pirc backstop, see
//!   the deviations): `Fetch.enable {patterns: [{urlPattern: '*',
//!   requestStage: 'Request'}]}` only, installed by the context before
//!   `Target.setAutoAttach`.
//!
//! `Fetch.requestPaused`: an intercepted CORS preflight is fulfilled with
//! Playwright's 204; every other request, redirect hops included (see the
//! deviations), is checked:
//! `Fetch.failRequest {errorReason: 'BlockedByClient'}` or
//! `Fetch.continueRequest {requestId}`. `Fetch.authRequired` answers
//! `Default` (Playwright without credentials).
//!
//! A redirect hop pauses again with the request's `networkId` and the new
//! URL (Chromium 153 sets no `redirectedRequestId` at the `Request`
//! stage). Playwright continues it unrouted, either because its
//! `Network.requestWillBeSent` carries the `redirectResponse` or because
//! the request was already continued (it replays that `continue`). Here a
//! pause whose `networkId` this session already continued is a hop; hops
//! are told apart only to remember a document's refused hop (below).
//!
//! Deviations (each blocks more than Playwright, never less):
//!
//! - Redirect hops are checked like any request. With Playwright (and so
//!   TS) they are not: a subresource's hop reached a blocked host unseen
//!   by `assertAllowed`, which looks only at frame URLs, and a document's
//!   hop (main frame, iframe or popup; a 307/308 keeps a form POST's method
//!   and body) was sent before `assertAllowed` refused the frame that
//!   landed there. A document's refused hop fails its navigation with
//!   `BlockedByClient` (the frame shows Chromium's error page); its URL
//!   (with the fragment) and reason are remembered by frame id
//!   ([`HostGuard::note_refused_hop`], forgotten at the frame's next
//!   navigation), and the manager names them as TS's `assertAllowed` named
//!   the URL the frame landed on (`goto`'s `ERR_BLOCKED_BY_CLIENT`, a frame
//!   on the error page), then leaves the page for `about:blank` as TS did.
//!   The text is TS's whenever the blocked host would have answered; it is
//!   stricter where TS's depended on what the blocked host did with the
//!   request: an unreachable blocked host (TS: Playwright's `net::ERR_…`
//!   goto error), a chain that leaves the blocked host again (TS: no
//!   error), several blocked hops (TS named the last, this the first), and
//!   the history (the error page's entry where TS had the blocked page's).
//!   As no frame can then commit a blocked host's document (DNS rebinding
//!   aside, see [`crate::browser::hosts`]), the manager reads a page after
//!   `assertAllowed` without a second check, as TS did.
//! - Playwright continues a paused request without a `networkId`, and one
//!   whose frame it does not know, without routing it: such a request's URL
//!   would reach the network unchecked. Here every paused request that is
//!   not a preflight is checked. A dedicated
//!   worker's `fetch` pauses without a `networkId` (seen with Chromium 153
//!   when the worker's session has not enabled `Network`).
//! - With `serviceWorkers: 'block'` Playwright gives a service worker no
//!   network manager, so a service worker that runs anyway (the init script
//!   only replaces `navigator.serviceWorker.register` on the instance;
//!   `ServiceWorkerContainer.prototype.register` still works) fetches
//!   unchecked. Here service workers get the same `Fetch` guard as pages.
//! - A backstop on the browser session: `Fetch` enabled there pauses every
//!   target's requests, after the target session's own `Fetch` (if any)
//!   continued them, and the same handler checks them. It is what guards
//!   shared workers (Playwright detaches them, so they run unguarded):
//!   Chromium 153 pauses a shared worker's requests on neither the page's
//!   session nor the worker's own (the context still installs
//!   [`TargetKind::ServiceWorker`] there), only on the browser session's.
//!   It equally sees the targets the context resumes and detaches without
//!   a guard of their own (prerender pages, worklets, future types, which
//!   Playwright leaves unguarded; not exercised: with the cache disabled
//!   Chromium 153 made no preload request at all). A request a
//!   target session refused never reaches the backstop; one it continued
//!   pauses once more and is checked again (the verdict is cached by
//!   [`HostGuard`], so this costs one CDP round trip per request; no
//!   measurable change on the corpus run). Authentication challenges are
//!   left to the target sessions (`handleAuthRequests` unset here).
//! - The bindings controller is pirc's own few lines rather than
//!   Playwright's `BindingsController` (not among the extracted assets): it
//!   defines the same globals and wire envelope (`{name, seq,
//!   serializedArgs}` on `__playwright__binding__`), with the arguments as
//!   plain JSON instead of Playwright's serialization, and resolves a
//!   binding call's promise at once (the mock never awaits it).
//! - Playwright recognizes a CORS preflight by its `Network.requestWillBeSent`
//!   (`initiator.type === 'preflight'`, method `OPTIONS`), which it pairs
//!   with the pause. The pause alone tells it here: `OPTIONS` with an
//!   `Access-Control-Request-Method` header, which only Chromium can set
//!   (a forbidden request header for pages); the paused event's resource
//!   type is the request's own (`XHR`), not `Preflight`.
//! - An allowed WebSocket is dispatched `passthrough` (the mock connects and
//!   relays itself), where Playwright's `connectToServer()` dispatches
//!   `connect` and relays every message through its client: the page sees
//!   the same socket. A page `close()` before the verdict is relayed as
//!   Playwright's client does (`closeServer`, then `closePage`).
//!
//! Page-owned background handlers inherit the page's resource authority, which
//! the manager binds at adoption and popups inherit from their opener. DNS waits
//! do not preserve an old allow decision: the actual CDP write rechecks authority.
//! A retired request/challenge can still be refused by trusted cleanup, but no
//! page JavaScript is evaluated to deliver a late WebSocket verdict. This does
//! not scope the shared browser-session backstop or revoke established sockets;
//! those still need context/OS containment and observed resource retirement.
//!
//! Accepted gaps (decided with the user on 2026-10-12): each is equal to
//! TS, whose Playwright guard has the same holes, and through each an
//! untrusted page reaches a blocked host (verified with Chromium 153
//! unless noted):
//!
//! - WebSockets. `Fetch` never sees a handshake, and no CDP command blocks
//!   one (`Network.setBlockedURLs` on page and worker sessions let the
//!   sockets connect); `Network.webSocketCreated` only reports one after
//!   the fact. The only guard is Playwright's main-world mock, in the realm
//!   the page's own scripts share:
//!   - `ws.url` is a writable property, and the mock connects to it after
//!     the verdict on the URL it reported at construction: set right after
//!     `new WebSocket(<allowed URL>)`, the socket connects to the new URL.
//!   - `__pwWebSocketDispatch` is a page-visible global: called with a
//!     pending socket's `_id` (also page-visible) and `type:
//!     'passthrough'`, it connects that socket whatever the verdict.
//!   - An allowed socket in passthrough keeps the native socket in its
//!     page-visible `_ws`: `new (ws._ws.constructor)(<blocked URL>)`
//!     connects with the native `WebSocket`, unchecked.
//!   - Workers have no mock: dedicated workers (nested ones too), shared
//!     workers and service workers (registered through
//!     `ServiceWorkerContainer.prototype.register`) open sockets to any
//!     host and port.
//!
//!   A handshake is an HTTP GET with a path and `Origin` the page chooses,
//!   and WebSockets have no CORS: a local WebSocket server that does not
//!   check `Origin` (dev servers' hot reload, local agents, debuggers)
//!   gives the page full read and write.
//! - Connections that are no request `Fetch` pauses:
//!   - `<link rel=preconnect>` and Chromium's own preconnect for a
//!     navigation open TCP connections to a blocked host (no bytes are
//!     sent; the request that would follow is refused);
//!   - WebRTC: STUN and TURN (UDP, and TURN/TCP allocations) reach blocked
//!     hosts, which is how browser LAN scans work (`icecandidateerror`);
//!   - WebTransport (HTTP/3 over QUIC) is not intercepted either (not
//!     tested).
//!
//! Closing them takes egress enforced outside the page (for example a
//! node-local proxy that applies [`HostGuard`] to every connection
//! Chromium makes), which is not done.
//!
//! Ported from playwright-core 1.63.0
//! `src/server/chromium/crNetworkManager.ts`,
//! `src/server/chromium/crPage.ts`,
//! `src/server/chromium/crServiceWorker.ts`,
//! `src/server/dispatchers/webSocketRouteDispatcher.ts` (Apache-2.0, see
//! `crates/pirc-node/NOTICE`).

use std::collections::HashSet;
use std::sync::{Arc, Mutex};

use serde_json::{Value, json};
use tokio::task::JoinHandle;

use futures_util::future::{BoxFuture, join_all};

use super::Result;
use super::cdp::{CdpError, Event, Session};
use crate::browser::hosts::HostGuard;
use crate::browser::{assets, effects};

/// What kind of target a session is (`targetInfo.type`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TargetKind {
    Page,
    /// An out-of-process iframe.
    Iframe,
    Worker,
    /// A worker with its own network: service workers, and shared workers
    /// (which Playwright detaches, letting them run unguarded: the context
    /// installs this on them, though only [`TargetKind::Browser`] sees
    /// their requests; see the module documentation).
    ServiceWorker,
    /// The browser session: the backstop (`Fetch` only, no bindings or
    /// scripts) that sees every target's requests, see the module
    /// documentation.
    Browser,
}

/// The guard's state for one target session; dropping it stops handling
/// the session's events.
pub struct Installed {
    task: Option<JoinHandle<()>>,
}

impl Drop for Installed {
    fn drop(&mut self) {
        if let Some(task) = self.task.take() {
            task.abort();
        }
    }
}

/// Playwright's single CDP binding (`PageBinding.kBindingName`).
pub const PLAYWRIGHT_BINDING: &str = "__playwright__binding__";
/// The binding the WebSocket mock calls (`kBindingName` of
/// `webSocketRouteDispatcher.ts`).
pub const WEBSOCKET_BINDING: &str = "__pwWebSocketBinding";
/// The close a blocked WebSocket gets (`ws.close({code: 1008, reason})`).
pub const BLOCKED_CLOSE_CODE: u16 = 1008;
pub const BLOCKED_CLOSE_REASON: &str = "blocked by pirc";

/// `Fetch.enable` as Playwright sends it while routing.
fn fetch_enable() -> Value {
    json!({
        "handleAuthRequests": true,
        "patterns": [{ "urlPattern": "*", "requestStage": "Request" }],
    })
}

/// `Fetch.enable` of the browser-session backstop: authentication
/// challenges are left to the target sessions (unanswered here, Chromium's
/// default applies, which is what `Default` asks for).
fn fetch_enable_backstop() -> Value {
    json!({ "patterns": [{ "urlPattern": "*", "requestStage": "Request" }] })
}

/// Playwright's `InitScript` wrapper.
fn init_script(source: &str) -> String {
    format!("(() => {{\n      {source}\n    }})();")
}

/// The bindings controller (pirc's stand-in for Playwright's
/// `BindingsController`, see the module documentation).
const BINDINGS_CONTROLLER: &str = r#"
      (() => {
        const property = '__playwright__binding__controller__';
        if (globalThis[property])
          return;
        const send = globalThis['__playwright__binding__'];
        const stringify = JSON.stringify;
        const resolved = () => Promise.resolve(undefined);
        const bindings = new Map();
        globalThis[property] = {
          addBinding(bindingName, noGlobal) {
            const data = { lastSeq: 0, removed: false };
            bindings.set(bindingName, data);
            if (!noGlobal)
              globalThis[bindingName] = (...args) => this.callBinding(bindingName, ...args);
          },
          callBinding(bindingName, ...args) {
            const data = bindings.get(bindingName);
            if (!data || data.removed)
              throw new Error(`binding "${bindingName}" has been removed`);
            const seq = ++data.lastSeq;
            send(stringify({ name: bindingName, seq, serializedArgs: args }));
            return resolved();
          },
        };
      })();
    "#;

/// `serviceWorkers: 'block'` (`BrowserContext._initialize`), verbatim.
const BLOCK_SERVICE_WORKERS: &str = "\nif (navigator.serviceWorker) navigator.serviceWorker.register = async () => { console.warn('Service Worker registration blocked by Playwright'); };\n";

/// The main-world init scripts of a page or frame session, in the order
/// Playwright's `page.allInitScripts()` gives them.
pub fn init_scripts() -> Vec<String> {
    vec![
        init_script(BINDINGS_CONTROLLER),
        init_script(&format!(
            "globalThis['__playwright__binding__controller__'].addBinding({}, false)",
            json!(WEBSOCKET_BINDING)
        )),
        init_script(BLOCK_SERVICE_WORKERS),
        init_script(&format!(
            "\n      (() => {{\n        const module = {{}};\n        {}\n        (module.exports.inject())(globalThis);\n      }})();\n    ",
            assets::WEBSOCKET_MOCK
        )),
    ]
}

/// Guard `session` (a target of `kind`) with `guard`.
pub async fn install(
    session: &Session,
    kind: TargetKind,
    guard: Arc<HostGuard>,
) -> Result<Installed> {
    let (installed, replies) = install_split(session, kind, guard).await?;
    replies.await?;
    Ok(installed)
}

/// The replies of a guard's commands still to come (see [`install_split`]).
pub type Replies = BoxFuture<'static, Result<()>>;

/// [`install`] in two steps: resolves once every command of the guard was
/// sent, in order, and request interception (`Fetch.enable`) replied, with
/// the other replies still to come. A target paused on start may be
/// resumed from then on: Chromium applies a session's commands in the
/// order they were sent, while a popup not yet running (a `noopener`
/// window) answers `Network.setCacheDisabled`, `Runtime.addBinding` and
/// `Page.addScriptToEvaluateOnNewDocument` only once it runs. (Playwright
/// sends all of its initialization, `Runtime.runIfWaitingForDebugger`
/// included, before awaiting any reply.) A failed `Fetch.enable` fails
/// the install, so the target never runs without request interception.
pub async fn install_split(
    session: &Session,
    kind: TargetKind,
    guard: Arc<HostGuard>,
) -> Result<(Installed, Replies)> {
    let done = || Box::pin(async { Ok(()) }) as Replies;
    if kind == TargetKind::Worker {
        // `_updateProtocolRequestInterceptionForSession` for a `workerFrame`.
        session
            .call("Network.setCacheDisabled", json!({ "cacheDisabled": true }))
            .await?;
        return Ok((Installed { task: None }, done()));
    }
    // Listen before anything can pause.
    let events = session.listen();
    let task = tokio::spawn(effects::inherit(handle_events(
        session.clone(),
        events,
        guard,
    )));
    let installed = Installed { task: Some(task) };
    if kind == TargetKind::Browser {
        session
            .call("Fetch.enable", fetch_enable_backstop())
            .await?;
        return Ok((installed, done()));
    }
    let (fetched_tx, fetched) = tokio::sync::oneshot::channel();
    let session = session.clone();
    // Its first poll sends every command.
    let mut replies: Replies = Box::pin(async move {
        let cache = session.call("Network.setCacheDisabled", json!({ "cacheDisabled": true }));
        let fetch = async {
            let reply = session.call("Fetch.enable", fetch_enable()).await;
            let _ = fetched_tx.send(reply.clone());
            reply
        };
        if kind == TargetKind::ServiceWorker {
            let (cache, fetch) = tokio::join!(cache, fetch);
            cache?;
            fetch?;
            return Ok(());
        }
        // The binding exists before the scripts that capture it run.
        let binding = session.call("Runtime.addBinding", json!({ "name": PLAYWRIGHT_BINDING }));
        let sources = init_scripts();
        let scripts = join_all(sources.iter().map(|source| {
            session.call(
                "Page.addScriptToEvaluateOnNewDocument",
                json!({ "source": source, "runImmediately": true }),
            )
        }));
        let (cache, fetch, binding, scripts) = tokio::join!(cache, fetch, binding, scripts);
        cache?;
        fetch?;
        binding?;
        for script in scripts {
            script?;
        }
        Ok(())
    });
    tokio::select! {
        biased;
        fetched = fetched => {
            fetched.unwrap_or_else(|_| Err(CdpError::closed()))?;
            Ok((installed, replies))
        }
        result = &mut replies => {
            result?;
            Ok((installed, done()))
        }
    }
}

/// The `networkId`s this session continued (their later pauses are
/// redirect hops or repeats), forgotten when the request ends; cleared
/// when it grows past [`CONTINUED_MAX`] (a later hop is then checked).
#[derive(Default)]
struct Continued(Mutex<HashSet<String>>);

const CONTINUED_MAX: usize = 10_000;

impl Continued {
    fn contains(&self, id: &str) -> bool {
        self.0.lock().unwrap().contains(id)
    }

    fn insert(&self, id: &str) {
        let mut ids = self.0.lock().unwrap();
        if ids.len() >= CONTINUED_MAX {
            ids.clear();
        }
        ids.insert(id.to_owned());
    }

    fn remove(&self, id: &str) {
        self.0.lock().unwrap().remove(id);
    }
}

async fn handle_events(
    session: Session,
    mut events: tokio::sync::mpsc::UnboundedReceiver<Event>,
    guard: Arc<HostGuard>,
) {
    let continued: Arc<Continued> = Arc::default();
    while let Some(event) = events.recv().await {
        match event.method.as_str() {
            "Fetch.requestPaused" => {
                let session = session.clone();
                let guard = guard.clone();
                let continued = continued.clone();
                tokio::spawn(effects::inherit(async move {
                    on_request_paused(&session, &guard, &continued, event.params).await;
                }));
            }
            "Fetch.authRequired" => {
                let session = session.clone();
                tokio::spawn(effects::inherit(async move {
                    let request = event.params["requestId"].clone();
                    let result = session
                        .call(
                            "Fetch.continueWithAuth",
                            json!({
                                "requestId": request,
                                "authChallengeResponse": { "response": "Default" }
                            }),
                        )
                        .await;
                    if result.is_err() && effects::check().is_err() {
                        reject_fetch(&session, request, true).await;
                    }
                }));
            }
            "Network.loadingFinished" | "Network.loadingFailed" => {
                if let Some(id) = event.params["requestId"].as_str() {
                    continued.remove(id);
                }
            }
            "Runtime.bindingCalled" if event.params["name"] == PLAYWRIGHT_BINDING => {
                let session = session.clone();
                let guard = guard.clone();
                tokio::spawn(effects::inherit(async move {
                    on_binding_called(&session, &guard, event.params).await
                }));
            }
            _ => {}
        }
    }
}

/// What to do with a paused request.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Verdict {
    /// Playwright's answer to an intercepted CORS preflight.
    FulfillPreflight(Vec<Value>),
    /// Ask the guard about this URL.
    Check(String),
}

/// How a `Fetch.requestPaused` is treated: a CORS preflight is answered as
/// Playwright's `_onRequestPaused`/`_onRequest` answer it, every other
/// request (redirect hops included, see the module documentation) is
/// checked.
pub fn classify(paused: &Value) -> Verdict {
    let request = &paused["request"];
    let headers = &request["headers"];
    let preflight = request["method"] == "OPTIONS"
        && headers.as_object().is_some_and(|headers| {
            headers
                .keys()
                .any(|name| name.eq_ignore_ascii_case("access-control-request-method"))
        });
    if preflight {
        let header = |name: &str| headers[name].as_str().filter(|value| !value.is_empty());
        let mut response = vec![
            json!({ "name": "Access-Control-Allow-Origin", "value": header("Origin").unwrap_or("*") }),
            json!({ "name": "Access-Control-Allow-Methods",
                "value": header("Access-Control-Request-Method").unwrap_or("GET, POST, OPTIONS, DELETE") }),
            json!({ "name": "Access-Control-Allow-Credentials", "value": "true" }),
        ];
        if let Some(allow) = header("Access-Control-Request-Headers") {
            response.push(json!({ "name": "Access-Control-Allow-Headers", "value": allow }));
        }
        return Verdict::FulfillPreflight(response);
    }
    Verdict::Check(request["url"].as_str().unwrap_or_default().to_owned())
}

async fn on_request_paused(
    session: &Session,
    guard: &HostGuard,
    continued: &Continued,
    paused: Value,
) {
    let request_id = paused["requestId"].clone();
    if effects::check().is_err() {
        reject_fetch(session, request_id, false).await;
        return;
    }
    let network_id = paused["networkId"].as_str();
    let hop = network_id.is_some_and(|id| continued.contains(id));
    // A frame's navigation (not one of its hops) forgets the hop refused in
    // its previous one, before anything continues: its own hops pause
    // only after that.
    let frame = (paused["resourceType"] == "Document")
        .then(|| paused["frameId"].as_str())
        .flatten();
    if let Some(frame) = frame
        && !hop
    {
        guard.forget_refused_hop(frame);
    }
    let proceed = || {
        if let Some(id) = network_id {
            continued.insert(id);
        }
        ("Fetch.continueRequest", json!({ "requestId": request_id }))
    };
    let (method, params) = match classify(&paused) {
        Verdict::FulfillPreflight(headers) => (
            "Fetch.fulfillRequest",
            json!({
                "requestId": request_id,
                "responseCode": 204,
                "responsePhrase": "No Content",
                "responseHeaders": headers,
                "body": "",
            }),
        ),
        Verdict::Check(url) => match guard.blocked_reason(&url).await {
            Some(reason) => {
                if let Some(frame) = frame
                    && hop
                {
                    let fragment = paused["request"]["urlFragment"].as_str();
                    let url = url + fragment.unwrap_or_default();
                    guard.note_refused_hop(frame, url, reason);
                }
                (
                    "Fetch.failRequest",
                    json!({ "requestId": request_id, "errorReason": "BlockedByClient" }),
                )
            }
            None => proceed(),
        },
    };
    if session.call(method, params).await.is_err() && effects::check().is_err() {
        reject_fetch(session, request_id, false).await;
    }
}

/// Only a refusal may bypass retired authority. Do not resume the target or
/// evaluate page JavaScript in this cleanup task; other sessions stay connected.
async fn reject_fetch(session: &Session, request: Value, auth: bool) {
    let session = session.clone();
    let _ = tokio::spawn(async move {
        if auth {
            session
                .call(
                    "Fetch.continueWithAuth",
                    json!({
                        "requestId": request,
                        "authChallengeResponse": { "response": "CancelAuth" }
                    }),
                )
                .await
        } else {
            session
                .call(
                    "Fetch.failRequest",
                    json!({
                        "requestId": request, "errorReason": "BlockedByClient"
                    }),
                )
                .await
        }
    })
    .await;
}

/// A WebSocket mock's report (`binding({type, id, ...})`) and what
/// Playwright's server and client answer to it: the requests for
/// `__pwWebSocketDispatch`. `Check` is an `onCreate` awaiting the guard.
#[derive(Clone, Debug, PartialEq)]
pub enum SocketAction {
    Check { id: Value, url: String },
    Dispatch(Value),
    Ignore,
}

/// The dispatch request for a WebSocket's verdict.
pub fn socket_verdict(id: &Value, blocked: bool) -> Value {
    if blocked {
        json!({ "id": id, "type": "closePage", "code": BLOCKED_CLOSE_CODE,
            "reason": BLOCKED_CLOSE_REASON, "wasClean": true })
    } else {
        json!({ "id": id, "type": "passthrough" })
    }
}

/// What to do with a `Runtime.bindingCalled` payload of the bindings
/// controller.
pub fn socket_action(payload: &str) -> SocketAction {
    let Ok(call) = serde_json::from_str::<Value>(payload) else {
        return SocketAction::Ignore;
    };
    if call["name"] != WEBSOCKET_BINDING {
        return SocketAction::Ignore;
    }
    let message = &call["serializedArgs"][0];
    let id = message["id"].clone();
    if !id.is_string() {
        return SocketAction::Ignore;
    }
    // Playwright's client without handlers relays one side's close to the
    // other (`closePage` → `closeServer` and back).
    let relay = |kind: &str| {
        let mut request = json!({ "id": id, "type": kind });
        for key in ["code", "reason", "wasClean"] {
            if let Some(value) = message.get(key) {
                request[key] = value.clone();
            }
        }
        SocketAction::Dispatch(request)
    };
    match message["type"].as_str() {
        Some("onCreate") => SocketAction::Check {
            url: message["url"].as_str().unwrap_or_default().to_owned(),
            id,
        },
        Some("onClosePage") => relay("closeServer"),
        Some("onCloseServer") => relay("closePage"),
        // Only sockets in `connect` mode report messages; pirc's are
        // passthrough or closed.
        _ => SocketAction::Ignore,
    }
}

async fn on_binding_called(session: &Session, guard: &HostGuard, params: Value) {
    if effects::check().is_err() {
        return;
    }
    let context = params["executionContextId"].clone();
    let request = match socket_action(params["payload"].as_str().unwrap_or_default()) {
        SocketAction::Ignore => return,
        SocketAction::Dispatch(request) => request,
        SocketAction::Check { id, url } => {
            socket_verdict(&id, guard.blocked_reason(&url).await.is_some())
        }
    };
    // `frame.evaluateExpression` in the main world the mock lives in (the
    // context that called the binding); a context gone meanwhile is fine.
    let _ = session
        .call(
            "Runtime.evaluate",
            json!({
                "expression": format!("globalThis.__pwWebSocketDispatch({request})"),
                "contextId": context,
            }),
        )
        .await;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn resource_revocation_during_dns_refuses_fetch_and_auth_but_preserves_a_peer() {
        use super::super::cdp::Fake;
        use crate::browser::effects::{Guard, PageResource};
        let mut fake = Fake::new();
        let session = fake.connection.session("source");
        let lookup = Arc::new(tokio::sync::Notify::new());
        let release = Arc::new(tokio::sync::Notify::new());
        let host = Arc::new(HostGuard::from_policy::<&str>(
            &[],
            None,
            &[],
            Arc::new({
                let lookup = lookup.clone();
                let release = release.clone();
                move |_| {
                    let lookup = lookup.clone();
                    let release = release.clone();
                    Box::pin(async move {
                        lookup.notify_one();
                        release.notified().await;
                        Ok(vec!["8.8.8.8".parse().unwrap()])
                    })
                }
            }),
        ));
        let resource = PageResource::default();
        // Initialization precedes manager adoption. Its event task must see a
        // later binding, not capture an unbound/allow verdict forever.
        let install = resource.clone().spawn({
            let session = session.clone();
            let host = host.clone();
            async move { install(&session, TargetKind::Browser, host).await }
        });
        let command = fake.command().await;
        assert_eq!(command["method"], "Fetch.enable");
        fake.send(json!({"id":command["id"],"sessionId":"source","result":{}}))
            .await;
        let _installed = install.await.unwrap().unwrap();
        let allowed = Arc::new(Mutex::new(true));
        resource
            .bind(Guard::new({
                let allowed = allowed.clone();
                move |effect| {
                    let allowed = allowed.lock().unwrap();
                    if !*allowed {
                        return Err(crate::error::ApiError::conflict("revoked"));
                    }
                    effect();
                    Ok(())
                }
            }))
            .unwrap();
        fake.send(json!({"sessionId":"source","method":"Fetch.requestPaused","params":{
            "requestId":"dns-wait","request":{"url":"https://fixture.example/path","method":"GET"}
        }})).await;
        tokio::time::timeout(std::time::Duration::from_secs(2), lookup.notified())
            .await
            .unwrap();
        *allowed.lock().unwrap() = false;
        release.notify_one();
        let denied = fake.command().await;
        assert_eq!(denied["method"], "Fetch.failRequest", "{denied}");
        assert_eq!(denied["params"]["requestId"], "dns-wait");
        fake.send(json!({"id":denied["id"],"sessionId":"source","result":{}}))
            .await;
        for (event, params, method, field, value) in [
            (
                "Fetch.authRequired",
                json!({"requestId":"auth"}),
                "Fetch.continueWithAuth",
                "authChallengeResponse",
                json!({"response":"CancelAuth"}),
            ),
            (
                "Fetch.requestPaused",
                json!({"requestId":"preflight","request":{"url":"https://fixture.example/","method":"OPTIONS","headers":{"Access-Control-Request-Method":"POST"}}}),
                "Fetch.failRequest",
                "errorReason",
                json!("BlockedByClient"),
            ),
        ] {
            fake.send(json!({"sessionId":"source","method":event,"params":params}))
                .await;
            let denied = fake.command().await;
            assert_eq!(denied["method"], method, "{denied}");
            assert_eq!(denied["params"][field], value, "{denied}");
            fake.send(json!({"id":denied["id"],"sessionId":"source","result":{}}))
                .await;
        }
        let peer = fake.connection.session("peer");
        let continued = Continued::default();
        let peer_request = on_request_paused(
            &peer,
            &host,
            &continued,
            json!({
                "requestId":"healthy","request":{"url":"https://8.8.8.8/","method":"GET"}
            }),
        );
        let reply = async {
            let command = fake.command().await;
            assert_eq!(command["sessionId"], "peer");
            assert_eq!(command["method"], "Fetch.continueRequest");
            fake.send(json!({"id":command["id"],"sessionId":"peer","result":{}}))
                .await;
        };
        tokio::join!(peer_request, reply);
        assert!(!fake.connection.is_closed());
    }

    #[tokio::test]
    async fn a_socket_verdict_waiting_on_dns_cannot_resume_a_revoked_page() {
        use super::super::cdp::Fake;
        let mut fake = Fake::new();
        let source = fake.connection.session("source");
        let lookup = Arc::new(tokio::sync::Notify::new());
        let release = Arc::new(tokio::sync::Notify::new());
        let allowed = Arc::new(Mutex::new(true));
        let guard = effects::Guard::new({
            let allowed = allowed.clone();
            move |effect| {
                let allowed = allowed.lock().unwrap();
                if !*allowed {
                    return Err(crate::error::ApiError::conflict("revoked"));
                }
                effect();
                Ok(())
            }
        });
        let host = HostGuard::from_policy::<&str>(
            &[],
            None,
            &[],
            Arc::new({
                let lookup = lookup.clone();
                let release = release.clone();
                move |_| {
                    let lookup = lookup.clone();
                    let release = release.clone();
                    Box::pin(async move {
                        lookup.notify_one();
                        release.notified().await;
                        Ok(vec!["8.8.8.8".parse().unwrap()])
                    })
                }
            }),
        );
        let pending = tokio::spawn(effects::background(Some(guard), async move {
            on_binding_called(&source, &host, json!({"executionContextId":1,"payload":json!({
                "name":WEBSOCKET_BINDING,"serializedArgs":[{"type":"onCreate","id":"s","url":"wss://fixture.example/"}]
            }).to_string()})).await;
        }));
        tokio::time::timeout(std::time::Duration::from_secs(2), lookup.notified())
            .await
            .unwrap();
        *allowed.lock().unwrap() = false;
        release.notify_one();
        tokio::time::timeout(std::time::Duration::from_secs(2), pending)
            .await
            .unwrap()
            .unwrap();
        fake.connection
            .session("peer")
            .send("peer-sentinel", json!({}));
        assert_eq!(fake.command().await["method"], "peer-sentinel");
    }

    #[test]
    fn classifies_paused_requests() {
        assert_eq!(
            classify(
                &json!({ "requestId": "1", "request": { "url": "http://a/", "method": "GET" } })
            ),
            Verdict::Check("http://a/".into())
        );
        // Redirect hops are checked, documents' too (tighter than TS).
        for kind in ["Document", "XHR", "Fetch", "Image", "Script", "Other"] {
            assert_eq!(
                classify(
                    &json!({ "requestId": "1", "networkId": "9", "resourceType": kind,
                    "request": { "url": "http://10.0.0.1/", "method": "GET" } })
                ),
                Verdict::Check("http://10.0.0.1/".into())
            );
        }
        // No networkId: checked (Playwright continues it).
        // A page's own OPTIONS request is no preflight.
        assert_eq!(
            classify(
                &json!({ "requestId": "1", "request": { "url": "http://c/", "method": "OPTIONS",
                "headers": { "Origin": "http://a" } } })
            ),
            Verdict::Check("http://c/".into())
        );
        assert_eq!(
            classify(
                &json!({ "requestId": "1", "request": { "url": "http://b/", "method": "POST" } })
            ),
            Verdict::Check("http://b/".into())
        );
        assert_eq!(
            classify(&json!({ "requestId": "1", "resourceType": "XHR",
                "request": { "url": "http://b/", "method": "OPTIONS", "headers": {
                    "Origin": "http://a", "Access-Control-Request-Method": "PUT",
                    "Access-Control-Request-Headers": "x-a" } } })),
            Verdict::FulfillPreflight(vec![
                json!({ "name": "Access-Control-Allow-Origin", "value": "http://a" }),
                json!({ "name": "Access-Control-Allow-Methods", "value": "PUT" }),
                json!({ "name": "Access-Control-Allow-Credentials", "value": "true" }),
                json!({ "name": "Access-Control-Allow-Headers", "value": "x-a" }),
            ])
        );
        assert_eq!(
            classify(&json!({ "requestId": "1", "resourceType": "XHR",
                "request": { "url": "http://b/", "method": "OPTIONS", "headers": {
                    "Origin": "", "Access-Control-Request-Method": "" } } })),
            Verdict::FulfillPreflight(vec![
                json!({ "name": "Access-Control-Allow-Origin", "value": "*" }),
                json!({ "name": "Access-Control-Allow-Methods", "value": "GET, POST, OPTIONS, DELETE" }),
                json!({ "name": "Access-Control-Allow-Credentials", "value": "true" }),
            ])
        );
    }

    fn call(message: Value) -> String {
        json!({ "name": WEBSOCKET_BINDING, "seq": 1, "serializedArgs": [message] }).to_string()
    }

    #[test]
    fn answers_the_websocket_mock_as_playwright() {
        assert_eq!(
            socket_action(&call(
                json!({ "type": "onCreate", "id": "ab", "url": "wss://x/", "protocols": [] })
            )),
            SocketAction::Check {
                id: json!("ab"),
                url: "wss://x/".into()
            }
        );
        assert_eq!(
            socket_verdict(&json!("ab"), true).to_string(),
            r#"{"id":"ab","type":"closePage","code":1008,"reason":"blocked by pirc","wasClean":true}"#
        );
        assert_eq!(
            socket_verdict(&json!("ab"), false).to_string(),
            r#"{"id":"ab","type":"passthrough"}"#
        );
        assert_eq!(
            socket_action(&call(
                json!({ "type": "onClosePage", "id": "ab", "code": 1000, "wasClean": true })
            )),
            SocketAction::Dispatch(
                json!({ "id": "ab", "type": "closeServer", "code": 1000, "wasClean": true })
            )
        );
        assert_eq!(
            socket_action(&call(
                json!({ "type": "onCloseServer", "id": "ab", "code": 1006, "reason": "", "wasClean": false })
            )),
            SocketAction::Dispatch(
                json!({ "id": "ab", "type": "closePage", "code": 1006, "reason": "", "wasClean": false })
            )
        );
        assert_eq!(
            socket_action(&call(
                json!({ "type": "onMessageFromPage", "id": "ab", "data": {} })
            )),
            SocketAction::Ignore
        );
        assert_eq!(socket_action("not json"), SocketAction::Ignore);
        assert_eq!(
            socket_action(
                &json!({ "name": "other", "serializedArgs": [{ "type": "onCreate", "id": "x" }] })
                    .to_string()
            ),
            SocketAction::Ignore
        );
    }

    #[test]
    fn orders_the_init_scripts_as_playwright() {
        let scripts = init_scripts();
        assert_eq!(scripts.len(), 4);
        assert!(scripts[0].contains("__playwright__binding__controller__"));
        assert!(scripts[1].contains(r#".addBinding("__pwWebSocketBinding", false)"#));
        assert!(scripts[2].contains("Service Worker registration blocked by Playwright"));
        assert!(scripts[3].contains("(module.exports.inject())(globalThis);"));
        assert!(scripts.iter().all(|s| s.starts_with("(() => {\n      ")));
    }
}
