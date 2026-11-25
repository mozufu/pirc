//! `auto-mode-gate.test.ts`, and a host with a scripted classifier model
//! for the model path (also used by `classifier`'s tests).

use std::rc::Rc;

use pirc_policy::real_resolve;
use serde_json::{Value, json};

use super::*;
use crate::tools::testing::{TestHost, args, config};

const WORKSPACE: &str = "/nonexistent-pirc-gate/home/repo";

fn host(features: Value, has_ui: bool) -> TestHost {
    let mut config = config("/", features);
    config.workspace = WORKSPACE.to_owned();
    config.path_policy.allow_write = vec![WORKSPACE.to_owned()];
    TestHost::new(config, Vec::new(), has_ui)
}

fn default_host() -> TestHost {
    host(json!({ "autoMode": { "useModel": false } }), false)
}

fn write(id: &str, input: &str) -> Map<String, Value> {
    args(json!({ "action": "write", "id": id, "input": input }))
}

async fn classify(auto: &AutoMode, host: &dyn AgentHost, action: &ShellAction) -> Decision {
    auto.classify(host, action, &AbortSignal::never())
        .await
        .unwrap()
}

async fn gate(
    auto: &AutoMode,
    host: &dyn AgentHost,
    tool: &str,
    args: Map<String, Value>,
) -> Option<String> {
    auto.gate(host, tool, &args, &AbortSignal::never())
        .await
        .unwrap()
}

#[tokio::test]
async fn judges_keystrokes_together_with_the_rest_of_their_line() {
    let host = default_host();
    let auto = AutoMode::new();
    // Each fragment alone looks harmless or unclear; together they are `rm -rf ~`.
    assert_eq!(
        gate(&auto, &host, "background_task", write("t1", "r")).await,
        None
    );
    let refused = gate(&auto, &host, "background_task", write("t1", "m -rf ~\n"))
        .await
        .unwrap();
    assert!(refused.contains("deletes"), "{refused}");
    assert!(refused.contains("no UI"), "{refused}");
    // Another task's line is separate.
    assert_eq!(
        gate(&auto, &host, "background_task", write("t2", "ls\n")).await,
        None
    );
    // The refused fragment was not sent: the pending line is still `r`.
    assert_eq!(
        auto.action_for(&host, "background_task", &write("t1", "x"))
            .unwrap()
            .text,
        "rx"
    );
    // Enter submits the line; the next one starts fresh.
    assert_eq!(
        gate(&auto, &host, "background_task", write("t1", "eadme\n")).await,
        None
    );
    assert_eq!(
        auto.action_for(&host, "background_task", &write("t1", "ls"))
            .unwrap()
            .text,
        "ls"
    );
    // Ctrl-C discards the line too.
    gate(&auto, &host, "background_task", write("t1", "r")).await;
    gate(&auto, &host, "background_task", write("t1", "\u{3}")).await;
    assert_eq!(
        auto.action_for(&host, "background_task", &write("t1", "ls"))
            .unwrap()
            .text,
        "ls"
    );
}

#[tokio::test]
async fn judges_concurrent_keystrokes_to_one_task_in_order() {
    let host = default_host();
    // A slow lease answer keeps the first write inside its gate.
    host.lease_delay_ms.set(30);
    let auto = AutoMode::new();
    let (first, second) = tokio::join!(
        gate(&auto, &host, "background_task", write("t1", "r")),
        gate(&auto, &host, "background_task", write("t1", "m -rf ~\n")),
    );
    assert_eq!(first, None);
    assert!(second.unwrap().contains("deletes"));
    assert!(auto.input_gates.borrow().is_empty());
}

#[tokio::test]
async fn marks_control_keys() {
    assert_eq!(
        visible_keys("a\r\u{7f}\u{3}\u{15}"),
        "a\n⟨Backspace⟩⟨Ctrl-C⟩⟨Ctrl-U⟩"
    );
    assert_eq!(visible_keys("tus\t\u{1b}[A\n"), "tus⟨Tab⟩⟨Esc⟩[A\n");
    // A read-only line with control keys is not read-only any more.
    let host = default_host();
    let auto = AutoMode::new();
    let action = auto
        .action_for(&host, "background_task", &write("u", "ls\u{1b}[A\n"))
        .unwrap();
    let decision = classify(&auto, &host, &action).await;
    assert_eq!(decision.classification.verdict, Verdict::Write);
    assert_eq!(decision.source, Source::Fallback);
}

#[tokio::test]
async fn bounds_the_pending_line() {
    let host = default_host();
    let auto = AutoMode::new();
    gate(
        &auto,
        &host,
        "background_task",
        write("t", &"x".repeat(10_000)),
    )
    .await;
    let action = auto
        .action_for(&host, "background_task", &write("t", "y"))
        .unwrap();
    assert!(js::len16(&action.text) < 4_200);
    assert!(action.text.starts_with("⟨earlier keystrokes truncated⟩"));
    assert!(
        classify(&auto, &host, &action)
            .await
            .classification
            .reason
            .contains("model check disabled")
    );
}

#[tokio::test]
async fn leases_only_the_known_targets_of_a_command_else_its_working_directory() {
    for features in [
        json!({ "autoMode": { "useModel": false } }),
        json!({ "autoMode": { "enabled": false } }),
    ] {
        let host = host(features, false);
        let auto = AutoMode::new();
        let bash = |command: &str| args(json!({ "command": command }));
        gate(&auto, &host, "bash", bash("cd /tmp && mkdir -p ghpirc")).await;
        assert_eq!(
            *host.leases.borrow(),
            vec![format!("{}/ghpirc", real_resolve("/tmp"))]
        );
        host.leases.borrow_mut().clear();
        gate(
            &auto,
            &host,
            "bash",
            bash("mkdir -p /tmp/a && git commit -m x"),
        )
        .await;
        assert_eq!(*host.leases.borrow(), vec![WORKSPACE.to_owned()]);
        host.leases.borrow_mut().clear();
        gate(&auto, &host, "bash", bash("ls")).await;
        assert!(host.leases.borrow().is_empty());
    }
}

#[tokio::test]
async fn leases_the_working_directory_for_tty_input() {
    let host = default_host();
    let auto = AutoMode::new();
    gate(
        &auto,
        &host,
        "background_task",
        write("t", "mkdir /tmp/x\n"),
    )
    .await;
    assert_eq!(*host.leases.borrow(), vec![WORKSPACE.to_owned()]);
}

#[tokio::test]
async fn applies_the_deny_list_with_auto_mode_off_and_broken_settings() {
    let host = host(json!({ "autoMode": { "useModel": true } }), false);
    let auto = AutoMode::new();
    let action = auto
        .action_for(
            &host,
            "bash",
            &args(json!({ "command": "sh -c \"echo deploy-prod\"" })),
        )
        .unwrap();
    assert_eq!(
        classify(&auto, &host, &action).await.classification.verdict,
        Verdict::Write
    );
    host.set_features(json!({ "autoMode": { "useModel": true, "deny": ["deploy-prod"] } }));
    let denied = classify(&auto, &host, &action).await.classification;
    assert_eq!(denied.verdict, Verdict::Danger);
    assert!(denied.reason.contains("deny-list"));
    host.set_features(json!({ "autoMode": { "enabled": false, "deny": "deploy-prod" } }));
    assert_eq!(
        classify(&auto, &host, &action).await.classification.verdict,
        Verdict::Danger
    );
    // A broken setting elsewhere does not drop the deny-list.
    host.set_features(json!({ "autoMode": { "timeoutMs": "soon", "deny": ["deploy-prod"] } }));
    assert_eq!(
        classify(&auto, &host, &action).await.classification.verdict,
        Verdict::Danger
    );
}

#[tokio::test]
async fn applies_the_deny_list_to_tty_input_and_ptc_scripts() {
    let host = host(
        json!({ "autoMode": { "useModel": false, "deny": ["just\\s+switch"] } }),
        false,
    );
    let auto = AutoMode::new();
    gate(&auto, &host, "background_task", write("t", "just sw")).await;
    assert!(
        gate(&auto, &host, "background_task", write("t", "itch\n"))
            .await
            .unwrap()
            .contains("deny-list")
    );
    let script = "return await tools.bash({ command: \"just switch\" });";
    assert!(
        gate(&auto, &host, "ptc", args(json!({ "code": script })))
            .await
            .unwrap()
            .contains("deny-list")
    );
}

#[tokio::test]
async fn runs_scripts_without_a_prompt_lease_or_classifier() {
    let host = host(json!({ "autoMode": { "useModel": true } }), true);
    let auto = AutoMode::new();
    for code in ["return await tools.ls({});", "await Bun.$`rm -rf ~`;"] {
        assert_eq!(
            gate(&auto, &host, "ptc", args(json!({ "code": code }))).await,
            None
        );
    }
    assert!(host.leases.borrow().is_empty());
    assert!(host.ui.confirms.borrow().is_empty());
}

#[test]
fn no_longer_gates_the_retired_code_tool() {
    let host = default_host();
    let auto = AutoMode::new();
    assert_eq!(
        auto.action_for(&host, "code", &args(json!({ "code": "await Bun.$`x`;" }))),
        None
    );
}

#[tokio::test]
async fn asks_a_human_about_danger_when_there_is_one() {
    let host = host(json!({}), true);
    let auto = AutoMode::new();
    let command = args(json!({ "command": "rm -rf ~" }));
    host.ui.answer.set(Some(false));
    let refused = gate(&auto, &host, "bash", command.clone()).await.unwrap();
    assert!(refused.ends_with(
        "The user declined it. Do not try to reach the same effect another way; explain what you intended and ask the user to run or approve it."
    ));
    let asked = host.ui.confirms.borrow()[0].clone();
    assert_eq!(
        asked,
        format!(
            "Command (bash, in {WORKSPACE}):\n\nrm -rf ~\n\nReason: deletes {}, outside the workspace",
            real_resolve(&std::env::var("HOME").unwrap())
        )
    );
    host.ui.answer.set(None);
    assert!(
        gate(&auto, &host, "bash", command.clone())
            .await
            .unwrap()
            .contains("The user did not approve it.")
    );
    host.ui.answer.set(Some(true));
    assert_eq!(gate(&auto, &host, "bash", command).await, None);
    // An approved danger still takes the lease.
    assert_eq!(*host.leases.borrow(), vec![WORKSPACE.to_owned()]);
}

#[tokio::test]
async fn warns_once_about_invalid_deny_patterns() {
    let host = host(json!({ "autoMode": { "deny": ["rm -rf ("] } }), false);
    let auto = AutoMode::new();
    let bash = args(json!({ "command": "ls" }));
    gate(&auto, &host, "bash", bash.clone()).await;
    gate(&auto, &host, "bash", bash).await;
    assert_eq!(
        *host.ui.notes.borrow(),
        vec![
            "Auto mode: deny-list pattern(s) are not valid regular expressions and are matched as plain text: rm -rf ("
                .to_owned()
        ]
    );
}

#[test]
fn reads_the_settings_like_zod() {
    let mode = |value: Value| default_approval_mode(value.as_object().unwrap());
    assert_eq!(mode(json!({})), ApprovalMode::Auto);
    // The retired switch: false is full access, true is auto.
    assert_eq!(
        mode(json!({ "autoMode": { "enabled": false } })),
        ApprovalMode::FullAccess
    );
    assert_eq!(
        mode(json!({ "autoMode": { "enabled": true } })),
        ApprovalMode::Auto
    );
    // `mode` wins over `enabled`, in either order.
    assert_eq!(
        mode(json!({ "autoMode": { "mode": "read-only", "enabled": false } })),
        ApprovalMode::ReadOnly
    );
    assert_eq!(
        mode(json!({ "autoMode": { "enabled": false, "mode": "auto" } })),
        ApprovalMode::Auto
    );
    // Any invalid setting restores every default, a misspelt mode included.
    assert_eq!(
        mode(json!({ "autoMode": { "mode": "full-acess" } })),
        ApprovalMode::Auto
    );
    assert_eq!(
        mode(json!({ "autoMode": { "enabled": false, "timeoutMs": "soon" } })),
        ApprovalMode::Auto
    );
    assert_eq!(
        mode(json!({ "autoMode": { "enabled": false, "model": { "provider": "p" } } })),
        ApprovalMode::Auto
    );
    assert_eq!(
        mode(json!({ "autoMode": {
            "mode": "full-access",
            "model": { "provider": "p", "id": "m", "thinking": "low" },
            "fallbackModels": [],
            "timeoutMs": 1000,
            "deny": ["x"],
        } })),
        ApprovalMode::FullAccess
    );
    assert!(uses_retired_enabled(
        json!({ "autoMode": { "enabled": true } })
            .as_object()
            .unwrap()
    ));
    assert!(!uses_retired_enabled(
        json!({ "autoMode": { "mode": "auto" } })
            .as_object()
            .unwrap()
    ));
    assert_eq!(
        auto_mode_deny(
            json!({ "autoMode": { "deny": ["a", 1, "b"] } })
                .as_object()
                .unwrap()
        ),
        vec!["a", "b"]
    );
}

#[tokio::test]
async fn without_a_classifier_model_unclear_actions_write_and_warn_once() {
    // `useModel` defaults to true; a host without models takes the
    // classifier-failure path: one warning, then plain writes.
    let host = host(json!({}), false);
    let auto = AutoMode::new();
    for _ in 0..2 {
        let action = auto
            .action_for(&host, "bash", &args(json!({ "command": "python3 x.py" })))
            .unwrap();
        let decision = classify(&auto, &host, &action).await;
        assert_eq!(decision.source, Source::Fallback);
        assert_eq!(decision.classification.verdict, Verdict::Write);
        assert!(
            decision
                .classification
                .reason
                .ends_with("; classifier unavailable")
        );
    }
    assert_eq!(
        *host.ui.notes.borrow(),
        vec![
            "Auto mode: classifier unavailable (no model available); treating unclear shell actions as writes"
                .to_owned()
        ]
    );
}

// ---------------------------------------------------------------------------
// The model path

/// What the scripted classifier model does with a request.
pub(crate) enum Reply {
    Text(String),
    /// A failed request with this error message.
    Fail(String),
    /// No answer until the request is aborted.
    Hang,
}

/// One classifier request as the model saw it.
pub(crate) struct Seen {
    /// `provider/id`.
    pub key: String,
    pub thinking: ThinkingLevel,
    pub max_tokens: Option<u64>,
    pub session_id: String,
    pub system_prompt: String,
    pub prompt: String,
    pub tools: usize,
}

type Respond = Box<dyn FnMut(&Seen) -> Reply>;

pub(crate) struct ModelState {
    pub respond: RefCell<Respond>,
    pub seen: RefCell<Vec<Seen>>,
}

/// An agent host with models (`p/m`, the session model; `p/r`, a reasoning
/// model; `q/m`) and a scripted stream function.
pub(crate) struct ModelHost {
    pub inner: TestHost,
    pub state: Rc<ModelState>,
    pub session_model: Option<(String, String)>,
    pub entries: Vec<(String, pirc_protocol::Message)>,
    pub branch: Vec<crate::session_store::SessionEntry>,
}

impl ModelHost {
    pub fn new(
        features: Value,
        has_ui: bool,
        respond: impl FnMut(&Seen) -> Reply + 'static,
    ) -> Self {
        Self {
            inner: host(features, has_ui),
            state: Rc::new(ModelState {
                respond: RefCell::new(Box::new(respond)),
                seen: RefCell::new(Vec::new()),
            }),
            session_model: Some(("p".to_owned(), "m".to_owned())),
            entries: Vec::new(),
            branch: Vec::new(),
        }
    }

    pub fn prompts(&self) -> Vec<String> {
        self.state
            .seen
            .borrow()
            .iter()
            .map(|seen| seen.prompt.clone())
            .collect()
    }
}

struct ScriptedStream(Rc<ModelState>);

impl crate::stream::StreamFn for ScriptedStream {
    fn stream<'a>(
        &'a self,
        request: crate::stream::StreamRequest,
        _on_delta: &'a mut dyn FnMut(&pirc_protocol::AssistantDelta),
    ) -> crate::LocalBoxFuture<'a, pirc_protocol::AssistantMessage> {
        Box::pin(async move {
            let prompt = match &request.messages[..] {
                [
                    pirc_protocol::Message::User {
                        content: pirc_protocol::UserContent::Text(text),
                        ..
                    },
                ] => text.clone(),
                _ => panic!("one user message"),
            };
            let seen = Seen {
                key: format!("{}/{}", request.provider_name, request.model.id),
                thinking: request.thinking,
                max_tokens: request.max_tokens,
                session_id: request.session_id.clone(),
                system_prompt: request.system_prompt.clone(),
                prompt,
                tools: request.tools.len(),
            };
            let reply = (self.0.respond.borrow_mut())(&seen);
            self.0.seen.borrow_mut().push(seen);
            let mut message = pirc_protocol::AssistantMessage {
                content: Vec::new(),
                api: "openai-completions".to_owned(),
                provider: request.provider_name,
                model: request.model.id,
                usage: crate::messages::empty_usage(),
                stop_reason: pirc_protocol::StopReason::Stop,
                error_message: None,
                timestamp: 0,
                completed_at: None,
                canonical_provider: None,
                response_id: None,
                response_model: None,
            };
            match reply {
                Reply::Text(text) => message.content.push(pirc_protocol::AssistantContent::Text {
                    text,
                    text_signature: None,
                }),
                Reply::Fail(error) => {
                    message.stop_reason = pirc_protocol::StopReason::Error;
                    message.error_message = Some(error);
                }
                Reply::Hang => {
                    request.signal.cancelled().await;
                    message.stop_reason = pirc_protocol::StopReason::Aborted;
                    message.error_message = Some("Inference request cancelled".to_owned());
                }
            }
            message
        })
    }
}

fn model(id: &str, reasoning: bool) -> Value {
    json!({ "id": id, "contextWindow": 100_000, "maxTokens": 1000, "reasoning": reasoning })
}

impl AgentHost for ModelHost {
    fn config(&self) -> Rc<crate::config::AgentConfig> {
        self.inner.config()
    }
    fn guard(&self) -> Rc<pirc_policy::PathGuard> {
        self.inner.guard()
    }
    fn ui(&self) -> Rc<dyn crate::ui::Ui> {
        self.inner.ui()
    }
    fn has_ui(&self) -> bool {
        self.inner.has_ui()
    }
    fn session_id(&self) -> String {
        self.inner.session_id()
    }
    fn acquire_write<'a>(
        &'a self,
        file: &'a str,
        signal: &'a AbortSignal,
    ) -> crate::LocalBoxFuture<'a, Result<(), String>> {
        self.inner.acquire_write(file, signal)
    }
    fn tool_list(&self) -> Vec<Rc<dyn crate::tools::Tool>> {
        self.inner.tool_list()
    }
    fn direct_tool_list(&self) -> Vec<Rc<dyn crate::tools::Tool>> {
        self.inner.direct_tool_list()
    }
    fn resolve_model(
        &self,
        reference: Option<(String, String)>,
    ) -> Result<crate::agent::ResolvedModel, String> {
        let Some((provider_name, id)) = reference.or_else(|| self.session_model.clone()) else {
            return Err("No model configured. Add providers to the gateway models.json".to_owned());
        };
        let models = match provider_name.as_str() {
            "p" => vec![model("m", false), model("r", true)],
            "q" => vec![model("m", false)],
            _ => return Err(format!("Unknown model {provider_name}/{id}")),
        };
        let provider: pirc_protocol::Provider = serde_json::from_value(json!({
            "api": "openai-completions", "baseUrl": "https://example.invalid", "models": models,
        }))
        .unwrap();
        let Some(model) = provider.models.iter().find(|model| model.id == id).cloned() else {
            return Err(format!("Unknown model {provider_name}/{id}"));
        };
        Ok(crate::agent::ResolvedModel {
            provider_name,
            provider,
            model,
        })
    }
    fn stream_function(&self) -> Option<Rc<dyn crate::stream::StreamFn>> {
        Some(Rc::new(ScriptedStream(self.state.clone())))
    }
    fn context_entries(&self) -> Vec<(String, pirc_protocol::Message)> {
        self.entries.clone()
    }
    fn branch(&self) -> Vec<crate::session_store::SessionEntry> {
        self.branch.clone()
    }
}

fn verdict(text: &str) -> impl FnMut(&Seen) -> Reply + 'static {
    let text = text.to_owned();
    move |_| Reply::Text(text.clone())
}

#[tokio::test]
async fn shows_the_model_the_whole_line_and_marks_control_keys() {
    let host = ModelHost::new(
        json!({ "autoMode": { "useModel": true } }),
        false,
        verdict("<verdict>write</verdict><reason>ok</reason>"),
    );
    let auto = AutoMode::new();
    gate(&auto, &host, "background_task", write("t", "git sta")).await;
    gate(
        &auto,
        &host,
        "background_task",
        write("t", "tus\t\u{1b}[A\n"),
    )
    .await;
    assert!(
        host.prompts()
            .last()
            .unwrap()
            .contains("git status⟨Tab⟩⟨Esc⟩[A")
    );
    // A read-only line with control keys is not read-only any more.
    let action = auto
        .action_for(&host, "background_task", &write("u", "ls\u{1b}[A\n"))
        .unwrap();
    assert_eq!(classify(&auto, &host, &action).await.source, Source::Model);
}

#[tokio::test]
async fn applies_the_deny_list_before_the_verdict_cache() {
    let host = ModelHost::new(
        json!({ "autoMode": { "useModel": true } }),
        false,
        verdict("<verdict>write</verdict><reason>prints</reason>"),
    );
    let auto = AutoMode::new();
    let action = auto
        .action_for(
            &host,
            "bash",
            &args(json!({ "command": "sh -c \"echo deploy-prod\"" })),
        )
        .unwrap();
    let first = classify(&auto, &host, &action).await;
    assert_eq!(first.classification.verdict, Verdict::Write);
    assert_eq!(first.classification.reason, "prints");
    // Cached.
    assert_eq!(classify(&auto, &host, &action).await.source, Source::Model);
    assert_eq!(host.prompts().len(), 1);
    host.inner
        .set_features(json!({ "autoMode": { "useModel": true, "deny": ["deploy-prod"] } }));
    let denied = classify(&auto, &host, &action).await.classification;
    assert_eq!(denied.verdict, Verdict::Danger);
    assert!(denied.reason.contains("deny-list"));
    host.inner
        .set_features(json!({ "autoMode": { "enabled": false, "deny": "deploy-prod" } }));
    assert_eq!(
        classify(&auto, &host, &action).await.classification.verdict,
        Verdict::Danger
    );
    host.inner
        .set_features(json!({ "autoMode": { "timeoutMs": "soon", "deny": ["deploy-prod"] } }));
    assert_eq!(
        classify(&auto, &host, &action).await.classification.verdict,
        Verdict::Danger
    );
}

#[tokio::test]
async fn runs_scripts_without_asking_the_classifier() {
    let host = ModelHost::new(
        json!({ "autoMode": { "useModel": true } }),
        true,
        verdict("<verdict>dangerous</verdict><reason>no</reason>"),
    );
    let auto = AutoMode::new();
    for code in ["return await tools.ls({});", "await Bun.$`rm -rf ~`;"] {
        assert_eq!(
            gate(&auto, &host, "ptc", args(json!({ "code": code }))).await,
            None
        );
    }
    assert!(host.inner.leases.borrow().is_empty());
    assert!(host.inner.ui.confirms.borrow().is_empty());
    assert!(host.prompts().is_empty());
}

#[tokio::test]
async fn sends_unclear_commands_to_the_classifier() {
    // `agent-auto-mode.test.ts`: read runs, write takes the lease, danger
    // asks the human; only read/write verdicts are cached.
    let host = ModelHost::new(
        json!({ "autoMode": { "useModel": true } }),
        true,
        |seen: &Seen| {
            Reply::Text(
                if seen.prompt.contains("echo quiet") {
                    "<verdict>read</verdict><reason>prints text</reason>"
                } else if seen.prompt.contains("touch model.txt") {
                    "<verdict>write</verdict><reason>creates a file</reason>"
                } else if seen.prompt.contains("echo exfil") {
                    "<verdict>dangerous</verdict><reason>uploads secrets</reason>"
                } else {
                    "no idea"
                }
                .to_owned(),
            )
        },
    );
    host.inner.ui.answer.set(Some(false));
    let auto = AutoMode::new();
    let bash = |command: &str| args(json!({ "command": command }));
    for _ in 0..2 {
        assert_eq!(
            gate(&auto, &host, "bash", bash("sh -c \"echo quiet\"")).await,
            None
        );
        assert_eq!(
            gate(&auto, &host, "bash", bash("sh -c \"touch model.txt\"")).await,
            None
        );
        let refused = gate(&auto, &host, "bash", bash("sh -c \"echo exfil\""))
            .await
            .unwrap();
        assert!(refused.starts_with("uploads secrets. The user declined it."));
    }
    assert_eq!(host.prompts().len(), 4);
    assert_eq!(*host.inner.leases.borrow(), vec![WORKSPACE.to_owned(); 2]);
    assert_eq!(host.inner.ui.confirms.borrow().len(), 2);
    assert!(host.inner.ui.confirms.borrow()[0].ends_with("Reason: uploads secrets"));
    // Unparseable: the classifier is unavailable, once warned.
    for command in ["sh -c \"one\"", "sh -c \"two\""] {
        let action = auto.action_for(&host, "bash", &bash(command)).unwrap();
        let decision = classify(&auto, &host, &action).await;
        assert_eq!(decision.source, Source::Fallback);
        assert_eq!(
            decision.classification.reason,
            "sh runs arbitrary code; classifier unavailable"
        );
    }
    assert_eq!(
        *host.inner.ui.notes.borrow(),
        vec![
            "Auto mode: classifier unavailable (p/m: unparseable reply); treating unclear shell actions as writes"
                .to_owned()
        ]
    );
}

#[tokio::test]
async fn bounds_the_verdict_cache() {
    let host = ModelHost::new(
        json!({ "autoMode": { "useModel": true } }),
        false,
        verdict("<verdict>read</verdict>"),
    );
    let auto = AutoMode::new();
    let action = |n: usize| {
        auto.action_for(
            &host,
            "bash",
            &args(json!({ "command": format!("sh -c \"echo {n}\"") })),
        )
        .unwrap()
    };
    for n in 0..=CACHE_LIMIT {
        classify(&auto, &host, &action(n)).await;
    }
    assert_eq!(auto.cache.borrow().len(), CACHE_LIMIT);
    // The oldest verdict went first.
    classify(&auto, &host, &action(1)).await;
    assert_eq!(host.prompts().len(), CACHE_LIMIT + 1);
    classify(&auto, &host, &action(0)).await;
    assert_eq!(host.prompts().len(), CACHE_LIMIT + 2);
}

#[tokio::test]
async fn cancelling_the_classifier_fails_the_gate() {
    let host = ModelHost::new(json!({ "autoMode": { "useModel": true } }), false, |_| {
        Reply::Hang
    });
    let auto = AutoMode::new();
    let controller = crate::signal::AbortController::new();
    let signal = controller.signal();
    let command = args(json!({ "command": "sh -c \"touch x\"" }));
    let (result, ()) = tokio::join!(auto.gate(&host, "bash", &command, &signal), async {
        tokio::task::yield_now().await;
        controller.abort();
    });
    assert!(result.is_err());
    assert!(host.inner.leases.borrow().is_empty());
    assert!(host.inner.ui.notes.borrow().is_empty());
    assert!(auto.cache.borrow().is_empty());
}

#[test]
fn reads_classifier_settings_and_choices() {
    let features = |value: Value| value.as_object().unwrap().clone();
    let settings = auto_mode_settings(&features(json!({ "autoMode": {
        "useMemory": false, "timeoutMs": 500,
        "fallbackModels": [{ "provider": "p", "id": "r", "thinking": "high" }],
    } })));
    assert_eq!(
        settings,
        AutoModeSettings {
            use_memory: false,
            timeout_ms: 500,
            fallback_models: vec![ModelChoice {
                provider: "p".to_owned(),
                id: "r".to_owned(),
                thinking: Some(ThinkingLevel::High),
            }],
            ..AutoModeSettings::default()
        }
    );
    // `timeoutMs` above 120 s, a thinking level that does not exist or a
    // null model restores every default.
    for broken in [
        json!({ "timeoutMs": 120_001, "useModel": false }),
        json!({ "timeoutMs": 1.5, "useModel": false }),
        json!({ "model": { "provider": "p", "id": "m", "thinking": "huge" }, "useModel": false }),
        json!({ "model": null, "useModel": false }),
        json!({ "fallbackModels": [{ "provider": "", "id": "m" }], "useModel": false }),
    ] {
        assert_eq!(
            auto_mode_settings(&features(json!({ "autoMode": broken }))),
            AutoModeSettings::default()
        );
    }
    assert_eq!(
        auto_mode_settings(&features(json!({ "autoMode": null }))),
        AutoModeSettings::default()
    );

    // Only auto mode's own models; the session model is appended later.
    let ids = |value: Value| -> Vec<String> {
        classifier_choices(&features(value))
            .into_iter()
            .map(|choice| choice.id)
            .collect()
    };
    assert_eq!(
        ids(json!({ "autoMode": { "model": { "provider": "c", "id": "x" } } })),
        ["x"]
    );
    assert_eq!(
        ids(json!({ "autoMode": { "fallbackModels": [{ "provider": "c", "id": "y" }] } })),
        ["y"]
    );
    // Broken auto-mode settings do not borrow models from other features.
    assert!(ids(json!({ "autoMode": { "model": { "provider": "c" } } })).is_empty());
    assert!(ids(json!({})).is_empty());
    assert!(
        ids(json!({ "observationalMemory": { "model": { "provider": "a", "id": "m" } } }))
            .is_empty()
    );
}

fn moded(mode: &str, has_ui: bool) -> TestHost {
    host(
        json!({ "autoMode": { "mode": mode, "useModel": false, "deny": ["deploy-prod"] } }),
        has_ui,
    )
}

#[tokio::test]
async fn read_only_mode_asks_for_anything_that_may_write() {
    let host = moded("read-only", false);
    let auto = AutoMode::new();
    // Reads run, without a lease.
    assert_eq!(
        gate(&auto, &host, "bash", args(json!({ "command": "ls -la" }))).await,
        None
    );
    assert!(host.leases.borrow().is_empty());
    // A known write, an unclear command and the file tools need a human.
    for (tool, call) in [
        ("bash", json!({ "command": "touch notes.txt" })),
        ("bash", json!({ "command": "some-tool --frob" })),
        ("write", json!({ "path": "a.txt", "content": "x" })),
        ("edit", json!({ "path": "a.txt", "edits": [] })),
    ] {
        let refused = gate(&auto, &host, tool, args(call)).await.unwrap();
        assert!(refused.contains("read-only mode"), "{refused}");
        assert!(refused.contains("no UI"), "{refused}");
    }
    assert!(host.leases.borrow().is_empty());
    // Danger is still called dangerous.
    let refused = gate(&auto, &host, "bash", args(json!({ "command": "rm -rf ~" })))
        .await
        .unwrap();
    assert!(
        refused.contains("Dangerous actions need a human"),
        "{refused}"
    );
}

#[tokio::test]
async fn read_only_mode_runs_what_the_user_allows() {
    let host = moded("read-only", true);
    host.ui.answer.set(Some(true));
    let auto = AutoMode::new();
    assert_eq!(
        gate(
            &auto,
            &host,
            "bash",
            args(json!({ "command": "touch notes.txt" }))
        )
        .await,
        None
    );
    assert_eq!(
        gate(
            &auto,
            &host,
            "write",
            args(json!({ "path": "a.txt", "content": "x" }))
        )
        .await,
        None
    );
    assert_eq!(
        *host.ui.confirm_titles.borrow(),
        [
            "Read-only mode: allow this action?",
            "Read-only mode: allow this action?"
        ]
    );
    // The command still takes the lease; the file tool takes its own.
    assert_eq!(host.leases.borrow().len(), 1);
}

#[tokio::test]
async fn full_access_mode_skips_the_gate_but_keeps_the_deny_list_and_the_lease() {
    let host = moded("full-access", false);
    let auto = AutoMode::new();
    assert_eq!(
        gate(
            &auto,
            &host,
            "bash",
            args(json!({ "command": "rm -rf build" }))
        )
        .await,
        None
    );
    assert_eq!(
        gate(
            &auto,
            &host,
            "write",
            args(json!({ "path": "a.txt", "content": "x" }))
        )
        .await,
        None
    );
    assert_eq!(host.leases.borrow().len(), 1);
    let refused = gate(
        &auto,
        &host,
        "bash",
        args(json!({ "command": "sh -c 'echo deploy-prod'" })),
    )
    .await
    .unwrap();
    assert!(refused.contains("deny-list"), "{refused}");
}
