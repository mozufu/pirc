# Cross-layer checks (scripts/e2e)

Scripted, re-runnable checks that start the real `pirc-gateway` and `pirc-node` with fresh temporary state and
exercise them from the layers a user touches. They run with the system `node` (no bun), need the repository's
`node_modules` (`playwright-core`, Vite) and a built tree, and clean up after themselves.

```sh
node scripts/e2e/run-all.mjs                    # V1 + V2 + V3 (builds the current Gateway and Node first)
node scripts/e2e/run-all.mjs --only v1          # a subset: v1, v2, v3
node scripts/e2e/run-all.mjs --old-sanitiser    # also V1 against the web app of 645b262f (see below)
node scripts/e2e/run-all.mjs --web-tree <dir>   # V1 against another checkout's apps/web
```

Each script can also run alone (`node scripts/e2e/v1-hostile-forms.mjs`) and exits non-zero on a failure. Set
`PIRC_E2E_SKIP_BUILD=1` to reuse `target/debug`; `PIRC_E2E_ARTIFACTS=<dir>` keeps screenshots of failures and of the
old UI. Run directories are short paths under `/tmp` (`PIRC_E2E_TMP` overrides): the nodes bind a Unix socket below
them and macOS limits that path to about 100 characters.

## What is real, and what is not

- Real: the Gateway and Node executables, their SQLite and file state (fresh per run), the dedicated test browser
  (`scripts/e2e/test_browser.mjs`, a headless shell with a new temporary profile; the everyday Chrome is never
  started), and the web app (Vite dev server over `apps/web`).
- A local Node adapter (`startAdapter` in `lib.mjs`) plays the trusted proxy: it strips client-supplied identity and
  proxy-secret headers, adds the fixture identity, Host/Origin and (V2) the proxy secret, and forwards everything else.
- The memory proposals are made by the real chat node: a scripted OpenAI-compatible model server returns the
  `memory_propose_user` call, and the Gateway stores the proposal. Approving one makes the active entry.
- Not real: a nginx, Caddy or Traefik (none is installed; installing one needs the owner's approval), an APK, an
  emulator or a device.

## V1 `v1-hostile-forms.mjs`: hostile forms in a real browser

A Markdown file in a workspace holds forms that POST to the app's own memory approve / reject / forget routes and
to the project-file write route (urlencoded, multipart, text/plain, text/plain shaped as JSON, empty, a button
`formaction`), and forms to a local external receiver. The Files panel previews it and the submit buttons are clicked
for real.

- Phase 1 is the preview as the app renders it. What the sanitiser leaves of each form is recorded (a sanitiser that
  drops same-origin actions makes these forms post to the page itself, not the Gateway).
- Phase 2 serves the same forms as raw HTML on a same-origin page, so they always reach the Gateway: every one must be
  refused `415 request_shape_required`.
- Asserted through the API: the proposals still pending, the entry still active, the project file's bytes unchanged.
- Controls: the external receiver gets its fields intact (all three encodings); and the same routes accept a request
  carrying `X-Pirc-Request`, so the refusals are the request shape and not a wrong route.
- `--old-sanitiser` repeats V1 against `apps/web` of 645b262f, whose sanitiser keeps same-origin actions: the
  previewed forms then do reach the Gateway (20 POSTs, all 415) and the state is still unchanged.

The run prints the commits it covered (`coverage`): HEAD, the last commit touching the sanitiser and the Gateway,
and uncommitted changes in `apps/web` and `crates` (a run over a dirty tree is labelled by that list).

## V2 `v2-proxy.mjs`, `v2-proxy-config.mjs`: a reverse proxy and `X-Pirc-Request`

- `v2-proxy.mjs`: writes and uploads through the Node proxy, the Gateway running with `PIRC_PROXY_SECRET`. JSON write,
  body-less write with the header, raw upload with the header: success. The same without the header: 415. Also a wrong
  value, a doubled header, a spoofed client identity, bypassing the proxy, and a "lossy" hop that drops the header
  (JSON still works, body-less and raw uploads get 415: the symptom of such a proxy).
- `v2-proxy-config.mjs`: a static reading of `nix/module.nix` (Nix is not evaluated) and
  `docs/deploy/reverse-proxy.md` for anything that would drop, overwrite or limit `X-Pirc-*` request headers.
  Informational lines (never failures) list what the docs do not say.

## V3 `v3-compat.mjs`: old and new web clients against old and new Gateways

OLD is commit 645b262f (before the request-shape rule). The script creates a temporary detached worktree of it, builds
its Gateway and Node into `target/suites/compat-645b262f` (kept as the build cache) and removes the worktree at the end.
Each Gateway gets its own fresh state.

| Client  | Gateway     | Expected                                                                                                                             |
| ------- | ----------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| Web new | Gateway new | JSON writes, body-less writes and raw uploads succeed                                                                                |
| Web new | Gateway old | the same operations succeed (the old Gateway ignores the header)                                                                     |
| Web old | Gateway new | JSON succeeds; body-less writes and raw uploads get `415 request_shape_required`; the old UI is driven and what it shows is recorded |
| Web old | Gateway old | baseline: everything succeeds                                                                                                        |

The web cells run the app's own api modules in the test browser (so the requests are the ones the app builds); the
old-Web cell also drives the project Settings file input, the composer's attach control and an unread chat. The old
Android JVM App cells were retired with the M8 cutover; their harness and instructions remain in the pre-cutover
commit described in [historical records](../../docs/development/historical-records.md#old-android-client-m8-cutover).
