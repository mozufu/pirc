# Delegation without the approval card

[Plans](README.md) · [Chat projects guide](../docs/guides/chat-projects.md) · [Tools (auto mode)](../docs/guides/tools.md) · [Security decisions](../docs/architecture/security-decisions.md)

**Unified-architecture integration (2026-11-07):** [C5](unified-completion-contracts.md#c5-canonical-tasks-and-foreground-routing)
requires an explicit legacy-to-canonical control mapping. The relay-answer lease
exception below applies only to that addressed question, not general approval or
dispatch. Cross-device legacy Stop limitations stay visible until migrated;
planning does not silently change current permissions.

Goal: a chat's delegation runs without a separate approval card, auto mode in the delegated session knows what the user actually asked for, and the approvals that remain reach the user in the chat instead of only inside the delegated session.

This file is the work queue for the change, not authorization: each phase needs the user's go-ahead.

## Done (2026-10-19)

Phases 0–2 are implemented; current behavior is documented in [Chat projects → Delegation](../docs/guides/chat-projects.md#delegation) and [Security decisions → Delegation approval](../docs/architecture/security-decisions.md#delegation-approval), which also records the threat model and the residual risk the user accepted.

- **Phase 0:** `scripts/approval-stats.ts` counts approval requests in delegated vs. ordinary sessions from the nodes' `interactions` tables and the gateway's `delegations` (read-only). Auto mode's rules-vs-model source is not recorded in the dialog, so it is reported as unrecorded.
- **Phase 1:** `delegation_approval` (`always` / `untrusted` / `never`) on each chat workspace's capabilities; verified `quote` (user's last 3 messages) delivered as `details.userRequests` to the delegated run's classifier; no-card delegations use the role's model or the workspace default; running delegations shown in the chat with Open/Stop (`delegations` in the snapshot, `delegations_changed`, `POST /api/delegations/:id/stop`); cap of 4 running automatic delegations per user; audit columns `dispatch`, `origins_json`, `quote`, `quote_entry_ids` (gateway schema 1005).
- **Phase 2:** confirm dialogs of a delegated session are relayed to its chat (`relay.<delegation>.<dialog>` interactions), pushed as "<session> needs you", answerable from the chat, Needs you (Allow/Deny) and notifications without a lease via the node's gateway-only `relayed-answer` route.

Decisions recorded: default `always` for existing installs and new projects; all three policies offered; relayed answers use a gateway exception (no lease); phase 3 session allows would be exact text only and may include `unsandboxed_bash`.

Not covered by automated tests: Android/Web against a real gateway and node, notification direct actions for relayed approvals on a real phone, and Stop while another device holds the delegated session's lease (returns 409 by design).

## Phase 3 — Auto mode precision (not started)

- [ ] **Reassess first** with `scripts/approval-stats.ts` on real usage after phases 1–2; it widens auto mode and may prove unnecessary.
- [ ] **Allow for this session.** Approval dialogs gain "Allow this again in this session" for the exact action text in the same working directory (auto mode danger and `unsandboxed_bash`, decided 2026-10-19). Never for deny-list matches; recorded in the session like the approval mode, cleared on restart of the run's branch (decide). Prefix/pattern grants are out of scope.
- [ ] **Soft and hard danger.** Rules (`auto_mode/rules.rs`) report a danger category. Hard (credentials, uploading data, download-and-execute, system/global configuration, privilege, deleting outside the workspace) always asks. Soft (force push, `reset --hard`/`clean -f`, publishing/deploying) goes to the classifier when the run has a verified user request, so "force-push my feature branch" can pass when the user said exactly that. A rules test corpus pins each category; classifier prompt text is reviewed with the change.
- [ ] Also consider recording auto mode's decision source (rules vs. model) with each approval so phase 0's measurement can split them.
