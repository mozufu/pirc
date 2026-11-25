//! `todo` (`agent/features/todo/`): the session's todo list. The model
//! keeps it with the `todo` capability (from `ptc` scripts), the human with
//! `/todo`; every change is a session entry, the web shows it as a widget,
//! a new process restores it and tells the model with a snapshot, and a
//! run that stops with unfinished todos gets one reminder.

pub mod model;

use std::cell::{Cell, RefCell};
use std::rc::{Rc, Weak};

use pirc_protocol::{Message, StopReason};
use serde_json::{Map, Value, json};

use crate::agent::{Agent, Delivery};
use crate::feature::{BeforeStart, Feature, FeatureCommand, off_in_mode};
use crate::session_store::EntryData;
use crate::tools::result_schema::{arr, fields, int, obj, one_of_strings, str_};
use crate::tools::{Tool, ToolContext, ToolResult, ToolSpec, js, spec_tool, typed};
use crate::ui::NotifyLevel;
use crate::{LocalBoxFuture, now_ms};
use model::{FormatOptions, State, Status, apply_action, format_todos, parse_state};

/// `TODO_ENTRY`: the custom entry holding the list after each change.
pub const TODO_ENTRY: &str = "local-todo-state-v1";
const CONTEXT: &str = "local-todo-context";
const WIDGET: &str = "local-todo";
const HELP: &str = "/todo: View the list
/todo add <text>: Add a task
/todo start|done|pending <ID>: Change status
/todo edit <ID> <text>: Edit a task
/todo category <ID> [name]: Set or clear a category
/todo remove <ID>: Delete a task
/todo prune: Remove completed tasks
/todo clear: Clear all tasks (confirmation required)";
const ACTIONS: [&str; 6] = ["list", "add", "update", "remove", "prune", "clear"];

/// `safe`: control characters as spaces, for the widget.
fn safe(text: &str) -> String {
    text.chars()
        .map(|c| {
            if matches!(c, '\u{0}'..='\u{1f}' | '\u{7f}'..='\u{9f}') {
                ' '
            } else {
                c
            }
        })
        .collect()
}

/// `changes`: what an action changed, as the model reads it.
fn changes(before: &State, after: &State) -> Result<String, String> {
    let mut previous: Vec<&model::Todo> = before.todos.iter().collect();
    let mut changed: Vec<u64> = Vec::new();
    for todo in &after.todos {
        let old = previous.iter().position(|item| item.id == todo.id);
        let same = old.is_some_and(|index| {
            let old = previous[index];
            old.text == todo.text
                && old.status == todo.status
                && old.category == todo.category
                && old.active_form == todo.active_form
                && old.blocked_by == todo.blocked_by
        });
        if !same {
            changed.push(todo.id);
        }
        if let Some(index) = old {
            previous.remove(index);
        }
    }
    let done = after
        .todos
        .iter()
        .filter(|todo| todo.status == Status::Completed)
        .count();
    let mut lines = vec![format!("{done}/{} completed", after.todos.len())];
    if !previous.is_empty() {
        let removed: Vec<String> = previous
            .iter()
            .map(|todo| format!("#{}", todo.id))
            .collect();
        lines.push(format!("Removed: {}", removed.join(", ")));
    }
    if !changed.is_empty() {
        lines.push(format_todos(
            after,
            FormatOptions {
                unfinished_only: false,
                ids: Some(&changed),
            },
        )?);
    }
    if previous.is_empty() && changed.is_empty() {
        lines.push("Unchanged.".to_owned());
    }
    Ok(lines.join("\n"))
}

/// `TODO_MARKS`: widget line markers, one per status; the web todo dock
/// parses them back.
fn mark(status: Status) -> &'static str {
    match status {
        Status::Completed => "✓",
        Status::InProgress => "▶",
        Status::Pending => "☐",
    }
}

/// `panel`: the web widget, a `TODO · done/total` header, then every task
/// in list order as `<mark> [category] label (blocked)`. In-progress tasks
/// show their activity label.
fn panel(state: &State) -> Vec<String> {
    let done = state
        .todos
        .iter()
        .filter(|todo| todo.status == Status::Completed)
        .count();
    let mut lines = vec![format!("TODO · {done}/{}", state.todos.len())];
    for item in &state.todos {
        let blocked = item.status != Status::Completed
            && item.blocked_by.iter().any(|id| {
                state
                    .todos
                    .iter()
                    .find(|todo| todo.id == *id)
                    .is_none_or(|todo| todo.status != Status::Completed)
            });
        let label = match (&item.status, &item.active_form) {
            (Status::InProgress, Some(active)) => active,
            _ => &item.text,
        };
        let category = item
            .category
            .as_ref()
            .map_or_else(String::new, |category| format!("[{}] ", safe(category)));
        lines.push(format!(
            "{} {category}{}{}",
            mark(item.status),
            safe(label),
            if blocked { " (blocked)" } else { "" }
        ));
    }
    lines
}

/// The list and what the model is owed, shared by the feature and its
/// tool.
#[derive(Default)]
struct TodoState {
    state: RefCell<State>,
    reminded: Cell<bool>,
    needs_snapshot: Cell<bool>,
}

impl TodoState {
    fn snapshot_text(&self) -> Result<String, String> {
        Ok(format!(
            "Todo snapshot (task data; replaces earlier todo state):\n{}",
            format_todos(&self.state.borrow(), FormatOptions::default())?
        ))
    }

    /// `snapshotMessage`.
    fn snapshot_message(&self) -> Result<Message, String> {
        Ok(Message::Custom {
            custom_type: CONTEXT.to_owned(),
            content: self.snapshot_text()?,
            display: false,
            details: None,
            timestamp: now_ms(),
        })
    }

    /// `paint`.
    fn paint(&self, agent: &Agent) {
        if !agent.has_ui() {
            return;
        }
        let state = self.state.borrow();
        let lines = (!state.todos.is_empty()).then(|| panel(&state));
        agent.ui().set_widget(WIDGET, lines.as_deref());
    }

    /// `restore`: the list from the session's entries; damaged ones are
    /// skipped.
    fn restore(&self, agent: &Agent) {
        let mut state = State::default();
        let mut invalid = false;
        for entry in agent.custom_entries(TODO_ENTRY) {
            if let EntryData::Custom { data, .. } = &entry.data {
                match parse_state(data) {
                    Some(parsed) => state = parsed,
                    None => invalid = true,
                }
            }
        }
        self.needs_snapshot.set(state.next_id > 1);
        *self.state.borrow_mut() = state;
        if invalid {
            agent.ui().notify(
                "Invalid todo history; corrupted snapshots were skipped.",
                NotifyLevel::Warning,
            );
        }
        self.paint(agent);
    }

    /// `run`: validate, append, swap at once, so parallel calls cannot
    /// lose updates. The list after the action.
    fn run(&self, agent: &Agent, action: &Value) -> Result<State, String> {
        let next = apply_action(&self.state.borrow(), action)?;
        if action.get("action").and_then(Value::as_str) != Some("list") {
            agent.append_entry(EntryData::Custom {
                custom_type: TODO_ENTRY.to_owned(),
                data: next.to_value(),
            })?;
            *self.state.borrow_mut() = next;
            self.paint(agent);
        }
        Ok(self.state.borrow().clone())
    }
}

/// `todo`, the capability.
struct TodoTool {
    spec: ToolSpec,
    todos: Rc<TodoState>,
    /// Weak: the agent owns its tools.
    agent: Weak<Agent>,
}

impl TodoTool {
    fn new(todos: Rc<TodoState>, agent: &Rc<Agent>) -> Self {
        let status = json!({ "type": "string", "enum": ["pending", "in_progress", "completed"] });
        let id = json!({ "type": "integer", "minimum": 1, "maximum": 999999 });
        let item_fields = || {
            let mut fields = Map::new();
            fields.insert(
                "text".to_owned(),
                json!({ "type": "string", "minLength": 1, "maxLength": 200 }),
            );
            fields.insert(
                "category".to_owned(),
                json!({ "type": "string", "maxLength": 60,
                    "description": "Category; empty string clears it, omit to retain" }),
            );
            fields.insert("status".to_owned(), status.clone());
            fields.insert(
                "activeForm".to_owned(),
                json!({ "type": "string", "minLength": 1, "maxLength": 100,
                    "description": "Activity label shown while in progress" }),
            );
            fields.insert(
                "blockedBy".to_owned(),
                json!({ "type": "array", "items": id.clone(), "maxItems": 50 }),
            );
            fields
        };
        let mut properties = Map::new();
        properties.insert(
            "action".to_owned(),
            json!({ "type": "string", "enum": ACTIONS }),
        );
        properties.insert(
            "items".to_owned(),
            json!({ "type": "array", "minItems": 1, "maxItems": 50,
                "items": { "type": "object", "properties": item_fields(),
                    "required": ["text"], "additionalProperties": false } }),
        );
        properties.insert("id".to_owned(), id.clone());
        properties.extend(item_fields());
        let todo = obj(
            vec![
                ("id", int(None)),
                ("text", str_(None)),
                (
                    "status",
                    one_of_strings(&["pending", "in_progress", "completed"], None),
                ),
                ("activeForm", str_(None)),
                ("category", str_(None)),
                ("blockedBy", arr(int(None), None)),
            ],
            &["activeForm", "category"],
        );
        Self {
            spec: ToolSpec::new(
                "todo",
                json!({ "type": "object", "properties": properties,
                    "required": ["action"], "additionalProperties": false }),
                Some(fields(
                    vec![
                        ("action", one_of_strings(&ACTIONS, None)),
                        ("todos", arr(todo, Some("The whole list after the action"))),
                    ],
                    &[],
                )),
            ),
            todos,
            agent: Rc::downgrade(agent),
        }
    }

    async fn run(&self, args: Map<String, Value>, ctx: ToolContext) -> Result<ToolResult, String> {
        if ctx.signal.aborted() {
            return Err("Aborted".to_owned());
        }
        let Some(agent) = self.agent.upgrade() else {
            return Err("Aborted".to_owned());
        };
        let before = self.todos.state.borrow().clone();
        let args = Value::Object(args);
        let snapshot = self.todos.run(&agent, &args)?;
        let action = args.get("action");
        let text =
            if action.and_then(Value::as_str) == Some("list") || self.todos.needs_snapshot.get() {
                format!(
                    "Todo snapshot:\n{}",
                    format_todos(&snapshot, FormatOptions::default())?
                )
            } else {
                changes(&before, &snapshot)?
            };
        self.todos.needs_snapshot.set(false);
        let mut details = Map::new();
        details.insert("state".to_owned(), snapshot.to_value());
        let mut data = Map::new();
        if let Some(action) = action {
            details.insert("action".to_owned(), action.clone());
            data.insert("action".to_owned(), action.clone());
        }
        data.insert("todos".to_owned(), snapshot.todos_value());
        Ok(typed(
            text,
            Value::Object(data),
            Some(Value::Object(details)),
            false,
        ))
    }
}

spec_tool!(TodoTool, ptc: true);

/// `todoFeature()`.
pub fn feature() -> Rc<dyn Feature> {
    Rc::new(TodoFeature::default())
}

#[derive(Default)]
struct TodoFeature {
    todos: Rc<TodoState>,
}

impl TodoFeature {
    /// The `/todo` command; `Err` is shown as an error.
    async fn command(&self, agent: &Rc<Agent>, args: &str) -> Result<(), String> {
        let words: Vec<&str> = args.split(js::is_space).filter(|w| !w.is_empty()).collect();
        let (command, rest) = match words.split_first() {
            Some((command, rest)) => (*command, rest),
            None => ("list", &[][..]),
        };
        let ui = agent.ui();
        if command == "help" {
            ui.notify(HELP, NotifyLevel::Info);
            return Ok(());
        }
        if command == "list" {
            let text = format_todos(&self.todos.state.borrow(), FormatOptions::default())?;
            ui.notify(&text, NotifyLevel::Info);
            return Ok(());
        }
        if agent.is_running() {
            ui.notify(
                "The agent is working; wait before editing todos manually.",
                NotifyLevel::Warning,
            );
            return Ok(());
        }
        let action = if command == "add" {
            json!({ "action": "add", "text": rest.join(" ") })
        } else if command == "prune" && rest.is_empty() {
            json!({ "action": "prune" })
        } else if command == "clear" && rest.is_empty() {
            let confirmed = ui
                .confirm(
                    "Clear todos",
                    "Delete all current todo items?",
                    Default::default(),
                )
                .await;
            if confirmed != Some(true) {
                return Ok(());
            }
            json!({ "action": "clear" })
        } else {
            let first = rest.first().copied().unwrap_or_default();
            let valid = first.starts_with(|c: char| ('1'..='9').contains(&c))
                && first.bytes().all(|b| b.is_ascii_digit());
            if !valid {
                return Err("Provide a valid todo ID (/todo help)".to_owned());
            }
            // `Number(rest[0])`.
            let id = first.parse::<f64>().unwrap_or(f64::INFINITY);
            let id = serde_json::Number::from_f64(id).map_or(Value::Null, Value::Number);
            let id = match id.as_f64() {
                Some(n) if n.fract() == 0.0 && n.abs() < 9_007_199_254_740_992.0 => {
                    json!(n as u64)
                }
                _ => id,
            };
            match command {
                "edit" => json!({ "action": "update", "id": id, "text": rest[1..].join(" ") }),
                "category" => {
                    json!({ "action": "update", "id": id, "category": rest[1..].join(" ") })
                }
                _ if rest.len() != 1 => {
                    return Err("Too many arguments (/todo help)".to_owned());
                }
                "remove" => json!({ "action": "remove", "id": id }),
                "start" | "done" | "pending" => {
                    let status = match command {
                        "start" => "in_progress",
                        "done" => "completed",
                        _ => "pending",
                    };
                    json!({ "action": "update", "id": id, "status": status })
                }
                _ => return Err("Unknown command (/todo help)".to_owned()),
            }
        };
        let before = self.todos.state.borrow().clone();
        let snapshot = self.todos.run(agent, &action)?;
        let delivery = if self.todos.needs_snapshot.get() {
            Delivery {
                custom_type: CONTEXT.to_owned(),
                content: self.todos.snapshot_text()?,
                display: false,
                details: None,
            }
        } else {
            Delivery {
                custom_type: CONTEXT.to_owned(),
                content: format!("Todo update (manual):\n{}", changes(&before, &snapshot)?),
                display: false,
                details: None,
            }
        };
        agent.deliver(delivery, false, false)?;
        self.todos.needs_snapshot.set(false);
        ui.notify("Todos updated.", NotifyLevel::Info);
        Ok(())
    }
}

impl Feature for TodoFeature {
    fn name(&self) -> &'static str {
        "todo"
    }

    fn tools(&self, agent: &Rc<Agent>) -> Vec<Rc<dyn Tool>> {
        if off_in_mode(agent, "todo") {
            return Vec::new();
        }
        vec![Rc::new(TodoTool::new(self.todos.clone(), agent))]
    }

    fn commands(&self) -> Vec<FeatureCommand> {
        vec![FeatureCommand::new("todo", "Manage todos (/todo help)")]
    }

    fn run_command<'a>(
        &'a self,
        agent: &'a Rc<Agent>,
        _name: &'a str,
        args: String,
    ) -> LocalBoxFuture<'a, Result<(), String>> {
        Box::pin(async move { self.command(agent, &args).await })
    }

    fn init<'a>(&'a self, agent: &'a Rc<Agent>) -> LocalBoxFuture<'a, Result<(), String>> {
        Box::pin(async move {
            self.todos.restore(agent);
            Ok(())
        })
    }

    fn user_input(&self, _agent: &Rc<Agent>, _text: &str) {
        self.todos.reminded.set(false);
    }

    fn before_agent_start<'a>(
        &'a self,
        _agent: &'a Rc<Agent>,
    ) -> LocalBoxFuture<'a, Result<Option<BeforeStart>, String>> {
        Box::pin(async move {
            if !self.todos.needs_snapshot.get() {
                return Ok(None);
            }
            self.todos.needs_snapshot.set(false);
            Ok(Some(BeforeStart {
                system_prompt: None,
                messages: vec![self.todos.snapshot_message()?],
            }))
        })
    }

    fn agent_end<'a>(
        &'a self,
        agent: &'a Rc<Agent>,
        produced: &'a [Message],
    ) -> LocalBoxFuture<'a, Result<(), String>> {
        Box::pin(async move {
            let stopped = matches!(produced.last(),
                Some(Message::Assistant(message)) if message.stop_reason == StopReason::Stop);
            if !stopped {
                return Ok(());
            }
            // An active goal starts the next round anyway; its continuation covers the reminder.
            if self.todos.reminded.get() || agent.pending_count() > 0 || agent.will_continue() {
                return Ok(());
            }
            let (unfinished, list) = {
                let state = self.todos.state.borrow();
                let unfinished = state
                    .todos
                    .iter()
                    .filter(|todo| todo.status != Status::Completed)
                    .count();
                let list = format_todos(
                    &state,
                    FormatOptions {
                        unfinished_only: true,
                        ids: None,
                    },
                )?;
                (unfinished, list)
            };
            if unfinished == 0 {
                return Ok(());
            }
            self.todos.reminded.set(true);
            agent.deliver(
                Delivery {
                    custom_type: "local-todo-reminder".to_owned(),
                    content: format!(
                        "{unfinished} unfinished todos. Finish and verify, or report blockers and stop. Respect pause/authorization; never fake completion or clear tasks to silence this reminder.\n{list}"
                    ),
                    display: true,
                    details: None,
                },
                true,
                true,
            )
        })
    }

    fn after_compact<'a>(&'a self, agent: &'a Rc<Agent>) -> LocalBoxFuture<'a, Result<(), String>> {
        Box::pin(async move {
            self.todos.restore(agent);
            Ok(())
        })
    }

    fn shutdown<'a>(&'a self, agent: &'a Rc<Agent>) -> LocalBoxFuture<'a, ()> {
        Box::pin(async move {
            if agent.has_ui() {
                agent.ui().set_widget(WIDGET, None);
            }
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agent::AgentOptions;
    use crate::session_store::SessionStore;
    use crate::signal::AbortController;
    use crate::tools::testing::{self, TestUi};

    /// An agent running only the todo feature, in a fresh session.
    fn agent(dir: &std::path::Path, ui: Rc<TestUi>, pot: bool) -> Rc<Agent> {
        let workspace = dir.join("workspace");
        std::fs::create_dir_all(&workspace).unwrap();
        let mut config = testing::config(&workspace.display().to_string(), json!({}));
        if pot {
            let (_, text) = pirc_config::modes::DEFAULT_MODE_FILES
                .iter()
                .find(|(file, _)| *file == "pot.md")
                .unwrap();
            config.mode = pirc_config::modes::parse_mode("pot", text).unwrap();
        }
        let store = SessionStore::open(dir.join("session"), &config.workspace).unwrap();
        Agent::new(AgentOptions {
            config,
            capabilities: Default::default(),
            role: None,
            store,
            emit: Rc::new(|_| {}),
            ui,
            has_ui: true,
            tools: Vec::new(),
            features: vec![feature()],
            acquire_write: None,
            allowed_tools: None,
            stream_override: None,
        })
    }

    async fn call(agent: &Rc<Agent>, args: Value) -> Result<ToolResult, String> {
        let tool = agent.get_tool("todo").expect("the todo capability");
        let context = testing::context((*agent.config()).clone(), AbortController::new().signal());
        tool.execute(testing::args(args), context.ctx).await
    }

    #[tokio::test]
    async fn the_tool_changes_and_reports_the_list() {
        let dir = tempfile::tempdir().unwrap();
        let ui = Rc::new(TestUi::default());
        let agent = agent(dir.path(), ui.clone(), false);
        agent.init().await.unwrap();
        let added = call(
            &agent,
            json!({ "action": "add", "items": [{ "text": "a" }, { "text": "b", "blockedBy": [1] }] }),
        )
        .await
        .unwrap();
        assert_eq!(
            testing::text_of(&added),
            "0/2 completed\n#1 [Pending] a\n#2 [Pending] b; depends on: #1"
        );
        assert_eq!(added.details.as_ref().unwrap()["action"], "add");
        assert_eq!(
            added.data.as_ref().unwrap()["todos"][1]["blockedBy"],
            json!([1])
        );
        let error = call(
            &agent,
            json!({ "action": "update", "id": 2, "status": "completed" }),
        )
        .await
        .unwrap_err();
        assert_eq!(error, "Dependency #1 of task #2 is not yet completed");
        let listed = call(&agent, json!({ "action": "list" })).await.unwrap();
        assert_eq!(
            testing::text_of(&listed),
            "Todo snapshot:\n#1 [Pending] a\n#2 [Pending] b; depends on: #1"
        );
        // Only changes are entries; a list is not.
        assert_eq!(agent.custom_entries(TODO_ENTRY).len(), 1);

        // A new process owes the model a snapshot, once.
        drop(agent);
        let again = self::agent(dir.path(), ui.clone(), false);
        again.init().await.unwrap();
        let updated = call(
            &again,
            json!({ "action": "update", "id": 1, "status": "completed" }),
        )
        .await
        .unwrap();
        assert_eq!(
            testing::text_of(&updated),
            "Todo snapshot:\n#1 [Completed] a\n#2 [Pending] b; depends on: #1"
        );
        let next = call(&again, json!({ "action": "update", "id": 2, "text": "c" }))
            .await
            .unwrap();
        assert_eq!(
            testing::text_of(&next),
            "1/2 completed\n#2 [Pending] c; depends on: #1"
        );
    }

    #[tokio::test]
    async fn the_command_edits_the_list_by_hand() {
        let dir = tempfile::tempdir().unwrap();
        let ui = Rc::new(TestUi::default());
        let agent = agent(dir.path(), ui.clone(), false);
        agent.init().await.unwrap();
        let feature = agent.features()[0].clone();
        let run = |args: &str| feature.run_command(&agent, "todo", args.to_owned());
        run("add  Buy   milk ").await.unwrap();
        run("").await.unwrap();
        assert_eq!(
            run("start 01").await.unwrap_err(),
            "Provide a valid todo ID (/todo help)"
        );
        assert_eq!(
            run("done 1 2").await.unwrap_err(),
            "Too many arguments (/todo help)"
        );
        assert_eq!(
            run("frob 1").await.unwrap_err(),
            "Unknown command (/todo help)"
        );
        assert_eq!(
            run("start 99999999999999999999").await.unwrap_err(),
            "Task ID not found"
        );
        ui.answer.set(Some(false));
        run("clear").await.unwrap();
        assert_eq!(*ui.confirms.borrow(), ["Delete all current todo items?"]);
        assert_eq!(
            *ui.notes.borrow(),
            ["Todos updated.", "#1 [Pending] Buy milk"]
        );
        // The manual change reached the model's history as hidden context.
        let messages = agent.all_messages();
        assert!(
            matches!(&messages[0], Message::Custom { custom_type, content, display: false, .. }
            if custom_type == CONTEXT && content == "Todo update (manual):\n0/1 completed\n#1 [Pending] Buy milk")
        );
    }

    #[test]
    fn pots_leave_the_tool_out() {
        let dir = tempfile::tempdir().unwrap();
        let agent = agent(dir.path(), Rc::new(TestUi::default()), true);
        assert!(agent.get_tool("todo").is_none());
    }

    fn state(action: Value) -> State {
        apply_action(&State::default(), &action).unwrap()
    }

    #[test]
    fn describes_changes() {
        let before = state(json!({ "action": "add", "items": [{ "text": "a" }, { "text": "b" }] }));
        let after = apply_action(
            &before,
            &json!({ "action": "update", "id": 1, "status": "completed" }),
        )
        .unwrap();
        assert_eq!(
            changes(&before, &after).unwrap(),
            "1/2 completed\n#1 [Completed] a"
        );
        let pruned = apply_action(&after, &json!({ "action": "prune" })).unwrap();
        assert_eq!(
            changes(&after, &pruned).unwrap(),
            "0/1 completed\nRemoved: #1"
        );
        assert_eq!(
            changes(&pruned, &pruned).unwrap(),
            "0/1 completed\nUnchanged."
        );
    }

    #[test]
    fn paints_the_widget() {
        let list = state(json!({ "action": "add", "items": [
            { "text": "write", "status": "in_progress", "activeForm": "Writing", "category": "qa" },
            { "text": "test", "blockedBy": [1] },
            { "text": "done", "status": "completed" },
        ] }));
        assert_eq!(
            panel(&list),
            ["TODO · 1/3", "▶ [qa] Writing", "☐ test (blocked)", "✓ done"]
        );
    }
}
