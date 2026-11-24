-- Unaccepted first-send preparation. Identity/tombstones outlive content and
-- workspace/session deletion; no row here by itself authorizes execution.
CREATE TABLE conversation_submissions (
 owner_user TEXT NOT NULL, operation_id TEXT NOT NULL,
 workspace_id TEXT NOT NULL, node_id TEXT NOT NULL, local_workspace_id TEXT NOT NULL,
 session_id TEXT NOT NULL UNIQUE, node_operation_id TEXT NOT NULL UNIQUE,
 command_id TEXT NOT NULL UNIQUE, submission_hash TEXT NOT NULL,
 payload_json TEXT CHECK(payload_json IS NULL OR json_valid(payload_json)),
 state TEXT NOT NULL CHECK(state IN ('preparing','cancelled')),
 created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
 -- Staged attachment deadline and expiry (attachments.sql).
 attachments_expires_at INTEGER, attachments_expired_at INTEGER,
 PRIMARY KEY(owner_user,operation_id),
 CHECK((state='preparing' AND payload_json IS NOT NULL) OR (state='cancelled' AND payload_json IS NULL))
);
CREATE INDEX conversation_submissions_workspace ON conversation_submissions(workspace_id);
CREATE TRIGGER submission_project_deletion AFTER INSERT ON workspace_deletions BEGIN
 UPDATE conversation_submissions SET state='cancelled',payload_json=NULL,updated_at=NEW.created_at
 WHERE workspace_id=NEW.workspace_id;
END;
CREATE TRIGGER submission_session_deletion AFTER INSERT ON session_deletions BEGIN
 UPDATE conversation_submissions SET state='cancelled',payload_json=NULL,updated_at=NEW.created_at
 WHERE session_id=NEW.session_id;
END;
CREATE TRIGGER submission_workspace_deleted AFTER DELETE ON workspaces BEGIN
 UPDATE conversation_submissions SET state='cancelled',payload_json=NULL
 WHERE workspace_id=OLD.id;
END;
