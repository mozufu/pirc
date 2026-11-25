# NixOS module

`nixosModules.default` (`nix/module.nix`) runs the gateway and, by default, a local node as two hardened systemd services, and can generate the nginx virtual host. This page walks through a deployment; the option reference is the module itself (`nixos-option services.pirc` or the descriptions in the file), and [`nix/README.md`](../../nix/README.md) covers the flake's other outputs.

## Adding the flake

```nix
{
  inputs.pirc.url = "github:YOUR-ORG/pirc";

  outputs = { nixpkgs, pirc, ... }: {
    nixosConfigurations.homolab = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [ pirc.nixosModules.default ./pirc.nix ];
    };
  };
}
```

A full starting point with nginx is [`nix/example.nix`](../../nix/example.nix). Alternatively apply `pirc.overlays.default` and use `pkgs.pirc-gateway` and `pkgs.pirc-node` in your own service definitions; the module is not required.

## A complete single-host configuration

```nix
{ config, pkgs, ... }:
{
  services.pirc = {
    enable = true;

    allowedUsers = [ "alice@example.com" ];
    allowedOrigins = [ "https://pirc.example.ts.net" ];
    allowedHosts = [ "pirc.example.ts.net" ];
    # listenAddress = "127.0.0.1"; port = 8787; trustedProxies = [ "127.0.0.1" "::1" ];

    # File-managed providers (optional; the web UI can add backends too).
    models = {
      providers.anthropic = {
        api = "anthropic-messages";
        baseUrl = "https://api.anthropic.com";
        apiKeyFile = config.sops.secrets.anthropic-key.path;
        models = [ { id = "claude-sonnet-4-5"; reasoning = true; contextWindow = 200000; } ];
      };
      defaultModel = { provider = "anthropic"; id = "claude-sonnet-4-5"; };
    };

    # Gateway-only secrets: EXA_API_KEY, PIRC_NODE_TOKENS for remote nodes, VAPID keys.
    environmentFile = config.sops.secrets.pirc-env.path;

    # The local node.
    workspaces.pirc = { path = "/srv/src/pirc"; displayName = "pirc"; };
    chat = false;                       # selects pirc-node; true selects pirc-node chat (workspaces must be empty)
    agentConfig = {
      limits.maxTurns = 300;
      features.sessionTitle.model = { provider = "anthropic"; id = "claude-haiku-4-5"; };
      sandbox.network.allowedDomains = [ "api.example.com" ];
    };
    agentPrompt = "Prefer small commits."; # modes that select agents:global
    skills.pdf = ./skills/pdf;
    extraPackages = with pkgs; [ git openssh nodejs bun ripgrep ];
    localNode.environmentFile = config.sops.secrets.pirc-node-env.path;  # e.g. GITHUB_TOKEN=… plus PIRC_AGENT_ENV_ALLOW=GITHUB_TOKEN for the agents

    nginx = {
      enable = true;
      hostName = "pirc.example.ts.net";
      forwardAuthUri = "http://127.0.0.1:9091/api/authz/auth-request";
      deviceTokens = true;              # phones
      exposeNodeEndpoint = true;        # remote nodes
      sslCertificate = "/var/lib/tailscale-certs/pirc.example.ts.net.crt";
      sslCertificateKey = "/var/lib/tailscale-certs/pirc.example.ts.net.key";
    };
  };

  sops.secrets.anthropic-key.owner = "pirc-gateway";
  sops.secrets.pirc-env.owner = "pirc-gateway";
  sops.secrets.pirc-node-env.owner = "pirc";
}
```

Evaluation fails with a message when: `allowedUsers`/`allowedOrigins`/`allowedHosts` is empty; `chat = true` together with `workspaces`; `workspaces` set with `localNode.enable = false`; `agentConfig.providers`/`defaultModel` set (they moved to `models`); nginx enabled without `forwardAuthUri`.

## What the module creates

`gatewayPackage` and `nodePackage` select the two Rust packages. The gateway runs `bin/pirc-gateway`; the local runner runs `bin/pirc-node chat` when `chat = true`, otherwise `bin/pirc-node`. Remove the retired `chatPackage` option. Service names remain `pirc` and `pirc-node`. nginx serves `${gatewayPackage}/share/pirc/web`; the node supplies native sandbox/CDP drivers, with bubblewrap on Linux.

| Item                    | Value                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| ----------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `pirc.service`          | The gateway, user `pirc-gateway` (`gatewayUser`), `WorkingDirectory`/`PIRC_STATE_DIR` = `/var/lib/pirc/daemon`, `EnvironmentFile` = `environmentFile`, `ExecReload` sends `SIGHUP`.                                                                                                                                                                                                                                                                                                                                                                                                     |
| `pirc-node.service`     | The local node, user `pirc` (`user`/`group`, `supplementaryGroups`), `PIRC_STATE_DIR` = `/var/lib/pirc/node`, `HOME` = `/var/lib/pirc`, requires `pirc.service`, `PIRC_DAEMON_URL = ws://127.0.0.1:<port>`.                                                                                                                                                                                                                                                                                                                                                                             |
| Local node token        | Created by a root `ExecStartPre` of the gateway at `/var/lib/pirc/daemon/local-node-token` (0600, gateway-owned), merged into `PIRC_NODE_TOKENS`, handed to the node as the systemd credential `node-token`.                                                                                                                                                                                                                                                                                                                                                                            |
| `/etc/pirc/models.json` | `services.pirc.models` as JSON; a change triggers a reload, not a restart.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| Agent config directory  | A store path with `config.json` (`agentConfig`), `AGENTS.md` (`agentPrompt`) and `skills/` (`skills`), exported as `PIRC_CONFIG_DIR`.                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| State directories       | `/var/lib/pirc` (0711), `/var/lib/pirc/daemon` (0700 gateway), `/var/lib/pirc/node` (0700 node), via tmpfiles.                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| nginx virtual host      | When `nginx.enable`: static web (sent with the [security response headers](reverse-proxy.md#security-response-headers)), `/api/` behind `auth_request`, optional device-token bypass and `/node/connect` (see [Reverse proxy](reverse-proxy.md)).                                                                                                                                                                                                                                                                                                                                       |
| Proxy shared secret     | When `nginx.enable` and `nginx.proxySecret` (default): `pirc-proxy-secret.service` (root, oneshot, before `pirc` and `nginx`) creates `/var/lib/pirc/daemon/proxy-secret` once and writes the nginx header snippet to `/run/pirc-nginx` (0750 root:nginx). The gateway gets it as `PIRC_PROXY_SECRET`; local processes connecting to the gateway port can no longer pose as nginx. Never in the store. Turning `nginx.proxySecret` off sets `PIRC_PROXY_SECRET_REQUIRED=false`; without the module's nginx, supply `PIRC_PROXY_SECRET` through the environment file for your own proxy. |

Environment derived from options: `PIRC_TIMEZONE` from `timeZone` (defaults to `time.timeZone`), `PIRC_TERMINALS` from `terminals`, `PIRC_BROWSER*` from `browser.*`. The sandbox has no switch (`sandbox.enable` was removed). `environment` adds non-secret variables to **both** services.

## Hardening and its consequences

Both units run with `NoNewPrivileges`, `PrivateTmp`, `PrivateDevices`, `ProtectHome`, `ProtectSystem=strict`, `ProtectKernelModules`, `ProtectControlGroups`, `RestrictSUIDSGID`, `LockPersonality`, an empty `CapabilityBoundingSet`, `RestrictRealtime`, `RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK`, `UMask=0077`, `Restart=on-failure`. The gateway also gets `ProtectKernelTunables`, `SystemCallFilter=@system-service`, `SystemCallArchitectures=native`, `ProtectProc=invisible` and `RestrictNamespaces`; the node does not, because bubblewrap mounts, creates namespaces and mounts its own `/proc`, and agents and terminals run your tools. `ProtectKernelTunables` in particular puts read-only mounts inside `/proc`, after which the kernel refuses bubblewrap's new `/proc` and no agent starts. `MemoryDenyWriteExecute` stays off for Chromium and user tools that may use JIT memory (an `apiKeyCommand` on Node.js too).

- `ProtectHome=true`: workspaces under `/home` are invisible. Put repositories under `/srv` (or override the hardening in your host config knowingly). Only the node service gets `ReadWritePaths` for the configured workspace paths.
- Web-added workspaces must be inside the node's home, which is `/var/lib/pirc`; use `services.pirc.workspaces` for anything else.
- The node account needs the Git/SSH credentials the agents should have, and nothing more. Give it `supplementaryGroups` rather than widening file modes.
- The sandbox needs unprivileged user namespaces (NixOS default: allowed). Whether bubblewrap works under this unit hardening on a given kernel is something to confirm on the host: the node log says `agent sandbox ready`, and otherwise no agent starts. In an LXC container (OrbStack, Incus) `PrivateDevices` also hides the container's `/dev/.lxc/proc`, with the same result; give the node `BindPaths=/dev/.lxc/proc` there.
- Tools the agent needs (`nix`, `bun`, compilers) go in `extraPackages`; `PATH` is otherwise minimal. `apiKeyCommand` runs on the gateway, whose `PATH` has no shell: name programs by absolute path (`"${pkgs.bash}/bin/sh"`, not `"sh"`), or the gateway refuses to start. The node's `PATH` has `bash`, which the `bash` tool uses where `/bin/bash` is missing.

## Remote nodes

The gateway host can serve nodes elsewhere:

1. In `environmentFile`: `PIRC_NODE_TOKENS={"laptop":"<secret>"}` (the local node's entry is merged in automatically).
2. `nginx.exposeNodeEndpoint = true` (or the equivalent route on your own proxy).
3. On the remote machine, run `pirc-node` (or `pirc-node chat` for the chat node) with `PIRC_NODE_ID=laptop`, the same secret, and `PIRC_DAEMON_URL=wss://pirc.example.ts.net` ([Node](node.md), [macOS node](macos-node.md)).

`localNode.enable = false` turns the host into a routing-only gateway. `localNode.id` defaults to `networking.hostName`.

## Day-to-day

```sh
systemctl status pirc pirc-node
journalctl -u pirc -u pirc-node -f
systemctl reload pirc            # re-read /etc/pirc/models.json (also automatic on switch)
sudo -u pirc-gateway ls -la /var/lib/pirc/daemon
```

## Upgrading the module

- Versions before the account split ran both services as `pirc`. On the first switch afterwards the daemon directory is chowned to `pirc-gateway` by tmpfiles and the old token at `/var/lib/pirc/local-node-token` is moved. Make `apiKeyFile` targets readable by `pirc-gateway` **before** switching, or the gateway fails to start.
- Replace the removed `services.pirc.package` with `gatewayPackage` and/or `nodePackage` overrides. The overlay no longer provides `pkgs.pirc`; use the corresponding role package. Remove the old role environment variable from custom environment files and commands; `chat` now adds the node subcommand. See [executable migration](upgrades.md).
- `hostId` was renamed to `localNode.id`; `piPackage`, `piArgs` and `runnerLimit` were removed (evaluation tells you).
- Bumping the flake input upgrades every co-located component together; remote nodes must be upgraded in the same window when the node protocol version changed ([Upgrades](upgrades.md)).

## Updating `nodeModulesHash`

After `bun.lock` changes, the fixed-output derivation's hash in `nix/web.nix` must be refreshed: set `nodeModulesHash = lib.fakeHash`, run `nix build .#pirc-gateway.web.nodeModules`, and copy the reported hash. One hash covers every platform.

After `Cargo.lock` changes, refresh `cargoHash` in `nix/package.nix` by building both native packages. For 0.3.0 upgrades, choose a new `stateDirectory`; see [fresh-start migration](upgrades.md).
