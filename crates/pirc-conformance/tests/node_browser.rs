//! The node's browser (`apps/gateway/src/node/browser.ts`, `browser-hosts.ts`,
//! `browser-extract.ts`, the browser part of `panel-routes.ts`) with a real
//! Chromium, driven by a real agent through `ptc` scripts of `tools.call`s
//! (the test plays the gateway and the model, as in `node_link_side.rs`),
//! and the side panel's browser stream relayed over the node link. The
//! pages are the browser golden corpus's (`crates/pirc-node/tests/fixtures/browser`),
//! served on loopback (allowed with `PIRC_BROWSER_ALLOW_PRIVATE`). Recorded
//! from the TS node (docs/development/historical-records.md).
//!
//! Normalized beyond the transcript's usual values: the fixture site's port
//! (`:<site-port>`), images (`<jpeg WxH>`, `<webm>`: what they are, not
//! their bytes), recording names' time stamps and sizes and durations.
//! Live state frames are recorded only once they show what a step waits
//! for (their titles are filled in asynchronously), and live `frame`s only
//! by their size. Skipped without a Chromium (see `node_browser_support`).

mod node_browser_support;
mod node_link_side_support;

use node_browser_support::{
    Browsing, Viewer, entry, ffmpeg, images, kind, required, start, state, viewport_frame,
};
use node_link_side_support::settled_in;
use serde_json::{Value, json};

/// A JavaScript string literal.
fn js(text: &str) -> String {
    json!(text).to_string()
}

/// Start a node with a browser, open a session in workspace `test`, prompt
/// it and return the agent's first model request.
async fn begin(extra: &[(&'static str, String)]) -> Option<(Browsing, String, Value, Value)> {
    let mut b = start(false, extra).await?;
    let (session, generation) = b.session("test").await;
    b.gw.prompt(&session, &generation, "browse-1", "Use the browser")
        .await;
    let first = b.model_start().await;
    Some((b, session, generation, first))
}

/// End the run: a final answer, then wait for the agent to settle.
async fn finish(b: &mut Browsing, start: &Value, session: &str) {
    b.gw.reply_text(start, "Done.").await;
    node_browser_support::wait_frame(&mut b.gw, node_browser_support::TURN, settled_in(session))
        .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn node_browser_fetch() {
    let Some((mut b, session, _, first)) = begin(&[]).await else {
        return;
    };
    let port = b.site.port;
    let a = |path: &str| js(&format!("http://127.0.0.1:{port}{path}"));
    let body = format!(
        r#"await call('web_fetch', {{ url: {markdown} }});
await call('web_fetch', {{ url: {markdown}, format: 'text' }});
await call('web_fetch', {{ url: {markdown}, format: 'html', offset: 500, maxChars: 1000 }});
await call('web_fetch', {{ url: {markdown}, offset: 100000 }});
await call('web_fetch', {{ url: {body_page} }});
await call('web_fetch', {{ url: {slow} }});
await call('web_fetch', {{ url: {missing} }});
await call('web_fetch', {{ url: {status} }});
await call('web_fetch', {{ url: {password}, format: 'html' }});"#,
        markdown = a("/markdown.html"),
        body_page = a("/markdown-body.html"),
        slow = a("/slow.html"),
        missing = a("/nothing-here"),
        status = a("/status/500"),
        password = a("/password.html"),
    );
    let (next, fetched) = b.run(&first, "f1", &body).await;
    b.t.note(
        "web_fetch: markdown, text, html (clipped), JS-rendered, statuses",
        fetched,
    );

    // Hosts the browser refuses, before or after navigating.
    let other = format!("http://other.localhost:{port}/details.html");
    let body = format!(
        r#"await call('web_fetch', {{ url: {loopback} }});
await call('web_fetch', {{ url: {bare} }});
await call('web_fetch', {{ url: {other} }});
await call('web_fetch', {{ url: {gateway} }});
await call('web_fetch', {{ url: {ipv6} }});
await call('web_fetch', {{ url: {redirect} }});
await call('browser_snapshot', {{}});
await call('browser_navigate', {{ url: {redirect} }});
await call('browser_navigate', {{ url: {framed} }});
await call('browser_navigate', {{ url: {decimal} }});
await call('web_fetch', {{ url: 'file:///etc/passwd' }});
await call('browser_navigate', {{ url: 'ftp://example.com/' }});
await call('browser_navigate', {{ url: 'http://exa mple.com/' }});"#,
        loopback = js(&format!("http://127.0.0.2:{port}/form.html")),
        bare = js(&format!("127.0.0.3:{port}/form.html")),
        other = js(&other),
        gateway = js(&format!("http://gateway.localhost:{port}/form.html")),
        ipv6 = js(&format!("http://[::1]:{port}/form.html")),
        redirect = a(&format!(
            "/redirect?to={}",
            other.replace(':', "%3A").replace('/', "%2F")
        )),
        framed = a("/blocked-frame.html"),
        decimal = js(&format!("http://2130706434:{port}/")),
    );
    let (next, blocked) = b.run(&next, "f2", &body).await;
    b.t.note("blocked hosts: private, local names, the gateway's, after a redirect, in a frame; other schemes", blocked);
    finish(&mut b, &next, &session).await;
    insta::assert_json_snapshot!("node_browser_fetch", b.t.into_value());
}

#[tokio::test(flavor = "multi_thread")]
async fn node_browser_pages() {
    let Some((mut b, session, _, first)) = begin(&[]).await else {
        return;
    };
    let port = b.site.port;
    let a = |path: &str| js(&format!("http://127.0.0.1:{port}{path}"));
    let body = format!(
        r#"const nav = await call('browser_navigate', {{ url: {form} }});
await call('browser_snapshot', {{ offset: 100, maxChars: 1000 }});
await call('browser_type', {{ ref: ref(nav, 'textbox "Name"'), text: 'Ada', element: 'Name' }});
await call('browser_select', {{ ref: ref(nav, 'combobox "Plan"'), values: ['Free'] }});
await call('browser_click', {{ ref: ref(nav, 'button "Submit"'), element: 'Submit' }});
await call('browser_type', {{ ref: ref(nav, 'checkbox "Remember me"'), text: 'x' }});
await call('browser_select', {{ ref: ref(nav, 'textbox "Name"'), values: ['x'] }});
await call('browser_select', {{ ref: ref(nav, 'combobox "Plan"'), values: [] }});
await call('browser_click', {{ ref: 'not-a-ref' }});
await call('browser_press', {{ key: 'NotAKey' }});
await call('browser_navigate', {{ url: 'back' }});"#,
        form = a("/form.html"),
    );
    let (next, form) = b.run(&first, "p1", &body).await;
    b.t.note(
        "a form: navigate, snapshot (clipped), type, select, click; errors",
        form,
    );

    let body = format!(
        r#"const kb = await call('browser_navigate', {{ url: {keyboard} }});
await call('browser_type', {{ ref: ref(kb, 'textbox "Field"'), text: 'aB1 é', slowly: true, snapshot: false }});
await call('browser_type', {{ ref: ref(kb, 'textbox "Field"'), text: 'more', slowly: true, clear: false, snapshot: false }});
await call('browser_type', {{ ref: ref(kb, 'textbox "Area"'), text: 'line', submit: true }});
await call('browser_press', {{ key: 'Shift+Tab' }});
const sel = await call('browser_navigate', {{ url: {select} }});
await call('browser_select', {{ ref: ref(sel, 'listbox "Toppings"'), values: ['Cheese', 'Basil'] }});
await call('browser_click', {{ ref: ref(sel, 'checkbox "Agree"'), double: true, snapshot: false }});
await call('browser_click', {{ ref: ref(sel, 'checkbox "Agree"'), button: 'right' }});
const mut = await call('browser_navigate', {{ url: {mutate} }});
await call('browser_click', {{ ref: ref(mut, 'button "Remove Beta"'), snapshot: false }});
await call('browser_click', {{ ref: ref(mut, 'button "Beta"') }});"#,
        keyboard = a("/keyboard.html"),
        select = a("/select.html"),
        mutate = a("/mutate.html"),
    );
    let (next, keys) = b.run(&next, "p2", &body).await;
    b.t.note(
        "keys, selections, mouse buttons; a ref whose element is gone (10 s)",
        keys,
    );

    let body = format!(
        r#"const s = await call('browser_navigate', {{ url: {slow} }});
await call('browser_click', {{ ref: ref(s, 'button "Load more"'), snapshot: false }});
await call('browser_wait_for', {{ text: 'More content' }});
await call('browser_click', {{ ref: ref(s, 'button "Dismiss toast"'), snapshot: false }});
await call('browser_wait_for', {{ textGone: 'Toast message', snapshot: false }});
await call('browser_wait_for', {{ text: 'Never shows up', timeoutMs: 500 }});
await call('browser_wait_for', {{ timeoutMs: 100, snapshot: false }});
const f = await call('browser_navigate', {{ url: {oopif} }});
await call('browser_click', {{ ref: ref(f, 'button "Remote button"') }});
await call('browser_type', {{ ref: ref(f, 'textbox "Remote input"'), text: 'in another renderer', snapshot: false }});
await call('browser_click', {{ ref: ref(f, 'textbox "Frame password"'), snapshot: false }});
await call('browser_press', {{ key: 'x' }});
await call('browser_snapshot', {{}});"#,
        slow = a("/slow.html"),
        oopif = a("/oopif.html"),
    );
    let (next, waits) = b.run(&next, "p3", &body).await;
    b.t.note("waiting for text; an out-of-process iframe", waits);

    let body = format!(
        r#"const p = await call('browser_navigate', {{ url: {password} }});
await call('browser_type', {{ ref: ref(p, 'textbox "Password"'), text: 'x' }});
await call('browser_type', {{ ref: ref(p, 'textbox "Shown password"'), text: 'x' }});
await call('browser_type', {{ ref: ref(p, 'textbox "One-time code"'), text: '', slowly: true }});
await call('browser_type', {{ ref: ref(p, 'textbox "Username"'), text: 'grace', snapshot: false }});
await call('browser_type', {{ ref: ref(p, 'textbox "Notes"'), text: 'hunter2' }});
await call('browser_click', {{ ref: ref(p, 'textbox "Password"'), snapshot: false }});
await call('browser_press', {{ key: 'a' }});
await call('browser_press', {{ key: 'Enter', snapshot: false }});
await call('browser_click', {{ ref: ref(p, 'textbox "Password"'), snapshot: false }});
await call('browser_press', {{ key: 'Tab', snapshot: false }});
await call('browser_click', {{ ref: ref(p, 'textbox "Shadow password"'), snapshot: false }});
await call('browser_press', {{ key: 'Backspace' }});
await call('browser_snapshot', {{}});"#,
        password = a("/password.html"),
    );
    let (next, secrets) = b.run(&next, "p4", &body).await;
    b.t.note("password masking and the password_field refusals", secrets);
    finish(&mut b, &next, &session).await;
    insta::assert_json_snapshot!("node_browser_pages", b.t.into_value());
}

#[tokio::test(flavor = "multi_thread")]
async fn node_browser_tabs() {
    let Some((mut b, session, _, first)) = begin(&[]).await else {
        return;
    };
    let port = b.site.port;
    let a = |path: &str| js(&format!("http://127.0.0.1:{port}{path}"));
    // The popup's adoption and load race the click's own result: the click
    // and the waits for the popup's title are not recorded.
    let body = format!(
        r#"const l = await call('browser_navigate', {{ url: {links} }});
await tools.call('browser_click', {{ ref: ref(l, 'link "Form in a new tab"'), snapshot: false }});
for (let i = 0; i < 100; i++) {{
  const t = await tools.call('browser_tabs', {{ action: 'list' }});
  const tabs = (t.ok && t.data && t.data.tabs) || [];
  if (tabs.length === 2 && tabs[1].title === 'Form') break;
  await tools.call('browser_wait_for', {{ timeoutMs: 100, snapshot: false }});
}}
await call('browser_tabs', {{ action: 'list' }});
await call('browser_snapshot', {{}});
await call('browser_tabs', {{ action: 'new', url: {details} }});
await call('browser_tabs', {{ action: 'new' }});
await call('browser_tabs', {{ action: 'select', index: 0 }});
await call('browser_snapshot', {{ maxChars: 1000 }});
await call('browser_tabs', {{ action: 'close', index: 1 }});
await call('browser_tabs', {{ action: 'select', index: 7 }});
await call('browser_tabs', {{ action: 'close', index: -1 }});
await call('browser_tabs', {{ action: 'list' }});
await call('browser_tabs', {{ action: 'new' }});
await call('browser_tabs', {{ action: 'new' }});
await call('browser_tabs', {{ action: 'new' }});
await call('browser_tabs', {{ action: 'new' }});
await call('browser_tabs', {{ action: 'new' }});
await call('browser_tabs', {{ action: 'new' }});
await call('browser_tabs', {{ action: 'close', index: 0 }});
await call('browser_tabs', {{ action: 'close', index: 0 }});
await call('browser_tabs', {{ action: 'close', index: 0 }});
await call('browser_tabs', {{ action: 'close', index: 0 }});
await call('browser_tabs', {{ action: 'close', index: 0 }});
await call('browser_tabs', {{ action: 'close', index: 0 }});
await call('browser_tabs', {{ action: 'close', index: 0 }});
await call('browser_tabs', {{ action: 'list' }});
await call('browser_snapshot', {{}});"#,
        links = a("/links.html"),
        details = a("/details.html"),
    );
    let (next, tabs) = b.run(&first, "t1", &body).await;
    b.t.note(
        "tabs: a popup, new, select, close (8 at most; the last one closed)",
        tabs,
    );

    let body = format!(
        r#"await call('browser_navigate', {{ url: {form} }});
const shot = await call('browser_screenshot', {{}});
await attachments.add(shot.attachments[0]);
await call('browser_navigate', {{ url: {markdown} }});
const full = await call('browser_screenshot', {{ fullPage: true }});
await attachments.add(full.attachments[0]);"#,
        form = a("/form.html"),
        markdown = a("/markdown.html"),
    );
    let (after, shots) = b.run(&next, "t2", &body).await;
    // The full page's height depends on the fonts: only that it is taller.
    let taller = regex::Regex::new(r"<jpeg 1280x(\d+)>").unwrap();
    let text = shots.to_string();
    let shots = taller.replace_all(&text, |found: &regex::Captures| {
        match found[1].parse::<u32>() {
            Ok(height) if height > 800 => "<jpeg 1280x(over 800)>".to_owned(),
            _ => found[0].to_owned(),
        }
    });
    b.t.note(
        "screenshots: the viewport, the full page; their images reach the model",
        serde_json::from_str(&shots).unwrap(),
    );
    finish(&mut b, &after, &session).await;
    insta::assert_json_snapshot!("node_browser_tabs", b.t.into_value());
}

/// The lease fields of a viewer message.
fn lease(generation: &Value, message: Value) -> Value {
    let mut message = message;
    message["clientId"] = json!("browser");
    message["generation"] = generation.clone();
    message
}

#[tokio::test(flavor = "multi_thread")]
async fn node_browser_viewer() {
    let Some(mut b) = start(false, &[]).await else {
        return;
    };
    let (session, generation) = b.session("test").await;
    let mut v = Viewer::open(&mut b.gw, "view-1", &session).await;
    let first = v.wait(&mut b.gw, kind("state")).await;
    let log = v.wait(&mut b.gw, kind("log")).await;
    b.t.note("attach before any page: state and log", json!([first, log]));

    // Before a page: what needs the lease, what creates the tab.
    v.now(&mut b.gw);
    v.input(&mut b.gw, json!({ "type": "key", "key": "a" }))
        .await;
    let refused = v.wait(&mut b.gw, kind("error")).await;
    v.now(&mut b.gw);
    v.input(&mut b.gw, json!({ "type": "log_image", "index": 0 }))
        .await;
    let image = v.wait(&mut b.gw, kind("log_image")).await;
    v.now(&mut b.gw);
    v.input(
        &mut b.gw,
        lease(&generation, json!({ "type": "key", "key": "a" })),
    )
    .await;
    let no_tab = v.wait(&mut b.gw, kind("error")).await;
    v.now(&mut b.gw);
    v.input(
        &mut b.gw,
        json!({ "type": "key", "key": "a", "clientId": "someone-else", "generation": generation }),
    )
    .await;
    let other = v.wait(&mut b.gw, kind("error")).await;
    b.t.note(
        "before a page: input without the lease, log_image (no lease needed), key with the lease, another client",
        json!([refused, image, no_tab, other]),
    );

    // The agent opens a page.
    b.gw.prompt(&session, &generation, "view-1", "Use the browser")
        .await;
    let start_1 = b.model_start().await;
    let mark = v.now(&mut b.gw);
    let body = format!(
        "await call('browser_navigate', {{ url: {} }});",
        js(&b.site.a("/form.html"))
    );
    v.now(&mut b.gw);
    let (start_2, navigated) = b.run(&start_1, "v1", &body).await;
    b.t.note("the agent navigates", navigated);
    let shown = v
        .wait(
            &mut b.gw,
            state(|s| s["title"] == "Form" && s["action"].is_null()),
        )
        .await;
    b.t.note("a state with the page and its title", shown);
    let busy = v
        .of(mark, &["state"])
        .into_iter()
        .find(|frame| frame["state"]["action"].is_string())
        .map(|frame| frame["state"]["action"].clone());
    b.t.note("the action shown meanwhile", json!(busy));
    let entry_1 = v.wait(&mut b.gw, kind("log_entry")).await;
    b.t.note("the log entry", entry_1.clone());
    // Of the viewport's size: not a stale first frame (see `viewport_frame`).
    let live = v.wait(&mut b.gw, viewport_frame).await;
    b.t.note("a live frame", live);

    // Input needs user mode.
    v.now(&mut b.gw);
    v.input(
        &mut b.gw,
        lease(&generation, json!({ "type": "key", "key": "a" })),
    )
    .await;
    let in_control = v.wait(&mut b.gw, kind("error")).await;
    b.t.note("input in agent mode", in_control);
    v.now(&mut b.gw);
    v.input(&mut b.gw, lease(&generation, json!({ "type": "takeover" })))
        .await;
    let took = v
        .wait(
            &mut b.gw,
            state(|s| s["mode"] == "user" && s["agentWaiting"] == false),
        )
        .await;
    let took_entry = v.wait(&mut b.gw, entry("User took control")).await;
    b.t.note(
        "takeover: user mode and its log entry",
        json!([took, took_entry]),
    );

    // The agent waits for control, then gets it back.
    v.now(&mut b.gw);
    b.gw.reply_tool(
        &start_2,
        "v2",
        "ptc",
        json!({ "code": node_browser_support::script("await call('browser_snapshot', {});") }),
    )
    .await;
    let waiting = v
        .wait(&mut b.gw, state(|s| s["agentWaiting"] == true))
        .await;
    b.t.note("the agent's snapshot waits for control", waiting);
    v.now(&mut b.gw);
    v.input(&mut b.gw, lease(&generation, json!({ "type": "release" })))
        .await;
    let released = v
        .wait(
            &mut b.gw,
            state(|s| s["mode"] == "agent" && s["agentWaiting"] == false),
        )
        .await;
    let returned = v.wait(&mut b.gw, entry("User returned control")).await;
    b.t.note(
        "release: agent mode and the user's log entry",
        json!([released, returned]),
    );
    let start_3 = b.model_start().await;
    b.t.note(
        "the waiting snapshot's result",
        node_browser_support::ptc_outcome(&start_3),
    );

    // A handoff: the user acts in the browser, then returns control.
    let body = "await call('browser_handoff', { reason: 'Please log in' });";
    v.now(&mut b.gw);
    b.gw.reply_tool(
        &start_3,
        "v3",
        "ptc",
        json!({ "code": node_browser_support::script(body) }),
    )
    .await;
    let handed = v
        .wait(
            &mut b.gw,
            state(|s| s["handoff"] == "Please log in" && s["agentWaiting"] == false),
        )
        .await;
    let handed_entry = v
        .wait(
            &mut b.gw,
            entry("Handed control to the user: Please log in"),
        )
        .await;
    b.t.note(
        "handoff: user mode with the reason",
        json!([handed, handed_entry]),
    );
    let mark = v.now(&mut b.gw);
    let details = b.site.a("/details.html");
    v.now(&mut b.gw);
    v.input(
        &mut b.gw,
        lease(&generation, json!({ "type": "navigate", "url": details })),
    )
    .await;
    let navigated = v
        .wait(
            &mut b.gw,
            state(|s| s["title"] == "Details" && s["mode"] == "user" && s["agentWaiting"] == true),
        )
        .await;
    b.t.note("the user navigates", navigated);
    let user_entries = v.of(mark, &["log_entry"]);
    b.t.note("its log entry", json!(user_entries));
    v.now(&mut b.gw);
    for message in [
        json!({ "type": "mouse", "action": "move", "x": 40, "y": 30 }),
        json!({ "type": "mouse", "action": "down", "x": 40, "y": 30, "button": "left", "clickCount": 1 }),
        json!({ "type": "mouse", "action": "up", "x": 40, "y": 30, "button": "left", "clickCount": 1 }),
        json!({ "type": "wheel", "x": 40, "y": 30, "dx": 0, "dy": 100 }),
        json!({ "type": "key", "key": "Tab" }),
        json!({ "type": "text", "text": "typed" }),
        json!({ "type": "key", "key": "NotAKey" }),
        json!({ "type": "tab", "index": 5 }),
        json!({ "type": "mouse", "action": "spin" }),
    ] {
        v.input(&mut b.gw, lease(&generation, message)).await;
    }
    v.now(&mut b.gw);
    v.input(&mut b.gw, lease(&generation, json!({ "type": "dance" })))
        .await;
    let unknown = v.wait(&mut b.gw, kind("error")).await;
    b.t.note(
        "mouse, wheel, keys, text, a missing tab, an unknown mouse action: no answer; an unknown message",
        unknown,
    );
    v.now(&mut b.gw);
    v.input(
        &mut b.gw,
        lease(
            &generation,
            json!({ "type": "navigate", "url": "file:///etc/passwd" }),
        ),
    )
    .await;
    let bad_url = v.wait(&mut b.gw, kind("error")).await;
    v.now(&mut b.gw);
    v.input(
        &mut b.gw,
        lease(
            &generation,
            json!({ "type": "navigate", "url": format!("http://other.localhost:{}/", b.site.port) }),
        ),
    )
    .await;
    let blocked = v.wait(&mut b.gw, kind("error")).await;
    b.t.note(
        "the user navigates to a file, to a blocked host",
        json!([bad_url, blocked]),
    );
    v.now(&mut b.gw);
    v.input(&mut b.gw, lease(&generation, json!({ "type": "back" })))
        .await;
    let back = v
        .wait(
            &mut b.gw,
            state(|s| s["title"] == "Form" && s["mode"] == "user" && s["agentWaiting"] == true),
        )
        .await;
    v.now(&mut b.gw);
    v.input(&mut b.gw, lease(&generation, json!({ "type": "forward" })))
        .await;
    let forward = v
        .wait(
            &mut b.gw,
            state(|s| s["title"] == "Details" && s["mode"] == "user" && s["agentWaiting"] == true),
        )
        .await;
    b.t.note("back and forward", json!([back, forward]));
    v.now(&mut b.gw);
    v.input(&mut b.gw, lease(&generation, json!({ "type": "release" })))
        .await;
    v.wait(&mut b.gw, entry("User returned control")).await;
    let start_4 = b.model_start().await;
    b.t.note(
        "the handoff's result",
        node_browser_support::ptc_outcome(&start_4),
    );
    let interactions =
        b.gw.ask("GET", &format!("/api/sessions/{session}/snapshot"), None)
            .await;
    b.t.note(
        "the handoff's dialog is withdrawn",
        interactions["data"]["body"]["interactions"].clone(),
    );

    // The log and its images.
    let mut second = Viewer::open(&mut b.gw, "view-2", &session).await;
    second.wait(&mut b.gw, kind("state")).await;
    let log = second.wait(&mut b.gw, kind("log")).await;
    b.t.note("a second viewer's log", log.clone());
    let with_image = log["entries"]
        .as_array()
        .and_then(|entries| entries.iter().find(|e| e["image"] == true))
        .map(|e| e["index"].clone())
        .unwrap_or(json!(-1));
    second
        .input(
            &mut b.gw,
            json!({ "type": "log_image", "index": with_image }),
        )
        .await;
    let thumbnail = second.wait(&mut b.gw, kind("log_image")).await;
    second
        .input(&mut b.gw, json!({ "type": "log_image", "index": 999 }))
        .await;
    let none = second.wait(&mut b.gw, kind("log_image")).await;
    second
        .input(&mut b.gw, json!({ "type": "log_image", "index": "1" }))
        .await;
    let text_index = second.wait(&mut b.gw, kind("log_image")).await;
    b.t.note(
        "log_image: an entry with a thumbnail, an unknown index, a string index",
        json!([thumbnail, none, text_index]),
    );
    second.close(&mut b.gw).await;
    v.close(&mut b.gw).await;
    finish(&mut b, &start_4, &session).await;
    insta::assert_json_snapshot!("node_browser_viewer", b.t.into_value());
}

/// A recording's name with its time stamp masked.
fn stamped(value: &Value) -> Value {
    let stamp = regex::Regex::new(r"\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-\d{3}Z").unwrap();
    serde_json::from_str(&stamp.replace_all(&value.to_string(), "<stamp>")).unwrap()
}

/// Sizes and durations: positive numbers become `<positive>`.
fn positive(value: &Value, keys: &[&str]) -> Value {
    match value {
        Value::Array(items) => items.iter().map(|item| positive(item, keys)).collect(),
        Value::Object(object) => Value::Object(
            object
                .iter()
                .map(|(key, item)| {
                    let item = match item.as_f64() {
                        Some(n) if keys.contains(&key.as_str()) && n > 0.0 => json!("<positive>"),
                        _ => positive(item, keys),
                    };
                    (key.clone(), item)
                })
                .collect(),
        ),
        _ => value.clone(),
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn node_browser_record() {
    if ffmpeg().is_none() {
        assert!(
            !required(),
            "no ffmpeg (PIRC_FFMPEG, ffmpeg on PATH) under PIRC_BROWSER_REQUIRED=1"
        );
        eprintln!("no ffmpeg (PIRC_FFMPEG, ffmpeg on PATH); skipping the recording scenario");
        return;
    }
    let Some(mut b) = start(false, &[]).await else {
        return;
    };
    let (session, generation) = b.session("test").await;
    let mut v = Viewer::open(&mut b.gw, "record-1", &session).await;
    v.wait(&mut b.gw, kind("log")).await;
    b.gw.prompt(&session, &generation, "record-1", "Record it")
        .await;
    let start_1 = b.model_start().await;
    let body = format!(
        r#"await call('browser_record', {{ action: 'stop' }});
await call('browser_record', {{ action: 'start', name: 'My demo: login/flow' }});
await call('browser_record', {{ action: 'start' }});
await call('browser_navigate', {{ url: {form} }});
await call('browser_wait_for', {{ timeoutMs: 500, snapshot: false }});
await call('browser_record', {{ action: 'stop' }});
await call('browser_record', {{ action: 'pause' }});"#,
        form = js(&b.site.a("/form.html")),
    );
    v.now(&mut b.gw);
    let (start_2, raw) = b.run(&start_1, "r1", &body).await;
    let path = raw["calls"]
        .as_array()
        .and_then(|calls| calls.iter().find_map(|c| c["data"]["path"].as_str()))
        .unwrap_or_default()
        .to_owned();
    let recorded = positive(&stamped(&raw), &["bytes", "durationMs"]);
    b.t.note(
        "browser_record: stop first, start, start again, stop, an unknown action",
        recorded.clone(),
    );
    let saved = v
        .wait(&mut b.gw, |frame| {
            frame["type"] == "log_entry"
                && frame["entry"]["action"]
                    .as_str()
                    .is_some_and(|a| a.starts_with("Saved recording "))
        })
        .await;
    b.t.note("the saved recording's log entry", stamped(&saved));

    // The viewer's record buttons.
    v.now(&mut b.gw);
    v.input(
        &mut b.gw,
        lease(&generation, json!({ "type": "record", "action": "start" })),
    )
    .await;
    let started = v.wait(&mut b.gw, entry("Started recording")).await;
    let recording = v
        .wait(&mut b.gw, state(|s| s["recording"].is_object()))
        .await;
    // Already recording: nothing happens.
    v.input(
        &mut b.gw,
        lease(&generation, json!({ "type": "record", "action": "start" })),
    )
    .await;
    tokio::time::sleep(std::time::Duration::from_millis(500)).await;
    v.now(&mut b.gw);
    v.input(
        &mut b.gw,
        lease(&generation, json!({ "type": "record", "action": "stop" })),
    )
    .await;
    let stopped = v
        .wait(&mut b.gw, |frame| {
            frame["type"] == "log_entry"
                && frame["entry"]["actor"] == "user"
                && frame["entry"]["action"]
                    .as_str()
                    .is_some_and(|a| a.starts_with("Saved recording "))
        })
        .await;
    let idle = v.wait(&mut b.gw, state(|s| s["recording"].is_null())).await;
    v.now(&mut b.gw);
    v.input(
        &mut b.gw,
        lease(&generation, json!({ "type": "record", "action": "stop" })),
    )
    .await;
    v.input(
        &mut b.gw,
        lease(&generation, json!({ "type": "record", "action": "pause" })),
    )
    .await;
    v.input(&mut b.gw, json!({ "type": "record", "action": "start" }))
        .await;
    let refused = v.wait(&mut b.gw, kind("error")).await;
    b.t.note(
        "the viewer records (start, start again, stop, stop again, pause, start without the lease): \
         log entries and states; only the lease error answers",
        stamped(&json!([started, recording, stopped, idle, refused])),
    );
    let user_path = stopped["entry"]["action"]
        .as_str()
        .and_then(|a| a.strip_prefix("Saved recording "))
        .unwrap_or_default()
        .to_owned();

    // Reading the recordings back.
    for (step, path) in [
        ("the agent's recording", &path),
        ("the viewer's recording", &user_path),
    ] {
        let chunk =
            b.gw.ask(
                "GET",
                &format!(
                    "/api/sessions/{session}/browser/recording?path={path}&offset=0&length=64"
                ),
                None,
            )
            .await;
        let body = &chunk["data"]["body"];
        let bytes = body["dataBase64"]
            .as_str()
            .and_then(|data| {
                use base64::Engine;
                base64::engine::general_purpose::STANDARD.decode(data).ok()
            })
            .unwrap_or_default();
        b.t.note(
            step,
            json!({ "status": chunk["data"]["status"], "mimeType": body["mimeType"],
                "offset": body["offset"], "size > 64": body["size"].as_u64().is_some_and(|s| s > 64),
                "chunk bytes": bytes.len(), "WebM magic": bytes.starts_with(&[0x1a, 0x45, 0xdf, 0xa3]) }),
        );
    }
    v.close(&mut b.gw).await;
    finish(&mut b, &start_2, &session).await;
    insta::assert_json_snapshot!("node_browser_record", b.t.into_value());
}

#[tokio::test(flavor = "multi_thread")]
async fn node_browser_close() {
    let Some(mut b) = start(true, &[]).await else {
        return;
    };
    let (session, generation) = b.session("chats").await;
    let mut v = Viewer::open(&mut b.gw, "close-1", &session).await;
    v.wait(&mut b.gw, kind("log")).await;
    b.gw.prompt(&session, &generation, "close-1", "Open a page")
        .await;
    let start_1 = b.model_start().await;
    let body = format!(
        "await call('browser_navigate', {{ url: {} }});",
        js(&b.site.a("/form.html"))
    );
    v.now(&mut b.gw);
    let (start_2, _) = b.run(&start_1, "c1", &body).await;
    v.wait(&mut b.gw, state(|s| s["title"] == "Form")).await;
    finish(&mut b, &start_2, &session).await;
    let deleted =
        b.gw.ask("DELETE", &format!("/api/sessions/{session}"), None)
            .await;
    b.t.note("delete the chat", deleted["data"]["status"].clone());
    let closed = v.wait(&mut b.gw, state(|s| s["active"] == false)).await;
    b.t.note("the viewer sees the browser closed", closed);
    v.close(&mut b.gw).await;
    let mut again = Viewer::open(&mut b.gw, "close-2", &session).await;
    let mut tries = 0;
    let reopened = loop {
        tries += 1;
        b.gw.link.drain(std::time::Duration::from_millis(200)).await;
        again.absorb(&mut b.gw);
        if again.closed.is_some() || again.frames.len() >= 2 || tries == 50 {
            break json!({ "frames": again.frames, "closed": again.closed });
        }
    };
    b.t.note("a viewer of the deleted chat", images(&reopened));
    insta::assert_json_snapshot!("node_browser_close", b.t.into_value());
}

/// A real Node, Chromium and ffmpeg: resource retirement is independent of
/// the actor that opened the tab, and does not close a workspace peer's tab.
#[tokio::test(flavor = "multi_thread")]
async fn node_browser_fence_retires_recording_without_closing_a_workspace_peer() {
    if ffmpeg().is_none() {
        assert!(!required(), "PIRC_BROWSER_REQUIRED=1 needs ffmpeg");
        eprintln!("no ffmpeg; skipping the browser fence scenario");
        return;
    }
    let Some(mut b) = start(false, &[]).await else {
        return;
    };
    let (source, source_generation) = b.session("test").await;
    let (peer, peer_generation) = b.session("test").await;
    let mut source_view = Viewer::open(&mut b.gw, "fenced-browser", &source).await;
    let mut peer_view = Viewer::open(&mut b.gw, "peer-browser", &peer).await;
    source_view.wait(&mut b.gw, kind("log")).await;
    peer_view.wait(&mut b.gw, kind("log")).await;
    for (session, generation, recording) in [
        (&source, &source_generation, true),
        (&peer, &peer_generation, false),
    ] {
        b.gw.prompt(session, generation, session, "Open the fixture page")
            .await;
        let first = b.model_start().await;
        let mut body = format!(
            "await call('browser_navigate', {{ url: {} }});",
            js(&b.site.a("/form.html"))
        );
        if recording {
            body.push_str("await call('browser_record', { action: 'start' });");
        }
        let (next, result) = b.run(&first, session, &body).await;
        let calls = result["calls"].as_array().expect("browser tool results");
        assert_eq!(calls.len(), if recording { 2 } else { 1 }, "{result}");
        assert!(calls.iter().all(|call| call["error"].is_null()), "{result}");
        // Ending the original Agent turn must not revoke its live resources.
        finish(&mut b, &next, session).await;
    }
    source_view
        .wait(&mut b.gw, state(|s| s["recording"].is_object()))
        .await;
    peer_view
        .wait(&mut b.gw, state(|s| s["title"] == "Form"))
        .await;
    let base = format!("/api/sessions/{source}");
    let snapshot = b.gw.ask("GET", &format!("{base}/snapshot"), None).await;
    assert_eq!(snapshot["data"]["status"], 200, "{snapshot}");
    let epoch = snapshot["data"]["body"]["session"]["runnerEpoch"].clone();
    assert!(epoch.is_number(), "{snapshot}");
    source_view.now(&mut b.gw);
    let accepted =
        b.gw.ask(
            "POST",
            &format!("{base}/execution-fences"),
            Some(json!({
                "intent": {
                    "operationId": "browser-resource-fence",
                    "planHash": "a".repeat(64),
                    "expectedWorkspaceId": "test",
                    "expectedRunnerEpoch": epoch
                },
                "clientId": "browser",
                "generation": source_generation
            })),
        )
        .await;
    assert_eq!(accepted["data"]["status"], 200, "{accepted}");
    // No explicit close/drain yet: even a quiet page has a retirement observer.
    source_view
        .wait(&mut b.gw, state(|s| s["active"] == false))
        .await;
    let drained =
        b.gw.ask(
            "POST",
            &format!("{base}/execution-fences/browser-resource-fence/drain"),
            Some(json!({})),
        )
        .await;
    assert_eq!(drained["data"]["status"], 200, "{drained}");
    let transition = &drained["data"]["body"]["transition"];
    assert_eq!(transition["state"], "supervisor_drained", "{drained}");
    assert_eq!(transition["revocationConfirmed"], false, "{drained}");
    assert_eq!(transition["targetInstalled"], false, "{drained}");

    // New work in the shared browser context still succeeds after retirement.
    peer_view.now(&mut b.gw);
    b.gw.prompt(
        &peer,
        &peer_generation,
        "peer-after-fence",
        "Navigate again",
    )
    .await;
    let first = b.model_start().await;
    let body = format!(
        "await call('browser_navigate', {{ url: {} }});",
        js(&b.site.a("/details.html"))
    );
    let (next, result) = b.run(&first, "peer-after-fence", &body).await;
    assert_eq!(
        result["calls"].as_array().map(Vec::len),
        Some(1),
        "{result}"
    );
    assert!(result["calls"][0]["error"].is_null(), "{result}");
    peer_view
        .wait(
            &mut b.gw,
            state(|s| {
                s["url"]
                    .as_str()
                    .is_some_and(|url| url.ends_with("/details.html"))
            }),
        )
        .await;
    finish(&mut b, &next, &peer).await;
    source_view.close(&mut b.gw).await;
    peer_view.close(&mut b.gw).await;
}
