//! Account-local private-directory registry shared by gateways and nodes.
//!
//! Records persist after exit: state remains private while its daemon is down.
//! Updates union paths under a process-shared lock, so concurrent instances and
//! older temporary parents cannot overwrite each other's protection.

use std::collections::BTreeSet;
use std::fs::{self, File};
use std::io::{self, Read, Write};
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use rustix::fs::{AtFlags, Dir, Mode, OFlags, mkdirat, openat, renameat, unlinkat};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::{Env, GatewayConfig, NodeConfig};

const MAX_RECORD_BYTES: u64 = 1024 * 1024;
const MAX_RECORDS: usize = 4096;
const MAX_PATHS: usize = 8192;
static NEXT_TEMP: AtomicU64 = AtomicU64::new(0);

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Record {
    version: u8,
    kind: String,
    id: String,
    private_dirs: BTreeSet<String>,
}

fn invalid() -> io::Error {
    io::Error::other("invalid or unsafe pirc private-directory registry")
}

fn check(file: &File, directory: bool, private: bool) -> io::Result<()> {
    let meta = file.metadata()?;
    let uid = rustix::process::getuid().as_raw();
    if meta.uid() != uid
        || (directory && !meta.is_dir())
        || (!directory && (!meta.is_file() || meta.nlink() != 1))
        || meta.mode() & if private { 0o077 } else { 0o022 } != 0
    {
        return Err(invalid());
    }
    Ok(())
}

/// The fixed root is already protected by SENSITIVE_HOME_PATHS. Directory
/// handles anchor every read/update; records and registry components cannot be
/// symlinks, hard-linked files, FIFOs, or writable by another account.
struct Registry {
    nodes: File,
    _lock: File,
}

impl Registry {
    fn open(env: &Env) -> io::Result<Self> {
        let home = env.home();
        if !home.is_absolute() {
            return Err(invalid());
        }
        let mut parent = File::open(home)?;
        for (part, private) in [(".local", false), ("pirc-node", true), ("nodes", true)] {
            match mkdirat(&parent, part, Mode::from_raw_mode(0o700)) {
                Ok(()) | Err(rustix::io::Errno::EXIST) => {}
                Err(error) => return Err(error.into()),
            }
            let dir = File::from(openat(
                &parent,
                part,
                OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
                Mode::empty(),
            )?);
            check(&dir, true, private)?;
            parent = dir;
        }
        let lock = File::from(openat(
            &parent,
            ".lock",
            OFlags::RDWR | OFlags::CREATE | OFlags::NOFOLLOW | OFlags::NONBLOCK | OFlags::CLOEXEC,
            Mode::from_raw_mode(0o600),
        )?);
        check(&lock, false, true)?;
        lock.lock()?;
        Ok(Self {
            nodes: parent,
            _lock: lock,
        })
    }

    fn read(&self, name: &str) -> io::Result<Option<Record>> {
        let fd = match openat(
            &self.nodes,
            name,
            OFlags::RDONLY | OFlags::NOFOLLOW | OFlags::NONBLOCK | OFlags::CLOEXEC,
            Mode::empty(),
        ) {
            Ok(fd) => fd,
            Err(rustix::io::Errno::NOENT) => return Ok(None),
            Err(error) => return Err(error.into()),
        };
        let file = File::from(fd);
        check(&file, false, true)?;
        let mut bytes = Vec::new();
        file.take(MAX_RECORD_BYTES + 1).read_to_end(&mut bytes)?;
        if bytes.len() as u64 > MAX_RECORD_BYTES {
            return Err(invalid());
        }
        let record: Record = serde_json::from_slice(&bytes).map_err(|_| invalid())?;
        if record.version != 1
            || !matches!(record.kind.as_str(), "node" | "gateway")
            || record.id.is_empty()
            || record.private_dirs.is_empty()
            || record.private_dirs.len() > MAX_PATHS
            || record
                .private_dirs
                .iter()
                .any(|p| !Path::new(p).is_absolute() || p.contains('\0'))
        {
            return Err(invalid());
        }
        Ok(Some(record))
    }

    fn update(&self, key: &str, mut record: Record) -> io::Result<()> {
        if let Some(old) = self.read(key)? {
            if old.kind != record.kind || old.id != record.id {
                return Err(invalid());
            }
            record.private_dirs.extend(old.private_dirs);
        }
        if record.private_dirs.len() > MAX_PATHS {
            return Err(invalid());
        }
        let bytes = serde_json::to_vec(&record).map_err(|_| invalid())?;
        if bytes.len() as u64 > MAX_RECORD_BYTES {
            return Err(invalid());
        }
        let (name, mut file) = loop {
            let name = format!(
                ".pending-{}-{}",
                std::process::id(),
                NEXT_TEMP.fetch_add(1, Ordering::Relaxed)
            );
            match openat(
                &self.nodes,
                name.as_str(),
                OFlags::WRONLY | OFlags::CREATE | OFlags::EXCL | OFlags::NOFOLLOW | OFlags::CLOEXEC,
                Mode::from_raw_mode(0o600),
            ) {
                Ok(fd) => break (name, File::from(fd)),
                Err(rustix::io::Errno::EXIST) => continue,
                Err(error) => return Err(error.into()),
            }
        };
        let result = (|| {
            file.write_all(&bytes)?;
            file.sync_all()?;
            renameat(&self.nodes, name.as_str(), &self.nodes, key)?;
            self.nodes.sync_all()
        })();
        if result.is_err() {
            let _ = unlinkat(&self.nodes, name.as_str(), AtFlags::empty());
        }
        result
    }
}

fn paths(items: impl IntoIterator<Item = PathBuf>) -> io::Result<BTreeSet<String>> {
    let mut out = BTreeSet::new();
    for item in items {
        if !item.is_absolute() {
            return Err(invalid());
        }
        out.insert(item.to_str().ok_or_else(invalid)?.to_owned());
        // Keep the spelling for link pinning and any existing target for old
        // state even if the owner repoints its symlink on a later restart.
        if let Ok(real) = fs::canonicalize(&item) {
            out.insert(real.to_str().ok_or_else(invalid)?.to_owned());
        }
    }
    Ok(out)
}

fn key(kind: &str, id: &str, state: &Path) -> String {
    let digest = Sha256::digest(state.as_os_str().as_encoded_bytes());
    // IDs are stored inside the record, never used as filename components.
    let hash = format!("{:x}", Sha256::digest([id.as_bytes(), &digest].concat()));
    format!("{kind}-{hash}.json")
}

/// All of the node's persistent private paths, including configured overrides.
pub fn node_private_dirs(config: &NodeConfig, env: &Env) -> Vec<PathBuf> {
    let mut dirs = vec![
        config.state_dir.clone(),
        config.sessions_dir.clone(),
        config.uploads_dir.clone(),
        config
            .database_path
            .parent()
            .unwrap_or(Path::new("/"))
            .to_path_buf(),
        config.browser.profiles_dir.clone(),
        config.workspace_memory_dir.clone(),
    ];
    if let Some(dir) = env.get("CREDENTIALS_DIRECTORY").filter(|s| !s.is_empty()) {
        dirs.push(env.resolve(dir));
    }
    dirs
}

/// Register before the node accepts work, and again before using a new temp
/// parent. Paths are never removed on process exit (a crash needs no cleanup).
pub fn register_node(config: &NodeConfig, env: &Env, temp_parent: Option<&Path>) -> io::Result<()> {
    let mut dirs = node_private_dirs(config, env);
    dirs.extend(temp_parent.map(Path::to_path_buf));
    Registry::open(env)?.update(
        &key("node", &config.node_id, &config.state_dir),
        Record {
            version: 1,
            kind: "node".into(),
            id: config.node_id.clone(),
            private_dirs: paths(dirs)?,
        },
    )
}

/// Gateway credentials/uploads and a separately configured database are private
/// too. Register before opening stores or accepting connections.
pub fn register_gateway(config: &GatewayConfig, env: &Env) -> io::Result<()> {
    Registry::open(env)?.update(
        &key("gateway", "gateway", &config.state_dir),
        Record {
            version: 1,
            kind: "gateway".into(),
            id: "gateway".into(),
            private_dirs: paths([
                config.state_dir.clone(),
                config.uploads_dir.clone(),
                config
                    .database_path
                    .parent()
                    .unwrap_or(Path::new("/"))
                    .to_path_buf(),
            ])?,
        },
    )
}

/// A fresh snapshot for each session/read-only command. Unreadable, malformed
/// or unsafe entries fail closed, rather than silently dropping protection.
pub fn private_dirs(env: &Env) -> io::Result<Vec<String>> {
    let registry = Registry::open(env)?;
    let mut names = Vec::new();
    for entry in Dir::read_from(&registry.nodes)? {
        let entry = entry?;
        let bytes = entry.file_name().to_bytes();
        if !bytes.ends_with(b".json") {
            continue;
        }
        names.push(
            std::str::from_utf8(bytes)
                .map_err(|_| invalid())?
                .to_owned(),
        );
        if names.len() > MAX_RECORDS {
            return Err(invalid());
        }
    }
    names.sort();
    let mut paths = BTreeSet::new();
    for name in names {
        let record = registry.read(&name)?.ok_or_else(invalid)?;
        paths.extend(record.private_dirs);
    }
    Ok(paths.into_iter().collect())
}

#[cfg(test)]
mod tests {
    use super::*;
    use pirc_protocol::NodeRole;
    use std::os::unix::fs::{OpenOptionsExt, PermissionsExt, symlink};
    use std::sync::{Arc, Barrier};

    fn fixture() -> (tempfile::TempDir, Env, NodeConfig) {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        let home = root.join("home");
        fs::create_dir(&home).unwrap();
        let env = Env::new(
            [
                ("HOME", home.to_str().unwrap()),
                ("PIRC_NODE_ID", "test-node"),
                ("PIRC_NODE_TOKEN", "0123456789abcdef0123456789abcdef"),
                ("PIRC_DAEMON_URL", "ws://127.0.0.1:8787"),
                ("PIRC_ALLOWED_USERS", "test-user"),
                ("PIRC_STATE_DIR", "state"),
            ],
            &root,
        );
        let config = NodeConfig::load(&env, NodeRole::Node).unwrap();
        (dir, env, config)
    }

    fn root(env: &Env) -> PathBuf {
        env.home().join(".local/pirc-node/nodes")
    }
    fn entry(env: &Env) -> PathBuf {
        fs::read_dir(root(env))
            .unwrap()
            .map(|e| e.unwrap().path())
            .find(|p| p.extension().is_some_and(|e| e == "json"))
            .unwrap()
    }
    fn write_private(file: &Path, bytes: &[u8]) {
        let mut out = fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(file)
            .unwrap();
        out.write_all(bytes).unwrap();
    }

    #[test]
    fn registers_overrides_and_gateway_state_without_secrets() {
        let (_dir, env, mut node) = fixture();
        node.sessions_dir = env.resolve("separate-sessions");
        node.uploads_dir = env.resolve("separate-uploads");
        node.browser.profiles_dir = env.resolve("separate-browser");
        node.workspace_memory_dir = env.resolve("separate-memory");
        node.database_path = env.resolve("separate-db/node.sqlite");
        register_node(&node, &env, Some(&env.resolve("temp-parent"))).unwrap();
        let snapshot = private_dirs(&env).unwrap();
        for name in [
            "state",
            "separate-sessions",
            "separate-uploads",
            "separate-browser",
            "separate-memory",
            "separate-db",
            "temp-parent",
        ] {
            assert!(
                snapshot.contains(&env.resolve(name).display().to_string()),
                "{name}"
            );
        }
        let gateway_env = Env::new(
            [
                (
                    "PIRC_NODE_TOKENS",
                    r#"{"n1":"0123456789abcdef0123456789abcdef"}"#,
                ),
                ("PIRC_TRUSTED_PROXIES", "127.0.0.1"),
                ("PIRC_ALLOWED_ORIGINS", "https://pirc.example"),
                ("PIRC_ALLOWED_HOSTS", "pirc.example"),
                ("PIRC_ALLOWED_USERS", "test-user"),
                ("PIRC_PROXY_SECRET_REQUIRED", "false"),
                ("PIRC_STATE_DIR", "gateway-state"),
                ("PIRC_TIMEZONE", "UTC"),
                ("HOME", env.home().to_str().unwrap()),
            ],
            env.resolve("."),
        );
        let gateway = GatewayConfig::load(&gateway_env).unwrap();
        register_gateway(&gateway, &gateway_env).unwrap();
        assert!(
            private_dirs(&env)
                .unwrap()
                .contains(&gateway.state_dir.display().to_string())
        );
        for file in fs::read_dir(root(&env)).unwrap().map(|e| e.unwrap().path()) {
            assert_eq!(file.metadata().unwrap().mode() & 0o777, 0o600);
            if file.extension().is_some_and(|e| e == "json") {
                let text = fs::read_to_string(file).unwrap();
                assert!(!text.contains(&node.node_token));
            }
        }
        assert_eq!(root(&env).metadata().unwrap().mode() & 0o777, 0o700);
    }

    #[test]
    fn concurrent_updates_keep_all_temp_parents_and_same_id_distinct_states() {
        let (_dir, env, config) = fixture();
        register_node(&config, &env, None).unwrap();
        let barrier = Arc::new(Barrier::new(9));
        std::thread::scope(|scope| {
            for n in 0..8 {
                let (env, config, barrier) = (env.clone(), config.clone(), barrier.clone());
                scope.spawn(move || {
                    barrier.wait();
                    register_node(&config, &env, Some(&env.resolve(format!("tmp-{n}")))).unwrap();
                    assert!(private_dirs(&env).is_ok());
                });
            }
            barrier.wait();
        });
        let mut other = config.clone();
        other.state_dir = env.resolve("other-state");
        register_node(&other, &env, None).unwrap();
        let snapshot = private_dirs(&env).unwrap();
        for n in 0..8 {
            assert!(snapshot.contains(&env.resolve(format!("tmp-{n}")).display().to_string()));
        }
        assert!(snapshot.contains(&other.state_dir.display().to_string()));
        assert!(snapshot.contains(&config.state_dir.display().to_string()));
        assert_eq!(
            fs::read_dir(root(&env))
                .unwrap()
                .filter(|e| e
                    .as_ref()
                    .unwrap()
                    .path()
                    .extension()
                    .is_some_and(|e| e == "json"))
                .count(),
            2
        );
    }

    #[test]
    fn retains_stopped_records_and_spelled_and_real_paths() {
        let (_dir, env, mut node) = fixture();
        let real = env.resolve("real-browser");
        fs::create_dir(&real).unwrap();
        let link = env.resolve("browser-link");
        symlink(&real, &link).unwrap();
        node.browser.profiles_dir = link.clone();
        register_node(&node, &env, None).unwrap();
        let first = private_dirs(&env).unwrap();
        assert!(first.contains(&link.display().to_string()));
        assert!(first.contains(&real.display().to_string()));
        fs::remove_dir(&real).unwrap();
        assert_eq!(
            private_dirs(&env).unwrap(),
            first,
            "missing/stopped state is not deregistered"
        );
    }

    #[test]
    fn malformed_or_unreadable_records_fail_closed() {
        let (_dir, env, config) = fixture();
        register_node(&config, &env, None).unwrap();
        let file = entry(&env);
        let saved = fs::read(&file).unwrap();
        for bad in [
            b"{".as_slice(),
            br#"{"version":2,"kind":"node","id":"n","privateDirs":["/state"]}"#,
            br#"{"version":1,"kind":"node","id":"n","privateDirs":["relative"]}"#,
            br#"{"version":1,"kind":"node","id":"n","privateDirs":[],"extra":true}"#,
        ] {
            write_private(&file, bad);
            assert!(private_dirs(&env).is_err());
        }
        write_private(&file, &saved);
        fs::set_permissions(&file, fs::Permissions::from_mode(0o666)).unwrap();
        assert!(private_dirs(&env).is_err());
    }

    #[test]
    fn rejects_symlink_hardlink_and_non_regular_records_and_locks() {
        for attack in [
            "symlink",
            "hardlink",
            "directory",
            "lock-symlink",
            "lock-hardlink",
        ] {
            let (_dir, env, config) = fixture();
            register_node(&config, &env, None).unwrap();
            let file = if attack.starts_with("lock-") {
                root(&env).join(".lock")
            } else {
                entry(&env)
            };
            let victim = env.resolve("victim");
            write_private(&victim, b"unchanged");
            fs::remove_file(&file).unwrap();
            match attack {
                "symlink" | "lock-symlink" => symlink(&victim, &file).unwrap(),
                "hardlink" | "lock-hardlink" => fs::hard_link(&victim, &file).unwrap(),
                _ => fs::create_dir(&file).unwrap(),
            }
            assert!(private_dirs(&env).is_err(), "{attack}");
            assert_eq!(fs::read(&victim).unwrap(), b"unchanged");
        }
    }

    #[test]
    fn rejects_redirected_or_writable_registry_directories() {
        for attack in ["link", "writable"] {
            let (_dir, env, config) = fixture();
            register_node(&config, &env, None).unwrap();
            let original = root(&env);
            let saved = original.with_file_name("saved");
            fs::rename(&original, &saved).unwrap();
            if attack == "link" {
                symlink(&saved, &original).unwrap();
            } else {
                fs::create_dir(&original).unwrap();
                fs::set_permissions(&original, fs::Permissions::from_mode(0o777)).unwrap();
            }
            assert!(private_dirs(&env).is_err(), "{attack}");
        }
    }
}
