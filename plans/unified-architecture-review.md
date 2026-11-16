# Integrated unified-conversation architecture review

[Plans](README.md) · [Product plan](unified-conversations.md) · [Execution contracts](conversation-execution-contracts.md) · [Library extraction](library-extraction.md) · [pots](pots/README.md)

Review date: 2026-10-24. Scope: Chat/Work unification, projects/tasks/resources,
pots, independent clients and reusable Rust foundations, including their links
to current modes, mobile, memory deletion and checkpoints. This is a review of
that architecture family, not a claim to revalidate every historical plan or
all running code. The original review's fetched `origin/main` baseline was
`aca6eeb6`. After publication, the user accepted the review's recommended defaults
and requested another documentation commit, rebase and push. The adopted choices
below supersede their earlier proposal status; implementation is still separate.

The user authorized this review, corrections and, after verification, a pull/rebase
and push of the local repository commits. That permission does not implement the
new architecture, change deployment permissions, replace Web, publish crates or
create a release. The preceding publication included App fixes with the recorded
verification below. This follow-up changes planning documents only; those earlier
runtime results must not be presented as new tests of the architecture.

## Implementation follow-up (2026-10-27)

The paragraphs above describe the original October 24 review/publication scope.
The user later authorized the staged architecture implementation and has now
requested a pull/rebase and push of accumulated code plus updated plan progress.
First-send persistence, original attachments, Stop/delete/retry recovery and
Web/native Android adoption are implemented through `578f759a`; activation stays
off until the remaining client/process/device and rollout gates pass. Follow the
[current snapshot](unified-conversations.md#current-progress-and-next-delivery-2026-10-28)
for evidence and the open U1–U6 queue. This does not mark the broader contracts
below implemented, or authorize deployment, a Release, Flutter Web or a UI reset.

## Review outcome and corrected contradictions

The product direction is coherent after the corrections below. It can be published
as a planning baseline with explicit implementation gates. It is not yet a complete
implementation specification, and no sandbox/client guarantees are considered
verified merely because they are written down.

| Finding                                                                                                           | Correction                                                                                                                                                             | Acceptance/reference                                             |
| ----------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------- |
| Task required an originating conversation, but tracking a pots suggestion must not create an empty work session   | Separate immutable request/suggestion origin, record owner and optional execution conversation; first authorized dispatch creates/maps the execution conversation once | Task lifecycle in the main plan; [P7-2/P7-3](pots/acceptance.md) |
| A conversation can move projects, but deletion could classify all its memory using today's membership             | Record write-time membership generation for new memory versions/proposals; keep stable original-entry/session provenance and review insufficient legacy evidence       | Memory deletion contract and L5-3                                |
| Project deletion could internally invoke single-chat memory deletion and undo its mixed-history Keep/Edit choices | Project deletion owns one memory cleanup plan; child session cleanup uses that scope and cannot run a second standalone memory purge                                   | L5-3, including crash/retry and moved conversations              |
| Default-off OAuth was labelled undecided while the feature-test gate assumed it was chosen                        | The review first made the gate conditional; subsequent user acceptance adopts optional default-off OAuth and tests for disabled/enabled consumers                      | Library packaging table and API proof gates                      |
| Earlier “keep local/no push” status could be mistaken for the current publication instruction                     | Record the latest review/rebase/push authorization separately from unchanged planning-only implementation scope                                                        | Status paragraphs in the plans                                   |

Other apparent tensions were checked and are intentional distinctions:

- Leaving removes project-derived grants; an independent disclosed file grant can
  survive. Explicitly blocking a folder overrides overlapping grants. This is not
  permission to retain ambient broad reads as a fictitious independent grant.
- Retained context does not promise erasure of previously read data. Fresh resource
  access, known managed cache cleanup and explicit deletion have separate contracts.
- Archive, pause coordination, takeover, stop and deletion have different effects.
  Taking over one task does not kill unrelated work or silently resume stopped work.
- Same visible conversation does not require one surviving OS process. A Node
  switch does not move files, profiles, external effects or recovery authority.
- Reusable-loop extraction supplies mechanics. Project permissions, product tasks,
  memory ownership, provenance and pots authority remain in the pirc host.

## Adopted defaults and deliberately deferred decisions

The user accepted the recommendations after the integrated review. Use the following
planning baseline without asking for the same choices again. Adoption specifies
future behavior; it does not change current grants, enable pots, implement crates
or authorize automatic data migration.

> **Updated 2026-11-16 (N3):** the App sign-in and server exposure row below is kept; "App independent" means no Web front end needs to be open, and the reverse proxy, HTTPS and Gateway boundary stay. See [2026-11-16 direction update](README.md#direction-update-2026-11-16).

| Area                                        | Adopted direction                                                                                                                                                                                                                  | Remaining work                                                                                                                        |
| ------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| Initial cwd and mount permissions           | Explicitly select/show the main folder and its read/write scope, including the managed-empty-workspace choice. New additional folders default to read-only unless explicitly granted writes; preserve existing grants on migration | Binding UI and enforcement; explain effective access when another grant already permits writes                                        |
| Managed empty-folder allocation             | Keep choices in a draft; allocate at first accepted send unless the user explicitly invokes Create folder. Never delete an explicitly created user work folder on draft abandonment                                                | Idempotent allocation, interrupted first send and ownership checks                                                                    |
| Shared notes and board                      | Durable notes have no automatic age-based expiry; explicit removal and existing source/project deletion rules still apply. Separate operational board retention from durable notes and show editor scopes                          | Storage/provenance mapping, editor presets and exact board-retention settings; no invented destructive duration                       |
| pots initial scope and execution            | Use user-selected observation scopes, distinguish progress from full content, and suggest without autonomous dispatch unless an explicit request or standing grant permits it                                                      | Scope selection and grants; no migration/onboarding step silently selects every project or conversation                               |
| pots spending/concurrency and notifications | Require configured finite budgets and bounded concurrency before proactive runs; group nonurgent suggestions into quiet digests/inbox                                                                                              | Actual budget/concurrency values, quiet hours and digest cadence were never specified and remain to configure                         |
| App sign-in and server exposure             | Keep separate security review deferred while preserving independent-client requirements and existing authorization                                                                                                                 | Reopen at native onboarding design; do not choose a new public port or replace authorization now                                      |
| Flutter Web                                 | Keep optional evaluation deferred; compare a measured vertical slice with existing Web before deciding migration                                                                                                                   | No framework replacement authorized                                                                                                   |
| Reusable crates                             | Adopt `pirc-llm-types`, `pirc-llm`, `pirc-agent-loop`; keep provider OAuth optional and off by default, with transport features separated by wire API. pirc explicitly enables required features to preserve its current behavior  | Exact feature names/dependency graph, Rust API/type ownership and local/Send proofs; path dependencies only, no crates.io publication |

### Remaining concrete values and engineering choices

No numerical amounts, time windows or destructive retention periods were proposed
and accepted. Configure finite pots budgets/concurrency before enabling proactive
work; do not interpret an absent setting as unlimited. The runtime design must
provide a complete finite configuration before activation rather than silently
inventing user authorization. Quiet-hour/digest values and board-retention/editor
presets still need concrete proposals within the adopted policy.

The actual observed projects/content and standing execution grants are user
configuration choices, not another architecture approval. Existing grants survive
migration; new-folder defaults do not downgrade them or override explicit blocks.
Public trait/type signatures and feature names are engineering work. The repository license is now AGPL-3.0-only (`e34586b2`, 2026-10-26);
external crate publication and release packaging remain separate owner decisions. The user does
not need to choose Rust boxing, lock algorithms or database column names.

## Engineering specifications and proof gates still missing

| Gate                                           | Concrete deliverable and practical limit                                                                                                                                                                                                                         |
| ---------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Conversation/task identity and state ownership | Map existing Node-local/composite session IDs to stable conversation/task identities, history segments and owners; preserve old links and first-send/retry semantics. A tracking-only task needs no execution session                                            |
| Cross-host context custody                     | Specify who journals/exports the authorized history and interruption point before worker retirement. No fresh response with complete history is promised if neither an authorized runtime nor required context is available; cached reading/drafts remain useful |
| Real resource revocation                       | Platform-specific proof for open descriptors, child processes, shells, aliases and unrestricted paths, plus host acknowledgements. Pending/offline is not completed revocation; unsupported arrangements must fail visibly                                       |
| Distributed transitions and event ordering     | Persist command/result identities, binding/control generations, snapshot/event handoff, crash receipts and timeout/unknown outcomes. No exactly-once guarantee for arbitrary external side effects                                                               |
| Multi-agent coordination                       | Specify wait wake-ups, fairness/deadlocks, ownership and stale-edit handling; test external edits and multiple Nodes sharing storage. Per-Node leases/checkpoints are not a universal filesystem lock                                                            |
| Project movement and deletion                  | Design immutable write-time provenance, project-level versus chat-level cleanup scope, legacy classification and reference ownership. Exercise mixed histories, concurrent edits, restart and retained recovery evidence                                         |
| Client/content migration                       | Preserve upload ownership and legacy restrictions, account-separated caches, live file identity and deletion reconciliation; keep real phone/IME/background-push acceptance distinct from local tests                                                            |
| pots triggering and bounded execution          | Define occurrence/deduplication keys, evidence freshness, task-link transactions, control races and concurrent budget accounting; prevent retries or bots from manufacturing new authority                                                                       |
| Rust extraction compatibility                  | Prototype local/Send use, streaming/cancellation/resume/error boundaries and feature combinations; preserve old serialized bytes, transport routing and pirc event order before deduplicating implementations                                                    |
| Upgrade and rollback                           | Inventory old data/client/Node versions, validate restart-safe migration on representative large histories and retained work, and name the supported rollback data version; a UI revert is not a database rollback                                               |

These gates are dependencies of implementation stages, not ten new approval forms.
A gate is complete only with the specified design/evidence, not by updating its
checkbox. The adopted policy must not be reopened as unresolved; unspecified
numeric settings, destructive durations or new access scopes must not be treated
as though the user had already chosen them.

## Suggested bounded first implementation proposal

Before changing code, present one small delivery: define the resource/capability
and identity contracts with compatibility fixtures, then apply them to a selected
same-conversation workflow. Keep provider extraction independently reviewable;
do not make full loop extraction, Flutter Web migration or a new auth mechanism
prerequisites for every product change. Implement the adopted defaults without
silently altering existing permissions or the established deletion contracts;
bring genuinely new behavioral tradeoffs back for review.

Current fixed Chat/Work tabs describe shipped navigation; they are not the desired
end state. Existing modes/mobile backlog remains available, but further old-layout
UI expansion should be assessed against the unified contracts. This does not close
existing security, rendering, physical-device or push acceptance gaps.

## Verification scope for publication

Repository publication should check Markdown formatting, local links/anchors,
scenario numbering, and the final diff; verify the included App fixes through
relevant existing automated tests/static analysis after integration. Do not start
new runtime architecture implementation to make this review appear complete.
Record actual command results separately from the future acceptance scenarios.

### App verification for the preceding publication

After `git pull --rebase origin main`, the branch was up to date with baseline
`aca6eeb6` and had no integration conflicts. At `311b995a`, the included App changes
passed `flutter analyze --no-pub` and **230 tests** across these existing suites:

- `html_keyboard_events_test.dart`
- `browser_parity_test.dart`
- `terminal_parity_test.dart`
- `timeline_parity_test.dart`
- `document_absolute_position_test.dart`
- `document_absolute_basis_test.dart`
- `document_live_runtime_dialog_author_position_test.dart`

Tests used `flutter test --no-pub --concurrency=2 --reporter=expanded` in
`apps/android`. These verify the included keyboard protocol/localized error and
modal-positioning changes, not the future architecture. No emulator or Chrome
instance was started. Only this run's newly created `build/native_assets`,
`build/test_cache` and `build/unit_test_assets` were removed; pre-existing releases
and parity artifacts were preserved.

Markdown formatting, local references/heading anchors, the 32 numbered future
acceptance cases and diff whitespace were checked. This verification record changes
no runtime source. Release publication and new architecture implementation remain
outside the current request.
