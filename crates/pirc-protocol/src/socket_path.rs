//! Unix socket paths longer than `sockaddr_un` holds (the node's inference
//! socket lives under its state directory, which may be deep).
//!
//! Bun bound and connected such paths; `std` refuses them ("path must be
//! shorter than SUN_LEN"). On Linux the socket is reached through
//! `/proc/self/fd/<dir fd>/<name>` instead, a short path to the same
//! directory entry. Elsewhere the long path is used as it is and fails as
//! before.

use std::fs::File;
use std::io;
use std::path::{Path, PathBuf};

/// Bytes `sockaddr_un.sun_path` holds with its terminating NUL: 108 on
/// Linux, 104 on macOS and the BSDs.
const SUN_PATH_BYTES: usize = if cfg!(target_os = "linux") { 108 } else { 104 };

/// A path to bind or connect to that the kernel accepts, and what must stay
/// open while it is used (the directory the short path goes through).
pub struct SocketPath {
    pub path: PathBuf,
    _directory: Option<File>,
}

impl SocketPath {
    /// `path` itself when it fits; on Linux, else, a path through an open
    /// descriptor of its directory.
    pub fn new(path: &Path) -> io::Result<Self> {
        use std::os::unix::ffi::OsStrExt;
        if path.as_os_str().as_bytes().len() < SUN_PATH_BYTES || !cfg!(target_os = "linux") {
            return Ok(Self {
                path: path.to_owned(),
                _directory: None,
            });
        }
        let (Some(parent), Some(name)) = (path.parent(), path.file_name()) else {
            return Ok(Self {
                path: path.to_owned(),
                _directory: None,
            });
        };
        // `O_PATH`: reaching the socket needs search permission on its
        // directory only, as with the full path.
        let directory = open_directory(parent)?;
        let short = Path::new("/proc/self/fd")
            .join(std::os::fd::AsRawFd::as_raw_fd(&directory).to_string())
            .join(name);
        Ok(Self {
            path: short,
            _directory: Some(directory),
        })
    }
}

#[cfg(target_os = "linux")]
fn open_directory(path: &Path) -> io::Result<File> {
    use std::os::unix::fs::OpenOptionsExt;
    std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_PATH | libc::O_DIRECTORY)
        .open(path)
}

#[cfg(not(target_os = "linux"))]
fn open_directory(path: &Path) -> io::Result<File> {
    File::open(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn short_paths_are_kept() {
        let path = Path::new("/run/pirc/i-abc/socket");
        assert_eq!(SocketPath::new(path).unwrap().path, path);
    }

    /// A directory removed on drop, and a `<directory>/socket` path of exactly
    /// `length` bytes under it (the directory name is padded to fit).
    struct Scratch(PathBuf);
    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    fn socket_of_length(label: &str, length: usize) -> (Scratch, PathBuf) {
        let base = std::env::temp_dir().canonicalize().unwrap();
        let root = base.join(format!("psp-{}-{label}", std::process::id()));
        let guard = Scratch(root.clone());
        let fixed = root.as_os_str().len() + "/x/socket".len();
        assert!(
            fixed <= length,
            "{} is too long for a {length}-byte socket path",
            root.display()
        );
        let directory = root.join("d".repeat(length - fixed + 1));
        std::fs::create_dir_all(&directory).unwrap();
        let socket = directory.join("socket");
        assert_eq!(socket.as_os_str().len(), length);
        (guard, socket)
    }

    #[test]
    fn a_path_one_byte_under_the_limit_is_kept_and_binds() {
        let (_guard, socket) = socket_of_length("fits", SUN_PATH_BYTES - 1);
        let bound = SocketPath::new(&socket).unwrap();
        assert_eq!(bound.path, socket);
        let _listener = std::os::unix::net::UnixListener::bind(&bound.path).unwrap();
        assert!(socket.exists());
    }

    /// One byte longer than `sockaddr_un` holds (it needs its terminating NUL).
    #[cfg(target_os = "linux")]
    #[test]
    fn a_path_one_byte_over_the_limit_goes_through_the_directory_on_linux() {
        let (_guard, socket) = socket_of_length("over", SUN_PATH_BYTES);
        let bound = SocketPath::new(&socket).unwrap();
        assert!(bound.path.starts_with("/proc/self/fd"), "{:?}", bound.path);
        assert!(bound.path.as_os_str().len() < SUN_PATH_BYTES);
        let _listener = std::os::unix::net::UnixListener::bind(&bound.path).unwrap();
        assert!(socket.exists());
    }

    /// Elsewhere the long path is returned as it is and the bind refuses it:
    /// documented ("fails as before"), and a plain error rather than a panic.
    #[cfg(not(target_os = "linux"))]
    #[test]
    fn a_path_one_byte_over_the_limit_is_returned_unchanged_and_refused_by_bind() {
        let (_guard, socket) = socket_of_length("over", SUN_PATH_BYTES);
        let bound = SocketPath::new(&socket).unwrap();
        assert_eq!(bound.path, socket);
        let error = std::os::unix::net::UnixListener::bind(&bound.path).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidInput, "{error}");
        assert!(!socket.exists());
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn long_paths_bind_and_connect_through_the_directory() {
        let root = std::env::temp_dir().join(format!("pirc-socket-{}", std::process::id()));
        let directory = root.join("d".repeat(150));
        std::fs::create_dir_all(&directory).unwrap();
        let socket = directory.join("socket");
        let bound = SocketPath::new(&socket).unwrap();
        assert!(bound.path.starts_with("/proc/self/fd"));
        let listener = std::os::unix::net::UnixListener::bind(&bound.path).unwrap();
        assert!(socket.exists());
        let connect = SocketPath::new(&socket).unwrap();
        let _client = std::os::unix::net::UnixStream::connect(&connect.path).unwrap();
        let _ = listener.accept().unwrap();
        std::fs::remove_dir_all(&root).unwrap();
    }
}
