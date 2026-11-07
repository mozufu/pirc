//! Initial Gateway acceptance and one-attempt Node admission. Public confirmation
//! stays gated until complete revocation/installation exists. Once attempted,
//! duplicates only read; a lost response can never cause automatic resubmission.
use super::*;

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Confirmation {
    plan_hash: String,
    observation_hash: String,
    client_id: String,
    generation: i64,
}
#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Frozen {
    node: String,
    remote: String,
    source: String,
    target: String,
    target_workspace_id: String,
    plan_hash: String,
    intent: Value,
    client_id: String,
    generation: i64,
}
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct Accepted {
    operation_id: String,
    session_id: String,
    state: String,
    created_at: i64,
    revocation_confirmed: bool,
    target_installed: bool,
}
fn saved(db: &Connection, user: &str, session: &str, op: &str) -> ApiResult<Option<Accepted>> {
    // Flags come only from a retained installed Node receipt.
    Ok(db.query_row("SELECT a.operation_id,a.session_id,a.state,a.created_at,coalesce(json_extract(p.receipt_json,'$.revocationConfirmed'),0) FROM conversation_transition_acceptances a LEFT JOIN conversation_transition_progress p ON p.owner_user=a.owner_user AND p.operation_id=a.operation_id WHERE a.owner_user=?1 AND a.session_id=?2 AND a.operation_id=?3",params![user,session,op],|r|{let state:String=r.get(2)?;Ok(Accepted{operation_id:r.get(0)?,session_id:r.get(1)?,revocation_confirmed:state=="installed"&&r.get::<_,bool>(4)?,target_installed:state=="installed",state,created_at:r.get(3)?})}).optional()?)
}
pub(super) fn require_open(db: &Connection, session: &str) -> ApiResult<()> {
    if let Some((op,state))=db.query_row("SELECT operation_id,state FROM conversation_transition_acceptances WHERE session_id=? AND state NOT IN ('deleted','installed','released')",[session],|r|Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?))).optional()? {
        return Err(ApiError::new(409,"environment_transition_pending","An accepted environment transition blocks new work until reconciliation finishes")
            .with_details(json!({"operationId":op,"state":state,"revocationConfirmed":false,"targetInstalled":false})));
    }
    Ok(())
}
pub(super) fn require_unused(db: &Connection, user: &str, op: &str) -> ApiResult<()> {
    if db.query_row("SELECT EXISTS(SELECT 1 FROM conversation_transition_acceptances WHERE owner_user=?1 AND operation_id=?2)",params![user,op],|r|r.get::<_,bool>(0))? {
        return Err(ApiError::new(409,"conflict","This transition identity has already been accepted; query its status"));
    }
    Ok(())
}
fn access(app: &AppState, db: &Connection, identity: &Identity, id: &str) -> ApiResult<()> {
    crate::auth::require_current_device(app, db, identity)?;
    db.claim_session(id, &identity.user, false)?;
    Ok(())
}
fn frozen(db: &Connection, user: &str, id: &str, op: &str) -> ApiResult<Frozen> {
    let raw:String=db.query_row("SELECT frozen_json FROM conversation_transition_acceptances WHERE owner_user=?1 AND session_id=?2 AND operation_id=?3 AND state!='deleted'",params![user,id,op],|r|r.get(0))?;
    serde_json::from_str(&raw).map_err(|_| ApiError::internal())
}
fn reserve(
    app: &AppState,
    identity: &Identity,
    row: &Preview,
    input: &Confirmation,
    observation: &Value,
    mapping: &(String, String, String, String),
    connection: crate::nodes::NodeConnection,
) -> ApiResult<(Accepted, bool)> {
    let hash = payload_hash(&json!({"session":row.session_id,"confirmation":input}));
    atomic(&app.db.lock(), |tx| {
        access(app, tx, identity, &row.session_id)?;
        let existing:Option<(String,String)>=tx.query_row("SELECT session_id,intent_hash FROM conversation_transition_acceptances WHERE owner_user=?1 AND operation_id=?2",params![identity.user,row.operation_id],|r|Ok((r.get(0)?,r.get(1)?))).optional()?;
        if let Some((session, prior)) = existing {
            if session != row.session_id || prior != hash {
                return Err(ApiError::new(
                    409,
                    "conflict",
                    "Transition confirmation already has different intent",
                ));
            }
            return Ok((
                saved(tx, &identity.user, &row.session_id, &row.operation_id)?
                    .ok_or_else(ApiError::internal)?,
                true,
            ));
        }
        app.nodes.require_connection(&mapping.0, connection)?;
        if input.client_id.is_empty()
            || input.client_id.len() > 200
            || !(0..=9_007_199_254_740_991).contains(&input.generation)
        {
            return Err(ApiError::invalid_input());
        }
        tx.validate_lease(&row.session_id, &input.client_id, input.generation)?;
        tx.validate_lease_user(&row.session_id, &identity.user)?;
        let current = snapshot(
            tx,
            &identity.user,
            &row.session_id,
            &row.target_workspace_id,
        )?;
        if input.plan_hash != row.plan_hash
            || payload_hash(&json!({"user":identity.user,"plan":current})) != row.plan_hash
            || receipts::access_at(app, tx, identity, row)? != *mapping
        {
            return Err(ApiError::new(
                409,
                "stale_environment",
                "Refresh the transition preview before confirming",
            ));
        }
        let o = &observation["observation"];
        if observation["status"] != "observed"
            || observation["observationHash"] != input.observation_hash
            || o["policiesMatch"] != true
            || o["overlap"] != false
            || o["sourceResource"]["state"] != "observed"
            || o["targetResource"]["state"] != "observed"
            || o["activity"]["fenced"] != false
            || o["activity"]["pendingRecords"] != false
            || mapping.2 == mapping.3
            || !receipts::digest(&o["nodeEvidenceHash"])
            || !o["nodeRunnerEpoch"]
                .as_i64()
                .is_some_and(|n| (0..=9_007_199_254_740_991).contains(&n))
        {
            return Err(ApiError::new(
                409,
                "transition_review_changed",
                "Resources or activity changed; review the new observation",
            ));
        }
        receipts::require_open(tx, &row.session_id)?;
        receipts::require_unused(tx, &identity.user, &row.operation_id)?;
        let f = Frozen {
            node: mapping.0.clone(),
            remote: mapping.1.clone(),
            source: mapping.2.clone(),
            target: mapping.3.clone(),
            target_workspace_id: row.target_workspace_id.clone(),
            plan_hash: row.plan_hash.clone(),
            intent: json!({"operationId":row.operation_id,"planHash":row.plan_hash,"expectedWorkspaceId":mapping.2,"expectedRunnerEpoch":o["nodeRunnerEpoch"],"preflight":{"targetWorkspaceId":mapping.3,"evidenceHash":o["nodeEvidenceHash"]}}),
            client_id: input.client_id.clone(),
            generation: input.generation,
        };
        tx.execute(
            "INSERT INTO conversation_transition_acceptances VALUES(?1,?2,?3,?4,?5,'accepted',?6)",
            params![
                identity.user,
                row.operation_id,
                row.session_id,
                hash,
                serde_json::to_string(&f).map_err(|_| ApiError::internal())?,
                now_ms()
            ],
        )?;
        Ok((
            saved(tx, &identity.user, &row.session_id, &row.operation_id)?
                .ok_or_else(ApiError::internal)?,
            false,
        ))
    })
}
fn same_source(db: &Connection, identity: &Identity, id: &str, f: &Frozen) -> ApiResult<()> {
    let s = db.claim_session(id, &identity.user, false)?;
    if s.node_id.as_deref() != Some(&f.node)
        || s.pi_session_id.as_deref() != Some(&f.remote)
        || db.get_workspace(&s.workspace_id)?.local_id() != Some(&f.source)
    {
        return Err(ApiError::new(
            409,
            "source_binding_changed",
            "The accepted source mapping changed; keep the transition blocked",
        ));
    }
    Ok(())
}
fn observe_reply(
    app: &AppState,
    identity: &Identity,
    id: &str,
    op: &str,
    f: &Frozen,
    body: &Value,
    connection: crate::nodes::NodeConnection,
) -> ApiResult<()> {
    // A receipt must match every frozen field, not merely any resource proof.
    if body["transition"]["intent"] != f.intent {
        return Err(ApiError::new(
            502,
            "invalid_transition_receipt",
            "Node receipt differs from the accepted intent",
        ));
    }
    let changed = atomic(&app.db.lock(), |tx| {
        access(app, tx, identity, id)?;
        same_source(tx, identity, id, f)?;
        app.nodes.require_connection(&f.node, connection)?;
        let row = Preview {
            operation_id: op.into(),
            session_id: id.into(),
            target_workspace_id: f.target_workspace_id.clone(),
            plan_hash: f.plan_hash.clone(),
            plan: Value::Null,
            created_at: 0,
            intent_hash: String::new(),
        };
        let (_, duplicate) = receipts::record(
            tx,
            &identity.user,
            &row,
            &f.remote,
            &f.source,
            &f.target,
            body,
        )?;
        let updated=tx.execute("UPDATE conversation_transition_acceptances SET state='node_fenced' WHERE owner_user=?1 AND session_id=?2 AND operation_id=?3 AND state IN ('accepted','outcome_unknown')",params![identity.user,id,op])?;
        Ok(!duplicate || updated != 0)
    })?;
    if changed {
        app.sessions_changed(Some(&identity.user));
    }
    Ok(())
}
async fn dispatch_once(
    app: &AppState,
    identity: &Identity,
    id: &str,
    op: &str,
    connection: crate::nodes::NodeConnection,
) -> ApiResult<Value> {
    if let Some(current) = status_if_present(app, identity, id, op)?
        && current["transition"]["state"] != "accepted"
    {
        return Ok(current);
    }
    let (f, send) = {
        let db = app.db.lock();
        access(app, &db, identity, id)?;
        let f = frozen(&db, &identity.user, id, op)?;
        same_source(&db, identity, id, &f)?;
        app.nodes.require_connection(&f.node, connection)?;
        let send = atomic(&db, |tx| {
            let current = snapshot(tx, &identity.user, id, &f.target_workspace_id)?;
            if payload_hash(&json!({"user":identity.user,"plan":current})) != f.plan_hash {
                return Err(ApiError::new(
                    409,
                    "stale_environment",
                    "The accepted environment changed before dispatch; reconcile without resending",
                ));
            }
            app.nodes.require_connection(&f.node, connection)?;
            tx.validate_lease(id, &f.client_id, f.generation)?;
            tx.validate_lease_user(id, &identity.user)?;
            // Persist uncertainty BEFORE issuing the sole POST. Crashes even in
            // the pre-send gap keep the fence and require read-only recovery.
            Ok(tx.execute("UPDATE conversation_transition_acceptances SET state='outcome_unknown' WHERE owner_user=?1 AND session_id=?2 AND operation_id=?3 AND state='accepted'",params![identity.user,id,op])?==1)
        })?;
        (f, send)
    };
    if !send {
        return status(app, identity, id, op);
    }
    let response = app
        .nodes
        .request_on(
            &f.node,
            connection,
            NodeHttpRequest {
                method: HttpMethod::Post,
                url: format!(
                    "/api/sessions/{}/execution-fences",
                    crate::routes::urlencoding_component(&f.remote)
                ),
                user: identity.user.clone(),
                payload: Some(
                    json!({"intent":f.intent,"clientId":f.client_id,"generation":f.generation}),
                ),
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
    if app.nodes.require_connection(&f.node, connection).is_ok()
        && let Ok(r) = response
        && r.status == 200
    {
        observe_reply(
            app,
            identity,
            id,
            op,
            &f,
            &r.body.unwrap_or(Value::Null),
            connection,
        )?;
    }
    app.sessions_changed(Some(&identity.user));
    status(app, identity, id, op)
}
pub(super) fn status(app: &AppState, identity: &Identity, id: &str, op: &str) -> ApiResult<Value> {
    let db = app.db.lock();
    access(app, &db, identity, id)?;
    let s = saved(&db, &identity.user, id, op)?
        .ok_or_else(|| ApiError::not_found("Accepted transition not found"))?;
    Ok(
        json!({"transition":s,"canConfirm":false,"progress":coordinator::progress(&db,&identity.user,op)?}),
    )
}
pub(super) fn status_if_present(
    app: &AppState,
    identity: &Identity,
    id: &str,
    op: &str,
) -> ApiResult<Option<Value>> {
    let db = app.db.lock();
    access(app, &db, identity, id)?;
    Ok(saved(&db, &identity.user, id, op)?.map(|s| json!({"transition":s,"canConfirm":false})))
}
fn reconciliation_status(
    app: &AppState,
    identity: &Identity,
    id: &str,
    op: &str,
    observation: &str,
) -> ApiResult<Value> {
    let mut result = status(app, identity, id, op)?;
    result["reconciliationState"] = json!(observation);
    Ok(result)
}
pub(super) async fn reconcile(
    app: &AppState,
    identity: &Identity,
    id: &str,
    op: &str,
) -> ApiResult<Option<Value>> {
    let f = {
        let db = app.db.lock();
        access(app, &db, identity, id)?;
        if saved(&db, &identity.user, id, op)?.is_none() {
            return Ok(None);
        }
        let f = frozen(&db, &identity.user, id, op)?;
        same_source(&db, identity, id, &f)?;
        f
    };
    let connection = match app.nodes.connection(&f.node) {
        Ok(c) => c,
        Err(_) => {
            return reconciliation_status(app, identity, id, op, "node_unavailable").map(Some);
        }
    };
    let response = app
        .nodes
        .request_on(
            &f.node,
            connection,
            NodeHttpRequest {
                method: HttpMethod::Get,
                url: format!(
                    "/api/sessions/{}/execution-fences/{}",
                    crate::routes::urlencoding_component(&f.remote),
                    crate::routes::urlencoding_component(op)
                ),
                user: identity.user.clone(),
                payload: None,
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
    let observation = if app.nodes.require_connection(&f.node, connection).is_err() {
        "connection_changed"
    } else {
        match response {
            Ok(r) if r.status == 200 => {
                observe_reply(
                    app,
                    identity,
                    id,
                    op,
                    &f,
                    &r.body.unwrap_or(Value::Null),
                    connection,
                )?;
                "node_fenced"
            }
            Ok(r) if r.status == 404 => "receipt_unavailable",
            _ => "node_unavailable",
        }
    };
    reconciliation_status(app, identity, id, op, observation).map(Some)
}
pub(super) async fn confirm_route(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path((id, op)): Path<(String, String)>,
    ReqBody(body): ReqBody,
) -> ApiResult<Json<Value>> {
    let input: Confirmation = body.parse()?;
    {
        let db = app.db.lock();
        access(&app, &db, &identity, &id)?;
        let prior:Option<(String,String)>=db.query_row("SELECT session_id,intent_hash FROM conversation_transition_acceptances WHERE owner_user=?1 AND operation_id=?2",params![identity.user,op],|r|Ok((r.get(0)?,r.get(1)?))).optional()?;
        if let Some((session, hash)) = prior {
            if session != id || hash != payload_hash(&json!({"session":id,"confirmation":input})) {
                return Err(ApiError::new(
                    409,
                    "conflict",
                    "Transition confirmation already has different intent",
                ));
            }
            // A retry is a receipt, even if target/preview/control has vanished.
            let s = saved(&db, &identity.user, &id, &op)?.ok_or_else(ApiError::internal)?;
            return Ok(Json(json!({"transition":s,"canConfirm":false})));
        }
    }
    let row = {
        let db = app.db.lock();
        access(&app, &db, &identity, &id)?;
        read(&db, &identity.user, &id, &op)?
    };
    // Do not expose a one-way admission-only switch to users. This gate must be
    // removed only with full revocation, installation and client recovery proof.
    if !confirmation_available(&app) {
        return Err(ApiError::new(
            409,
            "transition_coordinator_unavailable",
            "Environment switching awaits verified revocation and installation",
        ));
    }
    let mapping = receipts::access(&app, &identity, &row)?;
    let connection = app.nodes.connection(&mapping.0)?;
    let observation = preflight::observe(&app, &identity, &row, &mapping.0, connection).await?;
    app.nodes.require_connection(&mapping.0, connection)?;
    let (_, duplicate) = reserve(
        &app,
        &identity,
        &row,
        &input,
        &observation,
        &mapping,
        connection,
    )?;
    if duplicate {
        return status(&app, &identity, &id, &op).map(Json);
    }
    app.sessions_changed(Some(&identity.user));
    dispatch_once(&app, &identity, &id, &op, connection)
        .await
        .map(Json)
}
/// Off unless the operator enables switching. Even then, revocation is
/// confirmed or explicitly acknowledged, and the Node installs the target.
fn confirmation_available(app: &AppState) -> bool {
    app.config.environment_switching
}

pub(super) mod coordinator;
#[cfg(test)]
mod tests;
