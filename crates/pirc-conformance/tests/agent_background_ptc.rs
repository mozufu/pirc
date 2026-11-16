//! The `background_task` tool (`agent/features/background/`), with the
//! test playing the agent's node. `background_task` is not a direct tool:
//! the model reaches it only from a `ptc` script, so these transcripts
//! replay only on an agent with the PTC runtime (docs/architecture/ptc.md).
//! The slash commands, the panel and wake-ups without the tool are in
//! `agent_background.rs`. Tasks finish inside a blocking call (`wait`,
//! `stop`) or wait for a trigger file the test creates, so they finish at
//! known points.

mod background_support;
mod feature_support;

use std::time::Duration;

use background_support::{TaskMask, after, notified, release};
use feature_support::{Masker, ptc};
use pirc_conformance::{AgentOptions, AgentRun, Gate, ModelReply, Recorder};
use serde_json::{Value, json};

const FEATURES: &str = "background-task";

fn text(value: &str) -> ModelReply {
    ModelReply::Text(value.to_owned())
}

/// A script calling `background_task` with each of `calls` (JavaScript
/// object literals that may use `id`, the id of the first task started),
/// returning every outcome as JSON: the result's text, or the error.
fn script(calls: &[&str]) -> String {
    let mut code = String::from(
        "const out = [];\nlet id;\nconst call = async (args) => {\n  const r = await tools.call(\"background_task\", args);\n  out.push(r.ok ? r.data.text : r.error);\n  if (r.ok && r.data.task && id === undefined) id = r.data.task.id;\n  return r;\n};\n",
    );
    for args in calls {
        code.push_str(&format!("await call({args});\n"));
    }
    code.push_str("return JSON.stringify(out);");
    code
}

struct Run {
    r: Recorder,
    t: TaskMask,
    m: Masker,
}

impl Run {
    fn new(agent: &AgentRun) -> Self {
        Self {
            r: Recorder::new(agent),
            t: TaskMask::default(),
            m: Masker::new(),
        }
    }

    /// `tool_execution_update` lines of the `ptc` call are left out: the
    /// agent sends at most one per 100 ms, so how many a script that waits
    /// gives depends on timing.
    fn note(&mut self, step: &str, value: Value) {
        let value = match value {
            Value::Array(lines) => lines
                .into_iter()
                .filter(|line| line["type"] != "tool_execution_update")
                .collect(),
            other => other,
        };
        let value = self.t.mask(value);
        let step = self.t.step(step);
        self.m.note(&mut self.r, &step, value);
    }

    fn requests(&mut self, step: &str, agent: &AgentRun) {
        let requests = self.t.mask(json!(agent.take_requests()));
        let requests = match self.m.mask(requests) {
            Value::Array(items) => items,
            _ => Vec::new(),
        };
        self.r.requests(step, requests);
    }
}

/// Everything until the next `agent_settled`, and the model requests made
/// meanwhile.
async fn settle(agent: &mut AgentRun, run: &mut Run, step: &str) {
    let events = agent.until(|line| line["type"] == "agent_settled").await;
    run.note(&format!("{step}: events"), json!(events));
    run.requests(&format!("{step}: model requests"), agent);
}

/// A prompt and everything until the run settles.
async fn turn(agent: &mut AgentRun, run: &mut Run, step: &str, message: &str) {
    agent
        .command(json!({ "type": "prompt", "message": message }))
        .await;
    settle(agent, run, step).await;
}

/// Lines up to (and with) the first that satisfies `done`, recorded.
async fn then(agent: &mut AgentRun, run: &mut Run, step: &str, done: impl FnMut(&Value) -> bool) {
    let lines = agent.until(done).await;
    run.note(step, json!(lines));
}

/// Wait until `count` model requests arrived (not taken yet).
async fn requests_arrived(agent: &AgentRun, count: usize) {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    while agent.pending_requests() < count {
        assert!(tokio::time::Instant::now() < deadline, "no model request");
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_background_tool() {
    let Some(mut agent) = AgentRun::start(
        AgentOptions {
            files: vec![("sub/file.txt".to_owned(), "x\n".to_owned())],
            ..AgentOptions::default()
        }
        .features(FEATURES),
    )
    .await
    else {
        return;
    };
    let mut run = Run::new(&agent);
    agent.push([
        ptc(
            "t1",
            &script(&[
                r#"{ action: "list" }"#,
                r#"{ action: "start", command: "sleep 0.3; echo hello; pwd; sleep 0.1; echo err >&2", cwd: "sub" }"#,
                r#"{ action: "list" }"#,
                r#"{ action: "wait", id }"#,
                r#"{ action: "output", id }"#,
                r#"{ action: "output", id, lines: 1 }"#,
                r#"{ action: "stop", id }"#,
                r#"{ action: "monitor", id, notify_on: "x" }"#,
                r#"{ action: "write", id, input: "x" }"#,
            ]),
        ),
        ptc(
            "t2",
            &script(&[
                r#"{ action: "start", command: "sleep 30", timeout: 0.2 }"#,
                r#"{ action: "wait", id }"#,
                r#"{ action: "start", command: "sleep 30; echo never" }"#,
                r#"{ action: "list" }"#,
            ]),
        ),
        ptc(
            "t3",
            &script(&[
                r#"{ action: "start", command: "echo started; sleep 30" }"#,
                r#"{ action: "wait", id, timeout: 0.3 }"#,
                r#"{ action: "monitor", id, notify_on: "a/b" }"#,
                r#"{ action: "monitor", id }"#,
                r#"{ action: "monitor", id, notify_on: "(" }"#,
                r#"{ action: "stop", id }"#,
                r#"{ action: "stop", id }"#,
            ]),
        ),
        ptc(
            "t4",
            &script(&[
                r#"{ action: "start" }"#,
                r#"{ action: "start", command: "   " }"#,
                r#"{ action: "start", command: "true", cwd: "missing" }"#,
                r#"{ action: "start", command: "true", cwd: "sub/file.txt" }"#,
                r#"{ action: "start", command: "true", notify_on: "(" }"#,
                r#"{ action: "start", command: "true", notify_on: "" }"#,
                r#"{ action: "start", command: "a\u0000b" }"#,
                r#"{ action: "output" }"#,
                r#"{ action: "output", id: "nope" }"#,
                r#"{ action: "wait", id: "nope" }"#,
                r#"{ action: "write", id: "nope" }"#,
                r#"{ action: "write", id: "nope", input: "x" }"#,
                r#"{ action: "monitor", id: "nope" }"#,
                r#"{ action: "stop", id: "nope" }"#,
                r#"{ action: "frob" }"#,
                r#"{ action: "list", lines: 0 }"#,
            ]),
        ),
        text("Done."),
        text("Noted the stopped tasks."),
    ]);
    turn(&mut agent, &mut run, "tool calls", "Use background tasks").await;
    // Tasks stopped or timed out without a finished wait wake the agent.
    settle(&mut agent, &mut run, "the wake-up").await;
    let session = agent.session_entries();
    run.note("session file", json!(session));
    // The task still running is stopped.
    let (lines, code) = agent.close().await;
    run.note("shutdown", json!(lines));
    run.note("exit code", json!(code));
    insta::assert_json_snapshot!(
        "agent_background_tool",
        feature_support::without_ptc_progress(run.r.into_value())
    );
}

/// `agent-background.test.ts`: "wakes the idle agent once when background
/// work finishes".
#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_background_tool_wake() {
    let Some(mut agent) = AgentRun::start(AgentOptions::default().features(FEATURES)).await else {
        return;
    };
    let mut run = Run::new(&agent);
    agent.push([
        ptc(
            "b1",
            &script(&[&format!(
                "{{ action: \"start\", command: {} }}",
                json!(after("go", "echo built"))
            )]),
        ),
        text("Started the build; I will check when it finishes."),
    ]);
    turn(&mut agent, &mut run, "start", "build in background").await;
    agent.push([text("The build finished.")]);
    release(&agent, "go");
    settle(&mut agent, &mut run, "finished").await;
    tokio::time::sleep(Duration::from_millis(300)).await;
    run.note("later requests", json!(agent.pending_requests()));
    insta::assert_json_snapshot!(
        "agent_background_tool_wake",
        feature_support::without_ptc_progress(run.r.into_value())
    );
}

/// `agent-background.test.ts`: "does not wake the agent for tasks it
/// already waited on".
#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_background_tool_waited() {
    let Some(mut agent) = AgentRun::start(AgentOptions::default().features(FEATURES)).await else {
        return;
    };
    let mut run = Run::new(&agent);
    agent.push([
        ptc(
            "s",
            &script(&[r#"{ action: "start", command: "sleep 1.5; echo quick" }"#]),
        ),
        ptc(
            "w",
            "const l = await tools.call(\"background_task\", { action: \"list\" });\nconst w = await tools.call(\"background_task\", { action: \"wait\", id: l.data.tasks[0].id });\nreturn w.data.text;",
        ),
        text("done"),
    ]);
    turn(&mut agent, &mut run, "quick task", "quick task").await;
    tokio::time::sleep(Duration::from_millis(300)).await;
    run.note("later requests", json!(agent.pending_requests()));
    insta::assert_json_snapshot!(
        "agent_background_tool_waited",
        feature_support::without_ptc_progress(run.r.into_value())
    );
}

/// `agent-background.test.ts`: "wakes the agent with matched output and
/// supports write".
#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_background_tool_tty() {
    let Some(mut agent) = AgentRun::start(AgentOptions::default().features(FEATURES)).await else {
        return;
    };
    let mut run = Run::new(&agent);
    agent.push([
        ptc(
            "b1",
            &script(&[&format!(
                "{{ action: \"start\", tty: true, notify_on: \"READY\", command: {} }}",
                json!(after(
                    "go",
                    "echo READY; read line; echo \"got $line\"; sleep 30"
                ))
            )]),
        ),
        text("Waiting for the server."),
    ]);
    turn(&mut agent, &mut run, "start", "start server").await;
    agent.push([
        ptc(
            "w1",
            &script(&[
                r#"{ action: "list" }"#,
                r#"{ action: "write", id: (await tools.call("background_task", { action: "list" })).data.tasks[0].id, input: "ping\n" }"#,
                r#"{ action: "write", id: "nope", input: "x" }"#,
            ]),
        ),
        text("Sent input."),
    ]);
    release(&agent, "go");
    settle(&mut agent, &mut run, "matched").await;
    let (lines, code) = agent.close().await;
    run.note("shutdown", json!(lines));
    run.note("exit code", json!(code));
    insta::assert_json_snapshot!(
        "agent_background_tool_tty",
        feature_support::without_ptc_progress(run.r.into_value())
    );
}

/// `agent-background.test.ts`: "reports output lines that match the
/// monitor pattern", through the tool: matches collected while the agent
/// works reach it in one wake-up with the finished tasks; a monitor stops
/// after `MATCH_LIMIT` matches.
#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_background_tool_monitor() {
    let Some(mut agent) = AgentRun::start(AgentOptions::default().features(FEATURES)).await else {
        return;
    };
    let mut run = Run::new(&agent);
    let start = |name: &str, command: &str, pattern: Option<&str>| {
        let pattern = pattern.map_or(String::new(), |p| format!(", notify_on: {}", json!(p)));
        format!(
            "{{ action: \"start\", command: {}{pattern} }}",
            json!(after(name, command))
        )
    };
    let gate = Gate::new();
    agent.push([
        ptc(
            "m1",
            &script(&[
                &start(
                    "a",
                    "echo ok; echo \"ERROR one\"; printf \"\\033[31mERROR two\\033[0m\\n\"; printf \"\\r\\n  \\n\"; printf \"ERROR tail\"",
                    Some("ERROR"),
                ),
                &start(
                    "b",
                    "for i in $(seq 1 250); do echo \"hit $i\"; done",
                    Some("hit"),
                ),
                &start("c", "echo late-match", None),
                &start("d", "echo \"x hit\"", Some("hit")),
                // `id` is a's; the others by their place in the list.
                r#"{ action: "monitor", id: (await tools.call("background_task", { action: "list" })).data.tasks[2].id, notify_on: "late" }"#,
                r#"{ action: "monitor", id: (await tools.call("background_task", { action: "list" })).data.tasks[3].id }"#,
                r#"{ action: "list" }"#,
            ]),
        ),
        ModelReply::gated(&gate, text("Working.")),
        text("Saw the matches."),
    ]);
    agent
        .command(json!({ "type": "prompt", "message": "watch" }))
        .await;
    // Side requests (write leases) are answered only while lines are read.
    then(&mut agent, &mut run, "the script", |line| {
        line["type"] == "tool_execution_end" && line["toolCallId"] == "m1"
    })
    .await;
    requests_arrived(&agent, 2).await;
    for (name, status) in [
        ("a", "completed"),
        ("b", "completed"),
        ("c", "completed"),
        ("d", "completed"),
    ] {
        release(&agent, name);
        // How many `panel_changed` lines matches give depends on how the
        // output was cut into reads (one per match read in the same tick,
        // all but the first empty), so they are left out.
        let lines: Vec<Value> = agent
            .until(|line| notified(line, status))
            .await
            .into_iter()
            .filter(|line| line["type"] != "panel_changed")
            .collect();
        run.note(&format!("{name} finished"), json!(lines));
    }
    gate.open();
    let events = agent.until(|line| line["type"] == "agent_settled").await;
    run.note("the busy run: events", json!(events));
    settle(&mut agent, &mut run, "the wake-up").await;
    insta::assert_json_snapshot!(
        "agent_background_tool_monitor",
        feature_support::without_ptc_progress(run.r.into_value())
    );
}
