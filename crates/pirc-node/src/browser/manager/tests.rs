//! The session lifecycle with a fake context behind [`Launcher`]
//! (`browser.test.ts`'s "BrowserManager session lifecycle"), and the rest
//! of the manager's bookkeeping that needs no Chromium.

use std::collections::{BTreeMap, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use futures_util::StreamExt as _;
use futures_util::stream::BoxStream;
use pirc_config::node::{BrowserSettings, Viewport};
use serde_json::{Value, json};
use tokio::sync::{mpsc, oneshot, watch};

use super::seam::{
    ContextApi, ContextRef, FrameApi, FrameSink as CastSink, Launcher, LocatorApi, PageApi,
    PageEvent, PageRef, Selector,
};
use super::{ActiveRecording, BrowserManager, LazyHosts};
use crate::browser::engine::screencast::ScreencastFrame;
use crate::browser::engine::screencast::ScreencastOptions;
use crate::browser::engine::screenshot::ScreenshotOptions;
use crate::browser::engine::{self, LoadState, MouseButton};
use crate::browser::recording::test_support::fake_ffmpeg;
use crate::browser::recording::{RECORD_MAX, Recording};
use crate::browser::{BoxFuture, BrowserService, BrowserTarget, FrameSink};
use crate::error::ApiError;

fn fake_error<T>() -> engine::Result<T> {
    Err(engine::Error::new("fake page"))
}

#[derive(Default)]
struct FakePage {
    url: Mutex<String>,
    subscribers: Mutex<Vec<mpsc::UnboundedSender<PageEvent>>>,
    closed: AtomicBool,
    fail_close: AtomicBool,
    close_delay: Mutex<Duration>,
    close_popup: Mutex<Option<Arc<FakePage>>>,
    shows_actions: AtomicBool,
    /// The screencast's frame sink while it runs.
    cast: Mutex<Option<CastSink>>,
    /// How long each `title()` takes, in call order (then at once).
    title_delays: Mutex<VecDeque<Duration>>,
    /// How long `aria_snapshot` takes.
    snapshot_delay: Mutex<Duration>,
}

impl FakePage {
    fn new(url: &str) -> Arc<Self> {
        Arc::new(Self {
            url: Mutex::new(url.to_owned()),
            ..Self::default()
        })
    }

    fn emit(&self, event: impl Fn() -> PageEvent) {
        for subscriber in self.subscribers.lock().unwrap().iter() {
            let _ = subscriber.send(event());
        }
    }

    fn set_url(&self, url: &str) {
        url.clone_into(&mut self.url.lock().unwrap());
    }

    /// A screencast frame from Chromium.
    fn frame(&self, jpeg: &[u8]) {
        let sink = self.cast.lock().unwrap().clone().expect("a screencast");
        sink(ScreencastFrame {
            jpeg: Arc::new(jpeg.to_vec()),
            width: 800,
            height: 600,
        });
    }

    fn casting(&self) -> bool {
        self.cast.lock().unwrap().is_some()
    }
}

impl PageApi for FakePage {
    fn subscribe(&self) -> BoxStream<'static, PageEvent> {
        let (send, receive) = mpsc::unbounded_channel();
        self.subscribers.lock().unwrap().push(send);
        futures_util::stream::unfold(receive, |mut receive| async move {
            receive.recv().await.map(|event| (event, receive))
        })
        .boxed()
    }
    fn url(&self) -> String {
        self.url.lock().unwrap().clone()
    }
    fn title(&self) -> BoxFuture<'_, engine::Result<String>> {
        let delay = self.title_delays.lock().unwrap().pop_front();
        Box::pin(async move {
            if let Some(delay) = delay {
                tokio::time::sleep(delay).await;
            }
            Ok("Fake".to_owned())
        })
    }
    fn content(&self) -> BoxFuture<'_, engine::Result<String>> {
        Box::pin(async { fake_error() })
    }
    fn frames(&self) -> Vec<Arc<dyn FrameApi>> {
        Vec::new()
    }
    fn goto<'a>(
        &'a self,
        _: &'a str,
        _: LoadState,
        _: Duration,
    ) -> BoxFuture<'a, engine::Result<Option<u16>>> {
        Box::pin(async { fake_error() })
    }
    fn go_back(&self, _: LoadState, _: Duration) -> BoxFuture<'_, engine::Result<()>> {
        Box::pin(async { Ok(()) })
    }
    fn go_forward(&self, _: Duration) -> BoxFuture<'_, engine::Result<()>> {
        Box::pin(async { Ok(()) })
    }
    fn reload(&self, _: Duration) -> BoxFuture<'_, engine::Result<()>> {
        Box::pin(async { Ok(()) })
    }
    fn wait_for_load_state(&self, _: LoadState, _: Duration) -> BoxFuture<'_, engine::Result<()>> {
        Box::pin(async { Ok(()) })
    }
    fn evaluate<'a>(&'a self, _: &'a str) -> BoxFuture<'a, engine::Result<Value>> {
        Box::pin(async { fake_error() })
    }
    fn aria_snapshot(&self, _: Duration) -> BoxFuture<'_, engine::Result<String>> {
        let delay = *self.snapshot_delay.lock().unwrap();
        Box::pin(async move {
            tokio::time::sleep(delay).await;
            Ok("- generic [ref=e1]".to_owned())
        })
    }
    fn locator(self: Arc<Self>, _: Selector) -> Box<dyn LocatorApi> {
        unimplemented!("no locators on the fake page")
    }
    fn press<'a>(&'a self, _: &'a str) -> BoxFuture<'a, engine::Result<()>> {
        Box::pin(async { Ok(()) })
    }
    fn insert_text<'a>(&'a self, _: &'a str) -> BoxFuture<'a, engine::Result<()>> {
        Box::pin(async { Ok(()) })
    }
    fn mouse_move(&self, _: f64, _: f64) -> BoxFuture<'_, engine::Result<()>> {
        Box::pin(async { Ok(()) })
    }
    fn mouse_down(&self, _: MouseButton, _: u32) -> BoxFuture<'_, engine::Result<()>> {
        Box::pin(async { Ok(()) })
    }
    fn mouse_up(&self, _: MouseButton, _: u32) -> BoxFuture<'_, engine::Result<()>> {
        Box::pin(async { Ok(()) })
    }
    fn mouse_wheel(&self, _: f64, _: f64) -> BoxFuture<'_, engine::Result<()>> {
        Box::pin(async { Ok(()) })
    }
    fn screenshot(&self, _: ScreenshotOptions) -> BoxFuture<'_, engine::Result<Vec<u8>>> {
        Box::pin(async { Ok(vec![0xff, 0xd8, 0xff]) })
    }
    fn start_screencast(
        &self,
        _: ScreencastOptions,
        sink: CastSink,
    ) -> BoxFuture<'_, engine::Result<()>> {
        *self.cast.lock().unwrap() = Some(sink);
        Box::pin(async { Ok(()) })
    }
    fn stop_screencast(&self) -> BoxFuture<'_, engine::Result<()>> {
        *self.cast.lock().unwrap() = None;
        Box::pin(async { Ok(()) })
    }
    fn show_actions(&self) -> BoxFuture<'_, engine::Result<()>> {
        self.shows_actions.store(true, Ordering::SeqCst);
        Box::pin(async { Ok(()) })
    }
    fn bring_to_front(&self) -> BoxFuture<'_, engine::Result<()>> {
        Box::pin(async { Ok(()) })
    }
    fn close(&self) -> BoxFuture<'_, engine::Result<()>> {
        Box::pin(async {
            let delay = *self.close_delay.lock().unwrap();
            tokio::time::sleep(delay).await;
            if self.fail_close.load(Ordering::SeqCst) {
                return fake_error();
            }
            let popup = self.close_popup.lock().unwrap().take();
            if let Some(popup) = popup {
                self.emit(|| PageEvent::Popup(popup.clone()));
            }
            if !self.closed.swap(true, Ordering::SeqCst) {
                self.emit(|| PageEvent::Closed);
            }
            Ok(())
        })
    }
    fn is_closed(&self) -> bool {
        self.closed.load(Ordering::SeqCst)
    }
}

/// `fakeContext()`: counts `newPage` and `close`.
#[derive(Default)]
struct FakeContext {
    initial: Vec<PageRef>,
    created: Mutex<Vec<Arc<FakePage>>>,
    new_page_calls: AtomicUsize,
    close_calls: AtomicUsize,
    fail_close: AtomicBool,
    fail_page: AtomicBool,
    gone: Mutex<Option<watch::Sender<bool>>>,
    /// The next `new_page` waits for this.
    page_gate: Mutex<Option<oneshot::Receiver<()>>>,
}

impl FakeContext {
    fn new() -> Arc<Self> {
        Arc::new(Self {
            gone: Mutex::new(Some(watch::channel(false).0)),
            ..Self::default()
        })
    }

    fn stats(&self) -> (usize, usize) {
        (
            self.new_page_calls.load(Ordering::SeqCst),
            self.close_calls.load(Ordering::SeqCst),
        )
    }

    fn page(&self, index: usize) -> Arc<FakePage> {
        self.created.lock().unwrap()[index].clone()
    }

    /// Chromium went away by itself.
    fn crash(&self) {
        if let Some(gone) = self.gone.lock().unwrap().as_ref() {
            gone.send_replace(true);
        }
    }
}

impl ContextApi for FakeContext {
    fn pages(&self) -> Vec<PageRef> {
        self.initial.clone()
    }
    fn new_page(&self) -> BoxFuture<'_, engine::Result<PageRef>> {
        let gate = self.page_gate.lock().unwrap().take();
        Box::pin(async {
            if let Some(gate) = gate {
                let _ = gate.await;
            }
            self.new_page_calls.fetch_add(1, Ordering::SeqCst);
            if self.fail_page.load(Ordering::SeqCst) {
                return fake_error();
            }
            let page = FakePage::new("about:blank");
            self.created.lock().unwrap().push(page.clone());
            Ok(page as PageRef)
        })
    }
    fn closed(&self) -> BoxFuture<'_, ()> {
        let mut gone = self.gone.lock().unwrap().as_ref().unwrap().subscribe();
        Box::pin(async move {
            let _ = gone.wait_for(|gone| *gone).await;
        })
    }
    fn close(&self) -> BoxFuture<'_, ()> {
        Box::pin(async {
            self.close_calls.fetch_add(1, Ordering::SeqCst);
            if !self.fail_close.load(Ordering::SeqCst) {
                self.crash();
            }
        })
    }
}

type LaunchFn = dyn Fn() -> BoxFuture<'static, Result<ContextRef, String>> + Send + Sync;

/// `settings.launch`.
struct FakeLauncher {
    launch: Box<LaunchFn>,
    calls: AtomicUsize,
    profiles: Mutex<Vec<PathBuf>>,
}

impl Launcher for FakeLauncher {
    fn launch(
        &self,
        _: &Path,
        profile_dir: &Path,
        _: (u32, u32),
        _: BTreeMap<String, String>,
        _: Arc<LazyHosts>,
    ) -> BoxFuture<'static, Result<ContextRef, String>> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        self.profiles.lock().unwrap().push(profile_dir.to_owned());
        (self.launch)()
    }
}

fn settings(profiles: &Path) -> BrowserSettings {
    BrowserSettings {
        enabled: true,
        executable: Some("/fake/chromium".into()),
        ffmpeg: "ffmpeg".into(),
        profiles_dir: profiles.to_owned(),
        idle_ms: 60_000,
        viewport: Viewport {
            width: 800,
            height: 600,
        },
        allow_private_hosts: Vec::new(),
        gateway_host: String::new(),
        blocked_hosts: Vec::new(),
    }
}

struct Fixture {
    manager: Arc<BrowserManager>,
    launcher: Arc<FakeLauncher>,
    _profiles: tempfile::TempDir,
}

fn manager_with(
    settings_of: impl FnOnce(&Path) -> BrowserSettings,
    launch: Box<LaunchFn>,
) -> Fixture {
    let profiles = tempfile::tempdir().unwrap();
    let launcher = Arc::new(FakeLauncher {
        launch,
        calls: AtomicUsize::new(0),
        profiles: Mutex::new(Vec::new()),
    });
    let manager = Arc::new(BrowserManager::with_launcher(
        settings_of(profiles.path()),
        BTreeMap::new(),
        launcher.clone(),
    ));
    Fixture {
        manager,
        launcher,
        _profiles: profiles,
    }
}

/// A manager whose launches all return `context` at once.
fn ready(context: &Arc<FakeContext>) -> Fixture {
    let context = context.clone();
    manager_with(
        settings,
        Box::new(move || {
            let context = context.clone() as ContextRef;
            Box::pin(async move { Ok(context) })
        }),
    )
}

/// A manager whose (single) launch waits for the returned sender.
fn gated_manager() -> (Fixture, oneshot::Sender<ContextRef>, oneshot::Receiver<()>) {
    let (open, gate) = oneshot::channel::<ContextRef>();
    let (started, launch_started) = oneshot::channel::<()>();
    let gate = Mutex::new(Some((gate, started)));
    let fixture = manager_with(
        settings,
        Box::new(move || {
            let (gate, started) = gate.lock().unwrap().take().expect("one launch");
            let _ = started.send(());
            Box::pin(async move { gate.await.map_err(|_| "gate dropped".to_owned()) })
        }),
    );
    (fixture, open, launch_started)
}

fn target(session: &str, workspace: &str) -> BrowserTarget {
    BrowserTarget {
        session_id: session.into(),
        workspace_id: workspace.into(),
        root: std::env::temp_dir(),
    }
}

async fn settle() {
    for _ in 0..20 {
        tokio::task::yield_now().await;
    }
}

fn spawn_handle(
    manager: &Arc<BrowserManager>,
    target: &BrowserTarget,
    op: &str,
    args: Value,
) -> tokio::task::JoinHandle<Result<Value, ApiError>> {
    let manager = manager.clone();
    let target = target.clone();
    let op = op.to_owned();
    tokio::spawn(async move { manager.handle(target, op, args).await })
}

fn code(result: Result<Value, ApiError>) -> String {
    result.unwrap_err().code.into_owned()
}

#[tokio::test]
async fn drains_a_pending_launch_before_closing_and_never_creates_a_late_tab() {
    let (fixture, open, launch_started) = gated_manager();
    let manager = &fixture.manager;
    let target = target("pending-close", "launch-drain");
    let request = spawn_handle(
        manager,
        &target,
        "navigate",
        json!({ "url": "https://example.com" }),
    );
    launch_started.await.unwrap();

    let closing = {
        let manager = manager.clone();
        tokio::spawn(async move { manager.close_session("pending-close").await })
    };
    settle().await;
    assert!(!closing.is_finished());

    let fake = FakeContext::new();
    let _ = open.send(fake.clone());
    closing.await.unwrap().unwrap();
    let error = request.await.unwrap().unwrap_err();
    assert_eq!((error.status, &*error.code), (409, "conflict"));
    assert_eq!(error.message, "The browser session is closing");
    assert_eq!(fake.stats(), (0, 1));
    let status = manager
        .handle(target, "status".into(), json!({}))
        .await
        .unwrap();
    assert_eq!(status["active"], false);
    manager.shutdown().await;
}

/// `controller.abort()` while the launch is pending: dropping the request
/// changes nothing (TS's abort did not interrupt the launch either).
#[tokio::test]
async fn an_abandoned_request_still_drains_with_its_launch() {
    let (fixture, open, launch_started) = gated_manager();
    let manager = &fixture.manager;
    let target = target("pending-close", "launch-drain");
    let request = manager.handle(
        target.clone(),
        "navigate".into(),
        json!({ "url": "https://example.com" }),
    );
    let request = tokio::time::timeout(Duration::from_millis(1), request);
    let (_, launched) = tokio::join!(request, launch_started);
    launched.unwrap();
    let closing = {
        let manager = manager.clone();
        tokio::spawn(async move { manager.close_session("pending-close").await })
    };
    settle().await;
    assert!(!closing.is_finished());
    let fake = FakeContext::new();
    let _ = open.send(fake.clone());
    closing.await.unwrap().unwrap();
    assert_eq!(fake.stats(), (0, 1));
    manager.shutdown().await;
}

/// `browser_cancel` through the runner: the abort ends a wait at once but
/// the request settles (and keeps its slot) only when its launch does.
#[tokio::test]
async fn an_aborted_request_settles_with_its_operation() {
    let (fixture, open, launch_started) = gated_manager();
    let manager = &fixture.manager;
    let target = target("s", "w");
    let (abort, aborted) = watch::channel(false);
    let request = {
        let manager = manager.clone();
        let target = target.clone();
        tokio::spawn(async move {
            manager
                .handle_with_abort(target, "snapshot".into(), json!({}), aborted)
                .await
        })
    };
    launch_started.await.unwrap();
    abort.send_replace(true);
    settle().await;
    assert!(!request.is_finished());
    let _ = open.send(FakeContext::new() as ContextRef);
    // The launch went on; the aborted operation never starts.
    let error = request.await.unwrap().unwrap_err();
    assert_eq!(
        (error.status, &*error.message),
        (500, "This operation was aborted")
    );

    // A wait for the user ends with the abort.
    manager
        .handle(target.clone(), "handoff".into(), json!({ "reason": "x" }))
        .await
        .unwrap();
    let (abort, aborted) = watch::channel(false);
    let waiting = manager.handle_with_abort(target, "wait_control".into(), json!({}), aborted);
    let cancel = async {
        settle().await;
        abort.send_replace(true);
    };
    let (error, ()) = tokio::join!(waiting, cancel);
    assert_eq!(error.unwrap_err().status, 499);
    manager.shutdown().await;
}

#[tokio::test]
async fn keeps_a_shared_workspace_context_alive_for_another_pending_session() {
    let (fixture, open, launch_started) = gated_manager();
    let manager = &fixture.manager;
    let first = target("closing-session", "shared-launch");
    let second = target("active-session", "shared-launch");
    let first_request = spawn_handle(manager, &first, "handoff", json!({ "reason": "close me" }));
    let second_request = spawn_handle(manager, &second, "handoff", json!({ "reason": "keep me" }));
    launch_started.await.unwrap();
    settle().await;

    let closing = {
        let manager = manager.clone();
        tokio::spawn(async move { manager.close_session("closing-session").await })
    };
    settle().await;
    let fake = FakeContext::new();
    let _ = open.send(fake.clone());
    assert_eq!(code(first_request.await.unwrap()), "conflict");
    let kept = second_request.await.unwrap().unwrap();
    assert_eq!(kept["active"], true);
    assert_eq!(kept["mode"], "user");
    assert_eq!(kept["handoff"], "keep me");
    closing.await.unwrap().unwrap();
    assert_eq!(fake.stats().1, 0);

    manager.close_session("active-session").await.unwrap();
    assert_eq!(fake.stats().1, 1);
    assert_eq!(fixture.launcher.calls.load(Ordering::SeqCst), 1);
    manager.shutdown().await;
}

#[tokio::test]
async fn cancels_control_waits_when_a_session_closes_or_the_manager_shuts_down() {
    let target = target("waiting-session", "waiting-workspace");
    let closed_context = FakeContext::new();
    let fixture = ready(&closed_context);
    let manager = &fixture.manager;
    manager
        .handle(
            target.clone(),
            "handoff".into(),
            json!({ "reason": "user input" }),
        )
        .await
        .unwrap();
    let wait = spawn_handle(manager, &target, "wait_control", json!({}));
    settle().await;
    let closing = manager.close_session("waiting-session");
    assert_eq!(code(wait.await.unwrap()), "conflict");
    closing.await.unwrap();
    assert_eq!(closed_context.stats().1, 1);
    manager.shutdown().await;

    let shutdown_context = FakeContext::new();
    let fixture = ready(&shutdown_context);
    let manager = &fixture.manager;
    let target = BrowserTarget {
        session_id: "shutdown-waiting-session".into(),
        ..target
    };
    manager
        .handle(
            target.clone(),
            "handoff".into(),
            json!({ "reason": "user input" }),
        )
        .await
        .unwrap();
    let wait = spawn_handle(manager, &target, "wait_control", json!({}));
    settle().await;
    manager.shutdown().await;
    assert_eq!(code(wait.await.unwrap()), "conflict");
    assert_eq!(shutdown_context.stats().1, 1);
    // Shut down: nothing more is accepted.
    let error = manager
        .handle(target, "status".into(), json!({}))
        .await
        .unwrap_err();
    assert_eq!(
        (error.status, &*error.code, &*error.message),
        (503, "runner_unavailable", "The node is shutting down")
    );
}

#[tokio::test]
async fn refuses_when_disabled_or_without_chromium() {
    let context = FakeContext::new();
    let disabled = manager_with(
        |dir| BrowserSettings {
            enabled: false,
            ..settings(dir)
        },
        Box::new(move || {
            let context = context.clone() as ContextRef;
            Box::pin(async move { Ok(context) })
        }),
    );
    assert!(!disabled.manager.enabled());
    let error = disabled
        .manager
        .handle(target("s", "w"), "status".into(), json!({}))
        .await
        .unwrap_err();
    assert_eq!(
        (error.status, &*error.code, &*error.message),
        (
            403,
            "forbidden",
            "The browser is disabled on this node (PIRC_BROWSER)"
        )
    );

    let missing = manager_with(
        |dir| BrowserSettings {
            executable: None,
            ..settings(dir)
        },
        Box::new(|| Box::pin(async { Err("unused".to_owned()) })),
    );
    assert!(!missing.manager.enabled());
    let error = missing
        .manager
        .handle(target("s", "w"), "close".into(), json!({}))
        .await
        .unwrap_err();
    assert_eq!(
        (error.status, &*error.code, &*error.message),
        (
            503,
            "runner_unavailable",
            "No Chromium found on this node; set PIRC_BROWSER_EXECUTABLE"
        )
    );
}

#[tokio::test]
async fn status_and_viewers_launch_nothing() {
    let context = FakeContext::new();
    let fixture = ready(&context);
    let manager = &fixture.manager;
    assert!(manager.enabled());
    let status = manager
        .handle(target("s", "w"), "status".into(), json!({}))
        .await
        .unwrap();
    assert_eq!(
        status,
        json!({ "active": false, "url": "", "title": "", "mode": "agent", "handoff": null,
            "agentWaiting": false, "action": null, "recording": null, "tabs": [],
            "viewport": { "width": 800, "height": 600 } })
    );
    let frames = Arc::new(Mutex::new(Vec::new()));
    let sink: FrameSink = {
        let frames = frames.clone();
        Arc::new(move |frame| frames.lock().unwrap().push(frame))
    };
    let detach = manager.attach("s", sink);
    assert_eq!(
        frames.lock().unwrap()[0],
        json!({ "type": "state", "state": status })
    );
    assert_eq!(
        frames.lock().unwrap()[1],
        json!({ "type": "log", "entries": [] })
    );
    let answer = manager
        .input(target("s", "w"), json!({ "type": "key", "key": "a" }))
        .await
        .unwrap();
    assert_eq!(
        answer,
        Some(json!({ "type": "error", "code": "not_found",
            "message": "No browser is open for this session" }))
    );
    let image = manager
        .input(
            target("s", "w"),
            json!({ "type": "log_image", "index": 3.7 }),
        )
        .await
        .unwrap();
    assert_eq!(
        image,
        Some(json!({ "type": "log_image", "index": 3, "data": null }))
    );
    detach();
    assert_eq!(fixture.launcher.calls.load(Ordering::SeqCst), 0);
    manager.shutdown().await;
}

#[tokio::test]
async fn reports_a_failed_launch_and_tries_again_later() {
    let fixture = manager_with(
        settings,
        Box::new(|| Box::pin(async { Err("spawn chromium ENOENT\nmore detail".to_owned()) })),
    );
    let manager = &fixture.manager;
    let target = target("s", "w/../x y");
    for attempt in 1..=2 {
        let error = manager
            .handle(target.clone(), "snapshot".into(), json!({}))
            .await
            .unwrap_err();
        assert_eq!(
            (error.status, &*error.code, &*error.message),
            (
                503,
                "runner_unavailable",
                "Could not start the browser: spawn chromium ENOENT"
            )
        );
        assert_eq!(fixture.launcher.calls.load(Ordering::SeqCst), attempt);
    }
    let profile = fixture.launcher.profiles.lock().unwrap()[0].clone();
    assert_eq!(profile.file_name().unwrap(), "w____x_y");
    use std::os::unix::fs::PermissionsExt as _;
    assert_eq!(
        std::fs::metadata(&profile).unwrap().permissions().mode() & 0o777,
        0o700
    );
    manager.shutdown().await;
}

#[tokio::test]
async fn adopts_the_spare_blank_page_then_opens_new_ones_up_to_eight() {
    let spare = FakePage::new("about:blank");
    let context = Arc::new(FakeContext {
        initial: vec![spare.clone() as PageRef],
        gone: Mutex::new(Some(watch::channel(false).0)),
        ..FakeContext::default()
    });
    let fixture = ready(&context);
    let manager = &fixture.manager;
    let first = target("s1", "w");
    manager
        .handle(first.clone(), "handoff".into(), json!({ "reason": "x" }))
        .await
        .unwrap();
    assert_eq!(context.stats().0, 0);
    settle().await;
    assert!(spare.shows_actions.load(Ordering::SeqCst));
    // The spare page is taken: the next session gets a new one.
    let second = target("s2", "w");
    let view = manager
        .handle(second.clone(), "release".into(), json!({}))
        .await
        .unwrap();
    assert_eq!(view["active"], true);
    assert_eq!(context.stats().0, 1);
    for count in 2..=8 {
        let tabs = manager
            .handle(second.clone(), "tabs".into(), json!({ "action": "new" }))
            .await
            .unwrap();
        assert_eq!(tabs["tabs"].as_array().unwrap().len(), count);
        assert_eq!(
            tabs["tabs"][count - 1],
            json!({ "index": count - 1, "url": "about:blank",
            "title": "Fake", "active": true })
        );
    }
    let error = manager
        .handle(second.clone(), "tabs".into(), json!({ "action": "new" }))
        .await
        .unwrap_err();
    assert_eq!(
        (error.status, &*error.code, &*error.message),
        (409, "conflict", "At most 8 tabs per session")
    );
    for (index, message) in [(json!(8), "No tab 8"), (Value::Null, "No tab null")] {
        let error = manager
            .handle(
                second.clone(),
                "tabs".into(),
                json!({ "action": "select", "index": index }),
            )
            .await
            .unwrap_err();
        assert_eq!((error.status, &*error.message), (404, message));
    }
    let error = manager
        .handle(second.clone(), "tabs".into(), json!({ "action": "close" }))
        .await
        .unwrap_err();
    assert_eq!(error.message, "No tab (missing)");
    let error = manager
        .handle(second.clone(), "tabs".into(), json!({ "action": 3 }))
        .await
        .unwrap_err();
    assert_eq!(error.message, "action is list, new, select or close");
    let tabs = manager
        .handle(
            second.clone(),
            "tabs".into(),
            json!({ "action": "select", "index": 0 }),
        )
        .await
        .unwrap();
    assert_eq!(tabs["tabs"][0]["active"], true);
    // Closing the active tab makes the last one active.
    manager
        .handle(
            second.clone(),
            "tabs".into(),
            json!({ "action": "close", "index": 0 }),
        )
        .await
        .unwrap();
    settle().await;
    let status = manager
        .handle(second.clone(), "status".into(), json!({}))
        .await
        .unwrap();
    assert_eq!(status["tabs"].as_array().unwrap().len(), 7);
    assert_eq!(status["tabs"][6]["active"], true);
    let error = manager
        .handle(second, "frobnicate".into(), json!({}))
        .await
        .unwrap_err();
    assert_eq!(
        (error.status, &*error.message),
        (400, "Unknown browser operation frobnicate")
    );
    manager.shutdown().await;
    assert!(spare.is_closed());
}

#[tokio::test]
async fn hands_off_waits_for_the_user_and_times_out() {
    let context = FakeContext::new();
    let fixture = ready(&context);
    let manager = &fixture.manager;
    let target = target("s", "w");
    let error = manager
        .handle(target.clone(), "handoff".into(), json!({ "reason": "" }))
        .await
        .unwrap_err();
    assert_eq!(error.message, "reason must be a non-empty string");
    let view = manager
        .handle(
            target.clone(),
            "handoff".into(),
            json!({ "reason": "Please log in" }),
        )
        .await
        .unwrap();
    assert_eq!(
        (&view["mode"], &view["handoff"]),
        (&json!("user"), &json!("Please log in"))
    );
    let error = manager
        .handle(target.clone(), "snapshot".into(), json!({ "waitMs": 30 }))
        .await
        .unwrap_err();
    assert_eq!(
        (error.status, &*error.code, &*error.message),
        (
            409,
            "user_in_control",
            "The user still controls the browser. Wait, or ask them to return control."
        )
    );
    let status = manager
        .handle(target.clone(), "status".into(), json!({}))
        .await
        .unwrap();
    assert_eq!(status["agentWaiting"], false);

    // An abandoned wait (`browser_cancel`) stops waiting.
    let waiting = manager.handle(target.clone(), "wait_control".into(), json!({}));
    assert!(
        tokio::time::timeout(Duration::from_millis(30), waiting)
            .await
            .is_err()
    );
    settle().await;
    let status = manager
        .handle(target.clone(), "status".into(), json!({}))
        .await
        .unwrap();
    assert_eq!(status["agentWaiting"], false);

    let waiting = spawn_handle(manager, &target, "wait_control", json!({}));
    settle().await;
    let status = manager
        .handle(target.clone(), "status".into(), json!({}))
        .await
        .unwrap();
    assert_eq!(status["agentWaiting"], true);
    // Viewer input other than control needs user mode, which this is.
    let answer = manager
        .input(target.clone(), json!({ "type": "zoom" }))
        .await
        .unwrap();
    assert_eq!(
        answer,
        Some(
            json!({ "type": "error", "code": "invalid_input", "message": "Unknown message zoom" })
        )
    );
    assert_eq!(
        manager
            .input(target.clone(), json!({ "type": "release" }))
            .await
            .unwrap(),
        None
    );
    let summary = waiting.await.unwrap().unwrap();
    assert_eq!(
        summary,
        json!({ "url": "about:blank", "title": "Fake", "snapshot": "- generic [ref=e1]",
            "offset": 0, "totalChars": 18, "truncated": false })
    );
    let answer = manager
        .input(target.clone(), json!({ "type": "text", "text": "x" }))
        .await
        .unwrap();
    assert_eq!(
        answer,
        Some(json!({ "type": "error", "code": "agent_in_control",
            "message": "Take over the browser first" }))
    );
    let view = manager
        .handle(target.clone(), "release".into(), json!({}))
        .await
        .unwrap();
    assert_eq!(view["mode"], "agent");
    assert_eq!(
        manager
            .handle(target, "close".into(), json!({}))
            .await
            .unwrap(),
        json!({ "closed": true })
    );
    manager.shutdown().await;
}

#[tokio::test]
async fn streams_state_and_the_action_log_to_viewers() {
    let context = FakeContext::new();
    let fixture = ready(&context);
    let manager = &fixture.manager;
    let target = target("s", "w");
    let frames = Arc::new(Mutex::new(Vec::<Value>::new()));
    let sink: FrameSink = {
        let frames = frames.clone();
        Arc::new(move |frame| frames.lock().unwrap().push(frame))
    };
    let detach = manager.attach("s", sink);
    assert_eq!(
        manager
            .input(target.clone(), json!({ "type": "takeover" }))
            .await
            .unwrap(),
        None
    );
    // Twice: the second changes nothing.
    assert_eq!(
        manager
            .input(target.clone(), json!({ "type": "takeover" }))
            .await
            .unwrap(),
        None
    );
    manager
        .input(target.clone(), json!({ "type": "release" }))
        .await
        .unwrap();
    settle().await;
    let entries: Vec<Value> = frames
        .lock()
        .unwrap()
        .iter()
        .filter(|frame| frame["type"] == "log_entry")
        .map(|frame| frame["entry"].clone())
        .collect();
    assert_eq!(entries.len(), 2);
    assert_eq!(
        (
            &entries[0]["index"],
            &entries[0]["actor"],
            &entries[0]["action"],
            &entries[0]["image"]
        ),
        (
            &json!(0),
            &json!("user"),
            &json!("User took control"),
            &json!(false)
        )
    );
    assert_eq!(
        (
            &entries[1]["index"],
            &entries[1]["action"],
            &entries[1]["image"],
            &entries[1]["url"]
        ),
        (
            &json!(1),
            &json!("User returned control"),
            &json!(true),
            &json!("about:blank")
        )
    );
    let image = manager
        .input(target.clone(), json!({ "type": "log_image", "index": 1 }))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(image["data"], "/9j/");
    assert!(
        frames
            .lock()
            .unwrap()
            .iter()
            .any(|frame| frame["type"] == "state"
                && frame["state"]["mode"] == "user"
                && frame["state"]["title"] == "Fake"
                && frame["state"]["tabs"][0]["title"] == "Fake")
    );

    // A popup joins the session as its active tab.
    let popup = FakePage::new("https://example.com/popup");
    context
        .page(0)
        .emit(|| PageEvent::Popup(popup.clone() as PageRef));
    settle().await;
    let status = manager
        .handle(target.clone(), "status".into(), json!({}))
        .await
        .unwrap();
    assert_eq!(status["url"], "https://example.com/popup");
    assert_eq!(status["tabs"].as_array().unwrap().len(), 2);
    assert!(
        frames
            .lock()
            .unwrap()
            .iter()
            .any(|frame| frame["type"] == "log_entry"
                && frame["entry"]["action"] == "Popup opened: https://example.com/popup")
    );

    // Chromium went away: the session's tab is gone, viewers see it.
    context.crash();
    settle().await;
    let status = manager
        .handle(target.clone(), "status".into(), json!({}))
        .await
        .unwrap();
    assert_eq!(status["active"], false);
    let last_state = frames
        .lock()
        .unwrap()
        .iter()
        .rev()
        .find(|frame| frame["type"] == "state")
        .cloned()
        .unwrap();
    assert_eq!(last_state["state"]["active"], false);
    detach();
    manager.shutdown().await;
}

#[tokio::test]
async fn stops_a_recording_when_ffmpeg_is_missing() {
    let context = FakeContext::new();
    let fixture = manager_with(
        |dir| BrowserSettings {
            ffmpeg: "/nonexistent/ffmpeg".into(),
            ..settings(dir)
        },
        {
            let context = context.clone();
            Box::new(move || {
                let context = context.clone() as ContextRef;
                Box::pin(async move { Ok(context) })
            })
        },
    );
    let manager = &fixture.manager;
    let root = tempfile::tempdir().unwrap();
    let target = BrowserTarget {
        root: root.path().to_owned(),
        ..target("s", "w")
    };
    let error = manager
        .handle(
            target.clone(),
            "record".into(),
            json!({ "action": "start" }),
        )
        .await
        .unwrap_err();
    assert_eq!(
        (error.status, &*error.code, &*error.message),
        (
            503,
            "runner_unavailable",
            "ffmpeg not found (/nonexistent/ffmpeg); set PIRC_FFMPEG"
        )
    );
    assert!(root.path().join(".pirc/recordings").is_dir());
    let error = manager
        .handle(target.clone(), "record".into(), json!({ "action": "stop" }))
        .await
        .unwrap_err();
    assert_eq!((error.status, &*error.message), (409, "Not recording"));
    let error = manager
        .handle(target, "record".into(), json!({}))
        .await
        .unwrap_err();
    assert_eq!(
        (error.status, &*error.message),
        (400, "action is start or stop")
    );
    manager.shutdown().await;
}

// ---- timing, ordering and races ------------------------------------------------

/// A viewer that keeps what it gets.
fn viewer() -> (FrameSink, Arc<Mutex<Vec<Value>>>) {
    let frames = Arc::new(Mutex::new(Vec::new()));
    let sink: FrameSink = {
        let frames = frames.clone();
        Arc::new(move |frame| frames.lock().unwrap().push(frame))
    };
    (sink, frames)
}

fn of_type(frames: &Mutex<Vec<Value>>, kind: &str) -> Vec<Value> {
    frames
        .lock()
        .unwrap()
        .iter()
        .filter(|frame| frame["type"] == kind)
        .cloned()
        .collect()
}

/// The screencast frames a viewer got, decoded.
fn sent_frames(frames: &Mutex<Vec<Value>>) -> Vec<String> {
    use base64::Engine as _;
    of_type(frames, "frame")
        .iter()
        .map(|frame| {
            let data = base64::engine::general_purpose::STANDARD
                .decode(frame["data"].as_str().unwrap())
                .unwrap();
            String::from_utf8(data).unwrap()
        })
        .collect()
}

/// A manager whose launches return `context` and whose ffmpeg is `ffmpeg`.
fn with_ffmpeg(context: &Arc<FakeContext>, ffmpeg: &str) -> Fixture {
    let context = context.clone();
    let ffmpeg = ffmpeg.to_owned();
    manager_with(
        move |dir| BrowserSettings {
            ffmpeg,
            ..settings(dir)
        },
        Box::new(move || {
            let context = context.clone() as ContextRef;
            Box::pin(async move { Ok(context) })
        }),
    )
}

/// A stand-in ffmpeg that creates its output and reads its input to the
/// end, with shell builtins only (the manager's environment has no PATH).
const CONSUMING_FFMPEG: &str = r#"for last; do :; done; : > "$last"; while read -r _; do :; done"#;

#[tokio::test(start_paused = true)]
async fn sends_at_most_one_frame_per_80_ms_and_always_the_latest() {
    let context = FakeContext::new();
    let fixture = ready(&context);
    let manager = &fixture.manager;
    manager
        .handle(target("s", "w"), "release".into(), json!({}))
        .await
        .unwrap();
    let page = context.page(0);
    settle().await;
    // Nobody watches: no screencast.
    assert!(!page.casting());
    let (sink, frames) = viewer();
    let detach = manager.attach("s", sink);
    settle().await;
    assert!(page.casting());

    // The first frame goes out at once.
    page.frame(b"one");
    settle().await;
    assert_eq!(sent_frames(&frames), ["one"]);
    // Within the interval: held back, then only the latest.
    page.frame(b"two");
    page.frame(b"three");
    settle().await;
    tokio::time::advance(Duration::from_millis(79)).await;
    settle().await;
    assert_eq!(sent_frames(&frames), ["one"]);
    tokio::time::advance(Duration::from_millis(1)).await;
    settle().await;
    assert_eq!(sent_frames(&frames), ["one", "three"]);
    // After a quiet interval the next one goes out at once again.
    tokio::time::advance(Duration::from_millis(200)).await;
    page.frame(b"four");
    settle().await;
    assert_eq!(sent_frames(&frames), ["one", "three", "four"]);
    // A new viewer starts with the latest frame.
    let (sink, late) = viewer();
    let detach_late = manager.attach("s", sink);
    assert_eq!(sent_frames(&late), ["four"]);

    detach();
    detach_late();
    settle().await;
    assert!(!page.casting());
    manager.shutdown().await;
}

#[tokio::test(start_paused = true)]
async fn sends_a_tabs_states_in_the_order_they_were_taken() {
    let context = FakeContext::new();
    let fixture = ready(&context);
    let manager = &fixture.manager;
    manager
        .handle(target("s", "w"), "release".into(), json!({}))
        .await
        .unwrap();
    let (sink, frames) = viewer();
    let detach = manager.attach("s", sink);
    settle().await;
    let page = context.page(0);
    frames.lock().unwrap().clear();

    // The first state's title is slow: the second one waits for it.
    page.title_delays
        .lock()
        .unwrap()
        .push_back(Duration::from_millis(500));
    page.set_url("https://a.example/");
    page.emit(|| PageEvent::Load);
    settle().await;
    page.set_url("https://b.example/");
    page.emit(|| PageEvent::Load);
    settle().await;
    assert!(of_type(&frames, "state").is_empty());
    tokio::time::advance(Duration::from_millis(500)).await;
    settle().await;
    let urls: Vec<Value> = of_type(&frames, "state")
        .iter()
        .map(|state| state["state"]["url"].clone())
        .collect();
    assert_eq!(
        urls,
        [json!("https://a.example/"), json!("https://b.example/")]
    );

    // A title that takes more than a second lets later states pass.
    frames.lock().unwrap().clear();
    page.title_delays
        .lock()
        .unwrap()
        .push_back(Duration::from_secs(5));
    page.set_url("https://c.example/");
    page.emit(|| PageEvent::Load);
    settle().await;
    page.set_url("https://d.example/");
    page.emit(|| PageEvent::Load);
    settle().await;
    tokio::time::advance(Duration::from_secs(1)).await;
    settle().await;
    let urls: Vec<Value> = of_type(&frames, "state")
        .iter()
        .map(|state| state["state"]["url"].clone())
        .collect();
    assert_eq!(urls, [json!("https://d.example/")]);
    detach();
    manager.shutdown().await;
}

#[tokio::test(start_paused = true)]
async fn reaps_idle_sessions_unless_recording_in_user_mode_or_watched() {
    let context = FakeContext::new();
    let fixture = ready(&context);
    let manager = &fixture.manager;
    let sessions = ["idle", "recording", "user", "watched"];
    for session in sessions {
        manager
            .handle(target(session, "w"), "release".into(), json!({}))
            .await
            .unwrap();
    }
    manager
        .handle(
            target("user", "w"),
            "handoff".into(),
            json!({ "reason": "x" }),
        )
        .await
        .unwrap();
    let detach = manager.attach("watched", Arc::new(|_| {}));
    {
        // A recording without ffmpeg: only its presence matters here.
        let tab = manager.inner.lock().tabs["recording"].clone();
        let recording = Recording::start(
            "/nonexistent/ffmpeg",
            &BTreeMap::new(),
            tempfile::tempfile().unwrap(),
            "r".into(),
            Arc::new(|| None),
            Arc::new(|| true),
        );
        tab.lock().recording = Some(ActiveRecording {
            seq: 0,
            recording,
            limit: None,
        });
    }
    let open = || {
        let mut open: Vec<String> = manager.inner.lock().tabs.keys().cloned().collect();
        open.sort();
        open
    };
    // idle_ms is 60 s.
    tokio::time::advance(Duration::from_secs(59)).await;
    manager.inner.reap_idle();
    settle().await;
    assert_eq!(open(), sessions);
    tokio::time::advance(Duration::from_secs(2)).await;
    manager.inner.reap_idle();
    settle().await;
    settle().await;
    assert_eq!(open(), ["recording", "user", "watched"]);
    // Activity counts.
    manager
        .handle(target("user", "w"), "release".into(), json!({}))
        .await
        .unwrap();
    detach();
    manager.inner.reap_idle();
    settle().await;
    settle().await;
    assert_eq!(open(), ["recording", "user"]);
    manager.shutdown().await;
}

#[tokio::test(start_paused = true)]
async fn stops_a_recording_after_thirty_minutes() {
    let root = tempfile::tempdir().unwrap();
    let ffmpeg = fake_ffmpeg(root.path(), CONSUMING_FFMPEG);
    let context = FakeContext::new();
    let fixture = with_ffmpeg(&context, &ffmpeg);
    let manager = &fixture.manager;
    let target = BrowserTarget {
        root: root.path().join("session"),
        ..target("s", "w")
    };
    let started = manager
        .handle(
            target.clone(),
            "record".into(),
            json!({ "action": "start", "name": "cap" }),
        )
        .await
        .unwrap();
    assert_eq!(started["recording"], true);
    let path = started["path"].as_str().unwrap().to_owned();
    assert!(path.starts_with(".pirc/recordings/cap-"), "{path}");
    let recording = |manager: &BrowserManager| {
        let tab = manager.inner.lock().tabs["s"].clone();
        let st = tab.lock();
        st.recording
            .as_ref()
            .map(|active| active.recording.relative.clone())
    };
    // Watched, so that the idle sweep (also due at 30:00) keeps the tab.
    let (sink, frames) = viewer();
    let detach = manager.attach("s", sink);
    tokio::time::advance(RECORD_MAX - Duration::from_secs(1)).await;
    settle().await;
    assert_eq!(recording(manager), Some(path));
    tokio::time::advance(Duration::from_secs(1)).await;
    settle().await;
    assert_eq!(recording(manager), None);
    // Viewers see it once ffmpeg is gone (a real process: real time).
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    while of_type(&frames, "state").pop().unwrap()["state"]["recording"] != Value::Null {
        assert!(std::time::Instant::now() < deadline, "no final state");
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    detach();
    manager.shutdown().await;
}

/// ffmpeg failing at once fails the start with its stderr when it fails
/// within the start's 150 ms (as in TS). On a loaded machine it may fail
/// later: then the start succeeds and the stop reports the failure, the
/// other outcome TS gives for a slow ffmpeg; both are accepted.
#[tokio::test]
async fn fails_a_start_whose_ffmpeg_reports_an_error() {
    let root = tempfile::tempdir().unwrap();
    let ffmpeg = fake_ffmpeg(root.path(), "echo 'Unknown encoder' >&2; exit 1");
    // Run the script once first, as the first exec of a new file can take
    // longer than 150 ms (macOS checks it): the start's own outcome is the
    // likely one.
    let warm = std::process::Command::new(&ffmpeg).output().unwrap();
    assert_eq!(warm.stderr, b"Unknown encoder\n");
    let context = FakeContext::new();
    let fixture = with_ffmpeg(&context, &ffmpeg);
    let manager = &fixture.manager;
    let target = BrowserTarget {
        root: root.path().join("session"),
        ..target("s", "w")
    };
    let started = manager
        .handle(
            target.clone(),
            "record".into(),
            json!({ "action": "start" }),
        )
        .await;
    match started {
        Err(error) => assert_eq!(
            (error.status, &*error.code, &*error.message),
            (503, "runner_unavailable", "Unknown encoder\n")
        ),
        Ok(started) => {
            assert_eq!(started["recording"], true);
            // Stopped once ffmpeg's failure is the recording's (a stop
            // before it exits reports its exit code instead).
            let tab = manager.inner.lock().tabs["s"].clone();
            let deadline = std::time::Instant::now() + Duration::from_secs(10);
            while tab
                .lock()
                .recording
                .as_ref()
                .is_some_and(|active| active.recording.failed().is_none())
            {
                assert!(std::time::Instant::now() < deadline, "ffmpeg never failed");
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
            let error = manager
                .handle(target.clone(), "record".into(), json!({ "action": "stop" }))
                .await
                .unwrap_err();
            assert_eq!(
                (error.status, &*error.code, &*error.message),
                (500, "browser_error", "Recording failed: Unknown encoder\n")
            );
        }
    }
    let status = manager
        .handle(target, "status".into(), json!({}))
        .await
        .unwrap();
    assert_eq!(status["recording"], Value::Null);
    manager.shutdown().await;
}

/// Issue: two starts on different threads could both pass the "Already
/// recording" check. A start reserves the slot before it awaits (here, a
/// viewer's start opening the tab's page).
#[tokio::test]
async fn refuses_a_recording_start_racing_another() {
    let root = tempfile::tempdir().unwrap();
    let ffmpeg = fake_ffmpeg(root.path(), CONSUMING_FFMPEG);
    let context = FakeContext::new();
    let fixture = with_ffmpeg(&context, &ffmpeg);
    let manager = &fixture.manager;
    let target = BrowserTarget {
        root: root.path().join("session"),
        ..target("s", "w")
    };
    manager
        .handle(target.clone(), "release".into(), json!({}))
        .await
        .unwrap();
    manager
        .handle(
            target.clone(),
            "tabs".into(),
            json!({ "action": "close", "index": 0 }),
        )
        .await
        .unwrap();
    settle().await;
    assert!(manager.inner.lock().tabs["s"].active().is_none());
    let (open, gate) = oneshot::channel();
    *context.page_gate.lock().unwrap() = Some(gate);
    let viewer_start = {
        let manager = manager.clone();
        let target = target.clone();
        tokio::spawn(async move {
            manager
                .input(target, json!({ "type": "record", "action": "start" }))
                .await
        })
    };
    settle().await;
    assert!(!viewer_start.is_finished());
    let error = manager
        .handle(
            target.clone(),
            "record".into(),
            json!({ "action": "start" }),
        )
        .await
        .unwrap_err();
    assert_eq!((error.status, &*error.message), (409, "Already recording"));
    // A second viewer start is ignored.
    assert_eq!(
        manager
            .input(
                target.clone(),
                json!({ "type": "record", "action": "start" })
            )
            .await
            .unwrap(),
        None
    );
    open.send(()).unwrap();
    assert_eq!(viewer_start.await.unwrap().unwrap(), None);
    let stopped = manager
        .handle(target.clone(), "record".into(), json!({ "action": "stop" }))
        .await
        .unwrap();
    let path = stopped["path"].as_str().unwrap();
    assert!(path.starts_with(".pirc/recordings/recording-"), "{path}");
    let files = std::fs::read_dir(root.path().join("session/.pirc/recordings"))
        .unwrap()
        .count();
    assert_eq!(files, 1);
    manager.shutdown().await;
}

#[tokio::test(start_paused = true)]
async fn concurrent_closes_share_one_closing() {
    let context = FakeContext::new();
    let fixture = ready(&context);
    let manager = &fixture.manager;
    let target = target("s", "w");
    manager
        .handle(target.clone(), "release".into(), json!({}))
        .await
        .unwrap();
    *context.page(0).snapshot_delay.lock().unwrap() = Duration::from_secs(10);
    let running = spawn_handle(manager, &target, "snapshot", json!({}));
    settle().await;
    let close = || {
        let manager = manager.clone();
        tokio::spawn(async move { manager.close_session("s").await })
    };
    let (first, second) = (close(), close());
    settle().await;
    // Both wait for the running operation, in one closing.
    assert!(!first.is_finished() && !second.is_finished());
    assert_eq!(manager.inner.lock().closures.len(), 1);
    // New requests are fenced meanwhile.
    let error = manager
        .handle(target.clone(), "snapshot".into(), json!({}))
        .await
        .unwrap_err();
    assert_eq!(
        (error.status, &*error.message),
        (409, "The browser session is closing")
    );
    tokio::time::advance(Duration::from_secs(10)).await;
    running.await.unwrap().unwrap();
    first.await.unwrap().unwrap();
    second.await.unwrap().unwrap();
    assert_eq!(context.stats().1, 1);
    assert!(manager.inner.lock().closures.is_empty());
    manager.shutdown().await;
}

/// A crash wakes the waiter with a closed tab. A fresh request may reopen a
/// tracked tab, but an old queued request cannot revive an unregistered tab.
#[tokio::test]
async fn a_crash_wakes_waiters_without_reviving_an_untracked_tab() {
    let contexts = Arc::new(Mutex::new(Vec::<Arc<FakeContext>>::new()));
    let fixture = manager_with(settings, {
        let contexts = contexts.clone();
        Box::new(move || {
            let context = FakeContext::new();
            contexts.lock().unwrap().push(context.clone());
            Box::pin(async move { Ok(context as ContextRef) })
        })
    });
    let manager = &fixture.manager;
    let target = target("s", "w");
    manager
        .handle(target.clone(), "handoff".into(), json!({ "reason": "x" }))
        .await
        .unwrap();
    let queued = spawn_handle(manager, &target, "snapshot", json!({}));
    settle().await;
    let status = manager
        .handle(target.clone(), "status".into(), json!({}))
        .await
        .unwrap();
    assert_eq!(status["agentWaiting"], true);
    let first = contexts.lock().unwrap()[0].clone();
    first.crash();
    assert_eq!(queued.await.unwrap().unwrap_err().code, "conflict");
    assert_eq!(fixture.launcher.calls.load(Ordering::SeqCst), 1);
    let summary = manager
        .handle(target, "snapshot".into(), json!({}))
        .await
        .unwrap();
    assert_eq!(summary["snapshot"], "- generic [ref=e1]");
    assert_eq!(fixture.launcher.calls.load(Ordering::SeqCst), 2);
    manager.shutdown().await;
}

#[tokio::test(start_paused = true)]
async fn an_operation_aborted_while_queued_never_runs() {
    let context = FakeContext::new();
    let fixture = ready(&context);
    let manager = &fixture.manager;
    let target = target("s", "w");
    manager
        .handle(target.clone(), "release".into(), json!({}))
        .await
        .unwrap();
    *context.page(0).snapshot_delay.lock().unwrap() = Duration::from_secs(10);
    let running = spawn_handle(manager, &target, "snapshot", json!({}));
    settle().await;
    let (abort, aborted) = watch::channel(false);
    let queued = {
        let manager = manager.clone();
        let target = target.clone();
        tokio::spawn(async move {
            manager
                .handle_with_abort(target, "snapshot".into(), json!({}), aborted)
                .await
        })
    };
    settle().await;
    abort.send_replace(true);
    settle().await;
    // Settled only once the running operation lets go of the tab.
    assert!(!queued.is_finished());
    tokio::time::advance(Duration::from_secs(10)).await;
    running.await.unwrap().unwrap();
    let error = queued.await.unwrap().unwrap_err();
    assert_eq!(
        (error.status, &*error.code, &*error.message),
        (500, "browser_error", "This operation was aborted")
    );
    // Only the first one ran (and was logged).
    assert_eq!(manager.inner.lock().tabs["s"].lock().log_count, 1);
    manager.shutdown().await;
}

/// Issue: a `log_entry` broadcast while a viewer attaches was lost (taken
/// after the viewer's `log`, sent before it was registered) or sent twice
/// (in its `log` and again). Every viewer, attached while entries are
/// logged on another thread, sees each entry exactly once, in order, after
/// its `state` and `log`.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_viewer_attaching_while_entries_are_logged_gets_each_once() {
    const ENTRIES: usize = 2000;
    const VIEWERS: usize = 100;
    let context = FakeContext::new();
    let fixture = ready(&context);
    let manager = &fixture.manager;
    manager
        .handle(target("s", "w"), "release".into(), json!({}))
        .await
        .unwrap();
    let tab = manager.inner.lock().tabs["s"].clone();
    // One entry already: every viewer's `log` has at least one.
    manager.inner.log(&tab, "agent", "first", None);
    let start = Arc::new(std::sync::Barrier::new(2));
    let logging = {
        let inner = manager.inner.clone();
        let tab = tab.clone();
        let start = start.clone();
        tokio::task::spawn_blocking(move || {
            start.wait();
            for n in 0..ENTRIES {
                inner.log(&tab, "agent", &format!("entry {n}"), None);
            }
        })
    };
    // Spread over the logging: a viewer every ENTRIES / VIEWERS entries.
    let attaching = {
        let manager = manager.clone();
        let tab = tab.clone();
        tokio::task::spawn_blocking(move || {
            start.wait();
            (0..VIEWERS)
                .map(|n| {
                    while tab.lock().log_count < (1 + n * ENTRIES / VIEWERS) as u64 {
                        std::thread::yield_now();
                    }
                    let (sink, frames) = viewer();
                    let detach = manager.attach("s", sink);
                    (frames, detach)
                })
                .collect::<Vec<_>>()
        })
    };
    let viewers = attaching.await.unwrap();
    logging.await.unwrap();
    let last = ENTRIES as i64;
    for (frames, detach) in viewers {
        let frames = frames.lock().unwrap().clone();
        assert_eq!(frames[0]["type"], "state");
        assert_eq!(frames[1]["type"], "log");
        let mut indices: Vec<i64> = frames[1]["entries"]
            .as_array()
            .unwrap()
            .iter()
            .map(|entry| entry["index"].as_i64().unwrap())
            .collect();
        assert!(!indices.is_empty());
        indices.extend(
            frames[2..]
                .iter()
                .filter(|frame| frame["type"] == "log_entry")
                .map(|frame| frame["entry"]["index"].as_i64().unwrap()),
        );
        let first = indices[0];
        let expected: Vec<i64> = (first..=last).collect();
        assert_eq!(indices, expected, "lost or repeated entries");
        detach();
    }
    manager.shutdown().await;
}

/// Issue: a dropped tab's empty state went out at once, before the tab's
/// earlier states still reading their titles, so a viewer could end on a
/// stale state of a tab that no longer exists.
#[tokio::test(start_paused = true)]
async fn a_dropped_tabs_empty_state_goes_out_last() {
    let context = FakeContext::new();
    let fixture = ready(&context);
    let manager = &fixture.manager;
    manager
        .handle(target("s", "w"), "release".into(), json!({}))
        .await
        .unwrap();
    let (sink, frames) = viewer();
    let detach = manager.attach("s", sink);
    settle().await;
    let page = context.page(0);
    frames.lock().unwrap().clear();
    page.title_delays
        .lock()
        .unwrap()
        .push_back(Duration::from_millis(500));
    page.set_url("https://a.example/");
    page.emit(|| PageEvent::Load);
    settle().await;
    // Chromium goes away while that state reads its title.
    context.crash();
    settle().await;
    assert!(manager.inner.lock().tabs.is_empty());
    assert!(of_type(&frames, "state").is_empty());
    tokio::time::advance(Duration::from_millis(500)).await;
    settle().await;
    let states: Vec<(Value, Value)> = of_type(&frames, "state")
        .iter()
        .map(|state| {
            (
                state["state"]["url"].clone(),
                state["state"]["active"].clone(),
            )
        })
        .collect();
    assert_eq!(
        states,
        [
            (json!("https://a.example/"), json!(true)),
            (json!(""), json!(false)),
        ]
    );
    detach();
    manager.shutdown().await;
}

#[tokio::test(start_paused = true)]
async fn a_failed_page_close_stays_unconfirmed_and_does_not_close_a_peer_context() {
    let context = FakeContext::new();
    let f = ready(&context);
    for session in ["s", "peer"] {
        f.manager
            .handle(target(session, "w"), "release".into(), json!({}))
            .await
            .unwrap();
    }
    context.page(0).fail_close.store(true, Ordering::SeqCst);
    let error = f.manager.close_session("s").await.unwrap_err();
    assert_eq!(error.code, "browser_stop_unconfirmed");
    assert_eq!(context.stats().1, 0);
    assert!(!context.page(1).is_closed());
    assert!(
        f.manager
            .handle(target("s", "w"), "release".into(), json!({}))
            .await
            .is_err()
    );
    f.manager
        .handle(target("peer", "w"), "status".into(), json!({}))
        .await
        .unwrap();
    assert_eq!(
        f.manager.close_session("s").await.unwrap_err().code,
        "browser_stop_unconfirmed"
    );
    f.manager.close_session("peer").await.unwrap();
    f.manager.shutdown().await;
}

#[tokio::test(start_paused = true)]
async fn context_close_without_a_closed_event_is_not_success() {
    let context = FakeContext::new();
    let f = ready(&context);
    f.manager
        .handle(target("s", "w"), "release".into(), json!({}))
        .await
        .unwrap();
    context.fail_close.store(true, Ordering::SeqCst);
    assert_eq!(
        f.manager.close_session("s").await.unwrap_err().code,
        "browser_stop_unconfirmed"
    );
    assert_eq!(
        f.manager.close_session("s").await.unwrap_err().code,
        "browser_stop_unconfirmed"
    );
    context.crash();
    f.manager.shutdown().await;
}

#[tokio::test(start_paused = true)]
async fn a_popup_queued_before_page_close_is_drained_with_its_origin() {
    for fails in [false, true] {
        let context = FakeContext::new();
        let f = ready(&context);
        for session in ["s", "peer"] {
            f.manager
                .handle(target(session, "w"), "release".into(), json!({}))
                .await
                .unwrap();
        }
        let popup = FakePage::new("https://example.com/late-popup");
        *popup.close_delay.lock().unwrap() = Duration::from_secs(1);
        popup.fail_close.store(fails, Ordering::SeqCst);
        *context.page(0).close_popup.lock().unwrap() = Some(popup.clone());
        let manager = f.manager.clone();
        let closing = tokio::spawn(async move { manager.close_session("s").await });
        settle().await;
        assert!(!closing.is_finished());
        tokio::time::advance(Duration::from_secs(1)).await;
        let result = closing.await.unwrap();
        if fails {
            assert_eq!(result.unwrap_err().code, "browser_stop_unconfirmed");
        } else {
            result.unwrap();
            assert!(popup.is_closed());
        }
        assert!(!context.page(1).is_closed());
        assert_eq!(context.stats().1, 0);
        f.manager.close_session("peer").await.unwrap();
        f.manager.shutdown().await;
    }
}

#[tokio::test(start_paused = true)]
async fn failed_initial_page_cleanup_is_not_forgotten_by_a_later_close() {
    let context = FakeContext::new();
    context.fail_page.store(true, Ordering::SeqCst);
    context.fail_close.store(true, Ordering::SeqCst);
    let f = ready(&context);
    assert!(
        f.manager
            .handle(target("s", "w"), "release".into(), json!({}))
            .await
            .is_err()
    );
    assert_eq!(
        f.manager.close_session("s").await.unwrap_err().code,
        "browser_stop_unconfirmed"
    );
    context.crash();
    f.manager.shutdown().await;
}

#[tokio::test]
async fn foreground_authority_survives_spawn_and_is_rechecked_after_shared_launch() {
    for abortable in [false, true] {
        let (fixture, open, started) = gated_manager();
        let manager = fixture.manager.clone();
        let allowed = Arc::new(Mutex::new(true));
        let guard = crate::browser::effects::Guard::new({
            let allowed = allowed.clone();
            move |effect| {
                let allowed = allowed.lock().unwrap();
                if !*allowed {
                    return Err(ApiError::new(
                        409,
                        "lost_control",
                        "revoked while launching",
                    ));
                }
                effect();
                Ok(())
            }
        });
        let request = tokio::spawn(crate::browser::effects::scope(guard, async move {
            if abortable {
                let (_send, recv) = watch::channel(false);
                manager
                    .handle_with_abort(target("source", "w"), "snapshot".into(), json!({}), recv)
                    .await
            } else {
                manager
                    .handle(target("source", "w"), "snapshot".into(), json!({}))
                    .await
            }
        }));
        started.await.unwrap();
        *allowed.lock().unwrap() = false;
        let context = FakeContext::new();
        open.send(context.clone()).ok().unwrap();
        assert_eq!(request.await.unwrap().unwrap_err().code, "lost_control");
        assert_eq!(context.stats(), (0, 1));
        fixture.manager.shutdown().await;
    }
}

/// Real Node authority and durable receipts, with only Chromium substituted.
#[tokio::test]
async fn resource_retirement_survives_takeover_and_preserves_a_shared_peer() {
    use crate::browser::{effects, tracked::Tracked};
    use crate::store::Store;
    let node_fixture = crate::workspace_memory::tests::Fixture::new().await;
    let node = &node_fixture.node;
    let root: PathBuf = node
        .db
        .lock()
        .get_workspace("repo")
        .unwrap()
        .canonical_path
        .into();
    let peer = node
        .db
        .lock()
        .create_session("repo", root.join("peer-history").to_str().unwrap(), "alice")
        .unwrap();
    let source = BrowserTarget {
        session_id: node_fixture.current.clone(),
        workspace_id: "repo".into(),
        root: root.clone(),
    };
    let peer_target = BrowserTarget {
        session_id: peer.id.clone(),
        ..source.clone()
    };
    // Exit with an encoding error after EOF: closure must still be confirmed.
    let scripts = tempfile::tempdir().unwrap();
    let ffmpeg = fake_ffmpeg(
        scripts.path(),
        "while read -r _; do :; done; printf done >&3; exit 3",
    );
    let context = FakeContext::new();
    let fixture = with_ffmpeg(&context, &ffmpeg);
    let manager = &fixture.manager;
    let tracked = Tracked::new(Arc::downgrade(node), manager.clone());
    let phone = node
        .db
        .lock()
        .acquire_lease(&source.session_id, "phone", false, 60_000)
        .unwrap();
    let open = Arc::new(Mutex::new(true));
    effects::from(
        effects::Caller::Viewer {
            client: "phone".into(),
            generation: phone.generation,
            open: open.clone(),
        },
        tracked.handle(source.clone(), "snapshot".into(), json!({})),
    )
    .await
    .unwrap();
    effects::from(
        effects::Caller::Test,
        tracked.handle(peer_target, "snapshot".into(), json!({})),
    )
    .await
    .unwrap();
    let tab = manager.inner.lock().tabs[&source.session_id].clone();
    let resource = tab
        .resource
        .clone()
        .expect("the resource must survive the foreground spawn");
    let web = node
        .db
        .lock()
        .acquire_lease(&source.session_id, "web", true, 60_000)
        .unwrap();
    *open.lock().unwrap() = false;
    node.db
        .lock()
        .execute(
            "UPDATE sessions SET runner_epoch=1 WHERE id=?1",
            [&source.session_id],
        )
        .unwrap();
    assert!(
        resource.run(|| ()).is_ok(),
        "a takeover/new agent is not resource revocation"
    );
    let (sink, source_frames) = viewer();
    let source_detach = tracked.attach(&source.session_id, sink);
    let (sink, peer_frames) = viewer();
    let peer_detach = tracked.attach(&peer.id, sink);
    settle().await;
    let recorded = effects::from(
        effects::Caller::Agent {
            epoch: 1,
            abort: Arc::new(watch::channel(false).0),
        },
        tracked.handle(source.clone(), "record".into(), json!({"action":"start"})),
    )
    .await
    .unwrap();
    let late_sink = context.page(0).cast.lock().unwrap().clone().unwrap();
    let old_frame = tab.lock().last_frame.as_ref().unwrap().jpeg.clone();
    source_frames.lock().unwrap().clear();
    // A title request already waiting at revocation cannot publish its result.
    context
        .page(0)
        .title_delays
        .lock()
        .unwrap()
        .push_back(Duration::from_millis(400));
    manager.inner.emit_state(&tab);
    settle().await;
    crate::execution_fences::accept(
        &node.db.lock(),
        "alice",
        &source.session_id,
        &crate::execution_fences::Intent {
            operation_id: "background-retire".into(),
            plan_hash: "c".repeat(64),
            expected_workspace_id: "repo".into(),
            expected_runner_epoch: 1,
        },
        "web",
        web.generation,
    )
    .unwrap();
    source_frames.lock().unwrap().clear();
    late_sink(ScreencastFrame {
        jpeg: Arc::new(b"revoked-frame".to_vec()),
        width: 800,
        height: 600,
    });
    assert_eq!(*tab.lock().last_frame.as_ref().unwrap().jpeg, *old_frame);
    let popup = FakePage::new("https://late.example");
    context.page(0).emit(|| PageEvent::Popup(popup.clone()));
    context.page(1).frame(b"peer-live");
    tokio::time::timeout(Duration::from_secs(5), async {
        while !tab.closed() || !popup.is_closed() {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap();
    tracked.close_session(&source.session_id).await.unwrap();
    let summary = serde_json::to_value(
        crate::browser::journal::summary(&node.db.lock(), &source.session_id).unwrap(),
    )
    .unwrap();
    assert_eq!(summary["unresolved"], 0);
    assert_eq!(summary["observersSettled"], 1);
    assert!(!popup.shows_actions.load(Ordering::SeqCst));
    assert_eq!(context.stats().1, 0, "a peer still owns this context");
    assert!(context.page(1).casting());
    assert!(sent_frames(&peer_frames).contains(&"peer-live".to_owned()));
    assert!(!sent_frames(&source_frames).contains(&"revoked-frame".to_owned()));
    assert!(
        of_type(&source_frames, "state")
            .iter()
            .all(|message| message["state"]["title"] != "Fake")
    );
    let output = root.join(recorded["path"].as_str().unwrap());
    assert_eq!(std::fs::read(output).unwrap(), b"done");
    source_detach();
    peer_detach();
    tracked.close_session(&peer.id).await.unwrap();
    tracked.shutdown().await;
    node.close().await;
}

#[tokio::test]
async fn a_revoked_record_start_does_not_create_files_after_a_page_wait() {
    use crate::browser::effects;
    let context = FakeContext::new();
    let (release, wait) = oneshot::channel();
    *context.page_gate.lock().unwrap() = Some(wait);
    let fixture = ready(&context);
    let root = tempfile::tempdir().unwrap();
    let target = BrowserTarget {
        root: root.path().to_owned(),
        ..target("source", "w")
    };
    let allowed = Arc::new(Mutex::new(true));
    let guard = effects::Guard::new({
        let allowed = allowed.clone();
        move |effect| {
            if !*allowed.lock().unwrap() {
                return Err(ApiError::conflict("revoked"));
            }
            effect();
            Ok(())
        }
    });
    let manager = fixture.manager.clone();
    let request = tokio::spawn(effects::scope(guard, async move {
        manager
            .handle(target, "record".into(), json!({"action":"start"}))
            .await
    }));
    tokio::time::timeout(Duration::from_secs(3), async {
        while context.page_gate.lock().unwrap().is_some() {
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
    *allowed.lock().unwrap() = false;
    release.send(()).unwrap();
    assert!(request.await.unwrap().is_err());
    assert!(!root.path().join(".pirc").exists());
    fixture.manager.close_session("source").await.unwrap();
    fixture.manager.shutdown().await;
}
