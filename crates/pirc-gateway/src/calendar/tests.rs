use super::*;
use crate::db::Db;
use chrono::{Duration, NaiveDate};

fn ms(value: &str) -> i64 {
    chrono::DateTime::parse_from_rfc3339(value)
        .unwrap()
        .timestamp_millis()
}
fn spec() -> Spec {
    Spec {
        title: "Calendar test".into(),
        description: String::new(),
        location: String::new(),
        start: "2026-10-21T09:00".into(),
        end: "2026-10-21T10:00".into(),
        timezone: "Asia/Taipei".into(),
        all_day: false,
        recurrence: None,
        reminder_minutes: vec![],
    }
}
fn range(conn: &Connection, from: &str, to: &str) -> Value {
    query(
        conn,
        "alice",
        ms(from),
        ms(to),
        "Asia/Taipei",
        None,
        ms("2026-10-21T00:00:00Z"),
    )
    .unwrap()
}

#[test]
fn ownership_revision_idempotency_and_deleted_creation_keys() {
    let db = Db::memory();
    let c = db.lock();
    let s = spec();
    let first = create(&c, "alice", "stable-key", &s, 1).unwrap();
    assert_eq!(
        create(&c, "alice", "stable-key", &s, 2).unwrap().id,
        first.id
    );
    assert!(get(&c, "bob", &first.id).is_err());
    let mut changed = s.clone();
    changed.title = "Edited".into();
    assert_eq!(
        create(&c, "alice", "stable-key", &changed, 3)
            .unwrap_err()
            .status,
        409
    );
    let saved = update(
        &c,
        "alice",
        &first.id,
        &changed,
        crate::calendar::Mutation {
            revision: 1,
            scope: "series",
            occurrence: None,
        },
        4,
    )
    .unwrap();
    assert_eq!(saved.revision, 2);
    let stale = update(
        &c,
        "alice",
        &first.id,
        &s,
        crate::calendar::Mutation {
            revision: 1,
            scope: "series",
            occurrence: None,
        },
        5,
    )
    .unwrap_err();
    assert_eq!(stale.code, "calendar_conflict");
    assert_eq!(stale.details.unwrap()["event"]["title"], "Edited");
    assert!(remove(&c, "bob", &first.id, 2, "series", None, 6).is_err());
    remove(&c, "alice", &first.id, 2, "series", None, 7).unwrap();
    assert_eq!(
        c.query_row(
            "SELECT spec_json FROM calendar_events WHERE id=?",
            [&first.id],
            |r| r.get::<_, String>(0)
        )
        .unwrap(),
        "{}"
    );
    assert_eq!(
        create(&c, "alice", "stable-key", &s, 8).unwrap_err().code,
        "event_deleted"
    );
}

#[test]
fn validation_rejects_dates_reversed_ranges_and_unknown_zones() {
    let mut s = spec();
    s.start = "2026-02-30T09:00".into();
    assert!(validate_spec(&s).is_err());
    s = spec();
    s.end = s.start.clone();
    assert!(validate_spec(&s).is_err());
    s = spec();
    s.timezone = "not/a-zone".into();
    assert!(validate_spec(&s).is_err());
    s = spec();
    s.reminder_minutes = vec![-1];
    assert!(validate_spec(&s).is_err());
    s = spec();
    s.recurrence = Some(Rule {
        frequency: "weekly".into(),
        interval: 0,
        weekdays: vec![],
        until: None,
        count: None,
    });
    assert!(validate_spec(&s).is_err());
}

#[test]
fn range_uses_exclusive_end_and_overlapping_duration() {
    let db = Db::memory();
    let c = db.lock();
    create(&c, "alice", "k", &spec(), 0).unwrap();
    assert_eq!(
        range(&c, "2026-10-21T01:30:00Z", "2026-10-21T02:30:00Z")["items"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    assert_eq!(
        range(&c, "2026-10-21T00:00:00Z", "2026-10-21T01:00:00Z")["items"],
        json!([])
    );
    assert_eq!(
        range(&c, "2026-10-21T02:00:00Z", "2026-10-22T00:00:00Z")["items"],
        json!([])
    );
}

#[test]
fn month_end_and_leap_recurrence_skip_missing_dates() {
    let rule = Rule {
        frequency: "monthly".into(),
        interval: 1,
        weekdays: vec![],
        until: None,
        count: Some(3),
    };
    let seed = NaiveDate::from_ymd_opt(2026, 1, 31).unwrap();
    assert_eq!(
        recurrence::ordinal(seed, NaiveDate::from_ymd_opt(2026, 2, 28).unwrap(), &rule),
        None
    );
    assert_eq!(
        recurrence::ordinal(seed, NaiveDate::from_ymd_opt(2026, 5, 31).unwrap(), &rule),
        Some(2)
    );
    let yearly = Rule {
        frequency: "yearly".into(),
        ..rule
    };
    assert_eq!(
        recurrence::ordinal(
            NaiveDate::from_ymd_opt(2024, 2, 29).unwrap(),
            NaiveDate::from_ymd_opt(2028, 2, 29).unwrap(),
            &yearly
        ),
        Some(1)
    );
}

#[test]
fn weekly_interval_count_honors_partial_first_week() {
    let seed = NaiveDate::from_ymd_opt(2026, 10, 21).unwrap(); // Wednesday
    let rule = Rule {
        frequency: "weekly".into(),
        interval: 2,
        weekdays: vec![1, 3, 5],
        until: None,
        count: None,
    };
    assert_eq!(recurrence::ordinal(seed, seed, &rule), Some(0));
    assert_eq!(
        recurrence::ordinal(seed, seed + Duration::days(2), &rule),
        Some(1)
    );
    assert_eq!(
        recurrence::ordinal(seed, seed + Duration::days(5), &rule),
        None
    );
    assert_eq!(
        recurrence::ordinal(seed, seed + Duration::days(12), &rule),
        Some(2)
    );
}

#[test]
fn daylight_saving_gap_overlap_and_all_day_are_wall_clock_based() {
    let db = Db::memory();
    let c = db.lock();
    let mut s = spec();
    s.timezone = "America/New_York".into();
    s.start = "2026-03-07T02:30".into();
    s.end = "2026-03-07T04:30".into();
    s.recurrence = Some(Rule {
        frequency: "daily".into(),
        interval: 1,
        weekdays: vec![],
        until: None,
        count: Some(3),
    });
    let event = create(&c, "alice", "gap", &s, 0).unwrap();
    let items = event_occurrences(
        &c,
        &event,
        ms("2026-03-08T00:00:00Z"),
        ms("2026-03-09T00:00:00Z"),
    )
    .unwrap();
    assert_eq!(items[0].0.start_at, ms("2026-03-08T07:30:00Z"));
    s.start = "2026-11-01T01:30".into();
    s.end = "2026-11-01T02:30".into();
    s.recurrence = None;
    let event = create(&c, "alice", "overlap", &s, 0).unwrap();
    assert_eq!(
        recurrence::occurrences(
            &event,
            ms("2026-11-01T00:00:00Z"),
            ms("2026-11-02T00:00:00Z")
        )
        .unwrap()[0]
            .start_at,
        ms("2026-11-01T05:30:00Z")
    );
    s.start = "2026-03-08".into();
    s.end = "2026-03-09".into();
    s.all_day = true;
    let event = create(&c, "alice", "allday", &s, 0).unwrap();
    let item = recurrence::occurrences(
        &event,
        ms("2026-03-08T00:00:00Z"),
        ms("2026-03-10T00:00:00Z"),
    )
    .unwrap()
    .remove(0);
    assert_eq!(item.end_at - item.start_at, 23 * 3_600_000);
    assert_eq!(item.end_date, "2026-03-09");
}

#[test]
fn moved_and_cancelled_occurrences_do_not_duplicate() {
    let db = Db::memory();
    let c = db.lock();
    let mut s = spec();
    s.recurrence = Some(Rule {
        frequency: "daily".into(),
        interval: 1,
        weekdays: vec![],
        until: None,
        count: Some(3),
    });
    let event = create(&c, "alice", "series", &s, 0).unwrap();
    let mut moved = s.clone();
    moved.start = "2026-11-01T12:00".into();
    moved.end = "2026-11-01T13:00".into();
    update(
        &c,
        "alice",
        &event.id,
        &moved,
        crate::calendar::Mutation {
            revision: 1,
            scope: "occurrence",
            occurrence: Some("2026-10-22T09:00"),
        },
        1,
    )
    .unwrap();
    remove(
        &c,
        "alice",
        &event.id,
        2,
        "occurrence",
        Some("2026-10-23T09:00"),
        2,
    )
    .unwrap();
    let october = range(&c, "2026-10-01T00:00:00Z", "2026-11-01T00:00:00Z");
    assert_eq!(october["items"].as_array().unwrap().len(), 1);
    let november = range(&c, "2026-11-01T00:00:00Z", "2026-11-02T00:00:00Z");
    assert_eq!(november["items"].as_array().unwrap().len(), 1);
    assert_eq!(november["items"][0]["originalStart"], "2026-10-22T09:00");
    assert!(
        remove(
            &c,
            "alice",
            &event.id,
            3,
            "occurrence",
            Some("2027-01-01T09:00"),
            3
        )
        .is_err()
    );
}

#[test]
fn following_split_keeps_count_atomic_and_nonoverlapping() {
    let db = Db::memory();
    let c = db.lock();
    let mut s = spec();
    s.recurrence = Some(Rule {
        frequency: "daily".into(),
        interval: 1,
        weekdays: vec![],
        until: None,
        count: Some(5),
    });
    let event = create(&c, "alice", "split", &s, 0).unwrap();
    s.start = "2026-10-23T11:00".into();
    s.end = "2026-10-23T12:00".into();
    let next = update(
        &c,
        "alice",
        &event.id,
        &s,
        crate::calendar::Mutation {
            revision: 1,
            scope: "following",
            occurrence: Some("2026-10-23T09:00"),
        },
        1,
    )
    .unwrap();
    assert_ne!(event.id, next.id);
    let items = range(&c, "2026-10-20T00:00:00Z", "2026-11-01T00:00:00Z");
    assert_eq!(items["items"].as_array().unwrap().len(), 5);
    assert_eq!(next.spec.recurrence.unwrap().count, Some(3));
    assert_eq!(
        get(&c, "alice", &event.id)
            .unwrap()
            .spec
            .recurrence
            .unwrap()
            .count,
        Some(2)
    );
}

#[test]
fn following_split_carries_cancelled_occurrences_and_rolls_back_invalid_edits() {
    let db = Db::memory();
    let c = db.lock();
    let mut s = spec();
    s.recurrence = Some(Rule {
        frequency: "daily".into(),
        interval: 1,
        weekdays: vec![],
        until: None,
        count: Some(5),
    });
    let first = create(&c, "alice", "carry", &s, 0).unwrap();
    remove(
        &c,
        "alice",
        &first.id,
        1,
        "occurrence",
        Some("2026-10-24T09:00"),
        1,
    )
    .unwrap();
    let mut changed = s.clone();
    changed.start = "2026-10-23T11:00".into();
    changed.end = "2026-10-23T12:00".into();
    let mut invalid = changed.clone();
    invalid.end = "bad".into();
    assert!(
        update(
            &c,
            "alice",
            &first.id,
            &invalid,
            crate::calendar::Mutation {
                revision: 2,
                scope: "following",
                occurrence: Some("2026-10-23T09:00")
            },
            2
        )
        .is_err()
    );
    assert_eq!(get(&c, "alice", &first.id).unwrap().revision, 2);
    assert_eq!(list(&c, "alice").unwrap().len(), 1);
    update(
        &c,
        "alice",
        &first.id,
        &changed,
        crate::calendar::Mutation {
            revision: 2,
            scope: "following",
            occurrence: Some("2026-10-23T09:00"),
        },
        2,
    )
    .unwrap();
    let items = range(&c, "2026-10-20T00:00:00Z", "2026-11-01T00:00:00Z");
    assert_eq!(items["items"].as_array().unwrap().len(), 4);
}

#[test]
fn all_day_event_keeps_its_calendar_date_across_extreme_display_zones() {
    let db = Db::memory();
    let c = db.lock();
    let mut s = spec();
    s.start = "2026-10-21".into();
    s.end = "2026-10-22".into();
    s.timezone = "-12:00".into();
    s.all_day = true;
    create(&c, "alice", "float", &s, 0).unwrap();
    let page = query(
        &c,
        "alice",
        ms("2026-10-20T10:00:00Z"),
        ms("2026-10-21T10:00:00Z"),
        "+14:00",
        None,
        0,
    )
    .unwrap();
    assert_eq!(page["items"].as_array().unwrap().len(), 1);
    assert_eq!(page["items"][0]["startDate"], "2026-10-21");
}

#[test]
fn shared_web_android_fixture_matches_authoritative_occurrence_instants() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../../fixtures/mobile-parity/calendar.json"
    ))
    .unwrap();
    for item in fixture["items"].as_array().unwrap() {
        if item["type"] != "event" {
            continue;
        }
        let spec: Spec = serde_json::from_value({
            let mut event = item["event"].clone();
            for key in ["id", "revision", "createdAt", "updatedAt"] {
                event.as_object_mut().unwrap().remove(key);
            }
            event
        })
        .unwrap();
        validate_spec(&spec).unwrap();
        let event = Event {
            id: item["sourceId"].as_str().unwrap().into(),
            revision: 1,
            spec,
            end_before: None,
            created_at: 0,
            updated_at: 0,
        };
        let occurrences = recurrence::occurrences(
            &event,
            fixture["from"].as_i64().unwrap(),
            fixture["to"].as_i64().unwrap(),
        )
        .unwrap();
        let actual = occurrences
            .iter()
            .find(|o| o.original_start == item["originalStart"].as_str().unwrap())
            .unwrap();
        assert_eq!(actual.start_at, item["startAt"].as_i64().unwrap());
        assert_eq!(actual.end_at, item["endAt"].as_i64().unwrap());
    }
}

fn schedule(conn: &Connection, cron: &str) {
    conn.execute("INSERT INTO schedules(id,owner_user,workspace_id,title,prompt,cron,timezone,status,created_at,updated_at) VALUES ('task','alice','w','Agent task','hello',?,'UTC','active',0,0)",[cron]).unwrap();
}
#[test]
fn calendar_read_cannot_start_agents_or_invent_past_history() {
    let db = Db::memory();
    let c = db.lock();
    schedule(&c, "0 9 * * *");
    let now = ms("2026-10-21T10:00:00Z");
    let result = query(
        &c,
        "alice",
        ms("2026-10-20T00:00:00Z"),
        ms("2026-10-23T00:00:00Z"),
        "UTC",
        None,
        now,
    )
    .unwrap();
    assert_eq!(result["items"].as_array().unwrap().len(), 1);
    assert_eq!(result["items"][0]["startAt"], ms("2026-10-22T09:00:00Z"));
    for table in ["schedule_runs", "sessions"] {
        let count: i64 = c
            .query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |r| r.get(0))
            .unwrap();
        assert_eq!(count, 0);
    }
}
#[test]
fn dense_cron_pages_are_explicit_complete_and_stable() {
    let db = Db::memory();
    let c = db.lock();
    schedule(&c, "* * * * *");
    let from = ms("2026-10-22T00:00:00Z");
    let to = from + DAY_MS;
    let mut cursor = None;
    let mut ids = std::collections::HashSet::new();
    loop {
        let page = query(&c, "alice", from, to, "UTC", cursor.as_deref(), from - 1).unwrap();
        for item in page["items"].as_array().unwrap() {
            assert!(ids.insert(item["id"].as_str().unwrap().to_string()));
        }
        cursor = page["nextCursor"].as_str().map(str::to_owned);
        assert_eq!(page["limited"], cursor.is_some());
        if cursor.is_none() {
            break;
        }
    }
    assert_eq!(ids.len(), 1440);
    assert!(
        query(&c, "bob", from, to, "UTC", None, from - 1).unwrap()["items"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    assert!(query(&c, "alice", from, from + 94 * DAY_MS, "UTC", None, from).is_err());
    let forged =
        URL_SAFE_NO_PAD.encode(serde_json::to_vec(&(from, to, "UTC", i64::MAX, "x")).unwrap());
    assert!(query(&c, "alice", from, to, "UTC", Some(&forged), from).is_err());
}

#[test]
fn automatic_forecasts_deduplicate_but_manual_and_legacy_runs_keep_their_identity() {
    let db = Db::memory();
    let c = db.lock();
    schedule(&c, "0 9 * * *");
    let at = ms("2026-10-21T09:00:00Z");
    for (id, origin) in [
        ("auto", Some("scheduled")),
        ("manual", Some("manual")),
        ("legacy", None),
    ] {
        c.execute("INSERT INTO schedule_runs(id,schedule_id,owner_user,due_at,status,created_at,origin) VALUES (?,'task','alice',?,'completed',?,?)",params![id,at,at,origin]).unwrap();
    }
    let page = query(&c, "alice", at, at + DAY_MS, "UTC", None, at - 3_600_000).unwrap();
    let items = page["items"].as_array().unwrap();
    assert_eq!(items.len(), 3);
    let ids = items
        .iter()
        .map(|i| i["id"].as_str().unwrap())
        .collect::<Vec<_>>();
    assert!(ids.contains(&"run:manual"));
    assert!(ids.contains(&"run:legacy"));
    assert!(ids.contains(&format!("schedule:task:{at}").as_str()));
    assert_ne!(account_key("alice"), account_key("bob"));
}

pub(super) fn fixture() -> (crate::app::AppState, tempfile::TempDir) {
    use crate::app::App;
    use pirc_config::{Env, GatewayConfig};
    use std::sync::Arc;
    let dir = tempfile::tempdir().unwrap();
    let state = dir.path().join("state");
    let env = Env::new(
        [
            (
                "PIRC_NODE_TOKENS",
                r#"{"work":"0123456789abcdef0123456789abcdef"}"#,
            ),
            ("PIRC_TRUSTED_PROXIES", "127.0.0.1"),
            ("PIRC_ALLOWED_ORIGINS", "https://a.example"),
            ("PIRC_ALLOWED_HOSTS", "a.example"),
            ("PIRC_ALLOWED_USERS", "alice,bob"),
            ("PIRC_STATE_DIR", state.to_str().unwrap()),
            ("PIRC_CONFIG_DIR", dir.path().to_str().unwrap()),
            ("PIRC_TIMEZONE", "UTC"),
            ("HOME", "/home/test"),
        ],
        "/work",
    );
    let app = App::new(
        GatewayConfig::load(&env).unwrap(),
        Arc::new(Db::memory()),
        pirc_providers::backends::BackendService::open(&state, crate::app::empty_models()).unwrap(),
        crate::app::test_modes(),
    );
    (app, dir)
}

fn agent_session(app: &crate::app::AppState) -> String {
    use crate::db::Store;
    let c = app.db.lock();
    c.sync_remote_workspaces(
        "work",
        &[(
            "calendar".into(),
            "Calendar workspace".into(),
            pirc_protocol::mode::ModeId::new("directory").unwrap(),
        )],
    )
    .unwrap();
    c.create_session(
        "work:calendar",
        "node://work/calendar-chat",
        "work",
        "calendar-chat",
        "alice",
    )
    .unwrap()
    .id
}

#[tokio::test]
async fn agent_proposals_require_explicit_grant_and_are_applied_only_once() {
    use super::agent::{self, Permissions};
    let (app, _dir) = fixture();
    let session = agent_session(&app);
    let request = json!({"spec":spec()});
    let (status, _) = crate::agent_ops::run(
        &app,
        "work",
        "calendar-chat",
        "calendar.proposeCreate",
        request.clone(),
    )
    .await;
    assert_eq!(status, 403);
    agent::set_permissions(
        &app.db.lock(),
        "alice",
        Permissions {
            allow_read: false,
            allow_propose: true,
        },
    )
    .unwrap();
    let (status, first) = crate::agent_ops::run(
        &app,
        "work",
        "calendar-chat",
        "calendar.proposeCreate",
        request.clone(),
    )
    .await;
    assert_eq!(status, 200, "{first}");
    let (status, duplicate) = crate::agent_ops::run(
        &app,
        "work",
        "calendar-chat",
        "calendar.proposeCreate",
        request,
    )
    .await;
    assert_eq!(status, 200);
    assert_eq!(
        first["result"]["proposalId"],
        duplicate["result"]["proposalId"]
    );
    assert_eq!(duplicate["result"]["duplicate"], true);
    assert!(list(&app.db.lock(), "alice").unwrap().is_empty());
    let pending = app.pending_gateway_interactions(&session, "alice");
    assert_eq!(pending.len(), 1);
    let card = pending[0]["id"].as_str().unwrap();
    assert!(
        agent::answer(
            &app,
            &session,
            card,
            "bob",
            Some(&json!({"confirmed":true}))
        )
        .is_err()
    );
    let answered = agent::answer(
        &app,
        &session,
        card,
        "alice",
        Some(&json!({"confirmed":true})),
    )
    .unwrap()
    .unwrap();
    assert_eq!(list(&app.db.lock(), "alice").unwrap().len(), 1);
    let repeated = agent::answer(
        &app,
        &session,
        card,
        "alice",
        Some(&json!({"confirmed":true})),
    )
    .unwrap()
    .unwrap();
    assert_eq!(answered, repeated);
    assert_eq!(list(&app.db.lock(), "alice").unwrap().len(), 1);
    assert!(
        app.pending_gateway_interactions(&session, "alice")
            .is_empty()
    );
    assert_eq!(
        agent::answer(
            &app,
            &session,
            card,
            "alice",
            Some(&json!({"confirmed":false}))
        )
        .unwrap_err()
        .status,
        409
    );
    let (status, _) = crate::agent_ops::run(
        &app,
        "work",
        "calendar-chat",
        "calendar.query",
        json!({"from":"2026-10-01T00:00:00Z","to":"2026-11-01T00:00:00Z","timezone":"UTC"}),
    )
    .await;
    assert_eq!(status, 403);
}

#[tokio::test]
async fn agent_approval_revalidates_revision_permissions_and_expiry() {
    use super::agent::{self, Permissions};
    let (app, _dir) = fixture();
    let session = agent_session(&app);
    agent::set_permissions(
        &app.db.lock(),
        "alice",
        Permissions {
            allow_read: true,
            allow_propose: true,
        },
    )
    .unwrap();
    let initial = create(&app.db.lock(), "alice", "stale-agent", &spec(), 0).unwrap();
    let mut draft = spec();
    draft.title = "Agent edit".into();
    let (status, proposed) = crate::agent_ops::run(
        &app,
        "work",
        "calendar-chat",
        "calendar.proposeUpdate",
        json!({"id":initial.id,"revision":1,"spec":draft,"scope":"series"}),
    )
    .await;
    assert_eq!(status, 200, "{proposed}");
    let pending = app.pending_gateway_interactions(&session, "alice");
    let card = pending[0]["id"].as_str().unwrap();
    let mut web = spec();
    web.title = "Saved on Web".into();
    update(
        &app.db.lock(),
        "alice",
        &initial.id,
        &web,
        crate::calendar::Mutation {
            revision: 1,
            scope: "series",
            occurrence: None,
        },
        1,
    )
    .unwrap();
    let stale = agent::answer(
        &app,
        &session,
        card,
        "alice",
        Some(&json!({"confirmed":true})),
    )
    .unwrap()
    .unwrap();
    assert_eq!(stale["result"]["status"], "stale");
    assert_eq!(
        get(&app.db.lock(), "alice", &initial.id)
            .unwrap()
            .spec
            .title,
        "Saved on Web"
    );
    let (status, _) = crate::agent_ops::run(
        &app,
        "work",
        "calendar-chat",
        "calendar.proposeCreate",
        json!({"spec":spec()}),
    )
    .await;
    assert_eq!(status, 200);
    let pending = app.pending_gateway_interactions(&session, "alice");
    let card = pending[0]["id"].as_str().unwrap();
    agent::set_permissions(&app.db.lock(), "alice", Permissions::default()).unwrap();
    let revoked = agent::answer(
        &app,
        &session,
        card,
        "alice",
        Some(&json!({"confirmed":true})),
    )
    .unwrap()
    .unwrap();
    assert_eq!(revoked["result"]["status"], "stale");
    assert_eq!(list(&app.db.lock(), "alice").unwrap().len(), 1);
    agent::set_permissions(
        &app.db.lock(),
        "alice",
        Permissions {
            allow_read: true,
            allow_propose: true,
        },
    )
    .unwrap();
    crate::agent_ops::run(
        &app,
        "work",
        "calendar-chat",
        "calendar.proposeCreate",
        json!({"spec":spec()}),
    )
    .await;
    let pending = app.pending_gateway_interactions(&session, "alice");
    let card = pending[0]["id"].as_str().unwrap();
    app.db
        .lock()
        .execute(
            "UPDATE calendar_proposals SET expires_at=0 WHERE status='pending'",
            [],
        )
        .unwrap();
    assert_eq!(
        agent::answer(
            &app,
            &session,
            card,
            "alice",
            Some(&json!({"confirmed":true}))
        )
        .unwrap_err()
        .status,
        409
    );
    assert!(
        app.pending_gateway_interactions(&session, "alice")
            .is_empty()
    );
    assert_eq!(list(&app.db.lock(), "alice").unwrap().len(), 1);
}

#[tokio::test]
async fn authenticated_http_contract_works_for_web_and_paired_app() {
    let (app, _dir) = fixture();
    let (_, token) = app.devices.create("alice", "Phone").unwrap();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let router = crate::app::router(app.clone());
    let task = tokio::spawn(async move {
        axum::serve(
            listener,
            router.into_make_service_with_connect_info::<std::net::SocketAddr>(),
        )
        .await
        .unwrap();
    });
    let client = reqwest::Client::builder()
        .no_proxy()
        .timeout(std::time::Duration::from_secs(5))
        .build()
        .unwrap();
    let endpoint = format!("http://{address}");
    let web = |method, path: &str, user: &str| {
        client
            .request(method, format!("{endpoint}{path}"))
            .header("host", "a.example")
            .header("origin", "https://a.example")
            .header("x-pirc-user", user)
            .header(crate::capabilities::HEADER, "test/2")
    };
    let created = web(reqwest::Method::POST, "/api/calendar/events", "alice")
        .header("content-type", "application/json")
        .body(json!({"idempotencyKey":"http-key","event":spec()}).to_string())
        .send()
        .await
        .unwrap();
    assert_eq!(created.status().as_u16(), 201);
    assert_eq!(created.headers()["cache-control"], "no-store");
    let body: Value = serde_json::from_str(&created.text().await.unwrap()).unwrap();
    let id = body["event"]["id"].as_str().unwrap();
    let resource = format!("/api/calendar/events/{id}");
    let phone = client
        .get(format!("{endpoint}{resource}"))
        .header("host", "a.example")
        .header(crate::capabilities::HEADER, "test/2")
        .bearer_auth(&token)
        .send()
        .await
        .unwrap();
    assert_eq!(phone.status().as_u16(), 200);
    assert_eq!(
        serde_json::from_str::<Value>(&phone.text().await.unwrap()).unwrap(),
        body
    );
    assert_eq!(
        web(reqwest::Method::GET, &resource, "bob")
            .send()
            .await
            .unwrap()
            .status()
            .as_u16(),
        404
    );
    let permissions = web(reqwest::Method::GET, "/api/calendar/permissions", "alice")
        .send()
        .await
        .unwrap();
    assert_eq!(
        serde_json::from_str::<Value>(&permissions.text().await.unwrap()).unwrap(),
        json!({"allowRead":false,"allowPropose":false})
    );
    let updated = web(reqwest::Method::PATCH, &resource, "alice")
        .header("content-type", "application/json")
        .body(json!({"revision":1,"event":spec(),"scope":"series"}).to_string())
        .send()
        .await
        .unwrap();
    assert_eq!(updated.status().as_u16(), 200);
    let stale = client
        .patch(format!("{endpoint}{resource}"))
        .header("host", "a.example")
        .header(crate::capabilities::HEADER, "test/2")
        .bearer_auth(&token)
        .header("content-type", "application/json")
        .body(json!({"revision":1,"event":spec()}).to_string())
        .send()
        .await
        .unwrap();
    assert_eq!(stale.status().as_u16(), 409);
    let bad_origin = client
        .delete(format!("{endpoint}{resource}"))
        .header("host", "a.example")
        .header("x-pirc-user", "alice")
        .header(crate::capabilities::HEADER, "test/2")
        .header("origin", "https://evil.example")
        .header("content-type", "application/json")
        .body(json!({"revision":2}).to_string())
        .send()
        .await
        .unwrap();
    assert_eq!(bad_origin.status().as_u16(), 403);
    let range_path = format!(
        "/api/calendar?from={}&to={}&timezone=Asia%2FTaipei",
        ms("2026-10-20T00:00:00Z"),
        ms("2026-10-23T00:00:00Z")
    );
    let range = web(reqwest::Method::GET, &range_path, "alice")
        .send()
        .await
        .unwrap();
    assert_eq!(range.status().as_u16(), 200);
    assert_eq!(
        serde_json::from_str::<Value>(&range.text().await.unwrap()).unwrap()["items"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    task.abort();
}
