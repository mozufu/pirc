//! Exercise command locking and persisted outcomes through the real manager.
//! The fake process answers RPC lines; no sandbox or external provider runs.
use super::super::{CommandPayload, InitialSettings};
use super::*;
use crate::store::{CommandStatus, Store};
use crate::workspace_memory::tests::Fixture;

fn register(f: &Fixture) -> (Arc<Runner>, mpsc::UnboundedReceiver<Outbound>) {
    let row = f.node.db.lock().get_session(&f.current).unwrap();
    let (stdin, lines) = mpsc::unbounded_channel();
    let runner = Arc::new(Runner {
        node: Arc::downgrade(&f.node),
        session_id: row.id.clone(),
        workspace: f.node.db.lock().get_workspace(&row.workspace_id).unwrap(),
        mode: f.mode.clone(),
        epoch: row.runner_epoch,
        pid: None,
        prepared: Prepared::new(
            PathBuf::new(),
            vec![],
            vec![],
            Default::default(),
            vec![],
            None,
            || {},
        ),
        persistence: None,
        inference: None,
        launch: None,
        stdin,
        inner: Mutex::default(),
        view: Mutex::default(),
        reaped: AtomicBool::new(true),
        exited: watch::channel(false).0,
    });
    f.node.runners.lock().runners.insert(row.id, runner.clone());
    (runner, lines)
}
fn receive(f: &Fixture, id: &str, payload: &CommandPayload) {
    let json = serde_json::to_value(payload).unwrap();
    f.node
        .db
        .lock()
        .receive_command(id, &f.current, &crate::util::payload_hash(&json), &json)
        .unwrap();
}
async fn next(lines: &mut mpsc::UnboundedReceiver<Outbound>) -> Value {
    let line = tokio::time::timeout(Duration::from_secs(2), lines.recv())
        .await
        .unwrap()
        .unwrap();
    serde_json::from_str(&line.line).unwrap()
}
fn answer(runner: &Arc<Runner>, request: &Value, body: Value) {
    let mut reply = body;
    reply["type"] = json!("response");
    reply["id"] = request["id"].clone();
    runner.handle_value(reply).unwrap();
}

#[tokio::test]
async fn stop_overtakes_pending_admission_and_unknown_receipt_stays_deduplicated() {
    let f = Fixture::new().await;
    let (runner, mut lines) = register(&f);
    let lease = f
        .node
        .db
        .lock()
        .acquire_lease(&f.current, "phone", false, 60_000)
        .unwrap();
    let payload = CommandPayload::Prompt {
        message: "first".into(),
        upload_ids: None,
    };
    receive(&f, "first-send", &payload);
    let send = {
        let node = f.node.clone();
        let session = f.current.clone();
        let payload = payload.clone();
        tokio::spawn(async move {
            node.runners
                .dispatch(
                    &session,
                    "first-send",
                    &payload,
                    "alice",
                    ("phone", lease.generation),
                )
                .await
        })
    };
    let prompt = next(&mut lines).await;
    assert_eq!(prompt["type"], "prompt");
    assert!(!send.is_finished());
    assert_eq!(
        f.node.db.lock().get_command("first-send").unwrap().status,
        CommandStatus::Dispatched
    );
    let settings = CommandPayload::SetThinking {
        level: "low".into(),
    };
    receive(&f, "settings", &settings);
    let change = {
        let node = f.node.clone();
        let session = f.current.clone();
        tokio::spawn(async move {
            node.runners
                .dispatch(
                    &session,
                    "settings",
                    &settings,
                    "alice",
                    ("phone", lease.generation),
                )
                .await
        })
    };
    receive(&f, "stop", &CommandPayload::Stop);
    let stop = {
        let node = f.node.clone();
        let session = f.current.clone();
        tokio::spawn(async move {
            node.runners
                .dispatch(
                    &session,
                    "stop",
                    &CommandPayload::Stop,
                    "alice",
                    ("phone", lease.generation),
                )
                .await
        })
    };
    let clear = next(&mut lines).await;
    assert_eq!(clear["type"], "clear_queue");
    answer(&runner, &clear, json!({"success":true}));
    let abort = next(&mut lines).await;
    assert_eq!(abort["type"], "abort");
    answer(&runner, &abort, json!({"success":true}));
    stop.await.unwrap().unwrap();
    assert!(!send.is_finished());
    answer(
        &runner,
        &prompt,
        json!({"success":false,"errorCode":"admission_outcome_unknown","error":"inspect before retrying"}),
    );
    send.await.unwrap().unwrap();
    let settings = next(&mut lines).await;
    assert_eq!(settings["type"], "set_thinking_level");
    answer(&runner, &settings, json!({"success":true}));
    change.await.unwrap().unwrap();
    let json = serde_json::to_value(&payload).unwrap();
    let (row, duplicate) = f
        .node
        .db
        .lock()
        .receive_command(
            "first-send",
            &f.current,
            &crate::util::payload_hash(&json),
            &json,
        )
        .unwrap();
    assert!(duplicate);
    assert_eq!(row.status, CommandStatus::OutcomeUnknown);
    assert!(lines.try_recv().is_err());
    assert_eq!(
        f.node.db.lock().get_command("stop").unwrap().status,
        CommandStatus::Accepted
    );
    runner.exit(Some(0), None);
    f.node.close().await;
}

#[tokio::test]
async fn dropping_an_admission_answer_is_unknown_even_with_a_live_runner() {
    let f = Fixture::new().await;
    let (runner, mut lines) = register(&f);
    let lease = f
        .node
        .db
        .lock()
        .acquire_lease(&f.current, "phone", false, 60_000)
        .unwrap();
    let payload = CommandPayload::Prompt {
        message: "first".into(),
        upload_ids: None,
    };
    receive(&f, "first-send", &payload);
    let send = {
        let node = f.node.clone();
        let session = f.current.clone();
        tokio::spawn(async move {
            node.runners
                .dispatch(
                    &session,
                    "first-send",
                    &payload,
                    "alice",
                    ("phone", lease.generation),
                )
                .await
        })
    };
    let prompt = next(&mut lines).await;
    runner.lock().pending.remove(prompt["id"].as_str().unwrap());
    assert!(runner.alive());
    send.await.unwrap().unwrap();
    assert_eq!(
        f.node.db.lock().get_command("first-send").unwrap().status,
        CommandStatus::OutcomeUnknown
    );
    runner.exit(Some(0), None);
    f.node.close().await;
}

fn initial(f: &Fixture) -> (CommandPayload, InitialSettings, i64) {
    let payload = CommandPayload::Prompt {
        message: "immutable first text".into(),
        upload_ids: Some(vec![]),
    };
    receive(f, "initial-send", &payload);
    let db = f.node.db.lock();
    db.execute("INSERT INTO session_creations(owner_user,operation_id,workspace_id,submission_hash,session_id,state,created_at) VALUES('alice','creation-1','repo',?1,?2,'ready',1)",rusqlite::params!["a".repeat(64),f.current]).unwrap();
    db.execute("INSERT INTO creation_initial_admissions(owner_user,operation_id,session_id,command_id,input_hash,created_at,updated_at) VALUES('alice','creation-1',?1,'initial-send','hash',1,1)",[&f.current]).unwrap();
    let lease = db
        .acquire_lease(&f.current, "phone", false, 60_000)
        .unwrap();
    (
        payload,
        InitialSettings {
            provider: "fake".into(),
            model_id: "frozen-model".into(),
            thinking: pirc_protocol::ThinkingLevel::Low,
        },
        lease.generation,
    )
}
#[tokio::test]
async fn initial_settings_and_message_share_one_serialized_admission() {
    let f = Fixture::new().await;
    let (runner, mut lines) = register(&f);
    let (payload, settings, generation) = initial(&f);
    let node = f.node.clone();
    let session = f.current.clone();
    let send = tokio::spawn(async move {
        node.runners
            .dispatch_initial(
                &session,
                "initial-send",
                &payload,
                "alice",
                ("phone", generation),
                &settings,
            )
            .await
    });
    let model = next(&mut lines).await;
    assert_eq!(model["type"], "set_model");
    assert_eq!(model["modelId"], "frozen-model");
    assert!(lines.try_recv().is_err());
    answer(&runner, &model, json!({"success":true}));
    let thinking = next(&mut lines).await;
    assert_eq!(thinking["type"], "set_thinking_level");
    assert_eq!(thinking["level"], "low");
    answer(&runner, &thinking, json!({"success":true}));
    let prompt = next(&mut lines).await;
    assert_eq!(prompt["type"], "prompt");
    assert_eq!(prompt["message"], "immutable first text");
    answer(&runner, &prompt, json!({"success":true}));
    send.await.unwrap().unwrap();
    assert_eq!(
        f.node.db.lock().get_command("initial-send").unwrap().status,
        CommandStatus::Accepted
    );
    assert!(
        crate::session_creation::admission::require_generic(&f.node.db.lock(), &f.current).is_ok()
    );
    assert!(lines.try_recv().is_err());
    runner.exit(Some(0), None);
    f.node.close().await;
}
#[tokio::test]
async fn stop_during_initial_configuration_permanently_prevents_the_prompt_from_being_queued() {
    let f = Fixture::new().await;
    let (runner, mut lines) = register(&f);
    let (payload, settings, generation) = initial(&f);
    let node = f.node.clone();
    let session = f.current.clone();
    let send = tokio::spawn(async move {
        node.runners
            .dispatch_initial(
                &session,
                "initial-send",
                &payload,
                "alice",
                ("phone", generation),
                &settings,
            )
            .await
    });
    let model = next(&mut lines).await;
    assert_eq!(model["type"], "set_model");
    crate::session_creation::admission::request_stop(&f.node.db.lock(), &f.current, "alice")
        .unwrap();
    answer(&runner, &model, json!({"success":true}));
    assert!(send.await.unwrap().is_err());
    assert_eq!(
        f.node.db.lock().get_command("initial-send").unwrap().status,
        CommandStatus::Rejected
    );
    assert!(lines.try_recv().is_err());
    assert!(
        crate::session_creation::admission::require_sendable(
            &f.node.db.lock(),
            &f.current,
            "initial-send",
            "alice"
        )
        .is_err()
    );
    runner.exit(Some(0), None);
    f.node.close().await;
}

#[tokio::test]
async fn command_environment_is_rechecked_after_ensure_without_sending_stale_rpc() {
    let f = Fixture::new().await;
    let (runner, mut lines) = register(&f);
    let lease = f
        .node
        .db
        .lock()
        .acquire_lease(&f.current, "phone", false, 60_000)
        .unwrap();
    let payload = CommandPayload::SetThinking {
        level: "high".into(),
    };
    receive(&f, "versioned", &payload);
    let binding = json!({"version":1,"execution":{"generation":7}});
    crate::command_environment::record(&f.node.db.lock(), "versioned", Some(&binding), false)
        .unwrap();
    let mut link = f.node.link.open();
    f.node.link.set_registered(link.id);
    f.node.agent_gateway.connect();
    let dispatch = {
        let node = f.node.clone();
        let session = f.current.clone();
        tokio::spawn(async move {
            node.runners
                .dispatch(
                    &session,
                    "versioned",
                    &payload,
                    "alice",
                    ("phone", lease.generation),
                )
                .await
        })
    };
    for index in 0..2 {
        let text = tokio::time::timeout(Duration::from_secs(2), link.recv())
            .await
            .unwrap()
            .unwrap();
        link.written(&text);
        let request: Value = serde_json::from_str(&text).unwrap();
        assert_eq!(request["type"], "agent_request");
        assert_eq!(request["op"], "command.authority");
        assert_eq!(request["args"]["binding"], binding);
        let (status, body) = if index == 0 {
            (
                200,
                json!({"result":{"commandId":"versioned","binding":binding}}),
            )
        } else {
            (
                409,
                json!({"error":{"code":"stale_environment","message":"changed"}}),
            )
        };
        f.node
            .agent_gateway
            .receive(request["requestId"].as_str().unwrap(), status, Some(body));
    }
    assert_eq!(
        dispatch.await.unwrap().unwrap_err().code,
        "stale_environment"
    );
    assert!(lines.try_recv().is_err());
    assert_eq!(
        f.node.db.lock().get_command("versioned").unwrap().status,
        CommandStatus::Rejected
    );
    // Retrying the original receipt cannot turn it into newly admitted work.
    let raw = serde_json::to_value(CommandPayload::SetThinking {
        level: "high".into(),
    })
    .unwrap();
    assert!(
        f.node
            .db
            .lock()
            .receive_command(
                "versioned",
                &f.current,
                &crate::util::payload_hash(&raw),
                &raw
            )
            .unwrap()
            .1
    );
    runner.exit(Some(0), None);
    f.node.close().await;
}

#[tokio::test]
async fn unavailable_authority_rejects_before_start_without_sending_rpc() {
    let f = Fixture::new().await;
    let (runner, mut lines) = register(&f);
    let lease = f
        .node
        .db
        .lock()
        .acquire_lease(&f.current, "phone", false, 60_000)
        .unwrap();
    let payload = CommandPayload::SetThinking {
        level: "high".into(),
    };
    receive(&f, "offline", &payload);
    crate::command_environment::record(
        &f.node.db.lock(),
        "offline",
        Some(&json!({"version":1})),
        false,
    )
    .unwrap();
    let error = f
        .node
        .runners
        .dispatch(
            &f.current,
            "offline",
            &payload,
            "alice",
            ("phone", lease.generation),
        )
        .await
        .unwrap_err();
    assert_eq!(error.code, "command_authority_unavailable");
    assert!(lines.try_recv().is_err());
    assert_eq!(
        f.node.db.lock().get_command("offline").unwrap().status,
        CommandStatus::Rejected
    );
    runner.exit(Some(0), None);
    f.node.close().await;
}

#[tokio::test]
async fn local_control_takeover_during_authority_roundtrip_never_sends_rpc() {
    let f = Fixture::new().await;
    let (runner, mut lines) = register(&f);
    let lease = f
        .node
        .db
        .lock()
        .acquire_lease(&f.current, "phone", false, 60_000)
        .unwrap();
    let payload = CommandPayload::SetThinking {
        level: "high".into(),
    };
    receive(&f, "takeover", &payload);
    let binding = json!({"version":1,"execution":{"generation":7}});
    crate::command_environment::record(&f.node.db.lock(), "takeover", Some(&binding), false)
        .unwrap();
    let mut link = f.node.link.open();
    f.node.link.set_registered(link.id);
    f.node.agent_gateway.connect();
    let dispatch = {
        let node = f.node.clone();
        let session = f.current.clone();
        tokio::spawn(async move {
            node.runners
                .dispatch(
                    &session,
                    "takeover",
                    &payload,
                    "alice",
                    ("phone", lease.generation),
                )
                .await
        })
    };
    let text = tokio::time::timeout(Duration::from_secs(2), link.recv())
        .await
        .unwrap()
        .unwrap();
    link.written(&text);
    let request: Value = serde_json::from_str(&text).unwrap();
    assert_eq!(request["op"], "command.authority");
    // A takeover already reached Node, but the earlier Gateway reply is still in flight.
    let newer = f
        .node
        .db
        .lock()
        .acquire_lease(&f.current, "web", true, 60_000)
        .unwrap();
    assert!(newer.generation > lease.generation);
    f.node.agent_gateway.receive(
        request["requestId"].as_str().unwrap(),
        200,
        Some(json!({"result":{"commandId":"takeover","binding":binding}})),
    );
    assert!(dispatch.await.unwrap().is_err());
    assert!(lines.try_recv().is_err());
    assert_eq!(
        f.node.db.lock().get_command("takeover").unwrap().status,
        CommandStatus::Rejected
    );
    runner.exit(Some(0), None);
    f.node.close().await;
}

#[tokio::test]
async fn corrupted_saved_attachment_is_rejected_before_admission_and_stays_deduplicated() {
    let f = Fixture::new().await;
    let (runner, mut lines) = register(&f);
    let lease = f
        .node
        .db
        .lock()
        .acquire_lease(&f.current, "phone", false, 60_000)
        .unwrap();
    let upload = crate::store::UploadRow {
        id: "saved-image".into(),
        owner_user: "alice".into(),
        mime_type: "image/png".into(),
        byte_size: 4,
        storage_name: "saved-image.bin".into(),
        sha256: crate::util::sha256_hex(b"test"),
        kind: crate::store::UploadKind::Image,
        filename: Some("saved.png".into()),
        workspace_id: Some("repo".into()),
        session_id: Some(f.current.clone()),
    };
    f.node.db.lock().create_upload(&upload).unwrap();
    let source = f.node.config.uploads_dir.join(&upload.storage_name);
    std::fs::write(&source, b"evil").unwrap();
    for (id, payload) in [
        (
            "bad-prompt",
            CommandPayload::Prompt {
                message: "read image".into(),
                upload_ids: Some(vec![upload.id.clone()]),
            },
        ),
        (
            "bad-steer",
            CommandPayload::Steer {
                message: "read image".into(),
                upload_ids: Some(vec![upload.id.clone()]),
            },
        ),
        (
            "bad-follow-up",
            CommandPayload::FollowUp {
                message: "read image".into(),
                upload_ids: Some(vec![upload.id.clone()]),
            },
        ),
    ] {
        receive(&f, id, &payload);
        let error = f
            .node
            .runners
            .dispatch(
                &f.current,
                id,
                &payload,
                "alice",
                ("phone", lease.generation),
            )
            .await
            .unwrap_err();
        assert_eq!(error.code, "attachment_storage_unavailable");
        assert_eq!(
            f.node.db.lock().get_command(id).unwrap().status,
            CommandStatus::Rejected
        );
        assert!(lines.try_recv().is_err());
        // Repairing storage cannot turn a duplicate request into a new send.
        std::fs::write(&source, b"test").unwrap();
        let body = serde_json::to_value(&payload).unwrap();
        let (receipt, duplicate) = f
            .node
            .db
            .lock()
            .receive_command(id, &f.current, &crate::util::payload_hash(&body), &body)
            .unwrap();
        assert!(duplicate);
        assert_eq!(receipt.status, CommandStatus::Rejected);
        assert!(lines.try_recv().is_err());
        std::fs::write(&source, b"evil").unwrap();
    }
    let runs: i64 = f
        .node
        .db
        .lock()
        .query_row(
            "SELECT COUNT(*) FROM runs WHERE session_id=?",
            [&f.current],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(runs, 0);
    runner.exit(Some(0), None);
    f.node.close().await;
}

#[tokio::test]
async fn transition_blocks_queued_input_and_late_approval_but_keeps_stop_available() {
    let f = Fixture::new().await;
    let (runner, mut lines) = register(&f);
    let lease = f
        .node
        .db
        .lock()
        .acquire_lease(&f.current, "phone", false, 60_000)
        .unwrap();
    let first = CommandPayload::Prompt {
        message: "already sent".into(),
        upload_ids: None,
    };
    receive(&f, "before-transition", &first);
    let sending = {
        let node = f.node.clone();
        let session = f.current.clone();
        tokio::spawn(async move {
            node.runners
                .dispatch(
                    &session,
                    "before-transition",
                    &first,
                    "alice",
                    ("phone", lease.generation),
                )
                .await
        })
    };
    let prompt = next(&mut lines).await;
    let queued = CommandPayload::Prompt {
        message: "must not execute".into(),
        upload_ids: None,
    };
    receive(&f, "queued-transition", &queued);
    let waiting = {
        let node = f.node.clone();
        let session = f.current.clone();
        tokio::spawn(async move {
            node.runners
                .dispatch(
                    &session,
                    "queued-transition",
                    &queued,
                    "alice",
                    ("phone", lease.generation),
                )
                .await
        })
    };
    let interaction = {
        let db = f.node.db.lock();
        db.create_interaction(
            &f.current,
            runner.epoch(),
            "approve",
            "confirm",
            &Map::new(),
            crate::util::now_ms() + 60_000,
        )
        .unwrap()
    };
    let intent = crate::execution_fences::Intent {
        operation_id: "switch".into(),
        plan_hash: "a".repeat(64),
        expected_workspace_id: "repo".into(),
        expected_runner_epoch: runner.epoch(),
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
        f.node
            .db
            .lock()
            .claim_interaction(
                &interaction.id,
                &f.current,
                runner.epoch(),
                &json!({"confirmed":true})
            )
            .unwrap_err()
            .code,
        "environment_transition_pending"
    );
    // Stop still overtakes the pending answer and can clear the old queue.
    receive(&f, "stop-transition", &CommandPayload::Stop);
    let stop = {
        let node = f.node.clone();
        let session = f.current.clone();
        tokio::spawn(async move {
            node.runners
                .dispatch(
                    &session,
                    "stop-transition",
                    &CommandPayload::Stop,
                    "alice",
                    ("phone", lease.generation),
                )
                .await
        })
    };
    let clear = next(&mut lines).await;
    assert_eq!(clear["type"], "clear_queue");
    answer(&runner, &clear, json!({"success":true}));
    let abort = next(&mut lines).await;
    assert_eq!(abort["type"], "abort");
    answer(&runner, &abort, json!({"success":true}));
    stop.await.unwrap().unwrap();
    answer(&runner, &prompt, json!({"success":false,"error":"stopped"}));
    sending.await.unwrap().unwrap();
    assert_eq!(
        waiting.await.unwrap().unwrap_err().code,
        "environment_transition_pending"
    );
    assert_eq!(
        f.node
            .db
            .lock()
            .get_command("queued-transition")
            .unwrap()
            .status,
        CommandStatus::Rejected
    );
    assert!(lines.try_recv().is_err());
    // The final spawn boundary refuses even a direct stale prepared start.
    let row = f.node.db.lock().get_session(&f.current).unwrap();
    let error = spawn_child(
        &f.node,
        &row,
        &runner.workspace,
        &f.mode,
        &runner.prepared,
        None,
    )
    .unwrap_err();
    assert_eq!(error.code, "environment_transition_pending");
    runner.exit(Some(0), None);
    f.node.close().await;
}

#[tokio::test]
async fn disconnected_drain_caller_does_not_abandon_or_duplicate_supervisor_shutdown() {
    let f = Fixture::new().await;
    let (runner, mut lines) = register(&f);
    let lease = f
        .node
        .db
        .lock()
        .acquire_lease(&f.current, "phone", false, 60_000)
        .unwrap();
    let intent = crate::execution_fences::Intent {
        operation_id: "drain-reply-lost".into(),
        plan_hash: "a".repeat(64),
        expected_workspace_id: "repo".into(),
        expected_runner_epoch: runner.epoch(),
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
    let first = {
        let node = f.node.clone();
        let session = f.current.clone();
        tokio::spawn(async move {
            crate::execution_fences::drain(&node, "alice", &session, "drain-reply-lost").await
        })
    };
    let abort = next(&mut lines).await;
    assert_eq!(abort["type"], "abort");
    first.abort();
    assert!(first.await.unwrap_err().is_cancelled());
    let resumed = {
        let node = f.node.clone();
        let session = f.current.clone();
        tokio::spawn(async move {
            crate::execution_fences::drain(&node, "alice", &session, "drain-reply-lost").await
        })
    };
    // The join cannot finish until the original supervised stop finishes.
    tokio::task::yield_now().await;
    assert!(!resumed.is_finished());
    assert!(lines.try_recv().is_err());
    answer(&runner, &abort, json!({"success":true}));
    runner.exit(Some(0), None);
    let receipt = tokio::time::timeout(Duration::from_secs(2), resumed)
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    assert_eq!(receipt.state, "supervisor_drained");
    assert!(!receipt.revocation_confirmed && !receipt.target_installed);
    assert!(crate::execution_fences::require_open(&f.node.db.lock(), &f.current).is_err());
    f.node.close().await;
}
