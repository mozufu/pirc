-- Accepted Gateway intent precedes any Node mutation. A coordinated transition
-- ends as installed or released; both are terminal and inactive, so ordinary
-- commands reopen and a later transition may start. Node receipts still decide. No target/preview FK:
-- deleting review data must not release a potentially accepted source fence.
CREATE TABLE conversation_transition_acceptances (
 owner_user TEXT NOT NULL,
 operation_id TEXT NOT NULL,
 session_id TEXT NOT NULL,
 intent_hash TEXT NOT NULL,
 frozen_json TEXT,
 state TEXT NOT NULL CHECK(state IN ('accepted','outcome_unknown','node_fenced','installed','released','deleted')),
 created_at INTEGER NOT NULL,
 CHECK((state='deleted' AND frozen_json IS NULL) OR (state!='deleted' AND frozen_json IS NOT NULL)),
 PRIMARY KEY(owner_user,operation_id)
);
CREATE UNIQUE INDEX conversation_transition_acceptance_active ON conversation_transition_acceptances(session_id) WHERE state NOT IN ('deleted','installed','released');
CREATE TRIGGER conversation_transition_acceptance_immutable BEFORE UPDATE OF owner_user,operation_id,session_id,intent_hash,created_at ON conversation_transition_acceptances BEGIN
 SELECT RAISE(ABORT,'Accepted transition identities are immutable');
END;
CREATE TRIGGER conversation_transition_acceptance_retained BEFORE DELETE ON conversation_transition_acceptances BEGIN
 SELECT RAISE(ABORT,'Accepted transition identities are retained');
END;
