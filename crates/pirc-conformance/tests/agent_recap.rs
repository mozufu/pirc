//! The `recap` feature (docs/development/historical-records.md): `/recap` collects
//! evidence through the gateway (`recap.collect`), asks the model once
//! without tools and records a redacted report; bad arguments, an empty
//! history, failures, a second recap while one runs, cancellation, and
//! the sessions where `/recap` does not exist (no gateway, chats,
//! headless agents).

mod feature_support;

use feature_support::{Masker, command, notified, then, tools};
use pirc_conformance::{AgentOptions, AgentRun, ModelReply, Recorder};
use serde_json::{Value, json};

const SECRET: &str = "recap-secret-value-0123456789";

fn evidence(sessions: bool) -> Value {
    let sessions = if sessions {
        json!([{ "sessionId": "session-source", "truncated": false, "evidence": [
            { "entryId": "entry-source", "timestamp": 15, "role": "user",
              "text": format!("Please run the tests; my token is {SECRET}") },
            { "entryId": "entry-reply", "timestamp": 16, "role": "assistant",
              "text": "Ran them." } ] },
            { "sessionId": "session-`two`\n<b>", "truncated": true, "evidence": [] }])
    } else {
        json!([])
    };
    json!({ "ok": true, "result": {
        "version": 1,
        "scope": { "workspaceId": "workspace-1", "days": 7, "since": 1767225600000u64,
            "until": 1767830400123u64 },
        "sampling": "Most recent 20 eligible sessions;\nbounded sample.",
        "sessions": sessions,
        "skipped": [
            { "sessionId": "skipped-1", "reason": "recap_marked_session" },
            { "sessionId": "skipped-2", "reason": "too_large" },
            { "sessionId": "skipped-3", "reason": "recap_marked_session" } ],
        "truncated": sessions.as_array().is_some_and(|s| !s.is_empty()),
        "scannedBytes": 1234567,
    } })
}

fn recap_options() -> AgentOptions {
    AgentOptions {
        env: vec![
            ("PIRC_WRITE_BROKER".to_owned(), "1".to_owned()),
            ("PIRC_GATEWAY".to_owned(), "1".to_owned()),
            ("RECAP_TEST_TOKEN".to_owned(), SECRET.to_owned()),
        ],
        files: vec![
            ("README.md".to_owned(), "conformance\n".to_owned()),
            ("AGENTS.md".to_owned(), "Always run the tests.".to_owned()),
        ],
        config: json!({ "features": { "goal": true, "todo": { "enabled": false },
            "webSearch": { "enabled": "yes" } } }),
        ..AgentOptions::default()
    }
    .features("recap")
}

/// The recap's end: its status cleared.
fn done(line: &Value) -> bool {
    line["type"] == "extension_ui_request"
        && line["method"] == "setStatus"
        && line["statusKey"] == "recap"
        && line.get("statusText").is_none()
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_recap() {
    let Some(mut agent) = AgentRun::start(recap_options()).await else {
        return;
    };
    let mut r = Recorder::new(&agent);
    let mut m = Masker::new();
    let commands = agent.call(json!({ "type": "get_commands" })).await;
    m.note(&mut r, "commands", commands);
    for (step, text) in [
        ("zero days", "/recap 0"),
        ("too many days", "/recap 91"),
        ("a fraction", "/recap 1.5 focus"),
        ("a negative number", "/recap -1"),
        ("days that are not a number", "/recap --days nope"),
    ] {
        command(&mut agent, &mut m, &mut r, step, text).await;
    }
    agent
        .answers
        .lock()
        .unwrap()
        .gateway
        .insert("recap.collect".to_owned(), evidence(true));
    agent.push([ModelReply::Text(format!(
        "  Recommendation [session-source / entry-source]. sk-abcdefghijklmnopqrstuvwxyz1234 and {SECRET}  "
    ))]);
    command(
        &mut agent,
        &mut m,
        &mut r,
        "a recap",
        "/recap --days 7 test focus",
    )
    .await;
    then(&mut agent, &mut m, &mut r, "the report", done).await;
    m.turn(&mut r, "the report", &agent, Vec::new());
    for (step, text, reply) in [
        (
            "a failed model call",
            "/recap",
            ModelReply::Failed("PRIVATE provider error".to_owned()),
        ),
        (
            "a tool call",
            "/recap 3",
            tools(&[("t1", "read", json!({ "path": "README.md" }))]),
        ),
        (
            "an empty reply",
            "/recap 最近兩週",
            ModelReply::Text("   ".to_owned()),
        ),
    ] {
        agent.push([reply]);
        command(&mut agent, &mut m, &mut r, step, text).await;
        then(&mut agent, &mut m, &mut r, &format!("{step}: end"), done).await;
        m.turn(&mut r, step, &agent, Vec::new());
    }
    agent
        .answers
        .lock()
        .unwrap()
        .gateway
        .insert("recap.collect".to_owned(), evidence(false));
    command(
        &mut agent,
        &mut m,
        &mut r,
        "no history",
        "/recap 2 最近兩週",
    )
    .await;
    then(&mut agent, &mut m, &mut r, "no history: end", done).await;
    agent.answers.lock().unwrap().gateway.insert(
        "recap.collect".to_owned(),
        json!({ "ok": false, "error": { "code": "invalid_input", "message": "PRIVATE detail" } }),
    );
    command(&mut agent, &mut m, &mut r, "a gateway error", "/recap").await;
    then(&mut agent, &mut m, &mut r, "a gateway error: end", done).await;
    // A recap waits for the model; a second one is refused; abort cancels it.
    agent
        .answers
        .lock()
        .unwrap()
        .gateway
        .insert("recap.collect".to_owned(), evidence(true));
    agent.push([ModelReply::Hang("Partial".to_owned())]);
    command(&mut agent, &mut m, &mut r, "a slow recap", "/recap").await;
    // Wait until the model call is under way.
    agent.wait_for_request().await;
    command(&mut agent, &mut m, &mut r, "a second recap", "/recap").await;
    let response = agent.call(json!({ "type": "abort" })).await;
    m.note(&mut r, "abort", response);
    then(&mut agent, &mut m, &mut r, "cancelled", |line| {
        notified(line, "cancelled")
    })
    .await;
    then(&mut agent, &mut m, &mut r, "cancelled: end", done).await;
    m.turn(&mut r, "the slow recap", &agent, Vec::new());
    m.session(&mut r, &agent);
    insta::assert_json_snapshot!("agent_recap", r.into_value());
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_recap_unavailable() {
    let gateway = |kind: Option<&str>| {
        let mut env = vec![
            ("PIRC_WRITE_BROKER".to_owned(), "1".to_owned()),
            ("PIRC_GATEWAY".to_owned(), "1".to_owned()),
        ];
        if let Some(kind) = kind {
            let mode = if kind == "chat" {
                pirc_protocol::mode::default_chat()
            } else {
                pirc_protocol::mode::default_work()
            };
            env.push((
                "PIRC_MODE".to_owned(),
                serde_json::to_string(&mode).unwrap(),
            ));
        }
        env
    };
    for (name, options) in [
        ("no gateway", AgentOptions::default().features("recap")),
        (
            "chat",
            AgentOptions {
                env: gateway(Some("chat")),
                ..AgentOptions::default()
            }
            .features("recap"),
        ),
        (
            "headless",
            AgentOptions {
                env: gateway(None),
                args: vec!["--headless".to_owned()],
                ..AgentOptions::default()
            }
            .features("recap"),
        ),
    ] {
        let Some(mut agent) = AgentRun::start(options).await else {
            return;
        };
        let mut r = Recorder::new(&agent);
        let mut m = Masker::new();
        let commands = agent.call(json!({ "type": "get_commands" })).await;
        m.note(&mut r, "commands", commands);
        // Not a command: the text goes to the model.
        agent.push([ModelReply::Text("No recap here.".to_owned())]);
        feature_support::turn(&mut agent, &mut m, &mut r, "recap", "/recap 7").await;
        insta::assert_json_snapshot!(
            format!("agent_recap_unavailable_{}", name.replace(' ', "_")),
            r.into_value()
        );
    }
}
