-- Metadata only; capture before the first guarded terminal spawn. No old owner
-- is inferred from an incarnation UUID, an empty registry or an exited shell.
CREATE TABLE terminal_io_owners (
 incarnation TEXT PRIMARY KEY,
 identity_json TEXT NOT NULL CHECK(json_valid(identity_json)),
 state TEXT NOT NULL CHECK(state IN ('captured','gone')),
 created_at INTEGER NOT NULL,
 updated_at INTEGER NOT NULL
);
CREATE TRIGGER terminal_owner_identity BEFORE UPDATE OF incarnation,identity_json,created_at ON terminal_io_owners BEGIN
 SELECT RAISE(ABORT,'Terminal I/O owner identity is immutable');
END;
CREATE TRIGGER terminal_owner_monotonic BEFORE UPDATE OF state ON terminal_io_owners
WHEN NEW.state!=OLD.state AND NOT (OLD.state='captured' AND NEW.state='gone') BEGIN
 SELECT RAISE(ABORT,'Terminal I/O owner cannot be revived');
END;
CREATE TRIGGER terminal_owner_retained BEFORE DELETE ON terminal_io_owners BEGIN
 SELECT RAISE(ABORT,'Terminal I/O ownership evidence is retained');
END;
DROP TRIGGER terminal_runs_terminal;
CREATE TRIGGER terminal_runs_terminal BEFORE UPDATE OF state ON terminal_runs
WHEN OLD.state IN ('not_started','settled','unconfirmed') AND NEW.state!=OLD.state
 AND NOT (OLD.state='unconfirmed' AND NEW.state='settled' AND EXISTS(
 SELECT 1 FROM sandbox_launches l JOIN terminal_io_owners o ON o.incarnation=OLD.incarnation
 WHERE l.launch_id=OLD.id AND l.session_id=OLD.session_id AND l.workspace_id=OLD.workspace_id
 AND l.incarnation=OLD.incarnation AND l.resource_kind='terminal' AND l.state='terminated'
 AND l.identity_json IS NOT NULL AND o.state='gone'
 AND json_extract(l.identity_json,'$.bootId')=json_extract(o.identity_json,'$.bootId')
 AND json_extract(l.identity_json,'$.observerNamespace')=json_extract(o.identity_json,'$.observerNamespace')
 )) BEGIN
 SELECT RAISE(ABORT,'Terminal outcome requires confirmed closure evidence');
END;
