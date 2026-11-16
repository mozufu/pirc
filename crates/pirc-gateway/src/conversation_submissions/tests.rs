use super::*;
use crate::{app::App, db::Db};
use std::sync::Arc;

pub(super) fn input() -> Input {
    serde_json::from_value(json!({"operationId":"draft-1","submission":{
        "workspaceId":"node:repo","message":"Keep this first message",
        "attachments":[{"id":"file-1","name":"notes.txt","mimeType":"text/plain","byteSize":4,"sha256":"a".repeat(64)}]
    }})).unwrap()
}
pub(super) fn setup(db: &Connection) {
    db.sync_remote_workspaces(
        "node",
        &[
            (
                "repo".into(),
                "Repo".into(),
                pirc_protocol::ModeId::new("directory").unwrap(),
            ),
            (
                "other".into(),
                "Other".into(),
                pirc_protocol::ModeId::new("directory").unwrap(),
            ),
        ],
    )
    .unwrap();
}
pub(super) fn count(db: &Connection, table: &str) -> i64 {
    db.query_row(&format!("SELECT count(*) FROM {table}"), [], |r| r.get(0))
        .unwrap()
}
fn identities(db: &Connection, owner: &str, id: &str) -> (String, String, String) {
    db.query_row("SELECT session_id,node_operation_id,command_id FROM conversation_submissions WHERE owner_user=?1 AND operation_id=?2",params![owner,id],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?))).unwrap()
}

#[test]
fn preparation_survives_restart_without_publishing_or_executing() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("gateway.sqlite");
    let identity = {
        let db = Db::open(&path).unwrap();
        setup(&db.lock());
        let row = reserve(&mut db.lock(), "alice", &input()).unwrap();
        assert!(!row.accepted);
        assert_eq!(row.state, Phase::Preparing);
        assert_eq!(count(&db.lock(), "sessions"), 0);
        assert_eq!(count(&db.lock(), "commands"), 0);
        identities(&db.lock(), "alice", "draft-1")
    };
    let db = Db::open(&path).unwrap();
    let row = reserve(&mut db.lock(), "alice", &input()).unwrap();
    assert_eq!(identities(&db.lock(), "alice", "draft-1"), identity);
    assert_eq!(row.submission.unwrap().message, "Keep this first message");
    assert_eq!(count(&db.lock(), "conversation_submissions"), 1);
    assert!(db.lock().list_sessions().unwrap().is_empty());
}

#[test]
fn concurrent_connections_reserve_one_set_of_identities() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("gateway.sqlite");
    setup(&Db::open(&path).unwrap().lock());
    let barrier = std::sync::Barrier::new(6);
    let ids = std::thread::scope(|scope| {
        (0..6)
            .map(|_| {
                scope.spawn(|| {
                    let db = Db::open(&path).unwrap();
                    barrier.wait();
                    reserve(&mut db.lock(), "alice", &input()).unwrap();
                    identities(&db.lock(), "alice", "draft-1")
                })
            })
            .collect::<Vec<_>>()
            .into_iter()
            .map(|h| h.join().unwrap())
            .collect::<Vec<_>>()
    });
    assert!(ids.iter().all(|id| id == &ids[0]));
    let db = Db::open(&path).unwrap();
    assert_eq!(count(&db.lock(), "conversation_submissions"), 1);
    assert_eq!(count(&db.lock(), "sessions"), 0);
}

#[test]
fn separate_drafts_and_owners_are_independent_even_with_the_same_text() {
    let db = Db::memory();
    setup(&db.lock());
    let first = reserve(&mut db.lock(), "alice", &input()).unwrap();
    let second = reserve(&mut db.lock(), "bob", &input()).unwrap();
    let mut other = input();
    other.operation_id = "draft-2".into();
    let third = reserve(&mut db.lock(), "alice", &other).unwrap();
    assert_ne!(first.session_id, second.session_id);
    assert_ne!(first.session_id, third.session_id);
    assert_eq!(
        lookup(&db.lock(), "carol", "draft-1").unwrap_err().status,
        404
    );
    assert_eq!(
        cancel(&db.lock(), "carol", "draft-1").unwrap_err().status,
        404
    );
}

#[test]
fn immutable_key_rejects_changed_content_target_settings_and_manifest() {
    let db = Db::memory();
    setup(&db.lock());
    reserve(&mut db.lock(), "alice", &input()).unwrap();
    let original = serde_json::to_value(lookup(&db.lock(), "alice", "draft-1").unwrap()).unwrap();
    for variant in 0..7 {
        let mut changed = input();
        match variant {
            0 => changed.submission.message.push('!'),
            1 => changed.submission.workspace_id = "node:other".into(),
            2 => {
                changed.submission.model = Some(ModelChoice {
                    provider: "p".into(),
                    id: "m".into(),
                })
            }
            3 => changed.submission.thinking = Some(ThinkingLevel::High),
            4 => changed.submission.attachments[0].sha256 = "b".repeat(64),
            5 => changed.submission.attachments[0].byte_size = 5,
            _ => changed.submission.attachments[0].name = "different.txt".into(),
        }
        assert_eq!(
            reserve(&mut db.lock(), "alice", &changed).unwrap_err().code,
            "submission_conflict"
        );
    }
    assert_eq!(
        serde_json::to_value(lookup(&db.lock(), "alice", "draft-1").unwrap()).unwrap(),
        original
    );
}

#[test]
fn cancellation_scrubs_content_but_never_releases_the_identity() {
    let db = Db::memory();
    setup(&db.lock());
    let first = reserve(&mut db.lock(), "alice", &input()).unwrap();
    let cancelled = cancel(&db.lock(), "alice", "draft-1").unwrap();
    assert_eq!(cancelled.state, Phase::Cancelled);
    assert!(cancelled.submission.is_none());
    assert_eq!(cancelled.session_id, first.session_id);
    assert_eq!(cancelled.hash, first.hash);
    assert_eq!(
        cancel(&db.lock(), "alice", "draft-1").unwrap().state,
        Phase::Cancelled
    );
    assert_eq!(
        reserve(&mut db.lock(), "alice", &input()).unwrap().state,
        Phase::Cancelled
    );
    let mut changed = input();
    changed.submission.message = "new secret".into();
    assert_eq!(
        reserve(&mut db.lock(), "alice", &changed)
            .unwrap_err()
            .status,
        409
    );
    let body = serde_json::to_value(cancelled).unwrap();
    assert!(body.get("submission").is_none());
    assert!(body.get("hash").is_none());
}

#[test]
fn project_deletion_scrubs_pending_content_and_blocks_new_preparations() {
    let db = Db::memory();
    setup(&db.lock());
    reserve(&mut db.lock(), "alice", &input()).unwrap();
    db.lock()
        .begin_workspace_deletion("node:repo", "alice")
        .unwrap();
    assert_eq!(
        lookup(&db.lock(), "alice", "draft-1").unwrap().state,
        Phase::Cancelled
    );
    assert_eq!(
        reserve(&mut db.lock(), "alice", &input()).unwrap().state,
        Phase::Cancelled
    );
    let mut fresh = input();
    fresh.operation_id = "fresh".into();
    assert_eq!(
        reserve(&mut db.lock(), "alice", &fresh).unwrap_err().status,
        409
    );
    assert_eq!(count(&db.lock(), "sessions"), 0);
}

#[test]
fn project_deletion_cannot_discard_another_owners_pending_input() {
    let db = Db::memory();
    setup(&db.lock());
    reserve(&mut db.lock(), "bob", &input()).unwrap();
    assert_eq!(
        db.lock()
            .begin_workspace_deletion("node:repo", "alice")
            .unwrap_err()
            .status,
        403
    );
    assert_eq!(count(&db.lock(), "workspace_deletions"), 0);
    assert!(
        lookup(&db.lock(), "bob", "draft-1")
            .unwrap()
            .submission
            .is_some()
    );
    cancel(&db.lock(), "bob", "draft-1").unwrap();
    db.lock()
        .begin_workspace_deletion("node:repo", "alice")
        .unwrap();
}

#[test]
fn workspace_removal_cancels_only_when_committed_and_restore_does_not_revive() {
    let db = Db::memory();
    setup(&db.lock());
    reserve(&mut db.lock(), "alice", &input()).unwrap();
    db.lock().execute("INSERT INTO workspace_removals(workspace_id,owner_user,removed_at,status,token) VALUES('node:repo','alice',1,'checking','token')",[]).unwrap();
    assert_eq!(
        lookup(&db.lock(), "alice", "draft-1").unwrap().state,
        Phase::Preparing
    );
    db.lock()
        .execute(
            "UPDATE workspace_removals SET status='removed' WHERE workspace_id='node:repo'",
            [],
        )
        .unwrap();
    assert!(
        lookup(&db.lock(), "alice", "draft-1")
            .unwrap()
            .submission
            .is_none()
    );
    db.lock()
        .execute("DELETE FROM workspace_removals", [])
        .unwrap();
    assert_eq!(
        reserve(&mut db.lock(), "alice", &input()).unwrap().state,
        Phase::Cancelled
    );
}

#[test]
fn session_tombstone_and_hard_workspace_delete_scrub_content() {
    for session_delete in [true, false] {
        let db = Db::memory();
        setup(&db.lock());
        let row = reserve(&mut db.lock(), "alice", &input()).unwrap();
        if session_delete {
            db.lock().execute("INSERT INTO session_deletions(session_id,owner_user,status,created_at,workspace_id) VALUES(?1,'alice','deleting',1,'node:repo')",[row.session_id]).unwrap();
        } else {
            db.lock()
                .execute("DELETE FROM workspaces WHERE id='node:repo'", [])
                .unwrap();
        }
        assert_eq!(
            lookup(&db.lock(), "alice", "draft-1").unwrap().state,
            Phase::Cancelled
        );
        assert!(
            lookup(&db.lock(), "alice", "draft-1")
                .unwrap()
                .submission
                .is_none()
        );
    }
}

#[test]
fn preparation_preserves_private_recovery_workspace_ownership() {
    let db = Db::memory();
    setup(&db.lock());
    db.lock()
        .mark_checkpoint_workspace_private("node:repo")
        .unwrap();
    assert_eq!(
        reserve(&mut db.lock(), "alice", &input())
            .unwrap_err()
            .status,
        404
    );
    db.lock()
        .claim_checkpoint_workspace("node:repo", "alice")
        .unwrap();
    reserve(&mut db.lock(), "alice", &input()).unwrap();
    assert_eq!(
        reserve(&mut db.lock(), "bob", &input()).unwrap_err().status,
        404
    );
}

#[test]
fn strict_validation_bounds_text_and_attachment_manifests() {
    input().validate(4).unwrap();
    assert!(input().validate(3).is_err());
    for variant in 0..9 {
        let mut bad = input();
        match variant {
            0 => bad.operation_id = "../bad".into(),
            1 => bad.submission.attachments[0].name = "../file".into(),
            2 => bad.submission.attachments[0].sha256 = "not a hash".into(),
            3 => bad.submission.attachments[0].mime_type = "text/plain;token=secret".into(),
            4 => bad
                .submission
                .attachments
                .push(bad.submission.attachments[0].clone()),
            5 => bad.submission.attachments = vec![bad.submission.attachments[0].clone(); 17],
            6 => bad.submission.attachments[0].byte_size = 0,
            7 => bad.submission.attachments[0].name = "x".repeat(256),
            _ => {
                bad.submission.attachments.clear();
                bad.submission.message = " ".into();
            }
        }
        assert!(bad.validate(100).is_err(), "variant {variant}");
    }
    let mut boundary = input();
    boundary.submission.message = "😀".repeat(500_000);
    boundary.validate(4).unwrap();
    boundary.submission.message.push('x');
    assert!(boundary.validate(4).is_err());
    assert!(serde_json::from_value::<Input>(json!({"operationId":"a","owner":"bob","submission":{"workspaceId":"node:repo","message":"text"}})).is_err());
}

#[test]
fn migration_from_1011_preserves_sessions_and_installs_cleanup_triggers() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("gateway.sqlite");
    let prior = Connection::open(&path).unwrap();
    prior
        .execute_batch(concat!(
            include_str!("../schema.sql"),
            include_str!("../calendar/schema.sql"),
            include_str!("../pots/schema.sql"),
            "PRAGMA user_version=1011;"
        ))
        .unwrap();
    setup(&prior);
    prior.execute("INSERT INTO sessions(id,workspace_id,private_session_path,name,node_id,pi_session_id,owner_user,created_at,updated_at) VALUES('old','node:repo','node://node/old','Old','node','old','alice',1,1)", []).unwrap();
    drop(prior);
    let db = Db::open(&path).unwrap();
    assert_eq!(db.lock().get_session("old").unwrap().id, "old");
    assert_eq!(
        db.lock()
            .query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        crate::db::SCHEMA_VERSION
    );
    reserve(&mut db.lock(), "alice", &input()).unwrap();
    db.lock()
        .begin_workspace_deletion("node:repo", "alice")
        .unwrap();
    assert_eq!(
        lookup(&db.lock(), "alice", "draft-1").unwrap().state,
        Phase::Cancelled
    );
}

/// A Gateway with first-send admission enabled (`PIRC_FIRST_SEND=1`).
pub(super) fn app() -> (AppState, tempfile::TempDir) {
    app_with_database(false, true)
}
pub(super) fn disk_app() -> (AppState, tempfile::TempDir) {
    app_with_database(true, true)
}
/// A Gateway with the shipped default: first-send admission closed.
pub(super) fn closed_app() -> (AppState, tempfile::TempDir) {
    app_with_database(false, false)
}
/// Turns the rollout off for an already running Gateway, as an operator restart
/// with `PIRC_FIRST_SEND` unset would, while keeping its database and Node links.
pub(super) fn close_rollout(app: AppState) -> AppState {
    let mut inner = Arc::try_unwrap(app)
        .ok()
        .expect("no other holder of the app while the setting changes");
    inner.config.first_send = false;
    Arc::new(inner)
}
fn env_for(
    state: &std::path::Path,
    config_dir: &std::path::Path,
    first_send: bool,
) -> pirc_config::Env {
    pirc_config::Env::new(
        [
            ("PIRC_FIRST_SEND", if first_send { "1" } else { "0" }),
            (
                "PIRC_NODE_TOKENS",
                r#"{"node":"0123456789abcdef0123456789abcdef"}"#,
            ),
            ("PIRC_TRUSTED_PROXIES", "127.0.0.1"),
            ("PIRC_ALLOWED_ORIGINS", "https://a.example"),
            ("PIRC_ALLOWED_HOSTS", "a.example"),
            ("PIRC_ALLOWED_USERS", "alice,bob"),
            ("PIRC_STATE_DIR", state.to_str().unwrap()),
            ("PIRC_CONFIG_DIR", config_dir.to_str().unwrap()),
            ("PIRC_TIMEZONE", "UTC"),
            ("HOME", "/home/test"),
        ],
        "/work",
    )
}
fn app_with_database(on_disk: bool, first_send: bool) -> (AppState, tempfile::TempDir) {
    let dir = tempfile::tempdir().unwrap();
    let state = dir.path().join("state");
    let env = env_for(&state, dir.path(), first_send);
    let backends =
        pirc_providers::backends::BackendService::open(&state, crate::app::empty_models()).unwrap();
    let db = if on_disk {
        Db::open(&state.join("gateway.sqlite")).unwrap()
    } else {
        Db::memory()
    };
    let app = App::new(
        pirc_config::GatewayConfig::load(&env).unwrap(),
        Arc::new(db),
        backends,
        crate::app::test_modes(),
    );
    setup(&app.db.lock());
    (app, dir)
}
pub(super) async fn call(
    app: &AppState,
    method: &str,
    path: &str,
    user: Option<&str>,
    token: Option<&str>,
    body: Option<Value>,
) -> (u16, Value) {
    use tower::ServiceExt;
    let mut req = axum::http::Request::builder()
        .method(method)
        .uri(path)
        .header("host", "a.example")
        .header("x-pirc-first-send-contract", "2")
        .extension(axum::extract::ConnectInfo(
            "127.0.0.1:40000".parse::<std::net::SocketAddr>().unwrap(),
        ));
    if token.is_none() {
        req = req.header("origin", "https://a.example");
    }
    if let Some(user) = user {
        req = req.header("x-pirc-user", user);
    }
    if let Some(token) = token {
        req = req.header("authorization", format!("Bearer {token}"));
    }
    let bytes = if let Some(body) = body {
        req = req.header("content-type", "application/json");
        body.to_string()
    } else {
        String::new()
    };
    let response = crate::app::router(app.clone())
        .oneshot(req.body(axum::body::Body::from(bytes)).unwrap())
        .await
        .unwrap();
    let code = response.status().as_u16();
    let bytes = axum::body::to_bytes(response.into_body(), 4 * 1024 * 1024)
        .await
        .unwrap();
    (
        code,
        if bytes.is_empty() {
            Value::Null
        } else {
            serde_json::from_slice(&bytes).unwrap()
        },
    )
}
pub(super) fn body() -> Value {
    json!({"operationId":"draft-1","submission":serde_json::to_value(input().submission).unwrap()})
}

#[tokio::test]
async fn http_preparation_and_lookup_are_owner_scoped_and_not_acceptance() {
    let (app, _dir) = app();
    let (code, first) = call(
        &app,
        "POST",
        "/api/conversation-submissions/prepare",
        Some("alice"),
        None,
        Some(body()),
    )
    .await;
    assert_eq!(code, 200);
    assert_eq!(first["preparation"]["accepted"], false);
    assert_eq!(first["preparation"]["state"], "preparing");
    let (code, retry) = call(
        &app,
        "POST",
        "/api/conversation-submissions/prepare",
        Some("alice"),
        None,
        Some(body()),
    )
    .await;
    assert_eq!(code, 200);
    assert_eq!(retry, first);
    let path = "/api/conversation-submissions/draft-1";
    assert_eq!(
        call(&app, "GET", path, Some("alice"), None, None).await.1,
        first
    );
    assert_eq!(
        call(&app, "GET", path, Some("bob"), None, None).await.0,
        404
    );
    assert_eq!(
        call(&app, "DELETE", path, Some("bob"), None, None).await.0,
        404
    );
    assert_eq!(call(&app, "GET", path, None, None, None).await.0, 401);
    assert_eq!(count(&app.db.lock(), "sessions"), 0);
    assert_eq!(count(&app.db.lock(), "commands"), 0);
    let app = close_rollout(app);
    assert_eq!(
        call(
            &app,
            "GET",
            "/api/conversation-submissions/capabilities",
            Some("alice"),
            None,
            None
        )
        .await
        .1["canSubmit"],
        false
    );
}

#[tokio::test]
async fn http_rejects_invalid_input_and_unavailable_mode_before_reserving() {
    let (app, _dir) = app();
    let mut bad = body();
    bad["owner_user"] = json!("bob");
    assert_eq!(
        call(
            &app,
            "POST",
            "/api/conversation-submissions/prepare",
            Some("alice"),
            None,
            Some(bad)
        )
        .await
        .0,
        400
    );
    let mut bad = body();
    bad["submission"]["model"] = json!({"provider":"missing","id":"missing"});
    assert_eq!(
        call(
            &app,
            "POST",
            "/api/conversation-submissions/prepare",
            Some("alice"),
            None,
            Some(bad)
        )
        .await
        .0,
        400
    );
    app.modes
        .write()
        .unwrap()
        .clone_from(&Arc::new(Default::default()));
    assert_eq!(
        call(
            &app,
            "POST",
            "/api/conversation-submissions/prepare",
            Some("alice"),
            None,
            Some(body())
        )
        .await
        .0,
        409
    );
    assert_eq!(count(&app.db.lock(), "conversation_submissions"), 0);
}

#[tokio::test]
async fn http_cancel_stays_queryable_after_mode_removal_and_rejects_changed_retries() {
    let (app, _dir) = app();
    assert_eq!(
        call(
            &app,
            "POST",
            "/api/conversation-submissions/prepare",
            Some("alice"),
            None,
            Some(body())
        )
        .await
        .0,
        200
    );
    app.modes
        .write()
        .unwrap()
        .clone_from(&Arc::new(Default::default()));
    let cancelled = call(
        &app,
        "DELETE",
        "/api/conversation-submissions/draft-1",
        Some("alice"),
        None,
        None,
    )
    .await;
    assert_eq!(cancelled.0, 200);
    assert_eq!(cancelled.1["preparation"]["state"], "cancelled");
    assert!(cancelled.1["preparation"].get("submission").is_none());
    assert_eq!(
        call(
            &app,
            "POST",
            "/api/conversation-submissions/prepare",
            Some("alice"),
            None,
            Some(body())
        )
        .await
        .1,
        cancelled.1
    );
    let mut changed = body();
    changed["submission"]["message"] = json!("changed");
    assert_eq!(
        call(
            &app,
            "POST",
            "/api/conversation-submissions/prepare",
            Some("alice"),
            None,
            Some(changed)
        )
        .await
        .0,
        409
    );
}

#[tokio::test]
async fn paired_device_prepares_and_queries_without_a_browser_or_management_grant() {
    let (app, _dir) = app();
    let (device, token) = app.devices.create("alice", "Android").unwrap();
    let (_, other_token) = app.devices.create("bob", "Other Android").unwrap();
    let first = call(
        &app,
        "POST",
        "/api/conversation-submissions/prepare",
        None,
        Some(&token),
        Some(body()),
    )
    .await;
    assert_eq!(first.0, 200);
    let path = "/api/conversation-submissions/draft-1";
    assert_eq!(
        call(&app, "GET", path, None, Some(&token), None).await.1,
        first.1
    );
    // The same account on Web observes the same operation; another account cannot.
    assert_eq!(
        call(&app, "GET", path, Some("alice"), None, None).await.1,
        first.1
    );
    assert_eq!(
        call(&app, "GET", path, None, Some(&other_token), None)
            .await
            .0,
        404
    );
    assert_eq!(
        call(&app, "DELETE", path, None, Some(&other_token), None)
            .await
            .0,
        404
    );
    app.devices.revoke("alice", &device.id).unwrap();
    assert_eq!(
        call(&app, "GET", path, None, Some(&token), None).await.0,
        401
    );
    assert_eq!(count(&app.db.lock(), "sessions"), 0);
    assert_eq!(count(&app.db.lock(), "commands"), 0);
}

#[test]
fn concurrent_retry_cancellation_and_project_deletion_never_revive_content() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("gateway.sqlite");
    {
        let db = Db::open(&path).unwrap();
        setup(&db.lock());
        reserve(&mut db.lock(), "alice", &input()).unwrap();
    }
    let barrier = std::sync::Barrier::new(3);
    std::thread::scope(|scope| {
        let handles = (0..3)
            .map(|action| {
                scope.spawn({
                    let path = &path;
                    let barrier = &barrier;
                    move || {
                        let db = Db::open(path).unwrap();
                        barrier.wait();
                        match action {
                            0 => {
                                reserve(&mut db.lock(), "alice", &input()).unwrap();
                            }
                            1 => {
                                cancel(&db.lock(), "alice", "draft-1").unwrap();
                            }
                            _ => {
                                db.lock()
                                    .begin_workspace_deletion("node:repo", "alice")
                                    .unwrap();
                            }
                        }
                    }
                })
            })
            .collect::<Vec<_>>();
        for handle in handles {
            handle.join().unwrap();
        }
    });
    let db = Db::open(&path).unwrap();
    let row = reserve(&mut db.lock(), "alice", &input()).unwrap();
    assert_eq!(row.state, Phase::Cancelled);
    assert!(row.submission.is_none());
    assert_eq!(count(&db.lock(), "conversation_submissions"), 1);
    assert_eq!(count(&db.lock(), "sessions"), 0);
    assert_eq!(count(&db.lock(), "commands"), 0);
}

#[tokio::test]
async fn account_fence_rejects_a_changed_cookie_before_preparing_any_content() {
    use tower::ServiceExt;
    let (app, _dir) = app();
    let request=axum::http::Request::builder().method("POST").uri("/api/conversation-submissions/prepare")
        .header("host","a.example").header("origin","https://a.example").header("x-pirc-user","bob").header("x-pirc-account","alice").header("content-type","application/json")
        .extension(axum::extract::ConnectInfo("127.0.0.1:40000".parse::<std::net::SocketAddr>().unwrap()))
        .body(axum::body::Body::from(json!({"operationId":"old-account","submission":{"workspaceId":"node:repo","message":"private Alice text","attachments":[]}}).to_string())).unwrap();
    let response = crate::app::router(app.clone())
        .oneshot(request)
        .await
        .unwrap();
    assert_eq!(response.status().as_u16(), 409);
    assert_eq!(count(&app.db.lock(), "conversation_submissions"), 0);
    let(code,_)=call(&app,"POST","/api/conversation-submissions/prepare",Some("bob"),None,Some(json!({"expectedOwner":"alice","operationId":"old-account","submission":{"workspaceId":"node:repo","message":"Alice text","attachments":[]}}))).await;
    assert_eq!(code, 409);
    assert_eq!(count(&app.db.lock(), "conversation_submissions"), 0);
    let app = close_rollout(app);
    let (code, body) = call(
        &app,
        "GET",
        "/api/conversation-submissions/capabilities",
        Some("alice"),
        None,
        None,
    )
    .await;
    assert_eq!(code, 200);
    assert_eq!(body["ownerUser"], "alice");
    assert_eq!(body["canFenceAccount"], true);
    assert_eq!(body["canSubmit"], false);
}
#[tokio::test]
async fn pending_session_lookup_is_owner_scoped_and_neither_materializes_nor_takes_control() {
    use super::acceptance::tests::{identity, model, prepared, register};
    let (app, _dir) = app();
    model(&app);
    let requests = register(&app);
    prepared(&app, false);
    let accepted = super::acceptance::accept_intent(&app, &identity(), "draft-1")
        .await
        .unwrap();
    requests.lock().unwrap().clear();
    let path = format!(
        "/api/conversation-submissions/session/{}",
        accepted.session_id
    );
    let (code, body) = call(&app, "GET", &path, Some("alice"), None, None).await;
    assert_eq!(code, 200);
    assert_eq!(body["preparation"]["operationId"], "draft-1");
    assert_eq!(body["preparation"]["accepted"], true);
    assert_eq!(
        call(&app, "GET", &path, Some("bob"), None, None).await.0,
        404
    );
    assert!(requests.lock().unwrap().is_empty());
    assert_eq!(count(&app.db.lock(), "commands"), 0);
    assert!(
        app.db
            .lock()
            .get_lease(&accepted.session_id)
            .unwrap()
            .is_null()
    );
    app.db
        .lock()
        .begin_session_deletion(&accepted.session_id, "alice")
        .unwrap();
    assert_eq!(
        call(&app, "GET", &path, Some("alice"), None, None).await.0,
        404
    );
}

// Server-enforced rollout gate (`PIRC_FIRST_SEND`).
mod rollout_gate {
    use super::super::acceptance::tests::{model, prepared, register};
    use super::*;

    const PREPARE: &str = "/api/conversation-submissions/prepare";
    const CAPABILITIES: &str = "/api/conversation-submissions/capabilities";

    fn no_files() -> Value {
        json!({"operationId":"draft-1","submission":{"workspaceId":"node:repo","message":"hello","attachments":[]}})
    }
    fn code(body: &Value) -> &str {
        body["error"]["code"].as_str().unwrap_or_default()
    }
    async fn can_submit(app: &AppState) -> Value {
        call(app, "GET", CAPABILITIES, Some("alice"), None, None)
            .await
            .1["canSubmit"]
            .clone()
    }

    #[tokio::test]
    async fn default_configuration_refuses_prepare_staging_and_accept_with_a_current_client() {
        let (app, _dir) = closed_app();
        model(&app);
        let calls = register(&app);
        assert!(!app.config.first_send);
        assert_eq!(can_submit(&app).await, false);

        let (status, body) = call(&app, "POST", PREPARE, Some("alice"), None, Some(body())).await;
        assert_eq!((status, code(&body)), (409, "first_send_disabled"));
        assert_eq!(count(&app.db.lock(), "conversation_submissions"), 0);

        // A row that exists (for instance from before the gate was closed) is not
        // enough: staging and acceptance are admission, so they stay refused.
        prepared(&app, true);
        let staged = super::super::attachments::stage(&app, "alice", "draft-1", "file-1", b"test")
            .unwrap_err();
        assert_eq!((staged.status, staged.code), (409, "first_send_disabled"));
        let (status, body) = call(
            &app,
            "POST",
            "/api/conversation-submissions/draft-1/accept",
            Some("alice"),
            None,
            None,
        )
        .await;
        assert_eq!((status, code(&body)), (409, "first_send_disabled"));
        let db = app.db.lock();
        assert_eq!(count(&db, "conversation_submission_acceptances"), 0);
        assert_eq!(count(&db, "conversation_submission_attachments"), 0);
        assert_eq!(count(&db, "sessions"), 0);
        assert!(calls.lock().unwrap().is_empty(), "no Node request was made");
    }

    #[tokio::test]
    async fn enabled_configuration_with_a_current_client_prepares_then_accepts() {
        let (app, _dir) = app();
        model(&app);
        register(&app);
        assert_eq!(can_submit(&app).await, true);
        let (status, body) =
            call(&app, "POST", PREPARE, Some("alice"), None, Some(no_files())).await;
        assert_eq!(status, 200, "{body}");
        assert_eq!(body["preparation"]["accepted"], false);
        let (status, body) = call(
            &app,
            "POST",
            "/api/conversation-submissions/draft-1/accept",
            Some("alice"),
            None,
            None,
        )
        .await;
        assert_eq!(status, 202, "{body}");
        assert_eq!(body["preparation"]["accepted"], true);
        assert_eq!(
            count(&app.db.lock(), "conversation_submission_acceptances"),
            1
        );
    }

    #[tokio::test]
    async fn closing_the_rollout_after_prepare_blocks_accept_but_allows_inspect_and_discard() {
        let (app, _dir) = app();
        model(&app);
        register(&app);
        let (status, _) = call(&app, "POST", PREPARE, Some("alice"), None, Some(no_files())).await;
        assert_eq!(status, 200);
        let app = close_rollout(app);

        let (status, refused) = call(
            &app,
            "POST",
            "/api/conversation-submissions/draft-1/accept",
            Some("alice"),
            None,
            None,
        )
        .await;
        assert_eq!((status, code(&refused)), (409, "first_send_disabled"));
        assert_eq!(
            count(&app.db.lock(), "conversation_submission_acceptances"),
            0
        );
        // Repeating the prepare of a never-accepted operation is not a way in.
        let (status, again) =
            call(&app, "POST", PREPARE, Some("alice"), None, Some(no_files())).await;
        assert_eq!((status, code(&again)), (409, "first_send_disabled"));

        let (status, body) = call(
            &app,
            "GET",
            "/api/conversation-submissions/draft-1",
            Some("alice"),
            None,
            None,
        )
        .await;
        assert_eq!(status, 200);
        assert_eq!(body["preparation"]["state"], "preparing");
        let (status, body) = call(
            &app,
            "DELETE",
            "/api/conversation-submissions/draft-1",
            Some("alice"),
            None,
            None,
        )
        .await;
        assert_eq!(status, 200, "{body}");
        assert_eq!(body["preparation"]["state"], "cancelled");
        assert_eq!(count(&app.db.lock(), "sessions"), 0);
    }

    #[tokio::test]
    async fn a_correct_contract_header_never_overrides_a_closed_rollout() {
        let (app, _dir) = closed_app();
        prepared(&app, false);
        // `call` always sends the current contract header: the client is accepted
        // as compatible and still cannot submit.
        let (_, caps) = call(&app, "GET", CAPABILITIES, Some("alice"), None, None).await;
        assert_eq!(caps["clientContract"], 2);
        assert_eq!(caps["canSubmit"], false);
        for (method, path, payload) in [
            ("POST", PREPARE, Some(body())),
            ("POST", "/api/conversation-submissions/draft-1/accept", None),
        ] {
            let (status, answer) = call(&app, method, path, Some("alice"), None, payload).await;
            assert_eq!(
                (status, code(&answer)),
                (409, "first_send_disabled"),
                "{path}"
            );
        }
        assert_eq!(
            count(&app.db.lock(), "conversation_submission_acceptances"),
            0
        );
    }
}
