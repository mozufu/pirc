-- C1 operation authority as issued by the Gateway: the token the coordinator
-- presents to the Node for automatic steps of one accepted transition. It is
-- secret, separate from device control and removed with its conversation.
CREATE TABLE conversation_operation_authorities (
 owner_user TEXT NOT NULL,
 operation_id TEXT NOT NULL,
 session_id TEXT NOT NULL,
 revision INTEGER NOT NULL CHECK(revision>=1),
 token TEXT NOT NULL CHECK(length(token)=64),
 deadline_at INTEGER NOT NULL,
 issued_at INTEGER NOT NULL,
 revoked_at INTEGER,
 PRIMARY KEY(owner_user,operation_id,revision),
 CHECK(deadline_at>issued_at)
);
CREATE TRIGGER conversation_operation_authority_immutable BEFORE UPDATE ON conversation_operation_authorities
WHEN NEW.token IS NOT OLD.token OR NEW.deadline_at IS NOT OLD.deadline_at OR NEW.revision IS NOT OLD.revision
 OR NEW.issued_at IS NOT OLD.issued_at OR OLD.revoked_at IS NOT NULL OR NEW.revoked_at IS NULL BEGIN
 SELECT RAISE(ABORT,'Operation authority is immutable except for one revocation');
END;
CREATE TRIGGER conversation_operation_authority_session_deleted AFTER DELETE ON sessions BEGIN
 DELETE FROM conversation_operation_authorities WHERE session_id=OLD.id;
END;
CREATE TABLE conversation_authority_clock (
 id INTEGER PRIMARY KEY CHECK(id=1),
 max_seen_at INTEGER NOT NULL
);
