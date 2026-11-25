//! A pot's autonomy and models (plans/pots.md, Runtime and Autonomy): the
//! `set_autonomy`, `remind_me` and `set_thinking` tools, and the report of a
//! model fallback the agent made before any output. Every request reaches the
//! Gateway as a `pot.*` operation; the Gateway finds the pot from the session,
//! so the agent never names one.

use std::rc::Rc;

use serde_json::{Map, Value, json};

use crate::LocalBoxFuture;
use crate::agent::Agent;
use crate::channels::process_gateway;
use crate::tools::{Tool, ToolContext, ToolResult, ToolSpec, require_string, string_or, typed};

/// The pot's own range for `set_autonomy`: 1 hour to 30 days.
pub const MIN_INTERVAL_S: i64 = 3_600;
pub const MAX_INTERVAL_S: i64 = 30 * 24 * 3_600;
const REMINDER_MAX_MS: i64 = 365 * 24 * 3_600_000;
const MAX_NOTE: usize = 4_000;

pub const SET_AUTONOMY_TOOL: &str = "set_autonomy";
pub const REMIND_ME_TOOL: &str = "remind_me";
pub const SET_THINKING_TOOL: &str = "set_thinking";

fn duration(seconds: i64) -> String {
    let (count, unit) = if seconds % 86_400 == 0 {
        (seconds / 86_400, "day")
    } else if seconds % 3_600 == 0 {
        (seconds / 3_600, "hour")
    } else {
        (seconds / 60, "minute")
    };
    if count == 1 {
        format!("1 {unit}")
    } else {
        format!("{count} {unit}s")
    }
}

/// `intervalS`: whole seconds in the pot range, or `null` for off.
fn interval(args: &Map<String, Value>) -> Result<Option<i64>, String> {
    match args.get("intervalS") {
        Some(Value::Null) => Ok(None),
        Some(Value::Number(number)) => {
            let seconds = number.as_i64().ok_or("intervalS must be whole seconds")?;
            if (MIN_INTERVAL_S..=MAX_INTERVAL_S).contains(&seconds) {
                Ok(Some(seconds))
            } else {
                Err("intervalS must be 1 hour to 30 days, or null for off".into())
            }
        }
        _ => Err("intervalS must be a number of seconds, or null for off".into()),
    }
}

/// `at` (epoch milliseconds, in the future and within a year) and `note`.
fn reminder(args: &Map<String, Value>) -> Result<(i64, String), String> {
    let at = args
        .get("at")
        .and_then(Value::as_i64)
        .ok_or("at must be Unix epoch milliseconds")?;
    let note = require_string(args, "note")?.trim().to_owned();
    if note.is_empty() {
        return Err("note must not be empty".into());
    }
    if note.chars().count() > MAX_NOTE {
        return Err("note is at most 4000 characters".into());
    }
    let now = crate::now_ms() as i64;
    if at <= now {
        return Err("at must be in the future".into());
    }
    if at - now > REMINDER_MAX_MS {
        return Err("at must be within one year".into());
    }
    Ok((at, note))
}

/// `level` and its reason; only a pot with automatic thinking gets to ask.
fn thinking(args: &Map<String, Value>) -> Result<(String, String), String> {
    const LEVELS: [&str; 7] = ["off", "minimal", "low", "medium", "high", "xhigh", "max"];
    let level = args
        .get("level")
        .and_then(Value::as_str)
        .ok_or("level must be a thinking level")?
        .to_owned();
    if !LEVELS.contains(&level.as_str()) {
        return Err("level is one of off, minimal, low, medium, high, xhigh, max".into());
    }
    Ok((level, string_or(args, "reason", "").trim().to_owned()))
}

/// The pot's model chain from a `pot.context` answer, main first.
pub fn models_from_context(context: &Value) -> Vec<(String, String)> {
    fn push(model: &Value, out: &mut Vec<(String, String)>) {
        if let (Some(provider), Some(id)) = (
            model.get("provider").and_then(Value::as_str),
            model.get("model").and_then(Value::as_str),
        ) && !provider.is_empty()
            && !id.is_empty()
        {
            out.push((provider.to_owned(), id.to_owned()));
        }
    }
    let mut models = Vec::new();
    push(&context["models"]["main"], &mut models);
    for fallback in context["models"]["fallbacks"]
        .as_array()
        .into_iter()
        .flatten()
    {
        push(fallback, &mut models);
    }
    models
}

/// The next model after `current`, or the first when the current one is not
/// in the chain (as role fallback does).
pub fn next_model(
    models: &[(String, String)],
    current: Option<&(String, String)>,
) -> Option<(String, String)> {
    match current.and_then(|current| models.iter().position(|model| model == current)) {
        Some(position) => models.get(position + 1).cloned(),
        None => models.first().cloned(),
    }
}

/// `pot.fallback`'s arguments.
pub fn fallback_args(
    from: &(String, String),
    to: &(String, String),
    reason: &str,
) -> Map<String, Value> {
    let value = json!({
        "from": { "provider": from.0, "model": from.1 },
        "to": { "provider": to.0, "model": to.1 },
        "reason": reason,
    });
    match value {
        Value::Object(map) => map,
        _ => unreachable!("a JSON object"),
    }
}

/// Keep the chain `pot.context` reported for the agent's fallback.
pub fn remember_models(agent: &Agent, context: &Value) {
    let models = models_from_context(context);
    if !models.is_empty() {
        agent.set_pot_models(models);
    }
}

/// Tell the Gateway which fallback is active. Best effort: the model switch
/// already happened, and the next wake carries the model either way.
pub fn report_fallback(from: Option<&(String, String)>, to: &(String, String), reason: &str) {
    let (Some(from), Some(gateway)) = (from, process_gateway()) else {
        return;
    };
    let args = fallback_args(from, to, reason);
    tokio::task::spawn_local(async move {
        let _ = report(&gateway.gateway, args).await;
    });
}

/// `pot.fallback` with prepared arguments; its result or the channel error.
pub(crate) fn report(
    gateway: &crate::channels::NodeGateway,
    args: Map<String, Value>,
) -> crate::channels::PendingRequest<Value> {
    gateway.request("pot.fallback", args, None)
}

pub fn set_autonomy_tool() -> Rc<dyn Tool> {
    Rc::new(AutonomyTool::new())
}

pub fn remind_me_tool() -> Rc<dyn Tool> {
    Rc::new(RemindMeTool::new())
}

pub fn set_thinking_tool() -> Rc<dyn Tool> {
    Rc::new(ThinkingTool::new())
}

struct AutonomyTool {
    spec: ToolSpec,
}

impl AutonomyTool {
    fn new() -> Self {
        let interval = json!({
            "type": ["integer", "null"],
            "description": "Seconds between autonomy reviews (1 hour to 30 days), or null to turn them off",
        });
        Self {
            spec: ToolSpec::new(
                SET_AUTONOMY_TOOL,
                json!({
                    "type": "object",
                    "properties": {
                        "intervalS": interval,
                        "reason": { "type": "string", "description": "Why you chose this interval" },
                    },
                    "required": ["intervalS", "reason"],
                    "additionalProperties": false,
                }),
                None,
            ),
        }
    }

    async fn run(&self, args: Map<String, Value>, ctx: ToolContext) -> Result<ToolResult, String> {
        let amount = match interval(&args) {
            Ok(interval) => interval,
            Err(error) => return Ok(ToolResult::error(error)),
        };
        let gateway = process_gateway().ok_or("this pot has no Gateway connection")?;
        let result = gateway
            .gateway
            .request("pot.autonomy.set", args, Some(&ctx.signal))
            .await;
        if let Err(error) = result {
            return Ok(ToolResult::error(error.message().to_owned()));
        }
        Ok(ToolResult::text(match amount {
            Some(seconds) => format!("Autonomy reviews are now every {}.", duration(seconds)),
            None => "Autonomy reviews are off.".to_owned(),
        }))
    }
}

struct RemindMeTool {
    spec: ToolSpec,
}

impl RemindMeTool {
    fn new() -> Self {
        Self {
            spec: ToolSpec::new(
                REMIND_ME_TOOL,
                json!({
                    "type": "object",
                    "properties": {
                        "at": { "type": "integer", "description": "When to be woken, Unix epoch milliseconds" },
                        "note": { "type": "string", "description": "What to remember and do then" },
                    },
                    "required": ["at", "note"],
                    "additionalProperties": false,
                }),
                None,
            ),
        }
    }

    async fn run(&self, args: Map<String, Value>, ctx: ToolContext) -> Result<ToolResult, String> {
        let (at, note) = match reminder(&args) {
            Ok(value) => value,
            Err(error) => return Ok(ToolResult::error(error)),
        };
        let gateway = process_gateway().ok_or("this pot has no Gateway connection")?;
        let result = gateway
            .gateway
            .request("pot.reminder.create", args, Some(&ctx.signal))
            .await;
        let result = match result {
            Ok(result) => result,
            Err(error) => return Ok(ToolResult::error(error.message().to_owned())),
        };
        let data =
            json!({ "reminderId": result["id"], "at": result["at"], "note": result["note"] });
        Ok(typed(
            format!(
                "Reminder set for {} (Unix time {at} ms): {note}",
                crate::iso_time(at as u64)
            ),
            data,
            None,
            false,
        ))
    }
}

struct ThinkingTool {
    spec: ToolSpec,
}

impl ThinkingTool {
    fn new() -> Self {
        Self {
            spec: ToolSpec::new(
                SET_THINKING_TOOL,
                json!({
                    "type": "object",
                    "properties": {
                        "level": {
                            "type": "string",
                            "enum": ["off", "minimal", "low", "medium", "high", "xhigh", "max"],
                            "description": "The thinking level for your next wakes",
                        },
                        "reason": { "type": "string", "description": "Why this level is right now" },
                    },
                    "required": ["level", "reason"],
                    "additionalProperties": false,
                }),
                None,
            ),
        }
    }

    async fn run(&self, args: Map<String, Value>, ctx: ToolContext) -> Result<ToolResult, String> {
        let (level, _) = match thinking(&args) {
            Ok(value) => value,
            Err(error) => return Ok(ToolResult::error(error)),
        };
        let gateway = process_gateway().ok_or("this pot has no Gateway connection")?;
        let result = gateway
            .gateway
            .request("pot.thinking.set", args, Some(&ctx.signal))
            .await;
        match result {
            Ok(_) => Ok(typed(
                format!("Thinking level is {level} from your next wake."),
                json!({ "level": level, "appliesFrom": "next_wake" }),
                None,
                false,
            )),
            Err(error) => Ok(ToolResult::error(error.message().to_owned())),
        }
    }
}

impl Tool for AutonomyTool {
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

impl Tool for RemindMeTool {
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

impl Tool for ThinkingTool {
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

    fn context() -> Value {
        json!({
            "models": {
                "main": { "provider": "p", "model": "one" },
                "fallbacks": [
                    { "provider": "p", "model": "two" },
                    { "provider": "q", "model": "three" }
                ],
                "activeFallback": 0,
                "thinking": "medium",
                "thinkingAuto": true
            }
        })
    }

    #[test]
    fn the_chain_and_fallback_report_follow_the_context() {
        let models = models_from_context(&context());
        let names: Vec<&str> = models.iter().map(|(_, id)| id.as_str()).collect();
        assert_eq!(names, ["one", "two", "three"]);
        let one = ("p".to_owned(), "one".to_owned());
        let two = ("p".to_owned(), "two".to_owned());
        let three = ("q".to_owned(), "three".to_owned());
        assert_eq!(next_model(&models, Some(&one)), Some(two.clone()));
        assert_eq!(next_model(&models, Some(&two)), Some(three.clone()));
        assert_eq!(next_model(&models, Some(&three)), None);
        // An unknown current model starts over at the main one.
        let unknown = ("z".to_owned(), "z".to_owned());
        assert_eq!(next_model(&models, Some(&unknown)), Some(one.clone()));
        assert_eq!(next_model(&[], Some(&one)), None);
        let args = fallback_args(&one, &two, "rate limited");
        assert_eq!(args["from"]["model"], "one");
        assert_eq!(args["to"]["provider"], "p");
        assert_eq!(args["reason"], "rate limited");
    }

    #[test]
    fn the_tools_offer_their_documented_arguments() {
        for tool in [
            set_autonomy_tool() as Rc<dyn Tool>,
            remind_me_tool(),
            set_thinking_tool(),
        ] {
            assert!(!tool.description().is_empty(), "{}", tool.name());
            assert_eq!(tool.parameters()["type"], "object");
        }
        let set = set_autonomy_tool();
        assert_eq!(set.name(), SET_AUTONOMY_TOOL);
        assert_eq!(
            set.parameters()["properties"]["intervalS"]["type"],
            json!(["integer", "null"])
        );
        assert_eq!(remind_me_tool().name(), REMIND_ME_TOOL);
        assert_eq!(set_thinking_tool().name(), SET_THINKING_TOOL);
    }

    #[tokio::test]
    async fn the_fallback_report_sends_pot_fallback_to_the_gateway() {
        let frames = Rc::new(std::cell::RefCell::new(Vec::new()));
        let write = {
            let frames = frames.clone();
            Rc::new(move |value: Value| frames.borrow_mut().push(value)) as crate::rpc::Write
        };
        let gateway = crate::channels::NodeGateway::new(write);
        let from = ("p".to_owned(), "one".to_owned());
        let to = ("p".to_owned(), "two".to_owned());
        let args = fallback_args(&from, &to, "rate limited");
        let pending = report(&gateway, args);
        let request = frames.borrow()[0].clone();
        assert_eq!(request["op"], "pot.fallback");
        assert_eq!(request["args"]["to"]["model"], "two");
        gateway.respond(&json!({
            "id": request["id"],
            "ok": true,
            "result": { "activeFallback": 1 }
        }));
        assert_eq!(pending.await.unwrap()["activeFallback"], 1);
    }

    #[test]
    fn arguments_are_checked_before_any_request() {
        let map = |value: Value| value.as_object().unwrap().clone();
        assert_eq!(interval(&map(json!({ "intervalS": null }))), Ok(None));
        assert_eq!(
            interval(&map(json!({ "intervalS": 86_400 }))),
            Ok(Some(86_400))
        );
        assert!(interval(&map(json!({ "intervalS": 60 }))).is_err());
        assert!(interval(&map(json!({ "intervalS": 31 * 86_400 }))).is_err());
        assert!(interval(&map(json!({ "intervalS": "daily" }))).is_err());

        let soon = crate::now_ms() as i64 + 60_000;
        let (at, note) = reminder(&map(json!({ "at": soon, "note": "  Ping me  " }))).unwrap();
        assert_eq!((at, note.as_str()), (soon, "Ping me"));
        assert!(
            reminder(&map(
                json!({ "at": crate::now_ms() as i64 - 1, "note": "x" })
            ))
            .is_err()
        );
        assert!(reminder(&map(json!({ "at": soon + REMINDER_MAX_MS, "note": "x" }))).is_err());
        assert!(reminder(&map(json!({ "at": soon, "note": " " }))).is_err());

        assert_eq!(
            thinking(&map(json!({ "level": "high", "reason": " hard task " }))),
            Ok(("high".into(), "hard task".into()))
        );
        assert_eq!(
            thinking(&map(json!({ "level": "max", "reason": "x" }))),
            Ok(("max".into(), "x".into()))
        );
        assert!(thinking(&map(json!({ "level": "huge", "reason": "x" }))).is_err());
    }
}
