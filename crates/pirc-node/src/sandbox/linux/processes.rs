//! A trusted bubblewrap status pipe identifies the sandbox's PID namespace init.
//! A pidfd pins its identity: no numeric PID is signaled after capture. Missing,
//! late or inconsistent evidence stays unconfirmed, even when the wrapper exits.
//! The runner journals captured identities separately. Host-process revocation
//! and complete environment transitions remain outside this scope.

use std::io::{self, PipeReader, Read};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use command_fds::{CommandFdExt as _, FdMapping};
use serde::Deserialize;
use tokio::task::AbortHandle;

use crate::sandbox::processes::{Identity, ProcessScope, Snapshot, State};

mod kernel;
pub(crate) mod owner;
#[cfg(test)]
mod tests;

pub const STATUS_FD: i32 = 3;
const MAX_RECORD: usize = 8192;

trait Handle: Send + Sync {
    fn exited(&self) -> io::Result<bool>;
    fn kill(&self) -> io::Result<()>;
    fn identity(&self) -> Option<Identity> {
        None
    }
}
trait Kernel: Send + Sync {
    fn wrapper(&self, pid: u32) -> io::Result<Arc<dyn Handle>>;
    fn capture(
        &self,
        wrapper_pid: u32,
        wrapper: &dyn Handle,
        child: &Child,
    ) -> io::Result<Arc<dyn Handle>>;
}

#[derive(Deserialize)]
struct Child {
    #[serde(rename = "child-pid")]
    pid: u32,
    #[serde(rename = "pid-namespace")]
    namespace: u64,
}

struct Inner {
    reader: Option<PipeReader>,
    bytes: Vec<u8>,
    wrapper: Option<(u32, Arc<dyn Handle>)>,
    namespace: Option<Arc<dyn Handle>>,
    identity: Option<Identity>,
    state: State,
    retiring: bool,
    spawned: bool,
}
impl Default for Inner {
    fn default() -> Self {
        Self {
            reader: None,
            bytes: Vec::new(),
            wrapper: None,
            namespace: None,
            identity: None,
            state: State::Observing,
            retiring: false,
            spawned: false,
        }
    }
}

pub struct Scope {
    inner: Arc<Mutex<Inner>>,
    kernel: Arc<dyn Kernel>,
    observer: Mutex<Option<AbortHandle>>,
}
impl Default for Scope {
    fn default() -> Self {
        Self {
            inner: Arc::default(),
            kernel: Arc::new(kernel::Platform),
            observer: Mutex::default(),
        }
    }
}
impl Scope {
    /// All inherited FD mappings must be applied together (command-fds mappings
    /// in separate calls can collide). The pipe is never agent stdout or an RPC.
    pub fn prepare_command(&self, command: &mut tokio::process::Command) -> io::Result<()> {
        self.prepare_with_gate(command, None)
    }
    pub(crate) fn prepare_with_gate(
        &self,
        command: &mut tokio::process::Command,
        gate: Option<std::os::fd::OwnedFd>,
    ) -> io::Result<()> {
        let mut inner = self.inner.lock().unwrap_or_else(|p| p.into_inner());
        if inner.spawned || inner.retiring {
            return Err(io::Error::other("sandbox process scope cannot be reused"));
        }
        let (reader, writer) = std::io::pipe()?;
        nix::fcntl::fcntl(
            &reader,
            nix::fcntl::FcntlArg::F_SETFL(nix::fcntl::OFlag::O_NONBLOCK),
        )?;
        let mut mappings = vec![FdMapping {
            parent_fd: writer.into(),
            child_fd: STATUS_FD,
        }];
        mappings.extend(super::seccomp::mapping()?);
        if let Some(gate) = gate {
            mappings.push(FdMapping {
                parent_fd: gate,
                child_fd: crate::sandbox::terminal_gate::FD,
            });
        }
        command.fd_mappings(mappings).map_err(io::Error::other)?;
        inner.reader = Some(reader);
        inner.bytes.clear();
        Ok(())
    }
}

/// Reads only the first trusted status record. Keep the reader open afterwards:
/// bubblewrap writes the exit record too; closing it early would cause SIGPIPE.
fn record(inner: &mut Inner) -> io::Result<Option<Child>> {
    let Some(reader) = inner.reader.as_mut() else {
        return Ok(None);
    };
    loop {
        if let Some(end) = inner.bytes.iter().position(|b| *b == b'\n') {
            let child: Child =
                serde_json::from_slice(&inner.bytes[..end]).map_err(io::Error::other)?;
            if child.pid <= 1 || child.namespace == 0 {
                return Err(io::Error::other("invalid sandbox process identity"));
            }
            inner.bytes.clear();
            return Ok(Some(child));
        }
        if inner.bytes.len() >= MAX_RECORD {
            return Err(io::Error::other("sandbox process status exceeds limit"));
        }
        let mut chunk = [0u8; 1024];
        match reader.read(&mut chunk) {
            Ok(0) => return Err(io::Error::other("sandbox status ended before capture")),
            Ok(n) => inner.bytes.extend_from_slice(&chunk[..n]),
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => return Ok(None),
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        }
    }
}
fn refresh(inner: &mut Inner, kernel: &dyn Kernel) {
    if inner.state == State::Observing && inner.spawned {
        match record(inner) {
            Ok(Some(child)) => {
                let captured = inner
                    .wrapper
                    .as_ref()
                    .ok_or_else(|| io::Error::other("no wrapper handle"))
                    .and_then(|(pid, wrapper)| kernel.capture(*pid, wrapper.as_ref(), &child));
                match captured {
                    Ok(handle) => {
                        inner.identity = handle.identity();
                        inner.namespace = Some(handle);
                        inner.state = State::Running;
                        if inner.retiring {
                            retire(inner);
                        }
                    }
                    Err(_) => inner.state = State::Unconfirmed,
                }
                // Namespace handle now owns identity, no dependency on wrapper lifetime.
                inner.wrapper = None;
            }
            Err(_) => {
                inner.state = State::Unconfirmed;
                inner.wrapper = None;
            }
            Ok(None) => {}
        }
    }
    if let Some(namespace) = &inner.namespace {
        match namespace.exited() {
            Ok(true) => {
                inner.state = State::Terminated;
                inner.namespace = None;
            }
            Ok(false) => inner.state = State::Running,
            Err(_) => inner.state = State::Unconfirmed,
        }
    }
}
fn retire(inner: &mut Inner) {
    inner.retiring = true;
    if let Some(namespace) = &inner.namespace {
        // Killing is a request, not acknowledgement. Only pidfd readiness below
        // confirms exit; permission errors, unknown or missing handles never do.
        if namespace.exited().is_ok_and(|exited| !exited) {
            let _ = namespace.kill();
        }
    }
}
impl ProcessScope for Scope {
    fn spawned(&self, pid: u32) {
        {
            let mut inner = self.inner.lock().unwrap_or_else(|p| p.into_inner());
            if inner.spawned {
                return;
            }
            inner.spawned = true;
            match self.kernel.wrapper(pid) {
                Ok(handle) => inner.wrapper = Some((pid, handle)),
                Err(_) => {
                    inner.state = State::Unconfirmed;
                    return;
                }
            }
            refresh(&mut inner, self.kernel.as_ref());
        }
        let weak = Arc::downgrade(&self.inner);
        let kernel = self.kernel.clone();
        let task = tokio::spawn(async move {
            let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
            loop {
                let Some(inner) = weak.upgrade() else { return };
                {
                    let mut inner = inner.lock().unwrap_or_else(|p| p.into_inner());
                    refresh(&mut inner, kernel.as_ref());
                    if inner.state != State::Observing {
                        return;
                    }
                    if tokio::time::Instant::now() >= deadline {
                        inner.state = State::Unconfirmed;
                        inner.wrapper = None;
                        return;
                    }
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        });
        *self.observer.lock().unwrap_or_else(|p| p.into_inner()) = Some(task.abort_handle());
    }
    fn terminate(&self) {
        let mut inner = self.inner.lock().unwrap_or_else(|p| p.into_inner());
        refresh(&mut inner, self.kernel.as_ref());
        retire(&mut inner);
    }
    fn state(&self) -> State {
        let mut inner = self.inner.lock().unwrap_or_else(|p| p.into_inner());
        refresh(&mut inner, self.kernel.as_ref());
        inner.state
    }
    fn snapshot(&self) -> Snapshot {
        let mut inner = self.inner.lock().unwrap_or_else(|p| p.into_inner());
        refresh(&mut inner, self.kernel.as_ref());
        Snapshot {
            state: inner.state,
            identity: inner.identity.clone(),
        }
    }
    fn cleanup(&self) {
        {
            let mut inner = self.inner.lock().unwrap_or_else(|p| p.into_inner());
            refresh(&mut inner, self.kernel.as_ref());
            retire(&mut inner);
            if inner.state == State::Observing {
                inner.state = State::Unconfirmed;
            }
            inner.wrapper = None;
            inner.reader = None;
            inner.bytes.clear();
        }
        if let Some(observer) = self
            .observer
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .take()
        {
            observer.abort();
        }
    }
}
impl Drop for Scope {
    fn drop(&mut self) {
        self.terminate();
        if let Some(observer) = self
            .observer
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .take()
        {
            observer.abort();
        }
    }
}

/// Only called by trusted transition reconciliation, never by agent-supplied PIDs.
#[doc(hidden)]
pub async fn retire_saved(identity: &Identity) -> State {
    let handle = match kernel::reopen(identity) {
        Ok(Some(handle)) => handle,
        Ok(None) => return State::Terminated,
        Err(_) => return State::Unconfirmed,
    };
    if handle.kill().is_err() && !handle.exited().unwrap_or(false) {
        return State::Unconfirmed;
    }
    let deadline = tokio::time::Instant::now() + Duration::from_secs(2);
    loop {
        match handle.exited() {
            Ok(true) => return State::Terminated,
            Err(_) => return State::Unconfirmed,
            Ok(false) => {}
        }
        if tokio::time::Instant::now() >= deadline {
            return State::Unconfirmed;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
}
