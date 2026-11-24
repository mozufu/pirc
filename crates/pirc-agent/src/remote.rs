//! The gateway's inference through the node's authenticated Unix socket
//! (`agent/providers/remote.ts`): `GET /models`, `POST /inference` (NDJSON
//! `model_delta`/`model_end`/`model_error`), with the wire limits of
//! `inference-wire.ts`.
//!
//! HTTP is a small hand-written HTTP/1.1 client (`http.rs`): the peer is
//! the node's own local server, and it keeps the agent free of an HTTP
//! stack in the binary.

mod http;

use std::time::Duration;

use pirc_protocol::{
    AssistantContent, AssistantDelta, AssistantMessage, InferenceConfig, InferenceErrorCode,
    InferenceRequest, Message, Models, StopReason,
};
use serde::Deserialize;
use serde_json::Value;

use crate::LocalBoxFuture;
use crate::messages::empty_usage;
use crate::stream::{StreamFn, StreamRequest};

pub use pirc_protocol::{
    INFERENCE_BUFFER_MAX_BYTES, INFERENCE_REQUEST_MAX_BYTES, INFERENCE_STREAM_MAX_BYTES,
    INFERENCE_TIMEOUT_MS,
};
/// `fetchRemoteModels`' `AbortSignal.timeout`.
const MODELS_TIMEOUT_MS: u64 = 10_000;

/// `inferenceErrorMessage(code)`.
pub fn inference_error_message(code: InferenceErrorCode) -> &'static str {
    match code {
        InferenceErrorCode::Unavailable => "Gateway inference is unavailable",
        InferenceErrorCode::InvalidRequest => "Invalid inference request",
        InferenceErrorCode::LimitExceeded => "Inference transport limit exceeded",
        InferenceErrorCode::Timeout => "Inference request timed out",
        InferenceErrorCode::Cancelled => "Inference request cancelled",
        InferenceErrorCode::InferenceFailed => "Model inference failed",
    }
}

/// `new URL(value)` succeeds, roughly: a scheme, then anything.
fn url_like(value: &str) -> bool {
    let Some((scheme, rest)) = value.split_once(':') else {
        return false;
    };
    let mut chars = scheme.chars();
    chars.next().is_some_and(|c| c.is_ascii_alphabetic())
        && chars.all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.'))
        && !(matches!(
            scheme.to_ascii_lowercase().as_str(),
            "http" | "https" | "ws" | "wss"
        ) && rest.trim_start_matches('/').is_empty())
}

/// `modelsSchema.parse(value)`: the catalog shape and the checks serde
/// does not make (non-empty ids and model lists, positive sizes, input
/// kinds, URLs, a non-empty inference transport).
pub fn parse_models(value: &Value) -> Result<Models, String> {
    let models: Models = serde_json::from_value(value.clone()).map_err(|e| e.to_string())?;
    for (name, provider) in &models.providers {
        let at = |field: &str| format!("providers.{name}.{field}");
        if !url_like(&provider.base_url) {
            return Err(format!("{}: Expected a URL", at("baseUrl")));
        }
        if provider.models.is_empty() {
            return Err(format!("{}: Expected at least one entry", at("models")));
        }
        for (index, model) in provider.models.iter().enumerate() {
            let at = |field: &str| format!("providers.{name}.models.{index}.{field}");
            if model.base_url.as_deref().is_some_and(|url| !url_like(url)) {
                return Err(format!("{}: Expected a URL", at("baseUrl")));
            }
            if model.id.is_empty() {
                return Err(format!("{}: Expected a non-empty string", at("id")));
            }
            for (field, size) in [
                ("contextWindow", model.context_window),
                ("maxTokens", model.max_tokens),
            ] {
                if size == 0 {
                    return Err(format!("{}: Expected a positive number", at(field)));
                }
            }
            if let Some(input) = model
                .input
                .iter()
                .position(|input| input != "text" && input != "image")
            {
                return Err(format!(
                    "{}.{input}: Expected 'text' or 'image'",
                    at("input")
                ));
            }
        }
    }
    if let Some(inference) = &models.inference {
        for (field, value) in [
            ("socketPath", &inference.socket_path),
            ("token", &inference.token),
        ] {
            if value.is_empty() {
                return Err(format!("inference.{field}: Expected a non-empty string"));
            }
        }
    }
    Ok(models)
}

fn bearer(config: &InferenceConfig) -> String {
    format!("Bearer {}", config.token)
}

/// Statuses `redirect: 'error'` refuses.
fn redirect(status: u16) -> bool {
    matches!(status, 301 | 302 | 303 | 307 | 308)
}

/// `fetchRemoteModels`: the current public catalog.
pub async fn fetch_remote_models(config: &InferenceConfig) -> Result<Models, String> {
    let fetch = async {
        let authorization = bearer(config);
        let mut response = http::request(
            &config.socket_path,
            "GET",
            "/models",
            &[("Authorization", &authorization)],
            None,
        )
        .await
        .map_err(|_| "fetch failed".to_owned())?;
        if redirect(response.status) {
            return Err("fetch failed".to_owned());
        }
        if !response.ok() {
            return Err("Node model catalog is unavailable".to_owned());
        }
        let mut body = Vec::new();
        while let Some(chunk) = response
            .chunk()
            .await
            .map_err(|_| "fetch failed".to_owned())?
        {
            body.extend_from_slice(&chunk);
            if body.len() > INFERENCE_BUFFER_MAX_BYTES {
                return Err("Node model catalog exceeds limit".to_owned());
            }
        }
        let value: Value = serde_json::from_str(&String::from_utf8_lossy(&body))
            .map_err(|error| error.to_string())?;
        parse_models(&value)
    };
    tokio::time::timeout(Duration::from_millis(MODELS_TIMEOUT_MS), fetch)
        .await
        .unwrap_or_else(|_| Err("The operation timed out.".to_owned()))
}

/// `inferenceRequest(request)`: the explicit projection, never provider
/// options, endpoints or credentials.
pub fn inference_request(request: &StreamRequest) -> InferenceRequest {
    InferenceRequest {
        purpose: request.purpose,
        provider_name: request.provider_name.clone(),
        model_id: request.model.id.clone(),
        system_prompt: request.system_prompt.clone(),
        messages: request.messages.clone(),
        tools: request.tools.clone(),
        thinking: request.thinking,
        session_id: request.session_id.clone(),
        max_tokens: request.max_tokens,
        tool_choice: request.tool_choice,
    }
}

/// One NDJSON line (`inferenceEventSchema`).
#[derive(Debug, PartialEq)]
pub enum InferenceEvent {
    Delta(AssistantDelta),
    End(AssistantMessage),
    Error(InferenceErrorCode),
}

/// Parse and check one event line; `None` when it is not a valid event.
pub fn parse_event(line: &str) -> Option<InferenceEvent> {
    let value: Value = serde_json::from_str(line).ok()?;
    match value.get("type")?.as_str()? {
        "model_delta" => {
            let delta = AssistantDelta::deserialize(value.get("delta")?).ok()?;
            if let AssistantDelta::ToolcallEnd { tool_call, .. } = &delta
                && !matches!(tool_call, AssistantContent::ToolCall { .. })
            {
                return None;
            }
            Some(InferenceEvent::Delta(delta))
        }
        "model_end" => match Message::deserialize(value.get("message")?).ok()? {
            Message::Assistant(message) => Some(InferenceEvent::End(message)),
            _ => None,
        },
        "model_error" => Some(InferenceEvent::Error(
            InferenceErrorCode::deserialize(value.get("code")?).ok()?,
        )),
        _ => None,
    }
}

/// Why a stream ended without a final message.
enum Failure {
    Code(InferenceErrorCode),
    /// A transport or protocol problem (`unavailable`).
    Broken,
}

/// The request's stream: deltas as they come, then the final message.
async fn run(
    config: &InferenceConfig,
    body: Vec<u8>,
    on_delta: &mut dyn FnMut(&AssistantDelta),
) -> Result<AssistantMessage, Failure> {
    let authorization = bearer(config);
    let mut response = http::request(
        &config.socket_path,
        "POST",
        "/inference",
        &[
            ("Authorization", &authorization),
            ("Content-Type", "application/json"),
        ],
        Some(&body),
    )
    .await
    .map_err(|_| Failure::Broken)?;
    if redirect(response.status) {
        return Err(Failure::Broken);
    }
    let mut buffer: Vec<u8> = Vec::new();
    let mut bytes = 0usize;
    while let Some(chunk) = response.chunk().await.map_err(|_| Failure::Broken)? {
        bytes += chunk.len();
        if bytes > INFERENCE_STREAM_MAX_BYTES {
            return Err(Failure::Broken);
        }
        buffer.extend_from_slice(&chunk);
        let mut start = 0;
        while let Some(at) = buffer[start..].iter().position(|b| *b == b'\n') {
            let line = &buffer[start..start + at];
            start += at + 1;
            if line.len() > INFERENCE_BUFFER_MAX_BYTES {
                return Err(Failure::Broken);
            }
            if line.is_empty() {
                continue;
            }
            match parse_event(&String::from_utf8_lossy(line)) {
                Some(InferenceEvent::Delta(delta)) => on_delta(&delta),
                Some(InferenceEvent::End(message)) => return Ok(message),
                Some(InferenceEvent::Error(code)) => return Err(Failure::Code(code)),
                None => return Err(Failure::Broken),
            }
        }
        buffer.drain(..start);
        if buffer.len() > INFERENCE_BUFFER_MAX_BYTES {
            return Err(Failure::Broken);
        }
    }
    // Ended without `model_end` (with or without a partial line).
    Err(Failure::Broken)
}

/// `createRemoteStream(config)`.
pub struct RemoteStream {
    pub config: InferenceConfig,
}

impl StreamFn for RemoteStream {
    fn stream<'a>(
        &'a self,
        request: StreamRequest,
        on_delta: &'a mut dyn FnMut(&pirc_protocol::AssistantDelta),
    ) -> LocalBoxFuture<'a, pirc_protocol::AssistantMessage> {
        Box::pin(async move {
            let api = request.model.api.unwrap_or(request.provider.api);
            let partial = AssistantMessage {
                content: Vec::new(),
                api: serde_json::to_value(api)
                    .ok()
                    .and_then(|api| api.as_str().map(str::to_owned))
                    .unwrap_or_default(),
                provider: request.provider_name.clone(),
                model: request.model.id.clone(),
                usage: empty_usage(),
                stop_reason: StopReason::Stop,
                error_message: None,
                timestamp: crate::now_ms(),
                completed_at: None,
                canonical_provider: None,
                response_id: None,
                response_model: None,
            };
            let signal = request.signal.clone();
            let failure = |code: InferenceErrorCode| {
                let aborted = signal.aborted();
                AssistantMessage {
                    stop_reason: if aborted {
                        StopReason::Aborted
                    } else {
                        StopReason::Error
                    },
                    error_message: Some(
                        if aborted {
                            inference_error_message(InferenceErrorCode::Cancelled)
                        } else {
                            inference_error_message(code)
                        }
                        .to_owned(),
                    ),
                    completed_at: Some(crate::now_ms()),
                    ..partial.clone()
                }
            };
            let deadline = tokio::time::sleep(Duration::from_millis(INFERENCE_TIMEOUT_MS));
            let Ok(body) = serde_json::to_vec(&inference_request(&request)) else {
                return failure(InferenceErrorCode::Unavailable);
            };
            if body.len() > INFERENCE_REQUEST_MAX_BYTES {
                return failure(InferenceErrorCode::LimitExceeded);
            }
            let outcome = tokio::select! {
                biased;
                () = signal.cancelled() => Err(Failure::Code(InferenceErrorCode::Cancelled)),
                () = deadline => Err(Failure::Code(InferenceErrorCode::Timeout)),
                outcome = run(&self.config, body, on_delta) => outcome,
            };
            match outcome {
                Ok(message) => message,
                Err(Failure::Code(code)) => failure(code),
                Err(Failure::Broken) => failure(InferenceErrorCode::Unavailable),
            }
        })
    }
}

#[cfg(test)]
mod tests;
