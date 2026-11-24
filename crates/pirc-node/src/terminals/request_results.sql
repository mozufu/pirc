-- A start failure after reservation keeps its error code once, only for its own
-- not-started run. Owner/session pages read requests in creation order.
CREATE TRIGGER terminal_work_monotonic BEFORE UPDATE OF state,error_code ON terminal_work_requests
WHEN NOT (OLD.state='accepted' AND NEW.state='accepted' AND OLD.run_id IS NOT NULL
  AND OLD.error_code IS NULL AND NEW.error_code IS NOT NULL
  AND EXISTS(SELECT 1 FROM terminal_runs r WHERE r.id=OLD.run_id AND r.state='not_started'))
 AND (OLD.state!='accepted' OR NEW.state='accepted' OR (NEW.state='not_started' AND OLD.run_id IS NOT NULL)
  OR OLD.error_code IS NOT NULL) BEGIN
 SELECT RAISE(ABORT,'Work terminal outcome cannot be retried or reset');
END;
CREATE TRIGGER terminal_host_error_once BEFORE UPDATE OF error_code ON terminal_host_requests
WHEN OLD.error_code IS NOT NULL OR NEW.error_code IS NULL OR OLD.run_id IS NULL
 OR NOT EXISTS(SELECT 1 FROM terminal_runs r WHERE r.id=OLD.run_id AND r.state='not_started') BEGIN
 SELECT RAISE(ABORT,'Host terminal start failure is recorded once for its own run');
END;
CREATE INDEX terminal_work_requests_page ON terminal_work_requests(owner_user,session_id,created_at,request_id);
CREATE INDEX terminal_host_requests_page ON terminal_host_requests(owner_user,session_id,created_at,request_id);
