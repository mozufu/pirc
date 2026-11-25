use crate::db::{Db, Session, Store, atomic};
use pirc_protocol::ModeId;
use rusqlite::Connection;
use serde_json::json;

fn seed(conn: &Connection) {
    conn.sync_remote_workspaces(
        "node",
        &[
            (
                "repo".into(),
                "Repository".into(),
                ModeId::new("directory").unwrap(),
            ),
            ("pot".into(), "Pot".into(), ModeId::new("pot").unwrap()),
            (
                "custom".into(),
                "Custom".into(),
                ModeId::new("research").unwrap(),
            ),
        ],
    )
    .unwrap();
}

fn create(conn: &Connection, workspace: &str, remote: &str) -> Session {
    conn.create_session(
        &format!("node:{workspace}"),
        &format!("node://node/{remote}"),
        "node",
        remote,
        "alice",
    )
    .unwrap()
}

#[test]
fn every_legacy_identity_has_a_durable_binding_without_private_session_details() {
    let db = Db::memory();
    let conn = db.lock();
    seed(&conn);
    for (workspace, mode) in [
        ("repo", "directory"),
        ("pot", "pot"),
        ("custom", "research"),
    ] {
        let session = create(&conn, workspace, workspace);
        let public = session.public();
        assert_eq!(public["id"], session.id);
        assert_eq!(public["workspaceId"], format!("node:{workspace}"));
        assert_eq!(
            public["binding"],
            json!({
                "version":1,
                "membership":{"revision":1,"legacyWorkspaceId":format!("node:{workspace}")},
                "execution":{"generation":1,"workspaceId":format!("node:{workspace}"),"nodeId":"node","modeId":mode}
            })
        );
        for key in ["piSessionId", "privateSessionPath", "ownerUser"] {
            assert!(public.get(key).is_none(), "{key}");
        }
        assert_eq!(
            conn.get_session(&session.id).unwrap().binding,
            session.binding
        );
    }
    assert_eq!(conn.list_sessions().unwrap().len(), 3);
}

#[test]
fn first_mapping_and_runner_or_control_lifetimes_do_not_change_binding_versions() {
    let db = Db::memory();
    let conn = db.lock();
    seed(&conn);
    // Same insert as U1 acceptance: an accepted public session without a Node ID yet.
    conn.execute("INSERT INTO sessions(id,workspace_id,private_session_path,name,node_id,owner_user,created_at,updated_at) VALUES('pending','node:repo','submission://pending','Input','node','alice',10,10)", []).unwrap();
    let before = conn.get_session("pending").unwrap().binding;
    conn.execute("UPDATE sessions SET pi_session_id='first',private_session_path='node://node/first' WHERE id='pending'", []).unwrap();
    conn.execute(
        "UPDATE sessions SET runner_epoch=4,runner_state='running',name='Named' WHERE id='pending'",
        [],
    )
    .unwrap();
    conn.execute("INSERT INTO leases(session_id,client_id,generation,expires_at,updated_at,owner_user) VALUES('pending','phone',8,9999999999,1,'alice')", []).unwrap();
    conn.execute(
        "UPDATE leases SET generation=9,client_id='web' WHERE session_id='pending'",
        [],
    )
    .unwrap();
    seed(&conn); // Node reconnect with the same workspace ID/mode.
    conn.recover_startup().unwrap();
    assert_eq!(conn.get_session("pending").unwrap().binding, before);
    // An actual remapping of an established private session is distinguishable.
    conn.execute(
        "UPDATE sessions SET pi_session_id='replacement' WHERE id='pending'",
        [],
    )
    .unwrap();
    let after = conn.get_session("pending").unwrap().binding;
    assert_eq!(after.execution.generation, 2);
    assert_eq!(after.membership, before.membership);
}

#[test]
fn legacy_mapping_and_mode_changes_advance_only_the_relevant_versions_atomically() {
    let db = Db::memory();
    let conn = db.lock();
    seed(&conn);
    let session = create(&conn, "repo", "run");
    let other = create(&conn, "repo", "other");
    conn.execute(
        "UPDATE sessions SET node_id='new-node' WHERE id=?",
        [&session.id],
    )
    .unwrap();
    let binding = conn.get_session(&session.id).unwrap().binding;
    assert_eq!(binding.membership.revision, 1);
    assert_eq!(binding.execution.generation, 2);
    assert_eq!(binding.execution.node_id.as_deref(), Some("new-node"));
    // Storage adapter coverage, not a supported public switch operation.
    conn.execute(
        "UPDATE sessions SET workspace_id='node:custom' WHERE id=?",
        [&session.id],
    )
    .unwrap();
    let binding = conn.get_session(&session.id).unwrap().binding;
    assert_eq!(binding.membership.revision, 2);
    assert_eq!(binding.membership.legacy_workspace_id, "node:custom");
    assert_eq!(binding.execution.generation, 3);
    assert_eq!(binding.execution.mode_id, "research");
    conn.sync_remote_workspaces(
        "node",
        &[(
            "custom".into(),
            "Renamed".into(),
            ModeId::new("new-mode").unwrap(),
        )],
    )
    .unwrap();
    let binding = conn.get_session(&session.id).unwrap().binding;
    assert_eq!(binding.membership.revision, 3);
    assert_eq!(binding.execution.generation, 4);
    assert_eq!(binding.execution.mode_id, "new-mode");
    assert_eq!(conn.get_session(&other.id).unwrap().binding, other.binding);
    let result: crate::error::ApiResult<()> = atomic(&conn, |tx| {
        tx.execute(
            "UPDATE sessions SET workspace_id='node:repo' WHERE id=?",
            [&session.id],
        )?;
        Err(crate::error::ApiError::invalid_input())
    });
    assert!(result.is_err());
    assert_eq!(conn.get_session(&session.id).unwrap().binding, binding);
}

#[test]
fn checkpoint_continuation_reuses_its_binding_and_private_workspace_ownership() {
    let db = Db::memory();
    let conn = db.lock();
    seed(&conn);
    conn.claim_checkpoint_workspace("node:repo", "alice")
        .unwrap();
    let first = conn
        .create_checkpoint_session(
            "node:repo",
            "node://node/recovered",
            "node",
            "recovered",
            "alice",
        )
        .unwrap();
    let retry = conn
        .create_checkpoint_session(
            "node:repo",
            "node://node/recovered",
            "node",
            "recovered",
            "alice",
        )
        .unwrap();
    assert_eq!(retry.id, first.id);
    assert_eq!(retry.binding, first.binding);
    assert!(
        conn.create_checkpoint_session(
            "node:repo",
            "node://node/recovered",
            "node",
            "recovered",
            "bob"
        )
        .is_err()
    );
    assert_eq!(conn.list_sessions().unwrap().len(), 1);
}

#[test]
fn failed_creation_and_deletion_leave_no_orphan_binding() {
    let db = Db::memory();
    let conn = db.lock();
    seed(&conn);
    let result: crate::error::ApiResult<()> = atomic(&conn, |tx| {
        create(tx, "repo", "aborted");
        Err(crate::error::ApiError::invalid_input())
    });
    assert!(result.is_err());
    let count = || {
        conn.query_row("SELECT count(*) FROM conversation_bindings", [], |r| {
            r.get::<_, i64>(0)
        })
        .unwrap()
    };
    assert_eq!(count(), 0);
    let session = create(&conn, "repo", "kept");
    conn.begin_session_deletion(&session.id, "alice").unwrap();
    conn.finish_session_deletion(&session.id).unwrap();
    assert_eq!(count(), 0);
    assert!(conn.session_deletion(&session.id).unwrap().is_some());
}
