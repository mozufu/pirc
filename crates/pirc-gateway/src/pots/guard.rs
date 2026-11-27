//! The loop guard (plans/pots.md, Loop guard, rules 2–5).
//!
//! Progress is a backend-observed effect: a pot work run finishes, a pot's
//! message lands in a direct or group thread the user reads, a decision is
//! answered, or an observation is noted. Between two progress points we count
//! the wakes and messages a causal root causes, per root and per pot pair, and
//! the same structured purpose repeated. Past `pot_settings.loop_no_progress_*`
//! (or after the same purpose repeats with no progress) the root is suspended:
//! it delivers no wakes, the user gets one `loop_guard` card, and the
//! suspension is logged. Rate ceilings only delay delivery first; a root that
//! stays over them is suspended too.
//!
//! Only the user can lift a suspension ([`super::roots::resume`]); nothing a pot
//! does changes a suspended root's state.

use std::collections::HashMap;

use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Value, json};

use super::activity::{self, Counterpart, Entry, Kind, Refs};
use super::roots::{self, Root, State};
use super::store;
use super::threads::{self, Card};
use crate::error::ApiResult;
use crate::util::{new_id, now_ms};

/// A root that has waited at the rate ceilings this long is suspended.
const BACKPRESSURE_SUSPEND_MS: i64 = 5 * 60_000;
const MINUTE_MS: i64 = 60_000;
const HOUR_MS: i64 = 3_600_000;

/// A wake's or message's structured purpose: what it targets, the action class
/// and the source fact. Model wording never takes part.
pub fn purpose(target: &str, action: &str, source: &str) -> Value {
    json!({ "target": target, "action": action, "source": source })
}

fn owner_of(conn: &Connection, root_id: &str) -> ApiResult<Option<String>> {
    Ok(conn
        .query_row(
            "SELECT owner_user FROM causal_roots WHERE id=?1",
            [root_id],
            |r| r.get(0),
        )
        .optional()?)
}

fn note(
    conn: &Connection,
    root_id: &str,
    pot_id: &str,
    peer_pot_id: Option<&str>,
    kind: &str,
    purpose: &Value,
) -> ApiResult<()> {
    if owner_of(conn, root_id)?.is_none() {
        // A caller-named root that does not exist (for example an old test):
        // there is nothing to guard.
        return Ok(());
    }
    conn.execute(
        "INSERT INTO causal_root_events(id,root_id,at,kind,pot_id,peer_pot_id,purpose_json)
         VALUES(?1,?2,?3,?4,?5,?6,?7)",
        params![
            new_id("crev"),
            root_id,
            now_ms(),
            kind,
            pot_id,
            peer_pot_id,
            purpose.to_string()
        ],
    )?;
    Ok(())
}

/// Record a queued wake and judge its root.
pub fn note_wake(
    conn: &Connection,
    root_id: &str,
    pot_id: &str,
    peer_pot_id: Option<&str>,
    purpose: &Value,
) -> ApiResult<()> {
    note(conn, root_id, pot_id, peer_pot_id, "wake", purpose)?;
    evaluate(conn, root_id)
}

/// Record a pot-to-pot message and judge its root.
pub fn note_message(
    conn: &Connection,
    root_id: &str,
    from_pot: &str,
    peer_pot_id: &str,
    purpose: &Value,
) -> ApiResult<()> {
    note(
        conn,
        root_id,
        from_pot,
        Some(peer_pot_id),
        "message",
        purpose,
    )?;
    evaluate(conn, root_id)
}

/// A backend-observed effect resets the root's streak. This never changes a
/// suspended or stopped root's state.
pub fn progress(conn: &Connection, root_id: &str, pot_id: &str, what: &str) -> ApiResult<()> {
    let now = now_ms();
    conn.execute(
        "UPDATE causal_roots SET last_progress_at=?2,blocked_since=NULL WHERE id=?1",
        params![root_id, now],
    )?;
    if owner_of(conn, root_id)?.is_some() {
        conn.execute(
            "INSERT INTO causal_root_events(id,root_id,at,kind,pot_id,purpose_json)
             VALUES(?1,?2,?3,'progress',?4,?5)",
            params![
                new_id("crev"),
                root_id,
                now,
                pot_id,
                json!({ "progress": what }).to_string()
            ],
        )?;
    }
    Ok(())
}

/// What the loop guard sees since the last progress.
#[derive(Default)]
struct Streak {
    wakes: i64,
    messages: i64,
    /// Unordered pair key to (wakes, messages).
    pairs: HashMap<String, (i64, i64)>,
    /// The most repeated structured purpose and how often it repeats.
    repeated: Option<(Value, i64)>,
    /// Extra wake weight from same-purpose repeats (each repeat adds one).
    repeats: i64,
}

fn pair_key(a: &str, b: Option<&str>) -> String {
    match b {
        Some(b) if b < a => format!("{b}\u{0}{a}"),
        Some(b) => format!("{a}\u{0}{b}"),
        None => a.to_owned(),
    }
}

fn streak(conn: &Connection, root_id: &str, boundary: i64) -> ApiResult<Streak> {
    let mut streak = Streak::default();
    let rows: Vec<(String, Option<String>, String, String)> = conn
        .prepare(
            "SELECT pot_id,peer_pot_id,kind,purpose_json FROM causal_root_events
             WHERE root_id=?1 AND rowid>?2 AND kind IN ('wake','message') ORDER BY rowid",
        )?
        .query_map(params![root_id, boundary], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))
        })?
        .collect::<Result<_, _>>()?;
    // Repeats are judged per receiving pot: one fact waking several pots is
    // fan-out, not a loop.
    let mut purposes: HashMap<String, (Value, i64)> = HashMap::new();
    for (pot, peer, kind, purpose) in rows {
        let pair = streak
            .pairs
            .entry(pair_key(&pot, peer.as_deref()))
            .or_default();
        match kind.as_str() {
            "wake" => {
                streak.wakes += 1;
                pair.0 += 1;
            }
            _ => {
                streak.messages += 1;
                pair.1 += 1;
            }
        }
        let purpose: Value = serde_json::from_str(&purpose).unwrap_or_else(|_| json!({}));
        let entry = purposes
            .entry(format!("{pot}\u{0}{purpose}"))
            .or_insert_with(|| (purpose, 0));
        entry.1 += 1;
    }
    for (_, (purpose, count)) in purposes {
        if count > 1 {
            streak.repeats += count - 1;
        }
        if count > 1
            && streak
                .repeated
                .as_ref()
                .is_none_or(|(_, best)| count > *best)
        {
            streak.repeated = Some((purpose, count));
        }
    }
    Ok(streak)
}

/// Judge the root after a new wake or message and suspend it when a rule is
/// over its threshold.
fn evaluate(conn: &Connection, root_id: &str) -> ApiResult<()> {
    let Some(root) = roots::find(conn, root_id)? else {
        return Ok(());
    };
    if root.state != State::Active {
        return Ok(());
    }
    let Some(owner) = owner_of(conn, root_id)? else {
        return Ok(());
    };
    let settings = store::settings(conn, &owner)?;
    let boundary = roots::streak_boundary(conn, root_id)?;
    let streak = streak(conn, root_id, boundary)?;
    let over_rate = rate_over(conn, &root, &settings)?;
    if over_rate {
        // Delivery is delayed; a root that stays over the ceilings is stopped
        // before it can flood.
        conn.execute(
            "UPDATE causal_roots SET blocked_since=COALESCE(blocked_since,?2) WHERE id=?1",
            params![root_id, now_ms()],
        )?;
        let blocked_since: Option<i64> = conn.query_row(
            "SELECT blocked_since FROM causal_roots WHERE id=?1",
            [root_id],
            |r| r.get(0),
        )?;
        if blocked_since.is_some_and(|since| now_ms() - since >= BACKPRESSURE_SUSPEND_MS) {
            let reason = "the rate ceilings stayed exceeded".to_owned();
            suspend(conn, &owner, &root, &streak, &reason)?;
        }
        return Ok(());
    }
    conn.execute(
        "UPDATE causal_roots SET blocked_since=NULL WHERE id=?1",
        [root_id],
    )?;

    let wake_limit = settings.loop_no_progress_wakes as i64;
    let message_limit = settings.loop_no_progress_messages as i64;
    let mut pair_over: Vec<(String, i64, i64)> = Vec::new();
    for (pair, (wakes, messages)) in &streak.pairs {
        if *wakes >= wake_limit || *messages >= message_limit {
            pair_over.push((pair.replace('\u{0}', " and "), *wakes, *messages));
        }
    }
    if streak.wakes >= wake_limit {
        let reason = format!("{wake_limit} wakes without progress ({} now)", streak.wakes);
        return suspend(conn, &owner, &root, &streak, &reason);
    }
    if streak.messages >= message_limit {
        let reason = format!(
            "{message_limit} messages without progress ({} now)",
            streak.messages
        );
        return suspend(conn, &owner, &root, &streak, &reason);
    }
    // Each same-purpose repeat counts as one more wake: no progress in
    // between means the repeated purpose is the loop, wording aside.
    if streak.wakes + streak.repeats >= wake_limit
        && let Some((purpose, count)) = &streak.repeated
    {
        let target = purpose["target"].as_str().unwrap_or("an unknown target");
        let action = purpose["action"].as_str().unwrap_or("an unknown action");
        let reason =
            format!("the same purpose repeated {count} times without progress: {action} {target}");
        return suspend(conn, &owner, &root, &streak, &reason);
    }
    if let Some((pair, wakes, messages)) = pair_over.first() {
        let reason = format!(
            "the pair {pair} exchanged {wakes} wakes and {messages} messages without progress"
        );
        return suspend(conn, &owner, &root, &streak, &reason);
    }
    Ok(())
}

/// Whether the root's wakes per minute or a pair's messages per minute or hour
/// are over their ceilings. It does not suspend; [`evaluate`] does when the
/// ceiling stays exceeded.
fn rate_over(conn: &Connection, root: &Root, settings: &store::Settings) -> ApiResult<bool> {
    let now = now_ms();
    if root_wakes_since(conn, &root.id, now - MINUTE_MS)? >= settings.loop_root_wakes_minute as i64
    {
        return Ok(true);
    }
    // Pair ceilings count across the root's progress points and other roots.
    let pairs: Vec<(String, String)> = conn
        .prepare(
            "SELECT DISTINCT pot_id,peer_pot_id FROM causal_root_events
             WHERE root_id=?1 AND kind='message' AND peer_pot_id IS NOT NULL AND at>=?2",
        )?
        .query_map(params![root.id, now - HOUR_MS], |r| {
            Ok((r.get(0)?, r.get(1)?))
        })?
        .collect::<Result<_, _>>()?;
    for (a, b) in pairs {
        if messages_since(conn, &a, &b, now - MINUTE_MS)?
            >= settings.loop_pair_messages_minute as i64
            || messages_since(conn, &a, &b, now - HOUR_MS)?
                >= settings.loop_pair_messages_hour as i64
        {
            return Ok(true);
        }
    }
    Ok(false)
}

fn root_wakes_since(conn: &Connection, root_id: &str, since: i64) -> ApiResult<i64> {
    Ok(conn.query_row(
        "SELECT count(*) FROM causal_root_events WHERE root_id=?1 AND kind='wake' AND at>=?2",
        params![root_id, since],
        |r| r.get(0),
    )?)
}

/// Messages from `a` to `b` (either orientation counts once) since `since`.
fn messages_since(conn: &Connection, a: &str, b: &str, since: i64) -> ApiResult<i64> {
    Ok(conn.query_row(
        "SELECT count(*) FROM causal_root_events
         WHERE kind='message' AND at>=?1
           AND ((pot_id=?2 AND peer_pot_id=?3) OR (pot_id=?3 AND peer_pot_id=?2))",
        params![since, a, b],
        |r| r.get(0),
    )?)
}

/// Whether a wake must stay queued for the rate ceilings (backpressure). A
/// suspended or stopped root never delivers.
pub fn delivery_blocked(
    conn: &Connection,
    root_id: Option<&str>,
    from_pot: Option<&str>,
    pot_id: &str,
) -> ApiResult<bool> {
    let Some(root_id) = root_id else {
        return Ok(false);
    };
    let Some(root) = roots::find(conn, root_id)? else {
        return Ok(false);
    };
    if root.state != State::Active {
        return Ok(true);
    }
    let Some(owner) = owner_of(conn, root_id)? else {
        return Ok(false);
    };
    let settings = store::settings(conn, &owner)?;
    let now = now_ms();
    if root_wakes_since(conn, root_id, now - MINUTE_MS)? >= settings.loop_root_wakes_minute as i64 {
        conn.execute(
            "UPDATE causal_roots SET blocked_since=COALESCE(blocked_since,?2) WHERE id=?1",
            params![root_id, now],
        )?;
        return Ok(true);
    }
    if let Some(from) = from_pot
        && (messages_since(conn, from, pot_id, now - MINUTE_MS)?
            >= settings.loop_pair_messages_minute as i64
            || messages_since(conn, from, pot_id, now - HOUR_MS)?
                >= settings.loop_pair_messages_hour as i64)
    {
        conn.execute(
            "UPDATE causal_roots SET blocked_since=COALESCE(blocked_since,?2) WHERE id=?1",
            params![root_id, now],
        )?;
        return Ok(true);
    }
    Ok(false)
}

/// Suspend the root once, post the summary card where it started and log it.
fn suspend(
    conn: &Connection,
    owner: &str,
    root: &Root,
    streak: &Streak,
    reason: &str,
) -> ApiResult<()> {
    let now = now_ms();
    let changed = conn.execute(
        "UPDATE causal_roots SET state='suspended',suspend_reason=?2,suspended_at=?3,
           blocked_since=NULL WHERE id=?1 AND state='active'",
        params![root.id, reason, now],
    )?;
    if changed != 1 {
        return Ok(());
    }
    let name = |id: &str| -> String {
        conn.query_row("SELECT name FROM pots WHERE id=?1", [id], |r| r.get(0))
            .unwrap_or_else(|_| id.to_owned())
    };
    let pair = streak
        .pairs
        .iter()
        .max_by_key(|(_, (wakes, messages))| wakes + messages)
        .map(|(pair, _)| {
            pair.split('\u{0}')
                .map(&name)
                .collect::<Vec<_>>()
                .join(" and ")
        })
        .unwrap_or_else(|| "the user".to_owned());
    let repeated = streak
        .repeated
        .as_ref()
        .map(|(purpose, count)| {
            let target = purpose["target"].as_str().unwrap_or("target");
            let target = target
                .strip_prefix("pot:")
                .map(&name)
                .unwrap_or_else(|| target.to_owned());
            format!(
                "{} {target} ({count} times)",
                purpose["action"].as_str().unwrap_or("action")
            )
        })
        .unwrap_or_else(|| "none".to_owned());
    let last = chrono::DateTime::from_timestamp_millis(root.last_progress_at)
        .map(|at| at.format("%Y-%m-%d %H:%M UTC").to_string())
        .unwrap_or_else(|| root.last_progress_at.to_string());
    let body = format!(
        "Loop guard: I suspended this causal root because {reason}.\n\n\
         Pots involved: {pair}. Wakes since progress: {}. Messages since progress: {}. \
         Last progress: {last}. Repeated purpose: {repeated}.\n\n\
         Its queued wakes stay queued. The user can resume the root, stop it, or pause the pots involved.",
        streak.wakes, streak.messages
    );
    threads::post_card_in(
        conn,
        owner,
        &root.initiator_pot,
        root.thread_id.as_deref(),
        &body,
        Card::LoopGuard {
            root_id: root.id.clone(),
        },
    )?;
    activity::log(
        conn,
        owner,
        &root.initiator_pot,
        Entry::new(
            Kind::LoopGuard,
            format!("Suspended a causal root: {reason}"),
        )
        .toward(Counterpart::User)
        .refs(Refs {
            root: Some(root.id.clone()),
            thread: root.thread_id.clone(),
            ..Refs::default()
        })
        .root(Some(&root.id)),
    )?;
    Ok(())
}
