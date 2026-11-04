//! A kernel-owned process scope is stronger than a process group: descendants
//! can call setsid. This evidence covers only the captured sandbox, not host
//! commands, terminals, browser contexts or effects already sent. A saved
//! identity needs fresh kernel validation after Node restart.

use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum State {
    Unsupported,
    Observing,
    Running,
    Terminated,
    Unconfirmed,
}

/// Kernel identity captured while both wrapper and namespace init are pinned.
/// Boot and observer namespace are checked before any saved PID is consulted.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Identity {
    pub boot_id: String,
    pub observer_namespace: u64,
    pub namespace: u64,
    pub pid: u32,
    pub start_ticks: u64,
}

/// The Node process that owns host-side PTY I/O, not a namespace init and never
/// a signal target. Its whole thread group must end before restart settlement.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ObserverIdentity {
    pub version: u32,
    pub boot_id: String,
    pub observer_namespace: u64,
    pub pid: u32,
    pub start_ticks: u64,
}

#[derive(Clone, Debug)]
pub struct Snapshot {
    pub state: State,
    pub identity: Option<Identity>,
}

pub trait ProcessScope: Send + Sync {
    /// The trusted wrapper's PID, while it is still owned and unreaped.
    fn spawned(&self, pid: u32);
    fn terminate(&self);
    fn state(&self) -> State;
    fn snapshot(&self) -> Snapshot;
    /// Final wrapper teardown; release observation FDs without inventing proof.
    fn cleanup(&self);
}
