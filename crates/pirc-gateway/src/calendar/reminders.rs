//! Gateway-owned personal-event reminders. Each occurrence/reminder is
//! claimed once in SQLite before it is sent through the existing push path.

use std::sync::Arc;
use std::time::Duration;

use rusqlite::params;
use serde_json::json;

use super::{DAY_MS, Event, event_occurrences, list};
use crate::app::{App, AppState};
use crate::db::atomic;
use crate::error::ApiResult;
use crate::push::PushMessage;
use crate::util::now_ms;

const TICK: Duration = Duration::from_secs(30);
const MAX_OFFSET_MINUTES: i64 = 43_200;
const RETAIN_DELIVERIES_MS: i64 = 400 * DAY_MS;

struct Runtime;

/// Start the reminder timer once per gateway app.
pub fn start(app: &AppState) {
    if app.slots.get::<Runtime>().is_some() {
        return;
    }
    app.slots.set(Arc::new(Runtime));
    tick(app);
    let app = app.clone();
    tokio::spawn(async move {
        let mut interval = tokio::time::interval_at(tokio::time::Instant::now() + TICK, TICK);
        loop {
            interval.tick().await;
            tick(&app);
        }
    });
}

struct Due {
    user: String,
    message: PushMessage,
}

fn tick(app: &AppState) {
    if let Err(error) = super::agent::sweep_expired(app, now_ms()) {
        crate::log::warn(&format!(
            "calendar proposals: expiry scan failed: {}",
            error.message
        ));
    }
    let due = match collect_due(app, now_ms()) {
        Ok(due) => due,
        Err(error) => {
            crate::log::warn(&format!(
                "calendar reminders: scan failed: {}",
                error.message
            ));
            return;
        }
    };
    for item in due {
        crate::push::notify(app, &item.user, item.message);
    }
}

fn collect_due(app: &App, now: i64) -> ApiResult<Vec<Due>> {
    scan_due(&app.db.lock(), now)
}

fn scan_due(conn: &rusqlite::Connection, now: i64) -> ApiResult<Vec<Due>> {
    let mut statement = conn.prepare(
        "SELECT DISTINCT e.owner_user FROM calendar_events e
         WHERE e.deleted=0 AND EXISTS (SELECT 1 FROM push_subscriptions p
           WHERE p.owner_user=e.owner_user)",
    )?;
    let users = statement
        .query_map([], |row| row.get::<_, String>(0))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    drop(statement);
    // `occurrences` expands backward by the event duration itself, which is
    // capped at 366 days. Scanning from now catches ongoing long events while
    // avoiding a fixed two-year window on every timer tick.
    let from = now;
    let to = now.saturating_add(MAX_OFFSET_MINUTES * 60_000 + TICK.as_millis() as i64);
    let mut due = Vec::new();
    for user in users {
        for event in list(conn, &user)? {
            let occurrences = event_occurrences(conn, &event, from, to)?;
            for (occurrence, spec) in occurrences {
                if occurrence.end_at <= now {
                    continue;
                }
                let due_reminders: Vec<i64> = spec
                    .reminder_minutes
                    .iter()
                    .copied()
                    .filter(|minutes| occurrence.start_at.saturating_sub(minutes * 60_000) <= now)
                    .collect();
                if due_reminders.is_empty() {
                    continue;
                }
                let newly_claimed = claim(
                    conn,
                    &event,
                    &occurrence.original_start,
                    &due_reminders,
                    now,
                )?;
                if !newly_claimed {
                    continue;
                }
                due.push(Due {
                    user: user.clone(),
                    message: message(
                        &event,
                        &spec,
                        &occurrence.original_start,
                        &occurrence.start_date,
                        occurrence.start_at,
                        occurrence.end_at,
                        now,
                    ),
                });
            }
        }
    }
    conn.execute(
        "DELETE FROM calendar_reminder_deliveries WHERE created_at<?",
        [now.saturating_sub(RETAIN_DELIVERIES_MS)],
    )?;
    Ok(due)
}

/// Store an attempt before starting async push delivery. A gateway restart
/// cannot turn a handled reminder back into a notification backlog. Owners
/// without a subscription are excluded before this point so subscribing later
/// can still deliver an event that is ongoing or within its reminder window.
fn claim(
    conn: &rusqlite::Connection,
    event: &Event,
    occurrence_key: &str,
    minutes: &[i64],
    now: i64,
) -> ApiResult<bool> {
    atomic(conn, |conn| {
        let mut added = false;
        for reminder in minutes {
            let changed = conn.execute(
                "INSERT OR IGNORE INTO calendar_reminder_deliveries (event_id,occurrence_key,reminder_minutes,status,created_at) VALUES (?,?,?,'attempted',?)",
                params![event.id, occurrence_key, reminder, now],
            )?;
            added |= changed > 0;
        }
        Ok(added)
    })
}

fn message(
    event: &Event,
    spec: &super::Spec,
    occurrence: &str,
    start_date: &str,
    start_at: i64,
    end_at: i64,
    now: i64,
) -> PushMessage {
    let all_day = spec.all_day;
    let what = if start_at <= now {
        "is happening now"
    } else {
        "is coming up"
    };
    let when = if all_day {
        start_date.to_owned()
    } else {
        super::recurrence::wall(
            start_at,
            crate::schedules::Zone::parse(&spec.timezone)
                .unwrap_or(crate::schedules::Zone::Fixed(0)),
        )
        .map(|local| local.format("%Y-%m-%d %H:%M").to_string())
        .unwrap_or_else(|_| occurrence.to_owned())
    };
    let happening = start_at <= now && end_at > now;
    let body = if happening {
        format!("This event {what} ({when} {}).", spec.timezone)
    } else {
        format!("This event starts at {when} ({}).", spec.timezone)
    };
    let tag = format!("calendar:{}:{}", event.id, occurrence);
    PushMessage {
        title: format!("Event reminder: {}", spec.title),
        body,
        tag,
        target: json!({
            "calendar": true,
            "eventId": event.id,
            "occurrenceStart": occurrence,
            "date": start_date,
            "startAt": start_at,
        }),
        category: Some(crate::push::Category::Calendar),
        interaction: None,
        text: Some(crate::push::text::PushText::new(
            if happening {
                crate::push::text::CALENDAR_NOW
            } else {
                crate::push::text::CALENDAR_STARTS
            },
            &[
                ("event", &spec.title),
                ("when", &when),
                ("timezone", &spec.timezone),
            ],
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::calendar::{Rule, Spec, create, remove, update};
    use crate::db::Db;
    use rusqlite::params;
    use tempfile::TempDir;

    const USER: &str = "calendar@example.com";

    fn millis(value: &str) -> i64 {
        chrono::NaiveDateTime::parse_from_str(value, "%Y-%m-%dT%H:%M")
            .unwrap()
            .and_utc()
            .timestamp_millis()
    }

    fn db() -> (Db, TempDir) {
        let dir = tempfile::tempdir().unwrap();
        let db = Db::open(&dir.path().join("gateway.sqlite")).unwrap();
        (db, dir)
    }

    fn subscribe(conn: &rusqlite::Connection, user: &str) {
        conn.execute(
            "INSERT INTO push_subscriptions (id,owner_user,endpoint,p256dh,auth,kind,created_at) VALUES (?,?,?,'key','auth','web',0)",
            params![format!("sub-{user}"), user, format!("https://push.example/{user}")],
        )
        .unwrap();
    }

    fn spec(title: &str, start: &str, end: &str, reminders: Vec<i64>) -> Spec {
        Spec {
            title: title.into(),
            description: String::new(),
            location: String::new(),
            start: start.into(),
            end: end.into(),
            timezone: "UTC".into(),
            all_day: false,
            recurrence: None,
            reminder_minutes: reminders,
        }
    }

    fn recurring(mut spec: Spec, count: u32) -> Spec {
        spec.recurrence = Some(Rule {
            frequency: "daily".into(),
            interval: 1,
            weekdays: Vec::new(),
            until: None,
            count: Some(count),
        });
        spec
    }

    #[test]
    fn moving_an_occurrence_rearms_its_reminder_but_a_title_edit_does_not() {
        let (db, _dir) = db();
        let conn = db.lock();
        subscribe(&conn, USER);
        let now = millis("2026-10-21T08:00");
        let initial = recurring(
            spec(
                "Appointment",
                "2026-10-21T09:00",
                "2026-10-21T10:00",
                vec![60],
            ),
            3,
        );
        let event = create(&conn, USER, "move-reminder", &initial, now).unwrap();
        assert_eq!(scan_due(&conn, now).unwrap().len(), 1);
        let mut renamed = initial.clone();
        renamed.title = "Renamed".into();
        update(
            &conn,
            USER,
            &event.id,
            &renamed,
            crate::calendar::Mutation {
                revision: 1,
                scope: "series",
                occurrence: None,
            },
            now,
        )
        .unwrap();
        assert!(scan_due(&conn, now).unwrap().is_empty());
        let mut moved = renamed;
        moved.start = "2026-10-21T12:00".into();
        moved.end = "2026-10-21T13:00".into();
        update(
            &conn,
            USER,
            &event.id,
            &moved,
            crate::calendar::Mutation {
                revision: 2,
                scope: "occurrence",
                occurrence: Some("2026-10-21T09:00"),
            },
            now,
        )
        .unwrap();
        assert!(scan_due(&conn, now).unwrap().is_empty());
        assert_eq!(
            scan_due(&conn, millis("2026-10-21T11:00")).unwrap().len(),
            1
        );
        assert!(
            scan_due(&conn, millis("2026-10-21T11:00"))
                .unwrap()
                .is_empty()
        );
    }

    #[test]
    fn notification_points_to_the_personal_event_occurrence() {
        let event = Event {
            id: "event-1".into(),
            revision: 1,
            spec: super::super::Spec {
                title: "Dentist".into(),
                description: String::new(),
                location: String::new(),
                start: "2026-10-22T09:00".into(),
                end: "2026-10-22T10:00".into(),
                timezone: "Asia/Taipei".into(),
                all_day: false,
                recurrence: None,
                reminder_minutes: vec![15],
            },
            end_before: None,
            created_at: 0,
            updated_at: 0,
        };
        let message = message(
            &event,
            &event.spec,
            "2026-10-22T09:00",
            "2026-10-22",
            1_792_619_400_000,
            1_792_623_000_000,
            1_792_619_000_000,
        );
        assert_eq!(message.target["calendar"], true);
        assert_eq!(message.target["eventId"], "event-1");
        assert_eq!(message.target["date"], "2026-10-22");
        assert_eq!(message.target["startAt"], 1_792_619_400_000_i64);
        assert!(message.tag.contains("2026-10-22T09:00"));
    }

    #[test]
    fn reminder_attempt_is_unique_across_scans_and_gateway_restarts() {
        let (db, dir) = db();
        let now = millis("2026-10-21T08:00");
        {
            let conn = db.lock();
            subscribe(&conn, USER);
            create(
                &conn,
                USER,
                "restart-test",
                &spec("Dentist", "2026-10-21T09:00", "2026-10-21T10:00", vec![60]),
                now,
            )
            .unwrap();
            assert_eq!(scan_due(&conn, now).unwrap().len(), 1);
            assert!(scan_due(&conn, now).unwrap().is_empty());
        }
        drop(db);

        let reopened = Db::open(&dir.path().join("gateway.sqlite")).unwrap();
        let conn = reopened.lock();
        assert!(scan_due(&conn, now + 30_000).unwrap().is_empty());
        let status: String = conn
            .query_row(
                "SELECT status FROM calendar_reminder_deliveries",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(status, "attempted");
    }

    #[test]
    fn no_subscription_does_not_claim_a_reminder_and_cancelled_occurrences_are_skipped() {
        let (db, _dir) = db();
        let now = millis("2026-10-22T08:50");
        let conn = db.lock();
        let event = create(
            &conn,
            USER,
            "cancel-test",
            &recurring(
                spec(
                    "Daily check-in",
                    "2026-10-21T09:00",
                    "2026-10-21T10:00",
                    vec![15],
                ),
                2,
            ),
            now,
        )
        .unwrap();

        assert!(scan_due(&conn, now).unwrap().is_empty());
        let claims: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM calendar_reminder_deliveries",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(claims, 0);
        subscribe(&conn, USER);
        remove(
            &conn,
            USER,
            &event.id,
            event.revision,
            "occurrence",
            Some("2026-10-22T09:00"),
            now,
        )
        .unwrap();
        assert!(scan_due(&conn, now).unwrap().is_empty());
    }

    #[test]
    fn override_reminder_is_delivered_even_when_series_has_no_reminders() {
        let (db, _dir) = db();
        let now = millis("2026-10-22T09:00");
        let conn = db.lock();
        subscribe(&conn, USER);
        let event = create(
            &conn,
            USER,
            "override-test",
            &recurring(
                spec(
                    "Moved appointment",
                    "2026-10-21T09:00",
                    "2026-10-21T10:00",
                    vec![],
                ),
                2,
            ),
            now,
        )
        .unwrap();
        let mut moved = spec(
            "Moved appointment",
            "2026-10-22T09:30",
            "2026-10-22T10:30",
            vec![60],
        );
        moved.description = "This reminder belongs to the occurrence override".into();
        update(
            &conn,
            USER,
            &event.id,
            &moved,
            crate::calendar::Mutation {
                revision: event.revision,
                scope: "occurrence",
                occurrence: Some("2026-10-22T09:00"),
            },
            now,
        )
        .unwrap();

        let due = scan_due(&conn, now).unwrap();
        assert_eq!(due.len(), 1);
        assert_eq!(due[0].message.title, "Event reminder: Moved appointment");
        assert_eq!(due[0].message.target["occurrenceStart"], "2026-10-22T09:00");
    }

    #[test]
    fn deleted_series_is_ignored_and_ongoing_events_are_distinguished_from_expired_ones() {
        let (db, _dir) = db();
        let now = millis("2026-10-21T09:00");
        let conn = db.lock();
        subscribe(&conn, USER);
        let ongoing = create(
            &conn,
            USER,
            "ongoing-test",
            &spec(
                "Long appointment",
                "2026-10-21T08:00",
                "2026-10-21T10:00",
                vec![0],
            ),
            now,
        )
        .unwrap();
        create(
            &conn,
            USER,
            "expired-test",
            &spec(
                "Finished appointment",
                "2026-10-21T06:00",
                "2026-10-21T07:00",
                vec![0],
            ),
            now,
        )
        .unwrap();
        let deleted = create(
            &conn,
            USER,
            "deleted-test",
            &spec(
                "Removed appointment",
                "2026-10-21T09:30",
                "2026-10-21T10:00",
                vec![60],
            ),
            now,
        )
        .unwrap();
        remove(
            &conn,
            USER,
            &deleted.id,
            deleted.revision,
            "series",
            None,
            now,
        )
        .unwrap();

        let due = scan_due(&conn, now).unwrap();
        assert_eq!(due.len(), 1);
        assert_eq!(due[0].message.target["eventId"], ongoing.id);
    }
}
