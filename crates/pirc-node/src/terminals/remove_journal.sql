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
DROP TRIGGER terminal_runs_identity;
DROP TRIGGER terminal_runs_terminal;
DROP TRIGGER terminal_runs_retained;
DROP TABLE terminal_runs;
