//! Pot budgets (plans/pots.md, Budgets and the causal root; plans/usage.md,
//! Budget admission).
//!
//! Money is capped per calendar month and tokens per calendar day, per pot and
//! owner-wide. Admission holds an upper bound as a reservation in
//! `budget_reservations` before a model request runs, so two requests near a
//! cap cannot both pass. This module owns the windows, the sums the reservation
//! checks, exhaustion and a pot's budget requests to the user.

use chrono::{Datelike, Duration as ChronoDuration, NaiveDate, TimeZone};
use chrono_tz::Tz;
use rusqlite::{Connection, OptionalExtension, Row, TransactionBehavior, params};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::activity::{self, Counterpart, Entry, Kind, Refs};
use super::runtime::{self, NewWake, Source};
use super::store::{self, PotState};
use super::threads;
use crate::app::AppState;
use crate::error::{ApiError, ApiResult};
use crate::util::{new_id, now_ms};

/// A request body or answer is bounded like its activity row.
const MAX_REASON: usize = 2000;

/// The current calendar windows, in epoch milliseconds.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Windows {
    pub day_start: i64,
    pub day_end: i64,
    pub month_start: i64,
    pub month_end: i64,
}

/// The first instant of `day` in `zone`; a skipped midnight starts at the
/// first valid instant after it.
fn start_of(zone: Tz, day: NaiveDate) -> i64 {
    let midnight = day.and_hms_opt(0, 0, 0).expect("midnight exists");
    zone.from_local_datetime(&midnight)
        .earliest()
        .or_else(|| {
            zone.from_local_datetime(&(midnight + ChronoDuration::hours(1)))
                .earliest()
        })
        .map_or(i64::MAX, |time| time.timestamp_millis())
}

/// The day and month `now` falls in, in the Gateway's zone.
pub fn windows(zone: &str, now: i64) -> Windows {
    let zone: Tz = zone.parse().unwrap_or(chrono_tz::UTC);
    let local = chrono::Utc
        .timestamp_millis_opt(now)
        .single()
        .unwrap_or_else(|| chrono::Utc.timestamp_millis_opt(0).unwrap())
        .with_timezone(&zone);
    let day = local.date_naive();
    let next_day = day.succ_opt().unwrap_or(day);
    let month = NaiveDate::from_ymd_opt(day.year(), day.month(), 1).unwrap_or(day);
    let next_month = if day.month() == 12 {
        NaiveDate::from_ymd_opt(day.year() + 1, 1, 1)
    } else {
        NaiveDate::from_ymd_opt(day.year(), day.month() + 1, 1)
    }
    .unwrap_or(month);
    Windows {
        day_start: start_of(zone, day),
        day_end: start_of(zone, next_day),
        month_start: start_of(zone, month),
        month_end: start_of(zone, next_month),
    }
}

/// Which cap a request would exceed.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Scope {
    Pot,
    Owner,
    /// The causal root this request belongs to.
    Root,
}

impl Scope {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Pot => "pot",
            Self::Owner => "owner",
            Self::Root => "root",
        }
    }
}

/// Which unit of a cap a request would exceed.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Unit {
    Tokens,
    Money,
}

impl Unit {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Tokens => "tokens",
            Self::Money => "money",
        }
    }
}

/// A cap that leaves no room for another request.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Exhaustion {
    pub scope: Scope,
    pub unit: Unit,
}

/// The owner's caps for one pot.
pub struct Caps {
    /// `None`: the pot has no limit for this unit.
    pub pot_money: Option<i64>,
    pub pot_tokens: Option<i64>,
    pub owner_money: i64,
    pub owner_tokens: i64,
    pub count_subscription_money: bool,
}

pub fn caps(conn: &Connection, owner: &str, pot_id: &str) -> ApiResult<Caps> {
    let pot = store::read(conn, owner, pot_id)?;
    let settings = store::settings(conn, owner)?;
    Ok(Caps {
        pot_money: pot
            .input
            .permissions
            .budget_money_month_micros
            .map(|v| v as i64),
        pot_tokens: pot.input.permissions.budget_tokens_day.map(|v| v as i64),
        owner_money: settings.cap_money_month_micros as i64,
        owner_tokens: settings.cap_tokens_day as i64,
        count_subscription_money: settings.count_subscription_money,
    })
}

/// Money charged in `[from, to)`: billed API cost, plus the API-equivalent
/// estimate for subscriptions only when the owner enabled that accounting.
pub fn money_used(
    conn: &Connection,
    owner: &str,
    pot: Option<&str>,
    from: i64,
    to: i64,
    count_subscription_money: bool,
) -> rusqlite::Result<i64> {
    let sql = "SELECT COALESCE(SUM(CASE
                 WHEN auth_kind='api_key' THEN COALESCE(cost_micros,0)
                 WHEN auth_kind='subscription' AND ?4 THEN COALESCE(api_equiv_micros,0)
                 ELSE 0 END),0)
               FROM usage_events
               WHERE owner_user=?1 AND actor_kind='pot' AND at>=?2 AND at<?3";
    match pot {
        Some(pot) => conn.query_row(
            &format!("{sql} AND actor_id=?5"),
            params![owner, from, to, count_subscription_money, pot],
            |r| r.get(0),
        ),
        None => conn.query_row(
            sql,
            params![owner, from, to, count_subscription_money],
            |r| r.get(0),
        ),
    }
}

/// Every token an actor used in `[from, to)`, however it was paid for.
pub fn tokens_used(
    conn: &Connection,
    owner: &str,
    pot: Option<&str>,
    from: i64,
    to: i64,
) -> rusqlite::Result<i64> {
    let sql =
        "SELECT COALESCE(SUM(input_tokens+output_tokens+cache_read_tokens+cache_write_tokens),0)
               FROM usage_events
               WHERE owner_user=?1 AND actor_kind='pot' AND at>=?2 AND at<?3";
    match pot {
        Some(pot) => conn.query_row(
            &format!("{sql} AND actor_id=?4"),
            params![owner, from, to, pot],
            |r| r.get(0),
        ),
        None => conn.query_row(sql, params![owner, from, to], |r| r.get(0)),
    }
}

/// Money still held or charged without a usage row, for one window.
pub fn money_reserved(
    conn: &Connection,
    owner: &str,
    pot: Option<&str>,
    month_start: i64,
) -> rusqlite::Result<i64> {
    let sql = "SELECT COALESCE(SUM(CASE WHEN state='charged'
                   THEN COALESCE(actual_money_micros,money_micros) ELSE money_micros END),0)
               FROM budget_reservations
               WHERE owner_user=?1 AND month_start=?2 AND state IN ('held','charged')";
    match pot {
        Some(pot) => conn.query_row(
            &format!("{sql} AND pot_id=?3"),
            params![owner, month_start, pot],
            |r| r.get(0),
        ),
        None => conn.query_row(sql, params![owner, month_start], |r| r.get(0)),
    }
}

/// Tokens still held or charged without a usage row, for one window.
pub fn tokens_reserved(
    conn: &Connection,
    owner: &str,
    pot: Option<&str>,
    day_start: i64,
) -> rusqlite::Result<i64> {
    let sql = "SELECT COALESCE(SUM(CASE WHEN state='charged'
                   THEN COALESCE(actual_tokens,tokens) ELSE tokens END),0)
               FROM budget_reservations
               WHERE owner_user=?1 AND day_start=?2 AND state IN ('held','charged')";
    match pot {
        Some(pot) => conn.query_row(
            &format!("{sql} AND pot_id=?3"),
            params![owner, day_start, pot],
            |r| r.get(0),
        ),
        None => conn.query_row(sql, params![owner, day_start], |r| r.get(0)),
    }
}

/// The first cap `used + reserved` has reached for this pot or its owner.
/// A zero cap is exhausted from the start: no setting means unlimited.
pub fn exhaustion(
    conn: &Connection,
    owner: &str,
    pot_id: &str,
    windows: &Windows,
) -> ApiResult<Option<Exhaustion>> {
    let caps = caps(conn, owner, pot_id)?;
    let pot_money = money_used(
        conn,
        owner,
        Some(pot_id),
        windows.month_start,
        windows.month_end,
        caps.count_subscription_money,
    )? + money_reserved(conn, owner, Some(pot_id), windows.month_start)?;
    if caps.pot_money.is_some_and(|cap| pot_money >= cap) {
        return Ok(Some(Exhaustion {
            scope: Scope::Pot,
            unit: Unit::Money,
        }));
    }
    let pot_tokens = tokens_used(
        conn,
        owner,
        Some(pot_id),
        windows.day_start,
        windows.day_end,
    )? + tokens_reserved(conn, owner, Some(pot_id), windows.day_start)?;
    if caps.pot_tokens.is_some_and(|cap| pot_tokens >= cap) {
        return Ok(Some(Exhaustion {
            scope: Scope::Pot,
            unit: Unit::Tokens,
        }));
    }
    // An owner-wide cap of zero means the owner set none; per-pot caps always
    // apply (a pot's zero budget means it may not spend).
    if caps.owner_money > 0 {
        let owner_money = money_used(
            conn,
            owner,
            None,
            windows.month_start,
            windows.month_end,
            caps.count_subscription_money,
        )? + money_reserved(conn, owner, None, windows.month_start)?;
        if owner_money >= caps.owner_money {
            return Ok(Some(Exhaustion {
                scope: Scope::Owner,
                unit: Unit::Money,
            }));
        }
    }
    if caps.owner_tokens > 0 {
        let owner_tokens = tokens_used(conn, owner, None, windows.day_start, windows.day_end)?
            + tokens_reserved(conn, owner, None, windows.day_start)?;
        if owner_tokens >= caps.owner_tokens {
            return Ok(Some(Exhaustion {
                scope: Scope::Owner,
                unit: Unit::Tokens,
            }));
        }
    }
    Ok(None)
}

/// Record an exhaustion once per cap and window, not once per wake.
pub fn note_exhausted(
    conn: &Connection,
    owner: &str,
    pot_id: &str,
    exhaustion: Exhaustion,
    window_start: i64,
) -> ApiResult<bool> {
    let key = format!(
        "{}:{}:{}",
        exhaustion.scope.as_str(),
        exhaustion.unit.as_str(),
        window_start
    );
    let seen: Option<i64> = conn
        .query_row(
            "SELECT 1 FROM pot_activity
             WHERE owner_user=?1 AND pot_id=?2 AND kind='budget_exhausted'
               AND json_extract(refs_json,'$.budget')=?3 LIMIT 1",
            params![owner, pot_id, key],
            |r| r.get(0),
        )
        .optional()?;
    if seen.is_some() {
        return Ok(false);
    }
    let window = if exhaustion.unit == Unit::Money {
        "this month"
    } else {
        "today"
    };
    activity::log(
        conn,
        owner,
        pot_id,
        Entry::new(
            Kind::BudgetExhausted,
            format!(
                "{} {} budget exhausted {window}",
                match exhaustion.scope {
                    Scope::Pot => "Its",
                    Scope::Owner => "The owner's",
                    Scope::Root => "The causal root's",
                },
                exhaustion.unit.as_str()
            ),
        )
        .toward(Counterpart::User)
        .refs(Refs {
            budget: Some(key),
            ..Refs::default()
        }),
    )?;
    Ok(true)
}

/// Whether a wake must wait for budget. Called from `runtime::claim`, so the
/// exhausted pot's queued (and future) wakes stay queued. It also records the
/// exhaustion once per window.
pub fn wake_blocked(conn: &Connection, owner: &str, pot_id: &str, zone: &str) -> ApiResult<bool> {
    let windows = windows(zone, now_ms());
    let Some(exhaustion) = exhaustion(conn, owner, pot_id, &windows)? else {
        return Ok(false);
    };
    // Owner-wide exhaustion follows `on_exhausted`: `pause_all` stops every
    // pot's wakes; `ask` lets a wake run, be refused by admission and tell the
    // user, instead of silently queueing forever.
    if exhaustion.scope == Scope::Owner && store::settings(conn, owner)?.on_exhausted != "pause_all"
    {
        return Ok(false);
    }
    let start = if exhaustion.unit == Unit::Money {
        windows.month_start
    } else {
        windows.day_start
    };
    note_exhausted(conn, owner, pot_id, exhaustion, start)?;
    Ok(true)
}

fn used(
    conn: &Connection,
    owner: &str,
    pot: Option<&str>,
    windows: &Windows,
) -> ApiResult<(i64, i64)> {
    let count = store::settings(conn, owner)?.count_subscription_money;
    Ok((
        money_used(
            conn,
            owner,
            pot,
            windows.month_start,
            windows.month_end,
            count,
        )?,
        tokens_used(conn, owner, pot, windows.day_start, windows.day_end)?,
    ))
}

fn remaining(cap: Option<i64>, used: i64, reserved: i64) -> Option<i64> {
    cap.map(|cap| cap.saturating_sub(used).saturating_sub(reserved).max(0))
}

/// `pot.budget.status`: the pot's remaining money and tokens for the current
/// windows, its reservations, and the owner-wide remainder.
pub fn status(conn: &Connection, owner: &str, pot_id: &str, windows: Windows) -> ApiResult<Value> {
    let caps = caps(conn, owner, pot_id)?;
    let (pot_money_used, pot_tokens_used) = used(conn, owner, Some(pot_id), &windows)?;
    let pot_money_reserved = money_reserved(conn, owner, Some(pot_id), windows.month_start)?;
    let pot_tokens_reserved = tokens_reserved(conn, owner, Some(pot_id), windows.day_start)?;
    let (owner_money_used, owner_tokens_used) = used(conn, owner, None, &windows)?;
    let owner_money_reserved = money_reserved(conn, owner, None, windows.month_start)?;
    let owner_tokens_reserved = tokens_reserved(conn, owner, None, windows.day_start)?;
    Ok(json!({
        "money": {
            "capMicros": caps.pot_money,
            "usedMicros": pot_money_used,
            "reservedMicros": pot_money_reserved,
            "remainingMicros": remaining(caps.pot_money, pot_money_used, pot_money_reserved),
        },
        "tokens": {
            "cap": caps.pot_tokens,
            "used": pot_tokens_used,
            "reserved": pot_tokens_reserved,
            "remaining": remaining(caps.pot_tokens, pot_tokens_used, pot_tokens_reserved),
        },
        "owner": {
            "money": {
                "capMicros": caps.owner_money,
                "usedMicros": owner_money_used,
                "reservedMicros": owner_money_reserved,
                "remainingMicros": remaining((caps.owner_money > 0).then_some(caps.owner_money), owner_money_used, owner_money_reserved),
                "unlimited": caps.owner_money == 0,
            },
            "tokens": {
                "cap": caps.owner_tokens,
                "used": owner_tokens_used,
                "reserved": owner_tokens_reserved,
                "remaining": remaining((caps.owner_tokens > 0).then_some(caps.owner_tokens), owner_tokens_used, owner_tokens_reserved),
                "unlimited": caps.owner_tokens == 0,
            },
            "countSubscriptionMoney": caps.count_subscription_money,
        },
        "windows": {
            "monthStart": windows.month_start,
            "monthEnd": windows.month_end,
            "dayStart": windows.day_start,
            "dayEnd": windows.day_end,
        },
    }))
}

/// The window a budget request asks for.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Window {
    Month,
    Day,
}

impl Window {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Month => "month",
            Self::Day => "day",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "month" => Some(Self::Month),
            "day" => Some(Self::Day),
            _ => None,
        }
    }
}
crate::db::sql_text_enum!(Window);

/// What a pot asks for: money for the current month or tokens for today.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RequestInput {
    #[serde(default)]
    pub amount_micros: Option<u64>,
    #[serde(default)]
    pub tokens: Option<u64>,
    pub window: Window,
    #[serde(default)]
    pub reason: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RequestState {
    Pending,
    Approved,
    ApprovedAmount,
    Denied,
}

impl RequestState {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Pending => "pending",
            Self::Approved => "approved",
            Self::ApprovedAmount => "approved_amount",
            Self::Denied => "denied",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "pending" => Some(Self::Pending),
            "approved" => Some(Self::Approved),
            "approved_amount" => Some(Self::ApprovedAmount),
            "denied" => Some(Self::Denied),
            _ => None,
        }
    }
}
crate::db::sql_text_enum!(RequestState);

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BudgetRequest {
    pub id: String,
    pub pot_id: String,
    pub window: Window,
    pub amount_micros: Option<u64>,
    pub tokens: Option<u64>,
    pub reason: String,
    pub state: RequestState,
    pub approved_amount_micros: Option<u64>,
    pub approved_tokens: Option<u64>,
    pub created_at: i64,
    pub answered_at: Option<i64>,
}

const SELECT: &str = "SELECT id,pot_id,window,amount_micros,tokens,reason,state,
  approved_amount_micros,approved_tokens,created_at,answered_at FROM budget_requests";

fn row(row: &Row) -> rusqlite::Result<BudgetRequest> {
    Ok(BudgetRequest {
        id: row.get(0)?,
        pot_id: row.get(1)?,
        window: row.get(2)?,
        amount_micros: row.get::<_, Option<i64>>(3)?.map(|v| v as u64),
        tokens: row.get::<_, Option<i64>>(4)?.map(|v| v as u64),
        reason: row.get(5)?,
        state: row.get(6)?,
        approved_amount_micros: row.get::<_, Option<i64>>(7)?.map(|v| v as u64),
        approved_tokens: row.get::<_, Option<i64>>(8)?.map(|v| v as u64),
        created_at: row.get(9)?,
        answered_at: row.get(10)?,
    })
}

fn not_found() -> ApiError {
    ApiError::not_found("Budget request not found")
}

fn invalid(message: &str) -> ApiError {
    ApiError::new(400, "invalid_input", message)
}

fn find(conn: &Connection, owner: &str, id: &str) -> ApiResult<Option<BudgetRequest>> {
    Ok(conn
        .query_row(
            &format!("{SELECT} WHERE id=?1 AND owner_user=?2"),
            params![id, owner],
            row,
        )
        .optional()?)
}

pub fn read(conn: &Connection, owner: &str, id: &str) -> ApiResult<BudgetRequest> {
    find(conn, owner, id)?.ok_or_else(not_found)
}

/// The owner's requests, newest first, optionally only one state.
pub fn list(
    conn: &Connection,
    owner: &str,
    state: Option<RequestState>,
) -> ApiResult<Vec<BudgetRequest>> {
    let query = match state {
        Some(_) => {
            format!("{SELECT} WHERE owner_user=?1 AND state=?2 ORDER BY created_at DESC,rowid DESC")
        }
        None => format!("{SELECT} WHERE owner_user=?1 ORDER BY created_at DESC,rowid DESC"),
    };
    let mut statement = conn.prepare(&query)?;
    let requests = match state {
        Some(state) => statement
            .query_map(params![owner, state], row)?
            .collect::<Result<_, _>>()?,
        None => statement
            .query_map([owner], row)?
            .collect::<Result<_, _>>()?,
    };
    Ok(requests)
}

fn money(value: u64, field: &str) -> ApiResult<i64> {
    i64::try_from(value).map_err(|_| invalid(&format!("{field} is too large")))
}

impl RequestInput {
    fn normalize(self) -> ApiResult<Self> {
        let reason = self.reason.trim();
        if reason.chars().count() > MAX_REASON {
            return Err(invalid("reason must be at most 2000 characters"));
        }
        let (amount_micros, tokens) = match (self.amount_micros, self.tokens) {
            (Some(amount), None) if self.window == Window::Month && amount > 0 => {
                (Some(money(amount, "amountMicros")? as u64), None)
            }
            (None, Some(tokens)) if self.window == Window::Day && tokens > 0 => {
                (None, Some(money(tokens, "tokens")? as u64))
            }
            (Some(_), None) => {
                return Err(invalid("A month request asks in amountMicros"));
            }
            (None, Some(_)) => return Err(invalid("A day request asks in tokens")),
            _ => return Err(invalid("Give exactly one of amountMicros or tokens")),
        };
        Ok(Self {
            amount_micros,
            tokens,
            window: self.window,
            reason: reason.to_owned(),
        })
    }

    fn describe(&self) -> String {
        match (self.amount_micros, self.tokens) {
            (Some(amount), _) => format!("{amount} more micro-dollars this month"),
            (_, Some(tokens)) => format!("{tokens} more tokens today"),
            _ => unreachable!("normalize requires one amount"),
        }
    }
}

/// Whether the user wrote to the pot's direct thread after `since`.
fn user_wrote_since(conn: &Connection, owner: &str, pot_id: &str, since: i64) -> ApiResult<bool> {
    Ok(conn
        .query_row(
            "SELECT 1 FROM messages m JOIN threads t ON t.id=m.thread_id
             WHERE t.owner_user=?1 AND t.kind='direct' AND t.pot_a=?2
               AND m.author_kind='user' AND m.created_at>?3 LIMIT 1",
            params![owner, pot_id, since - 1],
            |r| r.get::<_, i64>(0),
        )
        .optional()?
        .is_some())
}

/// A pot asks the user for more budget. One request may be open per pot, and a
/// denial blocks that window until the user writes in the pot's direct thread.
pub fn request(
    conn: &mut Connection,
    owner: &str,
    pot_id: &str,
    input: RequestInput,
) -> ApiResult<BudgetRequest> {
    let pot = store::read(conn, owner, pot_id)?;
    if pot.state == PotState::Archived {
        return Err(ApiError::new(
            409,
            "pot_archived",
            "Restore the pot before asking for budget",
        ));
    }
    let input = input.normalize()?;
    let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let open: Option<String> = tx
        .query_row(
            "SELECT id FROM budget_requests WHERE pot_id=?1 AND state='pending'",
            [pot_id],
            |r| r.get(0),
        )
        .optional()?;
    if open.is_some() {
        return Err(ApiError::new(
            409,
            "budget_request_open",
            "This pot already has an open budget request",
        ));
    }
    let denied: Option<i64> = tx
        .query_row(
            "SELECT answered_at FROM budget_requests
             WHERE pot_id=?1 AND window=?2 AND state='denied' AND answered_at IS NOT NULL
             ORDER BY answered_at DESC LIMIT 1",
            params![pot_id, input.window],
            |r| r.get(0),
        )
        .optional()?;
    if let Some(denied_at) = denied
        && !user_wrote_since(&tx, owner, pot_id, denied_at)?
    {
        return Err(ApiError::new(
            409,
            "budget_request_denied",
            "The user denied this window; wait for a new message from them before asking again",
        ));
    }
    let id = new_id("budget");
    let handling = super::roots::handling(&tx, owner, pot_id)?;
    tx.execute(
        "INSERT INTO budget_requests(id,owner_user,pot_id,window,amount_micros,tokens,reason,
           causal_root,depth,state,created_at)
         VALUES(?1,?2,?3,?4,?5,?6,?7,?9,?10,'pending',?8)",
        params![
            id,
            owner,
            pot_id,
            input.window,
            input.amount_micros.map(|v| v as i64),
            input.tokens.map(|v| v as i64),
            input.reason,
            now_ms(),
            handling.root,
            handling.depth,
        ],
    )?;
    let ask = input.describe();
    let body = match input.reason.as_str() {
        "" => format!("Budget request: {ask}."),
        reason => format!("Budget request: {ask}.\n\nReason: {reason}"),
    };
    threads::post_card(
        &tx,
        owner,
        pot_id,
        &body,
        threads::Card::BudgetRequest {
            request_id: id.clone(),
        },
    )?;
    activity::log(
        &tx,
        owner,
        pot_id,
        Entry::new(Kind::BudgetRequest, format!("Asked the user for {ask}"))
            .toward(Counterpart::User)
            .refs(Refs {
                budget: Some(id.clone()),
                ..Refs::default()
            }),
    )?;
    tx.commit()?;
    read(conn, owner, &id)
}

/// The user's answer: approve the ask, approve a different amount, or deny.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Decision {
    Approve,
    ApproveAmount,
    Deny,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Answer {
    pub answer: Decision,
    #[serde(default)]
    pub amount: Option<u64>,
}

fn already_answered() -> ApiError {
    ApiError::new(
        409,
        "already_answered",
        "This budget request was already answered",
    )
}

/// Answer a pending request. Approval raises the pot's cap for the stated
/// window only (by the asked amount or the user's amount); every answer wakes
/// the pot and is posted as a system message in its direct thread.
pub fn answer(
    conn: &mut Connection,
    owner: &str,
    id: &str,
    answer: Answer,
) -> ApiResult<BudgetRequest> {
    let amount = match (answer.answer, answer.amount) {
        (Decision::ApproveAmount, Some(amount)) if amount > 0 => {
            Some(money(amount, "amount")? as u64)
        }
        (Decision::ApproveAmount, Some(_)) => {
            return Err(invalid("amount must be greater than zero"));
        }
        (Decision::ApproveAmount, None) => {
            return Err(invalid("approve_amount needs an amount"));
        }
        (Decision::Deny, Some(_)) => return Err(invalid("A deny answer takes no amount")),
        (_, None) => None,
        (Decision::Approve, Some(_)) => {
            return Err(invalid("Only approve_amount takes an amount"));
        }
    };
    let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let current = read(&tx, owner, id)?;
    if current.state != RequestState::Pending {
        return Err(already_answered());
    }
    let (state, approved_micros, approved_tokens) = match answer.answer {
        Decision::Deny => (RequestState::Denied, None, None),
        Decision::Approve | Decision::ApproveAmount => {
            let (micros, tokens) = match current.window {
                Window::Month => (
                    Some(amount.unwrap_or_else(|| current.amount_micros.unwrap_or(0))),
                    None,
                ),
                Window::Day => (
                    None,
                    Some(amount.unwrap_or_else(|| current.tokens.unwrap_or(0))),
                ),
            };
            let state = if answer.answer == Decision::ApproveAmount {
                RequestState::ApprovedAmount
            } else {
                RequestState::Approved
            };
            (state, micros, tokens)
        }
    };
    let changed = tx.execute(
        "UPDATE budget_requests SET state=?1,approved_amount_micros=?2,approved_tokens=?3,answered_at=?4
         WHERE id=?5 AND owner_user=?6 AND state='pending'",
        params![
            state,
            approved_micros.map(|v| v as i64),
            approved_tokens.map(|v| v as i64),
            now_ms(),
            id,
            owner,
        ],
    )?;
    if changed != 1 {
        return Err(already_answered());
    }
    let request = read(&tx, owner, id)?;
    if approved_micros.is_some() || approved_tokens.is_some() {
        let column = match request.window {
            Window::Month => "budget_money_month_micros",
            Window::Day => "budget_tokens_day",
        };
        let amount = approved_micros.or(approved_tokens).unwrap_or(0) as i64;
        tx.execute(
            &format!("UPDATE pot_permissions SET {column}={column}+?1 WHERE pot_id=?2"),
            params![amount, request.pot_id],
        )?;
        tx.execute(
            "UPDATE pots SET revision=revision+1,updated_at=?1 WHERE id=?2 AND owner_user=?3",
            params![now_ms(), request.pot_id, owner],
        )?;
    }
    let grant = match (request.window, approved_micros, approved_tokens) {
        (Window::Month, Some(micros), _) => {
            format!("{micros} more micro-dollars this month")
        }
        (Window::Day, _, Some(tokens)) => format!("{tokens} more tokens today"),
        _ => "no increase".to_owned(),
    };
    let (system, wake) = if request.state == RequestState::Denied {
        (
            "Budget request denied.".to_owned(),
            "The user denied your budget request for this window. You cannot ask again for it until the user writes to you in your direct thread.".to_owned(),
        )
    } else {
        (
            format!("Budget request approved: {grant}."),
            format!(
                "The user approved your budget request: {grant}. Your cap was raised for that window only."
            ),
        )
    };
    threads::post_system(&tx, owner, &request.pot_id, &system)?;
    // The answer continues the root of the wake that asked, at its depth.
    let (root, depth): (Option<String>, i64) = tx.query_row(
        "SELECT causal_root,depth FROM budget_requests WHERE id=?1",
        [id],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )?;
    if let Some(root_id) = &root {
        super::guard::progress(&tx, root_id, &request.pot_id, "budget_answered")?;
    }
    let thread = threads::direct(&tx, owner, &request.pot_id)?;
    let woken = runtime::enqueue(
        &tx,
        owner,
        &request.pot_id,
        NewWake {
            source: Source::Budget,
            thread_id: Some(&thread.id),
            causal_root: root.as_deref(),
            depth,
            from_pot: None,
            caused_by: None,
            purpose: super::guard::purpose(
                &format!("pot:{}", request.pot_id),
                "budget_answer",
                &request.id,
            ),
            content: &wake,
            details: json!({
                "budgetRequestId": request.id,
                "potId": request.pot_id,
                "state": request.state,
                "window": request.window,
                "amountMicros": approved_micros,
                "tokens": approved_tokens,
            }),
        },
    );
    // A stopped root takes nothing more; the answer itself still stands.
    runtime::unless_stopped(woken)?;
    activity::log(
        &tx,
        owner,
        &request.pot_id,
        Entry::new(
            Kind::BudgetRequest,
            match request.state {
                RequestState::Denied => "The user denied the budget request".to_owned(),
                _ => format!("The user approved {grant}"),
            },
        )
        .toward(Counterpart::User)
        .refs(Refs {
            budget: Some(request.id.clone()),
            ..Refs::default()
        }),
    )?;
    tx.commit()?;
    Ok(request)
}

/// `pot.budget.request` with the client hints a store write cannot send.
pub fn request_with_hints(
    app: &AppState,
    owner: &str,
    pot_id: &str,
    input: RequestInput,
) -> ApiResult<BudgetRequest> {
    let request = request(&mut app.db.lock(), owner, pot_id, input)?;
    app.budget_requests_changed(owner);
    app.threads_changed(owner);
    app.activity_changed(owner);
    Ok(request)
}

/// The pot's current status, for the agent operation.
pub fn status_for(conn: &Connection, owner: &str, pot_id: &str, zone: &str) -> ApiResult<Value> {
    status(conn, owner, pot_id, windows(zone, now_ms()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn windows_follow_the_zone_and_calendar_boundaries() {
        // 2026-11-25 01:30 UTC is 2026-11-25 09:30 in Taipei.
        let now = chrono::Utc
            .with_ymd_and_hms(2026, 11, 25, 1, 30, 0)
            .unwrap()
            .timestamp_millis();
        let taipei = windows("Asia/Taipei", now);
        assert_eq!(
            taipei.day_start,
            chrono::Utc
                .with_ymd_and_hms(2026, 11, 24, 16, 0, 0)
                .unwrap()
                .timestamp_millis()
        );
        assert_eq!(taipei.day_end - taipei.day_start, 86_400_000);
        // New York's 2026-03-08 is 23 hours long.
        let new_york = windows("America/New_York", 1_772_949_600_000);
        assert_eq!(new_york.day_end - new_york.day_start, 23 * 3_600_000);
        assert!(new_york.month_start < new_york.day_start);
    }
}
