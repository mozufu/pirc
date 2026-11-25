# pirc 2 roadmap

[Open work](README.md) · [Pots](pots.md) · [Usage](usage.md) · [Client](client.md) · [Design (E)](../docs/design/README.md)

Milestones run in order. A step is one or a few commits that leave `main` building and
are pushed on their own. Each step lists **Done when** (the evidence needed) and
**Deletes** (what goes away). Statuses use the four states: design, code,
acceptance, activation.

## Status

| Milestone                                                     | Design   | Code        | Acceptance | Notes                                                       |
| ------------------------------------------------------------- | -------- | ----------- | ---------- | ----------------------------------------------------------- |
| [M0 Unify the working tree](#m0-unify-the-working-tree)       | complete | complete    | n/a        | `e1a08db9`, `162c113b`                                      |
| [M1 Plans reset](#m1-plans-reset)                             | complete | in progress |            | steps 1–3 done (`287f1152`, `a165ee7a`, retirement)         |
| [M2 Backend baseline](#m2-backend-baseline)                   | complete | complete    |            | 6 moved to M4; 88 conformance tests set aside until M4.11   |
| [M3 Usage ledger](#m3-usage-ledger)                           | complete | complete    |            | P20; steps 1–4 done, step 5 is built with pot budgets in M4 |
| [M4 Pots backend](#m4-pots-backend)                           | complete | in progress |            | steps 0–4 and 6a done                                       |
| [M5 Client foundation](#m5-client-foundation)                 | complete | complete    |            | `f81ba7fd`…`f2fed4aa`; CI green at `02f1ad55`               |
| [M6 Work and settings screens](#m6-work-and-settings-screens) | outline  |             |            |                                                             |
| [M7 Pots screens](#m7-pots-screens)                           | outline  |             |            |                                                             |
| [M8 Android cutover](#m8-android-cutover)                     | outline  |             |            |                                                             |
| [M9 Web and macOS cutover](#m9-web-and-macos-cutover)         | outline  |             |            | Q8                                                          |
| [M10 Embedded Tailscale](#m10-embedded-tailscale)             | spike    |             |            |                                                             |
| [M11 Release](#m11-release)                                   | outline  |             |            |                                                             |

"Outline" milestones get their detailed steps written (rule P12) before they start,
using what the earlier milestones produced.

---

## M0 Unify the working tree

Done. The repository root is the active tree on `main`, tracking `origin/main`. The
old `.worktrees/flutter-web-parity` checkout was removed after its caches (`target/`,
`node_modules/`, Flutter/Gradle state, `.pirc/` test tools, `DEPLOY.md`, pending
snapshots) were moved into the root. The Flutter 0.5 prototype and the design-C
handoff are archived on branch `archive/flutter-mobile-0.5`; their working copies and
the October local test environments are outside the repository in `../pirc-legacy/`.
The direction-E handoff is in [`docs/design/`](../docs/design/README.md). Branches
whose commits were all in `main` were deleted.

---

## M1 Plans reset

Goal: one current specification; nothing in `plans/` that an agent could mistake for
a current instruction.

1. **New entry point and specifications.** `plans/README.md`, `roadmap.md`,
   `pots.md`, `usage.md`, `client.md`.
   Done when: pushed; Prettier passes on the new files.
2. **Extract still-valid contracts.** Create `docs/architecture/contracts.md`
   (current behavior and invariants only, no diaries) from these sources:
   - `unified-completion-contracts.md`: C1 durable operation authority, C2 revocation
     evidence, C3 cancellation/installation/trusted notices, C4 read model and
     recovery, C7 context/deletion/memory/content, the parts of C9 that are not about
     old-version compatibility, and the reservation rules of C8 (which move to
     [pots.md](pots.md#budgets-and-the-causal-root) instead).
   - `conversation-execution-contracts.md`: capability composition, overlapping
     permissions, Node switching, archive/delete/leave, saved content vs live file
     links. Drop the pots section (replaced by `pots.md`).
   - `execution-isolation.md`, `checkpoints.md`, `folder-grants.md`,
     `transition-installation.md`: the invariants and the open acceptance gaps (for
     example native Linux sandbox, device acceptance), not the implementation logs.
   - `mobile.md`: the rendering tier list and known renderer limitations move to
     `client.md`; everything else is history.
   - `plans/README.md` sections "Existing work and acceptance backlog", "Manual
     validation", "Accepted limitations", "Watch, do not build yet" and "Memory
     integration": keep items that survive the rewrite (check each against P1–P12),
     as a short list in `roadmap.md` under [Carried-over items](#carried-over-items).
     Done when: every extracted invariant names its source section; the owner has seen
     the list of items dropped as obsolete.
3. **Retire the old plan files.** Delete every file in `plans/` other than the five
   above, including `plans/pots/`. Record the last commit that contains them in
   `docs/development/historical-records.md` with `git show` examples, as that file
   already does for earlier retirements.
   Deletes: about 14,000 lines of plans.
4. **Fix drifting facts.** `README.md`, `docs/` and `apps/*/README.md` must not state
   schema versions, test counts or protocol numbers as prose; link to the constant in
   the code instead. Remove statements that only describe pirc 1 behavior once the
   matching milestone lands (tracked per milestone, not here).

---

## M2 Backend baseline

Goal: the backend speaks only the new flows, reports one capability document and
starts from a fresh schema. Old clients may break (P13); they are replaced in M6–M9
and not patched in the meantime.

1. **Delete legacy creation and the first-send gate.**
   - Gateway: `POST /api/sessions` (`routes::create_session`), the `PIRC_FIRST_SEND`
     setting (`pirc-config` `first_send`), `client::require_enabled`/`disabled()`,
     `canSubmit`'s rollout term; first-send is always enabled.
   - Node: `POST /api/sessions` (`app.rs` `create_session`) once its callers moved.
   - Move `dispatch::start_session` (`crates/pirc-gateway/src/dispatch.rs`, used by
     delegations and schedule runs) to an internal entry of the Node's
     `session_creation` module: no client draft, no first-message admission; the
     caller then delivers its message with the existing `deliver`. Pots dispatch keeps
     its own path until M4 replaces it.
     Done when: gateway and node unit tests for creation, delegations and schedules pass.
2. **Delete the unversioned command branch.** Every command carries
   `expectedBinding`; `routes::command`'s legacy relay branch and its tests go.
3. **Delete other legacy switches.** `PIRC_LEGACY_HOST_TERMINALS` and the unreviewed
   host-shell path; the legacy workspace `kind` field (Gateway `routes.rs`, Node
   `app.rs`). `x-pirc-account` stays optional: it is an account fence that
   WebSocket upgrades cannot carry, not a legacy switch.
4. **One capability document.** `GET /api/capabilities` returns
   `{ apiVersion, server, features: { <name>: { supported, enabled, version } } }`.
   Clients send `X-Pirc-Client: <app>/<apiVersion>`; an unaccepted `apiVersion` gets
   `426 client_upgrade_required` with a readable message. This replaces
   `GET /api/conversation-submissions/capabilities` and the
   `x-pirc-first-send-contract` header. Environment switching keeps its
   server-enforced `PIRC_ENVIRONMENT_SWITCHING` gate, reported here. `/api/health`
   keeps only liveness.
5. **Fresh schema baseline.**
   - Before deleting the chain, a temporary test builds a database through the old
     chain and compares the normalized `sqlite_schema` with the new baseline; it is
     removed once it passes.
   - Gateway: final `CREATE` statements only (rewrite the rename/recreate SQL such as
     `conversation_bindings/transitions/installation.sql` and the `ALTER`s in
     `attachments.sql` and `calendar/schema.sql`); version `1100`. Node: same,
     version `2100`. The checkpoint journal keeps its own version.
   - Any other `user_version` is refused at startup: "This state directory was created
     by an earlier pirc. pirc 2 cannot read it; move or delete `<dir>`."
   - Delete `MIGRATIONS`, `migrate()`, fence-only steps, TypeScript-era detection,
     the `remove_*.sql`/`test_remove_*.sql` files and the migration tests; rewrite the
     few fail-closed tests that used downgrade helpers to drop the table directly.
   - `docs/deploy/upgrades.md`: pirc 2 needs fresh state directories.
     Deletes: about 3,000 lines.
6. **Legacy observational-memory archive: moved to M4.** The module
   `crates/pirc-agent/src/features/memory/` (~3,100 lines) is described as a
   read-only archive, but its workspace ledger, panel and serializer are used by
   the live workspace memory, memory mirror, runner and PTC
   (`crates/pirc-node/src/workspace_memory.rs`, `memory_mirror.rs`,
   `runner/`, `panels/`). Separating them is a memory redesign, done with the
   per-pot memory in M4 step 10.
7. **Security defaults without a transition.**
   - The Gateway refuses to start without `PIRC_PROXY_SECRET` unless
     `PIRC_PROXY_SECRET_REQUIRED=false` is set; development scripts and
     `.env.example` set it explicitly, documented as development-only.
   - Management grants become `devices:read`, `devices:revoke` and `devices:pair`,
     each with its own confirmation text; pairing says it adds a long-lived device and
     shows its lifetime.
8. **Old-client code that only served deleted paths** is not edited; `apps/web` and
   `apps/android` are deleted wholesale in M8/M9.
9. **Conformance and CI repair.** Done: the conformance suite is verified on Linux
   through a temporary survey workflow, 193 tests pass. Device-token requests send
   `X-Pirc-Client`; follow-up commands name their binding; chat workspaces are
   created by `mode`; side-request snapshots gained only their `purpose`. 88 tests
   that create sessions through the removed `POST /api/sessions` carry a declared
   `#[ignore = "pirc 2: …"]` and are rewritten in M4 step 11; the passing floor is
   185 until then (`scripts/conformance-accounting.ts`). The Linux sandbox tests
   compile again and the Nix vendor hash is current.

---

## M4 Pots backend

Specification: [pots.md](pots.md). Each step is one or a few pushable commits; each
lists what it builds on. Gateway code lives in a new `crates/pirc-gateway/src/pots/`
(after step 0 frees the name); pot tools reach the Gateway through the existing
agent-operation channel (`agent_ops.rs`, `pot.*` operations), which already checks
that a session can only act as itself.

0. **Remove the model-free pots tracker.** Gateway `src/pots/` (routes, store,
   execution sweep, `node_events` hook, `pots_*` tables), Node `pots.rs` and
   `pots_tests.rs` (dispatch ledger, `pots_dispatches`, `require_generic_input`), the
   `pots_request` link frame and `PotsRequest`/`PotsOperation`/`PotsControl`
   (link protocol 17), conformance `pots.rs`, `docs/guides/pots.md` (replaced by a
   short note pointing to `plans/pots.md`). Keep, generalized: a client-replayable
   route can never mint backend provenance (`app.rs` delivery filter), now for the
   `pot-*` custom message types.
   Done when: workspace builds, gateway and node unit tests pass, no `pots_` table
   remains.
1. **Schema and store.** `pots/schema.sql` with the pot tables of
   [pots.md](pots.md#data-model) (threads, activity, approvals, handovers and the
   de-duplication tables arrive with the steps that use them) (real columns, revisions, finite defaults), and
   `pots/store.rs` with typed rows and transactional create/read/update by section
   (`profile`, `work`, `permissions`, `models`), pause/resume, owner-wide settings.
   Limits: 32 pots per owner, 200 threads, message bodies 32 KiB.
   Done when: store tests cover create-all-sections-at-once, revision conflicts,
   default limits never absent, and owner scoping.
2. **CRUD API and events.** `GET/POST /api/pots`, `GET/PATCH /api/pots/{id}`,
   `POST /api/pots/{id}/pause|resume`, `GET/PATCH /api/pots/settings`; capability
   `features.pots`; `/api/events` change kind `pots`. Validation: work models must be
   in the catalog the Gateway serves; locations must be owned workspaces/projects.
   Done when: HTTP tests for each route, including device tokens and foreign owners.
3. **Runtime on the chat node.**
   - Node: a `pot` mode (`crates/pirc-config/src/modes/pot.md`) and a `pots`
     workspace on the chat node whose sessions each get a private directory, like
     today's chat workspace. The chat mode stays until step 10.
   - Gateway: a pot's session is allocated through the internal creation entry
     (M2.1) when its first wake is delivered (or again if the session is gone);
     deleting a pot deletes the session (step 10).
   - Prompt: the agent asks `pot.context` (new agent operation) at start and per
     wake; the Gateway returns the personality, intro, work description,
     responsibilities, a permission summary and the user's display name. Pot ID comes
     from the session mapping, never from the agent.
   - Wakes: a per-pot queue table; the Gateway delivers one wake at a time with
     `deliver` and custom type `pot-wake` (source, thread, causal root, payload). The
     next wake waits for the run to settle (node events already report it).
   - Replies: when a wake's run settles, the Gateway reads the final assistant text
     and stores it as the pot's message in the wake's reply thread.
     Done when: a conformance-free integration test with the fake model drives one
     wake end to end through Gateway and Node unit harnesses; pause stops delivery.
4. **Threads and messages.** Tables from step 1; `GET/POST /api/threads`,
   `GET /api/threads/{id}/messages` (paged), `POST /api/threads/{id}/messages`
   (mentions, user-only `all`); routing rules (host, `@pot`, DM rules); the
   `pot.message.send` operation; events kind `threads`. Each delivered message
   becomes a wake of the addressed pot.
5. **Activity and point of view.** Writes from every earlier step go through one
   `activity::log` (landed first, with the `pot_activity` table and `activity=1`
   hints, so parallel steps can write activity); `GET /api/activity` with filters and paging; `GET /api/pots/{id}/view`;
   retention sweep.
6. **Work dispatch and model approvals.**
   - 6a. _Model approvals_ (independent of step 5; may land first): the
     `model_approvals` table, a store to request, list, answer and consume an
     approval, `GET /api/model-approvals` ("Needs you" listing) and
     `POST …/{id}/answer` (deny, deny with reason, allow once); a reason is posted in
     the pot's direct thread; every answer wakes the pot (source `approval`);
     `approvals_changed` hints. "Allow once" is consumed by exactly one start.
   - 6b. _Work dispatch_: operations `pot.work.open`, `pot.work.send`,
     `pot.work.status`; work sessions created through the internal entry with a
     `pot-instruction` delivery that renders as "From <pot>" (backend provenance
     only); at-most-once delivery with an uncertain state; an `ask` model goes
     through 6a before the session starts.
7. **Autonomy.** Review timer (`autonomy_interval_s`, default 2 days, off allowed)
   driven by the Gateway's scheduler; `pot.set_autonomy`, `pot.remind_me` (a
   pot-target schedule), `pot.set_thinking` (applied through the existing session
   thinking control, logged), fallback switches reported by the agent and logged.
8. **Budgets, causal roots and the loop guard.** Usage admission (M3.5) before each
   pot-attributed model request (the inference path refuses with
   `budget_exhausted`), `causal_roots` with depth/fan-out, `pot.budget.status` and
   `pot.budget.request` (decision card), the loop guard of
   [pots.md](pots.md#loop-guard); usage attribution gains `actor_kind='pot'`.
9. **Observation and de-duplication** (L0–L3): observed sources feed `obs_events`,
   per-pot `obs_observations`, lead/merged notifications, one dispatch per purpose.
10. **Handover, archive and delete**, then **remove the old assistant**: chat mode,
    `assistant_node` claim semantics (the chat node stays as the pot host),
    `SOUL.md`/`CHAT.md` routes, assistant-only chat projects, the assistant tools that
    pot tools replace, and the legacy session observational memory in
    `crates/pirc-agent/src/features/memory/` (moved here from M2.6; keep what
    workspace memory and pot memory use; delete
    `docs/architecture/legacy-observational-memory.md`).
    Deletes: an estimated 10–15k lines including tests.
11. **Conformance rewrite.** A harness helper starts a conversation through
    first-send (prepare, accept, materialize, dispatch, wait for the run); every test
    marked `#[ignore = "pirc 2: …"]` is rewritten on it or deleted with the feature it
    covered; snapshots are re-recorded on Linux and reviewed; the passing floor goes
    back above 250.

---

## M5 Client foundation

Specification: [client.md](client.md). The client work touches only `pubspec.yaml`
(root), `apps/app`, `packages/`, `apps/android`, `flake.nix` (Web artifacts for
the Nix Flutter), `.gitignore`, `android.yml` and a new CI workflow; it runs beside
the backend milestones. Flutter comes from the Nix shell (`nix develop`, Flutter
3.44.4); Android builds need `ANDROID_HOME` set to a local SDK. Each push runs
`flutter analyze` on the touched members and their fast tests.

1. **Workspace layout.**
   - Root `pubspec.yaml` declares a pub workspace (Dart ≥ 3.6) with the members
     `apps/android`, `apps/app`, `packages/pirc_render`, `packages/pirc_render_document`
     (added in step 2), `packages/pirc_client` and `packages/pirc_ui`. Every member has
     `resolution: workspace`; one `pubspec.lock` at the root replaces
     `apps/android/pubspec.lock`, so all members share the old app's pinned versions
     (`csslib`, `flutter_math_fork`, `flutter_svg`, …).
   - `apps/app`: `flutter create --platforms android,web`, package `pirc_app`.
     Gradle product flavors `standard` (`dev.pirc.mobile`) and `tailscale`
     (`dev.pirc.mobile.tailscale`, through `applicationIdSuffix`), dimension
     `network`. Dart reads `bool.fromEnvironment('PIRC_TAILSCALE')`; a startup check
     refuses a build whose define does not match the flavor (the flavor is passed to
     Dart through `appFlavor`). The old app stays `dev.pirc.mobile.preview`, so both
     install side by side.
   - Packages start empty with a library file, `analysis_options.yaml` and one test.
     Done when: `flutter pub get` at the root resolves; `flutter analyze` passes for
     `apps/android` and `apps/app`; `flutter build apk --debug --flavor standard
--dart-define=PIRC_TAILSCALE=false` and `flutter build web` succeed for `apps/app`.
2. **Rendering package** (inventory and order in
   [client.md](client.md#rendering)). Every sub-step keeps `apps/android` analyzing:
   1. _Break the cycle inside `apps/android`._ `rendering/` imports six `live/` files
      (`document_background_image`, `remote_content_gate`, `html_media`,
      `html_file_picker`, `document_object_urls`, `document_navigation_state`). Add a
      `RenderHost` (inherited widget) in `rendering/render_host.dart` with interfaces
      for the image loader and held-image policy, media factory, file picker, object
      URLs, background images and the document scope; `live/` implements them and the
      old app installs its implementation above `MaterialApp`. Gateway-free widgets
      among those files (the held-image gate, media boxes) move into `rendering/`.
   2. _Inject localization and theme._ `rendering/render_l10n.dart` gives the package
      its own `tr(source, [values])` with the same signature, which calls an
      injectable `RenderLocalizations` delegate; the 82 files change only their
      import. The package owns an en/zh-TW catalog of its 958 strings
      (`lib/src/l10n/*.json`, `tool/generate_l10n.dart`; 23 have Chinese source
      text), and its default delegate reads `RenderL10n.language`. The old app installs
      a delegate backed by `AppI18n` in `main()` and in `test/flutter_test_config.dart`.
      The seven `PircColors` users read a `RenderColors` `ThemeExtension` instead.
   3. _Move._ `git mv apps/android/lib/rendering packages/pirc_render/lib/src`; the
      library `package:pirc_render/pirc_render.dart` exports the chat surface (Markdown,
      code, math, Mermaid, static HTML and forms). Imports in `lib/`, `test/`,
      `integration_test/` and `tool/` are rewritten in the same commit. The d3-sankey
      licence asset that `licenses.dart` registers moves with the code and is read as
      `packages/pirc_render/assets/…`. Renderer tests that import no `live/` code move to
      `packages/pirc_render/test`.
   4. _Tier 3 behind interfaces._ Canvas drawing and pointer input, the computed-style
      export and script form submission move into `packages/pirc_render_document`,
      which depends on `pirc_render` and plugs in through `RenderHost.documentRuntime`
      (null for chat: a `<canvas>` stays blank, script submissions are refused). The
      computed-style spec type, the canvas sizing layout and the canvas limits stay in
      `pirc_render`. The dialog top-layer layout and the script callbacks remain in
      `native_html.dart`: they are inline, attribute-driven layout paths without
      imports of their own, and are split when M8 rebuilds the document code. The `live/document_*`
      files and their Kotlin counterparts stay in `apps/android`: they depend on the
      old Gateway client and are rebuilt on `pirc_client` in M8. A default-suite test
      walks the transitive imports of `package:pirc_render/pirc_render.dart` and fails
      if a tier-3 file is reachable.
   5. _Web compile._ Replace `dart:io` in `native_raster_images.dart` with a
      conditional import, and the 64-bit `ByteData` accessors in
      `mermaid/mindmap_cose.dart` with two 32-bit reads, and the integer literal in
      `html_input_sizing.dart` that JavaScript cannot represent. Pin
      `flutter_math_fork` to an exact version, with a comment that 42 imports use its
      internals. A throwaway `flutter build web` of `NativeMarkdown` compiles.
      Renderer tests that read Chromium captures still read them from
      `apps/android/tool/parity/fixtures/`; M8 moves those fixtures.
      Done when: `pirc_render` analyzes with no `apps/android` import; the import-graph
      test passes; the moved fast tests pass; `apps/android` analyzes.
3. **Client package** (`pirc_client`, pure Dart; inside the Flutter workspace its
   tests run with `flutter test`, because `dart test` refuses to resolve there).
   - API models for the capability document, session snapshot, events, command
     results and errors, written against the Gateway routes on `main` (M2.1–M2.4),
     not against the old clients.
   - Timeline reducer ported from `core/timeline/{Timeline,Events,PiMessages}.kt`,
     with the fixture harness from `TimelineFixturesTest.kt`; every file in
     `fixtures/timeline/` must match its `expected` projection.
   - `Transport` interface with an `io` adapter (`dart:io` `HttpClient` with redirects
     off, `Authorization: Bearer`, `dart:io` `WebSocket` with headers) and a `web`
     adapter (`BrowserClient` with credentials, browser `WebSocket`), chosen by
     conditional import. Every request sends `X-Pirc-Client: pirc-app/<apiVersion>`;
     every non-GET sends `X-Pirc-Request: 1`; 426 maps to `ClientUpgradeRequired`,
     401 to `PairingRequired`. The token store is an injected interface.
   - Event stream: cursor resume, backoff `min(20 s, 750 ms·2^n)` with jitter, early
     retry when connectivity returns or the page becomes visible, fatal close codes
     4400/4401/4403/4404.
   - Commands carry a client-generated command ID and `expectedBinding`; a request
     whose outcome is unknown (timeout, dropped connection after send) is marked
     uncertain and never re-sent through another path (N8). First-send is the only
     creation path. `GET /api/capabilities` is read on connect.
   - As built: `ApiClient.connect()` reads the capability document and refuses
     another `apiVersion`. An event connect times out after 15 s, and `retryNow`
     replaces a connect still in flight. On Web a refused upgrade (401/426) cannot
     be told from a dropped connection, so it is retried; a 4401 close stays fatal.
     The io adapter does the WebSocket handshake itself so redirects are never
     followed.
     Done when: fixture, transport (fake server), reconnect and command tests pass
     with `dart test`; the web adapter compiles (`dart analyze` and a
     `dart compile js` of a small entry point).
4. **State and app shell** (`pirc_ui`, `apps/app`).
   - `pirc_ui`: `tool/generate_tokens.dart` turns `docs/design/tokens.json` into
     `lib/src/tokens.g.dart`; a default-suite test fails when the generated file is
     stale. `PircTheme` builds light and dark `ThemeData` with token
     `ThemeExtension`s. `AdaptiveScaffold` picks one of the four layouts by width
     (≥ 1200, 900–1199, 600–899, < 600) with the rail, list, content and right-pane
     sizes from [client.md](client.md#design-system-and-layouts).
   - `apps/app`: Riverpod (`flutter_riverpod`, no code generation), `go_router` with
     the four tabs (Chat, Work, Activity, Calendar) and Settings as placeholders, en
     and zh-TW catalogs (ARB and `flutter gen-l10n`), a language setting, and the
     `PIRC_TAILSCALE`/flavor check.
   - As built: each tab is one route page whose open item is the `open` query
     parameter, so opening an item never rebuilds the list; the scaffold keeps
     list, content and side pane under stable keys, so a resize moves them and keeps
     drafts and scroll positions. The Traditional Chinese catalog is `app_zh.arb`
     (gen-l10n needs a base `zh` file) and `app_zh_TW.arb` inherits it. The app adds
     the renderer's `RenderColors` from the tokens, mapping the five names the
     tokens call differently (`web.bg`, `web.line`, `web.muted`, `code.head`,
     `border.default`). Language and appearance are not stored yet (M6).
     Done when: widget tests show each layout at 375, 700, 1000 and 1300 wide, and
     switching layout keeps the selected tab and route; light and dark build.
5. **Test layout and CI.**
   - `dart_test.yaml` in each package declares the tags `tier3`, `node`, `fonts`
     and `device`; the default run skips all four and reports them as skipped.
     They run with `flutter test --run-skipped -t <tag>` (a config `exclude_tags`
     cannot be lifted from the command line). Renderer tests that load host fonts
     are tagged `fonts`; the `pirc_render_document` tests are tagged `tier3`, except
     the Canvas decoder's work-budget tests, which are resource-safety regressions.
     The renderer suite had never run on Linux; tests that fail there for font
     reasons get the `fonts` tag when the Client workflow shows them.
   - Safety regressions (credential attachment and redirects, opaque origins,
     remote-content gating, content containment, request shapes) are untagged.
   - New workflow `.github/workflows/client.yml`: `flutter analyze` and the default
     tests for the workspace members, and both debug APKs and the Web build of
     `apps/app`. `android.yml` adds `packages/**` and `pubspec.*` to its paths and
     keeps building the old app.
     Done when: the default suites pass locally and the workflow file is valid.

---

## M6 Work and settings screens

Outline (detailed before start): pairing and connection; Work tab (filters, project
grouping); work conversation (task bar, From line, take over, first-send, composer,
model sheet, tool cards, approvals, questions, artifacts with manual version switch);
work panels (files, Git, terminal, tasks, memory, browser, context, checkpoints);
environment switching; projects; calendar; settings (account, AI providers and
models, memory, notifications, general, data, about); devices and pairing; the
management approval screen.

## M7 Pots screens

Outline: Chat tab; new pot (four steps); pot conversation with decision cards and work
cards; pot profile and settings; pause sheet; handover; archive/delete; groups
(create, conversation, mention popover, info); Activity tab and point of view; model
approval sheet; Settings → pots; user and usage pages.

## M8 Android cutover

Outline: slim native layer (push, notifications, quick-reply overlay, Keystore,
pickers, scanner, JS sandbox, media); notification actions re-fetch state before
showing a preselected answer; pairing v2 (app-initiated, challenge bound, confirmation
code shown on approval, credential rotation that extends idle life but not grants);
message content gets an opaque origin in the native engine; delete the old
`apps/android` UI and the bridge methods it alone used; application ID kept.

## M9 Web and macOS cutover

Outline: Flutter Web build (self-hosted CanvasKit and fonts, CSP with
`'wasm-unsafe-eval'`, no inline scripts, hand-written service worker with build ID,
Web Push, cache headers); agent HTML in a sandboxed opaque-origin iframe (Q3);
web-only screens (management approval, pairing QR); Nix packaging and nginx headers;
delete `apps/web`. macOS desktop target: Keychain credentials, pairing, isolated
web view for script-bearing documents (Q8), notifications while running.

## M10 Embedded Tailscale

Spike first, then build (P16, [client.md](client.md#embedded-tailscale-m10)). Every
Android release has two variants, `standard` (no Tailscale code) and `tailscale`;
M5 already sets up the two Gradle flavors and the `PIRC_TAILSCALE` define so the
variants exist from the first build, with the `tailscale` one identical until this
milestone. The `tailscale` variant embeds a userspace tailnet node on the official
Tailscale service, exposing a loopback proxy used by the Dart HTTP client and the Kotlin
background client, with in-app sign-in through Tailscale's login page. The spike
measures binary size, idle battery use, start-up time from a push and coexistence
with the system Tailscale app.

## M11 Release

Outline: rewrite `README.md` and `docs/` for pirc 2, full validation run requested by
the owner, changelog with the breaking-change notice, version bump. Android
artifacts: both the `standard` and the `tailscale` APK.

---

## Carried-over items

Open acceptance gaps, accepted limitations and watch items from the retired plans that
still apply to pirc 2. Gaps in the backend contracts (native Linux, transitions,
bindings, folders, checkpoints) are listed in
[contracts](../docs/architecture/contracts.md#open-acceptance-gaps). "Old README"
means `git show 162c113b:plans/README.md`; other sources are files in `plans/` as of
that commit.

**Acceptance and validation**

- **M8** Physical Android acceptance with a real account: pairing,
  streaming/cancel/reconnect, panels, management consent, simultaneous Web/App
  confirmations; keyboard and CJK IME, safe areas, rotation, background, low memory,
  OEM notifications and permissions, terminal HTTPS asset origin, release build.
  (mobile.md § Remaining work; old README § Manual validation)
- **M8** On a device: full multi-line approval bodies and labels, PTC approval
  declines and rendering, browser takeover (tap mapping, IME, drag scrolling), WebM
  playback. (old README § Existing work 1, § Manual validation)
- **M8** Calendar reminders and background behavior on a physical Android device.
  (calendar.md § Implementation record)
- **M8/M9** Real remote push delivery (UnifiedPush and Web Push) is unverified; the
  owner declined third-party relay testing, so it is not run without authorization.
  (mobile.md, calendar.md, release-0.9.3.md)
- **M8** Pairing credential lifetime: rotation before the 30-day expiry versus
  re-pairing, with a near-expiry warning (A7); decided by pairing v2. (old README
  § Existing work 3; mobile.md § Distribution decisions)
- **M6** Decide whether the native Context inspector is built (work panels include
  context). (old README § Existing work 3)
- **M6** Read-only Settings → Modes page listing each mode, its source file and its
  validation warnings, which today are only logged. (modes.md § Phase 3)
- **M9** Browser acceptance of the approval-mode picker and warning, and of project
  deletion including recovery after a real Node disconnect; installed-PWA Web Push on
  a real iPhone; iOS Safari keyboard and safe areas. (old README § Manual validation)
- **M9/M11** macOS builds are unsigned and not notarized. (old README § Manual
  validation)
- **M11** Linux/NixOS: a full agent session with browser on a non-container x86_64
  host at native speed, boot-time tmpfiles, bubblewrap and `/proc` privacy cases (run
  only in Linux CI) and Nix build validation (previously waived). (old README § Manual
  validation; release-0.9.3.md § Remaining release gates)
- **M11** Not covered by macOS end-to-end checks: TLS, a real identity provider,
  phone pairing, push, terminals; TLS fixtures do not verify OS CA updates or
  curl/Git trust stores. (old README § Manual validation; release-0.9.3.md)
- **M11** PTC with real providers: Anthropic direct calls with `null`/extra
  arguments, a real model reading agent-data fences; real-provider smoke tests and
  polyglot evaluation were waived, not passed. (old README § Manual validation,
  § Accepted limitations)
- **M11** Release procedure: Check and Android workflows pass on the exact `main`
  commit before the tag; verify draft assets, checksums and the Android signing
  identity. Distribution (sideload, F-Droid or Play) and production signing are still
  to decide. (release-0.9.3.md; mobile.md § Distribution decisions)
- **M11** Modes guide screenshots. (modes.md § Phase 3)
- **Watch** The one-off `node_link_side_runs` CI timeout, if it recurs. (old README
  § Manual validation)
- **Open, no milestone** On macOS a Node state directory path longer than about 76
  bytes makes the inference socket path exceed the platform limit; the Node exits at
  startup with a clear error. (unified-completion-contracts.md § C0)

**Renderer limitations** (M5 `pirc_render`; tiers 2–3 are frozen, only safety, crash,
resource and isolation fixes; mobile.md § Remaining work, § Deferred presentation and
compatibility boundaries)

- `alert`/`confirm`/`prompt` stay explicit unsupported APIs.
- Dialogs: Tab cycling in a single-control dialog and focus after light dismissal
  differ from Chromium; `TouchEvent` objects are absent; default static positioning
  covers block flow only.
- SVG is painted as one image, without per-shape pointer targets.
- Outside the covered layout subset: floats, sticky, zoom, multicolumn, table
  offsets, fragmented inline geometry, 3D/perspective transforms, `calc()` and
  logical insets, RTL, scroll snap, root horizontal scrolling. A DOM write followed by
  a geometry read without a matching native frame fails explicitly.
- `getComputedStyle()` covers a supplied subset; generic font names and default text
  heights differ from Chromium; two root-height fixtures keep 8 and 17 px of extra
  scroll space.
- Arbitrary sites and frameworks, full browser APIs, third-party cookie policies and
  uncommon HTML5 tree-builder recovery are not guaranteed.

**Accepted limitations** (old README § Accepted limitations unless noted)

- Security limits accepted in
  [security decisions](../docs/architecture/security-decisions.md) stay and are not
  reopened without a new decision; lasting domain allows belong in
  `sandbox.network.allowedDomains`.
- Repository keys preserve path case; `.git` symlinks and absolute `gitdir:` and
  `commondir` are followed; only the normalized key leaves the Node.
- Project deletion applies automatic forget/rollback entries as they stand at
  confirmation; only entries needing a decision are revision-checked; rollback may
  leave memory over budget.
- Teammates and subagents have no browser; the screenshot action log is memory-only
  and lost on Node restart.
- PTC: write-lease coverage of shell writes is partial, plain bash output is
  unlabelled, guests inherit the agent's sandbox rights, operations ignoring abort may
  outlive the grace period, and long waits can fill all slots.
- Oversized work interactions stop memory extraction with a visible budget error;
  nothing is truncated into coverage. Model summaries and extraction need separate
  quality evaluation. (memory-handoff.md § Acceptance gates)

**Watch, do not build yet** (each needs the owner's go-ahead)

- Memory consolidation, only if `memory_full` becomes frequent at 8,000 characters;
  consolidated text never gains `user` origin. (old README § Watch)
- Moving conversations between projects: revisit only if the workflow becomes
  painful. (old README § Watch)
- Memory search quality: an evaluation set, then FTS5 + BM25 with CJK bigrams, then
  optional hybrid search through a Gateway-side embeddings endpoint (the embeddings
  source is undecided; a hosted endpoint receives note text). A vector index only past
  about 50,000 rows per user or 50 ms p95, with a stable `sqlite-vec` that needs no
  `unsafe`. (memory-search.md; old README § Existing work 5)
- GPU in the sandbox: an opt-in Node setting (two Metal rules on macOS, exact device
  binds on Linux, a NixOS device policy). It changes a security boundary and needs a
  recorded decision; open questions: a missing device starts without GPU or refuses,
  and whether to ship `shaderCache`. (sandbox-gpu.md)
- Auto-mode precision: reassess with `scripts/approval-stats.ts` first; then "allow
  again in this session" for the exact action text, soft versus hard danger
  categories, and recording the decision source. (delegation-autonomy.md § Phase 3)
- Classify `browser_click`/`browser_type` on non-localhost origins for network
  provenance. (old README § Existing work 2)
- Project-scoped memory, if reopened: opt-in, scope from the trusted session (never
  agent arguments), proposals bound to a scope generation, not retroactive; it
  isolates projects from each other, not from operators, providers or backups. (old
  README § Project-only memory (B))
- Library extraction: API stabilization, feature-matrix builds, minimal local and
  `Send` consumers and an event-order proof; no crates.io publication without an
  owner decision. (library-extraction.md; [reusable LLM](../docs/architecture/reusable-llm.md))
- Calendar: external sync, invitations, shared calendars, OS integration and
  phone-local offline alarms are out of scope. (calendar.md § Goal and scope)

**Dropped**

- USER-proposal confirmation checks on Android: USER proposals belong to the removed
  assistant (P3). (old README § Existing work 1)
- Observational-memory provenance tagging of page results: the legacy OM archive is
  removed (M2.6). (old README § Existing work 2)
- Fixed Chat/Work tabs derived from `assistant`, retiring `kind` (deleted in M2.3) and
  the Android scratch-mode parity capture: tabs follow P1 and the old Android client is
  deleted (M8). (old README § Existing work 4; modes.md § Phase 3)
- Per-chat `delegation_approval`, relayed delegation approvals and Stop checks:
  assistant delegation is replaced by pot work dispatch (P3, pots.md).
  (delegation-autonomy.md; old README § Existing work 7)
- "Publication requires an explicit request" notes: publication resumes (P11). (old
  README § Existing work 8–9; calendar.md)
- Migrating global USER/MEMORY into project scopes: no data is kept (P5) and pot
  memory is per pot (P8). (old README § Project-only memory (B))
- "Deploy Gateway and Nodes together for the changed deliver body": an old release
  note. (old README § Manual validation)
- Pre-schema-1004 chat deletions, TypeScript protocol incompatibility, TypeScript PTC
  baseline comparison and "never delete old state": no old data or TypeScript
  components (P5; M2.5 refuses old state directories). (old README § Accepted
  limitations)
- A second chat node with its own `chats` workspace, and `workspace.read` for chats:
  the chat node becomes the pot host and pots read workspaces through scoped tools
  (P3, M4). (old README § Watch)
- Activation and cold cutover of existing repository ledgers, TypeScript cutover
  markers, and the Chat-owned personal MEMORY block: no deployed data (P5); pots
  replace the assistant chat (P3, P8). (old README § Memory integration;
  memory-handoff.md)
- Reserved migration numbers in memory-search.md: fresh schema baseline (P5).
- Flutter Web as an "evaluation option" and Chromium-parity growth (dialog
  positioning beyond block flow, invoker scheduling, wider framework coverage):
  decided by P4 and frozen by N1. (mobile.md)
- 0.9.3-specific tag and asset checks: superseded by M11. (release-0.9.3.md)
- Library stages for pots, App connection security and optional Flutter Web
  migration: replaced by pots.md, P16 and P4. (library-extraction.md)
- Chat default mode and forbidden combinations involving `assistant: full`: chat
  mode is removed (M4.10). (modes.md)
