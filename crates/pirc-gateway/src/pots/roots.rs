//! Causal roots (plans/pots.md, Budgets and the causal root).
//!
//! A root starts at a user message, an observed event, an autonomy review or a
//! reminder. Everything that origin causes — wakes, pot messages, work starts
//! and the model requests behind them — carries the root, its depth and its
//! budget. The depth and fan-out limits and the loop guard's thresholds come
//! from `pot_settings`; the budget starts as the initiating pot's remaining
//! money and tokens, capped by the owner's remaining limits, and is only ever
//! spent down.
//!
//! This module owns the root rows, the lineage of a wake (root and depth), the
//! root budget reservation used by admission, and the user's resume and stop.
//! The loop guard itself is [`super::guard`].

use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};

use super::budget::{self, Exhaustion, Scope, Unit, Windows};
use super::store;
use crate::error::{ApiError, ApiResult};
use crate::util::{new_id, now_ms};

/// What started a root.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Origin {
    UserMessage,
    Event,
    Review,
    Reminder,
}

impl Origin {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::UserMessage => "user_message",
            Self::Event => "event",
            Self::Review => "review",
            Self::Reminder => "reminder",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "user_message" => Some(Self::UserMessage),
            "event" => Some(Self::Event),
            "review" => Some(Self::Review),
            "reminder" => Some(Self::Reminder),
            _ => None,
        }
    }
}
crate::db::sql_text_enum!(Origin);

/// A root's lifecycle. A suspended root delivers no wakes; `resume` is the
/// user's alone. A stopped root is over and its queued wakes are failed.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum State {
    Active,
    Suspended,
    Stopped,
}

impl State {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Active => "active",
            Self::Suspended => "suspended",
            Self::Stopped => "stopped",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "active" => Some(Self::Active),
            "suspended" => Some(Self::Suspended),
            "stopped" => Some(Self::Stopped),
            _ => None,
        }
    }
}
crate::db::sql_text_enum!(State);

/// One causal root, with the counters the loop guard judges it by.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Root {
    pub id: String,
    pub origin_kind: Origin,
    pub origin_ref: String,
    /// Where the user sees it; absent goes to the initiator's direct thread.
    pub thread_id: Option<String>,
    pub initiator_pot: String,
    pub depth_limit: i64,
    pub fanout_limit: i64,
    pub budget_money_micros: i64,
    pub budget_tokens: i64,
    pub spent_money_micros: i64,
    pub spent_tokens: i64,
    pub reserved_money_micros: i64,
    pub reserved_tokens: i64,
    pub state: State,
    pub suspend_reason: Option<String>,
    pub suspended_at: Option<i64>,
    pub last_progress_at: i64,
    pub created_at: i64,
    /// Wakes and messages since the last progress, across the root.
    pub wakes_since_progress: i64,
    pub messages_since_progress: i64,
}

const SELECT: &str =
    "SELECT id,origin_kind,origin_ref,thread_id,initiator_pot,depth_limit,fanout_limit,
  budget_money_micros,budget_tokens,spent_money_micros,spent_tokens,
  reserved_money_micros,reserved_tokens,state,suspend_reason,suspended_at,
  last_progress_at,created_at,
  (SELECT count(*) FROM causal_root_events e
    WHERE e.root_id=causal_roots.id AND e.kind='wake' AND e.at>causal_roots.last_progress_at),
  (SELECT count(*) FROM causal_root_events e
    WHERE e.root_id=causal_roots.id AND e.kind='message' AND e.at>causal_roots.last_progress_at)
  FROM causal_roots";

fn row(r: &rusqlite::Row) -> rusqlite::Result<Root> {
    Ok(Root {
        id: r.get(0)?,
        origin_kind: r.get(1)?,
        origin_ref: r.get(2)?,
        thread_id: r.get(3)?,
        initiator_pot: r.get(4)?,
        depth_limit: r.get(5)?,
        fanout_limit: r.get(6)?,
        budget_money_micros: r.get(7)?,
        budget_tokens: r.get(8)?,
        spent_money_micros: r.get(9)?,
        spent_tokens: r.get(10)?,
        reserved_money_micros: r.get(11)?,
        reserved_tokens: r.get(12)?,
        state: r.get(13)?,
        suspend_reason: r.get(14)?,
        suspended_at: r.get(15)?,
        last_progress_at: r.get(16)?,
        created_at: r.get(17)?,
        wakes_since_progress: r.get(18)?,
        messages_since_progress: r.get(19)?,
    })
}

fn not_found() -> ApiError {
    ApiError::not_found("Causal root not found")
}

/// The owner's root by id.
pub fn read(conn: &Connection, owner: &str, id: &str) -> ApiResult<Root> {
    conn.query_row(
        &format!("{SELECT} WHERE id=?1 AND owner_user=?2"),
        params![id, owner],
        row,
    )
    .optional()?
    .ok_or_else(not_found)
}

/// A root by id, whether the caller names the owner or not (internal only).
pub fn find(conn: &Connection, id: &str) -> ApiResult<Option<Root>> {
    Ok(conn
        .query_row(&format!("{SELECT} WHERE id=?1"), [id], row)
        .optional()?)
}

/// The money and tokens still available under `pot` (or owner-wide) in the
/// current windows. `None` for the pot means the owner.
fn room(
    conn: &Connection,
    owner: &str,
    pot: Option<&str>,
    windows: &Windows,
    caps: &budget::Caps,
) -> ApiResult<(i64, i64)> {
    let (money_cap, tokens_cap) = match pot {
        Some(_) => (caps.pot_money, caps.pot_tokens),
        None => (caps.owner_money, caps.owner_tokens),
    };
    let money_used = budget::money_used(
        conn,
        owner,
        pot,
        windows.month_start,
        windows.month_end,
        caps.count_subscription_money,
    )? + budget::money_reserved(conn, owner, pot, windows.month_start)?;
    let tokens_used = budget::tokens_used(conn, owner, pot, windows.day_start, windows.day_end)?
        + budget::tokens_reserved(conn, owner, pot, windows.day_start)?;
    // A zero owner-wide cap means the owner set none; pot caps always apply.
    let money = if money_cap > 0 || pot.is_some() {
        money_cap.saturating_sub(money_used).max(0)
    } else {
        i64::MAX
    };
    let tokens = if tokens_cap > 0 || pot.is_some() {
        tokens_cap.saturating_sub(tokens_used).max(0)
    } else {
        i64::MAX
    };
    Ok((money, tokens))
}

/// Start a root for something `initiator` is about to handle. Its budget is
/// the initiator's remaining budget for the current windows, capped by the
/// owner's remaining limits. Root budgets use UTC windows: they are a single
/// amount for the root's lifetime, not a repeating window.
#[allow(clippy::too_many_arguments)]
pub fn start(
    conn: &Connection,
    owner: &str,
    initiator: &str,
    origin: Origin,
    origin_ref: &str,
    thread_id: Option<&str>,
) -> ApiResult<Root> {
    store::read(conn, owner, initiator)?;
    let settings = store::settings(conn, owner)?;
    let caps = budget::caps(conn, owner, initiator)?;
    let windows = budget::windows("UTC", now_ms());
    let (pot_money, pot_tokens) = room(conn, owner, Some(initiator), &windows, &caps)?;
    let (owner_money, owner_tokens) = room(conn, owner, None, &windows, &caps)?;
    let id = new_id("root");
    let now = now_ms();
    conn.execute(
        "INSERT INTO causal_roots(id,owner_user,origin_kind,origin_ref,thread_id,initiator_pot,
           depth_limit,fanout_limit,budget_money_micros,budget_tokens,state,last_progress_at,created_at)
         VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,'active',?11,?11)",
        params![
            id,
            owner,
            origin,
            origin_ref,
            thread_id,
            initiator,
            settings.loop_depth as i64,
            settings.loop_fanout as i64,
            pot_money.min(owner_money),
            pot_tokens.min(owner_tokens),
            now,
        ],
    )?;
    read(conn, owner, &id)
}

/// What a pot is handling right now: its in-flight wake, its root and depth.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Handling {
    pub wake_id: Option<String>,
    pub root: Option<String>,
    pub depth: i64,
}

/// The wake the pot is handling (`delivering` or `delivered`), with its root.
pub fn handling(conn: &Connection, owner: &str, pot_id: &str) -> ApiResult<Handling> {
    let found: Option<(String, Option<String>, i64)> = conn
        .query_row(
            "SELECT id,causal_root,depth FROM pot_wakes
             WHERE pot_id=?1 AND owner_user=?2 AND state IN ('delivering','delivered')
             ORDER BY COALESCE(delivered_at,created_at) DESC, rowid DESC LIMIT 1",
            params![pot_id, owner],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .optional()?;
    Ok(match found {
        Some((id, root, depth)) => Handling {
            wake_id: Some(id),
            root,
            depth,
        },
        None => Handling::default(),
    })
}

/// The root a pot session's or its work session's requests charge.
pub fn session_root(
    conn: &Connection,
    owner: &str,
    pot_id: &str,
    session_id: &str,
) -> ApiResult<Option<String>> {
    let own: Option<i64> = conn
        .query_row(
            "SELECT 1 FROM pot_runtime WHERE pot_id=?1 AND session_id=?2",
            params![pot_id, session_id],
            |r| r.get(0),
        )
        .optional()?;
    if own.is_some() {
        return Ok(handling(conn, owner, pot_id)?.root);
    }
    Ok(conn
        .query_row(
            "SELECT causal_root FROM pot_works
             WHERE owner_user=?1 AND pot_id=?2 AND session_id=?3",
            params![owner, pot_id, session_id],
            |r| r.get(0),
        )
        .optional()?
        .flatten())
}

/// Hold `money`/`tokens` against the root's budget. Called inside admission's
/// transaction, so concurrent children of one root cannot both pass.
pub fn hold(
    conn: &Connection,
    root_id: &str,
    reservation_id: &str,
    money: i64,
    tokens: i64,
) -> ApiResult<Option<Exhaustion>> {
    let Some((
        budget_money,
        budget_tokens,
        spent_money,
        spent_tokens,
        reserved_money,
        reserved_tokens,
    )) = conn
        .query_row(
            "SELECT budget_money_micros,budget_tokens,spent_money_micros,spent_tokens,
               reserved_money_micros,reserved_tokens FROM causal_roots WHERE id=?1",
            [root_id],
            |r| {
                Ok((
                    r.get::<_, i64>(0)?,
                    r.get::<_, i64>(1)?,
                    r.get::<_, i64>(2)?,
                    r.get::<_, i64>(3)?,
                    r.get::<_, i64>(4)?,
                    r.get::<_, i64>(5)?,
                ))
            },
        )
        .optional()?
    else {
        // The pot was deleted: nothing left to charge.
        return Ok(None);
    };
    if spent_money
        .saturating_add(reserved_money)
        .saturating_add(money)
        > budget_money
    {
        return Ok(Some(Exhaustion {
            scope: Scope::Root,
            unit: Unit::Money,
        }));
    }
    if spent_tokens
        .saturating_add(reserved_tokens)
        .saturating_add(tokens)
        > budget_tokens
    {
        return Ok(Some(Exhaustion {
            scope: Scope::Root,
            unit: Unit::Tokens,
        }));
    }
    conn.execute(
        "UPDATE causal_roots SET reserved_money_micros=reserved_money_micros+?2,
           reserved_tokens=reserved_tokens+?3 WHERE id=?1",
        params![root_id, money, tokens],
    )?;
    conn.execute(
        "INSERT OR REPLACE INTO root_reservations(reservation_id,root_id,money_micros,tokens,created_at)
         VALUES(?1,?2,?3,?4,?5)",
        params![reservation_id, root_id, money, tokens, now_ms()],
    )?;
    Ok(None)
}

/// A reservation finished: its upper bound leaves `reserved`; the actual
/// charge (or the kept upper bound when the charge is unknown) joins `spent`.
pub fn settle(
    conn: &Connection,
    reservation_id: &str,
    root_id: &str,
    held_money: i64,
    held_tokens: i64,
    spent_money: i64,
    spent_tokens: i64,
) -> rusqlite::Result<()> {
    conn.execute(
        "UPDATE causal_roots SET
           reserved_money_micros=max(0,reserved_money_micros-?2),
           reserved_tokens=max(0,reserved_tokens-?3),
           spent_money_micros=spent_money_micros+?4,
           spent_tokens=spent_tokens+?5
         WHERE id=?1",
        params![root_id, held_money, held_tokens, spent_money, spent_tokens],
    )?;
    conn.execute(
        "DELETE FROM root_reservations WHERE reservation_id=?1",
        [reservation_id],
    )?;
    Ok(())
}

/// Release a held reservation that never left (the request was refused).
pub fn release(
    conn: &Connection,
    reservation_id: &str,
    root_id: &str,
    held_money: i64,
    held_tokens: i64,
) {
    if let Err(error) = settle(conn, reservation_id, root_id, held_money, held_tokens, 0, 0) {
        crate::log::warn(&format!("root {root_id} reservation: {error}"));
    }
}

/// A held reservation whose request can no longer be alive keeps its upper
/// bound as an unknown charge, on the root too. Called inside admission's
/// transaction before a new request is considered.
pub fn expire_stale(conn: &Connection, older_than: i64) -> rusqlite::Result<()> {
    let stale: Vec<(String, String, i64, i64)> = conn
        .prepare(
            "SELECT rr.reservation_id,rr.root_id,rr.money_micros,rr.tokens
             FROM root_reservations rr JOIN budget_reservations br ON br.id=rr.reservation_id
             WHERE br.state='held' AND br.created_at<?1",
        )?
        .query_map([older_than], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))
        })?
        .collect::<Result<_, _>>()?;
    for (reservation_id, root_id, money, tokens) in stale {
        settle(
            conn,
            &reservation_id,
            &root_id,
            money,
            tokens,
            money,
            tokens,
        )?;
    }
    Ok(())
}

/// A pot work session's run finished: progress for the root that started it.
pub fn work_run_finished(conn: &Connection, session_id: &str) -> ApiResult<()> {
    let found: Option<(String, Option<String>)> = conn
        .query_row(
            "SELECT pot_id,causal_root FROM pot_works WHERE session_id=?1",
            [session_id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()?;
    if let Some((pot_id, Some(root))) = found {
        super::guard::progress(conn, &root, &pot_id, "work_run")?;
    }
    Ok(())
}

/// A backend-observed effect in the pot's current root.
pub fn progress(conn: &Connection, owner: &str, pot_id: &str, what: &str) -> ApiResult<()> {
    let handling = handling(conn, owner, pot_id)?;
    if let Some(root) = handling.root {
        super::guard::progress(conn, &root, pot_id, what)?;
    }
    Ok(())
}

/// The user resumes a suspended root: its queued wakes may deliver again.
pub fn resume(conn: &Connection, owner: &str, id: &str) -> ApiResult<Root> {
    let root = read(conn, owner, id)?;
    match root.state {
        State::Suspended => {
            let now = now_ms();
            conn.execute(
                "UPDATE causal_roots SET state='active',suspend_reason=NULL,suspended_at=NULL,
                   blocked_since=NULL,last_progress_at=?2 WHERE id=?1",
                params![id, now],
            )?;
            super::activity::log(
                conn,
                owner,
                &root.initiator_pot,
                super::activity::Entry::new(
                    super::activity::Kind::LoopGuard,
                    "The user resumed a suspended causal root",
                )
                .toward(super::activity::Counterpart::User)
                .refs(super::activity::Refs {
                    root: Some(id.to_owned()),
                    ..Default::default()
                })
                .root(Some(id)),
            )?;
            read(conn, owner, id)
        }
        State::Active => Ok(root),
        State::Stopped => Err(ApiError::new(
            409,
            "root_stopped",
            "A stopped causal root cannot be resumed",
        )),
    }
}

/// The user stops a root: it never wakes a pot again and its queued wakes fail.
pub fn stop(conn: &Connection, owner: &str, id: &str) -> ApiResult<Root> {
    let root = read(conn, owner, id)?;
    if root.state == State::Stopped {
        return Ok(root);
    }
    conn.execute(
        "UPDATE causal_roots SET state='stopped',blocked_since=NULL WHERE id=?1",
        [id],
    )?;
    let failed = conn.execute(
        "UPDATE pot_wakes SET state='failed',settled_at=?2,error='The causal root was stopped'
         WHERE causal_root=?1 AND state='queued'",
        params![id, now_ms()],
    )?;
    super::activity::log(
        conn,
        owner,
        &root.initiator_pot,
        super::activity::Entry::new(
            super::activity::Kind::LoopGuard,
            format!("The user stopped a causal root, failing {failed} queued wakes"),
        )
        .toward(super::activity::Counterpart::User)
        .refs(super::activity::Refs {
            root: Some(id.to_owned()),
            ..Default::default()
        })
        .root(Some(id)),
    )?;
    read(conn, owner, id)
}

/// The pots with wakes still queued for the root (to kick after a resume).
pub fn queued_pots(conn: &Connection, root_id: &str) -> ApiResult<Vec<String>> {
    Ok(conn
        .prepare(
            "SELECT DISTINCT pot_id FROM pot_wakes WHERE causal_root=?1 AND state='queued'
             ORDER BY pot_id",
        )?
        .query_map([root_id], |r| r.get(0))?
        .collect::<Result<_, _>>()?)
}
