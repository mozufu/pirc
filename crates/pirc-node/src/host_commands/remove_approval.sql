-- Test fixtures only: reconstruct a schema before host-management approvals.
DROP TRIGGER host_approval_identity;
DROP TRIGGER host_approval_once;
DROP TRIGGER host_approval_retained;
DROP TABLE host_execution_approvals;
