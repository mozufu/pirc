//! The built-in features (`agent/features/index.ts`), in the order the
//! agent runs their hooks.

use std::rc::Rc;

use crate::feature::Feature;

pub mod ask_question;
pub mod assistant;
pub mod background;
pub mod browser;
pub mod calendar;
pub mod compact;
pub mod goal;
pub mod memory;
pub mod pot;
pub mod project_instructions;
pub mod recap;
pub mod role;
pub mod sandbox;
pub mod schedules;
pub mod skills;
pub mod team;
pub mod title;
pub mod todo;
pub mod web_search;
pub mod workspace_memory;

/// Map hook names to their stable node-config / mode keys. Non-selectable
/// infrastructure (especially approval policy) is deliberately not included.
#[cfg(test)]
pub(crate) fn config_key(name: &str) -> Option<&'static str> {
    match name {
        "session-title" => Some("sessionTitle"),
        "todo" => Some("todo"),
        "observational-memory" => Some("observationalMemory"),
        "workspace-memory" => Some("workspaceMemory"),
        "skills" => Some("skills"),
        "browser" => Some("browser"),
        "web-search" => Some("webSearch"),
        "schedules" => Some("schedules"),
        "calendar" => Some("calendar"),
        "background-task" => Some("background"),
        "agent-team" => Some("agentTeam"),
        "goal" => Some("goal"),
        _ => None,
    }
}

/// `builtinFeatures`.
pub fn builtin_features() -> Vec<Rc<dyn Feature>> {
    vec![
        title::feature(),
        ask_question::feature(),
        todo::feature(),
        compact::feature(),
        // Chat sessions only: the project's instructions, before USER/MEMORY.
        project_instructions::feature(),
        // Agents started in a role: the role's instructions.
        role::feature(),
        memory::feature(),
        workspace_memory::feature(),
        // Chat sessions only: the user's memory, held by the gateway.
        assistant::feature(),
        // A pot's own session only: its identity, from the gateway.
        pot::feature(),
        skills::feature(),
        recap::feature(),
        // Node agents with a browser only (PIRC_BROWSER=1).
        browser::feature(),
        // Node agents with a gateway only; the gateway holds the search key.
        web_search::feature(),
        // Node agents with a gateway only; the gateway runs the schedules.
        schedules::feature(),
        // Node agents with a gateway only; user grants are checked by the gateway.
        calendar::feature(),
        // Node agents inside the node's OS sandbox only (PIRC_SANDBOX=srt).
        sandbox::feature(),
        background::feature(),
        team::feature(),
        // Last: its settle hook starts the next round after the others had their turn.
        goal::feature(),
    ]
}

/// `processFeatures`: the features an agent process runs. Development only,
/// for the agent-level conformance transcripts (docs/development/historical-records.md):
/// `PIRC_AGENT_FEATURES=none` runs the core alone, and a
/// comma-separated list of feature names (`todo,goal`) runs only those, in
/// their usual order. Unset or `all` runs every feature; production never
/// sets it. `Err` names unknown features.
pub fn process_features(setting: Option<&str>) -> Result<Vec<Rc<dyn Feature>>, String> {
    let setting = setting.map(str::trim).unwrap_or_default();
    if setting.is_empty() || setting == "all" {
        return Ok(builtin_features());
    }
    if setting == "none" {
        return Ok(Vec::new());
    }
    let mut wanted: Vec<&str> = Vec::new();
    for name in setting.split(',').map(str::trim) {
        if !wanted.contains(&name) {
            wanted.push(name);
        }
    }
    let features = builtin_features();
    let unknown: Vec<&str> = wanted
        .iter()
        .copied()
        .filter(|name| !features.iter().any(|feature| feature.name() == *name))
        .collect();
    if !unknown.is_empty() {
        return Err(format!(
            "PIRC_AGENT_FEATURES: unknown features {}",
            unknown.join(", ")
        ));
    }
    Ok(features
        .into_iter()
        .filter(|feature| wanted.contains(&feature.name()))
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn names(features: &[Rc<dyn Feature>]) -> Vec<&'static str> {
        features.iter().map(|feature| feature.name()).collect()
    }

    #[test]
    fn mode_feature_registry_matches_actual_features() {
        let features = builtin_features();
        let mut keys: Vec<_> = features
            .iter()
            .filter_map(|feature| config_key(feature.name()))
            .collect();
        keys.sort_unstable();
        let mut declared = pirc_protocol::mode::FEATURE_NAMES.to_vec();
        declared.sort_unstable();
        assert_eq!(keys, declared);
    }

    #[test]
    fn selects_features_as_the_ts_switch_does() {
        let all = names(&builtin_features());
        assert_eq!(
            all,
            [
                "session-title",
                "ask-question",
                "todo",
                "compact",
                "project-instructions",
                "role",
                "observational-memory",
                "workspace-memory",
                "assistant",
                "pot",
                "skills",
                "recap",
                "browser",
                "web-search",
                "schedules",
                "calendar",
                "sandbox",
                "background-task",
                "agent-team",
                "goal",
            ]
        );
        assert!(process_features(Some("none")).unwrap().is_empty());
        assert_eq!(names(&process_features(None).unwrap()), all);
        assert_eq!(names(&process_features(Some("all")).unwrap()), all);
        assert_eq!(
            names(&process_features(Some("goal, todo")).unwrap()),
            ["todo", "goal"]
        );
        assert_eq!(
            process_features(Some("todo,nope")).err().as_deref(),
            Some("PIRC_AGENT_FEATURES: unknown features nope")
        );
    }
}
