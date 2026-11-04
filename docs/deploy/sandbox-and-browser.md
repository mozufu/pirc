# Sandbox and browser (per node)

Both are node-side concerns: the node starts every agent inside an OS sandbox, and refuses to start one when it cannot; it also hands its agents a Chromium it owns. Neither involves the gateway.

## The native agent sandbox

Each `pirc-node agent` process (for either role) runs under the native sandbox: Seatbelt on macOS, bubblewrap on Linux, with a filtering HTTP/SOCKS5 network proxy on both. The filesystem algorithm was ported from srt 0.0.78 with additional protections. The Linux agent sandbox's seccomp filter only refuses vsock sockets (outside every network namespace: on WSL 2 the Windows host listens there) and io_uring (whose rings make sockets no filter sees), and kills 32-bit x86 programs, whose system calls it cannot check; Unix sockets are filtered by hiding their files (below). The separate PTC guest does use a seccomp allowlist and resource limits. Everything the agent starts (tools, `bash`, `ptc` scripts, hooks, teammates, subagents) is inside. A `ptc` script's interpreter process gets an empty environment and talks only to its agent. Side-panel terminals are **not**. The node closes every file descriptor it was started with besides stdin, stdout and stderr (a terminal's PTY left open by whatever launched it would otherwise reach the agent, and a command written to it runs outside the sandbox), and the in-sandbox bridge closes any other one again before it runs the agent.

### Host dependencies

Neither role ships srt, Node or socat. What the host must provide:

| Platform            | Needs                                                                                                                                        |
| ------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| Nix package / NixOS | The node wrapper supplies bubblewrap on Linux; no JS runtime.                                                                                |
| Other Linux         | `bubblewrap` from the distribution and unprivileged user namespaces (Ubuntu 24.04: `sysctl kernel.apparmor_restrict_unprivileged_userns=0`). |
| macOS               | Nothing: Seatbelt (`sandbox-exec`) is part of macOS.                                                                                         |

The sandbox is mandatory and cannot be turned off. The node probes the native backend at start-up (the log says `agent sandbox ready` or why not) and again before starting an agent while the last probe failed. When the native backend cannot sandbox on the host, **no agent starts**: sending a prompt fails with the reason. `PIRC_SANDBOX=off` makes the node refuse to start, and `"enabled"` in the `sandbox` settings is ignored with a warning.

| Variable           | Default        | Meaning                                                                      |
| ------------------ | -------------- | ---------------------------------------------------------------------------- |
| `PIRC_SANDBOX_SRT` | unset (native) | Development-only external srt-compatible stand-in; do not set in production. |

### Same-account nodes and gateway

Updated nodes and gateways register their private paths in `~/.local/pirc-node/nodes/`. Each new agent or read-only panel command reads a fresh account-wide snapshot and hides the registered state, session stores, uploads, browser profiles, workspace-memory directories, database directories and node temporary parents. Configured path overrides are included. A session retains its own read exceptions; the builtin agent saves private state through the node as described below. Distinct node IDs and state directories are still required; this registry does not make shared stores safe.

The registry root is already a sensitive home path. Directories are private (0700), records/lock files are 0600, writes are atomic under an OS file lock, and unsafe links, ownership, permissions or malformed records refuse session startup. Registry components cannot be symlinks; an existing `.local` must be owned by the account and not writable by other accounts. File names use a hash of the daemon kind, ID and state path, so the same node ID in different installations cannot overwrite a record. Records contain paths, never tokens.

Records persist across stops and crashes because stopped nodes' data remains sensitive. Registered empty `pirc-n-*` parents also remain, avoiding shutdown-time deletion during another sandbox's mount planning; individual session temp contents are removed as usual. Remove obsolete records/empty parents only after stopping all account-owned pirc processes and sandboxes. Do not remove the registry during operation. Missing registered paths are handled by the backend's normal missing-path policy.

**Snapshot limit:** a sandbox already running when another daemon first registers a new path does not gain that deny. Upgrade/restart every same-account gateway and node, then restart their existing sessions. Older executables do not register themselves; until all are upgraded, use explicit `sandbox.filesystem.denyRead`/`denyWrite` for their state and temp directories or separate OS accounts. This does not isolate unrestricted same-account processes, approved unsandboxed commands, or arbitrary external credential files; protect environment files and out-of-state `models.json` yourself.

### What the policy is

- **Reads**: everywhere, except credential stores under the account's home (`~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.config/gh`, `~/.netrc`, `~/.config/sops`, keychains, browser profiles, …; the full list is `SENSITIVE_HOME_PATHS` in `crates/pirc-policy/src/lib.rs`) and registered pirc state belonging to this OS account (`PIRC_STATE_DIR`, minus the session's own directory and its workspace's memory ledger; the systemd credentials directory on NixOS).
- **Writes**: the workspace (or the chat's directory), the node config's `allowedPaths`, the session's temporary directory and `/tmp`. Host build caches (`~/.cache`, `~/.npm`, `~/.cargo/registry`, `~/go/pkg/mod`, `~/.gradle/caches`, …) are read-only even inside a broad writable home. Cache environment variables point to session-private temporary paths; cold caches may require downloads. `.pirc/`, existing repositories' `.git/hooks` and `.git/config`, and shell start-up files stay read-only. A workspace with no `.git` may run `git init`; new repository guards take effect on the next session start.
- **Network**: only through the sandbox's proxy, to `DEFAULT_ALLOWED_DOMAINS` (GitHub, GitLab, Codeberg, npm, PyPI, crates.io, Go proxy, Nix caches, Maven, RubyGems, …) plus what you add. A host the task needs and the list lacks makes the agent call `sandbox_allow_domains`; the **node** asks you in the session, and an approved host stays allowed for that session.
- **Escape hatch**: for a `nix build`, a system change, or git over SSH that is not [set up for the sandbox](#git-and-the-github-cli), the agent calls `unsandboxed_bash`. The node asks you first, then runs the command as the node account, without the node's own secrets.

Both approvals are the node's own dialogs; nothing the agent prints counts as your answer. Teammates' and subagents' requests are relayed through their parent and say who is asking.

### Source fences and native proxy retirement

The native Linux/macOS filtering proxy belongs to its session. Accepted source
transition fences close registration and application I/O admission across the
Node commit, then retire HTTP, CONNECT and SOCKS connections. Peer sessions keep
their own proxies. Ordinary cleanup retires its own prepared proxy; a source
fence retires all that source's instances. Startup restores barriers from retained
fences, so a late prepare cannot revive them after reconnect or restart.

Stop waits for listener/connection task closure and already-admitted resolver
work. System `getaddrinfo` cannot be forcibly canceled by dropping its async
waiter. Missing closure evidence remains `network_stop_unconfirmed`, with source
execution blocked. A known rollback preserves the prior proxy; an uncertain
acceptance outcome is not permission to reopen it. Traffic already submitted to
the kernel or another service cannot be recalled.

This proof covers the native proxy only. External `PIRC_SANDBOX_SRT` wrappers
report unsupported; direct/Unix-socket/delegated paths and full process/descriptor
containment still need their own evidence. Native proxy counts alone never mean
`revocationConfirmed` or `targetInstalled`; public environment switching remains
disabled until all required resource and installation checks are complete.

### Private process channels and state

On Linux the builtin agent and PTC guest set `PR_SET_DUMPABLE=0` before reading private configuration, and set no-new-privileges. Same-user tool processes without `CAP_SYS_PTRACE` cannot reopen their `/proc/<pid>/fd` pipes or inspect their memory. This does not isolate signals between processes of the same UID or protect a custom agent executable that omits this hardening.

The builtin agent's session directory (including transcripts, context snapshots and team metadata) and assigned workspace-memory ledger are read-only inside the sandbox. The node saves them through a separate, random per-run persistence capability sent only over the private configure pipe, never through tool environment variables or files. The capability cannot call inference APIs and is revoked when its runner exits. Writes are limited to that session tree and append-only access to its pre-opened ledger; paths traverse directory descriptors without following symlinks, and linked files are refused. Team children inherit the private capability through their configure pipes. Temporary command output remains untrusted tool data. Memory remains provenance-labelled untrusted content, not an authorization source.

Custom `PIRC_AGENT_COMMAND` runtimes remain responsible for their own process channels and state custody; the builtin configure/persistence protocol is selected by the `agent` entry argument. Development SRT stand-ins are not covered by the native backend's full guarantees. Restart existing sessions after updating.

The credential deny list now also covers package-manager credentials (`.npmrc`, `.yarnrc.yml`, pip/Bundler config), container auth, OpenCode auth, remote VS Code state, and Chrome for Testing profiles. Private package credentials require an intentional `allowRead` exception or an explicitly provisioned environment credential. On WSL, standard `/mnt/<drive>/Users` trees are hidden by default; an explicitly selected workspace there is reopened. Custom Windows mount locations need explicit `denyRead`. Reads outside protected paths remain permitted: this is not a filesystem read allowlist.

### Tuning it

In the node's `$PIRC_CONFIG_DIR/config.json` (never a project's `.pirc/config.json`):

```json
{
  "sandbox": {
    "network": {
      "defaultDomains": true,
      "allowedDomains": ["api.example.com", "*.internal.example.org", "127.0.0.1:8080"],
      "deniedDomains": [],
      "allowLocalBinding": true,
      "allowUnixSockets": []
    },
    "filesystem": {
      "denyRead": ["~/.local/pirc-node"],
      "allowRead": [],
      "allowWrite": [],
      "denyWrite": [],
      "allowGitConfig": false
    }
  }
}
```

- Domains: a host, a `*.` wildcard, `localhost`, or an IPv4 address, each with an optional `:port`. `deniedDomains` wins.
- `allowLocalBinding` lets dev servers listen on localhost.
- `allowUnixSockets`: extra sockets the agent may reach, e.g. an `ssh-agent` or a container engine. On macOS the agent can connect only to these (and the node's own). On Linux seccomp cannot filter sockets by path, so the native (bubblewrap) backend hides them instead: every Unix socket bound on the host when the session starts (as listed in `/proc/net/unix`; a node that cannot read it refuses to start sessions) is hidden except the node's inference socket, the Nix daemon's (`/nix/var/nix/daemon-socket/socket`, open by default so builds work) and the ones listed here, which stay reachable even inside a hidden directory such as `/tmp/ssh-*`. The sockets that hand out the host (Docker, containerd, Podman, libvirt, LXD/Incus, the D-Bus system bus, systemd, the user's bus, gpg and keyring agents, `SSH_AUTH_SOCK`; `LINUX_HOST_SOCKETS` in `crates/pirc-policy/src/session.rs`) are hidden by name too, unless listed here. On WSL the interop directory `/run/WSL` is hidden whole, sockets bound after the session started included: through one, running a Windows `.exe` starts it on Windows, outside the sandbox. Any other socket bound after the session started, bound in another network namespace (a container's) or by a relative path stays reachable. A socket that disappears in the moment between planning a session and starting it fails that start, or leaves an empty file in its place under `/tmp`. The development `PIRC_SANDBOX_SRT` backend still allows every socket. The Nix daemon fetches what a client asks for past the proxy: in `auto` mode such commands go through the classifier, in `full-access` nothing stops them. Do not put the node account in the `docker` group: a socket it can reach that the sandbox misses is a way out.
- `denyRead` **must** include the directory holding the node's environment file (the one with `PIRC_NODE_TOKEN`) whenever that file is outside `PIRC_STATE_DIR`. On NixOS the token arrives as a systemd credential and the module handles it.
- `allowRead` re-opens a denied path; `denyWrite` closes a writable one. `allowGitConfig` lets `git remote add` write `.git/config` (and with it hooks paths), off by default.
- An invalid `sandbox` object leaves the defaults in force and shows a warning in every session.
- Credential stores and the node's own state stay unwritable even inside a writable path (a workspace holding `PIRC_STATE_DIR`, `~` in `allowedPaths`). A workspace that contains, or sits inside, the node's state or a credential store cannot be added.

### Git and the GitHub CLI

Without setup, this is what works inside the sandbox:

| What                              | Result         | Why                                                                                                                                                                                                                             |
| --------------------------------- | -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| git over HTTPS, public repository | Works          | Goes through the sandbox's proxy; `github.com` is in the default domains.                                                                                                                                                       |
| git over HTTPS, private or push   | No credentials | `~/.git-credentials`, `~/.netrc` and the keychain are unreadable, and `GH_TOKEN`/`GITHUB_TOKEN` are not passed on ([Node](node.md#agent-process)).                                                                              |
| `gh`                              | Does not start | `~/.config/gh` is unreadable. If you provide a token and writable config directory, its TLS check may still hit the sandbox's blocked macOS trust service (`x509: OSStatus -26276`).                                            |
| git over SSH                      | Fails          | `~/.ssh` is unreadable. On macOS, the sandbox's own `GIT_SSH_COMMAND` (`nc -X 5`) cannot send the credentials its proxy requires: `This proxy requires authentication, and this client did not offer an authentication method`. |

So the agent falls back to `unsandboxed_bash`, and you approve every push. Two setups make it work inside the sandbox: [HTTPS with a token](#https-with-a-token) (recommended) or [SSH with a dedicated key](#ssh-with-a-dedicated-key). Both are `env` entries in the node's `$PIRC_CONFIG_DIR/config.json`, which the agent adds to `bash` and `background_task` (also when called from a `ptc` script), hooks and teammates (not to `unsandboxed_bash`, which runs with the node account's own setup). They apply from the next agent start. Values are literal strings: `~` is not expanded there, except where the SSH command line below expands it itself.

Either way the agent holds the credential: reads are open, so it can read it, and it can use it for everything the credential allows on an allowed host. Use the narrowest credential: a fine-grained personal access token, or deploy keys, limited to the repositories the agent works on.

The examples below originated with srt 0.0.78. Native sandbox coverage includes Linux and macOS; Linux git-over-SSH uses the node's authenticated `sandbox-bridge connect` helper, not socat. macOS retains the `nc -X 5` authentication limitation.

#### HTTPS with a token

```json
{
  "sandbox": { "filesystem": { "allowWrite": ["~/.local/share/pirc-sandbox/gh"] } },
  "env": {
    "GH_TOKEN": "github_pat_…",
    "GH_CONFIG_DIR": "/Users/you/.local/share/pirc-sandbox/gh",
    "SSL_CERT_FILE": "/path/to/updated-ca-bundle.pem",
    "GIT_CONFIG_COUNT": "3",
    "GIT_CONFIG_KEY_0": "credential.helper",
    "GIT_CONFIG_VALUE_0": "",
    "GIT_CONFIG_KEY_1": "credential.https://github.com.helper",
    "GIT_CONFIG_VALUE_1": "!gh auth git-credential",
    "GIT_CONFIG_KEY_2": "url.https://github.com/.insteadOf",
    "GIT_CONFIG_VALUE_2": "git@github.com:"
  }
}
```

- `GH_TOKEN`: `gh` uses it instead of `~/.config/gh/hosts.yml`. For a fine-grained token: Contents read/write to push, Pull requests read/write for `gh pr`, Metadata read. To keep it out of `config.json`, put it in the node's environment instead and name it in `PIRC_AGENT_ENV_ALLOW=GH_TOKEN` ([Node](node.md#agent-process)).
- `GH_CONFIG_DIR`: the absolute path (with your home in place of `/Users/you`) of a directory the sandbox may write, outside `~/.config/gh`. It may be empty; create it once (`mkdir -p ~/.local/share/pirc-sandbox/gh`).
- `SSL_CERT_FILE` (for `gh` where its Go system-root loader honors it): point this to a maintained, current CA bundle that the sandbox can read. For example, use your package manager's CA bundle and verify its actual path and update level; do not assume macOS's `/etc/ssl/cert.pem` has current distrust updates. Go clients can choose different trust paths, so this variable does not force every Go program or other TLS client to bypass its platform verifier. See the [TLS deployment note](upgrades.md#tls-trust-update-october-2026).
- `GIT_CONFIG_*`: git configuration from the environment, so your `~/.gitconfig` (read-only in the sandbox, and shared with you) stays unchanged.
  - Key 0 clears inherited credential helpers. For example, Nix's git enables `osxkeychain`, which cannot reach the keychain and prints `failed to store: -60008`.
  - Key 1 gives git the same token through `gh`.
  - Key 2 rewrites SSH-style GitHub remotes to HTTPS, so existing clones push without `git remote set-url`; that command needs `.git/config`, which is read-only by default.
  - `GIT_CONFIG_COUNT` must equal the number of keys.

Check from a session: `gh auth status`, then `git ls-remote` on a private repository.

#### SSH with a dedicated key

As the node account, outside the sandbox (a side-panel terminal works), with a pirc checkout at hand:

```sh
mkdir -p ~/.local/pirc-ssh ~/.local/share/pirc-sandbox/ssh
chmod 700 ~/.local/pirc-ssh
ssh-keygen -t ed25519 -N '' -C pirc-agent -f ~/.local/pirc-ssh/id_ed25519
cp scripts/sandbox-ssh-proxy.py ~/.local/pirc-ssh/
```

Add `~/.local/pirc-ssh/id_ed25519.pub` to each repository as a deploy key with write access. GitHub accepts a key as a deploy key on one repository only; for several repositories, use a separate machine account. Then:

```json
{
  "sandbox": { "filesystem": { "allowWrite": ["~/.local/share/pirc-sandbox/ssh"] } },
  "env": {
    "GIT_SSH_COMMAND": "ssh -F /dev/null -o ControlMaster=no -o ControlPath=none -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=~/.local/share/pirc-sandbox/ssh/known_hosts -i ~/.local/pirc-ssh/id_ed25519 -o ProxyCommand='python3 ~/.local/pirc-ssh/sandbox-ssh-proxy.py %h %p'"
  }
}
```

- This replaces the `GIT_SSH_COMMAND` the sandbox sets. `ssh` itself only gets these options through git; run it the same way if you need it directly.
- `-F /dev/null`: `~/.ssh/config` is unreadable, so every option is given here. Connection sharing stays off, as the sandbox sets it, because its socket could not be created.
- `UserKnownHostsFile` must be writable; `accept-new` records GitHub's host key on first use. To pin it beforehand, write GitHub's published keys there.
- [`scripts/sandbox-ssh-proxy.py`](../../scripts/sandbox-ssh-proxy.py) does what the sandbox's `nc -X 5` was meant to do, with the per-session credentials the sandbox puts in `$ALL_PROXY`. The proxy still applies the domain allowlist: `github.com` without a port allows port 22, while hosts outside the list are refused. The script relies on those details of the sandbox proxy, so check it again after a pirc upgrade changes them.
- An `ssh-agent` instead of a key file: add its socket to `sandbox.network.allowUnixSockets`, put `SSH_AUTH_SOCK` in `env`, and drop `-i` and `IdentitiesOnly`. Agents can then use every key loaded in it. Not tested.
- Linux: the native `GIT_SSH_COMMAND` authenticates with `pirc-node sandbox-bridge connect`, but `~/.ssh` is still unreadable, so the same setup applies. Not tested.
- `gh` still needs the token setup; to use SSH for git and `gh` for the API, keep `GH_TOKEN`, `GH_CONFIG_DIR` and the maintained-bundle `SSL_CERT_FILE` setting from it and leave out `GIT_CONFIG_*`.

### What it does not cover

On Linux, a host-side atomic replacement of a protected file (for example `git config` rewriting `.git/config`, or an editor saving `.env`) can detach its protection in a running sandbox. Stop affected agents before making such replacements and start fresh sandboxes afterwards. This is an accepted limitation, not prevented by the agent-side rename protections. See [S10 and other accepted limits](../architecture/security-decisions.md#s10-host-replacement-of-linux-protected-paths).

`web_fetch`, the `browser_*` tools and `web_search` run in the node's browser or on the gateway, outside the sandbox. A hostile node account or host is out of scope; the sandbox limits an agent, it does not make the machine safe from the person who configured it.

## The agents' browser

A node gives its agents one Chromium per workspace through its native CDP pipe driver, with a persistent profile under `$PIRC_STATE_DIR/browser/` (a login made once serves every session in that workspace). The web and Android side panels show a live screencast, let you take over, and record videos to `<workspace>/.pirc/recordings/`.

Chromium runs as the node account, outside the agents' bubblewrap or Seatbelt sandbox, and is started with `--no-sandbox`, so Chromium's own renderer sandbox is off too, on every platform. Its private-host filtering (`PIRC_BROWSER_ALLOW_PRIVATE` below) limits where it goes; it is not process isolation. A page that exploits the browser runs with the node account's rights, so run the node under an account that holds nothing else.

| Variable                    | Default                                                     | Meaning                                                      |
| --------------------------- | ----------------------------------------------------------- | ------------------------------------------------------------ |
| `PIRC_BROWSER`              | `true`                                                      | Enable the browser (unavailable when none is found).         |
| `PIRC_BROWSER_EXECUTABLE`   | `chromium`/`google-chrome`… on `PATH`, else `/Applications` | Chromium or Chrome executable.                               |
| `PIRC_FFMPEG`               | `ffmpeg`                                                    | ffmpeg with libvpx, for recordings.                          |
| `PIRC_BROWSER_VIEWPORT`     | `1280x800`                                                  | Viewport.                                                    |
| `PIRC_BROWSER_IDLE_MS`      | 30 min                                                      | Idle time before a session's tabs close (the profile stays). |
| `PIRC_BROWSER_PROFILES_DIR` | `$PIRC_STATE_DIR/browser`                                   | Profile location.                                            |

| `PIRC_BROWSER_ALLOW_PRIVATE` | — | Private/local hosts the browser may reach anyway: host names, `*.suffix`, IPs, CIDR ranges, or `*` for all. |
| `PIRC_BROWSER_BLOCK_HOSTS` | — | The gateway's public host names (e.g. its `PIRC_ALLOWED_HOSTS`), refused like the `PIRC_DAEMON_URL` host. |

- Install Chromium (or Chrome) and ffmpeg on the node. The NixOS module does this through `services.pirc.browser.{enable,package,ffmpeg}` (defaults `pkgs.chromium`, `pkgs.ffmpeg-headless`).
- Pages use the node account's network access and the profile's logins. Before navigation and for HTTP requests intercepted by CDP `Fetch`, including redirect hops, the host guard refuses loopback, RFC 1918, carrier-grade NAT (`100.64.0.0/10`), link-local (including `169.254.169.254` cloud metadata), IPv6 unique-local/link-local, multicast or reserved addresses, `localhost`/`.local`/`.internal`/`.home.arpa` names, and the gateway host (from `PIRC_DAEMON_URL`, plus `PIRC_BROWSER_BLOCK_HOSTS`: set it to the gateway's public host names when the node connects through a different address). Allow exceptions with `PIRC_BROWSER_ALLOW_PRIVATE` (e.g. `localhost,192.168.1.0/24` for a dev server or NAS); the gateway host stays blocked even with `*` unless named explicitly.
- **This is not a public-host-only network boundary.** WebSockets are checked by a page-world mock that hostile JavaScript can bypass; worker WebSockets are unguarded. Preconnect, WebRTC STUN/TURN and WebTransport are outside `Fetch` interception, and Chromium's independent DNS resolution leaves a rebinding gap. Service-worker registration is blocked only by a bypassable script; workers that run still have their intercepted HTTP requests guarded, with a browser-session backstop covering shared workers. See [accepted browser limitations (S18)](../architecture/security-decisions.md#s18-browser-filtering-is-not-network-confinement).
- **Never log into the pirc web UI inside an agent's browser** (for example during a `browser_handoff`): the profile keeps the cookies, and a later agent could drive the UI with them.
- Taking over from the side panel requires holding session control.
- `features.browser.enabled: false` in the agent config hides the tools without disabling the node's browser; `PIRC_BROWSER=false` disables both.
- Headless Linux hosts need the usual Chromium runtime libraries; under the NixOS module's `PrivateDevices=true` hardening, Chromium runs without GPU, which is fine for headless use.
