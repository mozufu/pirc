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
