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
- **Install** `{targetWorkspaceId, evidenceHash}`: in one SQLite transaction it
  requires `supervisor_drained`, an evaluation of `confirmed`, or `unproven` with
  a matching acknowledgement. It re-runs the target preflight and requires the
  same `evidenceHash`, so a changed target is refused. Then it updates the
  session's workspace, appends the binding generation (`coverage: complete`),
  advances the runner epoch and marks the fence `installed`. That state is
  terminal and inactive, so admission reopens under the new binding only.
  The receipt reports `target_installed: true` and `revocation_confirmed` as
  `status == confirmed`.
- **Release** (explicit cancel, decision 3): allowed from `fenced`, `stopping`,
  `blocked` or `supervisor_drained`, never after `installed`. It advances the
  runner epoch and marks the fence `released` (terminal, inactive). The session
  keeps its original workspace; nothing is restarted.

Fence states become
`fenced → stopping → supervisor_drained → installed | released`, with `blocked`
and `deleted` as today. SQL triggers keep `installed`/`released` terminal and allow
`installed` only together with a new binding generation row.

After install, Node appends a host-created **environment changed** entry to the
conversation, keyed by operation so it is written once. The first new-generation
runner start checks that the entry exists before running. Requests carrying the
old epoch, queued old tool calls and old approvals are refused by the existing
epoch and fence checks.

Capabilities: `installsEnvironment: 1` and `transitionAcknowledgementVersion: 1`
on Nodes with these operations; `confirmsRevocation: 1` only where
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
