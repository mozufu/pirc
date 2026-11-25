//! The assistant's memory (`apps/gateway/src/daemon/memory.ts`,
//! `memory-interactions.ts`, `memory-routes.ts`) and its agent operations
//! (`assistant.context`, `memory.note`, `memory.proposeUser`,
//! `memory.search`, `recall.remote` in `agent-ops.ts`).

mod interactions;
mod ops;
mod provenance;
mod routes;
pub(crate) mod schema;
mod store;
pub(crate) mod text;

use axum::Router;
use rusqlite::Connection;
use serde_json::Value;

use crate::agent_ops::OpContext;
use crate::app::{App, AppState};
use crate::error::ApiResult;

pub use ops::Op;
pub use store::{Budgets, Store};

/// The memory store over `conn`, with the configured budgets.
pub fn store<'a>(app: &App, conn: &'a Connection) -> Store<'a> {
    Store::new(
        conn,
        Budgets {
            user: app.config.memory_budget_user,
            note: app.config.memory_budget_note,
        },
    )
}

pub fn parse_op(op: &str, args: &Value) -> Option<Result<Op, ()>> {
    ops::parse_op(op, args)
}

pub async fn run_op(app: &AppState, context: &OpContext, op: Op) -> ApiResult<Value> {
    ops::run_op(app, context, op).await
}

/// `/api/memory*`.
pub fn routes() -> Router<AppState> {
    routes::routes()
}

/// Forget what memory learned from a deleted chat (`MemoryStore.forgetSession`),
/// inside the deletion's transaction.
pub fn forget_session(app: &App, conn: &Connection, user: &str, session_id: &str) -> ApiResult<()> {
    interactions::ensure_known(app, conn);
    store(app, conn).forget_session(user, session_id)
}

/// The user's memory changed (`MemoryInteractions.changed`): its pending
/// proposals' interactions are published to their sessions. Hints are the caller's.
pub fn changed(app: &App, user: &str) {
    interactions::changed(app, user);
}

/// Pending USER-memory proposals of the session, as interactions.
pub fn pending_interactions(app: &App, session_id: &str, user: &str) -> Vec<Value> {
    let conn = app.db.lock();
    interactions::pending(&store(app, &conn), session_id, user).unwrap_or_default()
}

/// Answer a memory proposal's interaction; `None` when it is not one.
pub fn answer(
    app: &App,
    session_id: &str,
    interaction_id: &str,
    user: &str,
    answer: Option<&Value>,
) -> ApiResult<Option<Value>> {
    interactions::answer(app, session_id, interaction_id, user, answer)
}

#[cfg(test)]
pub(crate) mod tests;
