# pirc 2 roadmap

[Open work](README.md) · [Pots](pots.md) · [Usage](usage.md) · [Client](client.md) · [Design (E)](../docs/design/README.md)

Milestones run in order. A step is one or a few commits that leave `main` building and
are pushed on their own. Each step lists **Done when** (the evidence needed) and
**Deletes** (what goes away). Statuses use the four states: design, code,
acceptance, activation.

## Status

| Milestone                                                     | Design   | Code        | Acceptance | Notes                                               |
| ------------------------------------------------------------- | -------- | ----------- | ---------- | --------------------------------------------------- |
| [M0 Unify the working tree](#m0-unify-the-working-tree)       | complete | complete    | n/a        | `e1a08db9`, `162c113b`                              |
| [M1 Plans reset](#m1-plans-reset)                             | complete | in progress |            | steps 1–3 done (`287f1152`, `a165ee7a`, retirement) |
| [M2 Backend baseline](#m2-backend-baseline)                   | complete | in progress |            | steps 1–4 done                                      |
| [M3 Usage ledger](#m3-usage-ledger)                           | complete |             |            | P20                                                 |
| [M4 Pots backend](#m4-pots-backend)                           | complete |             |            | Q6                                                  |
| [M5 Client foundation](#m5-client-foundation)                 | complete |             |            |                                                     |
| [M6 Work and settings screens](#m6-work-and-settings-screens) | outline  |             |            |                                                     |
| [M7 Pots screens](#m7-pots-screens)                           | outline  |             |            |                                                     |
| [M8 Android cutover](#m8-android-cutover)                     | outline  |             |            |                                                     |
| [M9 Web and macOS cutover](#m9-web-and-macos-cutover)         | outline  |             |            | Q8                                                  |
| [M10 Embedded Tailscale](#m10-embedded-tailscale)             | spike    |             |            |                                                     |
| [M11 Release](#m11-release)                                   | outline  |             |            |                                                     |

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
9. **Conformance and CI repair.** The conformance suite runs only on Linux, so it is
   verified through the Check workflow (`gh workflow run check.yml --ref <branch>`).
   - About 45 conformance files create sessions with the removed
     `POST /api/sessions`. Add one harness helper that starts a conversation through
     first-send (prepare, accept, materialize, dispatch, wait for the run) and use it
     everywhere; snapshots that recorded the old route are re-recorded.
   - Terminal tests that set `PIRC_LEGACY_HOST_TERMINALS` move to isolated-work
     terminal requests; workspace creation in fixtures passes `mode`, not `kind`.
   - Fix the failures that predate the rewrite: `pirc-node` Linux sandbox tests do not
     compile (private `pty` module, a macro syntax error), and the Nix hash job fails.
     Done when: the Check workflow is green on `main`, or every remaining failure is
     listed here with its cause.

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
    assistant tools that pot tools replace. Split the session-level legacy
    observational memory out of `crates/pirc-agent/src/features/memory/` (moved
    here from M2.6): keep what workspace memory and the per-pot memory use, delete
    the read-only archive and `docs/architecture/legacy-observational-memory.md`.
    Deletes: an estimated 10–15k lines including tests.

---

## M5 Client foundation

Specification: [client.md](client.md). Steps:

1. **Workspace layout**: Dart pub workspace, `apps/app` (new Flutter app, Android and
   Web targets), `packages/pirc_render`, `packages/pirc_client`, `packages/pirc_ui`.
   The old `apps/android` keeps building until M8.
   The Android app has two Gradle flavors from the start, `standard` and `tailscale`
   ([client.md](client.md#embedded-tailscale-m10)), selected together with
   `--dart-define=PIRC_TAILSCALE`; until M10 they differ only in application ID.
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
