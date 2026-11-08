-- C2: an immutable snapshot of each distinct revocation evaluation of a
-- transition. Reviews page this exact set; a changed set is a new evaluation.
CREATE TABLE revocation_evaluations (
 owner_user TEXT NOT NULL,
 operation_id TEXT NOT NULL,
 evaluation_id TEXT NOT NULL,
 digest TEXT NOT NULL CHECK(length(digest)=64),
 status TEXT NOT NULL,
 items_total INTEGER NOT NULL CHECK(items_total>=0),
 items_json TEXT NOT NULL CHECK(json_valid(items_json)),
 created_at INTEGER NOT NULL,
 PRIMARY KEY(owner_user,operation_id,evaluation_id),
 UNIQUE(owner_user,operation_id,digest)
);
CREATE TRIGGER revocation_evaluation_immutable BEFORE UPDATE ON revocation_evaluations BEGIN
 SELECT RAISE(ABORT,'Revocation evaluations are immutable');
END;
CREATE TRIGGER revocation_evaluation_retained BEFORE DELETE ON revocation_evaluations BEGIN
 SELECT RAISE(ABORT,'Revocation evaluations are retained');
END;
