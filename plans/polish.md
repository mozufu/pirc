# M13 Final review and polish

[Open work](README.md) · [Roadmap](roadmap.md) · [Pots](pots.md) · [Updates](updates.md)

Goal: the last milestone before the release. It adds pot roles and export,
and collects the small experience fixes the owner finds while trying the release
candidate. Steps 1 and 2 are planned now; step 3 is filled in as the owner tries the
build. Nothing here may weaken an M9 contract.

## Step 1 — Pot roles

Many pots make the Chat list long. A **role** is a label the user gives pots, used
to filter the list. It has only a name and a text color.

Rules:

- A role grants nothing and is invisible to pots: it is not in any prompt, tool
  result or permission summary (pots.md, Invariant 4). It is presentation only.
- A pot has zero or more roles. Roles belong to the owner; names are unique per
  owner (compared case-insensitively after trimming), 1–24 characters. The color is
  one of the role tokens (step 1c), not a free value.
- Deleting a role removes it from every pot; the confirmation names how many pots
  carry it.

**1a Backend.** Tables in the Gateway database (indicative names):
`pot_roles` (`id`, `owner_user`, `name`, `color` (1–8), `position`, `created_at`,
`updated_at`, unique (`owner_user`, normalized name)) and `pot_role_members`
(`pot_id`, `role_id`, primary key on both, both `ON DELETE CASCADE`). Routes:
`GET/POST /api/pot-roles`, `PATCH/DELETE /api/pot-roles/{id}`,
`PUT /api/pot-roles/order`; a pot's roles are a `roles` array of IDs in the pot
create and update bodies and in pot reads; the pots list returns them so the Chat
list needs no extra request. A `pots=1` hint is sent on change. Capability:
`features.pots.version` becomes 2.

**1b Where the user sets roles.**

- New pot (E7–E9): on the first page under the name, a **Roles** row with chips of
  the chosen roles and **Add**, which opens a picker with every role and
  **New role** (name, color, live preview of the label).
- Pot settings (E23/E24): a **Roles** section with the same picker.
- Settings → Pots: **Manage roles**: list in display order (drag to reorder),
  rename, recolor, delete.

**1c Chat list.** The chips 全部/未讀/pots/群組 stay as they are. A **filter button**
(icon) at the end of the chip row opens a sheet:

- A check list of every role, plus **No role**; **Show all** clears it.
- With a selection, the list shows pots that have **any** selected role; the chip
  filter still applies on top (for example 未讀 + "研究" = unread threads of pots with
  that role). Groups are not affected by the role filter (P27).
- While a role filter is on, the button shows the number of selected roles and a
  line under the chips says "Showing roles: 研究, 生活 · Clear".
- The selection is kept per device (preferences), not on the Gateway.
- Pot rows show up to two role labels in their colors after the name, then "+n".
- Role colors: eight tokens added to `pirc_ui` with light and dark values that meet
  4.5:1 contrast on the list background; the design handoff gets a short addendum
  (E-roles) with the sheet and the row.

**Done when:** Gateway tests for the routes and the invariant (no role text in any
pot prompt or tool result); widget tests for the filter combinations; goldens of the
new pot page, the picker, manage roles, the filter sheet and the filtered list at
four widths in both themes and both languages.

## Step 2 — Export

Decided (P32): this milestone builds **export only**. Pots export with their
settings and **without memory**. Import is not built; when it is, every imported
item is scanned by a review model as well as checked by the rules below (see
"Later: import").

Builds on the [M10 bundle format](updates.md#step-4--state-bundle-format)
(`kind: export`): one archive with `bundle.json`, a human-readable copy of each part
(Markdown, CSV or iCalendar) and a versioned machine-readable copy (JSON), so a later
import can read it.

**What Settings → Data → Export offers** (P33; each item is a check box, and some
take a selection):

| Item                   | Contents                                                                                                                                                                                                                              | Format           | Default |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------- | ------- |
| Pot settings           | Per pot or all: name, avatar, intro, personality, work description, responsibilities, roles, models and fallbacks, thinking, autonomy interval, trust preset; permissions as a readable reference (workspace and node names, not IDs) | JSON + Markdown  | on      |
| Conversations          | Direct threads, groups and pot DMs, with decision cards and their answers; per pot, group or all; a date range                                                                                                                        | Markdown + JSON  | on      |
| Memory                 | USER entries and pot notes, each with its origin and trust level (M9 step 4); separate from pot settings                                                                                                                              | Markdown + JSON  | off     |
| Usage                  | The usage ledger for a date range                                                                                                                                                                                                     | CSV              | off     |
| Activity               | The activity log for a date range                                                                                                                                                                                                     | CSV + JSON       | off     |
| Calendar and schedules | Reminders and scheduled runs                                                                                                                                                                                                          | iCalendar + JSON | off     |
| Settings               | Notification preferences, pot settings defaults, roles, model choices, update settings; no secrets                                                                                                                                    | JSON             | off     |

**Not in M13:** work-session transcripts (they must be fetched from each node); a
later step adds them as an item, off by default.

**Never exported as system data:** device tokens and pairings, provider keys and
subscription tokens, push keys, node tokens, browser profiles (they hold cookies),
and the M10 `snapshot` bundles. Export uses explicitly selected fields rather
than copying database tables, configuration or state directories. There is no
encrypted export exception; recovery uses the M10 snapshots. User-written text
may still contain private material pasted into a message or note; the confirmation
does not promise to detect or remove those secrets.

**How it runs:**

- Only the owner starts an export from an authenticated client; no pot tool can
  start or read one. A conversation or memory export needs a fresh management
  approval for the exact accounts, items, selections and date range, bound to
  the owner and requesting device or browser session. An ordinary paired token
  alone is not authority, and the approval must not be reusable for another job
  or a wider selection.
- The Gateway builds the bundle as an owner-scoped background job and shows
  progress. Only the authorized requester may download it (Android through the
  system file picker, Web as a download, macOS through a save panel). Recheck
  authority before download, including device revocation; no shareable bearer
  link. Keep the archive private until the client confirms a completed transfer
  or the 24-hour limit expires. An interrupted transfer does not count as success
  and may retry the same job if authorization is still current.
- A conversation or memory export is recorded in Activity and announced on the
  owner's other devices without its contents. The notice is an audit signal,
  not a substitute for approval or download authorization.
- **Share a pot** exports one pot's settings without permissions and models, for
  giving to someone else, with a reminder to check the personality text for personal
  details.

**Done when:** each item's machine copy matches the stored data and marked
system secrets never appear in an archive; a paired device without fresh
approval cannot export conversations or memory; changed scope, wrong owner or
device, expired approval and revoked device are rejected. Test interrupted
download, deletion after completion and expiry, and restart recovery or a
visible failure. Goldens cover the export screen at four widths.

**Later: import (not in M13).** Notes for whoever designs it:

- A pot's personality, intro and work description go into its prompt, so a shared pot
  file is a way to plant instructions. Every text field is scanned by a review model
  with no tools (the M9 step 3b reader pattern), and the user sees the full text
  with the scan's findings before anything is saved.
- Rule checks come first: the bundle's hashes and schema, size limits, unknown
  fields refused.
- An imported pot starts paused, with reach `answer`, no work locations or DM peers,
  the Strict preset and autonomy review off, until the user sets each one.
- Imported notes keep their origin, are marked imported, and stay out of prompts
  (P26).

## Step 3 — Owner trial and polish

The owner uses the release candidate on Android, Web and macOS. Each item they report
becomes a numbered sub-step here (3.1, 3.2, …) with its screen, the expected
behavior and its test or golden. Items that change a contract or a design decision
go to the owner first.

**Done when:** the owner marks the list complete.
