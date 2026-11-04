-- Test fixtures only: restore the earlier immutable terminal outcome rule.
DROP TRIGGER terminal_runs_terminal;
CREATE TRIGGER terminal_runs_terminal BEFORE UPDATE OF state ON terminal_runs
WHEN OLD.state IN ('not_started','settled','unconfirmed') AND NEW.state!=OLD.state BEGIN
 SELECT RAISE(ABORT,'Terminal outcome cannot be replayed');
END;
DROP TRIGGER terminal_owner_identity;
DROP TRIGGER terminal_owner_monotonic;
DROP TRIGGER terminal_owner_retained;
DROP TABLE terminal_io_owners;
