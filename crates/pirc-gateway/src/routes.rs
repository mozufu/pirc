//! The browser API's REST routes (`apps/gateway/src/daemon/app.ts`,
//! "browser API"): nodes, workspaces, sessions, control leases, commands,
//! interactions, uploads and the relayed side panel.
//!
//! Request bodies are checked like the TS zod schemas: unknown keys are
//! dropped unless the schema passed them through, and any mismatch is a 400
//! `invalid_input` before the route does anything else.

use axum::extract::{Extension, Path, State};
use axum::http::{HeaderMap, StatusCode, Uri, header};
use axum::response::{IntoResponse, Response};
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use pirc_protocol::{HttpMethod, Mode, NodeHttpRequest, RegisteredWorkspace};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

use crate::app::{AppState, Claimed, ReqBody, forward, query_map};
use crate::auth::Identity;
use crate::db::{CapabilitiesPatch, DeletionStatus, Lease, Store, atomic};
use crate::error::{ApiError, json_response};
use crate::http::{Body, no_content, ok};
use crate::node_events::run_name;
use crate::util::present;

/// A route's failure: an error, or a node's reply passed through as it is.
pub enum Fail {
    Api(ApiError),
    Reply(Box<Response>),
}

impl From<ApiError> for Fail {
    fn from(error: ApiError) -> Self {
        Self::Api(error)
    }
}

impl IntoResponse for Fail {
    fn into_response(self) -> Response {
        match self {
            Self::Api(error) => error.into_response(),
            Self::Reply(response) => *response,
        }
    }
}

pub type Handled = Result<Response, Fail>;

fn status(response: Response, code: u16) -> Response {
    let mut response = response;
    *response.status_mut() = StatusCode::from_u16(code).unwrap_or(StatusCode::OK);
    response
}

fn created(body: Value) -> Response {
    json_response(201, &body)
}

/// The node's own URL of a session (`/api/sessions/<piSessionId><rest>`).
fn node_url(claimed: &Claimed, rest: &str) -> String {
    format!(
        "/api/sessions/{}{rest}",
        urlencoding_component(&claimed.pi_session_id)
    )
}

/// `encodeURIComponent`.
pub fn urlencoding_component(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for byte in text.bytes() {
        if byte.is_ascii_alphanumeric() || b"-_.!~*'()".contains(&byte) {
            out.push(byte as char);
        } else {
            out.push_str(&format!("%{byte:02X}"));
        }
    }
    out
}

/// Relay and require success; a failure is passed through unchanged.
async fn expect_ok(
    app: &AppState,
    node_id: &str,
    identity: &Identity,
    method: HttpMethod,
    url: String,
    payload: Option<Value>,
) -> Result<Value, Fail> {
    let response = app.relay(node_id, identity, method, url, payload).await?;
    if response.status >= 400 {
        return Err(Fail::Reply(Box::new(forward(response))));
    }
    Ok(response
        .body
        .filter(|body| !body.is_null())
        .unwrap_or_else(|| json!({})))
}

/// `z.string().trim().min(1).max(n)`: the trimmed text.
fn trimmed(text: &str, max: usize) -> Result<String, ApiError> {
    let text = text.trim_matches(pirc_config::text::is_space);
    let length = text.encode_utf16().count();
    if length == 0 || length > max {
        return Err(ApiError::invalid_input());
    }
    Ok(text.to_owned())
}

fn length_within(text: &str, min: usize, max: usize) -> Result<(), ApiError> {
    let length = text.encode_utf16().count();
    if length < min || length > max {
        return Err(ApiError::invalid_input());
    }
    Ok(())
}

// ---- nodes and the assistant's node -----------------------------------------

pub async fn health(State(app): State<AppState>) -> Response {
    ok(json!({ "ok": true, "version": 2, "nodes": app.nodes.count() }))
}

pub async fn list_nodes(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
) -> Response {
    let mut nodes = json!(app.nodes.list());
    if let Some(nodes) = nodes.as_array_mut() {
        for node in nodes {
            let node_id = node["id"].as_str().unwrap_or_default().to_owned();
            if let Some(workspaces) = node["workspaces"].as_array_mut() {
                workspaces.retain(|workspace| {
                    let Some(local_id) = workspace["id"].as_str() else {
                        return false;
                    };
                    if crate::workspace_removal::completed(
                        &app.db.lock(),
                        &format!("{node_id}:{local_id}"),
                    )
                    .unwrap_or(true)
                    {
                        return false;
                    }
                    if workspace["checkpointPrivate"].as_bool() != Some(true) {
                        return true;
                    }
                    let Some(local_id) = workspace["id"].as_str() else {
                        return false;
                    };
                    app.db
                        .lock()
                        .checkpoint_workspace_visible_to_user(
                            &format!("{node_id}:{local_id}"),
                            &identity.user,
                        )
                        .unwrap_or(false)
                });
                for workspace in workspaces {
                    let mode = workspace["mode"]
                        .as_str()
                        .and_then(|id| pirc_protocol::ModeId::new(id).ok())
                        .and_then(|id| app.mode(&id));
                    workspace["available"] = json!(mode.is_some());
                    if let Some(mode) = mode {
                        workspace["kind"] = json!(match mode.workdir {
                            pirc_protocol::mode::Workdir::PerSession => "chat",
                            _ => "directory",
                        });
                    }
                }
            }
        }
    }
    ok(json!({ "nodes": nodes }))
}

fn assistant_node_id(app: &AppState) -> Result<String, ApiError> {
    let offline = || {
        ApiError::new(
            503,
            "node_offline",
            "The chat node is offline or not registered",
        )
    };
    let node_id = app.db.lock().assistant_node()?.ok_or_else(offline)?;
    match app.nodes.get(&node_id) {
        Some(node) if node.role == pirc_protocol::NodeRole::Chat => Ok(node_id),
        _ => Err(offline()),
    }
}

pub async fn assistant_node(State(app): State<AppState>) -> Handled {
    let node_id = app.db.lock().assistant_node()?;
    let online = node_id.as_deref().is_some_and(|id| {
        app.nodes
            .get(id)
            .is_some_and(|node| node.role == pirc_protocol::NodeRole::Chat)
    });
    Ok(ok(json!({ "nodeId": node_id, "online": online })))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct NodeIdBody {
    node_id: String,
}

pub async fn release_assistant_node(
    State(app): State<AppState>,
    ReqBody(body): ReqBody,
) -> Handled {
    let NodeIdBody { node_id } = body.parse()?;
    length_within(&node_id, 1, usize::MAX)?;
    if !app.db.lock().release_assistant_node(&node_id)? {
        return Err(ApiError::new(
            409,
            "binding_changed",
            "Chat node binding changed; refresh before releasing",
        )
        .into());
    }
    app.nodes.disconnect(&app, &node_id);
    app.directory_changed();
    Ok(ok(json!({ "nodeId": null, "online": false })))
}

pub async fn assistant_prompts(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
) -> Handled {
    let node_id = assistant_node_id(&app)?;
    let response = app
        .relay(
            &node_id,
            &identity,
            HttpMethod::Get,
            "/api/assistant/prompts".into(),
            None,
        )
        .await?;
    if response.status != 200 {
        return Ok(forward(response));
    }
    let mut body = match response.body {
        Some(Value::Object(body)) => body,
        _ => Map::new(),
    };
    body.insert("nodeId".into(), json!(node_id));
    Ok(ok(Value::Object(body)))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct PromptBody {
    text: String,
    node_id: String,
}

pub async fn save_assistant_prompt(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(name): Path<String>,
    ReqBody(body): ReqBody,
) -> Handled {
    if name != "soul" && name != "chat" {
        return Err(ApiError::invalid_input().into());
    }
    let PromptBody { text, node_id } = body.parse()?;
    length_within(&node_id, 1, usize::MAX)?;
    if app.db.lock().assistant_node()?.as_deref() != Some(node_id.as_str()) {
        return Err(ApiError::new(
            409,
            "binding_changed",
            "Chat node binding changed; refresh and review before saving",
        )
        .into());
    }
    let target = assistant_node_id(&app)?;
    let response = app
        .relay(
            &target,
            &identity,
            HttpMethod::Put,
            format!("/api/assistant/prompts/{name}"),
            Some(json!({ "text": text })),
        )
        .await?;
    Ok(forward(response))
}

// ---- workspaces ---------------------------------------------------------------

pub async fn list_modes(State(app): State<AppState>) -> Response {
    json_response(200, &json!({"modes":app.public_modes()}))
}

fn public_workspace(app: &AppState, workspace: &crate::db::Workspace) -> Value {
    let mode = app.mode(&workspace.mode);
    let mut value = json!(workspace);
    value["available"] = json!(mode.is_some());
    if let Some(mode) = mode {
        value["kind"] = json!(match mode.workdir {
            pirc_protocol::mode::Workdir::PerSession => "chat",
            _ => "directory",
        });
    }
    value
}

pub async fn list_workspaces(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
) -> Handled {
    let conn = app.db.lock();
    let mut workspaces: Vec<Value> = conn
        .list_workspaces_for_user(&identity.user)?
        .into_iter()
        .filter(|workspace| workspace.id.contains(':'))
        .map(|workspace| public_workspace(&app, &workspace))
        .collect();
    // A project whose deletion did not finish stays listed, for its owner to finish it.
    for workspace in conn.deleting_workspaces()? {
        if !conn.checkpoint_workspace_visible_to_user(&workspace.id, &identity.user)? {
            continue;
        }
        let owner = conn
            .workspace_deletion(&workspace.id)?
            .map(|d| d.owner_user);
        if owner.as_deref() == Some(identity.user.as_str()) {
            let mut item = public_workspace(&app, &workspace);
            item["deleting"] = json!(true);
            workspaces.push(item);
        }
    }
    Ok(ok(json!({ "workspaces": workspaces })))
}

/// Checkpoint workspaces are private, including before their owner has been
/// learned from an explicit continuation response.
pub fn require_workspace_visible(
    app: &AppState,
    identity: &Identity,
    workspace_id: &str,
) -> Result<(), ApiError> {
    if app
        .db
        .lock()
        .checkpoint_workspace_visible_to_user(workspace_id, &identity.user)?
    {
        Ok(())
    } else {
        Err(ApiError::not_found("Workspace not found"))
    }
}

pub async fn get_capabilities(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(workspace_id): Path<String>,
) -> Handled {
    require_workspace_visible(&app, &identity, &workspace_id)?;
    let capabilities = app.db.lock().get_workspace_capabilities(&workspace_id)?;
    Ok(ok(json!({ "capabilities": capabilities })))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct CapabilitiesBody {
    capabilities: CapabilitiesPatch,
}

pub async fn patch_capabilities(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(workspace_id): Path<String>,
    ReqBody(body): ReqBody,
) -> Handled {
    let CapabilitiesBody { capabilities } = body.parse()?;
    require_workspace_visible(&app, &identity, &workspace_id)?;
    let workspace = app.db.lock().get_workspace(&workspace_id)?;
    if !app.require_mode(&workspace)?.full_assistant() {
        return Err(ApiError::invalid_input().into());
    }
    let capabilities = app
        .db
        .lock()
        .patch_workspace_capabilities(&workspace_id, &capabilities)?;
    app.directory_changed();
    Ok(ok(json!({ "capabilities": capabilities })))
}

/// The workspaces a chat project is linked to (docs/architecture/assistant-memory.md).
pub async fn get_links(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(workspace_id): Path<String>,
) -> Handled {
    require_workspace_visible(&app, &identity, &workspace_id)?;
    let links = crate::project_links::project_links(&app.db.lock(), &app.catalog(), &workspace_id)?;
    Ok(ok(crate::project_links::view(&app, &links)?))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct LinksBody {
    workspace_ids: Vec<String>,
}

/// Replace a project's links: `delegate` and `memory_search` follow at once,
/// the workspace list of chats started from now on.
pub async fn put_links(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(workspace_id): Path<String>,
    ReqBody(body): ReqBody,
) -> Handled {
    let LinksBody { workspace_ids } = body.parse()?;
    if workspace_ids.len() > 4 * crate::project_links::MAX_LINKS {
        return Err(ApiError::new(400, "invalid_input", "Too many workspaces").into());
    }
    for id in &workspace_ids {
        length_within(id, 1, 300)?;
        require_workspace_visible(&app, &identity, id)?;
    }
    require_workspace_visible(&app, &identity, &workspace_id)?;
    let links = crate::project_links::set_links(
        &app.db.lock(),
        &app.catalog(),
        &workspace_id,
        &workspace_ids,
    )?;
    Ok(ok(crate::project_links::view(&app, &links)?))
}

/// A workspace resource the node keeps and the gateway relays.
#[derive(Clone, Copy)]
enum NodeResource {
    Instructions,
    Files,
    ProjectConfig,
}

impl NodeResource {
    fn allowed(self, mode: &Mode) -> bool {
        match self {
            Self::Instructions => mode.project_instructions,
            Self::Files => mode.project_files,
            Self::ProjectConfig => mode.project_config,
        }
    }

    fn refusal(self) -> &'static str {
        match self {
            Self::Instructions => "Only chat projects have instructions",
            Self::Files => "Only chat projects have project files",
            Self::ProjectConfig => "Only directory workspaces have a project config",
        }
    }
}

/// The node and node-local URL of a workspace's `rest`, if its mode has
/// `resource`.
fn workspace_on_node(
    app: &AppState,
    identity: &Identity,
    workspace_id: &str,
    resource: NodeResource,
    rest: &str,
) -> Result<(String, String), ApiError> {
    require_workspace_visible(app, identity, workspace_id)?;
    let workspace = app.db.lock().get_workspace(workspace_id)?;
    let local = match workspace.local_id() {
        Some(local)
            if app
                .mode(&workspace.mode)
                .is_some_and(|mode| resource.allowed(&mode)) =>
        {
            local.to_owned()
        }
        _ => {
            return Err(ApiError::new(400, "invalid_input", resource.refusal()));
        }
    };
    if app.nodes.get(&workspace.host_id).is_none() {
        return Err(ApiError::new(
            503,
            "node_offline",
            format!("{} is offline", workspace.host_id),
        ));
    }
    Ok((
        workspace.host_id,
        format!("/api/workspaces/{}{rest}", urlencoding_component(&local)),
    ))
}

/// A chat project's instructions: the node keeps them; the gateway relays.
pub async fn get_instructions(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(workspace_id): Path<String>,
) -> Handled {
    let (node_id, url) = workspace_on_node(
        &app,
        &identity,
        &workspace_id,
        NodeResource::Instructions,
        "/instructions",
    )?;
    Ok(forward(
        app.relay(&node_id, &identity, HttpMethod::Get, url, None)
            .await?,
    ))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct TextBody {
    text: String,
}

pub async fn patch_instructions(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(workspace_id): Path<String>,
    ReqBody(body): ReqBody,
) -> Handled {
    let (node_id, url) = workspace_on_node(
        &app,
        &identity,
        &workspace_id,
        NodeResource::Instructions,
        "/instructions",
    )?;
    let TextBody { text } = body.parse()?;
    length_within(&text, 0, 100_000)?;
    Ok(forward(
        app.relay(
            &node_id,
            &identity,
            HttpMethod::Patch,
            url,
            Some(json!({ "text": text })),
        )
        .await?,
    ))
}

/// A chat project's files: the node keeps them; the gateway relays.
pub async fn get_project_files(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(workspace_id): Path<String>,
) -> Handled {
    let (node_id, url) = workspace_on_node(
        &app,
        &identity,
        &workspace_id,
        NodeResource::Files,
        "/files",
    )?;
    Ok(forward(
        app.relay(&node_id, &identity, HttpMethod::Get, url, None)
            .await?,
    ))
}

/// The one non-empty value of `name` in the query.
fn query_value(uri: &Uri, name: &str) -> Result<String, ApiError> {
    match query_map(uri).get(name).map(Vec::as_slice) {
        Some([value]) => {
            length_within(value, 1, 1000)?;
            Ok(value.clone())
        }
        _ => Err(ApiError::invalid_input()),
    }
}

/// `POST /api/workspaces/:id/files?filename=…`, raw bytes: add or replace a
/// project file on the project's node.
pub async fn upload_project_file(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(workspace_id): Path<String>,
    uri: Uri,
    ReqBody(body): ReqBody,
) -> Handled {
    let filename = query_value(&uri, "filename")?;
    let (node_id, url) = workspace_on_node(
        &app,
        &identity,
        &workspace_id,
        NodeResource::Files,
        &format!("/files?filename={}", urlencoding_component(&filename)),
    )?;
    let Body::Raw {
        bytes,
        content_type,
    } = body
    else {
        return Err(ApiError::new(400, "invalid_input", "Upload body must be raw bytes").into());
    };
    if bytes.is_empty() || bytes.len() > app.config.upload_max_bytes {
        return Err(
            ApiError::new(413, "payload_too_large", "Upload exceeds configured limit").into(),
        );
    }
    let content_type = content_type
        .as_deref()
        .map(|value| value.split(';').next().unwrap_or_default().to_owned())
        .unwrap_or_else(|| "application/octet-stream".to_owned());
    let response = app
        .nodes
        .request(
            &node_id,
            NodeHttpRequest {
                method: HttpMethod::Post,
                url,
                user: identity.user.clone(),
                payload: None,
                body_base64: Some(STANDARD.encode(&bytes)),
                content_type: Some(content_type),
            },
        )
        .await?;
    Ok(forward(response))
}

/// `DELETE /api/workspaces/:id/files?name=…`.
pub async fn delete_project_file(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(workspace_id): Path<String>,
    uri: Uri,
) -> Handled {
    let name = query_value(&uri, "name")?;
    let (node_id, url) = workspace_on_node(
        &app,
        &identity,
        &workspace_id,
        NodeResource::Files,
        &format!("/files?name={}", urlencoding_component(&name)),
    )?;
    Ok(forward(
        app.relay(&node_id, &identity, HttpMethod::Delete, url, None)
            .await?,
    ))
}

pub async fn project_config(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(workspace_id): Path<String>,
) -> Handled {
    let (node_id, url) = workspace_on_node(
        &app,
        &identity,
        &workspace_id,
        NodeResource::ProjectConfig,
        "/project-config",
    )?;
    Ok(forward(
        app.relay(&node_id, &identity, HttpMethod::Get, url, None)
            .await?,
    ))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct TrustBody {
    trusted: bool,
    #[serde(default, deserialize_with = "present")]
    hash: Option<String>,
}

pub async fn project_trust(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(workspace_id): Path<String>,
    ReqBody(body): ReqBody,
) -> Handled {
    let (node_id, url) = workspace_on_node(
        &app,
        &identity,
        &workspace_id,
        NodeResource::ProjectConfig,
        "/project-trust",
    )?;
    let trust: TrustBody = body.parse()?;
    let payload = match (trust.trusted, trust.hash) {
        (true, Some(hash))
            if hash.len() == 64
                && hash
                    .bytes()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)) =>
        {
            json!({ "trusted": true, "hash": hash })
        }
        (false, None) => json!({ "trusted": false }),
        _ => return Err(ApiError::invalid_input().into()),
    };
    Ok(forward(
        app.relay(&node_id, &identity, HttpMethod::Post, url, Some(payload))
            .await?,
    ))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CreateWorkspace {
    node_id: String,
    #[serde(default, deserialize_with = "present")]
    kind: Option<String>,
    #[serde(default)]
    mode: Option<pirc_protocol::mode::ModeId>,
    #[serde(default, deserialize_with = "present")]
    path: Option<String>,
    display_name: String,
}

pub async fn create_workspace(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    ReqBody(body): ReqBody,
) -> Handled {
    let input: CreateWorkspace = body.parse()?;
    if !pirc_config::valid_node_id(&input.node_id) {
        return Err(ApiError::invalid_input().into());
    }
    let display_name = trimmed(&input.display_name, 200)?;
    let node = app
        .nodes
        .get(&input.node_id)
        .ok_or_else(|| ApiError::new(503, "node_offline", "Node is offline"))?;
    if let (Some(mode), Some(kind)) = (&input.mode, &input.kind)
        && mode.as_str() != kind
    {
        return Err(ApiError::invalid_input().into());
    }
    if input.mode.is_none() && input.kind.is_none() && input.path.is_none() {
        return Err(ApiError::invalid_input().into());
    }
    // Legacy path-only creation remains a directory request on either role.
    let mode_id = input.mode.unwrap_or(
        pirc_protocol::mode::ModeId::new(input.kind.as_deref().unwrap_or("directory"))
            .map_err(|_| ApiError::invalid_input())?,
    );
    if !node.modes.contains(&mode_id) {
        return Err(ApiError::new(403, "forbidden", "Mode is not accepted by this node").into());
    }
    let mode = app.mode(&mode_id).ok_or_else(|| {
        ApiError::new(
            409,
            "mode_unavailable",
            "Requested workspace mode is unavailable",
        )
    })?;
    let payload = match mode.workdir {
        pirc_protocol::mode::Workdir::PerSession => {
            json!({"mode":mode_id, "displayName":display_name})
        }
        _ => {
            json!({"mode":mode_id, "path":trimmed(input.path.as_deref().ok_or_else(ApiError::invalid_input)?,4096)?, "displayName":display_name, "restoreExisting":true})
        }
    };
    let node_id = input.node_id;
    if app.nodes.get(&node_id).is_none() {
        return Err(ApiError::new(503, "node_offline", "Node is offline").into());
    }
    let remote = expect_ok(
        &app,
        &node_id,
        &identity,
        HttpMethod::Post,
        "/api/workspaces".into(),
        Some(payload),
    )
    .await?;
    let mut workspace: RegisteredWorkspace = serde_json::from_value(remote["workspace"].clone())
        .map_err(|_| ApiError::new(502, "node_error", "Node answered an invalid workspace"))?;
    if !mode.repository {
        workspace.repo = None;
    }
    let mut raw = remote["workspace"].clone();
    if !mode.repository
        && let Some(object) = raw.as_object_mut()
    {
        object.remove("repo");
    }
    if workspace.repo.is_some() {
        crate::nodes::sanitize_repo(&mut workspace);
        if workspace.repo.is_none()
            && let Some(object) = raw.as_object_mut()
        {
            object.remove("repo");
        }
    }
    // A lost acknowledgement is reconciled when the node registers again.
    if workspace.mode != mode_id {
        return Err(ApiError::new(
            502,
            "node_error",
            "Node answered a different workspace mode",
        )
        .into());
    }
    let mode = workspace.mode.clone();
    {
        let conn = app.db.lock();
        let id = format!("{node_id}:{}", workspace.id);
        if conn.find_workspace(&id)?.is_some() && !crate::workspace_removal::removed(&conn, &id)? {
            return Err(ApiError::new(
                409,
                "conflict",
                "Workspace ID or path is already registered",
            )
            .into());
        }
        atomic(&conn, |conn| {
            crate::workspace_removal::restore(conn, &id, &identity.user)?;
            conn.sync_remote_workspaces(
                &node_id,
                &[(workspace.id.clone(), workspace.display_name.clone(), mode)],
            )?;
            conn.set_workspace_repos(&node_id, &[(workspace.id.clone(), workspace.repo.clone())])
        })?;
    }
    let local_id = workspace.id.clone();
    app.nodes.add_workspace(&node_id, workspace, raw)?;
    app.directory_changed();
    app.sessions_changed(Some(&identity.user));
    app.schedules_changed(&identity.user);
    let stored = app
        .db
        .lock()
        .get_workspace(&format!("{node_id}:{local_id}"))?;
    Ok(created(
        json!({ "workspace": public_workspace(&app, &stored) }),
    ))
}

// ---- sessions -------------------------------------------------------------------

pub async fn list_sessions(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
) -> Handled {
    let user = identity.user.as_str();
    let (sessions, origins) = {
        let conn = app.db.lock();
        (conn.list_sessions()?, conn.session_origins(user)?)
    };
    // The newest origin of a session wins, as in the TS map.
    let origins: std::collections::HashMap<_, _> = origins.into_iter().collect();
    let sessions: Vec<Value> = sessions
        .into_iter()
        .filter(|session| session.node_id.is_some() && session.owner_user.as_deref() == Some(user))
        .map(|session| {
            let live = app.activity_of(session.node_id.as_deref(), &session.id);
            let mut public = session.public();
            // The node reports open runs; the gateway's own table only has finished ones.
            if let Some(run) = live.and_then(|live| live.run) {
                public["runStatus"] = json!(run_name(run));
            }
            if live.is_some_and(|live| live.write_lease) {
                public["writeLease"] = json!(true);
            }
            if let Some(origin) = origins.get(&session.id) {
                public["origin"] = json!(origin);
                // A delegated session's approval, answerable from Needs you.
                if let crate::db::SessionOrigin::Delegation { delegation_id, .. } = origin
                    && let Some(approval) =
                        crate::delegations::pending_approval(&app, delegation_id)
                {
                    public["origin"]["approval"] = approval;
                }
            }
            public
        })
        .collect();
    Ok(ok(json!({ "sessions": sessions })))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CreateSession {
    workspace_id: String,
}

pub async fn create_session(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    ReqBody(body): ReqBody,
) -> Handled {
    let CreateSession { workspace_id } = body.parse()?;
    length_within(&workspace_id, 1, usize::MAX)?;
    require_workspace_visible(&app, &identity, &workspace_id)?;
    let workspace = app.db.lock().get_workspace(&workspace_id)?;
    app.require_mode(&workspace)?;
    let node_id = workspace.host_id.clone();
    let online = app.nodes.get(&node_id).is_some_and(|node| {
        node.workspaces
            .iter()
            .any(|w| format!("{node_id}:{}", w.id) == workspace.id)
    });
    if !online {
        return Err(ApiError::new(503, "node_offline", "Node or workspace is offline").into());
    }
    let local = workspace.id[node_id.len() + 1..].to_owned();
    let remote = expect_ok(
        &app,
        &node_id,
        &identity,
        HttpMethod::Post,
        "/api/sessions".into(),
        Some(json!({ "workspaceId": local })),
    )
    .await?;
    let remote_id = match &remote["session"]["id"] {
        Value::String(id) => id.clone(),
        Value::Number(id) => id.to_string(),
        _ => {
            crate::log::error("node answered a session without an id");
            return Err(ApiError::internal().into());
        }
    };
    let session = app.db.lock().create_session(
        &workspace.id,
        &format!("node://{node_id}/{remote_id}"),
        &node_id,
        &remote_id,
        &identity.user,
    )?;
    Ok(created(json!({ "session": session })))
}

pub async fn delete_session(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(session_id): Path<String>,
) -> Handled {
    if let Some(response) =
        crate::conversation_submissions::try_delete(&app, &identity, &session_id).await?
    {
        return Ok(response);
    }
    let user = identity.user.as_str();
    let session = {
        let conn = app.db.lock();
        let deletion = conn.session_deletion(&session_id)?;
        if let Some(deletion) = &deletion {
            if deletion.owner_user != user {
                return Err(ApiError::new(403, "forbidden", "Chat belongs to another user").into());
            }
            if deletion.status == DeletionStatus::Deleted {
                return Ok(no_content());
            }
        }
        let session = conn.claim_session(&session_id, user, true)?;
        if !app
            .require_mode(&conn.get_workspace(&session.workspace_id)?)?
            .delete_sessions
        {
            return Err(ApiError::new(400, "invalid_input", "Only chats can be deleted").into());
        }
        session
    };
    let (Some(node_id), Some(pi_session_id)) =
        (session.node_id.clone(), session.pi_session_id.clone())
    else {
        return Err(offline_chat_node().into());
    };
    if app.nodes.get(&node_id).is_none() {
        return Err(offline_chat_node().into());
    }
    // Persist intent before the remote call: delayed agent operations cannot add memory.
    app.db.lock().begin_session_deletion(&session_id, user)?;
    let claimed = Claimed {
        session: session.clone(),
        node_id: node_id.clone(),
        pi_session_id,
    };
    let response = app
        .relay(
            &node_id,
            &identity,
            HttpMethod::Delete,
            node_url(&claimed, ""),
            None,
        )
        .await?;
    if response.status >= 400 {
        return Ok(forward(response));
    }
    {
        let conn = app.db.lock();
        atomic(&conn, |conn| {
            app.forget_session_memory(conn, user, &session_id)?;
            conn.finish_session_deletion(&session_id)
        })?;
    }
    app.memory_changed(user);
    app.events.publish(
        &session_id,
        session.runner_epoch,
        "session_deleted",
        json!({ "sessionId": session_id }),
    );
    app.events.forget(&session_id);
    app.sessions_changed(Some(user));
    app.schedules_changed(user);
    Ok(no_content())
}

fn offline_chat_node() -> ApiError {
    ApiError::new(
        503,
        "node_offline",
        "Connect the chat node before deleting this chat",
    )
}

#[derive(Deserialize)]
struct UpdateSession {
    #[serde(default, deserialize_with = "present")]
    name: Option<String>,
    #[serde(default, deserialize_with = "present")]
    pinned: Option<bool>,
    #[serde(default, deserialize_with = "present")]
    settled: Option<bool>,
}

/// Rename, pin and settle, in any combination. Only a rename reaches the node.
pub async fn update_session(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(session_id): Path<String>,
    ReqBody(body): ReqBody,
) -> Handled {
    let claimed = app.claim(&identity, &session_id)?;
    app.require_writable(&claimed.session)?;
    let update: UpdateSession = body.parse()?;
    let name = update
        .name
        .as_deref()
        .map(|name| trimmed(name, 200))
        .transpose()?;
    if name.is_none() && update.pinned.is_none() && update.settled.is_none() {
        return Err(ApiError::invalid_input().into());
    }
    if let Some(name) = name {
        expect_ok(
            &app,
            &claimed.node_id,
            &identity,
            HttpMethod::Patch,
            node_url(&claimed, ""),
            Some(json!({ "name": name })),
        )
        .await?;
        let mut data = Map::new();
        data.insert("name".into(), json!(name));
        data.insert("source".into(), json!("user"));
        app.apply_session_name(&claimed.session.id, claimed.session.runner_epoch, &data);
    }
    let conn = app.db.lock();
    if update.pinned.is_some() || update.settled.is_some() {
        conn.set_session_flags(&claimed.session.id, update.pinned, update.settled)?;
    }
    Ok(ok(
        json!({ "session": conn.get_session(&claimed.session.id)? }),
    ))
}

/// The user has read the session: its unread mark clears on every device.
pub async fn read_session(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(session_id): Path<String>,
) -> Handled {
    let claimed = app.claim(&identity, &session_id)?;
    if app.db.lock().mark_session_read(&claimed.session.id)? {
        app.sessions_changed(claimed.session.owner_user.as_deref());
    }
    let session = app.db.lock().get_session(&claimed.session.id)?;
    Ok(ok(json!({ "session": session })))
}

pub async fn snapshot(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(session_id): Path<String>,
) -> Handled {
    let claimed = app.claim(&identity, &session_id)?;
    let remote = expect_ok(
        &app,
        &claimed.node_id,
        &identity,
        HttpMethod::Get,
        node_url(&claimed, "/snapshot"),
        None,
    )
    .await?;
    let mut body = match remote {
        Value::Object(body) => body,
        _ => Map::new(),
    };
    // Node sequence numbers are not the gateway's: the browser resumes from ours.
    let mut session = claimed.session.public();
    let runner_state = body
        .get("session")
        .and_then(|session| session.get("runnerState"))
        .cloned();
    match runner_state {
        Some(state) => session["runnerState"] = state,
        None => {
            if let Some(object) = session.as_object_mut() {
                object.shift_remove("runnerState");
            }
        }
    }
    body.insert("session".into(), session);
    // Confirmations the gateway itself asks for (delegations, schedules, memory).
    let mut interactions = match body.get("interactions") {
        Some(Value::Array(items)) => items.clone(),
        _ => Vec::new(),
    };
    interactions.extend(app.pending_gateway_interactions(&claimed.session.id, &identity.user));
    body.insert("interactions".into(), Value::Array(interactions));
    // The delegations it started that still run (with Stop).
    body.insert(
        "delegations".into(),
        crate::delegations::active(&app, &claimed.session.id),
    );
    body.insert(
        "watermark".into(),
        json!(
            app.events
                .watermark(&claimed.session.id, claimed.session.runner_epoch)
        ),
    );
    Ok(ok(Value::Object(body)))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CommandBody {
    #[serde(default)]
    expected_binding: Option<crate::conversation_bindings::Binding>,
    command_id: String,
    client_id: String,
    generation: u64,
    payload: Map<String, Value>,
}

/// Keys a command payload may have (the node's `commandPayload` union).
const COMMAND_KEYS: [&str; 10] = [
    "type",
    "message",
    "uploadIds",
    "entryId",
    "queue",
    "index",
    "provider",
    "modelId",
    "level",
    "mode",
];
/// `message` limit, in UTF-16 units, as the node's.
const COMMAND_MESSAGE_MAX: usize = 1_000_000;
/// Uploads per message, as the node's.
const COMMAND_UPLOADS_MAX: usize = 16;
/// Any other string in a payload (type, IDs, model names).
const COMMAND_STRING_MAX: usize = 1_000;

/// The payload as stored and forwarded: unknown keys dropped (the node's
/// schema drops them too) and every value bounded, so a command row is
/// never larger than a prompt (security audit L8). The node still checks
/// the payload's shape.
fn command_payload(mut payload: Map<String, Value>) -> Result<Map<String, Value>, ApiError> {
    payload.retain(|key, _| COMMAND_KEYS.contains(&key.as_str()));
    for (key, value) in &payload {
        match (key.as_str(), value) {
            ("message", Value::String(text)) => length_within(text, 0, COMMAND_MESSAGE_MAX)?,
            ("uploadIds", Value::Array(ids)) => {
                if ids.len() > COMMAND_UPLOADS_MAX {
                    return Err(ApiError::invalid_input());
                }
                for id in ids {
                    let Value::String(id) = id else {
                        return Err(ApiError::invalid_input());
                    };
                    length_within(id, 0, COMMAND_STRING_MAX)?;
                }
            }
            (_, Value::String(text)) => length_within(text, 0, COMMAND_STRING_MAX)?,
            (_, Value::Number(_) | Value::Bool(_) | Value::Null) => {}
            _ => return Err(ApiError::invalid_input()),
        }
    }
    Ok(payload)
}

pub async fn command(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(session_id): Path<String>,
    ReqBody(body): ReqBody,
) -> Handled {
    let claimed = app.claim(&identity, &session_id)?;
    let input: CommandBody = body.parse()?;
    length_within(&input.command_id, 1, 200)?;
    length_within(&input.client_id, 1, usize::MAX)?;
    if input.generation == 0 || !input.payload.get("type").is_some_and(Value::is_string) {
        return Err(ApiError::invalid_input().into());
    }
    let session_id = claimed.session.id.as_str();
    let payload = Value::Object(command_payload(input.payload)?);
    if payload["type"] != "stop" {
        app.require_writable(&claimed.session)?;
        crate::conversation_submissions::require_initial_submission_complete(
            &app.db.lock(),
            session_id,
        )?;
    }
    let (command, duplicate) = {
        let conn = app.db.lock();
        atomic(&conn, |tx| {
            tx.validate_lease(session_id, &input.client_id, input.generation as i64)?;
            tx.validate_lease_user(session_id, &identity.user)?;
            let received = crate::conversation_bindings::commands::receive(
                tx,
                &claimed.session,
                &identity.user,
                &input.command_id,
                &payload,
                input.expected_binding.as_ref(),
            )?;
            if !received.1 && payload["type"] == "stop" {
                crate::conversation_submissions::note_stop(tx, session_id, &identity.user)?;
            }
            Ok(received)
        })?
    };
    if duplicate {
        return Ok(ok(json!({ "command": command, "duplicate": true })));
    }
    if app.nodes.get(&claimed.node_id).is_none() {
        app.db.lock().update_command(
            &input.command_id,
            "rejected",
            None,
            Some("Node is offline"),
        )?;
        return Err(ApiError::new(503, "node_offline", "Node is offline").into());
    }
    let versioned = input.expected_binding.is_some() && payload["type"] != "stop";
    let connection = if versioned {
        match crate::conversation_bindings::commands::supported(
            &app,
            &claimed.node_id,
            &identity.user,
        )
        .await
        {
            Ok(connection) => Some(connection),
            Err(error) => {
                app.db.lock().update_command(
                    &input.command_id,
                    "rejected",
                    None,
                    Some(&error.message),
                )?;
                return Err(error.into());
            }
        }
    } else {
        None
    };
    let ready = atomic(&app.db.lock(), |tx| {
        let current = tx.claim_session(session_id, &identity.user, false)?;
        tx.validate_lease(session_id, &input.client_id, input.generation as i64)?;
        tx.validate_lease_user(session_id, &identity.user)?;
        if current.binding != claimed.session.binding {
            return Err(ApiError::new(
                409,
                "stale_environment",
                "The conversation environment changed; refresh it before starting this action",
            ));
        }
        if payload["type"] != "stop" {
            crate::conversation_bindings::transitions::require_open(tx, session_id)?;
        }
        tx.update_command(&input.command_id, "dispatched", None, None)
    });
    if let Err(error) = ready {
        app.db
            .lock()
            .update_command(&input.command_id, "rejected", None, Some(&error.message))?;
        return Err(error.into());
    }
    let mut forwarded = json!({
        "commandId": input.command_id,
        "clientId": input.client_id,
        "generation": input.generation,
        "payload": payload,
    });
    if versioned {
        forwarded["commandEnvironment"] =
            serde_json::to_value(&claimed.session.binding).map_err(|_| ApiError::internal())?;
    }
    let remote = if let Some(connection) = connection {
        app.nodes
            .request_on(
                &claimed.node_id,
                connection,
                pirc_protocol::NodeHttpRequest {
                    method: HttpMethod::Post,
                    url: node_url(&claimed, "/commands"),
                    user: identity.user.clone(),
                    payload: Some(forwarded),
                    body_base64: None,
                    content_type: None,
                },
            )
            .await
    } else {
        app.relay(
            &claimed.node_id,
            &identity,
            HttpMethod::Post,
            node_url(&claimed, "/commands"),
            Some(forwarded),
        )
        .await
    };
    match remote {
        Err(error) => {
            app.db.lock().update_command(
                &input.command_id,
                "outcome_unknown",
                None,
                Some(&error.message),
            )?;
            let command = app.db.lock().get_command(&input.command_id)?;
            return Ok(json_response(
                503,
                &json!({ "command": command, "duplicate": false }),
            ));
        }
        Ok(remote) => {
            if payload["type"] == "stop"
                && let Some(body) = &remote.body
            {
                crate::conversation_submissions::observe_stop(&app, &identity, session_id, body)?;
            }
            let remote_command = remote
                .body
                .as_ref()
                .and_then(|body| body.get("command"))
                .filter(|command| !command.is_null())
                .cloned();
            match remote_command {
                None if remote.status >= 400 => {
                    let message = remote
                        .body
                        .as_ref()
                        .and_then(|body| body["error"]["message"].as_str())
                        .unwrap_or("Node rejected the command")
                        .to_owned();
                    app.db.lock().update_command(
                        &input.command_id,
                        "rejected",
                        None,
                        Some(&message),
                    )?;
                    return Ok(forward(remote));
                }
                command => {
                    let command = command.unwrap_or(Value::Null);
                    let status = command["status"].as_str().unwrap_or("outcome_unknown");
                    let result = command.get("result").filter(|result| !result.is_null());
                    let error = command["error"].as_str();
                    app.db
                        .lock()
                        .update_command(&input.command_id, status, result, error)?;
                }
            }
        }
    }
    let command = app.db.lock().get_command(&input.command_id)?;
    let code = if command.status == "accepted" {
        202
    } else {
        503
    };
    Ok(json_response(
        code,
        &json!({ "command": command, "duplicate": false }),
    ))
}

pub async fn command_receipt(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path((session, id)): Path<(String, String)>,
) -> Handled {
    let (session, command) = {
        let db = app.db.lock();
        let session = db.get_session(&session)?;
        if session.owner_user.as_deref() != Some(identity.user.as_str()) {
            return Err(ApiError::not_found("Command not found").into());
        }
        if db.session_deletion(&session.id)?.is_some() {
            return Err(ApiError::not_found("Command not found").into());
        }
        let command = db.get_command(&id)?;
        if command.session_id != session.id {
            return Err(ApiError::not_found("Command not found").into());
        }
        (session, command)
    };
    refresh_command_receipt(&app, &identity, &session, &command).await?;
    let db = app.db.lock();
    if db.session_deletion(&session.id)?.is_some() {
        return Err(ApiError::not_found("Command not found").into());
    }
    let command = db.get_command(&id)?;
    Ok(ok(json!({"command":command})))
}

/// Read-only reconciliation: no runner start, command replay or lease mutation.
async fn refresh_command_receipt(
    app: &AppState,
    identity: &Identity,
    session: &crate::db::Session,
    command: &crate::db::Command,
) -> Result<(), ApiError> {
    if !matches!(
        command.status.as_str(),
        "received" | "dispatched" | "outcome_unknown"
    ) {
        return Ok(());
    }
    let (Some(node), Some(remote)) = (&session.node_id, &session.pi_session_id) else {
        return Ok(());
    };
    let Ok(response) = app
        .relay(
            node,
            identity,
            HttpMethod::Get,
            format!("/api/sessions/{remote}/commands/{}", command.id),
            None,
        )
        .await
    else {
        return Ok(());
    };
    if response.status >= 400 {
        return Ok(());
    }
    let Some(receipt) = response.body.as_ref().and_then(|v| v.get("command")) else {
        return Ok(());
    };
    if receipt["id"] != command.id
        || receipt["sessionId"] != *remote
        || receipt["payloadHash"] != command.payload_hash
    {
        return Ok(());
    }
    let Some(status @ ("received" | "dispatched" | "accepted" | "rejected" | "outcome_unknown")) =
        receipt["status"].as_str()
    else {
        return Ok(());
    };
    let db = app.db.lock();
    if db.session_deletion(&session.id)?.is_none()
        && db.get_command(&command.id)?.status != "accepted"
    {
        db.update_command(
            &command.id,
            status,
            receipt.get("result"),
            receipt["error"].as_str(),
        )?;
    }
    Ok(())
}

pub async fn control(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(session_id): Path<String>,
) -> Handled {
    let claimed = app.claim(&identity, &session_id)?;
    let lease = app.db.lock().get_lease(&claimed.session.id)?;
    Ok(ok(json!({ "lease": lease })))
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct LeaseBody {
    client_id: String,
    #[serde(
        default,
        deserialize_with = "present",
        skip_serializing_if = "Option::is_none"
    )]
    generation: Option<u64>,
    #[serde(
        default,
        deserialize_with = "present",
        skip_serializing_if = "Option::is_none"
    )]
    force: Option<bool>,
}

impl LeaseBody {
    fn parse(body: &Body, held: bool) -> Result<Self, ApiError> {
        let lease: Self = body.parse()?;
        length_within(&lease.client_id, 1, 200)?;
        if held && !lease.generation.is_some_and(|generation| generation > 0) {
            return Err(ApiError::invalid_input());
        }
        Ok(lease)
    }

    fn generation(&self) -> i64 {
        self.generation.unwrap_or(0) as i64
    }
}

/// The node's lease from its answer.
fn remote_lease(remote: &Value) -> Result<Lease, ApiError> {
    serde_json::from_value(remote["lease"].clone())
        .map_err(|_| ApiError::new(502, "node_error", "Node answered an invalid lease"))
}

pub async fn acquire(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(session_id): Path<String>,
    ReqBody(body): ReqBody,
) -> Handled {
    let claimed = app.claim(&identity, &session_id)?;
    app.require_writable(&claimed.session)?;
    let lease = LeaseBody::parse(&body, false)?;
    let force = lease.force.unwrap_or(false);
    app.db
        .lock()
        .check_lease_user(&claimed.session.id, &identity.user, force)?;
    let remote = expect_ok(
        &app,
        &claimed.node_id,
        &identity,
        HttpMethod::Post,
        node_url(&claimed, "/control/acquire"),
        Some(json!(lease)),
    )
    .await?;
    app.db.lock().mirror_lease(
        &claimed.session.id,
        &remote_lease(&remote)?,
        &identity.user,
        force,
    )?;
    Ok(ok(remote))
}

pub async fn heartbeat(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(session_id): Path<String>,
    ReqBody(body): ReqBody,
) -> Handled {
    let claimed = app.claim(&identity, &session_id)?;
    let lease = LeaseBody::parse(&body, true)?;
    {
        let conn = app.db.lock();
        conn.validate_lease_user(&claimed.session.id, &identity.user)?;
        conn.validate_lease(&claimed.session.id, &lease.client_id, lease.generation())?;
    }
    let remote = expect_ok(
        &app,
        &claimed.node_id,
        &identity,
        HttpMethod::Post,
        node_url(&claimed, "/control/heartbeat"),
        Some(json!(lease)),
    )
    .await?;
    app.db.lock().mirror_lease(
        &claimed.session.id,
        &remote_lease(&remote)?,
        &identity.user,
        false,
    )?;
    Ok(ok(remote))
}

pub async fn release(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(session_id): Path<String>,
    ReqBody(body): ReqBody,
) -> Handled {
    let claimed = app.claim(&identity, &session_id)?;
    let lease = LeaseBody::parse(&body, true)?;
    {
        let conn = app.db.lock();
        conn.validate_lease_user(&claimed.session.id, &identity.user)?;
        conn.validate_lease(&claimed.session.id, &lease.client_id, lease.generation())?;
    }
    expect_ok(
        &app,
        &claimed.node_id,
        &identity,
        HttpMethod::Post,
        node_url(&claimed, "/control/release"),
        Some(json!(lease)),
    )
    .await?;
    app.db.lock().clear_remote_lease(&claimed.session.id)?;
    Ok(no_content())
}

pub async fn answer(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path((session_id, interaction_id)): Path<(String, String)>,
    ReqBody(body): ReqBody,
) -> Handled {
    let claimed = app.claim(&identity, &session_id)?;
    app.require_writable(&claimed.session)?;
    // A delegated session's dialog relayed to this chat: the owner answers
    // it without holding a control lease (docs/architecture/security-decisions.md).
    if interaction_id.starts_with(crate::delegations::RELAY_PREFIX) {
        let given = body.json().and_then(|body| body.get("answer")).cloned();
        if let Some(answer) = crate::delegations::answer_relayed(
            &app,
            &claimed.session.id,
            &interaction_id,
            &identity.user,
            given.as_ref(),
        )
        .await?
        {
            return Ok(ok(answer));
        }
    }
    // `answerBody`: a client and a held generation; the rest passes through.
    let (client_id, generation) = match body.json() {
        Some(Value::Object(answer)) => match (&answer.get("clientId"), &answer.get("generation")) {
            (Some(Value::String(client)), Some(Value::Number(generation)))
                if !client.is_empty() && generation.as_u64().is_some_and(|g| g > 0) =>
            {
                (client.clone(), generation.as_u64().unwrap_or(0) as i64)
            }
            _ => return Err(ApiError::invalid_input().into()),
        },
        _ => return Err(ApiError::invalid_input().into()),
    };
    let session_id = claimed.session.id.as_str();
    {
        let conn = app.db.lock();
        conn.validate_lease(session_id, &client_id, generation)?;
        conn.validate_lease_user(session_id, &identity.user)?;
    }
    let given = body.json().and_then(|body| body.get("answer")).cloned();
    // The gateway's own confirmations are answered here; the node never saw them.
    if let Some(answer) = crate::features::answer_gateway_interaction(
        &app,
        session_id,
        &interaction_id,
        &identity.user,
        given,
    )? {
        return Ok(ok(answer));
    }
    Ok(forward(
        app.relay(
            &claimed.node_id,
            &identity,
            HttpMethod::Post,
            node_url(
                &claimed,
                &format!(
                    "/interactions/{}/answer",
                    urlencoding_component(&interaction_id)
                ),
            ),
            body.json().cloned(),
        )
        .await?,
    ))
}

/// Images and other files are stored on the session's node, where its agent reads them.
pub async fn upload(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(session_id): Path<String>,
    uri: Uri,
    ReqBody(body): ReqBody,
) -> Handled {
    let claimed = app.claim(&identity, &session_id)?;
    app.require_writable(&claimed.session)?;
    let Body::Raw {
        bytes,
        content_type,
    } = body
    else {
        return Err(ApiError::new(400, "invalid_input", "Upload body must be raw bytes").into());
    };
    if bytes.is_empty() || bytes.len() > app.config.upload_max_bytes {
        return Err(
            ApiError::new(413, "payload_too_large", "Upload exceeds configured limit").into(),
        );
    }
    let query = query_map(&uri);
    let suffix = match query.get("filename").and_then(|values| values.first()) {
        Some(filename) if !filename.is_empty() => {
            format!("?filename={}", urlencoding_component(filename))
        }
        _ => String::new(),
    };
    let content_type = content_type
        .as_deref()
        .map(|value| value.split(';').next().unwrap_or_default().to_owned())
        .unwrap_or_else(|| "application/octet-stream".to_owned());
    let response = app
        .nodes
        .request(
            &claimed.node_id,
            NodeHttpRequest {
                method: HttpMethod::Post,
                url: node_url(&claimed, &format!("/uploads{suffix}")),
                user: identity.user.clone(),
                payload: None,
                body_base64: Some(STANDARD.encode(&bytes)),
                content_type: Some(content_type),
            },
        )
        .await?;
    Ok(forward(response))
}

/// Every node's agents use the gateway's providers, so one list serves all sessions.
pub async fn list_models(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    uri: Uri,
) -> Handled {
    let query = query_map(&uri);
    match query.get("sessionId").map(Vec::as_slice) {
        None => {}
        Some([session_id]) => {
            if !session_id.is_empty() {
                app.claim(&identity, session_id)?;
            }
        }
        Some(_) => return Err(ApiError::invalid_input().into()),
    }
    Ok(ok(
        json!({ "models": pirc_providers::list_models(&app.models()) }),
    ))
}

// ---- side panel, terminals and recordings: relayed verbatim -----------------------

/// Session sub-paths relayed to the node (read-only side panel, terminal
/// REST); anything else under a session is refused.
fn relayed_get(rest: &str) -> bool {
    let segment = |text: &str| !text.is_empty() && !text.contains(['/', '?']);
    let hex =
        |text: &str| (4..=64).contains(&text.len()) && text.bytes().all(|b| b.is_ascii_hexdigit());
    matches!(
        rest,
        "git/status"
            | "git/diff"
            | "git/log"
            | "files"
            | "files/content"
            | "panel/state"
            | "panel/context"
            | "terminals"
    ) || rest.strip_prefix("git/commits/").is_some_and(hex)
        || rest.strip_prefix("panel/background/").is_some_and(segment)
}

fn relayed_post(rest: &str) -> bool {
    let segment = |text: &str| !text.is_empty() && !text.contains(['/', '?']);
    rest == "terminals"
        || rest
            .strip_prefix("terminals/")
            .and_then(|rest| rest.strip_suffix("/close"))
            .is_some_and(segment)
        || rest
            .strip_prefix("panel/background/")
            .and_then(|rest| rest.strip_suffix("/stop"))
            .is_some_and(segment)
}

/// The raw path after `/api/sessions/<id>/`.
fn rest_of(uri: &Uri) -> String {
    uri.path().split('/').skip(4).collect::<Vec<_>>().join("/")
}

async fn relay_panel(
    app: AppState,
    identity: Identity,
    session_id: String,
    uri: Uri,
    method: HttpMethod,
    body: Option<Body>,
) -> Handled {
    let claimed = app.claim(&identity, &session_id)?;
    if method != HttpMethod::Get {
        app.require_writable(&claimed.session)?;
    }
    let rest = rest_of(&uri);
    let allowed = if method == HttpMethod::Get {
        relayed_get(&rest)
    } else {
        relayed_post(&rest)
    };
    if !allowed {
        return Err(ApiError::not_found("Route not found").into());
    }
    let query = uri
        .query()
        .filter(|query| !query.is_empty())
        .map(|query| format!("?{query}"))
        .unwrap_or_default();
    let payload = body.map(|body| body.json().cloned().unwrap_or_else(|| json!({})));
    Ok(forward(
        app.relay(
            &claimed.node_id,
            &identity,
            method,
            node_url(&claimed, &format!("/{rest}{query}")),
            payload,
        )
        .await?,
    ))
}

pub async fn relay_get(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(params): Path<Vec<(String, String)>>,
    uri: Uri,
) -> Handled {
    let session_id = params
        .into_iter()
        .find(|(name, _)| name == "id")
        .map(|(_, id)| id)
        .unwrap_or_default();
    relay_panel(app, identity, session_id, uri, HttpMethod::Get, None).await
}

pub async fn relay_post(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(params): Path<Vec<(String, String)>>,
    uri: Uri,
    ReqBody(body): ReqBody,
) -> Handled {
    let session_id = params
        .into_iter()
        .find(|(name, _)| name == "id")
        .map(|(_, id)| id)
        .unwrap_or_default();
    relay_panel(app, identity, session_id, uri, HttpMethod::Post, Some(body)).await
}

/// Browser recordings cross the node link in base64 chunks of this many bytes.
const RECORDING_CHUNK_BYTES: u64 = 4 * 1024 * 1024;

/// One chunk of a recording from the node: the file's size and the bytes.
async fn recording_chunk(
    app: &AppState,
    identity: &Identity,
    claimed: &Claimed,
    file: &str,
    offset: u64,
) -> Result<(u64, Vec<u8>), Fail> {
    let query = form_urlencoded::Serializer::new(String::new())
        .append_pair("path", file)
        .append_pair("offset", &offset.to_string())
        .append_pair("length", &RECORDING_CHUNK_BYTES.to_string())
        .finish();
    let response = app
        .relay(
            &claimed.node_id,
            identity,
            HttpMethod::Get,
            node_url(claimed, &format!("/browser/recording?{query}")),
            None,
        )
        .await?;
    if response.status >= 400 {
        return Err(Fail::Reply(Box::new(forward(response))));
    }
    let body = response.body.unwrap_or_default();
    let size = body["size"].as_u64().unwrap_or(0);
    let data = STANDARD
        .decode(body["dataBase64"].as_str().unwrap_or_default())
        .unwrap_or_default();
    Ok((size, data))
}

/// A browser recording (`.pirc/recordings/*.webm` in the session's
/// workspace), fetched from the node in chunks. Supports Range so video
/// players can seek.
pub async fn recording(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(session_id): Path<String>,
    headers: HeaderMap,
    uri: Uri,
) -> Handled {
    let claimed = app.claim(&identity, &session_id)?;
    let query = query_map(&uri);
    let file = match query.get("path").map(Vec::as_slice) {
        Some([file]) if (1..=300).contains(&file.encode_utf16().count()) => file.clone(),
        _ => return Err(ApiError::invalid_input().into()),
    };
    let range = headers
        .get(header::RANGE)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("bytes="))
        .and_then(|value| value.split_once('-'))
        .filter(|(a, b)| {
            a.bytes().all(|c| c.is_ascii_digit()) && b.bytes().all(|c| c.is_ascii_digit())
        })
        .map(|(a, b)| (a.to_owned(), b.to_owned()));
    // An offset past u64 is past any file: 416 below.
    let mut start: u64 = range
        .as_ref()
        .filter(|(a, _)| !a.is_empty())
        .map_or(0, |(a, _)| a.parse().unwrap_or(u64::MAX));
    let mut first = recording_chunk(&app, &identity, &claimed, &file, start).await?;
    let size = first.0;
    if let Some((a, b)) = &range
        && a.is_empty()
        && !b.is_empty()
    {
        // Suffix range: the last N bytes.
        start = size.saturating_sub(b.parse().unwrap_or(u64::MAX));
        // A failure here was not caught in TS: an internal error.
        first = recording_chunk(&app, &identity, &claimed, &file, start)
            .await
            .map_err(|_| Fail::Api(ApiError::internal()))?;
    }
    let end = match &range {
        Some((a, b)) if !a.is_empty() && !b.is_empty() => {
            b.parse::<u64>().unwrap_or(0).min(size.saturating_sub(1))
        }
        _ => size.saturating_sub(1),
    };
    if start >= size && size > 0 {
        let mut response = status(no_content(), 416);
        response.headers_mut().insert(
            header::CONTENT_RANGE,
            format!("bytes */{size}").parse().expect("header value"),
        );
        return Ok(response);
    }
    let length = if size == 0 {
        0
    } else {
        (end + 1).saturating_sub(start)
    };
    let stream = {
        let app = app.clone();
        futures_util::stream::unfold((start, first.1, false), move |(offset, next, done)| {
            let app = app.clone();
            let identity = identity.clone();
            let file = file.clone();
            let claimed = Claimed {
                session: claimed.session.clone(),
                node_id: claimed.node_id.clone(),
                pi_session_id: claimed.pi_session_id.clone(),
            };
            async move {
                if done || offset > end || next.is_empty() || size == 0 {
                    return None;
                }
                let take = ((end - offset + 1) as usize).min(next.len());
                let part = next[..take].to_vec();
                let offset = offset + take as u64;
                if offset > end {
                    return Some((Ok::<_, std::io::Error>(part), (offset, Vec::new(), true)));
                }
                match recording_chunk(&app, &identity, &claimed, &file, offset).await {
                    Ok((_, data)) => Some((Ok(part), (offset, data, false))),
                    Err(_) => Some((Ok(part), (offset, Vec::new(), true))),
                }
            }
        })
    };
    let mut response = axum::body::Body::from_stream(stream).into_response();
    let headers = response.headers_mut();
    headers.insert(header::CONTENT_TYPE, "video/webm".parse().expect("header"));
    headers.insert(header::ACCEPT_RANGES, "bytes".parse().expect("header"));
    headers.insert(
        header::CACHE_CONTROL,
        "private, max-age=3600".parse().expect("header"),
    );
    headers.insert(
        header::CONTENT_LENGTH,
        length.to_string().parse().expect("header"),
    );
    if range.is_some() {
        headers.insert(
            header::CONTENT_RANGE,
            format!("bytes {start}-{end}/{size}")
                .parse()
                .expect("header"),
        );
        return Ok(status(response, 206));
    }
    Ok(response)
}

/// Routes of the gateway's features (devices, memory, schedules, push).
pub fn feature_routes() -> axum::Router<AppState> {
    crate::features::routes()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn payload(value: Value) -> Result<Value, ApiError> {
        let Value::Object(map) = value else {
            unreachable!()
        };
        command_payload(map).map(Value::Object)
    }

    #[test]
    fn command_payloads_are_bounded() {
        assert_eq!(
            payload(json!({ "type": "prompt", "message": "hi", "uploadIds": ["u"], "extra": [1] }))
                .unwrap(),
            json!({ "type": "prompt", "message": "hi", "uploadIds": ["u"] })
        );
        assert_eq!(
            payload(json!({ "type": "send_now", "queue": "steering", "index": 2, "message": "x" }))
                .unwrap(),
            json!({ "type": "send_now", "queue": "steering", "index": 2, "message": "x" })
        );
        for command in [
            json!({"type": "edit_message", "entryId": "1234abcd", "message": "revised"}),
            json!({"type": "switch_branch", "entryId": "1234abcd"}),
        ] {
            assert_eq!(payload(command.clone()).unwrap(), command);
        }
        assert!(
            payload(
                json!({"type": "switch_branch", "entryId": "x".repeat(COMMAND_STRING_MAX + 1)})
            )
            .is_err()
        );
        let long = "a".repeat(COMMAND_MESSAGE_MAX + 1);
        assert!(payload(json!({ "type": "prompt", "message": long })).is_err());
        let many: Vec<String> = (0..=COMMAND_UPLOADS_MAX).map(|i| i.to_string()).collect();
        assert!(payload(json!({ "type": "prompt", "message": "x", "uploadIds": many })).is_err());
        let model = "m".repeat(COMMAND_STRING_MAX + 1);
        assert!(
            payload(json!({ "type": "set_model", "provider": "p", "modelId": model })).is_err()
        );
        assert!(payload(json!({ "type": "prompt", "message": { "nested": true } })).is_err());
        assert_eq!(
            payload(json!({ "type": "set_approval_mode", "mode": "read-only" })).unwrap(),
            json!({ "type": "set_approval_mode", "mode": "read-only" })
        );
    }
}
