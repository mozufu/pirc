//! `observe_note` and `observe_read`: the pot records what it notices about an
//! observed event and reads the observed session (Gateway operations
//! `pot.observe.*`).

use std::rc::Rc;

use serde_json::{Map, Value, json};

use crate::LocalBoxFuture;
use crate::channels::process_gateway;
use crate::tools::{Tool, ToolContext, ToolResult, ToolSpec, typed};

pub const NOTE_TOOL: &str = "observe_note";
pub const READ_TOOL: &str = "observe_read";

pub fn tools() -> Vec<Rc<dyn Tool>> {
    vec![Rc::new(ObserveTool::note()), Rc::new(ObserveTool::read())]
}

struct ObserveTool {
    spec: ToolSpec,
    operation: &'static str,
    describe: fn(&Value) -> String,
}

fn event_id() -> Value {
    json!({ "type": "string", "description": "The eventId from the event you were woken for" })
}

fn describe_note(_: &Value) -> String {
    "Noted.".to_owned()
}

fn describe_read(result: &Value) -> String {
    if result["gone"] == true {
        return "What the event was about no longer exists.".to_owned();
    }
    let run = &result["scheduleRun"];
    if run.is_object() {
        let title = run["title"].as_str().unwrap_or("the schedule");
        let status = run["status"].as_str().unwrap_or("unknown");
        return match run["result"].as_str() {
            Some(text) if !text.is_empty() => {
                format!("A run of \"{title}\" ended: {status}.\n\n{text}")
            }
            _ => format!("A run of \"{title}\" ended: {status}."),
        };
    }
    let event = &result["calendarEvent"];
    if event.is_object() {
        let mut out = format!(
            "\"{}\" from {} to {} ({}).",
            event["title"].as_str().unwrap_or("?"),
            event["start"].as_str().unwrap_or("?"),
            event["end"].as_str().unwrap_or("?"),
            event["timezone"].as_str().unwrap_or("?"),
        );
        for key in ["location", "description"] {
            if let Some(text) = event[key].as_str().filter(|t| !t.is_empty()) {
                out.push_str(&format!("\n{key}: {text}"));
            }
        }
        return out;
    }
    let name = result["session"]["name"].as_str().unwrap_or("the session");
    let run = result["run"].as_str().unwrap_or("unknown");
    match result["lastAnswer"].as_str() {
        Some(answer) => format!("\"{name}\" (run {run}). Its last answer:\n\n{answer}"),
        None => format!("\"{name}\" (run {run}) has no answer yet."),
    }
}

impl ObserveTool {
    fn note() -> Self {
        Self {
            spec: ToolSpec::new(
                NOTE_TOOL,
                json!({
                    "type": "object",
                    "properties": {
                        "eventId": event_id(),
                        "note": { "type": "string", "description": "What you notice, in your own words" },
                        "evidence": { "type": "array", "items": { "type": "string" },
                                      "description": "References that support it (session ids, file paths)" },
                    },
                    "required": ["eventId", "note"],
                    "additionalProperties": false,
                }),
                None,
            ),
            operation: "pot.observe.note",
            describe: describe_note,
        }
    }

    fn read() -> Self {
        Self {
            spec: ToolSpec::new(
                READ_TOOL,
                json!({
                    "type": "object",
                    "properties": { "eventId": event_id() },
                    "required": ["eventId"],
                    "additionalProperties": false,
                }),
                None,
            ),
            operation: "pot.observe.read",
            describe: describe_read,
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

impl Tool for ObserveTool {
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
    fn a_read_shows_the_sessions_last_answer() {
        let shown = describe_read(
            &json!({ "session": { "name": "Nightly" }, "run": "failed", "lastAnswer": "Tests broke." }),
        );
        assert_eq!(
            shown,
            "\"Nightly\" (run failed). Its last answer:\n\nTests broke."
        );
        let empty = describe_read(
            &json!({ "session": { "name": "Nightly" }, "run": "running", "lastAnswer": null }),
        );
        assert_eq!(empty, "\"Nightly\" (run running) has no answer yet.");
        let run = describe_read(
            &json!({ "scheduleRun": { "title": "Backup", "status": "failed", "result": "Disk full" } }),
        );
        assert_eq!(run, "A run of \"Backup\" ended: failed.\n\nDisk full");
        let event = describe_read(
            &json!({ "calendarEvent": { "title": "Standup", "start": "2026-11-26T09:00",
            "end": "2026-11-26T09:15", "timezone": "Asia/Taipei", "location": "Room 1", "description": "" } }),
        );
        assert_eq!(
            event,
            "\"Standup\" from 2026-11-26T09:00 to 2026-11-26T09:15 (Asia/Taipei).\nlocation: Room 1"
        );
    }
}
