//! Observation (plans/pots.md, Observation and de-duplication), L0 and L1.
//!
//! The Gateway notices a fact on a source (a session's run finished or started
//! waiting for the user), records it once as an `obs_events` row without
//! content, and wakes every active pot whose observe scope covers the source
//! (`event` wakes; `obs_targets` remembers who was reached and through a lead
//! scope or not). Each pot keeps its own note (`obs_observations`, L1); notes
//! are never merged. A pot only learns of what its scopes cover, and never of
//! its own session, another pot's own session, or work it coordinates itself.

use std::sync::Arc;

use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::sync::mpsc;

use super::runtime::{self, NewWake, Source};
use crate::app::App;
use crate::db::Store;
use crate::dispatch::{node_request, text_of};
use crate::error::{ApiError, ApiResult};
use crate::routes::urlencoding_component;
use crate::util::{new_id, now_ms};

pub const MAX_NOTE: usize = 4000;
const MAX_EVIDENCE: usize = 20;
const MAX_ANSWER: usize = 4000;
/// How often the polled sources (schedules, calendar) are looked at.
const POLL: std::time::Duration = std::time::Duration::from_secs(30);
/// Ended schedule runs younger than this are observed (several polls, in case
/// one is missed; L0 keeps each fact once).
const POLL_WINDOW_MS: i64 = 10 * 60_000;
/// A calendar event is "starting soon" this long before it starts.
const SOON_MS: i64 = 30 * 60_000;

/// A session fact the Gateway observed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SessionCondition {
    RunFinished,
    WaitingInput,
}

impl SessionCondition {
    fn key(self) -> &'static str {
        match self {
            Self::RunFinished => "run_finished",
            Self::WaitingInput => "waiting_input",
        }
    }

    fn phrase(self) -> &'static str {
        match self {
            Self::RunFinished => "finished its run",
            Self::WaitingInput => "is waiting for the user",
        }
    }
}

/// Pots of `owner` an event about a session reaches, with whether a scope
/// they lead matched.
fn session_targets(
    conn: &Connection,
    owner: &str,
    session_id: &str,
) -> ApiResult<Vec<(String, bool)>> {
    let session = conn.get_session(session_id)?;
    let project: Option<String> = conn
        .query_row(
            "SELECT project_workspace_id FROM conversation_project_memberships
             WHERE session_id=?1 AND resolution='member'",
            [session_id],
            |r| r.get(0),
        )
        .optional()?
        .flatten();
    let rows: Vec<(String, bool)> = conn
        .prepare(
            "SELECT p.id, max(s.lead) FROM pots p
             JOIN pot_permissions perm ON perm.pot_id=p.id
             JOIN pot_observe_scopes s ON s.pot_id=p.id
             WHERE p.owner_user=?1 AND p.state='active' AND perm.reach IN ('observe','work')
               AND ((s.kind='session' AND s.ref=?2)
                 OR (s.kind='workspace' AND s.ref=?3)
                 OR (s.kind='project' AND ?4 IS NOT NULL AND s.ref=?4))
               -- Not the pot's own session, nor any pot's, nor work it coordinates.
               AND NOT EXISTS(SELECT 1 FROM pot_runtime r WHERE r.session_id=?2)
               AND NOT EXISTS(SELECT 1 FROM pot_works w WHERE w.session_id=?2 AND w.pot_id=p.id)
             GROUP BY p.id ORDER BY p.id",
        )?
        .query_map(
            params![owner, session_id, session.workspace_id, project],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )?
        .collect::<Result<_, _>>()?;
    Ok(rows)
}

/// One observed fact, as L0 keys it.
struct Fact<'a> {
    owner: &'a str,
    source_kind: &'static str,
    source_ref: &'a str,
    condition: &'a str,
    occurrence: &'a str,
}

/// Record a fact once and queue `event` wakes for the pots it reaches.
/// Returns the pots woken (empty when the fact was already known).
fn emit(
    conn: &Connection,
    fact: Fact,
    targets: Vec<(String, bool)>,
    text: impl Fn(&str) -> String,
    details: Value,
) -> ApiResult<Vec<(String, String)>> {
    if targets.is_empty() {
        return Ok(Vec::new());
    }
    let id = new_id("obs");
    let inserted = conn.execute(
        "INSERT OR IGNORE INTO obs_events(id,owner_user,source_kind,source_ref,condition_key,occurrence_key,created_at)
         VALUES(?1,?2,?3,?4,?5,?6,?7)",
        params![id, fact.owner, fact.source_kind, fact.source_ref, fact.condition, fact.occurrence, now_ms()],
    )?;
    if inserted == 0 {
        return Ok(Vec::new());
    }
    let text = text(&id);
    let mut details = details;
    details["eventId"] = json!(id);
    details["condition"] = json!(fact.condition);
    // One root per fact: every pot the event reaches shares its budget and
    // depth. A lead scope's pot initiates it, otherwise the first target.
    let initiator = targets
        .iter()
        .find(|(_, lead)| *lead)
        .or_else(|| targets.first())
        .map(|(pot, _)| pot.clone())
        .expect("targets is not empty");
    let root = super::roots::start(
        conn,
        fact.owner,
        &initiator,
        super::roots::Origin::Event,
        &id,
        None,
    )?
    .id;
    let purpose = super::guard::purpose(
        &format!("event:{}", fact.source_ref),
        "event",
        &format!("event:{id}"),
    );
    let mut woken = Vec::new();
    for (pot, lead) in targets {
        conn.execute(
            "INSERT INTO obs_targets(event_id,pot_id,lead) VALUES(?1,?2,?3)",
            params![id, pot, lead],
        )?;
        runtime::enqueue(
            conn,
            fact.owner,
            &pot,
            NewWake {
                source: Source::Event,
                thread_id: None,
                causal_root: Some(&root),
                depth: 0,
                from_pot: None,
                caused_by: None,
                purpose: purpose.clone(),
                content: &text,
                details: details.clone(),
            },
        )?;
        woken.push((fact.owner.to_owned(), pot));
    }
    Ok(woken)
}

const NOT_A_REQUEST: &str = "Call observe_read with this eventId to look at it, and observe_note to \
     record what you notice. This is not a request from the user.";

/// Record a session fact once and wake the pots observing that session.
pub fn emit_session(
    conn: &Connection,
    session_id: &str,
    condition: SessionCondition,
    occurrence: &str,
) -> ApiResult<Vec<(String, String)>> {
    let session = conn.get_session(session_id)?;
    let Some(owner) = session.owner_user.clone() else {
        return Ok(Vec::new());
    };
    let targets = session_targets(conn, &owner, session_id)?;
    emit(
        conn,
        Fact {
            owner: &owner,
            source_kind: "session",
            source_ref: session_id,
            condition: condition.key(),
            occurrence,
        },
        targets,
        |id| {
            format!(
                "Observed (eventId {id}): the session \"{}\" in {} {}. {NOT_A_REQUEST}",
                session.name,
                session.workspace_id,
                condition.phrase()
            )
        },
        json!({ "sessionId": session_id }),
    )
}

/// Active observing pots of `owner` with a scope of `kind` that is all of
/// that kind (`ref` empty) or exactly `reference`.
fn kind_targets(
    conn: &Connection,
    owner: &str,
    kind: &str,
    reference: &str,
) -> ApiResult<Vec<(String, bool)>> {
    Ok(conn
        .prepare(
            "SELECT p.id, max(s.lead) FROM pots p
             JOIN pot_permissions perm ON perm.pot_id=p.id
             JOIN pot_observe_scopes s ON s.pot_id=p.id
             WHERE p.owner_user=?1 AND p.state='active' AND perm.reach IN ('observe','work')
               AND s.kind=?2 AND (s.ref='' OR s.ref=?3)
             GROUP BY p.id ORDER BY p.id",
        )?
        .query_map(params![owner, kind, reference], |r| {
            Ok((r.get(0)?, r.get(1)?))
        })?
        .collect::<Result<_, _>>()?)
}

/// Schedule runs that ended recently (completed, failed or missed).
fn poll_schedules(conn: &Connection, now: i64) -> ApiResult<Vec<(String, String)>> {
    let runs: Vec<(String, String, String, String, String)> = conn
        .prepare(
            "SELECT r.id, r.schedule_id, r.owner_user, r.status, s.title FROM schedule_runs r
             JOIN schedules s ON s.id=r.schedule_id
             WHERE r.status IN ('completed','failed','missed')
               AND COALESCE(r.finished_at, r.created_at) >= ?1
             ORDER BY r.created_at LIMIT 500",
        )?
        .query_map([now - POLL_WINDOW_MS], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?))
        })?
        .collect::<Result<_, _>>()?;
    let mut woken = Vec::new();
    for (run, schedule, owner, status, title) in runs {
        let targets = kind_targets(conn, &owner, "schedules", &schedule)?;
        let condition = format!("run_{status}");
        woken.extend(emit(
            conn,
            Fact {
                owner: &owner,
                source_kind: "schedule_run",
                source_ref: &run,
                condition: &condition,
                occurrence: "1",
            },
            targets,
            |id| {
                format!("Observed (eventId {id}): a run of the schedule \"{title}\" ended: {status}. {NOT_A_REQUEST}")
            },
            json!({ "scheduleId": schedule, "runId": run }),
        )?);
    }
    Ok(woken)
}

/// Calendar events starting within the next half hour.
fn poll_calendar(conn: &Connection, now: i64) -> ApiResult<Vec<(String, String)>> {
    let owners: Vec<String> = conn
        .prepare(
            "SELECT DISTINCT p.owner_user FROM pots p
             JOIN pot_observe_scopes s ON s.pot_id=p.id
             WHERE p.state='active' AND s.kind='calendar'",
        )?
        .query_map([], |r| r.get(0))?
        .collect::<Result<_, _>>()?;
    let mut woken = Vec::new();
    for owner in owners {
        for event in crate::calendar::list(conn, &owner)? {
            for (occurrence, spec) in
                crate::calendar::event_occurrences(conn, &event, now, now + SOON_MS)?
            {
                if occurrence.start_at < now || occurrence.start_at > now + SOON_MS {
                    continue;
                }
                let targets = kind_targets(conn, &owner, "calendar", &event.id)?;
                let minutes = (occurrence.start_at - now) / 60_000;
                woken.extend(emit(
                    conn,
                    Fact {
                        owner: &owner,
                        source_kind: "calendar",
                        source_ref: &event.id,
                        condition: "starting_soon",
                        occurrence: &occurrence.start_at.to_string(),
                    },
                    targets,
                    |id| {
                        format!(
                            "Observed (eventId {id}): the calendar event \"{}\" starts in about {minutes} minutes. {NOT_A_REQUEST}",
                            spec.title
                        )
                    },
                    json!({ "calendarEventId": event.id, "startAt": occurrence.start_at }),
                )?);
            }
        }
    }
    Ok(woken)
}

/// Look at the polled sources once; facts already known are skipped.
pub fn poll(conn: &Connection, now: i64) -> ApiResult<Vec<(String, String)>> {
    let mut woken = poll_schedules(conn, now)?;
    woken.extend(poll_calendar(conn, now)?);
    Ok(woken)
}

/// Hands woken pots to the runtime from code that holds only `&App`.
struct Runtime {
    kicks: mpsc::UnboundedSender<(String, String)>,
}

/// Start delivering the wakes observations queue.
pub fn start(app: &crate::app::AppState) {
    let (kicks, mut pending) = mpsc::unbounded_channel::<(String, String)>();
    app.slots.set(Arc::new(Runtime { kicks }));
    let kicker = app.clone();
    tokio::spawn(async move {
        while let Some((owner, pot)) = pending.recv().await {
            runtime::kick(&kicker, &owner, &pot);
        }
    });
    let app = app.clone();
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(POLL);
        loop {
            interval.tick().await;
            let woken = poll(&app.db.lock(), now_ms());
            match woken {
                Ok(woken) => {
                    for (owner, pot) in woken {
                        runtime::kick(&app, &owner, &pot);
                    }
                }
                Err(error) => crate::log::warn(&format!("pot observation poll: {}", error.message)),
            }
        }
    });
}

/// A session's live activity changed (`node_events.rs`).
pub fn on_session(app: &App, session_id: &str, condition: SessionCondition, occurrence: &str) {
    let woken = match emit_session(&app.db.lock(), session_id, condition, occurrence) {
        Ok(woken) => woken,
        Err(error) => {
            crate::log::warn(&format!("observation of {session_id}: {}", error.message));
            return;
        }
    };
    let mut owners: Vec<&str> = woken.iter().map(|(owner, _)| owner.as_str()).collect();
    owners.sort();
    owners.dedup();
    for owner in owners {
        app.causal_roots_changed(owner);
    }
    if let Some(runtime) = app.slots.get::<Runtime>() {
        for kick in woken {
            let _ = runtime.kicks.send(kick);
        }
    }
}

/// The event, if it reached the pot.
fn reached(
    conn: &Connection,
    owner: &str,
    pot_id: &str,
    event_id: &str,
) -> ApiResult<(String, String, String)> {
    conn.query_row(
        "SELECT e.source_kind, e.source_ref, e.condition_key FROM obs_events e
         JOIN obs_targets t ON t.event_id=e.id
         WHERE e.id=?1 AND e.owner_user=?2 AND t.pot_id=?3",
        params![event_id, owner, pot_id],
        |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
    )
    .optional()?
    .ok_or_else(|| ApiError::not_found("No such event reached you"))
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Note {
    pub event_id: String,
    pub note: String,
    #[serde(default)]
    pub evidence: Vec<String>,
    /// Ask to tell the user (L2): the lead pot does, or everyone's notes merge.
    #[serde(default)]
    pub notify: bool,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Observation {
    pub id: String,
    pub pot_id: String,
    pub event_id: String,
    pub note: String,
    pub evidence: Vec<String>,
    pub created_at: i64,
}

/// What a note did beyond being kept.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Noted {
    pub observation: Observation,
    /// The event's notification, if there is one; the note is attached to it.
    pub notification_id: Option<String>,
    /// This note created the notification: the user is told now.
    pub notified: bool,
    /// A lead pot tells the user about this event, not this pot.
    pub lead_pot: Option<String>,
}

/// Attach an observation to the event's notification, if there is one.
fn attach(
    conn: &Connection,
    owner: &str,
    event_id: &str,
    observation_id: &str,
) -> ApiResult<Option<String>> {
    let id: Option<String> = conn
        .query_row(
            "SELECT id FROM obs_notifications WHERE owner_user=?1 AND event_id=?2",
            params![owner, event_id],
            |r| r.get(0),
        )
        .optional()?;
    if let Some(id) = &id {
        conn.execute(
            "UPDATE obs_notifications SET observation_ids_json=json_insert(observation_ids_json,'$[#]',?2),
              updated_at=?3, state='open' WHERE id=?1
              AND NOT EXISTS(SELECT 1 FROM json_each(observation_ids_json) WHERE value=?2)",
            params![id, observation_id, now_ms()],
        )?;
    }
    Ok(id)
}

/// The pot's L1 note on an event that reached it (one per pot and event),
/// attached to the event's notification; with `notify`, the notification is
/// created by the lead pot, or merged when the event reached no lead.
pub fn note(conn: &Connection, owner: &str, pot_id: &str, input: Note) -> ApiResult<Noted> {
    let notify = input.notify;
    let event_id = input.event_id.clone();
    let observation = keep_note(conn, owner, pot_id, input)?;
    let leads: Vec<String> = conn
        .prepare("SELECT pot_id FROM obs_targets WHERE event_id=?1 AND lead=1 ORDER BY pot_id")?
        .query_map([&event_id], |r| r.get(0))?
        .collect::<Result<_, _>>()?;
    let mut lead_pot = None;
    let mut notified = false;
    if notify {
        if !leads.is_empty() && !leads.iter().any(|lead| lead == pot_id) {
            lead_pot = Some(
                conn.query_row("SELECT name FROM pots WHERE id=?1", [&leads[0]], |r| {
                    r.get(0)
                })
                .unwrap_or_else(|_| leads[0].clone()),
            );
        } else {
            let issuer = (!leads.is_empty()).then_some(pot_id);
            let stamp = now_ms();
            notified = conn.execute(
                "INSERT OR IGNORE INTO obs_notifications(id,owner_user,event_id,issuer_pot_id,created_at,updated_at)
                 VALUES(?1,?2,?3,?4,?5,?5)",
                params![new_id("notif"), owner, event_id, issuer, stamp],
            )? == 1;
        }
    }
    let notification_id = attach(conn, owner, &event_id, &observation.id)?;
    if notified {
        let preview: String = observation.note.chars().take(160).collect();
        super::activity::log(
            conn,
            owner,
            pot_id,
            super::activity::Entry::new(
                super::activity::Kind::ForwardedToUser,
                format!("Told the user: {preview}"),
            )
            .toward(super::activity::Counterpart::User),
        )?;
    }
    Ok(Noted {
        observation,
        notification_id,
        notified,
        lead_pot,
    })
}

fn keep_note(conn: &Connection, owner: &str, pot_id: &str, input: Note) -> ApiResult<Observation> {
    reached(conn, owner, pot_id, &input.event_id)?;
    let note = input.note.trim();
    if note.is_empty() || note.chars().count() > MAX_NOTE {
        return Err(ApiError::new(
            400,
            "invalid_input",
            "A note is 1 to 4000 characters",
        ));
    }
    if input.evidence.len() > MAX_EVIDENCE
        || input.evidence.iter().any(|e| e.is_empty() || e.len() > 500)
    {
        return Err(ApiError::new(
            400,
            "invalid_input",
            "Up to 20 evidence references of 1 to 500 bytes",
        ));
    }
    let id = new_id("obsn");
    let inserted = conn.execute(
        "INSERT OR IGNORE INTO obs_observations(id,pot_id,event_id,note,evidence_json,created_at)
         VALUES(?1,?2,?3,?4,?5,?6)",
        params![
            id,
            pot_id,
            input.event_id,
            note,
            serde_json::to_string(&input.evidence).expect("strings serialize"),
            now_ms()
        ],
    )?;
    if inserted == 0 {
        return Err(ApiError::new(
            409,
            "already_noted",
            "You already noted this event",
        ));
    }
    Ok(Observation {
        id,
        pot_id: pot_id.to_owned(),
        event_id: input.event_id,
        note: note.to_owned(),
        evidence: input.evidence,
        created_at: now_ms(),
    })
}

/// What an observed session shows, read only: its name, run status and last
/// answer.
pub async fn read(app: &App, owner: &str, pot_id: &str, event_id: &str) -> ApiResult<Value> {
    let (kind, source, condition) = reached(&app.db.lock(), owner, pot_id, event_id)?;
    match kind.as_str() {
        "schedule_run" => {
            let run: Option<(String, String, Option<String>, Option<String>)> = app
                .db
                .lock()
                .query_row(
                    "SELECT s.title, r.status, r.result, r.session_id FROM schedule_runs r
                     JOIN schedules s ON s.id=r.schedule_id WHERE r.id=?1 AND r.owner_user=?2",
                    params![source, owner],
                    |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
                )
                .optional()?;
            let Some((title, status, result, session)) = run else {
                return Ok(json!({ "eventId": event_id, "condition": condition, "gone": true }));
            };
            let result: Option<String> = result.map(|text| text.chars().take(MAX_ANSWER).collect());
            return Ok(json!({
                "eventId": event_id,
                "condition": condition,
                "scheduleRun": { "id": source, "title": title, "status": status, "result": result, "sessionId": session },
            }));
        }
        "calendar" => {
            let event = crate::calendar::list(&app.db.lock(), owner)?
                .into_iter()
                .find(|event| event.id == source);
            let Some(event) = event else {
                return Ok(json!({ "eventId": event_id, "condition": condition, "gone": true }));
            };
            return Ok(json!({
                "eventId": event_id,
                "condition": condition,
                "calendarEvent": {
                    "id": event.id, "title": event.spec.title, "start": event.spec.start,
                    "end": event.spec.end, "timezone": event.spec.timezone,
                    "location": event.spec.location, "description": event.spec.description,
                },
            }));
        }
        _ => {}
    }
    let session = app.db.lock().get_session(&source)?;
    let mut out = json!({
        "eventId": event_id,
        "condition": condition,
        "session": { "id": session.id, "name": session.name, "workspaceId": session.workspace_id },
    });
    let (Some(node), Some(remote)) = (&session.node_id, &session.pi_session_id) else {
        return Ok(out);
    };
    let snapshot = node_request(
        app,
        node,
        owner,
        pirc_protocol::HttpMethod::Get,
        format!("/api/sessions/{}/snapshot", urlencoding_component(remote)),
        None,
    )
    .await
    .map_err(|failure| ApiError::new(503, "node_unavailable", failure.0))?;
    out["run"] = snapshot["run"]["status"].clone();
    let answer = snapshot["history"]
        .as_array()
        .and_then(|history| {
            history
                .iter()
                .rev()
                .find(|m| m["role"] == "assistant" && !text_of(m).is_empty())
        })
        .map(|m| text_of(m).chars().take(MAX_ANSWER).collect::<String>());
    out["lastAnswer"] = json!(answer);
    Ok(out)
}

/// One notification as the user sees it: the event and every attached note.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Notification {
    pub id: String,
    pub event_id: String,
    pub source_kind: String,
    pub source_ref: String,
    pub condition: String,
    /// The lead pot that told the user; absent when merged.
    pub issuer_pot_id: Option<String>,
    pub observations: Vec<NotedBy>,
    pub state: String,
    pub created_at: i64,
    pub updated_at: i64,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NotedBy {
    pub pot_id: String,
    pub pot_name: String,
    pub note: String,
    pub evidence: Vec<String>,
    pub created_at: i64,
}

fn notification(conn: &Connection, row: NotificationRow) -> ApiResult<Notification> {
    let (
        id,
        event_id,
        source_kind,
        source_ref,
        condition,
        issuer,
        ids,
        state,
        created_at,
        updated_at,
    ) = row;
    let ids: Vec<String> = serde_json::from_str(&ids).unwrap_or_default();
    let mut observations = Vec::new();
    for observation in ids {
        let found = conn
            .query_row(
                "SELECT o.pot_id, p.name, o.note, o.evidence_json, o.created_at FROM obs_observations o
                 JOIN pots p ON p.id=o.pot_id WHERE o.id=?1",
                [&observation],
                |r| {
                    let evidence: String = r.get(3)?;
                    Ok(NotedBy {
                        pot_id: r.get(0)?,
                        pot_name: r.get(1)?,
                        note: r.get(2)?,
                        evidence: serde_json::from_str(&evidence).unwrap_or_default(),
                        created_at: r.get(4)?,
                    })
                },
            )
            .optional()?;
        observations.extend(found);
    }
    Ok(Notification {
        id,
        event_id,
        source_kind,
        source_ref,
        condition,
        issuer_pot_id: issuer,
        observations,
        state,
        created_at,
        updated_at,
    })
}

const NOTIFICATION: &str =
    "SELECT n.id, n.event_id, e.source_kind, e.source_ref, e.condition_key, n.issuer_pot_id,
  n.observation_ids_json, n.state, n.created_at, n.updated_at
  FROM obs_notifications n JOIN obs_events e ON e.id=n.event_id";

type NotificationRow = (
    String,
    String,
    String,
    String,
    String,
    Option<String>,
    String,
    String,
    i64,
    i64,
);

fn notification_row(r: &rusqlite::Row) -> rusqlite::Result<NotificationRow> {
    Ok((
        r.get(0)?,
        r.get(1)?,
        r.get(2)?,
        r.get(3)?,
        r.get(4)?,
        r.get(5)?,
        r.get(6)?,
        r.get(7)?,
        r.get(8)?,
        r.get(9)?,
    ))
}

/// The owner's notifications, newest first; `state` is `open` or `read`.
pub fn notifications(
    conn: &Connection,
    owner: &str,
    state: Option<&str>,
) -> ApiResult<Vec<Notification>> {
    if state.is_some_and(|s| s != "open" && s != "read") {
        return Err(ApiError::new(400, "invalid_input", "state is open or read"));
    }
    let rows: Vec<NotificationRow> = conn
        .prepare(&format!(
            "{NOTIFICATION} WHERE n.owner_user=?1 AND (?2 IS NULL OR n.state=?2) ORDER BY n.updated_at DESC, n.rowid DESC LIMIT 200"
        ))?
        .query_map(params![owner, state], notification_row)?
        .collect::<Result<_, _>>()?;
    rows.into_iter()
        .map(|row| notification(conn, row))
        .collect()
}

pub fn mark_read(conn: &Connection, owner: &str, id: &str) -> ApiResult<Notification> {
    if conn.execute(
        "UPDATE obs_notifications SET state='read' WHERE id=?1 AND owner_user=?2",
        params![id, owner],
    )? == 0
    {
        return Err(ApiError::not_found("Notification not found"));
    }
    let row = conn.query_row(
        &format!("{NOTIFICATION} WHERE n.id=?1"),
        [id],
        notification_row,
    )?;
    notification(conn, row)
}

/// What a notification shows as a push.
pub fn push_message(
    conn: &Connection,
    notification_id: &str,
) -> ApiResult<crate::push::PushMessage> {
    let row = conn.query_row(
        &format!("{NOTIFICATION} WHERE n.id=?1"),
        [notification_id],
        notification_row,
    )?;
    let shown = notification(conn, row)?;
    let first = shown.observations.first();
    Ok(crate::push::PushMessage {
        title: first.map_or_else(
            || crate::push::text::NOTICED_TITLE.to_owned(),
            |o| format!("{} noticed something", o.pot_name),
        ),
        body: first
            .map(|o| o.note.chars().take(200).collect())
            .unwrap_or_default(),
        tag: format!("pot-notification:{}", shown.id),
        target: json!({ "activityNotificationId": shown.id }),
        category: Some(crate::push::Category::Done),
        interaction: None,
        text: first.map(|o| {
            crate::push::text::PushText::new(
                crate::push::text::POT_NOTICED,
                &[("pot", &o.pot_name)],
            )
        }),
    })
}

/// The purpose a work start serves for an event (L3): target, action, event.
fn purpose(workspace_id: &str, event_id: &str) -> String {
    format!("{workspace_id}|work_open|{event_id}")
}

fn handled_by(conn: &Connection, owner: &str, key: &str) -> ApiResult<Option<String>> {
    Ok(conn
        .query_row(
            "SELECT p.name FROM obs_dispatches d JOIN pots p ON p.id=d.pot_id
             WHERE d.owner_user=?1 AND d.purpose_key=?2 AND d.state='active'",
            params![owner, key],
            |r| r.get(0),
        )
        .optional()?)
}

fn already_handled(name: &str) -> ApiError {
    ApiError::new(
        409,
        "already_handled",
        format!("{name} is already handling this; add what you know with observe_note"),
    )
}

/// Before asking for an approval: is this purpose already someone's?
pub fn check_dispatch(
    conn: &Connection,
    owner: &str,
    pot_id: &str,
    event_id: &str,
    workspace_id: &str,
) -> ApiResult<()> {
    reached(conn, owner, pot_id, event_id)?;
    match handled_by(conn, owner, &purpose(workspace_id, event_id))? {
        Some(name) => Err(already_handled(&name)),
        None => Ok(()),
    }
}

/// Claim the purpose for this pot's work start; a second pot is refused with
/// who handles it.
pub fn claim_dispatch(
    conn: &Connection,
    owner: &str,
    pot_id: &str,
    event_id: &str,
    workspace_id: &str,
) -> ApiResult<String> {
    reached(conn, owner, pot_id, event_id)?;
    let key = purpose(workspace_id, event_id);
    let id = new_id("disp");
    let inserted = conn.execute(
        "INSERT OR IGNORE INTO obs_dispatches(id,owner_user,event_id,purpose_key,pot_id,created_at)
         VALUES(?1,?2,?3,?4,?5,?6)",
        params![id, owner, event_id, key, pot_id, now_ms()],
    )?;
    if inserted == 0 {
        let name = handled_by(conn, owner, &key)?.unwrap_or_else(|| "another pot".to_owned());
        return Err(already_handled(&name));
    }
    Ok(id)
}

pub fn dispatch_started(conn: &Connection, dispatch_id: &str, work_id: &str) -> ApiResult<()> {
    conn.execute(
        "UPDATE obs_dispatches SET work_id=?2 WHERE id=?1",
        params![dispatch_id, work_id],
    )?;
    Ok(())
}

/// The start failed, or the user took the work over: the purpose is free.
pub fn release_dispatch(conn: &Connection, dispatch_id: &str) -> ApiResult<()> {
    conn.execute(
        "UPDATE obs_dispatches SET state='released' WHERE id=?1",
        [dispatch_id],
    )?;
    Ok(())
}

pub fn release_work(conn: &Connection, work_id: &str) -> ApiResult<()> {
    conn.execute(
        "UPDATE obs_dispatches SET state='released' WHERE work_id=?1",
        [work_id],
    )?;
    Ok(())
}
