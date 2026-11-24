# Client (Flutter, Android and Web)

[Open work](README.md) · [Roadmap M5–M10](roadmap.md#m5-client-foundation) · Design: [handoff](../docs/design/README.md), [rules](../docs/design/design-rules.md), [tokens](../docs/design/tokens.json)

One Flutter codebase replaces the Svelte web app (`apps/web`) and the current Flutter
UI (`apps/android/lib/live`). The native rendering engine (`apps/android/lib/rendering`)
is kept and extracted. This document records the architecture; facts about the
current code come from the 2026-11-24 inventories and cite paths so they can be
re-checked.

## Layout

```
pubspec.yaml                 Dart pub workspace (Dart ≥ 3.6)
apps/app/                    the Flutter application (android/, web/, lib/)
packages/pirc_client/        API models, transport, timeline reducer, repositories
packages/pirc_ui/            design tokens, theme, shared components, adaptive scaffold
packages/pirc_render/        chat content: Markdown, code, math, tables, images, HTML (static and forms), Mermaid
packages/pirc_render_document/  fetched documents and the script runtime (Android only; tier 3 lives here)
apps/android/                old app; keeps building until M8 deletes it
apps/web/                    old web app; keeps building until M9 deletes it
```

The Android application ID stays `dev.pirc.mobile` so the new app replaces the old
one in place.

## Transport

**Decision (Q5 default):** networking moves to Dart; Kotlin keeps only what needs
Android. Reasons: the Web build needs a Dart transport anyway; one implementation of
reconnect, cursors, command identities and the reducer is easier to keep correct
than three (TypeScript, Kotlin, Dart); embedded Tailscale (M10) then has one place to
plug in a proxy.

`pirc_client` defines a `Transport` with two adapters:

| Concern                 | Android adapter                                                                                       | Web adapter                                                                      |
| ----------------------- | ----------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| Identity                | `Authorization: Bearer <device token>`; token read from the Keystore through a small platform channel | Forward-auth cookie, same origin (`credentials: include`)                        |
| State-changing requests | `X-Pirc-Request: 1` on every non-GET                                                                  | Same                                                                             |
| HTTP                    | `package:http` over `dart:io` `HttpClient` (redirects off, so credentials never cross origins)        | `package:http` `BrowserClient` with credentials                                  |
| WebSocket               | `dart:io` `WebSocket` with headers                                                                    | Browser `WebSocket` (cookies and `Origin` sent automatically; no custom headers) |
| Proxy                   | `HttpClient.findProxy` → loopback proxy when embedded Tailscale is on (M10)                           | n/a                                                                              |
| Local storage           | Files and `shared_preferences`; drafts and first-send journal in app storage                          | IndexedDB / `localStorage`                                                       |

Shared logic in `pirc_client`:

- Event stream `/api/events` with cursor resume and the existing backoff
  (`min(20 s, 750 ms·2^n) + jitter`), early retry on connectivity regained or page
  visible, fatal close codes 4400/4401/4403/4404.
- The timeline reducer, ported from `apps/android/android/.../core/timeline/*.kt` and
  `apps/web/src/lib/state.ts`/`pi-messages.ts`, tested against `fixtures/timeline/`.
- Commands with client-generated IDs, uncertain-outcome markers, and the rule that an
  accepted request is never re-sent through another path.
- Control lease heartbeat (10 s visible, 15 s hidden) tied to visibility.
- Error mapping (`request_shape_required`, `client_upgrade_required`, 401 → pair again).

**What stays in Kotlin** (`apps/app/android`): Keystore credential store, UnifiedPush
service, notifications and their actions, the quick-reply overlay service, the QR
scanner, file/save pickers, share, clipboard images, drag-and-drop, the
`JavaScriptSandbox` script host, Canvas text fonts, media playback, AVIF decoding.

**Background client**: push receipt and the quick-reply overlay run without the Flutter
engine. They keep a slim Kotlin client (OkHttp from one factory, the same proxy as
Dart). To avoid keeping a second reducer, the Gateway gains compact endpoints for
them (M8): the current state of one interaction (question, choices, epoch, expiry,
control holder) and of one scheduled run.

**Management grants** move into Dart memory with the token. The earlier rule of keeping
them only in Kotlin added no real boundary inside one process.

## State

- Riverpod (`flutter_riverpod`), no code generation. Repositories in `pirc_client`
  expose streams; providers adapt them per screen. No controller over ~500 lines; the
  current `LiveController` (`apps/android/lib/live/gateway.dart`, 2,074 lines) is not
  ported as a unit.
- Every screen handles loading, empty, offline, failed, expired, read-only and retry
  (design rules).
- Layout changes keep the current conversation, scroll position, draft and right-pane
  content (design decision).
- **Startup and switching speed** (N3): measure first on the new client (time to first
  list, to first timeline, to switch). Then decide on cached first paint, paged
  history, incremental sync and on-demand panel loading.

## Rendering

The engine stays native on Android (N1). Tiers:

| Tier       | Scope                                                                                                                                                                                                     | Commitment                                                 |
| ---------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------- |
| 1 mainline | Markdown, code blocks (highlight, copy, scroll), tables, images and attachments, KaTeX-subset math, selection and copy, streaming without reflow, long conversations, keyboard and IME, common HTML forms | Regression tests, performance budget, defects are bugs     |
| 2 maintain | Mermaid (implemented diagram types), static HTML layout, SVG as image, fragment links, less common form controls                                                                                          | Keep and fix regressions; no expansion                     |
| 3 frozen   | Script runtime and DOM APIs, document cookies and storage, script resource lifecycle, advanced dialogs, Chromium pixel parity                                                                             | No expansion; safety, crash and isolation fixes still made |

Extraction (M5.2), from the inventory of `apps/android/lib/rendering`:

1. Break the import cycle: `native_html.dart`, `native_markdown.dart` and the
   background files import `live/` (`document_navigation_state`, `html_media`,
   `remote_content_gate`, `html_file_picker`, `document_object_urls`,
   `document_background_image`). Replace these with interfaces in a `RenderHost`
   passed down the tree: image loader, media factory, file picker, remote-content
   policy, link and form-submission handlers, document scope.
2. Inject localization (82 files call the app's `tr()`) and theme (7 files use
   `PircColors`) through a delegate and a `ThemeExtension`.
3. Split `native_html.dart` (6,895 lines) so the chat path no longer compiles in script
   hooks, Canvas, computed-style export and dialog top-layer code; those move to
   `pirc_render_document` with the `live/document_*` files (~13.5k lines) and their
   Kotlin counterparts.
4. Replace `dart:io` uses (`native_raster_images.dart`, `document_cache_policy.dart`)
   and the 64-bit `ByteData` accessors in `mermaid/mindmap_cose.dart` so the package
   compiles for Web.
5. Pin `flutter_math_fork` (42 imports of its internals) and record why.

**Web** (Q3 default): `pirc_render` (tiers 1 and 2) runs on Web unchanged. Fetched
documents and script-bearing HTML are shown by the browser in a sandboxed iframe
(`sandbox` without `allow-same-origin`, so the content has an opaque origin and no
access to the app's cookies, storage or API). The 7.2 MB Canvas-text WebAssembly and
the script runtime bundle are not shipped to Web.

## Web build (M9)

- CanvasKit and fonts are self-hosted (`--no-web-resources-cdn`, font fallback base
  URL), including Noto Sans TC and emoji; measure the first-load size.
- CSP: the current policy (`apps/web/csp-policy.ts`) plus `'wasm-unsafe-eval'` in
  `script-src`; no inline scripts (external bootstrap configuration).
- Flutter's generated service worker is disabled; the hand-written `sw.js` keeps the
  build ID, Web Push handlers, shell caching that refuses login redirects, and click
  routing; its cache rules are rewritten for Flutter's output.
- nginx: `Cache-Control: no-cache` for `index.html`, `flutter_bootstrap.js`,
  `flutter.js`, `version.json`, `sw.js` and unhashed engine files.
- Web-only features to carry over: Web Push, the management approval screen
  (`/?nativeManagement=<id>`), creating a pairing and its QR, PWA install and the
  update prompt, link parameters used by notifications (`session`, `interactionId`,
  `open=…`, calendar parameters).
- Development: a same-origin dev proxy to the Gateway with WebSockets; the dev origin
  goes in the allowlists.

## Design system and layouts

- Tokens from `docs/design/tokens.json` (C, D and E): colors (primary #4B6BA6, ink send
  button, avatar colors, working-status color), type scale, radii, shadows, sizes.
- One separation per surface: raised = shadow, grouped = fill, hairlines only in lists
  and tables. Dark mode by lightness steps. Lucide line icons. Touch targets ≥ 44–48.
- Layouts by available width (design decisions):

| Width    | Structure                                                                                    |
| -------- | -------------------------------------------------------------------------------------------- |
| ≥ 1200   | Rail 72, list 340, content (conversation max 760, settings max 720), optional right pane 400 |
| 900–1199 | Rail 76, list 320, content; right-pane content replaces the middle                           |
| 600–899  | Rail 76, one pane; opening an item replaces the list; info slides in from the right at 440   |
| < 600    | One screen and a bottom tab bar (56)                                                         |

- The drawer (☰) pushes the page instead of covering it. Badges on tabs are yellow.

## Inherited from the Flutter 0.5 prototype

Branch `archive/flutter-mobile-0.5`, `apps/mobile` and `pirc-mobile-handoff`:

- Quick-reply overlay above other apps; buttons disabled until state is confirmed;
  answered elsewhere, expired, offline, no-control and unknown-outcome states.
- Rich notifications with up to three preselected answers that open the app, re-fetch
  state and only then show the preselection; nothing is sent from the notification.
- Notification settings: categories, lock screen, do-not-disturb, per-workspace mute.
- `pirc-artifact` result blocks with explicit version switching that keeps each
  version's reading position (C 3A).

## Testing

- Default suite per package: fast, no device, no Node, no macOS-only fonts. Tags:
  `tier3`, `node` (needs the JS runtime in Node), `fonts` (needs Arial/Menlo),
  `device` (integration tests). `dart_test.yaml` declares them.
- Safety regressions (credential attachment, opaque origins, remote-content gating,
  content containment, request shapes) are in the default suite regardless of tier.
- Old Flutter tests are deleted with the code they test; renderer tests move with the
  renderer and are tagged.
- Visual checks: golden screenshots at phone, tablet portrait and landscape, and
  desktop widths, light and dark, compared with `docs/design/screenshots/`.
