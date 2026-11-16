//! A test that drives the real executables must be ignored, not passed, when they
//! are not there (`build.rs`). This keeps that true for every test in `tests/`:
//! a new one without the attribute would silently "pass" on a machine without the
//! executables, which is the accounting this suite must not have.
use std::fs;
use std::path::{Path, PathBuf};

const GATE: &str =
    r#"#[cfg_attr(not(conformance_enabled), ignore = "needs PIRC_CONFORMANCE_BIN_DIR")]"#;

/// Tests that never start an executable, by file (relative to `tests/`) and name.
const SELF_CONTAINED: &[(&str, &str)] = &[
    (
        "feature_masker.rs",
        "timestamp_shaped_digits_do_not_corrupt_random_session_ids",
    ),
    (
        "feature_masker.rs",
        "timestamps_are_masked_in_script_json_but_not_inside_identifiers",
    ),
    (
        "node_panels_support/mod.rs",
        "git_diff_usage_is_stable_across_git_versions",
    ),
    (
        "node_panels_support/mod.rs",
        "git_diff_usage_preserves_authorization_and_unrelated_errors",
    ),
];

fn sources(dir: &Path, out: &mut Vec<PathBuf>) {
    for entry in fs::read_dir(dir).unwrap() {
        let path = entry.unwrap().path();
        if path.is_dir() {
            sources(&path, out);
        } else if path.extension().is_some_and(|ext| ext == "rs") {
            out.push(path);
        }
    }
}

fn is_test_attribute(line: &str) -> bool {
    let line = line.trim_start();
    line.starts_with("#[test]") || line.starts_with("#[tokio::test")
}

fn function_name(line: &str) -> Option<&str> {
    let rest = line.trim_start();
    let rest = rest.strip_prefix("pub ").unwrap_or(rest);
    let rest = rest.strip_prefix("async ").unwrap_or(rest);
    let rest = rest.strip_prefix("fn ")?;
    Some(rest.split(['(', '<']).next().unwrap_or(rest).trim())
}

#[test]
fn every_test_that_needs_the_executables_is_ignored_without_them() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests");
    let mut files = Vec::new();
    sources(&root, &mut files);
    files.sort();
    let (mut checked, mut problems) = (0, Vec::new());
    for file in files {
        let relative = file
            .strip_prefix(&root)
            .unwrap()
            .to_string_lossy()
            .into_owned();
        if relative == "gating.rs" {
            continue;
        }
        let text = fs::read_to_string(&file).unwrap();
        let lines: Vec<&str> = text.lines().collect();
        for (index, line) in lines.iter().enumerate() {
            if !is_test_attribute(line) {
                continue;
            }
            let mut start = index;
            while start > 0 && lines[start - 1].trim_start().starts_with("#[") {
                start -= 1;
            }
            let Some((end, name)) = lines[index..]
                .iter()
                .enumerate()
                .find_map(|(offset, line)| function_name(line).map(|name| (index + offset, name)))
            else {
                problems.push(format!(
                    "{relative}:{}: a test attribute without a function",
                    index + 1
                ));
                continue;
            };
            let attributes = &lines[start..end];
            let gated = attributes.iter().any(|line| line.trim() == GATE);
            let ignored = attributes
                .iter()
                .any(|line| line.trim_start().starts_with("#[ignore"));
            let self_contained = SELF_CONTAINED.contains(&(relative.as_str(), name));
            checked += 1;
            let here = format!("{relative}:{}: {name}", index + 1);
            match (gated, ignored, self_contained) {
                (true, false, false) | (false, true, false) | (false, false, true) => {}
                (false, false, false) => problems.push(format!(
                    "{here} is neither gated nor ignored: add\n    {GATE}\n  \
                     or list it in SELF_CONTAINED if it never starts an executable"
                )),
                _ => problems.push(format!(
                    "{here} has more than one of: the gate, its own #[ignore], SELF_CONTAINED"
                )),
            }
        }
    }
    assert!(problems.is_empty(), "{}", problems.join("\n"));
    // The scan found the suite (a path or parsing change must not make it vacuous).
    assert!(checked > 200, "only {checked} tests found under tests/");
}
