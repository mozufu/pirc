//! Production recovery acceptance against disposable sources and private state.
use pirc_node::checkpoints::recovery::{
    CopyLimits, Job, PrepareRequest, RecoveryFactory, Selection,
};
use pirc_node::checkpoints::{Journal, Limits, Scope, digest};
use pirc_node::error::ApiResult;
use pirc_node::sandbox::{
    BoxFuture, PrepareInput, Prepared, ReadonlyInput, Sandbox, SandboxStatus,
};
use pirc_policy::PathPolicy;
use std::collections::BTreeMap;
use std::fs;
use std::os::unix::fs::{MetadataExt, PermissionsExt, symlink};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;
use tempfile::TempDir;

// For non-Git copies no process/sandbox is needed. For owned Git fixtures only,
// forward the read-only eligibility command, with no hooks/filters configured.
struct FixtureSandbox;
impl Sandbox for FixtureSandbox {
    fn check(&self) -> BoxFuture<'_, SandboxStatus> {
        Box::pin(async {
            SandboxStatus::Active {
                description: "fixture".into(),
            }
        })
    }
    fn prepare(&self, _: PrepareInput) -> BoxFuture<'_, ApiResult<Prepared>> {
        panic!("no live agent launch authorized by preparation")
    }
    fn prepare_readonly(&self, input: ReadonlyInput) -> BoxFuture<'_, ApiResult<Prepared>> {
        Box::pin(async move {
            Ok(Prepared::new(
                PathBuf::from(&input.command[0]),
                input.command[1..].to_vec(),
                vec![],
                Default::default(),
                vec![],
                None,
                || {},
            ))
        })
    }
}
struct Fixture {
    _dir: TempDir,
    state: PathBuf,
    scope: Scope,
    journal: Arc<Journal>,
    factory: RecoveryFactory,
}
impl Fixture {
    fn new() -> Self {
        Self::with_limits(CopyLimits {
            bytes: 1024 * 1024,
            node_bytes: 8 * 1024 * 1024,
            entries: 1000,
            free_reserve: 0,
        })
    }
    fn with_limits(limits: CopyLimits) -> Self {
        let dir = tempfile::tempdir().unwrap();
        let base = dir.path().canonicalize().unwrap();
        let state = base.join("state");
        let root = base.join("source");
        fs::create_dir(&root).unwrap();
        let scope = Scope {
            node: "n".into(),
            owner: "o".into(),
            workspace: "w".into(),
            session: "s".into(),
            epoch: 1,
            run: "r".into(),
            root: root.clone(),
            device: 0,
            inode: 0,
            policy: PathPolicy {
                allow_write: vec![root.to_string_lossy().into_owned()],
                ..Default::default()
            },
        }
        .bind_root()
        .unwrap();
        let journal = Arc::new(Journal::open(&state, Limits::default()).unwrap());
        let factory = RecoveryFactory::new(journal.clone(), limits).unwrap();
        Self {
            _dir: dir,
            state,
            scope,
            journal,
            factory,
        }
    }
    fn path(&self, p: &str) -> PathBuf {
        self.scope.root.join(p)
    }
    fn write(&self, p: &str, bytes: impl AsRef<[u8]>) {
        let path = self.path(p);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, bytes).unwrap();
    }
    fn operation(&self, p: &str, after: Option<&[u8]>) -> String {
        let id = self
            .journal
            .begin(&self.scope, &self.path(p), "write", None)
            .unwrap();
        if let Some(bytes) = after {
            self.write(p, bytes);
        } else {
            fs::remove_file(self.path(p)).unwrap();
        }
        self.journal.finish(&self.scope, &id, true).unwrap();
        id
    }
    fn seal(&self) {
        self.journal.seal("s", 1, Some("r"), false).unwrap();
    }
    fn sql(&self, sql: &str) -> i64 {
        rusqlite::Connection::open(self.state.join("checkpoints/index.sqlite"))
            .unwrap()
            .query_row(sql, [], |r| r.get(0))
            .unwrap()
    }
    async fn request(&self, operations: Vec<String>, review: bool, key: &str) -> PrepareRequest {
        let selection = Selection {
            operations,
            review_observational: review,
        };
        let preview = self
            .factory
            .preview(
                self.scope.clone(),
                selection.clone(),
                &FixtureSandbox,
                &BTreeMap::new(),
            )
            .await
            .unwrap();
        PrepareRequest {
            version: 1,
            key: key.into(),
            preview_revision: preview.revision,
            selection,
        }
    }
    async fn prepare(&self, request: PrepareRequest) -> Job {
        self.factory
            .prepare(
                self.scope.clone(),
                request,
                &FixtureSandbox,
                &BTreeMap::new(),
            )
            .await
            .unwrap()
    }
    async fn recover(&self, operations: Vec<String>, review: bool) -> Job {
        self.prepare(self.request(operations, review, "one").await)
            .await
    }
}
fn read(job: &Job, path: &str) -> Vec<u8> {
    fs::read(job.output.as_ref().unwrap().join(path)).unwrap()
}
fn git(root: &Path, args: &[&str]) {
    assert!(
        Command::new("git")
            .current_dir(root)
            .env_clear()
            .env("PATH", "/usr/bin:/bin")
            .env("HOME", root.parent().unwrap())
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .args(args)
            .output()
            .unwrap()
            .status
            .success()
    );
}
fn tree(root: &Path) -> BTreeMap<PathBuf, Vec<u8>> {
    fn walk(root: &Path, dir: &Path, out: &mut BTreeMap<PathBuf, Vec<u8>>) {
        for e in fs::read_dir(dir).unwrap() {
            let e = e.unwrap();
            if e.file_type().unwrap().is_dir() {
                walk(root, &e.path(), out);
            } else {
                out.insert(
                    e.path().strip_prefix(root).unwrap().into(),
                    fs::read(e.path()).unwrap(),
                );
            }
        }
    }
    let mut out = BTreeMap::new();
    walk(root, root, &mut out);
    out
}
#[tokio::test]
async fn observed_changes_are_not_silently_promoted_to_attributed_effects() {
    let f = Fixture::new();
    f.write("main", b"dirty user\n");
    let op = f.operation("main", Some(b"agent\n"));
    f.seal();
    let job = f.recover(vec![op], false).await;
    assert_eq!(job.state, "ready");
    assert_eq!(read(&job, "main"), b"agent\n");
    assert_eq!(job.manifest.paths[0].status, "review_observational");
    assert_eq!(
        f.journal.info(&f.scope).unwrap().unwrap().state,
        "observational"
    );
}
#[tokio::test]
async fn dirty_staged_unstaged_and_untracked_source_and_git_are_unchanged() {
    let f = Fixture::new();
    git(&f.scope.root, &["init", "-q"]);
    f.write("main", b"committed\n");
    git(&f.scope.root, &["add", "main"]);
    git(
        &f.scope.root,
        &[
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@example.invalid",
            "commit",
            "-qm",
            "baseline",
        ],
    );
    f.write("main", b"staged\n");
    git(&f.scope.root, &["add", "main"]);
    f.write("main", b"unstaged user\n");
    f.write("untracked", b"user file");
    let op = f.operation("main", Some(b"agent\n"));
    f.seal();
    let source = tree(&f.scope.root);
    let job = f.recover(vec![op], true).await;
    assert_eq!(read(&job, "main"), b"unstaged user\n");
    assert_eq!(read(&job, "untracked"), b"user file");
    assert_eq!(tree(&f.scope.root), source);
    assert!(!job.output.as_ref().unwrap().join(".git").exists());
    let a = fs::metadata(f.path("main")).unwrap();
    let b = fs::metadata(job.output.unwrap().join("main")).unwrap();
    assert_ne!((a.dev(), a.ino()), (b.dev(), b.ino()));
}
#[tokio::test]
async fn inverse_retains_later_other_hunk_and_conflicts_keep_current_without_markers() {
    for conflict in [false, true] {
        let f = Fixture::new();
        f.write("main", b"a\n1\n2\n3\n4\n5\nz\n");
        let op = f.operation("main", Some(b"agent\n1\n2\n3\n4\n5\nz\n"));
        f.seal();
        let current = if conflict {
            b"later\n1\n2\n3\n4\n5\nz\n".as_slice()
        } else {
            b"agent\n1\n2\n3\n4\n5\nuser\n".as_slice()
        };
        f.write("main", current);
        let job = f.recover(vec![op], true).await;
        if conflict {
            assert_eq!(read(&job, "main"), current);
            assert_eq!(job.manifest.paths[0].status, "conflict");
        } else {
            assert_eq!(read(&job, "main"), b"a\n1\n2\n3\n4\n5\nuser\n");
        }
        assert_eq!(fs::read(f.path("main")).unwrap(), current);
    }
}
#[tokio::test]
async fn exact_creations_and_deletions_only_and_directory_collisions_are_preserved() {
    for variant in 0..5 {
        let f = Fixture::new();
        if variant >= 2 {
            f.write("main", b"user baseline");
        }
        let op = f.operation("main", if variant < 2 { Some(b"agent") } else { None });
        f.seal();
        if variant == 1 || variant == 3 {
            f.write("main", b"later user");
        }
        if variant == 4 {
            f.write("main/sub", b"later child");
        }
        let job = f.recover(vec![op], true).await;
        match variant {
            0 => assert!(!job.output.unwrap().join("main").exists()),
            1 | 3 => {
                assert_eq!(read(&job, "main"), b"later user");
                assert_eq!(job.manifest.paths[0].status, "conflict");
            }
            2 => assert_eq!(read(&job, "main"), b"user baseline"),
            4 => {
                assert_eq!(read(&job, "main/sub"), b"later child");
                assert_eq!(job.manifest.paths[0].status, "excluded");
            }
            _ => unreachable!(),
        }
    }
}
#[tokio::test]
async fn binary_line_endings_and_executable_bits_are_exact() {
    for baseline in [
        b"binary\0\xff".as_slice(),
        b"a\r\nwithout-final-newline".as_slice(),
    ] {
        let f = Fixture::new();
        f.write("main", baseline);
        fs::set_permissions(f.path("main"), fs::Permissions::from_mode(0o6755)).unwrap();
        let op = f
            .journal
            .begin(&f.scope, &f.path("main"), "write", None)
            .unwrap();
        f.write("main", b"agent");
        fs::set_permissions(f.path("main"), fs::Permissions::from_mode(0o600)).unwrap();
        f.journal.finish(&f.scope, &op, true).unwrap();
        f.seal();
        let job = f.recover(vec![op], true).await;
        assert_eq!(read(&job, "main"), baseline);
        assert_eq!(
            fs::metadata(job.output.unwrap().join("main"))
                .unwrap()
                .mode()
                & 0o7777,
            0o700
        );
    }
    let f = Fixture::new();
    f.write("main", b"before\0");
    let op = f.operation("main", Some(b"after\0"));
    f.seal();
    f.write("main", b"user\0");
    let job = f.recover(vec![op], true).await;
    assert_eq!(read(&job, "main"), b"user\0");
    assert_eq!(job.manifest.paths[0].status, "conflict");
}
#[tokio::test]
async fn sensitive_paths_links_ignored_builds_and_nested_repos_are_not_copied() {
    let mut f = Fixture::new();
    f.write("main", b"ok");
    f.write("private/token", b"secret");
    f.write("target/cache", b"build");
    f.write("nested/.git/config", b"nested");
    f.write("nested/main", b"hidden");
    f.write("hard", b"shared");
    fs::hard_link(f.path("hard"), f.path("alias")).unwrap();
    symlink(f.path("private"), f.path("link")).unwrap();
    f.scope
        .policy
        .deny_read
        .push(f.path("private").display().to_string());
    let job = f.recover(vec![], false).await;
    let root = job.output.unwrap();
    assert_eq!(fs::read(root.join("main")).unwrap(), b"ok");
    for path in ["private", "target", "nested", "hard", "alias", "link"] {
        assert!(!root.join(path).exists());
        assert!(job.manifest.exclusions.contains_key(path));
    }
}
#[tokio::test]
async fn real_git_ignores_include_tracked_exceptions_and_never_run_hooks() {
    let f = Fixture::new();
    git(&f.scope.root, &["init", "-q"]);
    f.write(".gitignore", b"*.secret\n");
    f.write("hidden.secret", b"sensitive");
    f.write("tracked.secret", b"explicit tracked");
    git(&f.scope.root, &["add", "-f", "tracked.secret"]);
    f.write(
        ".git/hooks/post-checkout",
        b"#!/bin/sh\ntouch SHOULD_NOT_RUN\n",
    );
    fs::set_permissions(
        f.path(".git/hooks/post-checkout"),
        fs::Permissions::from_mode(0o700),
    )
    .unwrap();
    let before = tree(&f.scope.root);
    let job = f.recover(vec![], false).await;
    assert!(!job.output.as_ref().unwrap().join("hidden.secret").exists());
    assert_eq!(read(&job, "tracked.secret"), b"explicit tracked");
    assert_eq!(tree(&f.scope.root), before);
}
#[tokio::test]
async fn stale_preview_root_replacement_and_policy_changes_fail_closed() {
    for variant in 0..3 {
        let mut f = Fixture::new();
        f.write("main", b"current");
        let request = f.request(vec![], false, "one").await;
        if variant == 0 {
            f.write("main", b"new user");
        } else if variant == 1 {
            let old = f.scope.root.with_extension("old");
            fs::rename(&f.scope.root, old).unwrap();
            fs::create_dir(&f.scope.root).unwrap();
            f.write("main", b"current");
        } else {
            f.scope
                .policy
                .deny_read
                .push(f.path("main").display().to_string());
        }
        assert!(
            f.factory
                .prepare(f.scope.clone(), request, &FixtureSandbox, &BTreeMap::new())
                .await
                .is_err()
        );
        assert_eq!(f.sql("SELECT COUNT(*) FROM recovery_jobs"), 0);
    }
}
#[tokio::test]
async fn duplicate_requests_and_two_devices_return_one_durable_job_and_preserve_output_edits() {
    let f = Fixture::new();
    f.write("main", b"current");
    let request = f.request(vec![], false, "same").await;
    let env = BTreeMap::new();
    let (a, b) = tokio::join!(
        f.factory
            .prepare(f.scope.clone(), request.clone(), &FixtureSandbox, &env),
        f.factory
            .prepare(f.scope.clone(), request.clone(), &FixtureSandbox, &env)
    );
    let (a, b) = (a.unwrap(), b.unwrap());
    assert_eq!(a.id, b.id);
    assert_eq!(f.sql("SELECT COUNT(*) FROM recovery_jobs"), 1);
    let job = f.prepare(request.clone()).await;
    fs::write(
        job.output.as_ref().unwrap().join("main"),
        b"user in recovery",
    )
    .unwrap();
    let again = f.prepare(request.clone()).await;
    assert_eq!(again.id, job.id);
    assert_eq!(read(&again, "main"), b"user in recovery");
    let mut different = request;
    different.selection.review_observational = true;
    assert!(
        f.factory
            .prepare(
                f.scope.clone(),
                different,
                &FixtureSandbox,
                &BTreeMap::new()
            )
            .await
            .unwrap_err()
            .contains("idempotency")
    );
}
#[tokio::test]
async fn ready_output_becomes_stale_and_cannot_be_claimed_after_source_write() {
    let f = Fixture::new();
    f.write("main", b"current");
    let job = f.recover(vec![], false).await;
    f.write("main", b"new source");
    let fresh = f
        .factory
        .refresh(
            f.scope.clone(),
            job.id.clone(),
            &FixtureSandbox,
            &BTreeMap::new(),
        )
        .await
        .unwrap();
    assert_eq!(fresh.state, "stale");
    assert!(fresh.output.is_none());
    assert!(
        f.factory
            .claim(
                f.scope.clone(),
                job.id,
                job.revision,
                true,
                &FixtureSandbox,
                &BTreeMap::new()
            )
            .await
            .is_err()
    );
    assert_eq!(fs::read(f.path("main")).unwrap(), b"new source");
}
#[tokio::test]
async fn a_recovery_workspace_has_one_writer_group_with_a_fenced_new_generation() {
    let f = Fixture::new();
    f.write("main", b"current");
    let job = f.recover(vec![], false).await;
    let ticket = f
        .factory
        .claim(
            f.scope.clone(),
            job.id.clone(),
            job.revision,
            true,
            &FixtureSandbox,
            &BTreeMap::new(),
        )
        .await
        .unwrap();
    let opened = f.journal.recovery_job(&f.scope, &job.id).unwrap();
    assert!(
        f.factory
            .claim(
                f.scope.clone(),
                job.id.clone(),
                opened.revision,
                true,
                &FixtureSandbox,
                &BTreeMap::new()
            )
            .await
            .unwrap_err()
            .contains("active writer")
    );
    drop(ticket);
    assert!(
        f.factory
            .claim(
                f.scope.clone(),
                job.id.clone(),
                job.revision,
                true,
                &FixtureSandbox,
                &BTreeMap::new()
            )
            .await
            .is_err()
    );
    let ticket = f
        .factory
        .claim(
            f.scope.clone(),
            job.id.clone(),
            opened.revision,
            true,
            &FixtureSandbox,
            &BTreeMap::new(),
        )
        .await
        .unwrap();
    assert!(ticket.generation() > opened.revision);
    let input = ticket.prepare_input("fresh-session".into(), f.state.join("sessions/fresh"), None);
    assert!(input.workspace_memory_file.is_none());
    assert!(input.project_files_dir.is_none());
    assert_eq!(input.workspace_root, ticket.root());
}
#[tokio::test]
async fn unopened_output_edits_or_identity_replacements_are_preserved_and_refused() {
    for replace in [false, true] {
        let f = Fixture::new();
        f.write("main", b"current");
        let job = f.recover(vec![], false).await;
        let output = job.output.as_ref().unwrap();
        if replace {
            fs::rename(output, output.with_file_name("user-saved")).unwrap();
            fs::create_dir(output).unwrap();
        }
        fs::write(output.join("main"), b"user in recovery").unwrap();
        assert!(
            f.factory
                .claim(
                    f.scope.clone(),
                    job.id,
                    job.revision,
                    true,
                    &FixtureSandbox,
                    &BTreeMap::new()
                )
                .await
                .is_err()
        );
        assert_eq!(fs::read(output.join("main")).unwrap(), b"user in recovery");
    }
}
#[tokio::test]
async fn retention_and_session_deletion_cannot_remove_recovery_inputs() {
    let f = Fixture::new();
    f.write("main", b"baseline");
    let op = f.operation("main", Some(b"after"));
    f.seal();
    let job = f.recover(vec![op], true).await;
    assert!(
        f.journal
            .delete_session("o", "s")
            .unwrap_err()
            .contains("retained recovery")
    );
    rusqlite::Connection::open(f.state.join("checkpoints/index.sqlite"))
        .unwrap()
        .execute("UPDATE captures SET created=0", [])
        .unwrap();
    f.journal.sweep().unwrap();
    assert_eq!(f.journal.operations(&f.scope).unwrap().len(), 1);
    assert_eq!(
        f.journal.read_blob(&digest(b"baseline")).unwrap(),
        b"baseline"
    );
    assert_eq!(read(&job, "main"), b"baseline");
}
#[tokio::test]
async fn restarted_journal_preserves_ready_jobs_and_marks_half_prepared_output_interrupted() {
    let f = Fixture::new();
    f.write("main", b"current");
    let request = f.request(vec![], false, "one").await;
    let job = f.prepare(request.clone()).await;
    let db = rusqlite::Connection::open(f.state.join("checkpoints/index.sqlite")).unwrap();
    db.execute("UPDATE recovery_jobs SET state='preparing'", [])
        .unwrap();
    drop(db);
    let Fixture {
        _dir,
        state,
        scope,
        journal,
        factory,
    } = f;
    drop(factory);
    drop(journal);
    let journal = Arc::new(Journal::open(&state, Limits::default()).unwrap());
    let factory = RecoveryFactory::new(journal.clone(), CopyLimits::default()).unwrap();
    let again = factory
        .prepare(scope, request, &FixtureSandbox, &BTreeMap::new())
        .await
        .unwrap();
    assert_eq!(again.id, job.id);
    assert_eq!(again.state, "interrupted");
    assert!(again.output.is_none());
    assert_eq!(
        fs::read(job.output.unwrap().join("main")).unwrap(),
        b"current"
    );
}
#[tokio::test]
async fn protocol_binding_operation_and_copy_limits_reject_without_allocating_a_workspace() {
    let f = Fixture::new();
    f.write("main", b"current");
    let request = f.request(vec![], false, "one").await;
    let mut bad = request.clone();
    bad.version = 99;
    assert!(
        f.factory
            .prepare(f.scope.clone(), bad, &FixtureSandbox, &BTreeMap::new())
            .await
            .unwrap_err()
            .contains("protocol")
    );
    let mut other = f.scope.clone();
    other.owner = "other".into();
    assert!(
        f.factory
            .prepare(other, request.clone(), &FixtureSandbox, &BTreeMap::new())
            .await
            .is_err()
    );
    let limits = CopyLimits {
        bytes: 3,
        node_bytes: 3,
        entries: 100,
        free_reserve: 0,
    };
    let small = RecoveryFactory::new(f.journal.clone(), limits).unwrap();
    assert!(
        small
            .preview(
                f.scope.clone(),
                request.selection.clone(),
                &FixtureSandbox,
                &BTreeMap::new()
            )
            .await
            .unwrap_err()
            .contains("byte limit")
    );
    let limited = RecoveryFactory::new(
        f.journal.clone(),
        CopyLimits {
            entries: 1,
            ..CopyLimits::default()
        },
    )
    .unwrap();
    f.write("second", b"x");
    assert!(
        limited
            .preview(
                f.scope.clone(),
                request.selection,
                &FixtureSandbox,
                &BTreeMap::new()
            )
            .await
            .unwrap_err()
            .contains("entry limit")
    );
    assert!(!f.state.join("checkpoints/workspaces").exists());
}
#[tokio::test]
async fn reservations_are_shared_and_unknown_files_are_never_deleted_by_gc() {
    let f = Fixture::with_limits(CopyLimits {
        bytes: 1024,
        node_bytes: 1024,
        entries: 100,
        free_reserve: 0,
    });
    f.write("main", b"ok");
    let job = f.recover(vec![], false).await;
    let request = f.request(vec![], false, "second").await;
    assert!(
        f.factory
            .prepare(f.scope.clone(), request, &FixtureSandbox, &BTreeMap::new())
            .await
            .unwrap_err()
            .contains("reservation budget")
    );
    let output = job.output.unwrap();
    fs::write(output.join("user-added"), b"preserve").unwrap();
    f.journal.sweep().unwrap();
    assert_eq!(fs::read(output.join("user-added")).unwrap(), b"preserve");
}
#[tokio::test]
async fn overlapping_operation_ranges_active_runs_and_cross_owner_evidence_are_refused() {
    let f = Fixture::new();
    f.write("main", b"before");
    let a = f.operation("main", Some(b"a"));
    let b = f.operation("main", Some(b"b"));
    let sel = Selection {
        operations: vec![a.clone()],
        review_observational: true,
    };
    assert!(
        f.factory
            .preview(f.scope.clone(), sel, &FixtureSandbox, &BTreeMap::new())
            .await
            .unwrap_err()
            .contains("still capturing")
    );
    f.seal();
    assert!(
        f.factory
            .preview(
                f.scope.clone(),
                Selection {
                    operations: vec![a.clone(), b],
                    review_observational: true
                },
                &FixtureSandbox,
                &BTreeMap::new()
            )
            .await
            .unwrap_err()
            .contains("overlapping")
    );
    let mut scope = f.scope.clone();
    scope.owner = "different".into();
    assert!(
        f.factory
            .preview(
                scope,
                Selection {
                    operations: vec![a],
                    review_observational: true
                },
                &FixtureSandbox,
                &BTreeMap::new()
            )
            .await
            .is_err()
    );
}

#[tokio::test]
async fn native_sandbox_keeps_source_private_store_and_other_recoveries_closed_and_holds_lease() {
    let path = std::env::var("PATH").unwrap_or_default();
    #[cfg(target_os = "linux")]
    if pirc_node::sandbox::linux::find_bwrap(&pirc_config::Env::new([("PATH", path.as_str())], "/"))
        .is_none()
    {
        assert!(
            std::env::var_os("PIRC_CHECKPOINT_NATIVE_REQUIRED").is_none(),
            "native recovery acceptance requires bubblewrap"
        );
        eprintln!("native recovery acceptance skipped: bubblewrap unavailable");
        return;
    }
    let mut f = Fixture::new();
    let home = f.scope.root.parent().unwrap().join("home");
    let config_dir = f.scope.root.parent().unwrap().join("config");
    let tmp = tempfile::Builder::new()
        .prefix("p3-")
        .tempdir_in("/tmp")
        .unwrap();
    fs::create_dir(&home).unwrap();
    fs::create_dir(&config_dir).unwrap();
    fs::write(config_dir.join("config.json"),serde_json::json!({"allowedPaths":[f.scope.root],"sandbox":{"filesystem":{"allowWrite":[f.scope.root]}}}).to_string()).unwrap();
    let env = pirc_config::Env::new(
        [
            ("HOME", home.to_str().unwrap()),
            ("TMPDIR", tmp.path().to_str().unwrap()),
            ("PIRC_NODE_ID", "n"),
            ("PIRC_NODE_TOKEN", "0123456789abcdef0123456789abcdef"),
            ("PIRC_DAEMON_URL", "ws://127.0.0.1:8787"),
            ("PIRC_ALLOWED_USERS", "o"),
            ("PIRC_STATE_DIR", f.state.to_str().unwrap()),
            ("PIRC_CONFIG_DIR", config_dir.to_str().unwrap()),
            ("PIRC_BROWSER", "false"),
            ("PATH", path.as_str()),
        ],
        f._dir.path(),
    );
    let mut config = pirc_config::NodeConfig::load(&env, pirc_protocol::NodeRole::Node).unwrap();
    config.agent_command = "/bin/sh".into();
    config.agent_args.clear();
    pirc_config::registry::register_node(&config, &env, None).unwrap();
    #[cfg(target_os = "macos")]
    let sandbox: Arc<dyn Sandbox> = Arc::new(pirc_node::sandbox::macos::MacSandbox::new(
        config.clone(),
        env.clone(),
    ));
    #[cfg(target_os = "linux")]
    let sandbox: Arc<dyn Sandbox> = Arc::new(pirc_node::sandbox::linux::NativeSandbox::new(
        config.clone(),
        env.clone(),
        env!("CARGO_BIN_EXE_pirc-node").into(),
    ));
    assert!(
        matches!(sandbox.check().await, SandboxStatus::Active { .. }),
        "native recovery enforcement unavailable"
    );
    let source_prepared = sandbox
        .prepare(PrepareInput {
            grants: Vec::new(),
            session_id: "source".into(),
            workspace_root: f.scope.root.clone(),
            session_dir: config.sessions_dir.join("source"),
            inference_socket: None,
            protected_paths: vec![],
            workspace_memory_file: None,
            project_files_dir: None,
            recovery: None,
        })
        .await
        .unwrap();
    f.scope.policy = source_prepared.policy.paths.clone();
    source_prepared.cleanup();
    f.write("main", b"source");
    let job = f.recover(vec![], false).await;
    let second = f.prepare(f.request(vec![], false, "second").await).await;
    let ticket = f
        .factory
        .claim(
            f.scope.clone(),
            job.id.clone(),
            job.revision,
            true,
            &FixtureSandbox,
            &BTreeMap::new(),
        )
        .await
        .unwrap();
    let root = ticket.root().to_owned();
    let mut input = ticket.prepare_input("fresh".into(), config.sessions_dir.join("fresh"), None);
    // A changed effective source deny must carry over to the new location.
    // Ticket source policy already binds the effective pre-copy policy.
    let mut ordinary = input.clone();
    ordinary.recovery = None;
    assert!(sandbox.prepare(ordinary).await.is_err());
    let public_tmp = tmp.path().canonicalize().unwrap().join("user-file");
    fs::write(&public_tmp, b"user tmp").unwrap();
    let prepared = sandbox.prepare(input.clone()).await.unwrap();
    assert!(!pirc_policy::write_allowed(
        &prepared.policy.paths,
        f.path("main").to_str().unwrap()
    ));
    assert!(!pirc_policy::read_allowed(
        &prepared.policy.paths,
        f.state.join("checkpoints/index.sqlite").to_str().unwrap()
    ));
    assert!(!pirc_policy::read_allowed(
        &prepared.policy.paths,
        second
            .output
            .as_ref()
            .unwrap()
            .join("main")
            .to_str()
            .unwrap()
    ));
    assert!(
        pirc_policy::write_allowed(&prepared.policy.paths, root.join("main").to_str().unwrap()),
        "policy {:?}",
        prepared.policy.paths
    );
    input.recovery = None;
    drop(input);
    drop(ticket);
    let opened = f.journal.recovery_job(&f.scope, &job.id).unwrap();
    assert!(
        f.factory
            .claim(
                f.scope.clone(),
                job.id.clone(),
                opened.revision,
                true,
                &FixtureSandbox,
                &BTreeMap::new()
            )
            .await
            .unwrap_err()
            .contains("active writer")
    );
    let mut command = prepared.command().unwrap();
    command.args([
        "-c",
        r#"printf 'candidate edited' > main || exit 11
if printf 'bad' > "$1" 2>/dev/null; then exit 12; fi
if cat "$2" >/dev/null 2>&1; then exit 13; fi
if cat "$3" >/dev/null 2>&1; then exit 14; fi
if printf 'bad' > "$4" 2>/dev/null; then exit 15; fi
"#,
        "p3",
        f.path("main").to_str().unwrap(),
        f.state.join("checkpoints/index.sqlite").to_str().unwrap(),
        second
            .output
            .as_ref()
            .unwrap()
            .join("main")
            .to_str()
            .unwrap(),
        public_tmp.to_str().unwrap(),
    ]);
    command
        .current_dir(&root)
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .env("HOME", &home)
        .envs(prepared.env.iter().map(|(k, v)| (k, v)))
        .kill_on_drop(true);
    let output = tokio::time::timeout(std::time::Duration::from_secs(20), command.output())
        .await
        .unwrap()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(fs::read(f.path("main")).unwrap(), b"source");
    assert_eq!(fs::read(root.join("main")).unwrap(), b"candidate edited");
    prepared.cleanup();
    assert_eq!(fs::read(&public_tmp).unwrap(), b"user tmp");
    let next = f
        .factory
        .claim(
            f.scope.clone(),
            job.id,
            opened.revision,
            true,
            &FixtureSandbox,
            &BTreeMap::new(),
        )
        .await
        .unwrap();
    f.write("main", b"later user edit");
    assert!(
        sandbox
            .prepare(next.prepare_input(
                "later-session".into(),
                config.sessions_dir.join("later-session"),
                None
            ))
            .await
            .is_err()
    );
    assert_eq!(fs::read(f.path("main")).unwrap(), b"later user edit");
}

#[tokio::test]
async fn missing_retained_evidence_fails_closed_without_removing_the_output() {
    let f = Fixture::new();
    f.write("main", b"baseline");
    let op = f.operation("main", Some(b"after"));
    f.seal();
    let job = f.recover(vec![op], true).await;
    fs::remove_file(f.state.join("checkpoints/blobs").join(digest(b"after"))).unwrap();
    assert!(
        f.journal
            .recovery_job(&f.scope, &job.id)
            .unwrap_err()
            .contains("missing or corrupt")
    );
    assert_eq!(
        fs::read(job.output.unwrap().join("main")).unwrap(),
        b"baseline"
    );
}
#[tokio::test]
async fn unresolved_paths_need_an_explicit_keep_current_decision() {
    let f = Fixture::new();
    f.write("main", b"baseline");
    let op = f.operation("main", Some(b"after"));
    f.seal();
    let job = f.recover(vec![op], false).await;
    assert!(
        f.factory
            .claim(
                f.scope.clone(),
                job.id,
                job.revision,
                false,
                &FixtureSandbox,
                &BTreeMap::new()
            )
            .await
            .unwrap_err()
            .contains("explicit keep-current")
    );
}

#[tokio::test]
async fn opened_isolated_workspaces_can_be_checkpointed_and_recovered_into_new_sibling_roots() {
    let f = Fixture::new();
    f.write("main", b"original");
    let job = f.recover(vec![], false).await;
    let ticket = f
        .factory
        .claim(
            f.scope.clone(),
            job.id.clone(),
            job.revision,
            true,
            &FixtureSandbox,
            &BTreeMap::new(),
        )
        .await
        .unwrap();
    let mut isolated = f.scope.clone();
    isolated.root = ticket.root().to_owned();
    isolated.workspace = "independent".into();
    isolated.session = "new-session".into();
    isolated.run = "new-run".into();
    isolated.policy = PathPolicy {
        allow_write: vec![isolated.root.to_string_lossy().into_owned()],
        ..Default::default()
    };
    let isolated = isolated.bind_root().unwrap();
    let op = f
        .journal
        .begin(&isolated, &isolated.root.join("main"), "write", None)
        .unwrap();
    fs::write(isolated.root.join("main"), b"second agent").unwrap();
    f.journal.finish(&isolated, &op, true).unwrap();
    f.journal
        .seal(
            &isolated.session,
            isolated.epoch,
            Some(&isolated.run),
            false,
        )
        .unwrap();
    let selection = Selection {
        operations: vec![op],
        review_observational: true,
    };
    let preview = f
        .factory
        .preview(
            isolated.clone(),
            selection.clone(),
            &FixtureSandbox,
            &BTreeMap::new(),
        )
        .await
        .unwrap();
    let recovered = f
        .factory
        .prepare(
            isolated.clone(),
            PrepareRequest {
                version: 1,
                key: "nested-recovery".into(),
                preview_revision: preview.revision,
                selection,
            },
            &FixtureSandbox,
            &BTreeMap::new(),
        )
        .await
        .unwrap();
    assert_eq!(read(&recovered, "main"), b"original");
    assert!(!recovered.output.unwrap().starts_with(&isolated.root));
    assert_eq!(
        fs::read(isolated.root.join("main")).unwrap(),
        b"second agent"
    );
    assert_eq!(fs::read(f.path("main")).unwrap(), b"original");
}
