# Usage ledger

[Open work](README.md) · [Roadmap M3](roadmap.md#m3-usage-ledger) · [Pots budgets](pots.md#budgets-and-the-causal-root) · Design: E28–E31

Today, token usage exists only inside each session's message history
(`pirc-llm-types` `Usage`), and the model catalog drops prices
(`crates/pirc-providers/src/catalog.rs` keeps pi-ai's `Model` "without `cost`").
pirc 0.11.0 needs a ledger for pot budgets and for the user and usage pages.

## Recording

- **Where**: every model request already passes through the Gateway
  (`crates/pirc-gateway/src/nodes.rs`, `start_inference`), which receives the final
  assistant message with usage. Record there, once per request, including failed or
  cancelled requests that reported partial usage. Side requests (session titles, the
  auto-mode classifier, compaction, memory) go through the same path and are recorded
  with their purpose.
- **Row** (`usage_events`): `id`, `at`, `owner_user`, `session_id`, `node_id`,
  `actor_kind` (`user`, `pot`, `schedule`, `delegation`, `system`), `actor_id`,
  `causal_root`, `purpose` (`turn`, `title`, `classifier`, `compaction`, `memory`,
  …), `provider`, `model`, `auth_kind` (`api_key`, `subscription`, `keyless`),
  `plan` (subscription plan label, e.g. "Claude Max"), `input_tokens`,
  `output_tokens`, `cache_read_tokens`, `cache_write_tokens`, `cost_micros` (billed
  API cost; null for subscriptions and unpriced models), `api_equiv_micros` (what the
  same tokens would cost at API prices; null when unpriced), `pricing_revision`,
  `outcome`.
- **Attribution**: the inference request carries the session ID; the Gateway maps the
  session to its actor (a pot's own session, work a pot opened, a schedule run, a
  delegation, or the user). The causal root comes from the wake or work that the
  request belongs to (pots.md).
- **Retention**: rows are kept for 400 days by default (heatmaps need ~40 weeks plus a
  year of monthly totals); aggregated daily totals are kept indefinitely.

## Pricing

- Keep `cost` (input, output, cache read, cache write per million tokens) in
  `scripts/model-catalog.ts` and `crates/pirc-providers/catalog.json`, add it to
  `pirc-llm-types` `Model`, and stamp the catalog with a pricing revision.
- Custom endpoints and `models.json` providers may declare prices; without one, the
  model is unpriced.
- **Subscriptions** (P7): rows record tokens and the plan label. `api_equiv_micros` is
  computed when the model has a public API price and is shown only when the user turns
  on "show API-equivalent price"; the UI always marks it as an estimate. Subscription
  rows never have `cost_micros`.

## Budget admission

Used by pots (and later any capped actor):

1. Before a request, compute an upper bound from the input tokens, the request's
   output limit and the pricing revision; reserve it against the pot, the causal root
   and the owner-wide caps in one transaction.
2. If any cap would be exceeded, refuse with a typed reason
   (`budget_exhausted: pot|root|owner`, `tokens|money`).
3. On completion, replace the reservation with the actual row; keep unknown charges;
   refund only the proven unused part.
4. Money caps admit unpriced or subscription usage only through API-equivalent
   accounting when the user enabled it (P20); token caps count all usage.

## Views and API

`GET /api/usage?from=YYYY-MM-DD&to=YYYY-MM-DD[&tz=Area/City]` (implemented in
`crates/pirc-gateway/src/usage/api.rs`) returns the signed-in owner's usage for 1 to
400 local days (default zone: the Gateway's): per day, per model (with how it was
paid), per actor and per purpose, totals, the streak of consecutive active days
ending on the last day, and the pricing revision. The usage page builds the
overview numbers, the heatmap (one request covering 18–40 weeks), the 12-week
chart, the cumulative chart and the monthly breakdown from it.

Billed cost (`billedMicros`) and the subscription API-equivalent estimate
(`subscriptionApiEquivalentMicros`) are separate fields, so subscription usage is
never summed into spending silently. The share action renders charts to an image on the client; no
raw rows leave the device.

## Acceptance cases

- One row per request, including a cancelled request that reported partial usage.
- A pot-opened work session's requests are attributed to that pot and its root.
- Two concurrent requests near a cap cannot both pass admission.
- A subscription request records tokens and the plan; money totals exclude it unless
  API-equivalent accounting is on, and the UI marks the estimate.
- A price change does not alter past rows or raise an accepted cap.
