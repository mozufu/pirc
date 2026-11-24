//! Durable Node-side allocation for the first-message workflow. Reservation is
//! committed before filesystem work; session publication and readiness commit
//! together. Allocation prepares storage without starting an agent; `admission`
//! handles the explicit, separately fenced first-message command. The Gateway
//! persists and reconciles the intent and its outcome.

pub(crate) mod admission;
pub(crate) mod cancellation;
pub(crate) mod pre_stop;
pub(crate) mod uploads;

use std::fs::DirBuilder;
use std::os::unix::fs::DirBuilderExt;
use std::path::Path;

use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};
use serde::{Deserialize, Serialize};
use serde_json::json;

use crate::error::{ApiError, ApiResult};
use crate::router::{Request, Response};
use crate::services::Node;
use crate::store::{DeletionStatus, PLACEHOLDER_SESSION_NAME, Store};
use crate::util::{now_ms, prefix_uuid};

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Input {
    operation_id: String,
    workspace_id: String,
    /// Hash of the immutable submission, computed by the trusted Gateway.
    /// This allocation API cannot validate a message it has not received.
    submission_hash: String,
}

fn valid_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 100
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

impl Input {
    fn validate(&self) -> ApiResult<()> {
        if !valid_id(&self.operation_id)
            || self.workspace_id.is_empty()
            || self.workspace_id.len() > 256
            || self.submission_hash.len() != 64
            || !self
                .submission_hash
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        {
            return Err(ApiError::invalid_input());
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
enum State {
    Reserved,
    Ready,
    Deleting,
    Deleted,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct Creation {
    operation_id: String,
    workspace_id: String,
    session_id: String,
    state: State,
    #[serde(skip)]
    submission_hash: String,
}

fn read(db: &Connection, owner: &str, operation: &str) -> ApiResult<Option<Creation>> {
    Ok(db.query_row(
        "SELECT operation_id,workspace_id,session_id,state,submission_hash FROM session_creations WHERE owner_user=?1 AND operation_id=?2",
        params![owner, operation],
        |row| {
            let state: String = row.get(3)?;
            let state = match state.as_str() {
                "reserved" => State::Reserved,
                "ready" => State::Ready,
                _ => return Err(rusqlite::Error::InvalidQuery),
            };
            Ok(Creation {
                operation_id: row.get(0)?,
                workspace_id: row.get(1)?,
                session_id: row.get(2)?,
                state,
                submission_hash: row.get(4)?,
            })
        },
    ).optional()?)
}

/// A read never recreates files, sessions or missing workspaces. Deletion
/// tombstones are authoritative even between reservation and initialization.
fn current(db: &Connection, owner: &str, mut row: Creation) -> ApiResult<Creation> {
    if let Some(cancel) = cancellation::read(db, owner, &row.operation_id)? {
        row.state = if cancel.complete {
            State::Deleted
        } else {
            State::Deleting
        };
        return Ok(row);
    }
    if let Some(deletion) = db
        .session_deletion(&row.session_id)?
        .or(db.workspace_deletion(&row.workspace_id)?)
    {
        row.state = match deletion.status {
            DeletionStatus::Deleting => State::Deleting,
            DeletionStatus::Deleted => State::Deleted,
        };
        return Ok(row);
    }
    crate::checkpoints::continuation::require_workspace_owner(db, &row.workspace_id, owner)?;
    db.get_workspace(&row.workspace_id)?;
    if row.state == State::Ready {
        let session = db.claim_session(&row.session_id, owner, false)?;
        if session.workspace_id != row.workspace_id {
            return Err(ApiError::conflict("Conversation creation binding changed"));
        }
    }
    Ok(row)
}

fn matches(row: &Creation, input: &Input) -> ApiResult<()> {
    if row.workspace_id != input.workspace_id || row.submission_hash != input.submission_hash {
        return Err(ApiError::conflict(
            "Creation identity was already used for another submission",
        ));
    }
    Ok(())
}

/// BEGIN IMMEDIATE serializes independent connections, not only this process's
/// mutex. Reservation contains no session row and no filesystem side effect.
fn reserve(db: &mut Connection, owner: &str, input: &Input) -> ApiResult<Creation> {
    input.validate()?;
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    cancellation::require_live(&tx, owner, input)?;
    pre_stop::require_binding(&tx, owner, input)?;
    let row = if let Some(row) = read(&tx, owner, &input.operation_id)? {
        matches(&row, input)?;
        current(&tx, owner, row)?
    } else {
        crate::checkpoints::continuation::require_workspace_owner(&tx, &input.workspace_id, owner)?;
        tx.get_workspace(&input.workspace_id)?;
        let row = Creation {
            operation_id: input.operation_id.clone(),
            workspace_id: input.workspace_id.clone(),
            submission_hash: input.submission_hash.clone(),
            session_id: prefix_uuid("session"),
            state: State::Reserved,
        };
        tx.execute(
            "INSERT INTO session_creations(owner_user,operation_id,workspace_id,submission_hash,session_id,state,created_at) VALUES(?1,?2,?3,?4,?5,'reserved',?6)",
            params![owner, row.operation_id, row.workspace_id, row.submission_hash, row.session_id, now_ms()],
        )?;
        row
    };
    pre_stop::mirror(&tx, owner, &row)?;
    tx.commit()?;
    Ok(row)
}

fn storage_error() -> ApiError {
    ApiError::new(
        503,
        "creation_storage_unavailable",
        "Conversation storage could not be prepared; retry with the same creation identity",
    )
}

fn initialize(
    db: &mut Connection,
    owner: &str,
    input: &Input,
    sessions_dir: &Path,
) -> ApiResult<Creation> {
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    cancellation::require_live(&tx, owner, input)?;
    pre_stop::require_binding(&tx, owner, input)?;
    let row = read(&tx, owner, &input.operation_id)?
        .ok_or_else(|| ApiError::not_found("Conversation creation not found"))?;
    matches(&row, input)?;
    let mut row = current(&tx, owner, row)?;
    pre_stop::mirror(&tx, owner, &row)?;
    if row.state == State::Reserved {
        let storage = sessions_dir.join(&row.session_id);
        match DirBuilder::new().mode(0o700).create(&storage) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                // A crash may leave the empty directory before the SQLite commit.
                // Never adopt a symlink or erase contents someone added meanwhile.
                let metadata = std::fs::symlink_metadata(&storage).map_err(|_| storage_error())?;
                if !metadata.is_dir()
                    || metadata.file_type().is_symlink()
                    || std::fs::read_dir(&storage)
                        .map_err(|_| storage_error())?
                        .next()
                        .is_some()
                {
                    return Err(storage_error());
                }
            }
            Err(_) => return Err(storage_error()),
        }
        let stamp = now_ms();
        tx.execute(
            "INSERT INTO sessions(id,workspace_id,private_session_path,name,name_source,owner_user,created_at,updated_at) VALUES(?1,?2,?3,?4,'auto',?5,?6,?6)",
            params![row.session_id, row.workspace_id, storage.to_string_lossy(), PLACEHOLDER_SESSION_NAME, owner, stamp],
        )?;
        tx.execute(
            "UPDATE session_creations SET state='ready' WHERE owner_user=?1 AND operation_id=?2",
            params![owner, input.operation_id],
        )?;
        row.state = State::Ready;
    }
    if row.state == State::Ready {
        let storage = sessions_dir.join(&row.session_id);
        let metadata = std::fs::symlink_metadata(storage).map_err(|_| storage_error())?;
        if !metadata.is_dir() || metadata.file_type().is_symlink() {
            return Err(storage_error());
        }
    }
    tx.commit()?;
    Ok(row)
}

pub(crate) async fn prepare(node: Node, request: Request) -> ApiResult<Response> {
    let input: Input = request.parse_body()?;
    input.validate()?;
    let mut db = node.db.lock();
    cancellation::require_live(&db, &request.user, &input)?;
    // Check identity conflicts and tombstones before attempting any new work.
    if let Some(row) = read(&db, &request.user, &input.operation_id)? {
        matches(&row, &input)?;
        let row = current(&db, &request.user, row)?;
        if matches!(row.state, State::Deleting | State::Deleted) {
            return Ok(Response::json(json!({ "creation": row })));
        }
    }
    node.workspace_mode(&db.get_workspace(&input.workspace_id)?)?;
    reserve(&mut db, &request.user, &input)?;
    let row = initialize(&mut db, &request.user, &input, &node.config.sessions_dir)?;
    Ok(Response::json(json!({ "creation": row })))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct InternalInput {
    workspace_id: String,
}

/// An empty session the Gateway itself starts (delegations, schedule runs),
/// with no first-message admission: the Gateway delivers its own message next.
pub(crate) async fn internal(node: Node, request: Request) -> ApiResult<Response> {
    let input: InternalInput = request.parse_body()?;
    if input.workspace_id.is_empty() {
        return Err(ApiError::invalid_input());
    }
    crate::checkpoints::continuation::require_workspace_owner(
        &node.db.lock(),
        &input.workspace_id,
        &request.user,
    )?;
    let workspace = node.db.lock().get_workspace(&input.workspace_id)?;
    node.workspace_mode(&workspace)?;
    let storage = node.config.sessions_dir.join(prefix_uuid("pi"));
    DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(&storage)
        .map_err(|_| storage_error())?;
    let session =
        node.db
            .lock()
            .create_session(&workspace.id, &storage.to_string_lossy(), &request.user)?;
    Ok(Response::status(201, json!({ "session": session })))
}

pub(crate) async fn capabilities(node: Node, _request: Request) -> ApiResult<Response> {
    Ok(Response::json(
        json!({"version":1,"canAllocate":true,"canTransferAttachments":true,"attachmentMimeInQuery":true,"canAdmitFirstMessage":true,"canReadFirstMessageReceipt":true,"canReadCommandReceipts":true,"canCancelCreation":true,"canStopBeforeAllocation":true,"canRetryInitialAdmission":true,"canVoidInitialAdmission":true,"maxUploadBytes":node.config.upload_max_bytes,"maxAttachments":16}),
    ))
}

pub(crate) async fn status(node: Node, request: Request) -> ApiResult<Response> {
    let id = request.param("id").ok_or_else(ApiError::invalid_input)?;
    if !valid_id(id) {
        return Err(ApiError::invalid_input());
    }
    let db = node.db.lock();
    let row = read(&db, &request.user, id)?
        .ok_or_else(|| ApiError::not_found("Conversation creation not found"))?;
    let row = current(&db, &request.user, row)?;
    Ok(Response::json(json!({ "creation": row })))
}

#[cfg(test)]
mod tests;
