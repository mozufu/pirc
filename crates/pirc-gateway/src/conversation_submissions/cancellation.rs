//! Retriable cleanup by immutable creation identity, even without its session ID.
use super::*;
use futures_util::{StreamExt, stream};
use pirc_protocol::HttpMethod;
use std::{sync::Arc, time::Duration};

#[derive(Clone)]
struct Job {
    owner: String,
    op: String,
    session: String,
    node: String,
    creation: String,
    workspace: String,
    hash: String,
    expected: Option<String>,
}
const COLUMNS: &str = "owner_user,operation_id,session_id,node_id,node_operation_id,local_workspace_id,submission_hash,expected_node_session_id";
fn job(r: &rusqlite::Row<'_>) -> rusqlite::Result<Job> {
    Ok(Job {
        owner: r.get(0)?,
        op: r.get(1)?,
        session: r.get(2)?,
        node: r.get(3)?,
        creation: r.get(4)?,
        workspace: r.get(5)?,
        hash: r.get(6)?,
        expected: r.get(7)?,
    })
}
fn read(db: &Connection, owner: &str, op: &str) -> ApiResult<Option<Job>> {
    Ok(db.query_row(&format!("SELECT {COLUMNS} FROM conversation_submission_remote_cleanup WHERE owner_user=?1 AND operation_id=?2"),params![owner,op],job).optional()?)
}
pub(super) fn decorate(
    db: &Connection,
    owner: &str,
    op: &str,
    row: &mut Preparation,
) -> ApiResult<()> {
    if let Some(error)=db.query_row("SELECT last_error_code FROM conversation_submission_remote_cleanup WHERE owner_user=?1 AND operation_id=?2",params![owner,op],|r|r.get::<_,Option<String>>(0)).optional()? {
        row.cleanup_pending=true;row.cleanup_error=error;
    }
    Ok(())
}
fn queued(db: &Connection, owner: &str, session: &str) -> ApiResult<bool> {
    Ok(db.query_row("SELECT EXISTS(SELECT 1 FROM conversation_submissions s JOIN conversation_submission_acceptances a USING(owner_user,operation_id) WHERE s.owner_user=?1 AND s.session_id=?2)",params![owner,session],|r|r.get(0))?)
}
fn complete(app: &AppState, j: &Job, proof: &Value) -> ApiResult<()> {
    if proof["operationId"] != j.creation
        || proof["workspaceId"] != j.workspace
        || proof["submissionHash"] != j.hash
        || proof["complete"] != true
        || j.expected
            .as_ref()
            .is_some_and(|id| proof["sessionId"] != *id)
        || !proof
            .get("sessionId")
            .is_some_and(|id| id.is_null() || id.as_str().is_some_and(valid_id))
    {
        return Err(ApiError::new(
            502,
            "invalid_cancellation_receipt",
            "Node did not confirm the original creation cancellation",
        ));
    }
    let epoch = {
        let db = app.db.lock();
        crate::db::atomic(&db, |tx| {
            if read(tx, &j.owner, &j.op)?.is_none() {
                return Ok(None);
            }
            let row = lookup(tx, &j.owner, &j.op)?;
            if row.state != Phase::Cancelled {
                return Err(ApiError::internal());
            }
            let epoch = match tx.get_session(&j.session) {
                Ok(session) => {
                    if session.owner_user.as_deref() != Some(j.owner.as_str()) {
                        return Err(ApiError::not_found("Conversation not found"));
                    }
                    tx.begin_session_deletion(&j.session, &j.owner)?;
                    Some(session.runner_epoch)
                }
                Err(e) if e.status == 404 => None,
                Err(e) => return Err(e),
            };
            app.forget_session_memory(tx, &j.owner, &j.session)?;
            if tx.session_deletion(&j.session)?.is_some() {
                tx.finish_session_deletion(&j.session)?;
            }
            tx.execute("DELETE FROM conversation_submission_remote_cleanup WHERE owner_user=?1 AND operation_id=?2",params![j.owner,j.op])?;
            Ok(epoch)
        })?
    };
    if let Some(epoch) = epoch {
        app.events.publish(
            &j.session,
            epoch,
            "session_deleted",
            json!({"sessionId":j.session}),
        );
        app.events.forget(&j.session);
    }
    app.memory_changed(&j.owner);
    app.sessions_changed(Some(&j.owner));
    app.schedules_changed(&j.owner);
    Ok(())
}
async fn attempt(app: &AppState, j: Job) -> ApiResult<()> {
    {
        let db = app.db.lock();
        if db.execute("UPDATE conversation_submission_remote_cleanup SET last_attempt_at=?3 WHERE owner_user=?1 AND operation_id=?2",params![j.owner,j.op,now_ms()])?==0 {return Ok(());}
    }
    // The durable deletion, authorized by its owner, outlives the initiating
    // device/browser token. This identity grants only that already-queued cleanup.
    let identity = Identity {
        user: j.owner.clone(),
        device_id: None,
        management_authorized: false,
    };
    let result = async {
        let response = app
            .relay(
                &j.node,
                &identity,
                HttpMethod::Post,
                format!("/api/session-creations/{}/cancel", j.creation),
                Some(json!({"workspaceId":j.workspace,"submissionHash":j.hash})),
            )
            .await?;
        if response.status >= 400 {
            return Err(ApiError::new(
                503,
                "node_cleanup_unavailable",
                "Node has not confirmed cancellation",
            ));
        }
        let proof = response
            .body
            .as_ref()
            .and_then(|b| b.get("cancellation"))
            .ok_or_else(ApiError::internal)?;
        if proof["complete"] != true {
            return Err(ApiError::new(
                409,
                "node_cleanup_pending",
                "Node storage or checkpoint cleanup is still pending",
            ));
        }
        complete(app, &j, proof)
    }
    .await;
    if let Err(error) = result {
        app.db.lock().execute("UPDATE conversation_submission_remote_cleanup SET last_error_code=?3 WHERE owner_user=?1 AND operation_id=?2",params![j.owner,j.op,error.code])?;
    }
    Ok(())
}
/// Accepted-first-send sessions have a durable operation identity. Legacy
/// deletion retains its existing route/permissions and remote-ID requirements.
pub(crate) async fn try_delete(
    app: &AppState,
    identity: &Identity,
    session: &str,
) -> ApiResult<Option<axum::response::Response>> {
    let op = {
        let db = app.db.lock();
        if !queued(&db, &identity.user, session)? {
            return Ok(None);
        }
        let op:String=db.query_row("SELECT operation_id FROM conversation_submissions WHERE owner_user=?1 AND session_id=?2",params![identity.user,session],|r|r.get(0))?;
        let deletion = db.session_deletion(session)?;
        if let Some(deletion) = &deletion {
            if deletion.owner_user != identity.user {
                return Err(ApiError::not_found("Conversation not found"));
            }
            if deletion.status == crate::db::DeletionStatus::Deleted
                && read(&db, &identity.user, &op)?.is_none()
            {
                return Ok(Some(crate::http::no_content()));
            }
        }
        if deletion.is_none() && lookup(&db, &identity.user, &op)?.state != Phase::Cancelled {
            let row = db.claim_session(session, &identity.user, true)?;
            if !app
                .require_mode(&db.get_workspace(&row.workspace_id)?)?
                .delete_sessions
            {
                return Err(ApiError::new(
                    400,
                    "invalid_input",
                    "Conversations in this workspace cannot be deleted",
                ));
            }
            // The trigger scrubs the payload and queues remote cleanup in this
            // same commit, before a request is sent or a connection is required.
            crate::db::atomic(&db, |tx| tx.begin_session_deletion(session, &identity.user))?;
        }
        op
    };
    app.sessions_changed(Some(&identity.user));
    let pending = read(&app.db.lock(), &identity.user, &op)?;
    if let Some(j) = pending {
        attempt(app, j).await?;
    }
    if read(&app.db.lock(), &identity.user, &op)?.is_none() {
        return Ok(Some(crate::http::no_content()));
    }
    Ok(Some(crate::error::json_response(
        202,
        &json!({"deletion":{"sessionId":session,"state":"deleting","cleanupPending":true}}),
    )))
}
async fn sweep(app: &AppState) -> ApiResult<()> {
    let jobs = {
        let db = app.db.lock();
        db.prepare(&format!("SELECT {COLUMNS} FROM conversation_submission_remote_cleanup ORDER BY last_attempt_at,created_at LIMIT 32"))?.query_map([],job)?.collect::<Result<Vec<_>,_>>()?
    };
    let results = stream::iter(jobs.into_iter().map(|j| attempt(app, j)))
        .buffer_unordered(4)
        .collect::<Vec<_>>()
        .await;
    for result in results {
        result?;
    }
    Ok(())
}
pub(crate) fn start_cleanup(app: &AppState) {
    let weak = Arc::downgrade(app);
    tokio::spawn(async move {
        loop {
            let Some(app) = weak.upgrade() else {
                return;
            };
            if sweep(&app).await.is_err() {
                crate::log::warn("Creation cancellation cleanup remains pending; it will retry");
            }
            drop(app);
            tokio::time::sleep(Duration::from_secs(5)).await;
        }
    });
}
#[cfg(test)]
mod tests;
