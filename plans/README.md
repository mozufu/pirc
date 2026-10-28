# Open work

[Project](../README.md) · [Documentation](../docs/README.md) · [Historical records](../docs/development/historical-records.md)

This is a work queue, not authorization. Each implementation needs the user's
go-ahead; nothing here authorizes deployment, paid evaluation, deleting state or
rerunning the `#[ignore]`d real-host-root tests. Preserve unresolved items when
updating this queue. Completed implementation and validation diaries are available
through the historical-records locator, not maintained as active plans.

Current behavior and decisions live in [Assistant memory](../docs/architecture/assistant-memory.md),
[Security decisions](../docs/architecture/security-decisions.md) and
[Chat projects](../docs/guides/chat-projects.md). Historical TypeScript paths must
be remapped to `crates/` and findings reconfirmed before implementation. Completed
security fixes, OM model policy/diagnostics, secure deletion and project hard
deletion are not open work.

## Current priority: unified conversation architecture

[Unified conversations, projects and an independent App](unified-conversations.md)
records the 2026-10-23 planning direction: merge the user-facing Chat/Work flow,
distinguish projects, conversations, tasks and execution environments, and make
the App independently usable. pirc may discover and suggest relevant work quietly;
execution remains governed by user-granted authority. Flutter Web is evaluation
only. Domain relationships and workflows come before new interface implementation.
The 2026-10-24 clarification adds configurable conversation workspaces, shared
project mounts/rules, project departure revocation, collaboration boards and
attributed **pirc pots** coordination. The user subsequently authorized phased code
implementation, not deployment or crate publication. Two plans carry that work:

- **[pots](pots/README.md)** (own folder: README, [design](pots/design.md),
  [acceptance](pots/acceptance.md)). Delivered: progress-only tracking
  (shipped in v0.10.0), explicit controlled dispatch (`d4f1efbd`, unreleased,
  Gateway schema 1011 / Node protocol 15), and ownership-based Stop, archive and
  revocation-fence paging (`6d87f97f`, unreleased). Open: device and full-conformance
  acceptance, remaining inbox lifecycle, content observation, proactive analysis,
  digests/push and standing grants.
- **[Reusable Rust foundations](library-extraction.md)**. Delivered: pure types,
  transport/OAuth extraction, the native runtime contract, and a loop core that
  the production agent run drives through a thin adapter. Open: the adapter
  follow-ups, API stabilization and a clean full workspace/conformance gate.

Existing security/data-loss issues and acceptance gaps below remain
valid; this does not mark mobile parity complete. The user subsequently accepted
[the specification-review recommendations](unified-conversations.md#accepted-specification-review-recommendations-2026-10-24)
as the planning baseline. Accepted choices are no longer repeated as approval
questions; engineering contracts, unspecified settings and explicitly deferred
App connection/Flutter Web decisions remain open. The original planning task was
not implementation approval; the later authorization is limited to staged code
work and does not clear the remaining acceptance gates.

[Conversation execution contracts](conversation-execution-contracts.md) details all
seven accepted follow-up areas: capability composition, foreground/background task
routing, overlapping permissions, Node switching, archive/delete/leave, saved
content versus live file links, and pots coordination/takeover. Each includes
flows, exceptions and future acceptance cases; items 4–7 add 32 such cases while
preserving current memory-deletion and checkpoint ownership rules. The
[main plan](unified-conversations.md#accepted-follow-up-behavior-and-detailed-contracts-2026-10-24)
indexes the specifications. They are planning contracts, not completed implementation
or evidence of passing runtime tests.

[Integrated architecture review](unified-architecture-review.md) records the
cross-plan contradictions corrected before publication, remaining product choices,
and engineering proof gates. The user then adopted the [recommended defaults](unified-architecture-review.md#adopted-defaults-and-deliberately-deferred-decisions):
read-only additional mounts, first-send allocation unless explicitly created,
durable notes without age expiry, scoped/bounded pots, and the three crate names
with optional default-off OAuth. Exact amounts/times and board-retention/editor
presets remain configuration work; App sign-in and Flutter Web stay deferred.
The architecture documents can be published as a planning baseline; this is not
approval to implement every unchecked stage.

## Current implementation status (2026-10-28)

The published baseline is `798aa817` (2026-10-28), including foreground CDP
admission (`00a72a16`) and the accumulated U1/U2/U4 checkpoints. All five remote
jobs passed: [Check, native Linux sandbox/checkpoints, Nix and executable sizes](https://github.com/mozufu/pirc/actions/runs/40653077860),
and [Android](https://github.com/mozufu/pirc/actions/runs/40653077926).
This evidence applies to that revision, not subsequent local changes.
Local commit `d500f2d3` added [browser resource guards and recorder retirement](unified-conversations.md#u4-implementation-checkpoint-browser-resource-guards-and-recorder-retirement-2026-10-28).
The next local slice adds [page-owned engine/network admission](unified-conversations.md#u4-implementation-checkpoint-page-owned-engine-and-network-admission-2026-10-28), including delayed DNS decisions and popup/iframe/worker initialization.
It preserves shared-workspace peers and does not enable public transitions or
claim complete browser/OS revocation.
Subsequent work remains local by default: no push, deployment, version change,
Release or activation is implied by a completed slice.

| Area                                           | Current state                                                                                                                                                                                                                                                                                                                                 | Remaining delivery                                                                                                  |
| ---------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| U1 — reliable first Send                       | Gateway/Node durable intents, original files, admission/Stop/delete fences, explicit rejected-message retries and Gateway nonce retirement; Web/private Android drafts and recovery controls are implemented                                                                                                                                  | Live-client failure/local-write matrix, Android process/device and rollout/rollback gates                           |
| U2 — conversation/project/environment bindings | Durable bindings/membership/policy histories, frozen memory origins and cleanup receipts; captured command intent with Gateway/Node rechecks; frozen saved-upload origins                                                                                                                                                                     | Live-resource provenance, effect-boundary fencing and acknowledged transitions                                      |
| U3 — unified navigation/UI                     | Deferred by the user                                                                                                                                                                                                                                                                                                                          | Revisit after core contracts; current clients receive necessary functional controls only                            |
| U4 — mount/workspace transitions               | Node admission fence, scoped inference retirement, Linux pidfd scope, durable journal/reconciliation, guarded native startup, terminal effect checks and durable terminal/host-command/browser supervision and foreground CDP admission; local browser resource/recorder guards and page-owned engine/network admission; transitions disabled | Gateway coordinator, OS revocation proof, replacement policy/acknowledgement and project resources                  |
| U5 — canonical tasks and collaboration         | Existing pots/task/team/goal/todo foundations remain                                                                                                                                                                                                                                                                                          | Map common task/attempt identities, shared notes and structured waits; preserve other writers and memory provenance |
| U6 — bounded proactive pots                    | Progress-only observation and explicit dispatch exist                                                                                                                                                                                                                                                                                         | Scoped content observation, finite budgets, quiet suggestions and synchronized notification/decision lifecycle      |

**The new U1 flow is still gated by `canSubmit: false`.** Pushing its code does
not enable it. Current formats are Gateway schema **1025**, Node schema **2018**,
protocol **15**, client recovery contract **2**, and Web IndexedDB/native private
envelope **3**. Existing ordinary session APIs remain available. Unaccepted
Gateway attachment staging expires after **seven days**; accepted attachments and
private drafts are not subject to that deadline. See [upgrade and rollback
notes](../docs/deploy/upgrades.md).

U2 has started independently of U1 activation: see the
[binding migration inventory](conversation-binding-migration.md) and
[implementation checkpoint](unified-conversations.md#u2-implementation-checkpoint-saved-attachment-origins-2026-10-28).
Schema 1022 adds canonical project membership and append-only configured mode and
workspace-capability policy histories. Web/native API adapters can read the
owner-scoped environment state directly while Node is offline. The response marks
Node enforcement as not tracked. Schema 1023 adds frozen global-memory version/proposal origins, preserved through
approval/restore and erased with the existing deletion flows. Schema 1024 adds
source-aware project deletion, explicit legacy review and durable cleanup receipts.
Schema 1025 adds frozen Web/Android command intent and transactional Gateway
admission checks; duplicate receipts do not redispatch and changed environments
require version-aware clients. Node schema 2010 adds durable command origins,
connection-scoped capability probes and Gateway authority rechecks after Node
queue/startup waits. Node schema 2011 freezes new saved-upload origins and existing
access scopes, exposes owner-scoped metadata through Web/paired-device HTTP, and
verifies stored bytes before Agent use. Existing uploads retain their legacy rules;
workspace copies retain later user edits. Live-resource grants, full effect fencing,
installed policy acknowledgement and transitions remain pending. Node schema 2012 adds the internal transition admission
fence and retriable tracked-supervisor drain. Draining does not acknowledge OS
revocation or install a new environment; no public switch is enabled. See the
[transition checkpoint](unified-conversations.md#u4-implementation-checkpoint-node-transition-admission-fence-2026-10-28).
Runner-scoped inference capabilities now enforce the admission boundary and cancel
only the affected session; late provider replies cannot re-enter its relay. See the
[inference checkpoint](unified-conversations.md#u4-implementation-checkpoint-runner-scoped-inference-retirement-2026-10-28).
Node schema 2013 adds durable launch reservations and bounded restart reconciliation
of captured Linux identities. Old or missing process evidence remains unresolved;
see the [launch journal checkpoint](unified-conversations.md#u4-implementation-checkpoint-durable-sandbox-launch-journal-2026-10-28).
Node schema 2014 gates native Linux runner execution on committed process identity
and a one-time permission record; missing evidence refuses startup. See the
[guarded launch checkpoint](unified-conversations.md#u4-implementation-checkpoint-guarded-native-linux-launch-2026-10-28).
Panel terminals now recheck their original binding/controller at each actual write and resize; see the [terminal checkpoint](unified-conversations.md#u4-implementation-checkpoint-fenced-terminal-input-2026-10-28).
Node schema 2015 journals approved host commands and joins their Node-owned supervision on Stop/deletion/transition drain. Unknown prior observations remain unresolved; see the [host-command checkpoint](unified-conversations.md#u4-implementation-checkpoint-supervised-host-commands-2026-10-28).
Node schema 2016 retains approved host-command write ranges across Agent settlement and restart. Unknown legacy ranges block writes instead of inventing availability; see the [resource-retention checkpoint](unified-conversations.md#u4-implementation-checkpoint-host-write-resource-retention-2026-10-28).
Memory cold cutover now holds Node admission through its checked durable append and excludes unresolved local host ranges; host approval avoids the memory lifecycle-lock inversion. See the [cutover checkpoint](unified-conversations.md#u4-implementation-checkpoint-memory-cutover-host-exclusion-2026-10-28).
Node schema 2017 retains panel-terminal launch and stop observations across close/cancellation/restart. Unknown shells block deletion and drain instead of disappearing with their UI; see the [terminal-supervision checkpoint](unified-conversations.md#u4-implementation-checkpoint-durable-terminal-supervision-2026-10-28).
Node schema 2018 retains browser group origins and close outcomes, including canceled requests, late popups and uncertain prior groups. Unconfirmed closure blocks deletion/drain; see the [browser-supervision checkpoint](unified-conversations.md#u4-implementation-checkpoint-durable-browser-supervision-2026-10-28).
Foreground browser commands now retain their caller and recheck at the first pipe write; later queued commands cannot reuse revoked authority. Background browser resources and complete retirement remain open.
The local [independent-drain checkpoint](unified-conversations.md#u4-implementation-checkpoint-independent-resource-drain-2026-10-28) prevents runner locks and failed observations from skipping other resource stops. Unknown historical processes remain blocked; no public transition is enabled.
Resource grants, project moves and full effect fences remain open. U1 still needs device/deployment acceptance
before activation. Detailed validation and the previously reproduced macOS snapshot
limitation are recorded in the checkpoints; no full Linux/device acceptance is claimed.

Latest completed U1 slices and their recorded evidence:

- [Node capability/connection fencing](unified-conversations.md#u1-implementation-checkpoint-node-capabilities-and-connection-fencing-2026-10-27):
  materialize/dispatch recheck capabilities, and all first-send effects stay bound
  to that exact Node connection. Mid-probe revocation, workspace removal/control
  loss and known connection replacement prevent later effects/command reservation.
  Explicit blank release still retains old files without uploading them. 336
  Gateway tests, five live-client tests, three native checkpoint cases, contract/
  protocol checks, strict Clippy and focused localization checks pass. Historical
  mixed deployments and Android OS/device remain unverified.

- [Node storage reply loss](unified-conversations.md#u1-implementation-checkpoint-node-storage-reply-loss-2026-10-27):
  actual Node allocation or upload commits, then its reply is lost before Gateway
  restart. Fresh native/Web recovery is GET-only; only a separate explicit Send
  resumes the same operation, preserving one Node session/upload and one model
  execution across another restart. Five live-client tests pass, along with the
  bounded old-client contract rejection test and targeted compile/lint checks.
  No production behavior or activation changes; Android OS/device remains open.

- [Offline allocation and native blob cleanup](unified-conversations.md#u1-implementation-checkpoint-offline-allocation-fencing-and-private-blob-cleanup-2026-10-27):
  real native materialize is held while Web stops/deletes an offline Node;
  Gateway restart retains the decision, and fresh clients query without replay.
  Stop allows only an explicit blank-conversation release. Fixed native private
  blobs lingering after a confirmed deletion; cleanup follows durable metadata
  and repairs on reopen without affecting retained copies. Four live process
  tests and 65 native JVM cases pass; Android OS/device remains unverified.

- [Mixed Web/native control races](unified-conversations.md#u1-implementation-checkpoint-delayed-web-dispatch-versus-native-takeover-2026-10-27):
  a held real Web dispatch loses control to a paired native client. Explicit
  takeover followed by Stop, confirmed deletion or Send cannot revive old work
  or duplicate admission. JVM/browser and both-host restart preserve identities;
  both clients reconcile with GETs, and deletion cleanup completes. Three live
  process tests pass (the new three-case race plus the prior two native and three
  Web fault cases); no product behavior or rollout changed.

- [Paired native process acceptance](unified-conversations.md#u1-implementation-checkpoint-paired-native-process-recovery-and-revocation-2026-10-27):
  actual Kotlin engine/file journal and two real device tokens pass discarded
  dispatch reply and read-only journal faults, complete JVM/host restart, GET-only
  reconciliation and single-device revocation. Original input/files and one
  session/command/model request per operation survive; the other device keeps
  access. The Web three-case process test also passes after extracting shared
  assertions. This is explicit opt-in JVM/backend proof, not Android OS/device or
  default CI coverage.

- [Live Web reconciliation](unified-conversations.md#u1-implementation-checkpoint-live-web-reconciliation-and-durable-uncertainty-2026-10-27):
  actual Web/IndexedDB plus Gateway/Node/Agent passes transport replay, truncated
  reply and aborted local receipt across all-host/browser restart and parallel
  GET-only checks. Fixed the pre-effect uncertainty marker in both clients.
  79 Web/63 native JVM cases, typecheck and strict Clippy pass. The repeatable
  browser test is explicitly opt-in, not implied by a normal CI pass.

- [Editor attachment snapshots](unified-conversations.md#u1-implementation-checkpoint-editor-attachments-survive-source-cleanup-2026-10-27):
  reopening an editable Android draft atomically reads its verified files before
  another window can clean the source; unsent recovery preserves those bytes.
  Failed opening keeps the current editor, and delayed opening cannot replace new
  navigation. 51 Web, 62 native JVM and 26 focused Flutter cases pass; two dedicated
  browser pages preserve separate copies/Blob bytes after cleanup and restart.

- [Gateway nonce retirement](unified-conversations.md#u1-implementation-checkpoint-gateway-retirement-of-an-unreserved-retry-2026-10-27):
  schema 1020 atomically fences an unreserved client nonce against delayed POSTs,
  preserving existing commands and original files. 329 Gateway tests and five
  backend process cases and strict Clippy pass. Client adoption is recorded below;
  activation remains pending.
- [Web/native retry recovery](unified-conversations.md#u1-implementation-checkpoint-web-and-native-interrupted-retry-recovery-2026-10-27):
  explicit recovery fences an unreceived nonce; read-only Check resolves a matching
  durable retirement, preserving original files and newer work. 76 Web, 57 native
  JVM and 23 focused Flutter tests pass; a dedicated two-page browser/restart
  proof keeps original Blob bytes and one Retry POST.

- [Gateway retries](unified-conversations.md#u1-implementation-checkpoint-gateway-durable-rejected-admission-retries-2026-10-27):
  durable retry identity, per-attempt ordering and global Stop reconciliation;
  320 Gateway tests, strict Clippy and five backend process cases passed.
- [Node retries](unified-conversations.md#u1-implementation-checkpoint-node-rejected-admission-retry-foundation-2026-10-27):
  exact rejected-predecessor checks and retained original input; 447 Node tests
  (three existing helper ignores), strict Clippy and three Node process cases
  passed. The real Agent journal proof retains one user message/model call.
- [Web/native retries](unified-conversations.md#u1-implementation-checkpoint-web-and-native-android-rejected-admission-retries-2026-10-27):
  nonce-before-POST, query-only uncertain recovery and old-writer fences; 68 Web,
  50 native JVM and 22 focused Flutter tests passed with clean targeted analysis.
  A dedicated two-page/browser-restart proof preserves one nonce and original
  Blob bytes without another POST. Native JVM/synthetic browser proofs are
  distinct from actual Android OS/device and live client-to-backend acceptance.
- [Earlier draft, conflict and pending-Stop checkpoints](unified-conversations.md#u1-implementation-checkpoint-web-durable-drafts-and-recovery-2026-10-27)
  retain detailed migration, concurrency, cleanup and permission evidence. Their
  “next slice” statements describe that point in history, not today's queue.

Next, close U1's remaining gates in this order:

1. Finish historical-binary/rolling-upgrade and broader permission-change gates.
   Node capability/reconnection and mid-probe authority faults now have unit proof;
   they do not replace mixed deployment/device acceptance. Node storage reply-loss
   recovery, initial native revocation, mapped Web-dispatch/native
   takeover and reverse-direction offline pre-allocation Stop/deletion now pass;
   those do not imply every mapped reverse-direction race is covered.
2. Verify Android MethodChannel, OS private storage/Keystore, process death and
   attachment memory pressure; request a physical device when that step is ready.
3. Complete activation/rollback and the affected full CI/conformance gates before
   changing `canSubmit`. Then proceed with U2, U4, U5 and U6; U3 remains deferred.

The published baseline `303fa8f8` passed remote [Check](https://github.com/mozufu/pirc/actions/runs/40484413613)
and [Android](https://github.com/mozufu/pirc/actions/runs/40484413359), including
Linux native sandbox/checkpoint and Nix jobs. Repairs cover the Android test
controller signature, relative retry-fixture executable path, runner APT mirror
lists, random-ID normalization and independent checkpoint fixture lifetimes.
This is evidence for that exact published commit, not the subsequent local
client additions or a physical-device pass. Local Nix validation remains waived.

Run only focused simple Flutter checks when changing Flutter. Clean run-owned
outputs after verification while preserving shared caches, SDKs, existing APKs,
user state and other agents' work. App sign-in/topology, Flutter Web and iOS remain
deferred. The [main plan](unified-conversations.md#current-progress-and-next-delivery-2026-10-28)
records the authoritative current status and full acceptance contract.

## Existing work and acceptance backlog

1. **Android approval acceptance (assistant 3a).** Verify multi-line USER proposal
   `confirm` bodies and their labels on Android; give delegation confirmations the
   same check. See [mobile acceptance](mobile.md).
2. **Optional network provenance follow-up (assistant 5).** Classify
   `browser_click` / `browser_type` on non-localhost origins and complete
   observational-memory provenance tagging of page results. Bash network taint
   and PTC agent-data tagging are already implemented.
3. **Android decisions and follow-up.** Use the [mobile plan](mobile.md) for native
   content compatibility and acceptance. Decide token rotation before the 30-day
   limit versus monthly re-pairing (including A7's near-expiry warning),
   sideload-only versus F-Droid/Play distribution and production signing, and
   whether the native Context inspector is later or never.
4. **Data-driven workspace modes.** [Modes](modes.md) phase 3, re-scoped
   2026-10-19: fixed Chat/Work tabs (tab from the `assistant` capability, Work
   grouped by node), panels by capability, modes chosen only when creating a
   workspace. Removes `ui.group` as a breaking change (protocol 13; existing
   mode files must drop `group:`). Adds a scratch-mode guide example and a
   delegation-into-per-session-workspace scenario. Phase 2 (configuration,
   protocol 12, mode-id stores and agent enforcement) is implemented; full Linux
   conformance passed 217 tests with reviewed snapshots on 2026-10-19. Phase 3
   was implemented 2026-10-19; remaining: the Settings Modes page, retiring
   `kind`, an Android scratch parity capture and guide screenshots. Treat those
   as existing behavior/backlog; assess further fixed-tab UI expansion against
   the adopted unified-conversation contracts before implementation.
5. **Workspace-memory search quality.** [Memory search](memory-search.md):
   an evaluation set, then FTS5 + BM25 with CJK bigrams replacing `LIKE`, then
   optional hybrid semantic search through a gateway-side embeddings endpoint
   (brute-force cosine in Rust, no SQLite extension). Stays on SQLite; Postgres
   and sqlite-vec are rejected there. Each phase needs the user's go-ahead;
   phase 2 also needs the embeddings source decided.
6. **GPU access in the agent sandbox.** [Sandbox GPU](sandbox-gpu.md): an opt-in
   node setting adds two measured Seatbelt rules for Metal on macOS and exact
   NVIDIA/render-node binds on Linux (unverified on hardware), plus a NixOS module
   option replacing the node's `PrivateDevices`. Security-boundary change: each
   phase needs the user's go-ahead and a recorded decision.
7. **Delegation auto mode precision.** [Delegation autonomy](delegation-autonomy.md)
   phases 0–2 (dispatch policy, verified quotes, relayed approvals) were
   implemented 2026-10-19 with the user's decisions recorded in Security
   decisions. Remaining: phase 3 (session allows, soft/hard danger), only after
   reassessing with `scripts/approval-stats.ts`; plus real-device checks of
   relayed approvals and Stop.
8. **Calendar for schedules and personal events.** [Calendar](calendar.md):
   approved month/week/day/list views for Web and native Flutter Android,
   personal events, recurrence/exceptions, reminders and separately authorized
   agent proposals. Implementation is authorized locally; see the plan for
   verification and remaining device acceptance. Remote publication requires a
   later explicit request.
9. **Agent checkpoints and safe recovery.** [Checkpoints](checkpoints.md):
   phases 1–5 implemented and verified locally, including Node capture/journaling,
   independent recovery workspaces, owner-scoped Gateway operations and Web/native
   Android review/continuation. The published memory update is integrated;
   recovery keeps its own blank conversation and cannot write to source memory.
   Original directories and later user changes remain untouched. Coverage is
   observational; Linux runtime, real-device acceptance and reviewed disposal
   remain follow-ups. Publication still requires an explicit request.

## Project-only memory (B): collaboration design reopened, migration still shelved

On 2026-10-24 the user proposed project-scoped boards/shared notes and withdrawal
of project-specific content on departure. This reopens the collaboration/context
boundary for [architecture discussion](unified-conversations.md), not automatic
implementation of the old B design. Existing global USER/MEMORY remains as-is;
full re-scoping, the old restricted profile and migration remain undecided.
Hard deletion (D) is implemented, not blocked on this discussion. Unmounting alone
does not erase old conversation content, copies or previously learned notes.

If reopened, retain the design constraints:

- Opt-in, off by default and for existing projects. Add `scope_id` (default
  `global`) to entries/log/proposals and a composite tombstone key. Scope every
  store entry point by trusted `{owner, scope}` from the session, never agent
  arguments; include search, recall and mirrored records.
- Version snapshots by scope generation and bind proposals to scope and
  generation. Not retroactive: old sessions keep their frozen snapshots.
- Decide fresh sessions for every scope-generation change (recommended) versus
  weaker continuation, explicit cross-scope copying and its review, and dormant
  scope versus deletion/export when disabling.
- This isolates projects from each other, not from gateway/node operators,
  providers or backups.

The full deferred design is `git show 7677d24:plans/project-isolation.md`, section
B (TypeScript paths need remapping). Later decisions and the pre-cleanup plans
are at `af7074fc51742e79c8f0c76a9aaf64f80b414f7e`; see
[Historical records](../docs/development/historical-records.md).

## Manual validation

Attach these to the release that needs them; they are not new feature tasks.
Synthetic/emulator coverage does not close physical-device or real-account gaps.

- **Web approvals:** browser acceptance of the approval-mode picker and warning,
  and switching modes through a real gateway and node.
- **Project deletion:** dialog in a real browser and recovery after a real node
  disconnect. Android controlled-failure tests do not establish real network
  interruption recovery.
- **Browser:** real Android takeover (tap mapping, IME, drag scrolling) and WebM
  playback.
- **Schedules:** installed-PWA push on a real iPhone (Add to Home Screen). Deploy
  gateway and nodes together for the changed deliver body.
- **Sandbox (NixOS/Linux):** a full agent session, browser included, on a
  non-container x86_64 host at native speed; boot-time tmpfiles behavior on a
  real host. Earlier module/LXC/QEMU validation is complete; srt `apply-seccomp`
  is obsolete because srt no longer ships.
- **Mobile:** iOS/Android soft keyboard and safe areas, CJK IME in the Android
  composer, terminal HTTPS asset origin and a release build on a real phone;
  detailed account, device, provider and push gaps are in [mobile](mobile.md).
- **PTC:** Anthropic direct calls with `null`/extra arguments; declining approvals
  and rendering on the new Android client; a real model reading the newer
  agent-data fences. macOS OpenAI Responses/Chat Completions runtime checks were
  completed, but reviewed behavior changes were not re-measured.
- **Rust post-cutover:** investigate if the one-off, unreproduced
  `node_link_side_runs` CI timeout recurs. TLS, a real identity provider, phone
  pairing, push and terminals are not covered by the macOS end-to-end checks.
  The macOS v0.4.1/v0.5.0 archives are unsigned and not notarized.

## Accepted limitations — not new work

- **Security:** single-user gateway model, session-only domain approvals, S10
  (host atomic replacement detaches a protected Linux mount) and S18 (browser
  WebSocket/non-HTTP egress and DNS rebinding) stay accepted. Linux socket hiding
  covers sockets bound at plan time, not sockets bound later or in another
  network namespace. Other accepted security choices are in
  [Security decisions](../docs/architecture/security-decisions.md); do not
  reopen them without a new decision. Lasting domain allows belong in
  `sandbox.network.allowedDomains`; revisit session-only prompts only if repeated
  prompts become common.
- **Repository identity:** normalized repository keys preserve path case, so
  `github.com/Owner/Repo` and `github.com/owner/repo` differ. `.git` symlinks and
  absolute `gitdir:` / `commondir` are followed; only the normalized key leaves
  the node.
- **Project deletion:** automatic forget/rollback entries are handled as they
  stand at confirmation; only entries needing a user decision are revision
  compared. Rollback may leave memory over budget. Chat deletions before schema
  1004 did not record their project. Other exclusions and scoped tombstones are
  documented in [Deleting a project](../docs/guides/chat-projects.md#deleting-a-project).
- **Browser:** teammates/subagents have no browser; the screenshot action log is
  memory-only and lost on node restart.
- **PTC (accepted P3):** bash writes through a symlink created in the same command
  can skip the write lease. Plain bash output remains unlabelled (network fetcher
  or URL commands and `agent_inbox`, `delegation_status`, `memory_search`,
  `board_read` are tagged). Guests inherit agent sandbox rights. The approval
  convention does not enumerate host-gated operations. Operations ignoring abort
  may outlive the five-second grace; an agent crash mid-script is reported to the
  model as “interrupted”. Queued operations count toward progress and eight long
  waits can fill all slots.
- **Rust post-cutover, waived not passed:** full PTC/task-time comparison with the
  TypeScript baseline, real-provider smoke tests and polyglot evaluation.
  Reopening needs an agreed protocol, budget and credentials (historical tooling
  at `2d480d3`). Rust protocol 10 is incompatible with TypeScript nodes/gateways;
  current upgrades must follow [Upgrades](../docs/deploy/upgrades.md). Never
  delete old state without approval.

## Watch, do not build yet

- **Consolidation (“dreaming”):** only if `memory_full` becomes frequent at 8,000
  characters; revisit budgets first. Keep origins: consolidated text must not
  gain `user` origin.
- **Moving chats between projects and shared project files:** revisit remaining
  workflow friction only when painful with more than a handful of chats; shared
  project files themselves are already implemented.
- **Vector index (sqlite-vec / ANN):** brute-force cosine is planned in
  [memory search](memory-search.md) phase 2; revisit an index only at the
  thresholds listed there.
- **A second chat node:** needs its own `chats` workspace and a New chat rule.
- **`workspace.read`:** reading a linked repository without delegating, only if
  chats keep delegating just to look at a file.

## Memory integration

The authorized [memory handoff redesign](memory-handoff.md) has been ported to the Rust mainline. Its final validation record and separate repository activation constraints are maintained there; this does not authorize deployment or existing-ledger activation.
