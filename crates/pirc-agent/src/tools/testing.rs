//! Test doubles for the tools, auto mode and the PTC surface: a config, a
//! UI that records what it is asked, a tool context and an agent host.

use std::cell::{Cell, RefCell};
use std::rc::Rc;

use pirc_policy::{PathGuard, PathPolicy, real_resolve};
use serde_json::{Map, Value, json};

use super::{AcquireWrite, Tool, ToolContext, ToolResult};
use crate::LocalBoxFuture;
use crate::config::{AgentConfig, HooksConfig, Limits};
use crate::host::AgentHost;
use crate::signal::AbortSignal;
use crate::ui::{Choice, DialogOptions, NotifyLevel, Ui};

/// A config for `workspace` (which must exist), writable there only.
pub fn config(workspace: &str, features: Value) -> AgentConfig {
    let workspace = real_resolve(workspace);
    AgentConfig {
        config_dir: format!("{workspace}/../config"),
        workspace: workspace.clone(),
        models: serde_json::from_value(json!({})).unwrap(),
        default_model: None,
        allowed_paths: vec![workspace.clone()],
        protected_paths: Vec::new(),
        project_root: workspace.clone(),
        warnings: Vec::new(),
        path_policy: PathPolicy {
            allow_write: vec![workspace],
            ..PathPolicy::default()
        },
        sandboxed: false,
        env: Vec::new(),
        hooks: HooksConfig::default(),
        limits: Limits::default(),
        features: features.as_object().cloned().unwrap_or_default(),
        role_dirs: Vec::new(),
        system_prompt: Vec::new(),
        mode: pirc_protocol::mode::default_work(),
    }
}

/// A UI that records notifications and confirmations and answers
/// confirmations with `answer`.
#[derive(Default)]
pub struct TestUi {
    pub notes: RefCell<Vec<String>>,
    pub confirms: RefCell<Vec<String>>,
    pub confirm_titles: RefCell<Vec<String>>,
    pub answer: Cell<Option<bool>>,
}

impl Ui for TestUi {
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
        message: &'a str,
        _opts: DialogOptions,
    ) -> LocalBoxFuture<'a, Option<bool>> {
        self.confirms.borrow_mut().push(message.to_owned());
        self.confirm_titles.borrow_mut().push(title.to_owned());
        let answer = self.answer.get();
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
    fn notify(&self, message: &str, _level: NotifyLevel) {
        self.notes.borrow_mut().push(message.to_owned());
    }
    fn set_status(&self, _key: &str, _text: Option<&str>) {}
    fn set_widget(&self, _key: &str, _lines: Option<&[String]>) {}
}

/// A tool context in `config.workspace`; `leases` records `acquire_write`,
/// `updates` the partial results.
pub struct Context {
    pub ctx: ToolContext,
    pub leases: Rc<RefCell<Vec<String>>>,
    pub updates: Rc<RefCell<Vec<ToolResult>>>,
    pub refuse: Rc<RefCell<Option<String>>>,
}

pub fn context(config: AgentConfig, signal: AbortSignal) -> Context {
    let guard = PathGuard::new(
        &config.workspace,
        &config.path_policy,
        &config.protected_paths,
    );
    let leases = Rc::new(RefCell::new(Vec::new()));
    let updates = Rc::new(RefCell::new(Vec::new()));
    let refuse: Rc<RefCell<Option<String>>> = Rc::new(RefCell::new(None));
    let acquire_write: AcquireWrite = {
        let leases = leases.clone();
        let refuse = refuse.clone();
        Rc::new(move |file: String| {
            leases.borrow_mut().push(file);
            let refusal = refuse.borrow().clone();
            Box::pin(async move {
                match refusal {
                    Some(error) => Err(error),
                    None => Ok(()),
                }
            })
        })
    };
    let sink = updates.clone();
    Context {
        ctx: ToolContext {
            cwd: config.workspace.clone(),
            config: Rc::new(config),
            guard: Rc::new(guard),
            signal,
            tool_call_id: "call-1".to_owned(),
            ui: Rc::new(TestUi::default()),
            has_ui: false,
            env: Vec::new(),
            acquire_write,
            update: Rc::new(move |partial| sink.borrow_mut().push(partial)),
            human_wait: Rc::new(super::HumanWait::none),
        },
        leases,
        updates,
        refuse,
    }
}

/// The text of a result's first block.
pub fn text_of(result: &ToolResult) -> String {
    match result.content.first() {
        Some(pirc_protocol::UserBlock::Text { text, .. }) => text.clone(),
        _ => String::new(),
    }
}

pub fn args(value: Value) -> Map<String, Value> {
    value.as_object().cloned().unwrap_or_default()
}

/// An agent host over a fixed tool list.
pub struct TestHost {
    pub config: RefCell<Rc<AgentConfig>>,
    pub guard: Rc<PathGuard>,
    pub ui: Rc<TestUi>,
    pub has_ui: bool,
    pub tools: Vec<Rc<dyn Tool>>,
    pub direct: Vec<Rc<dyn Tool>>,
    pub leases: RefCell<Vec<String>>,
    /// How long `acquire_write` takes.
    pub lease_delay_ms: Cell<u64>,
}

impl TestHost {
    pub fn new(config: AgentConfig, tools: Vec<Rc<dyn Tool>>, has_ui: bool) -> Self {
        let guard = PathGuard::new(
            &config.workspace,
            &config.path_policy,
            &config.protected_paths,
        );
        let direct = crate::ptc::DIRECT_CAPABILITIES
            .iter()
            .filter_map(|name| tools.iter().find(|tool| tool.name() == *name).cloned())
            .collect();
        Self {
            config: RefCell::new(Rc::new(config)),
            guard: Rc::new(guard),
            ui: Rc::new(TestUi::default()),
            has_ui,
            tools,
            direct,
            leases: RefCell::new(Vec::new()),
            lease_delay_ms: Cell::new(0),
        }
    }

    pub fn set_features(&self, features: Value) {
        let mut config = (**self.config.borrow()).clone();
        config.features = features.as_object().cloned().unwrap_or_default();
        *self.config.borrow_mut() = Rc::new(config);
    }
}

impl AgentHost for TestHost {
    fn config(&self) -> Rc<AgentConfig> {
        self.config.borrow().clone()
    }
    fn guard(&self) -> Rc<PathGuard> {
        self.guard.clone()
    }
    fn ui(&self) -> Rc<dyn Ui> {
        self.ui.clone()
    }
    fn has_ui(&self) -> bool {
        self.has_ui
    }
    fn session_id(&self) -> String {
        "session-1".to_owned()
    }
    fn acquire_write<'a>(
        &'a self,
        file: &'a str,
        _signal: &'a AbortSignal,
    ) -> LocalBoxFuture<'a, Result<(), String>> {
        Box::pin(async move {
            let delay = self.lease_delay_ms.get();
            if delay > 0 {
                tokio::time::sleep(std::time::Duration::from_millis(delay)).await;
            }
            self.leases.borrow_mut().push(file.to_owned());
            Ok(())
        })
    }
    fn tool_list(&self) -> Vec<Rc<dyn Tool>> {
        self.tools.clone()
    }
    fn direct_tool_list(&self) -> Vec<Rc<dyn Tool>> {
        self.direct.clone()
    }
}
