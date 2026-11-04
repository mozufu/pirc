-- Node-issued host-management questions, bound before publication. No commands,
-- output, tokens or reusable PIDs; an unanswered question grants nothing.
CREATE TABLE host_execution_approvals (
 interaction_id TEXT PRIMARY KEY,
 execution_path TEXT NOT NULL CHECK(execution_path='host_management'),
 session_id TEXT NOT NULL,
 workspace_id TEXT NOT NULL,
 runner_epoch INTEGER NOT NULL,
 incarnation TEXT NOT NULL,
 request_id TEXT NOT NULL,
 intent_hash TEXT NOT NULL CHECK(length(intent_hash)=64),
 run_id TEXT UNIQUE REFERENCES host_command_runs(id),
 created_at INTEGER NOT NULL,
 UNIQUE(session_id,runner_epoch,incarnation,request_id)
);
CREATE TRIGGER host_approval_identity BEFORE UPDATE OF interaction_id,execution_path,session_id,workspace_id,runner_epoch,incarnation,request_id,intent_hash,created_at ON host_execution_approvals BEGIN
 SELECT RAISE(ABORT,'Host approval origin is immutable');
END;
CREATE TRIGGER host_approval_once BEFORE UPDATE OF run_id ON host_execution_approvals
WHEN OLD.run_id IS NOT NULL OR NEW.run_id IS NULL BEGIN
 SELECT RAISE(ABORT,'Host approval can be consumed only once');
END;
CREATE TRIGGER host_approval_retained BEFORE DELETE ON host_execution_approvals BEGIN
 SELECT RAISE(ABORT,'Host approval evidence is retained');
END;
