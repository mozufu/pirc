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
