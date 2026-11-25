//! `memory_note` and `memory_search` in a pot's session: the pot's own memory
//! (Gateway operations `pot.memory.*`), never another pot's or the user's.

use std::rc::Rc;

use serde_json::{Map, Value, json};

use crate::LocalBoxFuture;
use crate::channels::process_gateway;
use crate::tools::{Tool, ToolContext, ToolResult, ToolSpec, typed};

pub const NOTE_TOOL: &str = "memory_note";
pub const SEARCH_TOOL: &str = "memory_search";

const NOTE_DESCRIPTION: &str = "Keep a note in your own memory as this pot. Your next runs start with every note; this run keeps the notes it started with. Note what will matter later for your responsibilities: decisions and why, ongoing work, lessons learned, what the user told you. One fact per note, as one self-contained line; say so when something is a guess. Update a note when it changes (with its id and the revision you saw) and remove it when it is wrong or done. Never store secrets. Your memory is yours alone: other pots cannot read it, and you cannot read theirs.";

const SEARCH_DESCRIPTION: &str = "Search your own memory: notes holding more of the words come first; each word matches anywhere, ignoring case. Use it when your prompt's notes are not enough, for example after updates in this run.";

pub fn tools() -> Vec<Rc<dyn Tool>> {
    vec![Rc::new(MemoryTool::note()), Rc::new(MemoryTool::search())]
}

struct MemoryTool {
    spec: ToolSpec,
    operation: &'static str,
    describe: fn(&Value) -> String,
}

fn describe_note(result: &Value) -> String {
    let used = result["used"].as_u64().unwrap_or(0);
    let budget = result["budget"].as_u64().unwrap_or(0);
    if result["removed"] == true {
        return format!("Removed. Memory used: {used} of {budget} characters.");
    }
    format!(
        "Saved as {} (revision {}). Memory used: {used} of {budget} characters.",
        result["note"]["id"].as_str().unwrap_or("?"),
        result["note"]["revision"]
    )
}

fn describe_search(result: &Value) -> String {
    let hits = result["hits"].as_array().cloned().unwrap_or_default();
    if hits.is_empty() {
        return "No note matches.".to_owned();
    }
    hits.iter()
        .map(|note| {
            format!(
                "[{} r{}] {}",
                note["id"].as_str().unwrap_or("?"),
                note["revision"],
                note["content"].as_str().unwrap_or("")
            )
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn spec(name: &'static str, description: &str, parameters: Value) -> ToolSpec {
    ToolSpec {
        name,
        description: description.to_owned(),
        parameters: parameters.as_object().expect("object schema").clone(),
        result_schema: None,
    }
}

impl MemoryTool {
    fn note() -> Self {
        Self {
            spec: spec(
                NOTE_TOOL,
                NOTE_DESCRIPTION,
                json!({
                    "type": "object",
                    "properties": {
                        "action": { "type": "string", "enum": ["add", "update", "remove"] },
                        "id": { "type": "string", "description": "The note to update or remove" },
                        "content": { "type": "string", "description": "The note, for add and update" },
                        "baseRevision": { "type": "integer", "description": "The revision you saw, for update and remove" },
                    },
                    "required": ["action"],
                    "additionalProperties": false,
                }),
            ),
            operation: "pot.memory.note",
            describe: describe_note,
        }
    }

    fn search() -> Self {
        Self {
            spec: spec(
                SEARCH_TOOL,
                SEARCH_DESCRIPTION,
                json!({
                    "type": "object",
                    "properties": {
                        "query": { "type": "string" },
                        "limit": { "type": "integer", "minimum": 1, "maximum": 20 },
                    },
                    "required": ["query"],
                    "additionalProperties": false,
                }),
            ),
            operation: "pot.memory.search",
            describe: describe_search,
        }
    }

    async fn run(&self, args: Map<String, Value>, ctx: ToolContext) -> Result<ToolResult, String> {
        let gateway = process_gateway().ok_or("this pot has no Gateway connection")?;
        match gateway
            .gateway
            .request(self.operation, args, Some(&ctx.signal))
            .await
        {
            Ok(result) => Ok(typed((self.describe)(&result), result, None, false)),
            Err(error) => Ok(ToolResult::error(error.message().to_owned())),
        }
    }
}

impl Tool for MemoryTool {
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
    fn results_show_ids_revisions_and_the_budget() {
        let saved = describe_note(
            &json!({ "note": { "id": "mem_1", "revision": 2 }, "used": 120, "budget": 20000 }),
        );
        assert_eq!(
            saved,
            "Saved as mem_1 (revision 2). Memory used: 120 of 20000 characters."
        );
        let found = describe_search(
            &json!({ "hits": [{ "id": "mem_1", "revision": 2, "content": "CI runs at 2am" }] }),
        );
        assert_eq!(found, "[mem_1 r2] CI runs at 2am");
        assert_eq!(describe_search(&json!({ "hits": [] })), "No note matches.");
    }
}
