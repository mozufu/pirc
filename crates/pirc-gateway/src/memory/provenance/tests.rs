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
                pirc_protocol::ModeId::new("chat").unwrap(),
            ),
            (
                "b".into(),
                "B".into(),
                pirc_protocol::ModeId::new("chat").unwrap(),
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

#[test]
fn deleting_an_editor_keeps_other_creators_memory_and_project_scrub_erases_only_its_versions() {
    let db = Db::memory();
    let conn = db.lock();
    seed(&conn);
    let a = session(&conn, "a", "node:a");
    let b = session(&conn, "b", "node:b");
    let (entry, _) = store(&conn)
        .write_note(USER, &note("original A"), &change(&a))
        .unwrap();
    let origin = version(&conn, USER, &entry.id, Some(1)).unwrap();
    store(&conn)
        .write_note(USER, &replace(&entry.id, 1, "edited B"), &change(&b))
        .unwrap();
    let (p, _) = store(&conn)
        .propose(USER, &b, &propose("pending B"), &json!({"sessionId":b}))
        .unwrap();
    store(&conn).forget_session(USER, &b).unwrap();
    assert_eq!(
        store(&conn).entry(USER, &entry.id).unwrap().content,
        "edited B"
    );
    assert_eq!(count(&conn, "memory_version_contexts"), 2);
    assert_eq!(count(&conn, "memory_proposal_contexts"), 0);
    assert!(store(&conn).proposal(USER, &p.id).is_err());
    conn.begin_session_deletion(&b, USER).unwrap();
    conn.finish_session_deletion(&b).unwrap();
    assert_eq!(
        project(&version(&conn, USER, &entry.id, Some(2)).unwrap()),
        Some("node:b")
    );
    store(&conn)
        .delete_project(USER, "node:b", &[], &[])
        .unwrap();
    let restored = store(&conn).entry(USER, &entry.id).unwrap();
    assert_eq!(restored.content, "original A");
    assert_eq!(
        version(&conn, USER, &entry.id, Some(restored.revision)).unwrap(),
        origin
    );
    assert_eq!(count(&conn, "memory_version_contexts"), 2); // original + copied restore; B scrubbed
    store(&conn).forget_session(USER, &a).unwrap();
    assert_eq!(count(&conn, "memory_version_contexts"), 0);
}

#[test]
fn migration_keeps_large_legacy_history_unknown_under_concurrent_opens() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("db");
    let id = {
        let db = Db::open(&path).unwrap();
        let conn = db.lock();
        seed(&conn);
        let id = session(&conn, "writer", "node:a");
        crate::db::atomic(&conn,|tx|{
            for i in 1..=2048 {
                tx.execute("INSERT INTO memory_log(owner_user,entry_id,revision,op,content,origins_json,sources_json,actor,at) VALUES('alice','old',?,'replace',?,'[]',?,'session:legacy',?)",params![i,format!("historical {i}"),json!({"sessionId":id}).to_string(),i])?;
            } Ok(())
        }).unwrap();
        conn.execute("INSERT INTO memory_entries(id,owner_user,kind,content,status,revision,origins_json,sources_json,created_at,updated_at,created_by_session) VALUES('old','alice','note','historical 2048','active',2048,'[]',?,1,2048,?)",params![json!({"sessionId":id}).to_string(),id]).unwrap();
        conn.execute_batch(concat!(
            include_str!("../test_remove_provenance.sql"),
            "PRAGMA user_version=1022;"
        ))
        .unwrap();
        id
    };
    let gate = std::sync::Barrier::new(4);
    std::thread::scope(|scope| {
        let handles: Vec<_> = (0..4)
            .map(|_| {
                scope.spawn(|| {
                    gate.wait();
                    let db = Db::open(&path).unwrap();
                    assert_eq!(count(&db.lock(), "memory_log"), 2048);
                })
            })
            .collect();
        for h in handles {
            h.join().unwrap();
        }
    });
    let db = Db::open(&path).unwrap();
    let conn = db.lock();
    assert_eq!(count(&conn, "memory_version_contexts"), 0);
    assert_eq!(count(&conn, "memory_proposal_contexts"), 0);
    assert_eq!(store(&conn).history(USER, "old").unwrap().len(), 2048);
    assert_eq!(
        store(&conn).entry(USER, "old").unwrap().content,
        "historical 2048"
    );
    assert_eq!(
        version(&conn, USER, "old", Some(1024)).unwrap().source,
        Source::Unknown
    );
    let source: String = conn
        .query_row(
            "SELECT sources_json FROM memory_log WHERE revision=2048",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(source, json!({"sessionId":id}).to_string());
    let (entry, _) = store(&conn)
        .write_note(USER, &note("new after migration"), &change(&id))
        .unwrap();
    assert_eq!(
        project(&version(&conn, USER, &entry.id, Some(1)).unwrap()),
        Some("node:a")
    );
    assert_eq!(count(&conn, "memory_version_contexts"), 1);
}

#[tokio::test]
async fn stale_agent_context_cannot_write_or_propose_under_a_new_environment() {
    let (app, _dir) = crate::memory::tests::app();
    let user = "me@example.com";
    let context = {
        let conn = app.db.lock();
        seed(&conn);
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

#[test]
fn user_edit_of_mixed_project_history_has_no_invented_current_project_source() {
    use crate::memory::store::{ProjectChoice, ProjectDecision};
    let db = Db::memory();
    let conn = db.lock();
    seed(&conn);
    let a = session(&conn, "a", "node:a");
    let b = session(&conn, "b", "node:b");
    let (entry, _) = store(&conn)
        .write_note(USER, &note("A first"), &change(&a))
        .unwrap();
    store(&conn)
        .write_note(USER, &replace(&entry.id, 1, "B middle"), &change(&b))
        .unwrap();
    store(&conn)
        .write_note(USER, &replace(&entry.id, 2, "A last"), &change(&a))
        .unwrap();
    store(&conn)
        .delete_project(
            USER,
            "node:b",
            &[(
                entry.id.clone(),
                ProjectDecision {
                    revision: 3,
                    choice: ProjectChoice::Edit("user reviewed text".into()),
                },
            )],
            &[],
        )
        .unwrap();
    assert_eq!(
        version(&conn, USER, &entry.id, Some(4)).unwrap().source,
        Source::User
    );
    assert_eq!(count(&conn, "memory_version_contexts"), 3); // A first, A last, user edit
    assert_eq!(
        store(&conn).entry(USER, &entry.id).unwrap().content,
        "user reviewed text"
    );
    let scrubbed:Option<String>=conn.query_row("SELECT origin_json FROM memory_version_contexts c JOIN memory_log l ON l.seq=c.log_seq WHERE l.entry_id=? AND l.revision=2",[&entry.id],|r|r.get(0)).optional().unwrap();
    assert!(scrubbed.is_none());
}

#[test]
fn moved_author_history_and_proposals_follow_write_time_project_not_current_session() {
    use crate::memory::store::{ProjectAction, ProjectChoice, ProjectDecision};
    let db = Db::memory();
    let conn = db.lock();
    seed(&conn);
    let c = session(&conn, "mover", "node:a");
    let memory = store(&conn);
    let own = memory
        .write_note(USER, &note("A only"), &change(&c))
        .unwrap()
        .0;
    let mixed = memory
        .write_note(USER, &note("A shared"), &change(&c))
        .unwrap()
        .0;
    let pa = memory
        .propose(USER, &c, &propose("A proposal"), &json!({"sessionId":c}))
        .unwrap()
        .0;
    conn.execute("UPDATE sessions SET workspace_id='node:b' WHERE id=?", [&c])
        .unwrap();
    let mixed = memory
        .write_note(USER, &replace(&mixed.id, 1, "B continuation"), &change(&c))
        .unwrap()
        .0;
    let own_b = memory
        .write_note(USER, &note("B only"), &change(&c))
        .unwrap()
        .0;
    let pb = memory
        .propose(USER, &c, &propose("B proposal"), &json!({"sessionId":c}))
        .unwrap()
        .0;
    let plan = memory.project_plan(USER, "node:a").unwrap();
    assert_eq!(plan.len(), 2);
    assert_eq!(
        plan.iter().find(|p| p.entry.id == own.id).unwrap().action,
        ProjectAction::Forget
    );
    assert_eq!(
        plan.iter().find(|p| p.entry.id == mixed.id).unwrap().action,
        ProjectAction::Review
    );
    assert!(!plan.iter().any(|p| p.unknown_origin));
    let b_plan = memory.project_plan(USER, "node:b").unwrap();
    let rollback = b_plan.iter().find(|p| p.entry.id == mixed.id).unwrap();
    assert_eq!(rollback.action, ProjectAction::Rollback);
    assert_eq!(rollback.restored.as_deref(), Some("A shared"));
    memory
        .delete_project(
            USER,
            "node:a",
            &[(
                mixed.id.clone(),
                ProjectDecision {
                    revision: 2,
                    choice: ProjectChoice::Keep,
                },
            )],
            &[],
        )
        .unwrap();
    assert_eq!(memory.entry(USER, &own.id).unwrap().content, "");
    assert_eq!(memory.entry(USER, &own_b.id).unwrap().content, "B only");
    assert_eq!(
        memory.entry(USER, &mixed.id).unwrap().content,
        "B continuation"
    );
    assert!(memory.proposal(USER, &pa.id).is_err());
    assert_eq!(
        memory.proposal(USER, &pb.id).unwrap().content.as_deref(),
        Some("B proposal")
    );
    assert_eq!(conn.get_session(&c).unwrap().workspace_id, "node:b");
}

#[test]
fn unknown_history_and_proposals_require_explicit_choices_and_current_status() {
    use crate::memory::store::{
        ProjectAction, ProjectChoice, ProjectDecision, ProjectProposalDecision,
    };
    let db = Db::memory();
    let conn = db.lock();
    seed(&conn);
    let c = session(&conn, "writer", "node:b");
    let memory = store(&conn);
    let entry = memory
        .write_note(USER, &note("legacy text"), &change(&c))
        .unwrap()
        .0;
    conn.execute("DELETE FROM memory_version_contexts", [])
        .unwrap();
    let p = memory
        .propose(
            USER,
            &c,
            &propose("legacy proposal"),
            &json!({"sessionId":c}),
        )
        .unwrap()
        .0;
    conn.execute("DELETE FROM memory_proposal_contexts", [])
        .unwrap();
    // B's present membership is not proof of where either old write occurred.
    let plan = memory.project_plan(USER, "node:a").unwrap();
    assert_eq!(plan.len(), 1);
    assert!(plan[0].unknown_origin);
    assert_eq!(plan[0].action, ProjectAction::Review);
    assert_eq!(
        memory.project_proposals(USER, "node:a").unwrap()[0].action,
        ProjectAction::Review
    );
    let entries = [(
        entry.id.clone(),
        ProjectDecision {
            revision: 1,
            choice: ProjectChoice::Edit("legacy text".into()),
        },
    )];
    assert!(
        memory
            .delete_project(USER, "node:a", &entries, &[])
            .is_err()
    );
    assert_eq!(memory.history(USER, &entry.id).unwrap().len(), 1);
    // A concurrent approval/rejection invalidates the previewed proposal status.
    let decisions = [(
        p.id.clone(),
        ProjectProposalDecision {
            status: "pending".into(),
            forget: false,
        },
    )];
    memory.reject(USER, &p.id).unwrap();
    assert!(
        memory
            .delete_project(USER, "node:a", &entries, &decisions)
            .is_err()
    );
    let decisions = [(
        p.id.clone(),
        ProjectProposalDecision {
            status: "rejected".into(),
            forget: false,
        },
    )];
    memory
        .delete_project(USER, "node:a", &entries, &decisions)
        .unwrap();
    let kept = memory.entry(USER, &entry.id).unwrap();
    assert_eq!(kept.revision, 2);
    assert_eq!(
        version(&conn, USER, &entry.id, Some(2)).unwrap().source,
        Source::User
    );
    assert!(
        memory
            .history(USER, &entry.id)
            .unwrap()
            .iter()
            .find(|v| v.revision == 1)
            .unwrap()
            .content
            .is_none()
    );
    assert_eq!(
        memory.proposal(USER, &p.id).unwrap().content.as_deref(),
        Some("legacy proposal")
    );
    assert!(memory.project_plan(USER, "node:a").unwrap().is_empty());
}

#[test]
fn project_cleanup_receipt_survives_restart_and_preserves_later_user_edits() {
    use crate::memory::{
        self,
        store::{ProjectChoice, ProjectDecision},
    };
    let (app, _app_dir) = memory::tests::app();
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("gateway.sqlite");
    let db = Db::open(&path).unwrap();
    let conn = db.lock();
    seed(&conn);
    let a = session(&conn, "a", "node:a");
    let b = session(&conn, "b", "node:b");
    let entry = store(&conn)
        .write_note(USER, &note("created A"), &change(&a))
        .unwrap()
        .0;
    store(&conn)
        .write_note(USER, &replace(&entry.id, 1, "edited B"), &change(&b))
        .unwrap();
    let decisions = [(
        entry.id.clone(),
        ProjectDecision {
            revision: 2,
            choice: ProjectChoice::Keep,
        },
    )];
    crate::db::atomic(&conn, |tx| {
        tx.begin_workspace_deletion("node:a", USER)?;
        memory::delete_project(&app, tx, USER, "node:a", &decisions, &[])
    })
    .unwrap();
    assert!(
        memory::project_plan(&app, &conn, USER, "node:a")
            .unwrap()
            .is_empty()
    );
    // A standalone session-delete request finishing after the project fence
    // must not reinterpret this as the original-creator purge.
    memory::forget_session(&app, &conn, USER, &a).unwrap();
    assert_eq!(
        store(&conn).entry(USER, &entry.id).unwrap().content,
        "edited B"
    );
    let user_change = Change {
        actor: format!("user:{USER}"),
        origins: json!(["user"]),
        sources: json!({}),
    };
    store(&conn)
        .write_note(
            USER,
            &replace(&entry.id, 2, "later user edit"),
            &user_change,
        )
        .unwrap();
    drop(conn);
    drop(db);
    let db = Db::open(&path).unwrap();
    let conn = db.lock();
    assert!(memory::project_cleanup_complete(&conn, USER, "node:a").unwrap());
    assert!(memory::project_cleanup_complete(&conn, "someone else", "node:a").is_err());
    // A stale second-device decision is ignored once that effect committed.
    let stale = [(
        entry.id.clone(),
        ProjectDecision {
            revision: 2,
            choice: ProjectChoice::Forget,
        },
    )];
    memory::delete_project(&app, &conn, USER, "node:a", &stale, &[]).unwrap();
    memory::forget_session(&app, &conn, USER, &a).unwrap();
    conn.finish_session_deletion(&a).unwrap();
    assert_eq!(
        store(&conn).entry(USER, &entry.id).unwrap().content,
        "later user edit"
    );
    assert!(conn.get_session(&b).is_ok());
    assert_eq!(store(&conn).history(USER, &entry.id).unwrap().len(), 3);
}

#[test]
fn memory_conflict_rolls_back_project_fence_and_receipt() {
    use crate::memory;
    let (app, _dir) = memory::tests::app();
    let conn = app.db.lock();
    seed(&conn);
    let a = session(&conn, "a", "node:a");
    let b = session(&conn, "b", "node:b");
    let entry = store(&conn)
        .write_note(USER, &note("A"), &change(&a))
        .unwrap()
        .0;
    store(&conn)
        .write_note(USER, &replace(&entry.id, 1, "B"), &change(&b))
        .unwrap();
    assert!(
        crate::db::atomic(&conn, |tx| {
            tx.begin_workspace_deletion("node:a", USER)?;
            memory::delete_project(&app, tx, USER, "node:a", &[], &[])
        })
        .is_err()
    );
    assert!(conn.workspace_deletion("node:a").unwrap().is_none());
    assert!(conn.session_deletion(&a).unwrap().is_none());
    assert!(!memory::project_cleanup_complete(&conn, USER, "node:a").unwrap());
    assert_eq!(store(&conn).entry(USER, &entry.id).unwrap().content, "B");
}

#[test]
fn two_project_deletions_cannot_overwrite_each_others_reviewed_edit() {
    use crate::memory::{
        self,
        store::{ProjectChoice, ProjectDecision},
    };
    let (app, _appdir) = memory::tests::app();
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("gateway.sqlite");
    let db = Db::open(&path).unwrap();
    let conn = db.lock();
    seed(&conn);
    let a = session(&conn, "a", "node:a");
    let b = session(&conn, "b", "node:b");
    let entry = store(&conn)
        .write_note(USER, &note("A"), &change(&a))
        .unwrap()
        .0;
    store(&conn)
        .write_note(USER, &replace(&entry.id, 1, "B"), &change(&b))
        .unwrap();
    store(&conn)
        .write_note(USER, &replace(&entry.id, 2, "A again"), &change(&a))
        .unwrap();
    drop(conn);
    drop(db);
    let barrier = std::sync::Arc::new(std::sync::Barrier::new(2));
    let joins: Vec<_> = ["node:a", "node:b"]
        .into_iter()
        .map(|scope| {
            let app = app.clone();
            let path = path.clone();
            let barrier = barrier.clone();
            let id = entry.id.clone();
            std::thread::spawn(move || {
                let db = Db::open(&path).unwrap();
                let conn = db.lock();
                let plan = store(&conn).project_plan(USER, scope).unwrap();
                assert_eq!(plan[0].entry.revision, 3);
                barrier.wait();
                crate::db::atomic(&conn, |tx| {
                    tx.begin_workspace_deletion(scope, USER)?;
                    memory::delete_project(
                        &app,
                        tx,
                        USER,
                        scope,
                        &[(
                            id,
                            ProjectDecision {
                                revision: 3,
                                choice: ProjectChoice::Edit(format!("reviewed {scope}")),
                            },
                        )],
                        &[],
                    )
                })
                .map(|()| scope.to_owned())
                .map_err(|e| e.code)
            })
        })
        .collect();
    let results: Vec<_> = joins.into_iter().map(|j| j.join().unwrap()).collect();
    assert_eq!(results.iter().filter(|r| r.is_ok()).count(), 1);
    assert_eq!(results.iter().filter(|r| **r == Err("conflict")).count(), 1);
    let winner = results.into_iter().find_map(Result::ok).unwrap();
    let db = Db::open(&path).unwrap();
    let conn = db.lock();
    assert_eq!(
        store(&conn).entry(USER, &entry.id).unwrap().content,
        format!("reviewed {winner}")
    );
    assert_eq!(count(&conn, "project_memory_cleanup"), 1);
    assert_eq!(count(&conn, "workspace_deletions"), 1);
}

#[test]
fn large_history_review_scrubs_only_selected_origins_and_preserves_outside_versions() {
    use crate::memory::store::{ProjectChoice, ProjectDecision};
    let db = Db::memory();
    let conn = db.lock();
    seed(&conn);
    let a = session(&conn, "a", "node:a");
    let b = session(&conn, "b", "node:b");
    let memory = store(&conn);
    let entry = memory
        .write_note(USER, &note("first A"), &change(&a))
        .unwrap()
        .0;
    crate::db::atomic(&conn, |_| {
        for n in 2..=2000 {
            memory.write_note(
                USER,
                &replace(&entry.id, n - 1, &format!("version {n}")),
                &change(if n % 2 == 0 { &b } else { &a }),
            )?;
        }
        Ok(())
    })
    .unwrap();
    let plan = memory.project_plan(USER, "node:a").unwrap();
    assert_eq!(plan.len(), 1);
    assert_eq!(plan[0].entry.revision, 2000);
    assert!(
        memory
            .delete_project(
                USER,
                "node:a",
                &[(
                    entry.id.clone(),
                    ProjectDecision {
                        revision: 1999,
                        choice: ProjectChoice::Forget
                    }
                )],
                &[]
            )
            .is_err()
    );
    memory
        .delete_project(
            USER,
            "node:a",
            &[(
                entry.id.clone(),
                ProjectDecision {
                    revision: 2000,
                    choice: ProjectChoice::Edit("reviewed user text".into()),
                },
            )],
            &[],
        )
        .unwrap();
    let history = memory.history(USER, &entry.id).unwrap();
    assert_eq!(history.len(), 2001);
    assert_eq!(history.iter().filter(|v| v.content.is_some()).count(), 1001);
    assert_eq!(count(&conn, "memory_version_contexts"), 1001);
    assert!(memory.project_plan(USER, "node:a").unwrap().is_empty());
    assert_eq!(
        version(&conn, USER, &entry.id, Some(2))
            .unwrap()
            .relation("node:b"),
        Relation::Project
    );
}

#[test]
fn migration_from_1023_does_not_invent_cleanup_receipts() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("gateway.sqlite");
    let db = Db::open(&path).unwrap();
    let conn = db.lock();
    seed(&conn);
    let a = session(&conn, "a", "node:a");
    let entry = store(&conn)
        .write_note(USER, &note("kept"), &change(&a))
        .unwrap()
        .0;
    conn.begin_workspace_deletion("node:a", USER).unwrap();
    conn.execute_batch("DROP TABLE conversation_transition_previews; DROP TRIGGER command_environment_immutable; DROP TABLE command_environments; DROP TABLE project_memory_cleanup_sessions; DROP TABLE project_memory_cleanup; PRAGMA user_version=1023;").unwrap();
    drop(conn);
    drop(db);
    let db = Db::open(&path).unwrap();
    let conn = db.lock();
    assert_eq!(count(&conn, "project_memory_cleanup"), 0);
    assert_eq!(
        conn.query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        crate::db::SCHEMA_VERSION
    );
    assert!(conn.workspace_deletion("node:a").unwrap().is_some());
    assert_eq!(store(&conn).entry(USER, &entry.id).unwrap().content, "kept");
    assert_eq!(
        version(&conn, USER, &entry.id, Some(1))
            .unwrap()
            .relation("node:a"),
        Relation::Project
    );
}

#[test]
fn stale_review_cannot_become_an_automatic_forget_after_another_project_rolled_back() {
    use crate::memory::store::{ProjectAction, ProjectChoice, ProjectDecision};
    let db = Db::memory();
    let conn = db.lock();
    seed(&conn);
    let a = session(&conn, "a", "node:a");
    let b = session(&conn, "b", "node:b");
    let memory = store(&conn);
    let entry = memory
        .write_note(USER, &note("original A"), &change(&a))
        .unwrap()
        .0;
    memory
        .write_note(USER, &replace(&entry.id, 1, "B edit"), &change(&b))
        .unwrap();
    assert_eq!(
        memory.project_plan(USER, "node:a").unwrap()[0].action,
        ProjectAction::Review
    );
    let decision = [(
        entry.id.clone(),
        ProjectDecision {
            revision: 2,
            choice: ProjectChoice::Keep,
        },
    )];
    memory.delete_project(USER, "node:b", &[], &[]).unwrap();
    assert_eq!(
        memory.project_plan(USER, "node:a").unwrap()[0].action,
        ProjectAction::Forget
    );
    assert_eq!(
        memory
            .delete_project(USER, "node:a", &decision, &[])
            .unwrap_err()
            .code,
        "conflict"
    );
    assert_eq!(memory.entry(USER, &entry.id).unwrap().content, "original A");
}
