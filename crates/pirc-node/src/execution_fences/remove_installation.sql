-- Test fixtures only: restore the 2031 fence layer.
DROP TRIGGER environment_event_session_deleted;
DROP TRIGGER environment_event_once;
DROP TRIGGER environment_event_identity;
DROP INDEX environment_events_pending;
DROP TABLE environment_events;
DROP TRIGGER transition_acknowledgement_retained;
DROP TRIGGER transition_acknowledgement_immutable;
DROP TABLE transition_acknowledgements;
DROP TRIGGER execution_fence_target_retained;
DROP TRIGGER execution_fence_target_immutable;
DROP TABLE execution_fence_targets;
DROP TRIGGER execution_fence_terminal;
DROP TRIGGER execution_fence_identity;
DROP TRIGGER execution_fence_retained;
DROP TRIGGER execution_fence_session_deleted;
DROP INDEX execution_fence_active;
ALTER TABLE execution_fences RENAME TO execution_fences_2032;
CREATE TABLE execution_fences (
 owner_user TEXT NOT NULL,
 operation_id TEXT NOT NULL,
 session_id TEXT NOT NULL,
 intent_json TEXT NOT NULL CHECK(json_valid(intent_json)),
 state TEXT NOT NULL CHECK(state IN ('fenced','stopping','blocked','supervisor_drained','deleted')),
 error_code TEXT,
 created_at INTEGER NOT NULL,
 updated_at INTEGER NOT NULL,
 PRIMARY KEY(owner_user,operation_id)
);
INSERT INTO execution_fences SELECT * FROM execution_fences_2032;
DROP TABLE execution_fences_2032;
CREATE UNIQUE INDEX execution_fence_active ON execution_fences(session_id) WHERE state!='deleted';
CREATE TRIGGER execution_fence_identity BEFORE UPDATE OF owner_user,operation_id,session_id,intent_json,created_at ON execution_fences BEGIN
 SELECT RAISE(ABORT,'Execution fence identity is immutable');
END;
CREATE TRIGGER execution_fence_retained BEFORE DELETE ON execution_fences BEGIN
 SELECT RAISE(ABORT,'Execution fences are retained for reconciliation');
END;
CREATE TRIGGER execution_fence_session_deleted AFTER DELETE ON sessions BEGIN
 UPDATE execution_fences SET state='deleted',error_code=NULL WHERE session_id=OLD.id;
END;
