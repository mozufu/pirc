-- File bytes live in the gateway's private submission-staging directory.
-- The deadline is committed before filesystem work, including crash orphans.
CREATE TABLE conversation_submission_attachments (
 owner_user TEXT NOT NULL, operation_id TEXT NOT NULL, attachment_id TEXT NOT NULL,
 byte_size INTEGER NOT NULL CHECK(byte_size>0), sha256 TEXT NOT NULL,
 created_at INTEGER NOT NULL,
 PRIMARY KEY(owner_user,operation_id,attachment_id),
 FOREIGN KEY(owner_user,operation_id) REFERENCES conversation_submissions(owner_user,operation_id)
);
CREATE TABLE conversation_submission_cleanup (
 session_id TEXT PRIMARY KEY, owner_user TEXT NOT NULL, operation_id TEXT NOT NULL,
 attachment_ids_json TEXT NOT NULL CHECK(json_valid(attachment_ids_json)),
 created_at INTEGER NOT NULL, last_attempt_at INTEGER NOT NULL DEFAULT 0
);
CREATE TRIGGER submission_attachment_cancelled AFTER UPDATE OF state ON conversation_submissions
 WHEN NEW.state='cancelled' AND OLD.state!='cancelled' BEGIN
 INSERT INTO conversation_submission_cleanup(session_id,owner_user,operation_id,attachment_ids_json,created_at)
 VALUES(NEW.session_id,NEW.owner_user,NEW.operation_id,
   COALESCE((SELECT json_group_array(json_extract(value,'$.id')) FROM json_each(OLD.payload_json,'$.attachments')),'[]'),NEW.updated_at)
 ON CONFLICT(session_id) DO NOTHING;
 DELETE FROM conversation_submission_attachments WHERE owner_user=NEW.owner_user AND operation_id=NEW.operation_id;
END;
CREATE INDEX submission_attachment_expiry ON conversation_submissions(attachments_expires_at) WHERE state='preparing';
