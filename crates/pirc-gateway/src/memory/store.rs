//! The assistant's memory, held by the gateway for each user
//! (`MemoryStore` in `apps/gateway/src/daemon/memory.ts`). USER entries say
//! who the user is and what they want; they change only when the user
//! approves a proposal. MEMORY notes are the assistant's own, written
//! directly. Every change is logged as a revision. Forgetting erases an
//! entry's content and history and keeps only hashes, so the same text
//! cannot be saved again.

use rusqlite::types::Value as Sql;
use rusqlite::{Connection, OptionalExtension, Row, params, params_from_iter};
use serde::Serialize;
use serde_json::{Map, Value, json};

use super::provenance::{self, Snapshot};
use super::text::{content_hash, grouped, squash};
use crate::db::{atomic, sql_text_enum};
use crate::dispatch::redact_secrets;
use crate::error::{ApiError, ApiResult};
use crate::util::{hex, now_ms, random_bytes, safe_json};

pub const ENTRY_MAX_CHARS: usize = 1000;
pub const QUOTE_MAX_CHARS: usize = 1000;
pub const PENDING_PROPOSALS_MAX: usize = 20;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    User,
    Note,
}

impl Kind {
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "user" => Some(Self::User),
            "note" => Some(Self::Note),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::User => "user",
            Self::Note => "note",
        }
    }

    fn label(self) -> &'static str {
        match self {
            Self::User => "USER",
            Self::Note => "MEMORY",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Action {
    Add,
    Replace,
    Remove,
}

impl Action {
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "add" => Some(Self::Add),
            "replace" => Some(Self::Replace),
            "remove" => Some(Self::Remove),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Add => "add",
            Self::Replace => "replace",
            Self::Remove => "remove",
        }
    }
}

/// An entry's `status` column.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum EntryStatus {
    Active,
    /// Removed by the user or a proposal; its history is kept.
    Removed,
    /// Content and history wiped.
    Forgotten,
}

impl EntryStatus {
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "active" => Some(Self::Active),
            "removed" => Some(Self::Removed),
            "forgotten" => Some(Self::Forgotten),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Active => "active",
            Self::Removed => "removed",
            Self::Forgotten => "forgotten",
        }
    }
}

/// A proposal's `status` column.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum ProposalStatus {
    Pending,
    Approved,
    Rejected,
}

impl ProposalStatus {
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "pending" => Some(Self::Pending),
            "approved" => Some(Self::Approved),
            "rejected" => Some(Self::Rejected),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Pending => "pending",
            Self::Approved => "approved",
            Self::Rejected => "rejected",
        }
    }
}

sql_text_enum!(Kind);
sql_text_enum!(Action);
sql_text_enum!(EntryStatus);
sql_text_enum!(ProposalStatus);

/// Characters of memory per user.
#[derive(Clone, Copy, Debug)]
pub struct Budgets {
    pub user: usize,
    pub note: usize,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Entry {
    pub id: String,
    pub kind: Kind,
    /// Empty once forgotten.
    pub content: String,
    pub status: EntryStatus,
    pub revision: i64,
    pub origins: Value,
    pub sources: Value,
    pub created_at: i64,
    pub updated_at: i64,
}

impl Entry {
    fn from_row(row: &Row<'_>) -> rusqlite::Result<Self> {
        Ok(Self {
            id: row.get("id")?,
            kind: row.get("kind")?,
            content: row.get("content")?,
            status: row.get("status")?,
            revision: row.get("revision")?,
            origins: safe_json(&row.get::<_, String>("origins_json")?, json!([])),
            sources: safe_json(&row.get::<_, String>("sources_json")?, json!({})),
            created_at: row.get("created_at")?,
            updated_at: row.get("updated_at")?,
        })
    }

    fn is(&self, kind: Kind) -> bool {
        self.kind == kind
    }

    /// Written from content fetched from the network and from nothing the
    /// user said: a `bash` command that fetched (`tool:bash:network`), web
    /// search or fetch, or the browser. The snapshot labels such notes.
    pub fn fetched(&self) -> bool {
        let origins: Vec<&str> = self
            .origins
            .as_array()
            .map(|origins| origins.iter().filter_map(Value::as_str).collect())
            .unwrap_or_default();
        !origins.contains(&"user") && origins.iter().copied().any(network_origin)
    }

    /// The session the current text came from.
    pub fn source_session(&self) -> Option<&str> {
        self.sources.get("sessionId").and_then(Value::as_str)
    }
}

/// An origin that is content fetched from the network.
pub fn network_origin(origin: &str) -> bool {
    matches!(
        origin,
        "tool:bash:network" | "tool:web_fetch" | "tool:web_search"
    ) || origin.starts_with("tool:browser_")
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Version {
    pub revision: i64,
    pub op: String,
    pub content: Option<String>,
    pub origins: Value,
    pub sources: Value,
    pub actor: String,
    pub at: i64,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Proposal {
    pub id: String,
    pub action: Action,
    pub target_id: Option<String>,
    pub target_revision: Option<i64>,
    pub content: Option<String>,
    pub quote: String,
    pub sources: Value,
    pub session_id: String,
    pub status: ProposalStatus,
    pub created_at: i64,
    pub decided_at: Option<i64>,
}

impl Proposal {
    fn from_row(row: &Row<'_>) -> rusqlite::Result<Self> {
        Ok(Self {
            id: row.get("id")?,
            action: row.get("action")?,
            target_id: row.get("target_id")?,
            target_revision: row.get("target_revision")?,
            content: row.get("content")?,
            quote: row.get("quote")?,
            sources: safe_json(&row.get::<_, String>("sources_json")?, json!({})),
            session_id: row.get("session_id")?,
            status: row.get("status")?,
            created_at: row.get("created_at")?,
            decided_at: row.get("decided_at")?,
        })
    }
}

/// Who is changing memory, and what backs the change.
#[derive(Clone, Debug)]
pub struct Change {
    pub actor: String,
    pub origins: Value,
    pub sources: Value,
}

/// A note the assistant writes (`memory.note`).
#[derive(Clone, Debug)]
pub struct NoteInput {
    pub action: Action,
    pub id: Option<String>,
    pub content: Option<String>,
    /// The revision it last saw; `None` when absent or `null`.
    pub base_revision: Option<i64>,
}

/// A USER change the assistant proposes (`memory.proposeUser`).
#[derive(Clone, Debug)]
pub struct ProposeInput {
    pub action: Action,
    pub id: Option<String>,
    pub content: Option<String>,
    pub base_revision: Option<i64>,
    pub quote: String,
}

/// Entries are single lines; secrets are removed before anything is stored.
fn clean(text: &str) -> String {
    squash(&redact_secrets(text))
}

fn len(text: &str) -> i64 {
    text.encode_utf16().count() as i64
}

fn entry_text(value: Option<&str>) -> ApiResult<String> {
    let text = clean(value.unwrap_or_default());
    if text.is_empty() {
        return Err(ApiError::new(400, "invalid_input", "content is required"));
    }
    if len(&text) > ENTRY_MAX_CHARS as i64 {
        return Err(ApiError::new(
            413,
            "payload_too_large",
            format!(
                "One entry holds at most {ENTRY_MAX_CHARS} characters; split it into separate facts"
            ),
        ));
    }
    Ok(text)
}

/// The memory of every user, over one connection (or transaction).
pub struct Store<'a> {
    conn: &'a Connection,
    pub budgets: Budgets,
}

impl<'a> Store<'a> {
    pub fn new(conn: &'a Connection, budgets: Budgets) -> Self {
        Self { conn, budgets }
    }

    fn tx<T>(&self, body: impl FnOnce() -> ApiResult<T>) -> ApiResult<T> {
        atomic(self.conn, |_| body())
    }

    // ---------- reading ----------

    pub fn entries(
        &self,
        user: &str,
        kind: Option<Kind>,
        status: Option<EntryStatus>,
    ) -> ApiResult<Vec<Entry>> {
        let mut statement = self
            .conn
            .prepare("SELECT * FROM memory_entries WHERE owner_user=? ORDER BY created_at, id")?;
        let rows = statement.query_map([user], Entry::from_row)?;
        let mut entries = Vec::new();
        for entry in rows {
            let entry = entry?;
            if kind.is_none_or(|kind| entry.is(kind))
                && status.is_none_or(|status| entry.status == status)
            {
                entries.push(entry);
            }
        }
        Ok(entries)
    }

    pub fn entry(&self, user: &str, id: &str) -> ApiResult<Entry> {
        self.conn
            .query_row(
                "SELECT * FROM memory_entries WHERE id=? AND owner_user=?",
                [id, user],
                Entry::from_row,
            )
            .optional()?
            .ok_or_else(|| ApiError::not_found(format!("No memory entry {id}")))
    }

    fn used(&self, user: &str) -> ApiResult<(i64, i64)> {
        let mut used = (0, 0);
        for entry in self.entries(user, None, Some(EntryStatus::Active))? {
            if entry.is(Kind::User) {
                used.0 += len(&entry.content);
            } else if entry.is(Kind::Note) {
                used.1 += len(&entry.content);
            }
        }
        Ok(used)
    }

    pub fn usage(&self, user: &str) -> ApiResult<Value> {
        let (user_used, note_used) = self.used(user)?;
        Ok(json!({
            "user": { "used": user_used, "max": self.budgets.user },
            "note": { "used": note_used, "max": self.budgets.note },
        }))
    }

    /// Newest first.
    pub fn history(&self, user: &str, id: &str) -> ApiResult<Vec<Version>> {
        self.entry(user, id)?;
        let mut statement = self.conn.prepare(
            "SELECT * FROM memory_log WHERE entry_id=? AND owner_user=? ORDER BY seq DESC",
        )?;
        let rows = statement.query_map([id, user], |row| {
            Ok(Version {
                revision: row.get("revision")?,
                op: row.get("op")?,
                content: row.get("content")?,
                origins: safe_json(&row.get::<_, String>("origins_json")?, json!([])),
                sources: safe_json(&row.get::<_, String>("sources_json")?, json!({})),
                actor: row.get("actor")?,
                at: row.get("at")?,
            })
        })?;
        Ok(rows.collect::<Result<_, _>>()?)
    }

    pub fn proposals(
        &self,
        user: &str,
        status: Option<ProposalStatus>,
    ) -> ApiResult<Vec<Proposal>> {
        let mut statement = self
            .conn
            .prepare("SELECT * FROM memory_proposals WHERE owner_user=? ORDER BY created_at, id")?;
        let rows = statement.query_map([user], Proposal::from_row)?;
        let mut proposals = Vec::new();
        for proposal in rows {
            let proposal = proposal?;
            if status.is_none_or(|status| proposal.status == status) {
                proposals.push(proposal);
            }
        }
        Ok(proposals)
    }

    pub fn proposal(&self, user: &str, id: &str) -> ApiResult<Proposal> {
        self.conn
            .query_row(
                "SELECT * FROM memory_proposals WHERE id=? AND owner_user=?",
                [id, user],
                Proposal::from_row,
            )
            .optional()?
            .ok_or_else(|| ApiError::not_found(format!("No memory proposal {id}")))
    }

    /// The active entries of `kind`, as a session's context shows them.
    fn briefs(active: &[Entry], kind: Kind) -> Vec<Value> {
        active
            .iter()
            .filter(|entry| entry.is(kind))
            .map(|entry| {
                let mut brief = json!({ "id": entry.id, "content": entry.content,
                    "revision": entry.revision, "updatedAt": entry.updated_at });
                if kind == Kind::Note && entry.fetched() {
                    brief["fetched"] = json!(true);
                }
                brief
            })
            .collect()
    }

    /// What a coding session starts with: the approved USER entries only.
    pub fn user_context(&self, user: &str) -> ApiResult<Vec<Value>> {
        let active = self.entries(user, None, Some(EntryStatus::Active))?;
        Ok(Self::briefs(&active, Kind::User))
    }

    /// What an assistant session starts with.
    pub fn context(&self, user: &str, session_id: Option<&str>) -> ApiResult<Map<String, Value>> {
        let active = self.entries(user, None, Some(EntryStatus::Active))?;
        let brief = |kind: Kind| Self::briefs(&active, kind);
        let decisions: Vec<Value> = match session_id {
            Some(session_id) => {
                let mut decided: Vec<Proposal> = self
                    .proposals(user, None)?
                    .into_iter()
                    .filter(|p| p.session_id == session_id && p.status != ProposalStatus::Pending)
                    .collect();
                decided.sort_by_key(|p| p.decided_at.unwrap_or(0));
                let skip = decided.len().saturating_sub(20);
                decided
                    .into_iter()
                    .skip(skip)
                    .map(|p| {
                        json!({ "id": p.id, "action": p.action, "status": p.status,
                            "targetId": p.target_id, "decidedAt": p.decided_at })
                    })
                    .collect()
            }
            None => Vec::new(),
        };
        let mut context = Map::new();
        context.insert("user".into(), Value::Array(brief(Kind::User)));
        context.insert("notes".into(), Value::Array(brief(Kind::Note)));
        context.insert("usage".into(), self.usage(user)?);
        context.insert(
            "pendingProposals".into(),
            json!(self.proposals(user, Some(ProposalStatus::Pending))?.len()),
        );
        context.insert("proposalDecisions".into(), Value::Array(decisions));
        Ok(context)
    }

    // ---------- the assistant ----------

    /// The assistant adds, replaces or removes one of its notes. For replace
    /// and remove, `base_revision` is the version it last saw; anything else
    /// (or none) is a conflict that returns the current version, so another
    /// chat's change is never overwritten unseen. An unchanged note is
    /// returned as is.
    pub fn write_note(
        &self,
        user: &str,
        input: &NoteInput,
        change: &Change,
    ) -> ApiResult<(Entry, bool)> {
        self.tx(|| {
            if input.action == Action::Add {
                let content = entry_text(input.content.as_deref())?;
                self.refuse_forgotten(user, &content)?;
                if let Some(same) = self.active_with(user, Kind::Note, &content)? {
                    return Ok((same, true));
                }
                self.make_room(user, Kind::Note, len(&content))?;
                return Ok((
                    self.insert(user, Kind::Note, &content, change, None)?,
                    false,
                ));
            }
            let entry = self.entry(user, input.id.as_deref().unwrap_or_default())?;
            if !entry.is(Kind::Note) {
                return Err(ApiError::new(
                    403,
                    "forbidden",
                    format!(
                        "{} is a USER entry; USER changes only when the user approves a proposal",
                        entry.id
                    ),
                ));
            }
            if entry.status == EntryStatus::Forgotten {
                return Err(ApiError::new(
                    409,
                    "forgotten",
                    "The user asked to forget this note",
                ));
            }
            if entry.status == EntryStatus::Removed {
                return Err(ApiError::new(
                    409,
                    "conflict",
                    format!("Note {} was removed; add a new note instead", entry.id),
                ));
            }
            if input.base_revision != Some(entry.revision) {
                return Err(ApiError::new(
                    409,
                    "conflict",
                    format!("Note {} changed since you last saw it", entry.id),
                )
                .with_details(json!({
                    "id": entry.id, "revision": entry.revision, "content": entry.content,
                })));
            }
            if input.action == Action::Remove {
                let removed = self.update(
                    user,
                    &entry,
                    Next {
                        status: Some(EntryStatus::Removed),
                        ..Next::default()
                    },
                    "remove",
                    &change.actor,
                )?;
                return Ok((removed, false));
            }
            let content = entry_text(input.content.as_deref())?;
            if content_hash(&content) == content_hash(&entry.content) {
                return Ok((entry, true));
            }
            self.refuse_forgotten(user, &content)?;
            self.make_room(user, Kind::Note, len(&content) - len(&entry.content))?;
            let replaced = self.update(
                user,
                &entry,
                Next {
                    content: Some(&content),
                    origins: Some(&change.origins),
                    sources: Some(&change.sources),
                    ..Next::default()
                },
                "replace",
                &change.actor,
            )?;
            Ok((replaced, false))
        })
    }

    /// The assistant proposes a USER change resting on the user's exact
    /// words. Nothing changes until the user approves it. Proposing the same
    /// change again returns the pending proposal.
    pub fn propose(
        &self,
        user: &str,
        session_id: &str,
        input: &ProposeInput,
        sources: &Value,
    ) -> ApiResult<(Proposal, bool)> {
        self.tx(|| {
            let quote = clean(&input.quote);
            if quote.is_empty() {
                return Err(ApiError::new(
                    400,
                    "invalid_input",
                    "A USER change needs the user's exact words",
                ));
            }
            if len(&quote) > QUOTE_MAX_CHARS as i64 {
                return Err(ApiError::new(
                    413,
                    "payload_too_large",
                    format!("Quote at most {QUOTE_MAX_CHARS} characters of the user's words"),
                ));
            }
            let target = match input.action {
                Action::Add => None,
                _ => {
                    let target = self.entry(user, input.id.as_deref().unwrap_or_default())?;
                    if !target.is(Kind::User) || target.status != EntryStatus::Active {
                        return Err(ApiError::not_found(format!(
                            "No USER entry {}",
                            input.id.as_deref().unwrap_or("(no id)")
                        )));
                    }
                    Some(target)
                }
            };
            let content = match input.action {
                Action::Remove => None,
                _ => Some(entry_text(input.content.as_deref())?),
            };
            if let Some(content) = &content {
                self.refuse_forgotten(user, content)?;
                if let Some(target) = &target
                    && content_hash(content) == content_hash(&target.content)
                {
                    return Err(ApiError::new(
                        409,
                        "conflict",
                        format!("USER entry {} already says this", target.id),
                    ));
                }
                if target.is_none()
                    && let Some(same) = self.active_with(user, Kind::User, content)?
                {
                    return Err(ApiError::new(
                        409,
                        "conflict",
                        format!("USER already says this ({})", same.id),
                    ));
                }
            }
            let hash = content.as_deref().map(content_hash);
            let target_id = target.as_ref().map(|target| target.id.clone());
            let matching: Vec<Proposal> = {
                let mut statement = self.conn.prepare(
                    "SELECT * FROM memory_proposals WHERE owner_user=? AND action=? AND target_id IS ? AND content_hash IS ? ORDER BY created_at DESC",
                )?;
                let rows = statement.query_map(
                    params![user, input.action.as_str(), target_id, hash],
                    Proposal::from_row,
                )?;
                rows.collect::<Result<_, _>>()?
            };
            if let Some(pending) = matching.iter().find(|row| row.status == ProposalStatus::Pending) {
                return Ok((pending.clone(), true));
            }
            if matching.iter().any(|row| row.status == ProposalStatus::Rejected) {
                return Err(ApiError::new(
                    409,
                    "rejected_before",
                    "The user already rejected this exact change; do not propose it again",
                ));
            }
            let waiting = self.proposals(user, Some(ProposalStatus::Pending))?.len();
            if waiting >= PENDING_PROPOSALS_MAX {
                return Err(ApiError::new(
                    429,
                    "too_many_requests",
                    format!(
                        "{waiting} proposals are already waiting; ask the user to review them in Settings → Memory"
                    ),
                ));
            }
            if let Some(content) = &content {
                let before = target.as_ref().map_or(0, |target| len(&target.content));
                self.make_room(user, Kind::User, len(content) - before)?;
            }
            let id = self.new_id("memory_proposals", "p")?;
            self.conn.execute(
                "INSERT INTO memory_proposals (id,owner_user,action,target_id,target_revision,content,content_hash,quote,sources_json,session_id,status,created_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
                params![
                    id,
                    user,
                    input.action.as_str(),
                    target_id,
                    target.as_ref().and(input.base_revision),
                    content,
                    hash,
                    quote,
                    sources.to_string(),
                    session_id,
                    ProposalStatus::Pending,
                    now_ms(),
                ],
            )?;
            provenance::record_proposal(self.conn, &id, &provenance::from_session(self.conn, user, session_id)?)?;
            Ok((self.proposal(user, &id)?, false))
        })
    }

    /// Erase entries created here, not entries merely recalled or edited here.
    pub fn forget_session(&self, user: &str, session_id: &str) -> ApiResult<()> {
        self.tx(|| {
            let ids: Vec<String> = {
                let mut statement = self.conn.prepare(
                    "SELECT id FROM memory_entries WHERE owner_user=? AND created_by_session=?",
                )?;
                let rows = statement.query_map([user, session_id], |row| row.get(0))?;
                rows.collect::<Result<_, _>>()?
            };
            for id in ids {
                self.forget(user, &id)?;
            }
            self.conn.execute(
                "DELETE FROM memory_proposals WHERE owner_user=? AND session_id=?",
                [user, session_id],
            )?;
            Ok(())
        })
    }

    // ---------- the user ----------

    /// Apply a pending proposal. `target_revision` is the version of the
    /// target the user was shown; if it changed since, nothing is applied.
    pub fn approve(
        &self,
        user: &str,
        proposal_id: &str,
        target_revision: Option<i64>,
    ) -> ApiResult<(Proposal, Entry)> {
        self.tx(|| {
            let proposal = self.pending(user, proposal_id)?;
            let origin = provenance::proposal(self.conn, user, proposal_id)?;
            let actor = format!("user:{user}");
            let mut sources = match &proposal.sources {
                Value::Object(sources) => sources.clone(),
                _ => Map::new(),
            };
            sources.insert("quote".into(), json!(proposal.quote));
            sources.insert("proposalId".into(), json!(proposal.id));
            let change = Change {
                actor: actor.clone(),
                origins: json!(["user"]),
                sources: Value::Object(sources),
            };
            let entry = if proposal.action == Action::Add {
                let content = proposal.content.clone().unwrap_or_default();
                self.refuse_forgotten(user, &content)?;
                match self.active_with(user, Kind::User, &content)? {
                    Some(same) => same,
                    None => {
                        self.make_room(user, Kind::User, len(&content))?;
                        self.insert(user, Kind::User, &content, &change, Some(&origin))?
                    }
                }
            } else {
                let target = self.entry(user, proposal.target_id.as_deref().unwrap_or_default())?;
                if target.status != EntryStatus::Active {
                    return Err(ApiError::new(
                        409,
                        "conflict",
                        format!(
                            "USER entry {} was removed or forgotten since this was proposed; reject the proposal",
                            target.id
                        ),
                    ));
                }
                if target_revision.is_some_and(|revision| revision != target.revision) {
                    return Err(ApiError::new(
                        409,
                        "conflict",
                        format!("USER entry {} changed; review it again", target.id),
                    )
                    .with_details(json!({ "id": target.id, "revision": target.revision })));
                }
                if proposal.action == Action::Remove {
                    self.update(
                        user,
                        &target,
                        Next {
                            status: Some(EntryStatus::Removed),
                            ..Next::default()
                        },
                        "remove",
                        &actor,
                    )?
                } else {
                    let content = proposal.content.clone().unwrap_or_default();
                    self.refuse_forgotten(user, &content)?;
                    self.make_room(user, Kind::User, len(&content) - len(&target.content))?;
                    self.update(
                        user,
                        &target,
                        Next {
                            content: Some(&content),
                            origins: Some(&change.origins),
                            sources: Some(&change.sources),
                            provenance: Some(&origin),
                            ..Next::default()
                        },
                        "replace",
                        &actor,
                    )?
                }
            };
            self.conn.execute(
                "UPDATE memory_proposals SET status='approved', decided_at=?, target_id=? WHERE id=?",
                params![now_ms(), entry.id, proposal.id],
            )?;
            Ok((self.proposal(user, &proposal.id)?, entry))
        })
    }

    pub fn reject(&self, user: &str, proposal_id: &str) -> ApiResult<Proposal> {
        self.tx(|| {
            self.pending(user, proposal_id)?;
            self.conn.execute(
                "UPDATE memory_proposals SET status='rejected', decided_at=? WHERE id=?",
                params![now_ms(), proposal_id],
            )?;
            self.proposal(user, proposal_id)
        })
    }

    /// Erase an entry: its text, every earlier version and the proposals
    /// that carry them. Hashes of all its versions stay as tombstones, which
    /// refuse the same text (ignoring case and spacing) from then on.
    /// Rewordings are not caught. Session transcripts on the nodes are not
    /// touched.
    pub fn forget(&self, user: &str, entry_id: &str) -> ApiResult<()> {
        self.forget_in(user, entry_id, GLOBAL_SCOPE)
    }

    /// [`Self::forget`] with tombstones in `scope`; [`GLOBAL_SCOPE`] refuses
    /// the same text from then on.
    fn forget_in(&self, user: &str, entry_id: &str, scope: &str) -> ApiResult<()> {
        self.tx(|| {
            let entry = self.entry(user, entry_id)?;
            if entry.status == EntryStatus::Forgotten {
                return Ok(());
            }
            let versions: Vec<String> = {
                let mut statement = self.conn.prepare(
                    "SELECT content FROM memory_log WHERE entry_id=? AND owner_user=? AND content IS NOT NULL",
                )?;
                let rows = statement.query_map([entry_id, user], |row| row.get(0))?;
                rows.collect::<Result<_, _>>()?
            };
            let mut hashes: Vec<String> = Vec::new();
            for content in std::iter::once(&entry.content).chain(&versions) {
                if content.is_empty() {
                    continue;
                }
                let hash = content_hash(content);
                if !hashes.contains(&hash) {
                    hashes.push(hash);
                }
            }
            let at = now_ms();
            for hash in &hashes {
                self.conn.execute(
                    "INSERT OR IGNORE INTO memory_tombstones (owner_user,scope_id,content_hash,forgotten_at) VALUES (?,?,?,?)",
                    params![user, scope, hash, at],
                )?;
            }
            self.conn.execute(
                "UPDATE memory_entries SET content='', status='forgotten', revision=revision+1, origins_json='[]', sources_json='{}', updated_at=? WHERE id=?",
                params![at, entry_id],
            )?;
            self.conn.execute(
                "DELETE FROM memory_log WHERE entry_id=? AND owner_user=?",
                [entry_id, user],
            )?;
            let forgotten = self.entry(user, entry_id)?;
            self.log(user, &forgotten, "forget", &format!("user:{user}"), None)?;
            let hashed = if hashes.is_empty() {
                String::new()
            } else {
                format!(
                    " OR content_hash IN ({})",
                    vec!["?"; hashes.len()].join(",")
                )
            };
            let mut values = vec![
                Sql::Integer(at),
                Sql::Text(user.to_owned()),
                Sql::Text(entry_id.to_owned()),
            ];
            values.extend(hashes.into_iter().map(Sql::Text));
            self.conn.execute(
                &format!(
                    "UPDATE memory_proposals SET content=NULL, quote='', sources_json='{{}}', status=CASE WHEN status='pending' THEN 'rejected' ELSE status END, decided_at=COALESCE(decided_at, ?) WHERE owner_user=? AND (target_id=?{hashed})"
                ),
                params_from_iter(values),
            )?;
            Ok(())
        })
    }

    /// Bring back a removed entry, or an earlier version (`revision`) of an
    /// active or removed one. The user acts directly: USER needs no proposal.
    pub fn restore(&self, user: &str, entry_id: &str, revision: Option<i64>) -> ApiResult<Entry> {
        self.tx(|| {
            let entry = self.entry(user, entry_id)?;
            if entry.status == EntryStatus::Forgotten {
                return Err(ApiError::new(
                    409,
                    "forgotten",
                    "This entry was forgotten; nothing is left to restore",
                ));
            }
            let (content, origins, sources) = match revision {
                None => {
                    if entry.status == EntryStatus::Active {
                        return Ok(entry);
                    }
                    (
                        entry.content.clone(),
                        entry.origins.clone(),
                        entry.sources.clone(),
                    )
                }
                Some(revision) => self
                    .conn
                    .query_row(
                        "SELECT * FROM memory_log WHERE entry_id=? AND owner_user=? AND revision=? AND content IS NOT NULL",
                        params![entry_id, user, revision],
                        |row| {
                            Ok((
                                row.get::<_, String>("content")?,
                                safe_json(&row.get::<_, String>("origins_json")?, json!([])),
                                safe_json(&row.get::<_, String>("sources_json")?, json!({})),
                            ))
                        },
                    )
                    .optional()?
                    .ok_or_else(|| {
                        ApiError::not_found(format!("No version {revision} of {entry_id}"))
                    })?,
            };
            if entry.status == EntryStatus::Active && content == entry.content {
                return Ok(entry);
            }
            self.refuse_forgotten(user, &content)?;
            let kind = if entry.is(Kind::User) {
                Kind::User
            } else {
                Kind::Note
            };
            let before = if entry.status == EntryStatus::Active {
                len(&entry.content)
            } else {
                0
            };
            self.make_room(user, kind, len(&content) - before)?;
            let origin = provenance::version(self.conn, user, entry_id, revision)?;
            self.update(
                user,
                &entry,
                Next {
                    content: Some(&content),
                    status: Some(EntryStatus::Active),
                    origins: Some(&origins),
                    sources: Some(&sources),
                    provenance: Some(&origin),
                },
                "restore",
                &format!("user:{user}"),
            )
        })
    }

    // ---------- internals ----------

    fn pending(&self, user: &str, proposal_id: &str) -> ApiResult<Proposal> {
        let proposal = self.proposal(user, proposal_id)?;
        if proposal.status != ProposalStatus::Pending {
            return Err(ApiError::new(
                409,
                "conflict",
                format!(
                    "Proposal {proposal_id} was already {}",
                    proposal.status.as_str()
                ),
            ));
        }
        Ok(proposal)
    }

    fn active_with(&self, user: &str, kind: Kind, content: &str) -> ApiResult<Option<Entry>> {
        let hash = content_hash(content);
        Ok(self
            .entries(user, Some(kind), Some(EntryStatus::Active))?
            .into_iter()
            .find(|entry| content_hash(&entry.content) == hash))
    }

    fn refuse_forgotten(&self, user: &str, content: &str) -> ApiResult<()> {
        let found = self
            .conn
            .query_row(
                "SELECT 1 FROM memory_tombstones WHERE owner_user=? AND scope_id='global' AND content_hash=?",
                [user, &content_hash(content)],
                |_| Ok(()),
            )
            .optional()?;
        if found.is_some() {
            return Err(ApiError::new(
                409,
                "forgotten",
                "The user asked to forget this; do not save it again",
            ));
        }
        Ok(())
    }

    fn make_room(&self, user: &str, kind: Kind, delta: i64) -> ApiResult<()> {
        if delta <= 0 {
            return Ok(());
        }
        let (user_used, note_used) = self.used(user)?;
        let (used, max) = match kind {
            Kind::User => (user_used, self.budgets.user as i64),
            Kind::Note => (note_used, self.budgets.note as i64),
        };
        if used + delta > max {
            return Err(ApiError::new(
                409,
                "memory_full",
                format!(
                    "{} is full ({}/{} characters, {} more needed); replace or remove entries to make room",
                    kind.label(),
                    grouped(used),
                    grouped(max),
                    grouped(delta)
                ),
            )
            .with_details(json!({ "kind": kind.as_str(), "used": used, "max": max, "needed": delta })));
        }
        Ok(())
    }

    fn new_id(&self, table: &str, prefix: &str) -> ApiResult<String> {
        loop {
            let id = format!("{prefix}{}", hex(&random_bytes::<4>()));
            let exists = self
                .conn
                .query_row(&format!("SELECT 1 FROM {table} WHERE id=?"), [&id], |_| {
                    Ok(())
                })
                .optional()?;
            if exists.is_none() {
                return Ok(id);
            }
        }
    }

    fn insert(
        &self,
        user: &str,
        kind: Kind,
        content: &str,
        change: &Change,
        origin: Option<&Snapshot>,
    ) -> ApiResult<Entry> {
        let prefix = if kind == Kind::User { "u" } else { "n" };
        let id = self.new_id("memory_entries", prefix)?;
        let at = now_ms();
        self.conn.execute(
            "INSERT INTO memory_entries (id,owner_user,kind,content,status,revision,origins_json,sources_json,created_at,updated_at,created_by_session) VALUES (?,?,?,?,'active',1,?,?,?,?,?)",
            params![
                id,
                user,
                kind.as_str(),
                content,
                change.origins.to_string(),
                change.sources.to_string(),
                at,
                at,
                change.sources.get("sessionId").and_then(Value::as_str),
            ],
        )?;
        let entry = self.entry(user, &id)?;
        self.log(user, &entry, "add", &change.actor, origin)?;
        Ok(entry)
    }

    fn update(
        &self,
        user: &str,
        entry: &Entry,
        next: Next<'_>,
        op: &str,
        actor: &str,
    ) -> ApiResult<Entry> {
        self.conn.execute(
            "UPDATE memory_entries SET content=?, status=?, revision=?, origins_json=?, sources_json=?, updated_at=? WHERE id=? AND owner_user=?",
            params![
                next.content.unwrap_or(&entry.content),
                next.status.unwrap_or(entry.status),
                entry.revision + 1,
                next.origins.unwrap_or(&entry.origins).to_string(),
                next.sources.unwrap_or(&entry.sources).to_string(),
                now_ms(),
                entry.id,
                user,
            ],
        )?;
        let updated = self.entry(user, &entry.id)?;
        self.log(user, &updated, op, actor, next.provenance)?;
        Ok(updated)
    }

    fn log(
        &self,
        user: &str,
        entry: &Entry,
        op: &str,
        actor: &str,
        origin: Option<&Snapshot>,
    ) -> ApiResult<()> {
        let kept = op != "remove" && op != "forget";
        self.conn.execute(
            "INSERT INTO memory_log (owner_user,entry_id,revision,op,content,origins_json,sources_json,actor,at) VALUES (?,?,?,?,?,?,?,?,?)",
            params![
                user,
                entry.id,
                entry.revision,
                op,
                kept.then_some(&entry.content),
                if kept { entry.origins.to_string() } else { "[]".to_owned() },
                if kept { entry.sources.to_string() } else { "{}".to_owned() },
                actor,
                now_ms(),
            ],
        )?;
        if kept {
            let seq = self.conn.last_insert_rowid();
            let origin = match origin {
                Some(origin) => origin.clone(),
                None => provenance::from_actor(self.conn, user, actor)?,
            };
            provenance::record_version(self.conn, seq, &origin)?;
        }
        Ok(())
    }
}

/// Tombstones that refuse the text again (Forget, session deletion).
pub const GLOBAL_SCOPE: &str = "global";

/// What an update changes.
#[derive(Default)]
struct Next<'a> {
    provenance: Option<&'a Snapshot>,
    content: Option<&'a str>,
    status: Option<EntryStatus>,
    origins: Option<&'a Value>,
    sources: Option<&'a Value>,
}
