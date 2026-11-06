use super::*;
use crate::{
    services::Services,
    store::{Db, Store},
    workspace_memory::tests::Fixture,
};

fn root(f: &Fixture) -> std::path::PathBuf {
    f.node
        .db
        .lock()
        .get_workspace("repo")
        .unwrap()
        .canonical_path
        .into()
}
#[tokio::test]
async fn unavailable_isolation_is_retained_without_any_host_launch_or_retry() {
    let f = Fixture::new().await;
    let root = root(&f);
    let lease = f
        .node
        .db
        .lock()
        .acquire_lease(&f.current, "phone", true, 60_000)
        .unwrap();
    for expected in [201, 200] {
        let response = create(
            &f.node,
            "alice",
            &f.current,
            &root,
            "unsupported",
            ("phone", lease.generation),
            (None, None),
        )
        .await
        .unwrap();
        assert_eq!(response.status, expected);
        let body = response.body.unwrap();
        assert_eq!(body["workRequest"]["state"], "not_started");
        assert_eq!(
            body["workRequest"]["errorCode"],
            "isolated_terminal_unavailable"
        );
        assert!(body["terminal"].is_null());
    }
    {
        let db = f.node.db.lock();
        assert_eq!(
            db.query_row("SELECT count(*) FROM terminal_runs", [], |r| r
                .get::<_, i64>(0))
                .unwrap(),
            0
        );
        assert!(
            db.execute("DELETE FROM terminal_work_requests", [])
                .is_err()
        );
        assert!(
            db.execute(
                "UPDATE terminal_work_requests SET intent_hash=?1",
                ["b".repeat(64)]
            )
            .is_err()
        );
    }
    assert!(status(&f.node, "mallory", &f.current, "unsupported").is_err());
    f.node.close().await;
}
#[tokio::test]
async fn interrupted_preparation_survives_restart_as_unknown_without_replay() {
    let f = Fixture::new().await;
    let root = root(&f);
    let lease = f
        .node
        .db
        .lock()
        .acquire_lease(&f.current, "phone", true, 60_000)
        .unwrap();
    {
        // Model the committed admission before the worker can be scheduled.
        let db = f.node.db.lock();
        db.execute("INSERT INTO terminal_work_requests VALUES('alice',?1,'before-worker',?2,'repo',0,?3,?4,'accepted',NULL,NULL,NULL,1)",params![f.current,f.node.incarnation,root.to_string_lossy(),"a".repeat(64)]).unwrap();
    }
    f.node.close().await;
    let restarted = Services::start(f.node.config.clone(), f.node.env.clone())
        .await
        .unwrap();
    // This fixture installs its directory mode in memory, outside config files.
    restarted.modes.write().unwrap().insert(
        crate::store::ModeId::new("directory").unwrap(),
        f.mode.clone(),
    );
    let result = status(&restarted, "alice", &f.current, "before-worker").unwrap();
    assert_eq!(result["workRequest"]["state"], "outcome_unknown");
    assert!(result["terminal"].is_null());
    let new_lease = restarted
        .db
        .lock()
        .acquire_lease(&f.current, "phone", true, 60_000)
        .unwrap();
    assert!(new_lease.generation >= lease.generation);
    assert_eq!(
        create(
            &restarted,
            "alice",
            &f.current,
            &root,
            "before-worker",
            ("phone", new_lease.generation),
            (None, None)
        )
        .await
        .unwrap_err()
        .code,
        "work_terminal_request_conflict"
    );
    assert!(restarted.terminals.list(&f.current).is_empty());
    restarted.close().await;
}
#[test]
fn upgrade_keeps_legacy_scopes_without_inventing_request_ids() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("node.sqlite");
    {
        let db = Db::open(&file).unwrap();
        let db = db.lock();
        db.execute("INSERT INTO terminal_runs VALUES('legacy','session','repo','/repo','old','unconfirmed',1,1)",[]).unwrap();
        db.execute_batch(include_str!("../remove_requests.sql"))
            .unwrap();
        db.pragma_update(None, "user_version", 2027).unwrap();
    }
    let db = Db::open(&file).unwrap();
    let db = db.lock();
    assert_eq!(
        db.query_row("SELECT count(*) FROM terminal_work_requests", [], |r| r
            .get::<_, i64>(0))
            .unwrap(),
        0
    );
    assert_eq!(
        db.query_row(
            "SELECT state FROM terminal_runs WHERE id='legacy'",
            [],
            |r| r.get::<_, String>(0)
        )
        .unwrap(),
        "unconfirmed"
    );
}

#[test]
fn a_work_request_cannot_claim_an_agent_launch_as_its_terminal_scope() {
    let db = Db::memory();
    let db = db.lock();
    db.execute("INSERT INTO terminal_work_requests VALUES('alice','session','work','node','repo',0,'/repo',?1,'accepted',NULL,NULL,NULL,1)",["a".repeat(64)]).unwrap();
    let wrong = crate::store::atomic(&db, |db| {
        db.execute("INSERT INTO sandbox_launches VALUES('agent','session','repo',0,'node','launching',NULL,1,1,'waiting','agent')",[])?;
        db.execute("INSERT INTO terminal_runs VALUES('agent','session','repo','/repo','node','launching',1,1)",[])?;
        db.execute(
            "UPDATE terminal_work_requests SET run_id='agent',terminal_id='1234abcd'",
            [],
        )?;
        Ok(())
    });
    assert!(wrong.is_err());
    assert_eq!(
        db.query_row("SELECT count(*) FROM sandbox_launches", [], |r| r
            .get::<_, i64>(0))
            .unwrap(),
        0
    );
    assert!(
        db.query_row("SELECT run_id FROM terminal_work_requests", [], |r| r
            .get::<_, Option<String>>(0))
            .unwrap()
            .is_none()
    );
}

#[tokio::test]
async fn a_request_id_without_an_explicit_work_mode_never_opens_a_legacy_host_terminal() {
    use pirc_protocol::{HttpMethod, NodeHttpRequest};
    let f = Fixture::new().await;
    let lease = f
        .node
        .db
        .lock()
        .acquire_lease(&f.current, "phone", true, 60_000)
        .unwrap();
    let router = crate::router::Router::new(crate::panels::routes());
    let response=router.handle(&f.node,NodeHttpRequest{method:HttpMethod::Post,url:format!("/api/sessions/{}/terminals",f.current),user:"alice".into(),payload:Some(json!({"requestId":"work-only","clientId":"phone","generation":lease.generation})),body_base64:None,content_type:None}).await;
    let launches = f
        .node
        .db
        .lock()
        .query_row("SELECT count(*) FROM terminal_runs", [], |r| {
            r.get::<_, i64>(0)
        })
        .unwrap();
    f.node.close().await;
    assert_eq!(response.status, 400);
    assert_eq!(launches, 0);
}

#[tokio::test]
async fn unresolved_preparations_hold_existing_terminal_quota_before_new_workers() {
    let f = Fixture::new().await;
    let root = root(&f);
    let lease = f
        .node
        .db
        .lock()
        .acquire_lease(&f.current, "phone", true, 60_000)
        .unwrap();
    {
        let db = f.node.db.lock();
        for n in 0..PER_SESSION {
            db.execute("INSERT INTO terminal_work_requests VALUES('alice',?1,?2,?3,'repo',0,?4,?5,'accepted',NULL,NULL,NULL,1)",params![f.current,format!("pending-{n}"),f.node.incarnation,root.to_string_lossy(),"a".repeat(64)]).unwrap();
        }
    }
    let result = create(
        &f.node,
        "alice",
        &f.current,
        &root,
        "fifth-request",
        ("phone", lease.generation),
        (None, None),
    )
    .await;
    assert_eq!(result.unwrap_err().code, "conflict");
    assert!(
        saved(&f.node.db.lock(), "alice", &f.current, "fifth-request")
            .unwrap()
            .is_none()
    );
    assert!(f.node.terminals.list(&f.current).is_empty());
    f.node.close().await;
}

#[tokio::test]
async fn capability_reads_are_owned_non_mutating_and_reject_ambiguous_query_kinds() {
    use pirc_protocol::{HttpMethod, NodeHttpRequest};
    let f = Fixture::new().await;
    let router = crate::router::Router::new(crate::panels::routes());
    for (user, query, status) in [
        ("alice", "capabilities=1", 200),
        ("alice", "capabilities=0", 400),
        ("alice", "capabilities=1&workRequestId=a", 400),
        ("alice", "workRequestId=a&hostRequestId=b", 400),
        ("alice", "capabilities=1&capabilities=1", 400),
        ("mallory", "capabilities=1", 403),
    ] {
        let response = router
            .handle(
                &f.node,
                NodeHttpRequest {
                    method: HttpMethod::Get,
                    url: format!("/api/sessions/{}/terminals?{query}", f.current),
                    user: user.into(),
                    payload: None,
                    body_base64: None,
                    content_type: None,
                },
            )
            .await;
        assert_eq!(response.status, status, "{query}: {response:?}");
        if status == 200 {
            assert_eq!(
                response.body.unwrap()["terminalCapabilities"]["workTerminalRequestVersion"],
                1
            )
        }
    }
    assert_eq!(
        f.node
            .db
            .lock()
            .query_row("SELECT count(*) FROM terminal_work_requests", [], |r| r
                .get::<_, i64>(0))
            .unwrap(),
        0
    );
    f.node.close().await;
}
