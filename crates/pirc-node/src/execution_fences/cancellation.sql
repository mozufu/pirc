-- C3: a durable cancellation request on the fence itself. Release, drain and
-- installation serialize on this row; a request never clears and blocks install.
ALTER TABLE execution_fences ADD COLUMN cancel_requested_at INTEGER;
ALTER TABLE execution_fences ADD COLUMN cancel_reason TEXT;
CREATE TRIGGER execution_fence_cancel_once BEFORE UPDATE OF cancel_requested_at ON execution_fences
WHEN OLD.cancel_requested_at IS NOT NULL OR NEW.cancel_requested_at IS NULL OR OLD.state IN ('installed','deleted') BEGIN
 SELECT RAISE(ABORT,'A cancellation request is recorded once and never after installation');
END;
CREATE TRIGGER execution_fence_cancel_blocks_install BEFORE UPDATE OF state ON execution_fences
WHEN NEW.state='installed' AND OLD.cancel_requested_at IS NOT NULL BEGIN
 SELECT RAISE(ABORT,'A cancelled transition cannot install');
END;
