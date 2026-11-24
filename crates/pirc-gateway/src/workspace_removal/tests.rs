use super::*;
use crate::db::Db;
use pirc_config::{Env, GatewayConfig};
use pirc_protocol::{ModeId, SessionActivity, SessionRun};
use pirc_providers::backends::BackendService;
use serde_json::json;
use std::sync::Arc;

fn fixture() -> (AppState, tempfile::TempDir) {
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
            ("PIRC_ALLOWED_USERS", "u"),
            ("PIRC_STATE_DIR", state.to_str().unwrap()),
            ("PIRC_CONFIG_DIR", dir.path().to_str().unwrap()),
            ("PIRC_TIMEZONE", "UTC"),
            ("HOME", "/home/test"),
        ],
        "/work",
    );
    let models = serde_json::from_value(json!({ "providers": {} })).unwrap();
    let app = App::new(
        GatewayConfig::load(&env).unwrap(),
        Arc::new(Db::memory()),
        BackendService::open(&state, models).unwrap(),
        crate::app::test_modes(),
    );
    app.db
        .lock()
        .sync_remote_workspaces(
            "work",
            &[(
                "repo".into(),
                "Repo".into(),
                ModeId::new("directory").unwrap(),
            )],
        )
        .unwrap();
    (app, dir)
}

fn session(app: &App, user: &str) -> crate::db::Session {
    app.db
        .lock()
        .create_session(
            "work:repo",
            &format!("node://work/{user}"),
            "work",
            user,
            user,
        )
        .unwrap()
}

fn schedule(conn: &Connection, user: &str) {
    conn.execute("INSERT INTO schedules (id,owner_user,workspace_id,title,prompt,run_at,timezone,status,next_run_at,created_at,updated_at) VALUES ('schedule',?,'work:repo','S','P',5000,'UTC','active',5000,0,0)", [user]).unwrap();
}

#[test]
fn remove_keeps_history_and_pauses_schedules_until_explicit_restore() {
    let (app, _dir) = fixture();
    let session = session(&app, "u");
    let conn = app.db.lock();
    schedule(&conn, "u");
    conn.sync_remote_workspaces(
        "home",
        &[(
            "project".into(),
            "Project".into(),
            ModeId::new("chat").unwrap(),
        )],
    )
    .unwrap();
    conn.execute(
        "UPDATE workspaces SET repo='https://example.com/original' WHERE id='work:repo'",
        [],
    )
    .unwrap();
    let original = crate::project_links::set_links(
        &conn,
        &app.catalog(),
        "home:project",
        &["work:repo".into()],
    )
    .unwrap();
    remove(&app, &conn, "work:repo", "u").unwrap();
    remove(&app, &conn, "work:repo", "u").unwrap();
    assert!(removed(&conn, "work:repo").unwrap());
    assert!(conn.find_workspace("work:repo").unwrap().is_some());
    assert!(conn.get_session(&session.id).is_ok());
    assert!(conn.list_sessions().unwrap().is_empty());
    assert!(
        !conn
            .list_workspaces()
            .unwrap()
            .iter()
            .any(|w| w.id == "work:repo")
    );
    assert!(
        !conn
            .list_workspaces_for_user("u")
            .unwrap()
            .iter()
            .any(|w| w.id == "work:repo")
    );
    assert_eq!(conn.get_workspace("work:repo").unwrap_err().status, 404);
    assert!(conn.claim_session(&session.id, "u", false).is_err());
    assert!(conn.claim_session(&session.id, "u", true).is_err());
    assert!(
        conn.create_session("work:repo", "node://work/new", "work", "new", "u")
            .is_err()
    );
    assert_eq!(
        conn.query_row("SELECT status FROM schedules", [], |r| r
            .get::<_, String>(0))
            .unwrap(),
        "paused"
    );
    assert_eq!(
        crate::project_links::links(&conn, "home:project")
            .unwrap()
            .len(),
        1
    );
    // Editing unrelated links must keep the removed link and its metadata.
    conn.execute(
        "UPDATE workspaces SET repo='https://example.com/changed' WHERE id='work:repo'",
        [],
    )
    .unwrap();
    conn.sync_remote_workspaces(
        "work",
        &[(
            "other".into(),
            "Other".into(),
            ModeId::new("directory").unwrap(),
        )],
    )
    .unwrap();
    let kept = crate::project_links::set_links(
        &conn,
        &app.catalog(),
        "home:project",
        &["work:repo".into(), "work:other".into()],
    )
    .unwrap();
    assert_eq!(
        kept.iter().find(|link| link.workspace_id == "work:repo"),
        original.first()
    );
    conn.sync_remote_workspaces(
        "home",
        &[(
            "another".into(),
            "Another".into(),
            ModeId::new("chat").unwrap(),
        )],
    )
    .unwrap();
    assert!(
        crate::project_links::set_links(
            &conn,
            &app.catalog(),
            "home:another",
            &["work:repo".into()],
        )
        .is_err()
    );
    // A reconnect/configured workspace never restores an explicit removal.
    conn.sync_remote_workspaces(
        "work",
        &[(
            "repo".into(),
            "Repo".into(),
            ModeId::new("directory").unwrap(),
        )],
    )
    .unwrap();
    assert!(removed(&conn, "work:repo").unwrap());
    assert_eq!(
        restore(&conn, "work:repo", "other").unwrap_err().status,
        403
    );
    restore(&conn, "work:repo", "u").unwrap();
    assert!(conn.get_workspace("work:repo").is_ok());
    assert_eq!(conn.list_sessions().unwrap().len(), 1);
    assert_eq!(
        conn.query_row("SELECT status FROM schedules", [], |r| r
            .get::<_, String>(0))
            .unwrap(),
        "paused"
    );
}

#[test]
fn other_users_data_is_never_hidden() {
    let (app, _dir) = fixture();
    session(&app, "other");
    let conn = app.db.lock();
    assert_eq!(
        remove(&app, &conn, "work:repo", "u").unwrap_err().status,
        403
    );
    assert!(!removed(&conn, "work:repo").unwrap());
    drop(conn);
    let (app, _dir) = fixture();
    let conn = app.db.lock();
    schedule(&conn, "other");
    assert_eq!(
        remove(&app, &conn, "work:repo", "u").unwrap_err().status,
        403
    );
    assert!(!removed(&conn, "work:repo").unwrap());
}

#[test]
fn active_sessions_delegations_and_schedule_runs_block_removal() {
    let (app, _dir) = fixture();
    let session = session(&app, "u");
    app.on_node_activity(
        "work",
        &[SessionActivity {
            id: "u".into(),
            run: Some(SessionRun::Running),
            write_lease: Some(false),
        }],
    );
    let conn = app.db.lock();
    assert_eq!(
        remove(&app, &conn, "work:repo", "u").unwrap_err().status,
        409
    );
    assert!(!removed(&conn, "work:repo").unwrap());
    drop(conn);
    app.on_node_activity("work", &[]);
    let conn = app.db.lock();
    conn.set_runner_state(&session.id, "running").unwrap();
    assert_eq!(
        remove(&app, &conn, "work:repo", "u").unwrap_err().status,
        409
    );
    conn.set_runner_state(&session.id, "ready").unwrap();
    conn.execute("INSERT INTO delegations (id,owner_user,assistant_session_id,workspace_id,title,task,status,expires_at,created_at,updated_at) VALUES ('d','u','assistant','work:repo','D','T','pending_approval',1000,0,0)", []).unwrap();
    assert_eq!(
        remove(&app, &conn, "work:repo", "u").unwrap_err().status,
        409
    );
    conn.execute("UPDATE delegations SET status='completed'", [])
        .unwrap();
    schedule(&conn, "u");
    conn.execute("INSERT INTO schedule_runs (id,schedule_id,owner_user,due_at,status,created_at) VALUES ('run','schedule','u',0,'running',0)", []).unwrap();
    assert_eq!(
        remove(&app, &conn, "work:repo", "u").unwrap_err().status,
        409
    );
    conn.execute("UPDATE schedule_runs SET status='completed'", [])
        .unwrap();
    remove(&app, &conn, "work:repo", "u").unwrap();
}

#[test]
fn projects_cannot_be_removed_but_missing_work_modes_can() {
    let (app, _dir) = fixture();
    let conn = app.db.lock();
    for (id, mode) in [
        ("chats", "chat"),
        ("project", "chat"),
        ("custom", "unavailable"),
    ] {
        conn.sync_remote_workspaces(
            "work",
            &[(id.into(), id.into(), ModeId::new(mode).unwrap())],
        )
        .unwrap();
    }
    assert_eq!(
        remove(&app, &conn, "work:chats", "u").unwrap_err().status,
        400
    );
    assert_eq!(
        remove(&app, &conn, "work:project", "u").unwrap_err().status,
        400
    );
    remove(&app, &conn, "work:custom", "u").unwrap();
}

async fn call(
    router: &axum::Router,
    method: &str,
    path: &str,
    body: Option<serde_json::Value>,
) -> axum::response::Response {
    use tower::ServiceExt;
    let mut request = axum::http::Request::builder()
        .header(crate::capabilities::HEADER, "test/2")
        .method(method)
        .uri(path)
        .header("host", "a.example")
        .header(
            crate::request_shape::REQUEST_HEADER,
            crate::request_shape::REQUEST_VALUE,
        )
        .header("origin", "https://a.example")
        .header("x-pirc-user", "u")
        .extension(axum::extract::ConnectInfo(
            "127.0.0.1:40000".parse::<std::net::SocketAddr>().unwrap(),
        ));
    let body = match body {
        Some(body) => {
            request = request.header("content-type", "application/json");
            axum::body::Body::from(body.to_string())
        }
        None => axum::body::Body::empty(),
    };
    router
        .clone()
        .oneshot(request.body(body).unwrap())
        .await
        .unwrap()
}

async fn body(response: axum::response::Response) -> serde_json::Value {
    let bytes = axum::body::to_bytes(response.into_body(), 1024 * 1024)
        .await
        .unwrap();
    serde_json::from_slice(&bytes).unwrap()
}

#[tokio::test]
async fn http_removal_filters_node_lists_and_restores_only_on_add() {
    use pirc_protocol::{NodeHttpResponse, NodeRole, RegisteredWorkspace};
    let (app, _dir) = fixture();
    let session = session(&app, "u");
    app.nodes.set_test_node(crate::nodes::ConnectedNode {
        id: "work".into(), role: NodeRole::Node, modes: vec![ModeId::new("directory").unwrap()],
        workspaces: vec![RegisteredWorkspace { id: "repo".into(), display_name: "Repo".into(), mode: ModeId::new("directory").unwrap(), roles: None, repo: None, checkpoint_private: false }],
        added: Default::default(), connected_at: 0, last_seen_at: 0,
    }, |request| {
        if request.url.ends_with("/removal-check") {
            assert_eq!(request.method, pirc_protocol::HttpMethod::Get);
            return Ok(NodeHttpResponse { status: 200, body: Some(json!({"idle":true})) });
        }
        assert_eq!(request.method, pirc_protocol::HttpMethod::Post);
        assert_eq!(request.url, "/api/workspaces");
        assert_eq!(request.payload.as_ref().unwrap()["restoreExisting"], true);
        Ok(NodeHttpResponse { status: 201, body: Some(json!({ "workspace": { "id": "repo", "displayName": "Repo", "mode": "directory" } })) })
    });
    let router = crate::app::router(app.clone());
    assert_eq!(
        call(&router, "DELETE", "/api/workspaces/work:repo", None)
            .await
            .status(),
        204
    );
    let nodes = body(call(&router, "GET", "/api/nodes", None).await).await;
    assert_eq!(nodes["nodes"][0]["workspaces"], json!([]));
    assert_eq!(
        body(call(&router, "GET", "/api/workspaces", None).await).await["workspaces"],
        json!([])
    );
    assert_eq!(
        body(call(&router, "GET", "/api/sessions", None).await).await["sessions"],
        json!([])
    );
    assert_eq!(
        call(
            &router,
            "POST",
            &format!("/api/sessions/{}/commands", session.id),
            Some(json!({}))
        )
        .await
        .status(),
        404
    );
    assert_eq!(
        call(
            &router,
            "POST",
            "/api/workspaces",
            Some(
                json!({"nodeId":"work", "mode":"directory", "path":"/repo", "displayName":"Repo"})
            )
        )
        .await
        .status(),
        201
    );
    assert_eq!(app.db.lock().list_sessions().unwrap().len(), 1);
    assert_eq!(
        call(
            &router,
            "POST",
            "/api/workspaces",
            Some(
                json!({"nodeId":"work", "mode":"directory", "path":"/repo", "displayName":"Repo"})
            )
        )
        .await
        .status(),
        409
    );
}

#[test]
fn migration_from_1008_preserves_workspace_and_history() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("db.sqlite");
    {
        let conn = Connection::open(&path).unwrap();
        conn.execute_batch(concat!(
            include_str!("../schema.sql"),
            include_str!("../calendar/schema.sql"),
            "PRAGMA user_version=1008;"
        ))
        .unwrap();
        conn.sync_remote_workspaces(
            "work",
            &[(
                "repo".into(),
                "Repo".into(),
                ModeId::new("directory").unwrap(),
            )],
        )
        .unwrap();
        conn.execute("INSERT INTO sessions(id,workspace_id,private_session_path,name,node_id,pi_session_id,owner_user,created_at,updated_at) VALUES('old','work:repo','node://work/s','Old','work','s','u',1,1)", []).unwrap();
        conn.execute_batch("DROP TABLE workspace_removals;")
            .unwrap();
    }
    let db = Db::open(&path).unwrap();
    let conn = db.lock();
    assert!(conn.get_workspace("work:repo").is_ok());
    assert_eq!(conn.list_sessions().unwrap().len(), 1);
    assert!(!removed(&conn, "work:repo").unwrap());
}

#[test]
fn checking_fences_mutations_and_only_its_token_can_finalize_or_rollback() {
    let (app, _dir) = fixture();
    let session = session(&app, "u");
    let conn = app.db.lock();
    schedule(&conn, "u");
    assert_eq!(
        begin(&app, &conn, "work:repo", "u", false)
            .unwrap_err()
            .status,
        503
    );
    let (_, token) = begin(&app, &conn, "work:repo", "u", true).unwrap().unwrap();
    assert_eq!(
        begin(&app, &conn, "work:repo", "u", true)
            .unwrap_err()
            .status,
        409
    );
    assert_eq!(restore(&conn, "work:repo", "u").unwrap_err().status, 409);
    assert!(conn.claim_session(&session.id, "u", false).is_err());
    assert_eq!(conn.list_workspaces().unwrap().len(), 1);
    assert_eq!(conn.list_sessions().unwrap().len(), 1);
    assert!(!completed(&conn, "work:repo").unwrap());
    assert!(
        conn.receive_command("new", &session.id, "hash", &json!({"type":"prompt"}))
            .is_err()
    );
    assert_eq!(
        conn.query_row("SELECT status FROM schedules", [], |r| r
            .get::<_, String>(0))
            .unwrap(),
        "active"
    );
    rollback(&conn, "work:repo", "wrong-token").unwrap();
    assert!(removed(&conn, "work:repo").unwrap());
    assert!(finish(&conn, "work:repo", "wrong-token").is_err());
    rollback(&conn, "work:repo", &token).unwrap();
    assert!(!removed(&conn, "work:repo").unwrap());
    let (_, token) = begin(&app, &conn, "work:repo", "u", true).unwrap().unwrap();
    finish(&conn, "work:repo", &token).unwrap();
    rollback(&conn, "work:repo", &token).unwrap();
    assert!(removed(&conn, "work:repo").unwrap());
    assert!(
        begin(&app, &conn, "work:repo", "u", false)
            .unwrap()
            .is_none()
    );
    // Startup rolls back an interrupted probe without resurrecting completed removals.
    conn.sync_remote_workspaces(
        "work",
        &[(
            "other".into(),
            "Other".into(),
            ModeId::new("directory").unwrap(),
        )],
    )
    .unwrap();
    begin(&app, &conn, "work:other", "u", true).unwrap();
    conn.recover_startup().unwrap();
    assert!(!removed(&conn, "work:other").unwrap());
    assert!(removed(&conn, "work:repo").unwrap());
}

#[tokio::test]
async fn authoritative_node_check_rejects_accepted_command_before_activity_arrives() {
    use pirc_protocol::{NodeHttpResponse, NodeRole};
    for (status, response) in [
        (409, json!({"error":{"code":"conflict"}})),
        (200, json!({"idle":false})),
        (404, json!({})),
        (403, json!({})),
    ] {
        let (app, _dir) = fixture();
        let session = session(&app, "u");
        {
            let conn = app.db.lock();
            schedule(&conn, "u");
            conn.receive_command("accepted", &session.id, "hash", &json!({"type":"prompt"}))
                .unwrap();
            conn.update_command("accepted", "accepted", None, None)
                .unwrap();
        }
        let checking_app = app.clone();
        app.nodes.set_test_node(
            crate::nodes::ConnectedNode {
                id: "work".into(),
                role: NodeRole::Node,
                modes: vec![ModeId::new("directory").unwrap()],
                workspaces: vec![],
                added: Default::default(),
                connected_at: 0,
                last_seen_at: 0,
            },
            move |request| {
                assert_eq!(request.method, pirc_protocol::HttpMethod::Get);
                assert_eq!(request.url, "/api/workspaces/repo/removal-check");
                let conn = checking_app.db.lock();
                assert!(removed(&conn, "work:repo").unwrap());
                assert!(conn.claim_session(&session.id, "u", false).is_err());
                assert_eq!(
                    conn.query_row("SELECT status FROM schedules", [], |r| r
                        .get::<_, String>(0))
                        .unwrap(),
                    "active"
                );
                Ok(NodeHttpResponse {
                    status,
                    body: Some(response.clone()),
                })
            },
        );
        let router = crate::app::router(app.clone());
        assert!(
            !call(&router, "DELETE", "/api/workspaces/work:repo", None)
                .await
                .status()
                .is_success()
        );
        let conn = app.db.lock();
        assert!(!removed(&conn, "work:repo").unwrap());
        assert_eq!(conn.list_sessions().unwrap().len(), 1);
        assert_eq!(
            conn.query_row("SELECT status FROM schedules", [], |r| r
                .get::<_, String>(0))
                .unwrap(),
            "active"
        );
    }
}

#[test]
fn cancelled_probe_guard_rolls_back_only_its_pending_fence() {
    let (app, _dir) = fixture();
    let token = {
        let conn = app.db.lock();
        schedule(&conn, "u");
        begin(&app, &conn, "work:repo", "u", true)
            .unwrap()
            .unwrap()
            .1
    };
    let guard = PendingRemoval {
        app: app.clone(),
        id: "work:repo".into(),
        token: token.clone(),
        armed: true,
    };
    drop(guard);
    assert!(!removed(&app.db.lock(), "work:repo").unwrap());
    assert_eq!(
        app.db
            .lock()
            .query_row("SELECT status FROM schedules", [], |r| r
                .get::<_, String>(0))
            .unwrap(),
        "active"
    );
    let new_token = begin(&app, &app.db.lock(), "work:repo", "u", true)
        .unwrap()
        .unwrap()
        .1;
    drop(PendingRemoval {
        app: app.clone(),
        id: "work:repo".into(),
        token,
        armed: true,
    });
    assert!(removed(&app.db.lock(), "work:repo").unwrap());
    finish(&app.db.lock(), "work:repo", &new_token).unwrap();
    drop(PendingRemoval {
        app: app.clone(),
        id: "work:repo".into(),
        token: new_token,
        armed: true,
    });
    assert!(completed(&app.db.lock(), "work:repo").unwrap());
}

#[test]
fn pending_input_from_another_owner_blocks_workspace_removal() {
    let (app, _dir) = fixture();
    let conn = app.db.lock();
    conn.execute("INSERT INTO conversation_submissions(owner_user,operation_id,workspace_id,node_id,local_workspace_id,session_id,node_operation_id,command_id,submission_hash,payload_json,state,created_at,updated_at) VALUES('other','draft','work:repo','work','repo','pending-session','pending-creation','pending-command',?1,'{}','preparing',1,1)", ["a".repeat(64)]).unwrap();
    assert_eq!(
        begin(&app, &conn, "work:repo", "u", true)
            .unwrap_err()
            .status,
        403
    );
    assert!(!removed(&conn, "work:repo").unwrap());
    let content: Option<String> = conn
        .query_row(
            "SELECT payload_json FROM conversation_submissions",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(content.as_deref(), Some("{}"));
    conn.execute(
        "UPDATE conversation_submissions SET state='cancelled',payload_json=NULL",
        [],
    )
    .unwrap();
    remove(&app, &conn, "work:repo", "u").unwrap();
    assert!(completed(&conn, "work:repo").unwrap());
}
