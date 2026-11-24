# pirc mobile

Native Flutter Android client for pirc. Its Android transport lives in
`android/app/src/main/kotlin`; pairing uses Settings → Devices on the web.

The app includes chat and work sessions, streaming and cancellation, approvals,
memory and schedules, workspace panels, shared project files and project deletion, attachments,
notifications and native content rendering. Provider and device management uses a short-lived grant that
you approve in the authenticated web UI. HTML, JavaScript-backed documents,
Markdown, code, math and supported diagrams render through Flutter; browser
compatibility is incomplete. See the [remaining mobile work](../../docs/development/historical-records.md#retired-plans-2026-11-24).

## pots tracking checkpoint

The native pots page is available from phone navigation and the desktop sidebar.
It uses the existing paired Gateway HTTP bridge; no additional socket, observer
runtime or background worker is installed. Responsibilities select progress-only
workspaces and finite budgets, are saved disabled, and require explicit activation.
Observation pause, coordination pause, takeover and Stop tracking remain distinct.
Track only never creates an execution session; Start is unavailable in this
checkpoint. Tracking controls do not cancel tools in the source conversation.

Source identifiers, expiry and outdated states are shown without copying source
transcripts. Refresh/resume reconciles current server state; failed reads hide
previous records. Re-pairing and server account changes clear records/drafts and
fence stale responses/actions. Ambiguous mutations reconcile by GET, not automatic
POST replay. No pots preview is persisted on the phone.

`test/pots_test.dart` covers the tracking state and native phone/tablet UI gates,
including 390×844 and 1024×900 layouts, source opening without acceptance,
finite configuration, exact revision/generation requests, retry reconciliation,
expiry and re-pair/account races. Run it alongside the existing navigation,
calendar-account and localization regressions:

```sh
flutter test --no-pub test/pots_test.dart test/i18n_test.dart \
  test/mobile_page_navigation_test.dart test/navigation_parity_test.dart \
  test/calendar_account_test.dart
```

APK build, physical-device acceptance, real push delivery and execution/dispatch
parity are separate, unclaimed gates.

## HTML disclosures

Native `<details>` supports script-controlled open state and named accordions.
Summary pointer, keyboard and accessibility activation follow the script click
pipeline, including `preventDefault()`. The DOM reflects `open`/`name` and sends
coalesced `toggle` notifications. Reproduce the independent browser reference
with `node apps/android/tool/parity/capture_document_details_chromium153.mjs`
from the repository root; `tool/parity/document_details_test.mjs` compares the
runtime to it, while `test/native_html_details_script_test.dart` checks native
activation across phone/tablet sizes, themes and DPRs. Pixel appearance, default
summaries without authored markup and physical-device acceptance remain
separate boundaries in the mobile plan.

Fragment links reveal containing disclosures before native focus/scrolling,
including nested accordions, named groups, initial URLs, repeated activation
and history traversal. Static fetched documents retain open state and eligible
text drafts across resize/remount. Presentation reparses retain live file,
password, autocomplete-off and other control values while Reset still uses the
authored defaults. Static fetched documents also own these controls through
complete workspace removal/remount and same-frame replacement. Pending file
selection can finish for the same live document; close, account change, Reset
and fresh responses invalidate retired selections. Sensitive/off values remain
in memory only and are excluded from history snapshots. Recreate the independent
eight-profile value reference with
`node apps/android/tool/parity/capture_document_control_lifetime_chromium153.mjs`;
`test/document_control_lifetime_test.dart` covers native ownership, Reset,
reparenting and delayed picker boundaries. Wider scripted resource lifetimes
and real IME/focus transitions remain unverified.
Recreate the 96-profile disclosure reference with
`node apps/android/tool/parity/capture_document_details_fragment_chromium153.mjs`;
`test/document_details_fragment_test.dart` checks native visible geometry,
focus, scrolling and retained reading position. Hidden-until-found/beforematch,
shadow-tree revealing, custom marker appearance and closed-descendant CSSOM
geometry remain documented differences. These gates do not establish full
browser compatibility or new pixel parity.

## Scripted file selection

Already-authorized script choosers survive temporary removal or replacement of
the same live document view. Selected bytes, names and subsequent form submission
stay document-owned; current file controls update even if the script returns
unchanged HTML. Closing/replacing the document, changing account or switching
windows discards late results and cannot leave a stale chooser lease blocking
the next selection. Old renderer cleanup cannot pause its same-frame successor.
Recreate the independent browser reference with
`node apps/android/tool/parity/capture_document_script_picker_lifetime_chromium153.mjs`.
`tool/parity/document_script_picker_lifetime_test.mjs` checks the production JS
runtime against it; `test/native_html_script_picker_lifetime_test.dart` and
`test/document_script_picker_lifetime_test.dart` exercise native restoration and
controlled bridge boundaries. System chooser, Android engine IPC, real IME and
broader resource lifecycle acceptance remain separate in the mobile plan.

## Shipped runtime and native host integration

`test/document_live_runtime_resources_test.dart` executes the shipped JS bundle
through `NativeDocumentScripts`, the real native layout producer and Flutter
workspace. It compares independent browser states for fetch/JSON, dynamic
external classic scripts, AbortController cancellation and view replacement,
including live styles, editor values and panel geometry.
`test/document_live_runtime_picker_test.dart` checks chooser bytes, FormData,
trusted events and Reset through the same chain. A test-only Node VM protocol
peer supplies engine IPC; transport responses are synthetic. Android Sandbox,
real HTTP policy and system picker acceptance remain separate. Fully detached
views buffer resource callbacks until reattachment; CSS-hidden browser pages
can continue those callbacks.
Recreate the resource reference with
`node apps/android/tool/parity/capture_document_live_resources_chromium153.mjs`.

`test/document_live_runtime_assets_test.dart` adds linked stylesheets, initial
and dynamic raster images, imported module dependencies and module cache reuse
across document view replacement. Managed raster images share the document's
decoded image with JS/Canvas. Startup waits for script ownership; terminal engine
failure releases ordinary image loading. Separate image metadata validates
native handles without introducing author-visible HTML/CSS attributes. Managed
SVG images share immutable original bytes with Canvas while painting vectors
with the same intrinsic-size frame. `test/document_live_runtime_svg_test.dart`
checks startup, remount, same-frame replacement, stopped scripts and actual
HTML/Canvas pixels against a separate Chromium SVG reference; recreate it with
`node apps/android/tool/parity/capture_document_live_svg_chromium153.mjs`.
`test/document_vector_source_test.dart` checks immutable versions, failure,
retirement and a 32 MiB aggregate pool source-cache limit (separate from
Flutter’s standard graphics caches). Beyond that limit, SVG
retains its ordinary vector provider and may refetch. A vector widget test also
checks sharp colors after enlarging a 2x2 SVG to 128x128. Multi-frame images keep
their animation display paths; responsive/picture candidate selection and unobserved
images keep the ordinary provider. Script-side failures use the established
display fallback so its larger image limits are preserved.
Same-snapshot presentation updates preserve native inputs locally; newer script
snapshots apply their own values without stale history writes. Recreate the
browser reference with
`node apps/android/tool/parity/capture_document_live_assets_chromium153.mjs`.
These tests include exact opaque screenshot probes and bounded geometry/style
checks. Cross-provider image caching, lazy/responsive transitions, pending-image
presentation and complex resource graphs remain listed in the mobile plan.

`test/document_live_runtime_dialog_form_test.dart` checks dialog form closing
through the shipped runtime and real Flutter controls, including retained edits
through view removal, submit/invalid events, return values and no navigation.
`test/document_dialog_state_test.dart` checks runtime activation without authored
scripts and native/computed closed visibility, including author display overrides.
Recreate the independent reference with
`node apps/android/tool/parity/capture_document_dialog_form_chromium153.mjs`.
`test/document_live_runtime_dialog_show_test.dart` also verifies nonmodal
`show()`, real native initial/restored focus, edits and close behavior in eight
phone/tablet, DPR and theme profiles. Its independent reference is recreated by
`node apps/android/tool/parity/capture_document_dialog_show_chromium153.mjs`;
`document_dialog_show_test.mjs` checks 24 synchronous/settled opening/focus cases.
The fixture retains and explicitly asserts the 16 CSS px default-paragraph
margin-collapse difference. `document_dialog_modal_test.mjs` and
`test/document_live_runtime_dialog_modal_test.dart` cover common `showModal()`
state, native backdrop/centering, blocked background taps, Escape/Android Back
and cancelable requests in phone/tablet light/dark profiles. The script test
also checks `closedby=none` and rejects forged native top-layer markers.
`closedby=any` backdrop pointerdown/cancel/close and mouse/touch click order are
compared with the pinned Chromium 153 fixture captured by
`node apps/android/tool/parity/capture_document_dialog_modal_backdrop_chromium153.mjs`.
The Flutter widget gate checks touch light-dismiss, canceled light-dismiss,
`closedby=none` and background tap blocking. Physical-device acceptance remains open.
`test/document_live_runtime_dialog_author_position_test.dart` compares 16
phone/tablet cases with the pinned Chromium 153 author-position fixture,
captured by `node apps/android/tool/parity/capture_document_dialog_author_position_chromium153.mjs`.
It covers relative/static/sticky coercion, explicit offsets and top-layer
containing blocks outside positioned or transformed DOM parents.
`test/document_live_runtime_dialog_nested_test.dart` compares two stacked
modals with `document-dialog-nested-chromium153.json`: the doubled backdrop,
negative authored z-index, blocked lower-dialog input, top-only Tab focus
and accessibility semantics, and staged light-dismiss. Script attempts to focus
lower/background controls are rejected. Regenerate that fixture with
`node apps/android/tool/parity/capture_document_dialog_nested_chromium153.mjs`.
The final dialog's focus after backdrop dismissal still differs from Chromium;
see the mobile plan.
Host-layout documents with omitted `html`, `head` or `body` now create the
browser's common document tree before parser scripts. The pinned fixture from
`node apps/android/tool/parity/capture_document_rootless_chromium153.mjs`
compares ten tree/script-placement cases; `document_rootless_runtime_test.mjs`
and the rootless modal widget cases cover DOM and native layout together.
Broader UA layout/focus delegates and the remaining modal differences are listed
in the mobile plan.
The tests keep the observed close/toggle task-order difference explicit.
Validation popup paint has separate visual acceptance; an obscured pixel is not compared as background.

`test/document_live_runtime_dialog_layout_test.dart` checks default dialog
presentation in full fetched documents: native block-flow markers, fit-content
sizing, UA border/padding/color, CSSOM insets, Open/Close and authored color updates.
Recreate its independent browser reference with
`node apps/android/tool/parity/capture_document_dialog_layout_chromium153.mjs`.
Mixed inline/flex/grid static positions, embedded Markdown defaults and modal
size differences remain in the mobile plan. `test/loading_spinner_test.dart` verifies
actual loader rotation and suspension on hidden/reduced-motion surfaces.

`test/document_live_runtime_dialog_request_close_test.dart` checks cancelable
nonmodal close requests, retained CJK/emoji drafts, handler replacement, explicit
close and native focus restoration at eight viewport/theme/DPR profiles.
Recreate its independent Chromium 153 reference with
`node apps/android/tool/parity/capture_document_dialog_request_close_chromium153.mjs`;
`document_dialog_request_close_test.mjs` compares 44 synchronous/settled API,
reentrancy and handler-attribute/IDL cases. Basic modal/platform dismissal is
covered by the modal tests above. Complete handler compilation semantics and
the explicit pointer close/toggle task-source difference remain in the mobile plan.

Terminal controls support two-finger font zoom, Ctrl+plus/minus and Ctrl+0.
Mobile clients also show a Termux-style extra-key strip with one-shot Ctrl/Alt;
short viewports use one scrollable row. `test/terminal_zoom_test.dart`,
`test/terminal_extra_keys_test.dart` and `test/terminal_keyboard_performance_test.dart`
cover real PTY input/resize callbacks, retained input focus, scrolling, glyph-cache
reuse through keyboard metrics and small viewport layouts.
`test/timeline_notice_width_test.dart` checks the reported truncated warning using
actual Roboto metrics. Physical-device performance and keyboard acceptance remain
in the mobile plan.

## Build and run

Use Flutter 3.44.4 / Dart 3.12.2 or a compatible SDK, Android SDK and JDK 17.
Native document integration widget tests also require Node.js 22 or newer on
PATH; `PIRC_TEST_NODE` can select an explicit Node executable. The Nix development
shell includes Node.js 22, and Release CI installs it before running the tests.
Android 10 (API 29) or later is required. From the repository root, `nix develop`
provides Flutter, its matching Dart SDK, and JDK 17 alongside the Rust and web tools.
The Android SDK must be installed separately for native builds; point
`ANDROID_HOME` at your Android SDK. `flutter pub get` prepares the local Flutter
SDK configuration used by Gradle; do not commit `android/local.properties`.
Flutter tests and analysis work with the Nix SDK. Native Gradle 9 builds currently
reject the SDK's read-only `packages/integration_test/android` project directory;
use a writable Flutter SDK installation for those builds until this is addressed.
Run from this directory:

```sh
flutter pub get
flutter run
flutter build apk --release
```

The application ID is `dev.pirc.mobile.preview`. Local release-mode builds use
the existing Android debug signing key for preview installs. Release CI requires
a persistent keystore supplied through Actions secrets; see
[Release CI setup](../../docs/development/releasing.md#github-release-ci-setup-once-per-repository).
Origin's CI now has a dedicated release key. Its APKs require uninstalling the
old debug-signed beta first; local preview builds retain their debug identity.
Production application identity and store distribution remain release decisions;
do not treat these builds as store releases. No signing key, pairing credential
or local APK belongs in Git.

Upgrade the gateway and every node together. The 0.9.x server uses node protocol
13; this protocol is between the servers, not the app's REST connection. The app's
mode catalog, delegation approvals, management grants and cross-device interaction
synchronization need the matching gateway/web update. See the
[upgrade notes](../../docs/deploy/upgrades.md).

## Content boundary

Content the agent or a document supplies is treated as untrusted:

- **Initiator.** The paired credential is attached only to requests the app
  itself starts. Page content, forms, scripts and subresources use the content
  initiator and carry no credential, paired-origin cookie or Referer.
- **Gateway documents are inert.** A document whose final response URL (computed
  by the native transport after every redirect) is the paired origin is shown as
  text and controls but never gets a script environment, author stylesheets,
  same-origin script/fetch resources, or the paired origin's cookie and storage
  scopes (`PairedOriginPolicy`). The native script engine re-checks the document
  URL itself before it creates an isolate. The app still recognises its own Web
  shell. Documents and scripts from other origins, images, files, downloads and
  forms work as before.
- **Remote images and media load on a tap.** In chat messages, previews, tool
  output and Gateway documents, a remote image, poster or media source is an
  app-owned placeholder (`NativeRemoteContentGate`) showing the alt text and
  source until the user taps it; only then is it requested. Inline `data:`
  images display directly. CSS background images have no tap target and are not
  loaded in these places. A page the user navigated to on another origin loads
  its own images.
- **Update prompt.** A `request_shape_required` (HTTP 415) reply asks the user to
  update the app and is not retried in another shape.

`test/remote_content_gate_test.dart`, `test/paired_origin_document_test.dart`,
`PairedOriginDocumentTest.kt` and `test/ui_integrity_native_test.dart` pin these
with request counts and measured layout. `integration_test/
content_boundary_emulator_test.dart` and `dev/emulator-fixture.mjs` repeat the
checks on a device against local servers (not yet run on a device).

## Workspace modes

The app loads the gateway's mode catalog (`GET /api/modes`) with the workspace
index and asks capabilities, never mode ids, as described in the
[modes guide](../../docs/guides/modes.md); `lib/live/modes.dart` holds the
lookups. A workspace is in the Chat tab iff its mode is `assistant: full`; every
other workspace, including per-session ones such as a scratch mode, is under Work,
grouped by device. Side panels, settings sections, per-session deletion and
nouns follow the mode's capabilities. Add workspace offers the node's accepted,
non-assistant modes and asks for a path only for `workdir: workspace`. A
workspace whose mode is missing from the catalog is read-only under Work. An
older gateway without the catalog (404) falls back to the legacy `kind`.

## Project files and deletion

Project files use scoped native document tokens and stream one file at a time within the node's reported upload limit, not the session-attachment picker's older 8 MiB cap. Partial batches keep successful uploads; account, project, host or online-state changes discard stale results and stop the remaining batch. Temporary tokens are released on completion or cancellation.

Project deletion requires explicit Forget/Keep/Edit decisions for mixed-source memory, following the [project deletion contract](../../docs/guides/chat-projects.md#deleting-a-project). Revision conflicts reload the preview and clear prior decisions; other failures reload the remaining deletion plan before retrying. No deletion POST is retried automatically. Preview and confirmation capture the pairing stamp and that account's API before I/O; stale stamps are rejected before destructive requests. Account, host or project changes dismiss stale dialogs. Acknowledged deletion clears only that project's sessions, drafts and navigation, refreshes memory/schedules and fences stale indexes or pending chat creation from restoring it. The top-level Chats workspace cannot be deleted. Submission blocks dismissal and edits; constrained keyboard viewports may scroll the whole dialog.

## Verification

```sh
flutter analyze
flutter test
node --test tool/parity/*_test.mjs
```

Install the root Bun dependencies for the JavaScript tooling. Android JVM tests
run with `./gradlew testDebugUnitTest` from `android/`. Device integration tests
live in `integration_test/`; `real_gateway_test.dart` and related service tests
require the isolated synthetic Rust environment in `tool/parity/real_gateway.ts`
and its private Dart define file. `project_files_test.dart` covers raw project
uploads, replacement, removal and existing session attachments; its optional
`PIRC_PROJECT_FILES_PICKER=true` mode also exercises the Android document picker
with a local `pirc-project-file-picker.txt` containing `Native project picker fixture`
followed by a newline. `project_deletion_test.dart` verifies the native preview,
mixed-memory conflict/review, pairing guard and project cleanup using synthetic
`memory_note` histories. Never point those destructive test fixtures at
your normal gateway or production data.

Some pixel/geometry fixtures use macOS Arial and Menlo through
`tool/parity/capture_fonts.dart`; those checks require the matching comparison
fonts. `document_root_height_oracle_test.dart` compares native full-page height,
viewport units and overflow against the dedicated Chromium capture generated by
`tool/parity/capture_document_root_heights_web.mjs`.
`document_root_height_view_test.dart` checks resizing, retained form state,
bottom-link interaction and the viewport remaining below app chrome. The two
known trailing-space differences are listed in [the mobile plan](../../docs/development/historical-records.md#retired-plans-2026-11-24).
`document_offsets_oracle_test.dart` compares offsets and fixed flex margins with
Chromium. `document_margin_collapse_oracle_test.dart` and the fetched-page tests
cover common parent/first-child top margins. The percentage-margin oracle and
layout/view tests cover distinct containing-block widths, resizing, flex sizing,
flow-root barriers and scroll preservation during provisional or failed layout.
Remaining limits are recorded in the plan. `document_offsets_http_test.dart`
checks the shipped JavaScript runtime, scrolling, percentage geometry and style
mutation over local HTTP on Android.
`document_relative_position_oracle_test.dart` compares physical relative insets,
root/body offsets, flex/grid flow slots and scroller extents with Chromium.
The relative fetched-page tests check shifted link hits, clipped scrolling,
resizing and retained input state; the renderer tests also verify semantics and
flow baselines. Common relative `em`/`rem`/`vw`/`vh` insets also use reliable
computed lengths for paint and offset support. Recreate their separate 64-profile
/ 192-state reference with
`node apps/android/tool/parity/capture_document_relative_units_chromium153.mjs`;
`document_relative_units_test.dart` checks actual fetched-page rectangles,
styles, offsets, opaque pixels, shifted link hits and retained drafts through
font changes and resize. Missing length bases stay unsupported. This is a native
widget gate; Android Sandbox and physical-device coverage remain in the plan.
Fixed grid rows retain their sizes in auto-height containers.
`document_computed_styles_oracle_test.dart` compares the supported style values
with the dedicated Chromium reference. The production runtime and Android HTTP
checks cover live read-only declarations, native dimensions and mutation fences.
Computed styles are a supported subset; absent standard properties and stale
frames fail explicitly. The detailed boundaries remain in the mobile plan.
`document_replaced_styles_oracle_test.dart` compares decoded PNG/canvas intrinsic
sizes, HTML dimensions, border-box edges, percentages, overflow and max-width
fitting and height-driven aspect ratios with eight Chromium cases at two viewports. Small text-flow rounding
differences are named in the test and mobile plan. The Android HTTP
integration also reads canvas/image styles and rectangles through the shipped
runtime after actual image decoding. The native Chart.js cases below cover
bar-chart initialization, updates and measured container resizing; broader
library support and size-changing synchronous write/read gaps remain in the plan.

`document_canvas_text_test.dart` runs synchronous Canvas `measureText()`
through Android JavaScriptSandbox, compares it with actual Flutter font advances,
compares real ink bounds with native raster pixels at 4x resolution and paints
the resulting native Canvas commands. It requires Android 12+ and the
sandbox's WebAssembly/named-data features. The bundled Skia text engine is pinned
to the Flutter engine above, with source checksums and license notices; rebuild
its assets offline with `python3 tool/parity/build_document_script_runtime.py`.
`document_canvas_text_runtime_test.mjs` compares the real engine with the pinned
Roboto/Chromium width and ink fixtures, including alignment and baselines.
Unprepared fonts, missing glyphs, ambiguous ownership, OpenType BASE selection
and mixed color/outline ink remain explicit differences. Font preparation keeps
complete outlines, bounded to 64 MiB of unique data; isolate limits are unchanged.
This is a bounded Canvas surface, not full browser font support.

`document_mutation_observer_test.dart` verifies public DOM observation through
Android IPC: nested child/attribute/text records, old values, NodeList records,
Promise ordering, record draining and private-snapshot suppression. The matching
Node suites exercise the helper and the shipped bundle. Detached-subtree
transient observation and bulk record grouping remain explicit differences.

`document_absolute_position_test.dart` compares native absolute positioning with
pinned Chromium geometry, actual screenshot pixels and topmost hit targets.
It covers nearest relative/absolute block containing boxes, initial viewport
positioning, percentage sizes, stretching, auto/percentage margins, min/max,
flex/grid flow, inline/image/Canvas blockification, RTL and sibling overlap order.
With the loopback fixture server and define used below, run
`integration_test/document_absolute_test.dart` on a dedicated Android device.
Its selected profiles execute actual JS click handlers that change position and
size; settled rectangles must match and other flow boxes must not move.
Recreate the reference with
`node apps/android/tool/parity/capture_document_absolute_chromium153.mjs`.
At least one physical inset on each axis and an ordinary visible-overflow block
containing box are required. Both-auto static-position axes, inline containing
blocks, positioned scrolling/clipping, transformed containing blocks, negative
and complex nested stacking, positioned scroll/offset metrics, fixed and sticky
positioning remain open. See the mobile plan for the complete boundaries.

`integration_test/document_visibility_test.dart` runs without a fixture server.
It checks the real Android JS engine and Flutter document view across eight
phone/tablet, DPR 1/3 and light/dark profiles: `document.hidden`, read-only
`visibilityState`, ordered `visibilitychange` events, Promise updates and
animation suspension/resumption after window and simulated app activity changes.
The host tests also retain rapid hide/show edges during startup and in-flight
evaluations. A visible but unfocused (`inactive`) app stays visible to the DOM;
its existing scheduler still pauses until foreground resumes.
Recreate the pinned initial-property/synthetic-event browser observations with
`node apps/android/tool/parity/capture_document_visibility_chromium153.mjs`.
The dedicated Headless Shell does not prove real browser background transitions;
physical OS lifecycle delivery and chart-specific interruption remain separate
acceptance work. Neither the fixture nor test code is included in the APK.

`document_chart_http_test.dart` uses the pinned test-only Chart.js 4.5.1 UMD and
Chromium 153 fixture for phone/tablet at DPR 1/3. It compares actual native
geometry and painted bar/tooltip pixels, taps both bars and blank/outside areas,
checks legend hide/show with actual bar pixels and rapid outside taps, taps the
update button and increases the container
and Canvas CSS widths by 20 px. Initial CSS and backing sizes are consistent;
both CSS dimensions use explicit pixels, with no CSS attribute dependencies.
Other sizing modes and synchronous reads before native layout remain open. Run it with the loopback fixture server (keep it running in another
terminal) and an attached dedicated test device/emulator:

```sh
# From the repository root:
node apps/android/tool/parity/serve_document_chart_fixture.mjs --port 19261
# In the test terminal:
adb -s emulator-5554 reverse tcp:19261 tcp:19261
cd apps/android
flutter test integration_test/document_chart_http_test.dart -d emulator-5554 \
  --dart-define=PIRC_CHART_FIXTURE_ORIGIN=http://127.0.0.1:19261
adb -s emulator-5554 reverse --remove tcp:19261
```

Without the define, the fixture-dependent test is skipped. The server binds only
to loopback and verifies the pinned library hash. Recreate the browser reference
with `node apps/android/tool/parity/capture_document_chart_chromium153.mjs` from
the repository root; the capture refuses everyday Chrome and blocks requests.
The touch oracle is reproducible with
`node apps/android/tool/parity/capture_document_chart_interactions_chromium153.mjs`.
The native acceptance includes legend state and bar fill disappearance/restoration;
label strikethrough uses real glyph ink bounds. Full TouchEvent/multitouch compatibility,
custom plugins and untested chart configurations remain open; default animation
has the separate gate below.
Neither the test library nor its fixture is included in the APK.

With the same fixture server and define, run
`integration_test/document_chart_types_test.dart` for the stock-chart gate:
bar, line, pie, doughnut, scatter, bubble, radar and polar area across 64
phone/tablet, DPR 1/3 and light/dark profiles. The exact shared HTML/driver tests
first/second data hits, stock tooltips, outside dismissal, legend hide/show,
data updates and resizing. It also checks actual data pixels, cleared space,
doughnut holes and line connections. Recreate the frozen reference with
`node apps/android/tool/parity/capture_document_chart_types_chromium153.mjs`.
All browser resources are fulfilled locally by request interception; external
requests are blocked, and the dedicated test browser remains mandatory.

With the same server and define, run the default-animation gate:

```sh
flutter test integration_test/document_chart_animation_test.dart -d emulator-5554 \
  --dart-define=PIRC_CHART_FIXTURE_ORIGIN=http://127.0.0.1:19261
```

Its 64 profiles retain the original Chart.js 1,000 ms duration and `easeOutQuart`
easing and use ordinary `chart.update()`. The eight operations match the stock
gate. Progress/complete callbacks are monitored without replacing the clock or
shortening transitions. The test captures the actual Canvas widget layer during
active frames, requires changing paint and compares settled geometry, selected
colors, hits and completion counts against the browser. Canvas has an independent
repaint boundary; its unit test checks that changed pixels do not repaint a static
parent. Recreate the frozen reference from the repository root with
`node apps/android/tool/parity/capture_document_chart_animation_chromium153.mjs`.
Observed callback cadence is recorded rather than required to equal Chromium's.
Animation interruption/retargeting, background/visibility lifecycle and physical
device smoothness still need separate acceptance.

The stock font aliases keep the prior 2 px pixel-geometry bound, with raw
differences recorded; angles use a separate 1e-12 bound. A neutral radar tick
backdrop edge after hiding the data has an explicitly recorded 8 × DPR / 255-channel
antialiasing bound. Canvas dimensions, solid data and clear-space probes stay exact.
These are functional and selected-paint checks, not whole-image equality.
Tooltip interiors composited over data have a separate 1/255-per-channel rounding
allowance (observed polar-area `[6,40,19,255]` versus `[7,39,19,255]`). This
applies only at samples at least 8 CSS px inside the tooltip background; solid
data, transparent holes and clear-space samples keep their exact checks.
The same reference includes 129 font-independent path-call observations that
verify ignored nonfinite arguments, WebIDL arity/conversion errors and negative
radii. The original chart library is unchanged and is excluded from the APK.

The `document_chart_http_test.dart` command also audits 16 responsive sizing cases from
`document-chart-responsive-layout-chromium153.json`, loading the exact authored
HTML and driver used by the browser. All 16 cases must initialize without
diagnostics and match native geometry and bar pixels, including Canvas with no
authored size, pixel/percentage widths, initial inline display, content-box sizing
and omitted backing attributes. Container-only resizing requires matching early
and settled geometry and paint, including Chart's same-callback parent-width
read after changing descendant sizes. Native-proved simple used-size calculation
supports intrinsic initialization; general synchronous layout remains open.
Recreate this separate browser reference with
`node apps/android/tool/parity/capture_document_chart_responsive_layout_chromium153.mjs`.
The capture records both the early two-frame and settled resize observations;
the native audit keeps failures visible rather than substituting fixed sizes.

With the same fixture server, run from `apps/android`:

```sh
flutter test integration_test/document_frame_steps_test.dart -d emulator-5554 \
  --dart-define=PIRC_CHART_FIXTURE_ORIGIN=http://127.0.0.1:19261
```

It compares native frame callbacks with eight frozen Chromium cases: phone/tablet,
DPR 1/3, light/dark. It checks Promise jobs, cancellation, nested frames, frame
timestamps and actual native dimensions after earlier callbacks change width.
Recreate its reference with
`node apps/android/tool/parity/capture_document_frame_steps_chromium153.mjs`.
This repairs layout between callbacks. Within one callback, a measured fixed-width
ordinary block can also retain its `clientWidth` after strict descendants' size
changes when CSS cannot depend on those attributes and no scrollbar or intrinsic
sizing is involved. Other metrics and newly changed geometry still require native
layout; arbitrary synchronous writes and reads remain a separate gap.

With the same server and define, `integration_test/document_layout_dependencies_test.dart`
compares 32 browser/native cases: ordinary/nested blocks, content-box/border-box,
phone/tablet, DPR 1/3 and light/dark. It reads parent `clientWidth` immediately
after resizing a descendant, then compares actual native rectangles on the next
frame. Recreate the reference with
`node apps/android/tool/parity/capture_document_layout_dependencies_chromium153.mjs`.

`integration_test/document_box_style_projection_test.dart` uses the same server
and define to compare 32 independent computed-style cases against Chromium 153.
It switches edgeless fixed-size Canvas display/box-sizing, including percent width,
inline/block changes and same-batch restoration. The live computed declaration
and fixed single-child parent rectangle are checked synchronously; actual native
child geometry is checked on the next frame. Inline child baseline rounding may
differ by at most 0.1 px with platform fonts; the raw difference is recorded and
all other values stay exact. Recreate the reference with
`node apps/android/tool/parity/capture_document_box_style_projection_chromium153.mjs`.
This proof excludes scrollbar ancestors, edges, important box declarations,
attribute-dependent CSS and real dimension changes. It does not provide general
synchronous native layout or certify a replaced element's old position/scroll data.

`integration_test/document_canvas_sizing_test.dart` uses the same server and
define for 72 Chromium/native cases. It checks natural dimensions, auto-axis
ratios, px/percent switches, bitmap resets, zero natural axes and narrow fixed
parents after each individual write and native frame. The fractional-ratio mode
allows 0.02 px of browser layout quantization; other values remain exact.
`capture_document_canvas_sizing_chromium153.mjs` recreates the reference with
all network requests blocked. The runtime projects only host-proved simple CSS
sizes and stable parent data: a first-flow LTR path with pixel edges and no auto
margins, preceding rendered content, transforms or percentage relative offsets.
A scrolled root defers parent rectangles to native measurement to account for
scroll clamping after overflow changes. Unknown sizing expressions, changed child rectangles and scroll data still
require native measurement. Projection is bounded to 1,000,000 CSS pixels per
axis; the existing bitmap and drawing budgets remain separate.

`document_pointer_events_test.dart` compares 176 frozen Chromium 153 profiles
for native HTML hit targets and paint, including inherited `none`, explicit child
restoration, inline text, native buttons/Canvas, clipped/visible overflow and
dynamic changes. `document_pointer_restore_clip_test.dart` covers rounded clips
and text-field focus. Recreate the reference with
`node apps/android/tool/parity/capture_document_pointer_events_chromium153.mjs`.

`integration_test/document_pointer_events_test.dart` uses the same local server
and `PIRC_CHART_FIXTURE_ORIGIN` define for 88 Android profiles. The frozen browser
driver runs unchanged in JavaScriptSandbox; native touches, event targets,
bubbling, computed policy, dynamic updates and programmatic click traces are
compared after every step; restored native button border boxes are checked
against their authored sizes. The fixture server binds only to loopback and no
remote service is needed. SVG shape-specific hit geometry, pointer capture and
mid-gesture policy changes remain separate acceptance work.

`integration_test/document_text_style_test.dart` uses the same local server and
define for 48 frozen Chromium profiles. It compares synchronous cascade values
after visible/hidden text updates and next-frame native rectangles. Recreate the
reference with `node apps/android/tool/parity/capture_document_text_style_chromium153.mjs`.
`document_text_style_test.dart` checks native dependency proofs and packet metadata;
`document_text_style_runtime_test.mjs` checks the shipped bundle's retained styles
and invalidation. The pointer integration also checks immediate reads after its
programmatic click. Geometry still requires native layout, and text-sensitive
selectors or other DOM/style mutations retain their normal invalidation.

`document_fixed_oracle_test.dart` compares 120 Chromium profiles and 368 states
for viewport-fixed geometry, native paint, hit identities, root/inner scrolling
and same-document viewport resize. `document_fixed_position_test.dart` covers
short-document hit ownership and scroll extents. Recreate with
`node apps/android/tool/parity/capture_document_fixed_chromium153.mjs`.

`integration_test/document_fixed_test.dart` uses the same local fixture server and
`PIRC_CHART_FIXTURE_ORIGIN` define. Native Advance controls drive root/inner scroll,
style changes and hide/show; every state checks measured boxes and native clicks.
The eight hidden_dynamic profiles now use strict viewport comparison after the
root anchoring follow-up; their previous 180/300 allowance is removed. See the
mobile plan for the remaining positioning limits.
`document_scroll_frame_host_test.dart` verifies scroll acknowledgement before RAF,
ordered callback/Promise scrollBy and cancellation across hide/detach.

`document_scroll_anchor_oracle_test.dart` compares 144 profiles and 576 states
against Chromium: actual offset, extent, every captured box and a native painted
pixel. `document_scroll_anchor_activity_test.dart` checks ongoing drag/inertia.
The shared generator is `tool/parity/document_scroll_anchor_fixture.mjs`; capture
from the repository root with
`node apps/android/tool/parity/capture_document_scroll_anchor_chromium153.mjs`.
The Node contract checks source/driver identity, exclusion/suppression and removed
anchor behavior. `integration_test/document_scroll_anchor_test.dart` uses the same
local server/define as the fixed test, with the shipped JS sandbox and native
Advance control. Same-turn scrollTo/scrollBy wait for anchor compensation, and
layout acknowledgements wait for the resulting native paint.

`document_element_anchor_oracle_test.dart` compares 168 nested-scroll profiles
and 672 states, including actual native paint, owner replacement and hide/show.
Recreate its frozen reference from the repository root with
`node apps/android/tool/parity/capture_document_element_anchor_chromium153.mjs`.
The shared page/driver generator is `tool/parity/document_element_anchor_fixture.mjs`;
the Node contract verifies exact source identity, exclusions and coupled layers.
`integration_test/document_element_anchor_test.dart` uses the same loopback
fixture server and define as the root-anchor test, comparing all scroll/client
metrics and rectangles through the shipped JS engine and native controls.

`document_scroll_retention_test.dart` checks complete view/workspace remounts,
document switches, independent root/nested offsets, real link activation and fresh
history responses against eight Chromium 153 phone/tablet/DPR/theme profiles.
Capture the common HTML/driver reference with
`node apps/android/tool/parity/capture_document_scroll_retention_chromium153.mjs`.
Root history positions restore per entry in auto mode; nested positions stay with
the retained document. A fresh response starts nested positions at zero. The
Android `integration_test/document_scroll_retention_test.dart` uses the loopback
server/define above and real Step/Read buttons, requiring a new JS probe sequence
after each remount so a cached report cannot count as acceptance. The original VM
and offsets survive retained-view rebuilding; different documents stay isolated.
The workspace saves the latest root position at unmount, preserving user reading
past the original anchor; the native workspace gate also checks that a new
fragment selected while unmounted still applies on reveal.
Interrupted smooth scrolling and OS process-death restoration are separate gates.

`document_scroll_commands_test.dart` compares immediate native controller
positions and settled positions with 160 Chromium 153 command profiles, including
cancellation after animation has started. The JS bridge now reports immediate
clamped positions from measured native ranges and unacknowledged commands. It
keeps later commands across delayed measurements until their exact prefix is
acknowledged. Standards root reads/writes use the viewport even without a separate
html RenderBox. Root horizontal scrolling remains outside this gate.

The additional 96-profile feedback corpus covers repeated setter increments,
clamp-then-subtract, mixed methods, smooth cancellation, Promise jobs and RAF.
Recreate the independent references with:

```sh
node apps/android/tool/parity/capture_document_scroll_commands_chromium153.mjs
node apps/android/tool/parity/capture_document_scroll_feedback_chromium153.mjs
```

The Android `integration_test/document_scroll_commands_test.dart` uses the same
loopback fixture server/define as above and checks all 472 profiles: immediate and
settled readings, root aliases, intermediate traces and element rectangles. Node
tests check exact shared HTML/drivers, the shipped bundle, delayed
acknowledgements, bounded queues, measured ranges and lifecycle cancellation.
The existing 344 cases retain exact equality. The additional 128 rectangle cases
allow at most 0.001 CSS px for affine floating-point differences, while checking
all report keys, client rectangles and intermediate states.

`getBoundingClientRect()` and `getClientRects()` can now project pending scroll
commands from actual native paint ancestry, affine matrices and measured scroll
ranges. Fixed subtrees keep their viewport position; unrelated boxes remain
readable. The Canvas pointer rectangle fast path yields to this geometry after a
script scroll, so a real tap does not leave subsequent reads at its old position.
General DOM writes still require a matching native measurement; missing proof,
sticky and unsupported positioning paths retain explicit errors. Recreate the
128 independent Chromium 153 references with
`node apps/android/tool/parity/capture_document_scroll_rect_chromium153.mjs`;
the loopback fixture server supplies `/scroll-rect.json`.

Common HTML `transform` functions now paint and hit-test natively: translate,
scale, rotate, skew and six-value 2D matrices, composed in CSS order. Percentage
translations and ordinary `transform-origin` values use the actual laid-out
border box without changing normal-flow size. This gate includes nested
scrollports, default/explicit origins, rotation, matrix composition, transformed
positioned elements and actual Canvas taps.

`getComputedStyle()` also exposes common HTML 2D `transform` matrices and
`transform-origin` values. Matrix coefficients exclude the separately reported
origin; percentages use the actual untransformed border box. Identity matrices
remain distinct from `none`. Hidden elements report `none` and retain unresolved
percentage origins. Matrix numbers use six significant digits, matching the
frozen Chromium references. Retained declarations update after accepted native
frames when classes, dimensions and transforms change, including hidden-to-shown
and Canvas cases. `test/document_transform_style_oracle_test.dart` checks 128
phone/tablet, DPR 1/3 and light/dark profiles before and after mutation; Android
`integration_test/document_transform_style_test.dart` checks the same source
through JavaScriptSandbox, including camel-case/property aliases and geometry.
Recreate with
`node apps/android/tool/parity/capture_document_transform_style_chromium153.mjs`;
the loopback server supplies `/transform-style.json`.

Common transformed blocks also establish native containing blocks for absolute
and fixed descendants. Absolute elements choose the nearest positioned or
transformed ancestor; fixed elements choose the nearest transformed ancestor,
retaining `position: fixed` in scripts. Without one they stay viewport-fixed.
Identity transforms establish a containing block too. Adding/removing transforms
updates that ownership, and root or enclosing-panel scrolling moves local fixed
content. Common block opacity composes the complete positioned subtree as one
group without changing its click targets.

`test/document_transform_cb_oracle_test.dart` compares 136 independent Chromium
153 profiles across three states, with actual paint pixels and native clicks.
`integration_test/document_transform_cb_test.dart` checks the same HTML/drivers
through Android JavaScriptSandbox, real taps, geometry and two paint samples per
profile. Recreate with
`node apps/android/tool/parity/capture_document_transform_cb_chromium153.mjs`;
the fixture server supplies `/transform-cb.json`. Geometry tolerance is 1/32 CSS
px for subpixel layout rounding. Opaque pixels compare exactly. Android's 0.5
opacity composition differs from Chromium by at most one RGB level (1/255), a
recorded minor difference; alpha remains exact. Widget pixels compare exactly.

`offsetParent`, `offsetLeft` and `offsetTop` now cover the supported ordinary,
absolute and fixed paths through common 2D transforms. Native offset measurement
walks actual layout translations, ignores owned CSS paint transforms (including
singular matrices) and removes actual scroll translations. It never derives
layout coordinates by inverting painted rectangles. Viewport-fixed offsets use
the native layout position before viewport routing; local fixed boxes keep their
containing-block parent. Static-body coordinate rules distinguish ordinary flow
from positioned elements, including transformed bodies and root borders.

`test/document_transform_offset_oracle_test.dart` compares 224 independent
Chromium 153 profiles across three states. Android
`integration_test/document_transform_offset_test.dart` uses the same source
through JavaScriptSandbox. Offsets, dimensions and parent identities compare
exactly, with no coordinate tolerance. Recreate with
`node apps/android/tool/parity/capture_document_transform_offset_chromium153.mjs`;
the local server supplies `/transform-offset.json`. A positioned read requires
its actual native positioned item; missing/ambiguous owners, unsupported
framework transforms and stale frames retain explicit errors. Existing ordinary
offset references and regression checks remain covered.

Positioned and transformed block containing blocks can now own their native
scroll/clip surface. Their absolute and local-fixed entries live inside that
surface, so paint and hit testing share its scroll displacement and clip. The
actual constrained padding box remains the percentage/right/bottom basis even
when flow content is taller; borders stay stationary. `overflow:clip` excludes
trailing scroll-container padding from its reported overflow dimensions.

The independent `document-transform-scroll-chromium153.json` corpus has 192
phone/tablet, DPR 1/3 and theme profiles. Widget and Android Sandbox gates compare
three states for `auto`/`scroll`/`hidden`/`clip`, absolute/local fixed children,
percentage sizes, right/bottom placement, positioned overflow, auto heights,
content/border boxes and live size/overflow/transform changes. It also checks
viewport-fixed overlays escaping ordinary scroll/clip ancestors, switching
between viewport and local ownership, and native Canvas/button click targets.
Scroll/client sizes, offsets and parents compare exactly; rectangles allow
1/32 CSS px for browser subpixel rounding. Before/after pixels compare exactly.
Chromium and Android execute the same click observer and actual pointer taps; their before/after event counts compare
exactly, including clipped targets that must receive no click. Recreate with
`node apps/android/tool/parity/capture_document_transform_scroll_chromium153.mjs`.
Use `/transform-scroll.json` from the local fixture server and
`integration_test/document_transform_scroll_test.dart` for Android acceptance.

These gates do not certify general stacking/compositing between intermediate
ancestors, perspective/3D, individual transform properties, textual inline fragments,
inline/table/SVG containing blocks, transform-box variants or general transformed
overflow propagation. Table/zoom/fragmented offset paths and wider opacity
replacement/inline coverage remain separate differences. Missing
native boxes or unproved font bases withhold the affected computed values.
General DOM writes still need a matching native frame. CSS defaults, timing/event
variants, global getter errors and remaining DOM/layout APIs stay in the mobile
plan.

CSS `scroll-behavior` now selects the default for `window`/element scroll APIs,
numeric overloads and scroll offset setters. Native execution and the script
feedback ledger both use the matched native cascade: root styles apply to the
viewport; body styles do not propagate there. The property is non-inherited
unless `inherit` is explicit. `instant` overrides CSS smooth behavior. Clean
commands retain their resolved behavior if a later style mutation changes it.
Unmeasured defaults can still queue for the next native frame, but their
synchronous position feedback is explicitly unavailable until resolved. A default
after unmeasured style writes is taken from the next native frame; interleaved
style/scroll/style changes within one script turn are not browser-equivalent.

`document-scroll-behavior-chromium153.json` contains 224 independent Chromium
153 profiles for phone/tablet, DPR 1/3 and both themes. Native controller/cascade
checks and `integration_test/document_scroll_behavior_test.dart` compare computed
values, immediate positions and settled positions exactly through the shipped
Sandbox. The cases include auto/instant overrides, setters, aliases, explicit
inherit/unset, invalid declarations, CSS variables and frame-matched mutations.
Capture with `node apps/android/tool/parity/capture_document_scroll_behavior_chromium153.mjs`;
use `/scroll-behavior.json` from the local fixture server. Animation timing still
follows Flutter. Fragment navigation, broader scrollend/Promise semantics and general synchronous
reads after DOM/style writes remain separate differences; see the bounded
`scrollIntoView` gate below.

`Element.scrollIntoView()` now reveals actual native targets through nested
scrollports. The 216-case `document-into-view-chromium153.json` fixture is captured
independently with the guarded dedicated browser. It covers four alignments,
boolean/dictionary options, nearest containers, hidden targets, native Canvas,
button and input targets, CSS scroll margin/padding (including percentages and
font units), clipping, scale/rotation/mirroring, replacement and append/await.

Reproduce the capture with
`node apps/android/tool/parity/capture_document_into_view_chromium153.mjs`.
The shipped JS planner consumes the browser's independently measured input
geometry in `document_into_view_runtime_test.mjs`; Flutter separately verifies
native geometry and executes browser destinations in
`test/document_into_view_oracle_test.dart`. Android runs the shared HTML/driver
through the real Sandbox in `integration_test/document_into_view_test.dart`,
using `/into-view.json` from the loopback fixture server. Scroll positions and
Promise/option results are exact; affine rectangles use 1/32 CSS px tolerance.

A smooth reveal uses real native acknowledgement/activity for completion and
reports programmatic replacement or an observed stop short of its destination
as interrupted. Flutter's animation duration/curve and the time when a smooth
Promise completes remain different from this Chromium build: its root may
still move at Promise completion or after a redundant instant root request.
These intermediate pixels are not counted as matched. The Android test checks
that native await pixels are settled and a replaced root stays at its instant
endpoint. An appended target waits for a matching native frame; immediate reads
after arbitrary DOM/style writes remain unsupported. RTL/vertical layout,
horizontal root reveal, logical scroll inset properties, quirks/iframe/XML
documents, sticky/fragmented/SVG boxes, scroll snap, fractional CSS/limit rounding, unresolved inset math/complex variable shorthands and broader
invalid inset cascades are unverified. Other scroll APIs' Promise return values
and fragment navigation remain separate differences. Physical acceptance and
remote background push are still deferred as recorded in the mobile plan.

Fragment navigation now resolves rendered IDs/named anchors in browser order,
including duplicate targets, literal percent names, UTF-8 decoding and real
`top` targets. Repeating the same fragment reveals it again without adding an
entry or fetching the document. Saved history positions do not override an
explicit activation. Pending requests survive remounts, consumed requests do not
replay, and later URL/history changes invalidate old callbacks. The native
renderer keeps original ID selectors, label associations and form values.

Capture the independent 152-profile reference with
`node apps/android/tool/parity/capture_document_fragment_chromium153.mjs`.
`test/document_fragment_test.dart` checks initial URLs and actual first/repeated
link taps; the lifecycle and binding test files check remounts, replacement,
concurrent taps and preserved controls. Android runs
`integration_test/document_fragment_test.dart` using `/fragment.json` from the
loopback fixture server. Existing history behavior and the Sandbox element-reveal
suite remain separate regression gates. Positions use 1/32 CSS px tolerance;
relative history length, URL hashes, document reuse and request counts are exact.
The existing document RPC supplies a complete final URL; backend redirect/hash
inheritance is outside this renderer test.

Fragment scrolling now uses measured native layout for both ordinary and
scripted HTML, including actual nested scrollports, zero-range ports, clipping,
common affine transforms and CSS scroll margin/padding (including percentages
and font lengths). It plans all destinations before scrolling and honors CSS
smooth defaults; exact animation timing remains Flutter-specific. Initial
requests defer until the DOM index and native frame agree and earlier
DOM/history publications finish; later navigation cancels stale requests. The full parsed DOM preserves hidden head-node priority;
renderer-only IDs do not enter script packets.

Recreate the additional 280-profile reference with
`node apps/android/tool/parity/capture_document_fragment_scroll_chromium153.mjs`.
`test/document_fragment_scroll_test.dart` checks 136 non-script click/repeat
profiles and 40 initial URLs. The Android counterpart uses `/fragment-scroll.json`
from the loopback server for all 280 click/repeat profiles and 88 initial URLs,
including real Sandbox scripts and click-time style changes. All runs assert the
same document viewport after excluding the workspace's 48 px chrome.

Fragment focus now uses real native focus nodes and the existing trusted event
bridge. The former button/input exclusions are enabled. A completed native frame
composes focus centering and fragment reveal; textarea caret bounds are measured
from the owned editor, remain private to the host and do not enter VM packets.
Only instant focus scroll effects are positions; pending smooth goals are not.
Nonfocusable/disabled/hidden targets, tabindex, top/missing fragments and window
selection cancellation have explicit native behavior.

Recreate `document-fragment-focus-chromium153.json` with
`node apps/android/tool/parity/capture_document_fragment_focus_chromium153.mjs`.
Its widget gate checks 152 click/repeat and 40 initial profiles. Android's
`integration_test/document_fragment_focus_test.dart` uses `/fragment-focus.json`
for 312 click/repeat and 88 initial profiles, including real Sandbox event
reports, relatedTarget/activeElement and focus-time CSS changes. Insets, rotated
containers, already visible targets and root/inner/all smooth defaults are
included. Focus/event reports are exact; geometry uses 1/32 CSS px tolerance.
A separate widget test verifies CSS-sized toggles keep click, label, Space and
radio arrow-key behavior.

Reentrant focus redirection/navigation, filled/oversized-control caret and
selection variants, focus restoration across remount/background transitions,
broader traversal, focus pseudo styling, additional toggle box-model combinations
and exact toggle appearance/accent styling remain outside this gate. Redirected
focus records a difference.
Late target retry, hidden-until-found/beforematch revealing, unmeasured/inline/text/non-HTML
targets, RTL/vertical writing, sticky/SVG boxes, scroll snap, root horizontal
scrolling and unresolved inset math remain listed in the mobile plan. Unsupported
geometry retains the native anchor fallback; matching-frame waits are bounded.
Physical acceptance, backend redirect/hash inheritance and remote push are not
certified. Exact animation timing remains Flutter-specific.

Native `:target` styles and Sandbox selectors retain element identity across
History API URL rewrites, ID changes and workspace remounts. Navigation and
history traversal reselect before measured fragment reveal. Static cached pages
rebuild for the new target, including `display:none` targets made visible by CSS.
Recreate the 16-profile / 256-state Chromium reference with
`node apps/android/tool/parity/capture_document_target_state_chromium153.mjs`;
`integration_test/document_target_state_test.dart` uses `/target-state.json`.
The non-script widget gate covers 80 states. Actual styles and selector reports
compare exactly; rectangles/scroll use 1/32 CSS px tolerance. Broader selector,
shadow DOM, reentrant/late-load and lifecycle differences remain in the plan.

Initial scripted fragments wait for VM startup and parser/deferred target
selection without frame polling during resource I/O. The VM-selected native ID
survives load-time renames/duplicates; targets inserted only by load or later async
callbacks do not trigger an invented retry. Pending requests survive a workspace
remount and cancel on newer navigation or selection. Recreate the additional
88-profile / 264-state reference with
`node apps/android/tool/parity/capture_document_late_fragment_chromium153.mjs`;
`integration_test/document_late_fragment_test.dart` uses `/late-fragment.json`.
It covers parser/defer/module delays, inline/DCL targets, late-load negatives,
wheel scrolling, remounts beyond 128 frames and subsequent reflow. Loading timing,
streaming HTML, wider image/lifecycle behavior and pixel parity remain open.

Initial History API writes preserve the pending reveal across entry creation.
Parser/DCL routing uses the VM-selected target, while load-time URL rewrites retain
that target. Source entries captured before initial reveal keep a provisional
snapshot for their first return. The VM records the source scroll at action time;
later History writes preserve reading position. Traversal selects its target
after `popstate` and before `hashchange`.
Native nested reveal also retains an absolute root scroll issued after selection.
Root anchoring observes completed native child-layout measurements, so retained
static-page history does not wait for the bounded fallback after layout is ready.
Recreate the 288-profile / 880-state reference with
`node apps/android/tool/parity/capture_document_initial_history_chromium153.mjs`;
`integration_test/document_initial_history_test.dart` uses `/initial-history.json`.
It covers loaded/rewrite/back/forward states, no-fragment pages, multiple writes
and remounts. Relative-only initial scrolls, interleaved scroll/History callbacks,
fresh-response ordering and broader focus/load timing remain in the plan.

`document.scrollingElement` uses the initial HTML parser mode and native
box/overflow measurements to select the standards root, quirks body, or null.
`document.compatMode` is read-only. Root/body viewport metrics use the actual
viewport even without a separate html RenderBox, and identity queries do not
create a missing body. The additional 88-profile corpus covers 11 modern,
no-doctype, legacy-doctype and auto/hidden/clip overflow cases. Recreate it with
`node apps/android/tool/parity/capture_document_scrolling_element_chromium153.mjs`.
`test/document_mode_test.dart` checks the real startup payload against the
browser's compatibility mode. The combined Android gate uses
`/scrolling-element.json` on the same loopback fixture server. This follows the
[CSSOM View scrolling-element rules](https://drafts.csswg.org/cssom-view/#dom-document-scrollingelement).
Full quirks layout, inactive/XML/frameset Documents, mixed-axis routing and DOM
doctype node removal remain separate differences in the mobile plan.

Ordinary app rendering uses the platform fonts. Browser capture tools use
a dedicated test browser, never the user's everyday Chrome; see
[the test browser guide](tool/parity/TEST_BROWSER.md).

Keep source fixtures, compact expectations, regression tests and reproducible
capture tools in Git. APKs, screenshots, raw capture dumps, acceptance logs,
per-machine setup and chronological development notes stay in ignored local
output directories. Raw development output before 0.6.1 is retained locally under
`build/local-history/`, not published as project documentation. Retired tracked
plans and implementation notes are available through [Historical records in Git](../../docs/development/historical-records.md).

Historical capture metadata uses `<repository>/` for machine-local paths. This
normalization does not change the recorded browser results or claim a recapture.

Large JSON regression expectations are stored compactly; JSON values are
unchanged. Keep formatting-only capture output out of code reviews.

`document_resize_capture_test.dart` compares fractional content/border box data
with the dedicated Chromium 153 resize fixture at phone/tablet widths.
`document_resize_runtime_test.mjs` checks actual observation delivery and lifecycle
against that fixture. The Android offsets integration also exercises observer
callbacks through JavaScriptSandbox and the production native renderer. Supported
boxes and remaining observer differences are recorded in the mobile plan.

## Client language

Settings → General → Language offers English and 繁體中文. English is the default and fallback; the choice is saved on this phone and also applies to native notification/overlay controls. See [localization maintenance](../../docs/development/localization.md). New conversations open locally and enter the session list only when the first message is sent.
