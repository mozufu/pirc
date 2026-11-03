-- Test-only reconstruction before 1027.
DROP TRIGGER conversation_node_fence_session_deleted; DROP TABLE conversation_node_fences;
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
-- Test-only reconstruction of schemas before 1022. Never run in production.
DROP TRIGGER binding_workspace_policy_insert;
DROP TRIGGER binding_workspace_policy_changed;
DROP TRIGGER binding_capabilities_insert;
DROP TRIGGER binding_capabilities_update;
DROP TRIGGER binding_capabilities_delete;
DROP TRIGGER binding_project_insert;
DROP TRIGGER binding_project_mapping;
DROP TRIGGER binding_mode_policy_changed;
DROP TRIGGER binding_mode_policy_immutable;
DROP TRIGGER binding_mode_policy_retained;
DROP TRIGGER binding_workspace_policy_immutable;
DROP TRIGGER binding_workspace_policy_retained;
DROP VIEW conversation_membership_targets;
DROP VIEW current_workspace_policies;
DROP VIEW current_mode_policies;
DROP TABLE conversation_project_memberships;
DROP TABLE workspace_policy_versions;
DROP TABLE mode_policy_versions;
DROP TABLE binding_catalog_state;
