//! The agent's operations (`handle`, `run`, `operate`, `goto`,
//! `pageSummary`, `record` of `browser.ts`) and the waits for the user.

use std::sync::Arc;
use std::time::Duration;

use pirc_agent::tools::js::truthy;
use serde_json::{Map, Value, json};

use futures_util::{FutureExt as _, StreamExt as _};

use super::seam::{PageEvent, PageRef, Selector};
use super::view::base64;
use super::{
    ActiveRecording, Inner, LastFrame, Mode, OpError, OpResult, Signal, Tab, closing_error, spawn,
};
use crate::browser::BrowserTarget;
use crate::browser::assets::{PAGE_MARKDOWN, PASSWORD_VALUES, SENSITIVE_FIELD};
use crate::browser::engine::LoadState;
use crate::browser::engine::MouseButton;
use crate::browser::engine::locator::WaitState;
use crate::browser::engine::screenshot::ScreenshotOptions;
use crate::browser::hosts::blocked_error;
use crate::browser::recording::{FrameSource, RECORD_MAX, Recording, StillCurrent};
use crate::browser::util::{
    arg, check_url, clean_error, clip, describe, file_stamp, int_arg, js_string, mask_passwords,
    recording_name, ref_arg, str_arg, utf16_len,
};
use crate::error::{ApiError, ApiResult};

const SNAPSHOT_CHARS: i64 = 30_000;
const FETCH_CHARS: i64 = 40_000;
const MAX_CHARS: i64 = 200_000;
/// How long an agent operation waits for the user by default (`AGENT_WAIT_MS`).
const AGENT_WAIT_MS: i64 = 5 * 60_000;
/// Keys the agent may press on a secret field: they move focus or submit,
/// never insert text.
const SAFE_KEYS_ON_SECRET: [&str; 4] = ["Enter", "Tab", "Shift+Tab", "Escape"];

const fn ms(value: u64) -> Duration {
    Duration::from_millis(value)
}

fn password_field_error() -> ApiError {
    ApiError::new(
        403,
        "password_field",
        "The agent does not type into password or other secret fields. Use browser_handoff so the user can enter it.",
    )
}

fn aborted() -> ApiError {
    ApiError::new(499, "aborted", "Aborted")
}

/// `settle(page)`: DOM content loaded (5 s at most), then 250 ms.
async fn settle(page: &PageRef) {
    let _ = page
        .wait_for_load_state(LoadState::DomContentLoaded, ms(5_000))
        .await;
    tokio::time::sleep(ms(250)).await;
}

fn values_of(value: Value) -> Vec<String> {
    match value {
        Value::Array(items) => items
            .into_iter()
            .filter_map(|item| match item {
                Value::String(text) => Some(text),
                _ => None,
            })
            .collect(),
        _ => Vec::new(),
    }
}

fn text_of(value: Value) -> String {
    match value {
        Value::String(text) => text,
        Value::Null => String::new(),
        other => pirc_agent::tools::js::string_of(&other),
    }
}

impl Inner {
    /// `handle(target, op, args, signal)`: one agent `browser_request`.
    pub(super) async fn handle(
        self: Arc<Self>,
        target: BrowserTarget,
        op: String,
        args: Value,
        signal: Signal,
    ) -> ApiResult<Value> {
        self.require()?;
        crate::browser::effects::check()?;
        if op == "close" {
            self.close_session(&target.session_id).await?;
            return Ok(json!({ "closed": true }));
        }
        let _lease = self.begin_operation(&target.session_id)?;
        let tab = self
            .tab(&target, op != "status")
            .await
            .map_err(OpError::into_api)?;
        crate::browser::effects::check()?;
        if self.session_closing(&target.session_id) {
            return Err(closing_error());
        }
        if op == "status" {
            return Ok(self.view(tab.as_deref()));
        }
        let Some(tab) = tab else {
            return Err(ApiError::new(500, "browser_error", "No browser tab"));
        };
        tab.touch();
        match op.as_str() {
            "handoff" => {
                let reason = str_arg(arg(&args, "reason"), "reason", 2_000)?.to_owned();
                crate::browser::effects::run(|| {
                    self.set_mode(&tab, Mode::User, Some(reason.clone()))
                })?;
                self.log(
                    &tab,
                    "agent",
                    &format!("Handed control to the user: {reason}"),
                    None,
                );
                return Ok(self.view(Some(&tab)));
            }
            "wait_control" => {
                self.wait_for_agent_mode(&tab, &signal, 0).await?;
                return self
                    .page_summary(&tab, true, &Value::Null)
                    .await
                    .map_err(OpError::into_api);
            }
            "release" => {
                if tab.lock().mode == Mode::User {
                    crate::browser::effects::run(|| self.set_mode(&tab, Mode::Agent, None))?;
                    self.log(&tab, "agent", "Took back control", None);
                }
                return Ok(self.view(Some(&tab)));
            }
            "record" => return self.record(&tab, &args).await,
            _ => {}
        }
        let _busy = tab.busy.lock().await;
        crate::browser::effects::check()?;
        if self.session_closing(&target.session_id) {
            return Err(closing_error());
        }
        if signal.aborted() {
            // `signal.throwIfAborted()`: nobody waits for this answer.
            return Err(ApiError::new(
                500,
                "browser_error",
                "This operation was aborted",
            ));
        }
        let wait = int_arg(arg(&args, "waitMs"), AGENT_WAIT_MS, 0, 30 * 60_000);
        self.wait_for_agent_mode(&tab, &signal, wait).await?;
        crate::browser::effects::check()?;
        self.run(&tab, &op, &args).await
    }

    /// `waitForAgentMode(tab, signal, timeoutMs)`: resolves in agent mode;
    /// `timeout_ms` 0 waits as long as it takes.
    pub(super) async fn wait_for_agent_mode(
        self: &Arc<Self>,
        tab: &Arc<Tab>,
        signal: &Signal,
        timeout_ms: i64,
    ) -> ApiResult<()> {
        if signal.aborted() {
            return Err(aborted());
        }
        let (id, mut woken) = {
            let state = self.lock();
            if state.closing_sessions.contains(tab.session()) {
                return Err(closing_error());
            }
            let mut st = tab.lock();
            if st.mode == Mode::Agent {
                return Ok(());
            }
            st.waiting += 1;
            self.emit_state_with(tab, &st);
            let (wake, woken) = tokio::sync::oneshot::channel();
            let id = self.next_seq();
            st.waiters.push((id, wake));
            (id, woken)
        };
        let error = tokio::select! {
            result = &mut woken => return result.unwrap_or(None).map_or(Ok(()), Err),
            () = signal.wait() => aborted(),
            () = tokio::time::sleep(ms(timeout_ms.max(0) as u64)), if timeout_ms > 0 => {
                ApiError::new(
                    409,
                    "user_in_control",
                    "The user still controls the browser. Wait, or ask them to return control.",
                )
            }
        };
        {
            let mut st = tab.lock();
            if let Some(position) = st.waiters.iter().position(|(waiter, _)| *waiter == id) {
                st.waiters.remove(position);
                st.waiting = st.waiting.saturating_sub(1);
                self.emit_state_with(tab, &st);
                return Err(error);
            }
        }
        // Woken at the same time: the waker's answer counts.
        match woken.try_recv() {
            Ok(None) => Ok(()),
            Ok(Some(woken)) => Err(woken),
            Err(_) => Err(error),
        }
    }

    /// `run(tab, op, args)`: one serialized operation, shown to viewers
    /// while it runs and logged after.
    async fn run(self: &Arc<Self>, tab: &Arc<Tab>, op: &str, args: &Value) -> ApiResult<Value> {
        if tab.active().is_none() {
            self.new_page(tab).await.map_err(OpError::into_api)?;
        }
        let label = describe(op, args);
        {
            let mut st = tab.lock();
            st.action = Some(label.clone());
            self.emit_state_with(tab, &st);
        }
        let result = match self.operate(tab, op, args).await {
            Ok(result) => {
                let jpeg = self.thumbnail(tab.active()).await;
                self.log(tab, "agent", &label, jpeg);
                Ok(result)
            }
            Err(error) => {
                self.log(tab, "agent", &format!("{label} (failed)"), None);
                Err(match error {
                    OpError::Api(error) => error,
                    OpError::Engine(error) => {
                        ApiError::new(400, "browser_error", clean_error(&error.message))
                    }
                })
            }
        };
        {
            let mut st = tab.lock();
            st.action = None;
            st.last_activity = tokio::time::Instant::now();
            self.emit_state_with(tab, &st);
        }
        result
    }

    async fn operate(self: &Arc<Self>, tab: &Arc<Tab>, op: &str, args: &Value) -> OpResult<Value> {
        let Some(page) = tab.active() else {
            return Err(ApiError::new(500, "browser_error", "No active page").into());
        };
        let snapshot = arg(args, "snapshot") != Some(&Value::Bool(false));
        match op {
            "fetch" => {
                let status = self.goto(&page, &check_url(arg(args, "url"))?).await?;
                let format = arg(args, "format")
                    .and_then(Value::as_str)
                    .filter(|format| matches!(*format, "text" | "html"))
                    .unwrap_or("markdown");
                let raw = match format {
                    "html" => page.content().await?,
                    "text" => text_of(
                        page.evaluate("() => globalThis.document.body?.innerText ?? \"\"")
                            .await?,
                    ),
                    _ => text_of(page.evaluate(PAGE_MARKDOWN).await?),
                };
                let url = page.url();
                let title = page.title().await?;
                let clipped = clip(
                    &raw,
                    int_arg(arg(args, "offset"), 0, 0, 1_000_000_000) as usize,
                    int_arg(arg(args, "maxChars"), FETCH_CHARS, 1_000, MAX_CHARS) as usize,
                );
                Ok(json!({
                    "url": url,
                    "title": title,
                    "status": status,
                    "format": format,
                    "content": clipped.content,
                    "offset": clipped.offset,
                    "totalChars": clipped.total_chars,
                    "truncated": clipped.truncated,
                }))
            }
            "navigate" => {
                if arg(args, "url").and_then(Value::as_str) == Some("back") {
                    page.go_back(LoadState::DomContentLoaded, ms(15_000))
                        .await?;
                    settle(&page).await;
                    return self.page_summary(tab, true, &Value::Null).await;
                }
                let status = self.goto(&page, &check_url(arg(args, "url"))?).await?;
                let summary = self.page_summary(tab, true, &Value::Null).await?;
                let mut result = Map::new();
                result.insert("status".into(), json!(status));
                if let Value::Object(summary) = summary {
                    result.extend(summary);
                }
                Ok(Value::Object(result))
            }
            "back" => {
                page.go_back(LoadState::DomContentLoaded, ms(15_000))
                    .await?;
                self.page_summary(tab, true, &Value::Null).await
            }
            "snapshot" => self.page_summary(tab, true, args).await,
            "click" => {
                let locator = page
                    .clone()
                    .locator(Selector::AriaRef(ref_arg(arg(args, "ref"))?.into()));
                let button = MouseButton::parse(arg(args, "button").and_then(Value::as_str));
                let count = if arg(args, "double") == Some(&Value::Bool(true)) {
                    2
                } else {
                    1
                };
                locator.click(button, count, ms(10_000)).await?;
                settle(&page).await;
                self.page_summary(tab, snapshot, &Value::Null).await
            }
            "hover" => {
                let locator = page
                    .clone()
                    .locator(Selector::AriaRef(ref_arg(arg(args, "ref"))?.into()));
                locator.hover(ms(10_000)).await?;
                self.page_summary(tab, snapshot, &Value::Null).await
            }
            "type" => {
                let locator = page
                    .clone()
                    .locator(Selector::AriaRef(ref_arg(arg(args, "ref"))?.into()));
                let text = arg(args, "text")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                if utf16_len(text) > 20_000 {
                    return Err(ApiError::bad_request("text is too long").into());
                }
                if truthy(Some(&locator.evaluate(SENSITIVE_FIELD, ms(10_000)).await?)) {
                    return Err(password_field_error().into());
                }
                if arg(args, "slowly") == Some(&Value::Bool(true)) {
                    if arg(args, "clear") != Some(&Value::Bool(false)) {
                        locator.fill("", ms(10_000)).await?;
                    }
                    locator.press_sequentially(text, ms(20), ms(30_000)).await?;
                } else {
                    locator.fill(text, ms(10_000)).await?;
                }
                if arg(args, "submit") == Some(&Value::Bool(true)) {
                    locator.press("Enter", ms(10_000)).await?;
                }
                settle(&page).await;
                self.page_summary(tab, snapshot, &Value::Null).await
            }
            "select" => {
                let values: Vec<String> = match arg(args, "values") {
                    Some(Value::Array(values)) => values
                        .iter()
                        .filter_map(Value::as_str)
                        .take(50)
                        .map(str::to_owned)
                        .collect(),
                    _ => Vec::new(),
                };
                if values.is_empty() {
                    return Err(ApiError::bad_request("values must list options").into());
                }
                let locator = page
                    .clone()
                    .locator(Selector::AriaRef(ref_arg(arg(args, "ref"))?.into()));
                locator.select_option(&values, ms(10_000)).await?;
                settle(&page).await;
                self.page_summary(tab, snapshot, &Value::Null).await
            }
            "press" => {
                let key = str_arg(arg(args, "key"), "key", 100)?;
                // After a click into a password field, keys would type the
                // secret one by one.
                if !SAFE_KEYS_ON_SECRET.contains(&key) {
                    for frame in page.frames() {
                        let sensitive = frame
                            .evaluate(SENSITIVE_FIELD)
                            .await
                            .unwrap_or(Value::Bool(false));
                        if truthy(Some(&sensitive)) {
                            return Err(password_field_error().into());
                        }
                    }
                }
                page.press(key).await?;
                settle(&page).await;
                self.page_summary(tab, snapshot, &Value::Null).await
            }
            "wait_for" => {
                let timeout = int_arg(arg(args, "timeoutMs"), 10_000, 0, 60_000) as u64;
                let text = |name| match arg(args, name) {
                    Some(Value::String(text)) if !text.is_empty() => Some(text.clone()),
                    _ => None,
                };
                if let Some(text) = text("text") {
                    page.clone()
                        .locator(Selector::TextFirst(text))
                        .wait_for(WaitState::Visible, ms(timeout))
                        .await?;
                } else if let Some(gone) = text("textGone") {
                    page.clone()
                        .locator(Selector::TextFirst(gone))
                        .wait_for(WaitState::Hidden, ms(timeout))
                        .await?;
                } else {
                    tokio::time::sleep(ms(timeout.min(30_000))).await;
                }
                self.page_summary(tab, snapshot, &Value::Null).await
            }
            "screenshot" => {
                self.assert_allowed(&page).await?;
                let jpeg = page
                    .screenshot(ScreenshotOptions {
                        quality: 70,
                        full_page: arg(args, "fullPage") == Some(&Value::Bool(true)),
                        timeout: ms(15_000),
                    })
                    .await?;
                let url = page.url();
                let title = page.title().await?;
                Ok(json!({ "url": url, "title": title, "image": base64(&jpeg),
                    "mimeType": "image/jpeg" }))
            }
            "tabs" => {
                let action = match arg(args, "action") {
                    None | Some(Value::Null) => Some("list"),
                    Some(Value::String(action)) => Some(action.as_str()),
                    Some(_) => None,
                };
                match action {
                    Some("new") => {
                        let created = self.new_page(tab).await?;
                        if let Some(Value::String(url)) = arg(args, "url")
                            && !url.is_empty()
                        {
                            self.goto(&created, &check_url(Some(&json!(url)))?).await?;
                        }
                    }
                    Some(action @ ("select" | "close")) => {
                        let index =
                            int_arg(arg(args, "index"), -1, -1, super::TABS_PER_SESSION as i64);
                        let chosen = usize::try_from(index)
                            .ok()
                            .and_then(|index| tab.lock().pages.get(index).cloned());
                        let Some(chosen) = chosen else {
                            return Err(ApiError::not_found(format!(
                                "No tab {}",
                                js_string(arg(args, "index"))
                            ))
                            .into());
                        };
                        if action == "select" {
                            crate::browser::effects::run(|| {
                                tab.lock().active = Some(chosen.clone())
                            })?;
                            let _ = chosen.bring_to_front().await;
                            self.sync_screencast(tab);
                        } else {
                            chosen.close().await?;
                            // Playwright's `page.close()` resolves after the
                            // page's `close` listeners ran: the tab's listener
                            // (which has the event by now) drops the page
                            // before the list below is taken.
                            let dropped = async {
                                while tab
                                    .lock()
                                    .pages
                                    .iter()
                                    .any(|page| super::same(page, &chosen))
                                {
                                    tokio::time::sleep(Duration::from_millis(1)).await;
                                }
                            };
                            let _ = tokio::time::timeout(Duration::from_secs(1), dropped).await;
                        }
                    }
                    Some("list") => {}
                    _ => {
                        return Err(
                            ApiError::bad_request("action is list, new, select or close").into(),
                        );
                    }
                }
                self.emit_state(tab);
                Ok(json!({ "tabs": self.tab_list(tab).await }))
            }
            _ => Err(ApiError::bad_request(format!("Unknown browser operation {op}")).into()),
        }
    }

    /// `goto(page, url)`: the host check, the navigation (DOM content
    /// loaded, 30 s), a short wait for the network to settle, and the check
    /// of every frame where it ended up. The main frame's status.
    pub(super) async fn goto(self: &Arc<Self>, page: &PageRef, url: &str) -> OpResult<Option<u16>> {
        if let Some(reason) = self.hosts().blocked_reason(url).await {
            return Err(blocked_error(url, &reason).into());
        }
        let status = match page
            .goto(url, LoadState::DomContentLoaded, ms(30_000))
            .await
        {
            Ok(status) => status,
            Err(error) if error.message.contains("ERR_BLOCKED_BY_CLIENT") => {
                // Refused at a redirect hop (see `engine::network`): TS's
                // Playwright followed the hop, and `assertAllowed` then left
                // the page and named the URL it landed on.
                if let Some((hop, reason)) = self.hosts().refused_hop(&page.main_frame_id()) {
                    // Chromium's error page commits after the failure; leave
                    // it, not the navigation still committing.
                    let mut events = page.subscribe();
                    if !page.url().starts_with("chrome-error:") {
                        let committed = async {
                            while let Some(event) = events.next().await {
                                if matches!(event, PageEvent::MainFrameNavigated) {
                                    break;
                                }
                            }
                        };
                        let _ = tokio::time::timeout(ms(2_000), committed).await;
                    }
                    let _ = page.goto("about:blank", LoadState::Load, ms(10_000)).await;
                    return Err(blocked_error(&hop, &reason).into());
                }
                return Err(
                    blocked_error(url, "it (or a page it loads) is on a blocked host").into(),
                );
            }
            Err(error) => return Err(error.into()),
        };
        let _ = page
            .wait_for_load_state(LoadState::NetworkIdle, ms(3_000))
            .await;
        self.assert_allowed(page).await?;
        Ok(status)
    }

    /// `assertAllowed(page)`: when any frame is on a blocked host, leave the
    /// page and refuse: the agent never reads it.
    ///
    /// The request interception refuses a navigation's redirect hop to a
    /// blocked host (see `engine::network`), so such a frame shows
    /// Chromium's error page instead; TS's Playwright followed the hop and
    /// this check named the URL the frame landed on. A frame on the error
    /// page whose latest navigation was refused at a hop is refused here
    /// with that hop's URL, which is the same text when the blocked host
    /// would have answered. Where TS's text depended on what the blocked
    /// host did with the forwarded request, it is stricter here: an
    /// unreachable blocked host (TS: Playwright's `net::ERR_…` error, or no
    /// error), a chain that leaves the blocked host again (TS: no error),
    /// several blocked hops (TS named the last, this the first).
    async fn assert_allowed(self: &Arc<Self>, page: &PageRef) -> OpResult<()> {
        for frame in page.frames() {
            let url = frame.url();
            let refused = match self.hosts().blocked_reason(&url).await {
                Some(reason) => Some((url, reason)),
                None if url.starts_with("chrome-error:") => self.hosts().refused_hop(&frame.id()),
                None => None,
            };
            if let Some((url, reason)) = refused {
                let _ = page.goto("about:blank", LoadState::Load, ms(10_000)).await;
                return Err(blocked_error(&url, &reason).into());
            }
        }
        Ok(())
    }

    /// `tabList(tab)`.
    async fn tab_list(&self, tab: &Tab) -> Vec<Value> {
        let (pages, active) = {
            let st = tab.lock();
            (st.pages.clone(), st.active.clone())
        };
        futures_util::future::join_all(pages.iter().enumerate().map(|(index, page)| {
            let active = active
                .as_ref()
                .is_some_and(|active| super::same(active, page));
            async move {
                json!({ "index": index, "url": page.url(),
                    "title": page.title().await.unwrap_or_default(), "active": active })
            }
        }))
        .await
    }

    /// `pageSummary(tab, withSnapshot, args)`: URL, title, the tabs when
    /// there are several, and the AI snapshot with passwords masked,
    /// clipped by `args.offset`/`args.maxChars`.
    pub(super) async fn page_summary(
        self: &Arc<Self>,
        tab: &Arc<Tab>,
        with_snapshot: bool,
        args: &Value,
    ) -> OpResult<Value> {
        let Some(page) = tab.active() else {
            return Ok(json!({ "url": "", "title": "", "tabs": [] }));
        };
        self.assert_allowed(&page).await?;
        let mut summary = Map::new();
        summary.insert("url".into(), json!(page.url()));
        summary.insert(
            "title".into(),
            json!(page.title().await.unwrap_or_default()),
        );
        if tab.lock().pages.len() > 1 {
            summary.insert("tabs".into(), Value::Array(self.tab_list(tab).await));
        }
        if !with_snapshot {
            return Ok(Value::Object(summary));
        }
        let frames = page.frames();
        let (snapshot, passwords) = tokio::join!(
            page.aria_snapshot(ms(10_000)),
            futures_util::future::join_all(frames.iter().map(|frame| async move {
                frame
                    .evaluate(PASSWORD_VALUES)
                    .await
                    .map(values_of)
                    .unwrap_or_default()
            })),
        );
        let masked = mask_passwords(&snapshot?, &passwords.concat());
        let clipped = clip(
            &masked,
            int_arg(arg(args, "offset"), 0, 0, 1_000_000_000) as usize,
            int_arg(arg(args, "maxChars"), SNAPSHOT_CHARS, 1_000, MAX_CHARS) as usize,
        );
        summary.insert("snapshot".into(), json!(clipped.content));
        summary.insert("offset".into(), json!(clipped.offset));
        summary.insert("totalChars".into(), json!(clipped.total_chars));
        summary.insert("truncated".into(), json!(clipped.truncated));
        Ok(Value::Object(summary))
    }

    // ---- recording ------------------------------------------------------------

    /// `record(tab, args)`: the agent's `browser_record`.
    async fn record(self: &Arc<Self>, tab: &Arc<Tab>, args: &Value) -> ApiResult<Value> {
        match arg(args, "action").and_then(Value::as_str) {
            Some("start") => {
                let Some(reservation) = self.reserve_recording(tab) else {
                    return Err(ApiError::conflict("Already recording"));
                };
                let name = arg(args, "name")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                let path = self.start_recording(tab, reservation, name).await?;
                self.log(tab, "agent", "Started recording", None);
                Ok(json!({ "recording": true, "path": path }))
            }
            Some("stop") => {
                let Some(stopping) = self.stop_recording(tab) else {
                    return Err(ApiError::conflict("Not recording"));
                };
                let result = stopping.await?;
                self.log(tab, "agent", &saved(&result), None);
                Ok(result)
            }
            _ => Err(ApiError::bad_request("action is start or stop")),
        }
    }

    /// The check of `if (tab.recording)` and the start that follows, made
    /// atomic: TS set `tab.recording` with no await in between (a tab with
    /// a page), but two starts on different threads could both pass the
    /// check here. `None` when the tab records or a start is in progress.
    /// Stricter than TS for a tab without a page: TS let two starts that
    /// both awaited `newPage` both proceed (the second replaced the first).
    pub(super) fn reserve_recording(&self, tab: &Arc<Tab>) -> Option<RecordingReservation> {
        let mut st = tab.lock();
        if st.recording.is_some() || st.recording_starting.is_some() {
            return None;
        }
        let seq = self.next_seq();
        st.recording_starting = Some(seq);
        Some(RecordingReservation {
            tab: tab.clone(),
            seq,
        })
    }

    /// `startRecording(tab, name)` with the slot reserved; the recording's
    /// path.
    pub(super) async fn start_recording(
        self: &Arc<Self>,
        tab: &Arc<Tab>,
        reservation: RecordingReservation,
        name: &str,
    ) -> ApiResult<String> {
        if tab.active().is_none() {
            self.new_page(tab).await.map_err(OpError::into_api)?;
        }
        let file_name = format!(
            "{}-{}.webm",
            recording_name(name),
            file_stamp(crate::util::now_ms())
        );
        // Written from outside the sandbox: no symlink below the session
        // root is followed, and an existing file is never replaced.
        let browser_error = |error: std::io::Error| {
            ApiError::new(
                500,
                "browser_error",
                format!(".pirc/recordings/{file_name}: {error}"),
            )
        };
        let relative = format!(".pirc/recordings/{file_name}");
        // Current from now on, also before it is installed: a fast ffmpeg
        // failure is the recording's (`tab.recording === recording`).
        let seq = reservation.seq;
        let frames: FrameSource = {
            let tab = Arc::downgrade(tab);
            Arc::new(move || {
                let tab = tab.upgrade()?;
                let st = tab.lock();
                st.last_frame.as_ref().map(|frame| frame.jpeg.clone())
            })
        };
        let still_current: StillCurrent = {
            let tab = Arc::downgrade(tab);
            Arc::new(move || {
                tab.upgrade().is_some_and(|tab| {
                    let st = tab.lock();
                    st.recording_starting == Some(seq)
                        || st
                            .recording
                            .as_ref()
                            .is_some_and(|active| active.seq == seq)
                })
            })
        };
        let recording = crate::browser::effects::run(|| {
            let dir = crate::private_dir::open_dir(&tab.target.root, &[".pirc", "recordings"])
                .map_err(browser_error)?;
            let output = crate::private_dir::create_new(&dir, &file_name).map_err(browser_error)?;
            Ok::<_, ApiError>(Recording::start(
                &self.settings.ffmpeg,
                &self.env,
                output,
                relative.clone(),
                frames,
                still_current,
            ))
        })??;
        let failed = recording.failure();
        let limit = {
            let inner = Arc::downgrade(self);
            let tab = Arc::downgrade(tab);
            spawn(async move {
                tokio::time::sleep(RECORD_MAX).await;
                let (Some(inner), Some(tab)) = (inner.upgrade(), tab.upgrade()) else {
                    return;
                };
                let current = tab
                    .lock()
                    .recording
                    .as_ref()
                    .is_some_and(|active| active.seq == seq);
                if current && let Some(stopping) = inner.stop_recording(&tab) {
                    // Not in this task: stopping aborts it.
                    spawn(async move {
                        let _ = stopping.await;
                    });
                }
            })
        };
        let mut recording = Some(ActiveRecording {
            seq,
            recording,
            limit,
        });
        let installed = crate::browser::effects::run(|| {
            let mut st = tab.lock();
            if st.closed {
                return Err(closing_error());
            }
            debug_assert!(st.recording.is_none());
            st.recording_starting = None;
            st.recording = recording.take();
            Ok((st.last_frame.is_none(), st.active.clone()))
        })
        .and_then(|r| r);
        let (needs_seed, active) = match installed {
            Ok(installed) => installed,
            Err(error) => {
                if let Some(recording) = recording {
                    let _ = self.finish_recording(tab, recording).await;
                }
                return Err(error);
            }
        };
        drop(reservation);
        // Seed a frame so the video starts with the current page.
        if needs_seed && let Some(page) = active {
            let seed = page
                .screenshot(ScreenshotOptions {
                    quality: 60,
                    full_page: false,
                    timeout: ms(5_000),
                })
                .await;
            if let Ok(seed) = seed {
                let (width, height) = self.viewport();
                let mut st = tab.lock();
                if st.last_frame.is_none() {
                    st.last_frame = Some(LastFrame {
                        jpeg: Arc::new(seed),
                        width,
                        height,
                    });
                }
            }
        }
        self.sync_screencast(tab);
        tokio::time::sleep(ms(150)).await;
        if let Some(reason) = failed.get() {
            let taken = {
                let mut st = tab.lock();
                if st
                    .recording
                    .as_ref()
                    .is_some_and(|active| active.seq == seq)
                {
                    st.recording.take()
                } else {
                    None
                }
            };
            if let Some(active) = taken {
                let _ = self.finish_recording(tab, active).await;
            }
            self.sync_screencast(tab);
            return Err(ApiError::runner_unavailable(reason));
        }
        self.emit_state(tab);
        Ok(relative)
    }

    /// `stopRecording(tab)` when the tab records: the tab lets go of the
    /// recording now; the future waits for ffmpeg.
    pub(super) fn stop_recording(
        self: &Arc<Self>,
        tab: &Arc<Tab>,
    ) -> Option<impl Future<Output = ApiResult<Value>> + Send + 'static> {
        let active = tab.lock().recording.take()?;
        Some(self.finish_recording(tab, active))
    }

    pub(super) fn finish_recording(
        self: &Arc<Self>,
        tab: &Arc<Tab>,
        active: ActiveRecording,
    ) -> impl Future<Output = ApiResult<Value>> + Send + 'static {
        if let Some(limit) = &active.limit {
            limit.abort();
        }
        let stopping = active.recording.stop();
        let cleanup = self.begin_cleanup(tab.session());
        let inner = self.clone();
        let tab = tab.clone();
        let task = tokio::spawn(async move {
            let _cleanup = cleanup;
            let result = match std::panic::AssertUnwindSafe(stopping).catch_unwind().await {
                Ok(stopped) => {
                    if !stopped.confirmed {
                        inner
                            .lock()
                            .unconfirmed_sessions
                            .insert(tab.session().to_owned());
                    }
                    stopped.result()
                }
                Err(_) => {
                    inner
                        .lock()
                        .unconfirmed_sessions
                        .insert(tab.session().to_owned());
                    Err(crate::browser::journal::unresolved())
                }
            };
            inner.sync_screencast(&tab);
            inner.emit_state(&tab);
            result
        });
        // Dropping this waiter does not abandon the observer or its cleanup slot.
        async move {
            task.await
                .map_err(|_| crate::browser::journal::unresolved())?
        }
    }
}

/// A tab's recording slot, held by a start until its recording is
/// installed; released on drop (a start that failed or was dropped).
pub(super) struct RecordingReservation {
    tab: Arc<Tab>,
    seq: u64,
}

impl Drop for RecordingReservation {
    fn drop(&mut self) {
        let mut st = self.tab.lock();
        if st.recording_starting == Some(self.seq) {
            st.recording_starting = None;
        }
    }
}

/// The log line of a saved recording, which clients parse (`Saved
/// recording .pirc/recordings/<name>.webm`).
pub(super) fn saved(result: &Value) -> String {
    format!(
        "Saved recording {}",
        result["path"].as_str().unwrap_or_default()
    )
}
