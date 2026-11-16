//! Instructions features add to the system prompt, with the test playing
//! the agent's node: a chat project's instructions
//! (`agent/features/project-instructions.ts`), frozen in the session when
//! the chat starts and left out of other workspaces, and the role an agent
//! runs in (`agent/features/role.ts`), from the configure line or
//! `set_role`. The historical feature baseline (docs/development/historical-records.md).

use pirc_conformance::{AgentOptions, AgentRun, ModelReply, Recorder};
use serde_json::{Value, json};

fn chat(instructions: Option<&str>) -> AgentOptions {
    let mut options = AgentOptions::default();
    options.env.push((
        "PIRC_MODE".to_owned(),
        serde_json::to_string(&pirc_protocol::mode::default_chat()).unwrap(),
    ));
    if let Some(text) = instructions {
        options.configure = json!({ "instructions": text });
    }
    options.features("project-instructions")
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

/// The prompt sections of the latest context snapshot, without their
/// text (the requests show it).
async fn sections(agent: &mut AgentRun, r: &mut Recorder, step: &str) {
    let context = agent.call(json!({ "type": "get_context" })).await;
    let mut sections = context["data"]["sections"].clone();
    for section in sections.as_array_mut().into_iter().flatten() {
        if let Some(section) = section.as_object_mut() {
            section.remove("text");
        }
    }
    r.note(step, sections);
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_project_instructions() {
    let options = |text: &str| chat(Some(text));
    let Some(mut agent) = AgentRun::start(options("  Always answer in French.\n")).await else {
        return;
    };
    let mut r = Recorder::new(&agent);
    agent.push([ModelReply::Text("Bonjour.".to_owned())]);
    turn(&mut agent, &mut r, "first run", "hi").await;
    sections(&mut agent, &mut r, "prompt sections").await;
    agent.push([ModelReply::Text("Encore.".to_owned())]);
    turn(&mut agent, &mut r, "second run", "more").await;
    // The user edited them since: this chat keeps what it started with.
    let Some(mut agent) = agent.restart(options("Always answer in German.")).await else {
        return;
    };
    agent.push([ModelReply::Text("Toujours.".to_owned())]);
    turn(&mut agent, &mut r, "after a restart", "and now?").await;
    r.session(&agent);
    insta::assert_json_snapshot!("agent_project_instructions", r.into_value());
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_project_instructions_added_later() {
    // A chat that started without instructions keeps starting without them.
    let Some(mut agent) = AgentRun::start(chat(None)).await else {
        return;
    };
    let mut r = Recorder::new(&agent);
    agent.push([ModelReply::Text("Hi.".to_owned())]);
    turn(&mut agent, &mut r, "first run", "hi").await;
    let Some(mut agent) = agent.restart(chat(Some("Added later."))).await else {
        return;
    };
    agent.push([ModelReply::Text("Still plain.".to_owned())]);
    turn(&mut agent, &mut r, "after a restart", "more").await;
    r.session(&agent);
    insta::assert_json_snapshot!("agent_project_instructions_added_later", r.into_value());
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_project_instructions_older_chat() {
    // A chat that began before instructions existed: messages, no snapshot.
    let session = [
        json!({ "type": "session", "version": 1, "sessionId": "0123456789abcdef",
            "cwd": "/elsewhere", "id": "a0000001", "parentId": null, "timestamp": 1000 }),
        json!({ "type": "message", "message": { "role": "user", "content": "Old question",
            "timestamp": 1001 }, "id": "a0000002", "parentId": "a0000001", "timestamp": 1001 }),
    ]
    .iter()
    .map(Value::to_string)
    .collect::<Vec<_>>()
    .join("\n");
    let mut options = chat(Some("Too late."));
    options.files.push((
        "../session/session.jsonl".to_owned(),
        format!("{session}\n"),
    ));
    let Some(mut agent) = AgentRun::start(options).await else {
        return;
    };
    let mut r = Recorder::new(&agent);
    agent.push([ModelReply::Text("Plain.".to_owned())]);
    turn(&mut agent, &mut r, "first run", "hi").await;
    r.session(&agent);
    insta::assert_json_snapshot!("agent_project_instructions_older_chat", r.into_value());
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_project_instructions_outside_chat() {
    let Some(mut agent) = AgentRun::start(
        AgentOptions {
            configure: json!({ "instructions": "Chat only." }),
            ..AgentOptions::default()
        }
        .features("project-instructions"),
    )
    .await
    else {
        return;
    };
    let mut r = Recorder::new(&agent);
    agent.push([ModelReply::Text("Hi.".to_owned())]);
    turn(&mut agent, &mut r, "first run", "hi").await;
    r.session(&agent);
    insta::assert_json_snapshot!("agent_project_instructions_outside_chat", r.into_value());
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_role_from_configure() {
    let Some(mut agent) = AgentRun::start(
        AgentOptions {
            configure: json!({ "role": { "name": "reviewer",
                "instructions": "Review only; never edit files." } }),
            ..AgentOptions::default()
        }
        .features("role"),
    )
    .await
    else {
        return;
    };
    let mut r = Recorder::new(&agent);
    agent.push([ModelReply::Text("Reviewed.".to_owned())]);
    turn(&mut agent, &mut r, "first run", "review the change").await;
    sections(&mut agent, &mut r, "prompt sections").await;
    insta::assert_json_snapshot!("agent_role_from_configure", r.into_value());
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_role_without_instructions() {
    let Some(mut agent) = AgentRun::start(
        AgentOptions {
            configure: json!({ "role": { "name": "plain" } }),
            ..AgentOptions::default()
        }
        .features("role"),
    )
    .await
    else {
        return;
    };
    let mut r = Recorder::new(&agent);
    agent.push([ModelReply::Text("Done.".to_owned())]);
    turn(&mut agent, &mut r, "first run", "do it").await;
    insta::assert_json_snapshot!("agent_role_without_instructions", r.into_value());
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_role_set_and_resumed() {
    let options = || {
        AgentOptions {
            files: vec![
                ("README.md".to_owned(), "conformance\n".to_owned()),
                (
                    ".pirc/roles/writer.md".to_owned(),
                    "---\ndescription: Writes docs\n---\nWrite clearly, in short sentences.\n"
                        .to_owned(),
                ),
            ],
            ..AgentOptions::default()
        }
        .features("role")
    };
    let Some(mut agent) = AgentRun::start(options()).await else {
        return;
    };
    let mut r = Recorder::new(&agent);
    let set = agent
        .call(json!({ "type": "set_role", "role": "writer" }))
        .await;
    r.note("set the role", set);
    agent.push([ModelReply::Text("Written.".to_owned())]);
    turn(&mut agent, &mut r, "first run", "write the docs").await;
    // The session keeps its role in a new process.
    let Some(mut agent) = agent.restart(options()).await else {
        return;
    };
    agent.push([ModelReply::Text("More.".to_owned())]);
    turn(&mut agent, &mut r, "after a restart", "more docs").await;
    r.session(&agent);
    insta::assert_json_snapshot!("agent_role_set_and_resumed", r.into_value());
}
