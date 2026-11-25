//! Workspace memory from every node, held by the gateway for the
//! assistant's search (`apps/gateway/src/daemon/memory-records.ts`). Nodes
//! mirror their ledgers (`memory_mirror`); this applies the lines the way
//! the ledger fold does, and finds each item's owner and workspace through
//! the session that wrote it. Items whose session the gateway does not know
//! have no owner and are never found.
//!
//! Each item also keeps its workspace's repository (normalized `origin`)
//! as of its recording, so a search in one clone of a repository finds the
//! notes of its other clones, on any node.
//!
//! Search matches every word anywhere (`LIKE`), in any script, and ranks by
//! how many words a note holds: the corpus is small (a few thousand notes),
//! and a trigram index would miss two-character Chinese words anyway.

use rusqlite::types::Value as Sql;
use rusqlite::{Connection, OptionalExtension, Row, params, params_from_iter};
use serde_json::{Map, Value, json};

use crate::app::App;
use crate::db::{Store, atomic};
use crate::dispatch::resolve_directory_workspace;
use crate::error::{ApiError, ApiResult};
use crate::memory::schema::{array, hex12, optional, required, string};
use crate::memory::text::{clip, fold, parse_date, words};
use crate::util::{now_ms, safe_json};

const HIT_CHARS: usize = 600;
const MAX_TERMS: usize = 8;

/// What one node may keep mirrored here (security audit I3): rows,
/// forgotten tombstones included, and note bytes. Far above a real ledger
/// (notes are folded and capped on the node); a node past it gets no new
/// rows until some are cleared, and the gateway logs it. The node's ledger
/// stays the record; this is only the search copy.
const NODE_MAX_ROWS: u64 = 200_000;
const NODE_MAX_BYTES: u64 = 64 * 1024 * 1024;

/// A node's mirrored rows and note bytes, and its limits.
struct Quota {
    rows: u64,
    bytes: u64,
    max_rows: u64,
    max_bytes: u64,
    refused: u64,
    /// Integrity frames are bounded input and check their final SQL state atomically.
    deferred: bool,
}

impl Quota {
    fn of(conn: &Connection, node_id: &str, max_rows: u64, max_bytes: u64) -> ApiResult<Self> {
        let (rows, bytes) = conn.query_row(
            "SELECT COUNT(*), COALESCE(SUM(length(CAST(content AS BLOB))),0) FROM memory_records WHERE node_id=?",
            [node_id],
            |row| Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?)),
        )?;
        Ok(Self {
            rows: rows.max(0) as u64,
            bytes: bytes.max(0) as u64,
            max_rows,
            max_bytes,
            refused: 0,
            deferred: false,
        })
    }

    fn with(mut self, refused: u64) -> Self {
        self.refused = refused;
        self
    }

    /// Take room for one row of `bytes` content, or count it refused.
    fn admit(&mut self, bytes: usize) -> bool {
        let bytes = bytes as u64;
        if !self.deferred && (self.rows >= self.max_rows || self.bytes + bytes > self.max_bytes) {
            self.refused += 1;
            return false;
        }
        self.rows += 1;
        self.bytes += bytes;
        true
    }
}

/// Byte offsets of a node's mirrored ledgers, by ledger key (sent in `registered`).
pub fn watermarks(app: &App, node_id: &str) -> Value {
    let conn = app.db.lock();
    let rows = conn
        .prepare("SELECT ledger_key, watermark FROM memory_mirrors WHERE node_id=?")
        .and_then(|mut statement| {
            statement
                .query_map([node_id], |row| {
                    Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
                })?
                .collect::<Result<Vec<_>, _>>()
        });
    match rows {
        Ok(rows) => Value::Object(
            rows.into_iter()
                .map(|(key, watermark)| (key, json!(watermark)))
                .collect(),
        ),
        Err(error) => {
            crate::log::error(&format!("database: {error}"));
            json!({})
        }
    }
}

/// Store a `memory_mirror` chunk and return the ledger's watermark. A chunk
/// must start exactly where the stored part ends (or start over with
/// `reset`); anything else is ignored, and the answer tells the node where
/// to resume.
pub fn ingest(
    app: &App,
    node_id: &str,
    ledger_key: &str,
    offset: u64,
    end: u64,
    reset: bool,
    lines: &[Value],
) -> ApiResult<u64> {
    ingest_within(
        app,
        node_id,
        ledger_key,
        (offset, end, reset),
        lines,
        (NODE_MAX_ROWS, NODE_MAX_BYTES),
    )
}

/// [`ingest`] with the node's row and byte limits.
fn ingest_within(
    app: &App,
    node_id: &str,
    ledger_key: &str,
    (offset, end, reset): (u64, u64, bool),
    lines: &[Value],
    (max_rows, max_bytes): (u64, u64),
) -> ApiResult<u64> {
    let integrity = lines.last().is_some_and(|v| v["type"] == "integrity");
    if integrity
        && lines[..lines.len() - 1]
            .iter()
            .any(|v| match Line::parse(v) {
                Some(Line::Recorded(items)) => items.iter().any(|v| Item::parse(v).is_none()),
                Some(_) => false,
                None => true,
            })
    {
        return Err(ApiError::invalid_input());
    }
    let conn = app.db.lock();
    let refused = std::cell::Cell::new(0);
    let stored = atomic(&conn, |conn| {
        let current: u64 = conn
            .query_row(
                "SELECT watermark FROM memory_mirrors WHERE node_id=? AND ledger_key=?",
                [node_id, ledger_key],
                |row| row.get::<_, i64>(0),
            )
            .optional()?
            .map_or(0, |watermark| watermark.max(0) as u64);
        let old_hash: Option<String> = conn
            .query_row(
                "SELECT digest FROM memory_mirrors WHERE node_id=? AND ledger_key=?",
                [node_id, ledger_key],
                |row| row.get(0),
            )
            .optional()?
            .flatten();
        let marker = lines.last().filter(|v| v["type"] == "integrity");
        if old_hash.is_some() && marker.is_none() {
            return Ok(current);
        }
        if let Some(marker) = marker {
            if marker["version"] != 2
                || marker["end"].as_u64() != Some(end)
                || marker["digest"].as_str().is_none_or(|s| s.len() != 64)
            {
                return Ok(current);
            }
            if let Some(hash) = &old_hash {
                if marker["previousDigest"].as_str() != Some(hash) {
                    return Ok(current);
                }
            } else if marker["legacyProjection"].as_str()
                != Some(&projection(conn, node_id, ledger_key)?)
            {
                return Ok(current);
            }
        }
        // Replaying an old prefix must never erase a revocation, including legacy mirrors.
        if reset && current > 0 {
            return Ok(current);
        }
        if reset {
            if offset != 0 {
                return Ok(current);
            }
            conn.execute(
                "DELETE FROM memory_records WHERE node_id=? AND ledger_key=?",
                [node_id, ledger_key],
            )?;
        } else if offset != current {
            return Ok(current);
        }
        if end < offset {
            return Ok(if reset { 0 } else { current });
        }
        let mut quota = Quota::of(conn, node_id, max_rows, max_bytes)?;
        quota.deferred = integrity;
        for line in lines {
            if let Some(line) = Line::parse(line) {
                apply(conn, node_id, ledger_key, line, &mut quota)?;
            }
        }
        let final_quota = Quota::of(conn, node_id, max_rows, max_bytes)?;
        if integrity && (final_quota.rows > max_rows || final_quota.bytes > max_bytes) {
            return Err(ApiError::new(
                413,
                "memory_mirror_quota_exceeded",
                "Atomic memory frame exceeds mirror capacity",
            ));
        }
        refused.set(quota.refused);
        conn.execute(
            "INSERT INTO memory_mirrors (node_id,ledger_key,watermark,updated_at) VALUES (?,?,?,?) ON CONFLICT(node_id,ledger_key) DO UPDATE SET watermark=excluded.watermark, updated_at=excluded.updated_at",
            params![node_id, ledger_key, end as i64, now_ms()],
        )?;
        if let Some(marker) = marker {
            conn.execute(
                "UPDATE memory_mirrors SET digest=? WHERE node_id=? AND ledger_key=?",
                params![marker["digest"].as_str(), node_id, ledger_key],
            )?;
        }
        Ok(end)
    })?;
    if refused.get() > 0 {
        crate::log::warn(&format!(
            "memory mirror: node {node_id} is over its quota ({max_rows} rows, {max_bytes} bytes); {} new records not kept for search",
            refused.get()
        ));
    }
    Ok(stored)
}

/// One ledger line (`lineSchema`); its items are checked one by one, so one
/// bad item never costs its line.
enum Line<'a> {
    Recorded(&'a [Value]),
    Retired { ids: Vec<&'a str>, forgotten: bool },
    Cleared,
}

impl<'a> Line<'a> {
    fn parse(value: &'a Value) -> Option<Self> {
        let object = value.as_object()?;
        match object.get("type")?.as_str()? {
            "recorded" => {
                let items = object.get("items")?.as_array()?;
                (items.len() <= 2000).then_some(Self::Recorded(items))
            }
            "retired" => {
                let ids = array(object.get("ids")?, 0, 2000, |id| string(id, 0, 40))?;
                let forgotten = match object.get("reason")?.as_str()? {
                    "superseded" => false,
                    "forgotten" => true,
                    _ => return None,
                };
                Some(Self::Retired { ids, forgotten })
            }
            "cleared" => Some(Self::Cleared),
            _ => None,
        }
    }
}

/// A mirrored item (`itemSchema`).
struct Item {
    id: String,
    content: String,
    relevance: String,
    timestamp: String,
    session_id: Option<String>,
    git: Option<Value>,
    source_ids: Vec<String>,
    origins: Option<Vec<String>>,
}

impl Item {
    fn parse(value: &Value) -> Option<Self> {
        Self::fields(value.as_object()?).ok()
    }

    fn fields(object: &Map<String, Value>) -> Result<Self, ()> {
        let owned = |text: &str| text.to_owned();
        let id = required(object, "id", hex12)?.to_owned();
        let content = required(object, "content", |v| string(v, 0, 20_000).map(owned))?;
        let relevance = required(object, "relevance", |v| {
            v.as_str()
                .filter(|r| ["low", "medium", "high", "critical"].contains(r))
                .map(owned)
        })?;
        let timestamp = required(object, "timestamp", |v| string(v, 0, 40).map(owned))?;
        let session_id = optional(object, "sessionId", |v| string(v, 1, 200).map(owned))?;
        let git = optional(object, "git", |v| {
            let git = v.as_object()?;
            let mut out = Map::new();
            out.insert("head".into(), json!(string(git.get("head")?, 0, 64)?));
            if let Some(branch) = optional(git, "branch", |b| string(b, 0, 300)).ok()? {
                out.insert("branch".into(), json!(branch));
            }
            out.insert("dirty".into(), json!(git.get("dirty")?.as_bool()?));
            Some(Value::Object(out))
        })?;
        let source_ids = required(object, "sourceMemoryIds", |v| {
            array(v, 0, 200, |id| string(id, 0, 40).map(owned))
        })?;
        let origins = optional(object, "origins", |v| {
            array(v, 0, 50, |origin| string(origin, 0, 100).map(owned))
        })?;
        Ok(Self {
            id,
            content,
            relevance,
            timestamp,
            session_id,
            git,
            source_ids,
            origins,
        })
    }
}

/// One ledger line, applied like `foldWorkspace`.
fn apply(
    conn: &Connection,
    node_id: &str,
    key: &str,
    line: Line<'_>,
    quota: &mut Quota,
) -> ApiResult<()> {
    match line {
        Line::Cleared => {
            conn.execute(
                "DELETE FROM memory_records WHERE node_id=? AND ledger_key=? AND status!='forgotten'",
                [node_id, key],
            )?;
            let deferred = quota.deferred;
            *quota = Quota::of(conn, node_id, quota.max_rows, quota.max_bytes)?.with(quota.refused);
            quota.deferred = deferred;
        }
        Line::Retired { ids, forgotten } => {
            for id in ids {
                if !forgotten {
                    conn.execute(
                        "UPDATE memory_records SET status='superseded' WHERE node_id=? AND ledger_key=? AND id=? AND status='active'",
                        [node_id, key, id],
                    )?;
                    continue;
                }
                // Forgotten: nothing of it stays here, and it is never recorded again.
                let freed: Option<i64> = conn
                    .query_row(
                        "SELECT length(CAST(content AS BLOB)) FROM memory_records WHERE node_id=? AND ledger_key=? AND id=?",
                        [node_id, key, id],
                        |row| row.get(0),
                    )
                    .optional()?;
                let erased = conn.execute(
                    "UPDATE memory_records SET content='', git_json=NULL, source_ids_json='[]', origins_json=NULL, status='forgotten' WHERE node_id=? AND ledger_key=? AND id=?",
                    [node_id, key, id],
                )?;
                if let Some(freed) = freed {
                    quota.bytes = quota.bytes.saturating_sub(freed.max(0) as u64);
                }
                if erased == 0 && quota.admit(0) {
                    conn.execute(
                        "INSERT INTO memory_records (node_id,ledger_key,id,content,relevance,recorded_at,source_ids_json,status) VALUES (?,?,?,'','low','','[]','forgotten')",
                        [node_id, key, id],
                    )?;
                }
            }
        }
        Line::Recorded(items) => {
            for raw in items {
                let Some(item) = Item::parse(raw) else {
                    continue;
                };
                // First record wins, and a forgotten id stays forgotten.
                let exists = conn
                    .query_row(
                        "SELECT 1 FROM memory_records WHERE node_id=? AND ledger_key=? AND id=?",
                        [node_id, key, &item.id],
                        |_| Ok(()),
                    )
                    .optional()?;
                if exists.is_some() || !quota.admit(item.content.len()) {
                    continue;
                }
                let (session_id, workspace_id, owner_user) =
                    source(conn, node_id, item.session_id.as_deref())?;
                let repo: Option<String> = match &workspace_id {
                    Some(workspace_id) => conn
                        .query_row(
                            "SELECT repo FROM workspaces WHERE id=?",
                            [workspace_id],
                            |row| row.get(0),
                        )
                        .optional()?
                        .flatten(),
                    None => None,
                };
                conn.execute(
                    "INSERT INTO memory_records (node_id,ledger_key,id,content,relevance,recorded_at,git_json,source_ids_json,origins_json,node_session_id,session_id,workspace_id,owner_user,status,repo) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,'active',?)",
                    params![
                        node_id,
                        key,
                        item.id,
                        item.content,
                        item.relevance,
                        item.timestamp,
                        item.git.map(|git| git.to_string()),
                        json!(item.source_ids).to_string(),
                        item.origins.map(|origins| json!(origins).to_string()),
                        item.session_id,
                        session_id,
                        workspace_id,
                        owner_user,
                        repo,
                    ],
                )?;
            }
        }
    }
    Ok(())
}

/// The gateway's session behind a node session: its id, workspace and owner.
fn source(
    conn: &Connection,
    node_id: &str,
    node_session_id: Option<&str>,
) -> ApiResult<(Option<String>, Option<String>, Option<String>)> {
    let Some(node_session_id) = node_session_id else {
        return Ok((None, None, None));
    };
    let Some(session_id) = conn.resolve_remote_session(node_id, node_session_id)? else {
        return Ok((None, None, None));
    };
    let session = conn.get_session(&session_id)?;
    Ok((
        Some(session_id),
        Some(session.workspace_id),
        session.owner_user,
    ))
}

/// `${branch ?? 'detached'}@${head.slice(0, 7)}${dirty ? '*' : ''}`, for a git state with a head.
fn git_label(git: &Value) -> Option<String> {
    let head = git.get("head")?.as_str().filter(|head| !head.is_empty())?;
    let branch = git
        .get("branch")
        .and_then(Value::as_str)
        .unwrap_or("detached");
    let short: String = String::from_utf16_lossy(&head.encode_utf16().take(7).collect::<Vec<_>>());
    let dirty = git.get("dirty").and_then(Value::as_bool).unwrap_or(false);
    Some(format!("{branch}@{short}{}", if dirty { "*" } else { "" }))
}

/// `${displayName} on ${hostId}`, else what is known of it.
fn label(conn: &Connection, workspace_id: Option<&str>, node_id: Option<&str>) -> String {
    if let Some(workspace_id) = workspace_id
        && let Ok(workspace) = conn.get_workspace(workspace_id)
    {
        return format!("{} on {}", workspace.display_name, workspace.host_id);
    }
    match (node_id, workspace_id) {
        (Some(node_id), _) => format!("a repository on {node_id}"),
        (None, Some(workspace_id)) => workspace_id.to_owned(),
        (None, None) => "a workspace".to_owned(),
    }
}

fn escape_like(term: &str) -> String {
    let mut out = String::with_capacity(term.len());
    for c in term.chars() {
        if matches!(c, '\\' | '%' | '_') {
            out.push('\\');
        }
        out.push(c);
    }
    out
}

struct Ranked {
    score: usize,
    current: bool,
    time: i64,
    hit: Value,
}

fn all_rows(conn: &Connection, sql: &str, values: Vec<Sql>) -> ApiResult<Vec<Map<String, Value>>> {
    let mut statement = conn.prepare(sql)?;
    let names: Vec<String> = statement
        .column_names()
        .into_iter()
        .map(str::to_owned)
        .collect();
    let rows = statement.query_map(params_from_iter(values), |row: &Row<'_>| {
        let mut object = Map::new();
        for (index, name) in names.iter().enumerate() {
            let value = match row.get::<_, Sql>(index)? {
                Sql::Null => Value::Null,
                Sql::Integer(int) => json!(int),
                Sql::Real(real) => json!(real),
                Sql::Text(text) => json!(text),
                Sql::Blob(_) => Value::Null,
            };
            object.insert(name.clone(), value);
        }
        Ok(object)
    })?;
    Ok(rows.collect::<Result<_, _>>()?)
}

/// The workspaces a search keeps to: their ledgers and every record of
/// their repositories.
struct Scope {
    ids: Vec<String>,
    repos: Vec<String>,
}

/// `(?,?,…)`, or `(NULL)` (matching nothing) for none.
fn placeholders(count: usize) -> String {
    if count == 0 {
        "(NULL)".to_owned()
    } else {
        format!("({})", vec!["?"; count].join(","))
    }
}

/// Notes of `user` holding any of the words in `query`, most words first,
/// then current before superseded, then newest.
#[cfg(test)]
pub fn search(
    app: &App,
    user: &str,
    query: &str,
    workspace: Option<&str>,
    limit: Option<i64>,
) -> ApiResult<Vec<Value>> {
    search_in(app, user, query, workspace, limit)
}

/// [`search`] with a workspace by id or name.
pub fn search_in(
    app: &App,
    user: &str,
    query: &str,
    workspace: Option<&str>,
    limit: Option<i64>,
) -> ApiResult<Vec<Value>> {
    let folded = fold(query);
    let mut terms: Vec<&str> = Vec::new();
    for word in words(&folded) {
        if !terms.contains(&word) {
            terms.push(word);
        }
    }
    terms.truncate(MAX_TERMS);
    if terms.is_empty() {
        return Err(ApiError::new(400, "invalid_input", "query is required"));
    }
    let limit = limit.unwrap_or(8).clamp(1, 20) as usize;
    if let Some(reference) = workspace {
        let workspace = resolve_directory_workspace(app, reference)?;
        let scope = Scope {
            ids: vec![workspace.id],
            repos: workspace.repo.into_iter().collect(),
        };
        return find_hits(app, user, &terms, limit, Some(&scope));
    }
    find_hits(app, user, &terms, limit, None)
}

fn find_hits(
    app: &App,
    user: &str,
    terms: &[&str],
    limit: usize,
    scope: Option<&Scope>,
) -> ApiResult<Vec<Value>> {
    let any_term = |column: &str| {
        format!(
            "({})",
            terms
                .iter()
                .map(|_| format!("{column} LIKE ? ESCAPE '\\'"))
                .collect::<Vec<_>>()
                .join(" OR ")
        )
    };
    let patterns = terms
        .iter()
        .map(|term| Sql::Text(format!("%{}%", escape_like(term))));
    let mut values: Vec<Sql> = vec![Sql::Text(user.to_owned())];
    values.extend(patterns.clone());
    let records_in = match scope {
        Some(scope) => {
            values.extend(scope.ids.iter().cloned().map(Sql::Text));
            // A workspace without a repository keeps to its own ledgers.
            values.extend(scope.repos.iter().cloned().map(Sql::Text));
            let (ids, repos) = (
                placeholders(scope.ids.len()),
                placeholders(scope.repos.len()),
            );
            format!(
                " AND ((node_id || '/' || ledger_key) IN (SELECT node_id || '/' || ledger_key FROM memory_records WHERE workspace_id IN {ids}) OR repo IN {repos})"
            )
        }
        None => String::new(),
    };
    let conn = app.db.lock();
    let records = all_rows(
        &conn,
        &format!(
            "SELECT * FROM memory_records WHERE owner_user=? AND status IN ('active','superseded') AND {}{records_in}",
            any_term("content"),
        ),
        values.clone(),
    )?;
    let score = |text: &str| {
        let folded = fold(text);
        terms.iter().filter(|term| folded.contains(**term)).count()
    };
    let text = |row: &Map<String, Value>, key: &str| -> String {
        row.get(key)
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned()
    };
    let mut ranked: Vec<Ranked> = Vec::new();
    for row in &records {
        let content = text(row, "content");
        let git = row
            .get("git_json")
            .and_then(Value::as_str)
            .map(|git| safe_json(git, Value::Null))
            .and_then(|git| git_label(&git));
        let mut hit = Map::new();
        hit.insert("id".into(), json!(text(row, "id")));
        hit.insert("kind".into(), json!("workspace"));
        hit.insert(
            "workspace".into(),
            json!(label(
                &conn,
                row.get("workspace_id").and_then(Value::as_str),
                row.get("node_id").and_then(Value::as_str),
            )),
        );
        hit.insert("date".into(), json!(text(row, "recorded_at")));
        hit.insert("status".into(), json!(text(row, "status")));
        if let Some(git) = git {
            hit.insert("git".into(), json!(git));
        }
        hit.insert("relevance".into(), json!(text(row, "relevance")));
        hit.insert("content".into(), json!(clip(&content, HIT_CHARS)));
        ranked.push(Ranked {
            score: score(&content),
            current: text(row, "status") == "active",
            time: parse_date(&text(row, "recorded_at").replacen(' ', "T", 1)).unwrap_or(0),
            hit: Value::Object(hit),
        });
    }
    ranked.sort_by(|a, b| {
        b.score
            .cmp(&a.score)
            .then(b.current.cmp(&a.current))
            .then(b.time.cmp(&a.time))
    });
    Ok(ranked
        .into_iter()
        .take(limit)
        .map(|ranked| ranked.hit)
        .collect())
}

/// A mirrored note to recall.
#[derive(Clone, Debug, PartialEq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Found {
    pub node_id: String,
    pub ledger_key: String,
    pub workspace: String,
    pub date: String,
    pub status: String,
    pub content: String,
}

/// The user's mirrored notes with this id (usually one), for recall.
pub fn find(app: &App, user: &str, id: &str) -> ApiResult<Vec<Found>> {
    let conn = app.db.lock();
    let rows: Vec<(String, String, Option<String>, String, String, String)> = {
        let mut statement = conn.prepare(
            "SELECT node_id, ledger_key, workspace_id, recorded_at, status, content FROM memory_records WHERE id=? AND owner_user=? AND status!='forgotten' ORDER BY rowid",
        )?;
        let rows = statement.query_map([id, user], |row| {
            Ok((
                row.get(0)?,
                row.get(1)?,
                row.get(2)?,
                row.get(3)?,
                row.get(4)?,
                row.get(5)?,
            ))
        })?;
        rows.collect::<Result<_, _>>()?
    };
    Ok(rows
        .into_iter()
        .map(
            |(node_id, ledger_key, workspace_id, date, status, content)| Found {
                workspace: label(&conn, workspace_id.as_deref(), Some(&node_id)),
                node_id,
                ledger_key,
                date,
                status,
                content,
            },
        )
        .collect())
}

#[cfg(test)]
mod tests;

fn projection(conn: &Connection, node: &str, key: &str) -> ApiResult<String> {
    use sha2::{Digest, Sha256};
    let mut statement = conn.prepare(
        "SELECT id,status,content FROM memory_records WHERE node_id=? AND ledger_key=? ORDER BY id",
    )?;
    let rows = statement
        .query_map([node, key], |row| {
            Ok(json!([
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?
            ]))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(format!(
        "{:x}",
        Sha256::digest(serde_json::to_string(&rows).unwrap().as_bytes())
    ))
}
pub fn mirror_state(app: &App, node: &str, key: &str, user: &str) -> ApiResult<Value> {
    let conn = app.db.lock();
    let row: Option<(u64, Option<String>)> = conn
        .query_row(
            "SELECT watermark,digest FROM memory_mirrors WHERE node_id=? AND ledger_key=?",
            [node, key],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()?;
    let (watermark, digest) = row.unwrap_or((0, None));
    Ok(
        json!({"version":2,"watermark":watermark,"digest":digest,"legacyProjection":projection(&conn,node,key)?,"owner":user}),
    )
}
