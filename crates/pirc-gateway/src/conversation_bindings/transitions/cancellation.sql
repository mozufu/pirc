-- C3: the Gateway's durable cancellation intent. Once recorded, the
-- coordinator never starts another install phase for the operation; the Node's
-- committed release or install receipt decides the outcome.
CREATE TABLE conversation_transition_cancellations (
 owner_user TEXT NOT NULL,
 operation_id TEXT NOT NULL,
 session_id TEXT NOT NULL,
 client_id TEXT NOT NULL,
 requested_at INTEGER NOT NULL,
 PRIMARY KEY(owner_user,operation_id)
);
CREATE TRIGGER conversation_transition_cancellation_immutable BEFORE UPDATE ON conversation_transition_cancellations BEGIN
 SELECT RAISE(ABORT,'A cancellation intent is immutable');
END;
CREATE TRIGGER conversation_transition_cancellation_session_deleted AFTER DELETE ON sessions BEGIN
 DELETE FROM conversation_transition_cancellations WHERE session_id=OLD.id;
END;
