# Native management authorization

Paired apps use a device credential. Provider and device management additionally
require a short-lived grant approved by the same owner in the authenticated web
UI. Ordinary pairing never grants these management capabilities.

The Rust gateway implementation is `crates/pirc-gateway/src/management.rs` and
its authorization checks remain subject to the trusted proxy and allowed-Origin
rules. Android holds the temporary grant in memory and sends it only to matching
same-origin management routes. Pending requests expire after five minutes;
grants expire after fifteen minutes. Revoking or expiring the primary device
credential also prevents grant use.

## API contract

- `POST /api/native-management/requests`: authenticated paired device; SHA-256
  verifier challenge, explicit capability list (`providers`, `devices:read`,
  `devices:revoke`, `devices:pair`) and optional
  `replace`. Replacement revokes only that device's prior request/grant and still
  requires fresh browser approval. Creation is rate limited and storage bounded.
- `GET /api/native-management/requests/:id`: original device or same browser
  owner; only named device, capabilities, status and epoch-millisecond times.
  With `devices:pair` it also returns `pairing` (`idleDays`, `maxDays`): the
  approval screen states that the grant can add a long-lived device and shows
  that lifetime. Each capability has its own confirmation text.
- `POST .../:id/approve` and `POST .../:id/deny`: same-owner browser only, with
  the existing allowed-Origin and trusted-proxy checks.
- `POST .../:id/claim`: original device plus verifier, once; native transport
  consumes the secret without returning it to Flutter. Raw grants are not stored
  server-side; their hashes are indexed until revocation/expiry.
- `DELETE .../:id`: same-owner browser or original device cancels/revokes.
- `X-Pirc-Management` is sent beside a live paired bearer only to the granted
  management route family. Gateway checks the exact supported route and method.
  Provider access includes provider CRUD/default/discovery/test and subscription
  authorization; `devices:read` lists devices (`GET /api/devices`),
  `devices:pair` creates a pairing (`POST /api/devices`) and `devices:revoke`
  revokes one (`DELETE /api/devices/:id`); none implies another. Neither substitutes for
  normal device authentication or proxy identity.
- Android uses monotonic remaining lifetime, clears access immediately on local
  revoke/pairing changes, and attempts old-account remote cleanup independently.
  Offline cleanup cannot promise server confirmation; the UI says so and server
  expiry remains authoritative. Process/gateway restarts and removed terminal
  request records support explicit reapproval; no grant is silently recreated.
- System browser consent is an authentication boundary. All App settings/content
  remain Flutter; no browser cookies, proxy secrets or credential extraction.

The browser and Gateway must be updated alongside the App for this feature.
Actual cloud-provider subscription login requires the relevant external account
and is not established by the isolated consent/CRUD acceptance.
