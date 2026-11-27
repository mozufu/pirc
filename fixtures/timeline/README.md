# Timeline fixtures

Golden cases shared by every client that turns gateway snapshots and events into a chat timeline (the web's `api.ts`/`pi-messages.ts`/`state.ts`, and the Dart port in `packages/pirc_client`).

Each file holds a raw `GET /api/sessions/:id/snapshot` reply (`snapshot`), the raw `/api/events` messages that follow it (`events`), and `expected`: a projection of the client state after the snapshot and after every event has been applied. The projection leaves out timestamps and anything clients may format differently.

The web implementation is the reference. After an intended behavior change, regenerate `expected` and port the change to the other clients:

```sh
cd apps/web && UPDATE_TIMELINE_FIXTURES=1 npx vitest run src/lib/timeline-fixtures.test.ts
cd ../.. && npx prettier --write fixtures
```
