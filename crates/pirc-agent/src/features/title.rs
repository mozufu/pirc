//! `session-title` (`agent/features/title.ts`): automatic session titles,
//! after oh-my-pi's title generator. The first user message that describes
//! work is sent to a model in a side request (no tools, no thinking) that
//! answers with `<title>…</title>`. Greetings are skipped without a model
//! call. Failed requests retry in the background using the same first message;
//! a bounded local fallback keeps provider errors from leaving sessions unnamed.

use std::cell::{Cell, RefCell};
use std::collections::HashSet;
use std::rc::Rc;
use std::sync::LazyLock;
use std::time::Duration;

use pirc_protocol::{AssistantContent, Message, StopReason, ThinkingLevel, UserContent};
use serde_json::Value;

use crate::agent::{Agent, NameSource};
use crate::feature::Feature;
use crate::signal::{AbortController, AbortSignal};
use crate::stream::StreamRequest;
use crate::tools::js::{self, js_regex};
use crate::{LocalBoxFuture, now_ms};

const MAX_INPUT_CHARS: usize = 2_000;
const MAX_TITLE_CHARS: usize = 80;
const MAX_TOKENS: u64 = 512;
const TIMEOUT_MS: u64 = 30_000;

const MARKER_INSTRUCTION: &str = "Wrap the title in <title></title> tags and output nothing else. If the message does not describe a task or topic, output <title>none</title>.";

/// `TITLE_SYSTEM_PROMPT`.
pub static TITLE_SYSTEM_PROMPT: LazyLock<String> = LazyLock::new(|| {
    format!(
        "You name coding-agent sessions from the user's first message.
Write a concise title of 3 to 7 words that captures the task (for example \"Fix login button on mobile\").
Use the same language as the user's message. Use sentence case, no quotes, no emoji, and no trailing punctuation.
{MARKER_INSTRUCTION}"
    )
});

const LOW_SIGNAL: [&str; 47] = [
    "hi",
    "hello",
    "hey",
    "yo",
    "sup",
    "thanks",
    "thank you",
    "thx",
    "ty",
    "ok",
    "okay",
    "k",
    "yes",
    "yeah",
    "yep",
    "no",
    "nope",
    "sure",
    "cool",
    "nice",
    "great",
    "good",
    "continue",
    "go on",
    "go ahead",
    "test",
    "ping",
    "你好",
    "您好",
    "嗨",
    "哈囉",
    "哈喽",
    "謝謝",
    "谢谢",
    "好",
    "好的",
    "嗯",
    "對",
    "对",
    "是",
    "不是",
    "在嗎",
    "在吗",
    "繼續",
    "继续",
    "測試",
    "测试",
];

/// `isLowSignalTitleInput`: greetings, acknowledgements, bare numbers and
/// emoji carry no task to name.
pub fn is_low_signal_title_input(text: &str) -> bool {
    static SET: LazyLock<HashSet<&'static str>> =
        LazyLock::new(|| LOW_SIGNAL.into_iter().collect());
    let lower = js::trim(text).to_lowercase();
    let normalized = js_regex!(r"[\s\p{P}\p{S}]+$", "u").replace_all(&lower, "");
    let normalized = js_regex!(r"^[\s\p{P}\p{S}]+", "u").replace_all(&normalized, "");
    let normalized = js_regex!(r"\s+", "g").replace_all(&normalized, " ");
    if normalized.is_empty() || SET.contains(normalized.as_str()) {
        return true;
    }
    if js_regex!(r"^\d+$").test(&normalized) {
        return true;
    }
    // Emoji, symbols and punctuation only.
    !js_regex!(r"[\p{L}\p{N}]", "u").test(&normalized)
}

/// `parseTitle`: a clean title from a model reply; `None` when it declined
/// or produced nothing usable.
pub fn parse_title(raw: &str) -> Option<String> {
    let text = js_regex!(r"<(think|thinking|reasoning)>[\s\S]*?<\/\1>", "gi").replace_all(raw, "");
    let mut text = js_regex!(r"```(?:reasoning|thinking)[\s\S]*?```", "gi").replace_all(&text, "");
    let tagged = js_regex!(r"<title>([\s\S]*?)(?:<\/title>|$)", "gi")
        .find_iter(&text)
        .last()
        .map(|found| {
            found
                .group(1)
                .map_or(String::new(), |range| text[range].to_owned())
        });
    match tagged {
        Some(inner) => text = inner,
        None if js_regex!(r"<title\s*\/>", "i").test(&text) => return None,
        None => {}
    }
    let text = js_regex!(r"^```\w*\s*|\s*```$", "g").replace_all(&text, "");
    let mut text = js::trim(&text).to_owned();
    let json = js_regex!(r#"^\{\s*"title"\s*:\s*"((?:[^"\\]|\\.)*)"?"#)
        .captures(&text)
        .map(|found| {
            found
                .group(1)
                .map_or(String::new(), |range| text[range].to_owned())
        });
    if let Some(json) = json {
        text = serde_json::from_str::<String>(&format!("\"{json}\"")).unwrap_or(json);
    }
    let line = text
        .split('\n')
        .map(js::trim)
        .find(|line| !line.is_empty())?;
    let title = js_regex!(r"^(?:title|標題|标题)\s*[:：]\s*", "i").replace_all(line, "");
    let title =
        js_regex!(r#"^["'`“”‘’「」『』]+|["'`“”‘’「」『』]+$"#, "g").replace_all(&title, "");
    let title = js_regex!(r"[\s.。!！,，;；:：]+$", "u").replace_all(&title, "");
    let title = js_regex!(r"\s+", "g").replace_all(&title, " ");
    let mut title = js::trim(&title).to_owned();
    if title.is_empty() || js_regex!(r"^(none|null|n\/a)$", "i").test(&title) {
        return None;
    }
    if js::len16(&title) > MAX_TITLE_CHARS {
        let cut = js::head16(&title, MAX_TITLE_CHARS);
        let kept = match cut.rfind(' ') {
            Some(space) if js::len16(&cut[..space]) > MAX_TITLE_CHARS / 2 => &cut[..space],
            _ => cut,
        };
        title = format!("{}…", js::trim_end(kept));
    }
    Some(title)
}

/// `replyText`.
fn reply_text(content: &[AssistantContent]) -> String {
    content
        .iter()
        .filter_map(|part| match part {
            AssistantContent::Text { text, .. } => Some(text.as_str()),
            _ => None,
        })
        .collect()
}

/// `settingsSchema`'s result: `features.sessionTitle`.
#[derive(Clone, Debug, PartialEq)]
pub struct TitleSettings {
    pub enabled: bool,
    /// Model for titles; defaults to the session's current model.
    pub model: Option<(String, String)>,
    /// Replaces the default system prompt; the `<title>` instruction is
    /// always appended.
    pub prompt: Option<String>,
    pub max_attempts: u64,
}

impl Default for TitleSettings {
    fn default() -> Self {
        Self {
            enabled: true,
            model: None,
            prompt: None,
            max_attempts: 3,
        }
    }
}

impl TitleSettings {
    /// `settingsSchema.safeParse(value ?? {})`; `None` when it fails.
    fn parse(value: Option<&Value>) -> Option<Self> {
        let object = match value {
            None | Some(Value::Null) => return Some(Self::default()),
            Some(Value::Object(object)) => object,
            Some(_) => return None,
        };
        let mut settings = Self::default();
        match object.get("enabled") {
            None => {}
            Some(Value::Bool(enabled)) => settings.enabled = *enabled,
            Some(_) => return None,
        }
        match object.get("model") {
            None => {}
            Some(Value::Object(model)) => match (model.get("provider"), model.get("id")) {
                (Some(Value::String(provider)), Some(Value::String(id))) => {
                    settings.model = Some((provider.clone(), id.clone()));
                }
                _ => return None,
            },
            Some(_) => return None,
        }
        match object.get("prompt") {
            None => {}
            Some(Value::String(prompt)) => settings.prompt = Some(prompt.clone()),
            Some(_) => return None,
        }
        match object.get("maxAttempts") {
            None => {}
            Some(Value::Number(n)) => {
                let value = n.as_f64()?;
                if value.fract() != 0.0 || value <= 0.0 || value > 10.0 {
                    return None;
                }
                settings.max_attempts = value as u64;
            }
            Some(_) => return None,
        }
        Some(settings)
    }
}

/// `titleSettings`: the configured settings, or the defaults when they do
/// not fit the schema.
pub fn title_settings(agent: &Agent) -> TitleSettings {
    let config = agent.config();
    let mut settings =
        TitleSettings::parse(config.features.get("sessionTitle")).unwrap_or_default();
    settings.enabled &= !config.feature_disabled_by_mode("sessionTitle");
    settings
}

/// `generateTitle`: one title request; `None` on any failure.
pub async fn generate_title(agent: &Agent, message: &str, signal: AbortSignal) -> Option<String> {
    let settings = title_settings(agent);
    let resolved = agent.resolve_model(settings.model.clone()).ok()?;
    let system_prompt = match settings.prompt.as_deref().map(js::trim) {
        Some(custom) if !custom.is_empty() => format!("{custom}\n\n{MARKER_INSTRUCTION}"),
        _ => TITLE_SYSTEM_PROMPT.clone(),
    };
    let input = js::head16(js::trim(message), MAX_INPUT_CHARS);
    let session_id = agent.state()["sessionId"]
        .as_str()
        .unwrap_or_default()
        .to_owned();
    let request = StreamRequest {
        purpose: pirc_protocol::RequestPurpose::Title,
        max_tokens: Some(resolved.model.max_tokens.min(MAX_TOKENS)),
        provider_name: resolved.provider_name,
        provider: resolved.provider,
        model: resolved.model,
        system_prompt,
        messages: vec![Message::User {
            content: UserContent::Text(format!("<user-message>\n{input}\n</user-message>")),
            timestamp: now_ms(),
        }],
        tools: Vec::new(),
        thinking: ThinkingLevel::Off,
        session_id: format!("{session_id}-title"),
        signal,
        tool_choice: None,
    };
    let stream = agent.stream_function();
    let mut ignore = |_: &pirc_protocol::AssistantDelta| {};
    let reply = stream.stream(request, &mut ignore).await;
    if matches!(reply.stop_reason, StopReason::Error | StopReason::Aborted) {
        return None;
    }
    parse_title(&reply_text(&reply.content))
}

/// `titleFeature()`.
pub fn feature() -> Rc<dyn Feature> {
    Rc::new(TitleFeature::default())
}

#[derive(Default)]
struct TitleFeature {
    state: Rc<TitleState>,
}

#[derive(Default)]
struct TitleState {
    attempts: Cell<u64>,
    /// The request in flight, with a number telling attempts apart.
    inflight: RefCell<Option<(u64, AbortController)>>,
    next: Cell<u64>,
}

/// A non-model fallback, bounded like generated titles. It uses the original
/// meaningful message, never a later "why is this not named?" follow-up.
fn fallback_title(text: &str) -> Option<String> {
    let line = text.lines().map(str::trim).find(|line| !line.is_empty())?;
    let compact = line.split_whitespace().collect::<Vec<_>>().join(" ");
    if compact.is_empty() {
        return None;
    }
    let prefix: String = compact.chars().take(60).collect();
    Some(if prefix.len() < compact.len() {
        format!("{prefix}…")
    } else {
        prefix
    })
}

/// Retry independently of the chat run; cancellation and a human rename win.
async fn attempt(state: Rc<TitleState>, agent: Rc<Agent>, text: String) {
    let controller = AbortController::new();
    let id = state.next.get();
    state.next.set(id + 1);
    *state.inflight.borrow_mut() = Some((id, controller.clone()));
    // `AbortSignal.any([controller.signal, AbortSignal.timeout(TIMEOUT_MS)])`.
    let combined = AbortController::child_of(&controller.signal());
    let max_attempts = title_settings(&agent).max_attempts;
    let mut title = None;
    while state.attempts.get() < max_attempts
        && !controller.signal().aborted()
        && agent.session_name().is_none()
    {
        state.attempts.set(state.attempts.get() + 1);
        let request = AbortController::child_of(&combined.signal());
        title = tokio::select! {
            title = generate_title(&agent, &text, request.signal()) => title,
            () = tokio::time::sleep(Duration::from_millis(TIMEOUT_MS)) => {
                request.abort();
                None
            }
        };
        if title.is_some() || controller.signal().aborted() {
            break;
        }
        if state.attempts.get() < max_attempts {
            tokio::time::sleep(Duration::from_millis(500)).await;
        }
    }
    let title = title.or_else(|| fallback_title(&text));
    // A user rename while the request was in flight wins.
    if let Some(title) = title
        && !controller.signal().aborted()
        && agent.session_name().is_none()
    {
        let _ = agent.set_name(&title, NameSource::Auto);
    }
    let mine = state
        .inflight
        .borrow()
        .as_ref()
        .is_some_and(|(current, _)| *current == id);
    if mine {
        *state.inflight.borrow_mut() = None;
    }
}

impl Feature for TitleFeature {
    fn name(&self) -> &'static str {
        "session-title"
    }

    fn user_input(&self, agent: &Rc<Agent>, text: &str) {
        // Team sub-agents run headless and are never shown in the session list.
        if !agent.has_ui()
            || agent.session_name().is_some()
            || self.state.inflight.borrow().is_some()
        {
            return;
        }
        let settings = title_settings(agent);
        if !settings.enabled || self.state.attempts.get() >= settings.max_attempts {
            return;
        }
        if is_low_signal_title_input(text) {
            return;
        }
        crate::spawn_eager(attempt(self.state.clone(), agent.clone(), text.to_owned()));
    }

    fn shutdown<'a>(&'a self, _agent: &'a Rc<Agent>) -> LocalBoxFuture<'a, ()> {
        Box::pin(async move {
            let inflight = self.state.inflight.borrow().clone();
            if let Some((_, controller)) = inflight {
                controller.abort();
            }
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn fallback_uses_the_first_line_and_bounds_unicode_without_markup_parsing() {
        assert_eq!(
            fallback_title("  Fix   the compiler\nprivate context"),
            Some("Fix the compiler".into())
        );
        assert_eq!(
            fallback_title("<title>user text</title>"),
            Some("<title>user text</title>".into())
        );
        assert_eq!(fallback_title(" \n "), None);
        assert_eq!(
            fallback_title(&"中".repeat(80)).unwrap(),
            format!("{}…", "中".repeat(60))
        );
    }

    #[test]
    fn extracts_and_cleans_the_tagged_title() {
        let parse = |raw: &str| parse_title(raw);
        assert_eq!(
            parse("<title>Fix login button</title>").as_deref(),
            Some("Fix login button")
        );
        assert_eq!(
            parse("<think>scratch</think>\n<title> \"Fix login button.\" </title>").as_deref(),
            Some("Fix login button")
        );
        assert_eq!(
            parse("```json\n{\"title\": \"Debug failing CI\"}\n```").as_deref(),
            Some("Debug failing CI")
        );
        assert_eq!(
            parse("{\"title\": \"Truncated JSON").as_deref(),
            Some("Truncated JSON")
        );
        assert_eq!(
            parse("Title: 修正登入按鈕").as_deref(),
            Some("修正登入按鈕")
        );
        assert_eq!(parse("<title>none</title>"), None);
        assert_eq!(parse("<title/>"), None);
        assert_eq!(parse("   "), None);
        let long = parse(&format!("<title>{}</title>", "word ".repeat(40))).unwrap();
        assert!(js::len16(&long) <= 81);
        assert!(long.ends_with('…'));
        assert_eq!(long, format!("{}…", ["word"; 16].join(" ")));
        // More cases, as TS gives them.
        assert_eq!(
            parse("<THINKING>a</thinking><title>One</title><title>Two").as_deref(),
            Some("Two")
        );
        assert_eq!(
            parse("```reasoning\nhm\n```\nRename the API!!").as_deref(),
            Some("Rename the API")
        );
        assert_eq!(
            parse("{\"title\": \"Tab\\tescaped\"}").as_deref(),
            Some("Tab escaped")
        );
        // Quotes go before punctuation, so a quote before it stays.
        assert_eq!(parse("「重構 runner」。").as_deref(), Some("重構 runner」"));
        assert_eq!(parse("N/A").as_deref(), None);
        let unbroken = parse(&"x".repeat(100)).unwrap();
        assert_eq!(unbroken, format!("{}…", "x".repeat(80)));
    }

    #[test]
    fn skips_greetings_and_filler() {
        for text in [
            "hi",
            "Hello!",
            "thanks.",
            "42",
            "👍🎉",
            "你好",
            "謝謝！",
            "  ok  ",
            "",
            "  ...  ",
        ] {
            assert!(is_low_signal_title_input(text), "{text:?}");
        }
        for text in [
            "fix the login bug",
            "幫我重構 runner",
            "hi, can you add tests?",
            "42 apples",
        ] {
            assert!(!is_low_signal_title_input(text), "{text:?}");
        }
    }

    #[test]
    fn falls_back_to_default_settings_when_invalid() {
        assert_eq!(TitleSettings::parse(None), Some(TitleSettings::default()));
        assert_eq!(TitleSettings::parse(Some(&json!("x"))), None);
        assert_eq!(
            TitleSettings::parse(Some(&json!({ "maxAttempts": 0 }))),
            None
        );
        assert_eq!(
            TitleSettings::parse(Some(&json!({ "maxAttempts": 11 }))),
            None
        );
        assert_eq!(
            TitleSettings::parse(Some(&json!({ "maxAttempts": 1.5 }))),
            None
        );
        assert_eq!(
            TitleSettings::parse(Some(&json!({ "enabled": "yes" }))),
            None
        );
        assert_eq!(
            TitleSettings::parse(Some(&json!({ "model": { "provider": "p" } }))),
            None
        );
        assert_eq!(
            TitleSettings::parse(Some(&json!({ "enabled": false, "maxAttempts": 2.0,
                "model": { "provider": "p", "id": "m", "extra": 1 }, "prompt": "x", "other": 1 }))),
            Some(TitleSettings {
                enabled: false,
                model: Some(("p".to_owned(), "m".to_owned())),
                prompt: Some("x".to_owned()),
                max_attempts: 2,
            })
        );
    }
}
