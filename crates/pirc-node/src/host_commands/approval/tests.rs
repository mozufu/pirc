use super::*;
use crate::{
    store::{Db, Store},
    workspace_memory::tests::Fixture,
};
use serde_json::json;
use std::path::Path;
use tokio::sync::watch;

// These fixtures exercise the real durable confirmation claim. This helper is
// unavailable to product code and is never an alternative production grant.
pub(crate) fn issue(
    db: &Connection,
    node: &Node,
    request: Request<'_>,
    confirmed: bool,
) -> ApiResult<String> {
    let interaction = crate::store::atomic(db, |db| {
        let dialog =
            json!({"type":"extension_ui_request","method":"confirm","title":"Host management"});
        let interaction = db.create_interaction(
            request.session,
            request.epoch,
            &format!("node-sandbox-{}", crate::util::uuid()),
            "confirm",
            dialog.as_object().unwrap(),
            now_ms() + 60_000,
        )?;
        record(db, node, request, &interaction.id)?;
        Ok(interaction)
    })?;
    db.claim_interaction(
        &interaction.id,
        &interaction.session_id,
        interaction.runner_epoch,
        &json!({"confirmed":confirmed}),
    )?;
    Ok(interaction.id)
}
fn grant(f: &Fixture, request: &str, confirmed: bool) -> Origin {
    let mut origin = super::super::tests::origin(f, &f.current, request);
    let hash = "a".repeat(64);
    let interaction = issue(
        &f.node.db.lock(),
        &f.node,
        Request {
            session: &origin.session,
            workspace: &origin.workspace,
            epoch: origin.epoch,
            request: &origin.request,
            intent_hash: &hash,
        },
        confirmed,
    )
    .unwrap();
    origin.authority = Authority::HostManagement {
        interaction,
        intent_hash: hash,
    };
    origin
}
fn start(f: &Fixture, origin: Origin, text: &str) -> ApiResult<super::super::Ticket> {
    let mut command = crate::runner::host::command(&f.node.env, text, Path::new("/"));
    let source = watch::channel(false);
    // Keep the cancellation source alive for this short synchronous admission.
    f.node
        .host_commands
        .start(&f.node, &f.node.db.lock(), origin, &mut command, source.1)
}
#[tokio::test]
async fn answered_approval_is_consumed_with_launch_and_cannot_authorize_a_second_request() {
    let f = Fixture::new().await;
    let origin = grant(&f, "one", true);
    let Authority::HostManagement { interaction, .. } = &origin.authority else {
        unreachable!()
    };
    let interaction = interaction.clone();
    // Keep the source alive until the independent observer completes.
    let (_source, source) = watch::channel(false);
    let mut command = crate::runner::host::command(&f.node.env, "printf approved", Path::new("/"));
    let ticket = f
        .node
        .host_commands
        .start(
            &f.node,
            &f.node.db.lock(),
            origin,
            &mut command,
            source.clone(),
        )
        .unwrap();
    let run: String = f
        .node
        .db
        .lock()
        .query_row(
            "SELECT run_id FROM host_execution_approvals WHERE interaction_id=?1",
            [&interaction],
            |r| r.get(0),
        )
        .unwrap();
    assert!(!run.is_empty());
    assert_eq!(ticket.result().await.unwrap()["output"], "approved");
    let mut origin = super::super::tests::origin(&f, &f.current, "different");
    origin.authority = Authority::HostManagement {
        interaction,
        intent_hash: "a".repeat(64),
    };
    assert_eq!(
        start(&f, origin, "true").err().unwrap().code,
        "host_management_approval_required"
    );
    f.node.close().await;
}
#[tokio::test]
async fn declined_pending_expired_or_model_created_confirmations_never_start() {
    let f = Fixture::new().await;
    for (name, status, expires) in [
        ("declined", "answered", false),
        ("pending", "pending", false),
        ("expired", "answered", true),
    ] {
        let origin = grant(&f, name, name != "declined");
        let Authority::HostManagement { interaction, .. } = &origin.authority else {
            unreachable!()
        };
        f.node.db.lock().execute("UPDATE interactions SET status=?2,expires_at=CASE WHEN ?3 THEN 1 ELSE expires_at END WHERE id=?1",params![interaction,status,expires]).unwrap();
        assert_eq!(
            start(&f, origin, "true").err().unwrap().code,
            "host_management_approval_required"
        );
    }
    let mut origin = super::super::tests::origin(&f, &f.current, "forged");
    let dialog =
        json!({"method":"confirm","title":"Host management","executionPath":"host_management"});
    let fake = {
        let db = f.node.db.lock();
        let fake = db
            .create_interaction(
                &f.current,
                origin.epoch,
                "node-sandbox-forged",
                "confirm",
                dialog.as_object().unwrap(),
                now_ms() + 60_000,
            )
            .unwrap();
        db.claim_interaction(
            &fake.id,
            &f.current,
            origin.epoch,
            &json!({"confirmed":true}),
        )
        .unwrap();
        fake
    };
    origin.authority = Authority::HostManagement {
        interaction: fake.id,
        intent_hash: "a".repeat(64),
    };
    assert_eq!(
        start(&f, origin, "true").err().unwrap().code,
        "host_management_approval_required"
    );
    assert_eq!(
        f.node
            .db
            .lock()
            .query_row("SELECT count(*) FROM host_command_runs", [], |r| r
                .get::<_, i64>(0))
            .unwrap(),
        0
    );
    f.node.close().await;
}
#[tokio::test]
async fn changed_intent_origin_or_incarnation_cannot_inherit_the_grant() {
    let f = Fixture::new().await;
    for n in 0..5 {
        let mut origin = grant(&f, &format!("request-{n}"), true);
        match n {
            0 => {
                if let Authority::HostManagement { intent_hash, .. } = &mut origin.authority {
                    *intent_hash = "b".repeat(64)
                }
            }
            1 => origin.request = "replacement".into(),
            2 => origin.workspace = "replacement".into(),
            3 => origin.epoch += 1,
            _ => {
                f.node.db.lock().execute_batch("DROP TRIGGER host_approval_identity; UPDATE host_execution_approvals SET incarnation='earlier-node';").unwrap();
            }
        }
        assert!(start(&f, origin, "true").is_err());
    }
    f.node.close().await;
}
#[tokio::test]
async fn failed_consumption_rolls_back_the_launch_before_any_command_runs() {
    let f = Fixture::new().await;
    let origin = grant(&f, "full", true);
    let marker = f.dir.join("must-not-be-created");
    f.node.db.lock().execute_batch("CREATE TRIGGER fail_consumption BEFORE UPDATE OF run_id ON host_execution_approvals BEGIN SELECT RAISE(ABORT,'disk full'); END;").unwrap();
    assert!(start(&f, origin, &format!("touch '{}'", marker.display())).is_err());
    assert!(!marker.exists());
    {
        let db = f.node.db.lock();
        assert_eq!(
            db.query_row("SELECT count(*) FROM host_command_runs", [], |r| r
                .get::<_, i64>(0))
                .unwrap(),
            0
        );
        assert_eq!(
            db.query_row("SELECT count(*) FROM host_command_resources", [], |r| r
                .get::<_, i64>(0))
                .unwrap(),
            0
        );
        assert_eq!(
            db.query_row(
                "SELECT count(*) FROM host_execution_approvals WHERE run_id IS NULL",
                [],
                |r| r.get::<_, i64>(0)
            )
            .unwrap(),
            1
        );
    }
    f.node.close().await;
}
#[tokio::test]
async fn grant_identity_survives_session_deletion_without_regranting() {
    let f = Fixture::new().await;
    let origin = grant(&f, "retained", true);
    {
        let db = f.node.db.lock();
        assert!(
            db.execute(
                "UPDATE host_execution_approvals SET intent_hash=?1",
                ["b".repeat(64)]
            )
            .is_err()
        );
        assert!(
            db.execute("DELETE FROM host_execution_approvals", [])
                .is_err()
        );
        db.begin_session_deletion(&f.current, "alice").unwrap();
        db.finish_session_deletion(&f.current).unwrap();
        assert_eq!(
            db.query_row("SELECT count(*) FROM host_execution_approvals", [], |r| r
                .get::<_, i64>(
                0
            ))
            .unwrap(),
            1
        );
        assert!(origin.authority.validate(&db, &f.node, &origin).is_err());
    }
    f.node.close().await;
}
#[test]
fn migration_preserves_legacy_runs_without_inventing_user_approvals() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("node.sqlite");
    {
        let db = Db::open(&file).unwrap();
        let db = db.lock();
        db.execute("INSERT INTO host_command_runs VALUES('old','old-session','old-workspace',0,'old-node','old-request','settled',1,1)",[]).unwrap();
        db.execute_batch(include_str!("../remove_approval.sql"))
            .unwrap();
        db.pragma_update(None, "user_version", 2022).unwrap();
    }
    let db = Db::open(&file).unwrap();
    let db = db.lock();
    assert_eq!(
        db.query_row("SELECT count(*) FROM host_execution_approvals", [], |r| r
            .get::<_, i64>(
            0
        ))
        .unwrap(),
        0
    );
    assert_eq!(
        db.query_row(
            "SELECT state FROM host_command_runs WHERE id='old'",
            [],
            |r| r.get::<_, String>(0)
        )
        .unwrap(),
        "settled"
    );
    assert_eq!(
        db.pragma_query_value(None, "user_version", |r| r.get::<_, i64>(0))
            .unwrap(),
        2023
    );
}

#[tokio::test]
async fn failed_or_duplicate_question_reservation_does_not_leave_a_pending_dialog() {
    let f = Fixture::new().await;
    let request = || Request {
        session: &f.current,
        workspace: "repo",
        epoch: 0,
        request: "same",
        intent_hash: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    };
    f.node.db.lock().execute_batch("CREATE TRIGGER fail_question BEFORE INSERT ON host_execution_approvals BEGIN SELECT RAISE(ABORT,'disk full'); END;").unwrap();
    assert!(issue(&f.node.db.lock(), &f.node, request(), true).is_err());
    assert_eq!(
        f.node
            .db
            .lock()
            .query_row("SELECT count(*) FROM interactions", [], |r| r
                .get::<_, i64>(0))
            .unwrap(),
        0
    );
    f.node
        .db
        .lock()
        .execute_batch("DROP TRIGGER fail_question")
        .unwrap();
    issue(&f.node.db.lock(), &f.node, request(), true).unwrap();
    assert!(issue(&f.node.db.lock(), &f.node, request(), true).is_err());
    assert_eq!(
        f.node
            .db
            .lock()
            .query_row("SELECT count(*) FROM interactions", [], |r| r
                .get::<_, i64>(0))
            .unwrap(),
        1
    );
    f.node.close().await;
}
