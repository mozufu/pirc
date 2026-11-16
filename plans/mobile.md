# Mobile app follow-up work

[Plans](README.md) · [Build and test the app](../apps/android/README.md) · [Historical records](../docs/development/historical-records.md)

The Flutter Android app is the active client. Its native transport and tests live
under `apps/android/android`; there is no separate legacy UI module. iOS
transport is outside the agreed scope. Current features and reproducible test
entrypoints belong in the app README; completed integration and renderer diaries
are available from Git through Historical records, not repeated here.

## Architecture planning priority

The user requested [unified conversation and independent-App planning](unified-conversations.md)
on 2026-10-23 before further interface expansion. That proposal prioritizes
Chat/Work workflows, direct backend operation, native setup and shared state
contracts. Flutter Web remains an evaluation option; iOS transport and a content
renderer replacement are not newly authorized. The existing compatibility and
physical-device gaps below stay open. Planning does not establish runtime fixes.

> **Updated 2026-11-16 (N1):** the first four items below (dialog presentation, dynamic-content compatibility, scripted resource lifecycle, fragment scrolling) leave the mainline, which becomes common content, interaction, keyboard handling and smoothness; the tier list is still a proposal. See [2026-11-16 direction update](README.md#direction-update-2026-11-16).

## Remaining work, in priority order

- [ ] **Native dialog presentation:** dialog form closing, explicit `open`,
      nonmodal `show()` and `requestClose()`, and the common `showModal()` path
      now work through the script/native host. Modal dialogs paint above fixed
      content with a backdrop, block background taps and root scrolling, and
      consume Escape/Android Back through a cancelable close request. Local
      widget and script tests cover focus, close, reopen and canceled Back.
      `closedby="any"` now light-dismisses after a real backdrop pointerdown;
      a canceled `cancel` keeps it open, `closedby="none"` does not dismiss,
      and mouse/touch click ordering matches the pinned Chromium 153 oracle in
      phone/tablet widget tests. Physical Android acceptance remains pending.
      A matched Roboto fixture now gives the same 89.6 CSS px dialog width in
      Flutter and Chromium 153; the Flutter box remains 1 CSS px taller in the
      tested button-only case. Common author `position` overrides (`relative`,
      `static !important`, `sticky`, offset absolute/fixed) and positioned or
      transformed DOM parents now use the Chromium 153 top-layer containing
      block in 16 phone/tablet geometry and computed-style cases. Author `inset:auto` now uses the top-layer containing-block origin instead
      of an ordinary DOM flow marker, including positioned parents and zero
      margins. Six added phone/tablet Chromium 153 cases failed on the previous
      code (up to 68 CSS px horizontal offset); all 22 author-position cases
      now check native geometry and actual button activation. The 211 targeted
      dialog/absolute/fixed regressions and changed-file analysis passed locally. Other untested
      positioning combinations and backdrop
      pointer/hover behavior beyond the tested gestures remain unverified. Two stacked modals now
      paint both backdrops and ignore authored negative z-index for top-layer
      order. The phone/light gate keeps pointer and keyboard input in the upper
      dialog, rejects scripted focus on lower/background controls, exposes only
      the upper dialog to the root accessibility semantics tree, and restores
      lower dialog focus/semantics when the upper closes. Broader focus and
      accessibility combinations remain unverified. Chromium 153 visits a body
      focus sentinel between Tab cycles with a single-control dialog, while
      Flutter loops on that control. After light-dismissing the final dialog,
      Chromium mouse input leaves that dialog element focused while Flutter
      drops to body. Phone touch now retargets the compatibility mousedown,
      mouseup and click after light dismissal: the lower dialog receives them
      after the upper closes, the document root receives a blank-area tap after
      the final close, and an exposed button receives its tap. The script and
      native focus sequence matches the pinned Chromium 153 touch fixture;
      stale native blur from disposal is suppressed. The fixture and widget gate
      compare pointer/compatibility-mouse/focus event order, target, active
      element and resulting clicks, including the Chromium rule that canceling
      `pointerdown` suppresses compatibility mousedown/mouseup but retains click.
      The TouchEvent `touchstart`/`touchend`
      objects are still absent from the document runtime; retargeted mouse
      offset coordinates under differing target geometry and tablet/dark
      nested-modal visuals remain unverified.
      Extend default dialog positioning beyond block-only flow to mixed inline
      runs and flex/grid static-position rectangles. Modern invoker and
      dialog task-source scheduling still need coverage. Dialog handler
      attribute/IDL replacement has a bounded gate below.
      `alert`/`confirm`/`prompt`
      remain explicit unsupported APIs; do not replace them with async booleans.
- [ ] **Dynamic content compatibility:** wider synchronous DOM write/read layout,
      broader DOM APIs, Canvas font/ink coverage, inline-fragment measurements
      and common-library coverage. Broader image/framework flows remain
      unverified; preserve explicit unsupported errors. Host-layout documents
      now create connected `html/head/body` nodes for common rootless sources
      and incomplete `<html>` markup before parser scripts run. Connected
      `DocumentFragment` insertion now processes moved children so dynamic
      scripts execute once; scripts parsed via `insertAdjacentHTML()` remain
      inert even after moving. `Range.createContextualFragment()` now parses
      ordinary HTML containers and table rows; connected scripts and click
      handlers work through the native document host at phone/tablet widths.
      SVG contexts now preserve SVG-namespace descendants and live
      `ownerSVGElement` through insertion, cloning and reparenting;
      `foreignObject` contexts produce HTML children. The
      phone/tablet native SVG gate matches the fixed Chromium 153 dimensions
      and solid center pixel. The native renderer still treats SVG as one
      image, so per-shape pointer activation inside that image is not routed
      to SVG descendants. Broader SVG parsing and foreign-content visual
      integration remain unverified. Pinned Chromium 153 fixtures,
      runtime tests and Flutter widget gates cover these cases.
      Ten fixed Chromium 153 document-tree cases and four
      phone/tablet modal geometry cases cover the prior offset-packet crash.
      Less common HTML5 tree-builder recovery, such as duplicate head/body
      tags and malformed table nesting,
      remains unverified.
- [ ] **Scripted resource lifecycle and device input:** static fetched documents
      retain native controls through complete workspace removal/remount,
      same-frame replacement and reparenting. Already-authorized script file
      choosers survive temporary view removal/replacement. The shipped runtime
      and Flutter host have combined gates for fetch/abort, external classic
      scripts, choosers, simple linked styles, raster/SVG images and module graphs.
      Wider framework/resource lifetimes, responsive/lazy transitions and
      cross-provider image caching remain unverified. Check real CJK IME,
      focus and keyboard behavior across
      workspace/background/low-memory transitions on devices.
- [ ] **Fragment scrolling and target state:** complete CSS scroll margin/padding,
      nested-container alignment, remaining focus state, late-loaded targets and
      nodes discarded from rendered markup. Target lookup, initial URLs and
      repeated activation have a bounded gate below.
- [ ] **Physical phone/tablet acceptance:** use a real account for pairing,
      streaming/cancel/reconnect, panels, management consent and simultaneous
      web/app confirmations. Check keyboard (including CJK IME), safe areas,
      rotation, background, low memory, OEM permissions/notifications, terminal
      HTTPS asset origin and a release build. Verify multi-line USER/delegation
      confirmation bodies and labels, PTC approval declines/rendering, browser
      takeover tap mapping/IME/drag scrolling and WebM playback.
- [ ] **Project deletion interruption acceptance:** controlled HTTP failures
      cover partial-deletion retry UI, but physical-device/network-interruption
      recovery is unverified. Keep real-account/provider subscription acceptance
      separate from synthetic management-consent tests.
- [ ] **Remote background push:** real relay/delivery remains unverified. The
      user declined third-party relay testing; do not run it without authorization.
- [ ] **Distribution decisions:** sideload-only versus F-Droid/Play and the
      production application identity; token rotation before the 30-day expiry
      versus monthly re-pairing, including the near-expiry warning (A7); native
      Context inspector later or never. A dedicated release key is configured in
      origin's Actions secrets and Release setup passed on 2026-10-19. CI keeps
      the preview application ID; migrating from the old debug-signed beta needs
      uninstall/reinstall. Default local builds use the debug key unless release
      credentials are supplied;
      update-compatible verification APKs use the existing Release identity.

## 2026-10-20 client UX integration

Web and Flutter now share local unsent conversation creation, approval-mode warning
icons, and selectable English/Traditional Chinese UI catalogs. First send creates
the remote session; abandoning an unsent conversation creates no server record.
Automatic naming retries transient failures and falls back to the first meaningful
message while preserving manual names. The Web source viewer fixes line/gutter
alignment and horizontal overflow; Flutter retains its separate gutter.

The Flutter application root keeps its theme and input connection stable during
stream updates; widget tests exercise IME inset animation and CJK composition.
These checks do not replace the physical-device keyboard/background acceptance above.
Provider model catalogs were refreshed without replacing stored account configuration.

## Current local verification additions

Native document keyboard metadata and browser takeover key messages now retain
standard protocol names regardless of client language. The prior Traditional
Chinese path emitted translated Enter/Tab/Escape/Backspace/Control names and
could zero legacy key codes. English/Traditional Chinese gates now cover DOM
key/code/legacy values and real browser-pane hardware keys, IME deletion and
submit messages. The 57 related keyboard/browser/form/focus/i18n tests and changed-file
analysis passed locally. Physical OEM/CJK keyboard acceptance is still open;
this fix does not certify modal Tab sentinel traversal.

Terminal close errors now match the untranslated backend `not found` pattern,
like frozen Web revision `bd3d909`; Traditional Chinese no longer leaves a
missing terminal selected. English/Traditional Chinese tests verify permission
failures preserve tabs, missing terminals are removed, selection moves to the
remaining tab and closing state is cleared. The 26 related terminal/timeline
tests and changed-file analysis passed locally. The write-block parser's backend
pattern also no longer passes through translation lookup; its existing Chinese
catalog entry was identical, so no separate observed failure is claimed.

Title-only system notices now use the remaining row width, instead of sharing it
with an empty spacer. The reported `Stopped after 200 turns` text is checked
with Roboto at 320/390/768 CSS px, light/dark themes and 1/1.3 font scale. The old
layout fails six of these twelve cases. The web's single-line/long-text ellipsis
policy is retained; this does not certify every system notice layout.

Terminal glyph styles and colors remain stable through keyboard viewport changes
and unrelated conversation ticks. xterm 4.0.0 compares these objects by identity;
recreating either clears its paragraph cache. A controlled 3,000-line ANSI/CJK
replay plus 48 animated keyboard/output frames previously recreated both objects
48 times and now retains one of each. Local widget-test timings are diagnostic,
not physical-device FPS evidence. Font/theme/scale changes still invalidate the
right caches. Lease-generation changes resynchronize size and clear virtual
modifiers; unchanged controller state and visibility do not restart resize work.

Terminal zoom uses actual font metrics, grid reflow and the existing debounced PTY
resize. Two-finger pinch, Ctrl+plus/minus (including numpad) and Ctrl+0 are local
shortcuts, bounded to 8–32 logical px; they do not send shortcut characters to the
shell. One-finger history scrolling and terminal connection identity are retained.
Zoom is retained per mounted terminal tab; process-restart preference persistence
is not implemented.

Mobile terminals have two rows of Escape, Tab, slash, hyphen, Control, Alt,
directional, Home/End and Page Up/Down keys. Control/Alt apply to the next user
key/IME commit and then release; they do not modify terminal replies, replay or
clipboard paste. The native input connection remains focused across helper-key
taps. Lost control disables the keys and clears modifiers. Short viewports use a
scrollable single row; extremely short (<64 logical px after padding) viewports
prioritize the terminal surface and omit the helper row. Large font scales use
horizontal scrolling rather than clipping labels. Dedicated gates cover emitted
VT sequences, modifier consumption, paste, lease loss and small-height layouts.
Actual OEM keyboard/CJK composing, sustained-output stress, latency and gesture
feel still require the physical acceptance above. PTY reconnect/replay now swaps
the terminal model while retaining xterm's input widget and its focused IME
connection. A widget gate holds an open keyboard inset through reconnect and
confirms CJK input reaches the new socket tag; OS process and OEM keyboard
restoration still require physical acceptance.

## Deferred presentation and compatibility boundaries

The local App branch includes published 0.9.3 (`aca6eeb6`, node protocol 14).
Its gateway-owned modes, delegation approvals, calendar and checkpoints are included;
those new features still need the real-account/device acceptance listed above.
The frozen visual corpus is web revision `bd3d909`. Small visual differences,
uncommon syntax and the legacy audit's fine-grained layout/style findings remain
deferred, not verified pixel parity. New 0.6.x features, including native project
files/deletion, are outside that corpus. Original audit IDs and file references
are at `git show 7677d24:plans/mobile-audit.md`.

### Native layout and geometry

- Signed/negative vertical and font-relative top margins, empty-block
  collapse-through and parent/bottom-edge margin collapse need wider support.
  Common nonnegative pixel/percentage parent/first-child top margins, including
  the previous percentage findings, are implemented; do not reopen those fixes.
- Percentage margin settling uses actual containing-block widths with at most
  eight native passes. Missing bases or nonconvergence withhold geometry packets
  and retain committed scroll dimensions. Arbitrary standalone dry/intrinsic
  queries at hypothetical widths and cyclic intrinsic sizing are not general
  browser sizing. Cyclic percentage/fractional intrinsic grid-track sizing also
  remains outside the tested subset; fixed auto-height grid rows are implemented.
- Basic `display:flow-root` sizing and the margin barrier are covered. Float
  placement/containment and negative percentage/auto flex margins are not.
- Relative positioning supports native block/flex/grid/flow-root surfaces,
  signed pixel/percentage physical insets and zero CSS length values. Common
  nonzero `em`/`rem`/`vw`/`vh` physical insets use the native cascade's reliable
  canonical lengths, including mixed shorthand/longhands and nested relative
  ancestors. Paint and offset support use the same result; missing font/root
  font/viewport evidence remains unsupported rather than guessed. A separate
  Chromium 153 corpus checks 64 phone/tablet, DPR 1/3 and theme profiles across
  192 initial/font-change/resize states in the real fetched Flutter document.
  It compares rectangles within 1/32 CSS px, integer offsets/parent identities
  and computed style values exactly, two opaque screenshot samples exactly,
  shifted/old-position clicks and retained input edits. The unchanged old-code
  case fails by 40px. Android Sandbox/physical acceptance is not established by
  this widget gate. Other font/viewport units, `calc()`, logical insets, inline
  fragments and broader CSS syntax remain open. A parsed nonzero inline inset
  does not by itself gain offset metadata. Common absolute positioning and viewport-fixed overlays are
  implemented, including native hit targets. Common 2D transformed block
  containing blocks now support absolute/local fixed children, including
  identity transforms and dynamic ownership changes. Sticky positioning, zoom,
  table offsets and fragmented inline geometry remain open.
- General DOM writes followed immediately by geometry/style reads still need a
  matching native frame; stale, missing or ambiguous reads fail explicitly.
  Scroll-only rectangle reads now use actual native paint ancestry and affine
  matrices where proved. Native Canvas event callbacks have measured geometry
  for synchronous dispatch. A minimum height alone does not establish a definite
  height for percentage descendants.
- Common 2D `transform` functions and ordinary `transform-origin` paint and
  hit-test natively around the laid-out border box, including percentage
  translation and composed matrices. General stacking/compositing between
  intermediate ancestors,
  inline/table/SVG containing blocks, 3D/perspective, individual transform
  properties, textual inline fragments, transform-box variants and general
  transformed overflow propagation remain outside the covered subset. Table/zoom/multicolumn
  and fragmented offset paths still lack the required native offset support.
- Common block containing blocks can now own `auto`/`scroll`/`hidden`/`clip`
  overflow with absolute and local-fixed children. Positioned entries live
  inside the actual native scrollport; its constrained padding box supplies
  percentage and right/bottom bases while content can extend beyond it. Borders
  remain stationary; native paint and clicks share the scroll/clip path. A
  separate 192-profile Chromium 153 corpus checks phone/tablet, DPR 1/3 and both
  themes across three states, including reflow, overflow changes and transforms.
  Viewport-fixed overlays escape ordinary overflow ancestors and switch to/from
  local transform ownership; Canvas/button targets are included.
  Widget and Android Sandbox gates check exact scroll/client sizes, offsets and
  parent ids, rectangles within 1/32 CSS px, exact before/after pixels and real
  clipped/visible taps. Browser and Android use the same observer and compare
  actual before/after pointer click counts. Mixed-axis normalization, scrollbars,
  rounded clips and general transformed overflow propagation still need wider
  coverage.
- Common 2D transformed paths now provide `offsetParent`, `offsetLeft` and
  `offsetTop` for ordinary, absolute and fixed boxes. Measurement follows real
  untransformed native layout translations, removes native scroll displacement
  and ignores owned CSS paint transforms, including singular matrices. Viewport
  fixed offsets use the actual pre-routing layout position. The static-body
  rules distinguish ordinary flow from positioned content, including body
  transforms and html borders/margins. Native widget and Android Sandbox gates
  check 224 Chromium 153 phone/tablet, DPR 1/3 and theme profiles across three
  states, including dynamic ownership changes, Canvas/buttons, negative-half
  rounding and root/enclosing scrolling. All integer offsets, dimensions and
  parent identities compare exactly. Positioned reads require a real native
  positioned item; missing/ambiguous owners, unsupported framework transforms,
  fallback-flow positioning and stale frames withhold offset metadata. This
  does not provide general synchronous DOM write/read layout.
- The transformed-containing-block corpus has 136 Chromium 153 phone/tablet,
  DPR 1/3 and theme profiles, each checked before scrolling, after root/enclosing
  panel scrolling and after transform mutation. It covers static/relative and
  nested hosts, nearest-owner selection, identity transforms, percentage sizing,
  transformed children, Canvas and native buttons. Widget and Android Sandbox
  gates use the same sources and actual native clicks. Geometry allows 1/32 CSS
  px for subpixel rounding. Both compare two painted samples per profile;
  opaque pixels are exact. Android's 0.5 opacity RGB composition differs by at
  most one level (1/255), with exact alpha; widget opacity pixels are exact.
  Common block opacity now groups its positioned children too. Wider inline and
  replaced-element opacity, zero-opacity accessibility semantics, transitions
  and intermediate stacking groups remain unverified, rather than certified
  by this case.
- Two root-height fixtures retain extra trailing blank scroll space: 8 px with
  the default body margin and 17 px with nested content-box edges. Their element
  rectangles match Chromium; these scroll-extent differences remain deferred.
- Root horizontal scrolling, scrollend/Promise semantics, mixed window/element
  event order, RTL, scroll snap/anchoring and nested touch scroll chaining need
  wider coverage. Common vertical root and nested-container scroll anchoring are
  covered. Retained documents keep root/nested offsets through full view
  remounts and document switches; fresh responses start new nested positions.
  Smooth-scroll timing follows Flutter.

### Computed styles and scripts

- `getComputedStyle()` reads the native cascade and completed layout for a
  supported subset. Declarations are read-only and live across accepted frames;
  inline `element.style` remains independent. Enumeration is the supplied subset,
  not Chromium's full property list. Omitted recognized properties,
  pseudo-elements, stale frames and unavailable declarations fail explicitly.
- Common HTML 2D `transform` matrices and `transform-origin` now use the native
  transform parser and real untransformed border-box dimensions. Matrix values
  exclude the separately reported origin and preserve identity versus `none`.
  Hidden elements have no used transform and preserve percentage origins.
  Retained declarations update after accepted native layout, including class,
  size, transform and hidden-to-shown changes. An independent 128-profile
  Chromium 153 corpus covers phone/tablet, DPR 1/3, both themes, border/content
  boxes, Canvas, empty and hidden elements. Native widget and Android Sandbox
  gates check both states; styles compare exactly and rectangles use 0.001 CSS
  px tolerance. Unsupported reference boxes/font bases and missing measurements
  withhold affected values. This does not establish synchronous DOM write/read
  layout or full CSS transform inheritance, animation or SVG serialization.
- Inline-fragment and unmeasured list-item dimensions, auto margins, platform
  form-control UA properties, CSS font shorthand and unsupported length
  expressions remain outside this surface. The full browser
  `CSSStyleDeclaration` prototype/property surface is not implemented;
  custom-property names currently use the ASCII subset.
- Style limits: 256 properties, 128-character names, 4,096-character values and
  16 KiB of names/values per node; aggregate encoded style data is capped at
  2 MiB. Inheritance collection is bounded. Oversized/unavailable declarations
  are withheld whole, never truncated into apparently unset custom properties;
  geometry remains available.
- Generic native UA font-family names may differ from Chromium's resolved names
  (`serif` versus `Times`); custom-property comma whitespace normalization also
  differs. Default text/list fixture heights retain these measured boundaries
  at both viewport widths:

  | Element   | Native height | Chromium height |
  | --------- | ------------: | --------------: |
  | html      |     197.88 px |      184.875 px |
  | body      |     173.88 px |      152.875 px |
  | paragraph |         16 px |           18 px |
  | heading   |         32 px |           37 px |
  | list      |         16 px |           18 px |

  Native font metrics account for line-box differences; root/body also retain
  flow/margin differences. Native computed heights report actual native boxes.
  These boundaries do not exempt explicit block sizes, percentage edges,
  relative inset values or list content width from comparison.

- Some inserted classic-script lexical-scope behavior differs from browsers.
  Arbitrary websites/frameworks, third-party cookie policies and full browser API
  coverage are not guaranteed.

### Implemented interactive content

Native details disclosures now synchronize reflected `open`/`name`, attribute
writes (including Attr nodes), same-tree named groups, dynamic insertion and
coalesced trusted `toggle` events with old/new state. Inline/property handlers,
cancellation and nested interactive children use the script event pipeline.
Flutter summary padding, text, Enter/Space and accessibility activation share
that pipeline; summary focus survives same-document updates and authored open
changes still apply after native interaction. An independent Chromium 153 corpus checks 28 states; eight phone/tablet,
light/dark, DPR 1/3 widget profiles gate native activation and focus. These are
functional gates, not a new pixel-parity claim. Details without an authored
summary still use a local native fallback (script synchronization is unverified).
Script key-event cancellation, arbitrary shadow-tree details and separate
browser task-source ordering remain open. DOM notifications use
the bounded host-pumped callback scheduler; physical Sandbox/device acceptance
is not established by the Node/widget tests.

Fragment links now reveal containing details bodies from inner to outer before
native layout/focus/scrolling. Initial URLs, repeat activation and history
traversal preserve the selected node; links to a details element or its first
summary do not open that element itself. Named peers close consistently. Static
fetched documents retain live disclosure attributes across native reparses,
resize and remount; eligible declarative form drafts follow the existing
history-control policy. Live file selections, passwords and autocomplete-off
values survive presentation reparses and retained views. Static fetched
responses now own detached native control models in memory, so these values,
selected file bytes and text selection also survive complete workspace
removal/remount, same-frame replacement and GlobalKey reparenting. Reset keeps
authored defaults; a fresh response, closed document or retired account cannot
inherit excluded values or late picker results. Eligible history snapshots stay
separate and never export password/file/autocomplete-off values. CJK composing
ranges survive a static viewport reparse in widget tests; real IME and focus
transitions still require physical acceptance. A completed traversal is not
replayed on remount.
An independent eight-profile Chromium 153 control corpus checks 40 states.
Twenty-two native tests cover restoration, delayed file selection, retirement,
Reset and fresh responses. These are static-document value/ownership gates,
not new pixel proof or certification of scripted picker/resource lifetimes.
The independent Chromium 153 corpus covers 96 phone/tablet, DPR 1/3, theme and
initial/click profiles and 432 states. Native widgets compare 288 visible target
rectangles/root positions within 1/32 CSS px, exact focus/open state, nested
scroll offsets, repeat/history operations and subsequent reading-position
retention. Node tests independently compare DOM target/open state and toggle
ordering. There is no new screenshot/pixel or Android Sandbox/physical proof.
`hidden=until-found`/`beforematch`, broader flat/shadow-tree revealing and late
loading/reparenting remain open. Closed-details descendants still use the native
no-box geometry contract; Chromium can expose retained/forced layout rectangles
for these descendants. This difference is explicit rather than inferred from
visible-target success. Custom disclosure markers and general content-visibility
layout are not certified by this corpus.

Script-initiated file choosers now keep their already-authorized lease when
only the current document's Flutter view is removed or replaced. Queued chooser
requests still expire while hidden; document/account retirement or a window
selection change discards late bytes/errors. A discarded result releases its
lease so it cannot block a later chooser. Current renderers reconcile retained
file bytes even when the returned HTML is unchanged. Layout/activity ownership
prevents the previous renderer's cleanup from freezing its same-frame successor.
An independent Chromium 153 chooser corpus covers eight phone/tablet, DPR 1/3
and theme profiles across 40 states, using temporary synthetic file paths and the
browser chooser protocol (buffer injection does not prove trusted events).
Nine Node checks compare the production runtime's exact bytes, FormData names,
script initialization count, trusted input/change order, duplicate completion,
Reset and fresh-document state. Sixteen native widget profiles, ten fetched-host
lifecycle scenarios and two lease/ownership tests cover restoration, cancelled
or failed selection, Reset, document/account retirement and window changes.
The fetched-host tests use controlled bridge responses; they do not certify
Android engine IPC, actual system chooser/IME behavior, pixels or wider resource
lifetimes. Existing file-count, native byte retention and script byte limits
still apply.

An additional local integration gate now executes the shipped JavaScript bundle
through the production Dart task/layout/resource host and actual Flutter
workspace. A test-only Node VM supplies engine IPC; HTTP/chooser responses use
synthetic transport fixtures. No DOM snapshots or native geometry are fabricated.
Sixteen phone/tablet, DPR 1/3 and theme/replacement cases compare five states
against an independent eight-profile Chromium 153 resource corpus. They check
fetch/JSON completion after remount, external classic-script execution once,
AbortController cancellation, native editor values, live computed background
colors and actual panel rectangles within 1/32 CSS px. Eight additional chooser
cases run the previous browser fixture through this full chain, comparing exact
bytes, FormData names, trusted input/change events, Reset and one initialization.
Resource callbacks wait while the document view is fully detached and resume on
reattachment; the browser reference can run callbacks while merely CSS-hidden.
That scheduling difference is explicit; the resource gate compares resumed
outcomes. This gate adds no screenshot/pixel claim and does not replace actual
Android Sandbox IPC, native transport/CORS/cookie policy or system picker/device
acceptance. Broader framework flows remain separate work. Release CI prepares
Node.js 22 for these widget tests.

Script-managed raster HTML images now use the same document-owned decoded
version as JavaScript and Canvas, avoiding an independent display fetch that
could return a different image. Startup defers display fetching until script
ownership is known; an unavailable engine releases ordinary image loading.
Image state is a separate bounded snapshot projection, not authored HTML/CSS
attributes. Unknown handles, duplicate element IDs and invalid states fail at
the host boundary. Current HTML references retain their native image versions;
retirement still belongs to the document pool. Multi-frame images retain the
animation provider.
Presentation updates of the same script snapshot now preserve native controls
locally; they do not replay a stale history projection into a VM that may already
have changed those values. A fresh script snapshot remains authoritative.
The independent eight-profile Chromium 153 asset corpus covers 48 states,
including a no-store image with a deliberately different second response.
Twenty-four native scenarios compare 88 states through the shipped runtime,
real styles/layout/controls and actual image decoding. They check linked CSS,
initial/dynamic raster images, retained input, an imported module dependency,
module cache reuse and one execution per module across view replacement.
Panel rectangles use 1/32 CSS px tolerance, live colors compare exactly, and
448 opaque screenshot probes compare both the HTML image and Canvas exactly.
This is bounded pixel evidence, not whole-page screenshot parity.
Managed SVG images now share an immutable copy of the original source with the
Canvas decode. Display uses `SvgPicture.memory`, preserving vector scaling and
existing intrinsic/table sizing; it never substitutes the pool's bitmap. Source
copies exposed by the document pool are immutable to callers. The pool reserves
at most 32 MiB in aggregate (including retiring versions) and drops its source
references with their decoded versions. Failed and obsolete decodes return their
reservations. This is a pool budget, not a process-wide memory ceiling: Flutter's
existing SVG/vector caches may retain loader/compiled entries until their normal
eviction. At the source-cache limit, SVG
keeps its established vector/provider path; that case may refetch and is not
certified as source/pixel parity. A separate eight-profile Chromium SVG reference
checks the same 48 browser states and 88 native comparison states/448 opaque
pixels through actual loading, remount, same-frame replacement and startup. A
stopped-script case retains the loaded vector without fetching again. A 2x2 SVG
enlarged to 128x128 also checks distinct opaque colors within one bitmap texel,
proving the display remains vector-based. These gates do not certify arbitrary
SVG filters, fonts, animations or Canvas vector rasterization at every scale.
Unobserved ordinary, responsive/picture and animated images retain the
established native image provider and candidate selection. Script-side image errors
also retain the established display fallback, including sources outside the
script image decode limits; error-state pixel equivalence is not certified.
Late script observation can therefore perform another fetch. Cross-provider
caching, wider responsive/lazy and pending-image presentation, complex stylesheet
imports/module graphs and real Android/transport/device acceptance remain open.

Dialog form closing now stays in the document: effective `method="dialog"`
(including submitter overrides) validates and fires submit as appropriate, closes
its nearest ancestor dialog and sets its return value without constructing
FormData or a navigation command. Native forms without authored scripts activate
the runtime for dialog semantics. The transport-side unsupported-method guard
is preserved. `HTMLDialogElement`, reflected `open`, independent `returnValue`
and `close()` cover the tested closing path; cloned elements have independent
return state and public construction is illegal. Closed dialogs default to
`display:none`, with author display overrides respected by paint and computed
style. Captured invalid events now reach ancestor capture listeners as trusted
UA events; public synthetic events remain untrusted.

A separate Chromium 153 reference has 15 programmatic states and eight
phone/tablet, DPR 1/3 and theme profiles with six real-input states each. The
shipped runtime/Flutter gate checks values, captured event fields, native visibility,
rectangles within 1/32 CSS px and eight unobscured background pixel probes.
Native edits and closing survive complete view removal/reattachment without a
second engine or navigation. Submit cancellation, invalid/novalidate inputs,
external submitters, direct submit, no submitter, method overrides and authored
close-method overrides have gates.

Two differences remain explicit: the host's timer queue sends `toggle` before
`close`, while the captured Chromium pointer path sends `close` first. Tests
assert both observed orders separately and compare their payloads; they do not
claim event-loop parity. The [HTML Standard's dialog algorithms](https://html.spec.whatwg.org/multipage/interactive-elements.html)
use distinct task sources for those notifications. Native validation feedback
paint can obscure a different area than Chromium's popup; invalid-state geometry
and behavior are checked, but that covered pixel is not a parity claim. The
subsequent common `showModal()` implementation is summarized at the top of this
plan; default dialog UA layouts beyond the supported block-only gate and the
remaining APIs are still unfinished. These gates do not establish complete
dialog support or physical Android acceptance.

Nonmodal `show()` now fires a cancelable trusted opening `beforetoggle`, respects
cancellation and listener changes, and coalesces asynchronous toggle events.
Repeated show calls do not steal focus. Initial focus delegates to an eligible
autofocus descendant, then the first focusable descendant, then the dialog;
closing restores the previously focused eligible control only while focus
remains inside. External focus is preserved, restoration uses `preventScroll`,
and authored `.focus()` replacements do not intercept the internal algorithm.
Closed nested dialogs are skipped by the focus eligibility check. Dialog native
focus nodes are programmatically focusable without adding an ordinary Tab stop.

`document-dialog-show-chromium153.json` records 24 independent programmatic
opening/focus cases, including synchronous and settled event payloads, plus
eight phone/tablet, DPR 1/3, light/dark profiles with eight actual-input states.
The shipped runtime and real Flutter host check native primary focus, edited
values, local return values, visibility, geometry and 32 background probes.
The authored `position:static` fixture also retains a known difference: after
replacing dialog contents with a default `<p>`, Chromium moves the dialog's top
to 48 CSS px through margin collapse; Flutter keeps it at 32 CSS px. Tests assert
both measurements explicitly; the other rectangle components/states remain
matched, and corresponding dialog-local background probes do not assert equal
screen positions for that state. The browser's default positioning/intrinsic
layout beyond the block-only positioning gate below is still pending. Full
stylesheet-driven synchronous focus eligibility, shadow/
scrollable focus delegates, text selection on dialog focus, popover interaction,
render-task scheduling of hidden-focus cleanup and physical keyboard/IME focus
remain outside this bounded focus gate. The close/toggle task-source ordering
difference above is also retained; these gates do not certify a full browser
event loop.

Full fetched documents now opt into normal-origin dialog UA declarations. Any
normal author rule, including `*`, outranks those defaults; inline and important
rules retain their existing cascade rank. Closed visibility, fit-content sizing,
1em padding, 3px solid current-color borders and Canvas/CanvasText colors use the
same cascade for native paint and computed style. Used color scheme follows
inherited, explicit and variable-authored declarations. The generic author-only
style engine remains unchanged unless dialog defaults are requested.

Supported block-only static-position paths retain a zero-size native flow marker
when a positioned box is extracted. Actual marker layout determines the auto
axis; it is not inferred from CSS lengths or a previous screenshot. Positioned
fit-content width remains intrinsic instead of stretching between definite
insets. Native measured insets also supply the auto-axis CSSOM values. The new
`document_live_runtime_dialog_layout_test.dart` gate uses the shipped runtime,
actual Open/Close/Tint controls and a separate Chromium 153 reference at eight
phone/tablet, DPR 1/3 and light/dark profiles. Its five states check visibility,
rectangles within 1/32 CSS px, unchanged following-flow positions, computed styles
and 72 border/padding/content pixel probes, including dynamic authored color.

This does not implement modal presentation or certify arbitrary dialog layouts.
Mixed inline runs, flex/grid static-position rectangles, float/vertical-writing
static positions, general normal-flow fit-content sizing and embedded Markdown
UA dialog presentation remain unfinished. The block marker path is gated out
when its formatting-context evidence is missing. The existing default-paragraph
font-relative margin difference and broader focus/event-loop limits above remain.

Nonmodal `requestClose()` now fires a trusted, non-bubbling cancelable `cancel`
and closes through the internal algorithm only when accepted. Cancellation
preserves the return value, edited controls and current focus. Argument conversion
precedes state checks; disconnected/closed dialogs do not receive requests;
`closedby="none"` does not suppress an explicit request. Removed/reinserted dialog
subtrees invalidate the old pending request and focus restoration target.
Reentrant requests use the captured Chromium close-watcher enable lifetime and
pending return value, including distinct default/none versus any/closerequest
behavior. This is not a public `CloseWatcher` implementation or platform dismissal.

`oncancel`, `onclose`, `onbeforetoggle` and `ontoggle` now share their HTML-attribute
and IDL listener slot. Replacing a function preserves listener order, including
replacement during dispatch; `null` removes the slot, and a subsequent assignment
registers a new one. Returning `false` cancels cancelable events. Attr.value,
set/removeAttributeNode and toggleAttribute mutations use the same private DOM
reaction, without reattaching callbacks during snapshot decoration. The shared
`ontoggle` path also retains existing details disclosure behavior.

The independently captured `document-dialog-request-close-chromium153.json`
contains 44 synchronous/settled API and event-handler cases plus eight
phone/tablet, DPR 1/3 and light/dark interaction profiles. The shipped-bundle Node
gate checks those states; the real Flutter workspace gate checks all 56 native
interaction snapshots, retained CJK/emoji input, native input/button focus, no
navigation, one engine and clean retirement. The existing pointer close/toggle
order difference is explicitly asserted in both orders, not normalized away.
General event-handler compilation scopes, lazy syntax-error handling and unusual
non-callable callback objects are not certified. Full focus-event behavior for
arbitrary DOM removal/reparenting and a browser rendering-task scheduler remain
outside this gate, as do modal, Escape/Back and physical-device acceptance.

Tool-running and background-stopping loader icons now share the web's continuous
one-second rotation. The memory loader retains its size and uses the same native
widget. Hidden surfaces pause their ticker; reduced-motion settings show the
resting icon. Frame-driven tests verify quarter/three-quarter turns, repeated
cycles, completion removal, hidden/resumed surfaces and reduced-motion stopping.
Real Android frame pacing remains part of physical-device acceptance.

Native Canvas supports matched text measurement, intrinsic/pixel/percentage
sizing, container resizing, the eight stock Chart.js chart types and their default
animations. Covered bar interactions include touch tooltips, outside dismissal,
legend hide/show and redraw with real glyph ink bounds. MutationObserver handles
common live DOM changes, and animation callbacks receive current native geometry.
Document visibility suspends pending callbacks. These bounded gates do not certify
arbitrary chart configurations or frameworks; unsupported reads fail explicitly.

Root and nested vertical scroll anchoring use actual native clips and shared DOM
identity. Simultaneous root/outer/inner compensation, node replacement, hide/show,
style suppression and end clamping are covered. Text/focus/find priority,
RTL/horizontal writing, scroll snap/padding, complex transformed/out-of-flow
geometry, image-load identity and simultaneous smooth scrolling remain open.

Native root/element scroll commands now execute in their authored order. A
relative command uses actual current pixels, including after a smooth command;
instant-then-smooth retains the instant starting position. Same-position,
zero-delta, omitted-axis and empty-option commands cancel prior animations.
Native-frame scroll events still coalesce. The Chromium 153 command corpus has
160 phone/tablet, DPR and theme profiles; widget tests compare immediate native
positions and settled positions. Android checks immediate and settled JS readings
through the actual sandbox and native Run button.

**Scroll-position feedback:** root/element getters replay only unacknowledged
commands over actual native positions and programmatic ranges. Consecutive
`element.scrollTop += 20` calls now reach 40. Each accepted native packet names
its processed command prefix, so an older frame cannot erase newer commands or
replay an already consumed relative command. Native ranges include disabled axes
and clamping; smooth destinations are not treated as current positions. The
standards root uses viewport measurements even without a separate html box.
The additional Chromium 153 feedback corpus has 96 profiles for setters,
clamp-then-subtract, mixed methods, smooth cancellation, Promise jobs and RAF.
The position-feedback corpus compares 256 profiles, including aliases and
intermediate traces; the former 80 immediate-read mismatches are resolved.

`document.scrollingElement` and read-only `document.compatMode` are now supplied
for the active HTML document. Native startup passes the existing HTML parser's
initial mode, including valid strict/limited/quirks legacy doctypes. Guest
masking of `document.doctype` cannot change that mode. Standards roots and quirks
viewport-owning bodies use measured viewport positions, scroll extents and client
sizes. Quirks selection uses current native box/overflow evidence, including the
root-clip exception; absent or stale evidence is an explicit unsupported read.
Ownership queries inspect existing children and do not create a missing body.
The additional 88 Chromium 153 profiles cover 11 mode/overflow cases at phone and
tablet sizes, DPR 1/3 and both themes. The ownership/position corpus checks 344
profiles through the actual Sandbox and native Run button; rectangle coverage
extends the combined gate below.

This gate does not certify full quirks layout, inactive/DOMParser-created
Documents, XML/frameset documents, mixed-axis overflow normalization or mixed
viewport/body scroll routing. DOM doctype node removal and DocumentType ChildNode
helpers (including `.remove()`) remain unsupported by the vendored DOM; the mode
mutation test covers legal property masking, not successful node removal.

**Scroll-only rectangle feedback:** `getBoundingClientRect()` and
`getClientRects()` replay unacknowledged commands using real native paint
ancestors, measured scroll ranges and affine 2D coefficients. Root, nested and
combined scrolling, clamping, instant/smooth sequences, fixed/unrelated boxes
and actual Canvas taps are covered by 128 additional Chromium 153 profiles.
Canvas pointer rectangles are not reused after a pending script scroll. Native
2D transforms preserve the border-box origin and normal-flow allocation while
also transforming paint and hit tests. The combined Android gate covers 472
profiles; the original 344 remain exact comparisons, and the new rectangle
cases use at most 0.001 CSS px tolerance for affine floating-point differences.

Native proof includes every real owned scroll viewport, including visible or
zero-range wrappers, and stops at a proved viewport-fixed boundary. Metadata is
bounded to 64 scroll ancestors per box and 16,384 references per packet. Missing
or stale proof, sticky/unsupported positioning and nonaffine geometry retain
explicit errors. Browser expectations are captured independently, including
scroll displacement coefficients; native output does not generate them.

**CSS default scrolling:** window/element scroll methods, numeric overloads and
scroll offset setters now honor the matched native `scroll-behavior` value.
The root supplies the viewport default; body styles do not propagate to it.
The property does not inherit unless explicitly requested. `instant` overrides
CSS smooth behavior, and clean commands freeze the resolved choice at call time.
Native execution waits for the actual cascade when a dirty style frame is still
pending; synchronous feedback with an unresolved default fails explicitly.
Interleaved style/scroll/style calls within one turn use the next measured
default and can differ from the browser call-time choice.
A 224-profile Chromium 153 corpus checks computed values and immediate/settled
positions exactly, with native controller/cascade and Android Sandbox gates.
Valid/invalid CSS variables, inherited/unset values, setter/alias calls and
frame-matched class changes are included. This does not certify fragment navigation, exact timing or reads immediately
after dirty writes. `scrollIntoView` has the separate bounded gate below.

**Native element reveal:** `Element.scrollIntoView` uses actual native scrollport
sizes, origins, invertible affine axes and bounded ancestry. It supports the
common standards-mode horizontal LTR block/inline alignments, legacy boolean arguments,
`container:nearest`, nested auto/hidden ports (including zero ranges), current
native scroll ranges, CSS scroll margin/padding, and clipped propagation to
outer ports. Canvas, buttons and text inputs retain real measured targets;
raw document text/select/date/file controls are measured at their replacement
border box rather than a discarded parser placeholder. Unproved geometry is
rejected before queuing any part of a reveal batch.

The 216-profile Chromium 153 corpus covers phone/tablet, DPR 1/3 and both themes.
Native geometry producers are checked separately from the shipped JS planner,
and Android executes the same source in the real Sandbox. Instant positions,
boolean/dictionary conversion, getter order, rejected enum errors, descriptors,
Promise result dictionaries and nested destinations are checked. Smooth reveals
wait for native action acknowledgement and actual native scroll activity; the
host refreshes completion activity even when final pixels have stopped changing;
replacement and stopped-away-from-target completion return `interrupted:true`.
A newly appended element can be revealed after the next native layout frame.
This does not make mutation-then-read layout synchronous.

Explicit reveal differences: Flutter retains its native animation curve/duration
and resolves a smooth reveal after all owned native targets stop. The frozen
browser can resolve while its root is still moving. A redundant instant root
request cancels a preceding animation in Flutter; this Chromium build can drift
beyond that zero-distance request. Those timing differences remain listed and
are not claimed as matching intermediate pixels. Wider native gesture
interruption acceptance, scrollend ordering, RTL/vertical writing, horizontal
root scrolling, logical scroll inset properties, quirks/iframe/XML documents,
sticky/fragmented/SVG geometry, scroll snap, fractional CSS/limit quantization and unresolved CSS inset math/complex variable shorthands remain
outside this gate. Invalid inset declarations also need wider cascade coverage.
Other scroll methods' Promise return semantics and broader fragment scrolling
remain separate work; the selection/activation gate is below.

**Fragment selection and activation:** rendered HTML resolves IDs before named
`a` anchors and retains the first match in tree order. Literal fragment names
are tried before UTF-8 percent decoding; plus signs are preserved, malformed
percent/UTF-8 sequences are handled, and an actual `id`/`name="top"` wins over
the case-insensitive top-of-document fallback. Hidden targets do not fall back
to the page top. Private rendering aliases keep duplicate anchors distinct and
leave original IDs available to CSS selectors, labels, controls and scripting.

Repeated activation of the same URL requests another reveal without creating
a history entry or repeating HTTP. Explicit activation ignores an old saved
offset and still works in manual restoration mode. Requests survive a workspace
remount until consumed; consumed requests are not replayed. Later history/URL
changes invalidate stale callbacks. Internal alias resolution does not suppress
real link taps during an in-progress reveal, and swapping a viewport controller
rebinds its index without changing the document.

The independent 152-profile Chromium 153 corpus covers initial URLs and actual
first/repeated link clicks at both sizes, DPRs and themes. Flutter checks those
flows plus lifecycle, CSS-ID/label/value preservation and existing history
regressions. Android covers the actual native workspace's 152 click/repeat
profiles and reruns the 216 Sandbox reveal profiles. Source URLs are delivered
as complete final URLs by the existing document RPC; backend redirect/fragment
inheritance is not newly certified by this renderer gate.

**Native fragment geometry:** ordinary HTML and scripted pages now use the
same measured native layout evidence as element reveal. The host computes every
scroll destination before applying any command, using real inner-to-outer
scrollports (including zero-range ports), clipping, affine transforms and actual
scroll limits. Physical CSS scroll margins and padding include measured font
lengths and percentage padding. Root and nested `scroll-behavior` defaults are
honored; smooth animation timing still follows Flutter rather than Chromium.
Initial requests wait for their DOM index, matching layout revision and prior
DOM/history publications to drain, so the initial handoff cannot discard a
new smooth animation; later history/URL changes cancel a pending request. Renderer-only IDs remain outside
script layout packets, and private captures can select a bounded subset from a
larger document. The index now uses the full parsed DOM, so discarded head nodes
retain their priority over a later rendered duplicate.

The additional Chromium 153 corpus contains 280 profiles at phone/tablet sizes,
DPR 1/3 and both themes. The workspace has 48 CSS px of app chrome, excluded from
the browser document viewport; native tests assert the same available viewport.
The native geometry test now includes all 280 first/repeated profiles, plus 88
initial-load profiles with and without real Android Sandbox scripts. It includes CSS padding/margins,
negative margins, font lengths, percentages, transformed ports/targets, hidden
and oversized targets, Canvas, zero-range ports, root padding and click-time DOM
style mutations. Widget tests cover the 136 non-script first/repeated profiles
and 40 initial-load profiles. These are coordinate/navigation checks, not a
claim of pixel-perfect rendering or all fragment behavior.

**Native fragment focus:** the former button/input focus exclusions are now
enabled. Native DOM focus moves before reveal, and the existing trusted event
bridge delivers blur/focusout/focus/focusin with activeElement and relatedTarget.
Focusable links, controls and tabindex targets (including -1) receive
native focus; disabled, hidden and inert targets are not focused.
Nonfocusable targets clear document focus, while top fallback/missing anchors
retain the link's focus. The selected native node is retained across the focus
publication rather than reselecting another duplicate ID.

Focus centering and start/nearest fragment reveal are composed from one completed
native frame. Only the host's own instant scroll effects are translated through
proved native axes; a pending smooth focus goal is not treated as a position.
Textareas use their actual RenderEditable caret rectangle, checked against the
same target/root/revision. This private caret evidence never enters VM packets.
Native deferred caret reveal is suppressed during the focus handoff. Changing
the selected window cancels the pending navigation and cannot steal focus or
replay it on return; remount retention remains a separate existing contract.

The additional 312-profile Chromium 153 focus corpus covers actual native focus,
settled nested positions and first/repeated clicks at both sizes, DPRs and themes.
Android also checks 88 initial loads, with real Sandbox scripts, trusted event
order and relatedTarget/activeElement, including focus handlers changing CSS
margins. It covers buttons, inputs, textareas, selects, checkboxes, links,
tabindex, disabled/hidden/nonfocusable targets, top/missing fragments, insets,
rotation, already visible targets and root/inner/all smooth defaults. The
non-script widget gate has 152 click/repeat and 40 initial profiles. A separate
widget gate checks CSS-sized toggle activation, labels, Space and radio arrow
keys. The browser geometry tolerance is 1/32 CSS px; focus identity and event
reports must match exactly. Exact animation timing is still Flutter-specific.

**Native `:target` state:** native styles and scripted `querySelector(All)`,
`matches` and `closest` share the retained target identity. Literal/decoded IDs
and named anchors use fragment priority; hidden targets participate before
layout. Actual navigation (including repeated URLs) and history traversal
reselect; `pushState`/`replaceState`, ID mutation and view remounts do not. The
VM selects the initial target after DOMContentLoaded and before load, invalidates
layout when target identity changes and publishes its renderer ID separately
from markup. Static cached pages rebuild for the target revision before reveal,
so target-dependent display/size changes cannot use the old geometry.

A pinned Chromium 153 corpus covers 16 phone/tablet, DPR 1/3 and theme profiles,
with 256 states: first/repeated links, named/encoded/hidden/missing/top/empty
fragments, History API rewrites/traversals, renamed and duplicate nodes, removal
and reinsertion. Native Android tests compare actual computed styles, rectangles,
root scroll and Sandbox selector reports; the non-script widget gate covers
80 states. Scripted profiles also remount the workspace after pushState and keep
the same VM. Existing selector syntax limits still apply (`:is`/`:where`/`:has`,
pseudo-elements and shadow DOM are not established by this gate). Late target
selection outside the initial parser/defer boundary, image-driven retries,
reentrant navigation and broader browser lifecycle variants remain open. Unit checks also cover target marker collision avoidance,
malformed UTF-8/BOM decoding and detached-node identity.

**Initial generated targets:** the workspace now waits for VM startup and the
parser/deferred-script target-selection boundary using listeners, without burning
128 layout frames while external resources are pending. This includes the first
frame before `start()` has begun. Successful initial selection retains the VM's
node identity for native reveal; load handlers can rename it or insert an earlier
duplicate without changing the node being revealed. A null selected target stays
missing even if a load handler or a later async script inserts a matching ID.
Pending initial requests survive workspace remounts; document replacement,
selection changes and history/URL changes cancel stale waits and release listeners.
A script startup failure releases the wait for the existing fallback/error UI.

The additional Chromium 153 corpus covers 88 phone/tablet, DPR 1/3 and theme
profiles, with 264 before/load/reflow states. Android uses the real Sandbox while
only page/script HTTP is synthesized. It controls parser/defer/module/async
resource completion, exercises initial inline and DOMContentLoaded insertion,
load-time rename/duplicates, user wheel scrolling while the parser is blocked,
and reflow after initial selection. The remount case holds the resource beyond
128 frames and then reveals the same retained document. Native selector/style/
rectangle reports and root scrolling are compared with the shared browser source;
geometry allows 1/32 CSS px. This does not establish exact loading timing or
pixel-perfect output. The initial focus/load event order and removal of a
selected node before its first native frame remain uncertified.

**Initial History API routing:** pending initial target reveal now survives
`pushState`/`replaceState`, including the shared entry-insertion path. The VM's
selected node determines reveal after parser/DCL URL rewrites and remains selected
through load-time rewrites. HTML documents initially lacking a fragment also wait
for that initial selection; removing a fragment does not invent a top jump over
a script-established reading position. Initial selection waits for parser completion
and queued History actions; native reveal separately checks published layout. A
no-op layout refresh cannot strand the selection waiter.

A source entry captured before initial reveal records that its scroll snapshot
is provisional. The VM captures this marker and the measured/projected root
position when it queues the History action, before later host publications. Its
first traversal prefers a currently resolvable fragment and
otherwise keeps the captured native position; after reveal its actual offset is
recorded normally. This marker survives entry metadata/refetch copies. Valid
reading snapshots on reload/refetch retain their established restoration path.
A root absolute scroll accepted after initial target selection is reported by the
VM; native initial reveal retains nested-container work while preserving that
root position. Relative scrolling after an absolute reset shares the same root
base. A scroll before selection still yields to the initial fragment. Traversal updates
URL/state before `popstate`, selects the target after that callback, then emits
`hashchange` when applicable. Reading-position restoration also waits for destination
layout and anchor compensation, avoiding an extra shift when `:target` changes
height. Root anchoring also listens for completed native measurement frames:
a deferred child layout can become ready without relaying out its viewport.
The retained static-HTML Back/Forward regression checks both saved offsets and
completion in fewer than 20 test pumps, without `history_layout_not_ready`; the
old path waited 130 pumps. This is a host lifecycle regression, not a browser
animation/timing guarantee or new Android-device acceptance. Truly unavailable
geometry still uses the bounded native reading-position fallback and records
`history_layout_not_ready`.

The Chromium 153 initial-History corpus covers 288 phone/tablet, DPR 1/3 and theme
profiles and 880 loaded/rewrite/back/forward states. It checks parser, DCL and load
writes; both methods; same/other fragments, query routes, fragment removal;
initially fragment-less pages; multiple writes; and explicit loading-time root
scrolling. Android compares real Sandbox selectors, state/relative history length,
exact event reports/styles and measured rectangles/root positions (1/32 CSS px).
A subset remounts after initial routing. This does not certify arbitrary loading
or traversal event timing.

**Remaining fragment differences:** relative-only root scrolls after selection without a later absolute
reset, scroll/History writes interleaved before the first native frame, broader
fresh-response restoration ordering, reentrant focus redirection/navigation,
filled/oversized control caret and selection variants, focus restoration across
remount/background transitions, broader keyboard traversal, focus pseudo styling,
additional toggle box-model combinations and exact toggle appearance/accent
styling are not newly certified. A redirected focus is recorded as a difference.
Hidden-until-found/beforematch revealing, streamed HTML/parser exposure, image intrinsic-size/load
restoration, arbitrary late-DOM retry and targets without a measured box,
inline/text/non-HTML fragments, RTL/vertical writing, sticky/SVG geometry, scroll snap,
root horizontal scrolling and unresolved inset math remain open. Unsupported
geometry retains the native anchor fallback and an explicit difference; matching
frame waits stay bounded. Backend redirect/hash inheritance, physical devices
and remote push remain outside this gate. This does not establish pixel-perfect
rendering or complete fragment behavior.

**Remaining synchronous layout differences:** general DOM writes followed by
geometry reads still need matching native measurement. Exact animation timing,
scrollend/Promise behavior and mixed root/element event ordering are not certified by this gate. Global getter
exception propagation during stale layout is not certified on Android; Node's VM
can return undefined instead of propagating the accessor error. These unsupported
reads are separate from the certified clean-layout scroll-position updates.

Retained-document scrolling is owned by the document/VM lifecycle, including
root offsets across a new PageStorage bucket. Switching the document in one view
creates a separate native scroll position. The Chromium 153 retention corpus
covers eight phone/tablet, DPR and theme profiles: same-document history restores
the root per entry in auto mode, keeps current nested offsets, and leaves the root
unchanged in manual mode. A reconstructed response starts nested offsets at zero.
Native workspace tests cover traversal, remounts and named-window refetch. A
workspace captures the current entry's latest root offset before unmounting,
including after scroll positions detach, so it cannot replay an obsolete fragment
or history snapshot. New fragment navigation while unmounted still takes effect.
The Android gate checks fresh JS reads and native controls after remount/switch,
plus the full workspace's retained-entry and offscreen-fragment paths.
Smooth-scroll interruption during remount and OS process-death restoration remain
outside this gate; physical-device/background acceptance remains open.

The latest dedicated local Android renderer gate covers 168 nested-anchor, 144
root-anchor and 120 fixed-position profiles against frozen Chromium 153 results.
Maximum box differences are 0.00625, 0 and 0.009375 CSS px respectively. Related
Flutter regressions and JavaScript fixture tests passed before the 0.7.0 merge;
this is bounded renderer evidence, not physical-device or full backend acceptance.
Reproduce through the committed integration tests and parity capture tools.

## Validation boundaries and separate backend findings

Local emulator/synthetic-model tests are evidence for covered code paths, not
physical-device, real-account/provider or remote-push acceptance. Android
integration uses the shipped JavaScriptSandbox runtime and native renderer;
production-path widget tests and dedicated Chromium references provide layout
coverage, not a complete browser engine. Capture only synthetic local HTML in a
dedicated test browser, never the user's everyday browser. Keep reference results
independent of native output; do not weaken assertions to erase findings.

The release-time SQLite WAL lock, Linux seccomp descriptor and PTC
heap-exhaustion failures were addressed by
[PR #4](https://github.com/iceice666/pirc/pull/4), not left as Android tasks.
OOPIF cases passed with dedicated Chrome for Testing 153.0.8010.47. The macOS
keyboard corpus still differs at step 14 by the active-focus marker; expectations
remain unchanged. This local platform finding is separate from Linux CI and the
Android client. Backend runtime checks do not establish arbitrary provider/runtime
workloads in the app.

At 0.6.1 release, the full Rust workspace gate was not green on the local host;
later fixes must not be represented as a rerun of that release gate. Linux
black-box conformance remains a CI check; full Nix package builds were not run
locally (dependency hashes/evaluation passed). Consult PR #4 and current CI for
backend/integration evidence rather than old test counts. Raw logs, synthetic
state, screenshots, generated captures and APKs stay in ignored local output.
