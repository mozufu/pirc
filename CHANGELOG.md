# Changelog

User-facing changes are recorded here. See [release policy](docs/development/releasing.md).

## [Unreleased]

### Added

- Explicit pots Start in Web and Android: authorize a written instruction in a dedicated same-workspace execution conversation, with backend-attributed “From pots” messages, progress/results, takeover fences and execution-scoped Stop. Tracking and reading still never execute work; autonomous observation/dispatch remain unavailable.
- Durable one-shot dispatch identities and fail-closed recovery. Uncertain sends are never automatically replayed; pending Stop is reconciled when its Node reconnects.

### Changed

- Remove the legacy per-session observational memory and its `features.observationalMemory` settings, panel state and commands. Session handoffs, repository memory (`features.workspaceMemory`), workspace search and `recall` remain; compaction uses the regular compaction thresholds.

### Fixed

- Report failed or uncertain initial message admission truthfully, and allow Stop while admission hooks are pending. The complete first-send recovery flow is still in progress.
- Include the project AGPLv3 license in native/Web release archives and Nix packages, alongside existing third-party notices.

### Upgrade notes

- Back up Gateway, Node and client draft state before the next upgrade. Gateway schema 1019 and Node schema 2009 add durable first-message preparation, attachments, admission, Stop/delete recovery and explicit retries. Web/Android recovery is integrated but remains gated pending full acceptance; private draft formats are version 3. The seven-day expiry applies only to unaccepted Gateway staging. Node protocol 15 requires updating Gateway and all Nodes together. These changes are not part of the 0.10.0 tracking-only release.

## [0.10.0] - 2026-10-25

### Added

- Remove idle Work workspaces from the Gateway without deleting node files, sessions or memory. Adding the same canonical path again restores its existing identity; linked projects retain the offline link.
- Opt-in, progress-only pots tracking in Web and native Android: durable responsibilities with finite budgets, sourced suggestions, canonical tracking tasks and fenced pause/takeover controls. Tracking never starts an agent; automatic execution is not available in this checkpoint. Gateway schema 1010 requires a state backup before upgrade.
- Unpublished Rust foundations: pure `pirc-llm-types`, explicitly configured `pirc-llm` transports with optional default-off OAuth, and a host-driven `pirc-agent-loop` state-machine checkpoint. Production agents drive their existing run through `pirc-agent-loop` without changing events, persistence or the authenticated inference route.
- Reusable overlapping tool waits, snapshot-bound history rewriting independent of the memory backend, and standalone `pirc-tool-schema` validation/documentation helpers. Existing tool policy and memory storage remain host-owned.

### Changed

- LLM transports now use catalog-free runtime requests and structured completion, cancellation and failure outcomes. Provider wire formats, partial streaming snapshots and cancellation behavior stay compatible; tool argument ownership and SSE buffering avoid unnecessary copying.

### Fixed

- Saturate aggregated LLM usage counts instead of overflowing on extreme provider values.
- After a session write fails, later prompts end at once instead of calling the model for a reply that could not be saved.
- Android removes already-missing terminal tabs correctly in Traditional Chinese while preserving genuine close errors.
- Android keeps standard keyboard event names and key codes in Traditional Chinese, restoring native document shortcuts and remote browser Enter/Tab/Escape, deletion and IME submit.
- Android native modal dialogs with author `inset:auto` position independently of their former DOM parent layout, keeping controls aligned with their hit targets.

### Upgrade notes

- Back up Gateway state before schema 1010 migrations; older Gateways cannot open the migrated database. Update Gateway, Nodes and client assets together. Node protocol 14 and Node schema 2002 are unchanged from 0.9.3. Pots tracking remains opt-in and cannot execute tasks automatically. See [upgrades](docs/deploy/upgrades.md).
- The Rust libraries remain unpublished on crates.io. Android remains a beta preview; macOS archives are not Developer ID signed or notarized.

## [0.9.3] - 2026-10-23

### Added

- Web and Android calendars with month/week/day views, ordinary events, reminders and confirmed Agent proposals.
- Agent checkpoints and reviewed recovery into an isolated workspace, with Web/Android previews and continuation; the original workspace is never overwritten.

### Changed

- Session handoffs and repository memory use separate, provenance-checked journals. Existing repository memory requires explicit activation after stopping older writers.
- Web and Android show one collapsed activity row per response; thoughts, scripts and tool results expand on request. Answers, confirmations and failure summaries stay visible.

### Fixed

- Avoid memory activation deadlocks between concurrent agents and support large repository histories without exhausting the shared parse cache. Memory panels report activation state explicitly.
- Update Rust TLS verification dependencies for distrusted emSign certificate paths (RUSTSEC-2026-0382 and RUSTSEC-2026-0383); rebuild and restart the gateway and all chat/coding nodes.
- Android native HTML documents handle modal dialogs, backdrop dismissal, authored dialog positions and partial document roots; scripted focus reveals off-screen controls again.

### Upgrade notes

- Upgrade Gateway and all Nodes together (node protocol 14); back up state before Gateway schema 1008 and Node schema 2002 migrations. See [upgrades](docs/deploy/upgrades.md).

## [0.9.2] - 2026-10-20

### Added

- English and Traditional Chinese settings for Web and Android, including native notification and quick-reply controls.
- New conversations open immediately and stay local until the first message is sent; abandoned drafts do not enter the session list.
- Android app icon update, terminal pinch/Ctrl-key zoom and mobile extra keys.

### Fixed

- Harden sandbox process channels and private state/cache protection; new sandboxes also isolate registered same-account node/gateway directories. Restart existing sessions to apply the policy changes.
- Improve Android keyboard stability, loading indicators, agent labels and interactive document rendering, forms, dialogs and navigation.
- Add approval-mode warning icons, fix Web source-file line/gutter alignment, and make automatic session naming retry with a fallback.
- Refresh built-in provider model catalogs and preserve native API routes on supported official endpoints.

### Notes

- Android remains a beta preview using the existing Release signing identity. Real-device keyboard behavior and remote background push still need acceptance testing.

## [0.9.1] - 2026-10-19

The first published release with the 0.9.0 changes below (0.9.0 was tagged but its release build failed), now with the signed Android beta APK. Upgrade notes are those of 0.9.0.

### Fixed

- Release builds include the signed Android beta APK again: the release workflow fetches the pinned Flutter SDK with its history, and font-dependent Gantt geometry tests run only where macOS's PingFang font is installed.

## [0.9.0] - 2026-10-19

### Changed

- **Breaking: mode files no longer accept `ui.group`.** The Web and Android clients place a workspace in Chat or Work by its mode's `assistant` capability and show panels, settings, session deletion and the session noun by capability instead of the legacy `kind`, so a per-session mode on a coding node (such as a scratch mode) appears under Work with only the panels it has. Remove `group:` from every `$PIRC_CONFIG_DIR/modes/*.md` before upgrading, or the file is skipped and its workspaces become unavailable. **Node protocol 13: upgrade the gateway and all nodes together.** The gateway database migrates to schema 1005 (delegation audit columns) on start; nodes' schemas are unchanged. See the upgrade notes.

### Added

- **Delegation approval setting** per chat project (and the top-level Chats): `always` (default, today's card), `untrusted` (starts at once unless the chat read outside content since your last message) or `never`. With `untrusted` or `never`, delegation is no longer a human-only operation; read the risk in the chat projects guide before switching. At most 4 delegations started without the card run at once; they use the role's model or the workspace default. `PATCH /api/workspaces/:id/capabilities` accepts `delegation_approval`.
- The assistant passes your exact words that asked for the work (`quote`, checked against your last three messages); the delegated session's auto mode reads them, never the assistant's task text, as your request for that run.
- A chat shows the delegations it started while they run, with **Open** and **Stop** (`POST /api/delegations/:id/stop`).
- A delegated session's confirmations (auto mode, network access, commands outside the sandbox) are relayed to the chat that started it and pushed as "… needs you"; answer them there, from **Needs you** (Allow / Deny) or from the notification, without taking control of either session. Nodes gain the gateway-only `POST /api/sessions/:id/interactions/:interactionId/relayed-answer`; upgrade nodes with the gateway.
- `scripts/approval-stats.ts`: a read-only count of approval prompts in delegated and ordinary sessions.
- Adding a workspace lets you pick among the modes its device accepts (`GET /api/nodes` now lists each node's `modes`); the path is asked only for modes that work in a directory.
- A chat's list of delegation targets names each workspace's mode when the targets differ in mode, so the assistant can send one-off work to a scratch workspace and repository work to a repository.

## [0.8.0] - 2026-10-19

### Added

- Gateway-owned workspace modes load from `$PIRC_CONFIG_DIR/modes/<id>.md` at startup and on SIGHUP. Chat/Work are editable default files, not reserved built-ins; custom modes combine validated capabilities, ordered prompt sections, feature defaults and operation allowlists. Nodes explicitly accept ids with `PIRC_MODES`; agents receive validated `PIRC_MODE` snapshots and role/team tool lists cannot widen the mode ceiling. Missing modes leave history readable but refuse new work; changed modes stop affected agents and terminals. Existing clients retain Chat/Work compatibility; dynamic mode navigation is deferred. **Node protocol 12: upgrade gateway and all nodes together.** Database schemas are unchanged. See the modes guide and upgrade notes.
- Release CI builds macOS, Web and signed Android beta assets into a reviewed draft, with a separate signing setup check.

### Fixed

- Android full-page HTML improves layout, image/canvas sizing and computed-style reads, keeps text selection stable during image loading, notifies interactive content when native element sizes change, and supports native Canvas text measurement, intrinsic/pixel/percentage-sized chart initialization and container resizing, DOM mutation observation, Promise updates between animation callbacks, bar-chart touch tooltips, outside-tap dismissal, legend toggles, updates and resizing.
- Android fixes native pie-chart initialization when Canvas path arguments are nonfinite.
- Android Canvas frames repaint independently of surrounding document content.
- Android interactive documents receive visibility changes and pause pending animation callbacks while hidden.
- Android improves native absolute positioning and makes empty clickable CSS boxes respond across their visible area.
- Android interactive HTML respects pointer-events overlays and restored child controls, including dynamic policy changes, and preserves authored button sizes.
- Android keeps layout-independent computed styles readable after ordinary text updates while remeasuring affected dimensions.
- Android supports viewport-fixed HTML overlays and acknowledges native scrolling before animation callbacks.
- Android keeps the reading position stable when interactive HTML changes content above the viewport.
- Android preserves reading positions inside nested HTML scrolling panels.

## [0.7.0] - 2026-10-18

### Fixed

- Android full-page HTML content improves viewport sizing, offsets, common margins, relative positioning, grid rows and computed-style reads, while keeping overflowing content reachable.
- Gateway and node startup retry brief SQLite WAL-mode lock conflicts when processes open the same database concurrently.
- PTC scripts that exhaust their JavaScript heap report an out-of-memory error reliably, including when the engine cannot allocate an error object.
- OpenCode Zen and Go backends on the current `opencode.ai/inference/...` base URLs (and Zen on the legacy `opencode.ai/zen/...` ones) now send the OpenCode session and User-Agent headers automatically, and **Fetch models from endpoint** finds their model lists. The OpenCode Go preset uses `https://opencode.ai/inference/go/openai/v1`; the editor option is renamed **OpenCode compatibility**.

Same node protocol (11) and database schemas; upgrade the gateway and every node together as usual (an older node answers the new project-file routes with 404).

### Added

- You can edit your own messages in Chat and Work sessions, on the Web and in the Android app (**Edit message** → **Save & regenerate**). Saving keeps the original message and its replies as an earlier version, starts a new version from the edited text (attachments kept) and regenerates the reply; the previous/next buttons beside the message switch between versions without a model request, and the selected version survives reconnects and restarts. Only the selected version is used as context for later replies. Editing and switching need session control and an idle session (no running work or queued messages). **Tool effects are not undone**: files, commands, external actions and memory changed by the agent stay changed. Session commands `edit_message` (`{entryId, message}`) and `switch_branch` (`{entryId}`); snapshot history now includes `entryId` and user-message `branches`. An older node rejects these commands, so upgrade nodes with the gateway.
- The Android app can manage shared project files and delete chat projects with a preview, memory decisions and interrupted-deletion retry.
- Chat projects (and the top-level Chats) have project files: files every chat in the project can read, such as notes, documents or data (project page → Settings → Project files, or `GET`/`POST`/`DELETE /api/workspaces/:id/files`). The chat node keeps them in `<stateDir>/chat/<workspaceId>/files`; chats get that directory read-only in their sandbox and its path in their system prompt (`## Project files`), and the assistant cannot change them. They are shared, not copied: an upload, a replacement (same name) or a removal reaches chats already running. Chats started before the project's first file are not given them; start a new chat. At most 50 files per project, each within the node's upload limit. Deleting a project deletes its files.

## [0.6.1] - 2026-10-17

### Changed

- Updated the Android app with a native Flutter interface, richer content rendering and synchronized interactions across the app and web.

## [0.6.0] - 2026-10-17

The node protocol moves to 11: upgrade the gateway and every node together (a node on protocol 10 is refused, and a protocol 11 node by an older gateway). The gateway's database moves to schema 1004 and each node's to 2001 on first start (automatic); older versions refuse them afterwards, so keep a backup to downgrade. See [Upgrades](docs/deploy/upgrades.md).

### Added

- Chat projects can be deleted (project page → Settings → Delete project…). The confirmation lists what goes (the project's chats, uploads, instructions, links, settings and schedules, and the memory its chats wrote) and what stays (schedules its chats created elsewhere, work delegated to other workspaces, copies in other chats, older uploads, backups). Memory is judged by the chat each version came from: entries only the project wrote are forgotten, entries the project only changed last go back to their earlier text, and entries mixing both wait for your decision (forget, keep, or edit). Text forgotten this way may be written again by other chats; Settings → Memory's Forget still refuses it everywhere. Requires the chat node online; an interrupted deletion resumes when you delete again. API: `GET`/`POST /api/workspaces/:id/deletion`.

### Changed

- An upload can only be attached in the workspace it was uploaded in (`403` "Upload belongs to another workspace" elsewhere), so deleting a project can delete its uploads. Uploads made before this version can still be attached anywhere, and are not deleted with a project.
- Runs and commands a node interrupts when it starts again now say "node restarted" instead of "gateway restarted".
- The gateway logs why a models file reload (`SIGHUP`) failed, and logs a warning for each failed or timed-out model request with the node, provider/model and the same fixed classification the session shows (an HTTP status when known; never the provider's response).

### Fixed

- Two gateway or node processes opening the same database at once no longer race to create or migrate its schema: it is now done under one write lock, and a failed migration is rolled back whole.

### Security

- A `ptc` script that called `memory_search`, `delegation_status`, `agent_inbox` or `board_read` has its result fenced and labelled as data written by other sessions or agents, not instructions, as a script reading web content already was; values it stores keep the label for later scripts.
- A node no longer passes file descriptors it was started with to its agents: it closes every one but stdin, stdout and stderr at start-up, and the Linux sandbox's bridge closes any other before it runs the agent. A terminal's PTY left open by whatever launched the node reached the agent, and a command written to it ran outside the sandbox.
- On WSL, the Linux sandbox hides the interop directory `/run/WSL` whole. Interop sockets bound after a session started (each new WSL terminal binds one) stayed reachable, and through one the agent could run Windows programs outside the sandbox, past the network allowlist.
- The Linux sandbox refuses vsock sockets (`EPERM`) with a seccomp filter: they bypass the sandbox's network namespace, and on WSL 2 the Windows host listens on them. The filter also refuses io_uring, whose rings can open sockets unseen (programs fall back to plain system calls), and stops 32-bit x86 programs in the sandbox. bubblewrap must support `--seccomp` (every release since 0.1), and the kernel seccomp filters (a node without them refuses to start agents).

## [0.5.0] - 2026-10-16

The gateway's database moves to schema 1003 on first start (automatic: four columns, one table and one index); a 0.4.x gateway refuses it afterwards, so keep a backup to downgrade. Same node protocol (10); upgrade the gateway and every node together as usual.

### Added

- Coding sessions, delegated ones included, start with your approved USER entries in their system prompt (a frozen `## User` section, like a chat's). They only read them: the memory tools stay chat-only. Personal preferences repeated in each node's `AGENTS.md` can move into USER; keep repository rules in `AGENTS.md`. If the gateway cannot be reached the session starts without them, says so once, and tries again on its next run.
- Clones of one repository find each other's workspace memory: nodes report each directory workspace's `origin` remote, normalized (`github.com/owner/repo`; no path or credential leaves the node, and remotes on the node itself, such as `localhost` or `file:`, have none), and `memory_search` with a workspace also searches the notes and delegations of its other clones, on any node. The assistant's workspace list shows each repository. The URL is read from the workspace's own `.git` config at registration, without running git; a workspace inside a repository (rather than at its root) has none, and `insteadOf` rewrites and config includes are not followed.
- Chat projects can be linked to the directory workspaces they are about (project page → Settings → Linked workspaces, or `GET`/`PUT /api/workspaces/:id/links`). New chats in the project list those workspaces first, and the other clones of their repositories after them; `delegate` without a workspace goes to the only linked one (you still approve it), and `memory_search` without a workspace looks in the linked workspaces and their clones first, then everywhere if nothing is found there, or everywhere at once with `everywhere: true`. A link is not a permission: unlinked workspaces stay reachable. The top-level Chats workspace has no links.
- The assistant's MEMORY notes written from fetched content (a `bash` command that names `curl`, `wget`, `gh` or a URL, web search or fetch, the browser), and not from your words, are marked "(from fetched content)" in new chats' prompts, and the assistant is told to treat them as claims to check. Such `bash` results have the origin `tool:bash:network` (Settings → Memory shows "bash fetching from the network"), and a `ptc` script whose `bash` fetched has its result fenced as untrusted web content.
- Approval modes replace auto mode's on/off switch: `read-only` (only read-only actions run; every other command, unclear ones included, and every `write`/`edit` asks you; teammates and subagents are refused), `auto` (the default, as before) and `full-access` (nothing asks). The node's `features.autoMode.mode` sets the default, and the composer's approval-mode picker switches one session (recorded in it; switching to full access asks first, and a note stays above the composer while it lasts). Teammates and subagents follow their session, also when it changes; delegated and scheduled sessions start in the node's default. The deny-list still asks and writes still take the lease in every mode. `features.autoMode.enabled` still works with a warning: `false` is now `full-access`, `true` is `auto`.
- A delegation's approval card has a checkbox, "Treat this task as my request for auto mode": ticked, the delegated session's auto mode reads the task as if you had typed it, for the run it starts only (an operation the task names exactly is then not stopped as dangerous). Unticked, nothing changes.
- The session list shows how a delegated session ended ("Done" or "Failed"); delegated sessions are left as they are.
- `features.observationalMemory.missingModelPolicy`: `"error"` stops memory work with a visible error when a configured memory model (preferred or fallback) is not on the gateway, instead of using the session model; the default `"fallback"` keeps the old behavior.

### Security

- A provider's `apiKeyCommand` no longer receives the gateway's own secrets (node tokens, the VAPID private key, the proxy secret, the web search key) in its environment. Other variables are still passed, so password-manager and GnuPG setups keep working.
- A node can no longer push a browser's terminal or live-view socket far past its backlog limit with one huge message: node→browser stream messages over 4 MiB close a terminal socket (`1009`) and are dropped from the live view.
- The browser recording player only reads files inside the workspace: a `.pirc/recordings/*.webm` symlink tracked in a cloned repository could make it return any file the node account can read.
- Files the node itself writes into a session's `.pirc/uploads` (attachments) and `.pirc/recordings` (browser recordings) no longer follow symlinks a cloned repository may track there: the directories are opened without following links, files are created only when absent, and ffmpeg writes to a file the node opened.
- The gateway's limits of 100 pending requests and 64 open terminal/browser streams apply to each node instead of to all nodes together, so one busy node no longer makes the others answer "Too many pending node requests".
- JSON request bodies are limited to 4 MiB (uploads keep `PIRC_UPLOAD_MAX_BYTES`), and a session command keeps only the fields the node uses, each bounded (a message at most 1,000,000 UTF-16 units, at most 16 attachments), before it is stored and forwarded; other fields were stored and relayed whole.
- The gateway keeps at most 8 MiB of events per session for replay (besides the `PIRC_EVENT_BUFFER_SIZE` count), and at most 200,000 mirrored memory rows and 64 MiB of note text per node; a node over that gets no new rows kept for search, and the gateway logs it.
- The web bundle no longer ships source maps, and `bun run dev:web`/`preview` listen on localhost only (add `-- --host 0.0.0.0` for the LAN). The NixOS units drop every capability and restrict address families and realtime scheduling; the gateway's also gets a system-call filter, `ProtectProc=invisible` and no namespaces. CI actions are pinned by commit.
- The gateway's and nodes' databases use SQLite `secure_delete`: deleted and overwritten content (forgotten memory, deleted chats, revoked tokens) is zeroed in the database file instead of staying in free pages. Old WAL frames, copies and backups are not cleaned.
- Hook output and gateway messages no longer reach the model as if you had typed them: `sessionStart` and `beforePrompt` hook stdout is fenced in a `<hook_output>` block labelled as data from hook commands (the session-start one stays in the system prompt, but fenced), and every message the gateway delivers to a session (a delegated task, a scheduled run, a delegation's result) starts with a "Gateway message (pirc data, not typed by the user)" line.
- An agent can no longer delete a schedule on its own: `schedule` `delete` (and `/cron delete`) asks you to approve it in the chat, like creating or changing one, and a scheduled run cannot ask. Pause and resume still take effect at once.
- Finished delegations older than 90 days are deleted, unless a later delegation follows them.
- Skills a repository ships in `<workspace>/.pirc/skills/` are no longer presented to the model as installed by you: the system prompt lists them apart, as untrusted repository content that never overrides your instructions, and `/skill` marks them.
- A repository's `.pirc/config.json` `defaultModel` is now ignored, like its hooks, env and allowed paths, until you trust the workspace's project config; the warning names the model that was not used, and Settings shows it. Trust given before stays valid for configs without a `defaultModel`; a config that sets one needs trusting again.
- The Linux (bubblewrap) sandbox hides every Unix socket bound on the host when the session starts, not only a list of known ones: only the node's inference socket, the Nix daemon's (open by default so builds work) and the sockets in `sandbox.network.allowUnixSockets` stay reachable. Add a socket a session needs (an `ssh-agent`, a database, a container engine) to `allowUnixSockets`, which now works on Linux too, also inside a hidden directory such as `/tmp/ssh-*`, and also re-opens a socket of the built-in host list. The panel's read-only git commands reach none. A node that cannot read `/proc/net/unix` refuses to start sessions.
- A session can read and append to only its own repository's workspace-memory ledger, no longer every file in `PIRC_WORKSPACE_MEMORY_DIR`. The node now picks the ledger from the repository's files before the session starts (as git found it before, without running git on the host) and creates it; the ledger lock is a `flock` on the ledger instead of a `<key>.lock` file beside it, so leftover `.lock` files can be deleted (sessions still running from before the upgrade do not share the new lock; restart them with the node as usual). The ledger is chosen only from a plain repository, a worktree or a submodule whose git directory names it back; anything else in a workspace's `.git` (a symlink, a `.git` file naming another repository) keys it by its own path. A custom `PIRC_WORKSPACE_MEMORY_DIR` outside the state directory is now hidden from sessions as well.

### Fixed

- Observational memory no longer says the preferred model is "rate limited" when it is simply not among the gateway's models.
- Input in the browser's live view (mouse, keys, typed text, navigation) is applied in the order it was sent; quick input could run out of order, such as a key landing after a navigation sent later.
- NixOS nodes start agents again: the module's `ProtectKernelTunables` made the kernel refuse bubblewrap's `/proc`, so the node logged "agent sandbox unavailable" and no session could run. The gateway keeps the setting.
- The `bash` tool and approved host commands run `bash` from `PATH` where `/bin/bash` does not exist, as on NixOS; every call failed with `posix_spawn '/bin/bash'` there.
- A `nixos-rebuild switch` no longer locks the gateway out of its state: NixOS reset the node account's home (`/var/lib/pirc`) to mode 700 on every activation, and the gateway failed to restart (`CHDIR`) until the next boot. The module now sets it to 711.
- Unread sessions in the web sidebar are ordinary rows again: they took the style of the workspace's unread-count badge (a blue, 18-pixel-high pill), so several unread sessions overlapped.

### Known limits

- Assets: macOS ARM64 executables (not Developer ID signed or notarized) and the web build; no Linux binaries (use the Nix packages) and no Android APK (the Android client is being rewritten).
- Checked by hand for this release: `ptc` crash, decline, hook, screenshot and argument handling against OpenAI (Responses and Chat Completions) on macOS; the NixOS module on an aarch64 NixOS VM and an LXC container (sandbox, gateway system-call filter with a real `apiKeyCommand`, state handover, Chromium, Unix sockets). Not checked: Anthropic and subscription backends, Android, push on a real phone, TLS with a real identity provider.
- On Linux, a Unix socket bound after a session started, or in another network namespace, is not hidden from that session.

## [0.4.1] - 2026-10-15

Compatible with 0.4.0: same node protocol (10) and state; upgrade the gateway and every node together as usual.

### Security

- Auto mode no longer lets commands it treats as read-only run programs or write files without approval: `fd -x`, `rg --pre`, `bat --pager`, `sort --compress-program`, `uniq`/`xxd` output files, `yq -i`, `tree -o`, `date -s`, `hostname NAME`, sed scripts that write or read files in any spelling, and abbreviated GNU long options.
- Paths with `..` after a symlink are judged where the kernel resolves them, and `cd` follows bash's logical directory, so a write through a link is leased on the file actually written.
- Uploading a local file (`wget --post-file`, `curl -T`/`-d`/`-H @file` and similar) now goes to the classifier, and a recursive search (`grep -r`, `rg`, `ag`) of a directory that contains credentials needs approval like reading them.
- Approved host commands run in a session of their own, without the node's controlling terminal: they can no longer read keystrokes from, prompt on (`sudo` now fails at once) or inject input into the terminal the node runs in.
- The agent drops stdin lines over 64 MiB without buffering them and answers them as a parse error.

### Fixed

- A `ptc` script's process no longer aborts after reporting its result, which left a crash report on macOS for every execution.
- A service worker that Chromium stopped (for example after being idle) or that crashed no longer hangs when it is started again, nor do the pages waiting for it.
- Popups opened by a page keep their frame numbering with Chromium on macOS.
- A node whose credentials the gateway refuses now logs why, once until it registers again, instead of retrying silently: `PIRC_NODE_ID` and `PIRC_NODE_TOKEN` must match an entry of the gateway's `PIRC_NODE_TOKENS`. The gateway also logs refused node connections with the node id they claimed (never the token), at most once a minute.

### Known limits

- Because these checks are static, some harmless commands now ask the classifier or the user first, such as `grep -R`, `rg -L`, `wget -e robots=off` and sed scripts with unusual syntax.

## [0.4.0] - 2026-10-14

### Breaking changes

- The gateway and node/agent are native Rust executables with no embedded Bun, Node, Deno or V8 runtime. The two artifacts are `pirc-gateway` and `pirc-node`; replace `pirc-chat` with **`pirc-node chat`**, including service definitions and Nix package overrides.
- Node protocol **10** refuses mixed TS/Rust installations (WebSocket close 4426). Upgrade every role together.
- **Fresh state is required.** Do not reuse TS databases, session JSONL, backend settings or VAPID state. Re-pair devices, re-login subscription providers and start new sessions. Preserve old state with the old binaries for rollback. See [migration checklist](docs/deploy/upgrades.md).
- Native bubblewrap/Seatbelt sandbox and CDP browser drivers replace srt/Playwright runtime dependencies. Linux needs bubblewrap; git, Chromium/Chrome and optional ffmpeg remain external. Remove production `PIRC_SANDBOX_SRT` and `PIRC_PLAYWRIGHT_CORE` overrides.
- TS server sources, Bun server builds, the TS test suite and the PTC evaluation tools are removed; run the latter from a checkout of `2d480d3`, the last TS revision. Bun remains a web/development tool.

### Validation limitations

- The user explicitly waived the remaining full PTC/task-time and native provider/subscription smoke-test gate, including unresolved polyglot review/accounting results. These are not reported as passed. Previously accepted sandbox/browser security gaps remain documented in the [cutover record](docs/development/historical-records.md#rust-cutover-and-validation-scope) and [security decisions](docs/architecture/security-decisions.md).

### Security

- Agents can no longer read more credential stores: `~/.local/pirc-node` (the macOS node's `agent.env`), `~/.config/op`, Cargo, RubyGems and Terraform credentials, Claude Code and Codex login files, shell histories and Microsoft Edge profiles. Auto mode and the sandbox now share one list, so a shell command that touches `~/.npmrc`, `~/.yarnrc.yml` or `~/.bundle/config` also needs approval (builds can still read them).
- The file tools refuse writes to the workspace's `.git/hooks`, and to `.git/config` unless `sandbox.filesystem.allowGitConfig` is set, as the sandbox already did for shell commands.
- The gateway database and its WAL files are created with mode 0600, and an existing database is tightened on start.
- Mermaid diagrams are passed through the same sanitizer as the rest of a message.

## [0.3.0] - 2026-10-07

### Added

- `/recap` reviews a bounded sample of recent sessions in the same owner's directory workspace and proposes evidence-linked skills, rules, settings or workflow improvements. It defaults to 14 days and at most 20 sessions, excludes background and recap-marked sessions, and uses a separate no-tools model request without applying changes or promoting the report into memory. Sampled text is sent to the configured model; coverage, truncation and best-effort redaction limits are disclosed.
- Programmatic tool calling: the model can write a `ptc` script, TypeScript run in an isolated QuickJS interpreter, that calls tools as `tools.<name>(args)` with typed results, `tools.par` for bounded parallel work, image attachments and `store`/`load` across scripts. Several reads, an edit and its test run, or filtering search results take one model round. The core tools (`read`, `write`, `edit`, `ls`, `grep`, `find`, `bash`, `web_search`, `web_fetch`) can still be called directly; every other tool is reachable only from a script, with full contracts from `ptc_docs`. On the evaluation tasks with OpenAI `gpt-6.1-sol`, coding used about 20% fewer tokens than before this change, with the same authorization results; on 19 held-out Aider polyglot Python exercises, a build with one more routing sentence passed as many as before (all 38 trials on both) with 32% fewer tokens and 43% fewer model rounds.
- The web and Android timelines show each script's operations nested under it, with running, waiting-for-approval and finished states.
- Setup guide for using `gh` and git (HTTPS with a token, or SSH with a dedicated key) inside the agent sandbox instead of approving `unsandboxed_bash` for each push, with `scripts/sandbox-ssh-proxy.py`, an ssh `ProxyCommand` that authenticates to srt's proxy. Tested on macOS only.

### Changed

- Chats get `ptc` scripts too, over the tools they already have; no capability that chat lacked is added.
- Hooks, auto mode, approvals, path rules and the write lease apply to every operation of a script as to the same direct call. Auto mode checks a script's own text only against your `deny` list.
- Writes only under temporary directories and build caches no longer take the workspace write lease, so sessions using `/tmp` do not block each other.
- Each tool's arguments are checked against its schema before it runs (direct calls still accept `null` for optional arguments and ignore unknown keys).

### Removed

- The `code` tool (scripts with full Bun access) and `features.code`.

### Fixed

- Observational-memory settings now warn once at agent startup when invalid fields cause the entire configuration to use defaults, including re-enabling memory. Diagnostics identify fields without exposing rejected values. Unknown fields are warned about and ignored while valid settings remain in effect; validation strictness and defaults are unchanged.

### Security

- A script has no authority of its own: it runs in a QuickJS interpreter with no file, network or process access, inside a child process with an empty environment that talks only to its agent, which checks every operation the script asks for. The interpreter is the boundary: its process keeps the agent's sandbox rights rather than a stricter profile. After an operation is refused, only read-only tools (`read`, `ls`, `grep`, `find`, `web_fetch`, …) run in the rest of that script, commands and writes are not started, and the refusal always reaches the model.
- What a script gets from web pages, search results or the browser, including values an earlier script stored after reading them and this one may have loaded, is fenced as untrusted in its result.

### Migration

- Upgrade the gateway (it ships the web bundle) and every chat and coding node from the same release, then reload web clients and update the Android app. Rename hook matchers that name `code` to `ptc` (they still apply, with a warning in the session). Scripts that relied on Bun or Node APIs must use tools instead. See [PTC migration record](docs/development/historical-records.md#ptc-evaluation-outcome).

### Known limits

- Evaluated on one model (OpenAI `gpt-6.1-sol`); other providers get the same tools without their own evaluation. Against the pre-declared bounds, dependent multi-step edits on the fixture set did not take fewer rounds; chat used 7–15% more tokens; and chat replies to a request for a disabled capability passed the wording check less often (2/20 against 12/20), although the capability was blocked every time. These were accepted at cutover.
- Fixes made after these measurements (refusal handling, the attachment limit, lenient direct arguments) were not re-measured.
- Image attachments from a script are limited to 512 KiB together per result, so they fit the node's RPC line.

### Distribution

- macOS ARM64 gateway, chat and node executables plus web static assets; source archives are available from GitHub. Native binaries are not Developer ID signed/notarized and require external Chromium/Chrome and optional ffmpeg for browser features.
- Android versionName is 0.3.0 and versionCode is 3; no APK is published. No Linux/x86_64 binaries are included; Nix packaging is retained.
- Recap is a bounded review, not a full transcript audit: it excludes thinking and tool payloads, uses the loaded AGENTS.md snapshot and skill/role summaries, and does not automatically apply recommendations.

## [0.2.0] - 2026-10-02

This is the first tagged release. Earlier development used 0.1.0 without a published release; this entry summarizes the current release rather than inventing a historical 0.1.0 changelog.

### Added

- Global chat persona (`SOUL.md`) and general chat rules (`CHAT.md`), with node-local editors in Settings → Assistant and Nix options `services.pirc.soulPrompt` / `chatPrompt`.
- A Context side-panel tab for chats and coding sessions: system sections and sources, frozen-memory badges, tool descriptions/schemas, estimated and reported context usage, copy-all, and a node-local last-request snapshot available after an agent stops.
- Persistent binding of a single chat node, with an explicit confirmed release action in Settings → Assistant.
- Version synchronization/check tooling and a documented release/changelog policy.

### Changed

- Chats no longer read global or workspace `AGENTS.md`; coding sessions continue to use it and never load SOUL.md or CHAT.md.
- Gateway/node transport is now protocol **8**. Old registrations receive an explicit protocol mismatch rather than an ambiguous registration error.
- Global user-managed configuration and managed prompt symlink targets are protected from agent writes, including when located under an otherwise writable root.

### Security

- This release includes the mandatory, fail-closed agent sandbox and embedded sandbox runtime from recent development, plus project-configuration trust checks and auto-mode hardening. It does not claim that all security-audit limitations are resolved.
- Prompt management uses authenticated gateway/node `allowedUsers`; stale editors cannot silently save to a newly bound node.
- Context snapshots are atomically overwritten with mode `0600`, are not appended to session history, and are not mirrored or persisted by the gateway. Existing inference and assistant-memory data flows are unchanged.

### Migration

- Upgrade the gateway and **every chat/coding node together** for protocol 8. Back up state before upgrading; database changes are not guaranteed to be downgrade-compatible.
- Move chat-relevant rules from `AGENTS.md` into the chat node's `$PIRC_CONFIG_DIR/CHAT.md`; put persona text in global `SOUL.md`. Changes apply at the next agent start, not mid-run.
- Nix/store-managed files and symlinks are read-only in the web editor. Edit their original configuration instead.
- The first chat node registration is persistently bound. Before replacing that node, stop it and release the binding in Settings → Assistant; otherwise it may reconnect and reclaim the binding.

### Distribution and limits

- Local macOS ARM64 executables and web static assets accompany this release; source archives are provided by GitHub. Native archives are not Developer ID signed/notarized and do not bundle Chromium or ffmpeg.
- Android versionName is 0.2.0 and versionCode is 2. No Android APK or new native Android Context tab is included in this release.
- Linux/x86_64 binaries are not published or newly runtime-validated as part of this release. Nix packaging is retained.
- Token allocations are estimates scaled to matching provider input usage, not exact per-section tokenizer counts.

[Unreleased]: https://github.com/iceice666/pirc/compare/v0.7.0...HEAD
[0.7.0]: https://github.com/iceice666/pirc/releases/tag/v0.7.0
[0.6.1]: https://github.com/iceice666/pirc/releases/tag/v0.6.1
[0.6.0]: https://github.com/iceice666/pirc/releases/tag/v0.6.0
[0.5.0]: https://github.com/iceice666/pirc/releases/tag/v0.5.0
[0.4.1]: https://github.com/iceice666/pirc/releases/tag/v0.4.1
[0.3.0]: https://github.com/iceice666/pirc/releases/tag/v0.3.0
[0.2.0]: https://github.com/iceice666/pirc/releases/tag/v0.2.0
