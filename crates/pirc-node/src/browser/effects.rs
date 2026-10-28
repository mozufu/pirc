//! Caller-scoped foreground admission and environment-scoped browser resources.
//! Authority travels with queued effects, never the shared browser connection.
use crate::error::{ApiError, ApiResult};
use std::{
    future::Future,
    sync::{Arc, Mutex},
};
use tokio::sync::watch;

pub(crate) fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}
type Gate = dyn Fn(&mut dyn FnMut()) -> ApiResult<()> + Send + Sync;
#[derive(Clone)]
pub(crate) struct Guard {
    gate: Arc<Gate>,
    denied: Arc<Mutex<Option<ApiError>>>,
}
impl Guard {
    pub(crate) fn new(
        gate: impl Fn(&mut dyn FnMut()) -> ApiResult<()> + Send + Sync + 'static,
    ) -> Self {
        Self {
            gate: Arc::new(gate),
            denied: Arc::default(),
        }
    }
    pub(crate) fn run<T>(&self, effect: impl FnOnce() -> T) -> ApiResult<T> {
        if let Some(error) = self.failure() {
            return Err(error);
        }
        let mut effect = Some(effect);
        let mut result = None;
        let answer =
            (self.gate)(&mut || result = Some(effect.take().expect("one admitted effect")()));
        if let Err(error) = answer {
            let mut denied = lock(&self.denied);
            return Err(denied.get_or_insert(error).clone());
        }
        result.ok_or_else(ApiError::internal)
    }
    pub(crate) fn failure(&self) -> Option<ApiError> {
        lock(&self.denied).clone()
    }
}
#[derive(Clone)]
pub(crate) enum Caller {
    #[cfg(test)]
    Test,
    Agent {
        epoch: i64,
        abort: Arc<watch::Sender<bool>>,
    },
    Viewer {
        client: String,
        generation: i64,
        open: Arc<Mutex<bool>>,
    },
    Observer {
        open: Arc<Mutex<bool>>,
    },
}
tokio::task_local! {
    static CALLER: Caller;
    static EFFECT: Guard;
    static RESOURCE: Guard;
}
pub(crate) fn caller() -> Option<Caller> {
    CALLER.try_with(Clone::clone).ok()
}
pub(crate) fn require_caller(observer: bool) -> ApiResult<Caller> {
    let caller =
        caller().ok_or_else(|| ApiError::forbidden("Browser request authority is missing"))?;
    if matches!(caller, Caller::Observer { .. }) && !observer {
        return Err(ApiError::forbidden(
            "Browser observation does not authorize input",
        ));
    }
    Ok(caller)
}
pub(crate) async fn from<T>(caller: Caller, future: impl Future<Output = T>) -> T {
    CALLER.scope(caller, future).await
}
pub(crate) fn current() -> Option<Guard> {
    EFFECT.try_with(Clone::clone).ok()
}
pub(crate) async fn scope<T>(guard: Guard, future: impl Future<Output = T>) -> T {
    EFFECT.scope(guard, future).await
}
/// Capture before spawning a foreground request. Engine event loops and shared
/// context maintenance deliberately do not inherit one caller's authority.
pub(crate) fn inherit<F: Future>(future: F) -> impl Future<Output = F::Output> {
    let guard = current();
    let resource = resource();
    async move {
        let request = async move {
            match guard {
                Some(guard) => scope(guard, future).await,
                None => future.await,
            }
        };
        match resource {
            Some(resource) => with_resource(resource, request).await,
            None => request.await,
        }
    }
}
pub(crate) fn run<T>(effect: impl FnOnce() -> T) -> ApiResult<T> {
    match current() {
        Some(guard) => guard.run(effect),
        None => Ok(effect()),
    }
}
pub(crate) fn check() -> ApiResult<()> {
    run(|| ())
}

/// A browser resource outlives a foreground request/controller. Its scope only
/// carries the original environment and group, never one viewer's lease.
pub(crate) fn resource() -> Option<Guard> {
    RESOURCE.try_with(Clone::clone).ok()
}
pub(crate) async fn with_resource<T>(guard: Guard, future: impl Future<Output = T>) -> T {
    RESOURCE.scope(guard, future).await
}
pub(crate) async fn background<T>(guard: Option<Guard>, future: impl Future<Output = T>) -> T {
    match guard {
        Some(guard) => scope(guard.clone(), with_resource(guard, future)).await,
        None => future.await,
    }
}
