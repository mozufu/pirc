//! The node's SQLite store: the node half of `apps/gateway/src/database.ts`
//! with a fresh schema (`schema.sql`, only the tables a node uses). No
//! TS-era database is read (docs/development/historical-records.md): one is
//! refused at start-up with a pointer to the upgrade notes, as the gateway
//! does.
//!
//! Layout: opening ([`Db::open`], WAL, 0600 files, `user_version`) and the
//! row types are implemented here; the queries ([`Store`]) are owned by
//! **core**. As in the gateway, queries are methods of [`Store`],
//! implemented for [`Connection`], so a transaction (which dereferences to a
//! connection) can combine several; modules with queries of their own
//! (memory mirror, recap, workspace-memory recall) keep them next to their
//! logic and run them on `node.db.lock()`.
//!
//! Every method returns [`ApiResult`]: a SQLite failure is logged and
//! answered as 500 `internal_error` (TS threw, and Fastify answered 500).
//! Run and lease changes must be followed by `node.activity.notify_one()`
//! (TS `onRunsChanged`), by the caller.

use std::path::Path;
use std::sync::{Mutex, MutexGuard};
use std::time::{Duration, Instant};

pub use pirc_protocol::ModeId;
use rusqlite::{Connection, OptionalExtension, Row, params};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::error::{ApiError, ApiResult};
use crate::util::{now_ms, prefix_uuid, safe_json};

/// `PRAGMA user_version` of the node's schema. The TS node's database used
/// the gateway's migrations (1 to 19) and the Rust gateway's schema is 1000;
/// the node's line starts apart from both, so each is recognized.
/// 2001: uploads record their workspace and session; `workspace_deletions`.
pub const SCHEMA_VERSION: i64 = 2019;
/// Upgrades from each earlier node schema, applied in order.
const MIGRATIONS: &[(i64, &str)] = &[
    (
        2001,
        "ALTER TABLE uploads ADD COLUMN workspace_id TEXT;
     ALTER TABLE uploads ADD COLUMN session_id TEXT;
     CREATE INDEX uploads_workspace ON uploads(workspace_id);
     CREATE TABLE workspace_deletions (
       workspace_id TEXT PRIMARY KEY, owner_user TEXT NOT NULL,
       status TEXT NOT NULL, created_at INTEGER NOT NULL
     );",
    ),
    (
        2002,
        r#"CREATE TABLE IF NOT EXISTS checkpoint_intents (
  job TEXT PRIMARY KEY, owner TEXT NOT NULL, source_session TEXT NOT NULL,
  capture TEXT NOT NULL, expected_revision INTEGER NOT NULL,
  accept_unresolved INTEGER NOT NULL, scope_json TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS checkpoint_workspaces (
  workspace_id TEXT PRIMARY KEY,
  job TEXT NOT NULL UNIQUE REFERENCES checkpoint_intents(job),
  owner TEXT NOT NULL,
  session_id TEXT NOT NULL UNIQUE,
  created_at INTEGER NOT NULL
);"#,
    ),
    (2003, include_str!("pots.sql")),
    (2004, include_str!("session_creations.sql")),
    (2005, include_str!("creation_uploads.sql")),
    (2006, include_str!("creation_admissions.sql")),
    (2007, include_str!("creation_cancellations.sql")),
    (2008, include_str!("creation_pre_stops.sql")),
    (2009, include_str!("creation_admission_attempts.sql")),
    (2010, include_str!("../command_environment.sql")),
    (2011, include_str!("../upload_origins.sql")),
    (2012, include_str!("../execution_fences/schema.sql")),
    (2013, include_str!("../process_journal/schema.sql")),
    (2014, include_str!("../process_journal/guard.sql")),
    (2015, include_str!("../host_commands/schema.sql")),
    (2016, include_str!("../host_commands/resources.sql")),
    (2017, include_str!("../terminals/journal.sql")),
    (2018, include_str!("../browser/journal.sql")),
    // Resource-bound fence intents are not understood by older receipt readers.
    (2019, "SELECT 1;"),
];
/// The first node schema.
const FIRST_SCHEMA_VERSION: i64 = 2000;
/// The Rust gateway's `user_version`.
const GATEWAY_SCHEMA_VERSION: i64 = 1000;
const SCHEMA: &str = concat!(
    include_str!("schema.sql"),
    include_str!("session_creations.sql"),
    include_str!("creation_uploads.sql"),
    include_str!("creation_admissions.sql"),
    include_str!("creation_cancellations.sql"),
    include_str!("creation_pre_stops.sql"),
    include_str!("creation_admission_attempts.sql"),
    include_str!("../command_environment.sql"),
    include_str!("../upload_origins.sql"),
    include_str!("../execution_fences/schema.sql"),
    include_str!("../process_journal/schema.sql"),
    include_str!("../process_journal/guard.sql"),
    include_str!("../host_commands/schema.sql"),
    include_str!("../host_commands/resources.sql"),
    include_str!("../terminals/journal.sql"),
    include_str!("../browser/journal.sql")
);

/// Placeholder name of a new session until the agent's title replaces it.
pub const PLACEHOLDER_SESSION_NAME: &str = "New session";

/// The open store. Never hold the lock across an `await`.
pub struct Db(Mutex<Connection>);

impl Db {
    /// Open (creating) the store at `path`, readable by the owner only.
    pub fn open(path: &Path) -> Result<Self, String> {
        let describe = |error: rusqlite::Error| format!("{}: {error}", path.display());
        let connection = Connection::open(path).map_err(describe)?;
        // Another process may hold the write lock (opening, migrating).
        connection
            .busy_timeout(SQLITE_BUSY_TIMEOUT)
            .map_err(describe)?;
        // SQLite gives the WAL and shm files the main file's mode.
        restrict_mode(path)?;
        enable_wal_mode_with_retry(&connection, path, || {})?;
        for suffix in ["-wal", "-shm"] {
            let mut name = path.as_os_str().to_owned();
            name.push(suffix);
            restrict_mode(Path::new(&name))?;
        }
        connection
            .pragma_update(None, "foreign_keys", "ON")
            .map_err(describe)?;
        // Deleted and overwritten content (forgotten memory, revoked tokens)
        // is zeroed in the database file, not left in free space. Measured
        // at under 1% more WAL bytes and no measurable time on a
        // representative write mix; it does not clean old WAL frames,
        // backups or copies (docs/deploy/backup-and-recovery.md).
        connection
            .pragma_update(None, "secure_delete", "ON")
            .map_err(describe)?;
        create_schema(&connection, path)?;
        Ok(Self(Mutex::new(connection)))
    }

    /// An in-memory store (tests).
    pub fn memory() -> Self {
        let connection = Connection::open_in_memory().expect("an in-memory database");
        connection
            .pragma_update(None, "foreign_keys", "ON")
            .expect("foreign keys");
        create_schema(&connection, Path::new(":memory:")).expect("the node schema");
        Self(Mutex::new(connection))
    }

    pub fn lock(&self) -> MutexGuard<'_, Connection> {
        self.0
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

/// A TS-era `gateway.sqlite` left in the state directory while
/// `PIRC_DATABASE_PATH` points elsewhere is refused too.
pub fn refuse_typescript_database(path: &Path) -> Result<(), String> {
    if !path.exists() {
        return Ok(());
    }
    let connection = Connection::open_with_flags(path, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
        .map_err(|error| format!("{}: {error}", path.display()))?;
    let version: i64 = connection
        .pragma_query_value(None, "user_version", |row| row.get(0))
        .map_err(|error| format!("{}: {error}", path.display()))?;
    if (1..GATEWAY_SCHEMA_VERSION).contains(&version) {
        return Err(typescript_era(path));
    }
    Ok(())
}

fn typescript_era(path: &Path) -> String {
    format!(
        "{} was written by the TypeScript node (pirc 0.3 or earlier). This node starts from a \
         fresh state directory: sessions start anew. See the upgrade notes \
         (docs/deploy/upgrades.md), then move the old state directory away.",
        path.display()
    )
}

fn restrict_mode(path: &Path) -> Result<(), String> {
    use std::os::unix::fs::PermissionsExt;
    match std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)) {
        Err(error) if error.kind() != std::io::ErrorKind::NotFound => {
            Err(format!("{}: {error}", path.display()))
        }
        _ => Ok(()),
    }
}

const SQLITE_BUSY_TIMEOUT: Duration = Duration::from_secs(5);
const WAL_BUSY_TIMEOUT: Duration = Duration::from_millis(50);
const WAL_BUSY_RETRY_WINDOW: Duration = Duration::from_secs(5);
const WAL_BUSY_RETRY_INTERVAL: Duration = Duration::from_millis(10);

/// WAL mode changes can return SQLITE_BUSY without invoking SQLite's busy
/// handler when multiple connections switch the same new database at once.
/// Retry only that pragma; schema transactions and other errors keep their
/// existing behavior.
fn enable_wal_mode_with_retry(
    connection: &Connection,
    path: &Path,
    mut on_busy: impl FnMut(),
) -> Result<(), String> {
    let describe = |error: rusqlite::Error| format!("{}: {error}", path.display());
    connection
        .busy_timeout(WAL_BUSY_TIMEOUT)
        .map_err(&describe)?;

    let deadline = Instant::now() + WAL_BUSY_RETRY_WINDOW;
    let result = loop {
        match connection.pragma_update(None, "journal_mode", "WAL") {
            Ok(()) => break Ok(()),
            Err(error) if is_busy_or_locked(&error) && Instant::now() < deadline => {
                on_busy();
                let remaining = deadline.saturating_duration_since(Instant::now());
                std::thread::sleep(WAL_BUSY_RETRY_INTERVAL.min(remaining));
            }
            Err(error) => break Err(describe(error)),
        }
    };

    let restore_timeout = connection
        .busy_timeout(SQLITE_BUSY_TIMEOUT)
        .map_err(&describe);
    match (result, restore_timeout) {
        (Err(error), _) => Err(error),
        (Ok(()), Err(error)) => Err(error),
        (Ok(()), Ok(())) => Ok(()),
    }
}

fn is_busy_or_locked(error: &rusqlite::Error) -> bool {
    matches!(
        error,
        rusqlite::Error::SqliteFailure(failure, _)
            if matches!(
                failure.code,
                rusqlite::ErrorCode::DatabaseBusy | rusqlite::ErrorCode::DatabaseLocked
            )
    )
}

/// Create the schema in a new store; refuse a TS-era one, a gateway's, or
/// one of a version this node does not know. The version is read and acted
/// on under one `BEGIN IMMEDIATE` write lock, so two processes opening the
/// same store cannot both create or migrate it.
fn create_schema(connection: &Connection, path: &Path) -> Result<(), String> {
    let describe = |error: rusqlite::Error| format!("{}: {error}", path.display());
    connection
        .execute_batch("BEGIN IMMEDIATE")
        .map_err(describe)?;
    let result = apply_schema(connection, path)
        .and_then(|()| connection.execute_batch("COMMIT").map_err(describe));
    if result.is_err() {
        let _ = connection.execute_batch("ROLLBACK");
    }
    result
}

/// [`create_schema`]'s body, inside its transaction.
fn apply_schema(connection: &Connection, path: &Path) -> Result<(), String> {
    let describe = |error: rusqlite::Error| format!("{}: {error}", path.display());
    let version: i64 = connection
        .pragma_query_value(None, "user_version", |row| row.get(0))
        .map_err(describe)?;
    match version {
        SCHEMA_VERSION => return Ok(()),
        FIRST_SCHEMA_VERSION..SCHEMA_VERSION => {
            for (to, sql) in MIGRATIONS.iter().filter(|(to, _)| *to > version) {
                connection
                    .execute_batch(&format!("{sql}\nPRAGMA user_version = {to};"))
                    .map_err(describe)?;
            }
            return Ok(());
        }
        0 => {}
        1..GATEWAY_SCHEMA_VERSION => return Err(typescript_era(path)),
        GATEWAY_SCHEMA_VERSION => {
            return Err(format!(
                "{} is a pirc-gateway database, not a node's; give the node its own state directory",
                path.display()
            ));
        }
        _ => {
            return Err(format!(
                "{} has schema version {version}, which this node ({SCHEMA_VERSION}) does not know",
                path.display()
            ));
        }
    }
    let tables: i64 = connection
        .query_row("SELECT count(*) FROM sqlite_master", [], |row| row.get(0))
        .map_err(describe)?;
    if tables > 0 {
        return Err(format!(
            "{} is not empty but has no pirc schema version; refusing to use it",
            path.display()
        ));
    }
    connection
        .execute_batch(&format!(
            "{SCHEMA}\nPRAGMA user_version = {SCHEMA_VERSION};"
        ))
        .map_err(describe)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RunnerState {
    Stopped,
    Starting,
    Ready,
    Failed,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RunStatus {
    Queued,
    Running,
    WaitingInput,
    Stopping,
    Succeeded,
    Failed,
    Cancelled,
    Interrupted,
}

impl RunStatus {
    /// Queued, running, waiting for input or stopping (`RUNNING` in TS).
    pub fn is_open(self) -> bool {
        matches!(
            self,
            Self::Queued | Self::Running | Self::WaitingInput | Self::Stopping
        )
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CommandStatus {
    Received,
    Dispatched,
    Accepted,
    Rejected,
    OutcomeUnknown,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum InteractionStatus {
    Pending,
    Answered,
    Cancelled,
    Expired,
    Stale,
}

/// `user`: the user named it; `auto`: a placeholder or generated title,
/// which a new generated title may replace.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NameSource {
    User,
    Auto,
}

/// `Workspace` (`types.ts`).
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Workspace {
    pub id: String,
    pub host_id: String,
    pub display_name: String,
    pub canonical_path: String,
    pub defaults: Map<String, Value>,
    pub mode: ModeId,
}

/// `SessionRow`. Serializing it gives `publicSession(row)`, the session as
/// the gateway and clients see it: the private fields are never written.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionRow {
    pub id: String,
    pub workspace_id: String,
    pub node_id: Option<String>,
    #[serde(skip)]
    pub owner_user: Option<String>,
    pub name: String,
    pub name_source: NameSource,
    pub runner_state: RunnerState,
    /// The newest run's status.
    pub run_status: Option<RunStatus>,
    pub runner_epoch: i64,
    pub pinned_at: Option<i64>,
    pub settled_at: Option<i64>,
    pub unread: bool,
    pub created_at: i64,
    pub updated_at: i64,
    #[serde(skip)]
    pub private_session_path: String,
    #[serde(skip)]
    pub pi_session_id: Option<String>,
    #[serde(skip)]
    pub partial_output_lost: bool,
}

/// `CommandRow`, as the commands route answers it.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CommandRow {
    pub id: String,
    pub session_id: String,
    pub payload_hash: String,
    pub payload: Value,
    pub status: CommandStatus,
    /// `null` when there is none.
    pub result: Value,
    pub error: Option<String>,
}

/// `InteractionRow`, as snapshots list pending ones.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InteractionRow {
    pub id: String,
    pub rpc_id: String,
    pub session_id: String,
    pub runner_epoch: i64,
    pub kind: String,
    pub status: InteractionStatus,
    pub request: Map<String, Value>,
    pub expires_at: i64,
}

/// A granted or renewed control lease (`{clientId, generation, expiresAt}`).
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Lease {
    pub client_id: String,
    pub generation: i64,
    pub expires_at: i64,
}

/// `getLease`: the lease with whether it has expired.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LeaseView {
    pub client_id: String,
    pub generation: i64,
    pub expires_at: i64,
    pub expired: bool,
}

/// `latestRun`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RunRow {
    pub id: String,
    pub status: RunStatus,
    pub started_at: Option<i64>,
    pub ended_at: Option<i64>,
    pub failure_reason: Option<String>,
    pub created_at: i64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum UploadKind {
    Image,
    File,
}

/// `getUpload`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UploadRow {
    pub id: String,
    pub owner_user: String,
    pub mime_type: String,
    pub byte_size: i64,
    pub storage_name: String,
    pub sha256: String,
    pub kind: UploadKind,
    pub filename: Option<String>,
    /// Where it was uploaded (`None`: before schema 2001, usable anywhere).
    pub workspace_id: Option<String>,
    pub session_id: Option<String>,
}

/// `recoverStartup`'s counts, logged.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Recovery {
    pub interrupted_runs: usize,
    pub stale_interactions: usize,
    pub unknown_commands: usize,
}

/// Where a deletion stands (`status` of `session_deletions` and
/// `workspace_deletions`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DeletionStatus {
    /// Fenced; the cleanup may still be running or need a retry.
    Deleting,
    Deleted,
}

/// A row of `session_deletions` or `workspace_deletions`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SessionDeletion {
    pub owner_user: String,
    pub status: DeletionStatus,
}

/// The node's queries (owner: **core**), each the `GatewayDatabase`
/// method of the same name; error statuses, codes and messages as there.
pub trait Store {
    /// In one transaction: open runs → `interrupted` ("node restarted"),
    /// pending interactions → `stale`, dispatched commands →
    /// `outcome_unknown`, sessions not stopped → `stopped` with
    /// `partial_output_lost`, every lease deleted.
    fn recover_startup(&self) -> ApiResult<Recovery>;
    /// Upsert the configured workspaces (`PIRC_WORKSPACES`), forcing `directory`.
    fn sync_workspaces(
        &self,
        host_id: &str,
        workspaces: &[pirc_config::ConfigWorkspace],
    ) -> ApiResult<()>;
    /// Create or repair a chat workspace the node manages.
    fn ensure_chat_workspace(
        &self,
        workspace_id: &str,
        host_id: &str,
        display_name: &str,
        canonical_path: &str,
    ) -> ApiResult<Workspace>;
    /// 409 `conflict` "Workspace ID or path is already registered".
    fn add_workspace(
        &self,
        workspace_id: &str,
        host_id: &str,
        display_name: &str,
        canonical_path: &str,
        mode: ModeId,
    ) -> ApiResult<Workspace>;
    /// By display name; a chat project being deleted is left out.
    fn list_workspaces(&self) -> ApiResult<Vec<Workspace>>;
    /// 404 "Workspace not found"; 409 while it is being deleted.
    fn get_workspace(&self, workspace_id: &str) -> ApiResult<Workspace>;
    /// By canonical path; 409 while the matching workspace is being deleted.
    fn find_workspace_by_path(&self, canonical_path: &str) -> ApiResult<Option<Workspace>>;
    /// The workspace even while it is being deleted (the deletion's own lookups).
    fn find_workspace(&self, workspace_id: &str) -> ApiResult<Option<Workspace>>;
    fn workspace_deletion(&self, workspace_id: &str) -> ApiResult<Option<SessionDeletion>>;
    /// Fence the workspace and every session in it (403 if one is another
    /// user's). Idempotent.
    fn begin_workspace_deletion(&self, workspace_id: &str, user: &str) -> ApiResult<()>;
    /// Its sessions, deleted ones excluded.
    fn workspace_sessions(&self, workspace_id: &str) -> ApiResult<Vec<SessionRow>>;
    /// Uploads recorded as made in it.
    fn workspace_uploads(&self, workspace_id: &str) -> ApiResult<Vec<UploadRow>>;
    /// Delete its upload rows, trust and row once its sessions are gone
    /// (fenced first, else an internal error).
    fn finish_workspace_deletion(&self, workspace_id: &str) -> ApiResult<()>;
    fn get_workspace_trust(&self, workspace_id: &str) -> ApiResult<Option<String>>;
    /// `None` revokes; 400 for a non-directory workspace.
    fn set_workspace_trust(
        &self,
        workspace_id: &str,
        hash: Option<&str>,
        user: &str,
    ) -> ApiResult<()>;
    /// A new session named [`PLACEHOLDER_SESSION_NAME`] (`auto`), owned by `owner_user`.
    fn create_session(
        &self,
        workspace_id: &str,
        private_session_path: &str,
        owner_user: &str,
    ) -> ApiResult<SessionRow>;
    /// 404 "Session not found".
    fn get_session(&self, session_id: &str) -> ApiResult<SessionRow>;
    /// Name it as the user did (`name_source = user`).
    fn rename_session(&self, session_id: &str, name: &str) -> ApiResult<SessionRow>;
    /// A generated title, unless the user named the session; whether it changed.
    fn auto_rename_session(&self, session_id: &str, name: &str) -> ApiResult<bool>;
    /// 403 "Session belongs to another user"; unless `deleting`, 409 while it is being deleted.
    fn claim_session(&self, session_id: &str, user: &str, deleting: bool) -> ApiResult<SessionRow>;
    fn session_deletion(&self, session_id: &str) -> ApiResult<Option<SessionDeletion>>;
    /// 409 `conflict` "This chat is being deleted. Retry Delete to finish cleanup."
    fn require_session_available(&self, session_id: &str) -> ApiResult<()>;
    fn begin_session_deletion(&self, session_id: &str, user: &str) -> ApiResult<()>;
    /// Delete the session's rows (fenced first, else an internal error).
    fn finish_session_deletion(&self, session_id: &str) -> ApiResult<()>;
    fn set_runner_state(&self, session_id: &str, state: RunnerState) -> ApiResult<()>;
    /// The next epoch (and `partial_output_lost` cleared).
    fn increment_epoch(&self, session_id: &str) -> ApiResult<i64>;
    fn set_pi_session(&self, session_id: &str, pi_session_id: Option<&str>) -> ApiResult<()>;
    /// `(session id, status)` of every open run.
    fn active_runs(&self) -> ApiResult<Vec<(String, RunStatus)>>;
    /// A `queued` run; 409 `conflict` "Session already has an active run".
    fn create_run(&self, session_id: &str) -> ApiResult<String>;
    /// `started_at` on running, `ended_at` on a final status, the failure
    /// reason cleared on running and succeeded.
    fn update_run(
        &self,
        run_id: &str,
        status: RunStatus,
        failure_reason: Option<&str>,
    ) -> ApiResult<()>;
    fn latest_run(&self, session_id: &str) -> ApiResult<Option<RunRow>>;
    /// The command and whether it is a duplicate; 409 `conflict` "commandId
    /// was already used with a different payload".
    fn receive_command(
        &self,
        command_id: &str,
        session_id: &str,
        hash: &str,
        payload: &Value,
    ) -> ApiResult<(CommandRow, bool)>;
    /// 404 "Command not found".
    fn get_command(&self, command_id: &str) -> ApiResult<CommandRow>;
    fn update_command(
        &self,
        command_id: &str,
        status: CommandStatus,
        result: Option<&Value>,
        error: Option<&str>,
    ) -> ApiResult<()>;
    fn mark_dispatched_unknown(&self, session_id: &str, reason: &str) -> ApiResult<usize>;
    fn create_interaction(
        &self,
        session_id: &str,
        epoch: i64,
        rpc_id: &str,
        kind: &str,
        request: &Map<String, Value>,
        expires_at: i64,
    ) -> ApiResult<InteractionRow>;
    /// 404 "Interaction not found".
    fn get_interaction(&self, interaction_id: &str) -> ApiResult<InteractionRow>;
    /// Pending and unexpired, oldest first.
    fn pending_interactions(&self, session_id: &str) -> ApiResult<Vec<InteractionRow>>;
    /// 409 `stale_interaction` ("Interaction is no longer answerable" /
    /// "Interaction was already answered").
    fn claim_interaction(
        &self,
        interaction_id: &str,
        session_id: &str,
        epoch: i64,
        answer: &Value,
    ) -> ApiResult<InteractionRow>;
    /// The agent withdrew a dialog: the interaction id if one was pending.
    fn cancel_interaction_by_rpc_id(
        &self,
        session_id: &str,
        epoch: i64,
        rpc_id: &str,
    ) -> ApiResult<Option<String>>;
    fn stale_epoch_interactions(&self, session_id: &str, epoch: i64) -> ApiResult<()>;
    fn get_lease(&self, session_id: &str) -> ApiResult<Option<LeaseView>>;
    /// 409 `lost_control` "Another client holds control".
    fn acquire_lease(
        &self,
        session_id: &str,
        client_id: &str,
        force: bool,
        ttl_ms: u64,
    ) -> ApiResult<Lease>;
    /// 409 `lost_control` "Control lease is missing, expired, or superseded".
    fn validate_lease(&self, session_id: &str, client_id: &str, generation: i64) -> ApiResult<()>;
    fn heartbeat_lease(
        &self,
        session_id: &str,
        client_id: &str,
        generation: i64,
        ttl_ms: u64,
    ) -> ApiResult<Lease>;
    fn release_lease(&self, session_id: &str, client_id: &str, generation: i64) -> ApiResult<()>;
    fn create_upload(&self, upload: &UploadRow) -> ApiResult<()>;
    /// 404 "Upload not found".
    fn get_upload(&self, upload_id: &str) -> ApiResult<UploadRow>;
}

/// Run `body` in a savepoint (TS `db.transaction`, which nests too): its
/// changes are kept only if it succeeds.
pub fn atomic<T>(
    connection: &Connection,
    body: impl FnOnce(&Connection) -> ApiResult<T>,
) -> ApiResult<T> {
    /// Rolls the savepoint back unless released (an error or a panic).
    struct Guard<'a>(&'a Connection, bool);
    impl Drop for Guard<'_> {
        fn drop(&mut self) {
            if !self.1 {
                let _ = self.0.execute_batch("ROLLBACK TO atomic; RELEASE atomic");
            }
        }
    }
    connection.execute_batch("SAVEPOINT atomic")?;
    let mut guard = Guard(connection, false);
    let value = body(connection)?;
    connection.execute_batch("RELEASE atomic")?;
    guard.1 = true;
    Ok(value)
}

/// The open run statuses (`RUNNING` in TS), as SQL.
const OPEN_RUNS: &str = "('queued','running','waiting_input','stopping')";

/// A session with its newest run's status (TS ordered by `created_at` only;
/// `rowid` breaks ties within one millisecond).
const SESSION_SELECT: &str = "SELECT s.id, s.workspace_id, s.node_id, s.owner_user, s.name, \
     s.name_source, s.runner_state, (SELECT status FROM runs r WHERE r.session_id=s.id \
     ORDER BY r.created_at DESC, r.rowid DESC LIMIT 1) run_status, s.runner_epoch, s.pinned_at, \
     s.settled_at, s.activity_at, s.read_at, s.created_at, s.updated_at, \
     s.private_session_path, s.pi_session_id, s.partial_output_lost FROM sessions s";

const INTERACTION_COLUMNS: &str =
    "id, rpc_id, session_id, runner_epoch, kind, status, request_json, expires_at";

/// A stored enum (`snake_case` text) as its Rust value; an unknown text is
/// a corrupt row.
fn parse_enum<T: serde::de::DeserializeOwned>(text: String) -> rusqlite::Result<T> {
    serde_json::from_value(Value::String(text.clone())).map_err(|_| {
        rusqlite::Error::FromSqlConversionFailure(
            0,
            rusqlite::types::Type::Text,
            format!("unknown stored value {text:?}").into(),
        )
    })
}

pub fn enum_text<T: Serialize>(value: T) -> String {
    match serde_json::to_value(value) {
        Ok(Value::String(text)) => text,
        _ => unreachable!("store enums serialize as strings"),
    }
}

fn object(text: &str) -> Map<String, Value> {
    match safe_json(text, Value::Null) {
        Value::Object(map) => map,
        _ => Map::new(),
    }
}

fn workspace_row(row: &Row<'_>) -> rusqlite::Result<Workspace> {
    Ok(Workspace {
        id: row.get("id")?,
        host_id: row.get("host_id")?,
        display_name: row.get("display_name")?,
        canonical_path: row.get("canonical_path")?,
        defaults: object(&row.get::<_, String>("defaults_json")?),
        mode: parse_enum(row.get("kind")?)?,
    })
}

fn session_row(row: &Row<'_>) -> rusqlite::Result<SessionRow> {
    let activity: Option<i64> = row.get("activity_at")?;
    let read: Option<i64> = row.get("read_at")?;
    Ok(SessionRow {
        id: row.get("id")?,
        workspace_id: row.get("workspace_id")?,
        node_id: row.get("node_id")?,
        owner_user: row.get("owner_user")?,
        name: row.get("name")?,
        name_source: if row.get::<_, String>("name_source")? == "auto" {
            NameSource::Auto
        } else {
            NameSource::User
        },
        runner_state: parse_enum(row.get("runner_state")?)?,
        run_status: row
            .get::<_, Option<String>>("run_status")?
            .map(parse_enum)
            .transpose()?,
        runner_epoch: row.get("runner_epoch")?,
        pinned_at: row.get("pinned_at")?,
        settled_at: row.get("settled_at")?,
        unread: activity.is_some_and(|activity| activity > read.unwrap_or(0)),
        created_at: row.get("created_at")?,
        updated_at: row.get("updated_at")?,
        private_session_path: row.get("private_session_path")?,
        pi_session_id: row.get("pi_session_id")?,
        partial_output_lost: row.get::<_, i64>("partial_output_lost")? != 0,
    })
}

fn command_row(row: &Row<'_>) -> rusqlite::Result<CommandRow> {
    let result: Option<String> = row.get("result_json")?;
    Ok(CommandRow {
        id: row.get("id")?,
        session_id: row.get("session_id")?,
        payload_hash: row.get("payload_hash")?,
        payload: safe_json(&row.get::<_, String>("payload_json")?, Value::Null),
        status: parse_enum(row.get("status")?)?,
        // TS: `row.result_json ? safeJson(...) : null` (an empty text is none).
        result: result
            .filter(|text| !text.is_empty())
            .map_or(Value::Null, |text| safe_json(&text, Value::Null)),
        error: row.get("error_text")?,
    })
}

fn interaction_row(row: &Row<'_>) -> rusqlite::Result<InteractionRow> {
    Ok(InteractionRow {
        id: row.get("id")?,
        rpc_id: row.get("rpc_id")?,
        session_id: row.get("session_id")?,
        runner_epoch: row.get("runner_epoch")?,
        kind: row.get("kind")?,
        status: parse_enum(row.get("status")?)?,
        request: object(&row.get::<_, String>("request_json")?),
        expires_at: row.get("expires_at")?,
    })
}

const UPLOAD_COLUMNS: &str = "id, owner_user, mime_type, byte_size, storage_name, sha256, kind, filename, workspace_id, session_id";

fn upload_row(row: &Row<'_>) -> rusqlite::Result<UploadRow> {
    Ok(UploadRow {
        id: row.get(0)?,
        owner_user: row.get(1)?,
        mime_type: row.get(2)?,
        byte_size: row.get(3)?,
        storage_name: row.get(4)?,
        sha256: row.get(5)?,
        kind: if row.get::<_, String>(6)? == "file" {
            UploadKind::File
        } else {
            UploadKind::Image
        },
        filename: row.get(7)?,
        workspace_id: row.get(8)?,
        session_id: row.get(9)?,
    })
}

fn workspace_not_found() -> ApiError {
    ApiError::not_found("Workspace not found")
}

fn session_not_found() -> ApiError {
    ApiError::not_found("Session not found")
}

fn lost_lease() -> ApiError {
    ApiError::new(
        409,
        "lost_control",
        "Control lease is missing, expired, or superseded",
    )
}

fn stale_interaction(message: &str) -> ApiError {
    ApiError::new(409, "stale_interaction", message.to_owned())
}

/// The store's role pin: a chat node's state holds chat workspaces only, a
/// coding node's directory workspaces only (`buildNodeApp`). An operator
/// pointing the other role at the state must not expose its workspaces.
pub fn check_role(workspaces: &[Workspace], modes: &[ModeId]) -> Result<(), String> {
    if workspaces
        .iter()
        .any(|workspace| !modes.contains(&workspace.mode))
    {
        // TS named its executables; `pirc-chat` is `pirc-node chat` now,
        // and the text keeps the old name as well, for logs and scripts.
        let role = "configured accepted modes";
        return Err(format!(
            "State contains workspaces incompatible with {role}; use the matching executable or a separate state directory"
        ));
    }
    Ok(())
}

impl Store for Connection {
    fn recover_startup(&self) -> ApiResult<Recovery> {
        atomic(self, |db| {
            let stamp = now_ms();
            let interrupted_runs = db.execute(
                &format!(
                    "UPDATE runs SET status='interrupted', ended_at=?1, \
                     failure_reason='node restarted' WHERE status IN {OPEN_RUNS}"
                ),
                [stamp],
            )?;
            let stale_interactions = db.execute(
                "UPDATE interactions SET status='stale' WHERE status='pending'",
                [],
            )?;
            let unknown_commands = db.execute(
                "UPDATE commands SET status='outcome_unknown', error_text='node restarted before \
                 RPC acceptance was recorded', updated_at=?1 WHERE status='dispatched' OR (status='received' AND id IN (SELECT command_id FROM creation_initial_admissions WHERE command_id IS NOT NULL))",
                [stamp],
            )?;
            db.execute(
                "UPDATE sessions SET runner_state='stopped', partial_output_lost=1, updated_at=?1 \
                 WHERE runner_state!='stopped'",
                [stamp],
            )?;
            db.execute("DELETE FROM leases", [])?;
            Ok(Recovery {
                interrupted_runs,
                stale_interactions,
                unknown_commands,
            })
        })
    }

    fn sync_workspaces(
        &self,
        host_id: &str,
        workspaces: &[pirc_config::ConfigWorkspace],
    ) -> ApiResult<()> {
        atomic(self, |db| {
            let mut insert = db.prepare(
                "INSERT INTO workspaces (id,host_id,display_name,canonical_path,defaults_json,created_at,kind) \
                 VALUES (?1,?2,?3,?4,?5,?6,?7) ON CONFLICT(id) DO UPDATE SET host_id=excluded.host_id, \
                 display_name=excluded.display_name, canonical_path=excluded.canonical_path, \
                 defaults_json=excluded.defaults_json, kind=excluded.kind",
            )?;
            for workspace in workspaces {
                insert.execute(params![
                    workspace.id,
                    host_id,
                    workspace.display_name,
                    workspace.path.to_string_lossy(),
                    Value::Object(workspace.defaults.clone()).to_string(),
                    now_ms(),
                    workspace.mode.as_str(),
                ])?;
            }
            Ok(())
        })
    }

    fn ensure_chat_workspace(
        &self,
        workspace_id: &str,
        host_id: &str,
        display_name: &str,
        canonical_path: &str,
    ) -> ApiResult<Workspace> {
        self.execute(
            "INSERT INTO workspaces (id,host_id,display_name,canonical_path,defaults_json,created_at,kind) \
             VALUES (?1,?2,?3,?4,'{}',?5,'chat') ON CONFLICT(id) DO UPDATE SET \
             host_id=excluded.host_id, canonical_path=excluded.canonical_path, kind='chat'",
            params![workspace_id, host_id, display_name, canonical_path, now_ms()],
        )?;
        self.get_workspace(workspace_id)
    }

    fn add_workspace(
        &self,
        workspace_id: &str,
        host_id: &str,
        display_name: &str,
        canonical_path: &str,
        mode: ModeId,
    ) -> ApiResult<Workspace> {
        let inserted = self.execute(
            "INSERT INTO workspaces (id,host_id,display_name,canonical_path,defaults_json,created_at,kind) \
             VALUES (?1,?2,?3,?4,'{}',?5,?6)",
            params![
                workspace_id,
                host_id,
                display_name,
                canonical_path,
                now_ms(),
                mode.as_str()
            ],
        );
        match inserted {
            Err(rusqlite::Error::SqliteFailure(error, _))
                if error.code == rusqlite::ErrorCode::ConstraintViolation =>
            {
                return Err(ApiError::conflict(
                    "Workspace ID or path is already registered",
                ));
            }
            other => {
                other?;
            }
        }
        self.get_workspace(workspace_id)
    }

    fn list_workspaces(&self) -> ApiResult<Vec<Workspace>> {
        // SQLite's binary collation, as TS's query.
        let mut statement = self.prepare(
            "SELECT * FROM workspaces WHERE id NOT IN (SELECT workspace_id FROM workspace_deletions) \
             ORDER BY display_name",
        )?;
        let rows = statement.query_map([], workspace_row)?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    fn get_workspace(&self, workspace_id: &str) -> ApiResult<Workspace> {
        let workspace = self
            .find_workspace(workspace_id)?
            .ok_or_else(workspace_not_found)?;
        if self.workspace_deletion(workspace_id)?.is_some() {
            return Err(ApiError::conflict(
                "This project is being deleted. Retry Delete to finish cleanup.",
            ));
        }
        Ok(workspace)
    }

    fn find_workspace_by_path(&self, canonical_path: &str) -> ApiResult<Option<Workspace>> {
        let id: Option<String> = self
            .query_row(
                "SELECT id FROM workspaces WHERE canonical_path=?1",
                [canonical_path],
                |row| row.get(0),
            )
            .optional()?;
        id.map(|id| self.get_workspace(&id)).transpose()
    }

    fn find_workspace(&self, workspace_id: &str) -> ApiResult<Option<Workspace>> {
        Ok(self
            .query_row(
                "SELECT * FROM workspaces WHERE id=?1",
                [workspace_id],
                workspace_row,
            )
            .optional()?)
    }

    fn workspace_deletion(&self, workspace_id: &str) -> ApiResult<Option<SessionDeletion>> {
        Ok(self
            .query_row(
                "SELECT owner_user, status FROM workspace_deletions WHERE workspace_id=?1",
                [workspace_id],
                |row| {
                    Ok(SessionDeletion {
                        owner_user: row.get(0)?,
                        status: parse_enum(row.get(1)?)?,
                    })
                },
            )
            .optional()?)
    }

    fn begin_workspace_deletion(&self, workspace_id: &str, user: &str) -> ApiResult<()> {
        atomic(self, |db| {
            if db.find_workspace(workspace_id)?.is_none() {
                return Err(workspace_not_found());
            }
            let other_creation:bool=db.query_row("SELECT EXISTS(SELECT 1 FROM session_creations c WHERE c.workspace_id=?1 AND c.owner_user!=?2 AND NOT EXISTS(SELECT 1 FROM session_deletions d WHERE d.session_id=c.session_id AND d.status='deleted'))",params![workspace_id,user],|r|r.get(0))?;
            if other_creation {
                return Err(ApiError::forbidden(
                    "The project has another user's pending conversations",
                ));
            }
            let sessions = db.workspace_sessions(workspace_id)?;
            if sessions
                .iter()
                .any(|session| session.owner_user.as_deref() != Some(user))
            {
                return Err(ApiError::forbidden("The project has another user's chats"));
            }
            db.execute(
                "INSERT OR IGNORE INTO workspace_deletions VALUES (?1, ?2, 'deleting', ?3)",
                params![workspace_id, user, now_ms()],
            )?;
            for session in sessions {
                db.begin_session_deletion(&session.id, user)?;
            }
            Ok(())
        })
    }

    fn workspace_sessions(&self, workspace_id: &str) -> ApiResult<Vec<SessionRow>> {
        let mut statement = self.prepare(&format!(
            "{SESSION_SELECT} WHERE s.workspace_id=?1 ORDER BY s.created_at, s.rowid"
        ))?;
        let rows = statement.query_map([workspace_id], session_row)?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    fn workspace_uploads(&self, workspace_id: &str) -> ApiResult<Vec<UploadRow>> {
        let mut statement = self.prepare(&format!(
            "SELECT {UPLOAD_COLUMNS} FROM uploads WHERE workspace_id=?1 ORDER BY created_at, rowid"
        ))?;
        let rows = statement.query_map([workspace_id], upload_row)?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    fn finish_workspace_deletion(&self, workspace_id: &str) -> ApiResult<()> {
        atomic(self, |db| {
            if db.workspace_deletion(workspace_id)?.is_none() {
                crate::log::error(&format!(
                    "deleting workspace {workspace_id}: deletion must be fenced first"
                ));
                return Err(ApiError::internal());
            }
            if !db.workspace_sessions(workspace_id)?.is_empty() {
                crate::log::error(&format!(
                    "deleting workspace {workspace_id}: sessions remain"
                ));
                return Err(ApiError::internal());
            }
            db.execute("DELETE FROM uploads WHERE workspace_id=?1", [workspace_id])?;
            db.execute(
                "DELETE FROM workspace_trust WHERE workspace_id=?1",
                [workspace_id],
            )?;
            db.execute("DELETE FROM workspaces WHERE id=?1", [workspace_id])?;
            db.execute(
                "UPDATE workspace_deletions SET status='deleted' WHERE workspace_id=?1",
                [workspace_id],
            )?;
            Ok(())
        })
    }

    fn get_workspace_trust(&self, workspace_id: &str) -> ApiResult<Option<String>> {
        Ok(self
            .query_row(
                "SELECT project_hash FROM workspace_trust WHERE workspace_id=?1",
                [workspace_id],
                |row| row.get(0),
            )
            .optional()?)
    }

    fn set_workspace_trust(
        &self,
        workspace_id: &str,
        hash: Option<&str>,
        user: &str,
    ) -> ApiResult<()> {
        self.get_workspace(workspace_id)?;
        match hash {
            None => {
                self.execute(
                    "DELETE FROM workspace_trust WHERE workspace_id=?1",
                    [workspace_id],
                )?;
            }
            Some(hash) => {
                self.execute(
                    "INSERT INTO workspace_trust (workspace_id,project_hash,trusted_by,trusted_at) \
                     VALUES (?1,?2,?3,?4) ON CONFLICT(workspace_id) DO UPDATE SET \
                     project_hash=excluded.project_hash, trusted_by=excluded.trusted_by, \
                     trusted_at=excluded.trusted_at",
                    params![workspace_id, hash, user, now_ms()],
                )?;
            }
        }
        Ok(())
    }

    fn create_session(
        &self,
        workspace_id: &str,
        private_session_path: &str,
        owner_user: &str,
    ) -> ApiResult<SessionRow> {
        self.get_workspace(workspace_id)?;
        let session_id = prefix_uuid("session");
        let stamp = now_ms();
        self.execute(
            "INSERT INTO sessions (id,workspace_id,private_session_path,name,name_source,owner_user,\
             created_at,updated_at) VALUES (?1,?2,?3,?4,'auto',?5,?6,?6)",
            params![
                session_id,
                workspace_id,
                private_session_path,
                PLACEHOLDER_SESSION_NAME,
                owner_user,
                stamp
            ],
        )?;
        self.get_session(&session_id)
    }

    fn get_session(&self, session_id: &str) -> ApiResult<SessionRow> {
        self.query_row(
            &format!("{SESSION_SELECT} WHERE s.id=?1"),
            [session_id],
            session_row,
        )
        .optional()?
        .ok_or_else(session_not_found)
    }

    fn rename_session(&self, session_id: &str, name: &str) -> ApiResult<SessionRow> {
        self.get_session(session_id)?;
        self.execute(
            "UPDATE sessions SET name=?1, name_source='user', updated_at=?2 WHERE id=?3",
            params![name, now_ms(), session_id],
        )?;
        self.get_session(session_id)
    }

    fn auto_rename_session(&self, session_id: &str, name: &str) -> ApiResult<bool> {
        Ok(self.execute(
            "UPDATE sessions SET name=?1 WHERE id=?2 AND name_source='auto' AND name!=?1",
            params![name, session_id],
        )? > 0)
    }

    fn claim_session(&self, session_id: &str, user: &str, deleting: bool) -> ApiResult<SessionRow> {
        let session = self.get_session(session_id)?;
        if session.owner_user.as_deref() != Some(user) {
            return Err(ApiError::forbidden("Session belongs to another user"));
        }
        if !deleting {
            self.require_session_available(session_id)?;
        }
        Ok(session)
    }

    fn session_deletion(&self, session_id: &str) -> ApiResult<Option<SessionDeletion>> {
        Ok(self
            .query_row(
                "SELECT owner_user, status FROM session_deletions WHERE session_id=?1",
                [session_id],
                |row| {
                    Ok(SessionDeletion {
                        owner_user: row.get(0)?,
                        status: parse_enum(row.get(1)?)?,
                    })
                },
            )
            .optional()?)
    }

    fn require_session_available(&self, session_id: &str) -> ApiResult<()> {
        if self.session_deletion(session_id)?.is_some() {
            return Err(ApiError::conflict(
                "This chat is being deleted. Retry Delete to finish cleanup.",
            ));
        }
        Ok(())
    }

    fn begin_session_deletion(&self, session_id: &str, user: &str) -> ApiResult<()> {
        self.claim_session(session_id, user, true)?;
        self.execute(
            "INSERT OR IGNORE INTO session_deletions VALUES (?1, ?2, 'deleting', ?3)",
            params![session_id, user, now_ms()],
        )?;
        Ok(())
    }

    fn finish_session_deletion(&self, session_id: &str) -> ApiResult<()> {
        atomic(self, |db| {
            if db.session_deletion(session_id)?.is_none() {
                crate::log::error(&format!(
                    "deleting session {session_id}: deletion must be fenced first"
                ));
                return Err(ApiError::internal());
            }
            // The gateway's schedule and delegation rows of TS's shared
            // database are not on a node.
            for table in ["interactions", "commands", "leases", "runs"] {
                db.execute(
                    &format!("DELETE FROM {table} WHERE session_id=?1"),
                    [session_id],
                )?;
            }
            db.execute("DELETE FROM sessions WHERE id=?1", [session_id])?;
            // Files and runner have already been stopped/removed. Preserve the
            // dispatch tombstone so cancellation can settle after deletion.
            db.execute(
                "UPDATE pots_dispatches SET state='stopped',fenced=1 WHERE session_id=?1",
                [session_id],
            )?;
            db.execute(
                "UPDATE session_deletions SET status='deleted' WHERE session_id=?1",
                [session_id],
            )?;
            Ok(())
        })
    }

    fn set_runner_state(&self, session_id: &str, state: RunnerState) -> ApiResult<()> {
        self.execute(
            "UPDATE sessions SET runner_state=?1, updated_at=?2 WHERE id=?3",
            params![enum_text(state), now_ms(), session_id],
        )?;
        Ok(())
    }

    fn increment_epoch(&self, session_id: &str) -> ApiResult<i64> {
        self.execute(
            "UPDATE sessions SET runner_epoch=runner_epoch+1, partial_output_lost=0, updated_at=?1 \
             WHERE id=?2",
            params![now_ms(), session_id],
        )?;
        Ok(self.get_session(session_id)?.runner_epoch)
    }

    fn set_pi_session(&self, session_id: &str, pi_session_id: Option<&str>) -> ApiResult<()> {
        self.execute(
            "UPDATE sessions SET pi_session_id=?1, updated_at=?2 WHERE id=?3",
            params![pi_session_id, now_ms(), session_id],
        )?;
        Ok(())
    }

    fn active_runs(&self) -> ApiResult<Vec<(String, RunStatus)>> {
        let mut statement = self.prepare(&format!(
            "SELECT session_id, status FROM runs WHERE status IN {OPEN_RUNS} ORDER BY rowid"
        ))?;
        let rows = statement.query_map([], |row| Ok((row.get(0)?, parse_enum(row.get(1)?)?)))?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    fn create_run(&self, session_id: &str) -> ApiResult<String> {
        let active = self
            .query_row(
                &format!("SELECT id FROM runs WHERE session_id=?1 AND status IN {OPEN_RUNS}"),
                [session_id],
                |row| row.get::<_, String>(0),
            )
            .optional()?;
        if active.is_some() {
            return Err(ApiError::conflict("Session already has an active run"));
        }
        let run_id = prefix_uuid("run");
        self.execute(
            "INSERT INTO runs (id,session_id,status,created_at) VALUES (?1,?2,'queued',?3)",
            params![run_id, session_id, now_ms()],
        )?;
        Ok(run_id)
    }

    fn update_run(
        &self,
        run_id: &str,
        status: RunStatus,
        failure_reason: Option<&str>,
    ) -> ApiResult<()> {
        let stamp = now_ms();
        let running = status == RunStatus::Running;
        let started_at = running.then_some(stamp);
        let terminal = (!status.is_open()).then_some(stamp);
        // Going back to running or succeeding (after an auto-retry) drops
        // the provisional failure of an earlier attempt.
        let clears = running || status == RunStatus::Succeeded;
        self.execute(
            "UPDATE runs SET status=?1, started_at=COALESCE(started_at,?2), \
             ended_at=CASE WHEN ?3 THEN NULL ELSE COALESCE(?4,ended_at) END, \
             failure_reason=CASE WHEN ?5 THEN NULL ELSE COALESCE(?6,failure_reason) END WHERE id=?7",
            params![
                enum_text(status),
                started_at,
                running,
                terminal,
                clears,
                failure_reason,
                run_id
            ],
        )?;
        Ok(())
    }

    fn latest_run(&self, session_id: &str) -> ApiResult<Option<RunRow>> {
        Ok(self
            .query_row(
                "SELECT id, status, started_at, ended_at, failure_reason, created_at FROM runs \
                 WHERE session_id=?1 ORDER BY created_at DESC, rowid DESC LIMIT 1",
                [session_id],
                |row| {
                    Ok(RunRow {
                        id: row.get(0)?,
                        status: parse_enum(row.get(1)?)?,
                        started_at: row.get(2)?,
                        ended_at: row.get(3)?,
                        failure_reason: row.get(4)?,
                        created_at: row.get(5)?,
                    })
                },
            )
            .optional()?)
    }

    fn receive_command(
        &self,
        command_id: &str,
        session_id: &str,
        hash: &str,
        payload: &Value,
    ) -> ApiResult<(CommandRow, bool)> {
        atomic(self, |db| {
            let existing = db
                .query_row(
                    "SELECT * FROM commands WHERE id=?1",
                    [command_id],
                    command_row,
                )
                .optional()?;
            if let Some(existing) = existing {
                if existing.session_id != session_id || existing.payload_hash != hash {
                    return Err(ApiError::conflict(
                        "commandId was already used with a different payload",
                    ));
                }
                return Ok((existing, true));
            }
            let stamp = now_ms();
            db.execute(
                "INSERT INTO commands (id,session_id,payload_hash,payload_json,status,created_at,\
                 updated_at) VALUES (?1,?2,?3,?4,'received',?5,?5)",
                params![command_id, session_id, hash, payload.to_string(), stamp],
            )?;
            Ok((db.get_command(command_id)?, false))
        })
    }

    fn get_command(&self, command_id: &str) -> ApiResult<CommandRow> {
        self.query_row(
            "SELECT * FROM commands WHERE id=?1",
            [command_id],
            command_row,
        )
        .optional()?
        .ok_or_else(|| ApiError::not_found("Command not found"))
    }

    fn update_command(
        &self,
        command_id: &str,
        status: CommandStatus,
        result: Option<&Value>,
        error: Option<&str>,
    ) -> ApiResult<()> {
        self.execute(
            "UPDATE commands SET status=?1, result_json=?2, error_text=?3, updated_at=?4 WHERE id=?5",
            params![
                enum_text(status),
                result.map(Value::to_string),
                error,
                now_ms(),
                command_id
            ],
        )?;
        Ok(())
    }

    fn mark_dispatched_unknown(&self, session_id: &str, reason: &str) -> ApiResult<usize> {
        Ok(self.execute(
            "UPDATE commands SET status='outcome_unknown', error_text=?1, updated_at=?2 \
             WHERE session_id=?3 AND status='dispatched'",
            params![reason, now_ms(), session_id],
        )?)
    }

    fn create_interaction(
        &self,
        session_id: &str,
        epoch: i64,
        rpc_id: &str,
        kind: &str,
        request: &Map<String, Value>,
        expires_at: i64,
    ) -> ApiResult<InteractionRow> {
        let interaction_id = prefix_uuid("interaction");
        self.execute(
            "INSERT INTO interactions (id,rpc_id,session_id,runner_epoch,kind,status,request_json,\
             expires_at,created_at) VALUES (?1,?2,?3,?4,?5,'pending',?6,?7,?8)",
            params![
                interaction_id,
                rpc_id,
                session_id,
                epoch,
                kind,
                Value::Object(request.clone()).to_string(),
                expires_at,
                now_ms()
            ],
        )?;
        self.get_interaction(&interaction_id)
    }

    fn get_interaction(&self, interaction_id: &str) -> ApiResult<InteractionRow> {
        self.query_row(
            &format!("SELECT {INTERACTION_COLUMNS} FROM interactions WHERE id=?1"),
            [interaction_id],
            interaction_row,
        )
        .optional()?
        .ok_or_else(|| ApiError::not_found("Interaction not found"))
    }

    fn pending_interactions(&self, session_id: &str) -> ApiResult<Vec<InteractionRow>> {
        let mut statement = self.prepare(&format!(
            "SELECT {INTERACTION_COLUMNS} FROM interactions WHERE session_id=?1 AND \
             status='pending' AND expires_at>?2 ORDER BY created_at, rowid"
        ))?;
        let rows = statement.query_map(params![session_id, now_ms()], interaction_row)?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    fn claim_interaction(
        &self,
        interaction_id: &str,
        session_id: &str,
        epoch: i64,
        answer: &Value,
    ) -> ApiResult<InteractionRow> {
        atomic(self, |db| {
            crate::execution_fences::require_open(db, session_id)?;
            let interaction = db.get_interaction(interaction_id)?;
            if interaction.session_id != session_id
                || interaction.runner_epoch != epoch
                || interaction.status != InteractionStatus::Pending
                || interaction.expires_at <= now_ms()
            {
                return Err(stale_interaction("Interaction is no longer answerable"));
            }
            let changed = db.execute(
                "UPDATE interactions SET status='answered', answer_json=?1, answered_at=?2 \
                 WHERE id=?3 AND status='pending' AND runner_epoch=?4",
                params![answer.to_string(), now_ms(), interaction_id, epoch],
            )?;
            if changed != 1 {
                return Err(stale_interaction("Interaction was already answered"));
            }
            Ok(interaction)
        })
    }

    fn cancel_interaction_by_rpc_id(
        &self,
        session_id: &str,
        epoch: i64,
        rpc_id: &str,
    ) -> ApiResult<Option<String>> {
        let found: Option<String> = self
            .query_row(
                "SELECT id FROM interactions WHERE session_id=?1 AND runner_epoch=?2 AND \
                 rpc_id=?3 AND status='pending'",
                params![session_id, epoch, rpc_id],
                |row| row.get(0),
            )
            .optional()?;
        if let Some(id) = &found {
            self.execute(
                "UPDATE interactions SET status='cancelled' WHERE id=?1",
                [id],
            )?;
        }
        Ok(found)
    }

    fn stale_epoch_interactions(&self, session_id: &str, epoch: i64) -> ApiResult<()> {
        self.execute(
            "UPDATE interactions SET status='stale' WHERE session_id=?1 AND status='pending' \
             AND runner_epoch!=?2",
            params![session_id, epoch],
        )?;
        Ok(())
    }

    fn get_lease(&self, session_id: &str) -> ApiResult<Option<LeaseView>> {
        let now = now_ms();
        Ok(self
            .query_row(
                "SELECT client_id, generation, expires_at FROM leases WHERE session_id=?1",
                [session_id],
                |row| {
                    let expires_at: i64 = row.get(2)?;
                    Ok(LeaseView {
                        client_id: row.get(0)?,
                        generation: row.get(1)?,
                        expires_at,
                        expired: expires_at <= now,
                    })
                },
            )
            .optional()?)
    }

    fn acquire_lease(
        &self,
        session_id: &str,
        client_id: &str,
        force: bool,
        ttl_ms: u64,
    ) -> ApiResult<Lease> {
        self.get_session(session_id)?;
        atomic(self, |db| {
            let current = db
                .query_row(
                    "SELECT client_id, generation, expires_at FROM leases WHERE session_id=?1",
                    [session_id],
                    |row| {
                        Ok((
                            row.get::<_, String>(0)?,
                            row.get::<_, i64>(1)?,
                            row.get::<_, i64>(2)?,
                        ))
                    },
                )
                .optional()?;
            if let Some((holder, _, expires_at)) = &current
                && *expires_at > now_ms()
                && holder != client_id
                && !force
            {
                return Err(ApiError::new(
                    409,
                    "lost_control",
                    "Another client holds control",
                ));
            }
            let generation = current.map_or(0, |(_, generation, _)| generation) + 1;
            let expires_at = now_ms() + ttl_ms as i64;
            db.execute(
                "INSERT INTO leases (session_id,client_id,generation,expires_at,updated_at) \
                 VALUES (?1,?2,?3,?4,?5) ON CONFLICT(session_id) DO UPDATE SET \
                 client_id=excluded.client_id, generation=excluded.generation, \
                 expires_at=excluded.expires_at, updated_at=excluded.updated_at",
                params![session_id, client_id, generation, expires_at, now_ms()],
            )?;
            Ok(Lease {
                client_id: client_id.to_owned(),
                generation,
                expires_at,
            })
        })
    }

    fn validate_lease(&self, session_id: &str, client_id: &str, generation: i64) -> ApiResult<()> {
        let lease = self
            .query_row(
                "SELECT client_id, generation, expires_at FROM leases WHERE session_id=?1",
                [session_id],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, i64>(1)?,
                        row.get::<_, i64>(2)?,
                    ))
                },
            )
            .optional()?;
        match lease {
            Some((holder, current, expires_at))
                if holder == client_id && current == generation && expires_at > now_ms() =>
            {
                Ok(())
            }
            _ => Err(lost_lease()),
        }
    }

    fn heartbeat_lease(
        &self,
        session_id: &str,
        client_id: &str,
        generation: i64,
        ttl_ms: u64,
    ) -> ApiResult<Lease> {
        self.validate_lease(session_id, client_id, generation)?;
        let expires_at = now_ms() + ttl_ms as i64;
        self.execute(
            "UPDATE leases SET expires_at=?1, updated_at=?2 WHERE session_id=?3 AND client_id=?4 \
             AND generation=?5",
            params![expires_at, now_ms(), session_id, client_id, generation],
        )?;
        Ok(Lease {
            client_id: client_id.to_owned(),
            generation,
            expires_at,
        })
    }

    fn release_lease(&self, session_id: &str, client_id: &str, generation: i64) -> ApiResult<()> {
        self.validate_lease(session_id, client_id, generation)?;
        self.execute(
            "DELETE FROM leases WHERE session_id=?1 AND client_id=?2 AND generation=?3",
            params![session_id, client_id, generation],
        )?;
        Ok(())
    }

    fn create_upload(&self, upload: &UploadRow) -> ApiResult<()> {
        self.execute(
            "INSERT INTO uploads (id,owner_user,mime_type,byte_size,storage_name,sha256,created_at,\
             kind,filename,workspace_id,session_id) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)",
            params![
                upload.id,
                upload.owner_user,
                upload.mime_type,
                upload.byte_size,
                upload.storage_name,
                upload.sha256,
                now_ms(),
                enum_text(upload.kind),
                upload.filename,
                upload.workspace_id,
                upload.session_id
            ],
        )?;
        Ok(())
    }

    fn get_upload(&self, upload_id: &str) -> ApiResult<UploadRow> {
        self.query_row(
            &format!("SELECT {UPLOAD_COLUMNS} FROM uploads WHERE id=?1"),
            [upload_id],
            upload_row,
        )
        .optional()?
        .ok_or_else(|| ApiError::not_found("Upload not found"))
    }
}

#[cfg(test)]
mod tests;
