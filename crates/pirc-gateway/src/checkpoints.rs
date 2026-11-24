//! Owner-scoped checkpoint routes. These requests are browser/API operations;
//! agent gateway requests have no checkpoint operations and cannot reach them.

use axum::Router;
use axum::extract::{Extension, Path, State};
use axum::routing::{get, post};
use pirc_protocol::{HttpMethod, RegisteredWorkspace};
use serde::Deserialize;
use serde_json::{Value, json};

use crate::app::{AppState, ReqBody, forward, query_map};
use crate::auth::Identity;
use crate::db::{Session, Store};
use crate::error::{ApiError, ApiResult, json_response};
use crate::routes::{self, Handled};

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/api/sessions/{id}/checkpoints", get(list))
        .route(
            "/api/sessions/{id}/checkpoints/{capture}/preview",
            post(preview),
        )
        .route(
            "/api/sessions/{id}/checkpoints/{capture}/recoveries",
            post(prepare),
        )
        .route(
            "/api/sessions/{id}/checkpoints/{capture}/recoveries/{job}",
            get(get_job),
        )
        .route(
            "/api/sessions/{id}/checkpoints/{capture}/recoveries/{job}/continue",
            post(continue_recovery),
        )
        .route("/api/sessions/{id}/checkpoints/{capture}/file", get(file))
}

fn node_url(claimed: &crate::app::Claimed, rest: &str) -> String {
    format!(
        "/api/sessions/{}{rest}",
        routes::urlencoding_component(&claimed.pi_session_id)
    )
}

fn relay_url(claimed: &crate::app::Claimed, capture: &str, rest: &str) -> String {
    node_url(
        claimed,
        &format!(
            "/checkpoints/{}/{}",
            routes::urlencoding_component(capture),
            rest
        ),
    )
}

fn rewrite_job_continuation(
    app: &AppState,
    identity: &Identity,
    node_id: &str,
    job: &mut Value,
) -> ApiResult<()> {
    let Some(continuation) = job
        .as_object_mut()
        .and_then(|job| job.get_mut("continuation"))
    else {
        return Ok(());
    };
    if continuation.is_null() {
        return Ok(());
    }
    let local_session_id = continuation
        .get("sessionId")
        .and_then(Value::as_str)
        .filter(|id| pirc_config::valid_node_id(id));
    let local_workspace_id = continuation
        .get("workspaceId")
        .and_then(Value::as_str)
        .filter(|id| pirc_config::valid_node_id(id));
    let (Some(local_session_id), Some(local_workspace_id)) = (local_session_id, local_workspace_id)
    else {
        *continuation = Value::Null;
        return Ok(());
    };

    let conn = app.db.lock();
    let Some(global_session_id) = conn.resolve_remote_session(node_id, local_session_id)? else {
        *continuation = Value::Null;
        return Ok(());
    };
    let session = conn.get_session(&global_session_id)?;
    let global_workspace_id = format!("{node_id}:{local_workspace_id}");
    if session.owner_user.as_deref() != Some(&identity.user)
        || session.node_id.as_deref() != Some(node_id)
        || session.pi_session_id.as_deref() != Some(local_session_id)
        || session.workspace_id != global_workspace_id
        || !conn.checkpoint_workspace_visible_to_user(&global_workspace_id, &identity.user)?
    {
        *continuation = Value::Null;
        return Ok(());
    }
    let Some(continuation) = continuation.as_object_mut() else {
        *continuation = Value::Null;
        return Ok(());
    };
    continuation.insert("sessionId".into(), json!(global_session_id));
    continuation.insert("workspaceId".into(), json!(global_workspace_id));
    Ok(())
}

fn rewrite_checkpoint_origin(
    app: &AppState,
    identity: &Identity,
    node_id: &str,
    body: &mut Value,
) -> ApiResult<()> {
    let Some(origin) = body.as_object_mut().and_then(|body| body.get_mut("origin")) else {
        return Ok(());
    };
    if origin.is_null() {
        return Ok(());
    }
    let local_session_id = origin
        .get("sessionId")
        .and_then(Value::as_str)
        .filter(|id| pirc_config::valid_node_id(id));
    let local_workspace_id = origin
        .get("workspaceId")
        .and_then(Value::as_str)
        .filter(|id| pirc_config::valid_node_id(id));
    let (Some(local_session_id), Some(local_workspace_id)) = (local_session_id, local_workspace_id)
    else {
        *origin = Value::Null;
        return Ok(());
    };
    let conn = app.db.lock();
    let Some(global_session_id) = conn.resolve_remote_session(node_id, local_session_id)? else {
        *origin = Value::Null;
        return Ok(());
    };
    let session = conn.get_session(&global_session_id)?;
    let global_workspace_id = format!("{node_id}:{local_workspace_id}");
    if session.owner_user.as_deref() != Some(&identity.user)
        || session.node_id.as_deref() != Some(node_id)
        || session.pi_session_id.as_deref() != Some(local_session_id)
        || session.workspace_id != global_workspace_id
        || !conn.checkpoint_workspace_visible_to_user(&global_workspace_id, &identity.user)?
    {
        *origin = Value::Null;
        return Ok(());
    }
    let Some(origin) = origin.as_object_mut() else {
        *origin = Value::Null;
        return Ok(());
    };
    origin.insert("sessionId".into(), json!(global_session_id));
    origin.insert("workspaceId".into(), json!(global_workspace_id));
    Ok(())
}

fn rewrite_response_job_ids(
    app: &AppState,
    identity: &Identity,
    node_id: &str,
    response: &mut pirc_protocol::NodeHttpResponse,
) -> ApiResult<()> {
    if response.status >= 400 {
        return Ok(());
    }
    let Some(body) = response.body.as_mut() else {
        return Ok(());
    };
    if let Some(jobs) = body.get_mut("jobs").and_then(Value::as_array_mut) {
        for job in jobs {
            rewrite_job_continuation(app, identity, node_id, job)?;
        }
    }
    rewrite_checkpoint_origin(app, identity, node_id, body)?;
    rewrite_job_continuation(app, identity, node_id, body)
}

fn validate_lease(
    app: &AppState,
    identity: &Identity,
    session: &Session,
    client_id: &str,
    generation: i64,
) -> ApiResult<()> {
    if !(1..=200).contains(&client_id.encode_utf16().count()) || generation <= 0 {
        return Err(ApiError::invalid_input());
    }
    let conn = app.db.lock();
    conn.validate_lease_user(&session.id, &identity.user)?;
    conn.validate_lease(&session.id, client_id, generation)
}

pub async fn list(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(session_id): Path<String>,
    uri: axum::http::Uri,
) -> Handled {
    let query = query_map(&uri);
    if query.keys().any(|key| key != "cursor") {
        return Err(ApiError::invalid_input().into());
    }
    let claimed = app.claim(&identity, &session_id)?;
    let mut url = node_url(&claimed, "/checkpoints");
    if let Some(values) = query.get("cursor") {
        let [cursor] = values.as_slice() else {
            return Err(ApiError::invalid_input().into());
        };
        if cursor.is_empty() || cursor.encode_utf16().count() > 200 {
            return Err(ApiError::invalid_input().into());
        }
        let cursor = form_urlencoded::Serializer::new(String::new())
            .append_pair("cursor", cursor)
            .finish();
        url.push('?');
        url.push_str(&cursor);
    }
    let mut response = app
        .relay(&claimed.node_id, &identity, HttpMethod::Get, url, None)
        .await?;
    rewrite_response_job_ids(&app, &identity, &claimed.node_id, &mut response)?;
    Ok(forward(response))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct SelectionBody {
    operations: Vec<String>,
    review_observational: bool,
}

pub async fn preview(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path((session_id, capture)): Path<(String, String)>,
    ReqBody(body): ReqBody,
) -> Handled {
    let SelectionBody {
        operations,
        review_observational,
    } = body.parse()?;
    let claimed = app.claim(&identity, &session_id)?;
    let response = app
        .relay(
            &claimed.node_id,
            &identity,
            HttpMethod::Post,
            relay_url(&claimed, &capture, "preview"),
            Some(json!({
                "operations": operations,
                "reviewObservational": review_observational,
            })),
        )
        .await?;
    Ok(forward(response))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct PrepareBody {
    version: u32,
    key: String,
    preview_revision: String,
    operations: Vec<String>,
    review_observational: bool,
    client_id: String,
    generation: i64,
}

pub async fn prepare(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path((session_id, capture)): Path<(String, String)>,
    ReqBody(body): ReqBody,
) -> Handled {
    let PrepareBody {
        version,
        key,
        preview_revision,
        operations,
        review_observational,
        client_id,
        generation,
    } = body.parse()?;
    let claimed = app.claim(&identity, &session_id)?;
    validate_lease(&app, &identity, &claimed.session, &client_id, generation)?;
    let mut response = app
        .relay(
            &claimed.node_id,
            &identity,
            HttpMethod::Post,
            relay_url(&claimed, &capture, "recoveries"),
            Some(json!({
                "version": version,
                "key": key,
                "previewRevision": preview_revision,
                "operations": operations,
                "reviewObservational": review_observational,
                "clientId": client_id,
                "generation": generation,
            })),
        )
        .await?;
    rewrite_response_job_ids(&app, &identity, &claimed.node_id, &mut response)?;
    Ok(forward(response))
}

pub async fn get_job(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path((session_id, capture, job)): Path<(String, String, String)>,
) -> Handled {
    let claimed = app.claim(&identity, &session_id)?;
    let mut response = app
        .relay(
            &claimed.node_id,
            &identity,
            HttpMethod::Get,
            relay_url(
                &claimed,
                &capture,
                &format!("recoveries/{}", routes::urlencoding_component(&job)),
            ),
            None,
        )
        .await?;
    rewrite_response_job_ids(&app, &identity, &claimed.node_id, &mut response)?;
    Ok(forward(response))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct ContinueBody {
    revision: i64,
    accept_unresolved: bool,
    client_id: String,
    generation: i64,
}

fn continuation_parts(
    body: &Value,
    node_id: &str,
) -> ApiResult<(String, String, String, RegisteredWorkspace)> {
    let invalid = || {
        ApiError::new(
            502,
            "node_error",
            "Node answered an invalid checkpoint continuation",
        )
    };
    let session = body
        .get("session")
        .and_then(Value::as_object)
        .ok_or_else(invalid)?;
    let workspace = body
        .get("workspace")
        .and_then(Value::as_object)
        .ok_or_else(invalid)?;
    let local_session_id = session
        .get("id")
        .and_then(Value::as_str)
        .ok_or_else(invalid)?;
    let local_workspace_id = workspace
        .get("id")
        .and_then(Value::as_str)
        .ok_or_else(invalid)?;
    if !pirc_config::valid_node_id(local_session_id)
        || !pirc_config::valid_node_id(local_workspace_id)
        || session.get("workspaceId").and_then(Value::as_str) != Some(local_workspace_id)
        || workspace.get("hostId").and_then(Value::as_str) != Some(node_id)
    {
        return Err(invalid());
    }
    let display_name = workspace
        .get("displayName")
        .and_then(Value::as_str)
        .filter(|name| (1..=200).contains(&name.encode_utf16().count()))
        .ok_or_else(invalid)?;
    let mode = serde_json::from_value(workspace.get("mode").cloned().ok_or_else(invalid)?)
        .map_err(|_| invalid())?;
    let registered = RegisteredWorkspace {
        id: local_workspace_id.to_owned(),
        display_name: display_name.to_owned(),
        mode,
        roles: None,
        repo: None,
        checkpoint_private: true,
    };
    if body.get("job").and_then(Value::as_object).is_none() {
        return Err(invalid());
    }
    Ok((
        local_session_id.to_owned(),
        local_workspace_id.to_owned(),
        display_name.to_owned(),
        registered,
    ))
}

pub async fn continue_recovery(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path((session_id, capture, job)): Path<(String, String, String)>,
    ReqBody(body): ReqBody,
) -> Handled {
    let ContinueBody {
        revision,
        accept_unresolved,
        client_id,
        generation,
    } = body.parse()?;
    let claimed = app.claim(&identity, &session_id)?;
    validate_lease(&app, &identity, &claimed.session, &client_id, generation)?;
    let response = app
        .relay(
            &claimed.node_id,
            &identity,
            HttpMethod::Post,
            relay_url(
                &claimed,
                &capture,
                &format!(
                    "recoveries/{}/continue",
                    routes::urlencoding_component(&job)
                ),
            ),
            Some(json!({
                "revision": revision,
                "acceptUnresolved": accept_unresolved,
                "clientId": client_id,
                "generation": generation,
            })),
        )
        .await?;
    if response.status >= 400 {
        return Ok(forward(response));
    }
    let response_body = response.body.as_ref().ok_or_else(|| {
        ApiError::new(
            502,
            "node_error",
            "Node answered an invalid checkpoint continuation",
        )
    })?;
    let (local_session_id, local_workspace_id, display_name, registered) =
        continuation_parts(response_body, &claimed.node_id)?;
    let global_workspace_id = format!("{}:{}", claimed.node_id, local_workspace_id);
    {
        let conn = app.db.lock();
        conn.sync_remote_workspaces(
            &claimed.node_id,
            &[(
                local_workspace_id.clone(),
                display_name,
                registered.mode.clone(),
            )],
        )?;
        conn.mark_checkpoint_workspace_private(&global_workspace_id)?;
        conn.claim_checkpoint_workspace(&global_workspace_id, &identity.user)?;
    }
    let raw_workspace = serde_json::to_value(&registered).map_err(|_| ApiError::internal())?;
    // A node can disappear after replying; the durable Gateway mapping still
    // succeeds, and reconnect will repopulate the in-memory registry.
    if app.nodes.get(&claimed.node_id).is_some() {
        let _ = app
            .nodes
            .upsert_workspace(&claimed.node_id, registered, raw_workspace);
    }
    let global_session = app.db.lock().create_checkpoint_session(
        &global_workspace_id,
        &format!("node://{}/{}", claimed.node_id, local_session_id),
        &claimed.node_id,
        &local_session_id,
        &identity.user,
    )?;
    let mut job = response_body["job"].clone();
    rewrite_job_continuation(&app, &identity, &claimed.node_id, &mut job)?;
    let result = json!({
        "session": global_session.public(),
        "workspaceId": global_workspace_id,
        "job": job,
    });
    app.sessions_changed(Some(&identity.user));
    app.directory_changed();
    Ok(json_response(response.status, &result))
}

pub async fn file(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path((session_id, capture)): Path<(String, String)>,
    uri: axum::http::Uri,
) -> Handled {
    let query = query_map(&uri);
    if query
        .keys()
        .any(|key| !["operation", "side", "job"].contains(&key.as_str()))
    {
        return Err(ApiError::invalid_input().into());
    }
    let value = |name: &str| -> ApiResult<String> {
        match query.get(name).map(Vec::as_slice) {
            Some([value]) if !value.is_empty() && value.encode_utf16().count() <= 200 => {
                Ok(value.clone())
            }
            _ => Err(ApiError::invalid_input()),
        }
    };
    let operation = value("operation")?;
    let side = value("side")?;
    let job = query.get("job").map(|_| value("job")).transpose()?;
    if !matches!(side.as_str(), "before" | "after" | "current" | "candidate")
        || (matches!(side.as_str(), "current" | "candidate") && job.is_none())
    {
        return Err(ApiError::invalid_input().into());
    }
    let claimed = app.claim(&identity, &session_id)?;
    let encoded_query = {
        let mut encoded = form_urlencoded::Serializer::new(String::new());
        encoded
            .append_pair("operation", &operation)
            .append_pair("side", &side);
        if let Some(job) = job {
            encoded.append_pair("job", &job);
        }
        encoded.finish()
    };
    let response = app
        .relay(
            &claimed.node_id,
            &identity,
            HttpMethod::Get,
            format!("{}?{encoded_query}", relay_url(&claimed, &capture, "file")),
            None,
        )
        .await?;
    Ok(forward(response))
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::{Body, to_bytes};
    use axum::extract::ConnectInfo;
    use axum::http::{Method, Request};
    use axum::response::Response;
    use pirc_protocol::{NodeHttpRequest, NodeHttpResponse, NodeRole, RegisteredWorkspace};
    use serde_json::Value;
    use std::sync::{Arc, Mutex};
    use tower::ServiceExt;

    fn fake_node_reply(request: &NodeHttpRequest) -> NodeHttpResponse {
        let url = request.url.split('?').next().unwrap_or(&request.url);
        let payload = request.payload.as_ref().unwrap_or(&Value::Null);
        let (status, body) = if url.ends_with("/checkpoints") {
            (
                200,
                json!({
                    "captures": [{ "id": "capture-1" }],
                    "origin": {
                        "sessionId": "source-session",
                        "workspaceId": "source-workspace",
                        "jobId": "job-1",
                        "captureId": "capture-1"
                    },
                    "jobs": [{
                        "id": "job-1",
                        "continuation": { "sessionId": "new-session", "workspaceId": "recovery-workspace" }
                    }]
                }),
            )
        } else if url.ends_with("/preview") {
            (
                200,
                json!({ "revision": "preview-1", "operations": [], "reviewObservational": false }),
            )
        } else if url.ends_with("/recoveries") && payload["previewRevision"] == "stale" {
            (
                409,
                json!({ "error": { "code": "stale_preview", "message": "Refresh the preview" } }),
            )
        } else if url.ends_with("/recoveries") {
            (
                201,
                json!({
                    "id": "job-1",
                    "state": "ready",
                    "revision": 1,
                    "continuation": { "sessionId": "new-session", "workspaceId": "recovery-workspace" }
                }),
            )
        } else if url.ends_with("/continue") {
            (
                200,
                json!({
                    "session": { "id": "new-session", "workspaceId": "recovery-workspace", "name": "New session" },
                    "workspace": {
                        "id": "recovery-workspace",
                        "hostId": "work",
                        "displayName": "Recovery",
                        "canonicalPath": "/private/recovery/root",
                        "defaults": { "checkpointOrigin": { "sourceSessionId": "source-session", "captureId": "capture-1", "jobId": "job-1" } },
                        "mode": "directory"
                    },
                    "job": {
                        "id": "job-1",
                        "state": "continued",
                        "continuation": { "sessionId": "new-session", "workspaceId": "recovery-workspace" }
                    }
                }),
            )
        } else if url.ends_with("/file") {
            (
                200,
                json!({"path":"file.txt","text":"private fixture","binary":false,"absent":false,"truncated":false}),
            )
        } else if url.contains("/recoveries/job-1") {
            (
                200,
                json!({
                    "id": "job-1",
                    "state": "ready",
                    "revision": 1,
                    "continuation": { "sessionId": "new-session", "workspaceId": "recovery-workspace" }
                }),
            )
        } else {
            (
                404,
                json!({ "error": { "code": "not_found", "message": "No such checkpoint route" } }),
            )
        };
        NodeHttpResponse {
            status,
            body: Some(body),
        }
    }

    fn fixture() -> (AppState, tempfile::TempDir) {
        use crate::app::App;
        use pirc_config::{Env, GatewayConfig};
        use std::sync::Arc;

        let dir = tempfile::tempdir().unwrap();
        let state = dir.path().join("state");
        let env = Env::new(
            [
                (
                    "PIRC_NODE_TOKENS",
                    r#"{"work":"0123456789abcdef0123456789abcdef"}"#,
                ),
                ("PIRC_TRUSTED_PROXIES", "127.0.0.1"),
                ("PIRC_ALLOWED_ORIGINS", "https://a.example"),
                ("PIRC_ALLOWED_HOSTS", "a.example"),
                ("PIRC_ALLOWED_USERS", "alice,bob"),
                ("PIRC_STATE_DIR", state.to_str().unwrap()),
                ("PIRC_CONFIG_DIR", dir.path().to_str().unwrap()),
                ("PIRC_TIMEZONE", "UTC"),
                ("HOME", "/home/test"),
            ],
            "/work",
        );
        let app = App::new(
            GatewayConfig::load(&env).unwrap(),
            Arc::new(crate::db::Db::memory()),
            pirc_providers::backends::BackendService::open(&state, crate::app::empty_models())
                .unwrap(),
            crate::app::test_modes(),
        );
        (app, dir)
    }

    async fn call(
        router: &axum::Router,
        method: Method,
        path: &str,
        user: Option<&str>,
        bearer: Option<&str>,
        body: Option<Value>,
    ) -> Response {
        let mut request = Request::builder()
            .method(method)
            .uri(path)
            .header("host", "a.example")
            .header("origin", "https://a.example");
        if let Some(user) = user {
            request = request.header("x-pirc-user", user);
        }
        if let Some(bearer) = bearer {
            request = request.header("authorization", format!("Bearer {bearer}"));
        }
        let request = if let Some(body) = body {
            request
                .header("content-type", "application/json")
                .extension(ConnectInfo(
                    "127.0.0.1:40000".parse::<std::net::SocketAddr>().unwrap(),
                ))
                .body(Body::from(body.to_string()))
                .unwrap()
        } else {
            request
                .extension(ConnectInfo(
                    "127.0.0.1:40000".parse::<std::net::SocketAddr>().unwrap(),
                ))
                .body(Body::empty())
                .unwrap()
        };
        router.clone().oneshot(request).await.unwrap()
    }

    async fn response_json(response: Response) -> Value {
        let bytes = to_bytes(response.into_body(), 2 * 1024 * 1024)
            .await
            .unwrap();
        serde_json::from_slice(&bytes).unwrap()
    }

    fn register_test_node(app: &AppState) -> Arc<Mutex<Vec<NodeHttpRequest>>> {
        let requests = Arc::new(Mutex::new(Vec::new()));
        let recorded = requests.clone();
        app.nodes.set_test_node(
            crate::nodes::ConnectedNode {
                id: "work".into(),
                role: NodeRole::Chat,
                modes: vec![pirc_protocol::mode::ModeId::new("directory").unwrap()],
                workspaces: vec![
                    RegisteredWorkspace {
                        checkpoint_private: false,
                        id: "source-workspace".into(),
                        display_name: "Source".into(),
                        mode: pirc_protocol::mode::ModeId::new("directory").unwrap(),
                        roles: None,
                        repo: None,
                    },
                    RegisteredWorkspace {
                        checkpoint_private: true,
                        id: "orphan-recovery".into(),
                        display_name: "Unclaimed recovery".into(),
                        mode: pirc_protocol::mode::ModeId::new("directory").unwrap(),
                        roles: None,
                        repo: None,
                    },
                ],
                connected_at: crate::util::now_ms(),
                last_seen_at: crate::util::now_ms(),
                added: Default::default(),
            },
            move |request| {
                recorded.lock().unwrap().push(request.clone());
                Ok(fake_node_reply(&request))
            },
        );
        let node = app.nodes.get("work").unwrap();
        app.on_node_register(&node);
        requests
    }

    #[tokio::test]
    async fn router_scopes_checkpoints_and_maps_idempotent_continuation() {
        use crate::db::{Lease, Store};

        let (app, _dir) = fixture();
        let node_requests = register_test_node(&app);
        let source = app
            .db
            .lock()
            .create_session(
                "work:source-workspace",
                "node://work/source-session",
                "work",
                "source-session",
                "alice",
            )
            .unwrap();
        let (_, device_token) = app.devices.create("alice", "Phone").unwrap();
        let router = crate::app::router(app.clone());
        let base = format!("/api/sessions/{}/checkpoints", source.id);

        let (agent_status, agent_body) = crate::agent_ops::run(
            &app,
            "work",
            "source-session",
            "checkpoint.prepare",
            json!({}),
        )
        .await;
        assert_eq!(agent_status, 404);
        assert_eq!(agent_body["error"]["code"], "unknown_operation");
        assert!(node_requests.lock().unwrap().is_empty());

        let denied = call(
            &router,
            Method::POST,
            &format!("{base}/capture-1/preview"),
            Some("bob"),
            None,
            Some(json!({ "operations": [], "reviewObservational": false })),
        )
        .await;
        assert_eq!(denied.status().as_u16(), 403);
        assert!(node_requests.lock().unwrap().is_empty());

        let paired_preview = call(
            &router,
            Method::POST,
            &format!("{base}/capture-1/preview"),
            None,
            Some(&device_token),
            Some(json!({ "operations": [], "reviewObservational": false })),
        )
        .await;
        assert_eq!(paired_preview.status().as_u16(), 200);
        assert_eq!(response_json(paired_preview).await["revision"], "preview-1");

        app.db
            .lock()
            .mirror_lease(
                &source.id,
                &Lease {
                    client_id: "phone".into(),
                    generation: 1,
                    expires_at: crate::util::now_ms() + 60_000,
                },
                "alice",
                false,
            )
            .unwrap();

        let stale_lease = call(
            &router,
            Method::POST,
            &format!("{base}/capture-1/recoveries"),
            Some("alice"),
            None,
            Some(json!({
                "version": 1,
                "key": "prepare-1",
                "previewRevision": "stale",
                "operations": [],
                "reviewObservational": false,
                "clientId": "phone",
                "generation": 2
            })),
        )
        .await;
        assert_eq!(stale_lease.status().as_u16(), 409);
        assert_eq!(node_requests.lock().unwrap().len(), 1);

        let successful_prepare = call(
            &router,
            Method::POST,
            &format!("{base}/capture-1/recoveries"),
            None,
            Some(&device_token),
            Some(json!({
                "version": 1,
                "key": "prepare-1",
                "previewRevision": "preview-1",
                "operations": [],
                "reviewObservational": false,
                "clientId": "phone",
                "generation": 1
            })),
        )
        .await;
        assert_eq!(successful_prepare.status().as_u16(), 201);
        let prepared = response_json(successful_prepare).await;
        assert_eq!(prepared["id"], "job-1");
        assert!(prepared["continuation"].is_null());

        let stale_preview = call(
            &router,
            Method::POST,
            &format!("{base}/capture-1/recoveries"),
            Some("alice"),
            None,
            Some(json!({
                "version": 1,
                "key": "prepare-2",
                "previewRevision": "stale",
                "operations": [],
                "reviewObservational": false,
                "clientId": "phone",
                "generation": 1
            })),
        )
        .await;
        assert_eq!(stale_preview.status().as_u16(), 409);
        assert_eq!(
            response_json(stale_preview).await["error"]["code"],
            "stale_preview"
        );

        let continue_body = json!({
            "revision": 1,
            "acceptUnresolved": false,
            "clientId": "phone",
            "generation": 1
        });
        let continued = call(
            &router,
            Method::POST,
            &format!("{base}/capture-1/recoveries/job-1/continue"),
            None,
            Some(&device_token),
            Some(continue_body.clone()),
        )
        .await;
        assert_eq!(continued.status().as_u16(), 200);
        let first = response_json(continued).await;
        assert_eq!(first["session"]["workspaceId"], "work:recovery-workspace");
        assert_eq!(
            first["job"]["continuation"]["sessionId"],
            first["session"]["id"]
        );
        assert_eq!(
            first["job"]["continuation"]["workspaceId"],
            "work:recovery-workspace"
        );

        let repeated = call(
            &router,
            Method::POST,
            &format!("{base}/capture-1/recoveries/job-1/continue"),
            None,
            Some(&device_token),
            Some(continue_body),
        )
        .await;
        assert_eq!(repeated.status().as_u16(), 200);
        let second = response_json(repeated).await;
        assert_eq!(second["session"]["id"], first["session"]["id"]);
        assert_eq!(
            app.db
                .lock()
                .query_row(
                    "SELECT COUNT(*) FROM sessions WHERE node_id='work' AND pi_session_id='new-session'",
                    [],
                    |row| row.get::<_, i64>(0),
                )
                .unwrap(),
            1
        );

        let listed = call(
            &router,
            Method::GET,
            &format!("{base}?cursor=123%3Acapture-older"),
            Some("alice"),
            None,
            None,
        )
        .await;
        assert_eq!(listed.status().as_u16(), 200);
        assert_eq!(listed.headers()["cache-control"], "no-store");
        let listed = response_json(listed).await;
        assert_eq!(listed["origin"]["sessionId"], source.id);
        assert_eq!(listed["origin"]["workspaceId"], "work:source-workspace");
        assert_eq!(
            listed["jobs"][0]["continuation"]["sessionId"],
            first["session"]["id"]
        );
        assert_eq!(
            listed["jobs"][0]["continuation"]["workspaceId"],
            "work:recovery-workspace"
        );
        assert_eq!(
            node_requests.lock().unwrap().last().unwrap().url,
            "/api/sessions/source-session/checkpoints?cursor=123%3Acapture-older"
        );

        let fetched_job = call(
            &router,
            Method::GET,
            &format!("{base}/capture-1/recoveries/job-1"),
            Some("alice"),
            None,
            None,
        )
        .await;
        assert_eq!(fetched_job.status().as_u16(), 200);
        let fetched_job = response_json(fetched_job).await;
        assert_eq!(
            fetched_job["continuation"]["sessionId"],
            first["session"]["id"]
        );
        assert_eq!(
            fetched_job["continuation"]["workspaceId"],
            "work:recovery-workspace"
        );

        let bob_workspaces = call(
            &router,
            Method::GET,
            "/api/workspaces",
            Some("bob"),
            None,
            None,
        )
        .await;
        let bob_workspaces = response_json(bob_workspaces).await;
        assert!(
            bob_workspaces["workspaces"]
                .as_array()
                .unwrap()
                .iter()
                .all(|workspace| workspace["id"] != "work:recovery-workspace")
        );
        assert!(
            bob_workspaces["workspaces"]
                .as_array()
                .unwrap()
                .iter()
                .all(|workspace| workspace["id"] != "work:orphan-recovery")
        );

        let bob_nodes = call(&router, Method::GET, "/api/nodes", Some("bob"), None, None).await;
        let bob_nodes = response_json(bob_nodes).await;
        assert!(
            bob_nodes["nodes"][0]["workspaces"]
                .as_array()
                .unwrap()
                .iter()
                .all(|workspace| workspace["id"] != "recovery-workspace")
        );
        assert!(
            bob_nodes["nodes"][0]["workspaces"]
                .as_array()
                .unwrap()
                .iter()
                .all(|workspace| workspace["id"] != "orphan-recovery")
        );

        assert_eq!(node_requests.lock().unwrap().len(), 7);

        let alice_workspaces = call(
            &router,
            Method::GET,
            "/api/workspaces",
            Some("alice"),
            None,
            None,
        )
        .await;
        let alice_workspaces = response_json(alice_workspaces).await;
        assert!(
            alice_workspaces["workspaces"]
                .as_array()
                .unwrap()
                .iter()
                .any(|workspace| workspace["id"] == "work:recovery-workspace")
        );
        assert!(
            alice_workspaces["workspaces"]
                .as_array()
                .unwrap()
                .iter()
                .all(|workspace| workspace["id"] != "work:orphan-recovery")
        );

        let alice_nodes = call(
            &router,
            Method::GET,
            "/api/nodes",
            Some("alice"),
            None,
            None,
        )
        .await;
        let alice_nodes = response_json(alice_nodes).await;
        assert!(
            alice_nodes["nodes"][0]["workspaces"]
                .as_array()
                .unwrap()
                .iter()
                .any(|workspace| workspace["id"] == "recovery-workspace")
        );
        assert!(
            alice_nodes["nodes"][0]["workspaces"]
                .as_array()
                .unwrap()
                .iter()
                .all(|workspace| workspace["id"] != "orphan-recovery")
        );
        for query in [
            "operation=op&side=before",
            "operation=op&side=after",
            "operation=op&side=current&job=job-1",
            "operation=op&side=candidate&job=job-1",
        ] {
            let reply = call(
                &router,
                Method::GET,
                &format!("{base}/capture-1/file?{query}"),
                Some("alice"),
                None,
                None,
            )
            .await;
            assert_eq!(reply.status().as_u16(), 200);
            assert_eq!(reply.headers()["cache-control"], "no-store");
        }
        for query in [
            "operation=op&side=current",
            "operation=op&side=before&job=",
            "operation=op&side=before&side=after",
        ] {
            let reply = call(
                &router,
                Method::GET,
                &format!("{base}/capture-1/file?{query}"),
                Some("alice"),
                None,
                None,
            )
            .await;
            assert_eq!(reply.status().as_u16(), 400);
            assert_eq!(reply.headers()["cache-control"], "no-store");
        }
        let unauthorized = call(
            &router,
            Method::GET,
            &format!("{base}/capture-1/file?operation=op&side=before"),
            None,
            None,
            None,
        )
        .await;
        assert_eq!(unauthorized.status().as_u16(), 401);
        assert_eq!(unauthorized.headers()["cache-control"], "no-store");
    }
}
