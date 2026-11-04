-- Test fixtures only: reconstruct a schema before host-management approvals.
DROP TRIGGER host_approval_identity;
DROP TRIGGER host_approval_once;
DROP TRIGGER host_approval_retained;
DROP TABLE host_execution_approvals;
DROP TRIGGER browser_groups_identity;
DROP TRIGGER browser_groups_terminal;
DROP TRIGGER browser_groups_retained;
DROP TABLE browser_groups;
DROP TRIGGER terminal_runs_identity;
DROP TRIGGER terminal_runs_terminal;
DROP TRIGGER terminal_runs_retained;
DROP TABLE terminal_runs;
