//! The `browser_*` tools run from `ptc` scripts (docs/architecture/ptc.md):
//! page tools and their summaries, the
//! screenshot, tabs, recording, node errors, and the handoff to the human
//! (returned in the panel, confirmed in the dialog, cancelled, and without
//! a human). The test answers the node's `browser_request`s. Needs the
//! `ptc` runtime.

mod feature_support;

use std::collections::VecDeque;

use feature_support::{Masker, ptc, turn};
use pirc_conformance::{AgentOptions, AgentRun, ModelReply, Recorder};
use serde_json::{Value, json};

fn ok(result: Value) -> Value {
    json!({ "ok": true, "result": result })
}

fn browser_options(args: Vec<String>) -> AgentOptions {
    let mut options = AgentOptions {
        args,
        ..AgentOptions::default()
    }
    .features("browser");
    options
        .env
        .push(("PIRC_BROWSER".to_owned(), "1".to_owned()));
    options
}

/// Every call's outcome, as JSON.
fn script(calls: &[(&str, Value)]) -> String {
    let mut code = String::from("const out = [];\n");
    for (name, args) in calls {
        code.push_str(&format!(
            "out.push(await tools.call({}, {args}));\n",
            json!(name)
        ));
    }
    code.push_str(
        "return JSON.stringify(out.map((r) => r.ok ? { data: r.data, attachments: r.attachments } : { error: r.error }));",
    );
    code
}

fn page(snapshot: bool) -> Value {
    let mut page = json!({ "url": "https://example.com/", "title": "Example", "status": 200,
        "tabs": [ { "index": 0, "url": "https://example.com/", "title": "Example", "active": true },
            { "index": 1, "url": "about:blank", "title": "", "active": false } ] });
    if snapshot {
        page["snapshot"] = json!("- button \"Go\" [ref=e1]");
        page["offset"] = json!(10);
        page["totalChars"] = json!(100);
        page["truncated"] = json!(true);
    }
    page
}

fn queue(items: Vec<Value>) -> VecDeque<Value> {
    items.into()
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_browser_tools() {
    let Some(mut agent) = AgentRun::start(browser_options(Vec::new())).await else {
        return;
    };
    let mut r = Recorder::new(&agent);
    let mut m = Masker::new();
    {
        let mut answers = agent.answers.lock().unwrap();
        let browser = &mut answers.browser;
        browser.insert("navigate".to_owned(), queue(vec![ok(page(true))]));
        browser.insert(
            "snapshot".to_owned(),
            queue(vec![
                ok(json!({ "url": "https://example.com/", "title": "Example",
                    "snapshot": "- link \"Home\" [ref=e2]", "offset": 0, "totalChars": 24 })),
                ok(
                    json!({ "url": "https://example.com/after", "title": "After",
                    "snapshot": "- heading \"Done\"" }),
                ),
            ]),
        );
        browser.insert(
            "click".to_owned(),
            queue(vec![json!({ "ok": false, "error": { "code": "stale_ref",
                "message": "Ref e9 is not in the latest snapshot" } })]),
        );
        browser.insert(
            "type".to_owned(),
            queue(vec![ok(
                json!({ "url": "https://example.com/", "title": "Example" }),
            )]),
        );
        browser.insert(
            "screenshot".to_owned(),
            queue(vec![ok(
                json!({ "url": "https://example.com/", "title": "Example",
                "image": "iVBORw0KGgo=", "mimeType": "image/png" }),
            )]),
        );
        browser.insert(
            "tabs".to_owned(),
            queue(vec![
                ok(
                    json!({ "tabs": [ { "index": 0, "url": "https://example.com/",
                    "title": "", "active": true } ] }),
                ),
                ok(json!({ "tabs": [] })),
            ]),
        );
        browser.insert(
            "record".to_owned(),
            queue(vec![
                ok(json!({ "path": ".pirc/recordings/demo.webm" })),
                ok(
                    json!({ "path": ".pirc/recordings/demo.webm", "bytes": 204800,
                    "durationMs": 4567.8 }),
                ),
            ]),
        );
    }
    agent.push([
        ptc(
            "b1",
            &script(&[
                ("browser_navigate", json!({ "url": "https://example.com/" })),
                ("browser_snapshot", json!({})),
                (
                    "browser_click",
                    json!({ "ref": "e9", "element": "Go button" }),
                ),
                (
                    "browser_type",
                    json!({ "ref": "e1", "text": "hello", "submit": true, "snapshot": false }),
                ),
                ("browser_screenshot", json!({ "fullPage": true })),
                ("browser_tabs", json!({ "action": "list" })),
                ("browser_tabs", json!({ "action": "close", "index": 0 })),
                (
                    "browser_record",
                    json!({ "action": "start", "name": "demo" }),
                ),
                ("browser_record", json!({ "action": "stop" })),
            ]),
        ),
        ModelReply::Text("Browsed.".to_owned()),
    ]);
    turn(
        &mut agent,
        &mut m,
        &mut r,
        "page tools",
        "Browse example.com",
    )
    .await;
    // Handoffs: the panel returns control; the dialog confirms; cancelled.
    {
        let mut answers = agent.answers.lock().unwrap();
        answers.browser.insert(
            "handoff".to_owned(),
            queue(vec![ok(json!({})), ok(json!({})), ok(json!({}))]),
        );
        answers.browser.insert(
            "release".to_owned(),
            queue(vec![ok(json!({})), ok(json!({}))]),
        );
    }
    for (step, panel, dialog) in [
        ("returned in the panel", Some(ok(page(false))), None),
        (
            "confirmed in the dialog",
            None,
            Some(json!({ "confirmed": true })),
        ),
        ("cancelled", None, Some(json!({ "cancelled": true }))),
    ] {
        {
            let mut answers = agent.answers.lock().unwrap();
            if let Some(panel) = panel {
                answers
                    .browser
                    .insert("wait_control".to_owned(), queue(vec![panel]));
            }
            if let Some(dialog) = dialog {
                answers.dialogs.push_back(dialog);
            }
        }
        agent.push([
            ptc(
                "h1",
                &script(&[(
                    "browser_handoff",
                    json!({ "reason": "  請登入 / Please log in  " }),
                )]),
            ),
            ModelReply::Text("Handed off.".to_owned()),
        ]);
        turn(&mut agent, &mut m, &mut r, step, "Log in for me").await;
    }
    agent.push([
        ptc(
            "h2",
            &script(&[("browser_handoff", json!({ "reason": "   " }))]),
        ),
        ModelReply::Text("No reason.".to_owned()),
    ]);
    turn(&mut agent, &mut m, &mut r, "no reason", "Hand off").await;
    insta::assert_json_snapshot!(
        "agent_browser_tools",
        feature_support::without_ptc_progress(r.into_value())
    );
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_browser_handoff_headless() {
    let Some(mut agent) = AgentRun::start(browser_options(vec!["--headless".to_owned()])).await
    else {
        return;
    };
    let mut r = Recorder::new(&agent);
    let mut m = Masker::new();
    agent.push([
        ptc(
            "h1",
            &script(&[("browser_handoff", json!({ "reason": "Log in" }))]),
        ),
        ModelReply::Text("Nobody.".to_owned()),
    ]);
    turn(&mut agent, &mut m, &mut r, "handoff", "Hand off").await;
    insta::assert_json_snapshot!(
        "agent_browser_handoff_headless",
        feature_support::without_ptc_progress(r.into_value())
    );
}
