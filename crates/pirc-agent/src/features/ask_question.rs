//! `ask-question` (`agent/features/ask-question.ts`): the
//! `ask_user_question` capability, one to four questions asked through
//! the UI's dialogs (a choice with an "Other" option, or a typed answer),
//! with structured answers. Team workers ask the user with `agent_ask`
//! instead, which shares [`ask_questions`] and [`question_result_schema`].

use std::cell::{Cell, RefCell};
use std::rc::Rc;

use serde_json::{Map, Value, json};

use crate::LocalBoxFuture;
use crate::agent::Agent;
use crate::feature::Feature;
use crate::signal::{AbortController, AbortSignal};
use crate::tools::result_schema::{arr, fields, obj, one_of_strings, str_};
use crate::tools::{Tool, ToolContext, ToolResult, ToolSpec, js, spec_tool, typed};
use crate::ui::{Choice, DialogOptions, Ui};

const OTHER: &str = "Other (type your own answer)";

/// `unsafe`: control characters other than tab and line feed.
fn has_unsafe(text: &str) -> bool {
    text.chars()
        .any(|c| matches!(c, '\u{0}'..='\u{8}' | '\u{b}'..='\u{1f}' | '\u{7f}'..='\u{9f}'))
}

/// `Question`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Question {
    pub question: String,
    pub header: Option<String>,
    pub options: Option<Vec<Choice>>,
    pub multi_select: bool,
}

/// `QuestionAnswer`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct QuestionAnswer {
    pub question: String,
    pub selected: Vec<String>,
    pub custom_text: Option<String>,
}

/// `QuestionResult['status']`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum QuestionStatus {
    Answered,
    Cancelled,
    Unavailable,
}

/// `QuestionResult`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct QuestionResult {
    pub status: QuestionStatus,
    pub answers: Vec<QuestionAnswer>,
}

impl QuestionResult {
    fn empty(status: QuestionStatus) -> Self {
        Self {
            status,
            answers: Vec::new(),
        }
    }

    /// `{status, answers: [{question, selected, customText?}]}`.
    pub fn to_value(&self) -> Value {
        let status = match self.status {
            QuestionStatus::Answered => "answered",
            QuestionStatus::Cancelled => "cancelled",
            QuestionStatus::Unavailable => "unavailable",
        };
        let answers: Vec<Value> = self
            .answers
            .iter()
            .map(|answer| {
                let mut out = Map::new();
                out.insert("question".to_owned(), json!(answer.question));
                out.insert("selected".to_owned(), json!(answer.selected));
                if let Some(text) = &answer.custom_text {
                    out.insert("customText".to_owned(), json!(text));
                }
                Value::Object(out)
            })
            .collect();
        json!({ "status": status, "answers": answers })
    }
}

fn nonblank(text: &str) -> bool {
    !js::trim(text).is_empty()
}

/// `validateQuestions(params)`: the questions, or the error the TS tool
/// threw.
pub fn validate_questions(params: &Map<String, Value>) -> Result<Vec<Question>, String> {
    let questions = match params.get("questions") {
        Some(Value::Array(items)) if (1..=4).contains(&items.len()) => items,
        _ => return Err("Provide 1–4 questions".to_owned()),
    };
    if js::len16(&js::stringify(&Value::Object(params.clone()))) > 24_000 {
        return Err("Questionnaire exceeds 24000 characters".to_owned());
    }
    let mut out = Vec::new();
    for q in questions {
        let field = |key: &str| q.as_object().and_then(|q| q.get(key));
        let question = match field("question") {
            Some(Value::String(text)) if nonblank(text) && js::len16(text) <= 12_000 => text,
            _ => return Err("Question must be nonempty text (max 12000 characters)".to_owned()),
        };
        let header = match field("header") {
            None => None,
            Some(Value::String(header)) if js::len16(header) <= 120 => Some(header),
            Some(_) => return Err("Invalid question header".to_owned()),
        };
        let multi_select = match field("multiSelect") {
            None => false,
            Some(Value::Bool(value)) => *value,
            Some(_) => return Err("multiSelect must be boolean".to_owned()),
        };
        let options = match field("options") {
            None => None,
            Some(Value::Array(items)) if items.len() <= 12 => {
                let mut options = Vec::new();
                for item in items {
                    let get = |key: &str| item.as_object().and_then(|item| item.get(key));
                    let label = match get("label") {
                        Some(Value::String(label))
                            if nonblank(label) && js::len16(label) <= 1000 && label != OTHER =>
                        {
                            label
                        }
                        _ => {
                            return Err(
                                "Provide at most 12 options with nonempty labels".to_owned()
                            );
                        }
                    };
                    let description = match get("description") {
                        None => None,
                        Some(Value::String(text)) if js::len16(text) <= 4000 => Some(text),
                        Some(_) => {
                            return Err(
                                "Provide at most 12 options with nonempty labels".to_owned()
                            );
                        }
                    };
                    options.push(Choice {
                        label: label.clone(),
                        description: description.cloned(),
                    });
                }
                Some(options)
            }
            Some(_) => return Err("Provide at most 12 options with nonempty labels".to_owned()),
        };
        let texts = std::iter::once(Some(question))
            .chain(std::iter::once(header))
            .chain(
                options
                    .iter()
                    .flatten()
                    .flat_map(|option| [Some(&option.label), option.description.as_ref()]),
            );
        if texts.flatten().any(|text| has_unsafe(text)) {
            return Err("Question text must not contain control characters".to_owned());
        }
        if let Some(options) = &options {
            let mut labels: Vec<&str> = options.iter().map(|o| o.label.as_str()).collect();
            labels.sort_unstable();
            labels.dedup();
            if labels.len() != options.len() {
                return Err("Option labels must be unique".to_owned());
            }
        }
        out.push(Question {
            question: question.clone(),
            header: header.cloned(),
            options,
            multi_select,
        });
    }
    Ok(out)
}

fn dialog(signal: &AbortSignal) -> DialogOptions {
    DialogOptions {
        signal: Some(signal.clone()),
        ..DialogOptions::default()
    }
}

/// `askOne`: `None` when the human cancelled.
async fn ask_one(ui: &dyn Ui, q: &Question, signal: &AbortSignal) -> Option<QuestionAnswer> {
    let title = match q.header.as_deref() {
        Some(header) if !header.is_empty() => format!("{header}: {}", q.question),
        _ => q.question.clone(),
    };
    // A typed answer, asked again while blank or too long.
    let typed = async || -> Option<String> {
        while !signal.aborted() {
            let text = ui
                .input(&title, Some("Enter your answer"), dialog(signal))
                .await?;
            let trimmed = js::trim(&text);
            if !trimmed.is_empty() && js::len16(&text) <= 4000 {
                return Some(trimmed.to_owned());
            }
        }
        None
    };
    let options = q.options.as_deref().unwrap_or_default();
    if options.is_empty() {
        let text = typed().await?;
        return Some(QuestionAnswer {
            question: q.question.clone(),
            selected: Vec::new(),
            custom_text: Some(text),
        });
    }
    let mut choices = options.to_vec();
    choices.push(Choice {
        label: OTHER.to_owned(),
        description: None,
    });
    let picked = ui
        .choose(&title, &choices, q.multi_select, dialog(signal))
        .await
        .filter(|picked| !picked.is_empty())?;
    if signal.aborted() {
        return None;
    }
    let selected: Vec<String> = options
        .iter()
        .map(|option| option.label.clone())
        .filter(|label| picked.contains(label))
        .collect();
    if !picked.iter().any(|label| label == OTHER) {
        return Some(QuestionAnswer {
            question: q.question.clone(),
            selected,
            custom_text: None,
        });
    }
    let text = typed().await?;
    Some(QuestionAnswer {
        question: q.question.clone(),
        selected,
        custom_text: Some(text),
    })
}

/// `askQuestions`: every question in order; one cancelled cancels all.
pub async fn ask_questions(
    ui: &dyn Ui,
    has_ui: bool,
    questions: &[Question],
    signal: &AbortSignal,
) -> QuestionResult {
    if signal.aborted() {
        return QuestionResult::empty(QuestionStatus::Cancelled);
    }
    if !has_ui {
        return QuestionResult::empty(QuestionStatus::Unavailable);
    }
    let mut answers = Vec::new();
    for q in questions {
        match ask_one(ui, q, signal).await {
            Some(answer) if !signal.aborted() => answers.push(answer),
            _ => return QuestionResult::empty(QuestionStatus::Cancelled),
        }
    }
    QuestionResult {
        status: QuestionStatus::Answered,
        answers,
    }
}

/// `QUESTION_RESULT`: the typed result of asking the human
/// (`ask_user_question`, `agent_ask` to the user).
pub fn question_result_schema() -> Value {
    fields(
        vec![
            (
                "status",
                one_of_strings(&["answered", "cancelled", "unavailable"], None),
            ),
            (
                "answers",
                arr(
                    obj(
                        vec![
                            ("question", str_(None)),
                            (
                                "selected",
                                arr(str_(None), Some("Labels of the chosen options")),
                            ),
                            ("customText", str_(Some("A typed answer"))),
                        ],
                        &["customText"],
                    ),
                    Some("One per question, in order (empty unless answered)"),
                ),
            ),
        ],
        &[],
    )
}

/// `askQuestionSchema`.
pub fn ask_question_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "questions": {
                "type": "array",
                "minItems": 1,
                "maxItems": 4,
                "items": {
                    "type": "object",
                    "properties": {
                        "question": { "type": "string", "description": "Question for the human user" },
                        "header": { "type": "string", "description": "Short label (max 120 chars)" },
                        "options": {
                            "type": "array",
                            "maxItems": 12,
                            "items": {
                                "type": "object",
                                "properties": { "label": { "type": "string" }, "description": { "type": "string" } },
                                "required": ["label"],
                                "additionalProperties": false,
                            },
                        },
                        "multiSelect": { "type": "boolean" },
                    },
                    "required": ["question"],
                    "additionalProperties": false,
                },
            },
        },
        "required": ["questions"],
        "additionalProperties": false,
    })
}

/// Calls in flight, aborted when the agent shuts down (`lifetime`).
#[derive(Default)]
struct Lifetime {
    calls: RefCell<Vec<(u64, AbortController)>>,
    next: Cell<u64>,
}

/// Removes a call from [`Lifetime`] when it ends.
struct Registered<'a>(&'a Lifetime, u64);

impl Drop for Registered<'_> {
    fn drop(&mut self) {
        self.0.calls.borrow_mut().retain(|(id, _)| *id != self.1);
    }
}

/// `ask_user_question`.
struct AskQuestionTool {
    spec: ToolSpec,
    lifetime: Rc<Lifetime>,
}

impl AskQuestionTool {
    async fn run(&self, args: Map<String, Value>, ctx: ToolContext) -> Result<ToolResult, String> {
        let questions = validate_questions(&args)?;
        if !ctx.has_ui {
            let result = QuestionResult::empty(QuestionStatus::Unavailable).to_value();
            return Ok(typed(
                "Human UI unavailable in this agent. If you are a team worker, use agent_ask with to: \"user\".",
                result.clone(),
                Some(result),
                false,
            ));
        }
        // `AbortSignal.any([ctx.signal, lifetime.signal])`.
        let controller = AbortController::child_of(&ctx.signal);
        let id = self.lifetime.next.get();
        self.lifetime.next.set(id + 1);
        self.lifetime
            .calls
            .borrow_mut()
            .push((id, controller.clone()));
        let _registered = Registered(&self.lifetime, id);
        let result = ask_questions(&*ctx.ui, true, &questions, &controller.signal()).await;
        let value = result.to_value();
        let text = js::stringify(&value);
        let text = if js::len16(&text) > 48_000 {
            format!(
                "{}\n[truncated; full answers in details]",
                js::head16(&text, 10_000)
            )
        } else {
            text
        };
        Ok(typed(text, value.clone(), Some(value), false))
    }
}

spec_tool!(AskQuestionTool, ptc: false);

/// `askQuestionFeature()`.
pub fn feature() -> Rc<dyn Feature> {
    Rc::new(AskQuestionFeature::default())
}

#[derive(Default)]
struct AskQuestionFeature {
    lifetime: Rc<Lifetime>,
}

impl Feature for AskQuestionFeature {
    fn name(&self) -> &'static str {
        "ask-question"
    }

    fn tools(&self, _agent: &Rc<Agent>) -> Vec<Rc<dyn Tool>> {
        vec![Rc::new(AskQuestionTool {
            spec: ToolSpec::new(
                "ask_user_question",
                ask_question_schema(),
                Some(question_result_schema()),
            ),
            lifetime: self.lifetime.clone(),
        })]
    }

    fn shutdown<'a>(&'a self, _agent: &'a Rc<Agent>) -> LocalBoxFuture<'a, ()> {
        Box::pin(async move {
            let calls: Vec<AbortController> = self
                .lifetime
                .calls
                .borrow()
                .iter()
                .map(|(_, controller)| controller.clone())
                .collect();
            for controller in calls {
                controller.abort();
            }
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn validate(args: Value) -> Result<Vec<Question>, String> {
        validate_questions(args.as_object().unwrap())
    }

    #[test]
    fn validates_questionnaires_as_ts_does() {
        let q = |text: &str| json!({ "question": text });
        for (args, error) in [
            (json!({}), "Provide 1–4 questions"),
            (json!({ "questions": [] }), "Provide 1–4 questions"),
            (
                json!({ "questions": [q("1"), q("2"), q("3"), q("4"), q("5")] }),
                "Provide 1–4 questions",
            ),
            (
                json!({ "questions": ["x"] }),
                "Question must be nonempty text (max 12000 characters)",
            ),
            (
                json!({ "questions": [q(" \n ")] }),
                "Question must be nonempty text (max 12000 characters)",
            ),
            (
                json!({ "questions": [q(&"x".repeat(12_001))] }),
                "Question must be nonempty text (max 12000 characters)",
            ),
            (
                json!({ "questions": [q(&"x".repeat(24_000))] }),
                "Questionnaire exceeds 24000 characters",
            ),
            (
                json!({ "questions": [{ "question": "x", "header": null }] }),
                "Invalid question header",
            ),
            (
                json!({ "questions": [{ "question": "x", "multiSelect": 1 }] }),
                "multiSelect must be boolean",
            ),
            (
                json!({ "questions": [{ "question": "x", "options": [{ "label": " " }] }] }),
                "Provide at most 12 options with nonempty labels",
            ),
            (
                json!({ "questions": [{ "question": "x", "options": [{ "label": OTHER }] }] }),
                "Provide at most 12 options with nonempty labels",
            ),
            (
                json!({ "questions": [{ "question": "x", "options": [{ "label": "a", "description": 1 }] }] }),
                "Provide at most 12 options with nonempty labels",
            ),
            (
                json!({ "questions": [{ "question": "x", "options": {} }] }),
                "Provide at most 12 options with nonempty labels",
            ),
            (
                json!({ "questions": [{ "question": "x", "header": "h\u{1b}" }] }),
                "Question text must not contain control characters",
            ),
            (
                json!({ "questions": [{ "question": "x", "options": [{ "label": "a", "description": "\u{85}" }] }] }),
                "Question text must not contain control characters",
            ),
            (
                json!({ "questions": [{ "question": "x", "options": [{ "label": "a" }, { "label": "a" }] }] }),
                "Option labels must be unique",
            ),
        ] {
            assert_eq!(validate(args.clone()).unwrap_err(), error, "{args}");
        }
        let questions = validate(json!({ "questions": [
            { "question": "Which?\n\twith tabs", "header": "", "multiSelect": true,
              "options": [{ "label": "a", "description": "first" }, { "label": "b" }] },
        ] }))
        .unwrap();
        assert_eq!(
            questions,
            [Question {
                question: "Which?\n\twith tabs".to_owned(),
                header: Some(String::new()),
                options: Some(vec![
                    Choice {
                        label: "a".to_owned(),
                        description: Some("first".to_owned())
                    },
                    Choice {
                        label: "b".to_owned(),
                        description: None
                    },
                ]),
                multi_select: true,
            }]
        );
    }

    /// Answers dialogs from a script and records what it was asked.
    #[derive(Default)]
    struct ScriptedUi {
        choices: RefCell<std::collections::VecDeque<Option<Vec<String>>>>,
        inputs: RefCell<std::collections::VecDeque<Option<String>>>,
        asked: RefCell<Vec<String>>,
        /// Aborted when the first input is asked.
        abort_on_input: RefCell<Option<AbortController>>,
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
            title: &'a str,
            options: &'a [Choice],
            multiple: bool,
            _opts: DialogOptions,
        ) -> LocalBoxFuture<'a, Option<Vec<String>>> {
            let labels: Vec<&str> = options.iter().map(|o| o.label.as_str()).collect();
            self.asked
                .borrow_mut()
                .push(format!("choose {title} {labels:?} {multiple}"));
            let answer = self.choices.borrow_mut().pop_front().flatten();
            Box::pin(async move { answer })
        }
        fn confirm<'a>(
            &'a self,
            _title: &'a str,
            _message: &'a str,
            _opts: DialogOptions,
        ) -> LocalBoxFuture<'a, Option<bool>> {
            Box::pin(async { None })
        }
        fn input<'a>(
            &'a self,
            title: &'a str,
            placeholder: Option<&'a str>,
            _opts: DialogOptions,
        ) -> LocalBoxFuture<'a, Option<String>> {
            self.asked
                .borrow_mut()
                .push(format!("input {title} {placeholder:?}"));
            if let Some(controller) = self.abort_on_input.borrow_mut().take() {
                controller.abort();
            }
            let answer = self.inputs.borrow_mut().pop_front().flatten();
            Box::pin(async move { answer })
        }
        fn editor<'a>(
            &'a self,
            _title: &'a str,
            _prefill: Option<&'a str>,
            _opts: DialogOptions,
        ) -> LocalBoxFuture<'a, Option<String>> {
            Box::pin(async { None })
        }
        fn notify(&self, _message: &str, _level: crate::ui::NotifyLevel) {}
        fn set_status(&self, _key: &str, _text: Option<&str>) {}
        fn set_widget(&self, _key: &str, _lines: Option<&[String]>) {}
    }

    #[tokio::test]
    async fn asks_each_question_in_turn() {
        let ui = ScriptedUi::default();
        ui.choices.borrow_mut().extend([
            Some(vec!["postgres".to_owned()]),
            Some(vec!["a".to_owned(), OTHER.to_owned()]),
        ]);
        ui.inputs.borrow_mut().extend([
            Some("   ".to_owned()),
            Some("x".repeat(4001)),
            Some("  no  ".to_owned()),
            Some("c".to_owned()),
        ]);
        let questions = validate(json!({ "questions": [
            { "question": "Which DB?", "header": "DB",
              "options": [{ "label": "sqlite", "description": "embedded" }, { "label": "postgres" }] },
            { "question": "Anything else?" },
            { "question": "Pick", "multiSelect": true, "options": [{ "label": "a" }, { "label": "b" }] },
        ] }))
        .unwrap();
        let signal = AbortSignal::never();
        let result = ask_questions(&ui, true, &questions, &signal).await;
        assert_eq!(
            js::stringify(&result.to_value()),
            r#"{"status":"answered","answers":[{"question":"Which DB?","selected":["postgres"]},{"question":"Anything else?","selected":[],"customText":"no"},{"question":"Pick","selected":["a"],"customText":"c"}]}"#
        );
        assert_eq!(
            *ui.asked.borrow(),
            [
                r#"choose DB: Which DB? ["sqlite", "postgres", "Other (type your own answer)"] false"#,
                r#"input Anything else? Some("Enter your answer")"#,
                r#"input Anything else? Some("Enter your answer")"#,
                r#"input Anything else? Some("Enter your answer")"#,
                r#"choose Pick ["a", "b", "Other (type your own answer)"] true"#,
                r#"input Pick Some("Enter your answer")"#,
            ]
        );
        assert_eq!(
            ask_questions(&ui, false, &questions, &signal).await,
            QuestionResult::empty(QuestionStatus::Unavailable)
        );
    }

    #[tokio::test]
    async fn a_cancelled_dialog_or_an_abort_cancels_all() {
        let questions =
            validate(json!({ "questions": [{ "question": "First?" }, { "question": "Second?" }] }))
                .unwrap();
        let ui = ScriptedUi::default();
        ui.inputs
            .borrow_mut()
            .extend([Some("yes".to_owned()), None]);
        let result = ask_questions(&ui, true, &questions, &AbortSignal::never()).await;
        assert_eq!(result, QuestionResult::empty(QuestionStatus::Cancelled));
        let ui = ScriptedUi::default();
        let controller = AbortController::new();
        *ui.abort_on_input.borrow_mut() = Some(controller.clone());
        ui.inputs.borrow_mut().push_back(Some("late".to_owned()));
        let result = ask_questions(&ui, true, &questions, &controller.signal()).await;
        assert_eq!(result, QuestionResult::empty(QuestionStatus::Cancelled));
        assert_eq!(ui.asked.borrow().len(), 1);
        assert_eq!(
            ask_questions(&ui, true, &questions, &controller.signal()).await,
            QuestionResult::empty(QuestionStatus::Cancelled)
        );
    }

    #[tokio::test]
    async fn the_tool_answers_unavailable_without_a_human() {
        let dir = tempfile::tempdir().unwrap();
        let config = crate::tools::testing::config(&dir.path().display().to_string(), json!({}));
        let context = crate::tools::testing::context(config, AbortSignal::never());
        let tools = feature().tools(&dummy_agent(dir.path()));
        let result = tools[0]
            .execute(
                crate::tools::testing::args(json!({ "questions": [{ "question": "x" }] })),
                context.ctx,
            )
            .await
            .unwrap();
        assert_eq!(
            crate::tools::testing::text_of(&result),
            "Human UI unavailable in this agent. If you are a team worker, use agent_ask with to: \"user\"."
        );
        assert_eq!(
            result.details,
            Some(json!({ "status": "unavailable", "answers": [] }))
        );
        assert_eq!(
            result.data.map(Value::Object),
            Some(json!({ "status": "unavailable", "answers": [] }))
        );
    }

    fn dummy_agent(dir: &std::path::Path) -> Rc<Agent> {
        let config = crate::tools::testing::config(&dir.display().to_string(), json!({}));
        let store =
            crate::session_store::SessionStore::open(dir.join("session"), &config.workspace)
                .unwrap();
        Agent::new(crate::agent::AgentOptions {
            config,
            capabilities: Default::default(),
            role: None,
            store,
            emit: Rc::new(|_| {}),
            ui: Rc::new(crate::tools::testing::TestUi::default()),
            has_ui: false,
            tools: Vec::new(),
            features: Vec::new(),
            acquire_write: None,
            allowed_tools: None,
            stream_override: None,
        })
    }

    #[test]
    fn writes_results_in_ts_key_order() {
        let result = QuestionResult {
            status: QuestionStatus::Answered,
            answers: vec![
                QuestionAnswer {
                    question: "q".to_owned(),
                    selected: vec!["a".to_owned()],
                    custom_text: None,
                },
                QuestionAnswer {
                    question: "r".to_owned(),
                    selected: Vec::new(),
                    custom_text: Some("t".to_owned()),
                },
            ],
        };
        assert_eq!(
            js::stringify(&result.to_value()),
            r#"{"status":"answered","answers":[{"question":"q","selected":["a"]},{"question":"r","selected":[],"customText":"t"}]}"#
        );
    }
}
