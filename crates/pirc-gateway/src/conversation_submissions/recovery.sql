-- Reconciling a first-message dispatch whose outcome is unknown. Once a void is
-- requested here, that command id is never dispatched again: the Node either
-- reports it admitted or refuses it for good. The request is written before it
-- is sent, so a restart between the two resumes with the same void.
-- Idempotent on purpose: databases are upgraded in one transaction and may be
-- re-opened after a partial restore.
-- When the sweep last looked at an operation, so it rotates through all of them.
CREATE TABLE IF NOT EXISTS conversation_submission_reconcile_attempts (
 owner_user TEXT NOT NULL, operation_id TEXT NOT NULL, attempted_at INTEGER NOT NULL,
 PRIMARY KEY(owner_user,operation_id),
 FOREIGN KEY(owner_user,operation_id) REFERENCES conversation_submissions(owner_user,operation_id)
);
CREATE TABLE IF NOT EXISTS conversation_submission_voids (
 owner_user TEXT NOT NULL, operation_id TEXT NOT NULL, command_id TEXT NOT NULL UNIQUE,
 input_hash TEXT NOT NULL,
 requested_at INTEGER NOT NULL, last_attempt_at INTEGER,
 -- NULL until the Node answers: 'voided' (never admitted, never will be) or
 -- 'admission' (it holds an admission or rejection receipt instead).
 result TEXT CHECK(result IN ('voided','admission')),
 answered_at INTEGER,
 PRIMARY KEY(owner_user,operation_id,command_id),
 FOREIGN KEY(owner_user,operation_id) REFERENCES conversation_submissions(owner_user,operation_id),
 CHECK((result IS NULL)=(answered_at IS NULL))
);
-- Only an unadmitted attempt that is not under Stop can be voided.
CREATE TRIGGER IF NOT EXISTS submission_void_needs_unadmitted_attempt BEFORE INSERT ON conversation_submission_voids
WHEN NOT EXISTS(SELECT 1 FROM conversation_submission_dispatches d
  WHERE d.owner_user=NEW.owner_user AND d.operation_id=NEW.operation_id AND d.command_id=NEW.command_id
    AND d.input_hash=NEW.input_hash AND d.admitted_at IS NULL AND d.stop_requested=0
    AND d.state IN ('dispatched','outcome_unknown')) BEGIN
 SELECT RAISE(ABORT,'A void needs an unadmitted first-message attempt');
END;
-- A request keeps its identity and is answered once.
CREATE TRIGGER IF NOT EXISTS submission_void_answered_once BEFORE UPDATE ON conversation_submission_voids
WHEN OLD.result IS NOT NULL OR NEW.owner_user!=OLD.owner_user OR NEW.operation_id!=OLD.operation_id
  OR NEW.command_id!=OLD.command_id OR NEW.input_hash!=OLD.input_hash OR NEW.requested_at!=OLD.requested_at BEGIN
 SELECT RAISE(ABORT,'A first-message void request is answered once');
END;
CREATE TRIGGER IF NOT EXISTS submission_void_retained BEFORE DELETE ON conversation_submission_voids BEGIN
 SELECT RAISE(ABORT,'A first-message void request is retained');
END;
-- Once requested, the command id is never dispatched or recorded again.
CREATE TRIGGER IF NOT EXISTS submission_void_blocks_dispatch BEFORE INSERT ON conversation_submission_dispatches
WHEN EXISTS(SELECT 1 FROM conversation_submission_voids WHERE command_id=NEW.command_id) BEGIN
 SELECT RAISE(ABORT,'command_voided');
END;
CREATE TRIGGER IF NOT EXISTS submission_void_blocks_redispatch BEFORE UPDATE OF command_id,state ON conversation_submission_dispatches
WHEN NEW.state='dispatched' AND (NEW.command_id!=OLD.command_id OR OLD.state!='dispatched')
  AND EXISTS(SELECT 1 FROM conversation_submission_voids WHERE command_id=NEW.command_id) BEGIN
 SELECT RAISE(ABORT,'command_voided');
END;
CREATE TRIGGER IF NOT EXISTS submission_void_blocks_command BEFORE INSERT ON commands
WHEN EXISTS(SELECT 1 FROM conversation_submission_voids WHERE command_id=NEW.id) BEGIN
 SELECT RAISE(ABORT,'command_voided');
END;
