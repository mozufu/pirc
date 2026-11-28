# Client (Flutter, Android and Web)

[Open work](README.md) · [Roadmap M5–M12](roadmap.md#m5-client-foundation) · Design: [handoff](../docs/design/README.md), [rules](../docs/design/design-rules.md), [tokens](../docs/design/tokens.json)

One Flutter codebase replaces the Svelte web app (`apps/web`) and the current Flutter
UI (`apps/android/lib/live`). The native rendering engine (`apps/android/lib/rendering`)
is kept and extracted. This document records the architecture; facts about the
current code come from the 2026-11-24 inventories and cite paths so they can be
re-checked.

## Layout

```
pubspec.yaml                 Dart pub workspace (Dart ≥ 3.6)
apps/app/                    the Flutter application (android/, web/, macos/, lib/)
packages/pirc_client/        API models, transport, timeline reducer, repositories
packages/pirc_ui/            design tokens, theme, shared components, adaptive scaffold
packages/pirc_render/        chat content: Markdown, code, math, tables, images, HTML (static and forms), Mermaid
packages/pirc_render_document/  fetched documents and the script runtime (Android only; tier 3 lives here)
apps/android/                old app; keeps building until M8 deletes it
apps/web/                    old web app; keeps building until M11 deletes it
```

The new app's Android application ID and macOS bundle ID are `org.mozufu.pirc`
(owner decision, 2026-11-26; M5 built it as `dev.pirc.mobile`). The old app is
`dev.pirc.mobile.preview`, so the two install side by side: a user of the old app
pairs the new one again and then uninstalls the old one by hand (P5, M8).

## Transport

**Decision (P17):** networking moves to Dart; Kotlin keeps only what needs Android.
Reasons:

- **Speed.** Today every request and event crosses the method channel twice as
  serialized maps, and Kotlin re-emits the whole reduced session snapshot to Dart up
  to every 32 ms (`GatewayRuntime.kt` `startSessionWatch`). With the reducer in Dart,
  events are applied in place and only changed widgets rebuild.
- **Resources.** The costly part on a phone is background work. Push receipt and the
  quick-reply overlay keep running in Kotlin without starting the Flutter engine, so
  moving foreground networking to Dart does not add background cost.
- **One implementation.** The Web and desktop builds need a Dart transport anyway;
  reconnect, cursors, command identities and the reducer are kept correct once
  instead of three times (TypeScript, Kotlin, Dart). Embedded Tailscale (M12) then
  has one place to plug in a proxy.
- **Escape hatch.** HTTP goes through the `package:http` `Client` interface. If
  measurements show `dart:io`'s HTTP/1.1 client is a bottleneck on Android, swap in an
  OkHttp- or Cronet-backed `Client` (`ok_http`, `cronet_http`) without touching callers.

`pirc_client` defines a `Transport` with two adapters. The macOS desktop build uses
the Android (`dart:io`) adapter with a device token kept in the macOS Keychain; it
pairs like a phone.

| Concern                 | Android adapter                                                                                       | Web adapter                                                                      |
| ----------------------- | ----------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| Identity                | `Authorization: Bearer <device token>`; token read from the Keystore through a small platform channel | Forward-auth cookie, same origin (`credentials: include`)                        |
| State-changing requests | `X-Pirc-Request: 1` on every non-GET                                                                  | Same                                                                             |
| HTTP                    | `package:http` over `dart:io` `HttpClient` (redirects off, so credentials never cross origins)        | `package:http` `BrowserClient` with credentials                                  |
| WebSocket               | `dart:io` `WebSocket` with headers                                                                    | Browser `WebSocket` (cookies and `Origin` sent automatically; no custom headers) |
| Proxy                   | `HttpClient.findProxy` → loopback proxy when embedded Tailscale is on (M12)                           | n/a                                                                              |
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
control holder) and of one scheduled run. Besides answers and schedule decisions, the
client sends one more request: the overlay's send takes the control lease
(`…/control/acquire` with `force`) when another device holds it.

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

**Web** (P15): `pirc_render` (tiers 1 and 2) runs on Web unchanged. Fetched
documents and script-bearing HTML are shown by the browser in a sandboxed iframe
(`sandbox` without `allow-same-origin`, so the content has an opaque origin and no
access to the app's cookies, storage or API). The 7.2 MB Canvas-text WebAssembly and
the script runtime bundle are not shipped to Web.

**Desktop** (P14, P34): macOS uses `pirc_render` for tiers 1 and 2. Like Android
today, pirc 0.11.0 opens no script document on macOS: script-bearing HTML is shown
statically, its scripts not run, with a note that it holds scripts. When script
documents get an entry point on every platform, macOS shows them in a `WKWebView` with
a non-persistent data store, no script message handlers (no bridge to the app, no app
credentials), an opaque origin (no base URL), every network load blocked by a
`WKContentRuleList` unless the user activates remote content, navigation and new
windows refused, and no file access: the desktop counterpart of the Web iframe.
Desktop has no background push; notifications are shown while the app runs.

## Embedded Tailscale (M12)

Android first (P16). The deployment is reachable only inside the tailnet (Gateway,
nginx and Authelia), on the official Tailscale service.

- **Two Android build variants**, both shipped for every release:
  - `standard`: no Tailscale code; reaches the Gateway through the device's network
    (system Tailscale app, LAN or VPN). Smaller, and the default for development.
  - `tailscale`: the same app plus the embedded node described below.

  They are Gradle product flavors (`flutter build apk --flavor standard|tailscale`)
  with the Dart side selected by `--dart-define=PIRC_TAILSCALE=true|false`; the
  `standard` flavor must not link the native library. They share the application ID
  base but install side by side (`org.mozufu.pirc` and `org.mozufu.pirc.tailscale`),
  so both can be tested on one device; pairing and data are per install. Release
  artifacts are named `pirc-<version>-standard.apk` and `pirc-<version>-tailscale.apk`.
  CI builds both variants. Desktop and Web have only the standard build for now.

- The `tailscale` flavor links a userspace tailnet node (`tsnet` through libtailscale
  or a gomobile binding). It does not use Android's `VpnService`, so it works while the
  system Tailscale app is off and does not take the device's single VPN slot.
- The node exposes a loopback HTTP CONNECT proxy. The Dart `HttpClient` (via
  `findProxy`) and the Kotlin background client (OkHttp `proxy`) both use it; nothing
  else in the app needs to change.
- Sign-in: the app starts the node, shows Tailscale's login URL in an in-app browser
  tab, and stores the node state (its keys) in app-private storage encrypted with a
  Keystore key. The phone becomes its own device in the tailnet; tailnet ACLs apply.
- Background: the node runs while the app process runs. Push still arrives through
  UnifiedPush (outside the tailnet); handling a push that needs the Gateway starts the
  node first, with a timeout, before the background client calls it.
- Spike questions: binary size, battery use with the node idle, start-up time from a
  push, behavior when both the system Tailscale and the embedded node are on.

## Web build (M11)

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
