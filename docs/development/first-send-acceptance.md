# First-send live client acceptance

The first-send flow remains disabled by default (`PIRC_FIRST_SEND` unset, so
`canSubmit: false` and the Gateway refuses new admission). These
acceptance fixtures run the production Web `FirstSend`, HTTP transport and
IndexedDB, or the actual native Kotlin engine in separate JVM processes, against
isolated real Gateway, Node and Agent executables. The model
provider and sandbox launcher are the existing conformance fakes: this does not
prove model-provider behavior, production sandbox isolation, authentication
infrastructure, the full Web UI, or Android OS/device behavior.

## Web client

Install the repository's JavaScript dependencies and its dedicated test browser
(`node apps/android/tool/parity/install_test_browser.mjs`). Do not pass an everyday
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
Its trusted-proxy adapter adds the fixture identity only. The fixture Gateway is
started with `PIRC_FIRST_SEND=1`, because the Gateway enforces the rollout itself;
the adapter asserts that it reports `canSubmit: true`. Production configuration is
never changed.
All prepare, upload, accept, materialize, control, dispatch and receipt operations
are real HTTP calls to the built Gateway.

Three cases must converge on the original conversation, attachment and command:

- Dispatch succeeds, then the connection drops before response headers. Chromium
  may transparently replay the POST; all requests must resolve to the same command.
- Dispatch succeeds at the server, then its HTTP response body is truncated.
- Dispatch succeeds and returns, then the real IndexedDB receipt transaction
  aborts; further writes fail until the browser is restarted.

Web and native clients now persist uncertainty before remote effects; if both
receipt and error writes fail, the last committed record is still honest. The
native process fixture below tests its live backend path separately; this browser
fixture does not exercise a native device. Before restart, interrupted cases retain
frozen, uncertain original input. A transport-replayed response may already be admitted. The browser
is closed, both Gateway and Node are crashed/restarted, and two new pages query
their persisted drafts. They must agree with the server. Even a later explicit
continue of an admitted operation must make GET requests only: no additional
dispatch, one user history entry and one model request per operation, unchanged
session/command IDs and exact attachment bytes. The fixture checks both the native Node upload
files and browser Blobs, before and after restart.

## Paired native client in separate JVM processes

Use an ordinary macOS/Linux user (not root), Java 17+, the existing Android SDK
platform 36 and the repository's resolved Gradle dependencies. The compiler helper
reads pinned Kotlin/runtime jars from the existing Gradle cache, does not download
tools and does not build Flutter or an APK. Reuse the run-owned Rust target built
above, or create one and build Gateway/Node with the same profile variables.
A dedicated browser is not required for this native test.

```sh
python3 scripts/prepare-native-first-send.py --out "$first_send_run/native"
PIRC_NATIVE_FIRST_SEND_RUNTIME="$first_send_run/native/runtime.json" \
  PIRC_CONFORMANCE_BIN_DIR="$CARGO_TARGET_DIR/debug" \
  cargo test --locked -p pirc-conformance --test conversation_native_client \
  native_reopens_lost_receipts -- --ignored --nocapture
```

Use `--java /absolute/path/to/java` and `--sdk /absolute/path/to/android-sdk` when
needed. The output directory must be new. The helper compiles the actual native
engine, file journal, HTTP client and unchanged extracted bridge conversion
helpers with warnings treated as errors. This fixture is ignored by the default
suite and must be run explicitly; it fails on missing prerequisites.

The harness creates two paired device tokens through the real Gateway API. Both
native clients send their own bearer tokens without a browser identity or Origin.
The test-only interceptor supplies the fixture Host routing and asserts the
fixture Gateway (started with `PIRC_FIRST_SEND=1`) reports `canSubmit: true`.
Gateway/Node APIs, pairing authorization and revocation remain real. Synthetic
credentials live only in the fixture's private config file and are removed on exit.

Before dispatch, the second client opens each pending conversation through the
native adoption API. It has its own private journal and no copy of the first
client's attachment files. Two operations then inject faults after real dispatch:

- Discard the successful HTTP reply before returning it to the native engine.
- Make the actual operation directory read-only before the receipt write; both
  the atomic receipt write and subsequent error write fail. The previous journal
  remains readable and frozen/uncertain, with the original file bytes intact.

The first JVM exits completely. Gateway and Node are crashed/restarted, then a
fresh JVM opens both clients' journals. The first client's Continue and the second
client's Check only query results. Both recover the same session and admitted
command; exactly one user entry and model request exist per original, and native
upload/private attachment bytes are unchanged. Already admitted operations are
intentionally absent from the pending-session adoption API.

Finally, the harness revokes the first device. Its admitted-result lookup and new
submission both receive 401; the new input remains editable and unchanged, and no
remote preparation exists for it. The second device can still check both admitted
results. Every recovery/revocation-phase native request is GET-only.

This is native Kotlin/JVM process and real backend evidence, **not Android OS,
Keystore, MethodChannel, emulator or physical-device acceptance**. The model and
sandbox launcher remain conformance fakes. The mapped cross-client mutation cases
below have separate evidence; this test alone does not cover those cases or
interrupted allocation/mixed versions.

## Web dispatch held across native takeover, Stop and deletion

After preparing both the dedicated browser and native runtime above, run:

```sh
PIRC_NATIVE_FIRST_SEND_RUNTIME="$first_send_run/native/runtime.json" \
  PIRC_CONFORMANCE_BIN_DIR="$CARGO_TARGET_DIR/debug" \
  cargo test --locked -p pirc-conformance --test conversation_native_client \
  native_takeover_stop -- --ignored --nocapture
```

The Web helper runs the production engine/IndexedDB and pauses a real outbound
first-message dispatch after Web has acquired control. A separate JVM process
uses a real paired token to discover/adopt the pending conversation. Native Send
must receive 409 without dispatching or silently taking control. Only the explicit
native Take control action obtains a newer lease. Then it performs one of:

- Stop, followed by a duplicate Stop that must only query. The delayed Web dispatch
  resolves to stopped; neither client may admit the original input.
- Delete: first require the accepted-message confirmation, then explicitly confirm
  deletion. The delayed Web dispatch cannot execute; both clients clear the
  deleted input/files on reconciliation, and its session is no longer visible.
- Send the same immutable first input after takeover. The delayed Web dispatch
  resolves to the original admitted command, with one user entry/model request.

Stop keeps the original files; confirmed deletion removes that conversation's
Node uploads. Gateway staging cleanup is a separate durable job, scanned every
60 seconds and immediately at startup: `cleanupPending` is allowed before restart,
not proof that execution can resume. After both backend hosts restart, the fixture
waits for actual cleanup completion and verifies the staging directory is gone.
The browser profile and JVM are reopened. Both clients use GET-only checks and
retain identical session/state/command identities; the stopped and admitted
inputs keep exact Web Blob and Node upload bytes. No native copy of another
client's private attachment is fabricated.

This uses the production client engines and real HTTP/lease/admission/deletion
paths with fixture-only scheduling. It is **not the full application UI or Android
OS/device**. The three mapped-workspace cases do not cover the reverse direction
(native in-flight send versus Web takeover), an offline/unallocated Node or mixed
protocol versions. The older backend-only tests cover parts of those contracts;
they are not substituted for client acceptance.

## Native allocation held while Web stops/deletes an offline Node

With both client prerequisites prepared, run:

```sh
PIRC_NATIVE_FIRST_SEND_RUNTIME="$first_send_run/native/runtime.json" \
  PIRC_CONFORMANCE_BIN_DIR="$CARGO_TARGET_DIR/debug" \
  cargo test --locked -p pirc-conformance --test conversation_native_client \
  web_offline_stop -- --ignored --nocapture
```

For each of Stop and confirmed deletion, a real paired native client saves the
original input/file, prepares and accepts it, then pauses its actual materialize
request before Gateway receives it. The fixture kills Node and verifies its
registration disconnected. Web discovers/adopts that accepted, still-unmapped
conversation through the normal client API. Stop must honestly report unconfirmed
`stopping`; deletion must report `cancelled` with cleanup pending.

The held native request is released while Node remains offline. It cannot dispatch
or promote files. The native process exits, the browser closes, and Gateway is
crashed/restarted; its receipt must retain the same pending decision and session.
After the same Node resumes, the fixture waits for actual Stop confirmation or
cleanup completion. Fresh browser/JVM clients query their journals and even a
repeated original Send must emit GETs only (or be refused locally).

For Stop, original native private bytes and Gateway staging survive. A separate
explicit Web release action may materialize the same **blank** conversation;
no original attachments are promoted and no old user message/model request runs.
For deletion, the conversation remains unavailable and Gateway staging is gone.
Native receipt persistence clears the original private blobs, and reopening a
previously cancelled journal repairs interrupted blob cleanup. Other private
copies and stopped/uncertain input are retained. The test checks actual files,
not only the cleared attachment list.

Both cases require zero model requests and zero Node uploads throughout. They
cover the reverse client direction and offline pre-allocation lifecycle, not a
lost Node allocation reply after storage was already created, the full Web/Flutter
UI, mixed protocol versions or actual Android OS/device process death.

## Node storage succeeded but its reply was lost

With both client prerequisites prepared, run:

```sh
PIRC_NATIVE_FIRST_SEND_RUNTIME="$first_send_run/native/runtime.json" \
  PIRC_CONFORMANCE_BIN_DIR="$CARGO_TARGET_DIR/debug" \
  cargo test --locked -p pirc-conformance --test conversation_native_client \
  lost_node_storage_reply -- --ignored --nocapture
```

A transparent loopback WebSocket relay forwards the real Node authentication,
registration and protocol frames. It discards exactly one successful response,
after the Node has committed either its session allocation or its original
attachment upload. The fixture checks the real storage and bytes before crashing
Gateway; it then restarts Node from the same files. The old native process must
retain frozen, uncertain original input after the interrupted materialize request.
No synthetic allocation/admission receipt or production fault switch is used.

A new native JVM and a separate Web profile inspect that same accepted operation.
Their recovery calls are GET-only at both the client and Node links, and cause no
inference. Gateway honestly retains `nodeMapped: false` if allocation's reply was
lost, or true if only the later attachment reply was lost. It does not infer that
an absent mapping means no Node storage exists.

Only a separate explicit Send resumes materialization and dispatch. The repeated
allocation carries the same creation operation ID and leaves exactly the original
Node session directory; a repeated upload keeps its existing file identity and
bytes. There is one user entry, one command and one model request. After another
Gateway/Node restart and fresh native/browser clients, GET-only reconciliation
retains the same session/command and files without another admission.

This two-case proof covers a real backend storage/reply boundary, not Android OS
process death, all permission transitions, old Node protocol versions or the full
application UI. The native JVM/compiler and dedicated browser restrictions above
still apply. The default `canSubmit` remains false.

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
The five live-client fixtures above must still pass against the rebuilt current
Gateway/Node. Keep this evidence separate from historical-binary rolling upgrades,
the full permission matrix and actual Android OS/device acceptance.

## Cleanup and remaining gates

The browser helper closes its own profile/server, and the conformance fixture
stops its processes and removes its private state. After the test process exits,
remove only the run-owned target/log directory you created. Keep this proof
separate from the remaining permission/device-race, Stop/delete, actual-device,
migration/rollback and activation gates recorded in
[the architecture plan](../../plans/unified-conversations.md).
