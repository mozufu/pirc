//! The `goal` feature without `ptc` scripts (docs/development/historical-records.md):
//! `/goal` commands, continuation rounds started when the agent settles,
//! pauses at the round limit and after an interrupted run, a goal restored
//! disarmed after a restart, and the feature turned off (config, chats).
//! The goal tools themselves are reachable only from `ptc` scripts; those
//! scenarios are in `agent_goal_ptc.rs`.

mod feature_support;

use feature_support::{Masker, command, notified, settle, settle_events, then, tools, turn};
use pirc_conformance::{AgentOptions, AgentRun, ModelReply, Recorder};
use serde_json::{Value, json};

/// The hanging reply's text arrived (its last event): nothing more comes
/// until the agent gives up the request.
fn streaming(line: &Value) -> bool {
    line["type"] == "message_update" && line["assistantMessageEvent"]["type"] == "text_delta"
}

fn goal_options(config: Value) -> AgentOptions {
    AgentOptions {
        config,
        ..AgentOptions::default()
    }
    .features("goal")
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_goal_commands() {
    let Some(mut agent) = AgentRun::start(goal_options(
        json!({ "features": { "goal": { "defaultMaxRounds": 1 } } }),
    ))
    .await
    else {
        return;
    };
    let mut r = Recorder::new(&agent);
    let mut m = Masker::new();
    let commands = agent.call(json!({ "type": "get_commands" })).await;
    m.note(&mut r, "commands", commands);
    for (step, text) in [
        ("show without a goal", "/goal"),
        ("help", "/goal help"),
        ("pause without a goal", "/goal pause"),
        ("set without an objective", "/goal set"),
    ] {
        command(&mut agent, &mut m, &mut r, step, text).await;
    }
    // Created and started at once: round 1 of 1.
    agent.push([ModelReply::Text("Writing the docs.".to_owned())]);
    turn(
        &mut agent,
        &mut m,
        &mut r,
        "set",
        "/goal set Write the docs",
    )
    .await;
    then(&mut agent, &mut m, &mut r, "paused at the limit", |line| {
        notified(line, "Goal paused")
    })
    .await;
    command(&mut agent, &mut m, &mut r, "rounds 2", "/goal rounds 2").await;
    agent.push([ModelReply::Text("More docs.".to_owned())]);
    turn(&mut agent, &mut m, &mut r, "resume", "/goal resume").await;
    then(
        &mut agent,
        &mut m,
        &mut r,
        "paused at the new limit",
        |line| notified(line, "Goal paused"),
    )
    .await;
    for (step, text) in [
        ("edit", "/goal edit  Write the user docs \r\n "),
        ("pause a paused goal", "/goal pause"),
        ("rounds that are not a number", "/goal rounds 2x"),
        ("pause with arguments", "/goal pause now"),
        ("an unknown subcommand", "/goal bogus"),
        ("show", "/goal show"),
    ] {
        command(&mut agent, &mut m, &mut r, step, text).await;
    }
    // Replacing an open goal asks first; declined.
    agent
        .answers
        .lock()
        .unwrap()
        .dialogs
        .extend([json!({ "confirmed": false }), json!({ "confirmed": true })]);
    // The dialog opens before the command is answered; nothing follows.
    command(
        &mut agent,
        &mut m,
        &mut r,
        "set over an open goal",
        "/goal set Other",
    )
    .await;
    command(&mut agent, &mut m, &mut r, "clear", "/goal clear").await;
    then(&mut agent, &mut m, &mut r, "cleared", |line| {
        notified(line, "Goal cleared.")
    })
    .await;
    command(
        &mut agent,
        &mut m,
        &mut r,
        "clear without a goal",
        "/goal clear",
    )
    .await;
    // The model sees the goal state once after a change, and the goal tools.
    agent.push([
        tools(&[(
            "d1",
            "ptc_docs",
            json!({ "names": ["create_goal", "get_goal", "update_goal"] }),
        )]),
        ModelReply::Text("No goal now.".to_owned()),
    ]);
    turn(&mut agent, &mut m, &mut r, "a prompt", "What is the goal?").await;
    let state = agent.call(json!({ "type": "get_state" })).await;
    m.note(&mut r, "state", state);
    m.session(&mut r, &agent);
    insta::assert_json_snapshot!("agent_goal_commands", r.into_value());
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_goal_interrupted() {
    let Some(mut agent) = AgentRun::start(goal_options(json!({}))).await else {
        return;
    };
    let mut r = Recorder::new(&agent);
    let mut m = Masker::new();
    // An aborted round pauses the goal.
    agent.push([ModelReply::Hang("Working".to_owned())]);
    command(&mut agent, &mut m, &mut r, "set", "/goal set Long job").await;
    then(&mut agent, &mut m, &mut r, "round 1 streams", streaming).await;
    let response = agent.call(json!({ "type": "abort" })).await;
    m.note(&mut r, "abort", response);
    then(&mut agent, &mut m, &mut r, "paused", |line| {
        notified(line, "Goal paused")
    })
    .await;
    m.turn(&mut r, "aborted round", &agent, Vec::new());
    // A failed round pauses it too.
    agent.push([ModelReply::Failed("The model broke".to_owned())]);
    turn(&mut agent, &mut m, &mut r, "resume", "/goal resume").await;
    then(&mut agent, &mut m, &mut r, "paused again", |line| {
        notified(line, "Goal paused")
    })
    .await;
    // send_now interrupts a turn, but the run still ends cleanly: the goal
    // goes on to its next round.
    agent.push([
        ModelReply::Hang("Working".to_owned()),
        ModelReply::Text("Redirected.".to_owned()),
        ModelReply::Hang("Round two".to_owned()),
    ]);
    command(&mut agent, &mut m, &mut r, "resume again", "/goal resume").await;
    then(&mut agent, &mut m, &mut r, "round streams", streaming).await;
    agent
        .send(json!({ "type": "steer", "message": "change course" }))
        .await;
    then(&mut agent, &mut m, &mut r, "steered", |line| {
        line["type"] == "queue_update"
    })
    .await;
    let response = agent
        .call(json!({ "type": "send_now", "queue": "steering", "index": 0,
            "message": "change course" }))
        .await;
    m.note(&mut r, "send_now", response);
    settle_events(&mut agent, &mut m, &mut r, "interrupted round").await;
    then(&mut agent, &mut m, &mut r, "next round streams", streaming).await;
    let response = agent.call(json!({ "type": "abort" })).await;
    m.note(&mut r, "abort the next round", response);
    then(&mut agent, &mut m, &mut r, "paused once more", |line| {
        notified(line, "Goal paused")
    })
    .await;
    m.turn(&mut r, "next round", &agent, Vec::new());
    m.session(&mut r, &agent);
    insta::assert_json_snapshot!("agent_goal_interrupted", r.into_value());
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_goal_restored() {
    let options = || goal_options(json!({ "features": { "goal": { "defaultMaxRounds": 1 } } }));
    let Some(mut first) = AgentRun::start(options()).await else {
        return;
    };
    // The process dies during round 1.
    first.push([ModelReply::Hang("Working".to_owned())]);
    first
        .send(json!({ "type": "prompt", "message": "/goal set Survive" }))
        .await;
    first.until(streaming).await;
    let written = std::fs::read_to_string(first.session_dir.join("session.jsonl")).unwrap();
    drop(first);
    // The first agent's temporary workspace differs per run.
    let mut session = String::new();
    for (index, line) in written.lines().enumerate() {
        let mut entry: Value = serde_json::from_str(line).unwrap();
        if index == 0 {
            entry["cwd"] = json!("/elsewhere");
        }
        session.push_str(&entry.to_string());
        session.push('\n');
    }
    // A damaged goal snapshot after the valid one is skipped.
    let last: Value = serde_json::from_str(session.lines().last().unwrap()).unwrap();
    session.push_str(
        &json!({ "type": "custom", "customType": "goal-state-v1", "data": { "id": 7 },
            "id": "0000000f", "parentId": last["id"], "timestamp": 1_700_000_000_000u64 })
        .to_string(),
    );
    session.push('\n');
    let mut restored = options();
    restored
        .files
        .push(("../session/session.jsonl".to_owned(), session));
    let Some(mut agent) = AgentRun::start(restored).await else {
        return;
    };
    let mut r = Recorder::new(&agent);
    let mut m = Masker::new();
    let id = agent.command(json!({ "type": "get_state" })).await;
    then(&mut agent, &mut m, &mut r, "startup", |line| {
        line["type"] == "response" && line["id"] == id.as_str()
    })
    .await;
    // A prompt does not continue a disarmed goal, but the model sees it.
    agent.push([ModelReply::Text("It is disarmed.".to_owned())]);
    turn(&mut agent, &mut m, &mut r, "a prompt", "Status?").await;
    // Resuming rearms it; it has used its one round.
    command(&mut agent, &mut m, &mut r, "resume", "/goal resume").await;
    then(&mut agent, &mut m, &mut r, "paused at the limit", |line| {
        notified(line, "Goal paused")
    })
    .await;
    command(&mut agent, &mut m, &mut r, "rounds 2", "/goal rounds 2").await;
    agent.push([ModelReply::Text("Round two.".to_owned())]);
    turn(&mut agent, &mut m, &mut r, "resume again", "/goal resume").await;
    then(
        &mut agent,
        &mut m,
        &mut r,
        "paused at the new limit",
        |line| notified(line, "Goal paused"),
    )
    .await;
    m.session(&mut r, &agent);
    insta::assert_json_snapshot!("agent_goal_restored", r.into_value());
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_goal_off() {
    for (name, options) in [
        (
            "disabled",
            goal_options(json!({ "features": { "goal": { "enabled": false } } })),
        ),
        (
            "unusable settings",
            goal_options(json!({ "features": { "goal": { "minBlockedRounds": 500,
                "defaultMaxRounds": 1 } } })),
        ),
    ] {
        let Some(mut agent) = AgentRun::start(options).await else {
            return;
        };
        let mut r = Recorder::new(&agent);
        let mut m = Masker::new();
        command(&mut agent, &mut m, &mut r, "show", "/goal").await;
        agent.push([
            tools(&[("d1", "ptc_docs", json!({ "names": ["create_goal"] }))]),
            ModelReply::Text("Hi.".to_owned()),
        ]);
        turn(&mut agent, &mut m, &mut r, "a prompt", "Hello").await;
        if name == "unusable settings" {
            agent.push([ModelReply::Hang("Working".to_owned())]);
        }
        command(&mut agent, &mut m, &mut r, "set", "/goal set Something").await;
        if name == "unusable settings" {
            // Defaults instead: no round limit.
            then(&mut agent, &mut m, &mut r, "the round streams", streaming).await;
            let response = agent.call(json!({ "type": "abort" })).await;
            m.note(&mut r, "abort", response);
            then(&mut agent, &mut m, &mut r, "paused", |line| {
                notified(line, "Goal paused")
            })
            .await;
        }
        if name == "chat with goals on" {
            settle(&mut agent, &mut m, &mut r, "round 1").await;
            then(&mut agent, &mut m, &mut r, "paused at the limit", |line| {
                notified(line, "Goal paused")
            })
            .await;
        }
        m.session(&mut r, &agent);
        insta::assert_json_snapshot!(
            format!("agent_goal_off_{}", name.replace(' ', "_")),
            r.into_value()
        );
    }
}

/// An unfinished todo is not nagged about while the goal goes on to
/// another round; the last round gets the reminder.
#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_goal_with_todo() {
    let Some(mut agent) = AgentRun::start(
        AgentOptions {
            config: json!({ "features": { "goal": { "defaultMaxRounds": 2 } } }),
            ..AgentOptions::default()
        }
        .features("todo,goal"),
    )
    .await
    else {
        return;
    };
    let mut r = Recorder::new(&agent);
    let mut m = Masker::new();
    command(&mut agent, &mut m, &mut r, "a todo", "/todo add step").await;
    agent.push([
        ModelReply::Text("Round one.".to_owned()),
        ModelReply::Text("Round two.".to_owned()),
        ModelReply::Text("Reminded.".to_owned()),
    ]);
    command(&mut agent, &mut m, &mut r, "set", "/goal set Todo").await;
    settle_events(&mut agent, &mut m, &mut r, "round 1").await;
    settle(&mut agent, &mut m, &mut r, "round 2").await;
    then(&mut agent, &mut m, &mut r, "paused at the limit", |line| {
        notified(line, "Goal paused")
    })
    .await;
    insta::assert_json_snapshot!("agent_goal_with_todo", r.into_value());
}
