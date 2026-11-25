//! Black-box conformance harness for the pirc executables.
//!
//! Tests start real `pirc-gateway` and `pirc-node` executables from
//! `PIRC_CONFORMANCE_BIN_DIR` and talk to them only over HTTP and WebSocket,
//! so the same scenarios run against the TypeScript build (whose behavior the
//! committed snapshots record) and the Rust build that replaces it.
//!
//! Without `PIRC_CONFORMANCE_BIN_DIR` at build time the tests that need the
//! executables are ignored (see `build.rs`), so `cargo test` reports them as
//! ignored rather than passed. `PIRC_CONFORMANCE_REQUIRED` makes that a failure.

mod agent;
mod client;
mod cluster;
mod fake_gateway;
mod fake_llm;
mod fake_push;
mod first_send;
mod normalize;

pub use agent::{
    AgentOptions, AgentRun, Answers, Gate, ModelReply, Recorder, Responder, fake_models,
};
pub use client::{Api, Connection, Response, WebSocket};
pub use cluster::{
    CHATS_WORKSPACE_ID, Cluster, FAKE_SRT_CONTROL_LOG, GatewayOptions, HOST, LoneNode, NODE_ID,
    NODE_TOKEN, NodeOptions, ORIGIN, TARGET_WORKSPACE_ID, USER, WORKSPACE_ID, bin_dir,
    write_executable,
};
pub use fake_gateway::{FakeGateway, NodeLink, assert_gateway_frame, assert_node_frame};
pub use fake_llm::{FakeLlm, ModelsReply, Reply};
pub use fake_push::{FakePush, PushSubscription};
pub use first_send::{FirstSend, Started, serve_first_send_idle};
pub use normalize::{Normalizer, Transcript, mask_background_log_dir};

/// Headers a trusted proxy adds to an authenticated browser request.
/// The client API version the Gateway under test serves (`X-Pirc-Client`).
pub const CLIENT: &str = "conformance/2";

pub fn browser_headers() -> Vec<(&'static str, String)> {
    vec![
        ("host", HOST.to_owned()),
        ("origin", ORIGIN.to_owned()),
        ("x-pirc-user", USER.to_owned()),
        ("x-pirc-client", CLIENT.to_owned()),
    ]
}
