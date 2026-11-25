//! The gateway's native Chat Completions transport for providers configured
//! with the legacy `openai-chat` API (`agent/providers/openai-chat.ts`).

use crate::outcome::{ErrorKind, LlmError};
use crate::runtime::{ResolvedModel, RunRequest as StreamRequest};
use pirc_llm_types::{
    AssistantContent, AssistantDelta, AssistantMessage, Message, StopReason, ThinkingLevel,
    UserBlock, UserContent,
};
use serde_json::{Map, Value, json};

use crate::http::{Headers, opencode_headers};
use crate::js::{self, get, non_empty_str, present, truthy};
use crate::native::parse_tool_arguments;
use crate::sse::NativeDecoder;
use crate::stream::{Cancelled, Emitter, assistant, content_index, now_ms};

#[derive(Clone, Copy)]
struct Compat {
    developer_role: bool,
    reasoning_effort: bool,
    session_affinity: bool,
    long_cache: bool,
}

impl Compat {
    fn resolve(request: &StreamRequest<'_>) -> Self {
        let flags = &request.endpoint.compat;
        Self {
            developer_role: truthy(flags.get("supportsDeveloperRole")),
            reasoning_effort: flags.get("supportsReasoningEffort") != Some(&Value::Bool(false)),
            session_affinity: truthy(flags.get("sendSessionAffinityHeaders")),
            long_cache: truthy(flags.get("supportsLongCacheRetention")),
        }
    }
}

fn image_url(mime_type: &str, data: &str) -> Value {
    json!({ "type": "image_url", "image_url": { "url": format!("data:{mime_type};base64,{data}") } })
}

/// `textOf`: text blocks joined without a separator.
fn text_of(blocks: &[UserBlock]) -> String {
    blocks
        .iter()
        .filter_map(|block| match block {
            UserBlock::Text { text, .. } => Some(text.as_str()),
            UserBlock::Image { .. } => None,
        })
        .collect()
}

fn assistant_text(content: &[AssistantContent]) -> String {
    content
        .iter()
        .filter_map(|part| match part {
            AssistantContent::Text { text, .. } => Some(text.as_str()),
            _ => None,
        })
        .collect()
}

/// `toOpenAIMessages`.
fn to_openai_messages(request: &StreamRequest<'_>, flags: &Compat) -> Vec<Value> {
    let mut out = Vec::new();
    if !request.context.system_prompt.is_empty() {
        let role = if flags.developer_role {
            "developer"
        } else {
            "system"
        };
        out.push(json!({ "role": role, "content": request.context.system_prompt }));
    }
    for message in request.context.messages {
        match message {
            Message::User { content, .. } => {
                let content = match content {
                    UserContent::Text(text) => json!(text),
                    UserContent::Blocks(blocks) => Value::Array(
                        blocks
                            .iter()
                            .map(|block| match block {
                                UserBlock::Text { text, .. } => {
                                    json!({ "type": "text", "text": text })
                                }
                                UserBlock::Image { data, mime_type } => image_url(mime_type, data),
                            })
                            .collect(),
                    ),
                };
                out.push(json!({ "role": "user", "content": content }));
            }
            Message::Custom { content, .. } => {
                out.push(json!({ "role": "user", "content": content }));
            }
            Message::CompactionSummary { summary, .. } => out.push(json!({ "role": "user",
                "content": format!("<summary>\nThe conversation so far was compacted into this summary:\n\n{summary}\n</summary>") })),
            Message::Assistant(message) => {
                let text = assistant_text(&message.content);
                if matches!(message.stop_reason, StopReason::Error | StopReason::Aborted) {
                    // Keep only completed text, as the user saw it.
                    if !text.is_empty() {
                        out.push(json!({ "role": "assistant", "content": text }));
                    }
                    continue;
                }
                let mut converted = Map::new();
                converted.insert("role".to_owned(), json!("assistant"));
                let content = if text.is_empty() {
                    Value::Null
                } else {
                    json!(text)
                };
                converted.insert("content".to_owned(), content);
                let calls: Vec<Value> = message
                    .content
                    .iter()
                    .filter_map(|part| match part {
                        AssistantContent::ToolCall {
                            id,
                            name,
                            arguments,
                            ..
                        } => Some(json!({ "id": id, "type": "function", "function": {
                            "name": name,
                            "arguments": serde_json::to_string(arguments).unwrap_or_default(),
                        } })),
                        _ => None,
                    })
                    .collect();
                if !calls.is_empty() {
                    converted.insert("tool_calls".to_owned(), Value::Array(calls));
                }
                out.push(Value::Object(converted));
            }
            Message::ToolResult {
                tool_call_id,
                tool_name,
                content,
                ..
            } => {
                let text = text_of(content);
                let text = if text.is_empty() {
                    "(no output)".to_owned()
                } else {
                    text
                };
                out.push(json!({ "role": "tool", "tool_call_id": tool_call_id, "content": text }));
                let images: Vec<Value> = content
                    .iter()
                    .filter_map(|block| match block {
                        UserBlock::Image { data, mime_type } => Some(image_url(mime_type, data)),
                        UserBlock::Text { .. } => None,
                    })
                    .collect();
                if !images.is_empty() {
                    let mut parts = vec![json!({ "type": "text",
                        "text": format!("Images returned by tool {tool_name}:") })];
                    parts.extend(images);
                    out.push(json!({ "role": "user", "content": parts }));
                }
            }
        }
    }
    out
}

/// `reasoning_effort`: the model's mapping for the effective level, else the
/// level name (`none` for off).
fn effort(model: &ResolvedModel, level: ThinkingLevel) -> String {
    let Some(effective) = model.effective_thinking_level(level) else {
        return model
            .thinking_level_map
            .as_ref()
            .and_then(|map| map.get("off"))
            .and_then(Option::as_deref)
            .unwrap_or("none")
            .to_owned();
    };
    model
        .thinking_level_map
        .as_ref()
        .and_then(|map| map.get(effective.as_str()))
        .and_then(Option::as_deref)
        .unwrap_or_else(|| effective.as_str())
        .to_owned()
}

/// `openAIBody`.
fn openai_body(request: &StreamRequest<'_>, flags: &Compat) -> Map<String, Value> {
    let mut body = Map::new();
    body.insert("model".to_owned(), json!(request.model.id));
    body.insert(
        "messages".to_owned(),
        Value::Array(to_openai_messages(request, flags)),
    );
    body.insert("stream".to_owned(), json!(true));
    body.insert(
        "stream_options".to_owned(),
        json!({ "include_usage": true }),
    );
    body.insert(
        "max_completion_tokens".to_owned(),
        json!(
            request
                .options
                .max_tokens
                .unwrap_or(request.model.max_tokens)
        ),
    );
    if !request.context.tools.is_empty() {
        let tools: Vec<Value> = request
            .context
            .tools
            .iter()
            .map(|tool| {
                json!({ "type": "function", "function": { "name": tool.name,
                    "description": tool.description, "parameters": tool.parameters } })
            })
            .collect();
        body.insert("tools".to_owned(), Value::Array(tools));
        if let Some(choice) = request.options.tool_choice {
            body.insert(
                "tool_choice".to_owned(),
                serde_json::to_value(choice).unwrap_or_default(),
            );
        }
    }
    if request.model.reasoning && flags.reasoning_effort {
        body.insert(
            "reasoning_effort".to_owned(),
            json!(effort(request.model, request.options.thinking)),
        );
    }
    if flags.session_affinity {
        body.insert(
            "prompt_cache_key".to_owned(),
            json!(request.options.session_id),
        );
    }
    if flags.long_cache {
        body.insert("prompt_cache_retention".to_owned(), json!("24h"));
    }
    body
}

struct Call {
    index: f64,
    content_index: usize,
    raw: String,
}

/// At most one text/reasoning block is open; switching closes the previous kind.
enum ActiveBlock {
    Text(usize),
    Thinking(usize),
}

pub struct ChatRun {
    message: AssistantMessage,
    calls: Vec<Call>,
    active: Option<ActiveBlock>,
}

impl ChatRun {
    pub fn new(request: &StreamRequest<'_>) -> Self {
        Self {
            message: assistant(
                "openai-chat",
                request.provider_name,
                &request.model.id,
                StopReason::Stop,
            ),
            calls: Vec::new(),
            active: None,
        }
    }

    fn close_text(&mut self, emit: &mut Emitter<'_>) -> Result<(), Cancelled> {
        let Some(ActiveBlock::Text(index)) = self.active else {
            return Ok(());
        };
        self.active = None;
        let content = match &self.message.content[index] {
            AssistantContent::Text { text, .. } => text.clone(),
            _ => String::new(),
        };
        emit.emit(
            AssistantDelta::TextEnd {
                content_index: content_index(index),
                content,
            },
            &self.message,
        )
    }

    fn close_thinking(&mut self, emit: &mut Emitter<'_>) -> Result<(), Cancelled> {
        let Some(ActiveBlock::Thinking(index)) = self.active else {
            return Ok(());
        };
        self.active = None;
        let content = match &self.message.content[index] {
            AssistantContent::Thinking { thinking, .. } => thinking.clone(),
            _ => String::new(),
        };
        emit.emit(
            AssistantDelta::ThinkingEnd {
                content_index: content_index(index),
                content,
            },
            &self.message,
        )
    }

    fn fix_total(mut message: AssistantMessage) -> AssistantMessage {
        let usage = &mut message.usage;
        if usage.total_tokens == 0 {
            usage.total_tokens = crate::stream::usage_total(usage, false);
        }
        message
    }

    /// The `catch` path for an aborted request.
    pub fn aborted(&self) -> AssistantMessage {
        let mut message = self.message.clone();
        message
            .content
            .retain(|part| !matches!(part, AssistantContent::ToolCall { .. }));
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
            Ok(()) => {
                // Completion runs to the end even if cancelled meanwhile; the
                // caller then marks the message aborted.
                let _ = self.close_text(emit);
                let _ = self.close_thinking(emit);
                for call in &self.calls {
                    let arguments = parse_tool_arguments(&call.raw);
                    let part = &mut self.message.content[call.content_index];
                    if let AssistantContent::ToolCall {
                        arguments: args, ..
                    } = part
                    {
                        *args = arguments;
                    }
                    let delta = AssistantDelta::ToolcallEnd {
                        content_index: content_index(call.content_index),
                        tool_call: part.clone(),
                    };
                    let _ = emit.emit(delta, &self.message);
                }
                self.message.stop_reason = if !self.calls.is_empty() {
                    StopReason::ToolUse
                } else {
                    self.message.stop_reason
                };
                Ok(Self::fix_total(self.message.clone()))
            }
            Err(Failure::Cancelled) => Err(Cancelled),
            Err(Failure::Upstream(error)) => {
                emit.record_error(LlmError::diagnostic(ErrorKind::Protocol, error.clone()));
                let _ = self.close_text(emit);
                let _ = self.close_thinking(emit);
                if emit.cancelled() {
                    return Err(Cancelled);
                }
                // Half-streamed tool calls can be neither run nor replayed.
                self.message
                    .content
                    .retain(|part| !matches!(part, AssistantContent::ToolCall { .. }));
                self.message.stop_reason = StopReason::Error;
                self.message.error_message = Some(error);
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
        let flags = Compat::resolve(request);
        let base = request.endpoint.base_url.as_str();
        let url = format!(
            "{}/chat/completions",
            base.strip_suffix('/').unwrap_or(base)
        );
        let mut headers = Headers::default();
        headers.set("content-type", "application/json");
        headers.set("accept", "text/event-stream");
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
            headers.set("authorization", &format!("Bearer {key}"));
        }
        if flags.session_affinity {
            headers.set("session_id", request.options.session_id);
        }
        let header_map = headers.to_map().ok_or_else(|| {
            emit.record_error(LlmError::new(ErrorKind::InvalidRequest));
            Failure::upstream("Invalid header")
        })?;
        let body = serde_json::to_vec(&openai_body(request, &flags)).unwrap_or_default();
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
            let text: String = String::from_utf8_lossy(&body).chars().take(2000).collect();
            let text = if text.is_empty() {
                status.canonical_reason().unwrap_or("").to_owned()
            } else {
                text
            };
            emit.record_error(LlmError::http(status.as_u16(), text.clone()));
            return Err(Failure::Upstream(format!(
                "HTTP {}: {text}",
                status.as_u16()
            )));
        }
        let mut decoder = NativeDecoder::default();
        let mut finish: Option<Value> = None;
        'read: loop {
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
                if event.data == "[DONE]" {
                    break 'read;
                }
                self.chunk(&event.data, &mut finish, emit)?;
            }
            if ended {
                break;
            }
        }
        if finish.as_ref().and_then(Value::as_str) == Some("length") {
            self.message.stop_reason = StopReason::Length;
        }
        Ok(())
    }

    fn chunk(
        &mut self,
        data: &str,
        finish: &mut Option<Value>,
        emit: &mut Emitter<'_>,
    ) -> Result<(), Failure> {
        let chunk: Value = crate::json_parse::parse_event(data)
            .map_err(|_| Failure::upstream("JSON Parse error: Unable to parse JSON string"))?;
        if chunk.is_null() {
            return Err(Failure::upstream("null is not an object"));
        }
        let chunk = Some(&chunk);
        let error = get(chunk, "error");
        if truthy(error) {
            let message = match present(get(error, "message")) {
                Some(message) => js::to_js_string(message),
                None => error.map(Value::to_string).unwrap_or_default(),
            };
            emit.record_error(LlmError::upstream(message.clone()));
            return Err(Failure::Upstream(message));
        }
        let usage = get(chunk, "usage");
        if truthy(usage) {
            let number =
                |value: Option<&Value>| present(value).and_then(Value::as_f64).unwrap_or(0.0);
            let cached = number(get(get(usage, "prompt_tokens_details"), "cached_tokens"));
            let usage_out = &mut self.message.usage;
            usage_out.input = js::to_u64(number(get(usage, "prompt_tokens")) - cached);
            usage_out.output = js::to_u64(number(get(usage, "completion_tokens")));
            usage_out.cache_read = js::to_u64(cached);
            usage_out.cache_write = 0;
            usage_out.total_tokens = js::to_u64(number(get(usage, "total_tokens")));
        }
        let choice = get(chunk, "choices")
            .and_then(Value::as_array)
            .and_then(|choices| choices.first());
        if !truthy(choice) {
            return Ok(());
        }
        let delta = present(get(choice, "delta"));
        let reasoning =
            present(get(delta, "reasoning_content")).or(present(get(delta, "reasoning")));
        if let Some(reasoning) = non_empty_str(reasoning) {
            self.close_text(emit).map_err(Failure::from)?;
            let index = match self.active {
                Some(ActiveBlock::Thinking(index)) => index,
                _ => {
                    self.message.content.push(AssistantContent::Thinking {
                        thinking: String::new(),
                        signature: None,
                        redacted: None,
                    });
                    let index = self.message.content.len() - 1;
                    self.active = Some(ActiveBlock::Thinking(index));
                    let start = AssistantDelta::ThinkingStart {
                        content_index: content_index(index),
                    };
                    emit.emit(start, &self.message)?;
                    index
                }
            };
            if let AssistantContent::Thinking { thinking, .. } = &mut self.message.content[index] {
                thinking.push_str(reasoning);
            }
            let delta = AssistantDelta::ThinkingDelta {
                content_index: content_index(index),
                delta: reasoning.to_owned(),
            };
            emit.emit(delta, &self.message)?;
        }
        if let Some(text) = non_empty_str(get(delta, "content")) {
            self.close_thinking(emit)?;
            let index = match self.active {
                Some(ActiveBlock::Text(index)) => index,
                _ => {
                    self.message.content.push(AssistantContent::Text {
                        text: String::new(),
                        text_signature: None,
                    });
                    let index = self.message.content.len() - 1;
                    self.active = Some(ActiveBlock::Text(index));
                    let start = AssistantDelta::TextStart {
                        content_index: content_index(index),
                    };
                    emit.emit(start, &self.message)?;
                    index
                }
            };
            if let AssistantContent::Text { text: existing, .. } = &mut self.message.content[index]
            {
                existing.push_str(text);
            }
            let delta = AssistantDelta::TextDelta {
                content_index: content_index(index),
                delta: text.to_owned(),
            };
            emit.emit(delta, &self.message)?;
        }
        if let Some(calls) = present(get(delta, "tool_calls")) {
            let Some(calls) = calls.as_array() else {
                return Err(Failure::upstream("tool_calls is not iterable"));
            };
            for call in calls {
                self.tool_call(call, emit)?;
            }
        }
        if let Some(reason) = get(choice, "finish_reason").filter(|r| truthy(Some(r))) {
            *finish = Some(reason.clone());
        }
        Ok(())
    }

    fn tool_call(&mut self, call: &Value, emit: &mut Emitter<'_>) -> Result<(), Failure> {
        if call.is_null() {
            return Err(Failure::upstream("null is not an object"));
        }
        self.close_text(emit)?;
        self.close_thinking(emit)?;
        let call = Some(call);
        let index = js::number(get(call, "index")).unwrap_or(0.0);
        let function = get(call, "function");
        let position = match self.calls.iter().position(|state| state.index == index) {
            Some(position) => position,
            None => {
                let id = match present(get(call, "id")) {
                    Some(id) => js::to_js_string(id),
                    None => format!("call_{}_{}", js::to_js_string(&json!(index)), now_ms()),
                };
                let name = present(get(function, "name"))
                    .map(js::to_js_string)
                    .unwrap_or_default();
                self.message.content.push(AssistantContent::ToolCall {
                    id: id.clone(),
                    name: name.clone(),
                    arguments: Map::new(),
                    thought_signature: None,
                });
                let content = self.message.content.len() - 1;
                self.calls.push(Call {
                    index,
                    content_index: content,
                    raw: String::new(),
                });
                let start = AssistantDelta::ToolcallStart {
                    content_index: content_index(content),
                    id,
                    tool_name: name,
                };
                emit.emit(start, &self.message)?;
                self.calls.len() - 1
            }
        };
        let content = self.calls[position].content_index;
        if let Some(new_name) = get(function, "name").filter(|name| truthy(Some(name)))
            && let AssistantContent::ToolCall { name, .. } = &mut self.message.content[content]
            && name.is_empty()
        {
            *name = js::to_js_string(new_name);
        }
        if let Some(arguments) = non_empty_str(get(function, "arguments")) {
            self.calls[position].raw.push_str(arguments);
            let delta = AssistantDelta::ToolcallDelta {
                content_index: content_index(content),
                delta: arguments.to_owned(),
            };
            emit.emit(delta, &self.message)?;
        }
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

    #[test]
    fn parses_tool_arguments_like_the_ts_helper() {
        assert_eq!(parse_tool_arguments(" "), Map::new());
        assert_eq!(
            Value::Object(parse_tool_arguments(r#"{"a":1}"#)),
            json!({ "a": 1 })
        );
        assert_eq!(
            Value::Object(parse_tool_arguments("[1]")),
            json!({ "value": [1] })
        );
        assert_eq!(
            Value::Object(parse_tool_arguments("nope")),
            json!({ "__invalid_json": "nope" })
        );
    }
    #[test]
    fn compat_resolves_legacy_truthiness_not_strict_bool() {
        let mut endpoint = crate::ResolvedEndpoint::new(
            pirc_llm_types::ModelApi::OpenaiChat,
            "p",
            "http://localhost",
        );
        endpoint.compat = serde_json::from_value(json!({
            "supportsDeveloperRole": [], "supportsReasoningEffort": null,
            "sendSessionAffinityHeaders": "false", "supportsLongCacheRetention": 0
        }))
        .unwrap();
        let model = crate::ResolvedModel::new("m", 10);
        let request = crate::RunRequest::new("p", &endpoint, &model);
        let flags = Compat::resolve(&request);
        assert!(flags.developer_role);
        assert!(flags.reasoning_effort);
        assert!(flags.session_affinity);
        assert!(!flags.long_cache);
    }

    #[test]
    fn usage_fallback_saturates_without_replacing_reported_total() {
        let mut message = assistant("a", "p", "m", StopReason::Stop);
        message.usage.input = u64::MAX;
        message.usage.output = 1;
        assert_eq!(
            ChatRun::fix_total(message.clone()).usage.total_tokens,
            u64::MAX
        );
        message.usage.total_tokens = 7;
        assert_eq!(ChatRun::fix_total(message).usage.total_tokens, 7);
    }
}
