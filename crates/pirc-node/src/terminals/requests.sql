-- Stable isolated-work request identity; retries never schedule a second worker.
CREATE TABLE terminal_work_requests (
 owner_user TEXT NOT NULL,
 session_id TEXT NOT NULL,
 request_id TEXT NOT NULL,
 incarnation TEXT NOT NULL,
 workspace_id TEXT NOT NULL,
 runner_epoch INTEGER NOT NULL,
 cwd TEXT NOT NULL,
 intent_hash TEXT NOT NULL CHECK(length(intent_hash)=64),
 state TEXT NOT NULL CHECK(state IN ('accepted','not_started','outcome_unknown')),
 error_code TEXT,
 run_id TEXT UNIQUE REFERENCES terminal_runs(id),
 terminal_id TEXT UNIQUE,
 created_at INTEGER NOT NULL,
 PRIMARY KEY(owner_user,session_id,request_id),
 CHECK((run_id IS NULL)=(terminal_id IS NULL)),
 CHECK(state!='not_started' OR run_id IS NULL)
);
CREATE TRIGGER terminal_work_identity BEFORE UPDATE OF owner_user,session_id,request_id,incarnation,workspace_id,runner_epoch,cwd,intent_hash,created_at ON terminal_work_requests BEGIN
 SELECT RAISE(ABORT,'Work terminal request identity is immutable');
END;
CREATE TRIGGER terminal_work_once BEFORE UPDATE OF run_id,terminal_id ON terminal_work_requests
WHEN OLD.run_id IS NOT NULL OR NEW.run_id IS NULL OR NEW.terminal_id IS NULL OR OLD.state!='accepted'
 OR NOT EXISTS(SELECT 1 FROM terminal_runs t JOIN sandbox_launches l ON l.launch_id=t.id
  WHERE t.id=NEW.run_id AND t.session_id=OLD.session_id AND t.workspace_id=OLD.workspace_id
  AND t.incarnation=OLD.incarnation AND t.cwd=OLD.cwd AND t.state='launching'
  AND l.session_id=t.session_id AND l.workspace_id=t.workspace_id AND l.incarnation=t.incarnation
  AND l.resource_kind='terminal' AND l.runner_epoch=OLD.runner_epoch
  AND l.state='launching' AND l.guard_state='waiting') BEGIN
 SELECT RAISE(ABORT,'Work terminal request can reserve its own scope only once');
END;
CREATE TRIGGER terminal_work_monotonic BEFORE UPDATE OF state,error_code ON terminal_work_requests
WHEN OLD.state!='accepted' OR NEW.state='accepted' OR (NEW.state='not_started' AND OLD.run_id IS NOT NULL) BEGIN
 SELECT RAISE(ABORT,'Work terminal outcome cannot be retried or reset');
END;
CREATE TRIGGER terminal_work_retained BEFORE DELETE ON terminal_work_requests BEGIN
 SELECT RAISE(ABORT,'Work terminal request evidence is retained');
END;
