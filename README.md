# pirc

A private, self-hosted workspace for persistent coding-agent sessions and named pot agents, with a forward-authenticated web UI and a native Android client. It ships as two native Rust executables: `pirc-gateway` and `pirc-node` (including the `chat` role).

It consists of:

- a **gateway** that browsers talk to: authentication, the session index, and routing;
- a **chat node** (`pirc-node chat`) for pots;
- one or more **coding nodes** (`pirc-node`), one per machine with workspaces, which connect out to the gateway and run one built-in agent subprocess per session (over a JSONL RPC on stdin/stdout), plus side-panel shells;
- a responsive Svelte PWA;
- a native Flutter Android client ([`apps/android`](apps/android/README.md)), which pairs through device tokens; browser compatibility and some mobile workflows remain in progress.

The gateway never runs agents or tools; it only runs model requests on their behalf (see [Model backends](docs/guides/model-backends.md)). On a single machine, run the gateway and a node side by side; across devices, each device runs a node that connects to one central gateway over a private VPN. See [gateway and node reference](docs/development/gateway-and-node.md) for setup and the current limitations.

## Features

- **Persistent sessions across machines:** reconnect from the web or Android, follow streaming runs, respond to approvals, and switch between pot threads and coding workspaces.
- **Coding tools and collaboration:** file and shell tools, programmatic tool calling (PTC), background tasks, subagents and agent teams, with workspace write leases and per-session approval modes (`read-only`, `auto`, `full-access`).
- **Pots:** named persistent agents replace the assistant chat. The chat node hosts their sessions; user memory and shared repository memory remain.
- **Memory and context:** observational memory for long sessions, shared USER/MEMORY notes for full-assistant modes, approved USER preferences in coding sessions, and workspace-memory search across repository clones.
- **Workspace panels:** files, Git changes and history, interactive terminals, and browser viewing and takeover. Scheduled runs and push notifications help follow work away from the session.
- **Gateway-managed models:** subscription logins, API keys and custom endpoints, without configuring provider credentials on every node.

See the [user guides](docs/guides/README.md) for behavior and limits. Web and Android coverage differs; see the [Android README](apps/android/README.md) for supported workflows and remaining validation work.

## Security model

### Threat model

pirc is a **single-user, self-hosted tool for a trusted private network**, such as your own VPN or LAN. The operator, gateway, paired nodes, and their operating-system accounts belong to one trust domain. One user may have multiple nodes, devices, and concurrent sessions.

- Model backend settings and credentials are deployment-wide settings for that operator. pirc is not a multi-tenant service: user allowlists and session ownership do not establish isolation between mutually untrusted users, and there is no separate administrator/user role model.
- Compromised gateway or node hosts, malicious processes running as the same OS account, and hostile node operators are outside the protection boundary. Agents always run in an OS sandbox, but it limits what they read, write and reach; it does not make a hostile node or account safe. Storing credentials on the gateway alone does not isolate them from processes that can access the same files or environment (the NixOS module runs the gateway as its own account for that reason).
- Updated same-account nodes and gateways register private directories so new sandboxes hide the other daemons’ state and temporary parents. Existing sandboxes must be restarted after new paths are registered; see [same-account isolation](docs/deploy/sandbox-and-browser.md#same-account-nodes-and-gateway).
- Repository content, web pages, model output, provider errors, and browser input remain untrusted data. A trusted network does not make that content authorization to run commands or change settings.
- The security goals are to prevent unintended exposure and unauthorized access, cross-site requests, and accidental credential disclosure. Authentication, request validation, secret-safe handling, and resource/lifecycle limits still matter on a private network. Multi-user deployment or public exposure requires a new threat-model review.

### Deployment safeguards

The gateway is intended to sit behind a trusted reverse proxy using an Authelia-style forward-auth flow. The private-network assumption does not disable the following safeguards:

- The gateway only accepts identity headers from explicitly configured proxy IP addresses.
- Authenticated user identities, `Host`, and `Origin` are checked against exact allowlists.
- There is no trust-all or unauthenticated production default.
- Nodes authenticate to the gateway with per-node secrets and connect outbound only; they listen on no port.
- Phones running the native app authenticate with device tokens paired from the web **Settings → Devices**. A device token still needs the trusted proxy and an allowed `Host`, and by default expires after 7 days without use, 30 days after pairing, or on revocation. Managing devices or model backends additionally requires a scoped, short-lived management grant approved in the authenticated web UI. Otherwise, it acts as you, including shells on your nodes; revoke a lost phone at once. The proxy must pass these requests past forward auth and strip the identity header (see [device tokens](docs/development/gateway-and-node.md#device-tokens)).
- Workspaces are allowlisted. Each agent runs in a native OS sandbox (bubblewrap on Linux, Seatbelt on macOS, with a filtering proxy); see [Agent sandbox](docs/guides/agent.md#agent-sandbox). A node where the sandbox cannot work starts no agents.
- The web side panel can browse workspace files, show Git changes and history, and open interactive shells in the workspace. Shells run as the node's account, just like the agent's tools, and require holding session control; set `PIRC_TERMINALS=false` on the node to disable them.
- The agent's browser (see [Browser](docs/guides/browser.md)) loads pages with the node account's network access and keeps each workspace's logins in a persistent profile. Taking it over from the side panel requires holding session control; set `PIRC_BROWSER=false` on the node to disable it.
- Keep the gateway on loopback or a private interface reachable only by the trusted proxy. Do not expose it through Tailscale Funnel or the public Internet.

## Requirements

- No Bun, Node, Deno or V8 runtime is shipped or needed by the servers.
- `git`, bubblewrap (`bwrap`) on Linux, and the system `sandbox-exec` on macOS; Chromium/Chrome and optional ffmpeg for browser features.
- Development/build only: [Bun](https://bun.sh) **1.2 or later** for web/tooling (`packageManager` pins 1.4.2), and Rust **1.98.1** with `clippy`/`rustfmt` (`rust-toolchain.toml` and CI pin it; `nix develop` provides the matching tools). The locked PTC dependencies require at least Rust 1.97.
- A model backend, configured on the gateway: a subscription login (Claude Pro/Max, GitHub Copilot, ChatGPT/Codex) or an API-key/custom endpoint from the web **Settings**, and/or `models.json` (see [Model backends](docs/guides/model-backends.md))
- A trusted forward-auth reverse proxy
- Android development only: Flutter/Dart, Android SDK and JDK 17; see [Android build prerequisites](apps/android/README.md#build-and-run). These are not required for the servers or web client.

## Development

```sh
bun install
# Export configuration from .env.example (never source untrusted files).
# Rust does not auto-load .env files. Fill every security allowlist.
# Gateway, chat and coding nodes take separate environments.
bun run dev        # gateway
bun run dev:chat   # optional chat node, with its own node ID/token/state directory
bun run dev:node   # coding node, with PIRC_DAEMON_URL=ws://127.0.0.1:8787
bun run dev:web    # localhost only; add `-- --host 0.0.0.0` to try it from a phone on the LAN
```

The node's first workspace can point to this repository. See the [gateway and node reference](docs/development/gateway-and-node.md) for configuration and API details, and [`apps/web/README.md`](apps/web/README.md) for the client.

## Role-specific executables

```sh
bun run build                  # web bundle plus two native release executables
./target/release/pirc-gateway   # browser API and routing
./target/release/pirc-node chat # pots
./target/release/pirc-node      # coding agents and shells for this machine
```

Build one executable with `cargo build --locked --release -p pirc-gateway` or `-p pirc-node`; build the Web UI with `bun run --filter @pirc/web build`.

SQLite is bundled; the node embeds native QuickJS for PTC, not a general-purpose JS runtime. `pirc-node chat` selects chat, with no environment/argv-name role switch. Internal `agent`, `ptc-guest` and `sandbox-bridge` commands are runtime helpers, not services. OAuth runs in the gateway process.

The Nix gateway includes the static Web UI; the node includes native sandbox/browser drivers and supplies bubblewrap on Linux. Neither ships srt, Playwright's Node package or a JS sidecar. Account separation, filesystem permissions and sandboxing remain the security boundaries.

### Upgrading

Upgrade the gateway and every chat/coding node together. The current tree uses node protocol **15**; older-protocol nodes cannot connect. The `SCHEMA_VERSION` constants in `crates/pirc-gateway/src/db.rs` and `crates/pirc-node/src/store/mod.rs` are the source of truth for database compatibility. Web/native Android recovery and explicit retries are integrated, but the new flow remains gated by `canSubmit: false` pending full client/device and rollout acceptance. Web IndexedDB and Android private draft envelopes are **3**, preserving drafts while refusing older writers. Back up state and configuration first; older executables refuse the newer schemas. See [Upgrades](docs/deploy/upgrades.md) for capability requirements, migration notes and rollback limitations.

Upgrading from the pre-Rust **0.3.x** releases still requires fresh state: re-pair devices, re-login providers and start new sessions rather than reusing the old databases. See [migration and rollback guidance](docs/deploy/upgrades.md).

## Documentation

The native Flutter Android app is in [apps/android](apps/android/README.md); its [remaining work and validation limits](docs/development/historical-records.md#retired-plans-2026-11-24) are tracked separately.

Start with the [documentation index](docs/README.md). Current usage guides and architecture references are separate from [implementation plans](plans/README.md) and historical designs.

- [Agent configuration and sandbox](docs/guides/agent.md), [tools and workflows](docs/guides/tools.md)
- [Model backends and subscription logins](docs/guides/model-backends.md)
- [Session UI](docs/guides/session-ui.md), [browser](docs/guides/browser.md), [schedules and notifications](docs/guides/schedules.md), [pots](docs/guides/pots.md)
- [Architecture references](docs/architecture/README.md), [deployment guides](docs/deploy/README.md)

## Validation

```sh
bun run check
```

`bun run check` validates product versions, generated model/browser assets, formatting, Rust lint/tests, web types/tests and release builds. Android checks run separately; see [Android verification](apps/android/README.md#verification).

It ends with the conformance suite (`crates/pirc-conformance`), which starts the built `pirc-gateway` and `pirc-node` and compares their HTTP and WebSocket behavior with committed snapshots; after an intended change, `bun run conformance:record` re-records them; review the snapshot diff before committing it. The snapshots are Linux's: on other platforms the suite is skipped and recording refused (`scripts/conformance.ts`).

Real-model smoke tests are deliberately separate because they require credentials and incur provider cost. The automated suite drives the real agent against a scripted fake OpenAI/Anthropic SSE server (end to end through gateway inference), and covers subscription logins, refresh and logout with fake OAuth providers, and native provider transports against recorded parity fixtures. The TS-era tests and PTC evaluation tools were removed after the cutover; they run only from a checkout of `2d480d3`, the last TS revision.

## Releases

See [CHANGELOG.md](CHANGELOG.md) for user-facing changes and migrations, and [release policy](docs/development/releasing.md) for version bumps, validation and publishing. `bun run version:check` verifies synchronized product versions and is part of `bun run check`.

## Nix integration

A reusable flake, package, development shell, and NixOS module are available in [`flake.nix`](flake.nix) and [`nix/`](nix/README.md):

```sh
nix develop
nix build .#pirc-gateway
nix build .#pirc-node
```

The NixOS module runs the gateway (`pirc.service`, as `pirc-gateway`) and, by default, a local node (`pirc-node.service`, as `pirc`) under two unprivileged service accounts, and can generate an nginx virtual host wired to an Authelia-compatible `auth_request` endpoint. The model providers (`services.pirc.models`), agent configuration (`services.pirc.agentConfig`), secret management, TLS certificate ownership, workspace permissions, and host names remain explicit inputs rather than unsafe defaults.

## Deployment

Step-by-step deployment guides (topology, gateway and node configuration, reverse proxy, NixOS module, macOS launchd nodes, secrets, upgrades, backups and troubleshooting) are in [`docs/deploy/`](docs/deploy/README.md). Applying them to a host, proxy authorization, and backup/restore drills remain the operator's responsibility: nothing in the repository ships a trust-all default.

## Acknowledgements

pirc started as a web client for [Pi](https://github.com/earendil-works/pi) and now runs its own agent loop, tools, sessions, and protocol. Its native provider implementations were ported from Pi's [pi-ai](https://github.com/earendil-works/pi/tree/main/packages/ai); the pinned package is used only at development time to generate the embedded model catalog. Several built-in features (todo, background tasks, agent teams, observational memory) are ports of Pi extensions, and session titles follow oh-my-pi's title generator.
