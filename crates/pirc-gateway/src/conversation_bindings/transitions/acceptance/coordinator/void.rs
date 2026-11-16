//! Cancelling an environment switch whose Node outcome is unknown.
//!
//! The Gateway writes `outcome_unknown` before the one request that creates the
//! Node's fence, so a request that never arrived (or was refused) would block the
//! conversation forever. Only an explicit user cancellation can end that, and only
//! on the Node's own proof: a durable VOID receipt. A GET 404 or a refusal of the
//! original request proves nothing, because a delayed copy may still arrive; they
//! only leave a hint (`waitReason`) so a client can offer Cancel.
//!
//! Cancelling records the cancellation intent and a "void requested" marker in one
//! transaction. From then on the original create request is never sent again. The
//! Gateway then reads the Node's receipt: a fence that exists is adopted and the
//! existing cancel path continues. Otherwise it asks the Node to void the
//! operation, which either returns the fence it holds or refuses the operation for
//! good. Only a `voided` answer moves `outcome_unknown` to `released`, and the
//! database accepts that move only with that answer recorded. A Node that is
//! offline or cannot void leaves everything as it is and the conversation locked:
//! nothing is proven. The request is resent by every sweep and reconnect.
use super::*;

/// Error code of a cancel against a Node that cannot void.
pub(in crate::conversation_bindings::transitions) const UNSUPPORTED: &str =
    "transition_void_unsupported";

/// Whether the Node can void a transition operation.
#[derive(Debug, PartialEq, Eq)]
enum Support {
    Yes,
    No,
    /// Not reachable, or no clear answer: nothing is known about support.
    Unknown,
}

fn unsupported() -> ApiError {
    ApiError::new(
        409,
        UNSUPPORTED,
        "The Node must be upgraded before a switch whose outcome is unknown can be cancelled",
    )
}

/// Whether a void was requested for this operation (the marker).
pub(in crate::conversation_bindings::transitions) fn requested(
    db: &Connection,
    user: &str,
    op: &str,
) -> ApiResult<bool> {
    Ok(db.query_row(
        "SELECT EXISTS(SELECT 1 FROM conversation_transition_voids WHERE owner_user=?1 AND operation_id=?2)",
        params![user, op],
        |r| r.get(0),
    )?)
}

/// The void request and its receipt, for status. Absent until a cancellation of an
/// unknown outcome asked for one, so existing responses do not change.
pub(super) fn status(db: &Connection, user: &str, op: &str) -> ApiResult<Option<Value>> {
    Ok(db
        .query_row(
            "SELECT requested_at,result,answered_at,node_id FROM conversation_transition_voids WHERE owner_user=?1 AND operation_id=?2",
            params![user, op],
            |r| {
                let result: Option<String> = r.get(1)?;
                Ok(json!({"requestedAt":r.get::<_,i64>(0)?,
                    "state":if result.is_some(){"voided"}else{"pending"},
                    "answeredAt":r.get::<_,Option<i64>>(2)?,"nodeId":r.get::<_,String>(3)?}))
            },
        )
        .optional()?)
}

/// Record why an unknown outcome has not been resolved, for clients. A hint only:
/// it never changes the state and never releases anything. Replaced by the next
/// real receipt.
pub(in crate::conversation_bindings::transitions) fn hint(
    app: &AppState,
    identity: &Identity,
    id: &str,
    op: &str,
    reason: &str,
    code: Option<&str>,
) -> ApiResult<()> {
    let db = app.db.lock();
    if state(&db, &identity.user, id, op)? != "outcome_unknown" {
        return Ok(());
    }
    // A plain machine code only: nothing the Node says is passed through as text.
    let code = code.filter(|c| {
        !c.is_empty() && c.len() <= 64 && c.bytes().all(|b| b.is_ascii_lowercase() || b == b'_')
    });
    let safe: &[&str] = if requested(&db, &identity.user, op)? {
        &[]
    } else {
        &["cancel"]
    };
    let progress = json!({"stage":"outcome_unknown","waitReason":reason,"errorCode":code,
        "safeActions":safe,"revocationConfirmed":false,"targetInstalled":false});
    db.execute(
        "INSERT INTO conversation_transition_progress VALUES(?1,?2,?3,?4,?5) ON CONFLICT(owner_user,operation_id) DO UPDATE SET receipt_json=excluded.receipt_json,updated_at=excluded.updated_at",
        params![identity.user, op, id, progress.to_string(), now_ms()],
    )?;
    Ok(())
}

/// What a sweep or a client's read learned about an unknown outcome when no void
/// was requested: only a hint for `receipt_unavailable` and `node_unavailable`.
pub(super) fn note(
    app: &AppState,
    identity: &Identity,
    id: &str,
    op: &str,
    observation: Option<&str>,
) -> ApiResult<()> {
    match observation {
        Some(reason @ ("receipt_unavailable" | "node_unavailable")) => {
            hint(app, identity, id, op, reason, None)
        }
        _ => Ok(()),
    }
}

async fn support(
    app: &AppState,
    identity: &Identity,
    node: &str,
    connection: crate::nodes::NodeConnection,
) -> Support {
    let response = app
        .nodes
        .request_on(
            node,
            connection,
            NodeHttpRequest {
                method: HttpMethod::Get,
                url: "/api/execution-fences/capabilities".into(),
                user: identity.user.clone(),
                payload: None,
                body_base64: None,
                content_type: None,
            },
        )
        .await;
    match response {
        Ok(r) if r.status == 200 => {
            if r.body
                .as_ref()
                .is_some_and(|b| b["transitionVoidVersion"] == 1)
            {
                Support::Yes
            } else {
                Support::No
            }
        }
        // A Node that does not know the capabilities route is older than the void.
        Ok(r) if r.status == 404 || r.status == 405 => Support::No,
        _ => Support::Unknown,
    }
}

/// Commit the cancellation intent and the "void requested" marker together, once.
/// False when the outcome is no longer unknown (a fence was adopted meanwhile).
fn request(
    app: &AppState,
    identity: &Identity,
    id: &str,
    op: &str,
    f: &Frozen,
    client: &str,
) -> ApiResult<bool> {
    atomic(&app.db.lock(), |tx| {
        access(app, tx, identity, id)?;
        if state(tx, &identity.user, id, op)? != "outcome_unknown" {
            return Ok(false);
        }
        let stamp = now_ms();
        tx.execute(
            "INSERT OR IGNORE INTO conversation_transition_cancellations VALUES(?1,?2,?3,?4,?5)",
            params![identity.user, op, id, client, stamp],
        )?;
        tx.execute(
            "INSERT INTO conversation_transition_voids(owner_user,operation_id,session_id,node_id,plan_hash,requested_at) VALUES(?1,?2,?3,?4,?5,?6) ON CONFLICT(owner_user,operation_id) DO NOTHING",
            params![identity.user, op, id, f.node, f.plan_hash, stamp],
        )?;
        Ok(true)
    })
}

/// The Node answered `voided`: record its receipt and release in one transaction.
/// The database refuses the release without that receipt.
fn voided(
    app: &AppState,
    identity: &Identity,
    id: &str,
    op: &str,
    answer: &Value,
) -> ApiResult<()> {
    let changed = atomic(&app.db.lock(), |tx| {
        access(app, tx, identity, id)?;
        let stamp = now_ms();
        let recorded = tx.execute(
            "UPDATE conversation_transition_voids SET result='voided',answer_json=?3,answered_at=?4 WHERE owner_user=?1 AND operation_id=?2 AND result IS NULL",
            params![identity.user, op, answer.to_string(), stamp],
        )?;
        if recorded == 0 {
            // Another device's cancel got the same answer first.
            return Ok(false);
        }
        let released = tx.execute(
            "UPDATE conversation_transition_acceptances SET state='released' WHERE owner_user=?1 AND session_id=?2 AND operation_id=?3 AND state='outcome_unknown'",
            params![identity.user, id, op],
        )?;
        if released != 1 {
            return Err(ApiError::internal());
        }
        // Only a hint can be stored for an unknown outcome; it no longer applies.
        tx.execute(
            "DELETE FROM conversation_transition_progress WHERE owner_user=?1 AND operation_id=?2",
            params![identity.user, op],
        )?;
        Ok(true)
    })?;
    if changed {
        app.sessions_changed(Some(&identity.user));
    }
    Ok(())
}

/// Take one step towards an answer for a requested void: read the Node's receipt,
/// and when it holds none ask it to void. Safe to repeat from any number of
/// devices, sweeps and restarts. Returns why it is still waiting, if it is.
pub(super) async fn resolve(
    app: &AppState,
    identity: &Identity,
    id: &str,
    op: &str,
) -> ApiResult<Option<String>> {
    let (f, s) = current(app, identity, id, op)?;
    if s != "outcome_unknown" {
        return Ok(None);
    }
    // The receipt first. A fence that exists is adopted, and the void is moot.
    let observation = reconcile(app, identity, id, op)
        .await?
        .and_then(|v| v["reconciliationState"].as_str().map(str::to_owned));
    if state(&app.db.lock(), &identity.user, id, op)? != "outcome_unknown" {
        return Ok(None);
    }
    if observation.as_deref() != Some("receipt_unavailable") {
        // Offline, replaced connection, or an unreadable answer: nothing is proven.
        let reason = observation.unwrap_or_else(|| "node_unavailable".into());
        hint(app, identity, id, op, &reason, None)?;
        return Ok(Some(reason));
    }
    let Ok(connection) = app.nodes.connection(&f.node) else {
        hint(app, identity, id, op, "node_unavailable", None)?;
        return Ok(Some("node_unavailable".into()));
    };
    match support(app, identity, &f.node, connection).await {
        Support::Yes => {}
        Support::No => {
            hint(app, identity, id, op, "node_upgrade_required", None)?;
            return Ok(Some("node_upgrade_required".into()));
        }
        Support::Unknown => {
            hint(app, identity, id, op, "node_unavailable", None)?;
            return Ok(Some("node_unavailable".into()));
        }
    }
    app.db.lock().execute(
        "UPDATE conversation_transition_voids SET last_attempt_at=?3 WHERE owner_user=?1 AND operation_id=?2 AND result IS NULL",
        params![identity.user, op, now_ms()],
    )?;
    let response = app
        .nodes
        .request_on(
            &f.node,
            connection,
            NodeHttpRequest {
                method: HttpMethod::Post,
                url: format!(
                    "/api/sessions/{}/execution-fences/{}/void",
                    crate::routes::urlencoding_component(&f.remote),
                    crate::routes::urlencoding_component(op)
                ),
                user: identity.user.clone(),
                payload: Some(json!({"planHash":f.plan_hash})),
                body_base64: None,
                content_type: None,
            },
        )
        .await;
    {
        let db = app.db.lock();
        access(app, &db, identity, id)?;
        same_source(&db, identity, id, &f)?;
    }
    if app.nodes.require_connection(&f.node, connection).is_err() {
        // Resent by the next sweep: the void is idempotent on the Node.
        return Ok(Some("connection_changed".into()));
    }
    let response = match response {
        Ok(r) => r,
        Err(_) => {
            // The reply may be lost after the Node decided: ask again, same answer.
            hint(app, identity, id, op, "node_unavailable", None)?;
            return Ok(Some("node_unavailable".into()));
        }
    };
    let body = response.body.clone().unwrap_or(Value::Null);
    let answer = &body["void"];
    if response.status != 200
        || answer["operationId"] != op
        || answer["sessionId"] != f.remote.as_str()
    {
        let code = body["error"]["code"].as_str();
        hint(app, identity, id, op, "node_refused", code)?;
        return Ok(Some("node_refused".into()));
    }
    match answer["result"].as_str() {
        Some("voided") => {
            voided(app, identity, id, op, answer)?;
            Ok(None)
        }
        // The Node holds the fence: adopt it (its intent must match) and let the
        // existing cancel path continue. Nothing was voided.
        Some("fence") => {
            observe_reply(app, identity, id, op, &f, &body, connection)?;
            Ok(None)
        }
        _ => {
            hint(app, identity, id, op, "node_refused", None)?;
            Ok(Some("node_refused".into()))
        }
    }
}

/// What a cancel of an unknown outcome decided.
pub(super) enum Outcome {
    /// The cancel is complete for now: released, or waiting for the Node.
    Done(Value),
    /// A Node fence exists: continue with the ordinary cancel path.
    Continue,
}

/// A user's cancel while the outcome is unknown.
pub(super) async fn cancel(
    app: &AppState,
    identity: &Identity,
    id: &str,
    op: &str,
    lease: &(String, i64),
) -> ApiResult<Outcome> {
    let (f, s) = current(app, identity, id, op)?;
    if s != "outcome_unknown" {
        return Ok(Outcome::Continue);
    }
    if !requested(&app.db.lock(), &identity.user, op)? {
        let support = match app.nodes.connection(&f.node) {
            Ok(connection) => support(app, identity, &f.node, connection).await,
            Err(_) => Support::Unknown,
        };
        if support == Support::No {
            // Never assume a void succeeded on a Node that cannot perform one. Its
            // fence may exist, though, and that cancels the ordinary way.
            reconcile(app, identity, id, op).await?;
            if current(app, identity, id, op)?.1 == "node_fenced" {
                return Ok(Outcome::Continue);
            }
            return Err(unsupported());
        }
        // Offline or answering: the intent and the marker are committed first, so
        // a crash from here on resumes with the same void and no create request.
        if !request(app, identity, id, op, &f, &lease.0)? {
            return Ok(Outcome::Continue);
        }
    }
    let waiting = resolve(app, identity, id, op).await?;
    match current(app, identity, id, op)?.1.as_str() {
        "outcome_unknown" => {
            let mut result = describe(app, identity, id, op)?;
            result["reconciliationState"] =
                json!(waiting.unwrap_or_else(|| "node_unavailable".into()));
            Ok(Outcome::Done(result))
        }
        "released" => describe(app, identity, id, op).map(Outcome::Done),
        _ => Ok(Outcome::Continue),
    }
}

#[cfg(test)]
mod tests;
