//! Immutable first-message attempts, durable Stop and read-only outcome recovery.
mod retry;
use super::*;
use crate::{
    runner::{CommandPayload, InitialSettings},
    store::CommandStatus,
    util::payload_hash,
};
pub(crate) use retry::{attempt_status, retry};
use serde_json::Value;

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Model {
    provider: String,
    id: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Input {
    command_id: String,
    submission_hash: String,
    model: Model,
    thinking: pirc_protocol::ThinkingLevel,
    message: String,
    #[serde(default)]
    upload_ids: Vec<String>,
    client_id: String,
    generation: i64,
}
impl Input {
    fn validate(&self) -> ApiResult<()> {
        if !valid_id(&self.command_id)
            || self.submission_hash.len() != 64
            || !self
                .submission_hash
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
            || self.client_id.is_empty()
            || self.client_id.len() > 200
            || self.generation <= 0
            || self.message.encode_utf16().count() > 1_000_000
            || self.upload_ids.len() > 16
            || self.upload_ids.iter().any(|id| !valid_id(id))
            || [&self.model.provider, &self.model.id]
                .into_iter()
                .any(|s| s.is_empty() || s.len() > 1000 || s.contains('\0'))
            || (self.message.trim().is_empty() && self.upload_ids.is_empty())
        {
            return Err(ApiError::invalid_input());
        }
        Ok(())
    }
    fn payload(&self) -> CommandPayload {
        CommandPayload::Prompt {
            message: self.message.clone(),
            upload_ids: Some(self.upload_ids.clone()),
        }
    }
    fn hash(&self) -> String {
        payload_hash(
            &json!({"submissionHash":self.submission_hash,"model":self.model,"thinking":self.thinking,"payload":self.payload()}),
        )
    }
}
#[derive(Debug)]
struct Receipt {
    command: Option<String>,
    hash: Option<String>,
    stop: bool,
    confirmed: bool,
}
fn read(db: &Connection, owner: &str, op: &str) -> ApiResult<Option<Receipt>> {
    Ok(db.query_row("SELECT command_id,input_hash,stop_requested,stop_confirmed FROM creation_initial_admissions WHERE owner_user=?1 AND operation_id=?2",params![owner,op],|r|Ok(Receipt{command:r.get(0)?,hash:r.get(1)?,stop:r.get(2)?,confirmed:r.get(3)?})).optional()?)
}
fn creation(db: &Connection, owner: &str, op: &str) -> ApiResult<Creation> {
    let row = super::read(db, owner, op)?
        .ok_or_else(|| ApiError::not_found("Conversation creation not found"))?;
    current(db, owner, row)
}
fn receipt(db: &Connection, owner: &str, op: &str) -> ApiResult<Response> {
    receipt_for(db, owner, op, None)
}
fn receipt_for(
    db: &Connection,
    owner: &str,
    op: &str,
    attempt: Option<&str>,
) -> ApiResult<Response> {
    let parent = creation(db, owner, op)?;
    let row = read(db, owner, op)?;
    if matches!(parent.state, State::Deleting | State::Deleted) {
        return Ok(Response::json(
            json!({"admission":{"operationId":op,"sessionId":parent.session_id,"state":parent.state,"command":null,"stopRequested":true,"stopConfirmed":parent.state==State::Deleted}}),
        ));
    }
    let command = attempt
        .or_else(|| row.as_ref().and_then(|r| r.command.as_deref()))
        .map(|id| db.get_command(id))
        .transpose()?;
    if command
        .as_ref()
        .is_some_and(|c| c.session_id != parent.session_id)
    {
        return Err(ApiError::conflict("Initial attempt binding changed"));
    }
    let stop = row.as_ref().is_some_and(|r| r.stop);
    let confirmed = row.as_ref().is_some_and(|r| r.confirmed);
    let state = if confirmed {
        "stopped"
    } else if stop {
        "stopping"
    } else {
        match command.as_ref().map(|c| c.status) {
            Some(CommandStatus::Accepted) => "accepted",
            Some(CommandStatus::Rejected) => "rejected",
            Some(CommandStatus::OutcomeUnknown) => "outcome_unknown",
            Some(CommandStatus::Received | CommandStatus::Dispatched) => "pending",
            None => "not_submitted",
        }
    };
    Ok(Response::json(
        json!({"admission":{"operationId":op,"sessionId":parent.session_id,"state":state,"command":command,"inputHash":row.as_ref().and_then(|r|r.hash.as_ref()),"stopRequested":stop,"stopConfirmed":confirmed}}),
    ))
}
/// Check under the same DB lock as synchronous RPC enqueue. A Stop either wins
/// before enqueue or its abort is queued after that prompt; it cannot miss it.
pub(crate) fn require_sendable(
    db: &Connection,
    session: &str,
    command: &str,
    user: &str,
) -> ApiResult<()> {
    db.require_session_available(session)?;
    crate::execution_fences::require_open(db, session)?;
    let(op,expected,stop):(String,Option<String>,bool)=db.query_row("SELECT operation_id,command_id,stop_requested FROM creation_initial_admissions WHERE session_id=?1 AND owner_user=?2",params![session,user],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?))).optional()?.ok_or_else(||ApiError::conflict("Initial admission identity is missing"))?;
    let current = creation(db, user, &op)?;
    if current.state != State::Ready || expected.as_deref() != Some(command) || stop {
        return Err(ApiError::new(
            409,
            "first_message_stopped",
            "The initial message is fenced; reconcile its receipt",
        ));
    }
    Ok(())
}
pub(crate) fn require_generic(db: &Connection, session: &str) -> ApiResult<()> {
    let pending:bool=db.query_row("SELECT EXISTS(SELECT 1 FROM session_creations c LEFT JOIN creation_initial_admissions a ON a.owner_user=c.owner_user AND a.operation_id=c.operation_id LEFT JOIN commands q ON q.id=a.command_id WHERE c.session_id=?1 AND COALESCE(q.status,'')!='accepted' AND COALESCE(a.stop_confirmed,0)=0)",[session],|r|r.get(0))?;
    if pending {
        return Err(ApiError::new(
            409,
            "first_message_pending",
            "Reconcile the initial message before another command",
        ));
    }
    Ok(())
}
/// Caller already validated the user's held lease in the same write transaction.
pub(crate) fn request_stop(db: &Connection, session: &str, user: &str) -> ApiResult<bool> {
    let stamp = now_ms();
    let changed=db.execute("INSERT INTO creation_initial_admissions(owner_user,operation_id,session_id,stop_requested,created_at,updated_at) SELECT owner_user,operation_id,session_id,1,?3,?3 FROM session_creations WHERE session_id=?1 AND owner_user=?2 ON CONFLICT(owner_user,operation_id) DO UPDATE SET stop_requested=1,updated_at=excluded.updated_at",params![session,user,stamp])?;
    Ok(changed > 0)
}
pub(crate) fn confirm_stop(db: &Connection, session: &str) -> ApiResult<()> {
    db.execute("UPDATE creation_initial_admissions SET stop_confirmed=1,updated_at=?2 WHERE session_id=?1 AND stop_requested=1",params![session,now_ms()])?;
    Ok(())
}
pub(crate) fn stop_receipt(db: &Connection, session: &str, user: &str) -> ApiResult<Value> {
    let op: String = db.query_row(
        "SELECT operation_id FROM session_creations WHERE session_id=?1 AND owner_user=?2",
        params![session, user],
        |r| r.get(0),
    )?;
    Ok(receipt(db, user, &op)?.body.unwrap_or(Value::Null)["admission"].clone())
}
pub(crate) async fn submit(node: crate::services::Node, request: Request) -> ApiResult<Response> {
    let op = request
        .param("id")
        .filter(|id| valid_id(id))
        .ok_or_else(ApiError::invalid_input)?
        .to_owned();
    let input: Input = request.parse_body()?;
    input.validate()?;
    let session = {
        let mut db = node.db.lock();
        let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let parent = creation(&tx, &request.user, &op)?;
        if parent.submission_hash != input.submission_hash {
            return Err(ApiError::conflict("Submission identity changed"));
        }
        if matches!(parent.state, State::Deleting | State::Deleted) {
            let response = receipt(&tx, &request.user, &op)?;
            tx.commit()?;
            return Ok(response);
        }
        super::pre_stop::mirror(&tx, &request.user, &parent)?;
        if let Some(prior) = read(&tx, &request.user, &op)? {
            let known_attempt:bool=tx.query_row("SELECT EXISTS(SELECT 1 FROM creation_admission_attempts WHERE owner_user=?1 AND operation_id=?2 AND command_id=?3 AND input_hash=?4)",params![request.user,op,input.command_id,input.hash()],|r|r.get(0))?;
            if (prior
                .command
                .as_ref()
                .is_some_and(|id| id != &input.command_id)
                && !known_attempt)
                || prior
                    .hash
                    .as_ref()
                    .is_some_and(|hash| hash != &input.hash())
            {
                return Err(ApiError::conflict(
                    "Initial command identity belongs to different content",
                ));
            }
            if prior.command.is_some()
                || prior.stop
                || matches!(parent.state, State::Deleting | State::Deleted)
            {
                let result = receipt_for(
                    &tx,
                    &request.user,
                    &op,
                    prior.command.as_ref().map(|_| input.command_id.as_str()),
                )?;
                tx.commit()?;
                return Ok(result);
            }
        }
        if parent.state != State::Ready {
            return Err(ApiError::conflict("Conversation storage is not ready"));
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
        tx.execute("INSERT INTO creation_initial_admissions(owner_user,operation_id,session_id,command_id,input_hash,created_at,updated_at) VALUES(?1,?2,?3,?4,?5,?6,?6)",params![request.user,op,parent.session_id,input.command_id,input.hash(),stamp])?;
        tx.execute("INSERT INTO creation_admission_attempts(owner_user,operation_id,command_id,input_hash,created_at) VALUES(?1,?2,?3,?4,?5)",params![request.user,op,input.command_id,input.hash(),stamp])?;
        tx.commit()?;
        parent.session_id
    };
    dispatch(node, &op, &request.user, input, session).await
}
async fn dispatch(
    node: crate::services::Node,
    op: &str,
    user: &str,
    input: Input,
    session: String,
) -> ApiResult<Response> {
    let settings = InitialSettings {
        provider: input.model.provider.clone(),
        model_id: input.model.id.clone(),
        thinking: input.thinking,
    };
    if let Err(error) = node
        .runners
        .dispatch_initial(
            &session,
            &input.command_id,
            &input.payload(),
            user,
            (&input.client_id, input.generation),
            &settings,
        )
        .await
    {
        let db = node.db.lock();
        let row = db.get_command(&input.command_id)?;
        if matches!(
            row.status,
            CommandStatus::Received | CommandStatus::Dispatched
        ) {
            db.update_command(
                &input.command_id,
                if row.status == CommandStatus::Received {
                    CommandStatus::Rejected
                } else {
                    CommandStatus::OutcomeUnknown
                },
                None,
                Some(&error.message),
            )?;
        }
    }
    receipt_for(&node.db.lock(), user, op, Some(&input.command_id))
}
pub(crate) async fn status(node: crate::services::Node, request: Request) -> ApiResult<Response> {
    let op = request
        .param("id")
        .filter(|id| valid_id(id))
        .ok_or_else(ApiError::invalid_input)?;
    receipt(&node.db.lock(), &request.user, op)
}
pub(crate) async fn command_status(
    node: crate::services::Node,
    request: Request,
) -> ApiResult<Response> {
    let session = request.param("id").ok_or_else(ApiError::invalid_input)?;
    let id = request
        .param("commandId")
        .ok_or_else(ApiError::invalid_input)?;
    let db = node.db.lock();
    let session = db.get_session(session)?;
    if session.owner_user.as_deref() != Some(request.user.as_str()) {
        return Err(ApiError::not_found("Command not found"));
    }
    db.require_session_available(&session.id)?;
    let command = db.get_command(id)?;
    if command.session_id != session.id {
        return Err(ApiError::not_found("Command not found"));
    }
    let command = crate::execution_fences::stop_command::refresh(&db, &request.user, command)?;
    Ok(Response::json(json!({"command":command})))
}
#[cfg(test)]
mod tests;
