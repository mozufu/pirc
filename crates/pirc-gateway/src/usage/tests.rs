use super::*;
use crate::app::App;
use crate::db::{Db, Store};
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
    let delegated = session(&app, "remote-delegated");
    {
        let db = app.db.lock();
        db.execute(
            "INSERT INTO schedule_runs(id,schedule_id,owner_user,due_at,status,session_id,created_at)
             VALUES('run','schedule-1','alice',1,'running',?1,1)",
            [&scheduled],
        )
        .unwrap();
        db.execute(
            "INSERT INTO delegations(id,owner_user,assistant_session_id,workspace_id,title,task,status,
              target_session_id,expires_at,created_at,updated_at)
             VALUES('delegation-1','alice','chat','node:repo','t','task','running',?1,9,1,1)",
            [&delegated],
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
    let who = attribute(&db, "node", "remote-delegated").unwrap();
    assert_eq!(
        (who.actor_kind, who.actor_id.as_deref()),
        ("delegation", Some("delegation-1"))
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
