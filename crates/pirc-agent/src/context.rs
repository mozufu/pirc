//! The system prompt's sections and the context snapshot the side panel
//! shows (`agent/context.ts`), written to `<session>/context.json`.

use std::io::Write as _;
use std::path::Path;

use pirc_protocol::{Message, ToolSpec, Usage};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::messages::{estimate_tokens, js, text_tokens};

/// `PromptSection`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct PromptSection {
    pub id: String,
    pub title: String,
    pub source: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub frozen: Option<bool>,
    pub text: String,
}

impl PromptSection {
    pub fn new(id: &str, title: &str, source: &str, text: impl Into<String>) -> Self {
        Self {
            id: id.to_owned(),
            title: title.to_owned(),
            source: source.to_owned(),
            frozen: None,
            text: text.into(),
        }
    }
}

/// `CONTEXT_FILE`.
pub const CONTEXT_FILE: &str = "context.json";

/// `joinPrompt`: non-empty section texts joined by a blank line.
pub fn join_prompt(sections: &[PromptSection]) -> String {
    sections
        .iter()
        .map(|section| section.text.as_str())
        .filter(|text| !text.is_empty())
        .collect::<Vec<_>>()
        .join("\n\n")
}

/// `trimSections`: the old feature block's outer trim, interior whitespace
/// unchanged.
pub fn trim_sections(sections: &[PromptSection]) -> Vec<PromptSection> {
    let mut result: Vec<PromptSection> = sections
        .iter()
        .filter(|section| !section.text.is_empty())
        .cloned()
        .collect();
    while result
        .first()
        .is_some_and(|section| js::trim(&section.text).is_empty())
    {
        result.remove(0);
    }
    while result
        .last()
        .is_some_and(|section| js::trim(&section.text).is_empty())
    {
        result.pop();
    }
    if let Some(first) = result.first_mut() {
        first.text = js::trim_start(&first.text).to_owned();
    }
    if let Some(last) = result.last_mut() {
        last.text = js::trim_end(&last.text).to_owned();
    }
    result
}

/// `captureContext`'s input.
pub struct ContextInput<'a> {
    pub sections: &'a [PromptSection],
    pub tools: &'a [ToolSpec],
    pub messages: &'a [Message],
    pub provider: &'a str,
    pub model_id: &'a str,
    pub context_window: Option<u64>,
    pub memory_tokens: u64,
    /// `capabilities` (the registry's summaries).
    pub capabilities: Option<Value>,
}

fn object(pairs: Vec<(&str, Value)>) -> Value {
    Value::Object(
        pairs
            .into_iter()
            .map(|(key, value)| (key.to_owned(), value))
            .collect(),
    )
}

/// `captureContext`: a `ContextSnapshot` (as JSON, as clients read it).
pub fn capture_context(input: ContextInput<'_>) -> Value {
    let mut system = 0;
    let sections: Vec<Value> = input
        .sections
        .iter()
        .enumerate()
        .map(|(index, section)| {
            let separator = if index > 0 { "\n\n" } else { "" };
            let tokens = text_tokens(&format!("{}{separator}", section.text));
            system += tokens;
            let mut value = serde_json::to_value(section).unwrap_or(Value::Null);
            if let Value::Object(map) = &mut value {
                map.insert("estimatedTokens".to_owned(), Value::from(tokens));
            }
            value
        })
        .collect();
    let mut tool_tokens = 0;
    let tools: Vec<Value> = input
        .tools
        .iter()
        .map(|tool| {
            let mut value = serde_json::to_value(tool).unwrap_or(Value::Null);
            let tokens = text_tokens(&js::stringify(&value));
            tool_tokens += tokens;
            if let Value::Object(map) = &mut value {
                map.insert("estimatedTokens".to_owned(), Value::from(tokens));
            }
            value
        })
        .collect();
    let message_tokens: u64 = input.messages.iter().map(estimate_tokens).sum();
    let summary_tokens: u64 = input
        .messages
        .iter()
        .filter(|message| matches!(message, Message::CompactionSummary { .. }))
        .map(estimate_tokens)
        .sum();
    let memory = input.memory_tokens.min(summary_tokens);
    let buckets = object(vec![
        ("system", Value::from(system)),
        ("tools", Value::from(tool_tokens)),
        ("messages", Value::from(message_tokens - memory)),
        ("memory", Value::from(memory)),
    ]);
    let estimated_input = system + tool_tokens + message_tokens;
    let mut model = vec![
        ("provider", Value::from(input.provider)),
        ("id", Value::from(input.model_id)),
    ];
    if let Some(window) = input.context_window {
        model.push(("contextWindow", Value::from(window)));
    }
    let remaining = match input.context_window {
        Some(window) if window > 0 => Value::from(window.saturating_sub(estimated_input)),
        _ => Value::Null,
    };
    let mut snapshot = vec![
        ("version", Value::from(1)),
        ("id", Value::from(crate::random_uuid())),
        ("takenAt", Value::from(crate::now_ms())),
        ("model", object(model)),
        ("sections", Value::Array(sections)),
        ("tools", Value::Array(tools)),
    ];
    if let Some(capabilities) = input.capabilities {
        snapshot.push(("capabilities", capabilities));
    }
    snapshot.push((
        "usage",
        object(vec![
            ("estimatedInput", Value::from(estimated_input)),
            ("scale", Value::from(1)),
            ("buckets", buckets),
            ("remaining", remaining),
        ]),
    ));
    object(snapshot)
}

/// `withReportedUsage`: the provider's input count (with cache reads and
/// writes, never output) scales the estimate.
pub fn with_reported_usage(snapshot: &Value, usage: &Usage) -> Value {
    let reported = usage.input + usage.cache_read + usage.cache_write;
    if reported == 0 {
        return snapshot.clone();
    }
    let mut next = snapshot.clone();
    let context_window = snapshot
        .pointer("/model/contextWindow")
        .and_then(Value::as_f64)
        .filter(|window| *window != 0.0);
    let Some(usage_map) = next.get_mut("usage").and_then(Value::as_object_mut) else {
        return next;
    };
    let estimated = usage_map
        .get("estimatedInput")
        .and_then(Value::as_f64)
        .unwrap_or(0.0);
    let scale = if estimated != 0.0 {
        reported as f64 / estimated
    } else {
        1.0
    };
    usage_map.insert("reportedInput".to_owned(), Value::from(reported));
    usage_map.insert("scale".to_owned(), js::number_value(scale));
    usage_map.insert(
        "remaining".to_owned(),
        context_window.map_or(Value::Null, |window| {
            js::number_value((window - reported as f64).max(0.0))
        }),
    );
    next
}

/// `writeContext(dir, snapshot)`: atomically, as `context.json` (0600).
pub fn write_context(dir: &Path, snapshot: &Value) -> Result<(), String> {
    let file = dir.join(CONTEXT_FILE);
    let temp = dir.join(format!("{CONTEXT_FILE}.{}.tmp", crate::random_uuid()));
    let result = crate::state_io::create_new(&temp)
        .and_then(|mut out| out.write_all(js::stringify(snapshot).as_bytes()))
        .map_err(|error| js::node_error(&error, "open", Some(&temp)))
        .and_then(|()| {
            crate::state_io::rename(&temp, &file).map_err(|error| {
                format!(
                    "{} -> '{}'",
                    js::node_error(&error, "rename", Some(&temp)),
                    file.display()
                )
            })
        });
    // A successful rename already moved the temporary file; only a failed
    // write leaves one to remove (and its absence is not an error).
    if result.is_err() {
        let _ = crate::state_io::remove_file(&temp);
    }
    result
}

/// `readContext(dir)`: the last snapshot, `None` when there is none.
pub fn read_context(dir: &Path) -> Result<Option<Value>, String> {
    let file = dir.join(CONTEXT_FILE);
    let text = match std::fs::read(&file) {
        Ok(bytes) => String::from_utf8_lossy(&bytes).into_owned(),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(js::node_error(&error, "open", Some(&file))),
    };
    let value: Value =
        serde_json::from_str(&text).map_err(|error| format!("Invalid JSON: {error}"))?;
    let valid = value.get("version").and_then(Value::as_f64) == Some(1.0)
        && value.get("sections").is_some_and(Value::is_array)
        && value.get("tools").is_some_and(Value::is_array)
        && value.get("usage").is_some_and(truthy)
        && value.get("model").is_some_and(truthy);
    if !valid {
        return Err("Invalid context snapshot".to_owned());
    }
    Ok(Some(value))
}

fn truthy(value: &Value) -> bool {
    crate::tools::js::truthy(Some(value))
}

/// The public fields of a snapshot's usage (for tests and callers).
pub fn usage_of(snapshot: &Value) -> Map<String, Value> {
    snapshot
        .get("usage")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn section(text: &str) -> PromptSection {
        PromptSection::new("test", "Test", "built-in", text)
    }

    #[test]
    fn keeps_feature_joining_byte_identical_including_interior_whitespace() {
        for strings in [
            vec!["  first ", " second  "],
            vec!["", "\n ", "third", "\t"],
            vec!["  ", "\n"],
            vec!["a", " ", "b"],
        ] {
            let sections: Vec<PromptSection> = strings.iter().map(|s| section(s)).collect();
            let expected: String = strings
                .iter()
                .filter(|s| !s.is_empty())
                .map(|s| format!("\n\n{s}"))
                .collect();
            assert_eq!(
                join_prompt(&trim_sections(&sections)),
                js::trim(&expected),
                "{strings:?}"
            );
        }
    }

    fn summary(text: String) -> Message {
        Message::CompactionSummary {
            summary: text,
            tokens_before: 1000,
            timestamp: 1,
        }
    }

    #[test]
    fn accounts_for_memory_within_messages_and_scales_input_including_cache() {
        let messages = [summary("x".repeat(400))];
        let snapshot = capture_context(ContextInput {
            sections: &[section("system")],
            tools: &[],
            messages: &messages,
            provider: "p",
            model_id: "m",
            context_window: Some(1000),
            memory_tokens: 30,
            capabilities: None,
        });
        let usage = usage_of(&snapshot);
        assert_eq!(usage["buckets"]["messages"], 70);
        assert_eq!(usage["buckets"]["memory"], 30);
        let scaled = with_reported_usage(
            &snapshot,
            &Usage {
                input: 100,
                cache_read: 200,
                cache_write: 50,
                output: 999,
                total_tokens: 1349,
            },
        );
        let scaled_usage = usage_of(&scaled);
        assert_eq!(scaled_usage["reportedInput"], 350);
        assert_eq!(scaled_usage["remaining"], 650);
        let product = scaled_usage["scale"].as_f64().unwrap()
            * scaled_usage["estimatedInput"].as_f64().unwrap();
        assert_eq!(product, 350.0);
        assert!(!usage.contains_key("reportedInput"));
        // Key order as the TS spread leaves it.
        assert_eq!(
            scaled_usage.keys().collect::<Vec<_>>(),
            [
                "estimatedInput",
                "scale",
                "buckets",
                "remaining",
                "reportedInput"
            ]
        );
        // No reported input: unchanged.
        assert_eq!(
            with_reported_usage(&snapshot, &crate::messages::empty_usage()),
            snapshot
        );
    }

    #[test]
    fn estimates_sections_with_their_separator_and_tools_as_json() {
        let tool: ToolSpec = serde_json::from_value(json!({
            "name": "echo", "description": "Echo tool", "parameters": {"type": "object"}
        }))
        .unwrap();
        let snapshot = capture_context(ContextInput {
            sections: &[section("abcd"), section("ef")],
            tools: std::slice::from_ref(&tool),
            messages: &[],
            provider: "p",
            model_id: "m",
            context_window: None,
            memory_tokens: 5,
            capabilities: Some(json!([{"name": "read"}])),
        });
        assert_eq!(snapshot["sections"][0]["estimatedTokens"], 1);
        // "ef\n\n" is 4 characters.
        assert_eq!(snapshot["sections"][1]["estimatedTokens"], 1);
        // {"name":"echo","description":"Echo tool","parameters":{"type":"object"}} = 72
        assert_eq!(snapshot["tools"][0]["estimatedTokens"], 18);
        assert_eq!(snapshot["usage"]["remaining"], Value::Null);
        assert_eq!(snapshot["usage"]["buckets"]["memory"], 0);
        assert_eq!(snapshot["usage"]["estimatedInput"], 20);
        assert_eq!(snapshot["model"], json!({"provider": "p", "id": "m"}));
        assert_eq!(
            snapshot.as_object().unwrap().keys().collect::<Vec<_>>(),
            [
                "version",
                "id",
                "takenAt",
                "model",
                "sections",
                "tools",
                "capabilities",
                "usage"
            ]
        );
        assert_eq!(
            snapshot["sections"][0]
                .as_object()
                .unwrap()
                .keys()
                .collect::<Vec<_>>(),
            ["id", "title", "source", "text", "estimatedTokens"]
        );
    }

    #[test]
    fn writes_atomically_with_mode_0600_and_reads_back() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(read_context(dir.path()).unwrap(), None);
        let snapshot = capture_context(ContextInput {
            sections: &[section("s")],
            tools: &[],
            messages: &[],
            provider: "p",
            model_id: "m",
            context_window: Some(10),
            memory_tokens: 0,
            capabilities: None,
        });
        let snapshot = with_reported_usage(
            &snapshot,
            &Usage {
                input: 3,
                output: 0,
                cache_read: 0,
                cache_write: 0,
                total_tokens: 3,
            },
        );
        write_context(dir.path(), &snapshot).unwrap();
        let file = dir.path().join(CONTEXT_FILE);
        assert_eq!(
            std::fs::metadata(&file).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert_eq!(read_context(dir.path()).unwrap(), Some(snapshot.clone()));
        // scale 3/1 is written as JS writes it.
        assert!(
            std::fs::read_to_string(&file)
                .unwrap()
                .contains("\"scale\":3,")
        );
        assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 1);
        std::fs::write(&file, r#"{"version":2}"#).unwrap();
        assert_eq!(
            read_context(dir.path()).unwrap_err(),
            "Invalid context snapshot"
        );
    }
}
