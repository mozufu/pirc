//! The `anthropic-messages` wire API as the TS gateway runs it through Pi:
//! pi-adapter's mapping (`createPiStream`, `streamOptions`' Anthropic
//! branch, `fail`) around pi-ai 0.73.1's `streamAnthropic` (client
//! branches for API keys, OAuth subscription tokens, Copilot and Cloudflare
//! AI Gateway; request body; its own SSE reader and event handling) and the
//! `@anthropic-ai/sdk` 0.91.1 client it calls (headers, URL, error texts).

mod request;
mod sse;

use crate::outcome::{ErrorKind, LlmError};
use crate::runtime::RunRequest as StreamRequest;
use std::time::Duration;

use pirc_llm_types::{AssistantContent, AssistantDelta, AssistantMessage, StopReason, ToolSpec};
use serde_json::{Map, Value};

use crate::errors::pi_failure;
use crate::http::opencode_headers;
use crate::js::{self, get, present, truthy};
use crate::json_parse::{parse_streaming_json, repair_json};
use crate::pi::{NO_KEY, PiMessage, PiModel, api_name, history_message, pi_api, reasoning_effort};
use crate::stream::{Cancelled, Emitter, assistant, content_index};

use request::{HttpRequest, Options, from_claude_code_name, prepare};
use sse::{Decoder, SseMessage};

/// The SDK's default request timeout, which ends once headers arrive.
const SDK_TIMEOUT: Duration = Duration::from_secs(600);

const MESSAGE_EVENTS: [&str; 6] = [
    "message_start",
    "message_delta",
    "message_stop",
    "content_block_start",
    "content_block_delta",
    "content_block_stop",
];

/// pi-ai's scratch fields of a content block.
struct Scratch {
    /// `block.index`: the stream's block index, `None` when the event had
    /// none or once the block stopped (pi-ai deletes it).
    index: Option<Value>,
    state: ScratchState,
}

/// Scratch buffers belong only to tool calls; text/reasoning never carry JSON.
enum ScratchState {
    Text,
    Thinking,
    Tool { partial_json: Option<String> },
}

impl ScratchState {
    fn partial(&mut self) -> &mut Option<String> {
        let Self::Tool { partial_json } = self else {
            unreachable!("scratch state follows its assistant content variant")
        };
        partial_json
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

/// A JavaScript `TypeError` from reading a property of `null`/`undefined`.
fn type_error() -> Failure {
    Failure::upstream("TypeError: undefined is not an object")
}

/// `value ?? TypeError`: the object a property is read from.
fn object_of(value: Option<&Value>) -> Result<&Value, Failure> {
    present(value).ok_or_else(type_error)
}

/// A delta field appended to text: nothing when absent, other values as
/// `String(b)`.
fn js_concat(value: Option<&Value>) -> String {
    value.map_or_else(String::new, js::to_js_string)
}

/// `===` between two `index` values (objects are never equal).
fn same_index(a: Option<&Value>, b: Option<&Value>) -> bool {
    match (a, b) {
        (None, None) | (Some(Value::Null), Some(Value::Null)) => true,
        (Some(Value::Bool(a)), Some(Value::Bool(b))) => a == b,
        (Some(Value::Number(a)), Some(Value::Number(b))) => a.as_f64() == b.as_f64(),
        (Some(Value::String(a)), Some(Value::String(b))) => a == b,
        _ => false,
    }
}

/// `JSON.parse`, then once more after `repairJson` (`parseJsonWithRepair`).
fn parse_json_with_repair(text: &str) -> Option<Value> {
    crate::json_parse::parse_event(text).ok().or_else(|| {
        let repaired = repair_json(text);
        (repaired != text)
            .then(|| crate::json_parse::parse_event(&repaired).ok())
            .flatten()
    })
}

fn map_stop_reason(reason: &Value) -> Result<StopReason, Failure> {
    match reason.as_str() {
        Some("end_turn" | "pause_turn" | "stop_sequence") => Ok(StopReason::Stop),
        Some("max_tokens") => Ok(StopReason::Length),
        Some("tool_use") => Ok(StopReason::ToolUse),
        Some("refusal" | "sensitive") => Ok(StopReason::Error),
        _ => Err(Failure::Upstream(format!(
            "Unhandled stop reason: {}",
            js::to_js_string(reason)
        ))),
    }
}

/// A usage count as pi-ai keeps it.
fn count(value: Option<&Value>) -> u64 {
    js::to_u64(js::number(value).unwrap_or(0.0))
}

/// Arguments as the wire carries them (an object).
fn wire_arguments(value: Value) -> Map<String, Value> {
    match value {
        Value::Object(object) => object,
        _ => Map::new(),
    }
}

/// The adapter's `streamOptions` for `anthropic-messages`.
fn options(
    request: &StreamRequest<'_>,
    model: &PiModel,
    api_key: String,
    headers: Vec<(&'static str, String)>,
    long_cache_retention: bool,
) -> Options {
    let max_tokens = request
        .options
        .max_tokens
        .unwrap_or(request.model.max_tokens);
    let level = reasoning_effort(request, model);
    let mut options = Options {
        api_key,
        max_tokens,
        model_max_tokens: request.model.max_tokens,
        thinking_enabled: level.is_some(),
        effort: None,
        thinking_budget_tokens: 0,
        tool_choice: request.options.tool_choice,
        headers,
        long_cache_retention,
    };
    if let Some(level) = level.as_deref() {
        let fallback = match level {
            "minimal" => "low",
            other => other,
        };
        options.effort = Some(
            model
                .level_map(level)
                .flatten()
                .unwrap_or(fallback)
                .to_owned(),
        );
        let budget = match level {
            "minimal" => 1024,
            "low" => 2048,
            "medium" => 8192,
            _ => 16384,
        };
        options.thinking_budget_tokens = budget.min(max_tokens.saturating_sub(1));
        if max_tokens <= 1024 {
            options.thinking_enabled = false;
        }
    }
    options
}

/// One run: pi-ai's stream state plus the adapter's view of it.
pub struct AnthropicRun {
    model: PiModel,
    /// The adapter's result before Pi's `start` event.
    initial: AssistantMessage,
    /// `fromPi(output)`: Pi's message in wire form.
    out: AssistantMessage,
    /// The adapter's snapshot from Pi's `start` event, until the first delta.
    at_start: Option<AssistantMessage>,
    scratch: Vec<Scratch>,
    /// The caller's tools, for mapping Claude Code tool names back.
    tools: Vec<ToolSpec>,
    is_oauth: bool,
    started: bool,
    saw_start: bool,
    saw_stop: bool,
    status: Option<u16>,
}

impl AnthropicRun {
    pub fn new(request: &StreamRequest<'_>) -> Self {
        let model = PiModel::new(request);
        let api = pi_api(api_name(request.endpoint.api));
        let initial = assistant(
            api,
            request.provider_name,
            &request.model.id,
            StopReason::Stop,
        );
        let mut out = initial.clone();
        out.api = model.api.clone();
        out.model = model.id.clone();
        out.canonical_provider = Some(model.provider.clone());
        Self {
            model,
            initial,
            out,
            at_start: None,
            scratch: Vec::new(),
            tools: request.context.tools.to_vec(),
            is_oauth: false,
            started: false,
            saw_start: false,
            saw_stop: false,
            status: None,
        }
    }

    /// `{ ...result, stopReason: 'aborted' }` of the adapter's `fail(true)`.
    pub fn aborted(&self) -> AssistantMessage {
        let mut result = match (&self.at_start, self.started) {
            (Some(at_start), _) => at_start.clone(),
            (None, true) => self.out.clone(),
            (None, false) => self.initial.clone(),
        };
        result.stop_reason = StopReason::Aborted;
        result
    }

    /// The adapter's early error result (no request was made).
    fn error_without_request(&self, message: &str) -> AssistantMessage {
        let mut result = self.initial.clone();
        result.stop_reason = StopReason::Error;
        result.error_message = Some(message.to_owned());
        result
    }

    /// Pi's error event, classified by the adapter's `fail(false, …)`.
    fn failed(&self, upstream: &str) -> AssistantMessage {
        let mut result = self.out.clone();
        result.stop_reason = StopReason::Error;
        result.error_message = Some(pi_failure(self.status, Some(upstream)));
        result
    }

    pub async fn run(
        &mut self,
        client: &reqwest::Client,
        request: &StreamRequest<'_>,
        long_cache_retention: bool,
        emit: &mut Emitter<'_>,
    ) -> Result<AssistantMessage, Cancelled> {
        // A managed subscription account never falls back to another credential.
        let key = request
            .auth
            .as_key()
            .map(js::trim)
            .filter(|key| !key.is_empty());
        if request.endpoint.managed_credentials && key.is_none() {
            emit.record_error(LlmError::new(ErrorKind::CredentialsUnavailable));
            return Ok(self.error_without_request("Model credentials are unavailable."));
        }
        let Ok(headers) = opencode_headers(
            request.endpoint.opencode_go,
            &self.model.base_url,
            request.options.session_id,
        ) else {
            emit.record_error(LlmError::new(ErrorKind::InvalidRequest));
            return Ok(self.error_without_request("Model provider request failed."));
        };
        let options = options(
            request,
            &self.model,
            key.unwrap_or(NO_KEY).to_owned(),
            headers,
            long_cache_retention,
        );
        let context: Vec<PiMessage> = request
            .context
            .messages
            .iter()
            .map(|message| history_message(message, request.provider_name, &self.model))
            .collect();
        let http = match prepare(
            &self.model,
            request.context.system_prompt,
            &context,
            request.context.tools,
            &options,
            request.options.resolve_variable,
        ) {
            Ok(http) => http,
            Err(upstream) => {
                emit.record_error(LlmError::diagnostic(
                    ErrorKind::InvalidRequest,
                    upstream.clone(),
                ));
                return Ok(self.failed(&upstream));
            }
        };
        self.is_oauth = http.is_oauth;
        match self.stream(client, http, emit).await {
            Ok(result) => Ok(result),
            Err(Failure::Cancelled) => Err(Cancelled),
            Err(Failure::Upstream(upstream)) => {
                emit.record_error(LlmError::diagnostic(ErrorKind::Protocol, upstream.clone()));
                Ok(self.failed(&upstream))
            }
        }
    }

    async fn stream(
        &mut self,
        client: &reqwest::Client,
        http: HttpRequest,
        emit: &mut Emitter<'_>,
    ) -> Result<AssistantMessage, Failure> {
        let headers = http.headers.to_map().ok_or_else(|| {
            emit.record_error(LlmError::new(ErrorKind::InvalidRequest));
            Failure::upstream("Connection error.")
        })?;
        let body = serde_json::to_vec(&http.body).unwrap_or_default();
        let send = client.post(&http.url).headers(headers).body(body).send();
        let mut response = match tokio::time::timeout(SDK_TIMEOUT, send).await {
            Err(_) => {
                emit.record_error(LlmError::new(ErrorKind::Timeout));
                return Err(Failure::upstream("Request timed out."));
            }
            Ok(Err(error)) if error.is_timeout() => {
                emit.record_error(LlmError::from_reqwest(&error));
                return Err(Failure::upstream("Request timed out."));
            }
            Ok(Err(error)) => {
                emit.record_error(LlmError::from_reqwest(&error));
                return Err(Failure::upstream("Connection error."));
            }
            Ok(Ok(response)) => response,
        };
        let status = response.status().as_u16();
        if !response.status().is_success() {
            let body = response.bytes().await.unwrap_or_default();
            emit.record_error(LlmError::http(
                status,
                String::from_utf8_lossy(&body).into_owned(),
            ));
            return Err(Failure::Upstream(http_error(
                status,
                &String::from_utf8_lossy(&body),
            )));
        }
        if (100..=599).contains(&status) {
            self.status = Some(status);
        }
        if emit.cancelled() {
            return Err(Failure::Cancelled);
        }
        self.started = true;
        self.at_start = Some(self.out.clone());

        let mut decoder = Decoder::default();
        loop {
            let (messages, ended) = match response.chunk().await {
                Ok(Some(bytes)) => (decoder.push(&bytes), false),
                Ok(None) => (decoder.finish(), true),
                Err(error) => {
                    emit.record_error(LlmError::from_reqwest(&error));
                    return Err(Failure::upstream("terminated"));
                }
            };
            for message in messages {
                self.sse(&message, emit)?;
            }
            if ended {
                break;
            }
        }
        if self.saw_start && !self.saw_stop {
            return Err(Failure::upstream(
                "Anthropic stream ended before message_stop",
            ));
        }
        if matches!(
            self.out.stop_reason,
            StopReason::Aborted | StopReason::Error
        ) {
            emit.record_error(LlmError::new(ErrorKind::Provider));
            return Err(Failure::upstream("An unknown error occurred"));
        }
        Ok(self.out.clone())
    }

    /// `iterateAnthropicEvents` for one SSE message.
    fn sse(&mut self, message: &SseMessage, emit: &mut Emitter<'_>) -> Result<(), Failure> {
        let name = message.event.as_deref().unwrap_or_default();
        if name == "error" {
            emit.record_error(LlmError::upstream(message.data.clone()));
            return Err(Failure::Upstream(message.data.clone()));
        }
        if !MESSAGE_EVENTS.contains(&name) {
            return Ok(());
        }
        let parse_error = |error: &str| {
            Failure::Upstream(format!(
                "Could not parse Anthropic SSE event {name}: {error}; data={}; raw={}",
                message.data,
                message.raw.join("\\n")
            ))
        };
        let event = parse_json_with_repair(&message.data)
            .ok_or_else(|| parse_error("JSON Parse error: Unable to parse JSON string"))?;
        if event.is_null() {
            return Err(parse_error(
                "TypeError: null is not an object (evaluating 'event.type')",
            ));
        }
        match get(Some(&event), "type").and_then(Value::as_str) {
            Some("message_start") => self.saw_start = true,
            Some("message_stop") => self.saw_stop = true,
            _ => {}
        }
        self.event(&event, emit)
    }

    fn emit(&mut self, delta: AssistantDelta, emit: &mut Emitter<'_>) -> Result<(), Failure> {
        self.at_start = None;
        emit.emit(delta, &self.out)
            .map_err(|Cancelled| Failure::Cancelled)
    }

    /// The first block whose `index` is `index` (`blocks.findIndex`).
    fn find(&self, index: Option<&Value>) -> Option<usize> {
        self.scratch
            .iter()
            .position(|scratch| same_index(scratch.index.as_ref(), index))
    }

    fn push_block(&mut self, block: AssistantContent, index: Option<&Value>) -> u32 {
        let state = match &block {
            AssistantContent::Text { .. } => ScratchState::Text,
            AssistantContent::Thinking { .. } => ScratchState::Thinking,
            AssistantContent::ToolCall { .. } => ScratchState::Tool {
                partial_json: Some(String::new()),
            },
        };
        self.out.content.push(block);
        self.scratch.push(Scratch {
            index: index.cloned(),
            state,
        });
        content_index(self.out.content.len() - 1)
    }

    /// One parsed event (`streamAnthropic`'s loop body).
    fn event(&mut self, event: &Value, emit: &mut Emitter<'_>) -> Result<(), Failure> {
        let event = Some(event);
        let index = get(event, "index");
        match get(event, "type").and_then(Value::as_str) {
            Some("message_start") => {
                let message = object_of(get(event, "message"))?;
                self.out.response_id = get(Some(message), "id")
                    .and_then(Value::as_str)
                    .map(str::to_owned);
                let usage = object_of(get(Some(message), "usage"))?;
                let field = |name: &str| {
                    let value = get(Some(usage), name);
                    if truthy(value) { count(value) } else { 0 }
                };
                let out = &mut self.out.usage;
                out.input = field("input_tokens");
                out.output = field("output_tokens");
                out.cache_read = field("cache_read_input_tokens");
                out.cache_write = field("cache_creation_input_tokens");
                out.total_tokens = crate::stream::usage_total(out, true);
            }
            Some("content_block_start") => {
                let block = Some(object_of(get(event, "content_block"))?);
                match get(block, "type").and_then(Value::as_str) {
                    Some("text") => {
                        let text = AssistantContent::Text {
                            text: String::new(),
                            text_signature: None,
                        };
                        let content_index = self.push_block(text, index);
                        self.emit(AssistantDelta::TextStart { content_index }, emit)?;
                    }
                    Some("thinking") => {
                        let thinking = AssistantContent::Thinking {
                            thinking: String::new(),
                            signature: Some(String::new()),
                            redacted: None,
                        };
                        let content_index = self.push_block(thinking, index);
                        self.emit(AssistantDelta::ThinkingStart { content_index }, emit)?;
                    }
                    Some("redacted_thinking") => {
                        let thinking = AssistantContent::Thinking {
                            thinking: "[Reasoning redacted]".to_owned(),
                            signature: present(get(block, "data")).map(js::to_js_string),
                            redacted: Some(true),
                        };
                        let content_index = self.push_block(thinking, index);
                        self.emit(AssistantDelta::ThinkingStart { content_index }, emit)?;
                    }
                    Some("tool_use") => {
                        let raw_name = get(block, "name");
                        let name = if self.is_oauth && !self.tools.is_empty() {
                            let name = raw_name.and_then(Value::as_str).ok_or_else(type_error)?;
                            from_claude_code_name(name, &self.tools)
                        } else {
                            raw_name.map(js::to_js_string).unwrap_or_default()
                        };
                        let id = present(get(block, "id"))
                            .map(js::to_js_string)
                            .unwrap_or_default();
                        let input = present(get(block, "input"))
                            .cloned()
                            .unwrap_or_else(|| Value::Object(Map::new()));
                        let call = AssistantContent::ToolCall {
                            id: id.clone(),
                            name: name.clone(),
                            arguments: wire_arguments(input),
                            thought_signature: None,
                        };
                        let content_index = self.push_block(call, index);
                        self.emit(
                            AssistantDelta::ToolcallStart {
                                content_index,
                                id,
                                tool_name: name,
                            },
                            emit,
                        )?;
                    }
                    _ => {}
                }
            }
            Some("content_block_delta") => {
                let delta = Some(object_of(get(event, "delta"))?);
                let Some(position) = self.find(index) else {
                    // `blocks[-1]` is undefined: nothing happens, whatever the type.
                    return Ok(());
                };
                let content_index = content_index(position);
                match get(delta, "type").and_then(Value::as_str) {
                    Some("text_delta") => {
                        if let AssistantContent::Text { text, .. } = &mut self.out.content[position]
                        {
                            let delta = js_concat(get(delta, "text"));
                            text.push_str(&delta);
                            self.emit(
                                AssistantDelta::TextDelta {
                                    content_index,
                                    delta,
                                },
                                emit,
                            )?;
                        }
                    }
                    Some("thinking_delta") => {
                        if let AssistantContent::Thinking { thinking, .. } =
                            &mut self.out.content[position]
                        {
                            let delta = js_concat(get(delta, "thinking"));
                            thinking.push_str(&delta);
                            self.emit(
                                AssistantDelta::ThinkingDelta {
                                    content_index,
                                    delta,
                                },
                                emit,
                            )?;
                        }
                    }
                    Some("input_json_delta") => {
                        if let AssistantContent::ToolCall { arguments, .. } =
                            &mut self.out.content[position]
                        {
                            let delta = js_concat(get(delta, "partial_json"));
                            let partial = self.scratch[position]
                                .state
                                .partial()
                                .get_or_insert_with(String::new);
                            partial.push_str(&delta);
                            *arguments = wire_arguments(parse_streaming_json(partial));
                            self.emit(
                                AssistantDelta::ToolcallDelta {
                                    content_index,
                                    delta,
                                },
                                emit,
                            )?;
                        }
                    }
                    Some("signature_delta") => {
                        if let AssistantContent::Thinking { signature, .. } =
                            &mut self.out.content[position]
                        {
                            let signature = signature.get_or_insert_with(String::new);
                            signature.push_str(&js_concat(get(delta, "signature")));
                        }
                    }
                    _ => {}
                }
            }
            Some("content_block_stop") => {
                let Some(position) = self.find(index) else {
                    return Ok(());
                };
                self.scratch[position].index = None;
                let content_index = content_index(position);
                let end = match &mut self.out.content[position] {
                    AssistantContent::Text { text, .. } => AssistantDelta::TextEnd {
                        content_index,
                        content: text.clone(),
                    },
                    AssistantContent::Thinking { thinking, .. } => AssistantDelta::ThinkingEnd {
                        content_index,
                        content: thinking.clone(),
                    },
                    call @ AssistantContent::ToolCall { .. } => {
                        let partial = self.scratch[position].state.partial().take();
                        if let AssistantContent::ToolCall { arguments, .. } = call {
                            *arguments = wire_arguments(parse_streaming_json(
                                partial.as_deref().unwrap_or_default(),
                            ));
                        }
                        AssistantDelta::ToolcallEnd {
                            content_index,
                            tool_call: call.clone(),
                        }
                    }
                };
                self.emit(end, emit)?;
            }
            Some("message_delta") => {
                let delta = object_of(get(event, "delta"))?;
                let stop_reason = get(Some(delta), "stop_reason");
                if truthy(stop_reason) {
                    self.out.stop_reason = map_stop_reason(stop_reason.unwrap_or(&Value::Null))?;
                }
                let usage = Some(object_of(get(event, "usage"))?);
                let out = &mut self.out.usage;
                let fields = [
                    ("input_tokens", &mut out.input),
                    ("output_tokens", &mut out.output),
                    ("cache_read_input_tokens", &mut out.cache_read),
                    ("cache_creation_input_tokens", &mut out.cache_write),
                ];
                for (name, slot) in fields {
                    if let Some(value) = present(get(usage, name)) {
                        *slot = count(Some(value));
                    }
                }
                out.total_tokens = crate::stream::usage_total(out, true);
            }
            _ => {}
        }
        Ok(())
    }
}

/// `APIError.makeMessage` for a non-2xx response: the whole JSON body is
/// the error.
fn http_error(status: u16, body: &str) -> String {
    let parsed: Option<Value> = serde_json::from_str(body).ok();
    let error = parsed.as_ref().filter(|value| truthy(Some(value)));
    let message = get(error, "message");
    let msg = if truthy(message) {
        match message {
            Some(Value::String(text)) => text.clone(),
            Some(other) => other.to_string(),
            None => String::new(),
        }
    } else if let Some(error) = error {
        error.to_string()
    } else {
        body.to_owned()
    };
    if msg.is_empty() {
        format!("{status} status code (no body)")
    } else {
        format!("{status} {msg}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn api_error_messages_match_the_sdk() {
        assert_eq!(http_error(500, "boom"), "500 boom");
        assert_eq!(http_error(429, ""), "429 status code (no body)");
        assert_eq!(
            http_error(400, r#"{"type":"error","error":{"message":"x"}}"#),
            r#"400 {"type":"error","error":{"message":"x"}}"#
        );
        assert_eq!(http_error(400, r#"{"message":"m"}"#), "400 m");
        assert_eq!(http_error(400, r#"{"message":{"a":1}}"#), r#"400 {"a":1}"#);
        assert_eq!(http_error(401, "null"), "401 null");
        assert_eq!(http_error(401, "0"), "401 0");
        assert_eq!(http_error(401, "\"\""), "401 \"\"");
    }

    #[test]
    fn indexes_compare_strictly() {
        assert!(same_index(None, None));
        assert!(same_index(Some(&json!(1)), Some(&json!(1.0))));
        assert!(!same_index(Some(&json!(1)), None));
        assert!(!same_index(Some(&json!({})), Some(&json!({}))));
    }

    #[test]
    fn maps_stop_reasons() {
        assert_eq!(
            map_stop_reason(&json!("pause_turn")).ok(),
            Some(StopReason::Stop)
        );
        assert!(matches!(
            map_stop_reason(&json!(5)),
            Err(Failure::Upstream(text)) if text == "Unhandled stop reason: 5"
        ));
    }
    #[test]
    fn owned_arguments_keep_order_and_reject_non_objects() {
        assert_eq!(
            Value::Object(wire_arguments(
                serde_json::from_str(r#"{"z":1,"a":2}"#).unwrap()
            ))
            .to_string(),
            r#"{"z":1,"a":2}"#
        );
        assert!(wire_arguments(json!([1])).is_empty());
    }
}
