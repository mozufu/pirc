//! A private permit pipe, never PTY input. Only the trusted bridge may keep it
//! through descriptor cleanup; it is closed before proxies or user code start.
use super::launch_guard;
use std::{
    fs::File,
    io,
    os::fd::{AsRawFd, OwnedFd},
};
pub(crate) const FD: i32 = 5; // status 3, seccomp 4, long-profile arguments 9
pub(crate) const MODE: &str = "terminal-v1";
pub(crate) fn pipe() -> io::Result<(OwnedFd, std::io::PipeWriter)> {
    let (read, write) = std::io::pipe()?;
    nix::fcntl::fcntl(
        &write,
        nix::fcntl::FcntlArg::F_SETFL(nix::fcntl::OFlag::O_NONBLOCK),
    )?;
    Ok((read.into(), write))
}
pub(crate) fn wait_private() -> io::Result<()> {
    let gate = File::open(format!("/dev/fd/{FD}"))?;
    super::fds::close_except(&[gate.as_raw_fd()]);
    launch_guard::wait(&gate, std::time::Duration::from_secs(10))?;
    drop(gate);
    Ok(())
}
pub(crate) fn enter() -> io::Result<()> {
    wait_private()?;
    // This PTY was allocated exclusively for this work terminal. Never acquire
    // the Node's inherited terminal or start a runtime before setting it up.
    nix::unistd::setsid().map_err(io::Error::other)?;
    rustix::process::ioctl_tiocsctty(io::stdin()).map_err(io::Error::other)?;
    Ok(())
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use command_fds::{CommandFdExt, FdMapping};
    use std::{
        io::Write,
        process::{Command, Stdio},
        time::Duration,
    };
    pub(crate) const CHILD: &str = "sandbox::terminal_gate::tests::child_private_terminal_gate";
    /// A real process/PTY fixture, not evidence of a kernel namespace.
    #[test]
    #[ignore = "run by private_gate_is_not_keyboard_input and isolated-terminal fixtures"]
    fn child_private_terminal_gate() {
        let result = if std::env::var_os("PIRC_TEST_CTTY").is_some() {
            enter()
        } else {
            wait_private()
        };
        if result.is_err() {
            std::process::exit(125);
        }
        let report = std::env::var("PIRC_TEST_TERMINAL_REPORT").unwrap();
        let tty = File::open("/dev/tty").is_ok();
        let leaked = std::path::Path::new("/dev/fd/8").exists();
        let gate = std::path::Path::new("/dev/fd/5").exists();
        std::fs::write(&report, format!("{tty},{leaked},{gate}")).unwrap();
        let mut line = Vec::new();
        loop {
            let mut bytes = [0; 1];
            if launch_guard::wait_readable_for_test(&io::stdin(), Duration::from_secs(5)).is_err() {
                std::process::exit(124);
            }
            if rustix::io::read(io::stdin(), &mut bytes).unwrap_or(0) == 0 {
                std::process::exit(124)
            }
            line.push(bytes[0]);
            if bytes[0] == b'\n' {
                break;
            }
        }
        std::fs::write(format!("{report}.input"), line).unwrap();
        // Return through the test harness after the bounded input check.
    }
    #[tokio::test]
    async fn private_gate_is_not_keyboard_input_and_no_control_fd_reaches_work() {
        let dir = tempfile::tempdir().unwrap();
        let report = dir.path().join("report");
        let (master, slave) = crate::terminals::pty::open(24, 80).unwrap();
        let (read, mut write) = pipe().unwrap();
        let mut command = Command::new(std::env::current_exe().unwrap());
        command
            .args(["--exact", CHILD, "--ignored", "--nocapture"])
            .env("PIRC_TEST_CTTY", "1")
            .env("PIRC_TEST_TERMINAL_REPORT", &report)
            .stdin(slave.clone_stdio().unwrap())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        command
            .fd_mappings(vec![
                FdMapping {
                    parent_fd: read,
                    child_fd: FD,
                },
                FdMapping {
                    parent_fd: File::open("/dev/null").unwrap().into(),
                    child_fd: 8,
                },
            ])
            .unwrap();
        let mut child = command.spawn().unwrap();
        drop(command);
        drop(slave);
        master.write_test(launch_guard::PERMIT).unwrap();
        // Drain PTY echo just as the real terminal reader does. An unread tty
        // output queue can delay session-leader teardown on Darwin.
        let pump = tokio::spawn(async move {
            let mut bytes = [0u8; 1024];
            while let Ok(1..) = master.read(&mut bytes).await {}
        });
        tokio::time::sleep(Duration::from_millis(80)).await;
        assert!(!report.exists(), "PTY text authorized launch");
        write.write_all(launch_guard::PERMIT).unwrap();
        drop(write);
        let status = tokio::time::timeout(Duration::from_secs(8), async {
            loop {
                if let Some(status) = child.try_wait().unwrap() {
                    break status;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await;
        pump.abort();
        let _ = pump.await;
        if status.is_err() {
            let _ = child.kill();
            // Never block the test runtime in Child::wait after a failed PTY test.
            for _ in 0..100 {
                if child.try_wait().unwrap().is_some() {
                    break;
                }
                std::thread::sleep(Duration::from_millis(10));
            }
        }
        assert!(
            status.is_ok(),
            "helper report={:?}, input={:?}",
            std::fs::read_to_string(&report),
            std::fs::read(format!("{}.input", report.display()))
        );
        assert!(status.unwrap().success());
        assert_eq!(
            std::fs::read_to_string(&report).unwrap(),
            "true,false,false"
        );
        assert_eq!(
            std::fs::read(format!("{}.input", report.display())).unwrap(),
            launch_guard::PERMIT
        );
    }
}
