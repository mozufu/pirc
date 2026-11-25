use super::*;
use crate::{
    db::{CapabilitiesPatch, Db, Store as _},
    memory::store::{Action, Budgets, Change, NoteInput, ProposeInput, Store},
};
use serde_json::json;

const USER: &str = "alice";
fn seed(conn: &Connection) {
    conn.sync_remote_workspaces(
        "node",
        &[
            (
                "a".into(),
                "A".into(),
                pirc_protocol::ModeId::new("directory").unwrap(),
            ),
            (
                "b".into(),
                "B".into(),
                pirc_protocol::ModeId::new("directory").unwrap(),
            ),
        ],
    )
    .unwrap();
    policies::install_catalog(conn, &crate::app::test_modes()).unwrap();
}
fn session(conn: &Connection, name: &str, workspace: &str) -> String {
    conn.create_session(
        workspace,
        &format!("node://node/{name}"),
        "node",
        name,
        USER,
    )
    .unwrap()
    .id
}
fn store(conn: &Connection) -> Store<'_> {
    Store::new(
        conn,
        Budgets {
            user: 100000,
            note: 100000,
        },
    )
}
fn change(id: &str) -> Change {
    Change {
        actor: format!("session:{id}"),
        origins: json!(["assistant"]),
        sources: json!({"sessionId":id,"projectWorkspaceId":"forged-project-label"}),
    }
}
fn note(content: &str) -> NoteInput {
    NoteInput {
        action: Action::Add,
        id: None,
        content: Some(content.into()),
        base_revision: None,
    }
}
fn replace(id: &str, revision: i64, content: &str) -> NoteInput {
    NoteInput {
        action: Action::Replace,
        id: Some(id.into()),
        content: Some(content.into()),
        base_revision: Some(revision),
    }
}
fn propose(content: &str) -> ProposeInput {
    ProposeInput {
        action: Action::Add,
        id: None,
        content: Some(content.into()),
        base_revision: None,
        quote: content.into(),
    }
}
fn project(origin: &Snapshot) -> Option<&str> {
    match &origin.source {
        Source::Session {
            project_workspace_id,
            ..
        } => project_workspace_id.as_deref(),
        _ => None,
    }
}
fn count(conn: &Connection, table: &str) -> i64 {
    conn.query_row(&format!("SELECT count(*) FROM {table}"), [], |r| r.get(0))
        .unwrap()
}

#[test]
fn source_is_frozen_at_each_write_and_restore_does_not_reassign_it_to_current_project() {
    let db = Db::memory();
    let conn = db.lock();
    seed(&conn);
    let id = session(&conn, "writer", "node:a");
    let memory = store(&conn);
    let (entry, _) = memory
        .write_note(USER, &note("from A"), &change(&id))
        .unwrap();
    let first = version(&conn, USER, &entry.id, Some(1)).unwrap();
    assert_eq!(project(&first), Some("node:a"));
    conn.execute(
        "UPDATE sessions SET workspace_id='node:b' WHERE id=?",
        [&id],
    )
    .unwrap();
    let (second, _) = memory
        .write_note(USER, &replace(&entry.id, 1, "from B"), &change(&id))
        .unwrap();
    assert_eq!(version(&conn, USER, &entry.id, Some(1)).unwrap(), first);
    let second_origin = version(&conn, USER, &entry.id, Some(2)).unwrap();
    assert_eq!(project(&second_origin), Some("node:b"));
    assert!(matches!(
        second_origin.source,
        Source::Session {
            membership_revision: 2,
            binding_generation: 2,
            ..
        }
    ));
    let restored = memory.restore(USER, &entry.id, Some(1)).unwrap();
    assert_eq!(restored.content, "from A");
    assert_eq!(
        version(&conn, USER, &entry.id, Some(restored.revision)).unwrap(),
        first
    );
    let remove = NoteInput {
        action: Action::Remove,
        id: Some(entry.id.clone()),
        content: None,
        base_revision: Some(restored.revision),
    };
    memory.write_note(USER, &remove, &change(&id)).unwrap();
    assert_eq!(count(&conn, "memory_version_contexts"), 3); // contentless remove adds no source
    let restored = memory.restore(USER, &entry.id, None).unwrap();
    assert_eq!(
        version(&conn, USER, &entry.id, Some(restored.revision)).unwrap(),
        first
    );
    let creator: String = conn
        .query_row(
            "SELECT created_by_session FROM memory_entries WHERE id=?",
            [&entry.id],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(creator, id);
    assert_eq!(second.revision, 2);
    assert!(
        conn.execute(
            r#"UPDATE memory_version_contexts SET origin_json='{"version":1,"kind":"user"}'"#,
            []
        )
        .is_err()
    );
}

#[test]
fn approval_keeps_proposal_origin_across_move_duplicate_and_gateway_restart() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("db");
    let (proposal_id, origin) = {
        let db = Db::open(&path).unwrap();
        let conn = db.lock();
        seed(&conn);
        let id = session(&conn, "writer", "node:a");
        let input = propose("prefers tea");
        let (p, _) = store(&conn)
            .propose(USER, &id, &input, &json!({"sessionId":id}))
            .unwrap();
        let original = proposal(&conn, USER, &p.id).unwrap();
        conn.execute(
            "UPDATE sessions SET workspace_id='node:b' WHERE id=?",
            [&id],
        )
        .unwrap();
        let (duplicate, reused) = store(&conn)
            .propose(USER, &id, &input, &json!({"sessionId":id}))
            .unwrap();
        assert!(reused);
        assert_eq!(duplicate.id, p.id);
        assert_eq!(proposal(&conn, USER, &p.id).unwrap(), original);
        (p.id, original)
    };
    let db = Db::open(&path).unwrap();
    let conn = db.lock();
    let (_, entry) = store(&conn).approve(USER, &proposal_id, None).unwrap();
    assert_eq!(version(&conn, USER, &entry.id, Some(1)).unwrap(), origin);
    assert_eq!(project(&origin), Some("node:a"));
    assert!(
        conn.execute(
            r#"UPDATE memory_proposal_contexts SET origin_json='{"version":1,"kind":"user"}'"#,
            []
        )
        .is_err()
    );
    store(&conn).forget(USER, &entry.id).unwrap();
    assert_eq!(count(&conn, "memory_version_contexts"), 0);
    assert_eq!(count(&conn, "memory_proposal_contexts"), 0);
    assert_eq!(count(&conn, "memory_log"), 1); // the content-free Forget audit row only
}

#[test]
fn unknown_legacy_proposal_and_restore_never_use_todays_membership() {
    let db = Db::memory();
    let conn = db.lock();
    seed(&conn);
    let id = session(&conn, "writer", "node:a");
    let (p, _) = store(&conn)
        .propose(
            USER,
            &id,
            &propose("legacy preference"),
            &json!({"sessionId":id}),
        )
        .unwrap();
    conn.execute(
        "DELETE FROM memory_proposal_contexts WHERE proposal_id=?",
        [&p.id],
    )
    .unwrap();
    conn.execute(
        "UPDATE sessions SET workspace_id='node:b' WHERE id=?",
        [&id],
    )
    .unwrap();
    let (_, entry) = store(&conn).approve(USER, &p.id, None).unwrap();
    assert_eq!(
        version(&conn, USER, &entry.id, Some(1)).unwrap().source,
        Source::Unknown
    );
    let (n, _) = store(&conn)
        .write_note(USER, &note("old text"), &change(&id))
        .unwrap();
    conn.execute("DELETE FROM memory_version_contexts", [])
        .unwrap();
    store(&conn)
        .write_note(USER, &replace(&n.id, 1, "new text"), &change(&id))
        .unwrap();
    let restored = store(&conn).restore(USER, &n.id, Some(1)).unwrap();
    assert_eq!(
        version(&conn, USER, &n.id, Some(restored.revision))
            .unwrap()
            .source,
        Source::Unknown
    );
}

#[test]
fn concurrent_editors_keep_one_revision_and_its_actual_writer_without_changing_creator() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("db");
    let (a, b, entry) = {
        let db = Db::open(&path).unwrap();
        let conn = db.lock();
        seed(&conn);
        let a = session(&conn, "a", "node:a");
        let b = session(&conn, "b", "node:b");
        let (entry, _) = store(&conn)
            .write_note(USER, &note("original"), &change(&a))
            .unwrap();
        (a, b, entry.id)
    };
    let gate = std::sync::Barrier::new(2);
    let results = std::thread::scope(|scope| {
        let handles: Vec<_> = [(&a, "A edit"), (&b, "B edit")]
            .into_iter()
            .map(|(id, text)| {
                let path = &path;
                let entry = &entry;
                let gate = &gate;
                scope.spawn(move || {
                    let db = Db::open(path).unwrap();
                    gate.wait();
                    store(&db.lock())
                        .write_note(USER, &replace(entry, 1, text), &change(id))
                        .map(|v| (id.clone(), v.0))
                })
            })
            .collect();
        handles
            .into_iter()
            .map(|h| h.join().unwrap())
            .collect::<Vec<_>>()
    });
    assert_eq!(results.iter().filter(|r| r.is_ok()).count(), 1);
    let db = Db::open(&path).unwrap();
    let conn = db.lock();
    let (writer, latest) = results.iter().find_map(|r| r.as_ref().ok()).unwrap();
    let origin = version(&conn, USER, &entry, Some(2)).unwrap();
    assert!(matches!(origin.source,Source::Session {ref session_id,..} if session_id==writer));
    assert_eq!(
        store(&conn).entry(USER, &entry).unwrap().content,
        latest.content
    );
    assert_eq!(count(&conn, "memory_version_contexts"), 2);
    let creator: String = conn
        .query_row(
            "SELECT created_by_session FROM memory_entries WHERE id=?",
            [&entry],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(creator, a);
}

#[test]
fn provenance_failure_and_cross_owner_source_roll_back_the_memory_write() {
    let db = Db::memory();
    let conn = db.lock();
    seed(&conn);
    let id = session(&conn, "writer", "node:a");
    conn.execute_batch("CREATE TRIGGER fail_origin BEFORE INSERT ON memory_version_contexts BEGIN SELECT RAISE(ABORT,'disk error'); END;").unwrap();
    assert!(
        store(&conn)
            .write_note(USER, &note("must not survive"), &change(&id))
            .is_err()
    );
    assert_eq!(count(&conn, "memory_entries"), 0);
    assert_eq!(count(&conn, "memory_log"), 0);
    conn.execute_batch("DROP TRIGGER fail_origin; CREATE TRIGGER fail_proposal_origin BEFORE INSERT ON memory_proposal_contexts BEGIN SELECT RAISE(ABORT,'disk error'); END;").unwrap();
    assert!(
        store(&conn)
            .propose(
                USER,
                &id,
                &propose("must not survive"),
                &json!({"sessionId":id})
            )
            .is_err()
    );
    assert_eq!(count(&conn, "memory_proposals"), 0);
    conn.execute("UPDATE sessions SET owner_user='bob' WHERE id=?", [&id])
        .unwrap();
    assert_eq!(
        store(&conn)
            .write_note(USER, &note("foreign source"), &change(&id))
            .unwrap_err()
            .status,
        403
    );
    assert_eq!(count(&conn, "memory_entries"), 0);
}

#[tokio::test]
async fn stale_agent_context_cannot_write_or_propose_under_a_new_environment() {
    let (app, _dir) = crate::memory::tests::app();
    let user = "me@example.com";
    let mut mode = pirc_protocol::mode::default_work();
    mode.id = pirc_protocol::ModeId::new("assistant").unwrap();
    mode.workdir = pirc_protocol::mode::Workdir::PerSession;
    mode.assistant = pirc_protocol::mode::AssistantAccess::Full;
    mode.repository = false;
    mode.workspace_memory = false;
    mode.project_config = false;
    let mut catalog = (*app.catalog()).clone();
    catalog.modes.insert(mode.id.clone(), mode);
    app.replace_catalog(catalog).unwrap();
    let context = {
        let conn = app.db.lock();
        seed(&conn);
        conn.execute(
            "UPDATE workspaces SET kind='assistant' WHERE id='node:a'",
            [],
        )
        .unwrap();
        let id = session(&conn, "writer", "node:a");
        conn.execute(
            "UPDATE sessions SET owner_user=? WHERE id=?",
            params![user, id],
        )
        .unwrap();
        let session = conn.get_session(&id).unwrap();
        let workspace = conn.get_workspace("node:a").unwrap();
        crate::agent_ops::OpContext {
            mode: app.require_mode(&workspace).unwrap(),
            session,
            workspace,
            user: user.into(),
        }
    };
    app.db
        .lock()
        .patch_workspace_capabilities(
            "node:a",
            &serde_json::from_value::<CapabilitiesPatch>(json!({"web_search":false})).unwrap(),
        )
        .unwrap();
    for (op, args) in [
        (
            "memory.note",
            json!({"action":"add","content":"new note","origins":["assistant"]}),
        ),
        (
            "memory.proposeUser",
            json!({"action":"add","content":"new fact","quote":"my words","entryIds":["entry-1"]}),
        ),
    ] {
        let parsed = crate::memory::parse_op(op, &args).unwrap().unwrap();
        let error = crate::memory::run_op(&app, &context, parsed)
            .await
            .unwrap_err();
        assert_eq!(error.code, "stale_environment");
    }
    assert_eq!(count(&app.db.lock(), "memory_entries"), 0);
    assert_eq!(count(&app.db.lock(), "memory_proposals"), 0);
    let mut fresh = context;
    fresh.session = app.db.lock().get_session(&fresh.session.id).unwrap();
    let parsed = crate::memory::parse_op(
        "memory.note",
        &json!({"action":"add","content":"new note","origins":["assistant"]}),
    )
    .unwrap()
    .unwrap();
    let result = crate::memory::run_op(&app, &fresh, parsed).await.unwrap();
    let origin = version(
        &app.db.lock(),
        user,
        result["id"].as_str().unwrap(),
        Some(1),
    )
    .unwrap();
    assert!(matches!(
        origin.source,
        Source::Session {
            binding_generation: 2,
            workspace_policy_revision: 2,
            ..
        }
    ));
}
