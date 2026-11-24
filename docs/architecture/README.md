# Architecture references

[All documentation](../README.md) · [Current topology](../deploy/topology.md)

| Reference                                                                       | Covers                                                                                                             |
| ------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| [Behavioral contracts](contracts.md)                                            | Capability, tasks, environment transitions, folder grants, isolation, checkpoints, deletion and content invariants |
| [Model backends and authentication](backend-auth.md)                            | Gateway-owned inference and provider credentials, subscription logins and trust boundaries                         |
| [Observational memory](observational-memory.md)                                 | Session/workspace memory, extraction, storage, recall and validation                                               |
| [Prompt and Context contracts](prompt-context.md)                               | Prompt sections, assistant configuration, node-local snapshots and authorized relays                               |
| [Session activity and list updates](../guides/session-ui.md#activity-transport) | Node activity, session origins and client updates                                                                  |

- [Assistant memory and delegation](assistant-memory.md): frozen context, memory ownership, repository identity and delegation contracts.
- [Reusable LLM foundations](reusable-llm.md): extracted types, transport/OAuth ownership and the generic-loop integration gate.
- [PTC runtime contracts](ptc.md): discovery, per-operation authority, attachments and execution lifecycle.
- [Security decisions and accepted limits](security-decisions.md): current trust boundaries and accepted risks.

See also [native management authorization](native-management.md) for temporary App management grants and browser consent.

Completed designs, Rust cutover provenance and PTC evaluation evidence are available through [Historical records in Git](../development/historical-records.md).
