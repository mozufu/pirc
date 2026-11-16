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
