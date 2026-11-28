# M8 step 6: port of the old document runtime (working note)

A working note for the rest of [roadmap](roadmap.md) M8 step 6. Delete it when step 6
closes. Part 1 is commit `3ac162b9`.

**Groups B and C are on hold: pirc 0.11.0 has no entry point for script documents (owner
decision, 2026-11-27).** Step 6 stops after group A. The rest of this note is what B and C
start from if an entry point is chosen later.

## Entry point

There is none in 0.11.0 today, and the Gateway serves no documents.

- The old app opened document windows only for pages of the paired Gateway origin. These
  were the web app shell, its same-origin links and forms in messages
  (`NativeDocumentSubmissionHost` in `apps/android/lib/live/common.dart:283`,
  `openNativeDocument` in `live/document_navigation.dart:167`), and
  `<a download>`. Plain `http(s)` links in messages went to `external`
  (`common.dart:251-263`). Kotlin fetched those documents with the device token and the
  pairing's cookies (`GatewayRuntime.document`, `NativeDocumentTransport`).
- The 0.11.0 Gateway has `/api/*` JSON, the session relays (`files`, `files/content`,
  `git`, `panel`) and a 404 fallback (`crates/pirc-gateway/src/app.rs:377-488`). It has
  no web app shell and no HTML route.
- `apps/app` passes no link handler to `NativeMarkdown` (`work/timeline.dart:195,235`,
  `work/result_reader.dart:401,441`). `ResultReader` shows any artifact type other
  than markdown, code and table as "unsupported" (`work/artifacts.dart:28`), as
  `docs/design/design-rules.md:102` says. Design E has no document view.

Entry-point candidates, for when one is chosen:

1. A `pirc-artifact` with `type: "html"` opens in `ResultReader` (full screen or side) as
   a document from a message: opaque origin, no URL of its own.
2. An `.html` file from the files panel (`files/content` through `pirc_client`) opens the
   same way, as a document from a tool result.
3. `http(s)` links in messages and documents open in the system browser
   (`platform/links.dart`). No remote navigation happens inside the app.

With only 1–3, most of group B goes. The script runtime keeps in-document
history (`pushState`, fragments) without network navigation. If remote navigation is
wanted, B needs a new Kotlin `document` kind: a no-cors top-level fetch, still with no
credentials and to public addresses only.

## Groups and order

The groups follow the import closure. `document_scripts.dart` imports style loading,
dynamic styles and script images, so they move with it.

- **A (done in part A):** `document_environment`, `document_origin`, `document_referrer`,
  `document_script_resources`, `document_script_images`, `document_style_loading`,
  `document_dynamic_styles`, `document_scripts`. Also new: `document_resource_limiter`
  (the 6-in-flight queue) and `document_integrity` (SRI).
- **B (on hold):** `document_cache_policy`, `document_response_cache`, `document_navigation_state`,
  `document_window_manager`, and the old `document_download` (merge it into the part-1
  `document_download.dart`). Most of B goes if no remote navigation is wanted.
- **C (on hold):** `document_navigation` (the fetched-document view), the `apps/app` wiring
  (`fetchedDocumentHost`, the entry point, `RenderHost.documentRuntime`), and the
  remaining tests. `app_document_route` and `app_document_shell` recognise the web app
  shell served by the Gateway. 0.11.0 serves no shell, so they are not ported: notification
  and link routes are `apps/app/lib/src/router.dart` and `notifications/`.

## Call sort

(i) Old Kotlin bridge calls, now the `scripts` channel or Dart:

| Old call                                   | New                                                                             |
| ------------------------------------------ | ------------------------------------------------------------------------------- |
| `documentScriptCapabilities`               | `capabilities()`; `canvasTextSupported` → `canvasText`                          |
| `documentScriptOpen`                       | `open()`, then `loadRuntime()` (Kotlin reads the runtime from the APK)          |
| `documentScriptCanvasTextResources` + glue | `canvasText()`: Kotlin runs the glue and `__pircInitializeCanvasText`           |
| `documentScriptEvaluate`                   | `evaluate()`                                                                    |
| `documentScriptStorage`                    | `storage()`                                                                     |
| `documentScriptCookies`                    | `cookies()`                                                                     |
| `documentScriptResource` / `…Cancel`       | `resource()` / `cancelResource()`, through the per-session limiter              |
| `documentScriptClose`                      | `close()`                                                                       |
| `resolveDocumentUrl` (local Kotlin)        | Dart `resolveNativeDocumentUrl` (`pirc_render/lib/src/html_document_urls.dart`) |
| `documentStylesheet` (initial CSS)         | `resource(kind: stylesheet)` (B, when the view loads its initial sheets)        |
| `gateway.events` `documentStorageChanged`  | dropped: storage is per session, so no other writer exists                      |
| `documentStorageWindowOpen/Close`          | dropped: no shared `sessionStorage` across windows                              |

(ii) Old Gateway HTTP calls. None has a 0.11.0 route:

| Old call                 | New                                                                              |
| ------------------------ | -------------------------------------------------------------------------------- |
| `document`               | none; only if remote navigation is wanted (new Kotlin kind, never `pirc_client`) |
| `documentPrepareRequest` | dropped (it gave a cookie key for the Gateway-origin jar)                        |
| `boot` (pairing stamp)   | dropped: the scope's `accountIdentity`, and `closeAll` on unpair                 |
| `saveDocument`           | `FilesPlatform.save` through `DocumentDownload` (part 1)                         |
| `files/content` (new)    | `pirc_client`, only if candidate 2 is picked                                     |

## Field mapping

Old `documentScriptOpen` took `{owner, documentUrl, blobCreatorUrl?, storageSessionKey?}`
and returned `{id, cookieState?, storageState?}`. The new one takes `{owner}` and returns
`{id, origin: "null"}`.

- `documentUrl`: kept in Dart as the location URL. It goes to `__pircDocument.init`.
- `blobCreatorUrl`: dropped; B derives a blob document's origin in Dart if it keeps blob
  navigation.
- `storageSessionKey`: dropped. Each session has its own `sessionStorage`.
- `cookieState` `{generation, url, cookies, protections, secureOrigin, sameSiteContext,
allowedDomainSuffixes}`: derived in Dart from the session's cookie string. Each pair becomes
  a host-only, path `/`, session cookie. `generation` is a Dart counter per session.
  `protections` is empty. `allowedDomainSuffixes` is the host. Writes go to Kotlin as lines.
- `storageState` `{generation, revision, origin, sessionKey, quotaBytes, local, session}`:
  derived in Dart from `storage()`. The generation is per session, and the revision goes up
  only when the areas change. `origin` is the location URL's origin. `quotaBytes` is 5 MiB, the same as
  `DocumentStorage.QUOTA_CHARS` × 2. Runtime write types `set`, `remove` and `clear` map one
  to one to the channel's operations.
- The runtime gives storage and cookies only to an `http(s)` location. A document without a
  URL (candidates 1 and 2) would need a unique synthetic location such as
  `https://<random>.invalid/` to use the per-document stores of part 1. The name never
  resolves, and Kotlin still sends `Origin: null`. See the open points: this location
  conflicts with the opaque origin.
- Resource requests: `kind: script` + `type: module` → `module`. `credentials`,
  `crossOrigin`, `referrerPolicy`, `forcePreflight` and `stylesheetReferrerUrl` /
  `moduleReferrerUrl` are dropped: requests are never credentialed and never send a
  `Referer`. `mode: same-origin` fails in Dart, because an opaque origin has no same-origin
  URL. `integrity` is checked in Dart (`document_integrity.dart`): it fails closed on an
  opaque response, as browsers do. Remote `image` requests fail in Dart: images load only
  after a tap. `data:` and `blob:` images still decode.
- Response: `stylesheetReferrerPolicy` and `moduleReferrerPolicy` are gone (no `Referer`).
  The other fields are the same.

## Persistence decision

Storage and cookies stay in memory only, kept per session by Kotlin. They end when the
document closes. Reasons:

- The old app persisted them per pairing and origin. Such a key is shared by every
  document of one origin, and 0.11.0 forbids that ("no storage of another message").
- A per-document key would need a stable document identity and new Kotlin disk storage
  with a wipe on unpair. Tier 3 is frozen ("no expansion").
- The Web (sandboxed iframe) and macOS (non-persistent store) plans keep nothing either.

## Changes in behaviour (group A)

- No storage poll and no storage events: the session's storage has no other writer. The
  old poll and event code is deleted. Storage is read before a turn and written after one.
- A storage snapshot goes to the runtime only when the areas changed.
- Subresource Integrity is checked in Dart (the old app checked it in Kotlin):
  - metadata with only unsupported algorithms (for example `md5-…`) now passes, as in
    browsers;
  - the strongest algorithm is picked from every token with a supported name, so a
    token whose digest is not valid base64 is no longer dropped first;
  - algorithm names match without regard to case (`SHA384-…`);
  - a non-empty check on an opaque (`no-cors`) response always fails.
- Cookie seed (`documentCookieState`): Kotlin keeps only name, value and expiry, so the
  runtime's seed after a sync has every cookie at path `/` with no expiry. Path scoping
  and expiry hold in the runtime's own copy until the next sync. Lines the runtime refuses
  are still sent to Kotlin, which applies its own rules (`DocumentCookies.assign`).
- `Referer` and `Origin` headers set by a script are no longer removed in Dart. They reach
  the channel, and Kotlin drops them there (forbidden headers).
- A cancelled request that waits for a slot leaves the limiter queue and never goes out
  (`DocumentResourceLimiter.cancel`). Inside the limiter, `_resource` also checks the
  cancelled IDs before it sends. In group A the document's own resource queue already
  stops at 6, so the limiter queue guards other callers. Kotlin `ScriptResources.Calls`
  now remembers a cancel that arrives before its request begins (the control pool can
  overtake the network pool). It keeps such a cancel for 30 seconds, and at most 64 of
  them, and refuses that request ID once.
- `start()` lost `storageSessionKey`. `NativeDocumentScripts` takes a `ScriptsPlatform`
  and has no `loadRuntime` argument.

## Open points for B and C

- The synthetic `https://<random>.invalid/` location conflicts with the opaque origin. The
  runtime would report `self.origin` and `location.origin` as that https origin, not
  `"null"`. It would treat the document as a secure origin and accept `__Secure-` and
  `__Host-` cookies in its own copy, which Kotlin refuses, until the next sync. Whoever
  builds C decides between this location and no storage or cookies at all
  (`about:srcdoc`, as the Web iframe plan gives).

- Initial stylesheets. The old `documentStylesheet` loaded a fetched page's CSS before any
  isolate existed. `ScriptsPlatform.resource` needs a session, and the limiter is private
  to `NativeDocumentScripts`. B must either open the session first and add a public
  method on `NativeDocumentScripts` that goes through `_limiter`, or make the limiter
  injectable. Then a document without scripts but with remote CSS holds a session only
  for its CSS, and Kotlin allows 4 (`DocumentScripts.MAX_SESSIONS`). This is an open
  decision.
- Remote script images (`<img>` read by Canvas, `new Image()`) now fail with "Remote
  images load only after a tap." Nothing lets the user tap to load them yet. C either adds
  a tap step that loads the image through `ScriptsPlatform.media`, or accepts that they
  never load.
- B and C import A from `src/`. The library exports only `NativeDocumentScripts`,
  `NativeDocumentEnvironment` and `DocumentResourceLimiter`.

## Tests

- Default suite (never tagged, `document_scripts_safety_test.dart`):
  - the limiter: at most 6 run, waiting requests start in arrival order, a cancelled
    waiting request never runs, and closing fails the waiting ones;
  - a document has at most 6 requests out and still finishes all 8;
  - image refusal, dropped credential fields and refused credential headers;
  - SRI: hashes, no-cors scripts and stylesheets fail closed, and stylesheets are
    checked;
  - storage and cookies kept apart between documents.
- Group A: 25 files moved. Their old `Gateway` fakes run on
  `test/support/legacy_scripts_platform.dart`. It maps each channel call to the old
  bridge method name, and it follows the Kotlin channel for session IDs, owner and closed
  checks, the per-session stores, the cookie rules, the request cap, duplicate request
  IDs and opaque `no-cors` responses.
  - In the default suite: all of `document_script_resources`, `document_script_cookies`,
    `document_script_images` and `document_vector_source` (resource lifecycle,
    containment and limits). Also three tests of `document_style_loading`, four of
    `document_classic_script_host` and two of `document_scripts` (bounds, disposal, stale
    work).
  - `tier3`: the other tests of `document_scripts`, `document_classic_script_host` and
    `document_style_loading` (tagged per test), and the whole files `document_mode`,
    `document_pointer_activity`, `document_focus_actions`, `document_script_form_actions`,
    `document_anchor_activation_actions`, `document_file_picker_actions`,
    `document_frame_steps_host`, `document_environment`, `document_layout_host`,
    `document_scroll_frame_host`, `document_script_visibility`,
    `document_script_scheduler`, `document_canvas_host`, `document_dialog_state`,
    `document_dynamic_styles`, `document_script_image_animation`, `document_referrer` and
    `html_document_styles_oracle`.
- Group B (on hold): the tests that import `document_navigation_state`, `document_response_cache`
  or `document_cache_policy`. Among them are four that also import A files:
  `document_origin_test`, `document_referrer_navigation_test`,
  `document_history_bridge_test` and `document_dynamic_styles_oracle_test`.
- Group C (on hold): the tests that import `document_navigation` or `document_navigation_widget_test`
  (the `document_live_runtime_*` tests, `document_environment_view_test` and the dialog
  view tests).
- Integration tests (`apps/android/integration_test/document_*`, which import
  `document_scripts`): C decides for each one. It either rewrites the test for the new
  channel, tagged `device`, or drops it and says why. `document_storage`,
  `document_cookies` and `document_origin_navigation` tested Gateway-origin persistence and
  sharing across windows, which no longer exist. `document_resource_cancellation`,
  `document_object_url`, `document_media`, `document_canvas_text` and
  `document_stylesheets` are worth rewriting.
- Not ported: tests of `app_document_route` and `app_document_shell`, and of the
  Gateway-origin cookie jar and paired-origin policy. Step 9 deletes them.
