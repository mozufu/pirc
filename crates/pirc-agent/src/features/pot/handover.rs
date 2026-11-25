//! `handover_propose`: the pot proposes handing its items to another pot or to
//! the user (Gateway operation `pot.handover.propose`); the user confirms.

use std::rc::Rc;

use serde_json::{Map, Value, json};

use crate::LocalBoxFuture;
use crate::channels::process_gateway;
use crate::tools::{Tool, ToolContext, ToolResult, ToolSpec, typed};

pub const PROPOSE_TOOL: &str = "handover_propose";

pub fn tool() -> Rc<dyn Tool> {
    Rc::new(ProposeTool::new())
}

struct ProposeTool {
    spec: ToolSpec,
}

fn describe(result: &Value) -> String {
    let items = result["handover"]["items"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    let stops: Vec<String> = items
        .iter()
        .filter(|item| item["fit"] == "stop")
        .map(|item| {
            format!(
                "{} ({})",
                item["label"].as_str().unwrap_or("?"),
                item["reason"].as_str().unwrap_or("cannot continue there")
            )
        })
        .collect();
    let mut text = format!(
        "Handover of {} items proposed; the user decides. Keep working on them until it is applied.",
        items.len()
    );
    if !stops.is_empty() {
        text.push_str(&format!(
            "\n\nThese would not continue: {}.",
            stops.join("; ")
        ));
    }
    text
}

impl ProposeTool {
    fn new() -> Self {
        Self {
            spec: ToolSpec::new(
                PROPOSE_TOOL,
                json!({
                    "type": "object",
                    "properties": {
                        "toPotId": { "type": "string", "description": "The pot to hand over to; omit for the user" },
                        "items": {
                            "type": "array",
                            "description": "What to hand over; omit for everything you hold",
                            "items": {
                                "type": "object",
                                "properties": {
                                    "kind": { "type": "string", "enum": ["responsibility", "reminder", "work", "group_host"] },
                                    "ref": { "type": "string" },
                                },
                                "required": ["kind", "ref"],
                                "additionalProperties": false,
                            },
                        },
                        "reason": { "type": "string", "description": "Why, for the user" },
                    },
                    "additionalProperties": false,
                }),
                None,
            ),
        }
    }

    async fn run(&self, args: Map<String, Value>, ctx: ToolContext) -> Result<ToolResult, String> {
        let gateway = process_gateway().ok_or("this pot has no Gateway connection")?;
        match gateway
            .gateway
            .request("pot.handover.propose", args, Some(&ctx.signal))
            .await
        {
            Ok(result) => Ok(typed(describe(&result), result, None, false)),
            Err(error) => Ok(ToolResult::error(error.message().to_owned())),
        }
    }
}

impl Tool for ProposeTool {
    fn name(&self) -> &str {
        self.spec.name
    }
    fn description(&self) -> &str {
        &self.spec.description
    }
    fn parameters(&self) -> &Map<String, Value> {
        &self.spec.parameters
    }
    fn result_schema(&self) -> Option<&Value> {
        self.spec.result_schema.as_ref()
    }
    fn execute<'a>(
        &'a self,
        args: Map<String, Value>,
        ctx: ToolContext,
    ) -> LocalBoxFuture<'a, Result<ToolResult, String>> {
        Box::pin(async move { self.run(args, ctx).await })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_proposal_names_what_would_not_continue() {
        let text = describe(&json!({ "handover": { "items": [
            { "label": "Nightly tests", "fit": "ok" },
            { "label": "Fix CI", "fit": "stop", "reason": "Helper may not work there" },
        ] } }));
        assert!(text.starts_with("Handover of 2 items proposed"), "{text}");
        assert!(
            text.ends_with("These would not continue: Fix CI (Helper may not work there)."),
            "{text}"
        );
    }
}
