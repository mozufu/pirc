//! File-backed workspace-mode definitions, ready for the catalog cutover.
//!
//! Loading never creates files or supplies built-in fallbacks. Call
//! [`initialize_modes`] explicitly to seed a missing directory; an existing
//! directory is authoritative, even when empty or missing a shipped default.

use std::fmt;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};

use indexmap::IndexMap;
use pirc_protocol::mode::{Mode, ModeId};
use serde_json::{Map, Number, Value};

use crate::frontmatter::{self, yaml::Yaml};
use crate::{ConfigError, Env, default_config_dir};

/// Human-editable initial files, also suitable for printing for comparison.
/// The filename supplies the id; Markdown after front matter supplies the body.
pub const DEFAULT_MODE_FILES: &[(&str, &str)] = &[
    ("chat.md", include_str!("modes/chat.md")),
    ("directory.md", include_str!("modes/directory.md")),
    ("pot.md", include_str!("modes/pot.md")),
];

/// A skipped file and the validation or I/O rule it failed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ModeWarning {
    pub source: PathBuf,
    pub rule: String,
}

impl fmt::Display for ModeWarning {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: {}", self.source.display(), self.rule)
    }
}

/// Valid files in filename order, plus diagnostics for skipped files.
/// Callers decide how to log warnings; neither warnings nor an empty catalog
/// cause a fallback to the shipped defaults.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ModeCatalog {
    pub modes: IndexMap<ModeId, Mode>,
    pub warnings: Vec<ModeWarning>,
}

/// `$PIRC_CONFIG_DIR/modes`, with the same config-directory default as models.
pub fn default_modes_dir(env: &Env) -> PathBuf {
    default_config_dir(env).join("modes")
}

/// Parse a mode whose id is the filename stem (without `.md`).
///
/// `id` and `body` are reserved front-matter fields: accepting them would give
/// a file two sources of identity or instructions. Strict front matter rejects
/// ambiguous YAML before the shared protocol deserializer checks the schema,
/// vocabulary, bounds, and capability invariants.
pub fn parse_mode(filename_id: &str, text: &str) -> Result<Mode, String> {
    let id = ModeId::new(filename_id)?;
    let file = frontmatter::parse_strict(text)?;
    for field in ["id", "body"] {
        if file.meta.contains_key(field) {
            return Err(match field {
                "id" => "id must come from the mode filename, not front matter",
                _ => "body must come from the Markdown body, not front matter",
            }
            .to_owned());
        }
    }
    let mut fields = file
        .meta
        .into_iter()
        .map(|(name, value)| Ok((name, yaml_json(value)?)))
        .collect::<Result<Map<String, Value>, String>>()?;
    fields.insert("id".into(), Value::String(id.as_str().into()));
    fields.insert("body".into(), Value::String(file.body));
    serde_json::from_value(Value::Object(fields)).map_err(|error| error.to_string())
}

/// Convert without JavaScript's lossy coercions (notably nonfinite → null).
fn yaml_json(value: Yaml) -> Result<Value, String> {
    Ok(match value {
        Yaml::Null => Value::Null,
        Yaml::Bool(value) => Value::Bool(value),
        Yaml::Number(value) => Value::Number(
            Number::from_f64(value).ok_or("non-finite YAML numbers are not allowed in modes")?,
        ),
        Yaml::String(value) => Value::String(value),
        Yaml::Seq(values) => Value::Array(
            values
                .into_iter()
                .map(yaml_json)
                .collect::<Result<_, _>>()?,
        ),
        Yaml::Map(values) => Value::Object(
            values
                .into_iter()
                .map(|(name, value)| Ok((name, yaml_json(value)?)))
                .collect::<Result<_, String>>()?,
        ),
    })
}

/// Read `.md` files deterministically, skipping invalid or unreadable files.
///
/// A missing or unreadable directory is an error, not a request to seed or use
/// defaults. Symlinks to regular files are supported for read-only Nix configs;
/// directories and special files are refused, so a FIFO cannot block loading.
pub fn load_modes(dir: impl AsRef<Path>) -> Result<ModeCatalog, ConfigError> {
    let dir = dir.as_ref();
    let entries = fs::read_dir(dir).map_err(|error| {
        ConfigError(format!(
            "cannot read modes directory {}: {error}",
            dir.display()
        ))
    })?;
    let mut catalog = ModeCatalog::default();
    let mut paths = Vec::new();
    for entry in entries {
        match entry {
            Ok(entry) if entry.path().extension().is_some_and(|ext| ext == "md") => {
                paths.push(entry.path());
            }
            Ok(_) => {}
            Err(error) => catalog.warnings.push(ModeWarning {
                source: dir.to_owned(),
                rule: format!("cannot read directory entry: {error}"),
            }),
        }
    }
    paths.sort();
    for path in paths {
        match read_mode(&path) {
            Ok(mode) => {
                catalog.modes.insert(mode.id.clone(), mode);
            }
            Err(rule) => catalog.warnings.push(ModeWarning { source: path, rule }),
        }
    }
    Ok(catalog)
}

fn read_mode(path: &Path) -> Result<Mode, String> {
    let id = path
        .file_stem()
        .and_then(|stem| stem.to_str())
        .ok_or("mode filename must be valid UTF-8")?;
    // Validate before reading: filenames outside the id grammar never load.
    ModeId::new(id)?;
    let metadata = fs::metadata(path).map_err(|error| format!("cannot read mode file: {error}"))?;
    if !metadata.is_file() {
        return Err("mode source must be a regular file".into());
    }
    let text =
        fs::read_to_string(path).map_err(|error| format!("cannot read mode file: {error}"))?;
    parse_mode(id, &text)
}

/// Explicitly seed a missing modes directory with private default files.
///
/// Returns `true` only when this call created the directory. Never edits or
/// repopulates an existing directory, including a read-only symlinked one.
/// Existing non-directories are errors. This is deliberately not a startup hook.
///
/// If writing a default fails, the newly created directory can remain incomplete.
/// It is still authoritative: retries never silently refill it. The error names
/// the failed file; an operator must inspect the directory, then either complete
/// the desired files manually or explicitly remove the incomplete directory
/// before retrying initialization. No rollback removes potentially edited files.
pub fn initialize_modes(dir: impl AsRef<Path>) -> Result<bool, ConfigError> {
    use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};

    let dir = dir.as_ref();
    match fs::symlink_metadata(dir) {
        Ok(_) => return existing_directory(dir),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => {
            return Err(ConfigError(format!(
                "cannot inspect modes directory {}: {error}",
                dir.display()
            )));
        }
    }
    if let Some(parent) = dir.parent().filter(|parent| !parent.as_os_str().is_empty()) {
        crate::make_private_dir(parent)?;
    }
    match fs::DirBuilder::new().mode(0o700).create(dir) {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
            return existing_directory(dir);
        }
        Err(error) => {
            return Err(ConfigError(format!(
                "cannot create modes directory {}: {error}",
                dir.display()
            )));
        }
    }
    for (filename, text) in DEFAULT_MODE_FILES {
        let path = dir.join(filename);
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&path)
            .map_err(|error| initialization_error(dir, &path, "create", &error))?;
        file.write_all(text.as_bytes())
            .map_err(|error| initialization_error(dir, &path, "write", &error))?;
    }
    Ok(true)
}

fn initialization_error(
    dir: &Path,
    path: &Path,
    action: &str,
    error: &std::io::Error,
) -> ConfigError {
    ConfigError(format!(
        "cannot {action} mode file {}: {error}; newly created modes directory {} may be incomplete and will not be reseeded automatically; inspect it and either complete the desired files manually or explicitly remove the incomplete directory before retrying initialization",
        path.display(),
        dir.display()
    ))
}

fn existing_directory(dir: &Path) -> Result<bool, ConfigError> {
    if dir.is_dir() {
        Ok(false)
    } else {
        Err(ConfigError(format!(
            "modes path {} is not a directory",
            dir.display()
        )))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use pirc_protocol::mode::{PromptSection, default_chat, default_work};
    use std::os::unix::fs::{PermissionsExt, symlink};

    const CHAT_FILE: &str = include_str!("modes/chat.md");
    const WORK_FILE: &str = include_str!("modes/directory.md");

    fn ids(catalog: &ModeCatalog) -> Vec<&str> {
        catalog.modes.keys().map(ModeId::as_str).collect()
    }

    #[test]
    fn default_markdown_matches_protocol_defaults_exactly() {
        assert_eq!(parse_mode("chat", CHAT_FILE).unwrap(), default_chat());
        assert_eq!(parse_mode("directory", WORK_FILE).unwrap(), default_work());
    }

    #[test]
    fn filename_is_authoritative_and_body_is_markdown() {
        let mode = parse_mode("research", &format!("{CHAT_FILE}\n  Study carefully.\n")).unwrap();
        assert_eq!(mode.id.as_str(), "research");
        assert_eq!(mode.body, "Study carefully.");
        assert!(mode.prompt.contains(&PromptSection::Body));
        for id in ["", "../chat", "chat.md", "Upper", "1first", "a/b"] {
            assert!(
                parse_mode(id, CHAT_FILE)
                    .unwrap_err()
                    .contains("invalid mode id")
            );
        }
        for (field, rule) in [
            ("id: chat", "id must come from the mode filename"),
            ("id: different", "id must come from the mode filename"),
            (
                "body: Hidden instructions",
                "body must come from the Markdown body",
            ),
        ] {
            let text = CHAT_FILE.replacen("---\n", &format!("---\n{field}\n"), 1);
            assert!(parse_mode("chat", &text).unwrap_err().contains(rule));
        }
    }

    #[test]
    fn rejects_malformed_ambiguous_and_schema_invalid_modes() {
        for text in [
            "plain Markdown",
            "---\nlabel: Chat",
            "---\n- list\n---\n",
            "---\nscalar\n---\n",
            "---\nlabel: [\n---\n",
            "---\nlabel: A\nlabel: B\n---\n",
            "---\nui: {noun: chat, noun: work}\n---\n",
            "---\n123: wrong-key\n---\n",
        ] {
            assert!(parse_mode("chat", text).is_err(), "{text:?}");
        }
        for (from, to, rule) in [
            ("assistant: user", "assistant: full", "assistant: full"),
            (
                "features_on: []",
                "features_on: [notAFeature]",
                "unknown features_on",
            ),
            (
                "features_on: []",
                "features_on: [autoMode]",
                "unknown features_on",
            ),
            ("tools: null", "tools: [imaginary]", "unknown tools"),
            ("label: Work", "label: .inf", "non-finite"),
            ("label: Work", "label: 12", "string"),
            (
                "noun: session",
                "noun: session\n  typo: false",
                "unknown field",
            ),
            (
                "features_on: []",
                "features_on: []\ntypo: true",
                "unknown field",
            ),
        ] {
            let text = WORK_FILE.replace(from, to);
            let error = parse_mode("directory", &text).unwrap_err();
            assert!(error.contains(rule), "{error} should contain {rule}");
        }
        let without_body = CHAT_FILE.replace("  - body\n", "");
        assert!(
            parse_mode("chat", &format!("{without_body}Instructions"))
                .unwrap_err()
                .contains("body prompt section")
        );
        assert!(
            parse_mode("chat", &format!("{CHAT_FILE}{}", "x".repeat(8001)))
                .unwrap_err()
                .contains("body")
        );
    }

    #[test]
    fn catalog_sorts_files_skips_bad_ones_and_reports_source_and_rule() {
        let root = tempfile::tempdir().unwrap();
        let dir = root.path();
        fs::write(dir.join("zeta.md"), CHAT_FILE).unwrap();
        fs::write(dir.join("alpha.md"), WORK_FILE).unwrap();
        fs::write(dir.join("invalid.md"), "---\nlabel: [\n---\n").unwrap();
        fs::write(
            dir.join("unknown.md"),
            WORK_FILE.replace("tools: null", "tools: [not_real]"),
        )
        .unwrap();
        fs::write(dir.join("Upper.md"), CHAT_FILE).unwrap();
        fs::write(dir.join("bad-utf8.md"), [0xff]).unwrap();
        fs::write(dir.join("ignored.txt"), "ignored").unwrap();
        fs::create_dir(dir.join("not-a-file.md")).unwrap();
        let catalog = load_modes(dir).unwrap();
        assert_eq!(ids(&catalog), ["alpha", "zeta"]);
        assert_eq!(catalog.warnings.len(), 5);
        for (filename, rule) in [
            ("Upper.md", "invalid mode id"),
            ("bad-utf8.md", "cannot read mode file"),
            ("invalid.md", "YAML"),
            ("not-a-file.md", "regular file"),
            ("unknown.md", "unknown tools"),
        ] {
            let warning = catalog
                .warnings
                .iter()
                .find(|warning| warning.source == dir.join(filename))
                .unwrap();
            assert!(warning.rule.contains(rule), "{warning}");
            assert!(warning.to_string().contains(filename));
        }
    }

    #[test]
    fn missing_directory_is_not_seeded_by_loading() {
        let root = tempfile::tempdir().unwrap();
        let dir = root.path().join("modes");
        let error = load_modes(&dir).unwrap_err();
        assert!(error.to_string().contains(dir.to_str().unwrap()));
        assert!(!dir.exists());
    }

    #[test]
    fn initializer_creates_private_parseable_defaults_once() {
        let root = tempfile::tempdir().unwrap();
        let dir = root.path().join("config/modes");
        assert!(initialize_modes(&dir).unwrap());
        let catalog = load_modes(&dir).unwrap();
        assert!(catalog.warnings.is_empty());
        assert_eq!(ids(&catalog), ["chat", "directory", "pot"]);
        assert!(catalog.modes[&ModeId::new("pot").unwrap()].pot);
        assert_eq!(catalog.modes[&ModeId::new("chat").unwrap()], default_chat());
        assert_eq!(
            catalog.modes[&ModeId::new("directory").unwrap()],
            default_work()
        );
        assert_eq!(
            fs::metadata(&dir).unwrap().permissions().mode() & 0o777,
            0o700
        );
        for (filename, text) in DEFAULT_MODE_FILES {
            let path = dir.join(filename);
            assert_eq!(fs::read_to_string(&path).unwrap(), *text);
            assert_eq!(
                fs::metadata(path).unwrap().permissions().mode() & 0o777,
                0o600
            );
        }
        assert!(!initialize_modes(&dir).unwrap());
    }

    #[test]
    fn edited_and_deleted_defaults_are_never_restored() {
        let root = tempfile::tempdir().unwrap();
        let dir = root.path().join("modes");
        initialize_modes(&dir).unwrap();
        let changed = CHAT_FILE.replace("label: Chat", "label: Research");
        fs::write(dir.join("chat.md"), &changed).unwrap();
        fs::remove_file(dir.join("directory.md")).unwrap();
        assert!(!initialize_modes(&dir).unwrap());
        assert_eq!(fs::read_to_string(dir.join("chat.md")).unwrap(), changed);
        assert!(!dir.join("directory.md").exists());
        let catalog = load_modes(&dir).unwrap();
        assert_eq!(ids(&catalog), ["chat", "pot"]);
        assert_eq!(catalog.modes.values().next().unwrap().label, "Research");
    }

    #[test]
    fn existing_empty_directory_is_authoritative_even_read_only() {
        let root = tempfile::tempdir().unwrap();
        let dir = root.path().join("modes");
        fs::create_dir(&dir).unwrap();
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o500)).unwrap();
        assert!(!initialize_modes(&dir).unwrap());
        let catalog = load_modes(&dir).unwrap();
        assert!(catalog.modes.is_empty());
        assert!(catalog.warnings.is_empty());
        assert_eq!(fs::read_dir(&dir).unwrap().count(), 0);
        fs::set_permissions(dir, fs::Permissions::from_mode(0o700)).unwrap();
    }

    #[test]
    fn accepts_read_only_symlink_files_and_directories_without_seeding() {
        let root = tempfile::tempdir().unwrap();
        let store = root.path().join("store");
        fs::create_dir(&store).unwrap();
        let source = root.path().join("source.md");
        fs::write(&source, CHAT_FILE).unwrap();
        fs::set_permissions(&source, fs::Permissions::from_mode(0o400)).unwrap();
        symlink(&source, store.join("research.md")).unwrap();
        symlink(root.path().join("missing.md"), store.join("missing.md")).unwrap();
        let dir = root.path().join("modes");
        symlink(&store, &dir).unwrap();
        assert!(!initialize_modes(&dir).unwrap());
        let catalog = load_modes(&dir).unwrap();
        assert_eq!(ids(&catalog), ["research"]);
        assert_eq!(catalog.warnings.len(), 1);
        assert_eq!(catalog.warnings[0].source, dir.join("missing.md"));
        assert!(!store.join("chat.md").exists());
    }

    #[test]
    fn initializer_refuses_existing_non_directory_without_overwriting() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("modes");
        fs::write(&path, "keep").unwrap();
        assert!(
            initialize_modes(&path)
                .unwrap_err()
                .to_string()
                .contains("not a directory")
        );
        assert_eq!(fs::read_to_string(&path).unwrap(), "keep");
    }

    #[test]
    fn default_path_uses_config_directory_override() {
        assert_eq!(
            default_modes_dir(&Env::new([("HOME", "/home/test")], "/work")),
            PathBuf::from("/home/test/.config/.pirc/modes")
        );
        assert_eq!(
            default_modes_dir(&Env::new([("PIRC_CONFIG_DIR", "/etc/pirc")], "/work")),
            PathBuf::from("/etc/pirc/modes")
        );
    }
}
