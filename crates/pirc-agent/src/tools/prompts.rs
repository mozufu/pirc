//! Tool descriptions (`agent/prompts/tools.ts`): the markdown files in
//! `crates/pirc-agent/prompts/tools/`, preserved verbatim from TS 0.3.0.
//!
//! Placeholders: `{{name}}` takes a value, and `{{#flag}}…{{/flag}}` keeps
//! its text only when the flag is true. A missing value is an error, so a
//! prompt and its caller cannot drift apart silently.

macro_rules! prompts {
    ($($name:ident),* $(,)?) => {
        const PROMPTS: &[(&str, &str)] = &[
            $((
                stringify!($name),
                include_str!(concat!(
                    "../../prompts/tools/",
                    stringify!($name),
                    ".md"
                )),
            )),*
        ];
    };
}

prompts!(
    agent_ask,
    agent_inbox,
    agent_list,
    agent_reply,
    agent_send,
    agent_spawn,
    agent_stop,
    agent_wait,
    ask_user_question,
    background_task,
    bash,
    board_post,
    board_read,
    browser_click,
    browser_handoff,
    browser_navigate,
    browser_press,
    browser_record,
    browser_screenshot,
    browser_select,
    browser_snapshot,
    browser_tabs,
    browser_type,
    browser_wait_for,
    budget_request,
    budget_status,
    calendar,
    create_goal,
    delegate,
    delegation_status,
    edit,
    find,
    get_goal,
    grep,
    handover_propose,
    history_read,
    history_search,
    ls,
    memory_note,
    memory_propose_user,
    memory_search,
    message_send,
    observe_note,
    observe_read,
    ptc,
    ptc_docs,
    read,
    recall,
    remind_me,
    sandbox_allow_domains,
    schedule,
    set_autonomy,
    set_thinking,
    subagent,
    task_create,
    task_get,
    task_list,
    task_update,
    todo,
    unsandboxed_bash,
    update_goal,
    web_fetch,
    web_search,
    work_open,
    work_send,
    work_status,
    write,
);

#[cfg(test)]
mod mode_vocabulary_tests {
    use super::*;
    use std::collections::BTreeSet;

    #[test]
    fn mode_tool_vocabulary_covers_described_operations_without_ptc_wrappers() {
        let operations: BTreeSet<_> = tool_prompt_names()
            .filter(|name| !matches!(*name, "ptc" | "ptc_docs"))
            .collect();
        let mode_names: BTreeSet<_> = pirc_protocol::mode::TOOL_NAMES.iter().copied().collect();
        assert_eq!(mode_names, operations);
    }
}

/// A placeholder's value (`PromptVars`).
#[derive(Clone, Copy, Debug)]
pub enum PromptVar<'a> {
    Text(&'a str),
    Flag(bool),
}

/// The tools that have a description file (`TOOL_PROMPT_NAMES`).
pub fn tool_prompt_names() -> impl Iterator<Item = &'static str> {
    PROMPTS.iter().map(|(name, _)| *name)
}

fn is_word(c: char) -> bool {
    c.is_ascii_alphanumeric() || c == '_'
}

/// `{{` + a `\w+` name (after `marker`) + `}}` at `at`: the name and the end.
fn tag<'t>(text: &'t str, at: usize, marker: &str) -> Option<(&'t str, usize)> {
    let rest = text[at..].strip_prefix("{{")?.strip_prefix(marker)?;
    let len = rest.find(|c: char| !is_word(c)).unwrap_or(rest.len());
    if len == 0 || !rest[len..].starts_with("}}") {
        return None;
    }
    let start = at + 2 + marker.len();
    Some((&text[start..start + len], start + len + 2))
}

/// `toolPrompt(name, vars)`.
pub fn tool_prompt(name: &str, vars: &[(&str, PromptVar<'_>)]) -> Result<String, String> {
    let Some((_, text)) = PROMPTS.iter().find(|(key, _)| *key == name) else {
        return Err(format!(
            "No description for tool {name} (prompts/tools/{name}.md)"
        ));
    };
    let value = |key: &str| {
        vars.iter()
            .find(|(k, _)| *k == key)
            .map(|(_, value)| *value)
            .ok_or_else(|| format!("Tool description {name}: no value for {{{{{key}}}}}"))
    };
    let text = super::js::trim_end(text);
    // `{{#flag}}…{{/flag}}`: the nearest closing tag of the same name.
    let mut sections = String::new();
    let mut at = 0;
    while at < text.len() {
        if let Some((key, body_start)) = tag(text, at, "#") {
            let closing = format!("{{{{/{key}}}}}");
            if let Some(offset) = text[body_start..].find(&closing) {
                let keep = match value(key)? {
                    PromptVar::Flag(flag) => flag,
                    PromptVar::Text(text) => !text.is_empty(),
                };
                if keep {
                    sections.push_str(&text[body_start..body_start + offset]);
                }
                at = body_start + offset + closing.len();
                continue;
            }
        }
        let c = text[at..].chars().next().expect("a character");
        sections.push(c);
        at += c.len_utf8();
    }
    // `{{name}}`.
    let mut out = String::new();
    let mut at = 0;
    while at < sections.len() {
        if let Some((key, end)) = tag(&sections, at, "") {
            match value(key)? {
                PromptVar::Text(text) => out.push_str(text),
                PromptVar::Flag(_) => {
                    return Err(format!(
                        "Tool description {name}: {{{{{key}}}}} needs text, not a flag"
                    ));
                }
            }
            at = end;
            continue;
        }
        let c = sections[at..].chars().next().expect("a character");
        out.push(c);
        at += c.len_utf8();
    }
    Ok(out)
}

/// The description of a tool that takes no values.
pub fn fixed_prompt(name: &str) -> String {
    tool_prompt(name, &[]).expect("a tool description without placeholders")
}

#[cfg(test)]
mod tests {
    use super::*;
    use PromptVar::{Flag, Text};

    #[test]
    fn registers_every_description_file_and_nothing_else() {
        let dir = concat!(env!("CARGO_MANIFEST_DIR"), "/prompts/tools");
        let mut files: Vec<String> = std::fs::read_dir(dir)
            .unwrap()
            .filter_map(|entry| {
                let name = entry.unwrap().file_name().to_string_lossy().into_owned();
                name.strip_suffix(".md").map(str::to_owned)
            })
            .collect();
        files.sort();
        let mut names: Vec<String> = tool_prompt_names().map(str::to_owned).collect();
        names.sort();
        assert_eq!(names, files);
    }

    #[test]
    fn fills_values_and_keeps_flagged_text_only_when_the_flag_is_on() {
        let today = tool_prompt("web_search", &[("today", Text("2026-10-02"))]).unwrap();
        assert!(today.contains("(today is 2026-10-02)"));
        assert!(!today.contains("{{"));
        let all = tool_prompt(
            "memory_search",
            &[("recall", Flag(true)), ("delegation", Flag(true))],
        )
        .unwrap();
        assert!(all.ends_with(
            "are marked. Open a note's sources with recall (12-hex ids). See a delegation with delegation_status."
        ));
        let none = tool_prompt(
            "memory_search",
            &[("recall", Flag(false)), ("delegation", Flag(false))],
        )
        .unwrap();
        assert!(none.ends_with("superseded ones are marked."));
        let one = tool_prompt(
            "memory_search",
            &[("recall", Flag(false)), ("delegation", Flag(true))],
        )
        .unwrap();
        assert!(one.ends_with("are marked. See a delegation with delegation_status."));
        assert!(
            tool_prompt("recall", &[("chatSearch", Flag(false))])
                .unwrap()
                .contains("from an earlier session. Use when")
        );
    }

    #[test]
    fn refuses_a_missing_value_a_flag_for_text_and_an_unknown_tool() {
        assert!(
            tool_prompt("web_search", &[])
                .unwrap_err()
                .contains("no value for {{today}}")
        );
        assert!(
            tool_prompt("web_search", &[("today", Flag(true))])
                .unwrap_err()
                .contains("needs text")
        );
        assert!(
            tool_prompt("memory_search", &[("recall", Flag(true))])
                .unwrap_err()
                .contains("no value for {{delegation}}")
        );
        assert!(
            tool_prompt("nope", &[])
                .unwrap_err()
                .contains("No description for tool nope")
        );
    }

    #[test]
    fn leaves_no_placeholder_in_a_description_without_values() {
        for name in tool_prompt_names() {
            let Ok(text) = tool_prompt(name, &[]) else {
                continue;
            };
            assert!(!text.contains("{{") && !text.contains("}}"), "{name}");
            assert_eq!(text, super::super::js::trim(&text), "{name}");
        }
    }
}
