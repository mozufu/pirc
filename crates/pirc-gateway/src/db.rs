//! The gateway's SQLite database (`apps/gateway/src/database.ts`): a fresh
//! schema (`schema.sql`) and the queries over sessions, workspaces,
//! commands, leases and capabilities. Feature modules (devices, memory,
//! schedules, ...) keep their own queries next to their logic.
//!
//! Queries are methods of [`Store`], implemented for [`Connection`], so a
//! transaction (which dereferences to a connection) can combine several.

use std::path::Path;
use std::sync::{Mutex, MutexGuard};
use std::time::{Duration, Instant};

use rusqlite::{Connection, OptionalExtension, Row, params};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::error::{ApiError, ApiResult};
use crate::util::{new_id, now_ms, safe_json};

/// Store a closed set of words (`as_str`/`parse`) in a TEXT column.
macro_rules! sql_text_enum {
    ($type:ty) => {
        impl ::rusqlite::types::FromSql for $type {
            fn column_result(
                value: ::rusqlite::types::ValueRef<'_>,
            ) -> ::rusqlite::types::FromSqlResult<Self> {
                <$type>::parse(value.as_str()?).ok_or(::rusqlite::types::FromSqlError::InvalidType)
            }
        }

        impl ::rusqlite::types::ToSql for $type {
            fn to_sql(&self) -> ::rusqlite::Result<::rusqlite::types::ToSqlOutput<'_>> {
                Ok(::rusqlite::types::ToSqlOutput::from(self.as_str()))
            }
        }
    };
}
pub(crate) use sql_text_enum;

/// `PRAGMA user_version` of the Rust schema. The TS gateway's migrations
/// numbered 1 to 19; the Rust line starts far above them, at
/// [`FIRST_SCHEMA_VERSION`], so a TS-era database is recognized and refused
/// rather than misread.
pub const SCHEMA_VERSION: i64 = 1027;
/// The first Rust schema; later ones are reached through [`MIGRATIONS`].
const FIRST_SCHEMA_VERSION: i64 = 1000;
const SCHEMA: &str = concat!(
    include_str!("schema.sql"),
    include_str!("calendar/schema.sql"),
    include_str!("pots/schema.sql"),
    include_str!("conversation_submissions/schema.sql"),
    include_str!("conversation_submissions/attachments.sql"),
    include_str!("conversation_submissions/acceptance.sql"),
    include_str!("conversation_submissions/dispatch.sql"),
    include_str!("conversation_submissions/cancellation.sql"),
    include_str!("conversation_submissions/pre_stop.sql"),
    include_str!("conversation_submissions/retries.sql"),
    include_str!("conversation_submissions/retry_retirements.sql"),
    include_str!("conversation_bindings/schema.sql"),
    include_str!("conversation_bindings/policies.sql"),
    include_str!("memory/provenance.sql"),
    include_str!("memory/project_cleanup.sql"),
    include_str!("conversation_bindings/commands.sql"),
    include_str!("conversation_bindings/transitions.sql"),
    include_str!("conversation_bindings/transitions/receipts.sql")
);
/// Each migration takes a database from the version before it to its own;
/// [`SCHEMA`] assembles the newest whole schema, including calendar tables.
const MIGRATIONS: &[(i64, &str)] = &[
    (
        // Repository identity by normalized `origin` (docs/architecture/assistant-memory.md).
        1001,
        "ALTER TABLE workspaces ADD COLUMN repo TEXT;
         ALTER TABLE memory_records ADD COLUMN repo TEXT;",
    ),
    (
        // Projects linked to workspaces (docs/architecture/assistant-memory.md).
        1002,
        "CREATE TABLE project_links (
           project_workspace_id TEXT NOT NULL REFERENCES workspaces(id), workspace_id TEXT NOT NULL,
           repo TEXT, created_at INTEGER NOT NULL,
           PRIMARY KEY (project_workspace_id, workspace_id)
         );",
    ),
    (
        // Agents' schedule deletions wait for the user (security audit L10);
        1003,
        "ALTER TABLE schedule_proposals ADD COLUMN operation TEXT NOT NULL DEFAULT 'save';
         -- The delegation checkbox for auto mode, and retention (docs/architecture/assistant-memory.md).
         ALTER TABLE delegations ADD COLUMN as_user_request INTEGER NOT NULL DEFAULT 0;
         CREATE INDEX delegations_follows ON delegations(follows);",
    ),
    (
        // Project deletion (docs/guides/chat-projects.md): its fence, and
        // tombstones scoped to the deleted project.
        1004,
        "ALTER TABLE session_deletions ADD COLUMN workspace_id TEXT;
         CREATE TABLE workspace_deletions (
           workspace_id TEXT PRIMARY KEY, owner_user TEXT NOT NULL, status TEXT NOT NULL, created_at INTEGER NOT NULL
         );
         CREATE TABLE memory_tombstones_scoped (
           owner_user TEXT NOT NULL, scope_id TEXT NOT NULL DEFAULT 'global', content_hash TEXT NOT NULL,
           forgotten_at INTEGER NOT NULL,
           PRIMARY KEY (owner_user, scope_id, content_hash)
         );
         INSERT INTO memory_tombstones_scoped (owner_user, scope_id, content_hash, forgotten_at)
           SELECT owner_user, 'global', content_hash, forgotten_at FROM memory_tombstones;
         DROP TABLE memory_tombstones;
         ALTER TABLE memory_tombstones_scoped RENAME TO memory_tombstones;",
    ),
    (
        // Delegation without the approval card (docs/guides/chat-projects.md):
        // how each started, and what its dispatch rested on.
        1005,
        "ALTER TABLE delegations ADD COLUMN dispatch TEXT;
         ALTER TABLE delegations ADD COLUMN origins_json TEXT;
         ALTER TABLE delegations ADD COLUMN quote TEXT;
         ALTER TABLE delegations ADD COLUMN quote_entry_ids TEXT;
         UPDATE delegations SET dispatch='approved' WHERE dispatched_at IS NOT NULL OR status IN ('running','waiting_input','completed','failed');",
    ),
    (1006, "ALTER TABLE memory_mirrors ADD COLUMN digest TEXT;"),
    (1007, include_str!("calendar/schema.sql")),
    (
        // Private node-owned checkpoint continuation workspaces.
        1008,
        "CREATE TABLE IF NOT EXISTS checkpoint_workspace_owners (
           workspace_id TEXT PRIMARY KEY REFERENCES workspaces(id) ON DELETE CASCADE,
           owner_user TEXT
         );",
    ),
    (1009, "CREATE TABLE workspace_removals (workspace_id TEXT PRIMARY KEY REFERENCES workspaces(id) ON DELETE CASCADE, owner_user TEXT NOT NULL, removed_at INTEGER NOT NULL, status TEXT NOT NULL DEFAULT 'removed' CHECK(status IN ('checking','removed')), token TEXT NOT NULL DEFAULT '');"),
    (1010, include_str!("pots/schema.sql")),
    // Execution statuses/accepted instructions are not readable by old Gateways.
    // No SQL shape changes; the version fence prevents unsafe downgrade.
    (1011, "SELECT 1;"),
    (1012, include_str!("conversation_submissions/schema.sql")),
    (1013, include_str!("conversation_submissions/attachments.sql")),
    (1014, include_str!("conversation_submissions/acceptance.sql")),
    (1015, include_str!("conversation_submissions/dispatch.sql")),
    (1016, include_str!("conversation_submissions/cancellation.sql")),
    (1017, include_str!("conversation_submissions/pre_stop.sql")),
    // Semantic fence: older Gateways must not execute first Send without the new client contract.
    (1018, "SELECT 1;"),
    (1019, include_str!("conversation_submissions/retries.sql")),
    (1020, include_str!("conversation_submissions/retry_retirements.sql")),
    (1021, include_str!("conversation_bindings/schema.sql")),
    (1022, include_str!("conversation_bindings/policies.sql")),
    (1023, include_str!("memory/provenance.sql")),
    (1024, include_str!("memory/project_cleanup.sql")),
    (1025, include_str!("conversation_bindings/commands.sql")),
    (1026, include_str!("conversation_bindings/transitions.sql")),
    (1027, include_str!("conversation_bindings/transitions/receipts.sql")),
];

/// Placeholder name of a new session until the agent's title replaces it.
pub const PLACEHOLDER_SESSION_NAME: &str = "New session";

/// The open database. Never hold the lock across an `await`.
pub struct Db(Mutex<Connection>);

impl Db {
    /// Open (creating) the database at `path`, readable by the owner only.
    pub fn open(path: &Path) -> Result<Self, String> {
        let describe = |error: rusqlite::Error| format!("{}: {error}", path.display());
        let connection = Connection::open(path).map_err(describe)?;
        // Another process may hold the write lock (opening, migrating).
        connection
            .busy_timeout(SQLITE_BUSY_TIMEOUT)
            .map_err(describe)?;
        // Push keys, device-token hashes and memory live here. SQLite gives
        // the WAL and shm files the main file's mode, so this covers them.
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

    /// An in-memory database (tests).
    #[cfg(test)]
    pub fn memory() -> Self {
        let connection = Connection::open_in_memory().unwrap();
        connection
            .pragma_update(None, "foreign_keys", "ON")
            .unwrap();
        create_schema(&connection, Path::new(":memory:")).unwrap();
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
    if (1..FIRST_SCHEMA_VERSION).contains(&version) {
        return Err(typescript_era(path));
    }
    Ok(())
}

fn typescript_era(path: &Path) -> String {
    format!(
        "{} was written by the TypeScript gateway (pirc 0.3 or earlier). This gateway starts \
         from a fresh state directory: devices are paired again, sessions start anew. See the \
         upgrade notes (docs/deploy/upgrades.md), then move the old state directory away.",
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

/// Create the schema in a new database; refuse one from the TS gateway or a
/// newer Rust gateway. The version is read and acted on under one
/// `BEGIN IMMEDIATE` write lock, so two processes opening the same database
/// cannot both create or migrate it; any failure rolls the whole chain back.
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
    if version == SCHEMA_VERSION {
        return Ok(());
    }
    if (1..FIRST_SCHEMA_VERSION).contains(&version) {
        return Err(typescript_era(path));
    }
    if (FIRST_SCHEMA_VERSION..SCHEMA_VERSION).contains(&version) {
        return migrate(connection, version).map_err(describe);
    }
    if version > SCHEMA_VERSION {
        return Err(format!(
            "{} has schema version {version}, newer than this gateway's {SCHEMA_VERSION}",
            path.display()
        ));
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

/// Bring an older Rust schema up to date, inside [`create_schema`]'s
/// transaction.
fn migrate(connection: &Connection, from: i64) -> rusqlite::Result<()> {
    // Unpublished calendar/checkpoint builds used 1006/1007 before upstream
    // assigned 1006 to the memory digest. Preserve their data while joining
    // the upstream sequence, under create_schema's single write transaction.
    if (1006..=1007).contains(&from) {
        let digest: bool = connection.query_row(
            "SELECT EXISTS(SELECT 1 FROM pragma_table_info('memory_mirrors') WHERE name='digest')",
            [],
            |row| row.get(0),
        )?;
        if !digest {
            connection.execute_batch("ALTER TABLE memory_mirrors ADD COLUMN digest TEXT;")?;
        }
    }
    for (version, sql) in MIGRATIONS.iter().filter(|(version, _)| *version > from) {
        let calendar_exists: bool = connection.query_row(
            "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='calendar_events')",
            [], |row| row.get(0),
        )?;
        if *version != 1007 || !calendar_exists {
            connection.execute_batch(sql)?;
        }
        connection.pragma_update(None, "user_version", version)?;
    }
    Ok(())
}

/// Storage failures are logged and become a plain 500.
impl From<rusqlite::Error> for ApiError {
    fn from(error: rusqlite::Error) -> Self {
        crate::log::error(&format!("database: {error}"));
        ApiError::internal()
    }
}

pub use pirc_protocol::mode::ModeId;

/// A workspace as clients see it (its stored `canonical_path` is a
/// gateway-internal unique key and is not read).
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Workspace {
    pub id: String,
    pub host_id: String,
    pub display_name: String,
    pub defaults: Value,
    pub mode: ModeId,
    /// Its repository's normalized `origin`, as its node last reported it.
    #[serde(skip)]
    pub repo: Option<String>,
}

impl Workspace {
    pub(crate) fn from_row(row: &Row<'_>) -> rusqlite::Result<Self> {
        Ok(Self {
            id: row.get("id")?,
            host_id: row.get("host_id")?,
            display_name: row.get("display_name")?,
            defaults: safe_json(&row.get::<_, String>("defaults_json")?, json!({})),
            mode: ModeId::new(row.get::<_, String>("kind")?).map_err(|error| {
                rusqlite::Error::FromSqlConversionFailure(
                    0,
                    rusqlite::types::Type::Text,
                    std::io::Error::new(std::io::ErrorKind::InvalidData, error).into(),
                )
            })?,
            repo: row.get("repo")?,
        })
    }

    /// The node's own id of the workspace (`<nodeId>:<local>`), when it is a node's.
    pub fn local_id(&self) -> Option<&str> {
        self.id
            .strip_prefix(self.host_id.as_str())
            .and_then(|rest| rest.strip_prefix(':'))
    }
}

/// A session row. Serializing gives the public session (`publicSession`):
/// the node's session id and the owner never leave the gateway.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Session {
    pub id: String,
    pub binding: crate::conversation_bindings::Binding,
    pub workspace_id: String,
    pub node_id: Option<String>,
    pub name: String,
    /// `auto`: a placeholder or generated title that a new one may replace.
    pub name_source: String,
    pub runner_state: String,
    /// Finished runs are the nodes' business; the gateway never records one.
    pub run_status: Option<String>,
    pub runner_epoch: i64,
    pub pinned_at: Option<i64>,
    pub settled_at: Option<i64>,
    pub unread: bool,
    pub created_at: i64,
    pub updated_at: i64,
    #[serde(skip)]
    pub owner_user: Option<String>,
    #[serde(skip)]
    pub pi_session_id: Option<String>,
}

impl Session {
    fn from_row(row: &Row<'_>) -> rusqlite::Result<Self> {
        let activity: Option<i64> = row.get("activity_at")?;
        let read: Option<i64> = row.get("read_at")?;
        Ok(Self {
            id: row.get("id")?,
            workspace_id: row.get("workspace_id")?,
            binding: crate::conversation_bindings::Binding::from_row(row)?,
            node_id: row.get("node_id")?,
            owner_user: row.get("owner_user")?,
            name: row.get("name")?,
            name_source: if row.get::<_, String>("name_source")? == "auto" {
                "auto".into()
            } else {
                "user".into()
            },
            runner_state: row.get("runner_state")?,
            run_status: None,
            runner_epoch: row.get("runner_epoch")?,
            pinned_at: row.get("pinned_at")?,
            settled_at: row.get("settled_at")?,
            unread: activity.is_some_and(|activity| activity > read.unwrap_or(0)),
            created_at: row.get("created_at")?,
            updated_at: row.get("updated_at")?,
            pi_session_id: row.get("pi_session_id")?,
        })
    }

    /// The public session as JSON.
    pub fn public(&self) -> Value {
        serde_json::to_value(self).unwrap_or(Value::Null)
    }
}

/// A chat workspace's capability policy.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Capabilities {
    pub version: Version1,
    pub delegation: bool,
    pub memory_search: bool,
    pub remote_recall: bool,
    pub schedules: bool,
    pub web_search: bool,
    /// When a delegation of this chat workspace waits for the user's card.
    #[serde(default)]
    pub delegation_approval: DelegationApproval,
}

/// A chat workspace's delegation approval policy
/// (docs/guides/chat-projects.md#delegation).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum DelegationApproval {
    /// Every delegation waits for the user's card (the default, and what
    /// existing installs keep).
    #[default]
    Always,
    /// Starts at once unless the chat's context since the user's last
    /// message holds content from outside (tool output, reports).
    Untrusted,
    /// Always starts at once.
    Never,
}

/// The literal `1`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(try_from = "u8", into = "u8")]
pub struct Version1;

impl TryFrom<u8> for Version1 {
    type Error = &'static str;
    fn try_from(value: u8) -> Result<Self, Self::Error> {
        if value == 1 {
            Ok(Self)
        } else {
            Err("version must be 1")
        }
    }
}

impl From<Version1> for u8 {
    fn from(_: Version1) -> Self {
        1
    }
}

impl Default for Capabilities {
    fn default() -> Self {
        Self {
            version: Version1,
            delegation: true,
            memory_search: true,
            remote_recall: true,
            schedules: true,
            web_search: true,
            delegation_approval: DelegationApproval::Always,
        }
    }
}

/// Part of a policy to change (`workspaceCapabilitiesSchema.partial()`).
#[derive(Clone, Copy, Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CapabilitiesPatch {
    /// Accepted (it can only be 1) and otherwise ignored.
    #[serde(default, rename = "version", deserialize_with = "crate::util::present")]
    pub _version: Option<Version1>,
    #[serde(default, deserialize_with = "crate::util::present")]
    pub delegation: Option<bool>,
    #[serde(default, deserialize_with = "crate::util::present")]
    pub memory_search: Option<bool>,
    #[serde(default, deserialize_with = "crate::util::present")]
    pub remote_recall: Option<bool>,
    #[serde(default, deserialize_with = "crate::util::present")]
    pub schedules: Option<bool>,
    #[serde(default, deserialize_with = "crate::util::present")]
    pub web_search: Option<bool>,
    #[serde(default, deserialize_with = "crate::util::present")]
    pub delegation_approval: Option<DelegationApproval>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Capability {
    Delegation,
    MemorySearch,
    RemoteRecall,
    Schedules,
    WebSearch,
}

impl Capability {
    pub fn name(self) -> &'static str {
        match self {
            Self::Delegation => "delegation",
            Self::MemorySearch => "memory_search",
            Self::RemoteRecall => "remote_recall",
            Self::Schedules => "schedules",
            Self::WebSearch => "web_search",
        }
    }

    fn of(self, policy: &Capabilities) -> bool {
        match self {
            Self::Delegation => policy.delegation,
            Self::MemorySearch => policy.memory_search,
            Self::RemoteRecall => policy.remote_recall,
            Self::Schedules => policy.schedules,
            Self::WebSearch => policy.web_search,
        }
    }
}

/// A browser command, kept for idempotency.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Command {
    pub id: String,
    pub session_id: String,
    pub payload_hash: String,
    pub payload: Value,
    pub status: String,
    pub result: Value,
    pub error: Option<String>,
}

impl Command {
    fn from_row(row: &Row<'_>) -> rusqlite::Result<Self> {
        let result: Option<String> = row.get("result_json")?;
        Ok(Self {
            id: row.get("id")?,
            session_id: row.get("session_id")?,
            payload_hash: row.get("payload_hash")?,
            payload: safe_json(&row.get::<_, String>("payload_json")?, Value::Null),
            status: row.get("status")?,
            result: result.map_or(Value::Null, |result| safe_json(&result, Value::Null)),
            error: row.get("error_text")?,
        })
    }
}

/// What started a session other than the user.
#[derive(Clone, Debug, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum SessionOrigin {
    #[serde(rename_all = "camelCase")]
    Schedule {
        schedule_id: String,
        title: String,
        due_at: i64,
    },
    #[serde(rename_all = "camelCase")]
    Delegation {
        delegation_id: String,
        title: String,
        from_session_id: String,
        /// The delegation's status (`running`, `waiting_input`,
        /// `completed`, `failed`): delegated sessions are left as they are
        /// once their result is delivered, so the list says how they ended.
        status: String,
    },
}

/// A node's lease as it reports it.
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Lease {
    pub client_id: String,
    pub generation: i64,
    pub expires_at: i64,
}

/// Where a session's or project's deletion stands (`status` column).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DeletionStatus {
    /// Fenced; the node's cleanup may still be running or need a retry.
    Deleting,
    Deleted,
}

impl DeletionStatus {
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "deleting" => Some(Self::Deleting),
            "deleted" => Some(Self::Deleted),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Deleting => "deleting",
            Self::Deleted => "deleted",
        }
    }
}

sql_text_enum!(DeletionStatus);

/// A session or project being deleted: its owner and how far it got.
#[derive(Clone, Debug)]
pub struct Deletion {
    pub owner_user: String,
    pub status: DeletionStatus,
}

/// Run a mutation atomically. Reserve the writer before reading at the outer
/// boundary: upgrading a WAL read snapshot after another writer commits fails
/// immediately with SQLITE_BUSY_SNAPSHOT, regardless of the busy timeout.
/// Savepoints still nest inside a caller's transaction without committing it.
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
    let transaction = if connection.is_autocommit() {
        Some(rusqlite::Transaction::new_unchecked(
            connection,
            rusqlite::TransactionBehavior::Immediate,
        )?)
    } else {
        None
    };
    connection.execute_batch("SAVEPOINT atomic")?;
    let mut guard = Guard(connection, false);
    let value = body(connection)?;
    connection.execute_batch("RELEASE atomic")?;
    guard.1 = true;
    if let Some(transaction) = transaction {
        transaction.commit()?;
    }
    Ok(value)
}

fn session_not_found() -> ApiError {
    ApiError::not_found("Session not found")
}

/// The gateway's queries; see the module documentation.
pub trait Store {
    fn assistant_node(&self) -> ApiResult<Option<String>>;
    fn claim_assistant_node(&self, node_id: &str) -> ApiResult<bool>;
    fn release_assistant_node(&self, node_id: &str) -> ApiResult<bool>;
    fn recover_startup(&self) -> ApiResult<RecoveredStartup>;

    fn sync_remote_workspaces(
        &self,
        node_id: &str,
        workspaces: &[(String, String, ModeId)],
    ) -> ApiResult<()>;
    /// Record the repositories a node reported for its workspaces (local
    /// ids), and give their mirrored notes that had none the same.
    fn set_workspace_repos(
        &self,
        node_id: &str,
        repos: &[(String, Option<String>)],
    ) -> ApiResult<()>;
    /// A chat project being deleted (or deleted) is left out.
    fn list_workspaces(&self) -> ApiResult<Vec<Workspace>>;
    /// 404 "Workspace not found"; 409 while it is being deleted.
    fn get_workspace(&self, workspace_id: &str) -> ApiResult<Workspace>;
    /// The workspace even while it is being deleted (the deletion's own lookups).
    fn find_workspace(&self, workspace_id: &str) -> ApiResult<Option<Workspace>>;
    fn workspace_deletion(&self, workspace_id: &str) -> ApiResult<Option<Deletion>>;
    /// Fence the project and every session in it (403 if one is another
    /// user's). Idempotent.
    fn begin_workspace_deletion(&self, workspace_id: &str, user: &str) -> ApiResult<()>;
    /// Ids of the sessions in a workspace.
    fn workspace_session_ids(&self, workspace_id: &str) -> ApiResult<Vec<String>>;
    /// Chat projects being deleted (`deleting`), for their owner to finish.
    fn deleting_workspaces(&self) -> ApiResult<Vec<Workspace>>;
    /// Workspaces visible to this user, including only their own private
    /// checkpoint continuations. Unclaimed checkpoint workspaces stay hidden.
    fn list_workspaces_for_user(&self, user: &str) -> ApiResult<Vec<Workspace>>;
    /// Checkpoint workspaces are imported before their continuation response
    /// can be mapped; an absent owner therefore means private and unavailable.
    fn mark_checkpoint_workspace_private(&self, workspace_id: &str) -> ApiResult<()>;
    /// Bind a private checkpoint workspace to the user whose continuation
    /// response explicitly returned it. A different owner cannot take it over.
    fn claim_checkpoint_workspace(&self, workspace_id: &str, user: &str) -> ApiResult<()>;
    /// Whether a workspace is public or belongs to `user`.
    fn checkpoint_workspace_visible_to_user(
        &self,
        workspace_id: &str,
        user: &str,
    ) -> ApiResult<bool>;
    fn get_workspace_capabilities(&self, workspace_id: &str) -> ApiResult<Capabilities>;
    fn patch_workspace_capabilities(
        &self,
        workspace_id: &str,
        patch: &CapabilitiesPatch,
    ) -> ApiResult<Capabilities>;
    fn require_workspace_capability(
        &self,
        workspace_id: &str,
        capability: Capability,
    ) -> ApiResult<()>;
    fn require_session_capability(&self, session_id: &str, capability: Capability)
    -> ApiResult<()>;

    fn create_session(
        &self,
        workspace_id: &str,
        private_session_path: &str,
        node_id: &str,
        remote_session_id: &str,
        owner_user: &str,
    ) -> ApiResult<Session>;
    /// Idempotently map a node-owned recovery continuation into the gateway.
    fn create_checkpoint_session(
        &self,
        workspace_id: &str,
        private_session_path: &str,
        node_id: &str,
        remote_session_id: &str,
        owner_user: &str,
    ) -> ApiResult<Session>;
    fn list_sessions(&self) -> ApiResult<Vec<Session>>;
    fn get_session(&self, session_id: &str) -> ApiResult<Session>;
    fn rename_session(&self, session_id: &str, name: &str) -> ApiResult<Session>;
    fn set_session_flags(
        &self,
        session_id: &str,
        pinned: Option<bool>,
        settled: Option<bool>,
    ) -> ApiResult<Session>;
    fn mark_session_activity(&self, session_id: &str) -> ApiResult<()>;
    fn mark_session_read(&self, session_id: &str) -> ApiResult<bool>;
    fn auto_rename_session(&self, session_id: &str, name: &str) -> ApiResult<bool>;
    fn claim_session(&self, session_id: &str, user: &str, deleting: bool) -> ApiResult<Session>;
    fn session_origins(&self, owner_user: &str) -> ApiResult<Vec<(String, SessionOrigin)>>;
    fn session_deletion(&self, session_id: &str) -> ApiResult<Option<Deletion>>;
    fn require_session_available(&self, session_id: &str) -> ApiResult<()>;
    fn begin_session_deletion(&self, session_id: &str, user: &str) -> ApiResult<()>;
    fn finish_session_deletion(&self, session_id: &str) -> ApiResult<()>;
    fn resolve_remote_session(&self, node_id: &str, remote_id: &str) -> ApiResult<Option<String>>;
    fn interrupt_remote_session(&self, session_id: &str) -> ApiResult<()>;
    fn remote_session_ids(&self, node_id: &str) -> ApiResult<Vec<String>>;
    fn set_runner_state(&self, session_id: &str, state: &str) -> ApiResult<()>;
    fn increment_epoch(&self, session_id: &str) -> ApiResult<i64>;

    fn receive_command(
        &self,
        command_id: &str,
        session_id: &str,
        hash: &str,
        payload: &Value,
    ) -> ApiResult<(Command, bool)>;
    fn get_command(&self, command_id: &str) -> ApiResult<Command>;
    fn update_command(
        &self,
        command_id: &str,
        status: &str,
        result: Option<&Value>,
        error: Option<&str>,
    ) -> ApiResult<()>;

    fn check_lease_user(&self, session_id: &str, user: &str, force: bool) -> ApiResult<()>;
    fn mirror_lease(
        &self,
        session_id: &str,
        lease: &Lease,
        user: &str,
        force: bool,
    ) -> ApiResult<()>;
    fn clear_remote_lease(&self, session_id: &str) -> ApiResult<()>;
    fn validate_lease_user(&self, session_id: &str, user: &str) -> ApiResult<()>;
    fn get_lease(&self, session_id: &str) -> ApiResult<Value>;
    fn validate_lease(&self, session_id: &str, client_id: &str, generation: i64) -> ApiResult<()>;
}

fn finish_deletion(conn: &Connection, session_id: &str) -> ApiResult<()> {
    if conn.session_deletion(session_id)?.is_none() {
        crate::log::error("session deletion must be fenced first");
        return Err(ApiError::internal());
    }
    for table in ["commands", "leases"] {
        conn.execute(
            &format!("DELETE FROM {table} WHERE session_id=?"),
            [session_id],
        )?;
    }
    // Deletion fences the final node events, so the scheduler cannot rely
    // on an agent-stop event to settle a run. Keep its audit record and
    // the schedule, but release the open-run guard and the dead link.
    conn.execute(
        "UPDATE schedule_runs SET status='failed', result='The chat was deleted.', finished_at=? WHERE session_id=? AND status IN ('running','waiting_input')",
        params![now_ms(), session_id],
    )?;
    conn.execute(
        "UPDATE schedule_runs SET session_id=NULL WHERE session_id=?",
        [session_id],
    )?;
    conn.execute(
        "DELETE FROM schedule_proposals WHERE session_id=?",
        [session_id],
    )?;
    conn.execute(
        "DELETE FROM calendar_proposals WHERE session_id=?",
        [session_id],
    )?;
    conn.execute(
        "DELETE FROM delegations WHERE assistant_session_id=?",
        [session_id],
    )?;
    conn.execute("DELETE FROM sessions WHERE id=?", [session_id])?;
    conn.execute(
        "UPDATE session_deletions SET status='deleted' WHERE session_id=?",
        [session_id],
    )?;
    Ok(())
}

/// What startup recovery found (logged).
#[derive(Clone, Copy, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RecoveredStartup {
    pub unknown_commands: usize,
}

const SESSION_SELECT: &str = "SELECT sessions.*, b.membership_revision, b.legacy_workspace_id,
 b.generation AS binding_generation, b.execution_workspace_id, b.node_id AS binding_node_id,
 b.mode_id AS binding_mode_id FROM sessions
 JOIN conversation_bindings b ON b.session_id=sessions.id";

impl Store for Connection {
    fn assistant_node(&self) -> ApiResult<Option<String>> {
        Ok(self
            .query_row(
                "SELECT node_id FROM assistant_node WHERE singleton = 1",
                [],
                |row| row.get(0),
            )
            .optional()?)
    }

    fn claim_assistant_node(&self, node_id: &str) -> ApiResult<bool> {
        self.execute(
            "INSERT OR IGNORE INTO assistant_node(singleton, node_id) VALUES (1, ?)",
            [node_id],
        )?;
        Ok(self.assistant_node()?.as_deref() == Some(node_id))
    }

    fn release_assistant_node(&self, node_id: &str) -> ApiResult<bool> {
        Ok(self.execute(
            "DELETE FROM assistant_node WHERE singleton = 1 AND node_id = ?",
            [node_id],
        )? > 0)
    }

    /// Commands in flight when the gateway stopped have an unknown outcome;
    /// runners and leases belong to nodes that reconnect.
    fn recover_startup(&self) -> ApiResult<RecoveredStartup> {
        let stamp = now_ms();
        atomic(self, |tx| {
            let unknown_commands = tx.execute(
            "UPDATE commands SET status='outcome_unknown', error_text='gateway restarted before RPC acceptance was recorded', updated_at=? WHERE status='dispatched'",
            [stamp],
        )?;
            tx.execute(
            "UPDATE sessions SET runner_state='stopped', partial_output_lost=1, updated_at=? WHERE runner_state!='stopped'",
            [stamp],
        )?;
            tx.execute("DELETE FROM leases", [])?;
            // Removal probes have no node-side effects. An interrupted probe
            // must be retried, not leave a permanent checking fence.
            tx.execute("DELETE FROM workspace_removals WHERE status='checking'", [])?;
            Ok(RecoveredStartup { unknown_commands })
        })
    }

    fn sync_remote_workspaces(
        &self,
        node_id: &str,
        workspaces: &[(String, String, ModeId)],
    ) -> ApiResult<()> {
        atomic(self, |tx| {
            // A deleted project announced again (an old process, a restored
            // backup) stays deleted.
            let mut insert = tx.prepare(
                "INSERT INTO workspaces (id,host_id,display_name,canonical_path,defaults_json,created_at,kind) SELECT ?1,?2,?3,?4,?5,?6,?7 WHERE NOT EXISTS (SELECT 1 FROM workspace_deletions WHERE workspace_id=?1) ON CONFLICT(id) DO UPDATE SET display_name=excluded.display_name, kind=excluded.kind",
            )?;
            for (id, display_name, kind) in workspaces {
                insert.execute(params![
                    format!("{node_id}:{id}"),
                    node_id,
                    display_name,
                    format!("node://{node_id}/{id}"),
                    "{}",
                    now_ms(),
                    kind.as_str(),
                ])?;
            }
            Ok(())
        })
    }

    fn set_workspace_repos(
        &self,
        node_id: &str,
        repos: &[(String, Option<String>)],
    ) -> ApiResult<()> {
        atomic(self, |tx| {
            for (id, repo) in repos {
                let id = format!("{node_id}:{id}");
                let repo = repo
                    .as_deref()
                    .filter(|repo| pirc_protocol::valid_repo(repo));
                let changed =
                    tx.execute("UPDATE workspaces SET repo=? WHERE id=?", params![repo, id])?;
                // Only a directory workspace has a repository: a key reported for a chat
                // workspace must not tag its notes or links either.
                if changed == 0 {
                    continue;
                }
                if let Some(repo) = repo {
                    tx.execute(
                        "UPDATE memory_records SET repo=? WHERE workspace_id=? AND repo IS NULL AND status!='forgotten'",
                        params![repo, id],
                    )?;
                    // Links made before the repository was known cover its clones from now on.
                    tx.execute(
                        "UPDATE project_links SET repo=? WHERE workspace_id=? AND repo IS NULL",
                        params![repo, id],
                    )?;
                }
            }
            Ok(())
        })
    }

    fn list_workspaces(&self) -> ApiResult<Vec<Workspace>> {
        let mut statement = self.prepare(
            "SELECT * FROM workspaces WHERE id NOT IN (SELECT workspace_id FROM workspace_deletions) AND id NOT IN (SELECT workspace_id FROM workspace_removals WHERE status='removed') AND id NOT IN (SELECT workspace_id FROM checkpoint_workspace_owners) ORDER BY display_name",
        )?;
        let rows = statement.query_map([], Workspace::from_row)?;
        Ok(rows.collect::<Result<_, _>>()?)
    }

    fn list_workspaces_for_user(&self, user: &str) -> ApiResult<Vec<Workspace>> {
        let mut statement = self.prepare(
            "SELECT w.* FROM workspaces w
             WHERE w.id NOT IN (SELECT workspace_id FROM workspace_deletions)
               AND w.id NOT IN (SELECT workspace_id FROM workspace_removals WHERE status='removed')
               AND NOT EXISTS (
                 SELECT 1 FROM checkpoint_workspace_owners c
                 WHERE c.workspace_id=w.id AND (c.owner_user IS NULL OR c.owner_user!=?)
               )
             ORDER BY w.display_name",
        )?;
        let rows = statement.query_map([user], Workspace::from_row)?;
        Ok(rows.collect::<Result<_, _>>()?)
    }

    fn mark_checkpoint_workspace_private(&self, workspace_id: &str) -> ApiResult<()> {
        self.execute(
            "INSERT OR IGNORE INTO checkpoint_workspace_owners (workspace_id,owner_user) VALUES (?,NULL)",
            [workspace_id],
        )?;
        Ok(())
    }

    fn claim_checkpoint_workspace(&self, workspace_id: &str, user: &str) -> ApiResult<()> {
        self.get_workspace(workspace_id)?;
        let owner: Option<Option<String>> = self
            .query_row(
                "SELECT owner_user FROM checkpoint_workspace_owners WHERE workspace_id=?",
                [workspace_id],
                |row| row.get(0),
            )
            .optional()?;
        match owner {
            Some(Some(owner)) if owner != user => Err(ApiError::not_found("Workspace not found")),
            Some(Some(_)) => Ok(()),
            Some(None) => {
                self.execute(
                    "UPDATE checkpoint_workspace_owners SET owner_user=? WHERE workspace_id=? AND owner_user IS NULL",
                    params![user, workspace_id],
                )?;
                let owner: Option<String> = self.query_row(
                    "SELECT owner_user FROM checkpoint_workspace_owners WHERE workspace_id=?",
                    [workspace_id],
                    |row| row.get(0),
                )?;
                if owner.as_deref() == Some(user) {
                    Ok(())
                } else {
                    Err(ApiError::not_found("Workspace not found"))
                }
            }
            None => {
                self.execute(
                    "INSERT INTO checkpoint_workspace_owners (workspace_id,owner_user) VALUES (?,?)",
                    params![workspace_id, user],
                )?;
                Ok(())
            }
        }
    }

    fn checkpoint_workspace_visible_to_user(
        &self,
        workspace_id: &str,
        user: &str,
    ) -> ApiResult<bool> {
        let owner: Option<Option<String>> = self
            .query_row(
                "SELECT owner_user FROM checkpoint_workspace_owners WHERE workspace_id=?",
                [workspace_id],
                |row| row.get(0),
            )
            .optional()?;
        Ok(match owner {
            None => true,
            Some(Some(owner)) => owner == user,
            Some(None) => false,
        })
    }

    fn get_workspace(&self, workspace_id: &str) -> ApiResult<Workspace> {
        if crate::workspace_removal::removed(self, workspace_id)? {
            return Err(ApiError::not_found("Workspace not found"));
        }
        let workspace = self
            .find_workspace(workspace_id)?
            .ok_or_else(|| ApiError::not_found("Workspace not found"))?;
        if self.workspace_deletion(workspace_id)?.is_some() {
            return Err(ApiError::new(
                409,
                "conflict",
                "This project is being deleted. Retry Delete to finish cleanup.",
            ));
        }
        Ok(workspace)
    }

    fn find_workspace(&self, workspace_id: &str) -> ApiResult<Option<Workspace>> {
        Ok(self
            .query_row(
                "SELECT * FROM workspaces WHERE id=?",
                [workspace_id],
                Workspace::from_row,
            )
            .optional()?)
    }

    fn workspace_deletion(&self, workspace_id: &str) -> ApiResult<Option<Deletion>> {
        Ok(self
            .query_row(
                "SELECT owner_user, status FROM workspace_deletions WHERE workspace_id=?",
                [workspace_id],
                |row| {
                    Ok(Deletion {
                        owner_user: row.get(0)?,
                        status: row.get(1)?,
                    })
                },
            )
            .optional()?)
    }

    fn begin_workspace_deletion(&self, workspace_id: &str, user: &str) -> ApiResult<()> {
        atomic(self, |tx| {
            if tx.find_workspace(workspace_id)?.is_none() {
                return Err(ApiError::not_found("Workspace not found"));
            }
            let other_preparations: bool = tx.query_row(
                "SELECT EXISTS(SELECT 1 FROM conversation_submissions WHERE workspace_id=?1 AND owner_user!=?2 AND state='preparing')",
                params![workspace_id,user], |r| r.get(0),
            )?;
            if other_preparations {
                return Err(ApiError::new(
                    403,
                    "forbidden",
                    "The project has another user's pending conversations",
                ));
            }
            let sessions = tx.workspace_session_ids(workspace_id)?;
            for session_id in &sessions {
                if tx.get_session(session_id)?.owner_user.as_deref() != Some(user) {
                    return Err(ApiError::new(
                        403,
                        "forbidden",
                        "The project has another user's chats",
                    ));
                }
            }
            tx.execute(
                "INSERT OR IGNORE INTO workspace_deletions VALUES (?, ?, 'deleting', ?)",
                params![workspace_id, user, now_ms()],
            )?;
            for session_id in &sessions {
                tx.begin_session_deletion(session_id, user)?;
            }
            Ok(())
        })
    }

    fn workspace_session_ids(&self, workspace_id: &str) -> ApiResult<Vec<String>> {
        let mut statement =
            self.prepare("SELECT id FROM sessions WHERE workspace_id=? ORDER BY created_at, id")?;
        let rows = statement.query_map([workspace_id], |row| row.get(0))?;
        Ok(rows.collect::<Result<_, _>>()?)
    }

    fn deleting_workspaces(&self) -> ApiResult<Vec<Workspace>> {
        let mut statement = self.prepare(
            "SELECT w.* FROM workspaces w JOIN workspace_deletions d ON d.workspace_id=w.id WHERE d.status='deleting' ORDER BY w.display_name",
        )?;
        let rows = statement.query_map([], Workspace::from_row)?;
        Ok(rows.collect::<Result<_, _>>()?)
    }

    /// Gateway-owned policy: node workspace sync never overwrites it.
    fn get_workspace_capabilities(&self, workspace_id: &str) -> ApiResult<Capabilities> {
        self.get_workspace(workspace_id)?;
        let stored: Option<String> = self
            .query_row(
                "SELECT policy_json FROM workspace_capabilities WHERE workspace_id=?",
                [workspace_id],
                |row| row.get(0),
            )
            .optional()?;
        match stored {
            None => Ok(Capabilities::default()),
            Some(json) => serde_json::from_str(&json).map_err(|error| {
                crate::log::error(&format!("capabilities of {workspace_id}: {error}"));
                ApiError::internal()
            }),
        }
    }

    fn patch_workspace_capabilities(
        &self,
        workspace_id: &str,
        patch: &CapabilitiesPatch,
    ) -> ApiResult<Capabilities> {
        atomic(self, |tx| {
            tx.get_workspace(workspace_id)?;
            let mut policy = tx.get_workspace_capabilities(workspace_id)?;
            let set = |field: &mut bool, value: Option<bool>| {
                if let Some(value) = value {
                    *field = value;
                }
            };
            set(&mut policy.delegation, patch.delegation);
            set(&mut policy.memory_search, patch.memory_search);
            set(&mut policy.remote_recall, patch.remote_recall);
            set(&mut policy.schedules, patch.schedules);
            set(&mut policy.web_search, patch.web_search);
            if let Some(approval) = patch.delegation_approval {
                policy.delegation_approval = approval;
            }
            tx.execute(
            "INSERT INTO workspace_capabilities (workspace_id,policy_json) VALUES (?,?) ON CONFLICT(workspace_id) DO UPDATE SET policy_json=excluded.policy_json",
            params![workspace_id, json!(policy).to_string()],
        )?;
            Ok(policy)
        })
    }

    fn require_workspace_capability(
        &self,
        workspace_id: &str,
        capability: Capability,
    ) -> ApiResult<()> {
        if capability.of(&self.get_workspace_capabilities(workspace_id)?) {
            return Ok(());
        }
        Err(ApiError::new(
            403,
            "capability_disabled",
            format!(
                "Capability {} is disabled for this chat workspace. Ask the user to enable it in workspace settings.",
                capability.name()
            ),
        ))
    }

    fn require_session_capability(
        &self,
        session_id: &str,
        capability: Capability,
    ) -> ApiResult<()> {
        let workspace = self.get_session(session_id)?.workspace_id;
        self.require_workspace_capability(&workspace, capability)
    }

    fn create_session(
        &self,
        workspace_id: &str,
        private_session_path: &str,
        node_id: &str,
        remote_session_id: &str,
        owner_user: &str,
    ) -> ApiResult<Session> {
        self.get_workspace(workspace_id)?;
        let session_id = new_id("session");
        let stamp = now_ms();
        self.execute(
            "INSERT INTO sessions (id,workspace_id,private_session_path,name,name_source,node_id,pi_session_id,owner_user,created_at,updated_at) VALUES (?,?,?,?,'auto',?,?,?,?,?)",
            params![
                session_id,
                workspace_id,
                private_session_path,
                PLACEHOLDER_SESSION_NAME,
                node_id,
                remote_session_id,
                owner_user,
                stamp,
                stamp
            ],
        )?;
        self.get_session(&session_id)
    }

    fn create_checkpoint_session(
        &self,
        workspace_id: &str,
        private_session_path: &str,
        node_id: &str,
        remote_session_id: &str,
        owner_user: &str,
    ) -> ApiResult<Session> {
        atomic(self, |tx| {
            let existing: Option<Session> = tx
                .query_row(
                    &format!("{SESSION_SELECT} WHERE sessions.node_id=? AND pi_session_id=?"),
                    params![node_id, remote_session_id],
                    Session::from_row,
                )
                .optional()?;
            if let Some(existing) = existing {
                if existing.owner_user.as_deref() != Some(owner_user)
                    || existing.workspace_id != workspace_id
                {
                    return Err(ApiError::new(
                        502,
                        "node_error",
                        "Node answered an inconsistent checkpoint continuation",
                    ));
                }
                return Ok(existing);
            }

            let workspace_owner: Option<String> = tx
                .query_row(
                    "SELECT owner_user FROM checkpoint_workspace_owners WHERE workspace_id=?",
                    [workspace_id],
                    |row| row.get(0),
                )
                .optional()?
                .flatten();
            if workspace_owner.as_deref() != Some(owner_user) {
                return Err(ApiError::not_found("Workspace not found"));
            }
            let session_id = new_id("session");
            let stamp = now_ms();
            tx.execute(
                "INSERT INTO sessions (id,workspace_id,private_session_path,name,name_source,node_id,pi_session_id,owner_user,created_at,updated_at) VALUES (?,?,?,?,'auto',?,?,?,?,?)",
                params![
                    session_id,
                    workspace_id,
                    private_session_path,
                    PLACEHOLDER_SESSION_NAME,
                    node_id,
                    remote_session_id,
                    owner_user,
                    stamp,
                    stamp
                ],
            )?;
            tx.query_row(
                &format!("{SESSION_SELECT} WHERE sessions.id=?"),
                [session_id],
                Session::from_row,
            )
            .map_err(Into::into)
        })
    }

    fn list_sessions(&self) -> ApiResult<Vec<Session>> {
        let mut statement = self.prepare(&format!("{SESSION_SELECT} WHERE workspace_id NOT IN (SELECT workspace_id FROM workspace_removals WHERE status='removed') ORDER BY updated_at DESC"))?;
        let rows = statement.query_map([], Session::from_row)?;
        Ok(rows.collect::<Result<_, _>>()?)
    }

    fn get_session(&self, session_id: &str) -> ApiResult<Session> {
        self.query_row(
            &format!("{SESSION_SELECT} WHERE id=?"),
            [session_id],
            Session::from_row,
        )
        .optional()?
        .ok_or_else(session_not_found)
    }

    fn rename_session(&self, session_id: &str, name: &str) -> ApiResult<Session> {
        self.get_session(session_id)?;
        self.execute(
            "UPDATE sessions SET name=?, name_source='user', updated_at=? WHERE id=?",
            params![name, now_ms(), session_id],
        )?;
        self.get_session(session_id)
    }

    /// Sidebar organisation only: never touches `updated_at`.
    fn set_session_flags(
        &self,
        session_id: &str,
        pinned: Option<bool>,
        settled: Option<bool>,
    ) -> ApiResult<Session> {
        let session = self.get_session(session_id)?;
        let stamp = now_ms();
        let next = |wanted: Option<bool>, current: Option<i64>| match wanted {
            None => current,
            Some(true) => Some(current.unwrap_or(stamp)),
            Some(false) => None,
        };
        self.execute(
            "UPDATE sessions SET pinned_at=?, settled_at=? WHERE id=?",
            params![
                next(pinned, session.pinned_at),
                next(settled, session.settled_at),
                session_id
            ],
        )?;
        self.get_session(session_id)
    }

    /// The agent finished a run or stopped to ask something: unread until read.
    fn mark_session_activity(&self, session_id: &str) -> ApiResult<()> {
        self.execute(
            "UPDATE sessions SET activity_at=? WHERE id=?",
            params![now_ms(), session_id],
        )?;
        Ok(())
    }

    fn mark_session_read(&self, session_id: &str) -> ApiResult<bool> {
        Ok(self.execute(
            "UPDATE sessions SET read_at=MAX(?, activity_at) WHERE id=? AND activity_at > COALESCE(read_at, 0)",
            params![now_ms(), session_id],
        )? > 0)
    }

    /// A generated title, unless the user has named the session.
    fn auto_rename_session(&self, session_id: &str, name: &str) -> ApiResult<bool> {
        Ok(self.execute(
            "UPDATE sessions SET name=? WHERE id=? AND name_source='auto' AND name!=?",
            params![name, session_id, name],
        )? > 0)
    }

    /// Every session belongs to the user who created it.
    fn claim_session(&self, session_id: &str, user: &str, deleting: bool) -> ApiResult<Session> {
        let session = self.get_session(session_id)?;
        if session.owner_user.as_deref() != Some(user) {
            return Err(ApiError::new(
                403,
                "forbidden",
                "Session belongs to another user",
            ));
        }
        if crate::workspace_removal::removed(self, &session.workspace_id)? {
            return Err(ApiError::not_found("Workspace not found"));
        }
        if !deleting {
            self.require_session_available(session_id)?;
        }
        Ok(session)
    }

    /// Sessions a schedule or a delegation started, with what started them
    /// (the newest when a delegation follows up in the same session).
    fn session_origins(&self, owner_user: &str) -> ApiResult<Vec<(String, SessionOrigin)>> {
        let mut origins = Vec::new();
        let mut scheduled = self.prepare(
            "SELECT r.session_id, r.schedule_id, r.due_at, s.title FROM schedule_runs r JOIN schedules s ON s.id=r.schedule_id WHERE r.owner_user=? AND r.session_id IS NOT NULL ORDER BY r.created_at",
        )?;
        for row in scheduled.query_map([owner_user], |row| {
            Ok((
                row.get::<_, String>(0)?,
                SessionOrigin::Schedule {
                    schedule_id: row.get(1)?,
                    due_at: row.get(2)?,
                    title: row.get(3)?,
                },
            ))
        })? {
            origins.push(row?);
        }
        let mut delegated = self.prepare(
            "SELECT id, target_session_id, assistant_session_id, title, status FROM delegations WHERE owner_user=? AND target_session_id IS NOT NULL ORDER BY created_at",
        )?;
        for row in delegated.query_map([owner_user], |row| {
            Ok((
                row.get::<_, String>(1)?,
                SessionOrigin::Delegation {
                    delegation_id: row.get(0)?,
                    from_session_id: row.get(2)?,
                    title: row.get(3)?,
                    status: row.get(4)?,
                },
            ))
        })? {
            origins.push(row?);
        }
        Ok(origins)
    }

    fn session_deletion(&self, session_id: &str) -> ApiResult<Option<Deletion>> {
        Ok(self
            .query_row(
                "SELECT owner_user, status FROM session_deletions WHERE session_id=?",
                [session_id],
                |row| {
                    Ok(Deletion {
                        owner_user: row.get(0)?,
                        status: row.get(1)?,
                    })
                },
            )
            .optional()?)
    }

    fn require_session_available(&self, session_id: &str) -> ApiResult<()> {
        let session = self.get_session(session_id)?;
        if crate::workspace_removal::removed(self, &session.workspace_id)? {
            return Err(ApiError::not_found("Workspace not found"));
        }
        if self.session_deletion(session_id)?.is_some() {
            return Err(ApiError::new(
                409,
                "conflict",
                "This chat is being deleted. Retry Delete to finish cleanup.",
            ));
        }
        Ok(())
    }

    fn begin_session_deletion(&self, session_id: &str, user: &str) -> ApiResult<()> {
        self.claim_session(session_id, user, true)?;
        self.execute(
            "INSERT OR IGNORE INTO session_deletions (session_id,owner_user,status,created_at,workspace_id) SELECT ?1, ?2, 'deleting', ?3, workspace_id FROM sessions WHERE id=?1",
            params![session_id, user, now_ms()],
        )?;
        Ok(())
    }

    /// Atomic, and nests in the caller's transaction (with forgetting the session's memory).
    fn finish_session_deletion(&self, session_id: &str) -> ApiResult<()> {
        atomic(self, |conn| finish_deletion(conn, session_id))
    }

    fn resolve_remote_session(&self, node_id: &str, remote_id: &str) -> ApiResult<Option<String>> {
        Ok(self
            .query_row(
                "SELECT id FROM sessions WHERE node_id=? AND pi_session_id=? AND id NOT IN (SELECT session_id FROM session_deletions)",
                [node_id, remote_id],
                |row| row.get(0),
            )
            .optional()?)
    }

    fn interrupt_remote_session(&self, session_id: &str) -> ApiResult<()> {
        self.execute(
            "UPDATE commands SET status='outcome_unknown', error_text='node disconnected', updated_at=? WHERE session_id=? AND status='dispatched'",
            params![now_ms(), session_id],
        )?;
        self.execute("DELETE FROM leases WHERE session_id=?", [session_id])?;
        Ok(())
    }

    fn remote_session_ids(&self, node_id: &str) -> ApiResult<Vec<String>> {
        let mut statement = self.prepare("SELECT id FROM sessions WHERE node_id=?")?;
        let rows = statement.query_map([node_id], |row| row.get(0))?;
        Ok(rows.collect::<Result<_, _>>()?)
    }

    fn set_runner_state(&self, session_id: &str, state: &str) -> ApiResult<()> {
        self.execute(
            "UPDATE sessions SET runner_state=?, updated_at=? WHERE id=?",
            params![state, now_ms(), session_id],
        )?;
        Ok(())
    }

    fn increment_epoch(&self, session_id: &str) -> ApiResult<i64> {
        self.execute(
            "UPDATE sessions SET runner_epoch=runner_epoch+1, partial_output_lost=0, updated_at=? WHERE id=?",
            params![now_ms(), session_id],
        )?;
        Ok(self.get_session(session_id)?.runner_epoch)
    }

    /// Record a command once; a retry with the same id and payload is a
    /// duplicate, with another payload a conflict.
    fn receive_command(
        &self,
        command_id: &str,
        session_id: &str,
        hash: &str,
        payload: &Value,
    ) -> ApiResult<(Command, bool)> {
        atomic(self, |tx| {
            tx.require_session_available(session_id)?;
            let existing = tx
                .query_row(
                    "SELECT * FROM commands WHERE id=?",
                    [command_id],
                    Command::from_row,
                )
                .optional()?;
            if let Some(existing) = existing {
                if existing.session_id != session_id || existing.payload_hash != hash {
                    return Err(ApiError::new(
                        409,
                        "conflict",
                        "commandId was already used with a different payload",
                    ));
                }
                return Ok((existing, true));
            }
            let stamp = now_ms();
            tx.execute(
            "INSERT INTO commands (id,session_id,payload_hash,payload_json,status,created_at,updated_at) VALUES (?,?,?,?,'received',?,?)",
            params![command_id, session_id, hash, payload.to_string(), stamp, stamp],
        )?;
            Ok((tx.get_command(command_id)?, false))
        })
    }

    fn get_command(&self, command_id: &str) -> ApiResult<Command> {
        self.query_row(
            "SELECT * FROM commands WHERE id=?",
            [command_id],
            Command::from_row,
        )
        .optional()?
        .ok_or_else(|| ApiError::not_found("Command not found"))
    }

    fn update_command(
        &self,
        command_id: &str,
        status: &str,
        result: Option<&Value>,
        error: Option<&str>,
    ) -> ApiResult<()> {
        self.execute(
            "UPDATE commands SET status=?, result_json=?, error_text=?, updated_at=? WHERE id=?",
            params![
                status,
                result.map(Value::to_string),
                error,
                now_ms(),
                command_id
            ],
        )?;
        Ok(())
    }

    fn check_lease_user(&self, session_id: &str, user: &str, force: bool) -> ApiResult<()> {
        let current: Option<(Option<String>, i64)> = self
            .query_row(
                "SELECT owner_user, expires_at FROM leases WHERE session_id=?",
                [session_id],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()?;
        if let Some((owner, expires_at)) = current
            && expires_at > now_ms()
            && owner.as_deref() != Some(user)
            && !force
        {
            return Err(ApiError::new(
                409,
                "lost_control",
                "Another user holds control",
            ));
        }
        Ok(())
    }

    fn mirror_lease(
        &self,
        session_id: &str,
        lease: &Lease,
        user: &str,
        force: bool,
    ) -> ApiResult<()> {
        self.check_lease_user(session_id, user, force)?;
        self.execute(
            "INSERT INTO leases (session_id,client_id,generation,expires_at,updated_at,owner_user) VALUES (?,?,?,?,?,?) ON CONFLICT(session_id) DO UPDATE SET client_id=excluded.client_id,generation=excluded.generation,expires_at=excluded.expires_at,updated_at=excluded.updated_at,owner_user=excluded.owner_user",
            params![
                session_id,
                lease.client_id,
                lease.generation,
                lease.expires_at,
                now_ms(),
                user
            ],
        )?;
        Ok(())
    }

    fn clear_remote_lease(&self, session_id: &str) -> ApiResult<()> {
        self.execute("DELETE FROM leases WHERE session_id=?", [session_id])?;
        Ok(())
    }

    fn validate_lease_user(&self, session_id: &str, user: &str) -> ApiResult<()> {
        let owner: Option<Option<String>> = self
            .query_row(
                "SELECT owner_user FROM leases WHERE session_id=?",
                [session_id],
                |row| row.get(0),
            )
            .optional()?;
        if owner.flatten().as_deref() != Some(user) {
            return Err(ApiError::new(
                409,
                "lost_control",
                "Control belongs to another user",
            ));
        }
        Ok(())
    }

    fn get_lease(&self, session_id: &str) -> ApiResult<Value> {
        let lease = self
            .query_row(
                "SELECT client_id, generation, expires_at FROM leases WHERE session_id=?",
                [session_id],
                |row| {
                    let expires_at: i64 = row.get(2)?;
                    Ok(json!({
                        "clientId": row.get::<_, String>(0)?,
                        "generation": row.get::<_, i64>(1)?,
                        "expiresAt": expires_at,
                        "expired": expires_at <= now_ms(),
                    }))
                },
            )
            .optional()?;
        Ok(lease.unwrap_or(Value::Null))
    }

    fn validate_lease(&self, session_id: &str, client_id: &str, generation: i64) -> ApiResult<()> {
        let lease: Option<(String, i64, i64)> = self
            .query_row(
                "SELECT client_id, generation, expires_at FROM leases WHERE session_id=?",
                [session_id],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .optional()?;
        match lease {
            Some((client, current, expires_at))
                if client == client_id && current == generation && expires_at > now_ms() =>
            {
                Ok(())
            }
            _ => Err(ApiError::new(
                409,
                "lost_control",
                "Control lease is missing, expired, or superseded",
            )),
        }
    }
}

#[cfg(test)]
mod tests;
