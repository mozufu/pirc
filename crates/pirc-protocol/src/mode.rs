//! Validated workspace-mode data shared by the gateway, node and agent.
//!
//! The gateway loads these definitions from its configuration and distributes
//! them to nodes. Default constructors are only the source of initial files
//! and test fixtures; workspace ids never resolve to built-in capabilities.
//! A capability only grants; an invalid mode never falls back to a wider one.

use serde::{Deserialize, Deserializer, Serialize};
use std::fmt;

/// A stored mode name. No names (including `chat` and `directory`) are reserved.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize)]
#[serde(transparent)]
pub struct ModeId(String);

impl ModeId {
    pub fn new(value: impl Into<String>) -> Result<Self, String> {
        let value = value.into();
        let bytes = value.as_bytes();
        if !(1..=40).contains(&bytes.len())
            || !bytes[0].is_ascii_lowercase()
            || !bytes[1..]
                .iter()
                .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || matches!(b, b'_' | b'-'))
        {
            return Err(format!(
                "invalid mode id {value:?}: expected [a-z][a-z0-9_-]{{0,39}}"
            ));
        }
        Ok(Self(value))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for ModeId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl<'de> Deserialize<'de> for ModeId {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        Self::new(String::deserialize(deserializer)?).map_err(serde::de::Error::custom)
    }
}

/// Where a session's tools run.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Workdir {
    Workspace,
    PerSession,
}

/// Named system-prompt sections, rendered in the configured order.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum PromptSection {
    #[serde(rename = "base")]
    Base,
    #[serde(rename = "agents:global")]
    AgentsGlobal,
    #[serde(rename = "agents:workspace")]
    AgentsWorkspace,
    #[serde(rename = "agents:project")]
    AgentsProject,
    #[serde(rename = "body")]
    Body,
}

/// How much of the gateway's assistant state a session reaches.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AssistantAccess {
    User,
    Full,
}

/// Which workspaces a session's schedules may target.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ScheduleScope {
    Own,
    Any,
}

/// Presentation metadata. Clients place a mode's workspaces in the Chat or
/// Work tab by [`AssistantAccess`] (`full` is Chat), not by any field here.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ModeUi {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub icon: Option<String>,
    pub noun: String,
}

/// Feature configuration keys, not hook names. Approval policy (`autoMode`)
/// deliberately is not selectable by a workspace mode.
pub const FEATURE_NAMES: &[&str] = &[
    "sessionTitle",
    "todo",
    "observationalMemory",
    "workspaceMemory",
    "skills",
    "browser",
    "webSearch",
    "schedules",
    "calendar",
    "background",
    "agentTeam",
    "goal",
];

/// Session operations a mode may allow. PTC transport wrappers are not
/// operations: allowing `ptc` must never bypass a restricted operation list.
pub const TOOL_NAMES: &[&str] = &[
    "agent_ask",
    "agent_inbox",
    "agent_list",
    "agent_reply",
    "agent_send",
    "agent_spawn",
    "agent_stop",
    "agent_wait",
    "ask_user_question",
    "background_task",
    "bash",
    "board_post",
    "board_read",
    "browser_click",
    "browser_handoff",
    "browser_navigate",
    "browser_press",
    "browser_record",
    "browser_screenshot",
    "browser_select",
    "browser_snapshot",
    "browser_tabs",
    "browser_type",
    "browser_wait_for",
    "budget_request",
    "budget_status",
    "calendar",
    "create_goal",
    "edit",
    "find",
    "get_goal",
    "grep",
    "handover_propose",
    "ls",
    "memory_note",
    "memory_propose_user",
    "memory_search",
    "message_send",
    "observe_note",
    "observe_read",
    "read",
    "recall",
    "remind_me",
    "history_search",
    "history_read",
    "sandbox_allow_domains",
    "schedule",
    "set_autonomy",
    "set_thinking",
    "subagent",
    "task_create",
    "task_get",
    "task_list",
    "task_update",
    "todo",
    "unsandboxed_bash",
    "update_goal",
    "web_fetch",
    "web_search",
    "work_open",
    "work_send",
    "work_status",
    "write",
];

/// Owned capability data. Deserialization validates safety invariants too, so
/// received JSON cannot bypass the mode-file validator. Call [`Mode::validate`]
/// again after modifying public fields.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Mode {
    pub id: ModeId,
    pub label: String,
    pub description: String,
    pub ui: ModeUi,
    pub workdir: Workdir,
    pub prompt: Vec<PromptSection>,
    pub body: String,
    pub features_off: Vec<String>,
    pub features_on: Vec<String>,
    pub tools: Option<Vec<String>>,
    pub assistant: AssistantAccess,
    pub schedule_scope: ScheduleScope,
    pub project_config: bool,
    pub workspace_memory: bool,
    pub repository: bool,
    pub recap: bool,
    pub delete_sessions: bool,
    /// A pot's own session: the Gateway supplies its identity and messages.
    /// Written only when set, so other modes keep their shape.
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub pot: bool,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ModeFields {
    id: ModeId,
    label: String,
    #[serde(default)]
    description: String,
    ui: ModeUi,
    workdir: Workdir,
    prompt: Vec<PromptSection>,
    #[serde(default)]
    body: String,
    #[serde(default)]
    features_off: Vec<String>,
    #[serde(default)]
    features_on: Vec<String>,
    #[serde(default)]
    tools: Option<Vec<String>>,
    assistant: AssistantAccess,
    schedule_scope: ScheduleScope,
    #[serde(default)]
    project_config: bool,
    #[serde(default)]
    workspace_memory: bool,
    #[serde(default)]
    repository: bool,
    #[serde(default)]
    recap: bool,
    #[serde(default)]
    delete_sessions: bool,
    #[serde(default)]
    pot: bool,
}

impl<'de> Deserialize<'de> for Mode {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let raw = ModeFields::deserialize(deserializer)?;
        let mode = Self {
            id: raw.id,
            label: raw.label,
            description: raw.description,
            ui: raw.ui,
            workdir: raw.workdir,
            prompt: raw.prompt,
            body: raw.body,
            features_off: raw.features_off,
            features_on: raw.features_on,
            tools: raw.tools,
            assistant: raw.assistant,
            schedule_scope: raw.schedule_scope,
            project_config: raw.project_config,
            workspace_memory: raw.workspace_memory,
            repository: raw.repository,
            recap: raw.recap,
            delete_sessions: raw.delete_sessions,
            pot: raw.pot,
        };
        mode.validate().map_err(serde::de::Error::custom)?;
        Ok(mode)
    }
}

impl Mode {
    pub fn feature_off(&self, feature: &str) -> bool {
        self.features_off.iter().any(|name| name == feature)
    }

    pub fn full_assistant(&self) -> bool {
        self.assistant == AssistantAccess::Full
    }

    /// Field bounds use UTF-16 code units, like role instructions.
    pub fn validate(&self) -> Result<(), String> {
        fn text(value: &str, field: &str, max: usize, required: bool) -> Result<(), String> {
            if (required && value.trim().is_empty()) || value.encode_utf16().count() > max {
                return Err(format!(
                    "{field} must be {}at most {max} characters",
                    if required { "non-empty and " } else { "" }
                ));
            }
            Ok(())
        }
        fn names(values: &[String], known: &[&str], field: &str) -> Result<(), String> {
            if values.len() > 64 {
                return Err(format!("{field} must contain at most 64 names"));
            }
            for (index, value) in values.iter().enumerate() {
                if !known.contains(&value.as_str()) {
                    return Err(format!("unknown {field} name: {value}"));
                }
                if values[..index].contains(value) {
                    return Err(format!("duplicate {field} name: {value}"));
                }
            }
            Ok(())
        }
        text(&self.label, "label", 100, true)?;
        text(&self.description, "description", 500, false)?;
        text(&self.ui.noun, "ui.noun", 100, true)?;
        if let Some(icon) = &self.ui.icon {
            text(icon, "ui.icon", 100, true)?;
        }
        text(&self.body, "body", 8000, false)?;
        if self.prompt.is_empty() || self.prompt.len() > 8 {
            return Err("prompt must contain 1–8 named sections".into());
        }
        for (index, section) in self.prompt.iter().enumerate() {
            if self.prompt[..index].contains(section) {
                return Err(format!("duplicate prompt section: {section:?}"));
            }
        }
        if !self.body.is_empty() && !self.prompt.contains(&PromptSection::Body) {
            return Err("non-empty body requires the body prompt section".into());
        }
        names(&self.features_off, FEATURE_NAMES, "features_off")?;
        names(&self.features_on, FEATURE_NAMES, "features_on")?;
        for name in &self.features_on {
            if self.features_off.contains(name) {
                return Err(format!(
                    "feature {name} appears in both features_on and features_off"
                ));
            }
        }
        if let Some(tools) = &self.tools {
            names(tools, TOOL_NAMES, "tools")?;
        }
        if self.full_assistant() && self.workdir == Workdir::Workspace {
            return Err("assistant: full forbids workdir: workspace".into());
        }
        if self.workspace_memory && !self.repository {
            return Err("workspace_memory requires repository".into());
        }
        if self.project_config && !self.repository {
            return Err("project_config requires repository".into());
        }
        Ok(())
    }
}

/// Source for `directory.md`, and a fixture until the catalog cutover.
pub fn default_work() -> Mode {
    Mode {
        id: ModeId::new("directory").expect("default mode id"),
        label: "Work".into(),
        description: "Coding sessions in a repository.".into(),
        ui: ModeUi {
            icon: None,
            noun: "session".into(),
        },
        workdir: Workdir::Workspace,
        prompt: vec![
            PromptSection::Base,
            PromptSection::AgentsGlobal,
            PromptSection::AgentsWorkspace,
            PromptSection::AgentsProject,
            PromptSection::Body,
        ],
        body: String::new(),
        features_off: Vec::new(),
        features_on: Vec::new(),
        tools: None,
        assistant: AssistantAccess::User,
        schedule_scope: ScheduleScope::Own,
        project_config: true,
        workspace_memory: true,
        repository: true,
        recap: true,
        delete_sessions: false,
        pot: false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Value, json};

    #[test]
    fn defaults_match_the_legacy_ids_and_validate() {
        let mode = default_work();
        mode.validate().unwrap();
        let wire = serde_json::to_value(&mode).unwrap();
        assert_eq!(serde_json::from_value::<Mode>(wire).unwrap(), mode);
    }

    #[test]
    fn ids_are_validated_without_reserved_names() {
        for valid in [
            "chat",
            "directory",
            "user",
            "parent",
            "research-v2",
            "a_1",
            &"a".repeat(40),
        ] {
            assert_eq!(ModeId::new(valid).unwrap().as_str(), valid);
        }
        for invalid in [
            "",
            "Chat",
            "1a",
            "a/b",
            "a b",
            "../chat",
            "é",
            &"a".repeat(41),
        ] {
            assert!(ModeId::new(invalid).is_err(), "{invalid}");
            assert!(serde_json::from_value::<ModeId>(json!(invalid)).is_err());
        }
    }

    fn refuses(patch: Value, rule: &str) {
        let mut wire = serde_json::to_value(default_work()).unwrap();
        wire.as_object_mut()
            .unwrap()
            .extend(patch.as_object().unwrap().clone());
        let error = serde_json::from_value::<Mode>(wire)
            .unwrap_err()
            .to_string();
        assert!(error.contains(rule), "{error} should contain {rule}");
    }

    #[test]
    fn refuses_all_forbidden_combinations_on_deserialization() {
        refuses(json!({"assistant":"full"}), "assistant: full");
        refuses(
            json!({"repository":false}),
            "workspace_memory requires repository",
        );
        refuses(
            json!({"repository":false,"workspace_memory":false}),
            "project_config requires repository",
        );
    }

    #[test]
    fn validates_ranges_sections_and_vocabulary() {
        refuses(json!({"unknown":true}), "unknown field");
        refuses(
            json!({"ui":{"noun":"session","unknown":true}}),
            "unknown field",
        );
        // `ui.group` was removed: the tab follows `assistant`.
        refuses(
            json!({"ui":{"group":"work","noun":"session"}}),
            "unknown field",
        );
        refuses(json!({"label":" "}), "label");
        refuses(json!({"description":"x".repeat(501)}), "description");
        refuses(json!({"body":"😀".repeat(4001)}), "body");
        refuses(
            json!({"features_on":["goal"],"features_off":["goal"]}),
            "both",
        );
        refuses(json!({"features_on":["autoMode"]}), "unknown features_on");
        refuses(json!({"features_off":["typo"]}), "unknown features_off");
        refuses(json!({"tools":["made_up"]}), "unknown tools");
        refuses(json!({"tools":["ptc"]}), "unknown tools");
        refuses(json!({"tools":["read","read"]}), "duplicate tools");
        refuses(json!({"prompt":["base","base"]}), "duplicate prompt");
        refuses(json!({"prompt":[]}), "prompt must contain");
        refuses(json!({"prompt":["unknown"]}), "unknown variant");
        refuses(
            json!({"prompt":["base"],"body":"Instructions"}),
            "body prompt section",
        );
        let mut mode = default_work();
        mode.features_on.push("calendar".into());
        mode.body = "😀".repeat(4000);
        mode.tools = Some(Vec::new());
        mode.validate().unwrap();
    }

    #[test]
    fn vocabularies_are_unique() {
        for names in [FEATURE_NAMES, TOOL_NAMES] {
            for (index, name) in names.iter().enumerate() {
                assert!(!names[..index].contains(name), "{name}");
            }
        }
    }
}
