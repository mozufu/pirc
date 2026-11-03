//! Admission preconditions, not an acknowledgement of installed Node policy.
//! Captured identities survive retries; receipts never dispatch work again.
use super::Binding;
use crate::{
    db::{Command, Session, Store, atomic},
    error::{ApiError, ApiResult},
    util::payload_hash,
};
use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Value, json};

fn changed(current: &Binding) -> ApiError {
    ApiError::new(
        409,
        "stale_environment",
        "The conversation environment changed; refresh it before starting this action",
    )
    .with_details(json!({"binding":current}))
}
pub fn receive(
    conn: &Connection,
    captured: &Session,
    user: &str,
    id: &str,
    payload: &Value,
    expected: Option<&Binding>,
) -> ApiResult<(Command, bool)> {
    atomic(conn, |tx| {
        let current = tx.claim_session(&captured.id, user, false)?;
        let (command, duplicate) =
            tx.receive_command(id, &captured.id, &payload_hash(payload), payload)?;
        if duplicate {
            let origin: Option<String> = tx
                .query_row(
                    "SELECT binding_json FROM command_environments WHERE command_id=?",
                    [id],
                    |r| r.get(0),
                )
                .optional()?;
            if let (Some(origin), Some(expected)) = (origin, expected) {
                let origin: Binding =
                    serde_json::from_str(&origin).map_err(|_| ApiError::internal())?;
                if payload["type"] != "stop" && origin != *expected {
                    return Err(ApiError::new(
                        409,
                        "conflict",
                        "commandId was already used in a different conversation environment",
                    ));
                }
            }
            return Ok((command, true));
        }
        if payload["type"] != "stop" {
            super::transitions::require_open(tx, &current.id)?;
        }
        if current.binding != captured.binding {
            return Err(changed(&current.binding));
        }
        if payload["type"] != "stop" {
            match expected {
                Some(expected) if expected == &current.binding => {}
                Some(_) => return Err(changed(&current.binding)),
                None if current.binding.execution.generation == 1
                    && current.binding.membership.revision == 1 => {}
                None => {
                    return Err(ApiError::new(
                        409,
                        "environment_required",
                        "Refresh or update this client before starting work in a changed conversation environment",
                    ));
                }
            }
        }
        tx.execute(
            "INSERT INTO command_environments VALUES(?,?)",
            params![
                id,
                serde_json::to_string(&current.binding).map_err(|_| ApiError::internal())?
            ],
        )?;
        Ok((command, false))
    })
}

/// A Node rechecks after its local command queue/startup waits. This is a
/// read-only, point-in-time authority check, not an installed sandbox policy.
pub fn authorize(
    conn: &Connection,
    session: &Session,
    user: &str,
    command_id: &str,
    expected: &Binding,
    client_id: &str,
    generation: i64,
) -> ApiResult<Value> {
    atomic(conn, |tx| {
        let current = tx.claim_session(&session.id, user, false)?;
        let command = tx.get_command(command_id)?;
        if command.session_id != current.id {
            return Err(ApiError::not_found("Command not found"));
        }
        tx.validate_lease(&current.id, client_id, generation)?;
        tx.validate_lease_user(&current.id, user)?;
        super::transitions::require_open(tx, &current.id)?;
        if current.binding != *expected {
            return Err(changed(&current.binding));
        }
        let origin: Option<String> = tx
            .query_row(
                "SELECT binding_json FROM command_environments WHERE command_id=?",
                [command_id],
                |r| r.get(0),
            )
            .optional()?;
        let origin: Binding = serde_json::from_str(&origin.ok_or_else(|| {
            ApiError::new(
                409,
                "environment_required",
                "Command has no recorded environment",
            )
        })?)
        .map_err(|_| ApiError::internal())?;
        if origin != *expected
            || !matches!(command.status.as_str(), "dispatched" | "outcome_unknown")
        {
            return Err(ApiError::new(
                409,
                "command_not_dispatchable",
                "This command is no longer pending dispatch",
            ));
        }
        Ok(json!({"commandId":command_id,"binding":origin}))
    })
}

/// An additive, connection-scoped probe: an older Node must not silently ignore
/// the new command envelope. No command is sent by this probe.
pub(crate) async fn supported(
    app: &crate::app::AppState,
    node: &str,
    user: &str,
) -> ApiResult<crate::nodes::NodeConnection> {
    let connection = app.nodes.connection(node)?;
    let remote = app
        .nodes
        .request_on(
            node,
            connection,
            pirc_protocol::NodeHttpRequest {
                method: pirc_protocol::HttpMethod::Get,
                url: "/api/command-environments/capabilities".into(),
                user: user.into(),
                payload: None,
                body_base64: None,
                content_type: None,
            },
        )
        .await?;
    if remote.status != 200
        || remote
            .body
            .as_ref()
            .is_none_or(|body| body["version"] != 1 || body["rechecksCommandEnvironment"] != true)
    {
        return Err(ApiError::new(
            409,
            "command_environment_unsupported",
            "Upgrade this Node before sending versioned conversation commands",
        ));
    }
    app.nodes.require_connection(node, connection)?;
    Ok(connection)
}

#[cfg(test)]
mod tests;
