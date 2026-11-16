-- Test fixtures only: remove the 2040 transition void layer first.
DROP TRIGGER execution_fence_blocked_by_void;
DROP TRIGGER execution_fence_void_not_created;
DROP TRIGGER execution_fence_void_retained;
DROP TRIGGER execution_fence_void_immutable;
DROP TABLE execution_fence_voids;
-- Test fixtures only: remove the 2039 first-message void layer first.
DROP TRIGGER creation_admission_void_blocks_initial_update;
DROP TRIGGER creation_admission_void_blocks_initial_insert;
DROP TRIGGER creation_admission_void_blocks_attempt;
DROP TRIGGER creation_admission_void_blocks_command;
DROP TRIGGER creation_admission_void_not_admitted;
DROP TRIGGER creation_admission_void_retained;
DROP TRIGGER creation_admission_void_immutable;
DROP TABLE creation_admission_voids;
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
