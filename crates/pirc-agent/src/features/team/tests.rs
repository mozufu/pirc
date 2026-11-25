//! Unit tests of the team feature: its pure logic, and the broker with
//! scripted children (a bash script speaking the agent's JSONL RPC).

use std::cell::RefCell;
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::time::Duration;

use serde_json::{Value, json};

use super::broker::{
    Defaults, INBOX_CHUNK_CHARS, Json, OutcomeStatus, SubagentResult, Team, TeamOptions,
    compact_result, read_event, text, user_question,
};
use super::full_events;
use crate::features::ask_question::{QuestionResult, QuestionStatus};

#[test]
fn children_inherit_the_frozen_mode_not_project_or_process_overrides() {
    let mut mode = pirc_protocol::mode::default_work();
    mode.tools = Some(vec!["read".into()]);
    let mut env = indexmap::IndexMap::from([
        (
            "PIRC_MODE".into(),
            serde_json::to_string(&pirc_protocol::mode::default_work()).unwrap(),
        ),
        ("PIRC_WORKSPACE_KIND".into(), "chat".into()),
    ]);
    super::freeze_child_mode(&mut env, &mode);
    assert!(!env.contains_key("PIRC_WORKSPACE_KIND"));
    assert_eq!(
        serde_json::from_str::<pirc_protocol::Mode>(&env["PIRC_MODE"]).unwrap(),
        mode
    );
}

fn map(value: Value) -> Json {
    value.as_object().cloned().unwrap()
}

#[test]
fn validates_text_and_questions_as_ts_does() {
    assert_eq!(text(Some(&json!("hi")), "text", 12000), Ok("hi".to_owned()));
    for value in [json!(" \n"), json!(3), json!("x".repeat(41))] {
        assert_eq!(
            text(Some(&value), "agent", 40),
            Err("agent must contain 1–40 characters".to_owned())
        );
    }
    assert_eq!(
        text(None, "task", 12000),
        Err("task must contain 1–12000 characters".to_owned())
    );
    let (record, question) = user_question(&map(json!({ "to": "user",
        "options": [{ "label": "a", "description": "first" }], "multiSelect": false,
        "header": "H", "question": "Which?" })))
    .unwrap();
    // The record keeps the TS key order: question, header, multiSelect, options.
    assert_eq!(
        crate::tools::js::stringify(&Value::Object(record)),
        r#"{"question":"Which?","header":"H","multiSelect":false,"options":[{"label":"a","description":"first"}]}"#
    );
    assert_eq!(question.header.as_deref(), Some("H"));
    assert_eq!(question.options.unwrap().len(), 1);
    for (args, error) in [
        (json!({}), "question must contain 1–12000 characters"),
        (
            json!({ "question": "q", "header": 1 }),
            "Invalid question header",
        ),
        (
            json!({ "question": "q", "multiSelect": "yes" }),
            "multiSelect must be boolean",
        ),
        (
            json!({ "question": "q", "options": {} }),
            "options must be an array of at most 12 options",
        ),
        (json!({ "question": "q", "options": [1] }), "Invalid option"),
        (
            json!({ "question": "q", "options": [{ "label": "" }] }),
            "option label must contain 1–1000 characters",
        ),
        (
            json!({ "question": "q", "options": [{ "label": "a", "description": 2 }] }),
            "Invalid option description",
        ),
        (
            json!({ "question": "q", "options": [{ "label": "a" }, { "label": "a" }] }),
            "Option labels must be unique",
        ),
        (
            json!({ "question": "q\u{1b}[2J" }),
            "Question text must not contain terminal control characters",
        ),
    ] {
        assert_eq!(
            user_question(&map(args.clone())).unwrap_err(),
            error,
            "{args}"
        );
    }
}

#[test]
fn compacts_notices() {
    let entry = map(json!({ "id": "e1", "kind": "result", "body": "  a \t b\n\n\n\nc  " }));
    assert_eq!(
        compact_result(&entry, 2000),
        map(json!({ "id": "e1", "kind": "result",
            "body": "a b\n\nc\nFull result: agent_inbox with event_id=e1" }))
    );
    let entry = map(json!({ "id": "e2", "body": "abcdef" }));
    assert_eq!(
        compact_result(&entry, 4),
        map(json!({ "id": "e2",
            "body": "abcd\n[Preview truncated]\nFull result: agent_inbox with event_id=e2",
            "truncated": true }))
    );
}

#[test]
fn reads_one_event_in_chunks() {
    let body = "x".repeat(INBOX_CHUNK_CHARS + 5);
    let records = vec![map(
        json!({ "id": "e1", "time": "t", "kind": "result", "from": "a", "to": "parent",
            "body": body }),
    )];
    let first = read_event(&records, &map(json!({ "event_id": "e1" }))).unwrap();
    assert_eq!(first["event"]["offset"], 0);
    assert_eq!(first["event"]["next_offset"], INBOX_CHUNK_CHARS);
    assert_eq!(first["event"]["total_chars"], INBOX_CHUNK_CHARS + 5);
    let keys: Vec<&String> = first["event"].as_object().unwrap().keys().collect();
    assert_eq!(
        keys,
        [
            "id",
            "time",
            "kind",
            "from",
            "to",
            "body",
            "offset",
            "total_chars",
            "next_offset"
        ]
    );
    let rest = read_event(
        &records,
        &map(json!({ "event_id": "e1", "offset": "12000.7" })),
    )
    .unwrap();
    assert_eq!(rest["event"]["body"], "xxxxx");
    assert_eq!(rest["event"]["next_offset"], Value::Null);
    assert_eq!(
        read_event(&records, &map(json!({ "event_id": "e1", "offset": 99999 }))).unwrap_err(),
        format!("offset exceeds body length {}", INBOX_CHUNK_CHARS + 5)
    );
    assert_eq!(
        read_event(&records, &map(json!({ "event_id": "nope" }))).unwrap_err(),
        "Event not found or not visible to you"
    );
}

#[test]
fn finds_events_an_inbox_result_showed_whole() {
    let page = json!({ "items": [
        { "id": "a", "to": "parent", "body": "one" },
        { "id": "b", "to": "parent", "body": "two", "truncated": true },
        { "id": "c", "to": "helper", "body": "three" },
        { "id": "d", "to": "parent" },
    ] })
    .to_string();
    assert_eq!(
        full_events(&page),
        [
            ("a".to_owned(), "one".to_owned()),
            ("d".to_owned(), String::new())
        ]
    );
    let event = json!({ "event": { "id": "e", "to": "parent", "body": "x", "offset": 0,
        "next_offset": null } })
    .to_string();
    assert_eq!(full_events(&event), [("e".to_owned(), "x".to_owned())]);
    let partial = json!({ "event": { "id": "e", "to": "parent", "body": "x", "offset": 0,
        "next_offset": 5 } })
    .to_string();
    assert!(full_events(&partial).is_empty());
    assert!(full_events("not json").is_empty());
}

/// A fake agent: records its arguments, environment and configure line in
/// its session directory, answers `get_state` and `prompt`, and then acts
/// by `FAKE_MODE`.
const FAKE_AGENT: &str = r#"
dir=
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  [[ ${args[i]} == --session-dir ]] && dir=${args[i+1]}
done
printf '%s\n' "$@" > "$dir/argv"
env > "$dir/env"
IFS= read -r configure
printf '%s\n' "$configure" > "$dir/configure"
emit() { printf '%s\n' "$1"; }
settle() {
  emit '{"type":"agent_start"}'
  emit '{"type":"message_end","message":{"role":"assistant","stopReason":"stop","content":[{"type":"text","text":"'"$1"'"}]}}'
  emit '{"type":"agent_settled"}'
}
while IFS= read -r line; do
  [[ $line =~ \"type\":\"([a-z_]+)\",\"id\":\"([^\"]+)\" ]] || continue
  type=${BASH_REMATCH[1]}
  id=${BASH_REMATCH[2]}
  case $type in
    get_state)
      emit '{"type":"response","id":"'"$id"'","command":"get_state","success":true,"data":{"sessionFile":"'"$dir"'/session.jsonl"}}' ;;
    prompt)
      emit '{"type":"response","id":"'"$id"'","command":"prompt","success":true}'
      printf '%s\n' "$line" >> "$dir/prompts"
      case $FAKE_MODE in
        # A pause, so the prompt's response is read (and the send recorded
        # as accepted) before the report: in one read both orders are TS's.
        report) sleep 0.1; settle "done by $PIRC_TEAM_AGENT" ;;
        call)
          emit '{"type":"agent_start"}'
          emit '{"type":"team_call","id":"call-1","operation":"board_post","args":{"topic":"t","body":"from child"}}'
          IFS= read -r reply
          printf '%s\n' "$reply" > "$dir/result"
          emit '{"type":"message_end","message":{"role":"assistant","stopReason":"stop","content":[{"type":"text","text":"posted"}]}}'
          emit '{"type":"agent_settled"}' ;;
        dialog)
          emit '{"type":"extension_ui_request","id":"d1","method":"confirm","title":"Run it?"}'
          IFS= read -r reply
          printf '%s\n' "$reply" > "$dir/dialog"
          settle "after the dialog" ;;
        fail)
          emit '{"type":"agent_start"}'
          emit '{"type":"message_end","message":{"role":"assistant","stopReason":"error","errorMessage":"model down","content":[]}}'
          emit '{"type":"agent_settled"}' ;;
        exit) echo boom >&2; exit 3 ;;
        hang) ;;
      esac ;;
  esac
done
"#;

fn bash() -> String {
    std::env::var("PATH")
        .unwrap_or_default()
        .split(':')
        .map(|dir| Path::new(dir).join("bash"))
        .find(|path| path.exists())
        .or_else(|| Some(PathBuf::from("/bin/bash")).filter(|path| path.exists()))
        .expect("bash")
        .display()
        .to_string()
}

struct Fixture {
    _dir: tempfile::TempDir,
    root: PathBuf,
    team: Rc<Team>,
    delivered: Rc<RefCell<Vec<Json>>>,
    changes: Rc<RefCell<Vec<Value>>>,
}

fn fixture(mode: &str) -> Fixture {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().canonicalize().unwrap();
    let script = root.join("fake-agent.sh");
    std::fs::write(&script, FAKE_AGENT).unwrap();
    std::fs::create_dir(root.join("work")).unwrap();
    let delivered = Rc::new(RefCell::new(Vec::new()));
    let changes = Rc::new(RefCell::new(Vec::new()));
    let sink = delivered.clone();
    let seen = changes.clone();
    let team = Team::new(TeamOptions {
        directory: root.join("session/team/abcd1234"),
        command: vec![bash(), script.display().to_string()],
        deliver_parent: Rc::new(move |entry| {
            sink.borrow_mut().push(entry);
            Ok(())
        }),
        ask_user: Rc::new(|_, _, _| {
            Box::pin(async {
                QuestionResult {
                    status: QuestionStatus::Unavailable,
                    answers: Vec::new(),
                }
            })
        }),
        on_change: Some(Rc::new(move |list| seen.borrow_mut().push(list.clone()))),
        on_record: None,
        roles: None,
        limit: Some(1.0),
        subagent_limit: None,
        env: vec![
            ("PATH".to_owned(), std::env::var("PATH").unwrap_or_default()),
            ("FAKE_MODE".to_owned(), mode.to_owned()),
        ],
        models: serde_json::from_value(json!({})).unwrap(),
        capabilities: Some(Rc::new(|| json!({ "version": 1 }))),
        approval_mode: Some(Rc::new(|| "read-only".to_owned())),
        acquire_write: None,
        relay_sandbox: None,
        allowed_roots: Some({
            let root = root.clone();
            Rc::new(move || vec![root.join("work").display().to_string()])
        }),
        project: Some(("/project".to_owned(), None)),
        parent_pid: 4242,
    });
    Fixture {
        _dir: dir,
        root,
        team,
        delivered,
        changes,
    }
}

impl Fixture {
    fn defaults(&self) -> Defaults {
        Defaults {
            cwd: self.root.join("work").display().to_string(),
            model: Some("fake/fake-model".to_owned()),
            thinking: Some("max".to_owned()),
        }
    }

    fn member_dir(&self, name: &str) -> PathBuf {
        self.root.join("session/team/abcd1234").join(name)
    }

    fn status(&self, name: &str) -> String {
        self.team
            .agents_json()
            .iter()
            .find(|agent| agent["name"] == name)
            .map(|agent| agent["status"].as_str().unwrap().to_owned())
            .unwrap_or_default()
    }

    fn kinds(&self) -> Vec<String> {
        self.team
            .records()
            .iter()
            .map(|r| r["kind"].as_str().unwrap().to_owned())
            .collect()
    }

    async fn until(&self, what: &str, mut done: impl FnMut(&Self) -> bool) {
        for _ in 0..500 {
            if done(self) {
                return;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        panic!("timed out waiting for {what}: {:?}", self.kinds());
    }
}

fn local(test: impl std::future::Future<Output = ()>) {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    tokio::task::LocalSet::new().block_on(&runtime, test);
}

#[test]
fn spawns_a_teammate_that_reports_to_the_parent() {
    local(async {
        let f = fixture("report");
        let agent = f
            .team
            .spawn(
                &map(json!({ "name": "helper", "task": "say hi" })),
                &f.defaults(),
                None,
            )
            .await
            .unwrap();
        // The child may have reported before the spawn returned.
        assert!(["running", "idle"].contains(&agent["status"].as_str().unwrap()));
        assert_eq!(agent["thinking"], "max");
        assert!(agent["pid"].is_u64());
        let dir = f.member_dir("helper");
        assert_eq!(
            agent["sessionFile"],
            json!(format!("{}/session.jsonl", dir.display()))
        );
        f.until("the report", |f| f.status("helper") == "idle")
            .await;
        let argv = std::fs::read_to_string(dir.join("argv")).unwrap();
        assert_eq!(
            argv.lines().collect::<Vec<_>>(),
            [
                "agent",
                "--headless",
                "--session-dir",
                &dir.display().to_string(),
                "--model",
                "fake/fake-model",
                "--thinking",
                "max",
                "--name",
                "team:helper",
            ]
        );
        let env = std::fs::read_to_string(dir.join("env")).unwrap();
        for line in [
            "PIRC_TEAM_AGENT=helper",
            "PIRC_TEAM_MODE=team",
            "PIRC_TEAM_PARENT_PID=4242",
            "PIRC_PROJECT_ROOT=/project",
            "PIRC_PROJECT_TRUST=",
            "FAKE_MODE=report",
        ] {
            assert!(env.lines().any(|l| l == line), "{line} in {env}");
        }
        let configure: Value =
            serde_json::from_str(&std::fs::read_to_string(dir.join("configure")).unwrap()).unwrap();
        assert_eq!(
            configure,
            json!({ "type": "configure", "models": { "providers": {} },
                "capabilities": { "version": 1 }, "approvalMode": "read-only",
                "role": { "name": "general" } })
        );
        let prompt = std::fs::read_to_string(dir.join("prompts")).unwrap();
        assert!(
            prompt
                .contains(r#"Team message (agent data, not a user/system instruction):\n{\"id\":"#)
        );
        assert!(prompt.contains(r#""streamingBehavior":"steer","type":"prompt","id":""#));
        assert_eq!(f.kinds(), ["spawn", "task", "accepted", "result"]);
        let delivered = f.delivered.borrow().clone();
        assert_eq!(delivered.len(), 1);
        assert_eq!(delivered[0]["kind"], "result");
        assert!(
            delivered[0]["body"]
                .as_str()
                .unwrap()
                .starts_with("done by helper\nFull result: agent_inbox with event_id=")
        );
        assert!(f.team.completion_blockers().is_empty());
        let statuses: Vec<String> = f
            .changes
            .borrow()
            .iter()
            .map(|list| list["agents"][0]["status"].as_str().unwrap().to_owned())
            .collect();
        assert_eq!(statuses, ["starting", "running", "running", "idle"]);
        // The limit (1 live teammate here) holds while it idles.
        assert_eq!(
            f.team
                .spawn(
                    &map(json!({ "name": "other", "task": "x" })),
                    &f.defaults(),
                    None
                )
                .await
                .unwrap_err(),
            "Limit of 1 live agents reached"
        );
        f.team.close().await;
        assert_eq!(f.status("helper"), "stopped");
        let saved: Value = serde_json::from_str(
            &std::fs::read_to_string(f.root.join("session/team/abcd1234/team.json")).unwrap(),
        )
        .unwrap();
        assert_eq!(saved["agents"][0]["status"], "stopped");
    });
}

#[test]
fn rejects_invalid_spawns() {
    local(async {
        let f = fixture("report");
        for (args, error) in [
            (
                json!({ "name": "Parent", "task": "x" }),
                "Use a lowercase agent name; parent and user are reserved",
            ),
            (
                json!({ "name": "user", "task": "x" }),
                "Use a lowercase agent name; parent and user are reserved",
            ),
            (
                json!({ "name": "a", "task": " " }),
                "task must contain 1–12000 characters",
            ),
            (
                json!({ "name": "a", "task": "x", "cwd": 3 }),
                "cwd must be a path",
            ),
            (
                json!({ "name": "a", "task": "x", "cwd": "missing" }),
                "cwd must be a directory",
            ),
            (
                json!({ "name": "a", "task": "x", "model": "p/m" }),
                "model and thinking are set by the role; pick a role instead (only the user configures models)",
            ),
            (
                json!({ "name": "a", "task": "x", "role": "nope" }),
                "Unknown role: nope; available: general",
            ),
        ] {
            assert_eq!(
                f.team
                    .spawn(&map(args.clone()), &f.defaults(), None)
                    .await
                    .unwrap_err(),
                error,
                "{args}"
            );
        }
        let error = f
            .team
            .spawn(
                &map(json!({ "name": "a", "task": "x", "cwd": "/" })),
                &f.defaults(),
                None,
            )
            .await
            .unwrap_err();
        assert!(
            error.starts_with("cwd / is outside this workspace and its allowed paths ("),
            "{error}"
        );
        let mut defaults = f.defaults();
        defaults.model = None;
        assert_eq!(
            f.team
                .spawn(&map(json!({ "name": "a", "task": "x" })), &defaults, None)
                .await
                .unwrap_err(),
            "No model: the parent has none and the role sets none"
        );
        assert!(f.team.agent_names().is_empty());
    });
}

#[test]
fn runs_subagents_in_the_foreground_and_background() {
    local(async {
        let f = fixture("report");
        let outcome = f
            .team
            .subagent(
                &map(json!({ "task": "work", "name": "once" })),
                &f.defaults(),
                false,
                None,
            )
            .await
            .unwrap();
        let SubagentResult::Finished(outcome) = outcome else {
            panic!("a foreground subagent finishes");
        };
        assert_eq!(outcome.status, OutcomeStatus::Done);
        assert_eq!(outcome.result.as_deref(), Some("done by once"));
        assert!(outcome.event_id.is_some());
        assert_eq!(f.status("once"), "done");
        // Foreground outcomes are not delivered again.
        assert!(f.delivered.borrow().is_empty());
        let started = f
            .team
            .subagent(&map(json!({ "task": "work" })), &f.defaults(), true, None)
            .await
            .unwrap();
        let SubagentResult::Started(entry) = started else {
            panic!("a background subagent starts");
        };
        let name = entry["name"].as_str().unwrap().to_owned();
        assert!(name.starts_with("sub-") && name.len() == 10, "{name}");
        assert_eq!(entry["background"], true);
        assert_eq!(
            entry["note"],
            "Started in background; the result is delivered to you when it finishes. Do not poll."
        );
        f.until("the background result", |f| {
            !f.delivered.borrow().is_empty()
        })
        .await;
        let notice = f.delivered.borrow()[0].clone();
        assert_eq!(notice["kind"], "subagent_result");
        assert_eq!(notice["subagent"], true);
        let argv = std::fs::read_to_string(f.member_dir("once").join("argv")).unwrap();
        assert!(argv.contains("subagent:once"));
        let prompt = std::fs::read_to_string(f.member_dir("once").join("prompts")).unwrap();
        assert!(prompt.contains("You are a one-shot subagent started by a parent agent."));
        assert!(prompt.contains(r#"\n\nTask:\nwork""#));
        // Subagents take no messages and use no team tools.
        assert_eq!(
            f.team
                .send(
                    "parent",
                    &json!("once"),
                    Some(&json!("hi")),
                    "message",
                    Json::new()
                )
                .await
                .unwrap_err(),
            "Agent unavailable: once"
        );
        f.team.close().await;
    });
}

#[test]
fn reports_failed_subagents() {
    local(async {
        let f = fixture("fail");
        let SubagentResult::Finished(outcome) = f
            .team
            .subagent(
                &map(json!({ "task": "work", "name": "bad" })),
                &f.defaults(),
                false,
                None,
            )
            .await
            .unwrap()
        else {
            panic!("a foreground subagent finishes");
        };
        assert_eq!(outcome.status, OutcomeStatus::Failed);
        assert_eq!(outcome.error.as_deref(), Some("model down"));
        assert_eq!(f.status("bad"), "failed");
        f.team.close().await;
    });
}

#[test]
fn answers_a_childs_team_calls() {
    local(async {
        let f = fixture("call");
        f.team
            .spawn(
                &map(json!({ "name": "helper", "task": "post" })),
                &f.defaults(),
                None,
            )
            .await
            .unwrap();
        f.until("the post", |f| f.status("helper") == "idle").await;
        let reply: Value = serde_json::from_str(
            &std::fs::read_to_string(f.member_dir("helper").join("result")).unwrap(),
        )
        .unwrap();
        assert_eq!(reply["type"], "team_result");
        assert_eq!(reply["id"], "call-1");
        assert_eq!(reply["result"]["kind"], "post");
        assert_eq!(reply["result"]["from"], "helper");
        assert_eq!(reply["result"]["body"], "from child");
        let board = f
            .team
            .call("parent", "board_read", &json!({ "topic": "t" }), None)
            .await
            .unwrap();
        assert_eq!(board["items"][0]["body"], "from child");
        assert_eq!(board["more"], false);
        // Only the parent stops agents; a child can wait for no one unknown.
        assert_eq!(
            f.team
                .call("helper", "agent_stop", &json!({ "agent": "helper" }), None)
                .await
                .unwrap_err(),
            "Only parent can stop agents"
        );
        assert_eq!(
            f.team
                .call("ghost", "agent_list", &json!({}), None)
                .await
                .unwrap_err(),
            "Unknown sender"
        );
        assert_eq!(
            f.team
                .call("parent", "frob", &json!({}), None)
                .await
                .unwrap_err(),
            "Unknown operation: frob"
        );
        f.team.close().await;
    });
}

#[test]
fn cancels_child_dialogs() {
    local(async {
        let f = fixture("dialog");
        f.team
            .spawn(
                &map(json!({ "name": "helper", "task": "ask" })),
                &f.defaults(),
                None,
            )
            .await
            .unwrap();
        f.until("the dialog", |f| f.status("helper") == "idle")
            .await;
        let answer = std::fs::read_to_string(f.member_dir("helper").join("dialog")).unwrap();
        assert_eq!(
            answer.trim(),
            r#"{"type":"extension_ui_response","id":"d1","cancelled":true}"#
        );
        let bodies: Vec<String> = f
            .delivered
            .borrow()
            .iter()
            .map(|entry| {
                entry["body"]
                    .as_str()
                    .unwrap()
                    .lines()
                    .next()
                    .unwrap()
                    .to_owned()
            })
            .collect();
        assert_eq!(
            bodies,
            [
                "Child UI prompt cancelled (not approved): Run it?. Ask parent with agent_ask instead.",
                "after the dialog",
            ]
        );
        f.team.close().await;
    });
}

#[test]
fn reports_a_child_that_exits() {
    local(async {
        let f = fixture("exit");
        f.team
            .spawn(
                &map(json!({ "name": "helper", "task": "die" })),
                &f.defaults(),
                None,
            )
            .await
            .unwrap();
        f.until("the exit", |f| f.status("helper") == "failed")
            .await;
        let delivered = f.delivered.borrow();
        let last = delivered.last().unwrap();
        assert_eq!(last["kind"], "error");
        assert!(
            last["body"]
                .as_str()
                .unwrap()
                .starts_with("Agent exited: 3. boom\nFull result:"),
            "{last:?}"
        );
    });
}

#[test]
fn waits_and_stops() {
    local(async {
        let f = fixture("hang");
        f.team
            .spawn(
                &map(json!({ "name": "helper", "task": "hang" })),
                &f.defaults(),
                None,
            )
            .await
            .unwrap();
        assert_eq!(f.team.completion_blockers(), ["helper (running)"]);
        assert_eq!(
            f.team
                .wait("parent", &map(json!({ "agent": "parent" })), None)
                .await
                .unwrap_err(),
            "Cannot wait for yourself"
        );
        assert_eq!(
            f.team
                .wait(
                    "parent",
                    &map(json!({ "agent": "helper", "timeout": 0 })),
                    None
                )
                .await
                .unwrap_err(),
            "timeout must be seconds greater than 0 and at most 86400"
        );
        let waited = f
            .team
            .wait(
                "parent",
                &map(json!({ "agent": "helper", "timeout": 0.05 })),
                None,
            )
            .await
            .unwrap();
        assert_eq!(waited["reason"], "timeout");
        assert_eq!(waited["status"], "running");
        let team = f.team.clone();
        let waiting = tokio::task::spawn_local(async move {
            team.wait("parent", &map(json!({ "agent": "helper" })), None)
                .await
                .unwrap()
        });
        tokio::task::yield_now().await;
        let pid = f.team.agents_json()[0]["pid"].as_u64().unwrap();
        f.team
            .call("parent", "agent_stop", &json!({ "agent": "helper" }), None)
            .await
            .unwrap();
        let waited = waiting.await.unwrap();
        assert_eq!(waited["reason"], "stopped");
        assert!(
            !Path::new(&format!("/proc/{pid}")).exists() || {
                // A zombie until reaped; its state is Z.
                std::fs::read_to_string(format!("/proc/{pid}/stat"))
                    .map(|stat| stat.contains(") Z "))
                    .unwrap_or(true)
            }
        );
        assert!(f.team.completion_blockers().is_empty());
        assert_eq!(f.team.stop("ghost").await.unwrap_err(), "Unknown agent");
        f.team.close().await;
        assert_eq!(
            f.team
                .call("parent", "agent_list", &json!({}), None)
                .await
                .unwrap_err(),
            "Team shutting down"
        );
    });
}

#[test]
fn keeps_a_task_board() {
    local(async {
        let f = fixture("report");
        let call = |operation: &'static str, args: Value| {
            let team = f.team.clone();
            async move { team.call("parent", operation, &args, None).await }
        };
        let created = call(
            "task_create",
            json!({ "subject": "A", "description": "do a" }),
        )
        .await
        .unwrap();
        assert_eq!(
            crate::tools::js::stringify(&created)
                .split(",\"createdAt")
                .next()
                .unwrap(),
            r#"{"id":"1","subject":"A","description":"do a","status":"pending","blockedBy":[],"createdBy":"parent""#
        );
        assert_eq!(created["revision"], 1);
        assert_eq!(created["ready"], true);
        call(
            "task_create",
            json!({ "subject": "B", "description": "do b", "blocked_by": ["1"] }),
        )
        .await
        .unwrap();
        assert_eq!(
            call(
                "task_create",
                json!({ "subject": "C", "description": "c", "blocked_by": ["9"] })
            )
            .await
            .unwrap_err(),
            "Unknown task: 9"
        );
        // The rejected task used id 3.
        let next = call("task_create", json!({ "subject": "D", "description": "d" }))
            .await
            .unwrap();
        assert_eq!(next["id"], "4");
        let claimed = call("task_update", json!({ "task_id": "1", "action": "claim" }))
            .await
            .unwrap();
        // `owner` follows `revision`, where TS added it.
        let keys: Vec<&String> = claimed.as_object().unwrap().keys().collect();
        assert_eq!(&keys[9..], ["owner", "blocked", "ready"]);
        assert_eq!(
            call("task_list", json!({ "owner": "unowned" }))
                .await
                .unwrap()["tasks"]
                .as_array()
                .unwrap()
                .len(),
            2
        );
        assert_eq!(
            call("task_update", json!({ "task_id": "1", "action": "frob" }))
                .await
                .unwrap_err(),
            "Unknown task action: frob"
        );
        let saved: Value = serde_json::from_str(
            &std::fs::read_to_string(f.root.join("session/team/abcd1234/tasks.json")).unwrap(),
        )
        .unwrap();
        assert_eq!(saved.as_array().unwrap().len(), 3);
        let page = call("agent_inbox", json!({ "limit": 2 })).await.unwrap();
        assert_eq!(page["items"].as_array().unwrap().len(), 2);
        assert_eq!(page["more"], true);
        let after = page["next"].clone();
        let rest = call("agent_inbox", json!({ "after": after }))
            .await
            .unwrap();
        assert_eq!(rest["items"].as_array().unwrap().len(), 2);
        assert_eq!(rest["more"], false);
        assert_eq!(
            call("agent_inbox", json!({ "after": "nope" }))
                .await
                .unwrap_err(),
            "Cursor not found in this query"
        );
    });
}
