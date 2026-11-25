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

mod budget {
    use super::super::budget::{self, Answer, Decision, RequestInput, RequestState, Window};
    use super::super::threads;
    use super::*;

    fn ask_money(amount: u64) -> RequestInput {
        RequestInput {
            amount_micros: Some(amount),
            tokens: None,
            window: Window::Month,
            reason: "The nightly work needs a longer review".into(),
        }
    }

    fn ask_tokens(tokens: u64) -> RequestInput {
        RequestInput {
            amount_micros: None,
            tokens: Some(tokens),
            window: Window::Day,
            reason: String::new(),
        }
    }

    fn answer(decision: Decision, amount: Option<u64>) -> Answer {
        Answer {
            answer: decision,
            amount,
        }
    }

    #[test]
    fn a_budget_request_is_asked_once_answered_and_raises_only_that_window() {
        let db = db();
        let mut conn = db.lock();
        let pot = create(&mut conn, "alice", input("Tester")).unwrap();
        let request = budget::request(&mut conn, "alice", &pot.id, ask_money(1_000_000)).unwrap();
        assert_eq!(request.state, RequestState::Pending);
        assert_eq!(request.amount_micros, Some(1_000_000));
        assert_eq!(request.window, Window::Month);
        // It is a system message in the pot's direct thread.
        let thread = threads::direct(&conn, "alice", &pot.id).unwrap();
        let messages = threads::messages(&conn, "alice", &thread.id, None).unwrap();
        let last = messages.last().unwrap();
        assert_eq!(last.author_kind, "system");
        assert!(last.body.contains("Budget request"));
        assert!(last.body.contains("The nightly work needs a longer review"));
        // One open request per pot, and owners are separate.
        let error = budget::request(&mut conn, "alice", &pot.id, ask_money(5)).unwrap_err();
        assert_eq!(error.code, "budget_request_open");
        assert!(budget::list(&conn, "bob", None).unwrap().is_empty());
        assert_eq!(
            budget::answer(&mut conn, "bob", &request.id, answer(Decision::Deny, None))
                .unwrap_err()
                .status,
            404
        );
        // A denial blocks the same window until the user writes to the pot.
        let denied = budget::answer(
            &mut conn,
            "alice",
            &request.id,
            answer(Decision::Deny, None),
        )
        .unwrap();
        assert_eq!(denied.state, RequestState::Denied);
        let error = budget::request(&mut conn, "alice", &pot.id, ask_money(1_000_000)).unwrap_err();
        assert_eq!(error.code, "budget_request_denied");
        // Another window is still allowed.
        let day = budget::request(&mut conn, "alice", &pot.id, ask_tokens(5_000)).unwrap();
        assert_eq!(day.window, Window::Day);
        budget::answer(&mut conn, "alice", &day.id, answer(Decision::Deny, None)).unwrap();
        // The user's new message in the direct thread unlocks it.
        threads::post_user(&conn, "alice", &thread.id, "Go ahead", Vec::new(), false).unwrap();
        let again = budget::request(&mut conn, "alice", &pot.id, ask_money(1_000_000)).unwrap();
        // Approve a different amount: the cap rises by exactly that, once.
        let error = budget::answer(
            &mut conn,
            "alice",
            &again.id,
            answer(Decision::ApproveAmount, None),
        )
        .unwrap_err();
        assert_eq!(error.code, "invalid_input");
        let approved = budget::answer(
            &mut conn,
            "alice",
            &again.id,
            answer(Decision::ApproveAmount, Some(250_000)),
        )
        .unwrap();
        assert_eq!(approved.state, RequestState::ApprovedAmount);
        assert_eq!(approved.approved_amount_micros, Some(250_000));
        let pot = read(&conn, "alice", &pot.id).unwrap();
        assert_eq!(
            pot.input.permissions.budget_money_month_micros,
            20_000_000 + 250_000
        );
        // Answering twice is a conflict; every answer wakes the pot.
        assert_eq!(
            budget::answer(
                &mut conn,
                "alice",
                &again.id,
                answer(Decision::Approve, None)
            )
            .unwrap_err()
            .code,
            "already_answered"
        );
        let source: String = conn
            .query_row(
                "SELECT source FROM pot_wakes WHERE pot_id=?1 ORDER BY created_at DESC,rowid DESC LIMIT 1",
                [&pot.id],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(source, "budget");
        let kinds: Vec<String> = conn
            .prepare("SELECT kind FROM pot_activity WHERE pot_id=?1 ORDER BY rowid")
            .unwrap()
            .query_map([&pot.id], |r| r.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        assert_eq!(
            kinds
                .iter()
                .filter(|kind| kind.as_str() == "budget_request")
                .count(),
            6
        );
    }

    #[test]
    fn an_approved_request_raises_that_pots_cap_and_clamps_at_its_own_window() {
        let db = db();
        let mut conn = db.lock();
        let pot = create(&mut conn, "alice", input("Tester")).unwrap();
        let tokens = budget::request(&mut conn, "alice", &pot.id, ask_tokens(50_000)).unwrap();
        let approved = budget::answer(
            &mut conn,
            "alice",
            &tokens.id,
            answer(Decision::Approve, None),
        )
        .unwrap();
        assert_eq!(approved.state, RequestState::Approved);
        assert_eq!(approved.approved_tokens, Some(50_000));
        let pot = read(&conn, "alice", &pot.id).unwrap();
        assert_eq!(pot.input.permissions.budget_tokens_day, 550_000);
        assert_eq!(pot.input.permissions.budget_money_month_micros, 20_000_000);
        // Approving answers no longer pending.
        assert!(
            budget::list(&conn, "alice", Some(RequestState::Pending))
                .unwrap()
                .is_empty()
        );
    }

    #[test]
    fn a_request_rejects_mismatched_amounts_and_reasons() {
        let db = db();
        let mut conn = db.lock();
        let pot = create(&mut conn, "alice", input("Tester")).unwrap();
        let cases = [
            RequestInput {
                amount_micros: Some(5),
                tokens: Some(5),
                window: Window::Month,
                reason: String::new(),
            },
            RequestInput {
                amount_micros: Some(5),
                tokens: None,
                window: Window::Day,
                reason: String::new(),
            },
            RequestInput {
                amount_micros: None,
                tokens: Some(5),
                window: Window::Month,
                reason: String::new(),
            },
            RequestInput {
                amount_micros: Some(0),
                tokens: None,
                window: Window::Month,
                reason: String::new(),
            },
        ];
        for case in cases {
            let error = budget::request(&mut conn, "alice", &pot.id, case).unwrap_err();
            assert_eq!(error.code, "invalid_input");
        }
        assert!(budget::list(&conn, "alice", None).unwrap().is_empty());
    }
}

mod exhaustion {
    use super::super::runtime::{self, NewWake, Source};
    use super::*;

    fn wake(conn: &rusqlite::Connection, pot: &str) -> String {
        runtime::enqueue(
            conn,
            "alice",
            pot,
            NewWake {
                source: Source::User,
                thread_id: None,
                causal_root: None,
                content: "Please look at this",
                details: json!({}),
            },
        )
        .unwrap()
    }

    fn owner_caps(conn: &rusqlite::Connection, money: u64, tokens: u64) {
        conn.execute(
            "INSERT INTO pot_settings(owner_user,cap_money_month_micros,cap_tokens_day)
             VALUES('alice',?1,?2)
             ON CONFLICT(owner_user) DO UPDATE SET
               cap_money_month_micros=?1,cap_tokens_day=?2",
            rusqlite::params![money as i64, tokens as i64],
        )
        .unwrap();
    }

    #[test]
    fn a_pot_at_its_cap_waits_and_resumes_after_a_raise() {
        let db = db();
        let mut conn = db.lock();
        let pot = create(&mut conn, "alice", input("Tester")).unwrap();
        owner_caps(&conn, 100_000_000, 100_000_000);
        conn.execute(
            "UPDATE pot_permissions SET budget_money_month_micros=0,budget_tokens_day=0 WHERE pot_id=?1",
            [&pot.id],
        )
        .unwrap();
        let wake = wake(&conn, &pot.id);
        assert_eq!(
            runtime::claim_next(&conn, "alice", &pot.id, "UTC").unwrap(),
            None,
            "an exhausted pot's model wake waits"
        );
        // The sweep looks again, but the exhaustion is logged once per window.
        assert_eq!(
            runtime::claim_next(&conn, "alice", &pot.id, "UTC").unwrap(),
            None
        );
        let rows: i64 = conn
            .query_row(
                "SELECT count(*) FROM pot_activity WHERE kind='budget_exhausted'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(rows, 1);
        // A user-approved raise lets the queued wake through.
        conn.execute(
            "UPDATE pot_permissions SET budget_money_month_micros=1000000,budget_tokens_day=1000000 WHERE pot_id=?1",
            [&pot.id],
        )
        .unwrap();
        assert_eq!(
            runtime::claim_next(&conn, "alice", &pot.id, "UTC").unwrap(),
            Some(wake)
        );
    }

    #[test]
    fn owner_exhaustion_stops_every_pots_wakes_until_it_is_raised() {
        let db = db();
        let mut conn = db.lock();
        let first = create(&mut conn, "alice", input("First")).unwrap();
        let second = create(&mut conn, "alice", input("Second")).unwrap();
        owner_caps(&conn, 1, 100_000_000);
        conn.execute(
            "UPDATE pot_settings SET on_exhausted='pause_all' WHERE owner_user='alice'",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO usage_events(at,owner_user,node_id,node_session,actor_kind,actor_id,provider,
               model,auth_kind,input_tokens,output_tokens,cache_read_tokens,cache_write_tokens,
               cost_micros,outcome)
             VALUES(?1,'alice','node','past','pot',?2,'work-anthropic','claude-fable-5','api_key',
               1,0,0,0,5,'ok')",
            rusqlite::params![crate::util::now_ms(), first.id],
        )
        .unwrap();
        wake(&conn, &first.id);
        wake(&conn, &second.id);
        assert_eq!(
            runtime::claim_next(&conn, "alice", &first.id, "UTC").unwrap(),
            None
        );
        assert_eq!(
            runtime::claim_next(&conn, "alice", &second.id, "UTC").unwrap(),
            None,
            "an owner-wide cap stops every pot, not only the one that spent"
        );
        owner_caps(&conn, 100_000_000, 100_000_000);
        assert!(
            runtime::claim_next(&conn, "alice", &first.id, "UTC")
                .unwrap()
                .is_some()
        );
        assert!(
            runtime::claim_next(&conn, "alice", &second.id, "UTC")
                .unwrap()
                .is_some()
        );
    }
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

    async fn create_pot(app: &crate::app::AppState) -> String {
        let (status, created) =
            call(app, "POST", "/api/pots", Some("alice"), None, Some(body())).await;
        assert_eq!(status, 201, "{created}");
        created["pot"]["id"].as_str().unwrap().to_owned()
    }

    #[tokio::test]
    async fn observe_scopes_must_be_the_owners_own() {
        let (app, _dir) = app();
        let mut pot = body();
        pot["permissions"]["observe"] = json!([{ "kind": "session", "ref": "someone-elses" }]);
        let (status, error) = call(&app, "POST", "/api/pots", Some("alice"), None, Some(pot)).await;
        assert_eq!(status, 400, "{error}");
        let mut pot = body();
        pot["permissions"]["observe"] = json!([{ "kind": "workspace", "ref": "node:hidden" }]);
        assert_ne!(
            call(&app, "POST", "/api/pots", Some("alice"), None, Some(pot))
                .await
                .0,
            201
        );
    }

    #[tokio::test]
    async fn the_owner_reads_activity_and_a_pots_view_over_http() {
        let (app, _dir) = app();
        let (_, created) = call(&app, "POST", "/api/pots", Some("alice"), None, Some(body())).await;
        let id = created["pot"]["id"].as_str().unwrap().to_owned();
        let (status, page) = call(
            &app,
            "GET",
            "/api/activity?kind=created&limit=10",
            Some("alice"),
            None,
            None,
        )
        .await;
        assert_eq!(status, 200, "{page}");
        assert_eq!(page["activity"][0]["potName"], "Tester");
        assert_eq!(
            page["activity"][0]["counterpart"],
            json!({ "kind": "user" })
        );
        assert!(page.get("nextBefore").is_none());
        let (_, bobs) = call(&app, "GET", "/api/activity", Some("bob"), None, None).await;
        assert_eq!(bobs["activity"], json!([]));
        assert_eq!(
            call(
                &app,
                "GET",
                "/api/activity?kind=bogus",
                Some("alice"),
                None,
                None
            )
            .await
            .0,
            400
        );
        assert_eq!(
            call(
                &app,
                "GET",
                "/api/activity?as=pot",
                Some("alice"),
                None,
                None
            )
            .await
            .0,
            400
        );
        let (status, view) = call(
            &app,
            "GET",
            &format!("/api/pots/{id}/view"),
            Some("alice"),
            None,
            None,
        )
        .await;
        assert_eq!((status, view["potId"].as_str()), (200, Some(id.as_str())));
        assert_eq!(
            call(
                &app,
                "GET",
                &format!("/api/pots/{id}/view"),
                Some("bob"),
                None,
                None
            )
            .await
            .0,
            404
        );
    }

    #[tokio::test]
    async fn the_owner_talks_to_a_pot_and_its_groups_over_http() {
        let (app, _dir) = app();
        let mut ids = Vec::new();
        for name in ["Tester", "Helper"] {
            let mut pot = body();
            pot["profile"]["name"] = json!(name);
            let (status, created) =
                call(&app, "POST", "/api/pots", Some("alice"), None, Some(pot)).await;
            assert_eq!(status, 201, "{created}");
            ids.push(created["pot"]["id"].as_str().unwrap().to_owned());
        }
        let (status, direct) = call(
            &app,
            "GET",
            &format!("/api/pots/{}/thread", ids[0]),
            Some("alice"),
            None,
            None,
        )
        .await;
        assert_eq!(
            (status, direct["thread"]["kind"].as_str()),
            (200, Some("direct"))
        );
        let thread = direct["thread"]["id"].as_str().unwrap().to_owned();
        let messages = format!("/api/threads/{thread}/messages");
        let (status, posted) = call(
            &app,
            "POST",
            &messages,
            Some("alice"),
            None,
            Some(json!({ "body": "Hi" })),
        )
        .await;
        assert_eq!(status, 201, "{posted}");
        assert_eq!(posted["woken"], json!([ids[0]]));
        let (_, page) = call(
            &app,
            "GET",
            &format!("{messages}?before=99"),
            Some("alice"),
            None,
            None,
        )
        .await;
        assert_eq!(page["messages"][0]["body"], "Hi");
        // Another owner sees no thread; unknown fields are refused.
        assert_eq!(
            call(&app, "GET", &messages, Some("bob"), None, None)
                .await
                .0,
            404
        );
        assert_eq!(
            call(
                &app,
                "POST",
                &messages,
                Some("alice"),
                None,
                Some(json!({ "body": "x", "as": "pot" }))
            )
            .await
            .0,
            400
        );
        let group = json!({ "name": "Pair", "hostPotId": ids[0], "memberPotIds": [ids[1]] });
        let (status, created) = call(
            &app,
            "POST",
            "/api/threads",
            Some("alice"),
            None,
            Some(group),
        )
        .await;
        assert_eq!(
            (status, created["thread"]["kind"].as_str()),
            (201, Some("group"))
        );
        let (_, listed) = call(&app, "GET", "/api/threads", Some("alice"), None, None).await;
        assert_eq!(listed["threads"].as_array().unwrap().len(), 2);
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

    #[tokio::test]
    async fn budget_requests_are_listed_and_answered_over_http() {
        use crate::pots::budget::{self, RequestInput, Window};
        use std::sync::Arc;
        use std::sync::atomic::{AtomicBool, Ordering};

        let (app, _dir) = app();
        let pot = create_pot(&app).await;
        let fired = Arc::new(AtomicBool::new(false));
        let flag = fired.clone();
        let _hint = app.hints.budget_requests.add(
            "alice".into(),
            Arc::new(move || flag.store(true, Ordering::SeqCst)),
        );
        let request = budget::request(
            &mut app.db.lock(),
            "alice",
            &pot,
            RequestInput {
                amount_micros: Some(1_500_000),
                tokens: None,
                window: Window::Month,
                reason: "More review time".into(),
            },
        )
        .unwrap();
        // A store write alone sends no hint; the answer route does.
        assert!(!fired.swap(false, Ordering::SeqCst));
        let path = "/api/budget-requests?state=pending";
        let (status, listed) = call(&app, "GET", path, Some("alice"), None, None).await;
        assert_eq!(status, 200, "{listed}");
        assert_eq!(listed["budgetRequests"][0]["id"], request.id.as_str());
        assert_eq!(listed["budgetRequests"][0]["amountMicros"], 1_500_000);
        assert_eq!(
            call(
                &app,
                "GET",
                "/api/budget-requests?state=unknown",
                Some("alice"),
                None,
                None
            )
            .await
            .0,
            400
        );
        assert!(
            call(&app, "GET", "/api/budget-requests", Some("bob"), None, None)
                .await
                .1["budgetRequests"]
                .as_array()
                .unwrap()
                .is_empty()
        );
        let answer = format!("/api/budget-requests/{}/answer", request.id);
        assert_eq!(
            call(
                &app,
                "POST",
                &answer,
                Some("alice"),
                None,
                Some(json!({ "answer": "approve", "budget": 1 }))
            )
            .await
            .0,
            400
        );
        assert_eq!(
            call(
                &app,
                "POST",
                &answer,
                Some("alice"),
                None,
                Some(json!({ "answer": "approve_amount" }))
            )
            .await
            .0,
            400
        );
        assert_eq!(
            call(
                &app,
                "POST",
                &answer,
                Some("bob"),
                None,
                Some(json!({ "answer": "deny" }))
            )
            .await
            .0,
            404
        );
        let (status, answered) = call(
            &app,
            "POST",
            &answer,
            Some("alice"),
            None,
            Some(json!({ "answer": "approve_amount", "amount": 2_000_000 })),
        )
        .await;
        assert_eq!(status, 200, "{answered}");
        assert_eq!(answered["budgetRequest"]["state"], "approved_amount");
        assert_eq!(answered["budgetRequest"]["approvedAmountMicros"], 2_000_000);
        assert!(fired.swap(false, Ordering::SeqCst), "answer hints");
        let (_, updated) = call(
            &app,
            "GET",
            &format!("/api/pots/{pot}"),
            Some("alice"),
            None,
            None,
        )
        .await;
        assert_eq!(
            updated["pot"]["permissions"]["budgetMoneyMonthMicros"],
            20_000_000 + 2_000_000
        );
        let (_, pending) = call(&app, "GET", path, Some("alice"), None, None).await;
        assert_eq!(pending["budgetRequests"], Value::Array(Vec::new()));
        // The answer is a system message in the pot's direct thread.
        let (_, thread) = call(
            &app,
            "GET",
            &format!("/api/pots/{pot}/thread"),
            Some("alice"),
            None,
            None,
        )
        .await;
        let (_, page) = call(
            &app,
            "GET",
            &format!(
                "/api/threads/{}/messages",
                thread["thread"]["id"].as_str().unwrap()
            ),
            Some("alice"),
            None,
            None,
        )
        .await;
        assert!(page["messages"].as_array().unwrap().iter().any(|message| {
            message["body"]
                .as_str()
                .is_some_and(|body| body.contains("approved"))
        }));
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
    let direct = super::threads::direct(&conn, "alice", &pot.id).unwrap();
    assert_eq!(context["directThreadId"], direct.id.as_str());
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

mod runtime {
    use super::super::runtime::{self, NewWake, Source};
    use crate::db::Store;
    use crate::nodes::ConnectedNode;
    use crate::test_support::app_with_models;
    use crate::util::now_ms;
    use pirc_protocol::{HttpMethod, ModeId, NodeHttpRequest, NodeHttpResponse};
    use serde_json::{Value, json};
    use std::sync::{Arc, Mutex};

    /// What the fake chat node's session shows.
    #[derive(Clone, Copy, PartialEq)]
    enum Stage {
        Running,
        Answered,
    }

    struct Fake {
        requests: Mutex<Vec<NodeHttpRequest>>,
        stage: Mutex<Stage>,
        refuse_delivery: Mutex<bool>,
        delivered: Mutex<Option<Value>>,
    }

    fn chat_node() -> ConnectedNode {
        ConnectedNode {
            id: "chat".into(),
            role: pirc_protocol::NodeRole::Chat,
            modes: vec![ModeId::new("pot").unwrap()],
            workspaces: vec![pirc_protocol::RegisteredWorkspace {
                checkpoint_private: false,
                id: "pots".into(),
                display_name: "Pots".into(),
                mode: ModeId::new("pot").unwrap(),
                roles: None,
                repo: None,
            }],
            connected_at: now_ms(),
            last_seen_at: now_ms(),
            added: Default::default(),
        }
    }

    fn respond(fake: &Fake, request: &NodeHttpRequest) -> NodeHttpResponse {
        let ok = |status, body: Value| NodeHttpResponse {
            status,
            body: Some(body),
        };
        match (request.method, request.url.as_str()) {
            (HttpMethod::Post, "/api/session-creations/internal") => {
                ok(201, json!({ "session": { "id": "remote-pot" } }))
            }
            (HttpMethod::Patch, "/api/sessions/remote-pot") => ok(200, json!({})),
            (HttpMethod::Post, "/api/sessions/remote-pot/deliver") => {
                if *fake.refuse_delivery.lock().unwrap() {
                    return ok(503, json!({ "error": { "message": "busy" } }));
                }
                *fake.delivered.lock().unwrap() = request.payload.clone();
                ok(202, json!({ "delivered": true }))
            }
            (HttpMethod::Get, "/api/sessions/remote-pot/snapshot") => {
                let mut history = Vec::new();
                if let Some(message) = fake.delivered.lock().unwrap().clone() {
                    history.push(json!({ "role": "custom", "customType": "pot-wake",
                        "content": message["content"], "details": message["details"] }));
                }
                let running = *fake.stage.lock().unwrap() == Stage::Running;
                if !running {
                    history.push(json!({ "role": "assistant",
                        "content": [{ "type": "text", "text": "Done: all green." }] }));
                }
                ok(
                    200,
                    json!({ "history": history, "interactions": [],
                    "run": { "status": if running { "running" } else { "succeeded" }, "createdAt": 1 } }),
                )
            }
            _ => panic!(
                "unexpected Node request {:?} {}",
                request.method, request.url
            ),
        }
    }

    fn setup() -> (crate::app::AppState, tempfile::TempDir, Arc<Fake>, String) {
        let (app, dir) = app_with_models(json!({}));
        {
            let db = app.db.lock();
            db.sync_remote_workspaces(
                "chat",
                &[("pots".into(), "Pots".into(), ModeId::new("pot").unwrap())],
            )
            .unwrap();
            db.claim_assistant_node("chat").unwrap();
        }
        let fake = Arc::new(Fake {
            requests: Mutex::new(Vec::new()),
            stage: Mutex::new(Stage::Running),
            refuse_delivery: Mutex::new(false),
            delivered: Mutex::new(None),
        });
        let handler = fake.clone();
        app.nodes.set_test_node(chat_node(), move |request| {
            handler.requests.lock().unwrap().push(request.clone());
            Ok(respond(&handler, &request))
        });
        let mut input = super::input("Tester");
        input.permissions.work_locations.clear();
        input.models.work_models.clear();
        input.permissions.reach = super::Reach::Observe;
        let pot = super::create(&mut app.db.lock(), "alice", input).unwrap();
        (app, dir, fake, pot.id)
    }

    fn wake(app: &crate::app::AppState, pot: &str, text: &str) -> String {
        runtime::enqueue(
            &app.db.lock(),
            "alice",
            pot,
            NewWake {
                source: Source::User,
                thread_id: Some("thread-1"),
                causal_root: None,
                content: text,
                details: json!({ "from": "user" }),
            },
        )
        .unwrap()
    }

    #[tokio::test]
    async fn a_wake_is_delivered_once_and_its_answer_becomes_the_reply() {
        let (app, _dir, fake, pot) = setup();
        let first = wake(&app, &pot, "How did the nightly go?");
        let second = wake(&app, &pot, "And the flaky one?");
        runtime::check(&app, "alice", &pot).await.unwrap();
        // The pot's session was allocated in the pots workspace and remembered.
        let pot_row = super::read(&app.db.lock(), "alice", &pot).unwrap();
        let session = pot_row
            .session_id
            .clone()
            .unwrap_or_else(|| panic!("{:?}", runtime::wake(&app.db.lock(), &first)));
        assert_eq!(
            app.db.lock().get_session(&session).unwrap().workspace_id,
            "chat:pots"
        );
        let delivered = fake.delivered.lock().unwrap().clone().unwrap();
        assert_eq!(delivered["customType"], "pot-wake");
        assert_eq!(delivered["content"], "How did the nightly go?");
        assert_eq!(delivered["details"]["wakeId"], first.as_str());
        assert_eq!(delivered["details"]["source"], "user");
        assert_eq!(
            runtime::wake(&app.db.lock(), &first).unwrap().state,
            "delivered"
        );
        // One at a time: the second waits while the first runs.
        runtime::check(&app, "alice", &pot).await.unwrap();
        assert_eq!(
            runtime::wake(&app.db.lock(), &second).unwrap().state,
            "queued"
        );

        *fake.stage.lock().unwrap() = Stage::Answered;
        runtime::check(&app, "alice", &pot).await.unwrap();
        let done = runtime::wake(&app.db.lock(), &first).unwrap();
        assert_eq!(
            (done.state.as_str(), done.reply.as_deref()),
            ("settled", Some("Done: all green."))
        );
        // The next wake goes out right after, into the same session.
        assert_eq!(
            runtime::wake(&app.db.lock(), &second).unwrap().state,
            "delivered"
        );
        let creations = fake
            .requests
            .lock()
            .unwrap()
            .iter()
            .filter(|r| r.url == "/api/session-creations/internal")
            .count();
        assert_eq!(creations, 1);
        assert_eq!(
            super::read(&app.db.lock(), "alice", &pot)
                .unwrap()
                .session_id,
            Some(session)
        );
    }

    #[tokio::test]
    async fn a_paused_pot_gets_nothing_and_refused_sends_are_retried_then_failed() {
        let (app, _dir, fake, pot) = setup();
        let id = wake(&app, &pot, "Hello");
        super::set_state(
            &mut app.db.lock(),
            "alice",
            &pot,
            1,
            super::PotState::Paused,
        )
        .unwrap();
        runtime::check(&app, "alice", &pot).await.unwrap();
        assert_eq!(runtime::wake(&app.db.lock(), &id).unwrap().state, "queued");
        assert!(fake.requests.lock().unwrap().is_empty());

        super::set_state(
            &mut app.db.lock(),
            "alice",
            &pot,
            2,
            super::PotState::Active,
        )
        .unwrap();
        *fake.refuse_delivery.lock().unwrap() = true;
        for attempt in 1..=3 {
            runtime::check(&app, "alice", &pot).await.unwrap();
            let state = runtime::wake(&app.db.lock(), &id).unwrap();
            assert_eq!(state.attempts, attempt);
            assert_eq!(state.state, if attempt < 3 { "queued" } else { "failed" });
        }
        assert!(fake.delivered.lock().unwrap().is_none());
    }

    #[tokio::test]
    async fn without_a_chat_node_the_wake_waits_without_using_an_attempt() {
        let (app, _dir, _fake, pot) = setup();
        app.db.lock().release_assistant_node("chat").unwrap();
        let id = wake(&app, &pot, "Hello");
        runtime::check(&app, "alice", &pot).await.unwrap();
        let state = runtime::wake(&app.db.lock(), &id).unwrap();
        assert_eq!((state.state.as_str(), state.attempts), ("queued", 0));
        assert!(state.error.unwrap().contains("no chat node"));
    }

    #[tokio::test]
    async fn an_unconfirmed_delivery_is_never_sent_again() {
        let (app, _dir, fake, pot) = setup();
        let id = wake(&app, &pot, "Hello");
        // As after a crash between claim and send: in flight, never seen.
        runtime::check(&app, "alice", &pot).await.unwrap();
        *fake.delivered.lock().unwrap() = None;
        app.db
            .lock()
            .execute(
                "UPDATE pot_wakes SET delivered_at=?2 WHERE id=?1",
                rusqlite::params![id, now_ms() - 11 * 60_000],
            )
            .unwrap();
        let sends_before = fake
            .requests
            .lock()
            .unwrap()
            .iter()
            .filter(|r| r.url.ends_with("/deliver"))
            .count();
        runtime::check(&app, "alice", &pot).await.unwrap();
        let state = runtime::wake(&app.db.lock(), &id).unwrap();
        assert_eq!(state.state, "failed");
        assert_eq!(
            state.error.as_deref(),
            Some("Delivery could not be confirmed")
        );
        let sends_after = fake
            .requests
            .lock()
            .unwrap()
            .iter()
            .filter(|r| r.url.ends_with("/deliver"))
            .count();
        assert_eq!(sends_after, sends_before);
    }

    #[tokio::test]
    async fn wakes_carry_the_pots_model_and_thinking_only_when_they_change() {
        let (app, _dir, fake, pot) = setup();
        let first = wake(&app, &pot, "First");
        runtime::check(&app, "alice", &pot).await.unwrap();
        let delivered = fake.delivered.lock().unwrap().clone().unwrap();
        assert_eq!(delivered["model"]["provider"], "oauth:anthropic");
        assert_eq!(delivered["model"]["id"], "claude-fable-5");
        assert_eq!(delivered["thinking"], "medium");

        // The same settings are not sent again.
        let second = wake(&app, &pot, "Second");
        *fake.stage.lock().unwrap() = Stage::Answered;
        runtime::check(&app, "alice", &pot).await.unwrap();
        assert_eq!(
            runtime::wake(&app.db.lock(), &first).unwrap().state,
            "settled"
        );
        let delivered = fake.delivered.lock().unwrap().clone().unwrap();
        assert_eq!(delivered["details"]["wakeId"], second.as_str());
        assert_eq!(delivered.get("model"), None);
        assert_eq!(delivered.get("thinking"), None);

        // A new level is applied from the next wake.
        super::super::autonomy::set_thinking(
            &app.db.lock(),
            "alice",
            &pot,
            "high",
            "a harder task",
        )
        .unwrap();
        let third = wake(&app, &pot, "Third");
        runtime::check(&app, "alice", &pot).await.unwrap();
        let delivered = fake.delivered.lock().unwrap().clone().unwrap();
        assert_eq!(delivered["details"]["wakeId"], third.as_str());
        assert_eq!(delivered["thinking"], "high");

        // A reported fallback applies on the next wake too.
        let main = super::super::store::ModelChoice {
            provider: "oauth:anthropic".into(),
            model: "claude-fable-5".into(),
        };
        let fallback = super::super::store::ModelChoice {
            provider: "work-openai".into(),
            model: "gpt-5".into(),
        };
        super::super::autonomy::record_fallback(
            &app.db.lock(),
            "alice",
            &pot,
            &main,
            &fallback,
            "rate limited",
        )
        .unwrap();
        let fourth = wake(&app, &pot, "Fourth");
        runtime::check(&app, "alice", &pot).await.unwrap();
        let delivered = fake.delivered.lock().unwrap().clone().unwrap();
        assert_eq!(delivered["details"]["wakeId"], fourth.as_str());
        assert_eq!(delivered["model"]["id"], "gpt-5");
    }

    #[tokio::test]
    async fn a_paused_pot_takes_its_review_and_reminder_after_resume() {
        let (app, _dir, fake, pot) = setup();
        super::set_state(
            &mut app.db.lock(),
            "alice",
            &pot,
            1,
            super::PotState::Paused,
        )
        .unwrap();
        let note = "Check the deployment";
        super::super::autonomy::create_reminder(
            &app.db.lock(),
            "alice",
            &pot,
            now_ms() + 60_000,
            note,
        )
        .unwrap();
        app.db
            .lock()
            .execute(
                "UPDATE pot_reminders SET due_at=?2 WHERE pot_id=?1",
                rusqlite::params![pot, now_ms() - 1],
            )
            .unwrap();
        // A review is due as well: both wait as wakes while the pot is paused.
        app.db
            .lock()
            .execute(
                "UPDATE pot_runtime SET autonomy_interval_s=3600,last_engaged_at=?2,
                  next_review_at=?3 WHERE pot_id=?1",
                rusqlite::params![pot, now_ms() - 3_600_000, now_ms() - 1],
            )
            .unwrap();
        let woken = super::super::autonomy::sweep(&app.db.lock()).unwrap();
        assert_eq!(woken.len(), 2);
        assert!(
            woken
                .iter()
                .all(|(owner, id)| owner == "alice" && *id == pot)
        );
        let reviews: i64 = app
            .db
            .lock()
            .query_row(
                "SELECT count(*) FROM pot_wakes WHERE pot_id=?1 AND source='review'",
                [&pot],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(reviews, 1);
        runtime::check(&app, "alice", &pot).await.unwrap();
        assert!(fake.requests.lock().unwrap().is_empty());

        super::set_state(
            &mut app.db.lock(),
            "alice",
            &pot,
            2,
            super::PotState::Active,
        )
        .unwrap();
        runtime::check(&app, "alice", &pot).await.unwrap();
        let delivered = fake.delivered.lock().unwrap().clone().unwrap();
        assert_eq!(delivered["details"]["source"], "review");

        *fake.stage.lock().unwrap() = Stage::Answered;
        runtime::check(&app, "alice", &pot).await.unwrap();
        let delivered = fake.delivered.lock().unwrap().clone().unwrap();
        assert_eq!(delivered["details"]["source"], "reminder");
        assert_eq!(delivered["content"], note);
    }
}

mod autonomy {
    use super::super::autonomy::{self, MAX_PENDING_REMINDERS};
    use super::super::ops::{self, Op};
    use super::super::runtime::{self, NewWake, Source};
    use super::super::store::ModelChoice;
    use super::{db, input};
    use crate::agent_ops::OpContext;
    use crate::app::AppState;
    use crate::db::Store;
    use crate::error::ApiResult;
    use crate::test_support::app_with_models;
    use crate::util::now_ms;
    use rusqlite::params;
    use serde_json::{Value, json};

    fn pot(conn: &mut rusqlite::Connection) -> String {
        super::create(conn, "alice", input("Tester")).unwrap().id
    }

    fn wakes(conn: &rusqlite::Connection, pot: &str) -> Vec<(String, String, String)> {
        conn.prepare(
            "SELECT source,content,state FROM pot_wakes WHERE pot_id=?1 ORDER BY created_at,rowid",
        )
        .unwrap()
        .query_map([pot], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap()
    }

    fn activities(conn: &rusqlite::Connection, pot: &str) -> Vec<(String, String)> {
        conn.prepare("SELECT kind,summary FROM pot_activity WHERE pot_id=?1 ORDER BY at,rowid")
            .unwrap()
            .query_map([pot], |r| Ok((r.get(0)?, r.get(1)?)))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap()
    }

    fn review_times(conn: &rusqlite::Connection, pot: &str) -> (Option<i64>, Option<i64>) {
        conn.query_row(
            "SELECT last_engaged_at,next_review_at FROM pot_runtime WHERE pot_id=?1",
            [pot],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap()
    }

    #[test]
    fn a_due_review_wakes_the_pot_and_reschedules() {
        let db = db();
        let mut conn = db.lock();
        let pot = pot(&mut conn);
        // The first sweep starts the 2-day default; it is not due yet.
        assert!(autonomy::sweep(&conn).unwrap().is_empty());
        let (_, next) = review_times(&conn, &pot);
        assert!(next.unwrap() > now_ms());

        conn.execute(
            "UPDATE pot_runtime SET autonomy_interval_s=3600,last_engaged_at=?2,
              next_review_at=?3 WHERE pot_id=?1",
            params![pot, now_ms() - 7_200_000, now_ms() - 3_600_000],
        )
        .unwrap();
        assert_eq!(
            autonomy::sweep(&conn).unwrap(),
            vec![("alice".to_owned(), pot.clone())]
        );
        let queued = wakes(&conn, &pot);
        assert_eq!(
            (queued[0].0.as_str(), queued[0].2.as_str()),
            ("review", "queued")
        );
        assert!(
            activities(&conn, &pot)
                .iter()
                .any(|(kind, _)| kind == "review")
        );
        let (_, next) = review_times(&conn, &pot);
        assert!(next.unwrap() > now_ms());
        // One review at a time: the next sweep adds nothing.
        assert!(autonomy::sweep(&conn).unwrap().is_empty());
        assert_eq!(wakes(&conn, &pot).len(), 1);
    }

    #[test]
    fn reviews_wait_for_the_interval_and_stay_off_when_unset() {
        let db = db();
        let mut conn = db.lock();
        let pot = pot(&mut conn);
        conn.execute(
            "UPDATE pot_runtime SET autonomy_interval_s=3600,last_engaged_at=?2,
              next_review_at=?3 WHERE pot_id=?1",
            params![pot, now_ms(), now_ms() + 3_600_000],
        )
        .unwrap();
        assert!(autonomy::sweep(&conn).unwrap().is_empty());
        // Off: no schedule, no wake even long after the old one.
        conn.execute(
            "UPDATE pot_runtime SET autonomy_interval_s=NULL,next_review_at=NULL WHERE pot_id=?1",
            [&pot],
        )
        .unwrap();
        assert!(autonomy::sweep(&conn).unwrap().is_empty());
        assert!(wakes(&conn, &pot).is_empty());
    }

    #[test]
    fn a_non_review_wake_counts_as_engagement() {
        let db = db();
        let mut conn = db.lock();
        let pot = pot(&mut conn);
        conn.execute(
            "UPDATE pot_runtime SET autonomy_interval_s=3600,last_engaged_at=?2,
              next_review_at=?3 WHERE pot_id=?1",
            params![pot, now_ms() - 7_200_000, now_ms() - 3_600_000],
        )
        .unwrap();
        runtime::enqueue(
            &conn,
            "alice",
            &pot,
            NewWake {
                source: Source::User,
                thread_id: None,
                causal_root: None,
                content: "Hello",
                details: json!({}),
            },
        )
        .unwrap();
        let (engaged, next) = review_times(&conn, &pot);
        assert!(engaged.unwrap() >= now_ms() - 1_000);
        assert!(next.unwrap() > now_ms() + 3_500_000);
        // A review is not engagement: it does not move the timer.
        let before = review_times(&conn, &pot);
        conn.execute(
            "UPDATE pot_wakes SET state='settled' WHERE pot_id=?1 AND source='user'",
            [&pot],
        )
        .unwrap();
        runtime::enqueue(
            &conn,
            "alice",
            &pot,
            NewWake {
                source: Source::Review,
                thread_id: None,
                causal_root: None,
                content: "Review",
                details: json!({}),
            },
        )
        .unwrap();
        assert_eq!(review_times(&conn, &pot), before);
    }

    #[test]
    fn a_due_reminder_becomes_one_reminder_wake_and_limits_hold() {
        let db = db();
        let mut conn = db.lock();
        let pot = pot(&mut conn);
        let at = now_ms() + 60_000;
        let made =
            autonomy::create_reminder(&conn, "alice", &pot, at, "Check the deployment").unwrap();
        let reminder = made["id"].as_str().unwrap().to_owned();
        assert!(
            activities(&conn, &pot)
                .iter()
                .any(|(kind, summary)| kind == "reminder_set"
                    && summary.contains("Check the deployment"))
        );
        assert!(autonomy::sweep(&conn).unwrap().is_empty(), "not due yet");

        conn.execute(
            "UPDATE pot_reminders SET due_at=?2 WHERE id=?1",
            params![reminder, now_ms() - 1],
        )
        .unwrap();
        assert_eq!(
            autonomy::sweep(&conn).unwrap(),
            vec![("alice".to_owned(), pot.clone())]
        );
        let queued = wakes(&conn, &pot);
        assert_eq!(
            (queued[0].0.as_str(), queued[0].1.as_str()),
            ("reminder", "Check the deployment")
        );
        let state: String = conn
            .query_row(
                "SELECT state FROM pot_reminders WHERE id=?1",
                [&reminder],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(state, "delivered");
        assert!(autonomy::sweep(&conn).unwrap().is_empty(), "only once");

        // Invalid times.
        assert_eq!(
            autonomy::create_reminder(&conn, "alice", &pot, now_ms() - 1, "Past")
                .unwrap_err()
                .code,
            "invalid_input"
        );
        assert_eq!(
            autonomy::create_reminder(
                &conn,
                "alice",
                &pot,
                now_ms() + 366 * 86_400_000,
                "Too far",
            )
            .unwrap_err()
            .code,
            "invalid_input"
        );
        // At most 50 pending.
        for index in 0..MAX_PENDING_REMINDERS {
            autonomy::create_reminder(
                &conn,
                "alice",
                &pot,
                now_ms() + 60_000,
                &format!("Reminder {index}"),
            )
            .unwrap();
        }
        assert_eq!(
            autonomy::create_reminder(&conn, "alice", &pot, now_ms() + 60_000, "One more")
                .unwrap_err()
                .code,
            "limit_reached"
        );
    }

    fn context(app: &AppState, session: &crate::db::Session) -> OpContext {
        let mut mode = pirc_protocol::mode::default_work();
        mode.pot = true;
        OpContext {
            session: session.clone(),
            workspace: app.db.lock().get_workspace("node:repo").unwrap(),
            mode,
            user: "alice".to_owned(),
        }
    }

    async fn op(app: &AppState, context: &OpContext, name: &str, args: Value) -> ApiResult<Value> {
        let parsed = ops::parse_op(name, &args)
            .expect("a pot operation")
            .expect("valid arguments");
        ops::run_op(app, context, parsed).await
    }

    #[tokio::test]
    async fn the_pot_operations_change_its_own_settings_and_log_them() {
        let (app, _dir) = app_with_models(json!({}));
        super::db_setup(&app.db.lock());
        let mut created = input("Tester");
        created.permissions.work_locations.clear();
        created.models.work_models.clear();
        created.permissions.reach = super::Reach::Observe;
        let pot = super::create(&mut app.db.lock(), "alice", created)
            .unwrap()
            .id;
        let session = app
            .db
            .lock()
            .create_session("node:repo", "node://node/s1", "node", "s1", "alice")
            .unwrap();
        app.db
            .lock()
            .execute(
                "UPDATE pot_runtime SET session_id=?1 WHERE pot_id=?2",
                params![session.id, pot],
            )
            .unwrap();
        let context = context(&app, &session);

        let saved = op(
            &app,
            &context,
            "pot.autonomy.set",
            json!({ "intervalS": 7200, "reason": "a deadline" }),
        )
        .await
        .unwrap();
        assert_eq!(saved["intervalS"], 7200);
        let read = super::read(&app.db.lock(), "alice", &pot).unwrap();
        assert_eq!(
            (read.revision, read.input.autonomy.interval_s),
            (2, Some(7200))
        );
        let log = activities(&app.db.lock(), &pot);
        assert!(
            log.iter().any(|(kind, summary)| kind == "autonomy_changed"
                && summary.contains("a deadline")),
            "{log:?}"
        );
        assert_eq!(
            op(
                &app,
                &context,
                "pot.autonomy.set",
                json!({ "intervalS": 60, "reason": "too often" })
            )
            .await
            .unwrap_err()
            .code,
            "invalid_input"
        );
        let off = op(
            &app,
            &context,
            "pot.autonomy.set",
            json!({ "intervalS": null, "reason": "quiet" }),
        )
        .await
        .unwrap();
        assert!(off["intervalS"].is_null());
        assert!(off["nextReviewAt"].is_null());

        let thinking = op(
            &app,
            &context,
            "pot.thinking.set",
            json!({ "level": "high", "reason": "hard work" }),
        )
        .await
        .unwrap();
        assert_eq!(thinking["level"], "high");
        let level: String = app
            .db
            .lock()
            .query_row(
                "SELECT thinking FROM pot_runtime WHERE pot_id=?1",
                [&pot],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(level, "high");
        assert!(
            activities(&app.db.lock(), &pot)
                .iter()
                .any(|(kind, summary)| kind == "thinking_adjust" && summary.contains("hard work"))
        );
        app.db
            .lock()
            .execute(
                "UPDATE pot_runtime SET thinking_auto=0 WHERE pot_id=?1",
                [&pot],
            )
            .unwrap();
        assert_eq!(
            op(
                &app,
                &context,
                "pot.thinking.set",
                json!({ "level": "low", "reason": "try" })
            )
            .await
            .unwrap_err()
            .code,
            "thinking_fixed"
        );
        app.db
            .lock()
            .execute(
                "UPDATE pot_runtime SET thinking_auto=1 WHERE pot_id=?1",
                [&pot],
            )
            .unwrap();

        let reminder = op(
            &app,
            &context,
            "pot.reminder.create",
            json!({ "at": now_ms() + 60_000, "note": "Check the deploy" }),
        )
        .await
        .unwrap();
        assert!(reminder["id"].as_str().unwrap().starts_with("rem"));
        assert_eq!(
            op(
                &app,
                &context,
                "pot.reminder.create",
                json!({ "at": now_ms() - 1, "note": "Past" })
            )
            .await
            .unwrap_err()
            .code,
            "invalid_input"
        );

        let main = ModelChoice {
            provider: read.input.models.main.provider.clone(),
            model: read.input.models.main.model.clone(),
        };
        let fallback = ModelChoice {
            provider: read.input.models.fallbacks[0].provider.clone(),
            model: read.input.models.fallbacks[0].model.clone(),
        };
        let moved = op(
            &app,
            &context,
            "pot.fallback",
            json!({
                "from": { "provider": main.provider.clone(), "model": main.model.clone() },
                "to": { "provider": fallback.provider.clone(), "model": fallback.model.clone() },
                "reason": "rate limited"
            }),
        )
        .await
        .unwrap();
        assert_eq!(moved["activeFallback"], 1);
        assert!(
            activities(&app.db.lock(), &pot)
                .iter()
                .any(|(kind, summary)| kind == "fallback" && summary.contains("rate limited"))
        );
        // A fallback never moves backwards.
        assert_eq!(
            op(
                &app,
                &context,
                "pot.fallback",
                json!({
                    "from": { "provider": fallback.provider.clone(), "model": fallback.model.clone() },
                    "to": { "provider": main.provider.clone(), "model": main.model.clone() },
                    "reason": "back"
                })
            )
            .await
            .unwrap_err()
            .code,
            "invalid_input"
        );
        let view = ops::context(&app.db.lock(), "alice", &session.id).unwrap();
        assert_eq!(view["models"]["main"]["model"], main.model.as_str());
        assert_eq!(view["models"]["activeFallback"], 1);
        assert_eq!(view["models"]["thinking"], "high");
        assert_eq!(view["models"]["thinkingAuto"], true);
        // Without a session mapping the asking session is no pot.
        app.db
            .lock()
            .execute(
                "UPDATE pot_runtime SET session_id=NULL WHERE pot_id=?1",
                [&pot],
            )
            .unwrap();
        assert_eq!(
            op(
                &app,
                &context,
                "pot.autonomy.set",
                json!({ "intervalS": 3600, "reason": "x" })
            )
            .await
            .unwrap_err()
            .code,
            "not_a_pot"
        );
    }

    #[test]
    fn the_operations_parse_their_arguments() {
        assert!(matches!(
            ops::parse_op(
                "pot.autonomy.set",
                &json!({ "intervalS": null, "reason": "x" })
            ),
            Some(Ok(Op::AutonomySet(_)))
        ));
        assert!(matches!(
            ops::parse_op("pot.reminder.create", &json!({ "at": 1, "note": "x" })),
            Some(Ok(Op::ReminderCreate(_)))
        ));
        assert!(matches!(
            ops::parse_op(
                "pot.thinking.set",
                &json!({ "level": "high", "reason": "x" })
            ),
            Some(Ok(Op::ThinkingSet(_)))
        ));
        assert!(matches!(
            ops::parse_op(
                "pot.fallback",
                &json!({
                    "from": { "provider": "p", "model": "a" },
                    "to": { "provider": "p", "model": "b" }
                })
            ),
            Some(Ok(Op::Fallback(_)))
        ));
        assert!(matches!(
            ops::parse_op("pot.autonomy.set", &json!({ "intervalS": 60 })),
            Some(Ok(_))
        ));
        assert!(matches!(
            ops::parse_op("pot.reminder.create", &json!({ "at": "tomorrow" })),
            Some(Err(()))
        ));
    }
}

mod threads {
    use super::super::threads::{self, GroupInput, Target};
    use super::*;

    fn pot(conn: &mut rusqlite::Connection, name: &str, send: DmRule, receive: DmRule) -> String {
        let mut input = input(name);
        input.permissions.dm.send = send;
        input.permissions.dm.receive = receive;
        create(conn, "alice", input).unwrap().id
    }

    fn queued(conn: &rusqlite::Connection, pot: &str) -> Vec<(String, String)> {
        conn.prepare("SELECT source, content FROM pot_wakes WHERE pot_id=?1 ORDER BY rowid")
            .unwrap()
            .query_map([pot], |r| Ok((r.get(0)?, r.get(1)?)))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap()
    }

    #[test]
    fn a_direct_thread_wakes_its_pot_and_the_reply_is_posted_back() {
        let db = db();
        let mut conn = db.lock();
        let tester = pot(&mut conn, "Tester", DmRule::All, DmRule::All);
        let thread = threads::direct(&conn, "alice", &tester).unwrap();
        assert_eq!(
            threads::direct(&conn, "alice", &tester).unwrap().id,
            thread.id
        );
        assert_eq!(
            threads::direct(&conn, "bob", &tester).unwrap_err().status,
            404
        );
        let (message, woken) =
            threads::post_user(&conn, "alice", &thread.id, "How did it go?", vec![], false)
                .unwrap();
        assert_eq!((message.seq, message.author_kind.as_str()), (1, "user"));
        assert_eq!(woken, vec![tester.clone()]);
        let wakes = queued(&conn, &tester);
        assert_eq!(wakes[0].0, "user");
        assert!(wakes[0].1.ends_with("How did it go?"), "{}", wakes[0].1);
        // @all is for groups; mentions must be members.
        assert_eq!(
            threads::post_user(&conn, "alice", &thread.id, "x", vec![], true)
                .unwrap_err()
                .status,
            400
        );
        // The settled wake's answer becomes the pot's message.
        conn.execute(
            "UPDATE pot_wakes SET state='settled', reply='All green.' WHERE pot_id=?1",
            [&tester],
        )
        .unwrap();
        let wake: String = conn
            .query_row("SELECT id FROM pot_wakes WHERE pot_id=?1", [&tester], |r| {
                r.get(0)
            })
            .unwrap();
        let reply = threads::post_reply(&conn, &wake).unwrap().unwrap();
        assert_eq!(
            (reply.seq, reply.author_id.as_deref()),
            (2, Some(tester.as_str()))
        );
        let page = threads::messages(&conn, "alice", &thread.id, None).unwrap();
        assert_eq!(
            page.iter().map(|m| m.body.as_str()).collect::<Vec<_>>(),
            ["How did it go?", "All green."]
        );
        assert_eq!(
            threads::messages(&conn, "alice", &thread.id, Some(2))
                .unwrap()
                .len(),
            1
        );
        assert_eq!(
            threads::messages(&conn, "bob", &thread.id, None)
                .unwrap_err()
                .status,
            404
        );
    }

    #[test]
    fn a_group_wakes_the_host_mentions_or_everyone() {
        let db = db();
        let mut conn = db.lock();
        let host = pot(&mut conn, "Host", DmRule::All, DmRule::All);
        let member = pot(&mut conn, "Member", DmRule::All, DmRule::All);
        let third = pot(&mut conn, "Third", DmRule::All, DmRule::Off);
        let group = threads::create_group(
            &conn,
            "alice",
            GroupInput {
                name: "Release".into(),
                avatar_color: Some(3),
                host_pot_id: host.clone(),
                member_pot_ids: vec![member.clone(), third.clone()],
                project_id: None,
            },
        )
        .unwrap();
        assert_eq!(group.pots.len(), 3);
        let post = |body: &str, mentions: Vec<String>, all: bool| {
            let mut woken = threads::post_user(&conn, "alice", &group.id, body, mentions, all)
                .unwrap()
                .1;
            woken.sort();
            woken
        };
        assert_eq!(post("Status?", vec![], false), vec![host.clone()]);
        assert_eq!(
            post("@Member go", vec![member.clone()], false),
            vec![member.clone()]
        );
        let mut all = vec![host.clone(), member.clone(), third.clone()];
        all.sort();
        assert_eq!(post("Everyone", vec![], true), all);
        assert_eq!(queued(&conn, &host)[0].0, "group");
        // Outsiders cannot be mentioned; a group needs two pots.
        let outsider = pot(&mut conn, "Outsider", DmRule::All, DmRule::All);
        assert_eq!(
            threads::post_user(
                &conn,
                "alice",
                &group.id,
                "x",
                vec![outsider.clone()],
                false
            )
            .unwrap_err()
            .status,
            400
        );
        let lonely = GroupInput {
            name: "Solo".into(),
            avatar_color: None,
            host_pot_id: host.clone(),
            member_pot_ids: vec![host.clone()],
            project_id: None,
        };
        assert_eq!(
            threads::create_group(&conn, "alice", lonely)
                .unwrap_err()
                .status,
            400
        );

        // A pot's mention wakes only members its and their DM rules allow,
        // and a pot can never address everyone.
        let (_, woken) = threads::post_pot(
            &conn,
            "alice",
            &host,
            Target::Thread(&group.id),
            "Third, Member: look",
            vec![member.clone(), third.clone()],
            None,
        )
        .unwrap();
        assert_eq!(woken, vec![member.clone()]);
        let (_, woken) = threads::post_pot(
            &conn,
            "alice",
            &host,
            Target::Thread(&group.id),
            "Noted",
            vec![],
            None,
        )
        .unwrap();
        assert!(woken.is_empty());
        assert_eq!(
            threads::post_pot(
                &conn,
                "alice",
                &outsider,
                Target::Thread(&group.id),
                "Hi",
                vec![],
                None
            )
            .unwrap_err()
            .code,
            "not_a_member"
        );
    }

    #[test]
    fn a_card_lands_in_the_thread_of_the_wake_being_handled() {
        let db = db();
        let mut conn = db.lock();
        let host = pot(&mut conn, "Host", DmRule::All, DmRule::All);
        let member = pot(&mut conn, "Member", DmRule::All, DmRule::All);
        let group = threads::create_group(
            &conn,
            "alice",
            GroupInput {
                name: "Release".into(),
                avatar_color: None,
                host_pot_id: host.clone(),
                member_pot_ids: vec![member],
                project_id: None,
            },
        )
        .unwrap();
        let card = || threads::Card::BudgetRequest {
            request_id: "b1".into(),
        };
        // No wake in hand: the pot's direct thread.
        let quiet = threads::post_card(&conn, "alice", &host, "Budget request", card()).unwrap();
        assert_eq!(
            quiet.thread_id,
            threads::direct(&conn, "alice", &host).unwrap().id
        );
        // Handling a group message: the group.
        threads::post_user(&conn, "alice", &group.id, "Ship it", vec![], false).unwrap();
        conn.execute(
            "UPDATE pot_wakes SET state='delivered' WHERE pot_id=?1",
            [&host],
        )
        .unwrap();
        let shown = threads::post_card(&conn, "alice", &host, "Budget request", card()).unwrap();
        assert_eq!(shown.thread_id, group.id);
        assert_eq!(
            (shown.author_kind.as_str(), shown.card.clone()),
            ("system", Some(card()))
        );
        let json = serde_json::to_value(&shown).unwrap();
        assert_eq!(
            json["card"],
            json!({ "kind": "budget_request", "requestId": "b1" })
        );
        // A card never wakes anyone.
        let queued: i64 = conn
            .query_row(
                "SELECT count(*) FROM pot_wakes WHERE state='queued'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(queued, 0);
        // Only system messages carry cards.
        assert!(
            conn.execute(
                "UPDATE messages SET card_json='{}' WHERE author_kind='user'",
                []
            )
            .is_err()
        );
    }

    #[test]
    fn a_direct_thread_is_made_even_at_the_thread_limit() {
        let db = db();
        let mut conn = db.lock();
        let a = pot(&mut conn, "A", DmRule::All, DmRule::All);
        let b = pot(&mut conn, "B", DmRule::All, DmRule::All);
        for i in 0..threads::MAX_THREADS {
            conn.execute(
                "INSERT INTO threads(id,owner_user,kind,name,created_at,updated_at) VALUES(?1,'alice','group','g',0,0)",
                [format!("filler-{i}")],
            )
            .unwrap();
        }
        let group = GroupInput {
            name: "One more".into(),
            avatar_color: None,
            host_pot_id: a.clone(),
            member_pot_ids: vec![b.clone()],
            project_id: None,
        };
        assert_eq!(
            threads::create_group(&conn, "alice", group)
                .unwrap_err()
                .code,
            "limit_reached"
        );
        assert_eq!(threads::direct(&conn, "alice", &a).unwrap().kind, "direct");
    }

    #[test]
    fn pot_messages_follow_both_pots_rules_and_are_read_only_to_the_user() {
        let db = db();
        let mut conn = db.lock();
        let talker = pot(&mut conn, "Talker", DmRule::All, DmRule::All);
        let open = pot(&mut conn, "Open", DmRule::All, DmRule::All);
        let closed = pot(&mut conn, "Closed", DmRule::All, DmRule::Off);
        let quiet = pot(&mut conn, "Quiet", DmRule::Off, DmRule::All);
        let send = |from: &str, to: &str| {
            threads::post_pot(
                &conn,
                "alice",
                from,
                Target::Pot(to),
                "Ping",
                vec![],
                Some("root-1"),
            )
        };
        let (message, woken) = send(&talker, &open).unwrap();
        assert_eq!(woken, vec![open.clone()]);
        assert_eq!(queued(&conn, &open)[0].0, "dm");
        // The DM thread is the same both ways, and the user cannot post in it.
        let (back, _) = send(&open, &talker).unwrap();
        assert_eq!(back.thread_id, message.thread_id);
        assert_eq!(
            threads::post_user(&conn, "alice", &message.thread_id, "x", vec![], false)
                .unwrap_err()
                .code,
            "read_only"
        );
        assert_eq!(send(&talker, &closed).unwrap_err().code, "dm_refused");
        assert_eq!(send(&quiet, &open).unwrap_err().code, "dm_refused");
        assert_eq!(send(&talker, &talker).unwrap_err().status, 400);
        // Selected rules name the pots.
        let mut picky = input("Picky");
        picky.permissions.dm.receive = DmRule::Selected;
        picky.permissions.dm.receive_from = vec![open.clone()];
        let picky = create(&mut conn, "alice", picky).unwrap().id;
        assert!(threads::dm_allowed(&conn, "alice", &open, &picky).unwrap());
        assert!(!threads::dm_allowed(&conn, "alice", &talker, &picky).unwrap());
        // Every thread is listed for the user.
        assert_eq!(threads::list(&conn, "alice").unwrap().len(), 1);
        assert!(threads::list(&conn, "bob").unwrap().is_empty());
    }
}

mod approvals {
    use super::super::approvals::{self, Answer, ApprovalState, Decision, NewApproval};
    use super::super::threads;
    use super::*;

    fn ask() -> NewApproval {
        NewApproval {
            work_title: "Nightly release".into(),
            workspace_id: "node:repo".into(),
            provider: "oauth:anthropic".into(),
            model: "claude-opus-5".into(),
            thinking: Some("high".into()),
            reason: "The release notes need a careful read".into(),
            estimate_micros: 2_000_000,
            remaining_micros: Some(20_000_000),
        }
    }

    fn allow() -> Answer {
        Answer {
            answer: Decision::AllowOnce,
            reason: None,
        }
    }

    fn deny(reason: Option<&str>) -> Answer {
        Answer {
            answer: Decision::Deny,
            reason: reason.map(str::to_owned),
        }
    }

    #[test]
    fn only_ask_work_models_need_an_approval() {
        let db = db();
        let mut conn = db.lock();
        let pot = create(&mut conn, "alice", input("Tester")).unwrap();
        // A direct work model starts immediately; it is not an approval.
        let direct = NewApproval {
            model: "claude-fable-5".into(),
            ..ask()
        };
        let error = approvals::request(&conn, "alice", &pot.id, direct).unwrap_err();
        assert_eq!((error.status, error.code), (400, "invalid_input"));
        // Models outside the pot's work models are refused the same way.
        let mut main = ask();
        main.model = "gpt-5".into();
        main.provider = "work-openai".into();
        let error = approvals::request(&conn, "alice", &pot.id, main).unwrap_err();
        assert_eq!((error.status, error.code), (400, "invalid_input"));
        let mut unknown = ask();
        unknown.model = "claude-unknown".into();
        assert_eq!(
            approvals::request(&conn, "alice", &pot.id, unknown)
                .unwrap_err()
                .status,
            400
        );
        // An archived pot asks nothing.
        set_state(&mut conn, "alice", &pot.id, 1, PotState::Archived).unwrap();
        let error = approvals::request(&conn, "alice", &pot.id, ask()).unwrap_err();
        assert_eq!((error.status, error.code), (409, "pot_archived"));
    }

    #[test]
    fn allow_once_is_consumed_by_exactly_one_start() {
        let db = db();
        let mut conn = db.lock();
        let pot = create(&mut conn, "alice", input("Tester")).unwrap();
        let first = approvals::request(&conn, "alice", &pot.id, ask()).unwrap();
        assert_eq!(first.state, ApprovalState::Pending);
        assert_eq!(first.thinking.as_deref(), Some("high"));
        assert_eq!(first.estimate_micros, 2_000_000);
        assert_eq!(first.remaining_micros, Some(20_000_000));
        let answered = approvals::answer(&mut conn, "alice", &first.id, allow()).unwrap();
        assert_eq!(answered.state, ApprovalState::AllowedOnce);
        assert!(answered.answered_at.is_some());
        approvals::consume(
            &conn,
            "alice",
            &first.id,
            &pot.id,
            "oauth:anthropic",
            "claude-opus-5",
        )
        .unwrap();
        let used = approvals::read(&conn, "alice", &first.id).unwrap();
        assert_eq!(used.state, ApprovalState::Used);
        assert!(used.used_at.is_some());
        // The one start took the allow; a second is refused and needs a new one.
        assert_eq!(
            approvals::consume(
                &conn,
                "alice",
                &first.id,
                &pot.id,
                "oauth:anthropic",
                "claude-opus-5"
            )
            .unwrap_err()
            .code,
            "already_answered"
        );
        let second = approvals::request(&conn, "alice", &pot.id, ask()).unwrap();
        assert_ne!(second.id, first.id);
        assert_eq!(
            approvals::list(&conn, "alice", Some(ApprovalState::Pending)).unwrap(),
            vec![second]
        );
    }

    #[test]
    fn the_wrong_pot_or_model_cannot_consume_an_allow() {
        let db = db();
        let mut conn = db.lock();
        let pot = create(&mut conn, "alice", input("Tester")).unwrap();
        let other = create(&mut conn, "alice", input("Researcher")).unwrap();
        let approval = approvals::request(&conn, "alice", &pot.id, ask()).unwrap();
        approvals::answer(&mut conn, "alice", &approval.id, allow()).unwrap();
        let consume = |owner: &str, pot: &str, provider: &str, model: &str| {
            approvals::consume(&conn, owner, &approval.id, pot, provider, model)
        };
        assert_eq!(
            consume("alice", &other.id, "oauth:anthropic", "claude-opus-5")
                .unwrap_err()
                .code,
            "approval_mismatch"
        );
        assert_eq!(
            consume("alice", &pot.id, "oauth:anthropic", "claude-fable-5")
                .unwrap_err()
                .code,
            "approval_mismatch"
        );
        assert_eq!(
            consume("alice", &pot.id, "work-openai", "claude-opus-5")
                .unwrap_err()
                .code,
            "approval_mismatch"
        );
        assert_eq!(
            consume("bob", &pot.id, "oauth:anthropic", "claude-opus-5")
                .unwrap_err()
                .status,
            404
        );
        assert_eq!(
            approvals::read(&conn, "alice", &approval.id).unwrap().state,
            ApprovalState::AllowedOnce
        );
        consume("alice", &pot.id, "oauth:anthropic", "claude-opus-5").unwrap();
    }

    #[test]
    fn a_denied_approval_cannot_be_consumed() {
        let db = db();
        let mut conn = db.lock();
        let pot = create(&mut conn, "alice", input("Tester")).unwrap();
        let approval = approvals::request(&conn, "alice", &pot.id, ask()).unwrap();
        approvals::answer(&mut conn, "alice", &approval.id, deny(None)).unwrap();
        assert_eq!(
            approvals::consume(
                &conn,
                "alice",
                &approval.id,
                &pot.id,
                "oauth:anthropic",
                "claude-opus-5"
            )
            .unwrap_err()
            .code,
            "already_answered"
        );
        assert_eq!(
            approvals::read(&conn, "alice", &approval.id).unwrap().state,
            ApprovalState::Denied
        );
    }

    #[test]
    fn a_denial_reason_is_a_system_message_and_every_answer_wakes_the_pot() {
        let db = db();
        let mut conn = db.lock();
        let pot = create(&mut conn, "alice", input("Tester")).unwrap();
        let thread = threads::direct(&conn, "alice", &pot.id).unwrap();
        let approval = approvals::request(&conn, "alice", &pot.id, ask()).unwrap();
        approvals::answer(
            &mut conn,
            "alice",
            &approval.id,
            deny(Some("Too expensive this month")),
        )
        .unwrap();
        let page = threads::messages(&conn, "alice", &thread.id, None).unwrap();
        // The request's card comes first, pointing at the approval.
        assert_eq!(
            page[0].card,
            Some(threads::Card::ModelApproval {
                approval_id: approval.id.clone()
            })
        );
        let notice = page.last().unwrap();
        assert_eq!((notice.seq, notice.author_kind.as_str()), (2, "system"));
        assert_eq!(notice.card, None);
        assert_eq!(notice.author_id, None);
        assert!(notice.body.contains("Nightly release"), "{}", notice.body);
        assert!(
            notice.body.contains("Too expensive this month"),
            "{}",
            notice.body
        );
        let wake = |conn: &rusqlite::Connection| -> (String, String, serde_json::Value) {
            let (source, content, details): (String, String, String) = conn
                .query_row(
                    "SELECT source,content,details_json FROM pot_wakes WHERE pot_id=?1
                     ORDER BY rowid DESC LIMIT 1",
                    [&pot.id],
                    |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
                )
                .unwrap();
            (source, content, serde_json::from_str(&details).unwrap())
        };
        let (source, content, details) = wake(&conn);
        assert_eq!(source, "approval");
        assert!(content.contains("Nightly release"), "{content}");
        assert!(content.contains("claude-opus-5"), "{content}");
        assert!(
            content.contains("denied with the reason: Too expensive this month"),
            "{content}"
        );
        assert_eq!(details["approvalId"], approval.id.as_str());
        assert_eq!(details["state"], "denied");
        // A plain denial and an allow also wake the pot.
        let plain = approvals::request(&conn, "alice", &pot.id, ask()).unwrap();
        approvals::answer(&mut conn, "alice", &plain.id, deny(None)).unwrap();
        assert!(wake(&conn).1.contains("denied"));
        let allowed = approvals::request(&conn, "alice", &pot.id, ask()).unwrap();
        approvals::answer(&mut conn, "alice", &allowed.id, allow()).unwrap();
        let (source, content, details) = wake(&conn);
        assert_eq!(source, "approval");
        assert!(content.contains("allowed once"), "{content}");
        assert_eq!(details["approvalId"], allowed.id.as_str());
        assert_eq!(details["state"], "allowed_once");
        // Three request cards and the one reason; answers without text add
        // no messages.
        assert_eq!(
            threads::messages(&conn, "alice", &thread.id, None)
                .unwrap()
                .len(),
            4
        );
    }

    #[test]
    fn an_approval_is_answered_once_and_only_by_its_owner() {
        let db = db();
        let mut conn = db.lock();
        let pot = create(&mut conn, "alice", input("Tester")).unwrap();
        let approval = approvals::request(&conn, "alice", &pot.id, ask()).unwrap();
        approvals::answer(&mut conn, "alice", &approval.id, deny(None)).unwrap();
        let error = approvals::answer(&mut conn, "alice", &approval.id, allow()).unwrap_err();
        assert_eq!((error.status, error.code), (409, "already_answered"));
        // Another owner can neither see nor answer it.
        assert!(approvals::list(&conn, "bob", None).unwrap().is_empty());
        assert_eq!(
            approvals::read(&conn, "bob", &approval.id)
                .unwrap_err()
                .status,
            404
        );
        assert_eq!(
            approvals::answer(&mut conn, "bob", &approval.id, allow())
                .unwrap_err()
                .status,
            404
        );
        assert_eq!(
            approvals::request(&conn, "bob", &pot.id, ask())
                .unwrap_err()
                .status,
            404
        );
        assert_eq!(
            approvals::answer(&mut conn, "alice", "appr-missing", allow())
                .unwrap_err()
                .status,
            404
        );
    }

    #[test]
    fn pending_approvals_are_capped_and_listed_newest_first() {
        let db = db();
        let mut conn = db.lock();
        let pot = create(&mut conn, "alice", input("Tester")).unwrap();
        let mut ids = Vec::new();
        for _ in 0..approvals::MAX_PENDING {
            ids.push(
                approvals::request(&conn, "alice", &pot.id, ask())
                    .unwrap()
                    .id,
            );
        }
        let error = approvals::request(&conn, "alice", &pot.id, ask()).unwrap_err();
        assert_eq!((error.status, error.code), (409, "limit_reached"));
        let pending = approvals::list(&conn, "alice", Some(ApprovalState::Pending)).unwrap();
        assert_eq!(
            pending.iter().map(|a| a.id.as_str()).collect::<Vec<_>>(),
            ids.iter().rev().map(String::as_str).collect::<Vec<_>>()
        );
        // Answering frees a slot.
        approvals::answer(&mut conn, "alice", &ids[0], deny(None)).unwrap();
        approvals::request(&conn, "alice", &pot.id, ask()).unwrap();
    }

    mod http {
        use super::*;
        use crate::test_support::{app_with_models, call};
        use serde_json::Value;
        use std::sync::Arc;
        use std::sync::atomic::{AtomicBool, Ordering};

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

        async fn create_pot(app: &crate::app::AppState) -> String {
            let body = serde_json::to_value(input("Tester")).unwrap();
            let (status, created) =
                call(app, "POST", "/api/pots", Some("alice"), None, Some(body)).await;
            assert_eq!(status, 201, "{created}");
            created["pot"]["id"].as_str().unwrap().to_owned()
        }

        #[tokio::test]
        async fn approvals_are_listed_and_answered_over_http() {
            let (app, _dir) = app();
            let pot = create_pot(&app).await;
            let fired = Arc::new(AtomicBool::new(false));
            let flag = fired.clone();
            let _hint = app.hints.approvals.add(
                "alice".into(),
                Arc::new(move || flag.store(true, Ordering::SeqCst)),
            );
            let approval = app.request_approval("alice", &pot, ask()).unwrap();
            assert!(fired.swap(false, Ordering::SeqCst), "request hints");
            let path = "/api/model-approvals?state=pending";
            let (status, listed) = call(&app, "GET", path, Some("alice"), None, None).await;
            assert_eq!(status, 200, "{listed}");
            assert_eq!(listed["approvals"][0]["id"], approval.id.as_str());
            assert_eq!(listed["approvals"][0]["model"], "claude-opus-5");
            assert_eq!(listed["approvals"][0]["estimateMicros"], 2_000_000);
            let one = format!("/api/model-approvals/{}", approval.id);
            let (status, read) = call(&app, "GET", &one, Some("alice"), None, None).await;
            assert_eq!(
                (status, read["approval"]["id"].as_str()),
                (200, Some(approval.id.as_str()))
            );
            assert_eq!(
                call(&app, "GET", &one, Some("bob"), None, None).await.0,
                404
            );
            assert_eq!(
                call(
                    &app,
                    "GET",
                    "/api/model-approvals?state=unknown",
                    Some("alice"),
                    None,
                    None
                )
                .await
                .0,
                400
            );
            assert!(
                call(&app, "GET", "/api/model-approvals", Some("bob"), None, None)
                    .await
                    .1["approvals"]
                    .as_array()
                    .unwrap()
                    .is_empty()
            );

            let answer = format!("/api/model-approvals/{}/answer", approval.id);
            // Unknown fields and a reason with allow_once are refused.
            assert_eq!(
                call(
                    &app,
                    "POST",
                    &answer,
                    Some("alice"),
                    None,
                    Some(json!({ "answer": "deny", "approval": "x" }))
                )
                .await
                .0,
                400
            );
            assert_eq!(
                call(
                    &app,
                    "POST",
                    &answer,
                    Some("alice"),
                    None,
                    Some(json!({ "answer": "allow_once", "reason": "why not" }))
                )
                .await
                .0,
                400
            );
            assert_eq!(
                call(
                    &app,
                    "POST",
                    &answer,
                    Some("bob"),
                    None,
                    Some(json!({ "answer": "deny" }))
                )
                .await
                .0,
                404
            );

            let (status, answered) = call(
                &app,
                "POST",
                &answer,
                Some("alice"),
                None,
                Some(json!({ "answer": "deny", "reason": "Not this month" })),
            )
            .await;
            assert_eq!(status, 200, "{answered}");
            assert_eq!(answered["approval"]["state"], "denied");
            assert_eq!(answered["approval"]["denyReason"], "Not this month");
            assert!(fired.swap(false, Ordering::SeqCst), "answer hints");
            // Answering twice is a conflict.
            let (status, error) = call(
                &app,
                "POST",
                &answer,
                Some("alice"),
                None,
                Some(json!({ "answer": "allow_once" })),
            )
            .await;
            assert_eq!(
                (status, error["error"]["code"].as_str()),
                (409, Some("already_answered"))
            );
            let (_, pending) = call(&app, "GET", path, Some("alice"), None, None).await;
            assert_eq!(pending["approvals"], Value::Array(Vec::new()));
            let (_, denied) = call(
                &app,
                "GET",
                "/api/model-approvals?state=denied",
                Some("alice"),
                None,
                None,
            )
            .await;
            assert_eq!(denied["approvals"].as_array().unwrap().len(), 1);
            // The denial reason is a system message in the pot's thread.
            let (_, thread) = call(
                &app,
                "GET",
                &format!("/api/pots/{pot}/thread"),
                Some("alice"),
                None,
                None,
            )
            .await;
            let (_, page) = call(
                &app,
                "GET",
                &format!(
                    "/api/threads/{}/messages",
                    thread["thread"]["id"].as_str().unwrap()
                ),
                Some("alice"),
                None,
                None,
            )
            .await;
            assert_eq!(page["messages"][0]["card"]["kind"], "model_approval");
            assert_eq!(page["messages"][1]["authorKind"], "system");
            assert!(
                page["messages"][1]["body"]
                    .as_str()
                    .unwrap()
                    .contains("Not this month")
            );
        }
    }
}

mod activity {
    use super::super::activity::{self, Entry, Kind};
    use super::super::threads::{self, Target};
    use super::*;

    fn rows(
        conn: &rusqlite::Connection,
        owner: &str,
    ) -> Vec<(Option<String>, String, String, String)> {
        conn.prepare("SELECT pot_id, pot_name, kind, summary FROM pot_activity WHERE owner_user=?1 ORDER BY rowid")
            .unwrap()
            .query_map([owner], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap()
    }

    #[test]
    fn lifecycle_changes_and_pot_messages_are_logged() {
        let db = db();
        let mut conn = db.lock();
        let mut a = input("Tester");
        a.permissions.dm.receive = DmRule::All;
        let a = create(&mut conn, "alice", a).unwrap();
        let mut b = input("Helper");
        b.permissions.dm.receive = DmRule::All;
        let b = create(&mut conn, "alice", b).unwrap();
        let mut profile = a.input.profile.clone();
        profile.personality = "Warmer.".into();
        update(
            &mut conn,
            "alice",
            &a.id,
            PotPatch {
                revision: 1,
                profile: Some(profile),
                ..PotPatch::default()
            },
        )
        .unwrap();
        set_state(&mut conn, "alice", &a.id, 2, PotState::Paused).unwrap();
        set_state(&mut conn, "alice", &a.id, 3, PotState::Archived).unwrap();
        set_state(&mut conn, "alice", &a.id, 4, PotState::Paused).unwrap();
        threads::post_pot(
            &conn,
            "alice",
            &b.id,
            Target::Pot(&a.id),
            "Ping\nmore",
            vec![],
            Some("root"),
        )
        .unwrap();
        let kinds: Vec<(String, String)> = rows(&conn, "alice")
            .into_iter()
            .map(|(_, name, kind, _)| (name, kind))
            .collect();
        let expected = [
            ("Tester", "created"),
            ("Helper", "created"),
            ("Tester", "updated"),
            ("Tester", "paused"),
            ("Tester", "archived"),
            ("Tester", "restored"),
            ("Helper", "dm"),
        ];
        assert_eq!(kinds, expected.map(|(n, k)| (n.to_owned(), k.to_owned())));
        let all = rows(&conn, "alice");
        assert_eq!(all[2].3, "The user changed: profile");
        assert_eq!(all[6].3, "Message to Tester: Ping");
        let root: String = conn
            .query_row(
                "SELECT causal_root FROM pot_activity WHERE kind='dm'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(root, "root");
        assert!(rows(&conn, "bob").is_empty());
    }

    #[test]
    fn activity_is_filtered_paged_and_expires_with_the_owners_retention() {
        let db = db();
        let mut conn = db.lock();
        let a = create(&mut conn, "alice", input("Tester")).unwrap();
        let b = create(&mut conn, "alice", input("Helper")).unwrap();
        for i in 0..5 {
            activity::log(
                &conn,
                "alice",
                &a.id,
                Entry::new(Kind::Review, format!("review {i}")),
            )
            .unwrap();
        }
        let query = |q: activity::Query| activity::list(&conn, "alice", &q);
        let all = query(activity::Query::default()).unwrap();
        assert_eq!(all.activity.len(), 7);
        assert_eq!(all.activity[0].summary, "review 4", "newest first");
        assert!(all.next_before.is_none());
        let only_b = query(activity::Query {
            pot_id: Some(b.id.clone()),
            ..Default::default()
        })
        .unwrap();
        assert_eq!(only_b.activity.len(), 1);
        let created = query(activity::Query {
            kind: Some("created, dm".into()),
            ..Default::default()
        })
        .unwrap();
        assert_eq!(created.activity.len(), 2);
        assert_eq!(
            query(activity::Query {
                kind: Some("nonsense".into()),
                ..Default::default()
            })
            .unwrap_err()
            .status,
            400
        );
        assert_eq!(
            query(activity::Query {
                limit: Some(0),
                ..Default::default()
            })
            .unwrap_err()
            .status,
            400
        );
        // Pages of three walk every row once.
        let mut seen = Vec::new();
        let mut before = None;
        loop {
            let page = query(activity::Query {
                limit: Some(3),
                before: before.clone(),
                ..Default::default()
            })
            .unwrap();
            seen.extend(page.activity.iter().map(|a| a.id.clone()));
            match page.next_before {
                Some(next) => before = Some(next),
                None => break,
            }
        }
        assert_eq!(
            seen,
            all.activity
                .iter()
                .map(|a| a.id.clone())
                .collect::<Vec<_>>()
        );
        assert_eq!(
            query(activity::Query {
                before: Some("act_unknown".into()),
                ..Default::default()
            })
            .unwrap_err()
            .status,
            400
        );
        assert!(
            activity::list(&conn, "bob", &activity::Query::default())
                .unwrap()
                .activity
                .is_empty()
        );

        // Retention: the default 90 days, or the owner's own setting.
        let day = 86_400_000;
        let now = crate::util::now_ms();
        conn.execute(
            "UPDATE pot_activity SET at=?1 WHERE summary='review 0'",
            [now - 91 * day],
        )
        .unwrap();
        conn.execute(
            "UPDATE pot_activity SET at=?1 WHERE summary='review 1'",
            [now - 10 * day],
        )
        .unwrap();
        assert_eq!(activity::sweep(&conn, now).unwrap(), 1);
        let mut settings = settings(&conn, "alice").unwrap();
        settings.activity_retention_days = 7;
        update_settings(&mut conn, "alice", settings).unwrap();
        assert_eq!(activity::sweep(&conn, now).unwrap(), 1);
        let left = activity::list(&conn, "alice", &activity::Query::default()).unwrap();
        assert_eq!(left.activity.len(), 5);
    }

    #[test]
    fn a_pots_view_shows_its_threads_and_what_it_sent() {
        let db = db();
        let mut conn = db.lock();
        let mut a = input("Tester");
        a.permissions.dm.receive = DmRule::All;
        let a = create(&mut conn, "alice", a).unwrap();
        let mut b = input("Helper");
        b.permissions.dm.receive = DmRule::Off;
        let b = create(&mut conn, "alice", b).unwrap();
        let c = create(&mut conn, "alice", input("Bystander")).unwrap();
        threads::direct(&conn, "alice", &c.id).unwrap();
        for i in 0..3 {
            threads::post_pot(
                &conn,
                "alice",
                &b.id,
                Target::Pot(&a.id),
                &format!("note {i}"),
                vec![],
                None,
            )
            .unwrap();
        }
        let view = super::super::view::view(&conn, "alice", &b.id, None).unwrap();
        assert_eq!(view.threads.len(), 1, "only the threads it is in");
        assert_eq!(
            view.sent
                .iter()
                .map(|m| m.body.as_str())
                .collect::<Vec<_>>(),
            ["note 2", "note 1", "note 0"]
        );
        assert!(
            super::super::view::view(&conn, "alice", &a.id, None)
                .unwrap()
                .sent
                .is_empty()
        );
        assert_eq!(
            super::super::view::view(&conn, "bob", &b.id, None)
                .unwrap_err()
                .status,
            404
        );
        // A DM refused by the receiver's rules is refused and logged.
        assert_eq!(
            threads::post_pot(
                &conn,
                "alice",
                &a.id,
                Target::Pot(&b.id),
                "hi",
                vec![],
                None
            )
            .unwrap_err()
            .code,
            "dm_refused"
        );
        let refused = activity::list(
            &conn,
            "alice",
            &activity::Query {
                pot_id: Some(a.id.clone()),
                kind: Some("dm".into()),
                ..Default::default()
            },
        )
        .unwrap();
        assert_eq!(
            refused.activity[0].summary,
            "Message to Helper refused by the message rules"
        );
    }

    #[test]
    fn a_row_keeps_the_pots_name_after_it_is_gone_and_summaries_are_bounded() {
        let db = db();
        let mut conn = db.lock();
        let pot = create(&mut conn, "alice", input("Tester")).unwrap();
        activity::log(
            &conn,
            "alice",
            &pot.id,
            Entry::new(Kind::Review, "é".repeat(1000)),
        )
        .unwrap();
        assert_eq!(
            rows(&conn, "alice")[1].3.chars().count(),
            activity::MAX_SUMMARY
        );
        assert_eq!(
            activity::log(&conn, "alice", &pot.id, Entry::new(Kind::Review, "  "))
                .unwrap_err()
                .status,
            400
        );
        // Another owner's pot cannot be logged against.
        assert_eq!(
            activity::log(&conn, "bob", &pot.id, Entry::new(Kind::Review, "x"))
                .unwrap_err()
                .status,
            404
        );
        conn.execute("DELETE FROM pots WHERE id=?1", [&pot.id])
            .unwrap();
        let left = rows(&conn, "alice");
        assert_eq!(left.len(), 2);
        assert!(
            left.iter()
                .all(|(id, name, _, _)| id.is_none() && name == "Tester")
        );
    }
}

mod work {
    use super::super::approvals::{self, Answer, Decision};
    use super::super::work;
    use crate::db::Store;
    use crate::nodes::ConnectedNode;
    use crate::test_support::app_with_models;
    use crate::util::now_ms;
    use pirc_protocol::{HttpMethod, ModeId, NodeHttpRequest, NodeHttpResponse};
    use serde_json::{Value, json};
    use std::sync::{Arc, Mutex};

    #[derive(Default)]
    struct Fake {
        delivered: Mutex<Vec<Value>>,
        sessions: Mutex<u32>,
        /// How the next deliveries end: "ok", "refuse" or "lose".
        delivery: Mutex<&'static str>,
        answered: Mutex<bool>,
    }

    fn node() -> ConnectedNode {
        ConnectedNode {
            id: "node".into(),
            role: pirc_protocol::NodeRole::Node,
            modes: vec![ModeId::new("directory").unwrap()],
            workspaces: vec![pirc_protocol::RegisteredWorkspace {
                checkpoint_private: false,
                id: "repo".into(),
                display_name: "Repo".into(),
                mode: ModeId::new("directory").unwrap(),
                roles: None,
                repo: None,
            }],
            connected_at: now_ms(),
            last_seen_at: now_ms(),
            added: Default::default(),
        }
    }

    fn respond(
        fake: &Fake,
        request: &NodeHttpRequest,
    ) -> crate::error::ApiResult<NodeHttpResponse> {
        let ok = |status, body: Value| {
            Ok(NodeHttpResponse {
                status,
                body: Some(body),
            })
        };
        let url = request.url.as_str();
        match request.method {
            HttpMethod::Post if url == "/api/session-creations/internal" => {
                let mut n = fake.sessions.lock().unwrap();
                *n += 1;
                ok(201, json!({ "session": { "id": format!("remote-{n}") } }))
            }
            HttpMethod::Patch => ok(200, json!({})),
            HttpMethod::Post if url.ends_with("/deliver") => match *fake.delivery.lock().unwrap() {
                "refuse" => ok(409, json!({ "error": { "message": "busy" } })),
                "lose" => {
                    fake.delivered
                        .lock()
                        .unwrap()
                        .push(request.payload.clone().unwrap());
                    Err(crate::error::ApiError::new(
                        504,
                        "node_timeout",
                        "Node request timed out",
                    ))
                }
                _ => {
                    fake.delivered
                        .lock()
                        .unwrap()
                        .push(request.payload.clone().unwrap());
                    ok(202, json!({ "delivered": true }))
                }
            },
            HttpMethod::Get if url.ends_with("/snapshot") => {
                let mut history: Vec<Value> = fake
                    .delivered
                    .lock()
                    .unwrap()
                    .iter()
                    .map(|m| json!({ "role": "custom", "customType": m["customType"], "content": m["content"], "details": m["details"] }))
                    .collect();
                let answered = *fake.answered.lock().unwrap();
                if answered {
                    history.push(json!({ "role": "assistant", "content": [{ "type": "text", "text": "Fixed the build." }] }));
                }
                ok(
                    200,
                    json!({ "history": history, "interactions": [],
                    "run": { "status": if answered { "succeeded" } else { "running" }, "createdAt": 1 } }),
                )
            }
            _ => panic!("unexpected Node request {:?} {url}", request.method),
        }
    }

    fn setup() -> (crate::app::AppState, tempfile::TempDir, Arc<Fake>) {
        let (app, dir) = app_with_models(json!({}));
        super::db_setup(&app.db.lock());
        let fake = Arc::new(Fake::default());
        *fake.delivery.lock().unwrap() = "ok";
        let handler = fake.clone();
        app.nodes
            .set_test_node(node(), move |request| respond(&handler, &request));
        (app, dir, fake)
    }

    fn pot(app: &crate::app::AppState, edit: impl FnOnce(&mut super::PotInput)) -> String {
        let mut input = super::input("Tester");
        edit(&mut input);
        super::create(&mut app.db.lock(), "alice", input)
            .unwrap()
            .id
    }

    fn open(model: Option<&str>, approval: Option<&str>) -> work::Open {
        serde_json::from_value(json!({
            "workspaceId": "node:repo", "title": "Fix CI", "instruction": "Make the build green.",
            "provider": model.map(|_| "oauth:anthropic"), "model": model, "approvalId": approval,
            "reason": "Hard bug",
        }))
        .unwrap()
    }

    fn activity_kinds(app: &crate::app::AppState) -> Vec<String> {
        let conn = app.db.lock();
        conn.prepare("SELECT kind FROM pot_activity ORDER BY rowid")
            .unwrap()
            .query_map([], |r| r.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap()
    }

    #[tokio::test]
    async fn a_pot_opens_work_with_a_direct_model_and_its_instruction_is_from_it() {
        let (app, _dir, fake) = setup();
        let pot = pot(&app, |_| {});
        let opened = work::open(&app, "alice", &pot, open(None, None))
            .await
            .unwrap();
        assert_eq!(opened["state"], "started");
        assert_eq!(opened["instruction"]["delivery"], "delivered");
        let delivered = fake.delivered.lock().unwrap()[0].clone();
        assert_eq!(delivered["customType"], "pot-instruction");
        assert_eq!(
            delivered["model"],
            json!({ "provider": "oauth:anthropic", "id": "claude-fable-5" })
        );
        assert!(
            delivered["content"]
                .as_str()
                .unwrap()
                .starts_with("Instruction from Tester, a pot")
        );
        assert_eq!(delivered["details"]["potId"], pot.as_str());
        let session = opened["work"]["sessionId"].as_str().unwrap().to_owned();
        assert_eq!(
            app.db.lock().get_session(&session).unwrap().workspace_id,
            "node:repo"
        );
        assert_eq!(
            activity_kinds(&app)[1..],
            ["work_opened", "work_instruction"]
        );
        let thread = crate::pots::threads::direct(&app.db.lock(), "alice", &pot).unwrap();
        let cards =
            crate::pots::threads::messages(&app.db.lock(), "alice", &thread.id, None).unwrap();
        let work_id = opened["work"]["id"].as_str().unwrap();
        assert_eq!(
            cards[0].card,
            Some(crate::pots::threads::Card::Work {
                work_id: work_id.to_owned(),
                session_id: session.clone(),
            })
        );
        assert_eq!(
            work::read(&app.db.lock(), "alice", work_id)
                .unwrap()
                .session_id,
            session
        );
        assert_eq!(
            work::read(&app.db.lock(), "bob", work_id)
                .unwrap_err()
                .status,
            404
        );
        // Status follows the last instruction to its answer.
        let status = work::status(&app, "alice", &pot, &session).await.unwrap();
        assert_eq!(status["run"], "working");
        *fake.answered.lock().unwrap() = true;
        let status = work::status(&app, "alice", &pot, &session).await.unwrap();
        assert_eq!(
            (status["run"].as_str(), status["answer"].as_str()),
            (Some("over"), Some("Fixed the build."))
        );
        assert_eq!(
            work::list(&app.db.lock(), "alice", Some(&pot))
                .unwrap()
                .len(),
            1
        );
        assert!(work::list(&app.db.lock(), "bob", None).unwrap().is_empty());
    }

    #[tokio::test]
    async fn an_ask_model_starts_only_after_allow_once_and_only_once() {
        let (app, _dir, fake) = setup();
        let pot = pot(&app, |_| {});
        let first = work::open(&app, "alice", &pot, open(Some("claude-opus-5"), None))
            .await
            .unwrap();
        assert_eq!(first["state"], "awaiting_approval");
        assert_eq!(*fake.sessions.lock().unwrap(), 0, "nothing started");
        let approval = first["approvalId"].as_str().unwrap().to_owned();
        // Not yet allowed: refused.
        assert_eq!(
            work::open(
                &app,
                "alice",
                &pot,
                open(Some("claude-opus-5"), Some(&approval))
            )
            .await
            .unwrap_err()
            .status,
            409
        );
        approvals::answer(
            &mut app.db.lock(),
            "alice",
            &approval,
            Answer {
                answer: Decision::AllowOnce,
                reason: None,
            },
        )
        .unwrap();
        let started = work::open(
            &app,
            "alice",
            &pot,
            open(Some("claude-opus-5"), Some(&approval)),
        )
        .await
        .unwrap();
        assert_eq!(started["state"], "started");
        assert_eq!(
            fake.delivered.lock().unwrap()[0]["model"]["id"],
            "claude-opus-5"
        );
        let again = work::open(
            &app,
            "alice",
            &pot,
            open(Some("claude-opus-5"), Some(&approval)),
        )
        .await
        .unwrap_err();
        assert_eq!(again.status, 409, "a second start needs a new approval");
        assert_eq!(*fake.sessions.lock().unwrap(), 1);
    }

    #[tokio::test]
    async fn work_stays_inside_the_pots_reach_locations_models_and_concurrency() {
        let (app, _dir, _fake) = setup();
        let reader = pot(&app, |input| {
            input.permissions.work_locations[0].access = super::Access::Read
        });
        assert_eq!(
            work::open(&app, "alice", &reader, open(None, None))
                .await
                .unwrap_err()
                .status,
            403
        );
        let tester = pot(&app, |_| {});
        let mut elsewhere = open(None, None);
        elsewhere.workspace_id = "node:other".into();
        assert_eq!(
            work::open(&app, "alice", &tester, elsewhere)
                .await
                .unwrap_err()
                .status,
            403
        );
        assert_eq!(
            work::open(&app, "alice", &tester, open(Some("gpt-5"), None))
                .await
                .unwrap_err()
                .status,
            400
        );
        // Two at once (the pot's limit), then refused.
        work::open(&app, "alice", &tester, open(None, None))
            .await
            .unwrap();
        work::open(&app, "alice", &tester, open(None, None))
            .await
            .unwrap();
        assert_eq!(
            work::open(&app, "alice", &tester, open(None, None))
                .await
                .unwrap_err()
                .code,
            "limit_reached"
        );
        // Another owner cannot use the pot.
        assert_eq!(
            work::open(&app, "bob", &tester, open(None, None))
                .await
                .unwrap_err()
                .status,
            404
        );
        super::set_state(
            &mut app.db.lock(),
            "alice",
            &tester,
            1,
            super::PotState::Paused,
        )
        .unwrap();
        app.db.lock().execute("DELETE FROM pot_works", []).unwrap();
        assert_eq!(
            work::open(&app, "alice", &tester, open(None, None))
                .await
                .unwrap_err()
                .code,
            "pot_inactive"
        );
    }

    #[tokio::test]
    async fn an_unconfirmed_instruction_is_uncertain_and_taken_over_work_refuses_more() {
        let (app, _dir, fake) = setup();
        let pot = pot(&app, |_| {});
        let opened = work::open(&app, "alice", &pot, open(None, None))
            .await
            .unwrap();
        let session = opened["work"]["sessionId"].as_str().unwrap().to_owned();
        let work_id = opened["work"]["id"].as_str().unwrap().to_owned();
        *fake.delivery.lock().unwrap() = "refuse";
        assert_eq!(
            work::send(&app, "alice", &pot, &session, "Also run lint")
                .await
                .unwrap_err()
                .code,
            "not_delivered"
        );
        *fake.delivery.lock().unwrap() = "lose";
        let unsure = work::send(&app, "alice", &pot, &session, "Also run lint")
            .await
            .unwrap();
        assert_eq!(unsure["delivery"], "uncertain");
        assert_eq!(
            fake.delivered.lock().unwrap().len(),
            2,
            "sent once, never again"
        );
        // Another pot does not coordinate it.
        let other = super::create(&mut app.db.lock(), "alice", super::input("Other"))
            .unwrap()
            .id;
        assert_eq!(
            work::send(&app, "alice", &other, &session, "x")
                .await
                .unwrap_err()
                .status,
            404
        );
        // The user takes it over: the pot is told and cannot send any more.
        assert_eq!(
            work::take_over(&app.db.lock(), "bob", &work_id)
                .unwrap_err()
                .status,
            404
        );
        let taken = work::take_over(&app.db.lock(), "alice", &work_id).unwrap();
        assert_eq!(taken.state, "taken_over");
        *fake.delivery.lock().unwrap() = "ok";
        assert_eq!(
            work::send(&app, "alice", &pot, &session, "x")
                .await
                .unwrap_err()
                .code,
            "taken_over"
        );
        let wake: String = app
            .db
            .lock()
            .query_row(
                "SELECT source FROM pot_wakes WHERE pot_id=?1",
                [&pot],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(wake, "handover");
    }
}

mod observe {
    use super::super::observe::{self, Note, SessionCondition};
    use super::*;
    use rusqlite::params;

    fn setup() -> (Db, String, String, String) {
        let db = db();
        let (lead, other, session) = {
            let mut conn = db.lock();
            conn.sync_remote_workspaces(
                "node",
                &[
                    (
                        "repo".into(),
                        "Repo".into(),
                        pirc_protocol::ModeId::new("directory").unwrap(),
                    ),
                    (
                        "proj".into(),
                        "Proj".into(),
                        pirc_protocol::ModeId::new("directory").unwrap(),
                    ),
                ],
            )
            .unwrap();
            // Tester leads the workspace scope; Helper observes it without leading.
            let lead = create(&mut conn, "alice", input("Tester")).unwrap().id;
            let mut helper = input("Helper");
            helper.permissions.observe[0].lead = false;
            let other = create(&mut conn, "alice", helper).unwrap().id;
            let session = conn
                .create_session("node:repo", "node://node/r1", "node", "r1", "alice")
                .unwrap()
                .id;
            (lead, other, session)
        };
        (db, lead, other, session)
    }

    fn targets(conn: &rusqlite::Connection, event: &str) -> Vec<(String, bool)> {
        conn.prepare("SELECT pot_id, lead FROM obs_targets WHERE event_id=?1 ORDER BY pot_id")
            .unwrap()
            .query_map([event], |r| Ok((r.get(0)?, r.get(1)?)))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap()
    }

    fn event_of(conn: &rusqlite::Connection, pot: &str) -> String {
        conn.query_row(
            "SELECT json_extract(details_json,'$.eventId') FROM pot_wakes WHERE pot_id=?1 AND source='event' ORDER BY rowid DESC",
            [pot],
            |r| r.get(0),
        )
        .unwrap()
    }

    #[test]
    fn an_observed_fact_is_recorded_once_and_wakes_each_observer() {
        let (db, lead, other, session) = setup();
        let conn = db.lock();
        let woken =
            observe::emit_session(&conn, &session, SessionCondition::RunFinished, "1").unwrap();
        assert_eq!(woken.len(), 2);
        let event = event_of(&conn, &lead);
        assert_eq!(event_of(&conn, &other), event, "one L0 row for both");
        let mut expected = vec![(lead.clone(), true), (other.clone(), false)];
        expected.sort();
        assert_eq!(targets(&conn, &event), expected);
        // The same fact again is already known; another occurrence is new.
        assert!(
            observe::emit_session(&conn, &session, SessionCondition::RunFinished, "1")
                .unwrap()
                .is_empty()
        );
        assert_eq!(
            observe::emit_session(&conn, &session, SessionCondition::WaitingInput, "2")
                .unwrap()
                .len(),
            2
        );
        let events: i64 = conn
            .query_row("SELECT count(*) FROM obs_events", [], |r| r.get(0))
            .unwrap();
        assert_eq!(events, 2);
        // Each pot keeps its own note, once; a pot the event did not reach cannot note it.
        let note = |pot: &str, text: &str| {
            observe::note(
                &conn,
                "alice",
                pot,
                Note {
                    event_id: event.clone(),
                    note: text.into(),
                    evidence: vec![],
                },
            )
        };
        note(&lead, "Build broke on main").unwrap();
        note(&other, "Flaky test again").unwrap();
        assert_eq!(note(&lead, "again").unwrap_err().code, "already_noted");
        let notes: i64 = conn
            .query_row("SELECT count(*) FROM obs_observations", [], |r| r.get(0))
            .unwrap();
        assert_eq!(notes, 2, "never merged");
        drop(conn);
        let mut conn = db.lock();
        let outsider = create(&mut conn, "alice", input("Outsider")).unwrap().id;
        assert_eq!(
            observe::note(
                &conn,
                "alice",
                &outsider,
                Note {
                    event_id: event.clone(),
                    note: "x".into(),
                    evidence: vec![]
                }
            )
            .unwrap_err()
            .status,
            404
        );
        assert_eq!(
            observe::note(
                &conn,
                "bob",
                &lead,
                Note {
                    event_id: event,
                    note: "x".into(),
                    evidence: vec![]
                }
            )
            .unwrap_err()
            .status,
            404
        );
    }

    #[test]
    fn pots_never_observe_pot_sessions_their_own_work_or_beyond_their_scope() {
        let (db, lead, other, session) = setup();
        let mut conn = db.lock();
        // Work the lead coordinates reaches only the other observer.
        conn.execute(
            "INSERT INTO pot_works(id,owner_user,pot_id,session_id,workspace_id,title,provider,model,created_at,updated_at)
             VALUES('w1','alice',?1,?2,'node:repo','Fix','p','m',0,0)",
            params![lead, session],
        )
        .unwrap();
        let woken =
            observe::emit_session(&conn, &session, SessionCondition::RunFinished, "1").unwrap();
        assert_eq!(woken, vec![("alice".to_owned(), other.clone())]);
        // A pot's own session reaches nobody.
        conn.execute(
            "UPDATE pot_runtime SET session_id=?1 WHERE pot_id=?2",
            params![session, other],
        )
        .unwrap();
        assert!(
            observe::emit_session(&conn, &session, SessionCondition::RunFinished, "2")
                .unwrap()
                .is_empty()
        );
        conn.execute("UPDATE pot_runtime SET session_id=NULL", [])
            .unwrap();
        conn.execute("DELETE FROM pot_works", []).unwrap();
        // Paused pots, and pots that may only answer, are not reached.
        set_state(&mut conn, "alice", &lead, 1, PotState::Paused).unwrap();
        conn.execute(
            "UPDATE pot_permissions SET reach='answer' WHERE pot_id=?1",
            [&other],
        )
        .unwrap();
        assert!(
            observe::emit_session(&conn, &session, SessionCondition::RunFinished, "3")
                .unwrap()
                .is_empty()
        );
        // Another owner's session in the same workspace reaches no pot of alice's.
        set_state(&mut conn, "alice", &lead, 2, PotState::Active).unwrap();
        let bobs = conn
            .create_session("node:repo", "node://node/r2", "node", "r2", "bob")
            .unwrap()
            .id;
        assert!(
            observe::emit_session(&conn, &bobs, SessionCondition::RunFinished, "1")
                .unwrap()
                .is_empty()
        );
    }

    #[test]
    fn a_project_scope_reaches_its_members_sessions() {
        let (db, lead, _other, _session) = setup();
        let mut conn = db.lock();
        let mut watcher = input("Watcher");
        watcher.permissions.observe =
            vec![serde_json::from_value(json!({ "kind": "project", "ref": "node:proj" })).unwrap()];
        let watcher = create(&mut conn, "alice", watcher).unwrap().id;
        let member = conn
            .create_session("node:proj", "node://node/r3", "node", "r3", "alice")
            .unwrap()
            .id;
        conn.execute(
            "UPDATE conversation_project_memberships SET project_workspace_id='node:proj', resolution='member'
             WHERE session_id=?1",
            [&member],
        )
        .unwrap();
        let woken =
            observe::emit_session(&conn, &member, SessionCondition::WaitingInput, "1").unwrap();
        assert_eq!(woken, vec![("alice".to_owned(), watcher)]);
        assert!(!woken.iter().any(|(_, pot)| pot == &lead));
    }
}

mod hints {
    use crate::test_support::app_with_models;
    use futures_util::StreamExt;
    use serde_json::{Value, json};
    use tokio_tungstenite::tungstenite::{Message, client::IntoClientRequest};

    async fn serve(app: crate::app::AppState) -> std::net::SocketAddr {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let router = crate::app::router(app);
        tokio::spawn(async move {
            axum::serve(
                listener,
                router.into_make_service_with_connect_info::<std::net::SocketAddr>(),
            )
            .await
            .unwrap();
        });
        address
    }

    async fn connect(
        address: std::net::SocketAddr,
        query: &str,
        user: &str,
    ) -> tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>
    {
        let mut request = format!("ws://{address}/api/hints?{query}")
            .into_client_request()
            .unwrap();
        let headers = request.headers_mut();
        headers.insert("host", "a.example".parse().unwrap());
        headers.insert("origin", "https://a.example".parse().unwrap());
        headers.insert("x-pirc-user", user.parse().unwrap());
        headers.insert(crate::capabilities::HEADER, "test/2".parse().unwrap());
        tokio_tungstenite::connect_async(request).await.unwrap().0
    }

    async fn next(
        socket: &mut tokio_tungstenite::WebSocketStream<
            tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
        >,
    ) -> Message {
        tokio::time::timeout(std::time::Duration::from_secs(5), socket.next())
            .await
            .expect("a frame in time")
            .unwrap()
            .unwrap()
    }

    #[tokio::test]
    async fn a_hint_socket_needs_no_session_and_hears_only_its_owner() {
        let (app, _dir) = app_with_models(json!({}));
        let address = serve(app.clone()).await;
        let mut alice = connect(address, "pots=1&threads=1", "alice").await;
        // Give the server a moment to subscribe before the first hint.
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        app.pots_changed("bob");
        app.approvals_changed("alice");
        app.threads_changed("alice");
        app.pots_changed("alice");
        let mut kinds = Vec::new();
        for _ in 0..2 {
            let Message::Text(text) = next(&mut alice).await else {
                panic!("a text frame")
            };
            let frame: Value = serde_json::from_str(&text).unwrap();
            kinds.push(frame["type"].as_str().unwrap().to_owned());
        }
        assert_eq!(kinds, ["threads_changed", "pots_changed"]);

        // Asking for nothing, or for something unknown, closes the socket.
        for query in ["", "pots=1&sessionId=s1", "pots=yes"] {
            let mut socket = connect(address, query, "alice").await;
            match next(&mut socket).await {
                Message::Close(Some(frame)) => assert_ne!(u16::from(frame.code), 1000, "{query}"),
                other => panic!("{query}: expected a close, got {other:?}"),
            }
        }
    }
}
