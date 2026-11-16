//! Auto mode around `ptc` scripts (`agent-auto-mode.test.ts`,
//! docs/architecture/ptc.md): shell calls a script makes are gated one by one
//! (refused without a UI, asked about with one, withdrawn when the run is
//! cancelled), the user's deny-list applies to the script text itself, and
//! an ordinary script is neither classified nor leased. These need the PTC
//! runtime (the `m5-ptc` port) to replay against the Rust agent.

mod feature_support;

use std::collections::VecDeque;
use std::time::Duration;

use pirc_conformance::{AgentOptions, AgentRun, ModelReply, Recorder};
use serde_json::{Value, json};

/// `rm -rf ~` aims at a home that does not exist and lies outside the
/// scratch directories (the harness's temporary home counts as scratch).
const NO_HOME: &str = "/nonexistent/pirc-auto-mode-home";

fn ptc(id: &str, code: &str) -> ModelReply {
    ModelReply::tool(id, "ptc", json!({ "code": code }))
}

fn options(config: Value, headless: bool) -> AgentOptions {
    let mut options = AgentOptions {
        config,
        ..AgentOptions::default()
    };
    options.env.push(("HOME".to_owned(), NO_HOME.to_owned()));
    if headless {
        options.args.push("--headless".to_owned());
    }
    options
}

/// Operation timings differ between runs.
fn mask(value: &mut Value) {
    match value {
        Value::Array(items) => items.iter_mut().for_each(mask),
        Value::Object(object) => {
            for (key, item) in object.iter_mut() {
                if ["durationMs", "activeMs", "waitedMs"].contains(&key.as_str())
                    && item.is_number()
                {
                    *item = json!("<ms>");
                } else {
                    mask(item);
                }
            }
        }
        _ => {}
    }
}

/// The events of a step, then the requests the agent made.
fn record(r: &mut Recorder, agent: &AgentRun, step: &str, mut events: Vec<Value>) {
    events.iter_mut().for_each(mask);
    r.note(&format!("{step}: events"), json!(events));
    let mut requests = agent.take_requests();
    requests.iter_mut().for_each(mask);
    r.requests(&format!("{step}: model requests"), requests);
}

fn session(r: &mut Recorder, agent: &AgentRun) {
    let mut entries = json!(agent.session_entries());
    mask(&mut entries);
    r.note("session file", entries);
}

/// A prompt and everything the agent does until it settles.
async fn turn(agent: &mut AgentRun, r: &mut Recorder, step: &str, message: &str) {
    let response = agent
        .call(json!({ "type": "prompt", "message": message }))
        .await;
    r.note(&format!("{step}: response"), response);
    let events = agent.settle().await;
    record(r, agent, step, events);
}

fn exists(agent: &AgentRun, r: &mut Recorder, files: &[&str]) {
    let found: Vec<Value> = files
        .iter()
        .map(|file| json!([file, agent.workspace.join(file).exists()]))
        .collect();
    r.note("files", json!(found));
}

/// Without a UI, a dangerous bash call from a script fails with
/// `ApprovalDenied` and no dialog.
#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_auto_mode_ptc_headless() {
    let Some(mut agent) = AgentRun::start(options(json!({}), true)).await else {
        return;
    };
    let mut r = Recorder::new(&agent);
    agent.push([
        ptc(
            "p",
            "const r = await tools.call(\"bash\", { command: \"rm -rf ~\" }); return r.ok ? \"ran\" : r.error.code + \": \" + r.error.message;",
        ),
        ModelReply::tool("d", "bash", json!({ "command": "rm -rf ~" })),
        ModelReply::Text("Done.".to_owned()),
    ]);
    turn(&mut agent, &mut r, "refused", "go").await;
    r.note("exit code", json!(agent.finish().await));
    insta::assert_json_snapshot!(
        "agent_auto_mode_ptc_headless",
        feature_support::without_ptc_progress(r.into_value())
    );
}

/// With a UI, a dangerous bash call from a script asks the human and runs
/// only when approved.
#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_auto_mode_ptc_approval() {
    let Some(mut agent) = AgentRun::start(options(json!({}), false)).await else {
        return;
    };
    let mut r = Recorder::new(&agent);
    agent.answers.lock().unwrap().dialogs =
        VecDeque::from([json!({ "confirmed": false }), json!({ "confirmed": true })]);
    let script = |file: &str| {
        format!(
            "return await tools.bash({{ command: \"git push --force nowhere 2>/dev/null; touch {file}\" }});"
        )
    };
    agent.push([
        ptc("p1", &script("declined.txt")),
        ptc("p2", &script("ran.txt")),
        ModelReply::Text("Done.".to_owned()),
    ]);
    turn(&mut agent, &mut r, "asked", "go").await;
    exists(&agent, &mut r, &["declined.txt", "ran.txt"]);
    session(&mut r, &agent);
    r.note("exit code", json!(agent.finish().await));
    insta::assert_json_snapshot!(
        "agent_auto_mode_ptc_approval",
        feature_support::without_ptc_progress(r.into_value())
    );
}

/// Cancelling a script while its approval dialog is open withdraws the
/// dialog; a late "yes" grants nothing and the operation never runs.
#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_auto_mode_ptc_cancel() {
    let Some(mut agent) = AgentRun::start(options(json!({}), false)).await else {
        return;
    };
    let mut r = Recorder::new(&agent);
    agent.answers.lock().unwrap().dialogs = VecDeque::from([Value::Null]);
    agent.push([
        ptc(
            "p1",
            "await tools.write({ path: 'before.txt', content: '1' });\n await tools.bash({ command: \"git push --force nowhere 2>/dev/null; touch cancelled.txt\" });",
        ),
        ModelReply::Text("Done.".to_owned()),
    ]);
    let response = agent
        .call(json!({ "type": "prompt", "message": "go" }))
        .await;
    r.note("prompt: response", response);
    let mut events = agent
        .until(|line| line["type"] == "extension_ui_request" && line["method"] == "confirm")
        .await;
    let dialog = events.last().unwrap()["id"].clone();
    let response = agent.call(json!({ "type": "abort" })).await;
    r.note("abort: response", response);
    events.extend(agent.settle().await);
    events.retain(|line| line["type"] != "response");
    record(&mut r, &agent, "prompt", events);
    agent
        .send(json!({ "type": "extension_ui_response", "id": dialog, "confirmed": true }))
        .await;
    tokio::time::sleep(Duration::from_millis(200)).await;
    exists(&agent, &mut r, &["before.txt", "cancelled.txt"]);
    session(&mut r, &agent);
    r.note("exit code", json!(agent.finish().await));
    insta::assert_json_snapshot!(
        "agent_auto_mode_ptc_cancel",
        feature_support::without_ptc_progress(r.into_value())
    );
}

const DENY_SCRIPT: &str = "const note = \"forbidden-word\"; return note.length;";

fn deny_config() -> Value {
    json!({ "features": { "autoMode": { "deny": ["forbidden-word"] } } })
}

/// The user's deny-list applies to the script text itself: refused
/// without a UI, before the script runs.
#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_auto_mode_ptc_deny_headless() {
    let Some(mut agent) = AgentRun::start(options(deny_config(), true)).await else {
        return;
    };
    let mut r = Recorder::new(&agent);
    agent.push([ptc("h", DENY_SCRIPT), ModelReply::Text("Done.".to_owned())]);
    turn(&mut agent, &mut r, "refused", "go").await;
    r.note("exit code", json!(agent.finish().await));
    insta::assert_json_snapshot!(
        "agent_auto_mode_ptc_deny_headless",
        feature_support::without_ptc_progress(r.into_value())
    );
}

/// With a UI, a denied script text asks the human; approved, it runs.
#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_auto_mode_ptc_deny_approval() {
    let Some(mut agent) = AgentRun::start(options(deny_config(), false)).await else {
        return;
    };
    let mut r = Recorder::new(&agent);
    agent.answers.lock().unwrap().dialogs =
        VecDeque::from([json!({ "confirmed": false }), json!({ "confirmed": true })]);
    agent.push([
        ptc("d", DENY_SCRIPT),
        ptc("a", DENY_SCRIPT),
        ModelReply::Text("Done.".to_owned()),
    ]);
    turn(&mut agent, &mut r, "asked", "go").await;
    r.note("exit code", json!(agent.finish().await));
    insta::assert_json_snapshot!(
        "agent_auto_mode_ptc_deny_approval",
        feature_support::without_ptc_progress(r.into_value())
    );
}

/// With the classifier on, a script's own text is neither classified nor
/// leased; only the write its bash call makes takes the lease. (No
/// classifier reply is queued: a classifier request would take a main
/// reply and change the transcript.)
#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_auto_mode_ptc_unclassified() {
    let config = json!({ "features": { "autoMode": { "useModel": true } } });
    let Some(mut agent) = AgentRun::start(options(config, false)).await else {
        return;
    };
    let mut r = Recorder::new(&agent);
    agent.push([
        ptc(
            "plain",
            "const words = [\"Bun.$\", \"spawn\"]; return words.join(\" \");",
        ),
        ptc(
            "reads",
            "return (await tools.bash({ command: \"echo hi\" })).text.split(\"\\n\")[0];",
        ),
        ptc(
            "writes",
            "await tools.bash({ command: \"touch made.txt\" }); return \"made\";",
        ),
        ModelReply::Text("Done.".to_owned()),
    ]);
    turn(&mut agent, &mut r, "scripts", "go").await;
    exists(&agent, &mut r, &["made.txt"]);
    r.note("exit code", json!(agent.finish().await));
    insta::assert_json_snapshot!(
        "agent_auto_mode_ptc_unclassified",
        feature_support::without_ptc_progress(r.into_value())
    );
}

/// Approval modes (security audit L14): a headless agent in the node's
/// `read-only` mode is refused a write, from a script and directly; switched
/// to `full-access` over RPC (recorded in the session, reported by
/// `get_state`) the same write runs, and the deny-list still refuses.
#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_approval_modes() {
    let config = json!({ "features": { "autoMode": {
        "mode": "read-only", "useModel": false, "deny": ["forbidden-word"] } } });
    let Some(mut agent) = AgentRun::start(options(config, true)).await else {
        return;
    };
    let mut r = Recorder::new(&agent);
    let state = agent.call(json!({ "type": "get_state" })).await;
    r.note(
        "read-only: state",
        json!([
            state["data"]["approvalMode"],
            state["data"]["defaultApprovalMode"]
        ]),
    );
    agent.push([
        ptc(
            "p",
            "const r = await tools.call(\"bash\", { command: \"touch from-script.txt\" }); return r.ok ? \"ran\" : r.error.code + \": \" + r.error.message;",
        ),
        ModelReply::tool("w", "write", json!({ "path": "written.txt", "content": "x" })),
        ModelReply::Text("Done.".to_owned()),
    ]);
    turn(&mut agent, &mut r, "read-only", "go").await;
    let response = agent
        .call(json!({ "type": "set_approval_mode", "mode": "yolo" }))
        .await;
    r.note("an unknown mode: response", response);
    let response = agent
        .call(json!({ "type": "set_approval_mode", "mode": "full-access" }))
        .await;
    // Its `approval_mode_changed` event comes with the next turn's events.
    r.note("full access: response", response);
    let state = agent.call(json!({ "type": "get_state" })).await;
    r.note(
        "full access: state",
        json!([
            state["data"]["approvalMode"],
            state["data"]["defaultApprovalMode"]
        ]),
    );
    agent.push([
        ModelReply::tool("b", "bash", json!({ "command": "touch from-bash.txt" })),
        ModelReply::tool(
            "w2",
            "write",
            json!({ "path": "written.txt", "content": "x" }),
        ),
        ModelReply::tool("d", "bash", json!({ "command": "echo forbidden-word" })),
        ModelReply::Text("Done.".to_owned()),
    ]);
    turn(&mut agent, &mut r, "full access", "again").await;
    exists(
        &agent,
        &mut r,
        &["from-script.txt", "written.txt", "from-bash.txt"],
    );
    session(&mut r, &agent);
    r.note("exit code", json!(agent.finish().await));
    insta::assert_json_snapshot!(
        "agent_approval_modes",
        feature_support::without_ptc_progress(r.into_value())
    );
}
