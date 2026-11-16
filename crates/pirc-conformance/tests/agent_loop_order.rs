//! The ordering guarantees of the agent loop that a future extraction of the
//! loop (`crates/pirc-agent-loop`) must keep: a message is persisted before
//! its `message_end`, a reply's tool calls run one at a time in call order,
//! interrupted calls are recorded rather than run, retries and role fallbacks
//! emit their events around unpersisted attempts, and a context overflow is
//! compacted at most once per run before the turn is retried.
//!
//! Lines are reduced to labels; each `message_end` is marked with whether
//! the session file already held that message when the line was read.

use std::time::Duration;

use pirc_conformance::{AgentOptions, AgentRun, Gate, ModelReply, Recorder};
use serde_json::{Value, json};

fn calls(list: &[(&str, &str, Value)]) -> ModelReply {
    ModelReply::Tools(
        list.iter()
            .map(|(id, name, args)| ((*id).to_owned(), (*name).to_owned(), args.clone()))
            .collect(),
    )
}

/// Whether the session file holds `message` (by role, timestamp and, for a
/// tool result, its call id).
fn persisted(agent: &AgentRun, message: &Value) -> bool {
    agent.session_entries().iter().any(|entry| {
        let stored = &entry["message"];
        entry["type"] == "message"
            && stored["role"] == message["role"]
            && stored["timestamp"] == message["timestamp"]
            && stored["toolCallId"] == message["toolCallId"]
    })
}

/// A line reduced to what identifies it in the order.
fn label(agent: &AgentRun, line: &Value) -> Value {
    let kind = line["type"].as_str().unwrap_or_default();
    let text = |value: &Value| value.as_str().unwrap_or_default().to_owned();
    json!(match kind {
        "response" => {
            let mut label = format!("response {} {}", text(&line["command"]), line["success"]);
            if let Some(code) = line["errorCode"].as_str() {
                label += &format!(" ({code})");
            }
            label
        }
        "message_start" => format!("message_start {}", text(&line["message"]["role"])),
        "message_end" => {
            let message = &line["message"];
            let mut label = format!("message_end {}", text(&message["role"]));
            match message["role"].as_str() {
                Some("assistant") => label += &format!(" {}", text(&message["stopReason"])),
                Some("toolResult") => label += &format!(" {}", text(&message["toolCallId"])),
                _ => {}
            }
            if persisted(agent, message) {
                label + " (persisted)"
            } else {
                label + " (not persisted)"
            }
        }
        "message_update" => format!(
            "message_update {}",
            text(&line["assistantMessageEvent"]["type"])
        ),
        "tool_execution_start" | "tool_execution_end" => {
            format!("{kind} {}", text(&line["toolCallId"]))
        }
        "auto_retry_start" => format!(
            "auto_retry_start {}/{} {}ms: {}",
            line["attempt"],
            line["maxAttempts"],
            line["delayMs"],
            text(&line["errorMessage"])
        ),
        "auto_retry_end" => format!("auto_retry_end {} {}", line["attempt"], line["success"]),
        "compaction_start" => format!("compaction_start {}", text(&line["reason"])),
        "compaction_end" => match line.get("errorMessage") {
            Some(error) => format!(
                "compaction_end {} failed (aborted {}): {}",
                text(&line["reason"]),
                line["aborted"],
                text(error)
            ),
            None => format!("compaction_end {}", text(&line["reason"])),
        },
        "agent_error" => format!("agent_error {}", text(&line["error"])),
        "extension_ui_request" if line["method"] == "notify" => format!(
            "notify {}: {}",
            text(&line["notifyType"]),
            text(&line["message"])
        ),
        "extension_ui_request" => format!("extension_ui_request {}", text(&line["method"])),
        _ => kind.to_owned(),
    })
}

/// Labels of the lines until one satisfies `done` (included).
/// `tool_execution_update` lines are left out: how often a running tool
/// reports output depends on timing.
async fn labels_until(agent: &mut AgentRun, mut done: impl FnMut(&Value) -> bool) -> Vec<Value> {
    let mut labels = Vec::new();
    loop {
        let line = agent
            .next()
            .await
            .unwrap_or_else(|| panic!("agent exited after {labels:?}"));
        if line["type"] != "tool_execution_update" {
            labels.push(label(agent, &line));
        }
        if done(&line) {
            return labels;
        }
    }
}

async fn labels_until_settled(agent: &mut AgentRun) -> Vec<Value> {
    labels_until(agent, |line| line["type"] == "agent_settled").await
}

/// The text of each tool result in the session whose call id starts with
/// `prefix`.
fn tool_results(agent: &AgentRun, prefix: &str) -> Value {
    let results: Vec<Value> = agent
        .session_entries()
        .iter()
        .filter(|entry| {
            entry["message"]["role"] == "toolResult"
                && entry["message"]["toolCallId"]
                    .as_str()
                    .is_some_and(|id| id.starts_with(prefix))
        })
        .map(|entry| {
            let message = &entry["message"];
            let text: String = message["content"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|part| part["text"].as_str())
                .collect();
            json!({ "id": message["toolCallId"], "isError": message["isError"], "text": text })
        })
        .collect();
    json!(results)
}

/// Each session entry as its type and, for messages, role and stop reason.
fn session_outline(agent: &AgentRun) -> Value {
    let outline: Vec<Value> = agent
        .session_entries()
        .iter()
        .map(|entry| {
            let message = &entry["message"];
            match entry["type"].as_str() {
                Some("message") => {
                    let mut text = format!("message {}", message["role"].as_str().unwrap_or(""));
                    if let Some(stop) = message["stopReason"].as_str() {
                        text += &format!(" {stop}");
                    }
                    if let Some(error) = message["errorMessage"].as_str() {
                        text += &format!(": {error}");
                    }
                    json!(text)
                }
                Some("compaction") => json!(format!(
                    "compaction {}",
                    entry["details"]["kind"].as_str().unwrap_or("")
                )),
                Some(kind) => json!(kind),
                None => entry.clone(),
            }
        })
        .collect();
    json!(outline)
}

/// Every message is in the session file before its `message_end`; a reply
/// that cannot be persisted has no `message_end` and ends the run.
#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_loop_persistence_before_message_end() {
    let Some(mut agent) = AgentRun::start(AgentOptions::default()).await else {
        return;
    };
    let mut r = Recorder::new(&agent);
    agent.push([
        calls(&[("p1", "read", json!({ "path": "README.md" }))]),
        ModelReply::Text("Read it.".to_owned()),
    ]);
    agent
        .command(json!({ "type": "prompt", "message": "Read the README" }))
        .await;
    let order = labels_until_settled(&mut agent).await;
    r.note("a tool round", json!(order));
    agent.take_requests();

    // The session file changes behind the agent's back after the user
    // message was written: the reply cannot be appended.
    let gate = Gate::new();
    agent.push([ModelReply::gated(
        &gate,
        ModelReply::Text("Never shown.".to_owned()),
    )]);
    agent
        .command(json!({ "type": "prompt", "message": "Answer" }))
        .await;
    agent.wait_for_request().await;
    let file = agent.session_dir.join("session.jsonl");
    let mut raw = std::fs::read(&file).unwrap();
    raw.push(b'\n');
    std::fs::write(&file, raw).unwrap();
    gate.open();
    let order = labels_until_settled(&mut agent).await;
    r.note("a reply that cannot be persisted", json!(order));
    r.note("session afterwards", session_outline(&agent));
    agent.take_requests();

    // The store refuses further writes until it is reopened: the run ends
    // without asking the model for a turn it could not record.
    agent
        .command(json!({ "type": "prompt", "message": "Again" }))
        .await;
    let order = labels_until_settled(&mut agent).await;
    r.note("the next prompt", json!(order));
    r.note("model requests for it", json!(agent.take_requests().len()));
    r.note("session at the end", session_outline(&agent));
    insta::assert_json_snapshot!("agent_loop_persistence_before_message_end", r.into_value());
}

/// The calls of one reply run one at a time, in call order: a call sees
/// what the one before it did, however long that took.
#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_loop_serial_tools() {
    let Some(mut agent) = AgentRun::start(AgentOptions::default()).await else {
        return;
    };
    let mut r = Recorder::new(&agent);
    agent.push([
        calls(&[
            (
                "s1",
                "bash",
                json!({ "command": "sleep 0.5; printf 'first\\n' > order.txt" }),
            ),
            ("s2", "read", json!({ "path": "order.txt" })),
            (
                "s3",
                "bash",
                json!({ "command": "printf 'third\\n' >> order.txt; cat order.txt" }),
            ),
        ]),
        ModelReply::Text("In order.".to_owned()),
    ]);
    agent
        .command(json!({ "type": "prompt", "message": "Three steps" }))
        .await;
    let order = labels_until_settled(&mut agent).await;
    r.note("three calls in one reply", json!(order));
    r.note("tool results", tool_results(&agent, "s"));
    r.note(
        "order.txt",
        json!(std::fs::read_to_string(agent.workspace.join("order.txt")).unwrap()),
    );
    // A steer while the batch runs waits for the whole batch.
    agent.push([
        calls(&[
            ("t1", "bash", json!({ "command": "sleep 0.5" })),
            (
                "t2",
                "bash",
                json!({ "command": "printf 'ran\\n' > steered.txt" }),
            ),
        ]),
        ModelReply::Text("Saw the steer.".to_owned()),
    ]);
    agent
        .command(json!({ "type": "prompt", "message": "Two steps" }))
        .await;
    let mut order = labels_until(&mut agent, |line| {
        line["type"] == "tool_execution_start" && line["toolCallId"] == "t1"
    })
    .await;
    agent
        .command(json!({ "type": "steer", "message": "Also this" }))
        .await;
    order.extend(labels_until_settled(&mut agent).await);
    r.note("a steer during the batch", json!(order));
    r.note(
        "steered.txt exists",
        json!(agent.workspace.join("steered.txt").exists()),
    );
    insta::assert_json_snapshot!("agent_loop_serial_tools", r.into_value());
}

/// A message sent now, or an abort, interrupts the running call; the calls
/// after it are recorded as not run, and never run.
#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_loop_tool_interruptions() {
    let Some(mut agent) = AgentRun::start(AgentOptions::default()).await else {
        return;
    };
    let mut r = Recorder::new(&agent);
    for (step, prefix, interrupt) in [("send now", "n", true), ("abort", "a", false)] {
        let marker = format!("{}.txt", step.replace(' ', "-"));
        let id = |n: u8| format!("{prefix}{n}");
        agent.push([
            ModelReply::Tools(vec![
                (id(1), "bash".to_owned(), json!({ "command": "sleep 5" })),
                (
                    id(2),
                    "bash".to_owned(),
                    json!({ "command": format!("printf 'ran\\n' > {marker}") }),
                ),
                (id(3), "read".to_owned(), json!({ "path": "README.md" })),
            ]),
            ModelReply::Text("After the interruption.".to_owned()),
        ]);
        agent
            .command(json!({ "type": "prompt", "message": "Slow work" }))
            .await;
        let first = id(1);
        let mut order = labels_until(&mut agent, |line| {
            line["type"] == "tool_execution_start" && line["toolCallId"] == first.as_str()
        })
        .await;
        if interrupt {
            agent
                .command(json!({ "type": "follow_up", "message": "Stop that" }))
                .await;
            agent
                .command(json!({ "type": "send_now", "queue": "followUp", "index": 0,
                    "message": "Stop that" }))
                .await;
        } else {
            agent.command(json!({ "type": "abort" })).await;
        }
        order.extend(labels_until_settled(&mut agent).await);
        r.note(&format!("{step}: order"), json!(order));
        r.note(
            &format!("{step}: tool results"),
            tool_results(&agent, prefix),
        );
        r.note(
            &format!("{step}: later call ran"),
            json!(agent.workspace.join(&marker).exists()),
        );
        agent.take_requests();
    }
    insta::assert_json_snapshot!("agent_loop_tool_interruptions", r.into_value());
}

/// Retried attempts end with `message_end` but are never persisted; a reply
/// with text is not retried; an abort during the retry delay persists the
/// aborted reply without another `message_end`.
#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_loop_retry_order() {
    let Some(mut agent) = AgentRun::start(AgentOptions::default()).await else {
        return;
    };
    let mut r = Recorder::new(&agent);
    agent.push([
        ModelReply::Failed("Model provider request failed (HTTP 503).".to_owned()),
        ModelReply::Text("Recovered.".to_owned()),
    ]);
    agent
        .command(json!({ "type": "prompt", "message": "Retry once" }))
        .await;
    let order = labels_until_settled(&mut agent).await;
    r.note("a retried 503", json!(order));
    r.note("model requests", json!(agent.take_requests().len()));

    agent.push([ModelReply::Raw(vec![
        json!({ "type": "model_delta", "delta": { "type": "text_start", "contentIndex": 0 } }),
        json!({ "type": "model_delta", "delta": { "type": "text_delta", "contentIndex": 0,
            "delta": "Partial" } }),
        json!({ "type": "model_error", "code": "timeout" }),
    ])]);
    agent
        .command(json!({ "type": "prompt", "message": "Partial then timeout" }))
        .await;
    let order = labels_until_settled(&mut agent).await;
    r.note(
        "a transport timeout after streamed text (the reply keeps no text, so it is retried)",
        json!(order),
    );
    r.note("model requests", json!(agent.take_requests().len()));

    agent.push([ModelReply::Raw(vec![
        json!({ "type": "model_delta", "delta": { "type": "text_start", "contentIndex": 0 } }),
        json!({ "type": "model_delta", "delta": { "type": "text_delta", "contentIndex": 0,
            "delta": "Partial" } }),
        json!({ "type": "model_end", "message": { "role": "assistant",
            "content": [{ "type": "text", "text": "Partial" }], "api": "openai-completions",
            "provider": "fake", "model": "fake-model", "usage": { "input": 100, "output": 10,
            "cacheRead": 40, "cacheWrite": 0, "totalTokens": 150 }, "stopReason": "error",
            "errorMessage": "Model provider request failed (HTTP 503).", "timestamp": 1 } }),
    ])]);
    agent
        .command(json!({ "type": "prompt", "message": "Text then 503" }))
        .await;
    let order = labels_until_settled(&mut agent).await;
    r.note(
        "a retryable error on a reply with text is not retried",
        json!(order),
    );
    r.note("model requests", json!(agent.take_requests().len()));

    agent.push([ModelReply::Error("timeout".to_owned())]);
    agent
        .command(json!({ "type": "prompt", "message": "Abort the retry" }))
        .await;
    let mut order = labels_until(&mut agent, |line| line["type"] == "auto_retry_start").await;
    agent.command(json!({ "type": "abort" })).await;
    order.extend(labels_until_settled(&mut agent).await);
    r.note("an abort during the retry delay", json!(order));
    r.note("model requests", json!(agent.take_requests().len()));
    r.note("session", session_outline(&agent));
    insta::assert_json_snapshot!("agent_loop_retry_order", r.into_value());
}

/// Every retry used: three delays (2 s, 5 s, 15 s), then the last failure
/// is the persisted reply.
#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_loop_retry_exhausted() {
    let Some(mut agent) = AgentRun::start(AgentOptions::default()).await else {
        return;
    };
    let mut r = Recorder::new(&agent);
    agent.push(
        (0..4).map(|_| ModelReply::Failed("Model provider request failed (HTTP 503).".to_owned())),
    );
    agent
        .command(json!({ "type": "prompt", "message": "Keep failing" }))
        .await;
    let order = tokio::time::timeout(Duration::from_secs(60), labels_until_settled(&mut agent))
        .await
        .expect("the retries did not end");
    r.note("four failed attempts", json!(order));
    r.note("model requests", json!(agent.take_requests().len()));
    r.note("session", session_outline(&agent));
    insta::assert_json_snapshot!("agent_loop_retry_exhausted", r.into_value());
}

/// A retryable failure with a role that lists another model switches to it
/// at once, without a retry delay; the failed attempt is not persisted.
#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_loop_role_fallback() {
    let mut models = pirc_conformance::fake_models();
    models["providers"]["fake"]["models"]
        .as_array_mut()
        .unwrap()
        .push(
            json!({ "id": "backup-model", "contextWindow": 100000, "maxTokens": 1000,
            "reasoning": false, "input": ["text"], "compat": {} }),
        );
    let options = AgentOptions {
        configure: json!({ "role": { "name": "worker",
            "models": ["fake/fake-model", "fake/backup-model"] } }),
        models: Some(models),
        ..AgentOptions::default()
    };
    let Some(mut agent) = AgentRun::start(options).await else {
        return;
    };
    let mut r = Recorder::new(&agent);
    agent.push([
        ModelReply::Failed("Model provider request failed (HTTP 429).".to_owned()),
        ModelReply::Text("From the fallback.".to_owned()),
    ]);
    agent
        .command(json!({ "type": "prompt", "message": "Fall back" }))
        .await;
    let order = labels_until_settled(&mut agent).await;
    r.note("a 429 with a fallback model", json!(order));
    let models: Vec<Value> = agent
        .take_requests()
        .iter()
        .map(|request| request["modelId"].clone())
        .collect();
    r.note("requested models", json!(models));
    r.note("session", session_outline(&agent));
    insta::assert_json_snapshot!("agent_loop_role_fallback", r.into_value());
}

fn compaction_options() -> AgentOptions {
    AgentOptions {
        config: json!({ "features": { "compaction": { "keepRecentTokens": 1, "warmCache": false } } }),
        ..AgentOptions::default()
    }
}

/// A valid handoff for the compaction request it answers.
fn handoff() -> ModelReply {
    ModelReply::computed(|body| {
        let content = &body["messages"][0]["content"];
        let payload: Value = serde_json::from_str(content.as_str().unwrap()).unwrap();
        let source = &payload["sources"][0];
        ModelReply::Text(
            json!({ "state": { "goal": [{ "text": "Continue the repository task",
                "sources": [{ "sessionId": source["sessionId"], "entryId": source["entryId"] }] }],
                "activeConstraints": [], "progress": [], "decisions": [], "openQuestions": [],
                "nextSteps": [] }, "resolvedConstraints": [] })
            .to_string(),
        )
    })
}

/// A context overflow is not persisted; the turn ends, the context is
/// compacted, and the turn runs again. A second overflow in the same run is
/// persisted without another compaction; a failed compaction persists the
/// overflow it could not recover from.
#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_loop_overflow_compaction() {
    let Some(mut agent) = AgentRun::start(compaction_options()).await else {
        return;
    };
    let mut r = Recorder::new(&agent);
    agent.push([ModelReply::Text("Ready.".to_owned())]);
    agent
        .command(json!({ "type": "prompt", "message": "Original source ".repeat(500) }))
        .await;
    labels_until_settled(&mut agent).await;
    agent.take_requests();

    agent.push([
        ModelReply::Failed("context length exceeded".to_owned()),
        handoff(),
        ModelReply::Text("Recovered.".to_owned()),
    ]);
    agent
        .command(json!({ "type": "prompt", "message": "Continue after overflow" }))
        .await;
    let order = labels_until_settled(&mut agent).await;
    r.note("an overflow, compacted", json!(order));
    r.note("model requests", json!(agent.take_requests().len()));
    r.note("session", session_outline(&agent));

    agent.push([ModelReply::Text("More.".to_owned())]);
    agent
        .command(json!({ "type": "prompt", "message": "More source ".repeat(500) }))
        .await;
    labels_until_settled(&mut agent).await;
    agent.take_requests();
    agent.push([
        ModelReply::Failed("context length exceeded".to_owned()),
        handoff(),
        ModelReply::Failed("context length exceeded".to_owned()),
    ]);
    agent
        .command(json!({ "type": "prompt", "message": "Overflow twice" }))
        .await;
    let order = labels_until_settled(&mut agent).await;
    r.note("a second overflow in one run", json!(order));
    r.note("model requests", json!(agent.take_requests().len()));

    agent.push([ModelReply::Text("Again.".to_owned())]);
    agent
        .command(json!({ "type": "prompt", "message": "Further source ".repeat(500) }))
        .await;
    labels_until_settled(&mut agent).await;
    agent.take_requests();
    agent.push([
        ModelReply::Failed("context length exceeded".to_owned()),
        ModelReply::Text("invalid structured output".to_owned()),
    ]);
    agent
        .command(json!({ "type": "prompt", "message": "Overflow, bad handoff" }))
        .await;
    let order = labels_until_settled(&mut agent).await;
    r.note("an overflow whose compaction fails", json!(order));
    r.note("model requests", json!(agent.take_requests().len()));
    r.note("session at the end", session_outline(&agent));
    insta::assert_json_snapshot!("agent_loop_overflow_compaction", r.into_value());
}
