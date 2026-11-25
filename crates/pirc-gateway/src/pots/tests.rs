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
        let notice = page.last().unwrap();
        assert_eq!((notice.seq, notice.author_kind.as_str()), (1, "system"));
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
        // Only the one reason was posted; answers without text add no messages.
        assert_eq!(
            threads::messages(&conn, "alice", &thread.id, None)
                .unwrap()
                .len(),
            1
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
            assert_eq!(page["messages"][0]["authorKind"], "system");
            assert!(
                page["messages"][0]["body"]
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
