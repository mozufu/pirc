use super::*;
use crate::{
    conversation_bindings::policies,
    db::{CapabilitiesPatch, Db},
};
use pirc_protocol::ModeId;

fn setup(conn: &Connection) -> Session {
    conn.sync_remote_workspaces(
        "node",
        &[(
            "repo".into(),
            "Repo".into(),
            ModeId::new("directory").unwrap(),
        )],
    )
    .unwrap();
    policies::install_catalog(conn, &crate::app::test_modes()).unwrap();
    conn.create_session(
        "node:repo",
        "node://node/session",
        "node",
        "session",
        "alice",
    )
    .unwrap()
}
fn change(conn: &Connection) {
    conn.patch_workspace_capabilities(
        "node:repo",
        &serde_json::from_value::<CapabilitiesPatch>(json!({"web_search":false})).unwrap(),
    )
    .unwrap();
}
fn prompt() -> Value {
    json!({"type":"prompt","message":"hello"})
}
fn origin(conn: &Connection, id: &str) -> Option<Binding> {
    let raw: Option<String> = conn
        .query_row(
            "SELECT binding_json FROM command_environments WHERE command_id=?",
            [id],
            |r| r.get(0),
        )
        .optional()
        .unwrap();
    raw.map(|v| serde_json::from_str(&v).unwrap())
}

#[test]
fn stale_visible_environment_is_rejected_without_reserving_command_or_losing_input() {
    let db = Db::memory();
    let conn = db.lock();
    let old = setup(&conn);
    change(&conn);
    let current = conn.get_session(&old.id).unwrap();
    assert!(current.binding.execution.generation > old.binding.execution.generation);
    for expected in [Some(&old.binding), None] {
        let error = receive(&conn, &current, "alice", "cmd", &prompt(), expected).unwrap_err();
        assert_eq!(
            error.code,
            if expected.is_some() {
                "stale_environment"
            } else {
                "environment_required"
            }
        );
        assert!(conn.get_command("cmd").is_err());
        assert_eq!(origin(&conn, "cmd"), None);
    }
    // A newly initiated action may use refreshed intent; retries never invent it.
    assert!(
        !receive(
            &conn,
            &current,
            "alice",
            "cmd",
            &prompt(),
            Some(&current.binding)
        )
        .unwrap()
        .1
    );
    assert_eq!(origin(&conn, "cmd"), Some(current.binding));
}

#[test]
fn fresh_expected_binding_cannot_hide_a_routing_change_after_claim() {
    let db = Db::memory();
    let conn = db.lock();
    let old = setup(&conn);
    change(&conn);
    let current = conn.get_session(&old.id).unwrap();
    assert_eq!(
        receive(
            &conn,
            &old,
            "alice",
            "cmd",
            &prompt(),
            Some(&current.binding)
        )
        .unwrap_err()
        .code,
        "stale_environment"
    );
    assert!(conn.get_command("cmd").is_err());
}

#[test]
fn stop_remains_available_from_stale_and_legacy_clients() {
    let db = Db::memory();
    let conn = db.lock();
    let old = setup(&conn);
    change(&conn);
    let current = conn.get_session(&old.id).unwrap();
    for (id, expected) in [("stop-old", Some(&old.binding)), ("stop-legacy", None)] {
        let payload = json!({"type":"stop"});
        assert!(
            !receive(&conn, &current, "alice", id, &payload, expected)
                .unwrap()
                .1
        );
        assert_eq!(origin(&conn, id), Some(current.binding.clone()));
        assert!(
            receive(&conn, &current, "alice", id, &payload, expected)
                .unwrap()
                .1
        );
    }
}

#[test]
fn unchanged_legacy_client_is_supported_but_other_binding_fields_are_not_ignored() {
    let db = Db::memory();
    let conn = db.lock();
    let session = setup(&conn);
    assert!(
        !receive(&conn, &session, "alice", "legacy", &prompt(), None)
            .unwrap()
            .1
    );
    for mutate in [
        |b: &mut Binding| b.membership.revision += 1,
        |b: &mut Binding| b.membership.legacy_workspace_id = "another".into(),
        |b: &mut Binding| b.execution.node_id = Some("other-node".into()),
        |b: &mut Binding| b.execution.mode_id = "chat".into(),
        |b: &mut Binding| b.execution.workspace_id = "other".into(),
        |b: &mut Binding| b.version = 2,
    ] {
        let mut expected = session.binding.clone();
        mutate(&mut expected);
        assert_eq!(
            receive(&conn, &session, "alice", "bad", &prompt(), Some(&expected))
                .unwrap_err()
                .code,
            "stale_environment"
        );
        assert!(conn.get_command("bad").is_err());
    }
}

#[test]
fn original_receipts_survive_restart_and_policy_changes_without_redispatch() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("db");
    let original = {
        let db = Db::open(&path).unwrap();
        let conn = db.lock();
        let session = setup(&conn);
        receive(
            &conn,
            &session,
            "alice",
            "cmd",
            &prompt(),
            Some(&session.binding),
        )
        .unwrap();
        conn.update_command("cmd", "outcome_unknown", None, Some("response lost"))
            .unwrap();
        change(&conn);
        session
    };
    let db = Db::open(&path).unwrap();
    let conn = db.lock();
    let current = conn.get_session(&original.id).unwrap();
    for expected in [Some(&original.binding), None] {
        let (receipt, duplicate) =
            receive(&conn, &current, "alice", "cmd", &prompt(), expected).unwrap();
        assert!(duplicate);
        assert_eq!(receipt.status, "outcome_unknown");
        assert_eq!(origin(&conn, "cmd"), Some(original.binding.clone()));
    }
    assert_eq!(
        receive(
            &conn,
            &current,
            "alice",
            "cmd",
            &prompt(),
            Some(&current.binding)
        )
        .unwrap_err()
        .code,
        "conflict"
    );
    assert_eq!(
        receive(
            &conn,
            &current,
            "alice",
            "cmd",
            &json!({"type":"stop"}),
            None
        )
        .unwrap_err()
        .code,
        "conflict"
    );
    assert_eq!(
        receive(&conn, &current, "mallory", "cmd", &prompt(), None)
            .unwrap_err()
            .status,
        403
    );
}

#[test]
fn failure_to_record_environment_rolls_back_command_and_original_origin_is_immutable() {
    let db = Db::memory();
    let conn = db.lock();
    let session = setup(&conn);
    conn.execute_batch("CREATE TRIGGER fail_origin BEFORE INSERT ON command_environments BEGIN SELECT RAISE(ABORT,'disk failure'); END;").unwrap();
    assert!(
        receive(
            &conn,
            &session,
            "alice",
            "cmd",
            &prompt(),
            Some(&session.binding)
        )
        .is_err()
    );
    assert!(conn.get_command("cmd").is_err());
    conn.execute_batch("DROP TRIGGER fail_origin").unwrap();
    receive(
        &conn,
        &session,
        "alice",
        "cmd",
        &prompt(),
        Some(&session.binding),
    )
    .unwrap();
    assert!(
        conn.execute(
            "UPDATE command_environments SET binding_json=binding_json WHERE command_id='cmd'",
            []
        )
        .is_err()
    );
    conn.execute("DELETE FROM commands WHERE id='cmd'", [])
        .unwrap();
    assert_eq!(origin(&conn, "cmd"), None);
}

#[test]
fn independent_devices_racing_same_id_admit_only_once() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("db");
    let session = {
        let db = Db::open(&path).unwrap();
        setup(&db.lock())
    };
    let gate = std::sync::Barrier::new(2);
    let results = std::thread::scope(|scope| {
        let handles: Vec<_> = (0..2)
            .map(|_| {
                let path = &path;
                let gate = &gate;
                let session = &session;
                scope.spawn(move || {
                    let db = Db::open(path).unwrap();
                    gate.wait();
                    receive(
                        &db.lock(),
                        session,
                        "alice",
                        "cmd",
                        &prompt(),
                        Some(&session.binding),
                    )
                    .unwrap()
                    .1
                })
            })
            .collect();
        handles
            .into_iter()
            .map(|h| h.join().unwrap())
            .collect::<Vec<_>>()
    });
    assert_eq!(results.iter().filter(|duplicate| !**duplicate).count(), 1);
    let db = Db::open(&path).unwrap();
    assert_eq!(origin(&db.lock(), "cmd"), Some(session.binding));
}

#[test]
fn migration_does_not_invent_an_environment_for_historical_commands() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("db");
    let old = {
        let db = Db::open(&path).unwrap();
        let conn = db.lock();
        let session = setup(&conn);
        conn.receive_command(
            "historical",
            &session.id,
            &payload_hash(&prompt()),
            &prompt(),
        )
        .unwrap();
        conn.execute_batch("DROP TRIGGER conversation_node_fence_session_deleted; DROP TABLE conversation_node_fences; DROP TABLE conversation_transition_previews; DROP TRIGGER command_environment_immutable; DROP TABLE command_environments; PRAGMA user_version=1024;").unwrap();
        session
    };
    let db = Db::open(&path).unwrap();
    let conn = db.lock();
    assert_eq!(origin(&conn, "historical"), None);
    change(&conn);
    let current = conn.get_session(&old.id).unwrap();
    assert!(
        receive(
            &conn,
            &current,
            "alice",
            "historical",
            &prompt(),
            Some(&old.binding)
        )
        .unwrap()
        .1
    );
    assert_eq!(origin(&conn, "historical"), None);
}

#[test]
fn deleting_session_cannot_admit_new_work_or_replay_old_receipts() {
    let db = Db::memory();
    let conn = db.lock();
    let session = setup(&conn);
    receive(
        &conn,
        &session,
        "alice",
        "accepted",
        &prompt(),
        Some(&session.binding),
    )
    .unwrap();
    conn.begin_session_deletion(&session.id, "alice").unwrap();
    for (id, payload) in [
        ("accepted", prompt()),
        ("new", prompt()),
        ("stop", json!({"type":"stop"})),
    ] {
        assert_eq!(
            receive(
                &conn,
                &session,
                "alice",
                id,
                &payload,
                Some(&session.binding)
            )
            .unwrap_err()
            .status,
            409
        );
    }
    assert!(conn.get_command("new").is_err());
    assert!(conn.get_command("stop").is_err());
}

fn held(conn: &Connection, session: &Session, client: &str, generation: i64) {
    conn.mirror_lease(
        &session.id,
        &crate::db::Lease {
            client_id: client.into(),
            generation,
            expires_at: crate::util::now_ms() + 60_000,
        },
        "alice",
        false,
    )
    .unwrap();
}

#[test]
fn node_authority_rechecks_policy_and_control_without_replaying_a_receipt() {
    let db = Db::memory();
    let conn = db.lock();
    let session = setup(&conn);
    held(&conn, &session, "phone", 1);
    receive(
        &conn,
        &session,
        "alice",
        "cmd",
        &prompt(),
        Some(&session.binding),
    )
    .unwrap();
    assert_eq!(
        authorize(
            &conn,
            &session,
            "alice",
            "cmd",
            &session.binding,
            "phone",
            1
        )
        .unwrap_err()
        .code,
        "command_not_dispatchable"
    );
    conn.update_command("cmd", "dispatched", None, None)
        .unwrap();
    assert_eq!(
        authorize(
            &conn,
            &session,
            "alice",
            "cmd",
            &session.binding,
            "phone",
            1
        )
        .unwrap()["binding"],
        json!(session.binding)
    );
    held(&conn, &session, "web", 2);
    assert!(
        authorize(
            &conn,
            &session,
            "alice",
            "cmd",
            &session.binding,
            "phone",
            1
        )
        .is_err()
    );
    change(&conn);
    assert_eq!(
        authorize(&conn, &session, "alice", "cmd", &session.binding, "web", 2)
            .unwrap_err()
            .code,
        "stale_environment"
    );
    assert_eq!(conn.get_command("cmd").unwrap().status, "dispatched");
}

#[test]
fn node_authority_refuses_terminal_foreign_deleted_and_unattributed_commands() {
    let db = Db::memory();
    let conn = db.lock();
    let session = setup(&conn);
    held(&conn, &session, "phone", 1);
    receive(
        &conn,
        &session,
        "alice",
        "cmd",
        &prompt(),
        Some(&session.binding),
    )
    .unwrap();
    for status in ["rejected", "accepted"] {
        conn.update_command("cmd", status, None, None).unwrap();
        assert_eq!(
            authorize(
                &conn,
                &session,
                "alice",
                "cmd",
                &session.binding,
                "phone",
                1
            )
            .unwrap_err()
            .code,
            "command_not_dispatchable"
        );
    }
    conn.update_command("cmd", "outcome_unknown", None, None)
        .unwrap();
    assert!(
        authorize(
            &conn,
            &session,
            "alice",
            "cmd",
            &session.binding,
            "phone",
            1
        )
        .is_ok()
    );
    assert!(
        authorize(
            &conn,
            &session,
            "mallory",
            "cmd",
            &session.binding,
            "phone",
            1
        )
        .is_err()
    );
    let other = conn
        .create_session("node:repo", "node://node/other", "node", "other", "alice")
        .unwrap();
    assert_eq!(
        authorize(&conn, &other, "alice", "cmd", &other.binding, "phone", 1)
            .unwrap_err()
            .status,
        404
    );
    conn.receive_command("old", &session.id, &payload_hash(&prompt()), &prompt())
        .unwrap();
    conn.update_command("old", "dispatched", None, None)
        .unwrap();
    assert_eq!(
        authorize(
            &conn,
            &session,
            "alice",
            "old",
            &session.binding,
            "phone",
            1
        )
        .unwrap_err()
        .code,
        "environment_required"
    );
    conn.begin_session_deletion(&session.id, "alice").unwrap();
    assert!(
        authorize(
            &conn,
            &session,
            "alice",
            "cmd",
            &session.binding,
            "phone",
            1
        )
        .is_err()
    );
}

fn probe_app() -> (crate::app::AppState, tempfile::TempDir) {
    let dir = tempfile::tempdir().unwrap();
    let state = dir.path().join("state");
    let env = pirc_config::Env::new(
        [
            (
                "PIRC_NODE_TOKENS",
                r#"{"node":"0123456789abcdef0123456789abcdef"}"#,
            ),
            ("PIRC_TRUSTED_PROXIES", "127.0.0.1"),
            ("PIRC_ALLOWED_ORIGINS", "https://a.example"),
            ("PIRC_ALLOWED_HOSTS", "a.example"),
            ("PIRC_ALLOWED_USERS", "alice"),
            ("PIRC_STATE_DIR", state.to_str().unwrap()),
            ("PIRC_CONFIG_DIR", dir.path().to_str().unwrap()),
            ("PIRC_TIMEZONE", "UTC"),
            ("HOME", "/home/test"),
        ],
        "/work",
    );
    let backends =
        pirc_providers::backends::BackendService::open(&state, crate::app::empty_models()).unwrap();
    let app = crate::app::App::new(
        pirc_config::GatewayConfig::load(&env).unwrap(),
        std::sync::Arc::new(Db::memory()),
        backends,
        crate::app::test_modes(),
    );
    (app, dir)
}
fn probe_node() -> crate::nodes::ConnectedNode {
    crate::nodes::ConnectedNode {
        id: "node".into(),
        role: pirc_protocol::NodeRole::Node,
        modes: vec![ModeId::new("directory").unwrap()],
        workspaces: vec![],
        connected_at: 0,
        last_seen_at: 0,
        added: Default::default(),
    }
}
fn probe_reply() -> pirc_protocol::NodeHttpResponse {
    pirc_protocol::NodeHttpResponse {
        status: 200,
        body: Some(json!({"version":1,"rechecksCommandEnvironment":true})),
    }
}
#[tokio::test]
async fn capability_probe_is_read_only_and_refuses_old_or_incompatible_nodes() {
    let (app, _dir) = probe_app();
    assert!(supported(&app, "node", "alice").await.is_err());
    for (status, body) in [
        (404, None),
        (200, Some(json!({}))),
        (
            200,
            Some(json!({"version":2,"rechecksCommandEnvironment":true})),
        ),
        (
            200,
            Some(json!({"version":1,"rechecksCommandEnvironment":false})),
        ),
    ] {
        app.nodes.set_test_node(probe_node(), move |request| {
            assert_eq!(request.method, pirc_protocol::HttpMethod::Get);
            assert_eq!(request.url, "/api/command-environments/capabilities");
            assert_eq!(request.user, "alice");
            assert!(request.payload.is_none());
            Ok(pirc_protocol::NodeHttpResponse {
                status,
                body: body.clone(),
            })
        });
        assert_eq!(
            supported(&app, "node", "alice").await.unwrap_err().code,
            "command_environment_unsupported"
        );
    }
    app.nodes.set_test_node(probe_node(), |_| Ok(probe_reply()));
    assert!(supported(&app, "node", "alice").await.is_ok());
    let count: i64 = app
        .db
        .lock()
        .query_row("SELECT count(*) FROM commands", [], |r| r.get(0))
        .unwrap();
    assert_eq!(count, 0);
}
#[tokio::test]
async fn capability_probe_cannot_authorize_a_replacement_connection() {
    let (app, _dir) = probe_app();
    let weak = std::sync::Arc::downgrade(&app);
    app.nodes.set_test_node(probe_node(), move |_| {
        weak.upgrade()
            .unwrap()
            .nodes
            .set_test_node(probe_node(), |_| Ok(probe_reply()));
        Ok(probe_reply())
    });
    assert_eq!(
        supported(&app, "node", "alice").await.unwrap_err().code,
        "node_connection_changed"
    );
    let captured = supported(&app, "node", "alice").await.unwrap();
    app.nodes.set_test_node(probe_node(), |_| {
        panic!("stale connection must never dispatch")
    });
    assert_eq!(
        app.nodes
            .request_on(
                "node",
                captured,
                pirc_protocol::NodeHttpRequest {
                    method: pirc_protocol::HttpMethod::Post,
                    url: "/commands".into(),
                    user: "alice".into(),
                    payload: None,
                    body_base64: None,
                    content_type: None,
                }
            )
            .await
            .unwrap_err()
            .code,
        "node_connection_changed"
    );
}
