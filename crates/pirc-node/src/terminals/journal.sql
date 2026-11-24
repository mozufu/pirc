-- Terminal launch/observation evidence, never commands, output or reusable PIDs.
CREATE TABLE terminal_runs (
 id TEXT PRIMARY KEY,
 session_id TEXT NOT NULL,
 workspace_id TEXT NOT NULL,
 cwd TEXT NOT NULL,
 incarnation TEXT NOT NULL,
 state TEXT NOT NULL CHECK(state IN ('launching','running','not_started','settled','unconfirmed')),
 created_at INTEGER NOT NULL,
 updated_at INTEGER NOT NULL,
 binding_generation INTEGER
);
CREATE INDEX terminal_runs_session ON terminal_runs(session_id,state);
CREATE TRIGGER terminal_runs_identity BEFORE UPDATE OF id,session_id,workspace_id,cwd,incarnation,created_at ON terminal_runs BEGIN
 SELECT RAISE(ABORT,'Terminal origin is immutable');
END;
CREATE TRIGGER terminal_runs_retained BEFORE DELETE ON terminal_runs BEGIN
 SELECT RAISE(ABORT,'Terminal evidence is retained');
END;
