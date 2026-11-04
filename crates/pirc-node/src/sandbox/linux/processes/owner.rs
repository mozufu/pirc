//! Read-only process ownership checks. This module has no signaling operation.
//! pidfd_open uses the thread-group leader without PIDFD_THREAD: readable means
//! the last thread has exited, not merely that the leader stopped executing.
use crate::sandbox::processes::ObserverIdentity;
use std::io;

pub(crate) fn validate(owner: &ObserverIdentity) -> io::Result<()> {
    let boot = &owner.boot_id;
    if owner.version != 1
        || owner.pid == 0
        || owner.pid > i32::MAX as u32
        || owner.start_ticks == 0
        || owner.observer_namespace == 0
        || boot.len() != 36
        || !boot.bytes().enumerate().all(|(i, b)| {
            if [8, 13, 18, 23].contains(&i) {
                b == b'-'
            } else {
                b.is_ascii_hexdigit()
            }
        })
    {
        return Err(io::Error::other("invalid terminal I/O owner identity"));
    }
    Ok(())
}
pub(crate) fn matches(
    owner: &ObserverIdentity,
    kernel: &crate::sandbox::processes::Identity,
) -> bool {
    validate(owner).is_ok()
        && super::kernel::validate(kernel).is_ok()
        && owner.boot_id == kernel.boot_id
        && owner.observer_namespace == kernel.observer_namespace
}
#[cfg(target_os = "linux")]
mod platform {
    use super::*;
    use rustix::{
        event::{PollFd, PollFlags, Timespec, poll},
        process::{Pid, PidfdFlags, pidfd_open},
    };
    use std::{
        fs,
        os::{fd::OwnedFd, unix::fs::MetadataExt},
    };
    struct Readonly(OwnedFd);
    impl Readonly {
        fn open(pid: u32) -> io::Result<Self> {
            let raw = i32::try_from(pid).map_err(io::Error::other)?;
            let pid = Pid::from_raw(raw)
                .filter(|_| raw > 0)
                .ok_or_else(|| io::Error::other("invalid owner PID"))?;
            Ok(Self(pidfd_open(pid, PidfdFlags::empty())?))
        }
        fn gone(&self) -> io::Result<bool> {
            let mut fds = [PollFd::new(&self.0, PollFlags::IN)];
            poll(&mut fds, Some(&Timespec::default()))?;
            let events = fds[0].revents();
            if events.intersects(PollFlags::ERR | PollFlags::NVAL) {
                return Err(io::Error::other("cannot query owner pidfd"));
            }
            Ok(events.intersects(PollFlags::IN | PollFlags::HUP))
        }
    }
    pub(crate) fn current() -> io::Result<ObserverIdentity> {
        let pid = std::process::id();
        let pinned = Readonly::open(pid)?;
        let owner = ObserverIdentity {
            version: 1,
            pid,
            boot_id: fs::read_to_string("/proc/sys/kernel/random/boot_id")?
                .trim()
                .into(),
            observer_namespace: fs::metadata("/proc/self/ns/pid")?.ino(),
            start_ticks: super::super::kernel::start_ticks(&fs::read_to_string(
                "/proc/self/stat",
            )?)?,
        };
        validate(&owner)?;
        if pinned.gone()? {
            return Err(io::Error::other("owner exited during capture"));
        }
        Ok(owner)
    }
    pub(crate) fn gone(owner: &ObserverIdentity) -> io::Result<bool> {
        validate(owner)?;
        let boot = fs::read_to_string("/proc/sys/kernel/random/boot_id")?;
        let view = fs::metadata("/proc/self/ns/pid")?.ino();
        // Do not inspect a saved numeric PID in another boot or observer view.
        if boot.trim() != owner.boot_id || view != owner.observer_namespace {
            return Err(io::Error::other(
                "owner belongs to another host boot or PID view",
            ));
        }
        let pinned = match Readonly::open(owner.pid) {
            Ok(pinned) => pinned,
            Err(error) if error.raw_os_error() == Some(nix::libc::ESRCH) => return Ok(true),
            Err(error) => return Err(error),
        };
        if pinned.gone()? {
            return Ok(true);
        }
        let stat = match fs::read_to_string(format!("/proc/{}/stat", owner.pid)) {
            Ok(stat) => stat,
            Err(error) => return if pinned.gone()? { Ok(true) } else { Err(error) },
        };
        // A reused PID is not the old owner. Never signal or alter its process.
        if super::super::kernel::start_ticks(&stat)? != owner.start_ticks {
            return Ok(true);
        }
        pinned.gone()
    }
}
#[cfg(target_os = "linux")]
pub(crate) use platform::{current, gone};
#[cfg(not(target_os = "linux"))]
pub(crate) fn current() -> io::Result<ObserverIdentity> {
    Err(io::Error::other("terminal owner tracking requires Linux"))
}
#[cfg(not(target_os = "linux"))]
pub(crate) fn gone(owner: &ObserverIdentity) -> io::Result<bool> {
    validate(owner)?;
    Err(io::Error::other(
        "terminal owner reconciliation requires Linux",
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn invalid_owner_records_are_never_exit_evidence() {
        let owner = ObserverIdentity {
            version: 1,
            boot_id: "11111111-2222-3333-4444-555555555555".into(),
            observer_namespace: 10,
            pid: 1,
            start_ticks: 100,
        };
        validate(&owner).unwrap(); // A container's Node may legitimately be PID 1.
        for invalid in [
            ObserverIdentity {
                version: 2,
                ..owner.clone()
            },
            ObserverIdentity {
                pid: 0,
                ..owner.clone()
            },
            ObserverIdentity {
                start_ticks: 0,
                ..owner.clone()
            },
            ObserverIdentity {
                observer_namespace: 0,
                ..owner.clone()
            },
            ObserverIdentity {
                boot_id: "foreign".into(),
                ..owner.clone()
            },
        ] {
            assert!(validate(&invalid).is_err());
            assert!(gone(&invalid).is_err());
        }
    }
    #[cfg(target_os = "linux")]
    #[test]
    fn the_current_owner_and_all_its_threads_are_still_alive() {
        let owner = current().unwrap();
        assert_eq!(owner.pid, std::process::id());
        assert!(!gone(&owner).unwrap());
        let mut foreign = owner.clone();
        foreign.observer_namespace += 1;
        assert!(gone(&foreign).is_err());
        foreign = owner.clone();
        foreign.boot_id = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee".into();
        assert!(gone(&foreign).is_err());
        let mut reused = owner;
        reused.start_ticks += 1;
        assert!(gone(&reused).unwrap()); // Read-only; this test process survives.
    }
}
