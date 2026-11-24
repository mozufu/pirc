-- Deleting a session closes its accepted transitions and Node fences.
CREATE TRIGGER conversation_transition_acceptance_session_deleted AFTER DELETE ON sessions BEGIN
 UPDATE conversation_transition_acceptances SET state='deleted',frozen_json=NULL WHERE session_id=OLD.id;
END;
CREATE TRIGGER conversation_node_fence_session_deleted AFTER DELETE ON sessions BEGIN
 UPDATE conversation_node_fences SET state='deleted' WHERE session_id=OLD.id;
END;
-- The latest sanitized Node receipt of a coordinated transition, for status.
CREATE TABLE conversation_transition_progress (
 owner_user TEXT NOT NULL,
 operation_id TEXT NOT NULL,
 session_id TEXT NOT NULL,
 receipt_json TEXT NOT NULL CHECK(json_valid(receipt_json)),
 updated_at INTEGER NOT NULL,
 PRIMARY KEY(owner_user,operation_id)
);
CREATE TRIGGER conversation_transition_progress_session_deleted AFTER DELETE ON sessions BEGIN
 DELETE FROM conversation_transition_progress WHERE session_id=OLD.id;
END;
