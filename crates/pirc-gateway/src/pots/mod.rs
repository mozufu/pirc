//! Multiple named pots (plans/pots.md). Built in the steps of roadmap M4.

pub mod activity;
pub mod api;
pub mod approvals;
pub mod autonomy;
pub mod budget;
pub mod delivery;
pub mod guard;
pub mod handover;

/// `images::require_owned` and `images::release`, re-exported for threads.
fn images_owned(conn: &rusqlite::Connection, owner: &str, id: &str) -> crate::error::ApiResult<()> {
    crate::images::require_owned(conn, owner, id)
}

fn images_release(conn: &rusqlite::Connection, id: Option<&str>) -> crate::error::ApiResult<()> {
    crate::images::release(conn, id)
}
pub mod memory;
pub mod observe;
pub mod ops;
pub mod retire;
pub mod roots;
pub mod runtime;
pub mod store;
pub mod threads;
pub mod view;
pub mod work;

#[cfg(test)]
mod tests;
