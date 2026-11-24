-- Contains immutable identities only. A committed deletion survives loss of the
-- allocation response, its caller, a Node connection, or the public session row.
CREATE TABLE conversation_submission_remote_cleanup (
 owner_user TEXT NOT NULL, operation_id TEXT NOT NULL,
 session_id TEXT NOT NULL UNIQUE, node_id TEXT NOT NULL,
 node_operation_id TEXT NOT NULL, local_workspace_id TEXT NOT NULL,
 submission_hash TEXT NOT NULL, expected_node_session_id TEXT,
 created_at INTEGER NOT NULL, last_attempt_at INTEGER NOT NULL DEFAULT 0,
 last_error_code TEXT,
 PRIMARY KEY(owner_user,operation_id)
);
CREATE TRIGGER submission_remote_cancelled AFTER UPDATE OF state ON conversation_submissions
 WHEN NEW.state='cancelled' AND OLD.state!='cancelled' BEGIN
 INSERT OR IGNORE INTO conversation_submission_remote_cleanup(owner_user,operation_id,session_id,node_id,node_operation_id,local_workspace_id,submission_hash,expected_node_session_id,created_at)
 SELECT NEW.owner_user,NEW.operation_id,NEW.session_id,NEW.node_id,NEW.node_operation_id,NEW.local_workspace_id,NEW.submission_hash,a.node_session_id,NEW.updated_at
 FROM conversation_submission_acceptances a WHERE a.owner_user=NEW.owner_user AND a.operation_id=NEW.operation_id;
END;
