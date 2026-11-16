//! Reconciling an unknown first-message outcome. The Gateway state machine runs
//! against a small stand-in Node here; the Node's own behaviour (void against its
//! real admission code) is tested in `pirc-node` and, end to end, below.
use super::*;
use crate::conversation_submissions::{
    acceptance::{
        accept_intent, advance,
        tests::{caps, connected, identity, model, register},
    },
    attachments,
    dispatch::tests::{evidence, operation},
    tests::{call, count, disk_app},
};
use crate::{app::App, db::Db, db::Lease};
use pirc_protocol::{NodeHttpRequest, NodeHttpResponse};
use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::{Arc, Mutex};

/// What the stand-in Node does with the next admission it is sent.
#[derive(Clone, Copy, PartialEq)]
enum Delivery {
    /// Received and answered.
    Reply,
    /// Received and admitted, but the answer never reaches the Gateway.
    LostReply,
    /// Never received (the frame is still on its way): the Gateway times out.
    Dropped,
}
#[derive(Default)]
struct World {
    deliveries: VecDeque<Delivery>,
    creation: String,
    admitted: HashMap<String, Value>,
    order: Vec<String>,
    voided: HashSet<String>,
    posts: Vec<String>,
    refused: Vec<String>,
    dropped: Vec<NodeHttpRequest>,
    void_calls: usize,
    void_supported: bool,
    lose_void_replies: usize,
}
type Shared = Arc<Mutex<World>>;

fn timeout() -> ApiError {
    ApiError::new(
        504,
        "node_timeout",
        "Node response timed out; outcome may be unknown",
    )
}
fn respond(status: u16, body: Value) -> ApiResult<NodeHttpResponse> {
    Ok(NodeHttpResponse {
        status,
        body: Some(body),
    })
}
/// One request, handled as the Node would. Admitting and voiding are exclusive.
fn handle(world: &mut World, r: &NodeHttpRequest) -> ApiResult<NodeHttpResponse> {
    let creation = world.creation.clone();
    if r.url.ends_with("/capabilities") {
        let mut caps = caps();
        caps["canRetryInitialAdmission"] = json!(true);
        if world.void_supported {
            caps["canVoidInitialAdmission"] = json!(true);
        }
        return respond(200, caps);
    }
    let empty = json!({"operationId":creation,"sessionId":"session-stable","state":"not_submitted","command":null,"inputHash":null,"stopRequested":false,"stopConfirmed":false});
    if r.method == pirc_protocol::HttpMethod::Get {
        if let Some((_, id)) = r.url.split_once("/admission/attempts/") {
            return match world.admitted.get(id) {
                Some(proof) => respond(200, json!({"admission":proof})),
                None => respond(404, json!({"error":{"code":"not_found"}})),
            };
        }
        let head = world.order.last().and_then(|id| world.admitted.get(id));
        return respond(200, json!({"admission":head.unwrap_or(&empty)}));
    }
    let payload = r.payload.clone().unwrap_or(Value::Null);
    if r.url.ends_with("/admission/void") {
        world.void_calls += 1;
        let id = payload["commandId"].as_str().unwrap().to_owned();
        let answer = match world.admitted.get(&id) {
            Some(proof) => {
                json!({"void":{"result":"admission","operationId":creation,"commandId":id},"admission":proof})
            }
            None => {
                world.voided.insert(id.clone());
                json!({"void":{"result":"voided","operationId":creation,"commandId":id}})
            }
        };
        if world.lose_void_replies > 0 {
            world.lose_void_replies -= 1;
            return Err(timeout());
        }
        return respond(200, answer);
    }
    let input = if r.url.ends_with("/admission/retry") {
        payload["admission"].clone()
    } else {
        payload
    };
    let id = input["commandId"].as_str().unwrap().to_owned();
    match world.deliveries.pop_front().unwrap_or(Delivery::Reply) {
        Delivery::Dropped => {
            world.dropped.push(r.clone());
            Err(timeout())
        }
        delivery => {
            if world.voided.contains(&id) {
                world.refused.push(id);
                return respond(409, json!({"error":{"code":"command_voided"}}));
            }
            let mut proof = evidence(&input, "accepted");
            proof["operationId"] = json!(creation);
            world.admitted.insert(id.clone(), proof.clone());
            world.order.push(id.clone());
            world.posts.push(id);
            if delivery == Delivery::LostReply {
                return Err(timeout());
            }
            respond(200, json!({"admission":proof}))
        }
    }
}
fn install(app: &AppState, void_supported: bool, deliveries: &[Delivery]) -> Shared {
    let world: Shared = Arc::new(Mutex::new(World {
        creation: operation(app),
        void_supported,
        deliveries: deliveries.iter().copied().collect(),
        ..Default::default()
    }));
    let shared = world.clone();
    app.nodes.set_test_node(connected(), move |r| {
        handle(&mut shared.lock().unwrap(), &r)
    });
    world
}

/// A frozen first message (with a file) ready to dispatch, on disk.
async fn ready_with_file() -> (AppState, tempfile::TempDir, String) {
    let (app, dir) = disk_app();
    model(&app);
    register(&app);
    crate::conversation_submissions::acceptance::tests::prepared(&app, true);
    attachments::stage(&app, "alice", "draft-1", "file-1", b"test").unwrap();
    accept_intent(&app, &identity(), "draft-1").await.unwrap();
    let row = advance(&app, &identity(), "draft-1").await.unwrap();
    hold(&app, &row.session_id);
    (app, dir, row.session_id)
}
fn hold(app: &AppState, session: &str) {
    app.db
        .lock()
        .mirror_lease(
            session,
            &Lease {
                client_id: "phone".into(),
                generation: 1,
                expires_at: now_ms() + 600_000,
            },
            "alice",
            false,
        )
        .unwrap();
}
async fn dispatch(app: &AppState) -> Value {
    let (code, body) = call(
        app,
        "POST",
        "/api/conversation-submissions/draft-1/dispatch",
        Some("alice"),
        None,
        Some(json!({"clientId":"phone","generation":1})),
    )
    .await;
    assert_eq!(code, 200, "{body}");
    body["preparation"].clone()
}
async fn receipt(app: &AppState) -> Value {
    let (code, body) = call(
        app,
        "GET",
        "/api/conversation-submissions/draft-1/receipt",
        Some("alice"),
        None,
        None,
    )
    .await;
    assert_eq!(code, 200, "{body}");
    body["preparation"].clone()
}
async fn retry(app: &AppState, previous: &str, id: &str) -> Value {
    let (code, body) = call(
        app,
        "POST",
        "/api/conversation-submissions/draft-1/retry",
        Some("alice"),
        None,
        Some(json!({"retryId":id,"previousCommandId":previous,"clientId":"phone","generation":1})),
    )
    .await;
    assert_eq!(code, 200, "{body}");
    body["preparation"].clone()
}
fn gateway_commands(app: &AppState) -> Vec<(String, String)> {
    let db = app.db.lock();
    let mut q = db
        .prepare("SELECT id,status FROM commands ORDER BY created_at,id")
        .unwrap();
    q.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
        .unwrap()
        .map(Result::unwrap)
        .collect()
}
/// D11: the frozen text and the accepted file bytes are still readable.
fn retained(app: &AppState) {
    let db = app.db.lock();
    let row = lookup(&db, "alice", "draft-1").unwrap();
    let spec = row.submission.expect("the frozen submission is kept");
    assert_eq!(spec.message, "Keep this first message");
    assert_eq!(spec.attachments.len(), 1);
    let path = app
        .config
        .state_dir
        .join("submission-staging")
        .join(&row.session_id)
        .join("file-1.bin");
    assert_eq!(
        attachments::read_verified(&path, &spec.attachments[0]).unwrap(),
        b"test"
    );
    assert_eq!(count(&db, "conversation_submission_attachments"), 1);
    assert_eq!(count(&db, "conversation_submission_cleanup"), 0);
}

#[tokio::test]
async fn an_attempt_the_node_did_receive_is_adopted_and_never_voided() {
    // D3, with a client asking.
    let (app, _dir, _session) = ready_with_file().await;
    let world = install(&app, true, &[Delivery::LostReply]);
    let prep = dispatch(&app).await;
    assert_eq!(prep["state"], "outcome_unknown", "{prep}");
    assert!(prep["messageAdmission"]["recovery"].is_null());
    let prep = receipt(&app).await;
    assert_eq!(prep["state"], "admitted", "{prep}");
    let w = world.lock().unwrap();
    assert_eq!(w.posts.len(), 1, "no second send");
    assert_eq!(
        w.void_calls, 0,
        "an admission the Node holds is never voided"
    );
    drop(w);
    // Admitted: only now do the accepted file and its cleanup go.
    assert_eq!(count(&app.db.lock(), "conversation_submission_voids"), 0);
}

#[tokio::test]
async fn an_attempt_the_node_never_received_is_voided_then_retried_as_a_new_attempt() {
    // D4, D5 (a delayed frame), D11.
    let (app, _dir, _session) = ready_with_file().await;
    let world = install(&app, true, &[Delivery::Dropped, Delivery::Reply]);
    let prep = dispatch(&app).await;
    assert_eq!(prep["state"], "outcome_unknown");
    let first = prep["messageAdmission"]["commandId"]
        .as_str()
        .unwrap()
        .to_owned();
    retained(&app);

    // A check: the Node holds nothing, so the Gateway asks it to void.
    let prep = receipt(&app).await;
    assert_eq!(prep["state"], "admission_failed", "{prep}");
    let admission = &prep["messageAdmission"];
    assert_eq!(admission["outcome"], "not_admitted");
    assert_eq!(admission["retryEligible"], true);
    assert_eq!(admission["recovery"], "voided");
    assert_eq!(admission["commandId"], first);
    assert_eq!(world.lock().unwrap().void_calls, 1);
    assert_eq!(
        gateway_commands(&app),
        vec![(first.clone(), "rejected".to_string())]
    );
    retained(&app);

    // The delayed original frame now reaches the Node and is refused.
    {
        let mut w = world.lock().unwrap();
        let late = w.dropped[0].clone();
        w.deliveries.push_front(Delivery::Reply);
        let answer = handle(&mut w, &late).unwrap();
        assert_eq!(answer.status, 409);
        assert!(w.admitted.is_empty(), "nothing was created");
        assert_eq!(w.refused, vec![first.clone()]);
    }
    // Another check never turns the proof back into an unknown outcome.
    for _ in 0..2 {
        let again = receipt(&app).await;
        assert_eq!(again["state"], "admission_failed");
        assert_eq!(again["messageAdmission"]["outcome"], "not_admitted");
    }
    // A dispatch of the same operation never sends the voided id again.
    let again = dispatch(&app).await;
    assert_eq!(again["state"], "admission_failed");
    assert!(world.lock().unwrap().posts.is_empty());

    // The existing explicit retry: a new attempt that names the voided one.
    let prep = retry(&app, &first, "retry-a").await;
    assert_eq!(prep["state"], "admitted", "{prep}");
    let admission = &prep["messageAdmission"];
    assert_eq!(admission["attemptNumber"], 1);
    let second = admission["commandId"].as_str().unwrap().to_owned();
    assert_ne!(second, first);
    let w = world.lock().unwrap();
    assert_eq!(
        w.posts,
        vec![second],
        "the Node admitted only the successor"
    );
    assert!(w.voided.contains(&first));
    drop(w);
    // Admitted: the file is handed to cleanup and the copy is released.
    assert_eq!(count(&app.db.lock(), "conversation_submission_cleanup"), 1);
}

#[tokio::test]
async fn a_lost_void_reply_is_resent_and_the_answer_is_the_same() {
    // D7.
    let (app, _dir, _session) = ready_with_file().await;
    let world = install(&app, true, &[Delivery::Dropped]);
    world.lock().unwrap().lose_void_replies = 1;
    dispatch(&app).await;
    let prep = receipt(&app).await;
    assert_eq!(prep["state"], "outcome_unknown", "{prep}");
    assert_eq!(prep["messageAdmission"]["recovery"], "voiding");
    retained(&app);
    let prep = receipt(&app).await;
    assert_eq!(prep["state"], "admission_failed", "{prep}");
    assert_eq!(prep["messageAdmission"]["recovery"], "voided");
    assert_eq!(world.lock().unwrap().void_calls, 2);
    assert_eq!(count(&app.db.lock(), "conversation_submission_voids"), 1);
    retained(&app);
}

#[tokio::test]
async fn a_void_requested_before_a_crash_is_sent_after_restart_and_the_id_is_never_dispatched_again()
 {
    // D8: the crash is between "void requested" being committed and it being sent.
    let (app, _dir, session) = ready_with_file().await;
    let world = install(&app, true, &[Delivery::Dropped]);
    let prep = dispatch(&app).await;
    let first = prep["messageAdmission"]["commandId"]
        .as_str()
        .unwrap()
        .to_owned();
    let record = read(&app.db.lock(), "alice", "draft-1").unwrap().unwrap();
    assert!(request(&app, &identity(), "draft-1", &record).unwrap());
    // ...the process dies here: no void was sent, nothing was answered.
    assert_eq!(world.lock().unwrap().void_calls, 0);
    let config = app.config.clone();
    drop(app);
    let reopened = {
        let db = Db::open(&config.state_dir.join("gateway.sqlite")).unwrap();
        db.lock().recover_startup().unwrap();
        let backends = pirc_providers::backends::BackendService::open(
            &config.state_dir,
            crate::app::empty_models(),
        )
        .unwrap();
        App::new(config, Arc::new(db), backends, crate::app::test_modes())
    };
    model(&reopened);
    hold(&reopened, &session);
    let world = {
        // The Node kept its state across the Gateway's restart.
        let carried = world;
        let shared = carried.clone();
        reopened.nodes.set_test_node(connected(), move |r| {
            handle(&mut shared.lock().unwrap(), &r)
        });
        carried
    };
    let row = lookup(&reopened.db.lock(), "alice", "draft-1").unwrap();
    assert_eq!(row.state, Phase::OutcomeUnknown);
    assert_eq!(
        row.message_admission.as_ref().unwrap().recovery.as_deref(),
        Some("voiding")
    );
    assert!(
        reopened
            .db
            .lock()
            .execute(
                "INSERT INTO commands(id,session_id,payload_hash,payload_json,status,created_at,updated_at) VALUES(?1,?2,'h','{}','received',1,1)",
                params![first, session],
            )
            .is_err(),
        "the database refuses a second command row for a void-requested id"
    );
    // The sweep sends the void that was already committed.
    sweep(&reopened).await.unwrap();
    assert_eq!(world.lock().unwrap().void_calls, 1);
    let row = lookup(&reopened.db.lock(), "alice", "draft-1").unwrap();
    assert_eq!(row.state, Phase::AdmissionFailed);
    assert_eq!(
        count(&reopened.db.lock(), "conversation_submission_voids"),
        1
    );
    // A dispatch afterwards never sends the old id: only the receipt is shown.
    let again = dispatch(&reopened).await;
    assert_eq!(again["state"], "admission_failed");
    let w = world.lock().unwrap();
    assert!(w.posts.is_empty() && w.admitted.is_empty());
    assert_eq!(w.void_calls, 1, "the answered void is not asked again");
}

#[tokio::test]
async fn a_gateway_restart_during_a_dispatch_is_reconciled_by_the_sweep() {
    // Reserved and about to be sent when the Gateway died: after startup
    // recovery the command is unknown, and the sweep settles it.
    let (app, _dir, _session) = ready_with_file().await;
    let world = install(&app, true, &[]);
    let send = reserve(
        &app,
        &identity(),
        "draft-1",
        &super::super::tests::control(),
    )
    .unwrap()
    .unwrap();
    app.db.lock().recover_startup().unwrap();
    let row = lookup(&app.db.lock(), "alice", "draft-1").unwrap();
    assert_eq!(row.state, Phase::OutcomeUnknown);
    sweep(&app).await.unwrap();
    let row = lookup(&app.db.lock(), "alice", "draft-1").unwrap();
    assert_eq!(row.state, Phase::AdmissionFailed);
    let w = world.lock().unwrap();
    assert!(w.voided.contains(&send.command) && w.posts.is_empty());
    drop(w);
    retained(&app);
}

#[tokio::test]
async fn a_node_without_the_void_operation_keeps_the_unknown_outcome_and_says_so() {
    // D10.
    let (app, _dir, _session) = ready_with_file().await;
    let world = install(&app, false, &[Delivery::Dropped]);
    dispatch(&app).await;
    for _ in 0..2 {
        sweep(&app).await.unwrap();
    }
    let prep = receipt(&app).await;
    assert_eq!(prep["state"], "outcome_unknown", "{prep}");
    assert_eq!(prep["messageAdmission"]["recovery"], "recovery_unsupported");
    assert_eq!(prep["messageAdmission"]["retryEligible"], false);
    assert_eq!(prep["deliveryError"], "recovery_unsupported");
    {
        let w = world.lock().unwrap();
        assert_eq!(w.void_calls, 0, "a void is never sent, so none is assumed");
        assert!(w.posts.is_empty());
    }
    assert_eq!(count(&app.db.lock(), "conversation_submission_voids"), 0);
    retained(&app);
    // The Node is upgraded: the same sweep recovers it.
    world.lock().unwrap().void_supported = true;
    sweep(&app).await.unwrap();
    let prep = receipt(&app).await;
    assert_eq!(prep["state"], "admission_failed", "{prep}");
    assert_eq!(prep["messageAdmission"]["recovery"], "voided");
}

#[tokio::test]
async fn with_no_client_the_sweep_converges_an_adopted_and_a_voided_attempt() {
    // D12: neither scenario involves a request from a client after the dispatch.
    for (delivery, state) in [
        (Delivery::LostReply, "admitted"),
        (Delivery::Dropped, "admission_failed"),
    ] {
        let (app, _dir, _session) = ready_with_file().await;
        let world = install(&app, true, &[delivery]);
        let prep = dispatch(&app).await;
        assert_eq!(prep["state"], "outcome_unknown");
        sweep(&app).await.unwrap();
        let row = lookup(&app.db.lock(), "alice", "draft-1").unwrap();
        assert_eq!(serde_json::to_value(row.state).unwrap(), state);
        let (posts, voids) = {
            let w = world.lock().unwrap();
            (w.posts.len(), w.void_calls)
        };
        assert_eq!(posts, usize::from(delivery == Delivery::LostReply));
        assert_eq!(voids, usize::from(delivery == Delivery::Dropped));
        // A second sweep changes nothing.
        sweep(&app).await.unwrap();
        assert_eq!(world.lock().unwrap().void_calls, voids);
    }
}

#[tokio::test]
async fn a_node_reconnect_wakes_the_sweep_without_waiting_for_the_timer() {
    let (app, _dir, session) = ready_with_file().await;
    let world = install(&app, true, &[Delivery::Dropped]);
    // The loop's first pass (at start) finds nothing to do.
    start(&app);
    tokio::time::sleep(Duration::from_millis(300)).await;
    dispatch(&app).await;
    assert_eq!(world.lock().unwrap().void_calls, 0);
    app.events
        .publish(&session, 0, "node_reconnected", json!({"nodeId":"node"}));
    let deadline = std::time::Instant::now() + Duration::from_secs(3);
    loop {
        let row = lookup(&app.db.lock(), "alice", "draft-1").unwrap();
        if row.state == Phase::AdmissionFailed {
            break;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "a reconnect must wake the sweep within seconds, not the 5 s timer"
        );
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert_eq!(world.lock().unwrap().void_calls, 1);
}

#[tokio::test]
async fn the_database_keeps_a_voided_command_from_being_dispatched_or_recorded() {
    let (app, _dir, session) = ready_with_file().await;
    install(&app, true, &[Delivery::Dropped]);
    let prep = dispatch(&app).await;
    let first = prep["messageAdmission"]["commandId"]
        .as_str()
        .unwrap()
        .to_owned();
    let record = read(&app.db.lock(), "alice", "draft-1").unwrap().unwrap();
    // A void needs an unadmitted attempt of this exact input, not a stranger.
    assert!(
        app.db
            .lock()
            .execute(
                "INSERT INTO conversation_submission_voids(owner_user,operation_id,command_id,input_hash,requested_at) VALUES('alice','draft-1','other',?1,1)",
                [record.hash.clone().unwrap()],
            )
            .is_err()
    );
    assert!(request(&app, &identity(), "draft-1", &record).unwrap());
    let db = app.db.lock();
    // Answered once, never changed, never removed.
    db.execute(
        "UPDATE conversation_submission_voids SET result='voided',answered_at=2",
        [],
    )
    .unwrap();
    assert!(
        db.execute(
            "UPDATE conversation_submission_voids SET result='admission'",
            []
        )
        .is_err()
    );
    assert!(
        db.execute("DELETE FROM conversation_submission_voids", [])
            .is_err()
    );
    // The id cannot become a dispatch or a command again, by any path.
    db.execute("DELETE FROM commands WHERE id=?1", [&first])
        .unwrap();
    assert!(
        db.execute(
            "INSERT INTO commands(id,session_id,payload_hash,payload_json,status,created_at,updated_at) VALUES(?1,?2,'h','{}','received',1,1)",
            params![first, session],
        )
        .is_err()
    );
    db.execute(
        "UPDATE conversation_submission_dispatches SET state='rejected',outcome='not_admitted'",
        [],
    )
    .unwrap();
    assert!(
        db.execute(
            "UPDATE conversation_submission_dispatches SET state='dispatched',outcome='pending'",
            [],
        )
        .is_err(),
        "a voided attempt cannot be put back in flight"
    );
    db.execute("DELETE FROM conversation_submission_dispatches", [])
        .unwrap();
    assert!(
        db.execute(
            "INSERT INTO conversation_submission_dispatches(owner_user,operation_id,command_id,input_hash,state,outcome,created_at,updated_at) VALUES('alice','draft-1',?1,?2,'dispatched','pending',1,1)",
            params![first, record.hash.unwrap()],
        )
        .is_err()
    );
}

/// A real Node on `dir`, as pirc-node's own tests start one.
async fn real_node(dir: &std::path::Path) -> pirc_node::services::Node {
    use pirc_config::{Env, NodeConfig};
    use pirc_protocol::{NodeRole, mode::default_work};
    let root = dir.canonicalize().unwrap();
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
            ("PIRC_MODES", "directory,review"),
            ("PIRC_BROWSER", "false"),
            ("HOME", home.as_str()),
        ],
        &root,
    );
    let config = NodeConfig::load(&env, NodeRole::Node).unwrap();
    let node = pirc_node::services::Services::start(config, env)
        .await
        .unwrap();
    let mut review = default_work();
    review.id = pirc_protocol::ModeId::new("review").unwrap();
    node.replace_modes(vec![default_work(), review]).await;
    node
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_real_node_refuses_the_delayed_original_after_the_gateway_voided_it() {
    // D4 and D5 end to end, and D9: the Node restarts between the void and the
    // delayed frame. Every Node answer here comes from pirc-node's own code.
    use pirc_node::store::{ModeId, Store};
    let dir = tempfile::tempdir_in("/tmp").unwrap();
    let node = real_node(dir.path()).await;
    let work = dir.path().canonicalize().unwrap().join("repository");
    std::fs::create_dir(&work).unwrap();
    node.db
        .lock()
        .add_workspace(
            "repo",
            "test-node",
            "Repo",
            work.to_str().unwrap(),
            ModeId::new("directory").unwrap(),
        )
        .unwrap();
    let (app, _gateway_dir) = disk_app();
    model(&app);
    crate::conversation_submissions::acceptance::tests::prepared(&app, false);
    let current = Arc::new(Mutex::new(node));
    let late: Arc<Mutex<Vec<NodeHttpRequest>>> = Arc::default();
    let drop_next = Arc::new(Mutex::new(true));
    {
        let (current, late, drop_next) = (current.clone(), late.clone(), drop_next.clone());
        app.nodes.set_test_node(connected(), move |mut request| {
            // The Node serves its own user; the Gateway names theirs.
            request.user = "test-user".into();
            if request.method == pirc_protocol::HttpMethod::Post
                && request.url.ends_with("/admission")
                && std::mem::take(&mut *drop_next.lock().unwrap())
            {
                // The frame is still travelling: the Gateway times out.
                late.lock().unwrap().push(request);
                return Err(timeout());
            }
            let node = current.lock().unwrap().clone();
            let answer = tokio::task::block_in_place(|| {
                tokio::runtime::Handle::current().block_on(node.router.handle(&node, request))
            });
            Ok(NodeHttpResponse {
                status: answer.status,
                body: answer.body,
            })
        });
    }
    accept_intent(&app, &identity(), "draft-1").await.unwrap();
    let ready = advance(&app, &identity(), "draft-1").await.unwrap();
    hold(&app, &ready.session_id);
    let remote = session_on_node(&app);
    let grab = |node: &pirc_node::services::Node| {
        node.db
            .lock()
            .acquire_lease(&remote, "phone", false, 600_000)
            .unwrap();
    };
    grab(&current.lock().unwrap());

    let prep = dispatch(&app).await;
    assert_eq!(prep["state"], "outcome_unknown", "{prep}");
    let first = prep["messageAdmission"]["commandId"]
        .as_str()
        .unwrap()
        .to_owned();

    // The check: the real Node holds nothing, so the Gateway has it void.
    let prep = receipt(&app).await;
    assert_eq!(prep["state"], "admission_failed", "{prep}");
    assert_eq!(prep["messageAdmission"]["recovery"], "voided");

    // The Node restarts; its void is durable.
    let old = current.lock().unwrap().clone();
    old.close().await;
    drop(old);
    *current.lock().unwrap() = real_node(dir.path()).await;
    let node = current.lock().unwrap().clone();

    // The delayed original reaches the restarted Node and is refused.
    let delayed = late.lock().unwrap().remove(0);
    let refused = node.router.handle(&node, delayed).await;
    assert_eq!(refused.status, 409);
    assert_eq!(refused.body.unwrap()["error"]["code"], "command_voided");
    let on_node =
        |sql: &str, id: &str| -> i64 { node.db.lock().query_row(sql, [id], |r| r.get(0)).unwrap() };
    assert_eq!(
        on_node("SELECT count(*) FROM commands WHERE id=?1", &first),
        0
    );
    assert_eq!(
        on_node(
            "SELECT count(*) FROM creation_admission_voids WHERE command_id=?1",
            &first
        ),
        1
    );

    // The user retries: a new attempt, taken by the same Node as the first
    // admission of this creation, naming the voided one as its predecessor.
    grab(&node);
    let prep = retry(&app, &first, "retry-a").await;
    assert_eq!(prep["messageAdmission"]["attemptNumber"], 1, "{prep}");
    let second = prep["messageAdmission"]["commandId"]
        .as_str()
        .unwrap()
        .to_owned();
    assert_ne!(second, first);
    let previous: String = node
        .db
        .lock()
        .query_row(
            "SELECT previous_command_id FROM creation_admission_attempts WHERE command_id=?1",
            [&second],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(previous, first);
    assert_eq!(
        on_node("SELECT count(*) FROM commands WHERE id=?1", &second),
        1
    );
    assert_eq!(
        on_node("SELECT count(*) FROM commands WHERE id=?1", &first),
        0
    );
    node.close().await;
}

/// The Node-side session id the Gateway adopted at materialization.
fn session_on_node(app: &AppState) -> String {
    app.db
        .lock()
        .query_row(
            "SELECT node_session_id FROM conversation_submission_acceptances WHERE operation_id='draft-1'",
            [],
            |r| r.get(0),
        )
        .unwrap()
}
