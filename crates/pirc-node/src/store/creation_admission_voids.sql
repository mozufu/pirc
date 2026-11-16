-- A first-message command identity the Gateway asked the Node to refuse, because
-- it could not tell whether that request would ever arrive. Each command id is
-- decided exactly once on this Node: admitted (creation_admission_attempts and
-- commands), rejected (a commands row), or voided (this table). The triggers make
-- the three mutually exclusive in the database itself, not only in the handlers.
-- Bound to the owner, the creation operation and the exact input hash. No prompt
-- text or credentials are stored here, and a void is never updated or removed.
CREATE TABLE creation_admission_voids (
 owner_user TEXT NOT NULL, operation_id TEXT NOT NULL,
 command_id TEXT NOT NULL UNIQUE,
 session_id TEXT NOT NULL, input_hash TEXT NOT NULL,
 created_at INTEGER NOT NULL,
 PRIMARY KEY(owner_user,operation_id,command_id),
 FOREIGN KEY(owner_user,operation_id) REFERENCES session_creations(owner_user,operation_id)
);
CREATE TRIGGER creation_admission_void_immutable BEFORE UPDATE ON creation_admission_voids BEGIN
 SELECT RAISE(ABORT,'A first-message void is immutable');
END;
CREATE TRIGGER creation_admission_void_retained BEFORE DELETE ON creation_admission_voids BEGIN
 SELECT RAISE(ABORT,'A first-message void is retained');
END;
CREATE TRIGGER creation_admission_void_not_admitted BEFORE INSERT ON creation_admission_voids
WHEN EXISTS(SELECT 1 FROM commands WHERE id=NEW.command_id)
  OR EXISTS(SELECT 1 FROM creation_admission_attempts WHERE command_id=NEW.command_id)
  OR EXISTS(SELECT 1 FROM creation_initial_admissions WHERE command_id=NEW.command_id) BEGIN
 SELECT RAISE(ABORT,'An admitted command cannot be voided');
END;
CREATE TRIGGER creation_admission_void_blocks_command BEFORE INSERT ON commands
WHEN EXISTS(SELECT 1 FROM creation_admission_voids WHERE command_id=NEW.id) BEGIN
 SELECT RAISE(ABORT,'command_voided');
END;
CREATE TRIGGER creation_admission_void_blocks_attempt BEFORE INSERT ON creation_admission_attempts
WHEN EXISTS(SELECT 1 FROM creation_admission_voids WHERE command_id=NEW.command_id) BEGIN
 SELECT RAISE(ABORT,'command_voided');
END;
CREATE TRIGGER creation_admission_void_blocks_initial_insert BEFORE INSERT ON creation_initial_admissions
WHEN NEW.command_id IS NOT NULL AND EXISTS(SELECT 1 FROM creation_admission_voids WHERE command_id=NEW.command_id) BEGIN
 SELECT RAISE(ABORT,'command_voided');
END;
CREATE TRIGGER creation_admission_void_blocks_initial_update BEFORE UPDATE OF command_id ON creation_initial_admissions
WHEN NEW.command_id IS NOT NULL AND EXISTS(SELECT 1 FROM creation_admission_voids WHERE command_id=NEW.command_id) BEGIN
 SELECT RAISE(ABORT,'command_voided');
END;
