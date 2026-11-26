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
| [M4 Pots backend](#m4-pots-backend)                           | complete | complete    |            | steps 0–13 done; 231 conformance tests on Linux             |
| [M5 Client foundation](#m5-client-foundation)                 | complete | complete    |            | `f81ba7fd`…`f2fed4aa`; CI green at `02f1ad55`               |
| [M6 Work and settings screens](#m6-work-and-settings-screens) | complete | complete    |            | finished after review; 12 rewritten; Memory panel removed   |
| [M7 Pots screens](#m7-pots-screens)                           | complete | complete    |            | steps 0–14 done; goldens of every E screen at four widths   |
| [M8 Android cutover](#m8-android-cutover)                     | complete |             |            | defaults A–F accepted 2026-11-26; ID `org.mozufu.pirc`      |
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
6. **Legacy observational-memory archive: removed in M4 step 10c-2.** The legacy
   per-session ledger, panel, serializer and settings are gone; the workspace
   ledger, text/time helpers and mirroring that live workspace memory needs stay
   in `crates/pirc-agent/src/features/memory/`.
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
    - 10a. _Handover, archive and delete_ (pots.md, Handover…; code in
      `pots/handover.rs` and `pots/retire.rs`).
      - Items of a pot: responsibilities, pending reminders, open works it
        coordinates, groups it hosts. Fit against the receiver at proposal and again
        at apply: to a pot, a work is `ok` only with a `write` location for it and
        the `work` reach, a host role only for a member, a responsibility is
        `narrowed` when the receiver's reach is lower; to the user, works are taken
        over and the rest `stop`s. Nothing grants permissions.
      - `pot_handovers` and `pot_handover_items`; `POST /api/handovers` (the user),
        `handover_propose` (`pot.handover.propose`, a `handover` card),
        `GET /api/handovers`, `POST …/{id}/confirm` with the revision, `…/reject`.
        Applying moves what fits, wakes the receiver (`handover`), logs `assign`.
        Loop-guard rule 1: a pot may not hand an item to a pot that held it within
        `handback_cooldown_s`; the user may.
      - Retire: `POST /api/pots/{id}/retire/preview` and `…/retire` with the mode
        (`archive` or `delete`), the revision and a target per item (pot, user or
        none), applied in order: hand over, drop what has no target, fail queued
        wakes, then archive, or delete the pot's session and the pot. A deleted
        pot's activity, messages (`author_name`) and direct or DM threads keep its
        name until the owner's activity retention.
    - 10b. _Remove the assistant chat mode and delegations_: the `chat` mode and
      the `chats` workspace, `SOUL.md`/`CHAT.md` and `/api/assistant/prompts`,
      chat projects and project links, delegations and the mode's
      `delegate`/`delegate_target`. The chat node stays as the pot host (the
      `assistant_node` claim remains). Conformance tests of removed features go
      with step 11.
    - 10c. _Pot memory and the legacy memory_ (two parallel parts).
      - 10c-1. _Pot memory_ (`pots/memory.rs`, `features/pot/memory.rs`):
        `pot_memory` notes keyed by pot (deleted with it; P8, recall never crosses
        pots), with revisions and a per-pot size budget. In the pot mode,
        `memory_note` (`pot.memory.note`: add, update, remove with the base
        revision) and `memory_search` (`pot.memory.search`, the pot's own notes);
        `pot.context` adds the notes, frozen per run. `GET /api/pots/{id}/memory`
        and `DELETE /api/pots/{id}/memory/{entryId}` let the user read and forget
        them. Pots still read the user-approved USER entries; they never write the
        user's memory.
      - 10c-2. _Legacy session memory_: remove the legacy session observational
        memory in `crates/pirc-agent/src/features/memory/` (keep what workspace
        memory uses) and delete `docs/architecture/legacy-observational-memory.md`.

11. **Conformance rewrite.** Done: a harness helper starts conversations through
    first-send (`crates/pirc-conformance/src/first_send.rs`); the 83 set-aside tests
    run on it; tests of the features removed in step 10 are deleted. Linux run: 231
    passed, 0 failed, 10 ignored (5 live-client acceptance runs, the Gateway user
    memory replaced by pot memory, 4 terminal cases that need an isolated-terminal
    backend). The passing floor is 231: the removed features took about 30 passing
    tests with them.
12. **Client names** (owner request, 2026-11-25). Every client that takes control
    has a name the other clients can show ("Controlled by <name>", the devices
    list, later "handled on <name>"). A `clients` table (owner, `clientId`, device,
    name, user agent, last seen) is filled when a client acquires or keeps control.
    A paired device is named by its device record; a browser by the name it sends
    (`clientName`), else one read from its user agent ("Chrome on macOS").
    `GET /api/sessions/{id}/control` adds `holder` (name, kind); `GET /api/clients`
    lists the owner's clients for resolving `clientId`s in events;
    `PUT /api/clients/{clientId}` renames a browser; `GET|PATCH /api/device` lets a
    paired device read and rename itself (no management grant: it is its own
    record). The app adds the name to Settings (this device) and shows it.
13. **Working from several devices** (owner decision, 2026-11-25). Control is
    split in three:
    - Any of the owner's devices, without control: read, answer a question (the
      node keeps the first answer; the others are told who answered) and Stop.
    - Sending takes control: a device without it takes it when it sends; when the
      holder acted in the last 30 seconds the app asks once first. The control
      read gives the holder's `lastActionAt`.
    - Explicit control stays for terminal input, browser takeover, switching the
      host and checkpoint recovery.
      A question records how it ended (`answered` with the answering client and
      time, `cancelled` by the agent or a Stop, `expired`, `stale` after a runner
      restart) in its `interaction_answered` event, and snapshots keep questions that
      ended in the last 10 minutes, so every device shows what really happened
      ("Answered on Pixel 9 at 10:32") instead of guessing "handled elsewhere".

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
     Gradle product flavors `standard` (`org.mozufu.pirc`) and `tailscale`
     (`org.mozufu.pirc.tailscale`, through `applicationIdSuffix`), dimension
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
     `org.mozufu.pirc`, product name `pirc`, deployment target 12.0 (the lowest Xcode
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
    Browser, then "More" for Context and Checkpoints). It loads a panel when it
    opens and again when a `panel_changed` event names its section. The agent names
    only `context`, `background` and `team`, so Files, Git and Terminal read again on
    every `panel_changed` and when a run settles. The Memory panel is removed: the
    session memory it showed is gone from the backend, and workspace memory has no
    client route.
    - 10a. _Files and Git_ (read only): `GET /api/sessions/:id/files[/content]` with
      a path bar; `git/status`, `git/diff`, `git/log` and `git/commits/:sha` with a
      diff view.
    - 10b. _Terminal_: the list (`GET|POST …/terminals`, `…/close`) and the
      full-screen terminal on the stream WebSocket with `xterm`, always dark, with
      the extra key row. Create, type, resize and close need the control lease;
      without it the screen is read-only.
    - 10c. _Tasks_: `GET …/panel/state` (background tasks, teammates),
      `…/panel/background/:taskId` and its `stop`.
    - 10d. _Browser_: the `…/browser/stream` WebSocket, take and return control, and
      `…/browser/recording`: the recordings named by the browser log load with
      that route and open in another app through the share sheet (WebM does not
      play in the app on every platform).
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
    - M4 step 10b removed the assistant-only chat projects and the project links.
      The backend no longer has project files, rule instructions
      (`…/instructions`) or the delete preview (`GET|POST …/deletion`), so none of
      them is built.
    - Tabs: Conversations (the Work rows of that workspace; Back from a
      conversation opened here returns to the project page), Resources (the
      workspace capabilities, `GET|PATCH …/capabilities`) and Rules (the project
      config, `GET …/project-config`, and its trust, `POST …/project-trust`),
      shown only when the workspace's mode has `project_config`.
    - "New project" uses `POST /api/workspaces` (a folder on a connected host).
      "Remove project…" asks once and calls `DELETE /api/workspaces/:id`; an
      offline host refuses it with `node_offline`, and the app offers to try again.
    - Not built: Notes and Board (marked as planned in D), and leaving a project
      (D17, D18), which has no route.
      Done when: tests cover each tab, creation, removal and a removal refused by an
      offline host.
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
      agent access; general (language, appearance, text size, time zone, start tab;
      the time zone is this device's or a fixed UTC offset, kept on the device, and
      the calendar reads, shows and creates in it);
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

Specification: the design handoff for E ([spec](../docs/design/design-spec-pots.md),
screens E1–E36, prototype `docs/design/prototype/PhoneE.dc.html?start=<name>`,
screenshots `docs/design/screenshots/E-*`), [pots.md](pots.md) for behaviour, and
[components](../docs/design/components.md) and [rules](../docs/design/design-rules.md).
Every route, field and event is in
[gateway-and-node.md](../docs/development/gateway-and-node.md). The conventions of M6
hold: one API file per route family in `packages/pirc_client/lib/src/api/`, shared
widgets in `packages/pirc_ui/lib/src/components/` under the names of components.md
and section 10 of the E spec, screens and providers in `apps/app/lib/src/<area>/`,
every new string in `app_en.arb` and `app_zh.arb` in the same commit, client tests on
`FakeTransport`, app tests on `test/support/harness.dart`. Step 0 is backend work
done before step 3 starts; steps 1–2 run first, then 3–13 in any order, then 14.

**Fidelity.** The phone layout (below 600 wide) must look exactly like the design:
the same sizes, spacing, type, colours, radii and icons as the E prototype and its
CSS (`pirc-c.css` → `pirc-d.css` → `pirc-e.css`) and `docs/design/tokens.json`. Each
phone screen is accepted by putting its golden image next to its screenshot in
`docs/design/screenshots/E-*` (light and dark); every visible difference is listed in
the step's commit and fixed, or the design is shown to be wrong and the owner is
asked. Tablet and desktop follow the layout rules of E spec § 9 with the same
components.

**Settled for M7 (no open choices).**

- **Avatars**: a pot, a group and the user each have a colour (`avatarColor` 1–5)
  and may have an uploaded picture (`avatarImage`), kept by the Gateway so every
  device shows it. The app crops the picked image to a square and scales it to
  512 × 512 (PNG or WebP) before uploading; the colour stays as the fallback while
  the picture loads or when it is removed.
- **Personality templates** (E7) fill the personality field with this text; the user
  can edit it. Rigorous: "Precise and careful. Checks facts before answering, says
  when unsure, and prefers correctness over speed." Concise: "Brief and direct.
  Answers in as few words as possible and skips pleasantries." Friendly: "Warm and
  encouraging. Explains things plainly and checks that the user is comfortable with
  the next step." Custom: an empty field. zh-TW: 嚴謹「精確細心，回答前先查證，不確定時直說，寧可正確也不求快。」、簡潔「簡短直接，用最少的字回答，不寒暄。」、友善「溫暖、鼓勵人，用平常的話說明，確認你對下一步沒有疑問。」
- **Speech preview** (E7) shows one fixed sample line per template (en/zh in the ARB
  files); no model is called.
- **Thinking levels** follow the selected model: the picker lists only the levels
  `GET /api/models` gives for that model (`thinkingLevels`), labelled Minimal 最低
  (`minimal`), Low 低 (`low`), Medium 中 (`medium`), High 高 (`high`), Extra high
  超高 (`xhigh`), Max 最高 (`max`); a model without thinking shows the row disabled.
  When the model changes and its list lacks the chosen level, the nearest lower
  level is chosen. "Adjust by itself" is `thinkingAuto`.
- **Budgets** (E9): money per month in US dollars (sent as micro-dollars) and tokens
  per day. A new pot starts with US$20 per month and 2,000,000 tokens per day. Either
  limit can be switched off, not both: the step shows two switches and the last one
  on cannot be turned off. Subscription usage counts in money only when "show
  API-equivalent price" is on (P20), so the token limit is the one that always
  applies; the help text says so. When either limit is used up, the user gets a
  notification and the pot's direct thread a notice; at 80 % of either, the pot is
  told at the start of its next run (no extra wake). Owner-wide caps in Settings →
  pots: 0 means no owner-wide cap.
- **Defaults of a new pot**: reach "only answer"; observe nothing; DM send and
  receive "all"; no work locations; 2 concurrent works; autonomy review every 2 days
  (the toggle in step ③ can turn it off); main model = the Gateway's default model
  (`GET /api/models` `defaultModel`), thinking Medium, no fallbacks, no work models.
- **"Waiting on you"** for a pot is `needsYou` from `GET /api/pots` (pending model
  approvals, open budget requests, handovers it proposed, suspended causal roots it
  started). Its chat row shows the yellow `status.warningSoft` badge with that
  count; unread messages use the ink badge.
- **Avatar status** (E1 dots) comes from the pot's `status`: `working` → green
  three-dot capsule (no animation with reduced motion), `unavailable` → grey dot,
  `idle` → nothing.
- **Observation notifications** are shown at the top of the Activity tab as a
  "Noticed" section (open ones first, "Mark read" on each); the Activity tab badge
  counts open notifications. A push opens the Activity tab on that notification.
- **Activity type labels** (E5 tags): `dm` 私訊 / Message, `group_message` 群組 /
  Group, `assign` 交辦 / Handed over, `work_opened` 開工 / Opened work,
  `work_instruction` 送出指示 / Instruction, `file_read` 讀取 / Read,
  `thinking_adjust` 自動調整 / Auto-adjusted, `fallback` 備援 / Fallback,
  `awaiting_confirm` 等你確認 / Needs your OK, `awaiting_approval` 等你核准 /
  Needs approval, `approval_answered` 已核准 / Approval answered,
  `forwarded_to_user` 轉給你 / To you, `budget_request` 申請額度 / Budget request,
  `budget_exhausted` 額度用完 / Out of budget, `loop_guard` 已暫停連鎖 / Chain
  paused, `handover_proposed` 提議交接 / Proposed handover, `review` 自主檢視 /
  Review, `reminder_set` 提醒 / Reminder, `autonomy_changed` 自主設定 / Autonomy,
  lifecycle kinds (`created` … `deleted`) 狀態 / Status.
- **"Adjust ○○'s permissions…"** in E16 opens that pot's settings (E24) scrolled to
  step ③; it never changes a permission by itself.
- **Pause sheet** (E13): "While paused" lists: no new messages or events are
  delivered (they wait), reviews and reminders wait, it starts no work. "Goes on":
  works it already opened keep running under their own controls, its threads stay
  readable, nothing is handed over. The confirm button calls pause.
- **Groups** may be edited by the user only: name, colour, host, members (2–16). A
  pot is never added to a group automatically.
- **The user's avatar** is not shown on the user's own bubbles in pot and group
  conversations (they are the right-hand bubbles); in a pot's point of view
  (E18–E20) the user's messages show the user's avatar.
- **Archived pots** are not in the Chat tab; Settings → pots lists them, and each
  opens its old conversations read-only, with Restore.

0. **Backend additions** (not client work; done before step 3).
   - Threads: a per-owner read position (`POST /api/threads/{id}/read` with
     `{ seq }`); `GET /api/threads` gains `unread` and `lastMessage` (author, first
     line, `createdAt`).
   - Pots: `GET /api/pots` and `GET /api/pots/{id}` gain `status`
     (`working`, `idle`, `unavailable`), `needsYou` and `budgetLeft`
     (`moneyMicros`, `tokens` left in the current windows).
   - Models: `GET /api/models` gains `defaultModel` (`provider`, `id`, `thinking`)
     and, per model, `thinkingLevels` (the levels it accepts, from `minimal`,
     `low`, `medium`, `high`, `xhigh`, `max`; empty without thinking). `max` becomes
     a level of its own wherever a thinking level is accepted (pots, schedules,
     sessions), sent to providers that have it.
   - Pictures: `POST /api/images` (PNG, JPEG or WebP, at most 1 MiB) returns an
     `imageId`; `GET /api/images/{id}` serves it to its owner with long caching.
     Pots (`profile.avatarImage`), groups (`avatarImage`) and the user
     (`avatarImage` in `/api/me`) refer to one; replacing or removing it deletes the
     old picture.
   - Budgets: a pot's money and token limits may each be `null` (off), never both;
     new pots default to US$20 a month and 2,000,000 tokens a day. At 80 % of either
     limit, `pot.context` adds a budget notice to the pot's next run; when either is
     used up, the user gets a push and the pot's direct thread a system notice, once
     per window.
   - The user: `GET|PATCH /api/me` (`displayName`, `avatarColor`); pots call the
     user by `displayName` (`pot.context`).
   - Groups: `PATCH /api/threads/{id}` (`name`, `avatarColor`, `hostPotId`,
     `memberPotIds`, with the thread's `revision`) and `DELETE /api/threads/{id}`
     (groups only).
   - Point of view: `GET /api/pots/{id}/view` adds `instructions` (what the pot sent
     into work sessions, newest first, with the work's title and session).
     Done when: Gateway tests for each, and the routes are in gateway-and-node.md.
1. **Client package.** `packages/pirc_client/lib/src/api/`:
   - `pots_api.dart` (extend): full `Pot` model (profile, work, permissions, models,
     autonomy, state, revision, status, needsYou, sessionId), create, read, patch by
     section with revision, pause/resume/restore, held items, memory read and forget,
     retire preview and retire, settings read and patch.
   - `threads_api.dart`: threads (list, direct thread of a pot, create group, patch,
     delete, read position), messages (page with `before`, post with `mentions` and
     `all`), the `Card` union (`model_approval`, `budget_request`, `work`, `handover`,
     `loop_guard`) and `authorName` for deleted pots.
   - `decisions_api.dart`: model approvals (list, read, answer), budget requests
     (list, read, answer), handovers (list, read, create, confirm with revision,
     reject), causal roots (read, resume, stop).
   - `activity_api.dart`: activity (filters `potId`, `kind`, `since`, `until`,
     cursor `before`), pot view, observation notifications (list, read).
   - `me_api.dart`: `GET|PATCH /api/me`; `usage_api.dart`: `GET /api/usage`.
   - `HintStream` kinds used by M7: `pots`, `threads`, `approvals`, `activity`,
     `budgetRequests`, `notifications`, `causalRoots`.
     Done when: a test per route (request shape and parsing, including each card
     kind and a deleted author).
2. **Shared components** (`pirc_ui`, names from E spec § 10): `Avatar` (sizes 28,
   36, 48, 88; colours `avatar.1`–`avatar.5`; `me`), `AvatarStatus`, `GroupAvatar`,
   `ChatRow` (with and without avatar), `Bubble` (pot conversations and point of view
   only; mine on the right, a pot's tinted 18% of its colour in point of view),
   `HandoffLine`, `WorkCard`, `MentionPopover`, `ProfileHeader`, `HandoverItem` (fit
   ok / narrowed / stop / muted), `ModelAccess` (direct / ask you), `LogRow` with
   `LogTag`, `PovBar`, `Stats` (cards, heatmap, weekly bars, cumulative area, bar
   list).
   Done when: widget tests and golden images of each at phone width, light and
   dark.
3. **Chat tab (E1) and New (E6).** The list holds every non-archived pot's direct
   thread and every group, newest `updatedAt` first; a row shows the avatar with its
   status, name, `intro`, time, the last message's first line and the badges of
   the settled list above. Archived pots are not listed here. Read again on
   `pots_changed` and `threads_changed`. The ＋ button opens E6 with "New pot" and
   "New group" (the latter disabled with a note until two pots exist). Empty state:
   one line and a "New pot" button. The 32-pot limit shows the backend's message.
   Done when: tests for ordering, both badges, the status dots, the empty state and
   each hint; goldens at the four widths, light and dark.
4. **New pot (E7–E10).** Four steps with Back / Next; the last says "Create".
   ① avatar colour or picture (pick, crop, upload), name (1–40), personality with the templates. ② intro (≤ 200),
   work description (≤ 8000), responsibilities (add, edit, reorder, remove; title
   ≤ 200, optional detail). ③ reach (only answer / observe and suggest / start
   work); observe scopes, one switch each (calendar, schedules, and pickers for
   workspaces, projects and sessions from `GET /api/workspaces` and
   `GET /api/sessions`); DM send and receive, each all / selected / off, with a pot
   picker for selected; when reach is "start work": work locations (workspace and
   read/write), max concurrent works (0–16), budgets (two limits with their switches, per the settled rule); autonomy review interval
   (off, 1 day, 2 days, 1 week). ④ main model and fallbacks from `GET /api/models`, thinking (the model's levels), "adjust by itself", and when reach is "start work" the work models,
   each direct or ask; otherwise the explanation text instead. "Create" posts the
   whole input once and opens the new pot's conversation. A backend 400 shows its
   message on the step it concerns; nothing is lost on Back.
   Done when: tests for each step's validation, the reach-dependent sections, a full
   create request, and the error path; goldens of the four steps.
5. **Pot conversation (E11).** The pot's direct thread: bubbles (mine right, the
   pot's left with its avatar), system messages as notices, cards by `card.kind`:
   - `work` → `WorkCard` (title, state from `GET /api/pot-works/{id}`; opens the
     work conversation of M6);
   - `model_approval` → a card that opens the approval sheet of step 6;
   - `budget_request` → a card with Approve / Approve another amount / Deny;
   - `handover` → a card that opens the handover of step 8;
   - `loop_guard` → a card with Resume / Stop the chain / Pause the pots involved.
     Each card reads its item and shows its current state; a decided card shows the
     decision in one line. The composer posts `{ body }`; the pot's reply arrives as
     a message (`threads_changed`). The read position is sent when the newest message
     is shown. Older messages load on scroll (`before`). The header shows the avatar,
     name, status and opens the profile (E12). A deleted pot's thread is read-only and
     uses `authorName`.
     Done when: tests for each card and its states, paging, the read position, a
     deleted pot's thread and the hint updates; goldens.
6. **Model approval sheet (E25–E26)** from a card, the Work tab's "Needs you" row
   (M6 left it closed; it opens the sheet now) or a push. It shows the work title,
   model and thinking, the pot's reason, estimated cost and remaining budget, with
   Deny, Deny with a reason (expands a field, ≤ 2000) and Allow once. A second
   device's decision shows "Answered" with the result. Budget requests use the same
   sheet layout with Approve / Approve another amount (a field in the request's
   unit) / Deny.
   Done when: tests for each answer, the reason, the 409 of an answered item and the
   three entry points.
7. **Pot profile, settings, pause and memory (E12, E13, E24).** Profile: header
   (avatar 88, name, intro, status), Message / Settings / Pause or Resume actions,
   responsibilities, what it may do (a plain summary of permissions), its recent
   activity (five rows, "See all" opens Activity filtered to it) and its memory
   (notes from `GET /api/pots/{id}/memory`, each with Forget). Settings (E24) is the
   four steps on one page, each section saved on its own with the pot's revision
   (a 409 reloads and keeps the edit visible), then Pause, Hand over…, Archive or
   delete…. The pause sheet follows the settled text.
   Done when: tests for each section's save and conflict, pause and resume, forget a
   note; goldens.
8. **Handover and retire (E14–E17).** Handover: pick the receiver (another pot or
   you), tick items from `GET /api/pots/{id}/held`, create, then show each item's
   fit and reason and Confirm (with the revision) or Cancel. A pot's proposal (its
   card) opens the same screen with the banner and only Confirm / Reject. Retire:
   segmented Archive / Delete, a target per item (another pot, you, none) and "Give
   everything to…", the preview (`…/retire/preview`) with "Will stop" and "Kept", and
   the button "Hand over and archive" / "Hand over and delete". Delete asks once more
   with the pot's name typed. After delete the pot's conversation becomes read-only
   and the app returns to the Chat tab.
   Done when: tests for each fit, a pot's proposal, rule-1 refusal text, the preview,
   archive and delete; goldens.
9. **Groups (E32–E35).** New group: name, colour or picture, host, members (2–16 pots). The
   group conversation: bubbles with each pot's avatar and name; the composer's @
   opens `MentionPopover` (members with their reach and `budgetLeft`) and "@all" with
   the warning that every member will be woken; the request sends `mentions` (pot
   IDs) and `all`. Group info: members, host, edit (`PATCH`), delete.
   Done when: tests for creation, mention and all requests, editing with revision,
   deleting; goldens.
10. **Activity and point of view (E5, E18–E20, E27).** Activity: the "Noticed"
    section, then rows (`LogRow`) newest first with paging, filters by pot and by
    kind; filtering to one pot shows "See ○○'s point of view". Point of view: the
    read-only bar, the pot's threads (its direct thread, groups, pot DMs) and the
    messages it sent, the instructions it sent into work (E19, opening the work
    conversation), and pot DMs (E20) as read-only threads. A row opens its reference:
    thread, work session, approval, handover.
    Done when: tests for paging, both filters, each reference, the notifications
    section and point of view; goldens.
11. **Settings → pots (E23).** Totals at the top (this month's money and today's
    tokens from `GET /api/usage`, actor `pot`), owner caps (money per month, tokens
    per day), when exhausted (pause all / ask), activity retention (1–3650 days),
    then the pots and the archived pots (open the old conversations read-only, Restore). Saved with the settings revision.
    Done when: tests for each field and restore.
12. **You and usage (E28–E31) and the drawer user row.** `GET /api/usage` over the
    shown range: the six numbers, the heatmap (18 / 26–30 / 40 weeks by width), 12
    weekly bars, the cumulative area, this month by pot and by model as bar lists.
    Subscription money shows only when "show API-equivalent" is on (P20), marked as
    an estimate. Edit profile sheet: display name, colour and picture (`PATCH /api/me`, `POST /api/images`). The
    drawer's user row shows the display name and opens this page.
    Done when: tests for the numbers, the ranges by width, the estimate marking and the profile edit (name, colour, picture upload and removal); goldens.
13. **Work tab additions (E2–E4, E36).** "Opened by pots" rows open the work with the
    pot bar of M6; a pending model approval row opens the sheet of step 6; the
    conversation of a pot-opened work shows its `WorkCard` header link back to the
    pot.
    Done when: tests for both entry points.
14. **Close the milestone.** Goldens of every E screen at the four widths, light and dark; the phone ones compared with `docs/design/screenshots/E-*` per the fidelity rule, with no difference left unexplained; the ARB key test passes;
    the placeholder for the Chat and Activity tabs is deleted; the status table is
    updated.

## M8 Android cutover

Goal: the new app (`apps/app`, application ID `org.mozufu.pirc`) does everything the
old app (`apps/android`, `dev.pirc.mobile.preview`) does on Android, and the old app
is deleted. The two IDs differ (M5 step 1), so the new app installs beside the old one
and cannot read its token: a user pairs again and then uninstalls "pirc preview" (P5).

Specification: [client.md](client.md#transport) for what stays in Kotlin and the
background client; design C § 6 (`docs/design/design-spec-C.md`, screenshots
`docs/design/screenshots/C-手機/8, 9, 11, 13–15, 28, 30` and `C-通知/`) for
notifications and the quick-reply overlay; design D § 11 (D20) for notification
levels; [device tokens](../docs/development/gateway-and-node.md#device-tokens) for
the current pairing. The old app is the reference for behavior, not for code: read
`apps/android/android/app/src/main/kotlin/dev/pirc/{android,pirc_mobile}/` and
`apps/android/lib/live/`, and port a file only when it already has no old Gateway
client in it (for example the ML Kit scanner flow or the canvas font loader).

Conventions. Kotlin lives in `apps/app/android/app/src/main/kotlin/org/mozufu/pirc/`,
one package per feature. Each feature has its own method channel named
`org.mozufu.pirc/<feature>` (`credentials`, `push`, `notifications`, `overlay`, `scanner`,
`files`, `media`, `images`, `fonts`, `scripts`), with a Dart wrapper in
`apps/app/lib/src/platform/` (or in `pirc_render_document` for the document channels)
and a fake for tests. Kotlin unit tests run with `./gradlew testStandardDebugUnitTest`
in `apps/app/android`; `client.yml` adds that command in step 1. New strings go into
both ARB files; strings that Kotlin shows without the Flutter engine (notifications,
overlay) go into `values/strings.xml` and `values-zh-rTW/strings.xml`, and a test
checks that both have the same keys. Step 0 comes first, then step 1. Steps 2, 3, 5, 6
and 7 can then run in any order; step 4 needs step 3. Step 8 needs all of them, and
step 9 closes the milestone.

**Defaults the owner accepted on 2026-11-26.** The sources left these points open.
The steps below use them.

- **A. Pairing v2 and v1 (steps 0, 2).** The approval page of pairing v2 is a route of
  the `apps/app` Web build, which is served only from M9; `apps/web` gets no new work
  (P14). So M8 builds v2 completely and keeps v1 (the `pirc://pair?url=&token=` link
  and the Devices page that shows it) working: the Android app scans and opens v1
  links. M9 deploys the Web build, switches the app to v2 only, and deletes v1
  (`POST /api/devices` returning a token, the link, and the Devices page "Pair a new
  device").
- **B. Token rotation (A7, steps 0, 2).** `POST /api/device/rotate` gives a new token
  for the same device record and starts new idle and maximum windows (7 and 30 days),
  so a phone that is used at least once a week never pairs again. Rotation never adds
  or extends a management grant or a capability.
- **C. Who applies notification preferences (steps 0, 3).** The Gateway applies them
  per push target before it sends anything, so a muted category is never sent and Web
  Push (M9) uses the same settings.
- **D. Digest (steps 0, 3).** Items at level "digest" are not pushed one by one. The
  Gateway sends one summary push per target at the digest time (default 18:00 in the
  target's time zone) and one at the end of quiet hours, each only when there are new
  items. Quiet hours default to off.
- **E. What a notification can answer (steps 3, 4).** Only agent questions
  (`interaction_created`) and missed schedule runs get option buttons and the
  overlay, as in the old app. Pot model approvals (E25), budget requests, handovers
  and observation notifications open the app on their sheet or the Activity tab, with
  no preselected answer.
- **F. Release signing (step 8).** The cutover moves the signing of the old app
  (environment variables `PIRC_ANDROID_KEYSTORE`, `PIRC_ANDROID_STORE_PASSWORD`,
  `PIRC_ANDROID_KEY_ALIAS`, `PIRC_ANDROID_KEY_PASSWORD`, `PIRC_ANDROID_REQUIRE_SIGNING`)
  into `apps/app/android/app/build.gradle.kts`, so `release.yml` keeps making a signed
  APK. Distribution and the production key are still M11.

**Not in M8:** the live progress notification (C § 6.3 "即時進度"), iOS, and Gateway
push relays. Real remote push delivery (UnifiedPush through a public distributor, Web
Push) is tested only by the owner: the owner declined third-party relay testing, so
an agent never runs it.

0. **Backend additions** (Gateway; done before steps 2–4 need them).
   1. _Pairing v2._ App-initiated and bound to a challenge, built on the request
      store of `management.rs` (`/api/native-management/requests`), not as a second
      copy of it.
      - `POST /api/pairing/requests` with `{ deviceName, platform, challenge }`
        (`challenge` is the hex SHA-256 of a verifier that only the app holds) needs
        no identity. It returns `{ id, expiresAt, approvePath }`. A request lives 10
        minutes; at most 20 are open at one time, and more are refused with 429.
        Known limit: anyone who can reach these routes can keep 20 requests open and
        so delay pairing; the owner then waits up to 10 minutes or pairs with v1.
      - `GET /api/pairing/approvals/{id}` and `POST …/{id}/approve|deny` accept only
        a browser identity, as the management approval does. The approval binds the
        request to that user and returns a 6-digit confirmation code, shown only in
        the browser.
      - `POST /api/pairing/requests/{id}/claim` with `{ verifier, code }` needs no
        identity. It returns `202` while the request waits, `{ device, token }` once
        approved and the code matches, and `410` when denied or expired. Five wrong
        codes end the request. The token is the same `pirc_dev_` token as v1, with
        the same limits (10 phones, `Cache-Control: no-store`).
      - The two routes without identity still need a trusted proxy peer and an
        allowed `Host`. `docs/deploy/` and the Traefik example in
        `gateway-and-node.md` gain the router that sends exactly these two paths to
        the Gateway without forward auth.
   2. _Rotation_ (default B): `POST /api/device/rotate` (device token only) returns a
      new token for the same device ID, name and push targets, and sets the new
      deadlines. The old token works until the new one is first used or 5 minutes
      pass, so a lost response does not leave the phone without a token.
      `GET /api/device` already returns `expiresAt`; it gains `idleExpiresAt`.
   3. _Notification preferences_ (defaults C and D). Each push target gains
      `{ levels, quietHours, timeZone, lockScreen }`. `levels` maps the D20
      categories `needs_you`, `done`, `progress` and `calendar` to `immediate`,
      `digest` or `off` (defaults: immediate, digest, off, immediate). `quietHours`
      is `{ start, end }` or null; during quiet hours only `needs_you` is sent, as a
      silent notification. `lockScreen` is `hidden`, `title` or `full` (default
      `title`). `PATCH /api/push/subscriptions/{id}` changes them with a revision.
      Every sender (interactions, schedules, calendar, pots) names its category; the
      digest sender is new.
   4. _Push payload._ Question pushes add `expiresAt`, `category` and at most 3
      choices (`{ id, label }`) when the question is a single choice with 3 or fewer
      options; other questions send no choices. Pot pushes name their target
      (`{ potId, threadId }`, `{ activityNotificationId }`, `{ approvalId }`,
      `{ budgetRequestId }`). A missed-run push adds `runId` to its schedule target,
      so the background client can read the run. The push still holds no secret, and the app still
      fetches state before it shows any answer (C § 6.2).
   5. _Compact state for the background client._ `GET /api/sessions/{id}/interactions/{iid}`
      returns `state` (`pending`, `answered` or `expired`), `epoch`, `question`,
      `choices`, `expiresAt`, `controlHolder` and `answeredBy`
      (`{ deviceName, at }` or null). `GET /api/schedules/{id}/runs/{runId}` returns the run's state, time and
      reason. Both are small and need no session snapshot. `answeredBy` is also added
      to the `interaction_answered` push so other devices can say who answered.
      Done when: Gateway tests for each route and each refusal (no identity on an
      approval, a wrong code, a sixth code, an expired request, the 21st request, a
      rotated old token after first use of the new one, a category set to off, quiet
      hours, the digest), and every route is in `gateway-and-node.md`.
1. **Kotlin base, credentials and background client.**
   - Add the Kotlin dependencies once: OkHttp, UnifiedPush connector, ML Kit code
     scanner, `androidx.javascriptengine`, and JUnit with Robolectric for tests (the
     versions in the old app's `build.gradle.kts`).
   - `credentials` channel: the Keystore store of the old `CredentialStore.kt`
     (AES-GCM, alias `pirc-device-token`). On Android it replaces
     `flutter_secure_storage` (M6 default A); macOS keeps the Keychain through
     `flutter_secure_storage`. On first start after the update the app moves an
     existing token from the old store into the Keystore and deletes the old entry.
   - Background client: one OkHttp factory (redirects off, `Authorization: Bearer`,
     `X-Pirc-Client: pirc-app/<apiVersion>`, `X-Pirc-Request: 1` on every non-GET, a
     proxy hook for M10). It reads only the compact routes of step 0.5 and sends
     answers and schedule decisions with a client-generated command ID. It never
     re-sends a request whose outcome is unknown (N8); it reports "Not sure it
     arrived" instead.
   - `pirc_render` calls `dev.pirc.mobile/gateway` for `imageCapabilities` and
     `normalizeAvif`; this step renames that call to `org.mozufu.pirc/images`. Step 7
     adds the Kotlin side.
     Done when: Kotlin tests for the store (save, read, delete, move from the old
     store), for the request headers and for redirects being refused; a Dart test
     that the app reads its token through the channel; `client.yml` runs the Kotlin
     tests.
2. **Pairing on Android.**
   - QR scanner (`scanner` channel, ML Kit code scanner as in `BarcodeScanFlow.kt`)
     and the `pirc://pair` intent filter. Both feed the pairing page of M6 step 2. A
     v1 link pairs as today (default A).
   - Pairing v2 in the app: the user gives the Gateway address (typed, or a QR code
     that holds only the address). The app creates a request, shows the device name
     and "Open in a browser to approve", opens `approvePath` in the browser, and asks
     for the 6-digit code shown there. It claims with the verifier and the code. The
     states are waiting, approved, wrong code, denied and expired, each with its own
     text and a way to start again.
   - The approval route `/?pair=<id>` of the Web build (as `/?nativeManagement=<id>`
     in M6 step 15): device name, platform, the device lifetime and Approve and
     Deny; after Approve it shows the code in large digits. It is tested here and
     served from M9.
   - Rotation (default B): when the app comes to the foreground and less than 23 days
     of the maximum window remain, it rotates once and saves the new token before it
     uses it. The idle window needs no check, because every use resets it. If rotation
     fails and less than 3 days of the maximum window remain, Settings → this device and
     the drawer user row show "Pairing ends on <date>. Open pirc on this phone before
     then, or pair again."
     Done when: tests for the scanner result, the deep link, each v2 state, a wrong
     code, the approval page (approve, deny, expired), rotation (saved before use,
     a lost response) and the warning.
3. **Push and notifications.**
   - `push` channel: UnifiedPush registration as in `PushRegistration.kt`
     (distributor choice, enable, disable, a retired instance). The app sends the
     endpoint to `POST /api/push/subscriptions` with `kind: unifiedpush`.
   - Push receipt runs in Kotlin without the Flutter engine. The service reads the
     compact state (step 0.5) and then shows, updates or removes the notification.
     It never shows choices for state it could not read.
   - Notifications follow C § 6.3: collapsed (title and question, "Answer…" and "Open
     conversation"); expanded with at most 3 choices; a missed run with "View and
     run" and "Skip…"; "answered on <device>" with removal after 5 seconds; the lock
     screen version from `lockScreen`. Android notification channels follow the
     four D20 categories. Calendar reminders are pushes from the Gateway, as now.
   - A tap opens the app directly (no service in between). The app shows "Reconnecting
     and checking the latest state" with no buttons, then one of the five results of
     C § 6.2: still open (conversation and answer sheet with the tapped answer
     preselected; only "Send answer" sends), already answered (by whom and when),
     expired, controlled on another device (with "Take control"), offline (the
     preselection is kept, only "Retry"). Pot pushes open their target (default E).
   - Settings → Notifications (C screenshots 11 and 30): push on or off, the
     distributor, the four levels, quiet hours, the lock screen choice, "Send test",
     and the notification permission (Android 13+), which is asked only from this
     page or the first question.
     Deletes: the M8 placeholder text in `more_pages.dart`.
     Done when: Kotlin tests for each push kind (shown, updated, removed, state not
     readable), the lock screen versions and the channel of each category; Dart tests
     for the five results, each pot target and the settings page (save, conflict);
     goldens of the settings page.
4. **Quick-reply overlay.** An overlay service drawn by Kotlin above other apps (C
   § 6.4, screenshots 13–15 and 28), shown for a question push when the user has
   granted "Display over other apps"; without the permission, the normal
   notification is shown.
   - It opens with "Checking the latest state…" and all buttons disabled. After the
     compact read it shows the choices, a send button and the control source
     ("Control: this device" or the device that holds it). Sending gets a control
     lease and sends the answer through the background client, as the old
     `GatewayOverlayService.kt` does.
   - States: checking, ready, sent (closes by itself), answered elsewhere (result and
     "OK"), expired, offline, no control, and "Not sure it arrived". Close does not
     answer; the item stays in "Needs you". The top right opens the full
     conversation.
   - The overlay uses the token colours and type of `tokens.json`, in light and dark.
     Done when: Kotlin tests for each state and for the lease and command ID of a
     send; screenshots of each state next to C 13–15 and 28 in the commit, with each
     difference listed.
5. **Files, sharing and input.** `files` channel: the system picker for attachments
   and project files (replaces `file_selector`), the save picker for downloads and
   documents, share (replaces `share_plus` on Android), images from the clipboard,
   and images dropped onto the composer. The `FileProvider` authority is
   `${applicationId}.files`.
   Deletes: the M8 note in `attachments.dart`; `file_selector` and `share_plus` on
   Android, if no other platform uses them.
   Done when: Dart tests with the fake channel for each entry point and for a refused
   or cancelled pick; Kotlin tests for the save picker and the clipboard read.
6. **Documents and the script runtime (tier 3).** Rebuild the old `live/document_*`
   files on `pirc_client` inside `pirc_render_document`, and install
   `RenderHost.documentRuntime` in `apps/app` on Android only (Web and macOS keep
   null until M9).
   - Kotlin `scripts` channel: the `JavaScriptSandbox` host, script resources,
     document cookies and document storage, as in `NativeDocumentScripts.kt` and the
     files next to it.
   - **Opaque origin for message content.** A document or script that comes from a
     message or a tool result runs with an opaque origin. It never receives the
     device token or the Gateway's cookies. Its cookies and storage are kept per
     document and never shared with the Gateway origin or with another message.
     Remote images and media load only after the user taps them. The old
     `PairedOriginPolicy.kt` is not ported.
   - Split the dialog top-layer layout and the script callbacks out of
     `native_html.dart` into `pirc_render_document` (left for M8 by M5 step 2.4), so
     that the import-graph test still finds no tier-3 file in the chat surface.
   - Move `apps/android/tool/parity/fixtures/` to `packages/pirc_render/test/fixtures/parity/`
     and change the four tests that read it. The `apps/web/tool/parity/*.mjs`
     scripts, which write to `apps/android/build/parity`, are left broken until M9
     deletes `apps/web` (P13, P14).
     Done when: the moved tier-3 tests pass with `-t tier3`; new default-suite safety
     tests show that a message document gets no token, no Gateway cookie and no
     storage of another message; the import-graph test passes.
7. **Media, AVIF and canvas fonts.** `media` channel: recording playback and HTML
   media (play, pause, seek, save), as in `RecordingPlayer.kt` and
   `HtmlMediaPlayer.kt`, including WebM. `images` channel: `imageCapabilities` and
   `normalizeAvif` (`NativeRasterImages.kt`). `fonts` channel: the canvas text fonts
   (`NativeCanvasTextFonts.kt` and the two font files next to it).
   Done when: Kotlin tests for each channel; a Dart test that an AVIF image is shown
   when the channel reports support and falls back when it does not.
8. **Cutover: delete the old app.**
   - Delete `apps/android` and `.github/workflows/android.yml`. Remove `apps/android`
     from the root `pubspec.yaml` workspace and regenerate `pubspec.lock`.
   - Signing (default F): port the old signing block into
     `apps/app/android/app/build.gradle.kts`. `release.yml` builds the `standard`
     flavor of `apps/app` (and the `tailscale` flavor, still the same app until
     M10) and keeps its checks; `release-setup.yml` and `scripts/release-ci.ts`
     check `client.yml` instead of `android.yml` and name `org.mozufu.pirc`.
   - `scripts/version.ts` and `scripts/test/version.test.ts` read
     `apps/app/pubspec.yaml`. Delete `scripts/e2e/jvm.mjs` and
     `scripts/prepare-native-first-send.py` (they compile the old Kotlin core); the
     e2e scripts that use `apps/android/tool/parity/test_browser.mjs` move that file
     to `scripts/e2e/` or drop the check.
   - Docs: `README.md`, `docs/README.md`, `docs/development/{localization,first-send-acceptance,releasing}.md`,
     `docs/guides/session-ui.md`, `fixtures/timeline/README.md`,
     `scripts/e2e/README.md`, `fixtures/mobile-parity/.gitignore` and
     `.prettierignore` no longer name `apps/android`. In `client.md`, the layout
     table drops `apps/android`.
     Deletes: `apps/android` (about 17,000 lines of Kotlin and the old Flutter UI),
     `android.yml`, the two old e2e scripts.
   - Record the last commit that contains `apps/android` in
     `docs/development/historical-records.md` with `git show` examples, as M1 step 3
     did for the old plans.
     Done when: `rg -n 'apps/android' --glob '!plans/**'` finds only history
     (`CHANGELOG.md`, `docs/development/historical-records.md`); `flutter analyze` and the default
     suites pass for the workspace; both debug APKs and a signed release APK build
     in CI.
9. **Close the milestone.**
   - Goldens of every screen that M8 added or changed (pairing v2, the approval page,
     Settings → Notifications, the reconnect page and the five results) at the four
     widths, light and dark; the ARB key test and the `strings.xml` key test pass.
   - Device acceptance, run by the owner on a physical phone with a real account
     (from [Carried-over items](#carried-over-items)): pairing (v1 link and QR,
     rotation), streaming, cancel and reconnect, panels, management consent,
     answering the same question on Web and on the phone at the same time; keyboard
     and CJK IME, safe areas, rotation, background, low memory; notifications on the
     phone's own Android version (permission, lock screen, quiet hours, the overlay);
     calendar reminders; full multi-line approval bodies and labels, browser
     takeover, WebM playback; the release build. Remote push delivery is part of this
     list only if the owner chooses to run it. Each result is recorded in the status
     table's Notes; a skipped check is not a pass (N8).
   - Update the status table.

## M9 Web and macOS cutover

Outline: Flutter Web build (self-hosted CanvasKit and fonts, CSP with
`'wasm-unsafe-eval'`, no inline scripts, hand-written service worker with build ID,
Web Push, cache headers); agent HTML in a sandboxed opaque-origin iframe (Q3);
web-only screens (management approval, pairing QR, the pairing v2 approval route
built in M8); if M8 default A stands, the app switches to pairing v2 only and v1 is
deleted (`POST /api/devices` returning a token, the `pirc://pair` token link, the
Devices page "Pair a new device"); Nix packaging and nginx headers;
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
  Still open: the page lists the modes, but the Gateway reports no source file or
  warnings yet.
- **M9** `/api/hints` refuses any query key outside its hint names, so the Web build's
  `client=` query is refused and its hint stream cannot connect.
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
