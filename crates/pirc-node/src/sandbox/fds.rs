//! The descriptors a sandboxed command inherits: stdio, and whatever its
//! sandbox maps on purpose (srt's control pipe, bubblewrap's status pipe).
//!
//! Everything this process opens itself is close-on-exec (`std`, tokio,
//! rustix and nix all pass `O_CLOEXEC`; `command-fds` maps the sandboxes'
//! pipes in the child only). A descriptor the node *inherited* is not:
//! whatever started it (a terminal, a supervisor, a script) may have left
//! one open, a PTY whose other end is a shell outside the sandbox, say.
//! bubblewrap and srt pass every descriptor that survives `exec` on to the
//! agent, and a command written to such a PTY runs outside the sandbox, as
//! the node's user and with none of its restrictions. So:
//!
//! - the node closes every inherited descriptor above stderr when it
//!   starts, before any thread or child ([`close_inherited`]): nothing it
//!   spawns (agents, panel commands, terminals, the browser) gets one, and
//!   the node no longer holds them either;
//! - the in-sandbox bridge does the same before it runs the agent, so
//!   whatever reached it anyway stops there (it shares a uid and PID
//!   namespace with the agent, which could otherwise open its descriptors
//!   through `/proc/<pid>/fd`).
//!
//! The node takes no descriptor from its parent (no socket activation):
//! its stdio is all it keeps.

use std::os::fd::RawFd;

/// The first descriptor past stdio.
const FIRST: RawFd = 3;

/// This process's open descriptors (`/proc/self/fd`, `/dev/fd` on macOS),
/// sorted. The listing's own descriptor may be among them (closed by the
/// time this returns). Empty when neither can be listed.
pub fn open_fds() -> Vec<RawFd> {
    let dir = if cfg!(target_os = "linux") {
        "/proc/self/fd"
    } else {
        "/dev/fd"
    };
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut fds: Vec<RawFd> = entries
        .flatten()
        .filter_map(|entry| entry.file_name().to_str()?.parse().ok())
        .collect();
    fds.sort_unstable();
    fds.dedup();
    fds
}

/// Close every descriptor above stderr. Only where nothing in the process
/// owns one yet: at the start of `main`, single-threaded. Returns the
/// descriptors closed (the listing's own, already gone, is not counted).
pub fn close_inherited() -> Vec<RawFd> {
    close_except(&[])
}
/// Only trusted bootstrap code may temporarily keep an owned private gate.
pub(crate) fn close_except(keep: &[RawFd]) -> Vec<RawFd> {
    open_fds()
        .into_iter()
        .filter(|fd| *fd >= FIRST && !keep.contains(fd))
        .filter(|fd| nix::unistd::close(*fd).is_ok())
        .collect()
}

#[cfg(test)]
mod tests {
    use std::os::fd::{AsRawFd as _, OwnedFd};
    use std::path::Path;

    use nix::fcntl::{FcntlArg, FdFlag, fcntl};

    use super::*;

    /// Set in the child [`a_started_process_closes_what_it_inherited`] runs.
    const CHILD: &str = "PIRC_FDS_TEST_LEAKED";

    /// The child's half: the leaked descriptor is open on entry, closed
    /// after [`close_inherited`]. Runs only in that child.
    #[test]
    #[ignore = "run by a_started_process_closes_what_it_inherited"]
    fn child_closes_its_inherited_descriptors() {
        let fd: RawFd = std::env::var(CHILD).unwrap().parse().unwrap();
        let open = |fd: RawFd| Path::new(&format!("/dev/fd/{fd}")).exists();
        assert!(open(fd), "the descriptor was not inherited");
        assert!(close_inherited().contains(&fd));
        assert!(!open(fd));
        assert!(open(0) && open(1) && open(2), "stdio stays");
    }

    /// A descriptor inherited without close-on-exec (a PTY, say) is gone
    /// once a process ran [`close_inherited`].
    #[test]
    fn a_started_process_closes_what_it_inherited() {
        let leaked: OwnedFd = std::fs::File::open("/dev/null").unwrap().into();
        fcntl(&leaked, FcntlArg::F_SETFD(FdFlag::empty())).unwrap();
        let output = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "sandbox::fds::tests::child_closes_its_inherited_descriptors",
                "--ignored",
                "--nocapture",
            ])
            .env(CHILD, leaked.as_raw_fd().to_string())
            .output()
            .unwrap();
        let text = String::from_utf8_lossy(&output.stdout);
        assert!(
            output.status.success() && text.contains("1 passed"),
            "{text}{}",
            String::from_utf8_lossy(&output.stderr)
        );
    }
}
