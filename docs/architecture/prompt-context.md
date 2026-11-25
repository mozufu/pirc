# Prompt configuration and Context snapshots

This reference describes the prompt sections and Context snapshots the Rust agent
assembles. User-facing mode configuration is in [Workspace modes](../guides/modes.md).

## Prompt files and authority

A mode lists the prompt sections to render, in order: `base`, `agents:global`,
`agents:workspace`, `agents:project` and the mode's own Markdown `body`. Only the
selected files are read. Coding sessions also receive the approved USER entries
from the gateway as a frozen `## User` feature section (read-only, no MEMORY or
workspaces).

There is no editable global persona or chat-rules file and no gateway prompt
management route. Edits to AGENTS.md or a mode file apply at the next agent
start, not immediately to running agents.

The gateway persistently binds the first chat-node ID across disconnects/restarts.
That node hosts the pots. A second ID receives `409 chat_node_exists` in a
WebSocket registration frame, not an HTTP error after upgrade. Replacement
requires stopping the old node and explicitly releasing its binding in
Settings → Assistant; otherwise the old process may reclaim it. Only the binding
ID is stored at the gateway.

## Section and snapshot contracts

`crates/pirc-agent/src/context.rs` defines `PromptSection`: `id`, `title`, `source`, optional `frozen`, and `text`. Sections join with blank lines; trimming preserves interior whitespace. Features can supply section arrays or a string wrapped with their feature source. Sectioning is for inspection, not permission to reorder or rewrite the provider prompt.

A version-1 `ContextSnapshot` records an ID, timestamp, request model/context window, sections with estimated tokens, the actual provider tool specifications with estimates, optional internal capability metadata, and input-usage buckets. The hybrid surface's provider tools and script capabilities are distinct: capability metadata is not an extra provider schema list.

Estimates use the message estimator. Observational-memory tokens are allocated out of compaction-summary messages, bounded by their size, rather than counted twice. USER/MEMORY prompt sections remain system tokens. Matching provider usage supplies reported input including cache reads/writes, not output; the scale is reported input divided by estimated input. Remaining space uses the snapshot's request model window. These are approximate allocations, not exact tokenizer attribution.

## Node-local storage and relay

The agent retains `lastContext` and atomically replaces `<sessionDir>/context.json` with a mode-0600 exclusive temporary file and rename. The duplicated prompt and tool content is not appended to `session.jsonl`. Snapshots contain prompt/tool information, not raw conversation or provider credentials. They are removed with the session directory; there is no additional automatic retention policy.

Agent RPC `get_context` returns the live snapshot only below its bounded size allowance (at most 512 KiB). Node `GET /api/sessions/:id/panel/context` tries the live runner with an allowance below the RPC line limit, then falls back to the disk snapshot for large, stopped or older agents. Missing context returns `404 no_context` with a send-a-message-first explanation. The gateway relays under the existing session authorization and does not store the snapshot. Context updates use `panel_changed`.

The web Context panel shows sections, sources, frozen badges, tool definitions and usage. Workspace-readable sources can link to Files; global configuration sources are plain text. Copy all returns the joined prompt. Disk snapshots are labeled with their timestamp, not presented as freshly loaded configuration. Editing/reordering prompts from the inspector is not supported. Native Android inspector scope remains a [backlog decision](../../plans/README.md).

## Regression expectations and provenance

The design requires mode loading/order and fallback tests, byte-preserving section joins, usage allocation without memory double counting, and node-local stopped-agent fallback. These are preservation requirements, not a claim that this documentation change reran the suites.

The historical proposal's transient single-connected-node wording is superseded by persistent ID binding, and its owner wording by gateway/node `allowedUsers`.
