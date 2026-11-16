//! The agent's tool policy chain with the test playing its node (features
//! off): user hooks around tool calls, the auto-mode rules (danger
//! approvals, the deny-list, write-lease targets) and `ptc_docs` lookups.
//! The historical core baseline (docs/development/historical-records.md).

use std::collections::VecDeque;

use pirc_conformance::{AgentOptions, AgentRun, ModelReply, Recorder, write_executable};
use serde_json::{Value, json};

fn tools(calls: &[(&str, &str, Value)]) -> ModelReply {
    ModelReply::Tools(
        calls
            .iter()
            .map(|(id, name, args)| ((*id).to_owned(), (*name).to_owned(), args.clone()))
            .collect(),
    )
}

/// A prompt and everything the agent does until it settles.
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
async fn agent_hooks() {
    let options = AgentOptions {
        config: json!({
            "hooks": {
                "sessionStart": [{ "command": "echo SESSION-HOOK-CONTEXT" }],
                "beforePrompt": [{ "command": "echo PROMPT-HOOK-CONTEXT" }],
                "beforeTool": [
                    {
                        "matcher": "bash",
                        "command": "grep -q 'rm -rf' && { echo 'no deleting' >&2; exit 2; } || exit 0",
                    },
                    {
                        "matcher": "write",
                        "command": "printf '{\"args\":{\"path\":\"out.txt\",\"content\":\"QUIET\"}}'",
                    },
                    { "matcher": "read|ls", "command": "exit 1" },
                ],
                "afterTool": [{ "matcher": "write", "command": "echo formatted" }],
            }
        }),
        ..AgentOptions::default()
    };
    let Some(mut agent) = AgentRun::start(options).await else {
        return;
    };
    let mut r = Recorder::new(&agent);
    agent.push([
        tools(&[
            ("h1", "bash", json!({ "command": "rm -rf /tmp/whatever" })),
            (
                "h2",
                "write",
                json!({ "path": "quiet.txt", "content": "quiet" }),
            ),
            ("h3", "read", json!({ "path": "out.txt" })),
            ("h4", "bash", json!({ "command": "printf ok" })),
        ]),
        ModelReply::Text("Hooked.".to_owned()),
    ]);
    turn(&mut agent, &mut r, "hooked tools", "Use the tools").await;
    r.session(&agent);
    r.note("exit code", json!(agent.finish().await));
    insta::assert_json_snapshot!("agent_hooks", r.into_value());
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_auto_mode() {
    // This policy scenario records a missing interpreter, independent of whether
    // the host has Python installed. Keep the command and historical transcript.
    let bin = tempfile::tempdir().unwrap();
    write_executable(
        &bin.path().join("python3"),
        "#!/bin/sh\nprintf '%s\\n' '/bin/bash: line 1: python3: command not found' >&2\nexit 127\n",
    );
    let mut options = AgentOptions {
        config: json!({ "features": { "autoMode": { "deny": ["deploy-prod", "rm -rf ("] } } }),
        ..AgentOptions::default()
    };
    options.env.push((
        "PATH".to_owned(),
        format!(
            "{}:{}",
            bin.path().display(),
            std::env::var("PATH").unwrap_or_default()
        ),
    ));
    let Some(mut agent) = AgentRun::start(options).await else {
        return;
    };
    let mut r = Recorder::new(&agent);
    agent.answers.lock().unwrap().dialogs =
        VecDeque::from([json!({ "confirmed": false }), json!({ "confirmed": true })]);
    agent.push([
        tools(&[
            (
                "a1",
                "bash",
                json!({ "command": "rm -rf /opt/pirc-conformance-gone" }),
            ),
            (
                "a2",
                "bash",
                json!({ "command": "rm -rf /opt/pirc-conformance-gone" }),
            ),
            ("a3", "bash", json!({ "command": "echo deploy-prod" })),
            ("a4", "bash", json!({ "command": "ls; echo 'rm -rf ('" })),
            (
                "a5",
                "bash",
                json!({ "command": "mkdir -p build/out && ls build" }),
            ),
            ("a6", "bash", json!({ "command": "cat README.md | wc -l" })),
            ("a7", "bash", json!({ "command": "python3 -c 1 || true" })),
        ]),
        ModelReply::Text("Judged.".to_owned()),
    ]);
    turn(&mut agent, &mut r, "judged commands", "Run commands").await;
    r.session(&agent);
    r.note("exit code", json!(agent.finish().await));
    insta::assert_json_snapshot!("agent_auto_mode", r.into_value());
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_ptc_docs() {
    let Some(mut agent) = AgentRun::start(AgentOptions::default()).await else {
        return;
    };
    let mut r = Recorder::new(&agent);
    agent.push([
        tools(&[
            ("d1", "ptc_docs", json!({})),
            ("d2", "ptc_docs", json!({ "category": "files" })),
            (
                "d3",
                "ptc_docs",
                json!({ "names": ["bash", "grep", "bash"] }),
            ),
            (
                "d4",
                "ptc_docs",
                json!({ "names": ["read"], "category": "files" }),
            ),
            (
                "d5",
                "ptc_docs",
                json!({ "category": "files", "cursor": "forged.cursor" }),
            ),
            ("d6", "ptc_docs", json!({ "category": "web" })),
            ("d7", "ptc_docs", json!({ "names": [] })),
            ("d8", "ptc_docs", json!({ "registryVersion": "stale" })),
        ]),
        ModelReply::Text("Documented.".to_owned()),
    ]);
    turn(&mut agent, &mut r, "docs lookups", "Look things up").await;
    r.session(&agent);
    r.note("exit code", json!(agent.finish().await));
    insta::assert_json_snapshot!("agent_ptc_docs", r.into_value());
}
