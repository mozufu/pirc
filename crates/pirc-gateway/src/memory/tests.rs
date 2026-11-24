//! `apps/gateway/test/memory-store.test.ts`, and the interactions projected
//! from proposals.

use std::sync::Arc;

use rusqlite::Connection;
use serde_json::{Value, json};

use super::store::{
    Action, Budgets, Change, Entry, EntryStatus, NoteInput, Proposal, ProposalStatus, ProposeInput,
    Store,
};
use pirc_providers::backends::BackendService;

use crate::app::{App, empty_models};
use crate::db::{Db, Store as _};
use crate::error::ApiResult;

const ME: &str = "me@example.com";
const OTHER: &str = "other@example.com";

/// A gateway over an in-memory database, for tests that need an [`App`].
pub fn app() -> (Arc<App>, tempfile::TempDir) {
    let dir = tempfile::tempdir().unwrap();
    let state = dir.path().join("state");
    let env = pirc_config::Env::new(
        [
            (
                "PIRC_NODE_TOKENS",
                r#"{"n1":"0123456789abcdef0123456789abcdef"}"#,
            ),
            ("PIRC_TRUSTED_PROXIES", "127.0.0.1"),
            ("PIRC_PROXY_SECRET_REQUIRED", "false"),
            ("PIRC_ALLOWED_ORIGINS", "https://a.example"),
            ("PIRC_ALLOWED_HOSTS", "a.example"),
            ("PIRC_ALLOWED_USERS", ME),
            ("PIRC_STATE_DIR", state.to_str().unwrap()),
            ("PIRC_TIMEZONE", "UTC"),
            ("PIRC_MEMORY_USER_CHARS", "60"),
            ("PIRC_MEMORY_NOTE_CHARS", "80"),
            ("HOME", "/home/test"),
        ],
        "/",
    );
    let config = pirc_config::GatewayConfig::load(&env).unwrap();
    let backends = BackendService::open(&state, empty_models()).unwrap();
    (
        App::new(
            config,
            Arc::new(Db::memory()),
            backends,
            crate::app::test_modes(),
        ),
        dir,
    )
}

fn store(conn: &Connection) -> Store<'_> {
    Store::new(conn, Budgets { user: 60, note: 80 })
}

fn from_chat() -> Change {
    Change {
        actor: "session:s1".into(),
        origins: json!(["assistant"]),
        sources: json!({ "sessionId": "s1" }),
    }
}

fn code<T>(result: ApiResult<T>) -> &'static str {
    match result {
        Ok(_) => panic!("expected a failure"),
        Err(error) => error.code,
    }
}

fn add(content: &str) -> NoteInput {
    NoteInput {
        action: Action::Add,
        id: None,
        content: Some(content.into()),
        base_revision: None,
    }
}

fn edit(action: Action, id: &str, content: Option<&str>, base: Option<i64>) -> NoteInput {
    NoteInput {
        action,
        id: Some(id.into()),
        content: content.map(str::to_owned),
        base_revision: base,
    }
}

fn note(store: &Store<'_>, content: &str, user: &str) -> ApiResult<Entry> {
    store
        .write_note(user, &add(content), &from_chat())
        .map(|(entry, _)| entry)
}

fn propose_in(
    store: &Store<'_>,
    action: Action,
    id: Option<&str>,
    content: Option<&str>,
    base: Option<i64>,
    quote: &str,
) -> ApiResult<(Proposal, bool)> {
    store.propose(
        ME,
        "s1",
        &ProposeInput {
            action,
            id: id.map(str::to_owned),
            content: content.map(str::to_owned),
            base_revision: base,
            quote: quote.into(),
        },
        &json!({ "sessionId": "s1" }),
    )
}

fn propose(store: &Store<'_>, content: &str, quote: &str) -> ApiResult<(Proposal, bool)> {
    propose_in(store, Action::Add, None, Some(content), None, quote)
}

#[test]
fn notes_are_added_replaced_and_removed_with_every_revision_logged() {
    let db = Db::memory();
    let conn = db.lock();
    let store = store(&conn);
    let added = note(&store, "m5pro  holds\n the pirc repo", ME).unwrap();
    assert_eq!(
        (added.kind.as_str(), added.content.as_str(), added.revision),
        ("note", "m5pro holds the pirc repo", 1)
    );
    assert!(added.id.starts_with('n') && added.id.len() == 9);
    // Adding the same fact again (ignoring case and spacing) changes nothing.
    let (same, unchanged) = store
        .write_note(ME, &add("M5PRO holds the pirc repo"), &from_chat())
        .unwrap();
    assert!(unchanged);
    assert_eq!(same.id, added.id);

    // A replace must name the revision it saw; anything else returns the current one.
    let stale = store
        .write_note(
            ME,
            &edit(Action::Replace, &added.id, Some("x"), Some(0)),
            &from_chat(),
        )
        .unwrap_err();
    assert_eq!(stale.code, "conflict");
    assert_eq!(
        stale.details,
        Some(json!({ "id": added.id, "revision": 1, "content": "m5pro holds the pirc repo" }))
    );
    let replaced = store
        .write_note(
            ME,
            &edit(
                Action::Replace,
                &added.id,
                Some("lumo holds the pirc repo"),
                Some(1),
            ),
            &Change {
                origins: json!(["assistant", "tool:bash"]),
                ..from_chat()
            },
        )
        .unwrap()
        .0;
    assert_eq!(replaced.revision, 2);
    assert_eq!(replaced.origins, json!(["assistant", "tool:bash"]));
    let removed = store
        .write_note(
            ME,
            &edit(Action::Remove, &added.id, None, Some(2)),
            &from_chat(),
        )
        .unwrap()
        .0;
    assert_eq!((removed.status.as_str(), removed.revision), ("removed", 3));
    let history: Vec<(i64, String, Option<String>)> = store
        .history(ME, &added.id)
        .unwrap()
        .into_iter()
        .map(|v| (v.revision, v.op, v.content))
        .collect();
    assert_eq!(
        history,
        [
            (3, "remove".into(), None),
            (2, "replace".into(), Some("lumo holds the pirc repo".into())),
            (1, "add".into(), Some("m5pro holds the pirc repo".into())),
        ]
    );
    assert_eq!(store.context(ME, None).unwrap()["notes"], json!([]));
}

#[test]
fn notes_from_fetched_content_are_marked_in_the_context() {
    let db = Db::memory();
    let conn = db.lock();
    let store = store(&conn);
    let write = |content: &str, origins: Value| {
        store
            .write_note(
                ME,
                &add(content),
                &Change {
                    origins,
                    ..from_chat()
                },
            )
            .unwrap()
            .0
    };
    write("fetched", json!(["assistant", "tool:bash:network"]));
    write(
        "browsed",
        json!(["assistant", "tool:browser_snapshot", "tool:read"]),
    );
    write("local", json!(["assistant", "tool:bash"]));
    // The user's own words count more than a page they asked about.
    write("quoted", json!(["assistant", "tool:web_fetch", "user"]));
    let context = store.context(ME, None).unwrap();
    let mut fetched: Vec<(&str, bool)> = context["notes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|note| {
            (
                note["content"].as_str().unwrap(),
                note.get("fetched") == Some(&json!(true)),
            )
        })
        .collect();
    // Notes written in the same millisecond come in id order: sort.
    fetched.sort();
    assert_eq!(
        fetched,
        [
            ("browsed", true),
            ("fetched", true),
            ("local", false),
            ("quoted", false),
        ]
    );
}

#[test]
fn notes_stay_within_the_budget_one_entry_per_fact() {
    let db = Db::memory();
    let conn = db.lock();
    let store = store(&conn);
    note(&store, &"a".repeat(50), ME).unwrap();
    let full = note(&store, &"b".repeat(31), ME).unwrap_err();
    assert_eq!(full.code, "memory_full");
    assert_eq!(
        full.message,
        "MEMORY is full (50/80 characters, 31 more needed); replace or remove entries to make room"
    );
    assert_eq!(
        code(note(&store, &"c".repeat(1001), ME)),
        "payload_too_large"
    );
    assert_eq!(code(note(&store, "   ", ME)), "invalid_input");
    assert_eq!(
        store.usage(ME).unwrap()["note"],
        json!({ "used": 50, "max": 80 })
    );
}

#[test]
fn secrets_are_stripped_before_storing() {
    let db = Db::memory();
    let conn = db.lock();
    let store = store(&conn);
    let entry = note(&store, &format!("deploy token ghp_{}", "a".repeat(36)), ME).unwrap();
    assert_eq!(entry.content, "deploy token ghp_[REDACTED]");
}

#[test]
fn the_assistant_never_touches_user_entries_directly() {
    let db = Db::memory();
    let conn = db.lock();
    let store = store(&conn);
    let (proposal, _) = propose(&store, "Prefers short answers.", "I said so").unwrap();
    let entry = store.approve(ME, &proposal.id, None).unwrap().1;
    assert_eq!(
        code(store.write_note(
            ME,
            &edit(Action::Replace, &entry.id, Some("x"), Some(1)),
            &from_chat()
        )),
        "forbidden"
    );
}

#[test]
fn users_are_kept_apart() {
    let db = Db::memory();
    let conn = db.lock();
    let store = store(&conn);
    let mine = note(&store, "mine", ME).unwrap();
    assert_eq!(code(store.entry(OTHER, &mine.id)), "not_found");
    assert_eq!(store.context(OTHER, None).unwrap()["notes"], json!([]));
}

#[test]
fn user_changes_only_when_the_user_approves() {
    let db = Db::memory();
    let conn = db.lock();
    let store = store(&conn);
    let (proposal, duplicate) = propose(
        &store,
        "Prefers answers in Traditional Chinese.",
        "請用繁中",
    )
    .unwrap();
    assert_eq!(
        (
            proposal.status.as_str(),
            duplicate,
            proposal.id.starts_with('p')
        ),
        ("pending", false, true)
    );
    let context = store.context(ME, None).unwrap();
    assert_eq!(
        (&context["user"], &context["pendingProposals"]),
        (&json!([]), &json!(1))
    );
    // The same proposal again is the same pending proposal.
    let (again, duplicate) = propose(
        &store,
        "Prefers answers in Traditional Chinese.",
        "請用繁中",
    )
    .unwrap();
    assert!(duplicate);
    assert_eq!(again.id, proposal.id);
    let entry = store.approve(ME, &proposal.id, None).unwrap().1;
    assert_eq!(
        (entry.kind.as_str(), entry.content.as_str()),
        ("user", "Prefers answers in Traditional Chinese.")
    );
    assert_eq!(entry.origins, json!(["user"]));
    assert_eq!(
        entry.sources,
        json!({ "sessionId": "s1", "quote": "請用繁中", "proposalId": proposal.id })
    );
    assert_eq!(
        store.history(ME, &entry.id).unwrap()[0].actor,
        format!("user:{ME}")
    );
    let approved = store.proposal(ME, &proposal.id).unwrap();
    assert_eq!(approved.status, ProposalStatus::Approved);
    assert_eq!(approved.target_id.as_deref(), Some(entry.id.as_str()));
    assert_eq!(code(store.approve(ME, &proposal.id, None)), "conflict");
    // Already in USER: nothing to propose.
    assert_eq!(
        code(propose(
            &store,
            "prefers answers in traditional chinese.",
            "I said so"
        )),
        "conflict"
    );
}

#[test]
fn user_entries_are_replaced_and_removed_at_the_version_seen() {
    let db = Db::memory();
    let conn = db.lock();
    let store = store(&conn);
    let first = store
        .approve(
            ME,
            &propose(&store, "Lives in Taipei.", "I said so")
                .unwrap()
                .0
                .id,
            None,
        )
        .unwrap()
        .1;
    let (moved, _) = propose_in(
        &store,
        Action::Replace,
        Some(&first.id),
        Some("Lives in Tokyo."),
        Some(1),
        "moved to Tokyo",
    )
    .unwrap();
    assert_eq!(
        (moved.target_id.as_deref(), moved.target_revision),
        (Some(first.id.as_str()), Some(1))
    );
    assert_eq!(code(store.approve(ME, &moved.id, Some(7))), "conflict");
    let entry = store.approve(ME, &moved.id, Some(1)).unwrap().1;
    assert_eq!(
        (entry.content.as_str(), entry.revision),
        ("Lives in Tokyo.", 2)
    );
    let (drop, _) = propose_in(
        &store,
        Action::Remove,
        Some(&first.id),
        None,
        None,
        "forget where I live",
    )
    .unwrap();
    let entry = store.approve(ME, &drop.id, None).unwrap().1;
    assert_eq!((entry.status.as_str(), entry.revision), ("removed", 3));
    assert_eq!(store.context(ME, None).unwrap()["user"], json!([]));
}

#[test]
fn rejections_are_remembered_and_waiting_proposals_capped() {
    let db = Db::memory();
    let conn = db.lock();
    let store = store(&conn);
    let (proposal, _) = propose(&store, "Likes jazz.", "I said so").unwrap();
    assert_eq!(
        store.reject(ME, &proposal.id).unwrap().status,
        ProposalStatus::Rejected
    );
    assert_eq!(
        code(propose(&store, "Likes jazz.", "I said so")),
        "rejected_before"
    );
    for i in 0..20 {
        propose(&store, &format!("Fact {i}."), "I said so").unwrap();
    }
    let error = propose(&store, "One too many.", "I said so").unwrap_err();
    assert_eq!(error.code, "too_many_requests");
    assert_eq!(
        error.message,
        "20 proposals are already waiting; ask the user to review them in Settings → Memory"
    );
}

#[test]
fn the_user_budget_counts_when_proposing_and_approving() {
    let db = Db::memory();
    let conn = db.lock();
    let store = store(&conn);
    let big = store
        .approve(
            ME,
            &propose(&store, &"x".repeat(40), "I said so").unwrap().0.id,
            None,
        )
        .unwrap()
        .1;
    assert_eq!(
        code(propose(&store, &"y".repeat(30), "I said so")),
        "memory_full"
    );
    let fits = propose(&store, &"z".repeat(15), "I said so").unwrap().0;
    // 10 more characters: fits now (50/60), not after `fits` is approved (55 + 10).
    let grows = propose_in(
        &store,
        Action::Replace,
        Some(&big.id),
        Some(&"w".repeat(50)),
        Some(1),
        "q",
    )
    .unwrap()
    .0;
    store.approve(ME, &fits.id, None).unwrap();
    assert_eq!(code(store.approve(ME, &grows.id, None)), "memory_full");
    assert_eq!(
        store.proposal(ME, &grows.id).unwrap().status,
        ProposalStatus::Pending
    );
    assert_eq!(code(propose(&store, "No words.", "  ")), "invalid_input");
}

#[test]
fn forgetting_erases_every_version_and_refuses_the_text_again() {
    let db = Db::memory();
    let conn = db.lock();
    let store = store(&conn);
    let (proposal, _) = propose(&store, "Has two cats.", "I have two cats").unwrap();
    let entry = store.approve(ME, &proposal.id, None).unwrap().1;
    let (again, _) = propose_in(
        &store,
        Action::Replace,
        Some(&entry.id),
        Some("Has three cats."),
        Some(1),
        "3",
    )
    .unwrap();
    store.approve(ME, &again.id, None).unwrap();
    let (pending_remove, _) = propose_in(
        &store,
        Action::Remove,
        Some(&entry.id),
        None,
        None,
        "no more cats",
    )
    .unwrap();

    store.forget(ME, &entry.id).unwrap();
    let forgotten = store.entry(ME, &entry.id).unwrap();
    assert_eq!(
        (
            forgotten.status.as_str(),
            forgotten.content.as_str(),
            &forgotten.origins,
            &forgotten.sources
        ),
        ("forgotten", "", &json!([]), &json!({}))
    );
    let history: Vec<(String, Option<String>)> = store
        .history(ME, &entry.id)
        .unwrap()
        .into_iter()
        .map(|v| (v.op, v.content))
        .collect();
    assert_eq!(history, [("forget".to_owned(), None)]);
    for id in [&proposal.id, &again.id, &pending_remove.id] {
        let proposal = store.proposal(ME, id).unwrap();
        assert_eq!((proposal.content, proposal.quote.as_str()), (None, ""));
    }
    assert_eq!(
        store.proposal(ME, &pending_remove.id).unwrap().status,
        ProposalStatus::Rejected
    );
    // Neither version can come back, whatever the case or spacing.
    assert_eq!(
        code(propose(&store, "has  TWO cats.", "I said so")),
        "forgotten"
    );
    assert_eq!(code(note(&store, "Has three cats.", ME)), "forgotten");
    assert_eq!(code(store.restore(ME, &entry.id, Some(1))), "forgotten");
    // Another user's identical text is unaffected.
    assert_eq!(
        note(&store, "Has two cats.", OTHER).unwrap().content,
        "Has two cats."
    );
    // Idempotent.
    store.forget(ME, &entry.id).unwrap();
}

#[test]
fn removed_notes_and_earlier_versions_are_restored_within_the_budget() {
    let db = Db::memory();
    let conn = db.lock();
    let store = store(&conn);
    let entry = note(&store, "first version", ME).unwrap();
    store
        .write_note(
            ME,
            &edit(Action::Replace, &entry.id, Some("second version"), Some(1)),
            &from_chat(),
        )
        .unwrap();
    store
        .write_note(
            ME,
            &edit(Action::Remove, &entry.id, None, Some(2)),
            &from_chat(),
        )
        .unwrap();
    let back = store.restore(ME, &entry.id, None).unwrap();
    assert_eq!(
        (back.status.as_str(), back.content.as_str(), back.revision),
        ("active", "second version", 4)
    );
    let back = store.restore(ME, &entry.id, Some(1)).unwrap();
    assert_eq!(
        (back.content.as_str(), back.revision, &back.origins),
        ("first version", 5, &json!(["assistant"]))
    );
    let latest = &store.history(ME, &entry.id).unwrap()[0];
    assert_eq!(
        (latest.op.as_str(), latest.actor.as_str()),
        ("restore", "user:me@example.com")
    );
    assert_eq!(code(store.restore(ME, &entry.id, Some(3))), "not_found");
    note(&store, &"f".repeat(66), ME).unwrap();
    let removed = store
        .write_note(
            ME,
            &edit(Action::Remove, &entry.id, None, Some(5)),
            &from_chat(),
        )
        .unwrap()
        .0;
    note(&store, &"g".repeat(10), ME).unwrap();
    assert_eq!(code(store.restore(ME, &removed.id, None)), "memory_full");
}

#[test]
fn deleting_the_source_chat_forgets_what_it_created() {
    let db = Db::memory();
    let conn = db.lock();
    let store = store(&conn);
    let elsewhere_change = || Change {
        sources: json!({ "sessionId": "s2" }),
        ..from_chat()
    };
    let created = note(&store, "Originally here", ME).unwrap();
    store
        .write_note(
            ME,
            &edit(
                Action::Replace,
                &created.id,
                Some("Edited elsewhere"),
                Some(1),
            ),
            &elsewhere_change(),
        )
        .unwrap();
    let elsewhere = store
        .write_note(ME, &add("Originally elsewhere"), &elsewhere_change())
        .unwrap()
        .0;
    store
        .write_note(
            ME,
            &edit(Action::Replace, &elsewhere.id, Some("Edited here"), Some(1)),
            &from_chat(),
        )
        .unwrap();
    // A deduplicated add must not steal another chat's creation provenance.
    store
        .write_note(ME, &add("Edited here"), &from_chat())
        .unwrap();
    let user = store
        .approve(
            ME,
            &propose(&store, "Prefers tea", "I said so").unwrap().0.id,
            None,
        )
        .unwrap()
        .1;
    let pending = propose(&store, "Prefers coffee", "I said so").unwrap().0;
    let other = note(&store, "Other owner", OTHER).unwrap();
    store.forget_session(ME, "s1").unwrap();
    for id in [&created.id, &user.id] {
        let entry = store.entry(ME, id).unwrap();
        assert_eq!(
            (entry.status.as_str(), entry.content.as_str()),
            ("forgotten", "")
        );
    }
    assert!(
        store
            .history(ME, &created.id)
            .unwrap()
            .iter()
            .all(|v| v.content.is_none())
    );
    let kept = store.entry(ME, &elsewhere.id).unwrap();
    assert_eq!(
        (kept.status.as_str(), kept.content.as_str()),
        ("active", "Edited here")
    );
    assert_eq!(
        store.entry(OTHER, &other.id).unwrap().status,
        EntryStatus::Active
    );
    assert_eq!(code(store.proposal(ME, &pending.id)), "not_found");
    for content in ["Originally here", "Edited elsewhere"] {
        assert_eq!(code(note(&store, content, ME)), "forgotten");
    }
    assert_eq!(code(store.restore(ME, &user.id, None)), "forgotten");
    // Safe to retry after a lost acknowledgement.
    store.forget_session(ME, "s1").unwrap();
}

/// A chat workspace on node `n1` with one session of mine (`remote-1`).
fn chat_session(app: &App) -> String {
    let conn = app.db.lock();
    conn.sync_remote_workspaces(
        "n1",
        &[(
            "chat".into(),
            "Chat".into(),
            crate::db::ModeId::new("chat").unwrap(),
        )],
    )
    .unwrap();
    conn.create_session("n1:chat", "node://n1/remote-1", "n1", "remote-1", ME)
        .unwrap()
        .id
}

#[test]
fn proposals_are_interactions_of_their_chat() {
    let (app, _dir) = app();
    let session = chat_session(&app);
    let events = Arc::new(std::sync::Mutex::new(Vec::<Value>::new()));
    let seen = events.clone();
    let _subscription = app.events.subscribe_all(Arc::new(move |event| {
        seen.lock()
            .unwrap()
            .push(json!({ "type": event.kind, "data": event.data }));
    }));
    let proposal = {
        let conn = app.db.lock();
        super::interactions::ensure_known(&app, &conn);
        let store = super::store(&app, &conn);
        let entry = store
            .approve(
                ME,
                &store
                    .propose(
                        ME,
                        &session,
                        &ProposeInput {
                            action: Action::Add,
                            id: None,
                            content: Some("Lives in Taipei.".into()),
                            base_revision: None,
                            quote: "I live in Taipei".into(),
                        },
                        &json!({}),
                    )
                    .unwrap()
                    .0
                    .id,
                None,
            )
            .unwrap()
            .1;
        store
            .propose(
                ME,
                &session,
                &ProposeInput {
                    action: Action::Replace,
                    id: Some(entry.id.clone()),
                    content: Some("Lives in Tokyo.".into()),
                    base_revision: Some(1),
                    quote: "moved to Tokyo".into(),
                },
                &json!({}),
            )
            .unwrap()
            .0
    };
    super::changed(&app, ME);
    let cards = super::pending_interactions(&app, &session, ME);
    assert_eq!(cards.len(), 1);
    let card = &cards[0];
    let id = format!("memory:{}:1", proposal.id);
    assert_eq!(card["id"], id.as_str());
    assert_eq!(card["request"]["title"], "Replace USER memory?");
    assert!(
        card["request"]["message"]
            .as_str()
            .unwrap()
            .starts_with("Current memory (u")
    );
    assert!(super::pending_interactions(&app, "other", ME).is_empty());
    assert_eq!(
        events.lock().unwrap().as_slice(),
        [json!({ "type": "interaction_created", "data": card })]
    );

    let answer = |answer: Value| super::answer(&app, &session, &id, ME, Some(&answer));
    assert_eq!(
        super::answer(&app, &session, "node-1", ME, None).unwrap(),
        None
    );
    assert_eq!(code(answer(json!({ "confirmed": "yes" }))), "invalid_input");
    assert_eq!(
        answer(json!({ "confirmed": false })).unwrap(),
        Some(json!({ "interactionId": id, "status": "answered" }))
    );
    assert_eq!(
        code(answer(json!({ "confirmed": true }))),
        "stale_interaction"
    );
    super::changed(&app, ME);
    assert_eq!(
        events.lock().unwrap().last(),
        Some(
            &json!({ "type": "interaction_answered", "data": { "interactionId": id, "interactionEpoch": 0 } })
        )
    );
}

/// What a coding session gets (`assistant.context` outside a chat): the
/// approved, active USER entries of its own user, never another user's,
/// and none that were removed or forgotten.
#[test]
fn coding_sessions_get_only_their_users_active_user_entries() {
    let db = Db::memory();
    let conn = db.lock();
    let store = store(&conn);
    let approve_for = |user: &str, content: &str| {
        let (proposal, _) = store
            .propose(
                user,
                "s1",
                &ProposeInput {
                    action: Action::Add,
                    id: None,
                    content: Some(content.into()),
                    base_revision: None,
                    quote: "I said so".into(),
                },
                &json!({ "sessionId": "s1" }),
            )
            .unwrap();
        store.approve(user, &proposal.id, None).unwrap().1
    };
    approve_for(ME, "Kept.");
    let removed = approve_for(ME, "Removed.");
    let forgotten = approve_for(ME, "Forgotten.");
    approve_for(OTHER, "Someone else.");
    let (drop, _) = propose_in(
        &store,
        Action::Remove,
        Some(&removed.id),
        None,
        None,
        "drop it",
    )
    .unwrap();
    store.approve(ME, &drop.id, None).unwrap();
    store.forget(ME, &forgotten.id).unwrap();
    let contents = |user: &str| -> Vec<Value> {
        store
            .user_context(user)
            .unwrap()
            .into_iter()
            .map(|brief| brief["content"].clone())
            .collect()
    };
    assert_eq!(contents(ME), vec![json!("Kept.")]);
    assert_eq!(contents(OTHER), vec![json!("Someone else.")]);
    assert_eq!(contents("nobody@example.com"), Vec::<Value>::new());
}

fn in_chat(session: &str) -> Change {
    Change {
        actor: format!("session:{session}"),
        origins: json!(["assistant"]),
        sources: json!({ "sessionId": session }),
    }
}

fn write(store: &Store<'_>, input: &NoteInput, session: &str) -> Entry {
    store.write_note(ME, input, &in_chat(session)).unwrap().0
}

fn seed_project_authors(conn: &Connection) {
    use pirc_protocol::ModeId;
    conn.sync_remote_workspaces(
        "w",
        &[
            ("p".into(), "P".into(), ModeId::new("chat").unwrap()),
            ("other".into(), "Other".into(), ModeId::new("chat").unwrap()),
        ],
    )
    .unwrap();
    crate::conversation_bindings::policies::install_catalog(conn, &crate::app::test_modes())
        .unwrap();
    for (id, workspace) in [
        ("p1", "w:p"),
        ("p2", "w:p"),
        ("s2", "w:other"),
        ("s3", "w:other"),
    ] {
        conn.execute("INSERT INTO sessions(id,workspace_id,private_session_path,name,owner_user,created_at,updated_at) VALUES(?,?,?,?,?,0,0)",rusqlite::params![id,workspace,format!("node://w/{id}"),id,ME]).unwrap();
    }
}

#[test]
fn deleting_a_project_classifies_by_the_session_of_each_version() {
    use super::store::{ProjectAction, ProjectChoice, ProjectDecision};
    let db = Db::memory();
    let conn = db.lock();
    let store = store(&conn);
    seed_project_authors(&conn);
    // Only the project: forgotten.
    let own = write(&store, &add("Project only"), "p1");
    let own = write(
        &store,
        &edit(Action::Replace, &own.id, Some("Project only 2"), Some(1)),
        "p2",
    );
    // Elsewhere, then the project: rolled back.
    let tail = write(&store, &add("Tea"), "s2");
    write(
        &store,
        &edit(Action::Replace, &tail.id, Some("Tea for X"), Some(1)),
        "p1",
    );
    // Mixed: the user decides.
    let mixed = write(&store, &add("A"), "s2");
    write(
        &store,
        &edit(Action::Replace, &mixed.id, Some("A plus"), Some(1)),
        "p1",
    );
    let mixed = write(
        &store,
        &edit(Action::Replace, &mixed.id, Some("A plus more"), Some(2)),
        "s2",
    );
    // Untouched.
    let other = write(&store, &add("Other"), "s2");
    let pending = store
        .propose(
            ME,
            "p1",
            &ProposeInput {
                action: Action::Add,
                id: None,
                content: Some("Likes X".into()),
                base_revision: None,
                quote: "I like X".into(),
            },
            &json!({ "sessionId": "p1" }),
        )
        .unwrap()
        .0;

    let plan = store.project_plan(ME, "w:p").unwrap();
    let action = |id: &str| {
        plan.iter()
            .find(|item| item.entry.id == id)
            .map(|item| item.action)
    };
    assert_eq!(action(&own.id), Some(ProjectAction::Forget));
    assert_eq!(action(&tail.id), Some(ProjectAction::Rollback));
    assert_eq!(action(&mixed.id), Some(ProjectAction::Review));
    assert_eq!(action(&other.id), None);
    let rollback = plan.iter().find(|item| item.entry.id == tail.id).unwrap();
    assert_eq!(
        (rollback.restored.as_deref(), rollback.restored_revision),
        (Some("Tea"), Some(1))
    );

    // Without a decision (or on another revision) nothing changes.
    assert_eq!(code(store.delete_project(ME, "w:p", &[], &[])), "conflict");
    let stale = vec![(
        mixed.id.clone(),
        ProjectDecision {
            revision: mixed.revision - 1,
            choice: ProjectChoice::Forget,
        },
    )];
    assert_eq!(
        code(store.delete_project(ME, "w:p", &stale, &[])),
        "conflict"
    );
    assert_eq!(
        store.entry(ME, &own.id).unwrap().status,
        EntryStatus::Active
    );
    assert_eq!(
        store.proposal(ME, &pending.id).unwrap().status,
        ProposalStatus::Pending
    );

    let decisions = vec![(
        mixed.id.clone(),
        ProjectDecision {
            revision: mixed.revision,
            choice: ProjectChoice::Edit("A cleaned".into()),
        },
    )];
    store.delete_project(ME, "w:p", &decisions, &[]).unwrap();
    let forgotten = store.entry(ME, &own.id).unwrap();
    assert_eq!(
        (forgotten.status.as_str(), forgotten.content.as_str()),
        ("forgotten", "")
    );
    let rolled = store.entry(ME, &tail.id).unwrap();
    assert_eq!(rolled.content, "Tea");
    let texts = |id: &str| -> Vec<String> {
        store
            .history(ME, id)
            .unwrap()
            .into_iter()
            .filter_map(|version| version.content)
            .collect()
    };
    assert!(!texts(&tail.id).iter().any(|text| text.contains("for X")));
    let edited = store.entry(ME, &mixed.id).unwrap();
    assert_eq!(edited.content, "A cleaned");
    assert_eq!(edited.origins, json!(["user"]));
    // The project's version is gone from the history; the others stay.
    assert_eq!(texts(&mixed.id), ["A cleaned", "A plus more", "A"]);
    assert_eq!(store.entry(ME, &other.id).unwrap().content, "Other");
    assert_eq!(code(store.proposal(ME, &pending.id)), "not_found");
    // Project tombstones refuse nothing: another chat may write it again.
    write(&store, &add("Tea for X"), "s2");
    write(&store, &add("Project only 2"), "s2");
    // A user's Forget still does.
    store.forget(ME, &other.id).unwrap();
    assert_eq!(code(note(&store, "Other", ME)), "forgotten");
    // Nothing of the project is left to do; a repeated sweep is a no-op.
    let left: Vec<_> = store
        .project_plan(ME, "w:p")
        .unwrap()
        .into_iter()
        .map(|item| item.entry.id)
        .collect();
    assert!(left.is_empty(), "{left:?}");
    store.delete_project(ME, "w:p", &[], &[]).unwrap();
}

#[test]
fn a_kept_entry_stays_as_it_is() {
    use super::store::{ProjectAction, ProjectChoice, ProjectDecision};
    let db = Db::memory();
    let conn = db.lock();
    let store = store(&conn);
    seed_project_authors(&conn);
    // Created in the project, edited elsewhere: mixed too.
    let entry = write(&store, &add("From P"), "p1");
    let entry = write(
        &store,
        &edit(Action::Replace, &entry.id, Some("From P and S"), Some(1)),
        "s2",
    );
    let plan = store.project_plan(ME, "w:p").unwrap();
    assert_eq!(plan[0].action, ProjectAction::Review);
    let decisions = vec![(
        entry.id.clone(),
        ProjectDecision {
            revision: entry.revision,
            choice: ProjectChoice::Keep,
        },
    )];
    store.delete_project(ME, "w:p", &decisions, &[]).unwrap();
    let kept = store.entry(ME, &entry.id).unwrap();
    assert_eq!(
        (kept.content.as_str(), kept.revision),
        ("From P and S", entry.revision)
    );
    assert_eq!(store.history(ME, &entry.id).unwrap().len(), 2);
    // The raw plan still sees mixed history. The orchestration receipt, tested
    // separately, prevents retrying this low-level mutation.
    assert_eq!(code(store.delete_project(ME, "w:p", &[], &[])), "conflict");
    assert_eq!(store.entry(ME, &entry.id).unwrap().content, "From P and S");
}

#[test]
fn a_rollback_to_text_forgotten_since_forgets_instead() {
    use super::store::ProjectAction;
    let db = Db::memory();
    let conn = db.lock();
    let store = store(&conn);
    seed_project_authors(&conn);
    let entry = write(&store, &add("Old text"), "s2");
    write(
        &store,
        &edit(Action::Replace, &entry.id, Some("New text"), Some(1)),
        "p1",
    );
    // Forgotten elsewhere with the same words.
    let twin = write(&store, &add("Something"), "s3");
    let twin = write(
        &store,
        &edit(Action::Replace, &twin.id, Some("Other"), Some(1)),
        "s3",
    );
    conn.execute(
        "INSERT INTO memory_tombstones (owner_user,scope_id,content_hash,forgotten_at) VALUES (?,'global',?,0)",
        rusqlite::params![ME, super::text::content_hash("Old text")],
    )
    .unwrap();
    assert_eq!(
        store.project_plan(ME, "w:p").unwrap()[0].action,
        ProjectAction::Rollback
    );
    store.delete_project(ME, "w:p", &[], &[]).unwrap();
    assert_eq!(
        store.entry(ME, &entry.id).unwrap().status,
        EntryStatus::Forgotten
    );
    assert_eq!(store.entry(ME, &twin.id).unwrap().content, "Other");
}

// ---------------------------------------------------------------------------
// The request shape of the routes that change memory

mod request_shape {
    use std::sync::atomic::{AtomicUsize, Ordering};

    use super::*;
    use crate::request_shape::tests::{Probe, Who, identities, ok, probe, prove_operation};

    fn view(app: &App) -> Value {
        let conn = app.db.lock();
        let store = super::store(&conn);
        json!({
            "entries": store.entries(ME, None, None).unwrap(),
            "proposals": store.proposals(ME, None).unwrap(),
        })
    }

    fn accepted() -> Vec<Probe> {
        vec![
            probe("request header, no body", &[("x-pirc-request", "1")], ""),
            probe("strict JSON", &[("content-type", "application/json")], "{}"),
        ]
    }

    struct Fixture {
        app: Arc<App>,
        who: Vec<Who>,
        counter: AtomicUsize,
        _dir: tempfile::TempDir,
    }

    impl Fixture {
        fn new() -> Self {
            let (app, dir) = app();
            let who = identities(&app, ME);
            Self {
                app,
                who,
                counter: AtomicUsize::new(0),
                _dir: dir,
            }
        }

        fn fresh(&self) -> String {
            format!("fact {}", self.counter.fetch_add(1, Ordering::Relaxed))
        }

        fn proposal(&self) -> String {
            let conn = self.app.db.lock();
            let (proposal, _) = propose(&super::store(&conn), &self.fresh(), "I said so").unwrap();
            format!("/api/memory/proposals/{}", proposal.id)
        }

        fn entry(&self) -> String {
            let conn = self.app.db.lock();
            let entry = note(&super::store(&conn), &self.fresh(), ME).unwrap();
            format!("/api/memory/entries/{}", entry.id)
        }

        fn removed_entry(&self) -> String {
            let conn = self.app.db.lock();
            let store = super::store(&conn);
            let entry = note(&store, &self.fresh(), ME).unwrap();
            store
                .write_note(
                    ME,
                    &edit(Action::Remove, &entry.id, None, Some(entry.revision)),
                    &from_chat(),
                )
                .unwrap();
            format!("/api/memory/entries/{}", entry.id)
        }

        async fn prove(&self, seed: &dyn Fn() -> String) {
            prove_operation(
                &self.app,
                &self.who,
                "POST",
                seed,
                &|| view(&self.app),
                &accepted(),
                &ok,
            )
            .await;
        }
    }

    #[tokio::test]
    async fn approving_a_proposal_needs_the_request_shape() {
        let f = Fixture::new();
        f.prove(&|| format!("{}/approve", f.proposal())).await;
    }

    #[tokio::test]
    async fn rejecting_a_proposal_needs_the_request_shape() {
        let f = Fixture::new();
        f.prove(&|| format!("{}/reject", f.proposal())).await;
    }

    #[tokio::test]
    async fn forgetting_an_entry_needs_the_request_shape() {
        let f = Fixture::new();
        f.prove(&|| format!("{}/forget", f.entry())).await;
    }

    #[tokio::test]
    async fn restoring_an_entry_needs_the_request_shape() {
        let f = Fixture::new();
        f.prove(&|| format!("{}/restore", f.removed_entry())).await;
    }

    #[tokio::test]
    async fn a_form_cannot_turn_a_proposal_into_a_memory() {
        let f = Fixture::new();
        let path = format!("{}/approve", f.proposal());
        let id = path.split('/').nth(4).unwrap().to_owned();
        for who in &f.who {
            for form in crate::request_shape::tests::forged() {
                crate::request_shape::tests::send(&f.app, who, "POST", &path, &form).await;
            }
        }
        let conn = f.app.db.lock();
        let store = super::store(&conn);
        assert_eq!(
            store.proposal(ME, &id).unwrap().status,
            ProposalStatus::Pending
        );
        assert!(store.entries(ME, None, None).unwrap().is_empty());
    }
}
