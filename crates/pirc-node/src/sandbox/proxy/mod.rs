//! The native sandboxes' filtering proxy, shared by the Linux backend (a
//! Unix socket the in-sandbox bridge exposes as `127.0.0.1:3128` and
//! `:1080`) and the macOS backend (a loopback TCP port the Seatbelt profile
//! allows). Owner: **network**. Ported from sandbox-runtime 0.0.78
//! `mux-proxy.js`, `http-proxy.js`, `socks-proxy.js` and
//! `sandbox-manager.js` `filterNetworkRequest` (Apache-2.0, see
//! `crates/pirc-node/NOTICE`), for the settings pirc passes (`srtSettings`
//! in `node/sandbox.ts`): no TLS termination, MITM socket, credential
//! masking, parent proxy (the node drops `*_PROXY` from srt's environment)
//! or ask callback (the srt CLI has none; approvals arrive as new settings,
//! here [`Allowlist::set_approved`]).
//!
//! - One listener, srt's mux: a first byte of `0x04` or `0x05` is SOCKS
//!   ([`socks`]), anything else HTTP ([`http`]).
//! - Every client presents the session's [`ProxyAuth`] token, as srt does
//!   by default (`proxyAuthToken`, only absent when an external proxy port
//!   is configured): HTTP `Proxy-Authorization: Basic`, SOCKS5 RFC 1929.
//!   On macOS the proxy's port is reachable by every local process (and by
//!   other sessions with `allowLocalBinding`). On Linux the socket sits in
//!   the session's temp directory, inside the node's private parent of
//!   them all (`common::NodeTmp`), which every other session's read rules
//!   hide: the 0700 modes alone keep nothing apart, since every sandbox
//!   runs as the node's uid. The token is defence in depth there.
//! - A destination passes [`Allowlist::check`] (`filterNetworkRequest`:
//!   [`pattern::is_valid_host`], canonicalization, denied entries first,
//!   then allowed and approved ones), then a host name is resolved and its
//!   addresses vetted by [`address::Guard`] before the proxy connects.
//!
//! `allowLocalBinding` and `allowUnixSockets` are not the proxy's: on
//! Linux the agent has its own network namespace, so it may bind and
//! connect to its own loopback freely (no host service is reachable there)
//! and `allowLocalBinding` changes nothing; Unix sockets are not filtered
//! (pirc runs srt with `allowAllUnixSockets` on Linux, so no seccomp), only
//! hidden by the read rules. So the proxy is the only *network* way out on
//! Linux, not the only way out: a visible host daemon socket that resolves
//! or connects for its clients bypasses it (the name-service sockets are
//! hidden for that reason; see the Linux backend). On macOS both are Seatbelt rules in the
//! profile (`allowLocalBinding` also opens `localhost:*` outbound, which is
//! why the token matters there); the proxy only needs its port
//! ([`ProxyListener::loopback`]).
//!
//! Beyond srt (M6): per-session and node-wide connection caps, since this
//! proxy shares the node's fd table; deadlines for request heads and SOCKS
//! handshakes (Node's server had its own header timeouts, the SOCKS
//! library none). Only authenticated connections count against a
//! session's cap ([`MAX_CONNECTIONS`]). Until a client authenticates it
//! is one of a separate waiting set ([`MAX_UNAUTHENTICATED`], as large as
//! the cap, so a burst of the session's own clients fits) for at most
//! [`AUTH_TIMEOUT`]. A new connection is never refused because that set
//! is full: the oldest connection still waiting is closed instead. So a
//! client without the token cannot use up the session's own connections,
//! and holding idle connections no longer shuts new ones out. The
//! residual risk: a client that opens connections faster than the
//! session's clients send their request heads (the whole set within that
//! time) can still evict them before they authenticate. On Linux only
//! the session itself and host processes reach the socket; on macOS any
//! local process can. Host-name lookups run on tokio's blocking pool, at
//! most [`MAX_LOOKUPS`] per session (a lookup's thread outlives a dial
//! that gave up on it).

mod address;
mod env;
mod http;
mod pattern;
mod scopes;
mod socks;
pub use scopes::{Authority, Scopes, Summary};

use std::collections::VecDeque;
use std::net::{IpAddr, SocketAddr};
use std::sync::atomic::{AtomicU8, Ordering};
use std::sync::{Arc, RwLock};
use std::time::Duration;

use subtle::ConstantTimeEq;
use tokio::io::{
    AsyncBufReadExt, AsyncRead, AsyncWrite, AsyncWriteExt, BufReader, ReadHalf, WriteHalf,
};
use tokio::net::{TcpListener, TcpStream, UnixListener};
use tokio::sync::{OwnedSemaphorePermit, Semaphore};
use tokio::task::{AbortHandle, JoinSet};

pub use env::{EnvPlatform, NO_PROXY, PROXY_USER, basic_authorization, env_vars};

/// Authenticated connections one session may hold open through the proxy.
/// Each costs the node two fds (client and upstream): srt's proxy lived in
/// the session's own process, this one shares the node's fd table.
const MAX_CONNECTIONS: usize = 64;
/// Connections one session's proxy holds before they authenticate (one
/// fd each), apart from [`MAX_CONNECTIONS`]. When a new one arrives with
/// the set full, the oldest is closed. As large as [`MAX_CONNECTIONS`]:
/// a parallel burst (one connection per request) is accepted faster than
/// its heads arrive, and a smaller set would evict its own first clients.
const MAX_UNAUTHENTICATED: usize = MAX_CONNECTIONS;
/// How long a client has, from its connection, to present the token: its
/// first byte, then its HTTP request head or its SOCKS5 greeting and
/// credentials (clients send them at once).
const AUTH_TIMEOUT: Duration = Duration::from_secs(10);
/// Connections all sessions' proxies may hold open together: 1024 fds,
/// small next to the soft `RLIMIT_NOFILE` the node raises to its hard limit
/// at start-up (systemd's default hard limit is 524288), so sandboxed
/// agents cannot starve the link, the database, terminals or other
/// sessions' spawns of fds.
pub const MAX_NODE_CONNECTIONS: usize = 512;
/// Pause after a failed `accept` (`EMFILE` and the like), so the loop does
/// not spin while the condition lasts.
const ACCEPT_BACKOFF: Duration = Duration::from_millis(100);
/// How long an authenticated SOCKS client may take to send its request,
/// and the proxy to reach the destination (srt's `CONNECT_TIMEOUT_MS`).
const TIMEOUT: Duration = Duration::from_secs(30);
/// Host-name lookups one session's proxy runs at once. Each holds a thread
/// of tokio's blocking pool (shared with `tokio::fs`) until `getaddrinfo`
/// returns, which can outlast the dial's deadline.
const MAX_LOOKUPS: usize = 8;
/// srt's mux: how long a client may wait before its first byte.
const FIRST_BYTE_TIMEOUT: Duration = Duration::from_secs(10);

/// The domains a session may reach: its policy's, and the ones approved
/// since, which replace each other as srt's settings lines did.
///
/// Allowed and approved entries srt's schema refuses
/// ([`pattern::is_valid_allowed_entry`]: `*.localhost`, single-label
/// names but `localhost`, unbracketed IPv6) are ignored. pirc's
/// `valid_domain` (TS's `DOMAIN_PATTERN`) admits `*.localhost`, but srt
/// refused a settings line holding it, so such an entry or approval never
/// took effect; here it would open every loopback service of the host.
/// (srt refused the whole line; ignoring only the entry keeps the rest.)
/// Denied entries are kept as they are: a broader deny only refuses more.
pub struct Allowlist {
    allowed: Vec<String>,
    denied: Vec<String>,
    approved: RwLock<Vec<String>>,
}

impl Allowlist {
    pub fn new(allowed: Vec<String>, denied: Vec<String>) -> Self {
        Self {
            allowed: valid_entries(&allowed),
            denied,
            approved: RwLock::new(Vec::new()),
        }
    }

    /// Every domain approved so far.
    pub fn set_approved(&self, approved: &[String]) {
        *self.approved.write().unwrap_or_else(|p| p.into_inner()) = valid_entries(approved);
    }

    fn approved(&self) -> Vec<String> {
        self.approved
            .read()
            .unwrap_or_else(|p| p.into_inner())
            .clone()
    }

    /// Whether `host` may be reached on `port` ([`Self::check`]).
    pub fn allows(&self, host: &str, port: u16) -> bool {
        self.check(host, port).is_some()
    }

    /// srt's `filterNetworkRequest`: the canonical spelling of `host`
    /// (the one to connect to) when it may be reached on `port`.
    pub fn check(&self, host: &str, port: u16) -> Option<String> {
        if !pattern::is_valid_host(host) {
            return None;
        }
        let canonical = pattern::canonicalize_host(host).unwrap_or_else(|| host.to_owned());
        if self.is_denied(&canonical, port) {
            return None;
        }
        let allowed = self
            .allowed
            .iter()
            .chain(&self.approved())
            .any(|entry| pattern::matches(&canonical, port, entry));
        allowed.then_some(canonical)
    }

    /// Whether a denied entry matches (`canonical` is canonical already).
    fn is_denied(&self, canonical: &str, port: u16) -> bool {
        self.denied
            .iter()
            .any(|entry| pattern::matches(canonical, port, entry))
    }

    /// The resolved-address guard for one dial: the lists as they are now,
    /// this host's addresses as they are now.
    fn guard(&self) -> address::Guard {
        let mut allowed = self.allowed.clone();
        allowed.extend(self.approved());
        address::Guard::new(&allowed, &self.denied, address::local_addresses())
    }
}

/// The entries srt's schema would take.
fn valid_entries(entries: &[String]) -> Vec<String> {
    entries
        .iter()
        .filter(|entry| pattern::is_valid_allowed_entry(entry))
        .cloned()
        .collect()
}

/// The credential a session's clients present (srt's `proxyAuthToken`:
/// 16 random bytes in hex, generated when the proxy starts, exported only
/// into the sandbox's environment).
pub struct ProxyAuth {
    token: String,
}

impl ProxyAuth {
    pub fn generate() -> Self {
        let bytes = crate::util::random_bytes::<16>();
        Self {
            token: bytes.iter().map(|b| format!("{b:02x}")).collect(),
        }
    }

    pub fn token(&self) -> &str {
        &self.token
    }

    fn is_token(&self, password: &[u8]) -> bool {
        bool::from(self.token.as_bytes().ct_eq(password))
    }

    /// `checkAuth`: a `Basic` credential whose password is the token (any
    /// non-empty user, as srt; the user is only an attribution label).
    fn accepts_basic(&self, header: Option<&str>) -> bool {
        use base64::Engine as _;
        let Some(header) = header else {
            return false;
        };
        let Some((scheme, encoded)) = header
            .trim_start()
            .split_once(|c: char| c.is_ascii_whitespace())
        else {
            return false;
        };
        let encoded = encoded.trim();
        let well_formed = scheme.eq_ignore_ascii_case("basic")
            && !encoded.is_empty()
            && encoded
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'+' | b'/' | b'='));
        if !well_formed {
            return false;
        }
        // Node's base64 decoding is lenient about padding.
        let lenient = base64::engine::GeneralPurpose::new(
            &base64::alphabet::STANDARD,
            base64::engine::GeneralPurposeConfig::new()
                .with_decode_padding_mode(base64::engine::DecodePaddingMode::Indifferent)
                .with_decode_allow_trailing_bits(true),
        );
        let Ok(decoded) = lenient.decode(encoded.trim_end_matches('=')) else {
            return false;
        };
        match decoded.iter().position(|b| *b == b':') {
            Some(sep) if sep > 0 => self.is_token(&decoded[sep + 1..]),
            _ => false,
        }
    }

    /// The SOCKS5 user/password check: user `srt` or `srt.<label>`.
    fn accepts_socks(&self, user: &[u8], password: &[u8]) -> bool {
        let user_ok =
            user == PROXY_USER.as_bytes() || user.starts_with(format!("{PROXY_USER}.").as_bytes());
        user_ok & self.is_token(password)
    }
}

/// Where a session's proxy listens.
pub enum ProxyListener {
    /// Linux: a Unix socket in the session's temp directory, bound into
    /// the sandbox and bridged to `127.0.0.1:{3128,1080}`.
    Unix(UnixListener),
    /// macOS: a loopback TCP port, the only outbound address the Seatbelt
    /// profile allows.
    Tcp(TcpListener),
}

/// A client connection, whichever listener it came from.
trait Client: AsyncRead + AsyncWrite + Unpin + Send {}
impl<T: AsyncRead + AsyncWrite + Unpin + Send> Client for T {}

type Reader = BufReader<ReadHalf<Box<dyn Client>>>;
type Writer = WriteHalf<Box<dyn Client>>;

impl ProxyListener {
    /// A TCP listener on `127.0.0.1` and a free port, as srt's mux listens
    /// (macOS), with that port.
    pub async fn loopback() -> std::io::Result<(Self, u16)> {
        let listener = TcpListener::bind(("127.0.0.1", 0)).await?;
        let port = listener.local_addr()?.port();
        Ok((Self::Tcp(listener), port))
    }

    async fn accept(&self) -> std::io::Result<Box<dyn Client>> {
        match self {
            Self::Unix(listener) => Ok(Box::new(listener.accept().await?.0)),
            Self::Tcp(listener) => {
                let (stream, _) = listener.accept().await?;
                let _ = stream.set_nodelay(true);
                Ok(Box::new(stream))
            }
        }
    }
}

/// What every connection of a session's proxy shares.
struct Session {
    allowlist: Arc<Allowlist>,
    auth: Arc<ProxyAuth>,
    /// [`MAX_CONNECTIONS`]: the authenticated connections.
    connections: Arc<Semaphore>,
    /// [`MAX_LOOKUPS`].
    lookups: Arc<Semaphore>,
    authority: Arc<Authority>,
}

/// [`Gate::state`]: still waiting for the token (evictable).
const WAITING: u8 = 0;
/// [`Gate::state`]: authenticated, under the session's cap.
const ADMITTED: u8 = 1;
/// [`Gate::state`]: evicted, or ended before it authenticated.
const GONE: u8 = 2;

/// A connection's place under its session's caps: one of the
/// [`MAX_UNAUTHENTICATED`] waiting ones until it presents the token by
/// `deadline`, then one of the session's [`MAX_CONNECTIONS`]
/// ([`Gate::admit`]).
struct Gate {
    /// [`WAITING`], [`ADMITTED`] or [`GONE`], shared with the accept loop's
    /// [`Waiting`] entry; whichever side moves it off [`WAITING`] first
    /// wins, so an admitted connection is never evicted.
    state: Arc<AtomicU8>,
    admitted: Option<OwnedSemaphorePermit>,
    connections: Arc<Semaphore>,
    deadline: tokio::time::Instant,
}

impl Gate {
    /// The client authenticated: it leaves the waiting set for the
    /// session's cap. `false` when that cap is full or the connection was
    /// evicted meanwhile (close it).
    fn admit(&mut self) -> bool {
        if self.admitted.is_none() {
            let Ok(permit) = self.connections.clone().try_acquire_owned() else {
                return false;
            };
            if !moved_from_waiting(&self.state, ADMITTED) {
                return false;
            }
            self.admitted = Some(permit);
        }
        true
    }
}

impl Drop for Gate {
    fn drop(&mut self) {
        moved_from_waiting(&self.state, GONE);
    }
}

/// Move `state` from [`WAITING`] to `to`; `false` when it had left already.
fn moved_from_waiting(state: &AtomicU8, to: u8) -> bool {
    state
        .compare_exchange(WAITING, to, Ordering::AcqRel, Ordering::Acquire)
        .is_ok()
}

/// The accept loop's view of a connection that has not authenticated.
struct Waiting {
    state: Arc<AtomicU8>,
    task: AbortHandle,
}

/// Make room for one more waiting connection: forget the ones that left
/// the set, and when it is still full close the oldest one still waiting.
fn evict_if_full(waiting: &mut VecDeque<Waiting>) {
    waiting.retain(|entry| entry.state.load(Ordering::Acquire) == WAITING);
    while waiting.len() >= MAX_UNAUTHENTICATED {
        let Some(oldest) = waiting.pop_front() else {
            break;
        };
        if moved_from_waiting(&oldest.state, GONE) {
            oldest.task.abort();
        }
    }
}

/// Serve the session's proxy until the task is aborted (the session's
/// cleanup), which also ends every connection. `node` bounds the
/// connections of every session's proxy together.
pub async fn serve(
    listener: ProxyListener,
    allowlist: Arc<Allowlist>,
    auth: Arc<ProxyAuth>,
    node: Arc<Semaphore>,
) {
    serve_until(
        listener,
        allowlist,
        auth,
        node,
        Arc::new(Authority::default()),
    )
    .await;
}
async fn serve_until(
    listener: ProxyListener,
    allowlist: Arc<Allowlist>,
    auth: Arc<ProxyAuth>,
    node: Arc<Semaphore>,
    authority: Arc<Authority>,
) {
    let session = Arc::new(Session {
        allowlist,
        auth,
        connections: Arc::new(Semaphore::new(MAX_CONNECTIONS)),
        lookups: Arc::new(Semaphore::new(MAX_LOOKUPS)),
        authority: authority.clone(),
    });
    let mut waiting = VecDeque::with_capacity(MAX_UNAUTHENTICATED);
    let mut connections = JoinSet::new();
    loop {
        tokio::select! {
            biased;
            ()=authority.cancelled()=>break,
            accepted = scopes::admitted(authority.clone(),listener.accept()) => {
                let Ok(client) = accepted else {
                    tokio::time::sleep(ACCEPT_BACKOFF).await;
                    continue;
                };
                let Ok(permit) = node.clone().try_acquire_owned() else {
                    drop(client);
                    continue;
                };
                evict_if_full(&mut waiting);
                let state = Arc::new(AtomicU8::new(WAITING));
                let gate = Gate {
                    state: state.clone(),
                    admitted: None,
                    connections: session.connections.clone(),
                    deadline: tokio::time::Instant::now() + AUTH_TIMEOUT,
                };
                let session = session.clone();
                let task = connections.spawn(async move {
                    let client:Box<dyn Client>=Box::new(scopes::Guarded::new(client,session.authority.clone()));
                    let _ = handle(client, &session, gate).await;
                    drop(permit);
                });
                waiting.push_back(Waiting { state, task });
            }
            Some(_) = connections.join_next(), if !connections.is_empty() => {}
        }
    }
    drop(listener);
    connections.abort_all();
    while connections.join_next().await.is_some() {}
    // getaddrinfo cannot be forcibly canceled. Keep retirement unconfirmed
    // until every already-admitted blocking lookup has returned its permit.
    settle_lookups(&session.lookups).await;
}
async fn settle_lookups(lookups: &Arc<Semaphore>) {
    if lookups
        .clone()
        .acquire_many_owned(MAX_LOOKUPS as u32)
        .await
        .is_err()
    {
        std::future::pending::<()>().await;
    }
}

/// srt's mux: peek the first byte, then SOCKS or HTTP. `gate` is held
/// until the connection ends.
async fn handle(client: Box<dyn Client>, session: &Session, mut gate: Gate) -> std::io::Result<()> {
    let (reader, writer) = tokio::io::split(client);
    let mut reader = BufReader::new(reader);
    let first_byte_by = gate
        .deadline
        .min(tokio::time::Instant::now() + FIRST_BYTE_TIMEOUT);
    let first = match tokio::time::timeout_at(first_byte_by, reader.fill_buf()).await {
        Ok(Ok(buffer)) => buffer.first().copied(),
        Ok(Err(_)) | Err(_) => None,
    };
    match first {
        None => Ok(()),
        Some(0x04 | 0x05) => socks::handle(reader, writer, session, &mut gate).await,
        Some(_) => http::handle(reader, writer, session, &mut gate).await,
    }
}

/// Why a destination could not be reached.
enum DialError {
    /// The resolved-address guard refused every address (srt's
    /// `ResolvedAddressDeniedError`: a policy denial, not a failure).
    Denied(String),
    Failed,
}

/// `dialDirect` with the guard's lookup: an IP literal is connected to as
/// it is; a name is resolved once, its addresses vetted, and the survivors
/// tried in the resolver's order (Node's family fallback).
async fn dial(
    host: &str,
    port: u16,
    session: &Session,
) -> Result<scopes::Guarded<TcpStream>, DialError> {
    let attempt = async {
        let addresses: Vec<IpAddr> = match pattern::parse_ip(host) {
            Some(address) => vec![address],
            None => {
                let resolved = lookup(host, port, &session.lookups, &session.authority).await?;
                session
                    .allowlist
                    .guard()
                    .vet(host, port, &resolved)
                    .map_err(|denied| DialError::Denied(denied.message))?
            }
        };
        for address in addresses {
            if let Ok(stream) = scopes::admitted(
                session.authority.clone(),
                TcpStream::connect(SocketAddr::new(address, port)),
            )
            .await
            {
                let _ = stream.set_nodelay(true);
                return Ok(scopes::Guarded::new(stream, session.authority.clone()));
            }
        }
        Err(DialError::Failed)
    };
    tokio::time::timeout(TIMEOUT, attempt)
        .await
        .unwrap_or(Err(DialError::Failed))
}

/// `tokio::net::lookup_host`, holding one of the session's
/// [`MAX_LOOKUPS`] until the blocking lookup itself returns (not only
/// until the dial gives up on it).
async fn lookup(
    host: &str,
    port: u16,
    lookups: &Arc<Semaphore>,
    authority: &Arc<Authority>,
) -> Result<Vec<IpAddr>, DialError> {
    use std::net::ToSocketAddrs;
    let host = host.to_owned();
    lookup_with(lookups, authority, move || {
        (host.as_str(), port)
            .to_socket_addrs()
            .map(|addresses| addresses.map(|address| address.ip()).collect())
    })
    .await
}
async fn lookup_with(
    lookups: &Arc<Semaphore>,
    authority: &Arc<Authority>,
    resolve: impl FnOnce() -> std::io::Result<Vec<IpAddr>> + Send + 'static,
) -> Result<Vec<IpAddr>, DialError> {
    let permit = lookups
        .clone()
        .acquire_owned()
        .await
        .map_err(|_| DialError::Failed)?;
    authority
        .admit(|| {
            tokio::task::spawn_blocking(move || {
                let _permit = permit;
                resolve()
            })
        })
        .map_err(|_| DialError::Failed)?
        .await
        .map_err(|_| DialError::Failed)?
        .map_err(|_| DialError::Failed)
}

/// An established tunnel: each direction relayed on its own, so a client
/// that half-closes still gets the reply; once the destination is done
/// (or the client fails), the connection ends, as srt's `close` handlers
/// do.
async fn relay(mut reader: Reader, mut writer: Writer, upstream: scopes::Guarded<TcpStream>) {
    let (mut upstream_read, mut upstream_write) = tokio::io::split(upstream);
    let upload = async {
        if tokio::io::copy(&mut reader, &mut upstream_write)
            .await
            .is_ok()
        {
            let _ = upstream_write.shutdown().await;
            std::future::pending::<()>().await;
        }
    };
    let download = async {
        let _ = tokio::io::copy(&mut upstream_read, &mut writer).await;
        let _ = writer.shutdown().await;
    };
    tokio::select! {
        () = upload => {}
        () = download => {}
    }
}

#[cfg(test)]
mod tests;
