//! `pirc-node`, rewritten in Rust (docs/development/historical-records.md): the node
//! process of `apps/gateway/src/node/**` (both roles: `pirc-node` runs a
//! coding node, `pirc-node chat` the chat node) next to the session agent
//! (`pirc-node agent`, `pirc_agent`) and the PTC guest (`pirc-node
//! ptc-guest`, `pirc_ptc`).
//!
//! The node never listens on a port: it connects out to the gateway and
//! answers relayed requests through its own router. Its agents run as
//! sandboxed subprocesses speaking JSONL RPC, and reach models through the
//! node's inference socket.
//!
//! # Modules and owners
//!
//! M6 is ported in four parallel worktrees, each owning a disjoint set of
//! files; the layout commit fixed the interfaces between them. Shared files
//! (marked layout) change only by agreement.
//!
//! | module | ports | owner |
//! | --- | --- | --- |
//! | `main.rs`, [`cli`] | `entry/common.ts`, `entry/node-runtime.ts` | layout |
//! | [`error`], [`util`], [`log`] | `errors.ts`, `util.ts`, the logger | layout |
//! | [`events`] | `events.ts` | layout |
//! | [`models`] | `models.ts` `ModelStore` | layout |
//! | [`router`] | Fastify and `app.inject` | layout (matching), core ([`router::Router::handle`]) |
//! | [`link`] | `node/runtime.ts` (link) | layout ([`link::LinkSender`]), core ([`link::run`]) |
//! | [`browser`] | `node/browser.ts`, `node/browser-hosts.ts`, `node/browser-extract.ts` (in-page helpers), `node/browser-executable.ts` (in `pirc_config::node`); Playwright 1.63.0 in `browser::engine` | M8 (manager, core, netio, locator) |
//! | [`store`] | `database.ts` (node half), `schema.sql` | layout (open, rows), core (queries) |
//! | [`services`], [`node`] | `buildNodeApp`, `startNode`, `node/main.ts` | core |
//! | [`app`], [`chat`], [`assistant_prompts`] | `node/app.ts`, `node/chat.ts`, `assistant-prompts.ts`, `session-name.ts` | core |
//! | [`runner`] (`framing`, `reducer`) | `node/runner.ts`, `rpc-framing.ts`, `reducer.ts` | runner |
//! | [`inference`] | `node/inference.ts` | runner |
//! | [`write_broker`], [`agent_gateway`], [`branch_cache`], [`recap`] | the `node/` files of those names | runner |
//! | `pirc_config::env_allowlist` | `env-allowlist.ts`, `node/secrets.ts` | runner |
//! | [`panels`] (`inspect`) | `node/panel-routes.ts`, `node/inspect.ts` | panels |
//! | [`terminals`], [`streams`], [`memory_mirror`] | `node/terminals.ts`, the stream mux of `node/runtime.ts`, `node/memory-mirror.ts` | panels |
//! | [`sandbox`] (`srt`, `linux`, `bridge`, `unavailable`) | `node/sandbox.ts`, `spikes/linux-sandbox` | layout (trait, [`sandbox::Prepared`]), sandbox (backends) |
//! | `pirc_policy::session` | `sandbox-policy.ts` `sessionPolicy` and friends, `readAgentConfig` | sandbox |
//! | `pirc_config::node` | `config.ts` (node half) | layout |
//!
//! Conventions: the runtime is tokio's multi-threaded one, so route
//! handlers and everything they await are `Send`; nothing holds the store's
//! lock across an `await`; components reach each other through
//! [`services::Node`]; agent-visible and client-visible texts are TS's.

pub mod agent_gateway;
pub mod app;
pub mod assistant_prompts;
pub mod branch_cache;
pub mod browser;
pub mod chat;
pub mod checkpoints;
pub mod cli;
pub mod command_environment;
pub mod error;
pub mod events;
pub mod execution_fences;
pub mod grants;
mod host_commands;
pub mod inference;
pub mod link;
pub mod log;
pub mod memory_mirror;
pub mod models;
pub mod node;
pub mod panels;
#[doc(hidden)]
pub mod persistence;
pub mod private_dir;
mod process_journal;
pub mod project_files;
pub mod recap;
pub mod repo;
pub mod router;
pub mod runner;
pub mod sandbox;
pub mod services;
pub mod session_creation;
pub mod store;
pub mod streams;
pub mod terminals;
#[cfg(test)]
mod test_support;
pub mod upload_origins;
pub mod util;
pub mod write_broker;

use std::process::ExitCode;

use pirc_config::{Env, NodeConfig};
use pirc_protocol::NodeRole;

/// Run the node in `role` until it is told to stop: load the configuration
/// (a bad one is printed and exits 1), then [`node::run`].
pub fn run_role(role: NodeRole) -> ExitCode {
    // Before any thread or child: nothing the node was started with (a
    // terminal's PTY, say) reaches what it spawns (`sandbox::fds`).
    sandbox::fds::close_inherited();
    let env = Env::from_process();
    let config = match NodeConfig::load(&env, role) {
        Ok(config) => config,
        Err(error) => {
            eprintln!("pirc-node: {error}");
            return ExitCode::FAILURE;
        }
    };
    let runtime = match tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
    {
        Ok(runtime) => runtime,
        Err(error) => {
            eprintln!("pirc-node: cannot start the runtime: {error}");
            return ExitCode::FAILURE;
        }
    };
    match runtime.block_on(node::run(config, env)) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("pirc-node: {error}");
            ExitCode::FAILURE
        }
    }
}

pub mod workspace_memory;
