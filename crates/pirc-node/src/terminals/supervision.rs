//! One observer owns both signaling and reaping. Numeric group IDs are used
//! only while the unreaped direct child pins that identity; never after wait.
use super::*;
use nix::sys::signal::Signal;
use pirc_agent::tools::bash::kill_group;
use process_wrap::tokio::ChildWrapper;
use std::process::ExitStatus;

pub(super) async fn observe(
    mut child: Box<dyn ChildWrapper>,
    mut stopping: watch::Receiver<bool>,
) -> ApiResult<ExitStatus> {
    tokio::select! {
        biased;
        _ = stopping.wait_for(|stop| *stop) => {},
        result = child.wait() => return result.map_err(|_| journal::unresolved()),
    }
    // No wait/try_wait during the grace period: even an exited child must
    // remain unreaped until the last numeric group signal has been sent.
    let pid = child.id();
    if pid.is_none() {
        return Err(journal::unresolved());
    }
    kill_group(pid, Signal::SIGHUP);
    tokio::time::sleep(KILL_GRACE).await;
    kill_group(pid, Signal::SIGKILL);
    tokio::time::timeout(KILL_GRACE, child.wait())
        .await
        .map_err(|_| journal::unresolved())?
        .map_err(|_| journal::unresolved())
}

/// Finish the bounded final-output drain, cancel both pumps and observe their
/// destruction. Merely calling abort does not prove the master FD was released.
pub(super) async fn retire_io(
    reading: tokio::task::JoinHandle<()>,
    writing: tokio::task::JoinHandle<()>,
) -> ApiResult<()> {
    tokio::time::sleep(DRAIN).await;
    reading.abort();
    writing.abort();
    let joined = tokio::time::timeout(KILL_GRACE, async {
        let (read, write) = tokio::join!(reading, writing);
        [read, write]
            .into_iter()
            .all(|result| result.is_ok() || result.is_err_and(|error| error.is_cancelled()))
    })
    .await
    .map_err(|_| journal::unresolved())?;
    if !joined {
        return Err(journal::unresolved());
    }
    Ok(())
}

pub(super) async fn settle(entries: Vec<Arc<Entry>>) -> ApiResult<()> {
    // All stop requests were sent before joining; the deadline covers the
    // whole batch, including a native scope wait and both I/O owners, not
    // another grace period per terminal.
    tokio::time::timeout(KILL_GRACE * 4 + DRAIN + Duration::from_secs(1), async {
        let mut failure = None;
        for entry in entries {
            let mut done = entry.exited.clone();
            let result = match done.wait_for(Option::is_some).await {
                Ok(value) => value.clone().unwrap_or_else(|| Err(journal::unresolved())),
                Err(_) => Err(journal::unresolved()),
            };
            if let Err(error) = result {
                failure = Some(error);
            }
        }
        failure.map_or(Ok(()), Err)
    })
    .await
    .map_err(|_| journal::unresolved())?
}
