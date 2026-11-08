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
-- Test fixtures only: remove the 2029 request result layer first.
DROP INDEX terminal_host_requests_page;
DROP INDEX terminal_work_requests_page;
DROP TRIGGER terminal_host_error_once;
ALTER TABLE terminal_host_requests DROP COLUMN error_code;
-- Test fixtures only: remove the newest request layer before older schemas.
DROP TRIGGER terminal_work_identity;
DROP TRIGGER terminal_work_once;
DROP TRIGGER terminal_work_monotonic;
DROP TRIGGER terminal_work_retained;
DROP TABLE terminal_work_requests;
-- Test fixtures only, before removing earlier terminal schemas.
DROP TRIGGER terminal_host_identity;
DROP TRIGGER terminal_host_once;
DROP TRIGGER terminal_host_retained;
DROP TABLE terminal_host_requests;
-- Test fixtures only: restore the earlier immutable terminal outcome rule.
DROP TRIGGER terminal_runs_terminal;
CREATE TRIGGER terminal_runs_terminal BEFORE UPDATE OF state ON terminal_runs
WHEN OLD.state IN ('not_started','settled','unconfirmed') AND NEW.state!=OLD.state BEGIN
 SELECT RAISE(ABORT,'Terminal outcome cannot be replayed');
END;
DROP TRIGGER terminal_owner_identity;
DROP TRIGGER terminal_owner_monotonic;
DROP TRIGGER terminal_owner_retained;
DROP TABLE terminal_io_owners;
-- Test fixtures only: reconstruct a schema before host-management approvals.
DROP TRIGGER host_approval_identity;
DROP TRIGGER host_approval_once;
DROP TRIGGER host_approval_retained;
DROP TABLE host_execution_approvals;
DROP TRIGGER browser_groups_identity;
DROP TRIGGER browser_groups_terminal;
DROP TRIGGER browser_groups_retained;
DROP TABLE browser_groups;
