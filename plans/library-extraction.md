# Reusable Rust foundations (library extraction)

[Plans](README.md) · [pots](pots/README.md) · [Unified conversations](unified-conversations.md) · [Architecture reference](../docs/architecture/reusable-llm.md)

**2026-11-07 integration:** use [C0](unified-completion-contracts.md#c0-authority-current-snapshot-and-scope)
for current product progress, and [C10](unified-completion-contracts.md#c10-delivery-gates-and-integration-boundaries)
for library proof/dependency gates. Old B2/C “no implementation” notes describe
`d4f1efbd`, not the now-delivered U1/U2/U4 foundations. Full loop cleanup is not a
blanket prerequisite for tasks, mounts or App independence. Shipped Rust API facts
remain owned by the linked architecture reference.

Adopted design, 2026-10-24. The user then authorized phased implementation of the
reusable foundations. That does **not** authorize deployment, paid evaluation,
crates.io publication or completing the unified-conversation design wholesale.
The pots product plan, which used to share this file, now lives in [pots](pots/README.md).
See the [accepted design decisions](unified-conversations.md#accepted-specification-review-recommendations-2026-10-24).

## Delivered

Implementation baseline: `eb45f71d`. Current contracts, feature names and the exact
gates that were run are in
[Reusable LLM foundations](../docs/architecture/reusable-llm.md). That file is
the source of truth; the summary below is for orientation only.

- **`pirc-llm-types`** (`24abca5e`): unpublished, serialization-only leaf crate.
  `pirc-protocol` re-exports it, so existing imports and envelopes are unchanged.
  Pure data is not a safe public projection: Provider/Model DTOs may still carry
  credentials.
- **`pirc-llm`** (`24abca5e`, `bb1e8374`): owns the six native/Pi transports.
  The client, cache and cancellation are passed in explicitly, and each wire API
  has its own feature. OAuth is optional and off by default. The runtime contract
  is `run_request(Route, &RunRequest)` with typed outcomes that keep partial
  messages and safe error summaries. pirc keeps accounts, catalogs, credential
  storage, environment/TLS policy, cache identity and error redaction.
- **`pirc-agent-loop`** (`a5485cc8` → `4bb08c91`): executable state-machine core
  with correlated effects, generation fences, partial/error records, cancellation,
  overlapping wait tokens and snapshot-bound history rewrites. The production
  `Agent::run` goes through a thin adapter (`crates/pirc-agent/src/run_loop.rs`)
  that emits and writes nothing itself, so event order and persistence are
  unchanged. Retries, persistence, tools, approvals, queues and completion waits
  stay in the host.
- **`pirc-tool-schema`**: validation for a compatible schema subset, plus
  TypeScript documentation generated from tool metadata. PTC routing, tool policy
  and prompt budgets stay in the agent.

Validation is not clean. Focused gates passed, but the last recorded full
workspace and full conformance runs had environment-looking failures that were
not proven pre-existing. Remaining adapter follow-ups are listed under
[Remaining gates](../docs/architecture/reusable-llm.md#remaining-gates).

All seven accepted follow-up areas are detailed in
[Conversation execution contracts](conversation-execution-contracts.md) and
[pots design](pots/design.md#coordination-contract): capability composition,
foreground/parallel task routing, overlapping grants, Node switching,
lifecycle/deletion, historical/live content and pots coordination. Their state,
authorization and data ownership remain pirc host responsibilities. A generic loop
must expose cancel/resume and correlated results so the host can reject obsolete
work. It must not decide user-message targets, create grants, own deletion/cache
storage or silently restart stopped tasks. Cross-Node context handoff and pots
dispatch use trusted host adapters rather than copying private session stores or
giving the loop provider/account credentials.

## Combined direction

The product should have one conversation/work experience, project-mounted
resources, explicit tasks for substantial work, and **pirc pots**, a persistent
personal assistant that observes, suggests and coordinates within configured
permissions. Reusable crates supply model I/O and a small execution loop; pirc
continues to own projects, tasks, permissions, scheduling and client interaction.

| Layer                       | Responsibility                                                                    | Must remain separate from                                                         |
| --------------------------- | --------------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| Web / App                   | Conversation, project, task and pots views; commands and decision UI              | Provider credentials, authority decisions and background scheduling               |
| Gateway / pirc coordination | Identity, resource grants, task/decision records, pots dispatch and notifications | Generic transport/loop internals                                                  |
| Node / pirc agent host      | Mounts, sandbox, tools, write coordination, features, memory and checkpoints      | Frontend presence or a privileged generic loop                                    |
| Reusable loop               | Model/tool progression, cancellation and explicit suspension points               | Project membership, pots identity, approval policy, storage and notifications     |
| Reusable LLM layer          | Provider request/stream mechanics and optional OAuth flows                        | pirc settings files, Node identities, environment loading and global TLS mutation |

Keep the existing inference route when extracting: agent → Node's authenticated
Unix socket → Gateway → provider. Sharing a crate must not give project agents
provider secrets, make the App call providers directly or bypass Gateway policy.
A Node-side loop can use the existing remote adapter; standalone consumers can
supply a direct model adapter.

## Product requirements clarified by the user

The following are target product requirements. The checkpoint above implements
only the explicitly described subset; it is not blanket approval for every item:

- Configure a conversation workspace at creation. Mount selected existing
  folders, or explicitly create an empty folder under a configured server area.
- A project behaves like an organizational folder and shares one or several
  mounted folders and configuration/rule files with its conversations.
- Leaving the project removes its project-derived mounts and content access.
  Separately granted folder access remains disclosed; an explicit conversation
  folder block overrides overlapping grants and must be enforced by the host.
- Explore a project board/shared memory to help agents communicate and understand
  concurrent work, especially another agent holding a conflicting write lease.
- Recommend tasks for most complex work; long/background and multi-agent work
  should normally require tracked tasks and visible progress.
- pots requirements and references (OpenAI dots, Grok Bot) are in [pots design](pots/design.md).
- App connection security is deferred for a separate design discussion. Flutter
  Web remains an evaluation option.

Detailed journeys and pending decisions are in [Unified conversations](unified-conversations.md).
The user subsequently selected **A** on 2026-10-24: preserve existing conversation
context after project departure and stop project-derived mounts/new access.
The accepted follow-up separately discloses retained independent folder grants.
During an active run, warn first; if the user proceeds, enforce revocation of subsequent
access and notify the agent of the user-initiated change. The agent can decide
whether it needs to ask a follow-up question. These product behaviors are decided;
OS revocation/rebuild and offline-host acknowledgement remain technical design.
Unmounting does not erase retained information or undo completed writes, and a
communication board does not itself prevent concurrent filesystem writes.

## Library handoff: findings checked against this checkout

Handoff baseline: main `aca6eeb` (0.9.3). Reviewed local head before this update:
`1aed8533`; no remote fetch or runtime test was performed for this design pass.
The reported line counts and third-party crate versions were not remeasured.

Confirmed in the current sources:

- Workspace Rust 2024, MSRV 1.97, `publish = false`, `unsafe_code = forbid`.
- `pirc-providers/src/inference.rs` routes six transport implementations. Both
  pi-style and native paths are selected by existing configuration.
- Inference currently reads `PI_CACHE_RETENTION`, installs the default ring TLS
  provider and derives a cache/session identifier from Node, session and provider.
  Error masking belongs to the pirc integration boundary.
- `models_file.rs` calls `pirc_config::env_allowlist::is_secret_env`; settings,
  discovery/catalog integration and environment policy need not enter the library.
- The agent uses local futures and `Rc`/`RefCell`; its loop mixes persistence,
  compaction, retries, feature hooks and event ordering. Generic extraction is a
  more substantial change than relocating provider modules.

### Handoff corrections — still binding constraints

Raised before the first implementation; the delivered checkpoint was built against
them. They remain constraints on further changes. Which of them have proof is
recorded in the architecture reference, not here.

1. **Keep a lightweight dependency graph.** `pirc-protocol` currently needs only
   data/serialization dependencies (plus its existing Linux socket support).
   Re-exporting Provider/Model from an HTTP/OAuth-heavy `pirc-llm` would pull that
   layer into every protocol consumer unless features are carefully separated.
   Recommend pure shared metadata/types at the leaf; endpoint/credential runtime
   configuration in the LLM layer; pirc wire envelopes in `pirc-protocol`.
   Exact Provider/Model placement remains a decision, not a settled move.
2. **The whole inference/models files are not generic types.** `InferenceRequest`
   carries pirc session routing; `Models.inference` and `InferenceConfig` contain
   the private Node socket. `ThinkingLevel` and serde's `opaque::present` helper
   are additional dependencies to classify. Preserve the distinction between a
   missing field and an explicit null. Common types may be re-exported; pirc
   envelopes stay and adapt without changing old wire bytes.
3. **OAuth is not just moving `flows.rs`.** It imports backend `Credentials`,
   `catalog_models`, sibling domain/base-URL helpers and callback-server handling.
   Separate credential DTOs from persistence; inject optional post-login discovery
   and presentation/callback adapters. Model-provider OAuth is unrelated to the
   user's sign-in to the pirc App.
4. **The Send sketch is internally inconsistent.** A `Send + Sync` Transport
   returning `BoxFuture` with a Send callback does not serve the existing local
   agent's non-Send callback/state unchanged. Evaluate a minimal model-source
   interface with local and Send adapters or generic conditional bounds first.
   Do not adopt trait-variant or change runtime scheduling before a small proof
   and an event-order comparison. Send capability does not itself prove ordering.
5. **Specify suspension and resume, not only `next()`.** The proposed five Steps
   omit how to submit approval/tool results, streaming progress, cancellation,
   parallel call correlation and terminal completion. Distinguish idle from done,
   and blocked tools from failed tools. A resume must not execute a tool twice.
   Approval, lock and mount-revocation policy live in the pirc host; a generic
   tool request/result boundary may be cleaner than building pirc policy into
   the core. Host-originated environment changes must be deliverable while a
   run is waiting/streaming, with denied/interrupted results correlated to calls;
   do not let loop resume replay effects under an obsolete workspace generation.
6. **Retain failure information without leaking it.** Preserve partial replies,
   cancellation and structured retry/error reasons in the generic interface.
   The pirc adapter can retain `StopReason::Error` wire behavior and redact errors
   before they reach clients. Do not make raw provider errors safe by assumption.
7. **Compatibility helpers need classification.** JS-like coercion needed for
   existing provider bytes may stay in a private compatibility module initially.
   Host microtask scheduling and pirc config truthiness stay outside the core.
   Deleting every JS-named helper during the move would conflict with parity.
8. **TLS remains an explicit contract.** Inject a configured client/provider or
   use a documented explicit construction path; library construction must not
   install global crypto state. Retain the recently added distrust regression
   and the actual production verifier behavior after changing ownership.

The repository adopted AGPL-3.0-only in `e34586b2` (2026-10-26), inherited by
all workspace crates. Preserve existing third-party attribution/notices when
moving source. External crate publication and its packaging remain separate
owner decisions; no public release is part of this plan. Verify dependency APIs and candidate crate versions separately
if they are selected; the supplied ecosystem comparisons are not acceptance proof.

## Adopted extraction boundary

Adopted crate names and planned responsibilities:

| Crate / adapter              | Planned contents                                                                                                                |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| `pirc-llm-types`             | Pure messages, deltas, tool schemas, stop/error metadata and required neutral value types; ordered serde compatibility          |
| `pirc-llm`                   | Six existing transports initially, HTTP/SSE/parsing, explicit cache settings, injected credentials/client; optional OAuth       |
| `pirc-agent-loop`            | Small model/tool state machine with host-controlled effect/resume boundaries; no pirc session, task board or UI dependencies    |
| Existing `pirc-providers`    | Gateway backend storage, catalogs/configuration, environment policy, cache identity derivation and safe error adaptation        |
| Existing `pirc-agent` / Node | Remote inference adapter, features, memory, team/task integration, scheduling compatibility, sandbox/tools and checkpoint hooks |

Adopt optional OAuth, off by default, and transport features separated by wire API.
The pirc adapter explicitly enables the features it currently needs so extraction
does not disable existing subscription logins or change transport routing. Default-
feature minimal consumers must not require OAuth. Test disabled/enabled OAuth and
intended transport combinations independently: workspace feature unification can
hide missing optional dependencies. Current feature names and boundaries are documented in the architecture reference;
further dependency/API stabilization remains engineering work. Preserve pi/native
paths and their separate fixture comparisons.

A product task can contain many loop runs. pots can coordinate many product
tasks. Neither belongs inside the reusable loop, and neither requires the loop
extraction to be finished before its product behavior can be designed.

## API contracts and integration gates still to close

The original handoff required the contracts below before extraction. The current
crates provide concrete callable checkpoint APIs, but API stabilization and host
integration proofs remain incomplete. Continue this review alongside the product
[specification gaps](unified-conversations.md#specification-review-what-is-not-detailed-enough-2026-10-24).
Current signatures live in the crates and architecture reference; they are not a
claim of a stable published API. Adding a trait alone is not completion.

| Boundary                  | Questions the specification must answer                                                                                         | Required proof                                                                                                                          |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| Shared types              | Which fields are generic; wire-only wrappers; absent/null; ordered JSON; metadata versus endpoint credentials                   | Old fixtures serialize identically; no dependency cycle or unintended HTTP/OAuth in protocol consumers                                  |
| Model adapter             | Request ownership/lifetimes; delta versus partial snapshot callbacks; final reply consistency; backpressure; cancellation owner | Partial, canceled and malformed streams behave predictably without duplicate final messages                                             |
| Errors/retries            | Typed failure categories; partial usage; retryability; masking boundary; behavior after an effect may have occurred             | pirc keeps existing wire/errors; raw credentials/provider responses are not leaked; unknown outcomes are not replayed blindly           |
| Loop suspension           | Stable call IDs; one/many tools; concurrent results; approval/lock waits; continuation input; terminal reason                   | Duplicate/stale resume is refused; suspended work cancels; idle and completed remain distinguishable                                    |
| Host policy changes       | How revocation/stop notices interrupt work; grant-generation checks; preserving conversation on host restart                    | An in-flight old model reply cannot execute a removed-resource tool after rebinding                                                     |
| Scheduling/runtime        | Local and Send requirements; callback bounds; spawn/runtime assumptions; effect ordering                                        | Existing local adapter compiles and preserves conformance; Send consumer works without changing pirc scheduling                         |
| OAuth/client construction | HTTP/TLS ownership; browser/callback presentation; credential refresh/cancel; callback cleanup; optional discovery              | Local synthetic flow tests; no global provider installation, unexpected listeners or credential persistence in the library              |
| Packaging                 | Feature dependency matrix; public exports; internal compatibility helpers; MSRV and notice retention                            | Build default-minimal, OAuth-disabled/enabled and transport feature sets independently; explicitly test pirc opt-in; remain unpublished |

Adopted design sequence: inventory existing request/result/event shapes;
write a minimal local-adapter example and a separate Send-use example as proposed
contracts; define suspension/resume state transitions; then, only when authorized,
implement fake-adapter proofs before moving the full agent loop. Generic-loop
persistence should expose state/effect boundaries the host can journal, without
owning pirc session files or promising exactly-once arbitrary tool effects.

For each extraction change, record the baseline revision and exact fixtures/gates.
Do not approve deduplication of native/pi transports merely because happy-path
answers look alike. Compare request headers/body, cache identity, reasoning/tool
stream semantics, aborts, usage and error behavior separately. Public API names,
type ownership and local/Send strategy need engineering review and proofs; the
user does not need to choose implementation-level boxing or lock algorithms.
Packaging direction is adopted; the feature matrix must verify it without hiding
missing dependencies through workspace unification. The [integrated review](unified-architecture-review.md#adopted-defaults-and-deliberately-deferred-decisions)
separates those choices from numerical settings and engineering decisions still open.

## Combined delivery sequence — target and remaining gates

| Stage                          | Deliverable                                                                                                   | Dependencies / gate                                                                             |
| ------------------------------ | ------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| A. Specify adopted contracts   | Project mounts, departure/revocation, workspace switching, task identity, board/wait protocol, pots authority | Complete remaining contracts/settings in Unified conversations                                  |
| B1. Provider extraction        | Pure types, compatible adapters, then transport and optional OAuth separation                                 | Implement adopted packaging with API/compatibility proof; isolate from product behavior changes |
| B2. Product foundations        | Versioned workspace bindings, mount enforcement, durable tasks/decisions, independent-client state            | Stage A; can use the existing agent loop and provider adapter                                   |
| C. Unified workflow            | Same-conversation work, project resources, meaningful waiting/progress, Web/App contract parity               | Mount transitions, replay prevention and concurrent-writer acceptance                           |
| D. pots                        | Overview and attributed dispatch, then scoped proactive observation/digests ([pots](pots/README.md))          | Tasks, provenance, grants, durable wake-ups and notification reconciliation                     |
| E. Loop extraction             | Fake-adapter core, pirc integration and event-order/conformance checks (adapter in place since 2026-10-25)    | Stable provider boundary plus understood tool-wait/approval/cancel semantics                    |
| F. Optional frontend migration | Flutter Web comparison against current Web on difficult interactions                                          | Separate decision after measurement; not a dependency of App independence                       |

Historical status at `d4f1efbd` (superseded for current progress by C0):

- **B1:** checkpoint delivered (see [Delivered](#delivered)). API stabilization and the feature-matrix rerun remain open.
- **D:** tracking and explicit dispatch are delivered; proactive observation and digests are not. See [pots](pots/README.md#delivered).
- **E:** the production adapter is in place; its follow-ups remain open.
- **A:** contracts are partly specified ([Unified conversations](unified-conversations.md)).
- **B2, C, F:** no implementation checkpoint recorded.

B1/B2 are independent work streams. The later phased implementation authorization
permits the checkpoint above, not automatic execution of every future stage. Keep
integration checkpoints small so a provider
regression can be distinguished from a workspace/task migration regression.
App authentication/connection security remains a separate design gate; APIs and
state flows can be specified now, but no new listener or public port is implied.

## Acceptance gates — focused passes do not close the remaining target

- **Types:** existing decode/round-trip tests plus fixed serialized bytes, field
  ordering, omitted/null fields, enum tags, old session fixtures and tool-schema
  insertion order. Re-exporting a type alone is not byte-compatibility proof.
- **Provider/OAuth:** existing inference/parity/TLS/backend/flow tests; both routing
  paths; canceled and partial streams; cache IDs; redacted errors; feature matrix;
  no direct environment reads or global TLS installation in the new library.
  Inspect transitive client/environment behavior too, not only a grep result.
- **Loop:** fake model tool round trip, progressive deltas, refusal/resume, waiting
  for resources, cancellation while suspended, tool ordering/IDs, overflow handoff,
  retries, completion and no duplicate side effects. Then existing agent tests and
  pirc-conformance with unchanged event ordering.
- **Workspace/project:** multi-root aliases and overlap, revoked mounts, leaving
  while tools/children run, stale queues, unavailable Node, crashes mid-transition,
  project rules and memory access, retained conversation context (decision A),
  cancelable warnings, trusted agent notifications, open-descriptor revocation,
  partial-command effects, old approval rejection and historical/copy limitations.
  No forced user question, silent remount or retargeted retry after removal.
- **Collaboration:** A holds a file, B waits with owner/reason visible, no busy
  polling or false completion; release wakes B; B rereads before editing; cyclic
  waits and stopped owners resolve without forcing unsafe lock expiry.
- **pots and clients:** actor provenance cannot be forged by prompt text; narrowed
  grants remain narrowed through delegation; user takeover fences queued dispatch;
  duplicate approvals, missed push and closed Web do not replay work.
- **Lifecycle/content/pots:** the N4/L5/C6 cases in the conversation contracts and
  the [P7 cases](pots/acceptance.md) cover interrupted Node transitions, owned deletion versus retained recovery
  evidence, live-file reauthorization/account caches, suggestion deduplication and
  user takeover. Extraction must preserve these host boundaries; generic-loop
  tests alone do not establish backend/client or OS enforcement.
- Run workspace tests and clippy at each actual extraction checkpoint, plus the
  focused compatibility gates. Nix verification remains waived as previously
  requested; physical-device/remote-push limitations are not silently cleared.
  Clean disposable test/build outputs after actual runs.

The original design-only update performed no runtime verification. The subsequent
implementation checkpoint and its actually run local gates are recorded in the
current architecture reference. No real OAuth login, deployment or
crate publication was performed. Existing memory/checkpoint authority and the
remaining device, execution-adapter and full-conformance gates are not waived.
