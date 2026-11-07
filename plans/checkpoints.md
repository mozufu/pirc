# Agent checkpoints and safe recovery

[Plans](README.md) · [Session UI](../docs/guides/session-ui.md) · [Tools](../docs/guides/tools.md)

**Unified-architecture integration (2026-11-07):** [C6](unified-completion-contracts.md#c6-projects-folders-and-collaboration)
preserves independent-copy versus Git-worktree/shared-storage limits;
[C7](unified-completion-contracts.md#c7-context-deletion-memory-and-content)
requires the restricted recovery factory, private memory scope and non-overwrite
behavior even after project/binding changes. These are planning integration gates,
not new acceptance or changes to implemented recovery behavior.

Status: phases 1–4 implemented locally, 2026-10-22: safety experiments, opt-in
Node capture/journaling, independent recovery/isolation, authenticated Gateway
operations, Web/native Flutter Android review and durable continuation. Phase 5
local macOS integration/crash/client acceptance is complete; real Android and
Linux runtime acceptance remain. Multiple agents and preservation of both existing and later user
changes are hard requirements. Keep work local; no deployment, remote push or
Release is authorized. The published memory update was integrated locally on
2026-10-23 at the user’s request; see the memory integration acceptance below.

## Product decision

Recover a selected agent change **against the current workspace**, retaining
unrelated changes, rather than replacing the workspace with an old snapshot.
The default action builds a **new recovery workspace**; the original directory,
Git index, refs, user changes and running agents remain untouched. The user can
review the result and explicitly open a session in that workspace.

This is a deliberate safety boundary. A hash check followed by atomic rename is
not a filesystem compare-and-swap: an editor can write between those operations.
An in-process lock, advisory file lock or filesystem watcher does not stop an
uncooperative editor, terminal or another host. The first release therefore has
no automatic in-place restore or force-overwrite button. In-place publication
would need a separately reviewed design with an enforceable writer boundary;
it is not a hidden final step in this proposal.

The original workspace is never renamed, deleted, reset, stashed, staged,
committed or cleaned as a side effect of preparing or opening a recovery.

## Existing behavior and integration points

- `crates/pirc-node/src/write_broker.rs` coordinates overlapping paths between
  sessions within one node. Ownership is a session id, and a lease lasts until
  its run settles, exits or stops. It is not a per-operation or cross-node lock.
- `crates/pirc-node/src/runner/side.rs::grant_write` answers agent write requests.
  `crates/pirc-agent/src/agent.rs::acquire_write` and `tools/files.rs` use them.
  The current edit tool reads/computes its replacement before acquiring the
  lease; `write_checked` checks paths but does not compare a content revision.
  A checkpoint broker must coordinate read/transform/write and reject stale
  preimages, rather than merely add a snapshot around the existing final write.
- Teammates/subagents forward write requests through the parent in
  `features/team/broker.rs`. They share the parent's sandbox and lease authority;
  that does not establish exclusive per-agent ownership of a file.
- Bash, PTC, background jobs and the interactive terminal can change files.
  PTC's operation exclusivity is not a global filesystem transaction. A watcher
  supplies invalidation, not trustworthy writer identity or complete history.
- Web's `components/panel/{GitTab,DiffView}.svelte` and Android's
  `lib/live/{git_state,git_pane}.dart` provide existing diff/navigation patterns.
- Editing a message or switching conversation versions currently changes
  context only. This remains a separate action; it must not implicitly recover
  files or rerun tools.

These are confirmed code facts, not assumptions to replace with a new lease
model without review.

## Safety invariants

1. **Dirty baselines count.** Capture actual file bytes before the agent writes,
   including saved user changes not committed to Git. `HEAD` is never the sole
   baseline. Staged and unstaged state are distinct; recovery does not modify
   the original index. Unsaved editor buffers are not visible to the node and
   cannot be claimed as captured; the editor's original workspace stays intact.
2. **Only attributed effects are candidates.** A timestamp, Git diff or shared
   session id alone does not prove that a change belongs to Agent A. Uncertain
   changes are identified as uncertain and receive no automatic inverse.
3. **Later writes survive.** Recover by an inverse three-way merge with the
   latest observed content. A later write to the same hunk becomes a conflict;
   it is not silently replaced with the baseline.
4. **Source stays unchanged.** Read the source workspace, create results in a
   fresh node-owned destination, and publish that destination only after its
   journal reaches `ready`. Never use hard links to mutable source files.
5. **A preview is versioned.** A preview describes exactly which checkpoint,
   paths/hunks and observed source version produced it. Source changes make it
   stale and require a new preview; stale state is visible across clients.
6. **Unknown means unavailable.** Missing objects, interrupted captures,
   incomplete process quiescence, unsupported files or untrusted workspace
   identity produce an explicit gap/conflict, not an empty or successful restore.
7. **Recovery is recoverable.** Jobs have durable states, retained inputs,
   idempotency and crash cleanup. No half-built output is exposed as a usable
   workspace. A recovery never deletes its own source evidence.

## Multi-agent behavior

### Shared directory: group attribution

Existing sessions may continue to share their current execution arrangement.
A turn checkpoint includes the parent and all descendants whose writes belong
to that run, identified by node-issued run/group ids. A turn is stable only when
all writers and relevant background work have ended or are explicitly quiesced.
Returning a model response or a child result does not establish this condition.

Direct `write`/`edit` operations can record exact pre/post blobs and writer ids
at the write boundary. Interleaved operations are serialized and journaled by
the trusted node broker, with stale-base rejection. Hook-rewritten arguments,
PTC calls, parent and child tools use the same final-operation boundary.

Arbitrary shell commands, daemons and a user's editor can still write outside
that boundary. A shared-directory before/after scan is therefore **observed
change**, not proof of individual ownership. Do not label the difference as
Agent A's reversible changes merely because A's command was running. Such a
checkpoint can supply evidence, but uncertain files stay current in an
automatically prepared result and require explicit review.

### Independent parallel agents: isolated execution

For reliable agent-specific checkpoints, offer node-created isolated execution
workspaces. Start each agent from a captured version that includes the user's
existing dirty files. Each workspace has one writer group; children either join
that group or receive their own isolated root. Changes from one isolated agent
are proposed for integration and never copied into another agent's directory
automatically.

The workspace factory must use existing workspace authorization, trust and
sandbox construction. Do not let an agent choose an arbitrary new writable
root. Shared mutable `.git` metadata, writable alternates and hard-linked files
cannot allow one agent to modify another workspace. An independent checkout/copy
is the safe starting implementation; a Git worktree optimization requires a
separate verified metadata boundary. Neither operation changes user branches or
the original index.

Copy/checkout preparation must not run repository hooks, smudge filters,
submodule initialization or project scripts implicitly. Re-evaluate content-hash
trust before running anything in the candidate. Respect effective sensitive
path/deny-read policy during capture and copy, and preserve equivalent restrictions
at the new root: moving a protected file into a newly allowed path must not
bypass the sandbox. Validate this before enabling recovery continuation.

Within shared directories, extend coordination to all cooperating nodes on the
same host/account, using canonical physical-root identity and an account-level
broker/lock with fencing generations. Include parent/child writers and pirc
panel writes, not just the main agent. PID reuse is not ownership. Do not
advertise this as protection against external editors or network-filesystem
writers on other hosts. Overlapping/aliased roots and unverified multi-host
shared storage must be rejected for exclusive capture or marked observational.

### Required scenarios

| Situation                                              | Required result                                                                                         |
| ------------------------------------------------------ | ------------------------------------------------------------------------------------------------------- |
| User already changed a file before A starts            | A's baseline includes those bytes; recovery keeps them.                                                 |
| A edits one hunk; the user later edits another         | Merge A's inverse into current content in the recovery workspace; retain the user's hunk.               |
| A edits a hunk; the user later edits the same hunk     | Conflict. Preserve current bytes until reviewed.                                                        |
| A and B edit different hunks from known versions       | Recover only A's inverse; retain B's hunk.                                                              |
| B changes code introduced by A                         | Dependency/conflict review; no automatic removal of B's work. A clean text merge is not semantic proof. |
| Children share a directory and shell writes interleave | Group/uncertain attribution; no invented child ownership.                                               |
| Another device confirms the same recovery              | Return the same job/workspace; do not create or apply it twice.                                         |
| Source changes while a result is being prepared        | Original remains untouched; mark result stale and require refresh/review before continuation.           |

## Capture and storage

The node owns checkpoint blobs, manifests, operation journal and recovery jobs
under its private state directory. The agent sandbox must deny this storage,
including through the existing same-account daemon registry. The Gateway owns
authentication/routing and optional lightweight UI metadata; it is not the
authority for filesystem snapshots. Never send full checkpoint contents to a
model by default.

Suggested model (allocate schema/protocol versions during implementation):

- **Checkpoint:** id, owner, node/workspace identity, session/conversation branch,
  run, writer group, parent checkpoint, manifest revision, coverage and state
  (`capturing`, `stable`, `observational`, `incomplete`, `expired`).
- **File version:** path id, relative path, file kind, exact content digest,
  executable bit, size and blob reference; explicit `absent` state.
- **Operation:** node-issued actor/run/parent/tool ids, order and dependency
  edges, pre/post versions, effect status, verified or observational attribution.
- **Recovery preview/job:** owner, source/target checkpoint ids and revisions,
  selected file/hunk ids, observed source fingerprint, merge outcome per file,
  idempotency key, job revision and output identity.

Content-addressed blobs deduplicate identical bytes and can use bounded
compression. Save objects durably before committing their manifest references.
Preserve exact bytes/line endings; text diffs are a presentation layer. File
identity includes type and mode, not just a digest of textual content.

Default coverage: regular Git-tracked files and non-ignored untracked files
within the authorized root. Capture eligible nested directories without
crossing symlinks, mounts or nested repositories silently. Exclude `.git`, node
state, caches, dependencies/build output and configured sensitive files. Report
every exclusion relevant to a change; tracked secrets still make captured blobs
sensitive. Never promise that an ignored/oversized/unreadable file is protected.
Non-Git directory workspaces use the same manifests with explicit exclusion
rules and a recovery copy rather than a fabricated Git history.

Use bounded scans/streaming hashes, quotas and a visible coverage summary.
If an unmanaged source cannot provide a coherent capture, label it
observational; repeated hashes/watch events do not prove a multi-file atomic
snapshot. File changes between capture and preview invalidate the affected plan.

Proposed initial retention: 7 days, 100 stable checkpoints per workspace, a
1 GiB node-wide checkpoint budget, and a 10 MiB automatic per-file capture limit,
all configurable. Enforce the first applicable limit and show excluded files or
capture suspension. Keep an active run, pinned checkpoints and live recovery
inputs; if those fill the budget, suspend new captures visibly instead of
evicting them. Recovery workspace copies count against a separate displayed
disk reservation; refuse preparation before disk exhaustion. They are never
automatically deleted after a user has opened/modified them. Final defaults are
reviewable before implementation.

Deleting a session removes its checkpoint manifests and unreferenced blobs,
subject to references retained by another explicitly created recovery workspace
or job. Show those dependencies before deletion; do not silently destroy an
active recovery or a workspace containing new user edits. Cleanup, export and
backup guidance must treat checkpoint contents as private workspace data.

## Recovery algorithm

For one selected coherent checkpoint/range, compute its **net attributed
change** once; do not apply both a child operation and its parent aggregate.
Arbitrary overlapping multi-turn selection is deferred until dependency closure
can be validated.

For each selected text file:

```text
before = version before the selected agent change
after  = version after that change
current = latest observed source version
candidate = three_way_merge(base=after, ours=current, theirs=before)
```

Only clean, attributed inverses are included automatically. Retain current
content in conflicted output paths and keep before/after/current/candidate
versions separately in the trusted recovery store. Do not insert conflict
markers into source files or hide unresolved conflicts behind a success label.
A clean merge means textual compatibility, not that later code still works;
show dependency warnings and offer existing permitted test workflows.

- **Agent-created file:** remove from the recovery candidate only when current
  kind/content/mode exactly equal the agent's post-version. Later edits conflict.
- **Agent-deleted file:** recreate only if the current path is still absent and
  no directory/symlink/path collision exists.
- **Binary file:** exact post-version match permits inverse in the candidate;
  any later difference requires review. No text merge.
- **Rename/move:** operate on verified path history and both endpoints; Git
  similarity is display-only. Unknown ownership or occupied destination conflicts.
- **Directories:** never recursively delete unknown current contents. Build
  results from validated entries and keep unrelated files.
- **Symlinks, hard links, submodules, permissions/ACLs and special files:** no
  traversal or implicit recursive restoration. Start with ordinary files and
  executable bits; unsupported kinds remain explicit exclusions. Copies break
  hard links and never restore setuid/setgid or arbitrary ownership metadata.

Prepare results in a fresh unpublished destination. Preserve all eligible
current source files, including unrelated current untracked files, then apply
the validated inverse there. A source change or lost node/control authority
invalidates the job's acceptance revision. Interrupted copy/merge jobs remain
unavailable and can be retried idempotently or cleaned by their exact job id.

Before **Continue in recovery workspace**, revalidate the source observation,
job revision, conflicts and workspace trust. If the original has advanced, do
not present an old copy as containing its latest changes: refresh the candidate
against the new source or keep it as an explicitly historical copy. Opening the
result creates an authorized workspace/session linked to its source checkpoint;
it does not retarget a live runner or replay tool effects. Preserve origin and
untrusted-data provenance when transferring any conversation context.

## Original service/API sketch

The phase-4 implemented contract is documented below; these original paths are
retained as design history, not an API compatibility promise:

- `GET .../checkpoints`: paginated metadata/coverage and writer groups.
- `GET .../checkpoints/:id/diff`: bounded selected changes and attribution.
- `POST .../recoveries/preview`: checkpoint revision, opaque file/hunk selections;
  returns an expiring owner-bound preview id, source fingerprint and conflicts.
- `POST .../recoveries`: preview id/revision + idempotency key; starts preparation
  of a new workspace. The client cannot substitute arbitrary paths or blobs.
- `GET .../recoveries/:id`: authoritative job state and remaining conflicts.
- `POST .../recoveries/:id/continue`: explicit user intent plus current revision;
  revalidates and creates/opens the linked workspace/session once.

States: `previewing → review_required/ready → preparing → ready_to_continue →
continued`, with explicit `stale`, `failed`, `cancelled` and `expired`. Use distinct
preview/job state types so `ready` cannot mean both preview and usable output.
Return 409/current state for stale revisions; repeated requests return the
existing outcome. Nodes enforce authorization, root identity and journal state
again even when Gateway validation passed. A recovery is a user-only operation
in the first release; agents can report checkpoints but cannot approve recovery,
change retention or discard conflicts. Paired devices require the normal owner
and control rules; do not broaden short-lived management grants.

Owner-scoped invalidation makes Web/App refresh the authoritative job. A second
device's confirmation closes/disables the first device's stale action. Re-pair,
account changes, session switches and node reconnects fence old requests and
cached file contents. Node offline means metadata can be viewed if cached;
recovery actions are disabled and never replayed from an offline mutation queue.

## Web and native Android experience

Use the current pirc typography, colors, buttons, diff views and dialog/sheet
conventions, with English defaults and Traditional Chinese translations.

1. **Conversation entry:** a subtle checkpoint action on a completed user turn
   or run card, with coverage and parent/child group information. Incomplete or
   observational captures explain their limits instead of showing a green badge.
2. **Workspace history:** a Checkpoints section in the existing Git/changes
   panel, also accessible in non-Git workspaces. Filter by session/run/agent;
   distinguish individual verified effects from a shared writer group.
3. **Preview:** files marked safe inverse / retains later edits / conflict /
   excluded. Show original user baseline, agent change, current content and
   proposed result. Text such as “Current changes retained” must reflect the
   actual merge outcome, not merely an unchanged Git status.
4. **Action:** **Prepare recovery workspace**, with estimated disk usage and
   the statement that the current workspace is retained. Review unresolved files
   explicitly; default is to keep their current content.
5. **Result:** **Continue in recovery workspace**, **Open original**, and a
   link to the recovery's origin. Display stale/newer-source state before opening.
   Deleting an unused generated workspace has its own reviewed action.

Desktop Web/tablet uses file list plus diff/review pane. Phone Web and Flutter
use a full-height native review route/sheet with a file selector and Before /
Agent / Current / Result views. Provide keyboard-accessible controls on Web,
native scrolling, code highlighting and accessible status text on Android.
Large text, keyboard/IME, landscape and safe areas must not hide the action or
conflict state. Preserve selection/draft on reconnect; never store private blobs
in browser localStorage or notification payloads.

Recovery is independent of **Edit message / Save and regenerate**. A later
combined workflow would need an explicit choice and separate confirmation; the
first release never undoes files merely because a conversation branch changes.

## Implementation phases and acceptance

1. **Safety spike and fixtures.** Confirm file-effect hooks, descendant/process
   lifetimes, sandbox roots, same-host cross-node coordination and disk costs.
   Add a synthetic dirty workspace with user/A/B changes. Prove the inverse
   algorithm and the unchanged-source invariant before adding product actions.
2. **Node capture/journal.** Blob store, dirty baselines, trusted actor/group ids,
   coverage, retention and crash behavior; direct file tools plus explicit
   observational shell coverage. Do not claim individual parallel-agent recovery
   until isolated execution/root boundaries have passed acceptance.
3. **Safe preparation and isolation.** Recovery workspace factory, inverse
   merge, conflicts, idempotent durable jobs and isolated agent execution needed
   for full per-agent coverage. Inspect sandbox/trust and `.git` metadata behavior
   on Linux and macOS; allocate schema/protocol changes and mixed-version errors.
4. **Gateway and both clients.** Authorization/routing, invalidation, Web and
   native Flutter entry/history/preview/result UI, translations and parity.
   Phases 1–3 can be locally reviewed, but delivery is not complete with one client.
5. **Integrated acceptance.** Conformance plus actual filesystem concurrency,
   process crashes/restart, node disconnect/reconnect, two clients confirming,
   and real Android review/continuation when a device is available. Document any
   unverified platform behavior rather than marking it covered by unit tests.

### Phase 1 results and implementation gates

The executable experiment is
[`checkpoint_safety.rs`](../crates/pirc-node/tests/checkpoint_safety.rs), with a
test-only [helper](../crates/pirc-node/tests/checkpoint_support/mod.rs).
Neither phase-1 file is linked into the node executable. The phase-1 commit
introduced no API, database schema, automatic checkpoint, sandbox permission,
background capture worker or memory/session-history integration.

**Code audit, reconfirmed against the current Rust implementation:**

| Boundary                      | Finding                                                                                                                                                                                                                 | Required before product capture                                                                                                                                                                                        |
| ----------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Direct writes                 | `tools/files.rs::EditTool::run` reads and transforms before `acquire_write`; `write_checked` checks paths and uses `O_NOFOLLOW`, but does not compare an expected file revision.                                        | Put preimage capture, stale-base rejection, final authorized mutation and postimage evidence at the trusted node boundary. Existing hooks or leases alone are insufficient.                                            |
| Child ownership               | `features/team/broker.rs` forwards child `write_lease` through the parent's acquire callback.                                                                                                                           | Node-issued run/group/operation identity; do not infer the child writer from the parent session lease.                                                                                                                 |
| Run completion                | `runner/process.rs` releases leases on `agent_settled`. `features/background/mod.rs` explicitly allows background tasks to survive run abort; session closure stops them. Panel terminals have a separate PTY lifetime. | Account for descendants, PTC, background tasks and terminals. Require quiescence or report observational/incomplete coverage. A model response is not the boundary.                                                    |
| Process cleanup               | Agent bash uses `GroupGuard`; node host commands use their own process session; runner exit kills its process group.                                                                                                    | These contain ordinary descendants but are not proof that detached processes or external editors have stopped. Test their lifetimes separately from run settlement.                                                    |
| Cross-node writes             | Each `Node` constructs a separate in-memory `WriteBroker`. Two broker instances grant the same canonical physical root concurrently in the experiment.                                                                  | Account-level coordination and fencing for cooperating nodes, including alias/nested-root handling. Until then, no cross-node exclusive-capture claim. Multi-host shared storage remains outside exclusive guarantees. |
| Private storage and new roots | The daemon registry includes the node state directory in private paths. Linux/macOS policy-generation tests deny a prospective `state/checkpoints/blob`; the original session cannot write the new recovery root.       | Keep blobs under private registered state. Reauthorize a new workspace and translate effective deny rules before continuation. A copied file is not automatically safe to reopen.                                      |

**Safety experiments: 25 passed on macOS arm64.** They exercise:

- Actual disposable Git repositories with distinct committed, staged, unstaged
  and untracked user bytes. Preparing the inverse preserves the source's bytes
  and the complete observed Git metadata tree, including index, refs and HEAD.
- A/B edits in different hunks and both orders; later user edits remain. Same-hunk
  edits and B modifying A-introduced lines keep current bytes and report conflict.
  Unattributed shell/shared-child effects are retained for review.
- Exact create/delete postimages, occupied deleted paths, directory/type changes,
  binary differences, CRLF, missing final newline and executable bits. No conflict
  markers are written to either source or conflicted candidate files.
- Sensitive paths, newly added deny rules, ignored-fixture directories, symlinks,
  hard links and oversized files remain explicit exclusions. No traversal into
  linked external data, copying of `.git`, hooks/filters, source hard links or
  privileged permission bits occurs in the fixture preparation.
- A deterministic external write at the old check/rename race point and an
  independent shell process writing during preparation. The source retains the
  writer's result and the candidate is stale. Replacing the source root with
  identical bytes is detected using device/inode identity as well as its path.
- Capture byte/entry limits, copy budget rejection before destination allocation,
  non-quiescent group refusal, and injected failure cleanup of only the temporary
  candidate. Source observation errors fail the preparation rather than imply an
  empty or successful snapshot.

The existing host-command process-group cleanup test and nine background-task
lifecycle tests also pass (35 tests total for this round). Focused Clippy with
warnings denied, Rust formatting, plan formatting and diff whitespace checks
pass. These results cover the test-only experiment and the stated existing
lifecycle contracts, not a complete checkpoint product.

**Capacity experiment:** three 4 KiB files need a 12 KiB independent recovery
copy. Across baseline/A/current/candidate there are 12 KiB of unique content in
this fixture: prospective blob deduplication does not remove the additional
12 KiB copy cost. These are logical content sizes, not filesystem allocation,
compression, journal or metadata estimates. The helper implements no durable
blob store. Its 1 MiB/file, 4 MiB/capture and 1,000-entry bounds are test limits,
not the product defaults below; physical space reservation/ENOSPC still needs
implementation and acceptance.

**Limits:** the helper only walks test-owned trees with explicit fixture
exclusions; it does not implement production Git-ignore resolution, a hostile
filesystem descriptor walker, mount/nested-repository detection or a coherent
multi-file snapshot. The fixture supplies verified attribution and group
quiescence; no live node currently produces that evidence. The standalone
`git merge-file` experiment uses `base=after, ours=current, theirs=before`; a clean
text merge is not semantic dependency analysis. Rename attribution, persistent
journals, crash/power-loss recovery, actual Seatbelt/bubblewrap execution for
these candidates, continuation, client UI and Linux runtime acceptance remain
later-phase work. No Nix build is required for this phase at the user's request.

Reproduce from the repository root (requires the existing host Git executable):

```sh
cargo test --locked -p pirc-node --test checkpoint_safety
cargo test --locked -p pirc-node --lib runner::host::tests::an_aborted_command_leaves_nothing_running
cargo test --locked -p pirc-agent --lib features::background::tests
```

These contracts constrain the phase-2 implementation below; passing the
experiments does not authorize exposing recovery as ready.

### Phase 2: Node capture and operation journal

Implemented in [`checkpoints/`](../crates/pirc-node/src/checkpoints/mod.rs), with
main-agent file-tool handshakes, runner lifecycle binding and session cleanup.
Configuration is opt-in per local workspace id; see the
[deployment contract](../docs/deploy/node.md#experimental-checkpoint-capture).
No local user workspace has been enabled, deployed or migrated by this work.

- **Private durable storage:** separate versioned SQLite index and immutable
  SHA-256 content objects under registered node state. Save/fsync each object
  before committing its manifest reference. Record exact bytes, absence and
  executable bit without rewriting Git index/refs or any source file. Reuse
  identical objects; reject unsafe links/permissions and corrupt readback.
- **Authority and ordering:** node-bound owner/workspace/session/epoch/run plus
  node-issued capture, group and operation ids. The agent supplies a file-tool
  request, never a root, owner or source blob. Postimage tokens are bound to the
  complete runner identity; repeated completion does not resample later user
  bytes. Durable run/epoch close fences and session-deletion tombstones prevent
  delayed requests from reviving ended/deleted scopes.
- **Direct-tool hooks:** capture the final guarded `write`/`edit` path after
  hooks, policy and lease acquisition. Compare an eligible edit's expected
  preimage digest before that tool writes. Capture the actual postimage after
  success/failure. A postimage failure reports incomplete protection without
  retrying the completed write; cancellation leaves an interrupted record.
- **Coverage stays honest:** every shared-directory capture is observational,
  not stable or independently attributed. Shell/PTC/team/custom tool starts add
  explicit gap records. Children, arbitrary hooks, terminals and external
  processes remain uncovered. A settled run cannot establish their quiescence.
  The generic coverage descriptor applies even if no gap event was observable.
- **Bounded reads:** descriptor-relative `NOFOLLOW` traversal, nonblocking file
  opens, physical root identity, mount/nested-repository/link/type exclusions,
  effective deny-read rules and 10 MiB/file bounds. Git ignore classification
  reuses the read-only sandbox and keeps tracked ignored-name files eligible;
  no host-Git fallback. Recheck runner authority after asynchronous classification.
- **Retention/failure:** seven-day/100-capture workspace policy, 1,000 operation
  bound, 960 MiB content plus 64 MiB metadata ceilings and metadata admission
  headroom. Startup/traffic/hourly sweeps keep active or pinned evidence. Prune
  commits before unlinking orphans; cleanup removes only known unreferenced
  private objects. Session deletion retains pinned dependencies for review.
  Quota and IO failures do not produce a successful checkpoint. Startup marks
  unfinished operations interrupted/incomplete instead of sampling a new postimage.

Validation includes the persistent
[`checkpoint_capture.rs`](../crates/pirc-node/tests/checkpoint_capture.rs) suite,
the phase-1 safety experiments, file-tool/channel tests, sandboxed Git dispatch,
real Node-store/runner RPC binding, and existing runner/session/workspace tests.
Final macOS acceptance: **133 passed, 0 failed**, with one existing ignored
runner probe left ignored (28 persistent-capture, 25 phase-1 safety, 35 agent
tool/channel, 15 Git inspector, 23 runner and 7 app tests). Focused all-target
Clippy with warnings denied, Rust/Markdown formatting and diff checks pass.
The real-node test uses only disposable non-Git files, no linked gateway,
provider, live agent or browser. Git-dispatch tests use the existing sandbox
stand-in on disposable repositories; they do not establish native OS sandbox
enforcement for a recovery workspace.

**Phase-2 boundary at delivery:** capture alone supplies observations, not trusted
reversible attribution. Direct tools still mutate from the agent process; the
preflight check is not filesystem compare-and-swap against external writers.
Phase 3 below adds independent recovery preparation and a native isolation
handoff, without upgrading this coverage label. No Nix validation is run at the
user's request. Memory lifecycle/model context integration is untouched and
stays last, after the independent memory work is published and rebased.

```sh
cargo test --locked -p pirc-node --test checkpoint_capture --test checkpoint_safety
cargo test --locked -p pirc-agent --lib tools::
cargo test --locked -p pirc-node --lib panels::inspect::tests
cargo test --locked -p pirc-node --lib runner::
cargo test --locked -p pirc-node --lib app::tests
cargo clippy --locked -p pirc-node -p pirc-agent --all-targets -- -D warnings
```

### Phase 3: independent recovery preparation and isolation

Implemented in [`recovery.rs`](../crates/pirc-node/src/checkpoints/recovery.rs),
[`snapshot.rs`](../crates/pirc-node/src/checkpoints/snapshot.rs),
[`inverse.rs`](../crates/pirc-node/src/checkpoints/inverse.rs) and
[`isolation.rs`](../crates/pirc-node/src/checkpoints/isolation.rs).
The opt-in capture service shares its journal with this trusted-node factory.
At phase-3 delivery there was **no new agent RPC, public route or client action**.
Phase 4 below adds user APIs and client actions. Preparing, claiming or
constructing a sandbox never starts/retargets a live conversation.

- **Original preservation:** read the canonical source using bounded descriptor
  traversal. Independently create private files under
  `$PIRC_STATE_DIR/checkpoints/workspaces/<node-issued-job-id>/root`; no hard
  links, `.git`, Git checkout/reset/stash/index/ref writes or source mutations.
  Reject a source containing checkpoint storage rather than creating output
  inside the original. Previously opened independent recovery roots can be
  checkpointed and recovered into fresh siblings after checking their persisted
  owner and physical identity.
  Git eligibility uses complete sandboxed `ls-files` output with no truncation
  fallback. Deny-read, links, mount crossings, nested repositories, private and
  build directories remain explicit exclusions. Output directories/files are
  created relative to held descriptors; existing entries are never overwritten.
- **Inverse and review:** a closed run's selected direct operation can be
  reversed against current bytes with `base=after, ours=current, theirs=before`.
  A standalone, clean-environment `git merge-file` uses only private scratch
  files, with time/output bounds. No source hooks/filters/scripts run. Exact
  create/delete/binary/mode handling and text conflicts preserve later changes;
  conflicted output keeps current bytes, without conflict markers. Before,
  after, current and candidate evidence remains private and retained.
  Overlapping selections on one path require a future coherent-range API and
  are refused. Observations are never relabeled as verified agent ownership.
  Applying their inverse requires explicit observational review; continuing
  unresolved paths additionally requires an explicit keep-current decision.
- **Versioned jobs:** request protocol 1 and private SQLite schema 2; unsupported
  request/schema versions fail closed. Owner/node/workspace/session/epoch/run,
  physical root, effective policy, operation selection and observed source
  revision bind the request. SQL-unique idempotency keys return the same job;
  retries never rebuild or overwrite its output. States are `preparing`, `ready`,
  `opened`, `stale`, `failed` and `interrupted`, with monotonically increasing
  confirmation revisions. Recheck source after copy, on refresh/claim and before
  sandbox preparation. Source changes invalidate continuation. Edited/replaced
  unopened outputs are preserved and require review. Restart marks unfinished
  jobs interrupted instead of exposing a partial workspace as ready.
- **Inputs, space and cleanup:** retain captures and current/candidate objects
  independently of the capture pin bit. Retention/GC and session deletion cannot
  remove referenced evidence. Missing/corrupt evidence fails readback. Defaults
  are 256 MiB/copy, 20,000 entries, 10 MiB/file, 1 GiB logical workspace
  reservations and 64 MiB free-space headroom. Reserve the whole copy ceiling
  before allocation and check free space; actual IO/ENOSPC failures fail the job.
  Filesystem overhead and outside writers mean this is not a physical allocation
  guarantee. Keep failed/interrupted outputs and their reservations/evidence;
  no automatic workspace deletion is provided, including after user edits.
  A reviewed cleanup action remains deferred; it must never use blob-GC
  recursion against a workspace that may contain later user edits.
- **Isolated execution boundary:** claiming a current job takes an account-level
  nonblocking file lock for that independently generated root and increments its
  durable generation. The unforgeable in-process ticket owns the lock through
  native sandbox cleanup, including preparation failures. Ordinary and nested
  session roots inside any registered node's recovery store are refused without
  a ticket. Rebuild current sandbox settings, carry translated source path
  restrictions to the candidate, protect the original from writes and remove
  global extra write roots/shared `/tmp` grants. Keep only the new session's
  private temp directory. macOS drops srt's default host write exceptions.
  Custom srt wrappers are refused for this isolation mode. The new workspace
  must receive a new authorized session/id and fresh content trust in phase 4;
  source memory/project-state handles are rejected and no context replay occurs.
  Source files are still observations, and this does not turn legacy shared
  workspaces into exclusive per-agent captures or provide a multi-host lock.

Validation: production acceptance tests in
[`checkpoint_recovery.rs`](../crates/pirc-node/tests/checkpoint_recovery.rs),
plus injected-copy-failure and actual external-writer tests in the factory.
Final local acceptance: **269 passed, 0 failed**, with two existing child/probe
tests left ignored (21 production recovery, 2 factory fault/concurrency,
28 capture, 25 safety experiments, 113 sandbox, 15 Git inspector, 23 runner,
7 app and 35 agent-tool tests). All-target Clippy with warnings denied,
Rust/Markdown formatting and diff whitespace checks pass.
Native macOS Seatbelt runs a real local shell: candidate edits succeed, while
source writes, checkpoint DB reads, another recovery's reads and shared-temp
writes fail. The lock survives sandbox construction and releases on cleanup;
source edits after claim refuse subsequent sandbox preparation. Sources and
complete dirty/staged/unstaged Git metadata remain intact. No provider, browser,
Android emulator or real user workspace is used.

**Remaining acceptance:** actual Linux bubblewrap execution of the new root,
real power loss/physical full disk, distributed filesystems, descendant process
escape/quiescence, and real multi-client/device continuation remain later acceptance gates.
Phase 4 below implements the Node-runner/Gateway/Web/Android continuation path. Shared directories remain observational; no new per-agent stable
capture promise is made. Memory integration remains last. Nix validation is
explicitly skipped at the user's request.

```sh
cargo test --locked -p pirc-node --test checkpoint_recovery --test checkpoint_capture --test checkpoint_safety
cargo test --locked -p pirc-node --lib checkpoints
cargo test --locked -p pirc-node --lib sandbox::
cargo test --locked -p pirc-node --lib panels::inspect::tests
cargo test --locked -p pirc-node --lib runner::
cargo test --locked -p pirc-node --lib app::tests
cargo test --locked -p pirc-agent --lib tools::
cargo clippy --locked -p pirc-node -p pirc-agent --all-targets -- -D warnings
```

### Phase 4: user operations and durable continuation

Implemented locally in Node [`api.rs`](../crates/pirc-node/src/checkpoints/api.rs)
and [`continuation.rs`](../crates/pirc-node/src/checkpoints/continuation.rs),
Gateway [`checkpoints.rs`](../crates/pirc-gateway/src/checkpoints.rs), Web's
[`CheckpointsTab.svelte`](../apps/web/src/lib/components/panel/CheckpointsTab.svelte)
and native Android's
[`checkpoints_pane.dart`](../apps/android/lib/live/checkpoints_pane.dart).

- **User API:** `/api/sessions/:id/checkpoints` lists ten captures per cursor page,
  up to 100 operations per capture (with an explicit truncation flag) and the
  twenty most recent recovery jobs. `POST /:capture/preview` accepts node-issued
  operation ids and explicit observational review; `POST /:capture/recoveries`
  binds the preview revision, version 1 and idempotency key. Select at most one
  operation per path. No arbitrary path/blob/root request is accepted.
  `GET /:capture/recoveries/:job` revalidates an unopened copy;
  `POST /:capture/recoveries/:job/continue` requires a current revision, explicit
  keep-current acknowledgment for unresolved paths and the session control lease.
  `GET /:capture/file?operation=...&side=before|after|current|candidate&job=...`
  returns bounded UTF-8 preview text (256 KiB), absent/binary/excluded/truncated
  flags, never raw binary objects or private disk paths. Job `operations` retains
  exact selected identities when one path has several recorded edits.
- **Two authorization boundaries:** Gateway and Node both check owner/session
  access; prepare and continue validate the current device control generation.
  No agent RPC or short-lived administration grant authorizes recovery. Gateway
  forwards pagination, maps Node-local continuation/origin ids to global ids and
  retains private workspace ownership across reconnection. An unknown private
  registration stays hidden until an authorized continuation reconciles it.
  Owner-scoped `checkpoints_changed` and existing runner lifecycle events refresh
  clients. Actions are disabled offline and never put in a mutation replay queue.
- **Durable adoption:** a Node transaction creates one private owned workspace
  and new blank conversation per recovery job. Persisted confirmation intent
  bridges interruption between claiming the copy and publishing that mapping.
  Repeated confirmations, including a lost response and Node/Gateway restart,
  return the existing conversation. Deleting its conversation does not delete
  files or allow a repeated continuation to resurrect that conversation. There
  is no tool, prompt, history, source trust or memory replay.
- **Actual runner path:** a new recovery conversation obtains the native
  isolation ticket at runner startup, validating its private persisted origin,
  root device/inode and account-wide writer lock. Rebuild current sandbox policy
  and retain translated original path restrictions. Adopted workspaces remain
  independent after source edits and later candidate edits are never recopied.
  Capture opt-in is inherited; disabling future capture does not strand already
  adopted workspaces. The original runner is never retargeted. Source workspace
  memory remains disabled for this path until the final memory integration.
- **Both clients:** Checkpoints is available from the existing Git/changes panel,
  including non-Git directory workspaces. List captures/coverage, select an
  observed operation, explicitly review observational limits, preview copy size
  and exclusions, prepare, compare before/agent/current/result, acknowledge
  keeping unresolved current bytes, then continue into the returned conversation.
  Existing jobs can be refreshed/reopened. Original/origin navigation survives
  reload through owner-checked list metadata. Web uses the existing code diff
  renderer; Flutter uses native code highlighting and theme widgets. English
  and Traditional Chinese strings are included. Account/re-pair/session/node
  changes fence late file/mutation responses and drop cached private previews.
- **Compatibility:** Node protocol is **14** because private recovery workspace
  registration cannot safely be silently ignored by an older Gateway. Upgrade
  Gateway and Node together; older peers fail version checks. Node main schema
  is 2002, Gateway schema is 1007 with its private owner-table migration, and checkpoint
  journal schema stays 2. Back up private state before a deliberate downgrade.

The primary UI entry is the Git/changes panel; per-message/run shortcuts and
workspace-wide cross-session filtering remain follow-ups. Safe deletion of
retained workspaces/reservations is deliberately unavailable pending its own
review: user changes must not be removed by retention, a stale confirmation or
recursive cleanup. Selection is by operation/file, not arbitrary hunks or
coherent ranges of multiple writes to the same path. Coverage remains
observational; this phase does not claim verified per-agent attribution.

Local automated acceptance covers the actual Node API/router/SQLite and native
isolation ticket, Gateway authentication/router/node relay and private ownership,
client state/components, retries, stale control, offline/re-pair fencing,
pagination and exact diff selection. Rust verification passes **554 tests**
(321 Node library, 74 checkpoint integration, 18 protocol and 141 Gateway), with
two existing Node probes left ignored. Web focused verification passes **33
tests** across five test files, Svelte type checking reports no errors/warnings,
and the production build succeeds. Native Android focused state/widget suites
pass **39 tests**, with clean Flutter analysis and matched locale catalogs;
Kotlin compilation and all **6 TimelineWire tests** pass. Focused Rust Clippy,
formatting and diff whitespace checks pass. These tests do not substitute for actual
Android device review, two live clients, Linux bubblewrap execution, physical
full-disk/power-loss or distributed-filesystem acceptance. Nix validation is
skipped at the user's request. Memory integration remains last; no memory
implementation is changed in this phase.

### Phase 5: local integrated acceptance

Local macOS acceptance completed on 2026-10-22. All services, identities,
credentials, repositories, model replies and files used by these tests are
synthetic and test-owned. No external provider, real conversation, browser,
emulator, deployment, push or Release is used. Memory implementation and the
independent memory checkout remain untouched.

The assertion-based
[`checkpoints.rs`](../crates/pirc-conformance/tests/checkpoints.rs) suite runs
real Gateway, Node and Agent executables over HTTP/WebSocket with a local model
server and the **native sandbox**. It explicitly removes the conformance
harness's unconfined fake-srt override. Unlike the historical transcript suite,
it has no Linux-only snapshots and can run on macOS. Restart helpers stop only
processes launched by their own fixture; no user browser/process is closed and
no workspace files are reseeded on restart.

| Acceptance                    | Local result                                                                                                                                                                                                                                                                                             |
| ----------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Real file tools and dirty Git | Capture the staged dirty preimage; preserve untracked files and exact Git index/ref/object bytes through preparation, adoption and subsequent execution.                                                                                                                                                 |
| Web + paired App API          | Two real authenticated clients receive owner-scoped invalidation; concurrent preparation shares one job, stale control fails, repeated continuation shares one global conversation/workspace. A concurrent retry may report `preparing`; refresh its revision before confirmation.                       |
| Four file review sides        | Before/after work without a job; current/candidate require their job. Invalid, duplicate or arbitrary-path parameters fail. Actual Gateway/Node bounded text responses match all four expected versions.                                                                                                 |
| Reconnect and restart         | SIGKILL/restart the Gateway and then Node, preserving SQLite and device tokens. Ownership, global ids, source links, continuation mapping and later user edits survive. Reacquire the invalidated control lease after Node restart.                                                                      |
| Real continuation             | The new Agent writes successfully inside the adopted recovery root through the native sandbox. The original tree stays byte-identical; later candidate edits survive. Source conversation prompts are absent from the new model requests. A second session cannot start another writer in that root.     |
| Conflict and stale source     | Changes after preview refuse preparation; changes after preparation refuse continuation. Same-hunk conflicts require keep-current acknowledgment and retain the latest user bytes. Work-mode deletion remains disallowed by its existing capability.                                                     |
| Active Node crash             | Kill while a covered write has completed and an uncovered shell is active. Restart reports an incomplete observational capture with its gap; it does not invent a completed run, new postimage or recovery job.                                                                                          |
| Factory hard crashes          | A separate test process is killed during copy, after `ready`, and after `claim`. Restart retains reservations/evidence, fences partial output, refuses edited unopened output, releases the dead writer's lock and never recreates/overwrites user-edited output. Fault hooks exist only in test builds. |
| Native review constraints     | Eight light/dark phone/tablet/landscape fixtures include 2x text and keyboard insets. Conflict acknowledgment and the final action remain scrollable and usable; reviewing never implicitly continues.                                                                                                   |

**Fixes found during acceptance:** Gateway incorrectly required `job` for every
file preview and rejected `current`/`candidate`; it now implements the same
contract as both clients and Node. Checkpoint replies, including authentication
and invalid/stale responses, now explicitly use `Cache-Control: no-store`.
Gateway router regression assertions cover the header and all four query forms.
Flutter consent/conflict checkboxes now have their own transparent Material
surface so the enclosing background cannot hide their ink/background painting
or trigger the framework's ListTile assertion.

**Verification:** 225 Rust tests pass (3 real-process native scenarios, 7 Node
checkpoint/fault tests, 74 capture/recovery/safety integrations and 141 Gateway
regressions), plus 33 Web and 47 Flutter state/widget tests. The subprocess-only
helper is excluded from ordinary discovery and is explicitly launched/killed
three times by its parent acceptance test. Flutter analysis, focused all-target
Clippy for Node/Gateway/conformance, Rust formatting and diff checks pass.
Dedicated Rust targets, test directories and disposable Flutter/Vite outputs
are removed after verification; existing APKs/history/dependency caches remain.

**Pending acceptance:**

- Android physical device: real IME show/hide, actual phone/tablet ergonomics,
  pairing, network interruption and return to the recovered conversation. Widget
  keyboard insets and paired HTTP tokens do not establish device acceptance.
- Actual Linux bubblewrap execution. The existing Linux native-sandbox CI job
  now builds the executables and runs this new suite with
  `PIRC_CONFORMANCE_REQUIRED=1` and `PIRC_CHECKPOINT_NATIVE_REQUIRED=1`; absence of
  the required native backend fails. It has not run remotely because this work
  remains local. No Nix validation is performed, per the user's instruction.
- Physical power-loss/filesystem durability, physical full-disk exhaustion and
  distributed filesystems. SIGKILL, quota limits and injected IO/copy failure
  are covered; they are not power-loss or real full-disk evidence.
- Memory integration remains last. Per-turn shortcuts, cross-session filtering,
  multi-operation ranges and reviewed disposal of retained workspaces remain
  separate product follow-ups; there is still no automatic in-place overwrite.

Reproduce using test-owned output paths (build Gateway and Node together):

```sh
cargo build --locked -p pirc-gateway -p pirc-node
PIRC_CONFORMANCE_BIN_DIR=target/debug PIRC_CONFORMANCE_REQUIRED=1 PIRC_CHECKPOINT_NATIVE_REQUIRED=1 cargo test --locked -p pirc-conformance --test checkpoints -- --test-threads=1
cargo test --locked -p pirc-node --lib checkpoints::
cargo test --locked -p pirc-node --test checkpoint_capture --test checkpoint_recovery --test checkpoint_safety
cargo test --locked -p pirc-gateway
```

Required tests include:

- Dirty tracked/staged/untracked user files, exact bytes/CRLF and executable bits.
- User edits before/during/after A; B before/after/interleaved with A; parent and
  children, direct tools, PTC, shell background processes and terminals.
- Overlapping hunks, later dependencies, re-created deleted paths, edited newly
  created files, binary/move/type collisions and excluded/sensitive files.
- Two nodes on one physical root; canonical aliases/nested roots; unsupported
  shared multi-host filesystems refuse exclusive guarantees.
- Source changes after preview, during copy and before continuation. Verify
  original bytes, index and refs remain unchanged by the recovery process,
  including when an external editor writes at the old check/rename race point.
- Repeated/opposite/stale client actions, expired preview, account re-pair and
  cross-owner ids; no arbitrary-path or agent-chosen blob restoration.
- Kill after each durable job transition, full disk, quota, missing/corrupt blob,
  cancellation, cleanup and restart; never expose partially prepared output.
- Session/project deletion, retained recovery references and blob GC. Never
  delete an opened workspace's later edits under an automatic retention policy.
- Same fixtures/results on Web and Android, phone/tablet, both themes, large
  text, keyboard/landscape and stale/offline UI. No embedded WebView.

Implementation stays local until explicitly authorized otherwise. Each phase
gets its own reviewable commit. Remove disposable test/build/copy outputs after
verification, keeping user recovery workspaces, pinned checkpoints, deliverable
APKs and necessary review artifacts.

## Memory integration acceptance (2026-10-23)

Rebased all 20 local commits onto `origin/main` at `1846dfde`, including the Rust
handoff/repository-memory port and its hardening. No deployment or push. The
independent memory checkout was not modified.

- Memory RPCs (`workspace.*`, `history.*`) and checkpoint RPCs retain their
  separate Node-local handlers. Recovery retains a new blank conversation;
  its own history/handoff machinery works, while repository-memory authority
  remains disabled for the recovery root. It neither replays source memory nor
  writes facts from the recovery into the original repository ledger. Enabling
  an independent recovery ledger would require a separate product decision.
- Gateway schema is now **1008**: upstream memory digest 1006, calendar 1007,
  private recovery owners 1008. Transactional upgrade also recognizes the
  unpublished local 1006 calendar and 1007 checkpoint layouts, preserves their
  data/ownership, and adds the missing digest. Reopening is idempotent.
- Android now renders the handoff summary, legacy archive, pending mutations
  and repository-memory errors. Both clients keep repository errors visible
  when legacy OM is disabled but repository memory is independently enabled.
  New strings have English and Traditional Chinese catalogs.
- Nix `cargoHash` is recalculated from the merged lockfile and 348 checksum-verified
  crate archives. The original TLS commit’s staging NAR hash was reproduced
  exactly before calculating the new value. This is not a Nix build validation;
  Nix validation remains waived by the user. TLS distrust dependency versions
  and rejection tests remain intact.
- Native checkpoint process scenarios now explicitly enable the new memory
  features. Restart, conflicting edits, cross-device continuation and owner
  isolation still pass. The Node scope regression denies direct recovery
  `workspace.*` authority while permitting its own-session history scope.

Local acceptance: 1,107 Rust workspace library/binary tests (3 ignored, including
one crash helper explicitly invoked by its parent), 74 checkpoint file-safety
integration tests, 3 TLS rejection/control tests, 32 distinct real-process
memory/checkpoint scenarios, 19 Web tests and 34 Flutter tests. Full-workspace
Clippy, Svelte type checking and Flutter analysis pass. The side-channel run
transcript uses a fixture-private temp parent so macOS’s fake-srt warning does
not change the Linux golden event count; no golden snapshots were updated.

Disposable outputs are removed after verification. Existing ledgers are not
activated, cold-cut over or migrated by running tests; the deployed memory
activation procedure remains an operator action. Actual Android testing remains
with the user; Linux runtime and Nix builds are not claimed by this macOS run.

## Proposed defaults for review

- Opt-in per workspace initially; show coverage before enabling capture.
- All original and later user changes are retained; default result is a new
  workspace. Automatic in-place publication is outside this first release.
- Completed run/turn is the user-facing checkpoint unit; per-tool versions are
  internal evidence. Shared teams are groups unless actor attribution is proven.
- Require isolated execution for independently recoverable parallel agents.
- No Git-history/index rewriting, external API/database/deployment rollback,
  system-wide backup or recovery of pre-feature history. Existing history has
  no retroactively invented checkpoints.
- Retention/quotas above are proposed defaults, with explicit disk reservation
  and visible suspension when protection cannot be maintained.

### 2026-10-23 memory integration regression follow-up (local only)

- Cold cutover now conservatively refuses busy or starting peer runners without
  waiting on either the runner manager or peer lifecycle mutex. A deterministic
  two-runner barrier test holds both lifecycle locks concurrently, confirms both
  requests reject, then confirms activation succeeds after the peer stops.
- Repository history scanning uses an evicting request-local branch cache and
  retains fingerprints after eviction. A 69 MiB, three-session fixture verifies
  cold cutover, independent extraction/commits, context, clear, and rejection of
  a concurrent change to an evicted source. Routine context requests read only
  authorized headers for control metadata; boundary capture is explicit.
- Web/Android show an additive repository write-activation status, independently
  of the legacy OM switch. Manual sync/catchup before activation reports the
  required stopped-writer cutover, not a successful zero-result extraction.
- Native checkpoint continuation still reports repository memory disabled and
  rejects its authority, while preserving source workspaces and later writes.

Acceptance on macOS: **1,110** workspace Rust library/binary tests passed
(three existing subprocess helper tests remain ignored), **74** checkpoint
integration tests, **15** real-process memory/handoff/checkpoint tests,
**14** Web tests and **30** Flutter widget/state/catalog tests. Workspace
all-target Clippy with warnings denied, Svelte checking, Flutter analysis,
formatting and diff checks passed. Existing APKs are preserved; this follow-up
requires no new database migration, protocol bump, deployment or remote push.
Per-file journal and extraction limits remain; aggregate history no longer has
an artificial 64 MiB request failure. Android hardware and Linux runtime were
not re-tested in this local follow-up; Nix validation remains waived.
