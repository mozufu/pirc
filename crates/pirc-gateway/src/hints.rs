//! Hint frames for `/api/events` sockets that opt in (`directory=1`,
//! `memory=1`, `schedules=1`, `sessions=1`, `pots=1`, `threads=1`,
//! `approvals=1`, `activity=1`, `budgetRequests=1`, `notifications=1`,
//! `causalRoots=1`): sent outside the session's sequence and never replayed, so
//! clients that treat an unknown event as a reset are unaffected
//! (`daemon/app.ts`).

use std::collections::HashMap;
use std::hash::Hash;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, Weak};

pub type Hint = Arc<dyn Fn() + Send + Sync>;

/// Listeners by key (a user, or `()` for everyone).
pub struct Listeners<K> {
    inner: Mutex<HashMap<K, HashMap<u64, Hint>>>,
    next: AtomicU64,
}

impl<K: Eq + Hash + Clone + Send + Sync + 'static> Listeners<K> {
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            inner: Mutex::new(HashMap::new()),
            next: AtomicU64::new(0),
        })
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<K, HashMap<u64, Hint>>> {
        self.inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    pub fn add(self: &Arc<Self>, key: K, hint: Hint) -> HintGuard {
        let id = self.next.fetch_add(1, Ordering::Relaxed);
        self.lock().entry(key.clone()).or_default().insert(id, hint);
        let weak: Weak<Self> = Arc::downgrade(self);
        HintGuard(Some(Box::new(move || {
            if let Some(listeners) = weak.upgrade() {
                let mut inner = listeners.lock();
                if let Some(set) = inner.get_mut(&key) {
                    set.remove(&id);
                    if set.is_empty() {
                        inner.remove(&key);
                    }
                }
            }
        })))
    }

    /// Call every listener of `key` (outside the lock).
    pub fn notify(&self, key: &K) {
        let hints: Vec<Hint> = self
            .lock()
            .get(key)
            .map(|set| set.values().cloned().collect())
            .unwrap_or_default();
        for hint in hints {
            hint();
        }
    }
}

/// Removes its listener when dropped.
pub struct HintGuard(Option<Box<dyn FnOnce() + Send + Sync>>);

impl Drop for HintGuard {
    fn drop(&mut self) {
        if let Some(remove) = self.0.take() {
            remove();
        }
    }
}

/// The four kinds of hints.
pub struct Hints {
    pub directory: Arc<Listeners<()>>,
    pub memory: Arc<Listeners<String>>,
    pub schedules: Arc<Listeners<String>>,
    pub sessions: Arc<Listeners<String>>,
    /// The owner's pots changed (`pots=1`).
    pub pots: Arc<Listeners<String>>,
    /// The owner's threads or their messages changed (`threads=1`).
    pub threads: Arc<Listeners<String>>,
    /// The owner's model approvals changed (`approvals=1`).
    pub approvals: Arc<Listeners<String>>,
    /// The owner's pot activity grew (`activity=1`).
    pub activity: Arc<Listeners<String>>,
    /// The owner's pot budget requests changed (`budgetRequests=1`).
    pub budget_requests: Arc<Listeners<String>>,
    /// The owner's observation notifications changed (`notifications=1`).
    pub notifications: Arc<Listeners<String>>,
    /// One of the owner's causal roots changed (`causalRoots=1`).
    pub causal_roots: Arc<Listeners<String>>,
}

impl Hints {
    pub fn new() -> Self {
        Self {
            directory: Listeners::new(),
            memory: Listeners::new(),
            schedules: Listeners::new(),
            sessions: Listeners::new(),
            pots: Listeners::new(),
            threads: Listeners::new(),
            approvals: Listeners::new(),
            activity: Listeners::new(),
            budget_requests: Listeners::new(),
            notifications: Listeners::new(),
            causal_roots: Listeners::new(),
        }
    }
}
