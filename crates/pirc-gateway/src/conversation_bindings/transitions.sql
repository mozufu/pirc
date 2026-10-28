-- Review-only snapshots. No accepted switch, grant or Node fence is stored here.
CREATE TABLE conversation_transition_previews (
 owner_user TEXT NOT NULL,
 operation_id TEXT NOT NULL,
 session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
 target_workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
 intent_hash TEXT NOT NULL,
 plan_hash TEXT NOT NULL,
 plan_json TEXT NOT NULL CHECK(json_valid(plan_json)),
 created_at INTEGER NOT NULL,
 PRIMARY KEY(owner_user,operation_id)
);
CREATE INDEX transition_previews_session ON conversation_transition_previews(session_id);
CREATE TRIGGER transition_preview_immutable BEFORE UPDATE ON conversation_transition_previews BEGIN
 SELECT RAISE(ABORT,'Transition previews are immutable');
END;
