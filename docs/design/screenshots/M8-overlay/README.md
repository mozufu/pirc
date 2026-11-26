# Quick-reply overlay (M8 step 4) next to C 13–15 and 28

These images come from the Android emulator (AVD `pirc`, Android 16, 1080×2400 at
420 dpi, app language zh-TW). The debug build's `DebugOverlayReceiver` showed each
state with fake data. It runs push receipt on a made-up push and then
`OverlayLauncher.onReceipt`, as push delivery does; only the Gateway is fake. Each image
is cropped to the sheet and scaled to 540 px wide.
The app was in the background over the home screen, so the window was added without a
foreground activity. Switching the system to dark mode while the overlay was open
redrew it in the dark colours.

| Image | State | Design |
| --- | --- | --- |
| `01-light-question-checking.png` | Checking, every button disabled | C 14 (question variant) |
| `02-light-question-ready.png` | Ready, control on this device | C 13 |
| `03-light-question-other.png` | Ready, another device controls | — |
| `04-light-question-confirm.png` | Send read the question again: that device acted in the last 30 s, press again | — |
| `05-light-question-sending.png` | Sending | — |
| `06-light-question-sent.png` | Sent (closes by itself after 1.5 s) | — |
| `07-light-question-answered.png` | Answered elsewhere, "OK" | C 15 |
| `08-light-question-expired.png` | Expired | — |
| `09-light-question-offline.png` | Offline, "Retry" | — |
| `10-light-question-no-control.png` | Taking control failed | — |
| `11-light-question-not-sure.png` | Not sure it arrived | — |
| `12-light-run-checking.png` | Missed run, checking | C 14 |
| `13-light-run-ready.png` | Missed run, ready | C 14 (after the check) |
| `14-light-run-sending.png` | "Run now" pressed: buttons off while the run is read again and the decision goes out | C 14 |
| `15-light-run-sent.png` | Run started | — |
| `16-light-run-settled.png` | "Run now" found the run no longer missed: nothing sent | — |
| `17-light-run-not-sure.png` | Not sure the decision arrived | — |
| `d01`–`d07` | Dark: checking, ready, answered, run checking, run ready, no control, not sure | C 28 (ready) |

## Differences from C 13–15 and 28

All images:

- The backdrop is the emulator's home screen, not the grey "other app" of the
  prototype. The text uses the emulator's fonts (Roboto and Noto Sans CJK), not
  PingFang.
- The sheet has a 1 px `line.default` hairline, not the `float` shadow of the tokens.
  The window is exactly the sheet, so that touches beside it reach the app below, and
  a window cannot draw a shadow outside itself.
- The footer says the item stays in 「需要你」, the app's zh name of the "Needs you"
  filter, not 「待處理」 as in the prototype.
- No choice is selected when the overlay opens. A choice is selected only by a tap, so
  a stray tap cannot answer. The images select the first choice to match C 13 and 28.

C 13 and C 28 (ready):

- The line above the question shows only the expiry ("14 分後過期"). The workspace
  ("CI-runner / pirc") is not shown, because the compact read does not have it.
- The left button is "稍後" (Later), which closes the overlay. The prototype says
  "稍後提醒" (remind later), but no reminder is specified.
- When another device holds control, the footer says
  "控制：Office iMac · 送出會取得控制權" (image 03). C has no such image.

C 14 (missed run):

- While the overlay checks (image 12), it shows no schedule title and no planned time.
  It shows only what the compact read returned, and the push's title is English text
  from the server. After the read (image 13), the title, the planned time and the
  reason are shown.
- The detail line is "原定 <time> · <reason>". The time zone name, the workspace and
  the model are not shown, because the run's compact read does not have them. The time
  follows the device's 12 or 24 hour setting ("上午2:19").
- The footer has no "控制：此裝置" for runs. A schedule has no control lease.
- The button text is "略過這次" and "現在執行", as in C 14. The run is read again before
  either is sent (image 14).

C 15 (answered elsewhere):

- The text is "已由 iPad 在 上午8:51 回答。不需要再操作。". It does not say which answer
  was given ("全部重跑"), because `answeredBy` has only the device and the time. The
  text wraps as one paragraph; the prototype splits "已由" into its own column.
- There is no line with the workspace ("CI-runner / pirc") above the question, because
  the compact read does not have it.
- The device name is in the regular weight; the prototype sets "iPad" in bold.
- No footer: the item no longer waits in "Needs you". The same is true of Sent,
  Expired and "no longer missed".

States that C does not draw (confirm, sending, sent, expired, offline, no control, not
sure, no longer missed) use the same parts. Offline, no control and "not sure" show
"pirc" in the header without the session name, because these states do not keep it.

## Interpretations

These are not stated in the roadmap or in C § 6.4; the overlay does them as follows.

- The overlay opens only after push receipt's own compact read showed the item open: a
  question with 1 to 3 choices, or a run that is still missed. A run that failed or
  finished (it has the same push target), a question with more choices, and a push
  whose state could not be read get the notification alone.
- A push sent during quiet hours (`silent`) gets no overlay: a window that pops up would
  be louder than the silent notification the user chose.
- The notification is always posted as well. The overlay comes in addition, so closing
  it leaves the item in "Needs you" with its notification.
- While a send is out, a push for another item does not replace the overlay; that item
  has its notification.
- The window never takes focus, so the back key goes to the app below. The × and
  "稍後" close the overlay.
- Touches that reach the sheet while another window covers it are dropped
  (`filterTouchesWhenObscured`), so another app cannot trick a tap onto Send, Run now or
  a choice. While a screen dimmer or another overlay that lets touches through is
  active, the overlay therefore does not react to taps. The notification still works.
