//! A pot's point of view (plans/pots.md, Activity and point of view), read
//! only: the threads it can see and the messages it sent. The user reads it;
//! nothing here lets the user send as the pot.

use rusqlite::{Connection, OptionalExtension, params};
use serde::Serialize;

use super::store;
use super::threads::{self, Message, Thread};
use crate::error::{ApiError, ApiResult};

pub const PAGE: i64 = 50;

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct View {
    pub pot_id: String,
    pub threads: Vec<Thread>,
    /// Messages the pot wrote, newest first.
    pub sent: Vec<Message>,
    /// Pass as `before` for older sent messages; absent on the last page.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub next_before: Option<String>,
}

pub fn view(conn: &Connection, owner: &str, pot_id: &str, before: Option<&str>) -> ApiResult<View> {
    store::read(conn, owner, pot_id)?;
    let threads: Vec<Thread> = threads::list(conn, owner)?
        .into_iter()
        .filter(|thread| thread.pots.iter().any(|p| p == pot_id))
        .collect();
    let cursor = match before {
        Some(id) => Some(
            conn.query_row(
                "SELECT m.created_at, m.rowid FROM messages m JOIN threads t ON t.id=m.thread_id
                 WHERE m.id=?1 AND t.owner_user=?2 AND m.author_kind='pot' AND m.author_id=?3",
                params![id, owner, pot_id],
                |r| Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?)),
            )
            .optional()?
            .ok_or_else(|| ApiError::new(400, "invalid_input", "Unknown page cursor"))?,
        ),
        None => None,
    };
    let (at, rowid) = cursor.unwrap_or((i64::MAX, i64::MAX));
    let ids: Vec<String> = conn
        .prepare(
            "SELECT m.id FROM messages m JOIN threads t ON t.id=m.thread_id
             WHERE t.owner_user=?1 AND m.author_kind='pot' AND m.author_id=?2
               AND (m.created_at<?3 OR (m.created_at=?3 AND m.rowid<?4))
             ORDER BY m.created_at DESC, m.rowid DESC LIMIT ?5",
        )?
        .query_map(params![owner, pot_id, at, rowid, PAGE + 1], |r| r.get(0))?
        .collect::<Result<_, _>>()?;
    let mut sent = ids
        .iter()
        .map(|id| threads::message(conn, id))
        .collect::<ApiResult<Vec<_>>>()?;
    let next_before = if sent.len() > PAGE as usize {
        sent.truncate(PAGE as usize);
        sent.last().map(|m| m.id.clone())
    } else {
        None
    };
    Ok(View {
        pot_id: pot_id.to_owned(),
        threads,
        sent,
        next_before,
    })
}
