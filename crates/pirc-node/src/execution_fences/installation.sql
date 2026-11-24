-- A transition's admission fence survives process/reply loss. It is not proof
-- of OS revocation or installation. Keep a tombstone after session deletion.
-- Installation and explicit release end a fence. Both are terminal and inactive:
-- admission reopens only under the installed or original binding. Installation
-- requires the drain and the new binding generation in the same transaction.
CREATE TABLE execution_fences (
 owner_user TEXT NOT NULL,
 operation_id TEXT NOT NULL,
 session_id TEXT NOT NULL,
 intent_json TEXT NOT NULL CHECK(json_valid(intent_json)),
 state TEXT NOT NULL CHECK(state IN ('fenced','stopping','blocked','supervisor_drained','installed','released','deleted')),
 error_code TEXT,
 created_at INTEGER NOT NULL,
 updated_at INTEGER NOT NULL,
 -- C3: a durable cancellation request on the fence itself. Release, drain and
 -- installation serialize on this row; a request never clears and blocks install.
 cancel_requested_at INTEGER,
 cancel_reason TEXT,
 PRIMARY KEY(owner_user,operation_id)
);
CREATE UNIQUE INDEX execution_fence_active ON execution_fences(session_id) WHERE state NOT IN ('deleted','installed','released');
CREATE TRIGGER execution_fence_identity BEFORE UPDATE OF owner_user,operation_id,session_id,intent_json,created_at ON execution_fences BEGIN
 SELECT RAISE(ABORT,'Execution fence identity is immutable');
END;
CREATE TRIGGER execution_fence_retained BEFORE DELETE ON execution_fences BEGIN
 SELECT RAISE(ABORT,'Execution fences are retained for reconciliation');
END;
CREATE TRIGGER execution_fence_session_deleted AFTER DELETE ON sessions BEGIN
 UPDATE execution_fences SET state='deleted',error_code=NULL WHERE session_id=OLD.id;
END;
CREATE TRIGGER execution_fence_terminal BEFORE UPDATE OF state ON execution_fences
WHEN (OLD.state IN ('installed','released','deleted') AND NEW.state!='deleted')
 OR (NEW.state='installed' AND (OLD.state!='supervisor_drained' OR NOT EXISTS(
  SELECT 1 FROM session_binding_generations g WHERE g.session_id=OLD.session_id AND g.operation_id=OLD.operation_id)))
 OR (NEW.state='released' AND OLD.state NOT IN ('fenced','stopping','blocked','supervisor_drained')) BEGIN
 SELECT RAISE(ABORT,'A transition fence ends once, by drain plus installation or explicit release');
END;
-- The reviewed target, frozen at acceptance. Source activity changes during the
-- drain, so installation compares only this target subset, never the full hash.
CREATE TABLE execution_fence_targets (
 owner_user TEXT NOT NULL,
 operation_id TEXT NOT NULL,
 target_json TEXT NOT NULL CHECK(json_valid(target_json)),
 PRIMARY KEY(owner_user,operation_id)
);
CREATE TRIGGER execution_fence_target_immutable BEFORE UPDATE ON execution_fence_targets BEGIN
 SELECT RAISE(ABORT,'A reviewed transition target is immutable');
END;
CREATE TRIGGER execution_fence_target_retained BEFORE DELETE ON execution_fence_targets BEGIN
 SELECT RAISE(ABORT,'A reviewed transition target is retained');
END;
-- A user's acknowledgement of exactly one unproven evaluation. It closes nothing.
CREATE TABLE transition_acknowledgements (
 owner_user TEXT NOT NULL,
 operation_id TEXT NOT NULL,
 digest TEXT NOT NULL CHECK(length(digest)=64),
 items_json TEXT NOT NULL CHECK(json_valid(items_json)),
 client_id TEXT NOT NULL,
 generation INTEGER NOT NULL,
 created_at INTEGER NOT NULL,
 PRIMARY KEY(owner_user,operation_id,digest)
);
CREATE TRIGGER transition_acknowledgement_immutable BEFORE UPDATE ON transition_acknowledgements BEGIN
 SELECT RAISE(ABORT,'Transition acknowledgements are immutable');
END;
CREATE TRIGGER transition_acknowledgement_retained BEFORE DELETE ON transition_acknowledgements BEGIN
 SELECT RAISE(ABORT,'Transition acknowledgements are retained');
END;
-- One trusted environment-change notice per installation, delivered at most once.
CREATE TABLE environment_events (
 owner_user TEXT NOT NULL,
 operation_id TEXT NOT NULL,
 session_id TEXT NOT NULL,
 from_workspace_id TEXT NOT NULL,
 to_workspace_id TEXT NOT NULL,
 revocation TEXT NOT NULL CHECK(revocation IN ('confirmed','unproven')),
 state TEXT NOT NULL CHECK(state IN ('pending','sending','delivered','uncertain')),
 created_at INTEGER NOT NULL,
 updated_at INTEGER NOT NULL,
 PRIMARY KEY(owner_user,operation_id)
);
CREATE INDEX environment_events_pending ON environment_events(session_id) WHERE state='pending';
CREATE TRIGGER environment_event_identity BEFORE UPDATE OF owner_user,operation_id,session_id,from_workspace_id,to_workspace_id,revocation,created_at ON environment_events BEGIN
 SELECT RAISE(ABORT,'Environment event identity is immutable');
END;
CREATE TRIGGER environment_event_session_deleted AFTER DELETE ON sessions BEGIN
 DELETE FROM environment_events WHERE session_id=OLD.id;
END;
