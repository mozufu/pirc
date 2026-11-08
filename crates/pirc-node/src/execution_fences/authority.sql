-- Backend permission to advance exactly one accepted transition (C1), separate
-- from any device's interactive control lease and from execution grants. The
-- Node stores only a token hash; a later revision supersedes earlier ones.
CREATE TABLE operation_authorities (
 owner_user TEXT NOT NULL,
 operation_id TEXT NOT NULL,
 revision INTEGER NOT NULL CHECK(revision>=1),
 token_hash TEXT NOT NULL CHECK(length(token_hash)=64),
 deadline_at INTEGER NOT NULL,
 issued_at INTEGER NOT NULL,
 revoked_at INTEGER,
 PRIMARY KEY(owner_user,operation_id,revision),
 CHECK(deadline_at>issued_at)
);
CREATE TRIGGER operation_authority_immutable BEFORE UPDATE ON operation_authorities
WHEN NEW.owner_user IS NOT OLD.owner_user OR NEW.operation_id IS NOT OLD.operation_id OR NEW.revision IS NOT OLD.revision
 OR NEW.token_hash IS NOT OLD.token_hash OR NEW.deadline_at IS NOT OLD.deadline_at OR NEW.issued_at IS NOT OLD.issued_at
 OR OLD.revoked_at IS NOT NULL OR NEW.revoked_at IS NULL BEGIN
 SELECT RAISE(ABORT,'Operation authority is immutable except for one revocation');
END;
CREATE TRIGGER operation_authority_retained BEFORE DELETE ON operation_authorities BEGIN
 SELECT RAISE(ABORT,'Operation authority history is retained');
END;
-- The latest wall-clock time any authority check observed. A clock that moves
-- back behind it cannot extend permission; checks wait for reauthorization.
CREATE TABLE operation_authority_clock (
 id INTEGER PRIMARY KEY CHECK(id=1),
 max_seen_at INTEGER NOT NULL
);
