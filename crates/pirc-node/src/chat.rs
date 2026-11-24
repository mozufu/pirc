//! Chat workspace layout (`node/chat.ts`). Owner: **core**; `session_root`
//! and the instructions readers are used by the runner and the panels.
//!
//! - A chat workspace's directory is `<state>/chat/<workspace id>` (0700,
//!   realpath); the chat node's top-level chats are workspace
//!   [`pirc_config::CHAT_WORKSPACE_ID`] "Chats".
//! - A chat session works in `<workspace>/sessions/<basename(session id)>`
//!   (created 0700 on every call); a directory workspace's sessions work in
//!   the workspace.
//! - A chat project's instructions are `<workspace>/instructions.md`, at
//!   most [`INSTRUCTIONS_MAX_CHARS`] UTF-16 units, written 0600 through a
//!   temporary file and rename; empty removes the file.

use std::fs::{DirBuilder, OpenOptions};
use std::io::Write;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

use pirc_config::{CHAT_WORKSPACE_ID, NodeConfig, POTS_WORKSPACE_ID};
use pirc_protocol::mode::{Mode, Workdir};
use rusqlite::Connection;

use crate::error::{ApiError, ApiResult};
use crate::store::{Store, Workspace};
use crate::util::{head16, hex, random_bytes};

pub const INSTRUCTIONS_FILE: &str = "instructions.md";
pub const INSTRUCTIONS_MAX_CHARS: usize = 8000;

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

/// `ensureTopLevelChats`: the top-level chat workspace, for chats outside
/// any project.
pub fn ensure_top_level_chats(config: &NodeConfig, db: &Connection) -> ApiResult<Workspace> {
    let dir = chat_workspace_dir(config, CHAT_WORKSPACE_ID)?;
    db.ensure_chat_workspace(
        CHAT_WORKSPACE_ID,
        &config.node_id,
        "Chats",
        &dir.to_string_lossy(),
        "chat",
    )
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

/// `projectInstructionsPath`: a chat workspace's instructions file.
pub fn project_instructions_path(workspace: &Workspace, mode: &Mode) -> Option<PathBuf> {
    mode.project_instructions
        .then(|| Path::new(&workspace.canonical_path).join(INSTRUCTIONS_FILE))
}

pub use pirc_config::text::trim as js_trim;

/// `readProjectInstructions`: trimmed and cut to the limit; `""` for none.
pub fn read_project_instructions(workspace: &Workspace, mode: &Mode) -> String {
    let Some(file) = project_instructions_path(workspace, mode) else {
        return String::new();
    };
    match std::fs::read(&file) {
        Ok(bytes) => head16(
            js_trim(&String::from_utf8_lossy(&bytes)),
            INSTRUCTIONS_MAX_CHARS,
        )
        .to_owned(),
        Err(_) => String::new(),
    }
}

/// `writeProjectInstructions`: the stored text (413 `payload_too_large`
/// "Instructions are limited to 8000 characters").
pub fn write_project_instructions(
    workspace: &Workspace,
    text: &str,
    mode: &Mode,
) -> ApiResult<String> {
    let Some(file) = project_instructions_path(workspace, mode) else {
        return Err(ApiError::bad_request(
            "Only chat projects have instructions",
        ));
    };
    let value = js_trim(&text.replace("\r\n", "\n")).to_owned();
    if value.encode_utf16().count() > INSTRUCTIONS_MAX_CHARS {
        return Err(ApiError::new(
            413,
            "payload_too_large",
            format!("Instructions are limited to {INSTRUCTIONS_MAX_CHARS} characters"),
        ));
    }
    if let Some(parent) = file.parent() {
        make_dir(parent)?;
    }
    if value.is_empty() {
        return match std::fs::remove_file(&file) {
            Err(error) if error.kind() != std::io::ErrorKind::NotFound => {
                Err(io_failure("removing", &file, error))
            }
            _ => Ok(String::new()),
        };
    }
    let mut temp = file.clone().into_os_string();
    temp.push(format!(".{}.tmp", hex(&random_bytes::<6>())));
    let temp = PathBuf::from(temp);
    let written = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&temp)
        .and_then(|mut out| out.write_all(format!("{value}\n").as_bytes()))
        .and_then(|()| std::fs::rename(&temp, &file));
    if let Err(error) = written {
        let _ = std::fs::remove_file(&temp);
        return Err(io_failure("writing", &file, error));
    }
    Ok(value)
}

#[cfg(test)]
mod tests {
    use serde_json::Map;

    use super::*;
    use pirc_protocol::mode::{default_chat, default_work};

    fn chat(dir: &Path) -> Workspace {
        Workspace {
            id: "p".into(),
            host_id: "n".into(),
            display_name: "P".into(),
            canonical_path: dir.to_string_lossy().into_owned(),
            defaults: Map::new(),
            mode: default_chat().id,
        }
    }

    #[test]
    fn helpers_use_passed_capabilities_not_mode_names() {
        let dir = tempfile::tempdir().unwrap();
        let mut mode = default_chat();
        mode.id = pirc_protocol::mode::ModeId::new("research").unwrap();
        let workspace = Workspace {
            mode: mode.id.clone(),
            ..chat(dir.path())
        };
        assert_eq!(
            session_root(&workspace, "s", &mode).unwrap(),
            dir.path().join("sessions/s")
        );
        assert!(project_instructions_path(&workspace, &mode).is_some());
        mode.project_instructions = false;
        assert_eq!(project_instructions_path(&workspace, &mode), None);
        mode.workdir = Workdir::Workspace;
        assert_eq!(session_root(&workspace, "s", &mode).unwrap(), dir.path());
    }

    #[test]
    fn session_roots_and_instructions() {
        let dir = tempfile::tempdir().unwrap();
        let workspace = chat(dir.path());
        let root = session_root(&workspace, "session_1", &default_chat()).unwrap();
        assert_eq!(root, dir.path().join("sessions/session_1"));
        assert!(root.is_dir());
        assert_eq!(basename("a/b/"), "b");
        let directory = Workspace {
            mode: default_work().id,
            ..workspace.clone()
        };
        assert_eq!(
            session_root(&directory, "s", &default_work()).unwrap(),
            dir.path()
        );
        assert_eq!(project_instructions_path(&directory, &default_work()), None);
        assert_eq!(read_project_instructions(&directory, &default_work()), "");
        assert_eq!(
            write_project_instructions(&directory, "x", &default_work())
                .unwrap_err()
                .status,
            400
        );

        assert_eq!(read_project_instructions(&workspace, &default_chat()), "");
        assert_eq!(
            write_project_instructions(&workspace, "  Be brief.\r\nAlways.  ", &default_chat())
                .unwrap(),
            "Be brief.\nAlways."
        );
        let file = dir.path().join(INSTRUCTIONS_FILE);
        assert_eq!(
            std::fs::read_to_string(&file).unwrap(),
            "Be brief.\nAlways.\n"
        );
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            std::fs::metadata(&file).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert_eq!(
            read_project_instructions(&workspace, &default_chat()),
            "Be brief.\nAlways."
        );
        let long = "x".repeat(INSTRUCTIONS_MAX_CHARS + 1);
        let error = write_project_instructions(&workspace, &long, &default_chat()).unwrap_err();
        assert_eq!(
            (error.status, error.message.as_str()),
            (413, "Instructions are limited to 8000 characters")
        );
        assert_eq!(
            write_project_instructions(&workspace, " \n ", &default_chat()).unwrap(),
            ""
        );
        assert!(!file.exists());
    }
}
