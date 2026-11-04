//! The proxy over real sockets: HTTP, SOCKS5, the mux, the token, the caps.

use std::path::{Path, PathBuf};

use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, UnixListener, UnixStream};
use tokio::sync::Semaphore;

use super::*;

const TOKEN: &str = "0123456789abcdef0123456789abcdef";

fn auth() -> Arc<ProxyAuth> {
    Arc::new(ProxyAuth {
        token: TOKEN.to_owned(),
    })
}

fn authorization() -> String {
    format!(
        "Proxy-Authorization: {}\r\n",
        basic_authorization(&format!("srt:{TOKEN}"))
    )
}

#[test]
fn matches_as_srt_does() {
    let list = Allowlist::new(
        vec![
            "github.com".into(),
            "*.example.com".into(),
            "api.test.io:8443".into(),
            "127.0.0.1:8080".into(),
            "[::1]:9000".into(),
        ],
        vec!["bad.example.com".into(), "*:25".into()],
    );
    assert!(list.allows("github.com", 443));
    assert!(list.allows("GitHub.com.", 443));
    assert!(!list.allows("api.github.com", 443));
    assert!(list.allows("a.b.example.com", 80));
    assert!(!list.allows("a.b.example.com", 25), "a denied port");
    assert!(!list.allows("example.com", 80), "strict subdomains only");
    assert!(!list.allows("bad.example.com", 443), "denied wins");
    assert!(
        !list.allows("BAD.example.com.", 443),
        "denied after canonicalizing"
    );
    assert!(list.allows("api.test.io", 8443));
    assert!(!list.allows("api.test.io", 443));
    assert!(list.allows("127.0.0.1", 8080));
    assert!(list.allows("127.1", 8080));
    assert!(list.allows("0x7f.0.0.1", 8080));
    assert!(list.allows("::ffff:127.0.0.1", 8080));
    assert!(!list.allows("127.0.0.1", 80));
    assert_eq!(list.check("[0:0::1]", 9000).as_deref(), Some("::1"));
    assert!(!list.allows("::1", 9001));
    assert!(!list.allows("evil.com", 443));
    assert!(!list.allows("evil.com\0.example.com", 443), "malformed");
    list.set_approved(&["evil.com".into()]);
    assert!(list.allows("evil.com", 443));
    list.set_approved(&[]);
    assert!(!list.allows("evil.com", 443));
}

#[test]
fn entries_srts_schema_refuses_are_ignored() {
    let list = Allowlist::new(
        vec!["*.localhost".into(), "intranet".into(), "::1".into()],
        Vec::new(),
    );
    assert!(!list.allows("app.localhost", 80));
    assert!(!list.allows("intranet", 80));
    assert!(!list.allows("::1", 80));
    list.set_approved(&["*.localhost".into(), "localhost:3000".into()]);
    assert!(!list.allows("app.localhost", 3000));
    assert!(list.allows("localhost", 3000));
    // Denied entries stay as written.
    let list = Allowlist::new(vec!["localhost".into()], vec!["*.localhost".into()]);
    assert!(list.allows("localhost", 80));
}

/// The soft `RLIMIT_NOFILE` raised as the node raises it at start-up
/// (`node::raise_fd_limit`): the cap tests hold hundreds of sockets in
/// this one process, past macOS's default soft limit of 256.
fn raise_fd_limit() {
    static RAISED: std::sync::Once = std::sync::Once::new();
    RAISED.call_once(|| {
        use nix::sys::resource::{Resource, getrlimit, setrlimit};
        let (soft, hard) = getrlimit(Resource::RLIMIT_NOFILE).unwrap();
        let target = hard.min(10240);
        if soft < target {
            setrlimit(Resource::RLIMIT_NOFILE, target, hard).unwrap();
        }
    });
}

/// A host server: answers each request with its head (`|` for CRLF) and
/// body; `/echo` echoes raw bytes instead.
async fn upstream() -> u16 {
    raise_fd_limit();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    tokio::spawn(async move {
        while let Ok((stream, _)) = listener.accept().await {
            tokio::spawn(async move {
                let mut reader = BufReader::new(stream);
                let mut line = String::new();
                if reader.read_line(&mut line).await.unwrap_or(0) == 0 {
                    return;
                }
                if line.starts_with("ECHO") {
                    let mut stream = reader;
                    let mut buffer = [0u8; 1024];
                    loop {
                        match stream.read(&mut buffer).await {
                            Ok(0) | Err(_) => return,
                            Ok(n) => {
                                let _ = stream.get_mut().write_all(&buffer[..n]).await;
                            }
                        }
                    }
                }
                let mut head = line.clone();
                let mut length = 0usize;
                loop {
                    let mut next = String::new();
                    reader.read_line(&mut next).await.unwrap();
                    if let Some(value) = next.to_ascii_lowercase().strip_prefix("content-length:") {
                        length = value.trim().parse().unwrap();
                    }
                    head.push_str(&next);
                    if next == "\r\n" || next.is_empty() {
                        break;
                    }
                }
                let mut body = vec![0u8; length];
                reader.read_exact(&mut body).await.unwrap();
                let reply_body = format!(
                    "{}{}",
                    head.replace("\r\n", "|"),
                    String::from_utf8_lossy(&body)
                );
                let reply = format!(
                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nKeep-Alive: timeout=5\r\nConnection: keep-alive\r\n\r\n{reply_body}",
                    reply_body.len()
                );
                reader
                    .into_inner()
                    .write_all(reply.as_bytes())
                    .await
                    .unwrap();
            });
        }
    });
    port
}

struct Proxy {
    _dir: tempfile::TempDir,
    socket: PathBuf,
    list: Arc<Allowlist>,
    task: tokio::task::JoinHandle<()>,
}

impl Drop for Proxy {
    fn drop(&mut self) {
        self.task.abort();
    }
}

fn proxy(allowed: &[&str], denied: &[&str]) -> Proxy {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("proxy.sock");
    let list = Arc::new(Allowlist::new(
        allowed.iter().map(|s| (*s).to_owned()).collect(),
        denied.iter().map(|s| (*s).to_owned()).collect(),
    ));
    let task = tokio::spawn(serve(
        ProxyListener::Unix(UnixListener::bind(&socket).unwrap()),
        list.clone(),
        auth(),
        Arc::new(Semaphore::new(MAX_NODE_CONNECTIONS)),
    ));
    Proxy {
        _dir: dir,
        socket,
        list,
        task,
    }
}

async fn ask(socket: &Path, request: &[u8]) -> String {
    let mut stream = UnixStream::connect(socket).await.unwrap();
    // A connection over a cap is closed unread: write and read errors
    // leave an empty answer.
    let _ = stream.write_all(request).await;
    let _ = stream.shutdown().await;
    let mut out = Vec::new();
    let _ = stream.read_to_end(&mut out).await;
    String::from_utf8_lossy(&out).into_owned()
}

#[tokio::test]
async fn forwards_allowed_requests_and_refuses_the_rest() {
    let port = upstream().await;
    let p = proxy(&["localhost"], &[]);
    let auth = authorization();

    let reply = ask(
        &p.socket,
        format!(
            "GET http://LocalHost.:{port}/a?b=1#frag HTTP/1.1\r\nHost: evil.com\r\n{auth}Connection: keep-alive, X-Hop\r\nX-Hop: 1\r\nAccept: */*\r\n\r\n"
        )
        .as_bytes(),
    )
    .await;
    // The response's own hop-by-hop headers are replaced too.
    assert!(
        reply.starts_with("HTTP/1.1 200 OK\r\nContent-Length: "),
        "{reply}"
    );
    assert!(reply.contains("\r\nConnection: close\r\n\r\n"), "{reply}");
    assert!(!reply.contains("Keep-Alive"), "{reply}");
    assert!(
        reply.ends_with(&format!(
            "GET /a?b=1 HTTP/1.1|Host: localhost:{port}|Accept: */*|Connection: close||"
        )),
        "{reply}"
    );

    let denied = ask(
        &p.socket,
        format!("GET http://127.0.0.1:{port}/ HTTP/1.1\r\n{auth}\r\n").as_bytes(),
    )
    .await;
    assert!(denied.starts_with("HTTP/1.1 403 Forbidden"), "{denied}");
    assert!(
        denied.contains("X-Proxy-Error: blocked-by-allowlist"),
        "{denied}"
    );
    assert!(denied.ends_with("Connection blocked by network allowlist\n"));

    // CONNECT, once the address is approved.
    let connect = format!("CONNECT 127.0.0.1:{port} HTTP/1.1\r\n{auth}\r\n");
    let answer = ask(&p.socket, connect.as_bytes()).await;
    assert_eq!(
        answer,
        "HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain\r\nX-Proxy-Error: blocked-by-allowlist\r\n\r\nConnection blocked by network allowlist"
    );
    p.list.set_approved(&["127.0.0.1".into()]);
    let answer = ask(
        &p.socket,
        format!("{connect}GET /t HTTP/1.1\r\n\r\n").as_bytes(),
    )
    .await;
    assert!(
        answer.starts_with("HTTP/1.1 200 Connection Established\r\n\r\nHTTP/1.1 200 OK"),
        "{answer}"
    );
    assert!(answer.ends_with("GET /t HTTP/1.1||"), "{answer}");

    let bad = ask(
        &p.socket,
        format!("GET /relative HTTP/1.1\r\n{auth}\r\n").as_bytes(),
    )
    .await;
    assert!(bad.starts_with("HTTP/1.1 400"), "{bad}");
    let bad = ask(
        &p.socket,
        format!("GET https://localhost/ HTTP/1.1\r\n{auth}\r\n").as_bytes(),
    )
    .await;
    assert!(bad.starts_with("HTTP/1.1 400"), "{bad}");
    let bad = ask(
        &p.socket,
        format!("CONNECT localhost HTTP/1.1\r\n{auth}\r\n").as_bytes(),
    )
    .await;
    assert!(bad.starts_with("HTTP/1.1 400"), "{bad}");
    let closed = ask(
        &p.socket,
        format!("GET http://localhost:1/ HTTP/1.1\r\n{auth}\r\n").as_bytes(),
    )
    .await;
    assert!(closed.starts_with("HTTP/1.1 502"), "{closed}");
    let closed = ask(
        &p.socket,
        format!("CONNECT localhost:1 HTTP/1.1\r\n{auth}\r\n").as_bytes(),
    )
    .await;
    assert_eq!(closed, "HTTP/1.1 502 Bad Gateway\r\n\r\n");
    let large = ask(&p.socket, &vec![b'G'; 70 * 1024]).await;
    assert!(large.starts_with("HTTP/1.1 431"), "{large}");
}

#[tokio::test]
async fn every_client_presents_the_token() {
    let port = upstream().await;
    let p = proxy(&["127.0.0.1"], &[]);
    for request in [
        format!("GET http://127.0.0.1:{port}/ HTTP/1.1\r\n\r\n"),
        format!(
            "GET http://127.0.0.1:{port}/ HTTP/1.1\r\nProxy-Authorization: {}\r\n\r\n",
            basic_authorization("srt:wrong")
        ),
    ] {
        let reply = ask(&p.socket, request.as_bytes()).await;
        assert!(
            reply.starts_with("HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"srt\"\r\n"),
            "{reply}"
        );
    }
    let reply = ask(
        &p.socket,
        format!("CONNECT 127.0.0.1:{port} HTTP/1.1\r\n\r\n").as_bytes(),
    )
    .await;
    assert_eq!(
        reply,
        "HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"srt\"\r\n\r\n"
    );
    // Any user with the token (the user is a label).
    let reply = ask(
        &p.socket,
        format!(
            "GET http://127.0.0.1:{port}/ HTTP/1.1\r\nProxy-Authorization: {}\r\n\r\n",
            basic_authorization(&format!("someone:{TOKEN}"))
        )
        .as_bytes(),
    )
    .await;
    assert!(reply.starts_with("HTTP/1.1 200 OK"), "{reply}");
}

#[tokio::test]
async fn request_bodies_are_forwarded_once_and_nothing_after_them() {
    let port = upstream().await;
    let p = proxy(&["127.0.0.1"], &[]);
    let auth = authorization();
    let reply = ask(
        &p.socket,
        format!(
            "POST http://127.0.0.1:{port}/p HTTP/1.1\r\n{auth}Content-Length: 5\r\n\r\nhelloGET http://evil.com/ HTTP/1.1\r\n\r\n"
        )
        .as_bytes(),
    )
    .await;
    assert!(
        reply.ends_with("Content-Length: 5|Connection: close||hello"),
        "{reply}"
    );
    let reply = ask(
        &p.socket,
        format!(
            "POST http://127.0.0.1:{port}/p HTTP/1.1\r\n{auth}Content-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"
        )
        .as_bytes(),
    )
    .await;
    assert!(reply.starts_with("HTTP/1.1 400"), "smuggling: {reply}");
    let reply = ask(
        &p.socket,
        format!("GET http://127.0.0.1:{port}/ HTTP/1.1\r\n{auth}X: a\nHost: evil.com\r\n\r\n")
            .as_bytes(),
    )
    .await;
    assert!(reply.starts_with("HTTP/1.1 400"), "bare LF: {reply}");
}

/// A SOCKS5 client: greeting with `methods`, then (with 0x02) `user` and
/// `password`, then CONNECT to `address` (ATYP and bytes) and `port`.
/// What the proxy answered, all of it.
async fn socks(
    socket: &Path,
    methods: &[u8],
    credentials: Option<(&[u8], &[u8])>,
    address: &[u8],
    port: u16,
    then: &[u8],
) -> Vec<u8> {
    let mut stream = UnixStream::connect(socket).await.unwrap();
    let mut request = vec![5, u8::try_from(methods.len()).unwrap()];
    request.extend_from_slice(methods);
    if let Some((user, password)) = credentials {
        request.push(1);
        request.push(u8::try_from(user.len()).unwrap());
        request.extend_from_slice(user);
        request.push(u8::try_from(password.len()).unwrap());
        request.extend_from_slice(password);
    }
    request.extend_from_slice(&[5, 1, 0]);
    request.extend_from_slice(address);
    request.extend_from_slice(&port.to_be_bytes());
    request.extend_from_slice(then);
    let _ = stream.write_all(&request).await;
    let _ = stream.shutdown().await;
    let mut out = Vec::new();
    let _ = stream.read_to_end(&mut out).await;
    out
}

fn domain(name: &str) -> Vec<u8> {
    let mut out = vec![3, u8::try_from(name.len()).unwrap()];
    out.extend_from_slice(name.as_bytes());
    out
}

const GRANTED: [u8; 10] = [5, 0, 0, 1, 0, 0, 0, 0, 0, 0];
const NOT_ALLOWED: [u8; 10] = [5, 2, 0, 1, 0, 0, 0, 0, 0, 0];

#[tokio::test]
async fn socks5_connects_through_the_same_allowlist() {
    let port = upstream().await;
    let p = proxy(&["localhost", "[::1]"], &["bad.localhost"]);
    let creds = Some((&b"srt"[..], TOKEN.as_bytes()));
    let echo = b"ECHO\nping";
    let granted = |via: &[u8]| {
        let mut expected = vec![5, 2, 1, 0];
        expected.extend_from_slice(&GRANTED);
        expected.extend_from_slice(via);
        expected
    };

    // A domain (resolved on the host), offered alongside no-auth.
    let out = socks(&p.socket, &[0, 2], creds, &domain("localhost"), port, echo).await;
    assert_eq!(out, granted(b"ping"), "{}", String::from_utf8_lossy(&out));
    // IPv4 not on the list, then approved.
    let v4 = [1, 127, 0, 0, 1];
    let out = socks(&p.socket, &[2], creds, &v4, port, echo).await;
    assert_eq!(out[..4], [5, 2, 1, 0]);
    assert_eq!(out[4..], NOT_ALLOWED);
    p.list.set_approved(&["127.0.0.1".into()]);
    let out = socks(&p.socket, &[2], creds, &v4, port, echo).await;
    assert_eq!(out, granted(b"ping"));
    // IPv6: allowed, but nothing listens on [::1]:port.
    let mut v6 = vec![4];
    v6.extend_from_slice(&std::net::Ipv6Addr::LOCALHOST.octets());
    let out = socks(&p.socket, &[2], creds, &v6, port, b"").await;
    assert_eq!(out[4..], [5, 4, 0, 1, 0, 0, 0, 0, 0, 0], "host unreachable");
    // Denied and malformed names.
    for name in ["bad.localhost", "evil.com", "a\0.localhost", "a b"] {
        let out = socks(&p.socket, &[2], creds, &domain(name), port, b"").await;
        assert_eq!(out[4..], NOT_ALLOWED, "{name:?}");
    }
    // Wrong credentials.
    for (user, password) in [(&b"srt"[..], &b"nope"[..]), (b"root", TOKEN.as_bytes())] {
        let out = socks(
            &p.socket,
            &[2],
            Some((user, password)),
            &domain("localhost"),
            port,
            b"",
        )
        .await;
        assert_eq!(out, [5, 2, 1, 1]);
    }
    // BIND is not supported; an unknown address type closes.
    let mut stream = UnixStream::connect(&p.socket).await.unwrap();
    let mut request = vec![5, 1, 2, 1, 3, b's', b'r', b't', 32];
    request.extend_from_slice(TOKEN.as_bytes());
    request.extend_from_slice(&[5, 2, 0, 1, 127, 0, 0, 1, 0, 80]);
    stream.write_all(&request).await.unwrap();
    let mut out = Vec::new();
    stream.read_to_end(&mut out).await.unwrap();
    assert_eq!(out, [5, 2, 1, 0, 5, 7]);
    let out = socks(&p.socket, &[2], creds, &[9, 1, 2], port, b"").await;
    assert_eq!(out, [5, 2, 1, 0]);
    // SOCKS4 and a bad version close unanswered.
    assert_eq!(ask(&p.socket, &[4, 1, 0, 80, 127, 0, 0, 1, 0]).await, "");
}

#[tokio::test]
async fn socks5_without_authentication_is_refused_without_dialing() {
    let p = proxy(&["*.example.com"], &["*:22", "blocked.example.com"]);
    let ok = |rest: &[u8]| {
        let mut expected = vec![5, 0];
        expected.extend_from_slice(rest);
        expected
    };
    // Not port 22: "not allowed".
    let out = socks(&p.socket, &[0], None, &domain("a.example.com"), 443, b"").await;
    assert_eq!(out, ok(&NOT_ALLOWED));
    let out = socks(&p.socket, &[], None, &domain("a.example.com"), 443, b"").await;
    assert_eq!(out, ok(&NOT_ALLOWED), "no methods at all");
    // Port 22: success, then SSH speaking the reason.
    let out = socks(
        &p.socket,
        &[0],
        None,
        &domain("blocked.example.com"),
        22,
        b"",
    )
    .await;
    assert_eq!(out[..12], ok(&GRANTED));
    let ssh = &out[12..];
    assert!(ssh.starts_with(b"SSH-2.0-policy_refusal\r\n"));
    let packet = &ssh[24..];
    assert_eq!(packet[5], 1, "SSH_MSG_DISCONNECT");
    assert!(String::from_utf8_lossy(packet).contains("host is on the deny list"));

    let open = proxy(&["*.example.com"], &[]);
    let out = socks(&open.socket, &[0], None, &domain("a.example.com"), 22, b"").await;
    assert!(
        String::from_utf8_lossy(&out).contains("This proxy requires authentication"),
        "{out:?}"
    );
    // Malformed hosts get "not allowed" even on 22.
    let out = socks(&open.socket, &[0], None, &domain("a\0b"), 22, b"").await;
    assert_eq!(out, ok(&NOT_ALLOWED));
}

#[tokio::test]
async fn the_mux_dispatches_on_the_first_byte_only() {
    let p = proxy(&[], &[]);
    // EOF before any byte: closed.
    assert_eq!(ask(&p.socket, b"").await, "");
    // A TLS ClientHello's first byte is HTTP's business: 400.
    let tls = ask(&p.socket, b"\x16\x03\x01\x00\x05hello\r\n\r\n").await;
    assert!(tls.starts_with("HTTP/1.1 400"), "{tls}");
    // A SOCKS5 greeting gets a SOCKS answer.
    let mut stream = UnixStream::connect(&p.socket).await.unwrap();
    stream.write_all(&[5, 1, 2]).await.unwrap();
    let mut answer = [0u8; 2];
    stream.read_exact(&mut answer).await.unwrap();
    assert_eq!(answer, [5, 2]);
}

#[tokio::test]
async fn resolved_addresses_are_vetted_before_dialing() {
    let port = upstream().await;
    // `localhost` may be loopback; an IP literal on the list is never re-judged.
    let p = proxy(&["localhost", "127.0.0.1"], &["::1", "127.0.0.1:1"]);
    let auth = authorization();
    // `::1` is deny-listed, so `localhost` reaches 127.0.0.1 only.
    let reply = ask(
        &p.socket,
        format!("GET http://localhost:{port}/ HTTP/1.1\r\n{auth}\r\n").as_bytes(),
    )
    .await;
    assert!(reply.starts_with("HTTP/1.1 200 OK"), "{reply}");
    let reply = ask(
        &p.socket,
        format!("CONNECT localhost:1 HTTP/1.1\r\n{auth}\r\n").as_bytes(),
    )
    .await;
    assert_eq!(
        reply,
        "HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain\r\nX-Proxy-Error: blocked-by-sandbox-runtime\r\n\r\nConnection to localhost blocked: resolved to a deny-listed address"
    );
    let reply = ask(
        &p.socket,
        format!("GET http://localhost:1/ HTTP/1.1\r\n{auth}\r\n").as_bytes(),
    )
    .await;
    assert!(reply.starts_with("HTTP/1.1 403"), "{reply}");
    assert!(
        reply.ends_with(
            "\r\n\r\nConnection to localhost blocked: resolved to a deny-listed address\n"
        ),
        "{reply}"
    );
}

#[tokio::test]
async fn tcp_listeners_on_loopback() {
    let port = upstream().await;
    let (listener, proxy_port) = ProxyListener::loopback().await.unwrap();
    let list = Arc::new(Allowlist::new(vec!["127.0.0.1".into()], Vec::new()));
    let task = tokio::spawn(serve(listener, list, auth(), Arc::new(Semaphore::new(4))));
    let mut stream = tokio::net::TcpStream::connect(("127.0.0.1", proxy_port))
        .await
        .unwrap();
    stream
        .write_all(
            format!(
                "GET http://127.0.0.1:{port}/ HTTP/1.1\r\n{}\r\n",
                authorization()
            )
            .as_bytes(),
        )
        .await
        .unwrap();
    let mut out = String::new();
    stream.read_to_string(&mut out).await.unwrap();
    assert!(out.starts_with("HTTP/1.1 200 OK"), "{out}");
    task.abort();
}

#[tokio::test]
async fn every_sessions_proxy_shares_the_nodes_connection_cap() {
    let port = upstream().await;
    let dir = tempfile::tempdir().unwrap();
    let node = Arc::new(Semaphore::new(1));
    let list = Arc::new(Allowlist::new(vec!["127.0.0.1".into()], Vec::new()));
    let (a, b) = (dir.path().join("a.sock"), dir.path().join("b.sock"));
    let tasks = [&a, &b].map(|socket| {
        tokio::spawn(serve(
            ProxyListener::Unix(UnixListener::bind(socket).unwrap()),
            list.clone(),
            auth(),
            node.clone(),
        ))
    });
    let auth = authorization();
    // Session a holds the node's only connection open...
    let mut held = UnixStream::connect(&a).await.unwrap();
    held.write_all(format!("CONNECT 127.0.0.1:{port} HTTP/1.1\r\n{auth}\r\n").as_bytes())
        .await
        .unwrap();
    let mut established = [0u8; 39];
    held.read_exact(&mut established).await.unwrap();
    assert_eq!(&established, b"HTTP/1.1 200 Connection Established\r\n\r\n");
    // ...so session b's is closed unanswered.
    let refused = ask(
        &b,
        format!("GET http://127.0.0.1:1/ HTTP/1.1\r\n{auth}\r\n").as_bytes(),
    )
    .await;
    assert_eq!(refused, "");
    drop(held);
    // The permit comes back once the tunnel ends.
    let mut reply = String::new();
    for _ in 0..50 {
        reply = ask(
            &b,
            format!("GET http://127.0.0.1:{port}/ HTTP/1.1\r\n{auth}\r\n").as_bytes(),
        )
        .await;
        if !reply.is_empty() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert!(reply.starts_with("HTTP/1.1 200 OK"), "{reply}");
    for task in tasks {
        task.abort();
    }
}

/// One authenticated `CONNECT` tunnel to the upstream on `port`.
async fn tunnel(socket: &Path, port: u16) -> UnixStream {
    let mut tunnel = UnixStream::connect(socket).await.unwrap();
    tunnel
        .write_all(
            format!(
                "CONNECT 127.0.0.1:{port} HTTP/1.1\r\n{}\r\n",
                authorization()
            )
            .as_bytes(),
        )
        .await
        .unwrap();
    let mut established = [0u8; 39];
    tunnel.read_exact(&mut established).await.unwrap();
    assert_eq!(&established, b"HTTP/1.1 200 Connection Established\r\n\r\n");
    tunnel
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_burst_of_the_sessions_own_clients_gets_in() {
    let port = upstream().await;
    let p = proxy(&["127.0.0.1"], &[]);
    // As a parallel download does: every client connects at once and
    // sends its head right away; the accept loop outruns the heads.
    let burst: Vec<_> = (0..MAX_CONNECTIONS)
        .map(|_| {
            let socket = p.socket.clone();
            tokio::spawn(async move { tunnel(&socket, port).await })
        })
        .collect();
    let mut tunnels = Vec::new();
    for client in burst {
        tunnels.push(client.await.unwrap());
    }
    // Each tunnel works, and the session's cap holds: one more is closed.
    for tunnel in &mut tunnels {
        tunnel.write_all(b"ECHO\r\nping").await.unwrap();
        let mut echoed = [0u8; 4];
        tunnel.read_exact(&mut echoed).await.unwrap();
        assert_eq!(&echoed, b"ping");
    }
    let get = format!(
        "GET http://127.0.0.1:{port}/ HTTP/1.1\r\n{}\r\n",
        authorization()
    );
    assert_eq!(ask(&p.socket, get.as_bytes()).await, "");
}

#[tokio::test]
async fn clients_without_the_token_cannot_shut_the_session_out() {
    let port = upstream().await;
    let p = proxy(&["127.0.0.1"], &[]);
    // Tunnels left the waiting set once they presented the token.
    let mut tunnels = Vec::new();
    for _ in 0..4 {
        tunnels.push(tunnel(&p.socket, port).await);
    }
    // A client without the token fills the waiting set, and more...
    let mut idle = Vec::new();
    for _ in 0..MAX_UNAUTHENTICATED + 4 {
        idle.push(UnixStream::connect(&p.socket).await.unwrap());
    }
    // ...yet the session's clients still get in at once: each new
    // connection evicts the oldest one still waiting.
    let get = format!(
        "GET http://127.0.0.1:{port}/ HTTP/1.1\r\n{}\r\n",
        authorization()
    );
    let reply = ask(&p.socket, get.as_bytes()).await;
    assert!(reply.starts_with("HTTP/1.1 200 OK"), "{reply}");
    // The oldest idle connections were closed, the newest are still open.
    let mut closed = [0u8; 1];
    for stream in &mut idle[..5] {
        let read = tokio::time::timeout(Duration::from_secs(5), stream.read(&mut closed)).await;
        assert!(matches!(read, Ok(Ok(0) | Err(_))), "{read:?}");
    }
    let newest = idle.last_mut().unwrap();
    let still_open =
        tokio::time::timeout(Duration::from_millis(100), newest.read(&mut closed)).await;
    assert!(still_open.is_err(), "{still_open:?}");
    // The session's tunnels are untouched.
    for tunnel in &mut tunnels {
        tunnel.write_all(b"ECHO\r\nping").await.unwrap();
        let mut echoed = [0u8; 4];
        tunnel.read_exact(&mut echoed).await.unwrap();
        assert_eq!(&echoed, b"ping");
    }
}

#[tokio::test]
async fn lookups_hold_a_session_permit_until_they_return() {
    let lookups = Arc::new(Semaphore::new(1));
    let authority = Arc::new(Authority::default());
    let held = lookups.clone().acquire_owned().await.unwrap();
    // No permit: the lookup waits (and the dial's deadline would end it).
    let waiting = tokio::time::timeout(
        Duration::from_millis(100),
        lookup("localhost", 80, &lookups, &authority),
    )
    .await;
    assert!(waiting.is_err());
    drop(held);
    let (a, b) = tokio::join!(
        lookup("localhost", 80, &lookups, &authority),
        lookup("localhost", 80, &lookups, &authority)
    );
    assert!(a.is_ok() && b.is_ok());
    assert_eq!(lookups.available_permits(), 1);
}
