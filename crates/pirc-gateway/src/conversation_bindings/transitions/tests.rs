use super::*;
use crate::db::{CapabilitiesPatch, Db};
use pirc_protocol::{ModeId, NodeHttpResponse};
use std::sync::{Arc, Mutex};

pub(super) fn seed(db: &Connection) -> String {
    db.sync_remote_workspaces(
        "node",
        &["repo", "target", "third"]
            .map(|id| (id.into(), id.into(), ModeId::new("directory").unwrap())),
    )
    .unwrap();
    policies::install_catalog(db, &crate::app::test_modes()).unwrap();
    db.create_session(
        "node:repo",
        "node://node/private",
        "node",
        "Private",
        "alice",
    )
    .unwrap()
    .id
}
pub(super) fn input(db: &Connection, id: &str) -> Input {
    Input {
        operation_id: "move-1".into(),
        target_workspace_id: "node:target".into(),
        expected_binding: db.get_session(id).unwrap().binding,
    }
}
fn count(db: &Connection) -> i64 {
    db.query_row(
        "SELECT count(*) FROM conversation_transition_previews",
        [],
        |r| r.get(0),
    )
    .unwrap()
}
pub(super) fn identity() -> Identity {
    Identity {
        user: "alice".into(),
        device_id: None,
        management_authorized: false,
    }
}

#[test]
fn preview_survives_reboot_is_immutable_and_does_not_move_or_execute() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("db");
    let (id, input, hash) = {
        let db = Db::open(&path).unwrap();
        let db = db.lock();
        let id = seed(&db);
        let input = input(&db, &id);
        let row = reserve(&db, "alice", &id, &input).unwrap();
        assert_eq!(
            row.plan["source"]["environment"]["enforcement"],
            "not_tracked"
        );
        assert_eq!(row.plan["target"]["workspaceId"], "node:target");
        assert_eq!(db.get_session(&id).unwrap().workspace_id, "node:repo");
        assert_eq!(
            db.query_row("SELECT count(*) FROM commands", [], |r| r.get::<_, i64>(0))
                .unwrap(),
            0
        );
        assert!(
            db.execute(
                "UPDATE conversation_transition_previews SET plan_json='{}'",
                []
            )
            .is_err()
        );
        (id, input, row.plan_hash)
    };
    let db = Db::open(&path).unwrap();
    let db = db.lock();
    assert_eq!(reserve(&db, "alice", &id, &input).unwrap().plan_hash, hash);
    assert_eq!(count(&db), 1);
    let mut changed = input;
    changed.target_workspace_id = "node:third".into();
    assert_eq!(
        reserve(&db, "alice", &id, &changed).unwrap_err().status,
        409
    );
    assert!(read(&db, "bob", &id, "move-1").is_err());
    let other = db
        .create_session(
            "node:repo",
            "node://node/another",
            "node",
            "Another",
            "alice",
        )
        .unwrap();
    let another = Input {
        operation_id: "move-1".into(),
        target_workspace_id: "node:target".into(),
        expected_binding: other.binding,
    };
    assert_eq!(
        reserve(&db, "alice", &other.id, &another).unwrap_err().code,
        "conflict"
    );
    assert_eq!(count(&db), 1);
    db.execute("DELETE FROM sessions WHERE id=?", [&id])
        .unwrap();
    assert_eq!(count(&db), 0);
}
#[test]
fn stale_binding_private_target_and_failed_commit_do_not_create_previews() {
    let db = Db::memory();
    let db = db.lock();
    let id = seed(&db);
    let old = input(&db, &id);
    db.patch_workspace_capabilities(
        "node:repo",
        &serde_json::from_value::<CapabilitiesPatch>(json!({"web_search":false})).unwrap(),
    )
    .unwrap();
    assert_eq!(
        reserve(&db, "alice", &id, &old).unwrap_err().code,
        "stale_environment"
    );
    assert_eq!(count(&db), 0);
    let fresh = input(&db, &id);
    db.execute(
        "INSERT INTO checkpoint_workspace_owners VALUES('node:target','bob')",
        [],
    )
    .unwrap();
    assert_eq!(reserve(&db, "alice", &id, &fresh).unwrap_err().status, 404);
    db.execute("DELETE FROM checkpoint_workspace_owners", [])
        .unwrap();
    db.execute_batch("CREATE TRIGGER refuse_preview BEFORE INSERT ON conversation_transition_previews BEGIN SELECT RAISE(ABORT,'disk full'); END;").unwrap();
    assert!(reserve(&db, "alice", &id, &fresh).is_err());
    assert_eq!(count(&db), 0);
    assert_eq!(db.get_session(&id).unwrap().workspace_id, "node:repo");
}
#[test]
fn parallel_device_requests_share_one_frozen_identity() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("db");
    let db = Db::open(&path).unwrap();
    let id = seed(&db.lock());
    let spec = input(&db.lock(), &id);
    let barrier = std::sync::Barrier::new(4);
    let hashes = std::thread::scope(|scope| {
        (0..4)
            .map(|_| {
                scope.spawn(|| {
                    let db = Db::open(&path).unwrap();
                    barrier.wait();
                    reserve(&db.lock(), "alice", &id, &spec).unwrap().plan_hash
                })
            })
            .collect::<Vec<_>>()
            .into_iter()
            .map(|h| h.join().unwrap())
            .collect::<Vec<_>>()
    });
    assert!(hashes.iter().all(|h| h == &hashes[0]));
    assert_eq!(count(&db.lock()), 1);
}
#[test]
fn migration_preserves_old_binding_without_inventing_previews() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("db");
    let id = {
        let db = Db::open(&path).unwrap();
        let db = db.lock();
        let id = seed(&db);
        db.execute_batch("DROP TRIGGER conversation_node_fence_session_deleted; DROP TABLE conversation_node_fences; DROP TABLE conversation_transition_previews; PRAGMA user_version=1025;")
            .unwrap();
        id
    };
    let db = Db::open(&path).unwrap();
    assert_eq!(count(&db.lock()), 0);
    assert_eq!(
        db.lock().get_session(&id).unwrap().workspace_id,
        "node:repo"
    );
}

pub(super) fn app() -> (AppState, tempfile::TempDir, String) {
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
    let db = Arc::new(Db::memory());
    let id = seed(&db.lock());
    let app = crate::app::App::new(
        pirc_config::GatewayConfig::load(&env).unwrap(),
        db,
        backends,
        crate::app::test_modes(),
    );
    (app, dir, id)
}
pub(super) fn node() -> crate::nodes::ConnectedNode {
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
fn caps() -> NodeHttpResponse {
    NodeHttpResponse {
        status: 200,
        body: Some(json!({
            "version":1,"durableAdmissionFence":true,"trackedSupervisorDrain":true,
            "confirmsRevocation":false,"installsEnvironment":false,"privateUnexpectedField":"never expose"
        })),
    }
}
fn saved(app: &AppState, id: &str) -> Preview {
    let db = app.db.lock();
    reserve(&db, "alice", id, &input(&db, id)).unwrap()
}

#[tokio::test]
async fn offline_and_capability_only_previews_never_accept_or_fence_a_session() {
    let (app, _dir, id) = app();
    let before = app.db.lock().get_session(&id).unwrap().binding;
    let offline = describe(&app, &identity(), saved(&app, &id)).await.unwrap();
    assert_eq!(offline["canConfirm"], false);
    assert_eq!(offline["nodeObservations"][0]["status"], "offline");
    let calls = Arc::new(Mutex::new(Vec::new()));
    let seen = calls.clone();
    app.nodes.set_test_node(node(), move |r| {
        seen.lock().unwrap().push(r);
        Ok(caps())
    });
    let result = describe(&app, &identity(), saved(&app, &id)).await.unwrap();
    assert_eq!(result["state"], "preview");
    assert_eq!(result["canConfirm"], false);
    assert_eq!(result["nodeObservations"][0]["confirmsRevocation"], false);
    assert!(!result.to_string().contains("privateUnexpectedField"));
    let requests = calls.lock().unwrap();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, HttpMethod::Get);
    assert_eq!(requests[0].url, "/api/execution-fences/capabilities");
    assert!(requests[0].payload.is_none());
    assert_eq!(app.db.lock().get_session(&id).unwrap().binding, before);
}
#[tokio::test]
async fn policy_changes_and_connection_replacement_during_probe_invalidate_observations() {
    let (app, _dir, id) = app();
    let captured = saved(&app, &id);
    let db = app.db.clone();
    app.nodes.set_test_node(node(), move |_| {
        db.lock()
            .patch_workspace_capabilities(
                "node:target",
                &serde_json::from_value::<CapabilitiesPatch>(json!({"web_search":false})).unwrap(),
            )
            .unwrap();
        Ok(caps())
    });
    let result = describe(&app, &identity(), captured).await.unwrap();
    assert_eq!(result["state"], "stale");
    assert_eq!(result["canConfirm"], false);
    let nodes = app.nodes.clone();
    app.nodes.set_test_node(node(), move |_| {
        nodes.set_test_node(node(), |_| Ok(caps()));
        Ok(caps())
    });
    let result = describe(&app, &identity(), saved(&app, &id)).await.unwrap();
    assert_eq!(
        result["nodeObservations"][0]["status"],
        "connection_changed"
    );
}
#[tokio::test]
async fn revoked_device_cannot_receive_a_preview_after_the_probe() {
    let (app, _dir, id) = app();
    let (device, _token) = app.devices.create("alice", "Android").unwrap();
    let devices = app.devices.clone();
    let device_id = device.id.clone();
    app.nodes.set_test_node(node(), move |_| {
        devices.revoke("alice", &device_id).unwrap();
        Ok(caps())
    });
    let mut caller = identity();
    caller.device_id = Some(device.id);
    let result = describe(&app, &caller, saved(&app, &id)).await;
    assert_eq!(result.unwrap_err().status, 401);
}

pub(super) async fn http(
    app: &AppState,
    path: &str,
    payload: Option<Value>,
    token: Option<&str>,
) -> (u16, Value) {
    use tower::ServiceExt;
    let mut req = axum::http::Request::builder()
        .uri(path)
        .method(if payload.is_some() { "POST" } else { "GET" })
        .header("host", "a.example")
        .extension(axum::extract::ConnectInfo(
            "127.0.0.1:40000".parse::<std::net::SocketAddr>().unwrap(),
        ));
    if let Some(token) = token {
        req = req.header("authorization", format!("Bearer {token}"));
    } else {
        req = req
            .header("x-pirc-user", "alice")
            .header("origin", "https://a.example");
    }
    if payload.is_some() {
        req = req.header("content-type", "application/json");
    }
    let body = payload.map_or_else(axum::body::Body::empty, |v| {
        axum::body::Body::from(v.to_string())
    });
    let res = crate::app::router(app.clone())
        .oneshot(req.body(body).unwrap())
        .await
        .unwrap();
    let status = res.status().as_u16();
    let bytes = axum::body::to_bytes(res.into_body(), 1024 * 1024)
        .await
        .unwrap();
    (status, serde_json::from_slice(&bytes).unwrap())
}
#[tokio::test]
async fn web_and_paired_native_share_preview_without_browser_connection() {
    let (app, _dir, id) = app();
    let row = saved(&app, &id);
    let response = preflight_reply(&app, &id, &row);
    app.nodes.set_test_node(node(), move |r| {
        Ok(if r.method == HttpMethod::Get {
            preflight_caps()
        } else {
            response.clone()
        })
    });
    let (device, token) = app.devices.create("alice", "Android").unwrap();
    let payload = serde_json::to_value(input(&app.db.lock(), &id)).unwrap();
    let prepare_path = format!("/api/sessions/{id}/environment-transitions/previews");
    let native = http(&app, &prepare_path, Some(payload.clone()), Some(&token)).await;
    assert_eq!(native.0, 200, "{native:?}");
    let web = http(&app, &prepare_path, Some(payload), None).await;
    assert_eq!(web, native);
    let status_path = format!("/api/sessions/{id}/environment-transitions/previews/move-1");
    assert_eq!(http(&app, &status_path, None, Some(&token)).await, native);
    assert_eq!(native.1["canConfirm"], false);
    assert_eq!(native.1["resourcePreflight"]["status"], "observed");
    app.devices.revoke("alice", &device.id).unwrap();
    assert_eq!(http(&app, &status_path, None, Some(&token)).await.0, 401);
}

fn preflight_caps() -> NodeHttpResponse {
    let mut result = caps();
    result.body.as_mut().unwrap()["resourcePreflightVersion"] = json!(1);
    result
}
fn preflight_reply(app: &AppState, id: &str, row: &Preview) -> NodeHttpResponse {
    let session = app.db.lock().get_session(id).unwrap();
    let evidence = json!({"version":1,"sessionId":session.pi_session_id,"sourceWorkspaceId":"repo","targetWorkspaceId":"target",
        "runnerEpoch":777,
        "sourceMode":{"id":"directory","definitionHash":payload_hash(&row.plan["source"]["environment"]["modePolicy"]["definition"])},
        "targetMode":{"id":"directory","definitionHash":payload_hash(&row.plan["target"]["modePolicy"]["definition"])},
        "sourceResource":{"state":"observed","identity":"a".repeat(64),"privatePath":"/private/never-expose"},
        "targetResource":{"state":"observed","identity":"b".repeat(64)},"overlap":false,
        "activity":{"pendingRecords":false,"runnerPresent":false,"runnerStarting":false,"writeClaimsPresent":false,"fenced":false},
        "unrecognizedSecret":"never-expose"});
    NodeHttpResponse {
        status: 200,
        body: Some(
            json!({"evidenceHash":payload_hash(&evidence),"evidence":evidence,"canConfirm":false,"historyComplete":false}),
        ),
    }
}
#[tokio::test]
async fn resource_preflight_uses_original_mapping_and_never_forwards_private_node_fields() {
    let (app, _dir, id) = app();
    let row = saved(&app, &id);
    let response = preflight_reply(&app, &id, &row);
    let calls = Arc::new(Mutex::new(Vec::new()));
    let seen = calls.clone();
    app.nodes.set_test_node(node(), move |r| {
        seen.lock().unwrap().push(r.clone());
        Ok(if r.method == HttpMethod::Get {
            preflight_caps()
        } else {
            response.clone()
        })
    });
    let result = describe(&app, &identity(), row).await.unwrap();
    assert_eq!(result["resourcePreflight"]["status"], "observed");
    assert_eq!(
        result["resourcePreflight"]["observation"]["policiesMatch"],
        true
    );
    assert_eq!(result["canConfirm"], false);
    assert!(!result.to_string().contains("never-expose"));
    let calls = calls.lock().unwrap();
    assert_eq!(calls.len(), 2);
    assert_eq!(
        calls[1].url,
        "/api/sessions/Private/execution-fences/preflight"
    );
    assert_eq!(
        calls[1].payload.as_ref().unwrap()["expectedWorkspaceId"],
        "repo"
    );
    assert_eq!(
        calls[1].payload.as_ref().unwrap()["targetWorkspaceId"],
        "target"
    );
    assert_eq!(
        app.db.lock().get_session(&id).unwrap().workspace_id,
        "node:repo"
    );
}
#[tokio::test]
async fn resource_preflight_rejects_wrong_identity_hash_and_arbitrary_error_bodies() {
    for kind in 0..3 {
        let (app, _dir, id) = app();
        let row = saved(&app, &id);
        let mut response = preflight_reply(&app, &id, &row);
        if kind == 0 {
            let body = response.body.as_mut().unwrap();
            body["evidence"]["sessionId"] = json!("other-session");
            body["evidenceHash"] = json!(payload_hash(&body["evidence"]));
        }
        if kind == 1 {
            response.body.as_mut().unwrap()["evidenceHash"] = json!("0".repeat(64));
        }
        if kind == 2 {
            response.status = 500;
            response.body = Some(json!({"secret":"never-expose"}));
        }
        app.nodes.set_test_node(node(), move |r| {
            Ok(if r.method == HttpMethod::Get {
                preflight_caps()
            } else {
                response.clone()
            })
        });
        let result = describe(&app, &identity(), row).await.unwrap();
        assert_ne!(result["resourcePreflight"]["status"], "observed");
        assert!(!result.to_string().contains("other-session"));
        assert!(!result.to_string().contains("never-expose"));
        assert_eq!(result["canConfirm"], false);
    }
}
#[tokio::test]
async fn resource_preflight_discards_policy_or_connection_changes_during_host_wait() {
    for replace in [false, true] {
        let (app, _dir, id) = app();
        let row = saved(&app, &id);
        let response = preflight_reply(&app, &id, &row);
        let db = app.db.clone();
        let nodes = app.nodes.clone();
        app.nodes.set_test_node(node(), move |r| {
            if r.method == HttpMethod::Get {
                return Ok(preflight_caps());
            }
            if replace {
                nodes.set_test_node(node(), |_| Ok(caps()));
            } else {
                db.lock()
                    .patch_workspace_capabilities(
                        "node:target",
                        &serde_json::from_value::<CapabilitiesPatch>(json!({"web_search":false}))
                            .unwrap(),
                    )
                    .unwrap();
            }
            Ok(response.clone())
        });
        let result = describe(&app, &identity(), row).await.unwrap();
        assert_eq!(
            result["resourcePreflight"]["status"],
            if replace {
                "connection_changed"
            } else {
                "preview_stale"
            }
        );
        assert!(result["resourcePreflight"].get("observation").is_none());
    }
}
#[tokio::test]
async fn resource_preflight_rechecks_native_device_after_the_host_read() {
    let (app, _dir, id) = app();
    let row = saved(&app, &id);
    let response = preflight_reply(&app, &id, &row);
    let (device, _) = app.devices.create("alice", "Android").unwrap();
    let device_id = device.id.clone();
    let devices = app.devices.clone();
    app.nodes.set_test_node(node(), move |r| {
        if r.method == HttpMethod::Get {
            return Ok(preflight_caps());
        }
        devices.revoke("alice", &device_id).unwrap();
        Ok(response.clone())
    });
    let mut caller = identity();
    caller.device_id = Some(device.id);
    assert_eq!(describe(&app, &caller, row).await.unwrap_err().status, 401);
}

#[tokio::test]
async fn capability_wait_cannot_extend_device_or_policy_authority_to_host_inspection() {
    for revoke_device in [false, true] {
        let (app, _dir, id) = app();
        let row = saved(&app, &id);
        let (device, _) = app.devices.create("alice", "Android").unwrap();
        let devices = app.devices.clone();
        let device_id = device.id.clone();
        let db = app.db.clone();
        let posts = Arc::new(Mutex::new(0));
        let seen = posts.clone();
        app.nodes.set_test_node(node(), move |r| {
            if r.method == HttpMethod::Post {
                *seen.lock().unwrap() += 1;
            }
            if revoke_device {
                devices.revoke("alice", &device_id).unwrap();
            } else {
                db.lock()
                    .patch_workspace_capabilities(
                        "node:target",
                        &serde_json::from_value::<CapabilitiesPatch>(json!({"web_search":false}))
                            .unwrap(),
                    )
                    .unwrap();
            }
            Ok(preflight_caps())
        });
        let mut caller = identity();
        caller.device_id = Some(device.id);
        let result = describe(&app, &caller, row).await;
        if revoke_device {
            assert_eq!(result.unwrap_err().status, 401);
        } else {
            assert_eq!(
                result.unwrap()["resourcePreflight"]["status"],
                "preview_stale"
            );
        }
        assert_eq!(
            *posts.lock().unwrap(),
            0,
            "stale authority must not inspect host resources"
        );
    }
}
