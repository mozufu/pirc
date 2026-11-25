-- The node's store (crates/pirc-node/src/store/mod.rs): the tables of the
-- TS `database.ts` a node uses, consolidated. The gateway's tables
-- (devices, memory, schedules, delegations, push, capabilities) are not
-- here; nor are columns only the gateway writes, except those a session row
-- shows (pinned, settled, unread), which stay empty on a node.

CREATE TABLE workspaces (
  id TEXT PRIMARY KEY,
  host_id TEXT NOT NULL,
  display_name TEXT NOT NULL,
  canonical_path TEXT NOT NULL UNIQUE,
  defaults_json TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  -- 'directory' or 'chat'
  kind TEXT NOT NULL DEFAULT 'directory'
);

CREATE TABLE sessions (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL REFERENCES workspaces(id),
  -- The agent's own session id (`get_state`), for `--continue`.
  pi_session_id TEXT,
  private_session_path TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  -- 'user' or 'auto' (a placeholder or generated title)
  name_source TEXT NOT NULL DEFAULT 'user',
  -- 'stopped', 'starting', 'ready' or 'failed'
  runner_state TEXT NOT NULL DEFAULT 'stopped',
  runner_epoch INTEGER NOT NULL DEFAULT 0,
  partial_output_lost INTEGER NOT NULL DEFAULT 0,
  owner_user TEXT,
  node_id TEXT,
  pinned_at INTEGER,
  settled_at INTEGER,
  activity_at INTEGER,
  read_at INTEGER,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE TABLE runs (
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL REFERENCES sessions(id),
  -- queued, running, waiting_input, stopping (open); succeeded, failed,
  -- cancelled, interrupted
  status TEXT NOT NULL,
  started_at INTEGER,
  ended_at INTEGER,
  failure_reason TEXT,
  created_at INTEGER NOT NULL
);
CREATE INDEX runs_session_status ON runs(session_id, status);

CREATE TABLE commands (
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL REFERENCES sessions(id),
  payload_hash TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  -- received, dispatched, accepted, rejected, outcome_unknown
  status TEXT NOT NULL,
  result_json TEXT,
  error_text TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE INDEX commands_session_status ON commands(session_id, status);

CREATE TABLE interactions (
  id TEXT PRIMARY KEY,
  rpc_id TEXT NOT NULL,
  session_id TEXT NOT NULL REFERENCES sessions(id),
  runner_epoch INTEGER NOT NULL,
  kind TEXT NOT NULL,
  -- pending, answered, cancelled, expired, stale
  status TEXT NOT NULL,
  request_json TEXT NOT NULL,
  answer_json TEXT,
  expires_at INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  answered_at INTEGER,
  -- The client that answered (its clientId), and when the question ended for
  -- any reason, so every device can say what happened.
  answered_by TEXT,
  resolved_at INTEGER,
  UNIQUE(session_id, runner_epoch, rpc_id)
);
CREATE INDEX interactions_pending ON interactions(session_id, status, expires_at);

CREATE TABLE leases (
  session_id TEXT PRIMARY KEY REFERENCES sessions(id),
  client_id TEXT NOT NULL,
  generation INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  owner_user TEXT
);

CREATE TABLE uploads (
  id TEXT PRIMARY KEY,
  owner_user TEXT NOT NULL,
  mime_type TEXT NOT NULL,
  byte_size INTEGER NOT NULL,
  storage_name TEXT NOT NULL UNIQUE,
  sha256 TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  filename TEXT,
  -- 'image' or 'file'
  kind TEXT NOT NULL DEFAULT 'image',
  -- Where it was uploaded; it is usable in that workspace only and is
  -- deleted with it. NULL for uploads older than schema 2001.
  workspace_id TEXT,
  session_id TEXT
);
CREATE INDEX uploads_workspace ON uploads(workspace_id);

-- The project config (.pirc/config.json hooks, env, allowedPaths) the user
-- trusted for a directory workspace, by hash.
CREATE TABLE workspace_trust (
  workspace_id TEXT PRIMARY KEY REFERENCES workspaces(id) ON DELETE CASCADE,
  project_hash TEXT NOT NULL,
  trusted_by TEXT NOT NULL,
  trusted_at INTEGER NOT NULL
);

-- A chat project being deleted (fenced: hidden from the gateway, no new
-- sessions, until it is gone). Kept afterwards so a retry answers 204.
CREATE TABLE workspace_deletions (
  workspace_id TEXT PRIMARY KEY,
  owner_user TEXT NOT NULL,
  -- 'deleting' or 'deleted'
  status TEXT NOT NULL,
  created_at INTEGER NOT NULL
);

-- A chat being deleted (fenced: its routes answer 409 until it is gone).
CREATE TABLE session_deletions (
  session_id TEXT PRIMARY KEY,
  owner_user TEXT NOT NULL,
  -- 'deleting' or 'deleted'
  status TEXT NOT NULL,
  created_at INTEGER NOT NULL
);

-- Durable, owner-bound recovery adoption; no copied conversation/memory.
CREATE TABLE IF NOT EXISTS checkpoint_intents (
  job TEXT PRIMARY KEY, owner TEXT NOT NULL, source_session TEXT NOT NULL,
  capture TEXT NOT NULL, expected_revision INTEGER NOT NULL,
  accept_unresolved INTEGER NOT NULL, scope_json TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
-- Keep adoption tombstones if conversation/workspace metadata is deleted.
-- Repeated continuation must not recreate deleted conversations or remove files.
CREATE TABLE IF NOT EXISTS checkpoint_workspaces (
  workspace_id TEXT PRIMARY KEY,
  job TEXT NOT NULL UNIQUE REFERENCES checkpoint_intents(job),
  owner TEXT NOT NULL,
  session_id TEXT NOT NULL UNIQUE,
  created_at INTEGER NOT NULL
);

