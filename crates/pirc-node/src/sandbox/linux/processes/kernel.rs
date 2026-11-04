use super::{Child, Handle, Identity, Kernel};
use std::{io, sync::Arc};
pub(super) struct Platform;

#[cfg(not(target_os = "linux"))]
impl Kernel for Platform {
    fn wrapper(&self, _: u32) -> io::Result<Arc<dyn Handle>> {
        Err(io::Error::other("PID namespace tracking requires Linux"))
    }
    fn capture(&self, _: u32, _: &dyn Handle, _: &Child) -> io::Result<Arc<dyn Handle>> {
        Err(io::Error::other("PID namespace tracking requires Linux"))
    }
}

#[cfg(target_os = "linux")]
mod linux {
    use super::*;
    use rustix::{
        event::{PollFd, PollFlags, Timespec, poll},
        process::{Pid, PidfdFlags, Signal, pidfd_open, pidfd_send_signal},
    };
    use std::{
        fs,
        os::{fd::OwnedFd, unix::fs::MetadataExt},
    };

    struct Pinned {
        fd: OwnedFd,
        identity: Option<Identity>,
    }
    impl Pinned {
        fn open(pid: u32) -> io::Result<Self> {
            let raw = i32::try_from(pid).map_err(io::Error::other)?;
            let pid = Pid::from_raw(raw)
                .filter(|_| raw > 1)
                .ok_or_else(|| io::Error::other("invalid PID"))?;
            Ok(Self {
                fd: pidfd_open(pid, PidfdFlags::empty())?,
                identity: None,
            })
        }
    }
    impl Handle for Pinned {
        fn identity(&self) -> Option<Identity> {
            self.identity.clone()
        }
        fn exited(&self) -> io::Result<bool> {
            let mut fds = [PollFd::new(&self.fd, PollFlags::IN)];
            poll(&mut fds, Some(&Timespec::default()))?;
            let events = fds[0].revents();
            if events.intersects(PollFlags::ERR | PollFlags::NVAL) {
                return Err(io::Error::other("cannot query pidfd"));
            }
            Ok(events.intersects(PollFlags::IN | PollFlags::HUP))
        }
        fn kill(&self) -> io::Result<()> {
            pidfd_send_signal(&self.fd, Signal::KILL).map_err(Into::into)
        }
    }
    impl Kernel for Platform {
        fn wrapper(&self, pid: u32) -> io::Result<Arc<dyn Handle>> {
            Ok(Arc::new(Pinned::open(pid)?))
        }
        fn capture(
            &self,
            wrapper_pid: u32,
            wrapper: &dyn Handle,
            child: &Child,
        ) -> io::Result<Arc<dyn Handle>> {
            let refuse = || io::Error::other("sandbox namespace identity not confirmed");
            if wrapper.exited()? || child.pid == wrapper_pid {
                return Err(refuse());
            }
            let mut pinned = Pinned::open(child.pid)?;
            let status = fs::read_to_string(format!("/proc/{}/status", child.pid))?;
            let host = fs::metadata("/proc/self/ns/pid")?.ino();
            // Pin before checking /proc, then check both handles again. The
            // trusted live wrapper has exactly one namespace child, so a dead
            // child/PID reused by an unrelated process cannot pass this check.
            // The namespace inode comes from bubblewrap's private status pipe,
            // before it drops privilege. Reading /proc/child/ns/pid here would
            // require ptrace access to the namespace init on some hosts. PPid +
            // NSpid + both live pinned identities validate the same sole child.
            // No setns or as-pid-1 option is used by our native invocation.
            if !namespace_child(&status, wrapper_pid, child.pid)
                || child.namespace == host
                || pinned.exited()?
                || wrapper.exited()?
            {
                return Err(refuse());
            }
            let start_ticks =
                start_ticks(&fs::read_to_string(format!("/proc/{}/stat", child.pid))?)?;
            let boot_id = fs::read_to_string("/proc/sys/kernel/random/boot_id")?
                .trim()
                .to_owned();
            if pinned.exited()? || wrapper.exited()? {
                return Err(refuse());
            }
            pinned.identity = Some(Identity {
                boot_id,
                observer_namespace: host,
                namespace: child.namespace,
                pid: child.pid,
                start_ticks,
            });
            Ok(Arc::new(pinned))
        }
    }
    pub(crate) fn reopen(identity: &Identity) -> io::Result<Option<Arc<dyn Handle>>> {
        validate(identity)?;
        let boot = fs::read_to_string("/proc/sys/kernel/random/boot_id")?;
        let view = fs::metadata("/proc/self/ns/pid")?.ino();
        if boot.trim() != identity.boot_id || view != identity.observer_namespace {
            return Err(io::Error::other(
                "saved scope belongs to another host boot or PID view",
            ));
        }
        let pinned = match Pinned::open(identity.pid) {
            Ok(pinned) => pinned,
            Err(e) if e.raw_os_error() == Some(nix::libc::ESRCH) => return Ok(None),
            Err(e) => return Err(e),
        };
        if pinned.exited()? {
            return Ok(None);
        }
        let stat = fs::read_to_string(format!("/proc/{}/stat", identity.pid))?;
        if start_ticks(&stat)? != identity.start_ticks {
            return Ok(None);
        }
        let ns = fs::metadata(format!("/proc/{}/ns/pid", identity.pid))?.ino();
        if ns != identity.namespace {
            return Ok(None);
        }
        let status = fs::read_to_string(format!("/proc/{}/status", identity.pid))?;
        // Reparenting is expected after Node/launcher death. Require init's
        // namespace identity, not the old parent, before signaling this handle.
        let pids = status
            .lines()
            .find_map(|l| l.strip_prefix("NSpid:"))
            .ok_or_else(|| io::Error::other("missing namespace PID identity"))?;
        let pids = pids
            .split_whitespace()
            .map(str::parse::<u32>)
            .collect::<Result<Vec<_>, _>>()
            .map_err(io::Error::other)?;
        if pids.len() < 2 || pids.first() != Some(&identity.pid) || pids.last() != Some(&1) {
            return Err(io::Error::other("saved process is not namespace init"));
        }
        if pinned.exited()? {
            return Ok(None);
        }
        Ok(Some(Arc::new(pinned)))
    }
}

/// /proc status is read between acquiring the child pidfd and verifying both
/// handles are still live. A status from a later PID reuse cannot authorize it.
#[cfg(any(target_os = "linux", test))]
fn namespace_child(status: &str, wrapper: u32, child: u32) -> bool {
    let parent = status
        .lines()
        .find_map(|l| l.strip_prefix("PPid:"))
        .and_then(|s| s.trim().parse::<u32>().ok());
    let pids = status
        .lines()
        .find_map(|l| l.strip_prefix("NSpid:"))
        .map(|s| {
            s.split_whitespace()
                .map(str::parse::<u32>)
                .collect::<Result<Vec<_>, _>>()
        });
    parent == Some(wrapper)
        && pids.is_some_and(|p| {
            p.is_ok_and(|p| p.len() >= 2 && p.first() == Some(&child) && p.last() == Some(&1))
        })
}

#[cfg(target_os = "linux")]
pub(super) use linux::reopen;
#[cfg(not(target_os = "linux"))]
pub(super) fn reopen(_: &Identity) -> io::Result<Option<Arc<dyn Handle>>> {
    Err(io::Error::other("saved PID namespace requires Linux"))
}

pub(super) fn validate(identity: &Identity) -> io::Result<()> {
    if identity.pid <= 1
        || identity.pid > i32::MAX as u32
        || identity.namespace == 0
        || identity.namespace == identity.observer_namespace
        || identity.observer_namespace == 0
        || identity.start_ticks == 0
        || identity.boot_id.len() != 36
        || !identity.boot_id.bytes().enumerate().all(|(i, b)| {
            if [8, 13, 18, 23].contains(&i) {
                b == b'-'
            } else {
                b.is_ascii_hexdigit()
            }
        })
    {
        return Err(io::Error::other("invalid saved kernel identity"));
    }
    Ok(())
}

#[cfg(any(target_os = "linux", test))]
pub(super) fn start_ticks(stat: &str) -> io::Result<u64> {
    // The comm field may contain spaces and parentheses; fields after the last
    // closing parenthesis begin at field 3, starttime is field 22.
    stat.rsplit_once(')')
        .and_then(|(_, tail)| tail.split_whitespace().nth(19))
        .and_then(|s| s.parse().ok())
        .filter(|ticks| *ticks > 0)
        .ok_or_else(|| io::Error::other("invalid process start time"))
}

#[cfg(test)]
mod tests {
    use super::{namespace_child, start_ticks, validate};
    #[test]
    fn process_start_time_ignores_spaces_and_parentheses_in_comm() {
        let fields = std::iter::once("S")
            .chain(std::iter::repeat_n("0", 18))
            .chain(["12345", "0"])
            .collect::<Vec<_>>()
            .join(" ");
        assert_eq!(
            start_ticks(&format!("22 (name (with) spaces)) {fields}")).unwrap(),
            12345
        );
        for invalid in ["", "22 (name) S 1 2", "22 no-comm"] {
            assert!(start_ticks(invalid).is_err());
        }
    }
    #[test]
    fn rejects_non_process_and_host_namespace_saved_identities() {
        let good = super::Identity {
            boot_id: "11111111-2222-3333-4444-555555555555".into(),
            observer_namespace: 10,
            namespace: 11,
            pid: 22,
            start_ticks: 123,
        };
        validate(&good).unwrap();
        for bad in [
            super::Identity {
                pid: 1,
                ..good.clone()
            },
            super::Identity {
                namespace: 10,
                ..good.clone()
            },
            super::Identity {
                boot_id: "different host".into(),
                ..good.clone()
            },
            super::Identity {
                start_ticks: 0,
                ..good.clone()
            },
        ] {
            assert!(validate(&bad).is_err());
        }
    }
    #[test]
    fn requires_exact_parent_and_namespace_init_identity() {
        assert!(namespace_child("PPid: 7\nNSpid: 22 1\n", 7, 22));
        assert!(namespace_child("PPid: 7\nNSpid: 22 5 1\n", 7, 22));
        for status in [
            "",
            "PPid: 7\nNSpid: 22",
            "PPid: 8\nNSpid: 22 1",
            "PPid: 7\nNSpid: 99 1",
            "PPid: 7\nNSpid: 22 2",
            "PPid: 7\nNSpid: 22 x 1",
        ] {
            assert!(!namespace_child(status, 7, 22), "{status}");
        }
    }
}
