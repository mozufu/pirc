-- Test fixtures only: remove the 2040 transition void layer first.
DROP TRIGGER execution_fence_blocked_by_void;
DROP TRIGGER execution_fence_void_not_created;
DROP TRIGGER execution_fence_void_retained;
DROP TRIGGER execution_fence_void_immutable;
DROP TABLE execution_fence_voids;
