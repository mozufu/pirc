//! Durable review of an existing-workspace transition, not acceptance or grants.
//! A preview cannot retire the source, allocate folders or publish a new binding.
mod preflight;

use axum::{
    Extension, Json, Router,
    extract::{Path, State},
    routing::{get, post},
};
use pirc_protocol::{HttpMethod, NodeHttpRequest};
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::{Binding, policies};
use crate::{
    app::{AppState, ReqBody},
    auth::Identity,
    db::{Store, atomic},
    error::{ApiError, ApiResult},
    util::{now_ms, payload_hash},
};

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Input {
    operation_id: String,
    target_workspace_id: String,
    expected_binding: Binding,
}
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct Preview {
    operation_id: String,
    session_id: String,
    target_workspace_id: String,
    plan_hash: String,
    plan: Value,
    created_at: i64,
    #[serde(skip)]
    intent_hash: String,
}
fn valid(input: &Input) -> bool {
    !input.operation_id.is_empty()
        && input.operation_id.len() <= 100
        && input
            .operation_id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
        && !input.target_workspace_id.is_empty()
        && input.target_workspace_id.len() <= 1024
        && !input.target_workspace_id.contains('\0')
}
fn read(db: &Connection, user: &str, session: &str, op: &str) -> ApiResult<Preview> {
    let row = db.query_row(
        "SELECT operation_id,session_id,target_workspace_id,intent_hash,plan_hash,plan_json,created_at FROM conversation_transition_previews WHERE owner_user=?1 AND operation_id=?2 AND session_id=?3",
        params![user,op,session], |r| Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?,r.get::<_,String>(2)?,r.get::<_,String>(3)?,r.get::<_,String>(4)?,r.get::<_,String>(5)?,r.get::<_,i64>(6)?)),
    ).optional()?.ok_or_else(||ApiError::not_found("Transition preview not found"))?;
    Ok(Preview {
        operation_id: row.0,
        session_id: row.1,
        target_workspace_id: row.2,
        intent_hash: row.3,
        plan_hash: row.4,
        plan: serde_json::from_str(&row.5).map_err(|_| ApiError::internal())?,
        created_at: row.6,
    })
}
fn snapshot(db: &Connection, user: &str, session: &str, target: &str) -> ApiResult<Value> {
    atomic(db, |db| {
        let source = policies::environment(db, user, session)?;
        let session = db.claim_session(session, user, false)?;
        let workspace = db.get_workspace(target)?;
        if !db.checkpoint_workspace_visible_to_user(target, user)? {
            return Err(ApiError::not_found("Workspace not found"));
        }
        let mode: Option<(i64, Option<String>)> = db
            .query_row(
                "SELECT revision,mode_json FROM current_mode_policies WHERE mode_id=?",
                [workspace.mode.as_str()],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?;
        let mode = mode.map(|(revision,raw)| -> ApiResult<Value> {
            Ok(json!({"revision":revision,"definition":raw.map(|s|serde_json::from_str::<Value>(&s)).transpose().map_err(|_|ApiError::internal())?}))
        }).transpose()?;
        let (revision, raw): (i64, String) = db.query_row(
            "SELECT revision,policy_json FROM current_workspace_policies WHERE workspace_id=?",
            [target],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )?;
        let policy: Value = serde_json::from_str(&raw).map_err(|_| ApiError::internal())?;
        Ok(json!({
            "version":1,"source":{"environment":source,"runnerEpoch":session.runner_epoch,
                "cachedRunStatus":session.run_status},
            "target":{"workspaceId":workspace.id,"nodeId":workspace.host_id,
                "modeId":workspace.mode,"modePolicy":mode,
                "workspacePolicy":{"revision":revision,"capabilities":policy}},
            "context":"retain","files":"stay_at_source","resourceResolution":"requires_node_preflight"
        }))
    })
}
fn reserve(db: &Connection, user: &str, session: &str, input: &Input) -> ApiResult<Preview> {
    if !valid(input) {
        return Err(ApiError::invalid_input());
    }
    let intent = payload_hash(&json!({"user":user,"sessionId":session,"input":input}));
    atomic(db, |db| {
        // Check both scopes even on a replay; a saved preview grants no access.
        let plan = snapshot(db, user, session, &input.target_workspace_id)?;
        let existing:Option<String>=db.query_row("SELECT session_id FROM conversation_transition_previews WHERE owner_user=?1 AND operation_id=?2",params![user,input.operation_id],|r|r.get(0)).optional()?;
        if let Some(existing_session) = existing {
            if existing_session != session {
                return Err(ApiError::new(
                    409,
                    "conflict",
                    "Transition preview identity already belongs to another conversation",
                ));
            }
            let row = read(db, user, session, &input.operation_id)?;
            if row.intent_hash != intent {
                return Err(ApiError::new(
                    409,
                    "conflict",
                    "Transition preview identity already has different intent",
                ));
            }
            return Ok(row);
        }
        if serde_json::to_value(&input.expected_binding).map_err(|_| ApiError::internal())?
            != plan["source"]["environment"]["binding"]
        {
            return Err(ApiError::new(
                409,
                "stale_environment",
                "Refresh the source environment before previewing a switch",
            ));
        }
        let hash = payload_hash(&json!({"user":user,"plan":plan}));
        db.execute(
            "INSERT INTO conversation_transition_previews VALUES(?1,?2,?3,?4,?5,?6,?7,?8)",
            params![
                user,
                input.operation_id,
                session,
                input.target_workspace_id,
                intent,
                hash,
                plan.to_string(),
                now_ms()
            ],
        )?;
        read(db, user, session, &input.operation_id)
    })
}

pub fn router() -> Router<AppState> {
    Router::new()
        .route(
            "/api/sessions/{id}/environment-transitions/previews",
            post(prepare),
        )
        .route(
            "/api/sessions/{id}/environment-transitions/previews/{operation}",
            get(status),
        )
}
async fn prepare(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(id): Path<String>,
    ReqBody(body): ReqBody,
) -> ApiResult<Json<Value>> {
    let input: Input = body.parse()?;
    let row = {
        let db = app.db.lock();
        crate::auth::require_current_device(&app, &db, &identity)?;
        reserve(&db, &identity.user, &id, &input)?
    };
    describe(&app, &identity, row).await.map(Json)
}
async fn status(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path((id, op)): Path<(String, String)>,
) -> ApiResult<Json<Value>> {
    let row = {
        let db = app.db.lock();
        crate::auth::require_current_device(&app, &db, &identity)?;
        snapshot(
            &db,
            &identity.user,
            &id,
            &read(&db, &identity.user, &id, &op)?.target_workspace_id,
        )?;
        read(&db, &identity.user, &id, &op)?
    };
    describe(&app, &identity, row).await.map(Json)
}
async fn describe(app: &AppState, identity: &Identity, row: Preview) -> ApiResult<Value> {
    let source = row.plan["source"]["environment"]["binding"]["execution"]["nodeId"].as_str();
    let target = row.plan["target"]["nodeId"].as_str();
    let mut nodes = Vec::new();
    for node in [source, target].into_iter().flatten() {
        if !nodes.contains(&node) {
            nodes.push(node);
        }
    }
    let mut observations = Vec::new();
    let mut connections = Vec::new();
    let mut resource_preflight = if source != target {
        json!({"status":"cross_node_unsupported"})
    } else {
        json!({"status":"unsupported_or_unavailable"})
    };
    for node in nodes {
        let connection = match app.nodes.connection(node) {
            Ok(c) => c,
            Err(_) => {
                observations.push(json!({"nodeId":node,"status":"offline"}));
                if source == Some(node) && source == target {
                    resource_preflight = json!({"status":"offline"});
                }
                continue;
            }
        };
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
        let value = match response {
            Ok(r) if r.status == 200 => r.body.unwrap_or(Value::Null),
            _ => Value::Null,
        };
        // Whitelist the observation; never return arbitrary Node error/body data.
        if value["version"] == 1
            && [
                "durableAdmissionFence",
                "trackedSupervisorDrain",
                "confirmsRevocation",
                "installsEnvironment",
            ]
            .iter()
            .all(|key| value[*key].is_boolean())
        {
            observations.push(json!({"nodeId":node,"status":"observed",
                "durableAdmissionFence":value["durableAdmissionFence"]==true,
                "trackedSupervisorDrain":value["trackedSupervisorDrain"]==true,
                "confirmsRevocation":value["confirmsRevocation"]==true,
                "installsEnvironment":value["installsEnvironment"]==true}));
        } else {
            observations.push(json!({"nodeId":node,"status":"unsupported_or_unavailable"}));
        }
        if source == Some(node)
            && source == target
            && value["resourcePreflightVersion"] == 1
            && observations
                .last()
                .is_some_and(|v| v["status"] == "observed")
        {
            resource_preflight = preflight::observe(app, identity, &row, node, connection).await?;
        }
        connections.push((node.to_owned(), connection));
    }
    // Network waits cannot extend a device grant or freeze a stale policy as current.
    let current = {
        let db = app.db.lock();
        crate::auth::require_current_device(app, &db, identity)?;
        snapshot(
            &db,
            &identity.user,
            &row.session_id,
            &row.target_workspace_id,
        )?
    };
    let stale = payload_hash(&json!({"user":identity.user,"plan":current})) != row.plan_hash;
    for (node, connection) in connections {
        if app.nodes.require_connection(&node, connection).is_err()
            && let Some(value) = observations.iter_mut().find(|v| v["nodeId"] == node)
        {
            *value = json!({"nodeId":node,"status":"connection_changed"});
            resource_preflight = json!({"status":"connection_changed"});
        }
    }
    if stale {
        resource_preflight = json!({"status":"preview_stale"});
    }
    let mut blockers = vec!["coordinator_not_available"];
    if resource_preflight["status"] != "observed" {
        blockers.push("resource_preflight_required");
    } else {
        let observation = &resource_preflight["observation"];
        if observation["policiesMatch"] != true {
            blockers.push("node_policy_mismatch");
        }
        if observation["overlap"] == true {
            blockers.push("resource_overlap_requires_review");
        }
        if observation["sourceResource"]["state"] != "observed"
            || observation["targetResource"]["state"] != "observed"
        {
            blockers.push("resource_unavailable");
        }
        if observation["activity"]["pendingRecords"] == true {
            blockers.push("source_has_pending_work");
        }
        if observation["activity"]["fenced"] == true {
            blockers.push("source_already_fenced");
        }
    }
    if row.plan["source"]["environment"]["modePolicy"]["definition"].is_null()
        || row.plan["target"]["modePolicy"]["definition"].is_null()
    {
        blockers.push("mode_unavailable");
    }
    if stale {
        blockers.push("preview_stale");
    }
    if source != target {
        blockers.push("cross_node_handoff_not_available");
    }
    if row.plan["source"]["environment"]["binding"]["execution"]["workspaceId"]
        == row.target_workspace_id
    {
        blockers.push("environment_unchanged");
    }
    if observations.iter().any(|n| n["status"] != "observed") {
        blockers.push("node_unavailable_or_unsupported");
    }
    if observations.is_empty() || observations.iter().any(|n| n["confirmsRevocation"] != true) {
        blockers.push("revocation_unconfirmed");
    }
    if observations.is_empty()
        || observations
            .iter()
            .any(|n| n["installsEnvironment"] != true)
    {
        blockers.push("target_installation_unavailable");
    }
    Ok(
        json!({"preview":row,"state":if stale {"stale"}else{"preview"},
        "canConfirm":false,"blockedBy":blockers,"nodeObservations":observations,"resourcePreflight":resource_preflight}),
    )
}
#[cfg(test)]
mod tests;
