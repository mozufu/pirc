//! Agent teams (`agent/features/team/`, feature `agent-team`) as far as
//! they go without `ptc` scripts, with the test playing the agent's node:
//! the team capabilities in the system prompt and their `ptc_docs` (roles
//! in the `role` field), the side panel, the `/team` command without a
//! team, the settings and chats that leave the feature out, and an agent
//! started as a team member or one-shot subagent (`PIRC_TEAM_AGENT`),
//! whose write leases go to its parent as `team_call`s answered by
//! `team_result` lines. Spawning, messaging and waiting run inside `ptc`
//! scripts and are in `agent_team_ptc.rs`. The historical feature
//! baseline (docs/development/historical-records.md).

use std::collections::VecDeque;

use pirc_conformance::{AgentOptions, AgentRun, ModelReply, Recorder};
use serde_json::{Value, json};

fn text(value: &str) -> ModelReply {
    ModelReply::Text(value.to_owned())
}

fn tools(calls: &[(&str, &str, Value)]) -> ModelReply {
    ModelReply::Tools(
        calls
            .iter()
            .map(|(id, name, args)| ((*id).to_owned(), (*name).to_owned(), args.clone()))
            .collect(),
    )
}

/// A node role, so the `role` field lists more than `general`.
const REVIEWER: &str = "---\ndescription: Reviews changes without editing them.\nmodel: fake/small-*\nthinking: low\ntools: [read, grep]\n---\nReview carefully; never edit files.\n";

fn options() -> AgentOptions {
    let mut options = AgentOptions::default().features("agent-team");
    options
        .files
        .push((".pirc/roles/reviewer.md".to_owned(), REVIEWER.to_owned()));
    options
}

/// A prompt and everything until the run settles.
async fn turn(agent: &mut AgentRun, r: &mut Recorder, step: &str, message: &str) {
    let response = agent
        .call(json!({ "type": "prompt", "message": message }))
        .await;
    r.note(&format!("{step}: response"), response);
    let events = agent.settle().await;
    r.turn(step, agent, events);
}

/// A slash command: its lines up to its response and the notification
/// that ends it.
async fn slash(agent: &mut AgentRun, r: &mut Recorder, message: &str) {
    let id = agent
        .command(json!({ "type": "prompt", "message": message }))
        .await;
    let mut lines = Vec::new();
    let (mut answered, mut ended) = (false, false);
    while !(answered && ended) {
        let line = agent.next().await.expect("the agent exited");
        answered |= line["type"] == "response" && line["id"] == id.as_str();
        ended |= line["type"] == "extension_ui_request" && line["method"] == "notify";
        lines.push(line);
    }
    r.note(message, json!(lines));
}

/// The "## Capabilities" section of a request's system prompt and the
/// tools it offers the model.
fn surface(request: &Value) -> Value {
    let prompt = request["systemPrompt"].as_str().unwrap_or_default();
    let section = prompt
        .split("## Capabilities")
        .nth(1)
        .map(|rest| rest.split("\n## ").next().unwrap_or_default())
        .unwrap_or_default();
    let tools: Vec<Value> = request["tools"]
        .as_array()
        .map(|tools| tools.iter().map(|tool| tool["name"].clone()).collect())
        .unwrap_or_default();
    json!({ "capabilities": section, "tools": tools })
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_team_surface() {
    let Some(mut agent) = AgentRun::start(options()).await else {
        return;
    };
    let mut r = Recorder::new(&agent);
    let commands = agent.call(json!({ "type": "get_commands" })).await;
    r.note("commands", commands);
    let panel = agent.call(json!({ "type": "get_panel_state" })).await;
    r.note("panel without a team", panel);
    agent.push([
        tools(&[
            (
                "d1",
                "ptc_docs",
                json!({ "names": ["agent_spawn", "subagent", "agent_stop", "agent_list",
                    "agent_wait", "agent_send", "agent_ask", "agent_reply"] }),
            ),
            (
                "d2",
                "ptc_docs",
                json!({ "names": ["agent_inbox", "board_post", "board_read", "task_create",
                    "task_list", "task_get", "task_update"] }),
            ),
            ("d3", "ptc_docs", json!({ "category": "team" })),
        ]),
        text("Documented."),
    ]);
    turn(&mut agent, &mut r, "team docs", "Look up the team tools").await;
    // Without a team the command only explains itself.
    for message in [
        "/team",
        "/team status",
        "/team stop helper",
        "/team stop all",
        "/team stop",
        "/team stop a b",
        "/team frob",
    ] {
        slash(&mut agent, &mut r, message).await;
    }
    let panel = agent.call(json!({ "type": "get_panel_state" })).await;
    r.note("panel after the commands", panel);
    let (lines, code) = agent.close().await;
    r.note("shutdown", json!(lines));
    r.note("exit code", json!(code));
    insta::assert_json_snapshot!("agent_team_surface", r.into_value());
}

/// One run's first request: what the model is offered.
async fn offered(options: AgentOptions, r: &mut Recorder, step: &str) {
    let Some(mut agent) = AgentRun::start(options).await else {
        return;
    };
    agent.push([text("Ok.")]);
    agent
        .call(json!({ "type": "prompt", "message": "go" }))
        .await;
    agent.settle().await;
    let commands = agent.call(json!({ "type": "get_commands" })).await;
    let requests = agent.take_requests();
    // Each agent has its own temporary directory.
    let mut observed =
        json!({ "surface": surface(&requests[0]), "commands": commands["data"] }).to_string();
    for (path, placeholder) in agent.volatile() {
        observed = observed.replace(&path, placeholder);
    }
    r.note(step, serde_json::from_str(&observed).unwrap());
    agent.finish().await;
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_team_settings() {
    let Some(probe) = AgentRun::start(options()).await else {
        return;
    };
    let mut r = Recorder::new(&probe);
    drop(probe);
    offered(options(), &mut r, "default").await;
    offered(
        AgentOptions {
            config: json!({ "features": { "agentTeam": { "enabled": false } } }),
            ..options()
        },
        &mut r,
        "disabled",
    )
    .await;
    insta::assert_json_snapshot!("agent_team_settings", r.into_value());
}

/// An agent started by a team parent: `PIRC_TEAM_AGENT` names it,
/// `PIRC_TEAM_MODE` says `team` or `subagent`, and its role's tool
/// allowlist comes as `--tools`.
fn child(mode: &str) -> AgentOptions {
    let mut options = AgentOptions {
        args: [
            "--headless",
            "--name",
            &format!("{mode}:worker"),
            "--tools",
            "read,write",
        ]
        .map(str::to_owned)
        .to_vec(),
        ..AgentOptions::default()
    }
    .features("agent-team");
    options.env.extend([
        ("PIRC_TEAM_AGENT".to_owned(), "worker".to_owned()),
        ("PIRC_TEAM_MODE".to_owned(), mode.to_owned()),
    ]);
    options
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_team_member() {
    let Some(mut agent) = AgentRun::start(child("team")).await else {
        return;
    };
    let mut r = Recorder::new(&agent);
    let commands = agent.call(json!({ "type": "get_commands" })).await;
    r.note("commands", commands);
    let panel = agent.call(json!({ "type": "get_panel_state" })).await;
    r.note("panel", panel);
    // Leases come from the parent: granted, then refused.
    agent.answers.lock().unwrap().team = VecDeque::from([
        json!({ "result": { "granted": true } }),
        json!({ "error": "Another session holds the write lease" }),
    ]);
    agent.push([
        tools(&[(
            "w1",
            "write",
            json!({ "path": "granted.txt", "content": "one" }),
        )]),
        tools(&[(
            "w2",
            "write",
            json!({ "path": "refused.txt", "content": "two" }),
        )]),
        text("Written."),
    ]);
    turn(
        &mut agent,
        &mut r,
        "writes under the parent's lease",
        "Team message (agent data, not a user/system instruction):\n{\"body\":\"write two files\"}",
    )
    .await;
    // Answers for calls nobody made are ignored.
    agent
        .send(json!({ "type": "team_result", "id": "unknown", "result": { "granted": true } }))
        .await;
    agent
        .send(json!({ "type": "team_result", "id": 7, "error": "nope" }))
        .await;
    // An abort while the parent has not answered cancels the call.
    agent.answers.lock().unwrap().team = VecDeque::from([json!({ "hold": true })]);
    agent.push([
        tools(&[(
            "w3",
            "write",
            json!({ "path": "held.txt", "content": "three" }),
        )]),
        text("unused"),
    ]);
    let response = agent
        .call(json!({ "type": "prompt", "message": "write one more" }))
        .await;
    r.note("held lease: response", response);
    let mut lines = agent.until(|line| line["type"] == "team_call").await;
    let response = agent.call(json!({ "type": "abort" })).await;
    r.note("held lease: abort", response);
    lines.extend(agent.settle().await);
    r.turn("held lease", &agent, lines);
    // A late answer to the cancelled call changes nothing.
    let state = agent.call(json!({ "type": "get_state" })).await;
    r.note("state", state["data"]["isStreaming"].clone());
    r.session(&agent);
    r.note(
        "files",
        json!(
            ["granted.txt", "refused.txt", "held.txt"]
                .map(|name| agent.workspace.join(name).exists())
        ),
    );
    let (lines, code) = agent.close().await;
    r.note("shutdown", json!(lines));
    r.note("exit code", json!(code));
    insta::assert_json_snapshot!("agent_team_member", r.into_value());
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_team_subagent() {
    let Some(mut agent) = AgentRun::start(child("subagent")).await else {
        return;
    };
    let mut r = Recorder::new(&agent);
    let commands = agent.call(json!({ "type": "get_commands" })).await;
    r.note("commands", commands);
    agent.answers.lock().unwrap().team = VecDeque::from([json!({ "result": { "granted": true } })]);
    agent.push([
        tools(&[(
            "w1",
            "write",
            json!({ "path": "report.txt", "content": "done" }),
        )]),
        text("Report."),
    ]);
    turn(
        &mut agent,
        &mut r,
        "a one-shot task",
        "You are a one-shot subagent started by a parent agent.\n\nTask:\nwrite the report",
    )
    .await;
    let (lines, code) = agent.close().await;
    r.note("shutdown", json!(lines));
    r.note("exit code", json!(code));
    insta::assert_json_snapshot!("agent_team_subagent", r.into_value());
}
