-- Minimal retained fact: Node already accepted a source admission fence.
-- No foreign key to the target/preview: deleting either must not reopen dispatch.
CREATE TABLE conversation_node_fences (
 owner_user TEXT NOT NULL,
 operation_id TEXT NOT NULL,
 session_id TEXT NOT NULL,
 intent_digest TEXT NOT NULL,
 state TEXT NOT NULL CHECK(state IN ('fenced','deleted')),
 created_at INTEGER NOT NULL,
 PRIMARY KEY(owner_user,operation_id)
);
CREATE UNIQUE INDEX conversation_node_fence_active ON conversation_node_fences(session_id) WHERE state='fenced';
CREATE TRIGGER conversation_node_fence_immutable BEFORE UPDATE OF owner_user,operation_id,session_id,intent_digest,created_at ON conversation_node_fences BEGIN
 SELECT RAISE(ABORT,'Node fence identities are immutable');
END;
CREATE TRIGGER conversation_node_fence_retained BEFORE DELETE ON conversation_node_fences BEGIN
 SELECT RAISE(ABORT,'Node fence receipts are retained');
END;
CREATE TRIGGER conversation_node_fence_closed BEFORE UPDATE OF state ON conversation_node_fences WHEN (OLD.state='deleted' AND NEW.state!='deleted') OR (NEW.state='deleted' AND EXISTS(SELECT 1 FROM sessions WHERE id=OLD.session_id)) BEGIN
 SELECT RAISE(ABORT,'Only canonical session deletion may close a Node fence');
END;
CREATE TRIGGER conversation_node_fence_session_deleted AFTER DELETE ON sessions BEGIN
 UPDATE conversation_node_fences SET state='deleted' WHERE session_id=OLD.id;
END;
