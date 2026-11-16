//! The agent's configuration and session store as the node sees them
//! (features off): project and node prompt files, untrusted project config
//! and memory settings warnings, chat workspace prompts, and resuming a
//! session file the TS agent wrote (docs/development/historical-records.md).

use pirc_conformance::{AgentOptions, AgentRun, ModelReply, Recorder, fake_models};
use serde_json::{Value, json};

/// The default catalog with room in `small-model`, so no turn here compacts.
fn roomy_models() -> Value {
    let mut models = fake_models();
    models["providers"]["fake"]["models"][1]["contextWindow"] = json!(100_000);
    models
}

fn file(path: &str, content: impl Into<String>) -> (String, String) {
    (path.to_owned(), content.into())
}

/// Lines up to the response of `command`, startup notifications included.
async fn command(agent: &mut AgentRun, command: Value) -> Vec<Value> {
    let id = agent.command(command).await;
    agent
        .until(|line| line["type"] == "response" && line["id"] == id.as_str())
        .await
}

async fn turn(agent: &mut AgentRun, r: &mut Recorder, step: &str, message: &str) {
    let response = agent
        .call(json!({ "type": "prompt", "message": message }))
        .await;
    r.note(&format!("{step}: response"), response);
    let events = agent.settle().await;
    r.turn(step, agent, events);
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_project_config() {
    let Some(mut agent) = AgentRun::start(AgentOptions {
        files: vec![
            file("README.md", "conformance\n"),
            file("AGENTS.md", "\n  Workspace rules: be brief.  \n\n"),
            file(".pirc/AGENTS.md", "Project rules: cite files."),
            file(
                ".pirc/config.json",
                json!({
                    "defaultModel": { "provider": "fake", "id": "small-model" },
                    "env": { "PROJECT_VAR": "from-project" },
                    "hooks": { "sessionStart": [{ "command": "echo untrusted" }] }
                })
                .to_string(),
            ),
            file("../config/AGENTS.md", "Node rules: 😀 count UTF-16."),
        ],
        config: json!({
            "features": { "observationalMemory": { "enabled": false, "oldOption": "private" } },
            "limits": { "maxTurns": 5 }
        }),
        models: Some(roomy_models()),
        ..AgentOptions::default()
    })
    .await
    else {
        return;
    };
    let mut r = Recorder::new(&agent);
    let startup = command(&mut agent, json!({ "type": "get_state" })).await;
    r.note("startup and state", json!(startup));
    agent.push([ModelReply::Text("Brief.".to_owned())]);
    turn(&mut agent, &mut r, "prompt", "Who are you?").await;
    let context = agent.call(json!({ "type": "get_context" })).await;
    r.note("context", context);
    r.session(&agent);
    insta::assert_json_snapshot!("agent_project_config", r.into_value());
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_chat_prompts() {
    let Some(mut agent) = AgentRun::start(AgentOptions {
        env: vec![
            ("PIRC_WRITE_BROKER".to_owned(), "1".to_owned()),
            (
                "PIRC_MODE".to_owned(),
                serde_json::to_string(&pirc_protocol::mode::default_chat()).unwrap(),
            ),
        ],
        files: vec![
            file("AGENTS.md", "Coding rules that a chat ignores."),
            file(
                "../config/AGENTS.md",
                "Node coding rules that a chat ignores.",
            ),
            file(
                "../config/SOUL.md",
                "  You are Juniper.\r\nSpeak plainly.\r\n",
            ),
            file("../config/CHAT.md", "Chat rules: no emoji."),
        ],
        ..AgentOptions::default()
    })
    .await
    else {
        return;
    };
    let mut r = Recorder::new(&agent);
    let startup = command(&mut agent, json!({ "type": "get_state" })).await;
    r.note("startup and state", json!(startup));
    agent.push([ModelReply::Text("Hello.".to_owned())]);
    turn(&mut agent, &mut r, "prompt", "Hi").await;
    insta::assert_json_snapshot!("agent_chat_prompts", r.into_value());
}

/// A session file as the TS agent wrote it, with an entry type this
/// version does not know and a damaged line.
fn old_session() -> String {
    let usage =
        json!({ "input": 10, "output": 5, "cacheRead": 0, "cacheWrite": 0, "totalTokens": 15 });
    let assistant = |text: &str, timestamp: u64| {
        json!({ "role": "assistant", "content": [{ "type": "text", "text": text }],
            "api": "openai-completions", "provider": "fake", "model": "fake-model",
            "usage": usage, "stopReason": "stop", "timestamp": timestamp })
    };
    let lines = [
        json!({ "type": "session", "version": 1, "sessionId": "0123456789abcdef",
            "cwd": "/elsewhere", "id": "a0000001", "parentId": null, "timestamp": 1000 })
        .to_string(),
        json!({ "type": "message", "message": { "role": "user", "content": "Old question",
            "timestamp": 1001 }, "id": "a0000002", "parentId": "a0000001", "timestamp": 1001 })
        .to_string(),
        json!({ "type": "message", "message": assistant("Old answer", 1002),
            "id": "a0000003", "parentId": "a0000002", "timestamp": 1002 })
        .to_string(),
        json!({ "type": "compaction", "summary": "The user asked an old question.",
            "firstKeptEntryId": "a0000003", "tokensBefore": 1234,
            "id": "a0000004", "parentId": "a0000003", "timestamp": 1004 })
        .to_string(),
        json!({ "type": "label", "note": "from a newer agent",
            "id": "a0000005", "parentId": "a0000004", "timestamp": 1005 })
        .to_string(),
        json!({ "type": "custom", "customType": "ptc.operation", "data": {
            "parentToolCallId": "p1", "toolCallId": "p1:1", "toolName": "read",
            "args": { "path": "x" }, "content": [{ "type": "text", "text": "x" }],
            "isError": false, "timestamp": 1006 },
            "id": "a0000006", "parentId": "a0000005", "timestamp": 1006 })
        .to_string(),
        json!({ "type": "model_change", "provider": "fake", "modelId": "small-model",
            "id": "a0000007", "parentId": "a0000006", "timestamp": 1007 })
        .to_string(),
        json!({ "type": "thinking_level_change", "thinkingLevel": "high",
            "id": "a0000008", "parentId": "a0000007", "timestamp": 1008 })
        .to_string(),
        json!({ "type": "session_info", "name": "Resumed", "source": "user",
            "id": "a0000009", "parentId": "a0000008", "timestamp": 1009 })
        .to_string(),
        json!({ "type": "message", "message": { "role": "user", "content": "Newer question",
            "timestamp": 1010 }, "id": "a000000a", "parentId": "a0000009", "timestamp": 1010 })
        .to_string(),
        json!({ "type": "message", "message": assistant("Newer answer", 1011),
            "id": "a000000b", "parentId": "a000000a", "timestamp": 1011 })
        .to_string(),
    ];
    format!(
        "{}\n{{\"type\":\"message\",\"message\":{{\"role\":\"us",
        lines.join("\n")
    )
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_resume_session() {
    let Some(mut agent) = AgentRun::start(AgentOptions {
        files: vec![
            file("README.md", "conformance\n"),
            file("../session/session.jsonl", old_session()),
        ],
        models: Some(roomy_models()),
        ..AgentOptions::default()
    })
    .await
    else {
        return;
    };
    let mut r = Recorder::new(&agent);
    let startup = command(&mut agent, json!({ "type": "get_state" })).await;
    r.note("startup and state", json!(startup));
    let messages = agent.call(json!({ "type": "get_messages" })).await;
    r.note("messages", messages);
    agent.push([ModelReply::Text("Resumed answer.".to_owned())]);
    turn(&mut agent, &mut r, "prompt", "Continue").await;
    let context = agent.call(json!({ "type": "get_context" })).await;
    r.note("context", context);
    // The interrupted tail is recovered at writer open; complete legacy entries survive.
    let lines: Vec<Value> = std::fs::read_to_string(agent.session_dir.join("session.jsonl"))
        .unwrap()
        .split('\n')
        .map(|line| serde_json::from_str(line).unwrap_or_else(|_| json!({ "<line>": line })))
        .collect();
    r.note("session file", json!(lines));
    insta::assert_json_snapshot!("agent_resume_session", r.into_value());
}
