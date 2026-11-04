//! Node-owned supervision of approved host commands. The caller may disappear,
//! but cancellation/reaping is driven by an independent task. Durable records
//! keep a lost supervisor explicit; they never authorize replay or PID guessing.
use crate::store::Store;
use crate::{
    error::{ApiError, ApiResult},
    services::Node,
    util::{now_ms, uuid},
};
use futures_util::FutureExt;
use process_wrap::tokio::CommandWrap;
use rusqlite::{Connection, params};
use serde::Serialize;
use serde_json::Value;
use std::{
    collections::HashMap,
    panic::AssertUnwindSafe,
    sync::{Arc, Mutex, MutexGuard},
    time::Duration,
};
use tokio::sync::watch;

pub(crate) mod approval;
pub(crate) mod resources;

const WAIT: Duration = Duration::from_secs(5);
#[derive(Default)]
pub(crate) struct Commands(Mutex<Registry>);
#[derive(Default)]
struct Registry {
    jobs: HashMap<String, Arc<Job>>,
    stops: HashMap<String, usize>,
    closing: bool,
}
struct Job {
    session: String,
    epoch: i64,
    cancel: watch::Sender<bool>,
    result: watch::Receiver<Option<ApiResult<Value>>>,
}
impl Commands {
    fn lock(&self) -> MutexGuard<'_, Registry> {
        self.0.lock().unwrap_or_else(|p| p.into_inner())
    }
}

pub(crate) struct Origin {
    pub authority: approval::Authority,
    pub session: String,
    pub workspace: String,
    pub epoch: i64,
    pub request: String,
    pub timeout: Duration,
    pub root: std::path::PathBuf,
}
pub(crate) struct Ticket(Arc<Job>);
impl Drop for Ticket {
    fn drop(&mut self) {
        self.0.cancel.send_replace(true);
    }
}
impl Ticket {
    pub(crate) async fn result(self) -> ApiResult<Value> {
        wait(&self.0).await
    }
}
async fn wait(job: &Job) -> ApiResult<Value> {
    let mut result = job.result.clone();
    result
        .wait_for(Option::is_some)
        .await
        .map_err(|_| unconfirmed())?
        .as_ref()
        .unwrap()
        .clone()
}
fn unconfirmed() -> ApiError {
    ApiError::new(
        503,
        "host_stop_unconfirmed",
        "A host command has not been confirmed stopped; retry reconciliation",
    )
}

pub(crate) struct Stop {
    commands: Arc<Commands>,
    session: String,
}
impl Drop for Stop {
    fn drop(&mut self) {
        let mut registry = self.commands.lock();
        if let Some(n) = registry.stops.get_mut(&self.session) {
            *n -= 1;
            if *n == 0 {
                registry.stops.remove(&self.session);
            }
        }
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Summary {
    launches: u64,
    not_started: u64,
    observers_settled: u64,
    unresolved: u64,
    /// There is no inventory of pre-2015 host execution or kernel descendant proof.
    history_complete: bool,
}
pub(crate) fn summary(db: &Connection, session: &str) -> ApiResult<Summary> {
    Ok(db.query_row("SELECT count(*),coalesce(sum(state='not_started'),0),coalesce(sum(state='settled'),0),coalesce(sum(state NOT IN ('not_started','settled')),0) FROM host_command_runs WHERE session_id=?1",[session],|r|Ok(Summary{launches:r.get(0)?,not_started:r.get(1)?,observers_settled:r.get(2)?,unresolved:r.get(3)?,history_complete:false}))?)
}
fn finish(db: &Connection, id: &str, state: &str) -> ApiResult<()> {
    db.execute("UPDATE host_command_runs SET state=?2,updated_at=?3 WHERE id=?1 AND state IN ('launching','running')",params![id,state,now_ms()])?;
    Ok(())
}

impl Commands {
    pub(crate) fn active_runs(&self) -> Vec<String> {
        self.lock()
            .jobs
            .iter()
            .filter(|(_, job)| job.result.borrow().is_none())
            .map(|(id, _)| id.clone())
            .collect()
    }

    /// Caller holds Node's DB and runner-side admission locks through this call.
    /// The journal must commit independently before spawning arbitrary host code.
    pub(crate) fn start(
        self: &Arc<Self>,
        node: &Node,
        db: &Connection,
        origin: Origin,
        command: &mut CommandWrap,
        source: watch::Receiver<bool>,
    ) -> ApiResult<Ticket> {
        if !db.is_autocommit() {
            return Err(ApiError::internal());
        }
        db.require_session_available(&origin.session)?;
        crate::execution_fences::require_open(db, &origin.session)?;
        let row = db.get_session(&origin.session)?;
        if row.runner_epoch != origin.epoch || row.workspace_id != origin.workspace {
            return Err(ApiError::conflict(
                "The approved execution environment changed",
            ));
        }
        if db.query_row("SELECT EXISTS(SELECT 1 FROM host_command_runs WHERE session_id=?1 AND runner_epoch=?2 AND incarnation=?3 AND request_id=?4)",params![origin.session,origin.epoch,node.incarnation,origin.request],|r|r.get::<_,bool>(0))? {
            return Err(ApiError::conflict("This host command request was already admitted; it will not be replayed"));
        }
        origin.authority.validate(db, node, &origin)?;
        let paths = node.writes.host_paths(db, &origin, &node.incarnation)?;
        let mut registry = self.lock();
        if registry.closing || registry.stops.contains_key(&origin.session) || node.closing() {
            return Err(unconfirmed());
        }
        if *source.borrow() || source.has_changed().is_err() {
            return Err(ApiError::conflict("The host command was withdrawn"));
        }
        if registry
            .jobs
            .values()
            .filter(|j| j.session == origin.session)
            .count()
            >= 4
        {
            return Err(ApiError::conflict(
                "Too many host commands are still being supervised",
            ));
        }
        let id = uuid();
        let stamp = now_ms();
        crate::store::atomic(db, |db| {
            db.execute(
                "INSERT INTO host_command_runs VALUES(?1,?2,?3,?4,?5,?6,'launching',?7,?7)",
                params![
                    id,
                    origin.session,
                    origin.workspace,
                    origin.epoch,
                    node.incarnation,
                    origin.request,
                    stamp
                ],
            )?;
            origin.authority.consume(db, node, &origin, &id)?;
            resources::record(db, &id, &paths)
        })?;
        node.activity.notify_one();
        let (cancel, abort) = watch::channel(false);
        let (result_tx, result) = watch::channel(None);
        let job = Arc::new(Job {
            session: origin.session,
            epoch: origin.epoch,
            cancel,
            result,
        });
        let child = match command.spawn() {
            Ok(child) => child.into_inner(),
            Err(error) => {
                finish(db, &id, "not_started")?;
                node.activity.notify_one();
                result_tx.send_replace(Some(Ok(crate::runner::host::spawn_error(&error))));
                return Ok(Ticket(job));
            }
        };
        let journal_error = finish_running(db, &id).err();
        if journal_error.is_some() {
            job.cancel.send_replace(true);
        }
        registry.jobs.insert(id.clone(), job.clone());
        let commands = self.clone();
        let weak = Arc::downgrade(node);
        let task_job = job.clone();
        // This task, not the request waiting for its output, owns the child.
        tokio::spawn(async move {
            let observed = AssertUnwindSafe(crate::runner::host::observe(
                child,
                origin.timeout,
                source,
                abort,
            ))
            .catch_unwind()
            .await;
            let complete = observed.as_ref().is_ok_and(|v| v.complete);
            let outcome = if let Some(error) = journal_error {
                Err(error)
            } else {
                match observed {
                    Ok(v) if v.complete => Ok(v.result),
                    _ => Err(unconfirmed()),
                }
            };
            if let Some(node) = weak.upgrade() {
                let db = node.db.lock();
                let recorded = finish(&db, &id, if complete { "settled" } else { "unconfirmed" });
                // Publish loss of live ownership before releasing admission. A
                // failed outcome write must not let this epoch reuse the range.
                result_tx.send_replace(Some(recorded.and(outcome)));
                node.activity.notify_one();
            } else {
                result_tx.send_replace(Some(Err(unconfirmed())));
            }
            let mut registry = commands.lock();
            if registry
                .jobs
                .get(&id)
                .is_some_and(|j| Arc::ptr_eq(j, &task_job))
            {
                registry.jobs.remove(&id);
            }
        });
        Ok(Ticket(job))
    }
    pub(crate) fn cancel_epoch(&self, session: &str, epoch: i64) {
        for job in self
            .lock()
            .jobs
            .values()
            .filter(|j| j.session == session && j.epoch == epoch)
        {
            job.cancel.send_replace(true);
        }
    }
    /// The guard prevents a new start while an ordinary Stop is in flight. An
    /// accepted transition/deletion also has its durable DB fence afterward.
    pub(crate) fn stop(self: &Arc<Self>, session: &str) -> Stop {
        let mut registry = self.lock();
        *registry.stops.entry(session.into()).or_default() += 1;
        for job in registry.jobs.values().filter(|j| j.session == session) {
            job.cancel.send_replace(true);
        }
        Stop {
            commands: self.clone(),
            session: session.into(),
        }
    }
    pub(crate) async fn wait_session(&self, node: &Node, session: &str) -> ApiResult<()> {
        let jobs: Vec<_> = self
            .lock()
            .jobs
            .values()
            .filter(|j| j.session == session)
            .cloned()
            .collect();
        for job in &jobs {
            job.cancel.send_replace(true);
        }
        // Bound the caller, not the supervised work. Dropping this wait never
        // aborts reaping or loses the registry entry.
        tokio::time::timeout(
            WAIT,
            futures_util::future::join_all(jobs.iter().map(|j| wait(j))),
        )
        .await
        .map_err(|_| unconfirmed())?;
        if summary(&node.db.lock(), session)
            .map_err(|_| unconfirmed())?
            .unresolved
            != 0
        {
            return Err(unconfirmed());
        }
        Ok(())
    }
    pub(crate) async fn shutdown(&self) {
        let jobs: Vec<_> = {
            let mut r = self.lock();
            r.closing = true;
            r.jobs.values().cloned().collect()
        };
        for job in &jobs {
            job.cancel.send_replace(true);
        }
        if !tokio::time::timeout(
            WAIT,
            futures_util::future::join_all(jobs.iter().map(|j| wait(j))),
        )
        .await
        .is_ok_and(|results| results.into_iter().all(|result| result.is_ok()))
        {
            crate::log::warn("Host command supervision did not settle before Node shutdown");
        }
    }
}
fn finish_running(db: &Connection, id: &str) -> ApiResult<()> {
    db.execute("UPDATE host_command_runs SET state='running',updated_at=?2 WHERE id=?1 AND state='launching'",params![id,now_ms()])?;
    Ok(())
}
#[cfg(test)]
mod tests;

#[cfg(test)]
mod resource_tests;
