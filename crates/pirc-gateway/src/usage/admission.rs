//! Budget admission for pot model requests (plans/usage.md, Budget admission).
//!
//! Before a request from a pot's session runs, [`begin`] holds an upper bound
//! from the prompt size, the request's output limit and the accepted pricing
//! revision in `budget_reservations`. The check and the insert share one
//! `BEGIN IMMEDIATE` transaction, so two requests near a cap cannot both pass.
//! When the request finishes, [`finish`] replaces the reservation with the
//! actual usage; a request whose outcome or charge is unknown keeps its upper
//! bound counted instead.

use pirc_protocol::{AssistantMessage, InferenceRequest, StopReason, Usage};
use pirc_providers::ModelCost;
use rusqlite::{Connection, TransactionBehavior, params};
use serde_json::json;

use crate::app::AppState;
use crate::pots::budget::{self, Exhaustion, Scope, Unit, Windows};
use crate::usage::{self, Pricing};
use crate::util::{new_id, now_ms};

/// A held reservation. Held requests older than this have no living inference
/// task (a request times out after ten minutes), so they count as unknown
/// charges rather than blocking a cap forever.
const STALE_MS: i64 = 15 * 60_000;

/// The pricing and bounds a request was admitted at.
#[derive(Clone, Debug, PartialEq)]
pub struct Reservation {
    pub id: String,
    pub owner: String,
    pub pot_id: String,
    pub node_id: String,
    pub node_session: String,
    pub windows: Windows,
    pub money_micros: i64,
    pub tokens: i64,
    /// The accepted revision's per-token prices.
    pub price: ModelCost,
    pub pricing_revision: String,
}

/// What one request would take from every cap.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Bound {
    pub input_tokens: i64,
    pub output_tokens: i64,
    pub tokens: i64,
    pub money_micros: i64,
}

/// A defensible upper bound on a request's input tokens: every prompt byte is
/// at most one token, plus a little room per message and tool schema.
pub fn input_bound(request: &InferenceRequest) -> i64 {
    let messages = serde_json::to_vec(&request.messages).map_or(0, |bytes| bytes.len());
    let tools = serde_json::to_vec(&request.tools).map_or(0, |bytes| bytes.len());
    let bytes = request
        .system_prompt
        .len()
        .saturating_add(messages)
        .saturating_add(tools);
    let items = 1 + request.messages.len() + request.tools.len();
    (bytes as i64).saturating_add(64 * items as i64)
}

/// The request's output limit, or the model's largest possible answer.
fn output_limit(app: &AppState, request: &InferenceRequest) -> i64 {
    if let Some(limit) = request.max_tokens.filter(|limit| *limit > 0) {
        return limit as i64;
    }
    let merged = app.backends.merged();
    let from_backend = merged
        .providers
        .get(&request.provider_name)
        .and_then(|provider| {
            provider
                .models
                .iter()
                .find(|model| model.id == request.model_id)
        })
        .map(|model| model.max_tokens);
    let from_catalog = pirc_providers::catalog_providers()
        .flat_map(pirc_providers::catalog_models)
        .filter(|model| model.id == request.model_id)
        .map(|model| model.max_tokens)
        .max();
    from_backend
        .or(from_catalog)
        .filter(|limit| *limit > 0)
        .unwrap_or(32_000) as i64
}

/// The price money caps use: billed API cost, or the API-equivalent estimate
/// when the owner enabled it. A model with no such price has no money bound.
fn money_price(pricing: &Pricing, count_subscription_money: bool) -> Option<ModelCost> {
    pricing.billed.or(if count_subscription_money {
        pricing.api_equivalent
    } else {
        None
    })
}

fn bound(request: &InferenceRequest, app: &AppState, price: Option<ModelCost>) -> Bound {
    let input_tokens = input_bound(request);
    let output_tokens = output_limit(app, request);
    let money_micros = price.map_or(0, |price| {
        // Input can be charged as ordinary input, cache read or cache write;
        // the dearest of the three bounds all of them. Output stands alone.
        let input_rate = price.input.max(price.cache_read).max(price.cache_write);
        let total = input_tokens as f64 * input_rate + output_tokens as f64 * price.output.max(0.0);
        total.round().max(0.0) as i64
    });
    Bound {
        input_tokens,
        output_tokens,
        tokens: input_tokens.saturating_add(output_tokens),
        money_micros,
    }
}

fn exhausted(exhaustion: Exhaustion) -> crate::error::ApiError {
    crate::error::ApiError::new(
        402,
        "budget_exhausted",
        format!(
            "Budget exhausted: the {} {} cap has no room for this request",
            exhaustion.scope.as_str(),
            exhaustion.unit.as_str()
        ),
    )
    .with_details(json!({
        "scope": exhaustion.scope,
        "unit": exhaustion.unit,
    }))
}

fn window_start(exhaustion: Exhaustion, windows: &Windows) -> i64 {
    if exhaustion.unit == Unit::Money {
        windows.month_start
    } else {
        windows.day_start
    }
}

/// Hold `reservation` against its pot and owner caps, or report which cap has
/// no room. The sums include reservations still held by other requests.
pub fn reserve(
    conn: &Connection,
    reservation: &Reservation,
) -> crate::error::ApiResult<Option<Exhaustion>> {
    let tx = rusqlite::Transaction::new_unchecked(conn, TransactionBehavior::Immediate)?;
    // A request can no longer be alive after the inference timeout; keep its
    // upper bound as an unknown charge instead of blocking the window.
    tx.execute(
        "UPDATE budget_reservations
         SET state='charged',actual_money_micros=money_micros,actual_tokens=tokens,settled_at=?1
         WHERE state='held' AND created_at<?2",
        params![now_ms(), now_ms() - STALE_MS],
    )?;
    let caps = budget::caps(&tx, &reservation.owner, &reservation.pot_id)?;
    let pot_money = budget::money_used(
        &tx,
        &reservation.owner,
        Some(&reservation.pot_id),
        reservation.windows.month_start,
        reservation.windows.month_end,
        caps.count_subscription_money,
    )? + budget::money_reserved(
        &tx,
        &reservation.owner,
        Some(&reservation.pot_id),
        reservation.windows.month_start,
    )?;
    if pot_money.saturating_add(reservation.money_micros) > caps.pot_money {
        return Ok(Some(Exhaustion {
            scope: Scope::Pot,
            unit: Unit::Money,
        }));
    }
    let pot_tokens = budget::tokens_used(
        &tx,
        &reservation.owner,
        Some(&reservation.pot_id),
        reservation.windows.day_start,
        reservation.windows.day_end,
    )? + budget::tokens_reserved(
        &tx,
        &reservation.owner,
        Some(&reservation.pot_id),
        reservation.windows.day_start,
    )?;
    if pot_tokens.saturating_add(reservation.tokens) > caps.pot_tokens {
        return Ok(Some(Exhaustion {
            scope: Scope::Pot,
            unit: Unit::Tokens,
        }));
    }
    // A zero owner-wide cap means the owner set none.
    if caps.owner_money > 0 {
        let owner_money = budget::money_used(
            &tx,
            &reservation.owner,
            None,
            reservation.windows.month_start,
            reservation.windows.month_end,
            caps.count_subscription_money,
        )? + budget::money_reserved(
            &tx,
            &reservation.owner,
            None,
            reservation.windows.month_start,
        )?;
        if owner_money.saturating_add(reservation.money_micros) > caps.owner_money {
            return Ok(Some(Exhaustion {
                scope: Scope::Owner,
                unit: Unit::Money,
            }));
        }
    }
    if caps.owner_tokens > 0 {
        let owner_tokens = budget::tokens_used(
            &tx,
            &reservation.owner,
            None,
            reservation.windows.day_start,
            reservation.windows.day_end,
        )? + budget::tokens_reserved(
            &tx,
            &reservation.owner,
            None,
            reservation.windows.day_start,
        )?;
        if owner_tokens.saturating_add(reservation.tokens) > caps.owner_tokens {
            return Ok(Some(Exhaustion {
                scope: Scope::Owner,
                unit: Unit::Tokens,
            }));
        }
    }
    tx.execute(
        "INSERT INTO budget_reservations(id,owner_user,pot_id,node_id,node_session,
           month_start,month_end,day_start,day_end,money_micros,tokens,
           input_price,output_price,cache_read_price,cache_write_price,pricing_revision,
           state,created_at)
         VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,'held',?17)",
        params![
            reservation.id,
            reservation.owner,
            reservation.pot_id,
            reservation.node_id,
            reservation.node_session,
            reservation.windows.month_start,
            reservation.windows.month_end,
            reservation.windows.day_start,
            reservation.windows.day_end,
            reservation.money_micros,
            reservation.tokens,
            reservation.price.input,
            reservation.price.output,
            reservation.price.cache_read,
            reservation.price.cache_write,
            reservation.pricing_revision,
            now_ms(),
        ],
    )?;
    tx.commit()?;
    Ok(None)
}

/// Admit a request from a pot's own session. Requests from other sessions are
/// not capped here and return `None`.
pub fn begin(
    app: &AppState,
    node_id: &str,
    node_session: &str,
    request: &InferenceRequest,
) -> crate::error::ApiResult<Option<Reservation>> {
    let (who, windows, caps) = {
        let db = app.db.lock();
        let who = usage::attribute(&db, node_id, node_session)?;
        if who.actor_kind != "pot" {
            return Ok(None);
        }
        let (Some(owner), Some(pot_id)) = (who.owner.clone(), who.actor_id.clone()) else {
            return Ok(None);
        };
        let windows = budget::windows(&app.config.timezone, now_ms());
        let caps = budget::caps(&db, &owner, &pot_id)?;
        (who, windows, caps)
    };
    let owner = who.owner.expect("checked above");
    let pot_id = who.actor_id.expect("checked above");
    let pricing = usage::pricing(app, &request.provider_name, &request.model_id);
    let price = money_price(&pricing, caps.count_subscription_money).unwrap_or(ModelCost {
        input: 0.0,
        output: 0.0,
        cache_read: 0.0,
        cache_write: 0.0,
    });
    let bound = bound(request, app, Some(price));
    let reservation = Reservation {
        id: new_id("resv"),
        owner: owner.clone(),
        pot_id: pot_id.clone(),
        node_id: node_id.to_owned(),
        node_session: node_session.to_owned(),
        windows,
        money_micros: bound.money_micros,
        tokens: bound.tokens,
        price,
        pricing_revision: pirc_providers::catalog_version().to_owned(),
    };
    let refused = {
        let db = app.db.lock();
        reserve(&db, &reservation)?
    };
    let Some(exhaustion) = refused else {
        return Ok(Some(reservation));
    };
    if budget::note_exhausted(
        &app.db.lock(),
        &owner,
        &pot_id,
        exhaustion,
        window_start(exhaustion, &windows),
    )
    .unwrap_or(false)
    {
        app.activity_changed(&owner);
    }
    Err(exhausted(exhaustion))
}

fn actual(usage: &Usage, price: &ModelCost) -> (i64, i64) {
    (
        usage::micros(usage, price),
        (usage.input + usage.output + usage.cache_read + usage.cache_write) as i64,
    )
}

/// Finish a reservation: the actual usage replaces it, or an unknown charge
/// keeps its upper bound. Also records a cap that this request exhausted.
pub fn finish(app: &AppState, reservation: &Reservation, message: &AssistantMessage) {
    let total = message.usage.input
        + message.usage.output
        + message.usage.cache_read
        + message.usage.cache_write;
    let known =
        total > 0 || !matches!(message.stop_reason, StopReason::Error | StopReason::Aborted);
    // A settled reservation is replaced by the usage row, so its own actual
    // figures are only an audit trail; a charged one keeps counting.
    settle(app, reservation, known.then_some(&message.usage));
}

/// Keep a reservation whose request was stopped or timed out as an unknown
/// charge; it still counts toward its windows.
/// The request never left (refused after admission): its reservation goes.
pub fn cancel(app: &AppState, reservation: Option<&Reservation>) {
    let Some(reservation) = reservation else {
        return;
    };
    if let Err(error) = app.db.lock().execute(
        "DELETE FROM budget_reservations WHERE id=?1 AND state='held'",
        [&reservation.id],
    ) {
        crate::log::warn(&format!("budget reservation {}: {error}", reservation.id));
    }
}

pub fn keep_unknown(app: &AppState, reservation: Option<&Reservation>) {
    if let Some(reservation) = reservation {
        settle(app, reservation, None);
    }
}

fn settle(app: &AppState, reservation: &Reservation, usage: Option<&Usage>) {
    let known = usage.is_some();
    let (money, tokens) = match usage {
        Some(usage) => actual(usage, &reservation.price),
        None => (reservation.money_micros, reservation.tokens),
    };
    let result = {
        let db = app.db.lock();
        db.execute(
            "UPDATE budget_reservations
             SET state=?1,actual_money_micros=?2,actual_tokens=?3,settled_at=?4
             WHERE id=?5 AND state='held'",
            params![
                if known { "settled" } else { "charged" },
                money,
                tokens,
                now_ms(),
                reservation.id,
            ],
        )
    };
    if let Err(error) = result {
        crate::log::warn(&format!("could not settle budget reservation: {error}"));
        return;
    }
    let windows = reservation.windows;
    let exhausted = {
        let db = app.db.lock();
        budget::exhaustion(&db, &reservation.owner, &reservation.pot_id, &windows)
            .ok()
            .flatten()
    };
    let Some(exhaustion) = exhausted else {
        return;
    };
    let logged = budget::note_exhausted(
        &app.db.lock(),
        &reservation.owner,
        &reservation.pot_id,
        exhaustion,
        window_start(exhaustion, &windows),
    )
    .unwrap_or(false);
    if logged {
        app.activity_changed(&reservation.owner);
    }
}

/// The money actual usage costs at the reservation's accepted prices.
#[cfg(test)]
pub fn actual_money(reservation: &Reservation, usage: &Usage) -> i64 {
    actual(usage, &reservation.price).0
}

#[cfg(test)]
mod tests {
    use super::*;
    use pirc_protocol::{InferenceRequest, Message, ThinkingLevel};

    fn request(max_tokens: Option<u64>) -> InferenceRequest {
        let user = Message::User {
            content: pirc_protocol::UserContent::Text("hello".into()),
            timestamp: 1,
        };
        InferenceRequest {
            purpose: Default::default(),
            provider_name: "p".into(),
            model_id: "m".into(),
            system_prompt: "You are a pot.".into(),
            messages: vec![user],
            tools: Vec::new(),
            thinking: ThinkingLevel::Off,
            session_id: "agent".into(),
            max_tokens,
            tool_choice: None,
        }
    }

    #[test]
    fn the_input_bound_grows_with_the_prompt_and_never_shrinks_below_bytes() {
        let small = input_bound(&request(None));
        let mut large = request(None);
        large.system_prompt.push_str(&"x".repeat(10_000));
        assert!(input_bound(&large) >= small + 10_000);
        assert!(small > 0);
    }

    #[test]
    fn the_money_bound_prices_input_at_its_dearest_cache_rate_and_all_output() {
        let price = ModelCost {
            input: 10.0,
            output: 50.0,
            cache_read: 1.0,
            cache_write: 12.5,
        };
        let reservation = Reservation {
            id: "r".into(),
            owner: "alice".into(),
            pot_id: "pot".into(),
            node_id: "node".into(),
            node_session: "remote".into(),
            windows: budget::windows("UTC", 0),
            money_micros: 0,
            tokens: 100,
            price,
            pricing_revision: "old".into(),
        };
        let usage = Usage {
            input: 1_000,
            output: 100,
            cache_read: 0,
            cache_write: 0,
            total_tokens: 1_100,
        };
        // 1,000 input at $10/M + 100 output at $50/M.
        assert_eq!(actual_money(&reservation, &usage), 15_000);
    }
}
