# Reusable LLM foundations: extraction checkpoint

[Architecture](README.md) · [Model backends](backend-auth.md) · [pots guide](../guides/pots.md) · [Plan and remaining gates](../development/historical-records.md#retired-plans-2026-11-24)

Status: staged local implementation, 2026-10-24. The implementation baseline is
`eb45f71d8fdefb35a796704ebd9ba7accdf098ff`. The user authorized phased code work
following the design review; this is not deployment or crates.io publication
authorization. Workspace packages remain unpublished. The foundation crates are now
code, not just proposed names; the separate `pirc-tool-schema` validation/documentation
crate was added on 2026-10-25. Since 2026-10-25 the production agent's run is
driven through `pirc-agent-loop` by a thin adapter (see [the loop section](#loop-host-driven-core-and-the-production-adapter));
the rest of the run's host logic has not moved into the library, and the complete
unified conversation/pots contracts are not delivered by this extraction.

## Boundaries and dependency direction

| Component                   | Current responsibility                                                                                                                                     | Deliberately outside it                                                                                                |
| --------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `pirc-llm-types`            | Message/content/tool/delta/usage/stop/error and compatible model/provider DTOs. Pure serialization leaf.                                                   | HTTP, OAuth, sockets, runtime, environment loading and credential storage.                                             |
| `pirc-llm`                  | Wire request/stream mechanics for six existing transport paths; explicit client/cache/cancellation inputs; optional OAuth helpers.                         | Backend/account selection, Node routing, environment policy, credential persistence and safe user-facing error policy. |
| `pirc-agent-loop`           | Runtime-neutral, host-driven model/tool progression; effects, correlated resumes, generation fences, partial/failure records and explicit cancellation.    | The production run's host logic (streaming, retries, persistence), tools, approvals, write leases, storage and policy. |
| `pirc-tool-schema`          | Compatibility-subset tool validation, schema-to-TypeScript documentation and caller-selected prompt-budget fitting.                                        | Tool execution, PTC routing, authorization, config, storage and async runtime.                                         |
| `pirc-protocol`             | Existing pirc wire envelopes, `InferenceRequest`, `Models`, `InferenceConfig`, limits and Unix socket transport; re-exports shared DTOs.                   | Heavy LLM transport/OAuth dependency.                                                                                  |
| `pirc-providers`            | Gateway backend/catalog/configuration, account resolution, route selection, cache identity, environment/TLS setup and error masking; adapts to `pirc-llm`. | The new generic loop and client-facing task authority.                                                                 |
| Gateway / Node / agent host | Identity, scopes, grants, sessions, pots records, dispatch policy, sandbox, cancellation delivery, memory and checkpoints.                                 | Delegating these authority decisions to a reusable model loop.                                                         |

The deployed inference topology is unchanged: **agent → authenticated Node socket
→ Gateway → provider**. An App does not receive provider secrets or call the new
library to bypass Gateway policy. A standalone library consumer can inject its own
client and adapter; that does not acquire pirc credentials, mounts or grants.

### Pure data does not mean public data

`Provider` and `Model` remain compatibility DTOs with endpoint overrides, headers
and API keys. Extracting them to a serialization-only crate does **not** make them
secret-free. Hosts must select safe projections and retain credential ownership.
Existing Debug masking is not a sanitizer for arbitrary URLs or opaque objects.
A future metadata/credential split is still a separate compatibility change.

`serde_json/preserve_order` is enabled directly. Fixed serialized fixtures cover
ordered nested maps/tool schemas, enum spellings, defaults and omitted-versus-null
fields. Protocol integration fixtures prove re-export type identity and unchanged
routing/catalog/socket envelopes. The private opaque-details deserializer remains
at the data boundary rather than creating a reverse protocol dependency.

## Tool schema validation and documentation

[`pirc-tool-schema`](../../crates/pirc-tool-schema/README.md) is independently
usable from schema/description metadata: no agent `Tool` trait, protocol, config,
JavaScript VM or async runtime. It depends only on ordered `serde_json` and
`regress` for ECMAScript schema patterns. It exports the existing compatibility-
subset validator, schema-to-TypeScript projection, compact/full signatures,
bounded summaries and deterministic UTF-16 prompt-budget fitting. This is not
full JSON Schema; unsupported keywords are ignored and existing validation
quirks are documented. Rendering is documentation, not validation or authority.

Pirc wrappers use this crate while retaining core capability lists, default
budgets, PTC routing, common-result conventions and tool-specific caveats.
Validation still runs in the host's existing policy chain; extraction does not
grant execution or change hook/approval/write-lease order.

## Transport API and feature composition

`pirc-llm` defaults to **no transport and no OAuth**. Public wire features are:

- `openai-chat`
- `anthropic-messages` — preserves both native and Pi paths
- `openai-completions`
- `openai-responses`
- `openai-codex-responses`
- `oauth` — independent, default off; subscription-token inference does not
  require login-flow code

There are five wire feature names and six routes because the Anthropic feature
contains two intentionally distinct paths. They are not deduplicated into one
supposedly equivalent serializer. `pirc-providers` explicitly enables all required
wire features and OAuth so existing pirc backend choices remain available.

`Transport::new(reqwest::Client, long_cache_retention)` takes a host-constructed
client. The host supplies TLS/provider/trust/proxy policy; library construction
neither reads environment settings nor installs a global crypto provider.
`StreamRequest` carries neutral messages/model/provider configuration, an opaque
cache/session identity, an optional URL-variable resolver and an explicit Codex
User-Agent value. Platform/architecture and OS-release fingerprint discovery stays
in the pirc host adapter, not library filesystem/process probes. `Route` selects one
wire path explicitly. The library does not choose an account or fall back to a
more expensive provider. A disabled wire route returns an error, not another route.

`Transport::run` accepts a watch cancellation generation and an ordered synchronous
stream callback, returning the canonical final `AssistantMessage`. Stale
cancellation is checked before HTTP begins; cancellation suppresses further deltas
and retains available partial content/usage. Dropping the future cancels its HTTP
work. Native raw provider errors can contain sensitive bodies; the pirc adapter
continues to mask them before publication. Callback signatures currently require
`Send`; the runtime-neutral loop's separate local proof is not proof that the
transport accepts arbitrary non-Send callbacks.

The pirc adapter retains `PI_CACHE_RETENTION`, existing client/global TLS setup,
cache identity derived from Node/session/provider, route compatibility and error
redaction. Moving those host concerns back into the library would regress the
boundary. Explicit client injection also does not erase environment behavior
already chosen by a caller's client builder.

## Optional OAuth

The optional OAuth module provides PKCE, Anthropic/Codex authorization-code flows,
GitHub Copilot device/token flows, refresh and callback presentation helpers.
Callers pass an HTTP client, explicit endpoints/callback address, presentation
hooks and host-selected Copilot policy IDs. An empty policy-ID list causes no
policy-enable request. Backend-specific catalog discovery remains with pirc.

Credentials are an opaque, potentially secret-bearing value map, not a credential
store. Backend identity, login/refresh scheduling, validation, encrypted/private
persistence and error presentation remain host responsibilities. Instantiating a
transport does not start a listener. Explicit OAuth login can bind its configured
localhost callback; RAII/drop cancellation closes it and aborts pending callback
connections. There is not yet a pluggable callback-server factory. These helpers
are provider-subscription authentication, not App sign-in or a new pirc listener.

Synthetic local endpoints prove mechanics without real accounts. No real login,
provider credentials, paid evaluation or remote publication was performed for this
checkpoint.

## Loop: host-driven core and the production adapter

The new reducer returns effects; it never executes a tool itself:

1. At Idle, `advance` admits host input and yields one `Step::Model`.
2. While streaming, the core builds the attempt's partial from the deltas it is
   given (`stream_start`/`stream_delta`, block boundaries only), or the host
   supplies `Progress` with a delta and its own full snapshot. Partial content
   does not authorize tools; a successful final ToolUse reply yields correlated
   calls once.
3. Host code validates authority, obtains approval/resources and executes effects.
   Results can arrive in parallel order, but history retains call order and the
   next model effect waits for every result. Duplicate/stale resumes are rejected.
4. An ordinary reply returns Idle, not Done. Only the host's completion checks
   allow explicit completion. Failure suspends with typed/raw metadata and partial
   usage; retries, compaction and safe error publication remain host decisions.
5. Cancellation is terminal/idempotent and returns operations the host must abort.
   A greater-generation rebind fences callbacks and carries a trusted host notice
   without silently restarting work. Unresolved tool outcomes are Unknown, not a
   claim that external effects were undone.

Tickets identify one live loop instance, not durable globally unique commands.
There is no journal/restart protocol or exactly-once external-effects guarantee.
The host must check generation immediately before dispatch, deliver actual aborts
and enforce mount/lock revocation. A reducer cannot close a remote process or
revoke an already-open file descriptor by changing state.

`pirc-agent::Agent::run` drives its run through this core via
[`run_loop.rs`](../../crates/pirc-agent/src/run_loop.rs) (cut over in `a5485cc8`).
Each model call takes a ticket; the final reply goes through `finish_model`; tool
calls come from the validated `Step::Tools` batch and each result is fenced by its
call key; an overflow compaction is `ReplaceHistory`; and the run ends in an
explicit terminal state (`Completed`, `Cancelled` or `Failed`). The adapter also
feeds the core each streamed delta (the core keeps the partial at content-block
boundaries, so neither copies it per delta) and reports the running call's
waits: dialogs (`Approval` inside the auto-mode gate, otherwise
`Other("dialog")`) and the write lease (`Resource`). The adapter emits and
writes nothing: the event trace and the session store are unchanged, and requests
are still built from the session store, not from the core's history. The core's
history is shared with model requests as `Arc<Vec<Message>>` (copy-on-write), so
dropping a request copies nothing.

Where the core is stricter than the agent, the agent's behavior wins. Tool-use
replies with empty or repeated call ids, or with no calls, still run as listed,
outside the fence (`supersede`). An interrupted turn supersedes its request
instead of cancelling the run. Retries stay inside the agent's `stream`, so the
core never sees `Recovery::Retry`. A session that refuses a write ends the run at
once (`3914e9ec`).

The crate also holds the message-only helpers the agent used to carry itself:
error classification (`Failure::of_reply`, `is_retryable`,
`is_context_overflow`, which the agent's retry and overflow decisions call),
provider-facing history repair (`history::project`, behind the agent's
`sanitize_history`; the agent's `tool_history` pairs calls through
`history::Pairing` and adds its `ptc` operation evidence), the streamed
`Partial`, and the not-run tool outcome texts (`ToolOutcome::not_run`). They
classify and repair; they decide nothing. Token estimation and compaction cut
points stay in the agent: they need pirc's JavaScript-compatible text helpers
(`pirc-config`) and pirc's custom message types.

Overlapping call waits now live in the core: `begin_wait` returns an opaque
`WaitToken`, `finish_wait` ends only that wait, and `waiting_all` retains every
reason. Tokens from other runs cannot clear newer waits. The adapter's RAII
guard simply forwards the token; no global wait counter or overlapping-wait
stack remains in the agent. Legacy single-slot wait APIs remain independent.

History rewriting is memory-strategy-independent: snapshot-bound
`history::Rewrite` can insert retrieved context, replace a range with a summary,
or drop old turns. Strict source/candidate checks preserve whole tool batches;
stale plans fail atomically. `rewrite_history` is Idle-only and starts nothing.
For the model request emitted immediately after tool completion, the host can
explicitly call `rewrite_request` before dispatch and receive a fresh ticket;
it must discard the old effect and check exact ticket identity, not generation
alone (`is_current_model`). Existing streams are not silently restarted. This
is not storage, retrieval, summarization or a provenance/permission system.

Pirc shares only the lazy metadata-preserving `history::replace_prefix` projection
in `SessionStore::context_entries_of`: snapshot selection, rich-journal safety,
summary construction, entry IDs, OM compatibility and downstream provider repair
remain host-owned. Rewriting the adapter's run record does not rewrite pirc's
request context. See the crate's `memory` example for two non-OM strategies.

The adapter has moved none of the following; they remain host-owned production
logic: before-end persistence/message ordering, role fallback, retry
decisions/backoff, redaction, context preparation/compaction, sequential
tools through validation/hooks/approval/write leases, feature hooks, queues,
budgets and completion waits. Progress and waits are bookkeeping the agent does
not read; a refused update is dropped, not a run error. Fake parallel-result
tests do not enable parallel production tools. See the
[crate contract](../../crates/pirc-agent-loop/README.md) for the complete API and
the local `Rc`/`RefCell` versus separate Send examples.

## Unreleased pots execution boundary

The explicit pots execution adapter is host-owned in Gateway/Node, not part of
`pirc-agent-loop` or `pirc-llm`. Atomic task reservation, authority/budget checks,
a dedicated session binding and a backend-only `PotsRequest` link frame precede
Node delivery. A Node SQLite ledger retains dispatch identity, immutable instruction,
evidence expiry and control generations. Its send claim is at-most-once and
fail-closed on uncertain outcomes; recovery never automatically repeats execution.
See [pots](../guides/pots.md) for controls, limitations and upgrade fences. The
historical no-dispatch checkpoint/gates below are not current feature limitations.

## Verification actually run

These are local checkpoint results, not deployment or real-provider acceptance.
Later code changes must rerun the relevant gates.

2026-10-25 wait/schema/history follow-up: 44 loop tests, 11 tool-schema tests
(including the README doctest), 413 agent library tests and 34 PTC runtime tests
passed. Tool-schema tests and strict all-target clippy also passed in an isolated
copy with no other pirc crates. The local/Send/memory examples ran. Strict workspace
all-target clippy and formatting passed. Rebuilt debug Gateway/Node binaries
passed 49 conformance cases across ten suites (agent loop order, PTC/tools,
memory/compaction, core/store and team), with golden updates disabled. These
focused gates do not replace the historical full-workspace failures below; the
full browser/sandbox/transport matrix was not rerun for this follow-up.

| Gate                         | Recorded result                                                                                                                                                                                                                            |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Pure-type isolated workspace | Passed offline tree/check/test/strict clippy in a copied workspace containing only leaf + protocol: 4 fixed-byte leaf fixtures, 19 protocol unit tests and 3 identity/envelope tests. No HTTP/OAuth/runtime in the normal dependency tree. |
| Transport compatibility      | Existing 260-scenario TypeScript parity suite, 5 cancellation/drop cases and 3 TLS distrust regressions passed after extraction; backend tests passed.                                                                                     |
| Explicit host consumer       | Independent default-feature external consumer tree/check passed without HTTP/runtime/OAuth; all-wire consumer compiled and ran with an explicitly preconfigured TLS client and no global provider installation.                            |
| OAuth mechanics              | 17 local synthetic tests passed, including PKCE, browser/pasted callbacks, device flow, refresh, empty policy-ID behavior and callback cancellation/port release.                                                                          |
| Loop checkpoint              | 16 tests passed; local and Send examples both ran successfully; focused fmt and all-target strict clippy passed. Normal dependencies contain no HTTP/runtime.                                                                              |
| pots tracking checkpoint     | 22 focused store/API/host/migration tests passed; enclosing Gateway suite passed 178 tests, including 1009-to-1010 migration. This does not test an execution adapter: none is installed.                                                  |
| Native Android tracking      | 31 focused/regression tests passed (11 new pots cases), with changed production/test analysis clean. This is not APK, physical-device or push acceptance.                                                                                  |
| Existing production agent    | 399 library tests passed at the implementation baseline, before the adapter existed: a regression gate, not evidence of new-loop production parity.                                                                                        |
| Production loop adapter      | 2026-10-25 at `c4df1c27`: 411 agent library tests (incl. adapter, streaming-progress, wait, auto-mode gate and `completionWaitMs` timeout tests) and strict workspace clippy passed.                                                       |
| Conformance with the adapter | Same day, debug executables: 227 passed, including all agent suites and the 7 `agent_loop_order` cases; 5 `node_browser` cases failed as in earlier runs (browser environment; not rerun unsandboxed).                                     |
| Formatting                   | Final `cargo fmt --all --check` passed.                                                                                                                                                                                                    |
| Workspace lint               | `cargo clippy --workspace --all-targets --offline -- -D warnings` passed at the integrated checkpoint.                                                                                                                                     |

**Integrated validation is not clean.** The full workspace run exited 1 with
39 failures across seven targets: Node library (357 passed, 5 failed, 3 ignored),
`browser_corpus` (1 failure), `browser_engine` (19), `browser_manager` (2),
`browser_netio` (9), `sandbox_linux_agent` (2), and `sandbox_persistence` (1).
The five Node library failures were already known; the other newly observed
Chrome/network/sandbox/permission failures look environment-related but have no
baseline proof and are not classified as pre-existing passes or waived. The first executable
conformance run failed the memory scenario with WebSocket 4400 (“This chat is being
deleted”); 13 isolated retries passed. The deletion/event subscription code is
unchanged from the implementation baseline and a missing subscription-readiness
barrier is suspected, but a pre-existing baseline failure was **not** proven. A
full debug-executable conformance run completed with six failures in two targets:
the memory case and five `node_browser` cases (three snapshot mismatches and two
browser-frame timeouts); `node_browser_record` passed. A final fresh-binary focused
rerun of ten suites (agent core/order/Node, backend/OAuth, modes, memory, schedules,
Node sessions and session lifecycle) passed 20 tests with golden updates disabled.
This narrower rerun does not replace the failed full gate. No snapshot/assertion
was weakened and these failures are not waived.

Types have a reproducible isolated gate at
`crates/pirc-llm-types/scripts/check-isolated.sh`. Focused verification commands
and contract details also live in the crate READMEs. Feature tests must use an
isolated consumer/workspace: whole-workspace feature unification can hide unwanted
dependencies. The final `crates/pirc-llm/tests/feature-matrix.sh` gate passed in a
physical copy containing only types + LLM and a temporary target: check/test/strict
clippy for default, each of the five wire features, OAuth-only and all features.
The all-feature run passed 50 unit + 2 explicit-host boundary tests; OAuth-only
passed 14 tests. The default normal tree excludes HTTP/runtime/OAuth dependencies;
wire + OAuth excludes rustls and pirc protocol/config. The host chooses TLS.
Partial-feature warnings were resolved through conditional compilation rather
than suppressed. Disposable matrix outputs are removed on exit.

## Remaining gates

- Production loop adapter follow-ups: waits of unchecked calls (rejected call
  ids) are not tracked; the core keeps the run's replies and tool results
  alongside the session store until the run ends (tool results twice: history
  and tool records). The prompt
  command now waits for initial message admission and reports an uncertain
  outcome after a refused append. Durable Gateway/client reconciliation and
  a proven reopening path are still required.
  Revocation/rebind fences are not used by the production host yet. The five
  `node_browser` conformance cases need a run with a browser outside the sandbox.
- Rerun the isolated transport/OAuth matrix and dependency review after further
  changes; its current pass is not a permanent API/feature-stability guarantee.
  A pluggable OAuth callback-server factory remains unimplemented.
- Complete backend/client/OS acceptance for unified workspace binding, overlapping
  grants, deletion, live-file authorization and pots dispatch. A library test is
  not proof of those authority boundaries.
- Full native Android execution/notification parity and real-device/push acceptance, live-provider smoke
  tests under a separately authorized budget, and any full conformance run not
  explicitly recorded above.
- Public API stabilization, preservation of third-party notices and release
  packaging. The repository adopted AGPL-3.0-only in `e34586b2` (2026-10-26);
  all workspace crates inherit that license.
  No crates.io publication or deployment is implied. Nix verification remains
  waived as previously requested, not passed.
