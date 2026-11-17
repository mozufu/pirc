# pirc web client

Standalone Svelte 5 + TypeScript + Vite client for the pirc gateway. This package intentionally uses no SvelteKit server runtime; the build is a static bundle (`dist/`) that any web server can serve (see [`docs/deploy/reverse-proxy.md`](../../docs/deploy/reverse-proxy.md)).

## Commands

From the repository root:

```sh
bun install
bun run dev:web
bun run --filter @pirc/web typecheck
bun run --filter @pirc/web test
bun run --filter @pirc/web build
```

Vite proxies `/api` and WebSocket upgrades to `http://localhost:8787` in development (`vite.config.ts`).

## Runtime behavior

- Fetch requests include forward-auth cookies with `credentials: include`.
- Session snapshots are reduced with sequenced WebSocket events; reset or epoch mismatch requests a fresh snapshot. The reduction is shared with the Android client through the golden cases in [`fixtures/timeline`](../../fixtures/timeline/README.md).
- Drafts are stored per session in local storage. Offline drafts are **never** automatically submitted after reconnecting.
- Only hashed Vite assets below `/assets/` are cached by the hand-written service worker. HTML, API responses, conversations, uploads, and credentials are never cached.
- A waiting service worker shows an update prompt and does not force a page reload. Every build stamps its own identifier into `sw.js` (`sw-build-id.ts`), so a release is noticed by pages that are already open.
- A request the Gateway refuses with `request_shape_required` (a page older than the request-shape rule) shows a reload prompt.
- Remote images and media in rendered content load only on the user's click, in a new tab (`src/lib/remote-content.ts`); rendered content is contained in its box (`src/markdown.css`); diagrams are shown as images.
- The build writes a Content-Security-Policy `<meta>` element into `index.html` (`csp-policy.ts`); the dev server does not have it.
- If the API is unavailable in development, the interface loads local preview data (`src/lib/mock.ts`) so the full layout remains reviewable.

## Browser checks

`tool/browser/` has checks that need a real browser (the repository's dedicated test browser with a new temporary profile; never an everyday Chrome). Run them from `apps/web`:

```sh
node tool/browser/ui-integrity.mjs      # content cannot cover or restyle the UI outside its box
node tool/browser/remote-content.mjs    # no request before a click; the click opens one new tab
node tool/browser/csp.mjs               # zero policy violations on the main screens (needs the pirc-gateway and pirc-node binaries)
node tool/browser/update-flow.mjs       # an open page is offered a new release and replaces its shell
```

## API contract

The gateway API is documented in [gateway and node reference](../../docs/development/gateway-and-node.md#api); the client's types live in `src/lib/types.ts` and the calls in `src/lib/api.ts`. Points that differ from what a generic client might assume:

- List endpoints return envelopes (`{ sessions }`, `{ workspaces }`, `{ models }`), not bare arrays.
- `POST /api/sessions` takes only `{ workspaceId }`; the agent titles the session from the first message. `PATCH /api/sessions/:id` renames, pins or settles it.
- Commands carry a client-generated `commandId` plus `{ clientId, generation }` from a live control lease.
- The control lease is `POST /api/sessions/:id/control/{acquire,heartbeat,release}`.
- Interaction answers are `POST /api/sessions/:id/interactions/:interactionId/answer` with `{ clientId, generation, answer }`.
- Uploads are raw request bodies (`POST /api/sessions/:id/uploads?filename=…`, the file's content type as `content-type`), not multipart.
- WebSocket messages are `EventEnvelope` JSON objects with a cursor, numeric sequence, runner epoch, and typed event payload.
- JSON errors use `{ error: { code, message, details? } }`.
