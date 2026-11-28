# M10 Versions and updates

[Open work](README.md) · [Roadmap](roadmap.md) · [Releasing](../docs/development/releasing.md)

Goal: every client and server knows which versions work together and which versions
have known problems, tells the user in plain words with a link to the matching
GitHub release, and the Gateway and its nodes can update themselves after the user
agrees, without losing state or a reply in progress.

**Delivery order.** M10A (steps 0–4, then 7) provides release information from
GitHub, advisories, manual update guidance and the migration/backup foundations.
It is accepted independently and exposes no install action. M10B (steps 5–6) adds
graceful replacement for supported installations after M10A passes. It is not
accepted until the failure and recovery cases below pass. M11 completes the
production Web service and phone pairing on Compose.

Examples of what the user sees (illustrative versions, not releases):

- App: "This app version still works with your server, but it has a known problem:
  the conversation screen can stutter. Version 0.12.1 fixes it." with **View release**.
- Server: "Your server version has a security problem in the agent sandbox. Update
  to 0.12.2 as soon as possible." with **View release** in M10A, or **Update now**
  for an eligible installation in M10B.
- After an update: "Server updated to 0.12.2. Data was kept." in Activity and
  as a notification.

## Decisions (owner, 2026-11-28)

- **Release information comes only from the repository's GitHub, over HTTPS (P22).**
  The fixed URLs are compiled into the Gateway and the updaters: the release index
  on `main` and the assets of each version's GitHub Release. Links shown to the
  user are only ever under `https://github.com/mozufu/pirc/releases/`; anything
  else in the data is refused. Clients take the information from their own Gateway,
  which is the user's server; they do not fetch or verify it themselves.
- **M10B adds graceful replacement (P23):** stop taking new work, let replies in
  progress finish, back up, replace the binaries, restart, restore on failure,
  report. There is no in-process hot swap. M10A ships only advisories and manual
  guidance.
- **No pirc-managed signing keys (P28).** pirc does not run its own signing keys,
  key rotation or revocation. Release integrity rests on three things:
  - **Immutable releases.** The repository has GitHub immutable releases enabled,
    so a published release's assets and tag cannot be changed; GitHub attaches a
    signed release attestation listing the tag, commit and assets.
  - **Checks by the updater.** Before installing, the updater fetches the release
    from GitHub itself, requires it to be immutable, verifies the release attestation
    if the step 0 spike shows that is practical, and checks every download's size and
    SHA-256 against the release's own `pirc-release.json`.
  - **A waiting period.** An update is offered only after the release has been
    public for 48 hours (24 hours when it fixes a `security` advisory), counted
    from the `published_at` that the GitHub Releases API reports, never from the
    index. A release that should not have been published can be withdrawn in that
    time.

  What this does not cover: someone who controls the owner's GitHub account can
  publish a normal-looking release. The waiting period and the owner's consent
  are the remaining checks, as with a manual download. Securing the GitHub account
  is the owner's (passkeys are in use) and is not part of this plan.

## Version model (existing, kept)

- Product version: one SemVer for all parts (`package.json`; see
  [Versioning and releases](../docs/development/releasing.md)).
- Client API: `API_VERSION` in `crates/pirc-gateway/src/capabilities.rs`; a client
  with another API version gets `426 client_upgrade_required`. A matching API
  makes a client eligible to connect; it is not an upgrade decision.
- Node protocol: `NODE_PROTOCOL_VERSION` in `crates/pirc-protocol/src/lib.rs`;
  Gateway and nodes move together when it changes.
- **Update eligibility** additionally checks the installed components and
  platform artifacts, the target Gateway/Node protocol, the installed schema
  and an explicitly supported migration path for each component. A target schema
  number alone cannot establish that path. Installed state comes from the local
  process or its updater, not only from a version reported by another host.

## Release information

Two kinds of document, both JSON, both read only over HTTPS from fixed URLs:

- **The release index**, `release/index.json` on `main`, fetched from
  `https://raw.githubusercontent.com/mozufu/pirc/main/release/index.json`. It holds
  what changes after a release: each version's status and the advisories. Changes go
  through ordinary commits, so they have public history.
- **One release file per version**, `pirc-release.json`, an asset of that version's
  immutable GitHub Release. It holds what is fixed at release time: API version,
  node protocol, supported migration paths and every asset with its size and SHA-256,
  image digests included. The release attestation covers it like any other asset.

Release index (example):

```json
{
  "format": 1,
  "updatedAt": "2026-12-20T08:00:00Z",
  "releases": [
    {
      "version": "0.12.2",
      "tag": "v0.12.2",
      "publishedAt": "2026-12-20T07:40:00Z",
      "status": "supported",
      "summary": { "en": "…", "zh-TW": "…" }
    }
  ],
  "advisories": [
    {
      "id": "PIRC-2026-0003",
      "kind": "security",
      "severity": "high",
      "components": ["node"],
      "affected": ">=0.11.0 <0.12.2",
      "fixedIn": "0.12.2",
      "publishedAt": "2026-12-20T07:40:00Z",
      "title": { "en": "…", "zh-TW": "…" },
      "summary": { "en": "…", "zh-TW": "…" },
      "action": "update_now",
      "state": "active"
    }
  ]
}
```

Release file (example):

```json
{
  "format": 1,
  "version": "0.12.2",
  "tag": "v0.12.2",
  "commit": "…",
  "url": "https://github.com/mozufu/pirc/releases/tag/v0.12.2",
  "apiVersion": 2,
  "nodeProtocol": 17,
  "schema": {
    "gateway": { "target": 1121, "from": [1120, 1121] },
    "node": { "target": 2102, "from": [2101, 2102] }
  },
  "assets": [
    {
      "name": "pirc-v0.12.2-darwin-arm64.tar.gz",
      "platform": "macos-arm64",
      "sha256": "…",
      "size": 12345678
    }
  ],
  "images": [
    { "name": "ghcr.io/mozufu/pirc-gateway", "digest": "sha256:…" },
    { "name": "ghcr.io/mozufu/pirc-node", "digest": "sha256:…" }
  ]
}
```

- `kind`: `security`, `bug`, `performance`, `compatibility`. `severity`: `info`, `low`,
  `medium`, `high`, `critical`. `components`: `gateway`, `node`, `chat`, `app-android`,
  `app-web`, `app-macos`. `action`: `none`, `update`, `update_now`, `workaround`
  (with `workaround` text). `state` of an advisory: `active` or `retracted`; an
  advisory is never deleted from the index, only retracted. `status` of a release:
  `supported`, `deprecated`, `withdrawn`. A withdrawn release is never offered. An
  update to it that has not started draining stops; one that has started draining
  follows step 6: it finishes the same plan or rolls back every changed host, shows
  `recovery_required` when an outcome is unknown, and never leaves mixed versions.
- **Consistency.** A version is offered only when the index lists it as
  `supported` or `deprecated`, its release exists and is immutable, the release
  file's `version`, `tag` and `url` match the index entry, and the index
  `publishedAt` equals the release's `published_at` from the GitHub API. A mismatch
  refuses that version. A version lower than the installed one is never offered.
- **Images.** `images` may be empty in a release file made before Docker images
  exist (M10A dry runs). From 0.11.0 (M14), a release file without a digest for
  each published image is refused.
- **Index rollback.** The Gateway keeps the highest `updatedAt` it has accepted and
  every advisory it has seen. An index with a lower `updatedAt` is ignored, and an
  advisory missing from a newer index stays shown until the index marks it
  `retracted`.
- **Failures.** A fetch or parse failure is shown as "could not check" with the
  time of the last good check; the last good data stays visible for display, marked
  stale after 7 days, and never shown as "up to date". Install offers need a
  successful check within the last 24 hours; checks run every 12 hours, so one
  failed check does not hide an offer.
- Advisory text says what is affected and what to do, never how to exploit it.
- Strings come in English and Traditional Chinese; clients fall back to English.

## Step 0 — Formats, parser and the attestation spike

- **0a Formats.** Rust types and parsing (in `crates/pirc-protocol` or a small
  `pirc-release-info` crate) with `deny_unknown_fields` on known formats, SemVer
  range matching, the URL rule and the consistency rule. Dart parsing in
  `packages/pirc_client` for the copy the Gateway relays. Shared fixtures in
  `fixtures/release-info/`: valid, foreign URL, index and release file that
  disagree, `publishedAt` different from the API value, withdrawn, retracted
  advisory, older index, lower version, empty `images` before and after 0.11.0,
  unknown fields, stale data.
- **0b Validation script.** `scripts/release-info.ts check` validates
  `release/index.json` (and a given release file). It runs in `bun run check`, so
  it runs before every push, and again in CI. CI runs after a push and cannot stop
  a malformed index from reaching `main`; that is acceptable because every Gateway
  validates the index itself and keeps its last good copy, so a malformed index
  only shows "could not check". This does not catch a valid but wrong advisory or
  status; the owner reviews each index edit. Commands that edit the index for a
  commit: `add-release <tag>` (P39), `add-advisory`, `retract-advisory`,
  `withdraw`.
- **0c Spike: verifying the release attestation.** GitHub signs immutable releases
  with an attestation in the Sigstore bundle format. Measure whether the updater
  can verify it in Rust (the `sigstore` crate or a small verifier for this one
  bundle type): binary size, the trust root it needs and how that root is updated,
  offline behavior, and how it fails. The `gh` CLI is not a runtime dependency.
  Also confirm the API fields the updater relies on (the release's immutable flag,
  asset digests). Outcome: either the updater verifies the attestation (repository,
  tag, commit and the digest of `pirc-release.json`), or it relies on immutable
  releases, HTTPS and SHA-256 alone. The owner chooses from the spike report;
  M10B depends on it, M10A does not.

**Done when:** Rust and Dart pass the same fixtures; the script refuses each bad
fixture; the spike report is accepted.

## Step 1 — Gateway checks for updates

- Setting **Check for updates** (default on; interval 12 hours; a **Check now**
  button). The Gateway fetches the release index and, for each version newer than
  its own, that release's `pirc-release.json`; validates them (step 0); and stores
  the accepted data and the check time. Requests are plain GETs with a generic user
  agent and send nothing about the installation.
- `GET /api/updates`: the accepted index and release files, the Gateway's own version,
  API version, node protocol, the versions of connected nodes, the install kind
  (step 6), the last check time and result, and for each newer version when its
  waiting period ends. A hint (`updates=1`) tells clients when it changes. The route
  needs the same device authentication as every other route; only the API version
  check is waived, so a client too old for the API can still learn which release
  to install.

**Done when:** conformance tests with a local test server cover accept, foreign URL,
disagreeing files, a backdated `publishedAt`, an older index, withdrawn, offline
and stale; `/api/updates` refuses an unauthenticated request; no request leaks host
details.

## Step 2 — Clients show compatibility and advisories

- On start, on resume and on the `updates` hint, the client reads `/api/updates` and
  matches: its own version against advisories for its component; the Gateway's and
  each node's version against theirs; newer releases eligible for the client API.
  A client match does not enable a server install action.
- **Settings → About and updates**: this app's version, the server and node versions,
  each matching advisory, the newest release with its publish time and summary, and
  **View release** (opens the exact tag page in the browser).
- **Banner** on the Chat and Work tabs for `update_now` or severity `high`/`critical`;
  it can be hidden per advisory and comes back when a new advisory matches.
- **On `426 client_upgrade_required`**: the client reads `/api/capabilities` and
  `/api/updates` (both exempt from the version check) and names the release whose API
  version matches the server, with its link, instead of a generic message.
- Android opens the release page; installing the APK stays the user's step in this
  milestone. Web reloads to get the bundle the server serves.
- M10A shows **View release** and manual instructions for the detected install
  kind. **Update now** and **Update when idle** appear only for an eligible
  M10B deployment with its updater available.

**Done when:** widget tests for each banner and the About page, goldens at four widths
in both languages; the `426` path is tested against a Gateway with another API
version.

## Step 3 — Schema migrations from the release on

P5 stays in force for the cutover from 0.10.x or earlier to **pirc 0.11.0**:
start with fresh state. From an installed 0.11.0 onward, updates keep data (P24).
Every Gateway and Node schema change after 0.11.0 ships numbered forward migrations
and a test against the previous supported release's database with fixture data.
Order: M10 builds the migration runner and the fixture harness; the 0.11.0 release
(M14) records its schema fixtures; the first schema change after 0.11.0 is the first
one tested against a real previous-release fixture. A skip-version update is offered
only if each installed schema has a verified path to the target; otherwise show
the required intermediate release or manual instructions. No implicit downgrade
migration; rollback restores the pre-update snapshot before writes resume.

**Done when:** the migration runner and the fixture harness exist for both databases
and migrate a synthetic older schema in tests; `releasing.md` lists the rule,
including recording the fixtures at each release.

## Step 4 — State bundle format

One format for the pre-update snapshot (this milestone) and for export
(M13 step 2). Import is later (P32).

- A directory or a `.pirc-bundle` archive (tar, zstd) with `bundle.json` at its root:
  format version, product version, schema numbers, creation time, kind (`snapshot`
  or `export`), the host role (`gateway`, `chat`, `node`) and one entry per part
  (path, SHA-256, size, whether it holds secrets).
- Parts: databases as SQLite backup copies, state files as files, node transcripts
  and uploads as directories. A reader refuses a bundle whose hashes do not match or
  whose format it does not know.
- A `snapshot` bundle may hold secrets (provider settings, push keys, node tokens)
  and is written with owner-only permissions in the state directory; it never leaves
  the host. An `export` bundle (M13) never includes parts containing system
  credentials or any recovery snapshot, encrypted or not.

**Done when:** writer and reader for the Gateway and node state pass round-trip tests,
including a corrupted part and an unknown format.

## Step 5 — Docker install

A Docker Compose installation for an always-on Linux host, next to the Nix packaging
and the native archives (P31, P36). Coding nodes stay native: they need the user's
workspaces and toolchains, and on macOS the Seatbelt sandbox.

**What Docker is for (P36).** Docker is a way to install and update pirc, not a
security layer. The boundary around agents is the agent sandbox (bubblewrap on
Linux), the same as on a native install:

- The container is not counted as a boundary. No sandbox check is skipped or relaxed
  because a process runs in a container, and a container that cannot give the
  sandbox what it needs refuses to start agents (fail closed, as on any host).
- The usual container hygiene in 5b (non-root user, read-only root file system,
  pinned base images) is kept as good practice, not as part of the security model.
- Settings added so bubblewrap can run inside the container (5a) also widen what the
  container may do on the host, so they stay at what bubblewrap is measured to need.
- Docker does not update native installs; those use their own path (step 6).

**Linux hosts only.** Docker Desktop on macOS and Windows runs containers in a Linux
VM, where Seatbelt does not exist and bubblewrap depends on the VM's kernel and
settings, which pirc does not control or test. A Mac runs pirc from the native
archive; `docs/deploy/docker.md` says so on its first page.

**5a Spike (first).** Run the chat node with its agent sandbox inside a container and
record, per host (Linux x86_64 and arm64, Docker and rootless Docker, Podman):

- what bubblewrap needs (user namespaces, mounts, the network proxy) and the
  narrowest settings that give it: a seccomp profile that adds only what bubblewrap
  needs, an AppArmor profile, no `--privileged`, no added capabilities beyond what
  is measured to be required;
- whether Chromium can run under container-specific limits without weakening
  M9's native sandbox and browser invariants;
- that a container without these settings still refuses to start agents (fail
  closed, as on any host).
- the pass mark: the agent sandbox tests that run on a native Linux host pass
  unchanged inside the container. A result that passes only with a weaker sandbox
  means the chat node stays native.

Outcome: either the chat node joins the Compose file with the measured settings, or
the Compose file holds only the Gateway and the docs say to run the chat node
natively. The owner chooses from the spike's numbers.

**5b Images.** `ghcr.io/mozufu/pirc-gateway` and `ghcr.io/mozufu/pirc-node` (chat
uses the `chat` subcommand), `linux/amd64` and `linux/arm64`, built by Release CI from
the tagged commit; base images pinned by digest; a non-root user; read-only root file
system; state only in named volumes (`/var/lib/pirc/gateway`, `/var/lib/pirc/chat`);
secrets through files (`*_FILE` variables), never baked in. The release file
(`pirc-release.json`) lists each image digest.

**5c Compose.** `deploy/docker/compose.yaml` and `.env.example`: `gateway`, `chat`
(per 5a) and `updater` in M10. Use a local test client and disposable credentials
for Compose acceptance; do not depend on the old Web app or on production pairing.
M11 adds the production `web` service (Flutter served by nginx), then verifies
v2 phone pairing and the complete install. The identity provider and TLS stay the
user's choice; the example binds to loopback. A new guide `docs/deploy/docker.md`
(Linux hosts only).

**5d Updater.** `pirc-updater`, a small separate image, is the only service that
mounts the Docker socket. Its control socket is shared only with the Gateway.
The updater fetches the release from GitHub itself and runs the step 0 checks
(immutable release, attestation if adopted, release file); it takes nothing from
the Gateway beyond the version of the approved plan. It pulls exact digests and can
recreate only the registered services in its own Compose project. On a Compose
host it is the update coordinator (6a). It accepts apply or rollback only for a
plan it prepared itself and with the consent token bound to that plan (step 6,
P37); a Gateway connection alone is not consent. Never accept arbitrary images,
commands or deployment definitions. The Gateway never holds the Docker
socket and agents never see either socket. The updater stays minimal, has its
own tests and is re-reviewed before release (M14).

**Done when:** the spike report is accepted; a fresh `docker compose up` gives a
working Gateway and the supported Node setup for the local test client; the update
test of step 6 passes on Compose. Production Web and phone pairing are M11 gates.

## Step 6 — Graceful update

Install kinds (P31):

| Kind                                    | Who replaces the software                                             | Previous version kept as                  |
| --------------------------------------- | --------------------------------------------------------------------- | ----------------------------------------- |
| Docker Compose (step 5)                 | the `pirc-updater` container                                          | the previous image digests                |
| Native archive under systemd or launchd | the native `pirc-updater` (6a) under systemd or launchd               | the previous binaries beside the new ones |
| Nix and NixOS                           | the user (pirc shows the advisory, the release link and the commands) | the previous generation                   |

**6a The updater and the coordinator.**

- **Deliverable.** A crate `crates/pirc-updater` with one binary, shipped in every
  native archive and as the `pirc-updater` image (5d). It runs as the pirc service
  user (or a dedicated user that owns the same state and install paths), never as
  root, and holds no provider keys.
- **Native install.** `pirc-updater install --service gateway|node|chat` detects
  whether the pirc service is a system or user unit. For a system service it writes
  a system unit for the updater, running as a dedicated unprivileged user, plus a
  narrowly scoped polkit rule (or sudoers drop-in) that allows only
  `systemctl start|stop|restart|is-active` on the registered pirc units. For a user
  service it writes a user unit. On macOS it uses a LaunchDaemon for system
  services or a LaunchAgent for user services. The updater never runs as root. It
  records the service name and the install paths it may replace in its own
  owner-only state directory and checks that it can restart that service. Native
  binaries live in a versioned directory owned by that user, with a stable symlink
  for the service unit; the updater refuses an install path it cannot write rather
  than writing a root-owned path.
  Installing a system unit and its polkit rule is a one-time administrator step
  (root or sudo); the running updater is unprivileged. `pirc-updater uninstall`
  removes the unit and the rule. `pirc-updater status` prints the registration.
  The guide is [Upgrades](../docs/deploy/upgrades.md), extended with these steps.
- **The coordinator** is the updater on the Gateway host (native or Compose), not
  the Gateway, because the Gateway is itself replaced. It owns the plan and the
  journal and drives every state: it asks the Gateway to drain, takes the backups,
  swaps, checks health, commits, resumes or rolls back. The Gateway only shows the
  plan, relays consent and obeys the drain fence.
- **Participants** are the updaters on node hosts. Each participant connects
  outbound to the Gateway over HTTPS with its existing node token and polls a
  stable `/api/updates/agents` route (or an equivalent separate socket) for plans
  and posts receipts. This update channel is versioned separately from
  `NODE_PROTOCOL_VERSION`; it ships in 0.11.0 and a later release must keep its
  older side compatible, so an update never depends on the node protocol of the
  version being replaced. A node without the updater or channel is manual-only and
  blocks a protocol/schema-changing update (P38). Each participant checks the plan
  against GitHub itself. While the Gateway restarts, participants keep their state
  durably and continue when the channel returns. Order within a plan: drain, back
  up every host, swap remote nodes, swap the Gateway host, health of all, commit.
- **Updating the updater** is never part of a plan. After a plan reaches `done`, a
  newer updater is installed as its own small step: natively, the service manager
  starts the new binary and a shipped fallback unit (systemd `OnFailure=`, a
  launchd wrapper) restores the previous binary if it is not healthy within
  60 seconds; on Compose, a one-shot helper container from the new image recreates
  the `updater` service and restores the previous digest on the same failure. Each
  updater can read the journal format of the previous release.

An installation without a registered updater uses M10A guidance. Normal
Gateway and Node processes do not get install permissions. A separately managed
updater restricted to the registered service and paths survives a service restart
and resumes from durable state after its own restart. The update drain is an
explicit protocol. A standalone `SIGTERM` or manual `docker compose up -d` does
not imply the coordinated drain or rollback guarantees.

Store one immutable plan per attempt and allow only one active plan per
installation: update ID, owner approval, component set, current and target
versions, artifact digests, and separately recorded snapshot IDs and per-host
receipts. Keep the coordinator's journal and the participating updaters'
state **outside the state that a rollback restores**. After an unknown outcome
reload these records and reconcile the existing update; do not start a second one.

States (stored and shown to clients with Activity entries):
`available → consented → downloading → verified → draining → backing_up → swapping →
restarting → migrating → all_healthy → committed → resuming → done`.
Before `swapping`, a failed attempt aborts and removes the drain fence. Between
`swapping` and `committed`, finish the same verified plan or roll back all changed
hosts; show `recovery_required` if any outcome is unknown. `committed` is a durable
decision written only after all required participants report target health while
still fenced. After it, retry resume and reporting as needed, but do not
automatically restore a snapshot once new writes may have occurred.

1. **Consent.** The owner explicitly approves the exact installation, host set and
   target artifacts. Mechanism (P37): a management grant
   ([native management authorization](../docs/architecture/native-management.md))
   with a new capability `updates:apply`, approved by the owner in the browser.
   The grant is exchanged for a consent token bound to the plan digest (update ID,
   target version, host set, artifact digests), valid 15 minutes. The coordinator
   checks it at consent and again immediately before apply; if it expired, the
   owner re-approves the same plan digest without downloading again. Web-only
   owners use the equivalent forward-auth confirmation (or pair a device); an
   ordinary paired device session or pot cannot authorize it. Threat model (P37): this
   stops mistakes, stale plans and arbitrary commands over the Gateway connection.
   It does not defend against an already compromised Gateway, which controls pots
   and nodes anyway; such a Gateway can at most start an update to a release that
   passes the updater's own GitHub checks. The sheet shows the target version, its summary and
   advisories, the estimated downtime, the nodes that will update, and what stops:
   runs that are waiting, side-panel terminals, background tasks and browsers that a
   restart ends. Choices: **Update now**, **Update when idle**, **Not now**. The
   sheet is offered only after the waiting period (P28); before that, the About
   page shows when the update becomes available and **View release**.
2. **Download and verify.** Each host's updater fetches the release itself (step 0
   checks), downloads its asset from that release and checks size and SHA-256 from
   `pirc-release.json`; Docker pulls each image by the digest in that file, never by
   tag. Remote nodes download their own asset when their participant receives the
   plan; they report ready or a reason.
3. **Preflight.** Check disk space, local updater enrollment, previous binaries and
   migration support for every required host. Required hosts (P38): when
   the target changes the node protocol or a node schema, the Gateway and every
   registered, non-retired node; an offline or unsupported one blocks the update
   before draining. Otherwise, the Gateway host and the online nodes; offline nodes
   are named in the consent sheet with a warning and are updated by their
   participant when they reconnect, with their own snapshot, under the same
   checks. On reconnect the participant re-reads the index (withdrawal and
   advisory state), revalidates the plan and its consent token, and asks for a new
   approval if the token expired; a withdrawn release is not applied. No host is
   silently omitted. Revalidate the plan and consent before beginning the drain.
4. **Drain.** The Gateway stops starting new runs, wakes and scheduled runs (they stay
   queued; nothing is dropped and nothing is re-sent through another path, N8), and
   waits until each run in progress ends its current reply. Default limit 10 minutes;
   then it asks the user: wait longer, stop at the next tool boundary, or cancel the
   update.
5. **Back up.** After every host acknowledges the drain fence, copy Gateway and
   Node databases through the SQLite backup API, plus the
   state files of [Backup and recovery](../docs/deploy/backup-and-recovery.md), into a
   `snapshot` bundle (step 4). Verify integrity and restorability before swapping
   any host. Keep the last three snapshots and never prune one used by an open plan.
6. **Swap and restart** through the service manager (systemd unit, launchd agent) or,
   for Docker, by the updater recreating the pirc services of its Compose project;
   the process never replaces itself while running.
7. **Migrate, check health, commit, resume.** Replacement processes start fenced
   and run migrations. Verify target versions, schema, health and required
   Gateway–Node links before committing. Then release queued work in its original
   order; clients reconnect and get "Updated to X".
8. **Roll back before commit.** On failure that cannot safely finish the plan,
   restore old binaries or digests and the verified pre-update state on every
   changed participant. Unchanged hosts stay fenced until those participants
   confirm old-version health. If a host disappears mid-update, keep work fenced
   and show explicit recovery state; do not resume a mixed installation.

What survives without extra work: session transcripts on the nodes are the source of
truth and replies in progress finished while draining, so no model state has to be
serialized. What does not survive: processes the restart ends; the consent sheet
names them.

**Done when:** tests on Linux CI (native and Compose) and macOS (native) update a
Gateway and Node between two local builds, with a reply in progress, a queued
wake and a schedule due during the update, and show all three complete once.
Tests also cover an offline Node with a protocol change (blocks before drain), an
offline Node without one (updated on reconnect), an unsupported Node, a
participant lost after swapping, a withdrawal after draining started, an expired
or mismatched consent token, the updater updating itself and falling back, a failing migration, and a killed updater or host after drain,
backup, swap, migration and commit. Verify that recovery follows the same update
ID, no mixed-version installation processes work, pre-commit rollback preserves
data, and post-commit recovery does not discard new writes.

## Step 7 — Release pipeline (M10A)

- **Precondition, checked first.** Confirm in the repository settings that
  immutable releases are available and enabled, and that a test release receives a
  release attestation. If either is missing, stop and ask the owner; the trust
  model of P28 is not built on a feature that is off.
- **Uploads only while a draft.** Nothing is uploaded after publishing (a later
  upload is refused and would not be covered by the attestation).
- **Release CI** builds from the tag. After the final assets exist (the APKs
  signed), it computes sizes and SHA-256, writes `pirc-release.json` (assets, image
  digests, API version, node protocol, migration paths; `images` may be empty in
  M10A) and `SHA256SUMS`, and uploads them with the assets to the draft release.
  It then downloads the draft's assets again and checks them against both files
  before the release is offered to the owner to publish. Actions in the release
  workflow are pinned to commit SHAs.
- **Index change (P39).** After the owner publishes the release, the owner
  runs `scripts/release-info.ts add-release <tag>`, which reads the release from the
  GitHub API (immutable flag, `published_at`, the hash of `pirc-release.json`) and
  adds the entry as `supported`; the commit goes to `main` as usual (P11). CI holds
  no permission to push to `main`. Until the index lists a version, it is not
  offered.
- **Advisories and withdrawals** without a new version are index commits
  (`add-advisory`, `retract-advisory`, `withdraw`); they take effect at each
  Gateway's next check.
- `releasing.md` gains: the precondition, enabling immutable releases, when to add
  an advisory, how to withdraw a release, and that a release published by mistake
  is withdrawn, never edited.

**Done when:** a dry run in a test repository publishes an immutable pre-release
with `images: []` whose attestation verifies (`gh release verify`, and the updater
check if step 0c adopts it); the re-download check catches a replaced draft asset;
`add-release` refuses a mutable release; an invalid index fails `bun run check`; a
withdrawn version stops being offered at the next check. M10A can then be accepted
without M10B.

**Not in M10:** installing the Android APK from inside the app, delta updates,
automatic updates without consent, updating Nix installations, a Docker image for
coding nodes, Docker on macOS or Windows hosts.
