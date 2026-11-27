use super::*;

fn mode_agent(
    dir: &std::path::Path,
    mode: pirc_protocol::Mode,
    features: Value,
    allowed_tools: Option<Vec<String>>,
) -> Rc<Agent> {
    mode_agent_with_ui(dir, mode, features, allowed_tools).0
}

fn mode_agent_with_ui(
    dir: &std::path::Path,
    mode: pirc_protocol::Mode,
    features: Value,
    allowed_tools: Option<Vec<String>>,
) -> (Rc<Agent>, Rc<crate::tools::testing::TestUi>) {
    let ui = Rc::new(crate::tools::testing::TestUi::default());
    let mut config = crate::tools::testing::config(&dir.display().to_string(), features);
    config.mode = mode;
    config.role_dirs = crate::roles::role_dirs(&config.config_dir, &config.workspace);
    let store = SessionStore::open(dir.join("session"), &config.workspace).unwrap();
    let agent = Agent::new(AgentOptions {
        config,
        capabilities: Default::default(),
        role: None,
        store,
        emit: Rc::new(|_| {}),
        ui: ui.clone(),
        has_ui: false,
        tools: crate::tools::builtin_tools(),
        features: crate::features::builtin_features(),
        acquire_write: None,
        allowed_tools,
        stream_override: None,
    });
    (agent, ui)
}

#[test]
fn mode_configures_every_feature_without_removing_diagnostics() {
    for key in pirc_protocol::mode::FEATURE_NAMES {
        for mode_enabled in [false, true] {
            for explicit in [None, Some(true), Some(false)] {
                let dir = tempfile::tempdir().unwrap();
                let mut mode = pirc_protocol::mode::default_work();
                if mode_enabled {
                    mode.features_on.push((*key).into());
                } else {
                    mode.features_off.push((*key).into());
                }
                let mut features = json!({});
                if let Some(enabled) = explicit {
                    features[*key] = json!({"enabled":enabled});
                }
                let agent = mode_agent(dir.path(), mode, features, None);
                assert!(
                    agent.features.iter().any(|feature| {
                        crate::features::config_key(feature.name()) == Some(*key)
                    }),
                    "{key} must retain its diagnostics"
                );
                assert_eq!(
                    agent.config.features[*key]["enabled"],
                    json!(explicit.unwrap_or(mode_enabled)),
                    "{key}"
                );
            }
        }
    }
}

#[test]
fn mode_features_hide_default_off_tools_but_keep_management_commands() {
    let dir = tempfile::tempdir().unwrap();
    let mut mode = pirc_protocol::mode::default_work();
    mode.features_off = vec!["todo".into(), "background".into()];
    let agent = mode_agent(dir.path(), mode, json!({}), None);
    let commands = agent
        .features
        .iter()
        .flat_map(|feature| feature.commands())
        .map(|command| command.name.to_string())
        .collect::<Vec<_>>();
    assert!(commands.iter().any(|name| name == "todo"));
    assert!(commands.iter().any(|name| name == "bg"));
    assert!(agent.get_tool("todo").is_none());
    assert!(agent.get_tool("background_task").is_none());
}

#[test]
fn mode_tool_registry_matches_actual_registered_operation_names() {
    use crate::features::{assistant, browser, calendar, pot, sandbox, schedules, web_search};
    let dir = tempfile::tempdir().unwrap();
    let agent = mode_agent(
        dir.path(),
        pirc_protocol::mode::default_work(),
        json!({}),
        None,
    );
    let mut names: std::collections::BTreeSet<String> = agent
        .available_tools()
        .iter()
        .map(|tool| tool.name().to_owned())
        .collect();
    names.extend(browser::registered_tool_names());
    names.extend(sandbox::registered_tool_names());
    names.extend(schedules::registered_tool_names());
    names.extend(calendar::registered_tool_names());
    names.extend(web_search::registered_tool_names());
    names.extend(pot::registered_tool_names());
    for name in [
        assistant::NOTE_TOOL,
        assistant::PROPOSE_TOOL,
        assistant::SEARCH_TOOL,
    ] {
        names.insert(name.to_owned());
    }
    let declared = pirc_protocol::mode::TOOL_NAMES
        .iter()
        .map(|name| (*name).to_owned())
        .collect();
    assert_eq!(names, declared);
}

#[test]
fn mode_tool_ceiling_survives_roles_cli_and_recorded_role_restoration() {
    let dir = tempfile::tempdir().unwrap();
    let mut mode = pirc_protocol::mode::default_work();
    mode.tools = Some(vec!["read".into()]);
    let agent = mode_agent(
        dir.path(),
        mode.clone(),
        json!({}),
        Some(vec!["read".into(), "write".into(), "ptc".into()]),
    );
    let roles = dir.path().join(".pirc/roles");
    std::fs::create_dir_all(&roles).unwrap();
    std::fs::write(
        roles.join("wide.md"),
        "---\ntools: [read, write, agent_spawn]\n---\n",
    )
    .unwrap();
    agent.set_role("wide").unwrap();
    assert_eq!(
        agent
            .available_tools()
            .iter()
            .map(|tool| tool.name())
            .collect::<Vec<_>>(),
        ["read"]
    );
    assert!(agent.get_tool("write").is_none());
    assert!(agent.get_tool("ptc").is_none());
    assert_eq!(
        agent
            .model_tool_list()
            .iter()
            .map(|tool| tool.name())
            .collect::<Vec<_>>(),
        ["ptc", "ptc_docs", "read"]
    );
    drop(agent);
    let restored = mode_agent(dir.path(), mode, json!({}), None);
    assert_eq!(
        restored
            .available_tools()
            .iter()
            .map(|tool| tool.name())
            .collect::<Vec<_>>(),
        ["read"]
    );
    assert_eq!(restored.role.borrow().as_ref().unwrap().name, "wide");
}

#[tokio::test]
async fn mode_denied_operations_cannot_execute_through_ptc() {
    let dir = tempfile::tempdir().unwrap();
    let mut mode = pirc_protocol::mode::default_work();
    mode.tools = Some(vec!["read".into()]);
    let agent = mode_agent(dir.path(), mode.clone(), json!({}), None);
    let outcome = agent
        .run_operation(
            "ptc-call",
            "write",
            json!({"path":"escaped.txt","content":"no"})
                .as_object()
                .unwrap()
                .clone(),
            &AbortSignal::never(),
            "op-denied",
            OperationOptions::default(),
        )
        .await;
    assert!(outcome.result.is_error);
    assert!(!dir.path().join("escaped.txt").exists());
    mode.tools = Some(Vec::new());
    let empty = mode_agent(dir.path(), mode, json!({}), None);
    assert!(empty.available_tools().is_empty());
    assert!(empty.model_tool_list().is_empty());
}

/// What the probe tools saw of the run's agent loop.
type Seen = Rc<RefCell<Vec<(String, Vec<(CallKey, WaitReason)>)>>>;

fn loop_waits(agent: &Weak<Agent>) -> Vec<(CallKey, WaitReason)> {
    let agent = agent.upgrade().unwrap();
    let run_loop = agent.run_loop.borrow();
    run_loop.as_ref().map(RunLoop::waiting).unwrap_or_default()
}

/// The first reply streams a text block and one `read` call, recording
/// the agent loop's partial after each delta; the second just ends.
struct Streamed {
    agent: RefCell<Weak<Agent>>,
    calls: Cell<usize>,
    partials: RefCell<Vec<Vec<AssistantContent>>>,
}

impl crate::stream::StreamFn for Streamed {
    fn stream<'a>(
        &'a self,
        request: StreamRequest,
        on_delta: &'a mut dyn FnMut(&pirc_protocol::AssistantDelta),
    ) -> LocalBoxFuture<'a, AssistantMessage> {
        Box::pin(async move {
            use pirc_protocol::AssistantDelta as D;
            self.calls.set(self.calls.get() + 1);
            let agent = self.agent.borrow().upgrade().unwrap();
            let mut reply = agent.empty_assistant();
            reply.provider = request.provider_name;
            reply.model = request.model.id;
            if self.calls.get() > 1 {
                reply.content = vec![AssistantContent::Text {
                    text: "Done.".to_owned(),
                    text_signature: None,
                }];
                return reply;
            }
            let probe = AssistantContent::ToolCall {
                id: "w1".to_owned(),
                name: "read".to_owned(),
                arguments: Map::new(),
                thought_signature: None,
            };
            for delta in [
                D::TextStart { content_index: 0 },
                D::TextDelta {
                    content_index: 0,
                    delta: "Check".to_owned(),
                },
                D::TextEnd {
                    content_index: 0,
                    content: "Checking".to_owned(),
                },
                D::ToolcallStart {
                    content_index: 1,
                    id: "w1".to_owned(),
                    tool_name: "read".to_owned(),
                },
                D::ToolcallEnd {
                    content_index: 1,
                    tool_call: probe.clone(),
                },
            ] {
                on_delta(&delta);
                let run_loop = agent.run_loop.borrow();
                let partial = run_loop.as_ref().and_then(RunLoop::partial);
                self.partials
                    .borrow_mut()
                    .push(partial.map(|p| p.content.clone()).unwrap_or_default());
            }
            reply.content = vec![
                AssistantContent::Text {
                    text: "Checking".to_owned(),
                    text_signature: None,
                },
                probe,
            ];
            reply.stop_reason = StopReason::ToolUse;
            reply
        })
    }
}

/// `read` (so the model calls it directly) opens dialogs and takes the
/// write lease; `grep` is run by it as a ptc operation from another task.
struct Probe {
    name: &'static str,
    agent: Rc<RefCell<Weak<Agent>>>,
    seen: Seen,
    parameters: Map<String, Value>,
}

impl Probe {
    fn look(&self, step: &str) {
        let waits = loop_waits(&self.agent.borrow());
        self.seen.borrow_mut().push((step.to_owned(), waits));
    }
}

impl Tool for Probe {
    fn name(&self) -> &str {
        self.name
    }
    fn description(&self) -> &str {
        "probe"
    }
    fn parameters(&self) -> &Map<String, Value> {
        &self.parameters
    }
    fn execute<'a>(
        &'a self,
        _args: Map<String, Value>,
        ctx: ToolContext,
    ) -> LocalBoxFuture<'a, Result<ToolResult, String>> {
        Box::pin(async move {
            if self.name == "grep" {
                let dialog = ctx
                    .ui
                    .confirm("Probe", "op dialog", DialogOptions::default());
                self.look("op dialog");
                dialog.await;
                return Ok(ToolResult::text("op"));
            }
            let dialog = ctx.ui.confirm("Probe", "dialog", DialogOptions::default());
            self.look("dialog");
            dialog.await;
            self.look("dialog answered");
            APPROVAL_GATE
                .scope((), async {
                    let dialog = ctx.ui.confirm("Probe", "approve", DialogOptions::default());
                    self.look("approval");
                    dialog.await;
                })
                .await;
            (ctx.acquire_write)(format!("{}/out.txt", ctx.cwd)).await?;
            self.look("lease acquired");
            let agent = self.agent.borrow().upgrade().unwrap();
            let signal = ctx.signal.clone();
            let operation = agent.clone();
            tokio::task::spawn_local(async move {
                operation
                    .run_operation(
                        "w1",
                        "grep",
                        Map::new(),
                        &signal,
                        "w1:op1",
                        OperationOptions::default(),
                    )
                    .await
            })
            .await
            .unwrap();
            // Work of no call (another task, no operation) waits for no call.
            let seen = self.seen.clone();
            let weak = Rc::downgrade(&agent);
            tokio::task::spawn_local(async move {
                let agent = weak.upgrade().unwrap();
                let dialog = agent
                    .ui
                    .confirm("Probe", "background", DialogOptions::default());
                seen.borrow_mut()
                    .push(("background dialog".to_owned(), loop_waits(&weak)));
                dialog.await;
            })
            .await
            .unwrap();
            Ok(ToolResult::text("probed"))
        })
    }
}

#[tokio::test]
async fn the_agent_loop_sees_block_snapshots_and_the_running_calls_waits() {
    let dir = tempfile::tempdir().unwrap();
    let mut config = crate::tools::testing::config(&dir.path().display().to_string(), json!({}));
    config.models = serde_json::from_value(json!({"providers":{"fake":{"api":"openai-completions","baseUrl":"https://example.test","models":[{"id":"main","contextWindow":8192,"maxTokens":512}]}},"defaultModel":{"provider":"fake","id":"main"}})).unwrap();
    let workspace = config.workspace.clone();
    let weak = Rc::new(RefCell::new(Weak::new()));
    let seen: Seen = Rc::default();
    let probe = |name| -> Rc<dyn Tool> {
        Rc::new(Probe {
            name,
            agent: weak.clone(),
            seen: seen.clone(),
            parameters: json!({ "type": "object" }).as_object().unwrap().clone(),
        })
    };
    let lease_agent = weak.clone();
    let lease_seen = seen.clone();
    let lease: AcquireWrite = Rc::new(move |root: String| {
        let waits = loop_waits(&lease_agent.borrow());
        lease_seen
            .borrow_mut()
            .push((format!("lease {root}"), waits));
        Box::pin(async { Ok(()) })
    });
    let stream = Rc::new(Streamed {
        agent: RefCell::new(Weak::new()),
        calls: Cell::new(0),
        partials: RefCell::new(Vec::new()),
    });
    let local = tokio::task::LocalSet::new();
    local
        .run_until(async {
            let agent = Agent::new(AgentOptions {
                store: SessionStore::open(dir.path().join("session"), &workspace).unwrap(),
                config,
                capabilities: Default::default(),
                role: None,
                emit: Rc::new(|_| {}),
                ui: Rc::new(crate::tools::testing::TestUi::default()),
                has_ui: false,
                tools: vec![probe("read"), probe("grep")],
                features: Vec::new(),
                acquire_write: Some(lease),
                allowed_tools: None,
                stream_override: Some(stream.clone()),
            });
            *weak.borrow_mut() = Rc::downgrade(&agent);
            *stream.agent.borrow_mut() = Rc::downgrade(&agent);
            agent.prompt("Probe".to_owned(), Vec::new()).unwrap();
            for _ in 0..500 {
                if !agent.running.get() {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
            assert!(!agent.running.get(), "the run did not end");
            assert!(agent.run_loop.borrow().is_none());
        })
        .await;

    let text = |text: &str| AssistantContent::Text {
        text: text.to_owned(),
        text_signature: None,
    };
    let started = AssistantContent::ToolCall {
        id: "w1".to_owned(),
        name: "read".to_owned(),
        arguments: Map::new(),
        thought_signature: None,
    };
    assert_eq!(
        *stream.partials.borrow(),
        [
            vec![text("")],
            vec![text("")],
            vec![text("Checking")],
            vec![text("Checking"), started.clone()],
            vec![text("Checking"), started],
        ]
    );
    assert_eq!(stream.calls.get(), 2);

    let seen = seen.borrow();
    let steps: Vec<&str> = seen.iter().map(|(step, _)| step.as_str()).collect();
    assert_eq!(
        steps,
        [
            "dialog",
            "dialog answered",
            "approval",
            &format!("lease {workspace}"),
            "lease acquired",
            "op dialog",
            "background dialog",
        ]
    );
    let key = seen[0].1[0].0;
    assert_eq!(key.index, 0);
    let reasons: Vec<Vec<(CallKey, WaitReason)>> = seen.iter().map(|(_, w)| w.clone()).collect();
    assert_eq!(
        reasons,
        [
            vec![(key, WaitReason::Other("dialog".to_owned()))],
            vec![],
            vec![(key, WaitReason::Approval)],
            vec![(
                key,
                WaitReason::Resource(format!("write lease: {workspace}"))
            )],
            vec![],
            vec![(key, WaitReason::Other("dialog".to_owned()))],
            vec![],
        ]
    );
}

type Replies = std::collections::VecDeque<(Vec<AssistantContent>, StopReason)>;
/// Steps, each with the agent loop's waits at that point.
type Looked = RefCell<Vec<(String, Vec<(CallKey, WaitReason)>)>>;

/// Each model call takes the next scripted reply, after recording the
/// request's messages and the agent loop's call outcomes at that point.
#[derive(Default)]
struct Scripted {
    agent: RefCell<Weak<Agent>>,
    replies: RefCell<Replies>,
    requests: RefCell<Vec<String>>,
    tool_statuses: RefCell<Vec<Vec<pirc_agent_loop::ToolStatus>>>,
}

impl crate::stream::StreamFn for Scripted {
    fn stream<'a>(
        &'a self,
        request: StreamRequest,
        _on_delta: &'a mut dyn FnMut(&pirc_protocol::AssistantDelta),
    ) -> LocalBoxFuture<'a, AssistantMessage> {
        Box::pin(async move {
            let agent = self.agent.borrow().upgrade().unwrap();
            self.requests
                .borrow_mut()
                .push(serde_json::to_string(&request.messages).unwrap());
            let statuses = agent
                .run_loop
                .borrow()
                .as_ref()
                .map(RunLoop::tool_statuses)
                .unwrap_or_default();
            self.tool_statuses.borrow_mut().push(statuses);
            let (content, stop) = self
                .replies
                .borrow_mut()
                .pop_front()
                .expect("a scripted reply");
            let mut reply = agent.empty_assistant();
            reply.provider = request.provider_name;
            reply.model = request.model.id;
            reply.content = content;
            reply.stop_reason = stop;
            reply
        })
    }
}

/// Answers confirmations in order, recording each with the agent loop's
/// waits while it is open; records statuses.
#[derive(Default)]
struct ScriptedUi {
    agent: RefCell<Weak<Agent>>,
    answers: RefCell<std::collections::VecDeque<Option<bool>>>,
    confirms: Looked,
    statuses: RefCell<Vec<(String, Option<String>)>>,
}

impl Ui for ScriptedUi {
    fn select<'a>(
        &'a self,
        _title: &'a str,
        _options: &'a [String],
        _opts: DialogOptions,
    ) -> LocalBoxFuture<'a, Option<String>> {
        Box::pin(async { None })
    }
    fn choose<'a>(
        &'a self,
        _title: &'a str,
        _options: &'a [Choice],
        _multiple: bool,
        _opts: DialogOptions,
    ) -> LocalBoxFuture<'a, Option<Vec<String>>> {
        Box::pin(async { None })
    }
    fn confirm<'a>(
        &'a self,
        title: &'a str,
        _message: &'a str,
        _opts: DialogOptions,
    ) -> LocalBoxFuture<'a, Option<bool>> {
        let waits = loop_waits(&self.agent.borrow());
        self.confirms.borrow_mut().push((title.to_owned(), waits));
        let answer = self.answers.borrow_mut().pop_front().flatten();
        Box::pin(async move { answer })
    }
    fn input<'a>(
        &'a self,
        _title: &'a str,
        _placeholder: Option<&'a str>,
        _opts: DialogOptions,
    ) -> LocalBoxFuture<'a, Option<String>> {
        Box::pin(async { None })
    }
    fn editor<'a>(
        &'a self,
        _title: &'a str,
        _prefill: Option<&'a str>,
        _opts: DialogOptions,
    ) -> LocalBoxFuture<'a, Option<String>> {
        Box::pin(async { None })
    }
    fn notify(&self, _message: &str, _level: NotifyLevel) {}
    fn set_status(&self, key: &str, text: Option<&str>) {
        self.statuses
            .borrow_mut()
            .push((key.to_owned(), text.map(str::to_owned)));
    }
    fn set_widget(&self, _key: &str, _lines: Option<&[String]>) {}
}

/// An agent on the fake model `stream`, with `ui`; the agent loop's
/// status when the run ends is put in `ended`.
struct ScriptedRun {
    ui: Rc<ScriptedUi>,
    has_ui: bool,
    tools: Vec<Rc<dyn Tool>>,
    features: Vec<Rc<dyn Feature>>,
    acquire_write: Option<AcquireWrite>,
    stream: Rc<Scripted>,
    ended: Rc<RefCell<Vec<pirc_agent_loop::Status>>>,
}

impl ScriptedRun {
    fn new(replies: Vec<(Vec<AssistantContent>, StopReason)>) -> Self {
        Self {
            ui: Rc::default(),
            has_ui: false,
            tools: Vec::new(),
            features: Vec::new(),
            acquire_write: None,
            stream: Rc::new(Scripted {
                replies: RefCell::new(replies.into()),
                ..Scripted::default()
            }),
            ended: Rc::default(),
        }
    }

    fn agent(&self, dir: &std::path::Path, config: AgentConfig) -> Rc<Agent> {
        self.agent_with_emitter(dir, config, None)
    }

    fn agent_with_emitter(
        &self,
        dir: &std::path::Path,
        mut config: AgentConfig,
        extra_emit: Option<crate::rpc::Write>,
    ) -> Rc<Agent> {
        config.models = serde_json::from_value(json!({"providers":{"fake":{"api":"openai-completions","baseUrl":"https://example.test","models":[{"id":"main","contextWindow":8192,"maxTokens":512}]}},"defaultModel":{"provider":"fake","id":"main"}})).unwrap();
        let weak: Rc<RefCell<Weak<Agent>>> = Rc::default();
        let ended = self.ended.clone();
        let emitter = weak.clone();
        let emit: crate::rpc::Write = Rc::new(move |event: Value| {
            if event["type"] == "agent_end"
                && let Some(agent) = emitter.borrow().upgrade()
                && let Some(run_loop) = agent.run_loop.borrow().as_ref()
            {
                ended.borrow_mut().push(run_loop.status());
            }
            if let Some(emit) = &extra_emit {
                emit(event);
            }
        });
        let workspace = config.workspace.clone();
        let agent = Agent::new(AgentOptions {
            store: SessionStore::open(dir.join("session"), &workspace).unwrap(),
            config,
            capabilities: Default::default(),
            role: None,
            emit,
            ui: self.ui.clone(),
            has_ui: self.has_ui,
            tools: self.tools.clone(),
            features: self.features.clone(),
            acquire_write: self.acquire_write.clone(),
            allowed_tools: None,
            stream_override: Some(self.stream.clone()),
        });
        *weak.borrow_mut() = Rc::downgrade(&agent);
        *self.stream.agent.borrow_mut() = Rc::downgrade(&agent);
        *self.ui.agent.borrow_mut() = Rc::downgrade(&agent);
        agent
    }
}

/// Prompt, then wait (in tokio time, up to 200 s) for the run to end.
async fn run_prompt(agent: &Rc<Agent>, text: &str) {
    agent.prompt(text.to_owned(), Vec::new()).unwrap();
    for _ in 0..20_000 {
        if !agent.running.get() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    assert!(!agent.running.get(), "the run did not end");
    assert!(agent.run_loop.borrow().is_none());
}

/// A stopped reply's text reaches both `message_end` and the session, so a
/// reload shows it beside the stopped marker.
#[tokio::test]
async fn a_stopped_reply_keeps_its_text_when_emitted_and_stored() {
    let dir = tempfile::tempdir().unwrap();
    let config = crate::tools::testing::config(&dir.path().display().to_string(), json!({}));
    let workspace = config.workspace.clone();
    let run = ScriptedRun::new(vec![(
        vec![reply_text("Partial answer")],
        StopReason::Aborted,
    )]);
    let events = Rc::new(RefCell::new(Vec::new()));
    let recorded = events.clone();
    let emit: crate::rpc::Write = Rc::new(move |event| recorded.borrow_mut().push(event));
    tokio::task::LocalSet::new()
        .run_until(async {
            let agent = run.agent_with_emitter(dir.path(), config, Some(emit));
            run_prompt(&agent, "Stop this").await;

            let end = events
                .borrow()
                .iter()
                .find(|event| {
                    event["type"] == "message_end" && event["message"]["role"] == "assistant"
                })
                .cloned()
                .expect("the assistant's message_end");
            assert_eq!(end["message"]["stopReason"], "aborted", "{end}");
            assert_eq!(
                end["message"]["content"],
                json!([{ "type": "text", "text": "Partial answer" }])
            );
            drop(agent);
        })
        .await;

    // A new store over the same file reads the text back.
    let store = SessionStore::open(dir.path().join("session"), &workspace).unwrap();
    let stored = store
        .branch()
        .into_iter()
        .filter_map(|entry| entry.message().cloned())
        .find_map(|message| match message {
            Message::Assistant(message) => Some(message),
            _ => None,
        })
        .expect("the aborted assistant message");
    assert_eq!(stored.stop_reason, StopReason::Aborted);
    assert_eq!(stored.content, [reply_text("Partial answer")]);
}

/// A `bash` that runs nothing: it records each command it was given, with
/// the agent loop's waits at that point.
#[derive(Default)]
struct Shell {
    agent: RefCell<Weak<Agent>>,
    ran: Looked,
}

impl Tool for Shell {
    fn name(&self) -> &str {
        "bash"
    }
    fn description(&self) -> &str {
        "shell probe"
    }
    fn parameters(&self) -> &Map<String, Value> {
        static PARAMETERS: std::sync::LazyLock<Map<String, Value>> =
            std::sync::LazyLock::new(|| {
                json!({
                    "type": "object",
                    "properties": { "command": { "type": "string" } },
                    "required": ["command"]
                })
                .as_object()
                .unwrap()
                .clone()
            });
        &PARAMETERS
    }
    fn execute<'a>(
        &'a self,
        args: Map<String, Value>,
        _ctx: ToolContext,
    ) -> LocalBoxFuture<'a, Result<ToolResult, String>> {
        Box::pin(async move {
            let command = args["command"].as_str().unwrap_or_default().to_owned();
            let waits = loop_waits(&self.agent.borrow());
            self.ran.borrow_mut().push((command, waits));
            Ok(ToolResult::text("ran"))
        })
    }
}

fn bash(id: &str, command: &str) -> AssistantContent {
    AssistantContent::ToolCall {
        id: id.to_owned(),
        name: "bash".to_owned(),
        arguments: json!({ "command": command }).as_object().unwrap().clone(),
        thought_signature: None,
    }
}

fn reply_text(text: &str) -> AssistantContent {
    AssistantContent::Text {
        text: text.to_owned(),
        text_signature: None,
    }
}

#[tokio::test]
async fn a_model_call_passes_the_auto_mode_gate_as_its_own_approval_wait() {
    use pirc_agent_loop::{Status, TerminalReason, ToolStatus};
    let dir = tempfile::tempdir().unwrap();
    // The deny-list makes both commands dangerous without a classifier
    // model: the gate asks the user, then leases the working directory.
    let config = crate::tools::testing::config(
        &dir.path().display().to_string(),
        json!({ "autoMode": { "deny": ["forbidden"] } }),
    );
    let workspace = config.workspace.clone();
    let mut run = ScriptedRun::new(vec![
        (
            vec![bash("c1", "forbidden one"), bash("c2", "forbidden two")],
            StopReason::ToolUse,
        ),
        (vec![reply_text("Done.")], StopReason::Stop),
    ]);
    run.has_ui = true;
    *run.ui.answers.borrow_mut() = [Some(false), Some(true)].into();
    let shell = Rc::new(Shell::default());
    run.tools = vec![shell.clone()];
    let weak: Rc<RefCell<Weak<Agent>>> = Rc::default();
    let leases: Seen = Rc::default();
    let (lease_agent, lease_seen) = (weak.clone(), leases.clone());
    run.acquire_write = Some(Rc::new(move |root: String| {
        let waits = loop_waits(&lease_agent.borrow());
        lease_seen.borrow_mut().push((root, waits));
        Box::pin(async { Ok(()) })
    }));
    tokio::task::LocalSet::new()
        .run_until(async {
            let agent = run.agent(dir.path(), config);
            *weak.borrow_mut() = Rc::downgrade(&agent);
            *shell.agent.borrow_mut() = Rc::downgrade(&agent);
            run_prompt(&agent, "Run them").await;
        })
        .await;

    // Each dialog is the gate's, so an approval wait of the call asking.
    let confirms = run.ui.confirms.borrow();
    assert_eq!(confirms.len(), 2);
    let keys: Vec<CallKey> = confirms
        .iter()
        .map(|(title, waits)| {
            assert_eq!(title, "Auto mode: allow a potentially dangerous action?");
            assert_eq!(waits.len(), 1, "{waits:?}");
            assert_eq!(waits[0].1, WaitReason::Approval);
            waits[0].0
        })
        .collect();
    assert_eq!((keys[0].index, keys[1].index), (0, 1));
    // Only the approved call takes the lease, as its own resource wait.
    assert_eq!(
        *leases.borrow(),
        [(
            workspace.clone(),
            vec![(
                keys[1],
                WaitReason::Resource(format!("write lease: {workspace}"))
            )]
        )]
    );
    // The declined call never ran; the approved one ran with no wait open.
    assert_eq!(*shell.ran.borrow(), [("forbidden two".to_owned(), vec![])]);

    // The refusal is the declined call's failed result, in the core too.
    let requests = run.stream.requests.borrow();
    assert_eq!(requests.len(), 2);
    assert!(
        requests[1].contains("Blocked by auto mode: "),
        "{}",
        requests[1]
    );
    assert!(
        requests[1].contains("The user declined it."),
        "{}",
        requests[1]
    );
    assert_eq!(
        *run.stream.tool_statuses.borrow(),
        [vec![], vec![ToolStatus::Failed, ToolStatus::Completed]]
    );
    assert_eq!(
        *run.ended.borrow(),
        [Status::Done(TerminalReason::Completed)]
    );
}

/// Work that never completes.
struct Blocked;

impl Feature for Blocked {
    fn name(&self) -> &'static str {
        "blocked"
    }
    fn completion_blockers(&self, _agent: &Rc<Agent>) -> Vec<String> {
        vec!["helper (running)".to_owned()]
    }
}

#[tokio::test(start_paused = true)]
async fn a_completion_wait_times_out_once_and_the_run_reports_it() {
    use pirc_agent_loop::{Status, TerminalReason, ToolStatus};
    let dir = tempfile::tempdir().unwrap();
    let mut config = crate::tools::testing::config(&dir.path().display().to_string(), json!({}));
    config.limits.completion_wait_ms = 30_000;
    let mut run = ScriptedRun::new(vec![
        (vec![reply_text("Done.")], StopReason::Stop),
        (
            vec![reply_text("The helper is still running.")],
            StopReason::Stop,
        ),
    ]);
    run.features = vec![Rc::new(Blocked)];
    let started = tokio::time::Instant::now();
    let local = tokio::task::LocalSet::new();
    local
        .run_until(async {
            let agent = run.agent(dir.path(), config);
            run_prompt(&agent, "Finish up").await;
            assert!(agent.completion_waiting.borrow().is_empty());
        })
        .await;
    let waited = started.elapsed();
    // One wait of the configured length: the reply to the timeout ends the
    // run although the helper is still running.
    assert!(
        waited >= Duration::from_millis(30_000) && waited < Duration::from_millis(60_000),
        "{waited:?}"
    );

    let timeout =
        "Team completion wait timed out. These workers have NOT completed: helper (running).";
    let requests = run.stream.requests.borrow();
    assert_eq!(requests.len(), 2);
    assert!(!requests[0].contains(timeout));
    assert!(requests[1].contains(timeout), "{}", requests[1]);
    // Shown while waiting (refreshed on each check), cleared after.
    let statuses = run.ui.statuses.borrow();
    let (cleared, shown) = statuses.split_last().unwrap();
    assert_eq!(*cleared, ("completion-wait".to_owned(), None));
    assert!(!shown.is_empty());
    for status in shown {
        assert_eq!(
            *status,
            (
                "completion-wait".to_owned(),
                Some("Waiting for team: helper (running)".to_owned())
            )
        );
    }
    // The core went on to the timeout's turn and completed.
    assert_eq!(
        *run.stream.tool_statuses.borrow(),
        [Vec::<ToolStatus>::new(), vec![]]
    );
    assert_eq!(
        *run.ended.borrow(),
        [Status::Done(TerminalReason::Completed)]
    );
}

fn call(id: &str) -> AssistantContent {
    AssistantContent::ToolCall {
        id: id.to_owned(),
        name: "read".to_owned(),
        arguments: Map::new(),
        thought_signature: None,
    }
}

fn assistant(content: Vec<AssistantContent>, stop: StopReason) -> Message {
    Message::Assistant(AssistantMessage {
        content,
        api: "x".to_owned(),
        provider: "p".to_owned(),
        model: "m".to_owned(),
        usage: empty_usage(),
        stop_reason: stop,
        error_message: None,
        timestamp: 1,
        completed_at: None,
        canonical_provider: None,
        response_id: None,
        response_model: None,
    })
}

fn result(id: &str) -> Message {
    Message::ToolResult {
        tool_call_id: id.to_owned(),
        tool_name: "read".to_owned(),
        content: vec![],
        details: None,
        is_error: false,
        timestamp: 2,
    }
}

#[test]
fn sanitizes_orphans_and_missing_results() {
    let user = Message::User {
        content: UserContent::Text("hi".to_owned()),
        timestamp: 0,
    };
    let messages = vec![
        result("orphan"),
        assistant(vec![call("a"), call("b")], StopReason::ToolUse),
        result("b"),
        user.clone(),
        assistant(vec![call("c")], StopReason::Error),
        result("c"),
    ];
    let out = sanitize_history(&messages);
    let shape: Vec<String> = out
        .iter()
        .map(|m| match m {
            Message::ToolResult {
                tool_call_id,
                is_error,
                ..
            } => format!("result {tool_call_id} {is_error}"),
            Message::Assistant(_) => "assistant".to_owned(),
            Message::User { .. } => "user".to_owned(),
            _ => "other".to_owned(),
        })
        .collect();
    assert_eq!(
        shape,
        [
            "assistant",
            "result b false",
            "result a true",
            "user",
            "assistant"
        ]
    );
}

#[test]
fn interrupted_notes_carry_the_partial_text() {
    let message = match assistant(
        vec![AssistantContent::Text {
            text: "  partial  ".to_owned(),
            text_signature: None,
        }],
        StopReason::Aborted,
    ) {
        Message::Assistant(message) => message,
        _ => unreachable!(),
    };
    match interrupted_note(&message) {
        QueueItem::Custom(message) => match *message {
            Message::Custom { content, .. } => assert_eq!(
                content,
                "[Your previous response was interrupted by the user.] Partial output:\n\npartial"
            ),
            _ => panic!(),
        },
        _ => panic!(),
    }
}

#[test]
fn parses_slash_commands() {
    let parsed = |text: &str| parse_command(text);
    assert_eq!(
        parsed("  /goal   finish it \n"),
        Some(("goal".to_owned(), "finish it".to_owned()))
    );
    assert_eq!(
        parsed("/om:workspace view"),
        Some(("om:workspace".to_owned(), "view".to_owned()))
    );
    assert_eq!(
        parsed("/Todo\u{3000}a\nb"),
        Some(("Todo".to_owned(), "a\nb".to_owned()))
    );
    for text in ["goal", "/1goal", "/goal!", "/ goal", "/goal\u{85}x"] {
        assert_eq!(parsed(text), None, "{text:?}");
    }
}

mod admission;

#[test]
fn a_trusted_notice_with_an_id_is_applied_once_even_after_a_restart() {
    let dir = tempfile::tempdir().unwrap();
    let notice = || Delivery {
        custom_type: "environment-change".into(),
        content: "Moved.".into(),
        display: true,
        details: Some(json!({"noticeId":"move-1"})),
    };
    let count = |agent: &Rc<Agent>| {
        agent
            .branch()
            .iter()
            .filter(|entry| matches!(&entry.data, EntryData::Message(Message::Custom { custom_type, .. }) if custom_type == "environment-change"))
            .count()
    };
    let agent = mode_agent(
        dir.path(),
        pirc_protocol::mode::default_work(),
        json!({}),
        None,
    );
    agent.deliver(notice(), false, true).unwrap();
    agent.deliver(notice(), false, true).unwrap();
    assert_eq!(count(&agent), 1);
    drop(agent);
    // A replacement agent opens the same saved session and still skips it.
    let restarted = mode_agent(
        dir.path(),
        pirc_protocol::mode::default_work(),
        json!({}),
        None,
    );
    restarted.deliver(notice(), false, true).unwrap();
    assert_eq!(count(&restarted), 1);
    // A different notice is a new entry.
    let mut other = notice();
    other.details = Some(json!({"noticeId":"move-2"}));
    restarted.deliver(other, false, true).unwrap();
    assert_eq!(count(&restarted), 2);
}
