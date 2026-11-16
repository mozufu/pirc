//! `ask_user_question` (`agent/features/ask-question.ts`, feature
//! `ask-question`), with the test playing the agent's node: questions as
//! `extension_ui_request` dialogs, structured answers, typed answers,
//! cancellation and aborts, invalid questionnaires, headless agents. The
//! tool is not a direct tool: the model reaches it only from a `ptc`
//! script, so these transcripts replay only on an agent with the PTC
//! runtime (docs/architecture/ptc.md).

mod feature_support;

use std::collections::VecDeque;

use pirc_conformance::{AgentOptions, AgentRun, ModelReply, Recorder};
use serde_json::{Value, json};

/// A `ptc` call running one capability, as `ptcCall` in the TS tests.
fn ptc(id: &str, name: &str, args: Value) -> ModelReply {
    let code = format!(
        "const r = await tools.call({}, {args});\nif (!r.ok) throw new PtcError(r.error);\nreturn r.data.text;",
        json!(name)
    );
    ModelReply::tool(id, "ptc", json!({ "code": code }))
}

fn ask(id: &str, questions: Value) -> ModelReply {
    ptc(id, "ask_user_question", json!({ "questions": questions }))
}

fn text(value: &str) -> ModelReply {
    ModelReply::Text(value.to_owned())
}

fn options() -> AgentOptions {
    AgentOptions::default().features("ask-question")
}

/// Script timings (`activeMs`, `durationMs`, `waitedMs`) vary between
/// runs.
fn mask_times(value: &mut Value) {
    match value {
        Value::Array(items) => items.iter_mut().for_each(mask_times),
        Value::Object(object) => {
            for (key, item) in object.iter_mut() {
                if key.ends_with("Ms") && item.is_number() {
                    *item = json!("<ms>");
                } else {
                    mask_times(item);
                }
            }
        }
        _ => {}
    }
}

/// A prompt and everything until the run settles.
async fn turn(agent: &mut AgentRun, r: &mut Recorder, step: &str, message: &str) {
    let response = agent
        .call(json!({ "type": "prompt", "message": message }))
        .await;
    r.note(&format!("{step}: response"), response);
    let events = agent.settle().await;
    record(agent, r, step, events);
}

/// Events, then the requests the agent made, with timings masked.
fn record(agent: &AgentRun, r: &mut Recorder, step: &str, events: Vec<Value>) {
    let mut events = json!(events);
    mask_times(&mut events);
    r.note(&format!("{step}: events"), events);
    let mut requests = json!(agent.take_requests());
    mask_times(&mut requests);
    let requests = match requests {
        Value::Array(items) => items,
        _ => Vec::new(),
    };
    r.requests(&format!("{step}: model requests"), requests);
}

/// The session file, with timings masked.
fn session(agent: &AgentRun, r: &mut Recorder) {
    let mut entries = json!(agent.session_entries());
    mask_times(&mut entries);
    r.note("session file", entries);
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_ask_question() {
    let Some(mut agent) = AgentRun::start(options()).await else {
        return;
    };
    let mut r = Recorder::new(&agent);
    agent.answers.lock().unwrap().dialogs = VecDeque::from([
        json!({ "value": "postgres" }),
        // Blank answers are asked again.
        json!({ "value": "   " }),
        json!({ "value": "  no  " }),
        json!({ "value": "a, Other (type your own answer)",
            "values": ["a", "Other (type your own answer)"] }),
        json!({ "value": "c" }),
        // A cancelled dialog cancels the questionnaire.
        json!({ "cancelled": true }),
    ]);
    agent.push([
        ask(
            "q1",
            json!([
                { "question": "Which DB?", "header": "DB",
                  "options": [{ "label": "sqlite", "description": "embedded" }, { "label": "postgres" }] },
                { "question": "Anything else?" },
            ]),
        ),
        ask(
            "q2",
            json!([{ "question": "Pick", "multiSelect": true,
                "options": [{ "label": "a" }, { "label": "b" }] }]),
        ),
        ask(
            "q3",
            json!([{ "question": "First?" }, { "question": "Second?" }]),
        ),
        text("thanks"),
    ]);
    turn(&mut agent, &mut r, "answered", "ask me").await;
    session(&agent, &mut r);
    insta::assert_json_snapshot!(
        "agent_ask_question",
        feature_support::without_ptc_progress(r.into_value())
    );
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_ask_question_invalid() {
    let Some(mut agent) = AgentRun::start(options()).await else {
        return;
    };
    let mut r = Recorder::new(&agent);
    let q = |text: &str| json!({ "question": text });
    agent.push([
        ask("i1", json!([])),
        ask("i2", json!([q("1"), q("2"), q("3"), q("4"), q("5")])),
        ask("i3", json!([q("   ")])),
        ask(
            "i4",
            json!([{ "question": "x", "header": "h".repeat(121) }]),
        ),
        ask(
            "i5",
            json!([{ "question": "x", "options": [{ "label": "a" }, { "label": "a" }] }]),
        ),
        ask(
            "i6",
            json!([{ "question": "x", "options": [{ "label": "Other (type your own answer)" }] }]),
        ),
        ask("i7", json!([q("bell\u{7}")])),
        ask("i8", json!([{ "question": "x", "multiSelect": "yes" }])),
        ask("i9", json!([q(&"x".repeat(24_000))])),
        text("gave up"),
    ]);
    turn(&mut agent, &mut r, "invalid questionnaires", "ask badly").await;
    insta::assert_json_snapshot!(
        "agent_ask_question_invalid",
        feature_support::without_ptc_progress(r.into_value())
    );
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_ask_question_abort() {
    let Some(mut agent) = AgentRun::start(options()).await else {
        return;
    };
    let mut r = Recorder::new(&agent);
    agent.answers.lock().unwrap().dialogs = VecDeque::from([json!({ "hold": true })]);
    agent.push([ask("q1", json!([{ "question": "Wait?" }]))]);
    let response = agent
        .call(json!({ "type": "prompt", "message": "ask again" }))
        .await;
    r.note("prompt", response);
    let asked = agent
        .until(|line| line["type"] == "extension_ui_request" && line["method"] == "input")
        .await;
    r.note("asked", json!(asked));
    let abort = agent.call(json!({ "type": "abort" })).await;
    r.note("abort", abort);
    let events = agent.settle().await;
    record(&agent, &mut r, "aborted", events);
    insta::assert_json_snapshot!(
        "agent_ask_question_abort",
        feature_support::without_ptc_progress(r.into_value())
    );
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_ask_question_headless() {
    let Some(mut agent) = AgentRun::start(AgentOptions {
        args: vec!["--headless".to_owned()],
        ..options()
    })
    .await
    else {
        return;
    };
    let mut r = Recorder::new(&agent);
    agent.push([ask("q4", json!([{ "question": "x" }])), text("ok")]);
    turn(&mut agent, &mut r, "unavailable", "go").await;
    insta::assert_json_snapshot!(
        "agent_ask_question_headless",
        feature_support::without_ptc_progress(r.into_value())
    );
}
