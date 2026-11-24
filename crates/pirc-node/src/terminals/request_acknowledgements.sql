CREATE TRIGGER terminal_work_acknowledged_once BEFORE UPDATE OF acknowledged_at,acknowledged_by ON terminal_work_requests
WHEN OLD.acknowledged_at IS NOT NULL OR NEW.acknowledged_at IS NULL OR NEW.acknowledged_by IS NULL
 OR OLD.state='not_started'
 OR (OLD.run_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM terminal_runs r WHERE r.id=OLD.run_id AND r.state IN ('launching','running'))) BEGIN
 SELECT RAISE(ABORT,'Only an unconfirmed work terminal start can be acknowledged, once');
END;
CREATE TRIGGER terminal_host_acknowledged_once BEFORE UPDATE OF acknowledged_at,acknowledged_by ON terminal_host_requests
WHEN OLD.acknowledged_at IS NOT NULL OR NEW.acknowledged_at IS NULL OR NEW.acknowledged_by IS NULL
 OR NOT EXISTS(SELECT 1 FROM terminal_runs r WHERE r.id=OLD.run_id AND r.state IN ('launching','running')) BEGIN
 SELECT RAISE(ABORT,'Only an unconfirmed host terminal start can be acknowledged, once');
END;
