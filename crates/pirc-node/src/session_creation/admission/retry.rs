//! Explicit, held-lease retry after a durable rejected receipt. Never replay unknown work.
use super::*;
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Retry {
    previous_command_id: String,
    admission: Input,
}
fn reserve(node: &Node, user: &str, op: &str, retry: &Retry) -> ApiResult<Option<String>> {
    let input = &retry.admission;
    let mut db = node.db.lock();
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let parent = creation(&tx, user, op)?;
    // A successor may never reuse a voided command id.
    void::require_not_voided(&tx, user, op, &input.command_id)?;
    if parent.submission_hash != input.submission_hash {
        return Err(ApiError::conflict("Submission identity changed"));
    }
    let prior = read(&tx, user, op)?;
    // The predecessor may be a command the Node never admitted and has since
    // refused for good. Its recorded input must be the one being retried.
    let voided = void::voided_input(&tx, user, op, &retry.previous_command_id)?;
    if let Some(recorded) = &voided
        && *recorded != input.hash()
    {
        return Err(ApiError::conflict(
            "Retry must retain the exact original input",
        ));
    }
    if voided.is_none() {
        let prior = prior
            .as_ref()
            .ok_or_else(|| ApiError::conflict("No initial admission to retry"))?;
        if prior.hash.as_deref() != Some(input.hash().as_str()) {
            return Err(ApiError::conflict(
                "Retry must retain the exact original input",
            ));
        }
    } else if let Some(prior) = &prior
        && prior.hash.as_deref().is_some_and(|h| h != input.hash())
    {
        return Err(ApiError::conflict(
            "Retry must retain the exact original input",
        ));
    }
    let duplicate:Option<(String,Option<String>)>=tx.query_row("SELECT input_hash,previous_command_id FROM creation_admission_attempts WHERE owner_user=?1 AND operation_id=?2 AND command_id=?3",params![user,op,input.command_id],|r|Ok((r.get(0)?,r.get(1)?))).optional()?;
    if let Some((hash, previous)) = duplicate {
        if hash != input.hash() || previous.as_deref() != Some(&retry.previous_command_id) {
            return Err(ApiError::conflict(
                "Retry identity belongs to another attempt",
            ));
        }
        tx.commit()?;
        return Ok(None);
    }
    if parent.state != State::Ready || prior.as_ref().is_some_and(|p| p.stop || p.confirmed) {
        return Err(ApiError::new(
            409,
            "first_message_stopped",
            "The initial message is fenced; reconcile its receipt",
        ));
    }
    if voided.is_some() {
        // The head, if any, is the last attempt that did reach this Node; it
        // must be decided as rejected before anything new is admitted.
        if let Some(head) = prior.as_ref().and_then(|p| p.command.as_deref())
            && tx.get_command(head)?.status != CommandStatus::Rejected
        {
            return Err(ApiError::new(
                409,
                "admission_not_retryable",
                "Only a confirmed rejection permits a new attempt",
            ));
        }
    } else {
        let prior = prior.as_ref().expect("checked above");
        if prior.command.as_deref() != Some(&retry.previous_command_id) {
            return Err(ApiError::new(
                409,
                "admission_attempt_changed",
                "Another attempt already replaced this failure",
            ));
        }
        let previous = tx.get_command(&retry.previous_command_id)?;
        if previous.session_id != parent.session_id || previous.status != CommandStatus::Rejected {
            return Err(ApiError::new(
                409,
                "admission_not_retryable",
                "Only a confirmed rejection permits a new attempt",
            ));
        }
    }
    node.workspace_mode(&tx.get_workspace(&parent.workspace_id)?)?;
    tx.validate_lease(&parent.session_id, &input.client_id, input.generation)?;
    let occupied: bool = tx.query_row(
        "SELECT EXISTS(SELECT 1 FROM commands WHERE id=?1)",
        [&input.command_id],
        |r| r.get(0),
    )?;
    if occupied {
        return Err(ApiError::conflict("Command identity is already in use"));
    }
    let payload = serde_json::to_value(input.payload()).map_err(|_| ApiError::internal())?;
    tx.receive_command(
        &input.command_id,
        &parent.session_id,
        &payload_hash(&payload),
        &payload,
    )?;
    let stamp = now_ms();
    if prior.is_none() {
        // The voided first attempt left no admission row: the successor is the first.
        tx.execute("INSERT INTO creation_initial_admissions(owner_user,operation_id,session_id,command_id,input_hash,created_at,updated_at) VALUES(?1,?2,?3,?4,?5,?6,?6)",params![user,op,parent.session_id,input.command_id,input.hash(),stamp])?;
    } else {
        tx.execute("UPDATE creation_initial_admissions SET command_id=?3,input_hash=?5,updated_at=?4 WHERE owner_user=?1 AND operation_id=?2",params![user,op,input.command_id,stamp,input.hash()])?;
    }
    tx.execute("INSERT INTO creation_admission_attempts(owner_user,operation_id,command_id,input_hash,previous_command_id,created_at) VALUES(?1,?2,?3,?4,?5,?6)",params![user,op,input.command_id,input.hash(),retry.previous_command_id,stamp])?;
    tx.commit()?;
    Ok(Some(parent.session_id))
}
pub(crate) async fn retry(node: Node, request: Request) -> ApiResult<Response> {
    let op = request
        .param("id")
        .filter(|id| valid_id(id))
        .ok_or_else(ApiError::invalid_input)?
        .to_owned();
    let retry: Retry = request.parse_body()?;
    retry.admission.validate()?;
    if !valid_id(&retry.previous_command_id)
        || retry.previous_command_id == retry.admission.command_id
    {
        return Err(ApiError::invalid_input());
    }
    let Some(session) = reserve(&node, &request.user, &op, &retry)? else {
        return receipt_for(
            &node.db.lock(),
            &request.user,
            &op,
            Some(&retry.admission.command_id),
        );
    };
    dispatch(node, &op, &request.user, retry.admission, session).await
}
pub(crate) async fn attempt_status(node: Node, request: Request) -> ApiResult<Response> {
    let op = request
        .param("id")
        .filter(|id| valid_id(id))
        .ok_or_else(ApiError::invalid_input)?;
    let command = request
        .param("commandId")
        .filter(|id| valid_id(id))
        .ok_or_else(ApiError::invalid_input)?;
    let db = node.db.lock();
    creation(&db, &request.user, op)?;
    let exists:bool=db.query_row("SELECT EXISTS(SELECT 1 FROM creation_admission_attempts WHERE owner_user=?1 AND operation_id=?2 AND command_id=?3)",params![request.user,op,command],|r|r.get(0))?;
    if !exists {
        return Err(ApiError::not_found("Initial attempt not found"));
    }
    receipt_for(&db, &request.user, op, Some(command))
}
#[cfg(test)]
mod tests;
