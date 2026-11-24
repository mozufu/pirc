//! Owner-scoped first-send preparation and durable intent acceptance. Acceptance
//! publishes one pending session; Node journal admission/execution remain distinct.
//! Client activation stays gated until durable client recovery is integrated.
mod acceptance;
mod attachments;
mod cancellation;
/// Days a staged attachment of an unaccepted submission is kept.
pub const ATTACHMENT_RETENTION_DAYS: u32 = 7;
mod dispatch;
mod pre_stop;
pub(crate) use acceptance::require_initial_submission_complete;
pub(crate) use cancellation::try_delete;
pub(crate) fn start_cleanup(app: &AppState) {
    attachments::start_cleanup(app);
    cancellation::start_cleanup(app);
    pre_stop::start(app);
    dispatch::start_recovery(app);
}
pub(crate) use dispatch::{note_stop, observe_stop};

use axum::{
    Extension, Router,
    extract::{Path, State},
    routing::{get, post},
};
use pirc_protocol::ThinkingLevel;
use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::{
    app::{AppState, ReqBody},
    auth::Identity,
    db::Store,
    error::{ApiError, ApiResult},
    util::{new_id, now_ms, payload_hash},
};

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ModelChoice {
    provider: String,
    id: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Attachment {
    id: String,
    name: String,
    mime_type: String,
    byte_size: u64,
    sha256: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Spec {
    workspace_id: String,
    message: String,
    #[serde(default)]
    model: Option<ModelChoice>,
    #[serde(default)]
    thinking: Option<ThinkingLevel>,
    #[serde(default)]
    attachments: Vec<Attachment>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Input {
    #[serde(default)]
    expected_owner: Option<String>,
    operation_id: String,
    submission: Spec,
}

fn valid_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 100
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}
fn bounded(text: &str, max: usize) -> bool {
    !text.is_empty() && text.len() <= max && !text.contains('\0')
}
impl Input {
    fn validate(&self, upload_max: u64) -> ApiResult<()> {
        let s = &self.submission;
        if !valid_id(&self.operation_id)
            || !bounded(&s.workspace_id, 256)
            || s.message.encode_utf16().count() > 1_000_000
            || (s.message.trim().is_empty() && s.attachments.is_empty())
            || s.attachments.len() > 16
            || s.model
                .as_ref()
                .is_some_and(|m| !bounded(&m.provider, 1000) || !bounded(&m.id, 1000))
        {
            return Err(ApiError::invalid_input());
        }
        let mut ids = std::collections::HashSet::new();
        for a in &s.attachments {
            let mime = a.mime_type.split_once('/');
            if !valid_id(&a.id)
                || !ids.insert(&a.id)
                || !bounded(&a.name, 1024)
                || a.name
                    .trim_matches(|c: char| c.is_whitespace() || c == '\u{feff}')
                    .is_empty()
                || a.name.encode_utf16().count() > 255
                || a.name.contains(['/', '\\'])
                || a.byte_size == 0
                || a.byte_size > upload_max
                || a.mime_type.len() > 127
                || !mime.is_some_and(|(t, sub)| {
                    !t.is_empty()
                        && !sub.is_empty()
                        && t.bytes()
                            .chain(sub.bytes())
                            .all(|b| b.is_ascii_alphanumeric() || b"!#$&^_.+-".contains(&b))
                })
                || a.sha256.len() != 64
                || !a
                    .sha256
                    .bytes()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
            {
                return Err(ApiError::invalid_input());
            }
        }
        Ok(())
    }
    fn hash(&self) -> String {
        payload_hash(&serde_json::to_value(&self.submission).expect("serializable submission"))
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
enum Phase {
    Preparing,
    Accepted,
    Ready,
    Sending,
    Admitted,
    AdmissionFailed,
    OutcomeUnknown,
    Stopping,
    Stopped,
    Cancelled,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct Preparation {
    operation_id: String,
    session_id: String,
    workspace_id: String,
    state: Phase,
    /// True only after validated intent/session publication committed together.
    accepted: bool,
    /// Validated Node mapping, independent of dispatch/Stop state.
    node_mapped: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    accepted_at: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    delivery_error: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    message_admission: Option<dispatch::MessageAdmission>,
    staged_attachment_ids: Vec<String>,
    attachments_expires_at: Option<i64>,
    attachments_expired_at: Option<i64>,
    cleanup_pending: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    cleanup_error: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    submission: Option<Spec>,
    #[serde(skip)]
    hash: String,
}

fn lookup(db: &Connection, owner: &str, operation: &str) -> ApiResult<Preparation> {
    let mut row=db.query_row(
        "SELECT operation_id,session_id,workspace_id,state,payload_json,submission_hash,attachments_expires_at,attachments_expired_at FROM conversation_submissions WHERE owner_user=?1 AND operation_id=?2",
        params![owner,operation],
        |r| {
            let state:String=r.get(3)?;
            let state=match state.as_str() { "preparing"=>Phase::Preparing,"cancelled"=>Phase::Cancelled,_=>return Err(rusqlite::Error::InvalidQuery) };
            let raw:Option<String>=r.get(4)?;
            let submission=raw.map(|raw|serde_json::from_str(&raw)).transpose().map_err(|_|rusqlite::Error::InvalidQuery)?;
            Ok(Preparation { operation_id:r.get(0)?,session_id:r.get(1)?,workspace_id:r.get(2)?,state,accepted:false,node_mapped:false,accepted_at:None,delivery_error:None,message_admission:None,submission,hash:r.get(5)?,staged_attachment_ids:vec![],attachments_expires_at:r.get(6)?,attachments_expired_at:r.get(7)?,cleanup_pending:false,cleanup_error:None })
        }
    ).optional()?.ok_or_else(||ApiError::not_found("Submission not found"))?;
    if let Some((phase, stamp, error)) = acceptance::summary(db, owner, operation)? {
        row.accepted = true;
        row.node_mapped=db.query_row("SELECT node_session_id IS NOT NULL FROM conversation_submission_acceptances WHERE owner_user=?1 AND operation_id=?2",params![owner,operation],|r|r.get(0))?;
        row.accepted_at = Some(stamp);
        row.delivery_error = error;
        row.state = match phase.as_str() {
            "accepted" => Phase::Accepted,
            "ready" => Phase::Ready,
            "cancelled" => Phase::Cancelled,
            _ => return Err(ApiError::internal()),
        };
    }
    dispatch::decorate(db, owner, operation, &mut row)?;
    let expired = row.state == Phase::Preparing
        && row
            .attachments_expires_at
            .is_some_and(|deadline| deadline <= now_ms());
    row.cleanup_pending = expired
        || db.query_row(
            "SELECT EXISTS(SELECT 1 FROM conversation_submission_cleanup WHERE session_id=?1)",
            [&row.session_id],
            |r| r.get(0),
        )?;
    cancellation::decorate(db, owner, operation, &mut row)?;
    if row.state == Phase::Preparing && !row.cleanup_pending {
        row.staged_attachment_ids=db.prepare("SELECT attachment_id FROM conversation_submission_attachments WHERE owner_user=?1 AND operation_id=?2 ORDER BY attachment_id")?.query_map(params![owner,operation],|r|r.get(0))?.collect::<Result<Vec<_>,_>>()?;
    }
    Ok(row)
}

fn same(row: Preparation, input: &Input) -> ApiResult<Preparation> {
    if row.hash != input.hash() {
        return Err(ApiError::new(
            409,
            "submission_conflict",
            "This submission identity already belongs to different content or a different workspace",
        ));
    }
    Ok(row)
}

/// Serializes independent SQLite connections as well as concurrent HTTP calls.
/// This is a preparation record only: no session, command, Node request or file.
fn reserve(db: &mut Connection, owner: &str, input: &Input) -> ApiResult<Preparation> {
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let exists:bool=tx.query_row("SELECT EXISTS(SELECT 1 FROM conversation_submissions WHERE owner_user=?1 AND operation_id=?2)",params![owner,input.operation_id],|r|r.get(0))?;
    let row = if exists {
        same(lookup(&tx, owner, &input.operation_id)?, input)?
    } else {
        let spec = &input.submission;
        let workspace = tx.get_workspace(&spec.workspace_id)?;
        if !tx.checkpoint_workspace_visible_to_user(&workspace.id, owner)? {
            return Err(ApiError::not_found("Workspace not found"));
        }
        let local = workspace
            .id
            .strip_prefix(&format!("{}:", workspace.host_id))
            .filter(|id| !id.is_empty())
            .ok_or_else(ApiError::invalid_input)?;
        let now = now_ms();
        tx.execute(
            "INSERT INTO conversation_submissions(owner_user,operation_id,workspace_id,node_id,local_workspace_id,session_id,node_operation_id,command_id,submission_hash,payload_json,state,created_at,updated_at) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,'preparing',?11,?11)",
            params![owner,input.operation_id,workspace.id,workspace.host_id,local,new_id("session"),new_id("creation"),new_id("command"),input.hash(),serde_json::to_string(spec).map_err(|_|ApiError::internal())?,now],
        )?;
        lookup(&tx, owner, &input.operation_id)?
    };
    tx.commit()?;
    Ok(row)
}

fn cancel(db: &Connection, owner: &str, operation: &str) -> ApiResult<Preparation> {
    // Acceptance cannot be undone by treating a durable intent as an unsent draft.
    // Session/project deletion owns cancellation once the public session exists.
    if lookup(db, owner, operation)?.accepted {
        return Err(ApiError::new(
            409,
            "submission_accepted",
            "This message is accepted; use the conversation controls",
        ));
    }
    // One statement makes the cancellation fence and content removal atomic.
    if db.execute("UPDATE conversation_submissions SET state='cancelled',payload_json=NULL,updated_at=?3 WHERE owner_user=?1 AND operation_id=?2 AND NOT EXISTS(SELECT 1 FROM conversation_submission_acceptances a WHERE a.owner_user=?1 AND a.operation_id=?2)",params![owner,operation,now_ms()])?==0 {
        return Err(ApiError::new(409,"submission_accepted","This message is accepted; use the conversation controls"));
    }
    lookup(db, owner, operation)
}

pub fn router() -> Router<AppState> {
    Router::new()
        .merge(attachments::routes())
        .merge(acceptance::routes())
        .merge(dispatch::routes())
        .merge(pre_stop::routes())
        .route("/api/conversation-submissions/prepare", post(prepare))
        .route(
            "/api/conversation-submissions/session/{id}",
            get(pending_for_session),
        )
        .route(
            "/api/conversation-submissions/{id}",
            get(status).delete(discard),
        )
}

async fn pending_for_session(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(session): Path<String>,
) -> ApiResult<axum::Json<Value>> {
    let db = app.db.lock();
    let op:Option<String>=db.query_row("SELECT s.operation_id FROM conversation_submissions s JOIN conversation_submission_acceptances a USING(owner_user,operation_id) LEFT JOIN conversation_submission_dispatches d USING(owner_user,operation_id) WHERE s.owner_user=?1 AND s.session_id=?2 AND s.state!='cancelled' AND d.admitted_at IS NULL",params![identity.user,session],|r|r.get(0)).optional()?;
    let op = op.ok_or_else(|| ApiError::not_found("No pending first message"))?;
    Ok(axum::Json(
        json!({"preparation":lookup(&db,&identity.user,&op)?}),
    ))
}

async fn prepare(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    ReqBody(body): ReqBody,
) -> ApiResult<axum::Json<Value>> {
    let input: Input = body.parse()?;
    if input
        .expected_owner
        .as_deref()
        .is_some_and(|owner| owner != identity.user)
    {
        return Err(ApiError::new(
            409,
            "account_changed",
            "The signed-in account changed. Reopen this operation in its original account.",
        ));
    }
    input.validate(app.config.upload_max_bytes as u64)?;
    // A duplicate is an outcome query, even after a model/mode was removed.
    // Checking its immutable content still rejects retargeted retries.
    let existing = match lookup(&app.db.lock(), &identity.user, &input.operation_id) {
        Ok(row) => Some(row),
        Err(e) if e.status == 404 => None,
        Err(e) => return Err(e),
    };
    let row = if let Some(row) = existing {
        same(row, &input)?
    } else {
        let workspace = app
            .db
            .lock()
            .get_workspace(&input.submission.workspace_id)?;
        if !app
            .db
            .lock()
            .checkpoint_workspace_visible_to_user(&workspace.id, &identity.user)?
        {
            return Err(ApiError::not_found("Workspace not found"));
        }
        app.require_mode(&workspace)?;
        if let Some(model) = &input.submission.model {
            let models = app.models();
            if !models
                .providers
                .get(&model.provider)
                .is_some_and(|p| p.models.iter().any(|m| m.id == model.id))
            {
                return Err(ApiError::new(
                    400,
                    "model_unavailable",
                    "The selected model is unavailable",
                ));
            }
        }
        reserve(&mut app.db.lock(), &identity.user, &input)?
    };
    Ok(axum::Json(json!({"preparation":row})))
}
async fn status(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(id): Path<String>,
) -> ApiResult<axum::Json<Value>> {
    if !valid_id(&id) {
        return Err(ApiError::invalid_input());
    }
    Ok(axum::Json(
        json!({"preparation":lookup(&app.db.lock(),&identity.user,&id)?}),
    ))
}
async fn discard(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(id): Path<String>,
) -> ApiResult<axum::Json<Value>> {
    if !valid_id(&id) {
        return Err(ApiError::invalid_input());
    }
    Ok(axum::Json(
        json!({"preparation":cancel(&app.db.lock(),&identity.user,&id)?}),
    ))
}

#[cfg(test)]
mod tests;
