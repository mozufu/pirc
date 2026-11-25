//! Background tasks (`agent/features/background/`, feature
//! `background-task`) as far as they go without `ptc` scripts, with the
//! test playing the agent's node: the `/bg` slash commands and their
//! errors, completion wake-ups (one per idle period, coalesced while the
//! agent runs), the status line, the side panel with `background_output`
//! and `background_stop`, pseudo-terminal tasks, stopping on shutdown,
//! headless agents and chats. The `background_task` tool itself is in
//! `agent_background_ptc.rs`. Tasks wait for a trigger file the test
//! creates, so they finish at known points. The historical feature
//! baseline (docs/development/historical-records.md).

mod background_support;

use std::time::Duration;

use background_support::{
    TaskMask, after, custom_end, gone, log_contains, log_path, notified, release,
};
use pirc_conformance::{AgentOptions, AgentRun, Gate, ModelReply, Recorder};
use serde_json::{Value, json};

const FEATURES: &str = "background-task";
const COMMAND: &str = "background-task-command";

fn text(value: &str) -> ModelReply {
    ModelReply::Text(value.to_owned())
}

struct Run {
    r: Recorder,
    m: TaskMask,
}

impl Run {
    fn new(agent: &AgentRun) -> Self {
        Self {
            r: Recorder::new(agent),
            m: TaskMask::default(),
        }
    }

    fn note(&mut self, step: &str, value: Value) {
        let value = self.m.mask(value);
        self.r.note(&self.m.step(step), value);
    }

    fn requests(&mut self, step: &str, agent: &AgentRun) {
        let requests = match self.m.mask(json!(agent.take_requests())) {
            Value::Array(items) => items,
            _ => Vec::new(),
        };
        self.r.requests(step, requests);
    }

    /// Events and the model requests made meanwhile.
    fn turn(&mut self, step: &str, agent: &AgentRun, events: Vec<Value>) {
        self.note(&format!("{step}: events"), json!(events));
        self.requests(&format!("{step}: model requests"), agent);
    }
}

/// A slash command typed while idle: its lines up to its response and the
/// message it records (or the error it shows). Returns the recorded text.
async fn slash(agent: &mut AgentRun, run: &mut Run, message: &str) -> String {
    let id = agent
        .command(json!({ "type": "prompt", "message": message }))
        .await;
    let mut lines = Vec::new();
    let (mut answered, mut ended) = (false, false);
    let mut content = String::new();
    while !(answered && ended) {
        let line = agent.next().await.expect("the agent exited");
        answered |= line["type"] == "response" && line["id"] == id.as_str();
        if custom_end(&line, COMMAND) {
            ended = true;
            content = line["message"]["content"]
                .as_str()
                .unwrap_or_default()
                .to_owned();
        }
        if line["type"] == "extension_ui_request"
            && line["method"] == "notify"
            && line["notifyType"] == "error"
        {
            ended = true;
        }
        lines.push(line);
    }
    run.note(message, json!(lines));
    content
}

/// The task id a `/bg start` reported (its summary's first word).
fn task_id(content: &str) -> String {
    content.split(' ').next().unwrap_or_default().to_owned()
}

/// Lines up to (and with) the first that satisfies `done`, recorded.
async fn then(agent: &mut AgentRun, run: &mut Run, step: &str, done: impl FnMut(&Value) -> bool) {
    let lines = agent.until(done).await;
    run.note(step, json!(lines));
}

/// Everything until the next `agent_settled` (a run the agent started by
/// itself), and the model requests made meanwhile.
async fn settle(agent: &mut AgentRun, run: &mut Run, step: &str) {
    let events = agent.until(|line| line["type"] == "agent_settled").await;
    run.turn(step, agent, events);
}

/// A prompt and everything until the run settles.
async fn turn(agent: &mut AgentRun, run: &mut Run, step: &str, message: &str) {
    agent
        .command(json!({ "type": "prompt", "message": message }))
        .await;
    settle(agent, run, step).await;
}

/// An RPC command's response, recorded.
async fn call(agent: &mut AgentRun, run: &mut Run, step: &str, command: Value) -> Value {
    let response = agent.call(command).await;
    run.note(step, response.clone());
    response
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_background_commands() {
    let Some(mut agent) = AgentRun::start(AgentOptions::default().features(FEATURES)).await else {
        return;
    };
    let mut run = Run::new(&agent);
    call(
        &mut agent,
        &mut run,
        "commands",
        json!({ "type": "get_commands" }),
    )
    .await;
    for message in [
        "/bg",
        "/bg help",
        "/bg frob x",
        "/bg start",
        "/bg output",
        "/bg output nope",
        "/bg output a b c",
        "/bg stop nope",
        "/bg stop",
        "/bg write x",
        "/bg write nope hi",
        "/bg tty",
    ] {
        slash(&mut agent, &mut run, message).await;
    }
    let started = slash(
        &mut agent,
        &mut run,
        &format!(
            "/bg start {}",
            after(
                "go",
                "printf 'one\\ntwo\\n'; printf '\\033[31mred\\033[0m\\n'; echo last; sleep 0.1; echo three >&2"
            )
        ),
    )
    .await;
    let id = task_id(&started);
    slash(&mut agent, &mut run, "/bg list").await;
    slash(&mut agent, &mut run, &format!("/bg output {id}")).await;
    for lines in ["1", "x", "0", "2001", "1.5"] {
        slash(&mut agent, &mut run, &format!("/bg output {id} {lines}")).await;
    }
    slash(&mut agent, &mut run, &format!("/bg write {id} hi")).await;
    // Finishing while idle wakes the agent once.
    agent.push([text("Built.")]);
    release(&agent, "go");
    settle(&mut agent, &mut run, "finished").await;
    slash(&mut agent, &mut run, &format!("/bg output {id}")).await;
    slash(&mut agent, &mut run, &format!("/bg output {id} 2")).await;
    slash(&mut agent, &mut run, &format!("/bg stop {id}")).await;
    slash(&mut agent, &mut run, &format!("/bg write {id} hi")).await;
    slash(&mut agent, &mut run, "/bg list").await;
    // A failing command.
    agent.push([text("It failed.")]);
    let failed = slash(&mut agent, &mut run, "/bg start exit 3").await;
    settle(&mut agent, &mut run, "failed").await;
    slash(
        &mut agent,
        &mut run,
        &format!("/bg output {}", task_id(&failed)),
    )
    .await;
    let session = agent.session_entries();
    run.note("session file", json!(session));
    insta::assert_json_snapshot!("agent_background_commands", run.r.into_value());
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_background_wakes() {
    let Some(mut agent) = AgentRun::start(AgentOptions::default().features(FEATURES)).await else {
        return;
    };
    let mut run = Run::new(&agent);
    slash(
        &mut agent,
        &mut run,
        &format!("/bg start {}", after("a", "echo built")),
    )
    .await;
    agent.push([text("Started the build; I will check when it finishes.")]);
    turn(&mut agent, &mut run, "a run", "build in background").await;
    agent.push([text("The build finished.")]);
    release(&agent, "a");
    settle(&mut agent, &mut run, "the build finished").await;
    // Tasks that finish while the agent works wait for it to settle, then
    // wake it once together.
    slash(
        &mut agent,
        &mut run,
        &format!("/bg start {}", after("b", "echo b")),
    )
    .await;
    slash(
        &mut agent,
        &mut run,
        &format!("/bg start {}", after("c", "exit 3")),
    )
    .await;
    let gate = Gate::new();
    agent.push([ModelReply::gated(&gate, text("Working."))]);
    agent
        .command(json!({ "type": "prompt", "message": "work" }))
        .await;
    agent.wait_for_request().await;
    release(&agent, "b");
    then(&mut agent, &mut run, "b finished", |line| {
        notified(line, "completed")
    })
    .await;
    release(&agent, "c");
    then(&mut agent, &mut run, "c finished", |line| {
        notified(line, "failed")
    })
    .await;
    agent.push([text("Both done.")]);
    gate.open();
    let events = agent.until(|line| line["type"] == "agent_settled").await;
    run.note("the busy run: events", json!(events));
    let events = agent.until(|line| line["type"] == "agent_settled").await;
    run.note("the wake-up: events", json!(events));
    run.requests("both runs: model requests", &agent);
    // No further wake-up.
    tokio::time::sleep(Duration::from_millis(300)).await;
    run.note("later requests", json!(agent.pending_requests()));
    insta::assert_json_snapshot!("agent_background_wakes", run.r.into_value());
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_background_stops_while_running() {
    let Some(mut agent) = AgentRun::start(AgentOptions::default().features(FEATURES)).await else {
        return;
    };
    let mut run = Run::new(&agent);
    let first = slash(&mut agent, &mut run, "/bg start sleep 60").await;
    slash(&mut agent, &mut run, "/bg start sleep 61; echo never").await;
    let gate = Gate::new();
    agent.push([
        ModelReply::gated(&gate, text("Working.")),
        text("Saw the stops."),
        text("Both were stopped."),
    ]);
    agent
        .command(json!({ "type": "prompt", "message": "work" }))
        .await;
    agent.wait_for_request().await;
    // Commands typed while the agent works are recorded for it as steering.
    agent
        .command(json!({ "type": "steer", "message": format!("/bg stop {}", task_id(&first)) }))
        .await;
    then(&mut agent, &mut run, "stop one", |line| {
        notified(line, "stopped")
    })
    .await;
    agent
        .command(json!({ "type": "steer", "message": "/bg stop-all" }))
        .await;
    then(&mut agent, &mut run, "stop all", |line| {
        notified(line, "stopped")
    })
    .await;
    // The command records its message right after the stop.
    tokio::time::sleep(Duration::from_millis(100)).await;
    gate.open();
    let events = agent.until(|line| line["type"] == "agent_settled").await;
    run.note("the busy run: events", json!(events));
    let events = agent.until(|line| line["type"] == "agent_settled").await;
    run.note("the wake-up: events", json!(events));
    run.requests("both runs: model requests", &agent);
    slash(&mut agent, &mut run, "/bg stop-all").await;
    slash(&mut agent, &mut run, "/bg").await;
    insta::assert_json_snapshot!("agent_background_stops_while_running", run.r.into_value());
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_background_panel() {
    let Some(mut agent) = AgentRun::start(AgentOptions::default().features(FEATURES)).await else {
        return;
    };
    let mut run = Run::new(&agent);
    call(
        &mut agent,
        &mut run,
        "empty panel",
        json!({ "type": "get_panel_state" }),
    )
    .await;
    let started = slash(
        &mut agent,
        &mut run,
        "/bg start echo panel-output; printf 'a\\033[1mb\\033[0m\\x01c\\n'; sleep 60",
    )
    .await;
    let id = task_id(&started);
    call(
        &mut agent,
        &mut run,
        "panel",
        json!({ "type": "get_panel_state" }),
    )
    .await;
    log_contains(&log_path(&started), "\u{1}c").await;
    call(
        &mut agent,
        &mut run,
        "output",
        json!({ "type": "background_output", "taskId": id }),
    )
    .await;
    for lines in [
        json!(1),
        json!("1"),
        json!(0),
        json!(2001),
        json!(1.5),
        json!("x"),
        json!(null),
    ] {
        call(
            &mut agent,
            &mut run,
            &format!("output, lines {lines}"),
            json!({ "type": "background_output", "taskId": id, "lines": lines }),
        )
        .await;
    }
    call(
        &mut agent,
        &mut run,
        "output of an unknown task",
        json!({ "type": "background_output", "taskId": "nope" }),
    )
    .await;
    call(
        &mut agent,
        &mut run,
        "output without a task",
        json!({ "type": "background_output" }),
    )
    .await;
    call(
        &mut agent,
        &mut run,
        "stop an unknown task",
        json!({ "type": "background_stop", "taskId": "nope" }),
    )
    .await;
    // A stop from the panel answers at once; the model hears of it.
    agent.push([text("Noted, the watcher was stopped.")]);
    call(
        &mut agent,
        &mut run,
        "stop",
        json!({ "type": "background_stop", "taskId": id }),
    )
    .await;
    settle(&mut agent, &mut run, "stopped").await;
    call(
        &mut agent,
        &mut run,
        "stop again",
        json!({ "type": "background_stop", "taskId": id }),
    )
    .await;
    call(
        &mut agent,
        &mut run,
        "panel after",
        json!({ "type": "get_panel_state" }),
    )
    .await;
    call(
        &mut agent,
        &mut run,
        "output after",
        json!({ "type": "background_output", "taskId": id }),
    )
    .await;
    insta::assert_json_snapshot!("agent_background_panel", run.r.into_value());
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_background_tty() {
    let Some(mut agent) = AgentRun::start(AgentOptions::default().features(FEATURES)).await else {
        return;
    };
    let mut run = Run::new(&agent);
    let started = slash(
        &mut agent,
        &mut run,
        "/bg tty read -p \"name? \" n; echo \"hi $n\"; [ -t 0 ] && echo tty-ok; echo \"TERM=$TERM\"",
    )
    .await;
    let id = task_id(&started);
    log_contains(&log_path(&started), "name?").await;
    agent.push([text("Said hi.")]);
    slash(&mut agent, &mut run, &format!("/bg write {id} bob")).await;
    settle(&mut agent, &mut run, "finished").await;
    slash(&mut agent, &mut run, &format!("/bg output {id}")).await;
    slash(&mut agent, &mut run, &format!("/bg write {id} again")).await;
    slash(&mut agent, &mut run, &format!("/bg write {id}")).await;
    // Escapes in the typed text.
    let started = slash(
        &mut agent,
        &mut run,
        "/bg tty stty -echo; echo ready; read -r a; printf '[%s]\\n' \"$a\" | od -c | head -2",
    )
    .await;
    let id = task_id(&started);
    log_contains(&log_path(&started), "ready").await;
    agent.push([text("Read it.")]);
    slash(
        &mut agent,
        &mut run,
        &format!("/bg write {id} a\\tb\\x41\\u0042\\\\n\\e\\q"),
    )
    .await;
    settle(&mut agent, &mut run, "escapes").await;
    slash(&mut agent, &mut run, &format!("/bg output {id}")).await;
    insta::assert_json_snapshot!("agent_background_tty", run.r.into_value());
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_background_shutdown() {
    let Some(mut agent) = AgentRun::start(AgentOptions::default().features(FEATURES)).await else {
        return;
    };
    let mut run = Run::new(&agent);
    slash(&mut agent, &mut run, "/bg start sleep 60 & sleep 61; wait").await;
    slash(&mut agent, &mut run, "/bg tty sleep 62").await;
    let panel = agent.call(json!({ "type": "get_panel_state" })).await;
    let pids: Vec<u64> = panel["data"]["backgroundTasks"]
        .as_array()
        .unwrap()
        .iter()
        .map(|task| task["pid"].as_u64().unwrap())
        .collect();
    let (lines, code) = agent.close().await;
    run.note("shutdown", json!(lines));
    run.note("exit code", json!(code));
    let mut stopped = Vec::new();
    for pid in pids {
        stopped.push(gone(pid, Duration::from_secs(2)).await);
    }
    run.note("tasks stopped", json!(stopped));
    insta::assert_json_snapshot!("agent_background_shutdown", run.r.into_value());
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_background_headless() {
    let Some(mut agent) = AgentRun::start(
        AgentOptions {
            args: vec!["--headless".to_owned()],
            ..AgentOptions::default()
        }
        .features(FEATURES),
    )
    .await
    else {
        return;
    };
    let mut run = Run::new(&agent);
    // No status line without a UI.
    slash(
        &mut agent,
        &mut run,
        &format!("/bg start {}", after("go", "true")),
    )
    .await;
    agent.push([text("Ok.")]);
    release(&agent, "go");
    settle(&mut agent, &mut run, "finished").await;
    slash(&mut agent, &mut run, "/bg start sleep 60").await;
    let (lines, code) = agent.close().await;
    run.note("shutdown", json!(lines));
    run.note("exit code", json!(code));
    insta::assert_json_snapshot!("agent_background_headless", run.r.into_value());
}
