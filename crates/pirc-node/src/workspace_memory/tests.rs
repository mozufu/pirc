use super::*;
use crate::services::Services;
use pirc_agent::session_store::SessionStore;
use pirc_config::{Env, NodeConfig};
use pirc_protocol::{AssistantMessage, NodeRole, UserContent};
pub(crate) struct Fixture {
    _dir: tempfile::TempDir,
    pub(crate) node: Node,
    pub(crate) current: String,
    pub(crate) mode: pirc_protocol::Mode,
    pub(crate) scope: Scope,
    pub(crate) dir: PathBuf,
}
impl Fixture {
    pub(crate) async fn new() -> Self {
        let temp = tempfile::Builder::new()
            .prefix("pirc-w-")
            .tempdir_in("/tmp")
            .unwrap();
        let root = temp.path().canonicalize().unwrap();
        for d in ["repo", "state", "config", "home"] {
            std::fs::create_dir(root.join(d)).unwrap();
        }
        let vars: Vec<(String, String)> = vec![
            ("PIRC_NODE_ID".into(), "memory-test".into()),
            (
                "PIRC_NODE_TOKEN".into(),
                "0123456789abcdef0123456789abcdef".into(),
            ),
            ("PIRC_DAEMON_URL".into(), "ws://127.0.0.1:8787".into()),
            (
                "PIRC_STATE_DIR".into(),
                root.join("state").to_string_lossy().into_owned(),
            ),
            (
                "PIRC_CONFIG_DIR".into(),
                root.join("config").to_string_lossy().into_owned(),
            ),
            (
                "HOME".into(),
                root.join("home").to_string_lossy().into_owned(),
            ),
            ("PIRC_BROWSER".into(), "false".into()),
            ("PIRC_ALLOWED_USERS".into(), "alice".into()),
            (
                "PIRC_SANDBOX_SRT".into(),
                "/missing-memory-test-sandbox".into(),
            ),
            (
                "PIRC_WORKSPACES".into(),
                json!([{"id":"repo","path":root.join("repo")}]).to_string(),
            ),
        ];
        let env = Env::new(vars.iter().map(|(k, v)| (k.as_str(), v.as_str())), &root);
        let config = NodeConfig::load(&env, NodeRole::Node).unwrap();
        let node = Services::start(config, env).await.unwrap();
        let mode = pirc_protocol::mode::default_work();
        node.modes.write().unwrap().insert(
            pirc_protocol::mode::ModeId::new("directory").unwrap(),
            mode.clone(),
        );
        let dir = root.join("source");
        std::fs::create_dir(&dir).unwrap();
        SessionStore::open(dir.clone(), root.join("repo").to_str().unwrap()).unwrap();
        let row = node
            .db
            .lock()
            .create_session("repo", dir.to_str().unwrap(), "alice")
            .unwrap();
        let scope = scope(&node, &row.id, &mode, 0, true).unwrap();
        Self {
            _dir: temp,
            node,
            current: row.id,
            mode,
            scope,
            dir,
        }
    }
    fn view(&self) -> View {
        View::new(&self.node, &self.scope, true).unwrap()
    }
    fn context(&self) -> Value {
        execute(
            &self.view(),
            "workspace.context",
            &json!({"includeBoundaries":true}),
        )
        .unwrap()
    }
    fn mutate(&self, op: &str, extra: Value) -> ApiResult<Value> {
        let context = self.context();
        let mut args = json!({"jobId":format!("job_{}",crate::util::uuid()),"epoch":context["control"]["epoch"],"generation":context["control"]["generation"],"revision":context["control"]["revision"].as_u64().unwrap_or(0),"boundaries":context["boundaries"],"writersStopped":true});
        args.as_object_mut()
            .unwrap()
            .extend(extra.as_object().unwrap().clone());
        execute(&self.view(), op, &args)
    }
    fn turn(&self, text: &str) {
        let mut store = SessionStore::open(self.dir.clone(), "/").unwrap();
        store
            .append(EntryData::Message(Message::User {
                content: UserContent::Text(text.into()),
                timestamp: 1,
            }))
            .unwrap();
        let a:AssistantMessage=serde_json::from_value(json!({"role":"assistant","content":[{"type":"text","text":"Verified"}],"api":"openai-completions","provider":"fake","model":"m","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0},"stopReason":"stop","timestamp":1})).unwrap();
        store
            .append(EntryData::Message(Message::Assistant(a)))
            .unwrap();
    }
    fn commit(&self, empty: bool) -> Value {
        let job = execute(&self.view(), "workspace.next", &json!({})).unwrap();
        assert!(!job.is_null());
        let source = &job["sources"][0];
        let mut args = job.as_object().unwrap().clone();
        args.remove("control");
        args.remove("sources");
        for k in ["epoch", "generation", "revision"] {
            args.insert(k.into(), job["control"][k].clone());
        }
        args.insert("items".into(),if empty{json!([])}else{json!([{"content":"Use SQLite for repository state","sources":[{"sessionId":source["sessionId"],"entryId":source["entryId"]}]}])});
        let args = Value::Object(args);
        execute(&self.view(), "workspace.commit", &args).unwrap();
        args
    }
}
#[tokio::test]
async fn cold_cutover_empty_receipt_clear_and_ack_proof_do_not_claim_unprocessed_sources() {
    let f = Fixture::new().await;
    f.turn("Old backlog");
    assert!(f.context()["legacy"].as_bool().unwrap());
    assert_eq!(
        execute(&f.view(), "workspace.next", &json!({}))
            .unwrap_err()
            .code,
        "workspace_cold_cutover_required"
    );
    f.mutate("workspace.cold", json!({})).unwrap();
    assert!(
        execute(&f.view(), "workspace.next", &json!({}))
            .unwrap()
            .is_null()
    );
    f.turn("New empty interaction");
    f.commit(true);
    assert!(f.context()["items"].as_array().unwrap().is_empty());
    assert_eq!(f.context()["control"]["receipts"][0]["outcome"], "empty");
    f.turn("We use SQLite");
    f.commit(false);
    let c = f.context();
    assert_eq!(c["items"].as_array().unwrap().len(), 1);
    let args = json!({"jobId":"clear_ack","epoch":c["control"]["epoch"],"generation":c["control"]["generation"],"revision":c["control"]["revision"],"boundaries":c["boundaries"]});
    execute(&f.view(), "workspace.clear", &args).unwrap();
    let proof = execute(
        &f.view(),
        "workspace.context",
        &json!({"pendingJobs":[args]}),
    )
    .unwrap();
    assert_eq!(proof["jobs"][0]["proof"]["status"], "committed");
    assert!(proof["items"].as_array().unwrap().is_empty());
    assert!(
        execute(&f.view(), "workspace.next", &json!({}))
            .unwrap()
            .is_null()
    );
    f.node.close().await;
}
#[tokio::test]
async fn source_permission_and_deletion_changes_invalidate_captured_views() {
    let f = Fixture::new().await;
    f.mutate("workspace.cold", json!({})).unwrap();
    f.turn("Source");
    let mut view = f.view();
    execute(&view, "workspace.next", &json!({})).unwrap();
    f.node
        .db
        .lock()
        .execute(
            "UPDATE sessions SET owner_user='bob' WHERE id=?",
            [&f.current],
        )
        .unwrap();
    assert_eq!(view.revalidate(true).unwrap_err().code, "forbidden");
    assert!(scope(&f.node, &f.current, &f.mode, 1, true).is_err());
    let mut chat = f.mode.clone();
    chat.workspace_memory = false;
    assert!(scope(&f.node, &f.current, &chat, 0, true).is_err());
    f.node.close().await;
}
#[tokio::test]
async fn view_pages_survive_empty_receipts_but_not_inventory_changes() {
    let f = Fixture::new().await;
    f.mutate("workspace.cold", json!({})).unwrap();
    f.turn("Original");
    f.commit(false);
    let v = execute(&f.view(), "workspace.context", &json!({"view":true})).unwrap();
    let fingerprint =
        pirc_agent::journal::digest(serde_json::to_string(&v["items"]).unwrap().as_bytes());
    f.turn("Nothing durable");
    f.commit(true);
    let next = execute(
        &f.view(),
        "workspace.context",
        &json!({"view":true,"cursor":{"fingerprint":fingerprint,"offset":0}}),
    )
    .unwrap();
    assert_eq!(next["items"], v["items"]);
    let id = next["items"][0]["id"].clone();
    f.mutate("workspace.forget", json!({"id":id})).unwrap();
    assert_eq!(
        execute(
            &f.view(),
            "workspace.context",
            &json!({"view":true,"cursor":{"fingerprint":fingerprint,"offset":0}})
        )
        .unwrap_err()
        .code,
        "workspace_view_changed"
    );
    f.node.close().await;
}
#[test]
fn restored_or_equal_length_ledgers_cannot_cross_an_acknowledged_hash() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("ledger");
    let raw = b"{\"type\":\"cleared\",\"at\":1}\n";
    std::fs::write(&path, raw).unwrap();
    let state = journal::parse(raw).unwrap();
    let remote =
        json!({"version":2,"watermark":raw.len(),"digest":pirc_agent::journal::digest(raw)});
    assert!(mirror_check(&state, &remote, &path).is_ok());
    let replacement = b"{\"type\":\"cleared\",\"at\":2}\n";
    std::fs::write(&path, replacement).unwrap();
    assert_eq!(
        mirror_check(&journal::parse(replacement).unwrap(), &remote, &path)
            .unwrap_err()
            .code,
        "mirror_rollback"
    );
    assert_eq!(
        mirror_check(&journal::parse(&[]).unwrap(), &remote, &path)
            .unwrap_err()
            .code,
        "mirror_rollback"
    );
}

#[tokio::test]
async fn cold_marker_blocks_restored_legacy_before_any_mirror_ack() {
    let f = Fixture::new().await;
    f.mutate("workspace.cold", json!({})).unwrap();
    let path = ledger(&f.node, &f.scope);
    assert!(path.with_extension("lock").is_dir());
    std::fs::write(&path, b"{\"type\":\"cleared\",\"at\":1}\n").unwrap();
    assert_eq!(
        execute(&f.view(), "workspace.context", &json!({}))
            .unwrap_err()
            .code,
        "workspace_versioned_ledger_missing"
    );
    let c = execute(
        &f.view(),
        "workspace.context",
        &json!({"preparingCutover":true}),
    )
    .unwrap();
    assert!(c["items"].as_array().unwrap().is_empty());
    let args = json!({"jobId":"retry_cold","writersStopped":true});
    execute(&f.view(), "workspace.cold", &args).unwrap();
    assert!(!f.context()["legacy"].as_bool().unwrap());
    f.node.close().await;
}

#[tokio::test]
async fn another_session_reads_committed_work_and_clear_rejects_invented_cutoffs() {
    let mut f = Fixture::new().await;
    f.mutate("workspace.cold", json!({})).unwrap();
    f.turn("Use SQLite for repository state");
    f.commit(false);
    let second = f._dir.path().join("second");
    std::fs::create_dir(&second).unwrap();
    SessionStore::open(second.clone(), "/").unwrap();
    let row = f
        .node
        .db
        .lock()
        .create_session("repo", second.to_str().unwrap(), "alice")
        .unwrap();
    f.scope = scope(&f.node, &row.id, &f.mode, 0, true).unwrap();
    assert_eq!(f.context()["items"].as_array().unwrap().len(), 1);
    // B processes A's next raw interaction without starting A's runner.
    assert!(f.node.runners.get(&f.current).is_none());
    f.turn("A complete later interaction from the original session");
    f.commit(true);
    assert!(
        execute(&f.view(), "workspace.next", &json!({}))
            .unwrap()
            .is_null()
    );
    assert_eq!(
        f.mutate("workspace.clear", json!({"boundaries":[]}))
            .unwrap_err()
            .code,
        "workspace_source_changed"
    );
    let mut invalid = f.context()["boundaries"].clone();
    invalid[0]["afterEntryId"] = json!("not-an-original-source");
    assert_eq!(
        f.mutate("workspace.clear", json!({"boundaries":invalid}))
            .unwrap_err()
            .code,
        "workspace_source_changed"
    );
    assert_eq!(f.context()["items"].as_array().unwrap().len(), 1);
    let mut ack_view = f.view();
    public_control(&ack_view, &ack_view.state).unwrap();
    f.node
        .db
        .lock()
        .execute(
            "UPDATE sessions SET owner_user='bob' WHERE id=?",
            [&f.current],
        )
        .unwrap();
    assert!(ack_view.revalidate(true).is_err());
    assert!(f.context()["items"].as_array().unwrap().is_empty());
    f.node.close().await;
}

#[tokio::test]
async fn forgotten_interaction_stays_suppressed_after_assistant_continuation_and_catchup() {
    let f = Fixture::new().await;
    f.mutate("workspace.cold", json!({})).unwrap();
    f.turn("Use SQLite for repository state");
    f.commit(false);
    let id = f.context()["items"][0]["id"].clone();
    f.mutate("workspace.forget", json!({"id":id})).unwrap();
    let mut store = SessionStore::open(f.dir.clone(), "/").unwrap();
    let continued = store.branch().last().unwrap().data.clone();
    assert!(matches!(
        continued,
        EntryData::Message(Message::Assistant(_))
    ));
    store.append(continued).unwrap();
    drop(store);
    assert!(
        execute(&f.view(), "workspace.next", &json!({}))
            .unwrap()
            .is_null()
    );
    f.mutate("workspace.clear", json!({})).unwrap();
    assert!(
        execute(&f.view(), "workspace.next", &json!({"catchup":true}))
            .unwrap()
            .is_null()
    );
    assert!(f.context()["items"].as_array().unwrap().is_empty());
    f.node.close().await;
}

#[tokio::test]
async fn deleting_source_is_excluded_and_invalidates_another_callers_captured_job() {
    let f = Fixture::new().await;
    f.mutate("workspace.cold", json!({})).unwrap();
    f.turn("Never extract deleted evidence");
    let caller_dir = f.dir.parent().unwrap().join("caller_b");
    SessionStore::open(caller_dir.clone(), "/").unwrap();
    let caller = f
        .node
        .db
        .lock()
        .create_session("repo", caller_dir.to_str().unwrap(), "alice")
        .unwrap();
    let caller_scope = scope(&f.node, &caller.id, &f.mode, 0, true).unwrap();
    let mut captured = View::new(&f.node, &caller_scope, true).unwrap();
    let job = execute(&captured, "workspace.next", &json!({})).unwrap();
    assert!(!job.is_null());
    let revision = captured.state.control.as_ref().unwrap().revision;
    f.node
        .db
        .lock()
        .begin_session_deletion(&f.current, "alice")
        .unwrap();
    assert!(f.dir.join(session_store::SESSION_FILE).exists());
    assert!(captured.revalidate(true).is_err());
    let fresh = View::new(&f.node, &caller_scope, true).unwrap();
    assert!(
        execute(&fresh, "workspace.next", &json!({}))
            .unwrap()
            .is_null()
    );
    let mut args = job.as_object().unwrap().clone();
    for key in ["epoch", "generation", "revision"] {
        args.insert(key.into(), job["control"][key].clone());
    }
    args.insert("items".into(), json!([]));
    args.insert("retire".into(), json!([]));
    assert!(execute(&captured, "workspace.commit", &Value::Object(args)).is_err());
    assert_eq!(
        snapshot(&f.node, &caller_scope)
            .unwrap()
            .control
            .unwrap()
            .revision,
        revision
    );
    f.node.close().await;
}

/// An actual agent speaks RPC to the actual host journal. Only transport delivery
/// is controlled here: the first successful durable ACK is never delivered.
#[tokio::test(flavor = "multi_thread")]
async fn committed_clear_and_forget_survive_lost_ack_resend_and_confirmation() {
    use pirc_conformance::{AgentOptions, AgentRun};
    use std::time::Duration;
    for action in ["clear", "forget"] {
        let options = AgentOptions {
            env: vec![("PIRC_GATEWAY".into(), "1".into())],
            config: json!({"features":{"workspaceMemory":{"passive":true}}}),
            ..Default::default()
        }
        .features("workspace-memory");
        let Some(mut agent) = AgentRun::start(options).await else {
            return;
        };
        let mut f = Fixture::new().await;
        f.mutate("workspace.cold", json!({})).unwrap();
        f.turn("Original repository knowledge");
        f.commit(false);
        let note = f.context()["items"][0]["id"].as_str().unwrap().to_owned();
        let caller = f
            .node
            .db
            .lock()
            .create_session("repo", agent.session_dir.to_str().unwrap(), "alice")
            .unwrap();
        f.scope = scope(&f.node, &caller.id, &f.mode, 0, true).unwrap();
        for op in [
            "workspace.open",
            "workspace.context",
            "workspace.clear",
            "workspace.forget",
        ] {
            agent
                .answers
                .lock()
                .unwrap()
                .gateway
                .insert(op.into(), json!({"hold":true}));
        }
        let command = format!(
            "/om:workspace {action}{}",
            if action == "forget" {
                format!(" {note}")
            } else {
                String::new()
            }
        );
        let op = format!("workspace.{action}");
        let first = host_command(&f, &mut agent, &command, Some((&op, true))).await;
        let original = first
            .iter()
            .find(|e| e["type"] == "gateway_request" && e["op"] == op)
            .unwrap()["args"]
            .clone();
        assert!(first.iter().any(|e| {
            e["method"] == "notify"
                && e["message"]
                    .as_str()
                    .is_some_and(|s| s.contains("outcome may be unknown"))
        }));
        let pending = agent.call(json!({"type":"get_panel_state"})).await;
        assert_eq!(pending["data"]["workspaceMemory"]["pendingMutations"], 1);
        let path = ledger(&f.node, &f.scope);
        let committed = std::fs::read(&path).unwrap();
        let revision = f.context()["control"]["revision"].clone();
        let cutoffs = f.context()["control"]["clearCutoffs"].clone();
        assert!(f.context()["items"].as_array().unwrap().is_empty());
        // Sources advance after the transaction: a retry must not recapture them.
        f.turn("A new interaction after the durable mutation");
        let retry = host_command(&f, &mut agent, &command, Some((&op, false))).await;
        let resent = retry
            .iter()
            .find(|e| e["type"] == "gateway_request" && e["op"] == op)
            .unwrap()["args"]
            .clone();
        assert_eq!(resent, original);
        assert_eq!(std::fs::read(&path).unwrap(), committed);
        assert_eq!(f.context()["control"]["revision"], revision);
        assert_eq!(f.context()["control"]["clearCutoffs"], cutoffs);
        // Losing authority while an ACK is unknown must not expose notes or confirm a job.
        f.node
            .db
            .lock()
            .execute(
                "UPDATE sessions SET owner_user='bob' WHERE id=?",
                [&caller.id],
            )
            .unwrap();
        let denied = host_command(&f, &mut agent, "/om:workspace view", None).await;
        assert!(denied.iter().any(|e| {
            e["method"] == "notify"
                && e["message"]
                    .as_str()
                    .is_some_and(|s| s.contains("authority changed"))
        }));
        assert_eq!(
            agent.call(json!({"type":"get_panel_state"})).await["data"]["workspaceMemory"]["pendingMutations"],
            1
        );
        assert_eq!(std::fs::read(&path).unwrap(), committed);
        f.node
            .db
            .lock()
            .execute(
                "UPDATE sessions SET owner_user='alice' WHERE id=?",
                [&caller.id],
            )
            .unwrap();
        let confirmation = host_command(&f, &mut agent, "/om:workspace view", None).await;
        let query = confirmation
            .iter()
            .find(|e| e["type"] == "gateway_request" && e["op"] == "workspace.context")
            .unwrap();
        assert_eq!(
            query["args"]["pendingJobs"][0],
            json!({"jobId":original["jobId"],"epoch":original["epoch"],"generation":original["generation"],"revision":original["revision"]})
        );
        let proof = execute(&f.view(), "workspace.context", &query["args"]).unwrap();
        assert_eq!(proof["jobs"][0]["proof"]["status"], "committed");
        let pending = agent.call(json!({"type":"get_panel_state"})).await;
        assert_eq!(pending["data"]["workspaceMemory"]["pendingMutations"], 0);
        assert_eq!(std::fs::read(&path).unwrap(), committed);
        // Confirmed retries are still idempotent at the host, even after reopening.
        open_writer(&f.node, &f.scope, &json!({}), true).unwrap();
        execute(&f.view(), &op, &original).unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), committed);
        agent.finish().await;
        f.node.close().await;
    }

    async fn host_command(
        f: &Fixture,
        agent: &mut AgentRun,
        text: &str,
        lost: Option<(&str, bool)>,
    ) -> Vec<Value> {
        agent.command(json!({"type":"prompt","message":text})).await;
        let mut events = Vec::new();
        loop {
            let e = agent.next().await.expect("agent exited");
            if e["type"] == "gateway_request" {
                let op = e["op"].as_str().unwrap();
                let result = host_result(f, &e);
                let result = match result {
                    Ok(result) => result,
                    Err(error) => {
                        agent.send(json!({"type":"gateway_response","id":e["id"],"ok":false,"error":{"code":error.code,"message":error.message,"status":error.status}})).await;
                        events.push(e);
                        continue;
                    }
                };
                if lost.is_some_and(|(target, _)| target == op) {
                    assert_eq!(result["committed"], true);
                    if lost.unwrap().1 {
                        // Let the real production 20s timeout run. No ACK/error is sent.
                        tokio::time::sleep(Duration::from_secs(21)).await;
                    } else {
                        // A repeated durable result is again lost with a transport failure.
                        agent.send(json!({"type":"gateway_response","id":e["id"],"ok":false,"error":{"code":"transport_closed","message":"ACK delivery failed after durable commit","status":503}})).await;
                    }
                } else {
                    agent.send(json!({"type":"gateway_response","id":e["id"],"ok":true,"result":result})).await;
                }
            }
            let done = e["type"] == "extension_ui_request" && e["method"] == "notify";
            events.push(e);
            if done {
                return events;
            }
        }
    }
}

fn host_result(f: &Fixture, event: &Value) -> ApiResult<Value> {
    let op = event["op"].as_str().unwrap();
    let args = &event["args"];
    let current = scope(&f.node, &f.scope.caller, &f.mode, 0, true)?;
    if current != f.scope {
        return Err(ApiError::forbidden("Memory authority changed"));
    }
    if matches!(
        op,
        "workspace.open" | "workspace.clear" | "workspace.forget"
    ) {
        open_writer(&f.node, &f.scope, args, op == "workspace.open")?;
    }
    let mut view = f.view();
    let result = execute(&view, op, args)?;
    view.revalidate(true)?;
    Ok(result)
}
async fn host_answer(
    agent: &mut pirc_conformance::AgentRun,
    event: &Value,
    result: ApiResult<Value>,
) {
    match result {
        Ok(value)=>agent.send(json!({"type":"gateway_response","id":event["id"],"ok":true,"result":value})).await,
        Err(error)=>agent.send(json!({"type":"gateway_response","id":event["id"],"ok":false,"error":{"code":error.code,"message":error.message,"status":error.status}})).await,
    }
}
/// Hold a real request before its host transaction, reject a simultaneous resend,
/// then prove that rejection of a retry cannot settle the original unknown job.
#[tokio::test(flavor = "multi_thread")]
async fn parallel_resend_and_reversible_retry_rejection_preserve_unknown_original() {
    use pirc_conformance::{AgentOptions, AgentRun};
    for action in ["clear", "forget"] {
        let options = AgentOptions {
            env: vec![("PIRC_GATEWAY".into(), "1".into())],
            config: json!({"features":{"workspaceMemory":{"passive":true}}}),
            ..Default::default()
        }
        .features("workspace-memory");
        let Some(mut agent) = AgentRun::start(options).await else {
            return;
        };
        let mut f = Fixture::new().await;
        f.mutate("workspace.cold", json!({})).unwrap();
        f.turn("Original knowledge");
        f.commit(false);
        let note = f.context()["items"][0]["id"].as_str().unwrap().to_owned();
        let caller = f
            .node
            .db
            .lock()
            .create_session("repo", agent.session_dir.to_str().unwrap(), "alice")
            .unwrap();
        f.scope = scope(&f.node, &caller.id, &f.mode, 0, true).unwrap();
        for op in [
            "workspace.open",
            "workspace.context",
            "workspace.clear",
            "workspace.forget",
        ] {
            agent
                .answers
                .lock()
                .unwrap()
                .gateway
                .insert(op.into(), json!({"hold":true}));
        }
        let text = format!(
            "/om:workspace {action}{}",
            if action == "forget" {
                format!(" {note}")
            } else {
                String::new()
            }
        );
        let op = format!("workspace.{action}");
        let path = ledger(&f.node, &f.scope);
        let before = std::fs::read(&path).unwrap();
        agent.command(json!({"type":"prompt","message":text})).await;
        let held = loop {
            let event = agent.next().await.unwrap();
            if event["type"] != "gateway_request" {
                continue;
            }
            if event["op"] == op {
                break event;
            }
            host_answer(&mut agent, &event, host_result(&f, &event)).await;
        };
        agent.command(json!({"type":"prompt","message":text})).await;
        loop {
            let event = agent.next().await.unwrap();
            if event["type"] == "gateway_request" {
                assert_ne!(event["op"], op, "overlapping resend reached host");
                host_answer(&mut agent, &event, host_result(&f, &event)).await;
            }
            if event["method"] == "notify" {
                assert!(
                    event["message"]
                        .as_str()
                        .unwrap()
                        .contains("already running"),
                    "{event}"
                );
                break;
            }
        }
        assert_eq!(std::fs::read(&path).unwrap(), before);
        assert_eq!(
            agent.call(json!({"type":"get_panel_state"})).await["data"]["workspaceMemory"]["pendingMutations"],
            1
        );
        // The original production RPC expires without reaching the host transaction.
        tokio::time::sleep(std::time::Duration::from_secs(21)).await;
        let timeout = agent.until(|e| e["method"] == "notify").await;
        assert!(
            timeout.last().unwrap()["message"]
                .as_str()
                .unwrap()
                .contains("outcome may be unknown")
        );
        let extra = if action == "clear" {
            let dir = f._dir.path().join("temporary-source");
            std::fs::create_dir(&dir).unwrap();
            SessionStore::open(dir.clone(), f._dir.path().join("repo").to_str().unwrap()).unwrap();
            Some(
                f.node
                    .db
                    .lock()
                    .create_session("repo", dir.to_str().unwrap(), "alice")
                    .unwrap(),
            )
        } else {
            None
        };
        // Retry has the original immutable identity, but this attempt cannot commit.
        agent.command(json!({"type":"prompt","message":text})).await;
        loop {
            let event = agent.next().await.unwrap();
            if event["type"] == "gateway_request" {
                if event["op"] == op {
                    assert_eq!(event["args"], held["args"]);
                    let rejected = if action == "clear" {
                        host_result(&f, &event)
                    } else {
                        Err(ApiError::forbidden("Authority temporarily unavailable"))
                    };
                    if action == "clear" {
                        assert_eq!(
                            rejected.as_ref().unwrap_err().code,
                            "workspace_source_changed"
                        );
                    }
                    host_answer(&mut agent, &event, rejected).await;
                } else {
                    host_answer(&mut agent, &event, host_result(&f, &event)).await;
                }
            }
            if event["method"] == "notify" {
                break;
            }
        }
        assert_eq!(std::fs::read(&path).unwrap(), before);
        assert_eq!(
            agent.call(json!({"type":"get_panel_state"})).await["data"]["workspaceMemory"]["pendingMutations"],
            1
        );
        // Same CAS and no durable job is still pending, never evidence of failure.
        agent
            .command(json!({"type":"prompt","message":"/om:workspace view"}))
            .await;
        loop {
            let event = agent.next().await.unwrap();
            if event["type"] == "gateway_request" {
                let result = host_result(&f, &event);
                if event["op"] == "workspace.context" {
                    assert_eq!(
                        result.as_ref().unwrap()["jobs"][0]["proof"]["status"],
                        "pending"
                    );
                }
                host_answer(&mut agent, &event, result).await;
            }
            if event["method"] == "notify" {
                assert!(event["message"].as_str().unwrap().contains("still unknown"));
                break;
            }
        }
        if let Some(row) = extra {
            f.node
                .db
                .lock()
                .execute("DELETE FROM sessions WHERE id=?", [row.id])
                .unwrap();
        }
        // Restore the original source set, then the timed-out original actually commits late.
        let committed = host_result(&f, &held).unwrap();
        assert_eq!(committed["committed"], true);
        // A delayed response for the expired request is ignored; only a new proof settles it.
        host_answer(&mut agent, &held, Ok(committed)).await;
        assert_eq!(
            agent.call(json!({"type":"get_panel_state"})).await["data"]["workspaceMemory"]["pendingMutations"],
            1
        );
        let bytes = std::fs::read(&path).unwrap();
        agent
            .command(json!({"type":"prompt","message":"/om:workspace view"}))
            .await;
        loop {
            let event = agent.next().await.unwrap();
            if event["type"] == "gateway_request" {
                let result = host_result(&f, &event);
                if event["op"] == "workspace.context" {
                    assert_eq!(
                        result.as_ref().unwrap()["jobs"][0]["proof"]["status"],
                        "committed"
                    );
                }
                host_answer(&mut agent, &event, result).await;
            }
            if event["method"] == "notify" {
                assert_eq!(event["message"], "[]");
                break;
            }
        }
        assert_eq!(
            agent.call(json!({"type":"get_panel_state"})).await["data"]["workspaceMemory"]["pendingMutations"],
            0
        );
        host_result(&f, &held).unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), bytes);
        agent.finish().await;
        f.node.close().await;
    }
}

async fn memory_request(
    f: &Fixture,
    agent: &mut pirc_conformance::AgentRun,
    target: &str,
) -> Value {
    loop {
        let event = agent.next().await.expect("agent exited before request");
        if event["type"] == "gateway_request" {
            if event["op"] == target {
                return event;
            }
            host_answer(agent, &event, host_result(f, &event)).await;
        }
        assert_ne!(
            event["method"], "notify",
            "unexpected notice before {target}: {event}"
        );
    }
}
async fn memory_notice(f: &Fixture, agent: &mut pirc_conformance::AgentRun) -> String {
    loop {
        let event = agent.next().await.expect("agent exited before notice");
        if event["type"] == "gateway_request" {
            host_answer(agent, &event, host_result(f, &event)).await;
        }
        if event["method"] == "notify" {
            return event["message"].as_str().unwrap().into();
        }
    }
}
#[tokio::test(flavor = "multi_thread")]
async fn late_views_after_clear_forget_and_newer_unknown_ack_proofs_never_show_old_notes() {
    use pirc_conformance::{AgentOptions, AgentRun};
    for action in ["clear", "forget"] {
        for late_commit in [false, true] {
            let options = AgentOptions {
                env: vec![("PIRC_GATEWAY".into(), "1".into())],
                config: json!({"features":{"workspaceMemory":{"passive":true}}}),
                ..Default::default()
            }
            .features("workspace-memory");
            let Some(mut agent) = AgentRun::start(options).await else {
                return;
            };
            let mut f = Fixture::new().await;
            f.mutate("workspace.cold", json!({})).unwrap();
            f.turn("Original fact");
            f.commit(false);
            let note = f.context()["items"][0]["id"].as_str().unwrap().to_owned();
            let caller = f
                .node
                .db
                .lock()
                .create_session("repo", agent.session_dir.to_str().unwrap(), "alice")
                .unwrap();
            f.scope = scope(&f.node, &caller.id, &f.mode, 0, true).unwrap();
            for op in [
                "workspace.open",
                "workspace.context",
                "workspace.clear",
                "workspace.forget",
            ] {
                agent
                    .answers
                    .lock()
                    .unwrap()
                    .gateway
                    .insert(op.into(), json!({"hold":true}));
            }
            let command = format!(
                "/om:workspace {action}{}",
                if action == "forget" {
                    format!(" {note}")
                } else {
                    String::new()
                }
            );
            let delayed = if late_commit {
                agent
                    .command(json!({"type":"prompt","message":command}))
                    .await;
                let request = memory_request(&f, &mut agent, &format!("workspace.{action}")).await;
                host_answer(
                    &mut agent,
                    &request,
                    Err(ApiError::new(503, "transport_closed", "ACK unavailable")),
                )
                .await;
                assert!(memory_notice(&f, &mut agent).await.contains("original job"));
                Some(request)
            } else {
                None
            };
            agent
                .command(json!({"type":"prompt","message":"/om:workspace view"}))
                .await;
            let held = memory_request(&f, &mut agent, "workspace.context").await;
            let old = host_result(&f, &held).unwrap();
            assert!(!old["items"].as_array().unwrap().is_empty());
            if let Some(request) = delayed {
                assert_eq!(old["jobs"][0]["proof"]["status"], "pending");
                assert_eq!(host_result(&f, &request).unwrap()["committed"], true);
                // No client RPC finishes now: a newer proof is the only local invalidation.
                agent
                    .command(json!({"type":"prompt","message":"/om:workspace view"}))
                    .await;
                assert_eq!(memory_notice(&f, &mut agent).await, "[]");
            } else {
                agent
                    .command(json!({"type":"prompt","message":command}))
                    .await;
                assert!(
                    memory_notice(&f, &mut agent)
                        .await
                        .contains("transaction committed")
                );
            }
            let after = std::fs::read(ledger(&f.node, &f.scope)).unwrap();
            host_answer(&mut agent, &held, Ok(old)).await;
            let notice = memory_notice(&f, &mut agent).await;
            assert!(notice.contains("changed while reading"), "{notice}");
            assert!(!notice.contains("Use SQLite"));
            assert_eq!(
                agent.call(json!({"type":"get_panel_state"})).await["data"]["workspaceMemory"]["pendingMutations"],
                0
            );
            agent
                .command(json!({"type":"prompt","message":"/om:workspace view"}))
                .await;
            assert_eq!(memory_notice(&f, &mut agent).await, "[]");
            assert_eq!(std::fs::read(ledger(&f.node, &f.scope)).unwrap(), after);
            agent.finish().await;
            f.node.close().await;
        }
    }
}
#[tokio::test(flavor = "multi_thread")]
async fn a_real_late_ptc_hook_keeps_its_execution_across_reused_parent_ids_and_restart() {
    use pirc_agent::{handoff, session_store::SessionEntry};
    use pirc_conformance::{AgentOptions, AgentRun, ModelReply};
    let options = AgentOptions {
        config: json!({"hooks":{"beforeTool":[{"matcher":"read","timeoutMs":20000,"command":"if [ ! -f first-started ]; then touch first-started; while [ ! -f release-old ]; do sleep 0.05; done; else touch second-started; while [ ! -f release-new ]; do sleep 0.05; done; fi"}]}}),
        files: vec![("a.txt".into(), "evidence".into())],
        ..Default::default()
    };
    let Some(mut agent) = AgentRun::start(options).await else {
        return;
    };
    let tools = |timeout: f64| {
        ModelReply::Tools(vec![(
            "same".into(),
            "ptc".into(),
            json!({"code":"return await tools.read({path:'a.txt'});","timeout":timeout}),
        )])
    };
    agent.push([tools(0.5), ModelReply::Text("First script ended".into())]);
    agent
        .call(json!({"type":"prompt","message":"first interaction"}))
        .await;
    agent.settle().await;
    assert!(agent.workspace.join("first-started").exists());
    let raw = agent.session_entries();
    let outer = raw
        .iter()
        .find(|e| e["message"]["role"] == "toolResult" && e["message"]["toolCallId"] == "same")
        .unwrap();
    let execution = outer["message"]["details"]["executionId"]
        .as_str()
        .unwrap()
        .to_owned();
    assert!(!raw.iter().any(|e| e["customType"] == "ptc.operation"));
    agent.push([tools(15.0), ModelReply::Text("Second script ended".into())]);
    agent
        .call(json!({"type":"prompt","message":"second interaction"}))
        .await;
    agent
        .until(|e| {
            e["type"] == "tool_execution_start"
                && e["toolName"] == "read"
                && e["parentToolCallId"] == "same"
        })
        .await;
    std::fs::write(agent.workspace.join("release-old"), "").unwrap();
    agent
        .until(|e| {
            e["type"] == "tool_execution_end"
                && e["parentToolCallId"] == "same"
                && e["toolCallId"]
                    .as_str()
                    .is_some_and(|id| id.starts_with(&execution))
        })
        .await;
    std::fs::write(agent.workspace.join("release-new"), "").unwrap();
    agent.settle().await;
    let raw = agent.session_entries();
    let late = raw
        .iter()
        .position(|e| {
            e["customType"] == "ptc.operation"
                && e["data"]["toolCallId"]
                    .as_str()
                    .is_some_and(|id| id.starts_with(&execution))
        })
        .unwrap();
    let calls: Vec<_> = raw
        .iter()
        .enumerate()
        .filter_map(|(i, e)| {
            (e["message"]["content"][0]["type"] == "toolCall"
                && e["message"]["content"][0]["id"] == "same")
                .then_some(i)
        })
        .collect();
    assert_eq!(calls.len(), 2);
    assert!(late > calls[1]);
    let branch: Vec<SessionEntry> = raw
        .into_iter()
        .map(|e| serde_json::from_value(e).unwrap())
        .collect();
    assert!(handoff::boundaries(&branch).is_ok());
    assert!(handoff::boundaries_before(&branch[..late], &branch[late..]).is_err());
    assert!(
        handoff::sources(&branch)
            .iter()
            .any(|s| s.entry_id == branch[late].id && s.role == "operation:read")
    );
    let Some(mut agent) = agent.restart(AgentOptions::default()).await else {
        panic!("agent failed to restart")
    };
    let reopened: Vec<SessionEntry> = agent
        .session_entries()
        .into_iter()
        .map(|e| serde_json::from_value(e).unwrap())
        .collect();
    assert!(handoff::boundaries(&reopened).is_ok());
    assert!(handoff::boundaries_before(&reopened[..late], &reopened[late..]).is_err());
    agent.push([ModelReply::Text("Resumed".into())]);
    agent
        .call(json!({"type":"prompt","message":"Continue after restart"}))
        .await;
    agent.settle().await;
    let requests = agent.take_requests();
    let messages = requests.last().unwrap()["messages"].as_array().unwrap();
    assert_eq!(
        messages
            .iter()
            .filter(|m| m["role"] == "toolResult" && m["toolCallId"] == "same")
            .count(),
        2
    );
    agent.finish().await;
}
#[tokio::test]
async fn work_extraction_keeps_late_ptc_evidence_in_a_complete_range_and_respects_clear() {
    let f = Fixture::new().await;
    f.mutate("workspace.cold", json!({})).unwrap();
    let mut store = SessionStore::open(f.dir.clone(), "/").unwrap();
    let user = |text: &str| {
        EntryData::Message(Message::User {
            content: UserContent::Text(text.into()),
            timestamp: 1,
        })
    };
    let assistant = |content: Value, reason: &str| {
        EntryData::Message(serde_json::from_value(json!({"role":"assistant","content":content,"api":"x","provider":"x","model":"x","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0},"stopReason":reason,"timestamp":1})).unwrap())
    };
    let first = store.append(user("first")).unwrap();
    store
        .append(assistant(
            json!([{"type":"toolCall","id":"same","name":"ptc","arguments":{}}]),
            "toolUse",
        ))
        .unwrap();
    store
        .append(EntryData::Message(Message::ToolResult {
            tool_call_id: "same".into(),
            tool_name: "ptc".into(),
            content: vec![],
            details: Some(json!({"executionId":"old"})),
            is_error: true,
            timestamp: 1,
        }))
        .unwrap();
    store
        .append(assistant(
            json!([{"type":"text","text":"first completed"}]),
            "stop",
        ))
        .unwrap();
    store.append(user("second")).unwrap();
    store.append(EntryData::Custom{custom_type:"ptc.operation".into(),data:json!({"parentToolCallId":"same","toolCallId":"old:op1","toolName":"read","content":[{"type":"text","text":"late evidence"}]})}).unwrap();
    let last = store
        .append(assistant(
            json!([{"type":"text","text":"second completed"}]),
            "stop",
        ))
        .unwrap();
    let job = execute(&f.view(), "workspace.next", &json!({})).unwrap();
    assert_eq!(job["fromEntryId"], first.id);
    assert_eq!(job["throughEntryId"], last.id);
    assert!(
        job["sources"]
            .as_array()
            .unwrap()
            .iter()
            .any(|e| e["role"] == "operation:read")
    );
    f.commit(true);
    assert!(
        execute(&f.view(), "workspace.next", &json!({}))
            .unwrap()
            .is_null()
    );
    f.mutate(
        "workspace.clear",
        json!({"boundaries":f.context()["boundaries"]}),
    )
    .unwrap();
    assert!(
        execute(&f.view(), "workspace.next", &json!({}))
            .unwrap()
            .is_null()
    );
    f.node.close().await;
}

#[tokio::test]
async fn clear_and_forget_keep_new_admissions_while_fencing_late_revoked_operations() {
    for action in ["clear", "forget"] {
        let f = Fixture::new().await;
        f.mutate("workspace.cold", json!({})).unwrap();
        let mut store = SessionStore::open(f.dir.clone(), "/").unwrap();
        let user = |text: &str| {
            EntryData::Message(Message::User {
                content: UserContent::Text(text.into()),
                timestamp: 1,
            })
        };
        let assistant = |content: Value, reason: &str| {
            EntryData::Message(serde_json::from_value(json!({"role":"assistant","content":content,"api":"x","provider":"x","model":"x","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0},"stopReason":reason,"timestamp":1})).unwrap())
        };
        let old_source = store.append(user("old source")).unwrap();
        store
            .append(assistant(
                json!([{"type":"toolCall","id":"same","name":"ptc","arguments":{}}]),
                "toolUse",
            ))
            .unwrap();
        store
            .append(EntryData::Message(Message::ToolResult {
                tool_call_id: "same".into(),
                tool_name: "ptc".into(),
                content: vec![],
                details: Some(json!({"executionId":"old"})),
                is_error: true,
                timestamp: 1,
            }))
            .unwrap();
        store
            .append(assistant(
                json!([{"type":"text","text":"old range completed"}]),
                "stop",
            ))
            .unwrap();
        f.commit(false);
        let c = f.context();
        let id = c["items"][0]["id"].clone();
        f.mutate(
            &format!("workspace.{action}"),
            json!({"id":id,"boundaries":c["boundaries"]}),
        )
        .unwrap();
        let fresh_source = store
            .append(user("New repository convention: use PostgreSQL"))
            .unwrap();
        store.append(EntryData::Custom{custom_type:"ptc.operation".into(),data:json!({"parentToolCallId":"same","toolCallId":"old:op1","toolName":"read","content":[{"type":"text","text":"revoked old evidence"}]})}).unwrap();
        store
            .append(assistant(
                json!([{"type":"text","text":"interleaved completed"}]),
                "stop",
            ))
            .unwrap();
        let job = execute(&f.view(), "workspace.next", &json!({})).unwrap();
        assert_eq!(job["fromEntryId"], fresh_source.id);
        let sources = job["sources"].to_string();
        assert!(sources.contains("New repository convention"));
        assert!(!sources.contains("old source"));
        assert!(!sources.contains("revoked old evidence"));
        assert!(!sources.contains("operation:read"));
        let mut args = job.as_object().unwrap().clone();
        args.remove("control");
        args.remove("sources");
        for key in ["epoch", "generation", "revision"] {
            args.insert(key.into(), job["control"][key].clone());
        }
        let candidate = |id: &str| json!([{"content":"Use PostgreSQL for new repository work","sources":[{"sessionId":job["sessionId"],"entryId":id}]}]);
        args.insert("items".into(), candidate(&old_source.id));
        let before = std::fs::read(ledger(&f.node, &f.scope)).unwrap();
        assert!(execute(&f.view(), "workspace.commit", &Value::Object(args.clone())).is_err());
        assert_eq!(std::fs::read(ledger(&f.node, &f.scope)).unwrap(), before);
        args.insert("items".into(), candidate(&fresh_source.id));
        execute(&f.view(), "workspace.commit", &Value::Object(args)).unwrap();
        assert_eq!(
            f.context()["items"][0]["content"],
            "Use PostgreSQL for new repository work"
        );
        drop(store);
        SessionStore::open(f.dir.clone(), "/").unwrap();
        assert!(
            execute(&f.view(), "workspace.next", &json!({}))
                .unwrap()
                .is_null()
        );
        f.turn("independent fresh source");
        let job = execute(&f.view(), "workspace.next", &json!({})).unwrap();
        assert!(!job.is_null());
        assert!(!job["sources"].to_string().contains("revoked old evidence"));
        f.node.close().await;
    }
}

#[tokio::test]
async fn cold_and_clear_filter_late_results_and_operations_by_original_admission() {
    for action in ["cold", "clear"] {
        let f = Fixture::new().await;
        if action == "clear" {
            f.mutate("workspace.cold", json!({})).unwrap();
        }
        let mut store = SessionStore::open(f.dir.clone(), "/").unwrap();
        store
            .append(EntryData::Message(Message::User {
                content: UserContent::Text("pre-boundary evidence".into()),
                timestamp: 1,
            }))
            .unwrap();
        let call = serde_json::from_value(json!({"role":"assistant","content":[{"type":"toolCall","id":"old","name":"ptc","arguments":{}}],"api":"x","provider":"x","model":"x","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0},"stopReason":"toolUse","timestamp":1})).unwrap();
        store.append(EntryData::Message(call)).unwrap();
        f.mutate(&format!("workspace.{action}"), json!({})).unwrap();
        let fresh = store
            .append(EntryData::Message(Message::User {
                content: UserContent::Text("New independent repository evidence".into()),
                timestamp: 1,
            }))
            .unwrap();
        let done = serde_json::from_value(json!({"role":"assistant","content":[{"type":"text","text":"New interaction completed"}],"api":"x","provider":"x","model":"x","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0},"stopReason":"stop","timestamp":1})).unwrap();
        store.append(EntryData::Message(done)).unwrap();
        store
            .append(EntryData::Message(Message::ToolResult {
                tool_call_id: "old".into(),
                tool_name: "ptc".into(),
                content: vec![pirc_protocol::UserBlock::Text {
                    text: "late old result".into(),
                    text_signature: None,
                }],
                details: Some(json!({"executionId":"old"})),
                is_error: true,
                timestamp: 1,
            }))
            .unwrap();
        let late = store.append(EntryData::Custom {custom_type:"ptc.operation".into(),data:json!({"parentToolCallId":"old","toolCallId":"old:op1","toolName":"read","content":[{"type":"text","text":"late old operation"}]})}).unwrap();
        let job = execute(&f.view(), "workspace.next", &json!({})).unwrap();
        assert_eq!(job["fromEntryId"], fresh.id);
        let sources = job["sources"].to_string();
        assert!(sources.contains("New independent"));
        assert!(!sources.contains("pre-boundary"));
        assert!(!sources.contains("late old"));
        assert!(!sources.contains(&late.id));
        f.commit(true);
        assert!(
            execute(&f.view(), "workspace.next", &json!({}))
                .unwrap()
                .is_null()
        );
        f.node.close().await;
    }
}

fn ambiguous_legacy_ptc(store: &mut SessionStore, completed: bool) -> (String, String) {
    let user = |text: &str| {
        EntryData::Message(Message::User {
            content: UserContent::Text(text.into()),
            timestamp: 1,
        })
    };
    let call = || {
        EntryData::Message(serde_json::from_value(json!({"role":"assistant","content":[{"type":"toolCall","id":"reused","name":"ptc","arguments":{}}],"api":"x","provider":"x","model":"x","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0},"stopReason":"toolUse","timestamp":1})).unwrap())
    };
    let result = || {
        EntryData::Message(Message::ToolResult {
            tool_call_id: "reused".into(),
            tool_name: "ptc".into(),
            content: vec![],
            details: None,
            is_error: true,
            timestamp: 1,
        })
    };
    let first = store
        .append(user("Legacy source that must not be guessed"))
        .unwrap();
    store.append(call()).unwrap();
    store.append(result()).unwrap();
    store
        .append(user("Second legacy source without execution metadata"))
        .unwrap();
    store.append(call()).unwrap();
    let operation = store.append(EntryData::Custom {custom_type:"ptc.operation".into(),data:json!({"parentToolCallId":"reused","toolCallId":"missing:op1","toolName":"read","content":[{"type":"text","text":"Ambiguous legacy evidence"}]})}).unwrap();
    if completed {
        store.append(result()).unwrap();
    }
    (first.id, operation.id)
}

#[tokio::test]
async fn permanent_ptc_ambiguity_blocks_only_related_sources_and_is_reported() {
    for completed in [true, false] {
        let f = Fixture::new().await;
        f.mutate("workspace.cold", json!({})).unwrap();
        let mut store = SessionStore::open(f.dir.clone(), "/").unwrap();
        let (old, operation) = ambiguous_legacy_ptc(&mut store, completed);
        drop(store);
        f.turn("Fresh independent fact: use SQLite for repository state");
        let job = execute(&f.view(), "workspace.next", &json!({})).unwrap();
        assert!(
            !job.is_null(),
            "independent sources must not disappear behind old ambiguity"
        );
        let sources = job["sources"].to_string();
        assert!(sources.contains("Fresh independent fact"));
        assert!(!sources.contains("Legacy source"));
        assert!(!sources.contains("Ambiguous legacy evidence"));
        assert!(!sources.contains(&old));
        assert!(!sources.contains(&operation));
        let mut invalid = job.as_object().unwrap().clone();
        invalid.remove("control");
        invalid.remove("sources");
        for key in ["epoch", "generation", "revision"] {
            invalid.insert(key.into(), job["control"][key].clone());
        }
        invalid.insert("items".into(),json!([{"content":"Must not promote ambiguous evidence","sources":[{"sessionId":job["sessionId"],"entryId":operation}]}]));
        let before = std::fs::read(ledger(&f.node, &f.scope)).unwrap();
        assert_eq!(
            execute(&f.view(), "workspace.commit", &Value::Object(invalid))
                .unwrap_err()
                .code,
            "invalid_input"
        );
        assert_eq!(std::fs::read(ledger(&f.node, &f.scope)).unwrap(), before);
        f.commit(false);
        let bytes = std::fs::read(ledger(&f.node, &f.scope)).unwrap();
        let blocked = execute(&f.view(), "workspace.next", &json!({})).unwrap_err();
        assert_eq!(blocked.code, "workspace_source_blocked");
        assert!(blocked.message.contains("blocked"));
        assert_eq!(std::fs::read(ledger(&f.node, &f.scope)).unwrap(), bytes);
        assert_eq!(
            f.context()["control"]["receipts"].as_array().unwrap().len(),
            1
        );
        assert_eq!(
            f.context()["control"]["receipts"][0]["fromEntryId"],
            job["fromEntryId"]
        );
        SessionStore::open(f.dir.clone(), "/").unwrap();
        f.turn("Another independent admission");
        f.commit(true);
        assert_eq!(
            execute(&f.view(), "workspace.next", &json!({}))
                .unwrap_err()
                .code,
            "workspace_source_blocked"
        );
        assert_eq!(f.context()["items"].as_array().unwrap().len(), 1);
        f.node.close().await;
    }
}

#[tokio::test]
async fn pre_cutover_ptc_ambiguity_does_not_block_new_work_but_catchup_reports_it() {
    let f = Fixture::new().await;
    let mut store = SessionStore::open(f.dir.clone(), "/").unwrap();
    let (_, operation) = ambiguous_legacy_ptc(&mut store, true);
    let before = std::fs::read(f.dir.join(session_store::SESSION_FILE)).unwrap();
    drop(store);
    f.mutate("workspace.cold", json!({})).unwrap();
    f.turn("First post-cutover independent fact");
    let job = execute(&f.view(), "workspace.next", &json!({})).unwrap();
    assert!(!job.is_null());
    assert!(job["sources"].to_string().contains("First post-cutover"));
    assert!(!job["sources"].to_string().contains(&operation));
    f.commit(false);
    assert!(
        execute(&f.view(), "workspace.next", &json!({}))
            .unwrap()
            .is_null()
    );
    let blocked = execute(&f.view(), "workspace.next", &json!({"catchup":true})).unwrap_err();
    assert_eq!(blocked.code, "workspace_source_blocked");
    let after = std::fs::read(f.dir.join(session_store::SESSION_FILE)).unwrap();
    assert!(after.starts_with(&before));
    SessionStore::open(f.dir.clone(), "/").unwrap();
    f.turn("Second post-cutover independent fact");
    f.commit(true);
    assert!(
        execute(&f.view(), "workspace.next", &json!({}))
            .unwrap()
            .is_null()
    );
    assert_eq!(
        execute(&f.view(), "workspace.next", &json!({"catchup":true}))
            .unwrap_err()
            .code,
        "workspace_source_blocked"
    );
    assert_eq!(
        f.context()["control"]["receipts"].as_array().unwrap().len(),
        2
    );
    f.node.close().await;
}

#[tokio::test]
async fn unbounded_ptc_ambiguity_reports_blocked_without_starving_other_authorized_sessions() {
    let f = Fixture::new().await;
    f.mutate("workspace.cold", json!({})).unwrap();
    let mut store = SessionStore::open(f.dir.clone(), "/").unwrap();
    store.append(EntryData::Custom {custom_type:"ptc.operation".into(),data:json!({"parentToolCallId":"unknown","toolCallId":"foreign:op1","toolName":"read"})}).unwrap();
    drop(store);
    f.turn("Source with an unclassifiable earlier operation");
    assert_eq!(
        execute(&f.view(), "workspace.next", &json!({}))
            .unwrap_err()
            .code,
        "workspace_source_blocked"
    );
    let dir = f._dir.path().join("independent-source");
    let mut store = SessionStore::open(dir.clone(), "/").unwrap();
    store
        .append(EntryData::Message(Message::User {
            content: UserContent::Text("Another authorized session's independent source".into()),
            timestamp: 1,
        }))
        .unwrap();
    store.append(EntryData::Message(serde_json::from_value(json!({"role":"assistant","content":[{"type":"text","text":"Verified"}],"api":"x","provider":"x","model":"x","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0},"stopReason":"stop","timestamp":1})).unwrap())).unwrap();
    f.node
        .db
        .lock()
        .create_session("repo", dir.to_str().unwrap(), "alice")
        .unwrap();
    let job = execute(&f.view(), "workspace.next", &json!({})).unwrap();
    assert!(!job.is_null());
    assert!(
        job["sources"]
            .to_string()
            .contains("Another authorized session")
    );
    f.commit(true);
    assert_eq!(
        execute(&f.view(), "workspace.next", &json!({}))
            .unwrap_err()
            .code,
        "workspace_source_blocked"
    );
    f.node.close().await;
}

#[tokio::test]
async fn large_repository_history_streams_across_sources_and_preserves_evicted_evidence() {
    let mut f = Fixture::new().await;
    let mut dirs = vec![f.dir.clone()];
    for i in 1..3 {
        let dir = f._dir.path().join(format!("large-source-{i}"));
        SessionStore::open(dir.clone(), "/").unwrap();
        f.node
            .db
            .lock()
            .create_session("repo", dir.to_str().unwrap(), "alice")
            .unwrap();
        dirs.push(dir);
    }
    // Three independently valid journals exceed the former 64 MiB request cap.
    // Custom archived payload is private state, never extraction evidence.
    for dir in &dirs {
        let mut store = SessionStore::open(dir.clone(), "/").unwrap();
        store
            .append(EntryData::Custom {
                custom_type: "archived-test-payload".into(),
                data: json!({"padding":"x".repeat(23 * 1024 * 1024)}),
            })
            .unwrap();
    }
    let total: u64 = dirs
        .iter()
        .map(|d| {
            std::fs::metadata(d.join(session_store::SESSION_FILE))
                .unwrap()
                .len()
        })
        .sum();
    assert!(total > pirc_agent::journal::MAX_BYTES);
    f.mutate("workspace.cold", json!({})).unwrap();
    // Routine refresh reads identities only, without parsing unrelated bodies.
    let lean = f.view();
    let context = execute(&lean, "workspace.context", &json!({})).unwrap();
    assert!(context["boundaries"].is_null());
    assert!(lean.cache.borrow().is_empty());
    for (i, dir) in dirs.iter().enumerate() {
        f.dir = dir.clone();
        f.turn(&format!("Durable repository convention {i}"));
        let job = execute(&f.view(), "workspace.next", &json!({})).unwrap();
        assert!(!job.is_null());
        let mut args = job.as_object().unwrap().clone();
        for k in ["epoch", "generation", "revision"] {
            args.insert(k.into(), job["control"][k].clone());
        }
        args.insert("items".into(), json!([{"content":format!("Convention {i}"),"sources":[{"sessionId":job["sessionId"],"entryId":job["sources"][0]["entryId"]}]}]));
        execute(&f.view(), "workspace.commit", &Value::Object(args)).unwrap();
    }
    let mut captured = f.view();
    let notes = execute(&captured, "workspace.context", &json!({})).unwrap();
    assert_eq!(notes["items"].as_array().unwrap().len(), 3);
    assert!(captured.bytes.get() <= pirc_agent::journal::MAX_BYTES);
    assert_eq!(captured.fingerprints.borrow().len(), 3);
    assert!(
        captured.cache.borrow().len() < 3,
        "parsed branches must be evicted"
    );
    captured.revalidate(true).unwrap();
    assert!(
        execute(&f.view(), "workspace.next", &json!({}))
            .unwrap()
            .is_null()
    );
    let evicted = captured
        .rows
        .iter()
        .find(|row| !captured.cache.borrow().contains_key(&row.id))
        .unwrap()
        .clone();
    // A later append to an evicted source still invalidates the request.
    SessionStore::open(PathBuf::from(&evicted.private_session_path), "/")
        .unwrap()
        .append(EntryData::Custom {
            custom_type: "concurrent-change".into(),
            data: json!({}),
        })
        .unwrap();
    assert_eq!(
        captured.revalidate(true).unwrap_err().code,
        "source_changed"
    );
    assert_eq!(
        captured.source(&evicted).unwrap_err().code,
        "source_changed"
    );
    f.mutate("workspace.clear", json!({})).unwrap();
    assert!(f.context()["items"].as_array().unwrap().is_empty());
    assert!(
        execute(&f.view(), "workspace.next", &json!({}))
            .unwrap()
            .is_null()
    );
    f.node.close().await;
}

#[tokio::test]
async fn control_identity_checks_reject_replaced_headers_and_source_symlinks() {
    let f = Fixture::new().await;
    f.mutate("workspace.cold", json!({})).unwrap();
    let row = f.node.db.lock().get_session(&f.current).unwrap();
    let mut view = f.view();
    let id = view.source_id(&row).unwrap();
    f.node
        .db
        .lock()
        .execute(
            "UPDATE sessions SET pi_session_id=? WHERE id=?",
            [&id, &f.current],
        )
        .unwrap();
    let path = f.dir.join(session_store::SESSION_FILE);
    let mut header: Value = serde_json::from_str(
        std::fs::read_to_string(&path)
            .unwrap()
            .lines()
            .next()
            .unwrap(),
    )
    .unwrap();
    header["sessionId"] = json!("replacement-session");
    std::fs::write(&path, format!("{header}\n")).unwrap();
    assert!(view.revalidate(true).is_err());
    assert_eq!(
        execute(&f.view(), "workspace.context", &json!({}))
            .unwrap_err()
            .code,
        "source_identity_changed"
    );
    let moved = path.with_extension("original");
    std::fs::rename(&path, &moved).unwrap();
    std::os::unix::fs::symlink(&moved, &path).unwrap();
    assert_eq!(
        execute(&f.view(), "workspace.context", &json!({}))
            .unwrap_err()
            .code,
        "source_unavailable"
    );
    f.node.close().await;
}

fn pending_host(f: &Fixture, state: &str, owner: &str, path: Option<&Path>) {
    let db = f.node.db.lock();
    db.execute("INSERT INTO host_command_runs(id,session_id,workspace_id,runner_epoch,incarnation,request_id,state,created_at,updated_at) VALUES('host-cutover',?1,'original-workspace',0,'previous-node','request',?2,1,1)", rusqlite::params![owner,state]).unwrap();
    if let Some(path) = path {
        crate::host_commands::resources::record(
            &db,
            "host-cutover",
            &[path.to_string_lossy().into_owned()],
        )
        .unwrap();
    }
}
#[tokio::test]
async fn cold_cutover_refuses_own_or_orphan_host_ranges_without_altering_memory() {
    for (state, orphan, direct_ledger) in [
        ("launching", false, false),
        ("running", true, false),
        ("unconfirmed", true, true),
    ] {
        let f = Fixture::new().await;
        let path = ledger(&f.node, &f.scope);
        let root = Path::new(&f.scope.root);
        pending_host(
            &f,
            state,
            if orphan {
                "deleted-session"
            } else {
                &f.current
            },
            Some(if direct_ledger { &path } else { root }),
        );
        let before = std::fs::read(&path).ok();
        assert!(!f.node.runners.may_be_alive(&f.current));
        assert_eq!(
            f.mutate("workspace.cold", json!({})).unwrap_err().code,
            "host_write_pending"
        );
        assert_eq!(std::fs::read(&path).ok(), before);
        assert!(!path.with_extension("lock").exists());
        assert!(snapshot(&f.node, &f.scope).unwrap().control.is_none());
        f.node.close().await;
    }
}
#[tokio::test]
async fn cold_cutover_waits_for_settlement_and_keeps_idempotent_receipts() {
    let f = Fixture::new().await;
    pending_host(&f, "running", &f.current, Some(Path::new(&f.scope.root)));
    let args = json!({"jobId":"cold_host_retry","writersStopped":true});
    let captured = f.view();
    assert_eq!(
        execute(&captured, "workspace.cold", &args)
            .unwrap_err()
            .code,
        "host_write_pending"
    );
    f.node
        .db
        .lock()
        .execute(
            "UPDATE host_command_runs SET state='settled' WHERE id='host-cutover'",
            [],
        )
        .unwrap();
    let committed = execute(&captured, "workspace.cold", &args).unwrap();
    assert_eq!(committed["committed"], true);
    let before = std::fs::read(ledger(&f.node, &f.scope)).unwrap();
    // Another pending legacy effect after commit does not turn retry into a new
    // initialization or negate a previously committed immutable job.
    f.node.db.lock().execute("INSERT INTO host_command_runs(id,session_id,workspace_id,runner_epoch,incarnation,request_id,state,created_at,updated_at) VALUES('later','deleted-session','removed-workspace',0,'previous-node','later','running',1,1)",[]).unwrap();
    assert_eq!(
        execute(&f.view(), "workspace.cold", &args).unwrap()["committed"],
        true
    );
    assert_eq!(std::fs::read(ledger(&f.node, &f.scope)).unwrap(), before);
    f.node.close().await;
}
#[tokio::test]
async fn cold_cutover_allows_disjoint_known_hosts_but_not_missing_inventory() {
    let f = Fixture::new().await;
    pending_host(
        &f,
        "running",
        "unrelated-owner",
        Some(&f.dir.join("other-project")),
    );
    assert_eq!(
        f.mutate("workspace.cold", json!({})).unwrap()["committed"],
        true
    );
    f.node.close().await;
    let f = Fixture::new().await;
    pending_host(&f, "running", "legacy-owner", None);
    assert_eq!(
        f.mutate("workspace.cold", json!({})).unwrap_err().code,
        "host_write_pending"
    );
    assert!(snapshot(&f.node, &f.scope).unwrap().control.is_none());
    f.node.close().await;
    let f = Fixture::new().await;
    f.node
        .db
        .lock()
        .execute_batch("DROP TABLE host_command_resources")
        .unwrap();
    assert!(f.mutate("workspace.cold", json!({})).is_err());
    assert!(snapshot(&f.node, &f.scope).unwrap().control.is_none());
    f.node.close().await;
}

#[tokio::test]
async fn cold_writer_open_cannot_repair_a_tail_while_a_known_host_is_pending() {
    let f = Fixture::new().await;
    let path = ledger(&f.node, &f.scope);
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    let raw = b"{\"type\":\"cleared\",\"at\":1}\n{\"type\":";
    std::fs::write(&path, raw).unwrap();
    pending_host(&f, "running", &f.current, Some(Path::new(&f.scope.root)));
    // Ordinary legacy reads do not opt into repair or activation.
    open_writer(&f.node, &f.scope, &json!({}), true).unwrap();
    assert_eq!(std::fs::read(&path).unwrap(), raw);
    assert_eq!(
        open_writer(&f.node, &f.scope, &json!({"writersStopped":true}), false)
            .unwrap_err()
            .code,
        "host_write_pending"
    );
    assert_eq!(std::fs::read(&path).unwrap(), raw);
    f.node
        .db
        .lock()
        .execute(
            "UPDATE host_command_runs SET state='settled' WHERE id='host-cutover'",
            [],
        )
        .unwrap();
    open_writer(&f.node, &f.scope, &json!({"writersStopped":true}), false).unwrap();
    assert!(journal::read(&path).unwrap().control.is_none());
    assert_ne!(std::fs::read(&path).unwrap(), raw);
    f.mutate("workspace.cold", json!({})).unwrap();
    f.node.close().await;
}
