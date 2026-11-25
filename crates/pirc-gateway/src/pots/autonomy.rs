//! A pot's models and autonomy (plans/pots.md, Runtime and Autonomy): the
//! model and thinking level its session runs with, the fallback report, the
//! review timer and the pot's own reminders. The review timer and due
//! reminders are driven by the pots sweep in [`super::runtime`].
//!
//! The agent never names a pot: every operation resolves it from the asking
//! session first (see [`super::ops`]).

use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Value, json};

use super::activity::{Counterpart, Entry, Kind};
use super::runtime::{self, NewWake, Source};
use super::store::{self, ModelChoice, Pot, THINKING};
use crate::error::{ApiError, ApiResult};
use crate::util::{new_id, now_ms};

/// The shortest and longest interval `set_autonomy` accepts: 1 hour to 30
/// days, or off. New pots and the API allow up to a year.
pub const MIN_INTERVAL_S: i64 = 3_600;
pub const MAX_INTERVAL_S: i64 = 30 * 24 * 3_600;
/// A pot may keep this many reminders pending.
pub const MAX_PENDING_REMINDERS: i64 = 50;
/// A reminder is at most a year ahead.
const REMINDER_MAX_MS: i64 = 365 * 24 * 3_600_000;
const MAX_NOTE: usize = 4_000;
const MAX_REASON: usize = 2_000;

/// `autonomy_interval_s`, `next_review_at`, `last_engaged_at` and
/// `active_fallback` from `pot_runtime`.
type Runtime = (Option<i64>, Option<i64>, Option<i64>, i64);
/// One active pot the review sweep looks at.
type ReviewRow = (String, String, i64, i64, Option<i64>, Option<i64>);

fn invalid(message: impl Into<String>) -> ApiError {
    ApiError::new(400, "invalid_input", message)
}

/// Trimmed text with a character limit; empty is allowed (an optional reason).
fn checked_reason(value: &str) -> ApiResult<String> {
    let value = value.trim();
    if value.chars().count() > MAX_REASON {
        return Err(invalid("reason is at most 2000 characters"));
    }
    Ok(value.to_owned())
}

fn with_reason(summary: String, reason: &str) -> String {
    if reason.is_empty() {
        summary
    } else {
        format!("{summary}: {reason}")
    }
}

/// `2 days`, `1 hour`, `90 minutes`; whole units only.
fn duration(seconds: i64) -> String {
    let (count, unit) = if seconds % 86_400 == 0 {
        (seconds / 86_400, "day")
    } else if seconds % 3_600 == 0 {
        (seconds / 3_600, "hour")
    } else {
        (seconds / 60, "minute")
    };
    if count == 1 {
        format!("1 {unit}")
    } else {
        format!("{count} {unit}s")
    }
}

fn utc(millis: i64) -> String {
    chrono::DateTime::from_timestamp_millis(millis)
        .map(|at| at.format("%Y-%m-%d %H:%M UTC").to_string())
        .unwrap_or_else(|| millis.to_string())
}

fn runtime_row(conn: &Connection, pot_id: &str) -> ApiResult<Runtime> {
    conn.query_row(
        "SELECT autonomy_interval_s,next_review_at,last_engaged_at,active_fallback
         FROM pot_runtime WHERE pot_id=?1",
        [pot_id],
        |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
    )
    .optional()?
    .ok_or_else(|| ApiError::not_found("Pot not found"))
}

/// Every model the pot runs with, main first and fallbacks in order.
fn chain(pot: &Pot) -> Vec<ModelChoice> {
    std::iter::once(pot.input.models.main.clone())
        .chain(pot.input.models.fallbacks.iter().cloned())
        .collect()
}

/// The model a wake should use: the primary, or the recorded fallback.
fn effective_model(conn: &Connection, pot: &Pot) -> ApiResult<ModelChoice> {
    let (_, _, _, active) = runtime_row(conn, &pot.id)?;
    let models = chain(pot);
    Ok(models
        .get(active.max(0) as usize)
        .cloned()
        .unwrap_or_else(|| pot.input.models.main.clone()))
}

/// Remember what the session runs with when it was last reached: a wake only
/// carries `model` and `thinking` when they differ.
pub fn wake_settings(
    conn: &Connection,
    owner: &str,
    pot_id: &str,
) -> ApiResult<Option<(ModelChoice, String)>> {
    let pot = store::read(conn, owner, pot_id)?;
    let model = effective_model(conn, &pot)?;
    let thinking = pot.input.models.thinking.clone();
    let applied: Option<(String, String, String)> = conn
        .query_row(
            "SELECT provider,model,thinking FROM pot_session_settings WHERE pot_id=?1",
            [pot_id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .optional()?;
    Ok((applied
        != Some((
            model.provider.clone(),
            model.model.clone(),
            thinking.clone(),
        )))
    .then_some((model, thinking)))
}

/// The delivery applied the model and thinking level.
pub fn mark_applied(
    conn: &Connection,
    pot_id: &str,
    model: &ModelChoice,
    thinking: &str,
) -> ApiResult<()> {
    conn.execute(
        "INSERT INTO pot_session_settings(pot_id,provider,model,thinking,updated_at)
         VALUES(?1,?2,?3,?4,?5)
         ON CONFLICT(pot_id) DO UPDATE SET provider=excluded.provider,model=excluded.model,
          thinking=excluded.thinking,updated_at=excluded.updated_at",
        params![pot_id, model.provider, model.model, thinking, now_ms()],
    )?;
    Ok(())
}

/// A freshly allocated session starts from the node's defaults again.
pub fn clear_applied(conn: &Connection, pot_id: &str) -> ApiResult<()> {
    conn.execute("DELETE FROM pot_session_settings WHERE pot_id=?1", [pot_id])?;
    Ok(())
}

/// A wake arrived for the pot: the review timer starts again from now. Every
/// wake but a review counts as engagement (plans/pots.md, Autonomy).
pub fn engage(conn: &Connection, pot_id: &str) -> ApiResult<()> {
    let now = now_ms();
    conn.execute(
        "UPDATE pot_runtime SET last_engaged_at=?2,
          next_review_at=CASE WHEN autonomy_interval_s IS NULL THEN NULL
           ELSE ?2 + autonomy_interval_s * 1000 END
         WHERE pot_id=?1",
        params![pot_id, now],
    )?;
    Ok(())
}

/// `pot.autonomy.set`: the pot changes its own review interval, `None` turns
/// reviews off. The pot's revision goes up and the change is logged.
pub fn set_autonomy(
    conn: &Connection,
    owner: &str,
    pot_id: &str,
    interval_s: Option<i64>,
    reason: &str,
) -> ApiResult<Value> {
    if let Some(interval) = interval_s
        && !(MIN_INTERVAL_S..=MAX_INTERVAL_S).contains(&interval)
    {
        return Err(invalid(
            "intervalS must be 1 hour to 30 days, or null for off",
        ));
    }
    let reason = checked_reason(reason)?;
    let tx = conn.unchecked_transaction()?;
    let pot = store::read(&tx, owner, pot_id)?;
    let (_, _, engaged, _) = runtime_row(&tx, pot_id)?;
    let next = interval_s.map(|interval| engaged.unwrap_or_else(now_ms) + interval * 1000);
    tx.execute(
        "UPDATE pot_runtime SET autonomy_interval_s=?2,next_review_at=?3 WHERE pot_id=?1",
        params![pot_id, interval_s, next],
    )?;
    tx.execute(
        "UPDATE pots SET revision=revision+1,updated_at=?2 WHERE id=?1 AND owner_user=?3",
        params![pot_id, now_ms(), owner],
    )?;
    let summary = match interval_s {
        Some(interval) => format!(
            "{} set its autonomy review interval to {}",
            pot.input.profile.name,
            duration(interval)
        ),
        None => format!("{} turned its autonomy reviews off", pot.input.profile.name),
    };
    super::activity::log(
        &tx,
        owner,
        pot_id,
        Entry::new(Kind::AutonomyChanged, with_reason(summary, &reason))
            .toward(Counterpart::System),
    )?;
    tx.commit()?;
    Ok(json!({ "intervalS": interval_s, "nextReviewAt": next }))
}

/// `pot.thinking.set`: only a pot whose thinking is automatic may choose,
/// and the level applies from its next wake.
pub fn set_thinking(
    conn: &Connection,
    owner: &str,
    pot_id: &str,
    level: &str,
    reason: &str,
) -> ApiResult<Value> {
    if !THINKING.contains(&level) {
        return Err(invalid(
            "level is one of off, minimal, low, medium, high, xhigh",
        ));
    }
    let reason = checked_reason(reason)?;
    let tx = conn.unchecked_transaction()?;
    let pot = store::read(&tx, owner, pot_id)?;
    if !pot.input.models.thinking_auto {
        return Err(ApiError::new(
            409,
            "thinking_fixed",
            "This pot's thinking level is set by the user",
        ));
    }
    tx.execute(
        "UPDATE pot_runtime SET thinking=?2 WHERE pot_id=?1",
        params![pot_id, level],
    )?;
    tx.execute(
        "UPDATE pots SET revision=revision+1,updated_at=?2 WHERE id=?1 AND owner_user=?3",
        params![pot_id, now_ms(), owner],
    )?;
    super::activity::log(
        &tx,
        owner,
        pot_id,
        Entry::new(
            Kind::ThinkingAdjust,
            with_reason(
                format!(
                    "{} set its thinking level to {level}",
                    pot.input.profile.name
                ),
                &reason,
            ),
        )
        .toward(Counterpart::System),
    )?;
    tx.commit()?;
    Ok(json!({ "level": level, "appliesFrom": "next_wake" }))
}

/// `pot.reminder.create`: a reminder for the pot's own session, at most a
/// year ahead and with at most [`MAX_PENDING_REMINDERS`] pending.
pub fn create_reminder(
    conn: &Connection,
    owner: &str,
    pot_id: &str,
    at: i64,
    note: &str,
) -> ApiResult<Value> {
    let note = note.trim();
    if note.is_empty() || note.chars().count() > MAX_NOTE {
        return Err(invalid("note must be 1 to 4000 characters"));
    }
    let now = now_ms();
    if at <= now {
        return Err(invalid("at must be in the future"));
    }
    if at - now > REMINDER_MAX_MS {
        return Err(invalid("at must be within one year"));
    }
    let tx = conn.unchecked_transaction()?;
    let pot = store::read(&tx, owner, pot_id)?;
    let pending: i64 = tx.query_row(
        "SELECT count(*) FROM pot_reminders WHERE pot_id=?1 AND state='pending'",
        [pot_id],
        |r| r.get(0),
    )?;
    if pending >= MAX_PENDING_REMINDERS {
        return Err(ApiError::new(
            409,
            "limit_reached",
            "This pot has the most reminders pending",
        ));
    }
    let id = new_id("rem");
    tx.execute(
        "INSERT INTO pot_reminders(id,pot_id,owner_user,note,due_at,created_at)
         VALUES(?1,?2,?3,?4,?5,?6)",
        params![id, pot_id, owner, note, at, now],
    )?;
    super::activity::log(
        &tx,
        owner,
        pot_id,
        Entry::new(
            Kind::ReminderSet,
            format!(
                "{} set a reminder for {}: {note}",
                pot.input.profile.name,
                utc(at)
            ),
        )
        .toward(Counterpart::System),
    )?;
    tx.commit()?;
    Ok(json!({ "id": id, "at": at, "note": note }))
}

/// `pot.fallback`: a retryable model failure before any output made the agent
/// move to the next fallback; remember which one is now active.
pub fn record_fallback(
    conn: &Connection,
    owner: &str,
    pot_id: &str,
    from: &ModelChoice,
    to: &ModelChoice,
    reason: &str,
) -> ApiResult<Value> {
    let reason = checked_reason(reason)?;
    let tx = conn.unchecked_transaction()?;
    let pot = store::read(&tx, owner, pot_id)?;
    let models = chain(&pot);
    let position = |choice: &ModelChoice| {
        models
            .iter()
            .position(|m| m.provider == choice.provider && m.model == choice.model)
    };
    let (Some(from_pos), Some(to_pos)) = (position(from), position(to)) else {
        return Err(invalid("The reported models are not this pot's"));
    };
    if to_pos <= from_pos {
        return Err(invalid("The fallback must come after the failed model"));
    }
    let (_, _, _, active) = runtime_row(&tx, pot_id)?;
    if active != to_pos as i64 {
        tx.execute(
            "UPDATE pot_runtime SET active_fallback=?2 WHERE pot_id=?1",
            params![pot_id, to_pos as i64],
        )?;
        super::activity::log(
            &tx,
            owner,
            pot_id,
            Entry::new(
                Kind::Fallback,
                with_reason(
                    format!(
                        "{} moved from {}/{} to {}/{}",
                        pot.input.profile.name, from.provider, from.model, to.provider, to.model
                    ),
                    &reason,
                ),
            )
            .toward(Counterpart::System),
        )?;
    }
    tx.commit()?;
    Ok(json!({ "activeFallback": to_pos }))
}

/// The due reviews and reminders of the sweep: create their wakes and return
/// the pots that now have one. A reminder is created even while its pot is
/// paused, so it waits like any other wake; reviews wait for the resume too.
pub fn sweep(conn: &Connection) -> ApiResult<Vec<(String, String)>> {
    let mut woken = Vec::new();
    woken.extend(due_reminders(conn)?);
    woken.extend(due_reviews(conn)?);
    Ok(woken)
}

fn due_reminders(conn: &Connection) -> ApiResult<Vec<(String, String)>> {
    let now = now_ms();
    let due: Vec<(String, String, String, String, i64)> = conn
        .prepare(
            "SELECT r.id,r.pot_id,r.owner_user,r.note,r.due_at FROM pot_reminders r
             JOIN pots p ON p.id=r.pot_id
             WHERE r.state='pending' AND r.due_at<=?1 AND p.state!='archived'
             ORDER BY r.due_at, r.rowid LIMIT 200",
        )?
        .query_map([now], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?))
        })?
        .collect::<Result<_, _>>()?;
    let mut woken = Vec::new();
    for (id, pot_id, owner, note, at) in due {
        let tx = conn.unchecked_transaction()?;
        let claimed = tx.execute(
            "UPDATE pot_reminders SET state='delivered' WHERE id=?1 AND state='pending'",
            [&id],
        )?;
        if claimed == 1 {
            let wake = runtime::enqueue(
                &tx,
                &owner,
                &pot_id,
                NewWake {
                    source: Source::Reminder,
                    thread_id: None,
                    causal_root: None,
                    content: &note,
                    details: json!({ "reminderId": id, "dueAt": at }),
                },
            )?;
            tx.execute(
                "UPDATE pot_reminders SET wake_id=?2 WHERE id=?1",
                params![id, wake],
            )?;
            tx.commit()?;
            woken.push((owner, pot_id));
        } else {
            tx.commit()?;
        }
    }
    Ok(woken)
}

fn due_reviews(conn: &Connection) -> ApiResult<Vec<(String, String)>> {
    let now = now_ms();
    let rows: Vec<ReviewRow> = conn
        .prepare(
            "SELECT p.owner_user,p.id,p.created_at,r.autonomy_interval_s,r.next_review_at,
              r.last_engaged_at
             FROM pot_runtime r JOIN pots p ON p.id=r.pot_id
             WHERE p.state='active' AND r.autonomy_interval_s IS NOT NULL
             ORDER BY p.id",
        )?
        .query_map([], |r| {
            Ok((
                r.get(0)?,
                r.get(1)?,
                r.get(2)?,
                r.get(3)?,
                r.get(4)?,
                r.get(5)?,
            ))
        })?
        .collect::<Result<_, _>>()?;
    let mut woken = Vec::new();
    for (owner, pot_id, created_at, interval, next_review_at, last_engaged_at) in rows {
        let engaged = last_engaged_at.unwrap_or(created_at);
        let by_engagement = engaged + interval * 1000;
        // A recorded time further than one interval ahead is stale (the user
        // changed the interval through the API); the engagement time wins.
        let scheduled = match next_review_at {
            Some(next) if next <= now + interval * 1000 => next.max(by_engagement),
            _ => by_engagement,
        };
        if next_review_at != Some(scheduled) {
            conn.execute(
                "UPDATE pot_runtime SET next_review_at=?2 WHERE pot_id=?1",
                params![pot_id, scheduled],
            )?;
        }
        if scheduled > now {
            continue;
        }
        let in_flight: bool = conn.query_row(
            "SELECT EXISTS(SELECT 1 FROM pot_wakes WHERE pot_id=?1 AND source='review'
              AND state IN ('queued','delivering','delivered'))",
            [&pot_id],
            |r| r.get(0),
        )?;
        if in_flight {
            continue;
        }
        let interval_s = interval;
        let at = now + interval_s * 1000;
        let tx = conn.unchecked_transaction()?;
        runtime::enqueue(
            &tx,
            &owner,
            &pot_id,
            NewWake {
                source: Source::Review,
                thread_id: None,
                causal_root: None,
                content: &format!(
                    "It has been {}. Review your responsibilities and any work you started; \
                     do anything useful that is due. You may keep, shorten or turn off these \
                     reviews with set_autonomy.",
                    duration(interval_s)
                ),
                details: json!({ "intervalS": interval_s, "lastEngagedAt": last_engaged_at }),
            },
        )?;
        tx.execute(
            "UPDATE pot_runtime SET next_review_at=?2 WHERE pot_id=?1",
            params![pot_id, at],
        )?;
        super::activity::log(
            &tx,
            &owner,
            &pot_id,
            Entry::new(Kind::Review, "Autonomy review started").toward(Counterpart::System),
        )?;
        tx.commit()?;
        woken.push((owner, pot_id));
    }
    Ok(woken)
}
