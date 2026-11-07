//! A supervisor Stop is an ordinary durable command, not a new task or Agent RPC.
//! Retried POSTs read that command; GET may reconcile only observed drain facts.
use super::*;
use crate::store::{CommandRow, CommandStatus};
use serde_json::Value;

pub(crate) fn check(
    db: &Connection,
    owner: &str,
    session: &str,
    op: &str,
    hash: &str,
) -> ApiResult<Receipt> {
    let current = db.claim_session(session, owner, false)?;
    let saved = receipt(db, owner, session, op)?
        .ok_or_else(|| ApiError::not_found("Transition not found"))?;
    if current.workspace_id != saved.intent.expected_workspace_id {
        return Err(ApiError::new(
            409,
            "source_binding_changed",
            "The stopped transition source has changed",
        ));
    }
    if saved.intent.plan_hash != hash {
        return Err(ApiError::conflict(
            "Stop targets a different transition plan",
        ));
    }
    Ok(saved)
}
fn result(saved: &Receipt) -> Value {
    json!({"success":matches!(saved.state.as_str(),"supervisor_drained"|"deleted"|"installed"),"data":{"transition":{
        "operationId":saved.intent.operation_id,"state":saved.state,
        "errorCode":saved.error_code,"revocationConfirmed":saved.revocation_confirmed,"targetInstalled":saved.target_installed}}})
}
fn observe(db: &Connection, command: &str, saved: &Receipt) -> ApiResult<()> {
    atomic(db, |tx| {
        if tx.get_command(command)?.status == CommandStatus::Accepted {
            return Ok(());
        }
        let complete = matches!(
            saved.state.as_str(),
            "supervisor_drained" | "deleted" | "installed"
        );
        tx.update_command(
            command,
            if complete {
                CommandStatus::Accepted
            } else {
                CommandStatus::OutcomeUnknown
            },
            Some(&result(saved)),
            if complete {
                None
            } else {
                Some("Transition supervisor shutdown is not confirmed")
            },
        )
    })
}
fn unknown(db: &Connection, command: &str) -> ApiResult<()> {
    db.execute("UPDATE commands SET status='outcome_unknown',error_text='Transition supervisor shutdown is not confirmed' WHERE id=?1 AND status IN ('received','dispatched','outcome_unknown')",[command])?;
    Ok(())
}

pub(crate) async fn dispatch(
    node: &Node,
    owner: &str,
    session: &str,
    command: &str,
    op: &str,
    hash: &str,
    lease: (&str, i64),
) -> ApiResult<()> {
    // A task owns completion independently of the HTTP waiter's lifetime.
    let node = node.clone();
    let owner = owner.to_owned();
    let session = session.to_owned();
    let command = command.to_owned();
    let op = op.to_owned();
    let hash = hash.to_owned();
    let client = lease.0.to_owned();
    let generation = lease.1;
    let task = tokio::spawn(async move {
        let admitted = atomic(&node.db.lock(), |tx| {
            check(tx, &owner, &session, &op, &hash)?;
            tx.validate_lease(&session, &client, generation)?;
            tx.update_command(&command, CommandStatus::Dispatched, None, None)
        });
        if let Err(error) = admitted {
            node.db.lock().update_command(
                &command,
                CommandStatus::Rejected,
                None,
                Some("Transition Stop lost authority before dispatch"),
            )?;
            return Err(error);
        }
        match drain(&node, &owner, &session, &op).await {
            Ok(saved) => observe(&node.db.lock(), &command, &saved),
            Err(_) => unknown(&node.db.lock(), &command),
        }
    });
    task.await.map_err(|_| ApiError::internal())?
}
/// No task creation, POST, lease renewal, runner startup or resource mutation.
/// An old pending command can converge from the durable fence after a restart.
pub(crate) fn refresh(db: &Connection, owner: &str, command: CommandRow) -> ApiResult<CommandRow> {
    if command.payload["type"] != "stop_transition"
        || !matches!(
            command.status,
            CommandStatus::Received | CommandStatus::Dispatched | CommandStatus::OutcomeUnknown
        )
    {
        return Ok(command);
    }
    let op = command.payload["operationId"]
        .as_str()
        .ok_or_else(ApiError::internal)?;
    let hash = command.payload["planHash"]
        .as_str()
        .ok_or_else(ApiError::internal)?;
    let saved = check(db, owner, &command.session_id, op, hash)?;
    // Fenced/stopping/blocked is a useful observation, never a completed Stop.
    // Only already-attempted work may learn a terminal result; a received command
    // left before dispatch must not acquire effects or acceptance from a GET.
    if command.status != CommandStatus::Received {
        observe(db, &command.id, &saved)?;
    }
    db.get_command(&command.id)
}

#[cfg(test)]
mod tests {
    use super::*;
    use pirc_protocol::{HttpMethod, NodeHttpRequest};
    async fn fixture() -> (crate::workspace_memory::tests::Fixture, i64) {
        let f = crate::workspace_memory::tests::Fixture::new().await;
        let lease = f
            .node
            .db
            .lock()
            .acquire_lease(&f.current, "phone", false, 60000)
            .unwrap();
        let epoch = f
            .node
            .db
            .lock()
            .get_session(&f.current)
            .unwrap()
            .runner_epoch;
        super::super::accept(
            &f.node.db.lock(),
            "alice",
            &f.current,
            &Intent {
                operation_id: "move".into(),
                plan_hash: "a".repeat(64),
                expected_workspace_id: "repo".into(),
                expected_runner_epoch: epoch,
                preflight: None,
            },
            "phone",
            lease.generation,
        )
        .unwrap();
        (f, lease.generation)
    }
    async fn command(
        f: &crate::workspace_memory::tests::Fixture,
        id: &str,
        hash: &str,
        generation: i64,
    ) -> pirc_protocol::NodeHttpResponse {
        f.node.router.handle(&f.node,NodeHttpRequest{method:HttpMethod::Post,url:format!("/api/sessions/{}/commands",f.current),user:"alice".into(),payload:Some(json!({"commandId":id,"clientId":"phone","generation":generation,"payload":{"type":"stop_transition","operationId":"move","planHash":hash}})),body_base64:None,content_type:None}).await
    }
    #[tokio::test]
    async fn scoped_stop_uses_durable_command_without_starting_runner_or_changing_binding() {
        let (f, generation) = fixture().await;
        let before = f.node.db.lock().get_session(&f.current).unwrap();
        let peer = f
            .node
            .db
            .lock()
            .create_session("repo", "/peer", "alice")
            .unwrap();
        let a = command(&f, "stop-transition", &"a".repeat(64), generation).await;
        assert_eq!(a.status, 202, "{:?}", a.body);
        let body = a.body.unwrap();
        assert_eq!(
            body["command"]["result"]["data"]["transition"]["state"],
            "supervisor_drained"
        );
        assert_eq!(
            body["command"]["result"]["data"]["transition"]["revocationConfirmed"],
            false
        );
        assert!(!body["command"]["result"].to_string().contains("intent"));
        let changes = f.node.db.lock().total_changes();
        let duplicate = command(&f, "stop-transition", &"a".repeat(64), generation).await;
        assert_eq!(duplicate.body.unwrap()["duplicate"], true);
        assert_eq!(f.node.db.lock().total_changes(), changes);
        assert!(f.node.runners.get(&f.current).is_none());
        assert_eq!(
            f.node
                .db
                .lock()
                .get_session(&f.current)
                .unwrap()
                .workspace_id,
            before.workspace_id
        );
        require_open(&f.node.db.lock(), &peer.id).unwrap();
        assert!(require_open(&f.node.db.lock(), &f.current).is_err());
        f.node.close().await;
    }
    #[tokio::test]
    async fn stale_controller_wrong_plan_and_other_owner_cannot_start_shutdown() {
        let (f, generation) = fixture().await;
        assert_eq!(
            command(&f, "wrong", &"b".repeat(64), generation)
                .await
                .status,
            409
        );
        assert!(f.node.db.lock().get_command("wrong").is_err());
        f.node
            .db
            .lock()
            .acquire_lease(&f.current, "web", true, 60000)
            .unwrap();
        assert_eq!(
            command(&f, "stale", &"a".repeat(64), generation)
                .await
                .status,
            409
        );
        assert!(f.node.db.lock().get_command("stale").is_err());
        assert!(
            check(
                &f.node.db.lock(),
                "other",
                &f.current,
                "move",
                &"a".repeat(64)
            )
            .is_err()
        );
        assert_eq!(
            receipt(&f.node.db.lock(), "alice", &f.current, "move")
                .unwrap()
                .unwrap()
                .state,
            "fenced"
        );
        f.node.close().await;
    }
    #[tokio::test]
    async fn unknown_receipt_only_observes_saved_completion_and_never_dispatches() {
        let (f, _generation) = fixture().await;
        let payload =
            json!({"type":"stop_transition","operationId":"move","planHash":"a".repeat(64)});
        {
            let db = f.node.db.lock();
            db.receive_command("lost", &f.current, "hash", &payload)
                .unwrap();
            db.update_command("lost", CommandStatus::OutcomeUnknown, None, None)
                .unwrap();
        }
        let before = f.node.db.lock().get_lease(&f.current).unwrap();
        {
            let db = f.node.db.lock();
            let command = db.get_command("lost").unwrap();
            let observed = refresh(&db, "alice", command).unwrap();
            assert_eq!(observed.status, CommandStatus::OutcomeUnknown);
            assert_eq!(observed.result["data"]["transition"]["state"], "fenced");
            stage(&db, "alice", &f.current, "move", "supervisor_drained", None).unwrap();
        }
        let response = f
            .node
            .router
            .handle(
                &f.node,
                NodeHttpRequest {
                    method: HttpMethod::Get,
                    url: format!("/api/sessions/{}/commands/lost", f.current),
                    user: "alice".into(),
                    payload: None,
                    body_base64: None,
                    content_type: None,
                },
            )
            .await;
        assert_eq!(response.status, 200);
        assert_eq!(response.body.unwrap()["command"]["status"], "accepted");
        assert_eq!(f.node.db.lock().get_lease(&f.current).unwrap(), before);
        assert!(f.node.runners.get(&f.current).is_none());
        f.node.close().await;
    }
}
