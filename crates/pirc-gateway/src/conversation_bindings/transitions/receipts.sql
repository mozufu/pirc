-- Minimal retained fact: Node already accepted a source admission fence.
-- No foreign key to the target/preview: deleting either must not reopen dispatch.
CREATE TABLE conversation_node_fences (
 owner_user TEXT NOT NULL,
 operation_id TEXT NOT NULL,
 session_id TEXT NOT NULL,
 intent_digest TEXT NOT NULL,
 state TEXT NOT NULL CHECK(state IN ('fenced','installed','released','deleted')),
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
CREATE TRIGGER conversation_node_fence_closed BEFORE UPDATE OF state ON conversation_node_fences WHEN NEW.state!=OLD.state AND NOT(
 (OLD.state='fenced' AND NEW.state IN ('installed','released'))
 OR (NEW.state='deleted' AND NOT EXISTS(SELECT 1 FROM sessions WHERE id=OLD.session_id))) BEGIN
 SELECT RAISE(ABORT,'A Node fence ends only by installation, release or canonical session deletion');
END;
