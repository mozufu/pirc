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
                causal_root: None,
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

/// The pot's L1 note on an event that reached it; one per pot and event.
pub fn note(conn: &Connection, owner: &str, pot_id: &str, input: Note) -> ApiResult<Observation> {
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
