-- The gateway's SQLite schema (docs/development/historical-records.md): the TS
-- migrations of apps/gateway/src/database.ts consolidated into one fresh
-- schema. Tables the TS gateway created but never wrote (runs, interactions,
-- uploads, workspace_trust: those live on the nodes) are left out.

CREATE TABLE workspaces (
  id TEXT PRIMARY KEY, host_id TEXT NOT NULL, display_name TEXT NOT NULL,
  canonical_path TEXT NOT NULL UNIQUE, defaults_json TEXT NOT NULL, created_at INTEGER NOT NULL,
  kind TEXT NOT NULL DEFAULT 'directory',
  -- The repository's normalized origin (pirc_protocol::normalize_origin), as the node reports it.
  repo TEXT
);

-- A recovery root is node-private until the Gateway maps the continuation
-- response to its owner. A NULL owner is deliberately unavailable to users.
CREATE TABLE checkpoint_workspace_owners (
  workspace_id TEXT PRIMARY KEY REFERENCES workspaces(id) ON DELETE CASCADE,
  owner_user TEXT
);

CREATE TABLE sessions (
  id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL REFERENCES workspaces(id), pi_session_id TEXT,
  private_session_path TEXT NOT NULL UNIQUE, name TEXT NOT NULL,
  name_source TEXT NOT NULL DEFAULT 'user', runner_state TEXT NOT NULL DEFAULT 'stopped',
  runner_epoch INTEGER NOT NULL DEFAULT 0, partial_output_lost INTEGER NOT NULL DEFAULT 0,
  node_id TEXT, owner_user TEXT, pinned_at INTEGER, settled_at INTEGER,
  -- Unread: the agent finished something (activity_at) after the user last read it (read_at).
  activity_at INTEGER, read_at INTEGER,
  created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
);
CREATE INDEX sessions_node_id ON sessions(node_id);
CREATE UNIQUE INDEX sessions_remote_identity ON sessions(node_id, pi_session_id) WHERE node_id IS NOT NULL;

CREATE TABLE commands (
  id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(id), payload_hash TEXT NOT NULL,
  payload_json TEXT NOT NULL, status TEXT NOT NULL, result_json TEXT, error_text TEXT,
  created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
);
CREATE INDEX commands_session_status ON commands(session_id, status);

-- The node's control lease, mirrored with the user who holds it.
CREATE TABLE leases (
  session_id TEXT PRIMARY KEY REFERENCES sessions(id), client_id TEXT NOT NULL,
  generation INTEGER NOT NULL, expires_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
  owner_user TEXT
);

CREATE TABLE session_deletions (
  session_id TEXT PRIMARY KEY, owner_user TEXT NOT NULL, status TEXT NOT NULL, created_at INTEGER NOT NULL,
  -- Its workspace, so deleting a project also finds the chats deleted from it before
  -- (NULL for deletions before schema 1004).
  workspace_id TEXT
);

-- A chat project being deleted ('deleting') or deleted ('deleted'). The row outlives the
-- project, with no content, so node announcements, late events and restored node backups
-- cannot bring the project back (docs/guides/chat-projects.md).
CREATE TABLE workspace_deletions (
  workspace_id TEXT PRIMARY KEY, owner_user TEXT NOT NULL, status TEXT NOT NULL, created_at INTEGER NOT NULL
);

CREATE TABLE device_tokens (
  id TEXT PRIMARY KEY, owner_user TEXT NOT NULL, name TEXT NOT NULL,
  token_hash TEXT NOT NULL UNIQUE, created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL,
  last_used_at INTEGER NOT NULL
);
CREATE INDEX device_tokens_owner ON device_tokens(owner_user);

-- The assistant's memory (daemon/memory.ts).
CREATE TABLE memory_entries (
  id TEXT PRIMARY KEY, owner_user TEXT NOT NULL, kind TEXT NOT NULL, content TEXT NOT NULL,
  status TEXT NOT NULL, revision INTEGER NOT NULL, origins_json TEXT NOT NULL,
  sources_json TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
  -- Creation provenance is immutable even when later revisions come from other chats.
  created_by_session TEXT
);
CREATE INDEX memory_entries_owner ON memory_entries(owner_user, kind, status);
CREATE INDEX memory_entries_creator ON memory_entries(owner_user, created_by_session);
CREATE TABLE memory_log (
  seq INTEGER PRIMARY KEY AUTOINCREMENT, owner_user TEXT NOT NULL, entry_id TEXT NOT NULL,
  revision INTEGER NOT NULL, op TEXT NOT NULL, content TEXT, origins_json TEXT NOT NULL,
  sources_json TEXT NOT NULL, actor TEXT NOT NULL, at INTEGER NOT NULL
);
CREATE INDEX memory_log_entry ON memory_log(entry_id, revision);
CREATE TABLE memory_proposals (
  id TEXT PRIMARY KEY, owner_user TEXT NOT NULL, action TEXT NOT NULL, target_id TEXT,
  target_revision INTEGER, content TEXT, content_hash TEXT, quote TEXT NOT NULL,
  sources_json TEXT NOT NULL, session_id TEXT NOT NULL, status TEXT NOT NULL,
  created_at INTEGER NOT NULL, decided_at INTEGER
);
CREATE INDEX memory_proposals_owner ON memory_proposals(owner_user, status);
CREATE TABLE memory_tombstones (
  -- 'global' (Forget, chat deletion) refuses the text from then on; a project's
  -- workspace id (project deletion) only records it: other chats may write it again.
  owner_user TEXT NOT NULL, scope_id TEXT NOT NULL DEFAULT 'global', content_hash TEXT NOT NULL,
  forgotten_at INTEGER NOT NULL,
  PRIMARY KEY (owner_user, scope_id, content_hash)
);

-- Tasks the assistant hands to other workspaces (daemon/delegations.ts).
CREATE TABLE delegations (
  id TEXT PRIMARY KEY, owner_user TEXT NOT NULL, assistant_session_id TEXT NOT NULL,
  workspace_id TEXT NOT NULL, title TEXT NOT NULL, task TEXT NOT NULL, follows TEXT,
  status TEXT NOT NULL, target_session_id TEXT, result TEXT, notified_status TEXT,
  expires_at INTEGER NOT NULL, dispatched_at INTEGER,
  created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
  -- The model (and thinking level) it runs on, and the role its new session starts in.
  model_json TEXT, thinking TEXT, role TEXT,
  -- 1: the user approved it as their own request for auto mode, for the run it starts.
  as_user_request INTEGER NOT NULL DEFAULT 0,
  -- How it started: 'approved' (the user's card), 'auto' (the chat's delegation
  -- approval policy), NULL before it started. The origins of the chat's context
  -- the agent reported (JSON array), and the user's own words it verified
  -- (quote, JSON array of their message entry ids).
  dispatch TEXT, origins_json TEXT, quote TEXT, quote_entry_ids TEXT
);
CREATE INDEX delegations_owner ON delegations(owner_user, status);
CREATE INDEX delegations_follows ON delegations(follows);
CREATE INDEX delegations_assistant ON delegations(assistant_session_id, status);
CREATE INDEX delegations_target ON delegations(target_session_id, status);

-- Workspace memory mirrored from the nodes (daemon/memory-records.ts).
CREATE TABLE memory_mirrors (
  node_id TEXT NOT NULL, ledger_key TEXT NOT NULL, watermark INTEGER NOT NULL,
  updated_at INTEGER NOT NULL, digest TEXT, PRIMARY KEY (node_id, ledger_key)
);
CREATE TABLE memory_records (
  node_id TEXT NOT NULL, ledger_key TEXT NOT NULL, id TEXT NOT NULL,
  content TEXT NOT NULL, relevance TEXT NOT NULL, recorded_at TEXT NOT NULL,
  git_json TEXT, source_ids_json TEXT NOT NULL, origins_json TEXT,
  node_session_id TEXT, session_id TEXT, workspace_id TEXT, owner_user TEXT,
  status TEXT NOT NULL,
  -- Its workspace's repo when recorded, so clones find each other's notes.
  repo TEXT,
  PRIMARY KEY (node_id, ledger_key, id)
);
CREATE INDEX memory_records_owner ON memory_records(owner_user, status);
CREATE INDEX memory_records_id ON memory_records(id);

-- Scheduled agent runs (daemon/schedules.ts, docs/guides/schedules.md).
CREATE TABLE schedules (
  id TEXT PRIMARY KEY, owner_user TEXT NOT NULL, workspace_id TEXT NOT NULL,
  title TEXT NOT NULL, prompt TEXT NOT NULL, cron TEXT, run_at INTEGER,
  timezone TEXT NOT NULL, model_json TEXT, thinking TEXT,
  status TEXT NOT NULL, next_run_at INTEGER, created_by_session TEXT,
  created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
  -- Which runs push a notification.
  notify TEXT NOT NULL DEFAULT 'all'
);
CREATE INDEX schedules_owner ON schedules(owner_user);
CREATE INDEX schedules_due ON schedules(status, next_run_at);
CREATE TABLE schedule_runs (
  id TEXT PRIMARY KEY, schedule_id TEXT NOT NULL, owner_user TEXT NOT NULL,
  due_at INTEGER NOT NULL, status TEXT NOT NULL, session_id TEXT, result TEXT,
  started_at INTEGER, finished_at INTEGER, created_at INTEGER NOT NULL,
  -- What started the run (calendar/schema.sql); NULL when unknown.
  origin TEXT
);
CREATE INDEX schedule_runs_schedule ON schedule_runs(schedule_id, created_at);
CREATE INDEX schedule_runs_session ON schedule_runs(session_id, status);
CREATE TABLE schedule_proposals (
  id TEXT PRIMARY KEY, owner_user TEXT NOT NULL, session_id TEXT NOT NULL,
  schedule_id TEXT, spec_json TEXT NOT NULL, status TEXT NOT NULL,
  expires_at INTEGER NOT NULL, created_at INTEGER NOT NULL,
  -- What approving does: 'save' creates or changes (schedule_id), 'delete' deletes schedule_id.
  operation TEXT NOT NULL DEFAULT 'save'
);
CREATE INDEX schedule_proposals_session ON schedule_proposals(session_id, status);

-- Push notifications (daemon/push.ts).
CREATE TABLE push_subscriptions (
  id TEXT PRIMARY KEY, owner_user TEXT NOT NULL, endpoint TEXT NOT NULL UNIQUE,
  p256dh TEXT NOT NULL, auth TEXT NOT NULL, kind TEXT NOT NULL, name TEXT,
  device_id TEXT, created_at INTEGER NOT NULL, last_success_at INTEGER,
  failures INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX push_subscriptions_owner ON push_subscriptions(owner_user);

-- A chat workspace's capability policy (gateway-owned; node sync never touches it).
CREATE TABLE workspace_capabilities (
  workspace_id TEXT PRIMARY KEY REFERENCES workspaces(id), policy_json TEXT NOT NULL
);

-- The directory workspaces a chat project is about (docs/architecture/assistant-memory.md): a
-- default and an ordering, never a permission. No foreign key on workspace_id: a
-- link to a workspace that went away stays, shown as such. repo is the workspace's
-- normalized origin, so a link also covers the other clones of its repository.
CREATE TABLE project_links (
  project_workspace_id TEXT NOT NULL REFERENCES workspaces(id), workspace_id TEXT NOT NULL,
  repo TEXT, created_at INTEGER NOT NULL,
  PRIMARY KEY (project_workspace_id, workspace_id)
);

-- BEGIN workspace removals (1009)
-- Unregister only: node files, sessions and memory remain intact. Registration
-- never clears this fence; only an explicit Add workspace restores it.
CREATE TABLE workspace_removals (
  workspace_id TEXT PRIMARY KEY REFERENCES workspaces(id) ON DELETE CASCADE,
  owner_user TEXT NOT NULL, removed_at INTEGER NOT NULL,
  status TEXT NOT NULL DEFAULT 'removed' CHECK(status IN ('checking','removed')),
  token TEXT NOT NULL DEFAULT ''
);
-- END workspace removals (1009)

-- The one chat node this gateway is bound to.
CREATE TABLE assistant_node (singleton INTEGER PRIMARY KEY CHECK(singleton = 1), node_id TEXT NOT NULL);
