//! Explicit end of a transition fence: acknowledge an unproven revocation,
//! install the reviewed target, or release back to the original binding. Each
//! is bound to the retained fence and current control, and idempotent per
//! operation. None closes, settles or rewrites resource evidence.
use super::*;
use crate::runner::Runner;
use serde_json::{Map, Value};

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Outcome {
    pub generation: i64,
    pub from_workspace_id: String,
    pub to_workspace_id: String,
    /// `confirmed`, or `unproven` with a retained acknowledgement.
    pub revocation: String,
    /// `pending`, `sending`, `delivered` or `uncertain`.
    pub environment_event: String,
    /// C3: the binding was recorded; not proof that execution works.
    pub binding_committed: bool,
    /// The target was re-observed against its frozen review at installation.
    pub policy_validated: bool,
    /// `not_started`, `ready`, `failed` or `unknown` for the first runner
    /// in the installed generation. A failure never reverts the binding.
    pub runtime_ready: &'static str,
}
pub(super) fn outcome(
    db: &Connection,
    owner: &str,
    op: &str,
    state: &str,
) -> ApiResult<Option<Outcome>> {
    if state != "installed" {
        return Ok(None);
    }
    Ok(db.query_row(
        "SELECT g.generation,e.from_workspace_id,e.to_workspace_id,e.revocation,e.state,g.start_epoch,s.runner_epoch,s.runner_state,(SELECT max(generation) FROM session_binding_generations WHERE session_id=e.session_id) FROM environment_events e JOIN session_binding_generations g ON g.session_id=e.session_id AND g.operation_id=e.operation_id JOIN sessions s ON s.id=e.session_id WHERE e.owner_user=?1 AND e.operation_id=?2",
        params![owner, op],
        |r| {
            let generation: i64 = r.get(0)?;
            let (start, epoch, runner, latest): (i64, i64, String, i64) =
                (r.get(5)?, r.get(6)?, r.get(7)?, r.get(8)?);
            let runtime_ready = if latest != generation {
                "unknown"
            } else if epoch <= start {
                "not_started"
            } else {
                match runner.as_str() {
                    "failed" => "failed",
                    "starting" => "unknown",
                    _ => "ready",
                }
            };
            Ok(Outcome {
                generation,
                from_workspace_id: r.get(1)?,
                to_workspace_id: r.get(2)?,
                revocation: r.get(3)?,
                environment_event: r.get(4)?,
                binding_committed: true,
                policy_validated: true,
                runtime_ready,
            })
        },
    ).optional()?)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Acknowledge {
    plan_hash: String,
    digest: String,
    /// C2: the reviewed snapshot; the acknowledgement covers all of its items.
    #[serde(default)]
    evaluation_id: Option<String>,
    client_id: String,
    generation: i64,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Install {
    plan_hash: String,
    target_workspace_id: String,
    /// The current controller, or else the operation authority (C1).
    #[serde(default)]
    client_id: Option<String>,
    #[serde(default)]
    generation: Option<i64>,
    #[serde(default)]
    operation_authority: Option<authority::Presented>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Release {
    plan_hash: String,
    client_id: String,
    generation: i64,
}

fn refused(code: &'static str, message: &str) -> ApiError {
    ApiError::new(409, code, message)
}
/// The owner's retained fence for this plan, under current control.
fn fence(
    db: &Connection,
    owner: &str,
    session: &str,
    op: &str,
    plan: &str,
    lease: Option<(&str, i64)>,
) -> ApiResult<Receipt> {
    db.claim_session(session, owner, false)?;
    let saved = receipt(db, owner, session, op)?
        .ok_or_else(|| ApiError::not_found("Transition not found"))?;
    if saved.intent.plan_hash != plan {
        return Err(ApiError::conflict(
            "This request targets a different transition plan",
        ));
    }
    if saved.state == "deleted" {
        return Err(refused(
            "transition_deleted",
            "The conversation was deleted",
        ));
    }
    // Without a lease the caller must verify operation authority instead.
    if let Some(lease) = lease {
        db.validate_lease(session, lease.0, lease.1)?;
    }
    Ok(saved)
}
fn reply(node: &Node, session: &str, owner: &str, op: &str) -> ApiResult<Response> {
    let saved = receipt(&node.db.lock(), owner, session, op)?.ok_or_else(ApiError::internal)?;
    let saved = network_observation(node, session, saved);
    Ok(Response::json(json!({"transition":saved})))
}
fn acknowledged(db: &Connection, owner: &str, op: &str, digest: &str) -> ApiResult<bool> {
    Ok(db.query_row(
        "SELECT EXISTS(SELECT 1 FROM transition_acknowledgements WHERE owner_user=?1 AND operation_id=?2 AND digest=?3)",
        params![owner, op, digest],
        |r| r.get(0),
    )?)
}

/// Record the user's acknowledgement of exactly the current unproven items.
pub async fn acknowledge(node: Node, request: Request) -> ApiResult<Response> {
    let body: Acknowledge = request.parse_body()?;
    let session = request.param("id").unwrap_or_default();
    let op = request.param("operation").unwrap_or_default();
    {
        let db = node.db.lock();
        let saved = fence(
            &db,
            &request.user,
            session,
            op,
            &body.plan_hash,
            Some((&body.client_id, body.generation)),
        )?;
        if acknowledged(&db, &request.user, op, &body.digest)? {
            drop(db);
            return reply(&node, session, &request.user, op);
        }
        if saved.state != "supervisor_drained" {
            return Err(refused(
                "transition_not_drained",
                "Only a drained transition can be acknowledged",
            ));
        }
        let evaluation = revocation::evaluate(&node, &db, session, &saved.state)?;
        if evaluation.status != "unproven" {
            return Err(ApiError::new(
                409,
                "transition_not_unproven",
                "Only unproven revocation evidence can be acknowledged",
            )
            .with_details(json!({"status":evaluation.status,"digest":evaluation.digest})));
        }
        if evaluation.digest != body.digest
            || body
                .evaluation_id
                .as_ref()
                .is_some_and(|id| *id != revocation::evaluation_id(&evaluation.digest))
        {
            return Err(ApiError::new(
                409,
                "revocation_digest_changed",
                "The unproven items changed; review them again",
            )
            .with_details(json!({"digest":evaluation.digest})));
        }
        db.execute(
            "INSERT INTO transition_acknowledgements VALUES(?1,?2,?3,?4,?5,?6,?7)",
            params![
                request.user,
                op,
                body.digest,
                serde_json::to_string(&evaluation).map_err(|_| ApiError::internal())?,
                body.client_id,
                body.generation,
                now_ms()
            ],
        )?;
    }
    reply(&node, session, &request.user, op)
}

/// Install the reviewed target, once, after a drain whose revocation is
/// confirmed or acknowledged. Admission reopens under the new binding only.
pub async fn install(node: Node, request: Request) -> ApiResult<Response> {
    let body: Install = request.parse_body()?;
    let session = request.param("id").unwrap_or_default();
    let op = request.param("operation").unwrap_or_default();
    let installed = {
        let db = node.db.lock();
        let lease = match (&body.client_id, body.generation, &body.operation_authority) {
            (Some(client), Some(generation), None) => Some((client.as_str(), generation)),
            (None, None, Some(_)) => None,
            _ => return Err(ApiError::invalid_input()),
        };
        let saved = fence(&db, &request.user, session, op, &body.plan_hash, lease)?;
        if let Some(presented) = &body.operation_authority {
            authority::verify(&db, &request.user, op, presented)?;
        }
        let target = saved
            .intent
            .preflight
            .as_ref()
            .map(|proof| proof.target_workspace_id.clone());
        if target.as_deref() != Some(body.target_workspace_id.as_str()) {
            return Err(refused(
                "transition_target_mismatch",
                "The installation target differs from the reviewed transition",
            ));
        }
        match saved.state.as_str() {
            "installed" => false,
            "released" => {
                return Err(refused(
                    "transition_released",
                    "The transition was cancelled and returned to its original binding",
                ));
            }
            "supervisor_drained" => {
                let cancelled: bool = db.query_row(
                    "SELECT cancel_requested_at IS NOT NULL FROM execution_fences WHERE owner_user=?1 AND operation_id=?2",
                    params![request.user, op],
                    |r| r.get(0),
                )?;
                if cancelled {
                    return Err(refused(
                        "transition_cancel_requested",
                        "Cancellation was requested; this transition cannot install",
                    ));
                }
                let reviewed: Option<String> = db.query_row(
                    "SELECT target_json FROM execution_fence_targets WHERE owner_user=?1 AND operation_id=?2",
                    params![request.user, op],
                    |r| r.get(0),
                ).optional()?;
                let reviewed: Value = reviewed
                    .and_then(|text| serde_json::from_str(&text).ok())
                    .ok_or_else(|| {
                        refused(
                            "transition_target_unreviewed",
                            "This transition has no frozen target review; start a new transition",
                        )
                    })?;
                let evaluation = revocation::evaluate(&node, &db, session, &saved.state)?;
                let revocation = match evaluation.status {
                    "confirmed" => "confirmed",
                    "unproven" if acknowledged(&db, &request.user, op, &evaluation.digest)? => {
                        "unproven"
                    }
                    _ => {
                        return Err(ApiError::new(
                            409,
                            "revocation_unconfirmed",
                            "Revocation is not confirmed or acknowledged for the current evidence",
                        )
                        .with_details(
                            json!({"status":evaluation.status,"digest":evaluation.digest}),
                        ));
                    }
                };
                let current = preflight::current_target(
                    &node,
                    &db,
                    &request.user,
                    session,
                    &saved.intent,
                    &body.target_workspace_id,
                )?;
                if current != reviewed {
                    return Err(refused(
                        "stale_transition_target",
                        "The reviewed target changed; cancel and review a new transition",
                    ));
                }
                atomic(&db, |tx| {
                    let stamp = now_ms();
                    tx.execute(
                        "UPDATE sessions SET workspace_id=?2,runner_epoch=runner_epoch+1,updated_at=?3 WHERE id=?1",
                        params![session, body.target_workspace_id, stamp],
                    )?;
                    let epoch = tx.get_session(session)?.runner_epoch;
                    tx.execute(
                        "INSERT INTO session_binding_generations SELECT ?1,coalesce(max(generation),0)+1,?2,'complete',?3,?4,?5 FROM session_binding_generations WHERE session_id=?1",
                        params![session, body.target_workspace_id, epoch, stamp, op],
                    )?;
                    tx.execute(
                        "UPDATE execution_fences SET state='installed',error_code=NULL,updated_at=?3 WHERE owner_user=?1 AND operation_id=?2 AND state='supervisor_drained'",
                        params![request.user, op, stamp],
                    )?;
                    tx.execute(
                        "INSERT INTO environment_events VALUES(?1,?2,?3,?4,?5,?6,'pending',?7,?7)",
                        params![
                            request.user,
                            op,
                            session,
                            saved.intent.expected_workspace_id,
                            body.target_workspace_id,
                            revocation,
                            stamp
                        ],
                    )?;
                    Ok(())
                })?;
                true
            }
            _ => {
                return Err(refused(
                    "transition_not_drained",
                    "The source must finish draining before installation",
                ));
            }
        }
    };
    if installed && let Some(scopes) = node.sandbox.network_scopes() {
        scopes.reopen(session);
    }
    reply(&node, session, &request.user, op)
}

/// Release a fence whose cancellation was requested, if C3 allows it now.
/// Returns why it must wait, or None once released. Serialized by the caller's
/// database lock with drain staging and installation.
pub(super) fn try_release(
    node: &Node,
    db: &Connection,
    owner: &str,
    session: &str,
    op: &str,
) -> ApiResult<Option<&'static str>> {
    let saved = receipt(db, owner, session, op)?.ok_or_else(ApiError::internal)?;
    let fresh_epoch = match saved.state.as_str() {
        "released" => return Ok(None),
        // Nothing was stopped: the original runner and epoch stay valid.
        "fenced" => false,
        "stopping" => return Ok(Some("drain_active")),
        "blocked" => return Ok(Some("resources_unresolved")),
        "supervisor_drained" => {
            let evaluation = revocation::evaluate(node, db, session, &saved.state)?;
            if matches!(evaluation.status, "pending" | "blocked") {
                return Ok(Some("resources_unresolved"));
            }
            true
        }
        _ => return Ok(Some("transition_ended")),
    };
    // Never restore access the original binding no longer has.
    let original = &saved.intent.expected_workspace_id;
    if db.get_workspace(original).is_err() || db.workspace_deletion(original)?.is_some() {
        return Ok(Some("original_binding_invalid"));
    }
    atomic(db, |tx| {
        // Stopped work is not restarted; a drained source gets a fresh epoch.
        if fresh_epoch {
            tx.execute(
                "UPDATE sessions SET runner_epoch=runner_epoch+1,updated_at=?2 WHERE id=?1",
                params![session, now_ms()],
            )?;
        }
        tx.execute(
            "UPDATE execution_fences SET state='released',cancel_reason=NULL,updated_at=?3 WHERE owner_user=?1 AND operation_id=?2",
            params![owner, op, now_ms()],
        )?;
        Ok(())
    })?;
    if let Some(scopes) = node.sandbox.network_scopes() {
        scopes.reopen(session);
    }
    Ok(None)
}
/// Explicit cancel (C3): record the request durably, then release only when
/// the source state allows it. Otherwise it stays pending with a reason and
/// installation is refused; the drain completes the release when it settles.
pub async fn release(node: Node, request: Request) -> ApiResult<Response> {
    let body: Release = request.parse_body()?;
    let session = request.param("id").unwrap_or_default();
    let op = request.param("operation").unwrap_or_default();
    {
        let db = node.db.lock();
        let saved = fence(
            &db,
            &request.user,
            session,
            op,
            &body.plan_hash,
            Some((&body.client_id, body.generation)),
        )?;
        match saved.state.as_str() {
            "released" => {}
            "installed" => {
                return Err(refused(
                    "transition_installed",
                    "The target is installed; switching back is a new transition",
                ));
            }
            _ => {
                db.execute("UPDATE execution_fences SET cancel_requested_at=?3 WHERE owner_user=?1 AND operation_id=?2 AND cancel_requested_at IS NULL",params![request.user,op,now_ms()])?;
                let pending = try_release(&node, &db, &request.user, session, op)?;
                if let Some(reason) = pending {
                    db.execute("UPDATE execution_fences SET cancel_reason=?3 WHERE owner_user=?1 AND operation_id=?2",params![request.user,op,reason])?;
                }
            }
        }
    }
    reply(&node, session, &request.user, op)
}

/// Owner, operation and the agent `deliver` command of a claimed notice.
type Notice = (String, String, Map<String, Value>);
/// Claim the oldest pending environment-change notice for delivery, once.
pub(super) fn claim_notice(db: &Connection, session: &str) -> ApiResult<Option<Notice>> {
    let pending: Option<(String, String, String, String, String)> = db.query_row(
        "SELECT owner_user,operation_id,from_workspace_id,to_workspace_id,revocation FROM environment_events WHERE session_id=?1 AND state IN ('pending','uncertain') ORDER BY created_at LIMIT 1",
        [session],
        |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)),
    ).optional()?;
    let Some((owner, op, from, to, revocation)) = pending else {
        return Ok(None);
    };
    let claimed = db.execute(
        "UPDATE environment_events SET state='sending',updated_at=?3 WHERE owner_user=?1 AND operation_id=?2 AND state IN ('pending','uncertain')",
        params![owner, op, now_ms()],
    )?;
    if claimed != 1 {
        return Ok(None);
    }
    let name = |id: &str| {
        db.get_workspace(id)
            .map_or_else(|_| id.to_owned(), |w| w.display_name)
    };
    let content = format!(
        "The conversation environment changed: workspace \"{}\" replaced \"{}\". Earlier context is retained; tools now act only in the new workspace.{}",
        name(&to),
        name(&from),
        if revocation == "confirmed" {
            ""
        } else {
            " Revocation of the previous environment was not fully confirmed."
        }
    );
    let mut message = Map::new();
    message.insert("customType".into(), json!("environment-change"));
    message.insert("content".into(), json!(content));
    message.insert(
        "details".into(),
        {
            // One logical notice per operation (C3); the agent applies it once.
            let target: Option<i64> = db
                .query_row(
                    "SELECT generation FROM session_binding_generations WHERE operation_id=?1",
                    [&op],
                    |r| r.get(0),
                )
                .optional()?;
            json!({"noticeId":op,"operationId":op,"fromWorkspaceId":from,"toWorkspaceId":to,"revocation":revocation,
                "sourceGeneration":target.map(|g| g - 1),"targetGeneration":target})
        },
    );
    let mut deliver = Map::new();
    deliver.insert("type".into(), json!("deliver"));
    deliver.insert("wake".into(), json!(false));
    deliver.insert("message".into(), Value::Object(message));
    Ok(Some((owner, op, deliver)))
}
/// Record the delivery outcome. A failed or unanswered send is `uncertain` and
/// is retransmitted with the same notice ID; the agent applies it only once.
pub(super) fn finish_notice(db: &Connection, owner: &str, op: &str, sent: bool) -> ApiResult<()> {
    db.execute(
        "UPDATE environment_events SET state=?3,updated_at=?4 WHERE owner_user=?1 AND operation_id=?2 AND state='sending'",
        params![owner, op, if sent { "delivered" } else { "uncertain" }, now_ms()],
    )?;
    Ok(())
}
/// Deliver a pending or unconfirmed environment-change notice before the
/// session's next command. It adds context without starting a turn; the same
/// notice is retransmitted until the agent confirms it.
pub(crate) async fn deliver_notice(node: &Node, runner: &Runner, session: &str) -> ApiResult<()> {
    let Some((owner, op, deliver)) = claim_notice(&node.db.lock(), session)? else {
        return Ok(());
    };
    let sent = runner
        .request(deliver)
        .await
        .is_ok_and(|response| response.get("success") == Some(&Value::Bool(true)));
    finish_notice(&node.db.lock(), &owner, &op, sent)?;
    if sent {
        Ok(())
    } else {
        Err(ApiError::runner_unavailable(
            "The agent did not confirm the environment-change notice",
        ))
    }
}

#[cfg(test)]
mod tests;
