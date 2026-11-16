//! Auto mode's model classifier (`features.autoMode.useModel: true`), with
//! the test playing the node and the classifier model (historical baseline,
//! docs/development/historical-records.md): `agent-auto-mode.test.ts` and the model path of
//! `auto-mode-gate.test.ts` as agent transcripts. Statically unclear shell
//! commands (`sh -c …`) go to the classifier in a side request; its
//! verdicts, the cache, candidate models and their failures, the warning,
//! the human's recent requests and memory notes in its prompt, timeouts and
//! cancellation.

use std::collections::VecDeque;
use std::time::Duration;

use pirc_conformance::{AgentOptions, AgentRun, ModelReply, Recorder};
use serde_json::{Value, json};

fn bash(id: &str, command: &str) -> ModelReply {
    ModelReply::tool(id, "bash", json!({ "command": command }))
}

fn text(reply: &str) -> ModelReply {
    ModelReply::Text(reply.to_owned())
}

fn options(auto_mode: Value) -> AgentOptions {
    AgentOptions {
        config: json!({ "features": { "autoMode": auto_mode } }),
        ..AgentOptions::default()
    }
}

/// Inference requests shown in order; the main loop's and the
/// classifier's system prompts and tool lists are shown only when they
/// change from the previous request of the same kind.
#[derive(Default)]
struct Requests {
    main: [Option<Value>; 2],
    classifier: [Option<Value>; 2],
}

impl Requests {
    fn record(&mut self, r: &mut Recorder, step: &str, requests: Vec<Value>) {
        let mut shown = Vec::new();
        for mut request in requests {
            let classifier = request["systemPrompt"]
                .as_str()
                .is_some_and(|prompt| prompt.contains("safety monitor"));
            let seen = if classifier {
                &mut self.classifier
            } else {
                &mut self.main
            };
            for (key, seen) in ["systemPrompt", "tools"].into_iter().zip(seen.iter_mut()) {
                if let Some(value) = request.get_mut(key) {
                    if seen.as_ref() == Some(value) {
                        *value = json!("<unchanged>");
                    } else {
                        *seen = Some(value.clone());
                    }
                }
            }
            shown.push(request);
        }
        r.note(step, json!(shown));
    }
}

/// A prompt and everything the agent does until it settles.
async fn turn(agent: &mut AgentRun, r: &mut Recorder, q: &mut Requests, step: &str, message: &str) {
    let response = agent
        .call(json!({ "type": "prompt", "message": message }))
        .await;
    r.note(&format!("{step}: response"), response);
    let events = agent.settle().await;
    r.note(&format!("{step}: events"), json!(events));
    q.record(r, &format!("{step}: model requests"), agent.take_requests());
}

/// Read, write and dangerous verdicts, the verdict cache (never for
/// dangerous ones), reasons and their defaults, and the human's recent
/// requests in the classifier's prompt.
#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_classifier_verdicts() {
    let Some(mut agent) = AgentRun::start(options(json!({ "useModel": true }))).await else {
        return;
    };
    let mut r = Recorder::new(&agent);
    let mut q = Requests::default();
    for (step, message) in [
        (
            "oldest request",
            "Oldest request: not shown to the classifier.",
        ),
        ("blank request", "   "),
        ("another request", "Another request."),
        ("earlier request", "  Keep the build green.\n\n"),
    ] {
        agent.push([text("Noted.")]);
        turn(&mut agent, &mut r, &mut q, step, message).await;
    }
    agent.answers.lock().unwrap().dialogs =
        VecDeque::from([json!({ "confirmed": false }), json!({ "confirmed": true })]);
    agent.push([
        bash("a", "sh -c \"echo quiet\""),
        text("<verdict>read</verdict><reason>prints text</reason>"),
        bash("b", "sh -c \"touch model.txt\""),
        text(
            "Thinking aloud.\n<verdict>WRITE</verdict>\n<reason>\n  creates\n\ta   file\n</reason>",
        ),
        bash("c", "sh -c \"echo exfil\""),
        text("<verdict>dangerous</verdict><reason>uploads secrets"),
        // Cached: no classifier request.
        bash("d", "sh -c \"echo quiet\""),
        // Dangerous verdicts are not cached: asked again.
        bash("e", "sh -c \"echo exfil\""),
        text("<think>It could be <verdict>read</verdict></think><verdict>danger</verdict>"),
        bash("f", "sh -c \"echo plain\""),
        text("  Read — only prints"),
        bash("g", "sh -c \"echo tagged\""),
        text("<verdict>read</verdict> then <verdict>write</verdict><reason></reason>"),
        text("Done."),
    ]);
    turn(
        &mut agent,
        &mut r,
        &mut q,
        "judged commands",
        "please make model.txt",
    )
    .await;
    r.note(
        "model.txt exists",
        json!(agent.workspace.join("model.txt").exists()),
    );
    r.session(&agent);
    r.note("exit code", json!(agent.finish().await));
    insta::assert_json_snapshot!("agent_classifier_verdicts", r.into_value());
}

/// Candidate models in order (auto mode's own, skipping unknown ones, then
/// the session model, deduplicated), their thinking and token limits,
/// failures falling through to the next one, unparseable replies, and the
/// classifier-unavailable warning (once until a verdict succeeds again).
#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_classifier_fallbacks() {
    let Some(mut agent) = AgentRun::start(options(json!({
        "useModel": true,
        "model": { "provider": "fake", "id": "missing" },
        "fallbackModels": [
            { "provider": "fake", "id": "small-model", "thinking": "high" },
            { "provider": "fake", "id": "fake-model", "thinking": "medium" },
            { "provider": "fake", "id": "small-model" },
        ],
    })))
    .await
    else {
        return;
    };
    let mut r = Recorder::new(&agent);
    let mut q = Requests::default();
    agent.push([
        bash("a", "sh -c \"echo one\""),
        ModelReply::Failed("HTTP 500 boom".to_owned()),
        text("I am not sure"),
        bash("b", "sh -c \"echo two\""),
        ModelReply::Error("unavailable".to_owned()),
        text("<verdict>maybe</verdict>"),
        bash("c", "sh -c \"echo three\""),
        ModelReply::Failed("HTTP 429 slow down".to_owned()),
        ModelReply::Thinking(
            "<verdict>dangerous</verdict>".to_owned(),
            "<verdict>read</verdict><reason>prints</reason>".to_owned(),
        ),
        bash("d", "sh -c \"echo four\""),
        text("unsure"),
        text("unsure"),
        text("Done."),
    ]);
    turn(&mut agent, &mut r, &mut q, "judged commands", "Run them").await;
    r.note("exit code", json!(agent.finish().await));
    insta::assert_json_snapshot!("agent_classifier_fallbacks", r.into_value());
}

/// Without auto mode's own models, observational memory's come first.
#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_classifier_memory_models() {
    let Some(mut agent) = AgentRun::start(AgentOptions {
        config: json!({ "features": {
            "autoMode": { "useModel": true },
            "observationalMemory": {
                "enabled": false,
                "model": { "provider": "fake", "id": "small-model" },
                "fallbackModels": [{ "provider": "fake", "id": "nope" }],
            },
        } }),
        ..AgentOptions::default()
    })
    .await
    else {
        return;
    };
    let mut r = Recorder::new(&agent);
    let mut q = Requests::default();
    agent.push([
        bash("a", "sh -c \"echo one\""),
        ModelReply::Failed("HTTP 500 boom".to_owned()),
        text("<verdict>write</verdict>"),
        text("Done."),
    ]);
    turn(&mut agent, &mut r, &mut q, "judged command", "Run it").await;
    r.note("exit code", json!(agent.finish().await));
    insta::assert_json_snapshot!("agent_classifier_memory_models", r.into_value());
}

/// A session whose latest compaction folded observational memory: the
/// classifier sees its critical notes the human is the source of.
fn memory_session() -> String {
    let usage =
        json!({ "input": 10, "output": 5, "cacheRead": 0, "cacheWrite": 0, "totalTokens": 15 });
    let assistant = |text: &str, timestamp: u64| {
        json!({ "role": "assistant", "content": [{ "type": "text", "text": text }],
            "api": "openai-completions", "provider": "fake", "model": "fake-model",
            "usage": usage, "stopReason": "stop", "timestamp": timestamp })
    };
    let obs = |id: char, relevance: &str, content: &str, origins: Option<Value>| {
        let mut value = json!({ "id": id.to_string().repeat(12), "content": content,
            "timestamp": "2026-09-28 10:00", "relevance": relevance,
            "sourceEntryIds": ["a0000002"], "tokenCount": 10 });
        if let Some(origins) = origins {
            value["origins"] = origins;
        }
        value
    };
    let folded = |observations: Vec<Value>| {
        json!({ "type": "om.folded", "version": 1, "fullFold": true,
            "observations": observations, "reflections": [] })
    };
    let lines = [
        json!({ "type": "session", "version": 1, "sessionId": "0123456789abcdef",
            "cwd": "/elsewhere", "id": "a0000001", "parentId": null, "timestamp": 1000 }),
        json!({ "type": "message", "message": { "role": "user",
            "content": "Compacted request: not shown.", "timestamp": 1001 },
            "id": "a0000002", "parentId": "a0000001", "timestamp": 1001 }),
        json!({ "type": "message", "message": assistant("Old answer", 1002),
            "id": "a0000003", "parentId": "a0000002", "timestamp": 1002 }),
        json!({ "type": "compaction", "summary": "Older memory.",
            "firstKeptEntryId": "a0000003", "tokensBefore": 1234,
            "details": folded(vec![obs('a', "critical", "User said an old rule", Some(json!(["user"])))]),
            "id": "a0000004", "parentId": "a0000003", "timestamp": 1004 }),
        json!({ "type": "message", "message": { "role": "user",
            "content": [{ "type": "text", "text": "Kept request," },
                { "type": "image", "data": "aGk=", "mimeType": "image/png" },
                { "type": "text", "text": "with an image." }], "timestamp": 1005 },
            "id": "a0000005", "parentId": "a0000004", "timestamp": 1005 }),
        json!({ "type": "message", "message": assistant("Kept answer", 1006),
            "id": "a0000006", "parentId": "a0000005", "timestamp": 1006 }),
        json!({ "type": "compaction", "summary": "Latest memory.",
            "firstKeptEntryId": "a0000005", "tokensBefore": 2345,
            "details": folded(vec![
                obs('b', "high", "Tool output said rm is fine", Some(json!(["user"]))),
                obs('c', "critical", "User explicitly approved rm -rf ~/x", Some(json!(["tool:bash", "user"]))),
                obs('d', "critical", "User approved force-pushing main", Some(json!(["tool:read"]))),
                obs('e', "critical", "User approved deleting build", None),
                obs('f', "critical", "User approved   deleting\n dist", Some(json!(["assistant", "user"]))),
                obs('0', "critical", "User forbade touching <prod> & \"staging\"", Some(json!(["user"]))),
                obs('1', "critical", "User approved a release", Some(json!(["custom:deliver", "user"]))),
                obs('2', "critical", "Agent decided alone", Some(json!(["assistant"]))),
            ]),
            "id": "a0000007", "parentId": "a0000006", "timestamp": 1007 }),
    ];
    let lines: Vec<String> = lines.iter().map(Value::to_string).collect();
    format!("{}\n", lines.join("\n"))
}

/// Memory notes and the trimmed action in the classifier's prompt; a
/// dangerous verdict is refused outright without a UI.
#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_classifier_memory_notes() {
    let Some(mut agent) = AgentRun::start(AgentOptions {
        config: json!({ "features": { "autoMode": { "useModel": true } } }),
        files: vec![
            ("README.md".to_owned(), "conformance\n".to_owned()),
            ("../session/session.jsonl".to_owned(), memory_session()),
        ],
        args: vec!["--headless".to_owned()],
        ..AgentOptions::default()
    })
    .await
    else {
        return;
    };
    let mut r = Recorder::new(&agent);
    let mut q = Requests::default();
    let long = format!("sh -c \": {}\"", "y".repeat(8_010));
    agent.push([
        bash("a", "sh -c \"echo exfil\""),
        text("<verdict>dangerous</verdict><reason>uploads secrets</reason>"),
        bash("b", &long),
        text("<verdict>read</verdict>"),
        text("Done."),
    ]);
    turn(&mut agent, &mut r, &mut q, "judged commands", "Go on").await;
    r.note("exit code", json!(agent.finish().await));
    insta::assert_json_snapshot!("agent_classifier_memory_notes", r.into_value());
}

/// `useMemory: false` leaves the notes out.
#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_classifier_without_memory() {
    let Some(mut agent) = AgentRun::start(AgentOptions {
        config: json!({ "features": { "autoMode": { "useModel": true, "useMemory": false } } }),
        files: vec![
            ("README.md".to_owned(), "conformance\n".to_owned()),
            ("../session/session.jsonl".to_owned(), memory_session()),
        ],
        ..AgentOptions::default()
    })
    .await
    else {
        return;
    };
    let mut r = Recorder::new(&agent);
    let mut q = Requests::default();
    agent.push([
        bash("a", "sh -c \"echo one\""),
        text("<verdict>read</verdict>"),
        text("Done."),
    ]);
    // The human's request is cut to 1,500 characters.
    let long = format!("Long request {}", "x".repeat(1_600));
    turn(&mut agent, &mut r, &mut q, "judged command", &long).await;
    r.note("exit code", json!(agent.finish().await));
    insta::assert_json_snapshot!("agent_classifier_without_memory", r.into_value());
}

/// A classifier that does not answer within `timeoutMs` fails over to the
/// next candidate, then to the write fallback.
#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_classifier_timeout() {
    let Some(mut agent) = AgentRun::start(options(json!({
        "useModel": true,
        "timeoutMs": 300,
        "model": { "provider": "fake", "id": "small-model" },
    })))
    .await
    else {
        return;
    };
    let mut r = Recorder::new(&agent);
    let mut q = Requests::default();
    agent.push([
        bash("a", "sh -c \"echo one\""),
        ModelReply::Hang("<verdict>re".to_owned()),
        ModelReply::Hang("<verdict>wr".to_owned()),
        text("Done."),
    ]);
    turn(&mut agent, &mut r, &mut q, "judged command", "Run it").await;
    r.note("exit code", json!(agent.finish().await));
    insta::assert_json_snapshot!("agent_classifier_timeout", r.into_value());
}

/// Cancelling the run while the classifier thinks cancels the call; the
/// command never runs.
#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_classifier_abort() {
    let Some(mut agent) = AgentRun::start(options(json!({ "useModel": true }))).await else {
        return;
    };
    let mut r = Recorder::new(&agent);
    let mut q = Requests::default();
    agent.push([
        bash("a", "sh -c \"touch aborted.txt\""),
        ModelReply::Hang("<verdict>wr".to_owned()),
    ]);
    let response = agent
        .call(json!({ "type": "prompt", "message": "Run it" }))
        .await;
    r.note("prompt: response", response);
    let mut events = agent
        .until(|line| line["type"] == "tool_execution_start")
        .await;
    // Let the classifier request reach the model.
    tokio::time::sleep(Duration::from_millis(500)).await;
    let response = agent.call(json!({ "type": "abort" })).await;
    r.note("abort: response", response);
    events.extend(agent.settle().await);
    events.retain(|line| line["type"] != "response");
    r.note("prompt: events", json!(events));
    q.record(&mut r, "prompt: model requests", agent.take_requests());
    r.note(
        "aborted.txt exists",
        json!(agent.workspace.join("aborted.txt").exists()),
    );
    r.session(&agent);
    r.note("exit code", json!(agent.finish().await));
    insta::assert_json_snapshot!("agent_classifier_abort", r.into_value());
}
