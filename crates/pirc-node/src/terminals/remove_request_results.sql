-- Test fixtures only: remove the 2032 installation layer first.
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
-- Test fixtures only: remove the 2031 binding generation layer first.
DROP TRIGGER session_binding_generation_deleted;
DROP TRIGGER session_binding_generation_retained;
DROP TRIGGER session_binding_generation_identity;
DROP TRIGGER session_binding_generation_new;
DROP TABLE session_binding_generations;
-- Test fixtures only: remove the 2030 acknowledgement layer first.
DROP TRIGGER terminal_host_acknowledged_once;
DROP TRIGGER terminal_work_acknowledged_once;
ALTER TABLE terminal_host_requests DROP COLUMN acknowledged_by;
ALTER TABLE terminal_host_requests DROP COLUMN acknowledged_at;
ALTER TABLE terminal_work_requests DROP COLUMN acknowledged_by;
ALTER TABLE terminal_work_requests DROP COLUMN acknowledged_at;
-- Test fixtures only: restore the 2028 request result layer.
DROP INDEX terminal_host_requests_page;
DROP INDEX terminal_work_requests_page;
DROP TRIGGER terminal_host_error_once;
ALTER TABLE terminal_host_requests DROP COLUMN error_code;
DROP TRIGGER terminal_work_monotonic;
CREATE TRIGGER terminal_work_monotonic BEFORE UPDATE OF state,error_code ON terminal_work_requests
WHEN OLD.state!='accepted' OR NEW.state='accepted' OR (NEW.state='not_started' AND OLD.run_id IS NOT NULL) BEGIN
 SELECT RAISE(ABORT,'Work terminal outcome cannot be retried or reset');
END;
