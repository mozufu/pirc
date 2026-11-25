# Topology

## Processes

Two native executables implement three roles; chat uses an explicit subcommand:

| Executable       | Runs on                              | Listens on                                                  | Does                                                                                                                                |
| ---------------- | ------------------------------------ | ----------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| `pirc-gateway`   | one always-on host                   | `PIRC_HOST:PIRC_PORT` (default `127.0.0.1:8787`), HTTP + WS | Authenticates browsers and phones, indexes sessions, routes requests, runs **all model requests**, keeps memory, schedules and push |
| `pirc-node chat` | at most one always-on host           | nothing (connects out over one WebSocket)                   | Hosts pots, runs agents and their tools; owns pot transcripts                                                                          |
| `pirc-node`      | every machine with coding workspaces | nothing (connects out over one WebSocket)                   | Runs coding agents, side-panel shells, file/Git inspection, uploads and the agents' browser; owns session transcripts               |

Chat and coding roles share the node executable and agent implementation. Their internal worker commands are not independently deployed services:

| Command                 | Available on     | Purpose                                                          |
| ----------------------- | ---------------- | ---------------------------------------------------------------- |
| `agent`                 | `pirc-node`      | Agent loop over JSONL RPC, always inside the native OS sandbox   |
| `ptc-guest`             | `pirc-node`      | One PTC script in native QuickJS (empty environment, IPC only)   |
| `sandbox-bridge`        | `pirc-node`      | Internal Linux sandbox socket/network helper                     |
| `version` / `--version` | both executables | Prints the version; `help` / `--help` / `-h` prints public usage |

The Nix gateway package includes the Web UI, but not sandbox/browser runtime. The node includes native sandbox/CDP drivers, but not the Web UI; OAuth runs in the gateway process. Keep every role on the same release/protocol version. The executable split is **not privacy isolation**: OS accounts, filesystem permissions and sandboxing define the protection boundaries.

The gateway never runs agents, shells or tools, and never learns real workspace paths. A node never listens on a port; agents reach their node through a Unix socket in the node's state directory.

## Who talks to whom

```
browser ──https──▶ reverse proxy ──forward auth──▶ static web bundle
                        │                    └───▶ pirc-gateway  /api/…      (identity header set by the proxy)
phone app ──https──▶    │  Bearer pirc_dev_… ────▶ pirc-gateway  /api/…      (no forward auth, identity header stripped)
                        └─ /node/connect ◀──wss── pirc-node (machine A)      (no forward auth, PIRC_NODE_TOKEN)
                                          ◀──wss── pirc-node (machine B)
                                          ◀──ws─── pirc-node chat (always-on host, here loopback)

pirc-node ──stdio JSONL──▶ pirc-node agent ──unix socket──▶ pirc-node ──node link──▶ gateway ──▶ model provider
pirc-node chat ──stdio JSONL──▶ pirc-node agent ──unix socket──▶ pirc-node chat ──node link──▶ gateway
```

- Browsers and phones only ever reach the gateway, and only through the proxy.
- Nodes connect **out** to `PIRC_DAEMON_URL`. Off loopback the link must be `wss://`; the proxy passes `/node/connect` through without forward auth.
- Model providers are reached from the gateway only. A provider that listens on a node's `localhost` is unreachable; put it where the gateway can reach it.
- Web search (`EXA_API_KEY`) runs on the gateway; the agents' browser runs on the node.

## Supported layouts

### Single host

Gateway, one node, the proxy and the web bundle on the same machine. The node uses `PIRC_DAEMON_URL=ws://127.0.0.1:8787` (plain `ws://` is accepted on loopback). This is what the [NixOS module](nixos.md) sets up by default.

### Central gateway, several nodes

A small always-on host runs the gateway (and optionally a local node); workstations and laptops run nodes that connect over a VPN or tailnet. Each node has its own token in `PIRC_NODE_TOKENS`. Sessions are permanently assigned to the node that owns their workspace; a node that is offline makes its sessions answer `503` until it returns.

### Routing-only gateway

The gateway host has no workspaces (`services.pirc.localNode.enable = false`, or simply no node there). All work happens on remote nodes. The gateway still needs at least one entry in `PIRC_NODE_TOKENS`.

### The chat node

Run at most one `pirc-node chat` process (NixOS: `services.pirc.chat = true` selects it for the local runner). It hosts the `pots` workspace and each pot's own session in directories it manages under its state directory, and hosts **nothing else**: `PIRC_WORKSPACES` must be empty there and the web refuses to add directory workspaces to it. Pick an always-on machine, usually the gateway host's local node. Without a chat node, pots are unavailable.

## Where state lives

| Data                                                                       | Process   | Location                                                                    |
| -------------------------------------------------------------------------- | --------- | --------------------------------------------------------------------------- |
| Session index, control leases, command outcomes, device tokens             | gateway   | `$PIRC_STATE_DIR/gateway.sqlite`                                            |
| Assistant memory, schedules, push subscriptions, workspace caps | gateway   | same database                                                               |
| Web-managed model backends and subscription logins                         | gateway   | `$PIRC_STATE_DIR/backends/settings.json` (0600)                             |
| VAPID key pair for push (unless given by environment)                      | gateway   | `$PIRC_STATE_DIR/vapid.json`                                                |
| Session transcripts (the conversation source of truth), runs, interactions | node      | `$PIRC_STATE_DIR/sessions/<id>/`, `gateway.sqlite`                          |
| Uploads                                                                    | node      | `$PIRC_STATE_DIR/uploads/`, and `<workspace>/.pirc/uploads/` for non-images |
| Workspace memory ledgers (mirrored to the gateway without paths)           | node      | `$PIRC_STATE_DIR/workspace-memory/`                                         |
| Pots workspace and pot sessions                                            | chat node | `$PIRC_STATE_DIR/chat/pots/`                                                |
| Browser profiles (logins)                                                  | node      | `$PIRC_STATE_DIR/browser/`                                                  |
| Agent config, global `AGENTS.md`, skills                                   | node      | `$PIRC_CONFIG_DIR` (default `~/.config/.pirc`)                              |
| Node ↔ agent inference socket (random per start)                          | node      | `$PIRC_STATE_DIR/i-*/socket` (0600)                                         |

Both state directories are created with mode `0700`. See [Backup and recovery](backup-and-recovery.md) for what to copy.

## Ports and addresses to decide up front

- The gateway's listen address and port (`PIRC_HOST`, `PIRC_PORT`).
- The proxy's peer address as the gateway sees it (`PIRC_TRUSTED_PROXIES`): `127.0.0.1` and `::1` when co-located, else the proxy's private IP. Exact match, no CIDR.
- The public host name(s) and origin(s) browsers use (`PIRC_ALLOWED_HOSTS`, `PIRC_ALLOWED_ORIGINS`).
- The `wss://` URL nodes use to reach `/node/connect` (usually the same host name).
