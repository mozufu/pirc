# Folder grants and deny (C6a)

[Plans](README.md) · [Completion contracts](unified-completion-contracts.md#c6-projects-folders-and-collaboration) · [Transition installation](transition-installation.md)

Status: **design adopted on 2026-11-09**; C6a-1 and C6a-2 implemented locally. First slice
of [C6](unified-completion-contracts.md#c6-projects-folders-and-collaboration).
It also unblocks C1's "grant revoked between phases", C2's R5 and C3's X3 grant
case.

## User decisions (2026-11-09)

1. **First slice:** per-conversation folder grants with explicit deny, before
   project fan-out and managed-folder allocation.
2. **Grantable roots:** only folders under Node-configured roots
   (`PIRC_GRANT_ROOTS`, a JSON array of absolute paths). Unset means nothing is
   grantable.
3. **Live revocation:** revoking a grant or adding a deny fences immediately:
   new effects are refused, the conversation's runner and isolated terminals
   stop and restart without the old access, and the result states whether
   containment can be confirmed on this backend.

## Model

- A grant belongs to one conversation on its Node: `{grantId, path, access,
createdAt, revokedAt}`. `access` is `read`, `write` or `deny`. Paths are
  canonical (`realpath`) at creation. Write and read grants must lie under a
  configured root. A deny may also target a path inside the conversation's
  workspace or under an existing grant. Grants are retained after revocation.
- **Effective access:** deny overrides every overlapping grant, and the
  workspace itself, for the denied path and everything below it. A write grant
  makes its subtree writable. Existing explicit grants survive switches;
  nothing is widened implicitly.
- **Read is ambient on these backends.** The native Linux, sandbox-runtime and
  macOS policies already allow reading outside private state directories, so a
  `read` grant records intent but widens nothing. The effective-access view
  states this instead of implying a read restriction. Deny is what restricts
  reads.
- **Enforcement** goes through the existing session sandbox policy: write grants
  join `allowed_paths`, read grants `read_only_dirs`, denies `deny_read` and
  `deny_write`. Every backend that enforces that policy (agent and isolated
  terminal launches) therefore enforces grants. Every backend builds that
  policy; the unavailable backend starts nothing, so no grant can be bypassed
  there. Recovery checkpoints start without inherited grants.
- **Host execution ignores the sandbox.** While any deny is active, new
  host-management commands and host terminals for that conversation are refused
  (`folder_deny_unenforceable_on_host`), as C2 requires. Already-running host
  effects keep their unprovable status.

## Changes and fencing

- Create and revoke require the current control lease. Widening (a new read or
  write grant) also needs an open admission fence. Narrowing (a deny or a
  revoke) never waits for a pending transition; it makes that transition's
  frozen target stale instead (below). Each change advances the runner epoch, which
  invalidates old approvals, and stops the live runner and isolated terminals;
  the next start uses the new policy. Stopped work is not restarted.
- The reply reports the grant, whether a runner or terminals were stopped, and
  `confirmsContainment` (native Linux only). Elsewhere, descendants of the
  stopped runner are unprovable, as in C2.
- Transitions keep a conversation's grants; the target binding gets the same
  explicit grants, and deny still applies. The grant set is part of the
  reviewed target frozen at acceptance (only when grants exist, so older
  reviews still match). A change after review refuses installation with
  `stale_transition_target`, checked before revocation evidence; the user
  cancels and reviews again (C1 O5). Cancelling never restores a revoked
  grant (C3 X3).
- **Deny enforcement (C2 R5).** While a deny is active, the access view adds
  `denyEnforcement` `{status, risksTotal, digest}` from the revocation
  evaluator: `confirmed` only without retained risks, otherwise `unproven`.
  Acknowledging an unproven switch keeps the switch's adopted result but never
  makes the deny enforced, and host execution stays refused on the target.

## Slices

| Slice | Content                                                                                                     |
| ----- | ----------------------------------------------------------------------------------------------------------- |
| C6a-1 | Node: roots setting, grant store, effective access, policy wiring, immediate fence, host refusal under deny |
| C6a-2 | Gateway relay and status; C1 grant-revoked-between-phases, C2 R5 and C3 X3 grant cases                      |
| C6a-3 | Web/Android interface layer (throwaway UI)                                                                  |

Not in C6a: project-level grants and fan-out, managed folders, alias identity
beyond `realpath` (rename/inode/bind-mount checks), notes/board, waits and shared
storage. This plan authorizes no push, deployment or release.

## Local checkpoint: C6a-1 Node grants (2026-11-09)

Node schema **2038** adds `folder_grants` (immutable once revoked, deleted with
its session). `PIRC_GRANT_ROOTS` (JSON array of absolute paths) enables grants.
Routes, all relayed later by C6a-2:

- `GET /api/sessions/:id/grants` → `{grantsEnabled, effectiveAccess}`.
- `POST /api/sessions/:id/grants` `{clientId, generation, path, access}` →
  `{grant, effectiveAccess, fence}`; same path and access is idempotent and does
  not fence again.
- `POST /api/sessions/:id/grants/:grant/revoke` `{clientId, generation}`.

Errors: `folder_grants_unavailable` 409 (no roots), `folder_not_found` 404,
`folder_not_a_directory` 400, `folder_private` 403 (Node state),
`folder_outside_grant_roots` 403, `grant_not_found` 404, lease and admission
fence errors as elsewhere, `folder_deny_unenforceable_on_host` 409 from host
commands and host terminals while a deny is active.

`effectiveAccess` (version 1) lists each grant with `effective`
(`read`/`write`/`deny`), `deniedBy`, `writableVia`, the disclosure
`reads_outside_private_dirs_are_not_restricted` and `hostExecutionRefused`.
`fence` reports `runnerWasLive`, `runnerStopped`, `terminalsWereLive`,
`terminalsStopped` and `confirmsContainment`. Each change advances the runner
epoch, which stales pending approvals.

Native Linux is not tested here. Gateway relay, transition cases and clients
were not part of this slice.

## Local checkpoint: C6a-2 Gateway relay and transition cases (2026-11-09)

No schema change (Gateway **1032**, Node **2038**).

- **Relay.** The Gateway relays `GET`/`POST /api/sessions/:id/grants` and
  `POST /api/sessions/:id/grants/:grant/revoke` verbatim to the conversation's
  Node, like terminals; the Node owns validation, leases and fencing. Other
  paths under `grants/` are refused.
- **Frozen grants.** Node preflight evidence and the frozen target subset carry
  `folderGrants` when any exist. Installation compares the target before the
  revocation evidence and maps a narrowing change's epoch advance to
  `stale_transition_target`, which the Gateway already passes through.
- **Narrowing during a transition.** Deny and revoke are accepted while a
  transition is pending; new read/write grants return
  `environment_transition_pending`.

| Case                                         | Evidence                                                                                                                                                                                               |
| -------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **C1 O5** grant revoked mid-switch           | Real process: grant, confirm, revoke through the Gateway; `advance` returns `stale_transition_target`, the binding stays on the source. Node units for revoke and for a new deny                       |
| **C3 X3** grant revoked before release       | Real process and Node unit: cancel releases to the source with no active grant; widening during the transition was refused                                                                             |
| **C2 R5** switch versus deny, same host risk | Node unit: the same settled host command is acknowledged and installed in both cases; with a deny, `denyEnforcement` stays `unproven` after installation and host terminals stay refused on the target |
| Carry-over                                   | Node unit: an unchanged grant survives installation                                                                                                                                                    |

Known limits: on a backend without kernel containment, the epoch advance of a
grant change counts as an unprovable runner generation in later revocation
evaluations, even when no runner was live (over-reports, never hides). Native
Linux, project-level grants and the client interfaces (C6a-3) remain.
