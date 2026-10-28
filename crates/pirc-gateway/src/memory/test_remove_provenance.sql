-- Test-only reconstruction before 1026.
DROP TABLE conversation_transition_previews;
-- Test-only reconstruction before 1025.
DROP TRIGGER command_environment_immutable;
DROP TABLE command_environments;
-- Test-only reconstruction before 1024.
DROP TABLE project_memory_cleanup_sessions;
DROP TABLE project_memory_cleanup;
-- Test-only reconstruction of schemas before 1023.
DROP TRIGGER memory_version_context_immutable;
DROP TRIGGER memory_proposal_context_immutable;
DROP TRIGGER memory_version_context_scrub;
DROP TRIGGER memory_proposal_context_scrub;
DROP TABLE memory_version_contexts;
DROP TABLE memory_proposal_contexts;
