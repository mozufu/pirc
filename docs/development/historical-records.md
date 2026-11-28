# Historical records in Git

[All documentation](../README.md) · [Active plans](../../plans/README.md)

Completed implementation diaries and evaluation artifacts are kept in Git rather than maintained alongside current documentation. Use the [architecture references](../architecture/README.md), [user guides](../guides/README.md) and [deployment guides](../deploy/README.md) for current behavior. Historical proposals, commands and paid-run approvals are not current instructions or permission to rerun an evaluation.

## Retired plans (2026-11-24)

The 0.11.0 plan reset replaced every earlier plan with [Open work](../../plans/README.md),
the [roadmap](../../plans/roadmap.md) and its specifications. The behavioral contracts
that still apply were extracted into [Behavioral contracts](../architecture/contracts.md),
and the remaining acceptance gaps into the roadmap's carried-over items. The last
commit containing the retired plans is `a165ee7a92b27ee2fe68d61e7525f11497d17aeb`:

```sh
git ls-tree -r --name-only a165ee7a92b27ee2fe68d61e7525f11497d17aeb -- plans
git show a165ee7a92b27ee2fe68d61e7525f11497d17aeb:plans/unified-conversations.md
git show a165ee7a92b27ee2fe68d61e7525f11497d17aeb:plans/pots/design.md
```

The retired files are `calendar.md`, `checkpoints.md`, `conversation-binding-migration.md`,
`conversation-execution-contracts.md`, `delegation-autonomy.md`, `execution-isolation.md`,
`folder-grants.md`, `library-extraction.md`, `memory-handoff.md`, `memory-search.md`,
`mobile.md`, `modes.md`, `release-0.9.3.md`, `sandbox-gpu.md`, `transition-installation.md`,
`unified-architecture-review.md`, `unified-completion-contracts.md`,
`unified-conversations.md` and `pots/` (`README.md`, `design.md`, `acceptance.md`). The
plans index before the reset is `git show 162c113b:plans/README.md`. Their status
lines and authorization statements are history, not instructions.

## Old Android client (M8 cutover)

The M8 cutover removed the old Flutter Android client (`apps/android`, application
ID `dev.pirc.mobile.preview`) and its `.github/workflows/android.yml` workflow. The
last `main` commit containing the old app is `2b30db27`; read it without
restoring the files:

```sh
git ls-tree -r --name-only 2b30db27 -- apps/android
git show 2b30db27:apps/android/README.md
git show 2b30db27:apps/android/tool/parity/build_document_script_runtime.py
git show 2b30db27:scripts/prepare-native-first-send.py
git show 2b30db27:crates/pirc-conformance/tests/conversation_native_client.rs
```

The packaged document runtime and Canvas text engine in
`apps/app/android/app/src/main/assets/scripts/` came from that tree. Regeneration
was verified in a temporary extraction of `b32b0554`, without network access:

```sh
git archive b32b0554 apps/android | tar -x -C <temporary-directory>
python3 <temporary-directory>/apps/android/tool/parity/build_document_script_runtime.py \
  --output-dir <new-output-directory>
```

It reproduced the committed `document-script-runtime.js` (SHA-256
`2cd126e8768ea707d2c86b94df35e281d4a58bbbfffcd0fe6cd988798c5b5396`), its license
and third-party notice, the Canvas text bundle, license and provenance, byte for
byte. The generator verifies the committed Canvas wasm against its pinned hash
instead of rewriting it; that hash also matched. The script-runtime provenance
now names `b32b0554` as its source commit instead of the retired paths, so the
historical input remains identifiable without implying that the old tree still
exists.

The parity fixtures in `packages/pirc_render/test/fixtures/parity/` likewise
record `b32b0554` as their pre-cutover origin and keep generator names as
basenames. Retrieve the original generators, for example:

```sh
git show b32b0554:apps/android/tool/parity/capture_document_chart_chromium153.mjs
git show b32b0554:apps/android/tool/parity/verify_document_origin_browser.mjs
git show b32b0554:apps/android/tool/parity/vendor/canvas-text-fixture-font/Roboto-Regular.ttf
```

The old Android JVM first-send helper, the V3 App cells and the native conformance
test were retired with the same cutover because they compiled Kotlin from the
deleted client. The Web first-send acceptance and V3 Web cells remain current.
The old acceptance instructions are available at
`git show b32b0554:docs/development/first-send-acceptance.md`; marking those
fixtures removed does not record them as passed.

## Upgrade notes before 0.11.0

`docs/deploy/upgrades.md` was reset for 0.11.0, which starts from fresh state. The
release-by-release upgrade notes and local checkpoint notes up to 0.10.0 and the
unreleased work that followed are in commit `b643ff4c9fe698bee998537eb999a4f8183b7944`:

```sh
git show b643ff4c9fe698bee998537eb999a4f8183b7944:docs/deploy/upgrades.md
```

## Retrieve the retired documents

The complete pre-cleanup snapshot is commit `af7074fc51742e79c8f0c76a9aaf64f80b414f7e`. In a clone containing that commit:

```sh
# List the original files, including the 11 unchanged PTC JSON artifacts.
git ls-tree -r --name-only af7074fc51742e79c8f0c76a9aaf64f80b414f7e -- docs/history docs/evaluations/ptc

# Read a record without restoring obsolete files into the working tree.
git show af7074fc51742e79c8f0c76a9aaf64f80b414f7e:docs/history/rust-rewrite.md
git show af7074fc51742e79c8f0c76a9aaf64f80b414f7e:docs/history/security-audit.md
git show af7074fc51742e79c8f0c76a9aaf64f80b414f7e:docs/evaluations/ptc/ptc-only.md
```

That snapshot also contains the assistant, browser, schedules (`cron.md`), sandbox and old Android client designs, plus the full implementation/validation diaries in `plans/README.md` and `plans/mobile.md`. Current assistant contracts and accepted security decisions are maintained in [assistant memory](../architecture/assistant-memory.md) and [security decisions](../architecture/security-decisions.md).

Earlier consolidated plans (`assistant.md`, `project-isolation.md`, `backlog.md`, `mobile-audit.md`, `security-audit.md`) can be read with `git show 7677d24:plans/<file>.md`. Prompt customization's baseline is `69ae62c`; the former UI redesign was implemented in `4ce2c40`, `4a3e46f` and `ea76001`. Their current contracts are in [Prompt and Context](../architecture/prompt-context.md) and [Session UI](../guides/session-ui.md).

## PTC evaluation outcome

The hybrid surface was accepted and merged on **2026-10-07**: core tools are exposed directly and through `ptc`, and other capabilities through `ptc`. The original PTC-only target was superseded, not shown to pass. Current behavior is documented in [tools](../guides/tools.md) and [PTC runtime contracts](../architecture/ptc.md).

The retired `docs/evaluations/ptc/` records distinguish:

- The stopped Opus baseline and its preflights, which are not a completed baseline.
- The accepted OpenAI M1 baseline: **300 measured trials and 150 primes**.
- M4 rounds 1 and 2: failed bounds; round 3: incomplete, with no verdict.
- M4 rounds 4 and 5: hybrid comparisons that still failed the original bounds.
- The later 19-exercise public holdout: passed its separately declared bounds, with the recorded oracle caveat; chat limitations were accepted, not regraded.

The protocols, amendments, budgets, hashes, oracle limitations and all 11 JSON artifacts remain together in the snapshot above. Evaluation tooling was removed after the Rust cutover; the last TypeScript revision is `2d480d3`. Removing files from the current tree does not change their historical outcomes or authorize spending, resetting attempt markers, or rerunning the old tools. Later fixes were not automatically re-measured.

## Rust cutover and validation scope

The Rust rewrite's M0–M9 records describe the gateway/node/agent port and the TypeScript conformance baseline; source comments referring here identify that history, not an unfinished migration. The cutover did not import the old state, and incompatible gateway/node protocols cannot be mixed; see [upgrades](../deploy/upgrades.md).

The user **waived**, rather than passed, the remaining full PTC/task-time comparison, native real-provider/subscription smoke-test gate and unresolved polyglot review/accounting results. See the snapshot's `docs/history/rust-rewrite.md` “M9 Cutover” and `docs/history/security-audit.md` for the original decision and evidence. Current accepted boundaries live in [security decisions](../architecture/security-decisions.md); remaining manual checks live in [plans](../../plans/README.md). Reopening paid comparisons requires a new agreed protocol, budget and credentials.
