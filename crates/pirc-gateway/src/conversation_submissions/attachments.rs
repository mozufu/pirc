//! Immutable, bounded private files with durable receipts and cleanup jobs.
//! Filesystem work runs on blocking workers. SQLite serializes it against
//! cancellation, including other Gateway processes using the same state.
use std::{
    collections::HashSet,
    fs::{self, DirBuilder, File, OpenOptions},
    io::{Read, Write},
    os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt},
    path::{Path as FsPath, PathBuf},
    sync::Arc,
    time::Duration,
};

use axum::routing::put;
use rusqlite::TransactionBehavior;

use super::*;
use crate::{http::Body, util::sha256_hex};

pub(super) const RETENTION_MS: i64 = 7 * 24 * 60 * 60 * 1000;

pub(super) fn routes() -> Router<AppState> {
    Router::new().route(
        "/api/conversation-submissions/{id}/attachments/{attachment}",
        put(upload),
    )
}
fn unavailable() -> ApiError {
    ApiError::new(
        503,
        "attachment_storage_unavailable",
        "Attachment staging storage is unavailable; retain the local file and retry the same operation",
    )
}
fn conflict() -> ApiError {
    ApiError::new(
        409,
        "attachment_conflict",
        "Attachment bytes do not match the immutable manifest",
    )
}
fn root(app: &AppState) -> PathBuf {
    app.config.state_dir.join("submission-staging")
}
fn private_directory(path: &FsPath, create: bool) -> ApiResult<bool> {
    if create {
        match DirBuilder::new().mode(0o700).create(path) {
            Ok(()) => {
                File::open(path.parent().ok_or_else(unavailable)?)
                    .and_then(|f| f.sync_all())
                    .map_err(|_| unavailable())?;
            }
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(_) => return Err(unavailable()),
        }
    }
    let metadata = match fs::symlink_metadata(path) {
        Ok(m) => m,
        Err(e) if !create && e.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(_) => return Err(unavailable()),
    };
    if !metadata.is_dir()
        || metadata.file_type().is_symlink()
        || metadata.permissions().mode() & 0o077 != 0
    {
        return Err(unavailable());
    }
    Ok(true)
}
pub(super) fn directory(app: &AppState, session: &str, create: bool) -> ApiResult<Option<PathBuf>> {
    // The server-reserved public ID is the only directory key, never a user filename.
    if !valid_id(session) {
        return Err(unavailable());
    }
    let base = root(app);
    if !private_directory(&base, create)? {
        return Ok(None);
    }
    let dir = base.join(session);
    Ok(private_directory(&dir, create)?.then_some(dir))
}
pub(super) fn read_verified(path: &FsPath, attachment: &Attachment) -> ApiResult<Vec<u8>> {
    let file = pirc_config::private_files::open_private_regular(path).map_err(|_| unavailable())?;
    let metadata = file.metadata().map_err(|_| unavailable())?;
    if !metadata.is_file()
        || metadata.file_type().is_symlink()
        || metadata.len() != attachment.byte_size
        || metadata.permissions().mode() & 0o077 != 0
    {
        return Err(unavailable());
    }
    let mut bytes = Vec::new();
    file.take(attachment.byte_size + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| unavailable())?;
    if bytes.len() as u64 != attachment.byte_size || sha256_hex(&bytes) != attachment.sha256 {
        return Err(unavailable());
    }
    Ok(bytes)
}
struct PartialFile(PathBuf);
impl Drop for PartialFile {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}
fn write_file(dir: &FsPath, attachment: &Attachment, bytes: &[u8]) -> ApiResult<()> {
    let final_path = dir.join(format!("{}.bin", attachment.id));
    match fs::symlink_metadata(&final_path) {
        Ok(_) => {
            read_verified(&final_path, attachment)?;
            File::open(&final_path)
                .and_then(|f| f.sync_all())
                .map_err(|_| unavailable())?;
            File::open(dir)
                .and_then(|f| f.sync_all())
                .map_err(|_| unavailable())?;
            return Ok(());
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(_) => return Err(unavailable()),
    }
    let temporary_path = dir.join(format!(".{}.{}.part", attachment.id, crate::util::uuid()));
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&temporary_path)
        .map_err(|_| unavailable())?;
    // Only a successful create_new makes this path ours to remove.
    let temporary = PartialFile(temporary_path);
    file.write_all(bytes)
        .and_then(|()| file.sync_all())
        .map_err(|_| unavailable())?;
    // Atomic no-clobber publication. A crash before the receipt can safely
    // adopt this complete file; unexpected existing content is never replaced.
    match fs::hard_link(&temporary.0, &final_path) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
            read_verified(&final_path, attachment)?;
        }
        Err(_) => return Err(unavailable()),
    }
    File::open(dir)
        .and_then(|f| f.sync_all())
        .map_err(|_| unavailable())?;
    Ok(())
}

fn pending(
    db: &Connection,
    owner: &str,
    operation: &str,
    attachment: &str,
) -> ApiResult<(Preparation, Attachment)> {
    let row = lookup(db, owner, operation)?;
    if row.state != Phase::Preparing {
        return Err(ApiError::new(
            409,
            "submission_cancelled",
            "This submission was cancelled",
        ));
    }
    let workspace = db.get_workspace(&row.workspace_id)?;
    if !db.checkpoint_workspace_visible_to_user(&workspace.id, owner)? {
        return Err(ApiError::not_found("Workspace not found"));
    }
    if row.cleanup_pending {
        return Err(ApiError::new(
            409,
            "attachment_cleanup_pending",
            "Expired attachment staging is being cleaned; retry the same operation after cleanup",
        ));
    }
    let item = row
        .submission
        .as_ref()
        .and_then(|s| s.attachments.iter().find(|a| a.id == attachment))
        .cloned()
        .ok_or_else(|| ApiError::not_found("Attachment not found"))?;
    Ok((row, item))
}
pub(super) fn stage(
    app: &AppState,
    owner: &str,
    operation: &str,
    attachment: &str,
    bytes: &[u8],
) -> ApiResult<Preparation> {
    let digest = sha256_hex(bytes);
    let (session, item) = {
        let mut db = app.db.lock();
        let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let (row, item) = pending(&tx, owner, operation, attachment)?;
        if bytes.is_empty()
            || bytes.len() > app.config.upload_max_bytes
            || bytes.len() as u64 != item.byte_size
            || digest != item.sha256
        {
            return Err(conflict());
        }
        // Commit before any bytes are written, so crash orphans also expire.
        let stamp = now_ms();
        tx.execute("UPDATE conversation_submissions SET attachments_expires_at=?3,attachments_expired_at=NULL,updated_at=?4 WHERE owner_user=?1 AND operation_id=?2",params![owner,operation,stamp.saturating_add(RETENTION_MS),stamp])?;
        tx.commit()?;
        (row.session_id, item)
    };
    let mut db = app.db.lock();
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    // Cancellation/deletion can win between deadline reservation and file I/O.
    pending(&tx, owner, operation, attachment)?;
    let written = (|| {
        let dir = directory(app, &session, true)?.ok_or_else(unavailable)?;
        write_file(&dir, &item, bytes)
    })();
    if let Err(error) = written {
        // A known failed validation must not leave an old ready receipt.
        tx.execute("DELETE FROM conversation_submission_attachments WHERE owner_user=?1 AND operation_id=?2 AND attachment_id=?3",params![owner,operation,attachment])?;
        tx.commit()?;
        return Err(error);
    }
    tx.execute("INSERT INTO conversation_submission_attachments(owner_user,operation_id,attachment_id,byte_size,sha256,created_at) VALUES(?1,?2,?3,?4,?5,?6) ON CONFLICT(owner_user,operation_id,attachment_id) DO NOTHING",params![owner,operation,attachment,item.byte_size,item.sha256,now_ms()])?;
    let row = lookup(&tx, owner, operation)?;
    tx.commit()?;
    Ok(row)
}
async fn upload(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Path((operation, attachment)): Path<(String, String)>,
    ReqBody(body): ReqBody,
) -> ApiResult<axum::Json<Value>> {
    if !valid_id(&operation) || !valid_id(&attachment) {
        return Err(ApiError::invalid_input());
    }
    // Always transport as bytes, including JSON/HTML files; the manifest owns MIME.
    let Body::Raw {
        bytes,
        content_type,
    } = body
    else {
        return Err(ApiError::invalid_input());
    };
    if content_type
        .as_deref()
        .map(crate::http::media_type)
        .as_deref()
        != Some("application/octet-stream")
    {
        return Err(ApiError::invalid_input());
    }
    let row = tokio::task::spawn_blocking(move || {
        stage(&app, &identity.user, &operation, &attachment, &bytes)
    })
    .await
    .map_err(|_| ApiError::internal())??;
    Ok(axum::Json(json!({"preparation":row})))
}

fn expire(db: &mut Connection, stamp: i64) -> ApiResult<()> {
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let due=tx.prepare("SELECT owner_user,operation_id,session_id,payload_json FROM conversation_submissions WHERE state='preparing' AND attachments_expires_at<=?1 AND NOT EXISTS(SELECT 1 FROM conversation_submission_acceptances a WHERE a.owner_user=conversation_submissions.owner_user AND a.operation_id=conversation_submissions.operation_id) LIMIT 32")?.query_map([stamp],|r|Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?,r.get::<_,String>(2)?,r.get::<_,String>(3)?)))?.collect::<Result<Vec<_>,_>>()?;
    for (owner, operation, session, payload) in due {
        let spec: Spec = serde_json::from_str(&payload).map_err(|_| ApiError::internal())?;
        let ids = spec.attachments.iter().map(|a| &a.id).collect::<Vec<_>>();
        tx.execute("INSERT INTO conversation_submission_cleanup(session_id,owner_user,operation_id,attachment_ids_json,created_at) VALUES(?1,?2,?3,?4,?5) ON CONFLICT(session_id) DO NOTHING",params![session,owner,operation,serde_json::to_string(&ids).map_err(|_|ApiError::internal())?,stamp])?;
        tx.execute("DELETE FROM conversation_submission_attachments WHERE owner_user=?1 AND operation_id=?2",params![owner,operation])?;
        // Expiry removes only attachment staging, preserving the draft text/key.
        tx.execute("UPDATE conversation_submissions SET attachments_expires_at=NULL,attachments_expired_at=?3,updated_at=?3 WHERE owner_user=?1 AND operation_id=?2",params![owner,operation,stamp])?;
    }
    tx.commit()?;
    Ok(())
}
fn owned_filename(name: &str, ids: &HashSet<String>) -> bool {
    if let Some(id) = name.strip_suffix(".bin") {
        return ids.contains(id);
    }
    let Some(body) = name.strip_prefix('.').and_then(|n| n.strip_suffix(".part")) else {
        return false;
    };
    let Some((id, nonce)) = body.rsplit_once('.') else {
        return false;
    };
    ids.contains(id)
        && nonce.len() == 36
        && nonce.bytes().enumerate().all(|(i, b)| {
            if [8, 13, 18, 23].contains(&i) {
                b == b'-'
            } else {
                b.is_ascii_hexdigit()
            }
        })
}
fn clean_directory(app: &AppState, session: &str, ids: &HashSet<String>) -> ApiResult<()> {
    let Some(dir) = directory(app, session, false)? else {
        // A prior unlink may have finished before its directory fsync failed.
        // Persist the absence before acknowledging this cleanup job as done.
        let base = root(app);
        let parent = if private_directory(&base, false)? {
            base.as_path()
        } else {
            app.config.state_dir.as_path()
        };
        File::open(parent)
            .and_then(|f| f.sync_all())
            .map_err(|_| unavailable())?;
        return Ok(());
    };
    let entries = fs::read_dir(&dir)
        .map_err(|_| unavailable())?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|_| unavailable())?;
    // Validate the complete directory before deleting any positively owned file.
    for entry in &entries {
        if !entry
            .file_name()
            .to_str()
            .is_some_and(|n| owned_filename(n, ids))
            || !entry.file_type().map_err(|_| unavailable())?.is_file()
        {
            return Err(unavailable());
        }
    }
    for entry in entries {
        fs::remove_file(entry.path()).map_err(|_| unavailable())?;
    }
    fs::remove_dir(&dir).map_err(|_| unavailable())?;
    File::open(root(app))
        .and_then(|f| f.sync_all())
        .map_err(|_| unavailable())?;
    Ok(())
}
pub(super) fn sweep(app: &AppState, stamp: i64) -> ApiResult<usize> {
    expire(&mut app.db.lock(), stamp)?;
    let mut db = app.db.lock();
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let jobs=tx.prepare("SELECT session_id,attachment_ids_json FROM conversation_submission_cleanup ORDER BY last_attempt_at,created_at LIMIT 32")?.query_map([],|r|Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?)))?.collect::<Result<Vec<_>,_>>()?;
    let mut done = 0;
    for (session, raw) in jobs {
        let ids: HashSet<String> = serde_json::from_str(&raw).map_err(|_| ApiError::internal())?;
        if clean_directory(app, &session, &ids).is_ok() {
            tx.execute(
                "DELETE FROM conversation_submission_cleanup WHERE session_id=?1",
                [session],
            )?;
            done += 1;
        } else {
            // Failed paths must not starve later jobs behind one fixed page.
            tx.execute(
                "UPDATE conversation_submission_cleanup SET last_attempt_at=?2 WHERE session_id=?1",
                params![session, stamp],
            )?;
        }
    }
    tx.commit()?;
    Ok(done)
}
/// Startup and periodic retry cover deletion through other feature routes and
/// process death after a logical cancellation. Never scans unrelated directories.
pub(crate) fn start_cleanup(app: &AppState) {
    let weak = Arc::downgrade(app);
    tokio::spawn(async move {
        loop {
            let Some(app) = weak.upgrade() else {
                return;
            };
            let result = tokio::task::spawn_blocking(move || sweep(&app, now_ms())).await;
            if !matches!(result, Ok(Ok(_))) {
                crate::log::warn("Submission attachment cleanup could not finish; it will retry");
            }
            tokio::time::sleep(Duration::from_secs(60)).await;
        }
    });
}

#[cfg(test)]
mod tests;
