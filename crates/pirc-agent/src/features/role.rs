//! `role` (`agent/features/role.ts`): the role an agent runs in
//! (`roles.rs`) puts its instructions into the system prompt. Teammates and
//! subagents get the role from their parent; delivered sessions from the
//! gateway (`Agent::set_role`).

use std::rc::Rc;

use crate::LocalBoxFuture;
use crate::agent::Agent;
use crate::feature::{BeforeStart, Feature, PromptAddition};
use crate::roles::render_role;

/// `roleFeature()`.
pub fn feature() -> Rc<dyn Feature> {
    Rc::new(RoleFeature)
}

struct RoleFeature;

impl Feature for RoleFeature {
    fn name(&self) -> &'static str {
        "role"
    }

    fn before_agent_start<'a>(
        &'a self,
        agent: &'a Rc<Agent>,
    ) -> LocalBoxFuture<'a, Result<Option<BeforeStart>, String>> {
        Box::pin(async move {
            let section = agent.role().map(|role| render_role(&role));
            Ok(section
                .filter(|section| !section.is_empty())
                .map(|section| BeforeStart {
                    system_prompt: Some(PromptAddition::Text(section)),
                    messages: Vec::new(),
                }))
        })
    }
}
