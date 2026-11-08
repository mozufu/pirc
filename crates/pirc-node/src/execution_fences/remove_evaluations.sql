-- Test fixtures only: remove the 2036 cancellation layer first.
DROP TRIGGER execution_fence_cancel_blocks_install;
DROP TRIGGER execution_fence_cancel_once;
ALTER TABLE execution_fences DROP COLUMN cancel_reason;
ALTER TABLE execution_fences DROP COLUMN cancel_requested_at;
-- Test fixtures only: remove the 2035 evaluation snapshot layer first.
DROP TRIGGER revocation_evaluation_retained;
DROP TRIGGER revocation_evaluation_immutable;
DROP TABLE revocation_evaluations;
