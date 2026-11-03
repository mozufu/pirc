//! Workspace inspection for the panels (`node/inspect.ts`): git through the
//! `git` executable and files with realpath containment. Owner: **panels**
//! (M6); M7: **hardening** (git in the sandbox).
//!
//! git: `git --no-pager -c core.quotepath=false -c core.fsmonitor=false -c
//! color.ui=false <args>`, no shell, `cwd` the real root, the environment
//! `without_secrets` plus `GIT_OPTIONAL_LOCKS=0`, `GIT_TERMINAL_PROMPT=0`,
//! `GIT_PAGER=cat`, `LC_ALL=C`; stdout capped at 1 MiB (`truncated`); after
//! 15 s (TS: SIGKILL to git) the sandbox wrapper's process group is
//! SIGKILLed, and output still arriving is read for at most 1 s more
//! (`KILL_DRAIN`); exit codes other than 0 and 1 are 400 with the last
//! three stderr lines, but a sandbox that failed before git ran is 503
//! [`git_unavailable`] ([`Prepared::wrapper_failure`]). Rust-only (security
//! audit S8): git runs in the node's sandbox, read-only and without
//! network ([`Sandbox::prepare_readonly`]), with Git LFS's storage in the
//! sandbox's temp directory (`lfs_storage`); without a working sandbox
//! every git route is 503 [`git_unavailable`], where TS ran git on the
//! host. Files: `resolve_inside` (404 for a missing path or an absolute one
//! outside, 403 for a relative or symlink escape, 400 for NUL),
//! directory listings without `.git`, dirs first in `localeCompare` order
//! (the agent's `ls` ordering), 2000 entries; file reads with the 1 MiB
//! text and 8 MiB image limits.
//!
//! Path arithmetic is Node's `path` (lexical `..` in `path.resolve`, then
//! `realpath`), not `Path::join` plus `canonicalize`, which would resolve
//! `..` after following symlinks.

use std::collections::BTreeMap;
use std::ffi::OsString;
use std::io::{Read as _, Seek as _, SeekFrom};
use std::os::unix::fs::MetadataExt as _;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::LazyLock;
use std::time::Duration;

use base64::Engine as _;
use pirc_agent::messages::js::{number_value, path_normalize, path_resolve};
use pirc_agent::tools::js::{dirname, extname, name_order, relative, trim};
use regex_lite::Regex;
use serde_json::{Map, Value, json};
use tokio::io::AsyncReadExt as _;

use super::access;
use crate::error::{ApiError, ApiResult};
use crate::sandbox::{Prepared, ReadonlyInput, Sandbox, SandboxStatus};

const GIT_TIMEOUT: Duration = Duration::from_secs(15);
const DIFF_LIMIT: usize = 1_048_576;
const FILE_LIMIT: usize = 1_048_576;
const DIR_LIMIT: usize = 2_000;
/// Files `git status` reports at most.
const STATUS_LIMIT: usize = 5_000;
/// Base64 grows this by a third; it must stay well under the link's frame limit.
const IMAGE_LIMIT: u64 = 8 * 1_048_576;
/// Bytes `binary` looks at for a NUL.
const BINARY_SNIFF: usize = 8192;

/// The environment git runs with: `without_secrets` of the node's.
pub type ChildEnv = BTreeMap<String, String>;

/// An unexpected failure (TS threw something that was not an `ApiError`,
/// and Fastify answered 500): logged, never shown.
fn internal(what: &str, error: impl std::fmt::Display) -> ApiError {
    crate::log::error(&format!("{what}: {error}"));
    ApiError::internal()
}

fn display(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}

// ---------------------------------------------------------------------------
// git

struct GitResult {
    stdout: String,
    truncated: bool,
    exit_code: i32,
    timed_out: bool,
}

/// Coverage classification only. Always run repository Git in the existing
/// read-only sandbox; never execute host Git against an agent-writable config.
pub(crate) async fn checkpoint_eligible(
    sandbox: &dyn Sandbox,
    root: &Path,
    relative: &str,
    env: &ChildEnv,
) -> ApiResult<bool> {
    let result = git(
        sandbox,
        root,
        &["check-ignore", "--quiet", "--", relative],
        env,
    )
    .await
    .map_err(ApiError::from)?;
    if result.truncated || result.timed_out || !matches!(result.exit_code, 0 | 1) {
        return Err(ApiError::bad_request(
            "Checkpoint Git eligibility is unavailable",
        ));
    }
    Ok(result.exit_code == 1) // tracked files are not ignored by check-ignore
}

/// Complete eligibility list for checkpoint copies. No checkout, filters or hooks.
pub(crate) async fn checkpoint_files(
    sandbox: &dyn Sandbox,
    root: &Path,
    env: &ChildEnv,
) -> ApiResult<std::collections::BTreeSet<String>> {
    let result = git(
        sandbox,
        root,
        &[
            "ls-files",
            "-z",
            "--cached",
            "--others",
            "--exclude-standard",
        ],
        env,
    )
    .await
    .map_err(ApiError::from)?;
    if result.truncated
        || result.timed_out
        || result.exit_code != 0
        || result.stdout.contains('\u{fffd}')
    {
        return Err(ApiError::bad_request(
            "Complete checkpoint Git eligibility is unavailable",
        ));
    }
    Ok(result
        .stdout
        .split('\0')
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
        .collect())
}

/// Why git did not give a result.
enum GitError {
    /// Revocation/staleness is never a successful empty repository.
    Authority(ApiError),
    /// 400 from its exit code (or anything the caller answers as such).
    Api(ApiError),
    /// It could not start (TS: `Bun.spawn` threw).
    Spawn(std::io::Error),
    /// No sandbox to run it in (503), or the sandbox could not be prepared:
    /// always the answer, never read as "not a repository".
    Sandbox(ApiError),
}

impl From<GitError> for ApiError {
    fn from(error: GitError) -> Self {
        match error {
            GitError::Api(error) | GitError::Sandbox(error) | GitError::Authority(error) => error,
            GitError::Spawn(error) => internal("git could not start", error),
        }
    }
}

/// 503 `runner_unavailable` when git cannot run in the sandbox (S8): the
/// Git panel is unavailable on this node, for the reason agents are.
pub fn git_unavailable(reason: &str) -> ApiError {
    ApiError::runner_unavailable(format!(
        "The Git panel runs git in the sandbox, and it is unavailable on this node: {reason}"
    ))
}

/// SIGKILL the process group `pid` leads until it has been reaped: the
/// sandbox wrapper's. What git runs ends with it, though not always as a
/// member of the group: `sandbox-exec` execs git in place, so git and its
/// filters are in the group; bubblewrap (native, and srt's on Linux) starts
/// git in a session of its own (`--new-session`), which ends because
/// bubblewrap dies (`--die-with-parent`) and with it the PID namespace's
/// init, which takes every process of the namespace along.
struct Group(Option<i32>);

impl Group {
    fn kill(&self) {
        if let Some(pid) = self.0 {
            let _ = nix::sys::signal::killpg(
                nix::unistd::Pid::from_raw(pid),
                nix::sys::signal::Signal::SIGKILL,
            );
        }
    }
}

impl Drop for Group {
    fn drop(&mut self) {
        self.kill();
    }
}

/// How long output is still read after git was killed: a process that
/// left the group may hold the pipes.
const KILL_DRAIN: Duration = Duration::from_secs(1);

/// `git <args>` in `root`, inside the sandbox
/// ([`Sandbox::prepare_readonly`]: `root`'s read policy, nothing writable
/// but a temp directory, no network). The repository is agent-writable:
/// its config, attributes and hooks are the agent's, so whatever they make
/// git run stays in the sandbox (security audit S8), and never sees the
/// node token (the environment is the caller's `without_secrets`).
///
/// The sandbox wrapper runs in a process group of its own, killed as a
/// whole on the timeout, the output cap or a dropped request; output still
/// arriving from outside the group is read for at most [`KILL_DRAIN`].
async fn git(
    sandbox: &dyn Sandbox,
    root: &Path,
    args: &[&str],
    env: &ChildEnv,
) -> Result<GitResult, GitError> {
    access::check().map_err(GitError::Authority)?;
    let status = sandbox.check().await;
    access::check().map_err(GitError::Authority)?;
    if let SandboxStatus::Unavailable { reason } = status {
        return Err(GitError::Sandbox(git_unavailable(&reason)));
    }
    let command: Vec<OsString> = [
        "git",
        "--no-pager",
        "-c",
        "core.quotepath=false",
        "-c",
        "core.fsmonitor=false",
        "-c",
        "color.ui=false",
    ]
    .iter()
    .chain(args)
    .map(OsString::from)
    .collect();
    let prepared = sandbox
        .prepare_readonly(ReadonlyInput {
            workspace_root: root.to_path_buf(),
            command,
        })
        .await;
    access::check().map_err(GitError::Authority)?;
    let prepared = prepared.map_err(|error| {
        // Refused after the probe passed (a plan refusal, a profile too
        // long): the Git panel's words, not an agent start's.
        GitError::Sandbox(match crate::sandbox::unavailable_reason(&error) {
            Some(reason) => git_unavailable(reason),
            None => error,
        })
    })?;
    let result = run_prepared(&prepared, root, env, GIT_TIMEOUT).await;
    prepared.cleanup();
    result
}

/// `-c lfs.storage=<temp_dir>/lfs`, as environment variables. Git LFS's
/// clean filter (`filter.lfs.process`, `required`), which `status` and
/// `diff` run on every changed LFS file, writes the object into
/// `lfs.storage` (`.git/lfs` by default). The read-only sandbox refuses
/// that, and a required filter's failure fails git (400 for the whole
/// status). Pointed at the sandbox's temp directory, the filter works and
/// the panel shows what the host shows. Through `GIT_CONFIG_COUNT` (git
/// 2.31; the same scope as `-c`) because the command line is fixed before
/// the sandbox, and its temp directory, exist; after any pairs the
/// node's environment already has.
///
/// Other filters that write into the repository have no such setting
/// (git-annex's `.git/annex`): a required one still fails the request with
/// git's message. The fallback, if one turns out to matter, is
/// `filter.<name>.required=false`: git then compares the raw content, so
/// status still works and its diff reads "Binary files differ".
fn lfs_storage(env: &ChildEnv, temp_dir: &Path) -> [(String, String); 3] {
    let index = env
        .get("GIT_CONFIG_COUNT")
        .and_then(|count| count.trim().parse::<usize>().ok())
        .unwrap_or(0);
    [
        (format!("GIT_CONFIG_KEY_{index}"), "lfs.storage".to_owned()),
        (
            format!("GIT_CONFIG_VALUE_{index}"),
            display(&temp_dir.join("lfs")),
        ),
        ("GIT_CONFIG_COUNT".to_owned(), (index + 1).to_string()),
    ]
}

/// Run a prepared git with `timeout` (15 s; shorter in tests).
async fn run_prepared(
    prepared: &Prepared,
    cwd: &Path,
    env: &ChildEnv,
    timeout: Duration,
) -> Result<GitResult, GitError> {
    let limit = DIFF_LIMIT;
    let mut command = prepared.command().map_err(GitError::Spawn)?;
    command
        .current_dir(cwd)
        .env_clear()
        .envs(env)
        .env("GIT_OPTIONAL_LOCKS", "0")
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_PAGER", "cat")
        .env("LC_ALL", "C")
        .envs(prepared.env.iter().cloned())
        .envs(
            prepared
                .temp_dir()
                .map(|temp_dir| lfs_storage(env, temp_dir))
                .into_iter()
                .flatten(),
        )
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .process_group(0)
        .kill_on_drop(true);
    let mut child = access::run(|| Ok(command.spawn()))
        .map_err(GitError::Authority)?
        .map_err(GitError::Spawn)?;
    let mut group = Group(child.id().and_then(|pid| i32::try_from(pid).ok()));
    let mut stdout = child.stdout.take().expect("piped stdout");
    let mut stderr = child.stderr.take().expect("piped stderr");
    // Read concurrently, so a chatty stderr never blocks git (TS read it
    // after stdout, without a bound).
    let mut stderr = tokio::spawn(async move {
        let mut bytes = Vec::new();
        let _ = stderr.read_to_end(&mut bytes).await;
        bytes
    });
    let timer = tokio::time::sleep(timeout);
    tokio::pin!(timer);
    let mut timed_out = false;
    let mut revoked = None;
    let mut authority_poll = tokio::time::interval(Duration::from_millis(50));
    authority_poll.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    let mut out = Vec::new();
    let mut truncated = false;
    let mut chunk = vec![0; 64 * 1024];
    loop {
        tokio::select! {
            _ = authority_poll.tick() => {
                if let Err(error) = access::check() {
                    revoked = Some(error);
                    group.kill();
                    break;
                }
            },
            read = stdout.read(&mut chunk) => match read {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    if out.len() + n > limit {
                        out.extend_from_slice(&chunk[..limit - out.len()]);
                        truncated = true;
                        group.kill();
                        break;
                    }
                    out.extend_from_slice(&chunk[..n]);
                }
            },
            () = &mut timer => {
                if timed_out {
                    break;
                }
                timed_out = true;
                group.kill();
                timer.as_mut().reset(tokio::time::Instant::now() + KILL_DRAIN);
            }
        }
    }
    drop(stdout);
    let status = loop {
        tokio::select! {
            status = child.wait() => break status,
            _ = authority_poll.tick(), if revoked.is_none() => {
                if let Err(error) = access::check() {
                    revoked = Some(error);
                    group.kill();
                }
            },
            () = &mut timer, if !timed_out => {
                timed_out = true;
                group.kill();
            }
        }
    };
    // Reaped: its pid (the group's id) may be reused from now on.
    group.0 = None;
    let stderr = match tokio::time::timeout(KILL_DRAIN, &mut stderr).await {
        Ok(bytes) => bytes.unwrap_or_default(),
        Err(_) => {
            stderr.abort();
            Vec::new()
        }
    };
    if let Some(error) = revoked {
        return Err(GitError::Authority(error));
    }
    access::check().map_err(GitError::Authority)?;
    // Bun's `exited` is 128 + the signal for a killed process.
    let code = match status {
        Ok(status) => {
            use std::os::unix::process::ExitStatusExt as _;
            status
                .code()
                .unwrap_or_else(|| 128 + status.signal().unwrap_or(0))
        }
        Err(error) => return Err(GitError::Spawn(error)),
    };
    // The sandbox's own failure (it exits 1, as git's "no" does): 503,
    // never a clean repository, an empty history or an empty diff.
    if code != 0
        && !truncated
        && !timed_out
        && let Some(reason) = prepared.wrapper_failure(code, &String::from_utf8_lossy(&stderr))
    {
        return Err(GitError::Sandbox(git_unavailable(&reason)));
    }
    if code != 0 && !truncated && code != 1 {
        let stderr = String::from_utf8_lossy(&stderr);
        let lines: Vec<&str> = trim(&stderr).split('\n').collect();
        let message = lines[lines.len().saturating_sub(3)..].join("\n");
        let message = if message.is_empty() {
            format!("git exited with {code}")
        } else {
            message
        };
        return Err(GitError::Api(ApiError::bad_request(message)));
    }
    Ok(GitResult {
        stdout: String::from_utf8_lossy(&out).into_owned(),
        truncated,
        exit_code: code,
        timed_out,
    })
}

fn real_root(root: &Path) -> ApiResult<PathBuf> {
    std::fs::canonicalize(root).map_err(|_| ApiError::not_found("Workspace directory is missing"))
}

/// Whether `real` (canonical) is `root` (canonical) or inside it.
fn inside(root: &Path, real: &Path) -> bool {
    real.starts_with(root)
}

/// `resolveInside`: `relative` inside `root`, symlinks followed; escapes
/// refused. An absolute path that resolves inside is accepted (agents cite
/// those); any other is taken as workspace-relative, so an absolute path
/// outside is a 404 (TS), not a 403.
pub fn resolve_inside(root: &Path, relative: &str) -> ApiResult<PathBuf> {
    if relative.contains('\0') {
        return Err(ApiError::bad_request("Invalid path"));
    }
    let root = real_root(root)?;
    if relative.starts_with('/')
        && let Ok(real) = std::fs::canonicalize(relative)
        && inside(&root, &real)
    {
        return Ok(real);
    }
    let joined = path_resolve(&[&display(&root), relative.trim_start_matches('/')]);
    let real = std::fs::canonicalize(&joined).map_err(|_| ApiError::not_found("Path not found"))?;
    if !inside(&root, &real) {
        return Err(ApiError::forbidden("Path is outside the workspace"));
    }
    Ok(real)
}

/// `pathspec`: a git pathspec that never expands magic or globs; its
/// directory must resolve inside the workspace (deleted files are fine).
fn pathspec(root: &Path, relative: &str) -> ApiResult<String> {
    let normalized = path_normalize(&relative.replace('\\', "/"));
    let normalized = normalized.trim_start_matches('/');
    if normalized.is_empty()
        || normalized == "."
        || normalized == ".."
        || normalized.starts_with("../")
    {
        return Err(ApiError::bad_request("Invalid path"));
    }
    resolve_inside(root, &dirname(normalized))?;
    Ok(format!(":(literal){normalized}"))
}

/// `git rev-parse` and `git status` of the workspace: `{repo:false}`, or
/// the branch, its upstream and the changed files (at most 5000).
pub async fn git_status(sandbox: &dyn Sandbox, root: &Path, env: &ChildEnv) -> ApiResult<Value> {
    let root = access::run(|| real_root(root))?;
    let top = match git(sandbox, &root, &["rev-parse", "--show-toplevel"], env).await {
        Ok(top) => top,
        Err(GitError::Sandbox(error) | GitError::Authority(error)) => return Err(error),
        Err(_) => return Ok(json!({ "repo": false })),
    };
    let top = trim(&top.stdout).to_owned();
    let status = git(
        sandbox,
        &root,
        &[
            "status",
            "--porcelain=v1",
            "-z",
            "--branch",
            "--untracked-files=all",
            "--",
            ".",
        ],
        env,
    )
    .await?;
    let mut parsed = parse_status(&status.stdout);
    let prefix = relative(&top, &display(&root));
    let truncated = parsed.files.len() > STATUS_LIMIT;
    parsed.files.truncate(STATUS_LIMIT);
    Ok(json!({
        "repo": true,
        "root": prefix,
        "branch": parsed.branch,
        "upstream": parsed.upstream,
        "ahead": parsed.ahead,
        "behind": parsed.behind,
        "files": parsed.files,
        "truncated": truncated,
    }))
}

#[derive(Debug, Default, PartialEq)]
struct Status {
    branch: Option<String>,
    upstream: Option<String>,
    ahead: u64,
    behind: u64,
    files: Vec<Value>,
}

static HEADER: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^(.*?)(?:\.\.\.(\S+))?(?: \[(.*)\])?$").expect("header regex"));
static AHEAD: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"ahead (\d+)").expect("regex"));
static BEHIND: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"behind (\d+)").expect("regex"));

/// `git status --porcelain=v1 -z --branch`: the `## ` header, then `XY
/// path` records; a rename or copy carries its original path as the next
/// record.
fn parse_status(stdout: &str) -> Status {
    let mut status = Status::default();
    let records: Vec<&str> = stdout.split('\0').collect();
    let mut index = 0;
    while index < records.len() {
        let record = records[index];
        index += 1;
        if record.is_empty() {
            continue;
        }
        if let Some(header) = record.strip_prefix("## ") {
            let captures = HEADER.captures(header);
            let group = |n: usize| captures.as_ref().and_then(|c| c.get(n)).map(|m| m.as_str());
            let branch = group(1).unwrap_or(header);
            let branch = branch.strip_prefix("No commits yet on ").unwrap_or(branch);
            status.branch = Some(branch.to_owned());
            status.upstream = group(2).map(str::to_owned);
            let counts = group(3).unwrap_or("");
            let count = |regex: &Regex| {
                regex
                    .captures(counts)
                    .and_then(|c| c.get(1))
                    .map_or(0, |m| m.as_str().parse().unwrap_or(0))
            };
            status.ahead = count(&AHEAD);
            status.behind = count(&BEHIND);
            continue;
        }
        let mut chars = record.chars();
        let x = chars.next().unwrap_or(' ');
        let y = chars.next().unwrap_or(' ');
        let path = record
            .char_indices()
            .nth(3)
            .map_or("", |(at, _)| &record[at..]);
        let mut file = Map::new();
        file.insert("path".into(), json!(path));
        file.insert("index".into(), json!(x.to_string()));
        file.insert("worktree".into(), json!(y.to_string()));
        if x == 'R' || x == 'C' {
            let original = records.get(index).copied().unwrap_or("");
            index += 1;
            file.insert("origPath".into(), json!(original));
        }
        status.files.push(Value::Object(file));
    }
    status
}

/// A unified diff of one path or the whole workspace: worktree against the
/// index, or index against HEAD when `staged`; an untracked file against
/// `/dev/null` (`staged` ignored).
pub async fn git_diff(
    sandbox: &dyn Sandbox,
    root: &Path,
    env: &ChildEnv,
    path: Option<&str>,
    staged: bool,
    untracked: bool,
) -> ApiResult<Value> {
    let base = ["diff", "--no-color", "--no-ext-diff", "--no-textconv", "-M"];
    let root = access::run(|| real_root(root))?;
    // `path` is falsy when empty (TS), so `?path=` is the whole workspace.
    let path = path.filter(|path| !path.is_empty());
    if untracked && let Some(path) = path {
        let (file, is_file) = access::run(|| {
            let file = resolve_inside(&root, path)?;
            let is_file = std::fs::metadata(&file)
                .map_err(|error| internal("stat", error))?
                .is_file();
            Ok((file, is_file))
        })?;
        if !is_file {
            return Err(ApiError::bad_request("Not a file"));
        }
        let relative = relative(&display(&root), &display(&file));
        let mut args = base.to_vec();
        args.extend(["--no-index", "--", "/dev/null", &relative]);
        let result = git(sandbox, &root, &args, env).await?;
        return Ok(json!({ "diff": result.stdout, "truncated": result.truncated }));
    }
    let spec = match path {
        Some(path) => access::run(|| pathspec(&root, path))?,
        None => ".".to_owned(),
    };
    let mut args = base.to_vec();
    if staged {
        args.push("--cached");
    }
    args.extend(["--", &spec]);
    let result = git(sandbox, &root, &args, env).await?;
    Ok(json!({ "diff": result.stdout, "truncated": result.truncated }))
}

/// `Number(text)` of git's output, as a JSON number.
fn js_number_text(text: &str) -> f64 {
    crate::panels::js_number_of_str(text)
}

fn refs(text: Option<&str>) -> Vec<String> {
    match text {
        Some(text) if !text.is_empty() => text
            .split(", ")
            .filter(|part| !part.is_empty())
            .map(str::to_owned)
            .collect(),
        _ => Vec::new(),
    }
}

/// One page of the workspace's history; none without a HEAD.
pub async fn git_log(
    sandbox: &dyn Sandbox,
    root: &Path,
    env: &ChildEnv,
    skip: u64,
    limit: u64,
) -> ApiResult<Value> {
    // Not `real_root` (TS): a missing workspace fails to spawn, which reads
    // as no history.
    match git(
        sandbox,
        root,
        &["rev-parse", "--verify", "--quiet", "HEAD"],
        env,
    )
    .await
    {
        Ok(_) => {}
        Err(GitError::Sandbox(error) | GitError::Authority(error)) => return Err(error),
        Err(_) => return Ok(json!({ "commits": [], "more": false })),
    }
    let max_count = format!("--max-count={}", limit + 1);
    let skip = format!("--skip={skip}");
    let result = git(
        sandbox,
        root,
        &[
            "log",
            &max_count,
            &skip,
            "--format=%H%x1f%h%x1f%an%x1f%ae%x1f%at%x1f%D%x1f%s%x1e",
            "--",
            ".",
        ],
        env,
    )
    .await?;
    let commits: Vec<Value> = result
        .stdout
        .split('\x1e')
        .map(trim)
        .filter(|line| !line.is_empty())
        .map(|line| {
            let fields: Vec<&str> = line.split('\x1f').collect();
            let field = |n: usize| fields.get(n).copied();
            let mut commit = Map::new();
            commit.insert("sha".into(), json!(field(0).unwrap_or("")));
            if let Some(short) = field(1) {
                commit.insert("short".into(), json!(short));
            }
            commit.insert("author".into(), json!(field(2).unwrap_or("")));
            commit.insert("email".into(), json!(field(3).unwrap_or("")));
            commit.insert(
                "time".into(),
                number_value(field(4).map_or(f64::NAN, js_number_text) * 1000.0),
            );
            commit.insert("refs".into(), json!(refs(field(5))));
            commit.insert("subject".into(), json!(field(6).unwrap_or("")));
            Value::Object(commit)
        })
        .collect();
    let more = commits.len() as u64 > limit;
    let commits: Vec<Value> = commits.into_iter().take(limit as usize).collect();
    Ok(json!({ "commits": commits, "more": more }))
}

static SHA: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^[0-9a-fA-F]{4,64}$").expect("regex"));

/// A commit's header, message and patch (with its `--stat`).
pub async fn git_show(
    sandbox: &dyn Sandbox,
    root: &Path,
    env: &ChildEnv,
    sha: &str,
) -> ApiResult<Value> {
    if !SHA.is_match(sha) {
        return Err(ApiError::bad_request("Invalid commit id"));
    }
    let header = git(
        sandbox,
        root,
        &[
            "show",
            "-s",
            "--format=%H%x1f%an%x1f%ae%x1f%at%x1f%D%x1f%B",
            sha,
            "--",
        ],
        env,
    )
    .await?;
    let fields: Vec<&str> = header.stdout.split('\x1f').collect();
    let field = |n: usize| fields.get(n).copied();
    let patch = git(
        sandbox,
        root,
        &[
            "show",
            "--no-color",
            "--no-ext-diff",
            "--no-textconv",
            "-M",
            "--format=",
            "--patch",
            "--stat=200",
            sha,
            "--",
        ],
        env,
    )
    .await?;
    let message = fields
        .get(5..)
        .map_or(String::new(), |body| body.join("\x1f"));
    Ok(json!({
        "sha": field(0).unwrap_or(""),
        "author": field(1).unwrap_or(""),
        "email": field(2).unwrap_or(""),
        "time": number_value(field(3).map_or(f64::NAN, js_number_text) * 1000.0),
        "refs": refs(field(4)),
        "message": trim(&message),
        "diff": patch.stdout,
        "truncated": patch.truncated,
    }))
}

// ---------------------------------------------------------------------------
// files

/// A directory of the workspace: `.git` left out, directories first, then
/// `localeCompare` order, at most 2000 entries.
pub fn list_directory(root: &Path, relative_path: &str) -> ApiResult<Value> {
    let root = real_root(root)?;
    let dir = resolve_inside(
        &root,
        if relative_path.is_empty() {
            "."
        } else {
            relative_path
        },
    )?;
    let metadata = std::fs::metadata(&dir).map_err(|error| internal("stat", error))?;
    if !metadata.is_dir() {
        return Err(ApiError::bad_request("Not a directory"));
    }
    let mut entries = Vec::new();
    for entry in std::fs::read_dir(&dir).map_err(|error| internal("readdir", error))? {
        let entry = entry.map_err(|error| internal("readdir", error))?;
        let name = entry.file_name().to_string_lossy().into_owned();
        if name == ".git" {
            continue;
        }
        let file_type = entry
            .file_type()
            .map_err(|error| internal("readdir", error))?;
        let mut kind = if file_type.is_dir() {
            "dir"
        } else if file_type.is_file() {
            "file"
        } else if file_type.is_symlink() {
            "symlink"
        } else {
            "other"
        };
        let full = dir.join(entry.file_name());
        let mut size = None;
        // A dangling link stays a symlink.
        if kind == "symlink" && std::fs::metadata(&full).is_ok_and(|m| m.is_dir()) {
            kind = "dir";
        }
        if kind == "file" {
            size = std::fs::symlink_metadata(&full).ok().map(|m| m.len());
        }
        entries.push((name, kind, size));
    }
    entries.sort_by(|a, b| match (a.1 == "dir", b.1 == "dir") {
        (true, false) => std::cmp::Ordering::Less,
        (false, true) => std::cmp::Ordering::Greater,
        _ => name_order(&a.0, &b.0),
    });
    let truncated = entries.len() > DIR_LIMIT;
    let entries: Vec<Value> = entries
        .into_iter()
        .take(DIR_LIMIT)
        .map(|(name, kind, size)| {
            let mut entry = Map::new();
            entry.insert("name".into(), json!(name));
            entry.insert("kind".into(), json!(kind));
            if let Some(size) = size {
                entry.insert("size".into(), json!(size));
            }
            Value::Object(entry)
        })
        .collect();
    Ok(json!({
        "path": relative(&display(&root), &display(&dir)),
        "entries": entries,
        "truncated": truncated,
    }))
}

/// Images the side panel previews, by extension; sent inline as base64.
fn image_type(extension: &str) -> Option<&'static str> {
    Some(match extension {
        ".png" => "image/png",
        ".jpg" | ".jpeg" => "image/jpeg",
        ".gif" => "image/gif",
        ".webp" => "image/webp",
        ".avif" => "image/avif",
        ".bmp" => "image/bmp",
        ".ico" => "image/x-icon",
        ".svg" => "image/svg+xml",
        _ => return None,
    })
}

/// `stat.mtimeMs`: fractional milliseconds.
pub(crate) fn mtime_ms(metadata: &std::fs::Metadata) -> Value {
    number_value(metadata.mtime() as f64 * 1000.0 + metadata.mtime_nsec() as f64 / 1e6)
}

/// Read up to `length` bytes from `offset`, as `readSync` in a loop: a file
/// that shrank leaves the rest zero (TS allocated the buffer first).
fn read_at(file: &Path, offset: u64, length: usize) -> std::io::Result<Vec<u8>> {
    read_handle_at(&mut std::fs::File::open(file)?, offset, length)
}

fn read_handle_at(
    handle: &mut std::fs::File,
    offset: u64,
    length: usize,
) -> std::io::Result<Vec<u8>> {
    let mut buffer = vec![0; length];
    handle.seek(SeekFrom::Start(offset))?;
    let mut read = 0;
    while read < length {
        match handle.read(&mut buffer[read..]) {
            Ok(0) => break,
            Ok(n) => read += n,
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
            Err(error) => return Err(error),
        }
    }
    Ok(buffer)
}

/// A file of the workspace: its text (first 1 MiB, unless it is binary),
/// an image inline (whole, up to 8 MiB), or `imageTooLarge`.
pub fn read_workspace_file(root: &Path, relative_path: &str) -> ApiResult<Value> {
    let root = real_root(root)?;
    let file = resolve_inside(&root, relative_path)?;
    let metadata = std::fs::metadata(&file).map_err(|error| internal("stat", error))?;
    if !metadata.is_file() {
        return Err(ApiError::bad_request("Not a file"));
    }
    let size = metadata.len();
    let path = display(&file);
    let mime_type = image_type(&extname(&path).to_lowercase());
    let inline_image = mime_type.is_some() && size <= IMAGE_LIMIT;
    let length = if inline_image {
        size
    } else {
        size.min(FILE_LIMIT as u64)
    };
    let buffer = read_at(&file, 0, length as usize).map_err(|error| internal("read", error))?;
    let binary = buffer[..buffer.len().min(BINARY_SNIFF)].contains(&0);
    let mut out = Map::new();
    out.insert("path".into(), json!(relative(&display(&root), &path)));
    out.insert("size".into(), json!(size));
    out.insert("modifiedAt".into(), mtime_ms(&metadata));
    out.insert("binary".into(), json!(binary));
    out.insert("truncated".into(), json!(size > FILE_LIMIT as u64));
    if !binary {
        let text = &buffer[..buffer.len().min(FILE_LIMIT)];
        out.insert("content".into(), json!(String::from_utf8_lossy(text)));
    }
    match mime_type {
        Some(mime_type) if inline_image => {
            out.insert(
                "image".into(),
                json!({
                    "mimeType": mime_type,
                    "dataBase64": base64::engine::general_purpose::STANDARD.encode(&buffer),
                }),
            );
        }
        // Oversized images fall back to the plain file view.
        Some(_) => {
            out.insert("imageTooLarge".into(), json!(true));
        }
        None => {}
    }
    Ok(Value::Object(out))
}

/// `readRecordingChunk` (`panel-routes.ts`): a chunk of a browser
/// recording, base64. The route's pattern (`.pirc/recordings/<name>.webm`)
/// is checked by the caller; the file must also resolve inside the
/// workspace, like other panel reads, so a symlink tracked in a cloned
/// repository cannot point the panel at any file the node can read. Escapes
/// are 404s, as for a missing recording.
pub fn read_recording_chunk(
    root: &Path,
    relative_path: &str,
    offset: u64,
    length: u64,
) -> ApiResult<Value> {
    let not_found = || ApiError::not_found("Recording not found");
    let file = resolve_inside(root, relative_path).map_err(|_| not_found())?;
    // Size and bytes come from one open file, not a second path lookup.
    let mut handle = std::fs::File::open(&file).map_err(|_| not_found())?;
    let metadata = handle.metadata().map_err(|_| not_found())?;
    if !metadata.is_file() {
        return Err(not_found());
    }
    let size = metadata.len();
    let start = offset.min(size);
    let length = length.min(size - start) as usize;
    let buffer =
        read_handle_at(&mut handle, start, length).map_err(|error| internal("read", error))?;
    Ok(json!({
        "size": size,
        "offset": start,
        "mimeType": "video/webm",
        "dataBase64": base64::engine::general_purpose::STANDARD.encode(&buffer),
    }))
}

#[cfg(test)]
mod tests;
