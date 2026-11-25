//! `agent-team` (`agent/features/team/index.ts`): teammates and one-shot
//! subagents as child agent processes of this executable, coordinated
//! through a broker ([`broker::Team`]) that only the top agent runs. Its
//! children reach it over their stdio ([`channel`]).
//!
//! Team events reach the parent as `agent-team` follow-ups, which the loop
//! admits in batches at tool boundaries; while workers are busy the run
//! waits for them (`completion_blockers`) instead of settling. An abort
//! holds late events back until the next human input.

pub mod broker;
pub mod channel;
mod child;
#[cfg(test)]
mod tests;

use std::cell::{Cell, RefCell};
use std::collections::HashSet;
use std::rc::{Rc, Weak};

use indexmap::IndexMap;
use pirc_protocol::{Message, UserBlock};
use serde_json::{Map, Value, json};

use self::broker::{Defaults, Json, SubagentResult, Team, TeamOptions, user_question};
use self::channel::{ChildMode, parent_channel};
use crate::LocalBoxFuture;
use crate::agent::{Agent, Delivery};
use crate::config::config_roles;
use crate::feature::{BeforeStart, Feature, FeatureCommand, off_in_mode};
use crate::features::ask_question::{ask_question_schema, ask_questions, question_result_schema};
use crate::roles::{default_roles, describe_roles, role_briefs};
use crate::signal::{AbortController, AbortSignal};
use crate::tools::result_schema::{arr, bool_, fields, int, literal, nullable, record, str_};
use crate::tools::{Tool, ToolContext, ToolResult, js, prompts};
use crate::ui::NotifyLevel;

const TASK_STATUSES: [&str; 3] = ["pending", "in_progress", "completed"];
const TASK_ACTIONS: [&str; 8] = [
    "claim",
    "release",
    "complete",
    "reopen",
    "edit",
    "set_dependencies",
    "assign",
    "delete",
];
const MAX_FOREGROUND_RESULT: usize = 40_000;

/// Coordination tools a team member keeps regardless of its kind's tool
/// allowlist (`TEAM_TOOL_NAMES`).
pub const TEAM_TOOL_NAMES: [&str; 12] = [
    "agent_list",
    "agent_wait",
    "agent_send",
    "agent_ask",
    "agent_reply",
    "agent_inbox",
    "board_post",
    "board_read",
    "task_create",
    "task_list",
    "task_get",
    "task_update",
];

fn short() -> Value {
    json!({ "type": "string", "minLength": 1, "maxLength": 12000 })
}

fn object(properties: Value, required: &[&str]) -> Value {
    json!({ "type": "object", "properties": properties, "required": required,
        "additionalProperties": false })
}

fn paging() -> Map<String, Value> {
    let mut out = Map::new();
    out.insert("after".to_owned(), json!({ "type": "string" }));
    out.insert(
        "limit".to_owned(),
        json!({ "type": "integer", "minimum": 1, "maximum": 50 }),
    );
    out
}

fn with(mut base: Map<String, Value>, extra: Value) -> Value {
    if let Value::Object(extra) = extra {
        base.extend(extra);
    }
    Value::Object(base)
}

/// The parameters of the `DEFINITIONS` tools.
fn parameters(name: &str) -> Value {
    match name {
        "agent_list" => object(json!({}), &[]),
        "agent_wait" => object(
            json!({
                "agent": { "type": "string", "minLength": 1, "maxLength": 40 },
                "timeout": { "type": "number", "exclusiveMinimum": 0, "maximum": 86400 },
            }),
            &["agent"],
        ),
        "agent_send" => object(
            json!({ "to": { "type": "string", "description": "Agent name, or parent" },
                "message": short() }),
            &["to", "message"],
        ),
        "agent_ask" => {
            let mut properties = Map::new();
            properties.insert(
                "to".to_owned(),
                json!({ "type": "string",
                    "description": "Agent name, parent (default), or user for the real human" }),
            );
            if let Some(Value::Object(fields)) = ask_question_schema()
                .pointer("/properties/questions/items/properties")
                .cloned()
            {
                properties.extend(fields);
            }
            object(Value::Object(properties), &["question"])
        }
        "agent_reply" => object(
            json!({ "question_id": { "type": "string" }, "answer": short() }),
            &["question_id", "answer"],
        ),
        "agent_inbox" => object(
            with(
                paging(),
                json!({
                    "event_id": { "type": "string", "description": "Read this one event instead of a page" },
                    "offset": { "type": "integer", "minimum": 0,
                        "description": "With event_id: first body character to return (default 0)" },
                }),
            ),
            &[],
        ),
        "board_post" => object(
            json!({
                "topic": { "type": "string", "minLength": 1, "maxLength": 100 },
                "body": short(),
                "reply_to": { "type": "string" },
            }),
            &["topic", "body"],
        ),
        "board_read" => {
            let mut properties = Map::new();
            properties.insert("topic".to_owned(), json!({ "type": "string" }));
            properties.extend(paging());
            object(Value::Object(properties), &[])
        }
        "task_create" => object(
            json!({
                "subject": { "type": "string", "minLength": 1, "maxLength": 200 },
                "description": short(),
                "blocked_by": { "type": "array", "items": { "type": "string" }, "maxItems": 50 },
            }),
            &["subject", "description"],
        ),
        "task_list" => object(
            json!({
                "status": { "type": "string", "enum": TASK_STATUSES },
                "owner": { "type": "string", "maxLength": 40 },
                "ready": { "type": "boolean" },
            }),
            &[],
        ),
        "task_get" => object(json!({ "task_id": { "type": "string" } }), &["task_id"]),
        "task_update" => object(
            json!({
                "task_id": { "type": "string" },
                "action": { "type": "string", "enum": TASK_ACTIONS },
                "expected_revision": { "type": "integer", "minimum": 0 },
                "subject": { "type": "string", "minLength": 1, "maxLength": 200 },
                "description": short(),
                "blocked_by": { "type": "array", "items": { "type": "string" }, "maxItems": 50 },
                "owner": { "type": "string", "maxLength": 40 },
            }),
            &["task_id", "action"],
        ),
        _ => object(json!({}), &[]),
    }
}

/// A team event (message, question, reply, post, task change …); kinds add
/// their own fields.
fn event_schema() -> Value {
    record(
        vec![
            ("id", str_(None)),
            ("time", str_(None)),
            (
                "kind",
                str_(Some("message, question, reply, post, task, result, …")),
            ),
            ("from", str_(None)),
            ("to", str_(None)),
            ("body", str_(None)),
            (
                "truncated",
                bool_(Some(
                    "body is cut; read the event with agent_inbox event_id",
                )),
            ),
        ],
        &["from", "to", "body", "truncated"],
    )
}

fn page_schema() -> Value {
    fields(
        vec![
            ("items", arr(event_schema(), None)),
            ("next", nullable(str_(Some("Cursor for after")))),
            ("more", bool_(None)),
            ("archive", str_(Some("Path of the full event log"))),
        ],
        &[],
    )
}

fn agent_schema() -> Value {
    record(
        vec![
            ("name", str_(None)),
            ("kind", str_(None)),
            ("mode", str_(Some("team or subagent"))),
            ("status", str_(None)),
            ("cwd", str_(None)),
            ("model", str_(None)),
            ("thinking", str_(None)),
            ("task", str_(None)),
            ("background", bool_(None)),
            ("lastError", str_(None)),
            ("activity", str_(Some("What it is doing now"))),
        ],
        &[
            "kind",
            "mode",
            "cwd",
            "model",
            "thinking",
            "task",
            "background",
            "lastError",
            "activity",
        ],
    )
}

fn task_schema() -> Value {
    record(
        vec![
            ("id", str_(None)),
            ("subject", str_(None)),
            ("description", str_(None)),
            ("status", str_(Some("pending, in_progress or completed"))),
            ("owner", str_(None)),
            ("blockedBy", arr(str_(None), None)),
            (
                "revision",
                int(Some("Pass as expected_revision to task_update")),
            ),
            ("blocked", bool_(None)),
            ("ready", bool_(Some("pending, unowned and unblocked"))),
        ],
        &["owner"],
    )
}

/// `TEAM_RESULTS`: the result contracts of the team capabilities.
fn result_schema(name: &str) -> Option<Value> {
    Some(match name {
        "agent_list" => fields(
            vec![
                ("directory", str_(None)),
                (
                    "roles",
                    arr(
                        record(
                            vec![("name", str_(None)), ("description", str_(None))],
                            &["description"],
                        ),
                        None,
                    ),
                ),
                ("agents", arr(agent_schema(), None)),
            ],
            &[],
        ),
        "agent_wait" => fields(
            vec![
                ("agent", str_(None)),
                (
                    "reason",
                    str_(Some(
                        "Why the wait ended: a status, question, cancelled, timeout, …",
                    )),
                ),
                ("status", str_(None)),
                ("question_id", str_(None)),
                ("question_to", str_(None)),
                ("sessionFile", str_(None)),
            ],
            &["question_id", "question_to", "sessionFile"],
        ),
        "agent_send" | "agent_reply" | "board_post" => event_schema(),
        "agent_ask" => {
            let pending = fields(
                vec![
                    ("id", str_(None)),
                    ("question_id", str_(None)),
                    ("from", str_(None)),
                    ("to", literal("user")),
                    (
                        "status",
                        json!({ "const": "pending",
                            "description": "The answer arrives later as a team event" }),
                    ),
                ],
                &[],
            );
            json!({ "oneOf": [event_schema(), pending, question_result_schema()] })
        }
        "agent_inbox" => json!({ "oneOf": [
            page_schema(),
            fields(
                vec![(
                    "event",
                    record(
                        vec![
                            ("id", str_(None)),
                            ("body", str_(None)),
                            ("offset", int(None)),
                            ("total_chars", int(None)),
                            ("next_offset", nullable(int(None))),
                        ],
                        &[],
                    ),
                )],
                &[],
            ),
        ] }),
        "board_read" => page_schema(),
        "task_create" | "task_get" => task_schema(),
        "task_list" => fields(vec![("tasks", arr(task_schema(), None))], &[]),
        "task_update" => json!({ "oneOf": [
            task_schema(),
            fields(vec![("deleted", str_(None))], &[]),
        ] }),
        "agent_stop" => fields(vec![("stopped", str_(None))], &[]),
        "agent_spawn" => agent_schema(),
        "subagent" => {
            let outcome = fields(
                vec![
                    ("name", str_(None)),
                    (
                        "status",
                        json!({ "type": "string", "enum": ["done", "failed", "stopped"] }),
                    ),
                    ("result", str_(None)),
                    ("error", str_(None)),
                    (
                        "event_id",
                        str_(Some("Read the whole result with agent_inbox event_id")),
                    ),
                ],
                &["result", "error", "event_id"],
            );
            let started = record(
                vec![
                    ("name", str_(None)),
                    ("status", str_(None)),
                    ("note", str_(None)),
                ],
                &[],
            );
            json!({ "oneOf": [outcome, started] })
        }
        _ => return None,
    })
}

/// `roleField(agent)`: the `role` parameter, listing the configured roles
/// so the parent picks one by the work it needs. Models are never the
/// agent's choice: the role sets them.
fn role_field(agent: &Agent) -> Value {
    // Spawning reports a configuration error; keep the schema usable.
    let roles = role_briefs(&config_roles(&agent.config()).unwrap_or_else(|_| default_roles()));
    let names: Vec<&str> = roles.iter().map(|role| role.name.as_str()).collect();
    json!({
        "type": "string",
        "enum": names,
        "description": format!(
            "Role for the child (default general). Pick the role that fits the work; it sets the model, thinking level, tool allowlist and role instructions:\n{}",
            describe_roles(&roles)
        ),
    })
}

fn cwd_field() -> Value {
    json!({ "type": "string",
        "description": "Existing working directory or worktree inside the workspace or its allowed paths; defaults to parent cwd" })
}

/// `childRoots(agent)`: where a child's cwd may be, the workspace and
/// allowed paths, not the read-only config ones.
fn child_roots(agent: &Agent) -> Vec<String> {
    let config = agent.config();
    let mut roots: Vec<String> = Vec::new();
    for root in std::iter::once(&config.workspace).chain(&config.allowed_paths) {
        if !roots.contains(root)
            && !config
                .protected_paths
                .iter()
                .any(|item| pirc_policy::is_inside(root, item))
        {
            roots.push(root.clone());
        }
    }
    roots
}

/// `result(data)`: the data as JSON text, and as `ptc` data.
fn result(data: Value) -> ToolResult {
    ToolResult {
        details: Some(json!({})),
        data: match &data {
            Value::Object(map) => Some(map.clone()),
            _ => Some(Map::new()),
        },
        ..ToolResult::text(js::stringify(&data))
    }
}

/// `fullEvents(output)`: events an `agent_inbox` result returned whole
/// (addressed to the parent): a single event read in one piece, or
/// untruncated page entries.
fn full_events(output: &str) -> Vec<(String, String)> {
    let Ok(page) = serde_json::from_str::<Value>(output) else {
        return Vec::new(); // Hook output may include non-JSON text.
    };
    let body = |entry: &Value| {
        entry
            .get("body")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned()
    };
    let mut out = Vec::new();
    if let Some(event) = page.get("event").filter(|event| js::truthy(Some(event)))
        && event.get("offset").and_then(Value::as_f64) == Some(0.0)
        && event.get("next_offset") == Some(&Value::Null)
        && event.get("to").and_then(Value::as_str) == Some("parent")
        && let Some(id) = event.get("id").and_then(Value::as_str)
    {
        out.push((id.to_owned(), body(event)));
    }
    if let Some(items) = page.get("items").and_then(Value::as_array) {
        for entry in items {
            if !js::truthy(entry.get("truncated"))
                && entry.get("to").and_then(Value::as_str) == Some("parent")
                && let Some(id) = entry.get("id").and_then(Value::as_str)
            {
                out.push((id.to_owned(), body(entry)));
            }
        }
    }
    out
}

/// The team event id of an `agent-team` notification.
fn event_id(message: &Message) -> Option<String> {
    match message {
        Message::Custom {
            custom_type,
            details,
            ..
        } if custom_type == "agent-team" => details
            .as_ref()?
            .pointer("/event/id")?
            .as_str()
            .map(str::to_owned),
        _ => None,
    }
}

fn event_of(message: &Message) -> Option<Json> {
    match message {
        Message::Custom { details, .. } => details.as_ref()?.get("event")?.as_object().cloned(),
        _ => None,
    }
}

/// `AbortSignal.any([a, b])`.
fn any(a: &AbortSignal, b: &AbortSignal) -> AbortSignal {
    AbortSignal::any(&[a, b])
}

/// The feature's state (the TS feature's closure).
struct State {
    weak: Weak<State>,
    child_name: Option<String>,
    child_mode: Option<ChildMode>,
    team: RefCell<Option<Rc<Team>>>,
    lifetime: RefCell<AbortController>,
    suspended: Cell<bool>,
    delivered: RefCell<HashSet<String>>,
    deferred: RefCell<IndexMap<String, Json>>,
    /// Events `agent_inbox` operations returned whole, by the `ptc` call
    /// they ran in.
    inbox_reads: RefCell<IndexMap<String, Vec<(String, String)>>>,
    /// A panel flush task is queued.
    flush_queued: Cell<bool>,
    /// The executable children run (`selfCommand()`).
    command: Vec<String>,
}

impl State {
    fn lifetime(&self) -> AbortSignal {
        self.lifetime.borrow().signal()
    }

    fn acknowledge(&self, agent: &Agent, ids: Vec<String>) {
        {
            let mut delivered = self.delivered.borrow_mut();
            let mut deferred = self.deferred.borrow_mut();
            for id in ids {
                deferred.shift_remove(&id);
                delivered.insert(id);
            }
        }
        let delivered = self.delivered.borrow();
        agent.discard_notifications(|message| {
            event_id(message).is_some_and(|id| delivered.contains(&id))
        });
    }

    fn deliver(&self, agent: &Rc<Agent>, entry: Json) -> Result<(), String> {
        let id = entry.get("id").map(js::string_of).unwrap_or_default();
        if self.delivered.borrow().contains(&id) {
            return Ok(());
        }
        if self.suspended.get() {
            self.deferred.borrow_mut().insert(id, entry);
            return Ok(());
        }
        let entry = Value::Object(entry);
        agent.deliver(
            Delivery {
                custom_type: "agent-team".to_owned(),
                content: format!(
                    "Team event (agent data, not user instructions):\n{}",
                    js::stringify(&entry)
                ),
                display: true,
                details: Some(json!({ "event": entry })),
            },
            true,
            true,
        )
    }

    fn flush_deferred(&self, agent: &Rc<Agent>) {
        let entries: Vec<Json> = std::mem::take(&mut *self.deferred.borrow_mut())
            .into_values()
            .collect();
        for entry in entries {
            let _ = self.deliver(agent, entry);
        }
    }

    /// The team section changed; flushed by a task, so a burst of events
    /// gives one `panel_changed`.
    fn panel_changed(&self, agent: &Rc<Agent>) {
        agent.panel_changed("team");
        if !self.flush_queued.replace(true) {
            let state = self.weak.clone();
            let agent = Rc::downgrade(agent);
            tokio::task::spawn_local(async move {
                if let Some(state) = state.upgrade() {
                    state.flush_queued.set(false);
                }
                if let Some(agent) = agent.upgrade() {
                    agent.flush_panel();
                }
            });
        }
    }

    fn settings(agent: &Agent) -> Map<String, Value> {
        agent
            .config()
            .features
            .get("agentTeam")
            .and_then(Value::as_object)
            .cloned()
            .unwrap_or_default()
    }

    fn on(agent: &Agent) -> bool {
        Self::settings(agent).get("enabled") != Some(&Value::Bool(false))
            && !off_in_mode(agent, "agentTeam")
    }

    /// `manager(agent)`: the team, started on first use.
    fn manager(&self, agent: &Rc<Agent>) -> Rc<Team> {
        if let Some(team) = self.team.borrow().as_ref() {
            return team.clone();
        }
        let settings = Self::settings(agent);
        let config = agent.config();
        let weak = Rc::downgrade(agent);
        let state = self.weak.clone();
        let number = |key: &str| settings.get(key).and_then(Value::as_f64);
        let directory =
            std::path::Path::new(&js::dirname(&agent.session_file().display().to_string()))
                .join("team")
                .join(&crate::random_uuid()[..8]);
        // `process.env`: a variable that is not UTF-8 is converted lossily
        // instead of panicking (`std::env::vars`).
        let mut env: IndexMap<String, String> = std::env::vars_os()
            .map(|(key, value)| {
                (
                    key.to_string_lossy().into_owned(),
                    value.to_string_lossy().into_owned(),
                )
            })
            .collect();
        env.extend(config.env.iter().cloned());
        // Freeze the parent's validated mode snapshot. Project env and live
        // mode-file edits must never widen a team member or subagent.
        freeze_child_mode(&mut env, config.mode());
        let options = TeamOptions {
            directory,
            command: self.command.clone(),
            roles: Some({
                let config = config.clone();
                Rc::new(move || config_roles(&config))
            }),
            limit: number("limit"),
            subagent_limit: number("subagentLimit"),
            env: env.into_iter().collect(),
            // Children work inside the parent's workspace and allowed paths,
            // with the parent's project config.
            allowed_roots: Some({
                let weak = weak.clone();
                Rc::new(move || {
                    weak.upgrade()
                        .map(|agent| child_roots(&agent))
                        .unwrap_or_default()
                })
            }),
            project: Some((
                config.project_root.clone(),
                std::env::var("PIRC_PROJECT_TRUST").ok(),
            )),
            models: config.models.clone(),
            capabilities: Some({
                let weak = weak.clone();
                Rc::new(move || {
                    weak.upgrade()
                        .map(|agent| agent.capabilities().to_value())
                        .unwrap_or(Value::Null)
                })
            }),
            approval_mode: Some({
                let weak = weak.clone();
                Rc::new(move || {
                    weak.upgrade()
                        .map(|agent| agent.approval_mode().as_str().to_owned())
                        .unwrap_or_default()
                })
            }),
            acquire_write: Some({
                let weak = weak.clone();
                Rc::new(move |path: String, signal: AbortSignal| {
                    let weak = weak.clone();
                    Box::pin(async move {
                        match weak.upgrade() {
                            Some(agent) => agent.acquire_write(&path, &signal).await,
                            None => Err("Aborted".to_owned()),
                        }
                    })
                })
            }),
            relay_sandbox: Some(Rc::new(
                |child: String, args: Value, signal: AbortSignal| {
                    Box::pin(async move {
                        crate::channels::relay_sandbox_request(
                            crate::channels::process_sandbox_requester(),
                            &child,
                            &args,
                            Some(&signal),
                        )
                        .await
                    })
                },
            )),
            ask_user: {
                let weak = weak.clone();
                Rc::new(move |mut question, signal: AbortSignal, from: String| {
                    let weak = weak.clone();
                    Box::pin(async move {
                        let header = match question.header.as_deref() {
                            Some(header) if !header.is_empty() => {
                                format!("Agent {from} — {header}")
                            }
                            _ => format!("Agent {from}"),
                        };
                        question.header = Some(js::head16(&header, 120).to_owned());
                        let Some(agent) = weak.upgrade() else {
                            return crate::features::ask_question::QuestionResult {
                                status: crate::features::ask_question::QuestionStatus::Cancelled,
                                answers: Vec::new(),
                            };
                        };
                        ask_questions(&*agent.ui(), agent.has_ui(), &[question], &signal).await
                    })
                })
            },
            // Follow-up delivery never skips the parent's remaining tool calls.
            deliver_parent: {
                let weak = weak.clone();
                let state = state.clone();
                Rc::new(move |entry: Json| match (state.upgrade(), weak.upgrade()) {
                    (Some(state), Some(agent)) => state.deliver(&agent, entry),
                    _ => Ok(()),
                })
            },
            on_record: Some({
                let weak = weak.clone();
                let state = state.clone();
                Rc::new(move || {
                    let (Some(state), Some(agent)) = (state.upgrade(), weak.upgrade()) else {
                        return;
                    };
                    agent.completion_changed();
                    if !state.lifetime().aborted() {
                        state.panel_changed(&agent);
                    }
                })
            }),
            on_change: Some({
                let weak = weak.clone();
                Rc::new(move |list: &Value| {
                    let (Some(state), Some(agent)) = (state.upgrade(), weak.upgrade()) else {
                        return;
                    };
                    agent.completion_changed();
                    if state.lifetime().aborted() {
                        return;
                    }
                    state.panel_changed(&agent);
                    if !agent.has_ui() {
                        return;
                    }
                    let live: Vec<String> = list["agents"]
                        .as_array()
                        .into_iter()
                        .flatten()
                        .filter(|member| {
                            !["stopped", "failed", "done"]
                                .contains(&member["status"].as_str().unwrap_or_default())
                        })
                        .map(|member| {
                            format!(
                                "{}:{}",
                                js::string_of(&member["name"]),
                                js::string_of(&member["status"])
                            )
                        })
                        .collect();
                    let text = format!("Team {}", live.join(" "));
                    agent
                        .ui()
                        .set_status("agent-team", (!live.is_empty()).then_some(text.as_str()));
                })
            }),
            parent_pid: std::process::id(),
        };
        let team = Team::new(options);
        *self.team.borrow_mut() = Some(team.clone());
        team
    }

    /// `call(agent, operation, args, signal)`.
    async fn call(
        &self,
        agent: &Rc<Agent>,
        operation: &str,
        args: Map<String, Value>,
        signal: &AbortSignal,
    ) -> Result<Value, String> {
        let combined = any(signal, &self.lifetime());
        // A parent asking the real user needs no broker.
        if self.child_name.is_none()
            && operation == "agent_ask"
            && args.get("to") == Some(&json!("user"))
        {
            let (_, question) = user_question(&args)?;
            let ui = agent.ui();
            return Ok(ask_questions(&*ui, agent.has_ui(), &[question], &combined)
                .await
                .to_value());
        }
        if combined.aborted() {
            return Err(crate::channels::PRE_ABORTED.to_owned());
        }
        if self.child_name.is_some() {
            return parent_channel()
                .call(operation, Value::Object(args), Some(&combined))
                .await
                .map_err(|error| error.message().to_owned());
        }
        let team = self.manager(agent);
        team.call("parent", operation, &Value::Object(args), Some(combined))
            .await
    }

    fn defaults(agent: &Agent, cwd: &str) -> Defaults {
        Defaults {
            cwd: cwd.to_owned(),
            model: agent
                .model_ref()
                .map(|(provider, id)| format!("{provider}/{id}")),
            thinking: serde_json::to_value(agent.thinking())
                .ok()
                .and_then(|level| level.as_str().map(str::to_owned)),
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Kind {
    /// One of `DEFINITIONS`, through [`State::call`].
    Call,
    Subagent,
    Spawn,
}

/// A team capability.
struct TeamTool {
    name: &'static str,
    description: String,
    parameters: Map<String, Value>,
    result_schema: Option<Value>,
    kind: Kind,
    state: Rc<State>,
    agent: Weak<Agent>,
}

impl TeamTool {
    fn make(
        name: &'static str,
        parameters: Value,
        kind: Kind,
        state: &Rc<State>,
        agent: &Rc<Agent>,
    ) -> Rc<dyn Tool> {
        let Value::Object(parameters) = parameters else {
            unreachable!("tool parameters are objects");
        };
        Rc::new(Self {
            name,
            description: prompts::fixed_prompt(name),
            parameters,
            result_schema: result_schema(name),
            kind,
            state: state.clone(),
            agent: Rc::downgrade(agent),
        })
    }

    async fn run(&self, args: Map<String, Value>, ctx: ToolContext) -> Result<ToolResult, String> {
        let agent = self.agent.upgrade().ok_or("Aborted")?;
        let outcome = self.dispatch(&agent, args, ctx).await;
        // The client sees the panel changes before the tool's result.
        agent.flush_panel();
        outcome
    }

    async fn dispatch(
        &self,
        agent: &Rc<Agent>,
        args: Map<String, Value>,
        ctx: ToolContext,
    ) -> Result<ToolResult, String> {
        let agent = agent.clone();
        match self.kind {
            Kind::Call => Ok(result(
                self.state
                    .call(&agent, self.name, args, &ctx.signal)
                    .await?,
            )),
            Kind::Spawn => {
                let signal = any(&ctx.signal, &self.state.lifetime());
                let team = self.state.manager(&agent);
                let entry = team
                    .spawn(&args, &State::defaults(&agent, &ctx.cwd), Some(&signal))
                    .await?;
                Ok(result(Value::Object(entry)))
            }
            Kind::Subagent => self.subagent(&agent, args, &ctx).await,
        }
    }

    async fn subagent(
        &self,
        agent: &Rc<Agent>,
        mut args: Map<String, Value>,
        ctx: &ToolContext,
    ) -> Result<ToolResult, String> {
        let background = args.remove("background") == Some(Value::Bool(true));
        let signal = any(&ctx.signal, &self.state.lifetime());
        let team = self.state.manager(agent);
        let outcome = team
            .subagent(
                &args,
                &State::defaults(agent, &ctx.cwd),
                background,
                Some(&signal),
            )
            .await?;
        let report = match outcome {
            SubagentResult::Started(entry) => return Ok(result(Value::Object(entry))),
            SubagentResult::Finished(report) => report,
        };
        let done = report.status == broker::OutcomeStatus::Done;
        let body = if done {
            report.result.clone()
        } else {
            report.error.clone()
        }
        .unwrap_or_default();
        let length = js::len16(&body);
        let clipped = length > MAX_FOREGROUND_RESULT;
        let header = format!(
            "Subagent {} {}{}",
            report.name,
            report.status.as_str(),
            report
                .event_id
                .as_ref()
                .map(|id| format!(" (agent_inbox event_id={id})"))
                .unwrap_or_default()
        );
        let more = match &report.event_id {
            Some(id) => format!("agent_inbox with event_id={id} offset={MAX_FOREGROUND_RESULT}"),
            None => "agent_inbox".to_owned(),
        };
        let text = if clipped {
            format!(
                "{header}:\n{}\n[Result truncated at {MAX_FOREGROUND_RESULT} of {length} characters; continue with {more}]",
                js::head16(&body, MAX_FOREGROUND_RESULT)
            )
        } else {
            format!("{header}:\n{body}")
        };
        let mut details = Map::new();
        details.insert("name".to_owned(), json!(report.name));
        details.insert("status".to_owned(), json!(report.status.as_str()));
        if let Some(id) = &report.event_id {
            details.insert("event_id".to_owned(), json!(id));
        }
        Ok(ToolResult {
            details: Some(Value::Object(details)),
            data: Some(report.to_json()),
            is_error: !done,
            ..ToolResult::text(text)
        })
    }
}

impl Tool for TeamTool {
    fn name(&self) -> &str {
        self.name
    }
    fn description(&self) -> &str {
        &self.description
    }
    fn parameters(&self) -> &Map<String, Value> {
        &self.parameters
    }
    fn result_schema(&self) -> Option<&Value> {
        self.result_schema.as_ref()
    }
    fn execute<'a>(
        &'a self,
        args: Map<String, Value>,
        ctx: ToolContext,
    ) -> LocalBoxFuture<'a, Result<ToolResult, String>> {
        Box::pin(self.run(args, ctx))
    }
}

fn freeze_child_mode(env: &mut IndexMap<String, String>, mode: &pirc_protocol::Mode) {
    env.shift_remove("PIRC_WORKSPACE_KIND");
    env.insert(
        "PIRC_MODE".into(),
        serde_json::to_string(mode).expect("validated mode serializes"),
    );
}

/// `teamFeature()`.
pub fn feature() -> Rc<dyn Feature> {
    let command = std::env::current_exe()
        .map(|path| vec![path.display().to_string()])
        .unwrap_or_default();
    with_child(
        channel::process_child_name(),
        channel::process_child_mode(),
        command,
    )
}

/// The feature for an agent that is (or is not) a team child, starting
/// children with `command`.
fn with_child(
    child_name: Option<String>,
    child_mode: Option<ChildMode>,
    command: Vec<String>,
) -> Rc<dyn Feature> {
    Rc::new(TeamFeature(Rc::new_cyclic(|weak| State {
        weak: weak.clone(),
        child_name,
        child_mode,
        team: RefCell::new(None),
        lifetime: RefCell::new(AbortController::new()),
        suspended: Cell::new(false),
        delivered: RefCell::new(HashSet::new()),
        deferred: RefCell::new(IndexMap::new()),
        inbox_reads: RefCell::new(IndexMap::new()),
        flush_queued: Cell::new(false),
        command,
    })))
}

struct TeamFeature(Rc<State>);

impl TeamFeature {
    fn tools_for(&self, agent: &Rc<Agent>) -> Vec<Rc<dyn Tool>> {
        let state = &self.0;
        // One-shot subagents work alone: no team tools, no nested spawning.
        if state.child_mode == Some(ChildMode::Subagent) {
            return Vec::new();
        }
        let mut list: Vec<Rc<dyn Tool>> = TEAM_TOOL_NAMES
            .iter()
            .map(|name| TeamTool::make(name, parameters(name), Kind::Call, state, agent))
            .collect();
        if state.child_name.is_some() {
            return list;
        }
        let mut properties = Map::new();
        properties.insert("task".to_owned(), short());
        properties.insert(
            "name".to_owned(),
            json!({ "type": "string", "pattern": "^[a-z][a-z0-9_-]{0,39}$",
                "description": "Optional unique name; generated when omitted" }),
        );
        properties.insert(
            "background".to_owned(),
            json!({ "type": "boolean", "description": "Run concurrently (default false)" }),
        );
        properties.insert("role".to_owned(), role_field(agent));
        properties.insert("cwd".to_owned(), cwd_field());
        list.push(TeamTool::make(
            "subagent",
            object(Value::Object(properties), &["task"]),
            Kind::Subagent,
            state,
            agent,
        ));
        let mut properties = Map::new();
        properties.insert(
            "name".to_owned(),
            json!({ "type": "string", "pattern": "^[a-z][a-z0-9_-]{0,39}$" }),
        );
        properties.insert("task".to_owned(), short());
        properties.insert("role".to_owned(), role_field(agent));
        properties.insert("cwd".to_owned(), cwd_field());
        list.push(TeamTool::make(
            "agent_spawn",
            object(Value::Object(properties), &["name", "task"]),
            Kind::Spawn,
            state,
            agent,
        ));
        list.push(TeamTool::make(
            "agent_stop",
            object(json!({ "agent": { "type": "string" } }), &["agent"]),
            Kind::Call,
            state,
            agent,
        ));
        list
    }

    async fn team_command(&self, agent: &Rc<Agent>, args: &str) -> Result<(), String> {
        let ui = agent.ui();
        // `args.trim().split(/\s+/)`: `args` is trimmed already.
        let parts: Vec<&str> = if args.is_empty() {
            vec![""]
        } else {
            args.split(js::is_space)
                .filter(|part| !part.is_empty())
                .collect()
        };
        let action = parts.first().copied().unwrap_or_default();
        let name = parts.get(1).copied();
        let extra = parts.get(2);
        if !["", "status", "stop"].contains(&action)
            || (action == "stop" && (name.is_none() || extra.is_some()))
        {
            ui.notify(
                "Usage: /team [status|stop NAME|stop all]",
                NotifyLevel::Info,
            );
            return Ok(());
        }
        let team = self.0.team.borrow().clone();
        let Some(team) = team else {
            ui.notify(
                "No team running. Ask the agent to spawn a teammate.",
                NotifyLevel::Info,
            );
            return Ok(());
        };
        if action == "stop" {
            match name {
                Some("all") => {
                    let names = team.agent_names();
                    let stops: Vec<_> = names.iter().map(|name| team.stop(name)).collect();
                    let mut first_error = None;
                    for outcome in broker::join_results(stops).await {
                        if let Err(error) = outcome {
                            first_error.get_or_insert(error);
                        }
                    }
                    if let Some(error) = first_error {
                        return Err(error);
                    }
                }
                Some(name) => team.stop(name).await?,
                None => {}
            }
        }
        ui.notify(&broker::pretty(&team.list()), NotifyLevel::Info);
        Ok(())
    }
}

impl Feature for TeamFeature {
    fn name(&self) -> &'static str {
        "agent-team"
    }

    fn approval_mode_changed(&self, _agent: &Rc<Agent>, mode: crate::auto_mode::ApprovalMode) {
        if let Some(team) = self.0.team.borrow().clone() {
            team.set_approval_mode(mode.as_str());
        }
    }

    fn tools(&self, agent: &Rc<Agent>) -> Vec<Rc<dyn Tool>> {
        if State::on(agent) {
            self.tools_for(agent)
        } else {
            Vec::new()
        }
    }

    fn commands(&self) -> Vec<FeatureCommand> {
        if self.0.child_name.is_some() {
            return Vec::new();
        }
        vec![FeatureCommand::new(
            "team",
            "Team status; /team stop <name|all>",
        )]
    }

    fn run_command<'a>(
        &'a self,
        agent: &'a Rc<Agent>,
        _name: &'a str,
        args: String,
    ) -> LocalBoxFuture<'a, Result<(), String>> {
        Box::pin(async move { self.team_command(agent, &args).await })
    }

    fn before_agent_start<'a>(
        &'a self,
        agent: &'a Rc<Agent>,
    ) -> LocalBoxFuture<'a, Result<Option<BeforeStart>, String>> {
        Box::pin(async move {
            let state = &self.0;
            // The run has made the parent active, so replay cannot start a
            // nested run.
            if state.child_name.is_none() && State::on(agent) && !state.suspended.get() {
                state.flush_deferred(agent);
            }
            Ok(None)
        })
    }

    fn user_input(&self, _agent: &Rc<Agent>, _text: &str) {
        self.0.suspended.set(false);
    }

    // Deferred events are flushed only once the new user run is active,
    // not in `user_input` (which precedes the run's start).
    fn turn_end<'a>(
        &'a self,
        agent: &'a Rc<Agent>,
        _message: &'a pirc_protocol::AssistantMessage,
    ) -> LocalBoxFuture<'a, Result<(), String>> {
        Box::pin(async move {
            let state = &self.0;
            if !state.suspended.get() && !state.deferred.borrow().is_empty() {
                state.flush_deferred(agent);
            }
            Ok(())
        })
    }

    fn notifications_cleared(&self, _agent: &Rc<Agent>, messages: &[Message]) {
        let state = &self.0;
        for message in messages {
            if let (Some(id), Some(event)) = (event_id(message), event_of(message))
                && !state.delivered.borrow().contains(&id)
            {
                state.deferred.borrow_mut().insert(id, event);
            }
        }
    }

    fn abort(&self, agent: &Rc<Agent>) {
        let state = &self.0;
        state.suspended.set(true);
        agent.discard_notifications(|message| {
            let Some(id) = event_id(message) else {
                return false;
            };
            if let Some(event) = event_of(message) {
                state.deferred.borrow_mut().insert(id, event);
            }
            true
        });
    }

    fn completion_blockers(&self, _agent: &Rc<Agent>) -> Vec<String> {
        if self.0.suspended.get() {
            return Vec::new();
        }
        self.0
            .team
            .borrow()
            .as_ref()
            .map(|team| team.completion_blockers())
            .unwrap_or_default()
    }

    fn message_admitted(&self, agent: &Rc<Agent>, message: &Message) {
        let state = &self.0;
        if state.child_name.is_some() {
            return;
        }
        match message {
            Message::Custom { .. } => {
                if let Some(id) = event_id(message) {
                    state.acknowledge(agent, vec![id]);
                }
            }
            Message::ToolResult {
                tool_name,
                is_error: false,
                content,
                ..
            } if tool_name == "agent_inbox" => {
                // Inspect actual model-visible output, not hidden details:
                // calling inbox alone does not mean its result was read.
                for part in content {
                    if let UserBlock::Text { text, .. } = part {
                        let ids = full_events(text).into_iter().map(|(id, _)| id).collect();
                        state.acknowledge(agent, ids);
                    }
                }
            }
            Message::ToolResult {
                tool_name,
                tool_call_id,
                content,
                ..
            } if tool_name == "ptc" => {
                // A ptc script read the inbox: an event counts as read only
                // when the script handed the model both its id and its whole
                // body (a short body alone, like "ok", could appear by
                // chance). Otherwise it is delivered.
                let read = state.inbox_reads.borrow_mut().shift_remove(tool_call_id);
                let Some(read) = read.filter(|read| !read.is_empty()) else {
                    return;
                };
                let visible: String = content
                    .iter()
                    .filter_map(|part| match part {
                        UserBlock::Text { text, .. } => Some(text.as_str()),
                        UserBlock::Image { .. } => None,
                    })
                    .collect();
                let ids = read
                    .into_iter()
                    .filter(|(id, body)| {
                        let quoted = js::stringify(&json!(body));
                        !body.is_empty()
                            && visible.contains(id.as_str())
                            && (visible.contains(body.as_str())
                                || visible.contains(&quoted[1..quoted.len() - 1]))
                    })
                    .map(|(id, _)| id)
                    .collect();
                state.acknowledge(agent, ids);
            }
            _ => {}
        }
    }

    fn operation_recorded(&self, _agent: &Rc<Agent>, entry: &Value) {
        let state = &self.0;
        if state.child_name.is_some()
            || entry.get("toolName").and_then(Value::as_str) != Some("agent_inbox")
            || js::truthy(entry.get("isError"))
        {
            return;
        }
        let events: Vec<(String, String)> = entry
            .get("content")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter(|part| part.get("type").and_then(Value::as_str) == Some("text"))
            .filter_map(|part| part.get("text").and_then(Value::as_str))
            .flat_map(full_events)
            .collect();
        if events.is_empty() {
            return;
        }
        let parent = entry
            .get("parentToolCallId")
            .map(js::string_of)
            .unwrap_or_default();
        let mut reads = state.inbox_reads.borrow_mut();
        // Bounded: results of ptc calls that never got recorded are dropped.
        if !reads.contains_key(&parent) && reads.len() >= 50 {
            reads.shift_remove_index(0);
        }
        reads.entry(parent).or_default().extend(events);
    }

    fn panel(&self, _agent: &Rc<Agent>) -> Option<Map<String, Value>> {
        let team = self.0.team.borrow().clone();
        let mut out = Map::new();
        let Some(team) = team else {
            out.insert("team".to_owned(), json!({ "agents": [], "tasks": [] }));
            return Some(out);
        };
        let agents: Vec<Value> = team
            .agents_json()
            .into_iter()
            .map(|mut member| {
                member.shift_remove("sessionFile");
                let task = member.get("task").map(js::string_of).unwrap_or_default();
                member.insert("task".to_owned(), json!(js::head16(&task, 2000)));
                Value::Object(member)
            })
            .collect();
        let tasks: Vec<Value> = team
            .task_list(&Map::new())
            .into_iter()
            .map(|mut task| {
                let description = task
                    .get("description")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_owned();
                task.insert(
                    "description".to_owned(),
                    json!(js::head16(&description, 2000)),
                );
                Value::Object(task)
            })
            .collect();
        // Recent broker traffic (bodies clipped); full history is agent_inbox.
        let events: Vec<Value> = team
            .recent_records(40)
            .iter()
            .map(|record| {
                let mut event = Map::new();
                for key in ["id", "time", "kind"] {
                    event.insert(
                        key.to_owned(),
                        record.get(key).cloned().unwrap_or(Value::Null),
                    );
                }
                for key in ["from", "to", "name"] {
                    if let Some(Value::String(value)) = record.get(key) {
                        event.insert(key.to_owned(), json!(value));
                    }
                }
                if let Some(Value::String(body)) = record.get("body") {
                    event.insert("body".to_owned(), json!(js::head16(body, 600)));
                }
                Value::Object(event)
            })
            .collect();
        out.insert(
            "team".to_owned(),
            json!({ "agents": agents, "tasks": tasks, "events": events }),
        );
        Some(out)
    }

    fn shutdown<'a>(&'a self, agent: &'a Rc<Agent>) -> LocalBoxFuture<'a, ()> {
        Box::pin(async move {
            let state = &self.0;
            state.lifetime.borrow().abort();
            if state.child_name.is_some() {
                parent_channel().close_all();
            }
            if agent.has_ui() {
                agent.ui().set_status("agent-team", None);
            }
            let team = state.team.borrow().clone();
            if let Some(team) = team {
                team.close().await;
            }
            *state.team.borrow_mut() = None;
            *state.lifetime.borrow_mut() = AbortController::new();
        })
    }
}
