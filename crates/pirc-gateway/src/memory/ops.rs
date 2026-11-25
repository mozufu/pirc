//! The memory and assistant operations of `apps/gateway/src/daemon/agent-ops.ts`:
//! `assistant.context`, `memory.note`, `memory.proposeUser`,
//! `memory.search` and `recall.remote`.

use pirc_protocol::{HttpMethod, NodeHttpRequest};
use serde_json::{Map, Value, json};

use super::schema::{array, hex12, int, optional, required, strict, string};
use super::store::{Action, Change, NoteInput, ProposeInput};
use crate::agent_ops::OpContext;
use crate::app::AppState;
use crate::db::Store as _;
use crate::error::{ApiError, ApiResult};
use crate::memory_records;

/// A parsed memory or assistant operation.
pub enum Op {
    Context,
    Note(NoteArgs),
    ProposeUser(ProposeArgs),
    Search {
        query: String,
        workspace: Option<String>,
        limit: Option<i64>,
    },
    Recall {
        id: String,
    },
}

pub struct NoteArgs {
    input: NoteInput,
    origins: Vec<String>,
    entry_ids: Vec<String>,
    quote: Option<String>,
}

pub struct ProposeArgs {
    input: ProposeInput,
    entry_ids: Vec<String>,
}

type Fields<'a> = &'a Map<String, Value>;

fn action(object: Fields<'_>) -> Result<Action, ()> {
    required(object, "action", |value| {
        value.as_str().and_then(Action::parse)
    })
}

/// `entryId.optional()`.
fn entry_id(object: Fields<'_>) -> Result<Option<String>, ()> {
    optional(object, "id", |value| {
        string(value, 1, 40).map(str::to_owned)
    })
}

fn text(object: Fields<'_>, key: &str, max: usize) -> Result<Option<String>, ()> {
    optional(object, key, |value| {
        string(value, 0, max).map(str::to_owned)
    })
}

/// `z.number().int().nonnegative().nullable().optional()`; `null` is no revision.
fn base_revision(object: Fields<'_>) -> Result<Option<i64>, ()> {
    match object.get("baseRevision") {
        None | Some(Value::Null) => Ok(None),
        Some(value) => int(value).filter(|n| *n >= 0).map(Some).ok_or(()),
    }
}

/// `z.array(z.string().min(1).max(200)).max(20)`, at least `min`.
fn entry_ids(value: &Value, min: usize) -> Option<Vec<String>> {
    array(value, min, 20, |item| {
        string(item, 1, 200).map(str::to_owned)
    })
}

fn parse_note(args: &Value) -> Result<NoteArgs, ()> {
    let object = strict(
        args,
        &[
            "action",
            "id",
            "content",
            "baseRevision",
            "origins",
            "entryIds",
            "quote",
        ],
    )
    .ok_or(())?;
    let action = action(object)?;
    let id = entry_id(object)?;
    let content = text(object, "content", 4000)?;
    let base_revision = base_revision(object)?;
    let origins = required(object, "origins", |value| {
        array(value, 1, 20, |item| string(item, 1, 100).map(str::to_owned))
    })?;
    let entry_ids = optional(object, "entryIds", |value| entry_ids(value, 0))?.unwrap_or_default();
    let quote = text(object, "quote", 4000)?;
    Ok(NoteArgs {
        input: NoteInput {
            action,
            id,
            content,
            base_revision,
        },
        origins,
        entry_ids,
        quote,
    })
}

fn parse_propose(args: &Value) -> Result<ProposeArgs, ()> {
    let object = strict(
        args,
        &[
            "action",
            "id",
            "content",
            "baseRevision",
            "quote",
            "entryIds",
        ],
    )
    .ok_or(())?;
    let action = action(object)?;
    let id = entry_id(object)?;
    let content = text(object, "content", 4000)?;
    let base_revision = base_revision(object)?;
    let quote = required(object, "quote", |value| {
        string(value, 0, 4000).map(str::to_owned)
    })?;
    let entry_ids = required(object, "entryIds", |value| entry_ids(value, 1))?;
    Ok(ProposeArgs {
        input: ProposeInput {
            action,
            id,
            content,
            base_revision,
            quote,
        },
        entry_ids,
    })
}

fn parse_search(args: &Value) -> Result<Op, ()> {
    let object = strict(args, &["query", "workspace", "limit"]).ok_or(())?;
    Ok(Op::Search {
        query: required(object, "query", |value| {
            string(value, 1, 500).map(str::to_owned)
        })?,
        workspace: optional(object, "workspace", |value| {
            string(value, 1, 300).map(str::to_owned)
        })?,
        limit: optional(object, "limit", |value| {
            int(value).filter(|n| (1..=20).contains(n))
        })?,
    })
}

pub fn parse_op(op: &str, args: &Value) -> Option<Result<Op, ()>> {
    Some(match op {
        "assistant.context" => strict(args, &[]).map(|_| Op::Context).ok_or(()),
        "memory.note" => parse_note(args).map(Op::Note),
        "memory.proposeUser" => parse_propose(args).map(Op::ProposeUser),
        "memory.search" => parse_search(args),
        "recall.remote" => strict(args, &["id"])
            .and_then(|object| object.get("id"))
            .and_then(hex12)
            .map(|id| Op::Recall { id: id.to_owned() })
            .ok_or(()),
        _ => return None,
    })
}

/// Memory belongs to the assistant: a mode with full assistant access.
fn require_assistant(context: &OpContext) -> ApiResult<()> {
    if !context.mode.full_assistant() {
        return Err(ApiError::new(
            403,
            "forbidden",
            "Only chat sessions have the assistant memory",
        ));
    }
    Ok(())
}

/// Recheck under the same write transaction as memory and its provenance. The
/// context captured before waiting for DB access cannot relabel a stale write.
fn require_current_environment(conn: &rusqlite::Connection, context: &OpContext) -> ApiResult<()> {
    let current = conn.claim_session(&context.session.id, &context.user, false)?;
    if current.binding != context.session.binding {
        return Err(ApiError::new(
            409,
            "stale_environment",
            "Conversation environment changed; refresh before writing memory",
        ));
    }
    Ok(())
}

/// The user's repository workspaces, as `memory_search` may target them.
fn workspaces(app: &AppState) -> ApiResult<Value> {
    let all = app.db.lock().list_workspaces()?;
    let listed = all
        .iter()
        .filter(|workspace| {
            app.mode(&workspace.mode)
                .is_some_and(|mode| mode.repository)
                && workspace.id.contains(':')
        })
        .map(|workspace| {
            let mut item = Map::new();
            item.insert("id".into(), json!(workspace.id));
            item.insert("name".into(), json!(workspace.display_name));
            item.insert("node".into(), json!(workspace.host_id));
            item.insert(
                "online".into(),
                json!(crate::dispatch::workspace_online(app, workspace)),
            );
            if let Some(repo) = &workspace.repo {
                item.insert("repo".into(), json!(repo));
            }
            Value::Object(item)
        })
        .collect();
    Ok(Value::Array(listed))
}

pub async fn run_op(app: &AppState, context: &OpContext, op: Op) -> ApiResult<Value> {
    let user = context.user.as_str();
    let session_id = context.session.id.as_str();
    match op {
        // A full-assistant mode sees USER and MEMORY; a coding session reads
        // the approved USER entries and nothing else: no notes, no
        // workspaces, and its memory operations stay refused.
        Op::Context => {
            if !context.mode.full_assistant() {
                let user = {
                    let conn = app.db.lock();
                    super::store(app, &conn).user_context(user)?
                };
                return Ok(json!({
                    "enabled": true, "user": user, "notes": null, "workspaces": null,
                }));
            }
            let (capabilities, memory) = {
                let conn = app.db.lock();
                (
                    conn.get_workspace_capabilities(&context.workspace.id)?,
                    super::store(app, &conn).context(user, Some(session_id))?,
                )
            };
            let mut result = Map::new();
            result.insert("enabled".into(), json!(true));
            result.insert("capabilities".into(), json!(capabilities));
            result.extend(memory);
            result.insert("workspaces".into(), workspaces(app)?);
            Ok(Value::Object(result))
        }
        Op::Note(args) => {
            require_assistant(context)?;
            let mut sources = Map::new();
            sources.insert("sessionId".into(), json!(session_id));
            if !args.entry_ids.is_empty() {
                sources.insert("entryIds".into(), json!(args.entry_ids));
            }
            if let Some(quote) = args.quote.filter(|quote| !quote.is_empty()) {
                sources.insert("quote".into(), json!(quote));
            }
            let change = Change {
                actor: format!("session:{session_id}"),
                origins: json!(args.origins),
                sources: Value::Object(sources),
            };
            let (entry, unchanged, usage) = {
                let conn = app.db.lock();
                crate::db::atomic(&conn, |tx| {
                    require_current_environment(tx, context)?;
                    super::interactions::ensure_known(app, tx);
                    let store = super::store(app, tx);
                    let (entry, unchanged) = store.write_note(user, &args.input, &change)?;
                    Ok((entry, unchanged, store.usage(user)?))
                })?
            };
            if !unchanged {
                app.memory_changed(user);
            }
            Ok(json!({
                "id": entry.id,
                "revision": entry.revision,
                "status": entry.status,
                "unchanged": unchanged,
                "usage": usage["note"],
            }))
        }
        Op::ProposeUser(args) => {
            require_assistant(context)?;
            let sources = json!({ "sessionId": session_id, "entryIds": args.entry_ids });
            let (proposal, duplicate) = {
                let conn = app.db.lock();
                crate::db::atomic(&conn, |tx| {
                    require_current_environment(tx, context)?;
                    super::interactions::ensure_known(app, tx);
                    super::store(app, tx).propose(user, session_id, &args.input, &sources)
                })?
            };
            if !duplicate {
                app.memory_changed(user);
            }
            Ok(json!({ "proposalId": proposal.id, "duplicate": duplicate }))
        }
        Op::Search {
            query,
            workspace,
            limit,
        } => {
            require_assistant(context)?;
            Ok(json!({
                "hits": memory_records::search_in(app, user, &query, workspace.as_deref(), limit)?,
            }))
        }
        Op::Recall { id } => {
            require_assistant(context)?;
            recall(app, user, &id).await
        }
    }
}

/// Recall a workspace-memory note found by search: its node reads the
/// session that wrote it. With the node offline, the gateway's copy.
async fn recall(app: &AppState, user: &str, id: &str) -> ApiResult<Value> {
    let found = memory_records::find(app, user, id)?;
    if found.is_empty() {
        return Err(ApiError::not_found(format!(
            "No workspace memory note {id}"
        )));
    }
    let mut parts = Vec::new();
    for record in found {
        let online = app.nodes.get(&record.node_id).is_some();
        if online {
            let response = app
                .nodes
                .request(
                    &record.node_id,
                    NodeHttpRequest {
                        method: HttpMethod::Post,
                        url: "/api/workspace-memory/recall".into(),
                        user: user.to_owned(),
                        payload: Some(json!({ "ledgerKey": record.ledger_key, "id": id })),
                        body_base64: None,
                        content_type: None,
                    },
                )
                .await;
            if let Ok(response) = response
                && response.status < 400
                && let Some(text) = response
                    .body
                    .as_ref()
                    .and_then(|body| body.get("text"))
                    .and_then(Value::as_str)
            {
                parts.push(format!("{}:\n{text}", record.workspace));
                continue;
            }
        }
        let status = if record.status == "active" {
            String::new()
        } else {
            format!(" [{}]", record.status)
        };
        let source = if online {
            format!("{} could not read its source now.", record.node_id)
        } else {
            format!(
                "{} is offline, so the session that wrote it cannot be read now.",
                record.node_id
            )
        };
        parts.push(format!(
            "Workspace memory ({}), as the gateway last saw it:\n[{id}] {}{status} {}\n{source}",
            record.workspace, record.date, record.content
        ));
    }
    Ok(json!({ "text": parts.join("\n\n"), "status": "ok" }))
}
