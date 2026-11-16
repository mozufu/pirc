//! Cancelling an environment switch whose Node outcome is unknown (F1).
//!
//! Every test runs the Gateway against a REAL Node: its fence code and its store
//! (pirc-node), reached through the same request path the Gateway uses. The only
//! stand-in is the link between them, which can hold a request back (a delayed
//! frame), lose a reply, go offline, hide the capability or refuse a request
//! outright, exactly the ways the real link can fail.
use super::*;
use crate::conversation_bindings::transitions::tests::{identity, input, seed};
use crate::{
    app::App,
    db::{Db, Lease},
};
use pirc_protocol::{NodeHttpRequest, NodeHttpResponse};
use std::{
    path::Path,
    sync::{Arc, Mutex},
};

const NODE_USER: &str = "test-user";

/// What the link between the Gateway and the Node does next.
#[derive(Default)]
struct Knobs {
    /// The next create request is "still travelling": kept, never delivered, and
    /// the Gateway times out.
    hold_create: bool,
    /// The Node handles the next create, but its reply never arrives.
    lose_create_reply: bool,
    /// The next create is answered with an explicit refusal; the Node never sees it.
    refuse_create: bool,
    /// The next create fails before it enters the link's queue.
    unsent_create: bool,
    /// The Node handles this many voids, but each reply is lost.
    lose_void_replies: usize,
    /// While the void is on the wire, the delayed create reaches the Node too, on
    /// another thread, released at the same moment.
    race_create: bool,
    /// The delayed create reaches the Node just before the void does.
    create_before_void: bool,
    /// Which of the two threads starts first.
    race_void_first: bool,
    /// A Node that predates the void: it does not advertise the capability.
    legacy: bool,
    /// Nothing gets through; every request fails before it is queued.
    offline: bool,
    /// The Gateway "crashes" as it sends the void: the frame never leaves.
    swallow_void: bool,
    held: Vec<NodeHttpRequest>,
    calls: Vec<String>,
}
type Shared = Arc<Mutex<Knobs>>;

fn timeout() -> ApiError {
    ApiError::new(
        504,
        "node_timeout",
        "Node response timed out; outcome may be unknown",
    )
}
/// One request, handled by the real Node (blocking, as the test link does).
fn through(
    node: &pirc_node::services::Node,
    mut request: NodeHttpRequest,
) -> ApiResult<NodeHttpResponse> {
    // The Node serves its own user; the Gateway names theirs.
    request.user = NODE_USER.into();
    let answer = tokio::task::block_in_place(|| {
        tokio::runtime::Handle::current().block_on(node.router.handle(node, request))
    });
    Ok(answer)
}
/// The same, from a plain thread (not a runtime worker).
fn through_on(
    handle: &tokio::runtime::Handle,
    node: &pirc_node::services::Node,
    mut request: NodeHttpRequest,
) -> ApiResult<NodeHttpResponse> {
    request.user = NODE_USER.into();
    Ok(handle.block_on(node.router.handle(node, request)))
}
fn is_create(r: &NodeHttpRequest) -> bool {
    r.method == HttpMethod::Post && r.url.ends_with("/execution-fences")
}
fn is_void(r: &NodeHttpRequest) -> bool {
    r.method == HttpMethod::Post && r.url.ends_with("/void")
}

async fn real_node(dir: &Path) -> pirc_node::services::Node {
    use pirc_config::{Env, NodeConfig};
    use pirc_protocol::{NodeRole, mode::default_work};
    let root = dir.canonicalize().unwrap();
    let state = root.join("state").display().to_string();
    let config_dir = root.join("config").display().to_string();
    let home = root.display().to_string();
    let env = Env::new(
        [
            ("PIRC_NODE_ID", "node"),
            ("PIRC_NODE_TOKEN", "0123456789abcdef0123456789abcdef"),
            ("PIRC_DAEMON_URL", "ws://127.0.0.1:8787"),
            ("PIRC_ALLOWED_USERS", NODE_USER),
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

/// The Gateway on a file database, so a restart keeps its state.
fn gateway(dir: &Path, remote: Option<&str>) -> (AppState, String) {
    let state = dir.join("state");
    let base = [
        (
            "PIRC_NODE_TOKENS",
            r#"{"node":"0123456789abcdef0123456789abcdef"}"#,
        ),
        ("PIRC_TRUSTED_PROXIES", "127.0.0.1"),
        ("PIRC_ALLOWED_ORIGINS", "https://a.example"),
        ("PIRC_ALLOWED_HOSTS", "a.example"),
        ("PIRC_ALLOWED_USERS", "alice"),
        ("PIRC_STATE_DIR", state.to_str().unwrap()),
        ("PIRC_CONFIG_DIR", dir.to_str().unwrap()),
        ("PIRC_TIMEZONE", "UTC"),
        ("HOME", "/home/test"),
    ];
    let env = pirc_config::Env::new(base.iter().copied(), "/work");
    let backends =
        pirc_providers::backends::BackendService::open(&state, crate::app::empty_models()).unwrap();
    let db = Arc::new(Db::open(&dir.join("gateway.sqlite")).unwrap());
    let id = match remote {
        Some(remote) => {
            let db = db.lock();
            seed(&db);
            // The seeded conversation maps to the Node's own session.
            db.execute("UPDATE sessions SET pi_session_id=?1", [remote])
                .unwrap();
            db.query_row("SELECT id FROM sessions", [], |r| r.get(0))
                .unwrap()
        }
        None => db
            .lock()
            .query_row("SELECT id FROM sessions", [], |r| r.get(0))
            .unwrap(),
    };
    let app = App::new(
        pirc_config::GatewayConfig::load(&env).unwrap(),
        db,
        backends,
        crate::app::test_modes(),
    );
    (app, id)
}

/// A Gateway and a Node with one accepted switch from `node:repo` to `node:target`.
struct Fixture {
    app: AppState,
    gateway_dir: tempfile::TempDir,
    node_dir: tempfile::TempDir,
    node: Arc<Mutex<pirc_node::services::Node>>,
    knobs: Shared,
    id: String,
    remote: String,
    generation: i64,
}

impl Fixture {
    fn link(&self) {
        let (node, knobs) = (self.node.clone(), self.knobs.clone());
        self.app.nodes.set_test_node(
            crate::conversation_bindings::transitions::tests::node(),
            move |request| {
                {
                    let mut k = knobs.lock().unwrap();
                    if k.offline {
                        return Err(ApiError::new(503, "node_offline", "Node is offline").unsent());
                    }
                    k.calls
                        .push(format!("{:?} {}", request.method, request.url));
                    if k.legacy && request.url.ends_with("/execution-fences/capabilities") {
                        drop(k);
                        let mut answer = through(&node.lock().unwrap().clone(), request)?;
                        if let Some(body) = answer.body.as_mut().and_then(|b| b.as_object_mut()) {
                            body.remove("transitionVoidVersion");
                        }
                        return Ok(answer);
                    }
                    if k.legacy && is_void(&request) {
                        return Ok(NodeHttpResponse {
                            status: 404,
                            body: Some(json!({"error":{"code":"not_found"}})),
                        });
                    }
                    if is_create(&request) {
                        if std::mem::take(&mut k.refuse_create) {
                            return Ok(NodeHttpResponse {
                                status: 409,
                                body: Some(json!({"error":{"code":"stale_environment"}})),
                            });
                        }
                        if std::mem::take(&mut k.unsent_create) {
                            return Err(
                                ApiError::new(503, "node_error", "Link is congested").unsent()
                            );
                        }
                        if std::mem::take(&mut k.hold_create) {
                            k.held.push(request);
                            return Err(timeout());
                        }
                        if std::mem::take(&mut k.lose_create_reply) {
                            drop(k);
                            through(&node.lock().unwrap().clone(), request)?;
                            return Err(timeout());
                        }
                    }
                    if is_void(&request) {
                        if std::mem::take(&mut k.race_create) && !k.held.is_empty() {
                            let late = k.held.remove(0);
                            let void_first = k.race_void_first;
                            drop(k);
                            let node = node.lock().unwrap().clone();
                            let handle = tokio::runtime::Handle::current();
                            let gate = std::sync::Barrier::new(2);
                            let run = |request: NodeHttpRequest| {
                                gate.wait();
                                through_on(&handle, &node, request)
                            };
                            return std::thread::scope(|scope| {
                                let (first, second): (NodeHttpRequest, NodeHttpRequest) =
                                    if void_first {
                                        (request.clone(), late.clone())
                                    } else {
                                        (late.clone(), request.clone())
                                    };
                                let a = scope.spawn(|| run(first));
                                let b = scope.spawn(|| run(second));
                                let (a, b) = (a.join().unwrap(), b.join().unwrap());
                                if void_first { a } else { b }
                            });
                        }
                        if std::mem::take(&mut k.create_before_void) && !k.held.is_empty() {
                            let late = k.held.remove(0);
                            drop(k);
                            let node = node.lock().unwrap().clone();
                            through(&node, late)?;
                            return through(&node, request);
                        }
                        if k.swallow_void {
                            return Err(timeout());
                        }
                        if k.lose_void_replies > 0 {
                            k.lose_void_replies -= 1;
                            drop(k);
                            through(&node.lock().unwrap().clone(), request)?;
                            return Err(timeout());
                        }
                    }
                }
                through(&node.lock().unwrap().clone(), request)
            },
        );
    }
    fn node(&self) -> pirc_node::services::Node {
        self.node.lock().unwrap().clone()
    }
    fn connection(&self) -> crate::nodes::NodeConnection {
        self.app.nodes.connection("node").unwrap()
    }
    fn knobs(&self) -> std::sync::MutexGuard<'_, Knobs> {
        self.knobs.lock().unwrap()
    }
    /// A new link to the same Node: connections are told apart, so a request
    /// sent on the old one is a different connection from a later one.
    fn reconnect(&self) {
        self.link();
    }
    async fn dispatch(&self) -> Value {
        dispatch_once(
            &self.app,
            &identity(),
            &self.id,
            "move-1",
            self.connection(),
        )
        .await
        .unwrap()
    }
    async fn cancel(&self) -> ApiResult<Value> {
        super::super::cancel(
            &self.app,
            &identity(),
            &self.id,
            "move-1",
            ("phone".into(), self.generation),
        )
        .await
    }
    async fn sweep(&self) -> Value {
        advance(&self.app, &identity(), &self.id, "move-1", None)
            .await
            .unwrap()
    }
    fn state(&self) -> String {
        saved(&self.app.db.lock(), "alice", &self.id, "move-1")
            .unwrap()
            .unwrap()
            .state
    }
    fn open(&self) -> bool {
        receipts::require_open(&self.app.db.lock(), &self.id).is_ok()
    }
    fn count(&self, sql: &str) -> i64 {
        self.app.db.lock().query_row(sql, [], |r| r.get(0)).unwrap()
    }
    fn on_node(&self, sql: &str) -> i64 {
        self.node()
            .db
            .lock()
            .query_row(sql, [], |r| r.get(0))
            .unwrap()
    }
    fn node_fences(&self) -> i64 {
        self.on_node("SELECT count(*) FROM execution_fences WHERE operation_id='move-1'")
    }
    fn node_voids(&self) -> i64 {
        self.on_node("SELECT count(*) FROM execution_fence_voids WHERE operation_id='move-1'")
    }
    fn calls(&self, matching: impl Fn(&str) -> bool) -> usize {
        self.knobs().calls.iter().filter(|c| matching(c)).count()
    }
    /// How many create requests reached the link.
    fn creates(&self) -> usize {
        self.calls(|c| c.starts_with("Post") && c.ends_with("/execution-fences"))
    }
    fn voids_sent(&self) -> usize {
        self.calls(|c| c.starts_with("Post") && c.ends_with("/void"))
    }
    /// The delayed create finally arrives at the Node.
    fn deliver_held(&self) -> NodeHttpResponse {
        let request = self.knobs().held.remove(0);
        through(&self.node(), request).unwrap()
    }
    async fn restart_node(&self) {
        let old = self.node();
        old.close().await;
        drop(old);
        *self.node.lock().unwrap() = real_node(self.node_dir.path()).await;
    }
    /// The Gateway process dies and starts again on the same database.
    fn restart_gateway(&mut self) {
        let (app, id) = gateway(self.gateway_dir.path(), None);
        assert_eq!(id, self.id);
        self.app = app;
        self.link();
    }
}

async fn fixture() -> Fixture {
    let node_dir = tempfile::tempdir_in("/tmp").unwrap();
    let node = real_node(node_dir.path()).await;
    let root = node_dir.path().canonicalize().unwrap();
    for id in ["repo", "target"] {
        let path = root.join(id);
        std::fs::create_dir(&path).unwrap();
        node.db
            .lock()
            .add_workspace(
                id,
                "node",
                id,
                path.to_str().unwrap(),
                pirc_node::store::ModeId::new("directory").unwrap(),
            )
            .unwrap();
    }
    use pirc_node::store::Store as _;
    let (remote, epoch, generation) = {
        let db = node.db.lock();
        let s = pirc_node::store::Store::create_session(&*db, "repo", "/private/switch", NODE_USER)
            .unwrap();
        let lease = db.acquire_lease(&s.id, "phone", false, 600_000).unwrap();
        (s.id, s.runner_epoch, lease.generation)
    };
    let gateway_dir = tempfile::tempdir().unwrap();
    let (app, id) = gateway(gateway_dir.path(), Some(&remote));
    let fixture = Fixture {
        app,
        gateway_dir,
        node_dir,
        node: Arc::new(Mutex::new(node)),
        knobs: Shared::default(),
        id,
        remote: remote.clone(),
        generation,
    };
    fixture.link();
    // The Node's own preflight supplies the evidence the intent must carry.
    let preflight = through(
        &fixture.node(),
        NodeHttpRequest {
            method: HttpMethod::Post,
            url: format!("/api/sessions/{remote}/execution-fences/preflight"),
            user: "alice".into(),
            payload: Some(json!({"expectedWorkspaceId":"repo","expectedRunnerEpoch":epoch,"targetWorkspaceId":"target"})),
            body_base64: None,
            content_type: None,
        },
    )
    .unwrap();
    assert_eq!(preflight.status, 200, "{preflight:?}");
    let evidence = preflight.body.unwrap()["evidenceHash"].clone();
    fixture.knobs().calls.clear();
    let row = {
        let db = fixture.app.db.lock();
        db.mirror_lease(
            &fixture.id,
            &Lease {
                client_id: "phone".into(),
                generation,
                expires_at: now_ms() + 600_000,
            },
            "alice",
            false,
        )
        .unwrap();
        crate::conversation_bindings::transitions::reserve(
            &db,
            "alice",
            &fixture.id,
            &input(&db, &fixture.id),
        )
        .unwrap()
    };
    let confirmation = Confirmation {
        plan_hash: row.plan_hash.clone(),
        observation_hash: "reviewed".into(),
        client_id: "phone".into(),
        generation,
    };
    let observation = json!({"status":"observed","observationHash":"reviewed","observation":{"policiesMatch":true,"overlap":false,"sourceResource":{"state":"observed"},"targetResource":{"state":"observed"},"activity":{"fenced":false,"pendingRecords":false},"nodeRunnerEpoch":epoch,"nodeEvidenceHash":evidence}});
    let mapping =
        receipts::access_at(&fixture.app, &fixture.app.db.lock(), &identity(), &row).unwrap();
    assert_eq!(mapping.1, remote);
    reserve(
        &fixture.app,
        &identity(),
        &row,
        &confirmation,
        &observation,
        &mapping,
        fixture.connection(),
    )
    .unwrap();
    assert_eq!(fixture.state(), "accepted");
    fixture
}

fn code(error: &ApiError) -> &str {
    error.code
}

// ---- X1, X2, X3: the three outcomes ----------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn x1_a_create_that_never_arrived_is_voided_by_cancel_and_the_conversation_reopens() {
    let fx = fixture().await;
    fx.knobs().hold_create = true;
    let sent = fx.dispatch().await;
    // The request is in flight and its reply never came: unknown, and locked.
    assert_eq!(sent["transition"]["state"], "outcome_unknown", "{sent}");
    assert!(!fx.open());
    assert_eq!(fx.node_fences(), 0);
    assert_eq!(fx.knobs().held.len(), 1);

    let result = fx.cancel().await.unwrap();
    assert_eq!(result["transition"]["state"], "released", "{result}");
    assert_eq!(result["cancellation"]["void"]["state"], "voided");
    assert_eq!(result["cancellation"]["void"]["nodeId"], "node");
    assert!(result["cancellation"]["void"]["answeredAt"].is_i64());
    assert_eq!(fx.state(), "released");
    // The Node holds the void and no fence; the Gateway holds the receipt.
    assert_eq!((fx.node_fences(), fx.node_voids()), (0, 1));
    let (answer, node_id): (String, String) = fx
        .app
        .db
        .lock()
        .query_row(
            "SELECT answer_json,node_id FROM conversation_transition_voids WHERE operation_id='move-1' AND result='voided'",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap();
    let answer: Value = serde_json::from_str(&answer).unwrap();
    assert_eq!(answer["result"], "voided");
    assert_eq!(answer["operationId"], "move-1");
    assert_eq!(node_id, "node");
    // Both sides are open.
    assert!(fx.open());
    pirc_node::execution_fences::require_open(&fx.node().db.lock(), &fx.remote).unwrap();
    // The original request was sent exactly once, and never again.
    assert_eq!(fx.creates(), 1);
    // The conversation accepts an ordinary command again.
    let session = fx.app.db.lock().get_session(&fx.id).unwrap();
    crate::conversation_bindings::commands::receive(
        &fx.app.db.lock(),
        &session,
        "alice",
        "new-work",
        &json!({"type":"prompt","message":"carry on"}),
        Some(&session.binding),
    )
    .unwrap();
    // A new switch is a new identity with a new preview; it can be accepted.
    {
        let db = fx.app.db.lock();
        let second = Input {
            operation_id: "move-2".into(),
            ..input(&db, &fx.id)
        };
        let preview =
            crate::conversation_bindings::transitions::reserve(&db, "alice", &fx.id, &second);
        assert_eq!(preview.unwrap().operation_id, "move-2");
        receipts::require_unused(&db, "alice", "move-2").unwrap();
    }
    fx.node().close().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn x2_a_create_that_succeeded_with_a_lost_reply_is_adopted_and_never_voided() {
    let fx = fixture().await;
    fx.knobs().lose_create_reply = true;
    let sent = fx.dispatch().await;
    assert_eq!(sent["transition"]["state"], "outcome_unknown", "{sent}");
    // The Node did create it; only the answer was lost.
    assert_eq!(fx.node_fences(), 1);

    let result = fx.cancel().await.unwrap();
    // The fence was adopted and the ordinary cancel path asked the Node to release.
    assert_ne!(result["transition"]["state"], "outcome_unknown", "{result}");
    assert_eq!(fx.node_voids(), 0, "no void on the Node");
    assert_eq!(
        fx.count("SELECT count(*) FROM conversation_transition_voids WHERE result IS NOT NULL"),
        0,
        "no void receipt on the Gateway"
    );
    assert_eq!(fx.voids_sent(), 0, "no void was even sent");
    assert_eq!(fx.creates(), 1);
    // The Node recorded the cancellation of the fence it holds.
    assert!(fx.on_node("SELECT count(*) FROM execution_fences WHERE operation_id='move-1' AND cancel_requested_at IS NOT NULL") == 1);
    // A later sweep finishes the existing cancel path.
    fx.sweep().await;
    assert!(matches!(fx.state().as_str(), "node_fenced" | "released"));
    fx.node().close().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn x3_a_delayed_create_after_the_void_is_refused_and_creates_no_fence() {
    let fx = fixture().await;
    fx.knobs().hold_create = true;
    fx.dispatch().await;
    fx.cancel().await.unwrap();
    assert_eq!(fx.state(), "released");
    // Now the original frame reaches the Node.
    let late = fx.deliver_held();
    assert_eq!(late.status, 409, "{late:?}");
    assert_eq!(late.body.unwrap()["error"]["code"], "operation_voided");
    assert_eq!(fx.node_fences(), 0);
    assert_eq!(fx.node_voids(), 1);
    // Nothing on the Node is blocked, and the Gateway stays released.
    pirc_node::execution_fences::require_open(&fx.node().db.lock(), &fx.remote).unwrap();
    assert_eq!(fx.state(), "released");
    assert!(fx.open());
    fx.sweep().await;
    assert_eq!(fx.state(), "released");
    fx.node().close().await;
}

// ---- X4: racing -------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn x4_a_void_and_a_create_racing_leave_one_winner_and_both_sides_agree() {
    // The delayed create reaches the Node while the void is on the wire, from
    // another thread released at the same moment, in alternating order.
    let (mut created, mut voided) = (0, 0);
    for round in 0..16 {
        let fx = fixture().await;
        fx.knobs().hold_create = true;
        fx.dispatch().await;
        {
            let mut k = fx.knobs();
            k.race_create = true;
            k.race_void_first = round % 2 == 0;
        }
        let cancelled = fx.cancel().await.unwrap();
        let (fences, voids) = (fx.node_fences(), fx.node_voids());
        assert_eq!(fences + voids, 1, "exactly one of fenced and voided");
        if voids == 1 {
            voided += 1;
            assert_eq!(fx.state(), "released", "{cancelled}");
            assert!(fx.open());
            assert_eq!(
                fx.count(
                    "SELECT count(*) FROM conversation_transition_voids WHERE result='voided'"
                ),
                1
            );
        } else {
            created += 1;
            // The create won: the Gateway holds a fence, never a void receipt.
            assert!(matches!(fx.state().as_str(), "node_fenced" | "released"));
            assert_eq!(
                fx.count(
                    "SELECT count(*) FROM conversation_transition_voids WHERE result IS NOT NULL"
                ),
                0
            );
        }
        fx.node().close().await;
    }
    eprintln!("race outcomes: {created} created, {voided} voided");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn x4_both_orders_are_decided_the_same_way_on_both_sides() {
    // Void first: the delayed create is refused (x3). Create first: the void
    // reports the fence and the ordinary cancel path continues (x2, x7). Here the
    // two are forced at the moment the void is sent.
    for (create_first, name) in [(true, "create first"), (false, "void first")] {
        let fx = fixture().await;
        fx.knobs().hold_create = true;
        fx.dispatch().await;
        if create_first {
            assert_eq!(fx.deliver_held().status, 200, "{name}");
            fx.cancel().await.unwrap();
            assert_eq!((fx.node_fences(), fx.node_voids()), (1, 0), "{name}");
            assert_eq!(
                fx.voids_sent(),
                0,
                "{name}: the GET already showed the fence"
            );
        } else {
            fx.cancel().await.unwrap();
            assert_eq!(fx.deliver_held().status, 409, "{name}");
            assert_eq!((fx.node_fences(), fx.node_voids()), (0, 1), "{name}");
            assert_eq!(fx.state(), "released");
        }
        fx.node().close().await;
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_create_that_arrives_just_before_the_void_is_reported_by_the_void() {
    // The Gateway's read found nothing; the delayed create lands; then the void
    // arrives and the Node answers with the fence instead of voiding.
    let fx = fixture().await;
    fx.knobs().hold_create = true;
    fx.dispatch().await;
    fx.knobs().create_before_void = true;
    let result = fx.cancel().await.unwrap();
    assert_eq!(
        fx.voids_sent(),
        1,
        "the void was sent and answered with the fence"
    );
    assert_eq!((fx.node_fences(), fx.node_voids()), (1, 0));
    assert_ne!(result["transition"]["state"], "outcome_unknown", "{result}");
    assert_eq!(
        fx.count("SELECT count(*) FROM conversation_transition_voids WHERE result IS NOT NULL"),
        0
    );
    assert!(
        fx.on_node("SELECT count(*) FROM execution_fences WHERE cancel_requested_at IS NOT NULL")
            == 1
    );
    fx.node().close().await;
}

// ---- X5: an explicit refusal is only a hint ---------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn x5_a_refused_create_leaves_a_hint_and_only_the_users_cancel_releases() {
    let fx = fixture().await;
    fx.knobs().refuse_create = true;
    let sent = fx.dispatch().await;
    assert_eq!(sent["transition"]["state"], "outcome_unknown", "{sent}");
    assert_eq!(sent["progress"]["waitReason"], "node_refused");
    assert_eq!(sent["progress"]["errorCode"], "stale_environment");
    assert_eq!(sent["progress"]["safeActions"], json!(["cancel"]));
    // Sweeps may look as often as they like: nothing is voided or released.
    for _ in 0..3 {
        let seen = fx.sweep().await;
        assert_eq!(seen["transition"]["state"], "outcome_unknown");
    }
    assert_eq!((fx.node_fences(), fx.node_voids()), (0, 0));
    assert_eq!(fx.voids_sent(), 0);
    assert!(!fx.open());
    let result = fx.cancel().await.unwrap();
    assert_eq!(result["transition"]["state"], "released");
    assert_eq!((fx.node_fences(), fx.node_voids()), (0, 1));
    assert!(fx.open());
    fx.node().close().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_request_that_never_left_the_link_is_only_a_hint_too() {
    let fx = fixture().await;
    fx.knobs().unsent_create = true;
    let sent = fx.dispatch().await;
    assert_eq!(sent["transition"]["state"], "outcome_unknown", "{sent}");
    assert_eq!(sent["progress"]["waitReason"], "request_not_sent");
    for _ in 0..2 {
        fx.sweep().await;
    }
    // Not released, not voided, and not sent again by anyone.
    assert_eq!(fx.state(), "outcome_unknown");
    assert_eq!(
        (fx.node_fences(), fx.node_voids(), fx.voids_sent()),
        (0, 0, 0)
    );
    assert_eq!(fx.creates(), 1);
    fx.node().close().await;
}

// ---- X6: a 404 is not proof --------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn x6_a_404_from_the_sweep_is_not_proof_so_a_late_create_still_continues_the_flow() {
    let fx = fixture().await;
    fx.knobs().hold_create = true;
    fx.dispatch().await;
    // The sweep's read finds nothing: a hint, never a void or a release.
    let seen = fx.sweep().await;
    assert_eq!(seen["transition"]["state"], "outcome_unknown", "{seen}");
    assert_eq!(seen["progress"]["waitReason"], "receipt_unavailable");
    assert_eq!(seen["progress"]["safeActions"], json!(["cancel"]));
    assert_eq!(
        (fx.node_fences(), fx.node_voids(), fx.voids_sent()),
        (0, 0, 0)
    );
    assert!(!fx.open());
    // The delayed original arrives and the Node creates the fence.
    let late = fx.deliver_held();
    assert_eq!(late.status, 200, "{late:?}");
    assert_eq!(fx.node_fences(), 1);
    // The next sweep adopts it, and the flow goes on as for any fenced switch.
    let next = fx.sweep().await;
    assert_ne!(next["transition"]["state"], "outcome_unknown", "{next}");
    assert!(matches!(
        fx.state().as_str(),
        "node_fenced" | "installed" | "released"
    ));
    assert_eq!(fx.node_voids(), 0);
    assert_eq!(fx.voids_sent(), 0);
    // The stale hint is gone with the unknown outcome.
    assert_ne!(next["progress"]["waitReason"], "receipt_unavailable");
    fx.node().close().await;
}

// ---- X7: the connection is replaced -------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn x7_a_create_on_the_old_connection_and_a_void_on_the_new_one_agree() {
    // The delayed frame arrives after the void: refused.
    let fx = fixture().await;
    fx.knobs().hold_create = true;
    let old = fx.connection();
    fx.dispatch().await;
    fx.reconnect();
    assert_ne!(fx.connection(), old, "a new connection");
    // The old connection can no longer send anything for this operation.
    assert!(fx.app.nodes.require_connection("node", old).is_err());
    let result = fx.cancel().await.unwrap();
    assert_eq!(result["transition"]["state"], "released", "{result}");
    let late = fx.deliver_held();
    assert_eq!(late.status, 409);
    assert_eq!(late.body.unwrap()["error"]["code"], "operation_voided");
    assert_eq!((fx.node_fences(), fx.node_voids()), (0, 1));
    assert_eq!(fx.state(), "released");
    fx.node().close().await;

    // The delayed frame arrives before the void: the fence exists, and the void
    // on the new connection reports it instead of writing a void.
    let fx = fixture().await;
    fx.knobs().hold_create = true;
    fx.dispatch().await;
    fx.reconnect();
    assert_eq!(fx.deliver_held().status, 200);
    fx.cancel().await.unwrap();
    assert_eq!((fx.node_fences(), fx.node_voids()), (1, 0));
    assert_ne!(fx.state(), "released_by_void");
    assert_eq!(
        fx.count("SELECT count(*) FROM conversation_transition_voids WHERE result IS NOT NULL"),
        0
    );
    fx.node().close().await;
}

// ---- X8: a crash between the marker and the send -----------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn x8_a_crash_after_the_void_is_requested_and_before_it_is_sent_resumes_with_the_void_only() {
    let mut fx = fixture().await;
    fx.knobs().hold_create = true;
    fx.dispatch().await;
    assert_eq!(fx.creates(), 1);
    // The process dies after committing the marker, at the point it sends the
    // void: the frame never leaves.
    fx.knobs().swallow_void = true;
    let waiting = fx.cancel().await.unwrap();
    assert_eq!(
        waiting["transition"]["state"], "outcome_unknown",
        "{waiting}"
    );
    assert_eq!(waiting["cancellation"]["void"]["state"], "pending");
    assert_eq!(fx.voids_sent(), 1, "the send was attempted and lost");
    assert_eq!(fx.node_voids(), 0, "the Node never saw it");
    assert!(!fx.open());

    // Restart the Gateway on the same database.
    fx.restart_gateway();
    assert_eq!(fx.state(), "outcome_unknown");
    assert_eq!(
        fx.count("SELECT count(*) FROM conversation_transition_voids WHERE result IS NULL"),
        1,
        "the marker survived"
    );
    let creates_before = fx.creates();
    fx.knobs().swallow_void = false;
    // The user does nothing: the sweep resumes with the void.
    let resumed = fx.sweep().await;
    assert_eq!(resumed["transition"]["state"], "released", "{resumed}");
    assert_eq!((fx.node_fences(), fx.node_voids()), (0, 1));
    assert_eq!(
        fx.creates(),
        creates_before,
        "the create is never sent again"
    );
    assert!(fx.open());
    fx.node().close().await;
}

// ---- X9: the Node restarts after the void ------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn x9_the_void_survives_a_node_restart_and_the_delayed_create_is_still_refused() {
    let fx = fixture().await;
    fx.knobs().hold_create = true;
    fx.dispatch().await;
    fx.cancel().await.unwrap();
    assert_eq!(fx.state(), "released");
    fx.restart_node().await;
    assert_eq!(fx.node_voids(), 1, "the void is durable");
    // The delayed original reaches the restarted Node. Its lease died with the
    // old process; the void is checked before it.
    let late = fx.deliver_held();
    assert_eq!(late.status, 409, "{late:?}");
    assert_eq!(late.body.unwrap()["error"]["code"], "operation_voided");
    assert_eq!(fx.node_fences(), 0);
    pirc_node::execution_fences::require_open(&fx.node().db.lock(), &fx.remote).unwrap();
    assert_eq!(fx.state(), "released");
    fx.node().close().await;
}

// ---- X10, X11, X12, X13 -----------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn x10_a_lost_void_reply_is_resent_and_answered_the_same() {
    let fx = fixture().await;
    fx.knobs().hold_create = true;
    fx.dispatch().await;
    fx.knobs().lose_void_replies = 1;
    let waiting = fx.cancel().await.unwrap();
    // The Node decided; the Gateway does not know yet, and stays locked.
    assert_eq!(
        waiting["transition"]["state"], "outcome_unknown",
        "{waiting}"
    );
    assert_eq!(fx.node_voids(), 1);
    assert!(!fx.open());
    let done = fx.sweep().await;
    assert_eq!(done["transition"]["state"], "released", "{done}");
    assert_eq!(fx.node_voids(), 1, "still one void on the Node");
    assert_eq!(fx.voids_sent(), 2);
    fx.node().close().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn x11_cancelling_while_the_node_is_offline_waits_and_converges_when_it_returns() {
    let fx = fixture().await;
    fx.knobs().hold_create = true;
    fx.dispatch().await;
    fx.knobs().offline = true;
    let waiting = fx.cancel().await.unwrap();
    // The intent and the marker are durable; nothing is proven, so it stays locked.
    assert_eq!(
        waiting["transition"]["state"], "outcome_unknown",
        "{waiting}"
    );
    assert_eq!(waiting["reconciliationState"], "node_unavailable");
    assert_eq!(waiting["cancellation"]["void"]["state"], "pending");
    assert!(waiting["cancellation"]["requestedAt"].is_i64());
    assert!(!fx.open());
    assert_eq!(fx.state(), "outcome_unknown");
    // Sweeps while it is offline change nothing.
    fx.sweep().await;
    assert_eq!(fx.state(), "outcome_unknown");
    assert_eq!(fx.voids_sent(), 0);
    // The Node comes back: the sweep sends the void.
    fx.knobs().offline = false;
    let done = fx.sweep().await;
    assert_eq!(done["transition"]["state"], "released", "{done}");
    assert_eq!((fx.node_fences(), fx.node_voids()), (0, 1));
    assert!(fx.open());
    assert_eq!(fx.creates(), 1);
    fx.node().close().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn x12_a_node_that_cannot_void_gets_a_409_and_nothing_changes() {
    let fx = fixture().await;
    fx.knobs().hold_create = true;
    fx.dispatch().await;
    fx.knobs().legacy = true;
    let error = fx.cancel().await.unwrap_err();
    assert_eq!(
        (error.status, code(&error)),
        (409, "transition_void_unsupported")
    );
    assert!(error.message.contains("upgrade"), "{}", error.message);
    // State unchanged: no intent, no marker, no void, still locked.
    assert_eq!(fx.state(), "outcome_unknown");
    assert_eq!(
        fx.count("SELECT count(*) FROM conversation_transition_cancellations"),
        0
    );
    assert_eq!(
        fx.count("SELECT count(*) FROM conversation_transition_voids"),
        0
    );
    assert_eq!(
        (fx.node_fences(), fx.node_voids(), fx.voids_sent()),
        (0, 0, 0)
    );
    assert!(!fx.open());
    // Even a user who already asked (before the Node was downgraded) is never
    // told a void succeeded: the sweep says the Node must be upgraded.
    fx.knobs().legacy = false;
    fx.knobs().offline = true;
    fx.cancel().await.unwrap();
    fx.knobs().offline = false;
    fx.knobs().legacy = true;
    let seen = fx.sweep().await;
    assert_eq!(seen["transition"]["state"], "outcome_unknown");
    assert_eq!(seen["progress"]["waitReason"], "node_upgrade_required");
    assert_eq!(fx.voids_sent(), 0);
    assert_eq!(fx.node_voids(), 0);
    // Upgraded: it converges.
    fx.knobs().legacy = false;
    assert_eq!(fx.sweep().await["transition"]["state"], "released");
    fx.node().close().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_node_that_cannot_void_but_holds_the_fence_cancels_the_ordinary_way() {
    let fx = fixture().await;
    fx.knobs().lose_create_reply = true;
    fx.dispatch().await;
    fx.knobs().legacy = true;
    // The fence exists, so the ordinary release applies; no void is needed.
    let result = fx.cancel().await.unwrap();
    assert_ne!(result["transition"]["state"], "outcome_unknown", "{result}");
    assert_eq!((fx.node_voids(), fx.voids_sent()), (0, 0));
    fx.node().close().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn x13_two_devices_cancelling_at_once_produce_one_void_and_the_same_result() {
    let fx = Arc::new(fixture().await);
    fx.knobs().hold_create = true;
    fx.dispatch().await;
    // A second device takes control after the first asked? Both hold the same
    // lease here; what matters is that the two cancels run at the same time.
    let gate = Arc::new(tokio::sync::Barrier::new(2));
    let run = |fx: Arc<Fixture>, gate: Arc<tokio::sync::Barrier>| {
        tokio::spawn(async move {
            gate.wait().await;
            fx.cancel().await
        })
    };
    let (a, b) = (run(fx.clone(), gate.clone()), run(fx.clone(), gate.clone()));
    let (a, b) = (a.await.unwrap().unwrap(), b.await.unwrap().unwrap());
    for result in [&a, &b] {
        assert_eq!(result["transition"]["state"], "released", "{result}");
        assert_eq!(result["cancellation"]["void"]["state"], "voided");
    }
    assert_eq!(
        a["cancellation"]["void"]["answeredAt"],
        b["cancellation"]["void"]["answeredAt"]
    );
    assert_eq!(
        fx.count("SELECT count(*) FROM conversation_transition_voids"),
        1
    );
    assert_eq!(
        fx.count("SELECT count(*) FROM conversation_transition_cancellations"),
        1
    );
    assert_eq!(fx.node_voids(), 1);
    assert_eq!(fx.node_fences(), 0);
    fx.node().close().await;
}

// ---- X14: a voided identity is never reused ---------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn x14_a_voided_operation_cannot_be_confirmed_or_created_again() {
    let fx = fixture().await;
    fx.knobs().hold_create = true;
    fx.dispatch().await;
    fx.cancel().await.unwrap();
    assert_eq!(fx.state(), "released");
    // Gateway side: the identity is spent.
    let error = receipts::require_unused(&fx.app.db.lock(), "alice", "move-1").unwrap_err();
    assert_eq!((error.status, error.code), (409, "conflict"));
    // Re-confirming returns the receipt (released) and sends nothing to the Node.
    let creates = fx.creates();
    let again = dispatch_once(&fx.app, &identity(), &fx.id, "move-1", fx.connection())
        .await
        .unwrap();
    assert_eq!(again["transition"]["state"], "released");
    let sweep = fx.sweep().await;
    assert_eq!(sweep["transition"]["state"], "released");
    assert_eq!(fx.creates(), creates, "no create request after the void");
    assert_eq!(
        fx.count("SELECT count(*) FROM conversation_transition_acceptances WHERE state!='deleted'"),
        1
    );
    // Node side: the same operation id can never create a fence, whatever its plan.
    let held = fx.knobs().held.remove(0);
    let mut replay = held.clone();
    replay.payload.as_mut().unwrap()["intent"]["planHash"] = json!("b".repeat(64));
    for request in [held, replay] {
        let answer = through(&fx.node(), request).unwrap();
        assert_eq!(answer.status, 409);
        assert_eq!(answer.body.unwrap()["error"]["code"], "operation_voided");
    }
    assert_eq!(fx.node_fences(), 0);
    fx.node().close().await;
}

// ---- X15 and the database's own guarantees ----------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn x15_the_database_refuses_release_without_the_nodes_void_receipt() {
    let fx = fixture().await;
    fx.knobs().hold_create = true;
    fx.dispatch().await;
    let release = "UPDATE conversation_transition_acceptances SET state='released' WHERE operation_id='move-1'";
    let attempt = |sql: &str| fx.app.db.lock().execute(sql, []);
    // No marker, no receipt.
    assert!(attempt(release).is_err());
    // A marker needs the recorded cancellation intent.
    let marker = "INSERT INTO conversation_transition_voids(owner_user,operation_id,session_id,node_id,plan_hash,requested_at) SELECT owner_user,operation_id,session_id,'node','p',1 FROM conversation_transition_acceptances";
    assert!(attempt(marker).is_err(), "no cancellation intent yet");
    attempt("INSERT INTO conversation_transition_cancellations SELECT owner_user,operation_id,session_id,'phone',1 FROM conversation_transition_acceptances").unwrap();
    attempt(marker).unwrap();
    // A marker alone (the request, not the Node's answer) is not a receipt.
    assert!(attempt(release).is_err());
    assert_eq!(fx.state(), "outcome_unknown");
    // The state cannot go back to `accepted`, so the create can never be sent again.
    assert!(attempt("UPDATE conversation_transition_acceptances SET state='accepted'").is_err());
    // The marker is not edited or removed.
    assert!(attempt("UPDATE conversation_transition_voids SET node_id='other'").is_err());
    assert!(attempt("DELETE FROM conversation_transition_voids").is_err());
    // Only with the Node's answer recorded is the release accepted.
    attempt(
        "UPDATE conversation_transition_voids SET result='voided',answer_json='{}',answered_at=2",
    )
    .unwrap();
    attempt(release).unwrap();
    assert_eq!(fx.state(), "released");
    // Final: the answer is not rewritten, and a voided operation has no fence.
    assert!(attempt("UPDATE conversation_transition_voids SET result='voided',answer_json='{\"x\":1}',answered_at=3").is_err());
    assert!(attempt("UPDATE conversation_transition_acceptances SET state='node_fenced'").is_err());
    assert!(
        attempt("INSERT INTO conversation_node_fences VALUES('alice','move-1','s','d','fenced',1)")
            .is_err()
    );
    fx.node().close().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn once_a_void_is_requested_the_original_create_is_never_sent_again() {
    let fx = fixture().await;
    fx.knobs().hold_create = true;
    fx.dispatch().await;
    assert_eq!(fx.creates(), 1);
    fx.knobs().offline = true;
    fx.cancel().await.unwrap();
    fx.knobs().offline = false;
    fx.knobs().swallow_void = true;
    // Every way the Gateway could send again: a repeated dispatch, advance, a
    // sweep, the user cancelling once more. None sends a create.
    for _ in 0..3 {
        dispatch_once(&fx.app, &identity(), &fx.id, "move-1", fx.connection())
            .await
            .unwrap();
        fx.sweep().await;
        let _ = fx.cancel().await;
    }
    assert_eq!(
        fx.creates(),
        1,
        "the original create request is never repeated"
    );
    assert_eq!(fx.state(), "outcome_unknown");
    // The conditional update that sends it is a no-op once the marker exists,
    // even if the state were put back by hand.
    let direct = fx.app.db.lock().execute(
        "UPDATE conversation_transition_acceptances SET state='accepted' WHERE operation_id='move-1'",
        [],
    );
    assert!(direct.is_err());
    fx.node().close().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_cancel_before_dispatch_has_no_void_and_the_status_shape_is_unchanged() {
    let fx = fixture().await;
    let result = fx.cancel().await.unwrap();
    assert_eq!(result["transition"]["state"], "released");
    assert!(result["cancellation"]["requestedAt"].is_i64());
    assert!(result["cancellation"].get("void").is_none());
    assert_eq!(
        fx.count("SELECT count(*) FROM conversation_transition_voids"),
        0
    );
    assert_eq!(fx.creates(), 0);
    fx.node().close().await;
}
