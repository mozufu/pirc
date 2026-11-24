//! A model call as the agent makes it (`StreamRequest`/`StreamFn` in
//! `agent/providers/types.ts`). Under a node every call goes to the
//! gateway (`remote::RemoteStream`).

use pirc_protocol::{
    AssistantDelta, AssistantMessage, Message, Model, Provider, ThinkingLevel, ToolChoice, ToolSpec,
};

use crate::LocalBoxFuture;
use crate::signal::AbortSignal;

pub struct StreamRequest {
    pub purpose: pirc_protocol::RequestPurpose,
    pub provider_name: String,
    pub provider: Provider,
    pub model: Model,
    pub system_prompt: String,
    pub messages: Vec<Message>,
    pub tools: Vec<ToolSpec>,
    pub thinking: ThinkingLevel,
    pub session_id: String,
    pub signal: AbortSignal,
    pub max_tokens: Option<u64>,
    pub tool_choice: Option<ToolChoice>,
}

/// `StreamFn`: deltas as they come, then the final message. Errors are
/// folded into `stopReason: "error"`, never returned.
pub trait StreamFn {
    fn stream<'a>(
        &'a self,
        request: StreamRequest,
        on_delta: &'a mut dyn FnMut(&AssistantDelta),
    ) -> LocalBoxFuture<'a, AssistantMessage>;
}
