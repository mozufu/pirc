//! Void against the Node's real fence code and store (no stand-in Node).
use super::*;
use crate::services::Node;
use crate::{
    app::tests::{start_workspace_node, workspace_test_node},
    router::Body,
    store::{ModeId, Store},
};
use serde_json::Value;
use std::sync::Arc;

const USER: &str = "test-user";
const PLAN: &str = "a";

fn request(session: &str, op: Option<&str>, user: &str, body: Value) -> Request {
    let mut params = vec![("id".to_owned(), session.to_owned())];
    if let Some(op) = op {
        params.push(("operation".to_owned(), op.to_owned()));
    }
    Request {
        method: pirc_protocol::HttpMethod::Post,
        path: String::new(),
        query: vec![],
        params,
        user: user.into(),
        body: Body::Json(body),
    }
}
fn create_body(op: &str, epoch: i64, generation: i64) -> Value {
    json!({"intent":{"operationId":op,"planHash":PLAN.repeat(64),"expectedWorkspaceId":"repo","expectedRunnerEpoch":epoch},"clientId":"phone","generation":generation})
}
fn void_body() -> Value {
    json!({"planHash":PLAN.repeat(64)})
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
/// A session of `USER` with a lease: `(session id, runner epoch, generation)`.
fn session(node: &Node, tag: &str) -> (String, i64, i64) {
    let db = node.db.lock();
    let s = db
        .create_session("repo", &format!("/private/{tag}"), USER)
        .unwrap();
    let lease = db.acquire_lease(&s.id, "phone", false, 600_000).unwrap();
    (s.id, s.runner_epoch, lease.generation)
}
fn fences(node: &Node, op: &str) -> i64 {
    node.db
        .lock()
        .query_row(
            "SELECT count(*) FROM execution_fences WHERE operation_id=?1",
            [op],
            |r| r.get(0),
        )
        .unwrap()
}
fn voids(node: &Node, op: &str) -> i64 {
    node.db
        .lock()
        .query_row(
            "SELECT count(*) FROM execution_fence_voids WHERE operation_id=?1",
            [op],
            |r| r.get(0),
        )
        .unwrap()
}
fn result(response: &Response) -> String {
    response.body.as_ref().unwrap()["void"]["result"]
        .as_str()
        .unwrap()
        .to_owned()
}

#[tokio::test]
async fn a_void_wins_so_a_delayed_create_is_refused_and_creates_nothing() {
    // X3: the original request reaches the Node only after the void succeeded.
    let (_dir, node) = node().await;
    let (id, epoch, generation) = session(&node, "one");
    let voided = void(node.clone(), request(&id, Some("op-1"), USER, void_body()))
        .await
        .unwrap();
    assert_eq!(result(&voided), "voided");
    assert_eq!(voided.body.unwrap()["void"]["sessionId"], id);

    let late = create(
        node.clone(),
        request(&id, None, USER, create_body("op-1", epoch, generation)),
    )
    .await
    .unwrap_err();
    assert_eq!((late.status, late.code.as_ref()), (409, "operation_voided"));
    assert_eq!(fences(&node, "op-1"), 0);
    // The session is open and nothing was paused for it.
    require_open(&node.db.lock(), &id).unwrap();
    // A different plan under the same id is refused the same way.
    let mut other = create_body("op-1", epoch, generation);
    other["intent"]["planHash"] = json!("b".repeat(64));
    let late = create(node.clone(), request(&id, None, USER, other))
        .await
        .unwrap_err();
    assert_eq!(late.code, "operation_voided");
    // The receipt still says nothing was created.
    let status = status(node.clone(), request(&id, Some("op-1"), USER, json!({})))
        .await
        .unwrap_err();
    assert_eq!(status.status, 404);
    // A new operation on the same session is a new identity and works.
    create(
        node.clone(),
        request(&id, None, USER, create_body("op-2", epoch, generation)),
    )
    .await
    .unwrap();
    assert_eq!(fences(&node, "op-2"), 1);
    node.close().await;
}

#[tokio::test]
async fn a_fence_that_wins_is_reported_by_the_void_and_nothing_is_voided() {
    // X2: the create succeeded and only its reply was lost.
    let (_dir, node) = node().await;
    let (id, epoch, generation) = session(&node, "one");
    create(
        node.clone(),
        request(&id, None, USER, create_body("op-1", epoch, generation)),
    )
    .await
    .unwrap();
    for _ in 0..2 {
        let answer = void(node.clone(), request(&id, Some("op-1"), USER, void_body()))
            .await
            .unwrap();
        assert_eq!(result(&answer), "fence");
        let body = answer.body.unwrap();
        assert_eq!(body["transition"]["state"], "fenced");
        assert_eq!(body["transition"]["intent"]["operationId"], "op-1");
    }
    assert_eq!(voids(&node, "op-1"), 0);
    assert_eq!(fences(&node, "op-1"), 1);
    // The same operation with another plan is a conflict, never a void.
    let mut other = void_body();
    other["planHash"] = json!("b".repeat(64));
    assert_eq!(
        void(node.clone(), request(&id, Some("op-1"), USER, other))
            .await
            .unwrap_err()
            .status,
        409
    );
    assert_eq!(voids(&node, "op-1"), 0);
    // The fence is untouched: still blocking, still cancellable the usual way.
    assert_eq!(
        require_open(&node.db.lock(), &id).unwrap_err().code,
        "environment_transition_pending"
    );
    node.close().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_void_and_a_create_racing_leave_exactly_one_winner() {
    // X4, both orders and truly concurrent: either the fence exists and the void
    // reports it, or the void exists and the create was refused.
    let (_dir, node) = node().await;
    let (mut created, mut voided) = (0, 0);
    for round in 0..40 {
        let op = format!("race-{round}");
        let (id, epoch, generation) = session(&node, &format!("race-{round}"));
        let gate = Arc::new(tokio::sync::Barrier::new(2));
        let create_task = || {
            let (node, id, op, gate) = (node.clone(), id.clone(), op.clone(), gate.clone());
            tokio::spawn(async move {
                gate.wait().await;
                create(
                    node,
                    request(&id, None, USER, create_body(&op, epoch, generation)),
                )
                .await
            })
        };
        let void_task = || {
            let (node, id, op, gate) = (node.clone(), id.clone(), op.clone(), gate.clone());
            tokio::spawn(async move {
                gate.wait().await;
                void(node, request(&id, Some(&op), USER, void_body())).await
            })
        };
        let (a, b) = if round % 2 == 0 {
            let a = create_task();
            (a, void_task())
        } else {
            let b = void_task();
            (create_task(), b)
        };
        let (made, answer) = (a.await.unwrap(), b.await.unwrap().unwrap());
        match result(&answer).as_str() {
            "voided" => {
                voided += 1;
                assert_eq!(made.unwrap_err().code, "operation_voided");
                assert_eq!((fences(&node, &op), voids(&node, &op)), (0, 1));
                require_open(&node.db.lock(), &id).unwrap();
            }
            "fence" => {
                created += 1;
                assert!(made.is_ok());
                assert_eq!((fences(&node, &op), voids(&node, &op)), (1, 0));
            }
            other => panic!("unexpected void result {other}"),
        }
        assert!(
            node.db.lock().is_autocommit(),
            "no transaction is left open"
        );
    }
    assert_eq!(created + voided, 40);
    node.close().await;
}

#[tokio::test]
async fn a_lost_void_reply_is_answered_the_same_when_sent_again() {
    // X10.
    let (_dir, node) = node().await;
    let (id, _epoch, _generation) = session(&node, "one");
    for _ in 0..3 {
        let answer = void(node.clone(), request(&id, Some("op-1"), USER, void_body()))
            .await
            .unwrap();
        assert_eq!(result(&answer), "voided");
    }
    assert_eq!(voids(&node, "op-1"), 1);
    // It also works through the router, which is what the Gateway uses.
    let routed = node
        .router
        .handle(
            &node,
            pirc_protocol::NodeHttpRequest {
                method: pirc_protocol::HttpMethod::Post,
                url: format!("/api/sessions/{id}/execution-fences/op-1/void"),
                user: USER.into(),
                payload: Some(void_body()),
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
async fn a_void_survives_a_node_restart_and_a_delayed_create_is_still_refused() {
    // X9.
    let (dir, node) = node().await;
    let (id, epoch, generation) = session(&node, "one");
    void(node.clone(), request(&id, Some("op-1"), USER, void_body()))
        .await
        .unwrap();
    node.close().await;
    drop(node);

    let node = start_workspace_node(dir.path(), false).await;
    assert_eq!(voids(&node, "op-1"), 1);
    // The lease died with the old process; the void is checked before it.
    let late = create(
        node.clone(),
        request(&id, None, USER, create_body("op-1", epoch, generation)),
    )
    .await
    .unwrap_err();
    assert_eq!((late.status, late.code.as_ref()), (409, "operation_voided"));
    assert_eq!(fences(&node, "op-1"), 0);
    let again = void(node.clone(), request(&id, Some("op-1"), USER, void_body()))
        .await
        .unwrap();
    assert_eq!(result(&again), "voided");
    node.close().await;
}

#[tokio::test]
async fn a_void_is_bound_to_its_owner_session_and_plan() {
    let (_dir, node) = node().await;
    let (id, epoch, generation) = session(&node, "one");
    let (other, _, _) = session(&node, "two");
    // Another user cannot void (or probe) this session.
    let denied = void(
        node.clone(),
        request(&id, Some("op-1"), "intruder", void_body()),
    )
    .await
    .unwrap_err();
    assert_eq!(denied.status, 403);
    assert_eq!(voids(&node, "op-1"), 0);
    // A session that does not exist is not found, and records nothing.
    assert_eq!(
        void(
            node.clone(),
            request("missing", Some("op-1"), USER, void_body())
        )
        .await
        .unwrap_err()
        .status,
        404
    );
    assert_eq!(voids(&node, "op-1"), 0);
    // Malformed identities and bodies are invalid input.
    for bad in [
        json!({"planHash":"nope"}),
        json!({"planHash":"A".repeat(64)}),
        json!({}),
        json!({"planHash":PLAN.repeat(64),"extra":1}),
    ] {
        assert_eq!(
            void(node.clone(), request(&id, Some("op-1"), USER, bad))
                .await
                .unwrap_err()
                .status,
            400
        );
    }
    assert_eq!(
        void(
            node.clone(),
            request(&id, Some("bad id"), USER, void_body())
        )
        .await
        .unwrap_err()
        .status,
        400
    );
    // The owner's void is bound to that session and that plan.
    void(node.clone(), request(&id, Some("op-1"), USER, void_body()))
        .await
        .unwrap();
    assert_eq!(
        void(
            node.clone(),
            request(&other, Some("op-1"), USER, void_body())
        )
        .await
        .unwrap_err()
        .status,
        409
    );
    let mut changed = void_body();
    changed["planHash"] = json!("b".repeat(64));
    assert_eq!(
        void(node.clone(), request(&id, Some("op-1"), USER, changed))
            .await
            .unwrap_err()
            .status,
        409
    );
    // The voided operation cannot be created on the other session either.
    let late = create(
        node.clone(),
        request(&other, None, USER, create_body("op-1", epoch, generation)),
    )
    .await
    .unwrap_err();
    assert_eq!(late.code, "operation_voided");
    assert_eq!(voids(&node, "op-1"), 1);
    // Another user's identical operation id is a different identity.
    assert_eq!(fences(&node, "op-1"), 0);
    node.close().await;
}

#[tokio::test]
async fn the_store_itself_keeps_fence_and_void_mutually_exclusive_and_final() {
    let (_dir, node) = node().await;
    let (id, epoch, generation) = session(&node, "one");
    void(node.clone(), request(&id, Some("op-1"), USER, void_body()))
        .await
        .unwrap();
    create(
        node.clone(),
        request(&id, None, USER, create_body("op-2", epoch, generation)),
    )
    .await
    .unwrap();
    {
        let db = node.db.lock();
        // Whatever path inserts it, a voided operation cannot become a fence.
        let error = db
            .execute(
                "INSERT INTO execution_fences(owner_user,operation_id,session_id,intent_json,state,created_at,updated_at) VALUES(?1,'op-1',?2,'{}','fenced',1,1)",
                params![USER, id],
            )
            .unwrap_err();
        assert!(error.to_string().contains("operation_voided"), "{error}");
        // A created fence cannot be voided by a direct write either.
        assert!(db
            .execute(
                "INSERT INTO execution_fence_voids(owner_user,operation_id,session_id,plan_hash,created_at) VALUES(?1,'op-2',?2,?3,1)",
                params![USER, id, PLAN.repeat(64)],
            )
            .is_err());
        // A void is neither updated nor removed, even with its session deleted.
        assert!(
            db.execute("UPDATE execution_fence_voids SET plan_hash='x'", [])
                .is_err()
        );
        assert!(db.execute("DELETE FROM execution_fence_voids", []).is_err());
    }
    // It outlives the session it was written for.
    {
        let db = node.db.lock();
        db.begin_session_deletion(&id, USER).unwrap();
        db.finish_session_deletion(&id).unwrap();
    }
    assert_eq!(voids(&node, "op-1"), 1);
    node.close().await;
}

#[tokio::test]
async fn the_fence_transaction_leaves_no_open_transaction_and_rolls_back_on_failure() {
    let (_dir, node) = node().await;
    let (id, epoch, generation) = session(&node, "one");
    node.db
        .lock()
        .execute_batch("CREATE TRIGGER fail_fence BEFORE INSERT ON execution_fences BEGIN SELECT RAISE(ABORT,'disk full'); END;")
        .unwrap();
    assert!(
        create(
            node.clone(),
            request(&id, None, USER, create_body("op-1", epoch, generation)),
        )
        .await
        .is_err()
    );
    assert!(node.db.lock().is_autocommit());
    assert_eq!(fences(&node, "op-1"), 0);
    node.db
        .lock()
        .execute_batch("DROP TRIGGER fail_fence")
        .unwrap();
    // The failed attempt did not void or fence anything: it can still succeed.
    create(
        node.clone(),
        request(&id, None, USER, create_body("op-1", epoch, generation)),
    )
    .await
    .unwrap();
    assert!(node.db.lock().is_autocommit());
    assert_eq!(fences(&node, "op-1"), 1);
    node.close().await;
}

#[tokio::test]
async fn the_node_advertises_the_void_operation() {
    let (_dir, node) = node().await;
    let caps = capabilities(node.clone(), request("", None, USER, json!({})))
        .await
        .unwrap()
        .body
        .unwrap();
    assert_eq!(caps["transitionVoidVersion"], 1);
    assert_eq!(caps["transitionReleaseVersion"], 1);
    node.close().await;
}
