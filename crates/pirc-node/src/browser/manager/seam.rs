//! The manager's view of the engine: the few calls `node/browser.ts` made
//! on Playwright's `BrowserContext`, `Page`, `Frame` and `Locator`, as
//! object-safe traits. The real implementations below forward to
//! [`crate::browser::engine`]; the manager's unit tests put a fake context
//! behind [`Launcher`] (TS's `settings.launch` test hook), so the session
//! lifecycle is tested without Chromium.
//!
//! Pages are compared by identity (`Arc::ptr_eq`), as TS compared `Page`
//! objects: the engine hands out one `Arc<Page>` per page, which coerces
//! to the same [`PageRef`].

use std::collections::BTreeMap;
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use futures_util::StreamExt as _;
use futures_util::stream::BoxStream;
use serde_json::Value;

use super::LazyHosts;
use crate::browser::BoxFuture;
use crate::browser::engine::context::{Context, LaunchOptions};
use crate::browser::engine::frame::Frame;
use crate::browser::engine::locator::{Locator, WaitState};
use crate::browser::engine::page::{self, Page};
use crate::browser::engine::screencast::{ScreencastFrame, ScreencastOptions};
use crate::browser::engine::screenshot::ScreenshotOptions;
use crate::browser::engine::{LoadState, MouseButton, Result};

pub type PageRef = Arc<dyn PageApi>;
pub type ContextRef = Arc<dyn ContextApi>;
pub type FrameSink = Arc<dyn Fn(ScreencastFrame) + Send + Sync>;

/// Starts a workspace's context (`chromium.launchPersistentContext`).
pub trait Launcher: Send + Sync {
    /// The error is the reason ("Could not start the browser: <first line>").
    /// `hosts` is the guard every request of the context goes through
    /// (created on first use).
    fn launch(
        &self,
        executable: &Path,
        profile_dir: &Path,
        viewport: (u32, u32),
        env: BTreeMap<String, String>,
        hosts: Arc<LazyHosts>,
    ) -> BoxFuture<'static, std::result::Result<ContextRef, String>>;
}

/// The real Chromium ([`Context::launch`]).
pub struct ChromiumLauncher;

impl Launcher for ChromiumLauncher {
    fn launch(
        &self,
        executable: &Path,
        profile_dir: &Path,
        viewport: (u32, u32),
        env: BTreeMap<String, String>,
        hosts: Arc<LazyHosts>,
    ) -> BoxFuture<'static, std::result::Result<ContextRef, String>> {
        let executable = executable.to_owned();
        let profile_dir = profile_dir.to_owned();
        Box::pin(async move {
            let context = Context::launch(
                &executable,
                &profile_dir,
                LaunchOptions { viewport, env },
                hosts.get(),
            )
            .await?;
            Ok(context as ContextRef)
        })
    }
}

/// `BrowserContext` as the manager uses it.
pub trait ContextApi: Send + Sync {
    fn pages(&self) -> Vec<PageRef>;
    fn new_page(&self) -> BoxFuture<'_, Result<PageRef>>;
    /// Resolves when the context is gone (`close` event).
    fn closed(&self) -> BoxFuture<'_, ()>;
    fn close(&self) -> BoxFuture<'_, ()>;
}

impl ContextApi for Context {
    fn pages(&self) -> Vec<PageRef> {
        Context::pages(self)
            .into_iter()
            .map(|page| page as PageRef)
            .collect()
    }

    fn new_page(&self) -> BoxFuture<'_, Result<PageRef>> {
        Box::pin(async move { Ok(Context::new_page(self).await? as PageRef) })
    }

    fn closed(&self) -> BoxFuture<'_, ()> {
        Box::pin(Context::closed(self))
    }

    fn close(&self) -> BoxFuture<'_, ()> {
        Box::pin(Context::close(self))
    }
}

/// What the manager listens to on a page (`popup`, `framenavigated` of
/// the main frame, `load`, `close`).
pub enum PageEvent {
    Popup(PageRef),
    MainFrameNavigated,
    Load,
    Closed,
}

/// Which locator (`page.locator('aria-ref=…')`, `page.getByText(…).first()`).
pub enum Selector {
    AriaRef(String),
    TextFirst(String),
}

/// `Page` as the manager uses it.
pub trait PageApi: Send + Sync {
    /// Attach resource authority to already-running engine background tasks.
    fn bind_resource(&self, guard: crate::browser::effects::Guard) -> crate::error::ApiResult<()>;
    /// Events from now on, ending after [`PageEvent::Closed`].
    fn subscribe(&self) -> BoxStream<'static, PageEvent>;
    fn url(&self) -> String;
    fn title(&self) -> BoxFuture<'_, Result<String>>;
    fn content(&self) -> BoxFuture<'_, Result<String>>;
    fn frames(&self) -> Vec<Arc<dyn FrameApi>>;
    /// `page.goto`: the main frame's response status, if any.
    fn goto<'a>(
        &'a self,
        url: &'a str,
        wait_until: LoadState,
        timeout: Duration,
    ) -> BoxFuture<'a, Result<Option<u16>>>;
    fn go_back(&self, wait_until: LoadState, timeout: Duration) -> BoxFuture<'_, Result<()>>;
    fn go_forward(&self, timeout: Duration) -> BoxFuture<'_, Result<()>>;
    fn reload(&self, timeout: Duration) -> BoxFuture<'_, Result<()>>;
    fn wait_for_load_state(&self, state: LoadState, timeout: Duration)
    -> BoxFuture<'_, Result<()>>;
    /// `page.evaluate(fn)` in the main frame.
    fn evaluate<'a>(&'a self, function: &'a str) -> BoxFuture<'a, Result<Value>>;
    /// `page.ariaSnapshot({mode: 'ai', timeout})`.
    fn aria_snapshot(&self, timeout: Duration) -> BoxFuture<'_, Result<String>>;
    fn locator(self: Arc<Self>, selector: Selector) -> Box<dyn LocatorApi>;
    /// `page.keyboard.press(key)`.
    fn press<'a>(&'a self, key: &'a str) -> BoxFuture<'a, Result<()>>;
    fn insert_text<'a>(&'a self, text: &'a str) -> BoxFuture<'a, Result<()>>;
    fn mouse_move(&self, x: f64, y: f64) -> BoxFuture<'_, Result<()>>;
    fn mouse_down(&self, button: MouseButton, click_count: u32) -> BoxFuture<'_, Result<()>>;
    fn mouse_up(&self, button: MouseButton, click_count: u32) -> BoxFuture<'_, Result<()>>;
    fn mouse_wheel(&self, dx: f64, dy: f64) -> BoxFuture<'_, Result<()>>;
    fn screenshot(&self, options: ScreenshotOptions) -> BoxFuture<'_, Result<Vec<u8>>>;
    fn start_screencast(
        &self,
        options: ScreencastOptions,
        sink: FrameSink,
    ) -> BoxFuture<'_, Result<()>>;
    fn stop_screencast(&self) -> BoxFuture<'_, Result<()>>;
    /// `page.screencast.showActions({duration: 600})`: Playwright's action
    /// overlay (every later input action shows on the page and takes
    /// 600 ms longer).
    fn show_actions(&self) -> BoxFuture<'_, Result<()>>;
    fn bring_to_front(&self) -> BoxFuture<'_, Result<()>>;
    fn close(&self) -> BoxFuture<'_, Result<()>>;
    fn is_closed(&self) -> bool;
    /// The main frame's CDP frame id, for the host guard's refused redirect
    /// hops (`HostGuard::refused_hop`); "" (none) by default.
    fn main_frame_id(&self) -> String {
        String::new()
    }
}

/// `Frame` as the manager uses it.
pub trait FrameApi: Send + Sync {
    fn url(&self) -> String;
    /// `frame.evaluate(fn)`: called without an argument.
    fn evaluate<'a>(&'a self, function: &'a str) -> BoxFuture<'a, Result<Value>>;
    /// The CDP frame id, as [`PageApi::main_frame_id`]; "" by default.
    fn id(&self) -> String {
        String::new()
    }
}

/// `Locator` as the manager uses it.
pub trait LocatorApi: Send + Sync {
    fn click(
        &self,
        button: MouseButton,
        click_count: u32,
        timeout: Duration,
    ) -> BoxFuture<'_, Result<()>>;
    fn hover(&self, timeout: Duration) -> BoxFuture<'_, Result<()>>;
    fn fill<'a>(&'a self, value: &'a str, timeout: Duration) -> BoxFuture<'a, Result<()>>;
    fn press_sequentially<'a>(
        &'a self,
        text: &'a str,
        delay: Duration,
        timeout: Duration,
    ) -> BoxFuture<'a, Result<()>>;
    fn press<'a>(&'a self, key: &'a str, timeout: Duration) -> BoxFuture<'a, Result<()>>;
    fn select_option<'a>(
        &'a self,
        values: &'a [String],
        timeout: Duration,
    ) -> BoxFuture<'a, Result<Vec<String>>>;
    /// `locator.evaluate(fn, undefined, {timeout})`.
    fn evaluate<'a>(&'a self, function: &'a str, timeout: Duration)
    -> BoxFuture<'a, Result<Value>>;
    fn wait_for(&self, state: WaitState, timeout: Duration) -> BoxFuture<'_, Result<()>>;
}

/// Calls `function` (a function's source) without arguments: Playwright's
/// `evaluate(fn)` passes `undefined`, which `sensitiveField` tells apart
/// from `null` (only then does it look through shadow roots), while the
/// engine always passes a JSON value.
pub fn without_argument(function: &str) -> String {
    format!("() => (\n{function}\n)()")
}

impl PageApi for Page {
    fn bind_resource(&self, guard: crate::browser::effects::Guard) -> crate::error::ApiResult<()> {
        Page::bind_resource(self, guard)
    }

    fn subscribe(&self) -> BoxStream<'static, PageEvent> {
        futures_util::stream::unfold(Page::subscribe(self), |mut events| async move {
            let event = match events.recv().await? {
                page::PageEvent::Popup(popup) => PageEvent::Popup(popup as PageRef),
                page::PageEvent::MainFrameNavigated => PageEvent::MainFrameNavigated,
                page::PageEvent::Load => PageEvent::Load,
                page::PageEvent::Closed => PageEvent::Closed,
            };
            Some((event, events))
        })
        .boxed()
    }

    fn url(&self) -> String {
        Page::url(self)
    }

    fn title(&self) -> BoxFuture<'_, Result<String>> {
        Box::pin(Page::title(self))
    }

    fn content(&self) -> BoxFuture<'_, Result<String>> {
        Box::pin(Page::content(self))
    }

    fn frames(&self) -> Vec<Arc<dyn FrameApi>> {
        Page::frames(self)
            .into_iter()
            .map(|frame| Arc::new(frame) as Arc<dyn FrameApi>)
            .collect()
    }

    fn goto<'a>(
        &'a self,
        url: &'a str,
        wait_until: LoadState,
        timeout: Duration,
    ) -> BoxFuture<'a, Result<Option<u16>>> {
        Box::pin(async move {
            Ok(Page::goto(self, url, wait_until, timeout)
                .await?
                .map(|response| response.status))
        })
    }

    fn go_back(&self, wait_until: LoadState, timeout: Duration) -> BoxFuture<'_, Result<()>> {
        Box::pin(Page::go_back(self, wait_until, timeout))
    }

    fn go_forward(&self, timeout: Duration) -> BoxFuture<'_, Result<()>> {
        Box::pin(Page::go_forward(self, timeout))
    }

    fn reload(&self, timeout: Duration) -> BoxFuture<'_, Result<()>> {
        Box::pin(Page::reload(self, timeout))
    }

    fn wait_for_load_state(
        &self,
        state: LoadState,
        timeout: Duration,
    ) -> BoxFuture<'_, Result<()>> {
        Box::pin(Page::wait_for_load_state(self, state, timeout))
    }

    fn evaluate<'a>(&'a self, function: &'a str) -> BoxFuture<'a, Result<Value>> {
        Box::pin(
            async move { Page::evaluate(self, &without_argument(function), Value::Null).await },
        )
    }

    fn aria_snapshot(&self, timeout: Duration) -> BoxFuture<'_, Result<String>> {
        Box::pin(crate::browser::engine::snapshot::aria_snapshot(
            self, timeout,
        ))
    }

    fn locator(self: Arc<Self>, selector: Selector) -> Box<dyn LocatorApi> {
        Box::new(match selector {
            Selector::AriaRef(reference) => Locator::aria_ref(&self, &reference),
            Selector::TextFirst(text) => Locator::text_first(&self, &text),
        })
    }

    fn press<'a>(&'a self, key: &'a str) -> BoxFuture<'a, Result<()>> {
        Box::pin(self.keyboard().press(key, Duration::ZERO))
    }

    fn insert_text<'a>(&'a self, text: &'a str) -> BoxFuture<'a, Result<()>> {
        Box::pin(self.keyboard().insert_text(text))
    }

    fn mouse_move(&self, x: f64, y: f64) -> BoxFuture<'_, Result<()>> {
        Box::pin(async move {
            let modifiers = self.keyboard().modifiers();
            self.mouse().move_to(x, y, modifiers).await
        })
    }

    fn mouse_down(&self, button: MouseButton, click_count: u32) -> BoxFuture<'_, Result<()>> {
        Box::pin(async move {
            let modifiers = self.keyboard().modifiers();
            self.mouse().down(button, click_count, modifiers).await
        })
    }

    fn mouse_up(&self, button: MouseButton, click_count: u32) -> BoxFuture<'_, Result<()>> {
        Box::pin(async move {
            let modifiers = self.keyboard().modifiers();
            self.mouse().up(button, click_count, modifiers).await
        })
    }

    fn mouse_wheel(&self, dx: f64, dy: f64) -> BoxFuture<'_, Result<()>> {
        Box::pin(async move {
            let modifiers = self.keyboard().modifiers();
            self.mouse().wheel(dx, dy, modifiers).await
        })
    }

    fn screenshot(&self, options: ScreenshotOptions) -> BoxFuture<'_, Result<Vec<u8>>> {
        Box::pin(Page::screenshot(self, options))
    }

    fn start_screencast(
        &self,
        options: ScreencastOptions,
        sink: FrameSink,
    ) -> BoxFuture<'_, Result<()>> {
        Box::pin(Page::start_screencast(self, options, sink))
    }

    fn stop_screencast(&self) -> BoxFuture<'_, Result<()>> {
        Box::pin(Page::stop_screencast(self))
    }

    fn show_actions(&self) -> BoxFuture<'_, Result<()>> {
        crate::browser::engine::screencast::show_actions(
            self,
            Some(crate::browser::engine::screencast::ShowActions {
                duration: std::time::Duration::from_millis(600),
            }),
        );
        Box::pin(async { Ok(()) })
    }

    fn bring_to_front(&self) -> BoxFuture<'_, Result<()>> {
        Box::pin(Page::bring_to_front(self))
    }

    fn close(&self) -> BoxFuture<'_, Result<()>> {
        Box::pin(Page::close(self))
    }

    fn is_closed(&self) -> bool {
        Page::is_closed(self)
    }

    fn main_frame_id(&self) -> String {
        self.main_frame().id().to_owned()
    }
}

impl FrameApi for Frame {
    fn url(&self) -> String {
        Frame::url(self)
    }

    fn evaluate<'a>(&'a self, function: &'a str) -> BoxFuture<'a, Result<Value>> {
        Box::pin(
            async move { Frame::evaluate(self, &without_argument(function), Value::Null).await },
        )
    }

    fn id(&self) -> String {
        Frame::id(self).to_owned()
    }
}

impl LocatorApi for Locator {
    fn click(
        &self,
        button: MouseButton,
        click_count: u32,
        timeout: Duration,
    ) -> BoxFuture<'_, Result<()>> {
        Box::pin(Locator::click(self, button, click_count, timeout))
    }

    fn hover(&self, timeout: Duration) -> BoxFuture<'_, Result<()>> {
        Box::pin(Locator::hover(self, timeout))
    }

    fn fill<'a>(&'a self, value: &'a str, timeout: Duration) -> BoxFuture<'a, Result<()>> {
        Box::pin(Locator::fill(self, value, timeout))
    }

    fn press_sequentially<'a>(
        &'a self,
        text: &'a str,
        delay: Duration,
        timeout: Duration,
    ) -> BoxFuture<'a, Result<()>> {
        Box::pin(Locator::press_sequentially(self, text, delay, timeout))
    }

    fn press<'a>(&'a self, key: &'a str, timeout: Duration) -> BoxFuture<'a, Result<()>> {
        Box::pin(Locator::press(self, key, timeout))
    }

    fn select_option<'a>(
        &'a self,
        values: &'a [String],
        timeout: Duration,
    ) -> BoxFuture<'a, Result<Vec<String>>> {
        Box::pin(Locator::select_option(self, values, timeout))
    }

    fn evaluate<'a>(
        &'a self,
        function: &'a str,
        timeout: Duration,
    ) -> BoxFuture<'a, Result<Value>> {
        Box::pin(Locator::evaluate(self, function, timeout))
    }

    fn wait_for(&self, state: WaitState, timeout: Duration) -> BoxFuture<'_, Result<()>> {
        Box::pin(Locator::wait_for(self, state, timeout))
    }
}
