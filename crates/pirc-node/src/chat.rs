//! Chat workspace layout (`node/chat.ts`). Owner: **core**; `session_root`
//! is used by the runner and the panels.
//!
//! - A chat workspace's directory is `<state>/chat/<workspace id>` (0700,
//!   realpath).
//! - A chat session works in `<workspace>/sessions/<basename(session id)>`
//!   (created 0700 on every call); a directory workspace's sessions work in
//!   the workspace.

use std::fs::DirBuilder;
use std::os::unix::fs::DirBuilderExt;
use std::path::{Path, PathBuf};

use pirc_config::{NodeConfig, POTS_WORKSPACE_ID};
use pirc_protocol::mode::{Mode, Workdir};
use rusqlite::Connection;

use crate::error::{ApiError, ApiResult};
use crate::store::{Store, Workspace};

pub use pirc_config::text::trim as js_trim;

/// A file-system failure the caller cannot fix: logged, answered 500 (TS
/// threw a plain error).
fn io_failure(what: &str, path: &Path, error: std::io::Error) -> ApiError {
    crate::log::error(&format!("{what} {}: {error}", path.display()));
    ApiError::internal()
}

/// `mkdirSync(dir, { recursive: true, mode: 0o700 })`.
fn make_dir(dir: &Path) -> ApiResult<()> {
    DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(dir)
        .map_err(|error| io_failure("creating", dir, error))
}

/// `chatWorkspaceDir`: created if needed, canonical.
pub fn chat_workspace_dir(config: &NodeConfig, workspace_id: &str) -> ApiResult<PathBuf> {
    let dir = config.state_dir.join("chat").join(workspace_id);
    make_dir(&dir)?;
    dir.canonicalize()
        .map_err(|error| io_failure("resolving", &dir, error))
}

/// The workspace holding each pot's own session, on a chat node that has the
/// `pot` mode. Each session gets its private directory under it.
pub fn ensure_pots(config: &NodeConfig, db: &Connection) -> ApiResult<Workspace> {
    let dir = chat_workspace_dir(config, POTS_WORKSPACE_ID)?;
    db.ensure_chat_workspace(
        POTS_WORKSPACE_ID,
        &config.node_id,
        "Pots",
        &dir.to_string_lossy(),
        "pot",
    )
}

/// `path.basename`: the last non-empty `/`-separated part.
fn basename(text: &str) -> &str {
    text.split('/')
        .rfind(|part| !part.is_empty())
        .unwrap_or_default()
}

/// `sessionRoot`: where the session's agent, terminals and panels work.
pub fn session_root(workspace: &Workspace, session_id: &str, mode: &Mode) -> ApiResult<PathBuf> {
    let root = PathBuf::from(&workspace.canonical_path);
    if mode.workdir != Workdir::PerSession {
        return Ok(root);
    }
    let dir = root.join("sessions").join(basename(session_id));
    make_dir(&dir)?;
    Ok(dir)
}

#[cfg(test)]
mod tests {
    use serde_json::Map;

    use super::*;
    use pirc_protocol::mode::default_work;

    fn pot_mode() -> Mode {
        let (_, text) = pirc_config::modes::DEFAULT_MODE_FILES
            .iter()
            .find(|(file, _)| *file == "pot.md")
            .expect("the pot mode ships");
        pirc_config::modes::parse_mode("pot", text).expect("the pot mode parses")
    }

    fn chat(dir: &Path, mode: &Mode) -> Workspace {
        Workspace {
            id: "p".into(),
            host_id: "n".into(),
            display_name: "P".into(),
            canonical_path: dir.to_string_lossy().into_owned(),
            defaults: Map::new(),
            mode: mode.id.clone(),
        }
    }

    #[test]
    fn helpers_use_passed_capabilities_not_mode_names() {
        let dir = tempfile::tempdir().unwrap();
        let mut mode = pot_mode();
        mode.id = pirc_protocol::mode::ModeId::new("research").unwrap();
        let workspace = chat(dir.path(), &mode);
        assert_eq!(
            session_root(&workspace, "s", &mode).unwrap(),
            dir.path().join("sessions/s")
        );
        mode.workdir = Workdir::Workspace;
        assert_eq!(session_root(&workspace, "s", &mode).unwrap(), dir.path());
    }

    #[test]
    fn session_roots_follow_the_mode_workdir() {
        let dir = tempfile::tempdir().unwrap();
        let pot = pot_mode();
        let workspace = chat(dir.path(), &pot);
        let root = session_root(&workspace, "session_1", &pot).unwrap();
        assert_eq!(root, dir.path().join("sessions/session_1"));
        assert!(root.is_dir());
        assert_eq!(basename("a/b/"), "b");
        let work = default_work();
        let directory = chat(dir.path(), &work);
        assert_eq!(session_root(&directory, "s", &work).unwrap(), dir.path());
    }
}
