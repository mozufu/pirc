-- One durable identity per actual spawn attempt, retained across deletion. An
-- absent supervisor is never proof of termination of this launch's descendants.
-- One agent per runner epoch, but multiple independently identified work terminals.
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
 -- C2: every new launch or effect records the binding generation it ran under,
 -- in its own insert, before spawn. NULL means unattributed evidence; it is
 -- never assigned afterwards by time or workspace.
 binding_generation INTEGER,
 CHECK(state!='terminated' OR identity_json IS NOT NULL),
 CHECK(state!='not_started' OR identity_json IS NULL)
);
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
