//! Real PTY/Node checks: queued and partially delivered input must not inherit
//! another device's lease or cross an accepted environment transition.
use super::*;
use crate::store::Store;
use crate::workspace_memory::tests::Fixture;
use std::io::Read;
use tokio::sync::mpsc::UnboundedReceiver;

fn control(
    f: &Fixture,
    session: &str,
    client: &str,
) -> (Arc<Control>, UnboundedReceiver<ApiError>) {
    let lease = f
        .node
        .db
        .lock()
        .acquire_lease(session, client, true, 60_000)
        .unwrap();
    let (send, recv) = mpsc::unbounded_channel();
    (
        Arc::new(Control {
            client: client.into(),
            generation: lease.generation,
            open: Arc::new(Mutex::new(true)),
            rejected: Arc::new(move |e| {
                let _ = send.send(e);
            }),
        }),
        recv,
    )
}
fn root(f: &Fixture) -> std::path::PathBuf {
    f.node
        .db
        .lock()
        .get_workspace("repo")
        .unwrap()
        .canonical_path
        .into()
}
fn terminal(f: &Fixture, session: &str) -> TerminalInfo {
    let lease = f
        .node
        .db
        .lock()
        .acquire_lease(session, "phone", false, 60_000)
        .unwrap();
    f.node
        .terminals
        .create(session, &root(f), None, None, ("phone", lease.generation))
        .unwrap()
}
fn type_marker(f: &Fixture, session: &str, terminal: &str, name: &str, control: Arc<Control>) {
    f.node
        .terminals
        .input_controlled(
            session,
            terminal,
            &format!("printf done > {name}\n"),
            control,
        )
        .unwrap();
}
async fn marker(f: &Fixture, name: &str) {
    tokio::time::timeout(Duration::from_secs(10), async {
        while std::fs::read(root(f).join(name)).ok().as_deref() != Some(b"done") {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap();
}
async fn rejected(errors: &mut UnboundedReceiver<ApiError>, code: &str) {
    let e = tokio::time::timeout(Duration::from_secs(10), errors.recv())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(e.code, code);
}
fn fence(f: &Fixture, control: &Control) {
    let db = f.node.db.lock();
    let session = db.get_session(&f.current).unwrap();
    crate::execution_fences::accept(
        &db,
        "alice",
        &f.current,
        &crate::execution_fences::Intent {
            operation_id: "terminal-transition".into(),
            plan_hash: "a".repeat(64),
            expected_workspace_id: session.workspace_id,
            expected_runner_epoch: session.runner_epoch,
            preflight: None,
        },
        &control.client,
        control.generation,
    )
    .unwrap();
}
async fn cleanup(f: &Fixture) {
    tokio::time::timeout(
        Duration::from_secs(10),
        f.node.terminals.dispose_session(&f.current),
    )
    .await
    .unwrap()
    .unwrap();
    f.node.close().await;
}

#[tokio::test]
async fn queued_old_device_input_and_resize_are_refused_after_takeover() {
    let f = Fixture::new().await;
    let t = terminal(&f, &f.current);
    let (old, mut errors) = control(&f, &f.current, "phone");
    // Current-thread runtime: queued commands cannot run before this takeover.
    type_marker(&f, &f.current, &t.id, "old", old.clone());
    f.node
        .terminals
        .resize_controlled(&f.current, &t.id, 150.0, 50.0, old)
        .unwrap();
    let (new, _) = control(&f, &f.current, "web");
    rejected(&mut errors, "lost_control").await;
    rejected(&mut errors, "lost_control").await;
    assert_eq!(
        (
            f.node.terminals.list(&f.current)[0].cols,
            f.node.terminals.list(&f.current)[0].rows
        ),
        (80, 24)
    );
    assert!(!root(&f).join("old").exists());
    type_marker(&f, &f.current, &t.id, "new", new.clone());
    f.node
        .terminals
        .resize_controlled(&f.current, &t.id, 100.0, 30.0, new.clone())
        .unwrap();
    f.node
        .terminals
        .resize_controlled(&f.current, &t.id, f64::NAN, 40.0, new.clone())
        .unwrap();
    type_marker(&f, &f.current, &t.id, "resized", new);
    marker(&f, "resized").await;
    assert_eq!(
        (
            f.node.terminals.list(&f.current)[0].cols,
            f.node.terminals.list(&f.current)[0].rows
        ),
        (100, 40)
    );
    assert!(root(&f).join("new").exists());
    cleanup(&f).await;
}

#[tokio::test]
async fn queued_input_observes_fence_without_stopping_peer_terminal() {
    let f = Fixture::new().await;
    let peer_dir = root(&f).join("peer-session");
    let peer = f
        .node
        .db
        .lock()
        .create_session("repo", peer_dir.to_str().unwrap(), "alice")
        .unwrap();
    let source = terminal(&f, &f.current);
    let other = terminal(&f, &peer.id);
    let (source_control, mut errors) = control(&f, &f.current, "phone");
    let (peer_control, _) = control(&f, &peer.id, "web");
    type_marker(
        &f,
        &f.current,
        &source.id,
        "revoked",
        source_control.clone(),
    );
    fence(&f, &source_control);
    type_marker(&f, &peer.id, &other.id, "peer", peer_control);
    rejected(&mut errors, "environment_transition_pending").await;
    marker(&f, "peer").await;
    assert!(!root(&f).join("revoked").exists());
    assert_eq!(
        f.node
            .terminals
            .input_controlled(&f.current, &source.id, "echo never\n", source_control)
            .unwrap_err()
            .code,
        "environment_transition_pending"
    );
    f.node.terminals.dispose_session(&peer.id).await.unwrap();
    cleanup(&f).await;
}

#[tokio::test]
async fn queued_input_is_discarded_on_detach_close_deletion_or_mode_change() {
    for change in ["detach", "close", "delete", "mode", "workspace"] {
        let f = Fixture::new().await;
        let t = terminal(&f, &f.current);
        let (auth, mut errors) = control(&f, &f.current, "phone");
        let original_root = root(&f);
        type_marker(&f, &f.current, &t.id, "stale", auth.clone());
        match change {
            "detach" => *lock(&auth.open) = false,
            "close" => f.node.terminals.close(&f.current, &t.id).unwrap(),
            "delete" => f
                .node
                .db
                .lock()
                .begin_session_deletion(&f.current, "alice")
                .unwrap(),
            "mode" => f.node.modes.write().unwrap().clear(),
            "workspace" => {
                let moved = original_root.with_file_name("moved");
                std::fs::create_dir(&moved).unwrap();
                f.node
                    .db
                    .lock()
                    .execute(
                        "UPDATE workspaces SET canonical_path=?1 WHERE id='repo'",
                        [moved.to_str().unwrap()],
                    )
                    .unwrap();
            }
            _ => unreachable!(),
        }
        if matches!(change, "delete" | "mode" | "workspace") {
            rejected(
                &mut errors,
                match change {
                    "delete" => "conflict",
                    "mode" => "mode_unavailable",
                    _ => "stale_environment",
                },
            )
            .await;
        } else {
            // A second live terminal gives the writer tasks a real progress
            // barrier; closed streams must not receive delayed error frames.
            let fresh = terminal(&f, &f.current);
            let (current, _) = control(&f, &f.current, "phone");
            type_marker(&f, &f.current, &fresh.id, "barrier", current);
            marker(&f, "barrier").await;
            assert!(errors.try_recv().is_err());
        }
        assert!(!original_root.join("stale").exists());
        cleanup(&f).await;
    }
}

#[tokio::test]
async fn partial_write_rechecks_after_backpressure_and_does_not_send_the_tail() {
    for transition in [false, true] {
        let f = Fixture::new().await;
        let (control, _) = control(&f, &f.current, "phone");
        let (master, slave) = pty::open(24, 80).unwrap();
        let mut reader = slave.raw_reader().unwrap();
        let (pty, _) = mpsc::unbounded_channel();
        let (_, exited) = watch::channel(None);
        let cwd = root(&f);
        let binding = Binding::capture(&f.node, &f.node.db.lock(), &f.current, &cwd).unwrap();
        let entry = Arc::new(Entry {
            record: None,
            binding: Some(binding),
            stopping: watch::channel(false).0,
            state: Mutex::new(EntryState {
                closing: false,
                info: TerminalInfo {
                    id: "blocked-pty".into(),
                    session_id: f.current.clone(),
                    title: "test".into(),
                    cwd: root(&f).to_string_lossy().into_owned(),
                    cols: 80,
                    rows: 24,
                    created_at: 0,
                    exit_code: None,
                    exited: false,
                },
                scrollback: VecDeque::new(),
                scrollback_bytes: 0,
                listeners: vec![],
                decoder: Utf8Stream::default(),
            }),
            pty,
            exited,
        });
        let weak = Arc::downgrade(&f.node);
        let command = PtyCommand {
            authority: Authority::Client(control.clone()),
            action: Action::Write(vec![b'x'; 1024 * 1024]),
        };
        let writing =
            tokio::spawn(async move { input::execute(&weak, &entry, &master, &command).await });
        // Wait for actual delivery of a byte, without draining the PTY queue.
        tokio::time::timeout(Duration::from_secs(10), async {
            loop {
                match reader.read(&mut [0u8; 1]) {
                    Ok(1) => break,
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
                    other => panic!("unexpected PTY read: {other:?}"),
                }
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .unwrap();
        assert!(!writing.is_finished(), "the PTY must apply backpressure");
        if transition {
            fence(&f, &control);
        } else {
            f.node
                .db
                .lock()
                .acquire_lease(&f.current, "web", true, 60_000)
                .unwrap();
        }
        let mut received = 1usize;
        let mut buffer = [0u8; 8192];
        tokio::time::timeout(Duration::from_secs(10), async {
            while !writing.is_finished() {
                match reader.read(&mut buffer) {
                    Ok(n) => received += n,
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
                    Err(e) => panic!("{e}"),
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        let error = writing.await.unwrap().unwrap_err();
        assert_eq!(
            error.code,
            if transition {
                "environment_transition_pending"
            } else {
                "lost_control"
            }
        );
        assert!(
            received < 1024 * 1024,
            "the obsolete tail reached the terminal"
        );
        cleanup(&f).await;
    }
}

#[tokio::test]
async fn terminal_creation_rechecks_controller_and_original_root_before_spawning() {
    let f = Fixture::new().await;
    let (old, _) = control(&f, &f.current, "phone");
    let (current, _) = control(&f, &f.current, "web");
    assert_eq!(
        f.node
            .terminals
            .create(
                &f.current,
                &root(&f),
                None,
                None,
                (&old.client, old.generation)
            )
            .unwrap_err()
            .code,
        "lost_control"
    );
    assert_eq!(
        f.node
            .terminals
            .create(
                &f.current,
                Path::new("/"),
                None,
                None,
                (&current.client, current.generation)
            )
            .unwrap_err()
            .code,
        "stale_environment"
    );
    assert!(f.node.terminals.list(&f.current).is_empty());
    cleanup(&f).await;
}
