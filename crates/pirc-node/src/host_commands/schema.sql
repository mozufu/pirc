-- Minimal metadata, not commands/output/credentials or reusable numeric PIDs.
-- A supervisor finishing is not proof that every detached descendant exited.
CREATE TABLE host_command_runs (
 id TEXT PRIMARY KEY,
 session_id TEXT NOT NULL,
 workspace_id TEXT NOT NULL,
 runner_epoch INTEGER NOT NULL,
 incarnation TEXT NOT NULL,
 request_id TEXT NOT NULL,
 state TEXT NOT NULL CHECK(state IN ('launching','running','not_started','settled','unconfirmed')),
 created_at INTEGER NOT NULL,
 updated_at INTEGER NOT NULL,
 binding_generation INTEGER
);
CREATE UNIQUE INDEX host_command_request ON host_command_runs(session_id,runner_epoch,incarnation,request_id);
CREATE INDEX host_command_session ON host_command_runs(session_id,state);
CREATE TRIGGER host_command_identity BEFORE UPDATE OF id,session_id,workspace_id,runner_epoch,incarnation,request_id,created_at ON host_command_runs BEGIN
 SELECT RAISE(ABORT,'Host command identity is immutable');
END;
CREATE TRIGGER host_command_terminal BEFORE UPDATE OF state ON host_command_runs
WHEN OLD.state IN ('not_started','settled','unconfirmed') AND NEW.state!=OLD.state BEGIN
 SELECT RAISE(ABORT,'Host command outcome cannot be replayed');
END;
CREATE TRIGGER host_command_retained BEFORE DELETE ON host_command_runs BEGIN
 SELECT RAISE(ABORT,'Host command evidence is retained');
END;
