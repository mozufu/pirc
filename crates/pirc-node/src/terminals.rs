//! Interactive shells for the side panel (`node/terminals.ts`). Owner:
//! **panels** (M6); M7: **hardening** (the PTY, `terminals/pty.rs`). Not a
//! sandbox in the compatibility path: it has the node account's rights.
//! Explicit `isolated_work` terminals use a guarded native sandbox and the
//! kernel journal; unsupported backends refuse that path. Agents cannot reach
//! the human terminal stream.
//!
//! A PTY (`terminals/pty.rs`: its master close-on-exec from the start,
//! security audit S9) running `/bin/sh -c 'exec "$0" -l' <shell>` as a
//! session leader with the terminal as its controlling tty; the
//! environment `without_secrets` plus
//! `SSH_AUTH_SOCK`, `TERM=xterm-256color`, `COLORTERM=truecolor`,
//! `PIRC_TERMINAL=1`, `HOME`. Limits: 4 live terminals per session, 24 in
//! all; 20..500 columns, 5..200 rows; 256 KiB of scrollback in whole
//! chunks; input over 65,536 UTF-16 units dropped; exited terminals kept
//! 30 minutes. Closing sends SIGHUP to the process group, SIGKILL 2 s later.
//!
//! Each terminal has three tasks: one reads the PTY (scrollback, then
//! `output` to its listeners), one writes it (input and resizes, in order),
//! input is rechecked against its original connection/controller and terminal
//! environment at each nonblocking write or resize; closing cancels the writer.
//! A durable launch record precedes spawn. One observer signals and reaps the
//! shell, retaining its identity until the final signal; panel closure cannot
//! abandon that observer. The recorded outcome is only direct-shell evidence,
//! not containment of detached jobs or all foreground process groups. Then,
//! 50 ms later (to drain what the PTY still
//! holds), the PTY closes and listeners get `exit`. Output reaches
//! listeners while the terminal's lock is held, so an attach sees each byte
//! either in its replay or as output, never both nor neither; exits reach
//! them without it, so a listener may detach then.

use std::collections::{BTreeMap, VecDeque};
use std::path::Path;
use std::sync::{Arc, Mutex, MutexGuard, Weak};
use std::time::Duration;

use indexmap::IndexMap;
use serde::Serialize;
use tokio::sync::{mpsc, watch};

use crate::error::{ApiError, ApiResult};
use crate::services::WeakNode;
use crate::store::Store;

pub(crate) mod host;
mod input;
pub(crate) mod io_owners;
mod isolated;
#[cfg(test)]
mod isolated_tests;
pub(crate) mod journal;
pub mod pty;
pub(crate) mod requests;
mod supervision;
pub(crate) use input::Control;
use input::{Authority, Binding};

const SCROLLBACK_BYTES: usize = 256 * 1024;
const PER_SESSION: usize = 4;
const TOTAL: usize = 24;
const EXITED_RETENTION: Duration = Duration::from_secs(30 * 60);
/// Input longer than this (UTF-16 units) is dropped.
const INPUT_MAX_UNITS: usize = 65_536;
/// What the PTY may still hold when the shell exits.
const DRAIN: Duration = Duration::from_millis(50);
/// SIGHUP, then SIGKILL this much later.
const KILL_GRACE: Duration = Duration::from_secs(2);

/// `TerminalInfo`, as the REST routes and the `ready` frame show it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TerminalInfo {
    /// 8 hex digits.
    pub id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub execution_path: Option<String>,
    pub session_id: String,
    /// The shell's file name.
    pub title: String,
    pub cwd: String,
    pub cols: u16,
    pub rows: u16,
    pub created_at: i64,
    /// `None` while it runs, or when a signal ended it.
    pub exit_code: Option<i32>,
    pub exited: bool,
}

/// What a terminal tells its listeners.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TerminalEvent {
    Output(String),
    /// The shell's exit code; `None` when a signal ended it or the terminal
    /// was closed.
    Exit(Option<i32>),
}

pub type Listener = Arc<dyn Fn(&TerminalEvent) + Send + Sync>;

/// `TerminalManager`.
pub struct Terminals {
    node: WeakNode,
    registry: Arc<Mutex<Registry>>,
}

#[derive(Default)]
struct Registry {
    /// By id, in creation order (`list`).
    terminals: IndexMap<String, Arc<Entry>>,
    closing: bool,
    next_listener: u64,
}

struct Entry {
    // Immutable execution provenance; display metadata is not closure authority.
    host_management: bool,
    record: Option<journal::Record>,
    binding: Option<Binding>,
    stopping: watch::Sender<bool>,
    state: Mutex<EntryState>,
    pty: mpsc::UnboundedSender<PtyCommand>,
    /// Published only after the observer records its durable outcome.
    exited: watch::Receiver<Option<ApiResult<()>>>,
}

struct EntryState {
    closing: bool,
    info: TerminalInfo,
    /// Retained output (raw bytes) for replay on attach.
    scrollback: VecDeque<Vec<u8>>,
    scrollback_bytes: usize,
    listeners: Vec<(u64, Listener)>,
    decoder: Utf8Stream,
}

struct PtyCommand {
    authority: Authority,
    action: Action,
}

enum Action {
    Write(Vec<u8>),
    Resize { rows: f64, cols: f64 },
}

struct Environment<'a> {
    work: Option<isolated::Work>,
    host: Option<host::Grant>,
    vars: BTreeMap<String, String>,
    binding: Option<Binding>,
    journal: Option<(&'a crate::services::Node, &'a rusqlite::Connection)>,
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

impl Entry {
    fn state(&self) -> MutexGuard<'_, EntryState> {
        lock(&self.state)
    }
}

/// `defaultShell`: the configured shell or `$SHELL` when absolute, else
/// `/bin/sh`.
pub fn default_shell(preferred: Option<&str>, shell: Option<&str>) -> String {
    [preferred, shell]
        .into_iter()
        .flatten()
        .find(|shell| shell.starts_with('/'))
        .unwrap_or("/bin/sh")
        .to_owned()
}

/// `clamp(value, min, max, fallback)`: floored, the fallback for a
/// non-number.
pub(crate) fn clamp(value: f64, min: u16, max: u16, fallback: u16) -> u16 {
    let number = if value.is_finite() {
        value.floor()
    } else {
        f64::from(fallback)
    };
    number.clamp(f64::from(min), f64::from(max)) as u16
}

/// What [`Terminals::attach`] gives: the terminal now and its retained
/// output, decoded on its own (a split code point at its start is U+FFFD).
pub struct Attached {
    pub info: TerminalInfo,
    pub replay: String,
    /// For [`Terminals::detach`].
    pub listener: u64,
}

impl Terminals {
    pub fn new(node: WeakNode) -> Self {
        Self {
            node,
            registry: Arc::default(),
        }
    }

    fn registry(&self) -> MutexGuard<'_, Registry> {
        lock(&self.registry)
    }

    /// Every terminal of the session, exited ones too.
    pub fn list(&self, session_id: &str) -> Vec<TerminalInfo> {
        let entries: Vec<Arc<Entry>> = self.registry().terminals.values().cloned().collect();
        entries
            .iter()
            .filter_map(|entry| {
                let state = entry.state();
                (!state.closing).then(|| state.info.clone())
            })
            .filter(|info| info.session_id == session_id)
            .collect()
    }

    /// Start a plain shell in `cwd` (409 `conflict` past the limits, 503 while
    /// the node shuts down, 500 `runner_unavailable` "Could not start
    /// shell: ..." when it cannot start). Tests only: clients get isolated
    /// work or a reviewed host terminal.
    #[cfg(test)]
    pub(crate) fn create(
        &self,
        session_id: &str,
        cwd: &Path,
        cols: Option<i64>,
        rows: Option<i64>,
        control: (&str, i64),
    ) -> ApiResult<TerminalInfo> {
        self.create_selected(session_id, cwd, cols, rows, control, None)
    }

    fn create_selected(
        &self,
        session_id: &str,
        cwd: &Path,
        cols: Option<i64>,
        rows: Option<i64>,
        control: (&str, i64),
        host: Option<host::Grant>,
    ) -> ApiResult<TerminalInfo> {
        let node = self.node.upgrade().ok_or_else(ApiError::internal)?;
        let shell = default_shell(node.config.terminal_shell.as_deref(), node.env.get("SHELL"));
        let mut env = pirc_config::env_allowlist::without_secrets(&node.env, &[]);
        // Only the human types here, and on macOS the ssh-agent socket comes
        // from launchd, not a profile: `git push` over ssh needs it.
        if let Some(socket) = node.env.get("SSH_AUTH_SOCK").filter(|s| !s.is_empty()) {
            env.insert("SSH_AUTH_SOCK".into(), socket.into());
        }
        let home = node
            .env
            .get("HOME")
            .map_or_else(|| node.env.home().display().to_string(), str::to_owned);
        env.insert("HOME".into(), home);
        // Hold the same database lock as fence acceptance through PTY creation.
        let db = node.db.lock();
        crate::execution_fences::require_open(&db, session_id)?;
        db.validate_lease(session_id, control.0, control.1)?;
        let binding = Binding::capture(&node, &db, session_id, cwd)?;
        self.spawn(
            session_id,
            cwd,
            cols.map_or(f64::NAN, |cols| cols as f64),
            rows.map_or(f64::NAN, |rows| rows as f64),
            &shell,
            Environment {
                work: None,
                host,
                vars: env,
                binding: Some(binding),
                journal: Some((&node, &db)),
            },
        )
    }

    /// `create` with the shell and its environment chosen.
    fn spawn(
        &self,
        session_id: &str,
        cwd: &Path,
        cols: f64,
        rows: f64,
        shell: &str,
        environment: Environment<'_>,
    ) -> ApiResult<TerminalInfo> {
        let Environment {
            mut work,
            host,
            vars: mut env,
            binding,
            journal,
        } = environment;
        if work.is_some() && host.is_some() {
            return Err(ApiError::internal());
        }
        let mut registry = self.registry();
        if registry.closing {
            return Err(ApiError::runner_unavailable("Gateway is shutting down"));
        }
        let live: Vec<String> = registry
            .terminals
            .values()
            .map(|entry| entry.state())
            .filter(|state| !state.info.exited)
            .map(|state| state.info.session_id.clone())
            .collect();
        if live.iter().filter(|id| *id == session_id).count() >= PER_SESSION {
            return Err(requests::capacity_error(format!(
                "At most {PER_SESSION} terminals per session"
            )));
        }
        if live.len() >= TOTAL {
            return Err(requests::capacity_error("Too many open terminals"));
        }
        // Opening a new terminal discards this session's exited ones.
        registry.terminals.retain(|_, entry| {
            let state = entry.state();
            !(state.info.exited && state.info.session_id == session_id)
        });
        let cols = clamp(cols, 20, 500, 80);
        let rows = clamp(rows, 5, 200, 24);
        let id = crate::util::uuid()[..8].to_owned();
        if registry.terminals.contains_key(&id) {
            return Err(ApiError::conflict(
                "Terminal identity collision; request again",
            ));
        }
        let info = TerminalInfo {
            execution_path: if work.is_some() {
                Some("isolated_work".into())
            } else {
                host.as_ref().map(|_| "host_management".into())
            },
            id: id.clone(),
            session_id: session_id.into(),
            title: shell.rsplit('/').next().unwrap_or("shell").into(),
            cwd: cwd.to_string_lossy().into_owned(),
            cols,
            rows,
            created_at: crate::util::now_ms(),
            exit_code: None,
            exited: false,
        };

        env.insert("TERM".into(), "xterm-256color".into());
        env.insert("COLORTERM".into(), "truecolor".into());
        env.insert("PIRC_TERMINAL".into(), "1".into());

        let (record, launch) = if work.is_some() {
            let (node, db) = journal.ok_or_else(ApiError::internal)?;
            let workspace = &binding.as_ref().ok_or_else(ApiError::internal)?.workspace;
            let (record, launch) = crate::store::atomic(db, |db| {
                io_owners::record(
                    db,
                    &node.incarnation,
                    &work.as_ref().ok_or_else(ApiError::internal)?.owner,
                )?;
                let row = db.get_session(session_id)?;
                let launch = crate::process_journal::reserve_terminal(
                    db,
                    session_id,
                    workspace,
                    row.runner_epoch,
                    &node.incarnation,
                )?;
                let record =
                    journal::Record::scoped(node, db, session_id, workspace, cwd, &launch)?;
                if let Some(permit) = work.as_ref().and_then(|work| work.request.as_ref()) {
                    requests::link(db, node, permit, &info, &record)?;
                }
                Ok((record, launch))
            })?;
            (Some(record), Some(launch))
        } else if let Some(grant) = &host {
            let (node, db) = journal.ok_or_else(ApiError::internal)?;
            let workspace = &binding.as_ref().ok_or_else(ApiError::internal)?.workspace;
            let record = crate::store::atomic(db, |db| {
                let record = journal::Record::reserve_atomic(node, db, session_id, workspace, cwd)?;
                host::consume(db, node, grant, &info, &record)?;
                Ok(record)
            })?;
            (Some(record), None)
        } else {
            let record = journal
                .map(|(node, db)| {
                    let workspace = &binding.as_ref().ok_or_else(ApiError::internal)?.workspace;
                    journal::Record::reserve(node, db, session_id, workspace, cwd)
                })
                .transpose()?;
            (record, None)
        };
        let launched = (|| {
            let (pty, slave) = pty::open(rows, cols).map_err(|error| {
                crate::log::error(&format!("terminal: no PTY: {error}"));
                ApiError::internal()
            })?;
            // Through /bin/sh and exec: spawned directly, some shells (fish,
            // zsh) come up without the PTY as their controlling terminal and
            // lose job control. It is a session leader (Bun's `detached`), so a
            // hangup to the group reaches its jobs too.
            let spawned = if let Some(work) = &mut work {
                let (gate, writer) =
                    crate::sandbox::terminal_gate::pipe().map_err(|_| ApiError::internal())?;
                let mut command = work
                    .prepared
                    .terminal_command(gate)
                    .map_err(|_| ApiError::internal())?;
                env.extend(work.prepared.env.iter().cloned());
                env.remove("SSH_AUTH_SOCK");
                crate::sandbox::launch_guard::validate_bootstrap(&env)
                    .map_err(|e| ApiError::runner_unavailable(e.to_string()))?;
                env.insert(
                    crate::sandbox::launch_guard::ENV.into(),
                    crate::sandbox::terminal_gate::MODE.into(),
                );
                command.current_dir(cwd).env_clear().envs(&env);
                work.gate = Some(writer);
                pty::spawn_isolated(slave, command)
            } else {
                pty::spawn(slave, shell, cwd, &env)
            };
            let child = spawned.map_err(|error| {
                ApiError::new(
                    500,
                    "runner_unavailable",
                    format!(
                        "Could not start shell: {}",
                        pirc_agent::tools::js::fs_error(&error, "posix_spawn", Some("/bin/sh"))
                    ),
                )
            })?;
            Ok::<_, ApiError>((pty, child))
        })();
        let (pty, child) = match launched {
            Ok(pair) => pair,
            Err(error) => {
                if let (Some(record), Some((_, db))) = (&record, journal) {
                    // The run outcome and the linked request's reason commit together.
                    crate::store::atomic(db, |db| {
                        if let Some(launch) = &launch {
                            crate::process_journal::not_started(db, launch)?;
                        }
                        record.finish(db, "not_started")?;
                        requests::start_failed(db, &record.0, error.code.as_ref())
                    })?;
                }
                return Err(error);
            }
        };
        if let (Some(work), Some(pid)) = (&work, child.id()) {
            work.prepared.process_spawned(pid);
        }
        // Once spawn succeeds, the observer must own the child even if the
        // journal update fails. A request error cannot drop supervision.
        let running = match (&record, journal) {
            (Some(record), Some((_, db))) => record.finish(db, "running"),
            _ => Ok(()),
        };
        let (exited_tx, exited) = watch::channel(None);
        let (commands, receiver) = mpsc::unbounded_channel();
        let entry = Arc::new(Entry {
            host_management: host.is_some(),
            record,
            binding,
            stopping: watch::channel(false).0,
            state: Mutex::new(EntryState {
                closing: false,
                info: info.clone(),
                scrollback: VecDeque::new(),
                scrollback_bytes: 0,
                listeners: Vec::new(),
                decoder: Utf8Stream::default(),
            }),
            pty: commands,
            exited,
        });
        if running.is_err() {
            kill(&entry);
        }
        registry.terminals.insert(id, entry.clone());
        drop(registry);
        run(
            self.node.clone(),
            Arc::downgrade(&self.registry),
            entry,
            ObservedChild {
                child,
                work: work.zip(launch),
            },
            pty,
            receiver,
            exited_tx,
        );
        running?;
        Ok(info)
    }

    fn lookup(&self, session_id: &str, id: &str) -> ApiResult<Arc<Entry>> {
        self.registry()
            .terminals
            .get(id)
            .filter(|entry| {
                let state = entry.state();
                !state.closing && state.info.session_id == session_id
            })
            .cloned()
            .ok_or_else(|| ApiError::not_found("Terminal not found"))
    }

    /// Subscribe `listener`; `ready` gets the terminal and its replay before
    /// any output reaches the listener.
    pub fn attach(
        &self,
        session_id: &str,
        id: &str,
        listener: Listener,
        ready: impl FnOnce(&TerminalInfo, &str),
    ) -> ApiResult<Attached> {
        let entry = self.lookup(session_id, id)?;
        let listener_id = {
            let mut registry = self.registry();
            registry.next_listener += 1;
            registry.next_listener
        };
        let mut state = entry.state();
        if state.closing {
            return Err(ApiError::not_found("Terminal is closed"));
        }
        state.listeners.push((listener_id, listener));
        // Decoded on its own (TS): a split code point at its start is
        // dropped as U+FFFD, not mangled.
        let bytes: Vec<u8> = state.scrollback.iter().flatten().copied().collect();
        let mut decoder = Utf8Stream::default();
        let mut replay = decoder.decode(&bytes);
        replay.push_str(&decoder.finish());
        let info = state.info.clone();
        ready(&info, &replay);
        Ok(Attached {
            info,
            replay,
            listener: listener_id,
        })
    }

    /// Unsubscribe (the terminal lives on; nothing when it is gone).
    pub fn detach(&self, id: &str, listener: u64) {
        let entry = self.registry().terminals.get(id).cloned();
        if let Some(entry) = entry {
            entry
                .state()
                .listeners
                .retain(|(known, _)| *known != listener);
        }
    }

    /// Queue input with its original controller. Authority is checked again at
    /// each nonblocking PTY write, including after backpressure or takeover.
    pub(crate) fn input_controlled(
        &self,
        session_id: &str,
        id: &str,
        data: &str,
        control: Arc<Control>,
    ) -> ApiResult<()> {
        self.queue_input(session_id, id, data, Authority::Client(control))
    }

    fn queue_input(
        &self,
        session_id: &str,
        id: &str,
        data: &str,
        authority: Authority,
    ) -> ApiResult<()> {
        let entry = self.lookup(session_id, id)?;
        if entry.state().info.exited || data.encode_utf16().count() > INPUT_MAX_UNITS {
            return Ok(());
        }
        input::authorized(&self.node, &entry, &authority, |_| Ok(()))?;
        entry
            .pty
            .send(PtyCommand {
                authority,
                action: Action::Write(data.as_bytes().to_vec()),
            })
            .map_err(|_| ApiError::not_found("Terminal is closed"))
    }

    /// Resize in queue order under the same authority as typed input. The
    /// visible dimensions change only when the PTY accepted the resize.
    pub(crate) fn resize_controlled(
        &self,
        session_id: &str,
        id: &str,
        cols: f64,
        rows: f64,
        control: Arc<Control>,
    ) -> ApiResult<()> {
        self.queue_resize(session_id, id, cols, rows, Authority::Client(control))
    }

    fn queue_resize(
        &self,
        session_id: &str,
        id: &str,
        cols: f64,
        rows: f64,
        authority: Authority,
    ) -> ApiResult<()> {
        let entry = self.lookup(session_id, id)?;
        if entry.state().info.exited {
            return Ok(());
        }
        input::authorized(&self.node, &entry, &authority, |_| Ok(()))?;
        entry
            .pty
            .send(PtyCommand {
                authority,
                action: Action::Resize { rows, cols },
            })
            .map_err(|_| ApiError::not_found("Terminal is closed"))
    }

    #[cfg(test)]
    fn input(&self, session_id: &str, id: &str, data: &str) -> ApiResult<()> {
        self.queue_input(session_id, id, data, Authority::Test)
    }
    #[cfg(test)]
    fn resize(&self, session_id: &str, id: &str, cols: f64, rows: f64) -> ApiResult<()> {
        self.queue_resize(session_id, id, cols, rows, Authority::Test)
    }

    /// 404 `not_found` "Terminal not found".
    pub fn close(&self, session_id: &str, terminal_id: &str) -> ApiResult<()> {
        let entry = self.lookup(session_id, terminal_id)?;
        kill(&entry);
        Ok(())
    }

    /// Close every terminal of a session; the entries closed.
    fn close_session(&self, session_id: &str) -> Vec<Arc<Entry>> {
        let entries: Vec<Arc<Entry>> = self
            .registry()
            .terminals
            .values()
            .filter(|entry| entry.state().info.session_id == session_id)
            .cloned()
            .collect();
        for entry in &entries {
            kill(entry);
        }
        entries
    }

    /// Close a session's terminals and wait for their processes to exit
    /// (chat deletion, before its files go).
    pub async fn dispose_session(&self, session_id: &str) -> ApiResult<()> {
        self.stop_live(session_id).await?;
        self.require_settled(session_id)
    }
    pub(crate) async fn stop_live(&self, session: &str) -> ApiResult<()> {
        supervision::settle(self.close_session(session)).await
    }
    pub(crate) fn require_settled(&self, session: &str) -> ApiResult<()> {
        if let Some(node) = self.node.upgrade() {
            journal::require_settled(&node.db.lock(), session)?;
        }
        Ok(())
    }

    /// Refuse new terminals, request all stops, and join bounded observers.
    pub async fn shutdown(&self) {
        let entries = {
            let mut registry = self.registry();
            registry.closing = true;
            registry.terminals.values().cloned().collect::<Vec<_>>()
        };
        for entry in &entries {
            kill(entry);
        }
        if let Err(error) = supervision::settle(entries).await {
            crate::log::error(&format!("terminal shutdown: {}", error.code));
        }
    }
}

/// Hide the panel and cancel queued input; only its observer signals/reaps the
/// child. Retain the entry so a canceled close/deletion cannot lose observation.
fn kill(entry: &Arc<Entry>) {
    let listeners = {
        let mut state = entry.state();
        state.closing = true;
        entry.stopping.send_replace(true);
        std::mem::take(&mut state.listeners)
    };
    for (_, listener) in listeners {
        listener(&TerminalEvent::Exit(None));
    }
}

/// Append output to the scrollback (whole chunks dropped from the front
/// past the limit, never the last one) and hand it to the listeners.
fn output(entry: &Entry, chunk: &[u8]) {
    let mut state = entry.state();
    state.scrollback.push_back(chunk.to_vec());
    state.scrollback_bytes += chunk.len();
    while state.scrollback_bytes > SCROLLBACK_BYTES && state.scrollback.len() > 1 {
        let dropped = state.scrollback.pop_front().map_or(0, |chunk| chunk.len());
        state.scrollback_bytes -= dropped;
    }
    let data = state.decoder.decode(chunk);
    if !data.is_empty() {
        let event = TerminalEvent::Output(data);
        for (_, listener) in &state.listeners {
            listener(&event);
        }
    }
}

struct ObservedChild {
    child: Box<dyn process_wrap::tokio::ChildWrapper>,
    work: Option<(isolated::Work, crate::process_journal::Launch)>,
}

/// The terminal's tasks: see the module documentation.
fn run(
    node: WeakNode,
    registry: Weak<Mutex<Registry>>,
    entry: Arc<Entry>,
    observed: ObservedChild,
    pty: pty::Master,
    mut commands: mpsc::UnboundedReceiver<PtyCommand>,
    exited: watch::Sender<Option<ApiResult<()>>>,
) {
    let ObservedChild { child, work } = observed;
    let reader = Arc::new(pty);
    let writer = reader.clone();
    let reading = {
        let entry = entry.clone();
        tokio::spawn(async move {
            let mut buffer = vec![0; 64 * 1024];
            // EOF or EIO once every holder of the terminal is gone.
            while let Ok(n @ 1..) = reader.read(&mut buffer).await {
                output(&entry, &buffer[..n]);
            }
        })
    };
    let writing = {
        let node = node.clone();
        let entry = entry.clone();
        let mut stopping = entry.stopping.subscribe();
        tokio::spawn(async move {
            let work = async {
                while let Some(command) = commands.recv().await {
                    if let Err(error) = input::execute(&node, &entry, &writer, &command).await {
                        command.authority.rejected(error);
                    }
                }
            };
            tokio::select! {
                biased;
                _ = stopping.wait_for(|stopped| *stopped) => {},
                () = work => {},
            }
        })
    };
    tokio::spawn(async move {
        let observed = if let Some((work, launch)) = work {
            isolated::observe(&node, &entry, child, work, launch).await
        } else {
            supervision::observe(child, entry.stopping.subscribe()).await
        };
        let code = observed.as_ref().ok().and_then(|status| status.code());
        // A natural child exit must also stop queued input immediately. Keep
        // this separate from `closing`, which hides manually closed panels.
        {
            let _state = entry.state();
            entry.stopping.send_replace(true);
        }
        let io = supervision::retire_io(reading, writing).await;
        let mut result = observed.map(|_| ()).and(io);
        if let Some(record) = &entry.record {
            result = node
                .upgrade()
                .ok_or_else(journal::unresolved)
                .and_then(|node| {
                    record
                        .finish(
                            &node.db.lock(),
                            if result.is_ok() && !entry.host_management {
                                "settled"
                            } else {
                                "unconfirmed"
                            },
                        )
                        .map_err(|_| journal::unresolved())?;
                    result
                });
        }
        {
            let mut state = entry.state();
            // Only confirmed direct-shell/I/O closure frees the live quota.
            // Detached host authority remains durably unconfirmed separately.
            state.info.exited = result.is_ok();
            state.info.exit_code = code;
            if result.is_err() {
                state.closing = true;
            }
        }
        exited.send_replace(Some(result));
        // Successful disposal above requires both I/O owners to have settled.
        // An unconfirmed result retains uncertainty rather than claiming closure.
        let listeners: Vec<Listener> = entry
            .state()
            .listeners
            .iter()
            .map(|(_, listener)| listener.clone())
            .collect();
        for listener in listeners {
            listener(&TerminalEvent::Exit(code));
        }
        // An exited terminal stays readable for a while, then its
        // scrollback is freed.
        tokio::time::sleep(EXITED_RETENTION).await;
        let Some(registry) = registry.upgrade() else {
            return;
        };
        let mut registry = lock(&registry);
        let id = entry.state().info.id.clone();
        if registry
            .terminals
            .get(&id)
            .is_some_and(|current| Arc::ptr_eq(current, &entry))
        {
            registry.terminals.shift_remove(&id);
        }
    });
}

/// `TextDecoder` (UTF-8, BOM stripped once) fed chunk by chunk
/// (`stream: true`): an incomplete sequence at a chunk's end waits for the
/// next one; invalid bytes are U+FFFD (maximal subparts, as WHATWG).
#[derive(Default)]
pub(crate) struct Utf8Stream {
    pending: Vec<u8>,
    bom_seen: bool,
}

impl Utf8Stream {
    pub(crate) fn decode(&mut self, chunk: &[u8]) -> String {
        self.pending.extend_from_slice(chunk);
        let mut out = String::new();
        let mut rest: &[u8] = &self.pending;
        loop {
            match std::str::from_utf8(rest) {
                Ok(text) => {
                    out.push_str(text);
                    rest = &[];
                    break;
                }
                Err(error) => {
                    let (valid, after) = rest.split_at(error.valid_up_to());
                    out.push_str(std::str::from_utf8(valid).unwrap_or_default());
                    match error.error_len() {
                        Some(len) => {
                            out.push('\u{FFFD}');
                            rest = &after[len..];
                        }
                        None => {
                            rest = after;
                            break;
                        }
                    }
                }
            }
        }
        self.pending = rest.to_vec();
        self.strip_bom(out)
    }

    /// The end of the stream: an incomplete sequence is U+FFFD.
    pub(crate) fn finish(&mut self) -> String {
        if self.pending.is_empty() {
            return String::new();
        }
        self.pending.clear();
        self.strip_bom("\u{FFFD}".to_owned())
    }

    fn strip_bom(&mut self, text: String) -> String {
        if self.bom_seen || text.is_empty() {
            return text;
        }
        self.bom_seen = true;
        match text.strip_prefix('\u{FEFF}') {
            Some(rest) => rest.to_owned(),
            None => text,
        }
    }
}

#[cfg(test)]
mod tests;

#[cfg(test)]
#[path = "terminals/input_tests.rs"]
mod input_tests;

#[cfg(test)]
#[path = "terminals/supervision_tests.rs"]
mod supervision_tests;
