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
        db.execute("INSERT INTO terminal_work_requests(owner_user,session_id,request_id,incarnation,workspace_id,runner_epoch,cwd,intent_hash,state,error_code,run_id,terminal_id,created_at) VALUES('alice',?1,'before-worker',?2,'repo',0,?3,?4,'accepted',NULL,NULL,NULL,1)",params![f.current,f.node.incarnation,root.to_string_lossy(),"a".repeat(64)]).unwrap();
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
fn a_work_request_cannot_claim_an_agent_launch_as_its_terminal_scope() {
    let db = Db::memory();
    let db = db.lock();
    db.execute("INSERT INTO terminal_work_requests(owner_user,session_id,request_id,incarnation,workspace_id,runner_epoch,cwd,intent_hash,state,error_code,run_id,terminal_id,created_at) VALUES('alice','session','work','node','repo',0,'/repo',?1,'accepted',NULL,NULL,NULL,1)",["a".repeat(64)]).unwrap();
    let wrong = crate::store::atomic(&db, |db| {
        db.execute("INSERT INTO sandbox_launches(launch_id,session_id,workspace_id,runner_epoch,incarnation,state,identity_json,created_at,updated_at,guard_state,resource_kind) VALUES('agent','session','repo',0,'node','launching',NULL,1,1,'waiting','agent')",[])?;
        db.execute("INSERT INTO terminal_runs(id,session_id,workspace_id,cwd,incarnation,state,created_at,updated_at) VALUES('agent','session','repo','/repo','node','launching',1,1)",[])?;
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
            db.execute("INSERT INTO terminal_work_requests(owner_user,session_id,request_id,incarnation,workspace_id,runner_epoch,cwd,intent_hash,state,error_code,run_id,terminal_id,created_at) VALUES('alice',?1,?2,?3,'repo',0,?4,?5,'accepted',NULL,NULL,NULL,1)",params![f.current,format!("pending-{n}"),f.node.incarnation,root.to_string_lossy(),"a".repeat(64)]).unwrap();
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
    assert_eq!(result.unwrap_err().code, "terminal_capacity");
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
        ("alice", "unresolvedRequests=1", 200),
        (
            "alice",
            "unresolvedRequests=1&limit=100&after=1.work.a",
            200,
        ),
        ("alice", "unresolvedRequests=0", 400),
        ("alice", "unresolvedRequests=1&capabilities=1", 400),
        ("alice", "unresolvedRequests=1&hostRequestId=a", 400),
        ("alice", "unresolvedRequests=1&limit=0", 400),
        ("alice", "unresolvedRequests=1&limit=101", 400),
        ("alice", "unresolvedRequests=1&after=1.peer.a", 400),
        ("alice", "unresolvedRequests=1&after=x.work.a", 400),
        ("alice", "limit=5", 400),
        ("alice", "workRequestId=a&after=1.work.a", 400),
        ("mallory", "unresolvedRequests=1", 403),
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
        if status == 200 && query.starts_with("capabilities") {
            assert_eq!(
                response.body.unwrap()["terminalCapabilities"]["workTerminalRequestVersion"],
                3
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

#[tokio::test]
async fn unresolved_requests_list_only_open_decisions_in_stable_pages() {
    let f = Fixture::new().await;
    let root = root(&f);
    {
        let db = f.node.db.lock();
        let work = |request: &str, incarnation: &str, state: &str, at: i64, session: &str| {
            db.execute("INSERT INTO terminal_work_requests(owner_user,session_id,request_id,incarnation,workspace_id,runner_epoch,cwd,intent_hash,state,error_code,run_id,terminal_id,created_at) VALUES('alice',?1,?2,?3,'repo',0,?4,?5,?6,NULL,NULL,NULL,?7)",params![session,request,incarnation,root.to_string_lossy(),"a".repeat(64),state,at]).unwrap();
        };
        work(
            "w-preparing",
            &f.node.incarnation,
            "accepted",
            10,
            &f.current,
        );
        work("w-unknown", "old-node", "accepted", 20, &f.current);
        work(
            "w-failed",
            &f.node.incarnation,
            "not_started",
            30,
            &f.current,
        );
        work(
            "w-other-session",
            &f.node.incarnation,
            "accepted",
            11,
            "other-session",
        );
        let host = |request: &str, incarnation: &str, at: i64, expires: i64| {
            db.execute("INSERT INTO terminal_host_requests(id,owner_user,session_id,request_id,incarnation,intent_hash,review_json,created_at,expires_at) VALUES(?1,'alice',?2,?1,?3,?4,'{}',?5,?6)",params![request,f.current,incarnation,"b".repeat(64),at,expires]).unwrap();
        };
        host("h-review", &f.node.incarnation, 15, i64::MAX);
        host("h-expired", &f.node.incarnation, 25, 1);
        host("h-stale", "old-node", 35, i64::MAX);
    }
    let all = unresolved(&f.node, "alice", &f.current, None, None).unwrap();
    let items = all["terminalRequests"]["items"].as_array().unwrap();
    let states: Vec<_> = items
        .iter()
        .map(|item| {
            let result = item
                .get("workRequest")
                .unwrap_or_else(|| &item["hostManagement"]);
            (
                result["requestId"].as_str().unwrap(),
                result["state"].as_str().unwrap(),
            )
        })
        .collect();
    assert_eq!(
        states,
        [
            ("w-preparing", "preparing"),
            ("h-review", "review"),
            ("w-unknown", "outcome_unknown")
        ]
    );
    assert!(all["terminalRequests"]["next"].is_null());
    let mut after: Option<String> = None;
    let mut paged = Vec::new();
    for _ in 0..5 {
        let page = unresolved(&f.node, "alice", &f.current, after.as_deref(), Some("1")).unwrap();
        for item in page["terminalRequests"]["items"].as_array().unwrap() {
            paged.push(item.clone());
        }
        match page["terminalRequests"]["next"].as_str() {
            Some(next) => after = Some(next.into()),
            None => break,
        }
    }
    assert_eq!(&paged, items);
    assert!(unresolved(&f.node, "mallory", &f.current, None, None).is_err());
    // Reading creates, consumes or changes nothing.
    assert_eq!(
        f.node
            .db
            .lock()
            .query_row("SELECT count(*) FROM terminal_runs", [], |r| r
                .get::<_, i64>(0))
            .unwrap(),
        0
    );
    f.node.close().await;
}

#[tokio::test]
async fn acknowledged_unknowns_leave_discovery_but_keep_their_outcome() {
    let f = Fixture::new().await;
    let root = root(&f);
    {
        let db = f.node.db.lock();
        let work = |request: &str, incarnation: &str, state: &str, at: i64| {
            db.execute("INSERT INTO terminal_work_requests(owner_user,session_id,request_id,incarnation,workspace_id,runner_epoch,cwd,intent_hash,state,created_at) VALUES('alice',?1,?2,?3,'repo',0,?4,?5,?6,?7)",params![f.current,request,incarnation,root.to_string_lossy(),"a".repeat(64),state,at]).unwrap();
        };
        work("w-preparing", &f.node.incarnation, "accepted", 10);
        work("w-unknown", "old-node", "accepted", 20);
        work("w-failed", &f.node.incarnation, "not_started", 30);
        db.execute(
            "INSERT INTO terminal_runs(id,session_id,workspace_id,cwd,incarnation,state,created_at,updated_at) VALUES('run-h',?1,'repo',?2,'old-node','launching',1,1)",
            params![f.current, root.to_string_lossy()],
        )
        .unwrap();
        let host = |request: &str, incarnation: &str, at: i64, run: Option<&str>| {
            db.execute("INSERT INTO terminal_host_requests(id,owner_user,session_id,request_id,incarnation,intent_hash,review_json,created_at,expires_at,run_id,terminal_id) VALUES(?1,'alice',?2,?1,?3,?4,'{}',?5,?6,?7,?8)",params![request,f.current,incarnation,"b".repeat(64),at,i64::MAX,run,run.map(|_|"t-host")]).unwrap();
        };
        host("h-review", &f.node.incarnation, 15, None);
        host("h-unknown", "old-node", 25, Some("run-h"));
    }
    let listed = |f: &Fixture| -> Vec<String> {
        unresolved(&f.node, "alice", &f.current, None, None).unwrap()["terminalRequests"]["items"]
            .as_array()
            .unwrap()
            .iter()
            .map(|item| {
                item.get("workRequest")
                    .unwrap_or_else(|| &item["hostManagement"])["requestId"]
                    .as_str()
                    .unwrap()
                    .to_owned()
            })
            .collect()
    };
    assert_eq!(
        listed(&f),
        ["w-preparing", "h-review", "w-unknown", "h-unknown"]
    );
    // Only an unconfirmed start can be acknowledged.
    for (host, request) in [
        (false, "w-preparing"),
        (false, "w-failed"),
        (true, "h-review"),
    ] {
        let refused = acknowledge(&f.node, "alice", &f.current, host, request, "phone");
        assert_eq!(
            refused.unwrap_err().code,
            "terminal_request_not_unknown",
            "{request}"
        );
    }
    let missing = acknowledge(&f.node, "alice", &f.current, false, "never-sent", "phone");
    assert_eq!(missing.unwrap_err().code, "terminal_request_not_found");
    assert!(acknowledge(&f.node, "mallory", &f.current, false, "w-unknown", "phone").is_err());
    let first = acknowledge(&f.node, "alice", &f.current, false, "w-unknown", "phone").unwrap();
    assert_eq!(first["workRequest"]["state"], "outcome_unknown");
    assert!(first["workRequest"]["acknowledgedAt"].is_i64());
    let again = acknowledge(&f.node, "alice", &f.current, false, "w-unknown", "tablet").unwrap();
    assert_eq!(again, first);
    let host = acknowledge(&f.node, "alice", &f.current, true, "h-unknown", "phone").unwrap();
    assert_eq!(host["hostManagement"]["state"], "outcome_unknown");
    assert!(host["hostManagement"]["acknowledgedAt"].is_i64());
    assert_eq!(listed(&f), ["w-preparing", "h-review"]);
    // The outcome and the run evidence are unchanged; the decision is retained.
    assert_eq!(
        status(&f.node, "alice", &f.current, "w-unknown").unwrap()["workRequest"]["state"],
        "outcome_unknown"
    );
    {
        let db = f.node.db.lock();
        let run: String = db
            .query_row(
                "SELECT state FROM terminal_runs WHERE id='run-h'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(run, "launching");
        let by: String = db
            .query_row(
                "SELECT acknowledged_by FROM terminal_work_requests WHERE request_id='w-unknown'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(by, "phone");
        for sql in [
            "UPDATE terminal_work_requests SET acknowledged_at=1,acknowledged_by='x' WHERE request_id='w-unknown'",
            "UPDATE terminal_work_requests SET acknowledged_at=1,acknowledged_by='x' WHERE request_id='w-failed'",
            "UPDATE terminal_host_requests SET acknowledged_at=1,acknowledged_by='x' WHERE request_id='h-review'",
        ] {
            assert!(db.execute(sql, []).is_err(), "{sql}");
        }
    }
    let missing = status(&f.node, "alice", &f.current, "never-sent").unwrap_err();
    assert_eq!(missing.code, "terminal_request_not_found");
    let missing =
        super::super::host::status(&f.node, "alice", &f.current, "never-sent").unwrap_err();
    assert_eq!(missing.code, "terminal_request_not_found");
    f.node.close().await;
}

#[tokio::test]
async fn acknowledgement_route_needs_control_and_one_explicit_request() {
    use pirc_protocol::{HttpMethod, NodeHttpRequest};
    let f = Fixture::new().await;
    let lease = f
        .node
        .db
        .lock()
        .acquire_lease(&f.current, "phone", true, 60_000)
        .unwrap();
    let router = crate::router::Router::new(crate::panels::routes());
    let g = lease.generation;
    for (payload, status) in [
        (
            json!({"action":"acknowledge","clientId":"phone","generation":g,"workRequestId":"none"}),
            404,
        ),
        (
            json!({"action":"acknowledge","clientId":"phone","generation":g}),
            400,
        ),
        (
            json!({"action":"acknowledge","clientId":"phone","generation":g,"workRequestId":"a","hostRequestId":"b"}),
            400,
        ),
        (
            json!({"action":"acknowledge","clientId":"phone","generation":g,"workRequestId":"a","executionPath":"isolated_work"}),
            400,
        ),
        (
            json!({"action":"acknowledge","clientId":"tablet","generation":g,"workRequestId":"none"}),
            409,
        ),
    ] {
        let response = router
            .handle(
                &f.node,
                NodeHttpRequest {
                    method: HttpMethod::Post,
                    url: format!("/api/sessions/{}/terminals", f.current),
                    user: "alice".into(),
                    payload: Some(payload.clone()),
                    body_base64: None,
                    content_type: None,
                },
            )
            .await;
        assert_eq!(response.status, status, "{payload}: {response:?}");
    }
    f.node.close().await;
}
