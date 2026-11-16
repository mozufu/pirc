//! Scratch directories for tests that build fixture trees or bind Unix sockets.
//!
//! `CARGO_TARGET_TMPDIR` is a compile-cache location: its path is as long and as
//! odd as the checkout's target directory (an external volume's name may hold a
//! space, and a Unix socket address allows 103 bytes on macOS and 107 on Linux).
//! Runtime fixtures live in a short directory of their own instead, removed when
//! the returned guard drops. The root is `PIRC_TEST_SCRATCH` when it is set and
//! not empty, else the platform temporary directory; both are canonicalized so
//! the paths a test compares are the ones the kernel and a sandbox see.
use std::ffi::OsString;
use std::path::PathBuf;

/// Names the directory scratch directories are created in.
pub const SCRATCH_VARIABLE: &str = "PIRC_TEST_SCRATCH";

/// The canonical directory [`scratch_dir`] creates its directories in.
pub fn scratch_root() -> PathBuf {
    root_from(std::env::var_os(SCRATCH_VARIABLE))
}

/// [`scratch_root`] for an explicit `PIRC_TEST_SCRATCH` value.
pub fn root_from(configured: Option<OsString>) -> PathBuf {
    let base = configured
        .filter(|value| !value.is_empty())
        .map_or_else(std::env::temp_dir, PathBuf::from);
    base.canonicalize().unwrap_or_else(|error| {
        panic!(
            "the scratch directory {} ({SCRATCH_VARIABLE}, else the platform temporary directory) \
             cannot be used: {error}",
            base.display()
        )
    })
}

/// A new, uniquely named directory under [`scratch_root`], deleted on drop.
/// Keep `prefix` short: socket paths inside the directory share the limit.
pub fn scratch_dir(prefix: &str) -> tempfile::TempDir {
    tempfile::Builder::new()
        .prefix(prefix)
        .tempdir_in(scratch_root())
        .unwrap_or_else(|error| panic!("creating a scratch directory: {error}"))
}
