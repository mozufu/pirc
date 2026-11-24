//! Wire types shared by the gateway, the node and the agent, ported from
//! `apps/gateway/src/protocol.ts`, `protocol-schema.ts`, `inference-wire.ts`
//! and `models.ts`.
//!
//! These are shapes only. Size and length limits (`.max()` in the zod
//! schemas) are the receiving endpoint's to enforce. Payloads the TS schemas
//! keep opaque (`z.unknown()`) stay [`serde_json::Value`] here, and an opaque
//! field that is present but `null` stays distinct from an absent one.
//! Numbers are typed narrower than zod's `number` (HTTP statuses as `u16`,
//! token counts and timestamps as `u64`): a receiver treats a frame that does
//! not parse as invalid, as TS does one that fails its schema.

mod inference;
mod link;
pub mod mode;
mod models;
mod repo;
mod socket_path;

pub use inference::{
    AssistantContent, AssistantDelta, AssistantMessage, INFERENCE_BUFFER_MAX_BYTES,
    INFERENCE_MAX_REQUESTS, INFERENCE_REQUEST_MAX_BYTES, INFERENCE_STREAM_MAX_BYTES,
    INFERENCE_TIMEOUT_MS, InferenceErrorCode, InferenceRequest, Message, StopReason, ToolChoice,
    ToolSpec, Usage, UserBlock, UserContent,
};
pub use link::{
    GatewayMessage, HttpMethod, NodeHttpRequest, NodeHttpResponse, NodeMessage, NodeRole,
    PotsControl, PotsOperation, PotsRequest, RegisteredWorkspace, Registration, SessionActivity,
    SessionRun, TerminalKind, WorkspaceRole,
};
pub use mode::{Mode, ModeId};
pub use models::{InferenceConfig, Model, ModelApi, ModelRef, Models, Provider, ThinkingLevel};
pub use repo::{REPO_MAX_CHARS, normalize_origin, valid_repo};
pub use socket_path::SocketPath;

use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::Value;

/// Both sides must speak the same version; the gateway closes a node that
/// registers with another one with [`PROTOCOL_MISMATCH_CLOSE`].
pub const NODE_PROTOCOL_VERSION: u32 = 16;
/// Close code for a node that speaks another protocol version.
pub const PROTOCOL_MISMATCH_CLOSE: u16 = 4426;

/// WebSocket close code the gateway sends a node whose `x-pirc-node-id` and
/// bearer token match no entry of its `PIRC_NODE_TOKENS`.
pub const INVALID_NODE_CREDENTIALS_CLOSE: u16 = 4401;
/// Largest WebSocket frame on the node link.
pub const NODE_FRAME_MAX_BYTES: usize = 16_777_216;
/// Browser recordings cross the node link in base64 chunks of this many bytes.
pub const RECORDING_CHUNK_BYTES: usize = 4 * 1024 * 1024;
/// The identity header of a request replayed on a node's router; set only by
/// the node's link from the `request` frame's `user`.
pub const NODE_USER_HEADER: &str = "x-pirc-user";

/// Agent → gateway channel (`agent_request`): an allowlisted `area.action`
/// operation, at most this long.
pub const AGENT_OP_MAX_LENGTH: usize = 64;
/// Serialized `args` of one agent request.
pub const AGENT_REQUEST_MAX_BYTES: usize = 65_536;
/// How long a node waits for the gateway's answer before answering
/// `gateway_timeout` itself.
pub const AGENT_REQUEST_TIMEOUT_MS: u64 = 30_000;
/// Raw workspace-memory ledger bytes per `memory_mirror` frame.
pub const MIRROR_CHUNK_BYTES: usize = 262_144;

/// `AGENT_OP_PATTERN`, `^[a-z][a-zA-Z0-9]*(?:\.[a-z][a-zA-Z0-9]*)+$`. The
/// length limit ([`AGENT_OP_MAX_LENGTH`]) is checked separately.
pub fn valid_agent_op(op: &str) -> bool {
    let mut parts = op.split('.');
    let valid = |part: &str| {
        let mut bytes = part.bytes();
        bytes.next().is_some_and(|b| b.is_ascii_lowercase())
            && bytes.all(|b| b.is_ascii_alphanumeric())
    };
    parts.next().is_some_and(valid) && {
        let mut rest = parts.peekable();
        rest.peek().is_some() && rest.all(valid)
    }
}

/// Parse `value` as `T` and serialize it back; `Err` shows both when they
/// differ. Used to check these types against frames real executables send.
/// The comparison ignores key order: a struct's field order means nothing,
/// and the order of the free-form maps (providers, tool schemas, arguments)
/// is kept by `IndexMap` and `serde_json`'s `preserve_order`, which unit tests
/// check.
pub fn round_trip<T: Serialize + DeserializeOwned>(value: &Value) -> Result<T, String> {
    let parsed: T = serde_json::from_value(value.clone()).map_err(|error| error.to_string())?;
    let back = serde_json::to_value(&parsed).map_err(|error| error.to_string())?;
    if &back == value {
        Ok(parsed)
    } else {
        Err(format!("re-serialized as {back}\nexpected {value}"))
    }
}

/// `#[serde(deserialize_with)]` for opaque optional fields: a present `null`
/// is `Some(Value::Null)`, an absent field (with `default`) is `None`.
pub(crate) mod opaque {
    use serde::{Deserialize, Deserializer};
    use serde_json::Value;

    pub fn present<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Option<Value>, D::Error> {
        Value::deserialize(deserializer).map(Some)
    }
}

#[cfg(test)]
mod tests {
    use super::valid_agent_op;

    #[test]
    fn agent_ops() {
        for op in ["memory.note", "a.b.c", "schedule.createOne", "x1.y2"] {
            assert!(valid_agent_op(op), "{op}");
        }
        for op in [
            "memory", "", ".a", "a.", "a..b", "A.b", "a.B", "1a.b", "a_b.c", "a.b-c",
        ] {
            assert!(!valid_agent_op(op), "{op}");
        }
    }
}
