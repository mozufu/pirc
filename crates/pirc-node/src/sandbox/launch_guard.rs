//! Trusted bridge gate: no agent or proxy thread starts before Node commits
//! launch identity and releases this particular stdin pipe. EOF is refusal.
use rustix::event::{PollFd, PollFlags, Timespec, poll};
use std::io;
use std::os::fd::AsFd;
use std::time::{Duration, Instant};

pub(crate) const ENV: &str = "PIRC_NATIVE_LAUNCH_GUARD";
pub(crate) const PERMIT: &[u8] = b"PIRC-LAUNCH-1\n";

/// The trusted launcher must not run loader/shell hooks before reaching this
/// gate, even when the operator explicitly forwarded them to agent tools.
/// Agent config can install its tool environment after guarded startup instead.
pub(crate) fn validate_bootstrap(
    env: &std::collections::BTreeMap<String, String>,
) -> io::Result<()> {
    if env.keys().any(|name| {
        name.starts_with("LD_")
            || name.starts_with("DYLD_")
            || name.starts_with("_RLD")
            || name.starts_with("BASH_FUNC_")
            || matches!(
                name.as_str(),
                "BASH_ENV" | "ENV" | "SHELLOPTS" | "BASHOPTS" | "GLIBC_TUNABLES" | "GCONV_PATH"
            )
    }) {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "loader or shell bootstrap hooks are not allowed before guarded launch",
        ));
    }
    Ok(())
}

/// Unbuffered, bounded read: never consume the following configure/RPC bytes.
/// Only the trusted bridge calls this, before it starts threads or commands.
pub(crate) fn wait(input: &impl AsFd, timeout: Duration) -> io::Result<()> {
    let deadline = Instant::now() + timeout;
    let mut offset = 0;
    while offset < PERMIT.len() {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "launch permission expired",
            ));
        }
        let timeout = Timespec::try_from(remaining).map_err(io::Error::other)?;
        let mut fds = [PollFd::new(input, PollFlags::IN)];
        match poll(&mut fds, Some(&timeout)) {
            Err(rustix::io::Errno::INTR) => continue,
            Err(error) => return Err(error.into()),
            Ok(0) => {
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "launch permission expired",
                ));
            }
            Ok(_) => {}
        }
        if fds[0]
            .revents()
            .intersects(PollFlags::ERR | PollFlags::NVAL)
        {
            return Err(io::Error::other("launch pipe unavailable"));
        }
        let mut bytes = [0u8; PERMIT.len()];
        match rustix::io::read(input, &mut bytes[..PERMIT.len() - offset]) {
            Err(rustix::io::Errno::INTR) => continue,
            Err(error) => return Err(error.into()),
            Ok(0) => {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "Node closed launch pipe",
                ));
            }
            Ok(n) => {
                if bytes[..n] != PERMIT[offset..offset + n] {
                    return Err(io::Error::new(
                        io::ErrorKind::PermissionDenied,
                        "invalid launch permission",
                    ));
                }
                offset += n;
            }
        }
    }
    Ok(())
}

/// A single small nonblocking pipe write while the Node admission lock is held.
/// Never await here: acceptance of a new fence must not interleave with release.
pub(crate) fn release(output: &impl AsFd) -> io::Result<()> {
    // Tokio ChildStdin is nonblocking. Enforce that contract for other callers.
    let flags = rustix::fs::fcntl_getfl(output)?;
    if !flags.contains(rustix::fs::OFlags::NONBLOCK) {
        return Err(io::Error::other("launch writer must be nonblocking"));
    }
    loop {
        match rustix::io::write(output, PERMIT) {
            Err(rustix::io::Errno::INTR) => continue,
            Ok(n) if n == PERMIT.len() => return Ok(()),
            Ok(_) => return Err(io::Error::other("incomplete launch release")),
            Err(error) => return Err(error.into()),
        }
    }
}

#[cfg(test)]
pub(crate) fn wait_readable_for_test(input: &impl AsFd, timeout: Duration) -> io::Result<()> {
    let mut fds = [PollFd::new(input, PollFlags::IN)];
    let timeout = Timespec::try_from(timeout).map_err(io::Error::other)?;
    if poll(&mut fds, Some(&timeout))? > 0 {
        Ok(())
    } else {
        Err(io::Error::new(
            io::ErrorKind::TimedOut,
            "fixture stdin timed out",
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    #[test]
    fn refused_inputs_and_timeout_never_authorize_execution() {
        for data in [
            b"".as_slice(),
            b"PIRC-LAUNCH-",
            b"{\"type\":\"configure\"}",
            b"PIRC-LAUNCH-2\n",
        ] {
            let (reader, mut writer) = std::io::pipe().unwrap();
            writer.write_all(data).unwrap();
            drop(writer);
            assert!(wait(&reader, Duration::from_secs(1)).is_err());
        }
        let (reader, _writer) = std::io::pipe().unwrap();
        assert_eq!(
            wait(&reader, Duration::from_millis(10)).unwrap_err().kind(),
            io::ErrorKind::TimedOut
        );
    }
    #[test]
    fn fragmented_permission_preserves_following_rpc_bytes() {
        let (mut reader, mut writer) = std::io::pipe().unwrap();
        let thread = std::thread::spawn(move || {
            writer.write_all(&PERMIT[..4]).unwrap();
            std::thread::sleep(Duration::from_millis(10));
            writer.write_all(&PERMIT[4..]).unwrap();
            writer.write_all(b"{\"type\":\"configure\"}\n").unwrap();
        });
        wait(&reader, Duration::from_secs(1)).unwrap();
        let mut tail = String::new();
        reader.read_to_string(&mut tail).unwrap();
        assert_eq!(tail, "{\"type\":\"configure\"}\n");
        thread.join().unwrap();
    }
    #[test]
    fn release_is_one_nonblocking_write_and_cannot_release_a_peer() {
        let (reader, writer) = std::io::pipe().unwrap();
        let (peer, _peer_writer) = std::io::pipe().unwrap();
        assert!(release(&writer).is_err());
        rustix::fs::fcntl_setfl(&writer, rustix::fs::OFlags::NONBLOCK).unwrap();
        release(&writer).unwrap();
        wait(&reader, Duration::from_secs(1)).unwrap();
        assert!(wait(&peer, Duration::from_millis(10)).is_err());
    }
    #[test]
    fn launcher_hooks_cannot_execute_before_the_gate() {
        for key in [
            "LD_PRELOAD",
            "LD_LIBRARY_PATH",
            "LD_AUDIT",
            "DYLD_INSERT_LIBRARIES",
            "BASH_ENV",
            "ENV",
            "BASH_FUNC_exec%%",
            "GCONV_PATH",
            "GLIBC_TUNABLES",
        ] {
            assert!(validate_bootstrap(&[(key.to_owned(), "value".into())].into()).is_err());
        }
        assert!(
            validate_bootstrap(
                &[("PATH".into(), "/usr/bin".into()), (ENV.into(), "1".into())].into()
            )
            .is_ok()
        );
    }
}
