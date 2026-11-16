//! A durable successor command for a positively rejected original input.
mod retirement;
use super::*;
pub(super) use retirement::retire;
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Retry {
    retry_id: String,
    previous_command_id: String,
    client_id: String,
    generation: i64,
}
pub(super) fn current_id(
    db: &Connection,
    user: &str,
    op: &str,
    command: &str,
) -> ApiResult<Option<String>> {
    Ok(db.query_row("SELECT retry_id FROM conversation_submission_retry_attempts WHERE owner_user=?1 AND operation_id=?2 AND command_id=?3",params![user,op,command],|r|r.get(0)).optional()?)
}
/// The predecessor of `command` when it is an explicit retry attempt.
pub(super) fn previous_of(
    db: &Connection,
    user: &str,
    op: &str,
    command: &str,
) -> ApiResult<Option<String>> {
    Ok(db.query_row("SELECT previous_command_id FROM conversation_submission_retry_attempts WHERE owner_user=?1 AND operation_id=?2 AND command_id=?3",params![user,op,command],|r|r.get(0)).optional()?)
}
pub(super) fn current_number(
    db: &Connection,
    user: &str,
    op: &str,
    command: &str,
) -> ApiResult<i64> {
    Ok(db.query_row("SELECT attempt_number FROM conversation_submission_retry_attempts WHERE owner_user=?1 AND operation_id=?2 AND command_id=?3",params![user,op,command],|r|r.get(0)).optional()?.unwrap_or(0))
}
pub(super) fn eligible(record: &Record) -> bool {
    record.hash.is_some()
        && record.state == "rejected"
        && record.outcome == "not_admitted"
        && record.admitted.is_none()
        && !record.stop
        && !record.confirmed
}
fn known(db: &Connection, user: &str, op: &str, input: &Retry) -> ApiResult<bool> {
    lookup(db, user, op)?;
    if let Some(previous) = retirement::previous(db, user, op, &input.retry_id)? {
        return Err(ApiError::new(
            409,
            if previous == input.previous_command_id {
                "retry_retired"
            } else {
                "retry_identity_conflict"
            },
            "This retry identity was permanently retired; check its saved result",
        ));
    }
    let previous:Option<String>=db.query_row("SELECT previous_command_id FROM conversation_submission_retry_attempts WHERE owner_user=?1 AND operation_id=?2 AND retry_id=?3",params![user,op,input.retry_id],|r|r.get(0)).optional()?;
    if let Some(previous) = previous {
        if previous != input.previous_command_id {
            return Err(ApiError::new(
                409,
                "retry_identity_conflict",
                "Retry identity belongs to a different attempt",
            ));
        }
        return Ok(true);
    }
    Ok(false)
}
fn reserve(
    app: &AppState,
    identity: &Identity,
    op: &str,
    input: &Retry,
) -> ApiResult<Option<Send>> {
    let mut db = app.db.lock();
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    if known(&tx, &identity.user, op, input)? {
        tx.commit()?;
        return Ok(None);
    }
    let prior = read(&tx, &identity.user, op)?.ok_or_else(|| {
        ApiError::new(
            409,
            "admission_not_retryable",
            "There is no rejected first-message attempt",
        )
    })?;
    if !eligible(&prior) {
        return Err(ApiError::new(
            409,
            "admission_not_retryable",
            "Only a confirmed rejection permits a new attempt",
        ));
    }
    if prior.command != input.previous_command_id {
        return Err(ApiError::new(
            409,
            "admission_attempt_changed",
            "The first-message attempt changed; check its result",
        ));
    }
    let control = Control {
        client_id: input.client_id.clone(),
        generation: input.generation,
    };
    let mut send = validated_send(app, &tx, identity, op, &control)?;
    if prior.hash.as_deref() != Some(&send.hash) {
        return Err(ApiError::new(
            409,
            "submission_changed",
            "The original first-message input changed",
        ));
    }
    send.command = new_id("cmd");
    send.request["commandId"] = json!(send.command);
    tx.receive_command(
        &send.command,
        &send.session,
        &payload_hash(&send.payload),
        &send.payload,
    )?;
    tx.update_command(&send.command, "dispatched", None, None)?;
    let stamp = now_ms();
    let attempt = current_number(&tx, &identity.user, op, &prior.command)?
        .checked_add(1)
        .ok_or_else(ApiError::internal)?;
    tx.execute("INSERT INTO conversation_submission_retry_attempts(owner_user,operation_id,retry_id,command_id,previous_command_id,created_at,attempt_number) VALUES(?1,?2,?3,?4,?5,?6,?7)",params![identity.user,op,input.retry_id,send.command,input.previous_command_id,stamp,attempt])?;
    tx.execute("UPDATE conversation_submission_dispatches SET command_id=?3,input_hash=?4,state='dispatched',outcome='pending',last_error_code=NULL,updated_at=?5 WHERE owner_user=?1 AND operation_id=?2",params![identity.user,op,send.command,send.hash,stamp])?;
    tx.commit()?;
    Ok(Some(send))
}
pub(super) async fn retry(
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
    let input: Retry = body.parse()?;
    if !valid_id(&input.retry_id) || !valid_id(&input.previous_command_id) {
        return Err(ApiError::invalid_input());
    }
    Control {
        client_id: input.client_id.clone(),
        generation: input.generation,
    }
    .validate()?;
    let duplicate = {
        let db = app.db.lock();
        known(&db, &identity.user, &op, &input)?
    };
    if duplicate {
        return Ok(axum::Json(
            json!({"preparation":reconcile(&app,&identity,&op).await?}),
        ));
    }
    let (row, target) = {
        let db = app.db.lock();
        require_caller(&app, &db, &identity)?;
        let row = lookup(&db, &identity.user, &op)?;
        let target = target(&db, &identity.user, &op)?;
        require_current(&app, &db, &identity.user, &row, &target)?;
        (row, target)
    };
    let connection = app.nodes.connection(&target.node)?;
    let caps = app
        .nodes
        .request_on(
            &target.node,
            connection,
            pirc_protocol::NodeHttpRequest {
                method: HttpMethod::Get,
                url: "/api/session-creations/capabilities".into(),
                user: identity.user.clone(),
                payload: None,
                body_base64: None,
                content_type: None,
            },
        )
        .await?;
    if caps.status >= 400
        || caps
            .body
            .as_ref()
            .is_none_or(|v| v["version"] != 1 || v["canRetryInitialAdmission"] != true)
    {
        return Err(ApiError::new(
            409,
            "initial_retry_unsupported",
            "The Node must be upgraded before retrying this first message",
        ));
    }
    super::super::acceptance::check_support(
        caps,
        row.submission
            .as_ref()
            .ok_or_else(super::super::acceptance::pending_error)?,
    )?;
    app.nodes.require_connection(&target.node, connection)?;
    let Some(send) = reserve(&app, &identity, &op, &input)? else {
        return Ok(axum::Json(
            json!({"preparation":reconcile(&app,&identity,&op).await?}),
        ));
    };
    Ok(axum::Json(
        json!({"preparation":send_attempt(&app,&identity,&op,send,Some(&input.previous_command_id),connection).await?}),
    ))
}
pub(super) async fn status(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path((op, id)): Path<(String, String)>,
) -> ApiResult<axum::Json<Value>> {
    if !valid_id(&op) || !valid_id(&id) {
        return Err(ApiError::invalid_input());
    }
    if let Some(receipt) = retirement::receipt(&app.db.lock(), &identity.user, &op, &id)? {
        return Ok(axum::Json(receipt));
    }
    let (command, previous, number): (String, String, i64) = {
        let db = app.db.lock();
        lookup(&db, &identity.user, &op)?;
        db.query_row("SELECT command_id,previous_command_id,attempt_number FROM conversation_submission_retry_attempts WHERE owner_user=?1 AND operation_id=?2 AND retry_id=?3",params![identity.user,op,id],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?))).optional()?.ok_or_else(||ApiError::not_found("Retry not found"))?
    };
    let preparation = reconcile(&app, &identity, &op).await?;
    let (current, state) = {
        let db = app.db.lock();
        let current = read(&db, &identity.user, &op)?.is_some_and(|r| r.command == command);
        let state = if preparation.state == Phase::Cancelled {
            "cancelled".into()
        } else {
            db.get_command(&command)
                .map(|c| c.status)
                .unwrap_or_else(|_| "outcome_unknown".into())
        };
        (current, state)
    };
    Ok(axum::Json(
        json!({"retry":{"retryId":id,"commandId":command,"previousCommandId":previous,"attemptNumber":number,"isCurrent":current,"status":state},"preparation":preparation}),
    ))
}

/// A global first-input Stop applies even if this retry never reached the Node.
/// The predecessor's rejection is never evidence about the new command's admission.
pub(super) fn apply_global_fence(
    app: &AppState,
    identity: &Identity,
    op: &str,
    evidence: &Value,
) -> ApiResult<bool> {
    if evidence["stopRequested"] != true {
        return Ok(false);
    }
    if !evidence["stopConfirmed"].is_boolean()
        || !matches!(evidence["state"].as_str(), Some("stopped" | "stopping"))
    {
        return Err(invalid_receipt());
    }
    let mut db = app.db.lock();
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let row = lookup(&tx, &identity.user, op)?;
    if row.state == Phase::Cancelled {
        tx.commit()?;
        return Ok(true);
    }
    let prior = read(&tx, &identity.user, op)?.ok_or_else(invalid_receipt)?;
    let target = target(&tx, &identity.user, op)?;
    let session:Option<String>=tx.query_row("SELECT node_session_id FROM conversation_submission_acceptances WHERE owner_user=?1 AND operation_id=?2",params![identity.user,op],|r|r.get(0))?;
    if evidence["operationId"] != target.creation
        || evidence["sessionId"].as_str() != session.as_deref()
        || prior.hash.as_deref() != evidence["inputHash"].as_str()
    {
        return Err(invalid_receipt());
    }
    let cmd = evidence
        .get("command")
        .filter(|v| !v.is_null())
        .ok_or_else(invalid_receipt)?;
    let command = cmd["id"].as_str().ok_or_else(invalid_receipt)?;
    let known:bool=tx.query_row("SELECT EXISTS(SELECT 1 FROM conversation_submissions WHERE owner_user=?1 AND operation_id=?2 AND command_id=?3 UNION ALL SELECT 1 FROM conversation_submission_retry_attempts WHERE owner_user=?1 AND operation_id=?2 AND command_id=?3)",params![identity.user,op,command],|r|r.get(0))?;
    let spec = specification(&tx, &identity.user, op)?;
    if !known
        || cmd["sessionId"].as_str() != session.as_deref()
        || cmd["payloadHash"] != payload_hash(&spec.payload)
        || !matches!(
            cmd["status"].as_str(),
            Some("received" | "dispatched" | "accepted" | "rejected" | "outcome_unknown")
        )
    {
        return Err(invalid_receipt());
    }
    let confirmed = prior.confirmed || evidence["stopConfirmed"] == true;
    let admitted = prior.admitted.is_some();
    let state = if admitted {
        "accepted"
    } else if confirmed {
        "stopped"
    } else {
        "stopping"
    };
    let outcome = if admitted {
        "admitted"
    } else if prior.outcome == "not_admitted" {
        "not_admitted"
    } else {
        "outcome_unknown"
    };
    if !admitted && outcome == "outcome_unknown" && prior.hash.is_some() {
        tx.update_command(
            &prior.command,
            "outcome_unknown",
            None,
            Some("Stop confirmed separately; this attempt's earlier admission remains unknown"),
        )?;
    }
    tx.execute("UPDATE conversation_submission_dispatches SET state=?3,outcome=?4,stop_requested=1,stop_confirmed=?5,last_error_code=NULL,updated_at=?6 WHERE owner_user=?1 AND operation_id=?2",params![identity.user,op,state,outcome,confirmed,now_ms()])?;
    tx.commit()?;
    Ok(true)
}
#[cfg(test)]
mod tests;
