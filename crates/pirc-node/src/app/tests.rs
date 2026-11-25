use super::*;

#[test]
fn workspace_bodies() {
    let parsed = |value: Value| new_workspace(&value, false);
    assert!(parsed(json!({ "kind": "chat", "displayName": "Trip" })).is_err());
    let chat = parsed(json!({ "mode": "chat", "displayName": " Trip " })).unwrap();
    assert_eq!(chat.mode.as_str(), "chat");
    assert_eq!(chat.display_name, "Trip");
    assert!(!chat.restore_existing);
    for restore in [false, true] {
        assert_eq!(
            parsed(json!({ "path": "~/p", "displayName": "P", "restoreExisting": restore }))
                .unwrap()
                .restore_existing,
            restore
        );
    }
    for restore in [Value::Null, json!("true"), json!(1), json!({})] {
        assert!(
            parsed(json!({ "path": "~/p", "displayName": "P", "restoreExisting": restore }))
                .is_err()
        );
    }
    let directory = parsed(json!({ "path": " ~/p ", "displayName": "P", "extra": 1 })).unwrap();
    assert_eq!(directory.mode.as_str(), "directory");
    assert_eq!(directory.path.as_deref(), Some("~/p"));
    assert_eq!(
        parsed(json!({ "mode": "research", "displayName": "P" }))
            .unwrap()
            .mode
            .as_str(),
        "research"
    );
    assert!(new_workspace(&json!({ "displayName": "P" }), true).is_err());
    assert_eq!(
        new_workspace(&json!({ "displayName":"P", "path":"~/repo" }), true)
            .unwrap()
            .mode
            .as_str(),
        "directory"
    );
    for bad in [
        json!({ "kind": "chat", "displayName": "  " }),
        json!({ "mode": "research", "kind": "chat", "displayName": "P" }),
        json!({ "mode": "INVALID", "displayName": "P" }),
        json!({ "mode": null, "displayName": "P" }),
        json!({ "path": "/p", "displayName": "x".repeat(201) }),
        json!([]),
    ] {
        assert!(parsed(bad).is_err());
    }
}

fn per_session_mode(id: &str) -> pirc_protocol::Mode {
    let mut mode = pirc_protocol::mode::default_work();
    mode.id = ModeId::new(id).unwrap();
    mode.workdir = pirc_protocol::mode::Workdir::PerSession;
    mode.repository = false;
    mode.workspace_memory = false;
    mode.project_config = false;
    mode
}

fn request(id: Option<&str>, body: Value) -> Request {
    Request {
        method: pirc_protocol::HttpMethod::Post,
        path: String::new(),
        query: Vec::new(),
        params: id
            .map(|id| vec![("id".into(), id.into())])
            .unwrap_or_default(),
        user: "test-user".into(),
        body: Body::Json(body),
    }
}

pub(crate) async fn workspace_test_node() -> (tempfile::TempDir, Node) {
    workspace_test_node_grants(false).await
}
/// The same Node, with `<dir>/grant-root` as its only folder grant root (C6a).
pub(crate) async fn workspace_test_node_grants(grants: bool) -> (tempfile::TempDir, Node) {
    let dir = tempfile::tempdir_in("/tmp").unwrap();
    let node = start_workspace_node(dir.path(), grants).await;
    (dir, node)
}
/// Start (or, after `close`, restart) the test Node on the state in `dir`.
pub(crate) async fn start_workspace_node(dir: &Path, grants: bool) -> Node {
    use pirc_config::Env;
    use pirc_protocol::NodeRole;
    use pirc_protocol::mode::default_work;

    let root = dir.canonicalize().unwrap();
    let state = root.join("state").display().to_string();
    let config_dir = root.join("config").display().to_string();
    let home = root.display().to_string();
    std::fs::create_dir_all(root.join("grant-root")).unwrap();
    let grant_roots = serde_json::json!([root.join("grant-root")]).to_string();
    let mut vars = vec![
        ("PIRC_NODE_ID", "test-node"),
        ("PIRC_NODE_TOKEN", "0123456789abcdef0123456789abcdef"),
        ("PIRC_DAEMON_URL", "ws://127.0.0.1:8787"),
        ("PIRC_ALLOWED_USERS", "test-user"),
        ("PIRC_STATE_DIR", state.as_str()),
        ("PIRC_CONFIG_DIR", config_dir.as_str()),
        ("PIRC_MODES", "directory,review"),
        ("PIRC_BROWSER", "false"),
        ("HOME", home.as_str()),
    ];
    if grants {
        vars.push(("PIRC_GRANT_ROOTS", grant_roots.as_str()));
    }
    let env = Env::new(vars, &root);
    let config = NodeConfig::load(&env, NodeRole::Node).unwrap();
    let node = crate::services::Services::start(config, env).await.unwrap();
    let mut review = default_work();
    review.id = ModeId::new("review").unwrap();
    node.replace_modes(vec![default_work(), review]).await;
    node
}

#[tokio::test]
async fn workspace_removal_check_is_read_only_and_uses_authoritative_node_state() {
    use crate::store::{CommandStatus, RunStatus, RunnerState};
    let (_dir, node) = workspace_test_node().await;
    let root = Path::new(node.env.get("HOME").unwrap());
    let repository = root.join("repository");
    std::fs::create_dir(&repository).unwrap();
    node.db
        .lock()
        .add_workspace(
            "repo",
            "test-node",
            "Repository",
            &repository.to_string_lossy(),
            ModeId::new("directory").unwrap(),
        )
        .unwrap();
    let session = node
        .db
        .lock()
        .create_session("repo", "/private/session", "test-user")
        .unwrap();
    let check = || workspace_removal_check(node.clone(), request(Some("repo"), json!({})));
    let changes = node.db.lock().total_changes();
    let idle = check().await.unwrap();
    assert_eq!(idle.status, 200);
    assert_eq!(idle.body, Some(json!({ "idle": true })));
    assert_eq!(node.db.lock().total_changes(), changes);

    // No link/activity publication is needed for any of these refusals.
    let run = node.db.lock().create_run(&session.id).unwrap();
    for status in [
        RunStatus::Queued,
        RunStatus::Running,
        RunStatus::WaitingInput,
        RunStatus::Stopping,
    ] {
        node.db.lock().update_run(&run, status, None).unwrap();
        let changes = node.db.lock().total_changes();
        assert_eq!(check().await.unwrap_err().status, 409);
        assert_eq!(node.db.lock().total_changes(), changes);
    }
    node.db
        .lock()
        .update_run(&run, RunStatus::Succeeded, None)
        .unwrap();
    assert!(check().await.is_ok());
    node.db
        .lock()
        .set_runner_state(&session.id, RunnerState::Starting)
        .unwrap();
    assert_eq!(check().await.unwrap_err().status, 409);
    node.db
        .lock()
        .set_runner_state(&session.id, RunnerState::Ready)
        .unwrap();
    assert!(check().await.is_ok());
    node.db
        .lock()
        .receive_command(
            "command",
            &session.id,
            "hash",
            &json!({"type":"prompt","message":"hello"}),
        )
        .unwrap();
    for status in [CommandStatus::Received, CommandStatus::Dispatched] {
        node.db
            .lock()
            .update_command("command", status, None, None)
            .unwrap();
        assert_eq!(check().await.unwrap_err().status, 409);
    }
    node.db
        .lock()
        .update_command("command", CommandStatus::Accepted, None, None)
        .unwrap();
    assert!(check().await.is_ok());
    assert_eq!(
        node.writes.acquire(&session.id, &repository),
        crate::write_broker::WriteGrant::Granted
    );
    assert_eq!(check().await.unwrap_err().status, 409);
    node.writes.release(&session.id);
    assert!(check().await.is_ok());

    // A removed owner row must not make its still-running host command idle.
    node.db.lock().execute("INSERT INTO host_command_runs(id,session_id,workspace_id,runner_epoch,incarnation,request_id,state,created_at,updated_at) VALUES('orphan','deleted-session','repo',0,'old-node','request','running',1,1)",[]).unwrap();
    crate::host_commands::resources::record(
        &node.db.lock(),
        "orphan",
        &[repository.to_string_lossy().into_owned()],
    )
    .unwrap();
    assert_eq!(check().await.unwrap_err().code, "host_write_pending");
    node.db
        .lock()
        .execute(
            "UPDATE host_command_runs SET state='settled' WHERE id='orphan'",
            [],
        )
        .unwrap();
    assert!(check().await.is_ok());

    let other = node
        .db
        .lock()
        .create_session("repo", "/private/other", "other-user")
        .unwrap();
    let changes = node.db.lock().total_changes();
    assert_eq!(check().await.unwrap_err().status, 403);
    assert_eq!(node.db.lock().total_changes(), changes);
    node.db
        .lock()
        .execute(
            "UPDATE sessions SET owner_user=NULL WHERE id=?",
            [&other.id],
        )
        .unwrap();
    assert_eq!(check().await.unwrap_err().status, 403);
    assert!(repository.is_dir());
    node.close().await;
}

#[tokio::test]
async fn workspace_removal_check_rejects_per_session_workspaces_and_missing_ones() {
    let (_dir, node) = workspace_test_node().await;
    node.replace_modes(vec![
        pirc_protocol::mode::default_work(),
        per_session_mode("review"),
    ])
    .await;
    let created = create_workspace(
        node.clone(),
        request(None, json!({ "mode":"review", "displayName":"Review" })),
    )
    .await
    .unwrap();
    let id = created.body.unwrap()["workspace"]["id"]
        .as_str()
        .unwrap()
        .to_owned();
    assert_eq!(
        workspace_removal_check(node.clone(), request(Some(&id), json!({})))
            .await
            .unwrap_err()
            .status,
        400
    );
    // A workspace whose mode is unavailable may still be cleaned up.
    node.replace_modes(Vec::new()).await;
    assert!(
        workspace_removal_check(node.clone(), request(Some(&id), json!({})))
            .await
            .is_ok()
    );
    assert_eq!(
        workspace_removal_check(node.clone(), request(Some("missing"), json!({})))
            .await
            .unwrap_err()
            .status,
        404
    );
    node.close().await;
}

#[tokio::test]
async fn restore_existing_workspace_preserves_identity_history_and_files() {
    let (_dir, node) = workspace_test_node().await;
    let root = Path::new(node.env.get("HOME").unwrap());
    let repository = root.join("repository");
    std::fs::create_dir(&repository).unwrap();
    let file = repository.join("keep.txt");
    std::fs::write(&file, "workspace contents").unwrap();
    let first = create_workspace(
        node.clone(),
        request(
            None,
            json!({ "path": repository, "displayName": "Original" }),
        ),
    )
    .await
    .unwrap();
    assert_eq!(first.status, 201);
    let original = first.body.unwrap()["workspace"].clone();
    let id = original["id"].as_str().unwrap();
    let response = crate::session_creation::internal(
        node.clone(),
        request(None, json!({ "workspaceId": id })),
    )
    .await
    .unwrap();
    let session_id = response.body.unwrap()["session"]["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let session = node.db.lock().get_session(&session_id).unwrap();
    let history = Path::new(&session.private_session_path).join("session.jsonl");
    std::fs::write(&history, "saved session history\n").unwrap();
    let saved_session = serde_json::to_value(&session).unwrap();
    let saved_workspace = serde_json::to_value(node.db.lock().get_workspace(id).unwrap()).unwrap();
    let changes = node.db.lock().total_changes();

    for flag in [None, Some(false)] {
        let mut body = json!({ "path": repository, "displayName": "Replacement" });
        if let Some(flag) = flag {
            body["restoreExisting"] = json!(flag);
        }
        let error = create_workspace(node.clone(), request(None, body))
            .await
            .unwrap_err();
        assert_eq!(error.status, 409);
        assert_eq!(error.code, "conflict");
    }
    // Resolve a symlink and ~/ alias before looking up the existing row.
    let alias = root.join("alias");
    std::os::unix::fs::symlink(&repository, &alias).unwrap();
    for path in [repository.display().to_string(), "~/alias".to_owned()] {
        let restored = create_workspace(
            node.clone(),
            request(
                None,
                json!({
                    "path": path, "displayName": "Replacement", "restoreExisting": true,
                }),
            ),
        )
        .await
        .unwrap();
        assert_eq!(restored.status, 201);
        assert_eq!(restored.body.unwrap()["workspace"], original);
    }
    let mismatch = create_workspace(
            node.clone(),
            request(None, json!({
                "path": repository, "displayName": "Review", "mode": "review", "restoreExisting": true,
            })),
        )
        .await
        .unwrap_err();
    assert_eq!(mismatch.status, 409);
    assert_eq!(mismatch.code, "conflict");
    assert_eq!(node.db.lock().total_changes(), changes);
    assert_eq!(node.db.lock().list_workspaces().unwrap().len(), 1);
    assert_eq!(
        serde_json::to_value(node.db.lock().get_workspace(id).unwrap()).unwrap(),
        saved_workspace
    );
    assert_eq!(
        serde_json::to_value(node.db.lock().get_session(&session_id).unwrap()).unwrap(),
        saved_session
    );
    assert_eq!(node.db.lock().workspace_sessions(id).unwrap().len(), 1);
    assert_eq!(
        std::fs::read_to_string(&history).unwrap(),
        "saved session history\n"
    );
    assert_eq!(
        std::fs::read_to_string(&file).unwrap(),
        "workspace contents"
    );

    // The flag still creates a new workspace if no row matches.
    let fresh = root.join("fresh");
    std::fs::create_dir(&fresh).unwrap();
    let response = create_workspace(
        node.clone(),
        request(
            None,
            json!({ "path": fresh, "displayName": "Fresh", "restoreExisting": true }),
        ),
    )
    .await
    .unwrap();
    assert_ne!(response.body.unwrap()["workspace"]["id"], original["id"]);
    node.close().await;
}

#[tokio::test]
async fn restore_existing_workspace_does_not_bypass_path_validation_or_deletion_fence() {
    let (_dir, node) = workspace_test_node().await;
    let root = Path::new(node.env.get("HOME").unwrap());
    let file = root.join("file");
    std::fs::write(&file, "not a directory").unwrap();
    // Seed even invalid paths: an existing row must not bypass validation.
    let outside = tempfile::tempdir_in("/tmp").unwrap();
    let state = node.config.state_dir.canonicalize().unwrap();
    let sensitive = root.join(".ssh");
    std::fs::create_dir(&sensitive).unwrap();
    let outside = outside.path().canonicalize().unwrap();
    for (index, path) in [&state, &sensitive, &outside].into_iter().enumerate() {
        node.db
            .lock()
            .add_workspace(
                &format!("invalid_{index}"),
                "test-node",
                "Invalid",
                &path.to_string_lossy(),
                ModeId::new("directory").unwrap(),
            )
            .unwrap();
    }
    let changes = node.db.lock().total_changes();
    for (path, status) in [
        ("relative".to_owned(), 400),
        (root.join("missing").display().to_string(), 400),
        (file.display().to_string(), 400),
        (root.display().to_string(), 403),
        (state.display().to_string(), 403),
        (sensitive.display().to_string(), 403),
        (outside.display().to_string(), 403),
    ] {
        let error = create_workspace(
            node.clone(),
            request(
                None,
                json!({ "path": path, "displayName": "Restored", "restoreExisting": true }),
            ),
        )
        .await
        .unwrap_err();
        assert_eq!(error.status, status, "{path}: {error:?}");
    }
    assert_eq!(node.db.lock().total_changes(), changes);
    let repository = root.join("repository");
    std::fs::create_dir(&repository).unwrap();
    node.db
        .lock()
        .add_workspace(
            "deleting",
            "test-node",
            "Deleting",
            &repository.to_string_lossy(),
            ModeId::new("directory").unwrap(),
        )
        .unwrap();
    node.db
        .lock()
        .begin_workspace_deletion("deleting", "test-user")
        .unwrap();
    let changes = node.db.lock().total_changes();
    let error = create_workspace(
        node.clone(),
        request(
            None,
            json!({ "path": repository, "displayName": "Restored", "restoreExisting": true }),
        ),
    )
    .await
    .unwrap_err();
    assert_eq!(error.status, 409);
    assert!(error.message.contains("being deleted"));
    assert_eq!(node.db.lock().total_changes(), changes);
    assert!(repository.is_dir());
    node.close().await;
}

#[tokio::test]
async fn chat_role_accepting_only_custom_or_no_modes_does_not_seed_chat() {
    use pirc_config::Env;
    use pirc_protocol::NodeRole;
    for accepted in ["research", ""] {
        let dir = tempfile::tempdir_in("/tmp").unwrap();
        let root = dir.path().canonicalize().unwrap();
        let state = root.join("state").display().to_string();
        let config_dir = root.join("config").display().to_string();
        let home = root.display().to_string();
        let env = Env::new(
            [
                ("PIRC_NODE_ID", "test-node"),
                ("PIRC_NODE_TOKEN", "0123456789abcdef0123456789abcdef"),
                ("PIRC_DAEMON_URL", "ws://127.0.0.1:8787"),
                ("PIRC_ALLOWED_USERS", "test-user"),
                ("PIRC_STATE_DIR", state.as_str()),
                ("PIRC_CONFIG_DIR", config_dir.as_str()),
                ("PIRC_MODES", accepted),
                ("PIRC_BROWSER", "false"),
                ("HOME", home.as_str()),
            ],
            &root,
        );
        let config = NodeConfig::load(&env, NodeRole::Chat).unwrap();
        let node = crate::services::Services::start(config, env).await.unwrap();
        assert!(node.db.lock().list_workspaces().unwrap().is_empty());
        node.close().await;
    }
}

#[tokio::test]
async fn custom_modes_create_by_workdir_and_unavailable_sessions_are_read_only() {
    use pirc_config::Env;
    use pirc_protocol::NodeRole;
    use pirc_protocol::mode::default_work;

    // Keep the inference Unix-socket pathname below macOS SUN_LEN.
    let dir = tempfile::tempdir_in("/tmp").unwrap();
    let root = dir.path().canonicalize().unwrap();
    let real_state = root.join("state");
    std::fs::create_dir(&real_state).unwrap();
    let state_link = root.join("state-link");
    std::os::unix::fs::symlink(&real_state, &state_link).unwrap();
    let state = state_link.display().to_string();
    let config_dir = root.join("config").display().to_string();
    let home = root.display().to_string();
    let env = Env::new(
        [
            ("PIRC_NODE_ID", "test-node"),
            ("PIRC_NODE_TOKEN", "0123456789abcdef0123456789abcdef"),
            ("PIRC_DAEMON_URL", "ws://127.0.0.1:8787"),
            ("PIRC_ALLOWED_USERS", "test-user"),
            ("PIRC_STATE_DIR", state.as_str()),
            ("PIRC_CONFIG_DIR", config_dir.as_str()),
            ("PIRC_MODES", "research"),
            ("PIRC_BROWSER", "false"),
            ("HOME", home.as_str()),
        ],
        &root,
    );
    let config = NodeConfig::load(&env, NodeRole::Node).unwrap();
    let node = crate::services::Services::start(config, env).await.unwrap();
    let create = || {
        request(
            None,
            json!({ "mode": "research", "displayName": "Research" }),
        )
    };
    assert_eq!(
        create_workspace(node.clone(), create())
            .await
            .unwrap_err()
            .code,
        "mode_unavailable"
    );
    let mode = per_session_mode("research");
    node.replace_modes(vec![mode]).await;
    // A per-session mode works on a normal node, not only the chat role.
    let response = create_workspace(node.clone(), create()).await.unwrap();
    let workspace = response.body.unwrap()["workspace"].clone();
    assert_eq!(workspace["mode"], "research");
    let workspace_id = workspace["id"].as_str().unwrap();
    assert!(
        Path::new(workspace["canonicalPath"].as_str().unwrap())
            .starts_with(root.join("state/chat"))
    );
    let response = crate::session_creation::internal(
        node.clone(),
        request(None, json!({ "workspaceId": workspace_id })),
    )
    .await
    .unwrap();
    let session_id = response.body.unwrap()["session"]["id"]
        .as_str()
        .unwrap()
        .to_owned();
    // Editing a definition cannot reinterpret a managed assistant root
    // as a repository, or make its saved session writable there.
    let mut changed = default_work();
    changed.id = ModeId::new("research").unwrap();
    node.replace_modes(vec![changed]).await;
    let repository = root.join("repository");
    std::fs::create_dir(&repository).unwrap();
    let response = create_workspace(
        node.clone(),
        request(
            None,
            json!({
                "mode": "research", "displayName": "Repo", "path": repository,
            }),
        ),
    )
    .await
    .unwrap();
    let repository_id = response.body.unwrap()["workspace"]["id"]
        .as_str()
        .unwrap()
        .to_owned();
    assert_eq!(
        crate::session_creation::internal(
            node.clone(),
            request(None, json!({ "workspaceId": workspace_id }))
        )
        .await
        .unwrap_err()
        .code,
        "mode_unavailable"
    );
    assert_eq!(
        snapshot(node.clone(), request(Some(&session_id), json!({})))
            .await
            .unwrap()
            .status,
        200
    );
    node.replace_modes(vec![per_session_mode("research")]).await;
    // Conversely a saved repository must never become a full assistant
    // root merely because its mode file now uses per-session workdirs.
    assert_eq!(
        crate::session_creation::internal(
            node.clone(),
            request(None, json!({ "workspaceId": repository_id }))
        )
        .await
        .unwrap_err()
        .code,
        "mode_unavailable"
    );
    node.replace_modes(Vec::new()).await;
    assert_eq!(
        crate::session_creation::internal(
            node.clone(),
            request(None, json!({ "workspaceId": workspace_id }))
        )
        .await
        .unwrap_err()
        .code,
        "mode_unavailable"
    );
    let empty = || request(Some(&session_id), json!({}));
    assert_eq!(snapshot(node.clone(), empty()).await.unwrap().status, 200);
    assert_eq!(control(node.clone(), empty()).await.unwrap().status, 200);
    assert_eq!(
        rename_session(node.clone(), empty())
            .await
            .unwrap_err()
            .code,
        "mode_unavailable"
    );
    assert_eq!(
        acquire(node.clone(), empty()).await.unwrap_err().code,
        "mode_unavailable"
    );
    assert_eq!(
        heartbeat(node.clone(), empty()).await.unwrap_err().code,
        "mode_unavailable"
    );
    assert_eq!(
        release(node.clone(), empty()).await.unwrap_err().code,
        "mode_unavailable"
    );
    assert_eq!(
        answer(node.clone(), empty()).await.unwrap_err().code,
        "mode_unavailable"
    );
    assert_eq!(
        upload(node.clone(), empty()).await.unwrap_err().code,
        "mode_unavailable"
    );
    assert_eq!(
        deliver(node.clone(), empty()).await.unwrap_err().code,
        "mode_unavailable"
    );
    let command_request = request(
        Some(&session_id),
        json!({
            "commandId": "test-command", "clientId": "client", "generation": 1,
            "payload": { "type": "prompt", "message": "hello" }
        }),
    );
    assert_eq!(
        command(node.clone(), command_request)
            .await
            .unwrap_err()
            .code,
        "mode_unavailable"
    );
    node.close().await;
}

#[test]
fn home_paths_join_as_node_did() {
    let home = Path::new("/home/u");
    for (path, expected) in [
        ("~/p", "/home/u/p"),
        ("~//etc", "/home/u/etc"),
        ("~///etc/x", "/home/u/etc/x"),
        ("~/../v", "/home/v"),
        ("/abs", "/abs"),
        ("rel", "rel"),
    ] {
        assert_eq!(
            requested_path(home, path),
            PathBuf::from(expected),
            "{path}"
        );
    }
}

#[test]
fn deletion_entries_go_even_on_panic() {
    let deletions = Arc::new(Deletions::default());
    let finished: Deletion = async { Ok(()) }.boxed().shared();
    deletions.0.lock().unwrap().insert("s".into(), finished);
    let entry = DeletionEntry {
        deletions: deletions.clone(),
        session_id: "s".into(),
    };
    let panicked = std::panic::catch_unwind(std::panic::AssertUnwindSafe(move || {
        let _entry = entry;
        panic!("cleanup failed");
    }));
    assert!(panicked.is_err());
    assert!(deletions.0.lock().unwrap().is_empty());
}

#[test]
fn command_payloads_as_zod_outputs_them() {
    let payload = command_payload(&json!({ "type": "prompt", "message": "hi",
            "uploadIds": ["u"], "extra": true }))
    .unwrap();
    assert_eq!(
        serde_json::to_value(&payload).unwrap(),
        json!({ "type": "prompt", "message": "hi", "uploadIds": ["u"] })
    );
    assert_eq!(
        command_payload(&json!({ "type": "send_now", "queue": "followUp",
                "index": 1.0, "message": "m" }))
        .unwrap(),
        CommandPayload::SendNow {
            queue: "followUp".into(),
            index: 1,
            message: "m".into()
        }
    );
    for value in [
        json!({ "type": "edit_message", "entryId": "e1", "message": "revised" }),
        json!({ "type": "switch_branch", "entryId": "e2" }),
    ] {
        assert_eq!(
            serde_json::to_value(command_payload(&value).unwrap()).unwrap(),
            value
        );
    }
    for bad in [
        json!({ "type": "edit_message", "entryId": "e1", "message": "" }),
        json!({ "type": "edit_message", "message": "revised" }),
        json!({ "type": "switch_branch", "entryId": "" }),
        json!({ "type": "switch_branch", "entryId": null }),
        json!({ "type": "switch_branch", "entryId": "e".repeat(201) }),
        json!({ "type": "prompt", "message": "" }),
        json!({ "type": "prompt", "message": "m", "uploadIds": [""] }),
        json!({ "type": "send_now", "queue": "x", "index": 0, "message": "m" }),
        json!({ "type": "send_now", "queue": "steering", "index": -1, "message": "m" }),
        json!({ "type": "set_thinking", "level": "huge" }),
        json!({ "type": "set_approval_mode", "mode": "yolo" }),
        json!({ "type": "nope" }),
    ] {
        assert!(command_payload(&bad).is_err(), "{bad}");
    }
}

#[test]
fn answers_and_deliveries() {
    assert_eq!(
        Value::Object(interaction_answer(&json!({ "value": "a", "confirmed": true })).unwrap()),
        json!({ "value": "a" })
    );
    assert_eq!(
        Value::Object(
            interaction_answer(&json!({ "value": "a", "values": [1], "confirmed": false }))
                .unwrap()
        ),
        json!({ "confirmed": false })
    );
    assert_eq!(
        Value::Object(interaction_answer(&json!({ "cancelled": true })).unwrap()),
        json!({ "cancelled": true })
    );
    assert!(interaction_answer(&json!({ "cancelled": false })).is_err());
    assert!(
        delivery(&json!({ "customType": "scheduled-run", "content": "c",
            "role": "reviewer", "thinking": "high" }))
        .is_ok()
    );
    for bad in [
        json!({ "customType": "other", "content": "c" }),
        json!({ "customType": "scheduled-run", "content": "" }),
        json!({ "customType": "scheduled-run", "content": "c", "role": "Bad" }),
        json!({ "customType": "scheduled-run", "content": "c", "thinking": "x" }),
        json!({ "customType": "scheduled-run", "content": "c", "details": null }),
        json!({ "customType": "scheduled-run", "content": "c", "role": null }),
        json!({ "customType": "scheduled-run", "content": "c", "model": null }),
        json!({ "customType": "scheduled-run", "content": "c", "thinking": null }),
    ] {
        assert!(delivery(&bad).is_err(), "{bad}");
    }
    assert_eq!(sniff_image(b"GIF89a..."), Some("image/gif"));
    assert_eq!(sniff_image(b"RIFF\0\0\0\0WEBPVP8"), Some("image/webp"));
    assert_eq!(sniff_image(b"hello"), None);
}

#[tokio::test]
async fn session_creation_routes_are_durable_strict_and_read_only_on_lookup() {
    use crate::router::Router;
    use pirc_protocol::{HttpMethod, NodeHttpRequest};

    let (_dir, node) = workspace_test_node().await;
    node.db
        .lock()
        .add_workspace(
            "repo",
            "test-node",
            "Repository",
            "/repo",
            ModeId::new("directory").unwrap(),
        )
        .unwrap();
    let router = Router::new(routes(&node.config));
    let wire = |method, url: &str, payload| NodeHttpRequest {
        method,
        url: url.into(),
        user: "test-user".into(),
        payload,
        body_base64: None,
        content_type: None,
    };
    let body = json!({"operationId":"first-send-1", "workspaceId":"repo", "submissionHash":"a".repeat(64)});
    let create = || {
        wire(
            HttpMethod::Post,
            "/api/session-creations",
            Some(body.clone()),
        )
    };
    let first = router.handle(&node, create()).await;
    assert_eq!(first.status, 200, "{:?}", first.body);
    let first_body = first.body.unwrap();
    assert_eq!(first_body["creation"]["state"], "ready");
    assert!(first_body["creation"].get("submissionHash").is_none());
    let duplicate = router.handle(&node, create()).await;
    assert_eq!(duplicate.status, 200);
    assert_eq!(duplicate.body, Some(first_body.clone()));
    let changes = node.db.lock().total_changes();
    let status = router
        .handle(
            &node,
            wire(HttpMethod::Get, "/api/session-creations/first-send-1", None),
        )
        .await;
    assert_eq!(status.status, 200);
    assert_eq!(status.body, Some(first_body.clone()));
    assert_eq!(node.db.lock().total_changes(), changes);
    assert_eq!(
        router
            .handle(
                &node,
                wire(HttpMethod::Get, "/api/session-creations/missing", None)
            )
            .await
            .status,
        404
    );
    let mut extra = body.clone();
    extra["user"] = json!("other-user");
    assert_eq!(
        router
            .handle(
                &node,
                wire(HttpMethod::Post, "/api/session-creations", Some(extra))
            )
            .await
            .status,
        400
    );
    let mut too_long = body.clone();
    too_long["operationId"] = json!("a".repeat(101));
    assert_eq!(
        router
            .handle(
                &node,
                wire(HttpMethod::Post, "/api/session-creations", Some(too_long))
            )
            .await
            .status,
        400
    );
    let mut forbidden = create();
    forbidden.user = "not-allowed".into();
    assert_eq!(router.handle(&node, forbidden).await.status, 403);

    // The Gateway's own empty sessions (schedules, delegations) are separate.
    let internal = router
        .handle(
            &node,
            wire(
                HttpMethod::Post,
                "/api/session-creations/internal",
                Some(json!({"workspaceId":"repo"})),
            ),
        )
        .await;
    assert_eq!(internal.status, 201);
    assert_ne!(
        internal.body.unwrap()["session"]["id"],
        first_body["creation"]["sessionId"]
    );

    // Lookup stays available when execution is no longer enabled for the mode.
    node.replace_modes(vec![]).await;
    assert!(router.handle(&node, create()).await.status >= 400);
    assert_eq!(
        router
            .handle(
                &node,
                wire(HttpMethod::Get, "/api/session-creations/first-send-1", None)
            )
            .await
            .status,
        200
    );
    let id = first_body["creation"]["sessionId"].as_str().unwrap();
    node.db
        .lock()
        .begin_session_deletion(id, "test-user")
        .unwrap();
    let deleted = router.handle(&node, create()).await;
    assert_eq!(deleted.status, 200);
    assert_eq!(deleted.body.unwrap()["creation"]["state"], "deleting");
}
