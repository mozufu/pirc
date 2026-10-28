//! The page's screencast (`page.screencast.start({size, quality,
//! onFrame})` in `node/browser.ts`): `Page.startScreencast` JPEG frames at
//! most `size` (rounded down to even, as Playwright does), each
//! acknowledged once the sink returned. Playwright's action overlay
//! (`screencast.showActions({duration: 600})`) is part of it.
//!
//! Playwright 1.63.0 (`server/screencast.ts`, `CRPage.startScreencast`,
//! `FrameSession._onScreencastFrame`): `Page.startScreencast {format:
//! 'jpeg', quality, maxWidth, maxHeight}` on the page's main session, each
//! `Page.screencastFrame` (`data` base64, `metadata.deviceWidth` /
//! `deviceHeight`) handed to the client, then `Page.screencastFrameAck
//! {sessionId}` (the frame's number, not a CDP session); stopping sends
//! `Page.stopScreencast`. Errors of start and stop are ignored, as there.
//! Deviation: a frame whose image is not of its page's shape (Chromium's
//! stale first frames) is held back for the next one, see
//! [`has_page_shape`].
//! pirc has one client per page (the manager fans frames out), so the
//! cached-frame replay for later clients is the manager's.
//!
//! `showActions`: before every input action (`onBeforeInputAction`, see
//! [`announce`]) Playwright shows the action on the page (the injected
//! script's `setScreencastAnnotation`: the point, the element's box, the
//! action's title) for `duration` ms, *waiting that long before the action
//! runs*, then removes it. It does so whether or not a screencast runs:
//! with `node/browser.ts`'s 600 ms, every agent and viewer input waits
//! 600 ms (measured with Playwright 1.63.0: `keyboard.press` 633 ms,
//! `mouse.move` 623 ms, `locator.click` 653 ms). Ported as is. Deviation:
//! the announcement is bounded (`duration` + 2 s; the action goes on after
//! that), where Playwright waits for the main frame's utility world within
//! the action's timeout.
//!
//! Ported from playwright-core 1.63.0 `src/server/screencast.ts`,
//! `src/server/chromium/crPage.ts` (Apache-2.0, see
//! `crates/pirc-node/NOTICE`).

use std::sync::{Arc, Mutex};
use std::time::Duration;

use base64::Engine as _;
use serde_json::{Value, json};
use tokio::task::JoinHandle;

use super::Result;
use super::cdp::Session;
use super::frame::Arg;
use super::page::Page;

#[derive(Clone, Copy, Debug)]
pub struct ScreencastOptions {
    pub width: u32,
    pub height: u32,
    pub quality: u8,
}

/// One frame: the JPEG and the page's size it shows (`deviceWidth`,
/// `deviceHeight`).
#[derive(Clone, Debug)]
pub struct ScreencastFrame {
    pub jpeg: Arc<Vec<u8>>,
    pub width: u32,
    pub height: u32,
}

/// `screencast.showActions(options)`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ShowActions {
    /// How long each action is shown (and delayed), Playwright's default
    /// 500 ms.
    pub duration: Duration,
}

/// Per-page screencast state, kept by the page.
#[derive(Default)]
pub struct ScreencastState {
    /// The task handing frames to the sink while a screencast runs.
    running: Mutex<Option<JoinHandle<()>>>,
    actions: Mutex<Option<ShowActions>>,
    /// Screenshots of the page run one at a time (`Screenshotter`'s
    /// queue).
    pub(super) screenshots: tokio::sync::Mutex<()>,
}

impl ScreencastState {
    pub fn show_actions(&self, actions: Option<ShowActions>) {
        *self.actions.lock().unwrap() = actions;
    }

    pub fn actions(&self) -> Option<ShowActions> {
        *self.actions.lock().unwrap()
    }

    pub fn is_running(&self) -> bool {
        self.running.lock().unwrap().is_some()
    }
}

impl Drop for ScreencastState {
    fn drop(&mut self) {
        if let Some(task) = self.running.get_mut().unwrap().take() {
            task.abort();
        }
    }
}

pub async fn start(
    page: &Page,
    options: ScreencastOptions,
    sink: Arc<dyn Fn(ScreencastFrame) + Send + Sync>,
) -> Result<()> {
    start_on(page.session(), page.screencast_state(), options, sink).await
}

pub async fn stop(page: &Page) -> Result<()> {
    stop_on(page.session(), page.screencast_state()).await
}

/// [`start`] on a page's main session and state: a running screencast is
/// stopped first (a restart with the new options).
pub async fn start_on(
    session: &Session,
    state: &ScreencastState,
    options: ScreencastOptions,
    sink: Arc<dyn Fn(ScreencastFrame) + Send + Sync>,
) -> Result<()> {
    stop_on(session, state).await?;
    let mut events = session.listen();
    let acks = session.clone();
    let max = (options.width & !1, options.height & !1);
    let start = json!({
        "format": "jpeg",
        "quality": options.quality,
        "maxWidth": max.0,
        "maxHeight": max.1,
    });
    let restart = start.clone();
    let task = tokio::spawn(crate::browser::effects::background(
        crate::browser::effects::resource(),
        async move {
            // Until a first frame went out, one whose image is not of its
            // page's size is held back for the one Chromium sends next (see
            // [`has_page_shape`]); without one soon, the screencast is
            // restarted once, which makes Chromium send the current one.
            let mut first = true;
            let mut restarted = false;
            let mut held: Option<(ScreencastFrame, tokio::time::Instant)> = None;
            loop {
                if crate::browser::effects::check().is_err() {
                    break;
                }
                let event = match &held {
                    Some((_, until)) => {
                        match tokio::time::timeout_at(*until, events.recv()).await {
                            Ok(event) => event,
                            Err(_) if !restarted => {
                                restarted = true;
                                acks.send("Page.stopScreencast", json!({}));
                                acks.send("Page.startScreencast", restart.clone());
                                if let Some((_, until)) = &mut held {
                                    *until = tokio::time::Instant::now() + HOLD_AFTER_RESTART;
                                }
                                continue;
                            }
                            Err(_) => {
                                if crate::browser::effects::check().is_err() {
                                    break;
                                }
                                if let Some((frame, _)) = held.take() {
                                    first = false;
                                    sink(frame);
                                }
                                continue;
                            }
                        }
                    }
                    None => events.recv().await,
                };
                if crate::browser::effects::check().is_err() {
                    break;
                }
                let Some(event) = event else {
                    break;
                };
                if event.method != "Page.screencastFrame" {
                    continue;
                }
                if let Some(frame) = decode_frame(&event.params) {
                    if !first || has_page_shape(&frame, max) {
                        first = false;
                        held = None;
                        sink(frame);
                    } else {
                        // A stale frame replaces the one held, not its deadline
                        // (Chromium may send several).
                        let until = held.as_ref().map_or_else(
                            || tokio::time::Instant::now() + HOLD_MISSHAPEN,
                            |(_, until)| *until,
                        );
                        held = Some((frame, until));
                    }
                }
                let _ = acks
                    .call(
                        "Page.screencastFrameAck",
                        json!({ "sessionId": event.params["sessionId"] }),
                    )
                    .await;
            }
        },
    ));
    // A start that raced this one (both past their stop) is replaced, not
    // left feeding its sink.
    if let Some(previous) = state.running.lock().unwrap().replace(task) {
        previous.abort();
    }
    let _ = session.call("Page.startScreencast", start).await;
    Ok(())
}

/// [`stop`] on a page's main session and state; nothing when none runs.
pub async fn stop_on(session: &Session, state: &ScreencastState) -> Result<()> {
    let running = state.running.lock().unwrap().take();
    if let Some(task) = running {
        task.abort();
        let _ = session.call("Page.stopScreencast", json!({})).await;
    }
    Ok(())
}

/// How long a misshapen first frame waits for the next one before the
/// screencast is restarted (the next one comes some 20 ms later when
/// Chromium sends one).
const HOLD_MISSHAPEN: Duration = Duration::from_millis(100);

/// How long it then waits for the restarted screencast's frame before it
/// goes out anyway.
const HOLD_AFTER_RESTART: Duration = Duration::from_millis(500);

/// Whether the frame's image has the size of the page it says it shows
/// (`deviceWidth` x `deviceHeight`), scaled down to fit `max` (the
/// screencast's `maxWidth` x `maxHeight`) as Chromium scales it, give or
/// take two pixels of rounding.
///
/// Chromium (153) sometimes captures the first frame of a screencast (and
/// so Playwright's, measured with 1.63.0: 10 first frames out of 15 on a
/// page navigated as the screencast starts) from the view's surface before
/// the viewport emulation's resize, at the window's un-emulated size
/// (1280x713 for a 1280x800 window on Linux) or mid-resize (1266x800), or
/// scaled from a smaller surface (1086x679 on macOS), while its metadata
/// already says 1280x800. A frame of the right size follows some 20 ms
/// later, or (macOS, a page that does not change) none at all until the
/// page repaints. Until a screencast's first frame went out, such a frame
/// is held back for [`HOLD_MISSHAPEN`] in favour of the next one; then the
/// screencast is restarted once (`Page.stopScreencast`,
/// `Page.startScreencast`: Chromium sends its current frame) and the frame
/// waits [`HOLD_AFTER_RESTART`] more for it (Playwright hands such frames
/// on; deviation). Later frames all go out as they come.
fn has_page_shape(frame: &ScreencastFrame, max: (u32, u32)) -> bool {
    let Some((width, height)) = jpeg_size(&frame.jpeg) else {
        return true;
    };
    let (page_width, page_height) = (f64::from(frame.width), f64::from(frame.height));
    if page_width == 0.0 || page_height == 0.0 || max.0 == 0 || max.1 == 0 {
        return true;
    }
    let scale = (f64::from(max.0) / page_width)
        .min(f64::from(max.1) / page_height)
        .min(1.0);
    (f64::from(width) - page_width * scale).abs() <= 2.0
        && (f64::from(height) - page_height * scale).abs() <= 2.0
}

/// A JPEG's size, from its first start-of-frame marker.
fn jpeg_size(jpeg: &[u8]) -> Option<(u32, u32)> {
    if jpeg.get(..2)? != [0xff, 0xd8] {
        return None;
    }
    let mut at = 2;
    while at + 9 < jpeg.len() {
        if jpeg[at] != 0xff {
            return None;
        }
        let marker = jpeg[at + 1];
        let length = usize::from(u16::from_be_bytes([jpeg[at + 2], jpeg[at + 3]]));
        if matches!(marker, 0xc0..=0xc3) {
            let height = u16::from_be_bytes([jpeg[at + 5], jpeg[at + 6]]);
            let width = u16::from_be_bytes([jpeg[at + 7], jpeg[at + 8]]);
            return Some((u32::from(width), u32::from(height)));
        }
        at += 2 + length;
    }
    None
}

fn decode_frame(params: &Value) -> Option<ScreencastFrame> {
    let jpeg = base64::engine::general_purpose::STANDARD
        .decode(params["data"].as_str()?)
        .ok()?;
    let size = |name: &str| params["metadata"][name].as_f64().unwrap_or(0.0).round() as u32;
    Some(ScreencastFrame {
        jpeg: Arc::new(jpeg),
        width: size("deviceWidth"),
        height: size("deviceHeight"),
    })
}

/// `page.screencast.showActions({duration})` (`None`: `hideActions`).
pub fn show_actions(page: &Page, actions: Option<ShowActions>) {
    page.screencast_state().show_actions(actions);
}

/// An element's box in the main frame's viewport (`box` of
/// `onBeforeInputAction`).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

/// What `Screencast.onBeforeInputAction` evaluates in the main frame's
/// utility world (`this` is the injected script).
const ANNOTATE: &str = "async function(options) {
  const injected = this;
  injected.setScreencastAnnotation(options);
  await new Promise((f) => injected.utils.builtins.setTimeout(f, options.duration));
  injected.setScreencastAnnotation(null);
}";

/// The annotation's options (`setScreencastAnnotation`'s argument).
pub fn annotation(
    actions: ShowActions,
    title: &str,
    point: Option<(f64, f64)>,
    rect: Option<Rect>,
) -> Value {
    let mut options = json!({
        "duration": actions.duration.as_millis() as u64,
        "actionTitle": title,
        "cursor": "pointer",
    });
    if let Some((x, y)) = point {
        options["point"] = json!({ "x": x, "y": y });
    }
    if let Some(rect) = rect {
        options["box"] =
            json!({ "x": rect.x, "y": rect.y, "width": rect.width, "height": rect.height });
    }
    options
}

/// `onBeforeInputAction`: with `showActions` on, show the action `title`
/// (Playwright's rendered call title, e.g. `Press "Enter"`, `Mouse move`,
/// `Click`) at `point` / around `rect` and wait out the duration. Element
/// actions pass their element's box.
///
/// As Playwright's, the action fails when the main frame's injected script
/// cannot be had (its context destroyed while it is created, the page
/// closed), while a failure of the annotation itself is ignored (a
/// navigation ends its wait at once).
pub async fn announce(
    page: &Page,
    title: &str,
    point: Option<(f64, f64)>,
    rect: Option<Rect>,
) -> Result<()> {
    let Some(actions) = page.screencast_state().actions() else {
        return Ok(());
    };
    let options = annotation(actions, title, point, rect);
    let deadline = tokio::time::Instant::now() + actions.duration + Duration::from_secs(2);
    let main = page.main_frame();
    let (injected, uid) = match tokio::time::timeout_at(deadline, main.injected_in_context()).await
    {
        Ok(found) => found?,
        Err(_) => return Ok(()),
    };
    let shown = main.call_in_context(uid, &injected, ANNOTATE, vec![Arg::Value(options)], true);
    let _ = tokio::time::timeout_at(deadline, shown).await;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shapes_the_annotation_as_playwright() {
        let actions = ShowActions {
            duration: Duration::from_millis(600),
        };
        assert_eq!(
            annotation(actions, "Mouse move", Some((10.0, 20.5)), None),
            json!({ "duration": 600, "actionTitle": "Mouse move", "cursor": "pointer",
                "point": { "x": 10.0, "y": 20.5 } })
        );
        assert_eq!(
            annotation(
                actions,
                "Click",
                Some((1.0, 2.0)),
                Some(Rect {
                    x: 0.0,
                    y: 0.0,
                    width: 4.0,
                    height: 3.0
                })
            )["box"],
            json!({ "x": 0.0, "y": 0.0, "width": 4.0, "height": 3.0 })
        );
    }

    #[test]
    fn decodes_frames() {
        let frame = decode_frame(&json!({ "data": "/9j/", "sessionId": 3,
            "metadata": { "deviceWidth": 1280.0, "deviceHeight": 799.6 } }))
        .unwrap();
        assert_eq!(*frame.jpeg, vec![0xff, 0xd8, 0xff]);
        assert_eq!((frame.width, frame.height), (1280, 800));
    }

    /// The start of a JPEG of `width` x `height` (what [`jpeg_size`] reads).
    fn jpeg(width: u16, height: u16) -> Vec<u8> {
        let mut bytes = vec![0xff, 0xd8, 0xff, 0xc0, 0x00, 0x11, 0x08];
        bytes.extend(height.to_be_bytes());
        bytes.extend(width.to_be_bytes());
        bytes.extend([3, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1]);
        bytes
    }

    fn frame(jpeg: Vec<u8>, width: u32, height: u32) -> ScreencastFrame {
        ScreencastFrame {
            jpeg: Arc::new(jpeg),
            width,
            height,
        }
    }

    #[test]
    fn tells_frames_of_the_page_shape_from_stale_ones() {
        assert_eq!(jpeg_size(&jpeg(1280, 713)), Some((1280, 713)));
        assert_eq!(jpeg_size(&[0xff, 0xd8, 0xff]), None);
        let max = (1280, 800);
        assert!(has_page_shape(&frame(jpeg(1280, 800), 1280, 800), max));
        // Scaled down to fit the screencast's size, never up.
        assert!(has_page_shape(
            &frame(jpeg(640, 400), 1280, 800),
            (640, 400)
        ));
        assert!(has_page_shape(
            &frame(jpeg(319, 200), 1277, 800),
            (320, 200)
        ));
        assert!(has_page_shape(&frame(jpeg(400, 300), 400, 300), max));
        // Chromium's stale first frames (measured on Linux and macOS).
        assert!(!has_page_shape(&frame(jpeg(1280, 713), 1280, 800), max));
        assert!(!has_page_shape(&frame(jpeg(1266, 800), 1280, 800), max));
        assert!(!has_page_shape(&frame(jpeg(1086, 679), 1280, 800), max));
        // What cannot be checked goes out.
        assert!(has_page_shape(&frame(vec![1, 2], 1280, 800), max));
        assert!(has_page_shape(&frame(jpeg(1280, 713), 0, 0), max));
    }

    #[tokio::test(start_paused = true)]
    async fn a_revoked_resource_cannot_restart_the_screencast_but_cleanup_can_stop_it() {
        use super::super::cdp::Fake;
        use crate::browser::effects;
        let mut fake = Fake::new();
        let session = fake.connection.session("source");
        let state = ScreencastState::default();
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
        let started = effects::background(
            Some(guard.clone()),
            start_on(
                &session,
                &state,
                ScreencastOptions {
                    width: 1280,
                    height: 800,
                    quality: 60,
                },
                Arc::new(|_| panic!("the stale frame must not escape")),
            ),
        );
        let peer = async {
            let start = fake.command().await;
            assert_eq!(start["method"], "Page.startScreencast");
            fake.send(json!({"id":start["id"],"sessionId":"source","result":{}}))
                .await;
        };
        let (started, ()) = tokio::join!(started, peer);
        started.unwrap();
        let data = base64::engine::general_purpose::STANDARD.encode(jpeg(1280, 713));
        fake.send(json!({"method":"Page.screencastFrame","sessionId":"source","params":{"data":data,"sessionId":1,"metadata":{"deviceWidth":1280,"deviceHeight":800}}})).await;
        let ack = fake.command().await;
        assert_eq!(ack["method"], "Page.screencastFrameAck");
        fake.send(json!({"id":ack["id"],"sessionId":"source","result":{}}))
            .await;
        *allowed.lock().unwrap() = false;
        tokio::time::timeout(Duration::from_secs(2), async {
            while guard.failure().is_none() {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
        fake.connection
            .session("peer")
            .send("peer-command", json!({}));
        assert_eq!(fake.command().await["method"], "peer-command");
        let stopped = stop_on(&session, &state);
        let cleanup = async {
            let stop = fake.command().await;
            assert_eq!(stop["method"], "Page.stopScreencast");
            fake.send(json!({"id":stop["id"],"sessionId":"source","result":{}}))
                .await;
        };
        let (stopped, ()) = tokio::join!(stopped, cleanup);
        stopped.unwrap();
        assert!(!fake.connection.is_closed());
    }

    /// On paused time: the fake browser's pipes are in-process, so its
    /// messages are always ready before the clock auto-advances, and the
    /// holds are measured on the test's own clock, not the machine's load.
    #[tokio::test(start_paused = true)]
    async fn holds_back_a_stale_frame_for_the_next_one() {
        use super::super::cdp::Fake;
        let mut fake = Fake::new();
        let session = fake.connection.session("S");
        let state = ScreencastState::default();
        let got: Arc<Mutex<Vec<(u32, u32)>>> = Arc::default();
        let sink = {
            let got = got.clone();
            Arc::new(move |frame: ScreencastFrame| {
                got.lock().unwrap().push(jpeg_size(&frame.jpeg).unwrap());
            })
        };
        let options = ScreencastOptions {
            width: 1280,
            height: 800,
            quality: 60,
        };
        let started = start_on(&session, &state, options, sink);
        let browser = async {
            let start = fake.command().await;
            assert_eq!(start["method"], "Page.startScreencast");
            fake.send(json!({ "id": start["id"], "sessionId": "S", "result": {} }))
                .await;
        };
        let (started, ()) = tokio::join!(started, browser);
        started.unwrap();
        let mut number = 0;
        let mut cast = async |fake: &mut Fake, width: u16, height: u16| {
            number += 1;
            let data = base64::engine::general_purpose::STANDARD.encode(jpeg(width, height));
            fake.send(json!({ "method": "Page.screencastFrame", "sessionId": "S",
                "params": { "data": data, "sessionId": number,
                    "metadata": { "deviceWidth": 1280, "deviceHeight": 800 } } }))
                .await;
            let ack = fake.command().await;
            assert_eq!(ack["method"], "Page.screencastFrameAck");
            assert_eq!(ack["params"]["sessionId"], number);
            fake.send(json!({ "id": ack["id"], "sessionId": "S", "result": {} }))
                .await;
        };
        // Stale frames followed by a good one: only the good one.
        cast(&mut fake, 1280, 713).await;
        cast(&mut fake, 1086, 679).await;
        cast(&mut fake, 1280, 800).await;
        tokio::time::sleep(HOLD_MISSHAPEN + Duration::from_millis(100)).await;
        assert_eq!(*got.lock().unwrap(), [(1280, 800)]);
        // Once a frame went out, every frame does at once.
        cast(&mut fake, 1266, 800).await;
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert_eq!(*got.lock().unwrap(), [(1280, 800), (1266, 800)]);
        // A restart checks again; a stale first frame alone goes out after
        // a while.
        let sink = {
            let got = got.clone();
            Arc::new(move |frame: ScreencastFrame| {
                got.lock().unwrap().push(jpeg_size(&frame.jpeg).unwrap());
            })
        };
        got.lock().unwrap().clear();
        let started = start_on(&session, &state, options, sink);
        let browser = async {
            for method in ["Page.stopScreencast", "Page.startScreencast"] {
                let command = fake.command().await;
                assert_eq!(command["method"], method);
                fake.send(json!({ "id": command["id"], "sessionId": "S", "result": {} }))
                    .await;
            }
        };
        let (started, ()) = tokio::join!(started, browser);
        started.unwrap();
        cast(&mut fake, 1280, 713).await;
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert!(got.lock().unwrap().is_empty());
        // No next frame: restarted once (fire and forget).
        assert_eq!(fake.command().await["method"], "Page.stopScreencast");
        let start = fake.command().await;
        assert_eq!(start["method"], "Page.startScreencast");
        assert_eq!(
            start["params"],
            json!({ "format": "jpeg", "quality": 60, "maxWidth": 1280, "maxHeight": 800 })
        );
        // Its frames are stale too, coming faster than the hold: the last
        // one goes out once the hold is over.
        let until = tokio::time::Instant::now() + HOLD_AFTER_RESTART;
        let mut sent = 0;
        while tokio::time::Instant::now() + Duration::from_millis(40) < until {
            cast(&mut fake, 1280, 679 + sent).await;
            sent += 1;
            tokio::time::sleep(Duration::from_millis(30)).await;
        }
        assert!(got.lock().unwrap().is_empty());
        tokio::time::sleep(Duration::from_millis(150)).await;
        assert_eq!(*got.lock().unwrap(), [(1280, u32::from(679 + sent - 1))]);
    }
}
