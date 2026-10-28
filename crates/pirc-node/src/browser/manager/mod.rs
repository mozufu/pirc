//! The node's browsers: a port of `node/browser.ts`'s `BrowserManager`. One
//! Chromium per workspace (persistent profile under
//! `PIRC_BROWSER_PROFILES_DIR`), a tab group per session, the agent's
//! operations, the viewers (state, screencast, log), the user/agent mode
//! and handoff, recordings, the idle sweep and shutdown.
//!
//! Not a sandbox: the browser has the node account's network access and
//! the workspace profile's logins; [`super::hosts`] limits where it goes.
//!
//! TS ran on one thread; here the manager's state is behind one mutex
//! ([`State`], the maps of the TS class) and one per session tab
//! ([`TabState`]), never held across an await, always taken in that order.
//! Agent requests run detached ([`BrowserService::handle`]): dropping the
//! returned future is TS's abort, which only ends waits for the user
//! (`waitForAgentMode`) and the check before an operation starts; an
//! operation already running (a launch, a navigation, a recording) finishes
//! and its result is discarded. The runner aborts through
//! [`BrowserService::handle_with_abort`] instead, which still waits for the
//! operation to settle (TS's `browser_cancel` kept the request in flight
//! until then).
//!
//! The engine is reached through [`seam`] (TS's `settings.launch` test
//! hook), so the session lifecycle is unit-tested with a fake context.

mod input;
mod ops;
pub(crate) mod seam;
#[cfg(test)]
mod tests;
mod view;

use std::collections::{BTreeMap, HashMap, HashSet, VecDeque};
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock, Weak};
use std::time::Duration;

use pirc_config::Env;
use pirc_config::node::{BrowserSettings, NodeConfig};
use serde_json::{Value, json};
use tokio::sync::{oneshot, watch};
use tokio::task::AbortHandle;
use tokio::time::Instant;

use self::seam::{ChromiumLauncher, ContextRef, Launcher, PageRef};
use super::hosts::HostGuard;
use super::recording::Recording;
use super::{BoxFuture, BrowserService, BrowserTarget, Detach, FrameSink};
use crate::error::{ApiError, ApiResult};

/// Tabs (pages) one session may have open (`TABS_PER_SESSION`).
const TABS_PER_SESSION: usize = 8;
/// Log entries kept per session (`LOG_LIMIT`).
const LOG_LIMIT: usize = 150;
/// How often idle sessions are looked for.
const SWEEP_INTERVAL: Duration = Duration::from_secs(60);
/// How long closing a context may take before it is left alone.
const CONTEXT_CLOSE_TIMEOUT: Duration = Duration::from_secs(10);

/// The node's browsers ([`BrowserService`]). Nothing is launched until an
/// agent or a viewer opens a page.
pub struct BrowserManager {
    inner: Arc<Inner>,
}

impl BrowserManager {
    pub fn new(config: &NodeConfig, env: &Env) -> Self {
        Self::with_launcher(
            config.browser.clone(),
            pirc_config::env_allowlist::without_secrets(env, &[]),
            Arc::new(ChromiumLauncher),
        )
    }

    /// With another engine behind [`seam::Launcher`] (tests). `env` is
    /// Chromium's and ffmpeg's whole environment.
    pub(crate) fn with_launcher(
        settings: BrowserSettings,
        env: BTreeMap<String, String>,
        launcher: Arc<dyn Launcher>,
    ) -> Self {
        Self {
            inner: Arc::new(Inner {
                hosts: Arc::new(LazyHosts {
                    settings: settings.clone(),
                    guard: OnceLock::new(),
                }),
                settings,
                env,
                launcher,
                state: Mutex::new(State::default()),
                seq: AtomicU64::new(1),
                sweeping: AtomicBool::new(false),
                sweeper: Mutex::new(None),
            }),
        }
    }
}

impl BrowserService for BrowserManager {
    fn enabled(&self) -> bool {
        self.inner.settings.enabled && self.inner.settings.executable.is_some()
    }

    fn handle(
        &self,
        target: BrowserTarget,
        op: String,
        args: Value,
    ) -> BoxFuture<'_, ApiResult<Value>> {
        let signal = Signal::new();
        let task = tokio::spawn(super::effects::inherit(self.inner.clone().handle(
            target,
            op,
            args,
            signal.clone(),
        )));
        let abort = AbortOnDrop(signal);
        Box::pin(async move {
            let result = task.await;
            drop(abort);
            result.unwrap_or_else(|error| Err(panicked(error)))
        })
    }

    fn handle_with_abort(
        &self,
        target: BrowserTarget,
        op: String,
        args: Value,
        mut abort: watch::Receiver<bool>,
    ) -> BoxFuture<'_, ApiResult<Value>> {
        let signal = Signal::new();
        let mut task = tokio::spawn(super::effects::inherit(self.inner.clone().handle(
            target,
            op,
            args,
            signal.clone(),
        )));
        let abort_on_drop = AbortOnDrop(signal.clone());
        Box::pin(async move {
            let result = tokio::select! {
                result = &mut task => result,
                () = async { let _ = abort.wait_for(|aborted| *aborted).await; } => {
                    signal.abort();
                    task.await
                }
            };
            drop(abort_on_drop);
            result.unwrap_or_else(|error| Err(panicked(error)))
        })
    }

    fn attach(&self, session_id: &str, send: FrameSink) -> Detach {
        self.inner.attach(session_id, send)
    }

    fn input(
        &self,
        target: BrowserTarget,
        message: Value,
    ) -> BoxFuture<'_, ApiResult<Option<Value>>> {
        Box::pin(self.inner.clone().input(target, message))
    }

    fn close_session(&self, session_id: &str) -> BoxFuture<'_, ApiResult<()>> {
        Box::pin(self.inner.close_session(session_id))
    }

    fn shutdown(&self) -> BoxFuture<'_, ()> {
        let inner = self.inner.clone();
        Box::pin(async move { inner.shutdown().await })
    }
}

/// A workspace's browser profile directory name under the profiles
/// directory: its id with `[^a-zA-Z0-9_-]` as `_`.
pub fn profile_name(workspace_id: &str) -> String {
    workspace_id
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '_' || c == '-' {
                c
            } else {
                '_'
            }
        })
        .collect()
}

/// A request task that panicked (an engine bug): what TS answered for an
/// unexpected exception, 500 `browser_error` with its message.
fn panicked(error: tokio::task::JoinError) -> ApiError {
    let message = match error.try_into_panic() {
        Ok(payload) => payload
            .downcast_ref::<&str>()
            .map(|text| (*text).to_owned())
            .or_else(|| payload.downcast_ref::<String>().cloned())
            .unwrap_or_else(|| "The browser failed".to_owned()),
        Err(_) => "The browser failed".to_owned(),
    };
    ApiError::new(500, "browser_error", message)
}

/// The host guard, created on first use: a node whose agents never browse
/// builds none.
pub(crate) struct LazyHosts {
    settings: BrowserSettings,
    guard: OnceLock<Arc<HostGuard>>,
}

impl LazyHosts {
    pub(crate) fn get(&self) -> Arc<HostGuard> {
        self.guard
            .get_or_init(|| Arc::new(HostGuard::new(&self.settings)))
            .clone()
    }
}

/// TS's `AbortSignal` for one agent request.
#[derive(Clone)]
pub(crate) struct Signal(Arc<watch::Sender<bool>>);

impl Signal {
    pub(crate) fn new() -> Self {
        Self(Arc::new(watch::channel(false).0))
    }

    pub(crate) fn abort(&self) {
        self.0.send_replace(true);
    }

    pub(crate) fn aborted(&self) -> bool {
        *self.0.borrow()
    }

    /// Resolves once aborted.
    pub(crate) async fn wait(&self) {
        let mut aborted = self.0.subscribe();
        let _ = aborted.wait_for(|aborted| *aborted).await;
    }
}

/// Aborts the request when the caller stops waiting (`browser_cancel`).
struct AbortOnDrop(Signal);

impl Drop for AbortOnDrop {
    fn drop(&mut self) {
        self.0.abort();
    }
}

/// An error raised inside an operation: the agent sees an [`ApiError`] as
/// is and an engine (Playwright) error cleaned (`cleanError`, 400) inside
/// `run`, verbatim (500 `browser_error`) elsewhere, as TS's runner
/// answered non-`ApiError` exceptions.
pub(crate) enum OpError {
    Api(ApiError),
    Engine(super::engine::Error),
}

impl From<ApiError> for OpError {
    fn from(error: ApiError) -> Self {
        Self::Api(error)
    }
}

impl From<super::engine::Error> for OpError {
    fn from(error: super::engine::Error) -> Self {
        Self::Engine(error)
    }
}

impl OpError {
    pub(crate) fn into_api(self) -> ApiError {
        match self {
            Self::Api(error) => error,
            Self::Engine(error) => ApiError::new(500, "browser_error", error.message),
        }
    }
}

pub(crate) type OpResult<T> = Result<T, OpError>;

pub(crate) fn closing_error() -> ApiError {
    ApiError::conflict("The browser session is closing")
}

/// A workspace's launch: `None` while Chromium starts.
type Launch = watch::Receiver<Option<Result<ContextRef, String>>>;

/// `WorkspaceBrowser`: one context per workspace, and the sessions that use
/// or wait for it.
struct Workspace {
    seq: u64,
    launch: Launch,
    sessions: HashSet<String>,
}

/// The maps of the TS class.
#[derive(Default)]
struct State {
    closing: bool,
    workspaces: HashMap<String, Workspace>,
    tabs: HashMap<String, Arc<Tab>>,
    viewers: HashMap<String, Vec<Viewer>>,
    /// Accepted requests per session (`sessionOperations`).
    operations: HashMap<String, usize>,
    operation_waiters: HashMap<String, Vec<oneshot::Sender<()>>>,
    closing_sessions: HashSet<String>,
    /// A failed close stays fenced and queryable; absence is not proof of exit.
    closures: HashMap<String, watch::Receiver<Option<ApiResult<()>>>>,
    unconfirmed_sessions: HashSet<String>,
}

/// An attached viewer (`attach`).
struct Viewer {
    id: u64,
    sink: FrameSink,
    /// The tab whose log the viewer got in full when it attached, and that
    /// log's length: that tab's earlier `log_entry`s are not sent again.
    log_from: Option<(Weak<Tab>, u64)>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Mode {
    Agent,
    User,
}

impl Mode {
    fn as_str(self) -> &'static str {
        match self {
            Self::Agent => "agent",
            Self::User => "user",
        }
    }
}

/// The latest screencast frame.
#[derive(Clone)]
pub(crate) struct LastFrame {
    pub jpeg: Arc<Vec<u8>>,
    pub width: u32,
    pub height: u32,
}

pub(crate) struct LogEntry {
    index: u64,
    at: i64,
    actor: &'static str,
    action: String,
    url: String,
    jpeg: Option<Arc<Vec<u8>>>,
}

impl LogEntry {
    /// What viewers get (`BrowserLogEntry`, without the image).
    fn view(&self) -> Value {
        json!({ "index": self.index, "at": self.at, "actor": self.actor,
            "action": self.action, "url": self.url, "image": self.jpeg.is_some() })
    }
}

pub(crate) struct ActiveRecording {
    seq: u64,
    recording: Recording,
    /// The 30-minute cap.
    limit: Option<AbortHandle>,
}

/// A mode waiter: woken with nothing (agent mode) or an error (closing).
type Waiter = (u64, oneshot::Sender<Option<ApiError>>);

/// `Tab` of `browser.ts`: a session's pages and everything viewers see.
pub(crate) struct Tab {
    target: BrowserTarget,
    resource: Option<super::effects::Guard>,
    state: Mutex<TabState>,
    /// Agent operations run one at a time: they share the active page.
    busy: tokio::sync::Mutex<()>,
    /// Serializes screencast start/stop.
    cast: tokio::sync::Mutex<()>,
    /// The states emitted so far (numbered under the tab's lock) and how
    /// many of them went out: they go out in order (see
    /// `Inner::emit_state_with`).
    states_emitted: AtomicU64,
    states_sent: Arc<watch::Sender<u64>>,
    listeners: AtomicUsize,
    listeners_done: tokio::sync::Notify,
}

pub(crate) struct TabState {
    closed: bool,
    pages: Vec<PageRef>,
    active: Option<PageRef>,
    mode: Mode,
    handoff: Option<String>,
    waiting: usize,
    waiters: Vec<Waiter>,
    action: Option<String>,
    screencast: Option<PageRef>,
    last_frame: Option<LastFrame>,
    frame_timer: Option<AbortHandle>,
    last_sent: Option<Instant>,
    recording: Option<ActiveRecording>,
    /// A start in progress before its recording is installed (its seq):
    /// another start sees the slot taken (see `Inner::reserve_recording`).
    recording_starting: Option<u64>,
    log: VecDeque<LogEntry>,
    log_count: u64,
    last_activity: Instant,
}

impl Tab {
    fn new(target: BrowserTarget) -> Self {
        Self {
            target,
            resource: super::effects::resource(),
            state: Mutex::new(TabState {
                closed: false,
                pages: Vec::new(),
                active: None,
                mode: Mode::Agent,
                handoff: None,
                waiting: 0,
                waiters: Vec::new(),
                action: None,
                screencast: None,
                last_frame: None,
                frame_timer: None,
                last_sent: None,
                recording: None,
                recording_starting: None,
                log: VecDeque::new(),
                log_count: 0,
                last_activity: Instant::now(),
            }),
            busy: tokio::sync::Mutex::new(()),
            cast: tokio::sync::Mutex::new(()),
            states_emitted: AtomicU64::new(0),
            states_sent: Arc::new(watch::channel(0).0),
            listeners: AtomicUsize::new(0),
            listeners_done: tokio::sync::Notify::new(),
        }
    }

    fn lock(&self) -> MutexGuard<'_, TabState> {
        lock(&self.state)
    }

    fn session(&self) -> &str {
        &self.target.session_id
    }

    fn active(&self) -> Option<PageRef> {
        self.lock().active.clone()
    }

    fn closed(&self) -> bool {
        self.lock().closed
    }

    fn touch(&self) {
        self.lock().last_activity = Instant::now();
    }
}

pub(crate) fn same(a: &PageRef, b: &PageRef) -> bool {
    Arc::ptr_eq(a, b)
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}

/// Run `task` in the background when there is a runtime (always, in the
/// node; the handle aborts it).
fn spawn(task: impl Future<Output = ()> + Send + 'static) -> Option<AbortHandle> {
    tokio::runtime::Handle::try_current()
        .ok()
        .map(|runtime| runtime.spawn(task).abort_handle())
}

/// A request's hold on its session (`beginSessionOperation`): released on
/// drop.
struct Lease {
    inner: Arc<Inner>,
    session: String,
}

impl Drop for Lease {
    fn drop(&mut self) {
        let mut state = self.inner.lock();
        let remaining = state.operations.get(&self.session).copied().unwrap_or(1) - 1;
        if remaining > 0 {
            state.operations.insert(self.session.clone(), remaining);
            return;
        }
        state.operations.remove(&self.session);
        for wake in state
            .operation_waiters
            .remove(&self.session)
            .unwrap_or_default()
        {
            let _ = wake.send(());
        }
    }
}

pub(crate) struct Inner {
    settings: BrowserSettings,
    /// Chromium's and ffmpeg's environment (`withoutSecrets(process.env)`).
    env: BTreeMap<String, String>,
    hosts: Arc<LazyHosts>,
    launcher: Arc<dyn Launcher>,
    state: Mutex<State>,
    seq: AtomicU64,
    sweeping: AtomicBool,
    sweeper: Mutex<Option<AbortHandle>>,
}

impl Inner {
    fn lock(&self) -> MutexGuard<'_, State> {
        lock(&self.state)
    }

    fn next_seq(&self) -> u64 {
        self.seq.fetch_add(1, Ordering::Relaxed)
    }

    fn viewport(&self) -> (u32, u32) {
        (self.settings.viewport.width, self.settings.viewport.height)
    }

    fn hosts(&self) -> Arc<HostGuard> {
        self.hosts.get()
    }

    fn session_closing(&self, session: &str) -> bool {
        self.lock().closing_sessions.contains(session)
    }

    /// `require()`.
    fn require(&self) -> ApiResult<()> {
        if !self.settings.enabled {
            return Err(ApiError::forbidden(
                "The browser is disabled on this node (PIRC_BROWSER)",
            ));
        }
        if self.settings.executable.is_none() {
            return Err(ApiError::runner_unavailable(
                "No Chromium found on this node; set PIRC_BROWSER_EXECUTABLE",
            ));
        }
        if self.lock().closing {
            return Err(ApiError::runner_unavailable("The node is shutting down"));
        }
        Ok(())
    }

    /// `beginSessionOperation`: a lease for the full lifetime of an accepted
    /// request; a session close fences new ones and waits for these.
    fn begin_operation(self: &Arc<Self>, session: &str) -> ApiResult<Lease> {
        let mut state = self.lock();
        if state.closing {
            return Err(ApiError::runner_unavailable("The node is shutting down"));
        }
        if state.closing_sessions.contains(session) {
            return Err(closing_error());
        }
        *state.operations.entry(session.to_owned()).or_default() += 1;
        Ok(Lease {
            inner: self.clone(),
            session: session.to_owned(),
        })
    }

    /// Internal cleanup is tracked even after admission closes. It may close
    /// late popups or flush a recording; it never authorizes new user work.
    fn begin_cleanup(self: &Arc<Self>, session: &str) -> Lease {
        *self
            .lock()
            .operations
            .entry(session.to_owned())
            .or_default() += 1;
        Lease {
            inner: self.clone(),
            session: session.to_owned(),
        }
    }

    fn retire_popup(self: &Arc<Self>, tab: &Arc<Tab>, popup: PageRef) {
        let cleanup = self.begin_cleanup(tab.session());
        let inner = self.clone();
        let session = tab.session().to_owned();
        spawn(async move {
            let _cleanup = cleanup;
            let result = tokio::time::timeout(CONTEXT_CLOSE_TIMEOUT, popup.close()).await;
            if !matches!(result, Ok(Ok(()))) || !popup.is_closed() {
                inner.lock().unconfirmed_sessions.insert(session);
            }
        });
    }

    async fn wait_for_operations(&self, session: &str) {
        let wait = {
            let mut state = self.lock();
            if state.operations.get(session).copied().unwrap_or(0) == 0 {
                return;
            }
            let (wake, wait) = oneshot::channel();
            state
                .operation_waiters
                .entry(session.to_owned())
                .or_default()
                .push(wake);
            wait
        };
        let _ = wait.await;
    }

    // ---- lifecycle ----------------------------------------------------------

    /// The synchronous part of `context()`: the workspace's launch, started
    /// now if there is none (profile `<profiles>/<id with [^a-zA-Z0-9_-] as
    /// _>`, created 0700). `reserve` adds a session to the workspace in the
    /// same step (`tab()`'s reservation before it awaits the launch).
    fn workspace_launch(
        self: &Arc<Self>,
        id: &str,
        reserve: Option<&str>,
    ) -> OpResult<(u64, Launch)> {
        let mut state = self.lock();
        if !state.workspaces.contains_key(id) {
            let profile = self.settings.profiles_dir.join(profile_name(id));
            create_private_dir(&profile)?;
            let seq = self.next_seq();
            let (done, launch) = watch::channel(None);
            state.workspaces.insert(
                id.to_owned(),
                Workspace {
                    seq,
                    launch,
                    sessions: HashSet::new(),
                },
            );
            spawn(self.clone().launch(id.to_owned(), seq, profile, done));
        }
        let workspace = state.workspaces.get_mut(id).expect("inserted above");
        if let Some(session) = reserve {
            workspace.sessions.insert(session.to_owned());
        }
        Ok((workspace.seq, workspace.launch.clone()))
    }

    async fn launch(
        self: Arc<Self>,
        id: String,
        seq: u64,
        profile: std::path::PathBuf,
        done: watch::Sender<Option<Result<ContextRef, String>>>,
    ) {
        let Some(executable) = self.settings.executable.clone() else {
            return;
        };
        let launching = self.launcher.launch(
            &executable,
            &profile,
            self.viewport(),
            self.env.clone(),
            self.hosts.clone(),
        );
        // A panicking engine fails the launch instead of leaving it pending.
        let result = tokio::spawn(launching)
            .await
            .unwrap_or_else(|error| Err(panicked(error).message));
        match result {
            Ok(context) => {
                let weak = Arc::downgrade(&self);
                let watched = context.clone();
                let id = id.clone();
                spawn(async move {
                    watched.closed().await;
                    if let Some(inner) = weak.upgrade() {
                        inner.context_closed(&id, seq);
                    }
                });
                done.send_replace(Some(Ok(context)));
            }
            Err(reason) => {
                {
                    let mut state = self.lock();
                    if state.workspaces.get(&id).is_some_and(|w| w.seq == seq) {
                        state.workspaces.remove(&id);
                    }
                }
                done.send_replace(Some(Err(reason)));
            }
        }
    }

    /// The context closed (Chromium exited, or we closed it): forget it if
    /// it is still the workspace's, and drop the workspace's tabs.
    fn context_closed(self: &Arc<Self>, id: &str, seq: u64) {
        let tabs: Vec<Arc<Tab>> = {
            let mut state = self.lock();
            if !state.workspaces.get(id).is_some_and(|w| w.seq == seq) {
                return;
            }
            state.workspaces.remove(id);
            state
                .tabs
                .values()
                .filter(|tab| tab.target.workspace_id == id)
                .cloned()
                .collect()
        };
        for tab in tabs {
            self.drop_tab(&tab);
        }
    }

    /// `context(workspaceId)`: the workspace's context, launched if needed.
    async fn context(self: &Arc<Self>, id: &str) -> OpResult<ContextRef> {
        let (_, launch) = self.workspace_launch(id, None)?;
        Ok(wait_launch(launch).await.map_err(could_not_start)?)
    }

    /// `tab(target, create)`: the session's tab; with `create`, launched and
    /// given a page if needed.
    async fn tab(
        self: &Arc<Self>,
        target: &BrowserTarget,
        create: bool,
    ) -> OpResult<Option<Arc<Tab>>> {
        let existing = self.lock().tabs.get(&target.session_id).cloned();
        if let Some(existing) = existing
            && !existing.closed()
        {
            if create && existing.active().is_none() {
                self.new_page(&existing).await?;
            }
            return Ok(Some(existing));
        }
        if !create {
            return Ok(None);
        }
        self.require()?;
        // Reserve the session before awaiting the shared launch: closing
        // another session of the workspace must not dispose a context this
        // request still waits for.
        let (seq, launch) =
            self.workspace_launch(&target.workspace_id, Some(&target.session_id))?;
        let mut created = None;
        match self.create_tab(target, launch, &mut created).await {
            Ok(tab) => Ok(Some(tab)),
            Err(error) => {
                // A failed initial page must not leave an empty tab.
                if let Some(tab) = created
                    && self.is_current(&tab)
                    && tab.lock().pages.is_empty()
                {
                    self.drop_tab(&tab);
                }
                let unused = {
                    let mut state = self.lock();
                    let mut unused = None;
                    if !state.tabs.contains_key(&target.session_id)
                        && let Some(workspace) = state.workspaces.get_mut(&target.workspace_id)
                        && workspace.seq == seq
                    {
                        workspace.sessions.remove(&target.session_id);
                        if workspace.sessions.is_empty() {
                            unused = state.workspaces.remove(&target.workspace_id);
                        }
                    }
                    unused
                };
                if let Some(workspace) = unused
                    && close_context(workspace.launch).await.is_err()
                {
                    self.lock()
                        .unconfirmed_sessions
                        .insert(target.session_id.clone());
                }
                Err(error)
            }
        }
    }

    async fn create_tab(
        self: &Arc<Self>,
        target: &BrowserTarget,
        launch: Launch,
        created: &mut Option<Arc<Tab>>,
    ) -> OpResult<Arc<Tab>> {
        let context = wait_launch(launch).await.map_err(could_not_start)?;
        super::effects::check()?;
        let (tab, owned) = {
            let mut state = self.lock();
            // closeSession fences work accepted earlier as well as later
            // requests: a pending launch installs no tab after it started.
            if state.closing || state.closing_sessions.contains(&target.session_id) {
                return Err(closing_error().into());
            }
            if let Some(again) = state.tabs.get(&target.session_id)
                && !again.closed()
            {
                return Ok(again.clone());
            }
            let tab = Arc::new(Tab::new(target.clone()));
            state.tabs.insert(target.session_id.clone(), tab.clone());
            let owned: Vec<PageRef> = state
                .tabs
                .values()
                .flat_map(|tab| tab.lock().pages.clone())
                .collect();
            (tab, owned)
        };
        *created = Some(tab.clone());
        self.start_sweeper();
        self.watch_resource(&tab);
        // A fresh persistent context opens with one blank page nobody owns.
        let spare = context
            .pages()
            .into_iter()
            .find(|page| !owned.iter().any(|o| same(o, page)) && page.url() == "about:blank");
        match spare {
            Some(page) => self.adopt(&tab, page)?,
            None => {
                self.new_page(&tab).await?;
            }
        }
        Ok(tab)
    }

    fn is_current(&self, tab: &Arc<Tab>) -> bool {
        self.lock()
            .tabs
            .get(tab.session())
            .is_some_and(|current| Arc::ptr_eq(current, tab))
    }

    /// `newPage(tab)`.
    async fn new_page(self: &Arc<Self>, tab: &Arc<Tab>) -> OpResult<PageRef> {
        super::effects::check()?;
        if tab.closed() || self.session_closing(tab.session()) {
            return Err(closing_error().into());
        }
        if tab.lock().pages.len() >= TABS_PER_SESSION {
            return Err(
                ApiError::conflict(format!("At most {TABS_PER_SESSION} tabs per session")).into(),
            );
        }
        let context = self.context(&tab.target.workspace_id).await?;
        let page = context.new_page().await?;
        self.adopt(tab, page.clone())?;
        Ok(page)
    }

    /// Retire only this session's resources when its original environment is
    /// no longer authorized. Effect checks also run at each CDP write; this
    /// observer catches quiet resources with no incoming frames or commands.
    fn watch_resource(self: &Arc<Self>, tab: &Arc<Tab>) {
        let Some(guard) = tab.resource.clone() else {
            return;
        };
        let inner = Arc::downgrade(self);
        let tab = Arc::downgrade(tab);
        spawn(async move {
            loop {
                tokio::time::sleep(Duration::from_millis(250)).await;
                let (Some(inner), Some(tab)) = (inner.upgrade(), tab.upgrade()) else {
                    return;
                };
                if tab.closed() {
                    return;
                }
                if guard.run(|| ()).is_err() {
                    // Cleanup must remain possible after the resource grant is
                    // gone. No foreground/resource scope is inherited here.
                    let _ = inner.close_session(tab.session()).await;
                    return;
                }
            }
        });
    }

    /// `adopt(tab, page)`: admission and registration share the resource gate.
    fn adopt(self: &Arc<Self>, tab: &Arc<Tab>, page: PageRef) -> ApiResult<()> {
        let adopt = || {
            let state = self.lock();
            let mut st = tab.lock();
            if state.closing || state.closing_sessions.contains(tab.session()) || st.closed {
                return Err(closing_error());
            }
            st.pages.push(page.clone());
            st.active = Some(page.clone());
            tab.listeners.fetch_add(1, Ordering::AcqRel);
            Ok(())
        };
        let events = page.subscribe();
        let result = match &tab.resource {
            Some(guard) => guard.run(adopt).and_then(|r| r),
            None => adopt(),
        };
        if let Err(error) = result {
            self.retire_popup(tab, page);
            return Err(error);
        }
        let overlay = page.clone();
        spawn(super::effects::background(
            tab.resource.clone(),
            async move {
                if super::effects::check().is_ok() {
                    let _ = overlay.show_actions().await;
                }
            },
        ));
        // Event cleanup remains unscoped; new page adoption is guarded above.
        spawn(listen(Arc::downgrade(self), tab.clone(), page, events));
        self.sync_screencast(tab);
        self.emit_state(tab);
        Ok(())
    }

    fn on_popup(self: &Arc<Self>, tab: &Arc<Tab>, popup: PageRef) {
        let closing = self.session_closing(tab.session());
        {
            let st = tab.lock();
            if st.pages.iter().any(|p| same(p, &popup)) {
                return;
            }
            if closing || st.closed || st.pages.len() >= TABS_PER_SESSION {
                drop(st);
                self.retire_popup(tab, popup);
                return;
            }
        }
        let url = popup.url();
        if self.adopt(tab, popup).is_ok() {
            self.log(tab, "agent", &format!("Popup opened: {url}"), None);
        }
    }

    fn on_page_closed(self: &Arc<Self>, tab: &Arc<Tab>, page: &PageRef) {
        {
            let mut st = tab.lock();
            st.pages.retain(|p| !same(p, page));
            if st.active.as_ref().is_some_and(|active| same(active, page)) {
                st.active = st.pages.last().cloned();
            }
        }
        self.sync_screencast(tab);
        self.emit_state(tab);
    }

    /// `dropTab(tab)`: forget the tab (its pages are closed by the caller,
    /// or already gone); viewers stay registered.
    fn drop_tab(self: &Arc<Self>, tab: &Arc<Tab>) {
        let (stop, empty_seq) = {
            let mut st = tab.lock();
            if st.closed {
                return;
            }
            st.closed = true;
            st.pages.clear();
            st.active = None;
            if let Some(timer) = st.frame_timer.take() {
                timer.abort();
            }
            st.mode = Mode::Agent;
            self.wake_waiters(tab, &mut st, None);
            // Numbered after the woken waiters' states: it goes out last.
            let empty_seq = tab.states_emitted.fetch_add(1, Ordering::Relaxed);
            (st.recording.take(), empty_seq)
        };
        if let Some(recording) = stop {
            // finish_recording starts an independent cleanup observer now.
            drop(self.finish_recording(tab, recording));
        }
        {
            let mut state = self.lock();
            if state
                .tabs
                .get(tab.session())
                .is_some_and(|current| Arc::ptr_eq(current, tab))
            {
                state.tabs.remove(tab.session());
            }
            if let Some(workspace) = state.workspaces.get_mut(&tab.target.workspace_id) {
                workspace.sessions.remove(tab.session());
            }
        }
        self.emit_dropped(tab, empty_seq);
    }

    /// `closeSession(sessionId)`: fence new requests, fail the waits for the
    /// user, drain accepted requests (pending launches included), then
    /// close the tab and, when no session uses it any more, the context.
    /// Concurrent calls share one closing.
    fn close_session(
        self: &Arc<Self>,
        session: &str,
    ) -> impl Future<Output = ApiResult<()>> + Send + 'static {
        let mut done = {
            let mut state = self.lock();
            match state.closures.get(session) {
                Some(done) => done.clone(),
                None => {
                    state.closing_sessions.insert(session.to_owned());
                    // Waking the waits as successful would let a queued
                    // action start after close was requested.
                    if let Some(tab) = state.tabs.get(session) {
                        let mut st = tab.lock();
                        self.wake_waiters(tab, &mut st, Some(closing_error()));
                    }
                    let (finished, done) = watch::channel(None);
                    state.closures.insert(session.to_owned(), done.clone());
                    let inner = self.clone();
                    let session = session.to_owned();
                    spawn(async move {
                        let result = inner.closing(&session).await;
                        if result.is_ok() {
                            let mut state = inner.lock();
                            state.closures.remove(&session);
                            state.closing_sessions.remove(&session);
                        }
                        finished.send_replace(Some(result));
                    });
                    done
                }
            }
        };
        async move {
            tokio::time::timeout(Duration::from_secs(30), async {
                done.wait_for(Option::is_some)
                    .await
                    .map_err(|_| super::journal::unresolved())?
                    .clone()
                    .unwrap_or_else(|| Err(super::journal::unresolved()))
            })
            .await
            .map_err(|_| super::journal::unresolved())?
        }
    }

    async fn closing(self: &Arc<Self>, session: &str) -> ApiResult<()> {
        self.wait_for_operations(session).await;
        let (tab, workspace_ids) = {
            let state = self.lock();
            let tab = state.tabs.get(session).cloned();
            let mut ids: Vec<String> = tab
                .iter()
                .map(|tab| tab.target.workspace_id.clone())
                .collect();
            for (id, workspace) in &state.workspaces {
                if workspace.sessions.contains(session) && !ids.contains(id) {
                    ids.push(id.clone());
                }
            }
            (tab, ids)
        };
        let mut confirmed = !self.lock().unconfirmed_sessions.contains(session);
        let pages = tab
            .as_ref()
            .map(|tab| tab.lock().pages.clone())
            .unwrap_or_default();
        if let Some(tab) = &tab {
            if let Some(stopping) = self.stop_recording(tab) {
                // Encoding failure is distinct from an unconfirmed process exit.
                // The owned recorder observer records the latter in the manager.
                let _ = stopping.await;
            }
            self.drop_tab(tab);
        }
        let results = futures_util::future::join_all(pages.iter().map(|page| async move {
            let result = tokio::time::timeout(CONTEXT_CLOSE_TIMEOUT, page.close()).await;
            matches!(result, Ok(Ok(()))) && page.is_closed()
        }))
        .await;
        confirmed &= results.into_iter().all(|closed| closed);
        if let Some(tab) = &tab {
            // A Page close event follows its earlier popup events. Drain the
            // listeners before checking cleanup so those popups cannot be lost.
            confirmed &= tokio::time::timeout(CONTEXT_CLOSE_TIMEOUT, async {
                while tab.listeners.load(Ordering::Acquire) > 0 {
                    tab.listeners_done.notified().await;
                }
            })
            .await
            .is_ok();
        }
        confirmed &= tokio::time::timeout(CONTEXT_CLOSE_TIMEOUT, self.wait_for_operations(session))
            .await
            .is_ok();
        confirmed &= !self.lock().unconfirmed_sessions.contains(session);
        // The session may only have reserved a workspace while its launch
        // was pending: remove that too, then close an unused context.
        for id in workspace_ids {
            let unused = {
                let mut state = self.lock();
                let Some(workspace) = state.workspaces.get_mut(&id) else {
                    continue;
                };
                workspace.sessions.remove(session);
                if !workspace.sessions.is_empty() {
                    continue;
                }
                state.workspaces.remove(&id)
            };
            if let Some(workspace) = unused {
                confirmed &= close_context(workspace.launch).await.is_ok();
            }
        }
        if confirmed {
            Ok(())
        } else {
            Err(super::journal::unresolved())
        }
    }

    fn start_sweeper(self: &Arc<Self>) {
        if self.sweeping.swap(true, Ordering::AcqRel) {
            return;
        }
        let weak = Arc::downgrade(self);
        let handle = spawn(async move {
            let mut ticks =
                tokio::time::interval_at(Instant::now() + SWEEP_INTERVAL, SWEEP_INTERVAL);
            loop {
                ticks.tick().await;
                let Some(inner) = weak.upgrade() else { return };
                inner.reap_idle();
            }
        });
        *lock(&self.sweeper) = handle;
    }

    /// `reapIdle()`: close sessions idle for `idle_ms`, unless recording,
    /// in user mode or watched.
    fn reap_idle(self: &Arc<Self>) {
        let Some(cutoff) = Instant::now().checked_sub(Duration::from_millis(self.settings.idle_ms))
        else {
            return;
        };
        let idle: Vec<String> = {
            let state = self.lock();
            state
                .tabs
                .values()
                .filter(|tab| {
                    let st = tab.lock();
                    st.last_activity < cutoff
                        && st.recording.is_none()
                        && st.mode == Mode::Agent
                        && !state
                            .viewers
                            .get(tab.session())
                            .is_some_and(|v| !v.is_empty())
                })
                .map(|tab| tab.session().to_owned())
                .collect()
        };
        for session in idle {
            let closing = self.close_session(&session);
            spawn(async move {
                let _ = closing.await;
            });
        }
    }

    async fn shutdown(self: &Arc<Self>) {
        let sessions: Vec<String> = {
            let mut state = self.lock();
            state.closing = true;
            let mut sessions: Vec<String> = state.tabs.keys().cloned().collect();
            sessions.extend(state.operations.keys().cloned());
            for workspace in state.workspaces.values() {
                sessions.extend(workspace.sessions.iter().cloned());
            }
            sessions.sort();
            sessions.dedup();
            sessions
        };
        if let Some(sweeper) = lock(&self.sweeper).take() {
            sweeper.abort();
        }
        futures_util::future::join_all(sessions.iter().map(|session| self.close_session(session)))
            .await;
        let launches: Vec<Launch> = self
            .lock()
            .workspaces
            .drain()
            .map(|(_, workspace)| workspace.launch)
            .collect();
        futures_util::future::join_all(launches.into_iter().map(close_context)).await;
    }
}

/// A page's events for the tab that adopted it (`page.on(...)` in
/// `adopt`). The listener outlives the tab, as TS's did.
async fn listen(
    inner: Weak<Inner>,
    tab: Arc<Tab>,
    page: PageRef,
    mut events: futures_util::stream::BoxStream<'static, seam::PageEvent>,
) {
    use futures_util::{FutureExt as _, StreamExt as _};
    struct Listening(Arc<Tab>);
    impl Drop for Listening {
        fn drop(&mut self) {
            if self.0.listeners.fetch_sub(1, Ordering::AcqRel) == 1 {
                self.0.listeners_done.notify_one();
            }
        }
    }
    let _listening = Listening(tab.clone());
    // If already closed, first consume any queued popup events that precede
    // Closed. Only an empty closed stream may synthesize the final event.
    loop {
        let event = if page.is_closed() {
            events
                .next()
                .now_or_never()
                .flatten()
                .unwrap_or(seam::PageEvent::Closed)
        } else {
            // A page whose events end is gone.
            events.next().await.unwrap_or(seam::PageEvent::Closed)
        };
        let Some(inner) = inner.upgrade() else { return };
        match event {
            seam::PageEvent::Popup(popup) => inner.on_popup(&tab, popup),
            seam::PageEvent::MainFrameNavigated | seam::PageEvent::Load => inner.emit_state(&tab),
            seam::PageEvent::Closed => {
                inner.on_page_closed(&tab, &page);
                return;
            }
        }
    }
}

/// The context of a launch, once it has started (or why it did not).
async fn wait_launch(mut launch: Launch) -> Result<ContextRef, String> {
    match launch.wait_for(Option::is_some).await {
        Ok(result) => result.clone().unwrap_or_else(|| Err("not started".into())),
        Err(_) => Err("The browser launch was abandoned".into()),
    }
}

/// 503 "Could not start the browser: <first line of the reason>".
fn could_not_start(reason: String) -> ApiError {
    ApiError::runner_unavailable(format!(
        "Could not start the browser: {}",
        reason.split('\n').next().unwrap_or_default()
    ))
}

/// A close request is not a close event. Retain uncertainty on timeout.
async fn close_context(launch: Launch) -> ApiResult<()> {
    tokio::time::timeout(CONTEXT_CLOSE_TIMEOUT, async {
        if let Ok(context) = wait_launch(launch).await {
            context.close().await;
            context.closed().await;
        }
        Ok(())
    })
    .await
    .map_err(|_| super::journal::unresolved())?
}

/// `mkdirSync(dir, {recursive: true, mode: 0o700})`. A failure answers 500
/// `browser_error` with the I/O error (Rust's text, where TS's runner
/// forwarded Node's).
fn create_private_dir(dir: &Path) -> Result<(), ApiError> {
    use std::os::unix::fs::DirBuilderExt as _;
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(dir)
        .map_err(|error| ApiError::new(500, "browser_error", error.to_string()))
}
