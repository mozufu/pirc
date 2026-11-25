use super::*;

use crate::agent::AgentOptions;
use crate::session_store::SessionStore;
use crate::signal::AbortController;
use crate::tools::testing::{self, TestUi};

/// An agent running only this feature, in a fresh session; the lines it
/// emits are collected.
fn agent(dir: &std::path::Path, pot: bool) -> (Rc<Agent>, Rc<RefCell<Vec<Value>>>) {
    let workspace = dir.join("workspace");
    std::fs::create_dir_all(&workspace).unwrap();
    let mut config = testing::config(&workspace.display().to_string(), json!({}));
    if pot {
        let (_, text) = pirc_config::modes::DEFAULT_MODE_FILES
            .iter()
            .find(|(file, _)| *file == "pot.md")
            .unwrap();
        config.mode = pirc_config::modes::parse_mode("pot", text).unwrap();
    }
    let store = SessionStore::open(dir.join("session"), &config.workspace).unwrap();
    let lines = Rc::new(RefCell::new(Vec::new()));
    let sink = lines.clone();
    let agent = Agent::new(AgentOptions {
        config,
        capabilities: Default::default(),
        role: None,
        store,
        emit: Rc::new(move |line: Value| sink.borrow_mut().push(line)),
        ui: Rc::new(TestUi::default()),
        has_ui: true,
        tools: Vec::new(),
        features: vec![feature()],
        acquire_write: None,
        allowed_tools: None,
        stream_override: None,
    });
    (agent, lines)
}

async fn call(agent: &Rc<Agent>, args: Value) -> Result<ToolResult, String> {
    let tool = agent
        .get_tool("background_task")
        .expect("the background_task capability");
    let context = testing::context((*agent.config()).clone(), AbortController::new().signal());
    tool.execute(testing::args(args), context.ctx).await
}

fn info(command: &str) -> TaskInfo {
    TaskInfo {
        id: "abcd1234".to_owned(),
        command: command.to_owned(),
        cwd: "/w".to_owned(),
        status: TaskStatus::Running,
        pid: Some(7),
        exit_code: None,
        signal: None,
        log_path: "/tmp/x/abcd1234.log".to_owned(),
        tty: false,
        notify_on: None,
        matches: None,
        started_at: "2026-01-01T00:00:00.000Z".to_owned(),
        ended_at: None,
        error: None,
    }
}

#[test]
fn cleans_terminal_control_text() {
    assert_eq!(clean("\x1b[31mred\x1b[0m"), "red");
    assert_eq!(clean("\x1b]0;title\x07x"), "x");
    assert_eq!(clean("\x1b]8;;http://a\x1b\\link\x1b]8;;\x1b\\"), "link");
    assert_eq!(clean("\u{9b}31mz"), "z");
    assert_eq!(clean("\x1bcX"), "X");
    assert_eq!(clean("\x1b[?25lY"), "Y");
    assert_eq!(clean("a\x1b"), "a");
    assert_eq!(clean("a\tb\nc\r\x01\x7fd"), "a\tb\ncd");
}

#[test]
fn summarizes_tasks() {
    let mut task = info("echo  a\n\tb\x1b[1m");
    assert_eq!(summary(&task), "abcd1234 · running · echo a b");
    task.status = TaskStatus::Failed;
    task.exit_code = Some(Some(3));
    task.tty = true;
    task.notify_on = Some("x\\/y".to_owned());
    task.matches = Some(2);
    assert_eq!(
        summary(&task),
        "abcd1234 · failed (exit 3) · tty · notify_on /x\\/y/ (2 matches) · echo a b"
    );
    task.exit_code = Some(None);
    task.command = "é".repeat(200);
    assert!(summary(&task).ends_with(&format!(" · {}", "é".repeat(180))));
}

#[test]
fn shows_tasks_with_the_documented_fields() {
    let mut task = info("ls");
    task.exit_code = Some(None);
    task.signal = Some(Some("SIGTERM".to_owned()));
    let data = task_data(&task);
    let keys: Vec<&String> = data.as_object().unwrap().keys().collect();
    assert_eq!(
        keys,
        [
            "id",
            "command",
            "cwd",
            "status",
            "logPath",
            "startedAt",
            "pid",
            "exitCode",
            "signal"
        ]
    );
    let public = task_public(&task, Some(1));
    assert_eq!(public["command"], "l");
    assert!(public.get("logPath").is_none());
    assert_eq!(
        task_detail(&info(&"x".repeat(300)))["command"],
        "x".repeat(180)
    );
}

#[test]
fn unescapes_typed_input() {
    assert_eq!(
        unescape_input(r"a\tb\x41\u0042\\n\e\q\n"),
        "a\tbAB\\n\x1b\\q\n"
    );
    assert_eq!(unescape_input(r"\x4"), r"\x4");
    assert_eq!(unescape_input(r"\uD83D\uDE00"), "😀");
    assert_eq!(unescape_input(r"\uD83Dx"), "\u{FFFD}x");
    assert_eq!(unescape_input("\\"), "\\");
}

#[test]
fn resolves_paths_as_node_does() {
    assert_eq!(resolve("/w", "."), "/w");
    assert_eq!(resolve("/w", "sub/"), "/w/sub");
    assert_eq!(resolve("/w", "../x"), "/x");
    assert_eq!(resolve("/w", "/abs/./y/"), "/abs/y");
    assert_eq!(resolve("/w", ".."), "/");
}

#[test]
fn checks_line_counts() {
    assert_eq!(check_lines(1.0), Ok(1));
    assert_eq!(check_lines(2000.0), Ok(2000));
    for bad in [0.0, 2001.0, 1.5, f64::NAN] {
        assert_eq!(
            check_lines(bad).unwrap_err(),
            "lines must be an integer from 1 to 2000."
        );
    }
    assert_eq!(tail_lines("a\nb\nc", 2), "b\nc");
    assert_eq!(tail_lines("a", 5), "a");
}

#[test]
fn pots_leave_the_tool_out() {
    let dir = tempfile::tempdir().unwrap();
    let (agent, _) = agent(dir.path(), true);
    assert!(agent.get_tool("background_task").is_none());
}

#[tokio::test]
async fn the_tool_starts_waits_and_reports() {
    tokio::task::LocalSet::new()
        .run_until(async {
            let dir = tempfile::tempdir().unwrap();
            let (agent, lines) = agent(dir.path(), false);
            agent.init().await.unwrap();
            std::fs::create_dir(dir.path().join("workspace/sub")).unwrap();
            let started = call(
                &agent,
                json!({ "action": "start", "command": "sleep 0.2; echo hi; pwd", "cwd": "@sub" }),
            )
            .await
            .unwrap();
            let data = started.data.as_ref().unwrap();
            assert_eq!(data["action"], "start");
            let id = data["task"]["id"].as_str().unwrap().to_owned();
            assert_eq!(id.len(), 8);
            assert!(
                testing::text_of(&started)
                    .ends_with("\nStarted in background; this is not a completion result.")
            );
            assert!(
                data["task"]["cwd"]
                    .as_str()
                    .unwrap()
                    .ends_with("/workspace/sub")
            );
            let waited = call(&agent, json!({ "action": "wait", "id": id }))
                .await
                .unwrap();
            let text = testing::text_of(&waited);
            assert!(
                text.starts_with("Wait finished; check task status and exit code.\n"),
                "{text}"
            );
            assert!(text.contains("\nhi\n"), "{text}");
            let data = waited.data.as_ref().unwrap();
            assert_eq!(data["outcome"], "finished");
            assert_eq!(data["task"]["status"], "completed");
            assert_eq!(data["truncated"], false);
            let details = waited.details.as_ref().unwrap();
            assert_eq!(details["wait"]["outcome"], "finished");
            assert_eq!(details["tasks"][0]["id"], id.as_str());
            // Waited on: no wake-up is owed for it.
            assert!(agent.pending_count() == 0);
            let output = call(&agent, json!({ "action": "output", "id": id, "lines": 1 }))
                .await
                .unwrap();
            assert!(
                output.data.as_ref().unwrap()["output"]
                    .as_str()
                    .unwrap()
                    .ends_with("/workspace/sub")
            );
            assert_eq!(
                call(&agent, json!({ "action": "output" }))
                    .await
                    .unwrap_err(),
                "id is required."
            );
            assert_eq!(
                call(&agent, json!({ "action": "start", "command": " " }))
                    .await
                    .unwrap_err(),
                "command is required for start."
            );
            assert_eq!(
                call(&agent, json!({ "action": "write", "id": id }))
                    .await
                    .unwrap_err(),
                "input is required for write."
            );
            let monitor = call(
                &agent,
                json!({ "action": "monitor", "id": id, "notify_on": "x" }),
            )
            .await
            .unwrap_err();
            assert_eq!(monitor, format!("Task {id} has finished"));
            // A terminal task answers what it was sent.
            let tty = call(
                &agent,
                json!({ "action": "start", "tty": true, "notify_on": "never",
                    "command": "read line; echo \"got $line\"; sleep 30" }),
            )
            .await
            .unwrap();
            let tty_id = tty.data.as_ref().unwrap()["task"]["id"]
                .as_str()
                .unwrap()
                .to_owned();
            let wrote = call(
                &agent,
                json!({ "action": "write", "id": tty_id, "input": "ping\n" }),
            )
            .await
            .unwrap();
            assert!(testing::text_of(&wrote).starts_with("Sent 5 characters.\n"));
            assert!(testing::text_of(&wrote).contains("got ping"));
            assert_eq!(wrote.data.as_ref().unwrap()["sent"], 5);
            let cleared = call(&agent, json!({ "action": "monitor", "id": tty_id }))
                .await
                .unwrap();
            assert!(testing::text_of(&cleared).ends_with("\nMonitor cleared."));
            let stopped = call(&agent, json!({ "action": "stop", "id": tty_id }))
                .await
                .unwrap();
            assert!(testing::text_of(&stopped).starts_with(&format!("{tty_id} · stopped")));
            // Status line and panel followed along.
            let panel = agent.panel_state();
            assert_eq!(panel["backgroundTasks"].as_array().unwrap().len(), 2);
            assert!(
                lines
                    .borrow()
                    .iter()
                    .any(|line| line["type"] == "panel_changed"
                        && line["sections"] == json!(["background"]))
            );
            agent.shutdown().await;
            assert_eq!(
                call(&agent, json!({ "action": "list" })).await.unwrap_err(),
                "Background task runtime has shut down."
            );
        })
        .await;
}

#[tokio::test]
async fn the_command_runs_lists_and_stops_tasks() {
    tokio::task::LocalSet::new()
        .run_until(async {
            let dir = tempfile::tempdir().unwrap();
            let (agent, _) = agent(dir.path(), false);
            agent.init().await.unwrap();
            let feature = agent.features()[0].clone();
            let run = |args: &str| feature.run_command(&agent, "bg", args.to_owned());
            run("").await.unwrap();
            run("start sleep 30").await.unwrap();
            assert_eq!(
                run("output").await.unwrap_err(),
                "Usage: /bg output <id> [lines]"
            );
            assert_eq!(
                run("write x").await.unwrap_err(),
                "Usage: /bg write <id> <text>"
            );
            assert_eq!(
                run("stop nope").await.unwrap_err(),
                "Unknown background task: nope"
            );
            run("stop-all").await.unwrap();
            let messages = agent.all_messages();
            let texts: Vec<String> = messages
                .iter()
                .filter_map(|message| match message {
                    pirc_protocol::Message::Custom {
                        content,
                        custom_type,
                        ..
                    } if custom_type == "background-task-command" => Some(content.clone()),
                    _ => None,
                })
                .collect();
            assert_eq!(texts[0], "No background tasks.");
            assert!(texts[1].contains(" · running · sleep 30\nLog: "));
            assert_eq!(texts[2], "All background tasks stopped.");
        })
        .await;
}
