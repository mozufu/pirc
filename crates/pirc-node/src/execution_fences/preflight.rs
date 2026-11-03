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
    expected_runner_epoch: i64,
    target_workspace_id: String,
}
fn invalid(input: &Input) -> bool {
    [&input.expected_workspace_id, &input.target_workspace_id]
        .iter()
        .any(|id| id.is_empty() || id.len() > 1024 || id.contains('\0'))
        || !(0..=9_007_199_254_740_991).contains(&input.expected_runner_epoch)
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
    if invalid(input) {
        return Err(ApiError::invalid_input());
    }
    let db = node.db.lock();
    if node.closing() {
        return Err(ApiError::runner_unavailable("Node is stopping"));
    }
    let id = request.param("id").unwrap_or_default();
    let session = db.claim_session(id, &request.user, false)?;
    if session.workspace_id != input.expected_workspace_id
        || session.runner_epoch != input.expected_runner_epoch
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
        crate::checkpoints::continuation::require_workspace_owner(
            &db,
            &workspace.id,
            &request.user,
        )?;
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
    let fenced = match require_open(&db, id) {
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
        "sandboxProcesses":crate::process_journal::summary(&db,id)?,
        "hostCommands":crate::host_commands::summary(&db,id)?,
        "terminals":crate::terminals::journal::summary(&db,id)?,
        "browser":crate::browser::journal::summary(&db,id)?});
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
mod tests {
    use super::*;
    use crate::{router::Body, store::ModeId};
    async fn fixture() -> (tempfile::TempDir, Node, Request, Input) {
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
            expected_runner_epoch: session.runner_epoch,
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
        input.expected_runner_epoch += 1;
        assert_eq!(
            observe(&node, &request, &input).unwrap_err().code,
            "stale_environment"
        );
        input.expected_runner_epoch -= 1;
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
                expected_runner_epoch: input.expected_runner_epoch,
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
