//! Golden cases: `apps/gateway/test/memory-mirror.test.ts`.

use std::cell::{Cell, RefCell};
use std::path::PathBuf;

use super::*;
use crate::store::Db;

const KEY: &str = "cccccccccccccccc";

struct Setup {
    _root: tempfile::TempDir,
    dir: PathBuf,
    file: PathBuf,
    session_dir: String,
    session_id: String,
    db: Db,
    frames: RefCell<Vec<Value>>,
    refuse: Cell<bool>,
    state: RefCell<State>,
}

fn setup() -> Setup {
    let root = tempfile::tempdir().unwrap();
    let base = root.path().canonicalize().unwrap();
    let dir = base.join("workspace-memory");
    std::fs::create_dir(&dir).unwrap();
    let db = Db::memory();
    let session_dir = base.join("sessions/pi_one").display().to_string();
    db.lock()
        .execute_batch(&format!(
            "INSERT INTO workspaces (id, host_id, display_name, canonical_path, defaults_json, created_at)
             VALUES ('test', 'node', 'Test', '{}', '{{}}', 1);
             INSERT INTO sessions (id, workspace_id, private_session_path, name, owner_user, created_at, updated_at)
             VALUES ('session_1', 'test', '{session_dir}', 'New session', 'me@example.com', 1, 1);",
            base.display()
        ))
        .unwrap();
    Setup {
        _root: root,
        file: dir.join(format!("{KEY}.jsonl")),
        dir,
        session_dir,
        session_id: "session_1".to_owned(),
        db,
        frames: RefCell::new(Vec::new()),
        refuse: Cell::new(false),
        state: RefCell::new(State::default()),
    }
}

impl Setup {
    fn with<T>(&self, work: impl FnOnce(&mut State, &Io<'_>) -> T) -> T {
        let send = |message: &NodeMessage| {
            if self.refuse.get() {
                return false;
            }
            self.frames
                .borrow_mut()
                .push(serde_json::to_value(message).unwrap());
            true
        };
        let lookup = |dir: &str| -> Option<String> {
            self.db
                .lock()
                .query_row(
                    "SELECT id FROM sessions WHERE private_session_path=?",
                    [dir],
                    |row| row.get(0),
                )
                .optional()
                .unwrap()
        };
        let io = Io {
            dir: &self.dir,
            send: &send,
            lookup: &lookup,
        };
        work(&mut self.state.borrow_mut(), &io)
    }

    /// `mirror.connect(send, watermarks)`, without the timer.
    fn connect(&self, watermarks: &[(&str, u64)]) {
        self.with(|state, io| {
            state.resume(
                watermarks
                    .iter()
                    .map(|(key, at)| ((*key).to_owned(), *at))
                    .collect(),
            );
            state.scan(io);
        });
    }

    fn scan(&self) {
        self.with(|state, io| state.scan(io));
    }

    fn receive(&self, watermark: u64) {
        self.with(|state, io| state.receive(io, KEY, watermark, None));
    }

    fn frames(&self) -> Vec<Value> {
        self.frames.borrow().clone()
    }
}

fn item(content: &str, dir: &str) -> Value {
    json!({"id":pirc_agent::features::memory::workspace::hash_id(content),"content":content,"relevance":"high","timestamp":"2026-10-22 10:00","sessionId":"agent-internal-id","sessionDir":dir,"sourceMemoryIds":[],"tokenCount":10})
}
fn line(value: Value) -> String {
    format!("{value}\n")
}
fn append(file: &Path, text: &str) {
    use std::io::Write;
    std::fs::OpenOptions::new()
        .append(true)
        .open(file)
        .unwrap()
        .write_all(text.as_bytes())
        .unwrap();
}
#[test]
fn mirrors_public_projection_and_integrity_in_one_frame() {
    let s = setup();
    let first = line(json!({"type":"recorded","at":1,"items":[item("Knowledge",&s.session_dir)]}));
    std::fs::write(&s.file, &first).unwrap();
    s.connect(&[]);
    let frames = s.frames();
    assert_eq!(frames.len(), 1);
    assert_eq!(frames[0]["lines"][0]["items"][0]["sessionId"], s.session_id);
    assert_eq!(
        frames[0]["lines"][1]["digest"],
        pirc_agent::journal::digest(first.as_bytes())
    );
    let text = frames[0].to_string();
    assert!(!text.contains(&s.session_dir));
    s.receive(first.len() as u64);
    assert_eq!(s.frames().len(), 1);
    append(&s.file, "{\"type\":");
    s.scan();
    assert_eq!(s.frames().len(), 1);
}
#[test]
fn resumes_with_checkpoint_and_never_resets_a_shrunken_ledger() {
    let s = setup();
    let raw = line(json!({"type":"recorded","at":1,"items":[item("Before",&s.session_dir)]}));
    std::fs::write(&s.file, &raw).unwrap();
    s.connect(&[(KEY, raw.len() as u64)]);
    let frame = s.frames()[0].clone();
    assert_eq!(frame["offset"], raw.len());
    assert_eq!(frame["end"], raw.len());
    assert_eq!(frame["lines"][0]["type"], "integrity");
    s.receive(raw.len() as u64);
    std::fs::write(&s.file, "").unwrap();
    s.scan();
    assert_eq!(s.frames().len(), 1);
    std::fs::write(&s.file, &raw).unwrap();
    append(&s.file, &line(json!({"type":"cleared","at":2})));
    s.refuse.set(true);
    s.scan();
    s.refuse.set(false);
    s.scan();
    assert_eq!(s.frames().len(), 2);
    assert_eq!(s.frames()[1]["lines"][0]["type"], "cleared");
    assert!(s.frames()[1].get("reset").is_none());
}
#[test]
fn a_complete_v2_clear_and_its_checkpoint_share_one_frame() {
    let s = setup();
    let mut cold = pirc_agent::workspace_journal::frame(&Default::default(), "cold");
    cold.cutover = Some(vec![]);
    let first = line(serde_json::to_value(&cold).unwrap());
    let initial = pirc_agent::workspace_journal::parse(first.as_bytes()).unwrap();
    let mut clear = pirc_agent::workspace_journal::frame(&initial, "clear");
    clear.clear = true;
    clear.generation = "new".into();
    clear.clear_cutoffs = Some(vec![]);
    std::fs::write(
        &s.file,
        format!("{}{}", first, line(serde_json::to_value(clear).unwrap())),
    )
    .unwrap();
    s.connect(&[]);
    let frames = s.frames();
    assert_eq!(frames.len(), 1);
    assert_eq!(frames[0]["lines"][0]["type"], "cleared");
    assert_eq!(frames[0]["lines"][1]["type"], "integrity");
}
#[test]
fn refuses_corruption_and_malformed_additions_instead_of_mirroring_retirements() {
    let s = setup();
    std::fs::write(&s.file, line(json!({"type":"recorded","items":[{"id":1}]}))).unwrap();
    s.connect(&[]);
    assert!(s.frames().is_empty());
    std::fs::write(&s.file, "{}\ninvalid\n{\"type\":\"cleared\"}\n").unwrap();
    s.scan();
    assert!(s.frames().is_empty());
}
#[test]
fn does_not_mirror_private_files_or_recurse() {
    let s = setup();
    std::fs::write(s.dir.join("context.json"), "private").unwrap();
    std::fs::create_dir(s.dir.join("nested")).unwrap();
    std::fs::write(s.dir.join("nested/cccccccccccccccc.jsonl"), "private").unwrap();
    s.connect(&[]);
    assert!(s.frames().is_empty());
}

#[test]
fn revocations_beyond_a_chunk_coalesce_to_a_complete_checkpoint_and_survive_reconnect() {
    for clear in [false, true] {
        let s = setup();
        let mut cold = pirc_agent::workspace_journal::frame(&Default::default(), "cold");
        cold.cutover = Some(vec![]);
        let prefix = line(serde_json::to_value(cold).unwrap());
        let state = pirc_agent::workspace_journal::parse(prefix.as_bytes()).unwrap();
        let mut add = pirc_agent::workspace_journal::frame(&state, "add");
        add.add = (0..20)
            .map(|i| item(&format!("{i:02}{}", "x".repeat(18000)), &s.session_dir))
            .collect();
        let tail = line(serde_json::to_value(&add).unwrap());
        assert!(tail.len() > MIRROR_CHUNK_BYTES);
        let state =
            pirc_agent::workspace_journal::parse(format!("{prefix}{tail}").as_bytes()).unwrap();
        let mut revoke = pirc_agent::workspace_journal::frame(&state, "revoke");
        let forgotten = add.add[0]["id"].as_str().unwrap();
        if clear {
            revoke.clear = true;
            revoke.generation = "cleared".into();
            revoke.clear_cutoffs = Some(vec![]);
        } else {
            revoke.forget.push(forgotten.into());
        }
        let raw = format!(
            "{prefix}{tail}{}",
            line(serde_json::to_value(revoke).unwrap())
        );
        std::fs::write(&s.file, &raw).unwrap();
        s.connect(&[(KEY, prefix.len() as u64)]);
        let frames = s.frames();
        assert_eq!(frames.len(), 1);
        let frame = &frames[0];
        assert_eq!(frame["offset"], prefix.len());
        assert_eq!(frame["end"], raw.len());
        assert_eq!(
            frame["lines"].as_array().unwrap().last().unwrap()["digest"],
            pirc_agent::journal::digest(raw.as_bytes())
        );
        let projected = frame["lines"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|v| v["type"] != "integrity")
            .map(|v| format!("{v}\n"))
            .collect::<String>();
        assert_eq!(
            pirc_agent::workspace_journal::projection(raw.as_bytes()).unwrap(),
            pirc_agent::workspace_journal::projection(format!("{prefix}{projected}").as_bytes())
                .unwrap()
        );
        let public = frame["lines"].to_string();
        assert!(!public.contains(&s.session_dir));
        assert!(!public.contains(add.add[0]["content"].as_str().unwrap()));
        if clear {
            assert_eq!(frame["lines"][0]["type"], "cleared");
        } else {
            assert!(frame["lines"].as_array().unwrap().iter().any(|l| {
                l["reason"] == "forgotten"
                    && l["ids"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .any(|id| id == forgotten)
            }));
        }
        // Reconnect before ACK reconstructs exactly the same logical changes and checkpoint.
        s.connect(&[(KEY, prefix.len() as u64)]);
        assert_eq!(s.frames()[1], frames[0]);
        s.receive(raw.len() as u64);
        assert_eq!(s.frames().len(), 2);
    }
}
#[test]
fn coalesced_projection_preserves_tombstones_across_clear_and_retire_before_record() {
    let s = setup();
    let old = item("old", &s.session_dir);
    let next = item("new", &s.session_dir);
    let prefix = line(json!({"type":"recorded","at":1,"items":[old.clone()]}));
    let tail = format!(
        "{}{}{}{}{}",
        line(json!({"type":"retired","at":2,"reason":"forgotten","ids":[old["id"]]})),
        line(json!({"type":"cleared","at":3})),
        line(json!({"type":"retired","at":4,"reason":"superseded","ids":[next["id"]]})),
        line(json!({"type":"recorded","at":5,"items":[next.clone()]})),
        line(json!({"type":"recorded","at":6,"items":[old]}))
    );
    let compacted = coalesce(&prefix, &tail);
    let encoded = compacted
        .iter()
        .map(|l| s.with(|state, io| state.convert(io, l)))
        .collect::<Vec<_>>();
    assert_eq!(encoded[0]["type"], "cleared");
    assert_eq!(encoded[1]["items"][0]["content"], "new");
    assert_eq!(encoded[2]["reason"], "forgotten");
    assert!(!encoded.iter().any(|l| l["reason"] == "superseded"));
}

#[test]
fn oversized_later_revocation_does_not_hide_an_earlier_clear_checkpoint() {
    use pirc_agent::workspace_journal::{Snapshot, frame};
    let s = setup();
    let mut raw = String::new();
    // An acknowledged legacy prefix, then a valid explicit v2 cutover.
    for n in 0..12 {
        let notes: Vec<_> = (0..100)
            .map(|i| {
                item(
                    &format!("old-{n}-{i}-{}", "x".repeat(18000)),
                    &s.session_dir,
                )
            })
            .collect();
        raw.push_str(&line(json!({"type":"recorded","at":1,"items":notes})));
    }
    let mut state = Snapshot::default();
    let mut cold = frame(&state, "cold");
    cold.cutover = Some(vec![]);
    raw.push_str(&line(serde_json::to_value(&cold).unwrap()));
    state.control = Some(cold);
    let from = raw.len();
    let mut add = frame(&state, "blocked_add");
    add.add = (0..20)
        .map(|i| {
            item(
                &format!("blocked-{i}-{}", "x".repeat(18000)),
                &s.session_dir,
            )
        })
        .collect();
    let blocked = line(serde_json::to_value(&add).unwrap());
    assert!(blocked.len() > MIRROR_CHUNK_BYTES);
    raw.push_str(&blocked);
    state.control = Some(add);
    let mut clear = frame(&state, "clear");
    clear.clear = true;
    clear.generation = "after_clear".into();
    clear.clear_cutoffs = Some(vec![]);
    raw.push_str(&line(serde_json::to_value(&clear).unwrap()));
    state.control = Some(clear);
    let clear_end = raw.len();
    let mut forgotten = String::new();
    for n in 0..10 {
        let mut add = frame(&state, &format!("new_{n}"));
        add.add = (0..100)
            .map(|i| {
                item(
                    &format!("new-{n}-{i}-{}", "x".repeat(18000)),
                    &s.session_dir,
                )
            })
            .collect();
        forgotten = add.add[0]["id"].as_str().unwrap().to_owned();
        raw.push_str(&line(serde_json::to_value(&add).unwrap()));
        state.control = Some(add);
    }
    let mut forget = frame(&state, "forget");
    forget.forget.push(forgotten.clone());
    raw.push_str(&line(serde_json::to_value(forget).unwrap()));
    pirc_agent::workspace_journal::parse(raw.as_bytes()).unwrap();
    let oversized: Vec<_> = coalesce(&raw[..from], &raw[from..])
        .iter()
        .map(|l| s.with(|state, io| state.convert(io, l)))
        .collect();
    assert!(serde_json::to_vec(&oversized).unwrap().len() > pirc_protocol::NODE_FRAME_MAX_BYTES);
    std::fs::write(&s.file, &raw).unwrap();
    s.connect(&[(KEY, from as u64)]);
    let first = s.frames()[0].clone();
    assert_eq!(first["end"], clear_end);
    assert_eq!(first["lines"][0], json!({"type":"cleared"}));
    s.connect(&[(KEY, from as u64)]);
    assert_eq!(s.frames()[1], first); // a lost ACK reconstructs the same recovery
    let mut projection = raw[..from].to_owned();
    let mut frame_index = 1;
    loop {
        let frames = s.frames();
        let f = &frames[frame_index];
        assert!(serde_json::to_vec(f).unwrap().len() < pirc_protocol::NODE_FRAME_MAX_BYTES);
        for l in f["lines"].as_array().unwrap() {
            if l["type"] != "integrity" {
                projection.push_str(&line(l.clone()));
            }
        }
        let end = f["end"].as_u64().unwrap();
        assert_eq!(
            f["lines"].as_array().unwrap().last().unwrap()["digest"],
            pirc_agent::journal::digest(&raw.as_bytes()[..end as usize])
        );
        if end as usize == raw.len() {
            break;
        }
        s.receive(end);
        frame_index += 1;
        assert!(frame_index < 20);
    }
    assert_eq!(
        pirc_agent::workspace_journal::projection(raw.as_bytes()).unwrap(),
        pirc_agent::workspace_journal::projection(projection.as_bytes()).unwrap()
    );
    assert!(!projection.contains("\"content\":\"blocked-"));
    assert!(projection.contains(&forgotten));
}

#[test]
fn recovery_accounting_matches_public_encoding_with_tombstones_and_chunking() {
    let s = setup();
    let first = item("old", &s.session_dir);
    let prefix = line(json!({"type":"recorded","items":[first.clone()]}));
    let mut state = Coalescer::default();
    let mut size =
        |item: &WorkspaceItem| s.with(|state, io| state.item(io, item)).to_string().len();
    for l in parse_lines(&prefix) {
        state.apply(l, false, &mut size);
    }
    let tail = [
        json!({"type":"retired","ids":[first["id"]],"reason":"superseded"}),
        json!({"type":"recorded","items":[item("next", &s.session_dir)]}),
        json!({"type":"recorded","items":(0..2000).map(|i| item(&format!("quoted \" note-{i}"), &s.session_dir)).collect::<Vec<_>>()}),
        json!({"type":"recorded","items":[item("Unicode 中文\n", &s.session_dir)]}),
        json!({"type":"retired","ids":(0..4001).map(|i| format!("{i:012x}")).collect::<Vec<_>>(),"reason":"forgotten"}),
        json!({"type":"cleared"}),
        json!({"type":"recorded","items":[item("after clear", &s.session_dir)]}),
    ];
    let mut text = String::new();
    for raw in tail {
        let l = line(raw);
        text.push_str(&l);
        for l in parse_lines(&l) {
            state.apply(l, true, &mut size);
        }
        let public: Vec<_> = coalesce(&prefix, &text)
            .iter()
            .map(|l| s.with(|state, io| state.convert(io, l)))
            .collect();
        assert_eq!(
            state.encoded_len(),
            serde_json::to_vec(&public).unwrap().len()
        );
    }
}

#[test]
fn oversized_last_forget_keeps_a_bounded_earlier_forget_without_a_clear() {
    let s = setup();
    let old = item("old", &s.session_dir);
    let prefix = line(json!({"type":"recorded","items":[old.clone()]}));
    let first = format!(
        "{}{}",
        line(json!({"type":"recorded","items":[item("small replacement", &s.session_dir)]})),
        line(json!({"type":"retired","reason":"forgotten","ids":[old["id"]]}))
    );
    let large = item(&"large".repeat(100), &s.session_dir);
    let tail = format!(
        "{first}{}{}",
        line(json!({"type":"recorded","items":[large]})),
        line(json!({"type":"retired","reason":"forgotten","ids":["aaaaaaaaaaaa"]}))
    );
    let selected = recovery_end(&prefix, &tail, 400, None, |item| {
        s.with(|state, io| state.item(io, item)).to_string().len()
    });
    assert_eq!(selected, Some(first.len()));
    let lines: Vec<_> = coalesce(&prefix, &tail[..selected.unwrap()])
        .iter()
        .map(|l| s.with(|state, io| state.convert(io, l)))
        .collect();
    assert!(serde_json::to_vec(&lines).unwrap().len() < 400);
    assert!(!lines.iter().any(|l| l["type"] == "cleared"));
    assert!(
        lines
            .iter()
            .any(|l| l["reason"] == "forgotten" && l["ids"][0] == old["id"])
    );
}

#[test]
fn quota_rejection_survives_reconnect_and_backs_up_without_accepting_stale_feedback() {
    use pirc_agent::workspace_journal::{Snapshot, frame};
    let s = setup();
    let mut raw = line(json!({"type":"recorded","items":[item("x",&s.session_dir)]}));
    let mut snapshot = Snapshot::default();
    let mut cold = frame(&snapshot, "cold");
    cold.cutover = Some(vec![]);
    raw.push_str(&line(serde_json::to_value(&cold).unwrap()));
    snapshot.control = Some(cold);
    let from = raw.len() as u64;
    let mut add = frame(&snapshot, "blocked");
    add.add = (0..20)
        .map(|i| {
            item(
                &format!("blocked-{i}-{}", "x".repeat(18000)),
                &s.session_dir,
            )
        })
        .collect();
    raw.push_str(&line(serde_json::to_value(&add).unwrap()));
    snapshot.control = Some(add);
    let mut clear = frame(&snapshot, "clear");
    clear.clear = true;
    clear.generation = "cleared".into();
    clear.clear_cutoffs = Some(vec![]);
    raw.push_str(&line(serde_json::to_value(&clear).unwrap()));
    snapshot.control = Some(clear);
    let clear_end = raw.len() as u64;
    let mut add = frame(&snapshot, "later_notes");
    add.add = vec![item("new1", &s.session_dir), item("new2", &s.session_dir)];
    let forgotten = add.add[1]["id"].clone();
    raw.push_str(&line(serde_json::to_value(&add).unwrap()));
    snapshot.control = Some(add);
    let mut forget = frame(&snapshot, "forget");
    forget.forget.push(forgotten.as_str().unwrap().into());
    raw.push_str(&line(serde_json::to_value(&forget).unwrap()));
    pirc_agent::workspace_journal::parse(raw.as_bytes()).unwrap();
    std::fs::write(&s.file, &raw).unwrap();
    s.connect(&[(KEY, from)]);
    let latest = raw.len() as u64;
    assert_eq!(s.frames()[0]["end"], latest);
    assert!(
        serde_json::to_vec(&s.frames()[0]).unwrap().len() < pirc_protocol::NODE_FRAME_MAX_BYTES
    );
    // The gateway may reject the four remaining content bytes despite this tiny frame.
    s.with(|state, io| state.receive(io, KEY, from, Some(latest)));
    s.scan();
    assert_eq!(s.frames().len(), 1); // preserve the retry timer
    let deadline = s.state.borrow().sent[KEY].at;
    for _ in 0..3 {
        s.with(|state, _| state.suspend());
        s.connect(&[(KEY, from)]);
        assert_eq!(s.state.borrow().sent[KEY].at, deadline);
        assert_eq!(s.state.borrow().sent[KEY].retry_before, Some(latest));
        assert_eq!(s.frames().len(), 1);
    }
    s.refuse.set(true);
    s.with(|state, io| {
        state.sent.get_mut(KEY).unwrap().at = Instant::now() - ACK_TIMEOUT;
        state.scan(io);
    });
    assert_eq!(s.frames().len(), 1);
    assert_eq!(s.state.borrow().sent[KEY].retry_before, Some(latest));
    s.with(|state, _| state.suspend());
    s.connect(&[(KEY, from)]);
    s.refuse.set(false);
    s.with(|state, io| {
        state.sent.get_mut(KEY).unwrap().at = Instant::now() - ACK_TIMEOUT;
        state.scan(io);
    });
    assert_eq!(s.frames()[1]["end"], clear_end);
    assert_eq!(s.frames()[1]["lines"][0], json!({"type":"cleared"}));
    assert_eq!(
        s.frames()[1]["lines"].as_array().unwrap().last().unwrap()["digest"],
        pirc_agent::journal::digest(&raw.as_bytes()[..clear_end as usize])
    );
    // Late rejection of the larger attempt must not alter the current flight.
    s.with(|state, io| {
        state.receive(io, KEY, from, Some(latest));
        assert_eq!(state.sent[KEY].retry_before, Some(latest));
        state.receive(io, KEY, from + 1, Some(clear_end));
        assert_eq!(state.sent[KEY].retry_before, Some(latest));
    });
    // A lost ACK on the earlier projection resends that projection across reconnect.
    s.with(|state, _| state.suspend());
    s.connect(&[(KEY, from)]);
    assert_eq!(s.frames().len(), 2);
    s.with(|state, io| {
        state.sent.get_mut(KEY).unwrap().at = Instant::now() - ACK_TIMEOUT;
        state.scan(io);
    });
    assert_eq!(s.frames()[2], s.frames()[1]);
    s.receive(clear_end);
    assert_eq!(s.state.borrow().acked[KEY], clear_end);
    let next = s.frames().last().unwrap().clone();
    assert_eq!(next["end"], latest);
    s.with(|state, io| {
        state.receive(io, KEY, clear_end, Some(latest));
        state.sent.get_mut(KEY).unwrap().at = Instant::now() - ACK_TIMEOUT;
        state.scan(io);
    });
    // No earlier candidate remains: retry the latest instead of permanently excluding it.
    assert_eq!(s.frames().last().unwrap(), &next);
    s.connect(&[(KEY, clear_end)]);
    assert_eq!(s.frames().last().unwrap(), &next);
    s.receive(latest);
    assert!(!s.state.borrow().sent.contains_key(KEY));
}

#[test]
fn advancing_checkpoint_discards_a_quota_hint_from_the_older_base() {
    let s = setup();
    s.with(|state, io| {
        state.acked.insert(KEY.into(), 10);
        state.sent.insert(
            KEY.into(),
            Flight {
                at: Instant::now(),
                end: 30,
                retry_before: Some(30),
            },
        );
        // An earlier, durably accepted checkpoint can arrive after its ACK was lost.
        state.receive(io, KEY, 20, None);
        assert_eq!(state.acked[KEY], 20);
        assert!(state.sent[KEY].retry_before.is_none());
        assert!(s.frames.borrow().is_empty());
    });
}

#[test]
fn a_large_valid_legacy_line_cannot_hide_a_bounded_versioned_clear() {
    use pirc_agent::workspace_journal::{Snapshot, frame};
    let s = setup();
    let notes: Vec<_> = (0..500)
        .map(|i| item(&format!("legacy-{i}-{}", "x".repeat(18000)), &s.session_dir))
        .collect();
    let mut raw = line(json!({"type":"recorded","items":notes}));
    assert!(raw.len() > LINE_MAX_BYTES);
    let mut state = Snapshot::default();
    let mut cold = frame(&state, "cold");
    cold.cutover = Some(vec![]);
    raw += &line(json!(cold));
    state.control = Some(cold);
    let mut clear = frame(&state, "clear");
    clear.clear = true;
    clear.clear_cutoffs = Some(vec![]);
    clear.generation = "cleared".into();
    raw += &line(json!(clear));
    pirc_agent::workspace_journal::parse(raw.as_bytes()).unwrap();
    std::fs::write(&s.file, &raw).unwrap();
    s.connect(&[]);
    let frame = &s.frames()[0];
    assert_eq!(frame["end"], raw.len());
    assert_eq!(frame["lines"][0], json!({"type":"cleared"}));
    assert_eq!(frame["lines"].as_array().unwrap().len(), 2);
    assert!(serde_json::to_vec(frame).unwrap().len() < MIRROR_CHUNK_BYTES);
    assert_eq!(
        frame["lines"][1]["digest"],
        pirc_agent::journal::digest(raw.as_bytes())
    );
    assert_eq!(
        frame["lines"][1]["previousDigest"],
        pirc_agent::journal::digest(&[])
    );
    s.with(|state, _| state.suspend());
    s.connect(&[]);
    assert_eq!(s.frames().len(), 2);
    assert_eq!(s.frames()[0], s.frames()[1]);
}
#[test]
fn reconnect_drops_quota_progress_when_the_acknowledged_base_changes() {
    let s = setup();
    s.with(|state, _| {
        state.acked.insert(KEY.into(), 10);
        state.sent.insert(
            KEY.into(),
            Flight {
                at: Instant::now(),
                end: 30,
                retry_before: Some(30),
            },
        );
        state.verified.insert(KEY.into(), (30, "hash".into()));
        state.suspend();
        state.resume(HashMap::from([(KEY.into(), 20)]));
        assert!(!state.sent.contains_key(KEY));
        assert!(!state.verified.contains_key(KEY));
    });
}

#[test]
fn reconnect_revalidates_quota_retreat_against_the_original_bytes() {
    use pirc_agent::workspace_journal::{Snapshot, frame};
    let s = setup();
    let mut state = Snapshot::default();
    let mut cold = frame(&state, "cold");
    cold.cutover = Some(vec![]);
    let mut raw = line(json!(cold));
    state.control = Some(cold);
    let from = raw.len() as u64;
    let mut clear = frame(&state, "clear");
    clear.clear = true;
    clear.generation = "cleared".into();
    clear.clear_cutoffs = Some(vec![]);
    raw += &line(json!(clear));
    state.control = Some(clear);
    let mut add = frame(&state, "add");
    add.add = vec![item("new", &s.session_dir)];
    let id = add.add[0]["id"].as_str().unwrap().to_owned();
    raw += &line(json!(add));
    state.control = Some(add);
    let mut forget = frame(&state, "forget");
    forget.at = 2;
    forget.forget.push(id);
    raw += &line(json!(forget));
    pirc_agent::workspace_journal::parse(raw.as_bytes()).unwrap();
    std::fs::write(&s.file, &raw).unwrap();
    s.connect(&[(KEY, from)]);
    let end = raw.len() as u64;
    s.with(|state, io| state.receive(io, KEY, from, Some(end)));
    let replacement = raw.replace("\"at\":2,", "\"at\":3,");
    assert_ne!(replacement, raw);
    assert_eq!(replacement.len(), raw.len());
    pirc_agent::workspace_journal::parse(replacement.as_bytes()).unwrap();
    std::fs::write(&s.file, replacement).unwrap();
    s.with(|state, _| {
        state.suspend();
        state.sent.get_mut(KEY).unwrap().at = Instant::now() - ACK_TIMEOUT;
    });
    s.connect(&[(KEY, from)]);
    // The old rejection no longer describes this byte sequence: choose afresh.
    assert_eq!(s.frames()[1]["end"], end);
    assert!(s.state.borrow().sent[KEY].retry_before.is_none());
}
