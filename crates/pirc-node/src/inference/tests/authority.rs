use super::*;
use crate::store::Store;

async fn open(config: &InferenceConfig, session_label: &str) -> UnixStream {
    let mut body =
        serde_json::to_value(project(&request(AbortController::new().signal()))).unwrap();
    body["sessionId"] = json!(session_label);
    let mut stream = UnixStream::connect(&config.socket_path).await.unwrap();
    stream
        .write_all(&post(config, "/inference", &body.to_string()))
        .await
        .unwrap();
    stream
}
async fn finish(stream: &mut UnixStream) -> String {
    let mut bytes = Vec::new();
    tokio::time::timeout(Duration::from_secs(3), stream.read_to_end(&mut bytes))
        .await
        .unwrap()
        .unwrap();
    String::from_utf8(bytes).unwrap()
}
fn starts(sent: &Sent) -> Vec<String> {
    sent.lock()
        .unwrap()
        .iter()
        .filter_map(|m| {
            if let NodeMessage::ModelStart { request_id, .. } = m {
                Some(request_id.clone())
            } else {
                None
            }
        })
        .collect()
}

#[tokio::test]
async fn scoped_cancel_ignores_request_labels_preserves_peer_and_retires_old_tokens() {
    let (a, sent, _dir) = relay(Duration::from_secs(600), |_, _| {}).await;
    let b = scoped(a.relay.clone(), "peer", 1);
    let mut stream_a = open(&a.config, "peer").await; // Agent-controlled cache label is not authority.
    until(|| starts(&sent).len() == 1).await;
    let mut stream_b = open(&b.config, "session").await;
    until(|| starts(&sent).len() == 2).await;
    let ids = starts(&sent);
    assert_ne!(a.config.token, b.config.token);
    assert!(fetch_remote_models(&a.relay.config).await.is_err()); // No Node-wide bearer.
    assert_eq!(
        fetch_remote_models(&b.config).await.unwrap().inference,
        Some(b.config.clone())
    );

    a.revoke_session("session");
    a.revoke_session("session");
    let text = finish(&mut stream_a).await;
    assert!(text.contains("unavailable"), "{text}");
    assert_eq!(
        sent.lock()
            .unwrap()
            .iter()
            .filter(|m| matches!(m, NodeMessage::ModelCancel { .. }))
            .count(),
        1
    );
    assert_eq!(request_id(sent.lock().unwrap().last().unwrap()), ids[0]);
    a.receive(GatewayMessage::ModelDelta {
        request_id: ids[0].clone(),
        delta: AssistantDelta::TextDelta {
            content_index: 0,
            delta: "late-secret".into(),
        },
    });
    assert!(!text.contains("late-secret"));
    assert_eq!(a.lock().pending.len(), 1);
    b.receive(GatewayMessage::ModelEnd {
        request_id: ids[1].clone(),
        message: Message::Assistant(final_message()),
    });
    assert!(finish(&mut stream_b).await.contains("hello"));
    assert!(fetch_remote_models(&a.config).await.is_err());
    assert_eq!(
        raw(&a.config, &post(&a.config, "/inference", "{}")).await.0,
        401
    );

    let newer = scoped(a.relay.clone(), "session", 2);
    assert_ne!(newer.config.token, a.config.token);
    a._lease.close(); // A delayed old-epoch teardown must not revoke its replacement.
    assert_eq!(
        fetch_remote_models(&newer.config).await.unwrap().inference,
        Some(newer.config.clone())
    );
    let old_config = newer.config.clone();
    drop(newer);
    assert!(fetch_remote_models(&old_config).await.is_err());
    b.close().await;
}

#[tokio::test]
async fn body_wait_cannot_reuse_a_revoked_capability() {
    let (relay, sent, _dir) = relay(Duration::from_secs(600), |_, _| {}).await;
    let body = serde_json::to_value(project(&request(AbortController::new().signal())))
        .unwrap()
        .to_string();
    let bytes = post(&relay.config, "/inference", &body);
    let mut stream = UnixStream::connect(&relay.config.socket_path)
        .await
        .unwrap();
    stream.write_all(&bytes[..bytes.len() - 1]).await.unwrap();
    until(|| relay.lock().receiving == 1).await;
    relay._lease.close();
    stream.write_all(&bytes[bytes.len() - 1..]).await.unwrap();
    assert!(finish(&mut stream).await.contains("unavailable"));
    assert!(
        sent.lock().unwrap().is_empty(),
        "No start or cancel for a refused body"
    );
    until(|| relay.connections.load(Ordering::Acquire) == 0).await;
    assert_eq!(relay.lock().receiving, 0);
    relay.close().await;
}

#[tokio::test]
async fn real_node_gate_rechecks_epoch_workspace_mode_and_durable_fence_after_body_wait() {
    let f = crate::workspace_memory::tests::Fixture::new().await;
    let dir = tempfile::tempdir().unwrap();
    let sent: Sent = Arc::default();
    let sink = sent.clone();
    let relay = Relay::start(
        dir.path(),
        Arc::new(move |message| {
            sink.lock().unwrap().push(message.clone());
            true
        }),
        Arc::new(models),
        Duration::from_secs(600),
        super::super::authority::node_gate(Arc::downgrade(&f.node)),
    )
    .await
    .unwrap();
    let lease = relay.register(Identity {
        session: f.current.clone(),
        workspace: "repo".into(),
        epoch: 0,
        mode: f.mode.clone(),
    });
    assert!(fetch_remote_models(&lease.config).await.is_ok());
    let body = serde_json::to_value(project(&request(AbortController::new().signal())))
        .unwrap()
        .to_string();
    let bytes = post(&lease.config, "/inference", &body);
    let mut stream = UnixStream::connect(&lease.config.socket_path)
        .await
        .unwrap();
    stream.write_all(&bytes[..bytes.len() - 1]).await.unwrap();
    until(|| relay.lock().receiving == 1).await;
    f.node.db.lock().increment_epoch(&f.current).unwrap();
    stream.write_all(&bytes[bytes.len() - 1..]).await.unwrap();
    assert!(finish(&mut stream).await.contains("unavailable"));
    assert!(sent.lock().unwrap().is_empty());
    assert!(fetch_remote_models(&lease.config).await.is_err());
    let fresh = relay.register(Identity {
        session: f.current.clone(),
        workspace: "repo".into(),
        epoch: 1,
        mode: f.mode.clone(),
    });
    assert!(fetch_remote_models(&fresh.config).await.is_ok());
    let wrong = relay.register(Identity {
        session: f.current.clone(),
        workspace: "other".into(),
        epoch: 1,
        mode: f.mode.clone(),
    });
    assert!(fetch_remote_models(&wrong.config).await.is_err());
    let mut changed = f.mode.clone();
    changed.workspace_memory = !changed.workspace_memory;
    f.node
        .modes
        .write()
        .unwrap()
        .insert(changed.id.clone(), changed);
    assert!(fetch_remote_models(&fresh.config).await.is_err());
    f.node
        .modes
        .write()
        .unwrap()
        .insert(f.mode.id.clone(), f.mode.clone());
    {
        let db = f.node.db.lock();
        let control = db
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
            control.generation,
        )
        .unwrap();
    }
    // Durable database guard still refuses even without an in-memory revoke call.
    assert!(fetch_remote_models(&fresh.config).await.is_err());
    assert!(sent.lock().unwrap().is_empty());
    relay.close().await;
    f.node.close().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn revocation_serializes_with_admission_and_disallows_later_work() {
    let (relay, sent, _dir) = relay(Duration::from_secs(600), |_, _| {}).await;
    let scope = relay
        .authenticate(&format!("Bearer {}", relay.config.token))
        .unwrap();
    let entered = Arc::new(std::sync::Barrier::new(2));
    let release = Arc::new(std::sync::Barrier::new(2));
    let admitted = {
        let relay = relay.relay.clone();
        let scope = scope.clone();
        let entered = entered.clone();
        let release = release.clone();
        tokio::task::spawn_blocking(move || {
            relay.authorized(&scope, &mut || {
                entered.wait();
                release.wait();
            })
        })
    };
    // Waiting occurs on blocking workers; it does not hold a Tokio executor thread.
    tokio::task::spawn_blocking(move || entered.wait())
        .await
        .unwrap();
    let revoking = {
        let relay = relay.relay.clone();
        tokio::task::spawn_blocking(move || relay.revoke_session("session"))
    };
    // The held admission cannot be bypassed, and after release no later admission succeeds.
    release.wait();
    assert!(admitted.await.unwrap());
    revoking.await.unwrap();
    let mut ran = false;
    assert!(!relay.authorized(&scope, &mut || ran = true));
    assert!(!ran);
    assert!(sent.lock().unwrap().is_empty());
    relay.close().await;
}
