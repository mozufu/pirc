//! Durable acceptance/publication and idempotent Node materialization. No command,
//! lease acquisition, journal admission or model execution occurs in this module.
use base64::{Engine as _, engine::general_purpose::STANDARD};
use pirc_protocol::{HttpMethod, NodeHttpRequest, NodeHttpResponse};

use super::*;

pub(super) fn routes() -> Router<AppState> {
    Router::new()
        .route("/api/conversation-submissions/{id}/accept", post(accept))
        .route(
            "/api/conversation-submissions/{id}/materialize",
            post(materialize),
        )
}
pub(super) fn summary(
    db: &Connection,
    owner: &str,
    op: &str,
) -> ApiResult<Option<(String, i64, Option<String>)>> {
    Ok(db.query_row("SELECT phase,accepted_at,last_error_code FROM conversation_submission_acceptances WHERE owner_user=?1 AND operation_id=?2", params![owner,op], |r|Ok((r.get(0)?,r.get(1)?,r.get(2)?))).optional()?)
}
#[derive(Clone)]
pub(super) struct Target {
    pub(super) node: String,
    pub(super) workspace: String,
    pub(super) creation: String,
    pub(super) hash: String,
}
pub(super) fn target(db: &Connection, owner: &str, op: &str) -> ApiResult<Target> {
    db.query_row("SELECT node_id,local_workspace_id,node_operation_id,submission_hash FROM conversation_submissions WHERE owner_user=?1 AND operation_id=?2",params![owner,op],|r|Ok(Target{node:r.get(0)?,workspace:r.get(1)?,creation:r.get(2)?,hash:r.get(3)?})).optional()?.ok_or_else(||ApiError::not_found("Submission not found"))
}
pub(super) fn require_caller(
    app: &AppState,
    db: &Connection,
    identity: &Identity,
) -> ApiResult<()> {
    crate::auth::require_current_device(app, db, identity)
}
pub(super) fn pending_error() -> ApiError {
    ApiError::new(
        409,
        "submission_unavailable",
        "The submission is cancelled, deleted or unavailable",
    )
}
fn bad_node() -> ApiError {
    ApiError::new(
        502,
        "invalid_creation_receipt",
        "Node did not confirm the expected conversation or attachment",
    )
}
pub(super) fn require_current(
    app: &AppState,
    db: &Connection,
    owner: &str,
    row: &Preparation,
    target: &Target,
) -> ApiResult<()> {
    if row.state == Phase::Cancelled {
        return Err(pending_error());
    }
    if crate::workspace_removal::removed(db, &row.workspace_id)? {
        return Err(ApiError::new(
            409,
            "workspace_removed",
            "Restore the original workspace before resuming this submission",
        ));
    }
    let workspace = db.get_workspace(&row.workspace_id)?;
    if !db.checkpoint_workspace_visible_to_user(&workspace.id, owner)? {
        return Err(ApiError::not_found("Workspace not found"));
    }
    if workspace.host_id != target.node || workspace.local_id() != Some(target.workspace.as_str()) {
        return Err(ApiError::new(
            409,
            "submission_target_changed",
            "The original workspace binding changed",
        ));
    }
    app.require_mode(&workspace)?;
    let online = app.nodes.get(&target.node).is_some_and(|n| {
        n.modes.contains(&workspace.mode)
            && n.workspaces
                .iter()
                .any(|w| w.id == target.workspace && w.mode == workspace.mode)
    });
    if !online {
        return Err(ApiError::new(
            503,
            "node_offline",
            "The selected Node or workspace is offline",
        ));
    }
    Ok(())
}
fn choices(app: &AppState, spec: &Spec) -> ApiResult<(ModelChoice, ThinkingLevel)> {
    let models = app.models();
    let selected = spec
        .model
        .clone()
        .or_else(|| {
            models.default_model.as_ref().map(|m| ModelChoice {
                provider: m.provider.clone(),
                id: m.id.clone(),
            })
        })
        .or_else(|| {
            models.providers.iter().find_map(|(provider, p)| {
                p.models.first().map(|m| ModelChoice {
                    provider: provider.clone(),
                    id: m.id.clone(),
                })
            })
        })
        .ok_or_else(|| {
            ApiError::new(
                400,
                "model_unavailable",
                "Select an available model before sending",
            )
        })?;
    if !models
        .providers
        .get(&selected.provider)
        .is_some_and(|p| p.models.iter().any(|m| m.id == selected.id))
    {
        return Err(ApiError::new(
            400,
            "model_unavailable",
            "The selected model is unavailable",
        ));
    }
    let thinking = spec
        .thinking
        .or_else(|| models.default_model.as_ref().and_then(|m| m.thinking))
        .unwrap_or(ThinkingLevel::Medium);
    Ok((selected, thinking))
}
/// Metadata checks intentionally match Node's existing image-signature classifier.
fn validate_content(item: &Attachment, bytes: &[u8]) -> ApiResult<()> {
    let sniffed = if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        Some("image/png")
    } else if bytes.starts_with(&[0xff, 0xd8, 0xff]) {
        Some("image/jpeg")
    } else if bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a") {
        Some("image/gif")
    } else if bytes.len() >= 12 && &bytes[..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        Some("image/webp")
    } else {
        None
    };
    if sniffed
        .is_some_and(|mime| item.mime_type != "application/octet-stream" && item.mime_type != mime)
    {
        return Err(ApiError::new(
            400,
            "attachment_mime_mismatch",
            "Declared image type does not match the attachment bytes",
        ));
    }
    Ok(())
}
fn file(app: &AppState, row: &Preparation, item: &Attachment) -> ApiResult<Vec<u8>> {
    let dir = attachments::directory(app, &row.session_id, false)?.ok_or_else(|| {
        ApiError::new(
            503,
            "attachment_storage_unavailable",
            "Keep the original file; staging storage is unavailable",
        )
    })?;
    let bytes = attachments::read_verified(&dir.join(format!("{}.bin", item.id)), item)?;
    validate_content(item, &bytes)?;
    Ok(bytes)
}
fn ready_files(app: &AppState, db: &Connection, owner: &str, row: &Preparation) -> ApiResult<()> {
    let spec = row.submission.as_ref().ok_or_else(pending_error)?;
    if row.cleanup_pending {
        return Err(ApiError::new(
            409,
            "attachment_cleanup_pending",
            "Expired staging must be cleaned and restaged before acceptance",
        ));
    }
    for item in &spec.attachments {
        let receipt:bool=db.query_row("SELECT EXISTS(SELECT 1 FROM conversation_submission_attachments WHERE owner_user=?1 AND operation_id=?2 AND attachment_id=?3 AND byte_size=?4 AND sha256=?5)",params![owner,row.operation_id,item.id,item.byte_size,item.sha256],|r|r.get(0))?;
        if !receipt {
            return Err(ApiError::new(
                409,
                "attachments_incomplete",
                "Stage every attachment before accepting this message",
            ));
        }
        file(app, row, item)?;
    }
    Ok(())
}
fn response(remote: NodeHttpResponse, stage: &str) -> ApiResult<Value> {
    if remote.status >= 400 {
        // Never log upstream bodies, filenames, tokens or message contents.
        let code = remote
            .body
            .as_ref()
            .and_then(|body| body["error"]["code"].as_str())
            .filter(|code| {
                code.len() <= 64 && code.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_')
            })
            .unwrap_or("unclassified");
        crate::log::warn(&format!(
            "First-message {stage} refused: Node status {}, code {code}",
            remote.status
        ));
        return Err(ApiError::new(
            if remote.status == 404 {
                409
            } else {
                remote.status
            },
            "node_submission_unavailable",
            "Node could not complete the first-message preparation; reconcile the same submission",
        ));
    }
    remote.body.ok_or_else(bad_node)
}
pub(super) async fn supported(
    app: &AppState,
    identity: &Identity,
    target: &Target,
    spec: &Spec,
) -> ApiResult<crate::nodes::NodeConnection> {
    let connection = app.nodes.connection(&target.node)?;
    let remote = app
        .nodes
        .request_on(
            &target.node,
            connection,
            NodeHttpRequest {
                method: HttpMethod::Get,
                url: "/api/session-creations/capabilities".into(),
                user: identity.user.clone(),
                payload: None,
                body_base64: None,
                content_type: None,
            },
        )
        .await?;
    check_support(remote, spec)?;
    Ok(connection)
}

pub(super) fn check_support(remote: NodeHttpResponse, spec: &Spec) -> ApiResult<()> {
    if remote.status == 404 {
        return Err(ApiError::new(
            409,
            "first_send_unsupported",
            "Upgrade this Node before using reliable first Send",
        ));
    }
    let caps = response(remote, "capabilities")?;
    if caps["version"] != 1
        || caps["canAllocate"] != true
        || caps["canTransferAttachments"] != true
        || caps["attachmentMimeInQuery"] != true
        || caps["canAdmitFirstMessage"] != true
        || caps["canReadFirstMessageReceipt"] != true
        || caps["canCancelCreation"] != true
        || caps["canStopBeforeAllocation"] != true
        || caps["maxAttachments"]
            .as_u64()
            .is_none_or(|n| n < spec.attachments.len() as u64)
    {
        return Err(ApiError::new(
            409,
            "first_send_unsupported",
            "The Node does not support this first-message workflow",
        ));
    }
    let max = caps["maxUploadBytes"].as_u64().ok_or_else(bad_node)?;
    for item in &spec.attachments {
        // Base64 plus the request/envelope/URL must fit the existing link limit.
        if item.byte_size > max
            || item.byte_size.div_ceil(3) * 4 + 8192 > pirc_protocol::NODE_FRAME_MAX_BYTES as u64
        {
            return Err(ApiError::new(
                413,
                "attachment_too_large",
                "An attachment exceeds the selected Node or link limit",
            ));
        }
    }
    Ok(())
}
fn commit_acceptance(
    app: &AppState,
    identity: &Identity,
    op: &str,
    expected: &Target,
) -> ApiResult<Preparation> {
    let owner = identity.user.as_str();
    let mut db = app.db.lock();
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let row = lookup(&tx, owner, op)?;
    if row.accepted {
        tx.commit()?;
        return Ok(row);
    }
    require_caller(app, &tx, identity)?;
    let current = target(&tx, owner, op)?;
    if current.node != expected.node
        || current.workspace != expected.workspace
        || current.hash != expected.hash
    {
        return Err(pending_error());
    }
    require_current(app, &tx, owner, &row, &current)?;
    ready_files(app, &tx, owner, &row)?;
    if row
        .attachments_expires_at
        .is_some_and(|deadline| deadline <= now_ms())
    {
        return Err(ApiError::new(
            409,
            "attachments_expired",
            "The unaccepted staging expired; restage the original files",
        ));
    }
    require_current(app, &tx, owner, &row, &current)?;
    let (model, thinking) = choices(app, row.submission.as_ref().ok_or_else(pending_error)?)?;
    let stamp = now_ms();
    tx.execute("INSERT INTO sessions(id,workspace_id,private_session_path,name,name_source,node_id,owner_user,created_at,updated_at) VALUES(?1,?2,?3,?4,'auto',?5,?6,?7,?7)",params![row.session_id,row.workspace_id,format!("submission://{}",row.session_id),crate::db::PLACEHOLDER_SESSION_NAME,current.node,owner,stamp])?;
    let thinking = serde_json::to_value(thinking).map_err(|_| ApiError::internal())?;
    tx.execute("INSERT INTO conversation_submission_acceptances(owner_user,operation_id,phase,accepted_at,updated_at,model_json,thinking) VALUES(?1,?2,'accepted',?3,?3,?4,?5)",params![owner,op,stamp,serde_json::to_string(&model).map_err(|_|ApiError::internal())?,thinking.as_str().ok_or_else(ApiError::internal)?])?;
    tx.execute("UPDATE conversation_submissions SET attachments_expires_at=NULL,attachments_expired_at=NULL,updated_at=?3 WHERE owner_user=?1 AND operation_id=?2",params![owner,op,stamp])?;
    let row = lookup(&tx, owner, op)?;
    tx.commit()?;
    Ok(row)
}
pub(super) async fn accept_intent(
    app: &AppState,
    identity: &Identity,
    op: &str,
) -> ApiResult<Preparation> {
    let (row, target) = {
        let db = app.db.lock();
        let row = lookup(&db, &identity.user, op)?;
        if row.accepted {
            return Ok(row);
        }
        require_caller(app, &db, identity)?;
        let target = target(&db, &identity.user, op)?;
        require_current(app, &db, &identity.user, &row, &target)?;
        choices(app, row.submission.as_ref().ok_or_else(pending_error)?)?;
        (row, target)
    };
    supported(
        app,
        identity,
        &target,
        row.submission.as_ref().ok_or_else(pending_error)?,
    )
    .await?;
    let app = app.clone();
    let identity = identity.clone();
    let op = op.to_owned();
    let row = tokio::task::spawn_blocking(move || commit_acceptance(&app, &identity, &op, &target))
        .await
        .map_err(|_| ApiError::internal())??;
    Ok(row)
}
async fn accept(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(op): Path<String>,
    headers: axum::http::HeaderMap,
) -> ApiResult<(axum::http::StatusCode, axum::Json<Value>)> {
    client::require(&headers)?;
    if !valid_id(&op) {
        return Err(ApiError::invalid_input());
    }
    let row = accept_intent(&app, &identity, &op).await?;
    app.sessions_changed(Some(&identity.user));
    Ok((
        axum::http::StatusCode::ACCEPTED,
        axum::Json(json!({"preparation":row})),
    ))
}
fn publish_mapping(app: &AppState, identity: &Identity, op: &str, remote: &str) -> ApiResult<()> {
    let owner = identity.user.as_str();
    let mut db = app.db.lock();
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let row = lookup(&tx, owner, op)?;
    if !row.accepted || row.state == Phase::Cancelled {
        return Err(pending_error());
    }
    tx.require_session_available(&row.session_id)?;
    let target = target(&tx, owner, op)?;
    require_caller(app, &tx, identity)?;
    require_current(app, &tx, owner, &row, &target)?;
    let session = tx.claim_session(&row.session_id, owner, false)?;
    if session.workspace_id != row.workspace_id
        || session.node_id.as_deref() != Some(target.node.as_str())
    {
        return Err(ApiError::new(
            409,
            "submission_target_changed",
            "The pending conversation binding changed",
        ));
    }
    if session
        .pi_session_id
        .as_deref()
        .is_some_and(|id| id != remote)
    {
        return Err(bad_node());
    }
    let previous:Option<String>=tx.query_row("SELECT node_session_id FROM conversation_submission_acceptances WHERE owner_user=?1 AND operation_id=?2",params![owner,op],|r|r.get(0))?;
    if previous.as_deref().is_some_and(|id| id != remote) {
        return Err(bad_node());
    }
    tx.execute(
        "UPDATE sessions SET pi_session_id=?2,private_session_path=?3 WHERE id=?1",
        params![
            row.session_id,
            remote,
            format!("node://{}/{remote}", target.node)
        ],
    )?;
    tx.execute("UPDATE conversation_submission_acceptances SET node_session_id=?3,updated_at=?4 WHERE owner_user=?1 AND operation_id=?2",params![owner,op,remote,now_ms()])?;
    tx.commit()?;
    Ok(())
}
pub(super) async fn advance(
    app: &AppState,
    identity: &Identity,
    op: &str,
) -> ApiResult<Preparation> {
    let (row, target, blank) = {
        let db = app.db.lock();
        let row = lookup(&db, &identity.user, op)?;
        if !row.accepted {
            return Err(ApiError::new(
                409,
                "submission_not_accepted",
                "Accept the validated intent first",
            ));
        }
        // This POST is an explicit continuation after confirmed Stop. Prepare
        // the same blank storage, retaining the original input/staging without
        // promoting its attachments or attempting its first command again.
        let blank = row.state == Phase::Stopped;
        let ready = summary(&db, &identity.user, op)?.is_some_and(|s| s.0 == "ready");
        if (row.state != Phase::Accepted && !blank) || (blank && ready) {
            return Ok(row);
        }
        require_caller(app, &db, identity)?;
        let target = target(&db, &identity.user, op)?;
        require_current(app, &db, &identity.user, &row, &target)?;
        (row, target, blank)
    };
    let mut transfer = row.submission.as_ref().ok_or_else(pending_error)?.clone();
    if blank {
        // Explicit release after Stop allocates blank storage only. The old
        // input remains retained, so its files must not constrain this action.
        transfer.attachments.clear();
    }
    let connection = supported(app, identity, &target, &transfer).await?;
    // Capabilities are asynchronous. Stop/deletion, device revocation or a
    // removed workspace may have won while the Node was answering.
    {
        let db = app.db.lock();
        let current = lookup(&db, &identity.user, op)?;
        if current.state != row.state {
            return Ok(current);
        }
        require_caller(app, &db, identity)?;
        require_current(app, &db, &identity.user, &current, &target)?;
    }
    let remote = response(app.nodes.request_on(&target.node, connection, NodeHttpRequest {
        method: HttpMethod::Post, url: "/api/session-creations".into(), user: identity.user.clone(),
        payload: Some(json!({"operationId":target.creation,"workspaceId":target.workspace,"submissionHash":target.hash})),
        body_base64: None, content_type: None,
    }).await?, "allocation")?;
    let creation = &remote["creation"];
    let session = creation["sessionId"]
        .as_str()
        .filter(|id| valid_id(id))
        .ok_or_else(bad_node)?
        .to_owned();
    if creation["operationId"] != target.creation
        || creation["workspaceId"] != target.workspace
        || creation["state"] != "ready"
    {
        return Err(bad_node());
    }
    publish_mapping(app, identity, op, &session)?;
    let mut uploads = Vec::new();
    for item in row
        .submission
        .as_ref()
        .ok_or_else(pending_error)?
        .attachments
        .iter()
        .filter(|_| !blank)
    {
        let app_for_read = app.clone();
        let owner = identity.user.clone();
        let caller = identity.clone();
        let read_target = target.clone();
        let op = op.to_owned();
        let item = item.clone();
        let read_item = item.clone();
        let bytes = tokio::task::spawn_blocking(move || {
            let db = app_for_read.db.lock();
            let row = lookup(&db, &owner, &op)?;
            if !row.accepted || !matches!(row.state, Phase::Accepted | Phase::Ready) {
                return Err(pending_error());
            }
            db.require_session_available(&row.session_id)?;
            require_caller(&app_for_read, &db, &caller)?;
            require_current(&app_for_read, &db, &owner, &row, &read_target)?;
            file(&app_for_read, &row, &read_item)
        })
        .await
        .map_err(|_| ApiError::internal())??;
        let query = {
            let mut query = url::form_urlencoded::Serializer::new(String::new());
            query
                .append_pair("submissionHash", &target.hash)
                .append_pair("sha256", &item.sha256)
                .append_pair("byteSize", &item.byte_size.to_string())
                .append_pair("filename", &item.name)
                .append_pair("mimeType", &item.mime_type);
            query.finish()
        };
        let remote = response(
            app.nodes
                .request_on(
                    &target.node,
                    connection,
                    NodeHttpRequest {
                        method: HttpMethod::Put,
                        url: format!(
                            "/api/session-creations/{}/attachments/{}?{}",
                            target.creation, item.id, query
                        ),
                        user: identity.user.clone(),
                        payload: None,
                        body_base64: Some(STANDARD.encode(bytes)),
                        content_type: Some("application/octet-stream".into()),
                    },
                )
                .await?,
            "attachment",
        )?;
        let receipt = &remote["creationAttachment"];
        let upload = &receipt["upload"];
        let id = upload["id"]
            .as_str()
            .filter(|id| valid_id(id))
            .ok_or_else(bad_node)?;
        if receipt["operationId"] != target.creation
            || receipt["attachmentId"] != item.id
            || receipt["sessionId"] != session
            || receipt["state"] != "ready"
            || upload["sha256"] != item.sha256
            || upload["byteSize"] != item.byte_size
        {
            return Err(bad_node());
        }
        if uploads.iter().any(|known| known == id) {
            return Err(bad_node());
        }
        uploads.push(id.to_owned());
    }
    let mut db = app.db.lock();
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let current = lookup(&tx, &identity.user, op)?;
    if current.state == Phase::Cancelled {
        return Err(pending_error());
    }
    tx.require_session_available(&current.session_id)?;
    if blank {
        require_caller(app, &tx, identity)?;
        require_current(app, &tx, &identity.user, &current, &target)?;
    }
    tx.execute("UPDATE conversation_submission_acceptances SET phase='ready',upload_ids_json=?3,last_error_code=NULL,updated_at=?4 WHERE owner_user=?1 AND operation_id=?2 AND phase='accepted'",params![identity.user,op,serde_json::to_string(&uploads).map_err(|_|ApiError::internal())?,now_ms()])?;
    let row = lookup(&tx, &identity.user, op)?;
    tx.commit()?;
    Ok(row)
}
async fn materialize(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path(op): Path<String>,
    headers: axum::http::HeaderMap,
) -> ApiResult<axum::Json<Value>> {
    client::require(&headers)?;
    if !valid_id(&op) {
        return Err(ApiError::invalid_input());
    }
    let row = lookup(&app.db.lock(), &identity.user, &op)?;
    if !row.accepted {
        return Err(ApiError::new(
            409,
            "submission_not_accepted",
            "Accept the validated intent first",
        ));
    }
    let row = match advance(&app, &identity, &op).await {
        Ok(row) => row,
        Err(error) => {
            let db = app.db.lock();
            db.execute("UPDATE conversation_submission_acceptances SET last_error_code=?3,updated_at=?4 WHERE owner_user=?1 AND operation_id=?2 AND phase='accepted'",params![identity.user,op,error.code,now_ms()])?;
            lookup(&db, &identity.user, &op)?
        }
    };
    app.sessions_changed(Some(&identity.user));
    Ok(axum::Json(json!({"preparation":row})))
}
/// Generic commands cannot overtake the accepted first-message operation. Stop
/// remains available. Known admission or confirmed Stop releases this fence.
pub(crate) fn require_initial_submission_complete(db: &Connection, session: &str) -> ApiResult<()> {
    let pending:bool=db.query_row("SELECT EXISTS(SELECT 1 FROM conversation_submissions s JOIN conversation_submission_acceptances a USING(owner_user,operation_id) LEFT JOIN conversation_submission_dispatches d USING(owner_user,operation_id) WHERE s.session_id=?1 AND a.phase IN ('accepted','ready') AND d.admitted_at IS NULL AND COALESCE(d.stop_confirmed,0)=0)",[session],|r|r.get(0))?;
    if pending {
        Err(ApiError::new(
            409,
            "first_message_pending",
            "The accepted first message is still pending; reconcile that submission before sending another command",
        ))
    } else {
        Ok(())
    }
}
#[cfg(test)]
pub(crate) mod tests;
