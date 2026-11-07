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

Next: T3, split into T3a (Gateway acceptance stages, Node receipt states, advance/
acknowledge/cancel routes and the binding commit) and T3b (gated public
confirmation, recovery sweep and real-process acceptance).
