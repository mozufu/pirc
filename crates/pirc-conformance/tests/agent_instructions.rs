//! The role an agent runs in (`agent/features/role.ts`), from the configure
//! line or `set_role`, with the test playing the agent's node.

use pirc_conformance::{AgentOptions, AgentRun, ModelReply, Recorder};
use serde_json::json;

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
