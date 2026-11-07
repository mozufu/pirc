# Transition revocation and installation (U4 step 3)

[Plans](README.md) · [Unified conversations](unified-conversations.md) · [Execution contracts](conversation-execution-contracts.md) · [Execution isolation](execution-isolation.md)

Status: **design adopted on 2026-11-06**, not implemented. The user chose this
stream after the terminal execution-path work and decided the three product
questions below. This document turns the adopted transition model
([state table](unified-conversations.md#1-live-transition-failure-and-recovery--foundational))
into bounded slices on top of what exists: Gateway previews, observations and the
accepted-intent journal (schema 1028), Node admission fences, preflight evidence,
tracked drain and the `stop_transition` command (Node 2020), and the per-resource
journals (sandbox launches, host commands, terminals, browser groups, native
proxy). Today every receipt reports `revocation_confirmed: false` and
`target_installed: false`. Public confirmation returns
`transition_coordinator_unavailable`.

## User decisions (2026-11-06)

1. **Unprovable evidence needs an explicit, retained acknowledgement.** Some
   source records can never prove that access is gone: host-management commands
   and terminals (detached host work may survive), and launches from before the
   journals existed. The preview lists each one. The user acknowledges them for
   this one transition only. The acknowledgement is retained, never marks a record
   closed, and the result says "switched; revocation not fully confirmed" instead
   of "revoked".
2. **Hosts without kernel descendant containment use the same acknowledgement.**
   On macOS and behind external sandbox wrappers, Agent descendants cannot be
   proven stopped. Switching is allowed only after the same explicit
   acknowledgement, and is reported as not fully confirmed. Native Linux with
   captured kernel scopes can reach a fully confirmed switch.
3. **Late cancel may return to the original binding, explicitly.** After the
   source was drained but before installation commits, only an explicit user
   cancel reopens the conversation on its **original** binding, under a new runner
   epoch. Stopped work is not restarted. There is no automatic rollback. After
   installation commits, cancel is gone: switching back is a new transition.

These refine, and do not relax, the existing rules: no silent fallback to
unenforced access, no "removed" success while old authority may be live, no
force-clear, no PID guessing and no replay.

## Scope of the first delivery

- One conversation moves from its current workspace to another workspace that is
  already registered on the **same Node**. The mode must support the target under
  existing checks.
- Excluded: cross-Node handoff, project mounts/rules, additional folders,
  managed-folder allocation, multi-conversation project moves. Each remains a
  later extension of the same stages.
- Context is retained as already decided (decision A); history, memory provenance,
  checkpoints, uploads and peer conversations keep their owners and are not copied
  or moved.

## Node: binding generations and coverage

The journals record rows per session, but the conversation's history may span
several bindings. Revocation is evaluated only for the **current binding
generation**. Rows from earlier generations were judged at their own transition.

- A new retained Node table records `(session, generation, workspace, started_at,
operation)`. Generation 1 is seeded for every existing session at migration;
  each install appends the next generation.
- **Coverage:** sessions that exist at migration get `coverage: legacy`, because
  launches before the journals (and some early journal gaps) cannot be ruled out.
  Sessions created later, and every generation started by an install, get
  `coverage: complete`. Migration invents no outcome and no acknowledgement.
- Journal rows are attributed to a generation by session plus `created_at >=
started_at` and the generation's workspace. A row that cannot be attributed is
  unprovable, never ignored.

## Node: revocation evaluation

After the tracked drain, Node evaluates the current generation and adds a
`revocation` object to the existing transition receipt:

| Field                 | Meaning                                                                                        |
| --------------------- | ---------------------------------------------------------------------------------------------- |
| `status`              | `pending`, `blocked`, `unproven` or `confirmed`                                                |
| `items`               | Bounded list of `{kind, id, reason}` for every blocking or unprovable record (kinds below)     |
| `digest`              | SHA-256 of the canonical sorted `items`; an acknowledgement binds to it                        |
| `confirmsContainment` | Whether this Node backend can prove descendant containment at all (native Linux kernel scopes) |

Rules, from the strictest:

1. **`pending`:** the fence is not yet `supervisor_drained`, or some participant
   is still being observed in this Node incarnation (a live registry entry, a
   tracked drain, a running observer). It cannot be acknowledged; it must finish.
2. **`blocked`:** a record is unresolved but has no live observer: for example a
   `launching`/`running` row from an earlier incarnation, or a failed retirement.
   Recovery paths (I/O owner recovery, kernel reconciliation) may still settle it.
   It cannot be acknowledged.
3. **`unproven`:** every remaining item is one of these acknowledgeable kinds:
   - `host_command` / `host_terminal`: a host-management execution in this
     generation (settled or `unconfirmed`); detached host work may survive.
   - `legacy_history`: the generation's coverage is `legacy`.
   - `platform_containment`: the backend cannot prove containment and the
     generation had any Agent or sandbox launch.
   - `sandbox_launch` / `uncontained_launch` (added in T3b): on a backend without
     containment, a launch row with no kernel identity can never settle, so after
     the drain stopped its runner it is unprovable rather than blocking. Found by
     the first real-process run on macOS; with kernel identity it still blocks.
   - `unattributed`: a journal row that cannot be attributed to a generation.
4. **`confirmed`:** no items. Only reachable when `confirmsContainment` is true or
   nothing ran in the generation.

Isolated work terminals settle through their kernel scopes and add no item when
settled. Browser groups and native proxy scopes must be closed (no item kinds for
them: unresolved means `blocked`). The evaluation is a read of retained evidence.
It closes nothing and changes no record.

## Acknowledgement, install and release (Node)

Three new operations on the existing transition route family, each bound to the
retained fence (owner, session, operation, plan hash), the current control lease,
and idempotent per operation:

- **Acknowledge** `{digest}`: allowed only while `status` is `unproven` and the
  digest matches the current evaluation. It retains the digest, the items, the
  acting client and time. If the item set later changes, the digest no longer
  matches and a new acknowledgement is needed. It does not close any record.
- **Install** `{targetWorkspaceId}`: in one SQLite transaction it
  requires `supervisor_drained`, an evaluation of `confirmed`, or `unproven` with
  a matching acknowledgement. It re-observes the target and requires it to match
  the target subset frozen at acceptance, so a changed target is refused.
  (Implemented this way in T2: the full evidence hash also covers source
  activity, which the drain itself changes, so it can never match.) Then it updates the
  session's workspace, appends the binding generation (`coverage: complete`),
  advances the runner epoch and marks the fence `installed`. That state is
  terminal and inactive, so admission reopens under the new binding only.
  The receipt reports `target_installed: true` and `revocation_confirmed` as
  `status == confirmed`.
- **Release** (explicit cancel, decision 3): allowed from `fenced`, `stopping`,
  `blocked` or `supervisor_drained`, never after `installed` and never while this
  Node is still draining. A source that was drained gets a new runner epoch; an
  undrained `fenced` source keeps its epoch and live runner, since nothing was
  stopped. It marks the fence `released` (terminal, inactive). The session keeps
  its original workspace; nothing is restarted.

Fence states become
`fenced → stopping → supervisor_drained → installed | released`, with `blocked`
and `deleted` as today. SQL triggers keep `installed`/`released` terminal and allow
`installed` only together with a new binding generation row.

Install records one **environment changed** notice per operation. Node delivers
it to the agent as trusted context (`wake: false`, no model turn) before the next
command or delivery in that session, at most once: a send that is not confirmed
becomes `uncertain` and is never resent, and that command is refused once. Requests carrying the
old epoch, queued old tool calls and old approvals are refused by the existing
epoch and fence checks.

Capabilities (booleans, as the Gateway requires): `installsEnvironment: true` and
`transitionAcknowledgementVersion: 1` on Nodes with these operations;
`confirmsRevocation: true` only where
`confirmsContainment` is true.

## Gateway: coordinator

The accepted-intent journal gains stages after `node_fenced`:
`draining → evaluated → installing → ready`, plus `cancelling → cancelled` and the
existing `blocked`/`outcome_unknown` handling. Each Node step uses a stable
identity derived from the operation, so a retry or a recovery sweep can only join
or read the same step:

1. `node_fenced` → send `stop_transition` with command ID `stop:<operation>`.
2. Read the receipt until the drain settles; store the `revocation` evaluation
   (`evaluated`). `pending`/`blocked` waits and stays visible.
3. `confirmed` → install automatically; the user already confirmed the switch.
   `unproven` → wait for the user's acknowledgement of that exact digest, relay
   it to Node, then install.
4. On the install receipt (POST reply or later GET), in one Gateway transaction:
   advance the conversation binding (execution generation, and membership
   revision per the U2 rules), update the mapped workspace, record the
   acknowledgement, mark the journal `ready`, and notify devices. A crash between
   Node install and this commit is repaired by reading the Node receipt.
5. Cancel: before `node_fenced`, close the acceptance and release the command
   barrier. After it and before install, send Node **release**, then mark
   `cancelled`. After install, refuse.

A recovery sweep (startup and periodic, bounded pages like the pots sweep)
resumes non-terminal journals with read-only Node GETs first. It continues only
steps the user already authorized (stop, install after `confirmed` or an existing
matching acknowledgement). An offline Node leaves the stage pending.

Public confirmation stays gated: a Gateway setting (default **off**) enables
`confirm`, and only toward Nodes advertising `installsEnvironment: 1`. Whether to
turn it on by default is decided after composed acceptance.

## Client contract (interface only)

Clients already discover `activeTransition`. They add: confirm from a preview, the
stage and `revocation` view (items in plain language, digest kept internally), an
explicit **Acknowledge and switch** action for `unproven`, a cancel action until
install, and a final result that distinguishes "switched; revocation confirmed"
from "switched; revocation not fully confirmed". As decided for the terminal work,
the UI is throwaway and only the interface layer must be correct.

## Failure matrix (to be covered by tests)

| Point of failure                                     | Required result                                                                            |
| ---------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| Gateway crash after acceptance, before Node fence    | Sweep reads Node; a missing fence keeps `outcome_unknown`; no second acceptance            |
| Node restart during drain                            | Fence stays active; journals reconcile; evaluation is `blocked`/`pending`, never confirmed |
| Reply lost after stop, acknowledge or install        | Same identity read back; no second stop, acknowledgement or install                        |
| Target workspace removed or changed before install   | Preflight evidence mismatch refuses install; journal shows blocked; release still possible |
| New unprovable item appears after acknowledgement    | Digest mismatch; install refused until re-acknowledged                                     |
| Two devices confirm, acknowledge or cancel together  | One outcome per operation; the loser reads it                                              |
| Old model reply proposes a tool call after the fence | Refused by fence/epoch; never runs under either binding                                    |
| Cancel after install                                 | Refused; a new transition is required to go back                                           |
| Node offline throughout                              | Stage stays pending; nothing is reported as revoked or installed                           |
| Session deleted mid-transition                       | Fence `deleted`; journal closes with retained tombstone; nothing installs                  |

## Delivery slices

| Slice | Content                                                                                                            | Proof                                                                       |
| ----- | ------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------- |
| T1    | Node binding generations, coverage, revocation evaluation in receipts (no behavior change)                         | Unit cases per item kind and status; migration seeds generation 1 as legacy |
| T2    | Node acknowledge, install, release, environment-change entry, capabilities                                         | Idempotency, digest mismatch, preflight mismatch, epoch refusal, restart    |
| T3    | Gateway coordinator stages, Node calls, binding commit, recovery sweep, gated confirmation                         | Crash-point and concurrency cases with real Node processes                  |
| T4    | Web/Android interface for confirm, acknowledge, progress, cancel and result                                        | Client unit tests against the contract                                      |
| T5    | Composed acceptance: real Gateway/Node on macOS (unproven + acknowledgement), synthetic kernel fixture (confirmed) | Linux-native confirmation stays pending, as the user deferred Linux tests   |

Each slice is a local commit with its plan checkpoint. Native Linux acceptance,
cross-Node handoff and project mounts remain later work. This design authorizes
no push, deployment or release.

## Local implementation checkpoint: T1 binding generations and revocation evaluation (2026-11-07)

Node schema **2031** delivers slice T1 with no behavior change to admission,
drain, Stop or transition receipts' existing flags.

- `session_binding_generations` records each session's binding history:
  generation, workspace, coverage, start runner epoch, start time and installing
  operation. Migration seeds generation 1 for every existing session as
  **legacy** coverage with start epoch 0, so earlier runs count. A trigger seeds
  new sessions as **complete** at their current epoch. Rows are immutable,
  retained while the session exists, and removed with it.
- `execution_fences::revocation::evaluate` reads the current generation's
  retained evidence and returns `status` (`pending`, `blocked`, `unproven`,
  `confirmed`), bounded `items` (at most 100 shown, `itemsTotal` for the rest),
  `coverage`, `confirmsContainment` and a SHA-256 `digest` over every sorted item.
  Item kinds follow the design: unresolved sandbox launches, terminals, host
  commands, browser groups and native proxy scopes block and cannot be
  acknowledged; settled host commands and host-shell terminals, legacy coverage
  and untracked launches, rows from another workspace, an unrecorded workspace
  change and an Agent run without kernel containment are acknowledgeable. A
  settled kernel-scoped terminal adds nothing. An unfinished drain is always
  `pending`; a `blocked` fence is always `blocked`.
- New sandbox capability `contains_descendants()`, true only for the native Linux
  backend. Every other backend (macOS, wrappers, fixtures) reports false, so any
  Agent run there makes the generation `unproven`.
- Transition receipts (create, status, resume) gain an optional `revocation`
  object, omitted once the fence is `deleted`, or if evaluation cannot be read.
  `revocationConfirmed` and `targetInstalled` stay **false**. The Gateway still
  requires that and ignores the new field until T3.

Old binaries reject 2031; rollback needs matching state/binary backups. Gateway
**1029**, protocol/client/envelope **15/2/3**, capabilities, packages, lockfiles
and Nix hashes are unchanged.

Validation: **666 Node library tests** (five existing ignores; eight new revocation cases),
**421 Gateway tests**, **32 required real Gateway/Node process cases** across 12
suites plus the route snapshot case, `cargo fmt --check` and strict all-target
Node/Gateway/conformance/config Clippy passed. The new cases cover: an idle new
generation is confirmed, an unfinished drain is pending, a blocked fence is
blocked; an Agent run without containment is unproven; host commands and host
shells are acknowledgeable while a settled scoped terminal is not listed and an
open browser group blocks; untracked and foreign-workspace launches are unproven
and an unconfirmed scoped launch blocks; digests are stable, cover items beyond
the 100 shown, and change when any item changes; generations are immutable,
follow session deletion and detect an unrecorded workspace move; upgrade seeds
existing sessions as legacy and new sessions as complete; receipts carry the
evaluation, keep both flags false and omit it after deletion. Native Linux
(`confirmsContainment: true`) is not executed here. Local commit only.

T2 followed.

## Local implementation checkpoint: T2 acknowledge, install and release (2026-11-07)

Node schema **2032** delivers slice T2: the Node can end a transition fence by
installing the reviewed target or by explicit release, and records the user's
acknowledgement of unproven evidence. The Gateway does not call these yet (T3).

- **Fence states.** The fence table is rebuilt with `installed` and `released`.
  Both are terminal and inactive: admission reopens, the active-fence index and
  the startup proxy revocation sweep ignore them, and a later transition can
  start. SQL allows `installed` only from `supervisor_drained` together with the
  operation's new binding generation, and `released` only from `fenced`,
  `stopping`, `blocked` or `supervisor_drained`. Reconciliation helpers that
  require "some transition fence" still accept ended fences.
- **Frozen target review.** A resource-bound acceptance now freezes the target
  subset of its evidence (target workspace, mode definition hash, resource
  identity, overlap) in `execution_fence_targets`. Installation compares this
  subset with a fresh observation. This replaces the design's "same evidence hash"
  rule, which can never match because the drain changes source activity. Fences
  accepted before 2032 have no frozen target and refuse installation
  (`transition_target_unreviewed`); release still works.
- **Acknowledge** `POST .../execution-fences/:op/acknowledge
{planHash, digest, clientId, generation}`: only after the drain, only while the
  evaluation is `unproven`, only for the current digest
  (`revocation_digest_changed` otherwise). It retains the evaluation, client and
  time, closes no record and is idempotent per digest.
- **Install** `POST .../:op/install {planHash, targetWorkspaceId, clientId,
generation}`: requires the current lease, the drained fence, the reviewed
  target, a `confirmed` evaluation or an acknowledgement of the current digest
  (`revocation_unconfirmed` with status and digest otherwise), and an unchanged
  target (`stale_transition_target`). One transaction moves the session to the
  target, advances the runner epoch, appends a `complete` binding generation,
  marks the fence `installed` and queues the notice. Repeats return the same
  installation. The native proxy scope is reopened for the new generation only.
- **Release** `POST .../:op/release {planHash, clientId, generation}`: refused
  after installation (`transition_installed`) and while this Node is still
  draining (`transition_draining`). A drained source gets a new epoch; an
  undrained one keeps its epoch and live runner. The workspace never changes.
- **Receipts.** Ended fences omit the evaluation and carry
  `installation {generation, fromWorkspaceId, toWorkspaceId, revocation,
environmentEvent}`. `targetInstalled` is true once installed;
  `revocationConfirmed` is true only for a `confirmed` installation. The
  `stop_transition` command result reports both, and counts `installed` as done.
- **Environment notice.** Installation queues one `environment-change` notice.
  Node delivers it as trusted agent context with the agent RPC's new
  `wake: false` (no model turn) before the session's next command or delivery,
  at most once. An unconfirmed send becomes `uncertain`, is never resent, and
  that one command is refused.
- **Capabilities** (still booleans): `installsEnvironment: true`,
  `confirmsRevocation` = native Linux containment, plus
  `revocationEvaluationVersion`, `transitionAcknowledgementVersion` and
  `transitionReleaseVersion` at 1.

Known interim state until T3: the Gateway still requires `false` flags and the
old state set in Node receipts, so a fence installed or released directly on a
Node would show as an invalid receipt there. Public confirmation stays disabled,
so no client path reaches this. Old binaries reject 2032. Gateway **1029**,
protocol/client/envelope **15/2/3**, packages, lockfiles and Nix hashes are
unchanged.

Validation: **673 Node library tests** (five existing ignores; seven new installation
cases), **423 agent tests** (new `wake: false` case), **421 Gateway tests**, and
**37 real Gateway/Node/Agent process cases** across 15 suites (the 12 required
suites, `agent_rpc`, `agent_node` and the route snapshot) passed with
`cargo fmt --check` and strict all-target Node/Gateway/conformance/config/agent
Clippy. New Node cases: a confirmed drain installs once (workspace, epoch,
generation, reopened admission, terminal fence, later evaluation of generation 2);
unproven evidence installs only after acknowledging the exact digest, and new
evidence after an acknowledgement requires another; installation refuses an
undrained fence, a different target or plan, a stale lease and a changed target;
release keeps the original binding (drained: new epoch; undrained: same epoch)
and blocks later installation; a pre-2032 fence without a frozen target cannot
install; the notice is claimed once and never resent; upgrade keeps fences and
states. Two process assertions changed by design: the Node now reports
`installsEnvironment: true` through the link and in Gateway previews.
Native Linux containment and the Gateway coordinator are not exercised.
Local commit only.

T3 is split into T3a (below) and T3b.

## Local implementation checkpoint: T3a Gateway coordinator stages (2026-11-07)

Gateway schema **1030** delivers slice T3a: the Gateway can drive an accepted
transition after its Node fence to installation or explicit release. Public
confirmation is still disabled, so no client can create an acceptance yet (T3b).

- **Terminal stages.** `conversation_transition_acceptances` and
  `conversation_node_fences` are rebuilt with `installed` and `released`. Both
  are terminal and inactive: ordinary commands reopen, `activeTransition`
  disappears, and a later transition may start. The acceptance trigger allows
  `node_fenced → installed | released` and `accepted → released` (cancel before
  any Node request). A Node fence ends only by installation, release or
  canonical session deletion.
- **Node receipts.** Receipt validation accepts the Node 2032 states;
  `targetInstalled` must equal `state == installed`, and only an installed
  receipt may report `revocationConfirmed: true`. Every receipt must still match
  the frozen intent; an installed one must name the reviewed target.
- **Coordinator routes** under `/api/sessions/{id}/environment-transitions/{op}/`,
  each with the current `clientId`/`generation`, checked by the Gateway and again
  by the Node:
  - `advance`: reconciles an unknown outcome, asks the Node to drain (joining the
    tracked drain), stores the evaluation, and installs when the revocation is
    `confirmed` or already acknowledged. An unacknowledged `unproven` result or a
    lost lease leaves the stage waiting; an offline Node reports
    `node_unavailable`.
  - `acknowledge {digest}`: relays the acknowledgement of exactly that digest,
    then advances.
  - `cancel`: before dispatch it only closes the Gateway intent, which also
    stops a delayed dispatch; after the fence it asks the Node to release.
    Refused after installation (`transition_installed`).
- **Binding commit.** When a Node reports `installed` for the exact intent and
  target, one Gateway transaction updates the session's workspace (the existing
  binding trigger advances the execution generation and membership revision),
  ends both rows and stores the sanitized receipt. `released` ends both rows and
  keeps the original workspace.
- **Status.** Acceptance status adds `progress`: the latest sanitized Node
  receipt (`state`, `errorCode`, both flags, revocation `status`, `digest`,
  `itemsTotal`, `confirmsContainment` and items as `{kind, reason,
acknowledgeable}`, plus installation `revocation` and `environmentEvent`). No
  private Node session ids, run ids or paths leave the Gateway. Actionable Node
  refusals keep their codes; any other Node failure becomes
  `transition_step_failed`.

Old binaries reject 1030; rollback needs matching state/binary backups. Node
**2032**, protocol/client/envelope **15/2/3**, packages, lockfiles and Nix hashes
are unchanged. Test fixtures that downgrade the transition layers now also drop
the new progress table and its session trigger.

Validation: **426 Gateway tests** (five new coordinator cases), **37 real Gateway/Node/Agent
process cases** across 15 suites, `cargo fmt --check` and strict all-target
Node/Gateway/conformance/config/agent Clippy passed. The new cases, against a Node
stand-in that keeps its own fence state: a confirmed drain installs once, moves
the binding and generation, reopens commands and later calls only read; unproven
evidence waits, exposes sanitized items, refuses a wrong digest and installs after
the right acknowledgement with `revocationConfirmed: false`; cancel after the
fence releases and keeps the original workspace; a stale lease sends nothing and
a receipt naming another target is rejected without moving the binding; cancel
before dispatch closes the intent and a delayed dispatch then sends nothing.
Real-process coverage of the coordinator waits for T3b, because acceptance
needs public confirmation. Local commit only.

T3b followed.

## Local implementation checkpoint: T3b gated confirmation, recovery and composed acceptance (2026-11-07)

Slice T3b completes T3. Public confirmation exists behind an operator setting,
the Gateway resumes accepted transitions after restarts, and the composed flow
passes with real Gateway, Node and Agent processes on this macOS host. No schema
change (Gateway **1030**, Node **2032**).

- **Gated confirmation.** New Gateway setting `PIRC_ENVIRONMENT_SWITCHING`
  (default **off**). While off, previews keep `coordinator_not_available` and
  confirmation returns `transition_coordinator_unavailable`, as before. While on,
  a preview's `canConfirm` is true when it is not stale, has an observed resource
  preflight and has no blockers. `revocation_unconfirmed` no longer blocks a
  Node that advertises `transitionAcknowledgementVersion: 1`, because unproven
  revocation then needs an explicit acknowledgement. Node observations gain
  `acknowledgesRevocation`.
- **Recovery sweep.** On start and every 30 s, the Gateway pages accepted
  transitions in `outcome_unknown` or `node_fenced` (100 per page) and advances
  each with already-authorized steps only: reconcile, drain, and install with the
  confirming controller's lease when revocation is confirmed or already
  acknowledged. It never acknowledges, cancels or uses a newer lease; a lost lease
  or an offline Node leaves the stage waiting.
- **Evaluation fix found by the real run.** On a backend without kernel
  containment (macOS, external sandbox wrapper), an Agent launch row has no
  kernel identity and stays `running` after the drain stops its runner. It was
  classified as non-acknowledgeable `blocked`, which would have made switching
  impossible on macOS after any Agent run, contrary to user decision 2. It is now
  an acknowledgeable `sandbox_launch`/`uncontained_launch` item. A launch with a
  kernel identity still blocks until its scope is confirmed.
- **Clients after a switch.** The existing U2 rule applies: a command must carry
  the current `expectedBinding`, otherwise `environment_required` asks the client
  to refresh. The composed test sends it.

Composed real-process acceptance (`environment_transitions`, switching enabled,
second workspace on the same Node): an idle conversation previews with
`canConfirm: true`, is confirmed, then `advance` drains and installs it with
`revocationConfirmed: true`; its binding moves to the target, `activeTransition`
clears, and the next prompt runs after the `environment-change` notice appears in
the conversation. A conversation whose Agent ran reports `unproven` with a
`platform_containment` item and no private paths, refuses new prompts while
fenced, and installs after acknowledging its digest with
`revocationConfirmed: false`.

Validation: **674 Node library tests** (five existing ignores; one new uncontained-launch
case), **428 Gateway tests** (two new recovery-sweep cases: installs only
already-authorized steps, never acknowledges unproven evidence), **49 config
tests**, and **38 real Gateway/Node/Agent process cases** across 15 suites (the
new composed switching case included), with `cargo fmt --check` and strict
all-target Node/Gateway/conformance/config/agent Clippy. The conformance cluster
gains a `second_workspace` option (`test:target`); existing field-by-field
`NodeOptions` literals set it to false. Native Linux containment (a fully
confirmed switch after an Agent run) and client interfaces remain open. Local
commit only.

Next: T4, the Web/Android interface layer for preview confirmation, progress,
acknowledgement, cancel and the final result (throwaway UI, as decided).

## Local implementation checkpoint: T4 Web environment switching client (2026-11-07)

The Web client gains the interface layer for slice T4 against the T3a/T3b
Gateway routes. As decided for the terminal work, only the interface is meant to
be correct. The UI is throwaway: `EnvironmentSwitchPanel.svelte` sits at the top of
the side panel's Context tab, with no navigation or visual work.

- **Interface** (`apps/web/src/lib/environment-transitions.ts`):
  `environmentTransitionApi` (`environment`, `preview`, `previewStatus`,
  `confirm`, `status` = `GET .../receipts/{op}`, `advance`, `acknowledge`,
  `cancel`), parsers for previews, statuses (`progress` absent vs `null`, sanitized
  revocation items, `revocationConfirmed` only for `installed`) and
  `activeTransition`, `classifySwitchFailure`, `isBindingRefusal`,
  `transitionPhase`, `resultOf`, `allowedSwitchActions`, plain-language labels for
  every Gateway blocker and Node item kind/reason, and the in-memory
  `EnvironmentSwitch` controller (`discover`, `preview`, `confirm`, `resend`,
  `refresh`, `acknowledge`, `cancel`, `discard`, `setLease`, `dispose`).
- **Phases**:
  - Preview side: `review` (Confirm only when `canConfirm` and an observed
    `observationHash`), `review_blocked` (with `blockedBy`), `review_stale` (new
    review under a new `operationId`), `switching_disabled`
    (`coordinator_not_available`, `transition_coordinator_unavailable`),
    `preview_missing`/`confirm_missing`, `preview_unknown`/`confirm_unknown` and
    `rejected`.
  - Transition side: `accepted` → `awaiting_dispatch`,
    `outcome_unknown`, `node_fenced` → `draining` (no progress or `pending`),
    `blocked` (items, never acknowledgeable), `needs_acknowledgement`
    (`unproven`), `installing` (`confirmed`), `installed` → `switched`, `released`
    → `cancelled`, `deleted`, plus `legacy_fence` (an `activeTransition` of
    `fenced`) and `unknown_state`.
  - Results: "switched; revocation confirmed", "switched; revocation not fully
    confirmed", "cancelled; original workspace kept".
- **Identity and recovery**: a fresh `operationId` per review. A lost preview reply
  is read by GET, a lost confirmation by the receipt GET. Only a `404` allows
  re-sending the same identity and input, and a confirmation only under the same
  lease. After confirm the client calls `advance` once, then reads with backoff
  (1 s doubling to 30 s, reset on any change) while `draining`, `outcome_unknown`
  or `installing`. With control it reads through `advance`; without control, or
  after a cancel was asked, it reads only through the receipt GET.
  `reconciliationState: node_unavailable` is shown. 5xx and network loss keep
  reading. A definite refusal stops reading until _Check again_. After a reload the
  operation comes from `activeTransition`. Nothing is persisted, and IndexedDB
  stays at **3**.
- **Acknowledgement**: _Acknowledge and switch_ is offered only for `unproven`
  with control. It sends the digest of the status it showed. On
  `revocation_digest_changed` the client re-reads, shows the new items and marks
  them changed. It never acknowledges by itself. An ambiguous acknowledgement is
  resolved by `advance`. `lost_control` re-reads without advancing.
- **Cancel** is offered from `accepted` until installation, both before and after
  the fence. `transition_installed` reads the installed result ("too late"). After
  any cancel attempt, reads never advance, so nothing can install past it.
- **Binding**: after `installed` the client reads `GET .../environment` and reports
  the new binding. The panel then refreshes the snapshot, whose binding later
  commands send as `expectedBinding`. `AppState.sendCommand` refreshes the snapshot
  on `stale_environment`/`environment_required` and keeps the draft for the user to
  resend; nothing is resent automatically. Every code in the task list passes
  through by code.
- en/zh-TW strings for the throwaway panel. The existing `ContextTab` test
  fixture gained a `control` field, because the tab now mounts the panel.

Contract notes found while implementing (Gateway unchanged):

1. **No read-only status with `progress`.** `GET .../receipts/{op}` returns only
   `{transition, canConfirm}`. Revocation items come only from `advance`, which
   needs control and may drain or install, or from confirm/acknowledge/cancel
   replies. A second device without control can show the state but not the
   items.
2. **A stuck `accepted` acceptance is never dispatched again.** If `confirm`
   fails after the acceptance row commits (for example `dispatch_once`'s
   `stale_environment` or lease check), the row stays `accepted`. The recovery
   sweep pages only `outcome_unknown`/`node_fenced`, `advance` reconciles only
   `outcome_unknown`, and a duplicate confirm only reads. New commands stay
   refused (`environment_transition_pending`) until the user cancels. The client
   offers _Cancel_ and _Check again_ there.
3. **Generic 404s.** A missing preview, acceptance, receipt or session all return
   `404 not_found`. The client treats a 404 after a lost reply as "not stored",
   which is safe, because previews and confirmations are idempotent per identity
   and intent.
4. `activeTransition` carries no target workspace, and a `fenced` entry (a Node
   fence without an acceptance) has no client action.

Validation: `npx vitest run` in `apps/web`: **71 files, 699 tests** passed (637
before; **59** new in `environment-transitions.test.ts`, **3** in
`EnvironmentSwitchPanel.test.ts`, and one existing `app.svelte.test.ts` case
extended for the binding refresh). `svelte-check` found 0 errors and 0 warnings,
and Prettier check passed on all changed files. Rust, lockfiles and package
versions are unchanged.

Still open: real browser journeys against a switching-enabled Gateway, the new UI
(placement, item presentation, progress), Android parity (parallel slice) and the
contract notes above. Local commit only, no push, deployment or Release.

## Local implementation checkpoint: T4 Android environment switching client (2026-11-07)

Android adopts the [client contract](#client-contract-interface-only) on top of
T3a/T3b through its direct Gateway connection. As decided, only the interface
layer is correct; the controls are throwaway and sit at the end of the existing
Context side pane, with no navigation or visual redesign.

- New `apps/android/lib/live/environment_transitions.dart`, UI-independent:
  `EnvironmentTransitionApi` (environment, preview POST/GET, confirm, receipt
  GET, `advance`, `acknowledge`, `cancel`), parsed `ConversationEnvironment`
  (`binding`, `activeTransition`), `TransitionPreview` (`canConfirm`,
  `blockedBy`, `planHash`, `observationHash`), `TransitionStatus` (`transition`,
  sanitized `progress`, `TransitionRevocation` with `items`/`itemsTotal`/`digest`,
  `reconciliationState`) and `EnvironmentTransitionFlow`, which maps every state
  to an `EnvironmentSwitchStatus` with its `EnvironmentSwitchAction`s.
- **Preview.** Each review gets a fresh operation ID and sends the shown binding
  as `expectedBinding`. `blockedBy` is shown in plain language and Confirm is
  offered only for `canConfirm: true`. `coordinator_not_available` and
  `transition_coordinator_unavailable` are the `disabled` state. A stale preview,
  `transition_review_changed` or `stale_environment` (which also re-reads the
  binding) asks for a new review. A lost preview POST is read back; a `404`
  allows sending the same ID and body again.
- **Progress.** Confirm sends `planHash`, `observationHash` and the lease, then
  calls `advance`. While the state is `node_fenced` without progress or with a
  `pending` revocation, the flow polls with backoff (1, 2, 4, 8, 15, then 30 s).
  `advance` is used with control; without control the receipt GET is read and
  nothing mutates. A lost confirm reads the receipt GET: `404` keeps the same
  review for an identical re-confirm, an accepted one continues by `advance`.
  `reconciliationState: node_unavailable` is shown. After a restart, `load()`
  adopts `activeTransition`; nothing is persisted, and the envelope stays at **3**.
- **Revocation.** `unproven` lists items as plain kind/reason text with
  `itemsTotal`, and offers **Acknowledge and switch**, which sends the digest of
  the shown status. `revocation_digest_changed` (or another refusal that means
  the list changed) re-reads and shows the new list; nothing is acknowledged
  automatically. `blocked` lists the items and offers no acknowledgement.
- **Cancel and result.** Cancel is offered until installation (`accepted`,
  `outcome_unknown`, every `node_fenced` stage). `transition_installed`,
  `transition_released` and `transition_outcome_unknown` re-read the status.
  `installed` shows "switched; revocation confirmed" or "switched; revocation
  not fully confirmed" from `revocationConfirmed`, and `released` shows
  "cancelled; original workspace kept". An installed switch re-reads
  `GET .../environment` and hands the new binding to
  `LiveController.adoptBinding`, so later commands send it as `expectedBinding`.
  A command refused with `environment_required` or `stale_environment` now also
  refreshes the binding (`LiveController.refreshBinding`) and is never resent.
- **Errors** pass through by code with plain-language text (all listed T3
  codes plus `transition_review_changed`, `stale_environment` and
  `transition_not_reviewable`). 5xx, including `transition_step_failed` and
  `invalid_transition_receipt`, and connection loss are ambiguous: the flow reads
  again and never repeats a mutation under a new identity. 71 new en/zh-TW
  strings.

Validation: `flutter test test/environment_transitions_test.dart` **43 passed**
(the exact paths and bodies; operation IDs; 15 status-mapping and polling rows;
the three result texts; disabled previews and gated confirm; blockers; fresh IDs
with the shown binding; stale review; `stale_environment` binding refresh; lost
preview → same-ID resend; confirm → advance polling with backoff to an installed
binding refresh; capped backoff while the Node is unavailable; `node_unavailable`;
`transition_review_changed`; lost confirm with `404` and with acceptance; eight
passed-through refusals; two ambiguous 502 codes; restart discovery with and
without control; unproven items and acknowledgement; digest change re-read;
blocked without acknowledgement; ambiguous acknowledgement; cancel before and
after the fence; cancel after installation and `lost_control`; unknown cancel
outcome; command binding refresh without resend; one card widget case).
Existing `i18n` **3**, `command_environment` **4**, `context_flow` **2**,
`panel_core_accessibility` **12**, `side_panel` **6**, `completion` **12**,
`terminal_requests` **57** and `terminal_parity` **8** passed, and `flutter
analyze` of the whole package found no issues. Placing the card at the top of
the Context pane broke the pinned `context_flow` layout, so it sits at the end.

Contract notes for the coordinator (no Gateway change): the read-only receipt
GET omits `progress`, so a device without control cannot see revocation items
(only `advance`, the other coordinator replies and `POST .../reconcile` carry
them); `activeTransition` disappears after installation or release, so another
device that reloads afterwards cannot read the final result; and an
`activeTransition` taken from a bare Node fence (no acceptance) has no
acceptance status to read, so it shows as a refusal.

Open: device/emulator journeys, the new UI, and Web parity (separate slice).
Local commit only, no push, deployment or Release.

## Integration checkpoint: T4 environment switching clients (2026-11-07)

The Web and Android T4 slices were built in parallel from `c9a9d3e6` and
integrated as `bafea1ee` (Web) and `7da3d21a` (Android). Both are interface
layers with throwaway controls (Web: the side panel's Context tab; Android: the
end of the Context pane). Neither changes Rust, Kotlin, dependencies, lockfiles,
Web IndexedDB **3** or the Android envelope **3**. Both refresh the binding after
`environment_required`/`stale_environment` without resending.

Re-run after integration: Web `vitest run` **699 tests in 71 files** (62 new) with
`svelte-check` clean; Android focused Flutter tests **147 passed** (43 new
environment-switching tests plus i18n, command environment, context flow, panel
accessibility, side panel, completion and terminal suites) with `flutter analyze`
clean; Prettier clean. Rust is unchanged since T3b. No browser, emulator, device,
APK or native Linux validation is claimed. Local commits only.

Gaps found by the client agents (Gateway unchanged; small follow-up slice):

1. **Read-only status lacks `progress`.** `GET .../receipts/{op}` returns only the
   transition state, so a device without control cannot see the revocation
   items or digest; only `advance` (which needs control and may act) returns
   them. Both clients found this.
2. **A finished switch is not discoverable.** `activeTransition` disappears once
   installed or released, so a device that reloads afterwards cannot show
   whether revocation was confirmed or not fully confirmed.
3. **`activeTransition` lacks the target workspace**, and can come from a bare
   Node fence with no acceptance, for which no client action exists.
4. **An acceptance stuck in `accepted`.** If `confirm` fails after the acceptance
   commits but before dispatch (stale plan or lease), the row stays `accepted`:
   the sweep and `advance` skip it, and commands stay blocked until the user
   cancels. Clients offer Cancel and Check again.
5. **Generic 404s.** Missing preview, acceptance, receipt and session all return
   `not_found`. Clients' "404 after a lost reply means not stored" rule is safe
   because the requests are idempotent, but specific codes would be clearer.

Remaining after these: native Linux acceptance of a fully confirmed switch after
an Agent run, the new UI, and the later extensions (cross-Node handoff, project
mounts).

## Local implementation checkpoint: T5 failure-matrix acceptance (2026-11-07)

Slice T5 closes the planned slices with failure-matrix acceptance. The macOS
"unproven, then acknowledged" journey was already proven in T3b; T5 adds restart,
offline, concurrency, takeover and cancel journeys with real Gateway, Node and
Agent processes, and the "fully confirmed after an Agent run" path with the
synthetic kernel adapter. No schema change (Gateway **1030**, Node **2032**).

Real-process cases (`environment_transitions::switching`, switching enabled,
second workspace on the same Node):

| Failure point                                          | Observed result                                                                                                                  |
| ------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------- |
| Gateway crash right after confirmation, no client call | The restarted Gateway's recovery pass installs the switch on its own; generation 2                                               |
| Node offline after the fence                           | Control lapses with the Node (`lost_control`), the read-only status stays `node_fenced`, the binding stays on the source         |
| Node restarted                                         | Its retained fence survives; the re-acquired controller's `advance` installs                                                     |
| Two concurrent `advance` calls                         | Both report `installed`; the binding advances by exactly one generation                                                          |
| Another device takes control                           | The old device's `advance` is refused and nothing installs; the new controller installs                                          |
| Cancel after the drain (Agent had run)                 | `released`; workspace and generation unchanged; the next prompt runs on the original binding; a later acknowledgement is refused |

Two behaviors found and handled:

- **Recovery timing.** Control leases expire 30 s after their last renewal, and
  the confirming lease is what the recovery sweep uses to install. A sweep that
  ran only every 30 s therefore usually missed it after a Gateway restart. The
  sweep now also runs a pass on every `node_reconnected` event, which is when a
  restarted Gateway can first read the Node, normally inside the lease. Later
  installs come from a current controller's `advance`, as before.
- **Offline control.** The Gateway drops a session's control lease when its Node
  disconnects (existing behavior), so clients see `lost_control` rather than
  `node_unavailable` while the Node is away and must re-acquire control after it
  returns. The Web and Android clients already read the status without control.

Synthetic containment (Node unit, isolated-terminal fixture with a backend that
reports `contains_descendants`): after an Agent run, a terminated kernel scope
yields `confirmed` with `confirmsContainment: true`; an unsettled launch blocks
whether or not its identity was captured, and nothing is acknowledgeable.

Not covered here: session deletion during a transition through the public API
(workspace conversations cannot be deleted; Gateway unit tests cover canonical
deletion), a crash between the Node install commit and the Gateway commit
(repaired by the receipt read and unit-tested with the Node stand-in), an
in-flight model reply after the fence (refused by the existing fence and epoch
checks), and native Linux execution.

Validation: **675 Node library tests** (five existing ignores; one new containment case),
**428 Gateway tests**, and **42 real Gateway/Node/Agent process cases** across 15
suites (four new failure-matrix cases), with `cargo fmt --check` and strict
all-target Node/Gateway/conformance/config/agent Clippy. Local commit only.

Status after T5: the planned slices T1–T5 are delivered locally. Switching stays
off by default (`PIRC_ENVIRONMENT_SWITCHING`). Open: the five Gateway
status/discovery gaps from the T4 integration, native Linux acceptance, the new
UI, and the later extensions (cross-Node handoff, project mounts).
