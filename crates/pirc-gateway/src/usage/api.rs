//! `GET /api/usage`: the signed-in owner's usage by day, model and actor
//! (plans/usage.md). Billed cost and the API-equivalent estimate are always
//! reported separately, so subscription usage is never summed into spending
//! unless a client chooses to show the estimate.

use axum::extract::{Extension, Query, State};
use chrono::{Duration, NaiveDate, TimeZone};
use rusqlite::{Connection, params_from_iter, types::Value as SqlValue};
use serde::Deserialize;
use serde_json::{Value, json};

use crate::app::AppState;
use crate::auth::Identity;
use crate::error::{ApiError, ApiResult};

/// The longest range one request may cover.
pub const MAX_DAYS: i64 = 400;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Range {
    from: String,
    to: String,
    tz: Option<String>,
}

fn invalid(message: &str) -> ApiError {
    ApiError::new(400, "invalid_input", message)
}

/// Each local day in `from..=to` as `(date, start_ms, end_ms)` in `zone`.
fn day_bounds(from: NaiveDate, to: NaiveDate, zone: chrono_tz::Tz) -> Vec<(String, i64, i64)> {
    let start_of = |day: NaiveDate| {
        let midnight = day.and_hms_opt(0, 0, 0).expect("midnight exists");
        // A zone that skips midnight starts the day at the first valid instant.
        zone.from_local_datetime(&midnight)
            .earliest()
            .or_else(|| {
                zone.from_local_datetime(&(midnight + Duration::hours(1)))
                    .earliest()
            })
            .map_or(i64::MAX, |time| time.timestamp_millis())
    };
    let mut out = Vec::new();
    let mut day = from;
    while day <= to {
        let next = day.succ_opt().expect("date in range");
        out.push((day.to_string(), start_of(day), start_of(next)));
        day = next;
    }
    out
}

const SUMS: &str = "COUNT(e.id),
    COALESCE(SUM(e.input_tokens),0), COALESCE(SUM(e.output_tokens),0),
    COALESCE(SUM(e.cache_read_tokens),0), COALESCE(SUM(e.cache_write_tokens),0),
    COALESCE(SUM(e.cost_micros),0),
    COALESCE(SUM(CASE WHEN e.auth_kind='subscription' THEN e.api_equiv_micros END),0),
    COALESCE(SUM(CASE WHEN e.auth_kind='subscription' THEN e.input_tokens+e.output_tokens+e.cache_read_tokens+e.cache_write_tokens END),0)";

fn sums(row: &rusqlite::Row, at: usize) -> rusqlite::Result<Value> {
    let get = |i: usize| row.get::<_, i64>(at + i);
    let (input, output, read, write) = (get(1)?, get(2)?, get(3)?, get(4)?);
    Ok(json!({
        "requests": get(0)?,
        "tokens": { "input": input, "output": output, "cacheRead": read, "cacheWrite": write,
                    "total": input + output + read + write },
        "billedMicros": get(5)?,
        "subscriptionApiEquivalentMicros": get(6)?,
        "subscriptionTokens": get(7)?,
    }))
}

#[cfg(test)]
pub fn day_bounds_for_tests(from: NaiveDate, to: NaiveDate, zone: &str) -> Vec<(String, i64, i64)> {
    day_bounds(from, to, zone.parse().unwrap())
}

pub fn report(
    conn: &Connection,
    owner: &str,
    days: &[(String, i64, i64)],
) -> rusqlite::Result<Value> {
    let (start, end) = (days[0].1, days[days.len() - 1].2);
    let values = days.iter().map(|_| "(?,?,?)").collect::<Vec<_>>().join(",");
    let mut args: Vec<SqlValue> = Vec::new();
    for (date, from, to) in days {
        args.extend([
            SqlValue::Text(date.clone()),
            SqlValue::Integer(*from),
            SqlValue::Integer(*to),
        ]);
    }
    args.push(SqlValue::Text(owner.to_owned()));
    let by_day: Vec<Value> = conn
        .prepare(&format!(
            "WITH days(date,start,stop) AS (VALUES {values})
             SELECT d.date, {SUMS} FROM days d
             LEFT JOIN usage_events e ON e.owner_user=? AND e.at>=d.start AND e.at<d.stop
             GROUP BY d.date ORDER BY d.date"
        ))?
        .query_map(params_from_iter(args), |row| {
            let mut day = sums(row, 1)?;
            day["date"] = json!(row.get::<_, String>(0)?);
            Ok(day)
        })?
        .collect::<Result<_, _>>()?;
    let grouped = |columns: &str, keys: &[&str]| -> rusqlite::Result<Vec<Value>> {
        conn.prepare(&format!(
            "SELECT {columns}, {SUMS} FROM usage_events e
             WHERE e.owner_user=?1 AND e.at>=?2 AND e.at<?3
             GROUP BY {columns} ORDER BY COALESCE(SUM(e.cost_micros),0) DESC, COUNT(e.id) DESC"
        ))?
        .query_map(rusqlite::params![owner, start, end], |row| {
            let mut entry = sums(row, keys.len())?;
            for (i, key) in keys.iter().enumerate() {
                entry[*key] = json!(row.get::<_, Option<String>>(i)?);
            }
            Ok(entry)
        })?
        .collect()
    };
    let by_model = grouped(
        "e.provider, e.model, e.auth_kind, e.plan",
        &["provider", "model", "authKind", "plan"],
    )?;
    let by_actor = grouped("e.actor_kind, e.actor_id", &["actorKind", "actorId"])?;
    let by_purpose = grouped("e.purpose", &["purpose"])?;
    let mut total = json!({});
    for key in [
        "requests",
        "billedMicros",
        "subscriptionApiEquivalentMicros",
        "subscriptionTokens",
    ] {
        total[key] = json!(
            by_day
                .iter()
                .map(|d| d[key].as_i64().unwrap_or(0))
                .sum::<i64>()
        );
    }
    let mut tokens = json!({});
    for key in ["input", "output", "cacheRead", "cacheWrite", "total"] {
        tokens[key] = json!(
            by_day
                .iter()
                .map(|d| d["tokens"][key].as_i64().unwrap_or(0))
                .sum::<i64>()
        );
    }
    total["tokens"] = tokens;
    // Consecutive days with any request, ending on the last day of the range.
    let streak = by_day
        .iter()
        .rev()
        .take_while(|day| day["requests"].as_i64().unwrap_or(0) > 0)
        .count();
    Ok(json!({
        "days": by_day,
        "byModel": by_model,
        "byActor": by_actor,
        "byPurpose": by_purpose,
        "total": total,
        "streakDays": streak,
        "pricingRevision": pirc_providers::catalog_version(),
    }))
}

pub async fn get(
    State(app): State<AppState>,
    Extension(identity): Extension<Identity>,
    Query(range): Query<Range>,
) -> ApiResult<axum::Json<Value>> {
    let parse = |text: &str| {
        NaiveDate::parse_from_str(text, "%Y-%m-%d").map_err(|_| invalid("Dates are YYYY-MM-DD"))
    };
    let (from, to) = (parse(&range.from)?, parse(&range.to)?);
    if to < from || (to - from).num_days() >= MAX_DAYS {
        return Err(invalid("The range must be 1 to 400 days, from before to"));
    }
    let zone_name = range.tz.unwrap_or_else(|| app.config.timezone.clone());
    let zone: chrono_tz::Tz = zone_name
        .parse()
        .map_err(|_| invalid("Unknown time zone"))?;
    let days = day_bounds(from, to, zone);
    let mut out = report(&app.db.lock(), &identity.user, &days)?;
    out["timezone"] = json!(zone_name);
    Ok(axum::Json(out))
}
