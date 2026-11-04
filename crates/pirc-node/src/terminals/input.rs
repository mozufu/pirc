//! Typed input retains its original connection, controller and terminal binding.
//! Only a nonblocking write/ioctl runs under the DB/connection/entry locks. A
//! readiness wait never holds those locks; every partial write checks again.
use super::*;
use crate::services::Node;
use crate::store::Store;
use pirc_protocol::Mode;
use rusqlite::Connection;

pub(crate) struct Control {
    pub client: String,
    pub generation: i64,
    pub open: Arc<Mutex<bool>>,
    pub rejected: Arc<dyn Fn(ApiError) + Send + Sync>,
}

pub(super) enum Authority {
    Client(Arc<Control>),
    /// Only low-level PTY tests can omit a real Node and control lease.
    #[cfg(test)]
    Test,
}
impl Authority {
    pub(super) fn rejected(&self, error: ApiError) {
        match self {
            Self::Client(control) => {
                let connected = *lock(&control.open);
                if connected {
                    (control.rejected)(error);
                }
            }
            #[cfg(test)]
            Self::Test => {}
        }
    }
}

pub(super) struct Binding {
    pub(super) workspace: String,
    path: String,
    mode: Mode,
}
impl Binding {
    pub(super) fn capture(
        node: &Node,
        db: &Connection,
        session: &str,
        cwd: &Path,
    ) -> ApiResult<Self> {
        if node.closing() || !node.config.terminals_enabled {
            return Err(ApiError::forbidden(
                "Terminals are unavailable on this node",
            ));
        }
        db.require_session_available(session)?;
        let row = db.get_session(session)?;
        let workspace = db.get_workspace(&row.workspace_id)?;
        let mode = node.workspace_mode(&workspace)?;
        let root = crate::chat::session_root(&workspace, session, &mode)?;
        if root != cwd {
            return Err(stale_environment());
        }
        Ok(Self {
            workspace: workspace.id,
            path: workspace.canonical_path,
            mode,
        })
    }
    fn check(&self, node: &Node, db: &Connection, session: &str) -> ApiResult<()> {
        if node.closing() || !node.config.terminals_enabled {
            return Err(ApiError::forbidden(
                "Terminals are unavailable on this node",
            ));
        }
        db.require_session_available(session)?;
        crate::execution_fences::require_open(db, session)?;
        let row = db.get_session(session)?;
        if row.workspace_id != self.workspace {
            return Err(stale_environment());
        }
        let workspace = db.get_workspace(&row.workspace_id)?;
        if workspace.canonical_path != self.path || node.workspace_mode(&workspace)? != self.mode {
            return Err(stale_environment());
        }
        Ok(())
    }
}
fn stale_environment() -> ApiError {
    ApiError::new(
        409,
        "stale_environment",
        "The terminal environment changed; open a new terminal",
    )
}
fn closed() -> ApiError {
    ApiError::not_found("Terminal is closed")
}

/// The same DB mutex serializes fence acceptance and lease takeover. Closing a
/// connection or terminal uses the locks below, so a close cannot overtake this
/// particular write and leave later queued bytes admitted by a stale check.
pub(super) fn authorized<T>(
    weak: &WeakNode,
    entry: &Entry,
    authority: &Authority,
    effect: impl FnOnce(&mut EntryState) -> ApiResult<T>,
) -> ApiResult<T> {
    match authority {
        Authority::Client(control) => {
            let node = weak.upgrade().ok_or_else(closed)?;
            let db = node.db.lock();
            // Session identity is fixed for this entry, even after removal from
            // the live registry. Do not resolve a newer terminal by its id.
            let session = entry.state().info.session_id.clone();
            entry
                .binding
                .as_ref()
                .ok_or_else(ApiError::internal)?
                .check(&node, &db, &session)?;
            db.validate_lease(&session, &control.client, control.generation)?;
            let connected = lock(&control.open);
            if !*connected {
                return Err(closed());
            }
            let mut state = entry.state();
            if state.closing || state.info.exited || *entry.stopping.borrow() {
                return Err(closed());
            }
            effect(&mut state)
        }
        #[cfg(test)]
        Authority::Test => {
            let mut state = entry.state();
            if state.closing || state.info.exited || *entry.stopping.borrow() {
                return Err(closed());
            }
            effect(&mut state)
        }
    }
}

pub(super) async fn execute(
    node: &WeakNode,
    entry: &Entry,
    writer: &pty::Master,
    command: &PtyCommand,
) -> ApiResult<()> {
    match &command.action {
        Action::Write(data) => {
            let mut bytes = data.as_slice();
            while !bytes.is_empty() {
                // Check before a potentially long wait, and again under the
                // admission lock after readiness wakes. Partial bytes already
                // accepted by the kernel cannot be recalled.
                authorized(node, entry, &command.authority, |_| Ok(()))?;
                let mut ready = writer.writable().await.map_err(|_| closed())?;
                let result = authorized(node, entry, &command.authority, |_| {
                    Ok(ready.try_io(|fd| Ok(rustix::io::write(fd.get_ref(), bytes)?)))
                })?;
                match result {
                    Ok(Ok(0)) => return Err(closed()),
                    Ok(Ok(n)) => bytes = &bytes[n..],
                    Ok(Err(error)) if error.kind() == std::io::ErrorKind::Interrupted => {}
                    Ok(Err(_)) => return Err(closed()),
                    Err(_) => {} // WouldBlock: release all locks and wait again.
                }
            }
            Ok(())
        }
        Action::Resize { rows, cols } => authorized(node, entry, &command.authority, |state| {
            let rows = clamp(*rows, 5, 200, state.info.rows);
            let cols = clamp(*cols, 20, 500, state.info.cols);
            writer.resize(rows, cols).map_err(|_| closed())?;
            state.info.rows = rows;
            state.info.cols = cols;
            Ok(())
        }),
    }
}
