# First-send live client acceptance

First-send is the only way to create a session. These acceptance fixtures run the production Web `FirstSend`, HTTP transport and
IndexedDB against isolated real Gateway, Node and Agent executables. The model
provider and sandbox launcher are the existing conformance fakes: this does not
prove model-provider behavior, production sandbox isolation, authentication
infrastructure, the full Web UI, or Android OS/device behavior.

## Web client

Install the repository's JavaScript dependencies and its dedicated test browser
(`node scripts/e2e/install_test_browser.mjs`). Do not pass an everyday
Chrome executable or profile. The helper validates the executable and creates its
own temporary profile. Build the two Rust executables into a run-owned target
directory, then run:

```sh
first_send_run="$(mktemp -d "${TMPDIR:-/tmp}/pirc-first-send.XXXXXX")"
export CARGO_TARGET_DIR="$first_send_run/target"
export CARGO_PROFILE_DEV_DEBUG=0 CARGO_PROFILE_TEST_DEBUG=0 CARGO_INCREMENTAL=0
cargo build --locked -p pirc-gateway -p pirc-node
PIRC_CONFORMANCE_BIN_DIR="$CARGO_TARGET_DIR/debug" \
  cargo test --locked -p pirc-conformance --test conversation_web_client \
  -- --ignored --nocapture
```

Set `PIRC_TEST_NODE` if `node` is not on PATH. `PIRC_TEST_BROWSER` may point to a
validated dedicated Headless Shell executable. This is an explicit acceptance
test, ignored by the default workspace/conformance suite; a normal green CI run
does not mean it ran. It fails if binaries, browser or dependencies are missing.
Use a fresh run-owned `CARGO_TARGET_DIR`; preserve shared caches, SDKs and APKs.

The fixture binds only loopback and uses its own synthetic owner and provider.
Its trusted-proxy adapter adds the fixture identity only; it asserts that the
Gateway reports `canSubmit: true`.
All prepare, upload, accept, materialize, control, dispatch and receipt operations
are real HTTP calls to the built Gateway.

Three cases must converge on the original conversation, attachment and command:

- Dispatch succeeds, then the connection drops before response headers. Chromium
  may transparently replay the POST; all requests must resolve to the same command.
- Dispatch succeeds at the server, then its HTTP response body is truncated.
- Dispatch succeeds and returns, then the real IndexedDB receipt transaction
  aborts; further writes fail until the browser is restarted.

Web and native clients persist uncertainty before remote effects; if both
receipt and error writes fail, the last committed record is still honest. This
browser fixture does not exercise a native device. Before restart, interrupted cases retain
frozen, uncertain original input. A transport-replayed response may already be admitted. The browser
is closed, both Gateway and Node are crashed/restarted, and two new pages query
their persisted drafts. They must agree with the server. Even a later explicit
continue of an admitted operation must make GET requests only: no additional
dispatch, one user history entry and one model request per operation, unchanged
session/command IDs and exact attachment bytes. The fixture checks both the Node
upload files and browser Blobs, before and after restart.

## Retired native JVM fixtures

The paired-native JVM acceptance and the Web/native takeover, lost-reply and
offline-Node cases were retired with the old Android client at the M8 cutover.
Their old helper, native conformance test and instructions remain in the
pre-cutover commit described in
[historical records](historical-records.md#old-android-client-m8-cutover). No live
native-client acceptance fixture replaces them yet; the Flutter app's Dart and
Kotlin suites and the owner's device acceptance are separate evidence.

## Capability changes, connection replacement and authority races

Gateway unit coverage exercises accepted and ready inputs against a missing
capability route, unknown capability version, missing Stop/receipt support and
reduced upload limits. It also revokes the paired device, removes the workspace
or loses control while a probe is pending. Allocation/admission cannot proceed,
and the original operation/input/files remain available to authorized recovery.
A replaced connection cannot receive requests based on its predecessor's proof;
a replacement detected before reservation creates no command or retry record.
Retry requires the full workflow as well as retry support. Blank release after
confirmed Stop does not apply old attachment limits or promote original bytes.

```sh
cargo test --locked -p pirc-gateway --bin pirc-gateway
PIRC_CONFORMANCE_BIN_DIR="$CARGO_TARGET_DIR/debug" \
  cargo test --locked -p pirc-conformance --test conversation_contract --test node_link
```

The unit responders simulate capability and connection changes. The normal Node
protocol test uses real Gateway sockets; it does not run an old Node executable.
The live Web client fixture above must still pass against the rebuilt current
Gateway/Node. Keep this evidence separate from historical-binary rolling upgrades,
the full permission matrix and actual Android OS/device acceptance.

## Cleanup and remaining gates

The browser helper closes its own profile/server, and the conformance fixture
stops its processes and removes its private state. After the test process exits,
remove only the run-owned target/log directory you created. Keep this proof
separate from the remaining permission/device-race, Stop/delete, actual-device,
migration/rollback and activation gates recorded in
[the architecture plan](historical-records.md#retired-plans-2026-11-24).
