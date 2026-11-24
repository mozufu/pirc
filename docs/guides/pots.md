# pots: bounded progress suggestions and tracking

[User guides](README.md) · [Library boundaries](../architecture/reusable-llm.md) · [Remaining plan](../development/historical-records.md#retired-plans-2026-11-24)

## Current checkpoint

pots has a personal, owner-scoped overview, responsibilities, a durable suggestion
inbox and tracking tasks with optional explicitly authorized execution. The Web sidebar and native Android navigation open
**pots**. Both clients expose written-instruction Start and tracking views; APK installation,
physical-device and push acceptance remain open. These are locally implemented staged changes, not a
deployment or a completed autonomous assistant.

**Autonomous execution is unavailable.** Reading, tracking, budget configuration
and resuming coordination never dispatch. The unreleased explicit Start flow is
available through `executionAvailable: true`: enter a specific instruction and
choose Start for that task. It does not interpret a generic “session needs input”
suggestion as permission to answer the source interaction.

## Explicit Start, progress and results

1. Activate the responsibility and explicitly resume its coordination. Supply a
   positive remaining dispatch budget and an available concurrency slot. Observation
   permission alone never dispatches.
2. Track a current suggestion, then write the exact instruction you authorize
   (nonblank, at most 20,000 UTF-8 bytes). Start creates a **new dedicated execution
   conversation in the same workspace**. No source transcript, interaction prompt
   or approval answer is copied. Referencing an inaccessible source is not a grant.
3. Start rechecks source ownership/binding/freshness, workspace availability,
   responsibility/task controls and budgets. Gateway binds the execution session
   before Node delivery. The destination still applies its normal tool/approval
   policy. The instruction is a backend-created **From pots** custom message, not
   a forged direct user message; arbitrary prompt text/actor labels cannot mint it.
4. Follow Starting, Queued, Running, Waiting input and terminal status in pots;
   open the execution conversation to answer its own approvals and see full output.
   A redacted, bounded final answer is recorded as the outcome. Completion describes
   the execution run, not user acceptance of the deliverable. Internal background
   messages remain part of the execution; later ordinary user/external input makes
   attribution ambiguous and is not reported as a pots result.

There is one lifetime dispatch per tracking task. Concurrent devices and retries
with different command IDs return the same accepted instruction/session; changed
instructions conflict. A new objective requires a new task, not silent reuse of
an old acceptance. Failed attempts consume their reserved dispatch budget.

The Node durably claims a send immediately before agent RPC. A crash after that
claim can leave delivery uncertain; it is **at-most-once, not lossless exactly-once**.
Neither client nor recovery automatically replays execution. Unknown delivery
retains Starting and its concurrency slot until Node status/Stop reconciles it.
Gateway restart between reserve/prepare/start fences unfinished preparation rather
than silently restarting it. Progress uses coalesced runtime events and a slow
recovery sweep while clients are closed; there are no observer model workers.

The dedicated execution conversation belongs to pots until you **take over** the
task or the task ends. Until then it refuses ordinary input (prompts, follow-ups,
model/approval changes and scheduled or delegated deliveries) with
`pots_dispatch_reserved`; it still accepts answers to its own approvals and
questions, and its own Stop. This keeps pots' Stop from aborting work you started
there: Stop can only end the session while pots alone has used it.

- **Take over** fences undelivered work and hands the conversation to you. It
  does not abort already-delivered execution; that run continues and you stop it
  from the conversation itself. A later pots Stop then only ends the task in pots
  (the button reads **Stop tracking**); it never stops the conversation.
- **Pausing coordination** or a revoked grant only fences pots. Delivered work
  stays pots-owned, so Stop still stops it.
- When the task becomes terminal, Gateway hands the conversation back to you.
  This is retried by the recovery sweep while the Node is offline. A send whose
  outcome is unknown is never handed over: it is stopped instead.
- Stop stops only that dedicated execution session, never the original source.
  The conversation stays reserved until the stop completes. An offline Stop stays
  **Stopping** until confirmed; reconnect does not resume it.
  Completed/stopped tasks cannot be restarted by Start or coordination Resume.
  Node checks immutable evidence expiry at the final send claim. Host control changes
  are propagated as Node fences; a command already delivered before a fence is not
  claimed to have been prevented. This is not OS-level project-mount revocation.

Back up both states before upgrading: unreleased Gateway schema **1011**, Node
schema **2003**, Node protocol **15**. Update Gateway/Nodes together. These changes
are not part of the original 0.10.0 tracking-only release.

## Configure and explicitly activate

1. Enter a purpose and select the workspaces to observe. There is no implicit
   “all workspaces” grant. Select between 1 and 32 distinct available workspaces.
2. Supply all three finite limits. Nothing omitted means unlimited:
   - **Observation budget:** 1–1,000,000 distinct sourced issues, over the
     responsibility's lifetime.
   - **Dispatch budget:** 0–1,000,000. Zero records that dispatch is disabled;
     positive values permit only an explicitly authorized Start with current controls.
   - **Concurrency limit:** 1–32. This caps reserved/in-flight executions. There are no background observer model workers.
3. Choose **Save disabled responsibility**. Saving does not begin observation.
4. Review the selected scopes and limits, then choose **Activate observation**.
   Observation and coordination are separate controls; coordination starts paused.

Only **session progress events** are supported. A currently authorized pending
interaction may produce the generic suggestion **Session needs your input**.
Ordinary tool progress stays quiet. pots does not read transcripts, inspect files,
call a model, answer an interaction or synthesize a repair plan through this flow.
Purpose text describes the responsibility; it is not a new execution grant.

Budgets do not reset when you pause, disable, resume, refresh or restart Gateway.
A repeated issue, delivery retry or reconnect does not spend another observation.
Overlapping responsibilities share one issue; its first recorded responsibility
owns the provenance and quota charge. At exhaustion, new items are skipped without
model calls, fallback spending or interrupting unrelated sessions. Used/configured
counts remain visible. There is no automatic replenishment or budget-edit/reset
operation in this checkpoint.

## Reading, deciding and tracking are different

| Action                         | Current effect                                                                                                             |
| ------------------------------ | -------------------------------------------------------------------------------------------------------------------------- |
| Open pots or read a suggestion | Read the authoritative record; no acceptance, takeover or dispatch.                                                        |
| Review source conversation     | Navigate to the existing source session; its normal access checks still apply.                                             |
| Dismiss                        | Keep that occurrence quiet. A replay cannot restore it to pending.                                                         |
| Snooze                         | Persist a chosen wake time. Web currently offers one hour. It does not dispatch or automatically accept when time elapses. |
| Track only                     | Atomically create/link one canonical task for the suggestion, without an execution session or run.                         |
| Start                          | Authorize the written instruction once in a new dedicated same-workspace execution conversation.                           |

Two devices tracking the same current suggestion, even with different command IDs
or a lost response, receive the same canonical task. A stale revision instead
requires refreshing and reviewing the current record; the client does not silently
retry a changed decision. A tracking task records its immutable originating
suggestion and accepted action/target separately from its owner and optional
execution-session binding. The binding remains empty until explicit Start.

Snooze is not a freshness extension. While snoozed, Track is blocked until the
chosen time; afterwards the source, binding and expiry are still checked. An
expired or answered request, or a runner lifecycle change, makes an unlinked
suggestion `superseded`; a linked suggestion becomes `needs_refresh`. This does
not complete its task, revive dismissed work or claim the original issue remains
current.

## Controls have different scopes

| Control                                    | What changes                                                                                                                             | What does not change                                                                                      |
| ------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| Pause observation / Disable responsibility | Stop new observations and evidence refreshes for that responsibility.                                                                    | Existing records are not erased; independent sessions are not stopped.                                    |
| Pause coordination                         | Persist a fence against future pots coordination in that scope.                                                                          | Already delivered authorized execution can continue; no new dispatch is implied.                          |
| Resume observation / coordination          | Change the corresponding durable control.                                                                                                | Do not replenish budgets, replay suppressed events or restart stopped tasks.                              |
| Take over task                             | Fence that task's pots coordination with a new control generation; open its execution conversation to your input.                        | Do not kill already-delivered tools, complete the task or take over another task.                         |
| Stop tracking / Stop execution             | Fence coordination; for a pots-owned execution, stay Stopping until its dedicated session is stopped. After takeover, end the task only. | Do not cancel or kill the source conversation's runner, or anything you run in a taken-over conversation. |
| Archive                                    | Remove a finished record from lists and the per-owner cap. Irreversible.                                                                 | Do not delete it: it still deduplicates its occurrence and keeps its idempotency key.                     |

Taking over or stopping one task does not affect unrelated responsibilities or
tasks. Resuming coordination elsewhere cannot release a takeover. There is no
implicit resume of a stopped/taken-over task.

## Privacy and freshness

Suggestion evidence stores identifiers and revisions only: workspace, source
session, interaction ID, Gateway binding epoch and expiry. No source transcript,
interaction prompt, session title or model-written instructions are copied into
pots. The **From pots** attribution is a host-created record, not authority that a
board post, prompt or client-supplied label can forge. There is no REST endpoint
for injecting an observation or suggestion.

Gateway checks current workspace availability/private visibility, source-session
ownership and its current binding when ingesting, listing, opening or accepting
sourced items. Removed/deleting/checking workspaces and unavailable/foreign sources
cannot supply actionable suggestions. Unauthorized records are hidden as 404;
lists omit inaccessible sourced suggestions/tasks rather than expose previews.
Expiry is checked on reads and acceptance, without requiring a browser timer.
Reconnect refreshes the same occurrence only through a newly authorized host event;
it preserves dismissal, snooze and task links and cannot extend the old expiry.

Records and controls persist in Gateway SQLite while clients are closed. Web
refreshes on opening/focus and after commands and offers explicit Refresh. Android
uses the existing paired transport, refreshes on resume and clears records/drafts
on re-pairing or account changes; late replies cannot restore the old account.
Neither client persists pots snapshots in a client data cache; responses use no-store. This is
not a claim of mobile push reconciliation, offline execution or deletion of old
backups/copies.

## Limits and remaining work

Each owner has at most **100 responsibilities, 100 suggestions and 100 linked
tasks** that are not archived; list requests are capped at 100 and omit archived
records. A full suggestion inbox stops new issue creation without spending extra
quota. **Archive** frees a slot:

- a suggestion once it is dismissed or superseded and not tracked;
- a task once it is completed, failed, interrupted or stopped, together with its
  origin suggestion;
- a responsibility once it is disabled and none of its executions is still
  running. Its suggestions and tasks are archived with it, including ones hidden
  because their source was revoked, and its tracking-only tasks are stopped.

Archived records stay stored: a replayed event for an archived occurrence stays
quiet, and replaying a create request returns the archived responsibility. There
is no unarchive, cursor pagination, automatic retention, hard deletion or
budget-edit/reset workflow yet.

Still absent: transcript/content observation grants, periodic or model-driven
analysis, digests and dedicated pots push delivery, standing execution grants,
cross-workspace or existing-conversation dispatch, execution retries, and the full
P7 cross-client/runtime acceptance cases. Real browser/device journeys
still require verification; synthetic Web/backend/Android tests do not close those
gaps. Local browser acceptance was blocked by the operator setting
`PIRC_BROWSER_ALLOW_PRIVATE`; no alternate route was used.

## Stop-ownership and archive follow-up verification

Local sandboxed verification of the uncommitted follow-up to `29178481`:

- Gateway: 53 pots tests, including release on terminal tasks, pause versus
  takeover controls, archive rules and the revocation fence paging past 100
  pending tasks. Node: 12 pots ledger tests, including input refused until
  release, Stop after release leaving the session alone, and a Stop racing a send.
- Conformance with rebuilt debug binaries: 24 cases across `pots` (4, including
  the new Stop-after-takeover scenario), `agent_loop_order`, `delegations`,
  `message_edit`, `node_sessions`, `node_side` and `project_deletion`.
- Web: 61 files / 453 tests and a clean Svelte check. Android: 27 pots tests and
  the i18n test; changed files analyze clean.
- Workspace formatting and strict all-target clippy passed.

In this sandbox the Node library also fails three persistence tests
(`Persistence request refused`) besides the two socket-enumeration tests below.
They fail identically with the pots changes stashed. A full workspace run, full
conformance and device/browser acceptance were not repeated.

## Explicit-execution checkpoint verification

Local verification on the uncommitted follow-up to `3615ae3b`:

- Gateway: 202 tests; 46 pots tests include 9 orchestration regressions for
  bind-before-send, no replay, uncertain/restart recovery, control fences and
  revoked-source result hiding.
- Node: 8 dispatch-ledger tests plus the reserved-provenance HTTP regression;
  protocol: 23 tests.
- Real fresh debug Gateway/Node/agent processes with fake inference: 23 executable
  conformance cases across 7 suites, including 3 pots scenarios (concurrent Start,
  completion/privacy, dedicated-only Stop and running takeover). The Node-link
  snapshot changed only the intentional protocol number 14 → 15.
- Web: 61 files / 452 tests, clean Svelte check and production build (existing
  large-chunk warning). Android: 35 focused pots/timeline widget tests; native
  Kotlin timeline unit tests also passed. No physical-device/APK journey.
- Workspace formatting and strict all-target clippy passed.

The full sandboxed `cargo test --locked --offline --workspace` exited 101 at the
Node library: 369 passed, 2 failed, 3 ignored. Both failures are in Linux host Unix
socket enumeration (`host_unix_sockets_are_the_listed_sockets_but_the_allowed`,
`host_rules_hide_bound_sockets_but_the_allowed`); this run did not establish a
clean full-workspace gate or prove baseline causation. An outside-sandbox rerun
was not approved and was not performed. No safety assertions were relaxed. Full
executable conformance was not rerun; focused passes do not close full P7 or real
browser/device acceptance.

## Historical tracking-checkpoint verification

Local focused verification passed `cargo test -p pirc-gateway pots::`: 22 tests
(19 store, 2 HTTP/host tests and a 1009-to-1010 migration test). Coverage includes persistent controls/reopen,
concurrent acceptance/create/quota reservations, rollback on insert/link failures,
strict input rejection, owner hiding, source revocation/expiry, overlapping-scope
and reconnect deduplication, and no execution session on tracking/Start.
Gateway-only strict clippy passed with `--all-targets --no-deps -- -D warnings`.
The enclosing Gateway suite also passed all 178 tests, including the additional
1009-to-1010 migration regression. These focused passes do not imply a clean full
workspace or executable-conformance gate.

Web verification passed 61 test files / 436 tests, including 14 pots cases,
Svelte check (zero errors/warnings), production build and formatting. The build
retains the existing large-chunk warning. Android verification passed 31 focused
and existing regression tests (11 new pots tests), including phone/tablet widget
layouts, pairing/account fences and no POST replay; changed-file analysis and
formatting passed. These are widget tests, not pixel/screenshot or installed-APK
acceptance. No live-provider login, pots dispatch,
physical-device acceptance, deployment or crate publication is established here.
