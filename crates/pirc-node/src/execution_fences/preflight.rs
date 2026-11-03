//! Read-only source/target observations. A fingerprint is not a grant or an
//! installed policy. Never materialize per-session directories during review.
use super::*;
use pirc_protocol::mode::Workdir;
use serde_json::Value;
use std::{
    os::unix::{ffi::OsStrExt, fs::MetadataExt},
    path::{Path, PathBuf},
};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Input {
    expected_workspace_id: String,
    expected_runner_epoch: Option<i64>,
    target_workspace_id: String,
}
fn invalid(input: &Input) -> bool {
    [&input.expected_workspace_id, &input.target_workspace_id]
        .iter()
        .any(|id| id.is_empty() || id.len() > 1024 || id.contains('\0'))
        || input
            .expected_runner_epoch
            .is_some_and(|epoch| !(0..=9_007_199_254_740_991).contains(&epoch))
}
fn root(workspace: &crate::store::Workspace, session: &str, mode: &pirc_protocol::Mode) -> PathBuf {
    let root = PathBuf::from(&workspace.canonical_path);
    if mode.workdir == Workdir::PerSession {
        root.join("sessions").join(
            session
                .rsplit('/')
                .find(|s| !s.is_empty())
                .unwrap_or_default(),
        )
    } else {
        root
    }
}
fn resource(path: &Path) -> (Value, Option<PathBuf>) {
    match path
        .canonicalize()
        .and_then(|p| p.metadata().map(|m| (p, m)))
    {
        Ok((path, meta)) if meta.is_dir() => (
            json!({"state":"observed","identity":crate::util::payload_hash(&json!({"pathBytes":path.as_os_str().as_bytes(),"dev":meta.dev(),"ino":meta.ino()}))}),
            Some(path),
        ),
        Ok(_) => (json!({"state":"not_directory"}), None),
        Err(e) => (
            json!({"state":if e.kind()==std::io::ErrorKind::NotFound {"not_materialized"} else {"unavailable"}}),
            None,
        ),
    }
}
fn observe(node: &Node, request: &Request, input: &Input) -> ApiResult<Value> {
    observe_at(
        node,
        &node.db.lock(),
        &request.user,
        request.param("id").unwrap_or_default(),
        input,
    )
}
pub(super) fn check_proof(
    node: &Node,
    db: &Connection,
    owner: &str,
    id: &str,
    intent: &Intent,
) -> ApiResult<()> {
    let Some(proof) = &intent.preflight else {
        return Ok(());
    };
    let current = observe_at(
        node,
        db,
        owner,
        id,
        &Input {
            expected_workspace_id: intent.expected_workspace_id.clone(),
            expected_runner_epoch: Some(intent.expected_runner_epoch),
            target_workspace_id: proof.target_workspace_id.clone(),
        },
    )?;
    if current["evidenceHash"] != proof.evidence_hash {
        return Err(ApiError::new(
            409,
            "stale_resource_preflight",
            "The reviewed resources or activity changed; refresh before accepting",
        ));
    }
    Ok(())
}
fn observe_at(
    node: &Node,
    db: &Connection,
    owner: &str,
    id: &str,
    input: &Input,
) -> ApiResult<Value> {
    if invalid(input) {
        return Err(ApiError::invalid_input());
    }
    if node.closing() {
        return Err(ApiError::runner_unavailable("Node is stopping"));
    }
    let session = db.claim_session(id, owner, false)?;
    if session.workspace_id != input.expected_workspace_id
        || input
            .expected_runner_epoch
            .is_some_and(|epoch| session.runner_epoch != epoch)
    {
        return Err(ApiError::new(
            409,
            "stale_environment",
            "The source environment changed; refresh the preview",
        ));
    }
    let source = db.get_workspace(&session.workspace_id)?;
    let target = db.get_workspace(&input.target_workspace_id)?;
    for workspace in [&source, &target] {
        if workspace.host_id != node.config.node_id {
            return Err(ApiError::conflict(
                "Cross-Node resource preflight is not supported",
            ));
        }
        crate::checkpoints::continuation::require_workspace_owner(db, &workspace.id, owner)?;
        if db.workspace_deletion(&workspace.id)?.is_some() {
            return Err(ApiError::not_found("Workspace not found"));
        }
    }
    let source_mode = node.workspace_mode(&source)?;
    let target_mode = node.workspace_mode(&target)?;
    let (source_resource, source_path) = resource(&root(&source, id, &source_mode));
    let (target_resource, target_path) = resource(&root(&target, id, &target_mode));
    let overlap = source_path
        .zip(target_path)
        .map(|(a, b)| a.starts_with(&b) || b.starts_with(&a));
    let fenced = match require_open(db, id) {
        Ok(()) => false,
        Err(error) if error.code == "environment_transition_pending" => true,
        Err(error) => return Err(error),
    };
    let pending:bool=db.query_row("SELECT EXISTS(SELECT 1 FROM runs WHERE session_id=?1 AND status IN ('queued','running','waiting_input','stopping')) OR EXISTS(SELECT 1 FROM commands WHERE session_id=?1 AND status IN ('received','dispatched'))",[id],|r|r.get(0))?;
    let evidence = json!({"version":1,"sessionId":id,"sourceWorkspaceId":source.id,
        "targetWorkspaceId":target.id,"runnerEpoch":session.runner_epoch,
        "sourceMode":{"id":source.mode,"definitionHash":crate::util::payload_hash(&serde_json::to_value(&source_mode).map_err(|_|ApiError::internal())?)},"targetMode":{"id":target.mode,"definitionHash":crate::util::payload_hash(&serde_json::to_value(&target_mode).map_err(|_|ApiError::internal())?)},
        "sourceResource":source_resource,"targetResource":target_resource,"overlap":overlap,
        "activity":{"pendingRecords":pending,"runnerPresent":node.runners.get(id).is_some(),"runnerStarting":node.runners.is_starting(id),
            "writeClaimsPresent":!node.writes.leases(id).is_empty(),"fenced":fenced},
        "sandboxProcesses":crate::process_journal::summary(db,id)?,
        "hostCommands":crate::host_commands::summary(db,id)?,
        "terminals":crate::terminals::journal::summary(db,id)?,
        "browser":crate::browser::journal::summary(db,id)?});
    let mut blockers = vec!["revocation_unconfirmed", "target_installation_unavailable"];
    if source.id == target.id {
        blockers.push("environment_unchanged");
    }
    if source_resource["state"] != "observed" {
        blockers.push("source_resource_unavailable");
    }
    if target_resource["state"] != "observed" {
        blockers.push("target_resource_unavailable");
    }
    if overlap == Some(true) {
        blockers.push("resource_overlap_requires_review");
    }
    if pending {
        blockers.push("source_has_pending_work");
    }
    if fenced {
        blockers.push("source_already_fenced");
    }
    // Catalog updates need not acquire the DB lock. Reject any intervening
    // update rather than publishing a mixed-mode observation.
    if node.workspace_mode(&source)? != source_mode || node.workspace_mode(&target)? != target_mode
    {
        return Err(ApiError::new(
            409,
            "stale_environment",
            "Mode changed during preflight",
        ));
    }
    Ok(
        json!({"evidenceHash":crate::util::payload_hash(&evidence),"evidence":evidence,
        "canConfirm":false,"historyComplete":false,"blockedBy":blockers}),
    )
}
pub(crate) async fn handle(node: Node, request: Request) -> ApiResult<Response> {
    let input: Input = request.parse_body()?;
    observe(&node, &request, &input).map(Response::json)
}

#[cfg(test)]
pub(super) mod tests {
    use super::*;
    use crate::{router::Body, store::ModeId};
    pub(super) async fn fixture() -> (tempfile::TempDir, Node, Request, Input) {
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
            .unwrap();
        let request = Request {
            method: pirc_protocol::HttpMethod::Post,
            path: String::new(),
            query: vec![],
            params: vec![("id".into(), session.id)],
            user: "test-user".into(),
            body: Body::None,
        };
        let input = Input {
            expected_workspace_id: "repo".into(),
            expected_runner_epoch: Some(session.runner_epoch),
            target_workspace_id: "target".into(),
        };
        (dir, node, request, input)
    }
    #[tokio::test]
    async fn stable_read_only_observation_never_grants_or_moves_a_session() {
        let (_dir, node, request, input) = fixture().await;
        let changes = node.db.lock().total_changes();
        let a = observe(&node, &request, &input).unwrap();
        let b = observe(&node, &request, &input).unwrap();
        assert_eq!(a, b);
        let discovery = Input {
            expected_workspace_id: input.expected_workspace_id.clone(),
            expected_runner_epoch: None,
            target_workspace_id: input.target_workspace_id.clone(),
        };
        assert_eq!(observe(&node, &request, &discovery).unwrap(), a);
        assert_eq!(a["canConfirm"], false);
        assert_eq!(a["historyComplete"], false);
        assert_eq!(a["evidence"]["overlap"], false);
        assert_eq!(node.db.lock().total_changes(), changes);
        assert!(!a.to_string().contains(node.env.get("HOME").unwrap()));
        assert_eq!(
            node.db
                .lock()
                .get_session(request.param("id").unwrap())
                .unwrap()
                .workspace_id,
            "repo"
        );
        node.close().await;
    }
    #[tokio::test]
    async fn aliases_replacements_and_missing_paths_change_evidence_without_creation() {
        let (dir, node, request, input) = fixture().await;
        let root = dir.path().canonicalize().unwrap();
        let before = observe(&node, &request, &input).unwrap();
        std::fs::rename(root.join("target"), root.join("saved")).unwrap();
        let absent = observe(&node, &request, &input).unwrap();
        assert_eq!(
            absent["evidence"]["targetResource"]["state"],
            "not_materialized"
        );
        assert!(!root.join("target").exists());
        std::fs::create_dir(root.join("target")).unwrap();
        assert_ne!(
            observe(&node, &request, &input).unwrap()["evidenceHash"],
            before["evidenceHash"]
        );
        std::fs::remove_dir(root.join("target")).unwrap();
        std::os::unix::fs::symlink(root.join("repo"), root.join("target")).unwrap();
        assert_eq!(
            observe(&node, &request, &input).unwrap()["evidence"]["overlap"],
            true
        );
        node.close().await;
    }
    #[tokio::test]
    async fn stale_deleted_and_other_owner_sources_are_refused() {
        let (_dir, node, mut request, mut input) = fixture().await;
        input.expected_runner_epoch = Some(input.expected_runner_epoch.unwrap() + 1);
        assert_eq!(
            observe(&node, &request, &input).unwrap_err().code,
            "stale_environment"
        );
        input.expected_runner_epoch = Some(input.expected_runner_epoch.unwrap() - 1);
        request.user = "other".into();
        assert!(observe(&node, &request, &input).is_err());
        request.user = "test-user".into();
        node.db
            .lock()
            .begin_session_deletion(request.param("id").unwrap(), &request.user)
            .unwrap();
        assert!(observe(&node, &request, &input).is_err());
        node.close().await;
    }
    #[tokio::test]
    async fn per_session_target_does_not_allocate_a_directory() {
        let (_dir, node, request, mut input) = fixture().await;
        let mut chat = pirc_protocol::mode::default_chat();
        chat.id = ModeId::new("review").unwrap();
        node.replace_modes(vec![pirc_protocol::mode::default_work(), chat])
            .await;
        let dir = crate::chat::chat_workspace_dir(&node.config, "project").unwrap();
        node.db
            .lock()
            .add_workspace(
                "project",
                "test-node",
                "Project",
                dir.to_str().unwrap(),
                ModeId::new("review").unwrap(),
            )
            .unwrap();
        input.target_workspace_id = "project".into();
        let before = node.db.lock().total_changes();
        let result = observe(&node, &request, &input).unwrap();
        assert_eq!(
            result["evidence"]["targetResource"]["state"],
            "not_materialized"
        );
        assert!(!dir.join("sessions").exists());
        assert_eq!(before, node.db.lock().total_changes());
        node.close().await;
    }
    #[tokio::test]
    async fn private_recovery_target_is_hidden_without_reading_its_resource() {
        let (_dir, node, request, input) = fixture().await;
        let changes = {
            let db = node.db.lock();
            db.execute("INSERT INTO checkpoint_intents VALUES('job','other','source','capture',0,0,'{}',0)",[]).unwrap();
            db.execute(
                "INSERT INTO checkpoint_workspaces VALUES('target','job','other','private',0)",
                [],
            )
            .unwrap();
            db.total_changes()
        };
        assert_eq!(observe(&node, &request, &input).unwrap_err().status, 404);
        assert_eq!(node.db.lock().total_changes(), changes);
        node.close().await;
    }
    #[tokio::test]
    async fn unknown_activity_and_fenced_sources_never_become_ready() {
        let (_dir, node, request, input) = fixture().await;
        let id = request.param("id").unwrap();
        let run = node.db.lock().create_run(id).unwrap();
        let busy = observe(&node, &request, &input).unwrap();
        assert_eq!(busy["evidence"]["activity"]["pendingRecords"], true);
        node.db
            .lock()
            .update_run(&run, crate::store::RunStatus::Succeeded, None)
            .unwrap();
        let lease = node
            .db
            .lock()
            .acquire_lease(id, "phone", false, 60000)
            .unwrap();
        accept(
            &node.db.lock(),
            "test-user",
            id,
            &Intent {
                operation_id: "preflight".into(),
                plan_hash: "a".repeat(64),
                expected_workspace_id: "repo".into(),
                expected_runner_epoch: input.expected_runner_epoch.unwrap(),
                preflight: None,
            },
            "phone",
            lease.generation,
        )
        .unwrap();
        let fenced = observe(&node, &request, &input).unwrap();
        assert_eq!(fenced["evidence"]["activity"]["fenced"], true);
        assert_eq!(fenced["canConfirm"], false);
        node.close().await;
    }
}

#[cfg(test)]
mod acceptance_tests {
    use super::tests::fixture;
    use super::*;
    fn checked(
        node: &Node,
        request: &Request,
        intent: &Intent,
        generation: i64,
    ) -> ApiResult<Receipt> {
        let db = node.db.lock();
        let id = request.param("id").unwrap();
        super::super::accept_with(&db, &request.user, id, intent, "phone", generation, |tx| {
            check_proof(node, tx, &request.user, id, intent)
        })
    }
    fn intent(node: &Node, request: &Request, input: &Input) -> (Intent, i64) {
        let id = request.param("id").unwrap();
        let lease = node
            .db
            .lock()
            .acquire_lease(id, "phone", false, 60000)
            .unwrap();
        let observed = observe(node, request, input).unwrap();
        (
            Intent {
                operation_id: "bound-transition".into(),
                plan_hash: "a".repeat(64),
                expected_workspace_id: input.expected_workspace_id.clone(),
                expected_runner_epoch: input.expected_runner_epoch.unwrap(),
                preflight: Some(ResourceProof {
                    target_workspace_id: input.target_workspace_id.clone(),
                    evidence_hash: observed["evidenceHash"].as_str().unwrap().into(),
                }),
            },
            lease.generation,
        )
    }
    #[tokio::test]
    async fn changed_resource_rejects_before_fencing_and_replay_keeps_original_proof() {
        let (dir, node, request, input) = fixture().await;
        let (mut intent, generation) = intent(&node, &request, &input);
        let root = dir.path().canonicalize().unwrap();
        std::fs::rename(root.join("target"), root.join("saved-target")).unwrap();
        assert_eq!(
            checked(&node, &request, &intent, generation)
                .unwrap_err()
                .code,
            "stale_resource_preflight"
        );
        require_open(&node.db.lock(), request.param("id").unwrap()).unwrap();
        intent.preflight.as_mut().unwrap().evidence_hash = observe(&node, &request, &input)
            .unwrap()["evidenceHash"]
            .as_str()
            .unwrap()
            .into();
        let receipt = checked(&node, &request, &intent, generation).unwrap();
        assert_eq!(receipt.state, "fenced");
        assert!(!receipt.revocation_confirmed && !receipt.target_installed);
        // Receipt replay is reconciliation, not a new check or resource grant.
        node.db
            .lock()
            .acquire_lease(request.param("id").unwrap(), "other-device", true, 60000)
            .unwrap();
        let replay = checked(&node, &request, &intent, generation).unwrap();
        assert_eq!(replay.intent, receipt.intent);
        let mut conflict = intent.clone();
        conflict.preflight.as_mut().unwrap().evidence_hash = "b".repeat(64);
        assert_eq!(
            checked(&node, &request, &conflict, generation)
                .unwrap_err()
                .code,
            "conflict"
        );
        assert!(!root.join("target").exists());
        assert!(root.join("saved-target").is_dir());
        node.close().await;
    }
    #[tokio::test]
    async fn activity_changes_and_failed_commits_leave_source_open() {
        let (_dir, node, request, input) = fixture().await;
        let (mut intent, generation) = intent(&node, &request, &input);
        let id = request.param("id").unwrap();
        let run = node.db.lock().create_run(id).unwrap();
        assert_eq!(
            checked(&node, &request, &intent, generation)
                .unwrap_err()
                .code,
            "stale_resource_preflight"
        );
        require_open(&node.db.lock(), id).unwrap();
        node.db
            .lock()
            .update_run(&run, crate::store::RunStatus::Succeeded, None)
            .unwrap();
        intent.preflight.as_mut().unwrap().evidence_hash = observe(&node, &request, &input)
            .unwrap()["evidenceHash"]
            .as_str()
            .unwrap()
            .into();
        node.db.lock().execute_batch("CREATE TRIGGER refuse_bound_fence BEFORE INSERT ON execution_fences BEGIN SELECT RAISE(ABORT,'simulated disk failure'); END;").unwrap();
        assert!(checked(&node, &request, &intent, generation).is_err());
        require_open(&node.db.lock(), id).unwrap();
        assert_eq!(node.db.lock().get_session(id).unwrap().workspace_id, "repo");
        node.close().await;
    }
    #[tokio::test]
    async fn semantic_upgrade_preserves_legacy_receipts_and_does_not_invent_proofs() {
        let (_dir, node, request, input) = fixture().await;
        let (mut intent, generation) = intent(&node, &request, &input);
        intent.preflight = None;
        let id = request.param("id").unwrap();
        super::super::accept(
            &node.db.lock(),
            &request.user,
            id,
            &intent,
            "phone",
            generation,
        )
        .unwrap();
        let path = node.config.database_path.clone();
        node.db
            .lock()
            .pragma_update(None, "user_version", 2018)
            .unwrap();
        node.close().await;
        drop(node);
        let db = crate::store::Db::open(&path).unwrap();
        let db = db.lock();
        assert_eq!(
            db.pragma_query_value(None, "user_version", |r| r.get::<_, i64>(0))
                .unwrap(),
            2019
        );
        let saved = receipt(&db, &request.user, id, &intent.operation_id)
            .unwrap()
            .unwrap();
        assert_eq!(saved.intent, intent);
        assert!(
            serde_json::to_value(saved).unwrap()["intent"]
                .get("preflight")
                .is_none()
        );
        assert_eq!(
            require_open(&db, id).unwrap_err().code,
            "environment_transition_pending"
        );
    }
    #[tokio::test]
    async fn bare_acceptance_cannot_bypass_resource_validation() {
        let (_dir, node, request, input) = fixture().await;
        let (intent, generation) = intent(&node, &request, &input);
        let id = request.param("id").unwrap();
        assert_eq!(
            super::super::accept(
                &node.db.lock(),
                &request.user,
                id,
                &intent,
                "phone",
                generation
            )
            .unwrap_err()
            .code,
            "resource_preflight_required"
        );
        require_open(&node.db.lock(), id).unwrap();
        assert!(checked(&node, &request, &intent, generation + 1).is_err());
        require_open(&node.db.lock(), id).unwrap();
        assert_eq!(
            serde_json::to_value(&intent).unwrap()["preflight"]["evidenceHash"],
            intent.preflight.as_ref().unwrap().evidence_hash
        );
        node.close().await;
    }
}
