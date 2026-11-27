use super::*;
use crate::app::App;
use crate::db::{Db, Store};
use crate::pots::budget;
use crate::usage::admission::{self, Reservation};
use pirc_protocol::Models;
use serde_json::json;
use std::sync::Arc;

fn app() -> (AppState, tempfile::TempDir) {
    let dir = tempfile::tempdir().unwrap();
    let state = dir.path().join("state");
    let env = pirc_config::Env::new(
        [
            (
                "PIRC_NODE_TOKENS",
                r#"{"node":"0123456789abcdef0123456789abcdef"}"#,
            ),
            ("PIRC_TRUSTED_PROXIES", "127.0.0.1"),
            ("PIRC_PROXY_SECRET_REQUIRED", "false"),
            ("PIRC_ALLOWED_ORIGINS", "https://a.example"),
            ("PIRC_ALLOWED_HOSTS", "a.example"),
            ("PIRC_ALLOWED_USERS", "alice"),
            ("PIRC_STATE_DIR", state.to_str().unwrap()),
            ("PIRC_CONFIG_DIR", dir.path().to_str().unwrap()),
            ("PIRC_TIMEZONE", "UTC"),
            ("HOME", "/home/test"),
        ],
        "/work",
    );
    let models: Models = serde_json::from_value(json!({ "providers": {
        "work-anthropic": { "api": "anthropic-messages", "piProvider": "anthropic",
            "baseUrl": "https://api.anthropic.com", "apiKey": "key",
            "models": [{ "id": "claude-fable-5" }] },
        "local": { "api": "openai-completions", "baseUrl": "http://127.0.0.1:1234/v1",
            "models": [{ "id": "llama" }] },
        "custom": { "api": "openai-completions", "baseUrl": "https://llm.example/v1",
            "apiKey": "key", "models": [{ "id": "house-model" }] }
    }}))
    .unwrap();
    let backends = pirc_providers::backends::BackendService::open(&state, models).unwrap();
    let app = App::new(
        pirc_config::GatewayConfig::load(&env).unwrap(),
        Arc::new(Db::memory()),
        backends,
        crate::app::test_modes(),
    );
    (app, dir)
}

fn pot_input(money: u64, tokens: u64) -> crate::pots::store::PotInput {
    serde_json::from_value(json!({
        "profile": { "name": "Tester", "avatarColor": 1 },
        "work": {},
        "permissions": { "reach": "answer", "dm": { "send": "all", "receive": "all" },
            "maxConcurrentWorks": 0,
            "budgetMoneyMonthMicros": money, "budgetTokensDay": tokens },
        "models": { "main": { "provider": "work-anthropic", "model": "claude-fable-5" },
            "thinking": "off" }
    }))
    .unwrap()
}

fn owner_caps(app: &AppState, money: u64, tokens: u64) {
    app.db
        .lock()
        .execute(
            "INSERT INTO pot_settings(owner_user,cap_money_month_micros,cap_tokens_day)
             VALUES('alice',?1,?2)
             ON CONFLICT(owner_user) DO UPDATE SET
               cap_money_month_micros=?1,cap_tokens_day=?2",
            rusqlite::params![money as i64, tokens as i64],
        )
        .unwrap();
}

/// A pot whose own session is `remote`, exactly as `runtime` allocates it.
fn pot_session(app: &AppState, remote: &str, money: u64, tokens: u64) -> String {
    let session = session(app, remote);
    let pot =
        crate::pots::store::create(&mut app.db.lock(), "alice", pot_input(money, tokens)).unwrap();
    app.db
        .lock()
        .execute(
            "UPDATE pot_runtime SET session_id=?1 WHERE pot_id=?2",
            rusqlite::params![session, pot.id],
        )
        .unwrap();
    pot.id
}

fn inference(
    provider: &str,
    model: &str,
    max_tokens: Option<u64>,
) -> pirc_protocol::InferenceRequest {
    pirc_protocol::InferenceRequest {
        purpose: Default::default(),
        provider_name: provider.into(),
        model_id: model.into(),
        system_prompt: "x".repeat(400),
        messages: Vec::new(),
        tools: Vec::new(),
        thinking: pirc_protocol::ThinkingLevel::Off,
        session_id: "agent-chosen".into(),
        max_tokens,
        tool_choice: None,
    }
}

fn answer(input: u64, output: u64) -> AssistantMessage {
    serde_json::from_value(json!({
        "role": "assistant", "content": [{ "type": "text", "text": "ok" }],
        "api": "anthropic-messages", "provider": "work-anthropic", "model": "claude-fable-5",
        "usage": { "input": input, "output": output, "cacheRead": 0, "cacheWrite": 0,
                   "totalTokens": input + output },
        "stopReason": "stop", "timestamp": 1
    }))
    .unwrap()
}

fn session(app: &AppState, remote: &str) -> String {
    let db = app.db.lock();
    db.sync_remote_workspaces(
        "node",
        &[(
            "repo".into(),
            "Repo".into(),
            pirc_protocol::ModeId::new("directory").unwrap(),
        )],
    )
    .unwrap();
    db.create_session(
        "node:repo",
        &format!("node://node/{remote}"),
        "node",
        remote,
        "alice",
    )
    .unwrap()
    .id
}

fn usage(input: u64, output: u64, cache_read: u64, cache_write: u64) -> Usage {
    Usage {
        input,
        output,
        cache_read,
        cache_write,
        total_tokens: input + output + cache_read + cache_write,
    }
}

#[test]
fn micro_dollars_are_tokens_times_dollars_per_million() {
    let price = ModelCost {
        input: 10.0,
        output: 50.0,
        cache_read: 1.0,
        cache_write: 12.5,
    };
    // 1,000 input tokens at $10/M is $0.01 = 10,000 micro-dollars.
    assert_eq!(micros(&usage(1_000, 0, 0, 0), &price), 10_000);
    assert_eq!(
        micros(&usage(1_000, 200, 3_000, 40), &price),
        10_000 + 10_000 + 3_000 + 500
    );
    assert_eq!(micros(&usage(0, 0, 0, 0), &price), 0);
}

#[test]
fn backends_are_priced_by_how_they_are_paid() {
    let (app, _dir) = app();
    let keyed = pricing(&app, "work-anthropic", "claude-fable-5");
    assert_eq!(keyed.auth, AuthKind::ApiKey);
    assert_eq!(keyed.plan, None);
    assert!(keyed.billed.is_some());
    assert_eq!(keyed.billed, keyed.api_equivalent);

    let subscription = pricing(&app, "oauth:anthropic", "claude-fable-5");
    assert_eq!(subscription.auth, AuthKind::Subscription);
    assert_eq!(
        subscription.plan.as_deref(),
        Some("Anthropic (Claude Pro/Max)")
    );
    assert_eq!(subscription.billed, None);
    assert_eq!(subscription.api_equivalent, keyed.billed);

    let local = pricing(&app, "local", "llama");
    assert_eq!(local.auth, AuthKind::Keyless);
    assert_eq!((local.billed, local.api_equivalent), (None, None));

    let custom = pricing(&app, "custom", "house-model");
    assert_eq!(custom.auth, AuthKind::ApiKey);
    assert_eq!((custom.billed, custom.api_equivalent), (None, None));
}

#[test]
fn attribution_uses_the_gateway_session_and_its_origin() {
    let (app, _dir) = app();
    let plain = session(&app, "remote-plain");
    let scheduled = session(&app, "remote-scheduled");
    {
        let db = app.db.lock();
        db.execute(
            "INSERT INTO schedule_runs(id,schedule_id,owner_user,due_at,status,session_id,created_at)
             VALUES('run','schedule-1','alice',1,'running',?1,1)",
            [&scheduled],
        )
        .unwrap();
    }
    let db = app.db.lock();
    let who = attribute(&db, "node", "remote-plain").unwrap();
    assert_eq!(
        who,
        Attribution {
            owner: Some("alice".into()),
            session: Some(plain),
            actor_kind: "user",
            actor_id: Some("alice".into()),
        }
    );
    let who = attribute(&db, "node", "remote-scheduled").unwrap();
    assert_eq!(
        (who.actor_kind, who.actor_id.as_deref()),
        ("schedule", Some("schedule-1"))
    );
    // A pot's own session is charged to the pot, whose id comes from the
    // session mapping and never from the agent.
    drop(db);
    let pot = pot_session(&app, "remote-pot", 1_000_000, 1_000_000);
    let db = app.db.lock();
    let who = attribute(&db, "node", "remote-pot").unwrap();
    assert_eq!(
        (
            who.owner.as_deref(),
            who.actor_kind,
            who.actor_id.as_deref()
        ),
        (Some("alice"), "pot", Some(pot.as_str()))
    );
    // Work a pot opened is charged to that pot too.
    drop(db);
    let work = session(&app, "remote-work");
    app.db
        .lock()
        .execute(
            "INSERT INTO pot_works(id,owner_user,pot_id,session_id,workspace_id,title,provider,
               model,state,created_at,updated_at)
             VALUES('work-1','alice',?1,?2,'node:repo','Nightly','work-anthropic',
               'claude-fable-5','open',1,1)",
            rusqlite::params![pot, work],
        )
        .unwrap();
    let db = app.db.lock();
    let who = attribute(&db, "node", "remote-work").unwrap();
    assert_eq!(
        (
            who.owner.as_deref(),
            who.actor_kind,
            who.actor_id.as_deref()
        ),
        (Some("alice"), "pot", Some(pot.as_str()))
    );
    // The same remote ID on another Node is not this session.
    let who = attribute(&db, "other-node", "remote-plain").unwrap();
    assert_eq!((who.owner, who.actor_kind), (None, "system"));
}

/// auth_kind, plan, cost, API-equivalent, outcome, actor kind/purpose.
type Row = (
    String,
    Option<String>,
    Option<i64>,
    Option<i64>,
    String,
    String,
);

#[test]
fn every_finished_request_is_recorded_once_with_its_price() {
    let (app, _dir) = app();
    session(&app, "remote");
    let mut message: AssistantMessage = serde_json::from_value(json!({
        "role": "assistant", "content": [{ "type": "text", "text": "ok" }],
        "api": "anthropic-messages", "provider": "oauth:anthropic", "model": "claude-fable-5",
        "usage": { "input": 1000, "output": 100, "cacheRead": 0, "cacheWrite": 0, "totalTokens": 1100,
                   "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "total": 0 } },
        "stopReason": "stop", "timestamp": 1
    }))
    .unwrap();
    use pirc_protocol::RequestPurpose;
    let request = |provider: &str, purpose| pirc_protocol::InferenceRequest {
        purpose,
        provider_name: provider.into(),
        model_id: "claude-fable-5".into(),
        system_prompt: String::new(),
        messages: Vec::new(),
        tools: Vec::new(),
        thinking: pirc_protocol::ThinkingLevel::Off,
        // The agent's own label; attribution uses the Node session instead.
        session_id: "agent-chosen".into(),
        max_tokens: None,
        tool_choice: None,
    };
    let turn = request("oauth:anthropic", RequestPurpose::Turn);
    record(&app, "node", "remote", &turn, &message);
    message.stop_reason = StopReason::Error;
    let title = request("work-anthropic", RequestPurpose::Title);
    record(&app, "node", "remote", &title, &message);

    let db = app.db.lock();
    let rows: Vec<Row> = db
        .prepare(
            "SELECT auth_kind,plan,cost_micros,api_equiv_micros,outcome,actor_kind||'/'||purpose
             FROM usage_events ORDER BY id",
        )
        .unwrap()
        .query_map([], |r| {
            Ok((
                r.get(0)?,
                r.get(1)?,
                r.get(2)?,
                r.get(3)?,
                r.get(4)?,
                r.get(5)?,
            ))
        })
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    // claude-fable-5: $10/M input, $50/M output.
    let price = 1_000 * 10 + 100 * 50;
    assert_eq!(
        rows,
        vec![
            (
                "subscription".into(),
                Some("Anthropic (Claude Pro/Max)".into()),
                None,
                Some(price),
                "ok".into(),
                "user/turn".into()
            ),
            (
                "api_key".into(),
                None,
                Some(price),
                Some(price),
                "error".into(),
                "user/title".into()
            ),
        ]
    );
    let subscription_with_cost = db.execute(
        "INSERT INTO usage_events(at,node_id,node_session,actor_kind,provider,model,auth_kind,plan,
          input_tokens,output_tokens,cache_read_tokens,cache_write_tokens,cost_micros,outcome)
         VALUES(1,'n','s','user','p','m','subscription','Plan',0,0,0,0,5,'ok')",
        [],
    );
    assert!(
        subscription_with_cost.is_err(),
        "subscriptions are never billed per token"
    );
}

#[test]
fn days_follow_the_requested_zone_through_daylight_saving() {
    let date = |text| chrono::NaiveDate::parse_from_str(text, "%Y-%m-%d").unwrap();
    let days =
        api::day_bounds_for_tests(date("2026-03-07"), date("2026-03-09"), "America/New_York");
    let hours: Vec<i64> = days.iter().map(|(_, s, e)| (e - s) / 3_600_000).collect();
    // 2026-03-08 is 23 hours long in New York.
    assert_eq!(hours, vec![24, 23, 24]);
    assert_eq!(days[0].0, "2026-03-07");
    // Midnight UTC+8 on 2026-11-24 is 16:00 UTC the day before.
    let taipei = api::day_bounds_for_tests(date("2026-11-24"), date("2026-11-24"), "Asia/Taipei");
    assert_eq!(taipei[0].1, 1_763_913_600_000 + 365 * 86_400_000);
}

#[test]
fn the_report_is_owner_scoped_and_keeps_subscriptions_apart() {
    let (app, _dir) = app();
    let db = app.db.lock();
    let insert = |owner: &str,
                  at: i64,
                  auth: &str,
                  plan: Option<&str>,
                  cost: Option<i64>,
                  equiv: Option<i64>| {
        db.execute(
            "INSERT INTO usage_events(at,owner_user,node_id,node_session,actor_kind,actor_id,provider,model,
              auth_kind,plan,input_tokens,output_tokens,cache_read_tokens,cache_write_tokens,cost_micros,
              api_equiv_micros,outcome,purpose)
             VALUES(?1,?2,'n','s','user',?2,'p','m',?3,?4,100,10,0,0,?5,?6,'ok','turn')",
            rusqlite::params![at, owner, auth, plan, cost, equiv],
        )
        .unwrap();
    };
    let day = 86_400_000;
    insert("alice", 10, "api_key", None, Some(500), Some(500));
    insert(
        "alice",
        day + 10,
        "subscription",
        Some("Plan"),
        None,
        Some(700),
    );
    insert("alice", day + 20, "keyless", None, None, None);
    insert("bob", 30, "api_key", None, Some(9_999), Some(9_999));
    let days = vec![
        ("d1".to_owned(), 0, day),
        ("d2".to_owned(), day, 2 * day),
        ("d3".to_owned(), 2 * day, 3 * day),
    ];
    let report = api::report(&db, "alice", &days).unwrap();
    let requests: Vec<i64> = report["days"]
        .as_array()
        .unwrap()
        .iter()
        .map(|d| d["requests"].as_i64().unwrap())
        .collect();
    assert_eq!(requests, vec![1, 2, 0]);
    assert_eq!(report["total"]["billedMicros"], 500);
    assert_eq!(report["total"]["subscriptionApiEquivalentMicros"], 700);
    assert_eq!(report["total"]["subscriptionTokens"], 110);
    assert_eq!(report["total"]["tokens"]["total"], 330);
    // The last day had nothing.
    assert_eq!(report["streakDays"], 0);
    assert_eq!(report["byModel"].as_array().unwrap().len(), 3);
    assert_eq!(report["byPurpose"][0]["purpose"], "turn");
    let streak = api::report(&db, "alice", &days[..2]).unwrap();
    assert_eq!(streak["streakDays"], 2);
}

fn reservation(
    id: &str,
    owner: &str,
    pot: &str,
    windows: budget::Windows,
    money: i64,
    tokens: i64,
) -> Reservation {
    Reservation {
        id: id.into(),
        owner: owner.into(),
        pot_id: pot.into(),
        node_id: "node".into(),
        node_session: "remote".into(),
        root_id: None,
        windows,
        money_micros: money,
        tokens,
        price: pirc_providers::ModelCost {
            input: 10.0,
            output: 50.0,
            cache_read: 1.0,
            cache_write: 12.5,
        },
        pricing_revision: "old".into(),
    }
}

#[test]
fn a_pot_request_is_reserved_admitted_and_reconciled_to_actual_usage() {
    let (app, _dir) = app();
    owner_caps(&app, 100_000_000, 100_000_000);
    let pot = pot_session(&app, "remote-pot", 1_000_000, 1_000_000);
    let request = inference("work-anthropic", "claude-fable-5", Some(100));
    let reservation = admission::begin(&app, "node", "remote-pot", &request)
        .unwrap()
        .expect("pot requests are admitted");
    assert!(reservation.money_micros > 0);
    assert!(reservation.tokens > 0);
    assert_eq!(
        app.db
            .lock()
            .query_row(
                "SELECT count(*) FROM budget_reservations WHERE state='held'",
                [],
                |r| r.get::<_, i64>(0)
            )
            .unwrap(),
        1
    );
    let message = answer(1_000, 100);
    record(&app, "node", "remote-pot", &request, &message);
    admission::finish(&app, &reservation, &message);
    let db = app.db.lock();
    let (state, money, tokens): (String, i64, i64) = db
        .query_row(
            "SELECT state,actual_money_micros,actual_tokens FROM budget_reservations WHERE id=?1",
            [&reservation.id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .unwrap();
    assert_eq!((state.as_str(), tokens), ("settled", 1_100));
    // $10/M input + $50/M output at the accepted price.
    assert_eq!(money, 15_000);
    let status = budget::status(&db, "alice", &pot, reservation.windows).unwrap();
    assert_eq!(status["money"]["usedMicros"], 15_000);
    assert_eq!(status["money"]["reservedMicros"], 0);
    assert_eq!(status["money"]["remainingMicros"], 985_000);
}

#[test]
fn a_pots_work_session_spends_that_pots_budget() {
    let (app, _dir) = app();
    owner_caps(&app, 100_000_000, 100_000_000);
    let pot = pot_session(&app, "remote-pot", 1_000_000, 1_000_000);
    let work = session(&app, "remote-work");
    app.db
        .lock()
        .execute(
            "INSERT INTO pot_works(id,owner_user,pot_id,session_id,workspace_id,title,provider,
               model,state,created_at,updated_at)
             VALUES('work-1','alice',?1,?2,'node:repo','Nightly','work-anthropic',
               'claude-fable-5','open',1,1)",
            rusqlite::params![pot, work],
        )
        .unwrap();
    let request = inference("work-anthropic", "claude-fable-5", Some(100));
    let reservation = admission::begin(&app, "node", "remote-work", &request)
        .unwrap()
        .expect("work a pot opened is admitted");
    assert_eq!(reservation.pot_id, pot);
    assert!(reservation.money_micros > 0);
}

#[test]
fn an_exhausted_cap_refuses_typed_and_logs_once_per_window() {
    let (app, _dir) = app();
    owner_caps(&app, 100_000_000, 100_000_000);
    let pot = pot_session(&app, "remote-pot", 1, 1_000_000);
    let request = inference("work-anthropic", "claude-fable-5", Some(100));
    let error = admission::begin(&app, "node", "remote-pot", &request).unwrap_err();
    assert_eq!(error.code, "budget_exhausted");
    assert_eq!(error.details.as_ref().unwrap()["scope"], "pot");
    assert_eq!(error.details.as_ref().unwrap()["unit"], "money");
    // The same refusal in this window does not log again.
    for _ in 0..3 {
        let _ = admission::begin(&app, "node", "remote-pot", &request);
    }
    let rows: i64 = app
        .db
        .lock()
        .query_row(
            "SELECT count(*) FROM pot_activity WHERE kind='budget_exhausted'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(rows, 1);
    // Tokens are checked on their own cap.
    app.db
        .lock()
        .execute(
            "UPDATE pot_permissions SET budget_money_month_micros=1000000,budget_tokens_day=1 WHERE pot_id=?1",
            [&pot],
        )
        .unwrap();
    let error = admission::begin(&app, "node", "remote-pot", &request).unwrap_err();
    assert_eq!(error.details.as_ref().unwrap()["unit"], "tokens");
    // The owner's cap refuses every pot.
    app.db
        .lock()
        .execute(
            "UPDATE pot_permissions SET budget_money_month_micros=1000000,budget_tokens_day=1000000 WHERE pot_id=?1",
            [&pot],
        )
        .unwrap();
    owner_caps(&app, 1, 100_000_000);
    let error = admission::begin(&app, "node", "remote-pot", &request).unwrap_err();
    assert_eq!(error.details.as_ref().unwrap()["scope"], "owner");
    assert_eq!(error.details.as_ref().unwrap()["unit"], "money");
}

#[tokio::test]
async fn a_refused_admission_pushes_the_owner_once_per_cap_and_window() {
    let (app, _dir) = app();
    owner_caps(&app, 100_000_000, 100_000_000);
    let pot = pot_session(&app, "remote-pot", 0, 1_000_000);
    let request = inference("work-anthropic", "claude-fable-5", Some(100));

    let (url, service) = crate::push::tests::push_service().await;
    let alice = crate::push::tests::Subscriber::new();
    let push = std::sync::Arc::new(crate::push::Push::new(
        app.db.clone(),
        crate::push::generate_vapid_keys(),
        "mailto:ops@example.com".into(),
        true,
    ));
    push.subscribe(
        "alice",
        &crate::push::tests::input(&format!("{url}/alice"), alice.keys(), "unifiedpush", None),
        None,
    )
    .unwrap();
    app.slots.set(push);
    let activity_hits = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let thread_hits = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let activity = activity_hits.clone();
    let threads = thread_hits.clone();
    let _activity_guard = app.hints.activity.add(
        "alice".into(),
        std::sync::Arc::new(move || {
            activity.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        }),
    );
    let _thread_guard = app.hints.threads.add(
        "alice".into(),
        std::sync::Arc::new(move || {
            threads.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        }),
    );

    for _ in 0..2 {
        let error = admission::begin(&app, "node", "remote-pot", &request).unwrap_err();
        assert_eq!(error.code, "budget_exhausted");
    }
    assert_eq!(activity_hits.load(std::sync::atomic::Ordering::Relaxed), 1);
    assert_eq!(thread_hits.load(std::sync::atomic::Ordering::Relaxed), 1);
    for _ in 0..100 {
        if !service.lock().unwrap().received.is_empty() {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }
    let received = service.lock().unwrap().received.clone();
    assert_eq!(received.len(), 1, "one push per cap and window");
    let payload = alice.read(&received[0].2);
    assert_eq!(payload["category"], "needs_you");
    let thread: String = app
        .db
        .lock()
        .query_row(
            "SELECT id FROM threads
             WHERE owner_user='alice' AND kind='direct' AND pot_a=?1",
            [&pot],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(
        payload["target"],
        json!({ "potId": pot, "threadId": thread })
    );
}

#[test]
fn subscriptions_count_against_money_only_with_api_equivalent_accounting() {
    let (app, _dir) = app();
    owner_caps(&app, 100_000_000, 100_000_000);
    let _pot = pot_session(&app, "remote-pot", 10_000_000, 100_000_000);
    let request = inference("oauth:anthropic", "claude-fable-5", Some(100));
    let without = admission::begin(&app, "node", "remote-pot", &request)
        .unwrap()
        .unwrap();
    assert_eq!(
        without.money_micros, 0,
        "not counted until the user opts in"
    );
    assert!(without.tokens > 0, "token caps always apply");
    admission::keep_unknown(&app, Some(&without));

    app.db
        .lock()
        .execute(
            "UPDATE pot_settings SET count_subscription_money=1 WHERE owner_user='alice'",
            [],
        )
        .unwrap();
    let with = admission::begin(&app, "node", "remote-pot", &request)
        .unwrap()
        .unwrap();
    assert!(with.money_micros > 0, "counted at API-equivalent prices");
    // It is a reservation against the pot, not a billed row.
    let billed: i64 = app
        .db
        .lock()
        .query_row(
            "SELECT count(*) FROM usage_events WHERE cost_micros IS NOT NULL",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(billed, 0);
}

#[test]
fn a_price_change_does_not_reprice_stored_rows_or_an_accepted_reservation() {
    let (app, _dir) = app();
    owner_caps(&app, 100_000_000, 100_000_000);
    let pot = pot_session(&app, "remote-pot", 1_000_000, 1_000_000);
    let windows = budget::windows("UTC", now_ms());
    app.db
        .lock()
        .execute(
            "INSERT INTO usage_events(at,owner_user,node_id,node_session,actor_kind,actor_id,provider,
               model,auth_kind,input_tokens,output_tokens,cache_read_tokens,cache_write_tokens,
               cost_micros,pricing_revision,outcome)
             VALUES(?1,'alice','node','past','pot',?2,'work-anthropic','claude-fable-5','api_key',
               100,10,0,0,500,'1.0.0','ok')",
            rusqlite::params![now_ms(), pot],
        )
        .unwrap();
    let held = reservation("resv-old", "alice", &pot, windows, 300, 10);
    admission::reserve(&app.db.lock(), &held).unwrap();
    let db = app.db.lock();
    assert_eq!(
        budget::money_used(
            &db,
            "alice",
            Some(&pot),
            windows.month_start,
            windows.month_end,
            false
        )
        .unwrap(),
        500
    );
    assert_eq!(
        budget::money_reserved(&db, "alice", Some(&pot), windows.month_start).unwrap(),
        300
    );
    let status = budget::status(&db, "alice", &pot, windows).unwrap();
    assert_eq!(status["money"]["remainingMicros"], 1_000_000 - 800);
    // The accepted reservation keeps its own prices, whatever the catalog
    // says later.
    let usage = usage(1_000, 100, 0, 0);
    assert_eq!(admission::actual_money(&held, &usage), 15_000);
    let stored: i64 = db
        .query_row(
            "SELECT cost_micros FROM usage_events WHERE node_session='past'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(stored, 500, "past rows are never repriced");
}

#[test]
fn two_concurrent_requests_near_a_cap_cannot_both_pass() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("gateway.sqlite");
    let pot = {
        let db = Db::open(&path).unwrap();
        let mut conn = db.lock();
        let pot =
            crate::pots::store::create(&mut conn, "alice", pot_input(1_000, 10_000_000)).unwrap();
        conn.execute(
            "INSERT INTO pot_settings(owner_user,cap_money_month_micros,cap_tokens_day)
             VALUES('alice',1000000,100000000)",
            [],
        )
        .unwrap();
        pot.id
    };
    let windows = budget::windows("UTC", now_ms());
    let barrier = Arc::new(std::sync::Barrier::new(2));
    let run = |id: &'static str| {
        let path = path.clone();
        let pot = pot.clone();
        let barrier = barrier.clone();
        std::thread::spawn(move || {
            let conn = rusqlite::Connection::open(&path).unwrap();
            conn.busy_timeout(std::time::Duration::from_secs(10))
                .unwrap();
            let held = reservation(id, "alice", &pot, windows, 800, 10);
            barrier.wait();
            admission::reserve(&conn, &held).unwrap()
        })
    };
    let first = run("resv-a");
    let second = run("resv-b");
    let results = [first.join().unwrap(), second.join().unwrap()];
    let refused: Vec<_> = results.iter().filter(|result| result.is_some()).collect();
    assert_eq!(
        refused.len(),
        1,
        "only one of two 800-micro requests fits 1,000"
    );
    assert_eq!(refused[0].unwrap().scope, budget::Scope::Pot);
    assert_eq!(refused[0].unwrap().unit, budget::Unit::Money);
    let held: i64 = rusqlite::Connection::open(&path)
        .unwrap()
        .query_row(
            "SELECT count(*) FROM budget_reservations WHERE state='held'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(held, 1);
}
