//! Agent teams (`agent/features/team/`, feature `agent-team`) with real
//! children, with the test playing the parent's node: `agent_spawn` and
//! `subagent` start the agent executable under test as child processes
//! (the same executable, with the parent's environment, so the children
//! reach the same fake inference socket), children post to the shared
//! board, report back and ask questions, the parent waits for its workers
//! before it settles (the completion barrier), takes steering meanwhile,
//! and holds late results after an abort until the next prompt
//! (`agent-team.test.ts`, `agent-team-completion.test.ts`). The team tools
//! are not direct tools: the model reaches them only from `ptc` scripts,
//! so these transcripts replay only on an agent with the PTC runtime
//! (docs/architecture/ptc.md).
//!
//! The children's model replies are routed by what only their requests
//! contain (`Team message (agent data` for a teammate, `You are a one-shot
//! subagent` for a subagent), and the children's first replies are held
//! (`Gate`) until the parent waits, so the parent's lines come in one
//! order.

use std::sync::LazyLock;

use pirc_conformance::{AgentOptions, AgentRun, Gate, ModelReply, Recorder};
use regex::Regex;
use serde_json::{Value, json};

const TEAMMATE: &str = "Team message (agent data";
const SUBAGENT: &str = "You are a one-shot subagent";

/// A `ptc` call running one capability, as `ptcCall` in the TS tests.
fn ptc(id: &str, name: &str, args: Value) -> ModelReply {
    let code = format!(
        "const r = await tools.call({}, {args});\nif (!r.ok) throw new PtcError(r.error);\nreturn r.data.text;",
        json!(name)
    );
    ptc_code(id, &code)
}

fn ptc_code(id: &str, code: &str) -> ModelReply {
    ModelReply::tool(id, "ptc", json!({ "code": code }))
}

fn text(value: &str) -> ModelReply {
    ModelReply::Text(value.to_owned())
}

fn options() -> AgentOptions {
    AgentOptions::default().features("agent-team")
}

static VOLATILE: LazyLock<Vec<(Regex, &'static str)>> = LazyLock::new(|| {
    [
        // The team's directory under the session (`randomUUID().slice(0, 8)`).
        (r"/team/[0-9a-f]{8}", "/team/<team>"),
        // Generated subagent names.
        (r"\bsub-[0-9a-f]{6}\b", "sub-<name>"),
        (r#""pid":\d+"#, r#""pid":"<pid>""#),
    ]
    .into_iter()
    .map(|(pattern, placeholder)| (Regex::new(pattern).unwrap(), placeholder))
    .collect()
});

/// Process ids, generated names, team directories and script timings
/// vary between runs.
fn mask(value: &mut Value) {
    match value {
        Value::String(text) => {
            for (pattern, placeholder) in VOLATILE.iter() {
                if pattern.is_match(text) {
                    *text = pattern.replace_all(text, *placeholder).into_owned();
                }
            }
        }
        Value::Array(items) => items.iter_mut().for_each(mask),
        Value::Object(object) => {
            for (key, item) in object.iter_mut() {
                if (key == "pid" || key.ends_with("Ms")) && item.is_number() {
                    *item = json!(format!("<{key}>"));
                } else {
                    mask(item);
                }
            }
        }
        _ => {}
    }
}

fn masked(value: Value) -> Value {
    let mut value = value;
    mask(&mut value);
    value
}

/// Whether a request came from a child (its messages carry the child's
/// task).
fn is_child(request: &Value) -> bool {
    let messages = request["messages"].to_string();
    messages.contains(TEAMMATE) || messages.contains(SUBAGENT)
}

/// Events, then the parent's and the children's requests apart. A
/// script's progress updates are left out: they are throttled by time.
fn record(agent: &AgentRun, r: &mut Recorder, step: &str, events: Vec<Value>) {
    let events: Vec<Value> = events
        .into_iter()
        .filter(|event| event["type"] != "tool_execution_update" || event["toolName"] != "ptc")
        .collect();
    r.note(&format!("{step}: events"), masked(json!(events)));
    let (children, parent): (Vec<Value>, Vec<Value>) = agent
        .take_requests()
        .into_iter()
        .map(masked)
        .partition(is_child);
    r.requests(&format!("{step}: parent requests"), parent);
    r.note(&format!("{step}: child requests"), json!(children));
}

/// The parent waits for its team (`completion-wait` status set).
fn waiting(line: &Value) -> bool {
    line["type"] == "extension_ui_request"
        && line["method"] == "setStatus"
        && line["statusKey"] == "completion-wait"
        && line["statusText"].is_string()
}

/// The team status line names a member in a state.
fn team_status(state: &'static str) -> impl FnMut(&Value) -> bool {
    move |line: &Value| {
        line["type"] == "extension_ui_request"
            && line["statusKey"] == "agent-team"
            && line["statusText"]
                .as_str()
                .is_some_and(|text| text.contains(state))
    }
}

fn ended(id: &'static str) -> impl FnMut(&Value) -> bool {
    move |line: &Value| {
        line["type"] == "tool_execution_end"
            && line["toolCallId"] == id
            && line.get("parentToolCallId").is_none()
    }
}

/// The process ids a transcript's text mentions (`"pid":123`).
fn pids(lines: &[Value]) -> Vec<i32> {
    let pattern = Regex::new(r#"\\?"pid\\?":(\d+)"#).unwrap();
    let text = json!(lines).to_string();
    let mut out: Vec<i32> = pattern
        .captures_iter(&text)
        .filter_map(|found| found[1].parse().ok())
        .collect();
    out.sort_unstable();
    out.dedup();
    out
}

async fn close(agent: AgentRun, r: &mut Recorder, children: &[i32]) {
    let (lines, code) = agent.close().await;
    r.note("shutdown", masked(json!(lines)));
    r.note("exit code", json!(code));
    // The children are gone with their parent.
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    let alive: Vec<bool> = children
        .iter()
        .map(|pid| std::path::Path::new(&format!("/proc/{pid}")).exists())
        .collect();
    r.note("children alive after shutdown", json!(alive));
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_team_spawn() {
    let Some(mut agent) = AgentRun::start(options()).await else {
        return;
    };
    let mut r = Recorder::new(&agent);
    let gate = Gate::new();
    agent.route(
        TEAMMATE,
        [
            ModelReply::gated(
                &gate,
                ptc(
                    "c1",
                    "board_post",
                    json!({ "topic": "notes", "body": "child note" }),
                ),
            ),
            text("hi from helper"),
        ],
    );
    agent.push([
        ptc(
            "p1",
            "agent_spawn",
            json!({ "name": "helper", "task": "say hi" }),
        ),
        text("spawned"),
        ptc("p2", "board_read", json!({})),
        text("all done"),
    ]);
    let response = agent
        .call(json!({ "type": "prompt", "message": "spawn a helper" }))
        .await;
    r.note("spawn: response", response);
    let mut events = agent.until(waiting).await;
    gate.open();
    events.extend(agent.settle().await);
    let children = pids(&events);
    record(&agent, &mut r, "spawn", events);
    let panel = agent.call(json!({ "type": "get_panel_state" })).await;
    r.note("panel", masked(panel));
    r.note("children", json!(children.len()));
    close(agent, &mut r, &children).await;
    insta::assert_json_snapshot!("agent_team_spawn", r.into_value());
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_team_invalid() {
    let Some(mut agent) = AgentRun::start(options()).await else {
        return;
    };
    let mut r = Recorder::new(&agent);
    agent.push([
        ptc("a", "agent_spawn", json!({ "name": "Parent", "task": "x" })),
        ptc("b", "agent_wait", json!({ "agent": "nobody" })),
        ptc(
            "c",
            "agent_send",
            json!({ "to": "nobody", "message": "hi" }),
        ),
        ptc("d", "agent_stop", json!({ "agent": "nobody" })),
        ptc(
            "e",
            "task_update",
            json!({ "task_id": "1", "action": "claim" }),
        ),
        ptc(
            "f",
            "agent_spawn",
            json!({ "name": "helper", "task": "x", "cwd": "/" }),
        ),
        ptc("g", "subagent", json!({ "task": "x", "cwd": "missing" })),
        text("ok"),
    ]);
    let response = agent
        .call(json!({ "type": "prompt", "message": "try" }))
        .await;
    r.note("invalid calls: response", response);
    let events = agent.settle().await;
    record(&agent, &mut r, "invalid calls", events);
    close(agent, &mut r, &[]).await;
    insta::assert_json_snapshot!("agent_team_invalid", r.into_value());
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_team_tasks() {
    let Some(mut agent) = AgentRun::start(options()).await else {
        return;
    };
    let mut r = Recorder::new(&agent);
    let code = r#"const out = [];
const call = async (run) => {
  try {
    out.push((await run()).text);
  } catch (error) {
    out.push(`error: ${error.message}`);
  }
};
await call(() => tools.task_create({ subject: 'Design', description: 'Write the design' }));
await call(() => tools.task_create({ subject: 'Build', description: 'Build it', blocked_by: ['1'] }));
await call(() => tools.task_update({ task_id: '2', action: 'claim' }));
await call(() => tools.task_update({ task_id: '1', action: 'claim', expected_revision: 3 }));
await call(() => tools.task_update({ task_id: '1', action: 'claim' }));
await call(() => tools.task_update({ task_id: '1', action: 'complete' }));
await call(() => tools.task_list({ ready: true }));
await call(() => tools.task_update({ task_id: '1', action: 'set_dependencies', blocked_by: ['2'] }));
await call(() => tools.task_update({ task_id: '2', action: 'set_dependencies', blocked_by: ['2'] }));
await call(() => tools.task_update({ task_id: '1', action: 'reopen' }));
await call(() => tools.task_update({ task_id: '1', action: 'edit', subject: 'Design v2' }));
await call(() => tools.task_update({ task_id: '2', action: 'assign', owner: 'nobody' }));
await call(() => tools.task_update({ task_id: '1', action: 'delete' }));
await call(() => tools.task_get({ task_id: '2' }));
await call(() => tools.board_post({ topic: 'plan', body: 'first' }));
await call(() => tools.board_post({ topic: 'plan', body: 'reply', reply_to: 'missing' }));
await call(() => tools.board_read({ topic: 'plan' }));
await call(() => tools.agent_inbox({ limit: 2 }));
await call(() => tools.agent_list());
return out.join('\n');"#;
    agent.push([ptc_code("t1", code), text("Planned.")]);
    let response = agent
        .call(json!({ "type": "prompt", "message": "plan the work" }))
        .await;
    r.note("tasks: response", response);
    let events = agent.settle().await;
    record(&agent, &mut r, "tasks", events);
    let panel = agent.call(json!({ "type": "get_panel_state" })).await;
    r.note("panel", masked(panel));
    close(agent, &mut r, &[]).await;
    insta::assert_json_snapshot!("agent_team_tasks", r.into_value());
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_team_background_subagent() {
    let Some(mut agent) = AgentRun::start(options()).await else {
        return;
    };
    let mut r = Recorder::new(&agent);
    let gate = Gate::new();
    agent.route(
        SUBAGENT,
        [ModelReply::gated(&gate, text("gated background report"))],
    );
    agent.push([
        ptc(
            "spawn",
            "subagent",
            json!({ "task": "gated work", "background": true }),
        ),
        text("interim final"),
        text("integrated background report"),
    ]);
    let response = agent
        .call(json!({ "type": "prompt", "message": "delegate work" }))
        .await;
    r.note("delegate: response", response);
    let mut events = agent.until(waiting).await;
    // The RPC loop answers while the parent waits.
    for _ in 0..3 {
        let state = agent.call(json!({ "type": "get_state" })).await;
        r.note("state while waiting", state["data"]["isStreaming"].clone());
    }
    gate.open();
    events.extend(agent.settle().await);
    let children = pids(&events);
    record(&agent, &mut r, "delegate", events);
    close(agent, &mut r, &children).await;
    insta::assert_json_snapshot!("agent_team_background_subagent", r.into_value());
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_team_foreground_subagent() {
    let Some(mut agent) = AgentRun::start(options()).await else {
        return;
    };
    let mut r = Recorder::new(&agent);
    agent.route(
        SUBAGENT,
        [text("first report"), ModelReply::Failed("boom".to_owned())],
    );
    agent.push([
        ptc(
            "s1",
            "subagent",
            json!({ "task": "report", "name": "once", "role": "general" }),
        ),
        ptc("s2", "subagent", json!({ "task": "fail", "name": "twice" })),
        ptc("s3", "subagent", json!({ "task": "again", "name": "once" })),
        text("Collected."),
    ]);
    let response = agent
        .call(json!({ "type": "prompt", "message": "run subagents" }))
        .await;
    r.note("subagents: response", response);
    let events = agent.settle().await;
    let children = pids(&events);
    record(&agent, &mut r, "subagents", events);
    let panel = agent.call(json!({ "type": "get_panel_state" })).await;
    r.note("panel", masked(panel));
    close(agent, &mut r, &children).await;
    insta::assert_json_snapshot!("agent_team_foreground_subagent", r.into_value());
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_team_steer_while_waiting() {
    let Some(mut agent) = AgentRun::start(options()).await else {
        return;
    };
    let mut r = Recorder::new(&agent);
    let gate = Gate::new();
    agent.route(
        TEAMMATE,
        [ModelReply::gated(&gate, text("persistent worker report"))],
    );
    agent.push([
        ptc(
            "spawn",
            "agent_spawn",
            json!({ "name": "helper", "task": "complete gated work" }),
        ),
        text("interim"),
        text("steering accepted"),
        text("integrated"),
    ]);
    let response = agent
        .call(json!({ "type": "prompt", "message": "start helper" }))
        .await;
    r.note("start: response", response);
    let mut events = agent.until(waiting).await;
    let response = agent
        .call(json!({ "type": "steer", "message": "include the audit detail" }))
        .await;
    r.note("steer: response", response);
    events.extend(agent.until(waiting).await);
    gate.open();
    events.extend(agent.settle().await);
    let children = pids(&events);
    record(&agent, &mut r, "start", events);
    let panel = agent.call(json!({ "type": "get_panel_state" })).await;
    r.note("panel", masked(panel));
    close(agent, &mut r, &children).await;
    insta::assert_json_snapshot!("agent_team_steer_while_waiting", r.into_value());
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_team_abort_holds_results() {
    let Some(mut agent) = AgentRun::start(options()).await else {
        return;
    };
    let mut r = Recorder::new(&agent);
    let gate = Gate::new();
    agent.route(
        TEAMMATE,
        [ModelReply::gated(&gate, text("late worker report"))],
    );
    agent.push([
        ptc(
            "spawn",
            "agent_spawn",
            json!({ "name": "helper", "task": "complete gated work" }),
        ),
        text("interim"),
        text("resumed"),
        text("integrated late report"),
    ]);
    let response = agent
        .call(json!({ "type": "prompt", "message": "start helper" }))
        .await;
    r.note("start: response", response);
    let mut events = agent.until(waiting).await;
    let response = agent.call(json!({ "type": "abort" })).await;
    r.note("abort: response", response);
    events.extend(agent.settle().await);
    let children = pids(&events);
    record(&agent, &mut r, "start", events);
    // The report arrives while idle: recorded, not delivered.
    gate.open();
    let events = agent.until(team_status("helper:idle")).await;
    let state = agent.call(json!({ "type": "get_state" })).await;
    r.note("state", state["data"]["isStreaming"].clone());
    record(&agent, &mut r, "late report", events);
    let response = agent
        .call(json!({ "type": "prompt", "message": "now integrate the pending report" }))
        .await;
    r.note("integrate: response", response);
    let events = agent.settle().await;
    record(&agent, &mut r, "integrate", events);
    close(agent, &mut r, &children).await;
    insta::assert_json_snapshot!("agent_team_abort_holds_results", r.into_value());
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_team_question() {
    let Some(mut agent) = AgentRun::start(options()).await else {
        return;
    };
    let mut r = Recorder::new(&agent);
    let (asked, finish, answer) = (Gate::new(), Gate::new(), Gate::new());
    agent.route(
        TEAMMATE,
        [
            ModelReply::gated(
                &asked,
                ptc(
                    "question",
                    "agent_ask",
                    json!({ "to": "parent", "question": "Which format?" }),
                ),
            ),
            text("waiting for format"),
            ModelReply::gated(&finish, text("finished in approved format")),
        ],
    );
    // The parent finds the question in its inbox and answers it.
    let reply = r#"const inbox = await tools.call('agent_inbox', {});
if (!inbox.ok) throw new PtcError(inbox.error);
const question = inbox.data.items.find((item) => item.kind === 'question');
const r = await tools.call('agent_reply', { question_id: question.id, answer: 'Use JSON' });
if (!r.ok) throw new PtcError(r.error);
return r.data.text;"#;
    agent.push([
        ptc(
            "spawn",
            "agent_spawn",
            json!({ "name": "helper", "task": "complete gated work" }),
        ),
        text("interim"),
        ModelReply::gated(&answer, ptc_code("answer", reply)),
        text("answered"),
        text("integrated teammate progress"),
    ]);
    let response = agent
        .call(json!({ "type": "prompt", "message": "delegate and answer questions" }))
        .await;
    r.note("delegate: response", response);
    let mut events = agent.until(waiting).await;
    asked.open();
    // The helper asked and settled waiting for the answer.
    events.extend(agent.until(team_status("helper:waiting")).await);
    answer.open();
    events.extend(agent.until(ended("answer")).await);
    events.extend(agent.until(waiting).await);
    finish.open();
    events.extend(agent.settle().await);
    let children = pids(&events);
    record(&agent, &mut r, "delegate", events);
    close(agent, &mut r, &children).await;
    insta::assert_json_snapshot!("agent_team_question", r.into_value());
}
