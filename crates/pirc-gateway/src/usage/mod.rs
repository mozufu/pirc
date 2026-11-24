//! The usage ledger (plans/usage.md): one row per model request, recorded where
//! the Gateway finishes running it. Attribution comes from the Node session
//! whose runner capability admitted the request, never from what the agent
//! claims; prices come from the pinned model catalog.

use rusqlite::{Connection, OptionalExtension, params};

use pirc_protocol::Usage;
use pirc_protocol::{AssistantMessage, StopReason};
use pirc_providers::{ModelCost, catalog_price, catalog_version};

use crate::app::AppState;
use crate::util::now_ms;

/// How a request was paid for.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AuthKind {
    ApiKey,
    Subscription,
    Keyless,
}

impl AuthKind {
    fn as_str(self) -> &'static str {
        match self {
            Self::ApiKey => "api_key",
            Self::Subscription => "subscription",
            Self::Keyless => "keyless",
        }
    }
}

/// What a backend's request costs.
#[derive(Clone, Debug, PartialEq)]
pub struct Pricing {
    pub auth: AuthKind,
    pub plan: Option<String>,
    /// The price billed per token; `None` for subscriptions and unpriced models.
    pub billed: Option<ModelCost>,
    /// Public API price of the same model, for the API-equivalent estimate.
    pub api_equivalent: Option<ModelCost>,
}

/// The API catalog providers whose prices a subscription's models are
/// estimated with, in order.
fn api_equivalents(subscription: &str) -> &'static [&'static str] {
    match subscription {
        "anthropic" => &["anthropic"],
        "openai-codex" => &["openai"],
        // Copilot resells several vendors' models under their own IDs.
        "github-copilot" => &["anthropic", "openai"],
        _ => &[],
    }
}

/// Price `model` on backend `provider` as the Gateway runs it.
pub fn pricing(app: &AppState, provider: &str, model: &str) -> Pricing {
    if let Some(subscription) = provider.strip_prefix("oauth:") {
        let plan = pirc_providers::backends::OAUTH_PROVIDERS
            .iter()
            .find(|info| info.id == subscription)
            .map_or(subscription, |info| info.name);
        let api_equivalent = api_equivalents(subscription)
            .iter()
            .find_map(|api| catalog_price(api, model))
            .filter(|price| !price.is_zero());
        return Pricing {
            auth: AuthKind::Subscription,
            plan: Some(plan.to_owned()),
            billed: None,
            api_equivalent,
        };
    }
    let config = app.backends.merged();
    let backend = config.providers.get(provider);
    let keyed = backend.is_some_and(|b| b.api_key.as_deref().is_some_and(|k| !k.is_empty()));
    let catalog = backend
        .and_then(|b| b.pi_provider.as_deref())
        .unwrap_or(provider);
    let price = catalog_price(catalog, model);
    Pricing {
        auth: if keyed {
            AuthKind::ApiKey
        } else {
            AuthKind::Keyless
        },
        plan: None,
        billed: if keyed { price } else { None },
        api_equivalent: price.filter(|price| !price.is_zero()),
    }
}

/// `tokens × dollars-per-million-tokens` is exactly micro-dollars.
pub fn micros(usage: &Usage, price: &ModelCost) -> i64 {
    let total = usage.input as f64 * price.input
        + usage.output as f64 * price.output
        + usage.cache_read as f64 * price.cache_read
        + usage.cache_write as f64 * price.cache_write;
    total.round().max(0.0) as i64
}

/// Who a request is charged to.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Attribution {
    pub owner: Option<String>,
    pub session: Option<String>,
    pub actor_kind: &'static str,
    pub actor_id: Option<String>,
}

pub fn attribute(
    conn: &Connection,
    node_id: &str,
    node_session: &str,
) -> rusqlite::Result<Attribution> {
    let session: Option<(String, Option<String>)> = conn
        .query_row(
            "SELECT id, owner_user FROM sessions WHERE node_id=?1 AND pi_session_id=?2",
            params![node_id, node_session],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()?;
    let Some((session, owner)) = session else {
        return Ok(Attribution {
            owner: None,
            session: None,
            actor_kind: "system",
            actor_id: None,
        });
    };
    let schedule: Option<String> = conn
        .query_row(
            "SELECT schedule_id FROM schedule_runs WHERE session_id=?1 ORDER BY created_at DESC LIMIT 1",
            [&session],
            |r| r.get(0),
        )
        .optional()?;
    let (actor_kind, actor_id) = if let Some(schedule) = schedule {
        ("schedule", Some(schedule))
    } else if let Some(delegation) = conn
        .query_row(
            "SELECT id FROM delegations WHERE target_session_id=?1 ORDER BY created_at DESC LIMIT 1",
            [&session],
            |r| r.get::<_, String>(0),
        )
        .optional()?
    {
        ("delegation", Some(delegation))
    } else {
        ("user", owner.clone())
    };
    Ok(Attribution {
        owner,
        session: Some(session),
        actor_kind,
        actor_id,
    })
}

/// Record the finished request `message` ran for Node session `node_session`.
pub fn record(
    app: &AppState,
    node_id: &str,
    node_session: &str,
    request: &pirc_protocol::InferenceRequest,
    message: &AssistantMessage,
) {
    let (provider, model) = (request.provider_name.as_str(), request.model_id.as_str());
    let pricing = pricing(app, provider, model);
    let usage = &message.usage;
    let outcome = match message.stop_reason {
        StopReason::Error => "error",
        StopReason::Aborted => "aborted",
        _ => "ok",
    };
    let db = app.db.lock();
    let result = attribute(&db, node_id, node_session).and_then(|who| {
        db.execute(
            "INSERT INTO usage_events(at,owner_user,session_id,node_id,node_session,actor_kind,actor_id,
              provider,model,auth_kind,plan,input_tokens,output_tokens,cache_read_tokens,cache_write_tokens,
              cost_micros,api_equiv_micros,pricing_revision,outcome,purpose)
             VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20)",
            params![
                now_ms(),
                who.owner,
                who.session,
                node_id,
                node_session,
                who.actor_kind,
                who.actor_id,
                provider,
                model,
                pricing.auth.as_str(),
                pricing.plan,
                usage.input as i64,
                usage.output as i64,
                usage.cache_read as i64,
                usage.cache_write as i64,
                pricing.billed.map(|price| micros(usage, &price)),
                pricing.api_equivalent.map(|price| micros(usage, &price)),
                catalog_version(),
                outcome,
                request.purpose.as_str(),
            ],
        )
    });
    if let Err(error) = result {
        crate::log::warn(&format!("could not record model usage: {error}"));
    }
}

#[cfg(test)]
mod tests;
