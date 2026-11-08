# Transition revocation and installation (U4 step 3)

[Plans](README.md) · [Unified conversations](unified-conversations.md) · [Execution contracts](conversation-execution-contracts.md) · [Execution isolation](execution-isolation.md)

Status: T1–T5 delivered locally through `bf6ccd77`, **2026-11-07**, for same-Node
registered-workspace switching only. `PIRC_ENVIRONMENT_SWITCHING` stays off by
default. Native Linux acceptance, the five Gateway gaps and the completion
corrections below remain open. See the single [C0 snapshot](unified-completion-contracts.md#c0-authority-current-snapshot-and-scope).

The sections before the dated checkpoints specify the **target** contract as
clarified on 2026-11-07, not a claim that the code already implements the
corrections. [C1–C4](unified-completion-contracts.md#c1-durable-operation-authority)
supersede conflicting historical claims about control leases, generation-only
revocation, broad release and at-most-once notices. Dated T1–T5 records below remain
unchanged evidence of the actual, more limited implementation.

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

The conversation's journals span several bindings. Evaluate the current binding
**and inherited unresolved risks**, under [C2](unified-completion-contracts.md#c2-revocation-evidence-and-inherited-risk).
A prior acknowledgement applies only to its operation and never closes a record.
A clean latest generation cannot hide surviving earlier host authority.

- A new retained Node table records `(session, generation, workspace, started_at,
operation)`. Generation 1 is seeded for every existing session at migration;
  each install appends the next generation.
- **Coverage:** legacy histories remain explicit. `coverage: complete` describes
  recording of the new generation, not closure of inherited risks. Migration
  invents no outcome or acknowledgement.
- New effect rows record immutable binding generation/attempt/resource origin
  **before** launch. Time and workspace strings do not determine authority.
  Legacy rows without sufficient identity remain unprovable, never filtered away
  by `created_at >= started_at`. This requires a future migration; T1 uses the
  older time-based attribution and does not satisfy this corrected gate.

## Node: revocation evaluation

After the tracked drain, Node evaluates current and relevant inherited evidence.
The target receipt separates current-generation settlement from cumulative
revocation and provides the C2 immutable full-set review. Existing receipt fields
below describe the baseline and need compatible extension:

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

Operations retain fence identity (owner, session, operation, plan hash) and stable
step IDs. Human acknowledgement/cancel/reauthorization requires current control.
Automatic drain/install uses the distinct finite **operation authority** in
[C1](unified-completion-contracts.md#c1-durable-operation-authority), never a stale
interactive lease. This stronger behavior needs negotiated support and is not
implemented by the existing T1–T5 lease-bound calls.

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
  session's workspace, appends a recording-complete generation **without clearing
  inherited risks**, advances the epoch and marks the fence `installed`. Only the
  new binding can admit work after required context readiness. `target_installed`
  means binding commit; policy/runtime readiness is separate under C3. Unqualified
  `revocation_confirmed` requires closure of all relevant retained risks.
- **Release** (explicit cancel, decision 3): follows the
  [C3 state table](unified-completion-contracts.md#c3-cancellation-installation-and-trusted-context).
  An untouched fenced source can release with unchanged validated binding/epoch;
  a settled drained source returns explicitly under a new epoch. Active drains
  and unknown resource outcomes keep cancellation pending; no blanket release
  from blocked/stopping merely because the live registry is empty. Only adopted
  unproven residuals require disclosed return/concurrency risk in the explicit
  cancel action, not fabricated closure. Source rights
  must still be valid. Installation already committed forbids cancel. Nothing
  restarts, no risk record is cleared, and all races serialize with install.

Fence states become
`fenced → stopping → supervisor_drained → installed | released`, with `blocked`
and `deleted` as today. SQL triggers keep `installed`/`released` terminal and allow
`installed` only together with a new binding generation row.

Install records one logical **environment changed** notice per operation. Under
[C3](unified-completion-contracts.md#c3-cancellation-installation-and-trusted-context),
Node reconciles the same notice ID until an idempotent agent-applied watermark is
confirmed (`wake: false`, no model turn). Sending/uncertain notices survive restart
and are not skipped. Subsequent effect/model admission requires current binding
and rules context readiness. Duplicate delivery is not duplicate application.
Old epochs, queued old calls and approvals remain invalid. The T2 at-most-once
implementation below is historical and must be corrected before activation.

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
steps covered by valid C1 operation authority (stop, install after `confirmed`
or a matching acknowledgement). Closing clients, interactive lease expiry and
ordinary device-control takeover do not cancel that authority. Node offline waits;
operation expiry/revocation pauses new effects for reauthorization. Receipt
reconciliation and owned safety cleanup remain available.

Public confirmation stays gated: a Gateway setting (default **off**) enables
`confirm`, and only toward Nodes advertising `installsEnvironment: true`.
Activation additionally requires applicable C1–C4 negotiated contracts and
[C10 gates](unified-completion-contracts.md#c10-delivery-gates-and-integration-boundaries),
not just the historical T5 composed result. It remains off by default.

## Client contract (interface only)

Clients already discover `activeTransition`. They add: confirm from a preview, the
stage and `revocation` view (items in plain language, digest kept internally), an
explicit **Acknowledge and switch** action for `unproven`, a cancel action until
install, and a final result that distinguishes "switched; revocation confirmed"
from "switched; revocation not fully confirmed". As decided for the terminal work,
the UI is throwaway and only the interface layer must be correct.

## Failure matrix (to be covered by tests)

| Point of failure                                     | Required result                                                                                                                        |
| ---------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| Gateway crash after acceptance, before Node fence    | Reconcile same phase; unknown stays unknown; proven not-started may continue with valid operation authority, never a second acceptance |
| Node restart during drain                            | Fence stays active; journals reconcile; evaluation is `blocked`/`pending`, never confirmed                                             |
| Reply lost after stop, acknowledge or install        | Same identity read back; no second stop, acknowledgement or install                                                                    |
| Target workspace removed or changed before install   | Refuse install; safe cancel follows C3 and may remain pending; no restoration of invalid source rights                                 |
| New unprovable item appears after acknowledgement    | Digest mismatch; install refused until re-acknowledged                                                                                 |
| Two devices confirm, acknowledge or cancel together  | One outcome per operation; the loser reads it                                                                                          |
| Old model reply proposes a tool call after the fence | Refused by fence/epoch; never runs under either binding                                                                                |
| Cancel after install                                 | Refused; a new transition is required to go back                                                                                       |
| Node offline throughout                              | Stage stays pending; nothing is reported as revoked or installed                                                                       |
| Session deleted mid-transition                       | Fence `deleted`; journal closes with retained tombstone; nothing installs                                                              |

## Delivery slices

| Slice | Content                                                                                                            | Proof                                                                       |
| ----- | ------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------- |
| T1    | Node binding generations, coverage, revocation evaluation in receipts (no behavior change)                         | Unit cases per item kind and status; migration seeds generation 1 as legacy |
| T2    | Node acknowledge, install, release, environment-change entry, capabilities                                         | Idempotency, digest mismatch, preflight mismatch, epoch refusal, restart    |
| T3    | Gateway coordinator stages, Node calls, binding commit, recovery sweep, gated confirmation                         | Crash-point and concurrency cases with real Node processes                  |
| T4    | Web/Android interface for confirm, acknowledge, progress, cancel and result                                        | Client unit tests against the contract                                      |
| T5    | Composed acceptance: real Gateway/Node on macOS (unproven + acknowledgement), synthetic kernel fixture (confirmed) | Linux-native confirmation stays pending, as the user deferred Linux tests   |

T1–T5 are historical delivered slices, not proof of the newer C1–C4 completion
contracts. Next work follows K1–K4 in [C10](unified-completion-contracts.md#c10-delivery-gates-and-integration-boundaries).
Each implementation slice is a local commit with its actual evidence. Native Linux
acceptance, cross-Node handoff and project mounts remain later work. This design authorizes
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

Gaps found by the client agents (Gateway unchanged; implementation remains open).
[C4](unified-completion-contracts.md#c4-gateway-read-model-and-recovery-contract)
now specifies their DTO, recovery and error contracts. The stuck accepted row is
a usage-blocking recovery issue, not just a small UI follow-up:

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

Remaining beyond these Gateway fixes: the C1–C3 safety/authority/context
corrections and native Linux acceptance of confirmation after an Agent run.
Cross-Node handoff and project mounts are later extensions; UI redesign is
explicitly deferred, not a prerequisite for the bounded interface contract.

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

## Local implementation checkpoint: C4 G1 read-only progress (2026-11-08)

Closes C4 gap **G1**. `GET .../environment-transitions/receipts/{op}` now returns
the complete persisted read model of an accepted transition: `transition`,
`canConfirm` and `progress` (the last sanitized Node receipt, now with
`observedAt`). It needs no control lease and calls no Node, so a device without
control sees the stage, revocation items, digest and installation result. No
schema change (Gateway **1030**).

Validation: **429 Gateway tests** (new case: after another device takes control,
the read-only receipt still shows unproven progress, digest and `observedAt` with
no Node call) and strict Gateway Clippy passed. Local commit only.

## Local implementation checkpoint: C4 G2 finished-result discovery (2026-11-08)

Closes C4 gap **G2**. A finished switch stays discoverable after
`activeTransition` disappears:

- `GET /api/sessions/{id}/environment` adds `lastFinishedTransition`: the newest
  `installed` or `released` acceptance as `{operationId, state, createdAt,
targetWorkspaceId, targetInstalled, revocationConfirmed}`, or `null`.
- New `GET /api/sessions/{id}/environment-transitions?cursor=&limit=` pages this
  conversation's accepted transitions, active and finished, newest first, by
  creation time and operation ID (default 20, at most 100). It returns
  `{"transitions":{"version":1,"items":[…],"next":cursor|null}}` with the same
  public summary; it never includes the frozen private Node mapping. Unknown
  parameters, a bad limit or cursor return the Gateway's `400 invalid_input`.

Both reads need no control lease and call no Node. No schema change (Gateway
**1030**). Not in this gap: the C4 evidence-page and reauthorize routes, status
revisions and watermarks.

Validation: **430 Gateway tests** (new case: after installation the environment
shows `lastFinishedTransition` with the confirmed result and no active transition;
the list pages with `limit=1` to an empty end; bad parameters are refused; no
private IDs appear) and strict Gateway Clippy passed. Local commit only.

## Local implementation checkpoint: C4 G3 target and bare-fence discovery (2026-11-08)

Closes C4 gap **G3**. `activeTransition` (in `GET .../environment`) now names
the reviewed target as public `targetWorkspaceId` for an accepted transition. A
Node fence recorded with no Gateway acceptance no longer appears as `fenced`: it
is `reconciliation_required` with `recoveryReason: "no_gateway_acceptance"` and
`safeActions: ["reconcile"]` (the existing read-only receipt reconciliation), and
carries the preview's target when one exists. It never becomes consent: the
coordinator refuses to advance it. No schema change (Gateway **1030**). Adopting
matching retained intent or scoped cleanup for such fences remains C4 target work.

Validation: **431 Gateway tests** (new case: an accepted transition names its
target; a bare fence reports reconciliation with its target and cannot be
advanced) and strict Gateway Clippy passed. Local commit only.

## Local implementation checkpoint: C4 G4 recovery of undispatched acceptances (2026-11-08)

Closes C4 gap **G4**. An acceptance left in `accepted` (its confirmation failed
after the row committed but before dispatch) is no longer an unadvanceable
barrier. `accepted` means the single Node request was never sent, because
dispatch moves to `outcome_unknown` atomically before sending. So:

- `advance` and the recovery sweep (which now also pages `accepted`) retry that
  same dispatch. It rechecks the frozen plan and the confirming lease as before,
  then continues through drain and installation.
- If it can no longer be sent as reviewed (changed plan, lost or replaced
  control), the progress record becomes an explicit
  `{stage: "review_required", waitReason: <code>, safeActions: ["cancel"]}` and
  nothing reaches the Node. Cancelling releases the barrier.

No schema change (Gateway **1030**). This uses the interactive confirming lease as
the dispatch authority; the C1 finite operation authority and `reauthorize`
remain target work.

Validation: **433 Gateway tests** (new cases: an undispatched acceptance is sent
once and installs; one whose control moved on becomes `review_required` with no
Node request and is then cancelled by the new controller) and strict Gateway
Clippy passed. Local commit only.

## Local implementation checkpoint: C4 G5 specific missing-object codes (2026-11-08)

Closes C4 gap **G5**. Missing transition objects now have family-specific
codes: `preview_not_found`, `acceptance_not_found` (coordinator and acceptance
status), `receipt_not_found` and `conversation_not_found` (an authorized
conversation with no Node mapping). Concealment is unchanged: ownership checks run
first, so another user's conversation still gets the generic refusal. Clients'
rule that a 404 after a lost reply means "not stored" remains valid. Not in this
gap: `control_required` and the `plan_changed`/`evidence_changed` conflict codes
of the C4 table; `lost_control` and the existing conflict codes remain.

With G1–G5 delivered, the five Gateway gaps from the T4 integration are closed.
Remaining C4 target work: evidence pages, `reauthorize`, status revisions and
watermarks, and adoption or cleanup of bare Node fences. C1 operation authority,
C2 inherited risk, C3 cancellation corrections and native Linux acceptance remain.

Validation: **434 Gateway tests** (new case: missing preview, receipt and
acceptance return their own codes), strict Gateway/conformance Clippy, and the
`environment_transitions` (6), `execution_fences` (4) and route (1) process cases
passed. Local commit only.

## Local implementation checkpoint: C1 Node operation authority (2026-11-08)

First C1 slice (Node). Node schema **2033** adds operation authority: backend
permission to advance exactly one accepted transition, separate from device
control leases and from execution grants. It never grants a folder or host
permission.

- **Grant at fence creation.** `POST .../execution-fences` accepts an optional
  `operationAuthority {revision, tokenHash, deadlineAt}`, recorded in the same
  transaction as the fence. The Node stores only the hash.
- **Install by authority.** `POST .../:op/install` takes either the current
  `clientId`/`generation` or `operationAuthority {revision, token}`, never both.
  The authority must be the latest revision, match its hash, be unrevoked and
  before its deadline, otherwise `operation_authority_superseded`, `_invalid`
  (403), `_revoked`, `_expired` or `_missing`. Every other installation check
  (drain, reviewed target, revocation evaluation or acknowledgement) is unchanged.
- **Clock rollback.** Checks keep a persisted watermark of the latest time seen.
  A clock more than 5 s behind it returns `operation_authority_clock_uncertain`,
  so stepping the clock back cannot extend permission.
- **Reauthorize or revoke.** `POST .../:op/authority {planHash, clientId,
generation, grant | revoke: true}` requires the current controller and a fence
  that has not ended (`transition_ended`). A new grant must be newer than the
  latest revision, so a reauthorization whose reply was lost can be reissued.
  The frozen target never changes.
- **Visibility.** Receipts carry `operationAuthority {revision, deadlineAt,
revoked}` (no token or hash). The capability is `operationAuthorityVersion: 1`.

Fence creation, acknowledgement and release still require the current lease. The
Gateway does not issue authority yet (next slice). Old binaries reject 2033;
rollback needs matching state/binary backups. Gateway **1030**,
protocol/client/envelope **15/2/3**, packages, lockfiles and Nix hashes are
unchanged.

Validation: **677 Node library tests** (five existing ignores; two new: install by
authority after control moved, refusal of a wrong token and a superseded
revision, reauthorization by the current controller, refusal after the fence
ended; expired, revoked, missing and clock-rolled-back authority never install,
reauthorization without control is refused, and a lease plus an authority
together are rejected), **42 real Gateway/Node/Agent process cases** and strict
all-target Node/Gateway/conformance Clippy passed. Local commit only.

## Local implementation checkpoint: C1 Gateway operation authority (2026-11-08)

Second C1 slice (Gateway). Gateway schema **1031** issues and uses operation
authority, so a confirmed switch can finish without any device holding control.

- **Policy.** New setting `PIRC_TRANSITION_AUTHORITY_SECONDS`, the finite
  duration per confirmed transition. Unset or 0 keeps operation authority off and
  the earlier lease-bound behavior unchanged; no default duration is chosen. The
  preview reports `operationAuthority {available, durationSeconds}` before
  confirmation. It is available only with the policy set and every involved Node
  advertising `operationAuthorityVersion: 1`; Node observations gain
  `supportsOperationAuthority`.
- **Issue.** On a new confirmation with the policy set and a supporting Node, the
  Gateway stores revision 1 (a random 32-byte token, deadline = now + duration)
  in `conversation_operation_authorities`. The dispatch to the Node carries only
  `{revision, tokenHash, deadlineAt}`, so the Node records it with the fence. The
  first dispatch itself still uses the confirming lease, because the Node creates
  fences only under current control.
- **Use.** For automatic installation, the coordinator and recovery sweep present
  `operationAuthority {revision, token}` instead of any device lease. If the
  authority has expired, been revoked or the clock moved back (a persisted
  watermark with 5 s tolerance), no install is attempted and the stage waits. A
  transition without authority keeps the old lease-bound behavior. Node
  authority refusals pass through by code.
- **Reauthorize.** New `POST .../{op}/reauthorize {clientId, generation}`
  requires the current controller, the policy, a transition that has not ended,
  and an unchanged frozen plan (`plan_changed` otherwise). It issues the next
  revision Gateway-first, sends the grant to the Node when the fence exists, then
  continues. Same operation and step identities; the target never changes.
- **Status.** Acceptance status and the read-only receipt add `authority
{revision, deadlineAt, state: active | expired | revoked | clock_uncertain,
reauthorizationRequired}`. The token never leaves the Gateway's store and is
  removed with the conversation.

Old binaries reject 1031; rollback needs matching state/binary backups. Node
**2033**, protocol/client/envelope **15/2/3**, packages, lockfiles and Nix hashes
are unchanged. Web and Android do not yet show the authority deadline or offer
reauthorization.

Validation: **437 Gateway tests** (three new: authority recorded as a hash with the
fence, installation by authority with no device lease after control moved on and
no token in status; an expired authority waits without installing until the
current controller reauthorizes revision 2, which a stale device cannot do;
reauthorization without a policy is refused), the config tests, the
`environment_transitions` (6), `execution_fences` (4), `conversation_creation`
(2), `checkpoints` (3) and route (1) process cases, and strict
Gateway/config/conformance Clippy passed. Local commit only.

## Local implementation checkpoint: C1 operation authority acceptance (2026-11-08)

Third C1 slice: acceptance of operation authority with real Gateway, Node and
Agent processes (short device lease `PIRC_LEASE_TTL_MS=1500`), plus two fixes the
runs exposed.

| Case                                      | Evidence                                                                                                                                                                                                       |
| ----------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **O1** clients close, control expires     | Real process: confirm, let the lease lapse, crash and restart the Gateway; the reconnect pass installs by authority. Binding generation 2, `lastFinishedTransition` found, no token in any reply               |
| **O2** Node offline longer than the lease | Real process: authority still valid continues (O1 path via reconnect); expired authority shows `reauthorizationRequired` (O6)                                                                                  |
| **O3** restarts at persisted phases       | T5 Gateway-crash, Node-restart and offline cases; stable step identities; Gateway units for lost replies                                                                                                       |
| **O4** another device takes control       | Gateway unit: installation by authority after control moved; the old device cannot reauthorize. T5 takeover case for lease-bound transitions                                                                   |
| **O5** changed target or grant            | Install still rechecks the frozen target at the Node; reauthorization refuses a removed or changed review (`plan_changed`, unit). Grant revocation needs C6 grants: open                                       |
| **O6** deadline before vs after install   | Real process: authority expires while the Node is away; nothing installs; the current controller reauthorizes revision 2 and it installs. After-install reconciliation is the existing receipt adoption (unit) |
| **O7** lost acknowledgement or reply      | Existing units: ambiguous replies are read back, never retried under a new identity; Node accepts any newer revision so a lost reauthorization reply can be reissued                                           |
| **O8** completion resumes nothing         | Installation only changes the binding and queues the context notice; no task, dispatch or pots budget is touched (by construction)                                                                             |

Fixes found by the real runs:

- **Capability probe user.** The Gateway asked the Node for its capabilities
  with an empty user, which the Node never answers, so every confirmation with
  the policy set hung until timeout. It now sends the confirming user.
- **Material plan comparison.** Reauthorization compared the full plan hash. That
  includes the source runner epoch, which changes on every Node reconnect, so
  reauthorizing after a reconnect always reported `plan_changed`, contradicting
  C1's rule that incidental source activity must not make a frozen plan
  unsatisfiable. It now compares the reviewed plan (its preview must still match
  the frozen hash) without runner epoch and cached run status. A missing review
  remains `plan_changed`.

Not covered: native Linux, clock rollback across real restarts (unit only), grant
revocation between phases (needs C6), and Web/Android display of the authority
deadline and reauthorization.

Validation: **677 Node library tests**, **438 Gateway tests** (one new
`plan_changed` case), **44 real Gateway/Node/Agent process cases** across 15
suites (two new: O1, O2/O6), `cargo fmt --check` and strict all-target
Node/Gateway/conformance/config/agent Clippy passed. Local commit only.

## Local implementation checkpoint: C2 generation attribution and inherited risk (2026-11-08)

First C2 slice. Node schema **2034** attributes evidence by recorded binding
generation and keeps inherited risks.

- **Recorded generation.** `sandbox_launches`, `host_command_runs`,
  `terminal_runs` and `browser_groups` gain an immutable `binding_generation`.
  It is set by an `AFTER INSERT` trigger from the session's current generation,
  in the same statement as the row's reservation, so it is recorded before spawn
  or admission. Rows from before the migration stay `NULL`: explicitly
  unattributed legacy evidence, never assigned by time or workspace.
- **Evaluation v2.** The time filter (`created_at >= started_at`) is gone. Every
  retained row of the session is evaluated, and closed rows (not started,
  terminated kernel scopes, settled scoped terminals) drop out. An item carries
  its `generation` (or `null`) and `inherited` (from an earlier generation, or
  legacy). Unresolved items still block, and host effects stay unprovable in
  every later transition. Legacy coverage is listed per legacy generation, and an
  Agent run without containment is listed per generation in which it ran.
- **Separate reports.** `currentGeneration {status, itemsTotal}` is the current
  generation's own settlement; the top-level `status` is cumulative over all
  retained risks. A clean new generation can therefore be settled while
  cumulative revocation stays `unproven`. `revocationConfirmed` still means
  cumulative confirmation. The digest (version 2) covers every item with its
  generation and inheritance.
- **Gateway.** Sanitized progress passes `inherited`, `generation` and
  `currentGeneration` through. No Gateway schema change (Gateway **1031**).

Not in this slice: the owning operation/attempt on each row, immutable evaluation
snapshots with paging (C2b), and explicit folder denies (they depend on C6
grants, so they are reported as unsupported).

Positional `INSERT … VALUES` statements into these tables (including two in
production code) now name their columns, so added columns cannot shift values.
Old binaries reject 2034. Protocol, client formats, packages, lockfiles and Nix
hashes are unchanged.

Validation: **680 Node library tests** (three new: R1 surviving host effects
stay inherited through A→B→C while the new generation is settled; R2 attribution
follows the recorded generation even with a future generation start time, and
generations are immutable; R3 rows from before the migration stay `NULL`),
**438 Gateway tests**, **44 real Gateway/Node/Agent process cases** and strict
all-target Node/Gateway/conformance/config/agent Clippy passed. Local commit only.

## Local implementation checkpoint: C2 evaluation snapshots and paging (2026-11-08)

Second C2 slice. Node schema **2035** makes every reviewed risk set an immutable,
pageable evaluation.

- **Snapshots.** When a drained transition is evaluated (any status but
  `pending`), the full sorted item set is stored once in
  `revocation_evaluations`, keyed by operation and digest. Its
  `evaluationId` (`ev-` + 32 hex characters of the digest) appears in the
  receipt's `revocation`. The same set is always the same evaluation; any change
  creates a new one. Snapshots are immutable and retained.
- **Paging.** Node `GET .../execution-fences/:op/evaluations/:evaluation
?cursor=&limit=` (default 100, at most 200) pages that exact snapshot by offset,
  so cursors never drift to another evaluation. The Gateway relays it as
  `GET .../environment-transitions/{op}/evaluations/{evaluation}`: read-only, no
  control, query forwarded, items reduced to `{kind, reason, acknowledgeable,
inherited, generation}` (private run IDs stay on the Node);
  `evaluation_not_found` for an unknown snapshot.
- **Consent.** Acknowledgement accepts `evaluationId` with the digest, at the
  Node and through the Gateway. A snapshot that no longer matches the current
  full set returns `revocation_digest_changed`; the receipt names the new
  evaluation. The acknowledgement covers every item of the snapshot, not only the
  first page shown.

C2 cases: **R1** (A→B→C surviving host effects), **R2** (clock-independent
attribution) and **R3** (legacy rows stay unattributed) are covered in C2a; **R4**
(101+ risks with a change during paging) is covered here. **R5** (ordinary
switch versus an explicit folder deny under the same host risk) remains open: it
needs C6 project grants and deny enforcement, which do not exist yet. Clients do
not yet page evaluations or send `evaluationId`.

Old binaries reject 2035. Gateway **1031**, protocol/client/envelope **15/2/3**,
packages, lockfiles and Nix hashes are unchanged.

Validation: **681 Node library tests** (new R4 case: 121 items paged in pages of
50 to the exact total and digest while a new risk appears; the old snapshot's
consent is refused and the new one installs; unknown snapshot is 404),
**439 Gateway tests** (new relay case: read-only page without private IDs,
forwarded query, malformed IDs and unknown parameters refused), **44 real
Gateway/Node/Agent process cases** and strict all-target Clippy passed. Local
commit only.

## Local implementation checkpoint: C3 cancellation serialization (2026-11-08)

First C3 slice: cancellation is serialized on durable state. Node schema **2036**
and Gateway schema **1032**.

- **Node.** The fence row gains a once-only `cancel_requested_at` and a
  `cancel_reason`. Release, drain staging and installation all decide under the
  Node's database lock on that row; the process-local "draining" lookup is gone.
  `release` records the request, then:
  - `fenced` (nothing stopped): releases with the original runner and epoch;
  - `stopping`: waits with `drain_active`. The drain completes the release when
    it settles, if safe;
  - `blocked`, or a drained source whose evaluation is pending or blocked: waits
    with `resources_unresolved`;
  - drained with only acknowledgeable residual risk: releases under a fresh epoch
    and keeps the risk set; stopped work is not restarted;
  - original workspace missing or being deleted: waits with
    `original_binding_invalid`; access is never restored to it;
  - installed: `transition_installed`.

  A drain task that finds its fence already released or ended stops nothing. A
  later drain request on a drained fence completes a pending cancellation once
  safe. Installation refuses after a request (`transition_cancel_requested`,
  also enforced by SQL). Receipts carry `cancellation {requestedAt, pendingReason}`.

- **Gateway.** `conversation_transition_cancellations` stores the intent before
  any Node call. With an intent recorded, `advance` and the recovery sweep call
  only the Node drain (which completes the release) and never start an install.
  Status adds `cancellation`; sanitized progress passes the Node's pending reason.

Not in this slice: readiness states (C3b), the notice protocol (C3c) and the
X1–X5 process acceptance (C3d). Old binaries reject the new schemas.
Protocol, client formats, packages, lockfiles and Nix hashes are unchanged.

Validation: **685 Node library tests** (four new: cancel with unresolved evidence
waits, blocks installation and completes after the resource settles under a
fresh epoch; cancel during an interrupted drain completes when the drain settles;
an invalid original binding is not restored; a drain after release stops
nothing), **440 Gateway tests** (new: a pending cancellation never installs and
completes through the drain), **44 real Gateway/Node/Agent process cases** and
strict all-target Clippy passed. Local commit only.

## Local implementation checkpoint: C3 installation readiness (2026-11-08)

Second C3 slice: installation outcomes distinguish binding from readiness. No
schema change (Gateway **1032**, Node **2036**).

The installation outcome in receipts adds `bindingCommitted` (the binding was
recorded), `policyValidated` (the target was re-observed against its frozen
review at installation) and `runtimeReady` (`not_started` until a runner starts
in the installed generation, then `ready`, `failed` or `unknown`; `unknown` also
once a later generation replaced this one). It is derived from the session's
runner epoch and runner state, so a failed first launch reports `failed`
without reverting the committed binding or running in the old workspace. The
Gateway's sanitized progress passes the three fields through, so a client can
show "switched; execution not started" until the runtime is ready. Project-mount
policy receipts remain future work.

Validation: Node fence tests (new X5 case: `not_started`, then `failed` with the
binding still on the target, then `ready`), **440 Gateway tests** and strict
Node/Gateway Clippy passed. Local commit only.

## Local implementation checkpoint: C3 trusted notice protocol (2026-11-08)

Third C3 slice: the environment notice is idempotent state reconciliation. Node
schema **2037**.

- **One logical notice.** Each installation keeps one notice per operation. It
  now carries `noticeId` (the operation), `sourceGeneration` and
  `targetGeneration` with the workspaces and revocation result.
- **Retransmission.** A send whose reply was lost or refused becomes `uncertain`
  and is sent again **with the same ID** before the session's next command or
  delivery. Only one send is in flight at a time. `delivered` is final. This
  replaces T2's at-most-once rule, which could leave an agent without its
  environment context after a lost reply.
- **Restart.** On Node start, notices left `sending` by the previous process
  become `uncertain` and are retransmitted.
- **Agent.** `Agent::deliver` skips a notice whose `noticeId` and custom type are
  already in the saved transcript. A retransmission, or a replacement agent that
  reopens the session, adds no duplicate entry and wakes no turn. The command is
  still refused when the agent does not confirm the notice, so no new work starts
  before the trusted context is applied.

Not in this slice: an explicit rules-revision watermark in admission (the notice
carries generations; admission requires the delivered notice), and the X1–X5
real-process acceptance (next). Old binaries reject 2037. Gateway **1032**,
protocol/client/envelope **15/2/3**, packages, lockfiles and Nix hashes are
unchanged.

Validation: **687 Node library tests** (the notice test now checks one in-flight
claim, retransmission under the same ID after a lost reply and finality after
delivery; new X4 case: a send cut off by a Node restart is `uncertain` and
claimed again), **424 agent tests** (new: the same notice delivered twice, and
again to an agent reopened from the saved session, appears once; a different ID
is a new entry), **440 Gateway tests**, **44 real Gateway/Node/Agent process
cases** (the switching case still sees the notice once) and strict all-target
Clippy passed. Local commit only.

## Local implementation checkpoint: C3 acceptance X1–X5 (2026-11-08)

Fourth C3 slice: X1–X5 acceptance, plus two readiness fixes the real runs needed.
No schema change (Gateway **1032**, Node **2037**).

| Case                                                   | Evidence                                                                                                                                                                                                                                    |
| ------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **X1** cancel with blocked evidence                    | Node unit (C3a): waits `resources_unresolved`, refuses installation, completes under a fresh epoch once the resource settles                                                                                                                |
| **X2** concurrent drain/cancel/install                 | Real process: `advance` and `cancel` sent together; exactly one of `installed` / `released` commits and the binding matches it (target, or source at generation 1). Node unit: cancel during an interrupted drain completes when it settles |
| **X3** source grant revoked before release             | Node unit: original workspace being deleted keeps `original_binding_invalid`; access is never restored. Project-grant revocation needs C6                                                                                                   |
| **X4** notice delivered, receipt lost, agent restarted | Node unit: an interrupted send becomes `uncertain` after restart and is resent under the same ID. Agent unit: a reopened agent skips the already-applied notice                                                                             |
| **X5** committed binding, failed first launch          | Real process: after installation the target directory disappears; the next prompt fails, `runtimeReady` becomes `failed`, and the binding stays on the target. Node unit for the `not_started`/`failed`/`ready` sequence                    |

Fixes:

- **Readiness before an epoch.** A sandbox failure while preparing happens before
  the runner takes an epoch, so readiness had stayed `not_started`. Readiness
  now reads the runner state first, and installation resets the runner state to
  `stopped`, so an old binding's failure is not attributed to the new one.
- **Refresh after installation.** The Gateway's progress was the receipt captured
  at installation, so later readiness was never visible. `advance` on an
  installed transition now re-reads the Node receipt, read-only and best effort,
  to refresh readiness. It never performs an effect.

Not covered: X1 and X3 with a real unprovable resource or grant revocation
(the harness has none; X3's grant part needs C6), X4 with a deliberately dropped
agent reply in a real process, and native Linux.

Validation: **687 Node library tests**, **440 Gateway tests**, **46 real
Gateway/Node/Agent process cases** across 15 suites (two new: X2, X5),
`cargo fmt --check` and strict all-target Node/Gateway/conformance/config/agent
Clippy passed. Local commit only.
