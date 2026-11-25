//! The evidence a recap is written from (`node/recap.ts` `collectRecap`):
//! the agent's `gateway_request` with op `recap.collect` is answered here,
//! on the node, from the session files of the same owner's other sessions
//! in the same directory workspace. Owner: **runner**.
//!
//! The model call is the agent's (its recap feature); this only reads,
//! bounded and redacted (`pirc_agent::redact`), with every limit in UTF-16
//! units as TS counts them. The TS query also excluded sessions started by
//! schedules through the gateway's tables, which a node's
//! store never filled; those exclusions are dropped, the node-local
//! markers (`scheduled-run` entries) stay. Golden
//! cases: `node-recap.test.ts`.
//!
//! Its queries are its own (run on `node.db.lock()`, released before any
//! file is read); the file reads are blocking, so the runner calls this
//! off the async workers.

use std::collections::{HashMap, HashSet};
use std::fs::File;
use std::io::Read;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Component, Path, PathBuf};

use nix::fcntl::OFlag;
use pirc_agent::messages::js::{stringify, trim, utf16_len, utf16_prefix};
use pirc_agent::redact::redact_secrets;
use rusqlite::{Connection, OptionalExtension};
use serde_json::{Map, Value, json};

use crate::error::{ApiError, ApiResult};
use crate::runner::reducer::js_string;
use crate::services::Node;
use crate::util::now_ms;

const MAX_FILE: u64 = 4 * 1024 * 1024;
const MAX_SCAN: u64 = 32 * 1024 * 1024;
const MAX_OUTPUT: usize = 80_000;
const MAX_SESSIONS: usize = 20;
const MAX_ENTRIES: usize = 20_000;
const MAX_TEXT: usize = 1800;
const MAX_SESSION_JSON: usize = 5000;
const DAY_MS: i64 = 86_400_000;
const SAMPLING: &str = "Bounded sample of recent owned sessions in this exact workspace; active branch only, user text prioritized. Entire recap-marked, oversized, malformed, or changing sessions are excluded. Not full history coverage. Redaction is best-effort.";
const BACKGROUND_TYPES: [&str; 1] = ["scheduled-run"];

/// `collectRecap(db, sessionId, args)`: the evidence object, or the error
/// the agent gets (`args` must be `{days?: 1..90}`, strict).
pub fn collect_recap(node: &Node, session_id: &str, args: &Value) -> ApiResult<Value> {
    let scope = {
        let db = node.db.lock();
        scope(&db, session_id, args, now_ms())?
    };
    Ok(scope.collect())
}

/// `argsSchema`: `{days: int 1..90 = 14}`, strict.
fn days(args: &Value) -> Option<i64> {
    let Value::Object(args) = args else {
        return None;
    };
    if args.keys().any(|key| key != "days") {
        return None;
    }
    match args.get("days") {
        None => Some(14),
        Some(Value::Number(days)) => days
            .as_f64()
            .filter(|days| days.fract() == 0.0 && (1.0..=90.0).contains(days))
            .map(|days| days as i64),
        Some(_) => None,
    }
}

/// What a recap reads: decided under the store's lock, read without it.
pub(crate) struct Scope {
    workspace_id: String,
    root: String,
    days: i64,
    since: i64,
    until: i64,
    /// `(session id, private directory)`, newest first, at most 21.
    rows: Vec<(String, String)>,
}

/// A store failure: TS answered anything thrown that was not an
/// `ApiError` with 500 `recap_failed` (not the routes' `internal_error`).
fn recap_failed(error: rusqlite::Error) -> ApiError {
    crate::log::error(&format!("recap: {error}"));
    ApiError::new(
        500,
        "recap_failed",
        "Could not collect workspace recap evidence",
    )
}

pub(crate) fn scope(db: &Connection, session_id: &str, args: &Value, now: i64) -> ApiResult<Scope> {
    let days = days(args)
        .ok_or_else(|| ApiError::bad_request("Recap accepts only days (integer 1–90)"))?;
    let (workspace_id, owner): (String, Option<String>) = db
        .query_row(
            "SELECT workspace_id, owner_user FROM sessions WHERE id = ?",
            [session_id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()
        .map_err(recap_failed)?
        .ok_or_else(|| ApiError::not_found("Session not found"))?;
    let (kind, root): (String, String) = db
        .query_row(
            "SELECT kind, canonical_path FROM workspaces WHERE id = ?",
            [&workspace_id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()
        .map_err(recap_failed)?
        .ok_or_else(|| ApiError::not_found("Workspace not found"))?;
    if kind != "directory" {
        return Err(ApiError::bad_request(
            "Recap requires a directory workspace",
        ));
    }
    let Some(owner) = owner.filter(|owner| !owner.is_empty()) else {
        return Err(ApiError::forbidden("Recap requires a known session owner"));
    };
    let until = now;
    let since = until - days * DAY_MS;
    let mut statement = db
        .prepare(
            "SELECT id, private_session_path FROM sessions
         WHERE workspace_id = ? AND owner_user = ? AND id <> ? AND updated_at >= ?
         ORDER BY updated_at DESC, id DESC LIMIT 21",
        )
        .map_err(recap_failed)?;
    let rows = statement
        .query_map(
            rusqlite::params![workspace_id, owner, session_id, since],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .map_err(recap_failed)?
        .collect::<Result<Vec<(String, String)>, _>>()
        .map_err(recap_failed)?;
    Ok(Scope {
        workspace_id,
        root,
        days,
        since,
        until,
        rows,
    })
}

/// A session that is skipped, with its reason (TS threw `Error(reason)`).
type Skip = &'static str;

/// `noSymlinks`: reject every symlink component, not only the final file.
fn no_symlinks(file: &Path) -> Result<(), Skip> {
    if !file.is_absolute() {
        return Err("unsafe_path");
    }
    let parts: Vec<_> = file
        .components()
        .filter_map(|component| match component {
            Component::Normal(part) => Some(part),
            _ => None,
        })
        .collect();
    let mut cursor = PathBuf::from("/");
    for (index, part) in parts.iter().enumerate() {
        cursor.push(part);
        // A missing or unreadable component is no reason of ours.
        let stat = std::fs::symlink_metadata(&cursor).map_err(|_| "unreadable_session")?;
        if stat.file_type().is_symlink() || (index < parts.len() - 1 && !stat.is_dir()) {
            return Err("unsafe_path");
        }
    }
    Ok(())
}

/// A session file entry that passed `entrySchema`.
struct Entry {
    id: String,
    parent_id: Option<String>,
    timestamp: f64,
    value: Map<String, Value>,
}

fn record(value: Option<&Value>) -> Option<&Map<String, Value>> {
    value.and_then(Value::as_object)
}

/// `entrySchema` (passthrough).
fn entry(value: Value) -> Option<Entry> {
    let Value::Object(value) = value else {
        return None;
    };
    let id_like = |text: &str| (1..=128).contains(&utf16_len(text));
    let id = value
        .get("id")?
        .as_str()
        .filter(|id| id_like(id))?
        .to_owned();
    let parent_id = match value.get("parentId")? {
        Value::Null => None,
        Value::String(parent) if id_like(parent) => Some(parent.clone()),
        _ => return None,
    };
    let timestamp = value.get("timestamp")?.as_f64().filter(|t| *t >= 0.0)?;
    value.get("type")?.as_str()?;
    Some(Entry {
        id,
        parent_id,
        timestamp,
        value,
    })
}

/// `branch(text, root)`: the active branch, header first.
fn branch(text: &str, root: &str) -> Result<Vec<Entry>, Skip> {
    let mut entries: Vec<Entry> = Vec::new();
    let mut by_id: HashMap<String, usize> = HashMap::new();
    for line in text.split('\n') {
        if trim(line).is_empty() {
            continue;
        }
        if entries.len() >= MAX_ENTRIES {
            return Err("entry_limit");
        }
        let value: Value = serde_json::from_str(line).map_err(|_| "invalid_jsonl")?;
        let entry = entry(value).ok_or("invalid_entries")?;
        if by_id.contains_key(&entry.id) {
            return Err("invalid_entries");
        }
        // Origin tables live on the gateway; the delivered origin marker is
        // the node-local authority, on every branch.
        let custom_type = entry.value.get("customType");
        let message = record(entry.value.get("message"));
        let message_type = message.and_then(|message| message.get("customType"));
        if BACKGROUND_TYPES.contains(&js_string(custom_type).as_str())
            || BACKGROUND_TYPES.contains(&js_string(message_type).as_str())
        {
            return Err("background_session");
        }
        let marker = |value: Option<&Value>| {
            matches!(
                value.and_then(Value::as_str),
                Some("recap.run" | "recap.report")
            )
        };
        if marker(custom_type) || marker(message_type) {
            return Err("recap_marked_session");
        }
        by_id.insert(entry.id.clone(), entries.len());
        entries.push(entry);
    }
    let header_ok = entries.first().is_some_and(|header| {
        header.value.get("type").and_then(Value::as_str) == Some("session")
            && header.value.get("version").and_then(Value::as_f64) == Some(1.0)
            && header.value.get("cwd").and_then(Value::as_str) == Some(root)
            && header.parent_id.is_none()
    });
    if !header_ok {
        return Err("workspace_header_mismatch");
    }
    let mut chain = Vec::new();
    let mut seen = HashSet::new();
    let mut cursor = entries.len().checked_sub(1);
    while let Some(index) = cursor {
        let entry = &entries[index];
        if !seen.insert(index) {
            return Err("branch_cycle");
        }
        chain.push(index);
        let Some(parent) = &entry.parent_id else {
            break;
        };
        cursor = Some(*by_id.get(parent).ok_or("broken_branch")?);
    }
    if chain.last() != Some(&0) {
        return Err("broken_branch");
    }
    let mut slots: Vec<Option<Entry>> = entries.into_iter().map(Some).collect();
    Ok(chain
        .into_iter()
        .rev()
        .filter_map(|index| slots[index].take())
        .collect())
}

/// One piece of evidence (`RecapSource`), as its JSON object.
struct Source {
    user: bool,
    timestamp: f64,
    value: Map<String, Value>,
}

/// `sources(entries, since, until)`: user text first, newest first.
fn sources(entries: &[Entry], since: i64, until: i64) -> Vec<Source> {
    let mut out = Vec::new();
    // Names only: no arguments, result bodies, error messages, or custom memory.
    let tool = |out: &mut Vec<Source>, entry: &Entry, name: Option<&Value>, error: bool| {
        let Some(name) = name.and_then(Value::as_str) else {
            return;
        };
        let mut chars = name.chars();
        let valid = chars.next().is_some_and(|c| c.is_ascii_alphabetic())
            && name.len() <= 64
            && chars.all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | '-'));
        if valid {
            let mut value = Map::new();
            value.insert("entryId".into(), json!(entry.id));
            value.insert("timestamp".into(), entry.value["timestamp"].clone());
            value.insert("role".into(), json!("tool"));
            value.insert("toolName".into(), json!(redact_secrets(name)));
            value.insert("isError".into(), json!(error));
            out.push(Source {
                user: false,
                timestamp: entry.timestamp,
                value,
            });
        }
    };
    for entry in entries {
        if entry.timestamp < since as f64 || entry.timestamp > until as f64 {
            continue;
        }
        let kind = entry.value.get("type").and_then(Value::as_str);
        if kind == Some("custom")
            && entry.value.get("customType").and_then(Value::as_str) == Some("ptc.operation")
        {
            let data = record(entry.value.get("data"));
            tool(
                &mut out,
                entry,
                data.and_then(|data| data.get("toolName")),
                data.and_then(|data| data.get("isError")) == Some(&Value::Bool(true)),
            );
        }
        if kind != Some("message") {
            continue;
        }
        let Some(message) = record(entry.value.get("message")) else {
            continue;
        };
        let role = message.get("role").and_then(Value::as_str);
        if role == Some("toolResult") {
            tool(
                &mut out,
                entry,
                message.get("toolName"),
                message.get("isError") == Some(&Value::Bool(true)),
            );
        }
        let Some(role @ ("user" | "assistant")) = role else {
            continue;
        };
        let parts: &[Value] = match message.get("content") {
            Some(Value::Array(parts)) => parts,
            _ => &[],
        };
        let text = match message.get("content") {
            Some(Value::String(text)) => text.clone(),
            _ => parts
                .iter()
                .filter_map(Value::as_object)
                .filter(|part| part.get("type").and_then(Value::as_str) == Some("text"))
                .filter_map(|part| part.get("text").and_then(Value::as_str))
                .collect::<Vec<_>>()
                .join("\n"),
        };
        if !trim(&text).is_empty() {
            let mut value = Map::new();
            value.insert("entryId".into(), json!(entry.id));
            value.insert("timestamp".into(), entry.value["timestamp"].clone());
            value.insert("role".into(), json!(role));
            value.insert("text".into(), json!(redact_secrets(&text)));
            out.push(Source {
                user: role == "user",
                timestamp: entry.timestamp,
                value,
            });
        }
        for part in parts.iter().filter_map(Value::as_object) {
            if part.get("type").and_then(Value::as_str) == Some("toolCall") {
                tool(&mut out, entry, part.get("name"), false);
            }
        }
    }
    // Human evidence gets the budget first; within each tier prefer recent
    // entries (a stable sort, as JS's).
    out.sort_by(|a, b| {
        b.user.cmp(&a.user).then(
            b.timestamp
                .partial_cmp(&a.timestamp)
                .unwrap_or(std::cmp::Ordering::Equal),
        )
    });
    out
}

/// What reading one session gives: its evidence, or why it is skipped.
fn read_session(
    dir: &str,
    root: &str,
    since: i64,
    until: i64,
    scanned: &mut u64,
) -> Result<Vec<Source>, Skip> {
    let file = Path::new(dir).join("session.jsonl");
    no_symlinks(&file)?;
    let mut handle = File::options()
        .read(true)
        .custom_flags((OFlag::O_NOFOLLOW | OFlag::O_NONBLOCK).bits())
        .open(&file)
        .map_err(|_| "unreadable_session")?;
    let stat = handle.metadata().map_err(|_| "unreadable_session")?;
    if !stat.is_file() {
        return Err("unsafe_path");
    }
    if stat.len() > MAX_FILE {
        return Err("file_byte_limit");
    }
    if *scanned + stat.len() > MAX_SCAN {
        return Err("scan_byte_limit");
    }
    let mut buffer = vec![0; stat.len() as usize];
    let mut offset = 0;
    while offset < buffer.len() {
        let count = handle
            .read(&mut buffer[offset..])
            .map_err(|_| "unreadable_session")?;
        if count == 0 {
            return Err("changed_session");
        }
        offset += count;
        *scanned += count as u64;
    }
    let after = handle.metadata().map_err(|_| "unreadable_session")?;
    if after.len() != stat.len()
        || (after.mtime(), after.mtime_nsec()) != (stat.mtime(), stat.mtime_nsec())
    {
        return Err("changed_session");
    }
    let entries = branch(&String::from_utf8_lossy(&buffer), root)?;
    Ok(sources(&entries, since, until))
}

impl Scope {
    /// Read the sessions and build the evidence object.
    pub(crate) fn collect(self) -> Value {
        let mut sessions: Vec<Value> = Vec::new();
        let mut skipped: Vec<Value> = Vec::new();
        let mut truncated = self.rows.len() > MAX_SESSIONS;
        let mut scanned: u64 = 0;
        let result = |sessions: &[Value], skipped: &[Value], truncated: bool, scanned: u64| {
            json!({
                "version": 1,
                "scope": { "workspaceId": self.workspace_id, "days": self.days,
                    "since": self.since, "until": self.until },
                "sampling": SAMPLING,
                "sessions": sessions,
                "skipped": skipped,
                "truncated": truncated,
                "scannedBytes": scanned,
            })
        };
        for (session_id, dir) in self.rows.iter().take(MAX_SESSIONS) {
            let outcome = read_session(dir, &self.root, self.since, self.until, &mut scanned)
                .and_then(|candidates| {
                    let session = sample(session_id, candidates);
                    if session["evidence"].as_array().is_none_or(Vec::is_empty) {
                        return Err("no_in_window_evidence");
                    }
                    let session_truncated = session["truncated"] == Value::Bool(true);
                    sessions.push(session);
                    if utf16_len(&stringify(&result(&sessions, &skipped, truncated, scanned)))
                        > MAX_OUTPUT - 4000
                    {
                        sessions.pop();
                        return Err("output_limit");
                    }
                    Ok(session_truncated)
                });
            match outcome {
                Ok(session_truncated) => truncated |= session_truncated,
                Err(reason) => {
                    skipped.push(json!({ "sessionId": session_id, "reason": reason }));
                    truncated = true;
                }
            }
        }
        result(&sessions, &skipped, truncated, scanned)
    }
}

/// One session's evidence within its 5000-unit share: texts cut to 1800
/// units, and every item that would push the session's JSON past the
/// share left out (later, smaller ones may still fit).
fn sample(session_id: &str, candidates: Vec<Source>) -> Value {
    let mut evidence: Vec<Value> = Vec::new();
    let mut truncated = false;
    // `JSON.stringify(session).length`, kept as a sum: the frame without
    // items, the items, and the commas between them.
    let frame = |truncated: bool| {
        utf16_len(&stringify(
            &json!({ "sessionId": session_id, "evidence": [], "truncated": truncated }),
        ))
    };
    let mut items = 0;
    for source in candidates {
        let mut item = source.value;
        if let Some(Value::String(text)) = item.get("text")
            && utf16_len(text) > MAX_TEXT
        {
            truncated = true;
            let cut = utf16_prefix(text, MAX_TEXT).to_owned();
            item.insert("text".into(), Value::String(cut));
        }
        let item = Value::Object(item);
        let size = utf16_len(&stringify(&item));
        let commas = evidence.len();
        if frame(truncated) + items + size + commas > MAX_SESSION_JSON {
            truncated = true;
            continue;
        }
        items += size;
        evidence.push(item);
    }
    json!({ "sessionId": session_id, "evidence": evidence, "truncated": truncated })
}

#[cfg(test)]
mod tests;
