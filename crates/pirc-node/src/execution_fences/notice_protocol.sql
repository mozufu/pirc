-- C3: the environment notice is state reconciliation, not a replayed effect.
-- An unconfirmed send is retransmitted with the same notice ID; the agent
-- applies it once. A send interrupted by a restart becomes uncertain again.
CREATE TRIGGER environment_event_once BEFORE UPDATE OF state ON environment_events
WHEN NOT ((OLD.state IN ('pending','uncertain') AND NEW.state='sending')
 OR (OLD.state='sending' AND NEW.state IN ('delivered','uncertain'))) BEGIN
 SELECT RAISE(ABORT,'An environment notice is delivered once; only unconfirmed sends are retransmitted');
END;
