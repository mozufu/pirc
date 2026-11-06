# Isolated work and explicit host management

[Plans](README.md) · [Unified conversations](unified-conversations.md) · [Execution contracts](conversation-execution-contracts.md)

Status: adopted product direction, **2026-11-04**. The user selected
「採用建議：隔離工作＋明確主機管理模式」 after reviewing the effect of process
isolation on host administration. This is part of U4, not a replacement for its
resource-revocation/install proof or the original five-stage goal.

## Accepted behavior

| Execution path        | Intended use                                                        | Authority                                                                                       | Transition behavior                                                                   |
| --------------------- | ------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| Isolated work         | Ordinary Agent work and work terminals                              | Current workspace/project mounts, rules and scoped grants enforced by the backend               | Retire old processes/resources and install the new binding only with acknowledgements |
| Host management       | Explicitly selected host administration requiring host capabilities | A separate user-authorized host execution path; never inferred from model text or `full-access` | Unknown surviving work keeps the workspace transition blocked                         |
| Legacy host execution | Existing terminals and approved host-command evidence               | Preserve recorded origin and existing outcomes; classify insufficient evidence honestly         | Never relabel old work as isolated or invent descendant-closure proof                 |

General new work should default to isolated execution when this feature is
implemented. A host-management choice is explicit and visible for the affected
terminal or approved command, using the existing control/approval identities.
Selecting a mode for new work does not convert a running process in place or
retroactively broaden its grant. Agent approval modes remain separate: fewer
confirmation prompts do not authorize leaving the selected execution boundary.

Unsupported isolation must return its capability/status and retain the user's
draft/request; it cannot silently execute on the host. Source revocation and
target installation are distinct capabilities. Running work under a sandbox is
not proof that all old descendants, descriptors or delegated effects can be
retired when the environment changes.

Host management must identify its conversation/environment origin and affected
external work. Where its descendants or retained access cannot be verified stopped,
show pending/blocked and do not start the replacement environment. Closing a
terminal panel, an exited direct shell, a completed command observer or an empty
live registry is insufficient. No force-clear, guessed PID/process-name kill,
replay or fabricated revocation acknowledgement is authorized by this decision.
Already-issued external effects retain their known/unknown outcome.

## Engineering contract

- Reuse durable command/terminal identities and frozen resource origins. The
  effective path is selected/enforced by the host; an Agent-provided label is not
  a grant. Bind approval/control, environment revision, selected path and scoped
  resource identity before effects, and recheck after waits.
- Reuse the existing native sandbox policy and kernel process scope where they
  provide the required guarantees. Work shells/terminals must obey workspace/
  project access and expose only the descriptors they need. A PTY must retain
  interactive job control without inheriting unrelated Node descriptors.
- A trusted launch guard must prevent shell/loader hooks or user code from running
  before the persistent scope is committed. Namespace/process identity and closure
  evidence survive request loss and are reconciled after restart without PID
  guessing or re-executing the user's command.
- Retire the direct process, child scope, PTY I/O, native proxy and other bound
  resources independently. Failure or uncertainty in one participant cannot skip
  shutdown of the others or free a conflicting write range.
- Keep provenance-specific host effect/descendant limitations visible. A host
  command that changed a service is not undone by ending its initiating shell.
  Independent authority and external effects cannot be guessed from a parent PID.
- Preserve session/history links, memory provenance/deletion, checkpoint isolation,
  user files and other writers. Do not copy a source tree, reset a workspace or
  recursively remove a recovery directory as a mode change.
- Version the new path/grant semantics and client capability. Existing records do
  not acquire a new user approval during migration. If an old client cannot make
  the required explicit choice, request an update/selection rather than treating
  omitted fields as a new host-management grant.

The upstream [Bubblewrap manual](https://raw.githubusercontent.com/containers/bubblewrap/main/bwrap.xml)
describes separate user/PID namespaces, and its
[security description](https://github.com/containers/bubblewrap/blob/main/README.md#system-security)
explains `no_new_privs`/setuid restrictions. Consequently an isolated work adapter
must not promise unchanged `ps`/`kill`/privilege-escalation behavior. Those are
reasons for an explicit host-management path, not grounds for an implicit escape.
The exact supported guarantees must be tested on the actual selected backend;
macOS process groups alone are not kernel descendant containment.

## Implementation order and acceptance

1. Persist/resolve effective execution path and capability/grant origin, keeping
   legacy records explicit and all existing identities intact.
2. Add isolated work shell/terminal adapters and scope-aware host dispatch, reusing
   native launch guards, process evidence, write claims and existing journals.
3. Bind complete source revocation and target installation acknowledgements to
   the frozen transition. Unsupported/unproven resources stay blocked.
4. Add necessary Web/Android choice/status/warning controls in the existing style;
   paired Android calls Gateway directly. No navigation or visual redesign.
5. Verify concurrent controllers/Agents, identical/conflicting requests, crash
   points, unsupported backends, old clients/migrations, host-management permission
   refusal and resource retirement. Include a descendant that changes process
   group/session and keeps an old file descriptor. Verify peers and later user
   edits survive. Distinguish mocked/unit, actual process/backend and device proof.

These adapters and client controls are not delivered by the terminal I/O cleanup
checkpoint. Public switching and U1 activation remain gated. This plan authorizes
no deployment, push, release or unrelated operating-system configuration change.

## Local implementation checkpoint: host-management approval origin (2026-11-04)

The existing approved host-command path now asks explicitly for **host management**.
Before publishing the Node-owned question, it durably binds the interaction to
its conversation, workspace, runner epoch, Node incarnation, side-request ID and
an exact-intent digest. The digest includes command, working directory, timeout,
workspace path, session root and the runner's mode snapshot. An arbitrary Agent
confirmation, `full-access` label or earlier launch cannot substitute for this
private Node record.

Admission requires the matching, unexpired, positively answered confirmation.
The existing current-environment and withdrawal checks still run. Reservation
of the host run, one-time consumption of that question and cooperative write
ranges commit together before spawn; database failure rolls them all back. A
repeated question/request does not grant another execution. Declined, expired,
unanswered, changed or already-consumed grants are refused. Lost requests and
restart do not execute a command again.

Node schema **2023** adds immutable retained `host_execution_approvals` metadata,
with execution path `host_management` and its consumed run ID. It stores no
additional command/output/credential content. Old runs remain without a new
approval; migration does not manufacture one, and session deletion cannot turn
retained evidence into a reusable grant. Capability
`hostManagementApprovalVersion: 1` describes only this approval-origin contract.
Gateway schema **1029** and protocol/client/envelope **15/2/3** stay unchanged.

This is the host-command part of step 1 and its existing confirmation flow, not
completion of both modes. Isolated work/PTY launch adapters, terminal mode choice,
OS descendant containment, complete source revocation, target installation and
Web/Android mode controls remain open. Existing terminal execution is unchanged;
it has not been silently relabeled as isolated or newly authorized host management.
Public switching remains disabled. See the [validation record](unified-conversations.md#u4-implementation-checkpoint-host-management-approval-origin-2026-11-04).

## Local implementation checkpoint: guarded isolated work terminals (2026-11-04)

An explicit `executionPath: "isolated_work"` terminal request now uses the native
Linux policy planner, filtering proxy and captured PID-namespace scope, with the
configured shell in place of the agent. Agent/readonly preparation still uses
its existing command and policy. External wrappers, macOS and unavailable
backends return `isolated_terminal_unavailable`; they do not execute a host
replacement or reserve a terminal/kernel launch.

A private FD 5 gate is distinct from PTY stdin. Status/seccomp/gate descriptors
are installed in one mapping. The sandbox invocation itself forces the terminal
gate mode, so an ordinary command builder or cleared caller env fails closed.
The trusted bridge closes unrelated inherited
FDs, consumes the permit and closes its copy before proxies/login hooks/shell
code start. It acquires this terminal's own controlling PTY for job control.
Loader/shell bootstrap hooks are rejected before the guarded wrapper starts.
The terminal and kernel journal rows share the same actual launch ID and commit
before spawn. Captured kernel identity, current control lease, mode/binding and
source fence are rechecked before a single permit is delivered. Request loss
does not abandon the Node-owned observer or replay a command.

Stop retires the captured kernel scope independently of direct-shell/group
observation and joins both PTY pumps before terminal settlement. Missing identity,
failed observations or failed persistence stay unconfirmed. Only current known
kernel observations can settle a scoped terminal. Restart uses the existing
fenced kernel-journal reconciliation; no PID guessing or relaunch is added.
A lost terminal I/O observer is not converted into a settled terminal merely
because its namespace is gone. Automatic recovery of that acknowledgement needs
additional old-owner/descriptor closure proof and remains open.

Node schema **2024** is a semantic reader fence (`SELECT 1`). The scope association
is an atomic join of existing journal identities, not a second launch table or
backfilled grant. `isolatedTerminalVersion: 1` is advertised only by the native
Linux adapter; live isolated terminal metadata has `executionPath: "isolated_work"`.
Old metadata stays unclassified. Gateway **1029**, protocol/client/envelope
**15/2/3**, package/dependencies/lockfiles/Nix hashes stay unchanged.

**Rollout remains incomplete:** the omitted-path compatibility request still
uses its existing behavior while Web/Android mode controls and default migration
are implemented. An explicit `host_management` label is not accepted as a
terminal grant. There is no silent fallback from a failed isolated request.
Host-management terminal grants, client choices and isolated-by-default rollout
remain next work. The already-delivered exact-intent host-command approval remains
separate. Public switching and full revocation/installation stay disabled.

Native Linux coverage includes a new login-hook/PTY/privacy/detached-writer case
in the existing `sandbox_native` CI target. It is not executable on this macOS
host and has not been accepted as passed locally. Current Node/PTY fixtures use
a synthetic kernel adapter; the standalone gate test checks actual PTY/control
FD behavior. Full external/delegated effects, project resources and environment
installation still need independent evidence.

## Local fix: Agent and terminal journal slots (2026-11-04)

Review found that the shared kernel journal's original table-level
`UNIQUE(session_id,runner_epoch)` also limited work terminals: an existing Agent
or another terminal in the same epoch could prevent a terminal from opening.
Node schema **2025** replaces that constraint with immutable `resource_kind` and
an **Agent-only** unique epoch index. Each terminal keeps its own launch ID,
private gate and scope; it does not increment or borrow the Agent's epoch slot.
Typed lookup/reconciliation retains the resource kind so an observer cannot
substitute a peer/Agent launch.

The transactional migration preserves launch IDs, origins, timestamps, kernel
identity, guard state and outcomes. Only an existing exact terminal/kernel
identity-and-origin join classifies an old row as a terminal; other historical
rows keep their Agent classification. No new grant, release or closure is
created. A failed rebuild rolls back rows, triggers and schema version together.
Agent duplicate admission and one-time guard release stay enforced.

Validation: **618 Node tests passed** (five child/opt-in ignores), **421 Gateway
tests**, **19 required real-process cases** and strict all-target Clippy passed.
Five new journal/migration and real Node/PTY cases cover an Agent reservation
plus two simultaneous terminals,
independent identities and retirement, repeated Agent rejection, exact-origin
migration and DDL failure rollback. The kernel adapter in that local fixture is
synthetic; native Linux and full revocation/installation acceptance remain open.
The owned **2.4 GiB** build/log tree is cleaned after verification.
Lost-I/O-owner recovery, terminal mode controls and default rollout still follow.

## Local implementation checkpoint: terminal I/O owner recovery (2026-11-04)

Node schema **2026** captures the Node's own immutable boot/PID-view/process-birth
identity atomically with each new guarded terminal reservation. Recovery requires
an accepted source fence, exact terminal/kernel origin, confirmed namespace
termination and read-only proof that the old Node thread group has exited. This
uses Linux pidfds without the thread-only flag; see the upstream
[pidfd_open manual](https://man7.org/linux/man-pages/man2/pidfd_open.2.html).
The checker never signals a saved owner PID. PID reuse does not target the new
process; unknown/live/missing/mismatched evidence stays blocked.

Owner exit and terminal settlement persist together, with immutable identities
and monotonic retained outcomes. Failure rolls both updates back; no command
replay or new grant is introduced. Pre-2026 rows are not backfilled. Kernel and
owner scans use bounded keyset pages so early unresolved rows cannot hide later
history. Cleanup still starts independent participants and requires their own
outcomes; a stopped kernel alone cannot retire a live I/O owner.

`terminalIoOwnerRecoveryVersion: 1` is not a full revocation acknowledgement.
Native Linux execution still requires Linux acceptance; local recovery fixtures
inject the OS observations. Host-management terminal grants, Web/Android choices,
compatibility/default migration, project/delegated resources and target install
remain open. Full switch/U1 flags remain disabled. See the
[validation record](unified-conversations.md#u4-implementation-checkpoint-terminal-io-owner-recovery-2026-11-04).

Validation: **629 Node**, **421 Gateway** and **19 required process cases** passed,
with strict all-target Clippy. The owned **2.9 GiB** outputs are cleaned. Actual
Linux owner/namespace and client rollout acceptance remain outstanding.

## Local implementation checkpoint: human host-terminal review (2026-11-04)

The explicit host terminal backend now requires a Node-generated review followed
by confirmation of its exact ID/hash and current control/environment. The existing
terminal endpoint accepts `action: "review"` or `action: "confirm"`, with a stable
request ID and `executionPath: "host_management"`; only a positive confirmation
can consume the review. Review expiry reuses Node's existing interaction TTL.
Node schema **2027** retains immutable metadata, and consumes authority atomically
with the terminal reservation before spawn. A SQL origin check rejects peer runs.
Retries query the same attempt; restart/unknown outcomes never launch again.

An owner can query results through `GET .../terminals?hostRequestId=...`, independent
of control acquisition or an open Web client. Pending stale/expired reviews and
changed rules/control/epoch are refused. Old records gain no approval. Live host
terminal/ready metadata identifies the path. Direct-shell/I/O exit does not retire
all detached host work: the durable outcome remains unconfirmed and blocks source
settlement/deletion. Isolated recovery cannot clear it. No force-clear is added.

`hostTerminalReviewVersion: 1` describes backend availability, not completed client
rollout. Web/Android mode controls, durable client retry state and warnings,
isolated-by-default migration, native Linux acceptance and full revocation/install
remain open. The omitted-path compatibility API is not newly classified. See the
[validation record](unified-conversations.md#u4-implementation-checkpoint-host-terminal-review-and-once-only-launch-2026-11-04).

Validation: **639 Node**, **421 Gateway**, **20 required process cases**, final
**49 focused terminal cases** (including 10 host-terminal cases) and strict all-target Clippy passed. Read-only
recovery works after new terminals are disabled; host-source Stop remains blocked
without descendant proof. The owned **2.9 GiB** outputs are cleaned. Native Linux,
client rollout and full revocation/install remain unaccepted.

## Local implementation checkpoint: durable isolated work-terminal requests (2026-11-06)

Node schema **2028** adds retained `terminal_work_requests`, so an explicit
isolated work terminal has a stable request identity before asynchronous
preparation starts. This closes the "general isolated terminal reconciliation"
gap left by the guarded isolated adapter; it does not add client controls.

- The table stores owner/session/request identity, Node incarnation, workspace,
  runner epoch, cwd and an intent digest, with states `accepted`, `not_started`
  and `outcome_unknown`. Triggers keep identity immutable, permit exactly one link
  to this request's own `launching` terminal-kind kernel scope, keep outcomes
  monotonic and forbid deletion. An Agent launch or peer scope cannot be claimed.
- `POST .../terminals` with `executionPath: "isolated_work"` and `requestId`
  admits durably before preparation. Only the first submission schedules a worker;
  a dropped HTTP waiter does not cancel it. The request links to its terminal/kernel
  reservation in the same transaction, and a failed link rolls the whole scope back.
  A known failure before linking records `not_started` with its error code, such as
  `isolated_terminal_unavailable`; a panic records
  `outcome_unknown`/`terminal_start_unconfirmed`. Repeating the same intent returns
  the same result (`200`); a changed intent under the same ID returns
  `409 work_terminal_request_conflict`. Preparing requests count toward the existing
  per-session and total terminal limits.
- `GET .../terminals?workRequestId=<id>` reads the retained result, including
  at full quota. An old-incarnation request or a missing live terminal reports
  `outcome_unknown`; nothing is replayed after restart.
- `GET .../terminals?capabilities=1` returns owned, non-mutating
  `terminalCapabilities` (`enabled`, `isolatedTerminalVersion`,
  `hostTerminalReviewVersion`, `workTerminalRequestVersion`). The Node capability
  document gains `workTerminalRequestVersion: 1`.
- A `requestId` without `executionPath: "isolated_work"` is refused, so it can
  never open a legacy host terminal. The bare `isolated_work` request without an
  ID still works non-durably (see gap 3 below).

Upgrade preserves existing scopes and invents no request IDs or grants. Old binaries
reject 2028; rollback needs matching state/binary backups. Gateway **1029**,
protocol/client/envelope **15/2/3**, packages, lockfiles and Nix hashes are
unchanged. Known limit: when spawn fails **after** linking, the request's state
comes from the terminal run (`not_started`), but its `errorCode` stays empty;
this is folded into gap 2 below.

Validation: **651 Node library tests** (five existing child/opt-in ignores),
**421 Gateway tests**, **61 focused terminal tests** (seven request-module and five
new isolated-fixture cases among them), **29 required real Gateway/Node process
cases** across 12 suites (terminals 5, Node-link side channels 6, execution fences
4, checkpoints 3, conversation admission 2, creation 2, host-command fences 2,
environment transitions, inference fences, memory, project deletion and streams
1 each), `cargo fmt --check` and strict all-target Clippy for Node/Gateway/
conformance passed. The new conformance case drives an isolated request through
Gateway on macOS: `not_started`/`isolated_terminal_unavailable` without host
fallback, identical retry, `409` on changed size and query recovery with no
terminal listed. The kernel adapter in Node fixtures is synthetic; native Linux
acceptance, Web/Android rollout and full revocation/installation remain open.
Local commit only, no push, deployment or Release.

## Local implementation checkpoint: terminal request discovery and result parity (2026-11-06)

Node schema **2029** closes the four Node gaps of the client terminal contract,
which is now frozen for Web/Android. `workTerminalRequestVersion` becomes **2**
in both the per-session terminal capabilities and the Node capability document.

1. **Discovery.** `GET .../terminals?unresolvedRequests=1[&limit][&after]` lists
   this owner's work and host requests for the session that still need a client
   decision (`preparing`, `review`, `outcome_unknown`). It pages by
   creation time, kind and request ID (default 50, at most 100) over new indexes.
   Each item is the existing single-request result. Reading needs no control
   lease and mutates nothing. Clients no longer need to persist pending IDs, so
   Web IndexedDB **3** and the Android envelope **3** stay unchanged.
2. **Result parity.** `hostManagement` now carries `version`, `requestId` and
   `errorCode`, like `workRequest`. A spawn that fails **after** the reservation
   records its reason in the same transaction as the `not_started` run. SQL
   triggers allow this only once, only for that request's own not-started run, and
   never rewrite it. A new `terminal_host_requests.error_code` column starts empty
   for existing rows.
3. **Durable isolated path only.** `executionPath: "isolated_work"` without
   `requestId` returns `400 work_terminal_request_required`. No released client
   sends the bare form, so keeping it would only leave a second, non-recoverable
   path. Internal fixtures still call the adapter directly.
4. **Bounded first reply.** The first POST waits at most **20 s**, below the
   Gateway's **30 s** relay timeout. After that it answers `202` with the current
   result, while the single detached worker continues. `201`/`200` keep their
   meanings.

Upgrade keeps existing work/host requests and their outcomes and adds no failure
reasons, grants or request IDs. Old binaries reject 2029; rollback needs matching
state/binary backups. Gateway **1029**, protocol/client/envelope **15/2/3**,
packages, lockfiles and Nix hashes are unchanged.

New cases: listing filters (preparing, review and old-incarnation unknown kept;
not-started, expired, stale and other-session rows excluded), paging with `limit=1`
equals the full list, owner refusal, read-only effect; the 2028→2029 upgrade keeps
rows without reasons; a post-reservation spawn failure keeps `runner_unavailable`
once without replay; a slow preparation answers `202` before its one worker
finishes; host spawn failure exposes and protects its `errorCode`; route-level
read-kind exclusivity and paging validation. The new Gateway process case reviews
a host terminal, discovers it with `limit=1` paging through the relay, confirms
it and sees the list empty, with a not-started isolated request never listed.

Validation: **655 Node library tests** (five existing ignores), **421 Gateway tests**,
**30 required real Gateway/Node process cases** across 12 suites (terminals 6,
Node-link side channels 6, execution fences 4, checkpoints 3, conversation
admission/creation/host-command fences 2 each, environment transitions, inference
fences, memory, project deletion and streams 1 each), `cargo fmt --check` and
strict all-target Node/Gateway/conformance Clippy passed. The focused terminal
module passed **65 cases**. The kernel adapter in Node fixtures is synthetic; per the user
(2026-11-06), native Linux tests are not run here because this host cannot
simulate them. Local commit only, no push, deployment or Release.

## Client terminal execution-path contract v1 (frozen for Web/Android)

Status: proposed on 2026-11-06; **frozen for client implementation on
2026-11-06** after the [Node 2029 checkpoint](#local-implementation-checkpoint-terminal-request-discovery-and-result-parity-2026-11-06)
closed its four Node gaps. The Node side builds on the
[2028 checkpoint](#local-implementation-checkpoint-durable-isolated-work-terminal-requests-2026-11-06).
No Web or Android code sends `executionPath`, `requestId`, `workRequestId`,
`hostRequestId` or `unresolvedRequests` yet. Both clients must implement this
one contract, so they cannot diverge. Clients require
`workTerminalRequestVersion >= 2`; acknowledgement and the specific error codes
below need **3** ([Node 2030](#local-implementation-checkpoint-terminal-request-acknowledgement-and-specific-errors-2026-11-06)). This covers
step 4 of the [implementation order](#implementation-order-and-acceptance):
necessary controls in the existing style, with no navigation or visual redesign.

### Discovery

1. Before offering a new terminal, read `GET .../terminals?capabilities=1` for the
   session through the existing Gateway relay; paired Android calls Gateway directly.
2. `enabled: false` means no new terminal of any path. Existing terminals and the
   two result queries stay readable.
3. `isolatedTerminalVersion >= 1` and `workTerminalRequestVersion >= 2`: the
   ordinary **New terminal** action uses isolated work. A Node advertising
   `workTerminalRequestVersion: 1` lacks discovery and parity; treat it as needing
   an update rather than adapting to it.
4. `isolatedTerminalVersion: 0`, for example on macOS or behind an external wrapper:
   the ordinary action shows that isolation is unavailable. A separate, explicit
   **Host management terminal…** action is offered only if
   `hostTerminalReviewVersion >= 1`. The client never falls back to the omitted-path
   host terminal by itself.
5. A missing capability field means version 0. An older Node without the query
   gets the client's existing "update the Node" state, not a guessed path.

### Request identity and recovery

- Each user action gets a new client-generated `requestId`
  (`[A-Za-z0-9_-]{1,128}`, a random UUID is enough). Work and host IDs use separate
  namespaces, but clients must not reuse an ID across them.
- The digest covers owner, session, workspace and its path, cwd, runner epoch,
  mode, shell, `clientId`/`generation` and `cols`/`rows`. A POST retry is therefore
  valid only with the **same control lease and size**. After a reconnect, a lease
  change or a resize, recovery is **GET only**. A changed intent under the same
  ID returns `409 work_terminal_request_conflict`.
- A lost or timed-out POST, or a reload: GET the request. A
  `404 terminal_request_not_found` means it was not admitted yet; any other
  `404` (for example a missing session) is a definite refusal. The client may re-POST the **same** ID with the same intent
  (deduplicated), or drop it. It never mints a new ID for the same user action.
- Isolated POST status codes: `201` is the first submission's finished result,
  `200` repeats an existing request, `202` means admitted but still preparing
  after the bounded wait. The body has the same `workRequest` shape in all three.
  On `202` the client polls the GET; the worker continues on the Node.
  The status code is advisory: the paired Android bridge returns only bodies, so
  clients decide by `state` (`preparing` means poll) and never by status alone.
- Node waits at most **20 s** for the worker, below the Gateway's **30 s** relay
  timeout. A relay `504 node_timeout` or `503 node_offline` is still an ambiguous
  outcome, handled by the GET above, not by a new request.
- `executionPath: "isolated_work"` without `requestId` returns
  `400 work_terminal_request_required`; there is no non-durable isolated path.
- **Discovery:** `GET .../terminals?unresolvedRequests=1[&limit=1..100][&after=<next>]`
  returns `{"terminalRequests":{"version":1,"items":[…],"next":<cursor|null>}}`.
  Each item is exactly the single-request result object (`workRequest` or
  `hostManagement`, plus `terminal`). It lists this owner's requests for the
  session in `preparing`, `review` or `outcome_unknown`, in creation order. A page
  may hold fewer items than `limit`, or none; continue while `next` is non-null.
  The read needs no control lease and stays available when new terminals are
  disabled. Clients use it after reload, reconnect or on a second device, instead
  of persisting pending IDs. Web IndexedDB **3** and Android envelope **3** are
  unchanged.
- Quota refusals return `409 terminal_capacity` (all terminal paths, including
  the compatibility path); show "too many terminals", not a generic error.
- **Acknowledgement (v3):** `POST .../terminals` with
  `{"action":"acknowledge","clientId","generation","workRequestId"|"hostRequestId"}`
  (exactly one ID, no other fields) records a retained, once-only user decision
  for a request whose state is `outcome_unknown`. It needs current control but not
  the new-terminal capability. The result object gains `acknowledgedAt`, and
  `unresolvedRequests` stops listing it. The **state stays `outcome_unknown`**:
  run evidence, Stop/deletion/transition blocks and later reconciliation are
  unchanged; it is not a force-clear. Repeating it returns the same result. Other
  states return `409 terminal_request_not_unknown`; an unknown ID returns
  `404 terminal_request_not_found`.
- Read kinds (`capabilities`, `workRequestId`, `hostRequestId`,
  `unresolvedRequests`) are mutually exclusive; `after`/`limit` belong to the list
  only. Violations return `400 invalid_input`.
- Result shapes match. `workRequest` and `hostManagement` both carry `version: 1`,
  `requestId`, `state`, `errorCode` and `terminalId`. Host results add `id`,
  `reviewHash`, `review` and `expiresAt`. `errorCode` is set for a known no-start,
  including a spawn that failed after the reservation (for example
  `runner_unavailable`), and is never rewritten.

### Result states and client behavior

| State (`workRequest.state` / `hostManagement.state`) | Meaning                                                                     | Client behavior                                                                                                                                                   |
| ---------------------------------------------------- | --------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `review` (host only)                                 | Node-issued review is pending                                               | Show shell, root, size and the host-effects `warning` verbatim; confirm sends exact `reviewId`/`reviewHash`, `confirmed: true` and the reviewed `cols`/`rows`     |
| `stale` / `expired` (host only)                      | Review from an earlier Node incarnation, or past its TTL                    | Cannot be confirmed; a new review is a new user action with a new ID                                                                                              |
| `preparing` (work only)                              | Admitted; preparation is running in this Node incarnation                   | Show progress and poll with GET; do not POST again                                                                                                                |
| `launching` / `running` with `terminal`              | Live terminal linked to this request                                        | Attach to the existing stream for `terminal.id`                                                                                                                   |
| `not_started`                                        | Known no-start; `errorCode` says why (`isolated_terminal_unavailable`, …)   | Show the reason; _Try again_ is a new action; an unavailable path may offer the explicit host-management action, never auto-switch                                |
| `outcome_unknown`                                    | Start or liveness cannot be confirmed (restart, panic, lost registry)       | Show "start not confirmed"; no automatic retry; explain that workspace switching may stay blocked; offer **Acknowledge** (v3), which only hides it from discovery |
| `settled`                                            | Terminal ended with confirmed retirement                                    | Closed                                                                                                                                                            |
| `unconfirmed`                                        | Direct shell closed but retirement is not proven (host detached work, etc.) | Show as closed but unconfirmed; transitions stay blocked; no force-clear action                                                                                   |

Live terminals and ready frames already carry `executionPath`. Clients show a
small path label (isolated / host management) on the terminal tab. Untagged
legacy terminals remain unlabeled; they are not shown as isolated.

### Node gaps closed (2026-11-06)

All four were delivered in the [Node 2029 checkpoint](#local-implementation-checkpoint-terminal-request-discovery-and-result-parity-2026-11-06):

1. ~~Unresolved-request discovery~~: the `unresolvedRequests` read above.
2. ~~Shape parity~~: matching fields, plus a retained `errorCode` for failures
   after the reservation.
3. ~~Bare `isolated_work`~~: refused now rather than after client rollout,
   because no released client sends it and keeping it would leave a second,
   non-recoverable path.
4. ~~Relay timeout~~: Node's bounded 20 s wait and `202`, with a fixture where the
   waiter answers before the one worker finishes.

### Client work split (next)

Can run in parallel in separate worktrees, with the frozen contract as their only
shared input.

The user decided on **2026-11-06** that the current Web/Android UI will be fully
replaced by a new design that is still in mock-ups. Client slices therefore
only need **correct interfaces**: API calls, request identity, recovery and the
state mapping above, with tests. Minimal throwaway UI wiring is enough; visual
quality, placement and polish are out of scope.

- **Web** (`apps/web/src/lib/panel-api.ts`, `components/panel/TerminalTab.svelte`
  and locales): capabilities, request create/recover, host review dialog, state
  rendering and path label; en/zh-TW strings. Vitest cases cover every row of the
  state table, `202` polling, reload recovery through `unresolvedRequests` paging,
  `409` and the 404→same-ID re-POST.
- **Android** (`apps/android/lib/live/terminal_pane.dart`, `terminal_state.dart`
  and `gateway.dart`): the same flow through the direct Gateway connection, with
  focused simple Flutter tests only (no visual redesign).
- **Conformance**: Gateway-level discovery/paging and host review are already
  covered by `terminal_requests_are_discoverable_through_the_gateway_without_control`.
  Client slices add their own unit cases against this contract; real browser and
  device journeys stay with the new UI.

### Decisions to confirm with the user at client entry

1. ~~Where macOS offers the explicit host-management terminal.~~ Deferred to the
   new design (2026-11-06). The interface layer only exposes both actions, keeps
   them separate and never auto-switches; the temporary UI may place them anywhere.
2. When old clients that send the omitted-path request stop being able to open host
   terminals (isolated-by-default migration). Recommended: keep it until both new
   clients are released, then gate it behind a Node setting with a visible update
   prompt. Never reclassify existing terminals.
3. ~~What to do with requests left `outcome_unknown`.~~ **Decided 2026-11-06:**
   the user chose a retained acknowledgement marker that hides the request from
   discovery without claiming closure ([Node 2030](#local-implementation-checkpoint-terminal-request-acknowledgement-and-specific-errors-2026-11-06)). No force-clear is
   authorized. A guided manual-inspection path for `unconfirmed` stays open.

Native Linux acceptance of the isolated adapter, complete revocation/installation
and public switching remain gated as above. This contract authorizes no push,
deployment or release.

## Local implementation checkpoint: Web terminal contract client (2026-11-06)

The Web client now implements the
[client terminal execution-path contract v1](#client-terminal-execution-path-contract-v1-frozen-for-webandroid)
against Node `workTerminalRequestVersion` **2**. Per the user's 2026-11-06 scope rule,
only the interface layer is meant to be correct; the `TerminalTab.svelte` wiring is
throwaway UI for the coming redesign, with no navigation or visual work.

- **Interface** (`apps/web/src/lib/terminal-requests.ts`): `terminalRequestApi`
  (`capabilities`, `submitWork`, `workResult`, `reviewHost`, `confirmHost`,
  `hostResult`, `unresolvedPage`, `unresolved`), `parseCapabilities`/`terminalOffer`
  (`update_node`, `disabled`, `isolated`, `isolation_unavailable` with an explicit
  `hostManagement` flag; a missing field is 0, a missing document or version < 2
  asks to update the Node), `phaseOf`, `allowedActions`, `blocksTransitions`,
  `classifyFailure` and the in-memory `TerminalRequests` controller
  (`openWork`, `reviewHost`, `confirmHost`, `resubmit`, `refresh`, `dismiss`,
  `recover`, `dispose`). `http.ts` gains `requestWithStatus` so `201`/`200`/`202`
  stay distinct.
- **Identity and recovery**: one new `requestId` per user action; `202` and
  discovered `preparing` requests are polled by GET only; a `409` conflict or
  `host_terminal_review_required` reads the ID's retained result; any network loss
  or 5xx (including `504 node_timeout`/`503 node_offline`) is resolved by GET. A
  GET `404` offers _Send again_ with the same ID only while the lease, client and
  size are unchanged; otherwise only reading remains. Nothing retries or clears by
  itself. Discovery follows `next` through short or empty pages and stops on a
  cursor that does not advance. Pending IDs live in memory only; IndexedDB stays
  at **3**.
- **States**: every row of the state table maps to a client phase (`review`,
  `review_unusable`, `preparing`, `live`, `not_started`, `start_unconfirmed`,
  `closed`, `closed_unconfirmed`, plus `unknown_state` for future values) and
  local delivery phases (`submitting`, `checking`, `unknown_delivery`,
  `not_admitted`, `rejected`). A live state attaches through the existing
  `TerminalView` stream. Terminal chips show an isolated/host-management path
  label; untagged legacy terminals stay unlabeled.
- **No host fallback**: the omitted-path `panelApi.createTerminal` is removed. With
  isolation unavailable the ordinary action is disabled and a separate _Host
  management terminal…_ action reviews first (shell, directory, size and the
  `warning` verbatim), then confirms with the exact `reviewId`/`reviewHash`,
  `confirmed: true` and the size the Node reviewed.
- en/zh-TW strings for the throwaway wiring only.

Contract notes found while implementing (Node unchanged):

1. A host confirm must repeat the **reviewed** (Node-clamped) `cols`/`rows`: the
   review digest covers them, so another size returns
   `409 host_terminal_review_required`. The contract table names only
   `reviewId`/`reviewHash`/`confirmed`; the Web client sends `review.cols/rows`.
2. A review discovered after reload does not say which lease made it; the digest
   binds `clientId`/`generation`, so only the same lease can confirm it. The client
   lets the Node decide and otherwise shows the `409` and the review's state.
3. `outcome_unknown` work requests stay in `unresolvedRequests` permanently,
   because no client action can resolve them (by design, no force-clear). The list
   only grows across Node restarts; this belongs with decision 3 above.
4. A POST `404` (for example a missing session) is treated as a definite refusal;
   only a GET `404` means "not admitted".

Validation: `npx vitest run` in `apps/web`: **69 files, 622 tests** passed
(566 before; **53** new in `terminal-requests.test.ts` and **3** in
`TerminalTab.test.ts`). `svelte-check` found 0 errors and 0 warnings, and Prettier
check passed on all changed files. Rust, Gateway, Node, lockfiles and package
versions are unchanged.

Still open: real browser journeys against a live Gateway/Node, the new UI (placement
of the host-management action, the review dialog, progress), rediscovery on a
Gateway reconnect without a reload (the throwaway wiring rediscovers on mount and
session change only), and Android parity. Local commit only, no push, deployment
or Release.

## Local implementation checkpoint: Android terminal contract client (2026-11-06)

Android adopts the [client terminal execution-path contract v1](#client-terminal-execution-path-contract-v1-frozen-for-webandroid)
through its direct Gateway connection. Per the user's 2026-11-06 decision the
scope is the **interface layer only**; the terminal pane gets throwaway wiring
and no visual or navigation redesign.

- New `apps/android/lib/live/terminal_requests.dart`, UI-independent:
  `TerminalCapabilities` (missing fields mean 0; no `terminalCapabilities`
  object or `workTerminalRequestVersion < 2` means "update the Node"),
  `TerminalIntent` (session, `clientId`/`generation`, `cols`/`rows`),
  `TerminalRequestResult` (one parser for `workRequest`/`hostManagement` from
  POST, both GETs and discovery items), `TerminalRequestApi` (capabilities,
  `submitWork`, `reviewHost`, `confirmHost`, `read` with `404` → not admitted,
  `unresolvedPage`/`unresolved` following `next` through short or empty pages)
  and `TerminalRequestTracker` (one session's flow).
- Every contract row maps to a `TerminalRequestStatus` with its allowed
  `TerminalRequestAction`s (`terminalRequestActions`), plus transport states
  `submitting`, `ambiguous` (504/503/other 5xx/connection loss: resolved by GET),
  `notAdmitted` (GET `404`: re-POST the same ID only while lease and size are
  unchanged), `conflict` (`409 work_terminal_request_conflict`: GET only) and
  `rejected` (other 4xx). `preparing` polls GET; `launching`/`running` with its
  `terminal` attaches through the existing PTY stream code, without it it is
  `outcome_unknown`. There are no automatic POST retries and no force-clear;
  _dismiss_ only hides an entry locally. _Try again_ and a new host review are new
  actions with new random UUID request IDs.
- The ordinary New terminal action re-reads capabilities and POSTs only
  `isolated_work`; the omitted-path host POST is gone from Android. When
  isolation is unavailable it explains why, and the separate host-management
  action (review → verbatim `warning`, shell, cwd, size → confirm with the exact
  `reviewId`/`reviewHash`, `confirmed: true`) appears only with
  `hostTerminalReviewVersion >= 1`. Loading a session discovers unresolved
  requests; nothing is persisted, the private envelope stays at **3**.
- Terminal tabs show a small isolated / host management label from
  `executionPath`; untagged terminals stay unlabeled. 29 new en/zh-TW strings.

Validation: `flutter test test/terminal_requests_test.dart` **44 passed** (every
state row, 201/202 polling to live and to a no-start, failed poll, 409, other
4xx, 504→404→same-ID re-POST, 503 and connection-loss GET recovery, lease and
size change → GET only, five unavailable/old/disabled capability shapes with no
POST, host review/confirm/ambiguous confirm/refused confirm, discovery paging with
short and empty pages and a stuck cursor, recovery mapping, pane state and one
pane widget journey). Existing `terminal_parity` **8** (its two creation cases now
expect the isolated request), `terminal_extra_keys` **4**,
`terminal_keyboard_performance` **1**, `terminal_zoom` **2** and `i18n` **3**
passed; `flutter analyze` of the whole package found no issues.

Notes for the coordinator, no Node change made: the native bridge returns only
response bodies, so Android distinguishes `201`/`200`/`202` by `state`, which
the contract makes equivalent. A missing session and a missing request both
answer `404`; a re-POST after the former fails harmlessly. A review discovered
on another device or lease cannot be confirmed (its digest holds the lease), so
Node answers `409 host_terminal_review_required` and the client shows a refusal;
a new review is needed. Old-incarnation `outcome_unknown` work requests stay in
`unresolvedRequests` indefinitely, so the list can only grow until a later
resolution path exists.

Open: device/emulator journeys, the real new UI and placement of the host action
(with the new design), Web parity is a separate slice. Local commit only, no
push, deployment or Release.

## Integration checkpoint: Web and Android terminal contract clients (2026-11-06)

The two client slices were implemented in parallel worktrees from `0a289a14`
and integrated onto `codex/app-document-replaced-computed-style` as `d9d2f558`
(Web) and `0c487aed` (Android). Their own sections above record the design. Per
the user's 2026-11-06 decision, both are **interface layers with throwaway UI
wiring** for the coming redesign. Neither changes Rust, Kotlin, dependencies,
lockfiles, Web IndexedDB **3** or the Android envelope **3**. Both removed the
client's omitted-path host-terminal call, so no client falls back to it.

Re-run after integration: Web `vitest run` **622 tests in 69 files** (56 new) and
`svelte-check` with 0 errors/warnings; Android focused Flutter tests **62 passed**
(44 new request tests plus terminal parity, extra keys, keyboard performance, zoom
and i18n) and `flutter analyze` with no issues. Rust is unchanged since the Node
2029 checkpoint. No browser, emulator, device, APK or native Linux validation is
claimed. Local commits only, no push, deployment or Release.

Contract clarifications now written into the frozen contract above: a host
confirmation must repeat the reviewed (Node-clamped) `cols`/`rows`, because the
review hash covers them; a review is bound to the control lease that created it,
so a review found after reload or on another device gets
`409 host_terminal_review_required` and needs a new review; clients decide by
`state`, not HTTP status.

Follow-ups found by the client agents (Node unchanged; each needs its own slice):

1. ~~**`outcome_unknown` never leaves the unresolved list.**~~ Resolved by the
   user's choice of an acknowledgement marker ([Node 2030](#local-implementation-checkpoint-terminal-request-acknowledgement-and-specific-errors-2026-11-06)).
2. ~~**Distinguishable 404s.**~~ `terminal_request_not_found` (Node 2030).
3. ~~**Distinguishable capacity refusals.**~~ `terminal_capacity` (Node 2030).
4. **Reconnect discovery.** The throwaway Web wiring recovers only on mount or
   session change. The new UI must call `recover()` after a Gateway reconnect,
   and the Android tracker likewise after reconnect.

## Local implementation checkpoint: terminal request acknowledgement and specific errors (2026-11-06)

Node schema **2030** delivers the three Node follow-ups found by the client
agents. `workTerminalRequestVersion` becomes **3**.

1. **Acknowledgement (user decision, 2026-11-06).** `POST .../terminals` with
   `action: "acknowledge"` and exactly one of `workRequestId`/`hostRequestId`
   records `acknowledged_at`/`acknowledged_by` once for a request whose derived
   state is `outcome_unknown`. Discovery stops listing it; GET shows
   `acknowledgedAt`. The state stays `outcome_unknown`, and terminal runs, kernel
   journals and Stop/deletion/transition blocks are untouched. This is a retained
   user decision, not a closure or force-clear. Repeats are idempotent. Other
   states return `409 terminal_request_not_unknown`. It needs the current control
   lease but works while new terminals are disabled. SQL triggers allow it only
   once and only while the linked run is unresolved (or there is no run, for a
   work request that never reached its reservation).
2. **`404 terminal_request_not_found`** for an unknown work/host request ID
   (GET and acknowledgement), distinct from a missing session.
3. **`409 terminal_capacity`** for every terminal quota refusal, including the
   omitted-path compatibility API, whose snapshot is updated. Message text is
   unchanged; older clients that only read the status still see `409`.

Positional inserts into `terminal_work_requests` now name their columns, so the
added columns cannot shift values. Upgrade keeps existing requests unacknowledged
and invents no decisions. Old binaries reject 2030. Gateway **1029**,
protocol/client/envelope **15/2/3**, packages, lockfiles and Nix hashes are
unchanged.

New cases: acknowledgement of old-incarnation work and host unknowns (hidden from
discovery, state and launching run unchanged, actor retained, idempotent), refusal
for preparing/no-start/review, unknown IDs and foreign owners, SQL refusal of a
second or invalid marker, specific not-found codes for both kinds, route
validation (single ID, no extra fields, current lease), the 2029→2030 upgrade, and
a Gateway process case for the specific codes and `workTerminalRequestVersion: 3`.

Validation: **658 Node library tests** (five existing ignores), **421 Gateway tests**, **68
focused terminal tests**, **31 required real Gateway/Node process cases** across 12
suites (terminals 7, Node-link side channels 6, execution fences 4, checkpoints 3,
conversation admission/creation/host-command fences 2 each, environment
transitions, inference fences, memory, project deletion and streams 1 each),
`cargo fmt --check` and strict all-target Node/Gateway/conformance Clippy passed.
No native Linux, browser or device validation is claimed. Local commit only. Web and Android adopt v3 in the following client slices.

## Local implementation checkpoint: Web terminal contract v3 (2026-11-06)

The Web interface layer adopts [Node 2030](#local-implementation-checkpoint-terminal-request-acknowledgement-and-specific-errors-2026-11-06)
(`workTerminalRequestVersion` **3**). As before, only the interface is meant to
be correct; the `TerminalTab.svelte` wiring stays throwaway UI.

- **Specific errors** (`classifyFailure` in `apps/web/src/lib/terminal-requests.ts`):
  only `404 terminal_request_not_found` means "not admitted" and allows the
  same-ID re-POST. Any other `404` (a missing session, or a v2 Node's generic
  code) is a definite refusal. After an ambiguous POST it leaves the request
  readable (_Check again_) without a resend. `409 terminal_capacity` is a
  definite refusal with its own `reason: 'capacity'`, shown as "too many
  terminals". `409 terminal_request_not_unknown` has its own reason as well.
  Every recorded error now carries its `reason`.
- **Acknowledgement**: `terminalRequestApi.acknowledge(lease, kind, requestId)`
  sends exactly `{action: "acknowledge", clientId, generation,
workRequestId | hostRequestId}`. `canAcknowledge(caps)` requires version 3.
  `allowedActions` offers `acknowledge` only for `start_unconfirmed` with state
  `outcome_unknown` and no `acknowledgedAt`, and only with the current lease
  (it works while new terminals are disabled). `TerminalRequests.acknowledge`
  refuses a v2 Node, other states and other sessions without sending. On success
  the request leaves the in-memory list, as it leaves discovery, and is never shown
  as closed. A recovered or read result that is already acknowledged is dropped
  the same way. `409 terminal_request_not_unknown` and ambiguous replies re-read
  the result by GET; if that shows no `acknowledgedAt`, the action is offered again
  (the Node repeats it idempotently). A definite refusal keeps the request with its
  error. `acknowledgedAt` is parsed in both result shapes.
- en/zh-TW strings: _Acknowledge_, the explanation that acknowledging only stops
  listing the request (it is not closed and transitions may stay blocked), and the
  capacity message.

Validation: `npx vitest run` in `apps/web`: **69 files, 637 tests** passed (622
before; `terminal-requests.test.ts` **53 → 65**, `TerminalTab.test.ts` **3 → 6**).
`svelte-check` found 0 errors and 0 warnings, and Prettier check passed on all
changed files. Rust, lockfiles, package versions and IndexedDB **3** are unchanged.

Contract note: a v2 Node answers an unknown request ID with a generic `404`, so on
v2 a lost POST can no longer be re-sent under its ID. It stays readable instead.
This is conservative, and it only affects Nodes older than 2030.

Still open: rediscovery after a Gateway reconnect without reload, real browser
journeys and the new UI. Local commit only, no push, deployment or Release.

## Local implementation checkpoint: Android terminal contract v3 (2026-11-06)

Android adopts the [Node 2030](#local-implementation-checkpoint-terminal-request-acknowledgement-and-specific-errors-2026-11-06)
additions (`workTerminalRequestVersion: 3`) in the same interface layer
(`apps/android/lib/live/terminal_requests.dart`), with the throwaway pane wiring
unchanged apart from the new action and text.

- **Specific errors.** Only `404 terminal_request_not_found` makes a GET
  "not admitted" (`terminalRequestNotAdmitted`), which allows the same-ID
  re-POST. Any other `404`, such as a missing session, is rethrown: before a
  result it becomes the definite `rejected` status; for a known request it stays
  an error on the last result. `409 terminal_capacity` gets its own `capacity`
  status ("Too many terminals are open or preparing…") with _Try again_ (new ID)
  and _Dismiss_, for work requests and host reviews alike. A v2 Node's generic
  `404` therefore never allows a re-POST.
- **Acknowledgement.** `TerminalRequestApi.acknowledge` POSTs exactly
  `{"action":"acknowledge","clientId","generation","workRequestId"|"hostRequestId"}`.
  `TerminalRequestResult.acknowledgedAt` is parsed for both shapes. The new
  `TerminalRequestAction.acknowledge` is offered only for `outcomeUnknown`, only
  when `TerminalCapabilities.acknowledgesUnknown` (version ≥ 3, also while new
  terminals are disabled), only with the current control lease and only before
  `acknowledgedAt` is set. On success the state stays `outcome_unknown` and the
  entry leaves `TerminalRequestTracker.pending`/`pendingRequests`, with text that
  says the start is still unconfirmed and claims no closure. `409
terminal_request_not_unknown` and ambiguous replies are resolved by GET;
  other refusals keep the request pending with its error. Local _Dismiss_ is
  unchanged and separate.
- Host confirmation now always sends the reviewed `cols`/`rows`, as the updated
  state table requires. Three new en/zh-TW strings.

Validation: `flutter test test/terminal_requests_test.dart` **57 passed** (13 new:
specific vs generic `404` on read, a missing session after an ambiguous POST,
a generic `404` for a known request, `terminal_capacity` for work and host,
`acknowledgedAt` parsing, the exact acknowledge bodies, the offer matrix across
every state and v2/v3/disabled/no-lease capabilities, success leaving pending,
`terminal_request_not_unknown` re-read, ambiguous acknowledgement, a definite
refusal, no POST on v2 or without a lease, and pane acknowledgement). Existing
`terminal_parity` **8**, `terminal_extra_keys` **4**,
`terminal_keyboard_performance` **1**, `terminal_zoom` **2** and `i18n` **3**
passed; `flutter analyze` of the whole package found no issues. No device,
emulator or APK run. Local commit only, no push, deployment or Release.

## Integration checkpoint: terminal contract v3 clients (2026-11-06)

The Web and Android v3 slices were built in parallel from `9580e53b` and
integrated as `ac3d68b8` (Web) and `1d725a79` (Android). Both now treat only
`404 terminal_request_not_found` as "not admitted", show `409 terminal_capacity`
as its own reason, and offer **Acknowledge** only for `outcome_unknown`, on a v3
Node, with the current lease. An acknowledged request leaves the client's pending
list and discovery, and it is never shown as closed. Android host confirmation now
always repeats the reviewed size. Formats, dependencies and lockfiles are unchanged.

Re-run after integration: Web `vitest run` **637 tests in 69 files** with
`svelte-check` clean; Android focused Flutter tests **75 passed** (57 request
tests plus terminal parity, extra keys, keyboard performance, zoom and i18n) and
`flutter analyze` clean; Prettier clean on the changed files and plans. Rust is
unchanged since Node 2030. No browser, emulator, device, APK or native Linux
validation is claimed. Local commits only.

Accepted consequence: against a pre-2030 Node, a lost POST stays readable but is
no longer re-sent under the same ID, because the generic 404 cannot be told apart
from a missing session. This is the safe direction. Remaining open items: reconnect
discovery in the new UI (follow-up 4), real browser/device journeys, native Linux
acceptance, isolated-by-default rollout (decision 2) and a guided inspection path
for `unconfirmed`.
