# Schedules and notifications

[User guides](README.md) · [All documentation](../README.md)

The Web/Android **Calendar** also shows personal events and month/week/day views;
its **List** retains schedule management. See [Calendar](calendar.md) for event
editing, recurrence and the separate Agent calendar permissions. The schedule
execution and approval rules below continue to apply.

The gateway keeps each user's schedules and starts every run in a new session of the schedule's workspace, delivered as a scheduled-task message (never as your words). Manage them in the web app (Settings → Schedules), on Android (More → Schedules), with `/cron`, or by asking an agent. In the web and Android schedule forms, you may choose a model and thinking level per schedule; otherwise the normal default applies. An agent can propose a schedule, a change or a deletion, which you approve in the chat (`/cron delete` asks too); it can pause and resume on its own, but cannot choose a model or thinking level.

- **Nothing runs unasked.** A fire time the gateway slept through, or whose node was offline, becomes one _missed_ run that starts only when you allow it; a fire time while the previous run is still going is _skipped_. A run that waits for an answer (a dangerous command, a question) stays waiting until you open its session.
- **Time zones**: the web and Android apps default to the device's zone; an agent defaults to the gateway's (`PIRC_TIMEZONE`, else the system's; `services.pirc.timeZone` in the Nix module).
- **Notifications**: Web Push on browsers (Settings → General → Notifications; needs https or localhost, and the installed app on iOS) and [UnifiedPush](https://unifiedpush.org) on Android (More → Notifications, with a distributor such as ntfy; no Google services). They cover scheduled runs (each schedule chooses every run, only problems, or none), any session waiting for your answer and memory changes to approve. Messages are encrypted for each device and carry only a title, a short line and what to open; no agent output. A notification about the session you are looking at is not shown.
  - The gateway signs pushes with a VAPID key pair made on first start (`$PIRC_STATE_DIR/vapid.json`), or `PIRC_VAPID_PUBLIC_KEY`/`PIRC_VAPID_PRIVATE_KEY`. Changing it invalidates every subscription. `PIRC_VAPID_SUBJECT` (a `mailto:` or `https:` URL, default the first allowed origin) is the contact push services see.
  - Push endpoints must use https; `PIRC_PUSH_ALLOW_HTTP=true` also accepts http ones (a distributor server on a LAN). A phone's subscription goes with its device token.

See the scheduled-task tool contract in [Tools and workflows](./tools.md), and deployment settings in [Gateway configuration](../deploy/gateway.md).
