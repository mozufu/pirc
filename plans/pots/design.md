# pots product design

[pots](README.md) · [Acceptance cases](acceptance.md) · [Unified conversations](../unified-conversations.md) · [Conversation execution contracts](../conversation-execution-contracts.md)

**Completion amendment (2026-11-07):** [C5](../unified-completion-contracts.md#c5-canonical-tasks-and-foreground-routing)
fixes canonical task/attempt mappings and scope/control boundaries;
[C8](../unified-completion-contracts.md#c8-bounded-pots-configuration-and-lifecycle)
adds required configuration, atomic budgets, runtime, causal dedup and notification
lifecycle. These are adopted target contracts, not live grants or new implementation.
Existing P7 cases remain open.

Adopted design, 2026-10-24: the user accepted the
[specification-review recommendations](../unified-conversations.md#accepted-specification-review-recommendations-2026-10-24)
and the [follow-up behavior contracts](../unified-conversations.md#accepted-follow-up-behavior-and-detailed-contracts-2026-10-24).
This file collects the pots parts that used to be spread across the unified-conversation
plan, the execution contracts (former item 7) and the library-extraction plan.
It describes the target. [README](README.md#delivered) lists the subset that
actually exists, and the [user guide](../../docs/guides/pots.md) gives current behavior.

## User requirement (2026-10-24)

pots can observe allowed information and conversation progress, offer opinions,
and dispatch instructions after user authorization. Its messages must be marked as
originating from pots, with permissions configurable in settings.

## Authorities, attribution and notifications

Product name supplied by the user: **pirc pots** (personal assistant).
Planned presentation: one stable assistant entry point with an overview,
pending decisions and task-specific discussion threads. It is not a second
unstructured collection of interchangeable Chat sessions. A continuous persona
must not require an infinite transcript containing every agent's raw output.

Separate these authorities:

- **Observe:** which projects, tasks, calendar/source data and history may be read.
- **Suggest:** create a sourced recommendation without starting its proposed work.
- **Execute:** dispatch, modify, schedule, contact external systems or publish only
  within explicitly granted scope and the existing operation approval policy.

Observation itself has limits: no scanning arbitrary files, accounts or new
sources merely to find something useful. Retrieved content and other agents'
messages remain data, not user permission. Unapproved suggestions expire or stay
pending; silence, dismissal and notification delivery never authorize execution.

pots messages must carry backend-issued actor identity, source responsibility/task,
initiating user request or standing grant, target and scope. Display "From pots"
in the receiving conversation. A text prefix is insufficient: agents must not
be able to impersonate the user or manufacture delegated authority.

Configure observation, conversation reading, suggestions, dispatch/follow-ups,
stop/reprioritize, and notifications separately. User commands or explicit
standing grants authorize dispatch; the ability to watch progress does not.
Revalidate grants at delivery and execution, deduplicate retries, and fence queued
pots instructions after user takeover or project departure. Include loop/depth
and budget limits so bots cannot trigger an endless dispatch cycle.

The backend stores the suggestion, supporting evidence, revision, related tasks
and disposition. Event/rule filters should trigger bounded analysis, with budgets
and backoff, rather than a model continuously rereading every conversation.
Assistant inference runs on an available authorized execution service; a Gateway
alone is not an agent runtime. Show unavailable/stale status when it cannot run.

Notification categories (adopted treatment; exact timing settings remain open):

| Category                                               | Default treatment                                            |
| ------------------------------------------------------ | ------------------------------------------------------------ |
| Decision required, blocker or user-marked urgent event | Prompt notification subject to the user's preferences        |
| Ordinary completion or useful nonurgent suggestion     | Group in a digest/inbox                                      |
| Tool progress or unchanged state                       | Update the task silently                                     |
| Dismissed or snoozed suggestion                        | Stay quiet until the chosen time or a material new condition |

Include per-category controls, quiet hours, deduplication and a visible reason
for each suggestion. Proactive monitoring/analysis has a configurable budget and
can be stopped independently of ordinary chat. Exact numeric limits, quiet-hour
windows and digest cadence remain to configure; the policy itself is adopted.

## Reference capabilities: dots and Grok Bot

Official sources checked 2026-10-24 at the user's request. These describe external
product behavior; the pirc choices below are our proposals, not their internals.

- [OpenAI dots](https://learn.chatgpt.com/docs/dots): ongoing responsibility across
  conversations, background work, remembered context, delegated tasks and results
  or decisions brought back to the user. This supports a persistent pots identity
  with separate task contexts rather than one unlimited mixed transcript.
- [Dots controls](https://learn.chatgpt.com/docs/dots/controls): proactive research
  is read-only; later actions follow instructions, permissions and approval rules.
  Use this distinction when defining pots observation and dispatch grants.
- [Grok Bot](https://docs.x.ai/grok-bot/overview): persistent execution resources,
  parallel agents, direct handoffs and work continuing when clients are closed.
  Its documented shared computer/browser model is not a requirement for pirc;
  project mounts, private state and browser access retain explicit boundaries.

Proposed pots first scope: one personal assistant identity, task-specific threads,
scoped observation, event/scheduled wake-ups, durable suggestions, quiet digests,
explicitly attributed dispatch and user takeover. Voice, external messaging
channels, multiple named assistants and full computer-use capability are possible
later scope decisions, not implied by these references.

A persistent responsibility is distinct from a task: for example, "watch this
project for blocked work" can have bounded ongoing observation, while each
accepted repair becomes a task with a finish condition. Both need pause/revoke
controls, budgets and durable wake-up state. An always-on service need not keep
an LLM generating continuously. Required Gateway and execution Nodes still need
to be online; closing Web/App must not own their lifetime.

## Coordination contract

### Entry points and durable records

pots has one assistant identity with an overview/inbox and ongoing responsibilities.
Its main input can answer a question, refine a responsibility or initiate a task.
An accepted work suggestion links to the same canonical task and source conversation
used elsewhere. Opening it from pots, a project, a notification or the App changes
the view, not task ownership or the number of work conversations.

Separate a task's immutable origin (user message or pots responsibility/suggestion),
record owner and optional execution-conversation binding. A tracking-only task can
exist without an execution conversation or attempt. Reopening/accepting it for
tracking does not create an empty session. On the first authorized dispatch, reuse
the explicitly selected conversation or create/map one through the idempotent
first-message flow. Retrying Start returns that same mapping. An origin link alone
does not confer ownership for deletion or authority for execution.

Coordination history may record the user's request and task links, but must not
mirror every worker message into a second independently actionable work transcript.

| Record         | Minimum facts and purpose                                                                                                                                      |
| -------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Responsibility | User owner, purpose, observed scopes, separately granted actions, triggering policy, configuration revision and pause/budget state                             |
| Observation    | Authorized source IDs/revisions, observed time, freshness and trigger; retrieved content is evidence, not a new instruction                                    |
| Suggestion     | Stable identity, material condition, evidence references, proposed target/action, current revision and pending/snoozed/dismissed/superseded/linked disposition |
| Task link      | Canonical task/conversation, originating suggestion/request and any existing target; created atomically with acceptance reconciliation                         |
| Dispatch       | Backend-issued pots actor, user request or standing grant, target task/attempt, directive/binding/grant generations and idempotency identity                   |
| Notification   | Reference to the durable suggestion/task/decision, delivery/read/dismissed state and reconciliation revision; never authority to act                           |

### Observe, suggest, accept and report flow

1. **Observe within scope.** Filter events by current observation grants before
   accessing content or calling a model. A progress-read grant does not authorize
   reading complete transcripts, files or external accounts. Coalesce routine tool
   progress; use event/scheduled wake-ups and budgets instead of continuous polling.
2. **Evaluate relevance.** Record the evidence and its freshness. Verify the material
   condition still holds and check whether the same actionable issue already has
   a suggestion/task. Stale evidence can produce a needs-refresh state, not a
   fabricated current fact. Untrusted source text never changes pots permissions.
3. **Persist a suggestion.** Show why it matters, the intended target/action and
   what would require permission. Persist the item before notification delivery.
   Ordinary results/suggestions use the inbox/digest; decisions, blockers or events
   marked urgent follow notification preferences. Unchanged state remains quiet.
4. **Choose an explicit action.** Opening or reading is not acceptance. Dismiss and
   Snooze do not dispatch. A tracking-only action creates/links a proposed task
   without starting it. A clearly labelled Start action uses the user's specific
   instruction and current grants; ask only for missing scope/required approval,
   not an extra generic confirmation of an already authorized action.
5. **Create/link once.** Accept against the current suggestion revision and atomically
   reconcile its task link. Two devices accepting with different command IDs must
   still return one task for that suggestion's accepted objective. A materially
   changed action/target requires review rather than inheriting the old acceptance.
6. **Dispatch with attribution.** Recheck execution grants, current task control,
   workspace readiness and effect policy. The target receives a backend-attributed
   “From pots” instruction carrying its actual authority. Worker results return to
   the task and item 2's response flow; no forged user quote or authority from a label.
7. **Report a meaningful outcome.** Link deliverables, blockers or required decisions
   without copying all tool events into pots. Required child/background work must
   finish before completion; explicit user acceptance remains Ready for review.
   Opening the result does not automatically accept it or resume coordination.

Record the displayed action/target and accepted revision as the user's scoped
instruction. Extra model-written details are not automatically part of that
instruction, and an attributed approval must not be forged as a direct user quote.

A user-authorized standing responsibility may dispatch without a new suggestion
acceptance only within its recorded execution scope. Observation/suggestion
permission alone never enables this. Existing operation approval policy still
applies at the destination. A changed grant narrows subsequent dispatch; no agent
may grant itself permission or produce a mutual-dispatch loop to evade limits.

### Distinct controls and their scope

| Control                                                   | New pots activity                                                                                               | Already-running work                                                               |
| --------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| Pause observation for a responsibility                    | Stop new analysis/content fetches in that scope; keep existing items readable under current rights              | Independent tasks continue; no invented fresh observations                         |
| Pause new coordination for a task/responsibility/all pots | Fence pending/new pots dispatch and follow-ups in the selected scope                                            | Already delivered authorized tasks continue; UI says they are still running        |
| Take over task                                            | Fence conflicting queued pots directives for that task and its scoped children; route the user's input directly | Do not silently kill tools; unrelated responsibilities continue                    |
| Stop task                                                 | Fence new work and request host cancellation/reconciliation of that execution scope                             | Show stopping until workers/descendants are acknowledged; preserve partial effects |
| Revoke a resource/action grant                            | Reject subsequent affected effects and apply live revocation where necessary                                    | Reconcile affected workers; unrelated authorized work stays separate               |
| Resume coordination/observation                           | Revalidate current settings, grants, evidence and target before new activity                                    | Does not replay missed directives or restart an explicitly stopped task            |

Expose these distinctions in both clients; an ambiguous “pause pots” action must
state which scopes and effects it changes. Merely viewing a task is not takeover.
A user correction follows item 2; a conflicting pots instruction cannot overrule it.
If takeover races dispatch, persist their ordering/generations: queued stale
instructions are rejected; already-applied effects are reported and reconciled,
not described as prevented. Taking over one task does not grant pots access to
other conversations, and resuming pots elsewhere does not release that takeover.

### Quiet operation, failure and recovery

- **Deduplication:** repeated source events update the same material condition;
  timestamps/retries alone do not create a new suggestion. A dismissed item remains
  quiet until a meaningful condition changes. Snooze waits for the chosen time and
  rechecks relevance/authority then. A new occurrence of a recurring responsibility
  can be distinct, but its occurrence identity must be explicit; do not suppress
  all future work or resend the same occurrence repeatedly.
- **Adopted activation:** observation starts only for user-selected scopes, with
  progress/content rights separate. Suggestions do not imply dispatch authority.
  Require finite configured budgets and bounded concurrency before proactive work;
  absent values cannot mean unlimited. Nonurgent suggestions use the digest/inbox.
- **Budgets:** track observation and dispatch usage under their scoped configured
  limits, including concurrent workers. Reserve/check budget before new costly
  work; exhausted/unknown accounting blocks new discretionary analysis/dispatch
  with one useful status. It does not silently terminate unrelated user work or
  authorize a fallback provider/spending increase. Numerical defaults stay open.
- **Availability:** backend events/tasks persist with Web closed or App suspended.
  If the authorized agent runtime is unavailable, record pending/stale status and
  coalesce wake-ups; Gateway alone does not manufacture agent results. Reconnect
  reconciles current state before invoking queued observation or dispatch.
- **Changed evidence or permission:** recheck on acceptance and at effect time.
  Revoked/deleted sources become unavailable; remove known managed suggestion/
  notification previews covered by deletion. Do not quote formerly accessible
  private data into a new task to keep using it after revocation.
- **Lost responses/duplicate events:** reconcile the stable suggestion/task/dispatch
  identity. Unknown outcomes do not trigger another task, instruction or external
  effect; late results stay attributed and cannot restart stopped work.
- **Notification limits:** delivery failure does not lose the canonical item.
  Reading, dismissing a delivery, dismissing a suggestion and resolving a decision
  are different actions. One resolved decision disables other devices' stale
  actions when they synchronize; tapping an old push checks the current outcome.
- **No cascading authority:** a board message, worker result or other bot's request
  may inform a suggestion, but cannot become a new user instruction. Preserve
  delegation lineage and bounded loop/depth/concurrency policy at every dispatch.

The activation policy is adopted; exact quiet hours, digest cadence and budget/
concurrency/depth numbers still require concrete settings. User-selected scopes
and standing grants must be explicit; approval of the plan does not grant access
to every project or authorize autonomous dispatch across all conversations. Native sign-in
and real background push delivery retain their separate design/acceptance gates.

## Policy still to specify

The pots grant matrix, instruction precedence, budget accounting and the lifetime of
recurring responsibilities remain open. See
[specification review item 6](../unified-conversations.md#6-pots-authority-instruction-conflicts-and-attention-budget--user-policy)
and the “pots triggering and bounded execution” gate in the
[architecture review](../unified-architecture-review.md#engineering-specifications-and-proof-gates-still-missing).
