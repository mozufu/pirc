-- Configured policy versions; these are not acknowledgements of Node enforcement.
CREATE TABLE binding_catalog_state (id INTEGER PRIMARY KEY CHECK(id=1), initialized INTEGER NOT NULL CHECK(initialized IN (0,1)));
INSERT INTO binding_catalog_state VALUES(1,0);
CREATE TABLE mode_policy_versions (
 mode_id TEXT NOT NULL, revision INTEGER NOT NULL CHECK(typeof(revision)='integer' AND revision BETWEEN 1 AND 9007199254740991),
 mode_json TEXT CHECK(mode_json IS NULL OR json_valid(mode_json)),
 PRIMARY KEY(mode_id,revision)
);
CREATE VIEW current_mode_policies AS SELECT v.* FROM mode_policy_versions v
 WHERE revision=(SELECT MAX(revision) FROM mode_policy_versions WHERE mode_id=v.mode_id);
CREATE TABLE workspace_policy_versions (
 workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
 revision INTEGER NOT NULL CHECK(typeof(revision)='integer' AND revision BETWEEN 1 AND 9007199254740991),
 policy_json TEXT NOT NULL CHECK(json_valid(policy_json)),
 PRIMARY KEY(workspace_id,revision)
);
CREATE VIEW current_workspace_policies AS SELECT v.* FROM workspace_policy_versions v
 WHERE revision=(SELECT MAX(revision) FROM workspace_policy_versions WHERE workspace_id=v.workspace_id);
CREATE TRIGGER binding_workspace_policy_insert AFTER INSERT ON workspaces BEGIN
 INSERT INTO workspace_policy_versions VALUES(NEW.id,1,'{"version":1,"delegation":true,"memory_search":true,"remote_recall":true,"schedules":true,"web_search":true,"delegation_approval":"always"}');
END;
CREATE TRIGGER binding_workspace_policy_changed AFTER INSERT ON workspace_policy_versions
 WHEN NEW.revision>1 BEGIN
 UPDATE conversation_bindings SET generation=generation+1 WHERE execution_workspace_id=NEW.workspace_id;
END;
CREATE TRIGGER binding_capabilities_insert AFTER INSERT ON workspace_capabilities BEGIN
 INSERT INTO workspace_policy_versions
 SELECT NEW.workspace_id,revision+1,NEW.policy_json FROM current_workspace_policies
 WHERE workspace_id=NEW.workspace_id AND policy_json IS NOT NEW.policy_json;
END;
CREATE TRIGGER binding_capabilities_update AFTER UPDATE ON workspace_capabilities BEGIN
 INSERT INTO workspace_policy_versions
 SELECT NEW.workspace_id,revision+1,NEW.policy_json FROM current_workspace_policies
 WHERE workspace_id=NEW.workspace_id AND policy_json IS NOT NEW.policy_json;
END;
CREATE TRIGGER binding_capabilities_delete AFTER DELETE ON workspace_capabilities BEGIN
 INSERT INTO workspace_policy_versions
 SELECT OLD.workspace_id,revision+1,'{"version":1,"delegation":true,"memory_search":true,"remote_recall":true,"schedules":true,"web_search":true,"delegation_approval":"always"}' FROM current_workspace_policies
 WHERE workspace_id=OLD.workspace_id AND EXISTS(SELECT 1 FROM workspaces WHERE id=OLD.workspace_id) AND policy_json IS NOT '{"version":1,"delegation":true,"memory_search":true,"remote_recall":true,"schedules":true,"web_search":true,"delegation_approval":"always"}';
END;
CREATE TABLE conversation_project_memberships (
 session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
 revision INTEGER NOT NULL DEFAULT 1 CHECK(typeof(revision)='integer' AND revision BETWEEN 1 AND 9007199254740991),
 source_workspace_id TEXT NOT NULL REFERENCES workspaces(id),
 project_workspace_id TEXT REFERENCES workspaces(id),
 resolution TEXT NOT NULL CHECK(resolution IN ('unresolved','none','member','mode_unavailable')),
 CHECK(resolution!='member' OR project_workspace_id IS NOT NULL),
 CHECK(resolution!='none' OR project_workspace_id IS NULL)
);
-- Preserve a last known project when its mode is unavailable, only while the
-- original association still matches. Never turn that retained ID into a grant.
CREATE VIEW conversation_membership_targets AS
 SELECT b.session_id,b.legacy_workspace_id AS source_workspace_id,
 CASE WHEN state.initialized=0 THEN 'unresolved'
      WHEN mode.mode_json IS NULL THEN 'mode_unavailable'
      WHEN json_extract(mode.mode_json,'$.projects')=1
       AND substr(w.id,1,length(w.host_id)+1)=w.host_id||':'
       AND substr(w.id,length(w.host_id)+2)!='chats' THEN 'member'
      ELSE 'none' END AS resolution,
 CASE WHEN mode.mode_json IS NULL THEN
        CASE WHEN previous.source_workspace_id=b.legacy_workspace_id THEN previous.project_workspace_id ELSE NULL END
      WHEN json_extract(mode.mode_json,'$.projects')=1
       AND substr(w.id,1,length(w.host_id)+1)=w.host_id||':'
       AND substr(w.id,length(w.host_id)+2)!='chats' THEN w.id
      ELSE NULL END AS project_workspace_id
 FROM conversation_bindings b JOIN workspaces w ON w.id=b.legacy_workspace_id
 CROSS JOIN binding_catalog_state state
 LEFT JOIN current_mode_policies mode ON mode.mode_id=w.kind
 LEFT JOIN conversation_project_memberships previous ON previous.session_id=b.session_id;
CREATE TRIGGER binding_project_insert AFTER INSERT ON conversation_bindings BEGIN
INSERT INTO conversation_project_memberships(session_id,source_workspace_id,project_workspace_id,resolution)
 SELECT session_id,source_workspace_id,project_workspace_id,resolution FROM conversation_membership_targets WHERE session_id=NEW.session_id
 ON CONFLICT(session_id) DO UPDATE SET
   revision=conversation_project_memberships.revision+(
     conversation_project_memberships.resolution!='unresolved' AND
     (conversation_project_memberships.resolution IS NOT excluded.resolution
       OR conversation_project_memberships.project_workspace_id IS NOT excluded.project_workspace_id)),
   source_workspace_id=excluded.source_workspace_id,
   project_workspace_id=excluded.project_workspace_id,resolution=excluded.resolution;
END;
CREATE TRIGGER binding_project_mapping AFTER UPDATE OF legacy_workspace_id,mode_id ON conversation_bindings BEGIN
INSERT INTO conversation_project_memberships(session_id,source_workspace_id,project_workspace_id,resolution)
 SELECT session_id,source_workspace_id,project_workspace_id,resolution FROM conversation_membership_targets WHERE session_id=NEW.session_id
 ON CONFLICT(session_id) DO UPDATE SET
   revision=conversation_project_memberships.revision+(
     conversation_project_memberships.resolution!='unresolved' AND
     (conversation_project_memberships.resolution IS NOT excluded.resolution
       OR conversation_project_memberships.project_workspace_id IS NOT excluded.project_workspace_id)),
   source_workspace_id=excluded.source_workspace_id,
   project_workspace_id=excluded.project_workspace_id,resolution=excluded.resolution;
END;
CREATE TRIGGER binding_mode_policy_changed AFTER INSERT ON mode_policy_versions
 WHEN (SELECT initialized FROM binding_catalog_state WHERE id=1)=1 BEGIN
 UPDATE conversation_bindings SET generation=generation+1 WHERE mode_id=NEW.mode_id;
END;

-- Histories are append-only. Workspace deletion owns its policy retention.
CREATE TRIGGER binding_mode_policy_immutable BEFORE UPDATE ON mode_policy_versions BEGIN
 SELECT RAISE(ABORT,'Mode policy versions are immutable');
END;
CREATE TRIGGER binding_mode_policy_retained BEFORE DELETE ON mode_policy_versions BEGIN
 SELECT RAISE(ABORT,'Mode policy versions are retained');
END;
CREATE TRIGGER binding_workspace_policy_immutable BEFORE UPDATE ON workspace_policy_versions BEGIN
 SELECT RAISE(ABORT,'Workspace policy versions are immutable');
END;
CREATE TRIGGER binding_workspace_policy_retained BEFORE DELETE ON workspace_policy_versions
 WHEN EXISTS(SELECT 1 FROM workspaces WHERE id=OLD.workspace_id) BEGIN
 SELECT RAISE(ABORT,'Workspace policy versions belong to the workspace');
END;
