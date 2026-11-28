# M10 Versions and updates

[Open work](README.md) · [Roadmap](roadmap.md) · [Releasing](../docs/development/releasing.md)

Goal: every client and server knows which versions work together and which versions
have known problems, tells the user in plain words with a link to the matching
GitHub release, and the Gateway and its nodes can update themselves after the user
agrees, without losing state or a reply in progress.

**Delivery order.** M10A (steps 0–4, then 7) provides signed release information,
advisories, manual update guidance and the migration/backup foundations. It is
accepted independently and exposes no install action. M10B (steps 5–6) adds
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

- **The trust root is fixed in the binaries (P22).** The Gateway, Node and app
  compile in the offline root public key. The root signs short-lived delegations
  to release-manifest signing keys; it does not sign normal releases. A manifest
  that fails verification is ignored and
  reported as "could not check". Links shown to the user are only ever under
  `https://github.com/mozufu/pirc/releases/`; anything else in a manifest is refused.
  The Gateway relays the signed bytes to clients and every client verifies them
  itself, so a Gateway cannot forge advice.
- **M10B adds graceful replacement (P23):** stop taking new work, let replies in
  progress finish, back up, replace the binaries, restart, restore on failure,
  report. There is no in-process hot swap. M10A ships only advisories and manual
  guidance.
- **Only the delegated signing key is a CI secret (P28).** To keep a compromised
  workflow from signing on its own, this key lives only in a GitHub
  Environment (`manifest-signing`) that requires the owner's approval for every run,
  is limited to the `main` branch and `v*` tags, and is used by one job that runs no
  third-party action after the key is loaded. The job signs a reviewed manifest
  tied to the verified tag, commit and artifact digests; it does not run code from
  an unverified release checkout. The offline root is never loaded in CI.

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

## The manifest

Two JSON assets: `pirc-trust.json` (root-signed key delegation and revocation)
and `pirc-manifest.json` (release-signed version and advisory data). Each is a
single bounded envelope containing `format`, `keyId`, `payload` and `signature`.
The signature covers the exact UTF-8 payload bytes, with a distinct signing
domain for each asset. Encode payload and Ed25519 signature as base64url; do not
re-serialize JSON before verification. The example below is the decoded release
payload, not the envelope.

```json
{
  "format": 1,
  "trustEpoch": 3,
  "sequence": 42,
  "generatedAt": "2026-12-20T08:00:00Z",
  "expiresAt": "2027-01-20T08:00:00Z",
  "releases": [
    {
      "version": "0.12.2",
      "tag": "v0.12.2",
      "publishedAt": "2026-12-20T07:40:00Z",
      "url": "https://github.com/mozufu/pirc/releases/tag/v0.12.2",
      "apiVersion": 2,
      "nodeProtocol": 17,
      "schema": {
        "gateway": { "target": 1121, "from": [1120, 1121] },
        "node": { "target": 2102, "from": [2101, 2102] }
      },
      "status": "supported",
      "summary": { "en": "…", "zh-TW": "…" },
      "assets": [
        {
          "name": "pirc-v0.12.2-darwin-arm64.tar.gz",
          "platform": "macos-arm64",
          "sha256": "…",
          "size": 12345678
        }
      ]
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
      "action": "update_now"
    }
  ]
}
```

- `kind`: `security`, `bug`, `performance`, `compatibility`. `severity`: `info`, `low`,
  `medium`, `high`, `critical`. `components`: `gateway`, `node`, `chat`, `app-android`,
  `app-web`, `app-macos`. `action`: `none`, `update`, `update_now`, `workaround`
  (with `workaround` text). `status` of a release: `supported`, `deprecated`,
  `withdrawn` (a withdrawn release is never offered).
- **Freshness and replay.** Persist the highest root-signed trust epoch and,
  within it, the highest release `sequence` together with an authenticated payload
  digest. Reject lower values and conflicting contents at the same value;
  identical payloads are idempotent. Only the offline root can advance the trust
  epoch, so a released signing key cannot carry a sequence into a new epoch.
  Require a valid clock, `generatedAt` before `expiresAt`, and an unexpired
  delegation and manifest before offering or applying an update. An expired last
  known manifest may be shown as stale, never as "up to date". The update
  rollback must not roll back these verifier watermarks.
- **Routine rotation.** The offline root signs a new trust epoch listing the
  allowed key IDs and expiry (delegations last at most 30 days). Publish the
  delegation before the first manifest signed under the new epoch. A verifier
  accepts only manifests for its current verified epoch and a listed key.
- **Emergency revocation.** The offline root publishes a higher epoch without
  the compromised key, then a manifest signed by a replacement. A verified
  higher epoch is persisted even if its matching release manifest is not yet
  available; no cached manifest from the revoked epoch can authorize an update.
  A client that has not received revocation may still trust an unexpired old
  delegation, so revocation is not instantaneous. Compromise of the offline
  root itself requires a reviewed rebuild with a new root and out-of-band notice.
- **Partial publication or fetch.** Each asset contains its own signature, so
  there is no detached-signature swap. A missing, malformed or mismatched pair
  disables install offers until a current pair verifies. Keep independently
  verified state and any cached advisory only for display, with freshness
  indicated; do not lower the trust epoch or silently report success.
- Advisory text says what is affected and what to do, never how to exploit it.
- Strings come in English and Traditional Chinese; clients fall back to English.

## Step 0 — Manifest format and verifier

- `crates/pirc-protocol` (or a new small crate `pirc-manifest`): types, parsing with
  `deny_unknown_fields` on known versions, SemVer range matching, signature check,
  URL rule, sequence and expiry rules.
- Dart: the same rules in `packages/pirc_client` (or a new `pirc_manifest`), with
  shared test vectors in `fixtures/manifest/`: valid, bad signature, foreign URL,
  lower sequence, same sequence with different content, expired, unknown fields,
  routine rotation, revoked key, and mixed epochs.
- `scripts/manifest.ts`: build the next manifest from the previous one plus a release
  or advisory entry, and sign it with a key read from the environment (the CI secret)
  or, for tests, from a key file given on the command line; no key is ever stored in
  the repository.

**Done when:** Rust and Dart pass the same vectors; the script round-trips.

## Step 1 — Gateway checks for updates

- Setting **Check for updates** (default on; interval 24 hours; a **Check now**
  button). The Gateway fetches the manifest and signature, verifies them, stores the
  accepted bytes and replay watermarks separately from the restorable service
  snapshot, and never sends anything about the installation in the request
  (plain GET, generic user agent).
- `GET /api/updates`: the stored signed envelopes, the Gateway's own version, API version,
  node protocol, the versions of connected nodes, the install kind (step 6) and the
  last check time and result. A hint (`updates=1`) tells clients when it changes.
- The Gateway computes nothing the clients must trust; clients verify and match.

**Done when:** conformance tests with a local manifest server cover accept, refuse,
replay, expiry, offline; no request leaks host details.

## Step 2 — Clients show compatibility and advisories

- On start, on resume and on the `updates` hint, the client verifies the manifest and
  matches: its own version against advisories for its component; the Gateway's and
  each node's version against theirs; newer releases eligible for the client API.
  A client match does not enable a server install action.
- **Settings → About and updates**: this app's version, the server and node versions,
  each matching advisory, the newest release with its publish time and summary, and
  **View release** (opens the exact tag page in the browser).
- **Banner** on the Chat and Work tabs for `update_now` or severity `high`/`critical`;
  it can be hidden per advisory and comes back when a new advisory matches.
- **On `426 client_upgrade_required`**: the client reads `/api/capabilities` and the
  manifest (both exempt from the version check) and names the release whose API
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
Every Gateway and Node schema change ships numbered forward migrations and a test
against the previous supported release's database with fixture data. Record the
0.11.0 schema fixtures for the first such update. A skip-version update is offered
only if each installed schema has a verified path to the target; otherwise show
the required intermediate release or manual instructions. No implicit downgrade
migration; rollback restores the pre-update snapshot before writes resume.

**Done when:** the migration runner exists for both databases; the test harness opens
a previous-release fixture and migrates it; `releasing.md` lists the rule.

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
secrets through files (`*_FILE` variables), never baked in. The manifest's release
entry lists each image digest.

**5c Compose.** `deploy/docker/compose.yaml` and `.env.example`: `gateway`, `chat`
(per 5a) and `updater` in M10. Use a local test client and disposable credentials
for Compose acceptance; do not depend on the old Web app or on production pairing.
M11 adds the production `web` service (Flutter served by nginx), then verifies
v2 phone pairing and the complete install. The identity provider and TLS stay the
user's choice; the example binds to loopback. A new guide `docs/deploy/docker.md`
(Linux hosts only).

**5d Updater.** `pirc-updater`, a small separate image, is the only service that
mounts the Docker socket. Its control socket is shared only with the Gateway.
The updater independently verifies the signed manifest, pulls exact digests and
can recreate only the registered services in its own Compose project. Authenticate
the local caller and bind apply or rollback to a specific approved update plan and
its receipts; a Gateway connection alone is not consent. Never accept arbitrary
images, commands or deployment definitions. The Gateway never holds the Docker
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
| Native archive under systemd or launchd | an explicitly installed updater managed by systemd or launchd         | the previous binaries beside the new ones |
| Nix and NixOS                           | the user (pirc shows the advisory, the release link and the commands) | the previous generation                   |

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
   target artifacts through a scoped management action. An ordinary paired device
   session or pot cannot authorize it. The sheet shows the target version, its summary and
   advisories, the estimated downtime, the nodes that will update, and what stops:
   runs that are waiting, side-panel terminals, background tasks and browsers that a
   restart ends. Choices: **Update now**, **Update when idle**, **Not now**.
2. **Download and verify.** Each host downloads its asset from the release URL in the
   manifest and checks size and SHA-256 from the signed manifest; Docker pulls each
   image by the digest in the manifest, never by tag. Remote nodes download their own
   asset when the Gateway tells them; they report ready or a reason.
3. **Preflight.** Check disk space, local updater enrollment, previous binaries and
   migration support for every required host. For the first implementation,
   the required set is the Gateway and all registered, non-retired Nodes in the
   installation. An offline or unsupported participant blocks the update before
   draining; it cannot be silently omitted. Revalidate the plan and consent before
   beginning the drain.
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
Tests also cover an offline or unsupported Node before drain, a participant lost
after swapping, a failing migration, and a killed updater or host after drain,
backup, swap, migration and commit. Verify that recovery follows the same update
ID, no mixed-version installation processes work, pre-commit rollback preserves
data, and post-commit recovery does not discard new writes.

## Step 7 — Release pipeline (M10A)

- Release CI adds the release entry (archive and APK sizes and hashes, image
  digests) to the manifest and signs it in the `manifest-signing` environment after
  the owner approves the run (P28). The separate root delegation and its
  emergency-revocation process are not part of the release signing job.
- **Where it is published:** a release with the fixed tag `manifest`, marked as a
  pre-release so it is never "latest", whose two assets are replaced on every
  change; clients fetch
  `https://github.com/mozufu/pirc/releases/download/manifest/pirc-manifest.json`
  and `pirc-trust.json` in the same directory. A trust update may briefly make
  the old manifest unusable; clients follow the partial-publication rule above.
  Each version release also carries the verified pair it was published with,
  as an unchangeable record. `releasing.md` names `manifest` as the one release
  whose assets are replaced, and documents recovery without the ordinary key.
- A separate `workflow_dispatch` workflow publishes an advisory or withdraws a release
  without a new version, through the same environment.
- `releasing.md` gains: when to add an advisory, how to withdraw a release, how to
  publish an advisory without a release.

**Done when:** a dry run produces a signed pair from a draft release and every
verifier accepts it. A drill revokes a test CI key using only the offline root,
then verifies that the replacement works, the superseded key is refused, and a
partial publication cannot enable install. M10A can then be accepted without M10B.

**Not in M10:** installing the Android APK from inside the app, delta updates,
automatic updates without consent, updating Nix installations, a Docker image for
coding nodes, Docker on macOS or Windows hosts.
