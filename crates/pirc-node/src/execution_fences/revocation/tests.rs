use super::*;
use crate::{
    store::{Db, Store},
    workspace_memory::tests::Fixture,
};

fn kinds(evaluation: &Evaluation) -> Vec<(&'static str, &'static str, bool)> {
    evaluation
        .items
        .iter()
        .map(|item| (item.kind, item.reason, item.acknowledgeable))
        .collect()
}
fn eval(f: &Fixture, state: &str) -> Evaluation {
    evaluate(&f.node, &f.node.db.lock(), &f.current, state).unwrap()
}
fn exec(f: &Fixture, sql: &str) {
    f.node
        .db
        .lock()
        .execute(&sql.replace("$S", &f.current), [])
        .unwrap();
}

#[tokio::test]
async fn a_new_idle_generation_is_confirmed_and_an_unfinished_drain_is_pending() {
    let f = Fixture::new().await;
    let confirmed = eval(&f, "supervisor_drained");
    assert_eq!(confirmed.status, "confirmed");
    assert_eq!(confirmed.coverage, "complete");
    assert_eq!(confirmed.generation, 1);
    assert!(confirmed.items.is_empty());
    for state in ["fenced", "stopping"] {
        assert_eq!(eval(&f, state).status, "pending", "{state}");
    }
    assert_eq!(eval(&f, "blocked").status, "blocked");
    f.node.close().await;
}

#[tokio::test]
async fn an_agent_run_without_kernel_containment_is_unproven_not_confirmed() {
    let f = Fixture::new().await;
    f.node.db.lock().increment_epoch(&f.current).unwrap();
    let evaluation = eval(&f, "supervisor_drained");
    assert!(!evaluation.confirms_containment);
    assert_eq!(evaluation.status, "unproven");
    assert_eq!(
        kinds(&evaluation),
        [("platform_containment", "descendants_not_contained", true)]
    );
    f.node.close().await;
}

#[tokio::test]
async fn host_effects_are_acknowledgeable_and_unresolved_resources_block() {
    let f = Fixture::new().await;
    exec(
        &f,
        "INSERT INTO host_command_runs(id,session_id,workspace_id,runner_epoch,incarnation,request_id,state,created_at,updated_at) VALUES('hc-done','$S','repo',0,'n','r1','settled',5,5)",
    );
    exec(
        &f,
        "INSERT INTO host_command_runs(id,session_id,workspace_id,runner_epoch,incarnation,request_id,state,created_at,updated_at) VALUES('hc-never','$S','repo',0,'n','r2','not_started',5,5)",
    );
    exec(
        &f,
        "INSERT INTO terminal_runs(id,session_id,workspace_id,cwd,incarnation,state,created_at,updated_at) VALUES('host-shell','$S','repo','/repo','n','unconfirmed',5,5)",
    );
    // A settled kernel-scoped terminal needs no acknowledgement.
    exec(
        &f,
        "INSERT INTO sandbox_launches(launch_id,session_id,workspace_id,runner_epoch,incarnation,state,identity_json,created_at,updated_at,guard_state,resource_kind) VALUES('scoped','$S','repo',0,'n','terminated','{}',5,5,'released','terminal')",
    );
    exec(
        &f,
        "INSERT INTO terminal_runs(id,session_id,workspace_id,cwd,incarnation,state,created_at,updated_at) VALUES('scoped','$S','repo','/repo','n','settled',5,5)",
    );
    let unproven = eval(&f, "supervisor_drained");
    assert_eq!(unproven.status, "unproven");
    assert_eq!(
        kinds(&unproven),
        [
            ("host_command", "host_effects_may_survive", true),
            ("host_terminal", "host_effects_may_survive", true)
        ]
    );
    // A browser group left open cannot be acknowledged away.
    exec(
        &f,
        "INSERT INTO browser_groups(id,session_id,workspace_id,root,incarnation,state,created_at,updated_at) VALUES('pages','$S','repo','/repo','n','active',6,6)",
    );
    let blocked = eval(&f, "supervisor_drained");
    assert_eq!(blocked.status, "blocked");
    assert!(
        blocked
            .items
            .iter()
            .any(|item| item.kind == "browser" && !item.acknowledgeable)
    );
    assert_ne!(blocked.digest, unproven.digest);
    f.node.close().await;
}

#[tokio::test]
async fn unresolved_scoped_launches_block_and_untracked_or_foreign_rows_are_unproven() {
    let f = Fixture::new().await;
    exec(
        &f,
        "INSERT INTO sandbox_launches(launch_id,session_id,workspace_id,runner_epoch,incarnation,state,identity_json,created_at,updated_at,guard_state,resource_kind) VALUES('legacy:x','$S','repo',0,'n','legacy_untracked',NULL,5,5,'untracked','agent')",
    );
    exec(
        &f,
        "INSERT INTO sandbox_launches(launch_id,session_id,workspace_id,runner_epoch,incarnation,state,identity_json,created_at,updated_at,guard_state,resource_kind) VALUES('elsewhere','$S','other',0,'n','terminated','{}',5,5,'released','terminal')",
    );
    let unproven = eval(&f, "supervisor_drained");
    assert_eq!(
        kinds(&unproven),
        [
            ("legacy_history", "untracked_launch", true),
            ("unattributed", "other_workspace", true)
        ]
    );
    exec(
        &f,
        "INSERT INTO sandbox_launches(launch_id,session_id,workspace_id,runner_epoch,incarnation,state,identity_json,created_at,updated_at,guard_state,resource_kind) VALUES('live','$S','repo',0,'n','unconfirmed','{}',5,5,'released','terminal')",
    );
    let blocked = eval(&f, "supervisor_drained");
    assert_eq!(blocked.status, "blocked");
    assert!(
        blocked
            .items
            .iter()
            .any(|item| item.kind == "sandbox_launch" && item.reason == "unresolved")
    );
    f.node.close().await;
}

#[tokio::test]
async fn an_uncontained_running_launch_is_acknowledgeable_after_the_drain() {
    let f = Fixture::new().await;
    exec(
        &f,
        "INSERT INTO sandbox_launches(launch_id,session_id,workspace_id,runner_epoch,incarnation,state,identity_json,created_at,updated_at,guard_state,resource_kind) VALUES('agent','$S','repo',1,'n','running',NULL,5,5,'untracked','agent')",
    );
    let evaluation = eval(&f, "supervisor_drained");
    assert!(!evaluation.confirms_containment);
    assert_eq!(evaluation.status, "unproven");
    assert_eq!(
        kinds(&evaluation),
        [("sandbox_launch", "uncontained_launch", true)]
    );
    assert_eq!(eval(&f, "stopping").status, "pending");
    f.node.close().await;
}

#[tokio::test]
async fn the_digest_is_stable_bounded_and_covers_hidden_items() {
    let f = Fixture::new().await;
    for n in 0..120 {
        exec(
            &f,
            &format!(
                "INSERT INTO host_command_runs(id,session_id,workspace_id,runner_epoch,incarnation,request_id,state,created_at,updated_at) VALUES('hc-{n:03}','$S','repo',0,'n','r{n}','settled',5,5)"
            ),
        );
    }
    let first = eval(&f, "supervisor_drained");
    assert_eq!(first.items.len(), 100);
    assert_eq!(first.items_total, 120);
    assert_eq!(first, eval(&f, "supervisor_drained"));
    // A change beyond the shown page still changes the digest.
    exec(
        &f,
        "INSERT INTO host_command_runs(id,session_id,workspace_id,runner_epoch,incarnation,request_id,state,created_at,updated_at) VALUES('hc-999','$S','repo',0,'n','r999','settled',5,5)",
    );
    let changed = eval(&f, "supervisor_drained");
    assert_eq!(changed.items, first.items);
    assert_ne!(changed.digest, first.digest);
    f.node.close().await;
}

#[tokio::test]
async fn generations_are_immutable_follow_the_session_and_detect_unrecorded_moves() {
    let f = Fixture::new().await;
    {
        let db = f.node.db.lock();
        assert!(
            db.execute(
                "UPDATE session_binding_generations SET coverage='legacy'",
                []
            )
            .is_err()
        );
        assert!(
            db.execute("DELETE FROM session_binding_generations", [])
                .is_err()
        );
        // A workspace change without a recorded generation is never attributed.
        db.execute_batch("PRAGMA foreign_keys=OFF").unwrap();
        db.execute(
            "UPDATE sessions SET workspace_id='moved' WHERE id=?1",
            [&f.current],
        )
        .unwrap();
    }
    let moved = eval(&f, "supervisor_drained");
    assert_eq!(
        kinds(&moved),
        [("unattributed", "binding_changed_without_generation", true)]
    );
    {
        let db = f.node.db.lock();
        db.execute("DELETE FROM sessions WHERE id=?1", [&f.current])
            .unwrap();
        let left: i64 = db
            .query_row(
                "SELECT count(*) FROM session_binding_generations WHERE session_id=?1",
                [&f.current],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(left, 0);
    }
    f.node.close().await;
}

#[test]
fn existing_sessions_upgrade_as_legacy_and_new_sessions_start_complete() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("node.sqlite");
    let old = {
        let db = Db::open(&file).unwrap();
        let db = db.lock();
        db.add_workspace(
            "repo",
            "node",
            "Repo",
            "/repo",
            crate::store::ModeId::new("directory").unwrap(),
        )
        .unwrap();
        db.execute_batch(include_str!("../remove_binding_generations.sql"))
            .unwrap();
        let old = db
            .create_session("repo", "/private/old", "alice")
            .unwrap()
            .id;
        db.increment_epoch(&old).unwrap();
        db.pragma_update(None, "user_version", 2030).unwrap();
        old
    };
    let db = Db::open(&file).unwrap();
    let db = db.lock();
    let row = |session: &str| -> (String, i64, Option<String>) {
        db.query_row(
            "SELECT coverage,start_epoch,operation_id FROM session_binding_generations WHERE session_id=?1 AND generation=1",
            [session],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .unwrap()
    };
    assert_eq!(row(&old), ("legacy".into(), 0, None));
    let fresh = db.create_session("repo", "/private/new", "alice").unwrap();
    assert_eq!(
        row(&fresh.id),
        ("complete".into(), fresh.runner_epoch, None)
    );
}

#[tokio::test]
async fn receipts_carry_the_evaluation_without_claiming_revocation_or_installation() {
    use super::super::{Intent, accept, network_observation, receipt};
    let f = Fixture::new().await;
    let (epoch, generation) = {
        let db = f.node.db.lock();
        let epoch = db.get_session(&f.current).unwrap().runner_epoch;
        let lease = db.acquire_lease(&f.current, "phone", true, 60_000).unwrap();
        (epoch, lease.generation)
    };
    let intent = Intent {
        operation_id: "move-1".into(),
        plan_hash: "a".repeat(64),
        expected_workspace_id: "repo".into(),
        expected_runner_epoch: epoch,
        preflight: None,
    };
    accept(
        &f.node.db.lock(),
        "alice",
        &f.current,
        &intent,
        "phone",
        generation,
    )
    .unwrap();
    let read = || {
        let saved = receipt(&f.node.db.lock(), "alice", &f.current, "move-1")
            .unwrap()
            .unwrap();
        serde_json::to_value(network_observation(&f.node, &f.current, saved)).unwrap()
    };
    let fenced = read();
    assert_eq!(fenced["revocation"]["status"], "pending");
    assert_eq!(fenced["revocationConfirmed"], false);
    assert_eq!(fenced["targetInstalled"], false);
    exec(
        &f,
        "UPDATE execution_fences SET state='supervisor_drained' WHERE operation_id='move-1'",
    );
    let drained = read();
    assert_eq!(drained["revocation"]["status"], "confirmed");
    assert_eq!(drained["revocation"]["digest"].as_str().unwrap().len(), 64);
    // Evaluation does not change the reported flags in this slice.
    assert_eq!(drained["revocationConfirmed"], false);
    assert_eq!(drained["targetInstalled"], false);
    // Session deletion marks the fence deleted (its trigger); no evaluation follows.
    exec(
        &f,
        "UPDATE execution_fences SET state='deleted' WHERE operation_id='move-1'",
    );
    let deleted = read();
    assert_eq!(deleted["state"], "deleted");
    assert!(deleted.get("revocation").is_none());
    f.node.close().await;
}
