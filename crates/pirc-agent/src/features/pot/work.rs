//! `work_open`, `work_send`, `work_status`: the pot opens work in its work
//! locations and coordinates it (Gateway operations `pot.work.*`).

use std::rc::Rc;

use serde_json::{Map, Value, json};

use crate::LocalBoxFuture;
use crate::channels::process_gateway;
use crate::tools::{Tool, ToolContext, ToolResult, ToolSpec, typed};

pub const OPEN_TOOL: &str = "work_open";
pub const SEND_TOOL: &str = "work_send";
pub const STATUS_TOOL: &str = "work_status";

pub fn tools() -> Vec<Rc<dyn Tool>> {
    vec![
        Rc::new(WorkTool::open()),
        Rc::new(WorkTool::send()),
        Rc::new(WorkTool::status()),
    ]
}

struct WorkTool {
    spec: ToolSpec,
    operation: &'static str,
    describe: fn(&Value) -> String,
}

fn string(description: &str) -> Value {
    json!({ "type": "string", "description": description })
}

fn describe_open(result: &Value) -> String {
    if result["state"] == "awaiting_approval" {
        return format!(
            "That model needs the user's approval; approval {} is waiting. You are woken with the answer: if it is \"allow once\", call work_open again with the same arguments and approvalId.",
            result["approvalId"].as_str().unwrap_or("?")
        );
    }
    let session = result["work"]["sessionId"].as_str().unwrap_or("?");
    match result["instruction"]["delivery"].as_str() {
        Some("delivered") => {
            format!("Work started in session {session}; your instruction was delivered.")
        }
        Some("uncertain") => format!(
            "Work started in session {session}, but whether your instruction arrived is unknown. Check work_status before sending it again."
        ),
        _ => format!(
            "Work started in session {session}, but your instruction was not delivered: {}. Send it with work_send.",
            result["instruction"]["error"]
                .as_str()
                .unwrap_or("unknown reason")
        ),
    }
}

fn describe_send(result: &Value) -> String {
    match result["delivery"].as_str() {
        Some("delivered") => "Delivered.".to_owned(),
        _ => "Whether it arrived is unknown. Check work_status before sending it again.".to_owned(),
    }
}

fn describe_status(result: &Value) -> String {
    let title = result["work"]["title"].as_str().unwrap_or("the work");
    let taken = if result["work"]["state"] == "taken_over" {
        " The user took it over: do not send into it."
    } else {
        ""
    };
    let run = match result["run"].as_str() {
        Some("over") => format!(
            "finished ({}).\n\n{}",
            result["status"].as_str().unwrap_or("?"),
            result["answer"].as_str().unwrap_or("")
        ),
        Some("working") => "working.".to_owned(),
        Some("queued") => "your last instruction is queued.".to_owned(),
        Some("waiting_for_user") => "waiting for the user.".to_owned(),
        Some("dropped") => "it stopped before taking your last instruction.".to_owned(),
        _ => "unknown for now.".to_owned(),
    };
    format!("\"{title}\" is {run}{taken}")
}

impl WorkTool {
    fn open() -> Self {
        Self {
            spec: ToolSpec::new(
                OPEN_TOOL,
                json!({
                    "type": "object",
                    "properties": {
                        "workspaceId": string("One of your work locations"),
                        "title": string("A short name for the work"),
                        "instruction": string("What the work session should do"),
                        "provider": string("A work model's provider (with model); omit both for your first direct model"),
                        "model": string("A work model (with provider)"),
                        "thinking": { "type": "string", "enum": ["off", "minimal", "low", "medium", "high", "xhigh"] },
                        "approvalId": string("The user's allow-once approval for this start"),
                        "reason": string("Why this model, shown when it needs approval"),
                        "estimateMicros": { "type": "integer", "minimum": 0, "description": "Your cost estimate in micro-USD" },
                    },
                    "required": ["workspaceId", "title", "instruction"],
                    "additionalProperties": false,
                }),
                None,
            ),
            operation: "pot.work.open",
            describe: describe_open,
        }
    }

    fn send() -> Self {
        Self {
            spec: ToolSpec::new(
                SEND_TOOL,
                json!({
                    "type": "object",
                    "properties": {
                        "sessionId": string("A work session you opened"),
                        "instruction": string("The next instruction"),
                    },
                    "required": ["sessionId", "instruction"],
                    "additionalProperties": false,
                }),
                None,
            ),
            operation: "pot.work.send",
            describe: describe_send,
        }
    }

    fn status() -> Self {
        Self {
            spec: ToolSpec::new(
                STATUS_TOOL,
                json!({
                    "type": "object",
                    "properties": { "sessionId": string("A work session you opened") },
                    "required": ["sessionId"],
                    "additionalProperties": false,
                }),
                None,
            ),
            operation: "pot.work.status",
            describe: describe_status,
        }
    }

    async fn run(&self, args: Map<String, Value>, ctx: ToolContext) -> Result<ToolResult, String> {
        let gateway = process_gateway().ok_or("this pot has no Gateway connection")?;
        let answer = gateway
            .gateway
            .request(self.operation, args, Some(&ctx.signal))
            .await;
        match answer {
            Ok(result) => Ok(typed((self.describe)(&result), result, None, false)),
            Err(error) => Ok(ToolResult::error(error.message().to_owned())),
        }
    }
}

impl Tool for WorkTool {
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
    fn results_read_as_what_the_pot_should_do_next() {
        let waiting =
            describe_open(&json!({ "state": "awaiting_approval", "approvalId": "appr_1" }));
        assert!(
            waiting.contains("appr_1") && waiting.contains("approvalId"),
            "{waiting}"
        );
        let unsure = describe_open(&json!({ "state": "started", "work": { "sessionId": "s1" },
            "instruction": { "delivery": "uncertain" } }));
        assert!(
            unsure.contains("Check work_status before sending it again"),
            "{unsure}"
        );
        assert_eq!(
            describe_send(&json!({ "delivery": "delivered" })),
            "Delivered."
        );
        let done = describe_status(
            &json!({ "work": { "title": "Fix CI", "state": "taken_over" },
            "run": "over", "status": "succeeded", "answer": "All green." }),
        );
        assert_eq!(
            done,
            "\"Fix CI\" is finished (succeeded).\n\nAll green. The user took it over: do not send into it."
        );
    }
}
