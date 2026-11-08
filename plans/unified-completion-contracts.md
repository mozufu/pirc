# Unified implementation completion contracts

[Plans](README.md) · [Product plan](unified-conversations.md) · [Execution contracts](conversation-execution-contracts.md) · [Transitions](transition-installation.md) · [pots](pots/README.md)

Status: **adopted planning contract, 2026-11-07; implementation and acceptance pending**.
The user accepted the architecture-audit recommendations and explicitly chose
backend continuation of an accepted, frozen environment operation independently
of the originating App/Web connection and interactive control lease. This update
changes documents only. It does not resume a paused implementation goal, grant
runtime access, enable a feature, change formats, push or deploy anything.

## C0. Authority, current snapshot and scope

For this architecture family, read in this order:

1. The latest user instruction controls authorization, pause, publication and scope.
2. This file supplies the current completion contracts and cross-plan corrections.
3. Product/execution/isolation/pots plans supply compatible behavior and detailed
   flows; reusable-library architecture remains authoritative for shipped Rust APIs.
4. Dated implementation checkpoints describe only their recorded revision. Their
   “next”, “not implemented”, “local only” or test counts are not current status.

The snapshot below is based on source `bf6ccd77`, not a new runtime verification.
Update this one snapshot when implementation advances; link to evidence instead
of writing competing “latest” summaries across the plans.

| Area                   | Implemented baseline                                                                                        | Acceptance/activation and remaining work                                                                                         |
| ---------------------- | ----------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| Formats                | Gateway 1030; Node 2032; protocol 15; client contract 2; Web IndexedDB 3; Android private envelope 3        | No version or dependency change in this document                                                                                 |
| U1 first Send          | Gateway/Node/Web/Android persistence, recovery and draft integration                                        | `canSubmit: false`; mixed-version, device and rollout gates remain                                                               |
| U2 bindings            | Legacy adapter, configured policy, membership, memory/upload provenance and ordinary-command checks         | Full live-resource provenance and project grant enforcement remain                                                               |
| U4 same-Node switch    | T1–T5: existing registered workspace targets, coordinator, Web/Android controls and failure-matrix evidence | `PIRC_ENVIRONMENT_SWITCHING` defaults off; C4 G1 delivered; C1–C3, the remaining C4 gaps and native Linux acceptance remain      |
| Work/host terminals    | Explicit paths, retained requests, v3 clients; compatibility host path defaults off                         | Native Linux and real browser/Android journeys remain; no automatic host fallback                                                |
| U5 tasks/collaboration | Existing goal/todo/team/pots primitives                                                                     | Canonical mapping, project fan-out, notes/board and waits not accepted as complete                                               |
| U6 pots                | Progress tracking, explicit dispatch, Stop ownership/archive                                                | Content observation, proactive analysis, standing grants, budgets and digests not accepted as complete; P7 remains open          |
| Libraries              | Extracted types/transports/OAuth and production loop adapter                                                | API/feature/local-Send/event-order proof debt remains; no crates.io publication                                                  |
| App                    | Paired Android is an independent client for supported routine operations                                    | New sign-in/topology and broader management authorization remain separate; current Web-confirmed management grants are preserved |
| Deferred               | UI/navigation reset, Flutter Web migration, iOS native connection                                           | Not prerequisites for the bounded backend/client contracts here                                                                  |

Existing T5 evidence includes real-process restart/offline/concurrency/takeover/
cancel journeys, and **synthetic**, not native Linux, confirmed containment. Its
675 Node, 428 Gateway and 42 process cases are historical results, not tests run
for this document. C4 gaps G1 are delivered ([checkpoints](transition-installation.md)); the others remain.

The original context decision A remains: leaving a project preserves saved history
but removes new project-derived access. Independent disclosed grants survive;
explicit deny wins. This does not erase bytes already read by a model or user.

## C1. Durable operation authority

### Record and authority boundaries

First apply this model to workspace/mount transitions. Do not implicitly extend
it to continuous task execution, deletion, calendar writes, arbitrary host work
or pots spending. Those actions keep their own policies and confirmation rules.

Use three independent identities:

- **Interactive control lease**: who may submit a new intent, risk acknowledgement,
  cancellation, reauthorization or target change now.
- **Operation authority**: backend permission to advance exactly one accepted plan.
- **Execution authority**: the current binding/grants/epoch authorizing a concrete
  effect. Neither of the first two invents a folder or host-management grant.

Persist an accepted operation with at least:

| Field group | Required meaning                                                                                                                                    |
| ----------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| Identity    | Stable `operationId`, owner, conversation, operation kind and idempotency key                                                                       |
| Frozen plan | Source binding generation/revision, target resource identities and rights, material policy/membership revisions, plan hash and affected scope graph |
| Consent     | Authenticated confirming actor, original client/control generation, reviewed evidence version and any acknowledged digest/items                     |
| Delegation  | Allowed coordinator phases, authority revision, finite acceptance deadline, explicit renewal/revocation history                                     |
| Effects     | Stable per-phase command identities, claims and receipts, irreversible commit point, source drain and target readiness evidence                     |
| Recovery    | Current stage, status revision, wait reason, last observed receipts and ordered audit events                                                        |

The backend uses an internal, owner/operation/phase-scoped authority when the
interactive lease expires. It never impersonates a live device lease. Node must
validate the operation authority and current execution rights, not trust an actor
label or an old client token. New wire semantics require negotiated capability
support; existing nodes must not silently accept the stronger delegation.

At every new effect admission, atomically verify that the operation/phase is
current, authority is unexpired/unrevoked, target and relevant grants still match,
and no cancellation/deletion fence won. Reconnect or token renewal does not extend
operation authority. If the authority service is unavailable, observe/reconcile
but do not admit a new effect from a cached positive answer.

### Lifetime and continuation

Acceptance grants a **finite** operation deadline selected from a configured
per-kind policy and shown before confirmation. Missing/invalid policy keeps the
new capability disabled; this plan chooses no numerical duration. A bounded phase
permit cannot extend past that deadline. Live processes use monotonic elapsed
time; persisted deadlines must survive restart without clock rollback extending
permission. Uncertain clock validity requires reconciliation/reauthorization.

- Closing App/Web, suspension, transport loss or interactive lease expiry does not
  cancel the operation. A fair, bounded backend sweep/reconnect handler continues
  authorized stages without any client `advance` call.
- Another device acquiring control alone does not revoke an accepted operation.
  It gains current authorized actions. Explicit task takeover/Stop retains its
  separate, scoped behavior and is not equivalent to opening another device.
- A materially changed target, effective grant or reviewed risk pauses for current
  human review. Expected drain progress is not a changed target; incidental source
  activity must not make an already-frozen target hash impossible to satisfy.
- Deadline expiry or authorization loss stops **new** effects. It does not undo an
  effect admitted earlier, reopen source access or discard an active stop observer.
  Safe shutdown/result observation continues as already-owned cleanup; no new
  business effect, arbitrary command or rollback is inferred.
- Read receipts after expiry/revocation to discover facts already committed, subject
  to the viewer's current read rights. Node installation committed before expiry
  must still be reflected at Gateway; reconciliation is not a fresh installation.
- Explicit reauthorization needs current control and a fresh preview of material
  changes. Retain the same operation/step identities and increment authority
  revision; never reset an unknown outcome into “not sent”. Renewal cannot mutate
  frozen targets or widen rights: a changed target needs a new intent after this
  operation's effects are reconciled.

### State and action rules

Stages describe progress; orthogonal wait/authority fields avoid inventing a
competing Node fence state machine. The DTO names in this file are target API
contracts, not fields already available in version 1.

| Situation                             | Backend behavior                                                                 | Allowed human action                                               |
| ------------------------------------- | -------------------------------------------------------------------------------- | ------------------------------------------------------------------ |
| Accepted, no effects yet              | Verify durable identity and reconcile, then start the same plan while authorized | Cancel or inspect; target changes require a new reviewed intent    |
| Stopping                              | Keep tracked observers; reject new affected work                                 | Request cancellation, but reopening waits for C3 safety conditions |
| Node unavailable                      | `waiting_system/node_offline`, preserve barriers and operation                   | Inspect, request cancel; no pretend offline release                |
| Additional unproven evidence          | `waiting_user/acknowledgement_required`                                          | Current controller reviews exact evidence digest                   |
| Blocked resource / changed target     | Keep blocked reason and known effects                                            | Reconcile, cancel safely or review a replacement; no force-clear   |
| Authority expired/revoked             | `waiting_user/authority_expired` or `authority_revoked`; no new effects          | Reauthorize if still permitted, or request safe cancellation       |
| Installed at Node, Gateway reply lost | Read same receipt and commit the observed binding once                           | Inspect; cancellation cannot undo installation                     |
| Finished                              | Retained result discoverable from either client                                  | A reverse switch is a new operation                                |

A cancellation is itself an authenticated current-control request and can settle
an expired operation; it cannot erase unresolved resource evidence. Permission
revocation cannot prevent the host from retaining necessary cleanup barriers.

### Acceptance cases O1–O8

1. **O1**: Confirm, close both clients and expire the interactive lease. With valid
   operation authority and unchanged rights, the backend completes exactly one
   binding update; reopening either client discovers the same result.
2. **O2**: Node offline longer than a control lease, then reconnects. Continue only
   if operation authority remains valid; otherwise show reauthorization required.
3. **O3**: Gateway/Node restart at every persisted phase; read receipts before any
   retry, with stable IDs and no duplicate external effects.
4. **O4**: A new device takes control while the coordinator works. Original operation
   continues; old device cannot issue new controls; an explicit cancel is serialized
   against install and reports the actual winner.
5. **O5**: Revoke a grant/change target/add risk between phases. No newly forbidden
   effect starts; required human review cannot be replaced by background execution.
6. **O6**: Deadline expires before installation versus after Node's install commit.
   The former does not install; the latter reconciles the actual install without
   rollback or a second install. Clock rollback never extends authority.
7. **O7**: Lost acknowledgement or external reply remains unknown until reconciled;
   no fresh operation ID is used to “retry” an uncertain effect.
8. **O8**: Operation completion never resumes an explicitly stopped task, dispatches
   another objective or spends new pots budget.

## C2. Revocation evidence and inherited risk

Every new launch/effect must durably identify conversation, attempt, binding
**generation**, runner epoch, resource/grant origin and owning operation before
spawn/admission. Workspace strings and wall-clock comparisons are insufficient.
Migrations leave unassignable legacy evidence explicit, never manufacture closure.

Coverage means the completeness of **new-generation recording**, not historical
revocation. Keep an inherited-risk set referencing earlier generations until each
item has positive closure evidence. A reviewed legacy disposition is an annotation,
not removal from the unresolved set or technical closure. Acknowledgement is a per-operation consent,
not closure and not a grant. Do not prune inherited risks merely because a new
generation is complete or idle.

Evaluate current scopes plus inherited unresolved risks relevant to the removed
resources. Unknown scope remains conservatively relevant; a genuinely irrelevant
item may be excluded only with retained scope reasoning. Report current-generation
settlement separately from cumulative revocation. “Revocation confirmed” without a
scope qualifier is permitted only when all relevant retained risks are closed.

| Evidence                                                                       | Required behavior                                                        |
| ------------------------------------------------------------------------------ | ------------------------------------------------------------------------ |
| Live tracked stopping / pending observations                                   | `pending`; await them, no acknowledgement bypass                         |
| Unresolved record without live observer                                        | `blocked`; reconcile through retained ownership/kernel evidence          |
| Adopted unprovable classes, e.g. detached host effects or uncontained platform | `unproven`; ordinary switch may proceed with exact per-operation consent |
| Positive closure of all relevant scopes                                        | `confirmed`; record proof identity and backend capability                |
| Legacy/unattributed effects                                                    | Explicit unknown coverage/risk, never silently excluded by time filter   |

Explicit folder blocks, project-grant revocation and account/device revocation
must reject **new** prohibited access even if historical exposure cannot be erased.
An unproven acknowledgement cannot convert deny to allow, bypass pending/blocked,
or advertise resource removal while known old authority still works. If the host
cannot enforce that operation, report unsupported/blocked; preserve the barrier.
Ordinary switching can retain its adopted “not fully confirmed” result.

Risk review uses an immutable `evaluationId`, canonical full-set digest and total,
with deterministic cursor paging tied to that snapshot. The first 100 items are a
page, not the full consent boundary. Show total and category counts, allow the full
list to be inspected, and explicitly label any summary acknowledgement as covering
**all N items**. A changed digest requires new review; page cursors must not drift
to another snapshot. Server retains the exact confirmed set, actor and authority.

Cases R1–R5: A→B→C with surviving A host effects; A→B→A with same-millisecond or
backwards clocks; legacy rows after migration; 101/1000 risks with a change during
paging; ordinary switch versus explicit folder deny under the same host risk.
None can drop an unknown item or claim global closure from a clean new generation.

## C3. Cancellation, installation and trusted context

### Cancellation and serialization

Use one operation serialization boundary for starting drain, reserving a new
phase, cancelling and committing installation. A process-local `draining` lookup
outside that boundary is not a sufficient safety proof after restart.

| Source state/evidence                                                | Cancellation result                                                                                                                                           |
| -------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Fenced, no drain/effect claim, original runner unchanged             | Release the intent under unchanged validated original binding/epoch                                                                                           |
| Drain active                                                         | Record cancellation request; continue observing shutdown; no new writer yet                                                                                   |
| Source fully supervisor-drained and resource outcomes settled        | Explicit release to validated original binding under a fresh runner epoch; never restart stopped work                                                         |
| Unknown observer/resource or unresolved drain                        | Keep `cancel_pending`/blocked with reason; reconcile first; no force-clear                                                                                    |
| Only adopted unproven residual effects remain after supervisor drain | Preserve the risk set and disclose return/concurrency risk with the explicit cancel action; cancel does not restart work or label those effects fully stopped |
| Original binding/grants no longer valid                              | Do not restore access; await a newly reviewed authorized target or cleanup                                                                                    |
| Target install committed                                             | Return `transition_installed`; reconcile, then reverse only through a new transition                                                                          |

Gateway persists cancellation intent and prevents new unclaimed install phases;
Node serializes actual install/release against its own retained fence transaction.
There is no claimed atomic transaction spanning the two SQLite databases. An
already dispatched/uncertain phase must be reconciled before release; cancellation
stays requested, not completed. Node's committed install/release receipt determines
the winner, and Gateway converges to that fact after crashes. A local timeout never
makes an in-flight install safe to forget.

Cancel/acknowledge/install racing on two devices produces one committed result;
the losing command reads it. Explicit source-return consent does not authorize any
new host command. Deletion and Stop fences remain stronger than cancelled intent.

### Installation versus runtime readiness

Distinguish `bindingCommitted`, `policyValidated` and `runtimeReady` (`not_started`,
`ready`, `failed`, `unknown`). Existing `target_installed` describes the recorded
binding installation, not proof that every dependency and new mount is usable.
Display “switched; execution not started” until the necessary readiness checks.
A failed first runtime launch does not revert the committed binding or run in the
old workspace. Future project-mount support needs actual backend policy receipts.

### Trusted notice protocol

One logical environment notice per operation is persisted with notice ID,
source/target generation and active rules revision. Agent applies it idempotently
and returns a durable applied watermark/receipt. Retransmit the **same** notice on
lost replies; this is state reconciliation, not replaying a tool or model turn.
After restart, reconcile `sending`/`uncertain` as well as pending records.

Before subsequent effect/model admission, require the applicable environment
watermark and rules revision. A replacement agent receives authoritative current
metadata plus required ordered notices; it cannot depend on an old process's
in-memory receipt. Notices do not wake a model turn, resume a task or copy private
context. Duplicate notices do not duplicate transcript entries. Older epochs and
approvals never become valid in the new environment.

Cases X1–X5: cancel with blocked restart evidence; concurrent drain/cancel/install;
source grant revoked before release; notice delivered but receipt lost and agent
restarted; committed binding followed by runtime launch failure. Verify epochs,
retained risks, no duplicate writer and no effect before trusted context readiness.

## C4. Gateway read model and recovery contract

Retain the existing transition route family. Owner-authorized read-only operation
discovery and receipt queries never require an interactive lease or call `advance`.
Under `/api/sessions/{id}/environment-transitions`, the target route contract is:

| Method and suffix                                    | Contract                                                                                             |
| ---------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| `POST /previews`                                     | Prepare a no-effect preview of the proposed target; no folder allocation                             |
| `GET /previews/{operation}`                          | Read the retained preview and its material revision                                                  |
| `POST /previews/{operation}/confirm`                 | Current control accepts the frozen plan and finite operation deadline once                           |
| `GET /receipts/{operation}`                          | Complete persisted read model below, including finished outcomes; never advance an effect            |
| `GET ?cursor=…&limit=…`                              | New paged discovery of active and finished operations, stable cursor/order and last-finished summary |
| `GET /{operation}/evaluations/{evaluation}?cursor=…` | New immutable evidence pages for the exact evaluation/digest                                         |
| `POST /{operation}/advance`                          | Optional current-controller recovery hint; backend continuation never depends on it                  |
| `POST /{operation}/acknowledge`                      | Current control plus exact evaluation/digest; no implicit new target                                 |
| `POST /{operation}/cancel`                           | Current control requests serialized C3 safe cancellation                                             |
| `POST /{operation}/reauthorize`                      | New current-control review renews finite authority revision on the same non-terminal operation       |
| `POST /previews/{operation}/reconcile`               | Preserve existing receipt reconciliation; no new consent or replay                                   |

The list/evidence/reauthorize routes are target additions, not existing endpoints.
Reads return persisted status with `observedAt`, freshness and status revision;
stale evidence requests a background refresh without performing a transition in GET.
All write bodies carry stable request identity and expected plan/status revision;
acknowledgement also carries evaluation ID/digest, and reauthorization the reviewed
new deadline. Reusing an ID with different material input is a conflict. Freeze
JSON fixtures and old-client parsing before implementation. Target DTO:

| Group      | Fields/meaning                                                                                    |
| ---------- | ------------------------------------------------------------------------------------------------- |
| Identity   | `operationId`, conversation, kind, status revision, frozen plan identity                          |
| Plan       | Authorized source/target public Node/workspace/resource IDs; no private paths/session IDs/secrets |
| Progress   | Stage, wait reason, current safe actions and completion bounds                                    |
| Authority  | Expiry/reauthorization requirement; never an internal delegation credential                       |
| Revocation | Current and inherited-risk summary, evidence ID/digest/counts/paging and acknowledgement state    |
| Outcomes   | Source settlement, binding/policy/runtime readiness, cancellation or install result, uncertainty  |
| Ordering   | Snapshot watermark, update revision and final-result identity                                     |

`activeTransition` is a summary pointer, not the only discovery path. Retain a
last-finished summary and paged operation history so reload/another device can
find results. Retention must preserve unknown work and cleanup/decision references;
compaction leaves a safe tombstone and never frees an unresolved fence.

A bare Node fence without Gateway acceptance is `reconciliation_required`, with
only authorized inspection/adoption of **matching retained intent** or scoped
cleanup/cancel actions. Do not invent fresh consent from a Node fence. Missing
provenance stays blocked with a specific recovery reason.

Every durable `accepted` row must be eligible for bounded recovery. Recover a
missing dispatch by reading Node identity/receipt first, then execute the same
phase only if definitely not started and C1 authority remains valid. Changed
plan/expired authority produces an explicit review state, not an unadvanceable
row. Persist claims/outcomes and use stable retry identities; a read 404 alone is
not universal proof that no effect started.

| Condition                             | Target response/action                                                                                |
| ------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| Authentication/read scope absent      | Existing concealment policy; do not disclose someone else's object                                    |
| Authorized object family missing      | Specific `preview_not_found`, `acceptance_not_found`, `receipt_not_found` or `conversation_not_found` |
| Frozen plan/decision changed          | Conflict with current revision and `plan_changed` / `evidence_changed`                                |
| Current human control missing         | `control_required`; read remains available                                                            |
| Operation expired/revoked             | `operation_authority_expired` / `operation_authority_revoked`, safe actions included                  |
| Node offline / unsupported capability | Distinct unavailable/unsupported reason; retain outcome uncertainty                                   |
| Already installed/cancelled           | Idempotent authoritative result; no new effect                                                        |

These are target semantic error categories, not a claim that current generic 404s
or DTOs already changed. An idempotent same-ID retry still needs family-specific
outcome reconciliation; never turn an ambiguous 404 into a new operation.

Required cases G1–G5 address the five recorded Gateway gaps: no-control complete progress;
finished result after reload; target/bare-fence discovery; crash after durable
acceptance but before dispatch; specific missing-object/error recovery including
auth concealment. Also exercise result pagination, source/target deletion and
Node-install→Gateway-commit crash with real processes.

## C5. Canonical tasks and foreground routing

### Identity and mappings

A task has immutable owner/origin (user request, suggestion or schedule occurrence),
objective, revision, project association, optional execution conversation, state,
required/optional dependencies and artifact references. An attempt has task ID,
execution conversation, fixed binding generation/grant origins, runner identity,
limits, directive revision and correlated effects. A waiting tracking task needs
no empty execution conversation. Moving a conversation never rewrites origins.

| Existing concept               | Unified mapping                                                                                            |
| ------------------------------ | ---------------------------------------------------------------------------------------------------------- |
| User objective / goal          | Canonical task; preserve public ID alias and source request                                                |
| Todo/milestone                 | Child task only if separately executable/controllable; otherwise checklist evidence on parent              |
| Team/delegated worker          | Attempt or child task according to objective, always attributed to parent and scope                        |
| pots suggestion / tracking     | Suggestion origin plus optional tracked task; accepted dispatch creates/links an attempt once              |
| Schedule template / occurrence | Template is configuration; occurrence owns stable task identity; retry is another attempt                  |
| Checkpoint continuation        | Recovery attempt with restricted new environment and original provenance; never overwrite original attempt |

Before migration, inventory actual old IDs/states and build alias/round-trip
fixtures. Existing single-lifetime pots dispatch remains intact until its explicit
mapping migration; do not reinterpret it as unlimited retries.

### Creation and lifecycle

Deterministic triggers require tracking before background/scheduled execution,
child-agent dispatch or a durable wait is admitted. Ordinary short questions need
no task. An agent can propose promotion for other complex work; persist one
promotion decision linked to the originating message, with idempotent identity.
Splitting independent objectives preserves parent/origin links and separate Stop;
merging tracking does not merge grants or replay completed attempts.

States: `proposed → ready → running → waiting_user|waiting_resource|waiting_dependency
→ running → ready_for_review|completed`, with failed/cancelled terminal attempts.
Task status is derived from required children, unknown effects and review policy:
optional child failure is visible but need not fail the objective. Explicit user
acceptance requests require `ready_for_review`. Completion evidence records source
and artifact revisions; later edits can stale evidence without rewriting history.
Retry creates a new attempt after reconciling the previous one. Unknown external
outcomes are never reissued as a new attempt merely to get progress.

### Routing and scope graph

Host handles explicit Stop/revocation directly. Natural-language routing is a
versioned interpretation with `received`, `routed`, `applied` outcomes and an
accepted task/directive target; it cannot promise immediate interruption at input
arrival. Ambiguity prompts a target question without cancelling work. Only one
foreground response/context writer exists; child results are attributed.

Each attempt stores whether its environment is independently fixed or explicitly
inherited from a parent binding, and the actual grant dependency edges. A future
parent change cannot silently retarget an already admitted attempt. Old-target
queued work waits for revalidation; independent unrelated work continues. Project
grant revocation affects all edges depending on that grant, even on other Nodes.
A preview freezes/version-checks the affected graph; late descendants cannot slip
past a parent fence.

| Action                               | Authority                                                                                    |
| ------------------------------------ | -------------------------------------------------------------------------------------------- |
| View progress/content                | Separate current read grants                                                                 |
| Relay answer to a delegated question | Only the addressed valid question; legacy lease exception is not general execution authority |
| Approve/edit objective/start/retry   | Current action grant/control plus decision/directive revision                                |
| Explicit Stop/takeover               | Scoped authenticated control path, fences descendants; no model delay                        |
| Resume coordination or stopped task  | Fresh explicit request and current rights; never inferred from reconnect                     |
| pots directive                       | Authenticated pots actor and grant; not relabelled as user input                             |

New canonical controls need a compatibility mapping for legacy delegation's
cross-device 409 behavior; until available, expose its current limitation rather
than claiming unified control. Decision resolution is one atomic winner, broadcast
to clients; stale controls/notifications become “handled elsewhere”.

Cases T1–T6: one task across all mappings; duplicate promotion and multi-objective
split; question/correction/Stop during tools; A/B tasks with different bindings
and child grants; required child failure and stale test evidence; two-device
approval, takeover and late child result. No competing foreground stream,
unrequested restart, duplicate task or silent environment retargeting.

## C6. Projects, folders and collaboration

### Resources, allocation and fan-out

Resource identity includes host namespace and retained physical identity; mount
alias and grant identity are separate. Rename/remount/inode reuse and symlink,
hardlink or bind-mount aliases require backend-specific identity checks. Check
at open/effect boundaries using race-resistant handles where supported; unsupported
alias/descriptor containment must fail visibly. Do not claim universal filesystem
isolation from `realpath`, a path string or a per-Node database lock.

Keep a per-tool capability inventory: files/PTY/host execution/browser contexts/
network/source/calendar/memory access. Record actor, resources, effect boundary,
revocation participant and supported backend. New additional mounts default RO;
existing explicit grants survive, deny overrides overlap. Effective writes from
another grant must be disclosed, never hidden behind an RO alias.

Managed-folder allocation uses a stable reservation key, allowed-root and quota
checks, race-resistant creation, unique owned receipt, then adoption by first
accepted Send. An explicit Create folder is immediately user-owned and survives
draft abandonment. On lost responses inspect the reservation; do not adopt an
unrelated same-name directory or delete a folder with unowned/user changes. Orphan
cleanup applies only to proven system-owned unadopted reservations under a
configured policy. No destructive retention duration is chosen here.

A removed/missing primary cwd blocks new execution until explicitly replaced;
never silently choose home, the old project or an arbitrary writable mount.
Aliases are unique within a binding; target resources must resolve on its Node.

Project updates create a versioned change batch with affected membership
generations and per-binding desired/applied revisions. Concurrent join/leave is
serialized against that revision; a joining member cannot miss an already-frozen
revocation. Fence affected grants before reporting removal. Offline Nodes stay
pending and new commands remain blocked; partial success is visible and retries
use the same batch/member identities. No rollback restores revoked access.

### Rules, notes and board

Hard policy/grants constrain every layer; text rules cannot override them. For
ordinary guidance use explicit system→project→conversation precedence, applying
more specific instructions only within parent authority. Repository content is
untrusted input, not another security-policy tier. Pin the effective rules revision
at model/tool admission; ordinary edits apply at the next safe foreground turn,
with already-running commands unchanged. Access changes use immediate fences.

Gateway owns versioned project notes/board metadata; authorized content may remain
Node-backed with explicit availability receipts. Content transport must not copy
Node secrets into Gateway. Use CAS revisions for notes; concurrent edits return a
conflict with both versions, never last-write-wins. Board posts are append-only,
attributed discussion events; edits/redactions are new events with provenance.
Neither agent suggestions nor board text become approved rules or user commands.

Editor presets and board retention require explicit configuration before enabling
collaboration writes/automatic expiry. Available roles are reader, proposer and
editor; project-rule adoption remains user-controlled. Durable notes have no
age-based expiry. Board compaction must pin unresolved waits, active task links
and required provenance; no unspecified destructive TTL. Offline edits are drafts
until CAS acceptance. Store mixed-source provenance for summaries/derived notes.

### Waits and shared storage

Wait records contain waiter/holder/resource IDs, lease revision, requested scope,
cancellation identity and wake cursor. Queue conflicting writers fairly, recheck
on wake and reread before editing. Release at a safe tool/transaction boundary,
not arbitrarily while a process still writes. Detect wait cycles, including
parent waiting for child holding/awaiting its resource; surface a coordination
conflict and safely replan/release only settled leases. No model polling, forced
unlock or killing an active writer to break a cycle.

Git worktrees share metadata and are not full sandbox copies. Default recovery
is an independent copy per Checkpoints. Optional collaborative worktrees require
verified Git-metadata boundaries. Integration back uses revision checks/three-way
comparison and explicit conflict handling, preserving original/later user edits.
Per-Node coordination covers only its participants. Same-account Nodes need a
shared proven broker for exclusive claims; cross-host shared storage is unsupported
for exclusive-write guarantees until its protocol exists, not “protected” by a
Gateway row. Uncoordinated external writers remain detectable conflicts, not locks.

Cases P1–P6: alias replacement race; duplicate allocation/lost mkdir reply/user
edits; hundred-member mixed-online fan-out with join/leave; simultaneous notes
edits and malicious board text; cyclic waits/crashed holder/cancelled waiter;
shared Git metadata, external edits and two Nodes on the same physical storage.

## C7. Context, deletion, memory and content

Cross-Node switching requires an authorized durable context package with history
watermark, ordered partial outcomes, active rule/binding revisions, provenance and
integrity/size metadata. Export through a trusted host path before retiring the
only context owner; do not copy the entire state/profile directory. Validate
receipt completeness before target admission. Source unavailability/partial
export is blocked, not an empty replacement or a stale client-cache handoff.
Compression preserves source references; revoked live links do not become fresh
read permission. Cross-Node custody remains a later delivery, not part of T1–T5.

Deletion uses one immutable cleanup plan per originating deletion scope, with
per-host/object receipts and dependency pins. Freeze owner/membership/source
classification; project deletion's child cleanup cannot invoke a second standalone
memory purge. Pure-source derived entries can be removed; mixed notes/memory keep
the existing review/Keep/Edit policy. Legacy insufficient provenance stays
explicit. Archives do not stop work; deletion fences/reconciles before destruction.
Once irreversible deletion starts, cancellation cannot promise restoration; retain
a partial-cleanup result until all reachable hosts and references settle. Offline
tombstones prevent resurrection; compact only with a valid resync boundary.

| Data kind                          | Access/lifecycle rule                                                                         |
| ---------------------------------- | --------------------------------------------------------------------------------------------- |
| Personal memory                    | Explicit personal scope; adding a folder/project never enables it                             |
| Repository journal / project notes | Separate grants and immutable write-time membership/source provenance                         |
| Saved message/upload snapshot      | Original ownership and accepted reference rights; not reinterpreted as a live mount           |
| Live file                          | Host/resource/version identity and current grant at each fetch/effect                         |
| Managed cache                      | Partition by server identity and account; purge/invalidate by object/deletion revision        |
| User export                        | Disclosed user-controlled copy; no claim of remote erasure                                    |
| Recovery continuation              | New private restricted binding, independent directory and existing memory-disabled guarantees |

Download tokens bind audience/server/account, object/revision/scope and finite
expiry; no Node secrets in public DTOs. Range resume requires matching revision/
ETag and current permission; a stale token does not bypass revocation during
transfer. Reference GC pins active operations/checkpoints/unknown outcomes and
uses cleanup receipts. Draft attachments keep explicit original owner/context;
workspace changes require revalidation, not silent ownership transfer.
Offline saved bytes cannot be instantly erased remotely. Define cache key
invalidation and post-reconnect deletion reconciliation honestly; no fresh live
fetch from an offline-positive cache grant.

Checkpoint creation/continuation uses a restricted factory, not generic project
inheritance. Adding its result to a project or integrating files back is another
explicit operation. Existing memory-deletion and non-overwrite rules remain.

Cases D1–D5: unavailable/partial/large cross-host history; project+session deletion
with moved/mixed notes; personal-memory scope during chat→work/pots dispatch;
download/range during revocation and same account name on two servers; recovery
after source membership changes, with later edits preserved at the original path.

## C8. Bounded pots configuration and lifecycle

Content observation and proactive work stay disabled until a complete, finite
configuration exists. Missing values are not unlimited grants. This planning
approval does not grant access to any actual conversation or provider.

| Configuration     | Required contract; values still to choose                                                                                                |
| ----------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| Observation       | Explicit scopes and progress/content/source/calendar/file actions; membership growth does not silently widen consent                     |
| Suggest/track     | Source-authorized inbox/task creation, separate from execution                                                                           |
| Dispatch          | Explicit request or standing grant specifying actions, target scopes, limits and expiry; calendar proposal-confirmation remains stricter |
| Runtime/provider  | Authorized Node/service, model/provider and allowed outbound content; no fallback provider without permission                            |
| Spending          | Owner aggregate, responsibility and single-run caps; unit/pricing revision, window/timezone and explicit reset/edit policy               |
| Concurrency/depth | Finite limits across all descendants sharing a causal root                                                                               |
| Notifications     | Owner timezone, quiet hours, digest cadence, trusted urgent conditions and rate limits                                                   |
| Retention/editors | Board/editor presets from C6; responsibility/inbox paging, archive/delete policies and safe dedup pins                                   |

Before dispatch, reserve budget atomically across parallel observers/children.
Children inherit the causal-root accounting; new tasks/responsibilities cannot
reset the owner cap. Reserve a defensible upper bound from input/output limits
and the accepted pricing revision. If a provider cannot bound monetary cost,
refuse autonomous monetary-budget work or require an explicit disclosed count/
token-limited policy; do not promise exact spend enforcement from late usage alone.
Reconcile actual usage once, conservatively retain unknown charges, and refund
only proven unused reservations. Price changes do not silently
increase an accepted spend cap. Distinguish delivered lifetime counters from new
windowed budgets; reset is an explicit audited action, not a retry side effect.

Events identify source revision, issue/root cause, occurrence and causal parents;
model wording is not dedup identity. Coalesce overlapping responsibilities before
notification/dispatch. Dismiss/snooze stays effective until its selected condition
or a material source change; a recurrence is a new occurrence, not a new spelling.
Observer/board/agent updates cannot recursively manufacture authority or reset
chain budgets. Bounded event-driven/retry queues replace continuous polling.

No authorized runtime leaves a visible wait/degraded progress-only mode. Do not
pull Node credentials into Gateway or send transcripts to an unapproved provider.
Minimize content to the selected scope; policy changes cancel outstanding reads
and revalidate queued dispatch.

Durable inbox precedes push. Distinguish unread/read, dismissed, resolved and
executed; receiving a push is not acceptance. A decision handled on another device
withdraws obsolete actions and reconciles notifications. Urgency comes from trusted
rules, not source/model claims. Remote relay testing remains separately unaccepted.

Responsibility pause, observation pause, task Stop, irreversible legacy archive,
future reversible task archive and deletion have distinct transitions. Future
unarchive requires mapping/migration; it cannot replay old dispatch or discard
dedup history. Overview/persona uses authorized summaries, not an infinite merged
transcript. Context retention does not authorize new retrieval after scope removal.

Cases B1–B5: progress-only versus content grant and revoke; parallel last-budget
reservation with unknown usage; offline runtime/unapproved-provider fallback;
rephrased/recurring/self-triggered issues with cross-device notification cleanup;
archive/unarchive/capacity/pagination without re-dispatch. These add proof detail
to P7-1–P7-9, none of which is closed by this document.

## C9. Synchronization, compatibility and rollback

Snapshot and events use one server/account namespace, snapshot watermark and
monotonic entity/decision revisions. Subscribe from the snapshot watermark without
a gap; duplicate events are idempotent. If cursor history was compacted, return
`resync_required` and a new snapshot/tombstone boundary. Deletion/resolution revision
wins over late output/push or stale snapshots, not client receive timestamps.
A snapshot/stream cannot expose resources the viewer no longer may read.

Before each new wire semantic, inventory Gateway/Node/Agent/Web/private-cache/APK
versions and define absent/null/unsupported fields, required capabilities and
read/write compatibility fixtures. Never infer support from package version alone.
For the target contract, negotiate separate versioned capabilities:
`transitionOperationAuthorityVersion` (C1), `revocationEvidenceVersion` (C2),
`environmentNoticeReceiptVersion` (C3) and `transitionReadModelVersion` (C4).
Version 1 of each is the contract here; existing acknowledgement/release booleans
and v1 evaluation fields do not imply any of them. Corrected cancellation safety
requires `transitionReleaseVersion >= 2`; version 1 is the historical broad-release
contract. A Node advertises notice support only if its Agent protocol supports
idempotent application receipts too. Do not advertise these capabilities before
their fixtures and acceptance pass. A capable Gateway must refuse new authority
delegation to a legacy Node rather than emulate it with a stale control lease. Keep existing permitted old flows
working while their isolated limitations remain explicit.

Migrations use bounded, restart-safe pages and schema claims, preserve aliases,
unknown work and provenance, and exercise representative large histories. Reserve
actual migration numbers at implementation to avoid collisions with concurrent
work; old plan examples are not available numbers. Back up with version/consistency
metadata. Code rollback and data rollback are separate: state the supported reader/
writer floor and data loss if restoring a backup after new writes. Unsupported
old writers fail before mutation.

Feature disable blocks new acceptance, not receipt reads, cancellation requests,
cleanup or reconciliation of previously committed effects. Non-mutating recovery
remains possible even if fresh execution is now forbidden; existing C1 authority
still governs any new effect. No flag bypasses legacy grants or turns on U1.

Cases V1–V4: snapshot concurrent with resolve/delete and long-offline resync;
old APK/Node and missing capability; interrupted large migration with unknown
operations; disabling the flag mid-transition then rolling code/data back under
the declared compatibility floor. Verify checkpoints and existing app behavior.

## C10. Delivery gates and integration boundaries

| Slice                  | Required specification/implementation                                      | Evidence before activation                                               |
| ---------------------- | -------------------------------------------------------------------------- | ------------------------------------------------------------------------ |
| K1 evidence/cancel     | C2 generation attribution/inherited risk and C3 cancellation serialization | R1–R5, X1–X3; migration/restart/concurrent actors                        |
| K2 context/readiness   | C3 notice receipts and honest installation/runtime states                  | X4–X5; real replacement-agent/lost-reply cases                           |
| K3 durable coordinator | C1 operation authority plus C4 full read model and five Gateway fixes      | O1–O8, G1–G5; no client kept open, real process failures                 |
| K4 rollout             | C9 compatibility and this gate matrix                                      | V1–V4, actual supported Linux and Android/browser journeys               |
| K5 tasks               | C5 canonical migration and routing                                         | T1–T6, concurrent agents and required-child results                      |
| K6 projects            | C6 grants/fan-out/collaboration                                            | P1–P6, filesystem/alias platform proof                                   |
| K7 data                | C7 custody/cleanup/cache/recovery                                          | D1–D5, large/mixed provenance and existing memory/checkpoint regressions |
| K8 pots                | C8 scopes/runtime/accounting/inbox                                         | B1–B5 plus complete P7; finite configuration before enabling             |

K1–K3 may be reviewed separately but current switching activation requires all
applicable safety/read/recovery corrections. Activation is per backend/client
capability: macOS acknowledged-unproven acceptance cannot certify native Linux;
a deferred Linux gate need not prevent a separately accepted macOS-only scope. K5 can design in parallel; actual
project/pots execution depends on the corresponding grant and lifecycle gates.
No full loop rewrite or Flutter Web replacement is a prerequisite.

Every slice records separately: contract specified, code delivered, integration
accepted, platform accepted and activation allowed. Passing a synthetic adapter
never closes native Linux containment. Actual Android IME/process/Keystore/
background journeys remain distinct from JVM/Flutter tests. Local Nix validation
was waived; real remote push remains unaccepted. Necessary controls may be
throwaway in the old style; UI redesign stays deferred.

Library proof work uses independent minimal consumers for each adopted transport/
OAuth feature and local/Send usage; verify streaming/cancel/suspend/resume, wire
bytes and event order. Secret configuration is not a public client projection.
Product grants, task/memory identity and event ownership stay in the pirc host.
Only an identified missing API blocks a product slice; no speculative extraction
rewrite is inferred.

Calendar maps template→stable occurrence task→attempt; retry does not create a
second occurrence. A changed binding waits for revalidation. Preserve established
cron/timezone/DST and mandatory proposal confirmations. Source-triggered pots
suggestions remain untrusted observations until the required authorization.

Docker is a **separate proposed Linux-test slice**, not approval of production
container deployment. Specify image, userns/cgroup/bwrap prerequisites, real
containment probes, synthetic versus native results, resource limits and owned
cleanup. No default privileged mode, Docker socket or broad private-home mounts.
Missing isolation reports unsupported/failure, never skip-as-pass. Containers do
not certify NixOS/systemd or hardware behavior. Formal image updates/deployment
need their own lifecycle/security design; GPU/search backlogs remain separate.

## C11. Audit traceability and remaining configuration

All 38 audit findings now have a concrete target contract or an explicit boundary.
This closes planning ambiguities as listed; it does **not** mark code risks fixed
or acceptance passed. A slice cannot close by changing this table alone.

| Audit IDs | Disposition / contract                                                     | Required evidence                                         |
| --------- | -------------------------------------------------------------------------- | --------------------------------------------------------- |
| I01       | C0 single snapshot and precedence                                          | Fresh-reader status/link review                           |
| I02–I03   | C2 inherited risk and immutable generation identity                        | R1–R3                                                     |
| I04       | C3 cancel/drain/install boundaries                                         | X1–X3                                                     |
| I05–I06   | C3 durable notices and readiness scope                                     | X4–X5                                                     |
| I07–I08   | C2 full-set review and deny/exception matrix                               | R4–R5                                                     |
| I09       | C1 adopted operation authority independent of interactive lease            | O1–O8                                                     |
| I10       | C4 five Gateway fixes with DTO/error/recovery contracts                    | G1–G5                                                     |
| I11–I16   | C5 task mapping, creation, routing, scope, completion and controls         | T1–T6                                                     |
| I17–I22   | C6 resources, allocation, project fan-out, notes, waits and storage limits | P1–P6                                                     |
| I23–I27   | C7 custody, deletion, memory, cache and restricted recovery                | D1–D5                                                     |
| I28–I32   | C8 pots grants/accounting/runtime/events/lifecycle                         | B1–B5 and P7                                              |
| I33–I35   | C9 synchronization/compatibility plus C10 activation gates                 | V1–V4 and actual platform journeys                        |
| I36–I37   | C10 library and calendar integration boundaries                            | Minimal-consumer/conformance and occurrence/task fixtures |
| I38       | C10 separate Docker-test proposal and backlog scope                        | Future bounded proposal; no deployment authorization      |

Still to configure when those features enter implementation: finite per-kind
operation deadlines; managed-orphan/inbox/board retention where applicable;
notes/editor presets; pots observation/execution scopes and provider, spend units/
values/windows, concurrency/depth, timezone/quiet hours/digest/urgent limits.
Missing configuration disables the affected new authority or automatic destructive
behavior. Durable notes never gain age expiry. Numerical choices and real grants
are not silently manufactured by this planning approval.

No architecture choice about context retention, independent grants/deny, host
management, ordinary unproven switching or the independent-App direction needs to
be asked again. Concrete settings can be proposed at their stage; new material
behavior/security tradeoffs return for discussion rather than becoming implicit.

## Documentation verification (2026-11-07)

This round changes 16 Markdown planning files only. Prettier and `git diff --check`
pass. Local document targets/heading anchors, including inbound references to
renamed sections, and the unique I01–I38 traceability mapping were checked.
The O/R/X/G/T/P/D/B/V groups define 49 **future** acceptance scenarios; none was
executed in this round. No Rust/Web/Flutter test, build, emulator, browser or
third-party service was started, and no build output needs cleanup. Runtime fixes,
activation and publication remain separate from this local documentation commit.
