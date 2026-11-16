//! State-changing routes whose effect lives on a Node or in the session
//! index: a request of the wrong shape must leave all of it untouched.

use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use pirc_node::project_files;
use pirc_node::store::Workspace;
use pirc_protocol::mode::default_chat;
use pirc_protocol::{HttpMethod, ModeId, NodeHttpRequest, NodeHttpResponse, NodeRole};
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
    /// The project's directory on the Node, where the Node's own code writes.
    root: PathBuf,
    counter: AtomicUsize,
    _dir: tempfile::TempDir,
}

fn node_workspace(root: &std::path::Path) -> Workspace {
    Workspace {
        id: "chats".into(),
        host_id: "work".into(),
        display_name: "Chats".into(),
        canonical_path: root.display().to_string(),
        defaults: Default::default(),
        mode: ModeId::new("chat").unwrap(),
    }
}

fn filename(url: &str) -> String {
    let query = url.split_once('?').map_or("", |(_, query)| query);
    form_urlencoded::parse(query.as_bytes())
        .find(|(name, _)| name == "filename")
        .map(|(_, value)| value.into_owned())
        .unwrap_or_default()
}

impl World {
    fn new() -> Self {
        let (app, dir) = fixture();
        let root = dir.path().join("project");
        std::fs::create_dir_all(&root).unwrap();
        let log: Log = Arc::default();
        app.db
            .lock()
            .sync_remote_workspaces(
                "work",
                &[("chats".into(), "Chats".into(), ModeId::new("chat").unwrap())],
            )
            .unwrap();
        let node_root = root.clone();
        let node_log = log.clone();
        app.nodes.set_test_node(
            crate::nodes::ConnectedNode {
                id: "work".into(),
                role: NodeRole::Node,
                modes: vec![ModeId::new("chat").unwrap()],
                workspaces: vec![pirc_protocol::RegisteredWorkspace {
                    id: "chats".into(),
                    display_name: "Chats".into(),
                    mode: ModeId::new("chat").unwrap(),
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
                if request.method == HttpMethod::Post
                    && request.url.starts_with("/api/workspaces/chats/files?")
                {
                    // The Node's own project-file code does the write.
                    let bytes = STANDARD.decode(request.body_base64.unwrap()).unwrap();
                    let file = project_files::write(
                        &node_workspace(&node_root),
                        &filename(&request.url),
                        &bytes,
                        &default_chat(),
                    )
                    .unwrap();
                    return Ok(NodeHttpResponse {
                        status: 201,
                        body: Some(json!({ "file": file.json() })),
                    });
                }
                if request.method == HttpMethod::Delete
                    && request.url.starts_with("/api/workspaces/chats/files?")
                {
                    let query = request.url.split_once('?').map_or("", |(_, query)| query);
                    let name = form_urlencoded::parse(query.as_bytes())
                        .find(|(name, _)| name == "name")
                        .map(|(_, value)| value.into_owned())
                        .unwrap_or_default();
                    project_files::remove(&node_workspace(&node_root), &name, &default_chat())
                        .unwrap();
                    return Ok(NodeHttpResponse {
                        status: 204,
                        body: None,
                    });
                }
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
            root,
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
                "work:chats",
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

    fn files(&self) -> Value {
        let mut files = serde_json::Map::new();
        let dir = self.root.join("files");
        if let Ok(entries) = std::fs::read_dir(dir) {
            for entry in entries.flatten() {
                files.insert(
                    entry.file_name().to_string_lossy().into_owned(),
                    json!(String::from_utf8_lossy(
                        &std::fs::read(entry.path()).unwrap()
                    )),
                );
            }
        }
        Value::Object(files)
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

#[tokio::test]
async fn creating_a_project_file_needs_the_request_shape() {
    let world = World::new();
    let seed = || {
        format!(
            "/api/workspaces/work:chats/files?filename=new-{}.txt",
            world.next()
        )
    };
    prove_operation(
        &world.app,
        &world.who,
        "POST",
        &seed,
        &|| json!([world.files(), world.requests()]),
        &[raw("header, plain text", "text/plain")],
        &ok,
    )
    .await;
    // Nothing but the accepted uploads reached the Node, which wrote the files.
    assert_eq!(world.requests().as_array().unwrap().len(), world.who.len());
    assert_eq!(world.files().as_object().unwrap().len(), world.who.len());
}

#[tokio::test]
async fn replacing_a_project_file_needs_the_request_shape() {
    let world = World::new();
    let seed = || {
        // The Node's own code puts the original in place.
        project_files::write(
            &node_workspace(&world.root),
            "report.txt",
            b"original",
            &default_chat(),
        )
        .unwrap();
        "/api/workspaces/work:chats/files?filename=report.txt".to_owned()
    };
    prove_operation(
        &world.app,
        &world.who,
        "POST",
        &seed,
        &|| json!([world.files(), world.requests()]),
        &[raw("header, plain text", "text/plain")],
        &ok,
    )
    .await;
    assert_eq!(world.files()["report.txt"], "replacement");
    // A form cannot even touch the original.
    seed();
    let before = world.files();
    for who in &world.who {
        for forged in super::tests::forged() {
            super::tests::send(
                &world.app,
                who,
                "POST",
                "/api/workspaces/work:chats/files?filename=report.txt",
                &forged,
            )
            .await;
        }
    }
    assert_eq!(world.files(), before);
    assert_eq!(world.files()["report.txt"], "original");
}

#[tokio::test]
async fn removing_a_project_file_needs_the_request_shape() {
    let world = World::new();
    let seed = || {
        project_files::write(
            &node_workspace(&world.root),
            "report.txt",
            b"original",
            &default_chat(),
        )
        .unwrap();
        "/api/workspaces/work:chats/files?name=report.txt".to_owned()
    };
    prove_operation(
        &world.app,
        &world.who,
        "DELETE",
        &seed,
        &|| json!([world.files(), world.requests()]),
        &[probe("header, no body", &[("x-pirc-request", "1")], "")],
        &|status, _| status != 415,
    )
    .await;
}

#[tokio::test]
async fn stopping_a_delegation_needs_the_request_shape() {
    let world = World::new();
    let seed = || {
        let target = world.session();
        let assistant = world.session();
        let id = format!("d{:08}", world.next());
        world
            .app
            .db
            .lock()
            .execute(
                "INSERT INTO delegations (id,owner_user,assistant_session_id,workspace_id,title,task,status,target_session_id,expires_at,created_at,updated_at) VALUES (?,?,?,'work:chats','t','x','running',?,0,0,0)",
                params![id, USER, assistant, target],
            )
            .unwrap();
        format!("/api/delegations/{id}/stop")
    };
    let snapshot = || {
        let conn = world.app.db.lock();
        let rows: Vec<(String, String)> = conn
            .prepare("SELECT id,status FROM delegations ORDER BY id")
            .unwrap()
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))
            .unwrap()
            .map(Result::unwrap)
            .collect();
        json!([rows, world.requests()])
    };
    prove_operation(
        &world.app,
        &world.who,
        "POST",
        &seed,
        &snapshot,
        &[probe("header, no body", &[("x-pirc-request", "1")], "")],
        // The Node answers the control requests with a canned reply: whatever
        // the handler makes of it, it ran and called the Node.
        &|status, body| status != 415 && body["error"]["code"] != "request_shape_required",
    )
    .await;
}
