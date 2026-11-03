//! A blocked runner command must not serialize unrelated resource shutdown.
use super::*;
use crate::execution_fences::{Intent, accept, drain};
use crate::host_commands::Origin;
use crate::workspace_memory::tests::Fixture;

#[tokio::test]
async fn pending_runner_and_lost_waiter_do_not_delay_host_or_terminal_retirement() {
    let f = Fixture::new().await;
    let row = f.node.db.lock().get_session(&f.current).unwrap();
    let root: std::path::PathBuf = f
        .node
        .db
        .lock()
        .get_workspace("repo")
        .unwrap()
        .canonical_path
        .into();
    let lease = f
        .node
        .db
        .lock()
        .acquire_lease(&f.current, "phone", false, 60_000)
        .unwrap();
    f.node
        .terminals
        .create(&f.current, &root, None, None, ("phone", lease.generation))
        .unwrap();
    let peer = f
        .node
        .db
        .lock()
        .create_session("repo", "/unused-peer", "alice")
        .unwrap();
    let peer_lease = f
        .node
        .db
        .lock()
        .acquire_lease(&peer.id, "phone", false, 60_000)
        .unwrap();
    let peer_terminal = f
        .node
        .terminals
        .create(
            &peer.id,
            &root,
            None,
            None,
            ("phone", peer_lease.generation),
        )
        .unwrap();
    let (_source, source) = watch::channel(false);
    let mut command = host::command(&f.node.env, "exec /bin/sleep 30", &root);
    let ticket = f
        .node
        .host_commands
        .start(
            &f.node,
            &f.node.db.lock(),
            Origin {
                session: f.current.clone(),
                workspace: "repo".into(),
                epoch: row.runner_epoch,
                request: "blocked-runner-host".into(),
                timeout: Duration::from_secs(35),
                root: root.clone(),
            },
            &mut command,
            source,
        )
        .unwrap();

    let gate = f.node.runners.command_lock(&f.current);
    let held = gate.lock().await;
    accept(
        &f.node.db.lock(),
        "alice",
        &f.current,
        &Intent {
            operation_id: "blocked-runner".into(),
            plan_hash: "a".repeat(64),
            expected_workspace_id: "repo".into(),
            expected_runner_epoch: row.runner_epoch,
            preflight: None,
        },
        "phone",
        lease.generation,
    )
    .unwrap();
    let request = {
        let node = f.node.clone();
        let session = f.current.clone();
        tokio::spawn(async move { drain(&node, "alice", &session, "blocked-runner").await })
    };
    // Await the real child observers while the runner's lock is STILL held.
    // The previous sequential drain never reached either one.
    tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            let complete = {
                let db = f.node.db.lock();
                let host =
                    serde_json::to_value(crate::host_commands::summary(&db, &f.current).unwrap())
                        .unwrap();
                let terminal = serde_json::to_value(
                    crate::terminals::journal::summary(&db, &f.current).unwrap(),
                )
                .unwrap();
                host["observersSettled"] == 1 && terminal["observersSettled"] == 1
            };
            if complete {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("independent cleanup must proceed despite the runner wait");
    assert_eq!(ticket.result().await.unwrap()["aborted"], true);
    assert!(!request.is_finished());
    let state: String = f
        .node
        .db
        .lock()
        .query_row(
            "SELECT state FROM execution_fences WHERE session_id=?1",
            [&f.current],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(state, "stopping");
    assert!(f.node.terminals.list(&f.current).is_empty());
    assert_eq!(f.node.terminals.list(&peer.id)[0].id, peer_terminal.id);
    request.abort();
    assert!(request.await.unwrap_err().is_cancelled());

    // The owned drain is still waiting; dropping one HTTP waiter cannot abort it.
    let retry = {
        let node = f.node.clone();
        let session = f.current.clone();
        tokio::spawn(async move { drain(&node, "alice", &session, "blocked-runner").await })
    };
    drop(held);
    let receipt = tokio::time::timeout(Duration::from_secs(10), retry)
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    assert_eq!(receipt.state, "supervisor_drained");
    assert!(!receipt.revocation_confirmed && !receipt.target_installed);
    assert!(crate::execution_fences::require_open(&f.node.db.lock(), &f.current).is_err());
    assert!(crate::execution_fences::require_open(&f.node.db.lock(), &peer.id).is_ok());
    assert_eq!(f.node.terminals.list(&peer.id)[0].id, peer_terminal.id);
    f.node.close().await;
}
