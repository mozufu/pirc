//! Connection-scoped read-only Node observations. Never return raw Node bodies,
//! private session IDs or path data; never turn observations into switch grants.
use super::*;
use crate::nodes::NodeConnection;

fn digest(value: &Value) -> bool {
    value.as_str().is_some_and(|s| {
        s.len() == 64
            && s.bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    })
}
fn resource(value: &Value) -> Option<Value> {
    match value["state"].as_str()? {
        "observed" if digest(&value["identity"]) => {
            Some(json!({"state":"observed","identity":value["identity"]}))
        }
        state @ ("not_directory" | "not_materialized" | "unavailable") => {
            Some(json!({"state":state}))
        }
        _ => None,
    }
}
fn sanitized(
    body: &Value,
    session: &str,
    source: &str,
    target: &str,
    row: &Preview,
) -> Option<Value> {
    let e = &body["evidence"];
    if body["canConfirm"] != false
        || body["historyComplete"] != false
        || !digest(&body["evidenceHash"])
        || body["evidenceHash"] != payload_hash(e)
        || e["version"] != 1
        || e["sessionId"] != session
        || e["sourceWorkspaceId"] != source
        || e["targetWorkspaceId"] != target
        || !e["runnerEpoch"]
            .as_i64()
            .is_some_and(|epoch| (0..=9_007_199_254_740_991).contains(&epoch))
        || e["sourceMode"]["id"]
            != row.plan["source"]["environment"]["binding"]["execution"]["modeId"]
        || e["targetMode"]["id"] != row.plan["target"]["modeId"]
        || !digest(&e["sourceMode"]["definitionHash"])
        || !digest(&e["targetMode"]["definitionHash"])
        || !(e["overlap"].is_null() || e["overlap"].is_boolean())
    {
        return None;
    }
    let mut activity = serde_json::Map::new();
    for key in [
        "pendingRecords",
        "runnerPresent",
        "runnerStarting",
        "writeClaimsPresent",
        "fenced",
    ] {
        if !e["activity"][key].is_boolean() {
            return None;
        }
        activity.insert(key.into(), e["activity"][key].clone());
    }
    let policies_match = e["sourceMode"]["definitionHash"]
        == payload_hash(&row.plan["source"]["environment"]["modePolicy"]["definition"])
        && e["targetMode"]["definitionHash"]
            == payload_hash(&row.plan["target"]["modePolicy"]["definition"]);
    let observation = json!({"nodeEvidenceHash":body["evidenceHash"],"nodeRunnerEpoch":e["runnerEpoch"],"sourceResource":resource(&e["sourceResource"])?,"targetResource":resource(&e["targetResource"])?,
        "sourceModeHash":e["sourceMode"]["definitionHash"],"targetModeHash":e["targetMode"]["definitionHash"],
        "policiesMatch":policies_match,"overlap":e["overlap"],"activity":activity});
    Some(
        json!({"status":"observed","observationHash":payload_hash(&json!({"planHash":row.plan_hash,"observation":observation})),
        "observation":observation,"canConfirm":false,"historyComplete":false}),
    )
}
fn current(app: &AppState, identity: &Identity, row: &Preview) -> ApiResult<bool> {
    let db = app.db.lock();
    crate::auth::require_current_device(app, &db, identity)?;
    let plan = snapshot(
        &db,
        &identity.user,
        &row.session_id,
        &row.target_workspace_id,
    )?;
    Ok(payload_hash(&json!({"user":identity.user,"plan":plan})) == row.plan_hash)
}
pub(super) async fn observe(
    app: &AppState,
    identity: &Identity,
    row: &Preview,
    node: &str,
    connection: NodeConnection,
) -> ApiResult<Value> {
    // A capability probe may have waited while the device/policy was revoked.
    // Reauthorize before asking the host to inspect any resource.
    if !current(app, identity, row)? {
        return Ok(json!({"status":"preview_stale"}));
    }
    let (session, source, target) = {
        let db = app.db.lock();
        let session = db.claim_session(&row.session_id, &identity.user, false)?;
        let source = db.get_workspace(&session.binding.execution.workspace_id)?;
        let target = db.get_workspace(&row.target_workspace_id)?;
        if source.host_id != node
            || target.host_id != node
            || session.node_id.as_deref() != Some(node)
        {
            return Ok(json!({"status":"unsupported_mapping"}));
        }
        let (Some(session), Some(source), Some(target)) =
            (session.pi_session_id, source.local_id(), target.local_id())
        else {
            return Ok(json!({"status":"unsupported_mapping"}));
        };
        (session, source.to_owned(), target.to_owned())
    };
    let response = app
        .nodes
        .request_on(
            node,
            connection,
            NodeHttpRequest {
                method: HttpMethod::Post,
                url: format!(
                    "/api/sessions/{}/execution-fences/preflight",
                    crate::routes::urlencoding_component(&session)
                ),
                user: identity.user.clone(),
                payload: Some(json!({"expectedWorkspaceId":source,"targetWorkspaceId":target})),
                body_base64: None,
                content_type: None,
            },
        )
        .await;
    if !current(app, identity, row)? {
        return Ok(json!({"status":"preview_stale"}));
    }
    if app.nodes.require_connection(node, connection).is_err() {
        return Ok(json!({"status":"connection_changed"}));
    }
    Ok(match response {
        Ok(r) if r.status == 200 => r
            .body
            .as_ref()
            .and_then(|body| sanitized(body, &session, &source, &target, row))
            .unwrap_or_else(|| json!({"status":"invalid_observation"})),
        Ok(r) if r.status == 404 => json!({"status":"unsupported_or_unavailable"}),
        Ok(r) if r.status == 409 => json!({"status":"source_changed_or_unavailable"}),
        _ => json!({"status":"unavailable"}),
    })
}
