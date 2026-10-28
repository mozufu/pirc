//! A page: Playwright's `Page` with its `FrameManager` and `CRPage`
//! (`crPage.ts`, `frames.ts`, `page.ts`): the frame tree across sessions
//! (out-of-process iframes are child sessions whose frame keeps its
//! sequence number), navigation and history with Playwright's waits, load
//! states and `networkidle`, popups, title, content, and the input devices,
//! screenshot and screencast of [`super::input`], [`super::screenshot`] and
//! [`super::screencast`].
//!
//! Every event of the page's sessions (its own, its out-of-process iframes',
//! its workers') goes through one channel in the order Chromium sent them
//! and is applied by one task, as Playwright's single event loop applies
//! them; the replies Playwright acts on in that order (`Page.getFrameTree`,
//! `Page.setLifecycleEventsEnabled`) come through the channel too
//! ([`Session::call_echo`]). The state lives under one lock that is never
//! held across an `await`; waiters watch a change counter.
//!
//! A renderer crash marks the crashed frame session's commands failed
//! ([`Session::fail_on_crash`]), the page's own and an out-of-process
//! iframe's alike, as Playwright does. Deviation: only the page's own crash
//! makes the page crashed (`Page crashed`). Playwright's
//! `FrameSession._onTargetCrashed` also calls `page._didCrash()` for an
//! out-of-process iframe's renderer, failing the whole page; here only that
//! iframe's commands fail (its frame stays in the tree until Chromium
//! detaches it), and the page and its other frames stay usable.
//!
//! Ported from playwright-core 1.63.0 `src/server/page.ts`,
//! `src/server/frames.ts`, `src/server/chromium/crPage.ts` (Apache-2.0, see
//! `crates/pirc-node/NOTICE`).

use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use serde_json::{Value, json};
use tokio::sync::{mpsc, oneshot, watch};
use tokio::time::Instant;

use super::cdp::{CdpError, Event, Session};
use super::context::{Installed, Installer};
use super::frame::{ExecContext, Frame, World};
use super::input::{Keyboard, Mouse};
use super::network::TargetKind;
use super::screencast::{ScreencastFrame, ScreencastOptions, ScreencastState};
use super::screenshot::ScreenshotOptions;
use super::{Error, LoadState, Result};

/// What a page reports to its subscribers.
#[derive(Clone)]
pub enum PageEvent {
    /// A page this page opened (`page.on('popup')`), already initialized.
    Popup(Arc<Page>),
    /// The main frame navigated (`framenavigated` for the main frame).
    MainFrameNavigated,
    /// `load`.
    Load,
    /// The page closed (`close`); the last event.
    Closed,
}

/// The main frame's response to a navigation (`response.status()`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Response {
    pub status: u16,
}

pub struct Page {
    pub(super) shared: Arc<Shared>,
    keyboard: OnceLock<Keyboard>,
    mouse: OnceLock<Mouse>,
    screencast: ScreencastState,
}

impl Page {
    pub(crate) fn bind_resource(
        &self,
        guard: crate::browser::effects::Guard,
    ) -> crate::error::ApiResult<()> {
        self.shared.resource.bind(guard)
    }

    /// The CDP target id (stable for the page's life).
    pub fn target_id(&self) -> &str {
        &self.shared.target_id
    }

    /// The page's own session (the main frame's).
    pub fn session(&self) -> &Session {
        &self.shared.session
    }

    /// Events from now on, until [`PageEvent::Closed`].
    pub fn subscribe(&self) -> mpsc::UnboundedReceiver<PageEvent> {
        let (tx, rx) = mpsc::unbounded_channel();
        let mut state = self.shared.state.lock().unwrap();
        if state.closed {
            let _ = tx.send(PageEvent::Closed);
        } else {
            state.subscribers.push(tx);
        }
        rx
    }

    /// The main frame's URL (`page.url()`).
    pub fn url(&self) -> String {
        let state = self.shared.state.lock().unwrap();
        state
            .main
            .and_then(|main| state.frames.get(&main))
            .map(|frame| frame.url.clone())
            .unwrap_or_default()
    }

    /// `page.title()`: the main frame's `document.title` from its utility
    /// world; while it cannot be read, `Loading <url>` for a pending
    /// navigation or "" (as Playwright).
    pub async fn title(&self) -> Result<String> {
        let main = self.main_frame();
        match main
            .evaluate_in(World::Utility, "title", "() => document.title", Value::Null)
            .await
        {
            Ok(Value::String(title)) => Ok(title),
            Ok(_) => Ok(String::new()),
            Err(_) => {
                let state = self.shared.state.lock().unwrap();
                let url = state
                    .frames
                    .get(&main.key)
                    .and_then(|frame| frame.pending.as_ref())
                    .and_then(|pending| pending.request.as_ref())
                    .map(|request| request.url.clone());
                Ok(url.map(|url| format!("Loading {url}")).unwrap_or_default())
            }
        }
    }

    /// `page.content()`: the main frame's serialized HTML.
    pub async fn content(&self) -> Result<String> {
        const CONTENT: &str = "() => {
            let retVal = '';
            if (document.doctype)
              retVal = new XMLSerializer().serializeToString(document.doctype);
            if (document.documentElement)
              retVal += document.documentElement.outerHTML;
            return retVal;
          }";
        let main = self.main_frame();
        match main
            .evaluate_in(World::Utility, "content", CONTENT, Value::Null)
            .await
        {
            Ok(value) => Ok(value.as_str().unwrap_or_default().to_owned()),
            Err(error) if error.non_retriable || main.is_detached() => Err(error.error),
            Err(_) => Err(Error::api(
                "content",
                "Unable to retrieve content because the page is navigating and changing the content.",
            )),
        }
    }

    pub fn main_frame(&self) -> Frame {
        let state = self.shared.state.lock().unwrap();
        let key = state.main.unwrap_or(0);
        let id = state
            .frames
            .get(&key)
            .map(|frame| frame.id.clone())
            .unwrap_or_default();
        Frame::new(self.shared.clone(), key, &id)
    }

    /// Every attached frame, main frame first, then each frame's children
    /// in the order they attached (`page.frames()`).
    pub fn frames(&self) -> Vec<Frame> {
        let state = self.shared.state.lock().unwrap();
        state
            .frame_keys()
            .into_iter()
            .map(|key| Frame::new(self.shared.clone(), key, &state.frames[&key].id))
            .collect()
    }

    /// The frame with Playwright sequence number `seq` (`f<seq>e<n>` refs).
    pub fn frame_by_seq(&self, seq: u64) -> Option<Frame> {
        let state = self.shared.state.lock().unwrap();
        state
            .frame_keys()
            .into_iter()
            .find(|key| state.frames[key].seq == seq)
            .map(|key| Frame::new(self.shared.clone(), key, &state.frames[&key].id))
    }

    /// `page.goto(url, {waitUntil, timeout})`: the main frame's response,
    /// `None` for same-document or `about:` navigations. Errors as
    /// Playwright's (`goto: net::ERR_… at <url>`, `goto: Timeout 30000ms
    /// exceeded.`; see [`Error::api`]).
    pub async fn goto(
        &self,
        url: &str,
        wait_until: LoadState,
        timeout: Duration,
    ) -> Result<Option<Response>> {
        let main = self.main_frame();
        let api = "goto";
        main.race_navigation(api, timeout, main.goto_impl(api, url, wait_until))
            .await
    }

    /// `page.goBack({waitUntil, timeout})`; no history entry is not an error.
    pub async fn go_back(&self, wait_until: LoadState, timeout: Duration) -> Result<()> {
        self.go(-1, "goBack", wait_until, timeout).await.map(drop)
    }

    /// [`Page::go_back`] with the main frame's response (`None` without a
    /// history entry, for a same-document or `about:` navigation).
    pub async fn go_back_response(
        &self,
        wait_until: LoadState,
        timeout: Duration,
    ) -> Result<Option<Response>> {
        self.go(-1, "goBack", wait_until, timeout).await
    }

    /// `page.goForward({timeout})` (waits for `load`).
    pub async fn go_forward(&self, timeout: Duration) -> Result<()> {
        self.go(1, "goForward", LoadState::Load, timeout)
            .await
            .map(drop)
    }

    async fn go(
        &self,
        delta: i64,
        api: &'static str,
        wait_until: LoadState,
        timeout: Duration,
    ) -> Result<Option<Response>> {
        let main = self.main_frame();
        let session = self.shared.session.clone();
        let work = async {
            // Listening before the command, as Playwright's waitForNavigation.
            let navigations = main.subscribe_navigations();
            let history = session
                .call("Page.getNavigationHistory", json!({}))
                .await
                .map_err(|e| protocol_error(api, "Page.getNavigationHistory", e))?;
            let current = history["currentIndex"].as_i64().unwrap_or(0);
            let Some(entry) = history["entries"]
                .as_array()
                .and_then(|entries| entries.get(usize::try_from(current + delta).ok()?))
            else {
                return Ok(None);
            };
            session
                .call(
                    "Page.navigateToHistoryEntry",
                    json!({ "entryId": entry["id"] }),
                )
                .await
                .map_err(|e| protocol_error(api, "Page.navigateToHistoryEntry", e))?;
            main.wait_for_navigation(api, navigations, false, wait_until)
                .await
        };
        main.race_navigation(api, timeout, work).await
    }

    /// `page.reload({timeout})` (waits for `load`).
    pub async fn reload(&self, timeout: Duration) -> Result<()> {
        let main = self.main_frame();
        let session = self.shared.session.clone();
        let api = "reload";
        let work = async {
            let navigations = main.subscribe_navigations();
            let wait = main.wait_for_navigation(api, navigations, true, LoadState::Load);
            let reload = async {
                session
                    .call("Page.reload", json!({}))
                    .await
                    .map_err(|e| protocol_error(api, "Page.reload", e))
            };
            let (response, reloaded) = tokio::join!(wait, reload);
            reloaded?;
            response
        };
        main.race_navigation(api, timeout, work).await.map(|_| ())
    }

    /// `page.waitForLoadState(state, {timeout})` for the main frame.
    pub async fn wait_for_load_state(&self, state: LoadState, timeout: Duration) -> Result<()> {
        self.main_frame()
            .wait_for_load_state_api("waitForLoadState", state, timeout)
            .await
    }

    /// `page.evaluate(fn, arg)` in the main frame's main world (see
    /// [`Frame::evaluate`]).
    pub async fn evaluate(&self, function: &str, arg: Value) -> Result<Value> {
        self.main_frame()
            .evaluate_api("evaluate", function, arg)
            .await
    }

    /// The viewport (`viewport` of the launch options, or the size a
    /// `window.open` asked for a popup).
    pub fn viewport(&self) -> (u32, u32) {
        self.shared.state.lock().unwrap().viewport
    }

    pub fn keyboard(&self) -> &Keyboard {
        self.keyboard
            .get_or_init(|| Keyboard::new(self.shared.session.clone()))
    }

    pub fn mouse(&self) -> &Mouse {
        self.mouse
            .get_or_init(|| Mouse::new(self.shared.session.clone()))
    }

    /// The screencast's state, kept with the page for [`super::screencast`].
    pub fn screencast_state(&self) -> &ScreencastState {
        &self.screencast
    }

    /// `page.screenshot(options)`: the encoded image.
    pub async fn screenshot(&self, options: ScreenshotOptions) -> Result<Vec<u8>> {
        super::screenshot::capture(self, options).await
    }

    /// Start (or restart with new options) the page's screencast; frames go
    /// to `sink` until [`Page::stop_screencast`] or the page closes.
    pub async fn start_screencast(
        &self,
        options: ScreencastOptions,
        sink: Arc<dyn Fn(ScreencastFrame) + Send + Sync>,
    ) -> Result<()> {
        super::screencast::start(self, options, sink).await
    }

    pub async fn stop_screencast(&self) -> Result<()> {
        super::screencast::stop(self).await
    }

    /// `page.bringToFront()`.
    pub async fn bring_to_front(&self) -> Result<()> {
        self.shared
            .session
            .call("Page.bringToFront", json!({}))
            .await
            .map(|_| ())
            .map_err(|e| protocol_error("bringToFront", "Page.bringToFront", e))
    }

    /// `page.close()`: `Target.closeTarget` (no `beforeunload`), then the
    /// page's end.
    pub async fn close(&self) -> Result<()> {
        if self.is_closed() {
            return Ok(());
        }
        let closing = self
            .shared
            .browser
            .call(
                "Target.closeTarget",
                json!({ "targetId": self.shared.target_id }),
            )
            .await;
        if closing.is_err() && self.shared.browser.connection().is_closed() {
            return Ok(());
        }
        self.shared.wait(|state| state.closed.then_some(())).await;
        Ok(())
    }

    pub fn is_closed(&self) -> bool {
        self.shared.state.lock().unwrap().closed
    }

    /// Whether the page finished its initialization (Playwright's
    /// `reportAsNew`): `Some(Err)` when it failed.
    pub fn initialized(&self) -> Option<std::result::Result<(), String>> {
        self.shared.state.lock().unwrap().initialized.clone()
    }

    pub(super) fn emit(&self, event: PageEvent) {
        self.shared.state.lock().unwrap().emit(event);
    }
}

// ---------------------------------------------------------------------------
// Internals shared with frame.rs and context.rs.

pub(super) type FrameKey = u64;

/// What the page's state machine needs to reach the browser.
pub(super) struct PageSetup {
    pub target_id: String,
    pub session: Session,
    pub browser: Session,
    pub installer: Installer,
    pub viewport: (u32, u32),
    pub mac: bool,
    /// The page that opened it: its `window.open` features may set the
    /// viewport.
    pub opener: Option<Arc<Page>>,
}

pub(super) struct Shared {
    pub(super) target_id: String,
    pub(super) session: Session,
    pub(super) browser: Session,
    /// `__playwright_utility_world_<guid>`.
    pub(super) world: String,
    resource: crate::browser::effects::PageResource,
    mac: bool,
    installer: Installer,
    pub(super) state: Mutex<State>,
    changed: watch::Sender<u64>,
    events: mpsc::UnboundedSender<Event>,
    barriers: std::sync::atomic::AtomicU64,
}

/// A document of a frame (Playwright's `DocumentInfo`).
#[derive(Clone, Default)]
pub(super) struct Document {
    pub(super) document_id: Option<String>,
    pub(super) request: Option<Arc<Request>>,
}

/// A request the page's network events told about (the parts of
/// Playwright's `Request` navigation and `networkidle` use).
pub(super) struct Request {
    id: u64,
    pub(super) url: String,
    frame: Option<FrameKey>,
    /// Favicons and event sources do not count for `networkidle`.
    excluded: bool,
    favicon: bool,
    state: Mutex<RequestState>,
}

#[derive(Default)]
struct RequestState {
    response: Option<u16>,
    failure: Option<String>,
    redirected_to: Option<Arc<Request>>,
}

impl Request {
    fn final_request(self: &Arc<Self>) -> Arc<Self> {
        let next = self.state.lock().unwrap().redirected_to.clone();
        match next {
            Some(next) => next.final_request(),
            None => self.clone(),
        }
    }

    /// `Some(status)` once it has a response, `Some(None)` once it failed
    /// without one.
    fn outcome(&self) -> Option<Option<u16>> {
        let state = self.state.lock().unwrap();
        match (state.response, &state.failure) {
            (Some(status), _) => Some(Some(status)),
            (None, Some(_)) => Some(None),
            (None, None) => None,
        }
    }
}

/// Playwright's `InternalNavigation` event.
#[derive(Clone)]
pub(super) struct Navigation {
    pub(super) url: String,
    pub(super) new_document: Option<Document>,
    pub(super) error: Option<String>,
}

pub(super) struct FrameState {
    pub(super) id: String,
    pub(super) seq: u64,
    pub(super) parent: Option<FrameKey>,
    children: Vec<FrameKey>,
    pub(super) url: String,
    pub(super) name: String,
    lifecycle: HashSet<LoadState>,
    /// How many times each state was added (a waiter misses no transient
    /// state).
    pub(super) fired: HashMap<LoadState, u64>,
    idle_self: bool,
    idle_timer: Option<(u64, tokio::task::AbortHandle)>,
    inflight: HashSet<u64>,
    current: Document,
    pub(super) pending: Option<Document>,
    pub(super) main_world: Option<ExecContext>,
    pub(super) utility_world: Option<ExecContext>,
    navigations: Vec<mpsc::UnboundedSender<Navigation>>,
}

impl FrameState {
    pub(super) fn has(&self, state: LoadState) -> bool {
        self.lifecycle.contains(&state)
    }

    pub(super) fn context(&self, world: World) -> Option<&ExecContext> {
        match world {
            World::Main => self.main_world.as_ref(),
            World::Utility => self.utility_world.as_ref(),
        }
    }
}

/// An execution context a session reported.
struct ContextEntry {
    uid: u64,
    frame: FrameKey,
}

/// Playwright's `FrameSession`: one target's session (the page's, or an
/// out-of-process iframe's).
struct FrameSession {
    session: Session,
    parent: Option<String>,
    is_main: bool,
    swapped_in: bool,
    /// Frame events are applied (the main session's only once the frame
    /// tree is known).
    renderer: bool,
    /// `Page.lifecycleEvent`s are applied.
    lifecycle: bool,
    lifecycle_enabled: bool,
    lifecycle_on_enable: bool,
    /// `Target.attachedToTarget`s held until the frame tree is known.
    buffered: Option<Vec<Value>>,
    contexts: HashMap<i64, ContextEntry>,
    workers: HashMap<String, Option<Installed>>,
    first_navigation: Option<oneshot::Sender<std::result::Result<(), String>>>,
    guard: Option<Installed>,
}

#[derive(Clone)]
enum Route {
    Frame(String),
    Worker {
        owner: String,
        frame: Option<FrameKey>,
    },
}

pub(super) struct State {
    pub(super) closed: bool,
    /// The page's renderer crashed (`Page._didCrash`); it stays open.
    pub(super) crashed: bool,
    pub(super) initialized: Option<std::result::Result<(), String>>,
    pub(super) frames: HashMap<FrameKey, FrameState>,
    ids: HashMap<String, FrameKey>,
    pub(super) main: Option<FrameKey>,
    next_key: FrameKey,
    next_seq: u64,
    next_uid: u64,
    sessions: HashMap<String, FrameSession>,
    routes: HashMap<String, Route>,
    requests: HashMap<String, Arc<Request>>,
    subscribers: Vec<mpsc::UnboundedSender<PageEvent>>,
    window_features: VecDeque<Vec<String>>,
    viewport: (u32, u32),
    /// The last [`Shared::barrier`] the event loop reached.
    barrier: u64,
    /// Playwright's `SignalBarrier`s of the input actions running now: per
    /// barrier, how many main-frame navigations it still waits for (see
    /// [`Shared::add_signal_barrier`]).
    signal_barriers: HashMap<u64, u32>,
    next_signal_barrier: u64,
}

impl State {
    fn emit(&mut self, event: PageEvent) {
        self.subscribers
            .retain(|subscriber| subscriber.send(event.clone()).is_ok());
    }

    /// Main frame first, then children depth first (`frames()`).
    pub(super) fn frame_keys(&self) -> Vec<FrameKey> {
        fn collect(state: &State, key: FrameKey, out: &mut Vec<FrameKey>) {
            out.push(key);
            for child in &state.frames[&key].children {
                collect(state, *child, out);
            }
        }
        let mut out = Vec::new();
        if let Some(main) = self.main.filter(|main| self.frames.contains_key(main)) {
            collect(self, main, &mut out);
        }
        out
    }

    fn uid(&mut self) -> u64 {
        self.next_uid += 1;
        self.next_uid
    }

    /// The target whose session owns `key`'s documents
    /// (`_sessionForFrame`).
    fn session_target(&self, mut key: FrameKey) -> Option<String> {
        loop {
            let frame = self.frames.get(&key)?;
            if self.sessions.contains_key(&frame.id) {
                return Some(frame.id.clone());
            }
            key = frame.parent?;
        }
    }

    pub(super) fn session_for(&self, key: FrameKey) -> Option<Session> {
        self.session_target(key)
            .map(|target| self.sessions[&target].session.clone())
    }

    /// `_eventBelongsToStaleFrame`.
    fn stale(&self, target: &str, frame_id: &str) -> bool {
        let Some(key) = self.ids.get(frame_id) else {
            return true;
        };
        match self.session_target(*key) {
            Some(owner) => owner != target && !self.sessions[&owner].swapped_in,
            None => false,
        }
    }
}

impl Shared {
    fn bump(&self) {
        self.changed.send_modify(|generation| *generation += 1);
    }

    /// Resolve with `check`'s first `Some`, checked now and after every
    /// change of the state.
    pub(super) async fn wait<T>(&self, mut check: impl FnMut(&State) -> Option<T>) -> T {
        let mut changed = self.changed.subscribe();
        loop {
            if let Some(value) = check(&self.state.lock().unwrap()) {
                return value;
            }
            if changed.changed().await.is_err() {
                std::future::pending::<()>().await;
            }
        }
    }

    /// The window features of the latest `window.open` (for a popup's
    /// viewport).
    fn take_window_features(&self) -> Option<Vec<String>> {
        self.state.lock().unwrap().window_features.pop_front()
    }

    /// `FrameManager.waitForSignalsCreatedBy`'s barrier: from now on, every
    /// navigation the main frame requests (`Page.frameRequestedNavigation`
    /// in the current tab) holds it until the main frame's next navigation
    /// event (committed or failed). Remove it with
    /// [`Shared::remove_signal_barrier`].
    pub(super) fn add_signal_barrier(&self) -> u64 {
        let mut state = self.state.lock().unwrap();
        state.next_signal_barrier += 1;
        let id = state.next_signal_barrier;
        state.signal_barriers.insert(id, 0);
        id
    }

    pub(super) fn remove_signal_barrier(&self, id: u64) {
        self.state.lock().unwrap().signal_barriers.remove(&id);
    }

    /// `SignalBarrier.waitFor`: resolves once the navigations the barrier
    /// holds for were committed or failed (or the page closed).
    pub(super) async fn wait_signal_barrier(&self, id: u64) {
        self.wait(|state| {
            (state.closed || state.signal_barriers.get(&id).is_none_or(|held| *held == 0))
                .then_some(())
        })
        .await
    }

    /// Resolves once the event loop applied every event received so far
    /// (or the page closed).
    pub(super) async fn barrier(&self) {
        let id = self
            .barriers
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed)
            + 1;
        let _ = self.events.send(Event {
            session: None,
            method: "pirc.barrier".to_owned(),
            params: json!(id),
        });
        self.wait(|state| (state.barrier >= id || state.closed).then_some(()))
            .await;
    }
}

impl Page {
    /// Take over a page target attached at the browser (`new CRPage`): its
    /// events are applied from now on and its initialization runs; see
    /// [`Page::initialized`].
    pub(super) fn attach(setup: PageSetup) -> Arc<Self> {
        let (events, mut rx) = mpsc::unbounded_channel();
        let (changed, _) = watch::channel(0);
        let mut guid = [0u8; 16];
        let _ = getrandom::fill(&mut guid);
        let world = format!(
            "__playwright_utility_world_page@{}",
            guid.iter().map(|b| format!("{b:02x}")).collect::<String>()
        );
        let mut sessions = HashMap::new();
        sessions.insert(
            setup.target_id.clone(),
            FrameSession::new(setup.session.clone(), None, true),
        );
        setup.session.fail_on_crash();
        let mut routes = HashMap::new();
        if let Some(id) = setup.session.id() {
            routes.insert(id.to_owned(), Route::Frame(setup.target_id.clone()));
        }
        let (first_tx, first_rx) = oneshot::channel();
        sessions.get_mut(&setup.target_id).unwrap().first_navigation = Some(first_tx);
        let shared = Arc::new(Shared {
            target_id: setup.target_id.clone(),
            session: setup.session.clone(),
            browser: setup.browser,
            world,
            mac: setup.mac,
            installer: setup.installer,
            resource: setup
                .opener
                .as_ref()
                .map(|opener| opener.shared.resource.clone())
                .unwrap_or_default(),
            state: Mutex::new(State {
                closed: false,
                crashed: false,
                initialized: None,
                frames: HashMap::new(),
                ids: HashMap::new(),
                main: None,
                next_key: 0,
                next_seq: 0,
                next_uid: 0,
                sessions,
                routes,
                requests: HashMap::new(),
                subscribers: Vec::new(),
                window_features: VecDeque::new(),
                viewport: setup.viewport,
                barrier: 0,
                signal_barriers: HashMap::new(),
                next_signal_barrier: 0,
            }),
            changed,
            events: events.clone(),
            barriers: Default::default(),
        });
        setup.session.listen_into(events);
        {
            let shared = shared.clone();
            shared.resource.clone().spawn(async move {
                let mut changed = shared.changed.subscribe();
                loop {
                    tokio::select! {
                        event = rx.recv() => match event {
                            Some(event) => handle(&shared, event),
                            None => break,
                        },
                        _ = changed.changed() => {
                            if shared.state.lock().unwrap().closed {
                                break;
                            }
                        }
                    }
                }
            });
        }
        {
            let shared = shared.clone();
            let session = setup.session.clone();
            let target = setup.target_id.clone();
            let opener = setup.opener;
            shared.resource.clone().spawn(async move {
                // `new CRPage`: a popup takes the size its opener's latest
                // `window.open` asked for; that event came before this
                // target, possibly still queued in the opener's loop.
                if let Some(opener) = opener {
                    opener.shared.barrier().await;
                    let size = opener
                        .shared
                        .take_window_features()
                        .and_then(|features| Page::viewport_from_features(&features));
                    if let Some(size) = size {
                        shared.state.lock().unwrap().viewport = size;
                    }
                }
                let result = init_session(&shared, target, session, true, Some(first_rx)).await;
                let mut state = shared.state.lock().unwrap();
                if state.initialized.is_none() {
                    state.initialized = Some(result);
                }
                drop(state);
                shared.bump();
            });
        }
        let page = Arc::new(Self {
            shared,
            keyboard: OnceLock::new(),
            mouse: OnceLock::new(),
            screencast: ScreencastState::default(),
        });
        // Announcements (`showActions`) and drag handling for the page's
        // input devices.
        super::input::attach(&page);
        page
    }

    /// The page target is gone (`didClose`): every session's guard is
    /// dropped, waiters fail, subscribers get [`PageEvent::Closed`].
    pub(super) fn did_close(&self) {
        let mut state = self.shared.state.lock().unwrap();
        if state.closed {
            return;
        }
        state.closed = true;
        if state.initialized.is_none() {
            state.initialized = Some(Err(CdpError::closed().message));
        }
        for frame in state.frames.values_mut() {
            if let Some((_, timer)) = frame.idle_timer.take() {
                timer.abort();
            }
            frame.navigations.clear();
        }
        for (_, mut session) in state.sessions.drain() {
            if let Some(first) = session.first_navigation.take() {
                let _ = first.send(Err(CdpError::closed().message));
            }
        }
        state.routes.clear();
        state.emit(PageEvent::Closed);
        state.subscribers.clear();
        drop(state);
        self.shared.bump();
    }

    /// A popup's viewport from its opener's `window.open` features
    /// (`getViewportSizeFromWindowFeatures`).
    fn viewport_from_features(features: &[String]) -> Option<(u32, u32)> {
        let value = |name: &str| {
            features
                .iter()
                .find_map(|feature| feature.strip_prefix(name))
                .and_then(parse_int)
        };
        Some((value("width=")?, value("height=")?))
    }
}

/// JS `parseInt(s, 10)` for non-negative sizes.
fn parse_int(text: &str) -> Option<u32> {
    let text = text.trim_start();
    let digits: String = text
        .strip_prefix('+')
        .unwrap_or(text)
        .chars()
        .take_while(char::is_ascii_digit)
        .collect();
    digits.parse().ok()
}

impl FrameSession {
    fn new(session: Session, parent: Option<String>, is_main: bool) -> Self {
        Self {
            session,
            parent,
            is_main,
            swapped_in: false,
            renderer: !is_main,
            lifecycle: false,
            lifecycle_enabled: false,
            lifecycle_on_enable: false,
            buffered: Some(Vec::new()),
            contexts: HashMap::new(),
            workers: HashMap::new(),
            first_navigation: None,
            guard: None,
        }
    }
}

/// A protocol error as Playwright reports it (`Protocol error (<method>):
/// <message>`), or its closed-target error.
pub(super) fn protocol_error(api: &str, method: &str, error: CdpError) -> Error {
    if error.is_crashed() {
        return Error::api(api, error.message);
    }
    if error.is_closed() {
        return closed_error(api);
    }
    Error::api(api, format!("Protocol error ({method}): {}", error.message))
}

pub(super) fn closed_error(api: &str) -> Error {
    Error::api(api, CdpError::closed().message)
}

pub(super) fn deadline(timeout: Duration) -> Option<Instant> {
    (!timeout.is_zero()).then(|| Instant::now() + timeout)
}

/// `fut`, or `None` once `deadline` passed.
pub(super) async fn within<T>(
    deadline: Option<Instant>,
    fut: impl std::future::Future<Output = T>,
) -> Option<T> {
    match deadline {
        Some(deadline) => tokio::time::timeout_at(deadline, fut).await.ok(),
        None => Some(fut.await),
    }
}

// ---------------------------------------------------------------------------
// Session initialization (`FrameSession._initialize`).

/// Playwright's `platformToFontFamilies` for the headless defaults.
fn font_families(mac: bool) -> Value {
    if mac {
        json!({
            "fontFamilies": {
                "standard": "Times", "fixed": "Courier", "serif": "Times",
                "sansSerif": "Helvetica", "cursive": "Apple Chancery", "fantasy": "Papyrus"
            },
            "forScripts": [
                { "script": "jpan", "fontFamilies": {
                    "standard": "Hiragino Kaku Gothic ProN", "fixed": "Osaka-Mono",
                    "serif": "Hiragino Mincho ProN", "sansSerif": "Hiragino Kaku Gothic ProN" } },
                { "script": "hang", "fontFamilies": {
                    "standard": "Apple SD Gothic Neo", "serif": "AppleMyungjo",
                    "sansSerif": "Apple SD Gothic Neo" } },
                { "script": "hans", "fontFamilies": {
                    "standard": ",PingFang SC,STHeiti", "serif": "Songti SC",
                    "sansSerif": ",PingFang SC,STHeiti", "cursive": "Kaiti SC" } },
                { "script": "hant", "fontFamilies": {
                    "standard": ",PingFang TC,Heiti TC", "serif": "Songti TC",
                    "sansSerif": ",PingFang TC,Heiti TC", "cursive": "Kaiti TC" } }
            ]
        })
    } else {
        json!({
            "fontFamilies": {
                "standard": "Times New Roman", "fixed": "Monospace", "serif": "Times New Roman",
                "sansSerif": "Arial", "cursive": "Comic Sans MS", "fantasy": "Impact"
            }
        })
    }
}

/// Initialize a frame session before letting its target run, in
/// Playwright's order (all commands are written in this order; the replies
/// are awaited together). The main session's failure fails the page.
async fn init_session(
    shared: &Arc<Shared>,
    target: String,
    session: Session,
    is_main: bool,
    first_navigation: Option<oneshot::Receiver<std::result::Result<(), String>>>,
) -> std::result::Result<(), String> {
    let fail = |method: &str| {
        let method = method.to_owned();
        move |error: CdpError| format!("Protocol error ({method}): {}", error.message)
    };
    let mut window = None;
    if is_main {
        window = session
            .call("Browser.getWindowForTarget", json!({}))
            .await
            .ok()
            .and_then(|reply| reply.get("windowId").cloned());
    }
    let echo = |method: &'static str, kind: &'static str| {
        let session = session.clone();
        let events = shared.events.clone();
        async move {
            session
                .call_echo(
                    method,
                    json!({}),
                    &events,
                    "pirc.echo",
                    json!({ "kind": kind }),
                )
                .await
                .map(|_| ())
                .map_err(fail(method))
        }
    };
    let call = |method: &'static str, params: Value| {
        let session = session.clone();
        async move {
            session
                .call(method, params)
                .await
                .map(|_| ())
                .map_err(fail(method))
        }
    };
    let viewport = shared.state.lock().unwrap().viewport;
    // The guard lets the target run once it is in place.
    let (guarded_tx, guarded_rx) = oneshot::channel::<()>();
    let network = {
        let session = session.clone();
        let shared = shared.clone();
        let target = target.clone();
        async move {
            // Sent in order without awaiting the replies a paused target
            // (a `noopener` popup) only gives once it runs; the guard's
            // request interception is on before it runs
            // ([`super::network::install_split`]).
            let enable = session.call("Network.enable", json!({}));
            let guard = async {
                let kind = if is_main {
                    TargetKind::Page
                } else {
                    TargetKind::Iframe
                };
                let (installed, replies) = (shared.installer)(session.clone(), kind)
                    .await
                    .map_err(|error| error.message)?;
                if let Some(frame_session) = shared.state.lock().unwrap().sessions.get_mut(&target)
                {
                    frame_session.guard = installed;
                }
                let _ = guarded_tx.send(());
                replies.await.map_err(|error| error.message)
            };
            let (enabled, guarded) = tokio::join!(enable, guard);
            enabled.map_err(fail("Network.enable"))?;
            guarded
        }
    };
    // Last, as Playwright sends it, and never before the guard is in place
    // (a failed guard leaves the target paused).
    let resume = {
        let session = session.clone();
        async move {
            if guarded_rx.await.is_err() {
                // The guard failed: its step reports why.
                std::future::pending::<()>().await;
            }
            session
                .call("Runtime.runIfWaitingForDebugger", json!({}))
                .await
                .map(|_| ())
                .map_err(fail("Runtime.runIfWaitingForDebugger"))
        }
    };
    let mut steps: Vec<futures_util::future::BoxFuture<'_, std::result::Result<(), String>>> = vec![
        Box::pin(call("Page.enable", json!({}))),
        Box::pin(echo("Page.getFrameTree", "frameTree")),
        Box::pin(call("Log.enable", json!({}))),
        Box::pin(async {
            let session = session.clone();
            session
                .call_echo(
                    "Page.setLifecycleEventsEnabled",
                    json!({ "enabled": true }),
                    &shared.events,
                    "pirc.echo",
                    json!({ "kind": "lifecycle" }),
                )
                .await
                .map(|_| ())
                .map_err(fail("Page.setLifecycleEventsEnabled"))
        }),
        Box::pin(call("Runtime.enable", json!({}))),
        Box::pin(call(
            "Page.addScriptToEvaluateOnNewDocument",
            json!({ "source": "", "worldName": shared.world }),
        )),
        Box::pin(network),
        Box::pin(call(
            "Target.setAutoAttach",
            json!({ "autoAttach": true, "waitForDebuggerOnStart": true, "flatten": true }),
        )),
    ];
    if is_main {
        steps.push(Box::pin(call(
            "Emulation.setFocusEmulationEnabled",
            json!({ "enabled": true }),
        )));
        let (width, height) = viewport;
        if let Some(window) = window {
            steps.push(Box::pin(call(
                "Browser.setWindowBounds",
                json!({ "windowId": window, "bounds": { "width": width, "height": height } }),
            )));
        }
        steps.push(Box::pin(call(
            "Emulation.setDeviceMetricsOverride",
            json!({
                "mobile": false,
                "width": width,
                "height": height,
                "screenWidth": width,
                "screenHeight": height,
                "deviceScaleFactor": 1,
                "screenOrientation": { "angle": 0, "type": "landscapePrimary" },
            }),
        )));
    }
    steps.push(Box::pin(call(
        "Page.setFontFamilies",
        font_families(shared.mac),
    )));
    steps.push(Box::pin(call(
        "Emulation.setEmulatedMedia",
        json!({ "media": "", "features": [
            { "name": "prefers-color-scheme", "value": "light" },
            { "name": "prefers-reduced-motion", "value": "no-preference" },
            { "name": "forced-colors", "value": "none" },
            { "name": "prefers-contrast", "value": "no-preference" },
        ] }),
    )));
    // Polled after every step above was polled (and wrote its command)
    // once.
    steps.push(Box::pin(resume));
    if let Some(first) = first_navigation {
        steps.push(Box::pin(async move {
            first
                .await
                .unwrap_or_else(|_| Err(CdpError::closed().message))
        }));
    }
    futures_util::future::try_join_all(steps).await.map(|_| ())
}

// ---------------------------------------------------------------------------
// Event handling.

fn handle(shared: &Arc<Shared>, event: Event) {
    if event.method == "pirc.barrier" {
        let mut state = shared.state.lock().unwrap();
        state.barrier = state.barrier.max(event.params.as_u64().unwrap_or(0));
        drop(state);
        shared.bump();
        return;
    }
    let Some(session_id) = event.session.as_deref() else {
        return;
    };
    let mut state = shared.state.lock().unwrap();
    if state.closed {
        return;
    }
    match state.routes.get(session_id).cloned() {
        Some(Route::Frame(target)) => frame_event(shared, &mut state, &target, &event),
        Some(Route::Worker { owner, frame }) => {
            worker_event(shared, &mut state, &owner, session_id, frame, &event)
        }
        None => {}
    }
    drop(state);
    shared.bump();
}

fn frame_event(shared: &Arc<Shared>, state: &mut State, target: &str, event: &Event) {
    let Some(session) = state.sessions.get(target) else {
        return;
    };
    let (renderer, lifecycle) = (session.renderer, session.lifecycle);
    let params = &event.params;
    match event.method.as_str() {
        "pirc.echo" => echo_event(shared, state, target, params),
        "Target.attachedToTarget" => attached(shared, state, target, params),
        "Target.detachedFromTarget" => detached(shared, state, target, params),
        // `_onTargetCrashed` (the session's commands fail in the
        // connection). An out-of-process iframe's crash leaves the page
        // usable: a deviation, see the module docs.
        "Inspector.targetCrashed" if target == shared.target_id => state.crashed = true,
        "Page.windowOpen" => {
            let features = params["windowFeatures"]
                .as_array()
                .map(|features| {
                    features
                        .iter()
                        .filter_map(|feature| feature.as_str().map(str::to_owned))
                        .collect()
                })
                .unwrap_or_default();
            state.window_features.push_back(features);
        }
        "Network.requestWillBeSent" => request_will_be_sent(shared, state, target, None, params),
        "Network.responseReceived" => response_received(state, params),
        "Network.loadingFinished" => loading_finished(shared, state, params),
        "Network.loadingFailed" => loading_failed(shared, state, params),
        "Page.lifecycleEvent" if lifecycle => {
            let frame_id = params["frameId"].as_str().unwrap_or_default();
            if state.stale(target, frame_id) {
                return;
            }
            let event = match params["name"].as_str() {
                Some("load") => LoadState::Load,
                Some("DOMContentLoaded") => LoadState::DomContentLoaded,
                _ => return,
            };
            let key = state.ids[frame_id];
            on_lifecycle(shared, state, key, event);
        }
        _ if !renderer => {}
        "Page.frameAttached" => frame_attached_event(
            shared,
            state,
            target,
            params["frameId"].as_str().unwrap_or_default(),
            params["parentFrameId"].as_str(),
        ),
        "Page.frameDetached" => {
            let frame_id = params["frameId"].as_str().unwrap_or_default();
            if state.sessions.contains_key(frame_id) {
                return;
            }
            let Some(&key) = state.ids.get(frame_id) else {
                return;
            };
            if params["reason"].as_str() == Some("swap") {
                remove_children(state, key);
                return;
            }
            remove_frame(state, key);
            if let Some(main) = state.main {
                recalculate_network_idle(state, main, None);
            }
        }
        "Page.frameNavigated" => frame_navigated(shared, state, target, &params["frame"], false),
        "Page.frameRequestedNavigation" => {
            let frame_id = params["frameId"].as_str().unwrap_or_default();
            if state.stale(target, frame_id) {
                return;
            }
            if params["disposition"].as_str() == Some("currentTab") {
                let key = state.ids[frame_id];
                if state.frames[&key].parent.is_none() {
                    // `SignalBarrier.addFrameNavigation`.
                    for held in state.signal_barriers.values_mut() {
                        *held += 1;
                    }
                }
                let frame = state.frames.get_mut(&key).unwrap();
                if frame
                    .pending
                    .as_ref()
                    .is_some_and(|pending| pending.document_id.is_none())
                {
                    return;
                }
                frame.pending = Some(Document::default());
            }
        }
        "Page.navigatedWithinDocument" => {
            let frame_id = params["frameId"].as_str().unwrap_or_default();
            if state.stale(target, frame_id) {
                return;
            }
            let key = state.ids[frame_id];
            let url = params["url"].as_str().unwrap_or_default().to_owned();
            let frame = state.frames.get_mut(&key).unwrap();
            if frame
                .pending
                .as_ref()
                .is_some_and(|pending| pending.document_id.is_none() && pending.request.is_none())
            {
                frame.pending = None;
            }
            frame.url = url.clone();
            fire_navigation(
                state,
                key,
                Navigation {
                    url,
                    new_document: None,
                    error: None,
                },
            );
        }
        "Page.javascriptDialogOpening" => {
            if !state.ids.contains_key(target) {
                return;
            }
            // No dialog handlers: Playwright closes every dialog, accepting
            // `beforeunload` and dismissing the others.
            let accept = params["type"].as_str() == Some("beforeunload");
            let session = state.sessions[target].session.clone();
            shared.resource.clone().spawn(async move {
                let _ = session
                    .call("Page.handleJavaScriptDialog", json!({ "accept": accept }))
                    .await;
            });
        }
        "Runtime.executionContextCreated" => {
            let context = &params["context"];
            let Some(frame_id) = context["auxData"]["frameId"].as_str() else {
                return;
            };
            if !state.ids.contains_key(frame_id) || state.stale(target, frame_id) {
                return;
            }
            let key = state.ids[frame_id];
            let world = if context["auxData"]["isDefault"].as_bool() == Some(true) {
                Some(World::Main)
            } else if context["name"].as_str() == Some(shared.world.as_str()) {
                Some(World::Utility)
            } else {
                None
            };
            let Some(id) = context["id"].as_i64() else {
                return;
            };
            let uid = state.uid();
            let session = state.sessions.get_mut(target).unwrap();
            session
                .contexts
                .insert(id, ContextEntry { uid, frame: key });
            let execution = ExecContext::new(uid, id, session.session.clone());
            if let Some(world) = world {
                let frame = state.frames.get_mut(&key).unwrap();
                match world {
                    World::Main => frame.main_world = Some(execution),
                    World::Utility => frame.utility_world = Some(execution),
                }
            }
        }
        "Runtime.executionContextDestroyed" => {
            if let Some(id) = params["executionContextId"].as_i64() {
                context_destroyed(state, target, id);
            }
        }
        "Runtime.executionContextsCleared" => {
            let ids: Vec<i64> = state.sessions[target].contexts.keys().copied().collect();
            for id in ids {
                context_destroyed(state, target, id);
            }
        }
        _ => {}
    }
}

fn worker_event(
    shared: &Arc<Shared>,
    state: &mut State,
    owner: &str,
    _session_id: &str,
    frame: Option<FrameKey>,
    event: &Event,
) {
    let params = &event.params;
    match event.method.as_str() {
        "Target.attachedToTarget" => attached(shared, state, owner, params),
        "Target.detachedFromTarget" => detached(shared, state, owner, params),
        "Network.requestWillBeSent" => request_will_be_sent(shared, state, owner, frame, params),
        "Network.responseReceived" => response_received(state, params),
        "Network.loadingFinished" => loading_finished(shared, state, params),
        "Network.loadingFailed" => loading_failed(shared, state, params),
        _ => {}
    }
}

fn echo_event(shared: &Arc<Shared>, state: &mut State, target: &str, params: &Value) {
    match params["tag"]["kind"].as_str() {
        Some("frameTree") => {
            let Some(session) = state.sessions.get(target) else {
                return;
            };
            let is_main = session.is_main;
            if params.get("error").is_some() {
                return;
            }
            if is_main {
                handle_frame_tree(shared, state, target, &params["result"]["frameTree"]);
                state.sessions.get_mut(target).unwrap().renderer = true;
            }
            let buffered = state
                .sessions
                .get_mut(target)
                .and_then(|session| session.buffered.take())
                .unwrap_or_default();
            for event in buffered {
                attached(shared, state, target, &event);
            }
            let Some(session) = state.sessions.get(target) else {
                return;
            };
            let local: Vec<String> = if is_main {
                state
                    .frame_keys()
                    .into_iter()
                    .map(|key| state.frames[&key].id.clone())
                    .collect()
            } else {
                state
                    .ids
                    .contains_key(target)
                    .then(|| target.to_owned())
                    .into_iter()
                    .collect()
            };
            for frame_id in local {
                let session = session.session.clone();
                let world = shared.world.clone();
                shared.resource.clone().spawn(async move {
                    let _ = session
                        .call(
                            "Page.createIsolatedWorld",
                            json!({ "frameId": frame_id, "grantUniveralAccess": true, "worldName": world }),
                        )
                        .await;
                });
            }
            let initial_empty = is_main
                && state
                    .main
                    .and_then(|main| state.frames.get(&main))
                    .is_some_and(|main| main.url.is_empty() || main.url == ":");
            let session = state.sessions.get_mut(target).unwrap();
            if initial_empty {
                if session.lifecycle_enabled {
                    session.lifecycle = true;
                } else {
                    session.lifecycle_on_enable = true;
                }
            } else {
                if let Some(first) = session.first_navigation.take() {
                    let _ = first.send(Ok(()));
                }
                session.lifecycle = true;
            }
        }
        Some("lifecycle") => {
            if let Some(session) = state.sessions.get_mut(target) {
                session.lifecycle_enabled = true;
                if session.lifecycle_on_enable {
                    session.lifecycle = true;
                }
            }
        }
        Some("childDetached") => {
            let child = params["tag"]["target"].as_str().unwrap_or_default();
            let Some(session) = state.sessions.get(child) else {
                return;
            };
            if !session.swapped_in
                && let Some(&key) = state.ids.get(child)
            {
                remove_frame(state, key);
                if let Some(main) = state.main {
                    recalculate_network_idle(state, main, None);
                }
            }
            dispose_session(state, child);
        }
        _ => {}
    }
    let _ = shared;
}

fn handle_frame_tree(shared: &Arc<Shared>, state: &mut State, target: &str, tree: &Value) {
    let frame = &tree["frame"];
    frame_attached_event(
        shared,
        state,
        target,
        frame["id"].as_str().unwrap_or_default(),
        frame["parentId"].as_str(),
    );
    frame_navigated(shared, state, target, frame, true);
    if let Some(children) = tree["childFrames"].as_array() {
        for child in children {
            handle_frame_tree(shared, state, target, child);
        }
    }
}

fn frame_attached_event(
    shared: &Arc<Shared>,
    state: &mut State,
    target: &str,
    frame_id: &str,
    parent_id: Option<&str>,
) {
    if frame_id != target
        && let Some(session) = state.sessions.get_mut(frame_id)
    {
        session.swapped_in = true;
        if let Some(&key) = state.ids.get(frame_id) {
            remove_children(state, key);
        }
        return;
    }
    if let Some(parent) = parent_id
        && !state.ids.contains_key(parent)
    {
        return;
    }
    frame_attached(shared, state, frame_id, parent_id);
}

/// `FrameManager.frameAttached`.
fn frame_attached(
    shared: &Arc<Shared>,
    state: &mut State,
    frame_id: &str,
    parent_id: Option<&str>,
) -> FrameKey {
    let parent = parent_id.and_then(|parent| state.ids.get(parent).copied());
    if parent.is_none()
        && let Some(main) = state.main
    {
        let old = std::mem::replace(
            &mut state.frames.get_mut(&main).unwrap().id,
            frame_id.to_owned(),
        );
        state.ids.remove(&old);
        state.ids.insert(frame_id.to_owned(), main);
        return main;
    }
    let key = state.next_key;
    state.next_key += 1;
    let seq = state.next_seq;
    state.next_seq += 1;
    let mut fired = HashMap::new();
    fired.insert(LoadState::Commit, 1);
    state.frames.insert(
        key,
        FrameState {
            id: frame_id.to_owned(),
            seq,
            parent,
            children: Vec::new(),
            url: String::new(),
            name: String::new(),
            lifecycle: HashSet::from([LoadState::Commit]),
            fired,
            idle_self: false,
            idle_timer: None,
            inflight: HashSet::new(),
            current: Document::default(),
            pending: None,
            main_world: None,
            utility_world: None,
            navigations: Vec::new(),
        },
    );
    state.ids.insert(frame_id.to_owned(), key);
    match parent {
        Some(parent) => state.frames.get_mut(&parent).unwrap().children.push(key),
        None => state.main = Some(key),
    }
    start_idle_timer(shared, state, key);
    key
}

fn frame_navigated(
    shared: &Arc<Shared>,
    state: &mut State,
    target: &str,
    payload: &Value,
    initial: bool,
) {
    let frame_id = payload["id"].as_str().unwrap_or_default();
    if state.stale(target, frame_id) {
        return;
    }
    let key = state.ids[frame_id];
    let url = format!(
        "{}{}",
        payload["url"].as_str().unwrap_or_default(),
        payload["urlFragment"].as_str().unwrap_or_default()
    );
    let name = payload["name"].as_str().unwrap_or_default().to_owned();
    let document_id = payload["loaderId"].as_str().map(str::to_owned);
    committed_new_document(shared, state, key, url, name, document_id, initial);
    if !initial
        && let Some(session) = state.sessions.get_mut(target)
        && let Some(first) = session.first_navigation.take()
    {
        let _ = first.send(Ok(()));
    }
}

/// `FrameManager.frameCommittedNewDocumentNavigation`.
fn committed_new_document(
    shared: &Arc<Shared>,
    state: &mut State,
    key: FrameKey,
    url: String,
    name: String,
    document_id: Option<String>,
    initial: bool,
) {
    remove_children(state, key);
    let frame = state.frames.get_mut(&key).unwrap();
    let previous = std::mem::replace(&mut frame.url, url.clone());
    frame.name = name;
    let mut keep_pending = None;
    match frame.pending.take() {
        Some(mut pending) => {
            if pending.document_id.is_none() {
                pending.document_id = document_id.clone();
            }
            if pending.document_id == document_id {
                frame.current = pending;
            } else {
                keep_pending = Some(pending);
                frame.current = Document {
                    document_id,
                    request: None,
                };
            }
        }
        None => {
            frame.current = Document {
                document_id,
                request: None,
            };
        }
    }
    let current = frame.current.clone();
    clear_lifecycle(shared, state, key);
    fire_navigation(
        state,
        key,
        Navigation {
            url,
            new_document: Some(current),
            error: None,
        },
    );
    // A popup's initial document is `about:blank`, or `:` as Chromium 150
    // on macOS reports it: leaving it keeps the frame's number.
    if !initial && state.main == Some(key) && !matches!(previous.as_str(), "" | "about:blank" | ":")
    {
        let seq = state.next_seq;
        state.next_seq += 1;
        state.frames.get_mut(&key).unwrap().seq = seq;
    }
    state.frames.get_mut(&key).unwrap().pending = keep_pending;
}

fn fire_navigation(state: &mut State, key: FrameKey, navigation: Navigation) {
    let Some(frame) = state.frames.get_mut(&key) else {
        return;
    };
    frame
        .navigations
        .retain(|listener| listener.send(navigation.clone()).is_ok());
    if state.main == Some(key) {
        // `SignalBarrier.addFrameNavigation`'s waiters.
        for held in state.signal_barriers.values_mut() {
            *held = 0;
        }
    }
    if state.main == Some(key) && navigation.error.is_none() {
        state.emit(PageEvent::MainFrameNavigated);
    }
}

/// `FrameManager.frameAbortedNavigation`.
fn aborted_navigation(
    state: &mut State,
    key: FrameKey,
    error: String,
    document_id: Option<String>,
) {
    let Some(frame) = state.frames.get_mut(&key) else {
        return;
    };
    let Some(pending) = &frame.pending else {
        return;
    };
    if document_id.is_some() && pending.document_id != document_id {
        return;
    }
    let pending = frame.pending.take();
    let url = frame.url.clone();
    fire_navigation(
        state,
        key,
        Navigation {
            url,
            new_document: pending,
            error: Some(error),
        },
    );
}

fn remove_children(state: &mut State, key: FrameKey) {
    let children = state
        .frames
        .get(&key)
        .map(|frame| frame.children.clone())
        .unwrap_or_default();
    for child in children {
        remove_frame(state, child);
    }
}

/// `_removeFramesRecursively` + `Frame._onDetached`.
fn remove_frame(state: &mut State, key: FrameKey) {
    remove_children(state, key);
    let Some(mut frame) = state.frames.remove(&key) else {
        return;
    };
    if let Some((_, timer)) = frame.idle_timer.take() {
        timer.abort();
    }
    if state.ids.get(&frame.id) == Some(&key) {
        state.ids.remove(&frame.id);
    }
    if let Some(parent) = frame.parent
        && let Some(parent) = state.frames.get_mut(&parent)
    {
        parent.children.retain(|child| *child != key);
    }
    if state.main == Some(key) {
        state.main = None;
    }
}

fn context_destroyed(state: &mut State, target: &str, id: i64) {
    let Some(entry) = state
        .sessions
        .get_mut(target)
        .and_then(|session| session.contexts.remove(&id))
    else {
        return;
    };
    let Some(frame) = state.frames.get_mut(&entry.frame) else {
        return;
    };
    if frame
        .main_world
        .as_ref()
        .is_some_and(|c| c.uid == entry.uid)
    {
        frame.main_world = None;
    }
    if frame
        .utility_world
        .as_ref()
        .is_some_and(|c| c.uid == entry.uid)
    {
        frame.utility_world = None;
    }
}

/// `FrameSession._onAttachedToTarget`: an out-of-process iframe gets its
/// own frame session; a worker is guarded and let run; anything else is
/// detached.
fn attached(shared: &Arc<Shared>, state: &mut State, target: &str, params: &Value) {
    let Some(parent) = state.sessions.get_mut(target) else {
        return;
    };
    if let Some(buffered) = &mut parent.buffered {
        buffered.push(params.clone());
        return;
    }
    let parent_session = parent.session.clone();
    let Some(session_id) = params["sessionId"].as_str() else {
        return;
    };
    let session = parent_session.connection().session(session_id);
    let info = &params["targetInfo"];
    let child = info["targetId"].as_str().unwrap_or_default().to_owned();
    match info["type"].as_str() {
        Some("iframe") => {
            let key = match state.ids.get(&child) {
                Some(&key) => key,
                None => match info["parentFrameId"].as_str() {
                    Some(parent) if state.ids.contains_key(parent) => {
                        frame_attached(shared, state, &child, Some(parent))
                    }
                    _ => return,
                },
            };
            remove_children(state, key);
            let stale: Vec<i64> = state.sessions[target]
                .contexts
                .iter()
                .filter(|(_, entry)| entry.frame == key)
                .map(|(id, _)| *id)
                .collect();
            for id in stale {
                context_destroyed(state, target, id);
            }
            session.fail_on_crash();
            state.sessions.insert(
                child.clone(),
                FrameSession::new(session.clone(), Some(target.to_owned()), false),
            );
            state
                .routes
                .insert(session_id.to_owned(), Route::Frame(child.clone()));
            session.listen_into(shared.events.clone());
            let shared = shared.clone();
            shared.resource.clone().spawn(async move {
                let _ = init_session(&shared, child, session, false, None).await;
            });
        }
        Some("worker") => {
            let frame = info["parentFrameId"]
                .as_str()
                .and_then(|id| state.ids.get(id))
                .or_else(|| state.ids.get(target))
                .copied();
            state
                .sessions
                .get_mut(target)
                .unwrap()
                .workers
                .insert(session_id.to_owned(), None);
            state.routes.insert(
                session_id.to_owned(),
                Route::Worker {
                    owner: target.to_owned(),
                    frame,
                },
            );
            session.listen_into(shared.events.clone());
            let shared = shared.clone();
            let owner = target.to_owned();
            let session_id = session_id.to_owned();
            shared.resource.clone().spawn(async move {
                let _ = session.call("Runtime.enable", json!({})).await;
                let _ = session.call("Network.enable", json!({})).await;
                let Ok((installed, replies)) =
                    (shared.installer)(session.clone(), TargetKind::Worker).await
                else {
                    // Unguarded: it stays paused.
                    return;
                };
                if replies.await.is_err() {
                    return;
                }
                if let Some(slot) = shared
                    .state
                    .lock()
                    .unwrap()
                    .sessions
                    .get_mut(&owner)
                    .and_then(|owner| owner.workers.get_mut(&session_id))
                {
                    *slot = installed;
                }
                let _ = session
                    .call("Runtime.runIfWaitingForDebugger", json!({}))
                    .await;
                let _ = session
                    .call(
                        "Target.setAutoAttach",
                        json!({ "autoAttach": true, "waitForDebuggerOnStart": true, "flatten": true }),
                    )
                    .await;
            });
        }
        _ => {
            let session_id = session_id.to_owned();
            shared.resource.clone().spawn(async move {
                let _ = session
                    .call("Runtime.runIfWaitingForDebugger", json!({}))
                    .await;
                let _ = parent_session
                    .call(
                        "Target.detachFromTarget",
                        json!({ "sessionId": session_id }),
                    )
                    .await;
            });
        }
    }
}

/// `FrameSession._onDetachedFromTarget`.
fn detached(shared: &Arc<Shared>, state: &mut State, target: &str, params: &Value) {
    let session_id = params["sessionId"].as_str().unwrap_or_default();
    if let Some(owner) = state.sessions.get_mut(target)
        && owner.workers.remove(session_id).is_some()
    {
        state.routes.remove(session_id);
        return;
    }
    let child = params["targetId"].as_str().unwrap_or_default().to_owned();
    let Some(child_session) = state.sessions.get(&child) else {
        return;
    };
    if child_session.swapped_in {
        dispose_session(state, &child);
        return;
    }
    let session = state.sessions[target].session.clone();
    let events = shared.events.clone();
    shared.resource.clone().spawn(async move {
        let _ = session
            .call_echo(
                "Page.enable",
                json!({}),
                &events,
                "pirc.echo",
                json!({ "kind": "childDetached", "target": child }),
            )
            .await;
    });
}

/// `FrameSession.dispose`: the session, its child sessions and workers.
fn dispose_session(state: &mut State, target: &str) {
    let Some(mut session) = state.sessions.remove(target) else {
        return;
    };
    if let Some(first) = session.first_navigation.take() {
        let _ = first.send(Err(CdpError::closed().message));
    }
    for worker in session.workers.keys() {
        state.routes.remove(worker);
    }
    if let Some(id) = session.session.id() {
        state.routes.remove(id);
    }
    let children: Vec<String> = state
        .sessions
        .iter()
        .filter(|(_, child)| child.parent.as_deref() == Some(target))
        .map(|(id, _)| id.clone())
        .collect();
    for child in children {
        dispose_session(state, &child);
    }
}

// ---------------------------------------------------------------------------
// Lifecycle and `networkidle` (`Frame` in `frames.ts`).

fn on_lifecycle(shared: &Arc<Shared>, state: &mut State, key: FrameKey, event: LoadState) {
    let Some(frame) = state.frames.get_mut(&key) else {
        return;
    };
    if !frame.lifecycle.insert(event) {
        return;
    }
    *frame.fired.entry(event).or_default() += 1;
    if state.main == Some(key) && event == LoadState::Load {
        state.emit(PageEvent::Load);
    }
    if let Some(main) = state.main {
        recalculate_network_idle(state, main, None);
    }
    let _ = shared;
}

/// `Frame._onClearLifecycle`: a new document committed.
fn clear_lifecycle(shared: &Arc<Shared>, state: &mut State, key: FrameKey) {
    let frame = state.frames.get_mut(&key).unwrap();
    frame.lifecycle.clear();
    let current = frame.current.request.as_ref().map(|request| request.id);
    frame.inflight.retain(|id| Some(*id) == current);
    stop_idle_timer(frame);
    if frame.inflight.is_empty() {
        start_idle_timer(shared, state, key);
    }
    if let Some(main) = state.main {
        recalculate_network_idle(state, main, Some(key));
    }
    on_lifecycle(shared, state, key, LoadState::Commit);
}

/// `Frame._recalculateNetworkIdle`.
fn recalculate_network_idle(state: &mut State, key: FrameKey, allow_removal: Option<FrameKey>) {
    let Some(frame) = state.frames.get(&key) else {
        return;
    };
    let mut idle = frame.idle_self;
    for child in frame.children.clone() {
        recalculate_network_idle(state, child, allow_removal);
        if !state.frames[&child].has(LoadState::NetworkIdle) {
            idle = false;
        }
    }
    let frame = state.frames.get_mut(&key).unwrap();
    if idle && frame.lifecycle.insert(LoadState::NetworkIdle) {
        *frame.fired.entry(LoadState::NetworkIdle).or_default() += 1;
    }
    if allow_removal != Some(key) && frame.has(LoadState::NetworkIdle) && !idle {
        frame.lifecycle.remove(&LoadState::NetworkIdle);
    }
}

fn start_idle_timer(shared: &Arc<Shared>, state: &mut State, key: FrameKey) {
    let token = state.uid();
    let frame = state.frames.get_mut(&key).unwrap();
    stop_idle_timer(frame);
    if frame.has(LoadState::NetworkIdle) {
        return;
    }
    let weak = Arc::downgrade(shared);
    let task = shared.resource.clone().spawn(async move {
        tokio::time::sleep(Duration::from_millis(500)).await;
        let Some(shared) = weak.upgrade() else {
            return;
        };
        let mut state = shared.state.lock().unwrap();
        let Some(frame) = state.frames.get_mut(&key) else {
            return;
        };
        if frame.idle_timer.as_ref().map(|(token, _)| *token) != Some(token) {
            return;
        }
        frame.idle_timer = None;
        frame.idle_self = true;
        if let Some(main) = state.main {
            recalculate_network_idle(&mut state, main, None);
        }
        drop(state);
        shared.bump();
    });
    frame.idle_timer = Some((token, task.abort_handle()));
}

fn stop_idle_timer(frame: &mut FrameState) {
    if let Some((_, timer)) = frame.idle_timer.take() {
        timer.abort();
    }
    frame.idle_self = false;
}

// ---------------------------------------------------------------------------
// Requests (`CRNetworkManager`'s bookkeeping navigation and `networkidle`
// use; the guard's `Fetch` handling is in [`super::network`]).

fn request_will_be_sent(
    shared: &Arc<Shared>,
    state: &mut State,
    target: &str,
    worker_frame: Option<FrameKey>,
    params: &Value,
) {
    let url = params["request"]["url"].as_str().unwrap_or_default();
    if url.starts_with("data:") {
        return;
    }
    let request_id = params["requestId"].as_str().unwrap_or_default().to_owned();
    let mut redirected_from = None;
    if params.get("redirectResponse").is_some_and(Value::is_object)
        && let Some(previous) = state.requests.remove(&request_id)
    {
        previous.state.lock().unwrap().response = params["redirectResponse"]["status"]
            .as_u64()
            .map(|s| s as u16);
        request_finished(shared, state, &previous);
        redirected_from = Some(previous);
    }
    let mut frame = match params["frameId"].as_str() {
        Some(id) => state.ids.get(id).copied(),
        None => worker_frame,
    };
    if frame.is_none() && params["frameId"].as_str() == Some(shared.target_id.as_str()) {
        frame = Some(frame_attached(shared, state, &shared.target_id, None));
    }
    let Some(frame) = frame else {
        return;
    };
    let _ = target;
    let navigation = params["requestId"] == params["loaderId"] && params["type"] == "Document";
    let document_id = navigation.then(|| request_id.clone());
    let favicon =
        url.ends_with("/favicon.ico") || redirected_from.as_ref().is_some_and(|from| from.favicon);
    let event_source = params["type"]
        .as_str()
        .is_some_and(|kind| kind.eq_ignore_ascii_case("EventSource"));
    let id = state.uid();
    let request = Arc::new(Request {
        id,
        url: url.split('#').next().unwrap_or(url).to_owned(),
        frame: Some(frame),
        excluded: favicon || event_source,
        favicon,
        state: Mutex::default(),
    });
    if let Some(from) = &redirected_from {
        from.state.lock().unwrap().redirected_to = Some(request.clone());
    }
    state.requests.insert(request_id, request.clone());
    // `requestStarted`.
    if !request.excluded
        && let Some(frame_state) = state.frames.get_mut(&frame)
    {
        frame_state.inflight.insert(id);
        if frame_state.inflight.len() == 1 {
            stop_idle_timer(frame_state);
        }
    }
    if document_id.is_some()
        && let Some(frame_state) = state.frames.get_mut(&frame)
    {
        frame_state.pending = Some(Document {
            document_id,
            request: Some(request),
        });
    }
}

fn response_received(state: &mut State, params: &Value) {
    let Some(request) = params["requestId"]
        .as_str()
        .and_then(|id| state.requests.get(id))
    else {
        return;
    };
    request.state.lock().unwrap().response =
        params["response"]["status"].as_u64().map(|s| s as u16);
}

fn loading_finished(shared: &Arc<Shared>, state: &mut State, params: &Value) {
    let Some(request) = params["requestId"]
        .as_str()
        .and_then(|id| state.requests.remove(id))
    else {
        return;
    };
    request_finished(shared, state, &request);
}

fn loading_failed(shared: &Arc<Shared>, state: &mut State, params: &Value) {
    let Some(request) = params["requestId"]
        .as_str()
        .and_then(|id| state.requests.remove(id))
    else {
        return;
    };
    let failure = params["errorText"]
        .as_str()
        .filter(|text| !text.is_empty())
        .or_else(|| params["blockedReason"].as_str())
        .unwrap_or_default()
        .to_owned();
    request.state.lock().unwrap().failure = Some(failure.clone());
    request_finished(shared, state, &request);
    // `requestFailed`: the frame's pending navigation fails with it.
    let Some(key) = request.frame else {
        return;
    };
    let pending = state
        .frames
        .get(&key)
        .and_then(|frame| frame.pending.as_ref())
        .filter(|pending| {
            pending
                .request
                .as_ref()
                .is_some_and(|pending| pending.id == request.id)
        })
        .map(|pending| pending.document_id.clone());
    if let Some(document_id) = pending {
        let mut error = failure;
        if params["canceled"].as_bool() == Some(true) {
            error.push_str("; maybe frame was detached?");
        }
        aborted_navigation(state, key, error, document_id);
    }
}

/// `_inflightRequestFinished`.
fn request_finished(shared: &Arc<Shared>, state: &mut State, request: &Request) {
    if request.excluded {
        return;
    }
    let Some(key) = request.frame else {
        return;
    };
    let Some(frame) = state.frames.get_mut(&key) else {
        return;
    };
    if !frame.inflight.remove(&request.id) {
        return;
    }
    if frame.inflight.is_empty() {
        start_idle_timer(shared, state, key);
    }
}

// ---------------------------------------------------------------------------
// Navigation waits, used by [`Frame`].

impl Frame {
    /// Navigation events of this frame from now on.
    pub(super) fn subscribe_navigations(&self) -> mpsc::UnboundedReceiver<Navigation> {
        let (tx, rx) = mpsc::unbounded_channel();
        if let Some(frame) = self.shared.state.lock().unwrap().frames.get_mut(&self.key) {
            frame.navigations.push(tx);
        }
        rx
    }

    /// The next navigation event matching `predicate`; fails when the frame
    /// detaches or the page closes.
    async fn next_navigation(
        &self,
        api: &str,
        navigations: &mut mpsc::UnboundedReceiver<Navigation>,
        mut predicate: impl FnMut(&Navigation) -> bool,
    ) -> Result<Navigation> {
        loop {
            tokio::select! {
                navigation = navigations.recv() => match navigation {
                    Some(navigation) if predicate(&navigation) => return Ok(navigation),
                    Some(_) => {}
                    None => return Err(self.gone_error(api)),
                },
                error = self.gone(api) => return Err(error),
            }
        }
    }

    /// Resolves with the error once the page closed or the frame detached.
    pub(super) async fn gone(&self, api: &str) -> Error {
        self.shared
            .wait(|state| {
                if state.closed {
                    Some(closed_error(api))
                } else if !state.frames.contains_key(&self.key) {
                    Some(Error::api(api, "Frame was detached"))
                } else {
                    None
                }
            })
            .await
    }

    fn gone_error(&self, api: &str) -> Error {
        if self.shared.state.lock().unwrap().closed {
            closed_error(api)
        } else {
            Error::api(api, "Frame was detached")
        }
    }

    /// Wait until `state` fired for the current document (`AddLifecycle`).
    pub(super) async fn wait_lifecycle(&self, api: &str, wanted: LoadState) -> Result<()> {
        let mut start = None;
        let wait = self.shared.wait(|state| {
            let Some(frame) = state.frames.get(&self.key) else {
                return Some(Err(if state.closed {
                    closed_error(api)
                } else {
                    Error::api(api, "Frame was detached")
                }));
            };
            if state.closed {
                return Some(Err(closed_error(api)));
            }
            let fired = frame.fired.get(&wanted).copied().unwrap_or(0);
            let start = *start.get_or_insert(fired);
            (frame.has(wanted) || fired > start).then_some(Ok(()))
        });
        wait.await
    }

    /// `Frame.gotoImpl`.
    pub(super) async fn goto_impl(
        &self,
        api: &str,
        url: &str,
        wait_until: LoadState,
    ) -> Result<Option<Response>> {
        let url = if url.starts_with("localhost") || url.starts_with("127.0.0.1") {
            format!("http://{url}")
        } else {
            url.to_owned()
        };
        let mut navigations = self.subscribe_navigations();
        let session = self
            .owning_session()
            .ok_or_else(|| Error::api(api, "Frame was detached"))?;
        let reply = session
            .call(
                "Page.navigate",
                json!({ "url": url, "frameId": self.id(), "referrerPolicy": "unsafeUrl" }),
            )
            .await
            .map_err(|e| protocol_error(api, "Page.navigate", e))?;
        if reply["isDownload"].as_bool() == Some(true) {
            return Err(Error::api(api, "Download is starting"));
        }
        if let Some(text) = reply["errorText"].as_str().filter(|text| !text.is_empty()) {
            return Err(Error::api(api, format!("{text} at {url}")));
        }
        let navigation = match reply["loaderId"].as_str() {
            Some(loader) => {
                let navigation = self
                    .next_navigation(api, &mut navigations, |navigation| {
                        navigation.new_document.as_ref().is_some_and(|document| {
                            document.document_id.as_deref() == Some(loader)
                                || navigation.error.is_none()
                        })
                    })
                    .await?;
                let document = navigation.new_document.as_ref().unwrap();
                if document.document_id.as_deref() != Some(loader) {
                    return Err(Error::api(
                        api,
                        format!(
                            "Navigation to \"{url}\" is interrupted by another navigation to \"{}\"",
                            navigation.url
                        ),
                    ));
                }
                if let Some(error) = &navigation.error {
                    return Err(Error::api(api, error.clone()));
                }
                navigation
            }
            None => {
                self.next_navigation(api, &mut navigations, |navigation| {
                    navigation.new_document.is_none()
                })
                .await?
            }
        };
        drop(navigations);
        self.wait_lifecycle(api, wait_until).await?;
        self.response_of(api, &navigation).await
    }

    /// `Frame.waitForNavigation`.
    pub(super) async fn wait_for_navigation(
        &self,
        api: &str,
        mut navigations: mpsc::UnboundedReceiver<Navigation>,
        requires_new_document: bool,
        wait_until: LoadState,
    ) -> Result<Option<Response>> {
        let navigation = self
            .next_navigation(api, &mut navigations, |navigation| {
                navigation.error.is_some()
                    || !requires_new_document
                    || navigation.new_document.is_some()
            })
            .await?;
        drop(navigations);
        if let Some(error) = &navigation.error {
            return Err(Error::api(api, error.clone()));
        }
        self.wait_lifecycle(api, wait_until).await?;
        self.response_of(api, &navigation).await
    }

    async fn response_of(&self, api: &str, navigation: &Navigation) -> Result<Option<Response>> {
        let Some(request) = navigation
            .new_document
            .as_ref()
            .and_then(|document| document.request.clone())
        else {
            return Ok(None);
        };
        let request = request.final_request();
        let outcome = self.shared.wait(|state| {
            if state.closed {
                return Some(Err(closed_error(api)));
            }
            request.outcome().map(Ok)
        });
        Ok(outcome.await?.map(|status| Response { status }))
    }

    /// Run a navigation (`raceNavigationAction` under the API's timeout).
    pub(super) async fn race_navigation<T>(
        &self,
        api: &str,
        timeout: Duration,
        work: impl std::future::Future<Output = Result<T>>,
    ) -> Result<T> {
        let deadline = deadline(timeout);
        // `raceMultiple([_detachedScope, openScope])`: a crashed page fails
        // it at once.
        let crashed = self
            .shared
            .wait(|state| state.crashed.then(|| Error::api(api, "Page crashed")));
        let raced = async {
            let result = tokio::select! {
                biased;
                error = crashed => Err(error),
                result = work => result,
                error = self.gone(api) => Err(error),
            };
            // The connection marks the page's session crashed as it reads
            // `Inspector.targetCrashed`, the page only once its event loop
            // gets there: a command failing in between is the page's crash
            // too, which Playwright (one event dispatch) reports as such.
            // An out-of-process iframe's crash leaves the page's session.
            match result {
                Err(error)
                    if error.message == Error::api(api, CdpError::crashed().message).message
                        && self.shared.session.is_crashed() =>
                {
                    Err(Error::api(api, "Page crashed"))
                }
                other => other,
            }
        };
        within(deadline, raced)
            .await
            .unwrap_or_else(|| Err(Error::timeout(api, timeout)))
    }

    /// `waitForLoadState` under `api`'s timeout.
    pub(super) async fn wait_for_load_state_api(
        &self,
        api: &str,
        state: LoadState,
        timeout: Duration,
    ) -> Result<()> {
        within(deadline(timeout), self.wait_lifecycle(api, state))
            .await
            .unwrap_or_else(|| Err(Error::timeout(api, timeout)))
    }
}

impl std::fmt::Debug for Page {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Page")
            .field("target_id", &self.shared.target_id)
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::super::cdp::Fake;
    use super::*;

    #[tokio::test]
    async fn late_page_binding_fences_initialization_and_is_inherited_by_popups() {
        use crate::browser::effects::Guard;
        let mut fake = Fake::new();
        let connection = fake.connection.clone();
        let installer: Installer = Arc::new(|_, _| {
            Box::pin(async {
                Ok((
                    None,
                    Box::pin(async { Ok(()) }) as super::super::network::Replies,
                ))
            })
        });
        let page = Page::attach(PageSetup {
            target_id: "T".into(),
            session: connection.session("S"),
            browser: connection.browser(),
            installer: installer.clone(),
            viewport: (1280, 800),
            mac: false,
            opener: None,
        });
        let window = fake.command().await;
        assert_eq!(window["method"], "Browser.getWindowForTarget");
        let allowed = Arc::new(Mutex::new(true));
        let guard = Guard::new({
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
        page.bind_resource(guard.clone()).unwrap();
        page.bind_resource(guard).unwrap();
        assert!(
            page.bind_resource(Guard::new(|effect| {
                effect();
                Ok(())
            }))
            .is_err()
        );
        *allowed.lock().unwrap() = false;
        fake.send(json!({"id":window["id"],"sessionId":"S","result":{"windowId":1}}))
            .await;
        let initialized = tokio::time::timeout(
            Duration::from_secs(2),
            page.shared.wait(|s| s.initialized.clone()),
        )
        .await
        .unwrap();
        assert!(initialized.is_err());
        let popup = Page::attach(PageSetup {
            target_id: "P".into(),
            session: connection.session("popup"),
            browser: connection.browser(),
            installer,
            viewport: (1280, 800),
            mac: false,
            opener: Some(page.clone()),
        });
        let initialized = tokio::time::timeout(
            Duration::from_secs(2),
            popup.shared.wait(|s| s.initialized.clone()),
        )
        .await
        .unwrap();
        assert!(initialized.is_err());
        connection.session("peer").send("peer-sentinel", json!({}));
        assert_eq!(fake.command().await["method"], "peer-sentinel");
        // Trusted target close is outside the retired background scope.
        let close = popup.close();
        let reply = async {
            let close = fake.command().await;
            assert_eq!(close["method"], "Target.closeTarget");
            fake.send(json!({"id":close["id"],"result":{"success":true}}))
                .await;
            popup.did_close();
        };
        let (closed, ()) = tokio::join!(close, reply);
        closed.unwrap();
        page.did_close();
        popup.did_close();
    }

    #[tokio::test]
    async fn lets_the_target_run_once_every_initialization_command_is_sent() {
        let mut fake = Fake::new();
        let connection = fake.connection.clone();
        // An installer done at once (the engine tests' unguarded one).
        let installer: Installer = Arc::new(|_, _| {
            Box::pin(async {
                Ok((
                    None,
                    Box::pin(async { Ok(()) }) as super::super::network::Replies,
                ))
            })
        });
        let _page = Page::attach(PageSetup {
            target_id: "T".to_owned(),
            session: connection.session("S"),
            browser: connection.browser(),
            installer,
            viewport: (1280, 800),
            mac: false,
            opener: None,
        });
        let mut sent = Vec::new();
        tokio::time::timeout(Duration::from_secs(5), async {
            while !sent.iter().any(|m| m == "Runtime.runIfWaitingForDebugger")
                || !sent.iter().any(|m| m == "Emulation.setEmulatedMedia")
            {
                let command = fake.command().await;
                let method = command["method"].as_str().unwrap().to_owned();
                if method == "Browser.getWindowForTarget" {
                    fake.send(json!({ "id": command["id"], "sessionId": "S",
                        "result": { "windowId": 1, "bounds": {} } }))
                        .await;
                }
                sent.push(method);
            }
        })
        .await
        .expect("the initialization commands");
        // Playwright's `FrameSession._initialize` order: the target runs
        // once everything else was sent.
        assert_eq!(
            sent,
            [
                "Browser.getWindowForTarget",
                "Page.enable",
                "Page.getFrameTree",
                "Log.enable",
                "Page.setLifecycleEventsEnabled",
                "Runtime.enable",
                "Page.addScriptToEvaluateOnNewDocument",
                "Network.enable",
                "Target.setAutoAttach",
                "Emulation.setFocusEmulationEnabled",
                "Browser.setWindowBounds",
                "Emulation.setDeviceMetricsOverride",
                "Page.setFontFamilies",
                "Emulation.setEmulatedMedia",
                "Runtime.runIfWaitingForDebugger",
            ]
        );
    }
}
