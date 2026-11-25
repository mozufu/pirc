//! `budget_status` and `budget_request`: a pot reads its remaining budget and
//! asks the user for more (Gateway operations `pot.budget.status` and
//! `pot.budget.request`). Only the user's answer raises a cap.

use std::rc::Rc;

use serde_json::{Map, Value, json};

use crate::LocalBoxFuture;
use crate::channels::process_gateway;
use crate::tools::{Tool, ToolContext, ToolResult, ToolSpec, typed};

pub const STATUS_TOOL: &str = "budget_status";
pub const REQUEST_TOOL: &str = "budget_request";

pub fn status_tool() -> Rc<dyn Tool> {
    Rc::new(StatusTool {
        spec: ToolSpec::new(
            STATUS_TOOL,
            json!({ "type": "object", "properties": {},
            "additionalProperties": false }),
            None,
        ),
    })
}

pub fn request_tool() -> Rc<dyn Tool> {
    Rc::new(RequestTool {
        spec: ToolSpec::new(
            REQUEST_TOOL,
            json!({
                "type": "object",
                "properties": {
                    "amountMicros": { "type": "integer", "minimum": 1,
                        "description": "More money for this month, in micro-US-dollars" },
                    "tokens": { "type": "integer", "minimum": 1,
                        "description": "More tokens for today" },
                    "window": { "type": "string", "enum": ["month", "day"],
                        "description": "month for money, day for tokens" },
                    "reason": { "type": "string", "description": "Why you need it" },
                },
                "required": ["window"],
                "additionalProperties": false,
            }),
            None,
        ),
    })
}

fn number(value: &Value, key: &str) -> u64 {
    value[key].as_u64().unwrap_or(0)
}

fn status_text(status: &Value) -> String {
    let money = &status["money"];
    let tokens = &status["tokens"];
    let owner = &status["owner"];
    let owner_money_unlimited = owner["money"]["unlimited"].as_bool().unwrap_or(false);
    let owner_tokens_unlimited = owner["tokens"]["unlimited"].as_bool().unwrap_or(false);
    let owner_money = number(&owner["money"], "remainingMicros");
    let owner_tokens = number(&owner["tokens"], "remaining");
    let owner_line = match (owner_money_unlimited, owner_tokens_unlimited) {
        (true, true) => "Owner-wide: no caps.".to_owned(),
        (true, false) => format!("Owner-wide: no money cap; {owner_tokens} tokens left."),
        (false, true) => format!("Owner-wide: {owner_money} micro-dollars left; no token cap."),
        (false, false) => {
            format!("Owner-wide: {owner_money} micro-dollars and {owner_tokens} tokens left.")
        }
    };
    format!(
        "This month: {} of {} micro-dollars left ({} used, {} reserved).\n\
         Today: {} of {} tokens left ({} used, {} reserved).\n\
         {owner_line}\n\
         {}",
        number(money, "remainingMicros"),
        number(money, "capMicros"),
        number(money, "usedMicros"),
        number(money, "reservedMicros"),
        number(tokens, "remaining"),
        number(tokens, "cap"),
        number(tokens, "used"),
        number(tokens, "reserved"),
        if owner["countSubscriptionMoney"].as_bool().unwrap_or(false) {
            "Subscription usage counts at API-equivalent prices."
        } else {
            "Subscription usage does not count against money caps."
        }
    )
}

struct StatusTool {
    spec: ToolSpec,
}

impl StatusTool {
    async fn run(&self, args: Map<String, Value>, ctx: ToolContext) -> Result<ToolResult, String> {
        if !args.is_empty() {
            return Ok(ToolResult::error("budget_status takes no arguments"));
        }
        let gateway = process_gateway().ok_or("this pot has no Gateway connection")?;
        let status = gateway
            .gateway
            .request(STATUS_TOOL_OP, args, Some(&ctx.signal))
            .await;
        let status = match status {
            Ok(status) => status,
            Err(error) => return Ok(ToolResult::error(error.message().to_owned())),
        };
        Ok(typed(status_text(&status), status, None, false))
    }
}

const STATUS_TOOL_OP: &str = "pot.budget.status";
const REQUEST_TOOL_OP: &str = "pot.budget.request";

struct RequestTool {
    spec: ToolSpec,
}

impl RequestTool {
    async fn run(&self, args: Map<String, Value>, ctx: ToolContext) -> Result<ToolResult, String> {
        let money = args.contains_key("amountMicros");
        let tokens = args.contains_key("tokens");
        if money == tokens {
            return Ok(ToolResult::error(
                "Give exactly one of amountMicros or tokens",
            ));
        }
        match args.get("window").and_then(Value::as_str) {
            Some("month") if money => {}
            Some("day") if tokens => {}
            Some("month") => {
                return Ok(ToolResult::error("A month request asks in amountMicros"));
            }
            Some("day") => return Ok(ToolResult::error("A day request asks in tokens")),
            _ => return Ok(ToolResult::error("window must be month or day")),
        }
        let gateway = process_gateway().ok_or("this pot has no Gateway connection")?;
        let request = gateway
            .gateway
            .request(REQUEST_TOOL_OP, args, Some(&ctx.signal))
            .await;
        let request = match request {
            Ok(result) => result["request"].clone(),
            Err(error) => return Ok(ToolResult::error(error.message().to_owned())),
        };
        let asked = match request["window"].as_str() {
            Some("month") => format!(
                "{} more micro-dollars this month",
                request["amountMicros"].as_u64().unwrap_or(0)
            ),
            _ => format!(
                "{} more tokens today",
                request["tokens"].as_u64().unwrap_or(0)
            ),
        };
        Ok(typed(
            format!(
                "Asked the user for {asked}. It is open until they approve or deny it; only their answer raises your budget."
            ),
            request,
            None,
            false,
        ))
    }
}

impl Tool for StatusTool {
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

impl Tool for RequestTool {
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
    fn the_status_text_names_every_remainder() {
        let text = status_text(&json!({
            "money": { "capMicros": 20_000_000, "usedMicros": 1_000, "reservedMicros": 2_000,
                       "remainingMicros": 19_997_000 },
            "tokens": { "cap": 500_000, "used": 100, "reserved": 50, "remaining": 499_850 },
            "owner": {
                "money": { "remainingMicros": 50 },
                "tokens": { "remaining": 60 },
                "countSubscriptionMoney": false,
            },
        }));
        assert!(text.contains("19997000 of 20000000 micro-dollars left"));
        assert!(text.contains("499850 of 500000 tokens left"));
        assert!(text.contains("Owner-wide: 50 micro-dollars and 60 tokens left."));
        assert!(text.contains("does not count against money caps"));
    }
}
