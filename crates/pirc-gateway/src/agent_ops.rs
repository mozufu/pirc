//! Operations an agent may ask the gateway for through its node
//! (`agent_request`; `apps/gateway/src/daemon/agent-ops.ts`). The node names
//! the session. An operation runs only if it is allowlisted, the session
//! belongs to that node and to a user who is still allowed, and the chat
//! workspace's capability policy permits it; an agent can never act as
//! another session.
//!
//! Each area parses and runs its own operations (`memory`, `delegations`,
//! `schedules`, `calendar`, `web_search`); this module does the common checks in the TS
//! order: unknown session, foreign session, unknown op, invalid arguments,
//! capability, then the op.

use serde_json::{Value, json};

use crate::app::AppState;
use crate::db::{Capability, Session, Store, Workspace};
use crate::error::ApiError;
use crate::{calendar, delegations, memory, schedules, web_search};

/// Who is asking.
pub struct OpContext {
    pub session: Session,
    pub workspace: Workspace,
    pub mode: pirc_protocol::Mode,
    pub user: String,
}

fn agent_error(status: u16, code: &str, message: &str) -> (u16, Value) {
    (
        status,
        json!({ "error": { "code": code, "message": message } }),
    )
}

/// One area's parsed operation.
enum Parsed {
    Memory(memory::Op),
    Delegation(delegations::Op),
    Schedule(schedules::Op),
    Calendar(calendar::agent::Op),
    Web(web_search::Op),
    Pot(crate::pots::ops::Op),
    WorkspaceMirror(String),
    HistoryAuthority,
    CommandAuthority(CommandAuthority),
}

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct CommandAuthority {
    command_id: String,
    binding: crate::conversation_bindings::Binding,
    client_id: String,
    generation: i64,
}

/// `None`: no such operation; `Some(Err)`: invalid arguments.
fn parse(op: &str, args: &Value) -> Option<Result<Parsed, ()>> {
    if op == "command.authority" {
        return Some(
            serde_json::from_value::<CommandAuthority>(args.clone())
                .map_err(|_| ())
                .and_then(|value| {
                    if value.command_id.is_empty()
                        || value.command_id.len() > 200
                        || value.client_id.is_empty()
                        || value.client_id.len() > 200
                        || value.generation < 1
                    {
                        Err(())
                    } else {
                        Ok(Parsed::CommandAuthority(value))
                    }
                }),
        );
    }
    if op == "history.authority" {
        return Some(
            args.as_object()
                .filter(|a| a.is_empty())
                .map(|_| Parsed::HistoryAuthority)
                .ok_or(()),
        );
    }
    if op == "workspace.mirrorState" {
        return Some(
            args.as_object()
                .filter(|m| m.len() == 1)
                .and_then(|_| args["ledgerKey"].as_str())
                .filter(|k| {
                    k.len() == 16
                        && k.bytes()
                            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
                })
                .map(|k| Parsed::WorkspaceMirror(k.into()))
                .ok_or(()),
        );
    }
    if let Some(parsed) = memory::parse_op(op, args) {
        return Some(parsed.map(Parsed::Memory));
    }
    if let Some(parsed) = delegations::parse_op(op, args) {
        return Some(parsed.map(Parsed::Delegation));
    }
    if let Some(parsed) = schedules::parse_op(op, args) {
        return Some(parsed.map(Parsed::Schedule));
    }
    if let Some(parsed) = crate::pots::ops::parse_op(op, args) {
        return Some(parsed.map(Parsed::Pot));
    }
    if let Some(parsed) = calendar::agent::parse_op(op, args) {
        return Some(parsed.map(Parsed::Calendar));
    }
    web_search::parse_op(op, args).map(|parsed| parsed.map(Parsed::Web))
}

fn capability(op: &str) -> Option<Capability> {
    if op.starts_with("delegation.") {
        Some(Capability::Delegation)
    } else if op.starts_with("schedule.") {
        Some(Capability::Schedules)
    } else {
        match op {
            "memory.search" => Some(Capability::MemorySearch),
            "recall.remote" => Some(Capability::RemoteRecall),
            "web.search" => Some(Capability::WebSearch),
            _ => None,
        }
    }
}

fn mode_allows_operation(mode: &pirc_protocol::Mode, op: &str) -> bool {
    let required_tool = op.starts_with("calendar.").then_some("calendar");
    required_tool.is_none_or(|tool| {
        !mode.feature_off(tool)
            && mode
                .tools
                .as_ref()
                .is_none_or(|allowed| allowed.iter().any(|name| name == tool))
    })
}

/// Answer an agent's operation: `(status, body)`, `{result}` on success.
pub async fn run(
    app: &AppState,
    node_id: &str,
    remote_session_id: &str,
    op: &str,
    args: Value,
) -> (u16, Value) {
    let session = {
        let conn = app.db.lock();
        let Ok(Some(session_id)) = conn.resolve_remote_session(node_id, remote_session_id) else {
            return agent_error(404, "not_found", "The gateway does not know this session");
        };
        match conn.get_session(&session_id) {
            Ok(session) => session,
            Err(_) => {
                return agent_error(404, "not_found", "The gateway does not know this session");
            }
        }
    };
    let user = match &session.owner_user {
        Some(user)
            if session.node_id.as_deref() == Some(node_id)
                && app.config.auth.allowed_users.contains(user) =>
        {
            user.clone()
        }
        _ => return agent_error(403, "forbidden", "This session may not use the gateway"),
    };
    let Some(parsed) = parse(op, &args) else {
        return agent_error(
            404,
            "unknown_operation",
            &format!("Unknown gateway operation: {op}"),
        );
    };
    let Ok(parsed) = parsed else {
        return agent_error(400, "invalid_input", &format!("Invalid arguments for {op}"));
    };
    let outcome = async {
        let workspace = app.db.lock().get_workspace(&session.workspace_id)?;
        if let Some(capability) = capability(op) {
            app.db
                .lock()
                .require_workspace_capability(&workspace.id, capability)?;
        }
        let mode = app.require_mode(&workspace)?;
        if !mode_allows_operation(&mode, op) {
            return Err(ApiError::new(
                403,
                "tool_disabled",
                "The calendar tool is disabled for this workspace.",
            ));
        }
        let context = OpContext {
            mode,
            session,
            workspace,
            user,
        };
        match parsed {
            Parsed::CommandAuthority(input) => crate::conversation_bindings::commands::authorize(
                &app.db.lock(),
                &context.session,
                &context.user,
                &input.command_id,
                &input.binding,
                &input.client_id,
                input.generation,
            ),
            Parsed::HistoryAuthority => Ok(json!({"owner":context.user})),
            Parsed::WorkspaceMirror(key) => {
                if !context.mode.workspace_memory || !context.mode.repository {
                    return Err(ApiError::new(
                        403,
                        "forbidden",
                        "Repository memory is not available in this mode",
                    ));
                }
                crate::memory_records::mirror_state(app, node_id, &key, &context.user)
            }
            Parsed::Memory(op) => memory::run_op(app, &context, op).await,
            Parsed::Delegation(op) => delegations::run_op(app, &context, op).await,
            Parsed::Schedule(op) => schedules::run_op(app, &context, op).await,
            Parsed::Calendar(op) => calendar::agent::run_op(app, &context, op).await,
            Parsed::Web(op) => web_search::run_op(app, &context, op).await,
            Parsed::Pot(op) => crate::pots::ops::run_op(app, &context, op).await,
        }
    }
    .await;
    match outcome {
        Ok(result) => (200, json!({ "result": result })),
        Err(ApiError {
            status,
            code,
            message,
            details,
            ..
        }) => {
            let mut error = json!({ "code": code, "message": message });
            if let Some(details) = details {
                error["details"] = details;
            }
            (status, json!({ "error": error }))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn calendar_operations_follow_the_mode_tool_allowlist() {
        let mut mode = pirc_protocol::mode::default_work();
        mode.tools = Some(vec!["read".into(), "calendar".into()]);
        assert!(mode_allows_operation(&mode, "calendar.query"));
        assert!(mode_allows_operation(&mode, "schedule.list"));
        mode.tools = Some(vec!["read".into()]);
        assert!(!mode_allows_operation(&mode, "calendar.query"));
        assert!(mode_allows_operation(&mode, "schedule.list"));
        mode.tools = None;
        assert!(mode_allows_operation(&mode, "calendar.proposeCreate"));
        mode.features_off.push("calendar".into());
        assert!(!mode_allows_operation(&mode, "calendar.proposeCreate"));
    }
}
