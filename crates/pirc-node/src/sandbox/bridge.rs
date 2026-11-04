//! `pirc-node sandbox-bridge`: runs inside the native Linux sandbox in
//! place of srt's socat processes. Owner: **network**. Internal: not in the
//! help text. Plain threads: the bridge carries a handful of connections
//! and must not start a runtime the agent does not need.
//!
//! - `sandbox-bridge <proxy socket> -- <command> [args...]` (spike C's
//!   `inner`; srt's two `socat TCP-LISTEN:{3128,1080},fork,reuseaddr
//!   UNIX-CONNECT:<socket>`): relays `127.0.0.1:3128` and `:1080` (and
//!   `[::1]` when the namespace has it, since `localhost` may resolve
//!   there first) to the node's proxy socket, which tells HTTP and SOCKS
//!   apart itself (srt's mux; both of srt's sockets were the mux's too),
//!   then runs the command. The command inherits stdin, stdout and stderr
//!   untouched (the agent's JSONL RPC); the bridge exits with its status
//!   (128 + n for a signal).
//! - `sandbox-bridge connect <proxy host:port> <user:password> <host>
//!   <port>`: the ssh `ProxyCommand` of the sandbox's `GIT_SSH_COMMAND`
//!   (srt's `socat - PROXY:localhost:%h:%p,proxyport=3128,proxyauth=…`):
//!   an HTTP `CONNECT` with the credential, then stdin and stdout relayed
//!   through the tunnel. A refusal is printed on stderr (exit 1).

use std::io::{self, BufRead, BufReader, Read, Write};
use std::net::{Shutdown, TcpListener, TcpStream};
use std::os::unix::net::UnixStream;
use std::os::unix::process::ExitStatusExt;
use std::path::PathBuf;
use std::process::{Command, ExitCode};
use std::thread;

use super::linux::{BRIDGE_PORT, BRIDGE_SOCKS_PORT};
use super::proxy::basic_authorization;

/// The subcommand's arguments after its name.
pub fn run(args: Vec<String>) -> ExitCode {
    if args.first().map(String::as_str) == Some("connect") {
        return connect(&args[1..]);
    }
    let mut args = args.into_iter();
    let (Some(socket), Some(separator)) = (args.next(), args.next()) else {
        return usage();
    };
    let command: Vec<String> = args.collect();
    if separator != "--" || command.is_empty() {
        return usage();
    }
    let socket = PathBuf::from(socket);
    let guard = std::env::var(super::launch_guard::ENV);
    let authorized = match guard.as_deref() {
        Ok(super::terminal_gate::MODE) => super::terminal_gate::enter(),
        Ok("1") => {
            super::fds::close_inherited();
            super::launch_guard::wait(&io::stdin(), std::time::Duration::from_secs(10))
        }
        Err(std::env::VarError::NotPresent) => {
            super::fds::close_inherited();
            Ok(())
        }
        _ => Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "invalid launch mode",
        )),
    };
    if authorized.is_err() {
        eprintln!("pirc-node sandbox-bridge: launch was not authorized");
        return ExitCode::from(125);
    }

    for port in [BRIDGE_PORT, BRIDGE_SOCKS_PORT] {
        // srt's socat listened on IPv4 only.
        let listener = match TcpListener::bind(("127.0.0.1", port)) {
            Ok(listener) => listener,
            Err(error) => {
                eprintln!("pirc-node sandbox-bridge: cannot listen on 127.0.0.1:{port}: {error}");
                return ExitCode::from(125);
            }
        };
        let listeners = std::iter::once(listener).chain(TcpListener::bind(("::1", port)).ok());
        for listener in listeners {
            let socket = socket.clone();
            thread::spawn(move || {
                for stream in listener.incoming().flatten() {
                    let socket = socket.clone();
                    thread::spawn(move || {
                        if let Ok(upstream) = UnixStream::connect(&socket) {
                            relay(stream, upstream);
                        }
                    });
                }
            });
        }
    }
    match Command::new(&command[0])
        .args(&command[1..])
        .env_remove(super::launch_guard::ENV)
        .status()
    {
        Ok(status) => {
            let code = status
                .code()
                .or_else(|| status.signal().map(|signal| 128 + signal))
                .unwrap_or(1);
            ExitCode::from(u8::try_from(code & 0xff).unwrap_or(1))
        }
        Err(error) => {
            eprintln!("pirc-node sandbox-bridge: {}: {error}", command[0]);
            ExitCode::from(127)
        }
    }
}

fn usage() -> ExitCode {
    eprintln!(
        "usage: pirc-node sandbox-bridge <proxy socket> -- <command> [args...]\n       pirc-node sandbox-bridge connect <proxy host:port> <user:password> <host> <port>"
    );
    ExitCode::from(2)
}

/// Copy both ways until each side has finished writing.
fn relay(tcp: TcpStream, unix: UnixStream) {
    let (Ok(mut tcp_read), Ok(mut unix_write)) = (tcp.try_clone(), unix.try_clone()) else {
        return;
    };
    let forward = thread::spawn(move || {
        let _ = io::copy(&mut tcp_read, &mut unix_write);
        let _ = unix_write.shutdown(Shutdown::Write);
    });
    let (mut unix_read, mut tcp_write) = (unix, tcp);
    let _ = io::copy(&mut unix_read, &mut tcp_write);
    let _ = tcp_write.shutdown(Shutdown::Write);
    let _ = forward.join();
}

/// `connect`: the tunnel on stdin and stdout.
fn connect(args: &[String]) -> ExitCode {
    let [proxy, credential, host, port] = args else {
        return usage();
    };
    let target = if host.contains(':') && !host.starts_with('[') {
        format!("[{host}]:{port}")
    } else {
        format!("{host}:{port}")
    };
    match open_tunnel(proxy, credential, &target) {
        Ok((reader, stream)) => {
            pipe_stdio(reader, stream);
            ExitCode::SUCCESS
        }
        Err(error) => {
            eprintln!("pirc-node sandbox-bridge: CONNECT {target}: {error}");
            ExitCode::from(1)
        }
    }
}

/// `CONNECT target` through the proxy; the reader keeps any bytes that
/// came after the proxy's answer.
fn open_tunnel(
    proxy: &str,
    credential: &str,
    target: &str,
) -> io::Result<(BufReader<TcpStream>, TcpStream)> {
    // CR or LF in an argument would inject request lines.
    if [proxy, credential, target]
        .iter()
        .any(|arg| arg.contains(['\r', '\n']))
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "invalid argument",
        ));
    }
    let mut stream = TcpStream::connect(proxy)?;
    write!(
        stream,
        "CONNECT {target} HTTP/1.1\r\nHost: {target}\r\nProxy-Authorization: {}\r\n\r\n",
        basic_authorization(credential)
    )?;
    let mut reader = BufReader::new(stream.try_clone()?);
    let mut status = String::new();
    reader.read_line(&mut status)?;
    let mut head_length = status.len();
    loop {
        let mut line = String::new();
        if reader.read_line(&mut line)? == 0 {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "the proxy closed the connection",
            ));
        }
        head_length += line.len();
        if head_length > 64 * 1024 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "the proxy's answer is too long",
            ));
        }
        if line == "\r\n" || line == "\n" {
            break;
        }
    }
    let status = status.trim_end();
    let success = status
        .split(' ')
        .nth(1)
        .is_some_and(|code| code.len() == 3 && code.starts_with('2'));
    if !success {
        // The body says why (`Connection blocked by network allowlist`).
        let mut body = Vec::new();
        let _ = reader.take(4096).read_to_end(&mut body);
        let body = String::from_utf8_lossy(&body);
        let body = body.trim();
        let reason = if body.is_empty() {
            status.to_owned()
        } else {
            format!("{status}: {body}")
        };
        return Err(io::Error::new(io::ErrorKind::PermissionDenied, reason));
    }
    Ok((reader, stream))
}

/// stdin to the tunnel, the tunnel to stdout, until the tunnel ends.
fn pipe_stdio(mut reader: BufReader<TcpStream>, stream: TcpStream) {
    let Ok(mut upstream) = stream.try_clone() else {
        return;
    };
    thread::spawn(move || {
        let _ = io::copy(&mut io::stdin().lock(), &mut upstream);
        let _ = upstream.shutdown(Shutdown::Write);
    });
    let mut stdout = io::stdout().lock();
    let mut buffer = [0u8; 16 * 1024];
    loop {
        match reader.read(&mut buffer) {
            Ok(0) | Err(_) => break,
            Ok(read) => {
                if stdout
                    .write_all(&buffer[..read])
                    .and_then(|()| stdout.flush())
                    .is_err()
                {
                    break;
                }
            }
        }
    }
    let _ = stream.shutdown(Shutdown::Both);
}

#[cfg(test)]
mod tests {
    use std::io::Write;

    use super::*;

    /// A one-shot fake proxy answering `reply` and recording the request head.
    fn fake_proxy(reply: &'static [u8]) -> (String, thread::JoinHandle<String>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap().to_string();
        let handle = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut head = String::new();
            loop {
                let mut line = String::new();
                reader.read_line(&mut line).unwrap();
                head.push_str(&line);
                if line == "\r\n" {
                    break;
                }
            }
            stream.write_all(reply).unwrap();
            head
        });
        (address, handle)
    }

    #[test]
    fn opens_tunnels_with_the_credential() {
        let (proxy, head) = fake_proxy(b"HTTP/1.1 200 Connection Established\r\n\r\nSSH-2.0-x\r\n");
        let (mut reader, _stream) = open_tunnel(&proxy, "srt:tok", "[::1]:22").unwrap();
        assert_eq!(
            head.join().unwrap(),
            "CONNECT [::1]:22 HTTP/1.1\r\nHost: [::1]:22\r\nProxy-Authorization: Basic c3J0OnRvaw==\r\n\r\n"
        );
        let mut banner = String::new();
        reader.read_line(&mut banner).unwrap();
        assert_eq!(banner, "SSH-2.0-x\r\n", "bytes after the answer are kept");
    }

    #[test]
    fn says_why_a_tunnel_was_refused() {
        let (proxy, _head) = fake_proxy(
            b"HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain\r\n\r\nConnection blocked by network allowlist",
        );
        let error = open_tunnel(&proxy, "srt:tok", "evil.com:22").unwrap_err();
        assert_eq!(
            error.to_string(),
            "HTTP/1.1 403 Forbidden: Connection blocked by network allowlist"
        );
        assert!(open_tunnel(&proxy, "srt:tok\r\nX: y", "a:22").is_err());
    }
}
