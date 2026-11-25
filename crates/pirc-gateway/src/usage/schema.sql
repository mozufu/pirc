-- One row per model request the Gateway ran (plans/usage.md). Amounts are
-- micro-US-dollars; tokens are as the provider reported them.
CREATE TABLE usage_events (
 id INTEGER PRIMARY KEY,
 at INTEGER NOT NULL,
 -- NULL when the Node session is unknown to the Gateway.
 owner_user TEXT,
 session_id TEXT,
 node_id TEXT NOT NULL,
 node_session TEXT NOT NULL,
 actor_kind TEXT NOT NULL CHECK(actor_kind IN ('user','schedule','delegation','pot','system')),
 actor_id TEXT,
 causal_root TEXT,
 purpose TEXT,
 provider TEXT NOT NULL,
 model TEXT NOT NULL,
 auth_kind TEXT NOT NULL CHECK(auth_kind IN ('api_key','subscription','keyless')),
 -- The subscription plan's name, for subscription requests.
 plan TEXT,
 input_tokens INTEGER NOT NULL CHECK(input_tokens>=0),
 output_tokens INTEGER NOT NULL CHECK(output_tokens>=0),
 cache_read_tokens INTEGER NOT NULL CHECK(cache_read_tokens>=0),
 cache_write_tokens INTEGER NOT NULL CHECK(cache_write_tokens>=0),
 -- Billed API cost; NULL for subscriptions and unpriced models.
 cost_micros INTEGER CHECK(cost_micros IS NULL OR cost_micros>=0),
 -- The same tokens at public API prices; NULL when unpriced.
 api_equiv_micros INTEGER CHECK(api_equiv_micros IS NULL OR api_equiv_micros>=0),
 pricing_revision TEXT,
 outcome TEXT NOT NULL CHECK(outcome IN ('ok','error','aborted')),
 CHECK(auth_kind!='subscription' OR (cost_micros IS NULL AND plan IS NOT NULL))
);
CREATE INDEX usage_events_owner_at ON usage_events(owner_user, at);
CREATE INDEX usage_events_actor_at ON usage_events(actor_kind, actor_id, at);

-- Budget admission (plans/usage.md, Budget admission): an upper bound held
-- against a pot's and its owner's caps while a model request runs. Prices are
-- the accepted revision's, so a later catalog change never reprices it. A
-- finished request is `settled` (the usage row is the charge) or `charged`
-- (the charge is unknown, so the upper bound stays counted) until its window
-- has passed.
CREATE TABLE budget_reservations (
 id TEXT PRIMARY KEY,
 owner_user TEXT NOT NULL,
 pot_id TEXT NOT NULL,
 node_id TEXT NOT NULL,
 node_session TEXT NOT NULL,
 month_start INTEGER NOT NULL,
 month_end INTEGER NOT NULL,
 day_start INTEGER NOT NULL,
 day_end INTEGER NOT NULL,
 -- The reserved upper bound, in micro-US-dollars and tokens.
 money_micros INTEGER NOT NULL CHECK(money_micros>=0),
 tokens INTEGER NOT NULL CHECK(tokens>=0),
 -- Dollars per million tokens, at the accepted pricing revision.
 input_price REAL NOT NULL CHECK(input_price>=0),
 output_price REAL NOT NULL CHECK(output_price>=0),
 cache_read_price REAL NOT NULL CHECK(cache_read_price>=0),
 cache_write_price REAL NOT NULL CHECK(cache_write_price>=0),
 pricing_revision TEXT NOT NULL,
 state TEXT NOT NULL DEFAULT 'held' CHECK(state IN ('held','settled','charged')),
 actual_money_micros INTEGER CHECK(actual_money_micros IS NULL OR actual_money_micros>=0),
 actual_tokens INTEGER CHECK(actual_tokens IS NULL OR actual_tokens>=0),
 created_at INTEGER NOT NULL,
 settled_at INTEGER,
 CHECK(state='held' OR settled_at IS NOT NULL)
);
CREATE INDEX budget_reservations_owner ON budget_reservations(owner_user, month_start, day_start, state);
CREATE INDEX budget_reservations_pot ON budget_reservations(pot_id, month_start, day_start, state);
