//! Owner-scoped calendar access for agents. Read and proposal grants live in
//! `calendar_permissions`; they are independent of workspace capabilities.

use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

use super::{Event, Spec};
use crate::agent_ops::OpContext;
use crate::app::{App, AppState};
use crate::db::{Store, atomic};
use crate::error::{ApiError, ApiResult};
use crate::util::{now_ms, payload_hash};

const PROPOSAL_LIMIT: usize = 10;
const CARD_PREFIX: &str = "calendar:";

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Permissions {
    pub allow_read: bool,
    pub allow_propose: bool,
}

/// Read the user's explicit calendar grants. A missing row is deny/deny.
pub fn permissions(conn: &Connection, user: &str) -> ApiResult<Permissions> {
    Ok(conn
        .query_row(
            "SELECT allow_read, allow_propose FROM calendar_permissions WHERE owner_user=?",
            [user],
            |row| {
                Ok(Permissions {
                    allow_read: row.get::<_, i64>(0)? != 0,
                    allow_propose: row.get::<_, i64>(1)? != 0,
                })
            },
        )
        .optional()?
        .unwrap_or_default())
}

/// Save explicit grants. This helper is intended for the authenticated user
/// settings route; callers must pass booleans parsed from that request.
pub fn set_permissions(
    conn: &Connection,
    user: &str,
    permissions: Permissions,
) -> ApiResult<Permissions> {
    conn.execute(
        "INSERT INTO calendar_permissions (owner_user, allow_read, allow_propose) VALUES (?,?,?)
         ON CONFLICT(owner_user) DO UPDATE SET allow_read=excluded.allow_read, allow_propose=excluded.allow_propose",
        params![
            user,
            if permissions.allow_read { 1i64 } else { 0 },
            if permissions.allow_propose { 1i64 } else { 0 }
        ],
    )?;
    Ok(permissions)
}

#[derive(Debug)]
pub enum Op {
    Query {
        from: String,
        to: String,
        timezone: String,
        cursor: Option<String>,
    },
    Get {
        id: String,
    },
    ProposeCreate {
        spec: Value,
    },
    ProposeUpdate {
        id: String,
        revision: i64,
        spec: Value,
        scope: String,
        occurrence: Option<String>,
    },
    ProposeDelete {
        id: String,
        revision: i64,
        scope: String,
        occurrence: Option<String>,
    },
    ProposalResult {
        id: String,
    },
}

/// `None`: an unrelated operation; `Some(Err)`: malformed arguments.
pub fn parse_op(op: &str, args: &Value) -> Option<Result<Op, ()>> {
    let parsed = match op {
        "calendar.query" => object(args, &["from", "to", "timezone", "cursor"]).and_then(|a| {
            Ok(Op::Query {
                from: a.required("from", 1, 40)?,
                to: a.required("to", 1, 40)?,
                timezone: a.required("timezone", 1, 100)?,
                cursor: a.optional("cursor", 1, 200)?,
            })
        }),
        "calendar.get" => object(args, &["id"]).and_then(|a| {
            Ok(Op::Get {
                id: a.required("id", 1, 80)?,
            })
        }),
        "calendar.proposeCreate" => object(args, &["spec"]).and_then(|a| {
            let spec = a.required_value("spec")?;
            if !spec.is_object() {
                return Err(());
            }
            Ok(Op::ProposeCreate { spec })
        }),
        "calendar.proposeUpdate" => {
            object(args, &["id", "revision", "spec", "scope", "occurrence"]).and_then(|a| {
                let spec = a.required_value("spec")?;
                if !spec.is_object() {
                    return Err(());
                }
                Ok(Op::ProposeUpdate {
                    id: a.required("id", 1, 80)?,
                    revision: a.required_i64("revision")?,
                    spec,
                    scope: a
                        .optional("scope", 1, 32)?
                        .unwrap_or_else(|| "series".into()),
                    occurrence: a.optional("occurrence", 1, 80)?,
                })
            })
        }
        "calendar.proposeDelete" => object(args, &["id", "revision", "scope", "occurrence"])
            .and_then(|a| {
                Ok(Op::ProposeDelete {
                    id: a.required("id", 1, 80)?,
                    revision: a.required_i64("revision")?,
                    scope: a
                        .optional("scope", 1, 32)?
                        .unwrap_or_else(|| "series".into()),
                    occurrence: a.optional("occurrence", 1, 80)?,
                })
            }),
        "calendar.proposalResult" => object(args, &["id"]).and_then(|a| {
            Ok(Op::ProposalResult {
                id: a.required("id", 1, 80)?,
            })
        }),
        _ => return None,
    };
    Some(parsed)
}

#[derive(Clone, Debug)]
struct Args<'a>(&'a Map<String, Value>);

impl Args<'_> {
    fn required(&self, name: &str, min: usize, max: usize) -> Result<String, ()> {
        let text = self.0.get(name).and_then(Value::as_str).ok_or(())?;
        let text = text.trim();
        if (min..=max).contains(&text.encode_utf16().count()) {
            Ok(text.to_owned())
        } else {
            Err(())
        }
    }

    fn optional(&self, name: &str, min: usize, max: usize) -> Result<Option<String>, ()> {
        let Some(value) = self.0.get(name) else {
            return Ok(None);
        };
        let text = value.as_str().ok_or(())?.trim();
        if text.is_empty() || !(min..=max).contains(&text.encode_utf16().count()) {
            return Err(());
        }
        Ok(Some(text.to_owned()))
    }

    fn required_value(&self, name: &str) -> Result<Value, ()> {
        self.0.get(name).cloned().ok_or(())
    }

    fn required_i64(&self, name: &str) -> Result<i64, ()> {
        self.0
            .get(name)
            .and_then(Value::as_i64)
            .filter(|n| *n > 0)
            .ok_or(())
    }
}

fn object<'a>(value: &'a Value, allowed: &[&str]) -> Result<Args<'a>, ()> {
    let map = value.as_object().ok_or(())?;
    if map.keys().any(|key| !allowed.contains(&key.as_str())) {
        return Err(());
    }
    Ok(Args(map))
}

fn permission_error(permission: &str) -> ApiError {
    ApiError::new(
        403,
        "calendar_permission_required",
        format!(
            "Calendar {permission} access is disabled. The user can grant it in Calendar settings."
        ),
    )
}

fn require_read(conn: &Connection, user: &str) -> ApiResult<()> {
    if permissions(conn, user)?.allow_read {
        Ok(())
    } else {
        Err(permission_error("read"))
    }
}

fn require_propose(conn: &Connection, user: &str) -> ApiResult<()> {
    if permissions(conn, user)?.allow_propose {
        Ok(())
    } else {
        Err(permission_error("proposal"))
    }
}

pub async fn run_op(app: &AppState, context: &OpContext, op: Op) -> ApiResult<Value> {
    let user = &context.user;
    match op {
        Op::Query {
            from,
            to,
            timezone,
            cursor,
        } => {
            let conn = app.db.lock();
            require_read(&conn, user)?;
            let from = parse_range_bound(&from)?;
            let to = parse_range_bound(&to)?;
            let mut result = super::query(
                &conn,
                user,
                from,
                to,
                &timezone,
                cursor.as_deref(),
                now_ms(),
            )?;
            redact_schedule_details(&mut result);
            Ok(result)
        }
        Op::Get { id } => {
            let conn = app.db.lock();
            require_read(&conn, user)?;
            let event = super::get(&conn, user, &id)?;
            let event_id = event.id.clone();
            let revision = event.revision;
            Ok(json!({ "event": event, "id": event_id, "revision": revision }))
        }
        Op::ProposeCreate { spec } => {
            require_propose(&app.db.lock(), user)?;
            let spec: Spec = serde_json::from_value(spec).map_err(|_| ApiError::invalid_input())?;
            super::validate_spec(&spec)?;
            propose(
                app,
                context,
                ProposalDraft {
                    operation: "create",
                    event_id: None,
                    expected_revision: None,
                    spec: &spec,
                    scope: "series",
                    occurrence: None,
                },
            )
        }
        Op::ProposeUpdate {
            id,
            revision,
            spec,
            scope,
            occurrence,
        } => {
            require_propose(&app.db.lock(), user)?;
            let scope = checked_scope(&scope, occurrence.as_deref())?;
            let spec: Spec = serde_json::from_value(spec).map_err(|_| ApiError::invalid_input())?;
            super::validate_spec(&spec)?;
            let _event = {
                let conn = app.db.lock();
                validate_target(&conn, user, &id, revision, scope, occurrence.as_deref())?
            };
            propose(
                app,
                context,
                ProposalDraft {
                    operation: "update",
                    event_id: Some(&id),
                    expected_revision: Some(revision),
                    spec: &spec,
                    scope,
                    occurrence: occurrence.as_deref(),
                },
            )
        }
        Op::ProposeDelete {
            id,
            revision,
            scope,
            occurrence,
        } => {
            require_propose(&app.db.lock(), user)?;
            let scope = checked_scope(&scope, occurrence.as_deref())?;
            let event = {
                let conn = app.db.lock();
                validate_target(&conn, user, &id, revision, scope, occurrence.as_deref())?
            };
            propose(
                app,
                context,
                ProposalDraft {
                    operation: "delete",
                    event_id: Some(&id),
                    expected_revision: Some(revision),
                    spec: &event.spec,
                    scope,
                    occurrence: occurrence.as_deref(),
                },
            )
        }
        Op::ProposalResult { id } => proposal_result(app, user, &context.session.id, &id),
    }
}

fn validate_target(
    conn: &Connection,
    user: &str,
    id: &str,
    revision: i64,
    scope: &str,
    occurrence: Option<&str>,
) -> ApiResult<Event> {
    match super::validate_target(conn, user, id, revision, scope, occurrence) {
        Err(error) if error.status == 409 => Err(ApiError::new(
            409,
            "conflict",
            "The event changed. Read its current version before proposing this change.",
        )),
        result => result,
    }
}

fn checked_scope<'a>(scope: &'a str, occurrence: Option<&str>) -> ApiResult<&'a str> {
    match scope {
        "series" if occurrence.is_none() => Ok(scope),
        "occurrence" | "following" if occurrence.is_some() => Ok(scope),
        _ => Err(ApiError::invalid_input()),
    }
}

fn parse_range_bound(value: &str) -> ApiResult<i64> {
    if let Ok(value) = chrono::DateTime::parse_from_rfc3339(value) {
        return Ok(value.timestamp_millis());
    }
    chrono::NaiveDate::parse_from_str(value, "%Y-%m-%d")
        .ok()
        .and_then(|date| date.and_hms_opt(0, 0, 0))
        .map(|datetime| datetime.and_utc().timestamp_millis())
        .ok_or_else(ApiError::invalid_input)
}

/// Calendar read permission exposes schedule projections, but not the full
/// schedule prompts or run history included for the first-party calendar UI.
fn redact_schedule_details(result: &mut Value) {
    let Some(items) = result.get_mut("items").and_then(Value::as_array_mut) else {
        return;
    };
    for item in items {
        if item.get("type").and_then(Value::as_str) == Some("schedule")
            && let Some(item) = item.as_object_mut()
        {
            item.remove("schedule");
            item.remove("run");
        }
    }
}

struct ProposalDraft<'a> {
    operation: &'a str,
    event_id: Option<&'a str>,
    expected_revision: Option<i64>,
    spec: &'a Spec,
    scope: &'a str,
    occurrence: Option<&'a str>,
}

fn propose(app: &AppState, context: &OpContext, draft: ProposalDraft<'_>) -> ApiResult<Value> {
    let ProposalDraft {
        operation,
        event_id,
        expected_revision,
        spec,
        scope,
        occurrence,
    } = draft;
    let spec_json = serde_json::to_value(spec).map_err(|_| ApiError::internal())?;
    let request = json!({
        "operation": operation,
        "eventId": event_id,
        "expectedRevision": expected_revision,
        "spec": spec_json,
        "scope": scope,
        "occurrence": occurrence,
    });
    let request_hash = payload_hash(&request);
    let now = now_ms();
    sweep_expired(app, now)?;
    let expires_at = now.saturating_add(app.config.proposal_ttl_ms as i64);
    let proposal = {
        let conn = app.db.lock();
        require_propose(&conn, &context.user)?;
        atomic(&conn, |conn| {
            let waiting: i64 = conn.query_row(
                "SELECT COUNT(*) FROM calendar_proposals WHERE owner_user=? AND status='pending' AND expires_at>?",
                params![context.user, now],
                |row| row.get(0),
            )?;
            if waiting as usize >= PROPOSAL_LIMIT {
                return Err(ApiError::new(
                    429,
                    "calendar_proposals_full",
                    "Too many calendar proposals are waiting for approval.",
                ));
            }
            if let Some((id, result_json)) = conn
                .query_row(
                    "SELECT id,result_json FROM calendar_proposals WHERE owner_user=? AND session_id=? AND request_hash=? AND status='pending' ORDER BY created_at DESC LIMIT 1",
                    params![context.user, context.session.id, request_hash],
                    |row| Ok((row.get::<_, String>(0)?, row.get::<_, Option<String>>(1)?)),
                )
                .optional()?
            {
                return Ok((id, true, result_json));
            }
            let id = crate::util::new_id("cp");
            conn.execute(
                "INSERT INTO calendar_proposals (id,owner_user,session_id,event_id,expected_revision,operation,spec_json,scope,occurrence,request_hash,status,expires_at,created_at,decision,applied_event_id,result_json) VALUES (?,?,?,?,?,?,?,?,?,?,'pending',?,?,NULL,NULL,NULL)",
                params![
                    id,
                    context.user,
                    context.session.id,
                    event_id,
                    expected_revision,
                    operation,
                    spec_json.to_string(),
                    scope,
                    occurrence,
                    request_hash,
                    expires_at,
                    now,
                ],
            )?;
            Ok((id, false, None))
        })?
    };
    if !proposal.1 {
        publish_created(app, &context.session.id, &proposal.0)?;
    }
    Ok(json!({
        "proposalId": proposal.0,
        "duplicate": proposal.1,
        "status": "pending_approval",
        "operation": operation,
        "eventId": event_id,
    }))
}

fn publish_created(app: &App, session_id: &str, proposal_id: &str) -> ApiResult<()> {
    let card = {
        let conn = app.db.lock();
        let proposal = proposal_by_id(&conn, proposal_id)?.ok_or_else(ApiError::internal)?;
        interaction_of(&conn, &proposal)?
    };
    let epoch = app.db.lock().get_session(session_id)?.runner_epoch;
    app.events
        .publish(session_id, epoch, "interaction_created", card);
    Ok(())
}

#[derive(Clone, Debug)]
struct Proposal {
    id: String,
    owner_user: String,
    session_id: String,
    event_id: Option<String>,
    expected_revision: Option<i64>,
    operation: String,
    spec: Spec,
    scope: String,
    occurrence: Option<String>,
    status: String,
    expires_at: i64,
    created_at: i64,
    decision: Option<String>,
    result: Option<Value>,
}

fn proposal_by_id(conn: &Connection, id: &str) -> ApiResult<Option<Proposal>> {
    Ok(conn
        .query_row(
            "SELECT id,owner_user,session_id,event_id,expected_revision,operation,spec_json,scope,occurrence,status,expires_at,created_at,decision,result_json FROM calendar_proposals WHERE id=?",
            [id],
            |row| {
                let raw_spec: String = row.get(6)?;
                let spec = serde_json::from_str::<Spec>(&raw_spec).map_err(|_| {
                    rusqlite::Error::FromSqlConversionFailure(
                        6,
                        rusqlite::types::Type::Text,
                        Box::new(std::io::Error::other("invalid calendar proposal spec")),
                    )
                })?;
                let result = row
                    .get::<_, Option<String>>(13)?
                    .and_then(|raw| serde_json::from_str(&raw).ok());
                Ok(Proposal {
                    id: row.get(0)?,
                    owner_user: row.get(1)?,
                    session_id: row.get(2)?,
                    event_id: row.get(3)?,
                    expected_revision: row.get(4)?,
                    operation: row.get(5)?,
                    spec,
                    scope: row.get(7)?,
                    occurrence: row.get(8)?,
                    status: row.get(9)?,
                    expires_at: row.get(10)?,
                    created_at: row.get(11)?,
                    decision: row.get(12)?,
                    result,
                })
            },
        )
        .optional()?)
}

fn proposal_rows(conn: &Connection, session_id: &str, at: i64) -> ApiResult<Vec<Proposal>> {
    let mut statement = conn.prepare(
        "SELECT id FROM calendar_proposals WHERE session_id=? AND status='pending' AND expires_at>? ORDER BY created_at,id",
    )?;
    let ids = statement
        .query_map(params![session_id, at], |row| row.get::<_, String>(0))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    ids.iter()
        .map(|id| proposal_by_id(conn, id)?.ok_or_else(ApiError::internal))
        .collect()
}

/// Pending proposals projected as ordinary chat confirmations.
pub fn pending_interactions(app: &App, session_id: &str) -> Vec<Value> {
    if let Err(error) = sweep_expired(app, now_ms()) {
        crate::log::warn(&format!(
            "calendar proposals: expiry scan failed: {}",
            error.message
        ));
    }
    let conn = app.db.lock();
    proposal_rows(&conn, session_id, now_ms())
        .unwrap_or_default()
        .iter()
        .filter_map(|proposal| interaction_of(&conn, proposal).ok())
        .collect()
}

/// Expire old confirmation cards and publish the same close signal used for
/// an answered proposal. The reminder timer calls this alongside its scan.
pub fn sweep_expired(app: &App, at: i64) -> ApiResult<()> {
    let expired = {
        let conn = app.db.lock();
        atomic(&conn, |conn| {
            let mut statement = conn.prepare(
                "SELECT id,session_id,event_id FROM calendar_proposals
                 WHERE status='pending' AND expires_at<=? ORDER BY expires_at,id",
            )?;
            let rows = statement
                .query_map([at], |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, Option<String>>(2)?,
                    ))
                })?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            drop(statement);
            let mut expired = Vec::new();
            for (id, session_id, event_id) in rows {
                let result = json!({ "status": "expired", "eventId": event_id });
                let changed = conn.execute(
                    "UPDATE calendar_proposals SET status='expired',decision='expired',result_json=?
                     WHERE id=? AND status='pending' AND expires_at<=?",
                    params![result.to_string(), id, at],
                )?;
                if changed > 0 {
                    expired.push((id, session_id));
                }
            }
            Ok(expired)
        })?
    };
    for (id, session_id) in expired {
        let Ok(session) = app.db.lock().get_session(&session_id) else {
            continue;
        };
        app.events.publish(
            &session_id,
            session.runner_epoch,
            "interaction_answered",
            json!({ "interactionId": card_id(&id), "interactionEpoch": 0 }),
        );
    }
    Ok(())
}

fn interaction_of(conn: &Connection, proposal: &Proposal) -> ApiResult<Value> {
    let current = match proposal.event_id.as_deref() {
        Some(id) => super::get(conn, &proposal.owner_user, id)
            .ok()
            .map(|event| event_json(&event)),
        None => None,
    };
    let desired = spec_json(&proposal.spec)?;
    let title = desired["title"].as_str().unwrap_or("Untitled event");
    let label = match proposal.operation.as_str() {
        "create" => "Create this event?",
        "update" => "Save these event changes?",
        "delete" => "Delete this event?",
        _ => "Review this calendar change?",
    };
    let mut lines = vec![format!("Proposed event: {title}")];
    if let Some(current) = current.as_ref() {
        lines.push(String::new());
        lines.push("Current event:".into());
        lines.push(describe_event(current));
        if proposal.operation == "delete" {
            lines.push(format!("\nDelete scope: {}", scope_label(&proposal.scope)));
        } else {
            lines.push(String::new());
            lines.push("After approval:".into());
            lines.push(describe_event(&desired));
            lines.push(format!("\nEdit scope: {}", scope_label(&proposal.scope)));
        }
    } else {
        lines.push(describe_event(&desired));
    }
    Ok(json!({
        "id": card_id(&proposal.id),
        "rpcId": card_id(&proposal.id),
        "sessionId": proposal.session_id,
        "runnerEpoch": 0,
        "kind": "confirm",
        "status": "pending",
        "request": {
            "method": "confirm",
            "title": label,
            "message": lines.join("\n"),
            "confirmLabel": if proposal.operation == "delete" { "Delete" } else { "Save" },
            "cancelLabel": "Don't",
        },
        "expiresAt": proposal.expires_at,
        "createdAt": proposal.created_at,
    }))
}

fn card_id(id: &str) -> String {
    format!("{CARD_PREFIX}{id}:1")
}

fn scope_label(scope: &str) -> &'static str {
    match scope {
        "occurrence" => "this occurrence only",
        "following" => "this and following occurrences",
        _ => "the whole series",
    }
}

fn event_json(event: &Event) -> Value {
    serde_json::to_value(event).unwrap_or(Value::Null)
}

fn spec_json(spec: &Spec) -> ApiResult<Value> {
    serde_json::to_value(spec).map_err(|_| ApiError::internal())
}

fn describe_event(event: &Value) -> String {
    let get = |key: &str| event.get(key).and_then(Value::as_str).unwrap_or("unknown");
    let all_day = event.get("allDay") == Some(&Value::Bool(true));
    let mut lines = vec![format!(
        "When: {} → {} ({}){}",
        get("start"),
        get("end"),
        get("timezone"),
        if all_day { ", all day" } else { "" },
    )];
    if let Some(recurrence) = event.get("recurrence").filter(|v| !v.is_null()) {
        lines.push(format!("Repeats: {}", recurrence));
    }
    if let Some(reminders) = event
        .get("reminderMinutes")
        .and_then(Value::as_array)
        .filter(|reminders| !reminders.is_empty())
    {
        lines.push(format!(
            "Reminders: {} minutes before",
            reminders
                .iter()
                .map(Value::to_string)
                .collect::<Vec<_>>()
                .join(", ")
        ));
    }
    if let Some(location) = event
        .get("location")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
    {
        lines.push(format!("Location: {location}"));
    }
    if let Some(description) = event
        .get("description")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
    {
        lines.push(format!("Description: {description}"));
    }
    lines.join("\n")
}

fn proposal_result(app: &AppState, user: &str, session_id: &str, id: &str) -> ApiResult<Value> {
    sweep_expired(app, now_ms())?;
    let id = id.strip_prefix(CARD_PREFIX).unwrap_or(id);
    let id = id.strip_suffix(":1").unwrap_or(id);
    let conn = app.db.lock();
    let proposal = proposal_by_id(&conn, id)?
        .filter(|proposal| proposal.owner_user == user && proposal.session_id == session_id)
        .ok_or_else(|| ApiError::not_found("No calendar proposal in this chat"))?;
    if proposal.status == "pending" && proposal.expires_at <= now_ms() {
        drop(conn);
        sweep_expired(app, now_ms())?;
        return proposal_result(app, user, session_id, id);
    }
    let safe_result = proposal.result.as_ref().map(agent_result);
    Ok(json!({
        "proposalId": proposal.id,
        "status": proposal.status,
        "decision": proposal.decision,
        "eventId": proposal.result.as_ref().and_then(|result| result.get("eventId")),
        "result": safe_result,
    }))
}

/// Proposal permission returns the outcome metadata, never a calendar record.
fn agent_result(result: &Value) -> Value {
    let mut safe = Map::new();
    for key in ["status", "eventId", "revision", "deleted", "reason"] {
        if let Some(value) = result.get(key) {
            safe.insert(key.to_owned(), value.clone());
        }
    }
    Value::Object(safe)
}

/// Answer a calendar proposal. Repeated answers return the stored result;
/// event revision is checked again under the write lock before application.
pub fn answer(
    app: &AppState,
    session_id: &str,
    interaction_id: &str,
    user: &str,
    answer: Option<&Value>,
) -> ApiResult<Option<Value>> {
    let Some(id) = interaction_id
        .strip_prefix(CARD_PREFIX)
        .and_then(|id| id.strip_suffix(":1"))
    else {
        return Ok(None);
    };
    sweep_expired(app, now_ms())?;
    let approved = answer.and_then(|value| value.get("confirmed")) == Some(&Value::Bool(true));
    let now = now_ms();
    let (response, changed) = {
        let conn = app.db.lock();
        let Some(proposal) = proposal_by_id(&conn, id)? else {
            return Ok(None);
        };
        if proposal.session_id != session_id {
            return Ok(None);
        }
        if proposal.owner_user != user {
            return Err(ApiError::new(
                403,
                "forbidden",
                "Calendar proposal belongs to another user",
            ));
        }
        if proposal.status == "pending" && proposal.expires_at <= now_ms() {
            drop(conn);
            sweep_expired(app, now_ms())?;
            return Err(ApiError::new(
                409,
                "stale_interaction",
                "This calendar proposal expired",
            ));
        }
        if proposal.status != "pending" {
            if proposal.status == "expired" {
                return Err(ApiError::new(
                    409,
                    "stale_interaction",
                    "This calendar proposal expired",
                ));
            }
            if proposal.decision.as_deref() == Some(if approved { "approved" } else { "rejected" })
            {
                return Ok(Some(answered_value(
                    id,
                    proposal
                        .result
                        .unwrap_or_else(|| json!({"status": proposal.status})),
                )));
            }
            return Err(ApiError::new(
                409,
                "stale_interaction",
                "This calendar proposal was already handled",
            ));
        }
        atomic(&conn, |conn| {
            if !approved {
                let result = json!({ "status": "rejected", "eventId": proposal.event_id });
                conn.execute(
                    "UPDATE calendar_proposals SET status='rejected',decision='rejected',result_json=? WHERE id=? AND status='pending'",
                    params![result.to_string(), id],
                )?;
                return Ok((answered_value(id, result), false));
            }
            if !permissions(conn, user)?.allow_propose {
                let result = json!({ "status": "stale", "reason": "calendar proposal permission was revoked", "eventId": proposal.event_id });
                conn.execute(
                    "UPDATE calendar_proposals SET status='stale',decision='approved',result_json=? WHERE id=? AND status='pending'",
                    params![result.to_string(), id],
                )?;
                return Ok((answered_value(id, result), false));
            }
            let outcome = apply_proposal(conn, user, &proposal, now);
            let (status, result, changed) = match outcome {
                Ok(result) => ("approved", result, true),
                Err(error) if error.status == 409 => (
                    "stale",
                    json!({ "status": "stale", "reason": error.message, "eventId": proposal.event_id }),
                    false,
                ),
                Err(error) => (
                    "failed",
                    json!({ "status": "failed", "reason": error.message, "eventId": proposal.event_id }),
                    false,
                ),
            };
            conn.execute(
                "UPDATE calendar_proposals SET status=?,decision='approved',applied_event_id=?,result_json=? WHERE id=? AND status='pending'",
                params![status, result.get("eventId").and_then(Value::as_str), result.to_string(), id],
            )?;
            Ok((answered_value(id, result), changed))
        })?
    };
    publish_answered(app, session_id, id)?;
    if changed {
        app.schedules_changed(user);
    }
    Ok(Some(response))
}

fn apply_proposal(
    conn: &Connection,
    user: &str,
    proposal: &Proposal,
    now: i64,
) -> ApiResult<Value> {
    let event = match proposal.operation.as_str() {
        "create" => super::create(conn, user, &proposal.id, &proposal.spec, now)?,
        "update" => {
            let id = proposal
                .event_id
                .as_deref()
                .ok_or_else(ApiError::internal)?;
            let revision = proposal.expected_revision.ok_or_else(ApiError::internal)?;
            super::update(
                conn,
                user,
                id,
                &proposal.spec,
                crate::calendar::Mutation {
                    revision,
                    scope: &proposal.scope,
                    occurrence: proposal.occurrence.as_deref(),
                },
                now,
            )?
        }
        "delete" => {
            let id = proposal
                .event_id
                .as_deref()
                .ok_or_else(ApiError::internal)?;
            let revision = proposal.expected_revision.ok_or_else(ApiError::internal)?;
            super::remove(
                conn,
                user,
                id,
                revision,
                &proposal.scope,
                proposal.occurrence.as_deref(),
                now,
            )?;
            return Ok(json!({ "status": "approved", "eventId": id, "deleted": true }));
        }
        _ => return Err(ApiError::internal()),
    };
    Ok(json!({ "status": "approved", "eventId": event.id, "revision": event.revision }))
}

fn answered_value(id: &str, result: Value) -> Value {
    json!({ "interactionId": card_id(id), "status": "answered", "result": result })
}

fn publish_answered(app: &AppState, session_id: &str, id: &str) -> ApiResult<()> {
    let epoch = app.db.lock().get_session(session_id)?.runner_epoch;
    app.events.publish(
        session_id,
        epoch,
        "interaction_answered",
        json!({ "interactionId": card_id(id), "interactionEpoch": 0 }),
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn calendar_permissions_default_to_deny_and_are_independent() {
        let db = crate::db::Db::memory();
        let conn = db.lock();
        assert_eq!(
            permissions(&conn, "owner@example.com").unwrap(),
            Permissions::default()
        );
        assert_eq!(
            set_permissions(
                &conn,
                "owner@example.com",
                Permissions {
                    allow_read: true,
                    allow_propose: false
                },
            )
            .unwrap(),
            Permissions {
                allow_read: true,
                allow_propose: false
            },
        );
        assert_eq!(
            permissions(&conn, "owner@example.com").unwrap(),
            Permissions {
                allow_read: true,
                allow_propose: false
            },
        );
        set_permissions(
            &conn,
            "owner@example.com",
            Permissions {
                allow_read: false,
                allow_propose: true,
            },
        )
        .unwrap();
        assert_eq!(
            permissions(&conn, "owner@example.com").unwrap(),
            Permissions {
                allow_read: false,
                allow_propose: true
            },
        );
    }

    #[test]
    fn proposal_result_never_returns_event_content() {
        let result = agent_result(&json!({
            "status": "approved",
            "eventId": "event-1",
            "revision": 2,
            "event": { "title": "Private title", "description": "Private details" },
        }));
        assert_eq!(
            result,
            json!({ "status": "approved", "eventId": "event-1", "revision": 2 })
        );
        assert!(result.get("event").is_none());
    }

    #[test]
    fn expired_proposals_sweep_and_publish_the_close_once() {
        use crate::db::Store;

        let (app, _dir) = crate::calendar::tests::fixture();
        let session_id = {
            let conn = app.db.lock();
            conn.sync_remote_workspaces(
                "work",
                &[(
                    "calendar".into(),
                    "Calendar workspace".into(),
                    pirc_protocol::mode::ModeId::new("directory").unwrap(),
                )],
            )
            .unwrap();
            conn.create_session(
                "work:calendar",
                "node://work/calendar-chat",
                "work",
                "calendar-chat",
                "alice",
            )
            .unwrap()
            .id
        };
        let proposal_id = crate::util::new_id("cp");
        let spec = Spec {
            title: "Expired event".into(),
            description: String::new(),
            location: String::new(),
            start: "2026-10-21T09:00".into(),
            end: "2026-10-21T10:00".into(),
            timezone: "UTC".into(),
            all_day: false,
            recurrence: None,
            reminder_minutes: Vec::new(),
        };
        app.db
            .lock()
            .execute(
                "INSERT INTO calendar_proposals
                 (id,owner_user,session_id,event_id,expected_revision,operation,spec_json,
                  scope,occurrence,request_hash,status,expires_at,created_at)
                 VALUES (?,?,?,?,?,?,?,'series',NULL,?,'pending',0,0)",
                rusqlite::params![
                    proposal_id,
                    "alice",
                    session_id,
                    "event-expired",
                    1,
                    "delete",
                    serde_json::to_string(&spec).unwrap(),
                    "expired-request"
                ],
            )
            .unwrap();

        let result = proposal_result(&app, "alice", &session_id, &proposal_id).unwrap();
        assert_eq!(result["status"], "expired");
        assert_eq!(result["eventId"], "event-expired");

        let replay = app.events.replay(&session_id, None, 0);
        let close_events: Vec<_> = replay
            .events
            .iter()
            .filter(|event| event.kind == "interaction_answered")
            .collect();
        assert_eq!(close_events.len(), 1);
        assert_eq!(
            close_events[0].data.as_ref().unwrap()["interactionId"],
            card_id(&proposal_id)
        );

        let second_proposal_id = crate::util::new_id("cp");
        app.db
            .lock()
            .execute(
                "INSERT INTO calendar_proposals
                 (id,owner_user,session_id,event_id,expected_revision,operation,spec_json,
                  scope,occurrence,request_hash,status,expires_at,created_at)
                 VALUES (?,?,?,?,?,?,?,'series',NULL,?,'pending',0,0)",
                rusqlite::params![
                    second_proposal_id,
                    "alice",
                    session_id,
                    "event-expired-2",
                    1,
                    "delete",
                    serde_json::to_string(&spec).unwrap(),
                    "expired-request-2"
                ],
            )
            .unwrap();
        assert_eq!(
            answer(
                &app,
                &session_id,
                &card_id(&second_proposal_id),
                "alice",
                Some(&json!({ "confirmed": true })),
            )
            .unwrap_err()
            .status,
            409
        );

        assert!(pending_interactions(&app, &session_id).is_empty());
        let replay = app.events.replay(&session_id, None, 0);
        assert_eq!(replay.events.len(), 2);
    }

    #[test]
    fn agent_calendar_query_redacts_schedule_prompt_and_run_history() {
        let mut result = json!({
            "items": [
                {
                    "id": "schedule:s1:123",
                    "type": "schedule",
                    "sourceId": "s1",
                    "title": "Daily task",
                    "startAt": 123,
                    "state": "completed",
                    "schedule": { "prompt": "private instructions" },
                    "run": { "result": "private execution output", "sessionId": "secret-session" },
                },
                {
                    "id": "event:e1:2026-10-21T09:00",
                    "type": "event",
                    "event": { "title": "Dentist" },
                },
            ],
            "limited": false,
        });

        redact_schedule_details(&mut result);

        let schedule = &result["items"][0];
        assert_eq!(schedule["title"], "Daily task");
        assert_eq!(schedule["state"], "completed");
        assert!(schedule.get("schedule").is_none());
        assert!(schedule.get("run").is_none());
        assert_eq!(result["items"][1]["event"]["title"], "Dentist");
    }
}
