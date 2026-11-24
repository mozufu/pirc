use super::store::*;
use crate::db::{Db, Store};
use serde_json::json;

pub(super) fn input(name: &str) -> PotInput {
    serde_json::from_value(json!({
        "profile": { "name": name, "avatarColor": 2, "personality": "Calm and exact." },
        "work": { "intro": "Tests things", "description": "Runs the nightly checks.",
                  "responsibilities": [{ "title": "Nightly tests" }, { "title": "Flaky tests", "detail": "Track them" }] },
        "permissions": { "reach": "work",
            "observe": [{ "kind": "workspace", "ref": "node:repo", "lead": true }, { "kind": "calendar" }],
            "dm": { "send": "all", "receive": "selected" },
            "workLocations": [{ "workspaceId": "node:repo", "access": "write" }],
            "maxConcurrentWorks": 2, "budgetMoneyMonthMicros": 20_000_000, "budgetTokensDay": 500_000 },
        "models": { "main": { "provider": "oauth:anthropic", "model": "claude-fable-5" },
            "fallbacks": [{ "provider": "work-openai", "model": "gpt-5" }],
            "thinking": "medium", "thinkingAuto": true,
            "workModels": [{ "provider": "oauth:anthropic", "model": "claude-fable-5", "mode": "direct" },
                           { "provider": "oauth:anthropic", "model": "claude-opus-5", "mode": "ask" }] }
    }))
    .unwrap()
}

pub(super) fn db_setup(conn: &rusqlite::Connection) {
    conn.sync_remote_workspaces(
        "node",
        &[(
            "repo".into(),
            "Repo".into(),
            pirc_protocol::ModeId::new("directory").unwrap(),
        )],
    )
    .unwrap();
}

fn db() -> Db {
    let db = Db::memory();
    db_setup(&db.lock());
    db
}

#[test]
fn a_pot_is_created_with_every_section_and_reads_back_the_same() {
    let db = db();
    let mut conn = db.lock();
    let pot = create(&mut conn, "alice", input("Tester")).unwrap();
    assert_eq!(pot.state, PotState::Active);
    assert_eq!(pot.revision, 1);
    assert_eq!(pot.input.work.responsibilities.len(), 2);
    assert_eq!(pot.input.models.fallbacks[0].model, "gpt-5");
    assert_eq!(pot.input.autonomy.interval_s, Some(172_800));
    let mut expected = input("Tester");
    // Scopes and models come back in a stable order.
    expected
        .permissions
        .observe
        .sort_by(|a, b| a.kind.as_str().cmp(b.kind.as_str()));
    assert_eq!(pot.input, expected);
    assert_eq!(read(&conn, "alice", &pot.id).unwrap(), pot);
    // Another owner sees nothing.
    assert_eq!(read(&conn, "bob", &pot.id).unwrap_err().status, 404);
    assert!(list(&conn, "bob").unwrap().is_empty());
    assert_eq!(list(&conn, "alice").unwrap(), vec![pot]);
}

#[test]
fn permissions_grant_nothing_beyond_their_reach_and_limits_stay_finite() {
    let db = db();
    let mut conn = db.lock();
    let mut answering = input("Answers");
    answering.permissions.reach = Reach::Answer;
    let error = create(&mut conn, "alice", answering.clone()).unwrap_err();
    assert_eq!(error.status, 400, "work locations need the work reach");
    answering.permissions.work_locations.clear();
    answering.models.work_models.clear();
    assert_eq!(
        create(&mut conn, "alice", answering.clone())
            .unwrap_err()
            .status,
        400,
        "and observing needs observe"
    );
    answering.permissions.observe.clear();
    create(&mut conn, "alice", answering).unwrap();

    // Budgets are required fields: an omitted one is invalid, never unlimited.
    let mut value = serde_json::to_value(input("No budget")).unwrap();
    value["permissions"]
        .as_object_mut()
        .unwrap()
        .remove("budgetTokensDay");
    assert!(serde_json::from_value::<PotInput>(value).is_err());

    let mut bad = input("Bad");
    bad.permissions.work_locations[0].workspace_id = "node:unknown".into();
    assert_eq!(create(&mut conn, "alice", bad).unwrap_err().status, 400);
    let mut bad = input("Bad");
    bad.permissions.dm.send_to = vec!["pot-of-someone-else".into()];
    assert_eq!(create(&mut conn, "alice", bad).unwrap_err().status, 400);
    let mut bad = input("Bad");
    bad.autonomy.interval_s = Some(60);
    assert_eq!(create(&mut conn, "alice", bad).unwrap_err().status, 400);
    let mut bad = input("");
    bad.profile.name = "   ".into();
    assert_eq!(create(&mut conn, "alice", bad).unwrap_err().status, 400);
}

#[test]
fn updates_replace_sections_under_a_revision_check() {
    let db = db();
    let mut conn = db.lock();
    let peer = create(&mut conn, "alice", input("Researcher")).unwrap();
    let pot = create(&mut conn, "alice", input("Tester")).unwrap();
    let mut permissions = pot.input.permissions.clone();
    permissions.dm.receive_from = vec![peer.id.clone()];
    permissions.max_concurrent_works = 4;
    let updated = update(
        &mut conn,
        "alice",
        &pot.id,
        PotPatch {
            revision: 1,
            permissions: Some(permissions),
            autonomy: Some(Autonomy { interval_s: None }),
            ..Default::default()
        },
    )
    .unwrap();
    assert_eq!(updated.revision, 2);
    assert_eq!(
        updated.input.permissions.dm.receive_from,
        vec![peer.id.clone()]
    );
    assert_eq!(updated.input.permissions.max_concurrent_works, 4);
    assert_eq!(updated.input.autonomy.interval_s, None);
    // Untouched sections stay.
    assert_eq!(updated.input.models, pot.input.models);
    // A stale revision is refused and changes nothing.
    let stale = update(
        &mut conn,
        "alice",
        &pot.id,
        PotPatch {
            revision: 1,
            ..Default::default()
        },
    )
    .unwrap_err();
    assert_eq!(stale.code, "revision_conflict");
    // A pot cannot list itself as a peer.
    let mut own = updated.input.permissions.clone();
    own.dm.send_to = vec![pot.id.clone()];
    let error = update(
        &mut conn,
        "alice",
        &pot.id,
        PotPatch {
            revision: 2,
            permissions: Some(own),
            ..Default::default()
        },
    )
    .unwrap_err();
    assert_eq!(error.status, 400);
}

#[test]
fn state_changes_follow_pause_archive_and_restore() {
    let db = db();
    let mut conn = db.lock();
    let pot = create(&mut conn, "alice", input("Tester")).unwrap();
    let paused = set_state(&mut conn, "alice", &pot.id, 1, PotState::Paused).unwrap();
    let archived = set_state(
        &mut conn,
        "alice",
        &pot.id,
        paused.revision,
        PotState::Archived,
    )
    .unwrap();
    // Archived pots are not edited, and come back paused.
    let error = update(
        &mut conn,
        "alice",
        &pot.id,
        PotPatch {
            revision: archived.revision,
            ..Default::default()
        },
    )
    .unwrap_err();
    assert_eq!(error.code, "pot_archived");
    assert_eq!(
        set_state(
            &mut conn,
            "alice",
            &pot.id,
            archived.revision,
            PotState::Active
        )
        .unwrap_err()
        .code,
        "invalid_transition"
    );
    let restored = set_state(
        &mut conn,
        "alice",
        &pot.id,
        archived.revision,
        PotState::Paused,
    )
    .unwrap();
    assert_eq!(restored.state, PotState::Paused);
}

#[test]
fn each_owner_has_a_finite_number_of_pots() {
    let db = db();
    let mut conn = db.lock();
    for n in 0..MAX_POTS {
        create(&mut conn, "alice", input(&format!("Pot {n}"))).unwrap();
    }
    assert_eq!(
        create(&mut conn, "alice", input("One more"))
            .unwrap_err()
            .code,
        "limit_reached"
    );
    create(&mut conn, "bob", input("Bob's first")).unwrap();
}

#[test]
fn settings_have_finite_defaults_and_range_checks() {
    let db = db();
    let mut conn = db.lock();
    let defaults = settings(&conn, "alice").unwrap();
    assert_eq!(defaults.cap_money_month_micros, 0);
    assert_eq!(defaults.activity_retention_days, 90);
    assert_eq!(defaults.loop_no_progress_wakes, 12);
    assert!(!defaults.count_subscription_money);
    let mut next = defaults.clone();
    next.cap_money_month_micros = 50_000_000;
    next.count_subscription_money = true;
    let saved = update_settings(&mut conn, "alice", next.clone()).unwrap();
    assert_eq!(saved.revision, defaults.revision + 1);
    assert!(saved.count_subscription_money);
    // Stale and out-of-range writes are refused.
    assert_eq!(
        update_settings(&mut conn, "alice", next).unwrap_err().code,
        "revision_conflict"
    );
    let mut wild = saved.clone();
    wild.loop_depth = 1_000;
    assert_eq!(
        update_settings(&mut conn, "alice", wild)
            .unwrap_err()
            .status,
        400
    );
    // Owners are separate.
    assert_eq!(settings(&conn, "bob").unwrap().cap_money_month_micros, 0);
}

mod http {
    use crate::test_support::{app_with_models, call};
    use serde_json::{Value, json};

    fn app() -> (crate::app::AppState, tempfile::TempDir) {
        let (app, dir) = app_with_models(json!({
            "oauth:anthropic": { "api": "anthropic-messages", "baseUrl": "https://api.anthropic.com",
                "models": [{ "id": "claude-fable-5" }, { "id": "claude-opus-5" }] },
            "work-openai": { "api": "openai-responses", "baseUrl": "https://api.openai.com/v1",
                "apiKey": "k", "models": [{ "id": "gpt-5" }] }
        }));
        super::db_setup(&app.db.lock());
        (app, dir)
    }

    fn body() -> Value {
        serde_json::to_value(super::input("Tester")).unwrap()
    }

    #[tokio::test]
    async fn the_owner_creates_reads_updates_and_pauses_a_pot() {
        let (app, _dir) = app();
        let (status, created) =
            call(&app, "POST", "/api/pots", Some("alice"), None, Some(body())).await;
        assert_eq!(status, 201, "{created}");
        let id = created["pot"]["id"].as_str().unwrap().to_owned();
        assert_eq!(created["pot"]["profile"]["name"], "Tester");
        assert_eq!(created["pot"]["permissions"]["reach"], "work");

        let (status, listed) = call(&app, "GET", "/api/pots", Some("alice"), None, None).await;
        assert_eq!((status, listed["pots"].as_array().unwrap().len()), (200, 1));
        // Another owner can neither see nor change it.
        assert_eq!(
            call(
                &app,
                "GET",
                &format!("/api/pots/{id}"),
                Some("bob"),
                None,
                None
            )
            .await
            .0,
            404
        );
        assert_eq!(
            call(
                &app,
                "POST",
                &format!("/api/pots/{id}/pause"),
                Some("bob"),
                None,
                Some(json!({"revision":1}))
            )
            .await
            .0,
            404
        );

        let (status, updated) = call(
            &app,
            "PATCH",
            &format!("/api/pots/{id}"),
            Some("alice"),
            None,
            Some(json!({ "revision": 1, "profile": { "name": "Night tester", "avatarColor": 3 } })),
        )
        .await;
        assert_eq!(status, 200, "{updated}");
        assert_eq!(updated["pot"]["profile"]["name"], "Night tester");
        assert_eq!(updated["pot"]["revision"], 2);

        let (status, paused) = call(
            &app,
            "POST",
            &format!("/api/pots/{id}/pause"),
            Some("alice"),
            None,
            Some(json!({"revision":2})),
        )
        .await;
        assert_eq!(
            (status, paused["pot"]["state"].as_str()),
            (200, Some("paused"))
        );
        let (status, resumed) = call(
            &app,
            "POST",
            &format!("/api/pots/{id}/resume"),
            Some("alice"),
            None,
            Some(json!({"revision":3})),
        )
        .await;
        assert_eq!(
            (status, resumed["pot"]["state"].as_str()),
            (200, Some("active"))
        );
    }

    #[tokio::test]
    async fn models_must_be_served_and_locations_visible() {
        let (app, _dir) = app();
        let mut unknown = body();
        unknown["models"]["fallbacks"] = json!([{ "provider": "work-openai", "model": "gpt-9" }]);
        let (status, error) = call(
            &app,
            "POST",
            "/api/pots",
            Some("alice"),
            None,
            Some(unknown),
        )
        .await;
        assert_eq!(
            (status, error["error"]["code"].as_str()),
            (400, Some("unknown_model"))
        );
        let mut hidden = body();
        hidden["permissions"]["workLocations"] =
            json!([{ "workspaceId": "node:missing", "access": "read" }]);
        assert_ne!(
            call(&app, "POST", "/api/pots", Some("alice"), None, Some(hidden))
                .await
                .0,
            201
        );
        let mut extra = body();
        extra["permissions"]["unlimited"] = json!(true);
        assert_eq!(
            call(&app, "POST", "/api/pots", Some("alice"), None, Some(extra))
                .await
                .0,
            400
        );
    }

    #[tokio::test]
    async fn settings_round_trip_with_a_revision() {
        let (app, _dir) = app();
        let (status, got) =
            call(&app, "GET", "/api/pots/settings", Some("alice"), None, None).await;
        assert_eq!(status, 200);
        let mut next = got["settings"].clone();
        next["capTokensDay"] = json!(2_000_000);
        let (status, saved) = call(
            &app,
            "PATCH",
            "/api/pots/settings",
            Some("alice"),
            None,
            Some(next.clone()),
        )
        .await;
        assert_eq!(
            (status, saved["settings"]["capTokensDay"].as_i64()),
            (200, Some(2_000_000))
        );
        next["onExhausted"] = json!("spend_more");
        next["revision"] = saved["settings"]["revision"].clone();
        assert_eq!(
            call(
                &app,
                "PATCH",
                "/api/pots/settings",
                Some("alice"),
                None,
                Some(next)
            )
            .await
            .0,
            400
        );
        let (_, capabilities) =
            call(&app, "GET", "/api/capabilities", Some("alice"), None, None).await;
        assert_eq!(capabilities["features"]["pots"]["enabled"], true);
    }
}

#[test]
fn the_context_is_the_asking_sessions_pot_only() {
    let db = db();
    let mut conn = db.lock();
    let pot = create(&mut conn, "alice", input("Tester")).unwrap();
    let other = create(&mut conn, "alice", input("Researcher")).unwrap();
    conn.execute(
        "UPDATE pot_runtime SET session_id='session-of-tester' WHERE pot_id=?1",
        [&pot.id],
    )
    .unwrap();
    let context = super::ops::context(&conn, "alice", "session-of-tester").unwrap();
    assert_eq!(context["pot"]["id"], pot.id.as_str());
    assert_eq!(context["pot"]["name"], "Tester");
    assert_eq!(context["pot"]["personality"], "Calm and exact.");
    let summary = context["pot"]["permissions"].as_str().unwrap();
    assert!(summary.contains("start work"), "{summary}");
    assert!(summary.contains("node:repo (write)"), "{summary}");
    // Another session, or another owner, is not this pot.
    assert_eq!(
        super::ops::context(&conn, "alice", "unknown")
            .unwrap_err()
            .code,
        "not_a_pot"
    );
    assert_eq!(
        super::ops::context(&conn, "bob", "session-of-tester")
            .unwrap_err()
            .code,
        "not_a_pot"
    );
    assert_ne!(context["pot"]["id"], other.id.as_str());
}
