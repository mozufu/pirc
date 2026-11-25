//! Roles (`agent/roles.ts`): named presets an agent picks for a child or a
//! session instead of a model. A role is a markdown file `<name>.md`
//! with front matter (`description`, `model`, `thinking`, `tools`) and the
//! role instructions as its body, read from the built-in `general`, then
//! `$PIRC_CONFIG_DIR/roles/`, then the workspace's `.pirc/roles/`.

use indexmap::{IndexMap, IndexSet};
use pirc_protocol::Models;

use crate::messages::js;
use crate::skills::parse_skill_file;
use crate::skills::yaml::Yaml;

/// `RolePreset`.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct RolePreset {
    /// When to pick this role; shown to the agent that picks.
    pub description: Option<String>,
    pub instructions: Option<String>,
    /// Model patterns in order of preference (`expandModels`).
    pub models: Option<Vec<String>>,
    pub thinking: Option<String>,
    pub tools: Option<Vec<String>>,
    /// `workspace` for a role from the workspace's `.pirc/roles/`.
    pub source: Option<String>,
    /// `node` or `builtin`: the role that workspace role replaced.
    pub overrides: Option<String>,
}

/// `AgentRole`: the role an agent runs in.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct AgentRole {
    pub name: String,
    pub instructions: Option<String>,
    pub models: Option<Vec<String>>,
}

/// `RoleDir`.
#[derive(Clone, Debug, PartialEq)]
pub struct RoleDir {
    pub dir: String,
    /// `node` or `workspace`.
    pub source: String,
}

/// `RoleBrief`: what a picking agent (or the gateway) is told about a role.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct RoleBrief {
    pub name: String,
    pub description: Option<String>,
    pub models: Option<Vec<String>>,
    pub thinking: Option<String>,
    pub tools: Option<Vec<String>>,
    pub source: Option<String>,
    pub overrides: Option<String>,
}

/// `DEFAULT_ROLES`.
pub fn default_roles() -> IndexMap<String, RolePreset> {
    IndexMap::from([(
        "general".to_owned(),
        RolePreset {
            description: Some("General-purpose agent with the default model and all tools.".into()),
            ..RolePreset::default()
        },
    )])
}

const THINKING: [&str; 7] = ["off", "minimal", "low", "medium", "high", "xhigh", "max"];
const DESCRIPTION_LIMIT: usize = 500;
const INSTRUCTIONS_LIMIT: usize = 8000;
const FIELDS: [&str; 4] = ["description", "model", "thinking", "tools"];

/// `^[a-z][a-z0-9_-]{0,39}$`
fn valid_role_name(name: &str) -> bool {
    let bytes = name.as_bytes();
    (1..=40).contains(&bytes.len())
        && bytes[0].is_ascii_lowercase()
        && bytes[1..]
            .iter()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || *b == b'_' || *b == b'-')
}

/// `^[a-z][a-z0-9_]{0,63}$`
fn valid_tool_name(name: &str) -> bool {
    let bytes = name.as_bytes();
    (1..=64).contains(&bytes.len())
        && bytes[0].is_ascii_lowercase()
        && bytes[1..]
            .iter()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || *b == b'_')
}

/// `validateToolList(value, label)`: at most 64 tool names, deduplicated.
pub fn validate_tool_list(value: &Yaml, label: &str) -> Result<Vec<String>, String> {
    let Yaml::Seq(items) = value else {
        return Err(format!("{label} must be an array of at most 64 tool names"));
    };
    if items.len() > 64 {
        return Err(format!("{label} must be an array of at most 64 tool names"));
    }
    let mut out = IndexSet::new();
    for item in items {
        match item {
            Yaml::String(name) if valid_tool_name(name) => {
                out.insert(name.clone());
            }
            other => {
                return Err(format!(
                    "Invalid tool name in {label}: {}",
                    js::utf16_prefix(&other.js_string(), 80)
                ));
            }
        }
    }
    Ok(out.into_iter().collect())
}

/// `optionalText(value, limit, label)`.
fn optional_text(
    value: Option<&Yaml>,
    limit: usize,
    label: &str,
) -> Result<Option<String>, String> {
    match value {
        None | Some(Yaml::Null) => Ok(None),
        Some(Yaml::String(text)) if text.is_empty() => Ok(None),
        Some(Yaml::String(text)) if !js::trim(text).is_empty() && js::utf16_len(text) <= limit => {
            Ok(Some(js::trim(text).to_owned()))
        }
        Some(_) => Err(label.to_owned()),
    }
}

/// A list as a YAML list, or a comma-separated string (`[a, b]` too).
fn split_list(text: &str) -> Yaml {
    let mut inner = text;
    // /^\s*\[|\]\s*$/g
    let leading = js::trim_start(inner);
    if let Some(rest) = leading.strip_prefix('[') {
        inner = rest;
    }
    if let Some(rest) = js::trim_end(inner).strip_suffix(']') {
        inner = rest;
    }
    Yaml::Seq(
        inner
            .split(',')
            .map(|item| strip_quotes(js::trim(item)))
            .filter(|item| !item.is_empty())
            .map(|item| Yaml::String(item.to_owned()))
            .collect(),
    )
}

/// `item.replace(/^(['"])(.*)\1$/, '$2')` (`.` stops at line breaks).
fn strip_quotes(item: &str) -> &str {
    for quote in ['\'', '"'] {
        if item.len() >= 2
            && item.starts_with(quote)
            && item.ends_with(quote)
            && !item[1..item.len() - 1].contains(['\n', '\r', '\u{2028}', '\u{2029}'])
        {
            return &item[1..item.len() - 1];
        }
    }
    item
}

/// `toolList(value, label)`.
fn tool_list(value: Option<&Yaml>, label: &str) -> Result<Option<Vec<String>>, String> {
    match value {
        None | Some(Yaml::Null) => Ok(None),
        Some(Yaml::String(text)) => validate_tool_list(&split_list(text), label).map(Some),
        Some(other) => validate_tool_list(other, label).map(Some),
    }
}

/// `^[^/\s,]+\/[^\s,]+$`
fn valid_model_pattern(item: &str) -> bool {
    let Some((provider, id)) = item.split_once('/') else {
        return false;
    };
    let plain = |part: &str| !part.is_empty() && !part.chars().any(|c| js::is_space(c) || c == ',');
    plain(provider) && plain(id)
}

/// `modelList(value, name)`: one pattern, a YAML list or a comma-separated string.
fn model_list(value: Option<&Yaml>, name: &str) -> Result<Option<Vec<String>>, String> {
    let list = match value {
        None | Some(Yaml::Null) => return Ok(None),
        Some(Yaml::String(text)) if text.is_empty() => return Ok(None),
        Some(Yaml::String(text)) => split_list(text),
        Some(other) => other.clone(),
    };
    let items = match &list {
        Yaml::Seq(items) if !items.is_empty() && items.len() <= 20 => items,
        _ => {
            return Err(format!(
                "Invalid model for role {name}: give 1–20 provider/model-id patterns"
            ));
        }
    };
    let mut out = IndexSet::new();
    for item in items {
        match item {
            Yaml::String(text) if js::utf16_len(text) <= 200 && valid_model_pattern(text) => {
                out.insert(text.clone());
            }
            other => {
                return Err(format!(
                    "Invalid model for role {name}: {} (use provider/model-id; * matches within a part)",
                    js::utf16_prefix(&other.js_string(), 80)
                ));
            }
        }
    }
    Ok(Some(out.into_iter().collect()))
}

/// `parseRole(name, text)`: one role file; `name` comes from its file name.
pub fn parse_role(name: &str, text: &str) -> Result<RolePreset, String> {
    if !valid_role_name(name) || name == "parent" || name == "user" {
        return Err(format!(
            "Invalid role name: {name} (lowercase letters, digits, - and _)"
        ));
    }
    let file = parse_skill_file(text)?;
    let meta = &file.meta;
    let unknown: Vec<&str> = meta
        .keys()
        .map(String::as_str)
        .filter(|key| !FIELDS.contains(key))
        .collect();
    if !unknown.is_empty() {
        return Err(format!(
            "Unknown front matter for role {name}: {}",
            unknown.join(", ")
        ));
    }
    let description = optional_text(
        meta.get("description"),
        DESCRIPTION_LIMIT,
        &format!("Invalid description for role {name} (at most {DESCRIPTION_LIMIT} characters)"),
    )?;
    let models = model_list(meta.get("model"), name)?;
    let thinking = optional_text(
        meta.get("thinking"),
        20,
        &format!("Invalid thinking level for role {name}"),
    )?;
    if let Some(level) = &thinking
        && !THINKING.contains(&level.as_str())
    {
        return Err(format!("Invalid thinking level for role {name}: {level}"));
    }
    let tools = tool_list(meta.get("tools"), &format!("tools for role {name}"))?;
    if js::utf16_len(&file.body) > INSTRUCTIONS_LIMIT {
        return Err(format!(
            "Instructions for role {name} exceed {INSTRUCTIONS_LIMIT} characters"
        ));
    }
    Ok(RolePreset {
        description,
        instructions: (!file.body.is_empty()).then_some(file.body),
        models,
        thinking,
        tools,
        source: None,
        overrides: None,
    })
}

/// A part of a model pattern: `*` matches any characters but line breaks
/// (a JS `.`), everything else literally.
fn glob_matches(pattern: &str, text: &str) -> bool {
    let source = pattern
        .split('*')
        .map(regex_lite::escape)
        .collect::<Vec<_>>()
        .join("[^\n\r\u{2028}\u{2029}]*");
    regex_lite::Regex::new(&format!("^{source}$")).is_ok_and(|regex| regex.is_match(text))
}

/// `expandModels(patterns, providers)`: catalog models matching the
/// patterns, in pattern order and within one pattern in catalog order,
/// without duplicates.
pub fn expand_models(patterns: &[String], models: &Models) -> Vec<(String, String)> {
    let mut out = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for pattern in patterns {
        // Without a `/`, `indexOf` is -1: the provider part is all but the
        // last character and the id part the whole pattern.
        let (provider, id) = if let Some((provider, id)) = pattern.split_once('/') {
            (provider.to_owned(), id.to_owned())
        } else {
            let mut chars = pattern.chars();
            chars.next_back();
            (chars.as_str().to_owned(), pattern.clone())
        };
        for (provider_name, config) in &models.providers {
            if !glob_matches(&provider, provider_name) {
                continue;
            }
            for model in &config.models {
                let key = format!("{provider_name}/{}", model.id);
                if !glob_matches(&id, &model.id) || seen.contains(&key) {
                    continue;
                }
                seen.insert(key);
                out.push((provider_name.clone(), model.id.clone()));
            }
        }
    }
    out
}

/// `roleDirs(configDir, workspace)`: lowest precedence first.
pub fn role_dirs(config_dir: &str, workspace: &str) -> Vec<RoleDir> {
    vec![
        RoleDir {
            dir: js::path_join(&[config_dir, "roles"]),
            source: "node".to_owned(),
        },
        RoleDir {
            dir: js::path_join(&[workspace, ".pirc", "roles"]),
            source: "workspace".to_owned(),
        },
    ]
}

/// `readRoles(dirs)`: the defaults, then each directory's role files; a
/// later file replaces a role of the same name as a whole.
pub fn read_roles(dirs: &[RoleDir]) -> Result<IndexMap<String, RolePreset>, String> {
    let mut roles = default_roles();
    let mut origin: IndexMap<String, &str> =
        roles.keys().map(|name| (name.clone(), "builtin")).collect();
    for item in dirs {
        let Ok(entries) = js::sorted_dir_names(std::path::Path::new(&item.dir)) else {
            continue;
        };
        for entry in entries {
            if entry.starts_with('.') || !entry.ends_with(".md") {
                continue;
            }
            let file = js::path_join(&[&item.dir, &entry]);
            let name = &entry[..entry.len() - 3];
            let role = js::read_text(std::path::Path::new(&file))
                .and_then(|text| parse_role(name, &text))
                .map_err(|error| format!("{file}: {error}"))?;
            if item.source == "workspace" {
                let replaced = roles
                    .contains_key(name)
                    .then(|| origin.get(name).copied())
                    .flatten();
                roles.insert(
                    name.to_owned(),
                    RolePreset {
                        source: Some("workspace".to_owned()),
                        overrides: replaced.map(str::to_owned),
                        ..role
                    },
                );
            } else {
                roles.insert(name.to_owned(), role);
                origin.insert(name.to_owned(), "node");
            }
        }
    }
    Ok(roles)
}

/// `roleBriefs(roles)`.
pub fn role_briefs(roles: &IndexMap<String, RolePreset>) -> Vec<RoleBrief> {
    let some = |text: &Option<String>| text.clone().filter(|text| !text.is_empty());
    roles
        .iter()
        .map(|(name, role)| RoleBrief {
            name: name.clone(),
            description: some(&role.description),
            models: role.models.clone(),
            thinking: some(&role.thinking),
            tools: role.tools.clone(),
            source: some(&role.source),
            overrides: some(&role.overrides),
        })
        .collect()
}

/// `roleSourceNote(role)`: where a workspace role comes from.
pub fn role_source_note(source: Option<&str>, overrides: Option<&str>) -> String {
    if source != Some("workspace") {
        return String::new();
    }
    match overrides {
        Some(overrides) => format!(
            "from this workspace's .pirc/roles, overriding the {} role of the same name",
            if overrides == "node" {
                "node's"
            } else {
                "built-in"
            }
        ),
        None => "from this workspace's .pirc/roles".to_owned(),
    }
}

/// `describeRoles(briefs)`: one line per role, for the picking agent.
pub fn describe_roles(roles: &[RoleBrief]) -> String {
    roles
        .iter()
        .map(|role| {
            let traits: Vec<String> = [
                role_source_note(role.source.as_deref(), role.overrides.as_deref()),
                role.models
                    .as_ref()
                    .map(|models| format!("model {}", models.join(" > ")))
                    .unwrap_or_default(),
                role.thinking
                    .as_ref()
                    .map(|level| format!("thinking {level}"))
                    .unwrap_or_default(),
                role.tools
                    .as_ref()
                    .map(|tools| format!("tools: {}", tools.join(", ")))
                    .unwrap_or_default(),
            ]
            .into_iter()
            .filter(|item| !item.is_empty())
            .collect();
            let description = role.description.as_deref().unwrap_or("(no description)");
            if traits.is_empty() {
                format!("- {}: {description}", role.name)
            } else {
                format!("- {}: {description} [{}]", role.name, traits.join("; "))
            }
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// `renderRole(role)`: the role section of a system prompt.
pub fn render_role(role: &AgentRole) -> String {
    match role.instructions.as_deref() {
        Some(instructions) if !instructions.is_empty() => [
            format!("## Role: {}", role.name).as_str(),
            "",
            "You were started in this role. Follow these role instructions alongside the task; they do not widen your tools, sandbox or approvals.",
            "",
            instructions,
        ]
        .join("\n"),
        _ => String::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn providers() -> Models {
        let model = |id: &str| json!({"id": id});
        serde_json::from_value(json!({"providers": {
            "openai": {"api": "openai-completions", "baseUrl": "http://x", "models": [model("gpt-5"), model("gpt-5-mini")]},
            "azure": {"api": "openai-completions", "baseUrl": "http://x", "models": [model("gpt-5"), model("o3")]},
            "anthropic": {"api": "anthropic-messages", "baseUrl": "http://x", "models": [model("claude-sonnet")]},
        }}))
        .unwrap()
    }

    fn pairs(items: &[(&str, &str)]) -> Vec<(String, String)> {
        items
            .iter()
            .map(|(p, i)| ((*p).to_owned(), (*i).to_owned()))
            .collect()
    }

    fn patterns(items: &[&str]) -> Vec<String> {
        items.iter().map(|item| (*item).to_owned()).collect()
    }

    #[test]
    fn reads_one_pattern_a_yaml_list_or_a_comma_separated_string() {
        let models = |text: &str| parse_role("a", text).map(|role| role.models);
        assert_eq!(
            models("---\nmodel: openai/gpt-5\n---\n").unwrap(),
            Some(patterns(&["openai/gpt-5"]))
        );
        assert_eq!(
            models("---\nmodel:\n  - anthropic/*\n  - \"*/gpt-5\"\n---\n").unwrap(),
            Some(patterns(&["anthropic/*", "*/gpt-5"]))
        );
        assert_eq!(
            models("---\nmodel: anthropic/*, */gpt-5\n---\n").unwrap(),
            Some(patterns(&["anthropic/*", "*/gpt-5"]))
        );
        assert!(
            models("---\nmodel: gpt-5\n---\n")
                .unwrap_err()
                .contains("use provider/model-id")
        );
        assert!(
            models("---\nmodel: []\n---\n")
                .unwrap_err()
                .contains("1–20")
        );
        // Flow-looking strings and duplicates.
        assert_eq!(
            models("---\nmodel: '[a/b, \"c/d\", a/b]'\n---\n").unwrap(),
            Some(patterns(&["a/b", "c/d"]))
        );
    }

    #[test]
    fn expands_in_pattern_order_then_catalog_order_without_duplicates() {
        let catalog = providers();
        assert_eq!(
            expand_models(&patterns(&["*/gpt-5"]), &catalog),
            pairs(&[("openai", "gpt-5"), ("azure", "gpt-5")])
        );
        assert_eq!(
            expand_models(&patterns(&["openai/*"]), &catalog),
            pairs(&[("openai", "gpt-5"), ("openai", "gpt-5-mini")])
        );
        assert_eq!(
            expand_models(
                &patterns(&[
                    "nope/x",
                    "anthropic/claude-sonnet",
                    "*/gpt-5",
                    "openai/gpt-5*"
                ]),
                &catalog
            ),
            pairs(&[
                ("anthropic", "claude-sonnet"),
                ("openai", "gpt-5"),
                ("azure", "gpt-5"),
                ("openai", "gpt-5-mini"),
            ])
        );
        // Only * is special; dots and the rest match literally.
        assert!(expand_models(&patterns(&["openai/gpt.5"]), &catalog).is_empty());
    }

    #[test]
    fn validates_role_files() {
        let error = |name: &str, text: &str| parse_role(name, text).unwrap_err();
        assert_eq!(
            error("Bad", ""),
            "Invalid role name: Bad (lowercase letters, digits, - and _)"
        );
        assert!(error("user", "").starts_with("Invalid role name: user"));
        assert_eq!(
            error("a", "---\nfoo: 1\nbar: 2\n---\n"),
            "Unknown front matter for role a: foo, bar"
        );
        assert_eq!(
            error("a", "---\ndescription: 5\n---\n"),
            "Invalid description for role a (at most 500 characters)"
        );
        assert_eq!(
            error("a", "---\nthinking: huge\n---\n"),
            "Invalid thinking level for role a: huge"
        );
        assert_eq!(
            error("a", "---\ntools: [read, Bash]\n---\n"),
            "Invalid tool name in tools for role a: Bash"
        );
        assert_eq!(
            error("a", "---\ntools: 3\n---\n"),
            "tools for role a must be an array of at most 64 tool names"
        );
        assert_eq!(
            error("a", &"x".repeat(8001)),
            "Instructions for role a exceed 8000 characters"
        );
        let role = parse_role(
            "reviewer",
            "---\ndescription: '  Review  '\nthinking: off\ntools: read, grep, read\n---\n\nLook closely.\n",
        )
        .unwrap();
        assert_eq!(
            role,
            RolePreset {
                description: Some("Review".into()),
                instructions: Some("Look closely.".into()),
                thinking: Some("off".into()),
                tools: Some(patterns(&["read", "grep"])),
                ..RolePreset::default()
            }
        );
        assert_eq!(
            parse_role("plain", "Just text")
                .unwrap()
                .instructions
                .as_deref(),
            Some("Just text")
        );
        assert_eq!(
            parse_role("empty", "---\ndescription: ''\nmodel: ~\n---\n").unwrap(),
            RolePreset::default()
        );
    }

    /// Recorded from the TS `parseRole` (Bun 1.4.2).
    #[test]
    fn parses_like_the_ts_agent() {
        let parsed = |text: &str| parse_role("a", text);
        assert_eq!(
            parsed("---\ntools: [read, 1.5]\n---\n").unwrap_err(),
            "Invalid tool name in tools for role a: 1.5"
        );
        assert_eq!(
            parsed("---\nmodel: [1]\n---\n").unwrap_err(),
            "Invalid model for role a: 1 (use provider/model-id; * matches within a part)"
        );
        assert_eq!(
            parsed("---\ntools: ~\nthinking: max\n---\n").unwrap(),
            RolePreset {
                thinking: Some("max".into()),
                ..RolePreset::default()
            }
        );
        assert_eq!(
            parsed("---\n- x\n---\n").unwrap_err(),
            "Unknown front matter for role a: 0"
        );
        assert_eq!(
            parsed("---\ndescription: [x]\n---\n").unwrap_err(),
            "Invalid description for role a (at most 500 characters)"
        );
        assert_eq!(
            parsed("---\nmodel: a/b\nmodel: c/d\n---\n").unwrap().models,
            Some(patterns(&["c/d"]))
        );
        assert_eq!(
            parsed("---\ntools: \" read , 'grep' ,, \"\n---\n")
                .unwrap()
                .tools,
            Some(patterns(&["read", "grep"]))
        );
    }

    fn write_roles(dir: &std::path::Path, roles: &[(&str, &str)]) {
        std::fs::create_dir_all(dir).unwrap();
        for (name, text) in roles {
            std::fs::write(dir.join(format!("{name}.md")), text).unwrap();
        }
    }

    #[test]
    fn keeps_workspace_roles_overriding_node_roles_and_marks_where_they_come_from() {
        let root = tempfile::tempdir().unwrap();
        let config_dir = root.path().join("config");
        let workspace = root.path().join("ws");
        write_roles(
            &config_dir.join("roles"),
            &[
                (
                    "reviewer",
                    "---\ndescription: Read-only review\ntools: [read, grep]\n---\n",
                ),
                ("planner", "---\ndescription: Plans\n---\n"),
            ],
        );
        write_roles(
            &workspace.join(".pirc/roles"),
            &[
                (
                    "reviewer",
                    "---\ndescription: Repo reviewer\ntools: [read, bash]\n---\n",
                ),
                ("general", "---\ndescription: Repo general\n---\n"),
                ("docs", "---\ndescription: Docs\n---\n"),
            ],
        );
        std::fs::write(workspace.join(".pirc/roles/notes.txt"), "ignored").unwrap();
        std::fs::write(
            workspace.join(".pirc/roles/.hidden.md"),
            "---\nbad: 1\n---\n",
        )
        .unwrap();
        let dirs = role_dirs(
            &config_dir.display().to_string(),
            &workspace.display().to_string(),
        );
        let roles = read_roles(&dirs).unwrap();
        assert_eq!(
            roles.keys().collect::<Vec<_>>(),
            ["general", "planner", "reviewer", "docs"]
        );
        assert_eq!(
            roles["reviewer"],
            RolePreset {
                description: Some("Repo reviewer".into()),
                tools: Some(patterns(&["read", "bash"])),
                source: Some("workspace".into()),
                overrides: Some("node".into()),
                ..RolePreset::default()
            }
        );
        assert_eq!(roles["general"].source.as_deref(), Some("workspace"));
        assert_eq!(roles["general"].overrides.as_deref(), Some("builtin"));
        assert_eq!(roles["docs"].source.as_deref(), Some("workspace"));
        assert_eq!(roles["docs"].overrides, None);
        assert_eq!(roles["planner"].source, None);
        let described = describe_roles(&role_briefs(&roles));
        assert!(described.contains("- reviewer: Repo reviewer [from this workspace's .pirc/roles, overriding the node's role of the same name; tools: read, bash]"));
        assert!(described.contains("- general: Repo general [from this workspace's .pirc/roles, overriding the built-in role of the same name]"));
        assert!(described.contains("- docs: Docs [from this workspace's .pirc/roles]"));
        assert!(described.contains("- planner: Plans\n"));
        // A node directory never marks its roles.
        let node_only = read_roles(&[RoleDir {
            dir: workspace.join(".pirc/roles").display().to_string(),
            source: "node".into(),
        }])
        .unwrap();
        assert_eq!(node_only["docs"].source, None);
        // An invalid file names itself.
        write_roles(
            &config_dir.join("roles"),
            &[("broken", "---\nmodel: x\n---\n")],
        );
        let error = read_roles(&dirs).unwrap_err();
        assert!(error.starts_with(&format!(
            "{}/roles/broken.md: Invalid model for role broken: x",
            config_dir.display()
        )));
    }

    #[test]
    fn renders_the_role_section() {
        assert_eq!(
            render_role(&AgentRole {
                name: "x".into(),
                ..AgentRole::default()
            }),
            ""
        );
        assert_eq!(
            render_role(&AgentRole {
                name: "reviewer".into(),
                instructions: Some("Be strict.".into()),
                models: None
            }),
            "## Role: reviewer\n\nYou were started in this role. Follow these role instructions alongside the task; they do not widen your tools, sandbox or approvals.\n\nBe strict."
        );
    }
}
