use super::super::tests::{app, http, identity, input, node, seed};
use super::*;
use crate::db::Db;
use pirc_protocol::NodeHttpResponse;

fn preview(db: &Db, id: &str) -> Preview {
    let conn = db.lock();
    reserve(&conn, "alice", id, &input(&conn, id)).unwrap()
}
fn reply(row: &Preview) -> Value {
    json!({"transition":{"intent":{"operationId":row.operation_id,"planHash":row.plan_hash,
        "expectedWorkspaceId":"repo","expectedRunnerEpoch":777,
        "preflight":{"targetWorkspaceId":"target","evidenceHash":"a".repeat(64)}},
        "state":"supervisor_drained","revocationConfirmed":false,"targetInstalled":false,
        "privateUnexpectedField":"never-expose"}})
}
fn count(db: &Connection) -> i64 {
    db.query_row("SELECT count(*) FROM conversation_node_fences", [], |r| {
        r.get(0)
    })
    .unwrap()
}
#[tokio::test]
async fn reconciliation_is_durable_blocks_new_commands_and_keeps_stop_peers_and_receipts() {
    let (app, _dir, id) = app();
    let row = preview(&app.db, &id);
    let before = app.db.lock().get_session(&id).unwrap();
    let payload = json!({"type":"prompt","message":"original"});
    crate::conversation_bindings::commands::receive(
        &app.db.lock(),
        &before,
        "alice",
        "old",
        &payload,
        Some(&before.binding),
    )
    .unwrap();
    // Gateway event epochs can advance independently after a reconnect.
    app.db.lock().increment_epoch(&id).unwrap();
    let response = reply(&row);
    app.nodes.set_test_node(node(), move |r| {
        assert_eq!(r.method, HttpMethod::Get);
        assert_eq!(r.url, "/api/sessions/Private/execution-fences/move-1");
        Ok(NodeHttpResponse {
            status: 200,
            body: Some(response.clone()),
        })
    });
    let result = reconcile(&app, &identity(), row).await.unwrap();
    assert_eq!(result["state"], "fenced");
    assert_eq!(result["duplicate"], false);
    assert!(!result.to_string().contains("never-expose"));
    assert!(!result.to_string().contains("Private"));
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("persisted.sqlite");
    {
        let db = app.db.lock();
        assert_eq!(count(&db), 1);
        assert!(
            db.execute(
                "UPDATE conversation_node_fences SET state='deleted' WHERE session_id=?",
                [&id]
            )
            .is_err()
        );
        assert_eq!(
            crate::conversation_bindings::commands::receive(
                &db,
                &before,
                "alice",
                "new",
                &payload,
                Some(&before.binding)
            )
            .unwrap_err()
            .code,
            "environment_transition_pending"
        );
        assert!(db.get_command("new").is_err());
        assert!(
            crate::conversation_bindings::commands::receive(
                &db,
                &before,
                "alice",
                "old",
                &payload,
                Some(&before.binding)
            )
            .unwrap()
            .1
        );
        crate::conversation_bindings::commands::receive(
            &db,
            &before,
            "alice",
            "stop",
            &json!({"type":"stop"}),
            None,
        )
        .unwrap();
        let peer = db
            .create_session("node:repo", "node://node/peer", "node", "Peer", "alice")
            .unwrap();
        crate::conversation_bindings::commands::receive(
            &db,
            &peer,
            "alice",
            "peer",
            &payload,
            Some(&peer.binding),
        )
        .unwrap();
        db.execute("VACUUM INTO ?", [path.to_str().unwrap()])
            .unwrap();
    }
    let reopened = Db::open(&path).unwrap();
    require_open(&reopened.lock(), &id).unwrap_err();
    assert_eq!(
        read_saved(&reopened.lock(), "alice", &id, "move-1")
            .unwrap()
            .unwrap()
            .state,
        "fenced"
    );
    let original = read(&app.db.lock(), "alice", &id, "move-1").unwrap();
    let replay = reconcile(&app, &identity(), original).await.unwrap();
    assert_eq!(replay["duplicate"], true);
    let (_, token) = app.devices.create("alice", "Android").unwrap();
    let status = format!("/api/sessions/{id}/environment-transitions/receipts/move-1");
    assert_eq!(http(&app, &status, None, Some(&token)).await.0, 200);
    let mirrored = http(
        &app,
        &format!("/api/sessions/{id}/environment-transitions/previews/move-1/reconcile"),
        Some(json!({})),
        Some(&token),
    )
    .await;
    assert_eq!(mirrored.0, 200, "{mirrored:?}");
    assert_eq!(mirrored.1["duplicate"], true);
    assert_eq!(http(&app, &status, None, None).await.0, 200);
    app.nodes.set_test_node(node(), |_| {
        Err(ApiError::new(503, "node_offline", "Node unavailable"))
    });
    let original = read(&app.db.lock(), "alice", &id, "move-1").unwrap();
    let offline = reconcile(&app, &identity(), original).await.unwrap();
    assert_eq!(offline["state"], "node_unavailable");
    assert_eq!(offline["transition"]["state"], "fenced");
    assert_eq!(
        app.db.lock().get_session(&id).unwrap().binding,
        before.binding
    );
    {
        let db = app.db.lock();
        db.execute("DELETE FROM workspaces WHERE id='node:target'", [])
            .unwrap();
        assert_eq!(
            require_open(&db, &id).unwrap_err().code,
            "environment_transition_pending"
        );
        let mut retry = input(&db, &id);
        retry.target_workspace_id = "node:third".into();
        assert_eq!(
            reserve(&db, "alice", &id, &retry).unwrap_err().code,
            "conflict"
        );
    }
    {
        let db = app.db.lock();
        db.begin_session_deletion(&id, "alice").unwrap();
        db.finish_session_deletion(&id).unwrap();
    }
    assert_eq!(
        read_saved(&app.db.lock(), "alice", &id, "move-1")
            .unwrap()
            .unwrap()
            .state,
        "deleted"
    );
    assert!(
        app.db
            .lock()
            .execute("DELETE FROM conversation_node_fences", [])
            .is_err()
    );
}
#[test]
fn parallel_receipts_share_one_identity_and_conflicts_do_not_replace_it() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("db");
    let db = Db::open(&path).unwrap();
    let id = seed(&db.lock());
    let row = preview(&db, &id);
    let body = reply(&row);
    let barrier = std::sync::Barrier::new(4);
    let duplicates = std::thread::scope(|scope| {
        (0..4)
            .map(|_| {
                scope.spawn(|| {
                    let db = Db::open(&path).unwrap();
                    barrier.wait();
                    record(
                        &db.lock(),
                        "alice",
                        &row,
                        "Private",
                        "repo",
                        "target",
                        &body,
                    )
                    .unwrap()
                    .1
                })
            })
            .collect::<Vec<_>>()
            .into_iter()
            .map(|t| t.join().unwrap())
            .collect::<Vec<_>>()
    });
    assert_eq!(duplicates.iter().filter(|d| !**d).count(), 1);
    assert_eq!(count(&db.lock()), 1);
    let mut changed = body;
    changed["transition"]["intent"]["preflight"]["evidenceHash"] = json!("b".repeat(64));
    assert_eq!(
        record(
            &db.lock(),
            "alice",
            &row,
            "Private",
            "repo",
            "target",
            &changed
        )
        .unwrap_err()
        .code,
        "conflict"
    );
    assert!(
        db.lock()
            .execute(
                "UPDATE conversation_node_fences SET intent_digest='other'",
                []
            )
            .is_err()
    );
}
#[test]
fn invalid_receipts_and_failed_commits_never_fence_gateway_commands() {
    let db = Db::memory();
    let db = db.lock();
    let id = seed(&db);
    let row = reserve(&db, "alice", &id, &input(&db, &id)).unwrap();
    for field in ["operationId", "planHash", "expectedWorkspaceId"] {
        let mut body = reply(&row);
        body["transition"]["intent"][field] = json!("wrong");
        assert!(record(&db, "alice", &row, "Private", "repo", "target", &body).is_err());
        assert_eq!(count(&db), 0);
    }
    let mut body = reply(&row);
    body["transition"]["intent"]["preflight"] = Value::Null;
    assert!(record(&db, "alice", &row, "Private", "repo", "target", &body).is_err());
    db.execute_batch("CREATE TRIGGER fail_receipt BEFORE INSERT ON conversation_node_fences BEGIN SELECT RAISE(ABORT,'disk full'); END;").unwrap();
    assert!(
        record(
            &db,
            "alice",
            &row,
            "Private",
            "repo",
            "target",
            &reply(&row)
        )
        .is_err()
    );
    assert_eq!(count(&db), 0);
    require_open(&db, &id).unwrap();
}
#[tokio::test]
async fn connection_and_device_changes_after_query_never_persist_a_receipt() {
    for revoke in [false, true] {
        let (app, _dir, id) = app();
        let row = preview(&app.db, &id);
        let response = reply(&row);
        let (device, _) = app.devices.create("alice", "Android").unwrap();
        let device_id = device.id.clone();
        let nodes = app.nodes.clone();
        let devices = app.devices.clone();
        app.nodes.set_test_node(node(), move |_| {
            if revoke {
                devices.revoke("alice", &device_id).unwrap();
            } else {
                nodes.set_test_node(node(), |_| unreachable!("no second request"));
            }
            Ok(NodeHttpResponse {
                status: 200,
                body: Some(response.clone()),
            })
        });
        let mut caller = identity();
        caller.device_id = Some(device.id);
        let result = reconcile(&app, &caller, row).await;
        if revoke {
            assert_eq!(result.unwrap_err().status, 401);
        } else {
            assert_eq!(result.unwrap()["state"], "connection_changed");
        }
        assert_eq!(count(&app.db.lock()), 0);
    }
}
#[test]
fn migration_preserves_previews_without_inventing_node_acceptance() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("db");
    let (id, hash) = {
        let db = Db::open(&path).unwrap();
        let db = db.lock();
        let id = seed(&db);
        let row = reserve(&db, "alice", &id, &input(&db, &id)).unwrap();
        db.execute_batch("DROP TRIGGER conversation_transition_void_blocks_fence_receipt; DROP TRIGGER conversation_transition_void_blocks_fenced; DROP TRIGGER conversation_transition_void_retained; DROP TRIGGER conversation_transition_void_answered_once; DROP TRIGGER conversation_transition_void_needs_unknown_outcome; DROP TABLE conversation_transition_voids; DROP TRIGGER conversation_transition_cancellation_session_deleted; DROP TABLE conversation_transition_cancellations; DROP TRIGGER conversation_operation_authority_session_deleted; DROP TABLE conversation_operation_authorities; DROP TABLE conversation_authority_clock; DROP TRIGGER conversation_transition_progress_session_deleted; DROP TABLE conversation_transition_progress; DROP TRIGGER conversation_transition_acceptance_session_deleted; DROP TABLE conversation_transition_acceptances; DROP TRIGGER conversation_node_fence_session_deleted; DROP TABLE conversation_node_fences; PRAGMA user_version=1026;")
            .unwrap();
        (id, row.plan_hash)
    };
    let db = Db::open(&path).unwrap();
    let db = db.lock();
    assert_eq!(count(&db), 0);
    assert_eq!(read(&db, "alice", &id, "move-1").unwrap().plan_hash, hash);
    require_open(&db, &id).unwrap();
    assert_eq!(
        db.pragma_query_value(None, "user_version", |r| r.get::<_, i64>(0))
            .unwrap(),
        crate::db::SCHEMA_VERSION
    );
}

#[tokio::test]
async fn fence_received_during_capability_wait_prevents_dispatch_and_node_reauthorization() {
    let (app, _dir, id) = app();
    let row = preview(&app.db, &id);
    let body = reply(&row);
    let source = app.db.lock().get_session(&id).unwrap();
    {
        let db = app.db.lock();
        db.mirror_lease(
            &id,
            &crate::db::Lease {
                client_id: "phone".into(),
                generation: 1,
                expires_at: now_ms() + 60000,
            },
            "alice",
            false,
        )
        .unwrap();
        crate::conversation_bindings::commands::receive(
            &db,
            &source,
            "alice",
            "already-dispatched",
            &json!({"type":"prompt","message":"old"}),
            Some(&source.binding),
        )
        .unwrap();
        db.update_command("already-dispatched", "dispatched", None, None)
            .unwrap();
    }
    let db = app.db.clone();
    app.nodes.set_test_node(node(), move |r| {
        assert_eq!(
            r.method,
            HttpMethod::Get,
            "No command may be sent after the fence arrives"
        );
        assert_eq!(r.url, "/api/command-environments/capabilities");
        record(
            &db.lock(),
            "alice",
            &row,
            "Private",
            "repo",
            "target",
            &body,
        )
        .unwrap();
        Ok(NodeHttpResponse {
            status: 200,
            body: Some(json!({"version":1,"rechecksCommandEnvironment":true})),
        })
    });
    let result=http(&app,&format!("/api/sessions/{id}/commands"),Some(json!({"commandId":"waiting","clientId":"phone","generation":1,"expectedBinding":source.binding,"payload":{"type":"prompt","message":"new"}})),None).await;
    assert_eq!(result.0, 409, "{result:?}");
    assert_eq!(result.1["error"]["code"], "environment_transition_pending");
    assert_eq!(
        app.db.lock().get_command("waiting").unwrap().status,
        "rejected"
    );
    assert_eq!(
        crate::conversation_bindings::commands::authorize(
            &app.db.lock(),
            &source,
            "alice",
            "already-dispatched",
            &source.binding,
            "phone",
            1
        )
        .unwrap_err()
        .code,
        "environment_transition_pending"
    );
}

fn stop_setup(app: &AppState, id: &str) -> (Value, String) {
    let row = preview(&app.db, id);
    record(
        &app.db.lock(),
        "alice",
        &row,
        "Private",
        "repo",
        "target",
        &reply(&row),
    )
    .unwrap();
    app.db
        .lock()
        .mirror_lease(
            id,
            &crate::db::Lease {
                client_id: "phone".into(),
                generation: 1,
                expires_at: now_ms() + 60000,
            },
            "alice",
            false,
        )
        .unwrap();
    (
        json!({"commandId":"transition-stop","clientId":"phone","generation":1,"payload":{"type":"stop_transition","operationId":"move-1","planHash":row.plan_hash}}),
        row.operation_id,
    )
}
#[tokio::test]
async fn web_native_transition_stop_reuses_command_identity_and_keeps_source_fenced() {
    let (app, _dir, id) = app();
    let (mut body, _op) = stop_setup(&app, &id);
    body["payload"]["message"] = json!("must be dropped from Stop intent");
    let posts = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let seen = posts.clone();
    let captured = app.db.clone();
    let source = id.clone();
    app.nodes.set_test_node(node(),move |r| {
        if r.method==HttpMethod::Get {assert_eq!(r.url,"/api/execution-fences/capabilities");return Ok(NodeHttpResponse{status:200,body:Some(json!({"stopCommandVersion":1}))});}
        seen.fetch_add(1,std::sync::atomic::Ordering::SeqCst);
        assert_eq!(captured.lock().get_command("transition-stop").unwrap().status,"dispatched");
        assert!(require_open(&captured.lock(),&source).is_err());
        let payload=r.payload.unwrap();assert_eq!(payload["payload"]["operationId"],"move-1");
        assert!(payload.get("commandEnvironment").is_none());
        Ok(NodeHttpResponse{status:202,body:Some(json!({"command":{"id":"transition-stop","status":"accepted","result":{"success":true,"data":{"transition":{"operationId":"move-1","state":"supervisor_drained","revocationConfirmed":false,"targetInstalled":false}}}}}))})
    });
    let path = format!("/api/sessions/{id}/commands");
    let result = http(&app, &path, Some(body.clone()), None).await;
    assert_eq!(result.0, 202, "{result:?}");
    assert_eq!(
        result.1["command"]["result"]["data"]["transition"]["state"],
        "supervisor_drained"
    );
    let (_device, token) = app.devices.create("alice", "Android").unwrap();
    let duplicate = http(&app, &path, Some(body.clone()), Some(&token)).await;
    assert_eq!(duplicate.0, 200, "{duplicate:?}");
    assert_eq!(duplicate.1["duplicate"], true);
    assert_eq!(posts.load(std::sync::atomic::Ordering::SeqCst), 1);
    let read = http(&app, &format!("{path}/transition-stop"), None, Some(&token)).await;
    assert_eq!(read.0, 200);
    assert_eq!(read.1["command"]["status"], "accepted");
    assert!(require_open(&app.db.lock(), &id).is_err());
    assert_eq!(
        app.db.lock().get_session(&id).unwrap().workspace_id,
        "node:repo"
    );
}
#[tokio::test]
async fn lost_stop_reply_reconciles_with_get_and_never_resends_to_node() {
    let (app, _dir, id) = app();
    let (body, _op) = stop_setup(&app, &id);
    let hash = payload_hash(&body["payload"]);
    let posts = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let seen = posts.clone();
    app.nodes.set_test_node(node(),move |r| {
        if r.url=="/api/execution-fences/capabilities" {return Ok(NodeHttpResponse{status:200,body:Some(json!({"stopCommandVersion":1}))});}
        if r.method==HttpMethod::Post {seen.fetch_add(1,std::sync::atomic::Ordering::SeqCst);return Err(ApiError::new(503,"lost_reply","Unknown Stop outcome"));}
        assert_eq!(r.method,HttpMethod::Get);assert_eq!(r.url,"/api/sessions/Private/commands/transition-stop");
        Ok(NodeHttpResponse{status:200,body:Some(json!({"command":{"id":"transition-stop","sessionId":"Private","payloadHash":hash,"status":"accepted","result":{"success":true,"data":{"transition":{"operationId":"move-1","state":"supervisor_drained","revocationConfirmed":false,"targetInstalled":false}}}}}))})
    });
    let path = format!("/api/sessions/{id}/commands");
    let lost = http(&app, &path, Some(body.clone()), None).await;
    assert_eq!(lost.0, 503);
    assert_eq!(lost.1["command"]["status"], "outcome_unknown");
    let duplicate = http(&app, &path, Some(body), None).await;
    assert_eq!(duplicate.1["duplicate"], true);
    let read = http(&app, &format!("{path}/transition-stop"), None, None).await;
    assert_eq!(read.0, 200, "{read:?}");
    assert_eq!(read.1["command"]["status"], "accepted");
    assert_eq!(posts.load(std::sync::atomic::Ordering::SeqCst), 1);
    assert!(require_open(&app.db.lock(), &id).is_err());
}
#[tokio::test]
async fn unknown_transition_and_takeover_during_capability_wait_cannot_stop() {
    let (app, _dir, id) = app();
    let (mut body, _op) = stop_setup(&app, &id);
    body["payload"]["operationId"] = json!("unaccepted");
    let path = format!("/api/sessions/{id}/commands");
    let rejected = http(&app, &path, Some(body.clone()), None).await;
    assert_eq!(rejected.0, 409);
    assert!(app.db.lock().get_command("transition-stop").is_err());
    body["payload"]["operationId"] = json!("move-1");
    let db = app.db.clone();
    let source = id.clone();
    app.nodes.set_test_node(node(), move |r| {
        assert_eq!(r.method, HttpMethod::Get);
        db.lock()
            .mirror_lease(
                &source,
                &crate::db::Lease {
                    client_id: "web".into(),
                    generation: 2,
                    expires_at: now_ms() + 60000,
                },
                "alice",
                false,
            )
            .unwrap();
        Ok(NodeHttpResponse {
            status: 200,
            body: Some(json!({"stopCommandVersion":1})),
        })
    });
    let rejected = http(&app, &path, Some(body), None).await;
    assert_eq!(rejected.0, 409, "{rejected:?}");
    assert_eq!(
        app.db.lock().get_command("transition-stop").unwrap().status,
        "rejected"
    );
    assert!(require_open(&app.db.lock(), &id).is_err());
}

#[tokio::test]
async fn an_older_node_cannot_silently_ignore_transition_stop() {
    let (app, _dir, id) = app();
    let (body, _op) = stop_setup(&app, &id);
    app.nodes.set_test_node(node(), |r| {
        assert_eq!(r.method, HttpMethod::Get);
        Ok(NodeHttpResponse {
            status: 200,
            body: Some(json!({"version":1,"trackedSupervisorDrain":true})),
        })
    });
    let result = http(
        &app,
        &format!("/api/sessions/{id}/commands"),
        Some(body),
        None,
    )
    .await;
    assert_eq!(result.0, 409);
    assert_eq!(result.1["error"]["code"], "transition_stop_unsupported");
    assert_eq!(
        app.db.lock().get_command("transition-stop").unwrap().status,
        "rejected"
    );
    assert!(require_open(&app.db.lock(), &id).is_err());
}
#[tokio::test]
async fn command_receipt_wait_cannot_extend_device_connection_or_source_authority() {
    for change in ["device", "connection", "policy"] {
        let (app, _dir, id) = app();
        let (body, _op) = stop_setup(&app, &id);
        {
            let db = app.db.lock();
            let source = db.get_session(&id).unwrap();
            crate::conversation_bindings::commands::receive(
                &db,
                &source,
                "alice",
                "transition-stop",
                &body["payload"],
                None,
            )
            .unwrap();
            db.update_command("transition-stop", "outcome_unknown", None, None)
                .unwrap();
        }
        let hash = payload_hash(&body["payload"]);
        let (device, token) = app.devices.create("alice", "Android").unwrap();
        let devices = app.devices.clone();
        let nodes = app.nodes.clone();
        let db = app.db.clone();
        app.nodes.set_test_node(node(),move |r| {
            assert_eq!(r.method,HttpMethod::Get);
            match change {
                "device"=>devices.revoke("alice",&device.id).unwrap(),
                "connection"=>nodes.set_test_node(node(),|_|Ok(NodeHttpResponse{status:404,body:None})),
                _=>{db.lock().patch_workspace_capabilities("node:repo",&serde_json::from_value::<crate::db::CapabilitiesPatch>(json!({"web_search":false})).unwrap()).unwrap();}
            }
            Ok(NodeHttpResponse{status:200,body:Some(json!({"command":{"id":"transition-stop","sessionId":"Private","payloadHash":hash,"status":"accepted","result":{"private":"must not escape stale authority"}}}))})
        });
        let response = http(
            &app,
            &format!("/api/sessions/{id}/commands/transition-stop"),
            None,
            Some(&token),
        )
        .await;
        assert_eq!(
            response.0,
            if change == "device" { 401 } else { 409 },
            "{change}: {response:?}"
        );
        assert!(!response.1.to_string().contains("must not escape"));
        assert_eq!(
            app.db.lock().get_command("transition-stop").unwrap().status,
            "outcome_unknown"
        );
    }
}
