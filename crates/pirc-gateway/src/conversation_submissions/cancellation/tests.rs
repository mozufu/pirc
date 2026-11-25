use super::super::acceptance::tests::{connected, identity, model, prepared, register};
use super::super::tests::{app, call, count, disk_app};
use super::*;
use crate::db::Db;
async fn accepted(disk: bool) -> (AppState, tempfile::TempDir, String) {
    let (app, dir) = if disk { disk_app() } else { app() };
    let mut modes = crate::app::test_modes();
    modes
        .modes
        .get_mut(&pirc_protocol::mode::ModeId::new("directory").unwrap())
        .unwrap()
        .delete_sessions = true;
    *app.modes.write().unwrap() = Arc::new(modes);
    model(&app);
    register(&app);
    prepared(&app, false);
    let row = super::super::acceptance::accept_intent(&app, &identity(), "draft-1")
        .await
        .unwrap();
    (app, dir, row.session_id)
}
fn proof(j: &Job) -> Value {
    json!({"operationId":j.creation,"workspaceId":j.workspace,"submissionHash":j.hash,"sessionId":j.expected,"complete":true})
}
fn confirm(app: &AppState, proof: Value) {
    app.nodes.set_test_node(connected(), move |r| {
        assert_eq!(r.method, HttpMethod::Post);
        assert!(r.url.ends_with("/cancel"));
        Ok(pirc_protocol::NodeHttpResponse {
            status: 200,
            body: Some(json!({"cancellation":proof})),
        })
    });
}
#[tokio::test]
async fn deleting_before_materialization_uses_creation_identity_and_does_not_need_a_remote_session_id()
 {
    let (app, _dir, session) = accepted(false).await;
    let target = super::super::acceptance::target(&app.db.lock(), "alice", "draft-1").unwrap();
    let calls = Arc::new(std::sync::Mutex::new(Vec::new()));
    let log = calls.clone();
    app.nodes.set_test_node(connected(),move |r|{log.lock().unwrap().push(r.clone());assert_eq!(r.url,format!("/api/session-creations/{}/cancel",target.creation));assert_eq!(r.payload.as_ref().unwrap()["submissionHash"],target.hash);Ok(pirc_protocol::NodeHttpResponse{status:200,body:Some(json!({"cancellation":{"operationId":target.creation,"workspaceId":target.workspace,"submissionHash":target.hash,"sessionId":null,"complete":true}}))})});
    let (code, body) = call(
        &app,
        "DELETE",
        &format!("/api/sessions/{session}"),
        Some("alice"),
        None,
        None,
    )
    .await;
    assert_eq!(code, 204, "{body}");
    assert_eq!(calls.lock().unwrap().len(), 1);
    let row = lookup(&app.db.lock(), "alice", "draft-1").unwrap();
    assert_eq!(row.state, Phase::Cancelled);
    assert!(row.accepted);
    assert!(row.submission.is_none());
    assert!(app.db.lock().get_session(&session).is_err());
    assert_eq!(
        count(&app.db.lock(), "conversation_submission_remote_cleanup"),
        0
    );
    assert_eq!(
        call(
            &app,
            "DELETE",
            &format!("/api/sessions/{session}"),
            Some("alice"),
            None,
            None
        )
        .await
        .0,
        204
    );
}
#[tokio::test]
async fn response_loss_keeps_a_durable_cleanup_job_and_reopen_reconciles_without_a_lease() {
    let (app, _dir, session) = accepted(true).await;
    app.nodes.set_test_node(connected(), |_| {
        Err(ApiError::new(503, "node_offline", "synthetic disconnect"))
    });
    let (code, body) = call(
        &app,
        "DELETE",
        &format!("/api/sessions/{session}"),
        Some("alice"),
        None,
        None,
    )
    .await;
    assert_eq!(code, 202, "{body}");
    let row = lookup(&app.db.lock(), "alice", "draft-1").unwrap();
    assert!(row.cleanup_pending);
    assert!(row.submission.is_none());
    assert_eq!(row.cleanup_error.as_deref(), Some("node_offline"));
    let fresh = crate::app::App::new(
        app.config.clone(),
        Arc::new(Db::open(&app.config.state_dir.join("gateway.sqlite")).unwrap()),
        app.backends.clone(),
        crate::app::test_modes(),
    );
    let j = read(&fresh.db.lock(), "alice", "draft-1").unwrap().unwrap();
    confirm(&fresh, proof(&j));
    sweep(&fresh).await.unwrap();
    assert!(fresh.db.lock().get_session(&session).is_err());
    assert_eq!(
        count(&fresh.db.lock(), "conversation_submission_remote_cleanup"),
        0
    );
    assert!(fresh.db.lock().get_lease(&session).unwrap().is_null());
}
#[tokio::test]
async fn incorrect_cancellation_evidence_cannot_finish_deletion() {
    for field in ["operationId", "workspaceId", "submissionHash", "sessionId"] {
        let (app, _dir, session) = accepted(false).await;
        super::super::acceptance::advance(&app, &identity(), "draft-1")
            .await
            .unwrap();
        app.db
            .lock()
            .begin_session_deletion(&session, "alice")
            .unwrap();
        let j = read(&app.db.lock(), "alice", "draft-1").unwrap().unwrap();
        let mut bad = proof(&j);
        bad[field] = json!("other");
        confirm(&app, bad);
        sweep(&app).await.unwrap();
        assert!(read(&app.db.lock(), "alice", "draft-1").unwrap().is_some());
        assert_ne!(
            app.db
                .lock()
                .session_deletion(&session)
                .unwrap()
                .unwrap()
                .status,
            crate::db::DeletionStatus::Deleted
        );
        assert!(app.db.lock().get_session(&session).is_ok());
    }
}
#[tokio::test]
async fn deletion_during_unknown_allocation_cannot_publish_the_late_mapping() {
    let (app, _dir, session) = accepted(false).await;
    let weak = Arc::downgrade(&app);
    let sid = session.clone();
    app.nodes.set_test_node(connected(),move |r|{
        let app=weak.upgrade().unwrap();
        if r.url.ends_with("/capabilities") { return Ok(super::super::acceptance::tests::fake(&r)); }
        if r.url=="/api/session-creations"{
            app.db.lock().begin_session_deletion(&sid,"alice").unwrap();
            let input=r.payload.unwrap();return Ok(pirc_protocol::NodeHttpResponse{status:200,body:Some(json!({"creation":{"operationId":input["operationId"],"workspaceId":input["workspaceId"],"sessionId":"unknown-remote","state":"ready"}}))});
        }
        assert!(r.url.ends_with("/cancel"));let j=read(&app.db.lock(),"alice","draft-1").unwrap().unwrap();let mut proof=proof(&j);proof["sessionId"]=json!("unknown-remote");
        Ok(pirc_protocol::NodeHttpResponse{status:200,body:Some(json!({"cancellation":proof}))})
    });
    assert!(
        super::super::acceptance::advance(&app, &identity(), "draft-1")
            .await
            .is_err()
    );
    assert!(
        app.db
            .lock()
            .get_session(&session)
            .unwrap()
            .pi_session_id
            .is_none()
    );
    sweep(&app).await.unwrap();
    assert!(app.db.lock().get_session(&session).is_err());
}
#[tokio::test]
async fn unaccepted_discard_never_creates_a_remote_cleanup_job() {
    let (app, _dir) = app();
    model(&app);
    register(&app);
    prepared(&app, false);
    super::super::cancel(&app.db.lock(), "alice", "draft-1").unwrap();
    assert_eq!(
        count(&app.db.lock(), "conversation_submission_remote_cleanup"),
        0
    );
    sweep(&app).await.unwrap();
}
#[tokio::test]
async fn fresh_deletion_respects_mode_permission_but_committed_cleanup_survives_mode_removal() {
    let (app, _dir, session) = accepted(false).await;
    // A mode that keeps its conversations.
    let mut keeping = crate::app::test_modes();
    for mode in keeping.modes.values_mut() {
        mode.delete_sessions = false;
    }
    *app.modes.write().unwrap() = Arc::new(keeping);
    assert_eq!(
        call(
            &app,
            "DELETE",
            &format!("/api/sessions/{session}"),
            Some("alice"),
            None,
            None
        )
        .await
        .0,
        400
    );
    assert!(app.db.lock().session_deletion(&session).unwrap().is_none());
    app.db
        .lock()
        .begin_session_deletion(&session, "alice")
        .unwrap();
    *app.modes.write().unwrap() = Arc::new(Default::default());
    let j = read(&app.db.lock(), "alice", "draft-1").unwrap().unwrap();
    confirm(&app, proof(&j));
    assert_eq!(
        call(
            &app,
            "DELETE",
            &format!("/api/sessions/{session}"),
            Some("alice"),
            None,
            None
        )
        .await
        .0,
        204
    );
}
