-- One agent per runner epoch, but multiple independently identified work terminals.
-- Rebuild to remove the old table-level UNIQUE(session_id,runner_epoch).
DROP TRIGGER sandbox_launch_identity;
DROP TRIGGER sandbox_kernel_identity;
DROP TRIGGER sandbox_launch_terminal;
DROP TRIGGER sandbox_launch_retained;
DROP TRIGGER sandbox_guard_monotonic;
DROP INDEX sandbox_launches_pending;
DROP INDEX sandbox_guard_pending;
DROP INDEX IF EXISTS sandbox_agent_epoch;
ALTER TABLE sandbox_launches RENAME TO sandbox_launches_before_resources;
CREATE TABLE sandbox_launches (
 launch_id TEXT PRIMARY KEY,
 session_id TEXT NOT NULL,
 workspace_id TEXT NOT NULL,
 runner_epoch INTEGER NOT NULL,
 incarnation TEXT NOT NULL,
 state TEXT NOT NULL CHECK(state IN ('launching','running','unconfirmed','terminated','not_started','legacy_untracked')),
 identity_json TEXT CHECK(identity_json IS NULL OR json_valid(identity_json)),
 created_at INTEGER NOT NULL,
 updated_at INTEGER NOT NULL,
 guard_state TEXT NOT NULL DEFAULT 'untracked' CHECK(guard_state IN ('untracked','waiting','released','denied')),
 resource_kind TEXT NOT NULL CHECK(resource_kind IN ('agent','terminal')),
 CHECK(state!='terminated' OR identity_json IS NOT NULL),
 CHECK(state!='not_started' OR identity_json IS NULL)
);
INSERT INTO sandbox_launches
 SELECT l.launch_id,l.session_id,l.workspace_id,l.runner_epoch,l.incarnation,
 l.state,l.identity_json,l.created_at,l.updated_at,l.guard_state,
 CASE WHEN EXISTS(SELECT 1 FROM terminal_runs t WHERE t.id=l.launch_id
  AND t.session_id=l.session_id AND t.workspace_id=l.workspace_id
  AND t.incarnation=l.incarnation) THEN 'terminal' ELSE 'agent' END
 FROM sandbox_launches_before_resources l;
DROP TABLE sandbox_launches_before_resources;
CREATE UNIQUE INDEX sandbox_agent_epoch ON sandbox_launches(session_id,runner_epoch)
 WHERE resource_kind='agent';
CREATE INDEX sandbox_launches_pending ON sandbox_launches(session_id,updated_at)
 WHERE state IN ('running','unconfirmed','launching') AND identity_json IS NOT NULL;
CREATE INDEX sandbox_guard_pending ON sandbox_launches(session_id,created_at) WHERE guard_state='waiting';
CREATE TRIGGER sandbox_launch_identity BEFORE UPDATE OF launch_id,session_id,workspace_id,runner_epoch,incarnation,created_at,resource_kind ON sandbox_launches BEGIN
 SELECT RAISE(ABORT,'Sandbox launch identity is immutable');
END;
CREATE TRIGGER sandbox_kernel_identity BEFORE UPDATE OF identity_json ON sandbox_launches
WHEN OLD.identity_json IS NOT NULL AND NEW.identity_json IS NOT OLD.identity_json BEGIN
 SELECT RAISE(ABORT,'Sandbox kernel identity is immutable');
END;
CREATE TRIGGER sandbox_launch_terminal BEFORE UPDATE OF state ON sandbox_launches
WHEN OLD.state IN ('terminated','not_started','legacy_untracked') AND NEW.state!=OLD.state BEGIN
 SELECT RAISE(ABORT,'Sandbox launch terminal evidence is immutable');
END;
CREATE TRIGGER sandbox_launch_retained BEFORE DELETE ON sandbox_launches BEGIN
 SELECT RAISE(ABORT,'Sandbox launch evidence is retained');
END;
CREATE TRIGGER sandbox_guard_monotonic BEFORE UPDATE OF guard_state ON sandbox_launches
WHEN NEW.guard_state!=OLD.guard_state AND NOT (OLD.guard_state='waiting' AND NEW.guard_state IN ('released','denied')) BEGIN
 SELECT RAISE(ABORT,'Sandbox launch guard cannot be reset');
END;
