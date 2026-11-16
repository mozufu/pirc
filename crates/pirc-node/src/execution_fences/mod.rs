//! Node half of an environment transition: durable admission fencing, tracked
//! supervisor shutdown, revocation evaluation, and explicit installation or
//! release. Drained supervisors alone are NOT evidence that descendants or OS
//! grants are revoked; see `revocation`.
pub(crate) mod authority;
pub(crate) mod install;
mod preflight;
pub(crate) mod revocation;
pub(crate) mod stop_command;
mod void;
pub(crate) use preflight::handle as preflight;
pub use void::void;

use crate::{
    error::{ApiError, ApiResult},
    router::{Request, Response},
    services::Node,
    store::{Store, atomic},
    util::now_ms,
};
use futures_util::{
    FutureExt,
    future::{BoxFuture, Shared},
};
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
};
use std::{panic::AssertUnwindSafe, time::Duration};

type Drain = Shared<BoxFuture<'static, ApiResult<Receipt>>>;
#[derive(Default)]
pub(crate) struct Drains(Mutex<HashMap<(String, String, String), Drain>>);
struct DrainEntry {
    drains: Arc<Drains>,
    key: (String, String, String),
}
impl Drop for DrainEntry {
    fn drop(&mut self) {
        self.drains
            .0
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .remove(&self.key);
    }
}
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Intent {
    pub operation_id: String,
    /// Hash of the Gateway's frozen source/target transition plan. Not a grant.
    pub plan_hash: String,
    pub expected_workspace_id: String,
    pub expected_runner_epoch: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub preflight: Option<ResourceProof>,
}
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ResourceProof {
    pub target_workspace_id: String,
    pub evidence_hash: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Acceptance {
    intent: Intent,
    client_id: String,
    generation: i64,
    /// C1: backend authority to advance this one transition (revision 1).
    #[serde(default)]
    operation_authority: Option<authority::Grant>,
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Receipt {
    pub intent: Intent,
    pub state: String,
    pub error_code: Option<String>,
    pub created_at: i64,
    pub updated_at: i64,
    pub revocation_confirmed: bool,
    pub target_installed: bool,
    pub sandbox_processes: crate::process_journal::Summary,
    pub host_commands: crate::host_commands::Summary,
    pub terminals: crate::terminals::journal::Summary,
    pub browser: crate::browser::journal::Summary,
    pub native_proxy: crate::sandbox::proxy::Summary,
    /// Read-only evaluation of the current binding generation; absent once the
    /// session is deleted. It does not change `revocation_confirmed`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub revocation: Option<revocation::Evaluation>,
    /// Latest operation authority revision (never its token or hash).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub operation_authority: Option<serde_json::Value>,
    /// A durable cancellation request and why it still waits (C3).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cancellation: Option<serde_json::Value>,
    /// The committed installation of this fence, if any.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub installation: Option<install::Outcome>,
}
fn valid_id(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 200
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"_-.:".contains(&b))
}
fn validate(intent: &Intent) -> ApiResult<()> {
    if !valid_id(&intent.operation_id)
        || intent.plan_hash.len() != 64
        || !intent
            .plan_hash
            .bytes()
            .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
        || intent.expected_workspace_id.is_empty()
        || intent.expected_workspace_id.len() > 1024
        || !(0..=9_007_199_254_740_991).contains(&intent.expected_runner_epoch)
    {
        return Err(ApiError::invalid_input());
    }
    Ok(())
}
/// A fence that still blocks admission. Installed and released fences are
/// retained evidence but inactive.
pub(crate) const ACTIVE: &str = "state NOT IN ('deleted','installed','released')";
fn pending() -> ApiError {
    ApiError::new(
        409,
        "environment_transition_pending",
        "The conversation environment is changing; new operations are blocked until reconciliation finishes",
    )
}
/// Read/write entry points must recheck after waits. This is admission fencing,
/// not cancellation of already-admitted effects or kernel access revocation.
pub fn require_open(db: &Connection, session: &str) -> ApiResult<()> {
    let active: bool = db.query_row(
        &format!("SELECT EXISTS(SELECT 1 FROM execution_fences WHERE session_id=? AND {ACTIVE})"),
        [session],
        |r| r.get(0),
    )?;
    if active {
        return Err(pending());
    }
    Ok(())
}
fn receipt(db: &Connection, owner: &str, session: &str, op: &str) -> ApiResult<Option<Receipt>> {
    let row: Option<(String, String, Option<String>, i64, i64)> = db.query_row(
        "SELECT intent_json,state,error_code,created_at,updated_at FROM execution_fences WHERE owner_user=?1 AND session_id=?2 AND operation_id=?3",
        params![owner,session,op],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?)),
    ).optional()?;
    row.map(|(intent, state, error_code, created_at, updated_at)| {
        let installation = install::outcome(db, owner, op, &state)?;
        let cancellation: Option<serde_json::Value> = db.query_row(
            "SELECT cancel_requested_at,cancel_reason FROM execution_fences WHERE owner_user=?1 AND operation_id=?2 AND cancel_requested_at IS NOT NULL",
            params![owner, op],
            |r| Ok(json!({"requestedAt":r.get::<_,i64>(0)?,"pendingReason":r.get::<_,Option<String>>(1)?})),
        ).optional()?;
        let operation_authority: Option<serde_json::Value> = db.query_row(
            "SELECT revision,deadline_at,revoked_at IS NOT NULL FROM operation_authorities WHERE owner_user=?1 AND operation_id=?2 ORDER BY revision DESC LIMIT 1",
            params![owner, op],
            |r| Ok(json!({"revision":r.get::<_,i64>(0)?,"deadlineAt":r.get::<_,i64>(1)?,"revoked":r.get::<_,bool>(2)?})),
        ).optional()?;
        Ok(Receipt {
            intent: serde_json::from_str(&intent).map_err(|_| ApiError::internal())?,
            revocation_confirmed: installation
                .as_ref()
                .is_some_and(|i| i.revocation == "confirmed"),
            target_installed: installation.is_some(),
            operation_authority,
            cancellation,
            installation,
            state,
            error_code,
            created_at,
            updated_at,
            sandbox_processes: crate::process_journal::summary(db, session)?,
            host_commands: crate::host_commands::summary(db, session)?,
            terminals: crate::terminals::journal::summary(db, session)?,
            browser: crate::browser::journal::summary(db, session)?,
            native_proxy: Default::default(),
            revocation: None,
        })
    })
    .transpose()
}
#[cfg(test)]
pub(crate) fn accept(
    db: &Connection,
    owner: &str,
    session: &str,
    intent: &Intent,
    client: &str,
    generation: i64,
) -> ApiResult<Receipt> {
    accept_with(db, owner, session, intent, client, generation, |_| {
        if intent.preflight.is_some() {
            return Err(ApiError::new(
                409,
                "resource_preflight_required",
                "Resource-bound acceptance requires the Node resource check",
            ));
        }
        Ok(())
    })
}
fn accept_with(
    db: &Connection,
    owner: &str,
    session: &str,
    intent: &Intent,
    client: &str,
    generation: i64,
    resource_check: impl FnOnce(&Connection) -> ApiResult<()>,
) -> ApiResult<Receipt> {
    validate(intent)?;
    if let Some(proof) = &intent.preflight
        && (proof.target_workspace_id.is_empty()
            || proof.target_workspace_id.len() > 1024
            || proof.target_workspace_id.contains('\0')
            || proof.evidence_hash.len() != 64
            || !proof
                .evidence_hash
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)))
    {
        return Err(ApiError::invalid_input());
    }
    atomic(db, |tx| {
        // A voided operation is refused before anything else, so a late request
        // can never create the fence the user cancelled. A fence and a void are
        // mutually exclusive; see `void`.
        void::require_not_voided(tx, owner, &intent.operation_id)?;
        if let Some(saved) = receipt(tx, owner, session, &intent.operation_id)? {
            if saved.intent != *intent {
                return Err(ApiError::conflict(
                    "Transition identity already has a different plan",
                ));
            }
            // A duplicate is a receipt, even after takeover, restart or deletion.
            return Ok(saved);
        }
        let current = tx.claim_session(session, owner, false)?;
        tx.validate_lease(session, client, generation)?;
        if current.workspace_id != intent.expected_workspace_id
            || current.runner_epoch != intent.expected_runner_epoch
        {
            return Err(ApiError::new(
                409,
                "stale_environment",
                "The source environment changed; refresh the transition preview",
            ));
        }
        tx.get_workspace(&current.workspace_id)?;
        require_open(tx, session)?;
        resource_check(tx)?;
        let stamp = now_ms();
        tx.execute(
            "INSERT INTO execution_fences(owner_user,operation_id,session_id,intent_json,state,error_code,created_at,updated_at) VALUES(?1,?2,?3,?4,'fenced',NULL,?5,?5)",
            params![
                owner,
                intent.operation_id,
                session,
                serde_json::to_string(intent).map_err(|_| ApiError::internal())?,
                stamp
            ],
        )?;
        receipt(tx, owner, session, &intent.operation_id)?.ok_or_else(ApiError::internal)
    })
}
fn stage(
    db: &Connection,
    owner: &str,
    session: &str,
    op: &str,
    state: &str,
    error: Option<&str>,
) -> ApiResult<Receipt> {
    db.execute("UPDATE execution_fences SET state=?4,error_code=?5,updated_at=?6 WHERE owner_user=?1 AND session_id=?2 AND operation_id=?3 AND state NOT IN ('deleted','supervisor_drained','installed','released')",params![owner,session,op,state,error,now_ms()])?;
    receipt(db, owner, session, op)?.ok_or_else(|| ApiError::not_found("Transition not found"))
}
/// Every participant must be polled even when another fails, panics or remains
/// pending. These are cleanup observations, not a fail-fast transaction. Keep
/// input order for stable error selection, independent of completion order.
async fn settle_all<'a>(
    participants: impl IntoIterator<Item = BoxFuture<'a, ApiResult<()>>>,
) -> ApiResult<()> {
    let observations = participants.into_iter().map(|participant| async move {
        AssertUnwindSafe(participant)
            .catch_unwind()
            .await
            .unwrap_or_else(|_| Err(ApiError::internal()))
    });
    let results = futures_util::future::join_all(observations).await;
    results.into_iter().collect()
}

async fn stop_resources(node: &Node, session: &str) -> ApiResult<()> {
    // Runner stop can wait for a command/startup lock. Host commands must receive
    // cancellation now, not only after that lock opens. The durable admission
    // fence prevents a new launch while the independent observers are retiring.
    let _host_stop = node.host_commands.stop(session);
    if let Some(scopes) = node.sandbox.network_scopes() {
        scopes.revoke(session);
    }

    // Share one kernel retirement, including panic conversion, with terminal
    // recovery. Both still start independently of a blocked runner/command.
    let kernel = AssertUnwindSafe(crate::process_journal::retire_saved(node, session))
        .catch_unwind()
        .map(|result| result.unwrap_or_else(|_| Err(ApiError::internal())))
        .boxed()
        .shared();
    let terminal_kernel = kernel.clone();
    settle_all([
        node.runners.stop_session(session).boxed(),
        kernel.boxed(),
        node.host_commands.wait_session(node, session).boxed(),
        async {
            let live = node.terminals.stop_live(session).await;
            let _ = terminal_kernel.await; // Its result is retained by the sibling participant.
            let recovered = crate::terminals::io_owners::recover(node, session).await;
            live?;
            recovered?;
            node.terminals.require_settled(session)
        }
        .boxed(),
        async {
            if let Some(scopes) = node.sandbox.network_scopes() {
                scopes.wait(Some(session), Duration::from_secs(5)).await?;
            }
            Ok(())
        }
        .boxed(),
        // Construct inside the observed future so a synchronous service panic
        // cannot prevent the other cleanup branches from being polled.
        async { node.browser.close_session(session).await }.boxed(),
    ])
    .await
}

pub(crate) async fn drain(node: &Node, owner: &str, session: &str, op: &str) -> ApiResult<Receipt> {
    let work = {
        // One process owns the work, not the request waiting for its reply.
        // A canceled/expired HTTP request must not abandon terminal shutdown
        // after it has removed the terminal from the live registry.
        let mut active = node
            .execution_drains
            .0
            .lock()
            .unwrap_or_else(|p| p.into_inner());
        let key = (owner.to_owned(), session.to_owned(), op.to_owned());
        if let Some(work) = active.get(&key) {
            work.clone()
        } else {
            let saved = receipt(&node.db.lock(), owner, session, op)?
                .ok_or_else(|| ApiError::not_found("Transition not found"))?;
            if matches!(
                saved.state.as_str(),
                "deleted" | "supervisor_drained" | "installed" | "released"
            ) {
                // A settled source with a pending cancellation completes it here.
                if saved.state == "supervisor_drained" && saved.cancellation.is_some() {
                    let db = node.db.lock();
                    if let Some(reason) = install::try_release(node, &db, owner, session, op)? {
                        db.execute("UPDATE execution_fences SET cancel_reason=?3 WHERE owner_user=?1 AND operation_id=?2",params![owner,op,reason])?;
                    }
                    return receipt(&db, owner, session, op)?.ok_or_else(ApiError::internal);
                }
                return Ok(saved);
            }
            let node = node.clone();
            let entry = DrainEntry {
                drains: node.execution_drains.clone(),
                key: key.clone(),
            };
            let task = tokio::spawn(async move {
                let _entry = entry;
                let (owner, session, op) = key;
                {
                    let db = node.db.lock();
                    db.claim_session(&session, &owner, false)?;
                    // A fence released or ended before this task ran must not
                    // stop the source it handed back (C3 serialization).
                    let staged = stage(&db, &owner, &session, &op, "stopping", None)?;
                    if staged.state != "stopping" {
                        return Ok(staged);
                    }
                    node.inference.revoke_session(&session);
                }
                let stopped = stop_resources(&node, &session).await;
                let (state, error) = match stopped {
                    Ok(()) => ("supervisor_drained", None),
                    Err(error) => (
                        "blocked",
                        Some(if error.code == "host_stop_unconfirmed" {
                            "host_stop_unconfirmed"
                        } else if error.code == "terminal_stop_unconfirmed" {
                            "terminal_stop_unconfirmed"
                        } else if error.code == "network_stop_unconfirmed" {
                            "network_stop_unconfirmed"
                        } else if error.code == "browser_stop_unconfirmed" {
                            "browser_stop_unconfirmed"
                        } else {
                            "supervisor_stop_unconfirmed"
                        }),
                    ),
                };
                let db = node.db.lock();
                let staged = stage(&db, &owner, &session, &op, state, error)?;
                // A cancellation requested during the drain completes now, if safe.
                let requested: bool = db.query_row("SELECT cancel_requested_at IS NOT NULL FROM execution_fences WHERE owner_user=?1 AND operation_id=?2",params![owner,op],|r|r.get(0))?;
                if requested {
                    match install::try_release(&node, &db, &owner, &session, &op)? {
                        None => {}
                        Some(reason) => {
                            db.execute("UPDATE execution_fences SET cancel_reason=?3 WHERE owner_user=?1 AND operation_id=?2",params![owner,op,reason])?;
                        }
                    }
                    return receipt(&db, &owner, &session, &op)?.ok_or_else(ApiError::internal);
                }
                Ok(staged)
            });
            let work = async move { task.await.unwrap_or_else(|_| Err(ApiError::internal())) }
                .boxed()
                .shared();
            active.insert(
                (owner.to_owned(), session.to_owned(), op.to_owned()),
                work.clone(),
            );
            work
        }
    };
    // Timeout limits only this caller's wait. The tracked task still drains;
    // GET reports stopping, and a retry joins that same work.
    match tokio::time::timeout(Duration::from_secs(30), work).await {
        Ok(result) => result,
        Err(_) => receipt(&node.db.lock(), owner, session, op)?
            .ok_or_else(|| ApiError::not_found("Transition not found")),
    }
}
pub async fn capabilities(node: Node, _request: Request) -> ApiResult<Response> {
    Ok(Response::json(
        json!({"version":1,"resourcePreflightVersion":1,"resourceFenceVersion":1,"stopCommandVersion":1,"terminalIoClosureVersion":1,"terminalIoOwnerRecoveryVersion":1,"workTerminalRequestVersion":crate::terminals::requests::VERSION,"hostTerminalReviewVersion":1,"hostManagementApprovalVersion":1,"isolatedTerminalVersion":if node.sandbox.isolated_terminals(){1}else{0},"nativeProxyRevocationVersion":if node.sandbox.network_scopes().is_some(){1}else{0},"revocationEvaluationVersion":1,"operationAuthorityVersion":1,"transitionAcknowledgementVersion":1,"transitionReleaseVersion":1,"transitionVoidVersion":1,"durableAdmissionFence":true,"trackedSupervisorDrain":true,"installsEnvironment":true,"confirmsRevocation":node.sandbox.contains_descendants()}),
    ))
}
/// Run `body` inside `BEGIN IMMEDIATE`: committed if it succeeds, rolled back
/// if it fails. `atomic` inside it nests as a savepoint.
fn immediate<T>(db: &Connection, body: impl FnOnce() -> ApiResult<T>) -> ApiResult<T> {
    db.execute_batch("BEGIN IMMEDIATE")?;
    match body() {
        Ok(value) => match db.execute_batch("COMMIT") {
            Ok(()) => Ok(value),
            Err(error) => {
                let _ = db.execute_batch("ROLLBACK");
                Err(error.into())
            }
        },
        Err(error) => {
            let _ = db.execute_batch("ROLLBACK");
            Err(error)
        }
    }
}
pub async fn create(node: Node, request: Request) -> ApiResult<Response> {
    let body: Acceptance = request.parse_body()?;
    let result = {
        let db = node.db.lock();
        let session = request.param("id").unwrap_or_default();
        let cached:bool=db.query_row("SELECT EXISTS(SELECT 1 FROM execution_fences WHERE owner_user=?1 AND session_id=?2 AND operation_id=?3)",params![request.user,session,body.intent.operation_id],|r|r.get(0))?;
        if !cached {
            // A voided operation is refused before this source's I/O is paused.
            void::require_not_voided(&db, &request.user, &body.intent.operation_id)?;
            // Store ownership checks are read-only; reject other users before
            // pausing this source's I/O for the acceptance transaction.
            db.claim_session(session, &request.user, false)?;
        }
        let accept = || {
            // Take the write lock first (`atomic` alone is a savepoint). A void
            // is decided under the same connection lock and the same lock mode,
            // so a fence and a void of one operation can never both commit.
            let result = immediate(&db, || {
                accept_with(
                    &db,
                    &request.user,
                    session,
                    &body.intent,
                    &body.client_id,
                    body.generation,
                    |tx| {
                        preflight::check_proof(&node, tx, &request.user, session, &body.intent)?;
                        // Recorded with the fence itself, in the same transaction.
                        if let Some(grant) = &body.operation_authority {
                            authority::record(tx, &request.user, &body.intent.operation_id, grant)?;
                        }
                        Ok(())
                    },
                )
            });
            if result.is_err() {
                // A known rollback leaves the prior proxy usable. Failed rollback
                // or unreadable commit outcome cannot release network authority.
                let rollback_known=db.is_autocommit() && db.query_row(&format!("SELECT NOT EXISTS(SELECT 1 FROM execution_fences WHERE session_id=?1 AND {ACTIVE})"),[session],|r|r.get::<_,bool>(0)).unwrap_or(false);
                if !rollback_known && let Some(scopes) = node.sandbox.network_scopes() {
                    scopes.revoke(session);
                }
            }
            result
        };
        let result = if let Some(scopes) = node.sandbox.network_scopes() {
            scopes.fence(session, accept)?
        } else {
            accept()?
        };
        node.inference
            .revoke_session(request.param("id").unwrap_or_default());
        result
    };
    let result = network_observation(&node, request.param("id").unwrap_or_default(), result);
    Ok(Response::json(json!({"transition":result})))
}
pub async fn status(node: Node, request: Request) -> ApiResult<Response> {
    let saved = receipt(
        &node.db.lock(),
        &request.user,
        request.param("id").unwrap_or_default(),
        request.param("operation").unwrap_or_default(),
    )?
    .ok_or_else(|| ApiError::not_found("Transition not found"))?;
    let saved = network_observation(&node, request.param("id").unwrap_or_default(), saved);
    Ok(Response::json(json!({"transition":saved})))
}
pub async fn resume(node: Node, request: Request) -> ApiResult<Response> {
    let saved = drain(
        &node,
        &request.user,
        request.param("id").unwrap_or_default(),
        request.param("operation").unwrap_or_default(),
    )
    .await?;
    let saved = network_observation(&node, request.param("id").unwrap_or_default(), saved);
    Ok(Response::json(json!({"transition":saved})))
}
/// Page one immutable evaluation snapshot (C2). Cursors are offsets into that
/// exact sorted set, so they never drift to another evaluation.
pub async fn evaluation_page(node: Node, request: Request) -> ApiResult<Response> {
    let session = request.param("id").unwrap_or_default();
    let op = request.param("operation").unwrap_or_default();
    let id = request.param("evaluation").unwrap_or_default();
    let offset = match request.single_query("cursor")? {
        None => 0,
        Some(text) => text
            .parse::<usize>()
            .map_err(|_| ApiError::invalid_input())?,
    };
    let limit = match request.single_query("limit")? {
        None => 100,
        Some(text) => text
            .parse::<usize>()
            .ok()
            .filter(|n| (1..=200).contains(n))
            .ok_or_else(ApiError::invalid_input)?,
    };
    let db = node.db.lock();
    db.claim_session(session, &request.user, false)?;
    let row: Option<(String, String, i64, String)> = db
        .query_row(
            "SELECT e.digest,e.status,e.items_total,e.items_json FROM revocation_evaluations e JOIN execution_fences f ON f.owner_user=e.owner_user AND f.operation_id=e.operation_id WHERE e.owner_user=?1 AND e.operation_id=?2 AND e.evaluation_id=?3 AND f.session_id=?4",
            params![request.user, op, id, session],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
        )
        .optional()?;
    let (digest, status, total, items) =
        row.ok_or_else(|| ApiError::new(404, "evaluation_not_found", "Evaluation not found"))?;
    let items: Vec<serde_json::Value> =
        serde_json::from_str(&items).map_err(|_| ApiError::internal())?;
    let page: Vec<_> = items.iter().skip(offset).take(limit).cloned().collect();
    let next = (offset + page.len() < items.len()).then(|| (offset + page.len()).to_string());
    Ok(Response::json(
        json!({"evaluation":{"evaluationId":id,"digest":digest,"status":status,
        "itemsTotal":total,"items":page,"next":next}}),
    ))
}
fn network_observation(node: &Node, session: &str, mut receipt: Receipt) -> Receipt {
    receipt.native_proxy = node
        .sandbox
        .network_scopes()
        .map_or_else(Default::default, |scopes| scopes.summary(session));
    // An ended fence is described by its installation, not by evaluating the
    // generation that replaced or kept its source.
    if !matches!(receipt.state.as_str(), "deleted" | "installed" | "released") {
        // An unreadable evaluation is omitted, never reported as confirmed.
        let db = node.db.lock();
        receipt.revocation = revocation::evaluate(node, &db, session, &receipt.state)
            .ok()
            .map(|mut evaluation| {
                // A drained, reviewable set is stored once as an immutable snapshot.
                if evaluation.status != "pending"
                    && let Ok(Some(owner)) = db
                        .query_row(
                            "SELECT owner_user FROM execution_fences WHERE session_id=?1 AND operation_id=?2",
                            params![session, receipt.intent.operation_id],
                            |r| r.get::<_, String>(0),
                        )
                        .optional()
                {
                    evaluation.evaluation_id =
                        revocation::snapshot(&db, &owner, &receipt.intent.operation_id, &evaluation).ok();
                }
                evaluation
            });
    }
    receipt
}

#[cfg(test)]
mod tests;
