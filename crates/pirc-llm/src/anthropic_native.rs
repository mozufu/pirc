//! The gateway's native Anthropic Messages transport for plain
//! `anthropic-messages` providers (`agent/providers/anthropic.ts`): no
//! `piProvider` and no model-level `api`.

use crate::outcome::{ErrorKind, LlmError};
use crate::runtime::{ResolvedModel, RunRequest as StreamRequest};
use pirc_llm_types::{
    AssistantContent, AssistantDelta, AssistantMessage, Message, StopReason, ThinkingLevel,
    ToolChoice, UserBlock, UserContent,
};
use reqwest::header::{HeaderMap, HeaderName, HeaderValue};
use serde_json::{Map, Value, json};

use crate::http::opencode_headers;
use crate::js::{self, get, present, truthy};
use crate::native::parse_tool_arguments;
use crate::sse::NativeDecoder;
use crate::stream::{Cancelled, Emitter, assistant, content_index};

/// `{ ...provider.compat, ...model.compat }`.
#[derive(Clone, Copy)]
struct Compat {
    adaptive_thinking: bool,
}

impl Compat {
    fn resolve(request: &StreamRequest<'_>) -> Self {
        let flags = &request.endpoint.compat;
        Self {
            adaptive_thinking: truthy(flags.get("forceAdaptiveThinking")),
        }
    }
}

fn ephemeral() -> Value {
    json!({ "type": "ephemeral" })
}

/// `image()`.
fn image(mime_type: &str, data: &str) -> Value {
    json!({ "type": "image", "source": { "type": "base64", "media_type": mime_type, "data": data } })
}

fn user_blocks(blocks: &[UserBlock]) -> Vec<Value> {
    blocks
        .iter()
        .map(|block| match block {
            UserBlock::Text { text, .. } => json!({ "type": "text", "text": text }),
            UserBlock::Image { data, mime_type } => image(mime_type, data),
        })
        .collect()
}

/// `toAnthropicMessages`: roles must alternate, so consecutive same-role
/// messages are merged; the last user turn gets a cache breakpoint.
fn to_anthropic_messages(messages: &[Message]) -> Vec<Value> {
    let mut out: Vec<(&'static str, Vec<Value>)> = Vec::new();
    let mut push = |role: &'static str, blocks: Vec<Value>| {
        if blocks.is_empty() {
            return;
        }
        match out.last_mut() {
            Some((last, content)) if *last == role => content.extend(blocks),
            _ => out.push((role, blocks)),
        }
    };
    for message in messages {
        match message {
            Message::User { content, .. } => push(
                "user",
                match content {
                    UserContent::Text(text) => vec![json!({ "type": "text", "text": text })],
                    UserContent::Blocks(blocks) => user_blocks(blocks),
                },
            ),
            Message::Custom { content, .. } => {
                push("user", vec![json!({ "type": "text", "text": content })]);
            }
            Message::CompactionSummary { summary, .. } => push(
                "user",
                vec![json!({ "type": "text", "text": format!(
                    "<summary>\nThe conversation so far was compacted into this summary:\n\n{summary}\n</summary>"
                ) })],
            ),
            Message::Assistant(message) => {
                let failed = matches!(message.stop_reason, StopReason::Error | StopReason::Aborted);
                let mut blocks = Vec::new();
                for part in &message.content {
                    match part {
                        AssistantContent::Text { text, .. } if !text.is_empty() => {
                            blocks.push(json!({ "type": "text", "text": text }));
                        }
                        AssistantContent::Thinking {
                            thinking,
                            signature: Some(signature),
                            redacted,
                        } if !failed && !signature.is_empty() => {
                            blocks.push(if *redacted == Some(true) {
                                json!({ "type": "redacted_thinking", "data": signature })
                            } else {
                                json!({ "type": "thinking", "thinking": thinking, "signature": signature })
                            });
                        }
                        AssistantContent::ToolCall {
                            id,
                            name,
                            arguments,
                            ..
                        } if !failed => blocks.push(
                            json!({ "type": "tool_use", "id": id, "name": name, "input": arguments }),
                        ),
                        _ => {}
                    }
                }
                push("assistant", blocks);
            }
            Message::ToolResult {
                tool_call_id,
                content,
                is_error,
                ..
            } => {
                let content = if content.is_empty() {
                    vec![json!({ "type": "text", "text": "(no output)" })]
                } else {
                    user_blocks(content)
                };
                push(
                    "user",
                    vec![json!({ "type": "tool_result", "tool_use_id": tool_call_id,
                        "is_error": is_error, "content": content })],
                );
            }
        }
    }
    // Cache breakpoint on the last user turn so the growing prefix is reused.
    if let Some((_, content)) = out.iter_mut().rev().find(|(role, _)| *role == "user")
        && let Some(Value::Object(block)) = content.last_mut()
    {
        block.insert("cache_control".to_owned(), ephemeral());
    }
    out.into_iter()
        .map(|(role, content)| json!({ "role": role, "content": content }))
        .collect()
}

/// `budgets` (`?? 10_000` never applies: every level is listed).
fn budget(level: ThinkingLevel) -> i128 {
    match level {
        ThinkingLevel::Minimal => 1024,
        ThinkingLevel::Low => 4096,
        ThinkingLevel::Off | ThinkingLevel::Medium => 10_000,
        ThinkingLevel::High => 24_000,
        ThinkingLevel::Xhigh => 48_000,
        ThinkingLevel::Max => 64_000,
    }
}

/// `efforts`: the model's mapping for the effective level, else the level's
/// provider default.
fn effort(model: &ResolvedModel, level: ThinkingLevel) -> Value {
    // Before `max` was its own level, `xhigh` was the only way to ask an
    // Anthropic model without a map for its maximum effort.
    if level == ThinkingLevel::Xhigh && model.thinking_level_map.is_none() {
        return json!("max");
    }
    let Some(level) = model.effective_thinking_level(level) else {
        return Value::Null;
    };
    if let Some(mapped) = model
        .thinking_level_map
        .as_ref()
        .and_then(|map| map.get(level.as_str()))
        .and_then(Option::as_deref)
    {
        return json!(mapped);
    }
    match level {
        ThinkingLevel::Minimal | ThinkingLevel::Low => json!("low"),
        ThinkingLevel::Medium => json!("medium"),
        ThinkingLevel::High | ThinkingLevel::Xhigh => json!("high"),
        ThinkingLevel::Max => json!("max"),
        // `efforts.off` is undefined, and `thinking: off` never gets here.
        ThinkingLevel::Off => Value::Null,
    }
}

/// `anthropicBody`.
fn anthropic_body(request: &StreamRequest<'_>) -> Map<String, Value> {
    let flags = Compat::resolve(request);
    let max_tokens = request
        .options
        .max_tokens
        .unwrap_or(request.model.max_tokens);
    let mut body = Map::new();
    body.insert("model".to_owned(), json!(request.model.id));
    body.insert("max_tokens".to_owned(), json!(max_tokens));
    body.insert("stream".to_owned(), json!(true));
    body.insert(
        "messages".to_owned(),
        Value::Array(to_anthropic_messages(request.context.messages)),
    );
    if !request.context.system_prompt.is_empty() {
        body.insert(
            "system".to_owned(),
            json!([{ "type": "text", "text": request.context.system_prompt, "cache_control": ephemeral() }]),
        );
    }
    if !request.context.tools.is_empty() {
        let mut tools: Vec<Value> = request
            .context
            .tools
            .iter()
            .map(|tool| {
                json!({ "name": tool.name, "description": tool.description,
                    "input_schema": tool.parameters })
            })
            .collect();
        if let Some(Value::Object(last)) = tools.last_mut() {
            last.insert("cache_control".to_owned(), ephemeral());
        }
        body.insert("tools".to_owned(), Value::Array(tools));
        if request.options.tool_choice == Some(ToolChoice::None) {
            body.insert("tool_choice".to_owned(), json!({ "type": "none" }));
        }
    }
    if request.model.reasoning && request.options.thinking != ThinkingLevel::Off {
        if flags.adaptive_thinking {
            body.insert("thinking".to_owned(), json!({ "type": "adaptive" }));
            body.insert(
                "output_config".to_owned(),
                json!({ "effort": effort(request.model, request.options.thinking) }),
            );
        } else {
            let budget =
                budget(request.options.thinking).min((i128::from(max_tokens) - 1).max(1024));
            body.insert(
                "thinking".to_owned(),
                json!({ "type": "enabled", "budget_tokens": budget }),
            );
        }
    }
    body
}

/// The headers object of the TS code (exact keys, a later key replaces an
/// earlier one) as `fetch` sends it: names are case-insensitive, so
/// differently cased duplicates are joined with ", ", and values lose
/// leading and trailing HTTP white space.
#[derive(Default)]
struct HeaderObject(Vec<(String, String)>);

impl HeaderObject {
    fn set(&mut self, name: &str, value: &str) {
        match self.0.iter_mut().find(|(existing, _)| existing == name) {
            Some(entry) => entry.1 = value.to_owned(),
            None => self.0.push((name.to_owned(), value.to_owned())),
        }
    }

    /// `None` when a name or value is not valid HTTP (fetch throws then).
    fn to_map(&self) -> Option<HeaderMap> {
        let mut combined: Vec<(String, String)> = Vec::new();
        for (name, value) in &self.0 {
            let name = name.to_ascii_lowercase();
            let value = value.trim_matches([' ', '\t', '\n', '\r']);
            match combined.iter_mut().find(|(existing, _)| *existing == name) {
                Some(entry) => {
                    entry.1.push_str(", ");
                    entry.1.push_str(value);
                }
                None => combined.push((name, value.to_owned())),
            }
        }
        let mut map = HeaderMap::with_capacity(combined.len());
        for (name, value) in combined {
            let name = HeaderName::from_bytes(name.as_bytes()).ok()?;
            map.insert(name, HeaderValue::from_str(&value).ok()?);
        }
        Some(map)
    }
}

/// `httpError`: the status and the first 2000 UTF-16 units of the body.
fn http_error(status: reqwest::StatusCode, body: &[u8]) -> String {
    let text = String::from_utf8_lossy(body);
    let mut units = 0;
    let text: String = text
        .chars()
        .take_while(|c| {
            units += c.len_utf16();
            units <= 2000
        })
        .collect();
    let text = if text.is_empty() {
        status.canonical_reason().unwrap_or("").to_owned()
    } else {
        text
    };
    format!("HTTP {}: {text}", status.as_u16())
}

/// A delta field appended to text: nothing when absent.
fn concat(value: Option<&Value>) -> String {
    value.map_or_else(String::new, js::to_js_string)
}

/// Map keys compare by SameValueZero; a freshly parsed object never
/// matches. `None` is `undefined` (no `index` field).
fn same_key(a: Option<&Value>, b: Option<&Value>) -> bool {
    match (a, b) {
        (None, None) => true,
        (Some(Value::Number(a)), Some(Value::Number(b))) => a.as_f64() == b.as_f64(),
        (Some(Value::Array(_) | Value::Object(_)), _)
        | (_, Some(Value::Array(_) | Value::Object(_))) => false,
        (Some(a), Some(b)) => a == b,
        _ => false,
    }
}

/// A block's type and lifecycle are fixed by its start event, not its deltas.
#[derive(Debug)]
enum BlockState {
    Text {
        content_index: usize,
    },
    Thinking {
        content_index: usize,
    },
    Tool {
        content_index: usize,
        raw: String,
        finished: bool,
    },
}

impl BlockState {
    fn content_index(&self) -> usize {
        match self {
            Self::Text { content_index }
            | Self::Thinking { content_index }
            | Self::Tool { content_index, .. } => *content_index,
        }
    }
}

/// An Anthropic content block, keyed with JavaScript Map semantics.
struct Block {
    key: Option<Value>,
    state: BlockState,
}

pub struct NativeAnthropicRun {
    message: AssistantMessage,
    /// The `blocks` map, in insertion order.
    blocks: Vec<Block>,
}

impl NativeAnthropicRun {
    pub fn new(request: &StreamRequest<'_>) -> Self {
        Self {
            message: assistant(
                "anthropic-messages",
                request.provider_name,
                &request.model.id,
                StopReason::Stop,
            ),
            blocks: Vec::new(),
        }
    }

    fn fix_total(mut message: AssistantMessage) -> AssistantMessage {
        let usage = &mut message.usage;
        usage.total_tokens = usage
            .input
            .saturating_add(usage.output)
            .saturating_add(usage.cache_read)
            .saturating_add(usage.cache_write);
        message
    }

    /// The `catch` path: tool calls whose block never stopped are dropped.
    fn drop_unfinished(&self, message: &mut AssistantMessage) {
        let unfinished: Vec<usize> = self
            .blocks
            .iter()
            .filter_map(|block| match block.state {
                BlockState::Tool {
                    content_index,
                    finished: false,
                    ..
                } => Some(content_index),
                _ => None,
            })
            .collect();
        let mut index = 0;
        message.content.retain(|part| {
            let keep =
                !(matches!(part, AssistantContent::ToolCall { .. }) && unfinished.contains(&index));
            index += 1;
            keep
        });
    }

    /// The `catch` path for an aborted request.
    pub fn aborted(&self) -> AssistantMessage {
        let mut message = self.message.clone();
        self.drop_unfinished(&mut message);
        message.stop_reason = StopReason::Aborted;
        Self::fix_total(message)
    }

    pub async fn run(
        &mut self,
        client: &reqwest::Client,
        request: &StreamRequest<'_>,
        emit: &mut Emitter<'_>,
    ) -> Result<AssistantMessage, Cancelled> {
        match self.stream(client, request, emit).await {
            Ok(()) => Ok(Self::fix_total(self.message.clone())),
            Err(Failure::Cancelled) => Err(Cancelled),
            Err(Failure::Upstream(error)) => {
                emit.record_error(LlmError::diagnostic(ErrorKind::Protocol, error.clone()));
                if emit.cancelled() {
                    return Err(Cancelled);
                }
                let mut message = self.message.clone();
                self.drop_unfinished(&mut message);
                message.stop_reason = StopReason::Error;
                message.error_message = Some(error);
                self.message = message;
                Ok(Self::fix_total(self.message.clone()))
            }
        }
    }

    async fn stream(
        &mut self,
        client: &reqwest::Client,
        request: &StreamRequest<'_>,
        emit: &mut Emitter<'_>,
    ) -> Result<(), Failure> {
        let base = request.endpoint.base_url.as_str();
        let url = format!("{}/v1/messages", base.strip_suffix('/').unwrap_or(base));
        let mut headers = HeaderObject::default();
        headers.set("content-type", "application/json");
        headers.set("accept", "text/event-stream");
        headers.set("anthropic-version", "2023-06-01");
        for (name, value) in &request.endpoint.headers {
            headers.set(name, value);
        }
        let model_url = &request.endpoint.opencode_base_url;
        let opencode = opencode_headers(
            request.endpoint.opencode_go,
            model_url,
            request.options.session_id,
        )
        .map_err(|()| {
            emit.record_error(LlmError::new(ErrorKind::InvalidRequest));
            Failure::upstream("Invalid URL")
        })?;
        for (name, value) in opencode {
            headers.set(name, &value);
        }
        if let Some(key) = request.auth.as_key().filter(|key| !key.is_empty()) {
            headers.set("x-api-key", key);
        }
        let header_map = headers.to_map().ok_or_else(|| {
            emit.record_error(LlmError::new(ErrorKind::InvalidRequest));
            Failure::upstream("Invalid header")
        })?;
        let body = serde_json::to_vec(&anthropic_body(request)).unwrap_or_default();
        let mut response = client
            .post(&url)
            .headers(header_map)
            .body(body)
            .send()
            .await
            .map_err(|error| {
                emit.record_error(LlmError::from_reqwest(&error));
                Failure::upstream(if error.is_connect() {
                    "Unable to connect. Is the computer able to access the url?"
                } else {
                    "The socket connection was closed unexpectedly."
                })
            })?;
        let status = response.status();
        if !status.is_success() {
            let body = response.bytes().await.unwrap_or_default();
            emit.record_error(LlmError::http(
                status.as_u16(),
                String::from_utf8_lossy(&body).into_owned(),
            ));
            return Err(Failure::Upstream(http_error(status, &body)));
        }
        let mut decoder = NativeDecoder::default();
        let mut stop: Option<Value> = None;
        loop {
            let (events, ended) = match response.chunk().await {
                Ok(Some(bytes)) => (decoder.push(&bytes), false),
                Ok(None) => (decoder.finish().into_iter().collect(), true),
                Err(error) => {
                    emit.record_error(LlmError::from_reqwest(&error));
                    return Err(Failure::upstream(
                        "The socket connection was closed unexpectedly.",
                    ));
                }
            };
            for event in events {
                self.event(&event.data, &mut stop, emit)?;
            }
            if ended {
                break;
            }
        }
        self.message.stop_reason = match stop.as_ref().and_then(Value::as_str) {
            Some("tool_use") => StopReason::ToolUse,
            Some("max_tokens") => StopReason::Length,
            _ => StopReason::Stop,
        };
        Ok(())
    }

    fn block(&self, key: Option<&Value>) -> Option<usize> {
        self.blocks
            .iter()
            .position(|block| same_key(block.key.as_ref(), key))
    }

    /// `blocks.set`: an existing key keeps its place.
    fn set_block(&mut self, key: Option<&Value>, state: BlockState) {
        let block = Block {
            key: key.cloned(),
            state,
        };
        match self.block(key) {
            Some(position) => self.blocks[position] = block,
            None => self.blocks.push(block),
        }
    }

    fn event(
        &mut self,
        data: &str,
        stop: &mut Option<Value>,
        emit: &mut Emitter<'_>,
    ) -> Result<(), Failure> {
        let event: Value = crate::json_parse::parse_event(data)
            .map_err(|_| Failure::upstream("JSON Parse error: Unable to parse JSON string"))?;
        if event.is_null() {
            return Err(Failure::upstream(
                "null is not an object (evaluating 'event.type')",
            ));
        }
        let event = Some(&event);
        match get(event, "type").and_then(Value::as_str) {
            Some("message_start") => {
                let usage = present(get(get(event, "message"), "usage"));
                let number = |key: &str| {
                    present(get(usage, key))
                        .and_then(Value::as_f64)
                        .map_or(0, js::to_u64)
                };
                let usage_out = &mut self.message.usage;
                usage_out.input = number("input_tokens");
                usage_out.cache_read = number("cache_read_input_tokens");
                usage_out.cache_write = number("cache_creation_input_tokens");
                usage_out.output = number("output_tokens");
            }
            Some("content_block_start") => self.block_start(event, emit)?,
            Some("content_block_delta") => self.block_delta(event, emit)?,
            Some("content_block_stop") => self.block_stop(event, emit)?,
            Some("message_delta") => {
                if let Some(reason) = get(get(event, "delta"), "stop_reason")
                    && truthy(Some(reason))
                {
                    *stop = Some(reason.clone());
                }
                let output = get(get(event, "usage"), "output_tokens");
                if truthy(output)
                    && let Some(output) = output.and_then(Value::as_f64)
                {
                    self.message.usage.output = js::to_u64(output);
                }
            }
            Some("error") => {
                let error = get(event, "error");
                let message = match present(get(error, "message")) {
                    Some(message) => js::to_js_string(message),
                    // `JSON.stringify(undefined)` makes `new Error(undefined)`.
                    None => error.map(Value::to_string).unwrap_or_default(),
                };
                emit.record_error(LlmError::upstream(message.clone()));
                return Err(Failure::Upstream(message));
            }
            _ => {}
        }
        Ok(())
    }

    fn block_start(
        &mut self,
        event: Option<&Value>,
        emit: &mut Emitter<'_>,
    ) -> Result<(), Failure> {
        let block = present(get(event, "content_block"));
        let key = get(event, "index");
        let index = self.message.content.len();
        let (part, state) = match get(block, "type").and_then(Value::as_str) {
            Some("text") => (
                AssistantContent::Text {
                    text: String::new(),
                    text_signature: None,
                },
                BlockState::Text {
                    content_index: index,
                },
            ),
            Some(kind @ ("thinking" | "redacted_thinking")) => {
                let redacted = kind == "redacted_thinking";
                (
                    AssistantContent::Thinking {
                        thinking: String::new(),
                        signature: if redacted {
                            present(get(block, "data")).map(js::to_js_string)
                        } else {
                            None
                        },
                        redacted: redacted.then_some(true),
                    },
                    BlockState::Thinking {
                        content_index: index,
                    },
                )
            }
            Some("tool_use") => {
                let text = |key| {
                    present(get(block, key))
                        .map(js::to_js_string)
                        .unwrap_or_default()
                };
                (
                    AssistantContent::ToolCall {
                        id: text("id"),
                        name: text("name"),
                        arguments: Map::new(),
                        thought_signature: None,
                    },
                    BlockState::Tool {
                        content_index: index,
                        raw: String::new(),
                        finished: false,
                    },
                )
            }
            _ => return Ok(()),
        };
        let delta = match &part {
            AssistantContent::Text { .. } => AssistantDelta::TextStart {
                content_index: content_index(self.message.content.len()),
            },
            AssistantContent::Thinking { .. } => AssistantDelta::ThinkingStart {
                content_index: content_index(self.message.content.len()),
            },
            AssistantContent::ToolCall { id, name, .. } => AssistantDelta::ToolcallStart {
                content_index: content_index(self.message.content.len()),
                id: id.clone(),
                tool_name: name.clone(),
            },
        };
        self.message.content.push(part);
        self.set_block(key, state);
        emit.emit(delta, &self.message)?;
        Ok(())
    }

    fn block_delta(
        &mut self,
        event: Option<&Value>,
        emit: &mut Emitter<'_>,
    ) -> Result<(), Failure> {
        let Some(position) = self.block(get(event, "index")) else {
            return Ok(());
        };
        let delta = present(get(event, "delta"));
        let index = self.blocks[position].state.content_index();
        let part = &mut self.message.content[index];
        let delta = match get(delta, "type").and_then(Value::as_str) {
            Some("text_delta") => {
                let piece = concat(get(delta, "text"));
                if let AssistantContent::Text { text, .. } = part {
                    text.push_str(&piece);
                }
                AssistantDelta::TextDelta {
                    content_index: content_index(index),
                    delta: piece,
                }
            }
            Some("thinking_delta") => {
                let piece = concat(get(delta, "thinking"));
                if let AssistantContent::Thinking { thinking, .. } = part {
                    thinking.push_str(&piece);
                }
                AssistantDelta::ThinkingDelta {
                    content_index: content_index(index),
                    delta: piece,
                }
            }
            Some("signature_delta") => {
                if let AssistantContent::Thinking { signature, .. } = part {
                    let mut joined = signature.take().unwrap_or_default();
                    joined.push_str(&concat(get(delta, "signature")));
                    *signature = Some(joined);
                }
                return Ok(());
            }
            Some("input_json_delta") => {
                let piece = concat(get(delta, "partial_json"));
                // The legacy reducer emits cross-type deltas too. Non-tool raw
                // JSON is never consumed, so only tool states need retain it.
                if let BlockState::Tool { raw, .. } = &mut self.blocks[position].state {
                    raw.push_str(&piece);
                }
                AssistantDelta::ToolcallDelta {
                    content_index: content_index(index),
                    delta: piece,
                }
            }
            _ => return Ok(()),
        };
        emit.emit(delta, &self.message)?;
        Ok(())
    }

    fn block_stop(&mut self, event: Option<&Value>, emit: &mut Emitter<'_>) -> Result<(), Failure> {
        let Some(position) = self.block(get(event, "index")) else {
            return Ok(());
        };
        let block = &mut self.blocks[position];
        let index = block.state.content_index();
        let delta = match &mut block.state {
            BlockState::Text { .. } => AssistantDelta::TextEnd {
                content_index: content_index(index),
                content: match &self.message.content[index] {
                    AssistantContent::Text { text, .. } => text.clone(),
                    _ => String::new(),
                },
            },
            BlockState::Thinking { .. } => AssistantDelta::ThinkingEnd {
                content_index: content_index(index),
                content: match &self.message.content[index] {
                    AssistantContent::Thinking { thinking, .. } => thinking.clone(),
                    _ => String::new(),
                },
            },
            BlockState::Tool { raw, finished, .. } => {
                let parsed = parse_tool_arguments(raw);
                // Finish before emission: cancellation by the end callback must
                // retain the tool. Keep raw for repeated stops/post-stop deltas.
                *finished = true;
                let part = &mut self.message.content[index];
                if let AssistantContent::ToolCall { arguments, .. } = part {
                    *arguments = parsed;
                }
                AssistantDelta::ToolcallEnd {
                    content_index: content_index(index),
                    tool_call: part.clone(),
                }
            }
        };
        emit.emit(delta, &self.message)?;
        Ok(())
    }
}

enum Failure {
    Cancelled,
    Upstream(String),
}

impl Failure {
    fn upstream(text: &str) -> Self {
        Self::Upstream(text.to_owned())
    }
}

impl From<Cancelled> for Failure {
    fn from(Cancelled: Cancelled) -> Self {
        Self::Cancelled
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::runtime::{ResolvedEndpoint, ResolvedModel};
    use pirc_llm_types::ModelApi;
    use tokio::sync::watch;

    struct RuntimeFixture {
        endpoint: ResolvedEndpoint,
        model: ResolvedModel,
    }

    impl RuntimeFixture {
        fn new() -> Self {
            Self {
                endpoint: ResolvedEndpoint::new(
                    ModelApi::AnthropicMessages,
                    "anthropic",
                    "https://example.invalid",
                ),
                model: ResolvedModel::new("test", 8192),
            }
        }

        fn request(&self) -> StreamRequest<'_> {
            StreamRequest::new("anthropic", &self.endpoint, &self.model)
        }
    }

    fn events(run: &mut NativeAnthropicRun, events: &[Value]) -> Vec<AssistantDelta> {
        let (_tx, cancel) = watch::channel(0);
        let mut deltas = Vec::new();
        let mut callback =
            |delta: &AssistantDelta, _: &AssistantMessage| deltas.push(delta.clone());
        let mut emit = Emitter {
            cancel,
            error: None,
            on_delta: &mut callback,
        };
        let mut stop = None;
        for event in events {
            assert!(run.event(&event.to_string(), &mut stop, &mut emit).is_ok());
        }
        deltas
    }

    #[test]
    fn adaptive_compat_preserves_javascript_truthiness() {
        let mut fixture = RuntimeFixture::new();
        fixture.model.reasoning = true;
        for (flag, adaptive) in [
            (None, false),
            (Some(json!(null)), false),
            (Some(json!(false)), false),
            (Some(json!(0)), false),
            (Some(json!("")), false),
            (Some(json!(true)), true),
            (Some(json!(-1)), true),
            (Some(json!("false")), true),
            (Some(json!([])), true),
            (Some(json!({})), true),
        ] {
            fixture.endpoint.compat.clear();
            if let Some(flag) = flag {
                fixture
                    .endpoint
                    .compat
                    .insert("forceAdaptiveThinking".to_owned(), flag);
            }
            let mut request = fixture.request();
            request.options.thinking = ThinkingLevel::High;
            assert_eq!(Compat::resolve(&request).adaptive_thinking, adaptive);
            let body = anthropic_body(&request);
            assert_eq!(
                body["thinking"]["type"],
                if adaptive { "adaptive" } else { "enabled" }
            );
            assert_eq!(body.contains_key("output_config"), adaptive);
            if adaptive {
                assert_eq!(body["output_config"], json!({"effort": "high"}));
            } else {
                assert_eq!(body["thinking"]["budget_tokens"], 8191);
            }
            request.options.thinking = ThinkingLevel::Off;
            assert!(!anthropic_body(&request).contains_key("thinking"));
        }
    }

    #[test]
    fn maps_xhigh_and_max_to_the_models_efforts() {
        let map = |entries: &[(&str, Option<&str>)]| -> indexmap::IndexMap<String, Option<String>> {
            entries
                .iter()
                .map(|(level, effort)| ((*level).to_owned(), effort.map(str::to_owned)))
                .collect()
        };
        let effort = |levels: Option<indexmap::IndexMap<String, Option<String>>>,
                      level: ThinkingLevel| {
            let mut fixture = RuntimeFixture::new();
            fixture.model.reasoning = true;
            fixture.model.thinking_level_map = levels;
            fixture
                .endpoint
                .compat
                .insert("forceAdaptiveThinking".to_owned(), json!(true));
            let mut request = fixture.request();
            request.options.thinking = level;
            anthropic_body(&request)["output_config"]["effort"].clone()
        };
        let both = || map(&[("xhigh", Some("xhigh")), ("max", Some("max"))]);
        assert_eq!(effort(Some(both()), ThinkingLevel::Xhigh), json!("xhigh"));
        assert_eq!(effort(Some(both()), ThinkingLevel::Max), json!("max"));
        let max_only = || map(&[("max", Some("max"))]);
        assert_eq!(effort(Some(max_only()), ThinkingLevel::Xhigh), json!("max"));
        assert_eq!(effort(Some(max_only()), ThinkingLevel::Max), json!("max"));
        let neither = || map(&[("xhigh", None), ("max", None)]);
        assert_eq!(effort(Some(neither()), ThinkingLevel::Xhigh), json!("high"));
        assert_eq!(effort(Some(neither()), ThinkingLevel::Max), json!("high"));
        // Before `max`, `xhigh` was the only way to ask an unmapped model
        // for its maximum effort.
        assert_eq!(effort(None, ThinkingLevel::Xhigh), json!("max"));
    }

    #[test]
    fn malformed_cross_type_deltas_emit_without_retyping_blocks() {
        let fixture = RuntimeFixture::new();
        let mut run = NativeAnthropicRun::new(&fixture.request());
        let deltas = events(
            &mut run,
            &[
                json!({"type":"content_block_start","index":0,"content_block":{"type":"text"}}),
                json!({"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"ignored"}}),
                json!({"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{}"}}),
                json!({"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"ignored"}}),
                json!({"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"text"}}),
                json!({"type":"content_block_stop","index":0}),
                json!({"type":"content_block_start","index":1,"content_block":{"type":"thinking"}}),
                json!({"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"ignored"}}),
                json!({"type":"content_block_delta","index":1,"delta":{"type":"thinking_delta","thinking":"thought"}}),
                json!({"type":"content_block_delta","index":1,"delta":{"type":"signature_delta","signature":"sig"}}),
                json!({"type":"content_block_stop","index":1}),
            ],
        );
        assert!(
            matches!(&deltas[1], AssistantDelta::ThinkingDelta { content_index: 0, delta } if delta == "ignored")
        );
        assert!(
            matches!(&deltas[2], AssistantDelta::ToolcallDelta { content_index: 0, delta } if delta == "{}")
        );
        assert!(
            matches!(&deltas[4], AssistantDelta::TextEnd { content_index: 0, content } if content == "text")
        );
        assert!(
            matches!(&deltas[6], AssistantDelta::TextDelta { content_index: 1, delta } if delta == "ignored")
        );
        assert!(
            matches!(&deltas[8], AssistantDelta::ThinkingEnd { content_index: 1, content } if content == "thought")
        );
        assert!(
            matches!(&run.message.content[1], AssistantContent::Thinking { signature: Some(signature), .. } if signature == "sig")
        );
        assert!(matches!(
            run.blocks[0].state,
            BlockState::Text { content_index: 0 }
        ));
        assert!(matches!(
            run.blocks[1].state,
            BlockState::Thinking { content_index: 1 }
        ));
    }

    #[test]
    fn tool_state_retains_raw_after_stop_and_ignores_cross_type_mutation() {
        let fixture = RuntimeFixture::new();
        let mut run = NativeAnthropicRun::new(&fixture.request());
        let deltas = events(
            &mut run,
            &[
                json!({"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"id","name":"tool"}}),
                json!({"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ignored"}}),
                json!({"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"ignored"}}),
                json!({"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"a\":1"}}),
                json!({"type":"content_block_stop","index":0}),
                json!({"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":",\"b\":2}"}}),
                json!({"type":"content_block_stop","index":0}),
            ],
        );
        assert!(matches!(
            &deltas[1],
            AssistantDelta::TextDelta {
                content_index: 0,
                ..
            }
        ));
        assert!(matches!(
            &deltas[2],
            AssistantDelta::ThinkingDelta {
                content_index: 0,
                ..
            }
        ));
        assert!(
            matches!(&deltas[4], AssistantDelta::ToolcallEnd { tool_call: AssistantContent::ToolCall { arguments, .. }, .. } if arguments == json!({"__invalid_json":"{\"a\":1"}).as_object().unwrap())
        );
        assert!(
            matches!(&run.message.content[0], AssistantContent::ToolCall { arguments, .. } if arguments == json!({"a":1,"b":2}).as_object().unwrap())
        );
        assert!(
            matches!(&run.blocks[0].state, BlockState::Tool { finished: true, raw, .. } if raw == "{\"a\":1,\"b\":2}")
        );
        assert_eq!(run.aborted().content.len(), 1);
    }

    #[test]
    fn unfinished_cleanup_follows_current_map_entries_after_key_replacement() {
        let fixture = RuntimeFixture::new();
        let mut run = NativeAnthropicRun::new(&fixture.request());
        events(
            &mut run,
            &[
                json!({"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"orphaned"}}),
                json!({"type":"content_block_start","index":1.0,"content_block":{"type":"text"}}),
                json!({"type":"content_block_start","content_block":{"type":"tool_use","id":"unfinished"}}),
                json!({"type":"content_block_start","index":null,"content_block":{"type":"text"}}),
            ],
        );
        assert_eq!(run.blocks.len(), 3);
        assert!(matches!(
            run.blocks[0].state,
            BlockState::Text { content_index: 1 }
        ));
        let aborted = run.aborted();
        // Replacing the map key leaves the old tool in content, but no longer
        // tracks it as unfinished. This intentionally mirrors legacy cleanup.
        assert_eq!(aborted.content.len(), 3);
        assert!(
            matches!(&aborted.content[0], AssistantContent::ToolCall { id, .. } if id == "orphaned")
        );
        assert_eq!(aborted.stop_reason, StopReason::Aborted);
    }

    #[test]
    fn tool_end_is_finished_before_callback_cancels() {
        let fixture = RuntimeFixture::new();
        let mut run = NativeAnthropicRun::new(&fixture.request());
        events(
            &mut run,
            &[
                json!({"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"id","name":"tool"}}),
                json!({"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{}"}}),
            ],
        );
        assert!(run.aborted().content.is_empty());
        let (tx, cancel) = watch::channel(0);
        let mut callback = |delta: &AssistantDelta, _: &AssistantMessage| {
            assert!(matches!(delta, AssistantDelta::ToolcallEnd { .. }));
            tx.send(1).unwrap();
        };
        let mut emit = Emitter {
            cancel,
            error: None,
            on_delta: &mut callback,
        };
        let result = run.event(
            r#"{"type":"content_block_stop","index":0}"#,
            &mut None,
            &mut emit,
        );
        assert!(matches!(result, Err(Failure::Cancelled)));
        assert_eq!(run.aborted().content.len(), 1);
        assert!(matches!(
            run.blocks[0].state,
            BlockState::Tool { finished: true, .. }
        ));
    }

    #[test]
    fn map_keys_follow_same_value_zero() {
        assert!(same_key(None, None));
        assert!(same_key(Some(&json!(1)), Some(&json!(1.0))));
        assert!(!same_key(Some(&json!(1)), Some(&json!("1"))));
        assert!(!same_key(Some(&json!(null)), None));
        assert!(!same_key(Some(&json!([])), Some(&json!([]))));
    }

    #[test]
    fn headers_join_like_fetch() {
        let mut headers = HeaderObject::default();
        headers.set("accept", "a");
        headers.set("Accept", " b ");
        headers.set("accept", "c");
        let map = headers.to_map().unwrap();
        assert_eq!(map.get("accept").unwrap(), "c, b");
    }

    #[test]
    fn http_errors_cut_utf16_units() {
        let body = "é".repeat(2001);
        let text = http_error(reqwest::StatusCode::BAD_REQUEST, body.as_bytes());
        assert_eq!(text.chars().count(), "HTTP 400: ".len() + 2000);
        let text = http_error(reqwest::StatusCode::TOO_MANY_REQUESTS, b"");
        assert_eq!(text, "HTTP 429: Too Many Requests");
    }
}
