//! Keep a session group's evidence outside the live engine registry. A dropped
//! caller cannot erase uncertainty, and an empty registry after reboot is not a
//! successful close. Only browser resources launched by this Node are touched.
use super::*;
use crate::{services::WeakNode, store::Store};
use std::{
    collections::HashMap,
    sync::{
        Mutex, MutexGuard,
        atomic::{AtomicUsize, Ordering},
    },
    time::Duration,
};
use tokio::sync::{Notify, watch};

const CLOSE_WAIT: Duration = Duration::from_secs(30);
type Outcome = watch::Receiver<Option<ApiResult<()>>>;
fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}
struct Group {
    target: BrowserTarget,
    mode: pirc_protocol::Mode,
    record: journal::Record,
    active: AtomicUsize,
    idle: Notify,
    closing: Mutex<bool>,
    outcome: Mutex<Option<Outcome>>,
}
#[derive(Default)]
struct State {
    shutdown: bool,
    groups: HashMap<String, Arc<Group>>,
}
struct Inner {
    node: WeakNode,
    browser: Arc<dyn BrowserService>,
    state: Mutex<State>,
}
pub(crate) struct Tracked {
    inner: Arc<Inner>,
}
struct Operation {
    group: Arc<Group>,
}
impl Drop for Operation {
    fn drop(&mut self) {
        if self.group.active.fetch_sub(1, Ordering::AcqRel) == 1 {
            self.group.idle.notify_one();
        }
    }
}
impl Tracked {
    pub(crate) fn new(node: WeakNode, browser: Arc<dyn BrowserService>) -> Self {
        Self {
            inner: Arc::new(Inner {
                node,
                browser,
                state: Mutex::default(),
            }),
        }
    }
}
impl Inner {
    fn begin(&self, target: &BrowserTarget) -> ApiResult<Operation> {
        let node = self.node.upgrade().ok_or_else(journal::unresolved)?;
        let db = node.db.lock();
        if node.closing() || !self.browser.enabled() {
            return Err(unavailable());
        }
        crate::execution_fences::require_open(&db, &target.session_id)?;
        db.require_session_available(&target.session_id)?;
        let session = db.get_session(&target.session_id)?;
        let workspace = db.get_workspace(&session.workspace_id)?;
        let mode = node.workspace_mode(&workspace)?;
        if workspace.id != target.workspace_id
            || crate::chat::session_root(&workspace, &target.session_id, &mode)? != target.root
        {
            return Err(ApiError::new(
                409,
                "stale_environment",
                "The browser environment changed; reopen it from the current conversation",
            ));
        }
        let mut state = lock(&self.state);
        if state.shutdown {
            return Err(unavailable());
        }
        let group = if let Some(group) = state.groups.get(&target.session_id) {
            if *lock(&group.closing) {
                return Err(journal::unresolved());
            }
            if group.target != *target || group.mode != mode {
                return Err(ApiError::new(
                    409,
                    "stale_environment",
                    "The browser environment changed",
                ));
            }
            journal::require_settled(&db, &target.session_id, Some(&group.record.0))?;
            group.clone()
        } else {
            let group = Arc::new(Group {
                target: target.clone(),
                mode,
                record: journal::Record::reserve(&node, &db, target)?,
                active: AtomicUsize::new(0),
                idle: Notify::new(),
                closing: Mutex::new(false),
                outcome: Mutex::new(None),
            });
            state
                .groups
                .insert(target.session_id.clone(), group.clone());
            group
        };
        group.active.fetch_add(1, Ordering::AcqRel);
        Ok(Operation { group })
    }
    fn authority(
        &self,
        operation: &Operation,
        caller: Option<effects::Caller>,
        close: bool,
    ) -> effects::Guard {
        let weak = self.node.clone();
        let group = operation.group.clone();
        effects::Guard::new(move |effect| {
            let node = weak.upgrade().ok_or_else(journal::unresolved)?;
            let db = node.db.lock();
            if node.closing() {
                return Err(unavailable());
            }
            crate::execution_fences::require_open(&db, &group.target.session_id)?;
            db.require_session_available(&group.target.session_id)?;
            let row = db.get_session(&group.target.session_id)?;
            let workspace = db.get_workspace(&row.workspace_id)?;
            if workspace.id != group.target.workspace_id
                || node.workspace_mode(&workspace)? != group.mode
                || crate::chat::session_root(&workspace, &row.id, &group.mode)? != group.target.root
            {
                return Err(ApiError::new(
                    409,
                    "stale_environment",
                    "The browser environment changed",
                ));
            }
            // Hold the catalog and recovery overlay through the nonblocking effect.
            let modes = node.modes.read().unwrap_or_else(|e| e.into_inner());
            let recovery = node
                .recovery_roots
                .read()
                .unwrap_or_else(|e| e.into_inner());
            let mut mode = modes
                .get(&workspace.mode)
                .cloned()
                .ok_or_else(unavailable)?;
            if recovery.contains_key(&workspace.id) {
                mode.workspace_memory = false;
            }
            if mode != group.mode {
                return Err(unavailable());
            }
            let mut closing = lock(&group.closing);
            if *closing {
                return Err(journal::unresolved());
            }
            match &caller {
                None => effect(),
                Some(effects::Caller::Agent { epoch, abort }) => {
                    let aborted = abort.borrow();
                    if *epoch != row.runner_epoch || *aborted {
                        return Err(ApiError::new(
                            409,
                            "browser_authority_revoked",
                            "The original browser request is no longer authorized",
                        ));
                    }
                    effect();
                }
                Some(effects::Caller::Viewer {
                    client,
                    generation,
                    open,
                }) => {
                    db.validate_lease(&row.id, client, *generation)?;
                    let connected = lock(open);
                    if !*connected {
                        return Err(ApiError::not_found("Browser viewer is closed"));
                    }
                    effect();
                }
                Some(effects::Caller::Observer { open }) => {
                    let connected = lock(open);
                    if !*connected {
                        return Err(ApiError::not_found("Browser viewer is closed"));
                    }
                    effect();
                }
                #[cfg(test)]
                Some(effects::Caller::Test) => effect(),
            }
            if close {
                *closing = true;
            }
            Ok(())
        })
    }
    async fn close(self: &Arc<Self>, session: &str) -> ApiResult<()> {
        let group = {
            let state = lock(&self.state);
            state
                .groups
                .get(session)
                .inspect(|g| {
                    *lock(&g.closing) = true;
                })
                .cloned()
        };
        let Some(group) = group else {
            let node = self.node.upgrade().ok_or_else(journal::unresolved)?;
            return journal::require_settled(&node.db.lock(), session, None);
        };
        self.close_group(group).await
    }
    async fn close_group(self: &Arc<Self>, group: Arc<Group>) -> ApiResult<()> {
        let mut done = {
            let mut outcome = lock(&group.outcome);
            if let Some(done) = outcome.as_ref() {
                done.clone()
            } else {
                let (finished, done) = watch::channel(None);
                *outcome = Some(done.clone());
                let inner = self.clone();
                let group = group.clone();
                tokio::spawn(async move {
                    // Accepted manager calls retain their own in-flight slots.
                    // Start closing now to wake handoff waits; do not wait for
                    // our callers before asking the engine to drain them.
                    let mut result = inner.browser.close_session(&group.target.session_id).await;
                    while group.active.load(Ordering::Acquire) > 0 {
                        group.idle.notified().await;
                    }
                    result = inner
                        .node
                        .upgrade()
                        .ok_or_else(journal::unresolved)
                        .and_then(|node| {
                            group
                                .record
                                .finish(&node.db.lock(), result.is_ok())
                                .map_err(|_| journal::unresolved())?;
                            result
                        });
                    if result.is_ok() {
                        let mut state = lock(&inner.state);
                        if state
                            .groups
                            .get(&group.target.session_id)
                            .is_some_and(|g| Arc::ptr_eq(g, &group))
                        {
                            state.groups.remove(&group.target.session_id);
                        }
                    }
                    finished.send_replace(Some(result));
                });
                done
            }
        };
        tokio::time::timeout(CLOSE_WAIT, async {
            done.wait_for(Option::is_some)
                .await
                .map_err(|_| journal::unresolved())?
                .clone()
                .unwrap_or_else(|| Err(journal::unresolved()))
        })
        .await
        .map_err(|_| journal::unresolved())?
    }
}
impl BrowserService for Tracked {
    fn enabled(&self) -> bool {
        self.inner.browser.enabled()
    }
    fn handle(
        &self,
        target: BrowserTarget,
        op: String,
        args: Value,
    ) -> BoxFuture<'_, ApiResult<Value>> {
        Box::pin(async move {
            let caller = effects::require_caller(false)?;
            let operation = self.inner.begin(&target)?;
            let guard = self
                .inner
                .authority(&operation, Some(caller), op == "close");
            guard.run(|| ())?;
            if op == "close" {
                let group = operation.group.clone();
                drop(operation);
                self.inner.close_group(group).await?;
                return Ok(serde_json::json!({"closed":true}));
            }
            let resource = self.inner.authority(&operation, None, false);
            let result = effects::with_resource(
                resource,
                effects::scope(guard.clone(), async {
                    self.inner.browser.handle(target, op, args).await
                }),
            )
            .await;
            guard.failure().map_or(result, Err)
        })
    }
    fn handle_with_abort(
        &self,
        target: BrowserTarget,
        op: String,
        args: Value,
        abort: tokio::sync::watch::Receiver<bool>,
    ) -> BoxFuture<'_, ApiResult<Value>> {
        Box::pin(async move {
            let caller = effects::require_caller(false)?;
            let operation = self.inner.begin(&target)?;
            let guard = self
                .inner
                .authority(&operation, Some(caller), op == "close");
            guard.run(|| ())?;
            if op == "close" {
                let group = operation.group.clone();
                drop(operation);
                self.inner.close_group(group).await?;
                return Ok(serde_json::json!({"closed":true}));
            }
            let resource = self.inner.authority(&operation, None, false);
            let result = effects::with_resource(
                resource,
                effects::scope(guard.clone(), async {
                    self.inner
                        .browser
                        .handle_with_abort(target, op, args, abort)
                        .await
                }),
            )
            .await;
            guard.failure().map_or(result, Err)
        })
    }
    fn attach(&self, session: &str, send: FrameSink) -> Detach {
        self.inner.browser.attach(session, send)
    }
    fn input(
        &self,
        target: BrowserTarget,
        message: Value,
    ) -> BoxFuture<'_, ApiResult<Option<Value>>> {
        Box::pin(async move {
            let observer = message.get("type").and_then(Value::as_str) == Some("log_image");
            let caller = effects::require_caller(observer)?;
            let operation = self.inner.begin(&target)?;
            let guard = self.inner.authority(&operation, Some(caller), false);
            guard.run(|| ())?;
            let resource = self.inner.authority(&operation, None, false);
            let result = effects::with_resource(
                resource,
                effects::scope(guard.clone(), async {
                    self.inner.browser.input(target, message).await
                }),
            )
            .await;
            guard.failure().map_or(result, Err)
        })
    }
    fn close_session(&self, session: &str) -> BoxFuture<'_, ApiResult<()>> {
        let session = session.to_owned();
        Box::pin(async move { self.inner.close(&session).await })
    }
    fn shutdown(&self) -> BoxFuture<'_, ()> {
        Box::pin(async move {
            let sessions = {
                let mut state = lock(&self.inner.state);
                state.shutdown = true;
                state.groups.keys().cloned().collect::<Vec<_>>()
            };
            for result in
                futures_util::future::join_all(sessions.iter().map(|s| self.inner.close(s))).await
            {
                if let Err(error) = result {
                    crate::log::error(&format!("browser shutdown: {}", error.code));
                }
            }
            if tokio::time::timeout(CLOSE_WAIT, self.inner.browser.shutdown())
                .await
                .is_err()
            {
                crate::log::error("browser shutdown remains unconfirmed");
            }
        })
    }
}

#[cfg(test)]
#[path = "tracked_tests.rs"]
mod tests;
