# Open work

[Project](../README.md) · [Documentation](../docs/README.md) · [Design handoff](../docs/design/README.md) · [Historical records](../docs/development/historical-records.md)

This is the single entry point for current direction and open work. It was reset on
**2026-11-24** for the pirc 2 rewrite. Where any older text (in this folder, in Git
history, or in a document written before 2026-11-24) conflicts with this file or the
specifications it links, this file wins.

| File                                   | Contents                                                                                    |
| -------------------------------------- | ------------------------------------------------------------------------------------------- |
| [roadmap.md](roadmap.md)               | Ordered milestones M0–M11: steps, done criteria, what each one deletes                      |
| [pots.md](pots.md)                     | Multiple named pots: identity, permissions, runtime, messaging, budgets, activity, handover |
| [usage.md](usage.md)                   | Usage ledger, pricing, subscription accounting and the usage views                          |
| [client.md](client.md)                 | The single Flutter client (Android and Web): packages, transport, state, rendering, layout  |
| [design (E)](../docs/design/README.md) | Product design handoff: screens E1–E36, D and C specifications, tokens and prototypes       |

The other files in this folder (`unified-*.md`, `conversation-*.md`, `checkpoints.md`,
`execution-isolation.md`, `transition-installation.md`, `mobile.md`, `pots/`, …) are
**reference material awaiting retirement** in milestone M1. Read them only for the
contracts that [roadmap M1](roadmap.md#m1-plans-reset) lists as still valid; their
status lines, queues, "do not ask again" wording and authorization statements are void.

## Direction (2026-11-24)

pirc 2 is a breaking rewrite. It keeps the Rust Gateway/Node/agent topology, the
security model and the sandbox, and replaces the product surface:

- **One Flutter client for Android and Web.** The Svelte web app and the current
  Flutter UI are replaced by one Flutter codebase that follows design direction E.
  The native rendering engine is kept and extracted into a package.
- **Chat = pots and groups; Work = sessions.** The Chat tab holds named pots and
  groups. The Work tab holds sessions (the former chat/work split, merged), grouped
  by project; the user and pots both talk in them. Activity and Calendar complete the
  four tabs.
- **Multiple named pots replace the assistant chat.** Each pot is a persistent,
  autonomous agent with its own personality, memory, permissions, models and budget.
  The assistant chat, chat mode, `SOUL.md`/`CHAT.md` and the model-free pots tracker
  are removed.
- **No compatibility.** Deployed data is not kept and old clients are not supported.
  Schemas restart from a fresh baseline; old databases are refused with a clear
  message.
- **New flows only.** Clients use first-send and versioned bindings only; legacy
  session creation and its fallbacks are deleted.

## Decisions

Decisions are dated. A later decision names what it supersedes.

### 2026-11-24 (pirc 2)

| ID  | Decision                                                                                                                                                                                                                                                                                                                                                         |
| --- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| P1  | Design direction **E** (chat-style pots) is the product design, building on D (unified conversations) and C (visual language). The C decisions 1A/2A/3A from the earlier mobile handoff stay: Android first, the quick-reply overlay is required, and artifact updates are switched by the user. The archived handoff is on branch `archive/flutter-mobile-0.5`. |
| P2  | Pots are persistent agent sessions on the chat node that act autonomously unless paused. A pot that was never assigned work and never talked to is woken for an autonomy review after a configurable interval (default 2 days; can be turned off); the pot may lengthen, shorten or turn off its own review interval. Details: [pots.md](pots.md).               |
| P3  | The assistant chat feature is replaced by pots. `SOUL.md` becomes each pot's personality. Plain model questions go to a pot or to a new work session.                                                                                                                                                                                                            |
| P4  | All clients are Flutter, Web included (supersedes N4's "front-end technology evaluated separately" and the deferral of Flutter Web).                                                                                                                                                                                                                             |
| P5  | Deployed data is not kept; updates are not compatible with old versions. No migrations are written for the rewrite.                                                                                                                                                                                                                                              |
| P6  | Clients use only the new flows. First-send becomes the only creation path; the legacy session-creation paths are deleted once the internal callers have moved.                                                                                                                                                                                                   |
| P7  | Subscription usage is recorded as tokens labelled with the subscription plan. An API-equivalent price may be shown, optionally, and is always marked as an estimate.                                                                                                                                                                                             |
| P8  | Pot memory is isolated per pot. Pots may hand work directly to each other without the group host when the sender holds the dispatch right and the receiver the execution right; chains share the causal root's budget and depth limit. Consents given to a pot transfer to its successor on handover and are re-checked before starting.                         |
| P9  | `@all` exists in groups for the **user only**; the composer warns that every pot will be woken before sending. Pots cannot address everyone.                                                                                                                                                                                                                     |
| P10 | The three reach levels (answer only; observe and suggest; may start work) and the layered de-duplication (source event, per-pot observation, user notification, dispatch) are the permission and dedup model. Finer per-pot permissions (per project, per action) are planned later and must fit this model.                                                     |
| P11 | Publication resumes: commits go straight to `origin/main`, one small step at a time (supersedes follow-up (h) of 2026-11-16). Rules are in [Working rules](#working-rules).                                                                                                                                                                                      |
| P12 | Every milestone is written into [roadmap.md](roadmap.md) before it starts, with ordered steps and details detailed enough for another agent to continue.                                                                                                                                                                                                         |

### Still in force from 2026-11-16 and 2026-11-17

- **N1** native rendering stays on Android, for user experience; mainline is common
  content, interaction, keyboard and smoothness; Chromium-parity details are frozen.
  Common HTML forms are mainline. "Frozen" stops specification growth; safety, crash,
  resource and isolation defects are still fixed and their regressions stay in the
  default test set.
- **N3** the App works without a Web front end open; HTTPS/WSS, the Gateway, the
  reverse proxy and the security boundaries stay.
- **N6** multiple named pots (now specified in [pots.md](pots.md)). Another pot's
  message never stands in for user authorization; there is no channel the user cannot
  read.
- **N7** governance: new decisions name what they supersede; still-valid safety and
  data-protection contracts are kept.
- **N8** an accepted request is never re-sent through another flow after a timeout.
  A skipped test is not a pass.
- Status uses four separate states: design complete, code complete, acceptance
  passed, activation allowed.
- Agent content never obtains the app's first-party identity; activating a control in
  agent content is not approval to use the app's execution or management rights.
- Remote images and media in untrusted content load only after the user activates
  them; there is no Gateway image proxy.

N2 (rewrite limited to the existing Android UI), N4 (front-end technology evaluated
separately), N5 (Kotlin keeps all transport) and follow-up (h) (publication paused)
are superseded by P1, P4, P17 and P11.

### 2026-11-24 follow-ups (owner answers)

| ID  | Decision                                                                                                                                                                                                                                                                                                              |
| --- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| P13 | `main` does not need to stay usable during the rewrite. Old clients may break; CI may be red between steps and is repaired later. Steps are ordered for development efficiency.                                                                                                                                       |
| P14 | Native desktop builds are wanted besides the browser. Near-term development and testing cover **macOS** only; Linux and Windows come later. The Svelte app gets no new work and is deleted at the Flutter Web cutover.                                                                                                |
| P15 | Agent HTML: the native engine on Android; on Web the browser shows script-bearing documents in a sandboxed iframe with an opaque origin. The platforms may render such documents differently.                                                                                                                         |
| P16 | Embedded Tailscale (Android first): official Tailscale service; the deployment is Gateway + nginx + Authelia reachable only inside the tailnet; the app signs in through the Tailscale login page inside the app. Android ships two builds, with and without the embedded node. Flutter Web does not embed Tailscale. |
| P17 | Transport is chosen by the implementer for resource use and speed. Choice: Dart owns networking; Kotlin keeps only what needs Android, plus a slim background client (rationale in [client.md](client.md#transport)). Supersedes N5.                                                                                  |
| P18 | Autonomous spending is charged to the pot's budget; when it runs out the pot stops and notifies the user; it never raises its own limits. A pot can read its own budget to plan, and can ask the user for more through a decision card and notification; only the user's approval raises it.                          |
| P19 | Pots need a loop guard: high-volume collaboration is fine while it makes progress; ineffective cycles (for example A hands work to B and B immediately hands it back) are detected and stopped. See [pots.md](pots.md#loop-guard).                                                                                    |

## Pending owner decisions

Each has a default the plans use until the owner decides.

| ID  | Question                             | Default used in the plans                                                                                                                              | Blocks |
| --- | ------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------ | ------ |
| Q7  | Money caps and subscription usage    | Token caps count all usage; money caps count API-billed usage, plus subscription usage at API-equivalent price only when the user turns that option on | M3, M4 |
| Q8  | Script-bearing agent HTML on desktop | Like Web: an isolated web view with a non-persistent data store and no app bridge; tiers 1–2 use the Dart engine                                       | M9     |

## Working rules

- **Commits** use English messages in the existing `type(scope): summary` form, with
  the repository's configured author. Do not name any AI agent or tool in a commit,
  and add no co-author trailers.
- **Publishing**: push each small, coherent step straight to `origin/main`; no pull
  requests. Do not push `audit/` (local-only, excluded through `.git/info/exclude`)
  and do not describe unfixed security weaknesses in public files; describe the
  intended behavior instead.
- **Testing per push**: run only fast, targeted checks for what changed (format,
  `cargo check`/Clippy and unit tests of the touched crates, `flutter analyze` and the
  touched package's fast tests, Prettier for touched docs). Do not run the full Nix,
  Flutter or conformance suites per push; the owner asks for full acceptance runs.
  Report what ran, what was skipped and what failed, separately.
- **Plans first**: before starting a milestone, its section in
  [roadmap.md](roadmap.md) must hold ordered steps and details. Update the status
  table there as steps land; do not add diaries.
- **Large files**: split a file over ~1,500 lines when a step substantially changes
  it; do not open separate refactoring work for untouched files.
- **Deleting code**: the rewrite deletes aggressively, but only what its step names.
  Unfamiliar uncommitted files are treated as owner work.
