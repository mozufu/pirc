//! The secret-free inference protocol (`apps/gateway/src/inference-wire.ts`):
//! what an agent asks the gateway to run, and the streamed answer.

use serde::{Deserialize, Serialize};

use crate::models::ThinkingLevel;

// Keep the legacy imports as aliases of the reusable leaf DTOs.
pub use pirc_llm_types::{
    AssistantContent, AssistantDelta, AssistantMessage, InferenceErrorCode, Message, StopReason,
    ToolChoice, ToolSpec, Usage, UserBlock, UserContent,
};

/// Wire limits (`inference-wire.ts`), shared by the agent (client), the
/// node (its Unix-socket server and the link relay) and the gateway.
/// One `POST /inference` body.
pub const INFERENCE_REQUEST_MAX_BYTES: usize = 8 * 1024 * 1024;
/// One NDJSON line, and what may wait unsent in a buffer.
pub const INFERENCE_BUFFER_MAX_BYTES: usize = 16 * 1024 * 1024;
/// Everything one stream may carry.
pub const INFERENCE_STREAM_MAX_BYTES: usize = 256 * 1024 * 1024;
/// Streams in flight per node (the node's socket answers 429 beyond).
pub const INFERENCE_MAX_REQUESTS: usize = 32;
/// How long one request may run.
pub const INFERENCE_TIMEOUT_MS: u64 = 10 * 60_000;

/// What a model request is for. The default is an ordinary agent turn.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RequestPurpose {
    #[default]
    Turn,
    Title,
    Classifier,
    Compaction,
    Memory,
    Recap,
}

impl RequestPurpose {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Turn => "turn",
            Self::Title => "title",
            Self::Classifier => "classifier",
            Self::Compaction => "compaction",
            Self::Memory => "memory",
            Self::Recap => "recap",
        }
    }
}

/// One model request, as an agent's node forwards it (`model_start`).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct InferenceRequest {
    /// Why the agent makes this request; informational, for usage breakdowns.
    #[serde(default)]
    pub purpose: RequestPurpose,
    pub provider_name: String,
    pub model_id: String,
    pub system_prompt: String,
    pub messages: Vec<Message>,
    pub tools: Vec<ToolSpec>,
    pub thinking: ThinkingLevel,
    pub session_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_tokens: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_choice: Option<ToolChoice>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::round_trip;
    use serde_json::json;

    #[test]
    fn round_trips_every_message_role() {
        let messages = json!([
            { "role": "user", "content": "hi", "timestamp": 1 },
            { "role": "user", "content": [{ "type": "text", "text": "a" },
                { "type": "image", "data": "AA==", "mimeType": "image/png" }], "timestamp": 2 },
            { "role": "assistant", "content": [
                { "type": "thinking", "thinking": "hm", "signature": "s" },
                { "type": "text", "text": "ok" },
                { "type": "toolCall", "id": "c1", "name": "read", "arguments": { "path": "a" } }],
              "api": "openai-completions", "provider": "fake", "model": "m",
              "usage": { "input": 1, "output": 2, "cacheRead": 0, "cacheWrite": 0, "totalTokens": 3 },
              "stopReason": "toolUse", "timestamp": 3 },
            { "role": "toolResult", "toolCallId": "c1", "toolName": "read",
              "content": [{ "type": "text", "text": "x" }], "details": null, "isError": false,
              "timestamp": 4 },
            { "role": "custom", "customType": "note", "content": "c", "display": true,
              "timestamp": 5 },
            { "role": "compactionSummary", "summary": "s", "tokensBefore": 9, "timestamp": 6 },
        ]);
        round_trip::<Vec<Message>>(&messages).unwrap();
    }

    #[test]
    fn keeps_the_order_of_tool_schemas_and_arguments() {
        let text = r#"{"providerName":"p","modelId":"m","systemPrompt":"","messages":[{"role":"assistant","content":[{"type":"toolCall","id":"c","name":"n","arguments":{"z":1,"a":2}}],"api":"a","provider":"p","model":"m","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0},"stopReason":"toolUse","timestamp":1}],"tools":[{"name":"t","description":"d","parameters":{"type":"object","properties":{"z":{},"a":{}}}}],"thinking":"low","sessionId":"s"}"#;
        let request: InferenceRequest = serde_json::from_str(text).unwrap();
        let back = serde_json::to_string(&request).unwrap();
        assert!(back.contains(r#""arguments":{"z":1,"a":2}"#), "{back}");
        assert!(back.contains(r#""properties":{"z":{},"a":{}}"#), "{back}");
    }

    #[test]
    fn rejects_unknown_request_fields() {
        let request = json!({ "providerName": "p", "modelId": "m", "systemPrompt": "",
            "messages": [], "tools": [], "thinking": "low", "sessionId": "s", "extra": 1 });
        assert!(round_trip::<InferenceRequest>(&request).is_err());
    }
}
