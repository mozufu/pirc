-- Creation identity outlives session/project deletion so delayed retries cannot
-- resurrect them. No prompt, attachment content or credentials are stored here.
CREATE TABLE session_creations (
  owner_user TEXT NOT NULL, operation_id TEXT NOT NULL,
  workspace_id TEXT NOT NULL, submission_hash TEXT NOT NULL,
  session_id TEXT NOT NULL UNIQUE,
  state TEXT NOT NULL CHECK(state IN ('reserved', 'ready')),
  created_at INTEGER NOT NULL,
  PRIMARY KEY(owner_user, operation_id)
);
CREATE INDEX session_creations_workspace ON session_creations(workspace_id);
