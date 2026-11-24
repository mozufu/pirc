//! Durable bounded pots tracking and explicit one-shot execution.
//! Only authenticated host events may call ingest_progress/resolve_progress.
mod api;
mod execution;
pub use execution::start;
pub mod host;
pub use api::routes;
mod store;
pub use store::*;
#[cfg(test)]
mod api_tests;
#[cfg(test)]
#[cfg(test)]
mod tests;
