-- Accepted Gateway intent precedes any Node mutation. No target/preview FK:
-- deleting review data must not release a potentially accepted source fence.
CREATE TABLE conversation_transition_acceptances (
 owner_user TEXT NOT NULL,
 operation_id TEXT NOT NULL,
 session_id TEXT NOT NULL,
 intent_hash TEXT NOT NULL,
 frozen_json TEXT,
 state TEXT NOT NULL CHECK(state IN ('accepted','outcome_unknown','node_fenced','deleted')),
 created_at INTEGER NOT NULL,
 CHECK((state='deleted' AND frozen_json IS NULL) OR (state!='deleted' AND frozen_json IS NOT NULL)),
 PRIMARY KEY(owner_user,operation_id)
);
CREATE UNIQUE INDEX conversation_transition_acceptance_active ON conversation_transition_acceptances(session_id) WHERE state!='deleted';
CREATE TRIGGER conversation_transition_acceptance_immutable BEFORE UPDATE OF owner_user,operation_id,session_id,intent_hash,created_at ON conversation_transition_acceptances BEGIN
 SELECT RAISE(ABORT,'Accepted transition identities are immutable');
END;
CREATE TRIGGER conversation_transition_acceptance_retained BEFORE DELETE ON conversation_transition_acceptances BEGIN
 SELECT RAISE(ABORT,'Accepted transition identities are retained');
END;
CREATE TRIGGER conversation_transition_acceptance_progress BEFORE UPDATE ON conversation_transition_acceptances WHEN
 (NEW.frozen_json IS NOT OLD.frozen_json AND NOT(NEW.state='deleted' AND NEW.frozen_json IS NULL AND NOT EXISTS(SELECT 1 FROM sessions WHERE id=OLD.session_id))) OR
 NOT(NEW.state=OLD.state OR (OLD.state='accepted' AND NEW.state='outcome_unknown') OR (OLD.state IN ('accepted','outcome_unknown') AND NEW.state='node_fenced') OR (NEW.state='deleted' AND NOT EXISTS(SELECT 1 FROM sessions WHERE id=OLD.session_id))) BEGIN
 SELECT RAISE(ABORT,'Accepted transitions cannot reopen or change intent');
END;
CREATE TRIGGER conversation_transition_acceptance_session_deleted AFTER DELETE ON sessions BEGIN
 UPDATE conversation_transition_acceptances SET state='deleted',frozen_json=NULL WHERE session_id=OLD.id;
END;
