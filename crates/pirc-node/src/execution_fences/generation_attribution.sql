CREATE TRIGGER sandbox_launch_generation AFTER INSERT ON sandbox_launches WHEN NEW.binding_generation IS NULL BEGIN
 UPDATE sandbox_launches SET binding_generation=(SELECT max(generation) FROM session_binding_generations WHERE session_id=NEW.session_id) WHERE launch_id=NEW.launch_id;
END;
CREATE TRIGGER host_command_generation AFTER INSERT ON host_command_runs WHEN NEW.binding_generation IS NULL BEGIN
 UPDATE host_command_runs SET binding_generation=(SELECT max(generation) FROM session_binding_generations WHERE session_id=NEW.session_id) WHERE id=NEW.id;
END;
CREATE TRIGGER terminal_run_generation AFTER INSERT ON terminal_runs WHEN NEW.binding_generation IS NULL BEGIN
 UPDATE terminal_runs SET binding_generation=(SELECT max(generation) FROM session_binding_generations WHERE session_id=NEW.session_id) WHERE id=NEW.id;
END;
CREATE TRIGGER browser_group_generation AFTER INSERT ON browser_groups WHEN NEW.binding_generation IS NULL BEGIN
 UPDATE browser_groups SET binding_generation=(SELECT max(generation) FROM session_binding_generations WHERE session_id=NEW.session_id) WHERE id=NEW.id;
END;
CREATE TRIGGER sandbox_launch_generation_fixed BEFORE UPDATE OF binding_generation ON sandbox_launches WHEN OLD.binding_generation IS NOT NULL BEGIN
 SELECT RAISE(ABORT,'A launch generation is immutable');
END;
CREATE TRIGGER host_command_generation_fixed BEFORE UPDATE OF binding_generation ON host_command_runs WHEN OLD.binding_generation IS NOT NULL BEGIN
 SELECT RAISE(ABORT,'A host command generation is immutable');
END;
CREATE TRIGGER terminal_run_generation_fixed BEFORE UPDATE OF binding_generation ON terminal_runs WHEN OLD.binding_generation IS NOT NULL BEGIN
 SELECT RAISE(ABORT,'A terminal generation is immutable');
END;
CREATE TRIGGER browser_group_generation_fixed BEFORE UPDATE OF binding_generation ON browser_groups WHEN OLD.binding_generation IS NOT NULL BEGIN
 SELECT RAISE(ABORT,'A browser group generation is immutable');
END;
