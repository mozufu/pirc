# M9 Security review and hardening

[Open work](README.md) · [Roadmap](roadmap.md) · [Pots](pots.md) · [Security decisions](../docs/architecture/security-decisions.md)

Goal: before pirc 0.11.0, the current implementation (pots, the Flutter client, the Gateway
and the nodes) gets a full security review, the fixes it calls for, and dependency
updates. Every fix lands with a regression test, and the security model the fixes
establish is written down in [Security decisions](../docs/architecture/security-decisions.md).

Why now: the last full review (2026-11-16) predates pots (M4) and the client rewrite
(M5–M8). Pots add autonomous agents that wake each other, keep long-term notes and
start work, so the review covers what an agent can be led to do, not only what a
client or a network peer can do.

**Where findings live.** Findings that describe a weakness which is not fixed yet
are kept in the owner's local review notes, never in this repository (Working rules:
Publishing). This section describes the intended behavior and the steps. Commit
messages describe what a change makes true ("re-check a pot's permissions when an
instruction is delivered"), not what was possible before.

**Model.** The review and the fixes follow a layered model drawn from current
agent-security practice (owner's research notes, 2026-11-27; primary sources are
listed at the end of this section). pirc adopts these principles:

1. **The backend decides, the model does not.** Every effect (opening or instructing
   work, a pot message that wakes someone, a handover, a memory write, an outbound
   request) is allowed or refused by deterministic Gateway or Node code that reads
   the current state at the moment of the effect. Prompts, permission summaries and
   source labels in model input help the model behave; they never enforce anything.
2. **Assume the model is fully misled.** Prompt injection is not solved by any model
   or detector. A defense counts only if it holds when the model does exactly what
   injected text tells it to. Tests use a scripted model that obeys the injection
   (step 9).
3. **Rule of Two per run.** A run should not combine all three of: reading content
   that neither the user nor pirc wrote; reading sensitive data or holding write
   access; changing state or sending outward. When a run needs all three, the third
   goes through the user's approval or a scope the user granted beforehand.
4. **Provenance is data set by the backend.** Where a wake, message or value came from
   is a typed field the Gateway sets from the authenticated actor and carries end to
   end (pots.md, Invariants 1 and 3). A text prefix such as "From <pot>" is
   presentation only.
5. **Memory binds its origin when it is written.** A stored note keeps where it came
   from; a later summary or copy does not raise its trust. Notes from untrusted
   origins inform, never authorize.

Ordering: step 0 first; step 1 (the review) next, its parts in parallel; steps 2–6
(3b included) are designs that the owner reviews before code, then code in the order 2, 3, 4, 5, 6;
step 7 holds the remaining fixes from step 1 in priority order; step 8 can run any
time after step 0; step 9 grows with steps 2–7; step 10 closes the milestone.
Implementation is done in small steps by delegated agents; the reviewing agent
checks each step against its **Done when**.

## Step 0 — Baseline and inventory

- Record the baseline commit of the review.
- Update the milestone numbers in source comments and documents outside `plans/`
  (P21): `README.md`, `docs/development/releasing.md`,
  `docs/development/gateway-and-node.md`, `.github/workflows/release.yml`,
  `apps/app/android/app/build.gradle.kts`,
  `apps/app/android/app/src/main/res/xml/network_security_config.xml`,
  `apps/app/android/app/src/main/kotlin/org/mozufu/pirc/background/GatewayHttp.kt`,
  `apps/app/lib/src/connection/pairing.dart`, `apps/app/lib/src/document_host.dart`,
  `apps/app/lib/src/document_host_io.dart`,
  `apps/app/lib/src/settings/pairing_approval.dart`,
  `crates/pirc-gateway/src/auth.rs` (old M9 → M11, M10 → M12, M11 → M14; the
  "M0–M9 records" in `historical-records.md` are the earlier Rust port and stay).
- Write the **inventory of sources and sinks** (local notes):
  - _Sources_ of content neither the user nor pirc wrote: every wake source of
    pots.md § Runtime (user message, group message, pot DM, observed event, approval
    result, handover, reminder, autonomy review), tool results of `web_fetch`,
    `web_search` and `browser_*`, files and Git history in workspaces, uploads,
    observed events' text, other pots' messages and notes, and each provider
    adapter's handling of them.
  - _Sinks_: every tool of pot and work mode (`crates/pirc-protocol/src/mode.rs`) that
    changes state or reaches outward, every Gateway route that changes state, every
    place a client renders agent content (links, images, forms, documents).
  - For each pot configuration dimension (reach, observe scopes, work locations and
    their access, DM rules, work models and their mode, autonomy review), which leg
    of the Rule of Two it adds.

**Done when:** the inventory lists every wake source, every mode tool and every
state-changing route, each with the layer that enforces it (Gateway, Node, agent,
client); the milestone numbers outside `plans/` are updated.

## Step 1 — Review (parallel parts, no code)

Each part reads code, runs existing tests where useful, and records findings with
their evidence grade: **reproduced** (a test with synthetic data shows it),
**read** (every line on the path was read), **not reproduced** (code suggests it, no
run), **assumption**. Historical results and this round's runs are kept apart; a
skipped test is not a pass (N8). The parts do not overlap:

- **1a Authorization and revocation.** Reach, work locations and access, DM rules
  (`dm_send`/`dm_receive`, selected peers), group mentions, dispatch and execution
  rights, handover re-checks, model approvals, budget requests, take-over, pause and
  archive; for each, whether it is checked at request time, at delivery time, or
  both, and what a change of permissions does to work and threads already open.
- **1b Provenance and dispatch.** How each wake source reaches the model in each
  provider adapter (role, wrapping, escaping), how pot-to-pot and pot-to-work text is
  marked, whether any path lets text stand in for the user (Invariant 1), and which
  decisions depend on the model reading a label correctly.
- **1c Memory and long-lived state.** Pot notes, USER entries, workspace memory,
  observational memory, and anything a run can leave for a later run: reminders,
  `set_autonomy`, `set_thinking`, schedules, files in the pot's directory.
- **1d Execution boundary.** Agent sandbox (Seatbelt, bubblewrap, network proxy), the
  browser (process placement, flags, profile, private-host filtering, downloads),
  the PTC guest, side-panel terminals, outbound network policy, and ways content can
  leave through rendering (remote images, links, forms, documents) on Android, Web
  and macOS.
- **1e Earlier findings.** Each item of the 2026-11-16 review, re-checked on the
  current tree: fixed, changed, still open or no longer applicable.
- **1f Dependencies and supply chain.** `cargo audit`/`cargo deny` over the locked
  tree, Dart/Flutter packages, Android Gradle dependencies, pinned GitHub Actions, the
  Chromium version policy, and what release artifacts contain.

**Done when:** each part has a findings list with grades and a proposed minimal fix,
plus what it did not cover; the owner has the merged priority list (local).

## Step 2 — Authorization at the point of effect

Intended behavior:

- **One decision point.** A single Gateway function decides every pot effect: opening
  work, sending an instruction into work, `message_send`, a group mention that wakes a
  pot, a dispatch to another pot, applying a handover, a dispatch caused by an
  observed event. It is called at delivery, reads the pot's current state, reach,
  locations, access, DM rules and models, and records the decision. Request-time
  checks stay as early feedback; they are never the only check (pots.md, Reach
  levels: "checked when the request is made and again when the work starts").
- **Revocation applies to what is already open.** Narrowing a permission, pausing or
  archiving a pot, or removing a DM peer takes effect at that pot's next effect point,
  including work it opened earlier and DM threads that already exist. A run already
  in progress finishes its current reply; every effect it attempts after the change
  is decided on the new permissions; work it opened stays open for the user (P25).
- **Order revocation and admission explicitly.** For a Gateway effect, commit the
  authorization check and admission together against the current permission
  revision. For a Node effect, carry the bound operation identity and revision to
  the last enforceable admission point and reject stale or unconfirmed authority.
  An effect waiting in a queue has not crossed that point. If revocation wins,
  refuse the effect; if admission wins first, that effect may finish, but its
  authority does not extend to subsequent operations. A lost response is
  reconciled by operation identity, not retried as a new effect.
- **One-time approvals bind the operation.** An "allow once" covers exactly the start
  the user saw: workspace, title, a digest of the instruction, provider, model and
  thinking level. A start that differs in any of these is refused with
  `approval_mismatch`. The approval sheet shows the instruction (collapsed when
  long). An approval also ends when it is used, when the pot's permissions revision
  changes, or after 24 hours.
- Tests: a table test over every effect point × every revocation kind (permission
  narrowed, pot paused, pot archived, peer removed, location made read-only); a
  mutation test that changes each bound field of an approval and expects refusal.

**Done when:** the table and mutation tests pass in conformance; no effect point
calls the pot tools' store functions without the decision function.

## Step 3 — Trust levels, effect classes and the gate

Intended behavior (P29):

- **Every run has an origin**, set by the Gateway: `user` (the user's own message or
  mention), `pot` (another pot's DM, mention, handover or dispatch), `event` (an
  observed event), `self` (a reminder or autonomy review the pot scheduled), `system`
  (approval results and other Gateway cards).
- **Trust belongs to a session context, not to one run.** A pot has one long-lived
  session. The context becomes _external_ as soon as external input is admitted and
  stays there through compaction until the user resets it. For an effect, use
  _external_ if either the context or any input for the run is _external_:
  a clean input never resets an external context.

  | Source                                  | Input trust                                                                                                                                 |
  | --------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
  | Authenticated `user` message or mention | Clean for the user's own text; forwarded or attached content keeps its own provenance.                                                      |
  | `pot` message, handover or dispatch     | External for the sender's text; backend routing metadata grants no authority by itself.                                                     |
  | Observed `event`                        | Clean for backend-generated typed facts; external for source free text.                                                                     |
  | `self` reminder or review               | A typed timer alone is clean; reminder text and other saved input inherit the trust recorded when written.                                  |
  | Typed `system` result                   | Clean for backend-generated facts; included material keeps its own trust. Only the separately recorded decision grants its specific effect. |
  | Tool or resource results                | Web and reader content is external; work results inherit the work's trust. Ordinary user-provided files do not lower it by themselves.      |

  Backend-tracked derivatives keep the lowest input trust when copied, summarized,
  saved as a note or reminder, attached to a file, or passed to another pot or work
  session. Unknown provenance on agent-generated or imported material is not a
  clean source. The step 0 inventory must identify where provenance can be enforced;
  where it cannot be established, do not treat the material as clean. Provenance and
  effect authorization are separate: even clean content grants no permission.

- **Every tool has an effect class**, kept in a Gateway and Node table the model never
  sees as a rule it can change:
  - _read_;
  - _internal_: writes only the pot's own state (notes, reminders, its thinking and
    review interval);
  - _reversible effect_: opens or instructs work in a write location (file changes are
    covered by checkpoints), messages or wakes another pot inside pirc;
  - _irreversible or outbound_: `git push` and other network writes from work, sending
    anything beyond pirc, deleting, handing over, starting an `ask` model, asking for
    money, changing settings.

  Classify by the effect the backend can enforce, not by the tool name or the
  model's explanation. If a call can perform several effects, use the most
  restrictive applicable class; an unclassified effect is refused. A general-purpose
  execution call is not considered read-only or reversible unless its boundary
  enforces that restriction.

- **Per-pot trust preset**, chosen when the pot is created and in its settings:

  | Preset             | At _external_ trust                                                                                                        |
  | ------------------ | -------------------------------------------------------------------------------------------------------------------------- |
  | Strict             | _reversible effect_ and _irreversible or outbound_ calls become approval cards                                             |
  | Standard (default) | _reversible effect_ calls run within the pot's permissions; _irreversible or outbound_ calls become approval cards         |
  | Trusted            | the trust level adds no approvals; the pot's permissions still apply, and the step 5 combination warning must be confirmed |

  At _clean_ trust every preset behaves as today: permissions decide.
  In any row, a missing permission, unsupported operation, or stale revision
  is a refusal, not an approval card. A preset cannot widen a permission.

- **The gate** is in the step 2 decision function and in the Node's tool path for work
  sessions. Work opened or instructed from an _external_ context starts _external_ and
  uses the opener's preset, so a chain through another pot or a work session cannot
  wash the level clean. Reminders, notes and self-settings written from an _external_
  context carry that level forward (step 4).
- **Network from external work** stays inside the sandbox's domain allowlist even
  where the session's own settings would allow more: a read with data in its address
  is a way out.
- **When the user asked for it.** A user-origin run in an _external_ context still gets
  the card for an _irreversible or outbound_ call, marked "you asked for this in this
  message", answered with one tap: the content of the action may have been changed by
  what the context holds.
- **Batching.** Cards from one causal root are grouped on one sheet. A card can be
  answered "allow for this work for 2 hours" (or another listed duration); the grant
  is bound to the work session, the effect class and the target, and ends early when
  the pot's permissions change. A batch is presentation only: it does not approve
  unseen operations. Show the bound scope and expiry for a time-limited grant; an
  operation-specific allow-once decision keeps the exact binding in step 2.
- **Resetting trust.** **Reset trust** on the pot's settings starts a fresh context:
  the transcript stays readable, but nothing from before is in the model's context any
  more and no summary of it is carried over. Notes and reminders keep their own level
  (step 4); the confirmation says the pot will not remember the conversation.
- **Presentation (advisory).** Each provider adapter shows a non-user wake inside a
  Gateway-made envelope with the typed origin, a per-run random boundary and the
  content escaped so it cannot close the envelope; where a provider supports it,
  external content goes in a tool-result position rather than a user turn. Nothing
  relies on the model honoring this.

**Done when:** origin and trust are stored on every run and context and shown in the
pot's activity and header; the effect table covers every mode tool; conformance with
the scripted obeying model shows, for each preset, which calls run and which become
cards, including chains through a pot and a work session, reminders, and a reset;
envelope escaping has a test with boundary-forging input; the preset picker and reset
have goldens at four widths.

## Step 3b — External content reader

Intended behavior (P30; the owner's idea, 2026-11-28): pots normally read a
model-made digest of a web page instead of the page, and read the page itself only
when they need to.

Design:

- **A reader run** with no tools, no memory, no prompt of the pot's and no user data.
  It sees only the page's visible text (from the accessibility tree, so hidden text is
  dropped) and, optionally, the pot's question. It holds only one leg of the Rule of
  Two (untrusted input): it cannot act and has nothing private to leak.
- **Typed output**, validated by the Gateway: title, up to N short facts (each length
  capped), the answer to the pot's question if one was given, and links. A link is
  kept only if it appears in the page itself; anything that fails the schema is
  dropped, not repaired.
- **Asking the page.** `web_read(url, question?)` returns the digest; with a question
  the reader answers it from the page, which covers most "find the command / the date
  / the price" needs without the page entering the pot's context.
- **The page itself.** `web_read(url, raw: true)` with a stated reason. Strict: it is
  an approval card. Standard: allowed, logged with the reason in the pot's activity.
  Trusted: allowed.
- **Trust does not change.** The digest still makes the context _external_: a digest
  written by a model that read a hostile page can carry the hostile page's request
  (summaries are a known laundering path). The reader lowers how often a pot is
  misled and keeps long pages out of its long-lived context; the step 3 gate stays
  the guarantee.
- **Cost and model.** One extra model call per page, charged to the pot's budget and
  causal root. The reader model is an owner-wide setting (a small, cheap model by
  default), separate from the pot's models; a per-pot setting is not planned.
- Later, the same reader may front observed events' free text and long pot messages.

**Done when:** tests that the reader's request carries nothing but the
page and the question; schema validation drops forged links and oversized fields; a
conformance case where the page tells the reader to tell the pot to push still meets
the step 3 card.

## Step 4 — Memory provenance

Intended behavior (P26):

- Each pot note stores its origin: the run, the run's origin and trust level, and the
  time. Notes are listed to the user with that origin.
- Only entries the user confirmed (USER entries, and pot notes the user promoted) are
  placed in a pot's prompt. Other notes are retrieved with `memory_search` and arrive
  as tool results with their origin, as data.
- A note written at _external_ trust is never promoted automatically and never counts
  as the user's preference or consent. Explicit promotion changes prompt eligibility,
  not provenance; including an external note makes the context external.
- The user can promote, edit or forget any note from the pot's memory screen.

**Done when:** a conformance test shows a note written by a misled run does not reach
the next run's prompt and cannot authorize an effect; the memory screen shows origin
and offers promote.

## Step 5 — Capability combinations

Intended behavior: when a pot is created or its settings are saved, the Gateway
computes which legs of the Rule of Two the configuration holds (external reading,
sensitive access, effect or outbound) and whether the pot acts unattended (autonomy
review on, or observe scopes). When all three legs and unattended action meet, the
settings screen names the combination and asks for explicit confirmation; the step 3
gate still applies afterwards. The confirmation is stored with the settings revision.

**Done when:** the combination is computed in one place with a table test; the
settings screens (new pot, pot settings) show the warning; goldens at four widths.

## Step 6 — Browser and sandbox isolation

Design first for native installations, per platform, then code. M9 does not
depend on container results. M10's container spike owns any additional
containers-only decisions and verifies them against the same invariants.

- Where the agents' Chromium runs relative to the agent sandbox, and whether its own
  renderer sandbox can be on (Linux inside or beside bubblewrap; macOS beside
  Seatbelt). Measure what breaks; choose per platform; document the result in
  [Sandbox and browser](../docs/deploy/sandbox-and-browser.md).
- Browser profiles per session or per pot, holding no credentials unless the user
  signs in on purpose; downloads confined; private-host filtering kept.
- An optional outbound allowlist per pot for browser and fetch.

**Done when:** the per-platform decision is documented with what it protects and what
it does not; Linux checks run in Linux CI; the owner accepts the remaining trade-offs.

## Step 7 — Remaining fixes

The findings from step 1 not covered by steps 2–6, one small step each, in the order
of the merged priority list (evidence × impact ÷ cost). Each step names its
regression test. Findings graded "not reproduced" or "assumption" get a test first;
they are fixed when the test confirms them, or closed with the test as evidence.

## Step 8 — Dependencies and disclosure

- Update dependencies within their compatible ranges (Cargo, Dart/Flutter, Gradle),
  refresh `cargoHash` in `nix/package.nix`, and re-run the fast checks.
- Add `cargo deny` (advisories, licenses, sources) to the Check workflow; record each
  allowed exception with its reason and an expiry date.
- Add `SECURITY.md` with GitHub private vulnerability reporting, the supported
  versions (from the M10 manifest once it exists) and what counts as in scope.

**Done when:** `cargo deny check` passes in CI; `SECURITY.md` is published; the
dependency changes are listed in `CHANGELOG.md` under Unreleased.

## Step 9 — Adversarial tests

- Conformance uses synthetic source data and a scripted model to request effects.
  Use the step 3 source and effect tables as the test oracle: forbidden or stale
  operations never take effect, operations requiring approval wait for the bound
  decision, and permitted operations actually complete. Cover every preset and the
  step 2 revocation ordering, including already-open work and queued effects.
- For each defense of steps 2–6, at least one test written against that defense
  (the attacker knows it): forged envelopes, laundering through notes, reminders,
  another pot or a work session, approval reuse with changed arguments.
- An optional owner-run check with real models; it costs money and is never run by
  an agent without the owner's request (as with real-provider smoke tests).

**Done when:** the suite runs in Linux CI, every source and sink is mapped to a
tested policy class (or a reason it cannot occur), and each class has an allowed
case where applicable and a refusal or approval case where required. Distinct
enforcement paths are tested separately.

## Step 10 — Close

Re-run the step 1 checklist on the final tree; mark each finding fixed, accepted
(with the owner's reason) or moved; update `docs/architecture/security-decisions.md`
with the model above; set the status row. M14 re-reviews security boundaries
added or changed after this milestone; M9 does not certify those later changes.

**Not in M9:** separating a trusted planner from a quarantined model (CaMeL-style
dual models), learned injection detectors, and fine-tuned models. They may be
reconsidered after the release; the steps above do not depend on them.

**Primary sources** (claims are the authors' own unless noted):
Meta, _Agents Rule of Two_ (2025-10);
OpenAI, _Designing AI agents to resist prompt injection_ (2026-03);
Anthropic, _Mitigating the risk of prompt injections in browser use_ (2025-11) and
_Claude in Chrome is generally available_ (2026-08);
Beurer-Kellner et al., _Design Patterns for Securing LLM Agents against Prompt
Injections_, arXiv 2506.08837;
Debenedetti et al., _CaMeL_, arXiv 2503.18813;
Nasr et al., _The Attacker Moves Second_, arXiv 2510.09023;
Ma et al., _ROPE_, arXiv 2608.27496;
Zheng et al., _APEX_, arXiv 2610.06966;
Hempel et al., _Kairos_, arXiv 2610.18457;
Lim et al., _SPILLWAY_, arXiv 2611.07222;
Xu et al., _CapLite_, arXiv 2611.17115;
Louck, _Non-Malleable, Origin-Bound Authority_ (TMA-NM), arXiv 2606.24322;
Li et al., _SAFE-Mem_, arXiv 2610.22959;
Karunanidhi, _Utility Under Attack_, arXiv 2608.21230;
OWASP, _MCP Security Cheat Sheet_.
