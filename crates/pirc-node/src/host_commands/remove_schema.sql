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
-- Tests only: reconstruct pre-2016 schema.
DROP TRIGGER host_resources_immutable;
DROP TRIGGER host_resources_retained;
DROP TABLE host_command_resources;
DROP INDEX host_commands_pending;
-- Test fixtures only: reconstruct the pre-2015 schema before migration.
DROP TRIGGER host_command_identity;
DROP TRIGGER host_command_terminal;
DROP TRIGGER host_command_retained;
DROP TABLE host_command_runs;
