//! The repository memory settings check (`features.workspaceMemory`): the
//! startup warning, which never repeats a configured value.

use serde_json::{Map, Value};

use super::schema::{Checker, Issue, IssueKind, PathPart};

use crate::features::memory::config::{MODEL_KEYS, THINKING_CHOICES, WORKSPACE_KEYS};

/// `modelChoice`.
fn model_choice(checker: &mut Checker, value: Option<&Value>) {
    let Some(map) = checker.object(value) else {
        return;
    };
    checker.key(map, "provider", |c, v| c.string(v, Some(1)));
    checker.key(map, "id", |c, v| c.string(v, Some(1)));
    checker.key(map, "thinking", |c, v| {
        if v.is_some() {
            c.enumeration(v, &THINKING_CHOICES);
        }
    });
}

/// The problems in `features.workspaceMemory`, in schema order.
fn workspace_issues(raw: Option<&Value>) -> Vec<Issue> {
    let mut checker = Checker::default();
    let Some(map) = checker.object(raw) else {
        return checker.issues;
    };
    for key in WORKSPACE_KEYS {
        checker.key(map, key, |c, v| {
            if v.is_none() {
                return;
            }
            match key {
                "enabled" | "passive" => {
                    c.boolean(v);
                }
                "model" => model_choice(c, v),
                "fallbackModels" => {
                    if let Some(items) = c.array(v) {
                        for (i, item) in items.iter().enumerate() {
                            c.at(PathPart::Index(i), |c| model_choice(c, Some(item)));
                        }
                    }
                }
                "missingModelPolicy" => {
                    c.enumeration(v, &["fallback", "error"]);
                }
                _ => {
                    c.positive_int(v, None);
                }
            }
        });
    }
    checker.issues
}

fn field_path(parts: &[PathPart]) -> String {
    let mut out = "features.workspaceMemory".to_owned();
    for part in parts {
        match part {
            PathPart::Key(key) => {
                out.push('.');
                out.push_str(key);
            }
            PathPart::Index(index) => out.push_str(&format!("[{index}]")),
        }
    }
    out
}

/// `reason(issue)`: never the rejected value.
fn reason(issue: &Issue) -> String {
    match &issue.kind {
        IssueKind::InvalidType { expected, .. } | IssueKind::EnumType { expected, .. } => {
            format!("expected {expected}")
        }
        IssueKind::NotInteger => "expected integer".to_owned(),
        IssueKind::InvalidEnum { .. } => "expected a supported option".to_owned(),
        IssueKind::TooSmall {
            minimum, inclusive, ..
        } => format!(
            "must be {} {}",
            if *inclusive {
                "at least"
            } else {
                "greater than"
            },
            crate::messages::js::number_text(*minimum)
        ),
        IssueKind::TooBig {
            maximum, inclusive, ..
        } => format!(
            "must be {} {}",
            if *inclusive { "at most" } else { "less than" },
            crate::messages::js::number_text(*maximum)
        ),
        IssueKind::UnrecognizedKeys { .. } => "invalid field".to_owned(),
    }
}

/// `workspaceMemoryConfigWarning(features).warning`.
pub fn workspace_memory_config_warning(features: &Map<String, Value>) -> Option<String> {
    let raw = features
        .get("workspaceMemory")
        .filter(|value| !value.is_null())?;
    let issues = workspace_issues(Some(raw));
    let parsed = issues.is_empty();
    let mut diagnostics: Vec<String> = issues
        .iter()
        .map(|issue| format!("{}: {}", field_path(&issue.path), reason(issue)))
        .collect();
    let mut unknown_keys = |value: Option<&Value>, keys: &[&str], parts: &[PathPart]| {
        let Some(Value::Object(map)) = value else {
            return;
        };
        for key in map.keys() {
            if !keys.contains(&key.as_str()) {
                // Quoted, so punctuation cannot impersonate another warning.
                diagnostics.push(format!(
                    "{}[{}]: unknown field (ignored)",
                    field_path(parts),
                    crate::messages::js::string_literal(key)
                ));
            }
        }
    };
    unknown_keys(Some(raw), &WORKSPACE_KEYS, &[]);
    if let Value::Object(map) = raw {
        unknown_keys(
            map.get("model"),
            &MODEL_KEYS,
            &[PathPart::Key("model".into())],
        );
        if let Some(Value::Array(models)) = map.get("fallbackModels") {
            for (index, model) in models.iter().enumerate() {
                unknown_keys(
                    Some(model),
                    &MODEL_KEYS,
                    &[
                        PathPart::Key("fallbackModels".into()),
                        PathPart::Index(index),
                    ],
                );
            }
        }
    }
    if diagnostics.is_empty() {
        return None;
    }
    let summary = if parsed {
        "unknown fields were ignored; valid settings remain in effect."
    } else {
        "invalid fields use defaults or fail closed; valid settings remain in effect."
    };
    Some(format!(
        "Workspace memory configuration: {summary} {} Fix features.workspaceMemory in the node config.json and restart the agent.",
        diagnostics.join("; ")
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn warning(memory: Value) -> Option<String> {
        let features = json!({ "workspaceMemory": memory });
        workspace_memory_config_warning(features.as_object().unwrap())
    }

    #[test]
    fn accepts_defaults_and_valid_disabled_settings_without_a_warning() {
        assert_eq!(workspace_memory_config_warning(&Map::new()), None);
        assert_eq!(warning(Value::Null), None);
        assert_eq!(warning(json!({"enabled": false})), None);
        assert_eq!(
            warning(json!({
                "enabled": false, "passive": true,
                "model": {"provider": "p", "id": "m", "thinking": "max"},
                "fallbackModels": [{"provider": "p", "id": "f"}],
                "maxTokens": 40000, "rateLimitCooldownMs": 60000, "missingModelPolicy": "error",
            })),
            None
        );
    }

    #[test]
    fn reports_invalid_fields_without_rejected_values() {
        let text = warning(json!({
            "enabled": "private-enabled-value",
            "rateLimitCooldownMs": -1,
            "model": {"provider": "private-provider", "id": "private-model", "thinking": "private-enum-value"},
            "maxTokens": 1.5,
            "missingModelPolicy": "private-policy",
            "fallbackModels": [{"provider": "", "id": "private-model-value"}],
        }))
        .unwrap();
        assert!(!text.contains("private-"));
        assert_eq!(
            text,
            "Workspace memory configuration: invalid fields use defaults or fail closed; valid settings remain in effect. \
             features.workspaceMemory.enabled: expected boolean; \
             features.workspaceMemory.model.thinking: expected a supported option; \
             features.workspaceMemory.fallbackModels[0].provider: must be at least 1; \
             features.workspaceMemory.maxTokens: expected integer; \
             features.workspaceMemory.rateLimitCooldownMs: must be greater than 0; \
             features.workspaceMemory.missingModelPolicy: expected a supported option \
             Fix features.workspaceMemory in the node config.json and restart the agent."
        );
    }

    #[test]
    fn warns_about_unknown_keys_at_every_schema_object() {
        let text = warning(json!({
            "enabled": false,
            "legacy": "secret-value",
            "model": {"provider": "p", "id": "m", "thinking": "max", "extra": "secret-value"},
            "fallbackModels": [{"provider": "p", "id": "fallback", "typo": "secret-value"}]
        }))
        .unwrap();
        assert_eq!(
            text,
            "Workspace memory configuration: unknown fields were ignored; valid settings remain in effect. \
             features.workspaceMemory[\"legacy\"]: unknown field (ignored); \
             features.workspaceMemory.model[\"extra\"]: unknown field (ignored); \
             features.workspaceMemory.fallbackModels[0][\"typo\"]: unknown field (ignored) \
             Fix features.workspaceMemory in the node config.json and restart the agent."
        );
    }

    #[test]
    fn reports_invalid_whole_object_input_without_its_value() {
        for value in [json!(false), json!([]), json!("private-whole-object")] {
            let text = warning(value).unwrap();
            assert!(text.contains("features.workspaceMemory: expected object"));
            assert!(!text.contains("private-whole-object"));
        }
    }
}
