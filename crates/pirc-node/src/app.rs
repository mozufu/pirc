//! The node's own routes (`node/app.ts`, all but the panels'). Owner:
//! **core**.
//!
//! - Workspaces: `POST /api/workspaces` (chat projects on the chat node,
//!   directories under `$HOME` elsewhere, never around the node's state or
//!   a credential store), `DELETE /api/workspaces/:id` (chat projects only,
//!   fenced, idempotent), `GET`/`PATCH /api/workspaces/:id/instructions`,
//!   `GET`/`POST`/`DELETE /api/workspaces/:id/files` (`project_files`),
//!   `GET /api/workspaces/:id/project-config`,
//!   `POST /api/workspaces/:id/project-trust`; on the chat node
//!   `GET /api/assistant/prompts`, `PUT /api/assistant/prompts/:name`.
//! - Sessions: `POST /api/sessions`, `DELETE /api/sessions/:id` (chat
//!   only, fenced, idempotent), `PATCH /api/sessions/:id` (rename),
//!   `GET /api/sessions/:id/snapshot`, `POST /api/sessions/:id/deliver`,
//!   `POST /api/sessions/:id/commands`, control (`GET .../control`,
//!   `POST .../control/acquire|heartbeat|release`),
//!   `POST .../interactions/:interactionId/answer`, `POST .../uploads`.
//! - `POST /api/workspace-memory/recall`.
//!
//! Request bodies are checked as the TS zod schemas did: unknown keys are
//! dropped unless the schema was strict, `.trim()` applies before the
//! length checks, lengths count UTF-16 units, and a failure is 400
//! `invalid_input` "Invalid request".
//!
//! Golden cases: `app.integration.test.ts`, `chat-workspaces`,
//! `project-instructions`, `project-trust`, `assistant-prompts` and the
//! node halves of `relay.integration.test.ts`.

use std::collections::HashMap;
use std::fs::{DirBuilder, OpenOptions};
use std::io::Write;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use futures_util::FutureExt;
use futures_util::future::{BoxFuture, Shared};
use pirc_config::NodeConfig;
use pirc_protocol::mode::{ModeId, Workdir};
use serde_json::{Map, Value, json};

use crate::assistant_prompts::{self, PromptName};
use crate::chat;
use crate::error::{ApiError, ApiResult};
use crate::project_files;
use crate::router::{Body, Request, Response, Route, delete, get, parse, patch, post, put};
use crate::runner::{CommandPayload, Delivery};
use crate::services::Node;
use crate::store::{
    DeletionStatus, NameSource, SessionRow, Store, UploadKind, UploadRow, Workspace,
};
use crate::util::{head16, hex, payload_hash, prefix_uuid, random_bytes, sha256_hex};

/// Core's routes for this node's role (the assistant prompt routes exist on
/// the chat node only).
pub fn routes(config: &NodeConfig) -> Vec<Route> {
    let deletions = Arc::new(Deletions::default());
    let mut routes = vec![
        post("/api/workspaces", create_workspace),
        get("/api/workspaces/:id/removal-check", workspace_removal_check),
        delete("/api/workspaces/:id", {
            let deletions = deletions.clone();
            move |node, request| delete_workspace(node, request, deletions.clone())
        }),
        get("/api/workspaces/:id/instructions", read_instructions),
        patch("/api/workspaces/:id/instructions", write_instructions),
        get("/api/workspaces/:id/files", list_project_files),
        post("/api/workspaces/:id/files", upload_project_file),
        delete("/api/workspaces/:id/files", remove_project_file),
        get("/api/workspaces/:id/project-config", project_config),
        post("/api/workspaces/:id/project-trust", project_trust),
        post("/api/sessions", create_session),
        get(
            "/api/execution-fences/capabilities",
            crate::execution_fences::capabilities,
        ),
        post(
            "/api/sessions/:id/execution-fences/preflight",
            crate::execution_fences::preflight,
        ),
        post(
            "/api/sessions/:id/execution-fences",
            crate::execution_fences::create,
        ),
        get(
            "/api/sessions/:id/execution-fences/:operation",
            crate::execution_fences::status,
        ),
        post(
            "/api/sessions/:id/execution-fences/:operation/drain",
            crate::execution_fences::resume,
        ),
        post("/api/session-creations", crate::session_creation::prepare),
        get(
            "/api/session-creations/capabilities",
            crate::session_creation::capabilities,
        ),
        get(
            "/api/session-creations/:id",
            crate::session_creation::status,
        ),
        put(
            "/api/session-creations/:id/attachments/:attachment",
            crate::session_creation::uploads::transfer,
        ),
        get(
            "/api/session-creations/:id/attachments/:attachment",
            crate::session_creation::uploads::status,
        ),
        post("/api/session-creations/:id/cancel", {
            let deletions = deletions.clone();
            move |node, request| {
                crate::session_creation::cancellation::cancel(node, request, deletions.clone())
            }
        }),
        get(
            "/api/session-creations/:id/cancel",
            crate::session_creation::cancellation::status,
        ),
        post(
            "/api/session-creations/:id/stop",
            crate::session_creation::pre_stop::stop,
        ),
        get(
            "/api/session-creations/:id/stop",
            crate::session_creation::pre_stop::status,
        ),
        delete("/api/sessions/:id", move |node, request| {
            delete_session(node, request, deletions.clone())
        }),
        patch("/api/sessions/:id", rename_session),
        get("/api/sessions/:id/snapshot", snapshot),
        post("/api/sessions/:id/deliver", deliver),
        post("/api/workspace-memory/recall", recall_workspace_memory),
        post(
            "/api/session-creations/:id/admission",
            crate::session_creation::admission::submit,
        ),
        get(
            "/api/session-creations/:id/admission",
            crate::session_creation::admission::status,
        ),
        post(
            "/api/session-creations/:id/admission/retry",
            crate::session_creation::admission::retry,
        ),
        get(
            "/api/session-creations/:id/admission/attempts/:commandId",
            crate::session_creation::admission::attempt_status,
        ),
        get(
            "/api/sessions/:id/commands/:commandId",
            crate::session_creation::admission::command_status,
        ),
        get(
            "/api/command-environments/capabilities",
            crate::command_environment::capabilities,
        ),
        post("/api/sessions/:id/commands", command),
        get("/api/sessions/:id/control", control),
        post("/api/sessions/:id/control/acquire", acquire),
        post("/api/sessions/:id/control/heartbeat", heartbeat),
        post("/api/sessions/:id/control/release", release),
        post(
            "/api/sessions/:id/interactions/:interactionId/answer",
            answer,
        ),
        post(
            "/api/sessions/:id/interactions/:interactionId/relayed-answer",
            relayed_answer,
        ),
        post("/api/sessions/:id/uploads", upload),
        get(
            "/api/sessions/:id/uploads/:uploadId/reference",
            crate::upload_origins::get_reference,
        ),
    ];
    if config.chat() {
        routes.push(get("/api/assistant/prompts", read_prompts));
        routes.push(put("/api/assistant/prompts/:name", write_prompt));
    }
    routes
}

// ---------- request checks (the zod schemas of node/app.ts) ----------

/// JS string length.
fn length(text: &str) -> usize {
    text.encode_utf16().count()
}

fn object(value: &Value) -> ApiResult<&Map<String, Value>> {
    value.as_object().ok_or_else(ApiError::invalid_input)
}

/// A `.strict()` object: no key but `allowed`.
fn strict(map: &Map<String, Value>, allowed: &[&str]) -> ApiResult<()> {
    if map.keys().all(|key| allowed.contains(&key.as_str())) {
        Ok(())
    } else {
        Err(ApiError::invalid_input())
    }
}

/// `z.string()` (`.trim()` first when `trim`) with `min..=max` UTF-16 units.
fn string(
    map: &Map<String, Value>,
    key: &str,
    trim: bool,
    min: usize,
    max: usize,
) -> ApiResult<String> {
    let text = map
        .get(key)
        .and_then(Value::as_str)
        .ok_or_else(ApiError::invalid_input)?;
    let text = if trim { chat::js_trim(text) } else { text };
    let units = length(text);
    if units < min || units > max {
        return Err(ApiError::invalid_input());
    }
    Ok(text.to_owned())
}

/// The same, optional (`undefined` only: `null` is not a string).
fn optional_string(
    map: &Map<String, Value>,
    key: &str,
    trim: bool,
    min: usize,
    max: usize,
) -> ApiResult<Option<String>> {
    match map.get(key) {
        None => Ok(None),
        Some(_) => string(map, key, trim, min, max).map(Some),
    }
}

/// `z.number().int()`: an integral JS number.
fn js_int(value: &Value) -> Option<i64> {
    let number = value.as_number()?;
    if let Some(int) = number.as_i64() {
        return Some(int);
    }
    let float = number.as_f64()?;
    (float.is_finite() && float.fract() == 0.0 && float.abs() < 9.007_199_254_740_992e15)
        .then_some(float as i64)
}

/// `z.number().int().positive()` / `.nonnegative()`.
fn integer(map: &Map<String, Value>, key: &str, min: i64) -> ApiResult<i64> {
    map.get(key)
        .and_then(js_int)
        .filter(|value| *value >= min)
        .ok_or_else(ApiError::invalid_input)
}

fn optional_bool(map: &Map<String, Value>, key: &str) -> ApiResult<Option<bool>> {
    match map.get(key) {
        None => Ok(None),
        Some(Value::Bool(value)) => Ok(Some(*value)),
        Some(_) => Err(ApiError::invalid_input()),
    }
}

fn enumerated(map: &Map<String, Value>, key: &str, values: &[&str]) -> ApiResult<String> {
    map.get(key)
        .and_then(Value::as_str)
        .filter(|value| values.contains(value))
        .map(str::to_owned)
        .ok_or_else(ApiError::invalid_input)
}

const THINKING_LEVELS: [&str; 7] = ["off", "minimal", "low", "medium", "high", "xhigh", "max"];

fn param<'a>(request: &'a Request, name: &str) -> &'a str {
    request.param(name).unwrap_or_default()
}

/// `claim(request)`: the session, if the user owns it and it is not being
/// deleted.
fn claim(node: &Node, request: &Request) -> ApiResult<SessionRow> {
    node.db
        .lock()
        .claim_session(param(request, "id"), &request.user, false)
}

/// Mutations require the workspace's current, accepted catalog definition.
/// Plain `claim` remains available to history and control-state reads.
fn claim_mutable(node: &Node, request: &Request) -> ApiResult<SessionRow> {
    let session = claim(node, request)?;
    node.session_mode(&session.id)?;
    Ok(session)
}

/// A file-system failure: logged, answered 500 (TS threw a plain error).
fn io_failure(what: &str, path: &Path, error: impl std::fmt::Display) -> ApiError {
    crate::log::error(&format!("{what} {}: {error}", path.display()));
    ApiError::internal()
}

fn created(body: Value) -> ApiResult<Response> {
    Ok(Response::status(201, body))
}

// ---------- workspaces ----------

/// A requested catalog mode. Legacy `kind` is only an input alias, never
/// a source of capabilities; omitted ids use the node role's default id.
struct NewWorkspace {
    mode: ModeId,
    path: Option<String>,
    display_name: String,
    restore_existing: bool,
}

fn new_workspace(body: &Value, _chat_node: bool) -> ApiResult<NewWorkspace> {
    let map = object(body)?;
    let mode = optional_string(map, "mode", false, 1, 40)?;
    let kind = optional_string(map, "kind", false, 1, 40)?;
    if mode
        .as_ref()
        .zip(kind.as_ref())
        .is_some_and(|(mode, kind)| mode != kind)
    {
        return Err(ApiError::invalid_input());
    }
    if mode.is_none() && kind.is_none() && !map.contains_key("path") {
        return Err(ApiError::invalid_input());
    }
    // Legacy path-only callers request a directory, regardless of node role.
    let mode = ModeId::new(mode.or(kind).unwrap_or_else(|| "directory".to_owned()))
        .map_err(|_| ApiError::invalid_input())?;
    Ok(NewWorkspace {
        mode,
        path: optional_string(map, "path", true, 1, 4096)?,
        display_name: string(map, "displayName", true, 1, 200)?,
        restore_existing: optional_bool(map, "restoreExisting")?.unwrap_or(false),
    })
}

/// The requested directory: `~/rest` is `path.join(home, rest)`, where
/// (unlike `path.resolve`) an absolute `rest` (`~//etc`) stays under home.
fn requested_path(home: &Path, path: &str) -> PathBuf {
    match path.strip_prefix("~/") {
        Some(rest) => PathBuf::from(pirc_policy::resolve_path(
            &home.to_string_lossy(),
            rest.trim_start_matches('/'),
        )),
        None => PathBuf::from(path),
    }
}

/// A workspace id: `workspace_<uuid>` with underscores (ids stay one word).
fn workspace_id() -> String {
    prefix_uuid("workspace").replace('-', "_")
}

async fn create_workspace(node: Node, request: Request) -> ApiResult<Response> {
    let config = &node.config;
    let NewWorkspace {
        mode: mode_id,
        path,
        display_name,
        restore_existing,
    } = new_workspace(request.json(), config.chat())?;
    let mode = node.mode(&mode_id)?;
    if mode.workdir == Workdir::PerSession {
        let id = workspace_id();
        let dir = chat::chat_workspace_dir(config, &id)?;
        let workspace = node.db.lock().add_workspace(
            &id,
            &config.node_id,
            &display_name,
            &dir.to_string_lossy(),
            mode_id,
        )?;
        return created(json!({ "workspace": workspace }));
    }
    let path = path.ok_or_else(ApiError::invalid_input)?;
    let home_dir = node
        .env
        .get("HOME")
        .map(PathBuf::from)
        .or_else(std::env::home_dir)
        .unwrap_or_else(|| PathBuf::from("/"));
    let home = home_dir
        .canonicalize()
        .map_err(|error| io_failure("resolving", &home_dir, error))?;
    let requested = requested_path(&home, &path);
    if !requested.is_absolute() {
        return Err(ApiError::bad_request(
            "Workspace must use an absolute path or ~/path",
        ));
    }
    let canonical = match requested.canonicalize() {
        Ok(canonical) => canonical,
        Err(_) => {
            return Err(ApiError::bad_request(
                "Workspace directory must already exist",
            ));
        }
    };
    match std::fs::metadata(&canonical) {
        Ok(meta) if meta.is_dir() => {}
        Ok(_) => {
            return Err(ApiError::bad_request("Workspace path must be a directory"));
        }
        Err(_) => {
            return Err(ApiError::bad_request(
                "Workspace directory must already exist",
            ));
        }
    }
    let canonical = canonical.to_string_lossy().into_owned();
    let home = home.to_string_lossy().into_owned();
    if !canonical.starts_with(&format!("{home}/")) {
        return Err(ApiError::forbidden(
            "Workspace must stay within the node home directory",
        ));
    }
    // A workspace is writable from its sessions' sandboxes: it must not
    // hold (or sit inside) the node's own state or a credential store.
    let database_dir = config
        .database_path
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or_default();
    let mut off: Vec<String> = [
        &config.state_dir,
        &config.sessions_dir,
        &config.uploads_dir,
        &database_dir,
        &config.browser.profiles_dir,
        &config.workspace_memory_dir,
    ]
    .iter()
    .map(|dir| dir.to_string_lossy().into_owned())
    .collect();
    off.extend(
        pirc_policy::SENSITIVE_HOME_PATHS
            .iter()
            .map(|item| pirc_policy::resolve_path(&home, item)),
    );
    let clash = off
        .iter()
        .map(|item| pirc_policy::real_resolve(item))
        .find(|item| {
            pirc_policy::is_inside(item, &canonical) || pirc_policy::is_inside(&canonical, item)
        });
    if let Some(clash) = clash {
        return Err(ApiError::forbidden(format!(
            "Workspace must not contain or sit inside {clash} (pirc's state or a credential store)"
        )));
    }
    let workspace = {
        let db = node.db.lock();
        // The gateway may restore a removed directory registration, but only
        // after the same path checks as creation. Never reinterpret or update
        // an existing workspace (its identity and history must stay intact).
        let existing = if restore_existing {
            db.find_workspace_by_path(&canonical)?
        } else {
            None
        };
        if let Some(workspace) = existing {
            if workspace.mode != mode_id {
                return Err(ApiError::conflict(
                    "Workspace ID or path is already registered",
                ));
            }
            workspace
        } else {
            db.add_workspace(
                &workspace_id(),
                &config.node_id,
                &display_name,
                &canonical,
                mode_id,
            )?
        }
    };
    // Its roles, as registration reports them, for delegations.
    let mut body = serde_json::to_value(&workspace).unwrap_or_default();
    let details = crate::link::workspace_details(&node, vec![Some(canonical)]).await;
    if let Some((roles, repo)) = details.into_iter().next() {
        if let Some(roles) = roles {
            body["roles"] = serde_json::to_value(roles).unwrap_or_default();
        }
        if let Some(repo) = repo {
            body["repo"] = json!(repo);
        }
    }
    created(json!({ "workspace": body }))
}

/// Read-only authoritative preflight. The gateway fences its mutations before
/// calling this; delayed activity frames do not prove that the node is idle.
async fn workspace_removal_check(node: Node, request: Request) -> ApiResult<Response> {
    let db = node.db.lock();
    let workspace = db.get_workspace(param(&request, "id"))?;
    let mode = node.mode(&workspace.mode).ok();
    if workspace.id == "chats"
        || workspace.mode.as_str() == "chat"
        || mode.is_some_and(|mode| mode.projects || mode.full_assistant())
    {
        return Err(ApiError::bad_request(
            "Only Work workspaces can be removed; chat projects use Delete project",
        ));
    }
    let other: bool = db.query_row(
        "SELECT EXISTS(SELECT 1 FROM sessions WHERE workspace_id=?1 AND (owner_user IS NULL OR owner_user!=?2))",
        rusqlite::params![workspace.id, request.user],
        |row| row.get(0),
    )?;
    if other {
        return Err(ApiError::forbidden(
            "Workspace contains another user's sessions",
        ));
    }
    let busy: bool = db.query_row(
        "SELECT EXISTS(SELECT 1 FROM runs r JOIN sessions s ON s.id=r.session_id WHERE s.workspace_id=?1 AND r.status IN ('queued','running','waiting_input','stopping')) OR EXISTS(SELECT 1 FROM sessions WHERE workspace_id=?1 AND runner_state='starting') OR EXISTS(SELECT 1 FROM commands c JOIN sessions s ON s.id=c.session_id WHERE s.workspace_id=?1 AND c.status IN ('received','dispatched'))",
        [&workspace.id],
        |row| row.get(0),
    )?;
    let sessions = db.workspace_sessions(&workspace.id)?;
    if busy
        || sessions.iter().any(|session| {
            node.runners.is_starting(&session.id) || !node.writes.leases(&session.id).is_empty()
        })
    {
        return Err(ApiError::conflict(
            "Stop active sessions and delegations before removing this workspace",
        ));
    }
    crate::host_commands::resources::require_available(
        &db,
        std::path::Path::new(&workspace.canonical_path),
        None,
    )?;
    Ok(Response::json(json!({ "idle": true })))
}

/// `chatProject`: the workspace, which must be a chat project.
fn chat_project(node: &Node, request: &Request) -> ApiResult<Workspace> {
    let workspace = node.db.lock().get_workspace(param(request, "id"))?;
    if !node.workspace_mode(&workspace)?.project_instructions {
        return Err(ApiError::bad_request(
            "Only chat projects have instructions",
        ));
    }
    Ok(workspace)
}

fn instructions(text: String) -> ApiResult<Response> {
    Ok(Response::json(json!({
        "instructions": { "text": text, "maxChars": chat::INSTRUCTIONS_MAX_CHARS }
    })))
}

async fn read_instructions(node: Node, request: Request) -> ApiResult<Response> {
    let workspace = chat_project(&node, &request)?;
    let mode = node.workspace_mode(&workspace)?;
    instructions(chat::read_project_instructions(&workspace, &mode))
}

/// `{text: string}`, strict.
fn text_body(body: &Value) -> ApiResult<String> {
    let map = object(body)?;
    strict(map, &["text"])?;
    map.get("text")
        .and_then(Value::as_str)
        .map(str::to_owned)
        .ok_or_else(ApiError::invalid_input)
}

async fn write_instructions(node: Node, request: Request) -> ApiResult<Response> {
    let workspace = chat_project(&node, &request)?;
    let text = text_body(request.json())?;
    let mode = node.workspace_mode(&workspace)?;
    instructions(chat::write_project_instructions(&workspace, &text, &mode)?)
}

fn project_files_body(node: &Node, workspace: &Workspace) -> ApiResult<Value> {
    let mode = node.workspace_mode(workspace)?;
    let files: Vec<Value> = project_files::list(workspace, &mode)?
        .iter()
        .map(project_files::ProjectFile::json)
        .collect();
    Ok(json!({
        "files": files,
        "maxFiles": project_files::MAX_FILES,
        "maxBytes": node.config.upload_max_bytes,
    }))
}

/// `GET /api/workspaces/:id/files`: the project's files, by name.
async fn list_project_files(node: Node, request: Request) -> ApiResult<Response> {
    let workspace = node.db.lock().get_workspace(param(&request, "id"))?;
    Ok(Response::json(project_files_body(&node, &workspace)?))
}

/// `POST /api/workspaces/:id/files?filename=…`, raw bytes: add or replace
/// one file.
async fn upload_project_file(node: Node, request: Request) -> ApiResult<Response> {
    let workspace = node.db.lock().get_workspace(param(&request, "id"))?;
    let Body::Raw { bytes, .. } = &request.body else {
        return Err(ApiError::bad_request("Upload body must be raw bytes"));
    };
    if bytes.is_empty() || bytes.len() > node.config.upload_max_bytes {
        return Err(ApiError::new(
            413,
            "payload_too_large",
            "Upload exceeds configured limit",
        ));
    }
    let query = request.query_object();
    let filename = string(object(&query)?, "filename", false, 1, 1000)?;
    let mode = node.workspace_mode(&workspace)?;
    let file = project_files::write(&workspace, &filename, bytes, &mode)?;
    // The project may have been fenced for deletion while the bytes were
    // written: keep nothing then (its deletion removes the directory too).
    if let Err(error) = node.db.lock().get_workspace(&workspace.id) {
        if let Some(dir) = project_files::files_dir(&workspace, &mode) {
            let _ = std::fs::remove_dir_all(dir);
        }
        return Err(error);
    }
    created(json!({ "file": file.json() }))
}

/// `DELETE /api/workspaces/:id/files?name=…`.
async fn remove_project_file(node: Node, request: Request) -> ApiResult<Response> {
    let workspace = node.db.lock().get_workspace(param(&request, "id"))?;
    let query = request.query_object();
    let name = string(object(&query)?, "name", false, 1, 1000)?;
    let mode = node.workspace_mode(&workspace)?;
    project_files::remove(&workspace, &name, &mode)?;
    Ok(Response::empty(204))
}

/// `directoryWorkspace`: the workspace, which must be a directory.
fn directory_workspace(node: &Node, request: &Request) -> ApiResult<Workspace> {
    let workspace = node.db.lock().get_workspace(param(request, "id"))?;
    if !node.workspace_mode(&workspace)?.project_config {
        return Err(ApiError::bad_request(
            "Only directory workspaces have a project config",
        ));
    }
    Ok(workspace)
}

/// `projectSummary`: the project config's trust-relevant fields, their
/// hash and whether the user trusted exactly them; or the config's error.
fn project_summary(node: &Node, workspace: &Workspace) -> ApiResult<Map<String, Value>> {
    use pirc_agent::config as agent;
    let trusted_hash = node.db.lock().get_workspace_trust(&workspace.id)?;
    let mut summary = Map::new();
    match agent::read_project_config(&workspace.canonical_path) {
        Ok(project) => {
            let fields = agent::project_trust_fields(&project);
            let hash = agent::project_trust_hash(&fields);
            summary.insert("hooks".into(), fields.hooks.to_value());
            summary.insert(
                "env".into(),
                Value::Object(
                    fields
                        .env
                        .iter()
                        .map(|(key, value)| (key.clone(), Value::from(value.as_str())))
                        .collect(),
                ),
            );
            summary.insert(
                "allowedPaths".into(),
                Value::from(fields.allowed_paths.clone()),
            );
            summary.insert(
                "defaultModel".into(),
                fields
                    .default_model
                    .as_ref()
                    .map_or(Value::Null, |model| json!(model)),
            );
            summary.insert("hash".into(), Value::from(hash.as_str()));
            summary.insert("trustedHash".into(), json!(trusted_hash));
            summary.insert(
                "trusted".into(),
                Value::Bool(trusted_hash.as_deref() == Some(hash.as_str())),
            );
            summary.insert(
                "empty".into(),
                Value::Bool(agent::project_trust_empty(&fields)),
            );
        }
        Err(error) => {
            summary.insert("error".into(), Value::from(head16(&error, 2000)));
            summary.insert("hash".into(), Value::Null);
            summary.insert("trustedHash".into(), json!(trusted_hash));
            summary.insert("trusted".into(), Value::Bool(false));
            summary.insert("empty".into(), Value::Bool(true));
        }
    }
    Ok(summary)
}

async fn project_config(node: Node, request: Request) -> ApiResult<Response> {
    let workspace = directory_workspace(&node, &request)?;
    Ok(Response::json(
        json!({ "project": project_summary(&node, &workspace)? }),
    ))
}

async fn project_trust(node: Node, request: Request) -> ApiResult<Response> {
    let workspace = directory_workspace(&node, &request)?;
    // `{trusted: true, hash: string}` or `{trusted: false}`, both strict.
    let map = object(request.json())?;
    let hash = match map.get("trusted") {
        Some(Value::Bool(true)) => {
            strict(map, &["trusted", "hash"])?;
            Some(
                map.get("hash")
                    .and_then(Value::as_str)
                    .ok_or_else(ApiError::invalid_input)?
                    .to_owned(),
            )
        }
        Some(Value::Bool(false)) => {
            strict(map, &["trusted"])?;
            None
        }
        _ => return Err(ApiError::invalid_input()),
    };
    let Some(hash) = hash else {
        node.db
            .lock()
            .set_workspace_trust(&workspace.id, None, &request.user)?;
        return Ok(Response::json(
            json!({ "project": project_summary(&node, &workspace)? }),
        ));
    };
    let Some(hash) = pirc_agent::config::parse_trust_hash(Some(&hash)) else {
        return Err(ApiError::bad_request("hash must be a sha256 hex digest"));
    };
    let current = project_summary(&node, &workspace)?;
    if let Some(error) = current.get("error").and_then(Value::as_str) {
        return Err(ApiError::bad_request(format!(
            "The project config is invalid: {error}"
        )));
    }
    // Trust only what the user reviewed: the config may have changed since.
    if current.get("hash").and_then(Value::as_str) != Some(hash.as_str()) {
        return Err(ApiError::conflict(
            "The project config changed since it was shown; review it again before trusting it",
        ));
    }
    node.db
        .lock()
        .set_workspace_trust(&workspace.id, Some(&hash), &request.user)?;
    Ok(Response::json(
        json!({ "project": project_summary(&node, &workspace)? }),
    ))
}

async fn read_prompts(node: Node, _request: Request) -> ApiResult<Response> {
    let dir = &node.config.config_dir;
    Ok(Response::json(json!({
        "soul": assistant_prompts::inspect(dir, PromptName::Soul),
        "chat": assistant_prompts::inspect(dir, PromptName::Chat),
    })))
}

async fn write_prompt(node: Node, request: Request) -> ApiResult<Response> {
    let name = match param(&request, "name") {
        "soul" => PromptName::Soul,
        "chat" => PromptName::Chat,
        _ => return Err(ApiError::invalid_input()),
    };
    let text = text_body(request.json())?;
    let prompt = assistant_prompts::write(&node.config.config_dir, name, &text)?;
    Ok(Response::json(json!({ "prompt": prompt })))
}

// ---------- sessions ----------

async fn create_session(node: Node, request: Request) -> ApiResult<Response> {
    let map = object(request.json())?;
    let workspace_id = string(map, "workspaceId", false, 1, usize::MAX)?;
    crate::checkpoints::continuation::require_workspace_owner(
        &node.db.lock(),
        &workspace_id,
        &request.user,
    )?;
    let workspace = node.db.lock().get_workspace(&workspace_id)?;
    node.workspace_mode(&workspace)?;
    let storage = node.config.sessions_dir.join(prefix_uuid("pi"));
    DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(&storage)
        .map_err(|error| io_failure("creating", &storage, error))?;
    let session =
        node.db
            .lock()
            .create_session(&workspace.id, &storage.to_string_lossy(), &request.user)?;
    created(json!({ "session": session }))
}

type Deletion = Shared<BoxFuture<'static, ApiResult<()>>>;

/// Chat deletions in flight: a retried DELETE joins the running one.
#[derive(Default)]
pub(crate) struct Deletions(Mutex<HashMap<String, Deletion>>);

async fn delete_session(
    node: Node,
    request: Request,
    deletions: Arc<Deletions>,
) -> ApiResult<Response> {
    let session_id = param(&request, "id").to_owned();
    let user = request.user.clone();
    delete_owned_session(node, session_id, user, deletions, true).await?;
    Ok(Response::empty(204))
}
/// Only creation cancellation calls this with `check_mode = false`: it can
/// discard the Node-allocated private session, never the user's workspace.
pub(crate) async fn delete_owned_session(
    node: Node,
    session_id: String,
    user: String,
    deletions: Arc<Deletions>,
    check_mode: bool,
) -> ApiResult<()> {
    let (session, workspace) = {
        let db = node.db.lock();
        let deletion = db.session_deletion(&session_id)?;
        if let Some(deletion) = &deletion {
            if deletion.owner_user != user {
                return Err(ApiError::forbidden("Chat belongs to another user"));
            }
            if deletion.status == DeletionStatus::Deleted {
                return Ok(());
            }
        }
        let session = db.claim_session(&session_id, &user, true)?;
        let workspace = db.get_workspace(&session.workspace_id)?;
        if check_mode && !node.workspace_mode(&workspace)?.delete_sessions {
            return Err(ApiError::bad_request("Only chats can be deleted"));
        }
        db.begin_session_deletion(&session_id, &user)?;
        (session, workspace)
    };
    let task = {
        let mut running = deletions.0.lock().unwrap_or_else(|p| p.into_inner());
        running
            .entry(session_id.clone())
            .or_insert_with(|| {
                // Its own task: the cleanup finishes even if this request
                // goes away.
                let handle = tokio::spawn(finish_deletion(
                    node.clone(),
                    session,
                    workspace,
                    deletions.clone(),
                ));
                async move { handle.await.unwrap_or_else(|_| Err(ApiError::internal())) }
                    .boxed()
                    .shared()
            })
            .clone()
    };
    task.await
}

async fn finish_deletion(
    node: Node,
    session: SessionRow,
    workspace: Workspace,
    deletions: Arc<Deletions>,
) -> ApiResult<()> {
    // Removed on drop, so a panicking cleanup does not leave a finished
    // deletion that every retry would join (TS: `.finally(...)`).
    let _entry = DeletionEntry {
        deletions,
        session_id: session.id.clone(),
    };
    remove_session(&node, &session, &workspace).await
}

/// Removes a session's [`Deletions`] entry when dropped. The entry is
/// inserted under the map's lock before the task can take it, so the
/// removal never precedes the insertion.
struct DeletionEntry {
    deletions: Arc<Deletions>,
    session_id: String,
}

impl Drop for DeletionEntry {
    fn drop(&mut self) {
        self.deletions
            .0
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .remove(&self.session_id);
    }
}

async fn remove_session(node: &Node, session: &SessionRow, workspace: &Workspace) -> ApiResult<()> {
    node.runners.stop_session(&session.id).await?;
    node.terminals.dispose_session(&session.id).await?;
    node.browser.close_session(&session.id).await?;
    let mode = node.workspace_mode(workspace)?;
    // Both paths are allocated by the node, never supplied by the caller.
    let sessions_dir = node.config.sessions_dir.to_string_lossy().into_owned();
    let private = pirc_policy::resolve_path("/", &session.private_session_path);
    if !pirc_policy::is_inside(&private, &sessions_dir)
        || private == pirc_policy::resolve_path("/", &sessions_dir)
    {
        crate::log::error(&format!(
            "deleting session {}: invalid private session path",
            session.id
        ));
        return Err(ApiError::internal());
    }
    if let Some(capture) = &node.checkpoints {
        let capture = capture.clone();
        let owner = session.owner_user.clone().unwrap_or_default();
        let id = session.id.clone();
        tokio::task::spawn_blocking(move || capture.journal.delete_session(&owner, &id))
            .await
            .map_err(|_| ApiError::internal())?
            .map_err(|error| ApiError::new(409, "checkpoint_retained", error))?;
    }
    crate::session_creation::uploads::remove_session_files(node, &session.id)?;
    remove_tree(Path::new(&session.private_session_path))?;
    let base = session
        .id
        .split('/')
        .rfind(|part| !part.is_empty())
        .unwrap_or_default();
    if mode.workdir == Workdir::PerSession {
        remove_tree(
            &Path::new(&workspace.canonical_path)
                .join("sessions")
                .join(base),
        )?;
    }
    node.branches
        .forget(Path::new(&session.private_session_path));
    node.db.lock().finish_session_deletion(&session.id)?;
    node.events.forget(&session.id);
    Ok(())
}

/// `rmSync(path, { recursive: true, force: true })`.
fn remove_tree(path: &Path) -> ApiResult<()> {
    let removed = match std::fs::symlink_metadata(path) {
        Err(_) => return Ok(()),
        Ok(meta) if meta.is_dir() => std::fs::remove_dir_all(path),
        Ok(_) => std::fs::remove_file(path),
    };
    match removed {
        Err(error) if error.kind() != std::io::ErrorKind::NotFound => {
            Err(io_failure("removing", path, error))
        }
        _ => Ok(()),
    }
}

/// Delete a chat project: every chat in it (as [`delete_session`] does),
/// the uploads made in it, its browser profile, its directory
/// (instructions included) and its row. Fenced first, so a retry after a
/// failure or a restart finishes the same cleanup; the fenced project is
/// no longer announced to the gateway.
async fn delete_workspace(
    node: Node,
    request: Request,
    deletions: Arc<Deletions>,
) -> ApiResult<Response> {
    let workspace_id = param(&request, "id").to_owned();
    let user = request.user.clone();
    let workspace = {
        let db = node.db.lock();
        if let Some(deletion) = db.workspace_deletion(&workspace_id)? {
            if deletion.owner_user != user {
                return Err(ApiError::forbidden("Project belongs to another user"));
            }
            if deletion.status == DeletionStatus::Deleted {
                return Ok(Response::empty(204));
            }
        }
        let workspace = db
            .find_workspace(&workspace_id)?
            .ok_or_else(|| ApiError::not_found("Workspace not found"))?;
        if !node.workspace_mode(&workspace)?.projects
            || workspace.id == pirc_config::CHAT_WORKSPACE_ID
        {
            return Err(ApiError::bad_request("Only chat projects can be deleted"));
        }
        db.begin_workspace_deletion(&workspace_id, &user)?;
        workspace
    };
    let key = format!("workspace:{workspace_id}");
    let task = {
        let mut running = deletions.0.lock().unwrap_or_else(|p| p.into_inner());
        running
            .entry(key.clone())
            .or_insert_with(|| {
                let handle = tokio::spawn({
                    let node = node.clone();
                    let deletions = deletions.clone();
                    async move {
                        let _entry = DeletionEntry {
                            deletions,
                            session_id: key,
                        };
                        remove_project(&node, &workspace).await
                    }
                });
                async move { handle.await.unwrap_or_else(|_| Err(ApiError::internal())) }
                    .boxed()
                    .shared()
            })
            .clone()
    };
    task.await?;
    Ok(Response::empty(204))
}

/// An upload's storage name as the node makes them: `<48 hex>.bin`.
pub(crate) fn storage_name(name: &str) -> bool {
    name.strip_suffix(".bin").is_some_and(|stem| {
        stem.len() == 48
            && stem
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    })
}

async fn remove_project(node: &Node, workspace: &Workspace) -> ApiResult<()> {
    // Checked before anything goes: only the directory the node allocated,
    // `<state>/chat/<id>`, and only a non-empty id.
    let directory = Path::new(&workspace.canonical_path);
    let chat_root = node.config.state_dir.join("chat");
    let chat_root = chat_root.canonicalize().unwrap_or(chat_root);
    if workspace.id.is_empty()
        || directory.parent() != Some(chat_root.as_path())
        || directory.file_name() != Some(std::ffi::OsStr::new(&workspace.id))
    {
        crate::log::error(&format!(
            "deleting workspace {}: unexpected directory {}",
            workspace.id,
            directory.display()
        ));
        return Err(ApiError::internal());
    }
    let user = node
        .db
        .lock()
        .workspace_deletion(&workspace.id)?
        .map(|deletion| deletion.owner_user)
        .ok_or_else(ApiError::internal)?;
    let sessions = node.db.lock().workspace_sessions(&workspace.id)?;
    for session in sessions {
        node.db.lock().begin_session_deletion(&session.id, &user)?;
        remove_session(node, &session, workspace).await?;
    }
    let uploads = node.db.lock().workspace_uploads(&workspace.id)?;
    for upload in uploads {
        if !storage_name(&upload.storage_name) {
            crate::log::error(&format!("upload {}: invalid storage name", upload.id));
            return Err(ApiError::internal());
        }
        remove_tree(&node.config.uploads_dir.join(&upload.storage_name))?;
    }
    remove_tree(
        &node
            .config
            .browser
            .profiles_dir
            .join(crate::browser::manager::profile_name(&workspace.id)),
    )?;
    remove_tree(directory)?;
    node.db.lock().finish_workspace_deletion(&workspace.id)?;
    Ok(())
}

async fn rename_session(node: Node, request: Request) -> ApiResult<Response> {
    let session = claim_mutable(&node, &request)?;
    let name = string(object(request.json())?, "name", true, 1, 200)?;
    if let Some(active) = node.runners.get(&session.id) {
        let mut command = Map::new();
        command.insert("type".into(), json!("set_session_name"));
        command.insert("name".into(), json!(name));
        let response = active.request(command).await?;
        if response.get("success") != Some(&Value::Bool(true)) {
            let message = response
                .get("error")
                .and_then(Value::as_str)
                .unwrap_or("Agent rejected the name");
            return Err(ApiError::runner_unavailable(message));
        }
    }
    // Also tells connected clients; a no-op when the runner's echo already
    // applied it.
    apply_session_name(
        &node,
        &session.id,
        session.runner_epoch,
        &json!({ "name": name, "source": "user" }),
    )?;
    let session = node.db.lock().get_session(&session.id)?;
    Ok(Response::json(json!({ "session": session })))
}

/// The model and thinking level a live agent reports (`get_state`).
async fn live_agent(runner: &crate::runner::Runner) -> Option<Value> {
    let mut command = Map::new();
    command.insert("type".into(), json!("get_state"));
    let response = runner.request(command).await.ok()?;
    if response.get("success") != Some(&Value::Bool(true)) {
        return None;
    }
    let data = response.get("data").filter(|data| truthy(data))?;
    let model = data.get("model").filter(|model| truthy(model)).map_or(
        Value::Null,
        |model| json!({ "provider": model.get("provider"), "id": model.get("id") }),
    );
    let thinking = data.get("thinkingLevel").cloned().unwrap_or(Value::Null);
    let mut agent = json!({ "model": model, "thinkingLevel": thinking });
    for key in ["approvalMode", "defaultApprovalMode"] {
        if let Some(mode) = data.get(key).filter(|mode| mode.is_string()) {
            agent[key] = mode.clone();
        }
    }
    Some(agent)
}

fn truthy(value: &Value) -> bool {
    pirc_config::text::truthy(Some(value))
}

async fn snapshot(node: Node, request: Request) -> ApiResult<Response> {
    let claimed = claim(&node, &request)?;
    let session_id = claimed.id.clone();
    let active = node.runners.get(&session_id);
    let mut agent = match &active {
        Some(runner) => live_agent(runner).await,
        None => None,
    };
    // Read after the RPCs: the runner may have started and bumped the epoch.
    let session = node.db.lock().get_session(&session_id)?;
    let sandbox = match &active {
        Some(runner) if runner.alive() => runner.sandbox_status(),
        _ => Value::Null,
    };
    // The live state, the pending dialogs, the run and the watermark as of
    // one point between two agent lines, the watermark last (TS read them
    // in one tick after its awaits).
    let read = |state: crate::runner::ReducedState| -> ApiResult<_> {
        let db = node.db.lock();
        let interactions = db.pending_interactions(&session_id)?;
        let run = db.latest_run(&session_id)?;
        drop(db);
        let watermark = node.events.watermark(&session_id, session.runner_epoch);
        Ok((state, interactions, run, watermark))
    };
    let (state, interactions, run, watermark) = match &active {
        Some(runner) => runner.state_at(read)?,
        None => read(crate::runner::ReducedState::default())?,
    };
    // History comes from the session file, not the agent: it is there with
    // no runner at all, and a long transcript never has to fit one line.
    // Read after the watermark: the agent writes each message before
    // announcing it, so the file is never behind the watermark (it may be
    // ahead, as in TS).
    let branch = node
        .branches
        .read(Path::new(&claimed.private_session_path))
        .map_err(|error| {
            crate::log::error(&format!("reading session {session_id}: {error}"));
            ApiError::internal()
        })?;
    let history =
        pirc_agent::session_store::read_session_history(Path::new(&claimed.private_session_path))
            .map_err(|error| {
            crate::log::error(&format!("reading session history {session_id}: {error}"));
            ApiError::internal()
        })?;
    // No live runner: the settings the next agent starts with, so the
    // client does not fall back to another model.
    if agent.is_none() {
        agent = next_agent_settings(&node, &session, &branch);
    }
    Ok(Response::json(json!({
        "session": session,
        "history": history,
        "partialMessage": state.partial_message,
        "operations": state.operations,
        "queue": state.queue,
        "run": run,
        "interactions": interactions,
        "notifications": state.notifications,
        "widgets": state.widgets,
        "statuses": state.statuses,
        "agent": agent,
        "watermark": watermark,
        "partialOutputLost": session.partial_output_lost,
        "sandbox": sandbox,
    })))
}

/// `sessionSettings(branch, loadAgentConfig(root, models))`, or `None` for
/// an invalid config (advisory only).
fn next_agent_settings(
    node: &Node,
    session: &SessionRow,
    branch: &[pirc_agent::session_store::SessionEntry],
) -> Option<Value> {
    let workspace = node.db.lock().get_workspace(&session.workspace_id).ok()?;
    let mode = node.workspace_mode(&workspace).ok()?;
    let root = chat::session_root(&workspace, &session.id, &mode).ok()?;
    let mode_json = serde_json::to_string(&mode).ok()?;
    let env = |name: &str| {
        if name == "PIRC_MODE" {
            Some(mode_json.clone())
        } else {
            node.env.get(name).map(str::to_owned)
        }
    };
    let config =
        pirc_agent::config::load_agent_config(&root.to_string_lossy(), node.models.current(), &env)
            .ok()?;
    let (model, thinking) =
        pirc_agent::config::session_settings(branch, config.default_model.as_ref(), &config.models);
    let default_mode = pirc_agent::auto_mode::default_approval_mode(&config.features);
    let mode = pirc_agent::auto_mode::recorded_approval_mode(branch).unwrap_or(default_mode);
    Some(json!({
        "model": model.map(|(provider, id)| json!({ "provider": provider, "id": id })),
        "thinkingLevel": thinking,
        "approvalMode": mode.as_str(),
        "defaultApprovalMode": default_mode.as_str(),
    }))
}

/// `deliverBody`: strict, with the lengths and patterns serde cannot check.
fn delivery(body: &Value) -> ApiResult<Delivery> {
    // `.optional()` refuses `null`, which serde would read as `None`.
    if let Value::Object(map) = body
        && ["details", "role", "model", "thinking"]
            .iter()
            .any(|key| map.get(*key).is_some_and(Value::is_null))
    {
        return Err(ApiError::invalid_input());
    }
    let delivery: Delivery = parse(body)?;
    // pots-dispatch is backend-only provenance. Do not add it to this
    // user-replayable route: pots::handle owns both the ledger and message.
    let role_ok = delivery.role.as_deref().is_none_or(|role| {
        let mut chars = role.chars();
        chars.next().is_some_and(|c| c.is_ascii_lowercase())
            && role.len() <= 40
            && chars.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_' || c == '-')
    });
    let ok = [
        "assistant-delegation",
        "assistant-delegation-update",
        "scheduled-run",
    ]
    .contains(&delivery.custom_type.as_str())
        && (1..=100_000).contains(&length(&delivery.content))
        && role_ok
        && delivery
            .model
            .as_ref()
            .is_none_or(|model| !model.provider.is_empty() && !model.id.is_empty())
        && delivery
            .thinking
            .as_deref()
            .is_none_or(|level| THINKING_LEVELS.contains(&level));
    if !ok {
        return Err(ApiError::invalid_input());
    }
    Ok(delivery)
}

/// The gateway pushes a message into a session: a delegated task, or news
/// of one. No control lease is needed or taken.
async fn deliver(node: Node, request: Request) -> ApiResult<Response> {
    let session = claim_mutable(&node, &request)?;
    let body = delivery(request.json())?;
    crate::pots::require_generic_input(&node.db.lock(), &session.id)?;
    node.runners.deliver(&session.id, &body).await?;
    Ok(Response::status(202, json!({ "delivered": true })))
}

fn hex_id(text: &str, len: usize) -> bool {
    text.len() == len
        && text
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// The gateway recalls a workspace-memory note the assistant found. Only
/// the owner of the session that wrote it may read it; a forgotten note
/// answers without its content.
async fn recall_workspace_memory(node: Node, request: Request) -> ApiResult<Response> {
    let map = object(request.json())?;
    strict(map, &["ledgerKey", "id"])?;
    let ledger_key = map.get("ledgerKey").and_then(Value::as_str).unwrap_or("");
    let id = map.get("id").and_then(Value::as_str).unwrap_or("");
    if !hex_id(ledger_key, 16) || !hex_id(id, 12) {
        return Err(ApiError::invalid_input());
    }
    use pirc_agent::features::memory::{recall, workspace};
    let ledger = workspace::WorkspaceLedger::new(
        node.config
            .workspace_memory_dir
            .to_string_lossy()
            .into_owned(),
        ledger_key.to_owned(),
        String::new(),
    );
    let fold = ledger.fold().map_err(|error| {
        crate::log::error(&format!("workspace memory {ledger_key}: {error}"));
        ApiError::internal()
    })?;
    let mut readable = true;
    if let Some(item) = fold.items.get(id) {
        let owner: Option<String> = node
            .db
            .lock()
            .query_row(
                "SELECT owner_user FROM sessions WHERE private_session_path=?1",
                [&item.session_dir],
                |row| row.get(0),
            )
            .ok()
            .flatten();
        readable = owner.as_deref() == Some(request.user.as_str());
    }
    let result = if readable {
        workspace::recall_from_workspace(&fold, id, recall).map_err(|error| {
            crate::log::error(&format!("workspace memory {ledger_key}: {error}"));
            ApiError::internal()
        })?
    } else {
        None
    };
    let Some((text, status)) = result else {
        return Err(ApiError::not_found(format!(
            "No workspace memory note {id}"
        )));
    };
    Ok(Response::json(json!({ "text": text, "status": status })))
}

/// `commandPayload`: the discriminated union, as zod outputs it (unknown
/// keys dropped), with its limits.
fn command_payload(value: &Value) -> ApiResult<CommandPayload> {
    let map = object(value)?;
    let kind = map
        .get("type")
        .and_then(Value::as_str)
        .ok_or_else(ApiError::invalid_input)?;
    let message = || string(map, "message", false, 1, 1_000_000);
    let upload_ids = || -> ApiResult<Option<Vec<String>>> {
        match map.get("uploadIds") {
            None => Ok(None),
            Some(Value::Array(items)) if items.len() <= 16 => items
                .iter()
                .map(|item| {
                    item.as_str()
                        .filter(|id| !id.is_empty())
                        .map(str::to_owned)
                        .ok_or_else(ApiError::invalid_input)
                })
                .collect::<ApiResult<Vec<_>>>()
                .map(Some),
            Some(_) => Err(ApiError::invalid_input()),
        }
    };
    Ok(match kind {
        "prompt" => CommandPayload::Prompt {
            message: message()?,
            upload_ids: upload_ids()?,
        },
        "steer" => CommandPayload::Steer {
            message: message()?,
            upload_ids: upload_ids()?,
        },
        "follow_up" => CommandPayload::FollowUp {
            message: message()?,
            upload_ids: upload_ids()?,
        },
        "edit_message" => CommandPayload::EditMessage {
            entry_id: string(map, "entryId", false, 1, 200)?,
            message: message()?,
        },
        "switch_branch" => CommandPayload::SwitchBranch {
            entry_id: string(map, "entryId", false, 1, 200)?,
        },
        "stop" => CommandPayload::Stop,
        "clear_queue" => CommandPayload::ClearQueue,
        "send_now" => CommandPayload::SendNow {
            queue: enumerated(map, "queue", &["steering", "followUp"])?,
            index: integer(map, "index", 0)? as u64,
            message: message()?,
        },
        "set_model" => CommandPayload::SetModel {
            provider: string(map, "provider", false, 1, usize::MAX)?,
            model_id: string(map, "modelId", false, 1, usize::MAX)?,
        },
        "set_thinking" => CommandPayload::SetThinking {
            level: enumerated(map, "level", &THINKING_LEVELS)?,
        },
        "set_approval_mode" => CommandPayload::SetApprovalMode {
            mode: enumerated(map, "mode", &["read-only", "auto", "full-access"])?,
        },
        _ => return Err(ApiError::invalid_input()),
    })
}

/// `{clientId, generation}` of a held control lease.
fn held_lease(map: &Map<String, Value>) -> ApiResult<(String, i64)> {
    Ok((
        string(map, "clientId", false, 1, usize::MAX)?,
        integer(map, "generation", 1)?,
    ))
}

async fn command(node: Node, request: Request) -> ApiResult<Response> {
    let session = claim(&node, &request)?;
    let map = object(request.json())?;
    let command_id = string(map, "commandId", false, 1, 200)?;
    let (client_id, generation) = held_lease(map)?;
    let payload = command_payload(map.get("payload").unwrap_or(&Value::Null))?;
    // Stopping is the only action allowed after a mode is removed.
    if !matches!(payload, CommandPayload::Stop) {
        crate::pots::require_generic_input(&node.db.lock(), &session.id)?;
        crate::session_creation::admission::require_generic(&node.db.lock(), &session.id)?;
        node.session_mode(&session.id)?;
    }
    let stored = serde_json::to_value(&payload).unwrap_or_default();
    let (row, duplicate, initial_stop) = {
        let mut db = node.db.lock();
        let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        tx.validate_lease(&session.id, &client_id, generation)?;
        let (row, duplicate) =
            tx.receive_command(&command_id, &session.id, &payload_hash(&stored), &stored)?;
        crate::command_environment::record(
            &tx,
            &command_id,
            if matches!(payload, CommandPayload::Stop) {
                None
            } else {
                map.get("commandEnvironment")
            },
            duplicate,
        )?;
        let initial_stop = !duplicate
            && matches!(payload, CommandPayload::Stop)
            && crate::session_creation::admission::request_stop(&tx, &session.id, &request.user)?;
        tx.commit()?;
        (row, duplicate, initial_stop)
    };
    if duplicate {
        return Ok(Response::json(json!({ "command": row, "duplicate": true })));
    }
    if initial_stop && node.runners.get(&session.id).is_none_or(|r| !r.alive()) {
        // A missing runner does not prove its approved host work settled. Join
        // the independent supervisor before confirming the initial Stop receipt.
        if let Err(error) = node.runners.stop_session(&session.id).await {
            node.db.lock().update_command(
                &command_id,
                crate::store::CommandStatus::OutcomeUnknown,
                None,
                Some(&error.message),
            )?;
            return Err(error);
        }
        let db = node.db.lock();
        db.update_command(
            &command_id,
            crate::store::CommandStatus::Accepted,
            Some(&json!({"success":true,"data":{"cleared":0}})),
            None,
        )?;
        crate::session_creation::admission::confirm_stop(&db, &session.id)?;
        return Ok(Response::status(
            202,
            json!({"command":db.get_command(&command_id)?,"duplicate":false,"initialAdmission":crate::session_creation::admission::stop_receipt(&db,&session.id,&request.user)?}),
        ));
    }
    node.runners
        .dispatch(
            &session.id,
            &command_id,
            &payload,
            &request.user,
            (&client_id, generation),
        )
        .await?;
    let command = node.db.lock().get_command(&command_id)?;
    if initial_stop && command.status == crate::store::CommandStatus::Accepted {
        crate::session_creation::admission::confirm_stop(&node.db.lock(), &session.id)?;
    }
    let status = if command.status == crate::store::CommandStatus::Accepted {
        202
    } else {
        503
    };
    let mut body = json!({ "command": command, "duplicate": false });
    if initial_stop {
        body["initialAdmission"] = crate::session_creation::admission::stop_receipt(
            &node.db.lock(),
            &session.id,
            &request.user,
        )?;
    }
    Ok(Response::status(status, body))
}

async fn control(node: Node, request: Request) -> ApiResult<Response> {
    let session = claim(&node, &request)?;
    let lease = node.db.lock().get_lease(&session.id)?;
    Ok(Response::json(json!({ "lease": lease })))
}

async fn acquire(node: Node, request: Request) -> ApiResult<Response> {
    // Control is separate from execution: keep Stop/reconciliation reachable.
    let session = claim(&node, &request)?;
    node.session_mode_for_control(&session.id)?;
    let map = object(request.json())?;
    let client_id = string(map, "clientId", false, 1, 200)?;
    if map.contains_key("generation") {
        integer(map, "generation", 0)?;
    }
    let force = optional_bool(map, "force")?.unwrap_or(false);
    let lease =
        node.db
            .lock()
            .acquire_lease(&session.id, &client_id, force, node.config.lease_ttl_ms)?;
    Ok(Response::json(json!({ "lease": lease })))
}

/// `heldLeaseBody`: `leaseBody` with a positive generation.
fn held_lease_body(body: &Value) -> ApiResult<(String, i64)> {
    let map = object(body)?;
    let client_id = string(map, "clientId", false, 1, 200)?;
    let generation = integer(map, "generation", 1)?;
    optional_bool(map, "force")?;
    Ok((client_id, generation))
}

async fn heartbeat(node: Node, request: Request) -> ApiResult<Response> {
    // Control is separate from execution: keep Stop/reconciliation reachable.
    let session = claim(&node, &request)?;
    node.session_mode_for_control(&session.id)?;
    let (client_id, generation) = held_lease_body(request.json())?;
    let lease = node.db.lock().heartbeat_lease(
        &session.id,
        &client_id,
        generation,
        node.config.lease_ttl_ms,
    )?;
    Ok(Response::json(json!({ "lease": lease })))
}

async fn release(node: Node, request: Request) -> ApiResult<Response> {
    // Control is separate from execution: keep Stop/reconciliation reachable.
    let session = claim(&node, &request)?;
    node.session_mode_for_control(&session.id)?;
    let (client_id, generation) = held_lease_body(request.json())?;
    node.db
        .lock()
        .release_lease(&session.id, &client_id, generation)?;
    Ok(Response::empty(204))
}

/// `answerBody.answer`: the first branch of the union that fits, as zod
/// outputs it.
fn interaction_answer(value: &Value) -> ApiResult<Map<String, Value>> {
    let map = object(value)?;
    let mut answer = Map::new();
    if map.get("cancelled") == Some(&Value::Bool(true)) {
        answer.insert("cancelled".into(), Value::Bool(true));
        return Ok(answer);
    }
    if let Some(Value::String(text)) = map.get("value") {
        let values = match map.get("values") {
            None => None,
            Some(Value::Array(items))
                if items.len() <= 64 && items.iter().all(Value::is_string) =>
            {
                Some(Value::Array(items.clone()))
            }
            Some(_) => None,
        };
        // A bad `values` fails this branch; the next may still fit.
        if values.is_some() || !map.contains_key("values") {
            answer.insert("value".into(), Value::String(text.clone()));
            if let Some(values) = values {
                answer.insert("values".into(), values);
            }
            return Ok(answer);
        }
    }
    if let Some(Value::Bool(confirmed)) = map.get("confirmed") {
        answer.insert("confirmed".into(), Value::Bool(*confirmed));
        return Ok(answer);
    }
    Err(ApiError::invalid_input())
}

async fn answer(node: Node, request: Request) -> ApiResult<Response> {
    let session = claim_mutable(&node, &request)?;
    let interaction_id = param(&request, "interactionId").to_owned();
    let map = object(request.json())?;
    let (client_id, generation) = held_lease(map)?;
    let answer = interaction_answer(map.get("answer").unwrap_or(&Value::Null))?;
    node.db
        .lock()
        .validate_lease(&session.id, &client_id, generation)?;
    answer_interaction(&node, &session, &interaction_id, answer).await
}

/// The gateway relays the session owner's answer from the chat that
/// delegated this session's task, without a control lease (the gateway
/// checks the user and the delegation; docs/architecture/security-decisions.md).
/// Only a confirmation's yes or no.
async fn relayed_answer(node: Node, request: Request) -> ApiResult<Response> {
    let session = claim_mutable(&node, &request)?;
    let interaction_id = param(&request, "interactionId").to_owned();
    let map = object(request.json())?;
    let answer = interaction_answer(map.get("answer").unwrap_or(&Value::Null))?;
    let confirm = node.db.lock().get_interaction(&interaction_id)?.kind == "confirm";
    if !confirm || !answer.get("confirmed").is_some_and(Value::is_boolean) {
        return Err(ApiError::invalid_input());
    }
    answer_interaction(&node, &session, &interaction_id, answer).await
}

async fn answer_interaction(
    node: &Node,
    session: &SessionRow,
    interaction_id: &str,
    answer: Map<String, Value>,
) -> ApiResult<Response> {
    let active = node
        .runners
        .get(&session.id)
        .filter(|active| active.epoch() == session.runner_epoch)
        .ok_or_else(|| {
            ApiError::new(
                409,
                "stale_interaction",
                "Interaction belongs to an inactive runner",
            )
        })?;
    let epoch = active.epoch();
    let interaction = node.db.lock().claim_interaction(
        interaction_id,
        &session.id,
        epoch,
        &Value::Object(answer.clone()),
    )?;
    // Publishes `interaction_answered` before the answer goes on.
    node.runners
        .answer(
            &session.id,
            epoch,
            &interaction.rpc_id,
            &interaction.id,
            &answer,
        )
        .await?;
    Ok(Response::json(
        json!({ "interactionId": interaction.id, "status": "answered" }),
    ))
}

/// The image type of `bytes` by its signature (`sniffImage`).
fn sniff_image(bytes: &[u8]) -> Option<&'static str> {
    if bytes.starts_with(&[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) {
        Some("image/png")
    } else if bytes.starts_with(&[0xff, 0xd8, 0xff]) {
        Some("image/jpeg")
    } else if bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a") {
        Some("image/gif")
    } else if bytes.len() >= 12 && &bytes[..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        Some("image/webp")
    } else {
        None
    }
}

/// Shared by legacy uploads and durable first-send transfers.
pub(crate) fn classify_upload(
    bytes: &[u8],
    declared: &str,
    filename: Option<&str>,
) -> ApiResult<(String, UploadKind, Option<String>)> {
    Ok(match sniff_image(bytes) {
        Some(sniffed) => {
            if !declared.is_empty() && declared != "application/octet-stream" && declared != sniffed
            {
                return Err(ApiError::bad_request(
                    "Declared Content-Type does not match image content",
                ));
            }
            (sniffed.to_owned(), UploadKind::Image, None)
        }
        None => {
            let Some(filename) = filename else {
                return Err(ApiError::bad_request(
                    "filename is required for non-image uploads",
                ));
            };
            let base = filename
                .split('/')
                .rfind(|part| !part.is_empty())
                .unwrap_or_default();
            let cleaned = chat::js_trim(base);
            if cleaned.is_empty() {
                return Err(ApiError::bad_request("filename is invalid"));
            }
            let mime = if declared.is_empty() {
                "application/octet-stream".to_owned()
            } else {
                declared.to_owned()
            };
            (mime, UploadKind::File, Some(cleaned.to_owned()))
        }
    })
}

/// Images and generic files are stored on the node that runs the
/// session's agent.
async fn upload(node: Node, request: Request) -> ApiResult<Response> {
    let session = claim_mutable(&node, &request)?;
    let Body::Raw {
        bytes,
        content_type,
    } = &request.body
    else {
        return Err(ApiError::bad_request("Upload body must be raw bytes"));
    };
    if bytes.is_empty() || bytes.len() > node.config.upload_max_bytes {
        return Err(ApiError::new(
            413,
            "payload_too_large",
            "Upload exceeds configured limit",
        ));
    }
    let query = request.query_object();
    let query = object(&query)?;
    let filename = optional_string(query, "filename", true, 1, 255)?;
    // `headers['content-type'].split(';', 1)[0]`, untrimmed.
    let declared = content_type.split(';').next().unwrap_or_default();
    let (mime_type, kind, filename) = classify_upload(bytes, declared, filename.as_deref())?;
    let upload = UploadRow {
        id: prefix_uuid("upload"),
        owner_user: request.user.clone(),
        mime_type,
        byte_size: bytes.len() as i64,
        storage_name: format!("{}.bin", hex(&random_bytes::<24>())),
        sha256: sha256_hex(bytes),
        kind,
        filename,
        workspace_id: Some(session.workspace_id.clone()),
        session_id: Some(session.id.clone()),
    };
    let file = node.config.uploads_dir.join(&upload.storage_name);
    OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&file)
        .and_then(|mut out| out.write_all(bytes))
        .map_err(|error| io_failure("writing", &file, error))?;
    {
        // The chat (or its project) may have been fenced for deletion while
        // the bytes were written: keep nothing then.
        let db = node.db.lock();
        if let Err(error) = db
            .require_session_available(&session.id)
            .and_then(|()| db.get_workspace(&session.workspace_id).map(drop))
            .and_then(|()| db.create_upload(&upload))
        {
            let _ = std::fs::remove_file(&file);
            return Err(error);
        }
    }
    created(json!({ "upload": {
        "id": upload.id,
        "mimeType": upload.mime_type,
        "byteSize": upload.byte_size,
        "kind": upload.kind,
        "filename": upload.filename,
    } }))
}

/// `applySessionName` (`session-name.ts`): persist a name the agent
/// reported or the user chose and publish `session_renamed`; a generated
/// (`auto`) title never replaces a user's name. Used by the runner
/// (`session_name_changed`) and the rename route.
pub fn apply_session_name(
    node: &Node,
    session_id: &str,
    epoch: i64,
    data: &Value,
) -> ApiResult<()> {
    let name = data["name"]
        .as_str()
        .map(|name| head16(chat::js_trim(name), 200))
        .unwrap_or_default();
    if name.is_empty() {
        return Ok(());
    }
    let auto = data["source"] == "auto";
    {
        let db = node.db.lock();
        if auto {
            if !db.auto_rename_session(session_id, name)? {
                return Ok(());
            }
        } else {
            let session = db.get_session(session_id)?;
            if session.name == name && session.name_source == NameSource::User {
                return Ok(());
            }
            db.rename_session(session_id, name)?;
        }
    }
    node.events.publish(
        session_id,
        epoch,
        "session_renamed",
        json!({ "name": name, "source": if auto { "auto" } else { "user" } }),
    );
    Ok(())
}

#[cfg(test)]
pub(crate) mod tests;
