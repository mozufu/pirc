-- Attempt identity and predecessor only; prompt/files stay in their existing stores.
CREATE TABLE creation_admission_attempts (
 owner_user TEXT NOT NULL, operation_id TEXT NOT NULL,
 command_id TEXT NOT NULL UNIQUE, input_hash TEXT NOT NULL,
 previous_command_id TEXT, created_at INTEGER NOT NULL,
 PRIMARY KEY(owner_user,operation_id,command_id),
 FOREIGN KEY(owner_user,operation_id) REFERENCES creation_initial_admissions(owner_user,operation_id),
 CHECK(previous_command_id IS NULL OR previous_command_id!=command_id)
);
