//! A durable refusal of one first-message command identity. When the Gateway
//! cannot tell whether a relayed admission will ever arrive, one transaction
//! here either returns the admission the Node already holds (admitted, rejected
//! or still pending: nothing is written) or records that the command id will
//! never be admitted. Both run under the store's single connection lock inside
//! `BEGIN IMMEDIATE`, so exactly one of "admit" and "void" wins, in either order.
use super::*;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Void {
    command_id: String,
    submission_hash: String,
    /// Hash of the exact input of the attempt, as `Input::hash` computes it.
    input_hash: String,
}

fn hex64(text: &str) -> bool {
    text.len() == 64
        && text
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

fn voided(code: &'static str) -> ApiError {
    ApiError::new(
        409,
        code,
        "This first-message attempt was voided and can never be admitted; retry explicitly",
    )
}

/// The input hash a void recorded for `command`, if it was voided for this
/// owner and creation.
pub(super) fn voided_input(
    db: &Connection,
    owner: &str,
    op: &str,
    command: &str,
) -> ApiResult<Option<String>> {
    Ok(db.query_row("SELECT input_hash FROM creation_admission_voids WHERE owner_user=?1 AND operation_id=?2 AND command_id=?3",params![owner,op,command],|r|r.get(0)).optional()?)
}

/// First check of every admission transaction. A voided id is refused whatever
/// the content, before anything is looked up or created. The same id under a
/// different creation is refused by the table's uniqueness and the triggers.
pub(super) fn require_not_voided(
    db: &Connection,
    owner: &str,
    op: &str,
    command: &str,
) -> ApiResult<()> {
    let voided_anywhere: bool = db.query_row(
        "SELECT EXISTS(SELECT 1 FROM creation_admission_voids WHERE command_id=?1)",
        [command],
        |r| r.get(0),
    )?;
    if voided_anywhere || voided_input(db, owner, op, command)?.is_some() {
        return Err(voided("command_voided"));
    }
    Ok(())
}

fn answer(op: &str, command: &str, session: &str, result: &str) -> Value {
    json!({"void":{"result":result,"operationId":op,"commandId":command,"sessionId":session}})
}

pub(crate) async fn void(node: crate::services::Node, request: Request) -> ApiResult<Response> {
    let op = request
        .param("id")
        .filter(|id| valid_id(id))
        .ok_or_else(ApiError::invalid_input)?
        .to_owned();
    let input: Void = request.parse_body()?;
    if !valid_id(&input.command_id) || !hex64(&input.submission_hash) || !hex64(&input.input_hash) {
        return Err(ApiError::invalid_input());
    }
    let mut db = node.db.lock();
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    // The owner binding: another user's creation does not exist here.
    let parent = creation(&tx, &request.user, &op)?;
    if parent.submission_hash != input.submission_hash {
        return Err(ApiError::conflict("Submission identity changed"));
    }
    if matches!(parent.state, State::Deleting | State::Deleted) {
        // A deleted conversation's missing command proves nothing.
        let response = receipt(&tx, &request.user, &op)?;
        tx.commit()?;
        return Ok(response);
    }
    let attempt: bool = tx.query_row(
        "SELECT EXISTS(SELECT 1 FROM creation_admission_attempts WHERE owner_user=?1 AND operation_id=?2 AND command_id=?3)",
        params![request.user, op, input.command_id],
        |r| r.get(0),
    )?;
    if attempt {
        // Already decided: report it. Nothing is voided, and nothing changes.
        let admission = receipt_for(&tx, &request.user, &op, Some(&input.command_id))?
            .body
            .unwrap_or(Value::Null);
        tx.commit()?;
        let mut body = answer(&op, &input.command_id, &parent.session_id, "admission");
        body["admission"] = admission["admission"].clone();
        return Ok(Response::json(body));
    }
    let occupied: bool = tx.query_row(
        "SELECT EXISTS(SELECT 1 FROM commands WHERE id=?1)",
        [&input.command_id],
        |r| r.get(0),
    )?;
    if occupied {
        return Err(ApiError::conflict(
            "Command identity belongs to another admission",
        ));
    }
    if let Some(recorded) = voided_input(&tx, &request.user, &op, &input.command_id)? {
        if recorded != input.input_hash {
            return Err(ApiError::conflict(
                "Command identity belongs to other content",
            ));
        }
    } else {
        if voided_anywhere(&tx, &input.command_id)? {
            return Err(ApiError::conflict(
                "Command identity belongs to another creation",
            ));
        }
        tx.execute(
            "INSERT INTO creation_admission_voids(owner_user,operation_id,command_id,session_id,input_hash,created_at) VALUES(?1,?2,?3,?4,?5,?6)",
            params![request.user, op, input.command_id, parent.session_id, input.input_hash, now_ms()],
        )?;
    }
    tx.commit()?;
    Ok(Response::json(answer(
        &op,
        &input.command_id,
        &parent.session_id,
        "voided",
    )))
}

fn voided_anywhere(db: &Connection, command: &str) -> ApiResult<bool> {
    Ok(db.query_row(
        "SELECT EXISTS(SELECT 1 FROM creation_admission_voids WHERE command_id=?1)",
        [command],
        |r| r.get(0),
    )?)
}

#[cfg(test)]
mod tests;
