# pirc

A private, self-hosted workspace for persistent coding-agent sessions and named agents ("pots"). The servers are two native Rust executables, `pirc-gateway` and `pirc-node`. The clients reach the gateway through a forward-authenticated reverse proxy.

> [!WARNING]
> **pirc 2 is a breaking rewrite, and it is not finished.** The rewrite started on 2026-11-24. Until it is released:
>
> - `main` can fail to build or run, and CI can be red between steps.
> - pirc 2 keeps no data from earlier versions and supports no old clients. It refuses old databases.
> - Parts of this repository still describe or contain the old product. The old parts are deleted milestone by milestone.
>
> For a working version, use the last stable release, [`v0.10.0`](CHANGELOG.md#0100---2026-10-25). The current state and the next steps are in [Open work](plans/README.md) and the [roadmap status table](plans/roadmap.md#status).

## What pirc 2 keeps and what it changes

pirc 2 keeps these parts:

- the topology: one **gateway**, a **chat node**, and one or more **coding nodes**;
- the built-in agent, its tools, and the native OS sandbox;
- the [security model](#security-model) and its deployment safeguards.

pirc 2 changes the product that the user sees:

- **One Flutter client for Android, Web and macOS** ([`apps/app`](apps/app/README.md)). It follows design direction E ([design handoff](docs/design/README.md)). It replaces the Svelte web app ([`apps/web`](apps/web/README.md)) and the current Android UI ([`apps/android`](apps/android/README.md)). These two old clients receive no new work. They are deleted at the Android cutover (M8) and the Web and macOS cutover (M9).
- **Named pots replace the assistant chat.** Each pot is a persistent agent with its own personality, memory, permissions, models and budget. See [pots.md](plans/pots.md).
- **Four tabs.** The Chat tab holds pots and groups of pots. The Work tab holds coding sessions, grouped by project. Activity and Calendar are the other two tabs.
- **New flows only.** First-send is the only way to create a session. The database schemas start again from a new baseline, and no migrations are written.
- **Usage ledger.** pirc records token use and cost for each model request, and pots spend from their own budgets. See [usage.md](plans/usage.md).

## How it works

- The **gateway** is the server that clients talk to. It handles authentication, the session index, routing, and model requests. It never runs agents or tools. See [Model backends](docs/guides/model-backends.md).
- The **chat node** (`pirc-node chat`) hosts the pots.
- A **coding node** (`pirc-node`) runs on each machine that has workspaces. It connects out to the gateway. It runs one agent subprocess for each session (JSONL RPC on stdin and stdout), and the shells of the side panel.

On one machine, run the gateway and a node next to each other. For more than one device, each device runs a node, and all nodes connect to one central gateway over a private VPN. See the [gateway and node reference](docs/development/gateway-and-node.md).

## Repository layout

| Path                                              | Contents                                                                   |
| ------------------------------------------------- | -------------------------------------------------------------------------- |
| [`crates/`](crates)                               | Rust gateway, node, agent, model providers, protocol and conformance suite |
| [`apps/app/`](apps/app/README.md)                 | The new Flutter client (Android, Web, macOS)                               |
| [`packages/`](packages)                           | Dart packages of the new client: transport, UI and native rendering        |
| [`apps/web/`](apps/web/README.md)                 | Old Svelte web client; deleted at M9                                       |
| [`apps/android/`](apps/android/README.md)         | Old Flutter Android client; deleted at M8                                  |
| [`plans/`](plans/README.md)                       | Direction, decisions, roadmap and open work for the rewrite                |
| [`docs/`](docs/README.md)                         | Guides, architecture, deployment and design                                |
| [`nix/`](nix/README.md), [`flake.nix`](flake.nix) | Nix packages, development shell and NixOS module                           |

## Security model

### Threat model

pirc is a **single-user, self-hosted tool for a trusted private network**, such as your own VPN or LAN. The operator, the gateway, the paired nodes and their operating-system accounts belong to one trust domain. One user can have many nodes, devices and concurrent sessions.

- Model backend settings and credentials are settings of the whole deployment. pirc is not a multi-tenant service. User allowlists and session ownership do not isolate users who do not trust each other, and pirc has no separate administrator role.
- The protection boundary does not include a compromised gateway or node host, a malicious process that runs as the same OS account, or a hostile node operator. Agents always run in an OS sandbox. The sandbox limits what an agent can read, write and reach, but it does not make a hostile node or account safe. Credentials that are stored only on the gateway are still visible to processes that can read the same files or environment. For this reason, the NixOS module runs the gateway as its own account.
- When nodes and a gateway run as the same account, they register their private directories, so that new sandboxes hide the state of the other daemons. Restart existing sandboxes after new paths are registered. See [same-account isolation](docs/deploy/sandbox-and-browser.md#same-account-nodes-and-gateway).
- Repository content, web pages, model output, provider errors and browser input are untrusted data. A trusted network does not make that content permission to run commands or change settings.
- The security goals are to prevent unintended exposure, unauthorized access, cross-site requests and accidental disclosure of credentials. Authentication, request validation, careful handling of secrets, and limits on resources still apply on a private network. A multi-user or public deployment needs a new review of the threat model.

### Deployment safeguards

The gateway must run behind a trusted reverse proxy that uses an Authelia-style forward-auth flow. The private-network assumption does not turn off these safeguards:

- The gateway accepts identity headers only from proxy IP addresses that are explicitly configured.
- The gateway checks the authenticated user, `Host` and `Origin` against exact allowlists.
- No production default trusts all requests or allows unauthenticated access.
- Each node authenticates to the gateway with its own secret. Nodes only connect out; they listen on no port.
- Native apps authenticate with device tokens. A device token still needs the trusted proxy and an allowed `Host`. Device tokens expire, and you can revoke them; revoke the token of a lost phone at once. Managing devices or model backends also needs a short-lived management grant that you approve in the authenticated web UI. See [device tokens](docs/development/gateway-and-node.md#device-tokens).
- Workspaces are allowlisted. Each agent runs in a native OS sandbox: bubblewrap on Linux, and Seatbelt on macOS, with a filtering proxy. A node on which the sandbox cannot work starts no agents. See [Agent sandbox](docs/guides/agent.md#agent-sandbox).
- The side panel can open interactive shells in a workspace. Shells run as the node's account, like the agent's tools, and need session control. Set `PIRC_TERMINALS=false` on the node to turn them off.
- The agent's browser uses the network access of the node's account and keeps a persistent login profile for each workspace. Taking control of it needs session control. Set `PIRC_BROWSER=false` on the node to turn it off. See [Browser](docs/guides/browser.md).
- Keep the gateway on loopback or on a private interface that only the trusted proxy can reach. Do not expose it through Tailscale Funnel or the public Internet.

## Requirements

- Runtime: `git`; bubblewrap (`bwrap`) on Linux or the system `sandbox-exec` on macOS; Chromium or Chrome, and optionally ffmpeg, for browser features. The servers need no Bun, Node, Deno or V8 runtime.
- A model backend, configured on the gateway: a subscription login (Claude Pro/Max, GitHub Copilot, ChatGPT/Codex), an API key or custom endpoint, or `models.json`. See [Model backends](docs/guides/model-backends.md).
- A trusted forward-auth reverse proxy.
- Development: Rust **1.98.1** with `clippy` and `rustfmt` (pinned in `rust-toolchain.toml`), and [Bun](https://bun.sh) 1.2 or later for tooling. The Flutter client also needs Flutter and Dart; for Android, the Android SDK and JDK 17. `nix develop` provides the matching versions.

## Development

The servers:

```sh
bun install
# Export the configuration from .env.example. Rust does not load .env files.
# Fill every security allowlist. The gateway, chat node and coding node use separate environments.
bun run dev        # gateway
bun run dev:chat   # chat node, with its own node ID, token and state directory
bun run dev:node   # coding node, with PIRC_DAEMON_URL=ws://127.0.0.1:8787
```

The new Flutter client is in [`apps/app`](apps/app/README.md). Its structure, transport and test rules are in [client.md](plans/client.md). Run Flutter and Dart inside `nix develop`.

Release builds of the servers:

```sh
cargo build --locked --release -p pirc-gateway -p pirc-node
./target/release/pirc-gateway    # client API and routing
./target/release/pirc-node chat  # pots
./target/release/pirc-node       # coding agents and shells on this machine
```

SQLite is bundled. The node embeds QuickJS for programmatic tool calling; this is not a general-purpose JavaScript runtime. OAuth logins run in the gateway process.

## Validation

```sh
bun run check
```

`bun run check` checks product versions, generated assets, formatting, Rust lint and tests, and release builds. It ends with the conformance suite (`crates/pirc-conformance`). This suite starts the built `pirc-gateway` and `pirc-node` and compares their HTTP and WebSocket behavior with committed snapshots. The snapshots are from Linux, so the suite is skipped on other platforms. After an intended change, run `bun run conformance:record` and review the snapshot diff before you commit it.

During the rewrite, each step runs only fast, targeted checks. Full acceptance runs happen when the owner asks for them. See the [working rules](plans/README.md#working-rules).

Tests with real models are separate, because they need credentials and cost money. The automated suite runs the real agent against a scripted fake OpenAI/Anthropic SSE server.

## Nix and deployment

[`flake.nix`](flake.nix) and [`nix/`](nix/README.md) provide packages, a development shell and a NixOS module:

```sh
nix develop
nix build .#pirc-gateway
nix build .#pirc-node
```

The NixOS module runs the gateway and, by default, a local node, as two unprivileged service accounts. It can generate an nginx virtual host that uses an Authelia-compatible `auth_request` endpoint. Model providers, agent configuration, secrets, TLS certificates, workspace permissions and host names are explicit inputs, not unsafe defaults.

The [deployment guides](docs/deploy/README.md) cover topology, configuration, the reverse proxy, the NixOS module, macOS launchd nodes, secrets, backups and troubleshooting. They describe the current servers. pirc 2 has no upgrade path from 0.x: back up your state, then start with new state, pair the devices again and log in to the providers again.

## Documentation

- [Open work](plans/README.md): direction, decisions and the [roadmap](plans/roadmap.md) of the rewrite
- [Documentation index](docs/README.md): [user guides](docs/guides/README.md), [architecture](docs/architecture/README.md), [behavioral contracts](docs/architecture/contracts.md), [deployment](docs/deploy/README.md)
- [Design handoff (direction E)](docs/design/README.md)
- [Changelog](CHANGELOG.md) and [release policy](docs/development/releasing.md)
- [Historical records](docs/development/historical-records.md): plans and designs from before the rewrite

Some guides still describe the 0.x product. The rewrite updates `README.md` and `docs/` for pirc 2 in its last milestone (M11).

## License

pirc is licensed under the [GNU Affero General Public License v3](LICENSE).

## Acknowledgements

pirc started as a web client for [Pi](https://github.com/earendil-works/pi). It now runs its own agent loop, tools, sessions and protocol. Its native provider implementations are ports of Pi's [pi-ai](https://github.com/earendil-works/pi/tree/main/packages/ai). The pinned pi-ai package is used only during development, to generate the embedded model catalog. Several built-in features (todo, background tasks, agent teams) are ports of Pi extensions, and session titles follow the title generator of oh-my-pi.
