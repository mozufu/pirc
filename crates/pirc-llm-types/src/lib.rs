//! Pure serializable model/message DTOs, extracted from pirc-protocol without
//! changing their wire representation. No runtime, HTTP, OAuth, environment or
//! credential persistence is provided here.
//!
//! [`Provider`] and [`Model`] intentionally retain the existing endpoint/header
//! configuration fields for type identity and byte compatibility. They are not
//! guaranteed secret-free: hosts must redact and project them before disclosure.
//! Splitting credential configuration from model metadata is not part of this
//! compatibility checkpoint. Routing envelopes and local socket configuration
//! remain owned by pirc-protocol.
//!
//! JSON object insertion order and absent-versus-null opaque details are part of
//! the serialization contract. `serde_json/preserve_order` is enabled directly by
//! this crate's dependency, including for consumers outside the pirc workspace.

mod inference;
mod models;

pub use inference::{
    AssistantContent, AssistantDelta, AssistantMessage, InferenceErrorCode, Message, StopReason,
    ToolChoice, ToolSpec, Usage, UserBlock, UserContent,
};
pub use models::{
    Model, ModelApi, ModelRef, Provider, THINKING_LEVELS, ThinkingLevel, effective_thinking_level,
    model_thinking_levels, supports_thinking_level,
};

/// Preserve explicit null separately from an absent opaque field.
mod opaque {
    use serde::{Deserialize, Deserializer};
    use serde_json::Value;

    pub fn present<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Option<Value>, D::Error> {
        Value::deserialize(deserializer).map(Some)
    }
}
