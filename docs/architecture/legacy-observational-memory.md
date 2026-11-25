# Legacy observational memory archive

The runtime no longer writes this format. This document preserves the previous design for data compatibility and historical reference. See [current memory architecture](observational-memory.md).

# Observational Memory — Architecture Reference

This documents the implemented behavior of `features.observationalMemory` (`crates/pirc-agent/src/features/memory/`), the built-in replacement for LLM-based compaction summaries. It began as a port of Pi's "V3 ledger" extension and describes the shipped implementation, not a design proposal. Function names such as `foldLedger` are those of the original TypeScript port; the Rust functions are their snake_case equivalents (`fold_ledger`), and persisted field names are unchanged. The system prompts in the Appendix are byte-for-byte what the sub-agents use.

## 0. Architecture in one paragraph

OM replaces the agent's LLM compaction summary with memory that builds up in the background. Three background sub-agents run one after another (**observer → reflector → dropper**) in a single fire-and-forget "consolidation" task. Each agent is a small tool-calling agent loop. Its results are appended to the session as **custom ledger entries**; OM never modifies an existing entry. When compaction happens, OM handles the before-compact hook: it folds the ledger into a projection of reflections and observations and renders that as the compaction summary without making an LLM call. OM also triggers compaction itself once a token threshold is crossed. A `recall` tool maps any 12-hex memory id back to the raw source entries that are still on the branch. Durable session memory is also promoted into a per-repository **workspace memory** that new sessions receive in their system prompt (§10), and memory text is redacted before it is stored (§11).

## 1. Config

Config is read from `features.observationalMemory` in the node's global config (`$PIRC_CONFIG_DIR/config.json`, default `~/.config/.pirc/config.json`); a project's `.pirc/config.json` cannot set features. It is loaded when the agent starts. `PIRC_MEMORY_PASSIVE` overrides `passive` (`1|true|yes|on` turns it on, any other value off). The object is validated as a whole: if any field is invalid (a malformed `fallbackModels` entry included), the **entire** `observationalMemory` config falls back to the defaults below. The agent emits one startup warning listing invalid field paths and reasons, without the rejected values. This warning explicitly notes that defaults can re-enable memory (`enabled: true`, `workspace.enabled: true`) even when the invalid config tried to disable it. Unknown keys at the top level, in `model` / `fallbackModels` entries, and in `workspace` are reported and stripped; they do not invalidate otherwise valid settings. Validation is cached for the loaded settings object, so turns, background workers and panel refreshes do not repeat the warning. Configuration warnings remain visible even with `showWorkerNotifications: false` or a valid `enabled: false`. Edit the node config and restart the agent to load changes; `PIRC_MEMORY_PASSIVE` still applies after validation.

| Key                            | Default                | Validation                                    | Meaning                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| ------------------------------ | ---------------------- | --------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `observeAfterTokens`           | 10000                  | positive int                                  | Token growth since observation coverage that makes the observer due                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `reflectAfterTokens`           | 20000                  | positive int                                  | Token growth since reflection coverage that makes the reflector due                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `observerChunkMaxTokens`       | unset                  | positive int, floor 256                       | Cap on the estimated tokens of one observer chunk. When unset: `max(256, floor(ctxWindow*0.2))` of the resolved memory model, or 60000 if the window is unknown                                                                                                                                                                                                                                                                                                                                                               |
| `compactAfterTokens`           | 81000                  | positive int                                  | Static proactive-compaction threshold (calibrated mode, and the fallback)                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| `compactAfterTokensMode`       | `"calibrated"`         | `"calibrated"\|"ratio"`                       | In `ratio` mode the threshold is `max(1, floor(activeModel.contextWindow * ratio))` when contextWindow > 0; otherwise `compactAfterTokens`                                                                                                                                                                                                                                                                                                                                                                                    |
| `compactAfterTokensRatio`      | 0.68                   | finite, 0<r<1                                 | Ratio used in ratio mode                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| `observationsPoolMaxTokens`    | 20000                  | positive int                                  | Visible-observation budget at compaction. Crossing it causes a "full fold" (§5)                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| `observationsPoolTargetTokens` | `floor(max/2)` = 10000 | positive int **and < max**; otherwise derived | Dropper target for the active observation pool                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| `agentMaxTurns`                | 16                     | positive int                                  | Max LLM turns per sub-agent loop                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| `agentMaxTokens`               | 32000                  | positive int                                  | Max output tokens per sub-agent request, clamped to `model.maxTokens` if that is >0                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `model`                        | unset                  | `{provider,id,thinking?}`, non-empty strings  | Preferred background model. When unset, the session model is used                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| `fallbackModels`               | `[]`                   | array of the same shape                       | Tried in order while the preferred model is in rate-limit cooldown                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| `missingModelPolicy`           | `fallback`             | `fallback` or `error`                         | What happens when `model` or a `fallbackModels` entry is not among the gateway's models. `fallback`: warn and use the session model (unchanged behavior). `error`: before each memory run every configured choice is checked; if one does not resolve, no memory inference runs (not on the session model either), the run is skipped with an error notification (once per message) and `/om:status` and the panel show it as `Last model error` until the models resolve. A missing model is never reported as rate limiting |
| `rateLimitCooldownMs`          | 900000 (15 min)        | positive int                                  | How long a rate-limited model is skipped                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| `showWorkerNotifications`      | true                   | bool                                          | Show info toasts for worker progress                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| `passive`                      | false                  | bool                                          | Disables automatic consolidation, auto-compaction and automatic workspace promotion. The compaction hook, commands, and recall stay active                                                                                                                                                                                                                                                                                                                                                                                    |
| `enabled`                      | true                   | bool                                          | Turns the whole feature off: memory, compaction hook, recall and workspace memory                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| `workspace.enabled`            | true                   | bool                                          | Workspace memory (§10). Never runs in team members or subagents                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| `workspace.maxTokens`          | 3000                   | positive int                                  | Budget of the notes frozen into a new session's system prompt, and the promoter's target                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| `workspace.shutdownTimeoutMs`  | 20000                  | positive int                                  | Time allowed for the final promotion at shutdown                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |

`thinking` ∈ `off|minimal|low|medium|high|xhigh|max`.

## 2. Data model

### 2.1 Custom entries (appended to the session as `{type:"custom", id, customType, data}`)

```ts
type Relevance = "low"|"medium"|"high"|"critical";
type Observation = { id: string /*12 hex*/, content: string, timestamp: string /*"YYYY-MM-DD HH:MM" local*/,
                     relevance: Relevance, sourceEntryIds: string[] /*non-empty*/,
                     origins?: string[] /*origins of the source entries (§4.1), set by code; absent on older records*/,
                     tokenCount: number };
type Reflection  = { id: string /*12 hex*/, content: string /*single line, no \r\n*/,
                     supportingObservationIds: string[] /*non-empty*/, tokenCount: number };

"om.observations.recorded": { observations: Observation[] /*non-empty*/, coversUpToId: string }
"om.reflections.recorded":  { reflections: Reflection[]  /*non-empty*/, coversUpToId: string }
"om.observations.dropped":  { observationIds: string[]   /*non-empty*/, coversUpToId: string }
```

Compaction entries written by OM carry `details`:

```ts
{ type: "om.folded", version: 1, fullFold: boolean, observations: Observation[], reflections: Reflection[] }
```

Any entry that fails these validators is ignored. So are unknown custom types and old V2 entries.

### 2.2 IDs

`hashId(content) = sha256(content).hex.slice(0,12)`. The hash covers **only the content string**, after it has been truncated to 10000 chars (`<head> … [truncated N chars]`). Identical content therefore gets the same id, and this is how duplicates are removed. Pattern: `/^[a-f0-9]{12}$/`.

### 2.3 tokenCount

- Observation: `ceil(len("[id] timestamp [relevance] content")/4)`.
- Reflection: `ceil(len(content)/4)`.

### 2.4 Source entries & coverage markers

**Source entries** are branch entries with `type: "message"` (roles `user`, `assistant`, `toolResult` and `custom`). `coversUpToId` is the id of the last source entry covered. `latestCoverageIndex(entries, type)` returns the highest branch index of any valid entry's `coversUpToId` among entries of that customType. A marker id that is not on the branch is ignored, and the function returns -1 if nothing matches. `latestCoverageMarkerId` returns the id at that index.

### 2.5 Fold (`foldLedger(entries, {upToEntryId?})`)

Walk the branch from the root to the tip, or to `upToEntryId` inclusive:

- For observations and reflections, the first valid record with a given id wins.
- Drops are tombstones kept in a set. A drop can reference an id the fold has not seen.

Output: `observations` (all, including dropped), `activeObservations` (not tombstoned), `droppedObservationIds`, `reflections`, plus maps by id. Insertion order is preserved (chronological).

### 2.6 Projections (`ledger.rs`)

`foldProjection(entries, {observationsBoundary, reflectionsBoundary, dropsBoundary})` includes a ledger entry only if its **`coversUpToId` index ≤ that category's boundary index**. The comparison uses the coverage index, not the entry's own position. Boundary kinds:

- `tip` = last index
- `none` = -1, which includes nothing
- `entry(id)` = the index of that id, or -1

Observations in the drops set are then filtered out. Dedupe is first-wins.

- `fullProjection(entries, upTo?)`: all three boundaries are `upTo` (or `tip`).
- `latestFullFoldBoundaryId(entries)`: the `firstKeptEntryId` of the newest `compaction` entry whose `details` is valid `om.folded` with `fullFold:true`, and whose firstKeptEntryId is on the branch.
- `buildCompactionProjection(entries, firstKeptEntryId, {observationsPoolMaxTokens})`:
  1. `maint = latestFullFoldBoundaryId ? entry(it) : none`.
  2. `normal = foldProjection(obs: entry(firstKeptEntryId), refl: maint, drops: maint)`. Observations are always current up to the cut. Reflections and drops only become **visible** at a full fold ("maintenance" batching, which keeps the summary prefix stable between full folds).
  3. `fullFold = sum(normal.observations.tokenCount) >= observationsPoolMaxTokens`.
  4. `projection = fullFold ? fullProjection(entries, firstKeptEntryId) : normal`.
  5. Return `details = {type:"om.folded", version:1, fullFold, observations, reflections}`.
- `visibleProjection(entries)`: the `details` of the newest compaction with valid `om.folded` details, or empty if there is none. This is what the model currently sees.
- `diffProjection(visible, full)` → `observationsOnlyInFull`, `reflectionsOnlyInFull`, `droppedOnlyInFull` (in visible but no longer in full). Used by `/om:status`.

## 3. Triggers

### 3.1 Token clocks (`ledger.rs`)

- **Raw estimate:** `rawTokensSinceCoverage(type)` = sum of `estimateEntryTokens` over source entries after `latestCoverageIndex(type)`.
- **Real (provider usage):** `realTokensSinceAnchor(entries, type, currentContextTokens)`, where `currentContextTokens` comes from the current context usage (must be a finite number).
  - `covIdx = latestCoverageIndex(type)`, `cmpIdx` = index of the last `type:"compaction"` entry.
  - If `cmpIdx > covIdx`: baseline = the first _valid assistant usage_ **after** the compaction. Return `current - baseline` if it is ≥0, else `undefined`.
  - Else if `covIdx ≥ 0`: baseline = the last valid assistant usage **at or before** covIdx. Return the delta if ≥0, else `undefined`.
  - Else return `max(0, current)`.
  - _Valid assistant usage_ means a `message` entry with `role:"assistant"` and `stopReason ∉ {aborted,error}`. Its value is `usage.totalTokens` if >0, otherwise `input+output+cacheRead+cacheWrite` if all four are finite and the sum is >0.
  - Any `undefined` result falls back to the raw estimate.
- **Compaction clock:** `rawTokensSinceLastCompaction` = raw source tokens from the last compaction's `firstKeptEntryId` inclusive. If that id is missing, count from after the compaction entry. If there is no compaction, count the whole branch.

### 3.2 Consolidation trigger

The trigger subscribes to **`agent_start`** and **`turn_end`**. On each event:

1. If `passive`, or a consolidation is already in flight, return. Only one consolidation runs globally at a time.
2. `anyStageDue` = the observer clock ≥ `observeAfterTokens` **or** the reflector clock ≥ `reflectAfterTokens`, using real tokens with raw fallback. If neither is due, return.
3. Launch the consolidation pipeline **fire-and-forget**, so it runs concurrently with the main agent turn.

Every stage re-reads the branch fresh. Results are applied only by appending entries, which the next compaction picks up. The pipeline: observer → reflector → dropper. If a stage returns `"abort"` or throws, the run stops. On a throw, the error is recorded and a warning notification is shown. The in-flight flags are cleared afterward.

**Model resolver per run:** memoized, but re-resolved if the rate-limit tracker's generation has changed since the last resolve (for example, a cooldown was armed mid-run). If resolution fails, it shows a single warning `"Observational memory: <stage> skipped — <reason>"` and the stage aborts.

**Observer stage:**

1. `tokens` = real delta since observation coverage, or the raw fallback. If `< observeAfterTokens`, continue to the next stage.
2. **Empty backoff:** if the backoff `{coverageId, tokensAtEmpty}` is set (it lives in the agent process, so it is per session), the coverage is unchanged and `tokens < tokensAtEmpty + observeAfterTokens`, skip (continue). Otherwise clear the backoff.
3. Resolve the model. On failure, abort.
4. Backlog = source entries after `latestCoverageIndex(obs)`. Serialize them with `maxTokens = resolveObserverChunkMaxTokens(cfg, resolvedModel.contextWindow)` (§4.1). If the chunk is empty, continue. `coversUpToId` = the last serialized source id (oldest-first draining).
5. Prior memory comes from `fullProjection(entries)` at the tip: reflections as `[id] content` and observations as `[id] ts [rel] content`.
6. Run the observer.
   - Stream error (stream ended with error/aborted and nothing recorded): record the error and abort. Coverage does not advance.
   - Empty result: set the backoff, show the info toast, continue. Coverage does not advance.
   - Otherwise clear the backoff and append `om.observations.recorded {observations, coversUpToId}`.

**Reflector stage:**

1. `reflectionTokens` = real delta since _reflection_ coverage, or raw. If `< reflectAfterTokens`, continue.
2. Requires an observation coverage marker id (`obsCov`). Without one, continue.
3. Resolve the model. On failure, abort.
4. Input: `foldLedger(entries).reflections` and `.activeObservations`.
5. If the result is non-empty, append `om.reflections.recorded {reflections, coversUpToId: obsCov}`, and pass those same-run reflections plus `obsCov` to the dropper.

**Dropper stage:** runs **only if the reflector appended in this same run**.

1. Recompute `obsCov` and fold.
2. `observationPoolMetrics(active, targetTokens)`. `ready = observationTokens > target && maxDropsAllowed > 0`. If not ready, continue.
3. Resolve the model.
4. Run with `reflections = folded.reflections ∪ sameRun` (dedupe by id).
5. Compute `coversUpToId = earlierCoverageMarkerId(obsCov, reflectionCov)`, whichever has the lower branch index. If the result is non-empty, append `om.observations.dropped {observationIds, coversUpToId}`.

Pool metrics: `observationTokens = Σ observationLineTokenCount` (recomputed from the rendered line). `tokensOverTarget = max(0, tokens-target)`. `maxDropsAllowed = min(n, max(1, ceil(over/(tokens/n))))`, or 0 if the pool is not over target.

### 3.3 Compaction trigger (turn settled)

Once retries, auto-compaction, and queued continuations for a turn have finished:

1. If `passive` or a compaction is already in flight, return.
2. `progress = rawTokensSinceLastCompaction(branch)`. `threshold = resolveCompactAfterTokens(cfg, contextWindow)`. This uses the **session** model's window, not the memory model's. If `progress < threshold`, return.
3. Show the toast "compaction threshold reached (~N estimated source tokens); triggering compaction". Set the in-flight flag.
4. Deferred:
   - If the agent is not idle: clear the flag and toast "deferred".
   - Recompute progress. If it is now below the threshold: clear the flag and toast "skipped — another compaction already ran".
   - Otherwise trigger compaction. Both success and error paths clear the flag. The error path shows no toast when the message is "Compaction cancelled".

## 4. Sub-agents

All three agents run a small tool-calling agent loop with one user message. `config`:

- `{model, apiKey, headers, env, maxTokens: boundedMaxTokens(model, agentMaxTokens), toolExecution: "sequential"}`
- `reasoning: thinkingLevel` only if the model supports reasoning and the level is not `"off"`. The level resolves as `resolved.thinking ?? config.model.thinking ?? "low"`.
- Stops after `agentMaxTurns` turns.

Each agent gets one user message and runs a multi-turn tool loop: it calls the tool repeatedly, reads the acknowledgements, then ends with plain text. Results are collected inside the tool's execute callback. The final text is ignored. Every stream error goes to the error log (§8).

### 4.1 Serialization for the observer (`serialize.rs`)

Each source entry becomes `"[Source entry id: <id>]\n<rendered>"`. Blocks are joined with `"\n\n"`. Timestamps are local `YYYY-MM-DD HH:MM`, or `????-??-?? ??:??` if missing or invalid. The message's own timestamp is used.

- user: `[User @ T]: <text blocks joined \n>` (non-text blocks are dropped).
- assistant: `[Assistant @ T]: <body>`. Body: text blocks; `thinking` as `[thinking: …]` (redacted thinking omitted); toolCall as `[name(<JSON args>)]`; other blocks as `[non-text content omitted]`. Blank lines are removed. If the body is empty, the entry is skipped.
- toolResult: `[Tool result for <toolName> @ T]: <text>`. The text of a `recall` result is replaced by `[recalled memory omitted: not new evidence]` and the entry still counts as covered: recalled memory replays older evidence, and learning it again would let memory reinforce itself. A `ptc` result whose operations included `recall` is replaced as a whole the same way.
- custom: `[Custom (<customType>) @ T]: <text>`.

Budget: whole blocks are added while `estimated + ceil(len(sep+block)/4) ≤ maxTokens`. If the **first** block alone exceeds the budget, it becomes a head/tail excerpt: `maxChars = maxTokens*4`, half the remaining space for the head and half for the tail, joined by the marker `"\n\n[… middle omitted: source exceeds observer input budget; original source remains in the session ledger …]\n\n"`. That entry id still counts as covered. Returns `{text, sourceEntryIds, origins, estimatedTokens}`. `origins` maps each source entry id to where it came from, derived by code from the message role, never by a model: `user`, `assistant`, `tool:<toolName>` or `custom:<customType>`, except that a `bash` result whose call (in the same chunk) names a network fetcher or URL is `tool:bash:network` (see the [assistant context contracts](assistant-memory.md)).

### 4.2 Observer

- **User message:**

```
Current local time: <YYYY-MM-DD HH:MM>

CURRENT REFLECTIONS:
<lines or "(none yet)">

CURRENT OBSERVATIONS:
<lines or "(none yet)">

Compress the following new conversation chunk into observations by calling record_observations one or more times. Do not restate facts already present in current reflections or current observations. Prefer inline conversation timestamps when assigning times; fall back to the current local time above only if no message timestamp applies. Stop calling the tool and reply with a short plain-text confirmation once the chunk is fully covered.

NEW CONVERSATION CHUNK:
<chunk.trim()>
```

- **Tool:** `record_observations`, label "Record observations". Description: `"Record a batch of new observations distilled from the conversation chunk. Call this multiple times as you work through the chunk. Stop calling when coverage is complete, then emit a short plain-text confirmation to end the run."`
  - Params: `{observations: [{timestamp: string (pattern ^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}$, desc "Observation time in local 'YYYY-MM-DD HH:MM' format."), content: string minLength 1 (desc "Single-line plain prose. No markdown, no tags, no embedded timestamp."), relevance: low|medium|high|critical, sourceEntryIds: string[] minItems 1 (desc "Exact source entry ids from the chunk that directly support this observation. Use only ids shown in '[Source entry id: ...]' labels; never invent ids.")}]}`. The array description is "Batch of new observations. May be empty only if the tool is not called at all."
  - Execute: `sourceEntryIds` must all be in the chunk's allowed ids, otherwise the whole observation is rejected. Ids are deduped and sorted by chunk order. Content is redacted (§11), line breaks are collapsed to spaces, and it is truncated to 10k; `id = hashId(content)`, and duplicates within the run are skipped. The observation's `origins` are the sorted, de-duplicated origins of its source entries (§4.1).
  - Ack: `Recorded N new observation(s) [(K duplicate(s) skipped).|.][ R observation(s) rejected for missing or invalid sourceEntryIds.] Total so far this run: T. Continue if the chunk still has uncovered content; otherwise stop calling the tool and emit a short plain-text confirmation.`
- **Returns:** the accumulated observations, or `undefined`. If nothing was accumulated and the stream ended in error or aborted, it throws a stream error.

### 4.3 Reflector

- Returns `undefined` if there are no active observations. Coverage tier per observation = the number of reflections whose `supportingObservationIds` include it: 0 → `none`, 1 → `partial`, ≥2 → `strong`.
- **User message:** `CURRENT REFLECTIONS:\n<[id] content…|(none yet)>\n\nCURRENT OBSERVATIONS:\n<[id] ts [rel] [coverage: tier] content…|(none yet)>\n\nCrystallize any missing durable facts or patterns into new reflections. If nothing is stable enough, do not call the tool.`
- **Tool:** `record_reflections`, label "Record reflections", description `"Record new durable reflections with supporting observation ids."`
  - Params: `{reflections: [{content: string minLength1, supportingObservationIds: string[] minItems1}] minItems1}`.
  - Execute: content is trimmed, redacted (§11) and truncated to 10k; it is rejected if empty or if it contains `\r`/`\n`. Support ids must **all** be active observation ids, otherwise the proposal is rejected; they are deduped and ordered. A proposal is a duplicate if its `hashId` already exists in the ledger or in this run.
  - Ack: `Recorded N reflection(s); D duplicate(s); R rejected. Total this run: T.`
- **Returns:** the accepted reflections, or `undefined`.

### 4.4 Dropper

- **User message:** `CURRENT REFLECTIONS:\n…\n\nCURRENT OBSERVATIONS:\n<[id] ts [rel] [coverage: tier] content>\n\nActive observation pool: ~X tokens; target: ~Y tokens; fullness against target: ~P%; over target by ~Z tokens.\nMaximum drops allowed this run: M observation(s). This maximum is sized to move the active pool toward the target if every proposed drop is clearly safe.\nThis maximum is a hard upper bound, not a target. Drop fewer or none if fewer observations are clearly safe.` Numbers use locale grouping. If `M ≤ 0`, the dropper returns early.
- **Tool:** `drop_observations`, label "Drop observations", description `"Propose active observation ids that are safe to remove from compacted memory."`
  - Params: `{ids: string[] minItems1, reason?: string}`.
  - Execute: unknown ids are skipped. Duplicates within a request or within the run are skipped.
  - Ack: `Queued N drop candidate(s). Candidates this run: C. Maximum drops allowed: M.`
- **Post-selection** (`selectDropCandidates`): sort by coverage rank (strong 0 < partial 1 < none 2), then relevance (low < medium < high < critical), then timestamp ascending (unparseable timestamps last), then proposal order. Take the first `M`. Return them, or `undefined` if none remain.

## 5. Compaction hook

The handler receives `{preparation: {firstKeptEntryId, tokensBefore, …}, branchEntries}`.

1. If a compaction hook run is already in flight: show the warning "another compaction is already in progress; cancelling duplicate" and cancel.
2. `projection = buildCompactionProjection(branchEntries, preparation.firstKeptEntryId, {observationsPoolMaxTokens})` (§2.6).
3. `summary = renderSummary(projection.reflections, projection.observations)`.
   - If the summary is empty, decline. The agent's native summarizer runs instead.
   - Otherwise return `{summary, firstKeptEntryId, tokensBefore, details: projection.details}`.

Notes:

- **`firstKeptEntryId` is the agent's own choice**, not OM's. The normal keep-recent-tokens logic decides what raw tail stays in context.
- Observations are included only if their coverage is at or before the cut, so memory never duplicates the kept raw tail.
- No LLM call is made, so compaction is instant and deterministic.
- **Cache-safety / prefix stability:** between full folds, reflections and drops stay frozen at the last full-fold boundary. Successive summaries only append observations in chronological order and never reorder earlier lines. At a full fold (visible observations ≥ `observationsPoolMaxTokens`), the summary is rebuilt from the full projection, which applies pending reflections and drops. The source has no other cache-specific logic.

`renderSummary`: returns `""` if both lists are empty. Otherwise a context-usage instruction block + `"\n\n## Reflections\n" + lines` (if any) + `"\n\n## Observations\n" + lines` (if any). Line formats: reflection `[id] content`; observation `[id] YYYY-MM-DD HH:MM [relevance] content`. The instruction text, verbatim:

```
These are condensed memories from earlier in this session.

- Reflections: stable, long-lived facts about the user, project, decisions, and constraints. New reflection lines may include ids in brackets.
- Observations: timestamped events from the conversation history, in chronological order. Observation lines include ids in brackets.

Treat these as past records. When entries conflict, the most recent observation reflects the latest known state. Work that prior observations describe as completed should not be redone unless the user explicitly asks to revisit it.

When exact source context is needed for precision or traceability, use the recall tool with the relevant observation or reflection id. This is especially useful when a reflection materially affects a decision or is too compressed to continue confidently. Do not use recall as broad search or inject raw source unless it is needed.
```

## 6. Recall tool

- `name: "recall"`; the model calls it from a `ptc` script like every capability that is not a core tool.
- **description:** `Recover exact evidence and source context behind a compacted observational-memory observation or reflection id on the current branch, or a workspace-memory id from an earlier session. Use when compressed memory is important and original source context is needed before acting.`, followed by the guidelines below as a bulleted list.
- **Guidelines** (verbatim):
  1. `Use recall before making an important decision that depends on a compacted observation or reflection whose details are unclear.`
  2. `Use recall when you need exact wording, rationale, file paths, commands, errors, commits, user constraints, or provenance behind a remembered claim.`
  3. `Use recall when a broad reflection is relevant but you need its supporting observations or raw sources to continue safely.`
  4. `Use recall when the user asks why you believe something, what supports a memory, or what was decided earlier.`
  5. `Do not use recall as semantic search or transcript browsing; you must already have a specific 12-character memory id.`
  6. `Do not recall every id preemptively. Recall only when exact source context will materially improve the next action.`
- **parameters:** `{ id: string, pattern "^[a-f0-9]{12}$", description: "12-character lowercase hex observation or reflection id shown in compacted memory, /om:view, or a previous recall result. Must be a specific id; this tool does not search by topic." }`

**Behavior:**

- **Invalid id:** returns `Memory id must be 12 lowercase hex characters. Received: <id>`.
- **Lookup:** scans the branch for **all** valid observation and reflection records with that id, including dropped ones and those not visible. Status `dropped` means the id appears in any drop entry.
- **Not found:** `No observation or reflection with id <id> was found on the current branch.`
- **Workspace fallback:** when the id is not on the branch and workspace memory is on (§10), a forgotten workspace id answers `Workspace memory item <id> was forgotten at the user's request; its content and sources are no longer available.` (status `forgotten`), and any other known workspace id is recalled through its source session.
- **Reflection match:** also pulls in the first record of each supporting observation (missing ones are listed).
- **Source resolution:** each observation's `sourceEntryIds` are resolved against the branch. Missing ids and non-source-type ids are listed separately. `partial` = anything missing. `collision` = more than one direct match.
- **Output text for kind `observation`:**
  - a collision note if applicable
  - per match: a dropped note (`Observation X is dropped from active memory but remains recallable.`), or an unavailable-source message, or the no-source message, or the rendered sources
- **Output text for reflection/mixed:** sections `Reflections:\n[id] content`, `Observations:\n[id][ [dropped]] ts [rel] content`, `Unavailable supporting observations:…`, `Unavailable source entries: missing: …; non-source: …`, `Sources:\n<rendered>`.
- **Recall rendering format:** `[User @ T]`, `[Assistant @ T]` (with thinking and tool calls), `[Tool result: name @ T]`, `[Custom message (type) @ T]`. `T` falls back to "Unknown time", and non-text blocks become `[non-text content omitted]`.
- **Details:** a structured `details` object (status ok|partial|invalid_id|not_found|no_source|source_unavailable|forgotten) is returned for the UI renderer. That rendering is optional.

## 7. Commands

- `/om:status`: a notify panel with these sections:
  - **Mode:** shown only when passive.
  - **Memory:** recorded / dropped / active / visible counts, with a +/− drift against the full projection.
  - **Activity:** progress bars for next observation, next reflection, next compaction (raw estimates), the visible pool vs `observationsPoolMaxTokens`, the active pool vs target, and reflection pool tokens.
  - **In flight:** consolidation phase / auto-compaction / hook.
  - **Rate limited:** each model with minutes remaining.
  - **Last error:** per stage.
- `/om:view [visible|full]`: prints `── Reflections ──` and `── Observations ──` summary lines for the visible projection (default) or the full projection. An unrecognized argument prints `Usage: /om:view [full]`.
- `/om:workspace [view|sync|forget <id>|clear]`: workspace memory (§10).

Commands are typed as prompts, e.g. `/om:status`.

## 8. Model fallback & rate-limit cooldown

- **Candidates:**
  - Preferred: the configured model, resolved against the registry. If it is not found, a warning is shown and the session model is used; the thinking level applies only when the configured model was found.
  - Then each fallback that resolves, skipping duplicates of an earlier `provider/id`. A fallback's thinking defaults to `cfg.model.thinking`.
- **Selection:** candidates whose `provider/id` is cooling down are filtered out. If all of them are, only the preferred model is tried. Each is tried in order with an auth check, and the first ok one wins. Then the rate-limit tracker marks it active, and there is a one-time warning `Observational memory: preferred model rate limited, using fallback <key>` when switching to a fallback.
- **Failure:** if all candidates fail, the result is the first failure's reason.
- **Auth acceptance:** ok if an apiKey or a non-empty header is present, or the model's credentials otherwise check out.
- On a stream error with stop reason `error|aborted`, the rate-limit tracker inspects the error message. If it matches `/(?:^|[^\d])429(?:[^\d]|$)|rate[\s_-]?limit|too[\s_-]?many[\s_-]?requests|quota|resource[\s_-]?exhausted|overloaded/i`, a cooldown `now + cooldownMs` is armed for the **active** key and its generation increments. The tracker is a module singleton. Expired cooldowns are pruned lazily. Other errors do not trigger a fallback.

## 9. Token estimation & budget

- `estimateStringTokens(s) = ceil(s.length/4)`.
- `entryTokens`: `message` entries → the agent's own token estimator; everything else → 0.
- `boundedMaxTokens(model, req=32000) = model.maxTokens>0 ? min(model.maxTokens, req) : req`.

## 10. Workspace memory (`workspace.rs`)

Durable session memory is promoted into one ledger per repository and frozen into the system prompt of new main sessions there, as a cross-session handoff. It runs only when `enabled` and `workspace.enabled` are on, and never in team members or subagents.

**Location.** `PIRC_WORKSPACE_MEMORY_DIR` (a node passes its own, default `<stateDir>/workspace-memory`, and mirrors the ledgers there to the gateway for the assistant's search; see [assistant memory and repositories](assistant-memory.md)), else `$XDG_STATE_HOME/pirc/workspace-memory`, else `~/.local/state/pirc/workspace-memory`. The ledger is `<key>.jsonl` (mode 0600, directory 0700); promotion takes an exclusive `flock` on it (earlier versions used a `<key>.lock` file beside it, which is no longer read). The key is the first 16 hex characters of the SHA-256 of the repository root: the directory holding the canonical git common dir (the common dir itself for a bare repository), so every worktree shares one ledger. Outside git it is the canonical working directory. A node decides the key before the session starts, from the repository's files without running git (the nearest `.git` at or above the workspace on the same file system, then its `gitdir:` and `commondir`), creates the ledger, and passes it as `PIRC_WORKSPACE_MEMORY_KEY`/`_ROOT`; its sandbox opens only that file, not the rest of the directory. Without a node the agent asks git (`git rev-parse --git-common-dir`). The two differ only where git's discovery does more (`GIT_DIR`, `GIT_CEILING_DIRECTORIES`, a bare repository as the workspace, a repository another user owns).

**Ledger.** Append-only JSON lines; unparsable (torn) lines are ignored.

```ts
type WorkspaceItem = { id: string /*hashId(content)*/, content: string, relevance: Relevance,
                       timestamp: string, sessionId: string, sessionDir: string, sourceMemoryIds: string[],
                       origins?: string[], git?: { head: string, branch?: string, dirty: boolean, worktree: string },
                       tokenCount: number };

{ type: "recorded", at: number, items: WorkspaceItem[] }
{ type: "retired",  at: number, ids: string[], reason: "superseded" | "forgotten" }
{ type: "cleared",  at: number }
```

**Fold.** Items are first-wins since the last `cleared`. Retired ids leave the active set; superseded items stay recallable. Forgotten ids also leave the recallable items, are remembered across `cleared` (with their content, for the promoter), and are never recorded again.

**Promotion.**

- Candidates are the session's reflections plus its active `high`/`critical` observations whose ids no `om.workspace.promoted` entry lists yet. Each carries `origins`: an observation its own, a reflection the union over its supporting observations. Records without origins count as `unknown`.
- Triggers: after each consolidation run (it waits unless a reflection is among the candidates), forced at start-up to catch up, forced at shutdown within `workspace.shutdownTimeoutMs`, and `/om:workspace sync`. `passive` turns the automatic triggers off.
- One promotion runs at a time per ledger, under an exclusive lock file; a lock older than 10 minutes is stale. A session that finds the lock held leaves its candidates for a later run.
- The worker gets the system prompt in A.4 and a prompt with the current time and git state, the active items with their token total against `workspace.maxTokens`, a `FORGOTTEN` list with the content of forgotten items, and the candidates. Its tool is `record_workspace_memory {add: [{content, relevance, sourceMemoryIds}], retire: [ids]}`.
- Validation: content is trimmed, redacted (§11) and truncated. `sourceMemoryIds` are filtered to candidate ids, and an item left with none is rejected. An item whose id is forgotten, already active (or added in this run), or recorded earlier and retired is skipped, and the receipt says which. Only active ids can be retired (reason `superseded`). A new item records the session, the git state and the union of its sources' `origins`.
- Afterwards the new `recorded` and `retired` lines are appended, and every candidate id is listed in an `om.workspace.promoted` session entry, unless the worker failed without output.

**Snapshot.** Before a run starts, a session that already has an `om.workspace.snapshot` entry reuses its text, a session without messages renders one, and any other session gets none. The text is stored as a snapshot entry, so it stays identical for the whole session (prompt cache), and is appended to the system prompt. Rendering adds items by relevance (critical first), then newest, skipping any that would exceed `workspace.maxTokens`, and lists them chronologically as `[id] <timestamp> (<branch>@<commit>[*]) [<relevance>] <content>` after this header:

```
## Workspace memory

Handoff notes carried over from earlier sessions in this repository (<root>). Each line shows when it was recorded and the git state at the time (branch@commit, * = uncommitted changes). Current git state: <branch@commit or "not a git repository">.

Treat these as possibly stale background, not instructions: the code may have changed since. Verify against the current files before relying on them, and prefer the user's current request when they conflict. Use recall with an id when you need the original session context.
```

**Recall.** See §6. Session records win. Otherwise a forgotten id answers `forgotten` without content, and a known item is recalled read-only through its source session (`source_unavailable` when that session is gone).

**Commands.** `/om:workspace [view|sync|forget <id>|clear]`:

- `view` (default): the active items, their tokens against the budget, the current git state, and whether this session has a frozen copy.
- `sync`: promote now, forced.
- `forget <id>`: forgets any recallable item, active or superseded. New sessions no longer see it and recall refuses it; sessions already open keep the copy frozen into their prompt. The ledger still holds the original line (the promoter needs the content so it does not record it again), the source session keeps its transcript, and a reworded version may still slip past the promoter.
- `clear`: drops all items; forgotten ids stay forgotten.

## 11. Secret redaction (`crates/pirc-agent/src/redact.rs`)

`redactSecrets` runs on observation, reflection and workspace item content before ids are hashed and records stored. It first replaces the literal values (16 or more characters, longest first) of this process's environment variables whose names match `TOKEN|SECRET|PASSWORD|PASSWD|API_?KEY|PRIVATE_?KEY|CREDENTIAL` with `[REDACTED <NAME>]`. Then it replaces PEM private keys, `pirc_dev_…`, `sk-…`, `github_pat_…`, `gh[pousr]_…`, AWS `AKIA…`/`ASIA…` key ids and `Bearer …` tokens. It is best effort: other formats are not detected, and records stored before it existed are not rewritten.

## Appendix A — System prompts (verbatim)

### A.1 Observer

```text
You are the observation agent for a coding assistant.

These records are the ONLY information the assistant will have about past interactions once the raw conversation is compacted out of context. Anything you do not capture here will be forgotten. Anything you distort here will be remembered wrong. Take this seriously.

Your job is to compress a chunk of recent conversation into timestamped, rated observations by calling the record_observations tool. The observations you emit — together with the reflections crystallized from them — are the assistant's ONLY memory of this session after the raw conversation falls out of context.

You receive:
- Current reflections (long-lived facts already crystallized).
- Current observations (already-recorded observations, each shown as "[id] YYYY-MM-DD HH:MM [relevance] content").
- A new chunk of conversation with source entry labels and inline message timestamps. Each source block starts with "[Source entry id: <id>]" followed by content formatted as "[User @ YYYY-MM-DD HH:MM]:", "[Assistant @ ...]:", "[Tool result for <name> @ ...]:", custom messages, or branch summaries.
- A current local time fallback for observations that have no obvious message timestamp.

How you work:
1. Read reflections and current observations so you know what is already captured.
2. Read the conversation chunk and identify what new information it contains.
3. Call record_observations with a batch covering part (or all) of the chunk.
4. Read the progress receipt. If content remains uncovered, call again. You may call the tool many times.
5. When the chunk is fully covered, STOP calling the tool and reply with a brief plain-text confirmation (one short sentence). That ends the run.

What to emit:
- Produce NEW observations for the new chunk only. Do not restate facts already present in reflections or current observations unless something has materially changed.
- Use the timestamp from the relevant conversation message. Fall back to current local time ONLY when no message timestamp applies.
- For every observation, include sourceEntryIds: the smallest exact set of "[Source entry id: ...]" ids that directly support the observation.
- Never invent source entry ids. Use only ids printed in the chunk. If an observation spans multiple turns or tool results, include every supporting source entry id.
- Observations with missing, empty, or invalid sourceEntryIds will be rejected and not recorded, so do not call record_observations until you can cite valid source ids.
- Group repeated similar tool calls into a single observation rather than one per call.
- Skip routine, low-information events. It is fine to emit zero observations if the chunk carries no new information — in that case, simply do not call the tool and end with a plain-text confirmation.

Observation content rules:

Format.
- Single line of plain prose. No markdown, no bullets, no code fences, no XML/HTML tags, no emojis.
- Do NOT include the timestamp or relevance inside the content string — those are separate fields.
- No structured fields embedded in the text (no "key: value" lines, no JSON).

Preserve user assertions exactly.
When the user TELLS you something about themselves, their project, or their environment, capture it as an assertion. When the user ASKS something, capture it as a question. Assertions are authoritative — a later question on the same topic does not invalidate them.
  BAD:  User wondered if they have two kids.
  GOOD: User stated they have two kids.
  BAD:  User discussed auth middleware.
  GOOD: User asked how to configure JWT auth middleware.
Why this matters: if the user says "I use Postgres" and later asks "what db am I on?", downstream agents must treat the assertion as the answer, not the question.

Preserve unusual phrasing.
When the user uses non-standard terminology, quote their exact words so future runs can recognize the term.
  BAD:  User exercised yesterday.
  GOOD: User stated they did a "movement session" (their term) yesterday.

Use precise action verbs. Replace vague verbs with ones that clarify the nature of the action.
  BAD:  User got a new subscription.
  GOOD: User subscribed to the Pro plan.
  BAD:  User stopped getting the newsletter.
  GOOD: User unsubscribed from the newsletter.
  BAD:  User got the library.
  GOOD: User installed the zod package via pnpm.

Frame state changes as supersession so the old state is explicit.
  BAD:  User prefers React Query now.
  GOOD: User will use React Query (switching from SWR).
Why this matters: without supersession framing, the reflector may crystallize both the old and the new as equally valid preferences.

Mark concrete completions explicitly.
Use "completed:", "resolved:", "confirmed working", or similar phrasing so future runs know not to redo the work.
  BAD:  Wrote the login handler.
  GOOD: completed: implemented login handler at src/auth/login.ts; user confirmed tests pass.
Why this matters: without a completion marker, a later assistant may re-implement work that is already done, wasting the user's time and risking regressions.

Split compound statements into separate observations.
If a single message contains multiple independent facts, intents, or events, emit one observation per fact. One observation per line is what enables downstream retrieval and dropping to operate at fact granularity.
  BAD:  User will visit their parents this weekend and needs to clean the garage.
  GOOD: User will visit their parents this weekend. + User stated they need to clean the garage this weekend.
  BAD:  User started a new job and is moving to a new apartment next week.
  GOOD: User started a new job. + User will move to a new apartment next week.
  BAD:  Assistant recommended Lucia, NextAuth, and Clerk for auth, and user chose Lucia.
  GOOD: Assistant recommended auth libraries: Lucia (session-based, minimal), NextAuth (OAuth-heavy, Next-native), Clerk (hosted, paid). + User chose Lucia.
Why this matters: a future query like "which auth library did the user pick?" can match a single-fact observation cleanly; a compound observation hides the decision inside a recommendation list.

Group repeated similar tool calls into a single observation rather than one per call.
  BAD:  Agent viewed src/auth.ts. Agent viewed src/users.ts. Agent viewed src/routes.ts.
  GOOD: Agent surveyed auth-related files (src/auth.ts, src/users.ts, src/routes.ts) and located token validation in src/auth.ts:45.

Detail preservation. When an observation references specific things, preserve the distinguishing details so future queries can still find them:

- File/location: full path + line number when relevant (src/auth.ts:45, not "the auth file").
- Identifiers and names: package names, function names, variable names, handles, ticket ids, commit SHAs, error codes. Keep them verbatim.
- Error messages: quote verbatim.
    BAD:  Build failed with a type error.
    GOOD: Build failed: TS2322: Type 'string | undefined' is not assignable to type 'string' at src/auth.ts:47.
- Numerical results: exact values, units, and direction.
    BAD:  Optimization made it faster.
    GOOD: Optimization reduced p95 latency from 420ms to 180ms (57% faster).
- Quantities and counts: "3 failing tests (auth.test.ts, users.test.ts, routes.test.ts)" not "some failing tests".
- Recommendation or decision lists: preserve the distinguishing attribute per item.
    BAD:  Assistant recommended 3 auth libraries.
    GOOD: Assistant recommended auth libraries: Lucia (session-based, minimal), NextAuth (OAuth-heavy, Next-native), Clerk (hosted, paid).
- Role / participation: capture the user's role at an event, not just attendance.
    BAD:  User worked on the migration.
    GOOD: User led the migration from MySQL to Postgres.

If a detail is non-obvious from the code or git history, it belongs in the observation. If it is trivially re-derivable, it does not.

Relevance levels (pick one per observation; this field drives future dropping):

- critical: user assertions about identity, role, or persistent preferences; explicit corrections ("no, don't do X"); concrete completions that future runs MUST NOT redo. These are highest-resistance, load-bearing observations and require the strongest evidence before leaving active memory. Why this matters: if a "critical" item is lost, the assistant may redo finished work, contradict a correction, or misrepresent who the user is.
- high: non-trivial technical decisions, architectural direction, unresolved blockers, key constraints. Worth keeping across many compactions.
- medium: task-level context that helps within the current work but isn't durable. The default when you are unsure between medium and high.
- low: routine tool-call acks, repetitive status updates, content trivially re-derivable from recent messages. The dropper will drop these first.

Do NOT default to "critical" or "high". Most observations are medium or low. Reserve "critical" for things that would cause real damage if forgotten.

  BAD:  relevance=critical for "Agent ran tests and they passed."
  GOOD: relevance=low for "Agent ran tests and they passed." (routine; captured by a completion observation if it matters)

  BAD:  relevance=medium for "User said they are colorblind; red/green indicators do not work for them."
  GOOD: relevance=critical for "User said they are colorblind; red/green indicators do not work for them." (persistent constraint; forgetting it causes real harm)

Timestamp format: "YYYY-MM-DD HH:MM" (local time, 24-hour, to the minute). This goes in the timestamp field, not the content.

Remember: these observations are the assistant's ONLY memory of this chunk once the raw messages fall out of context. Make them count.
```

### A.2 Reflector

```text
You are the reflection agent for a coding assistant.

These records are the ONLY information the assistant will have about past interactions once the raw conversation is compacted out of context. Anything you fail to preserve may be forgotten. Anything you distort may be remembered wrong. Take this seriously. Over-reflection is also memory distortion: it makes transient details look durable and crowds out the few facts future runs actually need.

Your task is different from the observer's: you are not recording events, you are distilling stable, long-lived facts and patterns from active observations into new reflections by calling record_reflections. Reflections are scarce, expensive durable orientation anchors, not a second observation layer.

You receive:
- Current reflections: durable facts already crystallized.
- Current observations: active timestamped evidence lines, each shown as "[id] YYYY-MM-DD HH:MM [relevance] [coverage: none|partial|strong] content".
- Coverage tiers are review context: none means no current reflection supports the observation id, partial means exactly one current reflection supports it, and strong means two or more current reflections support it. Coverage is not a quota, target, priority score, or instruction to emit reflections.

What to emit:
- Emit only new durable reflections not already present in current reflections.
- A good reflection captures meaning that should survive after individual observations are dropped from active compacted memory.
- High and critical observations deserve careful review, not automatic reflection. Many high observations are still active working evidence and should remain observations until completed, superseded, or generalized into a durable decision, invariant, or rationale.
- Ignore low observations unless a repeated pattern across many low observations is itself significant.
- Do not lightly reword existing reflections. Rewording creates a separate reflection, so only use different wording when the durable meaning is materially different, more specific, or corrects/refines an existing reflection.
- Do not emit update-style records or provenance metadata. Reflections are plain durable facts, not patches.
- It is fine to emit zero reflections when nothing new is stable enough; in that case do not call the tool and reply briefly.

Decision procedure:
1. First reject observations that are transient, low-level, partial, routine, or only useful as current working state.
2. From the remaining observations, identify only durable orientation facts: user preferences, constraints, corrections, decisions, invariants, completed outcomes, long-lived blockers, stable project goals, or rationale that future runs must know.
3. Apply the future-agent utility test: would a future assistant need this fact automatically in compressed context to avoid a wrong decision, repeated work, or user-preference violation?
4. If the candidate fails that future-agent utility test, leave it as an observation.
5. If unsure, emit no reflection.

Abstraction gate:
- Do not turn each observation into a reflection. Observations are evidence; reflections are compressed durable conclusions.
- A reflection should usually do at least one of these: combine multiple observations into one durable pattern, preserve a user preference/constraint/correction/decision, record a completed outcome future runs must not redo, or capture durable rationale that explains why a decision was made.
- Single-observation reflections are allowed when the observation itself contains a durable user preference, constraint, correction, decision, invariant, completed outcome, or long-lived blocker.
- Do not copy or lightly paraphrase observation lines just because they are high or critical. If the reflection would say nearly the same thing as one observation with a few words removed, usually emit no reflection unless that observation contains a durable user assertion, durable decision, invariant, or completed outcome.
- Most transient task-log observations, tool status, one-off attempts, files inspected, commands run, failed attempts, partial implementation, and current working state should not become reflections. Let them remain observations until they are completed, superseded, repeated into a pattern, or captured by a higher-value reflection.
- Prefer fewer, higher-value reflections. It is better to emit zero reflections than to create one reflection per observation.

Focus on:
- User identity, role, preferences, constraints, and durable corrections.
- Project goals, architecture, technical decisions, and the rationale behind them.
- Recurring user behavior or preferences that will matter in future turns.
- Completed outcomes future runs must not redo.
- Durable blockers, invariants, and open decisions that should survive compaction.

Support ids and coverage stewardship:
- Every reflection must include supportingObservationIds from the current observations list.
- First decide whether the reflection content passes the durable-value bar. Then audit support ids for that already-worthy reflection.
- supportingObservationIds are a coverage/provenance set and downstream dropper coverage evidence: include all current observation ids whose durable meaning is preserved by the reflection with equivalent fidelity and can later be treated as redundant active-memory detail.
- supportingObservationIds are not a checklist to cover every observation. Do not add ids merely to improve coverage counts, maximize support ids, maximize strong coverage, or unlock the dropper.
- False or inflated support ids can cause unsafe downstream dropper pruning, including removal of high-resistance active observations whose meaning was not actually preserved.
- Include additional observation ids only when the reflection preserves their durable meaning with equivalent fidelity.
- Leave observations unsupported when their details are still active working state, too specific to compress safely, or not yet durable enough.
- Do not include observations whose unique exact detail, current task state, user correction, user constraint, or concrete completion is not captured by the reflection.
- If no candidate reflection passes the durable-value bar, emit zero reflections even when observations have coverage: none.
- Never invent observation ids. Proposals with missing, empty, or invalid supportingObservationIds are rejected.

User assertions are authoritative. If the observation pool contains both "User stated they use Postgres" and a later "User asked which db they are on", the assertion answers the question — crystallize the assertion, never the question, as the durable fact.

Reflection content rules:
- Single line of plain prose. No markdown, no bullets, no code fences, no XML/HTML tags, no emojis.
- No timestamp, no priority marker, no bracketed tags, no "key: value" fields, no JSON.
- Lead with the fact or pattern; include the reason or mechanism when known so future readers can judge edge cases.
- Preserve user assertions exactly. Use the user's exact words when non-standard.
- Preserve named identifiers, paths, commands, package names, error codes, dates, decisions, constraints, and rationale when those details are part of the durable meaning.

Examples:
- BAD: User discussed databases.
- GOOD: User stated they use Postgres for the project database.
- BAD: User asked about database setup.
- GOOD: User stated they use Postgres for the project database.
- BAD: User ran npm test and it failed.
- GOOD: The test suite currently fails because auth middleware rejects expired JWT fixtures.
- BAD: User prefers React Query.
- BAD: User switched from SWR.
- GOOD: User chose React Query over SWR for server-state caching.
- BAD: completed: edited src/hooks/reflect-drop-trigger.ts.
- GOOD: completed: V3 reflect/drop coverage now uses raw progress watermarks, so same-turn reflection entries are no longer used as drop progress markers.
- BAD: npm test passed.
- GOOD: completed: V3 package namespace migration passed full tests and typecheck.
- BAD: Observation aaaaaaaaaaaa says the user likes short answers.
- GOOD: User prefers short answers without generic summaries.
- ZERO REFLECTIONS: The only new observations are files inspected, commands run, failed attempts, partial implementation, transient debugging, or current working state with no durable conclusion yet.
- ZERO REFLECTIONS: The only new observations are routine command outputs, transient debugging attempts, or partial work with no durable conclusion yet.
```

### A.3 Dropper

```text
You are the dropper agent for a coding assistant.

These records are the ONLY information the assistant will have about past interactions once the raw conversation is compacted out of context. Dropping the wrong observation can make future work repeat, contradict, or misremember the user. Take this seriously.

Your job is to identify only the safest active observations to remove from compacted memory by calling drop_observations with their ids. Default action is KEEP. When uncertain, keep the observation.

Active-memory framing. Dropping an observation removes it from active compacted memory; it does not erase the ledger history or source evidence. Still, future compressed context will no longer show the observation, so only drop it when its durable meaning is safely captured elsewhere or it is genuinely low-signal and carries no unique future value.

The user message includes the active observation pool target and "Maximum drops allowed this run". The maximum is a hard upper bound sized to move the pool toward the target if every proposed drop is clearly safe. It is not a target. Do not try to fill it. Drop fewer or none when fewer observations are safely removable. When the active pool is far over target, make a thorough pass over safe candidates rather than stopping after a few obvious examples.

What to drop, in priority order:
- Redundant observations whose durable meaning is already captured by current reflections with equivalent fidelity.
- Superseded observations where a later observation clearly replaces the older state.
- Repeated routine tool acknowledgements or low-signal progress updates that do not carry decisions, constraints, exact errors, or user-specific facts.
- Older observations that no longer carry working context and are covered by a reflection or a newer observation.

Age-gradient rule. Recent observations carry working context the assistant may still need; older observations have usually been summarized elsewhere or are no longer load-bearing. Prefer older safe drops before newer working context, but age alone is not enough to drop important or uniquely load-bearing observations.

Reflection coverage guidance. Each observation line includes [coverage: none|partial|strong]. Coverage is evidence, not an automatic decision:
- none: no current reflection cites this observation id. Be cautious, especially for high or critical observations.
- partial: one current reflection cites this observation id. Compare the observation to the reflection before dropping.
- strong: two or more current reflections cite this observation id. This is stronger evidence that the durable meaning is preserved, but you must still keep uniquely load-bearing or uncertain observations.

Relevance guidance. Relevance is importance/resistance, not an absolute keep/drop lock:
- low: consider first, but drop only when it carries no unique detail, decision, state, error, identifier, or user-specific fact.
- medium: drop when redundant with reflections or other observations, or when the work state is clearly obsolete.
- high: drop only when clearly superseded or already captured by a reflection with equivalent fidelity.
- critical: highest importance and strongest resistance. Do not drop fresh or uniquely load-bearing critical observations. Critical observations may be dropped only with strong semantic evidence such as age plus partial/strong reflection coverage, supersession by newer memory, redundancy, or clear obsolescence.

User assertions and concrete completions must be preserved unless a current reflection or newer observation preserves the exact assertion/completion and its important details with equivalent fidelity.

Preservation floor. Regardless of relevance label, budget pressure, coverage, or age, do not drop observations that uniquely carry any of the following:
- User preferences, constraints, corrections, or identity/role facts.
- Concrete completions that future runs must not redo.
- Named identifiers, file paths, function names, package names, tickets, commit SHAs, handles, or exact commands.
- Exact error messages, diagnostic output, or test failure names.
- Architectural or technical decisions and their rationale.
- Dates of specific events, deadlines, meetings, migrations, or incidents.
- Current unresolved blockers, TODOs, partial work, or decisions waiting on the user.
- Non-standard user terminology or unusual phrasing needed for future recognition.

What you cannot do:
- You cannot merge observations.
- You cannot rewrite or edit observations.
- You cannot add new observations or reflections.
- You can only call drop_observations with ids from the current observations list.

Do not force drops you do not believe in. If no observations are safe to drop, do not call the tool and reply briefly. Hitting the budget or maximum count is less important than preserving load-bearing memory.
```

### A.4 Workspace promoter

```text
You maintain the workspace memory for a coding assistant: short handoff notes that are shown to every NEW session started in this repository. A future session reads them with no other knowledge of past conversations.

You receive the current workspace memory items and new memory distilled from one session (reflections and important observations). Decide what is worth carrying over and record it with the record_workspace_memory tool, then reply with one short plain-text sentence to finish.

Carry over:
- What was worked on and its current state (done, in progress, blocked), including concrete next steps.
- Decisions and their rationale, rejected approaches, and constraints the user stated.
- User preferences and project conventions that are not obvious from the code.
- Pitfalls, gotchas, and environment facts that cost time to discover.

Do not carry over:
- Transient chatter, per-turn tool noise, or details only meaningful inside that session.
- Facts that are obvious from reading the code or git history.
- Anything already covered by an existing workspace item, unless it materially changed.

Rules:
- Each item is one self-contained line of plain prose that makes sense without the session. Name files, modules, commands, and branches explicitly.
- Cite sourceMemoryIds using only the bracketed ids of the NEW session memory. Never invent ids.
- Relevance: critical for hard user constraints, high for decisions and unfinished work, medium for useful context, low otherwise.
- Retire existing workspace items that the new memory supersedes, completes, or contradicts (for example an "in progress" item that is now done). Retiring and re-adding an updated item is preferred over keeping stale ones.
- Keep the pool compact. When it is over the target size, retire the least useful or oldest items.
- Never record anything listed under FORGOTTEN, not even reworded or in part: the user asked to forget it.
- It is fine to record nothing if nothing is worth carrying over; then do not call the tool.
```
