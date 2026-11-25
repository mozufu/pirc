//! `message_send`: the pot sends a message to another pot or into a thread it
//! belongs to (Gateway operation `pot.message.send`).

use std::rc::Rc;

use serde_json::{Map, Value, json};

use crate::LocalBoxFuture;
use crate::channels::process_gateway;
use crate::tools::{Tool, ToolContext, ToolResult, ToolSpec, typed};

pub fn tool() -> Rc<dyn Tool> {
    Rc::new(SendTool::new())
}

pub const SEND_TOOL: &str = "message_send";

struct SendTool {
    spec: ToolSpec,
}

impl SendTool {
    fn new() -> Self {
        let string = |description: &str| json!({ "type": "string", "description": description });
        Self {
            spec: ToolSpec::new(
                SEND_TOOL,
                json!({
                    "type": "object",
                    "properties": {
                        "toPot": string("Another pot's ID, for a direct message"),
                        "threadId": string("A thread you belong to"),
                        "body": string("The message"),
                        "mentions": { "type": "array", "items": { "type": "string" },
                                      "description": "In a group: pot IDs to wake" },
                    },
                    "required": ["body"],
                    "additionalProperties": false,
                }),
                None,
            ),
        }
    }

    async fn run(&self, args: Map<String, Value>, ctx: ToolContext) -> Result<ToolResult, String> {
        if args.contains_key("toPot") == args.contains_key("threadId") {
            return Ok(ToolResult::error("Give exactly one of toPot or threadId"));
        }
        let gateway = process_gateway().ok_or("this pot has no Gateway connection")?;
        let sent = gateway
            .gateway
            .request("pot.message.send", args, Some(&ctx.signal))
            .await;
        let result = match sent {
            Ok(result) => result,
            Err(error) => return Ok(ToolResult::error(error.message().to_owned())),
        };
        let woken = result["woken"].as_array().map_or(0, Vec::len);
        let text = match woken {
            0 => "Sent. Nobody was woken by it.".to_owned(),
            1 => "Sent; it woke 1 pot.".to_owned(),
            n => format!("Sent; it woke {n} pots."),
        };
        let data = json!({
            "messageId": result["message"]["id"],
            "threadId": result["message"]["threadId"],
            "woken": result["woken"],
        });
        Ok(typed(text, data, None, false))
    }
}

impl Tool for SendTool {
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
