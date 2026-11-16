-- Cancelling an environment switch whose Node outcome is unknown. The Gateway
-- wrote `outcome_unknown` before the one request that creates the Node's fence,
-- so a lost request leaves the conversation blocked. Only a Node VOID receipt
-- proves that the fence was never created and never will be (a 404 or a refusal
-- proves nothing: a delayed request may still arrive). A row here is the durable
-- "void requested" marker, written together with the cancellation intent while
-- the outcome is unknown; once it exists the original create request is never
-- sent again (the state cannot return to `accepted`, and dispatch is a
-- conditional update on `accepted`). The same row records the Node's receipt.
-- Idempotent on purpose: databases are upgraded in one transaction and may be
-- re-opened after a partial restore.
CREATE TABLE IF NOT EXISTS conversation_transition_voids (
 owner_user TEXT NOT NULL, operation_id TEXT NOT NULL, session_id TEXT NOT NULL,
 node_id TEXT NOT NULL, plan_hash TEXT NOT NULL,
 requested_at INTEGER NOT NULL, last_attempt_at INTEGER,
 -- NULL until the Node answers: 'voided' (never created, never will be). When the
 -- Node holds the fence instead, nothing is recorded here: the fence is adopted.
 result TEXT CHECK(result IN ('voided')),
 answer_json TEXT CHECK(answer_json IS NULL OR json_valid(answer_json)),
 answered_at INTEGER,
 PRIMARY KEY(owner_user,operation_id),
 FOREIGN KEY(owner_user,operation_id) REFERENCES conversation_transition_acceptances(owner_user,operation_id),
 CHECK((result IS NULL)=(answered_at IS NULL) AND (result IS NULL)=(answer_json IS NULL))
);
-- Only an acceptance whose outcome is unknown, with a recorded cancellation
-- intent, can be marked for void. Nothing else is ever voided.
CREATE TRIGGER IF NOT EXISTS conversation_transition_void_needs_unknown_outcome BEFORE INSERT ON conversation_transition_voids
WHEN NOT EXISTS(SELECT 1 FROM conversation_transition_acceptances a
  WHERE a.owner_user=NEW.owner_user AND a.operation_id=NEW.operation_id AND a.session_id=NEW.session_id AND a.state='outcome_unknown')
  OR NOT EXISTS(SELECT 1 FROM conversation_transition_cancellations c
  WHERE c.owner_user=NEW.owner_user AND c.operation_id=NEW.operation_id AND c.session_id=NEW.session_id) BEGIN
 SELECT RAISE(ABORT,'A void needs an unknown outcome and a recorded cancellation');
END;
-- A request keeps its identity and is answered once, while the outcome is unknown.
CREATE TRIGGER IF NOT EXISTS conversation_transition_void_answered_once BEFORE UPDATE ON conversation_transition_voids
WHEN OLD.result IS NOT NULL OR NEW.owner_user!=OLD.owner_user OR NEW.operation_id!=OLD.operation_id
  OR NEW.session_id!=OLD.session_id OR NEW.node_id!=OLD.node_id OR NEW.plan_hash!=OLD.plan_hash
  OR NEW.requested_at!=OLD.requested_at
  OR (NEW.result IS NOT NULL AND NOT EXISTS(SELECT 1 FROM conversation_transition_acceptances a
    WHERE a.owner_user=OLD.owner_user AND a.operation_id=OLD.operation_id AND a.state='outcome_unknown')) BEGIN
 SELECT RAISE(ABORT,'A transition void request is answered once');
END;
CREATE TRIGGER IF NOT EXISTS conversation_transition_void_retained BEFORE DELETE ON conversation_transition_voids BEGIN
 SELECT RAISE(ABORT,'A transition void request is retained');
END;
-- The new ending: `outcome_unknown` becomes `released` only when the Node's void
-- receipt is in the database. Every other transition is as before.
DROP TRIGGER IF EXISTS conversation_transition_acceptance_progress;
CREATE TRIGGER conversation_transition_acceptance_progress BEFORE UPDATE ON conversation_transition_acceptances WHEN
 (NEW.frozen_json IS NOT OLD.frozen_json AND NOT(NEW.state='deleted' AND NEW.frozen_json IS NULL AND NOT EXISTS(SELECT 1 FROM sessions WHERE id=OLD.session_id))) OR
 NOT(NEW.state=OLD.state OR (OLD.state='accepted' AND NEW.state='outcome_unknown') OR (OLD.state IN ('accepted','outcome_unknown') AND NEW.state='node_fenced')
  OR (OLD.state='node_fenced' AND NEW.state IN ('installed','released')) OR (OLD.state='accepted' AND NEW.state='released')
  OR (OLD.state='outcome_unknown' AND NEW.state='released' AND EXISTS(SELECT 1 FROM conversation_transition_voids v
      WHERE v.owner_user=OLD.owner_user AND v.operation_id=OLD.operation_id AND v.session_id=OLD.session_id AND v.result='voided'))
  OR (NEW.state='deleted' AND NOT EXISTS(SELECT 1 FROM sessions WHERE id=OLD.session_id))) BEGIN
 SELECT RAISE(ABORT,'Accepted transitions cannot reopen or change intent');
END;
-- Once the Node has voided the operation, no fence for it can be adopted.
CREATE TRIGGER IF NOT EXISTS conversation_transition_void_blocks_fenced BEFORE UPDATE OF state ON conversation_transition_acceptances
WHEN NEW.state='node_fenced' AND EXISTS(SELECT 1 FROM conversation_transition_voids v
  WHERE v.owner_user=OLD.owner_user AND v.operation_id=OLD.operation_id AND v.result='voided') BEGIN
 SELECT RAISE(ABORT,'A voided transition has no Node fence');
END;
CREATE TRIGGER IF NOT EXISTS conversation_transition_void_blocks_fence_receipt BEFORE INSERT ON conversation_node_fences
WHEN EXISTS(SELECT 1 FROM conversation_transition_voids v
  WHERE v.owner_user=NEW.owner_user AND v.operation_id=NEW.operation_id AND v.result='voided') BEGIN
 SELECT RAISE(ABORT,'A voided transition has no Node fence');
END;
