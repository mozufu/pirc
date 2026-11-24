# pirc 2 roadmap

[Open work](README.md) · [Pots](pots.md) · [Usage](usage.md) · [Client](client.md) · [Design (E)](../docs/design/README.md)

Milestones run in order. A step is one or a few commits that leave `main` building and
are pushed on their own. Each step lists **Done when** (the evidence needed) and
**Deletes** (what goes away). Statuses use the four states: design, code,
acceptance, activation.

## Status

| Milestone                                                     | Design   | Code        | Acceptance | Notes                               |
| ------------------------------------------------------------- | -------- | ----------- | ---------- | ----------------------------------- |
| [M0 Unify the working tree](#m0-unify-the-working-tree)       | complete | complete    | n/a        | `e1a08db9`, `162c113b`              |
| [M1 Plans reset](#m1-plans-reset)                             | complete | in progress |            |                                     |
| [M2 Backend baseline](#m2-backend-baseline)                   | complete |             |            | Q1 decides the order of 2.4 and 2.5 |
| [M3 Usage ledger](#m3-usage-ledger)                           | complete |             |            | Q7                                  |
| [M4 Pots backend](#m4-pots-backend)                           | complete |             |            | Q6                                  |
| [M5 Client foundation](#m5-client-foundation)                 | complete |             |            | Q3, Q5                              |
| [M6 Work and settings screens](#m6-work-and-settings-screens) | outline  |             |            |                                     |
| [M7 Pots screens](#m7-pots-screens)                           | outline  |             |            |                                     |
| [M8 Android cutover](#m8-android-cutover)                     | outline  |             |            |                                     |
| [M9 Web cutover](#m9-web-cutover)                             | outline  |             |            | Q2, Q3                              |
| [M10 Embedded Tailscale](#m10-embedded-tailscale)             | spike    |             |            | Q4                                  |
| [M11 Release](#m11-release)                                   | outline  |             |            |                                     |

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

Goal: the backend only speaks the new flows, has one capability document, and starts
from a fresh schema. `main` keeps working with today's clients until step 2.5.

1. **First-send on by default.** Make `PIRC_FIRST_SEND` default to on, so both existing
   clients (which already follow `canSubmit`) create sessions through first-send.
   - Verify by reading `apps/web/src/lib/app.svelte.ts` and
     `apps/android/lib/live/gateway.dart`/`first_send.dart` that, with `canSubmit`
     true, neither client calls `POST /api/sessions` anywhere (drafts, chats, project
     chats, scheduled-session opening).
   - Update `docs/deploy` and `.env.example`.
     Done when: gateway tests for the capability default pass; a local run creates a
     session from the Web client through first-send.
2. **Move internal callers to the creation service.** `dispatch::start_session`
   (`crates/pirc-gateway/src/dispatch.rs`) is used by delegations and schedule runs and
   calls the Node's legacy `POST /api/sessions`. Give the Node's `session_creation`
   module an internal creation entry (no client draft, no first-message admission;
   the caller delivers its message with the existing `deliver`) and switch
   `start_session` to it. Pots dispatch keeps its own path until M4 replaces it.
   Done when: delegation and schedule tests pass against the new path.
3. **Delete legacy creation and unversioned paths.**
   - Gateway: `POST /api/sessions` (`routes::create_session`), the unversioned branch
     of `routes::command` (every command carries `expectedBinding`; confirm both
     current clients send it, and add it where missing first), the `PIRC_FIRST_SEND`
     gate and the `x-pirc-first-send-contract` header (replaced by 2.4).
   - Node: `POST /api/sessions`, `PIRC_LEGACY_HOST_TERMINALS` and the unreviewed
     host-shell path, the legacy workspace `kind` field (Gateway and Node).
   - Web and Android: the `canSubmit == false` fallbacks and `createSession` calls.
     Deletes: roughly 300–600 production lines plus their tests and fallbacks.
4. **One capability document.** `GET /api/capabilities` returns
   `{ apiVersion, server, features: { <name>: { supported, enabled, version } } }`.
   Clients send `X-Pirc-Client: <app>/<apiVersion>`; a client whose `apiVersion` the
   Gateway does not accept gets `426 client_upgrade_required` with a human-readable
   message (like the existing `request_shape_required` handling). Environment
   switching keeps its server-enforced `PIRC_ENVIRONMENT_SWITCHING` gate, now reported
   here. `/api/health` keeps only liveness.
   Done when: both current clients read it; gates are reported in one place.
5. **Fresh schema baseline** (breaking for deployments, not for clients).
   - Before deleting the chain, add a temporary test that builds a database through
     the old chain and compares the normalized `sqlite_schema` with the new baseline.
     Remove the test in the same step once it passes.
   - Gateway: one `schema.sql` set with final `CREATE` statements (rewrite the
     rename/recreate SQL such as `conversation_bindings/transitions/installation.sql`
     and the `ALTER`s in `attachments.sql`, `calendar/schema.sql`). New version
     `1100`. Node: same, version `2100`. The checkpoint journal keeps its own version.
   - Any other `user_version` is refused at startup with: "This state directory was
     created by an earlier pirc. pirc 2 cannot read it; move or delete `<dir>`."
   - Delete `MIGRATIONS`, `migrate()`, the fence-only steps, the TypeScript-era
     detection, the `remove_*.sql`/`test_remove_*.sql` files and the migration tests.
     Rewrite the few fail-closed tests that used a downgrade helper so they drop the
     table directly.
   - Docs: `docs/deploy/upgrades.md` states that pirc 2 needs fresh state directories.
     Deletes: about 3,000 lines (SQL, migration code, tests).
6. **Remove the legacy observational-memory archive** in
   `crates/pirc-agent/src/features/memory/` (read-only compatibility archive, ~3,700
   lines) and its docs (`docs/architecture/legacy-observational-memory.md`), keeping
   whatever the current handoff memory imports from it.
7. **Security defaults that no longer need a transition** (no compatibility to keep):
   - The Gateway refuses to start without `PIRC_PROXY_SECRET` unless
     `PIRC_PROXY_SECRET_REQUIRED=false` is set explicitly; the development scripts and
     `.env.example` set that explicitly, documented as development-only.
   - Management grants become separate capabilities `devices:read`,
     `devices:revoke` and `devices:pair`, each with its own confirmation text; pairing
     a new long-lived device says so and shows the lifetime.
     Done when: gateway tests cover both; docs and the Nix module are updated.

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
5. Budget admission hook used by M4.

---

## M4 Pots backend

Specification: [pots.md](pots.md). Steps (each a pushable slice):

1. **Schema and store** for pots, permissions, models, threads, messages, activity,
   approvals, handovers, de-duplication layers (pots.md [Data model](pots.md#data-model)).
2. **Pot CRUD API** (create in one request with all four steps' settings; read;
   update; pause/resume) and the global settings (caps, exhaustion policy, retention).
3. **Pot runtime on the chat node**: the `pot` mode replacing `chat`, one persistent
   session per pot, private directory, prompt assembly from personality and work
   description, wake queue and delivery.
4. **Threads and messaging**: user↔pot, groups (host, `@mention`, user-only `@all`),
   pot↔pot DMs with send/receive rules; pot tools for sending.
5. **Activity log and point-of-view queries**, with retention.
6. **Work dispatch**: open and continue work sessions through the creation service
   (M2.2), "From <pot>" provenance, allowed models with direct/ask, model approvals.
7. **Autonomy**: review timer, self-scheduling, thinking self-adjustment, fallback
   switching, all logged.
8. **Observation and de-duplication** (L0–L3) with causal-root accounting and limits.
9. **Handover, archive and delete**.
10. **Remove the old assistant and pots**: chat mode, `assistant_node` singleton
    claim semantics (the chat node stays as the pot host), `SOUL.md`/`CHAT.md`
    routes, chat projects that only served assistant chats, the model-free pots
    tracker (gateway `src/pots`, node `pots.rs` ledger once replaced), and the
    assistant tools that pot tools replace.
    Deletes: an estimated 10–15k lines including tests.

---

## M5 Client foundation

Specification: [client.md](client.md). Steps:

1. **Workspace layout**: Dart pub workspace, `apps/app` (new Flutter app, Android and
   Web targets), `packages/pirc_render`, `packages/pirc_client`, `packages/pirc_ui`.
   The old `apps/android` keeps building until M8.
2. **Rendering package**: break the `rendering/` ↔ `live/` cycle, inject localization,
   theme and host services, move engine files out of `live/`, put tier-3 code behind
   interfaces so chat Markdown does not compile it in, add test tags.
3. **Client package**: API models, the timeline reducer ported to Dart and tested
   against `fixtures/timeline/`, HTTP and WebSocket transport with Web and Android
   adapters, reconnect and cursor resume, command identities and uncertain-outcome
   markers.
4. **State and app shell**: Riverpod, routing, adaptive scaffold with the four layouts,
   design tokens from `docs/design/tokens.json`, light/dark, zh-TW and en catalogs.
5. **Test layout**: fast default suite per package, tags for slow/device/tier-3,
   safety regressions in the default suite, CI jobs updated.

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

## M9 Web cutover

Outline: Flutter Web build (self-hosted CanvasKit and fonts, CSP with
`'wasm-unsafe-eval'`, no inline scripts, hand-written service worker with build ID,
Web Push, cache headers); agent HTML in a sandboxed opaque-origin iframe (Q3);
web-only screens (management approval, pairing QR); Nix packaging and nginx headers;
delete `apps/web`.

## M10 Embedded Tailscale

Spike first (Q4): an Android build flavor embedding a userspace tailnet node
(`tsnet` through libtailscale or gomobile) that exposes a loopback proxy used by the
one Dart HTTP client and by the Kotlin background client; sign-in flow; behavior with
the system VPN off and in the background; battery cost. The Web cannot embed it.

## M11 Release

Outline: rewrite `README.md` and `docs/` for pirc 2, full validation run requested by
the owner, changelog with the breaking-change notice, version bump.

---

## Carried-over items

Filled by M1.2: open acceptance gaps and accepted limitations from the retired plans
that still apply to pirc 2.
