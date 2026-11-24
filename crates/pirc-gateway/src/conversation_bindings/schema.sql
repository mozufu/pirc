-- U2 compatibility bindings: organization and execution have separate revisions.
-- This is a projection of the existing workspace relationship, not a new grant or
-- a supported transition. A later transition must replace this adapter only after
-- Node revocation/acknowledgement is implemented.
CREATE TABLE conversation_bindings (
 session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
 membership_revision INTEGER NOT NULL DEFAULT 1 CHECK(typeof(membership_revision)='integer' AND membership_revision BETWEEN 1 AND 9007199254740991),
 legacy_workspace_id TEXT NOT NULL REFERENCES workspaces(id),
 generation INTEGER NOT NULL DEFAULT 1 CHECK(typeof(generation)='integer' AND generation BETWEEN 1 AND 9007199254740991),
 execution_workspace_id TEXT NOT NULL REFERENCES workspaces(id),
 node_id TEXT,
 mode_id TEXT NOT NULL
);
CREATE INDEX conversation_bindings_workspace ON conversation_bindings(execution_workspace_id);

-- Cover every creator atomically: legacy HTTP, first Send, delegation, schedules,
-- pots and checkpoint continuation. No read-time allocation or history rewrite.
CREATE TRIGGER conversation_binding_insert AFTER INSERT ON sessions BEGIN
 INSERT INTO conversation_bindings(session_id,legacy_workspace_id,execution_workspace_id,node_id,mode_id)
 SELECT NEW.id,NEW.workspace_id,NEW.workspace_id,NEW.node_id,kind
 FROM workspaces WHERE id=NEW.workspace_id;
END;
CREATE TRIGGER conversation_binding_mapping AFTER UPDATE OF workspace_id,node_id,pi_session_id ON sessions
 WHEN NEW.workspace_id IS NOT OLD.workspace_id OR NEW.node_id IS NOT OLD.node_id
   OR (OLD.pi_session_id IS NOT NULL AND NEW.pi_session_id IS NOT OLD.pi_session_id)
 BEGIN
 UPDATE conversation_bindings SET
   membership_revision=membership_revision+(NEW.workspace_id IS NOT OLD.workspace_id),
   legacy_workspace_id=NEW.workspace_id,
   generation=generation+1,execution_workspace_id=NEW.workspace_id,node_id=NEW.node_id,
   mode_id=(SELECT kind FROM workspaces WHERE id=NEW.workspace_id)
 WHERE session_id=NEW.id;
END;
-- A first Send receiving its first private Node ID completes the existing
-- binding; it does not change environments. Replacing an established ID does.
-- A runner restart, device takeover, rename or repository metadata refresh does
-- not change either revision.
CREATE TRIGGER conversation_binding_mode AFTER UPDATE OF kind ON workspaces
 WHEN NEW.kind IS NOT OLD.kind BEGIN
 UPDATE conversation_bindings SET generation=generation+1,
   membership_revision=membership_revision+1,mode_id=NEW.kind
 WHERE execution_workspace_id=NEW.id;
END;
