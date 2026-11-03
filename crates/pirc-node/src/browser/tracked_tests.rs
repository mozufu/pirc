use super::*;
use crate::workspace_memory::tests::Fixture;
use serde_json::json;
use std::sync::atomic::AtomicBool;
#[derive(Default)]
struct Fake {
    calls: AtomicUsize,
    authority: Mutex<Option<effects::Guard>>,
    wire: Mutex<Option<crate::browser::engine::cdp::Session>>,
    closes: AtomicUsize,
    fail_close: AtomicBool,
    close_gate: Mutex<Option<tokio::sync::oneshot::Receiver<()>>>,
}
impl BrowserService for Fake {
    fn enabled(&self) -> bool {
        true
    }
    fn handle(&self, _: BrowserTarget, _: String, _: Value) -> BoxFuture<'_, ApiResult<Value>> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        *lock(&self.authority) = effects::current();
        Box::pin(async { Ok(json!({})) })
    }
    fn handle_with_abort(
        &self,
        t: BrowserTarget,
        o: String,
        a: Value,
        _: watch::Receiver<bool>,
    ) -> BoxFuture<'_, ApiResult<Value>> {
        self.handle(t, o, a)
    }
    fn attach(&self, _: &str, _: FrameSink) -> Detach {
        Box::new(|| {})
    }
    fn input(&self, _: BrowserTarget, message: Value) -> BoxFuture<'_, ApiResult<Option<Value>>> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        let wire = lock(&self.wire).clone();
        Box::pin(async move {
            if let Some(wire) = wire {
                for index in 0..if message["two"] == true { 2 } else { 1 } {
                    wire.call("Input.insertText", json!({"text":index.to_string()}))
                        .await
                        .map_err(|e| ApiError::conflict(e.message))?;
                }
            }
            Ok(None)
        })
    }
    fn close_session(&self, _: &str) -> BoxFuture<'_, ApiResult<()>> {
        self.closes.fetch_add(1, Ordering::SeqCst);
        let gate = lock(&self.close_gate).take();
        Box::pin(async move {
            if let Some(gate) = gate {
                let _ = gate.await;
            }
            if self.fail_close.load(Ordering::SeqCst) {
                Err(journal::unresolved())
            } else {
                Ok(())
            }
        })
    }
    fn shutdown(&self) -> BoxFuture<'_, ()> {
        Box::pin(async {})
    }
}
fn target(f: &Fixture) -> BrowserTarget {
    BrowserTarget {
        session_id: f.current.clone(),
        workspace_id: "repo".into(),
        root: f
            .node
            .db
            .lock()
            .get_workspace("repo")
            .unwrap()
            .canonical_path
            .into(),
    }
}
fn setup(f: &Fixture) -> (Arc<Tracked>, Arc<Fake>) {
    let engine = Arc::new(Fake::default());
    (
        Arc::new(Tracked::new(Arc::downgrade(&f.node), engine.clone())),
        engine,
    )
}
fn summary(f: &Fixture) -> Value {
    serde_json::to_value(journal::summary(&f.node.db.lock(), &f.current).unwrap()).unwrap()
}
#[tokio::test]
async fn canceled_close_is_owned_once_and_a_new_group_needs_a_new_record() {
    effects::from(effects::Caller::Test, async {
        let f = Fixture::new().await;
        let (b, engine) = setup(&f);
        let t = target(&f);
        b.handle(t.clone(), "status".into(), json!({}))
            .await
            .unwrap();
        b.input(t.clone(), json!({"type":"text"})).await.unwrap();
        assert_eq!(summary(&f)["groups"], 1);
        let (send, recv) = tokio::sync::oneshot::channel();
        *lock(&engine.close_gate) = Some(recv);
        assert!(
            tokio::time::timeout(Duration::from_millis(10), b.close_session(&f.current))
                .await
                .is_err()
        );
        assert_eq!(engine.closes.load(Ordering::SeqCst), 1);
        assert_eq!(
            b.input(t.clone(), json!({})).await.unwrap_err().code,
            "browser_stop_unconfirmed"
        );
        send.send(()).unwrap();
        b.close_session(&f.current).await.unwrap();
        assert_eq!(engine.closes.load(Ordering::SeqCst), 1);
        assert_eq!(summary(&f)["observersSettled"], 1);
        b.handle(t, "status".into(), json!({})).await.unwrap();
        assert_eq!(summary(&f)["groups"], 2);
        b.close_session(&f.current).await.unwrap();
        b.shutdown().await;
        f.node.close().await;
    })
    .await;
}
#[tokio::test]
async fn journal_failure_prevents_effects_and_changed_environment_does_not_reuse_a_group() {
    effects::from(effects::Caller::Test, async {
    let f = Fixture::new().await;
    let (b, engine) = setup(&f);
    let t = target(&f);
    f.node.db.lock().execute_batch("CREATE TRIGGER reject_browser BEFORE INSERT ON browser_groups BEGIN SELECT RAISE(ABORT,'injected'); END;").unwrap();
    assert!(b.input(t.clone(), json!({})).await.is_err());
    assert_eq!(engine.calls.load(Ordering::SeqCst), 0);
    f.node
        .db
        .lock()
        .execute_batch("DROP TRIGGER reject_browser;")
        .unwrap();
    b.input(t.clone(), json!({})).await.unwrap();
    f.node
        .db
        .lock()
        .execute(
            "UPDATE workspaces SET canonical_path='/changed' WHERE id='repo'",
            [],
        )
        .unwrap();
    assert_eq!(
        b.input(t.clone(), json!({})).await.unwrap_err().code,
        "stale_environment"
    );
    let mut next = t;
    next.root = "/changed".into();
    assert_eq!(
        b.input(next, json!({})).await.unwrap_err().code,
        "stale_environment"
    );
    assert_eq!(engine.calls.load(Ordering::SeqCst), 1);
    b.close_session(&f.current).await.unwrap();
    f.node.close().await;
    }).await;
}
#[tokio::test]
async fn outcome_failure_survives_a_new_manager_and_blocks_deletion() {
    effects::from(effects::Caller::Test, async {
    for fail_storage in [false, true] {
        let f = Fixture::new().await;
        let (b, engine) = setup(&f);
        let t = target(&f);
        b.input(t, json!({})).await.unwrap();
        if fail_storage {
            f.node.db.lock().execute_batch("CREATE TRIGGER reject_close BEFORE UPDATE OF state ON browser_groups BEGIN SELECT RAISE(ABORT,'injected'); END;").unwrap();
        } else {
            engine.fail_close.store(true, Ordering::SeqCst);
        }
        assert_eq!(
            b.close_session(&f.current).await.unwrap_err().code,
            "browser_stop_unconfirmed"
        );
        assert_eq!(summary(&f)["unresolved"], 1);
        let (new, untouched) = setup(&f);
        assert_eq!(
            new.close_session(&f.current).await.unwrap_err().code,
            "browser_stop_unconfirmed"
        );
        assert_eq!(
            new.input(target(&f), json!({})).await.unwrap_err().code,
            "browser_stop_unconfirmed"
        );
        assert_eq!(untouched.calls.load(Ordering::SeqCst), 0);
        let file = f.dir.join("later-user-edit");
        std::fs::write(&file, b"kept").unwrap();
        let error = crate::app::delete_owned_session(
            f.node.clone(),
            f.current.clone(),
            "alice".into(),
            Arc::default(),
            false,
        )
        .await
        .unwrap_err();
        assert_eq!(error.code, "browser_stop_unconfirmed");
        assert_eq!(std::fs::read(file).unwrap(), b"kept");
        f.node.close().await;
    }
    }).await;
}
#[tokio::test]
async fn a_transition_fence_blocks_new_browser_work_and_reports_saved_unknown_groups() {
    effects::from(effects::Caller::Test, async {
        let f = Fixture::new().await;
        let (b, engine) = setup(&f);
        let t = target(&f);
        b.input(t.clone(), json!({})).await.unwrap();
        let lease = f
            .node
            .db
            .lock()
            .acquire_lease(&f.current, "phone", false, 60_000)
            .unwrap();
        let intent = crate::execution_fences::Intent {
            operation_id: "browser-move".into(),
            plan_hash: "a".repeat(64),
            expected_workspace_id: "repo".into(),
            expected_runner_epoch: 0,
            preflight: None,
        };
        crate::execution_fences::accept(
            &f.node.db.lock(),
            "alice",
            &f.current,
            &intent,
            "phone",
            lease.generation,
        )
        .unwrap();
        assert_eq!(
            b.input(t, json!({})).await.unwrap_err().code,
            "environment_transition_pending"
        );
        assert_eq!(engine.calls.load(Ordering::SeqCst), 1);
        // The node's actual manager has no live entry for this saved group.
        let receipt = crate::execution_fences::drain(&f.node, "alice", &f.current, "browser-move")
            .await
            .unwrap();
        assert_eq!(receipt.state, "blocked");
        assert_eq!(
            receipt.error_code.as_deref(),
            Some("browser_stop_unconfirmed")
        );
        assert!(!receipt.revocation_confirmed && !receipt.target_installed);
        b.close_session(&f.current).await.unwrap();
        let receipt = crate::execution_fences::drain(&f.node, "alice", &f.current, "browser-move")
            .await
            .unwrap();
        assert_eq!(receipt.state, "supervisor_drained");
        assert_eq!(
            serde_json::to_value(receipt.browser).unwrap()["observersSettled"],
            1
        );
        f.node.close().await;
    })
    .await;
}
#[test]
fn migration_preserves_unknown_history_and_origin_is_immutable() {
    use crate::store::Db;
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("node.sqlite");
    {
        let db = Db::open(&path).unwrap();
        db.lock()
            .execute_batch(include_str!("remove_journal.sql"))
            .unwrap();
        db.lock().pragma_update(None, "user_version", 2017).unwrap();
    }
    let db = Db::open(&path).unwrap();
    let db = db.lock();
    assert_eq!(
        serde_json::to_value(journal::summary(&db, "old").unwrap()).unwrap(),
        json!({"groups":0,"observersSettled":0,"unresolved":0,"historyComplete":false})
    );
    db.execute_batch(
        "INSERT INTO browser_groups VALUES('old','s','w','/origin','previous','active',1,1);",
    )
    .unwrap();
    assert_eq!(
        journal::require_settled(&db, "s", None).unwrap_err().code,
        "browser_stop_unconfirmed"
    );
    for sql in [
        "UPDATE browser_groups SET root='/new'",
        "DELETE FROM browser_groups",
    ] {
        assert!(db.execute(sql, []).is_err());
    }
    journal::Record("old".into()).finish(&db, false).unwrap();
    assert!(journal::Record("old".into()).finish(&db, true).is_err());
}

#[tokio::test]
async fn foreground_guard_rechecks_control_epoch_binding_and_fences_at_the_effect() {
    effects::from(effects::Caller::Test, async {
        for change in [
            "takeover", "detach", "epoch", "cancel", "root", "mode", "fence", "close",
        ] {
            let f = Fixture::new().await;
            let (browser, engine) = setup(&f);
            let t = target(&f);
            let control = f
                .node
                .db
                .lock()
                .acquire_lease(&f.current, "phone", false, 60_000)
                .unwrap();
            let connected = Arc::new(Mutex::new(true));
            let abort = Arc::new(watch::channel(false).0);
            let caller = if matches!(change, "epoch" | "cancel") {
                effects::Caller::Agent {
                    epoch: 0,
                    abort: abort.clone(),
                }
            } else {
                effects::Caller::Viewer {
                    client: "phone".into(),
                    generation: control.generation,
                    open: connected.clone(),
                }
            };
            effects::from(caller, browser.handle(t, "snapshot".into(), json!({})))
                .await
                .unwrap();
            let guard = lock(&engine.authority)
                .clone()
                .expect("guard installed before engine construction");
            assert_eq!(guard.run(|| 42).unwrap(), 42);
            match change {
                "takeover" => {
                    f.node
                        .db
                        .lock()
                        .acquire_lease(&f.current, "web", true, 60_000)
                        .unwrap();
                }
                "detach" => *lock(&connected) = false,
                "epoch" => {
                    f.node
                        .db
                        .lock()
                        .execute(
                            "UPDATE sessions SET runner_epoch=runner_epoch+1 WHERE id=?1",
                            [&f.current],
                        )
                        .unwrap();
                }
                "cancel" => {
                    abort.send_replace(true);
                }
                "root" => {
                    f.node
                        .db
                        .lock()
                        .execute(
                            "UPDATE workspaces SET canonical_path='/changed' WHERE id='repo'",
                            [],
                        )
                        .unwrap();
                }
                "mode" => f.node.modes.write().unwrap().clear(),
                "fence" => {
                    crate::execution_fences::accept(
                        &f.node.db.lock(),
                        "alice",
                        &f.current,
                        &crate::execution_fences::Intent {
                            operation_id: "browser-effect".into(),
                            plan_hash: "b".repeat(64),
                            expected_workspace_id: "repo".into(),
                            expected_runner_epoch: 0,
                            preflight: None,
                        },
                        "phone",
                        control.generation,
                    )
                    .unwrap();
                }
                "close" => {
                    browser.close_session(&f.current).await.unwrap();
                }
                _ => unreachable!(),
            }
            assert!(
                guard
                    .run(|| panic!("stale effect ran after {change}"))
                    .is_err(),
                "{change}"
            );
            assert!(guard.failure().is_some());
            if change != "close" {
                browser.close_session(&f.current).await.unwrap();
            }
            f.node.close().await;
        }
    })
    .await;
}

#[tokio::test]
async fn observer_cannot_mutate_and_stale_agent_cannot_close_a_current_group() {
    effects::from(effects::Caller::Test, async {
        let f = Fixture::new().await;
        let (browser, engine) = setup(&f);
        browser
            .handle(target(&f), "status".into(), json!({}))
            .await
            .unwrap();
        let observer = effects::Caller::Observer {
            open: Arc::new(Mutex::new(true)),
        };
        assert!(
            effects::from(
                observer,
                browser.input(
                    target(&f),
                    json!({"type":"navigate","url":"https://example.com"})
                )
            )
            .await
            .is_err()
        );
        let old = effects::Caller::Agent {
            epoch: -1,
            abort: Arc::new(watch::channel(false).0),
        };
        assert!(
            effects::from(old, browser.handle(target(&f), "close".into(), json!({})))
                .await
                .is_err()
        );
        assert_eq!(engine.closes.load(Ordering::SeqCst), 0);
        let current = effects::Caller::Agent {
            epoch: 0,
            abort: Arc::new(watch::channel(false).0),
        };
        effects::from(
            current,
            browser.handle(target(&f), "close".into(), json!({})),
        )
        .await
        .unwrap();
        assert_eq!(engine.closes.load(Ordering::SeqCst), 1);
        assert_eq!(summary(&f)["observersSettled"], 1);
        f.node.close().await;
    })
    .await;
}

#[tokio::test]
async fn a_real_control_takeover_fences_cdp_writes_after_queue_and_reply_waits() {
    effects::from(effects::Caller::Test, async {
        use crate::browser::engine::cdp::Fake as Pipe;
        for between in [false, true] {
            let f = Fixture::new().await;
            let (browser, engine) = setup(&f);
            let mut pipe = Pipe::new();
            *lock(&engine.wire) = Some(pipe.connection.session("source"));
            let control = f
                .node
                .db
                .lock()
                .acquire_lease(&f.current, "phone", false, 60_000)
                .unwrap();
            let (busy, first) = if between {
                (None, None)
            } else {
                let wire = pipe.connection.browser();
                let busy = tokio::spawn(async move {
                    wire.call("already-admitted", json!({"padding":"x".repeat(2_000_000)}))
                        .await
                });
                // Pause its body at the receiver to hold the following command in the queue.
                pipe.wait_for_command_prefix().await;
                (Some(busy), None::<Value>)
            };
            let task = {
                let browser = browser.clone();
                let target = target(&f);
                tokio::spawn(effects::from(
                    effects::Caller::Viewer {
                        client: "phone".into(),
                        generation: control.generation,
                        open: Arc::new(Mutex::new(true)),
                    },
                    async move {
                        browser
                            .input(target, json!({"type":"text","two":between}))
                            .await
                    },
                ))
            };
            tokio::time::timeout(Duration::from_secs(2), async {
                while engine.calls.load(Ordering::SeqCst) == 0 {
                    tokio::task::yield_now().await;
                }
            })
            .await
            .unwrap();
            let first = if between {
                Some(pipe.command().await)
            } else {
                first
            };
            if let Some(first) = &first {
                assert_eq!(first["method"], "Input.insertText");
            }
            f.node
                .db
                .lock()
                .acquire_lease(&f.current, "web", true, 60_000)
                .unwrap();
            if let Some(first) = first {
                pipe.send(json!({"id":first["id"],"sessionId":"source","result":{}}))
                    .await;
            }
            if busy.is_some() {
                let frame = pipe.command().await;
                assert_eq!(frame["method"], "already-admitted");
                pipe.send(json!({"id":frame["id"],"result":{}})).await;
            }
            let wire = pipe.connection.session("peer");
            let peer = tokio::spawn(async move { wire.call("peer-continues", json!({})).await });
            let frame = pipe.command().await;
            assert_eq!(frame["method"], "peer-continues");
            assert_eq!(task.await.unwrap().unwrap_err().code, "lost_control");
            pipe.send(json!({"id":frame["id"],"sessionId":"peer","result":{}}))
                .await;
            peer.await.unwrap().unwrap();
            if let Some(busy) = busy {
                busy.await.unwrap().unwrap();
            }
            browser.close_session(&f.current).await.unwrap();
            f.node.close().await;
        }
    })
    .await;
}

#[tokio::test]
async fn missing_authority_never_reserves_a_group_or_calls_the_engine() {
    let f = Fixture::new().await;
    let (browser, engine) = setup(&f);
    assert!(
        browser
            .handle(target(&f), "snapshot".into(), json!({}))
            .await
            .is_err()
    );
    assert!(
        browser
            .input(target(&f), json!({"type":"text"}))
            .await
            .is_err()
    );
    assert_eq!(engine.calls.load(Ordering::SeqCst), 0);
    assert_eq!(summary(&f)["groups"], 0);
    f.node.close().await;
}
