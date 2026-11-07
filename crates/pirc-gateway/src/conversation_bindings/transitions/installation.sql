-- A coordinated transition ends as installed or released. Both are terminal and
-- inactive: ordinary commands reopen and a later transition may start. Node
-- receipts still decide; these rows only record what the Node reported.
DROP TRIGGER conversation_transition_acceptance_immutable;
DROP TRIGGER conversation_transition_acceptance_retained;
DROP TRIGGER conversation_transition_acceptance_progress;
DROP TRIGGER conversation_transition_acceptance_session_deleted;
DROP INDEX conversation_transition_acceptance_active;
ALTER TABLE conversation_transition_acceptances RENAME TO conversation_transition_acceptances_1029;
CREATE TABLE conversation_transition_acceptances (
 owner_user TEXT NOT NULL,
 operation_id TEXT NOT NULL,
 session_id TEXT NOT NULL,
 intent_hash TEXT NOT NULL,
 frozen_json TEXT,
 state TEXT NOT NULL CHECK(state IN ('accepted','outcome_unknown','node_fenced','installed','released','deleted')),
 created_at INTEGER NOT NULL,
 CHECK((state='deleted' AND frozen_json IS NULL) OR (state!='deleted' AND frozen_json IS NOT NULL)),
 PRIMARY KEY(owner_user,operation_id)
);
INSERT INTO conversation_transition_acceptances SELECT owner_user,operation_id,session_id,intent_hash,frozen_json,state,created_at FROM conversation_transition_acceptances_1029;
DROP TABLE conversation_transition_acceptances_1029;
CREATE UNIQUE INDEX conversation_transition_acceptance_active ON conversation_transition_acceptances(session_id) WHERE state NOT IN ('deleted','installed','released');
CREATE TRIGGER conversation_transition_acceptance_immutable BEFORE UPDATE OF owner_user,operation_id,session_id,intent_hash,created_at ON conversation_transition_acceptances BEGIN
 SELECT RAISE(ABORT,'Accepted transition identities are immutable');
END;
CREATE TRIGGER conversation_transition_acceptance_retained BEFORE DELETE ON conversation_transition_acceptances BEGIN
 SELECT RAISE(ABORT,'Accepted transition identities are retained');
END;
CREATE TRIGGER conversation_transition_acceptance_progress BEFORE UPDATE ON conversation_transition_acceptances WHEN
 (NEW.frozen_json IS NOT OLD.frozen_json AND NOT(NEW.state='deleted' AND NEW.frozen_json IS NULL AND NOT EXISTS(SELECT 1 FROM sessions WHERE id=OLD.session_id))) OR
 NOT(NEW.state=OLD.state OR (OLD.state='accepted' AND NEW.state='outcome_unknown') OR (OLD.state IN ('accepted','outcome_unknown') AND NEW.state='node_fenced')
  OR (OLD.state='node_fenced' AND NEW.state IN ('installed','released')) OR (OLD.state='accepted' AND NEW.state='released')
  OR (NEW.state='deleted' AND NOT EXISTS(SELECT 1 FROM sessions WHERE id=OLD.session_id))) BEGIN
 SELECT RAISE(ABORT,'Accepted transitions cannot reopen or change intent');
END;
CREATE TRIGGER conversation_transition_acceptance_session_deleted AFTER DELETE ON sessions BEGIN
 UPDATE conversation_transition_acceptances SET state='deleted',frozen_json=NULL WHERE session_id=OLD.id;
END;
DROP TRIGGER conversation_node_fence_immutable;
DROP TRIGGER conversation_node_fence_retained;
DROP TRIGGER conversation_node_fence_closed;
DROP TRIGGER conversation_node_fence_session_deleted;
DROP INDEX conversation_node_fence_active;
ALTER TABLE conversation_node_fences RENAME TO conversation_node_fences_1029;
CREATE TABLE conversation_node_fences (
 owner_user TEXT NOT NULL,
 operation_id TEXT NOT NULL,
 session_id TEXT NOT NULL,
 intent_digest TEXT NOT NULL,
 state TEXT NOT NULL CHECK(state IN ('fenced','installed','released','deleted')),
 created_at INTEGER NOT NULL,
 PRIMARY KEY(owner_user,operation_id)
);
INSERT INTO conversation_node_fences SELECT owner_user,operation_id,session_id,intent_digest,state,created_at FROM conversation_node_fences_1029;
DROP TABLE conversation_node_fences_1029;
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
