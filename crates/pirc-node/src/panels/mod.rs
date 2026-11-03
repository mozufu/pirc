//! The side panels' routes (`node/panel-routes.ts`): git and files,
//! panel state and context, background tasks, terminals and the browser
//! recording. Owner: **panels**.
//!
//! Every route here goes through `local` of TS: claim the session (owner
//! check, not being deleted), then `chat::session_root` (which creates a
//! chat session's directory, even for a GET). Terminal routes check
//! `config.terminals_enabled` first (403 "Terminals are disabled on this
//! node"), before the claim. Golden cases: `panel.integration.test.ts`,
//! `context-panel.integration.test.ts`.
//!
//! Request validation reproduces the zod schemas: query numbers are
//! `z.coerce.number()` (JS `Number(text)`, so `?limit=` is 0), lengths are
//! UTF-16 units, and every failure is 400 `invalid_input` "Invalid request".

mod access;
pub mod inspect;

use std::path::{Path, PathBuf};
use std::sync::LazyLock;

use pirc_agent::session_store::EntryData;
use pirc_agent::tools::js::{len16, string_of, truthy};
use pirc_protocol::RECORDING_CHUNK_BYTES;
use regex_lite::Regex;
use serde_json::{Map, Value, json};

use crate::error::{ApiError, ApiResult};
use crate::router::{Request, Response, Route, get, post};
use crate::services::Node;
use crate::store::{SessionRow, Store as _};

/// The panel routes, merged with core's by the router:
///
/// - `GET /api/sessions/:id/git/status`, `.../git/diff`, `.../git/log`,
///   `.../git/commits/:sha`
/// - `GET /api/sessions/:id/files`, `.../files/content`
/// - `GET /api/sessions/:id/panel/state`, `.../panel/context`,
///   `.../panel/background/:taskId`, `POST .../panel/background/:taskId/stop`
/// - `GET /api/sessions/:id/terminals`, `POST .../terminals`,
///   `POST .../terminals/:terminalId/close`
/// - `GET /api/sessions/:id/browser/recording` (reads files only; no browser)
pub fn routes() -> Vec<Route> {
    vec![
        get("/api/sessions/:id/git/status", |node, request| async move {
            let local = local(&node, &request)?;
            let env = child_env(&node);
            Ok(Response::json(
                local
                    .access
                    .inspect(inspect::git_status(&*node.sandbox, &local.root, &env))
                    .await?,
            ))
        }),
        get("/api/sessions/:id/git/diff", |node, request| async move {
            let local = local(&node, &request)?;
            let path = optional_string(&request, "path", 0, 4096)?;
            let staged = flag(&request, "staged")?;
            let untracked = flag(&request, "untracked")?;
            let env = child_env(&node);
            let diff = local
                .access
                .inspect(inspect::git_diff(
                    &*node.sandbox,
                    &local.root,
                    &env,
                    path.as_deref(),
                    staged,
                    untracked,
                ))
                .await?;
            Ok(Response::json(diff))
        }),
        get("/api/sessions/:id/git/log", |node, request| async move {
            let local = local(&node, &request)?;
            let skip = coerce_int(&request, "skip", 0.0, 1_000_000.0, 0.0)?;
            let limit = coerce_int(&request, "limit", 1.0, 200.0, 50.0)?;
            let env = child_env(&node);
            let log = local
                .access
                .inspect(inspect::git_log(
                    &*node.sandbox,
                    &local.root,
                    &env,
                    skip as u64,
                    limit as u64,
                ))
                .await?;
            Ok(Response::json(log))
        }),
        get(
            "/api/sessions/:id/git/commits/:sha",
            |node, request| async move {
                let local = local(&node, &request)?;
                let sha = request.param("sha").unwrap_or_default();
                if !(4..=64).contains(&len16(sha)) {
                    return Err(ApiError::invalid_input());
                }
                let env = child_env(&node);
                Ok(Response::json(
                    local
                        .access
                        .inspect(inspect::git_show(&*node.sandbox, &local.root, &env, sha))
                        .await?,
                ))
            },
        ),
        get("/api/sessions/:id/files", |node, request| async move {
            let local = local(&node, &request)?;
            let path = optional_string(&request, "path", 0, 4096)?.unwrap_or_default();
            Ok(Response::json(
                local
                    .access
                    .run(|| inspect::list_directory(&local.root, &path))?,
            ))
        }),
        get(
            "/api/sessions/:id/files/content",
            |node, request| async move {
                let local = local(&node, &request)?;
                let path = optional_string(&request, "path", 1, 4096)?
                    .ok_or_else(ApiError::invalid_input)?;
                Ok(Response::json(local.access.run(|| {
                    inspect::read_workspace_file(&local.root, &path)
                })?))
            },
        ),
        get(
            "/api/sessions/:id/panel/state",
            |node, request| async move {
                let local = local(&node, &request)?;
                local
                    .access
                    .inspect(panel_state(&node, &local))
                    .await
                    .map(Response::json)
            },
        ),
        get(
            "/api/sessions/:id/panel/context",
            |node, request| async move {
                let local = local(&node, &request)?;
                local
                    .access
                    .inspect(panel_context(&node, &local))
                    .await
                    .map(Response::json)
            },
        ),
        get(
            "/api/sessions/:id/panel/background/:taskId",
            |node, request| async move {
                let local = local(&node, &request)?;
                let task_id = task_id(&request)?;
                let lines = coerce_int(&request, "lines", 1.0, 2000.0, 400.0)?;
                let runner = live_runner(&node, &local.session.id)?;
                let mut command = Map::new();
                command.insert("type".into(), json!("background_output"));
                command.insert("taskId".into(), json!(task_id));
                command.insert("lines".into(), json!(lines as u64));
                local
                    .access
                    .inspect(async { background_answer(runner.request(command).await?) })
                    .await
            },
        ),
        // Stopping a background task needs the control lease, like prompting
        // the agent. Only the claim here, not `local` (TS).
        post(
            "/api/sessions/:id/panel/background/:taskId/stop",
            |node, request| async move {
                let session = claim(&node, &request)?;
                let task_id = task_id(&request)?;
                let (client_id, generation) = lease_body(request.json())?;
                node.db
                    .lock()
                    .validate_lease(&session.id, &client_id, generation)?;
                let runner = live_runner(&node, &session.id)?;
                let mut command = Map::new();
                command.insert("type".into(), json!("background_stop"));
                command.insert("taskId".into(), json!(task_id));
                background_answer(runner.request(command).await?)
            },
        ),
        get("/api/sessions/:id/terminals", |node, request| async move {
            let session = terminal_session(&node, &request)?;
            Ok(Response::json(
                json!({ "terminals": node.terminals.list(&session.id) }),
            ))
        }),
        post("/api/sessions/:id/terminals", |node, request| async move {
            let session = terminal_session(&node, &request)?;
            let body = request.json();
            let (client_id, generation) = lease_body(body)?;
            let cols = optional_int(body, "cols")?;
            let rows = optional_int(body, "rows")?;
            node.db
                .lock()
                .validate_lease(&session.id, &client_id, generation)?;
            let workspace = node.db.lock().get_workspace(&session.workspace_id)?;
            let cwd = crate::chat::session_root(
                &workspace,
                &session.id,
                &node.workspace_mode(&workspace)?,
            )?;
            let terminal = node.terminals.create(
                &session.id,
                &cwd,
                Some(cols.unwrap_or(80)),
                Some(rows.unwrap_or(24)),
                (&client_id, generation),
            )?;
            Ok(Response::status(201, json!({ "terminal": terminal })))
        }),
        post(
            "/api/sessions/:id/terminals/:terminalId/close",
            |node, request| async move {
                let session = terminal_session(&node, &request)?;
                // zod's `min(1)`: the router never matches an empty segment.
                let terminal_id = request.param("terminalId").unwrap_or_default().to_owned();
                let (client_id, generation) = lease_body(request.json())?;
                node.db
                    .lock()
                    .validate_lease(&session.id, &client_id, generation)?;
                node.terminals.close(&session.id, &terminal_id)?;
                Ok(Response::empty(204))
            },
        ),
        get(
            "/api/sessions/:id/browser/recording",
            |node, request| async move {
                let local = local(&node, &request)?;
                let path = request
                    .single_query("path")?
                    .filter(|path| RECORDING_PATH.is_match(path))
                    .ok_or_else(ApiError::invalid_input)?
                    .to_owned();
                let offset = coerce_int(&request, "offset", 0.0, f64::INFINITY, 0.0)?;
                let chunk = RECORDING_CHUNK_BYTES as f64;
                let length = coerce_int(&request, "length", 1.0, chunk, chunk)?;
                Ok(Response::json(local.access.run(|| {
                    inspect::read_recording_chunk(&local.root, &path, offset as u64, length as u64)
                })?))
            },
        ),
    ]
}

static RECORDING_PATH: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^\.pirc/recordings/[A-Za-z0-9_.-]{1,200}\.webm$").expect("recording regex")
});

/// What `local` gives a handler: the claimed session and where it works.
struct Local {
    access: access::Access,
    session: SessionRow,
    root: PathBuf,
}

/// `claim(request)` of `node/app.ts`: the session, owned by the request's
/// user and not being deleted.
fn claim(node: &Node, request: &Request) -> ApiResult<SessionRow> {
    let id = request.param("id").unwrap_or_default();
    node.db.lock().claim_session(id, &request.user, false)
}

fn local(node: &Node, request: &Request) -> ApiResult<Local> {
    let db = node.db.lock();
    let session = db.claim_session(
        request.param("id").unwrap_or_default(),
        &request.user,
        false,
    )?;
    crate::execution_fences::require_open(&db, &session.id)?;
    let workspace = db.get_workspace(&session.workspace_id)?;
    let mode = node.workspace_mode(&workspace)?;
    let access = access::Access::new(
        node.clone(),
        request.user.clone(),
        session.clone(),
        workspace.clone(),
        mode.clone(),
    );
    drop(db);
    let root = access.run(|| crate::chat::session_root(&workspace, &session.id, &mode))?;
    Ok(Local {
        access,
        session,
        root,
    })
}

fn terminals_enabled(node: &Node) -> ApiResult<()> {
    if node.config.terminals_enabled {
        Ok(())
    } else {
        Err(ApiError::forbidden("Terminals are disabled on this node"))
    }
}

/// Terminals enabled, then the claim (that order: TS).
fn terminal_session(node: &Node, request: &Request) -> ApiResult<SessionRow> {
    terminals_enabled(node)?;
    claim(node, request)
}

/// The environment of git and terminals: the node's, without secrets.
fn child_env(node: &Node) -> inspect::ChildEnv {
    pirc_config::env_allowlist::without_secrets(&node.env, &[])
}

/// The session's runner while it lives, else 409 `runner_unavailable`
/// "The agent is not running".
fn live_runner(node: &Node, session_id: &str) -> ApiResult<std::sync::Arc<crate::runner::Runner>> {
    node.runners
        .get(session_id)
        .filter(|runner| runner.alive())
        .ok_or_else(|| ApiError::new(409, "runner_unavailable", "The agent is not running"))
}

/// A background RPC's answer: its `data`, or 404 with the agent's error.
fn background_answer(response: Map<String, Value>) -> ApiResult<Response> {
    if !truthy(response.get("success")) {
        let message = match response.get("error") {
            None | Some(Value::Null) => "Background task not found".to_owned(),
            Some(error) => string_of(error),
        };
        return Err(ApiError::not_found(message));
    }
    // `return response.data`: undefined is an empty 200.
    Ok(match response.get("data") {
        Some(data) => Response::json(data.clone()),
        None => Response {
            status: 200,
            body: None,
        },
    })
}

/// `taskId` (1..100 UTF-16 units).
fn task_id(request: &Request) -> ApiResult<String> {
    let task_id = request.param("taskId").unwrap_or_default();
    if !(1..=100).contains(&len16(task_id)) {
        return Err(ApiError::invalid_input());
    }
    Ok(task_id.to_owned())
}

// ---------------------------------------------------------------------------
// panel state and context

/// `GET .../panel/state`: memory from the session file (so it works while
/// the agent is stopped), plus live feature state when the agent runs.
/// Every failure of the live part or the configuration is swallowed.
async fn panel_state(node: &Node, local: &Local) -> ApiResult<Value> {
    let runner = node.runners.get(&local.session.id);
    let mut live = Map::new();
    let mut context_window: Option<u64> = None;
    if let Some(runner) = runner.as_ref().filter(|runner| runner.alive()) {
        let command = |kind: &str| {
            let mut command = Map::new();
            command.insert("type".into(), json!(kind));
            command
        };
        let (panel, state) = tokio::join!(
            runner.request(command("get_panel_state")),
            runner.request(command("get_state")),
        );
        if let Ok(panel) = panel
            && truthy(panel.get("success"))
            && let Some(Value::Object(data)) = panel.get("data")
        {
            live = data.clone();
        }
        if let Ok(state) = state
            && truthy(state.get("success"))
        {
            context_window = state
                .get("data")
                .and_then(|data| data.pointer("/model/contextWindow"))
                .and_then(Value::as_f64)
                .map(|window| window as u64);
        }
    }
    let branch = access::run(|| {
        node.branches
            .read(Path::new(&local.session.private_session_path))
            .map_err(|error| {
                crate::log::error(&format!("session branch: {error}"));
                ApiError::internal()
            })
    })?;
    let mut features = Map::new();
    let env = |name: &str| node.env.get(name).map(str::to_owned);
    // An invalid configuration falls back to the defaults.
    if let Ok(config) = access::run(|| {
        Ok(pirc_agent::config::load_agent_config(
            &local.root.to_string_lossy(),
            node.models.current(),
            &env,
        ))
    })? {
        features = config.features.clone();
        // A stopped agent: the session's current model decides a ratio-mode
        // threshold.
        if context_window.is_none() {
            let change = branch.iter().rev().find_map(|entry| match &entry.data {
                EntryData::ModelChange { provider, model_id } => {
                    Some((provider.clone(), model_id.clone()))
                }
                _ => None,
            });
            let reference = change.or_else(|| {
                config
                    .default_model
                    .as_ref()
                    .map(|model| (model.provider.clone(), model.id.clone()))
            });
            context_window = reference.and_then(|(provider, id)| {
                config
                    .models
                    .providers
                    .get(&provider)?
                    .models
                    .iter()
                    .find(|model| model.id == id)
                    .map(|model| model.context_window)
            });
        }
    }
    let memory = pirc_agent::features::memory::panel::memory_panel(
        &branch,
        &pirc_agent::features::memory::config::memory_config_from(&features),
        context_window,
    );
    let or = |key: &str, fallback: Value| match live.get(key) {
        None | Some(Value::Null) => fallback,
        Some(value) => value.clone(),
    };
    Ok(json!({
        "agentRunning": runner.is_some_and(|runner| runner.alive()),
        "memory": memory,
        "memoryRuntime": or("memoryRuntime", Value::Null),
        "workspaceMemory":or("workspaceMemory",Value::Null),
        "backgroundTasks": or("backgroundTasks", json!([])),
        "team": or("team", json!({ "agents": [] })),
    }))
}

/// `GET .../panel/context`: the live agent's context, else the last
/// snapshot on disk (404 `no_context` without one); sections whose source
/// is a readable file of the workspace get its `filePath`.
async fn panel_context(node: &Node, local: &Local) -> ApiResult<Value> {
    let runner = node.runners.get(&local.session.id);
    let mut snapshot = None;
    if let Some(runner) = runner.as_ref().filter(|runner| runner.alive()) {
        let mut command = Map::new();
        command.insert("type".into(), json!("get_context"));
        command.insert(
            "maxBytes".into(),
            json!(node.config.rpc_max_line_bytes.saturating_sub(1024)),
        );
        // A stopped or older agent can still have a disk snapshot.
        if let Ok(response) = runner.request(command).await
            && truthy(response.get("success"))
            && truthy(response.get("data"))
        {
            snapshot = response.get("data").cloned();
        }
    }
    access::run(|| {
        let live = snapshot.is_some();
        let snapshot = match snapshot {
            Some(snapshot) => snapshot,
            None => {
                pirc_agent::context::read_context(Path::new(&local.session.private_session_path))
                    .map_err(|error| {
                        crate::log::error(&format!("context snapshot: {error}"));
                        ApiError::internal()
                    })?
                    .ok_or_else(|| {
                        ApiError::new(
                            404,
                            "no_context",
                            "Send a message first to inspect its context",
                        )
                    })?
            }
        };
        let Value::Object(mut snapshot) = snapshot else {
            crate::log::error("context snapshot: not an object");
            return Err(ApiError::internal());
        };
        let Some(Value::Array(sections)) = snapshot.get("sections") else {
            crate::log::error("context snapshot: no sections");
            return Err(ApiError::internal());
        };
        let sections: Vec<Value> = sections
            .iter()
            .map(|section| link_section(&local.root, section))
            .collect();
        // `{...snapshot, sections}`: the key keeps its place.
        snapshot.insert("sections".into(), Value::Array(sections));
        Ok(json!({
            "snapshot": snapshot,
            "agentRunning": runner.is_some_and(|runner| runner.alive()),
            "source": if live { "live" } else { "snapshot" },
        }))
    })
}

/// A section whose absolute `source` is a readable regular file inside the
/// workspace, with `filePath` relative to it; any other unchanged.
fn link_section(root: &Path, section: &Value) -> Value {
    let Some(source) = section.get("source").and_then(Value::as_str) else {
        return section.clone();
    };
    if !source.starts_with('/') {
        return section.clone();
    }
    let linked = || -> Option<Value> {
        let root = std::fs::canonicalize(root).ok()?;
        let file = std::fs::canonicalize(source).ok()?;
        if !file.starts_with(&root) || !std::fs::metadata(&file).ok()?.is_file() {
            return None;
        }
        // `accessSync(file, R_OK)`.
        nix::unistd::access(&file, nix::unistd::AccessFlags::R_OK).ok()?;
        let relative =
            pirc_agent::tools::js::relative(&root.to_string_lossy(), &file.to_string_lossy());
        let mut section = section.as_object()?.clone();
        section.insert("filePath".into(), json!(relative));
        Some(Value::Object(section))
    };
    linked().unwrap_or_else(|| section.clone())
}

// ---------------------------------------------------------------------------
// validation (zod, as the routes used it)

/// A string query parameter of `min..=max` UTF-16 units; `None` when absent.
fn optional_string(
    request: &Request,
    name: &str,
    min: usize,
    max: usize,
) -> ApiResult<Option<String>> {
    match request.single_query(name)? {
        None => Ok(None),
        Some(value) if (min..=max).contains(&len16(value)) => Ok(Some(value.to_owned())),
        Some(_) => Err(ApiError::invalid_input()),
    }
}

/// `z.enum(['1','0','true','false']).optional()`, true for `1` and `true`.
fn flag(request: &Request, name: &str) -> ApiResult<bool> {
    match request.single_query(name)? {
        None => Ok(false),
        Some("1" | "true") => Ok(true),
        Some("0" | "false") => Ok(false),
        Some(_) => Err(ApiError::invalid_input()),
    }
}

/// `z.coerce.number().int().min(min).max(max).default(fallback)`.
fn coerce_int(request: &Request, name: &str, min: f64, max: f64, fallback: f64) -> ApiResult<f64> {
    let Some(text) = request.single_query(name)? else {
        return Ok(fallback);
    };
    let number = js_number_of_str(text);
    if number.is_finite() && number.fract() == 0.0 && number >= min && number <= max {
        Ok(number)
    } else {
        Err(ApiError::invalid_input())
    }
}

/// `leaseBody`: `{clientId: string 1..200, generation: positive int}`.
fn lease_body(body: &Value) -> ApiResult<(String, i64)> {
    let object = body.as_object().ok_or_else(ApiError::invalid_input)?;
    let client_id = object
        .get("clientId")
        .and_then(Value::as_str)
        .filter(|id| (1..=200).contains(&len16(id)))
        .ok_or_else(ApiError::invalid_input)?;
    let generation = object
        .get("generation")
        .and_then(Value::as_f64)
        .filter(|g| g.fract() == 0.0 && *g > 0.0)
        .ok_or_else(ApiError::invalid_input)?;
    // Past i64 no lease matches; saturating keeps it a mismatch.
    Ok((client_id.to_owned(), generation as i64))
}

/// `z.number().int().optional()` of a body field.
fn optional_int(body: &Value, name: &str) -> ApiResult<Option<i64>> {
    match body.get(name) {
        None => Ok(None),
        Some(value) => value
            .as_f64()
            .filter(|n| n.fract() == 0.0)
            .map(|n| Some(n as i64))
            .ok_or_else(ApiError::invalid_input),
    }
}

// ---------------------------------------------------------------------------
// JS number coercion

static DECIMAL: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?$").expect("decimal regex")
});

/// A decimal number in text (whitespace trimmed); anything else is NaN.
pub(crate) fn js_number_of_str(text: &str) -> f64 {
    let text = text.trim();
    if DECIMAL.is_match(text) {
        text.parse().unwrap_or(f64::NAN)
    } else {
        f64::NAN
    }
}

/// A JSON number, or a decimal number in a string; anything else is NaN.
pub(crate) fn js_number(value: Option<&Value>) -> f64 {
    match value {
        Some(Value::Number(n)) => n.as_f64().unwrap_or(f64::NAN),
        Some(Value::String(s)) => js_number_of_str(s),
        _ => f64::NAN,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn numbers_are_decimal_only() {
        for (text, expected) in [
            ("  12 ", 12.0),
            ("1e2", 100.0),
            ("1.", 1.0),
            (".5", 0.5),
            ("-3", -3.0),
            ("+4", 4.0),
        ] {
            assert_eq!(js_number_of_str(text), expected, "{text:?}");
        }
        for text in [
            "", "x", "inf", "NaN", "0x1A", "0b11", "Infinity", "1e", "1 2", "--1",
        ] {
            assert!(js_number_of_str(text).is_nan(), "{text:?}");
        }
        assert_eq!(js_number(Some(&json!(7))), 7.0);
        assert_eq!(js_number(Some(&json!("7"))), 7.0);
        for value in [json!(null), json!(true), json!([7]), json!({})] {
            assert!(js_number(Some(&value)).is_nan(), "{value}");
        }
        assert!(js_number(None).is_nan());
    }

    #[test]
    fn lease_bodies() {
        assert_eq!(
            lease_body(&json!({ "clientId": "b", "generation": 2, "x": 1 })),
            Ok(("b".to_owned(), 2))
        );
        for body in [
            json!(null),
            json!({}),
            json!({ "clientId": "", "generation": 1 }),
            json!({ "clientId": "b", "generation": 0 }),
            json!({ "clientId": "b", "generation": 1.5 }),
            json!({ "clientId": "b", "generation": "1" }),
            json!({ "clientId": "b".repeat(201), "generation": 1 }),
        ] {
            assert_eq!(lease_body(&body), Err(ApiError::invalid_input()), "{body}");
        }
        assert_eq!(optional_int(&json!({ "cols": 3.0 }), "cols"), Ok(Some(3)));
        assert_eq!(optional_int(&json!({}), "cols"), Ok(None));
        assert!(optional_int(&json!({ "cols": null }), "cols").is_err());
        assert!(optional_int(&json!({ "cols": "wide" }), "cols").is_err());
    }

    #[test]
    fn links_sections_to_workspace_files() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        std::fs::write(root.join("AGENTS.md"), "x").unwrap();
        let inside = json!({ "id": "a", "source": root.join("AGENTS.md").display().to_string() });
        assert_eq!(link_section(&root, &inside)["filePath"], json!("AGENTS.md"));
        for section in [
            json!({ "id": "b", "source": "AGENTS.md" }),
            json!({ "id": "c", "source": "/etc/hostname" }),
            json!({ "id": "d", "source": root.display().to_string() }),
            json!({ "id": "e", "source": root.join("missing").display().to_string() }),
            json!({ "id": "f" }),
        ] {
            assert_eq!(link_section(&root, &section), section);
        }
    }
}
