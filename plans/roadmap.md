# pirc 2 roadmap

[Open work](README.md) · [Pots](pots.md) · [Usage](usage.md) · [Client](client.md) · [Design (E)](../docs/design/README.md)

Milestones run in order. A step is one or a few commits that leave `main` building and
are pushed on their own. Each step lists **Done when** (the evidence needed) and
**Deletes** (what goes away). Statuses use the four states: design, code,
acceptance, activation.

## Status

| Milestone                                                     | Design   | Code        | Acceptance | Notes                                                         |
| ------------------------------------------------------------- | -------- | ----------- | ---------- | ------------------------------------------------------------- |
| [M0 Unify the working tree](#m0-unify-the-working-tree)       | complete | complete    | n/a        | `e1a08db9`, `162c113b`                                        |
| [M1 Plans reset](#m1-plans-reset)                             | complete | in progress |            | steps 1–3 done (`287f1152`, `a165ee7a`, retirement)           |
| [M2 Backend baseline](#m2-backend-baseline)                   | complete | complete    |            | 6 moved to M4; 88 conformance tests set aside until M4.11     |
| [M3 Usage ledger](#m3-usage-ledger)                           | complete | complete    |            | P20; steps 1–4 done, step 5 is built with pot budgets in M4   |
| [M4 Pots backend](#m4-pots-backend)                           | complete | in progress |            | steps 0–8a and 9 done; 8b, 10b and 11 in progress on branches |
| [M5 Client foundation](#m5-client-foundation)                 | complete | complete    |            | `f81ba7fd`…`f2fed4aa`; CI green at `02f1ad55`                 |
| [M6 Work and settings screens](#m6-work-and-settings-screens) | complete |             |            | 16 steps; defaults A–H accepted 2026-11-25                    |
| [M7 Pots screens](#m7-pots-screens)                           | outline  |             |            |                                                               |
| [M8 Android cutover](#m8-android-cutover)                     | outline  |             |            |                                                               |
| [M9 Web and macOS cutover](#m9-web-and-macos-cutover)         | outline  |             |            | Q8                                                            |
| [M10 Embedded Tailscale](#m10-embedded-tailscale)             | spike    |             |            |                                                               |
| [M11 Release](#m11-release)                                   | outline  |             |            |                                                               |

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

## M3 Usage ledger

Specification: [usage.md](usage.md). Steps:

1. Keep pricing in the model catalog (`scripts/model-catalog.ts`, `catalog.json`,
   `crates/pirc-llm-types` `Model.cost`), with a pricing revision.
2. Record one `usage_events` row per model request at the Gateway's inference
   completion (`nodes.rs` `start_inference`), including failures with partial usage.
3. Attribute each request to an actor (user, pot, schedule, delegation, title/
   classifier side requests) and a causal root.
4. Aggregation queries and `GET /api/usage/*` endpoints.
5. Budget admission hook: built with the pot budgets in M4 (reservation against
   the pot, the causal root and the owner caps, as [usage.md](usage.md#budget-admission)
   describes), so no unused code lands before its caller.

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
7. **Autonomy and the pot's models** (parallel to 5 and 6b; code in
   `pots/autonomy.rs` and `features/pot/autonomy.rs`).
   - Models: the pot's primary model and thinking level are applied to its session
     when it is allocated and before each wake if they changed; on a retryable
     failure before any output the agent moves to the next fallback (as role
     fallback does) and reports it (`pot.fallback`), logged as `fallback`.
   - Review timer: with `autonomy_interval_s` set, a pot not engaged since
     `last_engaged_at + interval` gets a `review` wake (`next_review_at` in
     `pot_runtime`, driven by the pots sweep); user messages, assigned work and
     non-review wakes set `last_engaged_at`.
   - Tools and operations: `set_autonomy` (`pot.autonomy.set`, interval or off,
     reason, logged `autonomy_changed`), `remind_me` (`pot.reminder.create`: a
     `pot_reminders` row delivered as a `reminder` wake at its time; at most 50
     pending per pot; logged `reminder_set`), `set_thinking` (`pot.thinking.set`,
     only with `thinking_auto`, logged `thinking_adjust`).
     Done when: Gateway tests for each operation and the review timer (due, not
     due, off, engaged recently), agent tests for the tools and the fallback report.
8. **Budgets, causal roots and the loop guard.**
   - 8a. _Admission and budget tools_ (parallel to 5, 6b and 7; code in
     `pots/budget.rs`, `usage/admission.rs`, `features/pot/budget.rs`). Requests
     from a pot's session are attributed `actor_kind='pot'`. Before each such
     request the inference path reserves an upper bound against the pot's caps and
     the owner caps in one transaction (usage.md, Budget admission) and refuses with
     `budget_exhausted` (`pot|owner`, `tokens|money`); completion reconciles.
     An exhausted pot's model wakes wait. `budget_status` (`pot.budget.status`) and
     `budget_request` (`pot.budget.request`, table `budget_requests`, one open per
     pot; `GET /api/budget-requests`, `POST …/{id}/answer` with approve, approve
     another amount, deny; a system message in the direct thread; the answer wakes
     the pot; logged `budget_request`/`budget_exhausted`).
     Done when: the acceptance cases of usage.md (concurrent requests near a cap,
     subscriptions without API-equivalent accounting, price change) pass as
     Gateway tests.
   - 8b. _Causal roots and the loop guard_ (after 6b and 8a; code in
     `pots/roots.rs` and `pots/guard.rs`). `causal_roots` (origin, depth and fan-out
     limits from `pot_settings`, money and token budget, spent and reserved, state
     `active`/`suspended`/`stopped`, last progress). A root starts at a user message,
     an observed event, a review or a reminder; every wake, pot message and work
     start it causes carries it with its depth (`pot_wakes` gains `depth`;
     `pot_works` gains `causal_root`). A wake past the depth limit, or past the
     fan-out of the wake that caused it, is not queued and the sender is told.
     Admission also reserves against the root's budget, so parallel children cannot
     overspend it. Loop guard rules 2–5 of [pots.md](pots.md#loop-guard) (rule 1,
     handovers, comes with 10a): progress is recorded by the backend (a work run
     finishes, a pot's message lands in a direct or group thread, a decision is
     answered, an observation is noted); repeats of the same structured purpose and
     no-progress streaks per root and per pot pair suspend the root; rate ceilings
     delay delivery first. A suspended root delivers nothing, posts one
     `loop_guard` card (`GET /api/causal-roots/{id}`, `POST …/{id}/resume`,
     `…/stop`), and is logged `loop_guard`; a pot cannot lift it.
     Done when: the four loop-guard tests of pots.md and the depth/fan-out cases
     pass.
9. **Observation and de-duplication** (L0–L3 of [pots.md](pots.md#observation-and-de-duplication);
   code in `pots/observe.rs`, tools in `features/pot/observe.rs`).
   - 9a. _Events and observations._ `obs_events` (L0: owner, source kind and ref,
     condition, occurrence; unique; no content) and `obs_targets` (which pots an
     event reached, and whether through a lead scope). Session sources: a run that
     finishes or starts waiting for the user (the live-activity transitions in
     `node_events.rs`) in a session the pot observes directly, through its
     workspace or through its project. Never the pot's own session, any pot's own
     session, or work the pot coordinates. Each matched active pot with reach
     `observe` or `work` gets an `event` wake. Tools `observe_note(eventId, note,
evidence?)` (L1 `obs_observations`, one per pot and event, only for events that
     reached the pot) and `observe_read(eventId)` (the session's name, run status
     and last answer, read only).
   - 9b. _More sources._ Schedule runs that finished (scope `schedules`, all of the
     owner's schedules) and calendar events starting within 30 minutes (scope `calendar`),
     polled every 30 seconds; the L0 unique key makes polling idempotent.
   - 9c. _Notifications and dispatch._ `observe_note(…, notify: true)` creates the
     event's single L2 `obs_notifications` row: from the lead pot when the event
     reached one through a lead scope (others' notes are attached, they cannot
     notify), otherwise one merged notification listing every observer's note.
     `GET /api/observation-notifications?state=`, `POST …/{id}/read`,
     `notifications_changed` hints, logged `forwarded_to_user`. L3: `work_open`
     with `eventId` claims the purpose (target workspace, `work_open`, event) in
     `obs_dispatches`; a second pot is refused with who handles it and may add
     notes; a failed start or a take-over releases the claim.
     Done when: the pots.md acceptance case (two pots observing one event: two L1
     rows, one L2 notification, one L3 dispatch) passes, plus scope, exclusion and
     lead tests.
10. **Handover, delete and the old assistant.**
    - 10a. _Handover, archive and delete_ (pots.md, Handover…): `pot_handovers` and
      items with fit, `handover_propose`, confirm, the retire preview, and delete
      (handover, then revocation, then the session, then removal); loop-guard rule 1.
    - 10b. _Remove the assistant chat mode and delegations_ (parallel to 8b and 9;
      no `crates/pirc-conformance` edits): the `chat` mode (`chat.md`,
      `default_chat`, the `chats` workspace and top-level chats), `SOUL.md`/`CHAT.md`
      and `/api/assistant/prompts` (Gateway and Node, `assistant_prompts.rs`),
      assistant-only chat projects and project links, delegations (`delegations.rs`,
      the `delegate`/`delegation_status` tools, the `assistant-delegation*` delivery
      types, the mode's `delegate`/`delegate_target`), and the clients' routes for
      them. The chat node stays as the pot host: the `assistant_node` claim remains
      (renamed later if useful). User memory and the legacy session memory stay for
      10c. Conformance tests of removed features are deleted after the rewrite
      (step 11) lands.
    - 10c. _Pot memory and the legacy memory_: pots get their own memory store keyed
      by pot (P8; recall never crosses pots), replacing the user-memory tools in the
      pot mode; then the legacy session observational memory in
      `crates/pirc-agent/src/features/memory/` is removed (keep what workspace
      memory uses; delete `docs/architecture/legacy-observational-memory.md`).
11. **Conformance rewrite** (parallel to every other step; touches only
    `crates/pirc-conformance` and `scripts/conformance-accounting.ts`). A harness
    helper starts a conversation through first-send (prepare, accept, materialize,
    dispatch, wait for the run); every test marked `#[ignore = "pirc 2: …"]` is
    rewritten on it, except tests of the assistant chat mode, which step 10 deletes
    with the feature. Snapshots are re-recorded on Linux (a temporary branch
    workflow) and reviewed: only session-creation differences may change. The
    passing floor goes back above 250.

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
   - Added later in M5 (owner decision, so M6 screens can be built and tested
     natively): the macOS scaffold, `flutter create --platforms macos`. Bundle ID
     `dev.pirc.mobile`, product name `pirc`, deployment target 12.0 (the lowest Xcode
     27 accepts); App Sandbox on, `network.client` in both entitlement files, no
     `network.server` in Release, no Keychain groups. macOS has only the standard
     build: with no flavor, `PIRC_TAILSCALE=true` is refused, as on Web. It uses the
     `dart:io` transport adapter. The Nix Flutter needs `macos` in the flake, and
     `flutter build macos` there needs a writable copy of the engine artifacts
     (`lipo` rewrites the framework, store files are read-only) and the shell's
     `DEVELOPER_DIR`/`SDKROOT` unset. CI does not build macOS.
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

Specification: [client.md](client.md) and the design handoff
([E](../docs/design/design-spec-pots.md), [D](../docs/design/design-spec-D.md),
[C](../docs/design/design-spec-C.md), [components](../docs/design/components.md),
[rules](../docs/design/design-rules.md)). Route formats are in
[gateway-and-node.md](../docs/development/gateway-and-node.md). The work touches
`apps/app`, `packages/pirc_client` and `packages/pirc_ui`; it changes no backend
code. Steps 1–7 run in order. Steps 8–15 can run in parallel after step 6.

Code goes in these places. API calls for one route family go in one file under
`packages/pirc_client/lib/src/api/` (new). Widgets that more than one screen uses go
in `packages/pirc_ui/lib/src/components/` (new), with the names from
[components.md](../docs/design/components.md). Screens and their Riverpod providers
go in `apps/app/lib/src/<area>/`. Every new string is added to `app_en.arb` and
`app_zh.arb` in the same commit. Client tests use `FakeTransport` from
`packages/pirc_client/test/support/fakes.dart`.

The old clients are the reference for behavior that the design does not describe:
`apps/android/lib/live/` and `apps/web/src/lib/`. They are read, not ported file by
file ([client.md](client.md#state)).

**Defaults the owner accepted on 2026-11-25.** The design leaves these points open
or gives two answers.

- **A. Token storage.** `flutter_secure_storage` holds the device token on Android
  and macOS until M8 adds the Keystore channel. Web has no token.
- **B. Updates of the Work list.** Lists read again on the hints of the
  `/api/hints` WebSocket, which needs no session (step 2).
- **C. Panels, artifacts and the task sheet at 900 and wider.** They use rule C: the
  right pane at 1200 and wider; they replace the middle at 900–1199; they are a full
  page below 900. The right pane holds one kind of content at a time.
- **D. Stop.** The composer has a secondary button "Stop this work", as in E36. The
  main button is always Send.
- **E. Tasks.** The backend has no task model yet
  ([contracts](../docs/architecture/contracts.md#open-acceptance-gaps)). M6 shows the
  goal, todo list and queue that the snapshot already holds. The D "send to" choice
  (D8) and the task detail sheet (D9) are not built.
- **F. Context and checkpoints panels.** Both are built as simple read-only pages,
  reached from a "More" entry after the six panel tabs. This answers the carried-over
  Context inspector item.
- **G. Entry to a project.** A tap on a project group header in the Work tab opens
  the project page.
- **H. Management approval screen.** M6 builds the screen. M9 only makes the Web
  build the served one.

The design uses 接管 for "take over a work session". 接手 means the receiver of a pot
handover, which is M7.

1. **Fill the gaps in `pirc_client`.**
   - `Session` gains `origin` (kind `schedule`) and `writeLease`. The `delegation`
     kind is not mapped: M4 step 10b removes delegations. `Capabilities` gains a
     `pots` getter.
   - `HintMessage.types` gains `pots_changed`, `threads_changed`,
     `approvals_changed`, `activity_changed` and `budget_requests_changed`. Today
     these frames are dropped.
   - `pi_messages.dart` maps `customType: "pot-instruction"` to a message with the
     pot's name and ID from `details` (`potName`, `potId`, `workId`,
     `instructionId`). The old `pots-dispatch` case is deleted.
   - `policy.dart` `errorFor` maps `409 environment_required` and `409 taken_over`
     to typed errors.
   - `ApiClient` gains `patch`, `put` and `delete` helpers. `TransportConfig` gains
     an optional callback that returns the management grant; the transport sends it
     as `x-pirc-management` only to `/api/devices*`, `/api/providers*` and
     `/api/provider-auth/*`.
     Done when: unit tests cover each item, and a safety test shows that the grant
     header is never sent to another path.
     Deletes: the `pots-dispatch` mapping.
2. **Storage, pairing and connection** (`apps/app/lib/src/connection/`).
   - Add `shared_preferences` (language, appearance, text size, start tab, Gateway
     URL) and `flutter_secure_storage` (device token, default A). The app's
     `TokenStore` reads the secure store. Check the macOS sandbox build first: M5
     added no Keychain entitlement.
   - Pairing uses the current v1 flow: the user pastes a
     `pirc://pair?url=<origin>&token=<token>` link. The page shows "checking",
     "not valid" and "paired". It calls `ApiClient.connect()` before it saves the
     token. The QR scanner and the `pirc` URL scheme come in M8. The Web build has no
     pairing page.
   - Providers: `connectionProvider` (the transport, `ApiClient`, capabilities and
     account) and `connectionStateProvider`. `PairingRequired` (401 or close code
     4401 on the event socket) clears the token and opens the pairing page.
     `ClientUpgradeRequired` shows a blocking "update the app" page.
   - Hints (default B): `pirc_client` gains a `HintStream` for the `/api/hints`
     WebSocket, with the reconnect rules of `SessionEventStream`. The Gateway replays
     nothing, so each list reads again after every connect and reconnect. Close code
     1013 means that the client was too slow; the stream connects again.
   - Shared state widgets: the offline banner ("Offline. What you see may be out of
     date."), "Reconnecting…" and the reconnect overlay that shows no buttons until
     the state is known (C § states, `StatesD`).
     Done when: tests cover pairing (valid, wrong link, 401, 426), token removal on
     4401, saved language and appearance after a restart, and `HintStream` (a hint
     arrives, a reconnect asks for a new read, close code 1013).
3. **Drawer and shell (E21).** The ☰ button opens a drawer that pushes the page
   (widths 310, 396 and 412). It shows the connection state, one row for each host
   from `GET /api/nodes`, the Settings entry and the light/dark switch. The user row
   shows the account name only; usage is M7. Tab badges are yellow.
   Done when: widget tests at 375, 700, 1000 and 1300 wide show the drawer open and
   closed, and the drawer keeps the selected tab.
4. **Work tab (E2–E4).**
   - Data: `GET /api/sessions`, `GET /api/workspaces`, `GET /api/pot-works` and
     `GET /api/model-approvals?state=pending`, loaded again on `sessions_changed`,
     `pots_changed` and `approvals_changed` hints from `HintStream`. A session is
     "opened by a pot" when a pot work has its `sessionId`; the session itself has
     no pot field.
   - Filters: All; Needs you (`runStatus` is `waiting_input`, plus pending model
     approvals); Running (`runStatus` is `running`); Mine (no pot work and no
     `origin`); Opened by pots. Each filter shows its note from `PhoneE`.
   - Rows have no avatar. Line 1: name, "From <pot>" or the schedule title, and the
     time. Line 2: host and state, with a symbol and text. Sessions are grouped by
     workspace under a header with a folder icon, the name and the count; the search
     field filters names and project names on the device.
   - Row actions: rename, pin, settle (`PATCH /api/sessions/:id`), delete
     (`DELETE`), and mark read (`POST /api/sessions/:id/read`) when a session opens.
   - A model approval row is shown but does not open; the approval sheet (E25) is
     M7.
     Done when: tests cover each filter, the grouping, each hint and each row
     action; golden images at the four widths, light and dark.
5. **Work conversation, reading.**
   - A `SessionController` for one open session (under 500 lines): snapshot,
     `SessionEventStream`, `reduceEvent`, a new snapshot on `SnapshotNeeded`, and
     the control lease with `LeaseHeartbeat` tied to app visibility.
   - Top bar: back (not at 1200 and wider), the name, the environment line (state
     dot, project, host) and the panel button.
   - Timeline: a reversed `ListView`. User and assistant messages use
     `NativeMarkdown` in document style, without bubbles. Tool calls are grouped in a
     `RunCard` ("n tool steps", failures marked with ✕ and text). System notices use
     `SystemEvent`.
   - Scrolling follows new output only when the view is at the bottom; otherwise a
     "New content ↓" or "A question waits for you ↓" button shows.
   - Control: when another client holds the lease, the composer is read-only and
     shows "Controlled by <name>" with "Take control" (`acquire` with `force`).
     Done when: tests replay `fixtures/timeline/` into the screen, cover reset and
     reconnect, and cover lease loss and take control.
6. **Composer, first-send and the model sheet.**
   - Composer (`ComposerDock`): attachment button, model button, steer or queue
     choice (`steer`, `follow_up`), Send, and "Stop this work" while a run is active
     (default D). `stop` returns the cleared queue text to the draft. Drafts are kept
     per session in app storage and are never sent automatically.
   - Commands go through `CommandSender` with `session.binding`. On
     `stale_environment` the draft stays and the screen loads a new snapshot. An
     uncertain command shows "Not sure it arrived" with "Check status"
     (`CommandSender.resolve`); it is never sent again (N8).
   - New conversation (D2, D3): the "new" button opens a draft with a workspace
     sheet that lists hosts and workspaces. A host that is offline shows the reason
     and cannot be picked. The first Send runs `FirstSendClient.send`. The draft is
     not in the Work list until it is accepted. States: "sending", "not sure it
     arrived" with "Check status" (`receipt`), and "refused" with "Send again" as a
     separate action (`retry`). A first-send journal in app storage lets the app
     check an open operation after a restart.
   - Attachments: `POST /api/sessions/:id/uploads`, or the first-send attachment
     route for a new conversation. The file pickers are native and come in M8; M6
     uses the Flutter `file_selector` plugin.
   - Model sheet (C option 3): two rows, "Model" and "Thinking", each with a
     sub-list. Data from `GET /api/models`. Changes are the `set_model` and
     `set_thinking` commands. A model without thinking disables the row. The goal,
     todo list and queue show above the composer (default E).
     Done when: tests cover each command, the stale binding, the uncertain state,
     every first-send state and a restart with an open operation.
7. **Questions and approvals.** `QuestionCard` for the four interaction kinds
   (`select`, `confirm`, `input`, `editor`), answered with
   `POST /api/sessions/:id/interactions/:interactionId/answer`. States: waiting,
   sending, answered (one summary line), expired (no buttons), and "control is on
   another device" (Send disabled, with "Take control"). An answer from another
   device turns the card into "handled elsewhere". The approval mode control sends
   `set_approval_mode`. A `relay.*` interaction needs no lease.
   Done when: tests cover each kind and each state, and two clients that answer the
   same question.
8. **The From line and take over (E36).**
   - A `pot-instruction` message shows a "From <pot>" tag above the instruction and
     a source line under it ("Not sent by you"). The name comes from the message
     `details`, never from the text.
   - While the pot work's `state` is `open`, a dark bar says that the pot
     coordinates the work, with a 接管 button. The composer then accepts only
     answers to questions and Stop; its hint says "Take over to send messages". The
     Gateway does not refuse a user command before a take-over, so the app applies
     this rule.
   - 接管 calls `POST /api/pot-works/:id/take-over` with the work ID, not the
     session ID. After success a plain banner says that the pot sends no more
     instructions here. `409 taken_over` from a second device is treated as success.
     Back returns to the screen the user came from.
     Done when: tests cover both states, the composer rule, the 409 case and a
     `pots_changed` hint that arrives from another device.
9. **Artifacts.** `pirc-artifact` result blocks in a message become a `ResultCard`
   (kind, version, state, title, summary; copy, share, open). `ResultReader` opens
   in the place default C gives. A newer version shows a note with a "Switch to vN"
   button; the reader never switches by itself, and each version keeps its own
   reading position (P1, 3A). States: generating, done, newer version, failed (the
   last good version stays), not supported (Markdown text). There is no artifact
   route; the data comes from the timeline. Reference: `live/artifacts.dart`.
   Done when: tests cover each state, the manual switch and the kept positions.
10. **Work panels.** One container with `PanelTabs` (Files, Git, Terminal, Tasks,
    Memory, Browser, then "More" for Context and Checkpoints). It loads a panel when
    it opens and again when a `panel_changed` event names its section.
    - 10a. _Files and Git_ (read only): `GET /api/sessions/:id/files[/content]` with
      a path bar; `git/status`, `git/diff`, `git/log` and `git/commits/:sha` with a
      diff view.
    - 10b. _Terminal_: the list (`GET|POST …/terminals`, `…/close`) and the
      full-screen terminal on the stream WebSocket with `xterm`, always dark, with
      the extra key row. Create, type, resize and close need the control lease;
      without it the screen is read-only.
    - 10c. _Tasks and Memory_: `GET …/panel/state` (background tasks, teammates,
      memory), `…/panel/background/:taskId` and its `stop`.
    - 10d. _Browser_: the `…/browser/stream` WebSocket, take and return control, and
      `…/browser/recording`.
    - 10e. _Context and Checkpoints_ (default F): `GET …/panel/context`; the
      checkpoint list, preview, recovery job and "continue" routes under
      `…/checkpoints`. Recovery is a user action and needs the control lease.
      Done when: each panel has tests for loading, empty, offline, failed and
      read-only, and the container has tests at the four widths.
11. **Environment switching (D10–D13).** Shown only when
    `features.environmentSwitching` is usable.
    - The workspace sheet opens from the environment line: host, folders with their
      rights (`GET …/environment`, `GET|POST …/grants`, `…/grants/:id/revoke`) and
      the current state.
    - "Switch host…" creates a preview (`POST …/environment-transitions/previews`
      with `targetWorkspaceId` and `expectedBinding`) and shows what stops, what
      stays and what the target lacks. Cancel changes nothing. Confirm, acknowledge,
      cancel and reauthorize use the routes of
      [contracts § 7](../docs/architecture/contracts.md#7-transition-read-model-and-recovery).
    - While a transition is active a banner shows its steps, and the composer keeps
      the draft and sends nothing. When the source host is offline the banner says
      that nothing starts on the target before the source confirms.
      Done when: tests cover preview, confirm, `plan_changed`, applying, the offline
      source and a second device that reads the result.
12. **Projects (D4–D6, D19).** Opened from a group header (default G).
    - This step starts after M4 step 10b, which removes the assistant-only chat
      projects and the project links. It uses only the workspace routes that remain.
    - Tabs: Conversations, Resources (`…/files`, `…/capabilities`) and Rules
      (`…/instructions`, `…/project-config`, `…/project-trust`).
    - "New project" uses `POST /api/workspaces`. "Delete project…" shows the preview
      from `GET /api/workspaces/:id/deletion` and confirms with `POST`.
    - Not built: Notes and Board (marked as planned in D), and leaving a project
      (D17, D18), which has no route.
      Done when: tests cover each tab, creation, the delete preview and a delete that
      waits for an offline host.
13. **Calendar (D21–D30).**
    - Month, week, day and list views over `GET /api/calendar`; the time zone under
      the title; marks by shape (dot, bar, diamond, yellow diamond for missed).
    - Personal events: `POST|PATCH|DELETE /api/calendar/events`, with the repeat
      scope sheet (this one, this and later, the series). A drag opens a draft; only
      Save changes the event.
    - Agent tasks: `/api/schedules` (create, edit, delete, run,
      `runs/:runId/dismiss`). A missed run is never run again without a choice. A
      task whose target is gone is shown as paused, and Save stays disabled until a
      new target is picked.
    - Agent access: `GET|PATCH /api/calendar/permissions`. A change proposal in a
      conversation is a `QuestionCard` with the before and after values.
      Done when: tests cover the four views, each event form, the three repeat
      scopes, a missed run and a paused task.
14. **Settings (E22).** Opened from the drawer; content is at most 720 wide.
    - Pages: account and this device; model providers and the default model
      (`/api/providers*`, `/api/provider-auth/*`; a paired app needs the `providers`
      grant from step 15); memory (`/api/memory*`); notifications; calendar and
      agent access; general (language, appearance, text size, time zone, start tab);
      modes (read only, `GET /api/modes`); about (app and Gateway versions,
      licences).
    - Notifications show what `GET /api/push` reports, the push targets with
      Remove, and "Send test". The three levels of D20 and the quiet hours need a
      Gateway setting that does not exist; they move to M8 with push.
    - "Unpair this device…" removes the token and local data after a confirmation.
    - A row is shown only when it does something. The pots row and the usage row
      are M7.
      Done when: each page has tests for loading, failed and the main action.
15. **Devices and the management approval screen.**
    - App side (`native_management_access.dart` is the reference): create a request
      with a SHA-256 challenge and a capability list, show the address to open in a
      browser, poll the request, claim it with the verifier, and keep the grant in
      memory only. The grant is dropped when it expires, when the user unpairs and
      when the app stops.
    - Devices page: list (`devices:read`), revoke (`devices:revoke`) and "Pair a new
      device" (`devices:pair`), which shows the link and its QR code one time, with
      the lifetime of the new device.
    - Approval screen (default H): the route `/?nativeManagement=<id>` in the Web
      build. It shows the device name, each capability with its own text, the pairing
      lifetime for `devices:pair`, and Approve and Deny. The Gateway accepts these
      two calls only from a browser identity, so the route does not exist in the
      Android and macOS builds.
      Done when: tests cover the whole grant flow, expiry, denial, each device
      action without its grant, and the approval screen for every capability.
16. **Close the milestone.** Golden images of every M6 screen at phone, tablet
    portrait, tablet landscape and desktop widths, light and dark, compared with
    `docs/design/screenshots/`. A test checks that `app_en.arb` and `app_zh.arb`
    have the same keys. The placeholder classes in `tab_screen.dart` for Work,
    Calendar and Settings are deleted. Update the status table.

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
delete `apps/web`. macOS desktop target, building on the scaffold from M5: Keychain
credentials, pairing, isolated web view for script-bearing documents (Q8),
notifications while running.

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
- **M6** The native Context inspector is built as a read-only panel (M6 step 10e).
  (old README § Existing work 3)
- **M6** Read-only Settings → Modes page listing each mode, its source file and its
  validation warnings, which today are only logged (M6 step 14). (modes.md § Phase 3)
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
