# Upgrades

## Local checkpoint: Gateway Node-fence receipt reconciliation

Gateway schema **1027** adds a minimal retained record of a Node that has already
accepted a resource-bound admission fence. Reconciliation sends only a Node GET,
validates the frozen plan/source/target/Node intent and current device/access, then
records a digest and blocks new ordinary/first-message dispatch for that session.
Existing command receipts, Stop, control takeover and unrelated sessions remain
available. A missing or offline receipt creates no accepted record; an existing
fence is retained through offline/unknown replies and target/preview deletion.

The record holds owner/operation/session IDs, an intent digest, state and creation
time. It stores no Node response body, private Node session ID, paths, history,
attachments or memory. Canonical session deletion closes the record as a minimal
tombstone. Accepted operation IDs cannot be reused after their preview disappears.

Node remains **2019**, protocol/client/private-envelope stay **15/2/3**. There are
no lockfile, dependency, Nix hash or package-version changes. Before eventual
deployment, back up consistent Gateway state; older Gateway binaries refuse 1027,
and rollback requires a matching state/binary backup. No deployment is authorized.
This is recovery of an already-accepted Node fact; initial Gateway acceptance
before remote effects, full revocation and replacement installation remain open.
See the [receipt reconciliation checkpoint](../../plans/unified-conversations.md#u4-implementation-checkpoint-gateway-node-fence-receipt-reconciliation-2026-11-04).

## Local checkpoint: resource-bound transition admission

Node schema **2019** is a semantic upgrade for durable execution-fence intents
that optionally contain a target workspace ID and the reviewed Node evidence hash.
Before first acceptance, Node re-observes the source/target and activity under the
same database transaction as the fence insert. Changed evidence rejects the
request without a fence; an identical retry returns its retained receipt.

The upgrade performs no SQL reshaping or resource allocation. Legacy intents
remain readable without inventing proofs. Older Node binaries refuse 2019, since
their strict receipt decoder cannot read the new optional intent property. Before
eventual deployment, back up consistent Node state and retain its matching binary;
rollback requires that backup, not lowering `user_version`. Gateway stays 1026,
protocol/client/private-envelope stay 15/2/3, and versions/dependencies/Nix hashes
are unchanged. The work remains local; no deployment is implied.

Gateway preview observations now expose the opaque `nodeEvidenceHash` alongside
the Node runner epoch, bound into the Gateway observation hash. Neither is a
grant. Node capability `resourceFenceVersion: 1` identifies checked admission;
legacy fence requests remain admission-only. All receipts still explicitly deny
full revocation and replacement installation, and public switching remains gated.
See the [resource-bound admission checkpoint](../../plans/unified-conversations.md#u4-implementation-checkpoint-resource-bound-node-admission-2026-11-04).

## Local checkpoint: durable transition previews

Gateway schema **1026** stores owner-scoped immutable environment review snapshots.
Repeated preparation and lookup recover the same intent; changed policy is reported
as stale. Previewing performs only Node capability reads, never fences a session,
allocates folders, changes bindings or starts work. Paired-device HTTP can query
this state directly. Confirmation remains disabled until resource preflight,
revocation and replacement installation are implemented.

Source-session or target-workspace deletion removes these review snapshots. No
accepted-message, attachment, memory or task retention changes. Node remains
2018; protocol/client/private-envelope remain 15/2/3. Package/dependency versions
and Nix hashes are unchanged. This update is local only. Before eventual
deployment, back up consistent Gateway state; older binaries refuse 1026 and
rollback requires a matching backup rather than editing the version or tables.
See the [preview checkpoint](../../plans/unified-conversations.md#u4-implementation-checkpoint-durable-gateway-transition-previews-2026-10-28)
for validation scope and remaining work.

## Local checkpoint: page-owned engine and network admission

A managed page now passes its original resource authority to background engine
initialization and intercepted network requests. Popup/iframe/dedicated-worker
initialization, DNS-delayed HTTP decisions, authentication and WebSocket-mock
verdicts cannot start a new guarded effect after that authority is revoked.
Cleanup can refuse a paused request or cancel authentication without closing a
peer conversation's shared connection. A page cannot be rebound to a different
resource owner.

This adds no schema or deployment migration. It is local-only code and does not
enable workspace switching or first-Send activation. Shared context/unowned
resources and established connections still require separate containment; see the
[page-resource checkpoint](../../plans/unified-conversations.md#u4-implementation-checkpoint-page-owned-engine-and-network-admission-2026-10-28)
for the exact validation scope and remaining limits.

## Local checkpoint: browser resource and recorder retirement

Browser background display/capture and recording writes now retain their
original environment authority independently of the viewer or Agent that started
them. A transition fence stops new guarded effects and retires quiet tabs; other
conversations in the shared workspace browser remain available. Ordinary
controller takeover or Agent turn completion does not stop an authorized recording.

Recorder shutdown now retains an independent child-exit observer even if its
caller disconnects or drops the stop request. Encoding errors remain visible but
do not by themselves mean the encoder is still running; an unconfirmed exit
continues to block confirmed close. Already-buffered data may flush before exit.
No claim is made about complete Chromium network/worker containment or arbitrary
descendants/descriptors. Public switching and U1 activation remain disabled.

This slice is local only. It changes no schema, dependency, package version or Nix
hash, and does not deploy or activate existing transitions. See the
[resource checkpoint](../../plans/unified-conversations.md#u4-implementation-checkpoint-browser-resource-guards-and-recorder-retirement-2026-10-28)
for validation scope and remaining work.

## Unreleased checkpoint: foreground browser admission

Browser actions now retain the original controller or Agent epoch/cancellation
identity through queued work and CDP writes. A takeover, disconnected viewer,
transition fence or changed environment can reject a later command in an action.
The original authority error is returned; the request is not automatically replayed.
An action may already have performed earlier commands, which are not rolled back.
A frame already started on the shared CDP pipe finishes intact; only later frames
are refused. Other conversations continue using that pipe.

This is foreground command admission, not complete browser process, background
network/worker, screencast or recording retirement. Existing uncertain-close
handling still applies. Public workspace switching and U1 activation remain
closed. No schema, dependency, package version or Nix hash changes are included
(Node 2018 / Gateway 1025 / protocol-client-envelope 15/2/3). See the
[implementation evidence and remaining limits](../../plans/unified-conversations.md#u4-implementation-checkpoint-foreground-browser-effect-admission-2026-10-28).

## Unreleased checkpoint: browser supervision

Node schema **2018** retains browser group identity and close observations.
Back up matching binaries and private state before migration. Older binaries
reject this schema; changing the version or deleting the evidence is not a
rollback. Gateway remains 1025; protocol/client/private envelope remain 15/2/3.

Close can now return `browser_stop_unconfirmed` when the engine did not confirm
page/context closure, cleanup timed out, or the result could not be saved. Session
deletion preserves its data and transition drain reports blocked. A Node crash
with an active group retains uncertainty: a fresh process with no live browser
entries does not prove the old resources stopped. New browser work for that
session is refused until safe reconciliation is implemented; no automatic
replay, forced clearing or manual PID signaling is supported.

Only pirc-owned resources are closed. Other sessions sharing the workspace
context remain independent. An old request interrupted by a context crash now
fails with a conflict instead of recreating an untracked tab; a fresh request may
open a registered tab. The journal stores original session/workspace/root,
incarnation and outcome/timestamps, not URLs, input, cookies or credentials.

These observations are not OS-wide browser containment or per-CDP-effect
revocation. Historical coverage and revocation/installation flags remain false.
Public environment switching and U1 activation remain disabled. See the
[implementation checkpoint](../../plans/unified-conversations.md#u4-implementation-checkpoint-durable-browser-supervision-2026-10-28).

## Unreleased local checkpoint: terminal supervision

Node schema **2017** adds a minimal retained panel-terminal journal. Preserve a
matching binary/state backup; older binaries reject this schema, and rewriting
its version or deleting evidence is not a rollback or reconciliation method.
Gateway remains 1025 and protocol/client/private envelope stay 15/2/3; there are
no package, dependency or Nix hash changes.

A close request hides the panel immediately, but the closing shell retains its
quota until its observer records the result. At the four-per-session limit,
wait for that settlement before opening another terminal. Stop signaling and
reaping share one observer, so a delayed signal is not sent after its child has
already been reaped. Shutdown joins bounded observers instead of discarding them.

Interrupted prior launches or failed result persistence can produce
`terminal_stop_unconfirmed`. Session deletion keeps its files, and environment
transition drain reports `blocked`; a new Node with no live terminal entries does
not erase this uncertainty. No automatic replay, saved-PID signaling or manual
force-clear is supported. Saved records retain only original session/workspace,
root, Node incarnation and outcome/times, not terminal input/output or credentials.
They remain after session deletion for reconciliation.

`terminals.observersSettled` covers the direct shell, not every detached or
foreground job or writable file descriptor. Old terminals have no inventory;
`historyComplete`, `revocationConfirmed` and `targetInstalled` remain false, and
public switching remains disabled. See the
[implementation checkpoint](../../plans/unified-conversations.md#u4-implementation-checkpoint-durable-terminal-supervision-2026-10-28).

## Unreleased local checkpoint: memory cutover admission

That checkpoint introduced no new schema or wire format (Node **2016**). Cold repository-memory
initialization now refuses unresolved local host-command ranges, including its
own session's jobs and orphaned owners, and retains admission through the durable
journal append. Pre-cutover legacy tail repair also retains admission; checked
append never repairs implicitly. `journal_repair_required` requires the explicit
writer-open/recovery path after stopping writers. Host startup does not wait on a
busy memory lifecycle lock while
holding DB; it returns `host_admission_busy` before spawning. Retry after that
state operation finishes. The operator must still stop untracked/other-Node
writers and explicitly request cutover. No ledger is activated by deployment.
See [memory activation](../architecture/observational-memory.md#activation-status-and-large-histories)
and the [implementation checkpoint](../../plans/unified-conversations.md#u4-implementation-checkpoint-memory-cutover-host-exclusion-2026-10-28).

## Unreleased local checkpoint: host write-resource retention

Node schema **2016** adds immutable resource snapshots to the approved host-command
journal. Each new reservation atomically records the original session execution
root and its currently held write ranges before spawn. This is cooperative
Node-local write coordination, not cross-Node exclusion, a sandbox permission
grant or a complete inventory of
files arbitrary host code can touch. Paths are private coordination metadata in
the Node database (0600), retained with the minimal execution record after session
or workspace deletion; commands, outputs and conversation contents are not copied.

Agent settlement and runner exit no longer discard those frozen ranges. Pending
host observations block overlapping peer writes and new host admissions, including
across distinct workspace IDs with nested canonical roots. A current live supervisor
may share ranges only with its own session/epoch/Node incarnation. A new epoch,
a previous Node incarnation, an unconfirmed outcome, or a failed outcome write
cannot inherit that exemption. Independent known nonoverlapping ranges continue.
Workspace-removal preflight and activity include orphaned pending host owners;
an unreadable inventory is not published as an empty activity frame.

Upgrade from 2015 does not infer old paths from today's workspace configuration.
A pending legacy command without a resource snapshot, or an invalid snapshot,
blocks cooperative write grants globally with `host_write_pending`. Reads and
inference remain available. No automatic replay, guessed PID signaling, manual
force-clear or supported reconciliation override is introduced. Preserve the
journal and matching binary/state backup; do not erase it or rewrite the schema
version to force progress or downgrade.

A settled direct-child/output observation releases this cooperative claim; it
still does **not** prove detached descendants, ambient filesystem access or every
previous write capability stopped. Full host containment, alias/descriptor-safe
authority, memory cold-cutover exclusion for arbitrary host code and restart
reconciliation remain U4 work. `historyComplete`, `revocationConfirmed` and
`targetInstalled` stay false; public switching and U1 activation remain disabled.
Gateway stays 1025; protocol/client/private-envelope formats remain 15/2/3. No
package version, lockfile or Nix dependency changes are needed. See the
[resource-retention checkpoint](../../plans/unified-conversations.md#u4-implementation-checkpoint-host-write-resource-retention-2026-10-28).

## Unreleased local checkpoint: supervised approved host commands

Node schema **2015** adds a minimal durable host-command journal. Older binaries
refuse this schema; preserve a consistent matching binary/state backup for any
eventual deployment or rollback. Do not delete records or rewrite the schema
version to force a downgrade. No Gateway, protocol/client contract, package,
dependency or Nix hash changes accompany it.

After approval, Node rechecks the runner's original environment before spawning
under the admission locks. Stop, deletion, mode replacement, transition drain and
shutdown request cancellation and join the Node-owned observer. Losing the caller
does not discard that observer; a repeated admitted request does not execute again.

A command interrupted across Node restart may leave `launching`, `running` or
`unconfirmed` evidence. Those entries do not authorize replay or numeric-PID
signals. Affected Stop/drain attempts return `host_stop_unconfirmed`; manually
confirming cleanup is not yet an exposed reconciliation workflow. Do not remove
the record to claim a completed environment switch. Already-settled observations
remain settled, and peers with no unresolved command keep their ordinary behavior.
Records retain only origin/state/time identifiers, not command bodies, outputs or
credentials, including after session deletion.

`hostCommands.observersSettled` does not certify all detached descendants exited.
Pre-2015 commands lack an inventory, so `historyComplete` remains false even when
all new records settled. Full revocation/target-installation flags remain false
and public environment switching stays disabled. This local work does not deploy
or enable the new first-Send flow. See the [implementation checkpoint](../../plans/unified-conversations.md#u4-implementation-checkpoint-supervised-host-commands-2026-10-28).

## Unreleased local checkpoint: guarded native Linux runner startup

Node schema **2014** adds a one-way launch gate record: `waiting` can become
`released` or `denied`, never be reset. Existing launches migrate as `untracked`;
no historical execution gains a guard retroactively. Gateway stays 1025 and no
protocol, client contract, package version, dependency lock or Nix hash changes.

Native Linux runner starts now wait for a captured, live kernel identity. Node
persists that identity and release decision, rechecks the session/epoch/workspace
and transition fence, then sends one small nonblocking permission record on the
private stdin pipe while holding the admission lock. The trusted bridge consumes
only that record before starting its proxy threads or Agent. EOF, a partial or
invalid record, timeout, missing identity or storage failure does not start Agent
work; no RPC is sent before release. Failed starts close the pipe and stop the
captured scope/wrapper. The guard flag is removed from the Agent's environment.
Pre-launch loader/shell hooks (such as forwarded `LD_PRELOAD`, `LD_LIBRARY_PATH`,
`BASH_ENV` or `ENV`) are refused rather than executed before the gate. If needed,
configure the tools' environment in Agent config, loaded after guarded startup.

This deliberately fails native Linux runner startup if the host cannot supply
pidfd/namespace identity evidence; it does not silently fall back to an untracked
launch. Native Linux runtime acceptance remains required before deployment.
Existing macOS/srt session paths and read-only panel commands retain their current
behavior and are not covered by this gate.

After interruption, a transition drain permanently denies still-waiting gates in
batches of 64. `guardedNotReleased` is separate evidence that no permission was
sent; it does not establish kernel exit and does not subtract from `unresolved`.
A release decision may have committed just before the Node died without delivering
its byte; keep it conservative and reconcile the already-saved kernel identity.
Never replay that permission into a replacement process. All full-transition
completion flags remain false; terminals, approved host commands, browser effects,
macOS containment and replacement-policy installation are still open.

Older Nodes refuse schema 2014. Preserve consistent matching binary/state backups
for an eventual deployment; do not edit the version or erase launch records to
force a downgrade. This work remains local and exposes no public workspace switch.

## Unreleased local checkpoint: durable sandbox launch evidence

Node schema **2013** records each runner launch before spawning it, keyed by
session, workspace, runner epoch and Node process incarnation. Only a failed
spawn establishes `not_started`; missing observation never establishes that a
sandbox stopped. Existing sessions with earlier runner epochs receive an explicit
`legacy_untracked` entry. Migration does not fence ordinary sessions or change
conversation history, checkpoints, memory origins or attachment access.

On native Linux, a captured identity includes boot ID, observer PID namespace,
sandbox namespace, PID and process start time. Reconciliation runs only inside an
accepted transition fence, with at most 64 identities per drain and four checks
at once. Repeating a drain continues the saved work. A fresh pidfd must be validated
against the original identity before signaling. Another boot/PID view, inaccessible
identity, an untracked backend or a launch without captured identity stays
unconfirmed. A wrapper exit or an empty live-runner map is not enough.

Internal transition receipts expose counts in `sandboxProcesses` and continue to
report `revocationConfirmed: false`, `targetInstalled: false`. This journal covers
recorded runner launches, not terminals, approved host commands, browser effects
or complete workspace revocation. The gap between spawning and durable identity
capture still needs a guarded launch handshake. Linux runtime acceptance and
macOS descendant containment also remain open. No workspace-switch UI is enabled.

The journal retains minimal launch evidence across conversation deletion; it holds
no conversation text, file content, model output or credentials. Do not remove
rows to make a transition appear complete. Older Node binaries refuse schema
2013; eventual rollback requires a consistent matching binary/state backup.
Gateway schema 1025, protocol 15, client contract 2, package versions, dependency
locks and Nix hashes are unchanged. This checkpoint stays local.

## Unreleased local checkpoint: transition admission fences

Node schema **2012** adds immutable execution-fence identities and durable stop
receipts. Gateway stays **1025**. Migration does not fence historical sessions.
Existing public APIs continue to use their ordinary environment until a trusted
coordinator explicitly accepts a transition. The new routes are internal to the
Node link; no public Gateway switch or UI is enabled in this checkpoint.

An accepted operation blocks new execution admission and persists across restarts.
Retries with the same intent query/rejoin that operation. A changed plan conflicts;
control/status, Stop and deletion remain available subject to existing ownership
and mode checks. Do not clear a pending row or edit its plan to force progress.
There is deliberately no release/regrant API before replacement-policy installation
and acknowledgement are implemented. Delete follows its existing destructive
semantics; it is not a substitute for a non-destructive transition recovery flow.

Local drain handling now starts independent resource cleanup together: an unresolved host command or waiting runner cannot prevent terminal/browser stop attempts. It still waits for every participant and retains uncertainty; clearing a journal is not recovery. A canceled request does not cancel the owned drain. This is a behavior-only change, with no schema migration.

`supervisor_drained` records tracked supervisor shutdown only. Every response still
says `revocationConfirmed: false`, `targetInstalled: false`; never treat it as a
ready environment. OS descendants/descriptors, pending effects, crash recovery and
actual target installation need the remaining U4 implementation. A reply timeout
does not cancel the tracked stop work or automatically restore old access.

Older Node binaries refuse schema 2012. Before eventual deployment, retain a
consistent matching binary/state backup. Do not decrement the schema version or
remove fence records to downgrade. Package versions, dependency locks, protocol,
client contracts and Nix hashes are unchanged. This slice stays local; native
revocation and deployment/rollback acceptance remain outstanding.

## Unreleased local checkpoint: saved attachment provenance

Node schema **2011** atomically records immutable origins for new uploads. Gateway
stays **1025**. Historical rows keep their existing workspace/owner and first-send
conversation restrictions; migration does not infer source Node/mode or change
attachment ownership. Existing upload deletion removes its provenance too.

The new authenticated attachment-reference route exposes safe metadata directly
through Gateway for browsers and paired devices. It does not serve bytes or grant
access. Older Nodes may return not found; that is not permission to infer metadata
or retry on another Node. The updated Gateway checks source workspace and current
binding after the reply, and does not expose private Node paths/session IDs.

When the Agent consumes an attachment, the stored file must match its saved size
and SHA-256 and cannot be a symlink. Missing/changed bytes return
`attachment_storage_unavailable`. A rejected input stays rejected on receipt
replay; repair storage before making a separate explicit new attempt. Existing
workspace copies preserve later user edits and remain distinct from saved bytes.

Older Node binaries refuse schema 2011. Before eventual deployment, back up
consistent state and retain the matching binary/state pair. Never decrement the
schema version or delete provenance metadata to downgrade. No Gateway migration,
protocol, client contract, package version, dependency lock or Nix hash changes.
This local checkpoint does not enable first Send, mounts, workspace switching or
new grants. Physical Android and deployment/rollback acceptance remain open.

## Unreleased local checkpoint: Node command authority rechecks

Node schema **2010** adds immutable command-origin metadata. Gateway stays **1025**.
Migrations do not assign current environments to historical commands. Updated
Web/Android commands require the new Node capability; Gateway checks it on the
same connection used for dispatch and revalidates control/environment afterwards.
Upgrade Node before using the matching clients. Older Nodes produce a clear
upgrade-required rejection; clients retain their input rather than retrying.

Node consults Gateway after its local queue/startup waits and before branch-file
mutation, checking the saved origin and current control. Missing authority or a
changed environment rejects the command without sending that RPC. Rejected
receipts and their origins survive restart. Stop keeps the existing control checks
without requiring this round trip. Legacy commands at unchanged generation 1 and
internal deliveries retain their existing admission rules.

This extends the Gateway-only checkpoint below; it is still **not full revocation**.
There is no atomic lease over future Agent effects, sandbox installation acknowledgement,
or fencing of queued tools/approvals. `enforcement: not_tracked` and production
`canSubmit: false` remain. No mount/workspace switching or new grant is enabled.

Older Node binaries refuse schema 2010. Back up consistent state and retain the
matching binary/state pair before eventual deployment; do not edit schema versions
or drop metadata to downgrade. Protocol 15, client contract 2, package versions,
dependency locks and Nix hashes are unchanged. This is local-only work, with Android
OS/device and deployment acceptance still outstanding.

## Unreleased local checkpoint: captured command environments

Gateway schema **1025** stores an immutable environment binding with newly admitted
ordinary commands. Migration leaves historical origins unknown. Web and Android
now send the binding visible when an action began, retaining it across settings,
uploads and native queueing. Results are queried/read without redispatch.

An unchanged legacy binding (membership revision 1, execution generation 1) still
accepts old clients. After a configured mode/capability/association change, clients
must include the current expected binding: stale values receive `stale_environment`,
missing values `environment_required` (HTTP 409). This is a deliberate compatibility
boundary: deploy matching Web/Android clients before changing such environments.
An updated client must refresh then initiate the action again; no automatic intent
upgrade or resend. Stop remains available under current ownership and control.

At this earlier checkpoint this was **Gateway admission only** (extended above): Node queues/approvals/tools and running sandbox
resources are not yet fenced by these versions, including a change between admission
and Node execution. Environment reads still report `enforcement: not_tracked`.
No workspace switching, new grants or first-send activation is exposed.

Older binaries refuse schema 1025. For an eventual deployment, back up consistent
state and retain a matching binary/state rollback pair; do not edit schema versions
or drop metadata to downgrade. Node schema 2009, protocol 15 and client contract 2
are unchanged. This checkpoint is local only; Android OS/device and deployment
acceptance remain outstanding.

## Unreleased local checkpoint: project memory cleanup receipts

Gateway schema **1024** adds content-free project memory completion receipts and
member cleanup scopes. It does not backfill receipts for partially deleted projects.
Such projects require review once before the new receipt commits. New deletions
classify recorded version/proposal origins independently of current membership.
Legacy/unknown origins require explicit review; there is no inferred reassignment.

The Web/Android confirmation sends `memoryReviewVersion: 1` and supports unknown
proposal Keep/Forget choices. Older clients remain compatible for fully known
origins but cannot confirm unknown-origin cleanup. Once the memory phase commits,
retry/restart resumes removal without reapplying it to later user edits. Standalone
chat deletions overlapping this operation retain its project cleanup semantics.

Older binaries refuse schema 1024. Back up a consistent complete state before an
eventual deployment; rollback uses a matching binary/state pair. Node schema 2009,
protocol 15, first-send client contract 2 and private envelope 3 are unchanged.
`canSubmit: false` remains. No supported project move, mount transition, new grant,
APK, deployment or Release is enabled by this local checkpoint.

## Unreleased local checkpoint: frozen memory origins

Gateway schema **1023** adds private origin snapshots for new global-memory
versions and proposals. Existing text, creator attribution, history and public
response formats stay unchanged; old rows are not backfilled from current project
membership. Approval/restore retain the original source snapshot. Forget, proposal
redaction and version deletion remove snapshots with their corresponding data.

A memory operation whose Gateway-validated environment changed before the write
transaction is refused with `stale_environment`. This is not the complete Node
generation fence and does not enable project moves. The schema 1024 checkpoint above integrates these origins into project deletion;
actual mount transitions remain a separate gate.

Older Gateway binaries refuse schema 1023. An eventual upgrade still requires a
consistent state backup and a matching binary/state rollback pair. Node schema
**2009**, protocol **15**, client contract **2**, private envelope **3** and the
production `canSubmit: false` gate remain unchanged. No deployment, Release, APK
or device acceptance is claimed by this local slice.

## Unreleased local checkpoint: configured environment policy

Gateway schema **1022** adds explicit conversation project membership and immutable
mode/workspace-capability policy histories. Migration preserves conversation IDs,
existing data and control/runner state. The first validated catalog resolves old
project associations without inventing historical transitions. An unavailable mode
retains its last known project reference, but never grants access from that record.

Catalog reload and capability patches append policy revisions atomically; affected
execution generations advance. Failed persistence retains the previous catalog and
policy. The new owner-scoped `/api/sessions/{id}/environment` read works with paired
Android and offline Nodes. Its `enforcement: "not_tracked"` explicitly does not prove
installed sandbox policy. No supported workspace switch or new mount grant is added.

Older Gateway binaries refuse schema 1022. Before an eventual deployment, take a
consistent complete state backup; policy snapshots are part of that state. Rollback
requires the matching binary/state pair, not deleting tables or editing user_version.
Do not run old Gateway binaries against migrated data. Deployment/rollback and
Android OS/device verification remain open. Node schema **2009**, protocol **15**,
first-send contract **2**, client envelope **3** and `canSubmit: false` are unchanged.
No dependency, package version, Nix hash or Release change is part of this slice.

## Unreleased local checkpoint: conversation binding identities

Gateway schema **1021** adds identity-only conversation bindings and backfills them
atomically from existing session/workspace mappings. Public conversation IDs,
private Node IDs, histories, ownership, memory provenance and checkpoint isolation
are preserved. Membership revision and execution generation are separate from
runner epochs and control leases. Inconsistent historical workspace references
refuse migration with the original state preserved, rather than dropping history.

Session lists/snapshots include an additive `binding.version: 1` descriptor. Web
and native Android preserve it; older server responses without it remain readable.
The descriptor represents the legacy association, not Node acknowledgement of new
sandbox policy. No workspace move, mount grant, command replay or U1 activation is
introduced. Node schema **2009**, protocol **15**, first-send client contract **2**,
private draft envelope **3**, package/dependency versions and Nix hashes are unchanged.

Older Gateway binaries refuse schema 1021. Deployment remains unperformed: take a
consistent full state backup and stop older Gateway processes before a later
upgrade. Rollback needs the matching binary/state pair; do not edit the version or
delete bindings to downgrade. Android OS/device and actual rolling-deployment
acceptance remain open. Production **`canSubmit: false`** remains in place.

## Unreleased local checkpoint: first-send Node connection fencing

Gateway now rechecks reliable-first-send capabilities before materialization and
initial admission, and requires the full workflow plus retry support for a new
retry. Capability evidence belongs to one registered Node connection. Allocation,
attachment transfer, admission and retry cannot carry it across a reconnect,
even when the replacement uses the same Node ID and protocol number.

An unsupported Node leaves the original accepted input/files pending. A known
connection change after probing is refused before command reservation; if an
attempt was already reserved when the connection changes, keep its outcome
uncertain and query it without replay. Check, Stop and authorized deletion retain
their existing paths. Explicit blank release after confirmed Stop does not upload
the original files. Web/Android show readable compatibility/reconnection errors.

Gateway **1020**, Node **2009**, protocol **15**, client contract **2**, private
client envelope **3**, dependency versions and Nix hashes are unchanged. Production
**`canSubmit: false`** remains; this is neither activation nor deployment. Unit
fault tests and current-binary client/checkpoint regressions pass. Historical
mixed-version deployment, rollout/rollback and Android OS/device acceptance remain
open; do not downgrade state or discard unresolved drafts to bypass the gate.

## Unreleased local checkpoint: client interrupted-retry recovery

Web and native Android now adopt the Gateway **1020** retirement proof via
**Recover interrupted retry**. Current Node **2009**, protocol **15**, client
contract **2**, Web IndexedDB/private envelope **3**, package/dependency versions
and Nix hashes remain unchanged. Production **`canSubmit: false`** is unchanged.

Checking is still read-only. Explicit recovery refreshes capability/account and
ordinary held control, then retires only the saved nonce against its exact rejected
predecessor. It does not submit a message; another Retry needs a separate user
action and enabled Send. A reserved unknown command cannot be retired or retried.
Lost responses/local writes resolve only through matching durable GET evidence.
Older Gateways without the capability cannot expose this action; existing Stop,
query and authorized deletion remain available. Older clients may inspect but do
not understand retirement proof, so keep their unresolved drafts for an updated
client rather than editing local status. Do not downgrade Gateway state from 1020.

Original input/files, Stop/delete fences, seven-day unaccepted staging expiry,
memory provenance and checkpoint isolation are preserved. Focused client and
synthetic browser/private-filesystem tests pass; full live-client/backend,
Android OS/device and activation/rollback acceptance remain open. No rollout,
APK, deployment or Release is performed.

## Unreleased local checkpoint: retiring an unreserved first-message retry

Gateway schema **1020** adds identity-only retry retirement tombstones. Node
**2009**, protocol **15**, client recovery contract **2**, Web IndexedDB/native
private envelope **3**, dependency versions and Nix hashes are unchanged. Older
Gateways refuse schema 1020; before deployment stop the old processes and back up
complete consistent Gateway/Node state. Rollback requires matching binaries and
full state, never editing SQLite versions or discarding retirement records.

A client may commit a retry nonce locally and crash before its POST reaches the
Gateway. A GET 404 alone still cannot prove that a delayed request will not arrive.
The new owner-scoped `POST .../retries/{retryId}/retire`, advertised by
`canRetireFirstMessageRetry`, atomically retires an unreserved nonce only with a
confirmed current rejected predecessor and the user’s held control. It neither
creates a command nor contacts Node or a model. Retired nonce GETs return explicit
`status: not_reserved, retired: true` with the nonce/predecessor identity; any late
Retry POST using that nonce is permanently refused. This does not consume an
attempt number or replace the original conversation/input/files.

If reservation won the race, retirement only returns/reconciles that existing
command; it cannot undo an execution, clear Stop or turn unknown admission into
known rejection. Repeating a completed retirement is read-only, including after
lease expiry, restart or authorized conversation deletion. The identity-only
tombstone survives content deletion just like the existing dispatch fences.
New retirement checks device authorization inside the transaction.

**At this backend checkpoint client adoption was pending; the newer checkpoint
above adds it.** Older
clients remain query-only for an unresolved nonce. Production **`canSubmit: false`**
is unchanged; this backend addition is not activation. Seven-day expiry remains
limited to unaccepted Gateway staging. No deployment, APK or release is included.

## Unreleased local checkpoint: Web/native first-message Retry adoption

Gateway **1019**, Node **2009**, protocol 15 and client contract 2 are unchanged.
The existing Web/Android recovery controls now adopt the explicit Retry API; the
production rollout still has **`canSubmit: false`**, so this does not enable a new
send path for deployed users. No APK or release assets are built here.

Web IndexedDB (same database name) is now **3**; Android private metadata envelope
is **3**. Rows, logical revisions, account bindings and attachment bytes migrate
without replacement; native imports validated envelopes 1/2 under its existing
lock. Old Web/native writers refuse the newer format. An older binary must not
write newer state. Preserve a consistent full private-state/browser-profile backup
if an installation rollback is required; never edit version fields or discard
unresolved drafts as a downgrade shortcut. Future formats remain read/write refused.

Retry keeps the original conversation/input/files, journals its nonce/predecessor
before POST and requires current capability/grants/control. Pending retries only
query their own nonce/result after a lost reply or restart; an absent nonce is not
permission to resend. Only the explicit Gateway `initial_retry_unsupported` refusal
proves reservation did not occur and permits a later user Retry after Node repair.
Global Stop and deletion are independent of any attempt's admission outcome.
Seven-day expiry continues to cover only unaccepted Gateway staging.

Focused Web/native-JVM/Flutter and isolated browser-storage proofs pass. Full live
client-to-backend, Android OS/process-death/device, pre-POST crash repair and rollout/
rollback acceptance remain required before activation. Shared SDKs/caches and APKs
are preserved; only run-owned test output is removed. No deployment is performed.

## Unreleased local checkpoint: Gateway first-message retries

Gateway schema **1019** adds durable retry nonce/predecessor/command history and
monotonic attempt numbers. Node remains **2009**, protocol **15**, client contract
**2**, package/dependency versions and Nix hashes stay unchanged. Older Gateways
refuse 1019. Before a future upgrade, stop old processes and take consistent full
Gateway/Node state backups; rollback needs matching state/binaries, never an edited
SQLite version or an old Gateway DB paired with newer attempted work.

The new explicit Retry API uses the same accepted input, conversation and files.
It requires a confirmed rejected predecessor, unchanged grants/mapping/model and
held control, and checks Node retry support before reservation. Every new attempt
commits before relay. Duplicate requests and owner-scoped nonce GETs only read/
reconcile; unknown outcomes never trigger a new POST or a fresh identity.
`messageAdmission` exposes `commandId`, `retryId`, `attemptNumber` and
`retryEligible` for clients to order updates reliably.

A retry that never reached Node can still reconcile the original operation's
confirmed global Stop without claiming its earlier admission is known. Staging
files remain retained until known admission or authorized deletion; the seven-day
rule still applies only to unaccepted staging. Existing memory deletion consent,
checkpoint isolation and ordinary session APIs are unchanged.

**At this backend checkpoint Web/native Android had not adopted Retry; the newer
client checkpoint above adds it. Production `canSubmit: false` remains unchanged.** Backend synthetic tests and paired direct-HTTP process proof
are separate from actual native-client/device acceptance. No deployment, APK or
release asset is included.

## Unreleased local checkpoint: Node rejected-admission retries

Node schema **2009** adds immutable first-message attempt/predecessor identities
and backfills existing initial command/hash metadata. Gateway remains **1018**;
protocol **15**, package/dependency versions and Nix hashes are unchanged.
Stop the old Node and take a complete consistent state backup before a future
upgrade. Older Nodes refuse 2009; restore matching full state and binaries for
rollback, never change SQLite `user_version` to force it.

The new trusted Node API permits an explicit fresh command only after its exact
current predecessor is durably rejected, with identical input/model/files and
valid current mode/control. It reuses the same session and attachments. Attempts
in progress, accepted, unknown or stopped cannot be replaced. Duplicate retries
and historical lookups read receipts only; restart never replays unacknowledged
work. Stop/deletion still fence the whole original first-message operation.

**Gateway/Web/Android have not adopted this retry API yet.** Existing App behavior
and production `canSubmit: false` stay unchanged. The real Node/Agent test proves
a known pre-message startup failure, repair/restart and one persisted user message;
it is not blanket permission to reopen an uncertain/corrupt journal. Complete
client-to-Gateway/Node and device acceptance remain open. No deployment, APK or
release asset is included.

## Unreleased local checkpoint: unsent edit recovery

Web/Android preserve a stale editor's text/settings/selected file bytes as an
explicit separate local draft when a peer changes or freezes its source operation.
The **Unsent edits** entry must be opened and reviewed, then explicitly sent;
recovery and navigation perform no preparation, admission or dispatch. Repeated
recovery respects the copy's revision too; another writer's copy is never replaced.
Unchanged input adopts the newer facts without creating a duplicate draft.

Web's common navigation paths wait for persistence and keep the current input
when saving fails. The native `recover` draft action uses the existing bound
origin/account and private file lock; it verifies bytes and commits independently.
Missing/corrupt bytes refuse the copy rather than claiming success. This does not
add a grant or require a Web connection. Explicit copy discard is independent of
source conversation/memory deletion; private drafts keep their existing lifetime.

Gateway 1018 / Node 2008, protocol 15, recovery contract 2 and private storage
versions stay unchanged. The optional local `recoveredFrom` identity is not part
of server/model input. **Production `canSubmit: false` remains unchanged.** Real
client-to-Agent, Android process-death and cleanup-race acceptance remain open.
No migration deployment, APK or release asset is included.

## Unreleased local checkpoint: first-send client compatibility

Gateway schema **1018** adds a semantic downgrade fence; no tables change.
Node schema **2008**, protocol **15**, package versions and dependencies stay
unchanged. Back up the complete Gateway state before any future upgrade.
Older Gateways refuse 1018; rollback requires matching binaries and the full
matching backup, never an edited SQLite `user_version`.

The first-send API remains wire version 1, with a separate client recovery
contract: `x-pirc-first-send-contract: 2`. Capabilities return `clientContract`
and `requiredClientContract: 2`. Missing, old, future or duplicate header values
cannot activate new sends; Prepare/Accept/Materialize/Dispatch reject them with
`409 first_send_client_upgrade_required`. This header grants no authority.
Queries, Stop and deletion retain their account, control and consent checks;
ordinary legacy session APIs keep their existing compatibility.

Modern clients recheck support before executable Send work. A bound modern
operation cannot fall back to legacy creation after successful old capabilities,
missing endpoints or incompatible versions. Original input/files stay retained;
query-only uncertain/terminal outcomes do not require sending again. Explicitly
unsupported cold legacy connections keep the previous flow without exposing
private recovery. Web ignores stale failed capability probes after newer binding.

The same Web IndexedDB name upgrades from version 1 to **2**, retaining rows,
Blobs and Stop identity. Close old pirc tabs if they block the upgrade; version-1
code then refuses to open the newer store. Android private envelope **2** imports
version-1 records after scope/path validation under the existing lock; logical
revision and attachment bytes stay unchanged. Older native code refuses version 2;
unknown future formats are refused without rewriting them. Use a compatible
client for recovery. Do not clear App storage, IndexedDB or uncertain drafts to
force a downgrade; that destroys the private recovery copy.

**Production `canSubmit: false` remains in effect.** Local process, browser-storage,
Web and focused native/Flutter checks are distinct from complete client-to-Agent
and Android device/process-death acceptance, which remain open. No deployment,
APK, release asset or new authentication/connection scheme is included. The
seven-day cleanup rule still applies only to unaccepted Gateway staging, not
accepted attachments or private drafts.

## Unreleased local checkpoint: client pending Stop adoption

Web/native Android/Flutter now support the Gateway's pre-allocation Stop scope
and explicit blank continuation. Gateway 1017 / Node 2008, protocol 15, dependency
and package versions are unchanged. **`canSubmit: false` remains in effect.**

The local Stop identity prevents a late original send from continuing. Native
private metadata/IndexedDB retain the pending control identity and original
input/files. Checking results never acquires control or replays a mutation;
explicit retry uses its saved identity, and takeover stays explicit. `nodeMapped`
separates mapping from stopped/stopping status. Open after confirmed unmapped
Stop prepares blank storage under current grants before navigation, retaining
frozen input. Deleted operations cannot be reopened through stale Stop flags.

Known admission, Stop and mapping facts merge independently across late replies.
Stop does not undo completed effects or resolve unknown earlier admission. The
recovery labels make that distinction visible in English/Traditional Chinese.
This preserves the existing separate accepted-delete and memory warning flow.

Mixed/older-client activation and rollback remain required gates before enabling
new sends; the global version-1 flag must not activate clients that cannot honor
local Stop/recovery metadata. Local tests are separate from a real native
client-to-Gateway/Node/device acceptance pass. No emulator, APK, deployment,
release asset or new login/connection scheme is included.

## Unreleased local checkpoint: Gateway queued pre-allocation Stop

Gateway schema **1017** adds pending-input Stop control and durable Stop jobs;
Node schema **2008**, protocol 15, package versions and dependencies are unchanged.
Back up Gateway state before any future upgrade; older Gateway binaries refuse 1017. Rollback needs the full matching backup rather than an edited `user_version`.

The new operation control scope is `pending_first_send_stop`, valid for 30 seconds
and usable only before a Node mapping exists. It cannot authorize Node commands.
Mapping races require the existing Node control/Stop flow. Once authorized, the
job survives offline periods, Gateway restart and initiating-device revocation;
only a validated Node acknowledgement confirms Stop. New first-send acceptance
requires the Node's `canStopBeforeAllocation` capability; older Nodes are refused
before intent/session publication. Existing accepted operations may still show
pending/unsupported until their Node supports the fence.

Explicit materialization after confirmed Stop may prepare the same blank
conversation under current grants. It never replays the original input or
promotes the stopped input's files; text/staged bytes remain retained and Delete
keeps its existing separate authorization and memory cleanup. `nodeMapped` tells
clients whether mapping is known independently of the Stop phase.

Web/Android adoption and full U1 client/device acceptance are not complete.
**`canSubmit: false` remains in effect**. No deployment, release asset, UI redesign
or new device connection scheme is included.

## Unreleased local checkpoint: Node pre-allocation Stop foundation

Node schema **2008** adds a durable first-message Stop that may precede Node
session allocation. Gateway schema 1016, protocol 15, dependency locks and
package versions are unchanged. Back up Node state before a future upgrade;
older Node binaries refuse schema 2008. Rollback requires the matching full
backup rather than changing SQLite `user_version`.

This Node-only API grants no new client control. Gateway durable Stop queuing,
fresh control authorization and Web/Android integration are still required;
**`canSubmit: false` remains in effect**. Existing client behavior is unchanged.
Stop records no message text, creates no session/files and deletes no history,
attachment or memory. A late allocation can prepare blank storage while the
original first message stays fenced. Stop after initial command intake must
use the existing leased session Stop; the pre-admission endpoint cannot claim
that it terminated execution. Duplicate pre-admission Stops never abort later
user work. Delete keeps its separate authorization and cleanup semantics.

Local Node/loopback process checks cover this foundation; this is not complete
App or production acceptance. No deployment or published asset is changed.

## Unreleased local checkpoint: Flutter durable first-send wiring

Flutter includes controller and recovery UI wiring for the native first-send
engine. **Gateway still returns `canSubmit: false`** until the remaining
integration/permission/restart gates pass. This is not production activation or
a release. Database, node-link, dependency and version identifiers are unchanged.

With support negotiated, private drafts/files survive navigation and reopen
under the same origin/owner. Storage refusal blocks sending/leaving instead of
falling back to legacy creation. Check result queries only; Continue, Take
control and Stop require their own user actions. The original message remains
frozen until known admission or confirmed Stop. Sidebar recovery and original
input are collapsed by default; ordinary messages keep their existing renderer.

Discard and accepted conversation deletion stay distinct. Native cancel requires
explicit accepted-delete consent, including if acceptance raced a stale Discard
button; that deletion uses the ordinary Gateway owner/mode checks and existing
memory warning. There is no new deletion permission. Before admission, approval
mode uses the workspace default; this slice adds no per-message permission mode.

Unknown cold capability support blocks new creation until it can be checked.
Explicitly unsupported/gated legacy servers keep their documented behavior;
reserved durable operations never use that fallback. Authenticated pending
recovery is still queryable when new sends are disabled. A bound offline draft
remains editable; cold recovery waits for authenticated capabilities and does
not erase private bytes. Unaccepted Gateway staging alone expires after seven
days; private drafts and accepted files are not covered by that deadline.

Focused Flutter/native JVM checks pass locally; a real Android process-death and
client-to-Gateway/Node/Agent pass remain required. No emulator, device or Nix
verification was performed, and no APK or release asset was replaced.

## Unreleased local checkpoint: native first-send engine

Android includes a native durable submission engine behind new methods on its
existing Gateway bridge. Flutter has **not** adopted those methods yet; Gateway
still returns **`canSubmit: false`**. Existing App behavior is unchanged. There
is no database, node-link, dependency, version or Nix-hash change in this slice.

The engine stores private drafts and attachment bytes in `noBackupFilesDir`,
scoped by the Gateway origin and authenticated owner. It requires an authenticated
capability response before cold recovery and validates the current pairing stamp
for every operation. Local edits need no network round trip after that binding.
Changing pairings hides access without repurposing another owner's draft; signing
back into the same owner/origin can recover it. Clearing App storage or uninstalling
removes this local recovery copy, so do not use either to resolve uncertain sends.

The native path freezes/persists the original operation before preparation,
queries unknown outcomes without replay, and keeps explicit Stop, Take control,
draft discard and conversation deletion separate. Paired tokens connect directly
to Gateway with the expected-account fence; no Web page or management grant is
needed. Requests do not follow redirects or automatically replay mutation bodies.
The seven-day expiry still covers only unaccepted Gateway staging, not accepted
attachments or private native drafts.

Only focused native JVM/filesystem/local-HTTP and Web regression checks ran here.
Flutter adoption, Android process-death/device checks and the full multi-client
integration matrix remain required before activation. This local checkpoint is
not a deployment instruction or a completed Android-flow guarantee.

## Unreleased local checkpoint: negotiated Web first-send recovery

Web includes private durable drafts and pending-send recovery, but Gateway still
returns **`canSubmit: false`** until Android adoption and the complete recovery
matrix pass. This checkpoint does not enable the new production client flow.
Gateway schema 1016, Node schema 2007 and protocol 15 are unchanged, as are
lockfiles and Nix cargo hashes. Unsupported/gated servers retain the existing
client flow; an operation already reserved for durable sending never silently
falls back after a local storage failure.

Authenticated capabilities add `ownerUser`, `canFenceAccount` and
`canFindPendingSession`. New durable requests send optional `x-pirc-account`
containing encodeURIComponent(owner); mismatch with the current authenticated
identity returns `409 account_changed` before mutation. Preparation also accepts
optional `expectedOwner` with the same check. Legacy clients need neither field.
An older strict server rejects the new preparation body rather than retargeting
an old-account draft. Read-only pending lookup by public session ID is owner
scoped and does not allocate, take control or replay input.

The new Web path requires working IndexedDB and successful local transaction
commits before sending. Cold recovery requires authenticated capability discovery
for that same Gateway origin/account. Do not clear site storage to resolve an
unknown outcome: it may hold the only unaccepted draft/attachment bytes. Check
result only queries; Continue and taking control require explicit user actions.
The seven-day policy applies to unaccepted Gateway staging, not accepted files
or private browser drafts. Browser/profile deletion remains outside that policy.

This is local implementation/verification work, not a deployment instruction or
a completed end-to-end Web/Android guarantee. No Nix or Android-device validation
was performed for this slice.

## Unreleased local checkpoint: cancellation before Node mapping

Gateway schema **1016** and Node schema **2007** add durable remote cleanup jobs
and Node creation-cancellation tombstones. Back up both state directories before
upgrading; old executables refuse these schemas. Do not downgrade by changing
`user_version`. Protocol 15 is unchanged, but new intent acceptance requires
Node's `canCancelCreation: true` capability as well as the earlier admission/file
capabilities. Upgrade compatible Nodes first. Dependencies/lockfile/Nix cargo
hashes are unchanged.

For accepted-first-send conversations, authorized Delete can commit while the
Node is offline or its allocation response/mapping is missing. **202** means the
conversation is deletion-fenced and cleanup is pending; **204** means remote
cleanup has been confirmed. Gateway retries that identity-scoped job after
restart/reconnect without a Web page or a fresh device/management grant. Outcome
reads report `cleanupPending` and optional `cleanupError`; they do not replay a
message or initiate allocation/cleanup. Existing owner/mode permission checks for
fresh Delete still apply. Stop and unaccepted-draft discard keep separate meanings.

Node cancellation can precede creation and permanently blocks delayed allocation,
transfer and initial admission. Ready-session cleanup uses the existing shutdown,
checkpoint retention and session/upload deletion flow. Unexpected reserved files
or an unavailable mode/storage/checkpoint stay pending; do not erase an unexpected
path to force success. User workspace roots are retained. Gateway verifies the
original operation/workspace/hash and any known Node session mapping before
finishing source-aware memory deletion and retiring the job. Migrations also
queue previously cancelled accepted operations with their original identities.

This checkpoint stays local. **`canSubmit: false` remains** until Web/Android
persistent draft/reconnect/deleting-state handling and multi-client gates pass.
It is not a completed client-flow guarantee or a deployment instruction.

## Unreleased local checkpoint: first-message admission and Stop

Gateway schema **1015** and Node schema **2006** add durable first-command
bindings, outcome reconciliation and a Stop fence. Back up both state directories
before upgrading; older executables refuse these schemas. Do not downgrade by
changing `user_version`. Protocol 15 is unchanged, but the new first-send flow
requires Node's `canAdmitFirstMessage` and `canReadFirstMessageReceipt` capabilities
as well as the earlier attachment capabilities. Upgrade compatible Nodes first.
No dependencies, lockfile or Nix cargo hash changed in this checkpoint.

The internal dispatch route commits one command identity before sending fixed
model/thinking/text/files. Duplicate requests reconcile its receipt; outcome
queries do not start runners, acquire/renew control or replay a prompt. Lost
acknowledgements/restarts before confirmation remain uncertain. Stop records a
fence against delayed original sends, including before runner startup; it does
not undo completed effects. Only known admission or confirmed Stop releases the
pending-input gate for an explicitly new command. Ordinary command receipts also
have an owner-scoped read endpoint; deletion hides their contents.

After known admission, Gateway cleans staging sources while Node retains
session-bound attachments. The seven-day deadline still applies only to
**unaccepted** staging. Accepted pending input is not silently expired. Existing
session IDs, allocation/upload identities, memory provenance and checkpoint
recovery isolation are preserved. New initial `received` commands become unknown
at Node startup; legacy `received` behavior is unchanged.

This is a local implementation checkpoint. **`canSubmit: false` remains** until
uncertain-allocation cancellation and Web/Android recovery are wired and verified.
It is not a deployment instruction or completed end-to-end client guarantee.

## Unreleased local checkpoint: accepted first-message intents

Gateway schema **1014** adds durable acceptance and Node materialization records.
Back up Gateway state before upgrading; old executables refuse this schema. Node
schema 2005 and protocol 15 are unchanged. Gateway requires Node's
`attachmentMimeInQuery: true` capability and refuses older Nodes before
acceptance. Upgrade compatible Nodes before enabling the future client flow.
Raw octet transport and immutable MIME metadata keep JSON files out of the
Node's legacy JSON body parser. Existing session IDs, Node mappings,
control, memory provenance and checkpoint recovery data are preserved. Do not
change `user_version` to downgrade.

The internal accept route commits a validated first-message intent and one public
pending session together. Materialization reconciles the same Node allocation
and attachment-transfer IDs. Neither route admits an Agent message, acquires
control or executes a model/tool. Clients remain on the old flow behind
**`canSubmit: false`** until the remaining admission/client gates are implemented.

Accepted staging no longer has the seven-day unaccepted deadline. Its bytes and
pending input remain recoverable until delivery cleanup or authorized deletion.
Conversation/project deletion scrubs content/settings and queues file cleanup;
non-destructive Work removal preserves accepted pending history behind the
removal fence. Explicit restore can resume the original operation. Unaccepted
staging/draft cleanup keeps its previous policy. This checkpoint stays local and
is not a deployment instruction or a completed first-send guarantee.

## Unreleased local checkpoint: Node attachment transfer

Node schema **2005** adds owner/creation-scoped attachment transfer records. Back
up Node state before upgrading; old executables refuse the migrated database.
Existing sessions, legacy uploads, allocation identities, memory provenance and
checkpoint recovery data are preserved. Gateway schema 1013 and protocol 15 stay
unchanged. Do not downgrade by changing `user_version`.

The new Node-only capability and `PUT`/`GET` attachment routes under
`/api/session-creations/` reserve one upload ID before file work and reconcile
lost responses, partial writes and restarts. New uploads are session-bound;
legacy upload scope is unchanged. Session deletion cleans reserved/ready files
and scrubs metadata while retaining a non-reusable identity. Missing/corrupt
acknowledged files produce an error instead of silently replaying the upload.

Gateway/client adoption is still gated with **`canSubmit: false`**. This is local
foundation work, not a deployment instruction or a completed first-send flow.
Future integration must detect unsupported Nodes and fail closed. The seven-day
unaccepted Gateway staging policy does not expire accepted Node attachments.

## Unreleased local checkpoint: attachment staging

Gateway schema **1013** adds owner-scoped attachment receipts, expiry and durable
cleanup jobs to the 1012 preparation ledger. Back up Gateway state before
upgrading; old Gateways refuse the migrated database. Node schema 2004 and
protocol 15 are unchanged. No existing accepted attachment is migrated or expired.

New unaccepted files are stored under `PIRC_STATE_DIR/submission-staging/`, with
private directories/files. They expire seven days after the latest manifest-valid
upload attempt, as selected by the user. The deadline is stored before file work
so a crash without a receipt cannot leave an untracked file indefinitely. Status
reads do not extend the deadline. Expiry retains pending text/manifest/operation
identity for recovery; uploading the same content can restage the same operation.

Cancellation/deletion queues file cleanup transactionally. Startup and periodic
workers remove only known staging files; status remains `cleanupPending` until
cleanup is complete. Unknown files or links block that operation's cleanup,
without deleting their contents. Do not place user files in the staging directory.
The new backend supports staging but still reports **`canSubmit: false`**: Node
promotion/admission and client adoption remain incomplete. Existing clients keep
their current upload path. This local checkpoint does not authorize deployment.

## Unreleased local checkpoint: Gateway first-send preparation

Gateway schema **1012** adds durable owner-scoped first-send preparation and
cancellation fences. Back up Gateway state before upgrading. Older Gateways
refuse the migrated database; do not downgrade by changing `user_version`.
Existing sessions, Node mappings, history, leases, memory and checkpoint recovery
ownership are preserved. Node schema **2004** and protocol **15** are unchanged
by this Gateway checkpoint.

This local intermediate stage reserves identities and stores pending input, but
creates no ordinary session or command and starts no Agent. The new capability
route reports `canPrepare: true, canSubmit: false`; existing Web/Android continue
their current flow. Preparation is not acceptance, Node admission or execution.
Attachment contents, acceptance, delivery and client recovery still need their
remaining U1 gates before activation. Cancellation and workspace/session deletion
remove the payload while retaining its non-reusable operation identity; existing
[backup and WAL limits](backup-and-recovery.md) still apply.

## Unreleased: Node session creation ledger

Node schema **2004** adds durable, owner-scoped creation identities. Back up Node
state before upgrading; older executables refuse the migrated schema. Existing
sessions and workspace identities, memory, uploads, checkpoint data and pots
records are unchanged. Do not downgrade by changing `user_version`.

This is a local first-send foundation, not a deployment instruction or a complete
client workflow. The new Node-only `POST /api/session-creations` and
`GET /api/session-creations/:id` routes allocate/reconcile a session but do not
send a message or start an agent. Gateway and clients do not use them yet. The
allocation ledger stores only identifiers, a submission hash and creation state;
it survives deletion so old retries cannot recreate a deleted conversation.
`deleting` is distinct from `deleted`; neither allows reallocation.

The Node link envelope remains protocol **15**, with additive HTTP routes. The
existing pots requirement to upgrade compatible Gateway/Nodes together still
applies. Future first-send integration must detect an unsupported route and fail
closed; it must not silently use legacy non-idempotent creation. Existing session
commands and specialized schedule/delegation/checkpoint/pots flows are unchanged.
See the [implementation checkpoint](../../plans/unified-conversations.md#u1-implementation-checkpoint-node-allocation-2026-10-26).

## Unreleased: explicit pots execution

Back up both Gateway and Node state before upgrading. Gateway schema **1011**
fences the extended task lifecycle (the existing pots SQL tables are unchanged);
Node schema **2003** adds durable dispatch identities, immutable instructions and
send/control fences. Older executables refuse the migrated schemas. Node protocol
**15** requires updating Gateway and every Node together; do not mix protocol 14
and 15. Update Web/Android clients to expose explicit instruction-based Start.

This is a local implementation checkpoint, not a deployment instruction. Start
requires an enabled responsibility, resumed coordination, remaining dispatch and
concurrency budgets, current source evidence and a written user instruction. It
uses a new dedicated conversation in the same workspace, never answers the source
interaction, and does not enable autonomous dispatch. Unknown sends are not
automatically retried. See [pots](../guides/pots.md).

## 0.10.0: pots tracking and gateway schema 1010

This release adds an opt-in, progress-only **pirc pots** inbox. Back
up Gateway state before upgrading: schema **1010** adds durable responsibilities,
sourced suggestions and tracking tasks. Older Gateways refuse the newer schema;
installing an older executable does not reverse the migration. Existing sessions,
workspaces, removal markers, memory and schedules are retained. No existing user
is enrolled in observation and no execution grant is created by the migration.

Update the Gateway and client assets together when deploying this checkpoint.
Node schema and node protocol are unchanged. The extracted LLM libraries keep
the existing authenticated Node → Gateway inference route; project agents do not
receive provider credentials. Production agents now drive their existing run
through the generic loop, retaining host-owned policy, storage and notifications. See [pots](../guides/pots.md) for tracking-only controls and the explicit
execution-unavailable boundary. This change does not authorize a deployment.

## TLS trust update: October 2026

The Rust gateway's outbound HTTPS and the node's `wss://` connection use
Rustls with `rustls-platform-verifier`. On macOS, it delegates certificate
trust evaluation to Security.framework and Apple's current trust policy. On
Linux, it discovers the host CA bundle and WebPKI validates certificate paths
against those roots. Keep the operating system's trust data current as well as
the pirc dependencies.

The October 2026 eMudhra incident led to [RUSTSEC-2026-0382](https://rustsec.org/advisories/RUSTSEC-2026-0382.html),
which covers acceptance of paths through distrusted emSign intermediates, and
[RUSTSEC-2026-0383](https://rustsec.org/advisories/RUSTSEC-2026-0383.html),
which covers the bundled roots that allowed such paths. This update locks the
patched releases `rustls-webpki` 0.103.16 and `webpki-root-certs` 1.0.10. See
the [incident report](https://emudhra.we-have-a-problem.com/) for the CA event.
Build from the updated lockfile (`nix build .#pirc-gateway .#pirc-node` from
the pirc checkout, or use your deployment's equivalent builder), then replace
and restart the gateway and every chat and coding node, including remote nodes;
a reload does not replace the running TLS verifier.

On NixOS, the pirc repository's pinned flake inputs control its build and
development environment, while the running host's Linux CA bundle comes from
the host's NixOS generation. Updating the project flake alone does not refresh
that host bundle; update and verify the host's CA package and trust policy
separately. External tools such as `gh`, `git`, `curl` and Python have their
own TLS implementations and CA bundles; update them separately. Variables such
as `SSL_CERT_FILE` only affect clients that honor them; see the [sandbox `gh`
setup](sandbox-and-browser.md#https-with-a-token). The Android app uses its
separate OkHttp and Android trust path; this Rust dependency update does not
change it.

The offline regression test is
`cargo test --locked -p pirc-providers --test tls_distrust`. It explicitly trusts
the legacy fixture roots and requires the twelve public incident chains,
including AAA cross-signs, to fail with `CertDistrusted` at a fixed time within
their validity periods. A valid local test CA must still pass. On Linux this
also exercises the platform verifier; on macOS and Windows it exercises WebPKI
rather than the native OS trust service. This test does not validate the
deployed host's CA updates or any external command-line tool's trust store.

## Work workspace removal: gateway schema 1009

This update adds non-destructive **Remove workspace…** under a Work workspace’s Settings in the web app. Back up gateway state before upgrading: schema **1009** adds durable removal markers, and older gateways refuse the new schema. Deploy the updated gateway, web assets and coding nodes together. The node protocol and node schema are unchanged, but removal requires the new node idle-check endpoint; an older node fails closed without removing the workspace.

Removal retains files and history, pauses schedules and survives node reconnects. Restoring an eligible directory through **Add workspace** requires the updated node’s same-path restoration support. Per-session workspaces and configured paths outside the device home currently have no UI restore; read the confirmation and [workspace removal guide](../guides/session-ui.md#removing-a-work-workspace-web) before removing them.

## 0.9.3: memory, calendar and checkpoints

Upgrade the Gateway and every chat/coding Node together: **node protocol 14**
adds private checkpoint workspace registration. Mixed protocol versions are
refused. Back up both Gateway and Node state directories before upgrading;
these migrations are not reversible by installing an older binary.

The Gateway migrates to **schema 1008**: 1006 records memory digests, 1007 adds
calendar events, grants, proposals and reminders, and 1008 adds private recovery
workspace ownership. Earlier local preview databases that used 1006 for calendar
or 1007 for checkpoints are recognized and brought to the same schema without
removing schedules, events or recovery ownership. Nodes migrate to **schema 2002**
for checkpoint workspace/session adoption. Older binaries refuse the new schemas.

Repository memory now has a versioned journal separate from session handoffs.
Legacy records remain readable; existing ledgers stay read-only until explicit
cold activation with all older writers stopped. Deploying these binaries does
not activate memory automatically. Review [memory activation](../architecture/observational-memory.md)
and the panel's activation status before synchronizing. Isolated recovery
sessions do not inherit the source workspace's memory or enable its writers.

The calendar adds user-owned events, recurrence exceptions, independent Agent
grants, confirmation proposals and reminder delivery attempts. Existing schedules
and runs remain intact; legacy run origins remain unknown. See
[Calendar](../guides/calendar.md) for behavior and limits. Checkpoint recovery
creates a separate workspace and requires review before continuing; it does not
restore files into the original directory or undo external side effects.

The TLS rebuild/restart and host trust-store instructions above also apply to
0.9.3.

## 0.9.0 / 0.9.1: mode tabs by capability, delegation approval, node protocol 13, gateway schema 1005

Upgrade the gateway and every node together: the node protocol moves to 13
because the mode catalog the gateway sends no longer has `ui.group`. Protocol 12
nodes are refused by the new gateway and protocol 13 nodes by an older one.

On first start the gateway migrates its database from schema 1000–1004 to 1005:
`delegations` gains `dispatch`, `origins_json`, `quote` and `quote_entry_ids`,
and delegations that already started are marked `dispatch='approved'`. A 0.8.x
gateway refuses a database at schema 1005: back up its state directory if you may
need to roll back. Node schemas are unchanged; nodes gain the gateway-only
`relayed-answer` route that relayed delegation approvals need. Every chat
workspace keeps `delegation_approval: always` (the approval card) until you
change it.

**Breaking: remove `group:` from every mode file before upgrading.** Clients now
place a mode's workspaces by its `assistant` capability (`full`: Chat, `user`:
Work), so `ui.group` was removed. Mode files reject unknown fields: a file that
still contains `group:` is skipped with a warning naming it, and its workspaces
become unavailable (history readable, no new work) until you delete the line
and reload the gateway (SIGHUP). This includes the default `chat.md` and
`directory.md` the gateway created earlier and read-only directories provided
by Nix. Compare with `pirc-gateway modes --print-defaults`.

`GET /api/nodes` lists each node's accepted mode ids (`modes`). Web and Android
clients ask capabilities instead of the legacy `kind`, which stays in workspace
JSON for one more release.

## 0.8.0: gateway-owned workspace modes, node protocol 12

Upgrade the gateway and every node together. Protocol 11 nodes are refused by
the new gateway and protocol 12 nodes by an older gateway; the close reason
explicitly asks for a coordinated upgrade. Database schemas remain gateway
1004 / node 2001: the existing `workspaces.kind` text column now stores mode
ids without a data migration.

On first start the gateway creates `$PIRC_CONFIG_DIR/modes/chat.md` and
`directory.md` **only if the modes directory does not exist**. Existing
installs keep the same default behavior. If you provision a read-only config
directory (for example with Nix), provide the modes directory and both default
files yourself, or make its parent writable for initial creation. An existing
empty directory deliberately disables all modes; invalid files are skipped,
not replaced with defaults. Use `pirc-gateway modes --print-defaults` to inspect
the shipped files before upgrading.

Nodes default to accepting `chat` on `pirc-node chat`, `directory` otherwise.
Custom modes require `PIRC_MODES` on each intended node and a gateway mode file.
Nodes receive definitions only from the gateway; agents receive validated
`PIRC_MODE` JSON. Retired `PIRC_WORKSPACE_KIND` is refused by agents. SIGHUP
reloads modes as well as models; changed/removed modes stop affected agents,
close their terminals and cancel inference. Missing modes keep existing
session history readable but refuse new work. Changing workdir strategy does
not migrate data; incompatible existing layouts are refused.

Back up configuration as well as state before upgrading. Older executables
cannot understand custom mode ids safely: restore reviewed default mode ids
and matching configuration/state before downgrading. Do not run old binaries
against a store containing custom ids; old parsers silently treated unknown
ids as directory workspaces. No deployment or data rewrite is automatic.

See [Workspace modes](../guides/modes.md) for format, permissions and examples.

## 0.6.0: gateway schema 1004, node schema 2001, node protocol 11

Upgrade the gateway and every node together: the node protocol moves to 11, and
the gateway closes a node on protocol 10 (the node exits asking for the
upgrade). On first start the gateway migrates its database from schema
1000–1003 to 1004 (the `workspace_deletions` table, a `workspace_id` in
`session_deletions`, and a `scope_id` in `memory_tombstones`; existing
tombstones become `global`, so forgotten text stays refused), and each node its
store from 2000 to 2001 (an upload's
`workspace_id`/`session_id`, and `workspace_deletions`). Uploads made before the
upgrade record no workspace: they can still be attached anywhere and are not
deleted with a chat project. From 0.6.0 both migrate under one write lock
in a single transaction, so a failed step leaves the database at its old
schema.

A 0.5.x gateway refuses a database at schema 1004, and a 0.5.x node one at 2001. Back up both state directories before upgrading if you may need to roll
back.

## 0.5.0: gateway schema 1003 (node protocol 10)

An in-place upgrade. On its first start the gateway migrates its database from
schema 1000, 1001 or 1002 to 1003 by itself, one transaction per step: 1001 adds the
`repo` columns of workspaces and mirrored workspace memory, 1002 the
`project_links` table (chat projects linked to workspaces), 1003 the
`operation` of schedule proposals (agents' deletions wait for you), the
`as_user_request` of delegations and an index on `delegations(follows)`. Node state is
unchanged and the node protocol stays 10, so nodes and gateway still
interoperate across the upgrade, but deploy them together as usual: an older
node reports no repositories, an older gateway gives coding sessions no USER
entries, and an older node's agent refuses `delegate` without a workspace before
asking the gateway. Upgrade every node with the gateway: an older node does not
offer the approval-mode switch (the web hides it) and refuses the command.

Node configs using `features.autoMode.enabled` keep working with a warning;
replace it with `features.autoMode.mode` (`enabled: false` now means
`"full-access"`, `true` means `"auto"`). A repository's `.pirc/config.json`
that sets `defaultModel` is ignored until you trust it again in the workspace's
Settings.

On Linux nodes, sessions no longer reach Unix sockets on the host other than
the node's inference socket and the Nix daemon's: add any a session needs (an
`ssh-agent`, a database, a container engine) to
`sandbox.network.allowUnixSockets`. Leftover `<key>.lock` files beside
workspace-memory ledgers can be deleted.

A 0.4.x gateway refuses a database at schema 1001, 1002 or 1003 ("newer than this
gateway"). Back up the gateway's state directory before upgrading if you may
need to roll back; restoring that backup loses what changed since.

## 0.4.0: fresh-start Rust cutover (node protocol 10)

This is a **breaking release**, not an in-place database migration. The server
executables are now native Rust: `pirc-gateway` and `pirc-node`. The chat service
runs **`pirc-node chat`**; there is no `pirc-chat` binary or package. Web and Android
API behaviour remains compatible; shared timeline fixtures are unchanged.

The Rust gateway/node refuse TS-era SQLite schemas. Do **not** copy the old
`gateway.sqlite`, node databases, `sessions/*/session.jsonl`, `backends/settings.json`
or `vapid.json` into the new state directory, even though some filenames and
formats resemble the old ones. Do not point `PIRC_DATABASE_PATH` at an old DB.

### Maintenance-window checklist

1. Build and validate the new release (`bun run check`; Nix: `nix build .#pirc-gateway .#pirc-node`).
2. Stop the gateway and **all** chat/coding nodes. Take a consistent, protected
   backup of each old state directory and keep the old release alongside it.
3. Select new, empty `PIRC_STATE_DIR` directories for the gateway and each node.
   For the NixOS module, set a new `services.pirc.stateDirectory`, for example
   `/var/lib/pirc-rust`. The module does not delete or migrate old state.
4. Preserve only reviewed configuration: identity/Host/Origin allowlists,
   proxy settings, file-managed `models.json`, workspace paths and agent prompts/
   skills. Recreate node credentials or deliberately provision matching tokens
   on both ends. Keep gateway and node accounts separate and secrets out of Nix.
5. Change chat launch commands to `pirc-node chat`; coding remains `pirc-node`.
   Remove `PIRC_CHAT`, `PIRC_PLAYWRIGHT_CORE`, and production `PIRC_SANDBOX_SRT`
   overrides. Install `bwrap` on Linux (`pirc-node`'s Nix wrapper supplies it),
   `git`, and Chromium/Chrome plus optional ffmpeg. No Bun/Node/srt is needed.
6. Nix users: remove `pirc-chat` package references and `services.pirc.chatPackage`;
   use `nodePackage` for both roles. `services.pirc.chat = true` now adds the
   `chat` argument. The unit names remain `pirc` and `pirc-node`.
7. Start the new gateway and all nodes in the same window. Protocol **9 and 10
   cannot mix**: the gateway closes mismatches with **4426**. Deploy the web bundle
   and check every expected node is online in `GET /api/nodes`.
8. Re-pair devices, re-login subscription backends, recreate UI-managed providers,
   enable push again (fresh VAPID keys), and start **new sessions**. Recreate
   schedules, projects, memories and other state deliberately; there is no import.
9. Test a trivial prompt and sandbox/browser operation on each role. Deployment
   and real-provider smoke tests are operator actions, not performed by cutover.

The remaining paid PTC/task-time and provider-login gate was **waived by the user**,
not passed. See [the cutover decision and validation scope](../development/historical-records.md#rust-cutover-and-validation-scope).

### Rollback across the cutover

Stop every new process first. Restore the **entire old release and matching old
state backups together**, including old chat binaries, provider settings and web
assets. Never run the TS binaries against Rust state or restore an old DB into
an active Rust service. Keep the fresh Rust state separately if it is needed for
inspection; there is no downgrade/import of sessions created after cutover.

## Later upgrades within the Rust release line

Keep gateway and nodes on the same release. Changes to
`crates/pirc-protocol/src/lib.rs`'s `NODE_PROTOCOL_VERSION` require a coordinated
restart. Node/agent changes require upgrading each node; gateway/provider changes
require the gateway; web changes require only the static bundle. Read each
release's migration notes before assuming a forward schema migration is supported.

- `models.json`: SIGHUP / `systemctl reload pirc`; invalid content keeps the last
  valid settings. Modes reload independently: invalid mode files are omitted,
  a directory-level failure keeps the previous catalog. Environment changes
  require a process restart.
- Agent config/prompts/skills: next agent start.
- Web-managed providers: apply immediately; affected in-flight inference cancels.
- While a node restarts, agents get `PIRC_SHUTDOWN_GRACE_MS`, then are killed;
  interrupted runs need a new prompt.
- Back up state before upgrading. Restore matching state with older binaries;
  SQLite has no automatic down-migration.

Dependency updates: refresh `cargoHash` in `nix/package.nix` after `Cargo.lock`
changes and `nodeModulesHash` in `nix/web.nix` after `bun.lock` changes. Build both
packages to verify fixed-output hashes; never commit a placeholder hash.
