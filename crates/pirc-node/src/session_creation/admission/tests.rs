use super::*;
use crate::{
    router::Body,
    store::{Db, ModeId},
};

fn intent() -> Input {
    serde_json::from_value(json!({"commandId":"first-message","submissionHash":"a".repeat(64),"model":{"provider":"fake","id":"m"},"thinking":"low","message":"first user text","uploadIds":[],"clientId":"phone","generation":1})).unwrap()
}
fn setup(db: &Connection) -> String {
    db.add_workspace(
        "repo",
        "node",
        "Repo",
        "/repo",
        ModeId::new("directory").unwrap(),
    )
    .unwrap();
    let session = db
        .create_session("repo", "/private-session", "alice")
        .unwrap();
    db.execute("INSERT INTO session_creations(owner_user,operation_id,workspace_id,submission_hash,session_id,state,created_at) VALUES('alice','creation-1','repo',?1,?2,'ready',1)",params!["a".repeat(64),session.id]).unwrap();
    session.id
}
fn bind(db: &Connection, session: &str, input: &Input) {
    let payload = serde_json::to_value(input.payload()).unwrap();
    db.receive_command(
        &input.command_id,
        session,
        &payload_hash(&payload),
        &payload,
    )
    .unwrap();
    db.execute("INSERT INTO creation_initial_admissions(owner_user,operation_id,session_id,command_id,input_hash,created_at,updated_at) VALUES('alice','creation-1',?1,?2,?3,1,1)",params![session,input.command_id,input.hash()]).unwrap();
}
fn request(input: &Input, user: &str) -> Request {
    Request {
        method: pirc_protocol::HttpMethod::Post,
        path: String::new(),
        query: vec![],
        params: vec![("id".into(), "creation-1".into())],
        user: user.into(),
        body: Body::Json(
            json!({"commandId":input.command_id,"submissionHash":input.submission_hash,"model":input.model,"thinking":input.thinking,"message":input.message,"uploadIds":input.upload_ids,"clientId":input.client_id,"generation":input.generation}),
        ),
    }
}
#[test]
fn restart_marks_only_pending_initial_receipts_unknown_and_lookup_does_not_take_control() {
    let db = Db::memory();
    let conn = db.lock();
    let session = setup(&conn);
    let input = intent();
    bind(&conn, &session, &input);
    conn.receive_command(
        "legacy-received",
        &session,
        "legacy-hash",
        &json!({"type":"stop"}),
    )
    .unwrap();
    conn.acquire_lease(&session, "phone", false, 60_000)
        .unwrap();
    let recovery = conn.recover_startup().unwrap();
    assert_eq!(recovery.unknown_commands, 1);
    assert_eq!(
        conn.get_command(&input.command_id).unwrap().status,
        CommandStatus::OutcomeUnknown
    );
    assert_eq!(
        conn.get_command("legacy-received").unwrap().status,
        CommandStatus::Received
    );
    let before = conn.get_lease(&session).unwrap();
    let status = receipt(&conn, "alice", "creation-1").unwrap().body.unwrap();
    assert_eq!(status["admission"]["state"], "outcome_unknown");
    assert_eq!(status["admission"]["inputHash"], input.hash());
    assert_eq!(conn.get_lease(&session).unwrap(), before);
    assert_eq!(receipt(&conn, "bob", "creation-1").unwrap_err().status, 404);
}
#[test]
fn stop_fences_even_an_initial_request_not_yet_registered_and_allows_explicit_new_input_only_after_confirmation()
 {
    let db = Db::memory();
    let conn = db.lock();
    let session = setup(&conn);
    assert!(require_generic(&conn, &session).is_err());
    assert!(request_stop(&conn, &session, "alice").unwrap());
    assert_eq!(
        receipt(&conn, "alice", "creation-1").unwrap().body.unwrap()["admission"]["state"],
        "stopping"
    );
    assert!(require_generic(&conn, &session).is_err());
    confirm_stop(&conn, &session).unwrap();
    assert!(require_generic(&conn, &session).is_ok());
    let r = receipt(&conn, "alice", "creation-1").unwrap().body.unwrap();
    assert_eq!(r["admission"]["state"], "stopped");
    assert!(r["admission"]["command"].is_null());
    assert!(require_sendable(&conn, &session, "first-message", "alice").is_err());
}
#[test]
fn deletion_retains_only_identity_and_never_turns_hidden_receipts_into_non_admission_proof() {
    let db = Db::memory();
    let conn = db.lock();
    let session = setup(&conn);
    bind(&conn, &session, &intent());
    conn.update_command("first-message", CommandStatus::Accepted, None, None)
        .unwrap();
    conn.begin_session_deletion(&session, "alice").unwrap();
    let pending = receipt(&conn, "alice", "creation-1").unwrap().body.unwrap();
    assert_eq!(pending["admission"]["state"], "deleting");
    assert_eq!(pending["admission"]["stopConfirmed"], false);
    conn.finish_session_deletion(&session).unwrap();
    let status = receipt(&conn, "alice", "creation-1").unwrap().body.unwrap();
    assert_eq!(status["admission"]["state"], "deleted");
    assert!(status["admission"]["command"].is_null());
    assert!(!status.to_string().contains("first user text"));
    assert!(require_sendable(&conn, &session, "first-message", "alice").is_err());
}
#[tokio::test]
async fn persisted_duplicate_returns_receipt_without_a_lease_or_runner_and_rejects_changed_model_or_text()
 {
    let (_dir, node, session) = super::super::uploads::tests::node().await;
    let input = intent();
    let user = "test-user";
    {
        let db = node.db.lock();
        let payload = serde_json::to_value(input.payload()).unwrap();
        db.receive_command(
            &input.command_id,
            &session,
            &payload_hash(&payload),
            &payload,
        )
        .unwrap();
        db.execute("INSERT INTO creation_initial_admissions(owner_user,operation_id,session_id,command_id,input_hash,created_at,updated_at) VALUES(?1,'creation-1',?2,?3,?4,1,1)",params![user,session,input.command_id,input.hash()]).unwrap();
        db.update_command(
            &input.command_id,
            CommandStatus::Accepted,
            Some(&json!({"success":true})),
            None,
        )
        .unwrap();
    }
    let response = submit(node.clone(), request(&input, user)).await.unwrap();
    assert_eq!(
        response.body.unwrap()["admission"]["command"]["status"],
        "accepted"
    );
    assert!(node.runners.get(&session).is_none());
    let mut changed = intent();
    changed.message = "different".into();
    assert_eq!(
        submit(node.clone(), request(&changed, user))
            .await
            .unwrap_err()
            .status,
        409
    );
    let mut changed = intent();
    changed.model.id = "different".into();
    assert_eq!(
        submit(node.clone(), request(&changed, user))
            .await
            .unwrap_err()
            .status,
        409
    );
    assert_eq!(
        submit(node.clone(), request(&input, "other-user"))
            .await
            .unwrap_err()
            .status,
        404
    );
    node.close().await;
}
#[tokio::test]
async fn no_runner_stop_is_confirmed_and_late_first_send_cannot_start_anything() {
    use pirc_protocol::{HttpMethod, NodeHttpRequest};
    let (_dir, node, session) = super::super::uploads::tests::node().await;
    let lease = node
        .db
        .lock()
        .acquire_lease(&session, "phone", false, 60_000)
        .unwrap();
    let stop=node.router.handle(&node,NodeHttpRequest{method:HttpMethod::Post,url:format!("/api/sessions/{session}/commands"),user:"test-user".into(),payload:Some(json!({"commandId":"stop-first","clientId":"phone","generation":lease.generation,"payload":{"type":"stop"}})),body_base64:None,content_type:None}).await;
    assert_eq!(stop.status, 202, "{stop:?}");
    assert_eq!(
        stop.body.unwrap()["initialAdmission"]["stopConfirmed"],
        true
    );
    let mut input = intent();
    input.generation = lease.generation;
    let result = submit(node.clone(), request(&input, "test-user"))
        .await
        .unwrap();
    assert_eq!(result.body.unwrap()["admission"]["state"], "stopped");
    assert!(node.runners.get(&session).is_none());
    assert!(node.db.lock().get_command("first-message").is_err());
    node.close().await;
}
#[tokio::test]
async fn raw_command_lookup_neither_claims_an_unowned_session_nor_renews_its_lease() {
    let (_dir, node, session) = super::super::uploads::tests::node().await;
    node.db
        .lock()
        .receive_command(
            "command-1",
            &session,
            "hash",
            &json!({"type":"prompt","message":"own text"}),
        )
        .unwrap();
    let _lease = node
        .db
        .lock()
        .acquire_lease(&session, "phone", false, 60_000)
        .unwrap();
    let before = node.db.lock().get_lease(&session).unwrap();
    let query = Request {
        method: pirc_protocol::HttpMethod::Get,
        path: String::new(),
        query: vec![],
        params: vec![
            ("id".into(), session.clone()),
            ("commandId".into(), "command-1".into()),
        ],
        user: "test-user".into(),
        body: Body::None,
    };
    assert_eq!(
        command_status(node.clone(), query.clone())
            .await
            .unwrap()
            .body
            .unwrap()["command"]["id"],
        "command-1"
    );
    assert_eq!(node.db.lock().get_lease(&session).unwrap(), before);
    node.db
        .lock()
        .execute(
            "UPDATE sessions SET owner_user=NULL WHERE id=?1",
            [&session],
        )
        .unwrap();
    assert_eq!(
        command_status(node.clone(), query)
            .await
            .unwrap_err()
            .status,
        404
    );
    assert!(
        node.db
            .lock()
            .get_session(&session)
            .unwrap()
            .owner_user
            .is_none()
    );
    node.close().await;
}
