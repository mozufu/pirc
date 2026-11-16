//! A durable refusal of one environment-transition operation identity. When the
//! Gateway cannot tell whether the one request that creates a fence will ever
//! arrive, one transaction here either returns the fence the Node already holds
//! (nothing is written) or records that this operation will never get one. The
//! fence-creating transaction checks the record first, so exactly one of "create"
//! and "void" wins, in either order, bound to the owner, the session and the
//! operation id. Both run under the store's single connection lock inside
//! `BEGIN IMMEDIATE`; the triggers in `voids.sql` enforce the same exclusion in
//! the database itself.
use super::*;
use rusqlite::TransactionBehavior;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Void {
    /// Hash of the frozen plan of the intent the Gateway sent (or may have sent).
    plan_hash: String,
}

fn hex64(text: &str) -> bool {
    text.len() == 64
        && text
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

fn refused() -> ApiError {
    ApiError::new(
        409,
        "operation_voided",
        "This environment switch was cancelled before the Node created its fence; start a new switch",
    )
}

/// `(session, plan hash)` recorded by a void of this operation, if any.
fn recorded(db: &Connection, owner: &str, op: &str) -> ApiResult<Option<(String, String)>> {
    Ok(db
        .query_row(
            "SELECT session_id,plan_hash FROM execution_fence_voids WHERE owner_user=?1 AND operation_id=?2",
            params![owner, op],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()?)
}

/// First check of the fence-creating transaction: a voided operation is refused
/// whatever its content, before any receipt is looked at or anything is created.
pub(super) fn require_not_voided(db: &Connection, owner: &str, op: &str) -> ApiResult<()> {
    if recorded(db, owner, op)?.is_some() {
        return Err(refused());
    }
    Ok(())
}

/// What the one transaction decided.
enum Decision {
    Fence(Box<Receipt>),
    Voided(String),
}

fn decide(
    db: &mut Connection,
    owner: &str,
    session: &str,
    op: &str,
    plan_hash: &str,
) -> ApiResult<Decision> {
    // The write lock is taken now, not at the first write: the check below and
    // the insert are one decision. The connection lock already keeps every other
    // user of this connection out; IMMEDIATE also guards a second connection.
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    if let Some(saved) = receipt(&tx, owner, session, op)? {
        if saved.intent.plan_hash != plan_hash {
            return Err(ApiError::conflict(
                "Transition identity already has a different plan",
            ));
        }
        // Already created: report it. Nothing is voided, and nothing changes.
        tx.commit()?;
        return Ok(Decision::Fence(Box::new(saved)));
    }
    let elsewhere: Option<String> = tx
        .query_row(
            "SELECT session_id FROM execution_fences WHERE owner_user=?1 AND operation_id=?2",
            params![owner, op],
            |r| r.get(0),
        )
        .optional()?;
    if elsewhere.is_some() {
        return Err(ApiError::conflict(
            "Transition identity belongs to another conversation",
        ));
    }
    // The owner binding: another user's session does not exist here.
    tx.claim_session(session, owner, false)?;
    match recorded(&tx, owner, op)? {
        Some((saved_session, saved_plan)) => {
            if saved_session != session || saved_plan != plan_hash {
                return Err(ApiError::conflict(
                    "Transition identity belongs to another conversation or plan",
                ));
            }
        }
        None => {
            tx.execute(
                "INSERT INTO execution_fence_voids(owner_user,operation_id,session_id,plan_hash,created_at) VALUES(?1,?2,?3,?4,?5)",
                params![owner, op, session, plan_hash, now_ms()],
            )?;
        }
    }
    tx.commit()?;
    Ok(Decision::Voided(session.to_owned()))
}

pub async fn void(node: Node, request: Request) -> ApiResult<Response> {
    let session = request
        .param("id")
        .filter(|id| valid_id(id))
        .ok_or_else(ApiError::invalid_input)?
        .to_owned();
    let op = request
        .param("operation")
        .filter(|id| valid_id(id))
        .ok_or_else(ApiError::invalid_input)?
        .to_owned();
    let input: Void = request.parse_body()?;
    if !hex64(&input.plan_hash) {
        return Err(ApiError::invalid_input());
    }
    let decision = decide(
        &mut node.db.lock(),
        &request.user,
        &session,
        &op,
        &input.plan_hash,
    )?;
    Ok(Response::json(match decision {
        Decision::Voided(session) => {
            json!({"void":{"result":"voided","operationId":op,"sessionId":session}})
        }
        Decision::Fence(saved) => {
            let saved = network_observation(&node, &session, *saved);
            json!({"void":{"result":"fence","operationId":op,"sessionId":session},"transition":saved})
        }
    }))
}

#[cfg(test)]
mod tests;
