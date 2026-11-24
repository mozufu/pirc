-- Personal calendar data is user-owned and independent of agent execution.
CREATE TABLE calendar_events (
  id TEXT PRIMARY KEY, owner_user TEXT NOT NULL, creation_key TEXT NOT NULL,
  creation_hash TEXT NOT NULL, spec_json TEXT NOT NULL, revision INTEGER NOT NULL,
  end_before TEXT, deleted INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
  UNIQUE(owner_user, creation_key)
);
CREATE INDEX calendar_events_owner ON calendar_events(owner_user, deleted);
CREATE TABLE calendar_exceptions (
  event_id TEXT NOT NULL REFERENCES calendar_events(id) ON DELETE CASCADE,
  original_start TEXT NOT NULL, spec_json TEXT, cancelled INTEGER NOT NULL,
  PRIMARY KEY(event_id, original_start)
);
CREATE TABLE calendar_permissions (
  owner_user TEXT PRIMARY KEY, allow_read INTEGER NOT NULL DEFAULT 0,
  allow_propose INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE calendar_proposals (
  id TEXT PRIMARY KEY, owner_user TEXT NOT NULL, session_id TEXT NOT NULL,
  event_id TEXT, expected_revision INTEGER, operation TEXT NOT NULL,
  spec_json TEXT, scope TEXT NOT NULL DEFAULT 'series', occurrence TEXT,
  request_hash TEXT NOT NULL,
  status TEXT NOT NULL, expires_at INTEGER NOT NULL, created_at INTEGER NOT NULL,
  decision TEXT, applied_event_id TEXT, result_json TEXT
);
CREATE INDEX calendar_proposals_session ON calendar_proposals(session_id, status);
CREATE UNIQUE INDEX calendar_proposals_pending_request
  ON calendar_proposals(owner_user, session_id, request_hash) WHERE status='pending';
CREATE TABLE calendar_reminder_deliveries (
  event_id TEXT NOT NULL REFERENCES calendar_events(id) ON DELETE CASCADE,
  occurrence_key TEXT NOT NULL, reminder_minutes INTEGER NOT NULL,
  status TEXT NOT NULL, created_at INTEGER NOT NULL,
  PRIMARY KEY(event_id, occurrence_key, reminder_minutes)
);
