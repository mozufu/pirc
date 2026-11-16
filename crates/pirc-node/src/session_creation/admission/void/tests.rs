//! Void against the Node's real admission code and store (no stand-in Node).
use super::*;
use crate::{
    app::tests::{start_workspace_node, workspace_test_node},
    router::Body,
    services::Node,
    store::ModeId,
};

const USER: &str = "test-user";
const HASH: &str = "a";

fn input(command: &str, message: &str, generation: i64) -> Input {
    serde_json::from_value(json!({"commandId":command,"submissionHash":HASH.repeat(64),"model":{"provider":"fake","id":"m"},"thinking":"low","message":message,"uploadIds":[],"clientId":"phone","generation":generation})).unwrap()
}
fn raw(input: &Input) -> Value {
    json!({"commandId":input.command_id,"submissionHash":input.submission_hash,"model":input.model,"thinking":input.thinking,"message":input.message,"uploadIds":input.upload_ids,"clientId":input.client_id,"generation":input.generation})
}
fn request(op: &str, user: &str, body: Value) -> Request {
    Request {
        method: pirc_protocol::HttpMethod::Post,
        path: String::new(),
        query: vec![],
        params: vec![("id".into(), op.into())],
        user: user.into(),
        body: Body::Json(body),
    }
}
fn void_body(input: &Input) -> Value {
    json!({"commandId":input.command_id,"submissionHash":input.submission_hash,"inputHash":input.hash()})
}
async fn prepared(node: &Node, op: &str) -> (String, i64) {
    let response = crate::session_creation::prepare(
        node.clone(),
        request(
            "",
            USER,
            json!({"operationId":op,"workspaceId":"repo","submissionHash":HASH.repeat(64)}),
        ),
    )
    .await
    .unwrap();
    let session = response.body.unwrap()["creation"]["sessionId"]
        .as_str()
        .unwrap()
        .to_owned();
    let lease = node
        .db
        .lock()
        .acquire_lease(&session, "phone", false, 600_000)
        .unwrap();
    (session, lease.generation)
}
async fn node() -> (tempfile::TempDir, Node) {
    let (dir, node) = workspace_test_node().await;
    let work = dir.path().canonicalize().unwrap().join("repository");
    std::fs::create_dir(&work).unwrap();
    node.db
        .lock()
        .add_workspace(
            "repo",
            "test-node",
            "Repo",
            work.to_str().unwrap(),
            ModeId::new("directory").unwrap(),
        )
        .unwrap();
    (dir, node)
}
fn count(node: &Node, sql: &str, id: &str) -> i64 {
    node.db.lock().query_row(sql, [id], |r| r.get(0)).unwrap()
}
fn commands(node: &Node, id: &str) -> i64 {
    count(node, "SELECT count(*) FROM commands WHERE id=?1", id)
}
fn voids(node: &Node, id: &str) -> i64 {
    count(
        node,
        "SELECT count(*) FROM creation_admission_voids WHERE command_id=?1",
        id,
    )
}
fn result(response: &Response) -> String {
    response.body.as_ref().unwrap()["void"]["result"]
        .as_str()
        .unwrap()
        .to_owned()
}

#[tokio::test]
async fn a_void_wins_so_a_delayed_submit_is_refused_and_creates_nothing() {
    // D5: the original request reaches the Node only after the void succeeded.
    let (_dir, node) = node().await;
    let (session, generation) = prepared(&node, "creation-1").await;
    let first = input("first-message", "hello", generation);
    let voided = void(node.clone(), request("creation-1", USER, void_body(&first)))
        .await
        .unwrap();
    assert_eq!(result(&voided), "voided");

    let late = submit(node.clone(), request("creation-1", USER, raw(&first)))
        .await
        .unwrap_err();
    assert_eq!((late.status, late.code.as_ref()), (409, "command_voided"));
    // Nothing was created, started or recorded for it.
    assert_eq!(commands(&node, "first-message"), 0);
    assert_eq!(
        count(
            &node,
            "SELECT count(*) FROM creation_admission_attempts WHERE command_id=?1",
            "first-message"
        ),
        0
    );
    assert_eq!(
        count(
            &node,
            "SELECT count(*) FROM creation_initial_admissions WHERE session_id=?1",
            &session
        ),
        0
    );
    assert!(node.runners.get(&session).is_none());
    // Different content under the same id is refused the same way.
    let changed = input("first-message", "something else", generation);
    let late = submit(node.clone(), request("creation-1", USER, raw(&changed)))
        .await
        .unwrap_err();
    assert_eq!(late.code, "command_voided");
    // The receipt still says nothing was admitted.
    let status = status(node.clone(), request("creation-1", USER, json!({})))
        .await
        .unwrap();
    assert_eq!(status.body.unwrap()["admission"]["state"], "not_submitted");
    node.close().await;
}

#[tokio::test]
async fn an_admission_that_wins_is_reported_by_the_void_and_nothing_is_voided() {
    // D6, submit first.
    let (_dir, node) = node().await;
    let (_session, generation) = prepared(&node, "creation-1").await;
    let first = input("first-message", "hello", generation);
    submit(node.clone(), request("creation-1", USER, raw(&first)))
        .await
        .unwrap();
    assert_eq!(commands(&node, "first-message"), 1);
    let answer = void(node.clone(), request("creation-1", USER, void_body(&first)))
        .await
        .unwrap();
    assert_eq!(result(&answer), "admission");
    let body = answer.body.unwrap();
    assert_eq!(body["admission"]["command"]["id"], "first-message");
    assert_eq!(body["admission"]["inputHash"], first.hash());
    assert_eq!(voids(&node, "first-message"), 0);
    // And a repeated void still reports it, never writes.
    let again = void(node.clone(), request("creation-1", USER, void_body(&first)))
        .await
        .unwrap();
    assert_eq!(result(&again), "admission");
    assert_eq!(voids(&node, "first-message"), 0);
    node.close().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_void_and_a_submit_racing_leave_exactly_one_winner() {
    // D6, both orders and truly concurrent: either the admission exists and
    // the void reports it, or the void exists and the submit was refused.
    let (_dir, node) = node().await;
    let (mut admitted, mut voided) = (0, 0);
    for round in 0..40 {
        let op = format!("creation-race-{round}");
        let (_session, generation) = prepared(&node, &op).await;
        let first = input(&format!("first-{round}"), "hello", generation);
        let gate = std::sync::Arc::new(tokio::sync::Barrier::new(2));
        let submit_task = || {
            let (node, op, body, gate) = (node.clone(), op.clone(), raw(&first), gate.clone());
            tokio::spawn(async move {
                gate.wait().await;
                submit(node, request(&op, USER, body)).await
            })
        };
        let void_task = || {
            let (node, op, body, gate) =
                (node.clone(), op.clone(), void_body(&first), gate.clone());
            tokio::spawn(async move {
                gate.wait().await;
                void(node, request(&op, USER, body)).await
            })
        };
        // Alternate which one is started first; the barrier releases both at once.
        let (a, b) = if round % 2 == 0 {
            let a = submit_task();
            (a, void_task())
        } else {
            let b = void_task();
            (submit_task(), b)
        };
        let (submitted, answer) = (a.await.unwrap(), b.await.unwrap().unwrap());
        let id = first.command_id.as_str();
        match result(&answer).as_str() {
            "voided" => {
                voided += 1;
                assert_eq!(submitted.unwrap_err().code, "command_voided");
                assert_eq!((commands(&node, id), voids(&node, id)), (0, 1));
            }
            "admission" => {
                admitted += 1;
                assert!(submitted.is_ok());
                assert_eq!((commands(&node, id), voids(&node, id)), (1, 0));
            }
            other => panic!("unexpected void result {other}"),
        }
    }
    assert_eq!(admitted + voided, 40);
    node.close().await;
}

#[tokio::test]
async fn a_lost_void_reply_is_answered_the_same_when_sent_again() {
    // D7.
    let (_dir, node) = node().await;
    let (_session, generation) = prepared(&node, "creation-1").await;
    let first = input("first-message", "hello", generation);
    let body = void_body(&first);
    for _ in 0..3 {
        let answer = void(node.clone(), request("creation-1", USER, body.clone()))
            .await
            .unwrap();
        assert_eq!(result(&answer), "voided");
        assert_eq!(answer.body.unwrap()["void"]["commandId"], "first-message");
    }
    assert_eq!(voids(&node, "first-message"), 1);
    // The same id for other content is a conflict, not a second void.
    let mut other = void_body(&first);
    other["inputHash"] = json!("b".repeat(64));
    assert_eq!(
        void(node.clone(), request("creation-1", USER, other))
            .await
            .unwrap_err()
            .status,
        409
    );
    // It also works through the router, which is what the Gateway uses.
    let routed = node
        .router
        .handle(
            &node,
            pirc_protocol::NodeHttpRequest {
                method: pirc_protocol::HttpMethod::Post,
                url: "/api/session-creations/creation-1/admission/void".into(),
                user: USER.into(),
                payload: Some(body),
                body_base64: None,
                content_type: None,
            },
        )
        .await;
    assert_eq!(routed.status, 200, "{routed:?}");
    assert_eq!(routed.body.unwrap()["void"]["result"], "voided");
    node.close().await;
}

#[tokio::test]
async fn a_void_survives_a_node_restart_and_a_delayed_submit_is_still_refused() {
    // D9.
    let (dir, node) = node().await;
    let (_session, generation) = prepared(&node, "creation-1").await;
    let first = input("first-message", "hello", generation);
    void(node.clone(), request("creation-1", USER, void_body(&first)))
        .await
        .unwrap();
    node.close().await;
    drop(node);

    let node = start_workspace_node(dir.path(), false).await;
    assert_eq!(voids(&node, "first-message"), 1);
    // The lease died with the old process; the void is checked before it.
    let late = submit(node.clone(), request("creation-1", USER, raw(&first)))
        .await
        .unwrap_err();
    assert_eq!((late.status, late.code.as_ref()), (409, "command_voided"));
    assert_eq!(commands(&node, "first-message"), 0);
    let again = void(node.clone(), request("creation-1", USER, void_body(&first)))
        .await
        .unwrap();
    assert_eq!(result(&again), "voided");
    node.close().await;
}

#[tokio::test]
async fn a_void_is_bound_to_its_owner_creation_and_input() {
    let (_dir, node) = node().await;
    let (_a, generation) = prepared(&node, "creation-1").await;
    let (_b, _) = prepared(&node, "creation-2").await;
    let first = input("first-message", "hello", generation);
    // Another user cannot see, void or probe the creation.
    assert_eq!(
        void(
            node.clone(),
            request("creation-1", "intruder", void_body(&first))
        )
        .await
        .unwrap_err()
        .status,
        404
    );
    // A different submission identity is refused.
    let mut wrong = void_body(&first);
    wrong["submissionHash"] = json!("c".repeat(64));
    assert_eq!(
        void(node.clone(), request("creation-1", USER, wrong))
            .await
            .unwrap_err()
            .status,
        409
    );
    // Malformed identities are refused before anything is read.
    for bad in [
        json!({"commandId":"a b","submissionHash":HASH.repeat(64),"inputHash":first.hash()}),
        json!({"commandId":"x","submissionHash":"short","inputHash":first.hash()}),
        json!({"commandId":"x","submissionHash":HASH.repeat(64)}),
    ] {
        assert_eq!(
            void(node.clone(), request("creation-1", USER, bad))
                .await
                .unwrap_err()
                .status,
            400
        );
    }
    assert_eq!(voids(&node, "first-message"), 0);
    void(node.clone(), request("creation-1", USER, void_body(&first)))
        .await
        .unwrap();
    // The id is voided for creation-1 only through that creation, but is never
    // reusable by another creation: its table key is the id itself.
    let conflict = void(node.clone(), request("creation-2", USER, void_body(&first)))
        .await
        .unwrap_err();
    assert_eq!(conflict.status, 409);
    let late = submit(node.clone(), request("creation-2", USER, raw(&first)))
        .await
        .unwrap_err();
    assert_eq!(late.code, "command_voided");
    node.close().await;
}

#[tokio::test]
async fn the_store_itself_keeps_admission_and_void_mutually_exclusive_and_final() {
    let (_dir, node) = node().await;
    let (session, generation) = prepared(&node, "creation-1").await;
    let first = input("first-message", "hello", generation);
    void(node.clone(), request("creation-1", USER, void_body(&first)))
        .await
        .unwrap();
    {
        let db = node.db.lock();
        // Whatever path inserts it, a voided command id cannot become a command.
        assert!(
            db.receive_command("first-message", &session, "hash", &json!({"type":"stop"}))
                .is_err()
        );
        assert_eq!(
            db.query_row(
                "SELECT count(*) FROM commands WHERE id='first-message'",
                [],
                |r| r.get::<_, i64>(0)
            )
            .unwrap(),
            0
        );
        assert!(
        db.execute(
            "INSERT INTO creation_initial_admissions(owner_user,operation_id,session_id,command_id,input_hash,created_at,updated_at) VALUES(?1,'creation-1',?2,'first-message',?3,1,1)",
            params![USER, session, first.hash()],
        )
        .is_err()
    );
        // A void is neither updated nor removed.
        assert!(
            db.execute("UPDATE creation_admission_voids SET input_hash=?1", ["x"])
                .is_err()
        );
        assert!(
            db.execute("DELETE FROM creation_admission_voids", [])
                .is_err()
        );
        // And an admitted command cannot be voided by a direct write either.
        db.receive_command("admitted", &session, "hash", &json!({"type":"stop"}))
            .unwrap();
        assert!(db
        .execute(
            "INSERT INTO creation_admission_voids(owner_user,operation_id,command_id,session_id,input_hash,created_at) VALUES(?1,'creation-1','admitted',?2,?3,1)",
            params![USER, session, first.hash()],
        )
        .is_err());
    }
    node.close().await;
}

#[tokio::test]
async fn an_explicit_retry_after_a_void_becomes_the_first_admission_and_keeps_its_input() {
    let (_dir, node) = node().await;
    let (_session, generation) = prepared(&node, "creation-1").await;
    let first = input("first-message", "hello", generation);
    void(node.clone(), request("creation-1", USER, void_body(&first)))
        .await
        .unwrap();
    let successor = input("second-message", "hello", generation);
    let retry_body = |previous: &str, admission: &Input| json!({"previousCommandId":previous,"admission":raw(admission)});
    // Different content cannot ride on the voided identity.
    let changed = input("second-message", "something else", generation);
    assert_eq!(
        retry(
            node.clone(),
            request("creation-1", USER, retry_body("first-message", &changed))
        )
        .await
        .unwrap_err()
        .status,
        409
    );
    // The voided id cannot be the successor.
    assert_eq!(
        retry(
            node.clone(),
            request("creation-1", USER, retry_body("second-message", &first))
        )
        .await
        .unwrap_err()
        .code,
        "command_voided"
    );
    // An id that was neither admitted nor voided is not a valid predecessor.
    assert_eq!(
        retry(
            node.clone(),
            request("creation-1", USER, retry_body("never-seen", &successor))
        )
        .await
        .unwrap_err()
        .status,
        409
    );
    retry(
        node.clone(),
        request("creation-1", USER, retry_body("first-message", &successor)),
    )
    .await
    .unwrap();
    assert_eq!(commands(&node, "second-message"), 1);
    let previous: String = node
        .db
        .lock()
        .query_row(
            "SELECT previous_command_id FROM creation_admission_attempts WHERE command_id='second-message'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(previous, "first-message");
    // The same retry sent again is a duplicate, not another admission.
    retry(
        node.clone(),
        request("creation-1", USER, retry_body("first-message", &successor)),
    )
    .await
    .unwrap();
    assert_eq!(
        count(
            &node,
            "SELECT count(*) FROM creation_admission_attempts WHERE operation_id=?1",
            "creation-1"
        ),
        1
    );
    // The original command id stays voided for good.
    assert_eq!(commands(&node, "first-message"), 0);
    node.close().await;
}

#[tokio::test]
async fn the_node_advertises_the_void_operation() {
    let (_dir, node) = node().await;
    let caps = crate::session_creation::capabilities(node.clone(), request("", USER, json!({})))
        .await
        .unwrap()
        .body
        .unwrap();
    assert_eq!(caps["canVoidInitialAdmission"], true);
    assert_eq!(caps["canRetryInitialAdmission"], true);
    node.close().await;
}
