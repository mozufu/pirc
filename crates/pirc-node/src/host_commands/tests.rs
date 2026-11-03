use super::*;
use crate::store::Db;
use crate::workspace_memory::tests::Fixture;
use std::path::Path;

pub(super) fn origin(f: &Fixture, session: &str, request: &str) -> Origin {
    let row = f.node.db.lock().get_session(session).unwrap();
    Origin {
        session: session.into(),
        root: f
            .node
            .db
            .lock()
            .get_workspace(&row.workspace_id)
            .unwrap()
            .canonical_path
            .into(),
        workspace: row.workspace_id,
        epoch: row.runner_epoch,
        request: request.into(),
        timeout: Duration::from_secs(15),
    }
}
pub(super) fn start(
    f: &Fixture,
    session: &str,
    request: &str,
    text: &str,
    source: watch::Receiver<bool>,
) -> ApiResult<Ticket> {
    let origin = origin(f, session, request);
    let mut command = crate::runner::host::command(&f.node.env, text, Path::new("/"));
    f.node
        .host_commands
        .start(&f.node, &f.node.db.lock(), origin, &mut command, source)
}
fn snapshot(f: &Fixture, session: &str) -> Summary {
    summary(&f.node.db.lock(), session).unwrap()
}

#[tokio::test]
async fn lost_waiter_is_cancelled_but_independently_reaped_and_peer_survives() {
    let f = Fixture::new().await;
    let peer_root = f.dir.join("peer-work");
    std::fs::create_dir(&peer_root).unwrap();
    let peer = {
        let db = f.node.db.lock();
        db.add_workspace(
            "other",
            "memory-test",
            "Other",
            peer_root.to_str().unwrap(),
            crate::store::ModeId::new("directory").unwrap(),
        )
        .unwrap();
        db.create_session("other", "/unused-peer", "alice").unwrap()
    };
    let (_source, source) = watch::channel(false);
    let first = start(
        &f,
        &f.current,
        "first",
        "exec /bin/sleep 30",
        source.clone(),
    )
    .unwrap();
    let peer_job = start(&f, &peer.id, "peer", "exec /bin/sleep 30", source).unwrap();
    assert_eq!(snapshot(&f, &f.current).unresolved, 1);
    drop(first);
    let _stop = f.node.host_commands.stop(&f.current);
    f.node
        .host_commands
        .wait_session(&f.node, &f.current)
        .await
        .unwrap();
    assert_eq!(snapshot(&f, &f.current).observers_settled, 1);
    assert_eq!(snapshot(&f, &peer.id).unresolved, 1);
    assert!(!snapshot(&f, &f.current).history_complete);
    drop(peer_job);
    f.node
        .host_commands
        .wait_session(&f.node, &peer.id)
        .await
        .unwrap();
    f.node.close().await;
}
#[tokio::test]
async fn stop_guards_compose_and_repeated_requests_never_reexecute() {
    let f = Fixture::new().await;
    let (_source, source) = watch::channel(false);
    let a = f.node.host_commands.stop(&f.current);
    let b = f.node.host_commands.stop(&f.current);
    assert!(start(&f, &f.current, "one", "true", source.clone()).is_err());
    drop(a);
    assert!(start(&f, &f.current, "one", "true", source.clone()).is_err());
    drop(b);
    let result = start(&f, &f.current, "one", "printf done", source.clone())
        .unwrap()
        .result()
        .await
        .unwrap();
    assert_eq!(result["output"], "done");
    assert!(start(&f, &f.current, "one", "printf duplicate", source).is_err());
    assert_eq!(snapshot(&f, &f.current).launches, 1);
    f.node.runners.stop_session(&f.current).await.unwrap();
    f.node.close().await;
}
#[tokio::test]
async fn failing_reservation_never_spawns_and_failed_running_write_cancels() {
    let f = Fixture::new().await;
    let (_source, source) = watch::channel(false);
    let marker = f.dir.join("must-not-exist");
    f.node.db.lock().execute_batch("CREATE TRIGGER fail_reserve BEFORE INSERT ON host_command_runs BEGIN SELECT RAISE(ABORT,'full'); END;").unwrap();
    assert!(
        start(
            &f,
            &f.current,
            "one",
            &format!("touch '{}'", marker.display()),
            source.clone()
        )
        .is_err()
    );
    assert!(!marker.exists());
    assert_eq!(snapshot(&f, &f.current).launches, 0);
    f.node.db.lock().execute_batch("DROP TRIGGER fail_reserve; CREATE TRIGGER fail_running BEFORE UPDATE OF state ON host_command_runs WHEN NEW.state='running' BEGIN SELECT RAISE(ABORT,'full'); END;").unwrap();
    let ticket = start(&f, &f.current, "two", "exec /bin/sleep 30", source).unwrap();
    assert!(ticket.result().await.is_err());
    assert_eq!(snapshot(&f, &f.current).observers_settled, 1);
    f.node.close().await;
}
#[tokio::test]
async fn failed_outcome_persistence_is_not_successful_stop() {
    let f = Fixture::new().await;
    let (_source, source) = watch::channel(false);
    f.node.db.lock().execute_batch("CREATE TRIGGER fail_settle BEFORE UPDATE OF state ON host_command_runs WHEN NEW.state='settled' BEGIN SELECT RAISE(ABORT,'full'); END;").unwrap();
    assert!(
        start(&f, &f.current, "one", "true", source)
            .unwrap()
            .result()
            .await
            .is_err()
    );
    assert_eq!(snapshot(&f, &f.current).unresolved, 1);
    assert_eq!(
        f.node
            .runners
            .stop_session(&f.current)
            .await
            .unwrap_err()
            .code,
        "host_stop_unconfirmed"
    );
    f.node.close().await;
}
#[tokio::test]
async fn cancelled_wait_does_not_cancel_supervision() {
    let f = Fixture::new().await;
    let (_source, source) = watch::channel(false);
    let ticket = start(&f, &f.current, "one", "exec /bin/sleep 30", source).unwrap();
    let _guard = f.node.host_commands.stop(&f.current);
    assert!(
        tokio::time::timeout(
            Duration::from_millis(10),
            f.node.host_commands.wait_session(&f.node, &f.current)
        )
        .await
        .is_err()
    );
    f.node
        .host_commands
        .wait_session(&f.node, &f.current)
        .await
        .unwrap();
    assert_eq!(ticket.result().await.unwrap()["aborted"], true);
    assert_eq!(snapshot(&f, &f.current).unresolved, 0);
    f.node.close().await;
}
#[tokio::test]
async fn spawn_failure_and_withdrawal_are_not_running_effects() {
    let f = Fixture::new().await;
    let (tx, rx) = watch::channel(false);
    tx.send_replace(true);
    assert!(start(&f, &f.current, "withdrawn", "true", rx).is_err());
    let closed = watch::channel(false).1;
    assert!(start(&f, &f.current, "closed", "true", closed).is_err());
    assert_eq!(snapshot(&f, &f.current).launches, 0);
    let origin = origin(&f, &f.current, "missing");
    let mut cmd = CommandWrap::from(tokio::process::Command::new("/missing-host-command-test"));
    let (_tx, rx) = watch::channel(false);
    let ticket = f
        .node
        .host_commands
        .start(&f.node, &f.node.db.lock(), origin, &mut cmd, rx)
        .unwrap();
    assert_eq!(ticket.result().await.unwrap()["exitCode"], Value::Null);
    assert_eq!(snapshot(&f, &f.current).not_started, 1);
    f.node.close().await;
}
#[tokio::test]
async fn stale_epoch_and_accepted_transition_refuse_new_host_effects() {
    let f = Fixture::new().await;
    let origin = origin(&f, &f.current, "stale");
    f.node.db.lock().increment_epoch(&f.current).unwrap();
    let (_tx, rx) = watch::channel(false);
    let mut cmd = crate::runner::host::command(&f.node.env, "true", Path::new("/"));
    assert!(
        f.node
            .host_commands
            .start(&f.node, &f.node.db.lock(), origin, &mut cmd, rx.clone())
            .is_err()
    );
    {
        let db = f.node.db.lock();
        let lease = db
            .acquire_lease(&f.current, "phone", false, 60_000)
            .unwrap();
        crate::execution_fences::accept(
            &db,
            "alice",
            &f.current,
            &crate::execution_fences::Intent {
                operation_id: "switch".into(),
                plan_hash: "a".repeat(64),
                expected_workspace_id: "repo".into(),
                expected_runner_epoch: 1,
                preflight: None,
            },
            "phone",
            lease.generation,
        )
        .unwrap();
    }
    assert_eq!(
        start(&f, &f.current, "fenced", "true", rx)
            .err()
            .unwrap()
            .code,
        "environment_transition_pending"
    );
    assert_eq!(snapshot(&f, &f.current).launches, 0);
    f.node.close().await;
}
#[test]
fn migration_restart_and_deletion_preserve_uncertainty_and_minimal_evidence() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("node.db");
    let session = {
        let db = Db::open(&path).unwrap();
        let db = db.lock();
        db.add_workspace(
            "repo",
            "node",
            "Repo",
            "/repo",
            crate::store::ModeId::new("directory").unwrap(),
        )
        .unwrap();
        let row = db
            .create_session("repo", "/private-session", "alice")
            .unwrap();
        db.increment_epoch(&row.id).unwrap();
        db.execute_batch(include_str!("remove_schema.sql")).unwrap();
        db.execute_batch("PRAGMA user_version=2014;").unwrap();
        row.id
    };
    {
        let db = Db::open(&path).unwrap();
        let db = db.lock();
        db.require_session_available(&session).unwrap();
        crate::execution_fences::require_open(&db, &session).unwrap();
        assert_eq!(summary(&db, &session).unwrap().launches, 0);
        assert!(!summary(&db, &session).unwrap().history_complete);
        for (id, state) in [
            ("a", "launching"),
            ("b", "running"),
            ("c", "unconfirmed"),
            ("d", "settled"),
        ] {
            db.execute(
                "INSERT INTO host_command_runs VALUES(?1,?3,'repo',1,'previous-node',?1,?2,1,1)",
                params![id, state, session],
            )
            .unwrap();
        }
    }
    let db = Db::open(&path).unwrap();
    let db = db.lock();
    assert_eq!(summary(&db, &session).unwrap().unresolved, 3);
    db.begin_session_deletion(&session, "alice").unwrap();
    db.finish_session_deletion(&session).unwrap();
    assert!(db.get_session(&session).is_err());
    assert_eq!(summary(&db, &session).unwrap().unresolved, 3);
    assert!(db.execute("DELETE FROM host_command_runs", []).is_err());
    assert!(
        db.execute("UPDATE host_command_runs SET runner_epoch=2", [])
            .is_err()
    );
    assert!(
        db.execute(
            "UPDATE host_command_runs SET state='running' WHERE id='d'",
            []
        )
        .is_err()
    );
    assert!(
        db.execute(
            "UPDATE host_command_runs SET state='settled' WHERE id='c'",
            []
        )
        .is_err()
    );
}

fn creation(f: &Fixture) -> i64 {
    let db = f.node.db.lock();
    db.execute("INSERT INTO session_creations(owner_user,operation_id,workspace_id,submission_hash,session_id,state,created_at) VALUES('alice','creation-1','repo',?1,?2,'ready',1)",params!["a".repeat(64),f.current]).unwrap();
    db.acquire_lease(&f.current, "phone", false, 60_000)
        .unwrap()
        .generation
}
async fn stop_request(f: &Fixture, generation: i64) -> pirc_protocol::NodeHttpResponse {
    f.node.router.handle(&f.node,pirc_protocol::NodeHttpRequest {
        method:pirc_protocol::HttpMethod::Post,url:format!("/api/sessions/{}/commands",f.current),user:"alice".into(),
        payload:Some(serde_json::json!({"commandId":"stop-initial","clientId":"phone","generation":generation,"payload":{"type":"stop"}})),body_base64:None,content_type:None,
    }).await
}
#[tokio::test]
async fn initial_stop_without_a_runner_still_joins_host_supervision() {
    let f = Fixture::new().await;
    let generation = creation(&f);
    let (_source, source) = watch::channel(false);
    let ticket = start(&f, &f.current, "old-host", "exec /bin/sleep 30", source).unwrap();
    assert!(f.node.runners.get(&f.current).is_none());
    let result = stop_request(&f, generation).await;
    assert_eq!(result.status, 202, "{result:?}");
    assert_eq!(
        result.body.unwrap()["initialAdmission"]["stopConfirmed"],
        true
    );
    assert_eq!(snapshot(&f, &f.current).observers_settled, 1);
    assert_eq!(ticket.result().await.unwrap()["aborted"], true);
    f.node.close().await;
}
#[tokio::test]
async fn previous_node_host_uncertainty_blocks_initial_stop_and_drain() {
    let f = Fixture::new().await;
    let generation = creation(&f);
    f.node.db.lock().execute("INSERT INTO host_command_runs VALUES('old',?1,'repo',0,'previous-incarnation','request','running',1,1)",[&f.current]).unwrap();
    let result = stop_request(&f, generation).await;
    assert_eq!(result.status, 503, "{result:?}");
    assert_eq!(
        result.body.unwrap()["error"]["code"],
        "host_stop_unconfirmed"
    );
    assert_eq!(
        f.node.db.lock().get_command("stop-initial").unwrap().status,
        crate::store::CommandStatus::OutcomeUnknown
    );
    assert_eq!(
        crate::session_creation::admission::stop_receipt(&f.node.db.lock(), &f.current, "alice")
            .unwrap()["stopConfirmed"],
        false
    );
    crate::execution_fences::accept(
        &f.node.db.lock(),
        "alice",
        &f.current,
        &crate::execution_fences::Intent {
            operation_id: "switch-old-host".into(),
            plan_hash: "a".repeat(64),
            expected_workspace_id: "repo".into(),
            expected_runner_epoch: 0,
            preflight: None,
        },
        "phone",
        generation,
    )
    .unwrap();
    let drained = crate::execution_fences::drain(&f.node, "alice", &f.current, "switch-old-host")
        .await
        .unwrap();
    let result = serde_json::to_value(drained).unwrap();
    assert_eq!(result["state"], "blocked");
    assert_eq!(result["errorCode"], "host_stop_unconfirmed");
    assert_eq!(result["hostCommands"]["unresolved"], 1);
    assert_eq!(result["revocationConfirmed"], false);
    f.node.close().await;
}
