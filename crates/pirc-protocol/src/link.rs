//! Frames on the node link (`/node/connect`), ported from
//! `apps/gateway/src/protocol-schema.ts`.

use indexmap::IndexMap;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::inference::{AssistantDelta, InferenceErrorCode, InferenceRequest, Message};
use crate::mode::{Mode, ModeId};
use crate::models::Models;

/// Node → gateway. `Register` must be the first frame and only the first:
/// the receiver rejects a later one (TS parses registration separately).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(
    tag = "type",
    rename_all = "snake_case",
    rename_all_fields = "camelCase"
)]
pub enum NodeMessage {
    Register(Registration),
    ModelStart {
        request_id: String,
        request: InferenceRequest,
        /// The Node session whose runner capability admitted the request. The
        /// Gateway attributes usage by this, never by `request.session_id`,
        /// which the agent chooses.
        session: String,
    },
    ModelCancel {
        request_id: String,
    },
    Heartbeat,
    /// The answer to a gateway `request`.
    Response {
        request_id: String,
        data: NodeHttpResponse,
    },
    /// A session event, by the node's own session id.
    Event {
        session_id: String,
        event: Map<String, Value>,
    },
    /// Every open run and write lease, sent whole on each change.
    Activity {
        sessions: Vec<SessionActivity>,
    },
    MemoryMirror {
        ledger_key: String,
        offset: u64,
        end: u64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        reset: Option<bool>,
        /// Ledger lines; malformed ones are skipped by the gateway, never fatal.
        lines: Vec<Value>,
    },
    /// An agent's allowlisted gateway operation (`area.action`).
    AgentRequest {
        request_id: String,
        session_id: String,
        op: String,
        #[serde(
            default,
            deserialize_with = "crate::opaque::present",
            skip_serializing_if = "Option::is_none"
        )]
        args: Option<Value>,
    },
    TerminalFrame {
        stream_id: String,
        #[serde(
            default,
            deserialize_with = "crate::opaque::present",
            skip_serializing_if = "Option::is_none"
        )]
        frame: Option<Value>,
    },
    TerminalClosed {
        stream_id: String,
        code: i64,
        reason: String,
    },
}

/// The registration a node sends first.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Registration {
    pub role: NodeRole,
    /// Absent from nodes before versioning (the gateway reads it as 1). Any
    /// integer parses, so another version is a mismatch, not a parse error.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub protocol: Option<i64>,
    pub workspaces: Vec<RegisteredWorkspace>,
    /// Mode ids this node is configured to accept; definitions come only
    /// from the gateway, never from this advertisement.
    pub modes: Vec<ModeId>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum NodeRole {
    Chat,
    Node,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RegisteredWorkspace {
    /// Private recovery root: newer gateway must fence unknown ownership.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub checkpoint_private: bool,
    pub id: String,
    pub display_name: String,
    pub mode: ModeId,
    /// The roles its agents can start in; absent when unknown.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub roles: Option<Vec<WorkspaceRole>>,
    /// Its repository's normalized `origin` ([`crate::normalize_origin`]);
    /// absent without one and from older nodes.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub repo: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct WorkspaceRole {
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub models: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub thinking: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tools: Option<Vec<String>>,
    /// `workspace`: from the workspace's `.pirc/roles`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source: Option<String>,
    /// `node` or `builtin`: the role it replaces.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub overrides: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionActivity {
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub run: Option<SessionRun>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub write_lease: Option<bool>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionRun {
    Queued,
    Running,
    WaitingInput,
    Stopping,
}

/// Gateway → node.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(
    tag = "type",
    rename_all = "snake_case",
    rename_all_fields = "camelCase"
)]
pub enum GatewayMessage {
    ModelDelta {
        request_id: String,
        delta: AssistantDelta,
    },
    /// `message` is always [`Message::Assistant`] (it carries `role`).
    ModelEnd {
        request_id: String,
        message: Message,
    },
    ModelError {
        request_id: String,
        code: InferenceErrorCode,
    },
    RegistrationError {
        status: u16,
        code: String,
        message: String,
    },
    Registered {
        node_id: String,
        models: Models,
        /// Acknowledged workspace-memory ledger offsets, by ledger key.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        mirrors: Option<IndexMap<String, u64>>,
    },
    /// The gateway-owned, validated catalog, after registration and on reload.
    Modes {
        modes: Vec<Mode>,
    },
    MemoryMirrorAck {
        ledger_key: String,
        watermark: u64,
        /// Quota rejection of this exact endpoint; older gateways omit this hint.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        rejected_end: Option<u64>,
    },
    Models {
        models: Models,
    },
    HeartbeatAck,
    /// A browser request to replay on the node's router.
    Request {
        request_id: String,
        data: NodeHttpRequest,
    },
    TerminalOpen {
        stream_id: String,
        user: String,
        session_id: String,
        terminal_id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        kind: Option<TerminalKind>,
    },
    TerminalInput {
        stream_id: String,
        #[serde(
            default,
            deserialize_with = "crate::opaque::present",
            skip_serializing_if = "Option::is_none"
        )]
        message: Option<Value>,
    },
    TerminalClose {
        stream_id: String,
    },
    AgentResponse {
        request_id: String,
        status: u16,
        #[serde(
            default,
            deserialize_with = "crate::opaque::present",
            skip_serializing_if = "Option::is_none"
        )]
        body: Option<Value>,
    },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum TerminalKind {
    Terminal,
    Browser,
}

/// An HTTP request the gateway replays on a node.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NodeHttpRequest {
    pub method: HttpMethod,
    /// Path and query, already rewritten to node-local ids.
    pub url: String,
    /// The authenticated user the gateway acts for.
    pub user: String,
    #[serde(
        default,
        deserialize_with = "crate::opaque::present",
        skip_serializing_if = "Option::is_none"
    )]
    pub payload: Option<Value>,
    /// A raw upload body, base64-encoded, with `content_type`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub body_base64: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub content_type: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "UPPERCASE")]
pub enum HttpMethod {
    Get,
    Post,
    Patch,
    Put,
    Delete,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct NodeHttpResponse {
    pub status: u16,
    /// Absent for an empty (204) response.
    #[serde(
        default,
        deserialize_with = "crate::opaque::present",
        skip_serializing_if = "Option::is_none"
    )]
    pub body: Option<Value>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::round_trip;
    use serde_json::json;

    #[test]
    fn keeps_a_null_payload_distinct_from_none() {
        let with_null = json!({ "type": "request", "requestId": "r",
            "data": { "method": "POST", "url": "/api/x", "user": "u", "payload": null } });
        let parsed = round_trip::<GatewayMessage>(&with_null).unwrap();
        let GatewayMessage::Request { data, .. } = parsed else {
            panic!("request expected");
        };
        assert_eq!(data.payload, Some(Value::Null));
        let without = json!({ "type": "request", "requestId": "r",
            "data": { "method": "GET", "url": "/api/x", "user": "u" } });
        round_trip::<GatewayMessage>(&without).unwrap();
    }

    #[test]
    fn round_trips_node_frames() {
        for frame in [
            json!({ "type": "register", "role": "node", "protocol": 13, "modes": ["directory"],
                "workspaces": [{ "id": "w", "displayName": "W", "mode": "directory",
                    "roles": [{ "name": "default", "source": "workspace" }] }] }),
            json!({ "type": "heartbeat" }),
            json!({ "type": "response", "requestId": "r", "data": { "status": 204 } }),
            json!({ "type": "activity", "sessions": [{ "id": "s", "run": "waiting_input" }] }),
            json!({ "type": "agent_request", "requestId": "r", "sessionId": "s",
                "op": "memory.note" }),
            json!({ "type": "terminal_closed", "streamId": "t", "code": 0, "reason": "exit" }),
        ] {
            round_trip::<NodeMessage>(&frame).unwrap_or_else(|error| panic!("{frame}: {error}"));
        }
    }

    #[test]
    fn round_trips_gateway_frames() {
        for frame in [
            json!({ "type": "heartbeat_ack" }),
            json!({ "type": "modes", "modes": [crate::mode::default_work()] }),
            json!({ "type": "model_delta", "requestId": "r",
                "delta": { "type": "toolcall_end", "contentIndex": 0,
                    "toolCall": { "type": "toolCall", "id": "c", "name": "n", "arguments": {} } } }),
            json!({ "type": "model_error", "requestId": "r", "code": "limit_exceeded" }),
            json!({ "type": "model_end", "requestId": "r", "message": { "role": "assistant",
                "content": [{ "type": "text", "text": "hi" }], "api": "a", "provider": "p",
                "model": "m", "usage": { "input": 1, "output": 1, "cacheRead": 0,
                    "cacheWrite": 0, "totalTokens": 2 }, "stopReason": "stop",
                "timestamp": 1 } }),
            json!({ "type": "terminal_open", "streamId": "s", "user": "u", "sessionId": "x",
                "terminalId": "browser", "kind": "browser" }),
            json!({ "type": "agent_response", "requestId": "r", "status": 200,
                "body": { "result": 1 } }),
        ] {
            round_trip::<GatewayMessage>(&frame).unwrap_or_else(|error| panic!("{frame}: {error}"));
        }
    }
}
