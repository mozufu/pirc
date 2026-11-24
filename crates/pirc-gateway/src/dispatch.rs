//! Work the gateway starts in a node session on its own: a delegation or a
//! scheduled run (`apps/gateway/src/daemon/session-dispatch.ts`). Both
//! create and name a session on the node, deliver a custom message into it,
//! and read the session back to learn whether it finished or waits for the
//! user. Also the helpers both share: secret redaction
//! (`agent/features/memory/redact.ts`) and workspace lookup by name
//! (`resolveDirectoryWorkspace` in `daemon/delegations.ts`).

use std::sync::LazyLock;

use pirc_protocol::{HttpMethod, NodeHttpRequest};
use regex_lite::Regex;
use serde_json::{Map, Value, json};

use crate::app::App;
use crate::db::{Session, Store, Workspace};
use crate::error::{ApiError, ApiResult};
use crate::events::GatewayEvent;
use crate::routes::urlencoding_component;

/// Run statuses after which a run is over.
pub const TERMINAL_RUNS: &[&str] = &["succeeded", "failed", "cancelled", "interrupted"];
/// Events of a followed session after which it may have finished or started waiting.
const WATCHED_EVENTS: &[&str] = &[
    "interaction_created",
    "interaction_answered",
    "runner_exit",
    "runner_error",
    "node_reconnected",
];

/// An event after which a followed session should be read again.
pub fn is_watched_event(event: &GatewayEvent) -> bool {
    (event.kind == "pi_event"
        && event
            .data
            .as_ref()
            .and_then(|data| data.get("type"))
            .and_then(Value::as_str)
            == Some("agent_settled"))
        || WATCHED_EVENTS.contains(&event.kind.as_str())
}

/// `text.replace(/\s+/g, ' ').trim()` with JavaScript's whitespace.
pub fn one_line(text: &str) -> String {
    text.split(pirc_config::text::is_space)
        .filter(|part| !part.is_empty())
        .collect::<Vec<_>>()
        .join(" ")
}

/// At most `max` UTF-16 units, ending in `…` when cut.
pub fn clip(text: &str, max: usize) -> String {
    let units: Vec<u16> = text.encode_utf16().collect();
    if units.len() <= max {
        return text.to_owned();
    }
    let kept = String::from_utf16_lossy(&units[..max.saturating_sub(1)]);
    format!("{}…", kept.trim_end_matches(pirc_config::text::is_space))
}

/// The text of a history message (an agent's answer).
pub fn text_of(message: &Value) -> String {
    match message.get("content") {
        Some(Value::String(text)) => text.trim_matches(pirc_config::text::is_space).to_owned(),
        Some(Value::Array(blocks)) => blocks
            .iter()
            .filter(|block| block.get("type").and_then(Value::as_str) == Some("text"))
            .filter_map(|block| block.get("text").and_then(Value::as_str))
            .collect::<Vec<_>>()
            .join("\n")
            .trim_matches(pirc_config::text::is_space)
            .to_owned(),
        _ => String::new(),
    }
}

/// The workspace's node is connected and still serves it.
pub fn workspace_online(app: &App, workspace: &Workspace) -> bool {
    app.nodes.get(&workspace.host_id).is_some_and(|node| {
        node.workspaces
            .iter()
            .any(|item| format!("{}:{}", workspace.host_id, item.id) == workspace.id)
    })
}

/// Why a node request failed: the node's error message, or its status.
#[derive(Clone, Debug)]
pub struct NodeFailure(pub String);

/// A node request that must succeed; the node's error message otherwise.
pub async fn node_request(
    app: &App,
    node_id: &str,
    user: &str,
    method: HttpMethod,
    url: String,
    payload: Option<Value>,
) -> Result<Value, NodeFailure> {
    let response = app
        .nodes
        .request(
            node_id,
            NodeHttpRequest {
                method,
                url,
                user: user.to_owned(),
                payload,
                body_base64: None,
                content_type: None,
            },
        )
        .await
        .map_err(|error| NodeFailure(error.message))?;
    if response.status >= 400 {
        let message = response
            .body
            .as_ref()
            .and_then(|body| body["error"]["message"].as_str())
            .map(str::to_owned)
            .unwrap_or_else(|| format!("{node_id} answered {}", response.status));
        return Err(NodeFailure(message));
    }
    Ok(response
        .body
        .filter(|body| !body.is_null())
        .unwrap_or_else(|| json!({})))
}

/// Create a session for `user` in `workspace` on its node, named `title`
/// (best effort).
pub async fn start_session(
    app: &App,
    workspace: &Workspace,
    user: &str,
    title: &str,
) -> Result<Session, NodeFailure> {
    app.require_mode(workspace)
        .map_err(|e| NodeFailure(e.message))?;
    let node_id = workspace.host_id.clone();
    let local = workspace.local_id().unwrap_or_default().to_owned();
    let created = node_request(
        app,
        &node_id,
        user,
        HttpMethod::Post,
        "/api/session-creations/internal".into(),
        Some(json!({ "workspaceId": local })),
    )
    .await?;
    let remote_id = match &created["session"]["id"] {
        Value::String(id) => id.clone(),
        Value::Number(id) => id.to_string(),
        _ => String::new(),
    };
    if remote_id.is_empty() {
        return Err(NodeFailure(format!("{node_id} did not create a session")));
    }
    let session = app
        .db
        .lock()
        .create_session(
            &workspace.id,
            &format!("node://{node_id}/{remote_id}"),
            &node_id,
            &remote_id,
            user,
        )
        .map_err(|error| NodeFailure(error.message))?;
    let renamed = node_request(
        app,
        &node_id,
        user,
        HttpMethod::Patch,
        format!("/api/sessions/{}", urlencoding_component(&remote_id)),
        Some(json!({ "name": title })),
    )
    .await;
    if renamed.is_ok() {
        let mut data = Map::new();
        data.insert("name".into(), json!(title));
        data.insert("source".into(), json!("user"));
        app.apply_session_name(&session.id, session.runner_epoch, &data);
    }
    app.directory_changed();
    Ok(session)
}

/// Push a custom message (`customType`, `content`, `details`, `role`,
/// `model`, `thinking`) into a node session; it wakes the agent.
pub async fn deliver(
    app: &App,
    session: &Session,
    user: &str,
    message: Value,
) -> Result<(), NodeFailure> {
    app.require_writable(session)
        .map_err(|e| NodeFailure(e.message))?;
    let (Some(node_id), Some(remote)) = (&session.node_id, &session.pi_session_id) else {
        return Err(NodeFailure("Session not found".into()));
    };
    node_request(
        app,
        node_id,
        user,
        HttpMethod::Post,
        format!("/api/sessions/{}/deliver", urlencoding_component(remote)),
        Some(message),
    )
    .await
    .map(|_| ())
}

/// Where a session stands with the custom message `is_ours` picks out.
#[derive(Clone, Debug, PartialEq)]
pub enum Progress {
    /// The node is gone or the session unknown: read it again later.
    Unknown,
    /// The message is still queued behind other work.
    Queued,
    /// The agent stopped before it took the message.
    Dropped,
    /// Waiting for the user: the dialogs it waits on, as the node lists them.
    Waiting(Vec<Value>),
    Working,
    Over {
        status: String,
        failure_reason: Option<String>,
        /// The last answer after the message.
        answer: String,
    },
}

/// Read the session back (`readProgress`); the message was delivered at `delivered_at`.
pub async fn read_progress(
    app: &App,
    session: &Session,
    user: &str,
    delivered_at: i64,
    is_ours: impl Fn(&Value) -> bool,
) -> Result<Progress, NodeFailure> {
    let (Some(node_id), Some(remote)) = (&session.node_id, &session.pi_session_id) else {
        return Ok(Progress::Unknown);
    };
    if app.nodes.get(node_id).is_none() {
        return Ok(Progress::Unknown);
    }
    let snapshot = node_request(
        app,
        node_id,
        user,
        HttpMethod::Get,
        format!("/api/sessions/{}/snapshot", urlencoding_component(remote)),
        None,
    )
    .await?;
    let empty = Vec::new();
    let history = snapshot["history"].as_array().unwrap_or(&empty);
    let run = snapshot.get("run").filter(|run| run.is_object());
    let run_status = run.map(|run| js_string(&run["status"]));
    let over = run_status
        .as_deref()
        .is_some_and(|status| TERMINAL_RUNS.contains(&status));
    let taken = history.iter().rposition(|message| {
        message.get("role").and_then(Value::as_str) == Some("custom") && is_ours(message)
    });
    let Some(taken) = taken else {
        let created = run.and_then(|run| run["createdAt"].as_f64()).unwrap_or(0.0);
        return Ok(if over && created >= delivered_at as f64 {
            Progress::Dropped
        } else {
            Progress::Queued
        });
    };
    if let Some(dialogs) = snapshot["interactions"]
        .as_array()
        .filter(|items| !items.is_empty())
    {
        return Ok(Progress::Waiting(dialogs.clone()));
    }
    if !over {
        return Ok(Progress::Working);
    }
    let answer = history[taken + 1..]
        .iter()
        .rfind(|message| message.get("role").and_then(Value::as_str) == Some("assistant"))
        .map(text_of)
        .unwrap_or_default();
    Ok(Progress::Over {
        status: run_status.unwrap_or_default(),
        failure_reason: run
            .and_then(|run| run["failureReason"].as_str())
            .map(str::to_owned),
        answer,
    })
}

use pirc_config::text::value_text as js_string;

/// A directory workspace by id, or by a name only one of them has.
pub fn resolve_directory_workspace(app: &App, reference: &str) -> ApiResult<Workspace> {
    let all: Vec<Workspace> = app
        .db
        .lock()
        .list_workspaces()?
        .into_iter()
        .filter(|workspace| {
            app.mode(&workspace.mode)
                .is_some_and(|mode| mode.delegate_target)
                && workspace.id.contains(':')
        })
        .collect();
    if let Some(exact) = all.iter().find(|workspace| workspace.id == reference) {
        return Ok(exact.clone());
    }
    let lower = reference.to_lowercase();
    let named: Vec<&Workspace> = all
        .iter()
        .filter(|workspace| workspace.display_name.to_lowercase() == lower)
        .collect();
    match named.as_slice() {
        [one] => Ok((*one).clone()),
        [] => {
            let listed: Vec<String> = all
                .iter()
                .map(|w| format!("{} ({})", w.display_name, w.id))
                .collect();
            Err(ApiError::new(
                404,
                "not_found",
                format!(
                    "No workspace {reference}. Workspaces: {}",
                    if listed.is_empty() {
                        "none".to_owned()
                    } else {
                        listed.join(", ")
                    }
                ),
            ))
        }
        several => Err(ApiError::new(
            409,
            "conflict",
            format!(
                "Several workspaces are called {reference}; use one of these ids: {}",
                several
                    .iter()
                    .map(|w| w.id.as_str())
                    .collect::<Vec<_>>()
                    .join(", ")
            ),
        )),
    }
}

static PATTERNS: LazyLock<Vec<(Regex, &'static str)>> = LazyLock::new(|| {
    [
        (
            r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----",
            "[REDACTED PRIVATE KEY]",
        ),
        (r"\b(pirc_dev_)[A-Za-z0-9_-]{16,}", "${1}[REDACTED]"),
        (r"\b(sk-)[A-Za-z0-9_-]{20,}", "${1}[REDACTED]"),
        (r"\b(github_pat_)[A-Za-z0-9_]{20,}", "${1}[REDACTED]"),
        (r"\b(gh[pousr]_)[A-Za-z0-9]{30,}", "${1}[REDACTED]"),
        (r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b", "[REDACTED AWS KEY]"),
        (
            r"(?i)\b(Bearer\s+)[A-Za-z0-9._~+/-]{16,}=*",
            "${1}[REDACTED]",
        ),
    ]
    .into_iter()
    .map(|(pattern, replacement)| (Regex::new(pattern).expect("redaction pattern"), replacement))
    .collect()
});

/// Best-effort removal of credentials from text the gateway stores and
/// replays (memory, tasks, results): well-known token formats and the
/// values of this process's secret-looking environment variables.
pub fn redact_secrets(text: &str) -> String {
    redact_with(
        text,
        std::env::vars_os().map(|(name, value)| {
            (
                name.to_string_lossy().into_owned(),
                value.to_string_lossy().into_owned(),
            )
        }),
    )
}

fn redact_with(text: &str, env: impl Iterator<Item = (String, String)>) -> String {
    const SECRET_NAMES: &[&str] = &["TOKEN", "SECRET", "PASSWORD", "PASSWD", "CREDENTIAL"];
    let secret_name = |name: &str| {
        let upper = name.to_uppercase();
        SECRET_NAMES.iter().any(|part| upper.contains(part))
            || ["API", "PRIVATE"].iter().any(|prefix| {
                upper.match_indices(prefix).any(|(at, _)| {
                    let rest = &upper[at + prefix.len()..];
                    rest.strip_prefix('_').unwrap_or(rest).starts_with("KEY")
                })
            })
    };
    let mut values: Vec<(String, String)> = env
        .filter(|(name, value)| value.encode_utf16().count() >= 16 && secret_name(name))
        .collect();
    // Longest first, so a secret containing another is replaced whole.
    values.sort_by_key(|(_, value)| std::cmp::Reverse(value.encode_utf16().count()));
    let mut out = text.to_owned();
    for (name, value) in values {
        if out.contains(&value) {
            out = out.replace(&value, &format!("[REDACTED {name}]"));
        }
    }
    for (pattern, replacement) in PATTERNS.iter() {
        out = pattern.replace_all(&out, *replacement).into_owned();
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn redaction() {
        let env = vec![
            ("MY_API_KEY".to_owned(), "0123456789abcdefXYZ".to_owned()),
            ("HOME".to_owned(), "/home/someone/abcdefgh".to_owned()),
        ];
        let text = "key 0123456789abcdefXYZ token sk-abcdefghijklmnopqrstuvwxyz \
                    Authorization: bearer abcdefghijklmnopqrst== AKIAABCDEFGHIJKLMNOP /home/someone/abcdefgh";
        let out = redact_with(text, env.into_iter());
        assert_eq!(
            out,
            "key [REDACTED MY_API_KEY] token sk-[REDACTED] Authorization: bearer [REDACTED] \
             [REDACTED AWS KEY] /home/someone/abcdefgh"
        );
        // JavaScript's `\b` (no `u` flag) treats non-ASCII letters as non-word.
        assert_eq!(
            redact_with(
                "密钥sk-abcdefghijklmnopqrstuvwxyz AKIAABCDEFGHIJKLMNOPé",
                std::iter::empty()
            ),
            "密钥sk-[REDACTED] [REDACTED AWS KEY]é"
        );
        let key = "-----BEGIN RSA PRIVATE KEY-----\nabc\n-----END RSA PRIVATE KEY-----";
        assert_eq!(
            redact_with(key, std::iter::empty()),
            "[REDACTED PRIVATE KEY]"
        );
    }

    #[test]
    fn text_helpers() {
        assert_eq!(one_line("  a \n\t b  "), "a b");
        assert_eq!(clip("abcdef", 4), "abc…");
        assert_eq!(clip("abc", 4), "abc");
        assert_eq!(
            text_of(
                &json!({ "content": [{ "type": "text", "text": " a " }, { "type": "image" }, { "type": "text", "text": "b" }] })
            ),
            "a \nb"
        );
    }
}
