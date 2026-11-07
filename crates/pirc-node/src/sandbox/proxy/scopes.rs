//! Session-owned native proxy resources. Revocation synchronously closes the I/O
//! admission gate, then waits for sockets and already-admitted lookups to settle.
use super::{Allowlist, ProxyAuth, ProxyListener};
use crate::error::{ApiError, ApiResult};
use serde::Serialize;
use std::{
    collections::{HashMap, HashSet},
    future::Future,
    io,
    pin::Pin,
    sync::{Arc, Mutex, RwLock, Weak},
    task::{Context, Poll},
    time::Duration,
};
use tokio::{
    io::{AsyncRead, AsyncWrite, ReadBuf},
    sync::{Semaphore, watch},
};

pub struct Authority {
    admission: Arc<RwLock<()>>,
    revoked: Mutex<bool>,
    stop: watch::Sender<bool>,
    finished: watch::Sender<bool>,
}
impl Default for Authority {
    fn default() -> Self {
        Self {
            admission: Arc::new(RwLock::new(())),
            revoked: Mutex::new(false),
            stop: watch::channel(false).0,
            finished: watch::channel(false).0,
        }
    }
}
impl Authority {
    pub(crate) fn is_open(&self) -> bool {
        !*self.revoked.lock().unwrap_or_else(|p| p.into_inner())
    }
    pub(crate) fn admit<T>(&self, action: impl FnOnce() -> T) -> io::Result<T> {
        let _admission = self.admission.read().unwrap_or_else(|p| p.into_inner());
        let revoked = self.revoked.lock().unwrap_or_else(|p| p.into_inner());
        if *revoked {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "Native proxy authority was revoked",
            ));
        }
        Ok(action())
    }
    fn revoke(&self) {
        let mut revoked = self.revoked.lock().unwrap_or_else(|p| p.into_inner());
        *revoked = true;
        self.stop.send_replace(true);
    }
    pub(super) async fn cancelled(&self) {
        let mut stop = self.stop.subscribe();
        loop {
            if *stop.borrow_and_update() {
                return;
            }
            if stop.changed().await.is_err() {
                return;
            }
        }
    }
    async fn closed(&self) {
        let mut finished = self.finished.subscribe();
        loop {
            if *finished.borrow_and_update() {
                return;
            }
            if finished.changed().await.is_err() {
                std::future::pending::<()>().await;
            }
        }
    }
}
/// Gate each nonblocking syscall poll, not just request creation or DNS return.
/// A revoke and the first I/O submission have one short shared critical section.
pub(super) struct Guarded<T> {
    inner: T,
    authority: Arc<Authority>,
}
impl<T> Guarded<T> {
    pub(super) fn new(inner: T, authority: Arc<Authority>) -> Self {
        Self { inner, authority }
    }
}
impl<T: AsyncRead + Unpin> AsyncRead for Guarded<T> {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        let this = self.get_mut();
        this.authority
            .admit(|| Pin::new(&mut this.inner).poll_read(cx, buf))
            .unwrap_or_else(|e| Poll::Ready(Err(e)))
    }
}
impl<T: AsyncWrite + Unpin> AsyncWrite for Guarded<T> {
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        let this = self.get_mut();
        this.authority
            .admit(|| Pin::new(&mut this.inner).poll_write(cx, buf))
            .unwrap_or_else(|e| Poll::Ready(Err(e)))
    }
    fn poll_write_vectored(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[io::IoSlice<'_>],
    ) -> Poll<io::Result<usize>> {
        let this = self.get_mut();
        this.authority
            .admit(|| Pin::new(&mut this.inner).poll_write_vectored(cx, buf))
            .unwrap_or_else(|e| Poll::Ready(Err(e)))
    }
    fn is_write_vectored(&self) -> bool {
        self.inner.is_write_vectored()
    }
    fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        let this = self.get_mut();
        this.authority
            .admit(|| Pin::new(&mut this.inner).poll_flush(cx))
            .unwrap_or_else(|e| Poll::Ready(Err(e)))
    }
    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        let this = self.get_mut();
        this.authority
            .admit(|| Pin::new(&mut this.inner).poll_shutdown(cx))
            .unwrap_or_else(|e| Poll::Ready(Err(e)))
    }
}
pub(super) async fn admitted<F, T>(authority: Arc<Authority>, future: F) -> io::Result<T>
where
    F: Future<Output = io::Result<T>>,
{
    struct Checked<F> {
        future: Pin<Box<F>>,
        authority: Arc<Authority>,
    }
    impl<F, T> Future for Checked<F>
    where
        F: Future<Output = io::Result<T>>,
    {
        type Output = io::Result<T>;
        fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
            let this = self.get_mut();
            this.authority
                .admit(|| this.future.as_mut().poll(cx))
                .unwrap_or_else(|e| Poll::Ready(Err(e)))
        }
    }
    Checked {
        future: Box::pin(future),
        authority,
    }
    .await
}
#[derive(Clone, Debug, Default, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Summary {
    pub supported: bool,
    pub revoked: bool,
    pub active: u64,
    pub pending: u64,
    pub closed: u64,
}
#[derive(Default)]
struct Inner {
    closing: bool,
    revoked: HashSet<String>,
    entries: HashMap<String, Vec<Weak<Authority>>>,
}
#[derive(Default)]
pub struct Scopes {
    inner: Mutex<Inner>,
    admissions: Mutex<HashMap<String, Weak<RwLock<()>>>>,
}
pub(crate) struct Lease {
    authority: Arc<Authority>,
}
impl Lease {
    pub(crate) fn authority(&self) -> Arc<Authority> {
        self.authority.clone()
    }
}
impl Drop for Lease {
    fn drop(&mut self) {
        self.authority.revoke();
    }
}
impl Scopes {
    fn admission(&self, session: &str) -> Arc<RwLock<()>> {
        let mut entries = self.admissions.lock().unwrap_or_else(|p| p.into_inner());
        if let Some(existing) = entries.get(session).and_then(Weak::upgrade) {
            return existing;
        }
        let gate = Arc::new(RwLock::new(()));
        entries.insert(session.into(), Arc::downgrade(&gate));
        gate
    }
    /// Lock only the source's synchronous I/O polls across the durable commit.
    /// Failure releases the gate without retiring a still-valid environment.
    pub(crate) fn fence<T>(
        &self,
        session: &str,
        accept: impl FnOnce() -> ApiResult<T>,
    ) -> ApiResult<T> {
        let admission = self.admission(session);
        let _exclusive = admission.write().unwrap_or_else(|p| p.into_inner());
        let result = accept()?;
        self.revoke(session);
        Ok(result)
    }
    pub(crate) fn start(
        &self,
        session: &str,
        listener: ProxyListener,
        allowlist: Arc<Allowlist>,
        auth: Arc<ProxyAuth>,
        node: Arc<Semaphore>,
    ) -> ApiResult<Lease> {
        let admission = self.admission(session);
        let _register = admission.read().unwrap_or_else(|p| p.into_inner());
        let mut inner = self.inner.lock().unwrap_or_else(|p| p.into_inner());
        if inner.closing || inner.revoked.contains(session) {
            return Err(ApiError::new(
                409,
                "environment_transition_pending",
                "Native proxy scope is retired",
            ));
        }
        let authority = Arc::new(Authority {
            admission: admission.clone(),
            ..Authority::default()
        });
        let entries = inner.entries.entry(session.into()).or_default();
        entries.retain(|e| e.strong_count() != 0);
        entries.push(Arc::downgrade(&authority));
        let task_authority = authority.clone();
        tokio::spawn(async move {
            super::serve_until(listener, allowlist, auth, node, task_authority.clone()).await;
            // No Drop-based acknowledgement: panic/abort is not closure evidence.
            task_authority.finished.send_replace(true);
        });
        Ok(Lease { authority })
    }
    pub fn revoke(&self, session: &str) {
        let mut inner = self.inner.lock().unwrap_or_else(|p| p.into_inner());
        inner.revoked.insert(session.into());
        if let Some(entries) = inner.entries.get(session) {
            for authority in entries.iter().filter_map(Weak::upgrade) {
                authority.revoke();
            }
        }
    }
    /// After a committed installation or release, a new generation may start
    /// proxies. Every earlier authority stays revoked and keeps its own outcome.
    pub(crate) fn reopen(&self, session: &str) {
        let mut inner = self.inner.lock().unwrap_or_else(|p| p.into_inner());
        inner.revoked.remove(session);
    }
    pub fn close_all(&self) {
        let mut inner = self.inner.lock().unwrap_or_else(|p| p.into_inner());
        inner.closing = true;
        for authority in inner.entries.values().flatten().filter_map(Weak::upgrade) {
            authority.revoke();
        }
    }
    pub fn summary(&self, session: &str) -> Summary {
        let inner = self.inner.lock().unwrap_or_else(|p| p.into_inner());
        let mut result = Summary {
            supported: true,
            revoked: inner.closing || inner.revoked.contains(session),
            ..Default::default()
        };
        for authority in inner
            .entries
            .get(session)
            .into_iter()
            .flatten()
            .filter_map(Weak::upgrade)
        {
            if *authority.finished.borrow() {
                result.closed += 1;
            } else if authority.is_open() {
                result.active += 1;
            } else {
                result.pending += 1;
            }
        }
        result
    }
    pub async fn wait(&self, session: Option<&str>, timeout: Duration) -> ApiResult<()> {
        let entries = {
            let inner = self.inner.lock().unwrap_or_else(|p| p.into_inner());
            if let Some(session) = session {
                if !inner.closing && !inner.revoked.contains(session) {
                    return Err(ApiError::conflict(
                        "Proxy retirement requires a source fence",
                    ));
                }
            } else if !inner.closing {
                return Err(ApiError::conflict("Proxy retirement requires shutdown"));
            }
            inner
                .entries
                .iter()
                .filter(|(key, _)| session.is_none_or(|s| s == key.as_str()))
                .flat_map(|(_, v)| v)
                .filter_map(Weak::upgrade)
                .collect::<Vec<_>>()
        };
        tokio::time::timeout(
            timeout,
            futures_util::future::join_all(entries.iter().map(|e| e.closed())),
        )
        .await
        .map_err(|_| {
            ApiError::new(
                409,
                "network_stop_unconfirmed",
                "Native proxy sockets or admitted lookups have not settled",
            )
        })?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sandbox::proxy::{ProxyListener, basic_authorization};
    use tokio::{
        io::{AsyncReadExt, AsyncWriteExt},
        net::{TcpListener, TcpStream},
    };
    pub(super) async fn tunnel(
        scopes: &Scopes,
        session: &str,
        socks: bool,
    ) -> (Lease, TcpStream, TcpStream) {
        let upstream = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let target = upstream.local_addr().unwrap();
        let auth = Arc::new(ProxyAuth::generate());
        let token = auth.token().to_owned();
        let (listener, port) = ProxyListener::loopback().await.unwrap();
        let lease = scopes
            .start(
                session,
                listener,
                Arc::new(Allowlist::new(
                    vec![format!("127.0.0.1:{}", target.port())],
                    vec![],
                )),
                auth,
                Arc::new(Semaphore::new(10)),
            )
            .unwrap();
        let mut client = TcpStream::connect(("127.0.0.1", port)).await.unwrap();
        if socks {
            client.write_all(&[5, 1, 2]).await.unwrap();
            let mut reply = [0; 2];
            client.read_exact(&mut reply).await.unwrap();
            assert_eq!(reply, [5, 2]);
            let mut credentials = vec![1, 3, b's', b'r', b't', token.len() as u8];
            credentials.extend(token.bytes());
            client.write_all(&credentials).await.unwrap();
            client.read_exact(&mut reply).await.unwrap();
            assert_eq!(reply, [1, 0]);
            let mut request = vec![5, 1, 0, 1, 127, 0, 0, 1];
            request.extend(target.port().to_be_bytes());
            client.write_all(&request).await.unwrap();
            let mut reply = [0; 10];
            client.read_exact(&mut reply).await.unwrap();
            assert_eq!(reply[1], 0);
        } else {
            let request = format!(
                "CONNECT 127.0.0.1:{} HTTP/1.1\r\nProxy-Authorization: {}\r\n\r\n",
                target.port(),
                basic_authorization(&format!("srt:{token}"))
            );
            client.write_all(request.as_bytes()).await.unwrap();
            let mut reply = Vec::new();
            while !reply.ends_with(b"\r\n\r\n") {
                reply.push(client.read_u8().await.unwrap());
            }
            assert!(reply.starts_with(b"HTTP/1.1 200"));
        }
        let (server, _) = upstream.accept().await.unwrap();
        (lease, client, server)
    }
    pub(super) async fn closed(stream: &mut TcpStream) {
        let mut bytes = [0; 1];
        let result = tokio::time::timeout(Duration::from_secs(2), stream.read(&mut bytes))
            .await
            .unwrap();
        assert!(
            matches!(result, Ok(0)) || result.is_err(),
            "Unexpected bytes after revocation: {result:?}"
        );
    }
    #[tokio::test]
    async fn revocation_closes_existing_http_and_socks_tunnels_but_preserves_peers() {
        let scopes = Scopes::default();
        let (_http, mut http, mut http_server) = tunnel(&scopes, "source", false).await;
        let (_socks, mut socks, mut socks_server) = tunnel(&scopes, "source", true).await;
        let (_peer, mut peer, mut peer_server) = tunnel(&scopes, "peer", false).await;
        http.write_all(b"before").await.unwrap();
        let mut before = [0; 6];
        http_server.read_exact(&mut before).await.unwrap();
        assert_eq!(&before, b"before");
        scopes.revoke("source");
        assert_eq!(scopes.summary("source").active, 0);
        scopes
            .wait(Some("source"), Duration::from_secs(2))
            .await
            .unwrap();
        for stream in [&mut http, &mut http_server, &mut socks, &mut socks_server] {
            closed(stream).await;
        }
        peer.write_all(b"peer").await.unwrap();
        let mut bytes = [0; 4];
        peer_server.read_exact(&mut bytes).await.unwrap();
        assert_eq!(&bytes, b"peer");
        peer_server.write_all(b"back").await.unwrap();
        peer.read_exact(&mut bytes).await.unwrap();
        assert_eq!(&bytes, b"back");
        assert!(!scopes.summary("peer").revoked);
        scopes.close_all();
        scopes.wait(None, Duration::from_secs(2)).await.unwrap();
    }
    #[tokio::test]
    async fn retired_scope_cannot_register_or_dial_and_drop_retires_its_own_proxy() {
        let scopes = Scopes::default();
        scopes.revoke("retired");
        let (listener, _) = ProxyListener::loopback().await.unwrap();
        assert!(
            scopes
                .start(
                    "retired",
                    listener,
                    Arc::new(Allowlist::new(vec![], vec![])),
                    Arc::new(ProxyAuth::generate()),
                    Arc::new(Semaphore::new(10))
                )
                .is_err()
        );
        let authority = Arc::new(Authority::default());
        authority.revoke();
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        assert!(
            admitted(
                authority,
                TcpStream::connect(listener.local_addr().unwrap())
            )
            .await
            .is_err()
        );
        assert!(
            tokio::time::timeout(Duration::from_millis(30), listener.accept())
                .await
                .is_err()
        );
        let (lease, mut client, mut server) = tunnel(&scopes, "open", false).await;
        drop(lease);
        scopes.revoke("open");
        scopes
            .wait(Some("open"), Duration::from_secs(2))
            .await
            .unwrap();
        closed(&mut client).await;
        closed(&mut server).await;
    }
    #[tokio::test]
    async fn committed_fence_excludes_waiting_io_and_failed_fence_preserves_authority() {
        let scopes = Arc::new(Scopes::default());
        let (lease, _client, _server) = tunnel(&scopes, "source", false).await;
        let authority = lease.authority();
        let failed: ApiResult<()> = scopes.fence("source", || Err(ApiError::internal()));
        assert!(failed.is_err());
        assert!(authority.admit(|| ()).is_ok());
        let (entered, locked) = std::sync::mpsc::channel();
        let (release, commit) = std::sync::mpsc::channel();
        let source = scopes.clone();
        let accept = std::thread::spawn(move || {
            source.fence("source", || {
                entered.send(()).unwrap();
                commit.recv().unwrap();
                Ok(())
            })
        });
        locked.recv().unwrap();
        let (attempted, attempt) = std::sync::mpsc::channel();
        let (completed, result) = std::sync::mpsc::channel();
        let io = std::thread::spawn(move || {
            attempted.send(()).unwrap();
            completed
                .send(authority.admit(|| "should not submit").is_ok())
                .unwrap();
        });
        attempt.recv().unwrap();
        assert!(result.recv_timeout(Duration::from_millis(10)).is_err());
        release.send(()).unwrap();
        accept.join().unwrap().unwrap();
        assert!(!result.recv().unwrap());
        io.join().unwrap();
        scopes
            .wait(Some("source"), Duration::from_secs(2))
            .await
            .unwrap();
    }
    #[tokio::test]
    async fn io_after_revocation_cannot_read_buffered_bytes_or_submit_new_bytes() {
        let authority = Arc::new(Authority::default());
        let (stream, mut peer) = tokio::io::duplex(64);
        let mut stream = Guarded::new(stream, authority.clone());
        peer.write_all(b"buffered").await.unwrap();
        authority.revoke();
        assert_eq!(
            stream.write_all(b"late").await.unwrap_err().kind(),
            io::ErrorKind::PermissionDenied
        );
        assert_eq!(
            stream.read_u8().await.unwrap_err().kind(),
            io::ErrorKind::PermissionDenied
        );
        assert!(
            tokio::time::timeout(Duration::from_millis(30), peer.read_u8())
                .await
                .is_err()
        );
    }
    #[tokio::test]
    async fn absent_completion_and_inflight_lookup_permits_remain_unconfirmed() {
        let scopes = Scopes::default();
        let authority = Arc::new(Authority::default());
        scopes
            .inner
            .lock()
            .unwrap()
            .entries
            .insert("source".into(), vec![Arc::downgrade(&authority)]);
        scopes.revoke("source");
        assert_eq!(
            scopes
                .wait(Some("source"), Duration::from_millis(10))
                .await
                .unwrap_err()
                .code,
            "network_stop_unconfirmed"
        );
        assert_eq!(scopes.summary("source").pending, 1);
        // Abort the async lookup while its admitted blocking resolver remains
        // alive. Use a synthetic resolver, never a third-party DNS request.
        let lookups = Arc::new(Semaphore::new(super::super::MAX_LOOKUPS));
        let (entered, ready) = tokio::sync::oneshot::channel();
        let (release, worker) = std::sync::mpsc::channel();
        let permit_owner = lookups.clone();
        let open = Arc::new(Authority::default());
        let running = open.clone();
        let lookup = tokio::spawn(async move {
            super::super::lookup_with(&permit_owner, &running, move || {
                let _ = entered.send(());
                worker.recv().unwrap();
                Ok(vec![])
            })
            .await
            .is_ok()
        });
        ready.await.unwrap();
        lookup.abort();
        let _ = lookup.await;
        open.revoke();
        assert_eq!(lookups.available_permits(), super::super::MAX_LOOKUPS - 1);
        assert!(
            tokio::time::timeout(
                Duration::from_millis(10),
                super::super::settle_lookups(&lookups)
            )
            .await
            .is_err()
        );
        release.send(()).unwrap();
        tokio::time::timeout(
            Duration::from_secs(1),
            super::super::settle_lookups(&lookups),
        )
        .await
        .unwrap();
        authority.finished.send_replace(true);
        scopes
            .wait(Some("source"), Duration::from_secs(1))
            .await
            .unwrap();
    }
}

#[cfg(test)]
mod integration {
    use super::*;
    use crate::sandbox::{
        BoxFuture, PrepareInput, Prepared, ReadonlyInput, Sandbox, SandboxStatus,
    };
    use crate::store::Store;
    use pirc_protocol::{HttpMethod, NodeHttpRequest};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    struct NativeLike {
        delegate: Arc<dyn Sandbox>,
        scopes: Scopes,
    }
    impl Sandbox for NativeLike {
        fn network_scopes(&self) -> Option<&Scopes> {
            Some(&self.scopes)
        }
        fn check(&self) -> BoxFuture<'_, SandboxStatus> {
            self.delegate.check()
        }
        fn prepare(&self, input: PrepareInput) -> BoxFuture<'_, ApiResult<Prepared>> {
            self.delegate.prepare(input)
        }
        fn prepare_readonly(&self, input: ReadonlyInput) -> BoxFuture<'_, ApiResult<Prepared>> {
            self.delegate.prepare_readonly(input)
        }
    }
    #[tokio::test]
    async fn accepted_node_fence_retires_live_proxy_and_restart_restores_the_registration_fence() {
        let f = crate::workspace_memory::tests::Fixture::new().await;
        f.node.close().await;
        let sandbox = Arc::new(NativeLike {
            delegate: f.node.sandbox.clone(),
            scopes: Scopes::default(),
        });
        let node = crate::services::Services::start_with_sandbox(
            f.node.config.clone(),
            f.node.env.clone(),
            sandbox.clone(),
        )
        .await
        .unwrap();
        let (_source, mut source, mut server) =
            super::tests::tunnel(&sandbox.scopes, &f.current, false).await;
        let (_peer, mut peer, mut peer_server) =
            super::tests::tunnel(&sandbox.scopes, "peer", false).await;
        let row = node.db.lock().get_session(&f.current).unwrap();
        let lease = node
            .db
            .lock()
            .acquire_lease(&f.current, "phone", false, 60000)
            .unwrap();
        node.db.lock().execute_batch("CREATE TRIGGER refuse_network_fence BEFORE INSERT ON execution_fences BEGIN SELECT RAISE(ABORT,'synthetic disk failure'); END;").unwrap();
        let failed=node.router.handle(&node,NodeHttpRequest{method:HttpMethod::Post,url:format!("/api/sessions/{}/execution-fences",f.current),user:"alice".into(),payload:Some(serde_json::json!({"intent":{"operationId":"network-fence","planHash":"a".repeat(64),"expectedWorkspaceId":row.workspace_id,"expectedRunnerEpoch":row.runner_epoch},"clientId":"phone","generation":lease.generation})),body_base64:None,content_type:None}).await;
        assert_eq!(failed.status, 500);
        assert!(!sandbox.scopes.summary(&f.current).revoked);
        source.write_all(b"open").await.unwrap();
        let mut still_open = [0; 4];
        server.read_exact(&mut still_open).await.unwrap();
        assert_eq!(&still_open, b"open");
        node.db
            .lock()
            .execute_batch("DROP TRIGGER refuse_network_fence;")
            .unwrap();
        let response=node.router.handle(&node,NodeHttpRequest{method:HttpMethod::Post,url:format!("/api/sessions/{}/execution-fences",f.current),user:"alice".into(),payload:Some(serde_json::json!({"intent":{"operationId":"network-fence","planHash":"a".repeat(64),"expectedWorkspaceId":row.workspace_id,"expectedRunnerEpoch":row.runner_epoch},"clientId":"phone","generation":lease.generation})),body_base64:None,content_type:None}).await;
        assert_eq!(response.status, 200, "{:?}", response.body);
        assert_eq!(
            response.body.unwrap()["transition"]["nativeProxy"]["revoked"],
            true
        );
        sandbox
            .scopes
            .wait(Some(&f.current), Duration::from_secs(2))
            .await
            .unwrap();
        super::tests::closed(&mut source).await;
        super::tests::closed(&mut server).await;
        peer.write_all(b"peer").await.unwrap();
        let mut bytes = [0; 4];
        peer_server.read_exact(&mut bytes).await.unwrap();
        assert_eq!(&bytes, b"peer");
        // Missing completion proof may not become supervisor_drained merely
        // because the runner or proxy listener is already gone.
        let unresolved = Arc::new(Authority::default());
        sandbox
            .scopes
            .inner
            .lock()
            .unwrap()
            .entries
            .entry(f.current.clone())
            .or_default()
            .push(Arc::downgrade(&unresolved));
        sandbox.scopes.revoke(&f.current);
        let blocked = crate::execution_fences::drain(&node, "alice", &f.current, "network-fence")
            .await
            .unwrap();
        assert_eq!(blocked.state, "blocked");
        assert_eq!(
            blocked.error_code.as_deref(),
            Some("network_stop_unconfirmed")
        );
        assert!(!blocked.revocation_confirmed && !blocked.target_installed);
        peer.write_all(b"live").await.unwrap();
        peer_server.read_exact(&mut bytes).await.unwrap();
        assert_eq!(&bytes, b"live");
        unresolved.finished.send_replace(true);
        let stopped = crate::execution_fences::drain(&node, "alice", &f.current, "network-fence")
            .await
            .unwrap();
        assert_eq!(stopped.state, "supervisor_drained");
        node.close().await;
        let fresh = Arc::new(NativeLike {
            delegate: f.node.sandbox.clone(),
            scopes: Scopes::default(),
        });
        let restarted = crate::services::Services::start_with_sandbox(
            f.node.config.clone(),
            f.node.env.clone(),
            fresh.clone(),
        )
        .await
        .unwrap();
        assert!(fresh.scopes.summary(&f.current).revoked);
        assert!(!fresh.scopes.summary("peer").revoked);
        let (listener, _) = ProxyListener::loopback().await.unwrap();
        assert!(
            fresh
                .scopes
                .start(
                    &f.current,
                    listener,
                    Arc::new(Allowlist::new(vec![], vec![])),
                    Arc::new(ProxyAuth::generate()),
                    Arc::new(Semaphore::new(10))
                )
                .is_err()
        );
        restarted.close().await;
    }
}
