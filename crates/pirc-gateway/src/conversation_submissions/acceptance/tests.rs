use super::super::tests::{app, call, count, disk_app, input};
use super::*;
use crate::{app::App, db::Db, nodes::ConnectedNode};
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicBool, Ordering},
};

pub(crate) fn identity() -> Identity {
    Identity {
        user: "alice".into(),
        device_id: None,
        management_authorized: false,
    }
}
pub(crate) fn model(app: &AppState) {
    app.backends.set_baseline(serde_json::from_value(json!({"providers":{"fake":{"api":"openai-completions","baseUrl":"https://model.invalid","models":[{"id":"m","contextWindow":10000,"maxTokens":1000,"reasoning":true,"input":["text"]}]}},"defaultModel":{"provider":"fake","id":"m","thinking":"high"}})).unwrap());
}
pub(crate) fn connected() -> ConnectedNode {
    ConnectedNode {
        id: "node".into(),
        role: pirc_protocol::NodeRole::Node,
        modes: vec![pirc_protocol::ModeId::new("directory").unwrap()],
        workspaces: vec![pirc_protocol::RegisteredWorkspace {
            checkpoint_private: false,
            id: "repo".into(),
            display_name: "Repo".into(),
            mode: pirc_protocol::ModeId::new("directory").unwrap(),
            roles: None,
            repo: None,
        }],
        connected_at: now_ms(),
        last_seen_at: now_ms(),
        added: Default::default(),
    }
}
pub(crate) fn caps() -> Value {
    json!({"version":1,"canAllocate":true,"canTransferAttachments":true,"attachmentMimeInQuery":true,"canAdmitFirstMessage":true,"canReadFirstMessageReceipt":true,"canCancelCreation":true,"canStopBeforeAllocation":true,"maxUploadBytes":1024,"maxAttachments":16})
}
pub(crate) fn fake(request: &NodeHttpRequest) -> NodeHttpResponse {
    let value = if request.url.ends_with("/capabilities") {
        caps()
    } else if request.url == "/api/session-creations" {
        let input = request.payload.as_ref().unwrap();
        json!({"creation":{"operationId":input["operationId"],"workspaceId":input["workspaceId"],"sessionId":"session-stable","state":"ready"}})
    } else if request.url.contains("/attachments/") {
        assert_eq!(request.method, HttpMethod::Put);
        let url = url::Url::parse(&format!("https://node.invalid{}", request.url)).unwrap();
        let fields = url
            .query_pairs()
            .collect::<std::collections::HashMap<_, _>>();
        assert_eq!(fields["filename"], "測試 #?%.json");
        assert_eq!(fields["mimeType"], "application/json");
        assert_eq!(
            STANDARD
                .decode(request.body_base64.as_ref().unwrap())
                .unwrap(),
            b"test"
        );
        assert_eq!(
            request.content_type.as_deref(),
            Some("application/octet-stream")
        );
        let parts = url.path().split('/').collect::<Vec<_>>();
        json!({"creationAttachment":{"operationId":parts[3],"attachmentId":parts[5],"sessionId":"session-stable","state":"ready","upload":{"id":"upload-stable","byteSize":4,"sha256":crate::util::sha256_hex(b"test")}}})
    } else {
        panic!("unexpected Node mutation: {}", request.url)
    };
    NodeHttpResponse {
        status: 200,
        body: Some(value),
    }
}
pub(crate) fn register(app: &AppState) -> Arc<Mutex<Vec<NodeHttpRequest>>> {
    let requests = Arc::new(Mutex::new(Vec::new()));
    let recorded = requests.clone();
    app.nodes.set_test_node(connected(), move |r| {
        recorded.lock().unwrap().push(r.clone());
        Ok(fake(&r))
    });
    requests
}
pub(crate) fn prepared(app: &AppState, attachment: bool) -> Input {
    let mut input = input();
    if attachment {
        input.submission.attachments[0].name = "測試 #?%.json".into();
        input.submission.attachments[0].mime_type = "application/json".into();
        input.submission.attachments[0].sha256 = crate::util::sha256_hex(b"test");
    } else {
        input.submission.attachments.clear();
    }
    reserve(&mut app.db.lock(), "alice", &input).unwrap();
    input
}
#[tokio::test]
async fn accepts_one_durable_public_pending_session_without_commands_or_leases() {
    let (app, _dir) = disk_app();
    model(&app);
    let requests = register(&app);
    prepared(&app, false);
    let first = accept_intent(&app, &identity(), "draft-1").await.unwrap();
    assert!(first.accepted);
    assert_eq!(first.state, Phase::Accepted);
    assert!(first.accepted_at.is_some());
    let session = app.db.lock().get_session(&first.session_id).unwrap();
    assert_eq!(session.owner_user.as_deref(), Some("alice"));
    assert!(session.pi_session_id.is_none());
    assert_eq!(count(&app.db.lock(), "sessions"), 1);
    assert_eq!(count(&app.db.lock(), "commands"), 0);
    assert_eq!(count(&app.db.lock(), "leases"), 0);
    let duplicate = accept_intent(&app, &identity(), "draft-1").await.unwrap();
    assert_eq!(duplicate.session_id, first.session_id);
    assert_eq!(duplicate.accepted_at, first.accepted_at);
    assert_eq!(requests.lock().unwrap().len(), 1);
    let db = Db::open(&app.config.state_dir.join("gateway.sqlite")).unwrap();
    let recovered = lookup(&db.lock(), "alice", "draft-1").unwrap();
    assert!(recovered.accepted);
    assert_eq!(recovered.session_id, first.session_id);
    assert_eq!(
        cancel(&db.lock(), "alice", "draft-1").unwrap_err().code,
        "submission_accepted"
    );
    assert_eq!(
        require_initial_submission_complete(&db.lock(), &first.session_id)
            .unwrap_err()
            .code,
        "first_message_pending"
    );
    let stored: (String, String) = db
        .lock()
        .query_row(
            "SELECT model_json,thinking FROM conversation_submission_acceptances",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap();
    assert_eq!(
        serde_json::from_str::<Value>(&stored.0).unwrap(),
        json!({"provider":"fake","id":"m"})
    );
    assert_eq!(stored.1, "high");
    app.backends.set_baseline(crate::app::empty_models());
    app.db
        .lock()
        .execute("UPDATE workspaces SET kind='removed-mode'", [])
        .unwrap();
    assert!(
        accept_intent(&app, &identity(), "draft-1")
            .await
            .unwrap()
            .accepted
    );
}
#[tokio::test]
async fn missing_corrupt_expired_or_mismatched_files_do_not_cross_acceptance() {
    for case in 0..4 {
        let (app, _dir) = app();
        model(&app);
        register(&app);
        let mut input = prepared(&app, true);
        if case != 0 {
            attachments::stage(&app, "alice", "draft-1", "file-1", b"test").unwrap();
        }
        let row = lookup(&app.db.lock(), "alice", "draft-1").unwrap();
        match case {
            1 => std::fs::write(
                app.config
                    .state_dir
                    .join("submission-staging")
                    .join(&row.session_id)
                    .join("file-1.bin"),
                b"oops",
            )
            .unwrap(),
            2 => {
                app.db
                    .lock()
                    .execute(
                        "UPDATE conversation_submissions SET attachments_expires_at=1",
                        [],
                    )
                    .unwrap();
            }
            3 => {
                input.submission.attachments[0].mime_type = "image/png".into();
                input.submission.attachments[0].sha256 = crate::util::sha256_hex(b"GIF89a");
                input.submission.attachments[0].byte_size = 6;
                app.db
                    .lock()
                    .execute(
                        "UPDATE conversation_submissions SET payload_json=?1",
                        [serde_json::to_string(&input.submission).unwrap()],
                    )
                    .unwrap();
                app.db
                    .lock()
                    .execute(
                        "UPDATE conversation_submission_attachments SET byte_size=6,sha256=?1",
                        [&input.submission.attachments[0].sha256],
                    )
                    .unwrap();
                std::fs::write(
                    app.config
                        .state_dir
                        .join("submission-staging")
                        .join(&row.session_id)
                        .join("file-1.bin"),
                    b"GIF89a",
                )
                .unwrap();
            }
            _ => {}
        }
        assert!(
            accept_intent(&app, &identity(), "draft-1").await.is_err(),
            "case {case}"
        );
        assert_eq!(count(&app.db.lock(), "sessions"), 0);
        assert_eq!(
            count(&app.db.lock(), "conversation_submission_acceptances"),
            0
        );
        assert!(!lookup(&app.db.lock(), "alice", "draft-1").unwrap().accepted);
    }
}
#[tokio::test]
async fn unsupported_or_offline_node_keeps_the_unsent_draft() {
    for case in 0..4 {
        let (app, _dir) = app();
        model(&app);
        prepared(&app, true);
        if case != 0 {
            app.nodes.set_test_node(connected(), move |_| {
                Ok(match case {
                    1 => NodeHttpResponse {
                        status: 404,
                        body: None,
                    },
                    2 => {
                        let mut body = caps();
                        body["maxUploadBytes"] = json!(3);
                        NodeHttpResponse {
                            status: 200,
                            body: Some(body),
                        }
                    }
                    _ => {
                        let mut body = caps();
                        body["canTransferAttachments"] = json!(false);
                        NodeHttpResponse {
                            status: 200,
                            body: Some(body),
                        }
                    }
                })
            });
        }
        assert!(accept_intent(&app, &identity(), "draft-1").await.is_err());
        assert_eq!(count(&app.db.lock(), "sessions"), 0);
        assert!(!lookup(&app.db.lock(), "alice", "draft-1").unwrap().accepted);
    }
}
#[tokio::test]
async fn rechecks_private_ownership_after_capability_response() {
    let (app, _dir) = app();
    model(&app);
    prepared(&app, false);
    let weak = Arc::downgrade(&app);
    app.nodes.set_test_node(connected(), move |_| {
        let app = weak.upgrade().unwrap();
        let db = app.db.lock();
        db.mark_checkpoint_workspace_private("node:repo").unwrap();
        db.claim_checkpoint_workspace("node:repo", "bob").unwrap();
        Ok(NodeHttpResponse {
            status: 200,
            body: Some(caps()),
        })
    });
    assert_eq!(
        accept_intent(&app, &identity(), "draft-1")
            .await
            .unwrap_err()
            .status,
        404
    );
    assert_eq!(count(&app.db.lock(), "sessions"), 0);
}
#[tokio::test]
async fn failed_acceptance_commit_cannot_publish_an_empty_conversation() {
    let (app, _dir) = app();
    model(&app);
    register(&app);
    prepared(&app, false);
    app.db.lock().execute_batch("CREATE TRIGGER reject_receipt BEFORE INSERT ON conversation_submission_acceptances BEGIN SELECT RAISE(ABORT,'injected storage error'); END;").unwrap();
    assert!(accept_intent(&app, &identity(), "draft-1").await.is_err());
    assert_eq!(count(&app.db.lock(), "sessions"), 0);
    assert!(!lookup(&app.db.lock(), "alice", "draft-1").unwrap().accepted);
    app.db
        .lock()
        .execute_batch("DROP TRIGGER reject_receipt")
        .unwrap();
    assert!(
        accept_intent(&app, &identity(), "draft-1")
            .await
            .unwrap()
            .accepted
    );
}
#[tokio::test]
async fn transfers_the_bound_json_attachment_once_and_retains_accepted_files() {
    let (app, _dir) = app();
    model(&app);
    let requests = register(&app);
    prepared(&app, true);
    attachments::stage(&app, "alice", "draft-1", "file-1", b"test").unwrap();
    let accepted = accept_intent(&app, &identity(), "draft-1").await.unwrap();
    assert!(accepted.attachments_expires_at.is_none());
    attachments::sweep(
        &app,
        now_ms().saturating_add(10 * attachments::RETENTION_MS),
    )
    .unwrap();
    let ready = advance(&app, &identity(), "draft-1").await.unwrap();
    assert_eq!(ready.state, Phase::Ready);
    assert_eq!(ready.session_id, accepted.session_id);
    let public = app.db.lock().get_session(&ready.session_id).unwrap();
    assert_eq!(public.pi_session_id.as_deref(), Some("session-stable"));
    assert!(app.claim(&identity(), &ready.session_id).is_ok());
    let uploads: String = app
        .db
        .lock()
        .query_row(
            "SELECT upload_ids_json FROM conversation_submission_acceptances",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(
        serde_json::from_str::<Value>(&uploads).unwrap(),
        json!(["upload-stable"])
    );
    let before = requests.lock().unwrap().len();
    advance(&app, &identity(), "draft-1").await.unwrap();
    assert_eq!(requests.lock().unwrap().len(), before);
    assert_eq!(count(&app.db.lock(), "commands"), 0);
    assert_eq!(count(&app.db.lock(), "leases"), 0);
    assert_eq!(count(&app.db.lock(), "conversation_submission_cleanup"), 0);
    assert!(
        app.config
            .state_dir
            .join("submission-staging")
            .join(&ready.session_id)
            .join("file-1.bin")
            .is_file()
    );
}
#[tokio::test]
async fn lost_transfer_response_reconciles_the_same_node_and_upload_id() {
    let (app, _dir) = app();
    model(&app);
    prepared(&app, true);
    attachments::stage(&app, "alice", "draft-1", "file-1", b"test").unwrap();
    let lost = Arc::new(AtomicBool::new(true));
    let flag = lost.clone();
    let requests = Arc::new(Mutex::new(Vec::new()));
    let record = requests.clone();
    app.nodes.set_test_node(connected(), move |r| {
        record.lock().unwrap().push(r.clone());
        let result = fake(&r);
        if r.url.contains("/attachments/") && flag.swap(false, Ordering::SeqCst) {
            Err(ApiError::new(
                503,
                "node_timeout",
                "synthetic lost response",
            ))
        } else {
            Ok(result)
        }
    });
    let accepted = accept_intent(&app, &identity(), "draft-1").await.unwrap();
    assert!(advance(&app, &identity(), "draft-1").await.is_err());
    assert_eq!(
        lookup(&app.db.lock(), "alice", "draft-1").unwrap().state,
        Phase::Accepted
    );
    let done = advance(&app, &identity(), "draft-1").await.unwrap();
    assert_eq!(done.session_id, accepted.session_id);
    assert_eq!(done.state, Phase::Ready);
    let recorded = requests.lock().unwrap();
    let creates = recorded
        .iter()
        .filter(|r| r.url == "/api/session-creations")
        .collect::<Vec<_>>();
    assert_eq!(creates.len(), 2);
    assert_eq!(creates[0].payload, creates[1].payload);
    let transfers = recorded
        .iter()
        .filter(|r| r.url.contains("/attachments/"))
        .collect::<Vec<_>>();
    assert_eq!(transfers.len(), 2);
    assert_eq!(transfers[0], transfers[1]);
    assert_eq!(count(&app.db.lock(), "sessions"), 1);
}
#[tokio::test]
async fn deletion_during_node_allocation_fences_late_publication() {
    let (app, _dir) = app();
    model(&app);
    register(&app);
    prepared(&app, false);
    let accepted = accept_intent(&app, &identity(), "draft-1").await.unwrap();
    let weak = Arc::downgrade(&app);
    let sid = accepted.session_id.clone();
    app.nodes.set_test_node(connected(), move |r| {
        let result = fake(&r);
        if r.url == "/api/session-creations" {
            weak.upgrade()
                .unwrap()
                .db
                .lock()
                .begin_session_deletion(&sid, "alice")
                .unwrap();
        }
        Ok(result)
    });
    assert!(advance(&app, &identity(), "draft-1").await.is_err());
    let row = lookup(&app.db.lock(), "alice", "draft-1").unwrap();
    assert!(row.accepted);
    assert_eq!(row.state, Phase::Cancelled);
    assert!(row.submission.is_none());
    assert!(
        app.db
            .lock()
            .get_session(&row.session_id)
            .unwrap()
            .pi_session_id
            .is_none()
    );
    assert_eq!(
        accept_intent(&app, &identity(), "draft-1")
            .await
            .unwrap()
            .state,
        Phase::Cancelled
    );
    assert_eq!(
        advance(&app, &identity(), "draft-1").await.unwrap().state,
        Phase::Cancelled
    );
}
#[tokio::test]
async fn malformed_node_receipts_never_bind_an_unrelated_session() {
    for field in ["operationId", "workspaceId", "state", "sessionId"] {
        let (app, _dir) = app();
        model(&app);
        register(&app);
        prepared(&app, false);
        let accepted = accept_intent(&app, &identity(), "draft-1").await.unwrap();
        app.nodes.set_test_node(connected(), move |r| {
            let mut result = fake(&r);
            if r.url == "/api/session-creations" {
                result.body.as_mut().unwrap()["creation"][field] = json!(if field == "sessionId" {
                    "../unsafe"
                } else {
                    "other"
                });
            }
            Ok(result)
        });
        assert!(advance(&app, &identity(), "draft-1").await.is_err());
        assert!(
            app.db
                .lock()
                .get_session(&accepted.session_id)
                .unwrap()
                .pi_session_id
                .is_none()
        );
    }
}
#[tokio::test]
async fn paired_device_accepts_and_materializes_without_web_and_revocation_blocks_access() {
    let (app, _dir) = app();
    model(&app);
    register(&app);
    prepared(&app, false);
    let (device, token) = app.devices.create("alice", "Android").unwrap();
    assert_eq!(
        call(
            &app,
            "POST",
            "/api/conversation-submissions/draft-1/accept",
            None,
            Some(&token),
            None
        )
        .await
        .0,
        202
    );
    let (code, body) = call(
        &app,
        "POST",
        "/api/conversation-submissions/draft-1/materialize",
        None,
        Some(&token),
        None,
    )
    .await;
    assert_eq!(code, 200, "{body}");
    assert_eq!(body["preparation"]["state"], "ready");
    assert_eq!(
        call(
            &app,
            "GET",
            "/api/conversation-submissions/draft-1",
            Some("bob"),
            None,
            None
        )
        .await
        .0,
        404
    );
    app.devices.revoke("alice", &device.id).unwrap();
    assert_eq!(
        call(
            &app,
            "GET",
            "/api/conversation-submissions/draft-1",
            None,
            Some(&token),
            None
        )
        .await
        .0,
        401
    );
}
#[test]
fn concurrent_sqlite_connections_publish_one_accepted_identity() {
    let (first, _dir) = disk_app();
    model(&first);
    register(&first);
    prepared(&first, false);
    let barrier = std::sync::Barrier::new(4);
    let apps = (0..4)
        .map(|_| {
            let app = App::new(
                first.config.clone(),
                Arc::new(Db::open(&first.config.state_dir.join("gateway.sqlite")).unwrap()),
                first.backends.clone(),
                crate::app::test_modes(),
            );
            register(&app);
            app
        })
        .collect::<Vec<_>>();
    let ids = std::thread::scope(|scope| {
        apps.iter()
            .map(|app| {
                let b = &barrier;
                scope.spawn(move || {
                    b.wait();
                    let t = target(&app.db.lock(), "alice", "draft-1").unwrap();
                    commit_acceptance(app, &identity(), "draft-1", &t)
                        .unwrap()
                        .session_id
                })
            })
            .collect::<Vec<_>>()
            .into_iter()
            .map(|h| h.join().unwrap())
            .collect::<Vec<_>>()
    });
    assert!(ids.iter().all(|id| id == &ids[0]));
    assert_eq!(count(&first.db.lock(), "sessions"), 1);
    assert_eq!(
        count(&first.db.lock(), "conversation_submission_acceptances"),
        1
    );
}

#[tokio::test]
async fn revocation_while_preflight_waits_prevents_durable_acceptance() {
    let (app, _dir) = app();
    model(&app);
    prepared(&app, false);
    let (device, token) = app.devices.create("alice", "Android").unwrap();
    let weak = Arc::downgrade(&app);
    app.nodes.set_test_node(connected(), move |_| {
        weak.upgrade()
            .unwrap()
            .devices
            .revoke("alice", &device.id)
            .unwrap();
        Ok(NodeHttpResponse {
            status: 200,
            body: Some(caps()),
        })
    });
    let (code, _) = call(
        &app,
        "POST",
        "/api/conversation-submissions/draft-1/accept",
        None,
        Some(&token),
        None,
    )
    .await;
    assert_eq!(code, 401);
    assert_eq!(count(&app.db.lock(), "sessions"), 0);
    assert!(!lookup(&app.db.lock(), "alice", "draft-1").unwrap().accepted);
}
#[test]
fn cancellation_racing_acceptance_has_only_one_atomic_winner() {
    for _ in 0..8 {
        let (first, _dir) = disk_app();
        model(&first);
        register(&first);
        prepared(&first, false);
        let second = App::new(
            first.config.clone(),
            Arc::new(Db::open(&first.config.state_dir.join("gateway.sqlite")).unwrap()),
            first.backends.clone(),
            crate::app::test_modes(),
        );
        register(&second);
        let b = std::sync::Barrier::new(2);
        let (accepted, cancelled) = std::thread::scope(|s| {
            let a = s.spawn(|| {
                b.wait();
                let t = target(&first.db.lock(), "alice", "draft-1").unwrap();
                commit_acceptance(&first, &identity(), "draft-1", &t)
            });
            let c = s.spawn(|| {
                b.wait();
                cancel(&second.db.lock(), "alice", "draft-1")
            });
            (a.join().unwrap(), c.join().unwrap())
        });
        let row = lookup(&first.db.lock(), "alice", "draft-1").unwrap();
        if row.accepted {
            assert!(accepted.is_ok());
            assert_eq!(cancelled.unwrap_err().code, "submission_accepted");
            assert_eq!(count(&first.db.lock(), "sessions"), 1);
            assert_eq!(row.state, Phase::Accepted);
        } else {
            assert!(accepted.is_err());
            assert!(cancelled.is_ok());
            assert_eq!(row.state, Phase::Cancelled);
            assert_eq!(count(&first.db.lock(), "sessions"), 0);
        }
    }
}
#[tokio::test]
async fn materialization_reports_retained_pending_intent_after_transport_failure() {
    let (app, _dir) = app();
    model(&app);
    register(&app);
    prepared(&app, false);
    accept_intent(&app, &identity(), "draft-1").await.unwrap();
    app.nodes.set_test_node(connected(), |_| {
        Err(ApiError::new(
            503,
            "node_offline",
            "synthetic disconnected link",
        ))
    });
    let (code, body) = call(
        &app,
        "POST",
        "/api/conversation-submissions/draft-1/materialize",
        Some("alice"),
        None,
        None,
    )
    .await;
    assert_eq!(code, 200);
    assert_eq!(body["preparation"]["accepted"], true);
    assert_eq!(body["preparation"]["state"], "accepted");
    assert_eq!(body["preparation"]["deliveryError"], "node_offline");
    assert!(
        body["preparation"]["submission"]["message"]
            .as_str()
            .is_some()
    );
    assert_eq!(count(&app.db.lock(), "commands"), 0);
    register(&app);
    let (code, body) = call(
        &app,
        "POST",
        "/api/conversation-submissions/draft-1/materialize",
        Some("alice"),
        None,
        None,
    )
    .await;
    assert_eq!(code, 200);
    assert_eq!(body["preparation"]["state"], "ready");
    assert!(body["preparation"].get("deliveryError").is_none());
}
#[tokio::test]
async fn removing_work_preserves_accepted_pending_history_until_explicit_restore() {
    for insert_removed in [true, false] {
        let (app, _dir) = app();
        model(&app);
        register(&app);
        prepared(&app, false);
        let accepted = accept_intent(&app, &identity(), "draft-1").await.unwrap();
        let mut draft = input();
        draft.operation_id = "other-draft".into();
        draft.submission.attachments.clear();
        reserve(&mut app.db.lock(), "alice", &draft).unwrap();
        app.db.lock().execute("INSERT INTO workspace_removals(workspace_id,owner_user,removed_at,status) VALUES('node:repo','alice',1,?1)",[if insert_removed{"removed"}else{"checking"}]).unwrap();
        if !insert_removed {
            app.db
                .lock()
                .execute("UPDATE workspace_removals SET status='removed'", [])
                .unwrap();
        }
        let current = lookup(&app.db.lock(), "alice", "draft-1").unwrap();
        assert!(current.accepted);
        assert_eq!(current.state, Phase::Accepted);
        assert_eq!(
            current.submission.unwrap().message,
            "Keep this first message"
        );
        assert_eq!(
            lookup(&app.db.lock(), "alice", "other-draft")
                .unwrap()
                .state,
            Phase::Cancelled
        );
        assert!(advance(&app, &identity(), "draft-1").await.is_err());
        assert!(app.db.lock().list_sessions().unwrap().is_empty());
        crate::workspace_removal::restore(&app.db.lock(), "node:repo", "alice").unwrap();
        let ready = advance(&app, &identity(), "draft-1").await.unwrap();
        assert_eq!(ready.session_id, accepted.session_id);
        assert_eq!(ready.state, Phase::Ready);
        assert_eq!(count(&app.db.lock(), "sessions"), 1);
    }
}
#[tokio::test]
async fn old_node_without_mime_transport_capability_is_rejected_before_acceptance() {
    let (app, _dir) = app();
    model(&app);
    prepared(&app, false);
    app.nodes.set_test_node(connected(), |_| {
        let mut old = caps();
        old.as_object_mut().unwrap().remove("attachmentMimeInQuery");
        Ok(NodeHttpResponse {
            status: 200,
            body: Some(old),
        })
    });
    assert_eq!(
        accept_intent(&app, &identity(), "draft-1")
            .await
            .unwrap_err()
            .code,
        "first_send_unsupported"
    );
    assert_eq!(count(&app.db.lock(), "sessions"), 0);
}
#[tokio::test]
async fn device_revoked_during_allocation_cannot_send_attachment_bytes() {
    let (app, _dir) = app();
    model(&app);
    register(&app);
    prepared(&app, true);
    attachments::stage(&app, "alice", "draft-1", "file-1", b"test").unwrap();
    let (device, _) = app.devices.create("alice", "Native").unwrap();
    let mut caller = identity();
    caller.device_id = Some(device.id.clone());
    let accepted = accept_intent(&app, &caller, "draft-1").await.unwrap();
    let weak = Arc::downgrade(&app);
    app.nodes.set_test_node(connected(), move |r| {
        if r.url.ends_with("/capabilities") {
            return Ok(fake(&r));
        }
        assert_eq!(r.url, "/api/session-creations");
        let response = fake(&r);
        weak.upgrade()
            .unwrap()
            .devices
            .revoke("alice", &device.id)
            .unwrap();
        Ok(response)
    });
    assert_eq!(
        advance(&app, &caller, "draft-1").await.unwrap_err().status,
        401
    );
    assert!(
        app.db
            .lock()
            .get_session(&accepted.session_id)
            .unwrap()
            .pi_session_id
            .is_none()
    );
    assert!(lookup(&app.db.lock(), "alice", "draft-1").unwrap().accepted);
    register(&app);
    assert_eq!(
        advance(&app, &identity(), "draft-1").await.unwrap().state,
        Phase::Ready
    );
}
#[test]
fn expiry_and_acceptance_serialize_without_expiring_accepted_files() {
    for _ in 0..4 {
        let (first, _dir) = disk_app();
        model(&first);
        register(&first);
        prepared(&first, true);
        attachments::stage(&first, "alice", "draft-1", "file-1", b"test").unwrap();
        let second = App::new(
            first.config.clone(),
            Arc::new(Db::open(&first.config.state_dir.join("gateway.sqlite")).unwrap()),
            first.backends.clone(),
            crate::app::test_modes(),
        );
        register(&second);
        let b = std::sync::Barrier::new(2);
        std::thread::scope(|s| {
            let a = s.spawn(|| {
                b.wait();
                let t = target(&first.db.lock(), "alice", "draft-1").unwrap();
                commit_acceptance(&first, &identity(), "draft-1", &t)
            });
            let clean = s.spawn(|| {
                b.wait();
                attachments::sweep(
                    &second,
                    now_ms().saturating_add(2 * attachments::RETENTION_MS),
                )
                .unwrap()
            });
            let _ = a.join().unwrap();
            clean.join().unwrap();
        });
        let row = lookup(&first.db.lock(), "alice", "draft-1").unwrap();
        let path = first
            .config
            .state_dir
            .join("submission-staging")
            .join(&row.session_id)
            .join("file-1.bin");
        if row.accepted {
            assert!(path.exists());
            assert_eq!(count(&first.db.lock(), "sessions"), 1);
        } else {
            assert!(!path.exists());
            assert_eq!(count(&first.db.lock(), "sessions"), 0);
            assert_eq!(row.submission.unwrap().message, "Keep this first message");
        }
    }
}

#[tokio::test]
async fn a_node_without_pre_allocation_stop_support_cannot_accept_a_new_intent() {
    let (app, _dir) = app();
    model(&app);
    prepared(&app, false);
    app.nodes.set_test_node(connected(), |r| {
        assert_eq!(r.method, HttpMethod::Get);
        assert!(r.url.ends_with("/capabilities"));
        let mut old = caps();
        old.as_object_mut()
            .unwrap()
            .remove("canStopBeforeAllocation");
        Ok(NodeHttpResponse {
            status: 200,
            body: Some(old),
        })
    });
    assert_eq!(
        accept_intent(&app, &identity(), "draft-1")
            .await
            .unwrap_err()
            .code,
        "first_send_unsupported"
    );
    assert_eq!(count(&app.db.lock(), "sessions"), 0);
    assert!(!lookup(&app.db.lock(), "alice", "draft-1").unwrap().accepted);
}

#[tokio::test]
async fn accepted_input_rechecks_node_capabilities_before_storage_and_preserves_files() {
    for unsupported in [
        "missing-route",
        "new-version",
        "missing-stop",
        "upload-limit",
    ] {
        let (app, _dir) = disk_app();
        model(&app);
        register(&app);
        prepared(&app, true);
        attachments::stage(&app, "alice", "draft-1", "file-1", b"test").unwrap();
        let accepted = accept_intent(&app, &identity(), "draft-1").await.unwrap();
        app.nodes.set_test_node(connected(), move |r| {
            assert_eq!(r.method, HttpMethod::Get);
            assert_eq!(r.url, "/api/session-creations/capabilities");
            let mut capabilities = caps();
            match unsupported {
                "new-version" => capabilities["version"] = json!(2),
                "missing-stop" => {
                    capabilities
                        .as_object_mut()
                        .unwrap()
                        .remove("canStopBeforeAllocation");
                }
                "upload-limit" => capabilities["maxUploadBytes"] = json!(1),
                _ => (),
            }
            Ok(NodeHttpResponse {
                status: if unsupported == "missing-route" {
                    404
                } else {
                    200
                },
                body: Some(capabilities),
            })
        });
        let error = advance(&app, &identity(), "draft-1").await.unwrap_err();
        assert_eq!(
            error.code,
            if unsupported == "upload-limit" {
                "attachment_too_large"
            } else {
                "first_send_unsupported"
            }
        );
        let reopened = Db::open(&app.config.state_dir.join("gateway.sqlite")).unwrap();
        let pending = lookup(&reopened.lock(), "alice", "draft-1").unwrap();
        assert_eq!(pending.session_id, accepted.session_id);
        assert_eq!(pending.state, Phase::Accepted);
        assert_eq!(
            file(
                &app,
                &pending,
                &pending.submission.as_ref().unwrap().attachments[0]
            )
            .unwrap(),
            b"test"
        );
        assert!(
            app.db
                .lock()
                .get_session(&pending.session_id)
                .unwrap()
                .pi_session_id
                .is_none()
        );
        assert_eq!(count(&app.db.lock(), "commands"), 0);
        register(&app);
        let ready = advance(&app, &identity(), "draft-1").await.unwrap();
        assert_eq!(ready.state, Phase::Ready);
        assert_eq!(ready.session_id, accepted.session_id);
    }
}

#[tokio::test]
async fn revocation_or_workspace_removal_during_capability_check_prevents_allocation() {
    for revoke in [false, true] {
        let (app, _dir) = app();
        model(&app);
        register(&app);
        prepared(&app, false);
        let (device, _) = app.devices.create("alice", "Native").unwrap();
        let mut caller = identity();
        caller.device_id = Some(device.id.clone());
        let accepted = accept_intent(&app, &caller, "draft-1").await.unwrap();
        let weak = Arc::downgrade(&app);
        app.nodes.set_test_node(connected(), move |r| {
            assert_eq!(r.url, "/api/session-creations/capabilities");
            let app = weak.upgrade().unwrap();
            if revoke { app.devices.revoke("alice", &device.id).unwrap(); }
            else { app.db.lock().execute("INSERT INTO workspace_removals(workspace_id,owner_user,removed_at,status) VALUES('node:repo','alice',1,'removed')",[]).unwrap(); }
            Ok(fake(&r))
        });
        let error = advance(&app, &caller, "draft-1").await.unwrap_err();
        assert_eq!(
            error.code,
            if revoke {
                "unauthorized"
            } else {
                "workspace_removed"
            }
        );
        assert!(
            app.db
                .lock()
                .get_session(&accepted.session_id)
                .unwrap()
                .pi_session_id
                .is_none()
        );
        assert_eq!(
            lookup(&app.db.lock(), "alice", "draft-1").unwrap().state,
            Phase::Accepted
        );
    }
}

#[tokio::test]
async fn replacing_connection_after_probe_or_allocation_cannot_inherit_capability_proof() {
    for after_allocation in [false, true] {
        let (app, _dir) = app();
        model(&app);
        register(&app);
        prepared(&app, true);
        attachments::stage(&app, "alice", "draft-1", "file-1", b"test").unwrap();
        accept_intent(&app, &identity(), "draft-1").await.unwrap();
        let weak = Arc::downgrade(&app);
        app.nodes.set_test_node(connected(), move |r| {
            let reply = fake(&r);
            if (after_allocation && r.url == "/api/session-creations")
                || (!after_allocation && r.url.ends_with("/capabilities"))
            {
                weak.upgrade()
                    .unwrap()
                    .nodes
                    .set_test_node(connected(), |_| {
                        panic!(
                            "replacement connection must not receive allocation or attachment bytes"
                        )
                    });
            }
            Ok(reply)
        });
        assert_eq!(
            advance(&app, &identity(), "draft-1")
                .await
                .unwrap_err()
                .code,
            "node_connection_changed"
        );
        assert_eq!(
            lookup(&app.db.lock(), "alice", "draft-1").unwrap().state,
            Phase::Accepted
        );
        assert_eq!(count(&app.db.lock(), "commands"), 0);
    }
}
