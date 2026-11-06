-- Test fixtures only: remove the newest request layer before older schemas.
DROP TRIGGER terminal_work_identity;
DROP TRIGGER terminal_work_once;
DROP TRIGGER terminal_work_monotonic;
DROP TRIGGER terminal_work_retained;
DROP TABLE terminal_work_requests;
-- Test fixtures only, before removing earlier terminal schemas.
DROP TRIGGER terminal_host_identity;
DROP TRIGGER terminal_host_once;
DROP TRIGGER terminal_host_retained;
DROP TABLE terminal_host_requests;
