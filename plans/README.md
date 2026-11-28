# Open work

[Project](../README.md) · [Documentation](../docs/README.md) · [Design handoff](../docs/design/README.md) · [Historical records](../docs/development/historical-records.md)

This is the single entry point for current direction and open work. It was reset on
**2026-11-24** for the pirc 0.11.0 rewrite. Where any older text (in this folder, in Git
history, or in a document written before 2026-11-24) conflicts with this file or the
specifications it links, this file wins.

| File                                   | Contents                                                                                    |
| -------------------------------------- | ------------------------------------------------------------------------------------------- |
| [roadmap.md](roadmap.md)               | Ordered milestones M0–M14: steps, done criteria, what each one deletes                      |
| [pots.md](pots.md)                     | Multiple named pots: identity, permissions, runtime, messaging, budgets, activity, handover |
| [security.md](security.md)             | M9: security review, hardening, dependency updates                                          |
| [updates.md](updates.md)               | M10A: signed advisories and manual guidance; M10B: graceful updates, state bundles          |
| [polish.md](polish.md)                 | M13: pot roles, export, owner trial polish                                                  |
| [usage.md](usage.md)                   | Usage ledger, pricing, subscription accounting and the usage views                          |
| [client.md](client.md)                 | The single Flutter client (Android and Web): packages, transport, state, rendering, layout  |
| [design (E)](../docs/design/README.md) | Product design handoff: screens E1–E36, D and C specifications, tokens and prototypes       |

The plans before the reset are retired; see
[historical records](../docs/development/historical-records.md#retired-plans-2026-11-24).
Their still-valid invariants are in
[Behavioral contracts](../docs/architecture/contracts.md).

## Direction (2026-11-24)

pirc 0.11.0 is a breaking rewrite. It keeps the Rust Gateway/Node/agent topology, the
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
- **One breaking cutover.** Releases through 0.10.x cannot upgrade their data or
  keep using their old clients with 0.11.0. Schemas start at a fresh baseline and
  old databases are refused with a clear message. Updates from 0.11.0 onward
  keep data (P24).
- **New flows only.** Clients use first-send and versioned bindings only; legacy
  session creation and its fallbacks are deleted.

## Decisions

Decisions are dated. A later decision names what it supersedes.

### 2026-11-24 (rewrite)

| ID  | Decision                                                                                                                                                                                                                                                                                                                                                         |
| --- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| P1  | Design direction **E** (chat-style pots) is the product design, building on D (unified conversations) and C (visual language). The C decisions 1A/2A/3A from the earlier mobile handoff stay: Android first, the quick-reply overlay is required, and artifact updates are switched by the user. The archived handoff is on branch `archive/flutter-mobile-0.5`. |
| P2  | Pots are persistent agent sessions on the chat node that act autonomously unless paused. A pot that was never assigned work and never talked to is woken for an autonomy review after a configurable interval (default 2 days; can be turned off); the pot may lengthen, shorten or turn off its own review interval. Details: [pots.md](pots.md).               |
| P3  | The assistant chat feature is replaced by pots. `SOUL.md` becomes each pot's personality. Plain model questions go to a pot or to a new work session.                                                                                                                                                                                                            |
| P4  | All clients are Flutter, Web included (supersedes N4's "front-end technology evaluated separately" and the deferral of Flutter Web).                                                                                                                                                                                                                             |
| P5  | There is no migration from 0.10.x or earlier to 0.11.0. Old clients are not supported by 0.11.0. P24 governs later updates.                                                                                                                                                                                                                                      |
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
| P20 | Money caps count API-billed usage; subscription usage counts toward them, at the API-equivalent price, only when the user turns on "show API-equivalent price". Token caps count all usage (was Q7).                                                                                                                  |

### 2026-11-28 (owner)

| ID  | Decision                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| P21 | Three milestones are inserted before the release: M9 security review and hardening, M10 versions and updates, M13 final review and polish (pot roles, export, items from the owner's trial). The former M9, M10 and M11 become M11, M12 and M14. Import is later (P32).                                                                                                                                                                                                                                                                                                                                                                                                  |
| P22 | Version and advisory information comes only from a signed manifest. The Gateway, Node and app each verify it against a compiled-in offline root public key and the root's signing-key delegation; links go only to the repository's GitHub Releases.                                                                                                                                                                                                                                                                                                                                                                                                                     |
| P23 | M10A delivers signed advisories and manual update guidance; M10B separately delivers user-started graceful replacement (drain, back up, replace, restart, restore on failure, report). No in-process hot swap. A signed advisory is not authorization to replace software.                                                                                                                                                                                                                                                                                                                                                                                               |
| P24 | Starting with updates from an installed 0.11.0, deployed data is kept. Every schema change ships a forward migration tested from the previous supported release. P5 still applies to entering 0.11.0 from 0.10.x or earlier.                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| P25 | Revoking a permission, or pausing or archiving a pot, lets a run in progress finish its current reply; every effect it attempts afterwards is decided on the new permissions; work it opened stays open for the user (was Q9).                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| P26 | Only memory entries the user confirmed are placed in a pot's prompt; other pot notes are found with `memory_search` and arrive as data with their origin (was Q11).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| P27 | Pot roles do not affect groups in the Chat list filter (was Q14).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| P28 | Release CI uses a delegated manifest signing key from an owner-approved protected GitHub Environment. A separate offline root (never a CI secret) issues, replaces and revokes delegations (was Q13). See [updates.md](updates.md#decisions-owner-2026-11-28).                                                                                                                                                                                                                                                                                                                                                                                                           |
| P29 | Trust levels (was Q10): a pot's session context becomes external once it reads external content and stays so until the user resets it. Tools are classed read, internal, reversible effect, irreversible or outbound; the presets are Strict, Standard (default: irreversible or outbound calls at external trust need approval) and Trusted. Work and reminders inherit trust. An ordinary user-provided file does not lower trust by itself, but copying, uploading or summarizing known external content does not remove its origin. Approval cards can be batched and time-limited. See [security.md](security.md#step-3--trust-levels-effect-classes-and-the-gate). |
| P30 | External content reader (was Q16): pots normally get web pages through `web_read`, which returns a typed digest (or an answer to the pot's question) made by a reader run with no tools, memory or private context; the digest still makes the context external; reading the page itself is an approval card (Strict), allowed and logged with a reason (Standard) or allowed (Trusted); the reader model is one owner-wide setting, a small model by default. Details: [security.md](security.md#step-3b--external-content-reader).                                                                                                                                     |
| P31 | Install kinds (was Q12): a Docker Compose installation for the always-on host (the Gateway, and the chat node if the M10 spike finds narrow enough container settings), updated by a separate `pirc-updater` container that alone holds the Docker socket; native archives under systemd or launchd; Nix and NixOS kept, shown the advisory, link and commands only; coding nodes stay native; Android opens the release page.                                                                                                                                                                                                                                           |
| P32 | Export first (was part of Q15): M13 builds export only; pots export with settings and without memory; import comes later and scans every imported item with a review model in addition to rule checks.                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| P33 | Export items (was Q15): pot settings and conversations on by default; memory (USER entries and pot notes, with origin) as its own item, off by default; usage, activity, calendar and schedules, and settings off by default; work-session transcripts later. Never export system credentials, browser profiles or recovery snapshots. Conversation and memory exports require fresh approval for the exact selection; the other-device notice is not authority. "Share a pot" keeps settings without permissions or models. See [polish.md](polish.md#step-2--export).                                                                                                  |
| P34 | Desktop script documents (was Q8): M11's macOS build renders tiers 1–2 and shows script-bearing HTML statically, like Android today. When script documents get an entry point on every platform, macOS uses a `WKWebView` with a non-persistent store, no bridge, an opaque origin, network blocked until the user activates remote content, and no navigation, new windows or file access. Details: [client.md](client.md#rendering).                                                                                                                                                                                                                                   |
| P35 | The next release is named **pirc 0.11.0** (tag `v0.11.0`), with no separate generation name. Versions in the manifests stay unchanged until the M14 release commit.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| P36 | Docker's role: Docker installs and updates pirc; it is not a security layer. The agent sandbox stays the boundary inside a container exactly as on a native host, no sandbox check is relaxed there, and the chat node joins Compose only if the native sandbox tests pass unchanged in the container. Docker installs are for Linux hosts only; a Mac (Docker Desktop) uses the native archive.                                                                                                                                                                                                                                                                         |

## Pending owner decisions

None open (2026-11-28). New questions are added here with the default the plans
use until the owner decides.

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
