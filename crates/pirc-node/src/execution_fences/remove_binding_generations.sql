-- Test fixtures only: remove the 2031 binding generation layer first.
DROP TRIGGER session_binding_generation_deleted;
DROP TRIGGER session_binding_generation_retained;
DROP TRIGGER session_binding_generation_identity;
DROP TRIGGER session_binding_generation_new;
DROP TABLE session_binding_generations;
