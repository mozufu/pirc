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
        Self::with_authority(op, ran, drain, None).await
    }
    /// The same fence, created with a C1 operation authority grant.
    async fn with_authority(op: &str, ran: bool, drain: bool, authority: Option<Value>) -> Self {
        Self::with_grant(op, ran, drain, authority, None).await
    }
    /// The same fence with one folder grant (`access`) active before review.
    async fn with_grant(
        op: &str,
        ran: bool,
        drain: bool,
        authority: Option<Value>,
        grant: Option<&str>,
    ) -> Self {
        let (dir, node) = crate::app::tests::workspace_test_node_grants(grant.is_some()).await;
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
        if let Some(access) = grant {
            let path = root.join("grant-root/shared");
            std::fs::create_dir_all(&path).unwrap();
            node.db.lock().execute(
                "INSERT INTO folder_grants(grant_id,session_id,path,access,client_id,created_at) VALUES('grant-1',?1,?2,?3,'phone',1)",
                params![session, path.to_str().unwrap(), access],
            ).unwrap();
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
        let mut body = json!({"intent":{"operationId":op,"planHash":PLAN,"expectedWorkspaceId":"repo","expectedRunnerEpoch":epoch,"preflight":{"targetWorkspaceId":"target","evidenceHash":observed["evidenceHash"]}},"clientId":"phone","generation":f.generation});
        if let Some(authority) = authority {
            body["operationAuthority"] = authority;
        }
        let (status, fenced) = f.call("", body).await;
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
    // With kernel containment (a Linux host with its sandbox) the earlier run
    // is proven contained, so there is nothing to acknowledge.
    if f.node.sandbox.contains_descendants() {
        let (status, installed) = f.install("move").await;
        assert_eq!(status, 200, "{installed}");
        f.node.close().await;
        return;
    }
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
            "INSERT INTO execution_fences(owner_user,operation_id,session_id,intent_json,state,error_code,created_at,updated_at) VALUES('test-user','old',?1,?2,'supervisor_drained',NULL,1,1)",
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
async fn the_environment_notice_is_retransmitted_with_one_id_until_confirmed() {
    let mut f = Fixture::new("move", false, true).await;
    f.install("move").await;
    {
        let db = f.node.db.lock();
        let (owner, op, deliver) = claim_notice(&db, &f.session).unwrap().unwrap();
        assert_eq!(deliver["type"], "deliver");
        assert_eq!(deliver["wake"], false);
        assert_eq!(deliver["message"]["customType"], "environment-change");
        let details = &deliver["message"]["details"];
        assert_eq!(details["noticeId"], "move");
        assert_eq!(details["toWorkspaceId"], "target");
        assert_eq!(
            (
                details["sourceGeneration"].clone(),
                details["targetGeneration"].clone()
            ),
            (json!(1), json!(2))
        );
        assert!(
            deliver["message"]["content"]
                .as_str()
                .unwrap()
                .contains("\"target\" replaced \"repo\"")
        );
        // Only one send is in flight at a time.
        assert!(claim_notice(&db, &f.session).unwrap().is_none());
        // A lost reply: the same notice is sent again; the agent applies it once.
        finish_notice(&db, &owner, &op, false).unwrap();
        let (_, _, again) = claim_notice(&db, &f.session).unwrap().unwrap();
        assert_eq!(again["message"]["details"]["noticeId"], "move");
        finish_notice(&db, &owner, &op, true).unwrap();
        assert!(claim_notice(&db, &f.session).unwrap().is_none());
        assert!(
            db.execute("UPDATE environment_events SET state='pending'", [])
                .is_err()
        );
    }
    f.node.close().await;
}

fn grant(revision: i64, token: &str, ttl_ms: i64) -> Value {
    json!({"revision":revision,"tokenHash":crate::util::sha256_hex(token),"deadlineAt":now_ms()+ttl_ms})
}
async fn install_with(f: &mut Fixture, op: &str, revision: i64, token: &str) -> (u16, Value) {
    f.call(
        &format!("{op}/install"),
        json!({"planHash":PLAN,"targetWorkspaceId":"target","operationAuthority":{"revision":revision,"token":token}}),
    )
    .await
}
#[tokio::test]
async fn operation_authority_installs_after_control_moved_and_only_while_current() {
    let mut f = Fixture::with_authority("move", false, true, Some(grant(1, "first", 60_000))).await;
    // Another device took control: the operation keeps its own authority.
    let tablet = f
        .node
        .db
        .lock()
        .acquire_lease(&f.session, "tablet", true, 60_000)
        .unwrap()
        .generation;
    let (status, body) = f.call("move", json!({})).await;
    let _ = (status, body);
    let (status, wrong) = install_with(&mut f, "move", 1, "guess").await;
    assert_eq!(
        (status, wrong["error"]["code"].clone()),
        (403, json!("operation_authority_invalid"))
    );
    // The current controller reauthorizes: revision 1 is superseded.
    let (status, renewed) = f
        .call(
            "move/authority",
            json!({"planHash":PLAN,"clientId":"tablet","generation":tablet,"grant":grant(2,"second",60_000)}),
        )
        .await;
    assert_eq!(status, 200, "{renewed}");
    assert_eq!(renewed["transition"]["operationAuthority"]["revision"], 2);
    assert!(
        !renewed
            .to_string()
            .contains(&crate::util::sha256_hex("second"))
    );
    let (status, old) = install_with(&mut f, "move", 1, "first").await;
    assert_eq!(
        (status, old["error"]["code"].clone()),
        (409, json!("operation_authority_superseded"))
    );
    let (status, installed) = install_with(&mut f, "move", 2, "second").await;
    assert_eq!(status, 200, "{installed}");
    assert_eq!(installed["transition"]["state"], "installed");
    // Ended fences need no further authority.
    let (status, late) = f
        .call(
            "move/authority",
            json!({"planHash":PLAN,"clientId":"tablet","generation":tablet,"grant":grant(3,"third",60_000)}),
        )
        .await;
    assert_eq!(
        (status, late["error"]["code"].clone()),
        (409, json!("transition_ended"))
    );
    f.node.close().await;
}
#[tokio::test]
async fn expired_revoked_missing_or_clock_rolled_back_authority_never_installs() {
    let mut f = Fixture::with_authority("move", false, true, Some(grant(1, "short", 3_000))).await;
    // Long enough to survive Node start-up and fence creation, then expire.
    tokio::time::sleep(std::time::Duration::from_millis(3_100)).await;
    let (status, expired) = install_with(&mut f, "move", 1, "short").await;
    assert_eq!(
        (status, expired["error"]["code"].clone()),
        (409, json!("operation_authority_expired"))
    );
    assert_eq!(f.workspace(), "repo");
    // Reauthorization needs the current controller.
    let (status, _) = f
        .call(
            "move/authority",
            json!({"planHash":PLAN,"clientId":"stranger","generation":99,"grant":grant(2,"next",60_000)}),
        )
        .await;
    assert_ne!(status, 200);
    let (status, _) = f
        .op("move", "authority", json!({"grant":grant(2,"next",60_000)}))
        .await;
    assert_eq!(status, 200);
    // A clock behind the watermark cannot extend permission.
    f.node
        .db
        .lock()
        .execute(
            "UPDATE operation_authority_clock SET max_seen_at=?1",
            [now_ms() + 600_000],
        )
        .unwrap();
    let (status, rolled) = install_with(&mut f, "move", 2, "next").await;
    assert_eq!(
        (status, rolled["error"]["code"].clone()),
        (409, json!("operation_authority_clock_uncertain"))
    );
    f.node
        .db
        .lock()
        .execute(
            "UPDATE operation_authority_clock SET max_seen_at=?1",
            [now_ms()],
        )
        .unwrap();
    let (status, _) = f.op("move", "authority", json!({"revoke":true})).await;
    assert_eq!(status, 200);
    let (status, revoked) = install_with(&mut f, "move", 2, "next").await;
    assert_eq!(
        (status, revoked["error"]["code"].clone()),
        (409, json!("operation_authority_revoked"))
    );
    assert_eq!(f.workspace(), "repo");
    f.node.close().await;

    let mut plain = Fixture::new("move", false, true).await;
    let (status, missing) = install_with(&mut plain, "move", 1, "any").await;
    assert_eq!(
        (status, missing["error"]["code"].clone()),
        (409, json!("operation_authority_missing"))
    );
    let (status, _) = plain
        .op(
            "move",
            "install",
            json!({"targetWorkspaceId":"target","operationAuthority":{"revision":1,"token":"any"}}),
        )
        .await;
    assert_eq!(
        status, 400,
        "a lease and an authority together are ambiguous"
    );
    plain.node.close().await;
}

impl Fixture {
    async fn get(&self, path: &str) -> (u16, Value) {
        let response = self
            .router
            .handle(
                &self.node,
                NodeHttpRequest {
                    method: HttpMethod::Get,
                    url: format!("/api/sessions/{}/execution-fences/{path}", self.session),
                    user: "test-user".into(),
                    payload: None,
                    body_base64: None,
                    content_type: None,
                },
            )
            .await;
        (response.status, response.body.unwrap_or(Value::Null))
    }
}
fn settled_host_commands(f: &Fixture, from: usize, to: usize) {
    let db = f.node.db.lock();
    for n in from..to {
        db.execute("INSERT INTO host_command_runs(id,session_id,workspace_id,runner_epoch,incarnation,request_id,state,created_at,updated_at) VALUES(?1,?2,'repo',1,'n',?1,'settled',5,5)",params![format!("hc-{n:04}"),f.session]).unwrap();
    }
}
#[tokio::test]
async fn r4_large_risk_sets_page_one_immutable_snapshot_and_a_change_needs_new_review() {
    let mut f = Fixture::new("move", true, true).await;
    settled_host_commands(&f, 0, 120);
    let (_, first) = f.get("move").await;
    let revocation = &first["transition"]["revocation"];
    let evaluation = revocation["evaluationId"].as_str().unwrap().to_owned();
    let digest = revocation["digest"].as_str().unwrap().to_owned();
    let total = revocation["itemsTotal"].as_u64().unwrap();
    assert!(total > 100);
    assert_eq!(revocation["items"].as_array().unwrap().len(), 100);
    // A new risk appears while the user is paging: the old snapshot is unchanged.
    settled_host_commands(&f, 120, 121);
    let (mut pages, mut cursor) = (Vec::new(), None::<String>);
    loop {
        let query = cursor
            .as_ref()
            .map_or("?limit=50".to_owned(), |c| format!("?limit=50&cursor={c}"));
        let (status, page) = f
            .get(&format!("move/evaluations/{evaluation}{query}"))
            .await;
        assert_eq!(status, 200, "{page}");
        assert_eq!(page["evaluation"]["digest"], digest);
        pages.extend(page["evaluation"]["items"].as_array().unwrap().clone());
        match page["evaluation"]["next"].as_str() {
            Some(next) => cursor = Some(next.to_owned()),
            None => break,
        }
    }
    assert_eq!(pages.len() as u64, total);
    let (_, changed) = f.get("move").await;
    let newer = changed["transition"]["revocation"]["evaluationId"]
        .as_str()
        .unwrap()
        .to_owned();
    assert_ne!(newer, evaluation);
    // Consent to the old snapshot no longer matches the current full set.
    let (status, stale) = f
        .op(
            "move",
            "acknowledge",
            json!({"digest":digest,"evaluationId":evaluation}),
        )
        .await;
    assert_eq!(
        (status, stale["error"]["code"].clone()),
        (409, json!("revocation_digest_changed"))
    );
    let current = changed["transition"]["revocation"]["digest"].clone();
    let (status, _) = f
        .op(
            "move",
            "acknowledge",
            json!({"digest":current,"evaluationId":newer}),
        )
        .await;
    assert_eq!(status, 200);
    let (status, installed) = f.install("move").await;
    assert_eq!(status, 200, "{installed}");
    let (status, missing) = f.get("move/evaluations/ev-unknown").await;
    assert_eq!(
        (status, missing["error"]["code"].clone()),
        (404, json!("evaluation_not_found"))
    );
    f.node.close().await;
}

fn state(f: &Fixture) -> (String, Option<String>) {
    f.node
        .db
        .lock()
        .query_row(
            "SELECT state,cancel_reason FROM execution_fences WHERE operation_id='move'",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap()
}
#[tokio::test]
async fn x1_cancel_with_unresolved_evidence_waits_and_blocks_installation() {
    let mut f = Fixture::new("move", false, true).await;
    f.node.db.lock().execute("INSERT INTO browser_groups(id,session_id,workspace_id,root,incarnation,state,created_at,updated_at) VALUES('pages',?1,'repo','/repo','n','active',6,6)",[&f.session]).unwrap();
    let before = f.epoch();
    let (status, pending) = f.op("move", "release", json!({})).await;
    assert_eq!(status, 200, "{pending}");
    assert_eq!(pending["transition"]["state"], "supervisor_drained");
    assert_eq!(
        pending["transition"]["cancellation"]["pendingReason"],
        "resources_unresolved"
    );
    assert_eq!(f.epoch(), before);
    let (status, install) = f.install("move").await;
    assert_eq!(
        (status, install["error"]["code"].clone()),
        (409, json!("transition_cancel_requested"))
    );
    // Once the resource settles, the same cancellation completes.
    f.node
        .db
        .lock()
        .execute(
            "UPDATE browser_groups SET state='settled' WHERE id='pages'",
            [],
        )
        .unwrap();
    let (_, released) = f.op("move", "release", json!({})).await;
    assert_eq!(released["transition"]["state"], "released", "{released}");
    assert_eq!(f.epoch(), before + 1);
    assert_eq!(f.workspace(), "repo");
    f.node.close().await;
}
#[tokio::test]
async fn x2_cancel_during_a_drain_completes_when_the_drain_settles() {
    let mut f = Fixture::new("move", false, false).await;
    // Model an interrupted drain: the fence was staged but nothing finished.
    f.node
        .db
        .lock()
        .execute(
            "UPDATE execution_fences SET state='stopping' WHERE operation_id='move'",
            [],
        )
        .unwrap();
    let (_, pending) = f.op("move", "release", json!({})).await;
    assert_eq!(
        pending["transition"]["cancellation"]["pendingReason"], "drain_active",
        "{pending}"
    );
    assert_eq!(state(&f).0, "stopping");
    let (status, drained) = f.call("move/drain", json!({})).await;
    assert_eq!(status, 200, "{drained}");
    assert_eq!(drained["transition"]["state"], "released", "{drained}");
    assert_eq!(f.workspace(), "repo");
    f.node.close().await;
}
#[tokio::test]
async fn x3_an_invalid_original_binding_is_not_restored() {
    let mut f = Fixture::new("move", false, true).await;
    f.node
        .db
        .lock()
        .execute(
            "INSERT INTO workspace_deletions VALUES('repo','test-user','deleting',1)",
            [],
        )
        .unwrap();
    let (_, pending) = f.op("move", "release", json!({})).await;
    assert_eq!(
        pending["transition"]["cancellation"]["pendingReason"], "original_binding_invalid",
        "{pending}"
    );
    assert_eq!(state(&f).0, "supervisor_drained");
    f.node.close().await;
}
#[tokio::test]
async fn a_drain_after_release_never_stops_the_returned_source() {
    let mut f = Fixture::new("move", false, false).await;
    let before = f.epoch();
    let (_, released) = f.op("move", "release", json!({})).await;
    assert_eq!(released["transition"]["state"], "released");
    let (_, after) = f.call("move/drain", json!({})).await;
    assert_eq!(after["transition"]["state"], "released");
    assert_eq!(f.epoch(), before);
    require_open(&f.node.db.lock(), &f.session).unwrap();
    f.node.close().await;
}

#[tokio::test]
async fn x5_a_failed_first_launch_reports_readiness_without_reverting_the_binding() {
    let mut f = Fixture::new("move", false, true).await;
    let (_, installed) = f.install("move").await;
    let outcome = &installed["transition"]["installation"];
    assert_eq!(outcome["bindingCommitted"], true);
    assert_eq!(outcome["policyValidated"], true);
    assert_eq!(outcome["runtimeReady"], "not_started");
    // The first runner in the new generation fails to start.
    f.node.db.lock().increment_epoch(&f.session).unwrap();
    f.node
        .db
        .lock()
        .execute(
            "UPDATE sessions SET runner_state='failed' WHERE id=?1",
            [&f.session],
        )
        .unwrap();
    let (_, failed) = f.get("move").await;
    assert_eq!(
        failed["transition"]["installation"]["runtimeReady"],
        "failed"
    );
    assert_eq!(f.workspace(), "target");
    f.node
        .db
        .lock()
        .execute(
            "UPDATE sessions SET runner_state='ready' WHERE id=?1",
            [&f.session],
        )
        .unwrap();
    let (_, ready) = f.get("move").await;
    assert_eq!(ready["transition"]["installation"]["runtimeReady"], "ready");
    f.node.close().await;
}

#[tokio::test]
async fn x4_a_notice_send_cut_off_by_a_restart_is_sent_again() {
    let mut f = Fixture::new("move", false, true).await;
    f.install("move").await;
    claim_notice(&f.node.db.lock(), &f.session)
        .unwrap()
        .unwrap();
    f.node.close().await;
    let restarted = crate::services::Services::start(f.node.config.clone(), f.node.env.clone())
        .await
        .unwrap();
    let state: String = restarted
        .db
        .lock()
        .query_row("SELECT state FROM environment_events", [], |r| r.get(0))
        .unwrap();
    assert_eq!(state, "uncertain");
    let again = claim_notice(&restarted.db.lock(), &f.session)
        .unwrap()
        .unwrap();
    assert_eq!(again.2["message"]["details"]["noticeId"], "move");
    restarted.close().await;
}

impl Fixture {
    async fn grants(&self, path: &str, body: Option<Value>) -> (u16, Value) {
        let response = self
            .router
            .handle(
                &self.node,
                NodeHttpRequest {
                    method: if body.is_some() {
                        HttpMethod::Post
                    } else {
                        HttpMethod::Get
                    },
                    url: format!("/api/sessions/{}/grants{path}", self.session),
                    user: "test-user".into(),
                    payload: body,
                    body_base64: None,
                    content_type: None,
                },
            )
            .await;
        (response.status, response.body.unwrap_or(Value::Null))
    }
    fn lease(&self) -> Value {
        json!({"clientId":"phone","generation":self.generation})
    }
    fn folder(&self, path: &str) -> String {
        self.dir
            .path()
            .canonicalize()
            .unwrap()
            .join(path)
            .to_str()
            .unwrap()
            .to_owned()
    }
}

#[tokio::test]
async fn o5_x3_revoking_a_grant_between_phases_needs_a_new_review_and_is_never_restored() {
    let mut f = Fixture::with_grant("move", false, true, None, Some("write")).await;
    // Widening waits for the transition; narrowing never does.
    std::fs::create_dir_all(f.folder("grant-root/other")).unwrap();
    let mut widen = f.lease();
    widen["path"] = json!(f.folder("grant-root/other"));
    widen["access"] = json!("write");
    let (status, refused) = f.grants("", Some(widen)).await;
    assert_eq!(
        (status, refused["error"]["code"].clone()),
        (409, json!("environment_transition_pending"))
    );
    let before = f.epoch();
    let (status, revoked) = f.grants("/grant-1/revoke", Some(f.lease())).await;
    assert_eq!(status, 200, "{revoked}");
    assert_eq!(f.epoch(), before + 1);
    // No background step can install the reviewed plan any more (O5).
    let (status, stale) = f.install("move").await;
    assert_eq!(
        (status, stale["error"]["code"].clone()),
        (409, json!("stale_transition_target"))
    );
    assert_eq!(f.workspace(), "repo");
    // Release returns to the source without the revoked grant (X3).
    let (_, released) = f.op("move", "release", json!({})).await;
    assert_eq!(released["transition"]["state"], "released", "{released}");
    require_open(&f.node.db.lock(), &f.session).unwrap();
    assert!(
        crate::grants::active(&f.node.db.lock(), &f.session)
            .unwrap()
            .is_empty()
    );
    f.node.close().await;
}

#[tokio::test]
async fn an_unchanged_grant_carries_over_and_a_new_deny_also_stales_the_target() {
    let mut f = Fixture::with_grant("move", false, true, None, Some("write")).await;
    let (status, installed) = f.install("move").await;
    assert_eq!(status, 200, "{installed}");
    assert_eq!(f.workspace(), "target");
    let active = crate::grants::active(&f.node.db.lock(), &f.session).unwrap();
    assert_eq!(active.len(), 1);
    f.node.close().await;

    let mut f = Fixture::with_grant("move", false, true, None, Some("write")).await;
    let mut deny = f.lease();
    deny["path"] = json!(f.folder("grant-root/shared"));
    deny["access"] = json!("deny");
    let (status, denied) = f.grants("", Some(deny)).await;
    assert_eq!(status, 200, "{denied}");
    let (status, stale) = f.install("move").await;
    assert_eq!(
        (status, stale["error"]["code"].clone()),
        (409, json!("stale_transition_target"))
    );
    f.node.close().await;
}

#[tokio::test]
async fn r5_an_acknowledged_switch_never_makes_a_deny_enforced_under_the_same_host_risk() {
    // Ordinary switch: a surviving host effect is unproven and acknowledgeable.
    let mut plain = Fixture::new("move", false, true).await;
    settled_host_commands(&plain, 0, 1);
    let (_, refused) = plain.install("move").await;
    let digest = refused["error"]["details"]["digest"].clone();
    assert_eq!(refused["error"]["details"]["status"], "unproven");
    plain
        .op("move", "acknowledge", json!({"digest":digest}))
        .await;
    let (status, _) = plain.install("move").await;
    assert_eq!(status, 200);
    plain.node.close().await;

    // The same risk under an explicit deny: the switch keeps its result, but
    // the deny stays unproven and host execution stays refused.
    let mut f = Fixture::with_grant("move", false, true, None, Some("deny")).await;
    settled_host_commands(&f, 0, 1);
    let (_, listed) = f.grants("", None).await;
    let enforcement = listed["effectiveAccess"]["denyEnforcement"].clone();
    assert_eq!(enforcement["status"], "unproven", "{listed}");
    let (_, refused) = f.install("move").await;
    let digest = refused["error"]["details"]["digest"].clone();
    f.op("move", "acknowledge", json!({"digest":digest})).await;
    let (status, installed) = f.install("move").await;
    assert_eq!(status, 200, "{installed}");
    assert_eq!(
        installed["transition"]["installation"]["revocation"],
        "unproven"
    );
    let (_, after) = f.grants("", None).await;
    assert_eq!(
        after["effectiveAccess"]["denyEnforcement"]["status"],
        "unproven"
    );
    assert_eq!(after["effectiveAccess"]["hostExecutionRefused"], true);
    let host = crate::terminals::host::handle(
        &f.node,
        "test-user",
        &f.session,
        std::path::Path::new(&f.folder("target")),
        &json!({"requestId":"h1","action":"review","executionPath":"host_management"}),
        ("phone", f.generation),
        (None, None),
    );
    assert_eq!(host.unwrap_err().code, "folder_deny_unenforceable_on_host");
    f.node.close().await;
}
