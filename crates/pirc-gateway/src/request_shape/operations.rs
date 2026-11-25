//! State-changing routes whose effect lives on a Node or in the session
//! index: a request of the wrong shape must leave all of it untouched.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use pirc_protocol::{ModeId, NodeHttpRequest, NodeHttpResponse, NodeRole};
use rusqlite::params;
use serde_json::{Value, json};

use super::tests::{Probe, USER, Who, fixture, identities, ok, probe, prove_operation};
use crate::app::AppState;
use crate::db::Store as _;

type Log = Arc<Mutex<Vec<String>>>;

struct World {
    app: AppState,
    who: Vec<Who>,
    log: Log,
    counter: AtomicUsize,
    _dir: tempfile::TempDir,
}

impl World {
    fn new() -> Self {
        let (app, dir) = fixture();
        let log: Log = Arc::default();
        app.db
            .lock()
            .sync_remote_workspaces(
                "work",
                &[("pots".into(), "Pots".into(), ModeId::new("pot").unwrap())],
            )
            .unwrap();
        let node_log = log.clone();
        app.nodes.set_test_node(
            crate::nodes::ConnectedNode {
                id: "work".into(),
                role: NodeRole::Node,
                modes: vec![ModeId::new("pot").unwrap()],
                workspaces: vec![pirc_protocol::RegisteredWorkspace {
                    id: "pots".into(),
                    display_name: "Pots".into(),
                    mode: ModeId::new("pot").unwrap(),
                    roles: None,
                    repo: None,
                    checkpoint_private: false,
                }],
                added: Default::default(),
                connected_at: 0,
                last_seen_at: 0,
            },
            move |request: NodeHttpRequest| {
                node_log
                    .lock()
                    .unwrap()
                    .push(format!("{:?} {}", request.method, request.url));
                Ok(NodeHttpResponse {
                    status: 201,
                    body: Some(json!({ "upload": { "id": "up1" } })),
                })
            },
        );
        let who = identities(&app, USER);
        Self {
            app,
            who,
            log,
            counter: AtomicUsize::new(0),
            _dir: dir,
        }
    }

    fn next(&self) -> usize {
        self.counter.fetch_add(1, Ordering::Relaxed)
    }

    fn session(&self) -> String {
        let n = self.next();
        self.app
            .db
            .lock()
            .create_session(
                "work:pots",
                &format!("node://work/remote-{n}"),
                "work",
                &format!("remote-{n}"),
                USER,
            )
            .unwrap()
            .id
    }

    fn requests(&self) -> Value {
        json!(*self.log.lock().unwrap())
    }
}

fn raw(name: &'static str, content_type: &'static str) -> Probe {
    probe(
        name,
        &[("x-pirc-request", "1"), ("content-type", content_type)],
        "replacement",
    )
}

#[tokio::test]
async fn marking_a_session_read_needs_the_request_shape() {
    let world = World::new();
    let seed = || {
        let id = world.session();
        world
            .app
            .db
            .lock()
            .execute(
                "UPDATE sessions SET activity_at=?, read_at=NULL WHERE id=?",
                params![crate::util::now_ms(), id],
            )
            .unwrap();
        format!("/api/sessions/{id}/read")
    };
    let read_marks = || {
        let conn = world.app.db.lock();
        let marks: Vec<Option<i64>> = conn
            .prepare("SELECT read_at FROM sessions ORDER BY id")
            .unwrap()
            .query_map([], |row| row.get(0))
            .unwrap()
            .map(Result::unwrap)
            .collect();
        json!(marks)
    };
    prove_operation(
        &world.app,
        &world.who,
        "POST",
        &seed,
        &read_marks,
        &super::tests::accepted_empty(),
        &ok,
    )
    .await;
}

#[tokio::test]
async fn a_session_upload_needs_the_request_shape() {
    let world = World::new();
    let seed = || {
        format!(
            "/api/sessions/{}/uploads?filename=note.txt",
            world.session()
        )
    };
    prove_operation(
        &world.app,
        &world.who,
        "POST",
        &seed,
        &|| world.requests(),
        &[
            raw("header, plain text", "text/plain"),
            raw("header, octet-stream", "application/octet-stream"),
        ],
        &ok,
    )
    .await;
    // The Node was reached once per accepted upload and by nothing else.
    let log = world.log.lock().unwrap();
    assert_eq!(log.len(), world.who.len() * 2, "{log:?}");
    assert!(
        log.iter()
            .all(|line| line.contains("/uploads?filename=note.txt"))
    );
}
