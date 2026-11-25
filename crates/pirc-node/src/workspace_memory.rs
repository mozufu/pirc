//! Host-authorized repository memory. Caller identity and paths never come from agent arguments.
use crate::{
    error::{ApiError, ApiResult},
    services::Node,
    store::{SessionRow, Store},
};
use pirc_agent::{
    handoff::{self, SourceRef},
    history,
    session_store::{self, EntryData, SessionEntry},
    workspace_journal::{self as journal, Boundary, Receipt, Snapshot},
};
use pirc_protocol::{Message, StopReason};
use serde_json::{Value, json};
use std::{
    collections::HashSet,
    io::{BufRead, BufReader, Read},
    os::unix::fs::{MetadataExt, OpenOptionsExt},
    path::{Path, PathBuf},
};

#[derive(Clone, PartialEq, Eq)]
pub struct Scope {
    pub caller: String,
    pub owner: String,
    pub workspace: String,
    pub path: String,
    pub key: String,
    pub root: String,
    pub epoch: i64,
    pub mode: pirc_protocol::Mode,
}
fn unavailable(code: impl Into<String>) -> ApiError {
    ApiError::new(
        409,
        code.into(),
        "Repository memory is unavailable; no previous prompt block is retained",
    )
}
fn err(e: String) -> ApiError {
    unavailable(
        e.split(':')
            .next()
            .unwrap_or("workspace_unavailable")
            .to_owned(),
    )
}
fn safe_dir(path: &Path) -> ApiResult<PathBuf> {
    let canonical = std::fs::canonicalize(path).map_err(|_| unavailable("source_unavailable"))?;
    // The registered root may contain a host alias; descendants must be real directories/files.
    if !std::fs::symlink_metadata(path).is_ok_and(|m| m.is_dir() && !m.file_type().is_symlink()) {
        return Err(unavailable("source_unavailable"));
    }
    Ok(canonical)
}
pub fn scope(
    node: &Node,
    caller: &str,
    expected_mode: &pirc_protocol::Mode,
    epoch: i64,
    work: bool,
) -> ApiResult<Scope> {
    let (session, workspace) = {
        let db = node.db.lock();
        db.require_session_available(caller)?;
        crate::execution_fences::require_open(&db, caller)?;
        let s = db.get_session(caller)?;
        let w = db.get_workspace(&s.workspace_id)?;
        if db.workspace_deletion(&w.id)?.is_some() {
            return Err(ApiError::forbidden("Workspace is being deleted"));
        }
        (s, w)
    };
    if session.runner_epoch != epoch || session.private_session_path.is_empty() {
        return Err(ApiError::forbidden(
            "The originating runner is no longer current",
        ));
    }
    let mode = node.workspace_mode(&workspace)?;
    if &mode != expected_mode || (work && (!mode.workspace_memory || !mode.repository)) {
        return Err(ApiError::forbidden(
            "This mode cannot access repository memory",
        ));
    }
    let owner = session
        .owner_user
        .clone()
        .filter(|s| !s.is_empty())
        .ok_or_else(|| ApiError::forbidden("A known session owner is required"))?;
    let (key, root) = if work {
        pirc_agent::features::memory::workspace::resolve_workspace_from_files(
            &workspace.canonical_path,
        )
    } else {
        (String::new(), String::new())
    };
    Ok(Scope {
        caller: caller.into(),
        owner,
        workspace: workspace.id,
        path: session.private_session_path,
        key,
        root,
        epoch,
        mode,
    })
}
fn source_file(row: &SessionRow) -> ApiResult<(std::fs::File, std::fs::Metadata, PathBuf)> {
    let dir = safe_dir(Path::new(&row.private_session_path))?;
    let path = dir.join(session_store::SESSION_FILE);
    let f = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(nix::libc::O_NOFOLLOW | nix::libc::O_NONBLOCK)
        .open(&path)
        .map_err(|_| unavailable("source_unavailable"))?;
    let before = f
        .metadata()
        .map_err(|_| unavailable("source_unavailable"))?;
    if !before.is_file() || before.nlink() != 1 || before.len() > pirc_agent::journal::MAX_BYTES {
        return Err(unavailable("source_unavailable"));
    }
    Ok((f, before, path))
}
fn verify_file(path: &Path, before: &std::fs::Metadata) -> ApiResult<()> {
    let after = std::fs::symlink_metadata(path).map_err(|_| unavailable("source_changed"))?;
    if !after.is_file() || after.nlink() != 1 || Fingerprint::of(before) != Fingerprint::of(&after)
    {
        return Err(unavailable("source_changed"));
    }
    Ok(())
}
fn read_source(row: &SessionRow) -> ApiResult<(std::sync::Arc<Vec<SessionEntry>>, Fingerprint)> {
    let (f, before, path) = source_file(row)?;
    let mut raw = Vec::new();
    f.take(pirc_agent::journal::MAX_BYTES + 1)
        .read_to_end(&mut raw)
        .map_err(|_| unavailable("source_unavailable"))?;
    verify_file(&path, &before)?;
    let p = pirc_agent::journal::parse(&raw).map_err(err)?;
    if p.incomplete {
        return Err(unavailable("source_incomplete"));
    }
    let entries = session_store::parse_entries(
        std::str::from_utf8(&raw).map_err(|_| unavailable("source_unavailable"))?,
    )
    .map_err(err)?;
    // Registered identity and raw header must agree; a replaced log cannot cross session boundaries.
    if let Some(pi) = &row.pi_session_id
        && history::header_id(&entries).map_err(err)? != *pi
    {
        return Err(unavailable("source_identity_changed"));
    }
    // A branch edit changes ancestry; use the same branch as the session reader.
    let by: std::collections::HashMap<_, _> = entries.iter().map(|e| (e.id.as_str(), e)).collect();
    let mut branch = Vec::new();
    let mut current = entries.last();
    while let Some(e) = current {
        branch.push(e.clone());
        current = e.parent_id.as_deref().and_then(|id| by.get(id).copied());
        if branch.len() > entries.len() {
            return Err(unavailable("source_cycle"));
        }
    }
    branch.reverse();
    Ok((std::sync::Arc::new(branch), Fingerprint::of(&before)))
}
fn source_available(db: &impl Store, row: &SessionRow, owner: &str) -> ApiResult<bool> {
    Ok(row.owner_user.as_deref() == Some(owner) && db.session_deletion(&row.id)?.is_none())
}
fn rows(node: &Node, s: &Scope) -> ApiResult<Vec<SessionRow>> {
    let workspaces = node.db.lock().list_workspaces()?;
    let mut result = Vec::new();
    for w in workspaces {
        let mode = match node.workspace_mode(&w) {
            Ok(m) => m,
            Err(_) => continue,
        };
        if !mode.workspace_memory || !mode.repository {
            continue;
        }
        let (key, root) = pirc_agent::features::memory::workspace::resolve_workspace_from_files(
            &w.canonical_path,
        );
        if key != s.key || root != s.root {
            continue;
        }
        let sessions = {
            let db = node.db.lock();
            db.workspace_sessions(&w.id)?
                .into_iter()
                .filter_map(|row| match source_available(&*db, &row, &s.owner) {
                    Ok(true) => Some(Ok(row)),
                    Ok(false) => None,
                    Err(e) => Some(Err(e)),
                })
                .collect::<ApiResult<Vec<_>>>()?
        };
        result.extend(sessions);
        if result.len() > 10000 {
            return Err(unavailable("workspace_source_limit"));
        }
    }
    result.sort_by(|a, b| a.created_at.cmp(&b.created_at).then(a.id.cmp(&b.id)));
    Ok(result)
}

#[derive(Clone, PartialEq, Eq)]
struct Fingerprint {
    dev: u64,
    ino: u64,
    len: u64,
    sec: i64,
    nsec: i64,
}
impl Fingerprint {
    fn of(m: &std::fs::Metadata) -> Self {
        Self {
            dev: m.dev(),
            ino: m.ino(),
            len: m.len(),
            sec: m.mtime(),
            nsec: m.mtime_nsec(),
        }
    }
}
/// One authority/source snapshot per host operation; cache is request-local, never durable.
type CachedSource = (std::sync::Arc<Vec<SessionEntry>>, Fingerprint);
pub struct View {
    node: Node,
    scope: Scope,
    rows: Vec<SessionRow>,
    state: Snapshot,
    cache: std::cell::RefCell<std::collections::HashMap<String, CachedSource>>,
    bytes: std::cell::Cell<u64>,
    // Retain validation evidence even after a parsed branch is evicted.
    fingerprints: std::cell::RefCell<std::collections::HashMap<String, Fingerprint>>,
    identities: std::cell::RefCell<std::collections::HashMap<String, String>>,
}
fn registry(rows: &[SessionRow]) -> Value {
    json!(
        rows.iter()
            .map(|r| json!([
                r.id,
                r.workspace_id,
                r.owner_user,
                r.private_session_path,
                r.pi_session_id
            ]))
            .collect::<Vec<_>>()
    )
}
impl View {
    pub fn new(node: &Node, s: &Scope, work: bool) -> ApiResult<Self> {
        Ok(Self {
            node: node.clone(),
            scope: s.clone(),
            rows: if work {
                rows(node, s)?
            } else {
                vec![node.db.lock().get_session(&s.caller)?]
            },
            state: if work {
                snapshot(node, s)?
            } else {
                journal::parse(&[]).map_err(err)?
            },
            cache: Default::default(),
            bytes: std::cell::Cell::new(0),
            fingerprints: Default::default(),
            identities: Default::default(),
        })
    }
    fn source(&self, row: &SessionRow) -> ApiResult<std::sync::Arc<Vec<SessionEntry>>> {
        if let Some((branch, _)) = self.cache.borrow().get(&row.id) {
            return Ok(branch.clone());
        }
        let (branch, fingerprint) = read_source(row)?;
        self.remember(row, fingerprint.clone())?;
        if self.bytes.get().saturating_add(fingerprint.len) > pirc_agent::journal::MAX_BYTES {
            self.cache.borrow_mut().clear();
            self.bytes.set(0);
        }
        self.bytes.set(self.bytes.get() + fingerprint.len);
        self.cache
            .borrow_mut()
            .insert(row.id.clone(), (branch.clone(), fingerprint));
        Ok(branch)
    }
    fn remember(&self, row: &SessionRow, fingerprint: Fingerprint) -> ApiResult<()> {
        let mut seen = self.fingerprints.borrow_mut();
        if seen.get(&row.id).is_some_and(|old| old != &fingerprint) {
            return Err(unavailable("source_changed"));
        }
        seen.insert(row.id.clone(), fingerprint);
        Ok(())
    }
    /// Control metadata needs an authorized session identity, not its message
    /// bodies. Actual notes, jobs and mutation boundaries still validate the
    /// entire active branch. Never trust an agent-supplied session ID here.
    fn source_id(&self, row: &SessionRow) -> ApiResult<String> {
        if let Some(id) = self.identities.borrow().get(&row.id) {
            return Ok(id.clone());
        }
        let id = if let Some((branch, _)) = self.cache.borrow().get(&row.id) {
            history::header_id(branch).map_err(err)?
        } else {
            let (file, before, path) = source_file(row)?;
            let mut header = String::new();
            BufReader::new(file.take(1024 * 1024))
                .read_line(&mut header)
                .map_err(|_| unavailable("source_unavailable"))?;
            if !header.ends_with('\n') {
                return Err(unavailable("invalid_session_header"));
            }
            let entries = session_store::parse_entries(&header).map_err(err)?;
            let id = history::header_id(&entries).map_err(err)?;
            if entries.len() != 1
                || entries[0].parent_id.is_some()
                || row
                    .pi_session_id
                    .as_ref()
                    .is_some_and(|registered| registered != &id)
            {
                return Err(unavailable("source_identity_changed"));
            }
            verify_file(&path, &before)?;
            self.remember(row, Fingerprint::of(&before))?;
            id
        };
        self.identities
            .borrow_mut()
            .insert(row.id.clone(), id.clone());
        Ok(id)
    }
    pub fn revalidate(&mut self, work: bool) -> ApiResult<()> {
        self.verify_sources(work)?;
        if work {
            self.state = snapshot(&self.node, &self.scope)?;
        }
        Ok(())
    }
    fn verify_sources(&self, work: bool) -> ApiResult<()> {
        if scope(
            &self.node,
            &self.scope.caller,
            &self.scope.mode,
            self.scope.epoch,
            work,
        )? != self.scope
        {
            return Err(ApiError::forbidden("Original caller authority changed"));
        }
        let latest = if work {
            rows(&self.node, &self.scope)?
        } else {
            vec![self.node.db.lock().get_session(&self.scope.caller)?]
        };
        if registry(&latest) != registry(&self.rows) {
            return Err(ApiError::forbidden(
                "Source ownership or registration changed",
            ));
        }
        for row in &self.rows {
            if let Some(before) = self.fingerprints.borrow().get(&row.id) {
                let m = std::fs::symlink_metadata(
                    Path::new(&row.private_session_path).join(session_store::SESSION_FILE),
                )
                .map_err(|_| unavailable("source_changed"))?;
                if !m.is_file() || m.nlink() != 1 || &Fingerprint::of(&m) != before {
                    return Err(unavailable("source_changed"));
                }
            }
        }
        Ok(())
    }
}

fn boundaries(view: &View) -> ApiResult<Vec<Boundary>> {
    view.rows
        .iter()
        .map(|row| {
            let b = view.source(row)?;
            Ok(Boundary {
                session_id: history::header_id(&b).map_err(err)?,
                after_entry_id: b
                    .iter()
                    .rev()
                    .find(|e| handoff::public(e))
                    .map(|e| e.id.clone()),
            })
        })
        .collect()
}
fn owned(view: &View, item: &Value) -> ApiResult<bool> {
    let dir = item["sessionDir"].as_str().unwrap_or("");
    let candidates = &view.rows;
    let Some(row) = candidates.iter().find(|r| r.private_session_path == dir) else {
        return Ok(false);
    };
    let branch = view.source(row)?;
    let sid = history::header_id(&branch).map_err(err)?;
    if item["sessionId"] != sid {
        return Ok(false);
    }
    if let Some(refs) = item.get("sources") {
        let refs: Vec<SourceRef> = serde_json::from_value(refs.clone())
            .map_err(|_| unavailable("invalid_workspace_sources"))?;
        if refs.iter().any(|r| {
            r.session_id != sid
                || !branch
                    .iter()
                    .any(|e| e.id == r.entry_id && handoff::public(e))
        }) {
            return Ok(false);
        }
    }
    Ok(true)
}
fn ledger(node: &Node, s: &Scope) -> PathBuf {
    node.config
        .workspace_memory_dir
        .join(format!("{}.jsonl", s.key))
}
pub fn snapshot(node: &Node, s: &Scope) -> ApiResult<Snapshot> {
    journal::read(&ledger(node, s)).map_err(err)
}
/// An acknowledged hash fences rollback and equal-length replacement. A legacy checkpoint needs
/// explicit upgrade before v2 activation, rather than assuming byte offsets prove identity.
pub fn mirror_check(s: &Snapshot, remote: &Value, path: &Path) -> ApiResult<()> {
    if remote["version"] != 2 {
        return Err(unavailable("mirror_upgrade_required"));
    }
    let watermark = remote["watermark"]
        .as_u64()
        .ok_or_else(|| unavailable("mirror_state_invalid"))? as usize;
    if watermark > s.bytes {
        return Err(unavailable("mirror_rollback"));
    }
    if watermark == 0 {
        return Ok(());
    }
    let hash = remote["digest"].as_str();
    let raw = std::fs::read(path).map_err(|_| unavailable("mirror_unavailable"))?;
    if raw.len() < watermark {
        return Err(unavailable("mirror_rollback"));
    }
    if let Some(hash) = hash {
        if pirc_agent::journal::digest(&raw[..watermark]) != hash {
            return Err(unavailable("mirror_rollback"));
        }
    } else if remote["legacyProjection"].as_str()
        != Some(&journal::projection(&raw[..watermark]).map_err(err)?)
    {
        return Err(unavailable("mirror_rollback"));
    }
    Ok(())
}
fn context(view: &View, args: &Value, state: &Snapshot) -> ApiResult<Value> {
    let max = args
        .get("maxTokens")
        .map_or(Some(3000), Value::as_u64)
        .filter(|v| *v > 0)
        .ok_or_else(ApiError::invalid_input)?
        .min(32000) as usize
        * 4;
    let mut items = Vec::new();
    for item in state
        .items
        .iter()
        .filter(|_| args["preparingCutover"] != true)
    {
        if owned(view, item)? {
            items.push(item.clone())
        }
    }
    let inventory = pirc_agent::journal::digest(serde_json::to_string(&items).unwrap().as_bytes());
    let mut start = 0usize;
    if let Some(c) = args.get("cursor").filter(|c| !c.is_null()) {
        if c["fingerprint"].as_str() != Some(&inventory) {
            return Err(unavailable("workspace_view_changed"));
        }
        start = c["offset"]
            .as_u64()
            .and_then(|x| usize::try_from(x).ok())
            .filter(|x| *x <= items.len())
            .ok_or_else(ApiError::invalid_input)?;
    }
    let paged = args["view"] == true;
    let mut result = Vec::new();
    let mut chars = 0;
    for item in items.iter().skip(start) {
        let n = item["content"].as_str().unwrap_or("").len();
        if chars + n > if paged { 128 * 1024 } else { max } || result.len() >= 50 {
            break;
        }
        chars += n;
        result.push(item.clone());
    }
    let end = start + result.len();
    let pending = args
        .get("pendingJobs")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    if pending.len() > 64 {
        return Err(ApiError::invalid_input());
    }
    let jobs: Vec<_> = pending
        .iter()
        .map(|j| {
            let id = j["jobId"].as_str().unwrap_or("");
            let proof = if let Some(frame) = state.jobs.get(id) {
                json!({"status":"committed","revision":frame.revision})
            } else if state.control.as_ref().is_some_and(|c| {
                j["epoch"] != c.epoch
                    || j["generation"] != c.generation
                    || j["revision"].as_u64().is_some_and(|r| r < c.revision)
            }) {
                json!({"status":"failed"})
            } else {
                json!({"status":"pending"})
            };
            json!({"jobId":id,"proof":proof})
        })
        .collect();
    Ok(
        json!({"control":public_control(view,state)?,"items":result,"total":items.len(),"cursor":if paged&&end<items.len(){json!({"fingerprint":inventory,"offset":end})}else{Value::Null},"boundaries":if args["includeBoundaries"]==true {Some(boundaries(view)?)}else{None},"jobs":jobs,"snapshot":state.hash,"legacy":state.control.is_none()}),
    )
}
fn next_job(view: &View, state: &Snapshot, catchup: bool) -> ApiResult<Value> {
    if state.control.is_none() {
        return Err(unavailable("workspace_cold_cutover_required"));
    }
    let mut blocked_sources = false;
    for row in &view.rows {
        let branch = view.source(row)?;
        let sid = history::header_id(&branch).map_err(err)?;
        let positions: std::collections::HashMap<_, _> = branch
            .iter()
            .enumerate()
            .map(|(at, entry)| (entry.id.as_str(), at))
            .collect();
        let index = |id: Option<&str>| -> ApiResult<Option<usize>> {
            id.map(|id| {
                positions
                    .get(id)
                    .copied()
                    .ok_or_else(|| unavailable("workspace_source_gap"))
            })
            .transpose()
        };
        let cut = index(
            state
                .cutover
                .iter()
                .find(|b| b.session_id == sid)
                .and_then(|b| b.after_entry_id.as_deref()),
        )?;
        let cleared = index(
            state
                .clear_cutoffs
                .iter()
                .find(|b| b.session_id == sid)
                .and_then(|b| b.after_entry_id.as_deref()),
        )?;
        let boundary = cut.into_iter().chain(cleared).max();
        let upper = if catchup {
            boundary.map_or(0, |i| i + 1)
        } else {
            branch.len()
        };
        let mut processed = HashSet::new();
        for receipt in state.receipts.iter().filter(|r| r.session_id == sid) {
            index(Some(&receipt.from_entry_id))?;
            index(Some(&receipt.through_entry_id))?;
            if !catchup
                || (receipt.mode.as_deref() == Some("catchup")
                    && Some(&receipt.generation) == state.control.as_ref().map(|c| &c.generation))
            {
                processed.insert((
                    receipt.from_entry_id.as_str(),
                    receipt.through_entry_id.as_str(),
                ));
            }
        }
        // Classify once: tool safety and evidence eligibility share provenance,
        // but revoking an old admission must not revoke a newer human admission.
        let Ok(history) = handoff::source_history(&branch) else {
            // An unbounded provenance error cannot be called "no work".
            // Continue looking for safe work in other authorized sessions.
            blocked_sources = true;
            continue;
        };
        let safe = &history.boundaries;
        let mut revoked = HashSet::new();
        for receipt in state
            .forgotten_ranges
            .iter()
            .filter(|r| r.session_id == sid)
        {
            let from = index(Some(&receipt.from_entry_id))?.unwrap();
            let through = index(Some(&receipt.through_entry_id))?.unwrap();
            for (at, entry) in branch.iter().enumerate().take(through + 1).skip(from) {
                if matches!(entry.data, EntryData::Message(Message::User { .. })) {
                    revoked.insert(at);
                }
            }
        }
        blocked_sources |= history.blocked.iter().any(|at| {
            *at < upper
                && (catchup || boundary.is_none_or(|boundary| *at > boundary))
                && !revoked.contains(at)
                && matches!(branch[*at].data, EntryData::Message(Message::User { .. }))
        });
        let starts: Vec<_> = branch
            .iter()
            .enumerate()
            .filter_map(|(i, e)| {
                (safe.contains(&i) && matches!(&e.data, EntryData::Message(Message::User { .. })))
                    .then_some(i)
            })
            .collect();
        for (number, &from) in starts.iter().enumerate() {
            if from >= upper {
                continue;
            }
            let end = starts
                .get(number + 1)
                .copied()
                .unwrap_or(branch.len())
                .min(upper);
            let through = branch[from..end]
                .iter()
                .rposition(handoff::public)
                .map(|i| i + from)
                .unwrap();
            if !safe.contains(&(through + 1)) {
                continue;
            }
            let eligible = |admission: usize| {
                admission >= from
                    && admission < end
                    && (catchup || boundary.is_none_or(|i| admission > i))
                    && !revoked.contains(&admission)
                    && !history.blocked.contains(&admission)
            };
            let Some(admitted_from) = (from..end).find(|&at| {
                eligible(at) && matches!(branch[at].data, EntryData::Message(Message::User { .. }))
            }) else {
                continue;
            };
            let Some(last_message) = branch[from..end].iter().rev().find(|entry| {
                matches!(entry.data, EntryData::Message(_))
                    && history
                        .origins
                        .get(&entry.id)
                        .is_some_and(|admission| eligible(*admission))
            }) else {
                continue;
            };
            if !matches!(&last_message.data,EntryData::Message(Message::Assistant(a))if a.stop_reason==StopReason::Stop)
            {
                continue;
            }
            if processed.contains(&(
                branch[admitted_from].id.as_str(),
                branch[through].id.as_str(),
            )) {
                continue;
            }
            let raw = &branch[from..=through];
            let sources: Vec<_> = history.sources(|at, admission| at >= from && at <= through && eligible(admission))
                .into_iter().map(|source| json!({"sessionId":sid,"entryId":source.entry_id,"role":source.role,"text":source.text,"derived":source.derived,"timestamp":source.timestamp})).collect();
            if serde_json::to_vec(&sources).unwrap().len() > 128 * 1024 {
                return Err(unavailable("workspace_turn_too_large"));
            }
            let job = pirc_agent::journal::digest(
                json!([journal::control(state), sid, raw, catchup])
                    .to_string()
                    .as_bytes(),
            );
            return Ok(
                json!({"jobId":format!("w_{}",&job[..48]),"control":public_control(view,state)?,"sessionId":sid,"fromEntryId":branch[admitted_from].id,"throughEntryId":branch[through].id,"sourceHash":pirc_agent::journal::digest(serde_json::to_vec(raw).unwrap().as_slice()),"sources":sources,"catchup":catchup}),
            );
        }
    }
    if blocked_sources {
        return Err(ApiError::new(
            409,
            "workspace_source_blocked",
            "Repository memory extraction is blocked for some sources: tool provenance is incomplete or ambiguous. Independent safe interactions can still be processed.",
        ));
    }
    Ok(Value::Null)
}
/// Caller holds Node admission. Runner checks stay nonblocking to avoid the
/// two-memory-call lifecycle lock inversion; pending host evidence is independent
/// of live runner/session membership and includes the caller's own host jobs.
fn cold_writers_stopped(node: &Node, db: &rusqlite::Connection, s: &Scope) -> ApiResult<()> {
    crate::host_commands::resources::require_available(db, Path::new(&s.root), None)?;
    crate::host_commands::resources::require_available(db, &ledger(node, s), None)?;
    for workspace in db.list_workspaces()? {
        let (key, root) = pirc_agent::features::memory::workspace::resolve_workspace_from_files(
            &workspace.canonical_path,
        );
        if key == s.key && root == s.root {
            for row in db.workspace_sessions(&workspace.id)? {
                if row.id != s.caller && node.runners.may_be_alive(&row.id) {
                    return Err(unavailable("workspace_writers_active"));
                }
            }
        }
    }
    Ok(())
}

fn mutation(view: &View, args: &Value, state: &Snapshot, action: &str) -> ApiResult<Value> {
    let node = &view.node;
    let s = &view.scope;
    let job = args["jobId"]
        .as_str()
        .filter(|j| handoff::key(j))
        .ok_or_else(ApiError::invalid_input)?;
    if let Some(old) = state.jobs.get(job) {
        let matches = match action {
            "cold" => old.cutover.is_some(),
            "clear" => old.clear,
            "forget" => old.forget.first().is_some_and(|id| args["id"] == *id),
            "commit" => old.receipt.is_some(),
            _ => false,
        };
        if !matches || old.revision != args["revision"].as_u64().unwrap_or(0) + 1 {
            return Err(unavailable("workspace_job_conflict"));
        }
        return Ok(json!({"committed":true,"control":public_control(view,state)?}));
    }
    if let Some(c) = &state.control {
        if args["epoch"] != c.epoch
            || args["generation"] != c.generation
            || args["revision"] != c.revision
        {
            return Err(unavailable("workspace_stale"));
        }
    } else if action != "cold" {
        return Err(unavailable("workspace_cold_cutover_required"));
    }
    let mut frame = journal::frame(state, job);
    match action {
        "cold" => {
            if args["writersStopped"] != true {
                return Err(ApiError::bad_request(
                    "Cold cutover requires all old writers stopped",
                ));
            }
            cold_writers_stopped(node, &node.db.lock(), s)?;

            if state.control.is_some() {
                return Err(unavailable("workspace_already_active"));
            }
            frame.cutover = Some(boundaries(view)?);
        }
        "clear" => {
            for item in &state.items {
                if !owned(view, item)? {
                    return Err(ApiError::forbidden(
                        "Shared ledger contains another owner’s memory",
                    ));
                }
            }

            // The caller retains this original capture when retrying an unknown ACK.
            let cutoffs: Vec<Boundary> = serde_json::from_value(args["boundaries"].clone())
                .map_err(|_| ApiError::invalid_input())?;
            let now = boundaries(view)?;
            if cutoffs.len() != now.len() {
                return Err(unavailable("workspace_source_changed"));
            }
            let mut seen = HashSet::new();
            for boundary in &cutoffs {
                if !seen.insert(&boundary.session_id)
                    || !now.iter().any(|n| n.session_id == boundary.session_id)
                {
                    return Err(unavailable("workspace_source_changed"));
                }
                if let Some(id) = &boundary.after_entry_id {
                    let mut found = false;
                    for row in &view.rows {
                        let branch = view.source(row)?;
                        if history::header_id(&branch).map_err(err)? == boundary.session_id {
                            found = branch.iter().any(|e| e.id == *id && handoff::public(e));
                            break;
                        }
                    }
                    if !found {
                        return Err(unavailable("workspace_source_changed"));
                    }
                }
            }
            frame.clear = true;
            frame.generation = format!("g_{}", crate::util::uuid());
            frame.clear_cutoffs = Some(cutoffs);
        }
        "forget" => {
            let id = args["id"]
                .as_str()
                .filter(|id| journal::id(id))
                .ok_or_else(ApiError::invalid_input)?;
            let item = state
                .items
                .iter()
                .find(|v| v["id"] == id)
                .ok_or_else(|| ApiError::not_found("Memory not found"))?;
            if !owned(view, item)? {
                return Err(ApiError::forbidden("Memory is not accessible"));
            }
            frame.forget.push(id.into());
        }
        "commit" => {
            let fresh = next_job(view, state, args["catchup"] == true)?;
            if fresh["jobId"] != job || fresh["sourceHash"] != args["sourceHash"] {
                return Err(unavailable("workspace_source_changed"));
            }
            let retired: Vec<String> = args
                .get("retire")
                .map(|v| serde_json::from_value(v.clone()))
                .transpose()
                .map_err(|_| ApiError::invalid_input())?
                .unwrap_or_default();
            if retired.len() > 100 {
                return Err(ApiError::invalid_input());
            }
            for id in &retired {
                let note = state
                    .items
                    .iter()
                    .find(|i| i["id"] == *id)
                    .ok_or_else(|| unavailable("workspace_invalid_retirement"))?;
                if !owned(view, note)? {
                    return Err(ApiError::forbidden("Memory is not accessible"));
                }
            }
            frame.retire = retired;
            let candidates = args["items"]
                .as_array()
                .filter(|a| a.len() <= 20)
                .ok_or_else(ApiError::invalid_input)?;
            let sid = fresh["sessionId"].as_str().unwrap();
            let row = view
                .rows
                .iter()
                .find(|r| {
                    view.source(r)
                        .ok()
                        .and_then(|b| history::header_id(&b).ok())
                        .as_deref()
                        == Some(sid)
                })
                .ok_or_else(|| unavailable("workspace_source_unavailable"))?;
            let allowed: HashSet<SourceRef> = fresh["sources"]
                .as_array()
                .unwrap()
                .iter()
                .filter(|v| v["derived"] != true)
                .map(|v| SourceRef {
                    session_id: sid.into(),
                    entry_id: v["entryId"].as_str().unwrap().into(),
                })
                .collect();
            let mut used = HashSet::new();
            for (index, v) in candidates.iter().enumerate() {
                let text = v["content"]
                    .as_str()
                    .filter(|s| !s.trim().is_empty() && s.len() <= 20000)
                    .ok_or_else(ApiError::invalid_input)?;
                let refs: Vec<SourceRef> = serde_json::from_value(v["sources"].clone())
                    .map_err(|_| ApiError::invalid_input())?;
                if refs.is_empty() || refs.len() > 100 || refs.iter().any(|r| !allowed.contains(r))
                {
                    return Err(ApiError::invalid_input());
                }
                // Forget is source-specific: old evidence cannot promote the same claim again.
                if refs.iter().any(|r| state.tombstones.contains(r)) {
                    continue;
                }
                let content = pirc_agent::features::memory::text::neutralize_headers(
                    &pirc_agent::redact::redact_secrets(text),
                );
                if state.items.iter().any(|i| {
                    i["content"] == content && !frame.retire.iter().any(|id| i["id"] == *id)
                }) {
                    continue;
                }
                let id = pirc_agent::journal::digest(
                    json!([job, index, content, refs]).to_string().as_bytes(),
                )[..12]
                    .to_owned();
                if !used.insert(id.clone()) {
                    return Err(ApiError::invalid_input());
                }
                frame.add.push(json!({"id":id,"content":content,"relevance":"high","timestamp":pirc_agent::features::memory::time::local_stamp_now(),"sessionId":sid,"sessionDir":row.private_session_path,"sourceMemoryIds":[],"sources":refs,"tokenCount":content.len().div_ceil(4)}));
            }
            frame.receipt = Some(Receipt {
                job_id: job.into(),
                generation: frame.generation.clone(),
                session_id: sid.into(),
                from_entry_id: fresh["fromEntryId"].as_str().unwrap().into(),
                through_entry_id: fresh["throughEntryId"].as_str().unwrap().into(),
                outcome: if frame.add.is_empty() && frame.retire.is_empty() {
                    "empty"
                } else {
                    "recorded"
                }
                .into(),
                mode: (args["catchup"] == true).then(|| "catchup".into()),
            });
        }
        _ => return Err(ApiError::invalid_input()),
    }
    let new = journal::append_checked(&ledger(node, s), &frame, state, || {
        view.verify_sources(true).map_err(|e| e.code.into_owned())?;
        if action == "cold" {
            // No own-session exemption: the caller may have a detached or
            // independently supervised host job despite having stopped Agent.
            let admission = node.db.lock();
            cold_writers_stopped(node, &admission, s).map_err(|e| e.code.into_owned())?;
            format_fence(&ledger(node, s))?;
            // Held through journal append + fsync, preventing a fresh host
            // reservation between the last writer check and durable cutover.
            Ok(Some(admission))
        } else {
            Ok(None)
        }
    })
    .map_err(err)?;
    Ok(json!({"committed":true,"control":public_control(view,&new)?}))
}
pub fn execute(view: &View, op: &str, args: &Value) -> ApiResult<Value> {
    let node = &view.node;
    let s = &view.scope;
    if op.starts_with("history.") {
        let row = node.db.lock().get_session(&s.caller)?;
        return history::view(&view.source(&row)?, args, op == "history.read").map_err(err);
    }
    let state = &view.state;
    let marker = ledger(node, s).with_extension("lock");
    if state.control.is_none()
        && std::fs::symlink_metadata(&marker).is_ok()
        && op != "workspace.open"
        && op != "workspace.cold"
        && !(op == "workspace.context" && args["preparingCutover"] == true)
    {
        return Err(unavailable("workspace_versioned_ledger_missing"));
    }
    match op {
        "workspace.open" => Ok(json!({"legacy":state.control.is_none()})),
        "workspace.context" => context(view, args, state),
        "workspace.next" => next_job(view, state, args["catchup"] == true),
        "workspace.cold" | "workspace.clear" | "workspace.forget" | "workspace.commit" => {
            mutation(view, args, state, op.split('.').nth(1).unwrap())
        }
        "workspace.recall" => {
            let item = state
                .items
                .iter()
                .find(|v| v["id"] == args["id"])
                .ok_or_else(|| ApiError::not_found("Memory not found"))?;
            if !owned(view, item)? {
                return Err(ApiError::forbidden("Memory is not accessible"));
            }
            let row = view
                .rows
                .iter()
                .find(|r| item["sessionDir"] == r.private_session_path)
                .ok_or_else(|| ApiError::not_found("Source not found"))?;
            let branch = view.source(row)?;
            let mut texts = vec![item["content"].as_str().unwrap_or("").into()];
            if let Some(refs) = item["sources"].as_array() {
                let ids: HashSet<_> = refs.iter().filter_map(|r| r["entryId"].as_str()).collect();
                texts.extend(
                    handoff::sources(&branch)
                        .into_iter()
                        .filter(|src| ids.contains(src.entry_id.as_str()))
                        .map(|src| src.text),
                );
            }
            let text = texts.join("\n\n");
            if text.len() > 128 * 1024 {
                return Err(unavailable("workspace_source_too_large"));
            }
            Ok(json!({"text":text,"status":"ok","memoryReplay":true}))
        }
        _ => Err(ApiError::invalid_input()),
    }
}
pub fn path(node: &Node, s: &Scope) -> PathBuf {
    ledger(node, s)
}

fn format_fence(path: &Path) -> Result<(), String> {
    use std::os::unix::fs::DirBuilderExt;
    let fence = path.with_extension("lock");
    match std::fs::DirBuilder::new().mode(0o700).create(&fence) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
        Err(_) => return Err("workspace_fence_unavailable".into()),
    }
    let m = std::fs::symlink_metadata(&fence).map_err(|_| "workspace_fence_unavailable")?;
    if !m.is_dir()
        || m.file_type().is_symlink()
        || std::fs::read_dir(&fence)
            .map_err(|_| "workspace_fence_unavailable")?
            .next()
            .is_some()
    {
        return Err("workspace_old_lock_present".into());
    }
    std::fs::File::open(path.parent().ok_or("workspace_fence_unavailable")?)
        .and_then(|f| f.sync_all())
        .map_err(|_| "workspace_fence_sync_failed")?;
    Ok(())
}
pub fn open_writer(node: &Node, s: &Scope, args: &Value, recover_only: bool) -> ApiResult<()> {
    let path = ledger(node, s);
    let marker = path.with_extension("lock");
    let has_marker = match std::fs::symlink_metadata(&marker) {
        Ok(m) => {
            if !m.is_dir()
                || m.file_type().is_symlink()
                || std::fs::read_dir(&marker)
                    .map_err(|_| unavailable("workspace_old_lock_present"))?
                    .next()
                    .is_some()
            {
                return Err(unavailable("workspace_old_lock_present"));
            }
            true
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => false,
        Err(_) => return Err(unavailable("workspace_fence_unavailable")),
    };
    let raw = match std::fs::read(&path) {
        Ok(raw) => raw,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Vec::new(),
        Err(_) => return Err(unavailable("workspace_unavailable")),
    };
    let parsed = pirc_agent::journal::parse(&raw).map_err(err)?;
    let active = journal::fold(&parsed.values)
        .map_err(err)?
        .control
        .is_some();
    if !active && !has_marker && args["writersStopped"] != true {
        return if recover_only {
            Ok(())
        } else {
            Err(unavailable("workspace_cold_cutover_required"))
        };
    }
    // Opening a legacy writer may repair/truncate an incomplete tail before
    // execute("workspace.cold") runs. Protect that effect too, not just the later
    // frame append. Journal locks are nonblocking, so contention refuses opening
    // rather than waiting on a checked writer holding journal before admission.
    let _admission = if !active {
        let admission = node.db.lock();
        cold_writers_stopped(node, &admission, s)?;
        Some(admission)
    } else {
        None
    };
    if !path.parent().is_some_and(Path::is_dir) {
        std::fs::create_dir_all(
            path.parent()
                .ok_or_else(|| unavailable("workspace_directory_unavailable"))?,
        )
        .map_err(|_| unavailable("workspace_directory_unavailable"))?;
    }
    pirc_agent::journal::Journal::at_path(&path, journal::validate_values).map_err(err)?;
    Ok(())
}

fn public_control(view: &View, state: &Snapshot) -> ApiResult<Value> {
    let mut control = journal::control(state);
    if control.is_null() {
        return Ok(control);
    }
    let mut ids = HashSet::new();
    for row in &view.rows {
        ids.insert(view.source_id(row)?);
    }
    for key in ["cutover", "clearCutoffs", "receipts"] {
        if let Some(a) = control[key].as_array_mut() {
            a.retain(|v| v["sessionId"].as_str().is_some_and(|id| ids.contains(id)));
        }
    }
    Ok(control)
}

#[cfg(test)]
pub(crate) mod tests;
