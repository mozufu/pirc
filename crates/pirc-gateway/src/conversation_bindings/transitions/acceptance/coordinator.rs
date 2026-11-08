//! Drive an accepted transition after its Node fence: drain, revocation review,
//! acknowledgement, installation or explicit release. Each Node step is
//! idempotent per operation, so a retry only joins or reads the same step. The
//! Gateway binding moves only after the Node reports an installed fence.
use super::*;
use pirc_protocol::NodeHttpResponse;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Control {
    client_id: String,
    generation: i64,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Acknowledge {
    digest: String,
    client_id: String,
    generation: i64,
}

/// What clients see of a Node receipt: no private ids, paths or session names.
fn sanitize(t: &Value) -> Value {
    let rev = &t["revocation"];
    let revocation = if rev.is_object() {
        let items: Vec<Value> = rev["items"].as_array().map_or_else(Vec::new, |items| {
            items
                .iter()
                .map(|i| json!({"kind":i["kind"],"reason":i["reason"],"acknowledgeable":i["acknowledgeable"]==true}))
                .collect()
        });
        json!({"status":rev["status"],"digest":rev["digest"],"itemsTotal":rev["itemsTotal"],
            "confirmsContainment":rev["confirmsContainment"]==true,"items":items})
    } else {
        Value::Null
    };
    let installation = &t["installation"];
    json!({"state":t["state"],"errorCode":t["errorCode"],
        "revocationConfirmed":t["revocationConfirmed"]==true,"targetInstalled":t["targetInstalled"]==true,
        "revocation":revocation,
        "installation":if installation.is_object(){json!({"revocation":installation["revocation"],"environmentEvent":installation["environmentEvent"]})}else{Value::Null}})
}
/// The last sanitized Node receipt, with `observedAt` so a reader can judge
/// freshness without asking the Node.
pub(super) fn progress(db: &Connection, user: &str, op: &str) -> ApiResult<Value> {
    let raw: Option<(String, i64)> = db
        .query_row(
            "SELECT receipt_json,updated_at FROM conversation_transition_progress WHERE owner_user=?1 AND operation_id=?2",
            params![user, op],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()?;
    Ok(raw
        .and_then(|(raw, at)| {
            let mut value: Value = serde_json::from_str(&raw).ok()?;
            value["observedAt"] = json!(at);
            Some(value)
        })
        .unwrap_or(Value::Null))
}
fn state(db: &Connection, user: &str, id: &str, op: &str) -> ApiResult<String> {
    saved(db, user, id, op)?
        .map(|s| s.state)
        .ok_or_else(|| ApiError::not_found("Accepted transition not found"))
}
/// Current control for a user-initiated step, checked by the Gateway too.
fn control(db: &Connection, id: &str, user: &str, lease: &(String, i64)) -> ApiResult<()> {
    db.validate_lease(id, &lease.0, lease.1)?;
    db.validate_lease_user(id, user)
}
/// The source session still maps to the accepted Node source, under this device.
fn current(app: &AppState, identity: &Identity, id: &str, op: &str) -> ApiResult<(Frozen, String)> {
    let db = app.db.lock();
    access(app, &db, identity, id)?;
    let s = state(&db, &identity.user, id, op)?;
    let f = frozen(&db, &identity.user, id, op)?;
    if s == "node_fenced" || s == "accepted" || s == "outcome_unknown" {
        same_source(&db, identity, id, &f)?;
    }
    Ok((f, s))
}
async fn call(
    app: &AppState,
    identity: &Identity,
    f: &Frozen,
    connection: crate::nodes::NodeConnection,
    op: &str,
    step: &str,
    payload: Value,
) -> ApiResult<NodeHttpResponse> {
    app.nodes
        .request_on(
            &f.node,
            connection,
            NodeHttpRequest {
                method: HttpMethod::Post,
                url: format!(
                    "/api/sessions/{}/execution-fences/{}/{step}",
                    crate::routes::urlencoding_component(&f.remote),
                    crate::routes::urlencoding_component(op)
                ),
                user: identity.user.clone(),
                payload: Some(payload),
                body_base64: None,
                content_type: None,
            },
        )
        .await
}
/// A Node error the user can act on, passed through; anything else is opaque.
fn node_error(response: &NodeHttpResponse) -> ApiError {
    let body = response.body.clone().unwrap_or(Value::Null);
    let code = body["error"]["code"].as_str().unwrap_or_default();
    let known = [
        "revocation_unconfirmed",
        "revocation_digest_changed",
        "transition_not_unproven",
        "transition_not_drained",
        "transition_draining",
        "transition_installed",
        "transition_released",
        "transition_target_unreviewed",
        "stale_transition_target",
        "lost_control",
    ];
    match known.iter().find(|k| **k == code) {
        Some(code) => {
            let mut error = ApiError::new(
                409,
                code,
                body["error"]["message"]
                    .as_str()
                    .unwrap_or("Node refused the transition step"),
            );
            let details = &body["error"]["details"];
            if details.is_object() {
                error = error
                    .with_details(json!({"status":details["status"],"digest":details["digest"]}));
            }
            error
        }
        None => ApiError::new(
            502,
            "transition_step_failed",
            "Node did not complete the transition step; check its status",
        ),
    }
}
/// Persist a Node receipt for this exact intent, and adopt an ended fence.
fn observe(
    app: &AppState,
    identity: &Identity,
    id: &str,
    op: &str,
    f: &Frozen,
    body: &Value,
    connection: crate::nodes::NodeConnection,
) -> ApiResult<()> {
    let t = &body["transition"];
    if t["intent"] != f.intent
        || !t["revocationConfirmed"].is_boolean()
        || t["targetInstalled"] != (t["state"] == "installed")
        || (t["state"] == "installed" && t["installation"]["toWorkspaceId"] != f.target.as_str())
    {
        return Err(ApiError::new(
            502,
            "invalid_transition_receipt",
            "Node receipt differs from the accepted transition",
        ));
    }
    let changed = atomic(&app.db.lock(), |tx| {
        access(app, tx, identity, id)?;
        app.nodes.require_connection(&f.node, connection)?;
        let before = state(tx, &identity.user, id, op)?;
        if before == "node_fenced" {
            same_source(tx, identity, id, f)?;
        }
        tx.execute(
            "INSERT INTO conversation_transition_progress VALUES(?1,?2,?3,?4,?5) ON CONFLICT(owner_user,operation_id) DO UPDATE SET receipt_json=excluded.receipt_json,updated_at=excluded.updated_at",
            params![identity.user, op, id, sanitize(t).to_string(), now_ms()],
        )?;
        let ended = match (before.as_str(), t["state"].as_str()) {
            ("node_fenced", Some("installed")) => {
                // The binding trigger advances generation and membership revision.
                tx.execute(
                    "UPDATE sessions SET workspace_id=?2 WHERE id=?1",
                    params![id, f.target_workspace_id],
                )?;
                Some("installed")
            }
            ("node_fenced", Some("released")) => Some("released"),
            _ => None,
        };
        if let Some(end) = ended {
            tx.execute("UPDATE conversation_transition_acceptances SET state=?4 WHERE owner_user=?1 AND session_id=?2 AND operation_id=?3 AND state='node_fenced'",params![identity.user,id,op,end])?;
            tx.execute("UPDATE conversation_node_fences SET state=?4 WHERE owner_user=?1 AND session_id=?2 AND operation_id=?3 AND state='fenced'",params![identity.user,id,op,end])?;
        }
        Ok(ended.is_some())
    })?;
    if changed {
        app.sessions_changed(Some(&identity.user));
    }
    Ok(())
}
fn describe(app: &AppState, identity: &Identity, id: &str, op: &str) -> ApiResult<Value> {
    status(app, identity, id, op)
}
/// Recheck mapping and connection after a Node wait, then adopt its reply.
#[allow(clippy::too_many_arguments)]
async fn step(
    app: &AppState,
    identity: &Identity,
    id: &str,
    op: &str,
    f: &Frozen,
    connection: crate::nodes::NodeConnection,
    name: &str,
    payload: Value,
) -> ApiResult<Value> {
    let response = call(app, identity, f, connection, op, name, payload).await?;
    {
        let db = app.db.lock();
        access(app, &db, identity, id)?;
    }
    app.nodes.require_connection(&f.node, connection)?;
    if response.status != 200 {
        return Err(node_error(&response));
    }
    let body = response.body.unwrap_or(Value::Null);
    observe(app, identity, id, op, f, &body, connection)?;
    Ok(body)
}

/// Continue an accepted transition: drain, then install when revocation is
/// confirmed or already acknowledged. Offline Nodes leave it pending.
async fn advance(
    app: &AppState,
    identity: &Identity,
    id: &str,
    op: &str,
    lease: Option<(String, i64)>,
) -> ApiResult<Value> {
    if let Some(lease) = &lease {
        control(&app.db.lock(), id, &identity.user, lease)?;
    }
    if current(app, identity, id, op)?.1 == "outcome_unknown" {
        reconcile(app, identity, id, op).await?;
    }
    let (f, s) = current(app, identity, id, op)?;
    if s != "node_fenced" {
        return describe(app, identity, id, op);
    }
    let Ok(connection) = app.nodes.connection(&f.node) else {
        let mut result = describe(app, identity, id, op)?;
        result["reconciliationState"] = json!("node_unavailable");
        return Ok(result);
    };
    let drained = step(app, identity, id, op, &f, connection, "drain", json!({})).await?;
    let t = &drained["transition"];
    let ready = t["state"] == "supervisor_drained"
        && matches!(
            t["revocation"]["status"].as_str(),
            Some("confirmed" | "unproven")
        );
    if ready {
        let (client, generation) = lease.unwrap_or((f.client_id.clone(), f.generation));
        let install = json!({"planHash":f.plan_hash,"targetWorkspaceId":f.target,"clientId":client,"generation":generation});
        match step(app, identity, id, op, &f, connection, "install", install).await {
            Ok(_) => {}
            // Waiting for an acknowledgement or a current controller is not a failure.
            Err(error) if matches!(error.code, "revocation_unconfirmed") => {}
            Err(error) if matches!(error.code, "lost_control") => {}
            Err(error) => return Err(error),
        }
    }
    describe(app, identity, id, op)
}
async fn acknowledge(
    app: &AppState,
    identity: &Identity,
    id: &str,
    op: &str,
    input: Acknowledge,
) -> ApiResult<Value> {
    let lease = (input.client_id.clone(), input.generation);
    control(&app.db.lock(), id, &identity.user, &lease)?;
    let (f, s) = current(app, identity, id, op)?;
    if s != "node_fenced" {
        return Err(ApiError::new(
            409,
            "transition_not_reviewable",
            "Only a fenced, drained transition can be acknowledged",
        ));
    }
    let connection = app.nodes.connection(&f.node)?;
    step(
        app,
        identity,
        id,
        op,
        &f,
        connection,
        "acknowledge",
        json!({"planHash":f.plan_hash,"digest":input.digest,"clientId":lease.0,"generation":lease.1}),
    )
    .await?;
    advance(app, identity, id, op, Some(lease)).await
}
/// Explicit cancel. Before dispatch it only closes the Gateway intent; after a
/// Node fence it asks the Node to release. Never after installation.
async fn cancel(
    app: &AppState,
    identity: &Identity,
    id: &str,
    op: &str,
    lease: (String, i64),
) -> ApiResult<Value> {
    control(&app.db.lock(), id, &identity.user, &lease)?;
    {
        let db = app.db.lock();
        access(app, &db, identity, id)?;
        // `accepted` means no Node request was sent: dispatch moves to
        // `outcome_unknown` atomically first, so this cannot race a POST.
        let closed = db.execute("UPDATE conversation_transition_acceptances SET state='released' WHERE owner_user=?1 AND session_id=?2 AND operation_id=?3 AND state='accepted'",params![identity.user,id,op])?;
        if closed == 1 {
            drop(db);
            app.sessions_changed(Some(&identity.user));
            return describe(app, identity, id, op);
        }
    }
    if current(app, identity, id, op)?.1 == "outcome_unknown" {
        reconcile(app, identity, id, op).await?;
    }
    let (f, s) = current(app, identity, id, op)?;
    match s.as_str() {
        "released" => return describe(app, identity, id, op),
        "installed" => {
            return Err(ApiError::new(
                409,
                "transition_installed",
                "The target is installed; switching back is a new transition",
            ));
        }
        "node_fenced" => {}
        _ => {
            return Err(ApiError::new(
                409,
                "transition_outcome_unknown",
                "The Node outcome is unknown; reconcile before cancelling",
            ));
        }
    }
    let connection = app.nodes.connection(&f.node)?;
    step(
        app,
        identity,
        id,
        op,
        &f,
        connection,
        "release",
        json!({"planHash":f.plan_hash,"clientId":lease.0,"generation":lease.1}),
    )
    .await?;
    describe(app, identity, id, op)
}

/// Every 30 s and whenever a Node reconnects, continue accepted transitions with already-authorized steps only:
/// reconcile, drain and install after confirmed or acknowledged revocation,
/// using the confirming controller's lease. It never acknowledges or cancels.
pub(in crate::conversation_bindings::transitions) fn start(app: &AppState) {
    let weak = std::sync::Arc::downgrade(app);
    // A Node that (re)connects is the moment its fences can be read again, and
    // usually still within the confirming controller's lease.
    let wake = std::sync::Arc::new(tokio::sync::Notify::new());
    let notify = std::sync::Arc::downgrade(&wake);
    let subscription = app.events.subscribe_all(std::sync::Arc::new(move |event| {
        if event.kind == "node_reconnected"
            && let Some(wake) = notify.upgrade()
        {
            wake.notify_one();
        }
    }));
    tokio::spawn(async move {
        let _subscription = subscription;
        let mut interval = tokio::time::interval(std::time::Duration::from_secs(30));
        loop {
            tokio::select! {
                _ = interval.tick() => {}
                _ = wake.notified() => {
                    // Let the reconnect finish publishing before reading.
                    tokio::time::sleep(std::time::Duration::from_millis(150)).await;
                }
            }
            let Some(app) = weak.upgrade() else {
                break;
            };
            let mut after = (String::new(), String::new());
            loop {
                let page: ApiResult<Vec<(String, String, String)>> = (|| {
                    let db = app.db.lock();
                    let mut q = db.prepare("SELECT owner_user,operation_id,session_id FROM conversation_transition_acceptances WHERE state IN ('outcome_unknown','node_fenced') AND (owner_user,operation_id)>(?1,?2) ORDER BY owner_user,operation_id LIMIT 100")?;
                    Ok(q.query_map(params![after.0, after.1], |r| {
                        Ok((r.get(0)?, r.get(1)?, r.get(2)?))
                    })?
                    .collect::<Result<_, _>>()?)
                })();
                let Ok(page) = page else { break };
                for (user, op, id) in &page {
                    let identity = Identity {
                        user: user.clone(),
                        device_id: None,
                        management_authorized: false,
                    };
                    // Errors stay visible in status; the next sweep retries reads.
                    let _ = advance(&app, &identity, id, op, None).await;
                }
                match page.last() {
                    Some((user, op, _)) if page.len() == 100 => after = (user.clone(), op.clone()),
                    _ => break,
                }
            }
        }
    });
}

pub(in crate::conversation_bindings::transitions) async fn advance_route(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path((id, op)): Path<(String, String)>,
    ReqBody(body): ReqBody,
) -> ApiResult<Json<Value>> {
    let input: Control = body.parse()?;
    advance(
        &app,
        &identity,
        &id,
        &op,
        Some((input.client_id, input.generation)),
    )
    .await
    .map(Json)
}
pub(in crate::conversation_bindings::transitions) async fn acknowledge_route(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path((id, op)): Path<(String, String)>,
    ReqBody(body): ReqBody,
) -> ApiResult<Json<Value>> {
    let input: Acknowledge = body.parse()?;
    acknowledge(&app, &identity, &id, &op, input)
        .await
        .map(Json)
}
pub(in crate::conversation_bindings::transitions) async fn cancel_route(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path((id, op)): Path<(String, String)>,
    ReqBody(body): ReqBody,
) -> ApiResult<Json<Value>> {
    let input: Control = body.parse()?;
    cancel(
        &app,
        &identity,
        &id,
        &op,
        (input.client_id, input.generation),
    )
    .await
    .map(Json)
}

#[cfg(test)]
mod tests;
