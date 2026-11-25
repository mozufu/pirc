//! A pot's own memory (plans/pots.md, Runtime: Memory; P8): notes keyed by the
//! pot, never shared with another pot and deleted with it. The pot writes them
//! with `memory_note` and finds them with `memory_search`; its prompt starts
//! with them. The user can read them and forget any. Pots read the user's
//! approved USER entries but never write the user's memory.

use rusqlite::{Connection, OptionalExtension, Row, params};
use serde::{Deserialize, Serialize};

use super::store;
use crate::error::{ApiError, ApiResult};
use crate::util::{new_id, now_ms};

/// The longest note, in characters.
pub const MAX_NOTE: usize = 2000;
/// All of a pot's notes together, in characters: what its prompt can carry.
pub const BUDGET: usize = 20_000;
pub const MAX_NOTES: i64 = 200;
const MAX_HITS: usize = 20;

fn invalid(message: &str) -> ApiError {
    ApiError::new(400, "invalid_input", message)
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Note {
    pub id: String,
    pub content: String,
    pub revision: i64,
    pub created_at: i64,
    pub updated_at: i64,
}

fn note_row(r: &Row) -> rusqlite::Result<Note> {
    Ok(Note {
        id: r.get(0)?,
        content: r.get(1)?,
        revision: r.get(2)?,
        created_at: r.get(3)?,
        updated_at: r.get(4)?,
    })
}

/// The pot's notes, oldest first.
pub fn list(conn: &Connection, owner: &str, pot_id: &str) -> ApiResult<Vec<Note>> {
    store::read(conn, owner, pot_id)?;
    Ok(conn
        .prepare(
            "SELECT id,content,revision,created_at,updated_at FROM pot_memory
             WHERE pot_id=?1 ORDER BY created_at, rowid",
        )?
        .query_map([pot_id], note_row)?
        .collect::<Result<_, _>>()?)
}

fn used(conn: &Connection, pot_id: &str, except: Option<&str>) -> ApiResult<usize> {
    let lengths: Vec<String> = conn
        .prepare("SELECT content FROM pot_memory WHERE pot_id=?1 AND id IS NOT ?2")?
        .query_map(params![pot_id, except], |r| r.get(0))?
        .collect::<Result<_, _>>()?;
    Ok(lengths.iter().map(|text| text.chars().count()).sum())
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Action {
    Add,
    Update,
    Remove,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct NoteInput {
    pub action: Action,
    #[serde(default)]
    pub id: Option<String>,
    #[serde(default)]
    pub content: Option<String>,
    /// The revision the pot last saw, for update and remove.
    #[serde(default)]
    pub base_revision: Option<i64>,
}

/// What a note write did, with what is left of the budget.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Written {
    pub note: Option<Note>,
    pub removed: bool,
    pub used: usize,
    pub budget: usize,
}

fn content(input: &NoteInput) -> ApiResult<String> {
    let text = input.content.as_deref().unwrap_or_default().trim();
    if text.is_empty() || text.chars().count() > MAX_NOTE {
        return Err(invalid("A note is 1 to 2000 characters"));
    }
    Ok(text.to_owned())
}

fn current(conn: &Connection, pot_id: &str, input: &NoteInput) -> ApiResult<Note> {
    let id = input
        .id
        .as_deref()
        .ok_or_else(|| invalid("id is required"))?;
    let note = conn
        .query_row(
            "SELECT id,content,revision,created_at,updated_at FROM pot_memory WHERE id=?1 AND pot_id=?2",
            params![id, pot_id],
            note_row,
        )
        .optional()?
        .ok_or_else(|| ApiError::not_found("No such note in your memory"))?;
    if input
        .base_revision
        .is_some_and(|seen| seen != note.revision)
    {
        return Err(ApiError::new(
            409,
            "revision_conflict",
            "The note changed since you read it; search again",
        ));
    }
    Ok(note)
}

/// The pot adds, updates or removes one of its own notes.
pub fn write(conn: &Connection, owner: &str, pot_id: &str, input: NoteInput) -> ApiResult<Written> {
    store::read(conn, owner, pot_id)?;
    let stamp = now_ms();
    let (note, removed) = match input.action {
        Action::Add => {
            let text = content(&input)?;
            let count: i64 = conn.query_row(
                "SELECT count(*) FROM pot_memory WHERE pot_id=?1",
                [pot_id],
                |r| r.get(0),
            )?;
            if count >= MAX_NOTES {
                return Err(ApiError::new(
                    409,
                    "memory_full",
                    "Your memory has the most notes allowed; remove some",
                ));
            }
            if used(conn, pot_id, None)? + text.chars().count() > BUDGET {
                return Err(ApiError::new(
                    409,
                    "memory_full",
                    "Your memory is full; shorten or remove notes",
                ));
            }
            let id = new_id("mem");
            conn.execute(
                "INSERT INTO pot_memory(id,pot_id,content,revision,created_at,updated_at) VALUES(?1,?2,?3,1,?4,?4)",
                params![id, pot_id, text, stamp],
            )?;
            (Some(id), false)
        }
        Action::Update => {
            let note = current(conn, pot_id, &input)?;
            let text = content(&input)?;
            if used(conn, pot_id, Some(&note.id))? + text.chars().count() > BUDGET {
                return Err(ApiError::new(
                    409,
                    "memory_full",
                    "Your memory is full; shorten or remove notes",
                ));
            }
            conn.execute(
                "UPDATE pot_memory SET content=?2, revision=revision+1, updated_at=?3 WHERE id=?1",
                params![note.id, text, stamp],
            )?;
            (Some(note.id), false)
        }
        Action::Remove => {
            let note = current(conn, pot_id, &input)?;
            conn.execute("DELETE FROM pot_memory WHERE id=?1", [&note.id])?;
            (None, true)
        }
    };
    let note = match note {
        Some(id) => Some(conn.query_row(
            "SELECT id,content,revision,created_at,updated_at FROM pot_memory WHERE id=?1",
            [&id],
            note_row,
        )?),
        None => None,
    };
    Ok(Written {
        note,
        removed,
        used: used(conn, pot_id, None)?,
        budget: BUDGET,
    })
}

/// The pot's notes holding the most of the query's words, best first; words
/// match anywhere, ignoring case.
pub fn search(
    conn: &Connection,
    owner: &str,
    pot_id: &str,
    query: &str,
    limit: Option<usize>,
) -> ApiResult<Vec<Note>> {
    let words: Vec<String> = query
        .split_whitespace()
        .map(str::to_lowercase)
        .filter(|word| !word.is_empty())
        .take(20)
        .collect();
    if words.is_empty() || query.chars().count() > 500 {
        return Err(invalid("A search is 1 to 500 characters"));
    }
    let limit = limit.unwrap_or(10).clamp(1, MAX_HITS);
    let mut scored: Vec<(usize, Note)> = list(conn, owner, pot_id)?
        .into_iter()
        .filter_map(|note| {
            let text = note.content.to_lowercase();
            let hits = words
                .iter()
                .filter(|word| text.contains(word.as_str()))
                .count();
            (hits > 0).then_some((hits, note))
        })
        .collect();
    scored.sort_by(|a, b| b.0.cmp(&a.0).then(b.1.updated_at.cmp(&a.1.updated_at)));
    Ok(scored
        .into_iter()
        .take(limit)
        .map(|(_, note)| note)
        .collect())
}

/// The user forgets one of the pot's notes.
pub fn forget(conn: &Connection, owner: &str, pot_id: &str, id: &str) -> ApiResult<()> {
    store::read(conn, owner, pot_id)?;
    if conn.execute(
        "DELETE FROM pot_memory WHERE id=?1 AND pot_id=?2",
        params![id, pot_id],
    )? == 0
    {
        return Err(ApiError::not_found("Note not found"));
    }
    Ok(())
}
