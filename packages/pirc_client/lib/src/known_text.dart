/// Fixed English text the Gateway and the agent send, which clients show in
/// their own words. The values mirror `pirc_protocol`
/// (`crates/pirc-protocol/src/lib.rs`).
library;

/// The option the agent adds after the options of every select question;
/// picking it asks for typed text.
const askOtherLabel = 'Other (type your own answer)';

/// A new session's name until its title replaces it.
const placeholderSessionName = 'New session';

/// The titles of the agent's approval questions in auto and read-only mode.
const autoModeApprovalTitle =
    'Auto mode: allow a potentially dangerous action?';
const readOnlyApprovalTitle = 'Read-only mode: allow this action?';
