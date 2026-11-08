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
