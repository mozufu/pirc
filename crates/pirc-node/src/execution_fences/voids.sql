-- An environment-transition operation identity the Gateway asked the Node to
-- refuse for good, because it could not tell whether the one request that
-- creates the fence would ever arrive. Each operation is decided exactly once on
-- this Node: a fence exists (execution_fences) or it is voided (this table). The
-- triggers make the two mutually exclusive in the database itself, not only in
-- the handlers. Bound to the owner, the session and the plan hash of the frozen
-- intent. Nothing private is stored, and a void is never updated or removed.
CREATE TABLE execution_fence_voids (
 owner_user TEXT NOT NULL,
 operation_id TEXT NOT NULL,
 session_id TEXT NOT NULL,
 plan_hash TEXT NOT NULL,
 created_at INTEGER NOT NULL,
 PRIMARY KEY(owner_user,operation_id)
);
CREATE TRIGGER execution_fence_void_immutable BEFORE UPDATE ON execution_fence_voids BEGIN
 SELECT RAISE(ABORT,'A transition void is immutable');
END;
CREATE TRIGGER execution_fence_void_retained BEFORE DELETE ON execution_fence_voids BEGIN
 SELECT RAISE(ABORT,'A transition void is retained as long as fence receipts are');
END;
CREATE TRIGGER execution_fence_void_not_created BEFORE INSERT ON execution_fence_voids
WHEN EXISTS(SELECT 1 FROM execution_fences WHERE owner_user=NEW.owner_user AND operation_id=NEW.operation_id) BEGIN
 SELECT RAISE(ABORT,'A created fence cannot be voided');
END;
CREATE TRIGGER execution_fence_blocked_by_void BEFORE INSERT ON execution_fences
WHEN EXISTS(SELECT 1 FROM execution_fence_voids WHERE owner_user=NEW.owner_user AND operation_id=NEW.operation_id) BEGIN
 SELECT RAISE(ABORT,'operation_voided');
END;
