//! The proxy's HTTP side. Ported from sandbox-runtime 0.0.78
//! `http-proxy.js` and `parent-proxy.js` `stripHopByHop` (Apache-2.0, see
//! `crates/pirc-node/NOTICE`).
//!
//! `CONNECT host:port` (or `[v6]:port`) opens a tunnel after the token,
//! the allowlist and the resolved-address guard; a request in absolute
//! form (`GET http://host/path`) is forwarded in origin form to the
//! canonical host with the `Host` header rebuilt from it (so the upstream
//! sees exactly the host that was checked) and hop-by-hop headers, and
//! those the client's `Connection` names, removed.
//!
//! Deviations from srt (whose Node server re-framed every request and
//! kept connections alive):
//!
//! - One request per connection: the request's body is forwarded by its
//!   own framing (`Content-Length` or chunked, never both, as llhttp
//!   insists), nothing the client sends after it is, and the response
//!   gets `Connection: close` (clients reconnect, as HTTP allows). The
//!   upstream gets `Connection: close` too.
//! - Plain `http://` only: srt would also fetch an `https://` target over
//!   TLS for a client that asks the proxy to (rare; clients `CONNECT`).
//! - A request target that is not absolute is 400 (srt: 500), and a head
//!   with bare CR/LF, NUL, folded lines or malformed header names is 400.

use std::io;

use super::scopes::Guarded;
use tokio::io::ReadHalf;
use tokio::io::{
    AsyncBufRead, AsyncBufReadExt, AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, BufReader,
};
use tokio::net::TcpStream;

use super::pattern::{format_authority, strip_brackets};
use super::{DialError, Gate, Reader, Session, Writer, dial, relay};

/// Longest request or response head (srt answered 431 past Node's limit).
const MAX_HEAD: usize = 64 * 1024;
/// Longest chunk-size or trailer line of a chunked body.
const MAX_LINE: usize = 8 * 1024;

/// `rawDenied`'s tags.
const ALLOWLIST_TAG: &str = "blocked-by-allowlist";
const RUNTIME_TAG: &str = "blocked-by-sandbox-runtime";
/// `ALLOWLIST_DENY`'s reason.
const ALLOWLIST_REASON: &str = "Connection blocked by network allowlist";

/// RFC 7230 §6.1 hop-by-hop headers and the proxy's own (srt's
/// `HOP_BY_HOP` without `transfer-encoding`: bodies pass in their own
/// framing here). `host` is rebuilt.
const DROPPED: &[&str] = &[
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "proxy-connection",
    "te",
    "trailer",
    "upgrade",
    "host",
];

/// The framing headers, kept even when `Connection` names them.
const FRAMING: &[&str] = &["content-length", "transfer-encoding"];

/// A request or response head, read through its blank line.
enum Head {
    Complete(Vec<u8>),
    TooLarge,
    Eof,
}

/// Read a head without consuming what follows it.
async fn read_head(reader: &mut (impl AsyncBufRead + Unpin)) -> io::Result<Head> {
    let mut head = Vec::new();
    loop {
        let buffer = reader.fill_buf().await?;
        if buffer.is_empty() {
            return Ok(Head::Eof);
        }
        let mut used = 0;
        let mut done = false;
        for byte in buffer {
            head.push(*byte);
            used += 1;
            if head.ends_with(b"\r\n\r\n") {
                done = true;
                break;
            }
            if head.len() > MAX_HEAD {
                break;
            }
        }
        reader.consume(used);
        if done {
            head.truncate(head.len() - 2);
            return Ok(Head::Complete(head));
        }
        if head.len() > MAX_HEAD {
            return Ok(Head::TooLarge);
        }
    }
}

/// One header line: its lowercase name, its trimmed value, the raw line.
struct Header {
    name: String,
    value: String,
    line: Vec<u8>,
}

/// A parsed head: its first line's three parts and its headers.
struct Parsed {
    start: [String; 3],
    headers: Vec<Header>,
}

fn is_token(text: &str) -> bool {
    !text.is_empty()
        && text
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"!#$%&'*+-.^_`|~".contains(&b))
}

/// Split a head (without its final blank line) strictly: CRLF lines only,
/// no NUL, no folding, token header names.
fn parse_head(head: &[u8]) -> Option<Parsed> {
    let mut text = head.strip_suffix(b"\r\n")?;
    let mut split = Vec::new();
    while let Some(end) = text.windows(2).position(|w| w == b"\r\n") {
        split.push(&text[..end]);
        text = &text[end + 2..];
    }
    split.push(text);
    if split
        .iter()
        .any(|line| line.contains(&b'\r') || line.contains(&b'\n') || line.contains(&0))
    {
        return None;
    }
    let mut lines = split.into_iter();
    let first = std::str::from_utf8(lines.next()?).ok()?;
    let mut parts = first.splitn(3, ' ');
    let start = [
        parts.next()?.to_owned(),
        parts.next()?.to_owned(),
        // A status line may lack its reason phrase.
        parts.next().unwrap_or_default().to_owned(),
    ];
    let mut headers = Vec::new();
    for line in lines {
        if line.first().is_some_and(|b| *b == b' ' || *b == b'\t') {
            return None;
        }
        let colon = line.iter().position(|b| *b == b':')?;
        let name = std::str::from_utf8(&line[..colon]).ok()?;
        if !is_token(name) {
            return None;
        }
        let value = String::from_utf8_lossy(&line[colon + 1..])
            .trim_matches([' ', '\t'])
            .to_owned();
        headers.push(Header {
            name: name.to_ascii_lowercase(),
            value,
            line: line.to_vec(),
        });
    }
    Some(Parsed { start, headers })
}

impl Parsed {
    fn first(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|header| header.name == name)
            .map(|header| header.value.as_str())
    }

    fn all<'a>(&'a self, name: &'a str) -> impl Iterator<Item = &'a str> {
        self.headers
            .iter()
            .filter(move |header| header.name == name)
            .flat_map(|header| header.value.split(','))
            .map(str::trim)
    }

    /// The header lines to forward: without hop-by-hop headers and those
    /// `Connection` names (`stripHopByHop`), framing kept.
    fn forwarded_lines(&self) -> Vec<&[u8]> {
        let named: Vec<String> = self
            .all("connection")
            .map(str::to_ascii_lowercase)
            .collect();
        self.headers
            .iter()
            .filter(|header| {
                FRAMING.contains(&header.name.as_str())
                    || !(DROPPED.contains(&header.name.as_str()) || named.contains(&header.name))
            })
            .map(|header| header.line.as_slice())
            .collect()
    }
}

/// How a request's body ends.
#[derive(Debug, PartialEq, Eq)]
enum Body {
    None,
    Length(u64),
    Chunked,
}

/// The body's framing, or `None` for an ambiguous one (llhttp's refusals:
/// both headers, differing lengths, a final coding other than chunked).
fn body(request: &Parsed) -> Option<Body> {
    let codings: Vec<String> = request
        .all("transfer-encoding")
        .map(str::to_ascii_lowercase)
        .collect();
    let lengths: Vec<&str> = request.all("content-length").collect();
    if !codings.is_empty() {
        let chunked = codings.last().is_some_and(|last| last == "chunked");
        return (lengths.is_empty() && chunked).then_some(Body::Chunked);
    }
    let Some(first) = lengths.first() else {
        return Some(Body::None);
    };
    let valid = lengths.iter().all(|length| {
        length == first && !length.is_empty() && length.bytes().all(|b| b.is_ascii_digit())
    });
    let length: u64 = first.parse().ok().filter(|_| valid)?;
    Some(if length == 0 {
        Body::None
    } else {
        Body::Length(length)
    })
}

/// `parseConnectTarget`: `host:port` or `[v6]:port`, port 1–65535.
fn connect_target(target: &str) -> Option<(String, u16)> {
    let (host, port) = if let Some(rest) = target.strip_prefix('[') {
        let (host, port) = rest.split_once("]:")?;
        (!host.is_empty() && !host.contains(']')).then_some((host, port))?
    } else {
        let (host, port) = target.split_once(':')?;
        (!host.is_empty() && !port.contains(':')).then_some((host, port))?
    };
    if port.is_empty() || !port.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let digits = port.trim_start_matches('0');
    let port: u16 = if digits.len() > 5 {
        None
    } else {
        digits.parse().ok()
    }?;
    (port > 0).then(|| (host.to_owned(), port))
}

/// `rawDenied`.
fn raw_denied(reason: &str, tag: &str) -> String {
    format!(
        "HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain\r\nX-Proxy-Error: {tag}\r\n\r\n{reason}"
    )
}

/// `respondDenied`, with the framing a closing connection needs.
fn denied_response(reason: &str, tag: &str) -> String {
    let body = format!("{reason}\n");
    format!(
        "HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain\r\nX-Proxy-Error: {tag}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    )
}

const PROXY_AUTH_REQUIRED: &str =
    "HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"srt\"\r\n\r\n";
const PROXY_AUTH_REQUIRED_REQUEST: &str = "HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"srt\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
const BAD_REQUEST: &str = "HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n";
const BAD_GATEWAY: &str = "HTTP/1.1 502 Bad Gateway\r\nContent-Type: text/plain\r\nContent-Length: 11\r\nConnection: close\r\n\r\nBad Gateway";

pub(super) async fn handle(
    mut reader: Reader,
    mut writer: Writer,
    session: &Session,
    gate: &mut Gate,
) -> io::Result<()> {
    // The head carries the credential: it is read under the
    // unauthenticated deadline ([`Gate`]).
    let head = match tokio::time::timeout_at(gate.deadline, read_head(&mut reader)).await {
        Err(_) => return Ok(()),
        Ok(head) => head?,
    };
    let head = match head {
        Head::Complete(head) => head,
        Head::Eof => return Ok(()),
        Head::TooLarge => {
            return writer
                .write_all(b"HTTP/1.1 431 Request Header Fields Too Large\r\n\r\n")
                .await;
        }
    };
    let Some(request) = parse_head(&head).filter(|parsed| {
        is_token(&parsed.start[0]) && matches!(parsed.start[2].as_str(), "HTTP/1.1" | "HTTP/1.0")
    }) else {
        return writer.write_all(BAD_REQUEST.as_bytes()).await;
    };
    let auth = session
        .auth
        .accepts_basic(request.first("proxy-authorization"));
    // Over the session's cap: closed unanswered, as at `accept` before.
    if auth && !gate.admit() {
        return Ok(());
    }
    if request.start[0] == "CONNECT" {
        if !auth {
            return writer.write_all(PROXY_AUTH_REQUIRED.as_bytes()).await;
        }
        let Some((host, port)) = connect_target(&request.start[1]) else {
            return writer.write_all(b"HTTP/1.1 400 Bad Request\r\n\r\n").await;
        };
        let Some(host) = session.allowlist.check(&host, port) else {
            return writer
                .write_all(raw_denied(ALLOWLIST_REASON, ALLOWLIST_TAG).as_bytes())
                .await;
        };
        let upstream = match dial(&host, port, session).await {
            Ok(upstream) => upstream,
            Err(DialError::Denied(reason)) => {
                return writer
                    .write_all(raw_denied(&reason, RUNTIME_TAG).as_bytes())
                    .await;
            }
            Err(DialError::Failed) => {
                return writer.write_all(b"HTTP/1.1 502 Bad Gateway\r\n\r\n").await;
            }
        };
        writer
            .write_all(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            .await?;
        relay(reader, writer, upstream).await;
        return Ok(());
    }
    if !auth {
        return writer
            .write_all(PROXY_AUTH_REQUIRED_REQUEST.as_bytes())
            .await;
    }
    forward(reader, writer, session, &request).await
}

/// A plain request: checked, rewritten, forwarded with its body, and the
/// response relayed with `Connection: close`.
async fn forward(
    mut reader: Reader,
    mut writer: Writer,
    session: &Session,
    request: &Parsed,
) -> io::Result<()> {
    let [method, target, version] = &request.start;
    let http = target
        .get(..7)
        .is_some_and(|s| s.eq_ignore_ascii_case("http://"));
    let Some(url) = url::Url::parse(target).ok().filter(|_| http) else {
        return writer.write_all(BAD_REQUEST.as_bytes()).await;
    };
    let Some(requested) = url.host_str().map(|host| strip_brackets(host).to_owned()) else {
        return writer.write_all(BAD_REQUEST.as_bytes()).await;
    };
    let port = url.port_or_known_default().unwrap_or(80);
    let Some(host) = session.allowlist.check(&requested, port) else {
        return writer
            .write_all(denied_response(ALLOWLIST_REASON, ALLOWLIST_TAG).as_bytes())
            .await;
    };
    let Some(body) = body(request) else {
        return writer.write_all(BAD_REQUEST.as_bytes()).await;
    };
    let upstream = match dial(&host, port, session).await {
        Ok(upstream) => upstream,
        Err(DialError::Denied(reason)) => {
            return writer
                .write_all(denied_response(&reason, RUNTIME_TAG).as_bytes())
                .await;
        }
        Err(DialError::Failed) => return writer.write_all(BAD_GATEWAY.as_bytes()).await,
    };
    let path = match url.query() {
        Some(query) => format!("{}?{query}", url.path()),
        None => url.path().to_owned(),
    };
    let mut head = format!(
        "{method} {path} {version}\r\nHost: {}\r\n",
        format_authority(&host, port, 80)
    )
    .into_bytes();
    for line in request.forwarded_lines() {
        head.extend_from_slice(line);
        head.extend_from_slice(b"\r\n");
    }
    head.extend_from_slice(b"Connection: close\r\n\r\n");
    let (upstream_read, mut upstream_write) = tokio::io::split(upstream);
    upstream_write.write_all(&head).await?;
    let upload = async {
        let sent = forward_body(&mut reader, &mut upstream_write, &body).await;
        if sent.is_ok() {
            // The request is complete; nothing after it is forwarded.
            std::future::pending::<()>().await;
        }
    };
    let download = forward_response(upstream_read, &mut writer);
    tokio::select! {
        () = upload => {}
        _ = download => {}
    }
    Ok(())
}

/// Copy exactly one body in its framing.
async fn forward_body(
    reader: &mut (impl AsyncBufRead + Unpin),
    upstream: &mut (impl AsyncWrite + Unpin),
    body: &Body,
) -> io::Result<()> {
    match body {
        Body::None => Ok(()),
        Body::Length(length) => copy_exact(reader, upstream, *length).await,
        Body::Chunked => loop {
            let line = read_line(reader).await?;
            upstream.write_all(&line).await?;
            let size = line
                .strip_suffix(b"\r\n")
                .map(|line| line.split(|b| *b == b';').next().unwrap_or_default())
                .and_then(|size| std::str::from_utf8(size).ok())
                .map(|size| size.trim_matches([' ', '\t']))
                .filter(|size| !size.is_empty() && size.len() <= 16)
                .and_then(|size| u64::from_str_radix(size, 16).ok())
                .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "chunk size"))?;
            if size == 0 {
                // Trailers, through the blank line.
                loop {
                    let line = read_line(reader).await?;
                    upstream.write_all(&line).await?;
                    if line == b"\r\n" {
                        return Ok(());
                    }
                }
            }
            copy_exact(reader, upstream, size).await?;
            let mut end = [0u8; 2];
            reader.read_exact(&mut end).await?;
            if &end != b"\r\n" {
                return Err(io::Error::new(io::ErrorKind::InvalidData, "chunk end"));
            }
            upstream.write_all(&end).await?;
        },
    }
}

async fn copy_exact(
    reader: &mut (impl AsyncRead + Unpin),
    upstream: &mut (impl AsyncWrite + Unpin),
    length: u64,
) -> io::Result<()> {
    let copied = tokio::io::copy(&mut reader.take(length), upstream).await?;
    if copied < length {
        return Err(io::ErrorKind::UnexpectedEof.into());
    }
    Ok(())
}

/// One CRLF-terminated line of a chunked body.
async fn read_line(reader: &mut (impl AsyncBufRead + Unpin)) -> io::Result<Vec<u8>> {
    let mut line = Vec::new();
    let read = (&mut *reader)
        .take(MAX_LINE as u64)
        .read_until(b'\n', &mut line)
        .await?;
    if read == 0 || !line.ends_with(b"\r\n") {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "chunk line"));
    }
    Ok(line)
}

/// The response: interim (1xx) heads as they are, the final head without
/// hop-by-hop headers and with `Connection: close`, then the rest as it
/// comes until the destination closes.
async fn forward_response(
    upstream: ReadHalf<Guarded<TcpStream>>,
    writer: &mut Writer,
) -> io::Result<()> {
    let mut upstream = BufReader::new(upstream);
    let mut sent = false;
    loop {
        let parsed = match read_head(&mut upstream).await {
            Ok(Head::Complete(head)) => parse_head(&head).map(|parsed| (head, parsed)),
            _ => None,
        };
        let status = parsed.as_ref().and_then(|(_, parsed)| {
            let [version, code, _] = &parsed.start;
            let code: u16 = code.parse().ok().filter(|_| code.len() == 3)?;
            version.starts_with("HTTP/1.").then_some(code)
        });
        let (Some((head, parsed)), Some(status)) = (parsed, status) else {
            if !sent {
                writer.write_all(BAD_GATEWAY.as_bytes()).await?;
            }
            return Ok(());
        };
        if (100..200).contains(&status) && status != 101 {
            writer.write_all(&head).await?;
            writer.write_all(b"\r\n").await?;
            sent = true;
            continue;
        }
        let mut out = parsed.start.join(" ").into_bytes();
        out.extend_from_slice(b"\r\n");
        for line in parsed.forwarded_lines() {
            out.extend_from_slice(line);
            out.extend_from_slice(b"\r\n");
        }
        out.extend_from_slice(b"Connection: close\r\n\r\n");
        writer.write_all(&out).await?;
        break;
    }
    tokio::io::copy(&mut upstream, writer).await?;
    writer.shutdown().await
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A whole head, as [`read_head`] returns it (without the blank line).
    fn parsed(head: &str) -> Option<Parsed> {
        parse_head(head.strip_suffix("\r\n").unwrap().as_bytes())
    }

    #[test]
    fn connect_targets() {
        assert_eq!(
            connect_target("example.com:443"),
            Some(("example.com".into(), 443))
        );
        assert_eq!(connect_target("[::1]:22"), Some(("::1".into(), 22)));
        assert_eq!(connect_target("a.com:0080"), Some(("a.com".into(), 80)));
        for bad in [
            "example.com",
            "example.com:",
            "example.com:0",
            "example.com:+80",
            "example.com:65536",
            "example.com:80/x",
            "::1:443",
            "[::1]",
            "[]:80",
            ":80",
        ] {
            assert_eq!(connect_target(bad), None, "{bad}");
        }
    }

    #[test]
    fn heads_are_parsed_strictly() {
        let request = parsed("GET http://a/ HTTP/1.1\r\nHost: a\r\nX-A:  b \r\n\r\n").unwrap();
        assert_eq!(request.start, ["GET", "http://a/", "HTTP/1.1"]);
        assert_eq!(request.first("x-a"), Some("b"));
        for bad in [
            "GET http://a/ HTTP/1.1\r\nX: a\nHost: b\r\n\r\n",
            "GET http://a/ HTTP/1.1\r\nX: a\rHost: b\r\n\r\n",
            "GET http://a/ HTTP/1.1\r\nX: a\0\r\n\r\n",
            "GET http://a/ HTTP/1.1\r\nX: a\r\n folded\r\n\r\n",
            "GET http://a/ HTTP/1.1\r\nX : a\r\n\r\n",
            "GET http://a/ HTTP/1.1\r\nno colon\r\n\r\n",
            "GET\r\n\r\n",
        ] {
            assert!(parsed(bad).is_none(), "{bad:?}");
        }
    }

    #[test]
    fn framing_is_unambiguous() {
        let framing = |headers: &str| {
            body(&parsed(&format!("POST http://a/ HTTP/1.1\r\n{headers}\r\n")).unwrap())
        };
        assert_eq!(framing(""), Some(Body::None));
        assert_eq!(framing("Content-Length: 5\r\n"), Some(Body::Length(5)));
        assert_eq!(
            framing("Content-Length: 5\r\nContent-Length: 5\r\n"),
            Some(Body::Length(5))
        );
        assert_eq!(framing("Content-Length: 5, 5\r\n"), Some(Body::Length(5)));
        assert_eq!(framing("Content-Length: 0\r\n"), Some(Body::None));
        assert_eq!(
            framing("Transfer-Encoding: chunked\r\n"),
            Some(Body::Chunked)
        );
        assert_eq!(
            framing("Transfer-Encoding: gzip, Chunked\r\n"),
            Some(Body::Chunked)
        );
        for bad in [
            "Content-Length: 5\r\nContent-Length: 6\r\n",
            "Content-Length: -1\r\n",
            "Content-Length: 1e3\r\n",
            "Content-Length: 5\r\nTransfer-Encoding: chunked\r\n",
            "Transfer-Encoding: chunked, gzip\r\n",
            "Transfer-Encoding: identity\r\n",
        ] {
            assert_eq!(framing(bad), None, "{bad}");
        }
    }

    #[test]
    fn hop_by_hop_headers_are_dropped() {
        let request = parsed(
            "GET http://a/ HTTP/1.1\r\nHost: evil\r\nConnection: keep-alive, X-Secret, Content-Length\r\nX-Secret: s\r\nKeep-Alive: 5\r\nProxy-Authorization: Basic x\r\nProxy-Connection: x\r\nTE: trailers\r\nUpgrade: websocket\r\nContent-Length: 2\r\nAccept: */*\r\n\r\n",
        )
        .unwrap();
        let lines: Vec<String> = request
            .forwarded_lines()
            .iter()
            .map(|line| String::from_utf8_lossy(line).into_owned())
            .collect();
        assert_eq!(lines, ["Content-Length: 2", "Accept: */*"]);
    }

    #[tokio::test]
    async fn chunked_bodies_end_where_they_end() {
        let input = b"4;ext=1\r\nabcd\r\n0\r\nTrailer: x\r\n\r\nGET http://other/ HTTP/1.1\r\n\r\n";
        let mut reader = BufReader::new(&input[..]);
        let mut out = Vec::new();
        forward_body(&mut reader, &mut out, &Body::Chunked)
            .await
            .unwrap();
        assert_eq!(out, b"4;ext=1\r\nabcd\r\n0\r\nTrailer: x\r\n\r\n");
        let mut rest = Vec::new();
        reader.read_to_end(&mut rest).await.unwrap();
        assert_eq!(rest, b"GET http://other/ HTTP/1.1\r\n\r\n");

        for bad in [&b"zz\r\n"[..], b"4\r\nabcdXX", b"4\nabcd\r\n", b"4\r\nab"] {
            let mut reader = BufReader::new(bad);
            let mut out = Vec::new();
            assert!(
                forward_body(&mut reader, &mut out, &Body::Chunked)
                    .await
                    .is_err()
            );
        }
        let mut reader = BufReader::new(&b"abcdef"[..]);
        let mut out = Vec::new();
        forward_body(&mut reader, &mut out, &Body::Length(4))
            .await
            .unwrap();
        assert_eq!(out, b"abcd");
    }

    #[tokio::test]
    async fn heads_stop_at_the_blank_line() {
        let mut reader = BufReader::new(&b"GET / HTTP/1.1\r\nA: b\r\n\r\nbody"[..]);
        let Head::Complete(head) = read_head(&mut reader).await.unwrap() else {
            panic!("incomplete");
        };
        assert_eq!(head, b"GET / HTTP/1.1\r\nA: b\r\n");
        let mut rest = Vec::new();
        reader.read_to_end(&mut rest).await.unwrap();
        assert_eq!(rest, b"body");
        let big = vec![b'a'; MAX_HEAD + 10];
        assert!(matches!(
            read_head(&mut BufReader::new(&big[..])).await.unwrap(),
            Head::TooLarge
        ));
        assert!(matches!(
            read_head(&mut BufReader::new(&b"GET"[..])).await.unwrap(),
            Head::Eof
        ));
    }
}
