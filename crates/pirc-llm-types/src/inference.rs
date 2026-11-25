//! Messages, tool schemas, deltas and inference failure codes.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ToolSpec {
    pub name: String,
    pub description: String,
    pub parameters: Map<String, Value>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ToolChoice {
    Auto,
    None,
}

/// A conversation entry, by `role`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(
    tag = "role",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
pub enum Message {
    User {
        content: UserContent,
        timestamp: u64,
    },
    Assistant(AssistantMessage),
    ToolResult {
        tool_call_id: String,
        tool_name: String,
        content: Vec<UserBlock>,
        #[serde(
            default,
            deserialize_with = "crate::opaque::present",
            skip_serializing_if = "Option::is_none"
        )]
        details: Option<Value>,
        is_error: bool,
        timestamp: u64,
    },
    Custom {
        custom_type: String,
        content: String,
        display: bool,
        #[serde(
            default,
            deserialize_with = "crate::opaque::present",
            skip_serializing_if = "Option::is_none"
        )]
        details: Option<Value>,
        timestamp: u64,
    },
    CompactionSummary {
        summary: String,
        tokens_before: u64,
        timestamp: u64,
    },
}

/// A user message's content: plain text or text and image blocks.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum UserContent {
    Text(String),
    Blocks(Vec<UserBlock>),
}

/// Content a user message or tool result can carry.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(
    tag = "type",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
pub enum UserBlock {
    Text {
        text: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        text_signature: Option<String>,
    },
    Image {
        data: String,
        mime_type: String,
    },
}

/// Content an assistant message can carry.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(
    tag = "type",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
pub enum AssistantContent {
    Text {
        text: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        text_signature: Option<String>,
    },
    Thinking {
        thinking: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        signature: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        redacted: Option<bool>,
    },
    ToolCall {
        id: String,
        name: String,
        arguments: Map<String, Value>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        thought_signature: Option<String>,
    },
}

/// An assistant message's fields; its `role` tag comes from [`Message`].
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AssistantMessage {
    pub content: Vec<AssistantContent>,
    pub api: String,
    pub provider: String,
    pub model: String,
    pub usage: Usage,
    pub stop_reason: StopReason,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error_message: Option<String>,
    pub timestamp: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub completed_at: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub canonical_provider: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub response_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub response_model: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Usage {
    pub input: u64,
    pub output: u64,
    pub cache_read: u64,
    pub cache_write: u64,
    pub total_tokens: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum StopReason {
    Stop,
    Length,
    ToolUse,
    Error,
    Aborted,
}

/// One streamed change to the assistant message being built.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(
    tag = "type",
    rename_all = "snake_case",
    rename_all_fields = "camelCase"
)]
pub enum AssistantDelta {
    TextStart {
        content_index: u32,
    },
    TextDelta {
        content_index: u32,
        delta: String,
    },
    TextEnd {
        content_index: u32,
        content: String,
    },
    ThinkingStart {
        content_index: u32,
    },
    ThinkingDelta {
        content_index: u32,
        delta: String,
    },
    ThinkingEnd {
        content_index: u32,
        content: String,
    },
    ToolcallStart {
        content_index: u32,
        id: String,
        tool_name: String,
    },
    ToolcallDelta {
        content_index: u32,
        delta: String,
    },
    /// `tool_call` is always the `toolCall` variant.
    ToolcallEnd {
        content_index: u32,
        tool_call: AssistantContent,
    },
}

/// Why an inference request failed; the message is fixed per code, so no
/// provider text crosses the link.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum InferenceErrorCode {
    Unavailable,
    InvalidRequest,
    LimitExceeded,
    Timeout,
    Cancelled,
    InferenceFailed,
    /// The request would exceed a pot's or its owner's budget cap.
    BudgetExhausted,
}
