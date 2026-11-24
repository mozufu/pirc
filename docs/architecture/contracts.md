# Behavioral contracts

[All documentation](../README.md) · [Architecture references](README.md) · [Open work](../../plans/README.md) · [Pots](../../plans/pots.md) · [Usage](../../plans/usage.md) · [Client](../../plans/client.md)

These are the behavioral contracts of the Gateway, Node and agent that pirc 2 keeps
from the earlier unified-conversation design. They state required behavior, not
delivery status: some invariants still lack acceptance on a platform, listed under
[Open acceptance gaps](#open-acceptance-gaps). Pots, usage accounting and the client
have their own specifications (linked above); where a contract here mentions a pot,
[pots.md](../../plans/pots.md) defines the pot's own rules.

Terms used throughout:

- **Conversation**: a work session. Its **binding** is the versioned execution
  environment (Node, main folder, mounts, grants, rules). The binding
  **generation** advances whenever execution authority changes.
- **Runner epoch**: identifies one agent process of a conversation. It is separate
  from the binding; restarting a runner does not move the conversation.
- **Control lease**: which device may issue interactive commands now. It is separate
  from the binding and from project membership; taking control moves nothing and
  grants no folder access.
- **Fence**: a durable record that blocks new effects of a scope while work is
  stopped and reconciled.

Each section ends with its **Source**: the retired planning file and section it was
extracted from. Those files are readable from Git history; see
[Historical records](../development/historical-records.md).

## 1. Effective capability

- An effect needs every applicable condition: **availability** (the runtime supports
  the tool and the configuration enables it), **authority** (a current grant for this
  actor, operation, target and scope), **approval** (the approval policy permits it or
  its pending decision was answered) and **readiness** (Node and resources available,
  binding current, write lease or dependency resolved). Clients show unavailable,
  unauthorized, awaiting approval and waiting for a resource as distinct states.
- A prompt instruction, hidden tool name, model assertion or the conversation's place
  in the interface is never enforcement. Checks run at dispatch and again at the
  effect boundary; a stale model request or old approval never recovers removed
  authority.
- Capabilities do not imply each other: dialogue grants nothing beyond the
  conversation; folder access grants no browser cookies, external accounts, calendar,
  schedule targets or permission to send or publish; a shell grants no broader child
  authority; seeing progress does not authorize sending instructions; provider,
  device and account management exist only behind the management boundary.
- Read-only access stays read-only through every path (shell, PTC, child agent).
  Background work is tracked as a task.
- Project rules and shared notes cannot create grants. Joining a project goes through
  the membership transition; copying its name or rules is not joining it.
- Approval presets are independent of grants: fewer prompts never cancel a
  prohibition. An execution path that cannot enforce the binding's policy is
  unavailable under that binding; policy is never weakened to fit a tool.
- Modes: a capability only grants. A missing, unknown or invalid mode or a forbidden
  combination is refused (or gets the narrowest mode), never widened. Modes are
  defined by the Gateway's configuration; a repository never defines one. Forbidden
  combinations are load errors.
- Discussion becomes work in the same conversation. A missing grant produces a
  request for that specific resource and action, never a general full-access remedy.
  A failed request stays visible and recoverable. A revocation turns a pending
  operation into denied or interrupted with its reason; it is not retried against a
  replacement folder.
- The reusable agent loop owns none of these checks; it receives host-approved
  model and tool progression.

**Source:** `plans/conversation-execution-contracts.md` § 1 Compose capabilities
without a Chat/Work switch; `plans/modes.md` § Principles.

## 2. Messages while work runs

- Each conversation has one foreground response owner at a time (a logical
  coordinator, not one process). Background and child tasks run with their own
  context and are attributed; they never append competing unlabelled streams. The
  foreground ownership generation is separate from control leases, pot coordination
  and write leases; opening the conversation on a second device does not create a
  second owner.
- An accepted message records its authenticated author, command identity, selected
  task if any and the revision the user was viewing. A client-supplied actor label
  cannot impersonate the user or a pot. Text from tools, files, other agents or pots
  never becomes a user command.

| Input                                | Behavior                                                                                                      |
| ------------------------------------ | ------------------------------------------------------------------------------------------------------------- |
| Ordinary question, nothing running   | Foreground answer; no task needed                                                                             |
| Question about a running task        | Answered in the foreground, associated with that task; does not cancel, complete or duplicate it              |
| Correction or clarification          | Same task, new directive revision; obsolete queued effects are fenced once the revision is applied            |
| Independent new objective            | Separate task; runs only if resources, isolation and concurrency allow, otherwise queued with its reason      |
| Explicit Stop                        | Direct host path; fences the task and its scoped descendants without waiting for a model; nothing rolled back |
| Pause/resume                         | Recorded and reconciled; pausing coordination does not mean processes stopped                                 |
| Reply to an approval or question     | Resolves only that decision, at its revision, with current authority                                          |
| Ambiguous target among several tasks | A short target question first; no guessed cancellation, retarget or dispatch                                  |

- Status shows received, queued, applied, stopping or interrupted; nothing promises
  that text interrupted work the instant it arrived.
- Stop stays visibly "stopping" until workers and descendants are reconciled; an
  offline worker leaves the stop unresolved. Restarting needs a new explicit start
  under current grants.
- Child results are correlated to task, attempt and call and reconciled once. Late
  output after a stop is kept as an attributed partial result; it cannot revive the
  task, change its target or overwrite a newer result.
- A child agent receives only authorized, relevant context, never every other
  conversation.
- Work a pot coordinates keeps the pot's actor identity. A user takeover suspends
  the pot's conflicting instructions, queued ones included; resuming coordination is
  an explicit user action.
- Reconnect replays accepted input and outcomes by stable identity and order, never
  by re-sending a request. Concurrent control changes are decided by revision, not
  timestamps.

**Source:** `plans/conversation-execution-contracts.md` § 2 Route new messages while
tasks run.

## 3. Tasks

- A **task** has an immutable owner and origin (user request, pot, schedule
  occurrence), objective, revision, project, optional execution conversation, state,
  dependencies and artifact references. An **attempt** has its task, execution
  conversation, fixed binding generation and grant origins, runner identity, limits,
  directive revision and correlated effects. Moving a conversation never rewrites
  origins.
- Mapping of existing concepts: a todo or milestone is a child task only when it is
  separately executable or controllable, otherwise checklist evidence; a team worker
  is an attempt or child task, attributed to its parent; a pot suggestion is an origin,
  and an accepted dispatch creates or links one attempt once; a schedule template is
  configuration while each occurrence owns a stable task identity and a retry is
  another attempt; a checkpoint continuation is a recovery attempt in a restricted
  environment that never overwrites the original attempt.
- Background or scheduled execution, child dispatch and durable waits require a
  tracked task. Short questions need none. A promotion decision is persisted once,
  idempotently, linked to its message. Splitting keeps origin links and separate Stop;
  merging tracking merges no grants and replays no completed attempt.
- States: `proposed`, `ready`, `running`, the waits (`waiting_user`,
  `waiting_resource`, `waiting_dependency`) back to `running`, then
  `ready_for_review` or `completed`; attempts may also end failed or cancelled.
  Task status derives from required children, unknown effects
  and review policy; an optional child's failure is visible without failing the
  objective. Acceptance by the user requires `ready_for_review`. Completion evidence
  records source and artifact revisions; later edits make it stale without rewriting
  history. A retry is a new attempt after the previous one is reconciled; an unknown
  external outcome is never reissued to make progress.
- Each attempt records whether its environment is fixed or inherited from a parent
  binding, and its actual grant edges. A later parent change cannot retarget an
  admitted attempt. Queued work for an old target waits for revalidation; unrelated
  work continues. Revoking a project grant affects every edge depending on it, on any
  Node. A preview freezes the affected graph so late descendants cannot slip past a
  parent fence.
- Authority per action: viewing needs current read grants; relaying an answer covers
  only the addressed, valid question; approving, editing, starting or retrying needs
  current control plus the decision or directive revision; Stop and takeover use the
  scoped control path and fence descendants; resuming needs a fresh explicit request
  (never inferred from reconnect); a pot's instruction carries the pot's actor and
  grant and is never relabelled as user input.
- A decision has one atomic winner, broadcast to all clients; other devices'
  controls and notifications turn into "handled elsewhere".

**Source:** `plans/unified-completion-contracts.md` § C5 Canonical tasks and
foreground routing.

## 4. Durable operation authority

Applies to environment transitions (workspace and mount changes). Other actions
(task execution, deletion, calendar writes, host work, pot spending) keep their own
policies.

- Three separate identities: the **control lease** (who may submit an intent,
  acknowledgement, cancellation, reauthorization or target change now), the
  **operation authority** (backend permission to advance exactly one accepted plan)
  and the **execution authority** (the current binding, grants and epoch behind a
  concrete effect). Neither of the first two invents a folder or host grant.
- An accepted operation persists: identity (operation ID, owner, conversation, kind,
  idempotency key); the frozen plan (source binding generation, target resources and
  rights, policy and membership revisions, plan hash, affected scope); consent
  (confirming actor, control generation, reviewed evidence version and digest);
  delegation (allowed phases, authority revision, finite deadline, renewal and
  revocation history); effects (stable per-phase command identities, receipts,
  commit point, drain and readiness evidence); recovery (stage, status revision, wait
  reason, ordered audit events).
- The backend continues with an internal owner-, operation- and phase-scoped
  authority after the interactive lease expires; it never impersonates a device
  lease. The Node validates operation authority and current execution rights, not an
  actor label or old client token.
- Every new effect admission atomically checks that the phase is current, authority is
  unexpired and unrevoked, target and grants still match and no cancellation or
  deletion fence won. Reconnect or token renewal does not extend authority. If the
  authority service is unavailable, the backend observes and reconciles but admits
  no new effect from a cached answer.
- The deadline is finite, chosen by a configured per-kind policy and shown before
  confirmation; a missing or invalid policy keeps the capability off. Persisted
  deadlines survive restart; clock rollback never extends them; uncertain clocks
  require reconciliation or reauthorization.
- Closing clients, suspension, transport loss or lease expiry does not cancel the
  operation; a bounded backend sweep continues authorized stages without any client
  call. Another device taking control does not revoke it (explicit task takeover and
  Stop keep their own behavior).
- A materially changed target, grant or reviewed risk pauses for human review.
  Expected drain progress is not a changed target.
- Expiry or loss of authority stops **new** effects only: it does not undo admitted
  effects, reopen source access or drop an active stop observer. Receipts stay
  readable (subject to current read rights); a Node install committed before expiry
  is still reflected at the Gateway, as reconciliation, not a fresh install.
- Reauthorization needs current control and a fresh preview, keeps the operation and
  step identities and increments the authority revision. It never resets an unknown
  outcome to "not sent", mutates frozen targets or widens rights.

| Situation                             | Backend                                                 | Human action                                        |
| ------------------------------------- | ------------------------------------------------------- | --------------------------------------------------- |
| Accepted, no effects yet              | Reconcile, then start the same plan while authorized    | Cancel or inspect; a new target needs a new intent  |
| Stopping                              | Keep observers; reject new affected work                | Request cancellation (reopening follows section 6)  |
| Node unavailable                      | Wait (`node_offline`); keep barriers and operation      | Inspect, request cancel; no pretend offline release |
| Additional unproven evidence          | Wait for acknowledgement of the exact digest            | Current controller reviews the evidence             |
| Blocked resource or changed target    | Keep reason and known effects                           | Reconcile, cancel safely or review a replacement    |
| Authority expired or revoked          | Wait; no new effects                                    | Reauthorize if permitted, or request safe cancel    |
| Installed at Node, Gateway reply lost | Read the same receipt; commit the observed binding once | Inspect; cancellation cannot undo installation      |
| Finished                              | Result discoverable from any client                     | Switching back is a new operation                   |

- Completing an operation never resumes a stopped task, dispatches another
  objective or spends a pot's budget.

**Source:** `plans/unified-completion-contracts.md` § C1 Durable operation authority;
`plans/transition-installation.md` § Gateway: coordinator.

## 5. Revocation evidence and inherited risk

- Every new launch or effect durably records conversation, attempt, binding
  generation, runner epoch, resource or grant origin and owning operation **before**
  spawn. Workspace strings and wall-clock comparisons never decide authority.
- "Coverage complete" describes recording of the current generation, not closure of
  earlier ones. An inherited-risk set references earlier generations until each item
  has positive closure evidence; a clean or idle new generation never prunes it. An
  acknowledgement is consent for one operation, not closure and not a grant.
- Evaluation covers current scopes plus relevant inherited risks. Unknown scope is
  treated as relevant; an item is excluded only with retained reasoning.
  Current-generation settlement and cumulative revocation are reported separately;
  unqualified "revocation confirmed" requires every relevant retained risk closed.

| Status      | Meaning                                                                                                                                                                                                | Allowed                                  |
| ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------- |
| `pending`   | Drain not finished, or a participant is still being observed                                                                                                                                           | Wait; cannot be acknowledged             |
| `blocked`   | Unresolved record without a live observer (earlier Node incarnation, failed retirement)                                                                                                                | Reconcile; cannot be acknowledged        |
| `unproven`  | Only acknowledgeable kinds remain: host-management commands and terminals, a backend without kernel descendant containment, launches without kernel identity on such a backend, unattributable records | Proceed with exact per-operation consent |
| `confirmed` | No items; reachable only on a backend that proves containment, or when nothing ran                                                                                                                     | Proceed                                  |

- The evaluation carries items `{kind, id, reason}`, a digest of the canonical sorted
  set and whether the backend can prove containment. It reads retained evidence and
  changes nothing. Isolated terminals settle through their kernel scopes; browser
  groups and proxy scopes must be closed, otherwise the status is `blocked`.
- Review uses an immutable evaluation ID, a digest and total over the full set, and
  cursor paging bound to that snapshot. A summary acknowledgement is labelled as
  covering **all N items**; a changed digest requires new review. The server keeps
  the exact confirmed set, actor and authority.
- A switch acknowledged as `unproven` reports "switched; revocation not fully
  confirmed", never "revoked". Only a backend with kernel descendant containment can
  reach a fully confirmed switch.
- An explicit folder deny, project-grant revocation and account or device revocation
  reject **new** prohibited access even when historical exposure cannot be erased. An
  `unproven` acknowledgement never turns deny into allow, bypasses `pending` or
  `blocked`, or advertises a removal while known old authority still works. A host
  that cannot enforce the operation reports it as unsupported or blocked and keeps
  the barrier.

**Source:** `plans/unified-completion-contracts.md` § C2 Revocation evidence and
inherited risk; `plans/transition-installation.md` § User decisions, § Node: binding
generations and coverage, § Node: revocation evaluation.

## 6. Cancellation, installation and trusted notices

- One serialization boundary covers starting the drain, reserving a phase, cancelling
  and committing installation; a process-local flag is not a safety proof after
  restart.

| Source state                                         | Cancellation                                                                                            |
| ---------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| Fenced, nothing drained or claimed, runner unchanged | Release under the unchanged original binding and epoch                                                  |
| Drain active                                         | Record the request; keep observing shutdown; no new writer                                              |
| Fully drained, resource outcomes settled             | Explicit return to the original binding under a new runner epoch; stopped work is not restarted         |
| Unknown observer or resource, unresolved drain       | Stay `cancel_pending` or blocked with the reason; reconcile first; no force-clear                       |
| Only acknowledged unproven residuals remain          | Keep the risk set; the cancel action discloses return and concurrency risk; nothing is labelled stopped |
| Original binding or grants no longer valid           | Do not restore access; wait for a newly reviewed target or cleanup                                      |
| Installation committed                               | Refused (`transition_installed`); going back is a new transition                                        |

- The Gateway persists the cancellation intent and blocks new install phases; the
  Node serializes install and release in its own fence transaction. No transaction
  spans both databases: the Node's committed receipt decides the winner and the
  Gateway converges to it after crashes. A local timeout never makes an in-flight
  install safe to forget. Racing cancel, acknowledge and install from two devices
  produce one result; the loser reads it.
- Only an explicit user cancellation may void an accepted transition whose Node
  outcome is unknown; automatic behavior is reconciliation only. There is no
  automatic rollback. Source-return consent authorizes no host command; deletion and
  Stop fences are stronger than a cancelled intent.
- Fence states: `fenced → stopping → supervisor_drained → installed | released`, plus
  `blocked` and `deleted`. `installed` and `released` are terminal; `installed` exists
  only together with a new binding generation.
- Install requires `supervisor_drained` and an evaluation of `confirmed`, or `unproven`
  with a matching acknowledgement. It re-observes the target and refuses if it no
  longer matches the frozen target. It appends a generation without clearing inherited
  risks and advances the epoch.
- Installation reports `bindingCommitted`, `policyValidated` and `runtimeReady`
  (`not_started`, `ready`, `failed`, `unknown`) separately; clients show "switched;
  execution not started" until the runtime is ready. A failed first launch neither
  reverts the binding nor runs in the old workspace.
- **Trusted notice.** Each installation has one logical environment notice (ID,
  source and target generation, rules revision). It is retransmitted with the same ID
  until the agent confirms application, including after restart (`sending` and
  `uncertain` notices are reconciled). Application is idempotent: duplicates add no
  transcript entry, wake no model turn, resume no task and copy no private context.
  No new effect or model turn is admitted before the notice is applied. A replacement
  agent gets the current metadata plus the required notices, not an old process's
  in-memory receipt. Old epochs, queued calls and approvals never become valid in the
  new environment.

**Source:** `plans/unified-completion-contracts.md` § C3 Cancellation, installation
and trusted context, § C0 Reliability and gate fixes; `plans/transition-installation.md`
§ Acknowledgement, install and release (Node).

## 7. Transition read model and recovery

- Discovery and receipt reads under `/api/sessions/{id}/environment-transitions` never
  need a control lease and never advance an effect. Writes (confirm, acknowledge,
  cancel, reauthorize, reconcile) need current control, a stable request identity and
  the expected plan or status revision; acknowledgement also carries the evaluation
  ID and digest. Reusing an ID with different input is a conflict. An optional
  `advance` is only a recovery hint; backend continuation never depends on it.
- The read model holds: identity (operation, kind, status revision, plan identity);
  plan (public Node, workspace and resource IDs only, never private paths, session IDs
  or secrets); progress (stage, wait reason, safe actions); authority (expiry,
  reauthorization requirement, never the credential); revocation (current and
  inherited summary, evaluation ID, digest, counts, acknowledgement state); outcomes
  (settlement, readiness, cancellation or install result, uncertainty); ordering
  (snapshot watermark, update revision, final-result identity). Stale evidence
  triggers a background refresh; a GET never performs a transition.
- `activeTransition` is a summary pointer. A last-finished summary and paged history
  let a reload or another device find results. Retention keeps unknown work and
  cleanup references; compaction leaves a tombstone and never frees an unresolved
  fence.
- A Node fence without Gateway acceptance is `reconciliation_required`; only
  inspection, adoption of matching retained intent, or scoped cleanup and cancel are
  offered. A fence never stands in for consent.
- Every durable `accepted` row is eligible for bounded recovery: read the Node
  receipt first, then send the same phase only if it definitely did not start and
  authority is valid. A changed plan or expired authority becomes an explicit review
  state. A read 404 alone is not proof that nothing started.

| Condition                       | Response                                                                                     |
| ------------------------------- | -------------------------------------------------------------------------------------------- |
| No authentication or read scope | Existing concealment; another user's object is not disclosed                                 |
| Authorized object missing       | `preview_not_found`, `acceptance_not_found`, `receipt_not_found` or `conversation_not_found` |
| Plan or evidence changed        | Conflict with the current revision (`plan_changed`, `evidence_changed`)                      |
| No current control              | `control_required`; reads stay available                                                     |
| Authority expired or revoked    | `operation_authority_expired` / `operation_authority_revoked`, with safe actions             |
| Node offline or unsupported     | Distinct unavailable or unsupported reason; uncertainty kept                                 |
| Already installed or cancelled  | Idempotent authoritative result; no new effect                                               |

Required failure behavior:

| Failure                                          | Result                                                                                   |
| ------------------------------------------------ | ---------------------------------------------------------------------------------------- |
| Gateway crash after acceptance, before the fence | Reconcile the same phase; unknown stays unknown; never a second acceptance               |
| Node restart during drain                        | Fence stays; journals reconcile; evaluation is `pending` or `blocked`, never `confirmed` |
| Reply lost after stop, acknowledge or install    | Same identity read back; no second step                                                  |
| Target removed or changed before install         | Install refused; safe cancel may stay pending; invalid source rights are not restored    |
| New unprovable item after acknowledgement        | Digest mismatch; install refused until acknowledged again                                |
| Two devices act at once                          | One outcome per operation; the loser reads it                                            |
| Old model reply proposes a tool call             | Refused by fence and epoch under either binding                                          |
| Node offline throughout                          | Stage stays pending; nothing reported revoked or installed                               |
| Conversation deleted mid-transition              | Fence `deleted`; journal closes with a tombstone; nothing installs                       |

**Source:** `plans/unified-completion-contracts.md` § C4 Gateway read model and
recovery contract; `plans/transition-installation.md` § Failure matrix.

## 8. Switching Nodes

- A switch changes the binding only. Conversation, tasks, authorship and provenance
  stay; resumed work is a new attempt on the target. Old attempts, commands,
  approvals, terminals and browser handles never become target objects. Matching
  repository names, remote URLs or path spellings are not evidence of equivalent files
  or authority.

| Material                                  | On a switch                                                                         |
| ----------------------------------------- | ----------------------------------------------------------------------------------- |
| Saved dialogue and task records           | Stay attributed; authorized context moves through a trusted host path               |
| Active rules and capabilities             | Resolved for the new binding; old rules are history                                 |
| Files, uncommitted changes, build outputs | Stay at the source; no copy, reset, stash, checkout or overwrite                    |
| Shells, background commands, dev servers  | Reconciled on the old host; processes and ports do not migrate                      |
| Browser state, cookies, credentials       | Stay with their owner; nothing transfers                                            |
| Approvals, file references, checkpoints   | Keep original targets; future operations revalidate                                 |
| Project resources on another Node         | Shown unresolved; need authorized target resources or an explicit membership change |

- Flow: preview (no user commands run; affected tasks, source-only files and missing
  dependencies shown; a same-spelled path is a different resource) → confirm against
  the preview revision (cancel before acceptance changes nothing; material changes
  need a new preview) → fence and reconcile the source → prepare the target only after
  source revocation is acknowledged (a preview never creates a folder; missing mounts
  stay unresolved) → commit with target acknowledgement and deliver the notice before
  further effects → continue deliberately (no old command replayed on the new folder;
  an explicitly stopped task stays stopped; queued work for the old binding waits).
- Clients show saved history and keep drafts while applying, but send no effect under
  the old binding.
- Missing or partial context blocks the switch; it never starts an empty replacement
  or treats a client cache as complete history. The whole private state directory is
  never copied.

| Condition                                    | Behavior                                                                         |
| -------------------------------------------- | -------------------------------------------------------------------------------- |
| Source offline or stop outcome unknown       | Gateway dispatch fenced; pending acknowledgement shown; no duplicate replacement |
| Target offline, full or unsupported          | Blocked with retry or change-target; revoked source access is not restored       |
| Failure between source stop and target ready | Resume the same transition from recorded acknowledgements                        |
| User changes their mind after acceptance     | A new revision or recovery choice; completed effects are not undone              |
| Two devices pick different targets           | Serialized by revision; one transition or a conflict, never two bindings         |
| External effect may have happened            | Known or unknown outcome reported; a new Node is not permission to resend        |
| Prepared folder has later user edits         | Preserved and located; no recursive cleanup                                      |

- Copying or synchronizing files between Nodes is a separate future operation. A
  checkpoint recovery workspace keeps its isolation when Nodes change.

**Source:** `plans/conversation-execution-contracts.md` § 4 Switch Nodes without
implicit migration.

## 9. Folder access: grants, deny and overlaps

- A mount presents a resource; a grant is a scoped permission with issuer and
  provenance. Node, resolved folder, mount alias, project membership, conversation
  grant and binding revision are separate identities. Two aliases of one folder are
  one lock identity. Every directly mounted resource of an attempt resolves on its
  Node.
- Resource identity includes host namespace and physical identity. Renames,
  remounts, inode reuse and symlink, hardlink or bind-mount aliases need
  backend-specific checks at open and effect boundaries; an arrangement the backend
  cannot check fails visibly. A path string or `realpath` alone is not isolation.
- A conversation grant is `{grantId, path, access, createdAt, revokedAt}` with access
  `read`, `write` or `deny`, canonical at creation. Read and write grants lie under the
  Node's configured grant roots (none configured means nothing is grantable); a deny
  may also target paths inside the workspace or an existing grant. Revoked grants are
  retained.
- Effective access, in order: deployment restrictions and protected state; an
  explicit deny overrides every overlapping grant and the workspace itself, for the
  path and everything below, including old approvals and permissive presets; among
  remaining grants, one must cover the operation and target (a read-only grant does
  not deny writes allowed by a separate visible grant, so the view shows effective
  access and its sources); a removed project grant excludes its subtree from ambient
  reads unless an independent grant remains; then approval policy, binding revision
  and readiness. A grant alone never authorizes every effect or removes a writer
  conflict.
- The effective-access view never implies a restriction the backend does not enforce.
- New additional mounts default to read-only; existing explicit grants survive
  switches; nothing is widened implicitly. A read-only alias under a writable parent
  shows the effective writes instead of promising a read-only boundary.
- Grants reach every backend through the session sandbox policy (write → allowed
  paths, read → read-only dirs, deny → deny read and write). An unavailable backend
  starts nothing. Recovery checkpoints start without inherited grants.
- While any deny is active, new host-management commands and host terminals for that
  conversation are refused (`folder_deny_unenforceable_on_host`).
- Creating or revoking a grant needs current control. Widening also needs no pending
  transition; narrowing (deny or revoke) never waits and instead makes a pending
  transition's frozen target stale (`stale_transition_target`). Every change advances
  the runner epoch (staling old approvals) and stops the runner and isolated
  terminals; the next start uses the new policy; stopped work is not restarted. The
  reply states whether containment can be confirmed on this backend.
- Grants are part of a transition's reviewed target; cancelling never restores a
  revoked grant.
- **Leave project** removes project-derived grants and discloses every independently
  granted overlapping path before confirmation and afterwards; it never claims "no
  access to /repo" while `/repo/docs` is still granted. **Block a folder** adds a
  read and write prohibition for this conversation's tasks, attempts and scoped
  descendants (delegation cannot shed it), not for unrelated conversations. Removing
  a block is an explicit change with a preview; a new mount never removes one.
- Revocation reuses the transition flow: retire workers holding forbidden access,
  recheck queued calls, approvals and delegated grants; offline or unsupported hosts
  stay pending; no "removed" success while old authority is live. Enforcement covers
  file tools, PTC, shells, terminals, background descendants and host-mediated
  preview and download.
- A per-tool capability inventory (files, PTY, host execution, browser, network,
  sources, calendar, memory) records actor, resources, effect boundary, revocation
  participant and supported backend.
- Managed folders use a stable reservation key, allowed-root and quota checks,
  race-resistant creation and an owned receipt, adopted by the first accepted send.
  An explicit Create folder is user-owned at once and survives draft abandonment. A
  lost response inspects the reservation; an unrelated same-name directory is never
  adopted, and a folder with unowned or user changes is never deleted. Orphan cleanup
  applies only to proven system-owned, unadopted reservations under a configured
  policy.
- A removed or missing main folder blocks new execution until explicitly replaced;
  home, the old project or another writable mount is never chosen silently.

**Source:** `plans/conversation-execution-contracts.md` § 3 Resolve overlapping
folder permissions explicitly; `plans/folder-grants.md` § Model, § Changes and
fencing; `plans/unified-completion-contracts.md` § C6 Projects, folders and
collaboration (Resources, allocation and fan-out).

## 10. Projects and collaboration

- Leaving a project preserves saved history but removes new project-derived access.
  Independent disclosed grants survive; an explicit deny wins. Bytes already read by
  a model or user are not erased.
- Project changes create a versioned change batch with affected membership
  generations and per-binding desired and applied revisions. Joining and leaving are
  serialized against it, so a joining member cannot miss a frozen revocation. Grants
  are fenced before removal is reported. Offline Nodes stay pending with new commands
  blocked; partial success is visible; retries reuse batch and member identities. No
  rollback restores revoked access.
- Hard policy and grants constrain every rule layer. Guidance follows system →
  project → conversation precedence, each within its parent's authority. Repository
  content is untrusted input, not a policy tier. The effective rules revision is
  pinned at model and tool admission; edits apply at the next safe foreground turn;
  access changes use immediate fences.
- The Gateway owns versioned notes and board metadata; content may stay on the Node
  with availability receipts, and Node secrets never move to the Gateway. Notes use
  compare-and-swap revisions; concurrent edits return a conflict with both versions.
  Board posts are append-only attributed events; edits and redactions are new events.
  Neither agent suggestions nor board text become approved rules or user commands.
  Durable notes have no age-based expiry; board compaction keeps unresolved waits,
  active task links and provenance. Roles: reader, proposer, editor; adopting project
  rules stays a user action. Missing retention or editor configuration keeps
  collaboration writes and expiry off.
- A wait records waiter, holder, resource, lease revision, scope, cancellation identity
  and wake cursor. Conflicting writers queue fairly, recheck on wake and reread before
  editing. Leases release at a safe boundary. Cycles (including a parent waiting on a
  child) surface as a coordination conflict; no model polling, forced unlock or
  killing an active writer.
- Git worktrees share metadata and are not sandbox copies; recovery defaults to an
  independent copy. Integration back uses revision checks and three-way comparison
  and preserves user edits. Exclusive claims across Nodes on shared storage need a
  proven shared broker; until then such storage has no exclusive-write guarantee, and
  external writers remain detectable conflicts, not locks.

**Source:** `plans/unified-completion-contracts.md` § C0 (context decision A), § C6
Projects, folders and collaboration.

## 11. Isolated work and host management

| Path            | Use                                                  | Authority                                                         | On environment change                                                                   |
| --------------- | ---------------------------------------------------- | ----------------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| Isolated work   | Ordinary agent work and work terminals (the default) | Current mounts, rules and scoped grants, enforced by the backend  | Old processes and resources retire; the new binding installs only with acknowledgements |
| Host management | Explicitly chosen host administration                | A separate explicit user grant; never model text or `full-access` | Pending or blocked waits; residuals need per-operation consent and stay recorded        |

- Choosing a path for new work never converts a running process or widens its grant.
  Approval modes are separate: fewer prompts never authorize leaving the execution
  boundary.
- Unsupported isolation returns its status and keeps the user's request; it never
  runs on the host instead. Running under a sandbox does not prove that descendants,
  descriptors or delegated effects can be retired later.
- Host management records its conversation and environment origin. Closing a
  terminal panel, an exited direct shell, a finished observer or an empty registry
  never proves revocation. No force-clear, guessed PID or process-name kill, replay
  or fabricated acknowledgement. External effects keep their known or unknown
  outcome; a host command that changed a service is not undone by ending its shell.
- A host-management command or terminal needs a Node-issued review bound to the exact
  intent (command or shell, directory, workspace, runner epoch, mode snapshot,
  control), positively confirmed, unexpired and consumed once, atomically with the
  run reservation, before spawn. Repeated requests grant nothing more; lost requests
  and restarts never execute again.
- Isolated launches: a trusted launch guard keeps shell or loader hooks and user code
  from running before the scope is committed; only needed descriptors are inherited;
  the PTY keeps job control; identity and closure evidence survive request loss and
  restart without PID guessing or re-running the command. Direct process, child
  scope, PTY I/O, proxy and other resources retire independently; one participant's
  failure skips none of the others and frees no conflicting write range.
- Terminal requests: each user action has one client-generated request ID; a retry
  with the same ID and intent is deduplicated, a changed intent is a conflict, and
  after a reconnect, lease change or resize recovery is read-only. A lost reply is
  resolved by reading the request; "not found" for that request means not admitted and
  allows re-sending the same ID, never a new one. Unresolved requests are discoverable
  without control. A request in `outcome_unknown` is never retried automatically;
  acknowledging it only hides it from discovery and keeps its blocking effect.
  `unconfirmed` (closed shell, retirement unproven) keeps transitions blocked with no
  force-clear. Terminals show their path (isolated or host management); unlabelled
  terminals are never shown as isolated.
- A backend without isolated terminals (for example macOS) offers host management
  only as a separate, explicit action; the client never switches paths by itself.

**Source:** `plans/execution-isolation.md` § Accepted behavior, § Engineering
contract, § Client terminal execution-path contract v1.

## 12. Checkpoints and recovery

- Recovery applies a selected agent change **against the current workspace** in a
  **new recovery workspace**. The original directory, Git index, refs, user changes
  and running agents are never renamed, deleted, reset, stashed, staged, committed or
  cleaned. There is no automatic in-place restore or force overwrite.
- Invariants: (1) baselines capture actual bytes, including uncommitted user changes,
  never `HEAD` alone; (2) only effects attributed to the agent are candidates; a
  timestamp, Git diff or shared session ID is not attribution, and uncertain changes
  get no automatic inverse; (3) later writes survive through an inverse three-way
  merge, and a later write to the same hunk is a conflict; (4) the source is only
  read, results are built in a fresh Node-owned destination published only when its
  job is `ready`, and never hard-linked to mutable source files; (5) a preview is
  versioned and becomes stale when the source changes; (6) missing objects,
  interrupted captures, unsupported files or untrusted identity produce an explicit
  gap, never an empty or successful result; (7) jobs are durable, idempotent and
  crash-safe; half-built output is never exposed and a recovery never deletes its
  source evidence.
- Shared-directory checkpoints attribute writes to a run group; shell, daemon or
  editor writes outside the write boundary are **observed**, not owned. Reliable
  per-agent recovery needs isolated execution workspaces created by the Node's
  workspace factory (never an agent-chosen root), starting from a capture that
  includes dirty files, with one writer group each. Preparation runs no repository
  hooks, filters, submodule init or project scripts and preserves deny-read
  restrictions at the new root.
- Merge rules: an agent-created file is removed only if it still equals the agent's
  version; a deleted file is recreated only if the path is still free; binaries
  invert only on an exact match; renames use verified path history; directories are
  never recursively deleted; symlinks, hard links, submodules, ACLs and special files
  are explicit exclusions; setuid, setgid and ownership are never restored.
- Before continuing in a recovery workspace, source observation, job revision,
  conflicts and trust are revalidated. Continuing creates a linked workspace and a
  new blank conversation; it does not retarget a live runner, replay tool effects,
  replay source memory or write to the source repository's memory.
- Recovery is a user-only operation; agents can report checkpoints but cannot approve
  recovery, change retention or discard conflicts. Nodes re-enforce authorization,
  root identity and journal state. Repeated requests return the existing job; a second
  device's confirmation disables the first device's stale action. Offline Nodes allow
  viewing cached metadata only; no action is replayed from an offline queue.
- Checkpoint storage is private Node state denied to the agent sandbox and never sent
  to a model by default. Coverage exclusions are reported. Retention and quotas are
  configurable; active runs, pinned checkpoints and live recovery inputs are never
  evicted (capture suspends visibly instead), and an opened or modified recovery
  workspace is never deleted automatically.
- Recovery is independent of editing a message or regenerating; changing a
  conversation branch never undoes files.

**Source:** `plans/checkpoints.md` § Product decision, § Safety invariants,
§ Multi-agent behavior, § Capture and storage, § Recovery algorithm, § Original
service/API sketch, § Memory integration acceptance.

## 13. Archive, leave and delete

| Action                          | Execution                                                                       | Data                                                                                                |
| ------------------------------- | ------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| Archive conversation or project | Organization only; no stop, no membership change                                | Tasks and schedules continue within grants; needs-you indicators stay visible outside the archive   |
| Unarchive                       | Same IDs return                                                                 | No replay, restart or re-creation                                                                   |
| Leave or move project           | Dialogue kept; grant transition of section 9                                    | Files and history kept; project rules, notes and board access removed; independent grants disclosed |
| Delete conversation             | New work fenced; work scoped to it stopped and reconciled                       | Owned content removed; user folders and independently owned records kept                            |
| Delete project                  | Membership, dispatch and member conversations fenced; affected hosts reconciled | The confirmed member set and project-owned state deleted; external resources kept                   |

- "Owned" needs recorded provenance, never a matching path, file name, repository key,
  author label or current membership. A mounted folder is never project-owned data. A
  shared task reference does not make a task owned twice.
- Mounted folders, repositories, commits and explicitly created work folders are
  preserved. Session scratch is removed only when positively session-owned, unreferenced
  and in scope. Uploads lose their owned associations; bytes are collected only when
  no surviving owner needs them. External schedules survive; a schedule whose target
  was removed is blocked and shown for repair, never retargeted. Independently owned
  delegated work and user-taken-over work stay. Checkpoint evidence and opened
  recovery workspaces stay. Other conversations, exports, logs, backups and provider
  copies are outside automatic deletion and are disclosed.
- Memory: deleting a conversation deletes memory entries originally created there,
  their versions and proposals; entries created elsewhere stay even if it edited them.
  Deleting a project classifies entries by write-time version origin: all versions
  from the project → forget; a project-authored suffix → roll back to the last outside
  version; mixed histories → the user's Forget/Keep/Edit choice at a current
  revision. Project deletion runs this plan once; cleaning its member conversations
  never runs a second standalone purge that would undo those choices. A moved
  conversation keeps its old versions' original scope. A model-supplied project label
  is not provenance.
- Flow: current preview (what stops, is deleted and remains) → confirm that exact
  scope (changes invalidate it; cancel mutates nothing) → record intent and fence new
  membership, dispatch, writes and retrieval → stop and reconcile workers, terminals,
  browser sessions, children and memory writers → clean with provenance and per-host
  steps (no broad recursive delete) → report complete only after required steps are
  acknowledged, publishing content-free deletion identities so late results, old
  snapshots or clients cannot resurrect the entity. Receipts never copy deleted text.
- Partial deletion shows "deleting / needs attention"; a retry resumes the same
  operation. Once destruction starts, cancel cannot restore content or authority.
  Offline hosts stay pending; offline files are not claimed deleted. Ambiguous
  ownership is preserved and reported. Remote effects already completed are reported
  as not undoable.

**Source:** `plans/conversation-execution-contracts.md` § 5 Archive, leave and delete
with explicit ownership; `plans/unified-completion-contracts.md` § C7 Context,
deletion, memory and content.

## 14. Context custody and data kinds

- Moving context to another Node uses an authorized, durable context package (history
  watermark, ordered partial outcomes, rule and binding revisions, provenance,
  integrity and size), exported through a trusted host path before the only context
  owner retires. Completeness is validated before the target admits work; an
  unavailable source or partial export blocks the switch. Compression keeps source
  references; revoked live links do not become read permission.

| Data                              | Rule                                                                                    |
| --------------------------------- | --------------------------------------------------------------------------------------- |
| Personal and pot memory           | Explicit scope; adding a folder or project to a conversation never grants it            |
| Repository journal, project notes | Separate grants; immutable write-time membership and source provenance                  |
| Saved message or upload           | Original ownership and reference rights; never reinterpreted as a live mount            |
| Live file                         | Host, resource and version identity plus the current grant at each fetch                |
| Managed cache                     | Partitioned by server identity and account; invalidated by object and deletion revision |
| User export                       | A disclosed user copy; no claim of remote erasure                                       |
| Recovery continuation             | New private restricted binding, independent directory, memory writes disabled           |

- Deletion uses one immutable cleanup plan per deletion scope with per-host receipts
  and dependency pins. Offline tombstones prevent resurrection; compaction needs a
  valid resync boundary.
- Memory writes capture the verified session, membership revision, binding
  generation, workspace, Node, mode and policy revisions in the same transaction.
  Approvals and restores copy the original snapshot; nothing recomputes an origin from
  where a conversation lives today. Direct user edits have a user origin. A memory
  write whose binding changed while waiting returns `stale_environment` and writes
  nothing.

**Source:** `plans/unified-completion-contracts.md` § C7 Context, deletion, memory
and content; `plans/conversation-binding-migration.md` § Memory write-time source
snapshots.

## 15. Saved content and live file references

- A message part is saved text, an attachment or a reference to mutable content. Its
  kind, owner, source conversation and project, Node and resource identity, content
  version, required grants and lifecycle are persisted. A file name, identical bytes
  or URL is not an ownership grant.

| Kind                                     | Expectation and boundary                                                                           |
| ---------------------------------------- | -------------------------------------------------------------------------------------------------- |
| Saved text, tool excerpt, captured image | Stays as saved; may differ from the current file; governed by conversation access and deletion     |
| Independently owned attachment           | Current attachment authority; moving a conversation transfers no ownership                         |
| Live file reference                      | Current allowed content with source and version; grants, Node and identity rechecked on every open |
| Cached preview, thumbnail or range       | Possibly stale; keeps provenance and account separation; never promoted to an attachment           |
| Recovery artifact                        | Tied to its recovery job's authority; the source path is no substitute                             |
| User export                              | Disclosed as not recallable                                                                        |

- Open flow: resolve the typed reference from the backend (never against a newly
  selected folder or a same-named file on another Node); check the owning record or
  the current grant; fetch through backend authorization (an internal URL or locator
  is not authority); show source and saved or current status, distinguishing no
  access, Node offline, missing file, stale reference and interrupted transfer, and
  never retry a denial or substitute another file; cache with provenance; on
  revocation, account change or deletion, invalidate live-fetch capabilities and stop
  transfers at the enforceable boundary.
- Download tokens are bound to audience, server, account, object, revision and scope
  with a finite expiry; no Node secret appears in a public response. A resumed range
  needs the same revision and current permission; a changed source refuses the resume
  and never splices versions. Exported files are never overwritten without an
  explicit destination choice.
- An explicit save or copy may create a separately owned attachment with provenance,
  checked at that moment. Leaving, deletion or denial never triggers an automatic
  copy. A content hash may deduplicate storage but never merges ownership or reveals
  another owner's bytes or metadata.
- Saved uploads record an immutable origin with their row, scope and source Node and
  mode; scope and origin cannot be updated. Consuming an attachment rechecks ownership
  and deletion, reads without following a leaf symlink and verifies size and digest;
  missing or replaced data fails as `attachment_storage_unavailable`.
- Offline: cached content is shown as stale; reconnecting needs new authority checks
  before fetching. Another account never sees cached records, search results or
  existence metadata of the previous one. Deletion revisions outrank old snapshots,
  and an offline cached record never becomes a new upload.

**Source:** `plans/conversation-execution-contracts.md` § 6 Separate saved content
from live file references; `plans/unified-completion-contracts.md` § C7;
`plans/conversation-binding-migration.md` § Saved attachment origins checkpoint.

## 16. Command admission and bindings

- Ordinary commands carry `expectedBinding`, the binding the user saw when acting.
  The Gateway checks ownership, availability, control and that binding while
  reserving the command, and records its environment with the receipt; a stale
  binding returns `409 stale_environment` with no command row, and the client keeps
  the unsent input. Duplicates return the existing receipt without dispatch; the same
  ID with another environment is a conflict.
- Before dispatch the Gateway probes the exact Node connection; the forwarded
  environment is the Gateway's, never a client-chosen destination. The Node records
  the origin atomically with its receipt and, after queue and startup waits, asks the
  Gateway to revalidate command, ownership, environment and control; an unknown or
  unavailable answer rejects dispatch. These are point-in-time checks, not a lease
  over later effects (see [Open acceptance gaps](#open-acceptance-gaps)).
- Stop does not require an up-to-date visible binding but still requires ownership
  and control. A deleting conversation admits no new commands.
- Membership revision and execution generation are independent and positive; a Node
  re-announcement, rename, runner restart, lease change or first private mapping
  advances neither. The public binding contains the public Node ID, never the private
  Node session or path. Configured mode and workspace policy histories are
  append-only; configuration revisions are not installed-policy acknowledgements.
- First send: an unknown outcome is reconciled on the server (receipt first, then a
  durable Node-side void of the command ID); a refused attempt is reported as not
  executed so the explicit retry applies; a request that provably never left the
  Gateway may be sent again with the same command ID. A new attempt is always started
  by the user. An accepted request is never re-sent through another flow after a
  timeout.

**Source:** `plans/conversation-binding-migration.md` § Identity mapping and current
migration, § Explicit membership and configured policy, § Command admission
checkpoint, § Node command authority checkpoint; `plans/unified-completion-contracts.md`
§ C0 Reliability and gate fixes.

## 17. Synchronization and feature gates

- Snapshots and events share one server and account namespace, a snapshot watermark
  and monotonic entity and decision revisions. Subscribing from the watermark leaves
  no gap; duplicate events are idempotent. If cursor history was compacted, the
  server returns `resync_required` with a new snapshot and tombstone boundary.
- Deletion and resolution revisions win over late output, pushes and stale snapshots,
  not client receive timestamps. A snapshot or stream never exposes a resource the
  viewer may no longer read.
- Capabilities are explicit and versioned; support is never inferred from a package
  version. A capability is advertised only when its contract is implemented and
  accepted. A peer without a required capability is refused, never emulated with a
  weaker mechanism such as a stale control lease.
- Disabling a feature blocks new acceptance only. Receipt reads, cancellation,
  cleanup and reconciliation of committed effects stay available; any new effect still
  needs its own authority. No flag bypasses grants.

**Source:** `plans/unified-completion-contracts.md` § C9 Synchronization,
compatibility and rollback.

## 18. Content and request safety

- State-changing API calls require the request-shape header; forged shapes under
  browser or device identities leave stored state unchanged.
- The app attaches its paired credential only to app-initiated requests; requests made
  by content withhold referrer and origin.
- Remote images and media in untrusted content load only after user activation, in a
  new context without referrer or opener; there is no Gateway image proxy.
- Rendered content stays inside its box: no fixed layers, transparent click catchers or
  transforms escape it, and diagram styles are isolated.
- Controlled attachments are identified by trusted server-issued identifiers, never by
  URL shape; relative and same-origin URLs in content are gated like any other.

**Source:** `plans/unified-completion-contracts.md` § C0 Reliability and gate fixes.

## Open acceptance gaps

Invariants above that are specified but not yet accepted:

- **Native Linux acceptance** of isolated work terminals, kernel containment and
  terminal I/O owner recovery, fully confirmed switches, deny enforcement and the
  checkpoint suite under bubblewrap. Synthetic kernel adapters do not close it.
- **Real browser and device journeys** for environment switching, terminal requests
  and checkpoint review and continuation, including two live clients.
- **Transitions:** cross-Node switching and context custody; project mounts and
  project-mount policy receipts; adoption or cleanup of a bare Node fence (also one
  without a stored preview); readiness refresh for a device without control and
  readiness in history summaries; an explicit rules-revision watermark at admission;
  status revisions and snapshot watermarks in the read model (not recorded as
  delivered); a configured finite per-kind operation deadline (none is chosen).
- **Bindings:** extend the point-in-time command checks to approvals, agent queues,
  internal deliveries and actual effect boundaries; record acknowledged installed
  policy; extend provenance to live files, previews, grants and project membership.
- **Folders and projects:** project-level grants and fan-out, managed folders, alias
  identity beyond `realpath`, notes, board, waits and shared storage. On backends
  without containment, a grant change counts as an unprovable generation even when
  no runner was live (over-reports, never hides).
- **Terminals:** a guided manual-inspection path for `unconfirmed` requests.
- **Checkpoints:** physical power loss, real full disk and distributed filesystems;
  per-turn shortcuts, cross-session filtering, multi-operation ranges and reviewed
  disposal of retained recovery workspaces.
- **Tasks and content:** the canonical task model, routing, live-file reference flow
  and data-kind rules of sections 2, 3, 14 and 15 have no complete implementation
  yet.

## Dropped as obsolete

Contracts in the sources that pirc 2 does not keep (decisions P1–P19 in
[Open work](../../plans/README.md#decisions)):

- `unified-completion-contracts.md` § C0 status snapshot, four-state table and format
  numbers: delivery diaries, not contracts.
- `unified-completion-contracts.md` § C0 legacy session-create limitation (no
  idempotency key): legacy creation is deleted (P6, roadmap M2.1).
- `unified-completion-contracts.md` § C0 "Node without the void operation is marked
  needing an upgrade": no mixed old Nodes are supported (P5).
- `unified-completion-contracts.md` § C0 old clients get an update message: replaced by
  the single capability document and `426 client_upgrade_required` (roadmap M2.4).
- `unified-completion-contracts.md` § C2 "migrations leave unassignable legacy evidence
  explicit" and the R3 legacy-row case: fresh schema baseline, no migrated evidence
  (P5).
- `unified-completion-contracts.md` § C3 `transitionReleaseVersion` and the broad-release
  version 1: version negotiation with older Nodes (P5).
- `unified-completion-contracts.md` § C4 "freeze old-client parsing": no old clients
  (P5, P13).
- `unified-completion-contracts.md` § C5 "inventory old IDs and build alias fixtures
  before migration" and "single-lifetime pots dispatch stays until its mapping
  migration": no migration (P5); the old pots tracker is replaced (P2, roadmap M4).
- `unified-completion-contracts.md` § C5 compatibility mapping for legacy delegation's
  cross-device 409 Stop: assistant delegation is replaced by pot work dispatch (P3,
  `pots.md`).
- `unified-completion-contracts.md` § C7 "legacy insufficient provenance stays
  explicit": no legacy data (P5).
- `unified-completion-contracts.md` § C7 "cross-Node custody is not part of T1–T5":
  delivery scoping; cross-Node switching is listed as an open gap instead.
- `unified-completion-contracts.md` § C8: pot configuration and budgets moved to
  `pots.md` and `usage.md`.
- `unified-completion-contracts.md` § C9 per-contract capability names, old APK and Node
  compatibility fixtures, "keep existing permitted old flows working", migration
  paging, backups and code/data rollback floors, and cases V2–V4: no compatibility or
  migration (P5, P6).
- `unified-completion-contracts.md` § C10 and § C11: delivery gates, audit traceability
  and authorization wording, not behavior.
- `conversation-execution-contracts.md` § 1 Existing-mode migration requirements
  (mode-field mapping, `assistant` scopes, Chat/Work `ui` placement): no migration
  (P5); chat mode and the assistant are removed (P3, roadmap M4.10).
- `conversation-execution-contracts.md` § 5 "the current chat/project deletion guide is
  the compatibility baseline" and legacy membership classification: no legacy data
  (P5); the memory rules themselves are kept in section 13.
- `conversation-execution-contracts.md` § 6 migration of legacy upload ownership
  exceptions: no legacy uploads (P5).
- `conversation-execution-contracts.md` § 7 pots coordination: replaced by `pots.md`.
- `conversation-binding-migration.md` legacy adapter seeding, unversioned old-client
  commands allowed at generation 1 (`environment_required`) and missing-binding
  compatibility: every command carries `expectedBinding` (P6, roadmap M2.2).
- `conversation-binding-migration.md` § Mode-field inventory and preservation: chat
  mode and its `assistant`/`delegate` fields go with the assistant (P3).
- `execution-isolation.md` legacy host execution row and the omitted-path terminal
  setting `PIRC_LEGACY_HOST_TERMINALS`: deleted (P6, roadmap M2.3).
- `execution-isolation.md` "old clients that cannot make the explicit choice": no old
  clients (P5).
- `execution-isolation.md`, `transition-installation.md` capability version numbers
  and client storage format notes: implementation detail of retired clients.
- `transition-installation.md` § Node: binding generations and coverage: generation 1
  seeded as `legacy`, and the `legacy_history` evaluation item: fresh schema baseline
  (P5).
- `transition-installation.md` § Client contract (throwaway UI): the client is rebuilt
  (P1, P4); behavior is kept in sections 5–7.
- `checkpoints.md` § Web and native Android experience and Phase 1–5 records: UI of
  retired clients and implementation diaries.
- `folder-grants.md` § Slices and checkpoints: delivery records.
