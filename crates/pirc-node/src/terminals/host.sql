-- A human terminal review is not an Agent confirmation or a reusable mode grant.
CREATE TABLE terminal_host_requests (
 id TEXT PRIMARY KEY,
 owner_user TEXT NOT NULL,
 session_id TEXT NOT NULL,
 request_id TEXT NOT NULL,
 incarnation TEXT NOT NULL,
 intent_hash TEXT NOT NULL CHECK(length(intent_hash)=64),
 review_json TEXT NOT NULL CHECK(json_valid(review_json)),
 created_at INTEGER NOT NULL,
 expires_at INTEGER NOT NULL,
 run_id TEXT UNIQUE REFERENCES terminal_runs(id),
 terminal_id TEXT UNIQUE,
 error_code TEXT,
 acknowledged_at INTEGER,
 acknowledged_by TEXT,
 UNIQUE(owner_user,session_id,request_id),
 CHECK((run_id IS NULL)=(terminal_id IS NULL))
);
CREATE TRIGGER terminal_host_identity BEFORE UPDATE OF id,owner_user,session_id,request_id,incarnation,intent_hash,review_json,created_at,expires_at ON terminal_host_requests BEGIN
 SELECT RAISE(ABORT,'Host terminal review is immutable');
END;
CREATE TRIGGER terminal_host_once BEFORE UPDATE OF run_id,terminal_id ON terminal_host_requests
WHEN OLD.run_id IS NOT NULL OR NEW.run_id IS NULL OR NEW.terminal_id IS NULL
 OR NOT EXISTS(SELECT 1 FROM terminal_runs r WHERE r.id=NEW.run_id
  AND r.session_id=OLD.session_id AND r.incarnation=OLD.incarnation
  AND r.workspace_id=json_extract(OLD.review_json,'$.workspaceId')
  AND r.cwd=json_extract(OLD.review_json,'$.cwd') AND r.state='launching') BEGIN
 SELECT RAISE(ABORT,'Host terminal review can be consumed only once');
END;
CREATE TRIGGER terminal_host_retained BEFORE DELETE ON terminal_host_requests BEGIN
 SELECT RAISE(ABORT,'Host terminal authority evidence is retained');
END;
