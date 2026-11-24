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
