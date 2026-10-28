//! Recordings (`browser_record`, the viewer's record button): the
//! session's screencast frames piped at 10 fps into ffmpeg
//! (`PIRC_FFMPEG`), VP9 WebM under `<session root>/.pirc/recordings/`, as
//! `node/browser.ts` does (`startRecording`/`stopRecording`). The manager
//! owns the parts that touch the tab (the seed frame, the screencast, the
//! 30-minute cap, the log); this is the ffmpeg process.
//!
//! The node creates the file itself without following symlinks
//! ([`crate::private_dir`]) and ffmpeg writes it as its fd 3
//! (`/dev/fd/3`), so a symlink in a cloned repository cannot redirect the
//! write (security audit I2).

use std::collections::BTreeMap;
use std::fs::File;
use std::os::fd::OwnedFd;
use std::pin::Pin;
use std::process::Stdio;
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicBool, Ordering},
};
use std::task::Poll;
use std::time::Duration;

use command_fds::{CommandFdExt as _, FdMapping};
use serde_json::{Value, json};
use tokio::io::{AsyncReadExt as _, AsyncWrite};
use tokio::process::Command;
use tokio::sync::watch;
use tokio::time::MissedTickBehavior;

use super::effects::Guard;
use crate::error::ApiError;

/// Frames written per second (`RECORD_FPS`).
pub const RECORD_FPS: u64 = 10;
/// A recording stops by itself after this long (`RECORD_MAX_MS`).
pub const RECORD_MAX: Duration = Duration::from_secs(30 * 60);
/// How long a stop waits for ffmpeg before killing it.
const STOP_TIMEOUT: Duration = Duration::from_secs(30);
/// stderr kept for the failure message (UTF-16 code units).
const STDERR_KEEP: usize = 2000;

/// The output file's descriptor in ffmpeg.
const OUTPUT_FD: i32 = 3;

/// ffmpeg's arguments (`browser.ts`, in its order), writing WebM to its
/// fd 3; the format is named, as the path has no extension.
pub fn ffmpeg_args() -> Vec<String> {
    [
        "-hide_banner",
        "-loglevel",
        "error",
        "-f",
        "image2pipe",
        "-framerate",
        "10",
        "-c:v",
        "mjpeg",
        "-i",
        "-",
        "-vf",
        "scale=trunc(iw/2)*2:trunc(ih/2)*2",
        "-c:v",
        "libvpx-vp9",
        "-deadline",
        "realtime",
        "-cpu-used",
        "8",
        "-b:v",
        "0",
        "-crf",
        "38",
        "-pix_fmt",
        "yuv420p",
        "-f",
        "webm",
        "-y",
        "/dev/fd/3",
    ]
    .into_iter()
    .map(str::to_owned)
    .collect()
}

/// The latest screencast JPEG of the tab, if any (read every tick).
pub type FrameSource = Arc<dyn Fn() -> Option<Arc<Vec<u8>>> + Send + Sync>;
/// Whether this recording is still the tab's (`tab.recording === recording`).
pub type StillCurrent = Arc<dyn Fn() -> bool + Send + Sync>;

/// A running ffmpeg fed with the tab's frames.
pub struct Recording {
    /// The file ffmpeg writes (its size is read from here, not the path).
    output: Arc<File>,
    /// `.pirc/recordings/<name>.webm`, relative to the session root.
    pub relative: String,
    /// `Date.now()` at the start.
    pub started_at: i64,
    failed: Arc<Mutex<Option<String>>>,
    /// The exit code once ffmpeg is gone (`None` inside: killed by a signal
    /// or never started).
    exited: watch::Receiver<Option<Option<i32>>>,
    stop: Arc<watch::Sender<bool>>,
    confirmed: Arc<AtomicBool>,
    timed_out: Arc<AtomicBool>,
    stop_wait: Duration,
}

/// Why a recording failed (shared with its [`Recording`]).
#[derive(Clone)]
pub struct Failure(Arc<Mutex<Option<String>>>);

impl Failure {
    pub fn get(&self) -> Option<String> {
        lock(&self.0).clone()
    }
}

/// How a stop ended (`code` of `stopRecording`).
pub enum Exit {
    Code(Option<i32>),
    Timeout,
}

/// A stopped recording, before its result is read.
pub struct Stopped {
    output: Arc<File>,
    pub relative: String,
    pub started_at: i64,
    pub exit: Exit,
    pub failed: Option<String>,
    /// The direct child was observed gone, independently of video validity.
    pub confirmed: bool,
}

impl Recording {
    /// Spawn `ffmpeg` (environment `env`, `withoutSecrets`) writing `output`,
    /// and write `frames()` into it every 100 ms. A write still in progress
    /// (ffmpeg not keeping up) skips the ticks until it is done, as
    /// `stdin.write` returning false did until `drain`. A spawn failure is
    /// [`Recording::failed`] (`ffmpeg not found (<ffmpeg>); set PIRC_FFMPEG`
    /// for a missing one; other errors carry Rust's text, not Node's).
    pub fn start(
        ffmpeg: &str,
        env: &BTreeMap<String, String>,
        output: File,
        relative: String,
        frames: FrameSource,
        still_current: StillCurrent,
    ) -> Self {
        Self::start_with_timeout(
            ffmpeg,
            env,
            output,
            relative,
            frames,
            still_current,
            STOP_TIMEOUT,
        )
    }

    fn start_with_timeout(
        ffmpeg: &str,
        env: &BTreeMap<String, String>,
        output: File,
        relative: String,
        frames: FrameSource,
        still_current: StillCurrent,
        grace: Duration,
    ) -> Self {
        let failed = Arc::new(Mutex::new(None::<String>));
        let (exited_tx, exited) = watch::channel(None);
        let stop = Arc::new(watch::channel(false).0);
        let confirmed = Arc::new(AtomicBool::new(false));
        let timed_out = Arc::new(AtomicBool::new(false));
        let authority = super::effects::resource();
        let output = Arc::new(output);
        let mut command = Command::new(ffmpeg);
        let mapped = match output.try_clone() {
            Ok(file) => command
                .fd_mappings(vec![FdMapping {
                    parent_fd: OwnedFd::from(file),
                    child_fd: OUTPUT_FD,
                }])
                .map(|_| ())
                .map_err(std::io::Error::other),
            Err(error) => Err(error),
        };
        command
            .args(ffmpeg_args())
            .env_clear()
            .envs(env)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);
        let recording = Self {
            output,
            relative,
            started_at: crate::util::now_ms(),
            failed: failed.clone(),
            exited,
            stop: stop.clone(),
            confirmed: confirmed.clone(),
            timed_out: timed_out.clone(),
            stop_wait: grace + Duration::from_secs(5),
        };
        if let Err(error) = mapped {
            *lock(&failed) = Some(error.to_string());
            confirmed.store(true, Ordering::Release);
            exited_tx.send_replace(Some(None));
            return recording;
        }
        let mut child = match command.spawn() {
            Ok(child) => child,
            Err(error) => {
                *lock(&failed) = Some(if error.kind() == std::io::ErrorKind::NotFound {
                    format!("ffmpeg not found ({ffmpeg}); set PIRC_FFMPEG")
                } else {
                    error.to_string()
                });
                confirmed.store(true, Ordering::Release);
                exited_tx.send_replace(Some(None));
                return recording;
            }
        };
        let stderr_text = Arc::new(Mutex::new(String::new()));
        let stderr_task = child.stderr.take().map(|mut stderr| {
            let text = stderr_text.clone();
            tokio::spawn(async move {
                let mut buffer = vec![0u8; 4096];
                while let Ok(n @ 1..) = stderr.read(&mut buffer).await {
                    let mut text = lock(&text);
                    text.push_str(&String::from_utf8_lossy(&buffer[..n]));
                    keep_tail(&mut text, STDERR_KEEP);
                }
            })
        });
        let stdout_task = child.stdout.take().map(|mut stdout| {
            tokio::spawn(async move {
                let mut buffer = vec![0u8; 4096];
                while let Ok(1..) = stdout.read(&mut buffer).await {}
            })
        });
        let writer = child.stdin.take().map(|mut stdin| {
            let failed = failed.clone();
            let stop = stop.clone();
            tokio::spawn(async move {
                let period = Duration::from_millis(1000 / RECORD_FPS);
                let mut ticks =
                    tokio::time::interval_at(tokio::time::Instant::now() + period, period);
                ticks.set_missed_tick_behavior(MissedTickBehavior::Skip);
                let mut stopping = stop.subscribe();
                loop {
                    tokio::select! {
                        biased;
                        _ = wait_stop(&mut stopping) => break,
                        _ = ticks.tick() => {}
                    }
                    let frame = match &authority {
                        Some(guard) => guard.run(|| frames()),
                        None => Ok(frames()),
                    };
                    let outcome = match frame {
                        Err(error) => FrameWrite::Denied(error),
                        Ok(None) => continue,
                        Ok(Some(frame)) => {
                            write_frame(&mut stdin, &frame, authority.as_ref(), &mut stopping).await
                        }
                    };
                    match outcome {
                        FrameWrite::Complete => {}
                        FrameWrite::Stopped | FrameWrite::Broken => break,
                        FrameWrite::Denied(error) => {
                            *lock(&failed) = Some(error.message);
                            stop.send_replace(true);
                            break;
                        }
                    }
                }
                // Dropping stdin interrupts even a backpressured partial JPEG;
                // it is private to this recorder, unlike a shared CDP frame.
            })
        });
        tokio::spawn(async move {
            // This supervisor owns stop/escalation even when Recording or its
            // stop waiter is dropped. Only this owned Child is ever signaled.
            let mut stopping = stop.subscribe();
            let status = tokio::select! {
                status = child.wait() => status,
                _ = wait_stop(&mut stopping) => {
                    match tokio::time::timeout(grace, child.wait()).await {
                        Ok(status) => status,
                        Err(_) => {
                            timed_out.store(true, Ordering::Release);
                            let _ = child.start_kill();
                            child.wait().await
                        }
                    }
                }
            };
            stop.send_replace(true);
            confirmed.store(status.is_ok(), Ordering::Release);
            finish_pipe_task(writer).await;
            finish_pipe_task(stderr_task).await;
            finish_pipe_task(stdout_task).await;
            let code = status.ok().and_then(|status| status.code());
            let stderr = lock(&stderr_text).clone();
            {
                let mut failed = lock(&failed);
                if failed.is_none() && !stderr.is_empty() && still_current() {
                    *failed = Some(stderr);
                }
            }
            exited_tx.send_replace(Some(code));
        });
        recording
    }

    /// Why the recording failed, once it has.
    pub fn failed(&self) -> Option<String> {
        lock(&self.failed).clone()
    }

    /// [`Recording::failed`], readable after the recording moved on.
    pub fn failure(&self) -> Failure {
        Failure(self.failed.clone())
    }

    /// Request stop immediately; the independent supervisor owns timeout,
    /// signaling and reaping even if nobody polls the returned future.
    pub fn stop(self) -> impl Future<Output = Stopped> + Send + 'static {
        self.stop.send_replace(true);
        async move {
            let mut exited = self.exited.clone();
            let observed =
                tokio::time::timeout(self.stop_wait, exited.wait_for(Option::is_some)).await;
            let (exit, confirmed) = match observed {
                Ok(Ok(code)) => (
                    if self.timed_out.load(Ordering::Acquire) {
                        Exit::Timeout
                    } else {
                        Exit::Code((*code).flatten())
                    },
                    self.confirmed.load(Ordering::Acquire),
                ),
                _ => (Exit::Timeout, false),
            };
            Stopped {
                failed: self.failed(),
                output: self.output.clone(),
                relative: self.relative.clone(),
                started_at: self.started_at,
                exit,
                confirmed,
            }
        }
    }
}

impl Drop for Recording {
    fn drop(&mut self) {
        self.stop.send_replace(true);
    }
}

async fn wait_stop(stop: &mut watch::Receiver<bool>) {
    let _ = stop.wait_for(|stopped| *stopped).await;
}

async fn finish_pipe_task(task: Option<tokio::task::JoinHandle<()>>) {
    if let Some(mut task) = task
        && tokio::time::timeout(Duration::from_secs(1), &mut task)
            .await
            .is_err()
    {
        task.abort();
        let _ = task.await;
    }
}

enum FrameWrite {
    Complete,
    Stopped,
    Broken,
    Denied(ApiError),
}

/// The resource gate surrounds each nonblocking poll, not a readiness wait.
/// Cancellation/revocation is also checked while a child never drains stdin.
async fn write_frame(
    stdin: &mut (impl AsyncWrite + Unpin),
    frame: &[u8],
    guard: Option<&Guard>,
    stop: &mut watch::Receiver<bool>,
) -> FrameWrite {
    let mut offset = 0;
    while offset < frame.len() {
        let write = std::future::poll_fn(|cx| {
            let mut effect = || Pin::new(&mut *stdin).poll_write(cx, &frame[offset..]);
            let result = match guard {
                Some(guard) => guard.run(effect),
                None => Ok(effect()),
            };
            match result {
                Ok(Poll::Pending) => Poll::Pending,
                Ok(Poll::Ready(result)) => Poll::Ready(Ok(result)),
                Err(error) => Poll::Ready(Err(error)),
            }
        });
        tokio::select! {
            biased;
            _ = wait_stop(stop) => return FrameWrite::Stopped,
            result = write => match result {
                Ok(Ok(n)) if n > 0 => offset += n,
                Ok(_) => return FrameWrite::Broken,
                Err(error) => return FrameWrite::Denied(error),
            },
            _ = tokio::time::sleep(Duration::from_millis(50)) => {
                if let Some(guard) = guard && let Err(error) = guard.run(|| ()) {
                    return FrameWrite::Denied(error);
                }
            }
        }
    }
    FrameWrite::Complete
}

impl Stopped {
    /// `{recording: false, path, bytes, durationMs}`, or 500 `browser_error`
    /// "Recording failed: <stderr | ffmpeg exited with <code>>". A missing
    /// file answers 500 `browser_error` with the I/O error (Rust's text;
    /// TS forwarded Node's `statSync` error the same way).
    pub fn result(&self) -> Result<Value, ApiError> {
        let code_ok = matches!(self.exit, Exit::Code(Some(0)));
        if !code_ok || self.failed.is_some() {
            let reason = self.failed.clone().unwrap_or_else(|| {
                format!(
                    "ffmpeg exited with {}",
                    match self.exit {
                        Exit::Timeout => "timeout".to_owned(),
                        Exit::Code(Some(code)) => code.to_string(),
                        Exit::Code(None) => "null".to_owned(),
                    }
                )
            });
            return Err(ApiError::new(
                500,
                "browser_error",
                format!("Recording failed: {reason}"),
            ));
        }
        let bytes = self
            .output
            .metadata()
            .map_err(|error| ApiError::new(500, "browser_error", error.to_string()))?
            .len();
        Ok(json!({
            "recording": false,
            "path": self.relative,
            "bytes": bytes,
            "durationMs": crate::util::now_ms() - self.started_at,
        }))
    }
}

/// `(text + chunk).slice(-max)` in UTF-16 code units.
fn keep_tail(text: &mut String, max: usize) {
    let mut units = 0;
    for (index, c) in text.char_indices().rev() {
        units += c.len_utf16();
        if units > max {
            let cut = index + c.len_utf8();
            text.drain(..cut);
            return;
        }
    }
}

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}

#[cfg(test)]
pub(crate) mod test_support {
    /// A stand-in ffmpeg: a shell script that copies stdin to the output
    /// file (its last argument) or fails with a message. Each call gets a
    /// fresh name (see [`crate::test_support::executable`]).
    pub(crate) fn fake_ffmpeg(dir: &std::path::Path, body: &str) -> String {
        static NEXT: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
        let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let path = dir.join(format!("ffmpeg-{n}"));
        crate::test_support::executable(&path, &format!("#!/bin/sh\n{body}\n"));
        path.display().to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::test_support::fake_ffmpeg;
    use super::*;

    #[tokio::test]
    async fn stop_supervision_survives_dropped_waiters_and_waits_for_exit() {
        for drop_waiter in [false, true] {
            let dir = tempfile::tempdir().unwrap();
            let ffmpeg = fake_ffmpeg(dir.path(), "exec /bin/sleep 30");
            let recording = Recording::start_with_timeout(
                &ffmpeg,
                &sh_env(),
                create(&dir.path().join("video")),
                "r".into(),
                no_frames(),
                Arc::new(|| false),
                Duration::from_millis(50),
            );
            let mut exited = recording.exited.clone();
            let confirmed = recording.confirmed.clone();
            let timed_out = recording.timed_out.clone();
            if drop_waiter {
                drop(recording.stop());
            } else {
                drop(recording);
            }
            tokio::time::timeout(Duration::from_secs(3), exited.wait_for(Option::is_some))
                .await
                .unwrap()
                .unwrap();
            assert!(confirmed.load(Ordering::Acquire));
            assert!(timed_out.load(Ordering::Acquire));
            assert_eq!(*exited.borrow(), Some(None));
        }
    }

    #[tokio::test]
    async fn resource_revocation_stops_a_backpressured_recorder_without_touching_a_peer() {
        let dir = tempfile::tempdir().unwrap();
        let ffmpeg = fake_ffmpeg(dir.path(), "printf ready >&3; exec /bin/sleep 30");
        let allowed = Arc::new(Mutex::new(true));
        let guard = Guard::new({
            let allowed = allowed.clone();
            move |effect| {
                let allowed = allowed.lock().unwrap();
                if !*allowed {
                    return Err(ApiError::conflict("environment revoked"));
                }
                effect();
                Ok(())
            }
        });
        let output = dir.path().join("video");
        let frames_seen = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let frames: FrameSource = {
            let count = frames_seen.clone();
            Arc::new(move || {
                count.fetch_add(1, Ordering::SeqCst);
                Some(Arc::new(vec![1; 2_000_000]))
            })
        };
        let recording = super::super::effects::with_resource(guard, async {
            Recording::start_with_timeout(
                &ffmpeg,
                &sh_env(),
                create(&output),
                "r".into(),
                frames,
                Arc::new(|| true),
                Duration::from_millis(50),
            )
        })
        .await;
        let mut peer = Command::new("/bin/sleep")
            .arg("30")
            .kill_on_drop(true)
            .spawn()
            .unwrap();
        tokio::time::timeout(Duration::from_secs(3), async {
            while frames_seen.load(Ordering::SeqCst) == 0
                || std::fs::read(&output).unwrap() != b"ready"
            {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
        *allowed.lock().unwrap() = false;
        let mut exited = recording.exited.clone();
        tokio::time::timeout(Duration::from_secs(3), exited.wait_for(Option::is_some))
            .await
            .unwrap()
            .unwrap();
        let stopped = recording.stop().await;
        assert!(stopped.confirmed);
        assert_eq!(stopped.failed.as_deref(), Some("environment revoked"));
        assert!(peer.try_wait().unwrap().is_none());
        peer.kill().await.unwrap();
    }

    #[tokio::test]
    async fn pending_frame_writes_recheck_revocation_without_pipe_readiness() {
        use tokio::io::AsyncReadExt;
        let (mut writer, mut reader) = tokio::io::duplex(4);
        let allowed = Arc::new(Mutex::new(true));
        let guard = Guard::new({
            let allowed = allowed.clone();
            move |effect| {
                let allowed = allowed.lock().unwrap();
                if !*allowed {
                    return Err(ApiError::conflict("revoked"));
                }
                effect();
                Ok(())
            }
        });
        let (_stop, mut stopped) = watch::channel(false);
        let work = tokio::spawn(async move {
            write_frame(&mut writer, b"123456789", Some(&guard), &mut stopped).await
        });
        // Read the actual first prefix, then leave the rest backpressured.
        let mut first = [0; 1];
        reader.read_exact(&mut first).await.unwrap();
        assert_eq!(first, *b"1");
        *allowed.lock().unwrap() = false;
        assert!(matches!(
            tokio::time::timeout(Duration::from_secs(2), work)
                .await
                .unwrap()
                .unwrap(),
            FrameWrite::Denied(_)
        ));
        let mut remaining = Vec::new();
        reader.read_to_end(&mut remaining).await.unwrap();
        assert!(remaining.len() <= 4, "no bytes admitted after the denial");
    }

    #[test]
    fn keeps_the_end_of_stderr() {
        let mut text = "ab😀cd".to_owned();
        keep_tail(&mut text, 4);
        assert_eq!(text, "😀cd");
        keep_tail(&mut text, 3);
        assert_eq!(text, "cd");
        keep_tail(&mut text, 10);
        assert_eq!(text, "cd");
    }

    #[test]
    fn passes_ffmpeg_its_arguments() {
        assert_eq!(
            ffmpeg_args().join(" "),
            "-hide_banner -loglevel error -f image2pipe -framerate 10 -c:v mjpeg -i - \
             -vf scale=trunc(iw/2)*2:trunc(ih/2)*2 -c:v libvpx-vp9 -deadline realtime \
             -cpu-used 8 -b:v 0 -crf 38 -pix_fmt yuv420p -f webm -y /dev/fd/3"
        );
    }

    fn create(path: &std::path::Path) -> File {
        File::create(path).unwrap()
    }

    fn no_frames() -> FrameSource {
        Arc::new(|| None)
    }

    #[tokio::test]
    async fn reports_a_missing_ffmpeg() {
        let dir = tempfile::tempdir().unwrap();
        let recording = Recording::start(
            "/nonexistent/ffmpeg",
            &BTreeMap::new(),
            create(&dir.path().join("a.webm")),
            ".pirc/recordings/a.webm".into(),
            no_frames(),
            Arc::new(|| true),
        );
        assert_eq!(
            recording.failed().as_deref(),
            Some("ffmpeg not found (/nonexistent/ffmpeg); set PIRC_FFMPEG")
        );
        let stopped = recording.stop().await;
        assert_eq!(
            stopped.result().unwrap_err().message,
            "Recording failed: ffmpeg not found (/nonexistent/ffmpeg); set PIRC_FFMPEG"
        );
    }

    fn sh_env() -> BTreeMap<String, String> {
        std::env::var("PATH")
            .map(|path| BTreeMap::from([("PATH".to_owned(), path)]))
            .unwrap_or_default()
    }

    #[tokio::test]
    async fn writes_the_latest_frame_at_ten_per_second() {
        let dir = tempfile::tempdir().unwrap();
        let ffmpeg = fake_ffmpeg(dir.path(), r#"for last; do :; done; cat > "$last""#);
        let file = dir.path().join("a.webm");
        let frame = Arc::new(b"JPEG".to_vec());
        let recording = Recording::start(
            &ffmpeg,
            &sh_env(),
            create(&file),
            ".pirc/recordings/a.webm".into(),
            Arc::new(move || Some(frame.clone())),
            Arc::new(|| true),
        );
        tokio::time::sleep(Duration::from_millis(550)).await;
        let stopped = recording.stop().await;
        let result = stopped.result().unwrap();
        assert_eq!(result["recording"], false);
        assert_eq!(result["path"], ".pirc/recordings/a.webm");
        let bytes = result["bytes"].as_u64().unwrap();
        assert_eq!(bytes % 4, 0);
        assert!((12..=28).contains(&bytes), "{bytes}");
        assert!(result["durationMs"].as_i64().unwrap() >= 500);
    }

    #[tokio::test]
    async fn a_dropped_recording_ends_ffmpeg_with_its_input() {
        let dir = tempfile::tempdir().unwrap();
        let ffmpeg = fake_ffmpeg(
            dir.path(),
            r#"for last; do :; done; cat > "$last"; echo end >> "$last""#,
        );
        let file = dir.path().join("a.webm");
        let frame = Arc::new(b"JPEG".to_vec());
        let recording = Recording::start(
            &ffmpeg,
            &sh_env(),
            create(&file),
            "r".into(),
            Arc::new(move || Some(frame.clone())),
            Arc::new(|| true),
        );
        tokio::time::sleep(Duration::from_millis(250)).await;
        let mut exited = recording.exited.clone();
        drop(recording);
        let code = *tokio::time::timeout(Duration::from_secs(10), exited.wait_for(Option::is_some))
            .await
            .unwrap()
            .unwrap();
        let code = code.flatten();
        // Killed, it would have no exit code and no "end".
        assert_eq!(code, Some(0));
        let written = std::fs::read_to_string(&file).unwrap();
        assert!(
            written.starts_with("JPEG") && written.ends_with("end\n"),
            "{written}"
        );
    }

    #[tokio::test]
    async fn fails_with_ffmpeg_stderr_or_its_exit_code() {
        let dir = tempfile::tempdir().unwrap();
        let ffmpeg = fake_ffmpeg(dir.path(), "echo 'bad input' >&2; exit 1");
        let recording = Recording::start(
            &ffmpeg,
            &sh_env(),
            create(&dir.path().join("a.webm")),
            "r".into(),
            no_frames(),
            Arc::new(|| true),
        );
        for _ in 0..100 {
            if recording.failed().is_some() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        assert_eq!(recording.failed().as_deref(), Some("bad input\n"));
        let error = recording.stop().await.result().unwrap_err();
        assert_eq!((error.status, &*error.code), (500, "browser_error"));
        assert_eq!(error.message, "Recording failed: bad input\n");

        // Stopped first: stderr is not the failure, the exit code is.
        let ffmpeg = fake_ffmpeg(dir.path(), "cat >/dev/null; echo late >&2; exit 3");
        let recording = Recording::start(
            &ffmpeg,
            &sh_env(),
            create(&dir.path().join("b.webm")),
            "r".into(),
            no_frames(),
            Arc::new(|| false),
        );
        let error = recording.stop().await.result().unwrap_err();
        assert_eq!(error.message, "Recording failed: ffmpeg exited with 3");
    }
}
