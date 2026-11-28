//! Node-owned capture journal and independent recovery preparation. No memory access.
//!
//! Shared directories supply observations, NOT exclusive writer attribution.
//! Only private node code binds owner/session/run/root; RPC arguments cannot.
pub mod api;
pub(crate) mod continuation;
mod files;
mod inverse;
pub mod isolation;
pub mod recovery;
pub mod runtime;
mod snapshot;

use pirc_policy::PathPolicy;
use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::fs::{self, File};
use std::io::{Read, Write};
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use crate::util::{now_ms, uuid};

type Result<T> = std::result::Result<T, String>;
pub fn digest(bytes: &[u8]) -> String {
    crate::util::hex(&Sha256::digest(bytes))
}
fn valid_hash(hash: &str) -> bool {
    hash.len() == 64
        && hash
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
fn err(error: impl std::fmt::Display) -> String {
    format!("checkpoint journal: {error}")
}

#[derive(Clone)]
pub struct Limits {
    pub file_bytes: u64,
    pub blob_bytes: u64,
    pub metadata_bytes: u64,
    pub captures_per_workspace: u32,
    pub operations_per_capture: u32,
    pub retention_ms: i64,
}
impl Default for Limits {
    fn default() -> Self {
        Self {
            file_bytes: 10 * 1024 * 1024,
            blob_bytes: 960 * 1024 * 1024,
            metadata_bytes: 64 * 1024 * 1024,
            captures_per_workspace: 100,
            operations_per_capture: 1000,
            retention_ms: 7 * 24 * 60 * 60 * 1000,
        }
    }
}

/// Constructed by the runner from its own stored authorization and sandbox.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Scope {
    pub node: String,
    pub owner: String,
    pub workspace: String,
    pub session: String,
    pub epoch: i64,
    pub run: String,
    pub root: PathBuf,
    pub device: u64,
    pub inode: u64,
    pub policy: PathPolicy,
}
impl Scope {
    pub fn bind_root(mut self) -> Result<Self> {
        self.root = self.root.canonicalize().map_err(err)?;
        let meta = fs::metadata(&self.root).map_err(err)?;
        if !meta.is_dir() {
            return Err(err("workspace is not a directory"));
        }
        self.device = meta.dev();
        self.inode = meta.ino();
        if [
            &self.node,
            &self.owner,
            &self.workspace,
            &self.session,
            &self.run,
        ]
        .iter()
        .any(|id| id.is_empty() || id.len() > 200)
        {
            return Err(err("invalid bound identity"));
        }
        Ok(self)
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum FileVersion {
    Absent,
    File {
        hash: String,
        size: u64,
        executable: bool,
    },
    Excluded {
        reason: String,
    },
}
impl FileVersion {
    fn hash(&self) -> Option<&str> {
        match self {
            Self::File { hash, .. } => Some(hash),
            _ => None,
        }
    }
}

#[derive(Debug, Serialize, Deserialize)]
pub struct Operation {
    pub id: String,
    pub capture: String,
    pub actor_group: String,
    pub path: String,
    pub tool: String,
    pub state: String,
    pub before: FileVersion,
    pub after: Option<FileVersion>,
}

#[derive(Debug, Serialize)]
pub struct CaptureInfo {
    pub id: String,
    pub actor_group: String,
    pub state: String,
    pub pinned: bool,
    pub gaps: bool,
    pub coverage: &'static str,
}

pub struct Journal {
    root: PathBuf,
    db: Mutex<Connection>,
    limits: Limits,
    // Drop after `db`: a second live process must never interrupt our journal.
    _lease: JournalLease,
}

struct JournalLease(File);

impl Drop for JournalLease {
    fn drop(&mut self) {
        // CLOEXEC closes the descriptor at exec, not at fork. A child which
        // has not exec'd yet can keep the file description (and its flock)
        // alive even after we close our descriptor.
        let _ = rustix::fs::flock(&self.0, rustix::fs::FlockOperation::Unlock);
    }
}

impl Journal {
    pub fn open(state: &Path, limits: Limits) -> Result<Self> {
        if limits.file_bytes == 0
            || limits.file_bytes > 100 * 1024 * 1024
            || limits.blob_bytes > i64::MAX as u64
            || limits.metadata_bytes < 128 * 1024
            || limits.metadata_bytes > 1024 * 1024 * 1024
            || limits.captures_per_workspace == 0
            || limits.operations_per_capture == 0
            || limits.retention_ms < 0
        {
            return Err(err("invalid capture limits"));
        }
        let dir = crate::private_dir::open_dir(state, &["checkpoints"]).map_err(err)?;
        let root = state.canonicalize().map_err(err)?.join("checkpoints");
        let meta = fs::metadata(&root).map_err(err)?;
        if meta.uid() != nix::unistd::getuid().as_raw() || meta.mode() & 0o077 != 0 {
            return Err(err("checkpoint directory is not private"));
        }
        let open_private = |name: &str| -> Result<File> {
            let file = File::from(
                rustix::fs::openat(
                    &dir,
                    name,
                    rustix::fs::OFlags::RDWR
                        | rustix::fs::OFlags::CREATE
                        | rustix::fs::OFlags::NOFOLLOW
                        | rustix::fs::OFlags::CLOEXEC,
                    rustix::fs::Mode::RUSR | rustix::fs::Mode::WUSR,
                )
                .map_err(err)?,
            );
            let meta = file.metadata().map_err(err)?;
            if !meta.is_file()
                || meta.nlink() != 1
                || meta.uid() != nix::unistd::getuid().as_raw()
                || meta.mode() & 0o077 != 0
            {
                return Err(err("unsafe checkpoint metadata file"));
            }
            Ok(file)
        };
        let lease = open_private("journal.lock")?;
        rustix::fs::flock(&lease, rustix::fs::FlockOperation::NonBlockingLockExclusive)
            .map_err(err)?;
        let lease = JournalLease(lease);
        let _index = open_private("index.sqlite")?;
        crate::private_dir::open_dir(&root, &["blobs"]).map_err(err)?;
        let db = Connection::open(root.join("index.sqlite")).map_err(err)?;
        db.busy_timeout(std::time::Duration::from_secs(5))
            .map_err(err)?;
        let version: i64 = db
            .pragma_query_value(None, "user_version", |r| r.get(0))
            .map_err(err)?;
        if version > 2 {
            return Err(err("unsupported checkpoint journal version"));
        }
        db.execute_batch("PRAGMA foreign_keys=ON; PRAGMA synchronous=FULL;
            CREATE TABLE IF NOT EXISTS captures (
                id TEXT PRIMARY KEY, node TEXT NOT NULL, owner TEXT NOT NULL, workspace TEXT NOT NULL,
                session TEXT NOT NULL, epoch INTEGER NOT NULL, run TEXT NOT NULL, root TEXT NOT NULL,
                device TEXT NOT NULL, inode TEXT NOT NULL, actor_group TEXT NOT NULL,
                state TEXT NOT NULL, pinned INTEGER NOT NULL DEFAULT 0, gaps INTEGER NOT NULL DEFAULT 0, created INTEGER NOT NULL,
                UNIQUE(node,owner,workspace,session,epoch,run));
            CREATE TABLE IF NOT EXISTS blobs (hash TEXT PRIMARY KEY, size INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS closed(session TEXT NOT NULL, epoch INTEGER NOT NULL, run TEXT NOT NULL, created INTEGER NOT NULL, PRIMARY KEY(session,epoch,run));
            CREATE TABLE IF NOT EXISTS deleted_sessions(owner TEXT NOT NULL, session TEXT NOT NULL, created INTEGER NOT NULL, PRIMARY KEY(owner,session));
            CREATE TABLE IF NOT EXISTS operations (
                seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT UNIQUE NOT NULL,
                capture TEXT NOT NULL REFERENCES captures(id) ON DELETE CASCADE,
                path TEXT NOT NULL, tool TEXT NOT NULL, state TEXT NOT NULL,
                before_json TEXT NOT NULL, after_json TEXT, pre_blob TEXT REFERENCES blobs(hash), post_blob TEXT REFERENCES blobs(hash));
            CREATE INDEX IF NOT EXISTS operations_capture ON operations(capture);
            CREATE INDEX IF NOT EXISTS operations_pre ON operations(pre_blob);
            CREATE INDEX IF NOT EXISTS operations_post ON operations(post_blob);
            CREATE INDEX IF NOT EXISTS captures_workspace ON captures(workspace,created);
            CREATE TABLE IF NOT EXISTS recovery_jobs (
                id TEXT PRIMARY KEY, node TEXT NOT NULL, owner TEXT NOT NULL, workspace TEXT NOT NULL,
                session TEXT NOT NULL, epoch INTEGER NOT NULL, run TEXT NOT NULL,
                request_key TEXT NOT NULL, request_hash TEXT NOT NULL,
                capture TEXT REFERENCES captures(id) ON DELETE RESTRICT,
                state TEXT NOT NULL, revision INTEGER NOT NULL DEFAULT 1,
                claimed INTEGER NOT NULL DEFAULT 0, reserved INTEGER NOT NULL, manifest TEXT NOT NULL, created INTEGER NOT NULL,
                UNIQUE(node,owner,workspace,request_key));
            CREATE INDEX IF NOT EXISTS recovery_capture ON recovery_jobs(capture);
            CREATE TABLE IF NOT EXISTS recovery_blobs (
                job TEXT NOT NULL REFERENCES recovery_jobs(id) ON DELETE CASCADE,
                hash TEXT NOT NULL REFERENCES blobs(hash), PRIMARY KEY(job,hash));
            UPDATE recovery_jobs SET state='interrupted',revision=revision+1 WHERE state='preparing';
            PRAGMA user_version=2;
            INSERT OR IGNORE INTO closed(session,epoch,run,created)
                SELECT session,epoch,'',unixepoch('now')*1000 FROM captures WHERE state='capturing';
            UPDATE operations SET state='interrupted' WHERE state='open';
            UPDATE captures SET state='incomplete' WHERE state='capturing';
        ").map_err(err)?;
        let page_size: u64 = db
            .pragma_query_value(None, "page_size", |r| r.get(0))
            .map_err(err)?;
        db.pragma_update(None, "max_page_count", limits.metadata_bytes / page_size)
            .map_err(err)?;
        let actual_pages: u64 = db
            .pragma_query_value(None, "max_page_count", |r| r.get(0))
            .map_err(err)?;
        if actual_pages.saturating_mul(page_size) > limits.metadata_bytes {
            return Err(err("existing journal exceeds metadata budget"));
        }
        File::from(dir).sync_all().map_err(err)?;
        File::open(state).and_then(|f| f.sync_all()).map_err(err)?;
        let journal = Self {
            root,
            db: Mutex::new(db),
            limits,
            _lease: lease,
        };
        journal.sweep()?;
        Ok(journal)
    }

    fn lock(&self) -> Result<std::sync::MutexGuard<'_, Connection>> {
        self.db.lock().map_err(|_| err("journal lock poisoned"))
    }

    fn private_blob(&self, hash: &str) -> Result<File> {
        if !valid_hash(hash) {
            return Err(err("invalid blob digest"));
        }
        let dir = crate::private_dir::open_dir(&self.root, &["blobs"]).map_err(err)?;
        let file = File::from(
            rustix::fs::openat(
                &dir,
                hash,
                rustix::fs::OFlags::RDONLY
                    | rustix::fs::OFlags::NOFOLLOW
                    | rustix::fs::OFlags::NONBLOCK
                    | rustix::fs::OFlags::CLOEXEC,
                rustix::fs::Mode::empty(),
            )
            .map_err(err)?,
        );
        let m = file.metadata().map_err(err)?;
        if !m.is_file()
            || m.nlink() != 1
            || m.uid() != nix::unistd::getuid().as_raw()
            || m.mode() & 0o077 != 0
            || m.len() > self.limits.file_bytes
        {
            return Err(err("unsafe blob file"));
        }
        Ok(file)
    }

    pub fn read_blob(&self, hash: &str) -> Result<Vec<u8>> {
        let file = self.private_blob(hash)?;
        let mut bytes = Vec::new();
        file.take(self.limits.file_bytes + 1)
            .read_to_end(&mut bytes)
            .map_err(err)?;
        if bytes.len() as u64 > self.limits.file_bytes || digest(&bytes) != hash {
            return Err(err("missing or corrupt blob"));
        }
        Ok(bytes)
    }

    fn save_blob(&self, db: &Connection, observation: &files::Observation) -> Result<()> {
        let Some(bytes) = &observation.bytes else {
            return Ok(());
        };
        let hash = observation
            .version
            .hash()
            .ok_or_else(|| err("missing digest"))?;
        let exists: bool = db
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM blobs WHERE hash=?1)",
                [hash],
                |r| r.get(0),
            )
            .map_err(err)?;
        if exists {
            self.read_blob(hash)?;
            return Ok(());
        }
        let used: u64 = db
            .query_row("SELECT COALESCE(SUM(size),0) FROM blobs", [], |r| r.get(0))
            .map_err(err)?;
        if used.saturating_add(bytes.len() as u64) > self.limits.blob_bytes {
            return Err(err("blob quota exhausted; capture suspended"));
        }
        let dir = crate::private_dir::open_dir(&self.root, &["blobs"]).map_err(err)?;
        let temporary = format!("pending-{}", uuid());
        let mut file = crate::private_dir::create_new(&dir, &temporary).map_err(err)?;
        let result = (|| -> Result<()> {
            file.write_all(bytes).map_err(err)?;
            file.sync_all().map_err(err)?;
            // Serialized under the journal transaction/lease; no live peer can
            // replace an immutable object. Reject pre-existing corrupt data.
            if self
                .root
                .join("blobs")
                .join(hash)
                .try_exists()
                .map_err(err)?
            {
                self.read_blob(hash)?;
            } else {
                rustix::fs::renameat(&dir, temporary.as_str(), &dir, hash).map_err(err)?;
                File::from(dir.try_clone().map_err(err)?)
                    .sync_all()
                    .map_err(err)?;
            }
            db.execute(
                "INSERT INTO blobs(hash,size) VALUES(?1,?2)",
                params![hash, bytes.len() as i64],
            )
            .map_err(err)?;
            Ok(())
        })();
        crate::private_dir::remove(&dir, &temporary);
        result
    }

    fn ensure_group(&self, tx: &Connection, scope: &Scope) -> Result<String> {
        let pages: u64 = tx
            .pragma_query_value(None, "page_count", |r| r.get(0))
            .map_err(err)?;
        let free: u64 = tx
            .pragma_query_value(None, "freelist_count", |r| r.get(0))
            .map_err(err)?;
        let size: u64 = tx
            .pragma_query_value(None, "page_size", |r| r.get(0))
            .map_err(err)?;
        // Reserve metadata capacity for postimages, closing/interruption and
        // deletion. Reaching admission limits must not prevent crash recovery.
        if pages.saturating_sub(free).saturating_mul(size) > self.limits.metadata_bytes * 3 / 4 {
            return Err(err("metadata quota exhausted; capture suspended"));
        }
        let deleted: bool = tx
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM deleted_sessions WHERE owner=?1 AND session=?2)",
                params![scope.owner, scope.session],
                |r| r.get(0),
            )
            .map_err(err)?;
        if deleted {
            return Err(err("checkpoint session was deleted"));
        }
        let closed: bool=tx.query_row("SELECT EXISTS(SELECT 1 FROM closed WHERE session=?1 AND epoch=?2 AND (run='' OR run=?3))",params![scope.session,scope.epoch,scope.run],|r|r.get(0)).map_err(err)?;
        if closed {
            return Err(err("checkpoint run is already closed"));
        }
        let existing: Option<(String,String,String,String,String)> = tx.query_row(
            "SELECT id,state,device,inode,root FROM captures WHERE node=?1 AND owner=?2 AND workspace=?3 AND session=?4 AND epoch=?5 AND run=?6",
            params![scope.node,scope.owner,scope.workspace,scope.session,scope.epoch,scope.run],
            |r| Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?))).optional().map_err(err)?;
        if let Some((id, state, device, inode, root)) = existing {
            if state != "capturing"
                || device != scope.device.to_string()
                || inode != scope.inode.to_string()
                || root != scope.root.to_string_lossy()
            {
                return Err(err("capture is closed or workspace identity changed"));
            }
            return Ok(id);
        }
        let count: u32 = tx
            .query_row(
                "SELECT COUNT(*) FROM captures WHERE workspace=?1",
                [&scope.workspace],
                |r| r.get(0),
            )
            .map_err(err)?;
        if count >= self.limits.captures_per_workspace {
            return Err(err(
                "capture limit reached; active/pinned captures retained",
            ));
        }
        let id = uuid();
        tx.execute("INSERT INTO captures(id,node,owner,workspace,session,epoch,run,root,device,inode,actor_group,state,created) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,'capturing',?12)",
            params![id,scope.node,scope.owner,scope.workspace,scope.session,scope.epoch,scope.run,scope.root.to_string_lossy(),scope.device.to_string(),scope.inode.to_string(),uuid(),now_ms()]).map_err(err)?;
        Ok(id)
    }

    fn maintain(&self, scope: &Scope) -> Result<()> {
        // Commit retention before unlinking orphans. Later rollback must not
        // leave retained manifests pointing at objects we have removed.
        let mut db = self.lock()?;
        let tx = db
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(err)?;
        let exists: bool=tx.query_row("SELECT EXISTS(SELECT 1 FROM captures WHERE node=?1 AND owner=?2 AND workspace=?3 AND session=?4 AND epoch=?5 AND run=?6)",
            params![scope.node,scope.owner,scope.workspace,scope.session,scope.epoch,scope.run],|r|r.get(0)).map_err(err)?;
        if !exists {
            self.prune(&tx, &scope.workspace, true)?;
        }
        tx.execute(
            "DELETE FROM closed WHERE created<?1 AND NOT EXISTS(SELECT 1 FROM captures c WHERE c.session=closed.session AND c.epoch=closed.epoch AND (closed.run='' OR c.run=closed.run))",
            [now_ms().saturating_sub(self.limits.retention_ms.max(24 * 60 * 60 * 1000))],
        )
        .map_err(err)?;
        tx.commit().map_err(err)?;
        drop(db);
        self.collect_orphans()
    }

    pub fn begin(
        &self,
        scope: &Scope,
        path: &Path,
        tool: &str,
        expected: Option<&str>,
    ) -> Result<String> {
        if !matches!(tool, "write" | "edit") || expected.is_some_and(|s| !valid_hash(s)) {
            return Err(err("invalid file operation"));
        }
        let relative = files::relative(scope, path)?;
        self.maintain(scope)?;
        let mut db = self.lock()?;
        let tx = db
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(err)?;
        let capture = self.ensure_group(&tx, scope)?;
        let count: u32 = tx
            .query_row(
                "SELECT COUNT(*) FROM operations WHERE capture=?1",
                [&capture],
                |r| r.get(0),
            )
            .map_err(err)?;
        if count >= self.limits.operations_per_capture {
            return Err(err("operation limit reached; capture suspended"));
        }
        let observation = files::observe(scope, &relative, self.limits.file_bytes)?;
        if matches!(&observation.version,FileVersion::Excluded{reason} if reason=="workspace_identity_changed" || reason=="changed_during_read")
        {
            return Err(err(
                "workspace changed during checkpoint capture; no file write attempted",
            ));
        }
        if let Some(expected) = expected
            && !matches!(observation.version, FileVersion::Excluded { .. })
            && observation.version.hash() != Some(expected)
        {
            return Err(err("stale edit preimage; reread the file before retrying"));
        }
        self.save_blob(&tx, &observation)?;
        if matches!(observation.version, FileVersion::Excluded { .. }) {
            tx.execute("UPDATE captures SET gaps=1 WHERE id=?1", [&capture])
                .map_err(err)?;
        }
        let id = uuid();
        tx.execute("INSERT INTO operations(id,capture,path,tool,state,before_json,pre_blob) VALUES(?1,?2,?3,?4,'open',?5,?6)",
            params![id,capture,relative,tool,serde_json::to_string(&observation.version).map_err(err)?,observation.version.hash()]).map_err(err)?;
        tx.commit().map_err(err)?;
        Ok(id)
    }

    /// Explicit coverage marker for shell, PTC, child/custom tools and terminals.
    /// It contains no shell output or arbitrary caller-selected file contents.
    pub fn note_uncovered(&self, scope: &Scope, tool: &str) -> Result<()> {
        self.maintain(scope)?;
        let mut db = self.lock()?;
        let tx = db
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(err)?;
        let capture = self.ensure_group(&tx, scope)?;
        let count: u32 = tx
            .query_row(
                "SELECT COUNT(*) FROM operations WHERE capture=?1",
                [&capture],
                |r| r.get(0),
            )
            .map_err(err)?;
        if count >= self.limits.operations_per_capture {
            return Err(err("operation limit reached; capture suspended"));
        }
        let version = serde_json::to_string(&FileVersion::Excluded {
            reason: "non_direct_tool_or_writer".into(),
        })
        .map_err(err)?;
        let name = if tool.len() <= 100 {
            tool
        } else {
            "custom_tool"
        };
        tx.execute("INSERT INTO operations(id,capture,path,tool,state,before_json) VALUES(?1,?2,'',?3,'uncovered',?4)",params![uuid(),capture,name,version]).map_err(err)?;
        tx.execute("UPDATE captures SET gaps=1 WHERE id=?1", [capture])
            .map_err(err)?;
        tx.commit().map_err(err)
    }

    pub fn start(&self, scope: &Scope) -> Result<()> {
        self.maintain(scope)?;
        let mut db = self.lock()?;
        let tx = db
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(err)?;
        self.ensure_group(&tx, scope)?;
        tx.commit().map_err(err)
    }

    pub fn finish(&self, scope: &Scope, operation: &str, succeeded: bool) -> Result<()> {
        self.collect_orphans()?;
        let mut db = self.lock()?;
        let tx = db
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(err)?;
        let (path, state, capture) = self.bound_operation(&tx, scope, operation)?;
        if state != "open" {
            return Ok(());
        } // idempotent; never resample a completed postimage
        let observation = files::observe(scope, &path, self.limits.file_bytes)?;
        self.save_blob(&tx, &observation)?;
        tx.execute(
            "UPDATE operations SET state=?2,after_json=?3,post_blob=?4 WHERE id=?1",
            params![
                operation,
                if succeeded { "observed" } else { "failed" },
                serde_json::to_string(&observation.version).map_err(err)?,
                observation.version.hash()
            ],
        )
        .map_err(err)?;
        if !succeeded || matches!(observation.version, FileVersion::Excluded { .. }) {
            tx.execute("UPDATE captures SET gaps=1 WHERE id=?1", [capture])
                .map_err(err)?;
        }
        tx.commit().map_err(err)
    }

    fn bound_operation(
        &self,
        db: &Connection,
        scope: &Scope,
        operation: &str,
    ) -> Result<(String, String, String)> {
        db.query_row("SELECT o.path,o.state,c.id FROM operations o JOIN captures c ON c.id=o.capture WHERE o.id=?1 AND c.node=?2 AND c.owner=?3 AND c.workspace=?4 AND c.session=?5 AND c.epoch=?6 AND c.run=?7 AND c.root=?8 AND c.device=?9 AND c.inode=?10",
            params![operation,scope.node,scope.owner,scope.workspace,scope.session,scope.epoch,scope.run,scope.root.to_string_lossy(),scope.device.to_string(),scope.inode.to_string()],
            |r| Ok((r.get(0)?,r.get(1)?,r.get(2)?))).map_err(|_| err("operation unavailable for this bound runner"))
    }

    pub(crate) fn operation_path(&self, scope: &Scope, operation: &str) -> Result<PathBuf> {
        let db = self.lock()?;
        let (path, _, _) = self.bound_operation(&db, scope, operation)?;
        Ok(scope.root.join(path))
    }

    /// Settled is observational, never stable: background/external writers may
    /// still exist. Interrupted operations stay explicit and non-restorable.
    pub fn seal(
        &self,
        session: &str,
        epoch: i64,
        run: Option<&str>,
        interrupted: bool,
    ) -> Result<()> {
        let mut db = self.lock()?;
        let tx = db
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(err)?;
        tx.execute(
            "INSERT OR IGNORE INTO closed(session,epoch,run,created) VALUES(?1,?2,?3,?4)",
            params![session, epoch, run.unwrap_or(""), now_ms()],
        )
        .map_err(err)?;
        tx.execute("UPDATE captures SET state=CASE WHEN ?4 OR gaps=1 OR state='incomplete' OR EXISTS(SELECT 1 FROM operations o WHERE o.capture=captures.id AND o.state='open') THEN 'incomplete' ELSE 'observational' END WHERE session=?1 AND epoch=?2 AND (?3 IS NULL OR run=?3) AND state IN ('capturing','incomplete')",params![session,epoch,run,interrupted]).map_err(err)?;
        tx.execute("UPDATE operations SET state='interrupted' WHERE state='open' AND capture IN (SELECT id FROM captures WHERE session=?1 AND epoch=?2 AND (?3 IS NULL OR run=?3))",params![session,epoch,run]).map_err(err)?;
        tx.commit().map_err(err)
    }

    pub fn operations(&self, scope: &Scope) -> Result<Vec<Operation>> {
        let db = self.lock()?;
        let mut statement=db.prepare("SELECT o.id,o.capture,c.actor_group,o.path,o.tool,o.state,o.before_json,o.after_json FROM operations o JOIN captures c ON c.id=o.capture WHERE c.node=?1 AND c.owner=?2 AND c.workspace=?3 AND c.session=?4 AND c.epoch=?5 AND c.run=?6 ORDER BY o.seq").map_err(err)?;
        let rows = statement
            .query_map(
                params![
                    scope.node,
                    scope.owner,
                    scope.workspace,
                    scope.session,
                    scope.epoch,
                    scope.run
                ],
                |r| {
                    Ok((
                        r.get::<_, String>(0)?,
                        r.get::<_, String>(1)?,
                        r.get::<_, String>(2)?,
                        r.get::<_, String>(3)?,
                        r.get::<_, String>(4)?,
                        r.get::<_, String>(5)?,
                        r.get::<_, String>(6)?,
                        r.get::<_, Option<String>>(7)?,
                    ))
                },
            )
            .map_err(err)?;
        let operations: Vec<Operation> = rows
            .map(|r| {
                let (id, capture, actor_group, path, tool, state, before, after) =
                    r.map_err(err)?;
                Ok(Operation {
                    id,
                    capture,
                    actor_group,
                    path,
                    tool,
                    state,
                    before: serde_json::from_str(&before).map_err(err)?,
                    after: after
                        .map(|s| serde_json::from_str(&s))
                        .transpose()
                        .map_err(err)?,
                })
            })
            .collect::<Result<_>>()?;
        // Never expose missing/corrupt evidence as a usable checkpoint.
        for operation in &operations {
            for version in std::iter::once(&operation.before).chain(operation.after.iter()) {
                if let FileVersion::File { hash, size, .. } = version {
                    let valid = self
                        .read_blob(hash)
                        .is_ok_and(|bytes| bytes.len() as u64 == *size);
                    if !valid {
                        db.execute(
                            "UPDATE captures SET gaps=1,state='incomplete' WHERE id=?1",
                            [&operation.capture],
                        )
                        .map_err(err)?;
                        return Err(err("checkpoint contains missing or corrupt evidence"));
                    }
                }
            }
        }
        Ok(operations)
    }

    pub fn info(&self, scope: &Scope) -> Result<Option<CaptureInfo>> {
        self.lock()?.query_row("SELECT id,actor_group,state,pinned,gaps FROM captures WHERE node=?1 AND owner=?2 AND workspace=?3 AND session=?4 AND epoch=?5 AND run=?6",
            params![scope.node,scope.owner,scope.workspace,scope.session,scope.epoch,scope.run],
            |r|Ok(CaptureInfo{id:r.get(0)?,actor_group:r.get(1)?,state:r.get(2)?,pinned:r.get(3)?,gaps:r.get(4)?,coverage:"observational: main-agent direct file tools only; shell, children, terminals and external writers uncovered"})).optional().map_err(err)
    }

    /// Internal owner-bound retention primitive; not an agent/public endpoint.
    pub fn pin(&self, scope: &Scope, pinned: bool) -> Result<()> {
        let changed=self.lock()?.execute("UPDATE captures SET pinned=?7 WHERE node=?1 AND owner=?2 AND workspace=?3 AND session=?4 AND epoch=?5 AND run=?6",
            params![scope.node,scope.owner,scope.workspace,scope.session,scope.epoch,scope.run,pinned]).map_err(err)?;
        if changed != 1 {
            return Err(err("capture unavailable"));
        }
        Ok(())
    }

    pub fn delete_session(&self, owner: &str, session: &str) -> Result<()> {
        let mut db = self.lock()?;
        let tx = db
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(err)?;
        let pinned: bool = tx
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM captures WHERE owner=?1 AND session=?2 AND pinned=1)",
                params![owner, session],
                |r| r.get(0),
            )
            .map_err(err)?;
        let retained: bool = tx.query_row("SELECT EXISTS(SELECT 1 FROM recovery_jobs r JOIN captures c ON c.id=r.capture WHERE c.owner=?1 AND c.session=?2)",params![owner,session],|r|r.get(0)).map_err(err)?;
        if retained {
            return Err(err(
                "session has retained recovery inputs; review recovery jobs before deleting",
            ));
        }
        if pinned {
            return Err(err(
                "session has pinned checkpoint evidence; review it before deleting",
            ));
        }
        tx.execute(
            "INSERT OR IGNORE INTO deleted_sessions(owner,session,created) VALUES(?1,?2,?3)",
            params![owner, session, now_ms()],
        )
        .map_err(err)?;
        tx.execute(
            "DELETE FROM captures WHERE owner=?1 AND session=?2",
            params![owner, session],
        )
        .map_err(err)?;
        tx.commit().map_err(err)?;
        drop(db);
        self.collect_orphans()
    }

    fn prune(&self, db: &Connection, workspace: &str, reserve: bool) -> Result<()> {
        db.execute("DELETE FROM captures WHERE workspace=?1 AND pinned=0 AND NOT EXISTS(SELECT 1 FROM recovery_jobs r WHERE r.capture=captures.id) AND state!='capturing' AND EXISTS(SELECT 1 FROM closed f WHERE f.session=captures.session AND f.epoch=captures.epoch AND (f.run='' OR f.run=captures.run)) AND created<?2",params![workspace,now_ms().saturating_sub(self.limits.retention_ms)]).map_err(err)?;
        // Reserve one slot, retaining active and explicitly pinned evidence.
        db.execute("DELETE FROM captures WHERE id IN (SELECT id FROM captures WHERE workspace=?1 AND pinned=0 AND NOT EXISTS(SELECT 1 FROM recovery_jobs r WHERE r.capture=captures.id) AND state!='capturing' AND EXISTS(SELECT 1 FROM closed f WHERE f.session=captures.session AND f.epoch=captures.epoch AND (f.run='' OR f.run=captures.run)) ORDER BY created,id LIMIT MAX(0,(SELECT COUNT(*) FROM captures WHERE workspace=?1)-?2+?3))",params![workspace,self.limits.captures_per_workspace,i64::from(reserve)]).map_err(err)?;
        Ok(())
    }

    pub fn sweep(&self) -> Result<()> {
        let mut db = self.lock()?;
        let tx = db
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(err)?;
        let workspaces: Vec<String> = {
            let mut s = tx
                .prepare("SELECT DISTINCT workspace FROM captures")
                .map_err(err)?;
            s.query_map([], |r| r.get(0))
                .map_err(err)?
                .collect::<std::result::Result<_, _>>()
                .map_err(err)?
        };
        for workspace in workspaces {
            self.prune(&tx, &workspace, false)?;
        }
        tx.commit().map_err(err)?;
        drop(db);
        self.collect_orphans()
    }

    /// Only unreferenced private blobs; no workspace paths are ever deleted.
    pub fn collect_orphans(&self) -> Result<()> {
        let db = self.lock()?;
        db.execute("DELETE FROM blobs WHERE hash NOT IN (SELECT pre_blob FROM operations WHERE pre_blob IS NOT NULL UNION SELECT post_blob FROM operations WHERE post_blob IS NOT NULL UNION SELECT hash FROM recovery_blobs)",[]).map_err(err)?;
        for entry in fs::read_dir(self.root.join("blobs")).map_err(err)? {
            let entry = entry.map_err(err)?;
            let name = entry.file_name();
            let Some(name) = name.to_str() else { continue };
            let referenced = if valid_hash(name) {
                db.query_row(
                    "SELECT EXISTS(SELECT 1 FROM blobs WHERE hash=?1)",
                    [name],
                    |r| r.get::<_, bool>(0),
                )
                .map_err(err)?
            } else {
                false
            };
            if !referenced
                && (valid_hash(name)
                    || name.strip_prefix("pending-").is_some_and(|s| {
                        s.len() == 36 && s.bytes().all(|b| b.is_ascii_hexdigit() || b == b'-')
                    }))
            {
                fs::remove_file(entry.path()).map_err(err)?;
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod lease_tests {
    use super::*;

    #[test]
    fn a_duplicate_descriptor_cannot_keep_a_closed_journal_locked() {
        let dir = tempfile::tempdir().unwrap();
        let state = dir.path().join("state");
        let journal = Journal::open(&state, Limits::default()).unwrap();
        // Like the descriptor inherited between fork and exec, this keeps the
        // original open file description alive after the Journal closes its fd.
        let inherited = journal._lease.0.try_clone().unwrap();
        assert!(Journal::open(&state, Limits::default()).is_err());

        drop(journal);
        let reopened = Journal::open(&state, Limits::default()).unwrap();
        drop(inherited);
        assert!(Journal::open(&state, Limits::default()).is_err());
        drop(reopened);
        assert!(Journal::open(&state, Limits::default()).is_ok());
    }
}
