//! Reconcile an already-accepted Node fence. No acceptance, Stop/drain or target
//! installation is sent here. A missing/unknown receipt is not permission to retry.
use super::*;

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct Saved {
    operation_id: String,
    session_id: String,
    state: String,
    created_at: i64,
    revocation_confirmed: bool,
    target_installed: bool,
}
fn read_saved(db: &Connection, user: &str, session: &str, op: &str) -> ApiResult<Option<Saved>> {
    Ok(db.query_row("SELECT operation_id,session_id,state,created_at FROM conversation_node_fences WHERE owner_user=?1 AND session_id=?2 AND operation_id=?3",params![user,session,op],|r|Ok(Saved{operation_id:r.get(0)?,session_id:r.get(1)?,state:r.get(2)?,created_at:r.get(3)?,revocation_confirmed:false,target_installed:false})).optional()?)
}
pub(super) fn require_unused(db: &Connection, user: &str, op: &str) -> ApiResult<()> {
    let exists:bool=db.query_row("SELECT EXISTS(SELECT 1 FROM conversation_node_fences WHERE owner_user=?1 AND operation_id=?2)",params![user,op],|r|r.get(0))?;
    if exists {
        return Err(ApiError::new(
            409,
            "conflict",
            "This operation already records a Node fence; query its receipt",
        ));
    }
    Ok(())
}
pub(crate) fn require_open(db: &Connection, session: &str) -> ApiResult<()> {
    let op:Option<String>=db.query_row("SELECT operation_id FROM conversation_node_fences WHERE session_id=? AND state='fenced'",[session],|r|r.get(0)).optional()?;
    if let Some(op) = op {
        return Err(ApiError::new(409,"environment_transition_pending","The source environment is fenced; reconcile its transition before starting new work")
            .with_details(json!({"operationId":op,"state":"fenced","revocationConfirmed":false,"targetInstalled":false})));
    }
    Ok(())
}
fn digest(value: &Value) -> bool {
    value.as_str().is_some_and(|s| {
        s.len() == 64
            && s.bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    })
}
fn record(
    db: &Connection,
    user: &str,
    row: &Preview,
    remote: &str,
    source: &str,
    target: &str,
    body: &Value,
) -> ApiResult<(Saved, bool)> {
    let r = &body["transition"];
    let intent = &r["intent"];
    let local_epoch = intent["expectedRunnerEpoch"].as_i64();
    if intent["operationId"] != row.operation_id
        || intent["planHash"] != row.plan_hash
        || intent["expectedWorkspaceId"] != source
        || intent["preflight"]["targetWorkspaceId"] != target
        || !digest(&intent["preflight"]["evidenceHash"])
        || !local_epoch.is_some_and(|n| (0..=9_007_199_254_740_991).contains(&n))
        || r["revocationConfirmed"] != false
        || r["targetInstalled"] != false
        || !matches!(
            r["state"].as_str(),
            Some("fenced" | "stopping" | "blocked" | "supervisor_drained" | "deleted")
        )
    {
        return Err(ApiError::new(
            502,
            "invalid_transition_receipt",
            "Node returned an unsupported or mismatched transition receipt",
        ));
    }
    // Hash only the recognized immutable intent. Unknown/private Node fields
    // neither leave this function nor redefine the reconciliation identity.
    let identity = json!({"owner":user,"session":row.session_id,"remoteSession":remote,"planHash":row.plan_hash,
        "source":source,"target":target,"nodeRunnerEpoch":local_epoch,
        "evidenceHash":intent["preflight"]["evidenceHash"]});
    let hash = payload_hash(&identity);
    atomic(db, |tx| {
        tx.claim_session(&row.session_id, user, false)?;
        let old:Option<(String,String)>=tx.query_row("SELECT session_id,intent_digest FROM conversation_node_fences WHERE owner_user=?1 AND operation_id=?2",params![user,row.operation_id],|r|Ok((r.get(0)?,r.get(1)?))).optional()?;
        if let Some((session, prior)) = old {
            if session != row.session_id || prior != hash {
                return Err(ApiError::new(
                    409,
                    "conflict",
                    "Transition identity already records a different Node intent",
                ));
            }
            return Ok((
                read_saved(tx, user, &row.session_id, &row.operation_id)?
                    .ok_or_else(ApiError::internal)?,
                true,
            ));
        }
        require_open(tx, &row.session_id)?;
        tx.execute(
            "INSERT INTO conversation_node_fences VALUES(?1,?2,?3,?4,'fenced',?5)",
            params![user, row.operation_id, row.session_id, hash, now_ms()],
        )?;
        Ok((
            read_saved(tx, user, &row.session_id, &row.operation_id)?
                .ok_or_else(ApiError::internal)?,
            false,
        ))
    })
}
fn access(
    app: &AppState,
    identity: &Identity,
    row: &Preview,
) -> ApiResult<(String, String, String, String)> {
    access_at(app, &app.db.lock(), identity, row)
}
fn access_at(
    app: &AppState,
    db: &Connection,
    identity: &Identity,
    row: &Preview,
) -> ApiResult<(String, String, String, String)> {
    crate::auth::require_current_device(app, db, identity)?;
    snapshot(
        db,
        &identity.user,
        &row.session_id,
        &row.target_workspace_id,
    )?;
    let session = db.claim_session(&row.session_id, &identity.user, false)?;
    let source = db.get_workspace(&session.workspace_id)?;
    let target = db.get_workspace(&row.target_workspace_id)?;
    if source.id != row.plan["source"]["environment"]["binding"]["execution"]["workspaceId"]
        || source.host_id != target.host_id
        || row.plan["target"]["nodeId"] != source.host_id
        || row.plan["source"]["environment"]["binding"]["execution"]["nodeId"] != source.host_id
        || session.node_id.as_deref() != Some(source.host_id.as_str())
    {
        return Err(ApiError::new(
            409,
            "source_binding_changed",
            "The original source mapping is unavailable for reconciliation",
        ));
    }
    let remote = session
        .pi_session_id
        .ok_or_else(|| ApiError::not_found("Session not found"))?;
    Ok((
        source.host_id.clone(),
        remote,
        source.local_id().ok_or_else(ApiError::internal)?.into(),
        target.local_id().ok_or_else(ApiError::internal)?.into(),
    ))
}
async fn reconcile(app: &AppState, identity: &Identity, row: Preview) -> ApiResult<Value> {
    let mapping = access(app, identity, &row)?;
    let (node, remote, source, target) = &mapping;
    let saved = read_saved(
        &app.db.lock(),
        &identity.user,
        &row.session_id,
        &row.operation_id,
    )?;
    let connection = match app.nodes.connection(node) {
        Ok(c) => c,
        Err(_) => {
            return Ok(
                json!({"state":"node_unavailable","transition":saved,"duplicate":saved.is_some()}),
            );
        }
    };
    let response = app
        .nodes
        .request_on(
            node,
            connection,
            NodeHttpRequest {
                method: HttpMethod::Get,
                url: format!(
                    "/api/sessions/{}/execution-fences/{}",
                    crate::routes::urlencoding_component(remote),
                    crate::routes::urlencoding_component(&row.operation_id)
                ),
                user: identity.user.clone(),
                payload: None,
                body_base64: None,
                content_type: None,
            },
        )
        .await;
    // Epoch changes on reconnect do not erase an already-accepted receipt. Scope,
    // mapping and device access still must be current on both sides of the wait.
    if access(app, identity, &row)? != mapping {
        return Err(ApiError::new(
            409,
            "source_binding_changed",
            "The source mapping changed during reconciliation",
        ));
    }
    if app.nodes.require_connection(node, connection).is_err() {
        return Ok(
            json!({"state":"connection_changed","transition":saved,"duplicate":saved.is_some()}),
        );
    }
    match response {
        Ok(r) if r.status == 200 => {
            let body = r.body.unwrap_or(Value::Null);
            let (saved, duplicate) = atomic(&app.db.lock(), |tx| {
                if access_at(app, tx, identity, &row)? != mapping {
                    return Err(ApiError::new(
                        409,
                        "source_binding_changed",
                        "The source mapping changed before receipt persistence",
                    ));
                }
                app.nodes.require_connection(node, connection)?;
                record(tx, &identity.user, &row, remote, source, target, &body)
            })?;
            if !duplicate {
                app.sessions_changed(Some(&identity.user));
            }
            Ok(json!({"state":"fenced","transition":saved,"duplicate":duplicate}))
        }
        Ok(r) if r.status == 404 => Ok(
            json!({"state":"receipt_unavailable","transition":saved,"duplicate":saved.is_some()}),
        ),
        _ => Ok(json!({"state":"node_unavailable","transition":saved,"duplicate":saved.is_some()})),
    }
}
pub(super) async fn reconcile_route(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path((id, op)): Path<(String, String)>,
) -> ApiResult<Json<Value>> {
    let row = read(&app.db.lock(), &identity.user, &id, &op)?;
    reconcile(&app, &identity, row).await.map(Json)
}
pub(super) async fn status_route(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path((id, op)): Path<(String, String)>,
) -> ApiResult<Json<Value>> {
    let db = app.db.lock();
    crate::auth::require_current_device(&app, &db, &identity)?;
    db.claim_session(&id, &identity.user, false)?;
    let saved = read_saved(&db, &identity.user, &id, &op)?
        .ok_or_else(|| ApiError::not_found("Transition receipt not found"))?;
    Ok(Json(json!({"transition":saved})))
}

#[cfg(test)]
mod tests;
