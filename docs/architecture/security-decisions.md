# Security decisions and limitations

This is a current boundary/decision reference, not an audit certificate or a list of historical vulnerabilities. Operational setup is in [Sandbox and browser](../deploy/sandbox-and-browser.md), [deployment](../deploy/README.md) and [secrets](../deploy/secrets.md). The Rust implementation, not old TypeScript audit paths, defines enforcement.

## Trust boundary

The supported deployment is **one person**, possibly using several allowed identities, not hostile multi-tenancy. Workspaces have no separate owner: allowed identities can manage workspace settings, trust, links and schedules. Sessions and assistant records still have ownership checks. Listing all directory workspaces in assistant context is intentional. Push endpoints have HTTPS/no-userinfo/no-redirect checks but no private-address filter, per-user subscription cap or test throttle; authenticated HTTP APIs have size limits, not a general request-rate limiter. These are accepted single-user trade-offs, not safe defaults for unrelated users sharing a gateway.

Agents must start inside the native OS sandbox; unavailable confinement fails closed. Auto-mode classification and file-tool checks are additional, advisory layers, not substitutes for the OS boundary. `full-access` changes confirmations, not the mandatory sandbox, deny-list or write lease. Project hooks, environment, allowed paths and default model require the user's content-hash trust. Repository role files may replace node roles wholesale; their source/override is exposed rather than restricted to narrowing permissions.

Panel terminals are deliberately unsandboxed login shells and enabled by default (`PIRC_TERMINALS=0` disables them). Approved `unsandboxed_bash` also runs outside the sandbox. The Git panel is different: it runs git in `Sandbox::prepare_readonly`, with the session's read policy, only temporary writes and no network; repository filters must not run unconstrained on the host.

The optional reverse-proxy shared secret must be configured if other processes can reach the trusted proxy-facing listener; trusted source IP alone does not identify the proxy process. User-configured model backend URLs may use HTTP for LAN/tailnet services. Generic host names retained in examples are not secrets. None of these choices authorizes exposure to untrusted users or networks.

## Rendered content from messages, tools and files

Text from agents, tools and workspace files is shown, but it is not the app. The Web client applies these rules (the Android app has its own gate for the same first rule):

- **Remote images and media load only on the user's click.** Nothing in such content makes a request by itself: the sanitiser removes every attribute that would fetch a remote source (images and `srcset`, `picture`, `video` and `audio` sources and posters, `input type=image`, SVG `image`/`use`/`feImage`, `url()` in styles, link preloads, `ping`, refresh, legacy `background`/`lowsrc`/`dynsrc`) and a placeholder shows the alternative text and the source address with a button. The button opens the address in a **new tab**, straight from the user's device, without a referrer or opener. There is no image proxy in the Gateway. `data:` images still display.
- **An address is not trusted for its shape.** A relative or same-origin URL in content is gated like any other. Images the app itself shows (attachments, file previews) are loaded by the app from identifiers it holds, not from addresses written in content.
- **Content stays in its box.** Rendered content cannot paint over, cover or intercept the controls around it (fixed or absolute positioning, oversized or transformed boxes, `z-index`); the content box clips and isolates it. Diagrams are shown as images, which are separate documents: their styles cannot reach the page and they load nothing of their own. Raw CSS from a diagram (`themeCSS`) is not accepted.
- **The page has a Content-Security-Policy** (a `<meta>` element written into `index.html` by the build) that allows its own scripts and styles and images only from itself or inline, as a second line behind the sanitiser; the static server adds `frame-ancestors 'none'`, `X-Frame-Options`, `Referrer-Policy: no-referrer` and `X-Content-Type-Options: nosniff` ([reverse proxy](../deploy/reverse-proxy.md#security-response-headers)). `form-action` is not set: forms in messages may submit to other sites by design.
- **Pages learn about new releases.** Each build gives `sw.js` its own bytes so that an open page is offered the update, and a request the Gateway refuses as out of date shows a reload prompt.

Browser checks for these rules are in `apps/web/tool/browser/` (see the web [README](../../apps/web/README.md#browser-checks)).

## S10: host replacement of Linux protected paths

**High risk, accepted by the user on 2026-10-12; not fixed.** Linux can detach another mount namespace's bind mount when the host unlinks or atomically replaces the protected file. A running sandbox may then see the replacement through its writable parent without the original read/write restriction.

Examples include host `git config`/`git push -u` replacing `.git/config`, checkout/pull replacing tracked protected configuration, and an editor's atomic save of `.env` or shell startup files. The agent could read a replacement secret or alter git configuration that executes code on a subsequent host git command. Ancestor pinning prevents agent-side renames; it does not prevent this host-side replacement.

Mitigations considered but not implemented:

- Watch for replacements and terminate the session: leaves a race and interrupts ordinary host git/editor workflows.
- Audit program-running git configuration after the session: detects only part of the problem and does not prevent it.

Avoid replacing protected paths from the host while agents run. If replacement is needed, stop affected agents first and start new sandboxes afterwards. Implementation: `crates/pirc-node/src/sandbox/linux/plan.rs`.

## S18: browser filtering is not network confinement

**High risk, accepted by the user on 2026-10-12; not fixed.** Chromium runs outside the agent sandbox and with its own renderer sandbox disabled (`--no-sandbox`). The node's URL/host guard is not an OS network boundary.

The native CDP `Fetch` guard checks navigations, redirect hops and intercepted HTTP requests, including service/shared-worker requests through worker guards and a browser-session backstop. Service-worker registration is blocked by an injected script, but a page can bypass that script; workers that run still receive HTTP guarding. It is incorrect to claim that workers are disabled absolutely or that all browser connections are checked.

Remaining gaps:

- WebSockets use a page-world mock that hostile page JavaScript can bypass; dedicated/shared/service-worker sockets have no equivalent guard. Local services that fail to validate WebSocket Origin can be reachable for reads and writes.
- Preconnect, WebRTC STUN/TURN and WebTransport are outside `Fetch` interception. WebTransport's gap is documented in the implementation, not established here by a runtime test.
- Chromium resolves DNS independently of the guard, leaving DNS-rebinding exposure.

A node-local proxy guarding every browser connection was considered but not implemented; merely hardening the page mock would not cover workers. Keep the node account minimal, do not log into the pirc UI in its persistent agent-browser profiles, and do not treat `PIRC_BROWSER_ALLOW_PRIVATE`/`BLOCK_HOSTS` as a comprehensive network firewall. Implementation: `crates/pirc-node/src/browser/engine/network.rs`, `browser/hosts.rs` and `browser/engine/launch.rs`.

## Delegation approval

**Decided by the user on 2026-10-19.** Delegation is no longer a human-only operation when a chat workspace's `delegation_approval` is `untrusted` or `never` ([chat projects guide](../guides/chat-projects.md#delegation)). The default for new and existing chat workspaces stays `always`: every delegation waits for the user's card. The user switches per project.

- `untrusted` starts a delegation without the card only when the chat agent reports that everything since the user's last message came from the user or the assistant itself (`origins`); any tool result or custom message (a delegation report), or an older agent that reports nothing, falls back to the card. `never` never asks. At most 4 such delegations run per user; more wait for the card.
- **Residual risk accepted with `never` (and `untrusted` within one turn of user words):** a prompt injection in content a chat reads can have the assistant delegate, and in the delegated session auto mode judges destructiveness, not intent. An injected task can change and commit code in a workspace, push where git credentials are configured for the sandbox, and install packages from default registries without a prompt. The sandbox (default and approved domains only, no credential stores, no writes outside workspace, explicitly allowed paths and temporary storage), auto mode's danger rules, the deny list, the node default approval mode of delegated sessions, the chat's visible running-delegation card with Stop, and the audit columns remain. Single-user, private-network deployments only.
- The delegated run's classifier reads only quotes the chat's agent found verbatim in the user's last three messages (`find_recent_quote`), delivered as `details.userRequests`, never the assistant-written task. A quote can still be taken out of context within that window; the classifier's rule that only an exact operation on an exact target authorizes still applies, and static danger never reaches the classifier.
- **Relayed approvals:** a delegated session's confirm dialogs are shown in the chat that started it and may be answered there, from Needs you or from a notification by the owning user **without the delegated session's control lease** (the gateway checks the user, the chat and that the dialog is still relayed, then calls the node's gateway-only `relayed-answer` route, which accepts only a confirm's yes/no). Agent text never answers; the node still decides. Stop takes the delegated session's lease only when no client holds it.
- Not built: "allow again in this session" and soft/hard danger categories (plan phase 3). If built later, remembered allows are exact text in the same working directory only, may include `unsandboxed_bash`, and never cover deny-list matches (decided 2026-10-19).

## Other accepted limits

- **Filesystem planning:** Linux binds resolve paths at startup. Retargeted symlinks between planning and mounting, or pre-existing hard links in otherwise writable locations, can defeat path-based assumptions. The session's own agent cannot create a cross-mount hard link to an already protected file, but another actor may prepare one. Missing protected paths use placeholders visible on the host; nested repository scanning has a depth limit of three.
- **Unix sockets:** Linux hides sockets found at planning time (with explicit exceptions), not every later connection. New sockets, sockets from another network namespace, relative-path sockets and later SSH-agent directories can remain reachable. The inference socket, explicit `allowUnixSockets` and the Nix daemon are exceptions; per-session proxy sockets require their token. WSL's interop directory is hidden whole. The current Linux seccomp filter blocks vsock/io_uring paths; it is not a Unix-socket path allowlist.
- **Nix and caches:** the Nix daemon is reachable by default and can fetch beyond the proxy; auto mode classifies requests, while full access does not. The shared writable host-cache decision was reopened on 2026-10-20: host caches are now read-only and cache environment variables use session-private temporary paths. This does not sanitize caches poisoned before the upgrade. Do not give the node account unnecessary host privileges such as Docker-group membership.
- **macOS:** `allowLocalBinding` permits access to loopback ports, not just an individual development server. Other sessions' proxies still require authentication. Native QuickJS guests have fd/resource restrictions on macOS, but not Linux's seccomp allowlist.
- **Private state under broad writable roots:** allowing a broad root such as home weakens protection of files created later beneath private directories; the builtin session directory and assigned ledger are now write-denied and persisted by the node, but other files first created beneath broad private roots after planning can remain exposed. Avoid unnecessarily broad `allowedPaths`.
- **Development stand-in:** `PIRC_SANDBOX_SRT` is not the production native backend and retains different confinement gaps. Do not use it as evidence for native security guarantees or as a production replacement.
- **Memory and authorization:** provenance labels and secret redaction are best effort; forgetting does not erase retained transcripts or frozen snapshots and cannot detect paraphrases. Repository identity may follow git-directory references to another readable repository; it joins only same-user records and grants no authorization. See [assistant memory](assistant-memory.md).
- **Schedule operations:** create/update/delete proposals require the user's approval; pause/resume remain direct by decision. No accepted decision allows a node token or agent text to approve a human-only operation; delegation stops being one only under the user's own `delegation_approval` setting (see above).

## 2026-10-20 sandbox report follow-up

Same-account daemons register private directories before use, and each new sandbox reads that registry. Existing sandboxes are snapshots; newly registered paths require restarting sessions. Linux agent and PTC processes disable dumpability to protect their private pipes from same-UID tools. Builtin state persistence uses a scoped node-side writer and a per-run capability, while custom agent executables remain responsible for an equivalent boundary. Host caches are read-only; additional credential paths and standard WSL Windows-user mounts are hidden. Native Git guards cover existing repositories without creating a phantom `.git` for a new repository. See [sandbox deployment](../deploy/sandbox-and-browser.md).

Validation uses synthetic stores/caches only. Local macOS native tests do not establish Linux/WSL enforcement; Linux CI includes the same-account, process-pipe, state-custody and real-agent regressions. The broader mount-detach and browser-network decisions above remain unchanged. Updating does not remove previously poisoned caches or existing memory entries.

## Evidence and historical decisions

Accepted risks remain accepted unless the user explicitly reopens them. This reference does not authorize mitigation work, live deployment, credential use, paid evaluations or deletion of state.

The Rust cutover's remaining full PTC/task-time comparisons and complete real-provider wire-API/subscription smoke matrix were explicitly waived on 2026-10-14. A waiver is not a passing evaluation. Later scoped smoke checks do not establish that whole matrix. Any new paid comparison needs an agreed baseline, protocol, account scope and budget.

Historical findings, rationale, compatibility differences and dated validation are recoverable from Git:

```sh
git show af7074fc51742e79c8f0c76a9aaf64f80b414f7e:docs/history/security-audit.md
git show af7074fc51742e79c8f0c76a9aaf64f80b414f7e:docs/history/rust-rewrite.md
```

Those records include superseded findings and old implementation paths. Historical passes, fake-provider tests and fake-CDP tests are not evidence of current exploit resistance, live-provider behavior or real-browser coverage. For current validation commands and platform scope, use [development workflow](../../README.md#development).
