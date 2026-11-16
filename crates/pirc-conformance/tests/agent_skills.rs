//! Agent Skills (`agent/features/skills.ts`, feature `skills`), with the
//! test playing the agent's node: discovery from `~/.agents/skills`, the
//! node's config directory and the workspace (with their precedence and a
//! skipped invalid skill), the system-prompt list, reading a skill's files
//! and the protection of them, `/skill` and `/skill:<name>`, rescanning,
//! and the switch that turns skills off. The historical feature baseline
//! (docs/development/historical-records.md).

use pirc_conformance::{AgentOptions, AgentRun, ModelReply, Recorder};
use serde_json::{Value, json};

fn skill(dir: &str, front_matter: &str, body: &str) -> (String, String) {
    (
        format!("{dir}/SKILL.md"),
        format!("---\n{front_matter}\n---\n\n{body}\n"),
    )
}

/// The node's skills (config directory), the workspace's, and the
/// cross-tool personal ones in `~/.agents/skills`.
fn files() -> Vec<(String, String)> {
    vec![
        ("README.md".to_owned(), "conformance\n".to_owned()),
        skill(
            "../config/skills/moodle-cli",
            "name: moodle-cli\ndescription: Read Moodle units, deadlines & <grades>.",
            "Run `moodle due`. See [reference](references/commands.md).",
        ),
        (
            "../config/skills/moodle-cli/references/commands.md".to_owned(),
            "moodle grades".to_owned(),
        ),
        skill(
            "../config/skills/pdf",
            "name: pdf\ndescription: Global PDF skill.",
            "Do the thing.",
        ),
        skill(
            "../config/skills/broken",
            "name: Broken Name\ndescription: x",
            "Do the thing.",
        ),
        skill(
            ".pirc/skills/pdf",
            "name: pdf\ndescription: >\n  Extract text from PDFs,\n  fill forms and OCR scans.",
            "Use pdftotext -layout.",
        ),
        skill(
            "../home/.agents/skills/pdf",
            "name: pdf\ndescription: Personal PDF skill, should lose to node and workspace.",
            "Do the thing.",
        ),
        skill(
            "../home/.agents/skills/gif-search",
            "name: gif-search\ndescription: Search and send a GIF.",
            "Find a GIF.",
        ),
    ]
}

fn tools(calls: &[(&str, &str, Value)]) -> ModelReply {
    ModelReply::Tools(
        calls
            .iter()
            .map(|(id, name, args)| ((*id).to_owned(), (*name).to_owned(), args.clone()))
            .collect(),
    )
}

/// Lines up to the response of `command`, startup notifications included.
async fn command(agent: &mut AgentRun, command: Value) -> Vec<Value> {
    let id = agent.command(command).await;
    agent
        .until(|line| line["type"] == "response" && line["id"] == id.as_str())
        .await
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

/// A slash command that answers with a notification and no run.
async fn notice(agent: &mut AgentRun, r: &mut Recorder, step: &str, message: &str) {
    let id = agent
        .command(json!({ "type": "prompt", "message": message }))
        .await;
    let mut lines = agent
        .until(|line| line["type"] == "response" && line["id"] == id.as_str())
        .await;
    if !lines
        .iter()
        .any(|line| line["type"] == "extension_ui_request")
    {
        lines.extend(
            agent
                .until(|line| line["type"] == "extension_ui_request")
                .await,
        );
    }
    r.note(step, json!(lines));
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_skills() {
    let Some(mut agent) = AgentRun::start(
        AgentOptions {
            files: files(),
            ..AgentOptions::default()
        }
        .features("skills"),
    )
    .await
    else {
        return;
    };
    let mut r = Recorder::new(&agent);
    let startup = command(&mut agent, json!({ "type": "get_commands" })).await;
    r.note("startup and commands", json!(startup));
    let config = agent.config_dir.display().to_string();
    agent.push([
        tools(&[
            (
                "r1",
                "read",
                json!({ "path": format!("{config}/skills/moodle-cli/references/commands.md") }),
            ),
            (
                "w1",
                "write",
                json!({ "path": format!("{config}/skills/moodle-cli/SKILL.md"),
                    "content": "x" }),
            ),
        ]),
        ModelReply::Text("Nothing is due.".to_owned()),
    ]);
    turn(&mut agent, &mut r, "skills in the prompt", "what is due?").await;
    notice(&mut agent, &mut r, "list skills", "/skill").await;
    notice(&mut agent, &mut r, "an unknown skill", "/skill nope").await;
    agent.push([ModelReply::Text("Extracted.".to_owned())]);
    turn(
        &mut agent,
        &mut r,
        "load a skill",
        "/skill:pdf read notes.pdf",
    )
    .await;
    agent.push([ModelReply::Text("Found one.".to_owned())]);
    turn(
        &mut agent,
        &mut r,
        "load a skill without a request",
        "/skill:gif-search",
    )
    .await;
    agent.push([ModelReply::Text("Due Friday.".to_owned())]);
    turn(
        &mut agent,
        &mut r,
        "load a skill by /skill <name>",
        "/skill moodle-cli   what is due?",
    )
    .await;
    // A skill installed while the agent runs is listed without a restart.
    let added = agent.workspace.join(".pirc/skills/new-one/SKILL.md");
    std::fs::create_dir_all(added.parent().unwrap()).unwrap();
    std::fs::write(
        &added,
        "---\nname: new-one\ndescription: Installed later.\n---\nNew.\n",
    )
    .unwrap();
    let commands = agent.call(json!({ "type": "get_commands" })).await;
    r.note("commands after installing one", commands);
    agent.push([ModelReply::Text("Seen.".to_owned())]);
    turn(&mut agent, &mut r, "rescanned", "anything new?").await;
    r.session(&agent);
    insta::assert_json_snapshot!("agent_skills", r.into_value());
}

#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]
#[tokio::test(flavor = "multi_thread")]
async fn agent_skills_disabled() {
    let Some(mut agent) = AgentRun::start(
        AgentOptions {
            files: files(),
            config: json!({ "features": { "skills": { "enabled": false } } }),
            ..AgentOptions::default()
        }
        .features("skills"),
    )
    .await
    else {
        return;
    };
    let mut r = Recorder::new(&agent);
    let startup = command(&mut agent, json!({ "type": "get_commands" })).await;
    r.note("startup and commands", json!(startup));
    agent.push([ModelReply::Text("Hi.".to_owned())]);
    turn(&mut agent, &mut r, "no skills in the prompt", "hello").await;
    // Not a command any more: the text goes to the model.
    agent.push([ModelReply::Text("No such thing.".to_owned())]);
    turn(&mut agent, &mut r, "/skill reaches the model", "/skill").await;
    insta::assert_json_snapshot!("agent_skills_disabled", r.into_value());
}
