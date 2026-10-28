# Unified conversation execution contracts

[Plans](README.md) · [Unified conversations](unified-conversations.md) · [pots](pots/README.md) · [Rust foundations](library-extraction.md)

Status: planning specification, 2026-10-24. The user accepted the seven follow-up
recommendations, first detailed items 1–3, then requested the same depth for
items 4–7. All seven now have flows, exceptions and future acceptance cases:
capability composition, message/task routing, overlapping folder permissions,
Node switching, lifecycle/deletion, content access and pots coordination.
This document records
target behavior and future acceptance cases; it does not implement or verify it.
The user subsequently authorized staged implementation; first-send persistence and
Web/native Android recovery are now implemented but remain gated. See the
[current progress snapshot](unified-conversations.md#current-progress-and-next-delivery-2026-10-28)
for delivered code, evidence and open acceptance. The
[U2 compatibility binding baseline](conversation-binding-migration.md) now persists
relationship versions, explicit project membership and configured policy snapshots.
Ordinary Web/Android commands also carry captured versions checked at Gateway
admission (schema 1025), with Node queue/startup rechecks (schema 2010). These
point-in-time checks do not fence all later effects or enforce
Node queues, approvals or tool effects. Its environment read model explicitly
reports enforcement as not tracked; it does
not implement authority-changing transitions.
The seven sections below remain target contracts; their cases are not automatically
verified by first-send or binding-baseline work. App authentication/topology and Flutter Web remain separate decisions.
The 2026-10-27 publication request covers accumulated commits and plan progress,
not deployment or release. The [integrated architecture review](unified-architecture-review.md)
retains the original design review and remaining gates.

The [browser-supervision checkpoint](unified-conversations.md#u4-implementation-checkpoint-durable-browser-supervision-2026-10-28) adds retained close outcomes and deletion/drain blocking in Node schema 2018. This does not fulfill per-effect browser revocation or replacement-policy installation.

The [foreground browser-effect checkpoint](unified-conversations.md#u4-implementation-checkpoint-foreground-browser-effect-admission-2026-10-28) checks captured actor/binding authority at the first CDP pipe write. Already-started frames finish for protocol integrity; shared background resources and complete revocation remain unverified.

The local [browser-resource checkpoint](unified-conversations.md#u4-implementation-checkpoint-browser-resource-guards-and-recorder-retirement-2026-10-28) adds environment-scoped manager background effects and recorder writes/exit observation. These resources survive ordinary controller/Agent changes; a fence retires the affected session without closing its workspace peers. Shared Chromium engine/network resources, descendant/descriptor containment and complete revocation remain open.

The local [page-resource checkpoint](unified-conversations.md#u4-implementation-checkpoint-page-owned-engine-and-network-admission-2026-10-28) binds engine initialization and intercepted network decisions to the owning page's environment. A late DNS result cannot authorize HTTP, authentication or a WebSocket-mock connection after revocation. Shared-context/unowned resources, established connections and full OS revocation remain outside this evidence.

The main plan owns domain lifetimes, retained context (decision A), revocation,
checkpoints and migration. This document refines those contracts. Names below
are logical concepts, not finalized API fields, database schemas or Rust types.

## 1. Compose capabilities without a Chat/Work switch

### Sources of effective capability

A unified conversation has a stable identity and a versioned execution binding.
Its visible location in the interface is never an authorization input. Separate:

- **Availability:** the selected runtime supports the tool/feature and conversation
  configuration enables it. Enabling a feature does not grant access to resources.
- **Authority:** the authenticated actor has a current grant for this operation,
  target and scope, within deployment policy and any explicit prohibitions.
- **Approval:** the existing operation approval policy permits this particular
  effect, or its matching pending decision has been resolved affirmatively.
- **Readiness:** the Node and required resources are available, the binding is
  current, and any required write lease or task dependency has been resolved.

An effect needs all applicable conditions. Show unavailable, unauthorized,
awaiting approval and waiting for a resource as distinct states. A hidden tool
name, a prompt instruction or an assistant's assertion is never enforcement.
Validate at dispatch and again at the effect boundary; do not use a stale model
request or old approval to recover removed authority.

### Capability mapping

| Capability                                        | Enabling context and authority                                                        | Effect boundary                                                                                                             |
| ------------------------------------------------- | ------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| Ordinary dialogue                                 | Current conversation access and configured model/runtime                              | No implicit grant to project files, other histories or administration                                                       |
| Read/list/search files                            | Available file tools plus effective read access to a resolved resource                | Node enforces on tools, shells and descendants; report the actual target                                                    |
| Edit/create files                                 | Effective write access and applicable operation approval                              | Node enforcement and writer coordination; read-only mounts do not become writable by asking the model                       |
| Commands and background work                      | Command capability, explicit workspace binding and relevant filesystem/network policy | Starting a shell does not grant broader child-process authority; background work has a tracked task                         |
| Project rules/notes/board                         | Current project membership and the relevant read/edit grant                           | Rules are user-controlled; notes are revisioned; board posts are attributed data                                            |
| Personal memory/history                           | Separately authorized memory/history scope and existing provenance rules              | Mounting a repository does not grant account-wide history or make project notes global memory                               |
| Browser, network, Sources, calendar and schedules | Their configured capability and operation-specific resource grants                    | Folder access does not grant browser cookies, external account access, wider schedule targets or permission to send/publish |
| Delegate/coordinate agents                        | Explicit dispatch scope, target capability and task lineage                           | Child authority is bounded by authorized delegation; seeing progress does not authorize sending instructions                |
| Provider/device/account management                | Verified management identity and scope                                                | Available only through the management boundary; never derived from a workspace mount or project rule                        |

A project may supply defaults and already-authorized project grants. An ordinary
rule or shared note cannot create a grant. Joining a project goes through the
membership/resource transition; copying its name or rules into a conversation
is not joining it. A conversation-specific grant retains its own provenance.

Approval presets remain independent from capability/resource grants. A setting
that reduces confirmation prompts does not cancel a resource prohibition. Any
execution path that cannot enforce the resulting policy is unavailable under
that binding, even if a tool exists with an unrestricted execution option.
Do not silently weaken the policy to accommodate that tool.

### Discuss-to-work flow

1. The user starts a conversation with its selected workspace or managed empty
   workspace. Retain choices in the draft; allocate managed storage at first accepted
   send unless the user explicitly invokes Create folder. Repeated first-send
   requests resolve the same allocation and conversation.
2. A question can be answered without a new mode or a new work session. Relevant
   rules are selected by current binding and scope; historical rules stay history.
3. When the user requests work, resolve the target and effective capabilities.
   If the chosen folder, grants and approval already suffice, continue directly.
4. If the target is ambiguous, ask about the target only. If a grant is missing,
   present the specific resource/action change; do not propose general full access
   as the automatic remedy. A failed request remains visible and recoverable.
5. Record substantial/background work as a task and bind each attempt to the
   current environment. The host may use a separate worker process while keeping
   the same visible dialogue, task identity and source attribution.
6. A capability/mount revocation follows the live transition protocol. A pending
   operation becomes denied/interrupted with its reason; it is not retried against
   a replacement folder. Already completed effects remain recorded.

Both clients show the selected Node, main folder, additional mounts and effective
access. Explanations should identify the missing prerequisite, such as a read-only
folder or an offline Node. Do not make users select Chat/Work to repair it.

### Existing-mode migration requirements

Inventory every field and consumer of `crates/pirc-protocol/src/mode.rs` before
changing behavior. Preserve existing custom mode IDs/configurations through an
explicit compatibility mapping; unknown fields or unsupported combinations do
not fall back to broader access.

| Existing concern                             | Target mapping and required review                                                             |
| -------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| `workdir`, repository and project resources  | Versioned main directory/mounts plus explicit project grants and provenance                    |
| `prompt`, `body`, project instructions       | Ordered, attributed active rules; old conversation text is not current policy                  |
| `features_on/off`, `tools`                   | Availability filters plus enforcement on every underlying operation, including PTC wrappers    |
| `assistant`, memory, recap/history           | Enumerated read/write scopes; never blanket-upgrade every old session to full assistant access |
| `delegate`, `delegate_target`, team tools    | Allowed actor/target relationships, bounded delegation and loop prevention                     |
| `schedule_scope`, project/session management | Explicit target/resource scopes; no expansion from `own` to `any` on migration                 |
| `ui` and Chat/Work placement                 | Presentation only; remove navigation coupling after preserving capability checks               |

The current full-assistant/workdir and delegator/target validation restrictions
cannot simply be deleted. Replacement checks and conformance fixtures must prove
how each old restricted combination remains bounded. A reusable agent loop does
not own these checks; it receives host-approved model/tool progression.

### Acceptance cases to implement later

- Ordinary chat becomes authorized repository work in the same conversation
  without a new mode prompt, lost context or duplicated work session.
- A read-only folder can be inspected; a write request gets a scoped explanation
  and cannot succeed via a shell/PTC wrapper or child agent instead.
- Project notes cannot turn on account-wide history, management or external-send
  privileges. A capable tool with a missing grant remains denied.
- A pending approval followed by mount revocation cannot execute the old action;
  both clients show the new reason and preserve any partial result.
- Old custom modes preserve their operation scopes; unsupported combinations are
  reported clearly, and existing memory/checkpoint provenance remains intact.

## 2. Route new messages while tasks run

### One foreground response flow, multiple attributed tasks

Each conversation has one active foreground response owner at a time. This is a
logical coordinator, not a requirement to keep one OS process alive. Independent
child/background tasks may run concurrently, each with its own context, attempt
and authorized workspace. They cannot append competing unlabelled assistant
streams to the main dialogue.

The backend records a foreground ownership generation and orders accepted input.
This is separate from device control leases, pots coordination authority and file
write leases. A second device does not create a second foreground owner by opening
or sending to the same conversation; existing command-control rules still apply.

A message records its authenticated author, command identity, conversation,
selected task if any, and the state/revision the user was viewing. Routing records
whether it is a question, task direction, separate objective or explicit control,
and its accepted target. A client-provided actor label cannot impersonate pots or
the user. Text from tools, files or another agent cannot become a user command.

### Routing table

| Input and context                                     | Target and behavior                                                                                                                  | What remains unchanged                                                                |
| ----------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------- |
| No work active; ordinary question                     | Foreground answer; no task required solely for answering                                                                             | Existing task history and workspace grants                                            |
| Running task; “explain that error”                    | Foreground side question associated with the relevant task; keep its work state visible                                              | Does not automatically cancel tools, create a new objective or mark the task complete |
| Running task; clarification/correction                | Same task with an attributed directive revision; reconcile affected pending/in-flight work before continuing it                      | Task identity, completed effects and unrelated tasks                                  |
| Clearly independent new objective                     | Create/queue a separate task when tracking is appropriate; show its target and queued/running state                                  | Does not silently replace or cancel the earlier objective                             |
| Message from a task detail or explicit task selection | Route to that task through the foreground coordinator; any background reply is task-attributed                                       | Does not create a duplicate task or pots conversation                                 |
| Explicit Stop control for a task                      | Host fences new affected work and requests cancellation of that task and its scoped descendants without waiting for a model response | Unrelated tasks; completed effects are not rolled back                                |
| Explicit pause/resume control                         | Record its scope and reconcile the task state before acting                                                                          | Pause coordination alone does not mean processes stopped                              |
| User reply to an approval/question                    | Resolve only the identified pending decision with its revision and current authority                                                 | A general chat message cannot approve every pending action                            |
| Ambiguous target with several tasks                   | Ask a short target question before applying the ambiguous directive                                                                  | No guessed cancellation, retargeted write or duplicate dispatch                       |

A new objective may execute concurrently only if granted resources, dependencies,
isolation and concurrency policy allow it. Otherwise show it queued with a reason.
One foreground response flow does not mean every background task is serialized.

Natural-language corrections come from the real user but still need interpretation.
Record when the target and directive were accepted; fence obsolete work at that
boundary. Explicit Stop and resource-revocation controls have a direct host path.
Do not promise that ambiguous text or an external command already in progress was
interrupted the instant a message arrived. Show received, queued, applied or
stopping/interrupted status as appropriate, including possible partial effects.

### Scheduling, context and result delivery

- A side question can interrupt the foreground explanation at a safe boundary.
  Model requests may need cancellation/restart with partial output retained; never
  run competing foreground context writers merely to answer sooner. If a tool
  cannot yield yet, show the question as received/waiting. Do not kill an unrelated
  command just to answer a question.
- A correction supersedes conflicting queued directives for that task. Tag pending
  model/tool work with the directive and binding revision so obsolete work cannot
  commit a new effect after the correction has been applied. Already-running
  non-atomic commands require stop/reconciliation; no rollback is implied.
- A stop moves through a visible stopping state until affected workers/descendants
  are reconciled. Offline workers leave an unresolved stop; do not show completed
  cancellation based only on losing the connection. Restart needs a fresh explicit
  resume/start instruction and current grants.
- Context handoffs carry the request, task/attempt, current rules, binding and a
  defined history watermark. Child agents receive only authorized relevant context;
  launching a child is not permission to copy every other conversation into it.
- Child outputs are correlated to their task/attempt/call and reconciled once.
  Late output after stop may be retained as an attributed outcome or partial result;
  it cannot revive the task, change its target or silently overwrite a newer result.
- Deliver one compact activity line/result summary per task update as appropriate.
  Thinking/scripts/tool details stay collapsed by default. Questions, decisions
  and error summaries remain visible; selecting a task opens its own details.
- pots dispatch keeps its backend actor/grant identity. User takeover suspends
  conflicting pots dispatch for the affected task, including queued instructions;
  unrelated responsibilities continue. Resuming coordination is explicit.

On reconnect, replay accepted input and outcomes by stable identity and order,
not by sending the same user request as a new message. A lost acknowledgement
requires outcome reconciliation. Concurrent control changes use revisions and
return the authoritative result; timestamps alone do not decide authority.

### Acceptance cases to implement later

1. While task A edits files, the user asks about an error. The answer is associated
   with A; its progress remains visible and no duplicate task/session is created.
2. While A runs, the user starts independent task B. Both remain separately
   identifiable; B runs only if permitted, otherwise its waiting reason is shown.
3. A correction arrives during a model stream or tool call. Obsolete queued effects
   are rejected after application; partial completed effects are reported, not hidden.
4. Stop A while B runs. A's descendants are reconciled; B continues unless it has
   an explicit dependency. pots and late child results cannot restart A.
5. Two devices submit a message/control at once, or resend after a lost response.
   There is one accepted command outcome and one foreground owner; both converge.
6. A child responds after ownership changes. Its output stays attributed, cannot
   become the user's new instruction, and cannot append a competing answer stream.
7. A reply to an expired approval cannot authorize an unrelated or changed action.

## 3. Resolve overlapping folder permissions explicitly

### Resource and grant identity

A mount is a presentation/binding of a resource; a grant is a scoped permission
with an issuer and provenance. Keep separate identities for Node, resolved folder,
mount alias, project membership, explicit conversation grant and binding revision.
Two aliases for the same folder do not create independent lock identities.
All directly mounted filesystem resources of an attempt must resolve on its Node;
remote copying/access remains a separate design, not an alias trick.

A project-derived grant ends with that membership. A deliberately created
conversation-specific grant is independent and appears separately in the UI.
Default broad host readability is not an independent user grant that can silently
keep a removed project path readable. Hard deployment restrictions remain in force.

### Two distinct user operations

| Operation                                   | Grant/policy change                                                                          | Required preview and outcome                                                                                                                |
| ------------------------------------------- | -------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| Leave project / remove its mounted resource | Remove the applicable project-derived grants and active configuration                        | List independently authorized overlapping paths and their remaining read/write access; stop fresh access where no independent grant remains |
| Block this conversation from a folder       | Add a read/write prohibition for that resource subtree to the conversation's execution scope | List affected mounts/tasks and running workers; overlapping parent/child grants cannot bypass it                                            |

A resource block applies to this conversation's affected tasks, attempts and
scoped descendants, including dispatched work elsewhere that carries that scope.
It is not a global block on every unrelated conversation using the same folder.
Project-wide settings changes separately preview all affected member conversations
and reconcile them per host. Do not let delegation shed the blocking scope.

Leaving retains conversation history under decision A and does not delete files.
If an independent grant remains, display the exception before confirmation and
in the resulting effective-access summary. Never report “no access to /repo” if
/repo/docs is still independently granted. Offer the separate block operation
when the user's intent is to remove all access to that subtree.

### Effective-access rules

Evaluate the requested operation against the resolved target and current scope:

1. Apply deployment restrictions and existing protected-state boundaries.
2. A current explicit conversation/resource prohibition takes precedence over
   overlapping grants for that scope. Old approvals and permissive confirmation
   presets do not override it.
3. Among remaining explicit grants, require one covering that operation and target.
   A read-only grant grants reads; it is not itself a deny of writes authorized by
   a separate visible read/write grant. Display effective access and its sources,
   rather than labelling such a folder only “read-only”.
4. On removing a project grant, exclude the revoked resource subtree from ambient
   host reads, reopening only operations covered by independently retained grants.
   Without such a grant it becomes inaccessible, even under a parent mount or the
   current broad-read sandbox baseline. This is a required new enforcement rule.
5. Then apply the operation approval policy, task/binding revision and readiness
   checks described in section 1. A resource grant alone does not authorize every
   effect or remove a writer conflict.

Examples for one conversation on Node N:

| Existing access                                               | User action                            | Effective result after confirmed enforcement                                                |
| ------------------------------------------------------------- | -------------------------------------- | ------------------------------------------------------------------------------------------- |
| Project `/repo` read/write only                               | Leave project                          | No new access to `/repo`; retained dialogue is unchanged                                    |
| Project `/repo` read/write + explicit `/repo/docs` read-only  | Leave project                          | `/repo/docs` read-only remains, disclosed; other `/repo` paths are unavailable              |
| Project `/repo` read/write + explicit `/repo/docs` read/write | Leave project                          | `/repo/docs` read/write remains, disclosed; no claim that all project data is inaccessible  |
| Project `/repo` read/write + explicit parent `/` read grant   | Leave project                          | Remaining independently granted reads are disclosed; project-derived writes end             |
| Any of those overlapping grants                               | Block `/repo` for this conversation    | No reads/writes under `/repo`, including `/repo/docs`, through those grants                 |
| Explicit `/repo` read/write                                   | Add a read-only alias for `/repo/docs` | Effective writes remain via the parent; show this instead of promising a read-only boundary |
| Explicit `/repo` read/write                                   | Block `/repo/docs`                     | `/repo/docs` denied; other authorized `/repo` paths remain available                        |
| A blocked path + stale approval or child dispatch             | Retry old operation                    | Denied; no new authority or implicit removal of the block                                   |

Removing a block is an explicit user access change against the current revision,
with a preview of grants that would become effective again. A new mount does not
silently remove a block. A changed path/Node or unclear resource identity requires
revalidation; do not treat a display alias as proof that a prohibition no longer
applies. The main folder/access scope is explicitly selected and shown; newly
added additional folders default to read-only unless writes are explicitly granted.
Preserve existing grants on migration and display effective access where another
grant already permits writes; a read-only new alias does not revoke that grant.

### Enforcement and transition requirements

Implementation note: Node schema 2012 now supplies the
[durable admission fence and tracked supervisor drain](unified-conversations.md#u4-implementation-checkpoint-node-transition-admission-fence-2026-10-28).
It blocks new admitted work without releasing the old binding after timeout or
restart. Its receipts explicitly report that OS revocation and target installation
are unconfirmed. The enforcement/alias/descriptor requirements below remain open;
no public transition or complete revocation proof is supplied by this checkpoint.
Node schema 2013 extends this with a [durable sandbox launch journal](unified-conversations.md#u4-implementation-checkpoint-durable-sandbox-launch-journal-2026-10-28)
and bounded saved-identity reconciliation. Missing historical/capture evidence
remains unresolved across restart. Node schema 2014 adds a [guarded native Linux
start](unified-conversations.md#u4-implementation-checkpoint-guarded-native-linux-launch-2026-10-28):
new Agent execution waits for durable identity and a one-time release. Unknown
wrapper exit, prior untracked launches, non-runner effects and target installation
remain open; process counts do not grant access.
[Terminal effect-boundary checks](unified-conversations.md#u4-implementation-checkpoint-fenced-terminal-input-2026-10-28)
now retain the original controller/connection/binding through queued and partial PTY
writes, rejecting after takeover or an accepted fence. This does not recall bytes
already delivered or prove termination of terminal descendants.
The [terminal-supervision checkpoint](unified-conversations.md#u4-implementation-checkpoint-durable-terminal-supervision-2026-10-28)
retains launch/outcome evidence after panel close, cancellation and restart. Unknown
shell observations block disposal/deletion and appear in drain receipts; a saved
direct-shell exit still does not establish detached-descendant containment or full
revocation. Closing hides UI immediately but retains live quota until settlement.

Node schema 2015 adds [approved host-command supervision](unified-conversations.md#u4-implementation-checkpoint-supervised-host-commands-2026-10-28):
spawn authority is rechecked at the effect boundary, Stop/drain joins the
independent observer, and interruption/storage failure preserves unresolved
journal evidence. Settled direct-child/pipes do not establish detached-descendant
termination; historical host execution is not inventoried.
Node schema 2016 adds [durable host write-resource retention](unified-conversations.md#u4-implementation-checkpoint-host-write-resource-retention-2026-10-28).
Agent cleanup cannot clear those frozen claims. Peer writes, host admissions and
removal preflight consult pending observations; missing prior ranges block rather
than infer an empty scope. This is cooperative coordination, not complete host
containment or authority revocation.

- Resolve and validate path components, containment and aliases at the trusted
  boundary. String-prefix checks or one-time symlink canonicalization are not
  sufficient. Define behavior for root renames, symlink replacement, bind mounts,
  hard-link aliases and path creation/removal races before claiming coverage.
- Enforce the result for file tools, PTC, shells, terminals, background descendants
  and host-mediated file preview/download. Current policy helpers are not proof
  that the intended precedence is already enforced on Linux and macOS.
- Reuse the durable preview → accepted → revoking → preparing → ready flow.
  Stop/retire old workers that retain forbidden access; recheck queued calls,
  approvals and delegated grants. Offline or unsupported hosts remain blocked or
  pending. No “removed” success while old authority is still live.
- If an unrestricted execution path, unsupported alias arrangement or shared-host
  configuration cannot enforce the block, report incompatibility and do not start
  affected work through that path. Do not silently fall back to unenforced access.
- Previous copies, already-read bytes and retained dialogue are governed by decision
  A; this is not retroactive erasure. Deliberately reading/copying new data to evade
  a removal is prohibited. Physical enforcement and alias limitations need explicit
  platform proof, not a promise of revoking all historical copies.

### Acceptance cases to implement later

Run every access-table case through direct file tools, shells and relevant child
processes; a cooperative tool-only test is insufficient. Also cover:

- Leaving with/without a separate grant, explicit block, explicit unblock and a
  permission preview that stays consistent with actual access on Web and App.
- Duplicate aliases, symlinks/renames and supported alternate filesystem paths;
  unsupported arrangements must fail visibly instead of claiming enforcement.
- An open descriptor or background child during revocation; stale approval and
  model result; repeated command; concurrent device changes; host restart/offline.
- A project-wide change affecting multiple conversations, with unrelated explicit
  grants disclosed and failures per host visible; no premature global completion.
- Preserved history/files/checkpoints, and no fresh note/rule retrieval through
  departed project authority. Independent file grants do not preserve project
  membership, active rule injection or board authority.

## 4. Switch Nodes without implicit migration

### Scope and preserved identities

Switching changes a conversation's execution binding. Keep the conversation,
canonical tasks, message authorship and result provenance; create a new execution
attempt for resumed work on the target. An old attempt, command, approval, terminal
or browser handle never becomes a target-Node object just because the UI changed.
Direct mounts of one attempt must resolve on its selected Node. Repository names,
remote URLs or matching paths are not evidence of equivalent files or authority.

Record the transition ID, expected source binding revision, source/target Nodes,
resolved target resources and grants, affected attempts/descendants, context
checkpoint identity, interrupted outcomes and host acknowledgements. This extends
the main plan's durable transition; it does not create a competing state machine.

| Material                                            | Behavior on a Node switch                                                                                                                   |
| --------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| Saved dialogue and task records                     | Remain attributed and accessible under their existing authority; transfer the authorized context representation through a trusted host path |
| Active rules and capabilities                       | Resolve for the new binding; retain old rules only as historical material                                                                   |
| Files, uncommitted changes and build outputs        | Stay at their source; no copy, reset, stash, checkout or overwrite as a switch side effect                                                  |
| Shells, background commands and development servers | Reconcile affected workers on the old host; their processes and ports are not migrated                                                      |
| Browser state, cookies and external credentials     | Stay under their existing ownership; no profile/credential transfer or newly granted account access                                         |
| Approvals, file references and checkpoints          | Keep original targets/provenance; revalidate future operations instead of rewriting their target IDs                                        |
| Project resources on another Node                   | Show unresolved bindings; require authorized target resources or an explicit membership/mount change                                        |

Preserving context requires an available, authorized and consistent context record.
Specify how the current Node-backed history is exported/journaled outside a retired
worker before cutover; do not copy its whole private state directory. If required
history is unavailable, keep the transition blocked rather than starting an empty
replacement conversation or treating a stale cache as the complete history.

### User and host flow

1. **Preview.** Select the target Node and its main folder/mounts. Check capability,
   authorization and enforcement support without running user commands. Show
   affected tasks, stopped resources, source-only files and unavailable target
   dependencies. A path with the same spelling is still a different resource.
2. **Confirm current intent.** Submit the transition against its preview revision.
   Canceling before acceptance changes nothing. If the binding, grants or affected
   work changed materially, refresh the preview rather than switching unseen work.
3. **Fence and reconcile.** Persist intent, reject new effects under the old binding,
   and stop/quiesce affected workers and descendants through the established
   revocation protocol. Capture partial outcomes and the context handoff checkpoint.
   Unrelated conversations or independent execution scopes are not stopped.
4. **Prepare the target.** Only after source revocation is acknowledged, install the
   new sandbox/binding and verify the target resources. Explicit Create folder uses
   its own authorized, idempotent allocation; merely previewing a target does not
   create a directory. Missing mounts remain unresolved rather than guessed.
5. **Publish readiness.** Commit the new binding only with target acknowledgement;
   publish one result to Web/App. Deliver the trusted environment-change notice and
   interrupted outcomes to the foreground coordinator before further effects.
6. **Continue deliberately.** Preserve the objective and explain where work now
   runs. The agent may plan next steps under current grants, but cannot replay an
   old command against a new folder. A task explicitly stopped by the user still
   needs explicit resume; a switch alone is not that instruction. A queued task
   whose target was the old binding waits for target reconciliation, not silent
   reassignment. An answered approval for the old target does not authorize it.

While applying, clients can show authorized saved history and retain drafts, but
must not advertise the new environment as usable or send new effects to the old
one. Navigating away or closing Web does not cancel the durable transition.

### Exceptions and recovery

| Condition                                                            | Required behavior                                                                                                          |
| -------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| Source Node offline or stop outcome unknown                          | Fence Gateway dispatch; show pending source acknowledgement; do not claim stopped workers or start a duplicate replacement |
| Target offline, full disk, missing dependency or unsupported sandbox | Keep execution blocked with a retry/change-target action; do not restore revoked source access automatically               |
| Failure after source stop but before target ready                    | Resume the same transition from recorded acknowledgements; retain files/context and partial results                        |
| User changes their mind after acceptance                             | Treat it as an explicit new revision/recovery choice; never “undo” completed effects or replay old commands as rollback    |
| Two devices select different targets                                 | Serialize by current transition/binding revision; return the accepted transition or a conflict, not two active bindings    |
| Gateway/Node restart or late old model reply                         | Reconcile durable generations before work; obsolete model/tool/approval results cannot acquire target authority            |
| A command may already have published/sent something                  | Report the known/unknown external outcome; a new Node is not permission to resend                                          |
| A prepared folder contains later user edits                          | Preserve it and identify its location; no automatic recursive cleanup of an interrupted target                             |

A separate future copy/synchronization operation must identify sources, destination,
permissions and conflicts, revalidate changed inputs, and avoid overwriting existing
or later user files. It is outside the switch transaction. Do not infer authority
to copy a removed resource, browser profile, credential or private session store.
Checkpoint recovery remains its existing isolated workspace and blank recovery
conversation; switching Node neither migrates its isolation ticket nor converts
it into an ordinary unrestricted workspace.

### Acceptance cases to implement later

- **N4-1:** Switch idle A → B with the same path spelling but different file contents.
  Dialogue survives; the UI names B; no source file, cookie or process is copied.
- **N4-2:** Switch during a write with background descendants. New effects are fenced,
  source authority is retired, partial changes remain, and the replacement gets the
  environment notice before acting. Other conversations continue.
- **N4-3:** A is offline or context handoff is unavailable. Both clients show the
  unresolved step; B cannot run a duplicate attempt using incomplete history.
- **N4-4:** B preparation fails after A stops. Retry/restart uses the same transition,
  preserves user edits, and never silently reactivates A or repeats an external send.
- **N4-5:** Web and App choose targets concurrently and lose responses. They converge
  on one transition; stale approvals, child results and queued commands stay fenced.
- **N4-6:** A project mount exists only on A or a target recovery root needs its own
  ticket. Missing authority/isolation blocks preparation; no substitute mount is made.
- **N4-7:** Changing Nodes after explicit Stop does not resume the stopped task;
  merely closing Web does not interrupt a valid transition or erase the App draft.

## 5. Archive, leave and delete with explicit ownership

### Action and ownership matrix

Lifecycle changes distinguish organization, authority and content destruction.
Deletion requires the applicable management/session capability; merging navigation
does not enable deletion on every former Work session. Project deletion keeps the
existing meaning of deleting its member conversations, with an explicit preview.
Keeping a conversation requires a separate completed move/leave operation before
confirming deletion, not an implicit move during destructive cleanup.

| Action                       | Conversations and execution                                                                   | Data and future work                                                                                                       |
| ---------------------------- | --------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| Archive conversation/project | Change organization; no implicit stop or membership change                                    | Existing tasks/schedules continue within grants; show active/needs-you indicators outside the archived list                |
| Unarchive                    | Return the same IDs to normal navigation                                                      | No replay, automatic restart or re-creation of deleted records                                                             |
| Leave/move project           | Preserve dialogue; execute item 3's grant transition                                          | Keep original files/history; remove project membership/rules/board access; disclose independent file grants                |
| Delete conversation          | Fence new work; stop and reconcile work whose execution scope belongs to it                   | Remove owned content under existing deletion rules; preserve user-owned folders and independently owned records            |
| Delete project               | Fence project membership/dispatch and affected member conversations; reconcile affected hosts | Delete the confirmed membership set and project-owned state; preserve external resources and specifically retained records |

“Owned” requires recorded provenance, not a matching path, filename, repository
key, author label or membership at the time cleanup happens. A shared filesystem
folder is not project-owned data merely because it was mounted. A shared task
reference does not make the same task owned by two conversations.

| Record/resource                                                                      | Cleanup boundary                                                                                                                                                                                                                                                                                |
| ------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Mounted user folders, repositories, commits and explicit server-created work folders | Preserve; deleting their link/conversation never authorizes deleting the actual folder                                                                                                                                                                                                          |
| Disposable per-session scratch                                                       | Remove only when positively identified as session-owned, no surviving references/writers, and included in the deletion scope; preserve ambiguous or adopted content                                                                                                                             |
| Conversation messages, private transcripts and session OM                            | Use existing owned-session deletion and source-access fences; prevent late results or memory workers from recreating them                                                                                                                                                                       |
| Uploaded originals and derived previews                                              | Delete the owned associations and derivations covered by the preview; collect backing bytes only when no surviving authorized owner/reference requires them                                                                                                                                     |
| Project rules/configuration/board                                                    | Remove project-owned state; project deletion is not deletion of the files mounted from outside it                                                                                                                                                                                               |
| Project notes and global memory                                                      | Apply recorded origin/version rules below; do not silently erase another author's surviving contribution                                                                                                                                                                                        |
| Schedules/calendar                                                                   | Delete project-owned schedules and history as today; external schedules survive. A surviving schedule whose execution authority/target was removed is blocked and shown for repair, never silently retargeted. Independent calendar events are not deleted solely because a chat discussed them |
| Delegations/child work                                                               | Fence and reconcile affected source-scoped execution; retain independently owned destination sessions/files/commits and user-taken-over work. Their independent authority must be current, not fabricated from the deleted source                                                               |
| Checkpoint evidence/recovery                                                         | Preserve referenced evidence and opened recovery workspaces, including later user changes; remove only unreferenced objects under the existing GC contract                                                                                                                                      |
| Other conversations, independent exports/logs, backups and provider copies           | Outside automatic deletion scope; disclose known retained references without promising universal erasure                                                                                                                                                                                        |

### Preserve existing memory deletion semantics

The current [chat/project deletion guide](../docs/guides/chat-projects.md#deleting-a-chat)
and [assistant memory contract](../docs/architecture/assistant-memory.md) are the
compatibility baseline. These two operations intentionally differ:

- **Single conversation:** delete USER/MEMORY entries originally created there,
  their logged versions and its proposals. Entries created elsewhere remain even
  if this conversation read or edited them. Preserve origin records needed for a
  later project-wide deletion; do not reinterpret an edit as new ownership.
- **Project:** classify entries by version origins. All versions from the project
  means forget; a suffix of project-authored versions rolls back to the last
  outside version; mixed histories require the existing Forget/Keep/Edit choice
  at a current revision. Include sources from already-deleted member conversations
  where that provenance was recorded. Do not treat blanket Keep or Forget as the
  default for every mixed entry.

For the new cross-project move feature, record the project-membership generation
at each memory version/proposal/source write, alongside stable conversation and
original-entry provenance. Moving conversation C from A to B does not reassign
C's old A-origin versions to B or make its later B-origin versions part of A.
Project deletion selects current member conversations for conversation destruction,
but classifies memory by immutable write-time provenance, including moved or
previously deleted sources. A's deletion cannot delete C merely because C once
belonged to A. Single-conversation deletion still uses its original-entry rule.

Run the project-level global-memory plan once. Internal cleanup of its member
conversations must not invoke the standalone conversation-memory purge afterward:
that would undo the user's mixed-history Keep/Edit choices. Use a recorded cleanup
scope/receipt so retry or restart cannot change the selected deletion semantics.
Legacy records without sufficient membership history require an explicit migration
classification/review; never infer historical ownership from today's membership.
New writes during a membership transition must bind to a committed generation or
wait; a model-supplied project label is not provenance.

Project deletion tombstones remain project-scoped; global Forget retains its own
semantics. New project notes must record sources/version origins so known derived
content cannot evade deletion by being relabelled as a board post. Apply the same
explicit conflict/review discipline to mixed contributions; full note storage and
retention settings still need implementation specification. Previously copied prose,
paraphrases and frozen snapshots elsewhere are not claimed universally traceable
or erased. Legacy uploads without ownership must not be assigned a guessed owner
just to delete them.

### Preview, execution and completion flow

1. **Prepare a current preview.** Inventory the project/conversation revision,
   member IDs, executing scopes/hosts, schedules, decisions, owned data, memory
   actions and retained references. Show what stops, what is deleted and what
   remains, including user folders and adopted recovery workspaces.
2. **Confirm exact scope.** Bind the user command to that preview and explicit
   mixed-memory decisions. A changed membership, target or reviewed memory entry
   invalidates the affected preview; reload before broadening destructive work.
   Cancel before acceptance performs no mutation.
3. **Record deletion intent and fence.** Durably mark the operation, prevent new
   membership/dispatch/writes from deleted scopes, invalidate pending decisions
   that could restart them, and exclude deleting sources from fresh retrieval.
   Atomically associate the command with its deletion operation to deduplicate it.
4. **Stop and reconcile.** Reconcile scoped workers, terminals, browser sessions,
   background children and memory writers on affected hosts. Account for effects
   already delivered elsewhere. Independently authorized destination work stays
   identified; do not cancel every external task just because it has a source link.
5. **Clean with provenance.** Use the confirmed owners and current deletion/forget
   rules, expected revisions and surviving references. Record per-host steps and
   conflicts; do not use a broad recursive delete on mounted or recovery roots.
6. **Publish completion.** Only report complete after required host/data steps are
   acknowledged. Publish content-free deletion identities and reconciliation events
   so clients, restored old state and late results cannot resurrect the entity.
   Minimize remaining operational metadata; new cleanup receipts/error reports
   must not copy deleted text into an audit archive. Reconcile known managed
   suggestion/notification previews covered by deletion; independent pre-existing
   logs/backups remain disclosed exclusions, not a claim of universal erasure.

During partial deletion, show “deleting / needs attention” and the outstanding step.
A retry resumes the same operation and rechecks unresolved conflicts; it does not
repeat already completed actions or require pretending the entity is intact. A
cancel/back navigation after destructive steps cannot restore removed content or
authority. Recovery from an independent backup is a separate explicit operation,
not a retry of a canceled UI dialog.

### Exceptions and recovery

- **Offline host:** keep the required acknowledgement pending; fence new Gateway
  work and reconcile before that host can resume old authority. Do not claim
  deletion of offline files or immediate retraction from an offline client.
- **Concurrent note edit or new member:** reject a stale destructive scope; when
  deletion already started, preserve the completed steps and show a fresh decision
  for unresolved conflicts. Do not replace the user's reviewed text silently.
- **Shared/uncertain ownership:** preserve the ambiguous data and report it. A
  matching hash, old path or shared repository key alone is insufficient to erase it.
- **Late result or schedule firing:** the deleted generation cannot recreate a
  conversation, task, attachment, note or pending approval. A retained independent
  schedule must recheck its target and grants before a future run.
- **Recovery dependencies:** keep opened workspaces and evidence required by
  surviving recovery jobs. If deletion and existing pin/reference obligations
  conflict, surface the retained dependency; do not free evidence still in use.
- **Remote side effects already completed:** report that deletion cannot unsend,
  unpublish or undo them. Any compensating action requires its own authorized scope.

### Acceptance cases to implement later

- **L5-1:** Archive while work and a schedule run; work remains reachable and
  authorized, and unarchive keeps IDs without restarting or duplicating anything.
- **L5-2:** Delete a conversation during tool/memory/background activity; all affected
  writers are reconciled and no late result resurrects it. Mounted user files stay.
- **L5-3:** Exercise single-conversation versus project memory cleanup with original,
  edited, suffix and mixed histories, a stale review revision and an earlier-deleted
  source. Also move a conversation A → B: A-origin and B-origin versions keep
  their write-time scope, and deleting A does not delete the moved conversation.
  Project cleanup/restart must not run a second standalone memory purge that undoes
  a reviewed Keep/Edit decision. Missing legacy scope requires review, not a guess.
- **L5-4:** Delete a project with member conversations, an external schedule and an
  independent delegated session. Preview and results distinguish owned deletion,
  blocked dependent targets and retained external records; no automatic retargeting.
- **L5-5:** Crash/reconnect during each destructive step. Resume one durable operation;
  both clients show pending until required cleanup completes; stale approvals fail.
- **L5-6:** Delete a source conversation after checkpoint adoption and later user
  edits. Its recovery workspace/evidence survive and continuation cannot resurrect
  the deleted conversation or replay source memory.
- **L5-7:** Shared bytes, legacy unowned uploads and an ambiguously owned/adopted
  managed folder with later edits are preserved when ownership/reference checks
  do not justify cleanup.
- **L5-8:** An offline App receives deletion after reconnect. Local history/search/
  notifications reconcile without reuploading the deleted record; independent
  exports/backups are not falsely claimed erased.

## 6. Separate saved content from live file references

Implementation checkpoint: [saved attachment origins](conversation-binding-migration.md#saved-attachment-origins-checkpoint-2026-10-28)
now preserves new upload identity/scope and legacy restrictions, provides direct
authenticated metadata and validates saved bytes before Agent consumption (Node
schema 2011). This covers saved uploads only; live-file/cache/grant provenance,
client presentation and the full open/download flow below remain target behavior.

### Content identity and lifetime

A message may contain saved text, an attachment or a reference to mutable content.
Persist which kind it is, its owner/account, source conversation/project, Node and
resource identity where relevant, origin, content/version identity, required grants
and lifecycle state. A filename, identical bytes or URL is not an ownership grant.
Version metadata lets the UI distinguish a saved result from the current file;
it does not force every live preview into a permanent snapshot.

| Content kind                                       | What a user can expect                                                                    | Access/lifetime boundary                                                                                                   |
| -------------------------------------------------- | ----------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| Saved message text, tool excerpt or captured image | Historical content remains as saved under decision A; it may differ from the current file | Governed by conversation access and explicit deletion; do not refresh it invisibly                                         |
| Independently owned saved attachment               | The saved bytes remain under that attachment's existing ownership                         | Require current attachment authority; a conversation move is not an ownership transfer                                     |
| Live project/workspace file reference              | Fetch the referenced resource's current allowed content, with source/version shown        | Revalidate resource grants, Node and identity on open/refresh/download; leaving may make it unavailable                    |
| Cached preview/thumbnail/range                     | A partial, possibly stale representation of its identified source                         | Keep cache provenance and account separation; never promote it into an independent durable attachment to bypass revocation |
| Recovery artifact/checkpoint object                | A result tied to a recovery job and its independent authority                             | Preserve recovery provenance and reference retention; the source file's path is not a substitute authority                 |
| Independent user export                            | A copy the user intentionally saved outside managed content                               | Disclose that later server revocation/deletion cannot recall such a copy                                                   |

Migration must retain existing upload workspace restrictions, including documented
legacy ownership exceptions. Calling every old project upload “conversation-owned”
would widen access. A previously saved dialogue can remain visible after moving
while its workspace-bound attachment requires separate access. Display that state
rather than silently reassigning the upload or pretending the bytes are missing.

### Open, preview and download flow

1. **Resolve the reference.** Load its typed identity and recorded provenance from
   the authenticated backend. Do not resolve old relative paths against a newly
   selected cwd or use a matching filename on a different Node.
2. **Determine the operation.** Opening saved content checks its owning record;
   live access checks current resource grants and binding/revocation state. Apply
   item 3's retained-independent-grant rules and explicit folder blocks.
3. **Fetch through the appropriate authority.** Web and App use the same backend
   authorization rules; no desktop browser is a relay. An internal URL or stored
   locator is not authority. Any download token must be scoped to its object,
   account and operation and support the required revocation boundary; a permanent
   transferable raw-Node URL cannot satisfy this contract.
4. **Display a clear result.** Show source and saved/current status. Distinguish
   inaccessible, unavailable Node, removed/missing file, stale reference and
   interrupted transfer. Retain the surrounding message; do not repeatedly retry
   an authority denial or substitute another file.
5. **Cache with provenance.** Partition by account/owner and source/version; store
   only authorized content and retain its ownership classification. Range requests,
   resume, thumbnail generation and renderer-initiated resource fetches perform the
   corresponding checks too. A cached success is not proof of today's access.
6. **Reconcile changes.** On revocation, account change or deletion, invalidate
   affected live-fetch capabilities and stale UI actions. Stop affected ongoing
   transfers at the enforceable host boundary; bytes already delivered or buffered
   cannot be recalled. Record the boundary instead of claiming instant erasure.

An explicit authorized save/copy may create a separately owned attachment, with
source provenance and destination rights checked at that moment. Leaving, deleting
or being denied cannot trigger an automatic copy to preserve otherwise-lost access.
A content hash may deduplicate storage, but must never merge ownership or expose
another owner's bytes or object metadata.

### Offline, departure and deletion behavior

- **Offline reading:** show authorized previously stored dialogue and available
  cached representations as stale/offline; do not claim the live file is unchanged.
  Missing bytes stay unavailable. Queueing a refresh does not preserve an old grant;
  reconnect requires new authority checks before requesting bytes.
- **Project departure:** retained history is not erased. Previously saved text and
  visible cached snapshots may remain identified as historical material. The live
  source cannot fetch further bytes unless an independent current grant remains.
  Legacy project-bound uploads do not acquire cross-project access by moving the
  containing conversation. A separate explicit resource block overrides grants.
- **Account switch/revocation:** an account's cached records are unavailable in
  another account. Once revocation is known, stop credential retries and reconcile
  local access. An offline device cannot be promised instantaneous remote cache
  removal; specify this limit rather than assuming it acknowledged an event.
- **Deletion:** remove the known managed cache/search/preview/notification copies
  covered by the deletion as clients receive it. Content-free deletion revisions
  outrank older snapshots; an offline cached record never becomes a new upload that
  resurrects it. Independently owned copies and surviving recovery evidence follow
  item 5's preview, rather than indiscriminate hash-based erasure.
- **Partial or changed content:** retain transfer/version identity. A changed source
  invalidates a byte-range resume; never splice old and new versions into a file or
  show a partial fetch as a complete download. User-exported files are not overwritten
  by a background resume or changed source without an explicit destination choice.

The exact cache size, expiry values and token mechanism remain engineering/settings
work. They must meet the above ownership, reconciliation and revocation behavior;
this plan does not choose a new authentication topology or public port.

### Acceptance cases to implement later

- **C6-1:** A message contains saved text, an independent attachment and a live project
  file link. After departure, history remains; each object follows its own rights,
  and a denied live link keeps the message intact with a clear reason.
- **C6-2:** Repeat with an independent overlapping read grant, then an explicit folder
  block. Web/App return the same effective result; no alias or old URL bypasses it.
- **C6-3:** Move a conversation containing a legacy workspace-bound upload. It is not
  relabelled or exposed in the new workspace; preserved history and access-denied
  attachment state are distinguishable.
- **C6-4:** Switch Nodes with identical relative filenames. Old links still identify
  the original source; opening one never fetches the replacement Node's file.
- **C6-5:** Revoke access during a download/thumbnail fetch. New and resumed requests
  are denied and the active transfer reconciles; already delivered bytes are not
  falsely claimed recalled. Cached snapshots cannot fetch fresh content.
- **C6-6:** Open cached content offline, then delete it elsewhere and reconnect.
  Deletion revisions beat stale snapshots; no resurrection or unconditional replay.
  A new object/project with the same name has a distinct identity and cannot expose
  or inherit the deleted object's cached bytes or permissions.
- **C6-7:** Switch accounts with an identical object name/hash. Cache, search and
  previews cannot reveal the previous account's content or existence metadata.
- **C6-8:** Interrupt a download and change its source version. Resume refuses mixed
  bytes; the original user-exported file remains intact. App operation works with
  every desktop Web client closed.

## 7. Make pots a bounded coordinator with one task record

This contract has moved to the [pots folder](pots/README.md) so that pots can be
planned independently. The contract and case text are unchanged:

- Records, the observe/suggest/accept/dispatch/report flow, controls and quiet
  operation: [pots design — coordination contract](pots/design.md#coordination-contract).
- Acceptance cases P7-1 to P7-9, now with their current local evidence:
  [pots acceptance](pots/acceptance.md).
- Delivered checkpoints and remaining work: [pots](pots/README.md).

## Remaining specification work

The user-visible behavior above is adopted. Remaining engineering work includes
persistent schemas, API/error shapes, atomic ordering and crash recovery, trusted
intent/control boundaries, per-tool capability inventory, platform enforcement
proofs and old-mode migration fixtures. Mount/allocation policies are adopted.
Durable notes have no automatic age expiry; explicit removal and existing source/
project deletion still apply. Board-retention/editor presets and exact pots limits
and times need configuration within those policies.

All seven behavior contracts now include flows, failure handling and acceptance
cases. Further implementation specification must cover cross-host context custody,
per-host deletion receipts and mixed-memory conflicts, attachment/cache ownership
migration, pots event/budget deduplication, and compatibility with old clients.
Behavioral detail is not proof of working enforcement or completed migration.
No runtime tests or builds were run for this planning document.
