//! `node-recap.test.ts`, on the node's own store (the gateway-table case,
//! "scheduled and delegated background sessions are not sampled", is gone
//! with those tables; its node-local half is kept).

use std::os::unix::fs::symlink;

use super::*;
use crate::store::Db;
use crate::util::uuid;

struct Fixture {
    _dir: tempfile::TempDir,
    root: PathBuf,
    db: Db,
    current: String,
    stamp: i64,
}

impl Fixture {
    fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        let db = Db::memory();
        let fixture = Self {
            _dir: dir,
            root: root.clone(),
            db,
            current: String::new(),
            stamp: now_ms() - 1000,
        };
        fixture.workspace("w", &root);
        let current = fixture.row("w", &root.join("current"), Some("alice"));
        Self { current, ..fixture }
    }

    fn workspace(&self, id: &str, path: &Path) {
        self.db
            .lock()
            .execute(
                "INSERT INTO workspaces (id, host_id, display_name, canonical_path, defaults_json,
                 created_at) VALUES (?, 'node', ?, ?, '{}', 0)",
                rusqlite::params![id, id, path.to_str().unwrap()],
            )
            .unwrap();
    }

    fn row(&self, workspace: &str, dir: &Path, owner: Option<&str>) -> String {
        let id = format!("session_{}", uuid());
        self.db
            .lock()
            .execute(
                "INSERT INTO sessions (id, workspace_id, private_session_path, name, owner_user,
                 created_at, updated_at) VALUES (?, ?, ?, 'New session', ?, ?, ?)",
                rusqlite::params![
                    id,
                    workspace,
                    dir.to_str().unwrap(),
                    owner,
                    now_ms(),
                    now_ms()
                ],
            )
            .unwrap();
        id
    }

    /// A session of `owner` with these entries after a header in `cwd`.
    fn session_in(
        &self,
        entries: Vec<Value>,
        owner: Option<&str>,
        workspace: &str,
        cwd: &Path,
    ) -> (String, PathBuf) {
        let dir = self.root.join(format!("s-{}", uuid()));
        std::fs::create_dir(&dir).unwrap();
        let id = self.row(workspace, &dir, owner);
        let mut all = vec![json!({ "type": "session", "version": 1,
            "cwd": cwd.to_str().unwrap(), "sessionId": "private-id" })];
        all.extend(entries);
        let lines: Vec<String> = all
            .into_iter()
            .enumerate()
            .map(|(index, entry)| {
                let mut line = json!({
                    "id": format!("e{index}"),
                    "parentId": if index > 0 { json!(format!("e{}", index - 1)) } else { Value::Null },
                    "timestamp": self.stamp,
                });
                line.as_object_mut()
                    .unwrap()
                    .extend(entry.as_object().unwrap().clone());
                line.to_string()
            })
            .collect();
        std::fs::write(dir.join("session.jsonl"), lines.join("\n") + "\n").unwrap();
        (id, dir)
    }

    fn session(&self, entries: Vec<Value>) -> (String, PathBuf) {
        self.session_in(entries, Some("alice"), "w", &self.root)
    }

    fn collect(&self, args: Value) -> ApiResult<Value> {
        let scope = scope(&self.db.lock(), &self.current, &args, now_ms())?;
        Ok(scope.collect())
    }
}

fn user(text: &str) -> Value {
    json!({ "type": "message", "message": { "role": "user", "content": text } })
}

fn with(mut entry: Value, extra: Value) -> Value {
    entry
        .as_object_mut()
        .unwrap()
        .extend(extra.as_object().unwrap().clone());
    entry
}

fn ids(result: &Value) -> Vec<String> {
    result["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .map(|session| session["sessionId"].as_str().unwrap().to_owned())
        .collect()
}

fn reasons(result: &Value) -> Vec<String> {
    result["skipped"]
        .as_array()
        .unwrap()
        .iter()
        .map(|skip| skip["reason"].as_str().unwrap().to_owned())
        .collect()
}

#[test]
fn strict_bound_arguments_and_fail_closed_owner_and_workspace_kind() {
    let fixture = Fixture::new();
    let root = fixture.root.to_str().unwrap();
    for args in [
        json!({ "days": 0 }),
        json!({ "days": 91 }),
        json!({ "days": 1.5 }),
        json!({ "days": "14" }),
        json!({ "path": root }),
        json!({ "sessionId": fixture.current }),
        Value::Null,
    ] {
        assert!(fixture.collect(args).is_err());
    }
    assert!(fixture.collect(json!({ "days": 2.0 })).is_ok());
    fixture
        .db
        .lock()
        .execute(
            "UPDATE sessions SET owner_user = NULL WHERE id = ?",
            [&fixture.current],
        )
        .unwrap();
    let error = fixture.collect(json!({})).unwrap_err();
    assert!(error.message.contains("known session owner"), "{error}");
    fixture
        .db
        .lock()
        .execute(
            "UPDATE sessions SET owner_user = 'alice' WHERE id = ?",
            [&fixture.current],
        )
        .unwrap();
    fixture
        .db
        .lock()
        .execute("UPDATE workspaces SET kind = 'chat'", [])
        .unwrap();
    let error = fixture.collect(json!({})).unwrap_err();
    assert!(error.message.contains("directory workspace"), "{error}");
}

#[test]
fn only_owned_exact_workspace_and_exact_cwd_current_excluded() {
    let fixture = Fixture::new();
    let (good, _) = fixture.session(vec![user("human requirement")]);
    fixture.session_in(vec![user("foreign-owner")], Some("bob"), "w", &fixture.root);
    fixture.session_in(vec![user("unknown-owner")], None, "w", &fixture.root);
    fixture.workspace("other", &fixture.root.join("worktree"));
    fixture.session_in(
        vec![user("other-worktree")],
        Some("alice"),
        "other",
        &fixture.root,
    );
    fixture.session_in(
        vec![user("wrong-header")],
        Some("alice"),
        "w",
        &fixture.root.join("nested"),
    );
    let result = fixture.collect(json!({})).unwrap();
    assert_eq!(ids(&result), [good]);
    assert_eq!(result["scope"]["days"], 14);
    assert_eq!(reasons(&result)[0], "workspace_header_mismatch");
}

#[test]
fn only_text_and_safe_tool_metadata_secrets_redacted_timestamps_bounded() {
    let fixture = Fixture::new();
    let stamp = fixture.stamp;
    fixture.session(vec![
        user("human sk-abcdefghijklmnopqrstuvwxyz"),
        with(user("too old"), json!({ "timestamp": stamp - 20 * DAY_MS })),
        with(user("future"), json!({ "timestamp": stamp + DAY_MS })),
        json!({ "type": "message", "message": { "role": "assistant", "content": [
            { "type": "text", "text": "answer" },
            { "type": "thinking", "thinking": "PRIVATE_THINKING" },
            { "type": "toolCall", "name": "bash", "arguments": { "command": "PRIVATE_ARGS" } },
        ] } }),
        json!({ "type": "message", "message": { "role": "toolResult", "toolName": "bash",
            "content": "PRIVATE_RESULT", "isError": true } }),
        json!({ "type": "custom", "customType": "ptc.operation", "data": { "toolName": "read",
            "args": "PRIVATE_PTC_ARGS", "content": "PRIVATE_PTC_RESULT", "isError": true } }),
        json!({ "type": "custom", "customType": "memory", "data": "PRIVATE_MEMORY" }),
    ]);
    let result = fixture.collect(json!({})).unwrap();
    let text = result.to_string();
    for absent in [
        "PRIVATE_",
        "abcdefghijklmnopqrstuvwxyz",
        "too old",
        "future",
    ] {
        assert!(!text.contains(absent), "{absent} in {text}");
    }
    let evidence = result["sessions"][0]["evidence"].as_array().unwrap();
    assert_eq!(evidence[0]["role"], "user");
    assert!(
        evidence
            .iter()
            .any(|e| e["toolName"] == "read" && e["isError"] == true)
    );
    assert!(
        evidence
            .iter()
            .all(|e| e["entryId"].is_string() && e["timestamp"] == stamp)
    );
}

#[test]
fn excludes_entire_recap_marked_sessions_even_markers_off_active_branch() {
    let fixture = Fixture::new();
    fixture.session(vec![
        user("original"),
        json!({ "type": "custom", "customType": "recap.run", "data": {} }),
        with(user("after"), json!({ "parentId": "e1" })),
    ]);
    fixture.session(vec![
        user("original"),
        json!({ "type": "message", "message": { "role": "custom",
            "customType": "recap.report", "content": "report" } }),
    ]);
    let result = fixture.collect(json!({})).unwrap();
    assert!(ids(&result).is_empty());
    assert_eq!(
        reasons(&result),
        ["recap_marked_session", "recap_marked_session"]
    );
}

#[test]
fn rejects_cycles_malformed_entries_and_detached_branches() {
    let fixture = Fixture::new();
    fixture.session(vec![
        user("cycle"),
        with(user("cycle"), json!({ "parentId": "e2" })),
    ]);
    fixture.session(vec![with(user("broken"), json!({ "parentId": "missing" }))]);
    fixture.session(vec![with(user("invalid"), json!({ "timestamp": "bad" }))]);
    let (good, _) = fixture.session(vec![
        user("abandoned"),
        with(user("active"), json!({ "parentId": "e0" })),
    ]);
    let result = fixture.collect(json!({})).unwrap();
    assert_eq!(ids(&result), [good]);
    assert!(!result.to_string().contains("abandoned"));
    let mut reasons = reasons(&result);
    reasons.sort();
    assert_eq!(
        reasons,
        ["branch_cycle", "broken_branch", "invalid_entries"]
    );
}

#[test]
fn rejects_symlink_files_and_directories_and_skips_huge_files_without_reading() {
    let fixture = Fixture::new();
    let (target, target_dir) = fixture.session(vec![user("target")]);
    let (_, linked_dir) = fixture.session(vec![user("linked")]);
    std::fs::remove_file(linked_dir.join("session.jsonl")).unwrap();
    symlink(
        target_dir.join("session.jsonl"),
        linked_dir.join("session.jsonl"),
    )
    .unwrap();
    let linked = fixture.root.join("linked-dir");
    symlink(&target_dir, &linked).unwrap();
    fixture.row("w", &linked, Some("alice"));
    let (_, huge) = fixture.session(Vec::new());
    std::fs::write(huge.join("session.jsonl"), "x".repeat(4 * 1024 * 1024 + 1)).unwrap();
    let result = fixture.collect(json!({})).unwrap();
    assert_eq!(ids(&result), [target]);
    let reasons = reasons(&result);
    assert_eq!(reasons.iter().filter(|r| *r == "unsafe_path").count(), 2);
    assert!(reasons.iter().any(|r| r == "file_byte_limit"));
    assert!(result["scannedBytes"].as_u64().unwrap() < 1000);
}

#[test]
fn node_local_background_markers_exclude_entire_sessions() {
    let fixture = Fixture::new();
    let custom_type = "scheduled-run";
    fixture.session(vec![
        user("before background marker"),
        json!({ "type": "message", "message": { "role": "custom", "customType": custom_type,
            "content": "background task" } }),
        with(user("off-marker branch"), json!({ "parentId": "e1" })),
    ]);
    fixture.session(vec![
        user("before"),
        json!({ "type": "custom", "customType": custom_type, "data": {} }),
        user("after"),
    ]);
    let result = fixture.collect(json!({})).unwrap();
    assert!(ids(&result).is_empty());
    assert_eq!(reasons(&result), vec!["background_session"; 2]);
}

#[test]
fn aggregate_scan_budget_is_bounded_and_omitted_sessions_are_disclosed() {
    let fixture = Fixture::new();
    for _ in 0..10 {
        fixture.session(vec![user(&"x".repeat(3_900_000))]);
    }
    let result = fixture.collect(json!({})).unwrap();
    assert!(result["scannedBytes"].as_u64().unwrap() <= 32 * 1024 * 1024);
    assert!(reasons(&result).iter().any(|r| r == "scan_byte_limit"));
    assert_eq!(result["truncated"], true);
}

#[test]
fn caps_session_count_and_serialized_output_and_prioritizes_human_evidence() {
    let fixture = Fixture::new();
    for _ in 0..22 {
        let mut entries: Vec<Value> = (0..15)
            .map(|_| {
                json!({ "type": "message", "message": { "role": "assistant",
                    "content": "a".repeat(3000) } })
            })
            .collect();
        entries.push(user("human first"));
        entries.push(user(&"b".repeat(6000)));
        fixture.session(entries);
    }
    let result = fixture.collect(json!({})).unwrap();
    let sessions = result["sessions"].as_array().unwrap();
    assert!(sessions.len() <= 20);
    assert_eq!(result["truncated"], true);
    assert!(utf16_len(&stringify(&result)) <= 80_000);
    for session in sessions {
        assert!(utf16_len(&stringify(session)) <= 5000);
        assert_eq!(session["evidence"][0]["role"], "user");
        assert!(
            session["evidence"]
                .as_array()
                .unwrap()
                .iter()
                .any(|e| e["text"] == "human first")
        );
    }
}

#[test]
fn sampled_sessions_match_a_recomputed_length() {
    // The running sum equals JSON.stringify(session).length.
    let candidates: Vec<Source> = (0..40)
        .map(|index| {
            let mut value = Map::new();
            value.insert("entryId".into(), json!(format!("e{index}")));
            value.insert("timestamp".into(), json!(index));
            value.insert("role".into(), json!("assistant"));
            value.insert("text".into(), json!("é😀".repeat(index * 20)));
            Source {
                user: false,
                timestamp: index as f64,
                value,
            }
        })
        .collect();
    let session = sample("s", candidates);
    let length = utf16_len(&stringify(&session));
    assert!(length <= 5000, "{length}");
    assert!(length > 4000, "{length}");
}

// runner.ts: anything collectRecap threw that was not an ApiError.
#[test]
fn store_failures_are_recap_failed() {
    let fixture = Fixture::new();
    fixture
        .db
        .lock()
        .execute_batch("ALTER TABLE sessions RENAME TO sessions_gone")
        .unwrap();
    let error = fixture.collect(json!({})).unwrap_err();
    assert_eq!(
        (error.status, &*error.code, &*error.message),
        (
            500,
            "recap_failed",
            "Could not collect workspace recap evidence"
        )
    );
}
