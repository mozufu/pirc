//! Permanently fence a local retry nonce that Gateway has never reserved.
use super::*;

pub(super) fn previous(
    db: &Connection,
    user: &str,
    op: &str,
    id: &str,
) -> ApiResult<Option<String>> {
    Ok(db.query_row(
        "SELECT previous_command_id FROM conversation_submission_retry_retirements WHERE owner_user=?1 AND operation_id=?2 AND retry_id=?3",
        params![user, op, id], |r| r.get(0),
    ).optional()?)
}

pub(super) fn receipt(db: &Connection, user: &str, op: &str, id: &str) -> ApiResult<Option<Value>> {
    let preparation = lookup(db, user, op)?;
    Ok(previous(db, user, op, id)?.map(|previous| json!({
        "retry": {"retryId":id, "previousCommandId":previous, "status":"not_reserved", "retired":true},
        "preparation":preparation,
    })))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Retire {
    previous_command_id: String,
    client_id: String,
    generation: i64,
}

/// The reservation and its retirement share the same immediate transaction
/// boundary. Whichever commits first wins; a reserved command is never undone.
fn fence(app: &AppState, identity: &Identity, op: &str, id: &str, input: &Retire) -> ApiResult<()> {
    let mut db = app.db.lock();
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    require_caller(app, &tx, identity)?;
    let row = lookup(&tx, &identity.user, op)?;
    if let Some(previous) = previous(&tx, &identity.user, op, id)? {
        if previous != input.previous_command_id {
            return Err(ApiError::new(
                409,
                "retry_identity_conflict",
                "Retry identity belongs to a different attempt",
            ));
        }
        tx.commit()?;
        return Ok(());
    }
    let retry = Retry {
        retry_id: id.into(),
        previous_command_id: input.previous_command_id.clone(),
        client_id: input.client_id.clone(),
        generation: input.generation,
    };
    if known(&tx, &identity.user, op, &retry)? {
        // Read-only reconciliation is allowed without reacquiring an expired lease.
        tx.commit()?;
        return Ok(());
    }
    let prior = read(&tx, &identity.user, op)?.ok_or_else(|| {
        ApiError::new(
            409,
            "admission_not_retryable",
            "There is no rejected first-message attempt",
        )
    })?;
    if row.state == Phase::Cancelled
        || !eligible(&prior)
        || prior.command != input.previous_command_id
    {
        return Err(ApiError::new(
            409,
            "admission_attempt_changed",
            "The first-message attempt changed; check its result",
        ));
    }
    let session = tx.claim_session(&row.session_id, &identity.user, false)?;
    if session.workspace_id != row.workspace_id {
        return Err(ApiError::new(
            409,
            "submission_target_changed",
            "The original conversation mapping is unavailable",
        ));
    }
    tx.validate_lease(&row.session_id, &input.client_id, input.generation)?;
    tx.validate_lease_user(&row.session_id, &identity.user)?;
    // This revokes one nonce only. It needs no online Node/model and cannot
    // resume work, acquire control, replace input, or clear an operation Stop.
    tx.execute(
        "INSERT INTO conversation_submission_retry_retirements(owner_user,operation_id,retry_id,previous_command_id,retired_at) VALUES(?1,?2,?3,?4,?5)",
        params![identity.user, op, id, input.previous_command_id, now_ms()],
    )?;
    tx.commit()?;
    Ok(())
}

pub(in crate::conversation_submissions) async fn retire(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path((op, id)): Path<(String, String)>,
    ReqBody(body): ReqBody,
) -> ApiResult<axum::Json<Value>> {
    let input: Retire = body.parse()?;
    if !valid_id(&op) || !valid_id(&id) || !valid_id(&input.previous_command_id) {
        return Err(ApiError::invalid_input());
    }
    Control {
        client_id: input.client_id.clone(),
        generation: input.generation,
    }
    .validate()?;
    fence(&app, &identity, &op, &id, &input)?;
    // Both outcomes use the same owned GET receipt. Losing this response is safe:
    // GET finds the permanent fence or the previously reserved command.
    status(State(app), Extension(identity), Path((op, id))).await
}

#[cfg(test)]
mod tests;
