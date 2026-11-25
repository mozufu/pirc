# Programmatic tool calling contracts

[Architecture](README.md) · [Tools and workflows](../guides/tools.md)

This describes the current Rust implementation, not an evaluation protocol. Core tools are available directly and through `ptc`; other registered capabilities are called from scripts. `ptc_docs` discovers their contracts. User-facing configuration and accepted limitations are described in the [tools guide](../guides/tools.md).

## Boundary and authorization

`crates/pirc-ptc/src/preflight.rs` strips TypeScript and derives a manifest from literal capability calls (`tools.read(...)`, `tools.call("read", ...)`). Computed names and aliases that obscure dispatch are refused. The manifest is a pre-check, not authorization: the agent checks each dispatched name against it and checks current capability availability.

The QuickJS interpreter runs in a killable `pirc-node ptc-guest` child, with an empty environment, inside the agent's OS sandbox. Scripts have no ambient filesystem, network, subprocess or module-loading API. Host interactions go through the agent's broker (`crates/pirc-agent/src/ptc/`). The native guest also applies platform-specific hardening; see `crates/pirc-ptc/src/harden.rs` and the [sandbox guide](../deploy/sandbox-and-browser.md).

Direct calls and script operations use the same validation, hooks, approval-mode checks, path rules, write leases and server-side authorization. Hook-rewritten arguments are checked as executed. Approval of a script or discovery of a capability never approves future operations. Cancellation, timeout and unavailable answers are not consent. After an operation is refused, only read-only operations may proceed in that execution; the host's refusal summary reaches the model even if script code catches the error.

## Results and concurrency

`tools.call` returns a typed success/error envelope. Convenience methods return its `data` or throw an error carrying the operation identity. Typed data is distinct from the human-facing tool result; scripts should use the contract returned by `ptc_docs`, not parse presentation text into invented fields.

`tools.par(items, fn, {concurrency})` preserves input order. On the first failure it stops dequeuing work, cancels eligible operations in that scope and its children, waits for its workers, and throws the first error. Completed effects remain completed. Nested scopes and `Promise.all` cannot bypass execution-wide limits. Non-read operations take one exclusive slot; the broker uses the final operation arguments when deciding whether exclusivity is needed.

There are no automatic retries, transactions or rollbacks. Validation or authorization can fail before an operation starts; cancellation after dispatch may leave its outcome unknown. Host-side completion accounting survives a failed or crashed script and distinguishes completed, failed, cancelled and unknown work.

## Limits and lifecycle

The shared numeric limits are in `crates/pirc-ptc/src/contracts.rs`; attachment limits are in `crates/pirc-agent/src/ptc/attachments.rs`.

| Resource                        | Limit                                                       |
| ------------------------------- | ----------------------------------------------------------- |
| Source                          | 65,536 UTF-8 bytes                                          |
| Operations                      | 200 per execution; 8 running at once, 1 exclusive operation |
| Parallel scopes                 | 200 per execution                                           |
| QuickJS managed heap / stack    | 128 MiB / 512 KiB                                           |
| Active time                     | 120 s by default (`limits.ptcTimeoutMs`), at most 1 h       |
| Operation arguments / result    | 1 MiB / 16 MiB                                              |
| Console output                  | 51,200 bytes                                                |
| Stored JSON value / total store | 262,144 / 1,048,576 characters                              |

These are separate budgets: the interpreter heap is not total process RSS, and operation results are not the outer model-output budget. Calls waiting for a slot count toward progress and quotas. Repeated attempts past quotas are bounded by an additional host-side attempt limit.

Active time pauses for human waits only while the guest is idle, not while it continues computing. Existing approval/question expiry still applies. Cancellation and timeouts stop the guest; pending operations receive cancellation and a five-second settling grace. An operation that ignores abort may outlive that grace, so stopping a script is not proof that all external effects stopped. Late callbacks do not resume the terminated script. Durable jobs and background agents have their own lifecycles.

## Discovery

`crates/pirc-agent/src/ptc/registry.rs` uses the same available-capability view for discovery and execution. An empty `ptc_docs` query returns the category index; category pages contain at most 20 summaries; exact queries accept at most 8 names. Responses are bounded by 16,384 UTF-8 bytes and paginate between complete items rather than cutting schemas.

Category cursors are authenticated with an agent-process-local key and bind the category, offset and registry version. Changed contracts return `StaleContract`; a cursor from another process is invalid. Discovery is read-only and grants no permissions.

## Attachments

Image bytes remain on the host. The script receives opaque, execution-bound descriptors, not base64 or a dereference API. `attachments.add(handle)` queues a host-held image for the outer result after checking its identity, expiry, model support and size. Constructing a descriptor does not mint a valid handle.

At most four images, totaling 512 KiB, may be queued. Handles expire at execution cleanup or after 15 minutes, whichever comes first. At most 16 unqueued images are retained, with a 64 MiB retained-byte cap. Queued images join the outer result only when the script completes. A model without image input receives an explicit refusal.

## Operation trace and exposure

Each inner operation emits normal `tool_execution_start/update/end` events under its capability name, with its own `toolCallId` and the outer script's `parentToolCallId`. Approval interactions can carry the operation ID so clients show the correct nested operation as waiting. Execution and parallel-scope traces retain parent links, sequence, status and timing; host records remain available even when the guest fails.

Operations are persisted as `ptc.operation` session entries, not conversation messages. The node's snapshot merges them into history beside the outer result, allowing clients to expand a script after reload without injecting every intermediate result into model context. Typed script data is not an additional event/session payload. Inner calls have the same owner-visible argument/result exposure and truncation rules as direct calls; this does not introduce gateway persistence, push payloads, telemetry or logging of their content.

Results that used network content or other agents' data are fenced as untrusted. Stored values retain that provenance when loaded by later scripts. Recalled source content is replayed evidence, not a new instruction. See the [tools guide](../guides/tools.md) for the current capability lists and the [observational-memory architecture](observational-memory.md) for source handling.
