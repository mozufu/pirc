//! A pot's runtime (plans/pots.md, Runtime): each pot has one persistent session
//! in the chat node's `pots` workspace, allocated on first need. Wakes wait in
//! `pot_wakes` and are delivered one at a time as `pot-wake` messages; when the
//! run that took a wake is over, its last answer is the wake's reply.
//!
//! Delivery is at most once. A wake is claimed (`delivering`) before the
//! request leaves; one whose delivery outcome is unknown is never re-sent, and
//! is failed if the session never shows it.

use std::time::Duration;

use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Value, json};

use super::delivery::Sent;
use super::store::{self, PotState};
use crate::app::AppState;
use crate::db::{Session, Store};
use crate::dispatch::{Progress, read_progress, start_session};
use crate::error::{ApiError, ApiResult};
use crate::util::{new_id, now_ms};

/// Delivery attempts before a wake is failed (each only after a refused send).
const MAX_ATTEMPTS: i64 = 3;
/// A delivered wake the session never shows is failed after this long.
const UNSEEN_LIMIT_MS: i64 = 10 * 60_000;
/// How often every pot with pending wakes is looked at again.
const SWEEP: Duration = Duration::from_secs(30);

/// A claimed wake: id, source, content, details, causal root and sender.
type QueuedWake = (
    String,
    String,
    String,
    String,
    Option<String>,
    Option<String>,
);

/// Where a wake came from.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Source {
    User,
    Group,
    Dm,
    Approval,
    Handover,
    Reminder,
    Review,
    Budget,
    Event,
}

impl Source {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::User => "user",
            Self::Group => "group",
            Self::Dm => "dm",
            Self::Approval => "approval",
            Self::Handover => "handover",
            Self::Reminder => "reminder",
            Self::Review => "review",
            Self::Budget => "budget",
            Self::Event => "event",
        }
    }
}

/// A wake to queue.
pub struct NewWake<'a> {
    pub source: Source,
    pub thread_id: Option<&'a str>,
    /// The causal root this wake belongs to (`roots::start`).
    pub causal_root: Option<&'a str>,
    /// Hops from the root: 0 for the origin's own wake.
    pub depth: i64,
    /// The pot whose message caused it, when one did.
    pub from_pot: Option<&'a str>,
    /// The wake whose handling caused it, for the fan-out limit.
    pub caused_by: Option<&'a str>,
    /// Structured target, action and source for repeated-purpose detection.
    pub purpose: Value,
    pub content: &'a str,
    pub details: Value,
}

/// An enqueue whose root was stopped queues nothing, and that is not an error
/// for a caller recording a user decision.
pub fn unless_stopped(queued: ApiResult<String>) -> ApiResult<Option<String>> {
    match queued {
        Ok(id) => Ok(Some(id)),
        Err(error) if error.code == "root_stopped" => Ok(None),
        Err(error) => Err(error),
    }
}

/// Queue a wake for the owner's pot; it is delivered by [`kick`] or the sweep.
/// A wake past its root's depth or fan-out limit is refused with a clear error
/// instead of being queued; the caller still stores what it was doing.
pub fn enqueue(conn: &Connection, owner: &str, pot_id: &str, wake: NewWake) -> ApiResult<String> {
    store::read(conn, owner, pot_id)?;
    if let Some(root_id) = wake.causal_root {
        let root: Option<(i64, i64, String)> = conn
            .query_row(
                "SELECT depth_limit,fanout_limit,state FROM causal_roots WHERE id=?1",
                [root_id],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .optional()?;
        if let Some((depth_limit, fanout_limit, state)) = root {
            if state == "stopped" {
                return Err(ApiError::new(
                    409,
                    "root_stopped",
                    "This causal root was stopped; nothing more is delivered for it",
                ));
            }
            if wake.depth > depth_limit {
                return Err(ApiError::new(
                    409,
                    "wake_depth",
                    format!("The causal root reached its depth limit ({depth_limit})"),
                ));
            }
            if let Some(parent) = wake.caused_by {
                let children: i64 = conn.query_row(
                    "SELECT count(*) FROM pot_wakes WHERE caused_by=?1",
                    [parent],
                    |r| r.get(0),
                )?;
                if children >= fanout_limit {
                    return Err(ApiError::new(
                        409,
                        "wake_fanout",
                        format!(
                            "This wake would exceed the causal root's fan-out limit ({fanout_limit})"
                        ),
                    ));
                }
            }
        }
    }
    let id = new_id("wake");
    conn.execute(
        "INSERT INTO pot_wakes(id,pot_id,owner_user,source,thread_id,causal_root,depth,from_pot,
           caused_by,purpose_json,content,details_json,created_at)
         VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13)",
        params![
            id,
            pot_id,
            owner,
            wake.source.as_str(),
            wake.thread_id,
            wake.causal_root,
            wake.depth,
            wake.from_pot,
            wake.caused_by,
            wake.purpose.to_string(),
            wake.content,
            wake.details.to_string(),
            now_ms(),
        ],
    )?;
    if let Some(root_id) = wake.causal_root
        && let Err(error) =
            super::guard::note_wake(conn, root_id, pot_id, wake.from_pot, &wake.purpose)
    {
        crate::log::warn(&format!("loop guard for root {root_id}: {}", error.message));
    }
    if wake.source != Source::Review {
        super::autonomy::engage(conn, pot_id)?;
    }
    Ok(id)
}

/// A pot wake's state.
#[cfg(test)]
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Wake {
    pub id: String,
    pub state: String,
    pub attempts: i64,
    pub reply: Option<String>,
    pub error: Option<String>,
}

#[cfg(test)]
pub fn wake(conn: &Connection, id: &str) -> ApiResult<Wake> {
    conn.query_row(
        "SELECT id,state,attempts,reply,error FROM pot_wakes WHERE id=?1",
        [id],
        |r| {
            Ok(Wake {
                id: r.get(0)?,
                state: r.get(1)?,
                attempts: r.get(2)?,
                reply: r.get(3)?,
                error: r.get(4)?,
            })
        },
    )
    .optional()?
    .ok_or_else(|| ApiError::not_found("Wake not found"))
}

/// The pot's own session, allocated in the chat node's `pots` workspace when it
/// has none (or its session is gone).
async fn ensure_session(app: &AppState, owner: &str, pot_id: &str) -> Result<Session, String> {
    let (name, existing) = {
        let conn = app.db.lock();
        let pot = store::read(&conn, owner, pot_id).map_err(|e| e.message)?;
        let existing = pot
            .session_id
            .as_deref()
            .and_then(|id| conn.get_session(id).ok());
        (pot.input.profile.name, existing)
    };
    if let Some(session) = existing {
        return Ok(session);
    }
    let node = app
        .db
        .lock()
        .assistant_node()
        .map_err(|e| e.message)?
        .ok_or("no chat node hosts pots")?;
    let workspace = app
        .db
        .lock()
        .get_workspace(&format!("{node}:{}", pirc_config::POTS_WORKSPACE_ID))
        .map_err(|_| "the chat node has no pots workspace".to_owned())?;
    let session = start_session(app, &workspace, owner, &name)
        .await
        .map_err(|failure| failure.0)?;
    app.db
        .lock()
        .execute(
            "UPDATE pot_runtime SET session_id=?1 WHERE pot_id=?2",
            params![session.id, pot_id],
        )
        .map_err(|e| e.to_string())?;
    super::autonomy::clear_applied(&app.db.lock(), pot_id).map_err(|e| e.message)?;
    Ok(session)
}

/// Claim the pot's next queued wake, unless one is in flight or the pot is
/// not active. The partial unique index makes a second claim fail.
fn claim(
    conn: &Connection,
    owner: &str,
    pot_id: &str,
    zone: &str,
) -> ApiResult<Option<(String, String, Value)>> {
    let pot = store::read(conn, owner, pot_id)?;
    if pot.state != PotState::Active {
        return Ok(None);
    }
    // A suspended or stopped root delivers nothing: its wakes stay queued.
    let next: Option<QueuedWake> = conn
        .query_row(
            "SELECT w.id,w.source,w.content,w.details_json,w.causal_root,w.from_pot
             FROM pot_wakes w
             WHERE w.pot_id=?1 AND w.state='queued'
               AND (w.causal_root IS NULL
                 OR EXISTS(SELECT 1 FROM causal_roots r
                           WHERE r.id=w.causal_root AND r.state='active'))
             ORDER BY w.created_at, w.rowid LIMIT 1",
            [pot_id],
            |r| {
                Ok((
                    r.get(0)?,
                    r.get(1)?,
                    r.get(2)?,
                    r.get(3)?,
                    r.get(4)?,
                    r.get(5)?,
                ))
            },
        )
        .optional()?;
    let Some((id, source, content, details, root, from_pot)) = next else {
        return Ok(None);
    };
    // An exhausted pot's model wakes wait; the answer to its budget request
    // still reaches it so it learns the user's decision.
    if source != "budget" && super::budget::wake_blocked(conn, owner, pot_id, zone)? {
        return Ok(None);
    }
    // Rate ceilings delay delivery: the oldest wake stays queued until the
    // root or the pair is allowed again.
    if super::guard::delivery_blocked(conn, root.as_deref(), from_pot.as_deref(), pot_id)? {
        return Ok(None);
    }
    let claimed = conn.execute(
        "UPDATE pot_wakes SET state='delivering' WHERE id=?1 AND state='queued'
         AND NOT EXISTS(SELECT 1 FROM pot_wakes WHERE pot_id=?2 AND state IN ('delivering','delivered'))",
        params![id, pot_id],
    );
    match claimed {
        Ok(1) => {}
        Ok(_) => return Ok(None),
        Err(rusqlite::Error::SqliteFailure(failure, _))
            if failure.code == rusqlite::ErrorCode::ConstraintViolation =>
        {
            return Ok(None);
        }
        Err(error) => return Err(error.into()),
    }
    let mut details: Value = serde_json::from_str(&details).unwrap_or_else(|_| json!({}));
    details["wakeId"] = json!(id);
    details["source"] = json!(source);
    Ok(Some((id, content, details)))
}

/// Claim the pot's next wake, for budget tests that must not need a Node.
#[cfg(test)]
pub fn claim_next(
    conn: &Connection,
    owner: &str,
    pot_id: &str,
    zone: &str,
) -> ApiResult<Option<String>> {
    Ok(claim(conn, owner, pot_id, zone)?.map(|(id, _, _)| id))
}

/// Deliver the pot's next wake if nothing is in flight.
pub async fn pump(app: &AppState, owner: &str, pot_id: &str) -> ApiResult<()> {
    let Some((id, content, details)) = claim(&app.db.lock(), owner, pot_id, &app.config.timezone)?
    else {
        return Ok(());
    };
    let session = match ensure_session(app, owner, pot_id).await {
        Ok(session) => session,
        Err(reason) => {
            // Nothing left: the wake waits for the chat node, attempts unchanged.
            app.db.lock().execute(
                "UPDATE pot_wakes SET state='queued',error=?2 WHERE id=?1",
                params![id, reason],
            )?;
            return Ok(());
        }
    };
    let settings = super::autonomy::wake_settings(&app.db.lock(), owner, pot_id)?;
    let mut message = json!({ "customType": "pot-wake", "content": content, "details": details });
    if let Some((model, thinking)) = &settings {
        message["model"] = json!({ "provider": model.provider, "id": model.model });
        message["thinking"] = json!(thinking);
    }
    let sent = super::delivery::send(app, &session, owner, message).await;
    let conn = app.db.lock();
    match sent {
        Sent::Delivered => {
            if let Some((model, thinking)) = &settings {
                super::autonomy::mark_applied(&conn, pot_id, model, thinking)?;
            }
            conn.execute(
                "UPDATE pot_wakes SET state='delivered',delivered_at=?2,error=NULL WHERE id=?1",
                params![id, now_ms()],
            )?;
        }
        // It may have run: followed like a delivered wake, never sent again;
        // if the session never shows it, it is failed later.
        Sent::Uncertain(reason) => {
            conn.execute(
                "UPDATE pot_wakes SET state='delivered',delivered_at=?2,error=?3 WHERE id=?1",
                params![id, now_ms(), reason],
            )?;
        }
        Sent::Refused(reason) => {
            // The Node refused or was never asked: the message did not run.
            conn.execute(
                "UPDATE pot_wakes SET attempts=attempts+1,error=?2,
                  state=CASE WHEN attempts+1>=?3 THEN 'failed' ELSE 'queued' END WHERE id=?1",
                params![id, reason, MAX_ATTEMPTS],
            )?;
        }
    }
    Ok(())
}

/// Follow the pot's delivered wake; when its run is over, keep the answer and
/// move on to the next wake.
pub async fn check(app: &AppState, owner: &str, pot_id: &str) -> ApiResult<()> {
    let found: Option<(String, i64, Option<String>)> = {
        let conn = app.db.lock();
        conn.query_row(
            "SELECT w.id, COALESCE(w.delivered_at,w.created_at), r.session_id FROM pot_wakes w
             JOIN pot_runtime r ON r.pot_id=w.pot_id
             WHERE w.pot_id=?1 AND w.state IN ('delivering','delivered')",
            [pot_id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .optional()?
    };
    let Some((id, delivered_at, Some(session_id))) = found else {
        return pump(app, owner, pot_id).await;
    };
    let session = app.db.lock().get_session(&session_id)?;
    let progress = read_progress(app, &session, owner, delivered_at, |message| {
        message
            .get("details")
            .and_then(|details| details.get("wakeId"))
            .and_then(Value::as_str)
            == Some(id.as_str())
    })
    .await
    .map_err(|failure| ApiError::new(503, "node_unavailable", failure.0))?;
    let settled = {
        let conn = app.db.lock();
        match progress {
            Progress::Over {
                answer,
                failure_reason,
                ..
            } => {
                conn.execute(
                    "UPDATE pot_wakes SET state='settled',settled_at=?2,reply=?3,error=?4 WHERE id=?1",
                    params![id, now_ms(), answer, failure_reason],
                )?;
                if super::threads::post_reply(&conn, &id)?.is_some() {
                    app.threads_changed(owner);
                    app.causal_roots_changed(owner);
                }
                true
            }
            Progress::Dropped => {
                conn.execute(
                    "UPDATE pot_wakes SET state='failed',settled_at=?2,error='The pot stopped before it took the message' WHERE id=?1",
                    params![id, now_ms()],
                )?;
                true
            }
            // Never seen in the session: the delivery outcome is unknown. It is
            // not re-sent; after a while it is given up.
            Progress::Queued if now_ms() - delivered_at > UNSEEN_LIMIT_MS => {
                conn.execute(
                    "UPDATE pot_wakes SET state='failed',settled_at=?2,error='Delivery could not be confirmed' WHERE id=?1",
                    params![id, now_ms()],
                )?;
                true
            }
            Progress::Queued | Progress::Working | Progress::Waiting(_) | Progress::Unknown => {
                false
            }
        }
    };
    if settled {
        app.pots_changed(owner);
        pump(app, owner, pot_id).await?;
    }
    Ok(())
}

/// Look at the pot again soon, without waiting for the sweep.
pub fn kick(app: &AppState, owner: &str, pot_id: &str) {
    let (app, owner, pot_id) = (app.clone(), owner.to_owned(), pot_id.to_owned());
    tokio::spawn(async move {
        if let Err(error) = check(&app, &owner, &pot_id).await {
            crate::log::warn(&format!("pot {pot_id}: {}", error.message));
        }
    });
}

/// The pot whose own session `session_id` is, if any.
pub fn pot_of(conn: &Connection, session_id: &str) -> Option<(String, String)> {
    conn.query_row(
        "SELECT p.owner_user, p.id FROM pot_runtime r JOIN pots p ON p.id=r.pot_id WHERE r.session_id=?1",
        [session_id],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )
    .optional()
    .ok()
    .flatten()
}

/// Every pot with wakes not yet settled.
fn pending(conn: &Connection) -> rusqlite::Result<Vec<(String, String)>> {
    conn.prepare(
        "SELECT DISTINCT owner_user, pot_id FROM pot_wakes WHERE state IN ('queued','delivering','delivered')",
    )?
    .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
    .collect()
}

/// Keeps the event subscription alive for the Gateway's lifetime.
struct Runtime {
    _events: std::sync::Mutex<Option<crate::events::Subscription>>,
}

/// Follow pot sessions' events, and sweep for pots after a restart or a
/// missed event.
pub fn start(app: &AppState) {
    // Listeners run under the hub's lock: only hand the session on.
    let (sender, mut sessions) = tokio::sync::mpsc::unbounded_channel::<String>();
    let subscription = app.events.subscribe_all(std::sync::Arc::new(move |event| {
        if crate::dispatch::is_watched_event(event) {
            let _ = sender.send(event.session_id.clone());
        }
    }));
    app.slots.set(std::sync::Arc::new(Runtime {
        _events: std::sync::Mutex::new(Some(subscription)),
    }));
    let follower = app.clone();
    tokio::spawn(async move {
        while let Some(session_id) = sessions.recv().await {
            let found = pot_of(&follower.db.lock(), &session_id);
            if let Some((owner, pot_id)) = found {
                kick(&follower, &owner, &pot_id);
            }
        }
    });
    let app = app.clone();
    tokio::spawn(async move {
        loop {
            let mut pots = pending(&app.db.lock()).unwrap_or_default();
            match super::autonomy::sweep(&app.db.lock()) {
                Ok(woken) => {
                    for (owner, _) in &woken {
                        app.activity_changed(owner);
                        app.causal_roots_changed(owner);
                    }
                    pots.extend(woken);
                }
                Err(error) => crate::log::warn(&format!("pot autonomy: {}", error.message)),
            }
            pots.sort();
            pots.dedup();
            for (owner, pot_id) in pots {
                if let Err(error) = check(&app, &owner, &pot_id).await {
                    crate::log::warn(&format!("pot {pot_id}: {}", error.message));
                }
            }
            tokio::time::sleep(SWEEP).await;
        }
    });
}
