# pirc pots

[Plans](../README.md) · [Product design](design.md) · [Acceptance cases](acceptance.md) · [User guide](../../docs/guides/pots.md) · [Library extraction](../library-extraction.md)

> **Superseded 2026-11-16 (N6):** pots are several named pot identities under one owner, each with its own responsibilities, observation scope and permissions, not one owner-scoped identity. See [2026-11-16 direction update](../README.md#direction-update-2026-11-16).

**pirc pots** is the user's persistent personal assistant: one owner-scoped identity
that observes allowed progress, records sourced suggestions, tracks tasks and, only
when the user authorizes it, dispatches attributed instructions. This folder holds
the remaining pots work. Current behavior lives in the [user guide](../../docs/guides/pots.md);
the host/library boundary lives in [Reusable LLM foundations](../../docs/architecture/reusable-llm.md#unreleased-pots-execution-boundary).

| File                           | Contents                                                                                               |
| ------------------------------ | ------------------------------------------------------------------------------------------------------ |
| [README.md](README.md)         | Authorization, what is delivered, known risks and the remaining work queue                             |
| [design.md](design.md)         | Adopted product design: authorities, records, observe/suggest/dispatch flow, controls, quiet operation |
| [acceptance.md](acceptance.md) | P7-1 to P7-9 acceptance cases with their current local evidence                                        |

## Authorization

The bounded tracking/dispatch/Stop checkpoints are implemented. Later staged
architecture authorization includes bounded pots design/work but is not a runtime
grant to observe actual content, dispatch, spend or notify. The latest user
instruction and goal state govern execution; this round is planning-only and
leaves the implementation goal paused. Do not ask again for adopted architecture
choices or infer deployment/publication permission from this queue.

[C8](../unified-completion-contracts.md#c8-bounded-pots-configuration-and-lifecycle)
now specifies scopes, runtime/provider, accounting, causal dedup and inbox
lifecycle; [C0](../unified-completion-contracts.md#c0-authority-current-snapshot-and-scope)
tracks implemented versus accepted. Concrete values/grants remain configuration
gates. Missing configuration keeps the affected proactive work disabled.

## Delivered

The checkpoints below are implemented in the fetched mainline. Tracking shipped
in v0.10.0; dispatch and its follow-up are unreleased. Implementation does not
establish deployment, device acceptance or a finished autonomous assistant.

### 1. Tracking (`24abca5e`, shipped in v0.10.0)

- Gateway schema **1010**: owner-scoped responsibilities, a durable suggestion
  inbox and canonical tracking tasks.
- Observation needs explicit activation, 1–32 selected workspaces and three finite
  lifetime limits (observation budget, dispatch budget, concurrency). A missing
  value never means unlimited.
- Only session-progress events feed it. The single generic suggestion is
  “Session needs your input”. No model calls, transcript reads or file reads.
- Deduplication is atomic: repeated events, reconnects and overlapping
  responsibilities share one issue and charge quota once.
- Dismiss, Snooze and Track only are separate actions. Two devices tracking the
  same suggestion get one task.
- Controls are durable: pause/resume observation, pause/resume coordination,
  take over, stop. Source revocation and expiry are checked on reads and acceptance.
- Each owner has at most 100 responsibilities, 100 suggestions and 100 tasks.
- Web and native Android have overview, inbox and task views.

### 2. Explicit controlled dispatch (`d4f1efbd`, unreleased)

- Upgrade fence: Gateway schema **1011**, Node schema **2003**, Node protocol **15**.
  Back up both states and upgrade Gateway and Nodes together.
- **Start** takes a written instruction (1–20,000 UTF-8 bytes). It creates one
  dedicated execution conversation in the same workspace. Each task gets one
  dispatch for its lifetime. Start never copies the source transcript and never
  answers the source interaction.
- Gateway reserves atomically (`reserve_start_task`) and binds the session before
  Node delivery. `authorize_dispatch` rechecks authority, budgets, controls,
  evidence expiry and the source runner epoch immediately before sending.
- The instruction arrives as a host-created **From pots** message. Prompt text and
  client-supplied labels cannot mint that attribution.
- Node keeps a durable send ledger and is fail-closed **at-most-once**. A crash
  after the send claim yields `dispatch_uncertain`; nothing resends it automatically.
- Progress and the redacted, bounded outcome are recorded. Takeover fences unsent
  work. Stop ends only the dedicated session, never the source conversation.
- Restart recovery observes and cancels. It never replays Prepare/Start or revives
  stopped work.
- Web and native Android have instruction entry, execution navigation/controls,
  en/zh-TW strings and a trusted pots-dispatch timeline entry.

Verification details, including exact test counts, are in the guide's
[verification section](../../docs/guides/pots.md#explicit-execution-checkpoint-verification).

### 3. Stop ownership, archive and fence paging (`6d87f97f`, unreleased)

Authorized by the user on 2026-10-26 as queue items 1 and part of 4. No schema
change; Node protocol stays **15** but gains the `Release` control, so Gateway
and Nodes must still be upgraded together.

- **Stop is tied to pots ownership.** The execution conversation refuses ordinary
  input until the Gateway releases it: on explicit takeover (`Release`), or once
  the task is terminal (retried by the recovery sweep). Pause and revocation still
  send the fence-only `TakeOver`, so delivered work stays stoppable. Stop stops the
  session only while pots still owns it, and keeps it reserved (`stopping`) until
  the stop completes; after release it only ends the task. An unknown send is
  stopped, never released.
- **Archive.** Responsibilities, suggestions and tasks gain an irreversible
  `archive` action. Archived records leave lists and the 100 caps but stay stored
  for deduplication and idempotency. Rules are in the
  [user guide](../../docs/guides/pots.md#limits-and-remaining-work).
- **Revocation fence paging.** `fence_invalid_pending` now pages by task id
  instead of stopping at 100 rows.

Verification: [guide](../../docs/guides/pots.md#stop-ownership-and-archive-follow-up-verification).
In short, the focused gates passed: Gateway 202 (46 pots), Web 452, Android 35
pots/timeline, 23 conformance cases across 7 suites, and strict clippy. The full
sandboxed Rust workspace run still fails 2 Linux Node socket-enumeration tests
(not shown to be caused by pots). Full conformance was not rerun.

## Known risks in the delivered code

Both review findings are addressed by checkpoint 3 above:

1. **Stop was not tied to a specific run** (it could abort user work started in
   the dedicated session after pots' run finished). Fixed by refusing ordinary
   input until release, rather than by correlating Stop with a run ID.
2. **"Restart reconciliation is capped"** was imprecise. The 30-second recovery
   sweep already paged by id. The unpaged `LIMIT 100` was in
   `fence_invalid_pending`, which now pages too.

Remaining consequence of the fix: a pots-owned execution conversation is
read-only to ordinary input until takeover or the end of the task. If a Node
never comes back, its terminal tasks keep being retried by the sweep.

## Remaining work queue

Roughly in dependency order. Use the current authorized stage and goal state;
the queue itself grants nothing. C8/C10 provide the completion requirements;
implementation and real P7 acceptance remain open.

1. ~~**Close the known risks** above, with regression tests.~~ Done in checkpoint 3.
2. **Verification debt:** a full conformance run, real browser and Android device
   journeys for tracking and Start, and an APK install. Resolve or classify the 2
   Node socket tests outside the sandbox (requires approval).
3. **Configuration values:** concrete defaults for budgets, concurrency and depth,
   plus quiet hours and digest cadence. The policy is adopted; the numbers were
   never chosen ([design](design.md#quiet-operation-failure-and-recovery)).
4. **Inbox lifecycle:** archive is done (checkpoint 3). Still open: cursor
   pagination, automatic retention or hard deletion, unarchive, and a budget
   edit/reset workflow.
5. **Content observation grants:** per-scope read-progress versus read-content.
   This must happen before any transcript- or file-aware suggestion.
6. **Bounded proactive analysis:** event and scheduled wake-ups with budgets and
   backoff, and an observer model running on an authorized execution service. No
   continuous polling.
7. **Digests and pots push:** grouped nonurgent items, a durable inbox ahead of
   push, and stale-push reconciliation (P7-8).
8. **Dispatch scope:** standing execution grants, dispatch into an existing or
   selected conversation, cross-workspace targets, and explicit retry semantics
   for failed attempts.
9. **Full P7 acceptance:** see [acceptance.md](acceptance.md). Focused tests do not
   close any case.

Prerequisites shared with other plans: durable tasks/decisions and grant
generations from [Unified conversations](../unified-conversations.md) stages B–C,
and real resource revocation from
[Conversation execution contracts](../conversation-execution-contracts.md).
The reusable loop must stay free of pots identity, grants and storage; see
[Library extraction](../library-extraction.md#combined-direction).
