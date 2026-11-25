//! `RpcUi`, `handleCommand` and `serveRpc` without the loop: the agent is a
//! stand-in recording what the commands asked of it (the RPC parts of
//! `agent-core.test.ts` / `agent-interaction.test.ts`; the conformance
//! transcripts cover them with the real agent).

use std::cell::{Cell, RefCell};
use std::rc::Rc;

use serde_json::{Value, json};
use tokio::sync::mpsc;

use super::*;
use crate::signal::AbortController;

fn recorder() -> (Write, Rc<RefCell<Vec<Value>>>) {
    let lines = Rc::new(RefCell::new(Vec::new()));
    let sink = lines.clone();
    (Rc::new(move |value| sink.borrow_mut().push(value)), lines)
}

async fn local<F: std::future::Future>(future: F) -> F::Output {
    tokio::task::LocalSet::new().run_until(future).await
}

/// Let spawned tasks and woken futures run.
async fn settle() {
    for _ in 0..5 {
        tokio::task::yield_now().await;
    }
}

fn line(lines: &Rc<RefCell<Vec<Value>>>, index: usize) -> Value {
    lines.borrow()[index].clone()
}

#[tokio::test]
async fn select_writes_the_request_and_reads_the_value() {
    local(async {
        let (write, lines) = recorder();
        let ui = RpcUi::new(write);
        let options = ["sqlite".to_owned(), "postgres".to_owned()];
        let answer = {
            let ui = ui.clone();
            tokio::task::spawn_local(async move {
                ui.select("DB: Which DB?", &options, DialogOptions::default())
                    .await
            })
        };
        settle().await;
        let request = line(&lines, 0);
        let id = request["id"].as_str().unwrap().to_owned();
        assert_eq!(
            serde_json::to_string(&request).unwrap(),
            format!(
                r#"{{"type":"extension_ui_request","id":"{id}","method":"select","title":"DB: Which DB?","options":["sqlite","postgres"]}}"#
            )
        );
        ui.respond(&json!({ "type": "extension_ui_response", "id": "other", "value": "x" }));
        ui.respond(&json!({ "type": "extension_ui_response", "id": id, "value": "postgres" }));
        assert_eq!(answer.await.unwrap().as_deref(), Some("postgres"));
    })
    .await;
}

#[tokio::test]
async fn choose_sends_descriptions_and_reads_values() {
    local(async {
        let (write, lines) = recorder();
        let ui = RpcUi::new(write);
        let choices = vec![
            Choice {
                label: "a".to_owned(),
                description: Some("first".to_owned()),
            },
            Choice {
                label: "b".to_owned(),
                description: None,
            },
        ];
        let first = {
            let (ui, choices) = (ui.clone(), choices.clone());
            tokio::task::spawn_local(async move {
                ui.choose("Pick", &choices, true, DialogOptions::default())
                    .await
            })
        };
        settle().await;
        let request = line(&lines, 0);
        assert_eq!(request["optionDescriptions"], json!(["first", ""]));
        assert_eq!(request["multiple"], json!(true));
        ui.respond(&json!({ "id": request["id"], "value": "a, b", "values": ["a", 1, "b"] }));
        assert_eq!(
            first.await.unwrap(),
            Some(vec!["a".to_owned(), "b".to_owned()])
        );
        let second = {
            let (ui, choices) = (ui.clone(), choices.clone());
            tokio::task::spawn_local(async move {
                ui.choose("Pick", &choices, false, DialogOptions::default())
                    .await
            })
        };
        settle().await;
        let request = line(&lines, 1);
        assert!(request.get("multiple").is_none());
        ui.respond(&json!({ "id": request["id"], "value": "b" }));
        assert_eq!(second.await.unwrap(), Some(vec!["b".to_owned()]));
    })
    .await;
}

#[tokio::test]
async fn confirm_input_and_editor_read_their_answers() {
    local(async {
        let (write, lines) = recorder();
        let ui = RpcUi::new(write);
        let confirm = {
            let ui = ui.clone();
            tokio::task::spawn_local(async move {
                ui.confirm("Sure?", "Really", DialogOptions::default())
                    .await
            })
        };
        settle().await;
        ui.respond(&json!({ "id": line(&lines, 0)["id"], "confirmed": 1 }));
        assert_eq!(confirm.await.unwrap(), Some(true));
        let input = {
            let ui = ui.clone();
            tokio::task::spawn_local(async move {
                ui.input("Name", None, DialogOptions::default()).await
            })
        };
        settle().await;
        let request = line(&lines, 1);
        assert!(request.get("placeholder").is_none());
        ui.respond(&json!({ "id": request["id"], "value": 5 }));
        assert_eq!(input.await.unwrap(), None);
        let editor = {
            let ui = ui.clone();
            tokio::task::spawn_local(async move {
                ui.editor("Edit", Some("text"), DialogOptions::default())
                    .await
            })
        };
        settle().await;
        let request = line(&lines, 2);
        assert_eq!(request["prefill"], json!("text"));
        ui.respond(&json!({ "id": request["id"], "cancelled": true, "value": "x" }));
        assert_eq!(editor.await.unwrap(), None);
    })
    .await;
}

#[tokio::test]
async fn dialogs_open_one_at_a_time_in_call_order() {
    local(async {
        let (write, lines) = recorder();
        let ui = RpcUi::new(write);
        let first = {
            let ui = ui.clone();
            tokio::task::spawn_local(async move {
                ui.input("first", None, DialogOptions::default()).await
            })
        };
        let second = {
            let ui = ui.clone();
            tokio::task::spawn_local(async move {
                ui.input("second", None, DialogOptions::default()).await
            })
        };
        settle().await;
        assert_eq!(lines.borrow().len(), 1);
        assert_eq!(line(&lines, 0)["title"], "first");
        ui.respond(&json!({ "id": line(&lines, 0)["id"], "value": "1" }));
        settle().await;
        assert_eq!(lines.borrow().len(), 2);
        assert_eq!(line(&lines, 1)["title"], "second");
        ui.respond(&json!({ "id": line(&lines, 1)["id"], "value": "2" }));
        assert_eq!(first.await.unwrap().as_deref(), Some("1"));
        assert_eq!(second.await.unwrap().as_deref(), Some("2"));
    })
    .await;
}

#[tokio::test]
async fn abort_cancels_the_open_dialog_and_tells_the_client() {
    local(async {
        let (write, lines) = recorder();
        let ui = RpcUi::new(write);
        let pre = AbortController::new();
        pre.abort();
        let options = DialogOptions {
            signal: Some(pre.signal()),
            ..DialogOptions::default()
        };
        assert_eq!(ui.input("never", None, options).await, None);
        assert!(lines.borrow().is_empty());

        let controller = AbortController::new();
        let options = DialogOptions {
            signal: Some(controller.signal()),
            tool_call_id: Some("q3".to_owned()),
            ..DialogOptions::default()
        };
        let pending = {
            let ui = ui.clone();
            tokio::task::spawn_local(async move { ui.input("Wait?", None, options).await })
        };
        settle().await;
        let request = line(&lines, 0);
        assert_eq!(request["toolCallId"], "q3");
        controller.abort();
        let cancel = line(&lines, 1);
        assert_eq!(cancel["method"], "cancel");
        assert_eq!(cancel["targetId"], request["id"]);
        assert_ne!(cancel["id"], request["id"]);
        assert_eq!(pending.await.unwrap(), None);
        // A late answer is ignored.
        ui.respond(&json!({ "id": request["id"], "value": "late" }));
        assert_eq!(lines.borrow().len(), 2);
    })
    .await;
}

#[tokio::test]
async fn timeouts_and_cancel_all_end_dialogs() {
    local(async {
        let (write, lines) = recorder();
        let ui = RpcUi::new(write);
        let options = DialogOptions {
            timeout_ms: Some(20),
            ..DialogOptions::default()
        };
        assert_eq!(ui.confirm("Quick", "m", options).await, None);
        let request = line(&lines, 0);
        assert_eq!(request["timeout"], json!(20));
        assert_eq!(
            request.as_object().unwrap().keys().collect::<Vec<_>>(),
            ["type", "id", "method", "title", "message", "timeout"]
        );
        let pending = {
            let ui = ui.clone();
            tokio::task::spawn_local(async move {
                ui.select("x", &["a".to_owned()], DialogOptions::default())
                    .await
            })
        };
        settle().await;
        ui.cancel_all();
        assert_eq!(pending.await.unwrap(), None);
        assert_eq!(lines.borrow().len(), 2);
    })
    .await;
}

#[tokio::test]
async fn a_dropped_dialog_closes_its_card_and_frees_the_turn() {
    local(async {
        let (write, lines) = recorder();
        let ui = RpcUi::new(write);
        {
            let dialog = ui.input("dropped", None, DialogOptions::default());
            let queued = ui.input("never polled", None, DialogOptions::default());
            let raced = tokio::time::timeout(std::time::Duration::from_millis(5), dialog).await;
            assert!(raced.is_err());
            drop(queued);
        }
        assert_eq!(line(&lines, 1)["method"], "cancel");
        assert_eq!(line(&lines, 1)["targetId"], line(&lines, 0)["id"]);
        let next = {
            let ui = ui.clone();
            tokio::task::spawn_local(async move {
                ui.input("next", None, DialogOptions::default()).await
            })
        };
        settle().await;
        assert_eq!(line(&lines, 2)["title"], "next");
        ui.respond(&json!({ "id": line(&lines, 2)["id"], "value": "ok" }));
        assert_eq!(next.await.unwrap().as_deref(), Some("ok"));
    })
    .await;
}

#[test]
fn notifications_status_and_widgets() {
    let (write, lines) = recorder();
    let ui = RpcUi::new(write);
    ui.notify("careful", NotifyLevel::Warning);
    ui.set_status("todo", Some("1/2"));
    ui.set_status("todo", None);
    ui.set_widget("todo", Some(&["- a".to_owned()]));
    ui.set_widget("todo", None);
    let shapes: Vec<Vec<String>> = lines
        .borrow()
        .iter()
        .map(|line| line.as_object().unwrap().keys().cloned().collect())
        .collect();
    assert_eq!(
        shapes,
        [
            vec!["type", "id", "method", "message", "notifyType"],
            vec!["type", "id", "method", "statusKey", "statusText"],
            vec!["type", "id", "method", "statusKey"],
            vec![
                "type",
                "id",
                "method",
                "widgetKey",
                "widgetLines",
                "widgetPlacement"
            ],
            vec!["type", "id", "method", "widgetKey", "widgetPlacement"],
        ]
    );
    assert_eq!(line(&lines, 0)["notifyType"], "warning");
    assert_eq!(line(&lines, 3)["widgetPlacement"], "aboveEditor");
}

/// The agent as the commands see it.
#[derive(Default)]
struct Fake {
    running: Cell<bool>,
    calls: RefCell<Vec<String>>,
    context: RefCell<Option<Value>>,
    delivered: RefCell<Vec<Delivery>>,
    images: RefCell<Vec<UserBlock>>,
}

impl Fake {
    fn call(&self, call: impl Into<String>) {
        self.calls.borrow_mut().push(call.into());
    }
    fn take(&self) -> Vec<String> {
        std::mem::take(&mut *self.calls.borrow_mut())
    }
}

impl Commands for Fake {
    fn refresh_models(&self) -> LocalBoxFuture<'_, ()> {
        self.call("refresh");
        Box::pin(async {})
    }
    fn is_running(&self) -> bool {
        self.running.get()
    }
    fn prompt(self: &Rc<Self>, text: String, images: Vec<UserBlock>) -> Result<(), String> {
        self.call(format!("prompt {text}"));
        *self.images.borrow_mut() = images;
        Ok(())
    }
    fn steer(self: &Rc<Self>, text: String, _: Vec<UserBlock>) {
        self.call(format!("steer {text}"));
    }
    fn follow_up(self: &Rc<Self>, text: String, _: Vec<UserBlock>) {
        self.call(format!("follow_up {text}"));
    }
    fn abort(self: &Rc<Self>) {
        self.call("abort");
    }
    fn idle(&self) -> LocalBoxFuture<'_, ()> {
        self.call("idle");
        Box::pin(async {})
    }
    fn send_now(self: &Rc<Self>, queue: Queue, index: usize, text: &str) -> Result<(), String> {
        self.call(format!("send_now {queue:?} {index} {text}"));
        Err("That message is no longer queued".to_owned())
    }
    fn clear_queue(self: &Rc<Self>) -> Value {
        json!({ "steering": [], "followUp": [] })
    }
    fn state(&self) -> Value {
        json!({ "isRunning": self.running.get() })
    }
    fn all_messages(&self) -> Vec<Message> {
        Vec::new()
    }
    fn compact(
        self: &Rc<Self>,
        instructions: Option<String>,
    ) -> LocalBoxFuture<'_, Result<Value, String>> {
        self.call(format!("compact {instructions:?}"));
        Box::pin(async { Err("Nothing to compact".to_owned()) })
    }
    fn command_list(&self) -> Vec<Value> {
        vec![json!({ "name": "compact" })]
    }
    fn available_models(&self) -> Vec<Value> {
        Vec::new()
    }
    fn set_model(&self, provider: &str, id: &str) -> Result<(), String> {
        self.call(format!("set_model {provider} {id}"));
        Ok(())
    }
    fn set_thinking(&self, level: &str) -> Result<(), String> {
        Err(format!("Unknown thinking level: {level}"))
    }
    fn set_approval_mode(self: &Rc<Self>, mode: &str) -> Result<(), String> {
        self.call(format!("set_approval_mode {mode}"));
        Ok(())
    }
    fn set_role(&self, name: &str) -> Result<(), String> {
        self.call(format!("set_role {name}"));
        Ok(())
    }
    fn set_name(&self, name: &str, source: NameSource) -> Result<(), String> {
        self.call(format!("set_name {name:?} {source:?}"));
        Ok(())
    }
    fn last_context(&self) -> Option<Value> {
        self.context.borrow().clone()
    }
    fn panel_state(self: &Rc<Self>) -> Value {
        json!({})
    }
    fn deliver(
        self: &Rc<Self>,
        delivery: Delivery,
        trigger_turn: bool,
        follow_up: bool,
    ) -> Result<(), String> {
        self.call(format!("deliver {trigger_turn} {follow_up}"));
        self.delivered.borrow_mut().push(delivery);
        Ok(())
    }
}

async fn run(agent: &Rc<Fake>, command: Value) -> Value {
    response(&command, dispatch(agent, &command).await)
}

#[tokio::test]
async fn prompts_queue_while_running_or_fail() {
    let agent = Rc::new(Fake::default());
    let image = json!({ "type": "prompt", "message": "Look",
        "images": [{ "type": "image", "data": "AA==" }, { "type": "image", "data": 1 },
            { "type": "text", "data": "x" }, { "type": "image", "data": "BB", "mimeType": "image/jpeg" }] });
    assert_eq!(
        run(&agent, image).await,
        json!({ "type": "response", "command": "prompt", "success": true })
    );
    assert_eq!(agent.take(), ["refresh", "prompt Look"]);
    assert_eq!(
        *agent.images.borrow(),
        [
            UserBlock::Image {
                data: "AA==".to_owned(),
                mime_type: "image/png".to_owned()
            },
            UserBlock::Image {
                data: "BB".to_owned(),
                mime_type: "image/jpeg".to_owned()
            },
        ]
    );
    agent.running.set(true);
    let response = run(&agent, json!({ "id": "1", "type": "prompt", "message": 3 })).await;
    assert_eq!(
        serde_json::to_string(&response).unwrap(),
        r#"{"type":"response","id":"1","command":"prompt","success":false,"error":"Agent is already running; use steer or follow_up"}"#
    );
    run(
        &agent,
        json!({ "type": "prompt", "message": "a", "streamingBehavior": "followUp" }),
    )
    .await;
    run(
        &agent,
        json!({ "type": "prompt", "message": "b", "streamingBehavior": "steer" }),
    )
    .await;
    run(&agent, json!({ "type": "steer", "message": "c" })).await;
    run(&agent, json!({ "type": "follow_up" })).await;
    assert_eq!(
        agent.take(),
        [
            "refresh",
            "refresh",
            "follow_up a",
            "refresh",
            "steer b",
            "steer c",
            "follow_up "
        ]
    );
}

#[tokio::test]
async fn validates_send_now_and_deliver() {
    let agent = Rc::new(Fake::default());
    let error = |response: Value| response["error"].as_str().unwrap().to_owned();
    assert_eq!(
        error(run(&agent, json!({ "type": "send_now", "message": "x" })).await),
        "send_now needs queue: steering or followUp"
    );
    for index in [json!(-1), json!(1.5), json!("0"), Value::Null] {
        assert_eq!(
            error(
                run(
                    &agent,
                    json!({ "type": "send_now", "queue": "steering", "index": index })
                )
                .await
            ),
            "send_now needs a non-negative integer index"
        );
    }
    assert!(agent.take().is_empty());
    assert_eq!(
        error(
            run(
                &agent,
                json!({ "type": "send_now", "queue": "followUp", "index": 2.0,
                "message": "x" })
            )
            .await
        ),
        "That message is no longer queued"
    );
    assert_eq!(agent.take(), ["send_now FollowUp 2 x"]);
    for message in [json!({ "customType": "note" }), json!("text"), Value::Null] {
        assert_eq!(
            error(run(&agent, json!({ "type": "deliver", "message": message })).await),
            "deliver needs message.customType and message.content"
        );
    }
    let response = run(
        &agent,
        json!({ "type": "deliver", "message": { "customType": "pot-wake",
        "content": "Done.", "details": { "taskId": "t1" } } }),
    )
    .await;
    assert_eq!(response["success"], json!(true));
    run(
        &agent,
        json!({ "type": "deliver", "message": { "customType": "n", "content": "",
        "details": "not an object" } }),
    )
    .await;
    assert_eq!(agent.take(), ["deliver true true", "deliver true true"]);
    // `wake: false` adds context (an environment change) without starting a turn.
    run(
        &agent,
        json!({ "type": "deliver", "wake": false, "message": { "customType": "environment-change",
        "content": "Moved." } }),
    )
    .await;
    assert_eq!(agent.take(), ["deliver false true"]);
    agent.delivered.borrow_mut().pop();
    assert_eq!(
        *agent.delivered.borrow(),
        [
            Delivery {
                custom_type: "pot-wake".to_owned(),
                // Labelled: never the user's words (L11).
                content: format!("{GATEWAY_MESSAGE_LABEL}\nDone."),
                display: true,
                details: Some(json!({ "taskId": "t1" })),
            },
            Delivery {
                custom_type: "n".to_owned(),
                content: format!("{GATEWAY_MESSAGE_LABEL}\n"),
                display: true,
                details: None,
            },
        ]
    );
}

#[tokio::test]
async fn simple_commands_and_their_data() {
    let agent = Rc::new(Fake::default());
    assert_eq!(
        run(&agent, json!({ "id": 7, "type": "abort" })).await,
        json!({ "type": "response", "id": 7, "command": "abort", "success": true })
    );
    assert_eq!(agent.take(), ["abort", "idle"]);
    assert_eq!(
        run(&agent, json!({ "type": "get_commands" })).await["data"],
        json!({ "commands": [{ "name": "compact" }] })
    );
    assert_eq!(
        run(&agent, json!({ "type": "get_messages" })).await["data"],
        json!({ "messages": [] })
    );
    assert_eq!(
        run(&agent, json!({ "type": "get_available_models" })).await["data"],
        json!({ "models": [] })
    );
    assert_eq!(
        run(
            &agent,
            json!({ "type": "compact", "customInstructions": 1 })
        )
        .await["error"],
        "Nothing to compact"
    );
    assert_eq!(
        run(
            &agent,
            json!({ "type": "set_model", "provider": "fake", "modelId": null }),
        )
        .await["error"],
        "set_model needs provider and modelId"
    );
    assert_eq!(
        run(&agent, json!({ "type": "set_model", "modelId": 12 })).await["error"],
        "set_model needs provider and modelId"
    );
    run(
        &agent,
        json!({ "type": "set_model", "provider": "fake", "modelId": "m" }),
    )
    .await;
    run(
        &agent,
        json!({ "type": "set_role", "role": ["a", null, true] }),
    )
    .await;
    run(&agent, json!({ "type": "set_session_name", "name": null })).await;
    run(&agent, json!({ "type": "set_session_name", "name": "Hi" })).await;
    assert_eq!(
        agent.take(),
        [
            "refresh",
            "refresh",
            "compact None",
            "refresh",
            "refresh",
            "refresh",
            "set_model fake m",
            "set_role [\"a\",null,true]",
            "set_name \"\" User",
            "set_name \"Hi\" User",
        ]
    );
    assert_eq!(
        run(
            &agent,
            json!({ "type": "set_thinking_level", "level": "max" })
        )
        .await["error"],
        "Unknown thinking level: max"
    );
    assert_eq!(
        run(&agent, json!({ "type": "teleport" })).await["error"],
        "Unsupported command: teleport"
    );
    assert_eq!(
        run(&agent, json!({ "message": "x" })).await,
        json!({ "type": "response", "success": false, "error": "Unsupported command: (missing)" })
    );
    assert_eq!(
        run(&agent, json!({ "type": "clear_queue" })).await["data"],
        json!({ "steering": [], "followUp": [] })
    );
}

#[tokio::test]
async fn get_context_answers_only_what_fits_the_line() {
    let agent = Rc::new(Fake::default());
    let response = run(&agent, json!({ "type": "get_context" })).await;
    assert_eq!(
        serde_json::to_string(&response).unwrap(),
        r#"{"type":"response","command":"get_context","success":true,"data":null}"#
    );
    let context = json!({ "text": "x".repeat(100) });
    let size = serde_json::to_vec(&context).unwrap().len();
    *agent.context.borrow_mut() = Some(context.clone());
    for (max, fits) in [
        (json!(null), true),
        (json!(size), false),
        (json!(size + 1), true),
        (json!(-5), false),
        (json!("big"), true),
        (json!(1e12), true),
    ] {
        let data =
            run(&agent, json!({ "type": "get_context", "maxBytes": max })).await["data"].clone();
        assert_eq!(
            data,
            if fits { context.clone() } else { Value::Null },
            "{max}"
        );
    }
    *agent.context.borrow_mut() = Some(json!({ "text": "x".repeat(512 * 1024) }));
    assert_eq!(
        run(&agent, json!({ "type": "get_context" })).await["data"],
        Value::Null
    );
}

#[test]
fn js_strings() {
    assert_eq!(js_string(None), "(missing)");
    assert_eq!(js_string(Some(&json!(1.5))), "1.5");
    assert_eq!(js_string(Some(&json!(2.0))), "2");
    assert_eq!(js_string(Some(&json!(-3))), "-3");
    assert_eq!(js_string(Some(&json!({ "a": 1 }))), "{\"a\":1}");
    assert_eq!(js_string(Some(&json!([1, [2, 3], null]))), "[1,[2,3],null]");
}

#[tokio::test]
async fn serves_lines_until_input_ends() {
    local(async {
        let (write, lines) = recorder();
        let agent = Rc::new(Fake::default());
        let ui = RpcUi::new(write.clone());
        let channels = Rc::new(NodeChannels::new(write.clone()));
        let lease = channels.write_broker.acquire("/w", None);
        let lease_id = line(&lines, 0)["id"].clone();
        let dialog = {
            let ui = ui.clone();
            tokio::task::spawn_local(
                async move { ui.input("q", None, DialogOptions::default()).await },
            )
        };
        settle().await;
        let dialog_id = line(&lines, 1)["id"].clone();
        lines.borrow_mut().clear();
        let (sender, mut input) = mpsc::unbounded_channel();
        for text in [
            String::new(),
            "  \u{feff}".to_owned(),
            "{not json".to_owned(),
            super::LINE_TOO_LONG.to_owned(),
            json!({ "type": "write_lease_response", "id": lease_id, "granted": true }).to_string(),
            json!({ "type": "extension_ui_response", "id": dialog_id, "value": "a" }).to_string(),
            json!({ "type": "team_result", "id": "x" }).to_string(),
            json!({ "id": "c1", "type": "get_state" }).to_string(),
            "5".to_owned(),
            json!({ "id": "c2", "type": "abort" }).to_string(),
        ] {
            sender.send(text).unwrap();
        }
        drop(sender);
        serve(agent.clone(), ui, channels, write, &mut input)
            .await
            .unwrap();
        settle().await;
        assert_eq!(lease.await, Ok(()));
        assert_eq!(dialog.await.unwrap().as_deref(), Some("a"));
        assert_eq!(
            *lines.borrow(),
            [
                json!({ "type": "response", "command": "parse", "success": false,
                    "error": "Invalid JSON" }),
                json!({ "type": "response", "command": "parse", "success": false,
                    "error": "Line too long" }),
                json!({ "type": "response", "id": "c1", "command": "get_state", "success": true,
                    "data": { "isRunning": false } }),
                json!({ "type": "response", "success": false,
                    "error": "Unsupported command: (missing)" }),
                json!({ "type": "response", "id": "c2", "command": "abort", "success": true }),
            ]
        );
    })
    .await;
}

#[tokio::test]
async fn a_null_command_ends_serving_with_an_error() {
    local(async {
        let (write, _) = recorder();
        let (sender, mut input) = mpsc::unbounded_channel();
        sender.send("null".to_owned()).unwrap();
        let ui = RpcUi::new(write.clone());
        let channels = Rc::new(NodeChannels::new(write.clone()));
        let served = serve(Rc::new(Fake::default()), ui, channels, write, &mut input).await;
        assert!(served.unwrap_err().contains("null is not an object"));
    })
    .await;
}
