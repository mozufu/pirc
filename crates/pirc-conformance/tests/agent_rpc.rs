//! The agent's RPC edges (features off), with the test playing its node:
//! startup flags, configuration warnings, lines that are not commands, and
//! how the process ends on a broken handshake or a `null` line. Complements
//! `agent_core.rs` (docs/development/historical-records.md).

use pirc_conformance::{AgentOptions, AgentRun, Recorder};
use serde_json::{Value, json};

/// Every line until `count` responses arrived.
async fn responses(agent: &mut AgentRun, count: usize) -> Vec<Value> {
    let mut seen = 0;
    agent
        .until(|line| {
            if line["type"] == "response" {
                seen += 1;
            }
            seen == count
        })
        .await
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_startup_options() {
    let Some(mut agent) = AgentRun::start(AgentOptions {
        files: vec![
            ("README.md".to_owned(), "conformance\n".to_owned()),
            // Untrusted project settings: ignored, with a warning.
            (
                ".pirc/config.json".to_owned(),
                json!({ "env": { "FROM_PROJECT": "1" } }).to_string(),
            ),
        ],
        args: [
            "--model",
            "fake/small-model",
            "--thinking",
            "high",
            "--name",
            "Named at start",
            "--headless",
            "--mode",
            "rpc",
            "--continue",
        ]
        .map(str::to_owned)
        .to_vec(),
        ..AgentOptions::default()
    })
    .await
    else {
        return;
    };
    let mut r = Recorder::new(&agent);
    agent.command(json!({ "type": "get_state" })).await;
    let lines = responses(&mut agent, 1).await;
    r.note("startup and state", json!(lines));
    r.session(&agent);
    r.note("exit code", json!(agent.finish().await));
    insta::assert_json_snapshot!("agent_startup_options", r.into_value());
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_rpc_lines() {
    let Some(mut agent) = AgentRun::start(AgentOptions::default()).await else {
        return;
    };
    let mut r = Recorder::new(&agent);
    // Valid JSON that is no command object.
    agent.send_raw("5\n\"text\"\n[1]\n\n   \n").await;
    let lines = responses(&mut agent, 3).await;
    r.note("lines that are not objects", json!(lines));
    // Answers nobody waits for are dropped; the next response is the marker's.
    for line in [
        json!({ "type": "extension_ui_response", "id": "nobody", "value": "x" }),
        json!({ "type": "write_lease_response", "id": "nobody", "granted": true }),
        json!({ "type": "gateway_response", "id": "nobody", "ok": true }),
        json!({ "type": "browser_response", "id": "nobody", "ok": true }),
        json!({ "type": "sandbox_response", "id": "nobody", "ok": true }),
        json!({ "type": "team_result", "id": "nobody" }),
    ] {
        agent.send(line).await;
    }
    agent
        .send(json!({ "id": null, "type": "clear_queue", "extra": true }))
        .await;
    let lines = responses(&mut agent, 1).await;
    r.note(
        "unanswered responses, then a command with a null id",
        json!(lines),
    );
    for (step, command) in [
        (
            "context with maxBytes 0",
            json!({ "type": "get_context", "maxBytes": 0 }),
        ),
        (
            "set_model with missing fields",
            json!({ "type": "set_model" }),
        ),
        (
            "set_session_name with null",
            json!({ "type": "set_session_name", "name": null }),
        ),
        (
            "deliver with a string message",
            json!({ "type": "deliver", "message": "hello" }),
        ),
    ] {
        let response = agent.call(command).await;
        r.note(step, response);
    }
    // `null` is thrown out of the RPC loop: the process fails.
    agent.send_raw("null\n").await;
    let mut rest = Vec::new();
    while let Some(line) = agent.next().await {
        rest.push(line);
    }
    r.note("lines still unread, then the end of output", json!(rest));
    r.note("exit code", json!(agent.finish().await));
    insta::assert_json_snapshot!("agent_rpc_lines", r.into_value());
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_configure_errors() {
    let mut r = None;
    for (step, configure) in [
        ("not a configure message", json!({ "type": "hello" })),
        (
            "an invalid catalog",
            json!({ "models": { "providers": { "broken": { "api": "zzz" } } } }),
        ),
    ] {
        let Some(mut agent) = AgentRun::start(AgentOptions {
            configure,
            ..AgentOptions::default()
        })
        .await
        else {
            return;
        };
        let recorder = r.get_or_insert_with(|| Recorder::new(&agent));
        let mut lines = Vec::new();
        while let Some(line) = agent.next().await {
            lines.push(line);
        }
        recorder.note(&format!("{step}: stdout"), json!(lines));
        recorder.note(&format!("{step}: exit code"), json!(agent.finish().await));
    }
    if let Some(r) = r {
        insta::assert_json_snapshot!("agent_configure_errors", r.into_value());
    }
}
