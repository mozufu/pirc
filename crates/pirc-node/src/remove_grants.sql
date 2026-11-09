-- Test fixtures only: remove the 2038 folder grant layer first.
DROP TRIGGER folder_grant_session_deleted;
DROP TRIGGER folder_grant_immutable;
DROP INDEX folder_grants_active;
DROP TABLE folder_grants;
