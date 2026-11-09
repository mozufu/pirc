//! Unforgeable in-process continuation ticket. Never deserialized from an agent.
//! Its account-wide flock survives sandbox preparation and holds through cleanup.
use super::{
    Result, Scope, err,
    recovery::{RecoveryFactory, binding, output_scope},
    snapshot,
};
use crate::panels::inspect::ChildEnv;
use crate::sandbox::{PrepareInput, Sandbox};
use pirc_policy::{PathPolicy, session::SessionPolicyInput};
use rusqlite::params;
use std::fs::{File, OpenOptions};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::Arc;

#[derive(Clone, Debug)]
pub struct RecoveryIsolation {
    root: PathBuf,
    source: PathBuf,
    source_policy: PathPolicy,
    device: u64,
    inode: u64,
    fence: i64,
    adopted: bool,
    source_scope: Scope,
    source_revision: String,
    source_git: Option<std::collections::BTreeSet<String>>,
    limits: super::recovery::CopyLimits,
    file_limit: u64,
    _lease: Arc<File>,
}
impl PartialEq for RecoveryIsolation {
    fn eq(&self, other: &Self) -> bool {
        self.root == other.root
            && self.source == other.source
            && self.source_policy == other.source_policy
            && self.device == other.device
            && self.inode == other.inode
            && self.fence == other.fence
    }
}
impl Eq for RecoveryIsolation {}
impl RecoveryIsolation {
    pub fn root(&self) -> &Path {
        &self.root
    }
    pub(crate) fn check_session(&self, session_id: &str) -> Result<()> {
        if session_id == self.source_scope.session {
            return Err(err("recovery requires a new session identity"));
        }
        Ok(())
    }
    pub fn generation(&self) -> i64 {
        self.fence
    }
    /// The caller creates a NEW authorized workspace/session with fresh trust.
    /// Memory/context replay is intentionally absent. No project code is run here.
    pub fn prepare_input(
        &self,
        session_id: String,
        session_dir: PathBuf,
        inference_socket: Option<PathBuf>,
    ) -> PrepareInput {
        PrepareInput {
            grants: Vec::new(),
            session_id,
            workspace_root: self.root.clone(),
            session_dir,
            inference_socket,
            protected_paths: Vec::new(),
            workspace_memory_file: None,
            project_files_dir: None,
            recovery: Some(self.clone()),
        }
    }
    pub(crate) fn constrain(&self, input: &mut SessionPolicyInput) -> Result<()> {
        if !self.adopted {
            let source = snapshot::scan(
                &self.source_scope,
                &self.limits,
                self.file_limit,
                self.source_git.as_ref(),
            )?;
            if source.fingerprint != self.source_revision {
                return Err(err(
                    "source changed before isolated execution; refresh the recovery",
                ));
            }
        }
        let meta = std::fs::symlink_metadata(&self.root).map_err(err)?;
        if !meta.is_dir()
            || (meta.dev(), meta.ino()) != (self.device, self.inode)
            || Path::new(&input.workspace_root) != self.root
        {
            return Err(err("isolated recovery workspace identity changed"));
        }
        if input.workspace_memory_file.is_some()
            || !input.read_only_dirs.is_empty() && input.read_only_dirs.len() > 1
        {
            return Err(err(
                "recovery continuation must not inherit workspace memory/project state",
            ));
        }
        // Only fresh workspace/session and existing sandbox temp roots may be
        // writable. Drop globally configured extra write roots/allowedPaths.
        input.allowed_paths.clear();
        // Shared /tmp grants could reach future siblings when private node
        // state itself is under /tmp. Only this session's private temp remains.
        input
            .tmp_dirs
            .retain(|p| pirc_policy::real_resolve(p) != pirc_policy::real_resolve("/tmp"));
        input.config.filesystem.allow_write.clear();
        input.config.filesystem.allow_read.clear();
        input.config.filesystem.allow_git_config = false;
        let map = |rule: &str| -> Option<String> {
            let path = Path::new(rule);
            if let Ok(relative) = path.strip_prefix(&self.source) {
                Some(self.root.join(relative).to_string_lossy().into_owned())
            } else if self.source.starts_with(path) {
                Some(self.root.to_string_lossy().into_owned())
            } else {
                None
            }
        };
        input
            .config
            .filesystem
            .deny_read
            .extend(self.source_policy.deny_read.iter().cloned());
        input
            .config
            .filesystem
            .deny_read
            .extend(self.source_policy.deny_read.iter().filter_map(|s| map(s)));
        // Retain specific read exceptions only inside the new root, never broad
        // exceptions to the checkpoint store, another workspace or source.
        input
            .config
            .filesystem
            .allow_read
            .extend(self.source_policy.allow_read.iter().filter_map(|s| map(s)));
        input
            .config
            .filesystem
            .deny_write
            .extend(self.source_policy.deny_write.iter().filter_map(|s| map(s)));
        input.config.filesystem.deny_write.extend(
            self.source_policy
                .deny_write
                .iter()
                .filter(|rule| {
                    // Alias spellings also protect symlink entries themselves.
                    // Feeding /var back through config canonicalization would
                    // incorrectly turn link protection into a /private/var deny.
                    Path::new(rule.as_str()) == Path::new(&pirc_policy::real_resolve(rule))
                        && (!self.root.starts_with(rule) || self.source.starts_with(rule))
                })
                .cloned(),
        );
        input
            .config
            .filesystem
            .deny_write
            .push(self.source.to_string_lossy().into_owned());
        input
            .protected_paths
            .push(self.source.to_string_lossy().into_owned());
        Ok(())
    }
}
impl RecoveryFactory {
    /// Trusted UI-only handoff for phase 4. Revalidates both source and unopened
    /// output, fences stale confirmations, acquires one writer group per root.
    /// No running session is retargeted, no tools replayed, no process launched.
    pub async fn claim(
        &self,
        scope: Scope,
        id: String,
        expected_revision: i64,
        accept_unresolved: bool,
        sandbox: &dyn Sandbox,
        env: &ChildEnv,
    ) -> Result<RecoveryIsolation> {
        let job = self
            .refresh(scope.clone(), id.clone(), sandbox, env)
            .await?;
        let git = self.eligibility(&scope, sandbox, env).await?;
        let factory = self.clone();
        tokio::task::spawn_blocking(move || {
            factory.claim_ready(scope, id, job, expected_revision, accept_unresolved, git)
        })
        .await
        .map_err(err)?
    }
    fn claim_ready(
        &self,
        scope: Scope,
        id: String,
        job: super::recovery::Job,
        expected_revision: i64,
        accept_unresolved: bool,
        git: Option<std::collections::BTreeSet<String>>,
    ) -> Result<RecoveryIsolation> {
        if !matches!(job.state.as_str(), "ready" | "opened") || job.revision != expected_revision {
            return Err(err("recovery stale or confirmation revision changed"));
        }
        if !accept_unresolved
            && job
                .manifest
                .paths
                .iter()
                .any(|p| p.status != "inverse_reviewed_observation")
        {
            return Err(err(
                "unresolved or observational paths require explicit keep-current review",
            ));
        }
        let root = job
            .output
            .ok_or_else(|| err("recovery output unavailable"))?;
        let lease = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .custom_flags(nix::libc::O_NOFOLLOW | nix::libc::O_CLOEXEC | nix::libc::O_NONBLOCK)
            .mode(0o600)
            .open(
                root.parent()
                    .ok_or_else(|| err("invalid recovery root"))?
                    .join("writer.lock"),
            )
            .map_err(err)?;
        let meta = lease.metadata().map_err(err)?;
        if !meta.is_file()
            || meta.nlink() != 1
            || meta.uid() != nix::unistd::getuid().as_raw()
            || meta.mode() & 0o077 != 0
        {
            return Err(err("unsafe recovery writer lock"));
        }
        rustix::fs::flock(&lease, rustix::fs::FlockOperation::NonBlockingLockExclusive)
            .map_err(|_| err("recovery workspace already has an active writer group"))?;
        let out = output_scope(&scope, &root)?;
        if (out.device, out.inode) != (job.manifest.output_device, job.manifest.output_inode) {
            return Err(err("recovery output identity changed"));
        }
        let latest = snapshot::scan(
            &out,
            &job.manifest.limits,
            self.journal.limits.file_bytes,
            None,
        )?;
        if job.state == "ready" && Some(latest.fingerprint) != job.manifest.output_revision {
            return Err(err(
                "unopened recovery output changed; preserve and review it",
            ));
        }
        if snapshot::scan(
            &scope,
            &job.manifest.limits,
            self.journal.limits.file_bytes,
            git.as_ref(),
        )?
        .fingerprint
            != job.manifest.source_revision
        {
            self.journal.set_job_state(&id, "stale")?;
            return Err(err("source changed before recovery continuation"));
        }
        let db = self.journal.lock()?;
        let changed=db.execute("UPDATE recovery_jobs SET state='opened',claimed=1,revision=revision+1 WHERE id=?1 AND revision=?2 AND state IN ('ready','opened') AND json_extract(manifest,'$.binding')=?3",params![id,expected_revision,binding(&scope)?]).map_err(err)?;
        if changed != 1 {
            return Err(err("recovery confirmation already handled or stale"));
        }
        Ok(RecoveryIsolation {
            root,
            source: scope.root.clone(),
            source_policy: scope.policy.clone(),
            device: out.device,
            inode: out.inode,
            fence: expected_revision + 1,
            adopted: false,
            source_scope: scope,
            source_revision: job.manifest.source_revision,
            source_git: git,
            limits: job.manifest.limits,
            file_limit: self.journal.limits.file_bytes,
            _lease: Arc::new(lease),
        })
    }
}

impl RecoveryFactory {
    /// Only the trusted Node's durable adoption mapping may invoke this. Once
    /// adopted, the candidate is the user's independent workspace: original
    /// edits no longer invalidate it or trigger recopying/overwriting it.
    pub(crate) async fn reopen_adopted(
        &self,
        scope: Scope,
        id: String,
        expected_root: PathBuf,
    ) -> Result<RecoveryIsolation> {
        let factory = self.clone();
        tokio::task::spawn_blocking(move || {
            let journal = &factory.journal;
            let job = journal.recovery_job(&scope, &id)?;
            let claimed: bool = journal
                .lock()?
                .query_row(
                    "SELECT claimed FROM recovery_jobs WHERE id=?1",
                    [&id],
                    |r| r.get(0),
                )
                .map_err(err)?;
            if !claimed || !matches!(job.state.as_str(), "opened" | "stale") {
                return Err(err("recovery workspace has not been adopted"));
            }
            let root = journal.root.join("workspaces").join(&id).join("root");
            if root != expected_root {
                return Err(err("adopted recovery root binding changed"));
            }
            let lease = OpenOptions::new()
                .read(true)
                .write(true)
                .custom_flags(nix::libc::O_NOFOLLOW | nix::libc::O_CLOEXEC | nix::libc::O_NONBLOCK)
                .open(
                    root.parent()
                        .ok_or_else(|| err("invalid recovery root"))?
                        .join("writer.lock"),
                )
                .map_err(err)?;
            let m = lease.metadata().map_err(err)?;
            if !m.is_file()
                || m.nlink() != 1
                || m.uid() != nix::unistd::getuid().as_raw()
                || m.mode() & 0o077 != 0
            {
                return Err(err("unsafe recovery writer lock"));
            }
            rustix::fs::flock(&lease, rustix::fs::FlockOperation::NonBlockingLockExclusive)
                .map_err(|_| err("Recovery workspace already has an active writer group"))?;
            let m = std::fs::symlink_metadata(&root).map_err(err)?;
            if !m.is_dir()
                || (m.dev(), m.ino()) != (job.manifest.output_device, job.manifest.output_inode)
            {
                return Err(err("adopted recovery workspace identity changed"));
            }
            journal
                .lock()?
                .execute(
                    "UPDATE recovery_jobs SET revision=revision+1 WHERE id=?1",
                    [&id],
                )
                .map_err(err)?;
            Ok(RecoveryIsolation {
                root,
                source: scope.root.clone(),
                source_policy: scope.policy.clone(),
                device: m.dev(),
                inode: m.ino(),
                fence: job.revision + 1,
                adopted: true,
                source_scope: scope,
                source_revision: job.manifest.source_revision,
                source_git: None,
                limits: job.manifest.limits,
                file_limit: journal.limits.file_bytes,
                _lease: Arc::new(lease),
            })
        })
        .await
        .map_err(err)?
    }
}
