//! `pot`: a pot's own session (mode `pot: true`) asks the Gateway who it is
//! (`pot.context`) before each run and puts that into its system prompt. The
//! Gateway decides which pot the session belongs to; the agent never names
//! one. Personality and work description are text for the model; permissions
//! are enforced by the Gateway and the Node, the summary only informs.

use std::rc::Rc;
use std::time::Duration;

use serde_json::{Map, Value};

use crate::LocalBoxFuture;
use crate::agent::Agent;
use crate::channels::process_gateway;
use crate::context::PromptSection;
use crate::feature::{BeforeStart, Feature, PromptAddition};
use crate::signal::{AbortController, AbortSignal};
use crate::tools::Tool;

/// How long a run waits for the pot's identity before it fails to start.
const CONTEXT_TIMEOUT: Duration = Duration::from_secs(15);

mod send;

pub struct PotFeature;

pub fn feature() -> Rc<dyn Feature> {
    Rc::new(PotFeature)
}

fn text(value: &Value, key: &str) -> String {
    value[key].as_str().unwrap_or_default().trim().to_owned()
}

/// The prompt section built from a `pot.context` answer.
pub fn identity_section(context: &Value) -> Result<PromptSection, String> {
    let pot = &context["pot"];
    let name = text(pot, "name");
    if name.is_empty() {
        return Err("the Gateway answered without a pot".into());
    }
    let mut out = format!("You are {name}, one of the user's pots.");
    let personality = text(pot, "personality");
    if !personality.is_empty() {
        out.push_str(&format!("\n\n## Personality\n\n{personality}"));
    }
    let intro = text(pot, "intro");
    let description = text(pot, "workDescription");
    let responsibilities: Vec<String> = pot["responsibilities"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|r| {
            let title = text(r, "title");
            (!title.is_empty()).then(|| match text(r, "detail") {
                detail if detail.is_empty() => format!("- {title}"),
                detail => format!("- {title}: {detail}"),
            })
        })
        .collect();
    if !intro.is_empty() || !description.is_empty() || !responsibilities.is_empty() {
        out.push_str("\n\n## Your work");
        for part in [intro, description] {
            if !part.is_empty() {
                out.push_str(&format!("\n\n{part}"));
            }
        }
        if !responsibilities.is_empty() {
            out.push_str(&format!(
                "\n\nYou are responsible for:\n{}",
                responsibilities.join("\n")
            ));
        }
    }
    let permissions = text(pot, "permissions");
    if !permissions.is_empty() {
        out.push_str(&format!("\n\n## What you may do\n\n{permissions}"));
    }
    let user = text(&context["user"], "name");
    if !user.is_empty() {
        out.push_str(&format!("\n\nThe user is {user}."));
    }
    Ok(PromptSection::new(
        "pot:identity",
        "Pot identity",
        "gateway:pot.context",
        out,
    ))
}

async fn load(signal: &AbortSignal) -> Result<PromptSection, String> {
    let gateway = process_gateway().ok_or("this pot has no Gateway connection")?;
    let timeout = AbortController::child_of(signal);
    let timer = {
        let timeout = timeout.clone();
        tokio::task::spawn_local(async move {
            tokio::time::sleep(CONTEXT_TIMEOUT).await;
            timeout.abort();
        })
    };
    let answer = gateway
        .gateway
        .request("pot.context", Map::new(), Some(&timeout.signal()))
        .await;
    timer.abort();
    let context = answer.map_err(|error| error.message().to_owned())?;
    identity_section(&context)
}

/// Every tool a pot session registers, for the mode tool registry test.
#[cfg(test)]
pub(crate) fn registered_tool_names() -> Vec<String> {
    vec![send::SEND_TOOL.to_owned()]
}

impl Feature for PotFeature {
    fn name(&self) -> &'static str {
        "pot"
    }

    fn tools(&self, agent: &Rc<Agent>) -> Vec<Rc<dyn Tool>> {
        if process_gateway().is_some() && agent.config().mode().pot {
            vec![send::tool()]
        } else {
            Vec::new()
        }
    }

    fn before_agent_start<'a>(
        &'a self,
        agent: &'a Rc<Agent>,
    ) -> LocalBoxFuture<'a, Result<Option<BeforeStart>, String>> {
        Box::pin(async move {
            let signal = AbortSignal::never();
            self.before_model_start(agent, &signal).await
        })
    }

    fn before_model_start<'a>(
        &'a self,
        agent: &'a Rc<Agent>,
        signal: &'a AbortSignal,
    ) -> LocalBoxFuture<'a, Result<Option<BeforeStart>, String>> {
        Box::pin(async move {
            if !agent.config().mode().pot {
                return Ok(None);
            }
            let section = load(signal)
                .await
                .map_err(|error| format!("Your pot identity could not be loaded: {error}"))?;
            Ok(Some(BeforeStart {
                system_prompt: Some(PromptAddition::Sections(vec![section])),
                messages: Vec::new(),
            }))
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn the_identity_section_names_the_pot_its_work_and_permissions() {
        let section = identity_section(&json!({
            "pot": { "id": "pot_1", "name": "Tester", "personality": "Calm.",
                     "intro": "Tests things", "workDescription": "Runs nightly checks.",
                     "responsibilities": [{ "title": "Nightly" }, { "title": "Flaky", "detail": "Track them" }],
                     "permissions": "You may only answer when addressed." },
            "user": { "name": "alice" }
        }))
        .unwrap();
        assert_eq!(section.id, "pot:identity");
        assert!(
            section
                .text
                .starts_with("You are Tester, one of the user's pots.")
        );
        assert!(section.text.contains("## Personality\n\nCalm."));
        assert!(section.text.contains("- Nightly\n- Flaky: Track them"));
        assert!(
            section
                .text
                .contains("## What you may do\n\nYou may only answer when addressed.")
        );
        assert!(section.text.ends_with("The user is alice."));
        // A minimal pot has only its name.
        let bare = identity_section(&json!({ "pot": { "name": "Bare" } })).unwrap();
        assert_eq!(bare.text, "You are Bare, one of the user's pots.");
        assert!(identity_section(&json!({})).is_err());
    }
}
