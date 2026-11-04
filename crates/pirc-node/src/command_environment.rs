//! Recheck Gateway intent after local queue/startup waits. This does not install
//! or revoke a sandbox, and is not an atomic lease over later agent effects.
use crate::{
    error::{ApiError, ApiResult},
    services::Node,
    store::Store,
};
use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Value, json};

pub(crate) async fn capabilities(
    _node: Node,
    _request: crate::router::Request,
) -> ApiResult<crate::router::Response> {
    Ok(crate::router::Response::json(
        json!({"version":1,"rechecksCommandEnvironment":true}),
    ))
}

pub fn record(
    conn: &Connection,
    id: &str,
    binding: Option<&Value>,
    duplicate: bool,
) -> ApiResult<()> {
    let stored: Option<String> = conn
        .query_row(
            "SELECT binding_json FROM command_environments WHERE command_id=?",
            [id],
            |r| r.get(0),
        )
        .optional()?;
    if duplicate {
        // A receipt lookup never upgrades an old command's authority.
        if let (Some(stored), Some(binding)) = (stored, binding)
            && serde_json::from_str::<Value>(&stored).map_err(|_| ApiError::internal())? != *binding
        {
            return Err(ApiError::conflict(
                "commandId was already used in a different conversation environment",
            ));
        }
        return Ok(());
    }
    if let Some(binding) = binding {
        if binding["version"] != 1 || binding.to_string().len() > 8192 || !binding.is_object() {
            return Err(ApiError::invalid_input());
        }
        conn.execute(
            "INSERT INTO command_environments VALUES(?,?)",
            params![id, binding.to_string()],
        )?;
    }
    Ok(())
}

pub async fn require_current(
    node: &Node,
    session: &str,
    id: &str,
    lease: (&str, i64),
) -> ApiResult<()> {
    {
        let db = node.db.lock();
        if let Err(error) = crate::execution_fences::require_open(&db, session) {
            db.update_command(
                id,
                crate::store::CommandStatus::Rejected,
                None,
                Some(&error.message),
            )?;
            return Err(error);
        }
    }
    let binding: Option<String> = node
        .db
        .lock()
        .query_row(
            "SELECT binding_json FROM command_environments WHERE command_id=?",
            [id],
            |r| r.get(0),
        )
        .optional()?;
    let Some(binding) = binding else {
        return Ok(());
    };
    let binding: Value = serde_json::from_str(&binding).map_err(|_| ApiError::internal())?;
    let answer = node
        .agent_gateway
        .request(
            session,
            "command.authority",
            json!({"commandId":id,"binding":binding,"clientId":lease.0,"generation":lease.1}),
        )
        .await;
    if answer.status == 200
        && answer.body["result"]["commandId"] == id
        && answer.body["result"]["binding"] == binding
    {
        // A control takeover can happen while the Gateway round trip is in flight.
        let db = node.db.lock();
        if let Err(error) = db
            .require_session_available(session)
            .and_then(|()| crate::execution_fences::require_open(&db, session))
            .and_then(|()| db.validate_lease(session, lease.0, lease.1))
        {
            db.update_command(
                id,
                crate::store::CommandStatus::Rejected,
                None,
                Some(&error.message),
            )?;
            return Err(error);
        }
        return Ok(());
    }
    // Nothing has been queued by this check. Refuse uncertainty, retaining the
    // same command receipt so a duplicate cannot later execute it.
    let error = if answer.status == 409 && answer.body["error"]["code"] == "stale_environment" {
        ApiError::new(
            409,
            "stale_environment",
            "The conversation environment changed; refresh it before starting this action",
        )
    } else {
        ApiError::new(
            409,
            "command_authority_unavailable",
            "The command's current authority could not be confirmed; it was not sent to the agent",
        )
    };
    node.db.lock().update_command(
        id,
        crate::store::CommandStatus::Rejected,
        None,
        Some(&error.message),
    )?;
    Err(error)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::{Db, ModeId};
    fn setup(db: &Connection) -> String {
        db.add_workspace(
            "repo",
            "node",
            "Repo",
            "/repo",
            ModeId::new("directory").unwrap(),
        )
        .unwrap();
        db.create_session("repo", "/session", "alice").unwrap().id
    }
    fn command(db: &Connection, session: &str, id: &str) {
        db.receive_command(
            id,
            session,
            "hash",
            &json!({"type":"prompt","message":"hi"}),
        )
        .unwrap();
    }
    fn origin(db: &Connection, id: &str) -> Option<Value> {
        let raw: Option<String> = db
            .query_row(
                "SELECT binding_json FROM command_environments WHERE command_id=?",
                [id],
                |r| r.get(0),
            )
            .optional()
            .unwrap();
        raw.map(|s| serde_json::from_str(&s).unwrap())
    }
    #[test]
    fn restart_and_duplicate_preserve_the_original_environment() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("node.db");
        let binding = json!({"version":1,"execution":{"generation":7}});
        {
            let db = Db::open(&path).unwrap();
            let conn = db.lock();
            let session = setup(&conn);
            command(&conn, &session, "cmd");
            record(&conn, "cmd", Some(&binding), false).unwrap();
        }
        let db = Db::open(&path).unwrap();
        let conn = db.lock();
        record(&conn, "cmd", Some(&binding), true).unwrap();
        record(&conn, "cmd", None, true).unwrap();
        assert!(
            record(
                &conn,
                "cmd",
                Some(&json!({"version":1,"execution":{"generation":8}})),
                true
            )
            .is_err()
        );
        assert_eq!(origin(&conn, "cmd"), Some(binding));
        assert!(
            conn.execute("UPDATE command_environments SET binding_json='{}'", [])
                .is_err()
        );
        conn.execute("DELETE FROM commands WHERE id='cmd'", [])
            .unwrap();
        assert!(origin(&conn, "cmd").is_none());
    }
    #[test]
    fn metadata_failure_rolls_back_command_reservation() {
        let db = Db::memory();
        let mut conn = db.lock();
        let session = setup(&conn);
        conn.execute_batch("CREATE TRIGGER fail_environment BEFORE INSERT ON command_environments BEGIN SELECT RAISE(ABORT,'disk failure'); END;").unwrap();
        {
            let tx = conn.transaction().unwrap();
            command(&tx, &session, "cmd");
            assert!(record(&tx, "cmd", Some(&json!({"version":1})), false).is_err());
        }
        assert!(conn.get_command("cmd").is_err());
        assert!(origin(&conn, "cmd").is_none());
    }
    #[test]
    fn migration_keeps_historical_commands_unattributed() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("node.db");
        {
            let db = Db::open(&path).unwrap();
            let conn = db.lock();
            let session = setup(&conn);
            command(&conn, &session, "old");
            conn.execute_batch(concat!(include_str!("host_commands/remove_approval.sql"), "DROP TRIGGER browser_groups_identity; DROP TRIGGER browser_groups_terminal; DROP TRIGGER browser_groups_retained; DROP TABLE browser_groups; DROP TRIGGER terminal_runs_identity; DROP TRIGGER terminal_runs_terminal; DROP TRIGGER terminal_runs_retained; DROP TABLE terminal_runs; DROP TRIGGER host_resources_immutable; DROP TRIGGER host_resources_retained; DROP TABLE host_command_resources; DROP INDEX host_commands_pending; DROP TRIGGER host_command_identity; DROP TRIGGER host_command_terminal; DROP TRIGGER host_command_retained; DROP TABLE host_command_runs; DROP TRIGGER sandbox_launch_identity; DROP TRIGGER sandbox_kernel_identity; DROP TRIGGER sandbox_launch_terminal; DROP TRIGGER sandbox_launch_retained; DROP TABLE sandbox_launches; DROP TRIGGER execution_fence_identity; DROP TRIGGER execution_fence_retained; DROP TRIGGER execution_fence_session_deleted; DROP INDEX execution_fence_active; DROP TABLE execution_fences; DROP TRIGGER upload_origin_capture; DROP TRIGGER upload_origin_immutable; DROP TRIGGER upload_origin_remove; DROP TRIGGER upload_record_immutable; DROP TABLE upload_origins; DROP TRIGGER command_environment_immutable; DROP TABLE command_environments; PRAGMA user_version=2009;")).unwrap();
        }
        let db = Db::open(&path).unwrap();
        let conn = db.lock();
        assert!(origin(&conn, "old").is_none());
        record(&conn, "old", Some(&json!({"version":1})), true).unwrap();
        assert!(origin(&conn, "old").is_none());
    }
}
