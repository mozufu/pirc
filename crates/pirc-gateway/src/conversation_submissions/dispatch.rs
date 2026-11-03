//! Each initial admission attempt is sent once. Known rejection permits an
//! explicit, held-lease successor; unknown outcomes only reconcile receipts.
mod retry;
use super::acceptance::{require_caller, require_current, target};
use super::*;
use pirc_protocol::HttpMethod;

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct MessageAdmission {
    outcome: String,
    command_id: Option<String>,
    retry_id: Option<String>,
    attempt_number: i64,
    retry_eligible: bool,
    stop_requested: bool,
    pub(super) stop_confirmed: bool,
}
struct Record {
    command: String,
    hash: Option<String>,
    state: String,
    outcome: String,
    stop: bool,
    confirmed: bool,
    admitted: Option<i64>,
    error: Option<String>,
}
fn read(db: &Connection, owner: &str, op: &str) -> ApiResult<Option<Record>> {
    Ok(db.query_row("SELECT command_id,input_hash,state,outcome,stop_requested,stop_confirmed,admitted_at,last_error_code FROM conversation_submission_dispatches WHERE owner_user=?1 AND operation_id=?2",params![owner,op],|r|Ok(Record{command:r.get(0)?,hash:r.get(1)?,state:r.get(2)?,outcome:r.get(3)?,stop:r.get(4)?,confirmed:r.get(5)?,admitted:r.get(6)?,error:r.get(7)?})).optional()?)
}
pub(super) fn decorate(
    db: &Connection,
    owner: &str,
    op: &str,
    row: &mut Preparation,
) -> ApiResult<()> {
    if let Some(record) = read(db, owner, op)? {
        row.message_admission = Some(MessageAdmission {
            outcome: record.outcome.clone(),
            command_id: record.hash.as_ref().map(|_| record.command.clone()),
            retry_id: retry::current_id(db, owner, op, &record.command)?,
            attempt_number: retry::current_number(db, owner, op, &record.command)?,
            retry_eligible: retry::eligible(&record),
            stop_requested: record.stop,
            stop_confirmed: record.confirmed,
        });
        if row.state == Phase::Cancelled {
            return Ok(());
        }
        row.delivery_error = record.error;
        row.state = if record.admitted.is_some() {
            Phase::Admitted
        } else {
            match record.state.as_str() {
                "dispatched" => {
                    let cmd = db.get_command(&record.command)?;
                    if cmd.status == "outcome_unknown" {
                        if let Some(admission) = &mut row.message_admission {
                            admission.outcome = "outcome_unknown".into();
                        }
                        Phase::OutcomeUnknown
                    } else {
                        Phase::Sending
                    }
                }
                "accepted" => Phase::Admitted,
                "rejected" => Phase::AdmissionFailed,
                "outcome_unknown" => Phase::OutcomeUnknown,
                "stopping" => Phase::Stopping,
                "stopped" => Phase::Stopped,
                "cancelled" => Phase::Cancelled,
                _ => return Err(ApiError::internal()),
            }
        };
    }
    Ok(())
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Control {
    client_id: String,
    generation: i64,
}
impl Control {
    fn validate(&self) -> ApiResult<()> {
        if self.client_id.is_empty() || self.client_id.len() > 200 || self.generation <= 0 {
            return Err(ApiError::invalid_input());
        }
        Ok(())
    }
}
struct Send {
    command: String,
    request: Value,
    hash: String,
    payload: Value,
    session: String,
}
fn specification(db: &Connection, owner: &str, op: &str) -> ApiResult<Send> {
    let row = lookup(db, owner, op)?;
    let spec = row.submission.as_ref().ok_or_else(|| {
        ApiError::new(409, "submission_unavailable", "The submission was deleted")
    })?;
    let(command,phase,model,thinking,uploads):(String,String,Option<String>,Option<String>,String)=db.query_row("SELECT COALESCE(d.command_id,s.command_id),a.phase,a.model_json,a.thinking,a.upload_ids_json FROM conversation_submissions s JOIN conversation_submission_acceptances a USING(owner_user,operation_id) LEFT JOIN conversation_submission_dispatches d USING(owner_user,operation_id) WHERE s.owner_user=?1 AND s.operation_id=?2",params![owner,op],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?)))?;
    if phase != "ready" {
        return Err(ApiError::new(
            409,
            "submission_not_ready",
            "Prepare the Node and attachments before sending",
        ));
    }
    let model: ModelChoice = serde_json::from_str(model.as_deref().ok_or_else(ApiError::internal)?)
        .map_err(|_| ApiError::internal())?;
    let thinking: ThinkingLevel =
        serde_json::from_value(json!(thinking.ok_or_else(ApiError::internal)?))
            .map_err(|_| ApiError::internal())?;
    let uploads: Vec<String> = serde_json::from_str(&uploads).map_err(|_| ApiError::internal())?;
    if uploads.len() != spec.attachments.len() {
        return Err(ApiError::internal());
    }
    let payload = json!({"type":"prompt","message":spec.message,"uploadIds":uploads});
    let body = json!({"commandId":command,"submissionHash":row.hash,"model":model,"thinking":thinking,"message":spec.message,"uploadIds":payload["uploadIds"]});
    let hash = payload_hash(
        &json!({"submissionHash":row.hash,"model":body["model"],"thinking":thinking,"payload":payload}),
    );
    Ok(Send {
        command,
        request: body,
        hash,
        payload,
        session: row.session_id,
    })
}
fn validated_send(
    app: &AppState,
    db: &Connection,
    identity: &Identity,
    op: &str,
    control: &Control,
) -> ApiResult<Send> {
    let row = lookup(db, &identity.user, op)?;
    let target = target(db, &identity.user, op)?;
    require_caller(app, db, identity)?;
    require_current(app, db, &identity.user, &row, &target)?;
    let claimed = db.claim_session(&row.session_id, &identity.user, false)?;
    crate::conversation_bindings::transitions::require_open(db, &row.session_id)?;
    let expected:Option<String>=db.query_row("SELECT node_session_id FROM conversation_submission_acceptances WHERE owner_user=?1 AND operation_id=?2",params![identity.user,op],|r|r.get(0))?;
    if expected.is_none()
        || expected != claimed.pi_session_id
        || claimed.workspace_id != row.workspace_id
        || claimed.node_id.as_deref() != Some(target.node.as_str())
    {
        return Err(ApiError::new(
            409,
            "submission_target_changed",
            "The original conversation mapping is unavailable",
        ));
    }
    db.validate_lease(&row.session_id, &control.client_id, control.generation)?;
    db.validate_lease_user(&row.session_id, &identity.user)?;
    let mut send = specification(db, &identity.user, op)?;
    let selected: &Value = &send.request["model"];
    if !app
        .models()
        .providers
        .get(
            selected["provider"]
                .as_str()
                .ok_or_else(ApiError::internal)?,
        )
        .is_some_and(|p| p.models.iter().any(|m| m.id == selected["id"]))
    {
        return Err(ApiError::new(
            409,
            "model_unavailable",
            "The accepted model is unavailable; the original message remains pending",
        ));
    }
    send.request["clientId"] = json!(control.client_id);
    send.request["generation"] = json!(control.generation);
    Ok(send)
}
fn reserve(
    app: &AppState,
    identity: &Identity,
    op: &str,
    control: &Control,
) -> ApiResult<Option<Send>> {
    let mut db = app.db.lock();
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let row = lookup(&tx, &identity.user, op)?;
    if row.state == Phase::Cancelled || read(&tx, &identity.user, op)?.is_some() {
        tx.commit()?;
        return Ok(None);
    }
    let mut send = validated_send(app, &tx, identity, op, control)?;
    let occupied: bool = tx.query_row(
        "SELECT EXISTS(SELECT 1 FROM commands WHERE id=?1)",
        [&send.command],
        |r| r.get(0),
    )?;
    if occupied {
        return Err(ApiError::new(
            409,
            "command_identity_conflict",
            "The original command identity is already in use",
        ));
    }
    tx.receive_command(
        &send.command,
        &send.session,
        &payload_hash(&send.payload),
        &send.payload,
    )?;
    tx.update_command(&send.command, "dispatched", None, None)?;
    let stamp = now_ms();
    tx.execute("INSERT INTO conversation_submission_dispatches(owner_user,operation_id,command_id,input_hash,state,outcome,created_at,updated_at) VALUES(?1,?2,?3,?4,'dispatched','pending',?5,?5)",params![identity.user,op,send.command,send.hash,stamp])?;
    send.request["clientId"] = json!(control.client_id);
    send.request["generation"] = json!(control.generation);
    tx.commit()?;
    Ok(Some(send))
}
fn invalid_receipt() -> ApiError {
    ApiError::new(
        502,
        "invalid_admission_receipt",
        "Node did not confirm the original first-message identity",
    )
}
fn apply(app: &AppState, identity: &Identity, op: &str, evidence: &Value) -> ApiResult<()> {
    apply_for(app, identity, op, None, evidence)
}
fn apply_for(
    app: &AppState,
    identity: &Identity,
    op: &str,
    command: Option<&str>,
    evidence: &Value,
) -> ApiResult<()> {
    let mut db = app.db.lock();
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let row = lookup(&tx, &identity.user, op)?;
    if row.state == Phase::Cancelled {
        tx.commit()?;
        return Ok(());
    }
    let Some(previous) = read(&tx, &identity.user, op)? else {
        return Err(invalid_receipt());
    };
    if command.is_some_and(|id| id != previous.command) {
        tx.commit()?;
        return Ok(());
    }
    let target = target(&tx, &identity.user, op)?;
    let remote_session:Option<String>=tx.query_row("SELECT node_session_id FROM conversation_submission_acceptances WHERE owner_user=?1 AND operation_id=?2",params![identity.user,op],|r|r.get(0))?;
    if evidence["operationId"] != target.creation
        || evidence["sessionId"].as_str() != remote_session.as_deref()
        || !evidence["stopRequested"].is_boolean()
        || !evidence["stopConfirmed"].is_boolean()
    {
        return Err(invalid_receipt());
    }
    if evidence["stopConfirmed"] == true && evidence["stopRequested"] != true {
        return Err(invalid_receipt());
    }
    if matches!(evidence["state"].as_str(), Some("deleting" | "deleted")) {
        return Err(ApiError::new(
            409,
            "node_conversation_deleted",
            "The Node conversation was deleted; its missing command is not proof of non-admission",
        ));
    }
    let stop = previous.stop || evidence["stopRequested"] == true;
    let confirmed = previous.confirmed || evidence["stopConfirmed"] == true;
    if confirmed && !stop {
        return Err(invalid_receipt());
    }
    let cmd = evidence.get("command").filter(|v| !v.is_null());
    let (status, outcome) = if let Some(cmd) = cmd {
        let expected = specification(&tx, &identity.user, op)?;
        if evidence["inputHash"] != expected.hash
            || previous.hash.as_deref() != Some(&expected.hash)
            || cmd["id"] != previous.command
            || cmd["sessionId"].as_str() != remote_session.as_deref()
            || cmd["payloadHash"] != payload_hash(&expected.payload)
        {
            return Err(invalid_receipt());
        }
        let status = cmd["status"].as_str().ok_or_else(invalid_receipt)?;
        match status {
            "accepted" => ("accepted", "admitted"),
            "rejected" => ("rejected", "not_admitted"),
            "received" | "dispatched" => ("dispatched", "pending"),
            "outcome_unknown" => ("outcome_unknown", "outcome_unknown"),
            _ => return Err(invalid_receipt()),
        }
    } else if evidence["stopConfirmed"] == true
        || (previous.confirmed && previous.outcome == "not_admitted")
    {
        // A stale empty receipt cannot combine with an earlier Stop flag to
        // prove non-admission of a command whose outcome was still unknown.
        ("stopped", "not_admitted")
    } else {
        ("outcome_unknown", "outcome_unknown")
    };
    let known = previous.admitted.is_some() || outcome == "admitted";
    let state = if known {
        "accepted"
    } else if confirmed {
        "stopped"
    } else if stop {
        "stopping"
    } else {
        status
    };
    let outcome = if known { "admitted" } else { outcome };
    let stamp = now_ms();
    if previous.hash.is_some() && (previous.admitted.is_none() || status == "accepted") {
        // Preserve the complete accepted receipt, including its result.
        let mirror = if known {
            "accepted"
        } else if status == "stopped" {
            "rejected"
        } else {
            status
        };
        tx.update_command(
            &previous.command,
            mirror,
            cmd.and_then(|c| c.get("result")),
            None,
        )?;
    }
    tx.execute("UPDATE conversation_submission_dispatches SET state=?3,outcome=?4,stop_requested=?5,stop_confirmed=?6,admitted_at=CASE WHEN ?7 THEN COALESCE(admitted_at,?8) ELSE admitted_at END,last_error_code=NULL,updated_at=?8 WHERE owner_user=?1 AND operation_id=?2",params![identity.user,op,state,outcome,stop,confirmed,known,stamp])?;
    if known && previous.admitted.is_none() {
        let ids = row
            .submission
            .as_ref()
            .ok_or_else(ApiError::internal)?
            .attachments
            .iter()
            .map(|a| &a.id)
            .collect::<Vec<_>>();
        tx.execute("INSERT INTO conversation_submission_cleanup(session_id,owner_user,operation_id,attachment_ids_json,created_at) VALUES(?1,?2,?3,?4,?5) ON CONFLICT(session_id) DO NOTHING",params![row.session_id,identity.user,op,serde_json::to_string(&ids).map_err(|_|ApiError::internal())?,stamp])?;
        tx.execute("DELETE FROM conversation_submission_attachments WHERE owner_user=?1 AND operation_id=?2",params![identity.user,op])?;
    }
    tx.commit()?;
    Ok(())
}
#[cfg(test)]
fn failure(app: &AppState, identity: &Identity, op: &str, code: &str) -> ApiResult<()> {
    failure_for(app, identity, op, None, code)
}
fn failure_for(
    app: &AppState,
    identity: &Identity,
    op: &str,
    command: Option<&str>,
    code: &str,
) -> ApiResult<()> {
    let db = app.db.lock();
    crate::db::atomic(&db, |tx| {
        let Some(record) = read(tx, &identity.user, op)? else {
            return Ok(());
        };
        if command.is_some_and(|id| id != record.command) {
            return Ok(());
        }
        if record.admitted.is_some()
            || record.confirmed
            || record.outcome == "not_admitted"
            || record.state == "cancelled"
        {
            return Ok(());
        }
        if record.hash.is_some() {
            tx.update_command(
                &record.command,
                "outcome_unknown",
                None,
                Some("First-message outcome is unconfirmed; reconcile without replaying"),
            )?;
        }
        tx.execute("UPDATE conversation_submission_dispatches SET state=CASE WHEN stop_requested=1 THEN 'stopping' ELSE 'outcome_unknown' END,outcome='outcome_unknown',last_error_code=?3,updated_at=?4 WHERE owner_user=?1 AND operation_id=?2",params![identity.user,op,code,now_ms()])?;
        Ok(())
    })
}

fn complete(
    app: &AppState,
    identity: &Identity,
    op: &str,
    command: &str,
    result: ApiResult<pirc_protocol::NodeHttpResponse>,
) -> ApiResult<()> {
    match result {
        Ok(remote) if remote.status < 400 => {
            if let Err(error) = apply_for(
                app,
                identity,
                op,
                Some(command),
                remote
                    .body
                    .as_ref()
                    .and_then(|b| b.get("admission"))
                    .unwrap_or(&Value::Null),
            ) {
                failure_for(app, identity, op, Some(command), error.code)?;
            }
        }
        Ok(_) => failure_for(
            app,
            identity,
            op,
            Some(command),
            "admission_receipt_unavailable",
        )?,
        Err(error) => failure_for(app, identity, op, Some(command), error.code)?,
    }
    Ok(())
}
async fn send_attempt(
    app: &AppState,
    identity: &Identity,
    op: &str,
    send: Send,
    previous: Option<&str>,
    connection: crate::nodes::NodeConnection,
) -> ApiResult<Preparation> {
    let target = target(&app.db.lock(), &identity.user, op)?;
    let (url, body) = if let Some(previous) = previous {
        (
            format!("/api/session-creations/{}/admission/retry", target.creation),
            json!({"previousCommandId":previous,"admission":send.request}),
        )
    } else {
        (
            format!("/api/session-creations/{}/admission", target.creation),
            send.request,
        )
    };
    let result = app
        .nodes
        .request_on(
            &target.node,
            connection,
            pirc_protocol::NodeHttpRequest {
                method: HttpMethod::Post,
                url,
                user: identity.user.clone(),
                payload: Some(body),
                body_base64: None,
                content_type: None,
            },
        )
        .await;
    complete(app, identity, op, &send.command, result)?;
    app.sessions_changed(Some(&identity.user));
    lookup(&app.db.lock(), &identity.user, op)
}
async fn reconcile(app: &AppState, identity: &Identity, op: &str) -> ApiResult<Preparation> {
    let (row, target, record, retried) = {
        let db = app.db.lock();
        let row = lookup(&db, &identity.user, op)?;
        let target = target(&db, &identity.user, op)?;
        let record = read(&db, &identity.user, op)?;
        let retried = record
            .as_ref()
            .map(|r| retry::current_id(&db, &identity.user, op, &r.command))
            .transpose()?
            .flatten()
            .is_some();
        (row, target, record, retried)
    };
    if row.state == Phase::Cancelled
        || record.is_none()
        || (row.state == Phase::Admitted
            && !record.as_ref().is_some_and(|r| r.stop && !r.confirmed))
        // Only a never-dispatched input can finish reconciliation here. A
        // confirmed ordinary Stop does not resolve an earlier unknown admission.
        || record.as_ref().is_some_and(|r| r.hash.is_none() && r.confirmed)
    {
        return Ok(row);
    }
    if pre_stop::pending(&app.db.lock(), &identity.user, op)? {
        return pre_stop::reconcile(app, &identity.user, op).await;
    }
    let record = record.expect("checked above");
    let url = if retried {
        format!(
            "/api/session-creations/{}/admission/attempts/{}",
            target.creation, record.command
        )
    } else {
        format!("/api/session-creations/{}/admission", target.creation)
    };
    let result = app
        .relay(&target.node, identity, HttpMethod::Get, url, None)
        .await;
    if retried && result.as_ref().is_ok_and(|r| r.status == 404) {
        // An unreceived successor has no per-attempt receipt. A separately
        // confirmed creation-wide Stop still fences it and all late copies.
        if let Ok(global) = app
            .relay(
                &target.node,
                identity,
                HttpMethod::Get,
                format!("/api/session-creations/{}/admission", target.creation),
                None,
            )
            .await
            && global.status < 400
        {
            let proof = global
                .body
                .as_ref()
                .and_then(|v| v.get("admission"))
                .unwrap_or(&Value::Null);
            if proof["command"]["id"] == record.command {
                complete(app, identity, op, &record.command, Ok(global))?;
                return lookup(&app.db.lock(), &identity.user, op);
            }
            if retry::apply_global_fence(app, identity, op, proof).unwrap_or(false) {
                return lookup(&app.db.lock(), &identity.user, op);
            }
        }
    }
    complete(app, identity, op, &record.command, result)?;
    lookup(&app.db.lock(), &identity.user, op)
}
pub(super) fn routes() -> Router<AppState> {
    Router::new()
        .route(
            "/api/conversation-submissions/{id}/dispatch",
            post(dispatch),
        )
        .route("/api/conversation-submissions/{id}/receipt", get(receipt))
        .route(
            "/api/conversation-submissions/{id}/retry",
            post(retry::retry),
        )
        .route(
            "/api/conversation-submissions/{id}/retries/{retryId}",
            get(retry::status),
        )
        .route(
            "/api/conversation-submissions/{id}/retries/{retryId}/retire",
            post(retry::retire),
        )
}
async fn dispatch(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(op): Path<String>,
    headers: axum::http::HeaderMap,
    ReqBody(body): ReqBody,
) -> ApiResult<axum::Json<Value>> {
    client::require(&headers)?;
    if !valid_id(&op) {
        return Err(ApiError::invalid_input());
    }
    let input: Control = body.parse()?;
    input.validate()?;
    let pending = {
        let db = app.db.lock();
        let row = lookup(&db, &identity.user, &op)?;
        if row.state == Phase::Cancelled || read(&db, &identity.user, &op)?.is_some() {
            None
        } else {
            validated_send(&app, &db, &identity, &op, &input)?;
            Some((row, target(&db, &identity.user, &op)?))
        }
    };
    let Some((row, target)) = pending else {
        return Ok(axum::Json(
            json!({"preparation":reconcile(&app,&identity,&op).await?}),
        ));
    };
    let connection = super::acceptance::supported(
        &app,
        &identity,
        &target,
        row.submission
            .as_ref()
            .ok_or_else(super::acceptance::pending_error)?,
    )
    .await?;
    app.nodes.require_connection(&target.node, connection)?;
    let Some(send) = reserve(&app, &identity, &op, &input)? else {
        return Ok(axum::Json(
            json!({"preparation":reconcile(&app,&identity,&op).await?}),
        ));
    };
    Ok(axum::Json(
        json!({"preparation":send_attempt(&app,&identity,&op,send,None,connection).await?}),
    ))
}
async fn receipt(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(op): Path<String>,
) -> ApiResult<axum::Json<Value>> {
    if !valid_id(&op) {
        return Err(ApiError::invalid_input());
    }
    Ok(axum::Json(
        json!({"preparation":reconcile(&app,&identity,&op).await?}),
    ))
}
/// Called only after validating the user's held lease and accepting their Stop
/// command, in that same transaction. This fences future initial sends locally.
pub(crate) fn note_stop(db: &Connection, session: &str, user: &str) -> ApiResult<()> {
    let stamp = now_ms();
    db.execute("INSERT INTO conversation_submission_dispatches(owner_user,operation_id,command_id,state,outcome,stop_requested,created_at,updated_at) SELECT s.owner_user,s.operation_id,s.command_id,'stopping','outcome_unknown',1,?3,?3 FROM conversation_submissions s JOIN conversation_submission_acceptances a USING(owner_user,operation_id) WHERE s.session_id=?1 AND s.owner_user=?2 AND a.phase!='cancelled' ON CONFLICT(owner_user,operation_id) DO UPDATE SET stop_requested=1,state=CASE WHEN admitted_at IS NULL THEN 'stopping' ELSE state END,updated_at=excluded.updated_at",params![session,user,stamp])?;
    Ok(())
}
pub(crate) fn observe_stop(
    app: &AppState,
    identity: &Identity,
    session: &str,
    body: &Value,
) -> ApiResult<()> {
    let op:Option<String>=app.db.lock().query_row("SELECT operation_id FROM conversation_submissions WHERE session_id=?1 AND owner_user=?2",params![session,identity.user],|r|r.get(0)).optional()?;
    if let Some(op) = op
        && let Some(evidence) = body.get("initialAdmission")
        && let Err(error) = apply(app, identity, &op, evidence)
        && (error.code != "invalid_admission_receipt"
            || !retry::apply_global_fence(app, identity, &op, evidence)?)
    {
        return Err(error);
    }
    Ok(())
}
#[cfg(test)]
mod tests;
