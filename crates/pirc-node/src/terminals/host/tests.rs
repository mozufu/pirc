use super::*;
use crate::{
    services::Services,
    store::{Db, Store},
    workspace_memory::tests::Fixture,
};

struct Input {
    root: std::path::PathBuf,
    generation: i64,
    body: Value,
}
fn input(f: &Fixture, request: &str) -> Input {
    let db = f.node.db.lock();
    let root = db.get_workspace("repo").unwrap().canonical_path.into();
    let generation = db
        .acquire_lease(&f.current, "phone", true, 60_000)
        .unwrap()
        .generation;
    Input {
        root,
        generation,
        body: json!({"requestId":request,"action":"review","executionPath":"host_management"}),
    }
}
fn call(f: &Fixture, i: &Input) -> ApiResult<Response> {
    handle(
        &f.node,
        "alice",
        &f.current,
        &i.root,
        &i.body,
        ("phone", i.generation),
        (None, None),
    )
}
fn prepare(f: &Fixture, i: &mut Input) -> Value {
    let reviewed = call(f, i).unwrap().body.unwrap();
    i.body["action"] = json!("confirm");
    i.body["confirmed"] = json!(true);
    i.body["reviewId"] = reviewed["hostManagement"]["id"].clone();
    i.body["reviewHash"] = reviewed["hostManagement"]["reviewHash"].clone();
    reviewed
}
fn count(node: &Node, table: &str) -> i64 {
    node.db
        .lock()
        .query_row(&format!("SELECT count(*) FROM {table}"), [], |r| r.get(0))
        .unwrap()
}

#[tokio::test]
async fn review_is_not_authority_and_only_one_confirmed_terminal_is_created() {
    let f = Fixture::new().await;
    let mut i = input(&f, "review-once");
    let reviewed = prepare(&f, &mut i);
    assert_eq!(reviewed["hostManagement"]["state"], "review");
    assert_eq!(count(&f.node, "terminal_runs"), 0);
    assert!(!reviewed.to_string().contains(f.dir.to_str().unwrap()));
    let opened = call(&f, &i).unwrap();
    assert_eq!(opened.status, 201);
    let opened = opened.body.unwrap();
    assert_eq!(opened["terminal"]["executionPath"], "host_management");
    let retried = call(&f, &i).unwrap();
    assert_eq!(retried.status, 200);
    assert_eq!(
        retried.body.unwrap()["terminal"]["id"],
        opened["terminal"]["id"]
    );
    assert_eq!(count(&f.node, "terminal_runs"), 1);
    let id = opened["terminal"]["id"].as_str().unwrap();
    // Presentation metadata cannot manufacture a scoped closure acknowledgement.
    f.node
        .terminals
        .lookup(&f.current, id)
        .unwrap()
        .state()
        .info
        .execution_path = Some("isolated_work".into());
    f.node.terminals.close(&f.current, id).unwrap();
    f.node.terminals.stop_live(&f.current).await.unwrap();
    assert!(f.node.terminals.require_settled(&f.current).is_err());
    assert_eq!(
        status(&f.node, "alice", &f.current, "review-once").unwrap()["hostManagement"]["state"],
        "unconfirmed"
    );
    {
        let db = f.node.db.lock();
        assert!(
            db.execute(
                "UPDATE terminal_host_requests SET run_id=NULL,terminal_id=NULL",
                []
            )
            .is_err()
        );
        assert!(
            db.execute(
                "UPDATE terminal_host_requests SET intent_hash=?1",
                ["b".repeat(64)]
            )
            .is_err()
        );
        assert!(
            db.execute("DELETE FROM terminal_host_requests", [])
                .is_err()
        );
    }
    {
        let db = f.node.db.lock();
        crate::execution_fences::accept(
            &db,
            "alice",
            &f.current,
            &crate::execution_fences::Intent {
                operation_id: "stop-host-source".into(),
                plan_hash: "a".repeat(64),
                expected_workspace_id: "repo".into(),
                expected_runner_epoch: 0,
                preflight: None,
            },
            "phone",
            i.generation,
        )
        .unwrap();
    }
    let receipt = crate::execution_fences::drain(&f.node, "alice", &f.current, "stop-host-source")
        .await
        .unwrap();
    assert_eq!(receipt.state, "blocked");
    assert_eq!(
        receipt.error_code.as_deref(),
        Some("terminal_stop_unconfirmed")
    );
    assert!(!receipt.revocation_confirmed && !receipt.target_installed);
    f.node.close().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn concurrent_confirmation_returns_one_durable_execution() {
    let f = Fixture::new().await;
    let mut i = input(&f, "parallel");
    prepare(&f, &mut i);
    let mut jobs = Vec::new();
    for _ in 0..8 {
        let node = f.node.clone();
        let session = f.current.clone();
        let root = i.root.clone();
        let body = i.body.clone();
        let generation = i.generation;
        jobs.push(tokio::spawn(async move {
            handle(
                &node,
                "alice",
                &session,
                &root,
                &body,
                ("phone", generation),
                (None, None),
            )
        }));
    }
    let mut ids = std::collections::HashSet::new();
    for job in jobs {
        let response = job.await.unwrap().unwrap();
        ids.insert(
            response.body.unwrap()["hostManagement"]["terminalId"]
                .clone()
                .to_string(),
        );
    }
    assert_eq!(ids.len(), 1);
    assert_eq!(count(&f.node, "terminal_runs"), 1);
    assert_eq!(f.node.terminals.list(&f.current).len(), 1);
    f.node.close().await;
}

#[tokio::test]
async fn changed_confirmation_control_environment_and_foreign_owner_never_launch() {
    for changed in [
        "hash", "id", "declined", "size", "takeover", "mode", "epoch", "fence", "foreign",
    ] {
        let f = Fixture::new().await;
        let mut i = input(&f, changed);
        prepare(&f, &mut i);
        match changed {
            "hash" => i.body["reviewHash"] = json!("a".repeat(64)),
            "id" => i.body["reviewId"] = json!("invented"),
            "declined" => i.body["confirmed"] = json!(false),
            "takeover" => {
                f.node
                    .db
                    .lock()
                    .acquire_lease(&f.current, "web", true, 60_000)
                    .unwrap();
            }
            "mode" => {
                f.node
                    .modes
                    .write()
                    .unwrap()
                    .get_mut(&crate::store::ModeId::new("directory").unwrap())
                    .unwrap()
                    .body
                    .push_str(" changed rules");
            }
            "epoch" => {
                f.node.db.lock().increment_epoch(&f.current).unwrap();
            }
            "fence" => {
                let db = f.node.db.lock();
                crate::execution_fences::accept(
                    &db,
                    "alice",
                    &f.current,
                    &crate::execution_fences::Intent {
                        operation_id: "switch".into(),
                        plan_hash: "a".repeat(64),
                        expected_workspace_id: "repo".into(),
                        expected_runner_epoch: 0,
                        preflight: None,
                    },
                    "phone",
                    i.generation,
                )
                .unwrap();
            }
            _ => {}
        }
        let result = if changed == "size" {
            handle(
                &f.node,
                "alice",
                &f.current,
                &i.root,
                &i.body,
                ("phone", i.generation),
                (Some(100), None),
            )
        } else if changed == "foreign" {
            handle(
                &f.node,
                "mallory",
                &f.current,
                &i.root,
                &i.body,
                ("phone", i.generation),
                (None, None),
            )
        } else {
            call(&f, &i)
        };
        assert!(result.is_err(), "{changed}");
        assert_eq!(count(&f.node, "terminal_runs"), 0, "{changed}");
        assert!(f.node.terminals.list(&f.current).is_empty());
        f.node.close().await;
    }
}

#[tokio::test]
async fn failed_atomic_reservation_does_not_consume_a_review_or_launch() {
    for table in ["terminal_runs", "terminal_host_requests"] {
        let f = Fixture::new().await;
        let mut i = input(&f, table);
        prepare(&f, &mut i);
        let event = if table == "terminal_runs" {
            "INSERT"
        } else {
            "UPDATE OF run_id"
        };
        f.node.db.lock().execute_batch(&format!("CREATE TRIGGER fail_host_terminal BEFORE {event} ON {table} BEGIN SELECT RAISE(ABORT,'injected'); END;")).unwrap();
        assert!(call(&f, &i).is_err());
        assert_eq!(count(&f.node, "terminal_runs"), 0);
        assert!(f.node.terminals.list(&f.current).is_empty());
        assert_eq!(
            status(&f.node, "alice", &f.current, table).unwrap()["hostManagement"]["state"],
            "review"
        );
        f.node
            .db
            .lock()
            .execute_batch("DROP TRIGGER fail_host_terminal")
            .unwrap();
        assert_eq!(call(&f, &i).unwrap().status, 201);
        f.node.close().await;
    }
}

#[tokio::test]
async fn expired_or_restarted_review_cannot_grant_a_terminal() {
    let f = Fixture::new().await;
    let i = input(&f, "expired");
    {
        let db = f.node.db.lock();
        let grant = Grant {
            id: String::new(),
            owner: "alice".into(),
            request: "expired".into(),
            hash: String::new(),
            client: "phone".into(),
            generation: i.generation,
        };
        let (hash, details) = capture(&f.node, &db, &f.current, &i.root, &grant, (80, 24)).unwrap();
        insert(
            &db,
            &f.node,
            &grant,
            &f.current,
            &hash,
            &details,
            now_ms() - i64::try_from(f.node.config.interaction_ttl_ms).unwrap() - 1,
        )
        .unwrap();
    }
    let mut i = i;
    prepare(&f, &mut i);
    assert_eq!(
        status(&f.node, "alice", &f.current, "expired").unwrap()["hostManagement"]["state"],
        "expired"
    );
    assert!(call(&f, &i).is_err());
    let mut pending = input(&f, "restart-pending");
    prepare(&f, &mut pending);
    f.node.close().await;
    let restarted = Services::start(f.node.config.clone(), f.node.env.clone())
        .await
        .unwrap();
    assert_eq!(
        status(&restarted, "alice", &f.current, "restart-pending").unwrap()["hostManagement"]["state"],
        "stale"
    );
    let current = restarted
        .db
        .lock()
        .acquire_lease(&f.current, "phone", true, 60_000)
        .unwrap()
        .generation;
    assert!(
        handle(
            &restarted,
            "alice",
            &f.current,
            &pending.root,
            &pending.body,
            ("phone", current),
            (None, None)
        )
        .is_err()
    );
    assert_eq!(count(&restarted, "terminal_runs"), 0);
    restarted.close().await;
}

#[tokio::test]
async fn crash_after_consumption_never_replays_a_reserved_terminal() {
    let f = Fixture::new().await;
    let mut i = input(&f, "unknown-start");
    prepare(&f, &mut i);
    {
        let db = f.node.db.lock();
        let grant = Grant {
            id: i.body["reviewId"].as_str().unwrap().into(),
            hash: i.body["reviewHash"].as_str().unwrap().into(),
            owner: "alice".into(),
            request: "unknown-start".into(),
            client: "phone".into(),
            generation: i.generation,
        };
        let terminal = TerminalInfo {
            id: "aabbccdd".into(),
            execution_path: Some("host_management".into()),
            session_id: f.current.clone(),
            title: "sh".into(),
            cwd: i.root.to_string_lossy().into_owned(),
            cols: 80,
            rows: 24,
            created_at: now_ms(),
            exit_code: None,
            exited: false,
        };
        crate::store::atomic(&db, |db| {
            let record = journal::Record::reserve_atomic(&f.node, db, &f.current, "repo", &i.root)?;
            consume(db, &f.node, &grant, &terminal, &record)
        })
        .unwrap();
    }
    f.node.close().await;
    let restarted = Services::start(f.node.config.clone(), f.node.env.clone())
        .await
        .unwrap();
    let current = restarted
        .db
        .lock()
        .acquire_lease(&f.current, "phone", true, 60_000)
        .unwrap()
        .generation;
    for _ in 0..3 {
        let response = handle(
            &restarted,
            "alice",
            &f.current,
            &i.root,
            &i.body,
            ("phone", current),
            (None, None),
        )
        .unwrap()
        .body
        .unwrap();
        assert_eq!(response["hostManagement"]["state"], "outcome_unknown");
        assert!(response["terminal"].is_null());
        assert_eq!(response["hostManagement"]["terminalId"], "aabbccdd");
    }
    assert_eq!(count(&restarted, "terminal_runs"), 1);
    assert!(restarted.terminals.list(&f.current).is_empty());
    restarted.close().await;
}

#[test]
fn migration_does_not_convert_legacy_terminals_to_approved_host_management() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("node.sqlite");
    {
        let db = Db::open(&file).unwrap();
        let db = db.lock();
        db.execute("INSERT INTO terminal_runs VALUES('old','session','repo','/repo','old-node','unconfirmed',1,1)",[]).unwrap();
        db.execute_batch(include_str!("../remove_host.sql"))
            .unwrap();
        db.pragma_update(None, "user_version", 2026).unwrap();
    }
    let db = Db::open(&file).unwrap();
    let db = db.lock();
    assert_eq!(
        db.query_row("SELECT count(*) FROM terminal_host_requests", [], |r| r
            .get::<_, i64>(0))
            .unwrap(),
        0
    );
    assert_eq!(
        db.query_row("SELECT state FROM terminal_runs WHERE id='old'", [], |r| {
            r.get::<_, String>(0)
        })
        .unwrap(),
        "unconfirmed"
    );
}

#[tokio::test]
async fn panel_routes_refuse_mode_labels_without_review_and_read_results_without_a_lease() {
    use pirc_protocol::{HttpMethod, NodeHttpRequest};
    let f = Fixture::new().await;
    let i = input(&f, "route-review");
    let router = crate::router::Router::new(crate::panels::routes());
    let request = |method, url: String, payload| NodeHttpRequest {
        method,
        url,
        user: "alice".into(),
        payload,
        body_base64: None,
        content_type: None,
    };
    for extra in [
        json!({"executionPath":"host_management"}),
        json!({"action":"review"}),
        json!({"executionPath":"isolated_work","action":"confirm","confirmed":true}),
    ] {
        let mut body = json!({"clientId":"phone","generation":i.generation});
        body.as_object_mut()
            .unwrap()
            .extend(extra.as_object().unwrap().clone());
        let response = router
            .handle(
                &f.node,
                request(
                    HttpMethod::Post,
                    format!("/api/sessions/{}/terminals", f.current),
                    Some(body),
                ),
            )
            .await;
        assert_eq!(response.status, 400);
    }
    assert_eq!(count(&f.node, "terminal_runs"), 0);
    let mut body = i.body.clone();
    body["clientId"] = json!("phone");
    body["generation"] = json!(i.generation);
    let reviewed = router
        .handle(
            &f.node,
            request(
                HttpMethod::Post,
                format!("/api/sessions/{}/terminals", f.current),
                Some(body),
            ),
        )
        .await;
    assert_eq!(reviewed.status, 200);
    f.node
        .db
        .lock()
        .acquire_lease(&f.current, "web", true, 60_000)
        .unwrap();
    let queried = router
        .handle(
            &f.node,
            request(
                HttpMethod::Get,
                format!(
                    "/api/sessions/{}/terminals?hostRequestId=route-review",
                    f.current
                ),
                None,
            ),
        )
        .await;
    assert_eq!(queried.status, 200);
    assert_eq!(
        queried.body.unwrap()["hostManagement"]["id"],
        reviewed.body.unwrap()["hostManagement"]["id"]
    );
    f.node.close().await;
    let mut config = f.node.config.clone();
    config.terminals_enabled = false;
    let restarted = Services::start(config, f.node.env.clone()).await.unwrap();
    let queried = router
        .handle(
            &restarted,
            request(
                HttpMethod::Get,
                format!(
                    "/api/sessions/{}/terminals?hostRequestId=route-review",
                    f.current
                ),
                None,
            ),
        )
        .await;
    assert_eq!(queried.status, 200);
    assert_eq!(queried.body.unwrap()["hostManagement"]["state"], "stale");
    let ordinary = router
        .handle(
            &restarted,
            request(
                HttpMethod::Get,
                format!("/api/sessions/{}/terminals", f.current),
                None,
            ),
        )
        .await;
    assert_eq!(ordinary.status, 403);
    restarted.close().await;
}

#[tokio::test]
async fn database_refuses_consuming_a_review_with_a_peer_terminal_origin() {
    let f = Fixture::new().await;
    let mut i = input(&f, "peer-origin");
    prepare(&f, &mut i);
    {
        let db = f.node.db.lock();
        let peer = db.create_session("repo", "/peer", "alice").unwrap();
        let result = crate::store::atomic(&db, |db| {
            let record = journal::Record::reserve_atomic(&f.node, db, &peer.id, "repo", &i.root)?;
            db.execute(
                "UPDATE terminal_host_requests SET run_id=?1,terminal_id='abcdef12'",
                [record.0],
            )?;
            Ok(())
        });
        assert!(result.is_err());
    }
    assert_eq!(count(&f.node, "terminal_runs"), 0);
    assert_eq!(
        status(&f.node, "alice", &f.current, "peer-origin").unwrap()["hostManagement"]["state"],
        "review"
    );
    f.node.close().await;
}

#[tokio::test]
async fn known_spawn_failure_is_not_retried_with_the_consumed_review() {
    let f = Fixture::new().await;
    let mut i = input(&f, "spawn-failure");
    prepare(&f, &mut i);
    // Only move this owned fixture's workspace to make chdir fail before exec.
    let moved = i.root.with_extension("temporarily-moved");
    std::fs::rename(&i.root, &moved).unwrap();
    let failed = call(&f, &i);
    std::fs::rename(&moved, &i.root).unwrap();
    let failed = failed.unwrap().body.unwrap();
    assert_eq!(failed["hostManagement"]["state"], "not_started");
    assert!(failed["terminal"].is_null());
    assert_eq!(failed["hostManagement"]["version"], 1);
    assert_eq!(failed["hostManagement"]["requestId"], "spawn-failure");
    assert_eq!(failed["hostManagement"]["errorCode"], "runner_unavailable");
    assert!(
        f.node
            .db
            .lock()
            .execute("UPDATE terminal_host_requests SET error_code='other'", [])
            .is_err()
    );
    let retry = call(&f, &i).unwrap().body.unwrap();
    assert_eq!(
        retry["hostManagement"]["terminalId"],
        failed["hostManagement"]["terminalId"]
    );
    assert_eq!(retry["hostManagement"]["state"], "not_started");
    assert_eq!(retry["hostManagement"]["errorCode"], "runner_unavailable");
    assert_eq!(count(&f.node, "terminal_runs"), 1);
    assert!(f.node.terminals.list(&f.current).is_empty());
    f.node.close().await;
}
