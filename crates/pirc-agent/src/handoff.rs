//! Validated session-local handoffs. Legacy summaries remain inherited evidence.
use crate::session_store::{EntryData, SessionEntry};
use pirc_protocol::{Message, UserBlock, UserContent};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{HashMap, HashSet};
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SourceRef {
    pub session_id: String,
    pub entry_id: String,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Fact {
    pub text: String,
    pub sources: Vec<SourceRef>,
}
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct State {
    pub goal: Vec<Fact>,
    pub active_constraints: Vec<Fact>,
    pub progress: Vec<Fact>,
    pub decisions: Vec<Fact>,
    pub open_questions: Vec<Fact>,
    pub next_steps: Vec<Fact>,
}
impl State {
    pub fn groups(&self) -> [(&str, &[Fact]); 6] {
        [
            ("Goal", &self.goal),
            ("Active constraints", &self.active_constraints),
            ("Progress", &self.progress),
            ("Decisions", &self.decisions),
            ("Open questions", &self.open_questions),
            ("Next steps", &self.next_steps),
        ]
    }
    pub fn facts(&self) -> impl Iterator<Item = &Fact> {
        self.groups().into_iter().flat_map(|(_, f)| f)
    }
    pub fn valid(&self) -> bool {
        self.groups().iter().all(|(_, g)| g.len() <= 100)
            && self.facts().all(|f| {
                !f.text.is_empty()
                    && crate::messages::js::utf16_len(&f.text) <= 16000
                    && f.sources.len() <= 100
                    && f.sources
                        .iter()
                        .all(|r| key(&r.session_id) && key(&r.entry_id))
            })
    }
    pub fn neutralize(&mut self) {
        for group in [
            &mut self.goal,
            &mut self.active_constraints,
            &mut self.progress,
            &mut self.decisions,
            &mut self.open_questions,
            &mut self.next_steps,
        ] {
            for f in group {
                f.text = crate::features::memory::text::neutralize_headers(
                    &crate::redact::redact_secrets(&f.text),
                );
            }
        }
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Handoff {
    pub kind: String,
    pub version: u8,
    #[serde(default)]
    pub text_only: bool,
    pub job_id: String,
    pub previous_snapshot_id: Option<String>,
    pub source_from_entry_id: String,
    pub legacy_base_id: Option<String>,
    pub state: State,
}
pub fn key(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 128
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}
pub fn render(h: &Handoff) -> String {
    let mut out = String::new();
    if h.text_only {
        out.push_str("Text and tool metadata handoff; non-text pixels and private thinking were not interpreted.\n\n")
    }
    if let Some(id) = &h.legacy_base_id {
        out.push_str(&format!(
            "Inherited legacy base: {id}; its prefix has not been revalidated.\n\n"
        ))
    }
    out.push_str(
        &h.state
            .groups()
            .iter()
            .map(|(title, facts)| {
                format!(
                    "## {title}\n{}",
                    if facts.is_empty() {
                        "(none)".into()
                    } else {
                        facts
                            .iter()
                            .map(|f| {
                                format!(
                                    "- {}{}",
                                    f.text,
                                    if f.sources.is_empty() {
                                        String::new()
                                    } else {
                                        format!(
                                            " [sources: {}]",
                                            f.sources
                                                .iter()
                                                .map(|r| format!("{}:{}", r.session_id, r.entry_id))
                                                .collect::<Vec<_>>()
                                                .join(", ")
                                        )
                                    }
                                )
                            })
                            .collect::<Vec<_>>()
                            .join("\n")
                    }
                )
            })
            .collect::<Vec<_>>()
            .join("\n\n"),
    );
    out
}
pub fn details(e: &SessionEntry) -> Option<Handoff> {
    match &e.data {
        EntryData::Compaction {
            details: Some(v), ..
        } => serde_json::from_value(v.clone()).ok(),
        _ => None,
    }
}
pub fn valid_snapshots(branch: &[SessionEntry]) -> Vec<&SessionEntry> {
    let session = match branch.first().map(|e| &e.data) {
        Some(EntryData::Session { session_id, .. }) => session_id,
        _ => return Vec::new(),
    };
    let positions: HashMap<_, _> = branch
        .iter()
        .enumerate()
        .map(|(i, e)| (e.id.as_str(), i))
        .collect();
    let mut valid: Vec<&SessionEntry> = Vec::new();
    for (at, e) in branch.iter().enumerate() {
        let EntryData::Compaction {
            summary,
            first_kept_entry_id,
            tokens_before: _,
            details: value,
        } = &e.data
        else {
            continue;
        };
        let cut = positions.get(first_kept_entry_id.as_str()).copied();
        if summary.trim().is_empty()
            || (first_kept_entry_id != "end"
                && cut.is_none_or(|i| i >= at || !matches!(branch[i].data, EntryData::Message(_))))
        {
            continue;
        }
        let kind = value.as_ref().and_then(|d| d.get("kind"));
        if kind.is_some_and(|k| k != "handoff") {
            continue;
        }
        if kind.is_none() {
            valid.push(e);
            continue;
        }
        let Some(h) = details(e) else { continue };
        let Some(cut) = cut else { continue };
        if h.kind != "handoff" || h.version != 1 || !key(&h.job_id) || !h.state.valid() {
            continue;
        }
        let previous = valid.last().copied();
        let expected_start = previous
            .and_then(|p| match &p.data {
                EntryData::Compaction {
                    first_kept_entry_id,
                    ..
                } if first_kept_entry_id == "end" => branch
                    .iter()
                    .skip(positions[p.id.as_str()] + 1)
                    .find(|e| matches!(e.data, EntryData::Message(_)))
                    .map(|e| e.id.as_str()),
                EntryData::Compaction {
                    first_kept_entry_id,
                    ..
                } => Some(first_kept_entry_id.as_str()),
                _ => None,
            })
            .or_else(|| {
                if previous.is_none() {
                    branch
                        .iter()
                        .find(|e| matches!(e.data, EntryData::Message(_)))
                        .map(|e| e.id.as_str())
                } else {
                    None
                }
            });
        let legacy = previous.and_then(|p| {
            details(p)
                .map(|h| h.legacy_base_id)
                .unwrap_or_else(|| Some(p.id.clone()))
        });
        if h.previous_snapshot_id.as_deref() != previous.map(|e| e.id.as_str())
            || Some(h.source_from_entry_id.as_str()) != expected_start
            || h.legacy_base_id != legacy
            || render(&h) != *summary
        {
            continue;
        }
        if positions
            .get(h.source_from_entry_id.as_str())
            .is_none_or(|i| *i >= cut)
        {
            continue;
        }
        if h.state.facts().flat_map(|f| &f.sources).any(|r| {
            r.session_id != *session
                || positions
                    .get(r.entry_id.as_str())
                    .is_none_or(|i| *i >= cut || !public(&branch[*i]))
        }) {
            continue;
        }
        let from = positions[h.source_from_entry_id.as_str()];
        if boundaries_before(&branch[from..cut], &branch[cut..]).is_err() {
            continue;
        }
        let inherited: HashSet<_> = previous
            .and_then(details)
            .map(|h| h.state.facts().flat_map(|f| f.sources.clone()).collect())
            .unwrap_or_default();
        if h.state.facts().flat_map(|f| &f.sources).any(|r| {
            positions
                .get(r.entry_id.as_str())
                .is_some_and(|i| *i < from)
                && !inherited.contains(r)
        }) {
            continue;
        }
        valid.push(e);
    }
    valid
}
pub fn public(e: &SessionEntry) -> bool {
    matches!(&e.data, EntryData::Message(_))
        || matches!(&e.data,EntryData::Custom{custom_type,..}if custom_type=="ptc.operation")
}
pub use crate::tool_history::issued;
fn inspect(
    entries: &[SessionEntry],
    following: &[SessionEntry],
) -> Result<(HashSet<usize>, crate::tool_history::Groups), String> {
    inspect_classified(entries, following, false)
}
fn inspect_classified(
    entries: &[SessionEntry],
    following: &[SessionEntry],
    exclude_ambiguity: bool,
) -> Result<(HashSet<usize>, crate::tool_history::Groups), String> {
    let mut groups = crate::tool_history::Groups::for_entries(entries.iter().chain(following));
    let mut safe = HashSet::new();
    for (i, e) in entries.iter().enumerate() {
        let before = groups.idle();
        let is_safe = match &e.data {
            EntryData::Message(m) => groups.message(m)?,
            EntryData::Custom { custom_type, data } if custom_type == "ptc.operation" => {
                if exclude_ambiguity {
                    groups.source_operation(data)?;
                } else {
                    groups.operation(data)?;
                }
                before
            }
            _ => {
                groups.other();
                before
            }
        };
        if is_safe {
            safe.insert(i);
        }
    }
    // A task closes only calls without a matching recorded result in the retained tail.
    if following
        .first()
        .and_then(SessionEntry::message)
        .is_some_and(crate::tool_history::task_start)
    {
        groups.interrupt();
    }
    if groups.idle() {
        safe.insert(entries.len());
    }
    Ok((safe, groups))
}
pub fn candidate_boundaries(entries: &[SessionEntry]) -> Result<HashSet<usize>, String> {
    inspect(entries, &[]).map(|(safe, _)| safe)
}
pub fn boundaries(entries: &[SessionEntry]) -> Result<HashSet<usize>, String> {
    boundaries_before(entries, &[])
}
pub fn boundaries_before(
    entries: &[SessionEntry],
    following: &[SessionEntry],
) -> Result<HashSet<usize>, String> {
    let (safe, groups) = inspect(entries, following)?;
    if !groups.idle() {
        return Err("handoff_incomplete_tool_group".into());
    }
    Ok(safe)
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Source {
    pub entry_id: String,
    pub role: String,
    pub timestamp: u64,
    pub text: String,
    pub derived: bool,
}
pub fn replay_tool(name: &str) -> bool {
    matches!(
        name,
        "recall" | "memory_search" | "history_read" | "history_search"
    )
}
fn text_parts(value: &Value) -> String {
    if let Some(s) = value.as_str() {
        return s.into();
    }
    value
        .as_array()
        .map(|parts| {
            parts
                .iter()
                .filter_map(|p| match p["type"].as_str() {
                    Some("thinking") => None,
                    Some("text") => Some(p["text"].as_str().unwrap_or("").into()),
                    Some("toolCall") => Some(format!(
                        "[tool call {}: {}]",
                        p["name"].as_str().unwrap_or(""),
                        p["arguments"]
                    )),
                    _ => Some("[non-text content omitted]".into()),
                })
                .collect::<Vec<String>>()
                .join("\n")
        })
        .unwrap_or_default()
}
pub fn sources(branch: &[SessionEntry]) -> Vec<Source> {
    sources_before(branch, &[])
}
pub fn sources_before(branch: &[SessionEntry], following: &[SessionEntry]) -> Vec<Source> {
    let groups = inspect(branch, following).ok().map(|(_, groups)| groups);
    sources_with_groups(branch, groups.as_ref(), |_| true)
}
/// One classification supplies both compression boundaries and Work evidence origins.
/// A late result/operation belongs to the human admission that issued its parent.
/// This is a read-time view; no source or coverage metadata is persisted.
pub struct SourceHistory<'a> {
    pub boundaries: HashSet<usize>,
    pub origins: HashMap<String, usize>,
    pub blocked: HashSet<usize>,
    branch: &'a [SessionEntry],
    groups: crate::tool_history::Groups,
}
impl SourceHistory<'_> {
    pub fn sources(&self, include: impl Fn(usize, usize) -> bool) -> Vec<Source> {
        sources_with_groups(self.branch, Some(&self.groups), |at| {
            let admission = self.origins[&self.branch[at].id];
            !self.blocked.contains(&admission) && include(at, admission)
        })
    }
}
pub fn source_history(branch: &[SessionEntry]) -> Result<SourceHistory<'_>, String> {
    let (boundaries, groups) = inspect_classified(branch, &[], true)?;
    let mut admissions = Vec::with_capacity(branch.len());
    let mut admission = 0;
    for (at, entry) in branch.iter().enumerate() {
        if matches!(entry.data, EntryData::Message(Message::User { .. })) {
            admission = at;
        }
        admissions.push(admission);
    }
    // Exclude whole admissions from the earliest possible parent through the
    // ambiguous operation. Later independent admissions retain their own evidence.
    let blocked = groups
        .ambiguous_spans()
        .flat_map(|span| admissions[span].iter().copied())
        .collect();
    let origins = branch
        .iter()
        .enumerate()
        .map(|(at, entry)| {
            let origin = groups.source_parent(at).map_or(at, |(parent, _)| parent);
            (entry.id.clone(), admissions[origin])
        })
        .collect();
    Ok(SourceHistory {
        boundaries,
        origins,
        blocked,
        branch,
        groups,
    })
}
fn sources_with_groups(
    branch: &[SessionEntry],
    groups: Option<&crate::tool_history::Groups>,
    include: impl Fn(usize) -> bool,
) -> Vec<Source> {
    branch
        .iter()
        .enumerate()
        .filter_map(|(entry_at, e)| {
            if !include(entry_at) {
                return None;
            }
            let (role, mut text, derived) = match &e.data {
                EntryData::Message(m) => {
                    let v = serde_json::to_value(m).ok()?;
                    match m {
                        Message::User { .. } => ("user".into(), text_parts(&v["content"]), false),
                        Message::Assistant(_) => (
                            v["role"].as_str()?.to_owned(),
                            format!(
                                "[stopReason: {}]\n{}",
                                v["stopReason"],
                                text_parts(&v["content"])
                            ),
                            false,
                        ),
                        Message::ToolResult { tool_name, .. } => (
                            format!("tool:{tool_name}"),
                            format!("[isError: {}]\n{}", v["isError"], text_parts(&v["content"])),
                            replay_tool(tool_name)
                                || v.get("details").is_some_and(|d| {
                                    d.get("memoryReplay") == Some(&Value::Bool(true))
                                }),
                        ),
                        Message::Custom {
                            custom_type,
                            content,
                            ..
                        } => (format!("custom:{custom_type}"), content.clone(), true),
                        _ => return None,
                    }
                }
                EntryData::Custom { custom_type, data } if custom_type == "ptc.operation" => {
                    let name = data["toolName"].as_str()?;
                    let parent = groups.and_then(|g| g.source_parent(entry_at)).and_then(|(at,_)| branch.get(at)).map(|e| format!("; parent entry: {}", e.id)).unwrap_or_default();
                    (
                        format!("operation:{name}"),
                        format!(
                            "[parent tool call: {}{}; operation: {}]\n{}\n{}",
                            data["parentToolCallId"].as_str()?,
                            parent,
                            data["toolCallId"].as_str()?,
                            data.get("args").unwrap_or(&Value::Null),
                            text_parts(&data["content"])
                        ),
                        replay_tool(name)
                            || data.get("memoryReplay") == Some(&Value::Bool(true))
                            || data["details"]["memoryReplay"] == true,
                    )
                }
                _ => return None,
            };
            if let EntryData::Message(m) = &e.data {
                for (call_at, (id,_)) in issued(m).into_iter().enumerate() {
                    if groups.is_some_and(|g| g.interrupted.contains(&(entry_at, call_at))) {
                        text.push_str(&format!("\n[Tool call {id} was interrupted before a recorded result; outcome unknown. No successful action is established.]"));
                    }
                }
            }
            Some(Source {
                entry_id: e.id.clone(),
                role,
                timestamp: e.timestamp,
                text: crate::features::memory::text::neutralize_headers(
                    &crate::redact::redact_secrets(&text),
                ),
                derived,
            })
        })
        .collect()
}
#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Resolution {
    pub text: String,
    pub source: SourceRef,
    pub quote: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Output {
    pub state: State,
    #[serde(default)]
    pub resolved_constraints: Vec<Resolution>,
}
pub struct Validation<'a> {
    pub previous: Option<&'a State>,
    pub constraints: &'a HashMap<String, usize>,
    pub complete: &'a HashSet<SourceRef>,
    pub allowed: &'a HashSet<SourceRef>,
    pub changes: &'a [Resolution],
    pub branch: &'a [SessionEntry],
    pub session: &'a str,
    pub range: std::ops::Range<usize>,
    pub legacy: bool,
}
pub fn validate_state(next: &State, context: Validation<'_>) -> Result<(), String> {
    let Validation {
        previous,
        constraints,
        complete,
        allowed,
        changes,
        branch,
        session,
        range,
        legacy,
    } = context;
    if !next.valid() || !next.facts().any(|_| true) {
        return Err("handoff_invalid_output".into());
    }
    for fact in next.facts() {
        if fact.sources.is_empty()
            && !legacy
            && !previous.is_some_and(|p| {
                p.facts()
                    .any(|f| f.text == fact.text && f.sources.is_empty())
            })
        {
            return Err("handoff_invalid_source".into());
        }
        if fact.sources.iter().any(|r| !allowed.contains(r)) {
            return Err("handoff_invalid_source".into());
        }
    }
    for (text, at) in constraints {
        if next.active_constraints.iter().any(|f| &f.text == text) {
            continue;
        }
        let change = changes
            .iter()
            .find(|c| &c.text == text)
            .ok_or("handoff_constraint_lost")?;
        let i = branch
            .iter()
            .position(|e| e.id == change.source.entry_id)
            .ok_or("handoff_constraint_lost")?;
        let original = match &branch[i].data {
            EntryData::Message(Message::User { content, .. }) => match content {
                UserContent::Text(t) => t.clone(),
                UserContent::Blocks(parts) => parts
                    .iter()
                    .filter_map(|p| {
                        if let UserBlock::Text { text, .. } = p {
                            Some(text.as_str())
                        } else {
                            None
                        }
                    })
                    .collect::<Vec<_>>()
                    .join("\n"),
            },
            _ => return Err("handoff_constraint_lost".into()),
        };
        if change.source.session_id != session
            || !complete.contains(&change.source)
            || !range.contains(&i)
            || i <= *at
            || change.quote.trim().is_empty()
            || !original.contains(&change.quote)
            || !next
                .decisions
                .iter()
                .any(|f| f.text == change.quote && f.sources.contains(&change.source))
        {
            return Err("handoff_constraint_lost".into());
        }
    }
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn state_is_strict_and_round_trips() {
        let state = State {
            goal: vec![Fact {
                text: "Keep context".into(),
                sources: vec![],
            }],
            ..State::default()
        };
        assert!(state.valid());
        assert!(serde_json::from_value::<State>(serde_json::json!({"bad":[]})).is_err());
        let h = Handoff {
            kind: "handoff".into(),
            version: 1,
            text_only: true,
            job_id: "h_123".into(),
            previous_snapshot_id: None,
            source_from_entry_id: "first".into(),
            legacy_base_id: None,
            state,
        };
        assert!(render(&h).contains("Keep context"));
    }
}

#[cfg(test)]
mod constraint_tests {
    use super::*;
    use serde_json::json;
    fn user(id: &str, text: &str) -> SessionEntry {
        SessionEntry::from_value(json!({"type":"message","id":id,"parentId":null,"timestamp":1,"message":{"role":"user","content":text,"timestamp":1}})).unwrap()
    }
    #[test]
    fn only_complete_later_original_human_quotes_can_remove_a_constraint() {
        let old_ref = SourceRef {
            session_id: "s".into(),
            entry_id: "old".into(),
        };
        let new_ref = SourceRef {
            session_id: "s".into(),
            entry_id: "new".into(),
        };
        let old = State {
            active_constraints: vec![Fact {
                text: "Do not deploy".into(),
                sources: vec![old_ref.clone()],
            }],
            ..State::default()
        };
        let next = State {
            decisions: vec![Fact {
                text: "You may deploy staging now".into(),
                sources: vec![new_ref.clone()],
            }],
            ..State::default()
        };
        let branch = vec![
            user("old", "Do not deploy"),
            user("new", "You may deploy staging now"),
        ];
        let constraints = HashMap::from([("Do not deploy".into(), 0)]);
        let allowed = HashSet::from([old_ref, new_ref.clone()]);
        let complete = HashSet::from([new_ref.clone()]);
        let changes = vec![Resolution {
            text: "Do not deploy".into(),
            source: new_ref,
            quote: "You may deploy staging now".into(),
        }];
        let validate = |complete: &HashSet<SourceRef>, established: &HashMap<String, usize>| {
            validate_state(
                &next,
                Validation {
                    previous: Some(&old),
                    constraints: established,
                    complete,
                    allowed: &allowed,
                    changes: &changes,
                    branch: &branch,
                    session: "s",
                    range: 0..2,
                    legacy: false,
                },
            )
        };
        assert!(validate(&complete, &constraints).is_ok());
        assert_eq!(
            validate(&HashSet::new(), &constraints).unwrap_err(),
            "handoff_constraint_lost"
        );
        assert_eq!(
            validate(&complete, &HashMap::from([("Do not deploy".into(), 1)])).unwrap_err(),
            "handoff_constraint_lost"
        );
    }
}
