-- Test fixtures only: remove the 2038 folder grant layer first.
DROP TRIGGER folder_grant_session_deleted;
DROP TRIGGER folder_grant_immutable;
DROP INDEX folder_grants_active;
DROP TABLE folder_grants;
-- Test fixtures only: restore the 2036 notice trigger first.
DROP TRIGGER environment_event_once;
CREATE TRIGGER environment_event_once BEFORE UPDATE OF state ON environment_events
WHEN NOT ((OLD.state='pending' AND NEW.state='sending') OR (OLD.state='sending' AND NEW.state IN ('delivered','uncertain'))) BEGIN
 SELECT RAISE(ABORT,'An environment notice is sent at most once');
END;
-- Test fixtures only: remove the 2036 cancellation layer first.
DROP TRIGGER execution_fence_cancel_blocks_install;
DROP TRIGGER execution_fence_cancel_once;
ALTER TABLE execution_fences DROP COLUMN cancel_reason;
ALTER TABLE execution_fences DROP COLUMN cancel_requested_at;
-- Test fixtures only: remove the 2035 evaluation snapshot layer first.
DROP TRIGGER revocation_evaluation_retained;
DROP TRIGGER revocation_evaluation_immutable;
DROP TABLE revocation_evaluations;
-- Test fixtures only: remove the 2034 generation attribution layer first.
DROP TRIGGER browser_group_generation_fixed;
DROP TRIGGER terminal_run_generation_fixed;
DROP TRIGGER host_command_generation_fixed;
DROP TRIGGER sandbox_launch_generation_fixed;
DROP TRIGGER browser_group_generation;
DROP TRIGGER terminal_run_generation;
DROP TRIGGER host_command_generation;
DROP TRIGGER sandbox_launch_generation;
ALTER TABLE browser_groups DROP COLUMN binding_generation;
ALTER TABLE terminal_runs DROP COLUMN binding_generation;
ALTER TABLE host_command_runs DROP COLUMN binding_generation;
ALTER TABLE sandbox_launches DROP COLUMN binding_generation;
-- Test fixtures only: remove the 2033 operation authority layer first.
DROP TABLE operation_authority_clock;
DROP TRIGGER operation_authority_retained;
DROP TRIGGER operation_authority_immutable;
DROP TABLE operation_authorities;
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
