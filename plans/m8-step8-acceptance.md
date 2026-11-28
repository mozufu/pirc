# M8 step 8: device acceptance checklist (working note)

A working note for [roadmap](roadmap.md) M8 step 8, the owner's acceptance on a physical
Android phone with a real account. Delete it when step 8 closes, after the results are in
the status table's Notes. A skipped check is not a pass (N8): mark it `skipped` with the
reason.

**Owner update (2026-11-27):** sections A–D passed on a physical device. The
owner approved proceeding with cutover before finishing E (quick-reply overlay)
and F (release APK on a phone); both remain to be verified. G1 is optional and
was not confirmed. The detailed run below is the earlier agent run, not the
owner's results.

**Cutover:** the old app was removed in `34a49c41`. Use the current Android
build for the remaining E–F checks. CI verified the signed standard release APK
at the cutover revision; the smoke run did not publish or upload that APK and
does not replace F on a physical phone.

## Before you start

- **Gateway and Node from current `main`.** Steps 0–7 need the pirc 2
  Gateway (pairing v2 tables, `POST /api/device/rotate`, notification preferences,
  compact endpoints for the background client).
- **APKs**, built from the same revision in `apps/app/build/app/outputs/flutter-apk/`:
  - `app-standard-debug.apk`: debug build, for most checks.
  - `app-standard-release.apk`: use the configured signing key for the release
    checks (see [Release setup](../docs/development/releasing.md)). Local release
    builds without that key use the debug key and are not the CI-signed APK.
  - Both have the ID `org.mozufu.pirc` (no debug suffix). In-place installs also
    require matching signing certificates; moving from a debug-key APK to the
    CI-signed APK requires uninstalling and pairing again.
- **A UnifiedPush distributor on the phone** (for example ntfy). Every notification
  goes through push (`push/PircPushService.kt` → `notifications/`). There is no local
  path. Without a distributor, sections D and E cannot be run and are `skipped`. The
  owner chooses the distributor's server. A public relay is the owner's own decision
  (roadmap M8, "Not in M8").
- **Where the v1 pairing link comes from.** Pairing v2 is hidden behind
  `PIRC_PAIRING_V2` (off) until M9 serves its approval page, so it is **not** checked
  here. A v1 `pirc://pair?url=&token=` link and QR code come from either:
  - Settings → Devices → Phones in the browser (forward auth), or
  - Settings → Devices → "Pair a new device" in `apps/app` on a device that holds a
    `devices:read` management grant (`settings/devices_page.dart`).

## Short token windows (for section A)

Since `33d19dab`, the app rotates when less than 23/30 of the Gateway's maximum
window remains, i.e. 23 days for the default 30-day window
(`connection/rotation.dart` `rotateBeforeFor`). The Gateway reads whole days.

- **Rotation on the next connect:** in a test Gateway, pair a fresh device with a
  2-day maximum and idle window. Restart the same Gateway database with
  `PIRC_DEVICE_TOKEN_MAX_DAYS=30` while the token is still valid. Reconnect and see
  the new maximum expiry on the same device record. Foreground the app again and
  verify that the new token does not rotate a second time. A short maximum window
  alone no longer makes a fresh token rotate immediately.
- **Near-expiry warning:** keep `PIRC_DEVICE_TOKEN_IDLE_DAYS=2` in the preceding
  setup. On the next connect, force only `POST /api/device/rotate` to fail in the
  test setup. Check that the warning shows the earlier of the refreshed idle expiry
  and the saved maximum expiry, not a 30-day date.
- **"Pairing expired; your settings are kept":** revoke the phone on the Devices page
  and bring the app to the foreground (a `401` is treated the same as expiry).
- Put the defaults (7 and 30) back afterwards.

## Checks

Write `pass`, `fail (what happened)` or `skipped (why)` in the Result column. Note the
phone model and Android version once at the top of the results.

Phone: Xiaomi `2412DPC0AG` (`rodin`) Android version: 16 OEM skin: HyperOS 3.0

### A. Pairing and connection

| #   | Check                                                                                  | Result                                                                                                                   |
| --- | -------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| A1  | Pair with a v1 `pirc://pair` link opened from another app (the `links` channel)        | pass (agent, local Gateway; VIEW intent sent by adb)                                                                     |
| A2  | Pair by scanning the v1 QR code (ML Kit scanner, camera permission prompt)             | skipped (needs a camera scan)                                                                                            |
| A3  | Token rotation happens on its own with a short maximum window; the app stays connected | partial: the pre-fix build rotated and kept the old token for 5 minutes but looped (S6); retest with `33d19dab` or later |
| A4  | The near-expiry warning shows and uses the effective expiry                            | skipped (shown only after a failed rotation, `rotation.dart:210`; not forced)                                            |
| A5  | Revoked token → pairing screen with "Pairing expired; your settings are kept"          | pass; the 已配對 label seen on that screen is fixed in `3d78d17c`                                                        |
| A6  | Streaming a reply; cancel mid-stream; reconnect after airplane mode on and off         | partial: streamed, stopped and reconnected; the text before stop now stays (S4, checked on the emulator)                 |
| A7  | Panels: files, git, terminal (including the terminal's HTTPS asset origin), work panel | fail: 新終端 fails silently (S1); Back from a file leaves the session (S2). Files pass; Git, browser not checked         |
| A8  | Management consent (approve and decline a grant)                                       | not run                                                                                                                  |

### B. Input, layout and lifecycle

| #   | Check                                                                              | Result                                                                                |
| --- | ---------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| B1  | Hardware/software keyboard; CJK IME (Zhuyin or Pinyin) composition in the composer | partial: Zhuyin composition shows underlined in the composer; no full CJK typing test |
| B2  | Safe areas: notch, gesture bar, keyboard open                                      | pass (portrait: composer above keyboard, status and gesture bars clear)               |
| B3  | Rotation to landscape and back, mid-conversation                                   | skipped (needs the rotation-lock setting changed)                                     |
| B4  | Background then foreground after several minutes; the stream resumes               | pass (returns to the same panel)                                                      |
| B5  | Low memory: "Don't keep activities" or force kill, then reopen; state comes back   | skipped (`am kill` refused by HyperOS; Don't keep activities needs a setting change)  |

### C. Approvals, browser and media

| #   | Check                                                                                                   | Result                                                                         |
| --- | ------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| C1  | Full multi-line approval bodies and labels are readable and not cut                                     | pass (3-line question, labels and descriptions complete); English strings (S3) |
| C2  | PTC approval declines and how they are rendered                                                         | pass (decline → ApprovalDenied, file not created, step marked failed)          |
| C3  | Browser takeover: tap mapping, IME, drag scrolling                                                      | skipped (local Node runs with `PIRC_BROWSER=false`)                            |
| C4  | WebM playback (recording player and HTML media); save a recording                                       | not run                                                                        |
| C5  | Files: pick, save, share into the app, paste an image (limits 11 MiB per file, 16 files, 64 MiB in all) | not run                                                                        |
| C6  | An AVIF image in a message shows (or falls back on a phone without AVIF support)                        | not run                                                                        |

### D. Notifications (needs a distributor)

| #   | Check                                                                                                                                                         | Result                                                                                                                                                                 |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| D1  | Push settings list the installed distributors and preselect the only one                                                                                      | pass (ntfy listed and chosen; test push arrived through ntfy.sh)                                                                                                       |
| D2  | The Android 13+ notification permission prompt, and the result when it is denied                                                                              | skipped (permission was already granted before the run; the prompt was not seen)                                                                                       |
| D3  | An agent question arrives as a notification with option buttons; answering from it works                                                                      | partial: arrives (channel `needs_you`); with 2 options + Other the owner expanded it and saw the choices; 3 options gave none before the S8 fix; title in English (S3) |
| D4  | A missed schedule run arrives with buttons; failed and waiting runs count as `needs_you`                                                                      | not run                                                                                                                                                                |
| D5  | Model approval, budget request and handover open the app on their sheet, with no answer chosen                                                                | not run                                                                                                                                                                |
| D6  | Levels per category (`needs_you`, `done`, `progress`, `calendar`): `off` sends nothing, `digest` sends one summary at `digestAt` (set it a few minutes ahead) | partial: `off` sends nothing (checked); `digest` not run                                                                                                               |
| D7  | Quiet hours set to start now and end a few minutes later (try also crossing midnight): silent during, summary when they end                                   | partial: question arrived in a `silent:` group without an overlay; end-of-quiet-hours summary and midnight crossing not checked on the phone                           |
| D8  | Lock screen `hidden` (secret notification) and `title` (text hidden only while Android hides sensitive content)                                               | pass for `hidden` (`vis=SECRET` in dumpsys); the lock screen itself not looked at; `title` not run                                                                     |
| D9  | Calendar reminders arrive on time with the app in the background                                                                                              | not run                                                                                                                                                                |
| D10 | OEM battery and notification limits (autostart, battery optimisation) do not stop delivery                                                                    | partial: delivered on HyperOS with the app in the background (not killed)                                                                                              |
| D11 | Notification text follows the system language, not the app's language                                                                                         | partial: Kotlin buttons follow the system language (zh); the title comes from the Gateway in English (S3)                                                              |

### E. Quick-reply overlay (needs a distributor)

| #   | Check                                                                                                                                                              | Result                                                                                                                                                   |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| E1  | The "display over other apps" permission prompt and its setting                                                                                                    | pass (granted by the owner; the setting shows it)                                                                                                        |
| E2  | The overlay opens for a question with 1–3 choices; the notification is posted as well                                                                              | pass: 2 options (staging reached the agent) and, after the S8 fix, 3 options + Other (B reached the agent)                                               |
| E3  | The overlay never opens during quiet hours                                                                                                                         | pass (no overlay during quiet hours)                                                                                                                     |
| E4  | Sending from the overlay while another device holds control: it takes control, asks first if the holder acted in the last 30 s, and shows who holds it if it fails | partial: the send took control from another client and the answer arrived; the 30 s question was not triggered (the other holder had no recorded action) |

### F. Release build

| #   | Check                                                                                      | Result                                                               |
| --- | ------------------------------------------------------------------------------------------ | -------------------------------------------------------------------- |
| F1  | `app-standard-release.apk` installs, pairs and streams (R8/minify did not break a channel) | skipped (release build allows HTTPS only; the local Gateway is HTTP) |
| F2  | In the release build, push, the overlay, the scanner and media still work                  | skipped (as F1)                                                      |

### G. Optional: real remote push delivery

Only if the owner chooses to run it. An agent never runs this.

| #   | Check                                                                        | Result               |
| --- | ---------------------------------------------------------------------------- | -------------------- |
| G1  | A notification arrives through a public distributor with the phone off Wi-Fi | skipped (owner only) |

## Run of 2026-11-27 (agent, local test Gateway)

Push checks (D, E) used ntfy.sh as the UnifiedPush distributor, with the owner's
consent in chat. Driven by the agent over wireless adb with the debug APK, against a local Gateway, coding
Node and chat Node built from `f316edd6`, and a scripted fake model (no real account,
no real provider). The phone reached the Gateway at `localhost:8787` through
`adb reverse`. These results are the agent's, not the owner's acceptance; the owner
decides which count.

Findings:

- **S1 New terminal fails silently.** 新終端 shows nothing, in a reopened session and in
  a new one after a sent message. The Gateway answers the create with
  `workRequest.state: not_started`, `errorCode: isolated_terminal_unavailable`
  (checked with the same request by curl). `TerminalsPanel._create` leaves its poll on
  `not_started`, finds no `terminal` and returns without a message
  (`work/panels/terminal_panel.dart:52-62`). Whether this local setup (a macOS Node,
  a workspace that is not a Git repository) should give an isolated terminal is a
  second question; the missing error is the bug. **Fixed in `22b4f08a`:** the panel now
  shows why the terminal did not start; checked on the phone.
- **S2 Back leaves the session.** In the full-screen panel, open a file, press the
  system Back once: the app goes to the Work list, not to the file list. **Fixed in
  `da138a04`:** Back closes a file, then goes up a folder, then closes the panel, then
  leaves the session; checked on the phone.
- **S3 English text in the zh-TW UI.** From the server: "Other (type your own answer)"
  (`pirc-agent/src/features/ask_question.rs:20`), "New session" (placeholder name,
  `pirc-gateway/src/db.rs:71`) and "Auto mode: allow a potentially dangerous action?"
  (`pirc-agent/src/auto_mode/mod.rs:729`). From the app: `panelTasks` is "Tasks" in
  `app_zh.arb:282`. **App side, `0578cd95`:** "Tasks" stays, as design-spec-C § 41 names the
  panel; `fromPot` in zh now shows only the pot's name, like 你 for `fromYou`.
  **Server strings, fixed in `557ab608`, owner's decision: translate in the app.** The
  fixed English stays on the wire; `pirc_protocol` holds it, `pirc_client` and the
  Android app mirror it and show their own words: Other, "New session" (work list,
  conversation header, chat work cards, pot form, overlay header), the auto mode and
  read-only approval titles (question card and notification), and the question push
  title, built on the phone from a new `sessionName` push field. Checked on the
  emulator (zh): Other, 新對話 and the auto mode title. The push title is covered by
  Kotlin tests only (the phone's adb dropped). Then still English: the other push kinds
  (pot requests and replies, schedules, calendar, the test push, digest summaries), the
  fallback body "It needs your answer to go on.", the approval body (Command…,
  Reason…) and the agent's "Enter your answer" placeholder. **Fixed in the follow-up:**
  pushes whose title holds a name (a pot's, a schedule's, an event's) carry
  `text: {key, args}` beside the English title and body (`pirc-gateway/src/push/text.rs`),
  the digest title comes from its count, and fixed push titles and bodies are matched as
  sent; the app's approval card and the overlay show the frame (label, "in", "Reason:")
  in the app's words, and the typed answer's hint too. The command and the classifier's
  reason stay as sent: the model writes them. Checked on the emulator (zh): the
  approval frame and the hint. The push wording is covered by Robolectric tests in zh;
  not yet seen on the phone.
- **S4 Text before stop is dropped.** After 停止 the streamed part of the reply is gone;
  only "已停止。" stays.
  **Fixed in `21333e44`, owner's decision: keep it.** The remote stream returned
  an empty aborted message. It now keeps text and thinking streamed so far, not
  unfinished tool calls. Checked on the emulator with an equivalent local fix: the text up to
  the stop stays, with 已停止。 under it.
- **S5 Pair button label.** On the "pairing expired" screen the button read 已配對 until
  a link was opened. **Fixed in `3d78d17c`:** the pairing state now lives only while the
  pairing page shows it.
- **S6 Rotation loop with a short maximum.** With `PIRC_DEVICE_TOKEN_MAX_DAYS` at 23 or
  less, the app rotates about every 10 seconds while open: each rotation reconnects, the
  reconnect checks again and finds less than `rotateBefore` (23 days) left. Each
  reconnect resets the screen ("正在重新連線並取得最新狀態…", an open file closes). With
  the default 30 days it settles after one rotation.
  **Fixed in `33d19dab`:** `GET /api/device` and the rotation reply carry
  `maxAgeMs`, and the app rotates at 23/30 of that window (23 days for 30).
- **S7 No expandable question notification (caused by S8).** A question with 3 options
  plus Other reached the phone with no choices, so its notification had nothing to
  expand. With 2 options plus Other the owner could expand it and saw the 3 choices
  on HyperOS 3. Not a HyperOS limit.
- **S8 Three options never got choices or the overlay.** The agent adds "Other (type
  your own answer)" to every select question, so 3 options reached the Gateway as 4,
  over the limit of 3. **Fixed in `1b3e6a2e`, owner's decision: Other is not counted.**
  The Gateway leaves a last Other out of the count and marks it `other: true`
  (`pirc_protocol::ASK_OTHER_LABEL`, shared with the agent). The overlay shows all
  options and Other; the notification has 3 slots, filled with the real options first
  and Other only when a slot is left. Checked on the phone: a 3-option question opened
  the overlay with A, B, C and Other, and the answer reached the agent.
- **S9 Notification icon.** The small icon in the shade is the default Flutter logo. The cause was the launcher icon, the Flutter default; HyperOS shows it
  in the shade. **Fixed in `b12136cb`:** the app uses the pirc adaptive icon from
  `apps/android` (`ic_pirc`). Not yet seen on the phone.
- **S10 Session times moved.** During the rotation loop (S6) all three sessions in the
  Work list showed 17:46 though nothing happened in them. Cause not checked.
  Cause: Gateway startup recovery marks every session with a live runner stopped and
  sets its `updated_at` (`pirc-gateway/src/db.rs:819`), and runner state changes do the
  same (`db.rs:1420`); the Work list shows `updated_at` as the last activity, so a
  Gateway restart moves every such session to the restart time. **Fixed:** startup
  recovery, runner state changes and the new epoch on a Node reconnect no longer touch
  a session's `updated_at`; a finished run or a question (the moments that mark it
  unread) now sets it. The Gateway reads it only to order the session list, never for
  sync; the web Sidebar and the app's Work list show it. A message the user sends
  moves it only when that run finishes or asks. Not yet seen on the phone.

## Choices to confirm or change

These were made while building steps 0–7 (roadmap M8, "Choices made while building").
They are decisions, not device tests. Write `keep` or what to change.

| #   | Choice                                                                                                                         | Decision                                                            |
| --- | ------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------- |
| K1  | A `links` channel (`org.mozufu.pirc/links`) receives `pirc://pair` and opens the browser                                       |                                                                     |
| K2  | Failed and waiting schedule runs are `needs_you`                                                                               |                                                                     |
| K3  | Update pushes (answered, refresh): none at `digest` or `off`, silent during quiet hours                                        |                                                                     |
| K4  | `lockScreen: hidden` = secret notification; `title` depends on Android's lock-screen setting                                   |                                                                     |
| K5  | The overlay opens only for a question with 1–3 choices or a run still missed, never in quiet hours, always with a notification | keep, and Other is not counted toward the 3 (owner, 2026-11-27; S8) |
| K6  | The overlay's send takes control with `force`, asking first if the holder acted in the last 30 s                               |                                                                     |
| K7  | Files: 11 MiB per file, 16 files, 64 MiB at once                                                                               |                                                                     |
| K8  | Message documents keep storage and cookies in memory only, per document                                                        |                                                                     |
| K9  | Kotlin notification and overlay text follows the system language                                                               |                                                                     |

## After the run

- Copy a short summary into the status table's Notes for M8 (for example "step 8: 38
  pass, 2 fail (D7, C3), 3 skipped (G1, …)") and list each failure under M8 Progress.
- Failures become fixes before step 9. Step 9 deletes `apps/android` only after this
  acceptance.
