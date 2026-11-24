-- The Node's binding history for revocation evaluation. Every session and every
-- installed generation has complete journal coverage; `legacy` coverage (launches
-- that cannot be ruled out) is no longer written.
CREATE TABLE session_binding_generations (
 session_id TEXT NOT NULL,
 generation INTEGER NOT NULL CHECK(generation>=1),
 workspace_id TEXT NOT NULL,
 coverage TEXT NOT NULL CHECK(coverage IN ('legacy','complete')),
 start_epoch INTEGER NOT NULL CHECK(start_epoch>=0),
 started_at INTEGER NOT NULL CHECK(started_at>=0),
 operation_id TEXT,
 PRIMARY KEY(session_id,generation),
 CHECK((generation=1)=(operation_id IS NULL))
);
CREATE TRIGGER session_binding_generation_new AFTER INSERT ON sessions BEGIN
 INSERT INTO session_binding_generations VALUES(NEW.id,1,NEW.workspace_id,'complete',NEW.runner_epoch,0,NULL);
END;
CREATE TRIGGER session_binding_generation_identity BEFORE UPDATE ON session_binding_generations BEGIN
 SELECT RAISE(ABORT,'Binding generations are immutable');
END;
CREATE TRIGGER session_binding_generation_retained BEFORE DELETE ON session_binding_generations
WHEN EXISTS(SELECT 1 FROM sessions WHERE id=OLD.session_id) BEGIN
 SELECT RAISE(ABORT,'Binding generations are retained while their session exists');
END;
CREATE TRIGGER session_binding_generation_deleted AFTER DELETE ON sessions BEGIN
 DELETE FROM session_binding_generations WHERE session_id=OLD.id;
END;
