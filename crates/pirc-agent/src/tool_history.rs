//! Shared task admissions and issued-tool classification. Recovery is a projection,
//! never a fabricated successful result or a mutation of the original journal.
use pirc_agent_loop::history::Pairing;
pub use pirc_agent_loop::history::issued;
use pirc_protocol::Message;
use serde_json::Value;
use std::collections::{HashMap, HashSet};

pub fn task_start(message: &Message) -> bool {
    matches!(message, Message::User { .. })
        || matches!(
            message,
            Message::Custom { custom_type, .. } if custom_type == "scheduled-run"
        )
}
/// Calls are identified by their occurrence, because providers may reuse IDs
/// after a completed group. An unfinished/unknown occurrence keeps its ID reserved.
type CallKey = (usize, usize);
#[derive(Clone, Copy)]
enum Event<'a> {
    Message(&'a Message),
    Operation(&'a Value),
    Other,
}
fn event(entry: &crate::session_store::SessionEntry) -> Event<'_> {
    use crate::session_store::EntryData;
    match &entry.data {
        EntryData::Message(m) => Event::Message(m),
        EntryData::Custom { custom_type, data } if custom_type == "ptc.operation" => {
            Event::Operation(data)
        }
        _ => Event::Other,
    }
}
#[derive(Default)]
struct Evidence<'a> {
    calls: HashMap<CallKey, (&'a str, &'a str)>,
    results: HashMap<CallKey, (usize, &'a Message)>,
    operation_parents: HashMap<usize, CallKey>,
    ambiguous_operations: HashMap<usize, Vec<CallKey>>,
    last_operations: HashMap<CallKey, usize>,
}
impl<'a> Evidence<'a> {
    fn collect(events: impl IntoIterator<Item = Event<'a>>) -> Self {
        let events: Vec<_> = events.into_iter().collect();
        let pairing = Pairing::collect(events.iter().map(|event| match event {
            Event::Message(m) => Some(*m),
            Event::Operation(_) | Event::Other => None,
        }));
        let mut evidence = Self {
            calls: pairing.calls,
            results: pairing.results,
            ..Self::default()
        };
        // The outer result already stores the stable executionId. Index it
        // before associating operations, including ones arriving after that result.
        let mut executions = HashMap::new();
        let mut call_executions = HashMap::new();
        for (&key, &(_, m)) in &evidence.results {
            if let Message::ToolResult {
                tool_name, details, ..
            } = m
                && tool_name == "ptc"
                && let Some(id) = details
                    .as_ref()
                    .and_then(|d| d["executionId"].as_str())
                    .filter(|id| !id.is_empty())
            {
                call_executions.insert(key, id);
                executions
                    .entry(id)
                    .and_modify(|old| *old = None)
                    .or_insert(Some(key));
            }
        }
        let mut active = HashMap::new();
        for (at, event) in events.iter().copied().enumerate() {
            match event {
                Event::Message(m) => {
                    for (i, (id, _)) in issued(m).into_iter().enumerate() {
                        let key = (at, i);
                        if evidence.calls.contains_key(&key) {
                            active.insert(id, key);
                        }
                    }
                    if let Message::ToolResult { tool_call_id, .. } = m
                        && active.get(tool_call_id.as_str()).is_some_and(|key| {
                            evidence
                                .results
                                .get(key)
                                .is_some_and(|(result_at, _)| *result_at == at)
                        })
                    {
                        active.remove(tool_call_id.as_str());
                    }
                }
                Event::Operation(data) => {
                    let Some(parent) = data["parentToolCallId"].as_str() else {
                        continue;
                    };
                    let execution = data["toolCallId"]
                        .as_str()
                        .and_then(|id| id.rsplit_once(":op"))
                        .filter(|(_, n)| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()))
                        .map(|(id, _)| id);
                    let key = if let Some(known) = execution.and_then(|id| executions.get(id)) {
                        *known // A duplicated execution identity remains ambiguous.
                    } else if execution.is_none() && active.contains_key(parent) {
                        // Bare legacy operation IDs retain chronological matching.
                        active.get(parent).copied()
                    } else {
                        // An unknown execution prefix must consider legacy parents,
                        // including an active occurrence without its outer result.
                        // Do not let arrival order turn uncertainty into a new parent.
                        let parents: Vec<_> = evidence
                            .calls
                            .iter()
                            .filter(|(key, (id, name))| {
                                key.0 < at
                                    && *id == parent
                                    && *name == "ptc"
                                    && !call_executions.contains_key(key)
                            })
                            .map(|(key, _)| *key)
                            .collect();
                        // Ambiguous late evidence also makes a cut through any of
                        // its possible parents unsafe, until existing results resolve it.
                        for key in &parents {
                            evidence.last_operations.insert(*key, at);
                        }
                        if parents.len() > 1 {
                            evidence.ambiguous_operations.insert(at, parents);
                            None
                        } else {
                            parents.first().copied()
                        }
                    };
                    if let Some(key) = key
                        && key.0 < at
                        && evidence
                            .calls
                            .get(&key)
                            .is_some_and(|(id, name)| *id == parent && *name == "ptc")
                    {
                        evidence.operation_parents.insert(at, key);
                        evidence.last_operations.insert(key, at);
                    }
                }
                Event::Other => {}
            }
        }
        evidence
    }
}
struct Pending {
    id: String,
    name: String,
    completed: bool,
    operations: HashSet<String>,
}
#[derive(Default)]
pub(crate) struct Groups {
    at: usize,
    pending: HashMap<CallKey, Pending>,
    unfinished: HashMap<String, CallKey>,
    results: HashSet<CallKey>,
    source_parents: Option<HashMap<usize, CallKey>>,
    ambiguous_operations: HashMap<usize, Vec<CallKey>>,
    last_operations: HashMap<CallKey, usize>,
    pub interrupted: HashSet<CallKey>,
}
impl Groups {
    fn from_evidence(evidence: Evidence<'_>) -> Self {
        let mut parents = evidence.operation_parents;
        parents.extend(evidence.results.iter().map(|(key, (at, _))| (*at, *key)));
        Self {
            results: evidence.results.into_keys().collect(),
            source_parents: Some(parents),
            ambiguous_operations: evidence.ambiguous_operations,
            last_operations: evidence.last_operations,
            ..Self::default()
        }
    }
    pub fn for_messages<'a>(messages: impl IntoIterator<Item = &'a Message>) -> Self {
        Self::from_evidence(Evidence::collect(messages.into_iter().map(Event::Message)))
    }
    pub fn for_entries<'a>(
        entries: impl IntoIterator<Item = &'a crate::session_store::SessionEntry>,
    ) -> Self {
        Self::from_evidence(Evidence::collect(entries.into_iter().map(event)))
    }
    pub fn interrupt(&mut self) {
        self.pending.retain(|key, pending| {
            if (!pending.completed && self.results.contains(key))
                || self
                    .last_operations
                    .get(key)
                    .is_some_and(|at| *at >= self.at)
            {
                true
            } else {
                if !pending.completed {
                    self.interrupted.insert(*key);
                }
                false
            }
        });
    }
    pub fn idle(&self) -> bool {
        self.pending.is_empty()
    }
    pub fn other(&mut self) {
        self.at += 1;
    }
    pub fn source_parent(&self, at: usize) -> Option<CallKey> {
        self.source_parents.as_ref()?.get(&at).copied()
    }
    fn close_completed(&mut self, key: CallKey) {
        if self.pending.get(&key).is_some_and(|p| p.completed)
            && self
                .last_operations
                .get(&key)
                .is_none_or(|at| *at < self.at)
        {
            self.pending.remove(&key);
        }
    }
    pub fn message(&mut self, m: &Message) -> Result<bool, String> {
        if task_start(m) {
            self.interrupt();
        }
        let safe = self.idle();
        let at = self.at;
        self.at += 1;
        for (i, (id, name)) in issued(m).into_iter().enumerate() {
            if self.unfinished.contains_key(id) {
                return Err("handoff_duplicate_tool_call".into());
            }
            let key = (at, i);
            self.unfinished.insert(id.into(), key);
            self.pending.insert(
                key,
                Pending {
                    id: id.into(),
                    name: name.into(),
                    completed: false,
                    operations: HashSet::new(),
                },
            );
        }
        if let Message::ToolResult {
            tool_call_id,
            tool_name,
            ..
        } = m
        {
            let key = *self
                .unfinished
                .get(tool_call_id)
                .ok_or("handoff_unmatched_tool_result")?;
            let pending = self
                .pending
                .get_mut(&key)
                .filter(|p| p.name == *tool_name)
                .ok_or("handoff_unmatched_tool_result")?;
            pending.completed = true;
            self.unfinished.remove(tool_call_id);
            self.close_completed(key);
        }
        Ok(safe)
    }
    pub fn ambiguous_spans(&self) -> impl Iterator<Item = std::ops::RangeInclusive<usize>> {
        self.ambiguous_operations
            .iter()
            .filter_map(|(at, parents)| {
                parents.iter().map(|key| key.0).min().map(|from| from..=*at)
            })
    }
    pub fn operation(&mut self, data: &Value) -> Result<(), String> {
        self.operation_inner(data, false)
    }
    /// Work may pass an excluded ambiguous span without choosing a parent.
    /// Strict compression validation and real orphan/identity errors are unchanged.
    pub fn source_operation(&mut self, data: &Value) -> Result<(), String> {
        self.operation_inner(data, true)
    }
    fn operation_inner(&mut self, data: &Value, exclude_ambiguity: bool) -> Result<(), String> {
        let at = self.at;
        self.at += 1;
        let parent = data["parentToolCallId"]
            .as_str()
            .ok_or("handoff_unmatched_operation")?;
        let id = data["toolCallId"]
            .as_str()
            .ok_or("handoff_unmatched_operation")?;
        if exclude_ambiguity && let Some(parents) = self.ambiguous_operations.get(&at).cloned() {
            if parents.iter().any(|key| {
                !self
                    .pending
                    .get(key)
                    .is_some_and(|p| p.id == parent && p.name == "ptc")
            }) {
                return Err("handoff_unmatched_operation".into());
            }
            // No operation is attached to a parent or treated as successful.
            // All possible spans stay open through their last recorded operation;
            // only completed calls can close here. Missing results stay unknown.
            for key in parents {
                self.close_completed(key);
            }
            return Ok(());
        }
        let key = self
            .source_parents
            .as_ref()
            .map_or_else(
                || self.unfinished.get(parent).copied(),
                |parents| parents.get(&at).copied(),
            )
            .ok_or("handoff_unmatched_operation")?;
        let pending = self
            .pending
            .get_mut(&key)
            .ok_or("handoff_unmatched_operation")?;
        if pending.id != parent || pending.name != "ptc" || !pending.operations.insert(id.into()) {
            return Err("handoff_unmatched_operation".into());
        }
        self.close_completed(key);
        Ok(())
    }
}
pub fn message_boundaries(entries: &[(String, Message)]) -> Result<HashSet<usize>, String> {
    let mut groups = Groups::for_messages(entries.iter().map(|(_, m)| m));
    let mut safe = HashSet::new();
    for (i, (_, m)) in entries.iter().enumerate() {
        if groups.message(m)? {
            safe.insert(i);
        }
    }
    if groups.idle() {
        safe.insert(entries.len());
    }
    Ok(safe)
}
#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    fn call(reason: &str) -> Message {
        serde_json::from_value(json!({"role":"assistant","content":[{"type":"toolCall","id":"call","name":"ptc","arguments":{}}],"api":"x","provider":"x","model":"x","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0},"stopReason":reason,"timestamp":1})).unwrap()
    }
    fn user() -> Message {
        Message::User {
            content: pirc_protocol::UserContent::Text("next".into()),
            timestamp: 2,
        }
    }
    fn result(name: &str) -> Message {
        Message::ToolResult {
            tool_call_id: "call".into(),
            tool_name: name.into(),
            content: vec![],
            details: None,
            is_error: false,
            timestamp: 1,
        }
    }
    #[test]
    fn only_tool_use_issues_calls_and_task_admission_closes_unknown_attempts() {
        let mut groups = Groups::default();
        groups.message(&call("aborted")).unwrap();
        assert!(groups.idle());
        groups.message(&call("toolUse")).unwrap();
        assert!(!groups.idle());
        groups
            .operation(&json!({"parentToolCallId":"call","toolCallId":"nested"}))
            .unwrap();
        groups.message(&user()).unwrap();
        assert!(groups.idle());
        assert!(groups.interrupted.contains(&(1, 0)));
        assert!(
            groups
                .operation(&json!({"parentToolCallId":"call","toolCallId":"later"}))
                .is_err()
        );
        assert!(groups.message(&call("toolUse")).is_err());
    }
    #[test]
    fn reports_do_not_close_tools_and_mismatched_results_remain_invalid() {
        let mut groups = Groups::default();
        groups.message(&call("toolUse")).unwrap();
        groups
            .message(&Message::Custom {
                custom_type: "custom-report".into(),
                content: "report".into(),
                display: true,
                details: None,
                timestamp: 1,
            })
            .unwrap();
        assert!(!groups.idle());
        assert!(groups.message(&result("bash")).is_err());
        assert!(Groups::default().message(&result("ptc")).is_err());
    }
    #[test]
    fn cut_points_keep_latest_admission_despite_interleaved_reports_and_open_tools() {
        let report = Message::Custom {
            custom_type: "custom-report".into(),
            content: "report".into(),
            display: true,
            details: None,
            timestamp: 3,
        };
        let entries = vec![
            ("first".into(), user()),
            ("tool".into(), call("toolUse")),
            ("next".into(), user()),
            ("report".into(), report),
        ];
        assert_eq!(
            crate::compaction::find_cut_point(&entries, 0).as_deref(),
            Some("next")
        );
        let open = vec![("first".into(), user()), ("tool".into(), call("toolUse"))];
        assert!(crate::compaction::find_cut_point(&open, 0).is_none());
    }
}

#[cfg(test)]
mod source_projection_tests {
    use super::*;
    use crate::session_store::{EntryData, SessionEntry};
    #[test]
    fn older_interruption_remains_visible_while_a_later_tool_is_running() {
        let user = || Message::User {
            content: pirc_protocol::UserContent::Text("next".into()),
            timestamp: 1,
        };
        let call = |id: &str| {
            serde_json::from_value::<Message>(serde_json::json!({"role":"assistant","content":[{"type":"toolCall","id":id,"name":"ptc","arguments":{}}],"api":"x","provider":"x","model":"x","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0},"stopReason":"toolUse","timestamp":1})).unwrap()
        };
        let branch = vec![user(), call("interrupted"), user(), call("active")]
            .into_iter()
            .enumerate()
            .map(|(i, m)| SessionEntry {
                id: format!("e{i}"),
                parent_id: None,
                timestamp: 1,
                data: EntryData::Message(m),
            })
            .collect::<Vec<_>>();
        assert!(crate::handoff::boundaries(&branch).is_err());
        let sources = crate::handoff::sources(&branch);
        assert!(
            sources
                .iter()
                .any(|s| s.entry_id == "e1" && s.text.contains("outcome unknown"))
        );
        assert!(
            !sources
                .iter()
                .any(|s| s.entry_id == "e3" && s.text.contains("was interrupted"))
        );
    }
}

#[cfg(test)]
mod interleaving_tests {
    use super::*;
    use crate::session_store::{EntryData, SessionEntry};
    #[test]
    fn admitted_tasks_never_split_completed_tool_groups_or_erase_real_results() {
        for task in [
            Message::User {
                content: pirc_protocol::UserContent::Text("next task".into()),
                timestamp: 2,
            },
            Message::Custom {
                custom_type: "scheduled-run".into(),
                content: "next task".into(),
                display: true,
                details: None,
                timestamp: 2,
            },
        ] {
            let call:Message=serde_json::from_value(serde_json::json!({"role":"assistant","content":[{"type":"toolCall","id":"done","name":"bash","arguments":{}},{"type":"toolCall","id":"lost","name":"bash","arguments":{}}],"api":"x","provider":"x","model":"x","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0},"stopReason":"toolUse","timestamp":1})).unwrap();
            let result = Message::ToolResult {
                tool_call_id: "done".into(),
                tool_name: "bash".into(),
                content: vec![],
                details: None,
                is_error: false,
                timestamp: 3,
            };
            let messages = vec![
                Message::User {
                    content: pirc_protocol::UserContent::Text("first".into()),
                    timestamp: 1,
                },
                call,
                task.clone(),
                result,
            ];
            let entries = messages
                .iter()
                .cloned()
                .enumerate()
                .map(|(i, m)| (format!("e{i}"), m))
                .collect::<Vec<_>>();
            assert!(!message_boundaries(&entries).unwrap().contains(&2));
            assert!(crate::compaction::find_cut_point(&entries, 0).is_none());
            let branch = entries
                .into_iter()
                .map(|(id, m)| SessionEntry {
                    id,
                    parent_id: None,
                    timestamp: 1,
                    data: EntryData::Message(m),
                })
                .collect::<Vec<_>>();
            assert!(crate::handoff::boundaries(&branch).is_ok());
            assert!(crate::handoff::boundaries_before(&branch[..2], &branch[2..]).is_err());
            let sources = crate::handoff::sources(&branch);
            let text = &sources.iter().find(|s| s.entry_id == "e1").unwrap().text;
            assert!(text.contains("Tool call lost was interrupted"));
            assert!(!text.contains("Tool call done was interrupted"));
            let projected = crate::agent::sanitize_history(&messages);
            assert!(projected.iter().any(|m|matches!(m,Message::ToolResult{tool_call_id,is_error:false,..} if tool_call_id=="done")));
            assert_eq!(projected.iter().filter(|m|matches!(m,Message::ToolResult{tool_call_id,is_error:true,..} if tool_call_id=="lost")).count(),1);
            let result_at = projected
                .iter()
                .position(
                    |m| matches!(m,Message::ToolResult{tool_call_id,..}if tool_call_id=="done"),
                )
                .unwrap();
            let task_at = projected.iter().position(|m| m == &task).unwrap();
            assert!(result_at < task_at);
        }
    }
}

#[cfg(test)]
mod recovery_tests {
    use super::*;
    use crate::agent::sanitize_history as project;
    use crate::session_store::{EntryData, SessionEntry};
    use pirc_protocol::AssistantContent;
    use serde_json::json;
    fn user() -> Message {
        Message::User {
            content: pirc_protocol::UserContent::Text("next".into()),
            timestamp: 1,
        }
    }
    fn call(id: &str) -> Message {
        serde_json::from_value(json!({"role":"assistant","content":[{"type":"toolCall","id":id,"name":"ptc","arguments":{}}],"api":"x","provider":"x","model":"x","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0},"stopReason":"toolUse","timestamp":1})).unwrap()
    }
    fn result(id: &str) -> Message {
        Message::ToolResult {
            tool_call_id: id.into(),
            tool_name: "ptc".into(),
            content: vec![],
            details: None,
            is_error: false,
            timestamp: 2,
        }
    }
    fn entries(data: Vec<EntryData>) -> Vec<SessionEntry> {
        data.into_iter()
            .enumerate()
            .map(|(i, data)| SessionEntry {
                id: format!("e{i}"),
                parent_id: i.checked_sub(1).map(|i| format!("e{i}")),
                timestamp: 1,
                data,
            })
            .collect()
    }
    #[test]
    fn late_results_survive_interleaved_assistants_and_overlapping_tool_groups() {
        let text: Message = serde_json::from_value(json!({"role":"assistant","content":[{"type":"text","text":"interleaved reply"}],"api":"x","provider":"x","model":"x","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0},"stopReason":"stop","timestamp":1})).unwrap();
        for task in [
            user(),
            Message::Custom {
                custom_type: "scheduled-run".into(),
                content: "next".into(),
                display: true,
                details: None,
                timestamp: 1,
            },
        ] {
            for middle in [text.clone(), call("second")] {
                let mut messages = vec![user(), call("first"), task.clone(), middle.clone()];
                if !issued(&middle).is_empty() {
                    messages.push(result("second"));
                }
                messages.push(result("first"));
                let branch = entries(messages.iter().cloned().map(EntryData::Message).collect());
                assert!(crate::handoff::boundaries(&branch).is_ok());
                assert!(crate::handoff::boundaries_before(&branch[..2], &branch[2..]).is_err());
                let projected = crate::agent::sanitize_history(&messages);
                assert_eq!(projected[2], result("first"));
                assert_eq!(projected[3], task);
                assert_eq!(projected[4], middle);
                assert!(
                    !projected
                        .iter()
                        .any(|m| matches!(m, Message::ToolResult { is_error: true, .. }))
                );
                let mut open = HashSet::new();
                for m in &projected {
                    if let Message::ToolResult { tool_call_id, .. } = m {
                        assert!(open.remove(tool_call_id));
                    } else {
                        assert!(open.is_empty());
                        for (id, _) in issued(m) {
                            open.insert(id.to_owned());
                        }
                    }
                }
                assert!(open.is_empty());
                assert_eq!(branch.len(), messages.len()); // projection never appends fabricated journal entries
            }
        }
    }
    #[test]
    fn ptc_operations_after_an_admission_recover_without_an_outer_result() {
        let operation = EntryData::Custom {
            custom_type: "ptc.operation".into(),
            data: json!({"parentToolCallId":"first","toolCallId":"nested","toolName":"read","content":[{"type":"text","text":"recorded nested evidence"}],"isError":false}),
        };
        let branch = entries(vec![
            EntryData::Message(user()),
            EntryData::Message(call("first")),
            EntryData::Message(user()),
            operation.clone(),
            EntryData::Message(user()),
        ]);
        let safe = crate::handoff::boundaries(&branch).unwrap();
        assert!(!safe.contains(&2));
        assert!(safe.contains(&4));
        assert!(crate::handoff::boundaries_before(&branch[..2], &branch[2..]).is_err());
        assert!(crate::handoff::boundaries_before(&branch[..4], &branch[4..]).is_ok());
        let sources = crate::handoff::sources(&branch);
        assert!(
            sources
                .iter()
                .any(|s| s.entry_id == "e1" && s.text.contains("outcome unknown"))
        );
        assert!(
            sources
                .iter()
                .any(|s| s.entry_id == "e3" && s.text.contains("recorded nested evidence"))
        );
        assert!(
            crate::handoff::boundaries(&entries(vec![
                operation.clone(),
                EntryData::Message(user())
            ]))
            .is_err()
        );
        let mut duplicate = branch[..4]
            .iter()
            .map(|e| e.data.clone())
            .collect::<Vec<_>>();
        duplicate.extend([operation, EntryData::Message(user())]);
        assert!(crate::handoff::boundaries(&entries(duplicate)).is_err());
        let mut wrong_parent = branch.clone();
        if let EntryData::Custom { data, .. } = &mut wrong_parent[3].data {
            data["parentToolCallId"] = json!("unissued");
        }
        assert!(crate::handoff::boundaries(&wrong_parent).is_err());
        let mut wrong_name = branch.clone();
        if let EntryData::Message(Message::Assistant(a)) = &mut wrong_name[1].data
            && let AssistantContent::ToolCall { name, .. } = &mut a.content[0]
        {
            *name = "bash".into();
        }
        assert!(crate::handoff::boundaries(&wrong_name).is_err());
    }
    #[test]
    fn completed_ids_and_nested_operations_are_scoped_to_each_occurrence() {
        let operation = || EntryData::Custom {
            custom_type: "ptc.operation".into(),
            data: json!({"parentToolCallId":"same","toolCallId":"nested","toolName":"read","content":[{"type":"text","text":"nested evidence"}]}),
        };
        let raw = entries(vec![
            EntryData::Custom {
                custom_type: "private-metadata".into(),
                data: json!({}),
            },
            EntryData::Message(user()),
            EntryData::Message(call("same")),
            EntryData::Message(user()),
            operation(),
            EntryData::Message(result("same")),
            EntryData::Message(user()),
            EntryData::Message(call("same")),
            EntryData::Message(user()),
            operation(),
            EntryData::Message(user()),
        ]);
        // Reopening serialized history must retain both occurrences and the late PTC evidence.
        let branch: Vec<SessionEntry> =
            serde_json::from_slice(&serde_json::to_vec(&raw).unwrap()).unwrap();
        let safe = crate::handoff::boundaries(&branch).unwrap();
        assert!(!safe.contains(&3));
        assert!(safe.contains(&6));
        assert!(!safe.contains(&8));
        assert!(safe.contains(&10));
        let sources = crate::handoff::sources(&branch);
        assert!(
            !sources
                .iter()
                .find(|s| s.entry_id == "e2")
                .unwrap()
                .text
                .contains("outcome unknown")
        );
        assert!(
            sources
                .iter()
                .find(|s| s.entry_id == "e7")
                .unwrap()
                .text
                .contains("outcome unknown")
        );
        let messages: Vec<_> = branch.iter().filter_map(|e| e.message().cloned()).collect();
        let projected = project(&messages);
        assert_eq!(
            projected
                .iter()
                .flat_map(issued)
                .filter(|(id, _)| *id == "same")
                .count(),
            2
        );
        assert_eq!(
            projected
                .iter()
                .filter(|m| matches!(
                    m,
                    Message::ToolResult {
                        is_error: false,
                        ..
                    }
                ))
                .count(),
            1
        );
        assert_eq!(
            projected
                .iter()
                .filter(|m| matches!(m, Message::ToolResult { is_error: true, .. }))
                .count(),
            1
        );
        let mut duplicate = branch[..10].to_vec();
        duplicate.push(entries(vec![operation()]).remove(0));
        assert!(crate::handoff::boundaries(&duplicate).is_err());
    }
    #[test]
    fn completed_reused_ids_preserve_distinct_results_but_pending_duplicates_fail() {
        let mut second = result("same");
        if let Message::ToolResult { timestamp, .. } = &mut second {
            *timestamp = 99;
        }
        let messages = vec![
            user(),
            call("same"),
            user(),
            result("same"),
            user(),
            call("same"),
            second.clone(),
        ];
        let boundaries = message_boundaries(
            &messages
                .iter()
                .cloned()
                .enumerate()
                .map(|(i, m)| (i.to_string(), m))
                .collect::<Vec<_>>(),
        )
        .unwrap();
        assert!(!boundaries.contains(&2));
        assert!(boundaries.contains(&4));
        let projected = project(&messages);
        assert_eq!(projected[2], result("same"));
        assert_eq!(projected[6], second);
        assert_eq!(projected.iter().flat_map(issued).count(), 2);
        for duplicate in [
            vec![call("same"), call("same")],
            vec![call("same"), user(), call("same")],
        ] {
            assert!(
                message_boundaries(
                    &duplicate
                        .into_iter()
                        .enumerate()
                        .map(|(i, m)| (i.to_string(), m))
                        .collect::<Vec<_>>()
                )
                .is_err()
            );
        }
        let mut different_name = messages;
        if let Message::Assistant(a) = &mut different_name[5]
            && let AssistantContent::ToolCall { name, .. } = &mut a.content[0]
        {
            *name = "bash".into();
        }
        if let Message::ToolResult { tool_name, .. } = &mut different_name[6] {
            *tool_name = "bash".into();
        }
        assert_eq!(project(&different_name)[6], different_name[6]);
        assert!(
            crate::handoff::boundaries(&entries(
                different_name.into_iter().map(EntryData::Message).collect()
            ))
            .is_ok()
        );
    }
    fn execution_result(parent: &str, execution: &str) -> Message {
        let mut m = result(parent);
        if let Message::ToolResult { details, .. } = &mut m {
            *details = Some(json!({"executionId":execution}));
        }
        m
    }
    fn execution_operation(parent: &str, execution: &str) -> EntryData {
        EntryData::Custom {
            custom_type: "ptc.operation".into(),
            data: json!({"parentToolCallId":parent,"toolCallId":format!("{execution}:op1"),"toolName":"read","content":[{"type":"text","text":"late evidence"}]}),
        }
    }
    #[test]
    fn late_operations_keep_their_completed_execution_when_parent_ids_are_reused() {
        let branch = entries(vec![
            EntryData::Message(user()),
            EntryData::Message(call("same")),
            EntryData::Message(execution_result("same", "old")),
            EntryData::Message(user()),
            EntryData::Message(call("same")),
            EntryData::Message(user()),
            execution_operation("same", "old"),
            EntryData::Message(user()),
        ]);
        let evidence = Evidence::collect(branch.iter().map(event));
        assert_eq!(evidence.operation_parents.get(&6), Some(&(1, 0)));
        assert!(!evidence.last_operations.contains_key(&(4, 0)));
        let safe = crate::handoff::boundaries(&branch).unwrap();
        assert!(!safe.contains(&3));
        assert!(safe.contains(&7));
        assert!(crate::handoff::boundaries_before(&branch[..3], &branch[3..]).is_err());
        let sources = crate::handoff::sources(&branch);
        assert!(
            !sources
                .iter()
                .find(|s| s.entry_id == "e1")
                .unwrap()
                .text
                .contains("outcome unknown")
        );
        assert!(
            sources
                .iter()
                .find(|s| s.entry_id == "e4")
                .unwrap()
                .text
                .contains("outcome unknown")
        );
        assert!(sources.iter().any(|s| s.entry_id == "e6"
            && s.text.contains("late evidence")
            && s.text.contains("parent entry: e1")));
        let reopened: Vec<SessionEntry> =
            serde_json::from_slice(&serde_json::to_vec(&branch).unwrap()).unwrap();
        assert_eq!(crate::handoff::boundaries(&reopened).unwrap(), safe);
    }
    #[test]
    fn interleaved_completed_executions_and_legacy_late_operations_remain_valid() {
        let branch = entries(vec![
            EntryData::Message(call("same")),
            EntryData::Message(execution_result("same", "old")),
            EntryData::Message(call("same")),
            execution_operation("same", "new"),
            EntryData::Message(execution_result("same", "new")),
            execution_operation("same", "old"),
        ]);
        let evidence = Evidence::collect(branch.iter().map(event));
        assert_eq!(evidence.operation_parents.get(&3), Some(&(2, 0)));
        assert_eq!(evidence.operation_parents.get(&5), Some(&(0, 0)));
        assert!(crate::handoff::boundaries(&branch).is_ok());
        let legacy = entries(vec![
            EntryData::Message(call("legacy")),
            EntryData::Message(result("legacy")),
            EntryData::Custom {
                custom_type: "ptc.operation".into(),
                data: json!({"parentToolCallId":"legacy","toolCallId":"nested"}),
            },
        ]);
        assert!(crate::handoff::boundaries(&legacy).is_ok());
        let mut duplicate = branch.clone();
        duplicate.push(branch[5].clone());
        assert!(crate::handoff::boundaries(&duplicate).is_err());
        let wrong = entries(vec![
            EntryData::Message(call("same")),
            execution_operation("same", "foreign"),
            EntryData::Message(execution_result("same", "actual")),
        ]);
        assert!(crate::handoff::boundaries(&wrong).is_err());
        let ambiguous = entries(vec![
            EntryData::Message(call("same")),
            EntryData::Message(execution_result("same", "duplicate")),
            EntryData::Message(call("same")),
            EntryData::Message(execution_result("same", "duplicate")),
            execution_operation("same", "duplicate"),
        ]);
        assert!(crate::handoff::boundaries(&ambiguous).is_err());
    }
    #[test]
    fn legacy_missing_execution_id_stays_ambiguous_until_reused_parent_is_known() {
        let branch = entries(vec![
            EntryData::Message(user()),
            EntryData::Message(call("same")),
            EntryData::Message(result("same")),
            EntryData::Message(user()),
            EntryData::Message(call("same")),
            execution_operation("same", "old"),
            EntryData::Message(user()),
        ]);
        let evidence = Evidence::collect(branch.iter().map(event));
        assert!(!evidence.operation_parents.contains_key(&5));
        assert!(crate::handoff::boundaries(&branch).is_err());
        assert!(crate::handoff::boundaries_before(&branch[..3], &branch[3..]).is_err());
        // Existing outer metadata resolves the ambiguity without inventing an ID
        // or moving the operation when the active/new result finally arrives.
        let mut completed = branch.clone();
        completed.insert(
            6,
            entries(vec![EntryData::Message(execution_result("same", "new"))]).remove(0),
        );
        completed[6].id = "new_result".into();
        let evidence = Evidence::collect(completed.iter().map(event));
        assert_eq!(evidence.operation_parents.get(&5), Some(&(1, 0)));
        assert_eq!(evidence.last_operations.get(&(1, 0)), Some(&5));
        assert!(!evidence.last_operations.contains_key(&(4, 0)));
        let safe = crate::handoff::boundaries(&completed).unwrap();
        assert!(!safe.contains(&3));
        let reopened: Vec<SessionEntry> =
            serde_json::from_slice(&serde_json::to_vec(&completed).unwrap()).unwrap();
        assert_eq!(crate::handoff::boundaries(&reopened).unwrap(), safe);
        let sources = crate::handoff::sources(&reopened);
        assert!(
            sources
                .iter()
                .any(|s| s.entry_id == "e5" && s.text.contains("parent entry: e1"))
        );
        // Two completed legacy candidates are still ambiguous, never arbitrary.
        if let EntryData::Message(Message::ToolResult { details, .. }) = &mut completed[6].data {
            *details = None;
        }
        assert!(crate::handoff::boundaries(&completed).is_err());
    }
    #[test]
    fn work_excludes_ambiguous_spans_without_weakening_compression_or_known_id_validation() {
        let stop: Message = serde_json::from_value(json!({"role":"assistant","content":[{"type":"text","text":"independent completion"}],"api":"x","provider":"x","model":"x","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0},"stopReason":"stop","timestamp":1})).unwrap();
        let branch = entries(vec![
            EntryData::Message(user()),
            EntryData::Message(call("same")),
            EntryData::Message(result("same")),
            EntryData::Message(user()),
            EntryData::Message(call("same")),
            execution_operation("same", "old"),
            EntryData::Message(user()),
            EntryData::Message(result("same")),
            EntryData::Message(stop),
            EntryData::Message(user()),
        ]);
        // A real later outer result holds the shared group open across e6.
        let history = crate::handoff::source_history(&branch).unwrap();
        assert_eq!(history.blocked, HashSet::from([0, 3]));
        assert!(!history.boundaries.contains(&6));
        assert!(history.boundaries.contains(&9));
        assert_eq!(history.origins["e7"], 3);
        let kept: Vec<_> = history
            .sources(|_, _| true)
            .into_iter()
            .map(|s| s.entry_id)
            .collect();
        assert_eq!(kept, vec!["e6", "e8", "e9"]);
        assert!(crate::handoff::boundaries(&branch).is_err());
        assert!(crate::handoff::boundaries_before(&branch[..3], &branch[3..]).is_err());
        let reopened: Vec<SessionEntry> =
            serde_json::from_slice(&serde_json::to_vec(&branch).unwrap()).unwrap();
        assert_eq!(
            crate::handoff::source_history(&reopened).unwrap().blocked,
            history.blocked
        );
        // Exact duplicated identities and foreign operations remain errors in Work too.
        let duplicate = entries(vec![
            EntryData::Message(call("same")),
            EntryData::Message(execution_result("same", "duplicate")),
            EntryData::Message(call("same")),
            EntryData::Message(execution_result("same", "duplicate")),
            execution_operation("same", "duplicate"),
        ]);
        assert!(crate::handoff::source_history(&duplicate).is_err());
        let foreign = entries(vec![
            EntryData::Message(call("same")),
            execution_operation("same", "foreign"),
            EntryData::Message(execution_result("same", "actual")),
        ]);
        assert!(crate::handoff::source_history(&foreign).is_err());
    }
}
