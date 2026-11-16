//! Server-side reconciliation of a first-message dispatch whose outcome is
//! unknown, with no client involved. The Node is asked for its receipt first.
//! One "no record" answer is not proof (a delayed frame may still arrive), so a
//! Node that holds nothing is asked to void the command id: it either returns
//! the admission it already has, or refuses that id for good. The request to void
//! is committed before it is sent, and the id is never dispatched again.
use super::*;
use futures_util::{StreamExt, stream};
use std::{sync::Arc, time::Duration};

/// Shown in `deliveryError` and as `messageAdmission.recovery`.
pub(super) const UNSUPPORTED: &str = "recovery_unsupported";
const SWEEP_LIMIT: i64 = 32;

/// How a first-message attempt's void stands, for clients.
pub(super) fn state(db: &Connection, owner: &str, op: &str, record: &Record) -> Option<String> {
    let voided: Option<Option<String>> = db.query_row("SELECT result FROM conversation_submission_voids WHERE owner_user=?1 AND operation_id=?2 AND command_id=?3",params![owner,op,record.command],|r|r.get(0)).optional().ok()?;
    match voided {
        Some(Some(result)) if result == "voided" => Some("voided".into()),
        Some(None) if record.admitted.is_none() => Some("voiding".into()),
        _ if record.error.as_deref() == Some(UNSUPPORTED) && record.admitted.is_none() => {
            Some(UNSUPPORTED.into())
        }
        _ => None,
    }
}

/// The Node answered that this attempt was never admitted and never will be.
pub(super) fn answered_void(
    db: &Connection,
    owner: &str,
    op: &str,
    command: &str,
) -> ApiResult<bool> {
    Ok(db.query_row("SELECT EXISTS(SELECT 1 FROM conversation_submission_voids WHERE owner_user=?1 AND operation_id=?2 AND command_id=?3 AND result='voided')",params![owner,op,command],|r|r.get(0))?)
}

/// An unadmitted first-message attempt whose outcome is unknown, outside Stop.
fn candidate(db: &Connection, owner: &str, op: &str) -> ApiResult<Option<Record>> {
    let Some(record) = read(db, owner, op)? else {
        return Ok(None);
    };
    if lookup(db, owner, op)?.state == Phase::Cancelled
        || record.hash.is_none()
        || record.admitted.is_some()
        || record.stop
        || record.confirmed
        || record.outcome == "not_admitted"
        || pre_stop::pending(db, owner, op)?
    {
        return Ok(None);
    }
    let unknown = match record.state.as_str() {
        "outcome_unknown" => true,
        "dispatched" => db.get_command(&record.command)?.status == "outcome_unknown",
        _ => false,
    };
    Ok(unknown.then_some(record))
}

/// Whether the Node's receipt shows it holds no record of the attempt.
pub(super) fn holds_nothing(receipt: &ApiResult<pirc_protocol::NodeHttpResponse>) -> bool {
    receipt.as_ref().is_ok_and(|r| {
        r.status < 400
            && r.body
                .as_ref()
                .and_then(|b| b.get("admission"))
                .is_some_and(|a| {
                    a["command"].is_null()
                        && a["state"] == "not_submitted"
                        && a["stopRequested"] == false
                        && a["stopConfirmed"] == false
                })
    })
}

/// Commit the request to void, once. It is idempotent: the same row serves
/// every later send.
fn request(app: &AppState, identity: &Identity, op: &str, record: &Record) -> ApiResult<bool> {
    let hash = record.hash.clone().ok_or_else(ApiError::internal)?;
    let db = app.db.lock();
    crate::db::atomic(&db, |tx| {
        if candidate(tx, &identity.user, op)?.is_none_or(|c| c.command != record.command) {
            return Ok(false);
        }
        tx.execute("INSERT INTO conversation_submission_voids(owner_user,operation_id,command_id,input_hash,requested_at) VALUES(?1,?2,?3,?4,?5) ON CONFLICT(owner_user,operation_id,command_id) DO NOTHING",params![identity.user,op,record.command,hash,now_ms()])?;
        Ok(true)
    })
}

fn unsupported(app: &AppState, identity: &Identity, op: &str, record: &Record) -> ApiResult<()> {
    app.db.lock().execute("UPDATE conversation_submission_dispatches SET last_error_code=?4,updated_at=?5 WHERE owner_user=?1 AND operation_id=?2 AND command_id=?3 AND admitted_at IS NULL AND outcome='outcome_unknown'",params![identity.user,op,record.command,UNSUPPORTED,now_ms()])?;
    Ok(())
}

/// The Node confirmed the void: the attempt is a known non-admission, so the
/// existing explicit retry (a new attempt, `previousCommandId` = this one) applies.
fn voided(app: &AppState, identity: &Identity, op: &str, command: &str) -> ApiResult<()> {
    let db = app.db.lock();
    crate::db::atomic(&db, |tx| {
        let Some(record) = read(tx, &identity.user, op)? else {
            return Ok(());
        };
        let still_open = record.command == command
            && record.admitted.is_none()
            && !record.stop
            && !record.confirmed
            && matches!(record.state.as_str(), "dispatched" | "outcome_unknown");
        if !still_open {
            return Ok(());
        }
        let stamp = now_ms();
        tx.execute("UPDATE conversation_submission_voids SET result='voided',answered_at=?4 WHERE owner_user=?1 AND operation_id=?2 AND command_id=?3 AND result IS NULL",params![identity.user,op,command,stamp])?;
        tx.update_command(
            command,
            "rejected",
            None,
            Some("The Node refused this attempt for good; it was never admitted"),
        )?;
        tx.execute("UPDATE conversation_submission_dispatches SET state='rejected',outcome='not_admitted',last_error_code=NULL,updated_at=?4 WHERE owner_user=?1 AND operation_id=?2 AND command_id=?3",params![identity.user,op,command,stamp])?;
        Ok(())
    })
}

fn mark(app: &AppState, identity: &Identity, op: &str, command: &str, result: &str) {
    let _ = app.db.lock().execute("UPDATE conversation_submission_voids SET result=?4,answered_at=?5 WHERE owner_user=?1 AND operation_id=?2 AND command_id=?3 AND result IS NULL",params![identity.user,op,command,result,now_ms()]);
}

/// Ask the Node to void the attempt if it still holds nothing for it. Called with
/// a receipt that showed no record, from a client's check or from the sweep.
pub(super) async fn settle(app: &AppState, identity: &Identity, op: &str) -> ApiResult<()> {
    let (record, target) = {
        let db = app.db.lock();
        let Some(record) = candidate(&db, &identity.user, op)? else {
            return Ok(());
        };
        (record, target(&db, &identity.user, op)?)
    };
    let caps = app
        .relay(
            &target.node,
            identity,
            HttpMethod::Get,
            "/api/session-creations/capabilities".into(),
            None,
        )
        .await;
    let can_void = caps.as_ref().is_ok_and(|r| {
        r.status < 400
            && r.body
                .as_ref()
                .is_some_and(|b| b["version"] == 1 && b["canVoidInitialAdmission"] == true)
    });
    if caps.is_err() {
        // Offline or timed out: nothing is known about support, nothing changes.
        return Ok(());
    }
    if !can_void {
        // Never assume a void succeeded on a Node that cannot perform one.
        return unsupported(app, identity, op, &record);
    }
    if !request(app, identity, op, &record)? {
        return Ok(());
    }
    send(app, identity, op, &record.command, &target).await
}

/// Send (or resend) the committed void request and apply the Node's answer.
async fn send(
    app: &AppState,
    identity: &Identity,
    op: &str,
    command: &str,
    target: &acceptance::Target,
) -> ApiResult<()> {
    let input_hash: String = app.db.lock().query_row("SELECT input_hash FROM conversation_submission_voids WHERE owner_user=?1 AND operation_id=?2 AND command_id=?3",params![identity.user,op,command],|r|r.get(0))?;
    app.db.lock().execute("UPDATE conversation_submission_voids SET last_attempt_at=?4 WHERE owner_user=?1 AND operation_id=?2 AND command_id=?3",params![identity.user,op,command,now_ms()])?;
    let answer = app
        .relay(
            &target.node,
            identity,
            HttpMethod::Post,
            format!("/api/session-creations/{}/admission/void", target.creation),
            Some(json!({"commandId":command,"submissionHash":target.hash,"inputHash":input_hash})),
        )
        .await;
    let Ok(remote) = answer else {
        return Ok(());
    };
    let body = remote.body.unwrap_or(Value::Null);
    let void = &body["void"];
    if remote.status >= 400
        || void["commandId"] != command
        || void["operationId"] != target.creation
    {
        return Ok(());
    }
    match void["result"].as_str() {
        Some("voided") => voided(app, identity, op, command)?,
        // The Node had decided it already: adopt that receipt, nothing is voided.
        Some("admission")
            if apply_for(app, identity, op, Some(command), &body["admission"]).is_ok() =>
        {
            mark(app, identity, op, command, "admission");
        }
        _ => {}
    }
    Ok(())
}

/// Reconcile every unknown first-message attempt. Rotates by the last attempt so
/// a Node that is down cannot starve the others.
pub(super) async fn sweep(app: &AppState) -> ApiResult<()> {
    let jobs: Vec<(String, String)> = {
        let db = app.db.lock();
        db.prepare("SELECT d.owner_user,d.operation_id FROM conversation_submission_dispatches d JOIN conversation_submissions s USING(owner_user,operation_id) WHERE d.input_hash IS NOT NULL AND d.admitted_at IS NULL AND d.stop_requested=0 AND d.stop_confirmed=0 AND s.state!='cancelled' AND (d.state='outcome_unknown' OR (d.state='dispatched' AND EXISTS(SELECT 1 FROM commands c WHERE c.id=d.command_id AND c.status='outcome_unknown'))) ORDER BY COALESCE((SELECT a.attempted_at FROM conversation_submission_reconcile_attempts a WHERE a.owner_user=d.owner_user AND a.operation_id=d.operation_id),0),d.updated_at LIMIT ?1")?
            .query_map([SWEEP_LIMIT], |r| Ok((r.get(0)?, r.get(1)?)))?
            .collect::<Result<_, _>>()?
    };
    for result in stream::iter(jobs.into_iter().map(|(owner, op)| async move {
        let identity = Identity {
            user: owner,
            device_id: None,
            management_authorized: false,
        };
        app.db.lock().execute("INSERT INTO conversation_submission_reconcile_attempts(owner_user,operation_id,attempted_at) VALUES(?1,?2,?3) ON CONFLICT(owner_user,operation_id) DO UPDATE SET attempted_at=excluded.attempted_at",params![identity.user,op,now_ms()])?;
        // The receipt first; `reconcile` asks for the void only when the Node
        // holds nothing, and a request committed before a crash is sent again.
        reconcile(app, &identity, &op).await.map(|_| ())
    }))
    .buffer_unordered(4)
    .collect::<Vec<_>>()
    .await
    {
        result?;
    }
    Ok(())
}

/// Every 5 s, and whenever a Node reconnects, reconcile unknown first messages
/// even with no client connected.
pub(in crate::conversation_submissions) fn start(app: &AppState) {
    let weak = Arc::downgrade(app);
    let wake = Arc::new(tokio::sync::Notify::new());
    let notify = Arc::downgrade(&wake);
    let subscription = app.events.subscribe_all(Arc::new(move |event| {
        if event.kind == "node_reconnected"
            && let Some(wake) = notify.upgrade()
        {
            wake.notify_one();
        }
    }));
    tokio::spawn(async move {
        let _subscription = subscription;
        let mut interval = tokio::time::interval(Duration::from_secs(5));
        loop {
            tokio::select! {
                _ = interval.tick() => {}
                _ = wake.notified() => {
                    // A late frame from the old connection may still be arriving;
                    // the void is safe either way, but let the reconnect settle.
                    tokio::time::sleep(Duration::from_millis(150)).await;
                }
            }
            let Some(app) = weak.upgrade() else {
                return;
            };
            if sweep(&app).await.is_err() {
                crate::log::warn("First-message reconciliation will retry");
            }
        }
    });
}

#[cfg(test)]
mod tests;
