# Conversation binding migration (U2)

[Unified conversations](unified-conversations.md) · [Execution contracts](conversation-execution-contracts.md)

**Current scope (2026-11-07):** the formats and delivered/remaining split are in
[C0](unified-completion-contracts.md#c0-authority-current-snapshot-and-scope).
The schema 1021–1025/2010–2012 descriptions below are dated migration checkpoints,
not current format numbers or proof that T1–T5 are absent. New authority, immutable
effect generations and inherited risks require the [C2](unified-completion-contracts.md#c2-revocation-evidence-and-inherited-risk)
and [C9 compatibility](unified-completion-contracts.md#c9-synchronization-compatibility-and-rollback)
gates; no migration numbers are reserved here.

Status: U2 in progress locally, 2026-10-28. Schema 1021 delivered the durable
legacy adapter; schema 1022 adds explicit project membership, configured mode
and workspace-capability histories, and an owner-scoped environment read model.
Schema **1023** captures new global-memory version/proposal write-time origins.
Schema **1024** consumes them in project deletion and records cleanup completion.
Schema **1025** records immutable command admission environments and checks the
Web/Android caller's captured binding before accepting new ordinary commands.
Node schema **2010** now persists those command origins and rechecks Gateway
authority after local queue/startup waits. Node schema **2011** freezes new saved
upload origins and preserves their access scopes. Live-resource provenance, full
effect fences and supported environment transitions remain to implement. No mount, move, grant, process restart or U1 activation is enabled.

## Identity mapping and current migration

| Existing identity or state                          | Schema 1021 mapping                                                                        | Preservation rule                                                                            |
| --------------------------------------------------- | ------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------- |
| Public `sessions.id`                                | Same conversation ID                                                                       | Keep deep links, command/approval targets, schedules, pots and memory/checkpoint sources     |
| `sessions.workspace_id`                             | `membership.legacyWorkspaceId` plus `execution.workspaceId`                                | Explicit compatibility association; does not declare every directory workspace a project     |
| Chat project                                        | Existing workspace ID, classified by `project_links::is_project` using the current catalog | Preserve project files, rules and links; links are ordering/defaults, never folder grants    |
| Top-level `chats` / directory workspace             | Existing workspace association                                                             | No invented project or implicit membership in linked workspaces                              |
| Custom mode ID, including unavailable IDs           | Exact `execution.modeId`                                                                   | Preserve it; unavailable modes remain unavailable under existing checks                      |
| Node ID / private Node session                      | Same host and private mapping                                                              | Public binding contains the already-public Node ID, never private Node session/path or owner |
| First-send accepted session without Node allocation | Same binding at generation 1                                                               | The first private ID completes that allocation; it is not an environment switch              |
| Checkpoint continuation                             | Its existing new public ID and private recovery workspace                                  | Preserve ownership/isolation; retry returns that same binding                                |
| Runner epoch                                        | Existing epoch, separate from binding                                                      | Restarting a runner does not move the conversation                                           |
| Device control generation                           | Existing control lease, separate from membership/binding                                   | Takeover does not move the conversation or grant folder access                               |
| Memory/history/provenance                           | Unchanged stored data                                                                      | Do not infer historical membership from today's workspace; do not replay commands            |

`conversation_bindings` is seeded within the existing single migration transaction.
Its insert trigger covers every session creator, including first-send acceptance,
ordinary creation, schedules/delegations/pots and checkpoint continuation. Rollback
removes both rows; final session deletion cascades the identity-only binding.
An invalid historical workspace reference refuses migration atomically rather
than silently omitting that conversation from the public list.

Membership revision and execution generation start at **1** independently. A
legacy workspace reassignment advances both; replacing an established Node
mapping advances execution only. A mode-ID reassignment conservatively advances
both because the old catalog can classify project membership. A same-ID Node
announcement, display-name/repository refresh, rename, runner restart, device
lease change and first private mapping do not advance either. Values must remain
positive, exact JavaScript integers. These storage-adapter cases do **not** expose
a supported workspace-switch API.

The compatibility `binding.version: 1` is included in ordinary session responses,
lists and snapshots. Web retains it in its API model; native Android retains it
through Session parsing, timeline state, edits and serialization to Flutter.
Missing bindings remain compatible with old Gateways. An advertised unsupported
version or conflicting workspace reference is rejected, not treated as an old
server or used to choose a different execution destination.

## Explicit membership and configured policy (schema 1022)

`conversation_project_memberships` stores one canonical project association per
conversation, separately from `membership.legacyWorkspaceId`. Its own revision
starts at 1. The current validated mode's `projects` capability and existing
`project_links::is_project` identity rule classify legacy projects. Top-level
`chats` and directory workspaces do not become projects. No files are copied.

Resolution is `unresolved` before the first catalog adoption, `member` for a
confirmed project, `none` for a confirmed non-project, or `mode_unavailable` when
the mode cannot be resolved. A missing mode retains the last known project ID only
if the source workspace is unchanged. That retained reference grants nothing.
Initial migration/adoption does not pretend to have observed a past membership
transition. Later changes to the project ID or resolution advance the canonical
revision; moving between two non-project directories only changes the legacy
association and execution generation. These adapter cases remain internal, not a
new user-facing move API.

`mode_policy_versions` stores each full validated mode definition, including rules,
under an append-only revision. Removal appends a null definition rather than
rewriting history. Startup/reload installs the catalog, resolves memberships and
advances affected execution generations in one transaction; a failed write leaves
the prior in-memory catalog intact and publishes no replacement to Nodes. The
first adoption does not advance existing execution generations. Identical reloads
and restarts do not append versions. All definition changes, including labels,
conservatively advance the version; finer semantic classification is deferred.

`workspace_policy_versions` seeds each workspace's current capabilities (or its
existing default) at revision 1. Actual policy changes and reset-to-default append
snapshots and advance affected execution generations; no-op patches do neither.
The read/modify/write patch is now an IMMEDIATE transaction, so simultaneous patches
to different fields retain both edits. Snapshot failure/overflow rolls back the
policy change. Histories reject UPDATE and direct DELETE; workspace policy history
is removed with the workspace through its existing authorized deletion flow. Mode
history remains part of Gateway configuration state. No new memory data is stored.

`GET /api/sessions/{id}/environment` reads one consistent snapshot with:

- `version: 1`, the unchanged `sessionId` and compatibility `binding`;
- `project: {revision, workspaceId, resolution}`;
- `modePolicy: {revision, definition}` (null policy for an unknown mode, null
  definition for a recorded removal), and `workspacePolicy: {revision, capabilities}`;
- `enforcement: "not_tracked"` — never a claim that Node installed these policies.

The route is owner scoped, respects checkpoint privacy and deletion fences, and
returns `Cache-Control: no-store` even on authentication failure. Paired Android
can read it directly without browser consent, a live Node or a private Node session
mapping. Web and native API adapters validate the version, requested session,
project/binding scope, revisions and enforcement marker; errors/older-server 404s
are not turned into synthetic authority. Existing list/snapshot shapes are unchanged
from schema 1021. No new UI or Flutter bridge operation is claimed in this slice.

**Boundary:** configured policy versions still are not installed/acknowledged
sandbox versions. Project files and mutable external rules/mounts are not yet
snapshotted. Later checkpoints below add ordinary-command version preconditions and Node
rechecks. They are not installed-policy acknowledgements. U4 must provide real Node revocation and
acknowledgement before a project/environment transition can be exposed.

## Memory write-time source snapshots (schema 1023)

`memory_version_contexts` and `memory_proposal_contexts` are private, versioned
sidecars to the original memory log and proposal rows. Migration creates them empty:
no current workspace is used to backfill historical membership. New agent-authored
text/proposals capture the verified session, canonical membership resolution and
revision, execution generation/workspace/Node/mode, and configured policy revisions
inside the same transaction as the write. User/model-supplied source labels cannot
supply this snapshot. The existing `sources_json` and immutable creator attribution
keep their original meanings and wire formats.

USER approval copies the proposal's original snapshot; duplicate proposals retain
that same snapshot. Restore and project rollback copy the restored content version's
snapshot. They never recompute an origin from where its conversation lives today.
Legacy/missing snapshots remain explicitly unknown. Direct user edits have a user
origin rather than an invented project. A no-op note or restore creates no new
version or origin. Contentless Remove/Forget audit rows carry no source snapshot.

Sidecars reject UPDATE. Log/proposal deletion cascades their snapshots; project
history scrubbing and proposal redaction delete them in the same transaction.
Deleting an editing conversation preserves another creator's memory and the retained
version origins needed by project deletion. Global Forget and creator deletion
remove the relevant snapshots. Original entry ownership and mixed-history Keep/Edit/
Forget semantics are unchanged.

`memory.note` and `memory.proposeUser` compare the Gateway operation context's
binding to current state under the memory write transaction. A change while waiting
returns `stale_environment` without a memory/proposal row. This does **not** yet
fence a Node's old-generation request arriving after a change: the Node protocol
still needs expected binding generations at all effect boundaries. No switch API
is exposed by this change.

**Integrated locally (schema 1024):** project deletion selects by recorded origins,
not session sets. Unknown versions and proposals require explicit client-aware
review. Completion receipts commit with memory effects and the project fence;
retry, restart and overlapping standalone member deletion preserve the selected
semantics and later edits. Current member sessions alone are destroyed. Migration
never invents historical receipts; old partial deletions need review. Resource
provenance and actual mount revocation remain separate work.

## Mode-field inventory and preservation

Inventory source: `crates/pirc-protocol/src/mode.rs`. No field or safety validator
is removed in this slice.

| Fields                                             | Current consumers / target responsibility                                                                            |
| -------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| `id`, `label`, `description`, `ui`                 | Catalog, Gateway directory and Web/Android modes; identity/presentation, not authority                               |
| `workdir`                                          | Node chat/app/runner and checkpoints; retain workspace vs per-session working directory until a supported transition |
| `prompt`, `body`                                   | Agent config/prompt assembly; future attributed active rules, never reinterpret retained history as current policy   |
| `features_on`, `features_off`, `tools`             | Agent config/loop/features and tools; availability filters remain enforced, including PTC                            |
| `assistant`                                        | Gateway agent operations and Agent assistant feature; existing user/full scopes remain distinct                      |
| `delegate`, `delegate_target`                      | Gateway delegations/dispatch and Agent teams; no scope expansion or implicit target access                           |
| `schedule_scope`                                   | Gateway schedules; preserve own/any restriction and delegation requirement                                           |
| `project_instructions`, `project_files`            | Node chat/app/project-files and Gateway resource routes; preserve current project access                             |
| `project_config`, `repository`, `workspace_memory` | Node runner/side/workspace-memory/checkpoints and Agent config; preserve trust, repository and memory constraints    |
| `recap`                                            | Agent context construction; no new personal-history access                                                           |
| `delete_sessions`, `projects`                      | Gateway/Node deletion and project management; preserve mode restrictions and tombstones                              |

The full-assistant/workspace, delegate/delegate-target, repository/project-files,
workspace-memory/repository and schedule-any/delegation validations remain.

## Command admission checkpoint (2026-10-28)

Normal Web/Android command POSTs carry optional `expectedBinding` outside the
Node payload. It is the complete binding visible when the user initiated the
action, separate from runner epoch, device control and canonical project revision.
Web captures it before pending uploads and before model/thinking/prompt posts;
Flutter copies it before the sequence, and Android validates it before its native
command queue. Neither delivery path fetches a newer environment to authorize an
old action. Existing paired-device Gateway authentication remains sufficient.

Gateway checks ownership, availability, control and the captured binding while
reserving the command. Its immutable `command_environments` row commits with the
receipt. A stale binding returns `409 stale_environment` without a command row;
old clients without a binding may initiate work only while both legacy membership
revision and execution generation are 1. After changes they receive
`409 environment_required`. Both clients explain rejection in English/Traditional
Chinese and retain unsent input. Refresh and a new user action are required.

Duplicates return the old receipt, including uncertain results, without dispatch.
Reusing an ID/payload with another recorded environment is a conflict. Old command
rows retain unknown provenance; migration does not infer their prior environment.
Stop deliberately does not require an up-to-date visible binding, still requires
current control/ownership, and uses the current routing captured by Gateway.
Stop duplicates remain read-only. A deleting conversation cannot admit new commands.

**Original checkpoint boundary (extended by the Node checkpoint below):** this
is a Gateway admission precondition. Node payloads, protocol 15,
runner queues, approvals, background tasks, tools, already-open descriptors and
sandbox effects do not yet carry/enforce the binding generation. In particular,
this does not fence a policy change after admission but before Node execution.
`enforcement: not_tracked` stays accurate. No move/switch/mount API or U1 activation
is enabled. U4 must install/revoke authority and obtain Node acknowledgement before
exposing environment switches; this admission check alone is not that guarantee.

Validation: 382 Gateway unit tests; nine process cases covering the real Web/device
admission route, memory/project cleanup, checkpoints, legacy first-send contract,
Node link and session lifecycle; strict Gateway/conformance Clippy. Web has 64
focused cases plus Svelte checks; Android Gradle compiles the actual native bridge
and passes 25 focused JVM cases; Flutter has six focused controller/localization
cases plus changed-file analysis. Android environment API tests now use the
existing MockWebServer dependency instead of JDK-only HttpServer, so they compile
under Android Gradle as well as standalone JVM checks. OS/device/Keystore and live
MethodChannel acceptance, full workspace tests and local Nix are not claimed.

## Node command authority checkpoint (2026-10-28)

Gateway schema stays **1025**; Node advances to **2010**. For a new versioned
ordinary command, Gateway probes the exact Node connection using a read-only
capability request, then rechecks ownership/control/binding before dispatch.
Unsupported or replaced Nodes are rejected without sending the command. The
forwarded `commandEnvironment` is Gateway's captured binding, not a client-selected
Node destination. Reconnect does not transfer the probe to another connection.

Node records that origin atomically with its command receipt. Historical commands
stay unattributed; duplicate requests never backfill or replace their original
binding. Origins cannot be updated and are deleted with their command. Migration
and restart preserve this rule; metadata failure rolls back the new reservation.

After waiting for the local command gate and again after runner startup, Node asks
Gateway's authenticated `command.authority` operation to validate the recorded
command, session ownership/availability, environment and current device control.
Gateway accepts only pending `dispatched`/`outcome_unknown` receipts with matching
origins; this read-only check never redispatches them. Node also rechecks its own
lease after that reply, so a concurrent local takeover cannot use an older answer.
Branch changes recheck after idle/shutdown waits before mutating the session file.
An unknown/unavailable/malformed authority response rejects dispatch. A stale
binding has its specific rejection; Web/Flutter explain upgrade/unavailable cases
in English and Traditional Chinese, retain input, and do not auto-retry.

**Compatibility and limits:** Stop bypasses the probe and origin checks while
retaining existing ownership/control checks. Old clients at an unchanged generation
still use the legacy path; first-send/internal schedule/pots paths without this
sidecar retain their own existing admission rules. No policy is inferred for them.
New version-aware clients require a Node supporting this capability; upgrade Node
before using the matching clients. A Gateway transport timeout still leaves an
unknown receipt to query, never permission to replay the action.

These are point-in-time checks, not a lease spanning the later effect. They do not
fence an authority change after the last reply, queued Agent work, running tools,
approvals, existing descriptors or a branch restart after the disk mutation. They
do not install/revoke sandbox access, change runner epoch or prove Node policy
acknowledgement. `enforcement: not_tracked`, `canSubmit: false`, protocol **15** and
client contract **2** remain. Workspace transitions and new grants remain disabled.

Validation: **453 Node tests passed, 3 intentionally ignored**; **386 Gateway
tests**; **10 process integration cases** covering real Web/paired-device routes,
a policy change held between Gateway and Node, restart/receipt reconciliation,
legacy first-send compatibility, memory, project deletion, Node link and native
checkpoints. **54 focused Web tests**, Svelte checks, **7 focused Flutter tests**,
changed-file Flutter analysis and strict Node/Gateway/conformance Clippy pass.
Node migration/rollback, immutable origins, capability/connection replacement,
local control takeover during the authority reply and unavailable authority are
covered. Android native bridge code was unchanged and its JVM suite was not rerun.

One unrestricted-parallel local run hit the existing macOS terminal-size test
(`SIZE-30x100` instead of `SIZE-40x120`). Terminal code/tests are unchanged; that
case passed alone, and all 453 Node cases passed with four test threads. This is
recorded as an intermittent local PTY test observation, not a fixed terminal bug.
No full-workspace, Linux sandbox, Nix, physical Android/Keystore/live MethodChannel
or deployment acceptance is claimed. Temporary outputs are cleaned after this
slice; retained APKs, shared caches and user data are preserved.

## Saved attachment origins checkpoint (2026-10-28)

Node schema **2011** adds immutable `upload_origins` in the same transaction as
new `uploads` rows. The snapshot records the exact upload row, scope and observed
source Node/mode. Upload content/scope and origin updates are refused. Deleting
the parent upload cascades its metadata; deleting origins alone is refused. A
metadata failure rolls back the upload insert. There is no historical backfill.

The scope remains the existing one: ordinary uploads require the same owner and
source workspace; durable first-send uploads additionally require the original
conversation. The old `creation_uploads` restriction still applies to historical
rows. Pre-2001 uploads without a workspace retain their owner-only exception.
Moving a conversation cannot relabel or broaden any of these scopes. New
first-send origins retain the conversation restriction even if their transfer
index disappears. Old records remain explicitly `legacy`, with unknown Node/mode.

`GET /api/sessions/:id/uploads/:uploadId/reference` is authenticated owner-scoped
metadata, available directly to browser or paired-device requests. Gateway checks
the binding again after the Node reply and requires matching workspace scope.
It maps private source session IDs to an existing owned public session, otherwise
returns null, never a substituted current conversation or private locator. A Node
without this route returns its existing unavailable/not-found response; Gateway
does not fabricate provenance. Metadata alone is neither a byte download nor an
availability proof or grant.

Agent attachment consumption reuses the same ownership/deletion checks and reads
saved bytes through the configured uploads directory with no leaf symlink follow.
Regular-file size and SHA-256 must match. Missing/replaced data returns
`attachment_storage_unavailable`; a known pre-admission failure is a durable
rejected receipt for prompt/steer/follow-up. Receipt replay never sends it again.
Workspace copies remain mutable and existing entries are not overwritten, so a
user's later changes are preserved and are not mistaken for a saved snapshot.

Conversation/project deletion retains current ownership rules. In particular,
an ordinary workspace upload may outlive its source chat; its public source-chat
ID then becomes null. Deleting a first-send conversation or the owning workspace
removes its owned upload plus origin through existing cleanup. Checkpoint recovery
and memory deletion retain their independent provenance rules.

This does not capture Gateway project-membership/version or filesystem grant IDs,
implement live-file/cache/preview provenance, provide cross-Node copies, update
client presentation or install/revoke sandbox authority. Source workspaces are
not reclassified as projects. Actual mount/switch transitions remain U4 work.

## Transition admission fence integration (Node 2012)

The [first U4 implementation](unified-conversations.md#u4-implementation-checkpoint-node-transition-admission-fence-2026-10-28)
adds durable Node admission fences and tracked supervisor drain, independently of
binding generations. The frozen operation ID/plan hash and expected local
workspace/runner epoch are not a new binding, grant, policy revision or replacement
attempt. Acceptance checks current ownership/control; replay returns the same
receipt without reauthorizing effects. One pending intent per session prevents
two devices from installing different plans implicitly.

Internal Node-link routes are `/api/execution-fences/capabilities`,
`POST /api/sessions/:id/execution-fences`, and
`GET /api/sessions/:id/execution-fences/:operation` with explicit `POST .../drain`.
No Gateway public route or Web/App entry is exposed. The forthcoming coordinator
must capture and validate canonical source/target bindings and actual grants before
calling these endpoints; an arbitrary hash is not authority to install anything.
The node only records/reconciles the admission fence and closes tracked supervisors.
No completion, cancellation or fence-release endpoint is provided in this slice.

`supervisor_drained` describes that close sequence, not OS-level revocation or an
installed target. Both acknowledgement flags remain false, including after
restart. `enforcement: not_tracked` in the Gateway remains accurate. Queued input,
RPC mutation, startup, approval and selected host admission paths reject a fenced
session. Previously admitted effects and kernel access remain subject to the U4
revocation work; this fence must never substitute for it. Context and the source
binding stay unchanged, and deletion retains the operation's terminal receipt.

## Remaining U2 implementation and gates

1. Extend provenance beyond saved uploads/global memory to live files, previews,
   grants and canonical project membership/version snapshots. Add pending/acknowledged
   transitions, not just configuration. The saved-upload and global-memory deletion
   integrations are complete locally; they do not prove live resource revocation.
2. Extend the delivered Gateway/Node ordinary-command checks to approvals, Agent
   queues, internal deliveries and actual effect boundaries. Record acknowledged installed
   policy, not just configured revisions. Runner epoch/control stay independent.
3. Implement joining/moving/departure only with U4 revocation of actual project
   resources, retaining original conversation context and protecting other writers.
4. Exercise the complete transition across Node disconnect/restart, project deletion,
   checkpoints and memory provenance. The current adapter/read-model tests do not
   prove those effects.

Local validation and the reproduced pre-change macOS memory-counter snapshot
difference are recorded in the [U2 checkpoints](unified-conversations.md#u2-implementation-checkpoint-project-membership-and-configured-policy-2026-10-27). Physical
Android process/Keystore/MethodChannel and deployment/rollback acceptance are not
claimed by JVM or synthetic process checks. UI redesign stays deferred; no remote
push, deployment or Release is part of this slice.
