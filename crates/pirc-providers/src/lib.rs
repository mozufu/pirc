//! Model transports and the gateway's `models.json`, ported from the TS
//! gateway (`backends/inference.ts`, `backends/pi-adapter.ts`, `models.ts`,
//! `agent/providers/openai-chat.ts`) and the parts of pi-ai 0.73.1 and the
//! `openai` SDK they use.
//!
//! Transports: pi-ai's `openai-completions` (also used for `openai-chat`
//! providers routed through Pi), `anthropic-messages`, `openai-responses`
//! and `openai-codex-responses`, and the native `openai-chat` and
//! `anthropic-messages` transports ([`Inference::run`] picks one as
//! `GatewayInference` did). Wire mechanics live in `pirc-llm`; this crate
//! retains gateway policy and safe adapters. [`backends`] is the settings store.

pub mod backends;
mod catalog;
mod errors;
mod http;
mod inference;
mod js;
mod models_file;
mod stream;

pub use catalog::{
    CatalogModel, ModelCost, catalog_models, catalog_price, catalog_providers, catalog_version,
};
pub use errors::safe_inference_error;
pub use inference::{Inference, Resolve, Resolved};
pub use models_file::{ModelsFile, expand_home, list_models, load_models_file, public_models};
