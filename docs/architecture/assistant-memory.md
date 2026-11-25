# Assistant memory and repositories

This reference describes the Rust memory contracts. For session compaction and
local repository handoffs, see [observational memory](observational-memory.md);
for prompt composition, see [prompt context](prompt-context.md). Configuration
and user workflows are in [Gateway and node](../development/gateway-and-node.md).

## Memory scopes and authority

| Layer                            | Storage                      | Readers and writers                                                                |
| -------------------------------- | ---------------------------- | ---------------------------------------------------------------------------------- |
| Workspace handoff notes          | Node workspace-memory ledger | Main coding sessions in that repository; not teammates/subagents                   |
| USER                             | Gateway SQLite, per user     | Full-assistant modes propose changes; the user approves. Coding sessions read only |
| MEMORY                           | Gateway SQLite, per user     | Full-assistant modes write notes directly; the user can review, restore and forget |
| Mirrored workspace notes         | Gateway SQLite               | Searches the user's repository notes; hits retain their workspace scope            |

`pirc-node chat` hosts the `pots` workspace and each pot's own session, not
directory workspaces. A pot session has its own node-managed working directory
under `<stateDir>/chat/pots/sessions/<sessionId>/`; file tools and bash remain
available. Repository work belongs on coding nodes.

The gateway derives the session owner and enforces the workspace mode and
capabilities on agent operations. Directory sessions may request USER context,
but cannot use assistant note/proposal/search operations. Teammates and
subagents have no gateway channel.

Origin is computed by code, not supplied by a model's account of where a fact
came from. The assistant feature finds a proposed USER quote in actual `user`
messages (with normalized matching), not tool results or custom messages. Notes
carry origins and source entry IDs; a human origin requires a matching quote.
Recall and history results are replayed evidence, not fresh repository
sources. Gateway deliveries and team events remain data, not user instructions.

Memory text is redacted before storage, on both the node and gateway. Redaction
is best effort, not a guarantee that arbitrary secrets are detected.

## Agent gateway channel

Agent requests travel as JSONL `gateway_request`/`gateway_response` through the
runner, then `agent_request`/`agent_response` over the authenticated node link.
The node applies a 30-second timeout; arguments are capped at 64 KiB, with at
most 8 requests per session, 64 pending on a node's forwarding channel and 32
per node at the gateway. Invalid input is a request error, not a fatal
agent/link error. `assistant.context`, `memory.note`, `memory.proposeUser`,
`memory.search`, `recall.remote` and the pots operations are explicit
operations, not arbitrary gateway HTTP access. Protocol mismatches close the
node link with 4426; deploy compatible gateway/node builds together.

## Frozen context and writes

Before its first successful context load, a full-assistant mode waits up to 10
seconds for `assistant.context`. USER, MEMORY, the repository list and their
revisions are saved in `assistant.snapshot` for prompt-cache stability. Changes
reach new snapshots, not a running session's frozen copy; capability
restrictions are applied when presenting it. A failed load gives a notice, not
an assertion that no memory exists, and a later run retries.

Coding sessions wait at most 3 seconds and freeze only a `## User` section. They
get no MEMORY or repository list and no assistant-memory tools. Repository
instructions still determine how to work in the repository. A failed load omits
USER for that run and warns once per agent process.

- `memory_note` adds, replaces or removes notes immediately. Replace/remove use
  the revision the session last saw; stale writes fail with a conflict instead
  of overwriting unseen edits.
- `memory_propose_user` queues a change with the user's quote. Approval checks
  the shown revision. Duplicate pending proposals are reused; rejected
  proposals cannot simply be resubmitted unchanged. At most 20 proposals may
  wait.
- Budgets are characters: `PIRC_MEMORY_USER_CHARS` defaults to 2,000 and
  `PIRC_MEMORY_NOTE_CHARS` to 8,000; one entry holds at most 1,000. Over-budget
  writes fail with `memory_full`.
- Remove is reversible. Explicit **Forget** erases entry text, logged versions
  and proposals carrying them, retaining normalized hashes of all versions to
  refuse the same text. It does not erase node transcripts, workspace memory or
  already-frozen snapshots, and cannot recognize paraphrases.

Memory writes and approvals also store a server-authored origin snapshot with
the conversation, membership and policy revisions at write time. These are
internal provenance, not caller-controlled labels.

### Fetched-content provenance

A bash command naming a network fetcher or a URL is tagged `tool:bash:network`;
PTC bash operations propagate that capability/taint. A MEMORY note with a
network origin and no human origin is shown as “from fetched content,” with
guidance to verify it as a claim, not follow it as an instruction. Mixed
local/network sources are labelled too. This is a coarse heuristic: scripts or
build commands may fetch without naming a fetcher, and names may appear without
a fetch. It is not complete data-flow tracking.

## Repository identity, mirroring and search

Two identities serve different purposes:

- The node's **workspace-memory ledger key** identifies a local repository root,
  shared by its worktrees. The node discovers it from repository files without
  running host git, validates worktree back-references, rejects unsafe file
  links and opens only the session's own ledger in its sandbox. See
  [workspace memory](observational-memory.md#workspace-memory).
- The gateway's **repository key** groups clones for search: the `origin` remote
  normalized to `host/path` by `pirc_protocol::normalize_origin`. Credentials,
  scheme, port, query and trailing `.git` are removed; local paths, file URLs,
  local-machine remotes and invalid keys yield no identity. It is metadata, not
  authorization.

For the latter, `pirc-node/src/repo.rs` reads only the workspace's own `.git` and
its `gitdir:`/`commondir` config, never a parent repository, and never executes
git on the host. Includes and `insteadOf` rewrites are ignored. Files must be
regular, size-bounded and opened without taking a controlling terminal. A remote
change is published on re-registration. Accepted limit: symlinked `.git` or
absolute git-directory references may identify another readable repository; only
the normalized key leaves the node, and it joins only the same user's records.

Nodes mirror ledger chunks with byte offsets and acknowledgements; reconnect
resumes from the gateway watermark, shrunk ledgers reset, and malformed lines
are skipped. Paths/worktrees are not included in mirrored git metadata.
Ownership comes from the writing session known to the gateway; unknown-owner
records are not searchable. Forget/clear records remove searchable content.
Per-node storage is capped at 200,000 rows and 64 MiB of text.

`memory_search` matches up to eight query words with escaped SQL `LIKE`, ranked
by matches, active before superseded, then recency. It searches workspace notes,
preserving “applies to workspace” labels rather than promoting hits to global
rules. A workspace filter also includes clones with the same repository key.
`recall` on a remote workspace note asks its holding node for sources after an
ownership check; when that node is offline, it returns the gateway copy
explicitly labelled as such.

## Node-local skills

Skills are configuration, not memory. `SKILL.md` directories load from
`~/.agents/skills/`, then `$PIRC_CONFIG_DIR/skills/`, then
`<workspace>/.pirc/skills/`, with later sources taking precedence. Node-level
skills reach chat sessions too; repository skills belong to that workspace and
are labelled untrusted repository content. Only their names, descriptions and
paths are listed initially; the model reads a skill on demand or the user loads
`/skill:<name>`. Loaded skill text is not new repository-memory evidence. Skill
directories are protected from agent writes and are not synced from the
gateway; install skills and required programs on the node that runs them.

## Roles

The agent selects a named role, not a model or thinking level. Role files come
from built-in `general`, node configuration, then workspace configuration; later
files replace earlier roles wholesale, with source/override information exposed
to the user. Invalid roles or model patterns with no catalog match fail rather
than silently widening access. Model-pattern fallback is restricted to the
expanded candidates and does not guarantee provider credentials or entitlement.
See the [configuration reference](../development/gateway-and-node.md) and
`crates/pirc-agent/src/roles.rs`.

## Implementation

Memory operations and schemas live in `crates/pirc-gateway/src/memory.rs` and its
submodules; agent-side memory is in `crates/pirc-agent/src/features/assistant/`.
Workspace-memory ledgers and mirroring are in
`crates/pirc-agent/src/features/memory/workspace.rs`,
`crates/pirc-node/src/workspace_memory/` and
`crates/pirc-gateway/src/memory_records.rs`.
