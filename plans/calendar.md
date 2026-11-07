# Calendar for schedules and personal events

[Plans](README.md) · [Schedules](../docs/guides/schedules.md) · [Mobile follow-up](mobile.md)

**Unified-architecture integration (2026-11-07):** [C5](unified-completion-contracts.md#c5-canonical-tasks-and-foreground-routing)
and [C10](unified-completion-contracts.md#c10-delivery-gates-and-integration-boundaries)
map schedule template/occurrence/task/attempt and target revalidation. Existing
calendar proposal confirmation and cron/timezone/DST policies remain binding;
pots standing grants cannot bypass them. This is target integration, not a new
scheduler implementation or runtime authorization.

Status: implemented locally; device acceptance pending, 2026-10-21. The user approved
the month/week/day prototype for Web and Flutter Android in the existing pirc style.
The user explicitly chose to include ordinary personal events as well as agent
schedules, and to include agent management with user confirmation and separate
calendar access permissions. Implementation and local commits are authorized;
remote publication is not.

## Implementation record (2026-10-21)

- [x] Approved month/week/day Web and native App design.
- [x] Gateway calendar migration 1007 (renumbered after memory integration; current schema 1008), owner-scoped CRUD, bounded/paginated projection,
      daily/weekly/monthly/yearly recurrence, exceptions and atomic series splits.
- [x] Revision conflicts, idempotent creation, actual/forecast run identity,
      independent default-deny calendar grants and human-confirmed agent proposals.
- [x] Gateway reminder attempts, occurrence deduplication and rescheduling,
      shared confirmation expiry/handled events. Reuse `schedules_changed` for
      calendar invalidation; no new hint subscription is needed.
- [x] Web month/week/day/list, event editor and schedule management, account
      preferences, permissions, reminders, move/resize drafts and English/Traditional
      Chinese. Typecheck, 92 focused/regression tests, production build and pinned
      Chromium span/point geometry checks pass.
- [x] Native Flutter month/week/day/list and event/Agent-task management,
      recurrence scopes/end rules, permissions, notification deep links,
      long-press move and end-time resize drafts. Matching fixture screenshots,
      keyboard/landscape/large-text checks, account re-pair isolation,
      idempotent retries and stale-edit review are covered by local tests.
- [x] Flutter static analysis and 69 focused regression tests; Android Kotlin
      compilation and unit tests. Preserve projection revisions until explicit
      conflict review on both clients. Disposable build/test output is cleaned
      after verification, with release APKs and review screenshots preserved.
- [ ] Physical Android background/reminder acceptance when a device is available.
- [ ] True remote notification delivery; the previously declined third-party
      relay remains untested. Local reminder claims and payload/deep-link tests
      do not replace this acceptance step.

Frozen recurrence policy: skip missing month days/leap dates; DST gaps move
forward and overlaps use the first instant. All-day dates remain calendar dates
in the selected display zone. Changing a whole series' start/zone/recurrence
resets its old exceptions; time-changing edits rearm affected reminders. After
downtime, remind only for events not yet ended; skip older reminders without
sending a backlog. A persisted delivery attempt is not remote delivery proof.

Gateway tests cover authenticated Web and paired-device HTTP, migration from
1000/1005, ownership, stale/duplicate approvals, revoked grants/expiry, recurrence
splits, DST, dense pagination, reminder rescheduling and the shared Web/App
fixture `fixtures/mobile-parity/calendar.json`. See
[Calendar](../docs/guides/calendar.md) for API contracts and limits.

## Goal and scope

One calendar shows personal events and agent schedules in month, week and day
views. Keep the existing schedule list available as a fourth view so its full
management and history remain accessible. The calendar belongs to the signed-in
user and is shared by that user's paired devices.

- **Personal event:** title, start/end, time zone, optional all-day or multi-day
  span, description, location, repetition and reminders. It never starts an agent.
- **Agent schedule:** the existing workspace, prompt, cron/one-off time, model,
  thinking and notification policy. Each occurrence starts a new agent session
  under the current approval and scheduling rules.
- Both types have explicit icons and names in the creation form, calendar items
  and details. A personal event cannot become an agent task through a gesture or
  an implicit default.
- Initial delivery covers manual and agent-assisted personal-event management.
  Agent calendar access has separate read/proposal permissions; the current
  `schedules` capability must not silently grant access to personal events.
- External calendar sync, meeting invitations, shared/team calendars and OS
  calendar integration are outside this proposal. They can be added later.

## Current implementation to reuse

- Rust Gateway: `crates/pirc-gateway/src/schedules/{mod,api,cron,timer}.rs`;
  SQLite `schedules`, `schedule_runs` and `schedule_proposals`.
- Web: `SchedulesPage.svelte`, `ScheduleSettings.svelte`, `lib/schedules.ts`.
- Flutter: `schedules_page.dart`, `schedules_state.dart`, the native date/time
  picker and the existing schedule request bridge.
- Both clients refresh on `schedules_changed`. Existing schedule mutations,
  agent proposals, missed-run approvals, new-session dispatch and notification
  preferences continue to use those contracts.
- Existing run history is bounded. The new UI must state its available history
  range rather than imply that every past execution is retained forever.

## Visual and interaction design

Use the current Web CSS tokens (`apps/web/src/app.css`) and their Flutter mapping
(`apps/android/assets/design-tokens.json`, `lib/theme.dart`). Reuse the current
Lucide icons, typography, muted surfaces, subtle borders, corner radii, button
styles, focus rings and light/dark themes. New dialogs, sheets, notices and date
controls must use these components/tokens, including Flutter surfaces.

Retain the current sidebar/mobile tab placement. Proposed page name: **Calendar**
with **New event** as the primary action; its creation form explicitly selects
Personal event or Agent task. Existing schedule links land in the same page with
the appropriate task selected.

Desktop/tablet layout:

```text
Calendar       <  Today  >   October 2026       Month | Week | Day | List    + New
Type / workspace / status filters               Display time zone
Calendar grid or time axis                      Selected event details
```

- Keep the existing 56 px page header and control typography as the starting
  reference. Let the calendar use the available content width; the old 780 px
  limit remains suitable for forms/list content, not the seven-day time grid.
- Details open in a side panel when space permits. On phones they open in a
  sheet/full-height detail surface using the same tokens and actions.
- General events use a calendar icon; agent tasks use the existing task/agent
  icon. Use restrained accent treatments. Running, failed, missed, waiting,
  paused and completed states also have text/icons, not color alone.
- Loading, empty, offline, permission and retry states belong in the page's
  visual system. Preserve an unfinished editor when a request fails.

### Month

- Seven weekday columns, previous/next month, Today, selected date and today
  markers. Respect the selected first day of week.
- Desktop cells show time/title previews and multi-day event spans. `+N more`
  opens that date's agenda; it must not silently discard events.
- Phone cells keep the seven-column month grid with compact event markers and
  counts. Selecting a date shows its agenda below the grid. Month view does not
  silently become a list on a small screen.

### Week

- Seven-day header, all-day/multi-day strip, vertical time axis and current-time
  marker. Timed personal events occupy their actual duration; overlapping items
  are arranged in adjacent lanes with an explicit dense-item expansion.
- Agent schedules are point-in-time triggers: show a distinct compact marker at
  the due time, not an invented 30/60-minute appointment. Recorded start/end
  times may describe an actual run in its details/history.
- On phones keep the week view, with a pinned time gutter and synchronized
  horizontal scrolling for readable day columns. All seven days remain reachable.

### Day

- The same all-day strip, time scale, overlap rules and event cards as Week,
  with a single full-width day and a compact date navigator.
- Tap/click an empty time slot to create a personal event with that date/time
  prefilled. Selecting Agent task remains an explicit choice.

### Editing and navigation

- Personal events support create/edit/delete, drag to move and resize to change
  duration, including touch controls and keyboard-accessible alternatives.
  Multi-day and all-day changes preserve local date semantics.
- Repeating personal events offer **this occurrence**, **this and following**,
  or **the whole series** where applicable; cancellation creates an exception.
- One-off agent tasks can open a time-change confirmation after a move. Repeating
  agent tasks open their recurrence editor; never silently rewrite a cron rule
  or imply that a single trigger was moved when only a series edit is supported.
- Task details retain Run now, pause/resume, edit/delete, missed-run allow/dismiss,
  result preview and Open session. Personal-event details offer their own actions.
- Browser history/deep links retain view, anchor date and selected item. Store
  view/time-zone/week-start preferences per account locally on each client;
  those display preferences do not change a schedule's execution time zone.
- All controls and dates support English and Traditional Chinese. Start with
  locale-based week start, with an explicit Sunday/Monday preference.

## Agent access and confirmation

The user chose to include this in the first implementation, not as a later add-on.

- Add an agent calendar tool for date-range queries and event details, and for
  proposing create/update/delete operations. A confirmed ordinary event never
  starts an agent session.
- Separate permission to read from permission to propose changes. Gateway-owned
  mode/capability settings control both, with a user-visible setting; a repository
  cannot grant them. Existing coding modes do not inherit private calendar access
  from the schedule capability. Freeze the configuration/defaults during phase 2.
- Every proposed create/update/delete waits for user confirmation, including
  requests made by an unattended agent task. General command approval modes do
  not bypass this confirmation. Read access still requires its own grant.
- Show the event title, dates/times, time zones, all-day state, recurrence scope,
  reminders and before/after differences in the chat approval. A series deletion
  or “this and following” edit must name that scope explicitly.
- Bind proposals to owner, originating session, event identity, expected revision
  and an expiry. Revalidate before an atomic apply; stale proposals ask the user
  to review the current event instead of overwriting it.
- Reuse the shared approval presentation on Web and Flutter. Applying on one
  device updates the others to the handled state and removes active buttons;
  duplicate confirmation returns the existing result and creates no extra event.
  Notification withdrawal follows the existing platform delivery capabilities.
- The agent receives the actual applied/rejected/stale result and event ID. It
  must not report an event as saved while the proposal is still pending.

## Data and API design

### Personal events

Add user-owned calendar event, recurrence-exception and reminder records to
SQLite, with migration and backup/restore coverage. Keep them separate from
agent prompts and execution records.

- Event identity, owner, title, description, location, time zone and revision.
- Timed events: start/end instants plus the intended local-time recurrence rule.
  All-day events: start date and exclusive end date in their calendar time zone;
  do not encode them as arbitrary UTC-midnight timestamps.
- Recurrence: daily/weekly/monthly/yearly, interval, selected weekdays where
  relevant, and optional end date/count. Freeze the supported rule representation
  and missing-month-day policy in phase 1; share the fixtures across both clients.
- Exceptions identify an occurrence by its original local start, so moving it
  does not create a duplicate. Splitting a series for “this and following” is an
  atomic operation.
- Reminder offsets are distinct from agent schedule outcome notifications.
  Personal events may have no reminder or one/more offsets before start.

### Calendar projection

Add a read-only, owner-scoped date-range API (proposed
`GET /api/calendar?from=...&to=...&timezone=...`) plus personal-event CRUD and
occurrence-edit endpoints. The range uses `[from,to)` UTC instants; timezone is
for date grouping and display, not a rewrite of stored rules.

- Rust expands personal recurrence and agent cron with their authoritative time
  zone rules. Clients render the result; they do not maintain different cron
  implementations.
- Return stable occurrence identity, source type, parent event/schedule ID,
  original occurrence time, effective start/end or all-day dates, optional run
  ID, state and revision. Forecasts and actual runs must not appear twice for one
  due occurrence; manual runs retain their own identities.
- Past schedule views use recorded runs. Do not reconstruct past appointments
  from today's edited cron rule, and do not label an unrecorded past time as a
  successful or missed run.
- Future agent forecasts are computed, not inserted into `schedule_runs` or
  dispatched. Opening or navigating the calendar must never trigger an agent.
- Keep existing schedule endpoints compatible. Add origin/occurrence metadata to
  new run records only if needed for reliable matching; legacy records must not
  be guessed to be manual or scheduled.
- Bound requested ranges, recurrence expansion and response size. Month queries
  may return per-date summaries/previews; dense cron patterns need an explicitly
  grouped presentation and paginated detail, never a silently truncated first-N
  list. All views must show when a preview/count is bounded.

### Time, concurrency and synchronization

- One selected display zone applies to the whole grid. Details also show an
  item's own zone when different. Changing display zone cannot reschedule it.
- Define/test DST gaps and overlaps, 23/25-hour day grids, leap days, month ends,
  midnight boundaries and cross-zone all-day events.
- Personal-event writes use expected revision and idempotent creation keys.
  If Web and App edit the same item, show the conflict/current version and retain
  the local draft; do not overwrite silently.
- Add a `calendar_changed` hint (or a documented extension of the existing hint)
  and invalidate only the affected date ranges. Reconcile through authoritative
  GETs after reconnect or ambiguous mutation failures.
- Initial offline support is cached reading and retained drafts. Writes and
  reminders remain Gateway-owned; phone-local offline alarms would be separate
  work with additional scheduling/deduplication requirements.

## Personal-event reminders

Reuse the existing encrypted Web Push / Android UnifiedPush delivery path, with
new event-reminder payloads and deep links. This needs reminder computation and
delivery records; storing a date in the UI alone does not implement reminders.

- Deduplicate by occurrence/reminder and device. Shared acknowledgment state
  prevents an already-handled reminder action from being replayed on another
  device; repeated actions return the current handled state.
- Proposed restart policy: deliver still-relevant reminders for events not yet
  ended once; summarize older missed reminders instead of sending a backlog.
- Reuse the user's notification permission/onboarding settings. Show delivery
  availability accurately. The previously declined third-party relay test stays
  unverified until the user authorizes it; local synthetic tests cannot close it.

## Implementation order and acceptance

1. **Reviewable design.** Freeze month/week/day/list screens for desktop, tablet
   and phone, in both themes, with existing design tokens. Include the creation
   type choice, overlapping events, all-day spans, selected details and errors.
   The user reviews the layouts before implementation proceeds.
2. **Rust data, permissions and calendar projection.** Event schema/migration,
   personal CRUD, recurrence/exceptions, range API, ownership, revisions, calendar
   read/proposal grants and shared synthetic fixtures. Verify that calendar reads
   never create runs or sessions.
3. **Web calendar.** Month/week/day, retained List, forms/details, time zones,
   recurrence editing, move/resize, accessibility and links to existing runs.
4. **Flutter calendar.** Native equivalents using the same fixtures, tokens and
   responsive rules; include touch scrolling, gesture cancellation, keyboard/IME,
   large text, rotation and retained drafts. No embedded WebView.
5. **Agent tools, confirmations, reminders and device reconciliation.** Agent
   query/proposal tools, chat approval UI, stale/repeated confirmation handling,
   Gateway reminder timer, deduplication, notification deep links and multi-device
   edit/action reconciliation. Preserve the explicit real-relay acceptance gap.
6. **Integrated acceptance.** Same date, viewport, font scale, theme and display
   zone on Web/App; compare all three views and list/detail actions. Include
   dense schedules, DST, recurrence exceptions, stale edits, offline/reconnect,
   and background notification behavior on a real Android device when available.

Each implementation phase should produce a reviewable local commit. Remote push,
version bump and Release publication require a later explicit user request.
Clean disposable test/build outputs after each round; retain deliverable APKs,
fixtures and any explicitly needed diagnostic artifacts.

## Proposed defaults to confirm with the design

- Personal events and agent tasks share the calendar; creation starts as a
  personal event, and Agent task is explicit.
- Device time zone and locale-based week start; both can be changed in the page.
- User-owned personal calendar with explicitly granted agent read/proposal access;
  external sharing/sync later.
- Server-owned reminders initially, with cached reading/drafts when disconnected.
