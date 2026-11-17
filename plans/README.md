# Open work

[Project](../README.md) · [Documentation](../docs/README.md) · [Historical records](../docs/development/historical-records.md)

**Current architecture specification (2026-11-07):** [Completion contracts](unified-completion-contracts.md)
contains the authoritative [status snapshot](unified-completion-contracts.md#c0-authority-current-snapshot-and-scope),
accepted [operation continuation policy](unified-completion-contracts.md#c1-durable-operation-authority),
38-finding [traceability](unified-completion-contracts.md#c11-audit-traceability-and-remaining-configuration)
and staged gates. This is a document-only/local-commit update; the implementation
goal remains paused. Historical publication/resume notes below are not permission
to push or resume work now.

<a id="direction-update-2026-11-16"></a>

## 2026-11-16 direction update

This is the single authoritative entry point for the current direction. The
project owner made the decisions below on 2026-11-16. Where they conflict with
text written around 2026-10-24 or 2026-11-07 (including wording such as "adopted"
or "do not ask again"), these decisions win. Superseded text is kept for history
and carries a dated marker pointing here. The list of superseded and updated
clauses was prepared from local audit notes (not in this repository). Safety and
data-protection contracts that still apply are kept.

### Decisions

- **N1 - Native content rendering.** The native-content requirement stays, for the
  sake of user experience. The near-term mainline is common content, interaction,
  keyboard handling and smoothness; rare syntax and Chromium-compatibility details
  leave the mainline. Replacing the whole rendering layer with a WebView is not
  authorized; alternatives are compared before any decision.
- **N2 - Flutter rewrite scope.** The scope is the interface, state management and
  data layer, plus necessary rendering performance and integration fixes. This
  un-defers the U3 interface work. The `pirc-mobile-handoff` material is a
  reference, not a frozen specification. Flows, data models and component
  boundaries are mapped first.
- **N3 - Independent App.** "App independent" means no Web front end needs to be
  open. HTTPS/WSS, the Gateway, the reverse proxy and the existing security
  boundaries stay. Startup and switching waits are measured first; caching,
  paging, incremental sync, on-demand loading and reconnect/resume are evaluated
  afterwards. First sign-in, pairing and management authorization that do not
  depend on the Web are designed separately; the existing management approval
  mechanism is kept.
- **N4 - Positioning.** The App's operating experience is the design starting
  point; Web keeps functional parity. Both share backend contracts, permissions
  and operation semantics. Whether the front-end technology is unified is
  evaluated separately.
- **N5 - iOS.** iOS is not part of the near or medium term. Kotlin transport is
  not moved to Dart for a hypothetical iOS; the split follows Android needs,
  testability and maintenance cost.
- **N6 - Multiple named pots.** Several named pots replace the single-assistant
  design. Each has its own responsibilities, observation scope and permissions;
  pots can message each other, join groups and dispatch within limits. Dispatch
  inside granted authority needs a dispatch right on the sender and an execution
  right on the receiver, with resources and budgets checked at execution time.
  Another pot's message never stands in for user authorization. Source marking,
  task linkage, de-duplication, shared budgets, depth limits and stop controls are
  kept; a group message must not wake every pot. The user can see pot messages in
  sessions, between pots and in groups. There is still one user.
- **N7 - Governance.** The project is led by the owner. New decisions name the
  clauses they supersede, the date and the scope. Safety and data-protection
  contracts that still apply are kept. There is no default requirement to rewrite
  crate layering, the Gateway/Node topology or the conformance method.
- **N8 - Process.** New interfaces join the new flows through clear data
  interfaces and capability negotiation, not by turning every switch on. An
  accepted new request is never re-sent through the old flow after a timeout.
  Before any publication the remote and target branch are checked, updates are
  integrated and test evidence is confirmed; historical and current results are
  recorded separately; a skipped test is not a pass; no release is created. See
  follow-up (h) for the current pause.
- **N9 - Method.** The baseline is unified first, then a small number of parallel
  reviews follow and the main agent integrates them.

### Superseded and updated clauses

| File                                                                   | Original gist                                                                            | Disposition                                                                       |
| ---------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| [pots/README.md](pots/README.md)                                       | pots is one owner-scoped identity                                                        | Superseded (N6): several named pots under one owner                               |
| [pots/design.md](pots/design.md)                                       | One stable assistant entry point                                                         | Superseded (N6): each pot has its own entry point, plus an overview               |
| [pots/design.md](pots/design.md)                                       | First scope is one assistant identity; multiple named assistants are a later decision    | Superseded (N6): multiple named pots are formal scope                             |
| [pots/design.md](pots/design.md)                                       | pots has one assistant identity with an overview/inbox                                   | Superseded (N6)                                                                   |
| [pots/design.md](pots/design.md)                                       | Agents may not produce a mutual-dispatch loop                                            | Superseded (N6): bounded mutual dispatch is allowed; unbounded loops stay barred  |
| [unified-conversations.md](unified-conversations.md)                   | Same mutual-dispatch gate sentence                                                       | Superseded (N6): same rewrite                                                     |
| [pots/design.md](pots/design.md)                                       | No cascading authority                                                                   | Updated (N6): kept and strengthened                                               |
| [unified-completion-contracts.md](unified-completion-contracts.md) C8  | Spending caps: owner aggregate, responsibility and single-run                            | Updated (N6): per-pot caps added; owner total and causal-root accounting are kept |
| [README.md](README.md) U3 row and item 3 of the U1 queue               | Unified navigation/UI deferred by the user                                               | Updated (N2): un-deferred                                                         |
| [unified-completion-contracts.md](unified-completion-contracts.md)     | Deferred: UI/navigation reset, Flutter Web migration, iOS                                | Updated (N2): UI/navigation un-deferred; Flutter Web and iOS stay deferred        |
| [unified-completion-contracts.md](unified-completion-contracts.md) C10 | Necessary controls may be throwaway in the old style; UI redesign deferred               | Superseded (N2): new controls belong in the new interface                         |
| [unified-conversations.md](unified-conversations.md)                   | Keep the native-content requirement; no WebView fallback                                 | Updated (N1): kept; mainline scope clarified                                      |
| [mobile.md](mobile.md)                                                 | Remaining work lists dialog, dynamic-content, script-lifecycle and fragment-scroll items | Updated (N1): the first four items leave the mainline; the tier list is proposed  |
| [unified-architecture-review.md](unified-architecture-review.md)       | App sign-in and server exposure deferred                                                 | Updated (N3): kept; meaning of "App independent" clarified                        |

### Confirmed 2026-11-16 follow-ups

- **(a) HTML form interaction.** Common HTML form interaction (buttons, inputs,
  checkboxes, radios, selects and submit, with the basic events, focus and
  keyboard behaviour they need) is mainline rendering scope. Structured cards may
  be proposed separately but have not been chosen to replace HTML, so existing
  capability commitments are not lowered on that basis.
- **(b) Frozen rendering items.** "Frozen" means no further specification growth.
  Safety, crash, resource-release and credential/cookie/storage isolation defects
  are still fixed, and required safety regressions stay in the default test set
  even if the fast test set is tiered.
- **(c) Agent content identity.** Content from agents does not obtain the app's
  own first-party identity. Activating a submit control inside agent content is
  not approval to use the app's execution or management rights. This is a design
  principle only.
- **(d) Multiple named pots.** Multiple named pots replace the single-assistant
  design. De-duplication is layered: each pot keeps its own observations and
  evidence; shared events, user notifications and same-purpose dispatches are
  de-duplicated per layer and summarised by a configured lead/coordinating pot. A
  global de-duplication record must not swallow another pot's responsibility or
  evidence, nor share unauthorised content. The detailed data model is still a
  proposal.
- **(e) Device credential rotation.** Rotation may extend beyond the 30-day total
  lifetime while keeping the 7-day idle expiry and manual revocation. Rotation
  must not extend management grants, add permissions or become a different
  device. Detailed rules are still a proposal.
- **(f) F1 scope this round.** An explicit user cancellation is the only trigger
  for voiding an accepted environment transition whose Node outcome is unknown.
  Automatic behaviour is reconciliation only. This delivers a safe exit, not
  automatic continuation in every situation.
- **(g) F2 first-message attempts.** After a first-message attempt is proven not
  admitted it is shown as "not executed, can retry", never as completed. A new
  attempt is always started by the user. Drafts and attachments are retained.
- **(h) Publication paused.** Pushing, merging to main and releases are paused as
  of 2026-11-16 until the owner says otherwise. Implementation continues as local
  commits.
- **(i) Status reporting.** Status uses four separate states that must not be
  merged: design complete, code complete, acceptance passed, activation allowed.

### Confirmed 2026-11-17 follow-ups

Decided on 2026-11-17. Publication stays paused (follow-up (h) above); this is a
strategy and a set of rules for local work, not a release.

- **(a) Remote images and media in untrusted content load only on user
  activation.** "Untrusted content" is chat messages, previewed Markdown/HTML files
  and tool output. A placeholder shows the alternative text and the source; the
  content is loaded only after the user activates it, directly from the user's
  device, with nothing sent before. There is **no Gateway image proxy**. `data:`
  images and the app's own attachments and file previews are unchanged. On Web the
  activation opens the address in a new tab without referrer or opener; on Android
  it displays in place without credentials or referrer. Displaying in place on Web
  is **not** implemented: it would require widening the page policy to all remote
  images. Still a proposal: whether Web should offer it.
- **(b) Controlled attachments come from trusted identifiers, not URL shape.** A
  relative or same-origin URL written in content is not treated as the app's own.
  No current feature loads an image by URL, so nothing is built for this yet; a
  future one would use server-issued identifiers from a trusted session snapshot.
  This is a design principle only.
- **(c) Security response headers.** The static web app is served with
  `frame-ancestors 'none'`, `X-Frame-Options`, `Referrer-Policy: no-referrer` and
  `X-Content-Type-Options: nosniff`, and the build writes a page
  Content-Security-Policy. Forms in messages may still submit to other sites.
- **(d) Rendered content is contained within its box and diagram styles are
  isolated** (Web). Content cannot cover or intercept controls outside its message
  or preview, and diagrams are shown as isolated images. Common styling and forms
  are kept.
- **(e) Release order (strategy only; it does not lift the pause).** A compatible
  signed APK first; then the Web bundle and the Gateway together; open Web tabs are
  prompted to reload and the old service-worker shell is replaced; a client that
  does not meet the new rules receives an explicit "update" message. No check is
  bypassed to keep an old client working. New clients are verified locally against
  new and old Gateways, and old clients against the new Gateway, before any
  publication is discussed.

Status of each item is in the four-state table in
[unified completion contracts](unified-completion-contracts.md#reliability-and-gate-fixes-2026-11-16).
Items still proposals: in-place remote images on Web, server-issued identifiers for
controlled attachments, and the compatibility matrix against a real reverse proxy.

### Still proposals (not decided)

- Pairing-flow redesign
- Rotation detail rules
- Multi-pots data model, group wake-up rules and report-chain depth accounting
- Rendering tier list
- Test-set tiering
- Any Flutter Web decision

This is a work queue, not authorization. Each implementation needs the user's
go-ahead; nothing here authorizes deployment, paid evaluation, deleting state or
rerunning the `#[ignore]`d real-host-root tests. Preserve unresolved items when
updating this queue. Completed implementation and validation diaries are available
through the historical-records locator, not maintained as active plans.

Current behavior and decisions live in [Assistant memory](../docs/architecture/assistant-memory.md),
[Security decisions](../docs/architecture/security-decisions.md) and
[Chat projects](../docs/guides/chat-projects.md). Historical TypeScript paths must
be remapped to `crates/` and findings reconfirmed before implementation. Completed
security fixes, OM model policy/diagnostics, secure deletion and project hard
deletion are not open work.

## Current priority: unified conversation architecture

[Unified conversations, projects and an independent App](unified-conversations.md)
records the 2026-10-23 planning direction: merge the user-facing Chat/Work flow,
distinguish projects, conversations, tasks and execution environments, and make
the App independently usable. pirc may discover and suggest relevant work quietly;
execution remains governed by user-granted authority. Flutter Web is evaluation
only. Domain relationships and workflows come before new interface implementation.
The 2026-10-24 clarification adds configurable conversation workspaces, shared
project mounts/rules, project departure revocation, collaboration boards and
attributed **pirc pots** coordination. The user subsequently authorized phased code
implementation, not deployment or crate publication. Two plans carry that work:

- **[pots](pots/README.md)** (own folder: README, [design](pots/design.md),
  [acceptance](pots/acceptance.md)). Delivered: progress-only tracking
  (shipped in v0.10.0), explicit controlled dispatch (`d4f1efbd`, unreleased,
  Gateway schema 1011 / Node protocol 15), and ownership-based Stop, archive and
  revocation-fence paging (`6d87f97f`, unreleased). Open: device and full-conformance
  acceptance, remaining inbox lifecycle, content observation, proactive analysis,
  digests/push and standing grants.
- **[Reusable Rust foundations](library-extraction.md)**. Delivered: pure types,
  transport/OAuth extraction, the native runtime contract, and a loop core that
  the production agent run drives through a thin adapter. Open: the adapter
  follow-ups, API stabilization and a clean full workspace/conformance gate.

Existing security/data-loss issues and acceptance gaps below remain
valid; this does not mark mobile parity complete. The user subsequently accepted
[the specification-review recommendations](unified-conversations.md#accepted-specification-review-recommendations-2026-10-24)
as the planning baseline. Accepted choices are no longer repeated as approval
questions; engineering contracts, unspecified settings and explicitly deferred
App connection/Flutter Web decisions remain open. The original planning task was
not implementation approval; the later authorization is limited to staged code
work and does not clear the remaining acceptance gates.

[Conversation execution contracts](conversation-execution-contracts.md) details all
seven accepted follow-up areas: capability composition, foreground/background task
routing, overlapping permissions, Node switching, archive/delete/leave, saved
content versus live file links, and pots coordination/takeover. Each includes
flows, exceptions and future acceptance cases; items 4–7 add 32 such cases while
preserving current memory-deletion and checkpoint ownership rules. The
[main plan](unified-conversations.md#accepted-follow-up-behavior-and-detailed-contracts-2026-10-24)
indexes the specifications. They are planning contracts, not completed implementation
or evidence of passing runtime tests.

[Integrated architecture review](unified-architecture-review.md) records the
cross-plan contradictions corrected before publication, remaining product choices,
and engineering proof gates. The user then adopted the [recommended defaults](unified-architecture-review.md#adopted-defaults-and-deliberately-deferred-decisions):
read-only additional mounts, first-send allocation unless explicitly created,
durable notes without age expiry, scoped/bounded pots, and the three crate names
with optional default-off OAuth. Exact amounts/times and board-retention/editor
presets remain configuration work; App sign-in and Flutter Web stay deferred.
The architecture documents can be published as a planning baseline; this is not
approval to implement every unchecked stage.

<a id="current-implementation-status-2026-10-28"></a>

## Historical implementation records (2026-10-28 to 2026-11-07)

The old anchor is retained. These records describe their own revisions only;
“latest”, “next” and authorization statements are historical. Consult
[C0](unified-completion-contracts.md#c0-authority-current-snapshot-and-scope)
for current implemented/accepted/active status; this section grants no authority.

The earlier publication `9eccd9e1` refreshed progress on **2026-11-04** for the
user's explicit pull/rebase and push request. `git pull --rebase origin main` found the remote baseline `798aa817`
already integrated; there were no incoming changes or conflicts. This publication
includes eight previously local source commits, ending at `b1cc9d28`:

| Commit     | Delivered scope                                                                                                 |
| ---------- | --------------------------------------------------------------------------------------------------------------- |
| `d500f2d3` | Browser resource guards, recorder retirement and retained close evidence                                        |
| `ab94a678` | Page-owned engine/background/network admission, including delayed DNS                                           |
| `fddd9ca3` | Independent runner/process/host-command/terminal/browser drain                                                  |
| `24a2c7a0` | Durable owner-scoped Gateway review previews, schema 1026                                                       |
| `133c32c3` | Workspace panel/Git authority checks across waits and stale-result suppression                                  |
| `97bd0303` | Non-allocating Node resource/alias/activity preflight                                                           |
| `afc360a6` | Gateway consumption of resource observations with connection/device/policy checks and separate epoch namespaces |
| `b1cc9d28` | Evidence-bound Node admission receipts and Node schema 2019 semantic upgrade                                    |

Latest completed local validation at `b1cc9d28`: **585 Node tests passed** (four
existing opt-in tests ignored), **400 Gateway tests passed**, **14 required
real-process cases passed**, and strict Node/Gateway/conformance all-target
Clippy passed. These include old-receipt migration, concurrent intents, large
memory histories, paired-native HTTP, repeated requests, restart/offline behavior,
resource changes, revocation and native checkpoint isolation. Individual slices
and their limits are linked from the [main plan](unified-conversations.md#integration-and-publication-checkpoint-2026-11-04).

The published revision `9eccd9e1` now has successful completed
[Check](https://github.com/mozufu/pirc/actions/runs/41678942853) and
[Android](https://github.com/mozufu/pirc/actions/runs/41678943035) workflows.
Those results do not prove CI for the newer source commit below. The known
panel-memory token snapshot discrepancy remains recorded in its
[checkpoint](unified-conversations.md#u4-implementation-checkpoint-workspace-panel-authority-2026-11-04).

The user resumed implementation after that publication and now explicitly requests
publishing current progress. `git pull --rebase origin main` completed against
`9eccd9e1` without incoming changes or conflicts. This publication adds
`0c8fb22c`: [Node-fence receipt reconciliation](unified-conversations.md#u4-implementation-checkpoint-gateway-node-fence-receipt-reconciliation-2026-11-04),
which records verified existing Node acceptance and blocks new session commands
at Gateway while preserving Stop, receipts and peer work. Its completed local
validation is **406 Gateway tests**, **14 required real-process cases** and strict
Gateway/Node/conformance all-target Clippy. The owned **2.1 GiB** temporary tree
has been removed. No unchanged source tests were repeated for this conflict-free
rebase; publication checks cover formatting, diff integrity and document targets.

See the [receipt publication checkpoint](unified-conversations.md#node-fence-receipt-publication-checkpoint-2026-11-04)
for scope and remaining gates. Initial accepted-intent coordination and full
revocation/installation remain open. Public switching and first-Send activation
stay gated. Future work remains local unless explicitly authorized to push;
deployment, package-version changes and a Release are outside this request.

Latest local continuation after publication `b6f2f41f`:
[Gateway accepted-intent journal](unified-conversations.md#u4-implementation-checkpoint-gateway-accepted-intent-journal-2026-11-04)
adds the initial durable barrier, one-attempt Node admission service, immutable
unknown-outcome recovery and `activeTransition` discovery for Web/paired Android.
New public confirmations remain disabled until complete revocation, installation
and coordinator recovery are proved. **416 Gateway tests**, **14 required
real-process cases** and strict all-target Clippy pass; the owned **2.1 GiB** tree
is cleaned. Positive acceptance uses Node stand-ins; device/full-coordinator
acceptance remains open. This continuation is local only; the goal stays active.

Latest local continuation of `3e80ad6f`:
[durable transition Stop commands](unified-conversations.md#u4-implementation-checkpoint-durable-transition-stop-commands-2026-11-04)
reuse existing command identities for a known source's supervised-resource Stop.
Node rechecks operation/plan/source/control; Web/paired Android share deduplicated
commands and read-only recovery after reply loss/restart. Full revocation, target
installation, public confirmation and client controls remain open. **588 Node
library tests** passed (four existing opt-in ignores), **421 Gateway tests**,
**14 required real-process cases** and strict all-target Clippy passed. The
**2.7 GiB** owned output tree is cleaned. This continuation stays local.

Latest local continuation of `cf2d33fe`:
[native proxy retirement](unified-conversations.md#u4-implementation-checkpoint-native-proxy-retirement-2026-11-04)
closes source I/O across durable fence acceptance, retires live HTTP/SOCKS tunnels,
waits for sockets/admitted lookups and restores barriers on startup. Peers keep
their own network scope; missing evidence stays blocked. **594 Node library
tests** passed (four existing opt-in ignores), **421 Gateway tests**, **14 required
process cases** and strict all-target Clippy passed. Real local proxy/router tests
use a test adapter; native OS/full-coordinator/device acceptance remains open.
The **2.7 GiB** owned output tree is cleaned. No public switching is enabled.

Latest local continuation of `2361e1bc`:
[terminal I/O settlement](unified-conversations.md#u4-implementation-checkpoint-terminal-io-settlement-2026-11-04)
joins both PTY owners before saving/notifying settlement and rejects input during
natural-exit cleanup while retaining output/history. **598 Node library tests**
passed (four existing opt-in ignores), **421 Gateway tests**, **16 required
process cases** and strict all-target Clippy passed. The **2.3 GiB** owned output
is cleaned. Full descendant containment and switching stay unconfirmed.

Latest local continuation of `e1a440ec`:
[host-management approval origin](unified-conversations.md#u4-implementation-checkpoint-host-management-approval-origin-2026-11-04)
binds a Node-issued question to exact command/environment intent and consumes it
atomically with the host-run reservation before spawn (Node schema **2023**).
Old runs do not acquire new grants. **608 Node tests** passed (four existing
opt-in ignores), **421 Gateway tests**, **18 required process cases** and strict
all-target Clippy passed; the **2.4 GiB** owned outputs are cleaned. Isolated
terminals, complete revocation/install and mode controls remain open.

Latest local continuation of `7e05a6df`:
[guarded isolated work terminals](unified-conversations.md#u4-implementation-checkpoint-guarded-isolated-work-terminals-2026-11-04)
adds the explicit native Linux path, private PTY-independent permit and shared
journal identity (Node **2024**). Unsupported backends refuse host fallback.
**613 Node tests** passed (five child/opt-in ignores), **421 Gateway tests**,
**19 required process cases** and strict all-target Clippy passed; the **2.4 GiB**
owned outputs are cleaned. Actual Linux namespace CI, lost-I/O-owner recovery,
client mode choice/host-terminal grants and default rollout remain open.

Latest local correction to `3112df72`:
[Agent and terminal journal slots](unified-conversations.md#u4-implementation-checkpoint-agent-and-terminal-journal-slots-2026-11-04)
replace the shared epoch uniqueness with an Agent-only constraint and immutable
resource kinds (Node **2025**). An Agent plus multiple terminals can coexist
without sharing a kernel scope or weakening Agent/guard deduplication.
**618 Node tests**, **421 Gateway tests**, **19 required process cases** and
strict all-target Clippy passed; **2.4 GiB** owned outputs are cleaned. Owner
recovery and client rollout remain open.

Latest local recovery delivery:
[terminal I/O owner recovery](unified-conversations.md#u4-implementation-checkpoint-terminal-io-owner-recovery-2026-11-04)
records the old Node process identity before isolated-terminal spawn (Node **2026**).
Restart settlement needs both exact namespace termination and read-only old-owner
exit proof under a source fence. Unknown evidence remains blocked; no PID-based
kill, command replay or legacy proof backfill. Keyset history scans prevent early
unknown rows from starving later recoverable work. Native Linux acceptance,
client mode/default rollout and complete revocation/install remain open.
**629 Node tests**, **421 Gateway tests**, **19 required process cases** and
strict all-target Clippy passed. The owned **2.9 GiB** outputs are cleaned; this
delivery stays local.

[Folder grants and deny (C6a)](folder-grants.md): C6a-1 Node grants, effective
access, immediate fence and host refusal under deny; C6a-2 Gateway relay and the
C1 O5, C2 R5 and C3 X3 grant cases. Client interfaces (C6a-3) next. Local only.

Latest local transition delivery:
[T5 failure-matrix acceptance](transition-installation.md#local-implementation-checkpoint-t5-failure-matrix-acceptance-2026-11-07): **675 Node**,
**428 Gateway** tests and **42 process cases** passed. T1–T5 are done; next are
the five Gateway status/discovery gaps. Local only.

Previous local transition delivery:
[T4 environment switching clients](transition-installation.md#integration-checkpoint-t4-environment-switching-clients-2026-11-07): Web **699
tests**, Android **147 focused tests**, clean svelte-check and `flutter analyze`.
Next: five small Gateway status/discovery gaps found by the clients. Local only.

Previous local transition delivery:
[T3b gated confirmation, recovery and composed acceptance](transition-installation.md#local-implementation-checkpoint-t3b-gated-confirmation-recovery-and-composed-acceptance-2026-11-07):
switching works end to end behind `PIRC_ENVIRONMENT_SWITCHING` (default off).
**674 Node**, **428 Gateway** tests and **38 process cases** passed. Next: T4.
Local only.

Previous local transition delivery:
[T3a Gateway coordinator stages](transition-installation.md#local-implementation-checkpoint-t3a-gateway-coordinator-stages-2026-11-07) (Gateway
**1030**): advance, acknowledge and cancel routes, terminal stages and the
binding commit. **426 Gateway tests** and **37 process cases** passed. Next: T3b.
Local only.

Previous local transition delivery:
[T2 acknowledge, install and release](transition-installation.md#local-implementation-checkpoint-t2-acknowledge-install-and-release-2026-11-07) (Node
**2032**): Node-side installation, explicit release, digest-bound acknowledgement
and the environment notice. **673 Node**, **423 agent**, **421 Gateway** tests and
**37 process cases** passed. Next: T3a/T3b. Local only.

Previous local transition delivery:
[T1 binding generations and revocation evaluation](transition-installation.md#local-implementation-checkpoint-t1-binding-generations-and-revocation-evaluation-2026-11-07)
(Node **2031**): read-only evaluation of what retained evidence proves after a
drain; flags stay false. **666 Node tests**, **421 Gateway tests**, **32 required
process cases** and strict Clippy passed. Next: T2. Local only.

Previous local terminal delivery:
[compatibility host terminals off by default](execution-isolation.md#local-implementation-checkpoint-compatibility-host-terminals-off-by-default-2026-11-06): the
omitted-path request returns `426` unless `PIRC_LEGACY_HOST_TERMINALS` is set.
658 Node, 421 Gateway and 32 required process cases passed. Next: U4 step 3,
chosen by the user, with its [adopted design](transition-installation.md) and
slices T1–T5.

Previous local terminal delivery:
[acknowledgement and specific errors](execution-isolation.md#local-implementation-checkpoint-terminal-request-acknowledgement-and-specific-errors-2026-11-06) (Node **2030**)
hides acknowledged `outcome_unknown` requests from discovery without closing them
and adds `terminal_request_not_found`/`terminal_capacity`. **658 Node tests**,
**421 Gateway tests**, **31 required process cases** and strict Clippy passed.
Both clients [adopted v3](execution-isolation.md#integration-checkpoint-terminal-contract-v3-clients-2026-11-06): Web **637 tests**, Android
**75 focused tests**, clean svelte-check and `flutter analyze`. Local only.

Previous local client delivery:
[Web and Android terminal contract clients](execution-isolation.md#integration-checkpoint-web-and-android-terminal-contract-clients-2026-11-06)
adopt the frozen terminal contract as interface layers with throwaway UI; no
format changes. Web **622 tests** with clean svelte-check, Android **62 focused
tests** with clean `flutter analyze`. Four follow-ups are recorded; the growth of
unresolved `outcome_unknown` requests needs a user decision. Local only.

Previous local terminal delivery:
[terminal request discovery and result parity](unified-conversations.md#u4-implementation-checkpoint-terminal-request-discovery-and-result-parity-2026-11-06)
closes the client-contract Node gaps (Node **2029**): unresolved-request paging,
matching host/work results with retained start-failure reasons, required request
IDs for isolated work and a bounded `202` first reply. The
[client terminal contract](execution-isolation.md#client-terminal-execution-path-contract-v1-frozen-for-webandroid) is frozen; the interface-only
Web/Android slices followed. **655 Node tests**, **421 Gateway tests**, **30 required process cases**
and strict all-target Clippy passed. Local only.

Previous local terminal delivery:
[durable isolated work-terminal requests](unified-conversations.md#u4-implementation-checkpoint-durable-isolated-work-terminal-requests-2026-11-06)
retains an explicit isolated terminal's request identity before preparation, runs
one worker per request and recovers results read-only (Node **2028**). Unavailable
isolation never falls back to the host. Its client-contract Node gaps followed in Node 2029.
**651 Node tests**, **421 Gateway tests**, **29 required process cases**,
**61 focused terminal cases** and strict all-target Clippy passed. Local only.

Previous local host-terminal delivery:
[human review and once-only launch](unified-conversations.md#u4-implementation-checkpoint-host-terminal-review-and-once-only-launch-2026-11-04)
adds a Node-generated, exact-environment review, explicit positive confirmation,
atomic grant/launch reservation and request-bound result lookup (Node **2027**).
Accepted retries/restarts never relaunch. Direct-shell closure keeps uncontained
host work unconfirmed and source settlement blocked. Necessary Web/Android mode
controls and warnings, client recovery/default rollout and full revocation/install
remain open.
**639 Node tests**, **421 Gateway tests**, **20 required process cases**, final
**49 focused terminal cases** and strict all-target Clippy passed; the
owned **2.9 GiB** outputs are cleaned. This delivery remains local.

The user adopted [isolated work + explicit host management](execution-isolation.md).
This is no longer an approval question. New adapters/grant origins and necessary
Web/Android mode controls remain implementation work; no implicit host fallback
or `full-access` escalation is authorized by the design.

> **Updated 2026-11-16 (N2):** The U3 row below ("Deferred by the user") is un-deferred; the scope is the interface, state management and data layer plus necessary rendering performance and integration fixes, and `pirc-mobile-handoff` is a reference rather than a frozen specification. See [2026-11-16 direction update](#direction-update-2026-11-16).

| Area                                           | Current state                                                                                                                                                                                                | Remaining delivery                                                                                                    |
| ---------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------- |
| U1 — reliable first Send                       | Gateway/Node durable intents, original files, admission/Stop/delete fences, explicit rejected-message retries and Gateway nonce retirement; Web/private Android drafts and recovery controls are implemented | Live-client failure/local-write matrix, Android process/device and rollout/rollback gates                             |
| U2 — conversation/project/environment bindings | Durable bindings/membership/policy histories, frozen memory origins and cleanup receipts; captured command intent with Gateway/Node rechecks; frozen saved-upload origins                                    | Live-resource provenance, effect-boundary fencing and acknowledged transitions                                        |
| U3 — unified navigation/UI                     | Deferred by the user                                                                                                                                                                                         | Revisit after core contracts; current clients receive necessary functional controls only                              |
| U4 — mount/workspace transitions               | Gateway accepted-intent journal (publicly gated), cross-device discovery and durable Stop; Node evidence-bound fences, tracked drain, native proxy I/O retirement and exact-intent host-management approval  | Complete coordinator recovery/cancellation, OS revocation, replacement acknowledgement, project resources and clients |
| U5 — canonical tasks and collaboration         | Existing pots/task/team/goal/todo foundations remain                                                                                                                                                         | Map common task/attempt identities, shared notes and structured waits; preserve other writers and memory provenance   |
| U6 — bounded proactive pots                    | Progress-only observation and explicit dispatch exist                                                                                                                                                        | Scoped content observation, finite budgets, quiet suggestions and synchronized notification/decision lifecycle        |

**The new U1 flow is still gated by `canSubmit: false`.** Pushing its code does
not enable it. Current formats are Gateway schema **1034**, Node schema **2040** (the
`SCHEMA_VERSION` constants in `crates/pirc-gateway/src/db.rs` and
`crates/pirc-node/src/store/mod.rs` are the source of truth),
protocol **15**, client recovery contract **2**, and Web IndexedDB/native private
envelope **3**. Existing ordinary session APIs remain available. Unaccepted
Gateway attachment staging expires after **seven days**; accepted attachments and
private drafts are not subject to that deadline. See [upgrade and rollback
notes](../docs/deploy/upgrades.md).

U2 has started independently of U1 activation: see the
[binding migration inventory](conversation-binding-migration.md) and
[implementation checkpoint](unified-conversations.md#u2-implementation-checkpoint-saved-attachment-origins-2026-10-28).
Schema 1022 adds canonical project membership and append-only configured mode and
workspace-capability policy histories. Web/native API adapters can read the
owner-scoped environment state directly while Node is offline. The response marks
Node enforcement as not tracked. Schema 1023 adds frozen global-memory version/proposal origins, preserved through
approval/restore and erased with the existing deletion flows. Schema 1024 adds
source-aware project deletion, explicit legacy review and durable cleanup receipts.
Schema 1025 adds frozen Web/Android command intent and transactional Gateway
admission checks; duplicate receipts do not redispatch and changed environments
require version-aware clients. Node schema 2010 adds durable command origins,
connection-scoped capability probes and Gateway authority rechecks after Node
queue/startup waits. Node schema 2011 freezes new saved-upload origins and existing
access scopes, exposes owner-scoped metadata through Web/paired-device HTTP, and
verifies stored bytes before Agent use. Existing uploads retain their legacy rules;
workspace copies retain later user edits. Live-resource grants, full effect fencing,
installed policy acknowledgement and transitions remain pending. Node schema 2012 adds the internal transition admission
fence and retriable tracked-supervisor drain. Draining does not acknowledge OS
revocation or install a new environment; no public switch is enabled. See the
[transition checkpoint](unified-conversations.md#u4-implementation-checkpoint-node-transition-admission-fence-2026-10-28).
Runner-scoped inference capabilities now enforce the admission boundary and cancel
only the affected session; late provider replies cannot re-enter its relay. See the
[inference checkpoint](unified-conversations.md#u4-implementation-checkpoint-runner-scoped-inference-retirement-2026-10-28).
Node schema 2013 adds durable launch reservations and bounded restart reconciliation
of captured Linux identities. Old or missing process evidence remains unresolved;
see the [launch journal checkpoint](unified-conversations.md#u4-implementation-checkpoint-durable-sandbox-launch-journal-2026-10-28).
Node schema 2014 gates native Linux runner execution on committed process identity
and a one-time permission record; missing evidence refuses startup. See the
[guarded launch checkpoint](unified-conversations.md#u4-implementation-checkpoint-guarded-native-linux-launch-2026-10-28).
Panel terminals now recheck their original binding/controller at each actual write and resize; see the [terminal checkpoint](unified-conversations.md#u4-implementation-checkpoint-fenced-terminal-input-2026-10-28).
Node schema 2015 journals approved host commands and joins their Node-owned supervision on Stop/deletion/transition drain. Unknown prior observations remain unresolved; see the [host-command checkpoint](unified-conversations.md#u4-implementation-checkpoint-supervised-host-commands-2026-10-28).
Node schema 2016 retains approved host-command write ranges across Agent settlement and restart. Unknown legacy ranges block writes instead of inventing availability; see the [resource-retention checkpoint](unified-conversations.md#u4-implementation-checkpoint-host-write-resource-retention-2026-10-28).
Memory cold cutover now holds Node admission through its checked durable append and excludes unresolved local host ranges; host approval avoids the memory lifecycle-lock inversion. See the [cutover checkpoint](unified-conversations.md#u4-implementation-checkpoint-memory-cutover-host-exclusion-2026-10-28).
Node schema 2017 retains panel-terminal launch and stop observations across close/cancellation/restart. Unknown shells block deletion and drain instead of disappearing with their UI; see the [terminal-supervision checkpoint](unified-conversations.md#u4-implementation-checkpoint-durable-terminal-supervision-2026-10-28).
Node schema 2018 retains browser group origins and close outcomes, including canceled requests, late popups and uncertain prior groups. Unconfirmed closure blocks deletion/drain; see the [browser-supervision checkpoint](unified-conversations.md#u4-implementation-checkpoint-durable-browser-supervision-2026-10-28).
Foreground browser commands now retain their caller and recheck at the first pipe write; later queued commands cannot reuse revoked authority. Background browser resources and complete retirement remain open.
The local [independent-drain checkpoint](unified-conversations.md#u4-implementation-checkpoint-independent-resource-drain-2026-10-28) prevents runner locks and failed observations from skipping other resource stops. Unknown historical processes remain blocked; no public transition is enabled.
Gateway schema 1026 adds [durable transition review previews](unified-conversations.md#u4-implementation-checkpoint-durable-gateway-transition-previews-2026-10-28), with owner/version checks, reconnect-aware capability observations and paired-device HTTP access. Confirmation remains disabled; no switch or Node fence follows a preview.
Resource grants, project moves and full effect fences remain open. U1 still needs device/deployment acceptance
before activation. Detailed validation and the previously reproduced macOS snapshot
limitation are recorded in the checkpoints; no full Linux/device acceptance is claimed.

Latest completed U1 slices and their recorded evidence:

- [Node capability/connection fencing](unified-conversations.md#u1-implementation-checkpoint-node-capabilities-and-connection-fencing-2026-10-27):
  materialize/dispatch recheck capabilities, and all first-send effects stay bound
  to that exact Node connection. Mid-probe revocation, workspace removal/control
  loss and known connection replacement prevent later effects/command reservation.
  Explicit blank release still retains old files without uploading them. 336
  Gateway tests, five live-client tests, three native checkpoint cases, contract/
  protocol checks, strict Clippy and focused localization checks pass. Historical
  mixed deployments and Android OS/device remain unverified.

- [Node storage reply loss](unified-conversations.md#u1-implementation-checkpoint-node-storage-reply-loss-2026-10-27):
  actual Node allocation or upload commits, then its reply is lost before Gateway
  restart. Fresh native/Web recovery is GET-only; only a separate explicit Send
  resumes the same operation, preserving one Node session/upload and one model
  execution across another restart. Five live-client tests pass, along with the
  bounded old-client contract rejection test and targeted compile/lint checks.
  No production behavior or activation changes; Android OS/device remains open.

- [Offline allocation and native blob cleanup](unified-conversations.md#u1-implementation-checkpoint-offline-allocation-fencing-and-private-blob-cleanup-2026-10-27):
  real native materialize is held while Web stops/deletes an offline Node;
  Gateway restart retains the decision, and fresh clients query without replay.
  Stop allows only an explicit blank-conversation release. Fixed native private
  blobs lingering after a confirmed deletion; cleanup follows durable metadata
  and repairs on reopen without affecting retained copies. Four live process
  tests and 65 native JVM cases pass; Android OS/device remains unverified.

- [Mixed Web/native control races](unified-conversations.md#u1-implementation-checkpoint-delayed-web-dispatch-versus-native-takeover-2026-10-27):
  a held real Web dispatch loses control to a paired native client. Explicit
  takeover followed by Stop, confirmed deletion or Send cannot revive old work
  or duplicate admission. JVM/browser and both-host restart preserve identities;
  both clients reconcile with GETs, and deletion cleanup completes. Three live
  process tests pass (the new three-case race plus the prior two native and three
  Web fault cases); no product behavior or rollout changed.

- [Paired native process acceptance](unified-conversations.md#u1-implementation-checkpoint-paired-native-process-recovery-and-revocation-2026-10-27):
  actual Kotlin engine/file journal and two real device tokens pass discarded
  dispatch reply and read-only journal faults, complete JVM/host restart, GET-only
  reconciliation and single-device revocation. Original input/files and one
  session/command/model request per operation survive; the other device keeps
  access. The Web three-case process test also passes after extracting shared
  assertions. This is explicit opt-in JVM/backend proof, not Android OS/device or
  default CI coverage.

- [Live Web reconciliation](unified-conversations.md#u1-implementation-checkpoint-live-web-reconciliation-and-durable-uncertainty-2026-10-27):
  actual Web/IndexedDB plus Gateway/Node/Agent passes transport replay, truncated
  reply and aborted local receipt across all-host/browser restart and parallel
  GET-only checks. Fixed the pre-effect uncertainty marker in both clients.
  79 Web/63 native JVM cases, typecheck and strict Clippy pass. The repeatable
  browser test is explicitly opt-in, not implied by a normal CI pass.

- [Editor attachment snapshots](unified-conversations.md#u1-implementation-checkpoint-editor-attachments-survive-source-cleanup-2026-10-27):
  reopening an editable Android draft atomically reads its verified files before
  another window can clean the source; unsent recovery preserves those bytes.
  Failed opening keeps the current editor, and delayed opening cannot replace new
  navigation. 51 Web, 62 native JVM and 26 focused Flutter cases pass; two dedicated
  browser pages preserve separate copies/Blob bytes after cleanup and restart.

- [Gateway nonce retirement](unified-conversations.md#u1-implementation-checkpoint-gateway-retirement-of-an-unreserved-retry-2026-10-27):
  schema 1020 atomically fences an unreserved client nonce against delayed POSTs,
  preserving existing commands and original files. 329 Gateway tests and five
  backend process cases and strict Clippy pass. Client adoption is recorded below;
  activation remains pending.
- [Web/native retry recovery](unified-conversations.md#u1-implementation-checkpoint-web-and-native-interrupted-retry-recovery-2026-10-27):
  explicit recovery fences an unreceived nonce; read-only Check resolves a matching
  durable retirement, preserving original files and newer work. 76 Web, 57 native
  JVM and 23 focused Flutter tests pass; a dedicated two-page browser/restart
  proof keeps original Blob bytes and one Retry POST.

- [Gateway retries](unified-conversations.md#u1-implementation-checkpoint-gateway-durable-rejected-admission-retries-2026-10-27):
  durable retry identity, per-attempt ordering and global Stop reconciliation;
  320 Gateway tests, strict Clippy and five backend process cases passed.
- [Node retries](unified-conversations.md#u1-implementation-checkpoint-node-rejected-admission-retry-foundation-2026-10-27):
  exact rejected-predecessor checks and retained original input; 447 Node tests
  (three existing helper ignores), strict Clippy and three Node process cases
  passed. The real Agent journal proof retains one user message/model call.
- [Web/native retries](unified-conversations.md#u1-implementation-checkpoint-web-and-native-android-rejected-admission-retries-2026-10-27):
  nonce-before-POST, query-only uncertain recovery and old-writer fences; 68 Web,
  50 native JVM and 22 focused Flutter tests passed with clean targeted analysis.
  A dedicated two-page/browser-restart proof preserves one nonce and original
  Blob bytes without another POST. Native JVM/synthetic browser proofs are
  distinct from actual Android OS/device and live client-to-backend acceptance.
- [Earlier draft, conflict and pending-Stop checkpoints](unified-conversations.md#u1-implementation-checkpoint-web-durable-drafts-and-recovery-2026-10-27)
  retain detailed migration, concurrency, cleanup and permission evidence. Their
  “next slice” statements describe that point in history, not today's queue.

Next, close U1's remaining gates in this order:

> **Updated 2026-11-16 (N2):** Item 3 below ("U3 remains deferred") is un-deferred; the scope is the interface, state management and data layer plus necessary rendering performance and integration fixes. See [2026-11-16 direction update](#direction-update-2026-11-16).

1. Finish historical-binary/rolling-upgrade and broader permission-change gates.
   Node capability/reconnection and mid-probe authority faults now have unit proof;
   they do not replace mixed deployment/device acceptance. Node storage reply-loss
   recovery, initial native revocation, mapped Web-dispatch/native
   takeover and reverse-direction offline pre-allocation Stop/deletion now pass;
   those do not imply every mapped reverse-direction race is covered.
2. Verify Android MethodChannel, OS private storage/Keystore, process death and
   attachment memory pressure; request a physical device when that step is ready.
3. Complete activation/rollback and the affected full CI/conformance gates before
   changing `canSubmit`. Then proceed with U2, U4, U5 and U6; U3 remains deferred.

The published baseline `303fa8f8` passed remote [Check](https://github.com/mozufu/pirc/actions/runs/40484413613)
and [Android](https://github.com/mozufu/pirc/actions/runs/40484413359), including
Linux native sandbox/checkpoint and Nix jobs. Repairs cover the Android test
controller signature, relative retry-fixture executable path, runner APT mirror
lists, random-ID normalization and independent checkpoint fixture lifetimes.
This is evidence for that exact published commit, not the subsequent local
client additions or a physical-device pass. Local Nix validation remains waived.

Run only focused simple Flutter checks when changing Flutter. Clean run-owned
outputs after verification while preserving shared caches, SDKs, existing APKs,
user state and other agents' work. App sign-in/topology, Flutter Web and iOS remain
deferred. The [main plan](unified-conversations.md#current-progress-and-next-delivery-2026-10-28)
records the authoritative current status and full acceptance contract.

## Existing work and acceptance backlog

1. **Android approval acceptance (assistant 3a).** Verify multi-line USER proposal
   `confirm` bodies and their labels on Android; give delegation confirmations the
   same check. See [mobile acceptance](mobile.md).
2. **Optional network provenance follow-up (assistant 5).** Classify
   `browser_click` / `browser_type` on non-localhost origins and complete
   observational-memory provenance tagging of page results. Bash network taint
   and PTC agent-data tagging are already implemented.
3. **Android decisions and follow-up.** Use the [mobile plan](mobile.md) for native
   content compatibility and acceptance. Decide token rotation before the 30-day
   limit versus monthly re-pairing (including A7's near-expiry warning),
   sideload-only versus F-Droid/Play distribution and production signing, and
   whether the native Context inspector is later or never.
4. **Data-driven workspace modes.** [Modes](modes.md) phase 3, re-scoped
   2026-10-19: fixed Chat/Work tabs (tab from the `assistant` capability, Work
   grouped by node), panels by capability, modes chosen only when creating a
   workspace. Removes `ui.group` as a breaking change (protocol 13; existing
   mode files must drop `group:`). Adds a scratch-mode guide example and a
   delegation-into-per-session-workspace scenario. Phase 2 (configuration,
   protocol 12, mode-id stores and agent enforcement) is implemented; full Linux
   conformance passed 217 tests with reviewed snapshots on 2026-10-19. Phase 3
   was implemented 2026-10-19; remaining: the Settings Modes page, retiring
   `kind`, an Android scratch parity capture and guide screenshots. Treat those
   as existing behavior/backlog; assess further fixed-tab UI expansion against
   the adopted unified-conversation contracts before implementation.
5. **Workspace-memory search quality.** [Memory search](memory-search.md):
   an evaluation set, then FTS5 + BM25 with CJK bigrams replacing `LIKE`, then
   optional hybrid semantic search through a gateway-side embeddings endpoint
   (brute-force cosine in Rust, no SQLite extension). Stays on SQLite; Postgres
   and sqlite-vec are rejected there. Each phase needs the user's go-ahead;
   phase 2 also needs the embeddings source decided.
6. **GPU access in the agent sandbox.** [Sandbox GPU](sandbox-gpu.md): an opt-in
   node setting adds two measured Seatbelt rules for Metal on macOS and exact
   NVIDIA/render-node binds on Linux (unverified on hardware), plus a NixOS module
   option replacing the node's `PrivateDevices`. Security-boundary change: each
   phase needs the user's go-ahead and a recorded decision.
7. **Delegation auto mode precision.** [Delegation autonomy](delegation-autonomy.md)
   phases 0–2 (dispatch policy, verified quotes, relayed approvals) were
   implemented 2026-10-19 with the user's decisions recorded in Security
   decisions. Remaining: phase 3 (session allows, soft/hard danger), only after
   reassessing with `scripts/approval-stats.ts`; plus real-device checks of
   relayed approvals and Stop.
8. **Calendar for schedules and personal events.** [Calendar](calendar.md):
   approved month/week/day/list views for Web and native Flutter Android,
   personal events, recurrence/exceptions, reminders and separately authorized
   agent proposals. Implementation is authorized locally; see the plan for
   verification and remaining device acceptance. Remote publication requires a
   later explicit request.
9. **Agent checkpoints and safe recovery.** [Checkpoints](checkpoints.md):
   phases 1–5 implemented and verified locally, including Node capture/journaling,
   independent recovery workspaces, owner-scoped Gateway operations and Web/native
   Android review/continuation. The published memory update is integrated;
   recovery keeps its own blank conversation and cannot write to source memory.
   Original directories and later user changes remain untouched. Coverage is
   observational; Linux runtime, real-device acceptance and reviewed disposal
   remain follow-ups. Publication still requires an explicit request.

## Project-only memory (B): collaboration design reopened, migration still shelved

On 2026-10-24 the user proposed project-scoped boards/shared notes and withdrawal
of project-specific content on departure. This reopens the collaboration/context
boundary for [architecture discussion](unified-conversations.md), not automatic
implementation of the old B design. Existing global USER/MEMORY remains as-is;
full re-scoping, the old restricted profile and migration remain undecided.
Hard deletion (D) is implemented, not blocked on this discussion. Unmounting alone
does not erase old conversation content, copies or previously learned notes.

If reopened, retain the design constraints:

- Opt-in, off by default and for existing projects. Add `scope_id` (default
  `global`) to entries/log/proposals and a composite tombstone key. Scope every
  store entry point by trusted `{owner, scope}` from the session, never agent
  arguments; include search, recall and mirrored records.
- Version snapshots by scope generation and bind proposals to scope and
  generation. Not retroactive: old sessions keep their frozen snapshots.
- Decide fresh sessions for every scope-generation change (recommended) versus
  weaker continuation, explicit cross-scope copying and its review, and dormant
  scope versus deletion/export when disabling.
- This isolates projects from each other, not from gateway/node operators,
  providers or backups.

The full deferred design is `git show 7677d24:plans/project-isolation.md`, section
B (TypeScript paths need remapping). Later decisions and the pre-cleanup plans
are at `af7074fc51742e79c8f0c76a9aaf64f80b414f7e`; see
[Historical records](../docs/development/historical-records.md).

## Manual validation

Attach these to the release that needs them; they are not new feature tasks.
Synthetic/emulator coverage does not close physical-device or real-account gaps.

- **Web approvals:** browser acceptance of the approval-mode picker and warning,
  and switching modes through a real gateway and node.
- **Project deletion:** dialog in a real browser and recovery after a real node
  disconnect. Android controlled-failure tests do not establish real network
  interruption recovery.
- **Browser:** real Android takeover (tap mapping, IME, drag scrolling) and WebM
  playback.
- **Schedules:** installed-PWA push on a real iPhone (Add to Home Screen). Deploy
  gateway and nodes together for the changed deliver body.
- **Sandbox (NixOS/Linux):** a full agent session, browser included, on a
  non-container x86_64 host at native speed; boot-time tmpfiles behavior on a
  real host. Earlier module/LXC/QEMU validation is complete; srt `apply-seccomp`
  is obsolete because srt no longer ships.
- **Mobile:** iOS/Android soft keyboard and safe areas, CJK IME in the Android
  composer, terminal HTTPS asset origin and a release build on a real phone;
  detailed account, device, provider and push gaps are in [mobile](mobile.md).
- **PTC:** Anthropic direct calls with `null`/extra arguments; declining approvals
  and rendering on the new Android client; a real model reading the newer
  agent-data fences. macOS OpenAI Responses/Chat Completions runtime checks were
  completed, but reviewed behavior changes were not re-measured.
- **Rust post-cutover:** investigate if the one-off, unreproduced
  `node_link_side_runs` CI timeout recurs. TLS, a real identity provider, phone
  pairing, push and terminals are not covered by the macOS end-to-end checks.
  The macOS v0.4.1/v0.5.0 archives are unsigned and not notarized.

## Accepted limitations — not new work

- **Security:** single-user gateway model, session-only domain approvals, S10
  (host atomic replacement detaches a protected Linux mount) and S18 (browser
  WebSocket/non-HTTP egress and DNS rebinding) stay accepted. Linux socket hiding
  covers sockets bound at plan time, not sockets bound later or in another
  network namespace. Other accepted security choices are in
  [Security decisions](../docs/architecture/security-decisions.md); do not
  reopen them without a new decision. Lasting domain allows belong in
  `sandbox.network.allowedDomains`; revisit session-only prompts only if repeated
  prompts become common.
- **Repository identity:** normalized repository keys preserve path case, so
  `github.com/Owner/Repo` and `github.com/owner/repo` differ. `.git` symlinks and
  absolute `gitdir:` / `commondir` are followed; only the normalized key leaves
  the node.
- **Project deletion:** automatic forget/rollback entries are handled as they
  stand at confirmation; only entries needing a user decision are revision
  compared. Rollback may leave memory over budget. Chat deletions before schema
  1004 did not record their project. Other exclusions and scoped tombstones are
  documented in [Deleting a project](../docs/guides/chat-projects.md#deleting-a-project).
- **Browser:** teammates/subagents have no browser; the screenshot action log is
  memory-only and lost on node restart.
- **PTC (accepted P3):** bash writes through a symlink created in the same command
  can skip the write lease. Plain bash output remains unlabelled (network fetcher
  or URL commands and `agent_inbox`, `delegation_status`, `memory_search`,
  `board_read` are tagged). Guests inherit agent sandbox rights. The approval
  convention does not enumerate host-gated operations. Operations ignoring abort
  may outlive the five-second grace; an agent crash mid-script is reported to the
  model as “interrupted”. Queued operations count toward progress and eight long
  waits can fill all slots.
- **Rust post-cutover, waived not passed:** full PTC/task-time comparison with the
  TypeScript baseline, real-provider smoke tests and polyglot evaluation.
  Reopening needs an agreed protocol, budget and credentials (historical tooling
  at `2d480d3`). Rust protocol 10 is incompatible with TypeScript nodes/gateways;
  current upgrades must follow [Upgrades](../docs/deploy/upgrades.md). Never
  delete old state without approval.

## Watch, do not build yet

- **Consolidation (“dreaming”):** only if `memory_full` becomes frequent at 8,000
  characters; revisit budgets first. Keep origins: consolidated text must not
  gain `user` origin.
- **Moving chats between projects and shared project files:** revisit remaining
  workflow friction only when painful with more than a handful of chats; shared
  project files themselves are already implemented.
- **Vector index (sqlite-vec / ANN):** brute-force cosine is planned in
  [memory search](memory-search.md) phase 2; revisit an index only at the
  thresholds listed there.
- **A second chat node:** needs its own `chats` workspace and a New chat rule.
- **`workspace.read`:** reading a linked repository without delegating, only if
  chats keep delegating just to look at a file.

## Memory integration

The authorized [memory handoff redesign](memory-handoff.md) has been ported to the Rust mainline. Its final validation record and separate repository activation constraints are maintained there; this does not authorize deployment or existing-ledger activation.
