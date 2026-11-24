# pirc

A private, forward-authenticated web client for persistent coding-agent sessions. It ships as three independently compiled executables: `pirc-gateway`, `pirc-chat`, and `pirc-node`.

It consists of:

- a **gateway** that browsers talk to: authentication, the session index, and routing;
- a **chat node** (`pirc-chat`) for assistant chats and projects;
- one or more **coding nodes** (`pirc-node`), one per machine with workspaces, which connect out to the gateway and run one built-in agent subprocess per session (over a JSONL RPC on stdin/stdout), plus side-panel shells;
- a responsive Svelte PWA;
- a native Android client in progress ([`apps/android`](./apps/android/README.md)), which pairs through device tokens;
- a Flutter Android testing client ([`apps/mobile`](./apps/mobile/README.md)) with the Claude Design phone/tablet UI, sharing the original Android API and event reducer: live chat, work panels, PTY, browser, schedules, notifications, quick-reply overlays, and manually selected reading versions.

The gateway never runs agents or tools; it only runs model requests on their behalf (see [Agent](#agent)). On a single machine, run the gateway and a node side by side; across devices, each device runs a node that connects to one central gateway over a private VPN. See [`apps/gateway/README.md`](./apps/gateway/README.md) for setup and the current limitations.

## Security model

### Threat model

pirc is a **single-user, self-hosted tool for a trusted private network**, such as your own VPN or LAN. The operator, gateway, paired nodes, and their operating-system accounts belong to one trust domain. One user may have multiple nodes, devices, and concurrent sessions.

- Model backend settings and credentials are deployment-wide settings for that operator. pirc is not a multi-tenant service: user allowlists and session ownership do not establish isolation between mutually untrusted users, and there is no separate administrator/user role model.
- Compromised gateway or node hosts, malicious processes running as the same OS account, and hostile node operators are outside the protection boundary. Agents always run in an OS sandbox, but it limits what they read, write and reach; it does not make a hostile node or account safe. Storing credentials on the gateway alone does not isolate them from processes that can access the same files or environment (the NixOS module runs the gateway as its own account for that reason).
- Repository content, web pages, model output, provider errors, and browser input remain untrusted data. A trusted network does not make that content authorization to run commands or change settings.
- The security goals are to prevent unintended exposure and unauthorized access, cross-site requests, and accidental credential disclosure. Authentication, request validation, secret-safe handling, and resource/lifecycle limits still matter on a private network. Multi-user deployment or public exposure requires a new threat-model review.

### Deployment safeguards

The gateway is intended to sit behind a trusted reverse proxy using an Authelia-style forward-auth flow. The private-network assumption does not disable the following safeguards:

- The gateway only accepts identity headers from explicitly configured proxy IP addresses.
- Authenticated user identities, `Host`, and `Origin` are checked against exact allowlists.
- There is no trust-all or unauthenticated production default.
- Nodes authenticate to the gateway with per-node secrets and connect outbound only; they listen on no port.
- Phones running the native app authenticate with device tokens paired from the web **Settings → Devices**. A device token still needs the trusted proxy and an allowed `Host`, cannot manage devices or model backends, and dies after 7 days without use, 30 days after pairing, or on revocation. Otherwise, it acts as you, including shells on your nodes; revoke a lost phone at once. The proxy must pass these requests past forward auth and strip the identity header (see [`apps/gateway/README.md`](./apps/gateway/README.md#device-tokens)).
- Workspaces are allowlisted. Each agent runs in an OS sandbox (srt, sandbox-runtime, built into the chat/node executables); see "Agent sandbox" below. A node where the sandbox cannot work starts no agents.
- The web side panel can browse workspace files, show Git changes and history, and open interactive shells in the workspace. Shells run as the node's account, just like the agent's tools, and require holding session control; set `PIRC_TERMINALS=false` on the node to disable them.
- The agent's browser (see [Browser](#browser)) loads pages with the node account's network access and keeps each workspace's logins in a persistent profile. Taking it over from the side panel requires holding session control; set `PIRC_BROWSER=false` on the node to disable it.
- Keep the gateway on loopback or a private interface reachable only by the trusted proxy. Do not expose it through Tailscale Funnel or the public Internet.

## Requirements

- [Bun](https://bun.sh) 1.2 or newer (development/build only; the compiled executables embed their runtime)
- A model backend, configured on the gateway: a subscription login (Claude Pro/Max, GitHub Copilot, ChatGPT/Codex) or an API-key/custom endpoint from the web **Settings**, and/or `models.json` (see [Agent](#agent))
- A trusted forward-auth reverse proxy

## Development

```sh
bun install
cp apps/gateway/.env.example apps/gateway/.env
# Fill every security allowlist. Do not copy development values to production.
# Gateway, chat and coding nodes take separate environments; see the example.
bun run dev        # gateway
bun run dev:chat   # optional chat node, with its own node ID/token/state directory
bun run dev:node   # coding node, with PIRC_DAEMON_URL=ws://127.0.0.1:8787
bun run dev:web
```

The node's first workspace can point to this repository. See [`apps/gateway/README.md`](./apps/gateway/README.md) for configuration and API details, and [`apps/web/README.md`](./apps/web/README.md) for the client.

## Role-specific executables

```sh
bun run build            # web bundle plus all three independent executables
./apps/gateway/dist/pirc-gateway  # browser API and routing
./apps/gateway/dist/pirc-chat     # assistant chats and projects
./apps/gateway/dist/pirc-node     # coding agents and shells for this machine
```

To compile only one role, run `bun run build:gateway`, `bun run build:chat` or `bun run build:node` from `apps/gateway/` (from the repository root, prefix with `bun run --filter @pirc/gateway`). Build the Web UI separately with `bun run --filter @pirc/web build` when needed.

Each executable embeds Bun and SQLite. Chat and coding nodes share the same node/agent implementation, but their executable fixes the role; no environment variable switches between them. Both support the internal `agent` and `ptc-worker` commands; only the gateway supports `oauth-worker`. These worker commands are started by the runtime, not separate services.

The Nix gateway package includes the static Web UI but no sandbox/browser runtime. The chat/node packages include srt and on-disk playwright-core but no Web UI; browser execution still needs Chromium/Chrome and optional ffmpeg. The compiled executables need no separate Bun installation. Keep all three roles on the same release/protocol version. The executable split is a packaging boundary, **not privacy isolation**: host accounts, filesystem permissions and the agent sandbox remain the security boundaries. See [migration guidance](./docs/deploy/upgrades.md#migrating-from-the-single-executable).

## Agent

The built-in agent (`apps/gateway/src/agent/`) is configured in three layers:

- **Models (gateway)**: model backends and their credentials live only on the gateway, which also **runs every model request**. Agents stay on their nodes and send requests over the node link (via a private, token-protected Unix socket from agent to node); the gateway resolves the backend, calls the model, and streams the reply back. Nodes and agents receive only a secret-free model catalog: no API key, OAuth token, endpoint URL or header. Because credentials are resolved per request, a changed key, a token refresh, a new login or a logout reaches running sessions on their next request; a settings change cancels requests in flight. Backends come from two sources:
  - **Web Settings → Model backends** (`$PIRC_STATE_DIR/backends/settings.json`, mode 0600, written atomically): every subscription login built into the pinned [pi-ai](https://github.com/earendil-works/pi/tree/main/packages/ai) version (`@mariozechner/pi-ai@0.73.1`: **Anthropic Claude Pro/Max**, **GitHub Copilot**, **ChatGPT Plus/Pro (Codex)**), API-key or keyless custom endpoints (`openai-completions`, `openai-responses`, `anthropic-messages`, legacy `openai-chat`), and the default model. See [Subscription logins](#subscription-logins).
  - **`models.json`** (`PIRC_MODELS_FILE`, default `$PIRC_CONFIG_DIR/models.json`, i.e. `~/.config/.pirc/models.json`): `providers` and `defaultModel`, read-only in the web UI. Reference API keys with `apiKeyEnv`, `apiKeyFile`, or `apiKeyCommand` (resolved on the gateway). A file backend wins over a web backend with the same ID; the web default model wins over the file default. Send the gateway `SIGHUP` to reload the file. An invalid file is fatal at startup, and on reload it is logged and ignored.

  Endpoints must be reachable from the gateway (a model server that only listens on a node's `localhost` is not). Nodes have no provider settings of their own; `providers` and `defaultModel` in a node's `config.json` are ignored with a warning.

- **Node**: `~/.config/.pirc/config.json` on each node (override the directory with `PIRC_CONFIG_DIR`) holds limits, features, hooks, `env`, `allowedPaths` and `sandbox`. Coding rules go in `AGENTS.md` in the same directory. Chats instead use global `SOUL.md` (persona) and `CHAT.md` (general rules), editable in Settings → Assistant when the files are writable. Changes apply at the next agent start; move chat-relevant rules out of `AGENTS.md` when upgrading.
- **Project**: `<workspace>/.pirc/config.json` can only add `allowedPaths`, `env`, `hooks`, and a `defaultModel` (which must name one of the gateway's models). Its `allowedPaths`, `env` and `hooks` are ignored until you trust them in the workspace's Settings (trust is tied to their content, so a later change needs trusting again), and its `allowedPaths` never widen the sandbox. `<workspace>/.pirc/AGENTS.md` is appended to the system prompt, and `<workspace>/.pirc/roles/<name>.md` adds or replaces roles. The agent cannot write to any `.pirc/` directory.

### Agent sandbox

A node starts every agent inside [srt](https://github.com/anthropic-experimental/sandbox-runtime) (Seatbelt on macOS, bubblewrap with a seccomp filter on Linux). The agent's tools, shells, `code` scripts, hooks, teammates and subagents all run inside it. The file tools apply the same rules, so they refuse what the sandbox would:

- **Reads** work anywhere except credential stores (`~/.ssh`, `~/.gnupg`, cloud and git credentials, keychains, browser profiles) and the node's own state (other sessions, uploads, its database, browser profiles, its credentials).
- **Writes** go only to the workspace (or a chat's own directory), the node's `allowedPaths`, the session's temporary directory, `/tmp` and build caches. `.pirc/`, git hooks, `.git/config` and shell startup files stay read-only.
- **Network** goes through a filtering proxy. Only common code hosts and package registries are allowed, plus hosts you add. When a task needs another host, the agent calls `sandbox_allow_domains` and the node asks you. An approved host stays allowed for the rest of the session.
- **Outside the sandbox**: for what the sandbox blocks (a nix build, git over SSH, changing the system), the agent calls `unsandboxed_bash`. The node asks you first, then runs the command with the node account's permissions, but without the node's own secrets.

The node itself asks for both approvals, not the agent: nothing the agent says counts as your answer. Teammates and subagents share the sandbox; their requests go through the agent that started them and name who is asking.

Set it in the node's `config.json` (never a project's):

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

Notes on these settings:

- If the `sandbox` settings are invalid, the defaults stay in force and the session shows a warning.
- Put the directory holding the node's own env file (with `PIRC_NODE_TOKEN`) in `denyRead` when it sits outside `PIRC_STATE_DIR`.
- The node runs the srt built into its executable (`pirc-node srt`); `PIRC_SANDBOX_SRT` names an external one instead, as the Nix package does. Linux hosts still need bubblewrap, socat and ripgrep.
- The sandbox cannot be turned off. When srt cannot sandbox on the host, no agent starts and prompts fail with the reason; for example, Linux may refuse unprivileged user namespaces (Ubuntu 24.04 needs `kernel.apparmor_restrict_unprivileged_userns=0`). `PIRC_SANDBOX=off` makes the node refuse to start.

The sandbox does not cover `web_fetch`, the `browser_*` tools or `web_search`: the node's browser and the gateway run those, so they remain a way to send data out, like anything sent to the model.

- **Skills**: [Agent Skills](https://agentskills.io) — directories holding a `SKILL.md` (YAML front matter with `name` and `description`, then instructions, plus any scripts or references it points to) — loaded from, lowest precedence first: `~/.agents/skills/` (a personal skill directory shared across agent harnesses such as OpenClaw and Hermes; every session on the node), `$PIRC_CONFIG_DIR/skills/` (every session on the node, chats included), and `<workspace>/.pirc/skills/` (that project). A later source wins on a name clash. Only each skill's name, description and path go in the system prompt; the model reads the skill when a task matches. `/skill:<name> [request]` loads one explicitly and `/skill` lists them. Skill directories, including symlinked ones, are readable but not writable by the file tools; a skill added after a session's agent started is listed at once, but if it is a symlink (or the directory did not exist yet) its files become readable only in a new session. Invalid skills are skipped with a warning. `features.skills.enabled: false` turns skills off.

Hooks (`sessionStart`, `beforePrompt`, `beforeTool`, `afterTool`, `agentSettled`) are shell commands that receive JSON on stdin. A `beforeTool` hook can reject a tool call (exit 2) or rewrite its arguments.

Built-in tools and features:

- Tools: `read`/`write`/`edit`/`ls`/`find`/`grep`/`bash`.
- PTC code mode (`code`: TS/JS run in a subprocess that can call the other tools).
- `ask_user_question` and `todo`.
- `web_search`: the gateway searches the web with [Exa](https://exa.ai) and returns up to 10 results (title, URL, date and query-relevant excerpts, marked as untrusted); the agent reads whole pages with `web_fetch`. Set `EXA_API_KEY` in the gateway's environment (for example its `environmentFile`); the key never reaches a node, and without it the tool answers that search is not configured. Identical searches are cached for 15 minutes. Only a node's main agent has it (not teammates or subagents), auto mode does not ask before searching, and `features.webSearch.enabled: false` on a node removes the tool.
- Scheduled tasks (`schedule`, `/cron`): a prompt that runs by itself, as a new session in a workspace, on a 5-field cron expression or once at a set time, in an IANA time zone (see [Schedules and notifications](#schedules-and-notifications)). An agent's new schedules and changes wait for your approval in its chat; pausing and deleting do not. An assistant chat may schedule in any directory workspace, other sessions only in their own, and a scheduled run cannot create, resume or start schedules. `features.schedules.enabled: false` on a node removes the tool and the command.
- Session goals (`create_goal`/`get_goal`/`update_goal`, `/goal`): one persisted completion objective per session. Once a run stops cleanly, the agent starts a continuation round on its own, and keeps doing so until the model marks the goal `complete` or `blocked`, the round limit is used up, or you pause it. An aborted or failed run pauses the goal. Only a user request may create, edit, pause, or resume a goal. Updates must quote the goal's current revision. `blocked` is rejected until `minBlockedRounds` rounds have passed. After the agent restarts, an active goal waits for `/goal resume`. The web client docks the goal above the composer with pause and resume buttons. Configure it in `features.goal`: `enabled` (default `true`), `minBlockedRounds` (default `3`), and `defaultMaxRounds` (the limit for goals created without one; unlimited by default). Team children never get goals.
- Compaction with prompt-cache warming, and observational memory with `recall`.
- `background_task`: shell jobs with process-group cleanup and one coalesced wakeup per batch of completions. `tty: true` runs a job on a pseudo-terminal so `write` can send it input. `notify_on` (a regular expression, set on start or later with `monitor`) wakes the agent with matching output lines, for dev servers, watchers, or log tails.
- `subagent`: a one-shot delegate with a fresh context. It runs one task and returns only its final report, then exits. It runs in the foreground (the tool call waits) or with `background: true` (the report is delivered once when it finishes). Subagents get no team tools and cannot spawn further agents.
- Agent teams: `agent_spawn` starts persistent collaborators that message each other (`agent_send`/`ask`/`reply`/`wait`), share notes (`board_*`), and coordinate on a shared task board (`task_create`/`list`/`get`/`update`). The board has claims, owners, dependencies, and revision checks, and tasks are released when their owner stops. A teammate reports its last answer to the parent once each time it goes idle. Children are `pirc-chat agent --headless` or `pirc-node agent --headless` subprocesses, matching their node's executable.
- Team completion: after a clean model turn, the parent stays in the same run while workers are active, displaying “Waiting for team” without polling the LLM. Idle persistent teammates do not block completion; parent-directed questions return control to the model. `limits.completionWaitMs` (default 60,000; maximum 86,400,000) bounds each wait: timeout adds an explicit pending-work notice and lets the model report partial progress, without stopping workers. Already-streamed text is not buffered or retracted. Pending team reports enter context together at tool boundaries (bounded batches); a direct `agent_inbox` result suppresses duplicate notifications only for fully returned event IDs. Long reports are read in full with `agent_inbox` `event_id` plus `offset`, 12,000 characters at a time, following `next_offset`. Truncated previews and inbox reads hidden inside `code` do not count as full reads. Stop suspends automatic team wakeups and retains late reports for the next user turn; it does not stop workers (`agent_stop` or `/team stop` does). There is no automatic team recovery after a process restart.
- Roles: subagents, teammates and delegations start in a role instead of a model. A role is a markdown file `<name>.md` (lowercase letters, digits, `-` and `_`): optional YAML front matter with `description` (up to 500 characters), `model`, `thinking` and `tools` (an allowlist, as a YAML list or comma-separated), and the role instructions as the body (up to 8,000 characters). Roles come from the built-in `general`, then the node's `$PIRC_CONFIG_DIR/roles/`, then the workspace's `.pirc/roles/`; a later file replaces a role of the same name as a whole. `model` is one `provider/model-id` or a list of up to 20 (YAML list or comma-separated), where `*` matches anything within a part: `*/gpt-5` is `gpt-5` from any provider, `openai/*` any OpenAI model. The patterns expand in order, each into its matches in the gateway's model-catalog order. The agent starts on the first match; on a retryable failure before any text is emitted (for example a rate limit, overload, HTTP 408/409/5xx, timeout or dropped connection), it moves immediately to the next match and stays there for the rest of the session. The final candidate uses normal in-place retries. A model you pick yourself outside the role's expanded list turns role fallback off. JSON roles in `config.json` (`roles`, `features.agentTeam.kinds`) are ignored, with a warning when the node starts. For example `~/.config/.pirc/roles/explorer.md`:

  ```markdown
  ---
  description: Read-only code investigation
  model: [anthropic/claude-haiku-*, '*/gpt-5-mini']
  thinking: low
  tools: [read, ls, find, grep]
  ---

  Do not edit files. Cite file:line evidence and mark anything unverified.
  ```

  The picking agent sees every role's name, description, model, thinking and tools (the `role` parameter of `subagent` and `agent_spawn`, and the `## Workspaces` section for delegations). The instructions go into the started agent's system prompt as a `## Role` section; they cannot widen tools, sandbox or approvals. A broken role file makes using a role fail with the file's name and the mistake. Agents never pass a model or thinking level: `subagent`, `agent_spawn`, `delegate` and `schedule` refuse them. Only you set models: in role files, in a delegation's approval card, and in schedule settings. A delegation's follow-up keeps its session's role. Teammates always keep their coordination tools. `features.agentTeam.limit` (default 4) caps live teammates and `subagentLimit` (default 4) caps running subagents.

- Session titles: sessions cannot be named when created; each one is named by the model from the first user message that describes work (greetings are skipped). It is a side request with no tools and no thinking, and it retries on later messages if it fails. A name you set by renaming always wins. Configure it in `features.sessionTitle`: `enabled` (default `true`), `model` (`{ "provider", "id" }`; defaults to the session's model, so a small, fast model saves cost), `prompt` (replaces the default system prompt), and `maxAttempts` (default `3`).
- Auto mode: a check that runs before every `bash` command, `background_task` start, input or `write`, every `code` script, and the same calls made from `code`. A `code` script that spawns processes or writes files directly counts as dangerous; one that uses other runtime APIs goes to the classifier; one that only computes and calls `tools.*` runs unprompted. Input to a background task is judged as the whole pending line, not keystroke by keystroke. First, static rules sort the action into read-only, workspace write, or dangerous. Dangerous actions include deleting a workspace root or anything outside it, `git reset --hard`/`clean -f`/force push, publishing or deploying, touching credentials, changing system or global configuration, and piping a download into a shell. Any action the rules cannot judge goes to a classifier model, which sees the action, the user's last few requests and the critical observational-memory notes the session currently carries that came from the user (their earlier constraints, corrections and decisions), but never tool output. Operands the rules cannot resolve (variables, globs near credentials), `PATH`/`LD_*`/`GIT_*` assignments, aliases, symlinks created earlier in the command and `git -c`/`--upload-pack`-style options also go to the classifier. A dangerous action needs your confirmation; headless agents (teammates and subagents) are refused instead. Anything that may write takes the node's write lease first, so another session writing the same worktree makes the call fail with `workspace_busy`. When no classifier model answers, an unclear action counts as a write. Configure it in `features.autoMode`: `enabled` (default `true`; `false` keeps only the write-lease decision), `useModel` (default `true`), `useMemory` (default `true`; show the classifier those memory notes), `model` and `fallbackModels` (default to `features.observationalMemory`'s, then the session model), `timeoutMs` (default `30000`), and `deny` (regular expressions for commands that always need your confirmation; see [docs/deploy/node.md](./docs/deploy/node.md#the-agent-config-directory)). This is not a sandbox: approved or misclassified commands still run with the agent's permissions inside the OS sandbox.

### Browser

Each node gives its agents a real Chromium through [playwright-core](https://playwright.dev) (plans/browser.md). The node owns one browser per workspace, with a persistent profile under `$PIRC_STATE_DIR/browser/`, so a login made once serves every session in that workspace. Each session drives its own tabs.

- **Tools**:
  - `web_fetch` renders a URL (JavaScript runs, logins apply) and returns readable markdown, text or HTML, in pages of `maxChars`.
  - `browser_navigate`/`snapshot`/`click`/`type`/`select`/`press`/`wait_for`/`screenshot`/`tabs` drive pages through accessibility-snapshot refs.
  - `browser_handoff` asks you to take over, for example to log in or pass a CAPTCHA, and waits until you return control.
  - `browser_record` records a video.

  Snapshots mask password values, and `browser_type` refuses password fields, so logins go through a handoff. Only the node's main agent has the browser (not teammates or subagents), and only `http(s)` URLs open. Auto mode does not judge browser actions; the system prompt tells the agent to ask before consequential submissions.

- **Side panel → Browser** (web and Android):
  - A live JPEG screencast of the session's active tab, streamed only while you watch.
  - **Take over** pauses the agent's browser tools (they wait up to 5 minutes, or for the handoff) and forwards your clicks, scrolling and typing, IME included. **Return control** hands it back.
  - An address bar, tabs, and a **Record** button.
  - An activity log whose steps (with a screenshot per agent action) you can replay one by one.
- **Recordings** are WebM files in `<workspace>/.pirc/recordings/`. Frames are repeated at 10 fps so videos play in real time, and recordings stop after 30 minutes. They play in the `browser_record` tool card (web) or open in the Android player, served with HTTP ranges from `/api/sessions/:id/browser/recording?path=…`.
- **Node settings**:

  | Variable                    | Meaning                                                    | Default                                                                                    |
  | --------------------------- | ---------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
  | `PIRC_BROWSER`              | Enables the browser                                        | `true`; unavailable when no browser is found                                               |
  | `PIRC_BROWSER_EXECUTABLE`   | Browser executable                                         | `chromium`, `google-chrome`… on `PATH`, then `/Applications/Chromium.app` or Google Chrome |
  | `PIRC_FFMPEG`               | ffmpeg with libvpx, used for recordings                    | `ffmpeg`                                                                                   |
  | `PIRC_BROWSER_VIEWPORT`     | Viewport size                                              | `1280x800`                                                                                 |
  | `PIRC_BROWSER_IDLE_MS`      | Idle time before a session's tabs close; the profile stays | 30 minutes                                                                                 |
  | `PIRC_BROWSER_PROFILES_DIR` | Where the profiles live                                    | `$PIRC_STATE_DIR/browser`                                                                  |

  `features.browser.enabled: false` in an agent config hides the tools. The NixOS module sets these through `services.pirc.browser.{enable,package,ffmpeg}`.

### Schedules and notifications

The gateway keeps each user's schedules and starts every run in a new session of the schedule's workspace, delivered as a scheduled-task message (never as your words). Manage them in the web app (Settings → Schedules), on Android (More → Schedules), with `/cron`, or by asking an agent. In the web and Android schedule forms, you may choose a model and thinking level per schedule; otherwise the normal default applies. An agent can propose a schedule or change, but cannot choose its model or thinking level.

- **Nothing runs unasked.** A fire time the gateway slept through, or whose node was offline, becomes one _missed_ run that starts only when you allow it; a fire time while the previous run is still going is _skipped_. A run that waits for an answer (a dangerous command, a question) stays waiting until you open its session.
- **Time zones**: the web and Android apps default to the device's zone; an agent defaults to the gateway's (`PIRC_TIMEZONE`, else the system's; `services.pirc.timeZone` in the Nix module).
- **Notifications**: Web Push on browsers (Settings → General → Notifications; needs https or localhost, and the installed app on iOS) and [UnifiedPush](https://unifiedpush.org) on Android (More → Notifications, with a distributor such as ntfy; no Google services). They cover scheduled runs (each schedule chooses every run, only problems, or none), any session waiting for your answer, finished or failed delegations, and memory changes to approve. Messages are encrypted for each device and carry only a title, a short line and what to open; no agent output. A notification about the session you are looking at is not shown.
  - The gateway signs pushes with a VAPID key pair made on first start (`$PIRC_STATE_DIR/vapid.json`), or `PIRC_VAPID_PUBLIC_KEY`/`PIRC_VAPID_PRIVATE_KEY`. Changing it invalidates every subscription. `PIRC_VAPID_SUBJECT` (a `mailto:` or `https:` URL, default the first allowed origin) is the contact push services see.
  - Push endpoints must use https; `PIRC_PUSH_ALLOW_HTTP=true` also accepts http ones (a distributor server on a LAN). A phone's subscription goes with its device token.

### Subscription logins

Open **Settings → Model backends** and choose **Log in**. The gateway runs pi-ai's login flow in an isolated, time-limited subprocess and shows its steps in the browser: the authorization link and instructions, device codes, questions (such as a GitHub Enterprise domain), and progress. Nothing needs a CLI on a node.

- **Claude Pro/Max** and **ChatGPT/Codex** use fixed `localhost` redirect URLs. When your browser is not on the gateway machine, the final redirect page fails to load; copy that complete `http://localhost:…` URL from the address bar and paste it into the login card. It must carry the state from this login. Do not expose a callback port.
- **GitHub Copilot** uses a device code. pi-ai's login also **enables the policy for every GitHub Copilot model it knows** on your account, so the UI requires explicit consent first. Some models may still need enabling in Copilot itself.
- Tokens are refreshed on the gateway shortly before they expire, once for concurrent requests. **Log out** deletes the gateway's saved credentials and blocks new requests; it does not revoke the account upstream or recall content already sent.
- pi-ai's model catalog is not proof that your plan includes a model, and a built-in login is not a statement about each service's terms for third-party clients: check them yourself. Real logins and paid calls are not part of the automated tests.

Chat projects (the assistant's chats on the chat node) can turn off delegation, memory search, remote recall, schedules and web search per project, and can carry instructions for every new chat. See [`docs/chat-projects.md`](./docs/chat-projects.md).

The observational-memory implementation is documented in [`docs/architecture-observational-memory.md`](./docs/architecture-observational-memory.md); the backend/subscription-login architecture is in [`docs/architecture-backend-auth.md`](./docs/architecture-backend-auth.md).

## Validation

```sh
bun run check
```

Real-model smoke tests are deliberately separate because they require credentials and incur provider cost. The automated suite drives the real agent against a scripted fake OpenAI/Anthropic SSE server (end to end through gateway inference), and covers subscription logins, refresh and logout with fake OAuth providers, and the pi-ai adapter with an injected stream.

## Releases

See [CHANGELOG.md](./CHANGELOG.md) for user-facing changes and migrations, and [release policy](./docs/releasing.md) for version bumps, validation and publishing. `bun run version:check` verifies synchronized product versions and is part of `bun run check`.

## Nix integration

A reusable flake, package, development shell, and NixOS module are available in [`flake.nix`](./flake.nix) and [`nix/`](./nix/README.md):

```sh
nix develop
nix build .#pirc-gateway
nix build .#pirc-chat
nix build .#pirc-node
```

The NixOS module runs the gateway (`pirc.service`, as `pirc-gateway`) and, by default, a local node (`pirc-node.service`, as `pirc`) under two unprivileged service accounts, and can generate an nginx virtual host wired to an Authelia-compatible `auth_request` endpoint. The model providers (`services.pirc.models`), agent configuration (`services.pirc.agentConfig`), secret management, TLS certificate ownership, workspace permissions, and host names remain explicit inputs rather than unsafe defaults.

## Deployment

Step-by-step deployment guides (topology, gateway and node configuration, reverse proxy, NixOS module, macOS launchd nodes, secrets, upgrades, backups and troubleshooting) are in [`docs/deploy/`](./docs/deploy/README.md). Applying them to a host, proxy authorization, and backup/restore drills remain the operator's responsibility: nothing in the repository ships a trust-all default.

## Acknowledgements

pirc started as a web client for [Pi](https://github.com/earendil-works/pi) and now runs its own agent loop, tools, sessions, and protocol. It still uses Pi's [pi-ai](https://github.com/earendil-works/pi/tree/main/packages/ai) package on the gateway, only for subscription logins, the model catalog, and the model transports behind them. Several built-in features (todo, background tasks, agent teams, observational memory) are ports of Pi extensions, and session titles follow oh-my-pi's title generator.
