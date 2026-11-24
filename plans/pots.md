# Pots

[Open work](README.md) · [Roadmap M4](roadmap.md#m4-pots-backend) · [Usage](usage.md) · Design: [decisions](../docs/design/decisions.md), [E specification](../docs/design/design-spec-pots.md)

A **pot** is a named, persistent, autonomous agent owned by the single user. Each pot
has its own personality, memory, responsibilities, permissions, models and budget.
Pots talk to the user, to each other and in groups, and open or join work sessions
within their permissions. This document is the backend specification; the screens
are in the design handoff (E1–E36).

## Invariants

These hold for every feature below and are tested directly.

1. **No forged authority.** A message from a pot never counts as the user's
   instruction or consent. Only the user's own actions (through an authenticated
   client) grant, approve, raise limits or confirm.
2. **No hidden channel.** Every pot↔pot message, every instruction a pot sends into a
   work session and every handover is a stored event the user can read.
3. **Attribution comes from the backend.** "From <pot>" and the author of every
   message are set by the Gateway from the authenticated actor, never from text.
4. **Personality and work description grant nothing.** Only the permission settings
   do.
5. **Permissions never merge.** A pot acting in a group, or on work handed over to it,
   uses only its own permissions. Handover transfers work, not permissions.
6. **Bounded autonomy.** Every action belongs to a causal root; roots have finite
   depth, fan-out and budget. A missing limit is not unlimited.
7. **At-most-once dispatch.** Instructions into work sessions are delivered at most
   once; an uncertain delivery is shown as uncertain and is not retried automatically.
8. **Durable before push.** A decision waiting for the user is stored before any
   notification; a notification is never an approval.

## Data model

New tables live in the Gateway database (fresh baseline from M2.5) with real columns,
not JSON blobs. Names are indicative.

| Table                    | Key columns                                                                                                                                                                                                                              |
| ------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `pots`                   | `id`, `owner_user`, `name`, `avatar_color`, `avatar_upload`, `personality` (soul text), `intro` (short, shown in lists and `@` menu), `work_description`, `state` (`active`/`paused`/`archived`), `revision`, `created_at`, `updated_at` |
| `pot_responsibilities`   | `id`, `pot_id`, `title`, `detail`, `position`                                                                                                                                                                                            |
| `pot_permissions`        | one row per pot: `reach` (`answer`/`observe`/`work`), `dm_send` and `dm_receive` (`all`/`selected`/`off`, default `all`), `max_concurrent_works`, `budget_money_month_micros`, `budget_tokens_day`, `revision`                           |
| `pot_observe_scopes`     | `pot_id`, `kind` (project, workspace, session, calendar, schedules, …), `ref`, `lead` (this pot summarises the scope's notifications)                                                                                                    |
| `pot_dm_peers`           | `pot_id`, `peer_pot_id`, `direction` (`send`/`receive`): used when the matching rule is `selected`                                                                                                                                       |
| `pot_work_locations`     | `pot_id`, `project_id` or `node_id`+`path`, `access` (`read`/`write`)                                                                                                                                                                    |
| `pot_models`             | `pot_id`, `position` (0 = primary, 1… = fallbacks), `provider`, `model`                                                                                                                                                                  |
| `pot_runtime`            | `pot_id`, `thinking`, `thinking_auto`, `session_id` (its persistent session), `autonomy_interval_s` (null = off; default 172800), `next_review_at`, `last_engaged_at`, `active_fallback`                                                 |
| `pot_work_models`        | `pot_id`, `provider`, `model`, `mode` (`direct`/`ask`)                                                                                                                                                                                   |
| `threads`                | `id`, `kind` (`direct` user↔pot, `group`, `pot_dm` pot↔pot), `name`, `avatar`, `host_pot_id` (groups), `project_id` (optional group binding), `created_at`                                                                             |
| `thread_members`         | `thread_id`, `member_kind` (`user`/`pot`), `member_id`, `joined_at`, `left_at`                                                                                                                                                           |
| `messages`               | `id`, `thread_id`, `seq`, `author_kind`, `author_id`, `body`, `mentions`, `all_mention`, `reply_to`, `causal_root`, `created_at`; cards (decisions, work cards, handoff lines) are typed rows                                            |
| `pot_activity`           | `id`, `pot_id`, `at`, `kind`, `counterpart_kind`, `counterpart_id`, `summary`, `refs` (thread, message, session, approval, handover), `causal_root`                                                                                      |
| `causal_roots`           | `id`, `origin` (user message, observed event, autonomy review, schedule), `depth_limit`, `fanout_limit`, `budget_micros`, `budget_tokens`, `spent_*`, `reserved_*`, `state`                                                              |
| `model_approvals`        | `id`, `pot_id`, `work_session_id` or pending work, `provider`, `model`, `thinking`, `reason`, `estimate_micros`, `remaining_micros`, `state` (`pending`/`allowed_once`/`denied`), `deny_reason`                                          |
| `budget_requests`        | `id`, `pot_id`, `amount_micros` or `tokens`, `window`, `reason`, `state` (`open`/`approved`/`denied`), `approved_amount`                                                                                                                 |
| `pot_handovers`          | `id`, `from_pot_id`, `to_kind`/`to_id` (pot or user), `proposed_by` (`user`/`pot`), `state` (`proposed`/`confirmed`/`applied`/`rejected`), `revision`                                                                                    |
| `pot_handover_items`     | `handover_id`, `item_kind` (responsibility, follow-up, coordinated work, group host), `item_ref`, `fit` (`ok`/`narrowed`/`stop`), `target`                                                                                               |
| `pot_settings`           | owner-wide: `cap_money_month_micros`, `cap_tokens_day`, `on_exhausted` (`pause_all`/`ask`), `activity_retention_days`, loop-guard thresholds                                                                                             |
| `obs_events` (L0)        | `id`, `owner_user`, `source_kind`, `source_ref`, `condition_key`, `occurrence_key`, `source_revision`; unique on (owner, source, condition, occurrence); no content                                                                      |
| `obs_observations` (L1)  | `id`, `pot_id`, `event_id`, `note`, `evidence_refs`, `created_at`; unique on (pot, event)                                                                                                                                                |
| `obs_notifications` (L2) | `id`, `owner_user`, `event_id`, `issuer_pot_id` (lead or null for merged), `observation_ids`, `state`; unique on (owner, event)                                                                                                          |
| `obs_dispatches` (L3)    | `id`, `owner_user`, `event_id`, `purpose_key` (target session/workspace + action class + event), `pot_id`, `state`; at most one active per purpose                                                                                       |

Limits are columns with defaults, never absent: a pot without a budget value cannot
start model work.

## Reach levels

| Reach                 | May                                                                                                                 | May not                                 |
| --------------------- | ------------------------------------------------------------------------------------------------------------------- | --------------------------------------- |
| `answer` (only reply) | Reply when the user, a group or a permitted pot addresses it; use its own memory                                    | Observe sources; open or message work   |
| `observe` (suggest)   | Plus: receive events from its observe scopes, record observations, suggest to the user or DM permitted pots         | Open or message work                    |
| `work` (start work)   | Plus: open work sessions in its work locations, send instructions into work it coordinates, request model approvals | Exceed its locations, models or budgets |

"Dispatch right" (sender) = reach `work` plus DM send permission to the receiver, or the
group host role. "Execution right" (receiver) = reach `work` with a location covering
the target. Both are checked when the request is made and again when the work starts.

## Runtime

- **Host**: the chat node (`pirc-chat`). The Gateway does not run agents.
- **One persistent session per pot** in a new `pot` mode, which replaces `chat` mode
  (`crates/pirc-config/src/modes/chat.md`). The session lives in a private directory
  `<state>/pots/<pot-id>/` (writable scratch space, not shared between pots).
- **Prompt**: built-in pot identity and environment sections, then the pot's
  personality, intro, work description, responsibilities and a generated summary of
  its permissions (for the model's information only; enforcement is in the Gateway
  and Node), then the user's display name.
- **Wakes**: the pot's session is idle between wakes. A wake is a delivery into the
  session with a typed source: user message, group message addressed to it, pot DM,
  observed event, model-approval result, handover, its own scheduled reminder, or an
  autonomy review. Wakes are queued per pot and delivered one at a time; a wake carries
  its causal root and the thread to answer in (the reply target).
- **Replies**: the pot's final assistant text of a wake goes to the reply target.
  Messages to other threads use the `message_send` tool, subject to DM rules.
- **Memory**: isolated per pot (P8). The existing assistant memory store is keyed by
  pot ID; recall never returns another pot's notes.
- **Models**: primary plus ordered fallbacks; on a retryable failure before any output
  the pot moves to the next model (as role fallback does today) and logs a `fallback`
  activity. Thinking level is the configured one; with `thinking_auto` the pot may call
  `set_thinking(level, reason)`, which applies without asking and logs a
  `thinking_adjust` activity with the reason.
- **Pause**: no wakes are delivered (they stay queued unless they expire); work the pot
  already started continues under its own controls; the pause sheet lists what stops
  and what continues. Nothing is handed over.

## Autonomy

- **Autonomy review**: if `autonomy_interval_s` is set and the pot has not been engaged
  (no user message, no assigned work, no wake other than reviews) since
  `last_engaged_at + interval`, the Gateway delivers an `autonomy_review` wake. The
  default interval for a new pot is 2 days; the user can turn it off at creation or
  later. The pot may call `set_autonomy(interval | off, reason)` to change its own
  interval (P2); this is logged.
- **Self-scheduling**: `remind_me(at, note)` creates a pot-owned reminder (a schedule
  whose target is the pot's own session) so the pot can plan work toward a deadline.
  Reminders count against the pot's budget like any wake.
- **Deadline-driven work** (example: "finish X by 11/30, here is the project folder"):
  the user grants a work location; the pot plans with reminders, opens or continues
  work sessions within its locations and concurrency, and reports in its thread.
- **Spending** (P18): every autonomous wake and everything it causes is charged
  to the pot and to its causal root. When the pot's budget is exhausted, it stops
  taking wakes that need a model, posts a decision card in its thread and notifies the
  user. It never raises its own limits; it can check its budget and ask for more
  (see [Budgets](#budgets-and-the-causal-root)).

## Threads and messaging

- **Direct thread** (user↔pot): created with the pot. Bubbles with avatars.
- **Groups**: members (user and pots), a host pot, name and avatar (defaults to the
  members'), optional project binding.
  - A user message without a mention wakes **only the host**, which answers and may
    hand parts to members (each acts with its own permissions).
  - `@pot` wakes that pot only.
  - `@all` is available to the user only; the composer warns that every pot will be
    woken (P9). Pots cannot address all members.
  - A pot's group message that mentions another pot wakes it only if the sender's DM
    send rule and the receiver's DM receive rule both allow it; otherwise the mention
    is shown but does not wake.
- **Pot DMs** (pot↔pot): only through `message_send`, gated by both pots' DM rules.
  Each DM is a stored thread visible to the user and a `dm` activity.
- **Decision cards**: a pot asks the user to choose (design E11) through a durable
  interaction card in its thread, listed as "待你" (waiting for you). Answering is a
  user action; the answer is delivered as a wake.
- **Work cards and handoff lines** are typed messages created by the Gateway when a
  pot opens work or hands something over, not text the model writes.

## Work dispatch

- `work_open(location, title, instruction, model?, thinking?)` creates a work session
  through the internal creation service (roadmap M2.2) with "From <pot>" provenance
  and the pot as coordinator.
- `work_send(session, instruction)` delivers into a work session the pot coordinates
  (at most once; uncertain stays uncertain).
- `work_status(session)` reads progress the pot is allowed to observe.
- **Models for work**: only models in `pot_work_models`. `direct` models start
  immediately. `ask` models create a `model_approvals` row and a sheet for the user
  (work name, model and thinking, the pot's reason, estimated cost and remaining
  budget) with exactly three answers: deny, deny with a reason, allow once. A reason is
  posted into the pot's thread. "Allow once" covers that one start only.
- Waiting approvals appear in Work → "Needs you" and in Activity ("等你核准").
- The user can take over any pot-coordinated work; the pot is told and stops sending.
- Concurrency: `max_concurrent_works` per pot, plus the global caps.

## Observation and de-duplication

Layers (P10):

| Layer           | Key                                    | Rule                                                                                                |
| --------------- | -------------------------------------- | --------------------------------------------------------------------------------------------------- |
| L0 source event | (owner, source, condition, occurrence) | One row per fact; no content. A pot only learns of it if its observe scope covers the source.       |
| L1 observation  | (pot, L0)                              | One per pot, never merged. Each keeps its own note and evidence.                                    |
| L2 notification | (owner, L0)                            | At most one notification per event, sent by the scope's lead pot, or merged listing every observer. |
| L3 dispatch     | (owner, L0, purpose)                   | At most one active dispatch per purpose; a second pot is told who is handling it and may add notes. |

- A responsibility is never absorbed by another pot's observation: L0 existing means
  "known", not "handled".
- Sharing an observation with another pot goes through a DM and cannot exceed the
  receiver's own observe scope.
- Purpose keys are built from structured fields, never from model wording.
- Observation cost is charged to each observing pot; dispatch cost to the dispatching
  pot and its causal root.

## Budgets and the causal root

- **Units**: money (micro-USD) per month and tokens per day, per pot and owner-wide
  (`pot_settings`). Concurrency is a separate limit.
- **Causal root**: created by a user message, an observed event, an autonomy review or
  a reminder. Every wake, DM, handoff and work start it causes inherits it.
  Defaults: depth 4, fan-out 4 per hop, budget = the initiating pot's remaining budget
  capped by owner limits. New work or handovers cannot reset a root's accounting.
- **Reservation before calls**: before a model request, reserve a defensible upper
  bound from the request's input size, output limit and the pricing revision, across
  every concurrent child of the root. Reconcile once with actual usage; keep unknown
  charges; refund only proven unused reservations. Price changes do not raise an
  accepted cap. If a model cannot be bounded in money (no price), money caps cannot
  admit it unless the user enabled API-equivalent accounting (Q7); token caps always
  apply.
- **Exhaustion**: per pot, the pot stops model wakes and asks the user; owner-wide,
  `on_exhausted` decides (`pause_all` or `ask`).
- **Planning with the budget** (P18): `budget_status` returns the pot's remaining
  money and tokens for the current windows, its reservations, the owner-wide
  remainder and the current root's remainder. `budget_request(amount, window,
reason)` posts a decision card in the pot's direct thread and sends a notification;
  the user can approve (raising that pot's cap for the stated window), approve a
  different amount, or deny. Only one request per pot can be open; a denied request
  cannot be repeated for the same window without new user input. A request reserves
  nothing and costs only its own wake.

## Loop guard

High-volume collaboration is allowed while it makes progress (P19). The guard stops
ineffective cycles; it does not cap productive work beyond the budgets.

**Progress** is a backend-observed effect, never a model claim: a work session's run
completes, a task or todo changes state, files change in a work location, a
user-visible message lands in a direct or group thread the user reads, a decision is
answered, a handover is applied, an observation records new evidence.

Rules, each with configurable thresholds in `pot_settings` and conservative defaults:

1. **Ping-pong handovers.** An item handed back to its previous holder within the
   cooldown (default 1 hour) is refused unless the user confirms. A→B→C→A cycles of
   the same item are detected by its handover history, not by timing alone.
2. **Same purpose repeated.** A wake whose structured purpose (target, action class,
   source event) matches a recent wake in the same root with no progress in between
   counts as a repeat. Wording does not matter.
3. **No-progress streak.** Per causal root and per pot pair, count wakes and messages
   since the last progress. Past the threshold (default 12 wakes or 30 messages), the
   root is suspended: no more wakes are delivered for it.
4. **Rate ceilings.** Per pot pair, messages per minute and per hour; per root, wakes
   per minute. Exceeding a ceiling delays delivery (backpressure) before it suspends.
5. **Suspension is visible.** A suspended root posts one summary card to the user (who
   was talking, how many exchanges, the last progress, the repeated purpose) with
   resume, stop the root, or pause the pots involved. It is logged as activity. A pot
   cannot lift a suspension.

Tests cover: an A→B→A handover refused; a two-pot DM exchange without progress
suspended at the threshold; a long exchange with progress every few turns not
suspended; a suspended root waking nothing until the user resumes it.

## Handover, pause, archive, delete

- **Handover** moves responsibilities, follow-ups, coordinated works and group host
  roles to another pot or to the user. Each item shows the receiver's fit: ok,
  narrowed (scope shrinks to what the receiver may do) or stop (the item cannot
  continue). Permissions are never added automatically. A pot may propose a handover
  (`handover_propose`); the user confirms. Handovers are versioned; applying re-checks
  permissions at that moment. Consents the user gave to the original pot transfer and
  are re-checked before the receiver starts (P8).
- **Archive** (reversible) and **delete** (removes personality, memory and settings):
  first decide a target for each handover item (other pot, user, or none), then show
  what will stop and what will be kept, then apply in this order: hand over, revoke
  permissions, stop the session, archive or delete. Restoring an archived pot does not
  take back handed-over items automatically.
- **Retention after delete**: activity rows and thread messages keep a snapshot of the
  pot's name and avatar until the activity retention period expires.

## Activity and point of view

- Activity kinds: `dm`, `assign` (handoff to another pot), `work_instruction`,
  `file_read`, `thinking_adjust`, `fallback`, `handover_proposed`, `awaiting_confirm`,
  `awaiting_approval`, `forwarded_to_user`, plus lifecycle events. Each row: who →
  counterpart, time, kind, two-line summary, references.
- Queries: by pot, by kind, by time, paginated; retention from `pot_settings`.
- **Point of view** (read only): the threads a pot can see and the messages it sent,
  including instructions sent into work sessions. The user cannot send as the pot.

## Tools (pot mode)

`message_send`, `decision_request`, `work_open`, `work_send`, `work_status`,
`handover_propose`, `remind_me`, `set_autonomy`, `set_thinking`, `budget_status`,
`budget_request`, `memory_note`,
`memory_search`, `observe_note` (L1), `suggest` (to the user), plus the read-only
workspace tools allowed by its scopes and `web_search`/`web_fetch` when enabled.
`delegate`, `delegation_status` and `memory_propose_user` from the assistant are
replaced by `work_*` and the pot memory.

## API sketch

| Method and path                                  | Purpose                                       |
| ------------------------------------------------ | --------------------------------------------- |
| `GET/POST /api/pots`                             | List; create with all four steps' settings    |
| `GET/PATCH /api/pots/{id}`                       | Read; update any section (with `revision`)    |
| `POST /api/pots/{id}/pause`, `/resume`           | Pause or resume                               |
| `POST /api/pots/{id}/retire/preview`, `/retire`  | Archive or delete with item targets           |
| `POST /api/pots/{id}/restore`                    | Restore an archived pot                       |
| `GET/POST /api/handovers`, `POST …/{id}/confirm` | Handovers                                     |
| `GET/POST /api/threads`, `GET …/{id}/messages`   | Threads and paged messages                    |
| `POST /api/threads/{id}/messages`                | User sends (mentions, `all`)                  |
| `GET /api/activity`                              | Activity with filters                         |
| `GET /api/pots/{id}/view`                        | Point of view                                 |
| `GET /api/model-approvals`, `POST …/{id}/answer` | Model approvals                               |
| `GET/PATCH /api/pots/settings`                   | Owner-wide caps, exhaustion policy, retention |

Live updates use the existing `/api/events` stream with new change kinds (`threads`,
`activity`, `pots`, `approvals`).

## Removed by M4

Assistant chat mode and its prompts (`SOUL.md`, `CHAT.md`, `/api/assistant/*`), the
single-assistant claim semantics, assistant-only chat projects, the model-free pots
tracker (`crates/pirc-gateway/src/pots`, node `pots.rs` once its dispatch ledger is
reused or replaced) and their clients' pages.

## Acceptance cases

Each invariant has at least one negative test. Additional cases:

- A group message without a mention wakes only the host; `@pot` wakes one; a pot's
  attempt to address everyone is refused; user `@all` wakes every member.
- A DM blocked by either side's rule is refused and logged; nothing is delivered.
- A chain A→B→C→… stops at the depth limit with a visible notice; parallel children
  cannot overspend the root.
- Two pots observing one event: two L1 rows, one L2 notification, one L3 dispatch.
- Handover to a pot without the needed location marks the item "stop" and does not
  grant the location.
- An `ask` model is not used until "allow once"; a second start needs a new approval.
- A pot changes its autonomy interval; the change is logged; an off interval means no
  reviews.
- A paused pot receives no wakes; its running work continues; resuming delivers
  queued, unexpired wakes.
- Delete applies handover, then revocation, then removal; memory is gone; activity
  keeps the name snapshot until retention expiry.
