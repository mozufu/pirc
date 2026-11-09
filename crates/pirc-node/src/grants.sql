-- C6a: explicit per-conversation folder access. A deny overrides every
-- overlapping grant and the workspace. Grants are retained after revocation.
CREATE TABLE folder_grants (
 grant_id TEXT PRIMARY KEY,
 session_id TEXT NOT NULL,
 path TEXT NOT NULL,
 access TEXT NOT NULL CHECK(access IN ('read','write','deny')),
 client_id TEXT NOT NULL,
 created_at INTEGER NOT NULL,
 revoked_at INTEGER
);
CREATE INDEX folder_grants_active ON folder_grants(session_id) WHERE revoked_at IS NULL;
CREATE TRIGGER folder_grant_immutable BEFORE UPDATE ON folder_grants
WHEN NEW.grant_id IS NOT OLD.grant_id OR NEW.session_id IS NOT OLD.session_id OR NEW.path IS NOT OLD.path
 OR NEW.access IS NOT OLD.access OR NEW.client_id IS NOT OLD.client_id OR NEW.created_at IS NOT OLD.created_at
 OR OLD.revoked_at IS NOT NULL OR NEW.revoked_at IS NULL BEGIN
 SELECT RAISE(ABORT,'A folder grant is immutable except for one revocation');
END;
CREATE TRIGGER folder_grant_session_deleted AFTER DELETE ON sessions BEGIN
 DELETE FROM folder_grants WHERE session_id=OLD.id;
END;
