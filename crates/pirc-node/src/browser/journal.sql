-- Minimal browser session-group evidence; no URLs, input, cookies or PIDs.
CREATE TABLE browser_groups (
 id TEXT PRIMARY KEY,
 session_id TEXT NOT NULL,
 workspace_id TEXT NOT NULL,
 root TEXT NOT NULL,
 incarnation TEXT NOT NULL,
 state TEXT NOT NULL CHECK(state IN ('active','settled','unconfirmed')),
 created_at INTEGER NOT NULL,
 updated_at INTEGER NOT NULL,
 binding_generation INTEGER
);
CREATE INDEX browser_groups_session ON browser_groups(session_id,state);
CREATE TRIGGER browser_groups_identity BEFORE UPDATE OF id,session_id,workspace_id,root,incarnation,created_at ON browser_groups BEGIN
 SELECT RAISE(ABORT,'Browser group origin is immutable');
END;
CREATE TRIGGER browser_groups_terminal BEFORE UPDATE OF state ON browser_groups
WHEN OLD.state!='active' AND NEW.state!=OLD.state BEGIN
 SELECT RAISE(ABORT,'Browser outcome cannot be replayed');
END;
CREATE TRIGGER browser_groups_retained BEFORE DELETE ON browser_groups BEGIN
 SELECT RAISE(ABORT,'Browser evidence is retained');
END;
