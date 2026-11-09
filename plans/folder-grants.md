# Folder grants and deny (C6a)

[Plans](README.md) · [Completion contracts](unified-completion-contracts.md#c6-projects-folders-and-collaboration) · [Transition installation](transition-installation.md)

Status: **design adopted on 2026-11-09**; C6a-1 implemented locally. First slice
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

- Create and revoke require the current control lease and an open admission
  fence (no transition pending). Each change advances the runner epoch, which
  invalidates old approvals, and stops the live runner and isolated terminals;
  the next start uses the new policy. Stopped work is not restarted.
- The reply reports the grant, whether a runner or terminals were stopped, and
  `confirmsContainment` (native Linux only). Elsewhere, descendants of the
  stopped runner are unprovable, as in C2.
- Transitions keep a conversation's grants; the target binding gets the same
  explicit grants, and deny still applies.

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

Not yet: Gateway relay, transition carry-over of grants to the target binding,
C1/C2/C3 grant cases (C6a-2) and client interfaces (C6a-3). Native Linux is not
tested here.
