use super::*;
use crate::db::{CapabilitiesPatch, Db};
use pirc_protocol::ModeId;
use serde_json::json;

fn seed(db: &Connection) {
    db.sync_remote_workspaces(
        "node",
        &[
            ("chats".into(), "Chats".into(), ModeId::new("chat").unwrap()),
            (
                "project".into(),
                "Project".into(),
                ModeId::new("chat").unwrap(),
            ),
            (
                "repo".into(),
                "Repo".into(),
                ModeId::new("directory").unwrap(),
            ),
            (
                "other".into(),
                "Other".into(),
                ModeId::new("directory").unwrap(),
            ),
            (
                "custom".into(),
                "Custom".into(),
                ModeId::new("research").unwrap(),
            ),
        ],
    )
    .unwrap();
}
fn create(db: &Connection, workspace: &str, name: &str) -> String {
    db.create_session(
        &format!("node:{workspace}"),
        &format!("node://node/{name}"),
        "node",
        name,
        "alice",
    )
    .unwrap()
    .id
}
fn view(db: &Connection, id: &str) -> Environment {
    environment(db, "alice", id).unwrap()
}
fn count(db: &Connection, table: &str) -> i64 {
    db.query_row(&format!("SELECT count(*) FROM {table}"), [], |r| r.get(0))
        .unwrap()
}
fn patch(raw: serde_json::Value) -> CapabilitiesPatch {
    serde_json::from_value(raw).unwrap()
}

#[test]
fn membership_classifies_legacy_projects_without_inventing_directory_projects() {
    let db = Db::memory();
    let conn = db.lock();
    seed(&conn);
    let ids: Vec<_> = ["chats", "project", "repo", "custom"]
        .iter()
        .map(|w| create(&conn, w, w))
        .collect();
    assert_eq!(view(&conn, &ids[1]).project.resolution, "unresolved");
    install_catalog(&conn, &crate::app::test_modes()).unwrap();
    for (id, resolution, project) in [
        (&ids[0], "none", None),
        (&ids[1], "member", Some("node:project")),
        (&ids[2], "none", None),
        (&ids[3], "mode_unavailable", None),
    ] {
        let v = view(&conn, id);
        assert_eq!(v.project.resolution, resolution);
        assert_eq!(v.project.workspace_id.as_deref(), project);
        assert_eq!(v.project.revision, 1);
        assert_eq!(v.binding.execution.generation, 1);
        assert_eq!(v.workspace_policy.capabilities, Capabilities::default());
        assert_eq!(v.workspace_policy.revision, 1);
        assert_eq!(v.enforcement, "not_tracked");
    }
    let new = create(&conn, "project", "new");
    assert_eq!(view(&conn, &new).project.resolution, "member");
    let repo = create(&conn, "repo", "move");
    conn.execute(
        "UPDATE sessions SET workspace_id='node:other' WHERE id=?",
        [&repo],
    )
    .unwrap();
    let v = view(&conn, &repo);
    assert_eq!(v.project.revision, 1); // legacy location is not project membership
    assert_eq!(v.binding.membership.revision, 2);
    assert_eq!(v.binding.execution.generation, 2);
}

#[test]
fn same_id_policy_edits_removal_and_restart_are_versioned_without_erasing_membership() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("db");
    let mut catalog = crate::app::test_modes();
    let db = Db::open(&path).unwrap();
    let id = {
        let conn = db.lock();
        seed(&conn);
        install_catalog(&conn, &catalog).unwrap();
        create(&conn, "project", "s")
    };
    let mode_id = ModeId::new("chat").unwrap();
    catalog.modes.get_mut(&mode_id).unwrap().body = "new rules".into();
    install_catalog(&db.lock(), &catalog).unwrap();
    assert_eq!(view(&db.lock(), &id).binding.execution.generation, 2);
    assert_eq!(view(&db.lock(), &id).project.revision, 1);
    let saved = catalog.modes.shift_remove(&mode_id).unwrap();
    install_catalog(&db.lock(), &catalog).unwrap();
    let v = view(&db.lock(), &id);
    assert_eq!(v.project.resolution, "mode_unavailable");
    assert_eq!(v.project.workspace_id.as_deref(), Some("node:project"));
    assert_eq!(v.project.revision, 2);
    assert_eq!(v.mode_policy.unwrap().revision, 3);
    assert_eq!(v.binding.execution.generation, 3);
    drop(db);
    let db = Db::open(&path).unwrap();
    install_catalog(&db.lock(), &catalog).unwrap();
    assert_eq!(view(&db.lock(), &id).binding.execution.generation, 3);
    catalog.modes.insert(mode_id, saved);
    install_catalog(&db.lock(), &catalog).unwrap();
    let v = view(&db.lock(), &id);
    assert_eq!(v.project.resolution, "member");
    assert_eq!(v.project.revision, 3);
    assert_eq!(v.mode_policy.unwrap().revision, 4);
    let bodies: Vec<Option<String>> = db
        .lock()
        .prepare(
            "SELECT mode_json FROM mode_policy_versions WHERE mode_id='chat' ORDER BY revision",
        )
        .unwrap()
        .query_map([], |r| r.get(0))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    assert_eq!(bodies.len(), 4);
    assert!(bodies[2].is_none());
    assert_ne!(bodies[0], bodies[1]);
    assert_eq!(bodies[1], bodies[3]);
}

#[test]
fn unavailable_destination_does_not_inherit_source_project_or_change_history() {
    let db = Db::memory();
    let conn = db.lock();
    seed(&conn);
    install_catalog(&conn, &crate::app::test_modes()).unwrap();
    let id = create(&conn, "project", "s");
    conn.execute(
        "UPDATE sessions SET workspace_id='node:custom' WHERE id=?",
        [&id],
    )
    .unwrap();
    let v = view(&conn, &id);
    assert_eq!(v.project.resolution, "mode_unavailable");
    assert!(v.project.workspace_id.is_none());
    assert_eq!(v.project.revision, 2);
    assert_eq!(v.binding.execution.generation, 2);
    assert_eq!(
        conn.get_session(&id).unwrap().pi_session_id.as_deref(),
        Some("s")
    );
}

#[test]
fn failed_catalog_install_rolls_back_versions_generation_and_membership() {
    let db = Db::memory();
    let conn = db.lock();
    seed(&conn);
    let mut catalog = crate::app::test_modes();
    install_catalog(&conn, &catalog).unwrap();
    let id = create(&conn, "project", "s");
    let before = serde_json::to_value(view(&conn, &id)).unwrap();
    conn.execute_batch("CREATE TRIGGER fail_project_update BEFORE UPDATE ON conversation_project_memberships BEGIN SELECT RAISE(ABORT,'test failure'); END;").unwrap();
    catalog
        .modes
        .get_mut(&ModeId::new("chat").unwrap())
        .unwrap()
        .projects = false;
    assert!(install_catalog(&conn, &catalog).is_err());
    assert_eq!(serde_json::to_value(view(&conn, &id)).unwrap(), before);
    assert_eq!(count(&conn, "mode_policy_versions"), 3);
}

#[test]
fn capabilities_have_atomic_snapshots_noop_stability_and_default_reset() {
    let db = Db::memory();
    let conn = db.lock();
    seed(&conn);
    install_catalog(&conn, &crate::app::test_modes()).unwrap();
    let id = create(&conn, "project", "s");
    conn.patch_workspace_capabilities("node:project", &patch(json!({"delegation":true})))
        .unwrap();
    assert_eq!(view(&conn, &id).workspace_policy.revision, 1);
    conn.patch_workspace_capabilities("node:project", &patch(json!({"web_search":false})))
        .unwrap();
    let v = view(&conn, &id);
    assert_eq!(v.workspace_policy.revision, 2);
    assert_eq!(v.binding.execution.generation, 2);
    assert_eq!(v.project.revision, 1);
    conn.execute(
        "DELETE FROM workspace_capabilities WHERE workspace_id='node:project'",
        [],
    )
    .unwrap();
    let v = view(&conn, &id);
    assert_eq!(v.workspace_policy.revision, 3);
    assert_eq!(v.binding.execution.generation, 3);
    assert_eq!(v.workspace_policy.capabilities, Capabilities::default());
    // Overflow rejects the whole patch, not just the version bump.
    conn.execute(
        "UPDATE conversation_bindings SET generation=9007199254740991 WHERE session_id=?",
        [&id],
    )
    .unwrap();
    assert!(
        conn.patch_workspace_capabilities("node:project", &patch(json!({"web_search":false})))
            .is_err()
    );
    assert_eq!(
        conn.get_workspace_capabilities("node:project").unwrap(),
        Capabilities::default()
    );
    assert_eq!(view(&conn, &id).workspace_policy.revision, 3);
    conn.begin_session_deletion(&id, "alice").unwrap();
    conn.finish_session_deletion(&id).unwrap();
    assert_eq!(count(&conn, "conversation_project_memberships"), 0);
    conn.execute(
        "DELETE FROM workspace_capabilities WHERE workspace_id='node:project'",
        [],
    )
    .unwrap();
    conn.execute("DELETE FROM workspaces WHERE id='node:project'", [])
        .unwrap();
    assert_eq!(
        conn.query_row(
            "SELECT count(*) FROM workspace_policy_versions WHERE workspace_id='node:project'",
            [],
            |r| r.get::<_, i64>(0)
        )
        .unwrap(),
        0
    );
}

#[test]
fn concurrent_independent_capability_patches_preserve_both_edits_and_consistent_versions() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("db");
    let id = {
        let db = Db::open(&path).unwrap();
        let conn = db.lock();
        seed(&conn);
        install_catalog(&conn, &crate::app::test_modes()).unwrap();
        create(&conn, "project", "s")
    };
    let gate = std::sync::Barrier::new(2);
    std::thread::scope(|scope| {
        let handles: Vec<_> = [json!({"web_search":false}), json!({"remote_recall":false})]
            .into_iter()
            .map(|raw| {
                let path = &path;
                let gate = &gate;
                scope.spawn(move || {
                    let db = Db::open(path).unwrap();
                    gate.wait();
                    db.lock()
                        .patch_workspace_capabilities("node:project", &patch(raw))
                        .unwrap();
                })
            })
            .collect();
        for handle in handles {
            handle.join().unwrap();
        }
    });
    let db = Db::open(&path).unwrap();
    let v = view(&db.lock(), &id);
    assert!(
        !v.workspace_policy.capabilities.web_search
            && !v.workspace_policy.capabilities.remote_recall
    );
    assert_eq!(v.workspace_policy.revision, 3);
    assert_eq!(v.binding.execution.generation, 3);
}

#[test]
fn read_requires_owner_and_checkpoint_visibility_even_without_a_live_node() {
    let db = Db::memory();
    let conn = db.lock();
    seed(&conn);
    install_catalog(&conn, &crate::app::test_modes()).unwrap();
    let id = create(&conn, "repo", "s");
    assert_eq!(environment(&conn, "bob", &id).unwrap_err().status, 403);
    conn.execute("UPDATE sessions SET pi_session_id=NULL WHERE id=?", [&id])
        .unwrap();
    assert_eq!(view(&conn, &id).session_id, id);
    conn.mark_checkpoint_workspace_private("node:repo").unwrap();
    assert_eq!(environment(&conn, "alice", &id).unwrap_err().status, 404);
    conn.claim_checkpoint_workspace("node:repo", "alice")
        .unwrap();
    assert_eq!(view(&conn, &id).session_id, id);
    conn.begin_session_deletion(&id, "alice").unwrap();
    assert_eq!(environment(&conn, "alice", &id).unwrap_err().status, 409);
}

fn app() -> (AppState, tempfile::TempDir) {
    let dir = tempfile::tempdir().unwrap();
    let state = dir.path().join("state");
    let env = pirc_config::Env::new(
        [
            (
                "PIRC_NODE_TOKENS",
                r#"{"node":"0123456789abcdef0123456789abcdef"}"#,
            ),
            ("PIRC_TRUSTED_PROXIES", "127.0.0.1"),
            ("PIRC_PROXY_SECRET_REQUIRED", "false"),
            ("PIRC_ALLOWED_ORIGINS", "https://a.example"),
            ("PIRC_ALLOWED_HOSTS", "a.example"),
            ("PIRC_ALLOWED_USERS", "alice,bob"),
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
    seed(&app.db.lock());
    (app, dir)
}

async fn http(
    app: &AppState,
    id: &str,
    user: Option<&str>,
    token: Option<&str>,
) -> (u16, serde_json::Value) {
    use tower::ServiceExt;
    let mut req = axum::http::Request::builder()
        .header(crate::capabilities::HEADER, "test/2")
        .uri(format!("/api/sessions/{id}/environment"))
        .header("host", "a.example")
        .extension(axum::extract::ConnectInfo(
            "127.0.0.1:40000".parse::<std::net::SocketAddr>().unwrap(),
        ));
    if let Some(user) = user {
        req = req
            .header("x-pirc-user", user)
            .header("origin", "https://a.example");
    }
    if let Some(token) = token {
        req = req.header("authorization", format!("Bearer {token}"));
    }
    let res = crate::app::router(app.clone())
        .oneshot(req.body(axum::body::Body::empty()).unwrap())
        .await
        .unwrap();
    let code = res.status().as_u16();
    assert!(res.headers().get("cache-control").is_some());
    let bytes = axum::body::to_bytes(res.into_body(), 1024 * 1024)
        .await
        .unwrap();
    (code, serde_json::from_slice(&bytes).unwrap())
}

#[tokio::test]
async fn web_and_paired_android_read_identical_offline_state_with_owner_and_revocation_checks() {
    let (app, _dir) = app();
    let id = create(&app.db.lock(), "project", "s");
    let (device, token) = app.devices.create("alice", "Android").unwrap();
    let (_, other) = app.devices.create("bob", "Other phone").unwrap();
    let web = http(&app, &id, Some("alice"), None).await;
    let native = http(&app, &id, None, Some(&token)).await;
    assert_eq!(web.0, 200);
    assert_eq!(native, web);
    assert_eq!(web.1["project"]["workspaceId"], "node:project");
    assert_eq!(web.1["enforcement"], "not_tracked");
    assert!(web.1.get("piSessionId").is_none());
    assert_eq!(http(&app, &id, Some("bob"), None).await.0, 403);
    assert_eq!(http(&app, &id, None, Some(&other)).await.0, 403);
    assert_eq!(http(&app, &id, None, None).await.0, 401);
    app.replace_catalog(ModeCatalog::default()).unwrap();
    let unavailable = http(&app, &id, None, Some(&token)).await;
    assert_eq!(unavailable.0, 200);
    assert_eq!(unavailable.1["project"]["resolution"], "mode_unavailable");
    assert!(unavailable.1["modePolicy"]["definition"].is_null());
    app.devices.revoke("alice", &device.id).unwrap();
    assert_eq!(http(&app, &id, None, Some(&token)).await.0, 401);
}

#[test]
fn failed_catalog_publication_keeps_the_running_catalog_and_versions() {
    let (app, _dir) = app();
    let id = create(&app.db.lock(), "project", "s");
    let before = app.catalog();
    app.db.lock().execute_batch("CREATE TRIGGER fail_mode_insert BEFORE INSERT ON mode_policy_versions BEGIN SELECT RAISE(ABORT,'disk failure'); END;").unwrap();
    assert!(app.replace_catalog(ModeCatalog::default()).is_err());
    assert_eq!(*app.catalog(), *before);
    assert_eq!(view(&app.db.lock(), &id).binding.execution.generation, 1);
    assert_eq!(view(&app.db.lock(), &id).project.resolution, "member");
}

#[test]
fn histories_cannot_be_edited_or_deleted_independently_and_workspace_cascade_still_works() {
    let db = Db::memory();
    let conn = db.lock();
    seed(&conn);
    install_catalog(&conn, &crate::app::test_modes()).unwrap();
    for sql in [
        "UPDATE mode_policy_versions SET mode_json=NULL",
        "DELETE FROM mode_policy_versions",
        "UPDATE workspace_policy_versions SET policy_json='{}'",
        "DELETE FROM workspace_policy_versions",
    ] {
        assert!(conn.execute(sql, []).is_err(), "{sql}");
    }
    conn.patch_workspace_capabilities("node:project", &patch(json!({"web_search":false})))
        .unwrap();
    conn.execute(
        "DELETE FROM workspace_capabilities WHERE workspace_id='node:project'",
        [],
    )
    .unwrap();
    conn.execute("DELETE FROM workspaces WHERE id='node:project'", [])
        .unwrap();
    assert_eq!(
        conn.query_row(
            "SELECT count(*) FROM workspace_policy_versions WHERE workspace_id='node:project'",
            [],
            |r| r.get::<_, i64>(0)
        )
        .unwrap(),
        0
    );
}
