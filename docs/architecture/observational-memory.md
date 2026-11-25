# Session handoffs and independent memory

The session uses one structured handoff plus recent raw history. Repository knowledge is extracted independently from complete original interactions. Chat personal memory and Work repository knowledge refresh as separate feature-owned blocks at model-turn boundaries. Original public source text remains available through current-session history tools and authorized dedicated cross-session resolvers.

The [four-phase implementation and acceptance contract](../development/historical-records.md#retired-plans-2026-11-24) records file ownership, data flow, budgets, coverage, failure recovery, compatibility and controlled activation. The legacy per-session observational-memory format (Observer, Reflector, Dropper and promotion workers, the session ledger and its panel) has been removed; repository knowledge is extracted independently as described here.

Work knowledge crosses authorized sessions/worktrees of the same repository; a session handoff remains local. The newer mode system may expose approved USER preferences to Work, while personal Chat MEMORY remains separate. Memory text never grants fresh permission.

Existing repository ledgers remain read-only until an explicit cold cutover with all older writers stopped. Cutover boundaries are not processing receipts. Activation and deployment require a separate operational decision. Neither was performed by the implementation work.

## Repository memory settings

`features.workspaceMemory` in the node's global config controls repository extraction. Unknown keys are reported and ignored; invalid control flags fail closed (`enabled` becomes false, `passive` true) while valid fields remain in effect.

| Key                   | Default    | Meaning                                                                                               |
| --------------------- | ---------- | ----------------------------------------------------------------------------------------------------- |
| `enabled`             | `true`     | Extract and show repository notes. A mode must also enable `workspace_memory` and `repository`.       |
| `passive`             | `false`    | Stop automatic extraction at turn boundaries; `/om:workspace` commands still work.                    |
| `model`               | unset      | `{provider, id, thinking?}` for extraction. Unset uses the session model.                             |
| `fallbackModels`      | `[]`       | Tried in order while the preferred model cools down.                                                  |
| `missingModelPolicy`  | `fallback` | `fallback` uses the session model; `error` stops extraction when a configured model does not resolve. |
| `maxTokens`           | `3000`     | Budget for the notes shown to a session, and the extraction target.                                   |
| `rateLimitCooldownMs` | `900000`   | How long a rate-limited extraction model is skipped.                                                  |

## Activation status and large histories

The Web and Android memory panels expose repository write activation separately
from session handoff state. Before cutover, existing notes remain readable but
`/om:workspace sync` and `catchup` report that writing is not activated; zero
processed interactions is not a successful activation. Stop all old node,
standalone and child writers before explicitly running
`/om:workspace cold --writers-stopped`. A busy peer or runner manager refuses
cutover without waiting on another runner's lifecycle lock. Retry after those
writers have stopped. This does not automatically activate any deployed ledger.

Cold cutover also checks the Node's durable approved-host-command resource
inventory, including the caller's own commands and owners whose session/runner
has disappeared. Overlapping unresolved ranges, unknown legacy ranges and
inventory failures refuse initialization; a known independent range does not.
Legacy writer preparation holds the same exclusion while repairing an incomplete
tail. Checked append refuses an unrepaired tail (`journal_repair_required`) rather
than changing bytes before its admission check. The final writer check holds Node
admission until the journal append and sync complete, preventing a new host launch between that check and the commit. The
admission guard is released before the final journal read; runner checks remain
nonblocking. Host approval encountering a busy runner reports
`host_admission_busy` and does not reserve or spawn a command.

An acknowledged immutable cutover job remains committed on retry even if new
work has since started; it is not applied again. Unknown responses still retain
the original job for reconciliation. The `--writers-stopped` requirement remains:
this inventory cannot prove that untracked old processes, arbitrary detached
host children or writers on another Node have stopped. Memory source ownership,
deletions, clear/forget rules and checkpoint recovery isolation are unchanged.

Routine context requests no longer capture all history boundaries. Only an
explicit clear preparation requests `includeBoundaries`; cold cutover captures
its boundaries on the host. Control metadata reads authorized session headers,
while notes, extraction and mutations still validate the full relevant branches.
Parsed source branches use a bounded request-local cache: exceeding 64 MiB across
multiple source files evicts parsed branches instead of disabling repository
memory. Source fingerprints survive eviction, so changed/deleted/reassigned
sources still invalidate delivery or commit. The existing per-file 64 MiB journal
limit and per-interaction extraction budget remain in effect.

Recovery workspaces continue to reject repository-memory access. These changes
do not import original repository memory into a checkpoint continuation or grant
access across owners, modes, or deleted sessions.
