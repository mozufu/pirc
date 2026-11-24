-- A validated first-message intent is accepted atomically with one public session.
-- This is not a Node message-admission or execution receipt.
CREATE TABLE conversation_submission_acceptances (
 owner_user TEXT NOT NULL, operation_id TEXT NOT NULL,
 phase TEXT NOT NULL CHECK(phase IN ('accepted','ready','cancelled')),
 accepted_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
 model_json TEXT CHECK(model_json IS NULL OR json_valid(model_json)), thinking TEXT,
 node_session_id TEXT, upload_ids_json TEXT NOT NULL DEFAULT '[]' CHECK(json_valid(upload_ids_json)),
 last_error_code TEXT,
 PRIMARY KEY(owner_user,operation_id),
 FOREIGN KEY(owner_user,operation_id) REFERENCES conversation_submissions(owner_user,operation_id)
);
-- Gateways may share a Node: uniqueness is already checked by the sessions'
-- (node_id,pi_session_id) identity; only accepted rows retain this private mapping.
CREATE TRIGGER submission_acceptance_cancelled AFTER UPDATE OF state ON conversation_submissions
 WHEN NEW.state='cancelled' BEGIN
 UPDATE conversation_submission_acceptances SET phase='cancelled',model_json=NULL,thinking=NULL,
   upload_ids_json='[]',last_error_code=NULL,updated_at=NEW.updated_at
 WHERE owner_user=NEW.owner_user AND operation_id=NEW.operation_id;
END;

-- Removing Work keeps accepted history and pending input. Unaccepted drafts still
-- cancel, as before. Restoring that workspace may reconcile the same acceptance.
CREATE TRIGGER submission_workspace_removed AFTER INSERT ON workspace_removals
 WHEN NEW.status='removed' BEGIN
 UPDATE conversation_submissions SET state='cancelled',payload_json=NULL,updated_at=NEW.removed_at
 WHERE workspace_id=NEW.workspace_id AND NOT EXISTS(
  SELECT 1 FROM conversation_submission_acceptances a
  WHERE a.owner_user=conversation_submissions.owner_user AND a.operation_id=conversation_submissions.operation_id);
END;
CREATE TRIGGER submission_workspace_removal_completed AFTER UPDATE OF status ON workspace_removals
 WHEN NEW.status='removed' BEGIN
 UPDATE conversation_submissions SET state='cancelled',payload_json=NULL,updated_at=NEW.removed_at
 WHERE workspace_id=NEW.workspace_id AND NOT EXISTS(
  SELECT 1 FROM conversation_submission_acceptances a
  WHERE a.owner_user=conversation_submissions.owner_user AND a.operation_id=conversation_submissions.operation_id);
END;
