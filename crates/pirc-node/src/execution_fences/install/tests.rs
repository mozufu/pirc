use super::*;
use crate::store::ModeId;
use pirc_protocol::{HttpMethod, NodeHttpRequest};

struct Fixture {
    dir: tempfile::TempDir,
    node: Node,
    router: crate::router::Router,
    session: String,
    generation: i64,
}
const PLAN: &str = "abababababababababababababababababababababababababababababababab";
impl Fixture {
    /// A drained, resource-bound fence from `repo` to `target`. `ran` simulates an
    /// Agent run before the transition (unproven without kernel containment).
    async fn new(op: &str, ran: bool, drain: bool) -> Self {
        let (dir, node) = crate::app::tests::workspace_test_node().await;
        let root = dir.path().canonicalize().unwrap();
        for id in ["repo", "target"] {
            let path = root.join(id);
            std::fs::create_dir(&path).unwrap();
            node.db
                .lock()
                .add_workspace(
                    id,
                    "test-node",
                    id,
                    path.to_str().unwrap(),
                    ModeId::new("directory").unwrap(),
                )
                .unwrap();
        }
        let session = node
            .db
            .lock()
            .create_session("repo", "/private/session", "test-user")
            .unwrap()
            .id;
        if ran {
            node.db.lock().increment_epoch(&session).unwrap();
        }
        let generation = node
            .db
            .lock()
            .acquire_lease(&session, "phone", false, 60_000)
            .unwrap()
            .generation;
        let router = crate::router::Router::new(crate::app::routes(&node.config));
        let mut f = Self {
            dir,
            node,
            router,
            session,
            generation,
        };
        let epoch = f.epoch();
        let (status, observed) = f
            .call(
                "preflight",
                json!({"expectedWorkspaceId":"repo","expectedRunnerEpoch":epoch,"targetWorkspaceId":"target"}),
            )
            .await;
        assert_eq!(status, 200, "{observed}");
        let (status, fenced) = f.call("", json!({"intent":{"operationId":op,"planHash":PLAN,"expectedWorkspaceId":"repo","expectedRunnerEpoch":epoch,"preflight":{"targetWorkspaceId":"target","evidenceHash":observed["evidenceHash"]}},"clientId":"phone","generation":f.generation})).await;
        assert_eq!(status, 200, "{fenced}");
        if drain {
            let (status, drained) = f.call(&format!("{op}/drain"), json!({})).await;
            assert_eq!(status, 200, "{drained}");
            assert_eq!(drained["transition"]["state"], "supervisor_drained");
        }
        f.generation = f
            .node
            .db
            .lock()
            .acquire_lease(&f.session, "phone", false, 60_000)
            .unwrap()
            .generation;
        f
    }
    fn epoch(&self) -> i64 {
        self.node
            .db
            .lock()
            .get_session(&self.session)
            .unwrap()
            .runner_epoch
    }
    fn workspace(&self) -> String {
        self.node
            .db
            .lock()
            .get_session(&self.session)
            .unwrap()
            .workspace_id
    }
    async fn call(&mut self, path: &str, body: Value) -> (u16, Value) {
        let suffix = if path.is_empty() {
            String::new()
        } else {
            format!("/{path}")
        };
        let response = self
            .router
            .handle(
                &self.node,
                NodeHttpRequest {
                    method: HttpMethod::Post,
                    url: format!("/api/sessions/{}/execution-fences{suffix}", self.session),
                    user: "test-user".into(),
                    payload: Some(body),
                    body_base64: None,
                    content_type: None,
                },
            )
            .await;
        (response.status, response.body.unwrap_or(Value::Null))
    }
    async fn op(&mut self, op: &str, action: &str, extra: Value) -> (u16, Value) {
        let mut body = json!({"planHash":PLAN,"clientId":"phone","generation":self.generation});
        for (key, value) in extra.as_object().unwrap() {
            body[key] = value.clone();
        }
        self.call(&format!("{op}/{action}"), body).await
    }
    async fn install(&mut self, op: &str) -> (u16, Value) {
        self.op(op, "install", json!({"targetWorkspaceId":"target"}))
            .await
    }
}

#[tokio::test]
async fn a_confirmed_drain_installs_the_reviewed_target_once_and_reopens_admission() {
    let mut f = Fixture::new("move", false, true).await;
    let before = f.epoch();
    let (status, installed) = f.install("move").await;
    assert_eq!(status, 200, "{installed}");
    let t = &installed["transition"];
    assert_eq!(t["state"], "installed");
    assert_eq!(t["targetInstalled"], true);
    assert_eq!(t["revocationConfirmed"], true);
    assert_eq!(t["installation"]["generation"], 2);
    assert_eq!(t["installation"]["revocation"], "confirmed");
    assert_eq!(t["installation"]["environmentEvent"], "pending");
    assert!(t.get("revocation").is_none());
    assert_eq!(f.workspace(), "target");
    assert_eq!(f.epoch(), before + 1);
    require_open(&f.node.db.lock(), &f.session).unwrap();
    // Repeating returns the same installation without another epoch or generation.
    let (status, again) = f.install("move").await;
    assert_eq!(status, 200);
    assert_eq!(again["transition"]["installation"], t["installation"]);
    assert_eq!(f.epoch(), before + 1);
    let (status, late) = f.op("move", "release", json!({})).await;
    assert_eq!(status, 409);
    assert_eq!(late["error"]["code"], "transition_installed");
    {
        let db = f.node.db.lock();
        let generation: (String, String, i64) = db
            .query_row(
                "SELECT workspace_id,coverage,start_epoch FROM session_binding_generations WHERE session_id=?1 AND generation=2",
                [&f.session],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .unwrap();
        assert_eq!(generation, ("target".into(), "complete".into(), before + 1));
        // The ended fence is terminal and cannot be reopened or reused.
        assert!(
            db.execute("UPDATE execution_fences SET state='fenced'", [])
                .is_err()
        );
    }
    // A later transition from the new binding can start: the old fence is inactive.
    let evaluation =
        revocation::evaluate(&f.node, &f.node.db.lock(), &f.session, "supervisor_drained").unwrap();
    assert_eq!((evaluation.generation, evaluation.status), (2, "confirmed"));
    f.node.close().await;
}

#[tokio::test]
async fn unproven_evidence_installs_only_after_acknowledging_its_exact_digest() {
    let mut f = Fixture::new("move", true, true).await;
    let (status, refused) = f.install("move").await;
    assert_eq!(status, 409);
    assert_eq!(refused["error"]["code"], "revocation_unconfirmed");
    let digest = refused["error"]["details"]["digest"]
        .as_str()
        .unwrap()
        .to_owned();
    assert_eq!(refused["error"]["details"]["status"], "unproven");
    let (status, wrong) = f
        .op("move", "acknowledge", json!({"digest":"0".repeat(64)}))
        .await;
    assert_eq!(status, 409);
    assert_eq!(wrong["error"]["code"], "revocation_digest_changed");
    for _ in 0..2 {
        let (status, acknowledged) = f.op("move", "acknowledge", json!({"digest":digest})).await;
        assert_eq!(status, 200, "{acknowledged}");
        assert_eq!(acknowledged["transition"]["state"], "supervisor_drained");
    }
    // New unprovable evidence after the acknowledgement needs a new one.
    f.node.db.lock().execute("INSERT INTO host_command_runs(id,session_id,workspace_id,runner_epoch,incarnation,request_id,state,created_at,updated_at) VALUES('late','{s}','repo',1,'n','r','settled',5,5)".replace("{s}", &f.session).as_str(), []).unwrap();
    let (status, changed) = f.install("move").await;
    assert_eq!(status, 409);
    let next = changed["error"]["details"]["digest"]
        .as_str()
        .unwrap()
        .to_owned();
    assert_ne!(next, digest);
    let (status, _) = f.op("move", "acknowledge", json!({"digest":next})).await;
    assert_eq!(status, 200);
    let (status, installed) = f.install("move").await;
    assert_eq!(status, 200, "{installed}");
    let t = &installed["transition"];
    assert_eq!(t["targetInstalled"], true);
    assert_eq!(t["revocationConfirmed"], false);
    assert_eq!(t["installation"]["revocation"], "unproven");
    let count: i64 = f
        .node
        .db
        .lock()
        .query_row(
            "SELECT count(*) FROM transition_acknowledgements",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(count, 2);
    // The acknowledged host command itself is not closed or rewritten.
    let state: String = f
        .node
        .db
        .lock()
        .query_row(
            "SELECT state FROM host_command_runs WHERE id='late'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(state, "settled");
    f.node.close().await;
}

#[tokio::test]
async fn installation_requires_a_drain_the_reviewed_target_and_current_control() {
    let mut f = Fixture::new("move", false, false).await;
    let (status, early) = f.install("move").await;
    assert_eq!(
        (status, early["error"]["code"].clone()),
        (409, json!("transition_not_drained"))
    );
    let (_, _) = f.call("move/drain", json!({})).await;
    let (status, wrong) = f
        .op("move", "install", json!({"targetWorkspaceId":"repo"}))
        .await;
    assert_eq!(
        (status, wrong["error"]["code"].clone()),
        (409, json!("transition_target_mismatch"))
    );
    let (status, plan) = f
        .call("move/install", json!({"planHash":"c".repeat(64),"targetWorkspaceId":"target","clientId":"phone","generation":f.generation}))
        .await;
    assert_eq!(
        (status, plan["error"]["code"].clone()),
        (409, json!("conflict"))
    );
    f.node
        .db
        .lock()
        .acquire_lease(&f.session, "tablet", true, 60_000)
        .unwrap();
    let (status, _) = f.install("move").await;
    assert_ne!(status, 200);
    f.generation = f
        .node
        .db
        .lock()
        .acquire_lease(&f.session, "phone", true, 60_000)
        .unwrap()
        .generation;
    // The reviewed target changed after acceptance.
    let root = f.dir.path().canonicalize().unwrap();
    std::fs::rename(root.join("target"), root.join("moved-away")).unwrap();
    let (status, stale) = f.install("move").await;
    assert_eq!(
        (status, stale["error"]["code"].clone()),
        (409, json!("stale_transition_target"))
    );
    assert_eq!(f.workspace(), "repo");
    require_open(&f.node.db.lock(), &f.session).unwrap_err();
    f.node.close().await;
}

#[tokio::test]
async fn explicit_release_keeps_the_original_binding_and_ends_the_fence() {
    let mut drained = Fixture::new("move", false, true).await;
    let before = drained.epoch();
    for _ in 0..2 {
        let (status, released) = drained.op("move", "release", json!({})).await;
        assert_eq!(status, 200, "{released}");
        assert_eq!(released["transition"]["state"], "released");
        assert_eq!(released["transition"]["targetInstalled"], false);
    }
    assert_eq!(drained.workspace(), "repo");
    assert_eq!(drained.epoch(), before + 1);
    require_open(&drained.node.db.lock(), &drained.session).unwrap();
    let (status, after) = drained.install("move").await;
    assert_eq!(
        (status, after["error"]["code"].clone()),
        (409, json!("transition_released"))
    );
    drained.node.close().await;
    // An undrained source keeps its epoch: nothing was stopped.
    let mut fenced = Fixture::new("move", false, false).await;
    let before = fenced.epoch();
    let (status, _) = fenced.op("move", "release", json!({})).await;
    assert_eq!(status, 200);
    assert_eq!(fenced.epoch(), before);
    require_open(&fenced.node.db.lock(), &fenced.session).unwrap();
    fenced.node.close().await;
}

#[tokio::test]
async fn a_fence_without_a_frozen_target_review_cannot_install() {
    let mut f = Fixture::new("move", false, true).await;
    {
        // Model a pre-2032 resource-bound fence: same intent shape, no target row.
        let db = f.node.db.lock();
        let intent: String = db
            .query_row(
                "SELECT intent_json FROM execution_fences WHERE operation_id='move'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        db.execute(
            "UPDATE execution_fences SET state='released' WHERE operation_id='move'",
            [],
        )
        .unwrap();
        db.execute(
            "INSERT INTO execution_fences VALUES('test-user','old',?1,?2,'supervisor_drained',NULL,1,1)",
            params![f.session, intent.replace("\"move\"", "\"old\"")],
        )
        .unwrap();
    }
    let (status, refused) = f.install("old").await;
    assert_eq!(
        (status, refused["error"]["code"].clone()),
        (409, json!("transition_target_unreviewed"))
    );
    assert_eq!(f.workspace(), "repo");
    f.node.close().await;
}

#[tokio::test]
async fn the_environment_notice_is_claimed_once_and_never_resent() {
    let mut f = Fixture::new("move", false, true).await;
    f.install("move").await;
    {
        let db = f.node.db.lock();
        let (owner, op, deliver) = claim_notice(&db, &f.session).unwrap().unwrap();
        assert_eq!(deliver["type"], "deliver");
        assert_eq!(deliver["wake"], false);
        assert_eq!(deliver["message"]["customType"], "environment-change");
        assert_eq!(deliver["message"]["details"]["toWorkspaceId"], "target");
        assert!(
            deliver["message"]["content"]
                .as_str()
                .unwrap()
                .contains("\"target\" replaced \"repo\"")
        );
        // A second claim, or a lost reply, never sends it again.
        assert!(claim_notice(&db, &f.session).unwrap().is_none());
        finish_notice(&db, &owner, &op, false).unwrap();
        assert!(claim_notice(&db, &f.session).unwrap().is_none());
        assert!(
            db.execute("UPDATE environment_events SET state='pending'", [])
                .is_err()
        );
        let state: String = db
            .query_row("SELECT state FROM environment_events", [], |r| r.get(0))
            .unwrap();
        assert_eq!(state, "uncertain");
    }
    f.node.close().await;
}

#[test]
fn upgrade_keeps_fences_and_states_and_adds_no_installation() {
    use crate::store::Db;
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("node.sqlite");
    {
        let db = Db::open(&file).unwrap();
        let db = db.lock();
        db.execute_batch(include_str!("../remove_installation.sql"))
            .unwrap();
        db.execute(
            "INSERT INTO execution_fences VALUES('u','op','s','{}','supervisor_drained',NULL,1,1)",
            [],
        )
        .unwrap();
        db.pragma_update(None, "user_version", 2031).unwrap();
    }
    let db = Db::open(&file).unwrap();
    let db = db.lock();
    let state: String = db
        .query_row(
            "SELECT state FROM execution_fences WHERE operation_id='op'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(state, "supervisor_drained");
    for table in [
        "execution_fence_targets",
        "transition_acknowledgements",
        "environment_events",
    ] {
        let n: i64 = db
            .query_row(&format!("SELECT count(*) FROM {table}"), [], |r| r.get(0))
            .unwrap();
        assert_eq!(n, 0, "{table}");
    }
    // Installation needs its generation row, so a bare state change is refused.
    assert!(
        db.execute("UPDATE execution_fences SET state='installed'", [])
            .is_err()
    );
}
