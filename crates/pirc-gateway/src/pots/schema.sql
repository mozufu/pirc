-- Multiple named pots (plans/pots.md). Every limit is a column with a finite
-- default: a missing value never means unlimited.
CREATE TABLE pots (
 id TEXT PRIMARY KEY,
 owner_user TEXT NOT NULL,
 name TEXT NOT NULL CHECK(length(name) BETWEEN 1 AND 40),
 avatar_color INTEGER NOT NULL DEFAULT 1 CHECK(avatar_color BETWEEN 1 AND 5),
 avatar_upload TEXT,
 -- The soul: how it speaks and behaves. Grants nothing.
 personality TEXT NOT NULL DEFAULT '' CHECK(length(personality)<=8000),
 intro TEXT NOT NULL DEFAULT '' CHECK(length(intro)<=200),
 work_description TEXT NOT NULL DEFAULT '' CHECK(length(work_description)<=8000),
 state TEXT NOT NULL DEFAULT 'active' CHECK(state IN ('active','paused','archived')),
 revision INTEGER NOT NULL DEFAULT 1 CHECK(revision>0),
 created_at INTEGER NOT NULL,
 updated_at INTEGER NOT NULL,
 UNIQUE(id, owner_user)
);
CREATE INDEX pots_owner ON pots(owner_user, state);
CREATE TABLE pot_responsibilities (
 id TEXT PRIMARY KEY,
 pot_id TEXT NOT NULL REFERENCES pots(id) ON DELETE CASCADE,
 title TEXT NOT NULL CHECK(length(title) BETWEEN 1 AND 200),
 detail TEXT NOT NULL DEFAULT '' CHECK(length(detail)<=2000),
 position INTEGER NOT NULL
);
CREATE INDEX pot_responsibilities_pot ON pot_responsibilities(pot_id, position);
CREATE TABLE pot_permissions (
 pot_id TEXT PRIMARY KEY REFERENCES pots(id) ON DELETE CASCADE,
 reach TEXT NOT NULL DEFAULT 'answer' CHECK(reach IN ('answer','observe','work')),
 dm_send TEXT NOT NULL DEFAULT 'all' CHECK(dm_send IN ('all','selected','off')),
 dm_receive TEXT NOT NULL DEFAULT 'all' CHECK(dm_receive IN ('all','selected','off')),
 max_concurrent_works INTEGER NOT NULL DEFAULT 1 CHECK(max_concurrent_works BETWEEN 0 AND 16),
 -- Either may be off (NULL), never both (the service enforces it).
 budget_money_month_micros INTEGER CHECK(budget_money_month_micros IS NULL OR budget_money_month_micros>=0),
 budget_tokens_day INTEGER CHECK(budget_tokens_day IS NULL OR budget_tokens_day>=0)
);
CREATE TABLE pot_observe_scopes (
 pot_id TEXT NOT NULL REFERENCES pots(id) ON DELETE CASCADE,
 kind TEXT NOT NULL CHECK(kind IN ('project','workspace','session','calendar','schedules')),
 ref TEXT NOT NULL DEFAULT '',
 lead INTEGER NOT NULL DEFAULT 0 CHECK(lead IN (0,1)),
 PRIMARY KEY(pot_id, kind, ref)
);
CREATE TABLE pot_dm_peers (
 pot_id TEXT NOT NULL REFERENCES pots(id) ON DELETE CASCADE,
 peer_pot_id TEXT NOT NULL,
 direction TEXT NOT NULL CHECK(direction IN ('send','receive')),
 PRIMARY KEY(pot_id, peer_pot_id, direction),
 CHECK(peer_pot_id!=pot_id)
);
CREATE TABLE pot_work_locations (
 pot_id TEXT NOT NULL REFERENCES pots(id) ON DELETE CASCADE,
 -- A project or a directory workspace the owner holds.
 workspace_id TEXT NOT NULL,
 access TEXT NOT NULL DEFAULT 'write' CHECK(access IN ('read','write')),
 PRIMARY KEY(pot_id, workspace_id)
);
-- Position 0 is the main model, 1... the fallbacks in order.
CREATE TABLE pot_models (
 pot_id TEXT NOT NULL REFERENCES pots(id) ON DELETE CASCADE,
 position INTEGER NOT NULL CHECK(position BETWEEN 0 AND 19),
 provider TEXT NOT NULL,
 model TEXT NOT NULL,
 PRIMARY KEY(pot_id, position)
);
CREATE TABLE pot_work_models (
 pot_id TEXT NOT NULL REFERENCES pots(id) ON DELETE CASCADE,
 provider TEXT NOT NULL,
 model TEXT NOT NULL,
 mode TEXT NOT NULL CHECK(mode IN ('direct','ask')),
 PRIMARY KEY(pot_id, provider, model)
);
CREATE TABLE pot_runtime (
 pot_id TEXT PRIMARY KEY REFERENCES pots(id) ON DELETE CASCADE,
 thinking TEXT NOT NULL DEFAULT 'medium' CHECK(thinking IN ('off','minimal','low','medium','high','xhigh')),
 thinking_auto INTEGER NOT NULL DEFAULT 0 CHECK(thinking_auto IN (0,1)),
 -- Its persistent session on the chat node, once allocated.
 session_id TEXT UNIQUE,
 -- NULL turns autonomy reviews off; 172800 s is the 2-day default.
 autonomy_interval_s INTEGER DEFAULT 172800 CHECK(autonomy_interval_s IS NULL OR autonomy_interval_s BETWEEN 3600 AND 31536000),
 next_review_at INTEGER,
 last_engaged_at INTEGER,
 active_fallback INTEGER NOT NULL DEFAULT 0
);
-- Owner-wide pot limits and policies (one row per owner).
CREATE TABLE pot_settings (
 owner_user TEXT PRIMARY KEY,
 cap_money_month_micros INTEGER NOT NULL DEFAULT 0 CHECK(cap_money_month_micros>=0),
 cap_tokens_day INTEGER NOT NULL DEFAULT 0 CHECK(cap_tokens_day>=0),
 on_exhausted TEXT NOT NULL DEFAULT 'ask' CHECK(on_exhausted IN ('pause_all','ask')),
 activity_retention_days INTEGER NOT NULL DEFAULT 90 CHECK(activity_retention_days BETWEEN 1 AND 3650),
 -- Count subscription usage at API-equivalent prices in money caps (P20).
 count_subscription_money INTEGER NOT NULL DEFAULT 0 CHECK(count_subscription_money IN (0,1)),
 loop_depth INTEGER NOT NULL DEFAULT 4 CHECK(loop_depth BETWEEN 1 AND 16),
 loop_fanout INTEGER NOT NULL DEFAULT 4 CHECK(loop_fanout BETWEEN 1 AND 16),
 loop_no_progress_wakes INTEGER NOT NULL DEFAULT 12 CHECK(loop_no_progress_wakes BETWEEN 2 AND 1000),
 loop_no_progress_messages INTEGER NOT NULL DEFAULT 30 CHECK(loop_no_progress_messages BETWEEN 2 AND 10000),
 -- Rate ceilings: delivery waits while a pair or root is over them.
 loop_pair_messages_minute INTEGER NOT NULL DEFAULT 12 CHECK(loop_pair_messages_minute BETWEEN 1 AND 1000),
 loop_pair_messages_hour INTEGER NOT NULL DEFAULT 120 CHECK(loop_pair_messages_hour BETWEEN 1 AND 100000),
 loop_root_wakes_minute INTEGER NOT NULL DEFAULT 20 CHECK(loop_root_wakes_minute BETWEEN 1 AND 1000),
 handback_cooldown_s INTEGER NOT NULL DEFAULT 3600 CHECK(handback_cooldown_s BETWEEN 0 AND 604800),
 revision INTEGER NOT NULL DEFAULT 1
);
-- Messages and events waiting for a pot, delivered into its session one at a
-- time (plans/pots.md, Runtime). At most one wake per pot is in flight.
CREATE TABLE pot_wakes (
 id TEXT PRIMARY KEY,
 pot_id TEXT NOT NULL REFERENCES pots(id) ON DELETE CASCADE,
 owner_user TEXT NOT NULL,
 source TEXT NOT NULL CHECK(source IN ('user','group','dm','event','approval','handover','reminder','review','budget')),
 thread_id TEXT,
 causal_root TEXT,
 -- The root's first wake is depth 0; each pot message or work start adds one.
 depth INTEGER NOT NULL DEFAULT 0 CHECK(depth>=0),
 -- The pot whose message caused this wake, and that wake's id (fan-out).
 from_pot TEXT,
 caused_by TEXT,
 -- Structured purpose (target, action, source) for repeated-purpose detection.
 purpose_json TEXT NOT NULL DEFAULT '{}' CHECK(json_valid(purpose_json)),
 content TEXT NOT NULL CHECK(length(content) BETWEEN 1 AND 100000),
 details_json TEXT NOT NULL DEFAULT '{}' CHECK(json_valid(details_json)),
 state TEXT NOT NULL DEFAULT 'queued' CHECK(state IN ('queued','delivering','delivered','settled','failed')),
 attempts INTEGER NOT NULL DEFAULT 0,
 delivered_at INTEGER,
 settled_at INTEGER,
 reply TEXT,
 error TEXT,
 created_at INTEGER NOT NULL
);
CREATE INDEX pot_wakes_pending ON pot_wakes(pot_id, state, created_at);
CREATE UNIQUE INDEX pot_wakes_in_flight ON pot_wakes(pot_id) WHERE state IN ('delivering','delivered');
-- Conversations with and between pots (plans/pots.md, Threads and messaging).
-- The user can read every thread; authors are set by the Gateway.
CREATE TABLE threads (
 id TEXT PRIMARY KEY,
 owner_user TEXT NOT NULL,
 kind TEXT NOT NULL CHECK(kind IN ('direct','group','pot_dm')),
 name TEXT NOT NULL DEFAULT '' CHECK(length(name)<=60),
 avatar_color INTEGER CHECK(avatar_color IS NULL OR avatar_color BETWEEN 1 AND 5),
 host_pot_id TEXT REFERENCES pots(id) ON DELETE SET NULL,
 project_id TEXT,
 -- The direct thread's pot, or a pot DM's two pots in order. Cleared when a
 -- pot is deleted: the thread stays, named, until the retention removes it.
 pot_a TEXT REFERENCES pots(id) ON DELETE SET NULL,
 pot_b TEXT REFERENCES pots(id) ON DELETE SET NULL,
 last_seq INTEGER NOT NULL DEFAULT 0,
 -- The user's read position and a group's edit revision.
 last_read_seq INTEGER NOT NULL DEFAULT 0,
 revision INTEGER NOT NULL DEFAULT 1,
 -- An uploaded picture (images.rs) instead of the colour.
 avatar_image TEXT,
 created_at INTEGER NOT NULL,
 updated_at INTEGER NOT NULL,
 CHECK(kind!='direct' OR pot_b IS NULL),
 CHECK(kind!='pot_dm' OR pot_a IS NULL OR pot_b IS NULL OR pot_a<pot_b),
 CHECK(kind!='group' OR (pot_a IS NULL AND pot_b IS NULL))
);
CREATE UNIQUE INDEX threads_direct ON threads(owner_user, pot_a) WHERE kind='direct';
CREATE UNIQUE INDEX threads_pot_dm ON threads(owner_user, pot_a, pot_b) WHERE kind='pot_dm';
CREATE INDEX threads_owner ON threads(owner_user, updated_at);
CREATE TABLE thread_members (
 thread_id TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
 pot_id TEXT NOT NULL REFERENCES pots(id) ON DELETE CASCADE,
 PRIMARY KEY(thread_id, pot_id)
);
CREATE TABLE messages (
 id TEXT PRIMARY KEY,
 thread_id TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
 seq INTEGER NOT NULL,
 author_kind TEXT NOT NULL CHECK(author_kind IN ('user','pot','system')),
 author_id TEXT,
 -- The author pot's name, kept once the pot is deleted.
 author_name TEXT,
 body TEXT NOT NULL CHECK(length(body) BETWEEN 1 AND 32768),
 mentions_json TEXT NOT NULL DEFAULT '[]' CHECK(json_valid(mentions_json)),
 all_mention INTEGER NOT NULL DEFAULT 0 CHECK(all_mention IN (0,1)),
 causal_root TEXT,
 created_at INTEGER NOT NULL,
 -- A Gateway card (approval, budget request, work): a typed system message.
 card_json TEXT CHECK(card_json IS NULL OR (json_valid(card_json) AND author_kind='system')),
 UNIQUE(thread_id, seq),
 CHECK(all_mention=0 OR author_kind='user')
);
-- A pot's request to start work with an `ask` model (plans/pots.md, Models
-- for work). "allow once" covers exactly one start, then the row is used.
CREATE TABLE model_approvals (
 id TEXT PRIMARY KEY,
 owner_user TEXT NOT NULL,
 pot_id TEXT NOT NULL REFERENCES pots(id) ON DELETE CASCADE,
 work_title TEXT NOT NULL CHECK(length(work_title) BETWEEN 1 AND 200),
 -- Where the work would run.
 workspace_id TEXT NOT NULL CHECK(length(workspace_id) BETWEEN 1 AND 256),
 provider TEXT NOT NULL CHECK(length(provider) BETWEEN 1 AND 100),
 model TEXT NOT NULL CHECK(length(model) BETWEEN 1 AND 200),
 thinking TEXT CHECK(thinking IS NULL OR thinking IN ('off','minimal','low','medium','high','xhigh')),
 -- The causal root of the wake that asked, so the answer continues it.
 causal_root TEXT,
 depth INTEGER NOT NULL DEFAULT 0 CHECK(depth>=0),
 -- The pot's reason for this start.
 reason TEXT NOT NULL DEFAULT '' CHECK(length(reason)<=2000),
 estimate_micros INTEGER NOT NULL DEFAULT 0 CHECK(estimate_micros>=0),
 remaining_micros INTEGER CHECK(remaining_micros IS NULL OR remaining_micros>=0),
 state TEXT NOT NULL DEFAULT 'pending' CHECK(state IN ('pending','allowed_once','denied','used')),
 deny_reason TEXT CHECK(deny_reason IS NULL OR length(deny_reason)<=2000),
 created_at INTEGER NOT NULL,
 answered_at INTEGER,
 used_at INTEGER,
 CHECK(deny_reason IS NULL OR state='denied'),
 CHECK(answered_at IS NULL OR state!='pending'),
 CHECK(used_at IS NULL OR state='used')
);
CREATE INDEX model_approvals_owner ON model_approvals(owner_user, state, created_at DESC);
CREATE INDEX model_approvals_pot_pending ON model_approvals(pot_id, state) WHERE state='pending';
-- What pots did (plans/pots.md, Activity and point of view). A row keeps the
-- pot's name and color, so it still reads after the pot is deleted, until the
-- owner's retention removes it.
CREATE TABLE pot_activity (
 id TEXT PRIMARY KEY,
 owner_user TEXT NOT NULL,
 pot_id TEXT REFERENCES pots(id) ON DELETE SET NULL,
 pot_name TEXT NOT NULL,
 pot_avatar_color INTEGER NOT NULL,
 at INTEGER NOT NULL,
 kind TEXT NOT NULL CHECK(kind IN (
  'created','updated','paused','resumed','archived','restored','deleted',
  'dm','group_message','assign','work_opened','work_instruction','file_read',
  'thinking_adjust','fallback','autonomy_changed','reminder_set','review',
  'handover_proposed','awaiting_confirm','awaiting_approval','approval_answered',
  'forwarded_to_user','budget_request','budget_exhausted','loop_guard')),
 counterpart_kind TEXT CHECK(counterpart_kind IS NULL OR counterpart_kind IN ('user','pot','work_session','workspace','system')),
 counterpart_id TEXT,
 summary TEXT NOT NULL CHECK(length(summary) BETWEEN 1 AND 400),
 refs_json TEXT NOT NULL DEFAULT '{}' CHECK(json_valid(refs_json)),
 causal_root TEXT,
 CHECK(counterpart_id IS NULL OR counterpart_kind IS NOT NULL)
);
CREATE INDEX pot_activity_owner ON pot_activity(owner_user, at DESC);
CREATE INDEX pot_activity_pot ON pot_activity(pot_id, at DESC);
-- Work sessions a pot opened and coordinates (plans/pots.md, Work dispatch).
CREATE TABLE pot_works (
 id TEXT PRIMARY KEY,
 owner_user TEXT NOT NULL,
 pot_id TEXT NOT NULL REFERENCES pots(id) ON DELETE CASCADE,
 session_id TEXT NOT NULL UNIQUE,
 workspace_id TEXT NOT NULL,
 title TEXT NOT NULL CHECK(length(title) BETWEEN 1 AND 200),
 provider TEXT NOT NULL,
 model TEXT NOT NULL,
 thinking TEXT,
 -- The root that started this work; its session's requests charge it.
 causal_root TEXT,
 -- taken_over: the user took it; the pot may no longer send into it.
 state TEXT NOT NULL DEFAULT 'open' CHECK(state IN ('open','taken_over')),
 created_at INTEGER NOT NULL,
 updated_at INTEGER NOT NULL
);
CREATE INDEX pot_works_pot ON pot_works(pot_id, state);
CREATE INDEX pot_works_owner ON pot_works(owner_user, created_at DESC);
-- Each instruction a pot sent into its work, delivered at most once.
CREATE TABLE pot_work_instructions (
 id TEXT PRIMARY KEY,
 work_id TEXT NOT NULL REFERENCES pot_works(id) ON DELETE CASCADE,
 -- The root of the wake that sent it (work keeps charging its start root).
 causal_root TEXT,
 body TEXT NOT NULL CHECK(length(body) BETWEEN 1 AND 32768),
 state TEXT NOT NULL CHECK(state IN ('sending','delivered','refused','uncertain')),
 error TEXT,
 created_at INTEGER NOT NULL
);
CREATE INDEX pot_work_instructions_work ON pot_work_instructions(work_id, created_at);
-- Reminders a pot sets for itself (plans/pots.md, Autonomy): a row becomes a
-- `reminder` wake at its due time, at most once.
CREATE TABLE pot_reminders (
 id TEXT PRIMARY KEY,
 pot_id TEXT NOT NULL REFERENCES pots(id) ON DELETE CASCADE,
 owner_user TEXT NOT NULL,
 note TEXT NOT NULL CHECK(length(note) BETWEEN 1 AND 4000),
 due_at INTEGER NOT NULL,
 state TEXT NOT NULL DEFAULT 'pending' CHECK(state IN ('pending','delivered')),
 wake_id TEXT,
 created_at INTEGER NOT NULL
);
CREATE INDEX pot_reminders_due ON pot_reminders(state, due_at) WHERE state='pending';
CREATE INDEX pot_reminders_pot ON pot_reminders(pot_id, state);
-- The model and thinking level last applied to a pot's session, so a wake
-- only sets them when they differ (plans/pots.md, Runtime).
CREATE TABLE pot_session_settings (
 pot_id TEXT PRIMARY KEY REFERENCES pots(id) ON DELETE CASCADE,
 provider TEXT NOT NULL,
 model TEXT NOT NULL,
 thinking TEXT NOT NULL,
 updated_at INTEGER NOT NULL
);
-- A pot's ask for more budget (plans/pots.md, Budgets and the causal root):
-- money for the current month or tokens for the current day. One request per
-- pot may be open; a denial blocks that window until the user writes in the
-- pot's direct thread. Approving raises the pot's cap for that window only.
CREATE TABLE budget_requests (
 id TEXT PRIMARY KEY,
 owner_user TEXT NOT NULL,
 pot_id TEXT NOT NULL REFERENCES pots(id) ON DELETE CASCADE,
 window TEXT NOT NULL CHECK(window IN ('month','day')),
 amount_micros INTEGER CHECK(amount_micros IS NULL OR amount_micros>=0),
 tokens INTEGER CHECK(tokens IS NULL OR tokens>=0),
 reason TEXT NOT NULL DEFAULT '' CHECK(length(reason)<=2000),
 -- The causal root of the wake that asked; the answer continues it.
 causal_root TEXT,
 depth INTEGER NOT NULL DEFAULT 0 CHECK(depth>=0),
 state TEXT NOT NULL DEFAULT 'pending' CHECK(state IN ('pending','approved','approved_amount','denied')),
 approved_amount_micros INTEGER CHECK(approved_amount_micros IS NULL OR approved_amount_micros>=0),
 approved_tokens INTEGER CHECK(approved_tokens IS NULL OR approved_tokens>=0),
 created_at INTEGER NOT NULL,
 answered_at INTEGER,
 CHECK((amount_micros IS NULL) != (tokens IS NULL)),
 CHECK(window!='month' OR (amount_micros IS NOT NULL AND amount_micros>0)),
 CHECK(window!='day' OR (tokens IS NOT NULL AND tokens>0)),
 CHECK(answered_at IS NULL OR state!='pending'),
 CHECK(state='pending' OR approved_amount_micros IS NOT NULL OR approved_tokens IS NOT NULL OR state='denied')
);
CREATE INDEX budget_requests_owner ON budget_requests(owner_user, state, created_at DESC);
CREATE UNIQUE INDEX budget_requests_open ON budget_requests(pot_id) WHERE state='pending';
-- L0: one row per observed fact, no content (plans/pots.md, Observation and
-- de-duplication).
CREATE TABLE obs_events (
 id TEXT PRIMARY KEY,
 owner_user TEXT NOT NULL,
 source_kind TEXT NOT NULL CHECK(source_kind IN ('session','schedule_run','calendar')),
 source_ref TEXT NOT NULL,
 condition_key TEXT NOT NULL,
 occurrence_key TEXT NOT NULL,
 source_revision TEXT,
 created_at INTEGER NOT NULL,
 UNIQUE(owner_user, source_kind, source_ref, condition_key, occurrence_key)
);
CREATE INDEX obs_events_created ON obs_events(created_at);
-- The pots an event reached, and whether through a scope they lead.
CREATE TABLE obs_targets (
 event_id TEXT NOT NULL REFERENCES obs_events(id) ON DELETE CASCADE,
 pot_id TEXT NOT NULL REFERENCES pots(id) ON DELETE CASCADE,
 lead INTEGER NOT NULL DEFAULT 0 CHECK(lead IN (0,1)),
 PRIMARY KEY(event_id, pot_id)
);
-- L1: each pot's own note on an event, never merged.
CREATE TABLE obs_observations (
 id TEXT PRIMARY KEY,
 pot_id TEXT NOT NULL REFERENCES pots(id) ON DELETE CASCADE,
 event_id TEXT NOT NULL REFERENCES obs_events(id) ON DELETE CASCADE,
 note TEXT NOT NULL CHECK(length(note) BETWEEN 1 AND 4000),
 evidence_json TEXT NOT NULL DEFAULT '[]' CHECK(json_valid(evidence_json)),
 created_at INTEGER NOT NULL,
 UNIQUE(pot_id, event_id)
);
-- L2: at most one notification to the user per observed event, from the lead
-- pot or merged from every observer who asked to notify.
CREATE TABLE obs_notifications (
 id TEXT PRIMARY KEY,
 owner_user TEXT NOT NULL,
 event_id TEXT NOT NULL REFERENCES obs_events(id) ON DELETE CASCADE,
 -- The lead pot that notified; NULL for a merged notification.
 issuer_pot_id TEXT REFERENCES pots(id) ON DELETE SET NULL,
 observation_ids_json TEXT NOT NULL DEFAULT '[]' CHECK(json_valid(observation_ids_json)),
 state TEXT NOT NULL DEFAULT 'open' CHECK(state IN ('open','read')),
 created_at INTEGER NOT NULL,
 updated_at INTEGER NOT NULL,
 UNIQUE(owner_user, event_id)
);
CREATE INDEX obs_notifications_owner ON obs_notifications(owner_user, state, updated_at DESC);
-- L3: one active dispatch per purpose (target, action, event); a second pot
-- is told who handles it.
CREATE TABLE obs_dispatches (
 id TEXT PRIMARY KEY,
 owner_user TEXT NOT NULL,
 event_id TEXT NOT NULL REFERENCES obs_events(id) ON DELETE CASCADE,
 purpose_key TEXT NOT NULL,
 pot_id TEXT NOT NULL REFERENCES pots(id) ON DELETE CASCADE,
 work_id TEXT,
 state TEXT NOT NULL DEFAULT 'active' CHECK(state IN ('active','released')),
 created_at INTEGER NOT NULL
);
CREATE UNIQUE INDEX obs_dispatches_active ON obs_dispatches(owner_user, purpose_key) WHERE state='active';
-- Handovers of a pot's items to another pot or the user (plans/pots.md,
-- Handover, pause, archive, delete). Kept after the pot is deleted.
CREATE TABLE pot_handovers (
 id TEXT PRIMARY KEY,
 owner_user TEXT NOT NULL,
 from_pot_id TEXT REFERENCES pots(id) ON DELETE SET NULL,
 to_kind TEXT NOT NULL CHECK(to_kind IN ('pot','user')),
 to_pot_id TEXT REFERENCES pots(id) ON DELETE SET NULL,
 proposed_by TEXT NOT NULL CHECK(proposed_by IN ('user','pot')),
 reason TEXT NOT NULL DEFAULT '' CHECK(length(reason)<=2000),
 state TEXT NOT NULL DEFAULT 'proposed' CHECK(state IN ('proposed','applied','rejected')),
 revision INTEGER NOT NULL DEFAULT 1,
 created_at INTEGER NOT NULL,
 applied_at INTEGER
);
CREATE INDEX pot_handovers_owner ON pot_handovers(owner_user, state, created_at DESC);
CREATE TABLE pot_handover_items (
 handover_id TEXT NOT NULL REFERENCES pot_handovers(id) ON DELETE CASCADE,
 kind TEXT NOT NULL CHECK(kind IN ('responsibility','reminder','work','group_host')),
 ref TEXT NOT NULL,
 label TEXT NOT NULL,
 -- How the item is recognised across handovers (loop-guard rule 1).
 item_key TEXT NOT NULL,
 fit TEXT NOT NULL CHECK(fit IN ('ok','narrowed','stop')),
 reason TEXT,
 PRIMARY KEY(handover_id, kind, ref)
);
CREATE INDEX pot_handover_items_key ON pot_handover_items(item_key);
-- One causal root per user message, observed event, autonomy review or
-- reminder (plans/pots.md, Budgets and the causal root): every wake, pot
-- message, work start and model request it causes shares its depth and
-- fan-out limits and its budget. New work never resets its accounting.
CREATE TABLE causal_roots (
 id TEXT PRIMARY KEY,
 owner_user TEXT NOT NULL,
 origin_kind TEXT NOT NULL CHECK(origin_kind IN ('user_message','event','review','reminder')),
 origin_ref TEXT NOT NULL,
 -- Where the user sees it: the message's thread, else the initiator's direct thread.
 thread_id TEXT,
 initiator_pot TEXT NOT NULL REFERENCES pots(id) ON DELETE CASCADE,
 depth_limit INTEGER NOT NULL CHECK(depth_limit BETWEEN 1 AND 16),
 fanout_limit INTEGER NOT NULL CHECK(fanout_limit BETWEEN 1 AND 16),
 budget_money_micros INTEGER NOT NULL DEFAULT 0 CHECK(budget_money_micros>=0),
 budget_tokens INTEGER NOT NULL DEFAULT 0 CHECK(budget_tokens>=0),
 spent_money_micros INTEGER NOT NULL DEFAULT 0 CHECK(spent_money_micros>=0),
 spent_tokens INTEGER NOT NULL DEFAULT 0 CHECK(spent_tokens>=0),
 reserved_money_micros INTEGER NOT NULL DEFAULT 0 CHECK(reserved_money_micros>=0),
 reserved_tokens INTEGER NOT NULL DEFAULT 0 CHECK(reserved_tokens>=0),
 state TEXT NOT NULL DEFAULT 'active' CHECK(state IN ('active','suspended','stopped')),
 -- Why the loop guard suspended it, and since when delivery has waited.
 suspend_reason TEXT,
 suspended_at INTEGER,
 blocked_since INTEGER,
 last_progress_at INTEGER NOT NULL,
 created_at INTEGER NOT NULL
);
CREATE INDEX causal_roots_owner ON causal_roots(owner_user, created_at DESC);
-- What a root caused, for the loop guard: wakes and messages count towards
-- the no-progress streak and the rate ceilings; progress rows only explain it.
CREATE TABLE causal_root_events (
 id TEXT PRIMARY KEY,
 root_id TEXT NOT NULL REFERENCES causal_roots(id) ON DELETE CASCADE,
 at INTEGER NOT NULL,
 kind TEXT NOT NULL CHECK(kind IN ('wake','message','progress')),
 -- The wake's receiver, or the message's sender.
 pot_id TEXT NOT NULL,
 -- The other pot of the pair (a wake's sender, a message's receiver).
 peer_pot_id TEXT,
 purpose_json TEXT NOT NULL DEFAULT '{}' CHECK(json_valid(purpose_json))
);
CREATE INDEX causal_root_events_root ON causal_root_events(root_id, at);
CREATE INDEX causal_root_events_pair ON causal_root_events(pot_id, peer_pot_id, at);
-- The root each held model reservation belongs to (plans/usage.md, Budget
-- admission): a restart or a timed-out request must still reconcile the
-- root's reserved budget with its spent budget.
CREATE TABLE root_reservations (
 reservation_id TEXT PRIMARY KEY,
 root_id TEXT NOT NULL REFERENCES causal_roots(id) ON DELETE CASCADE,
 money_micros INTEGER NOT NULL CHECK(money_micros>=0),
 tokens INTEGER NOT NULL CHECK(tokens>=0),
 created_at INTEGER NOT NULL
);
CREATE INDEX root_reservations_root ON root_reservations(root_id);
-- A pot's own memory (P8): its notes, never another pot's, deleted with it.
CREATE TABLE pot_memory (
 id TEXT PRIMARY KEY,
 pot_id TEXT NOT NULL REFERENCES pots(id) ON DELETE CASCADE,
 content TEXT NOT NULL CHECK(length(content) BETWEEN 1 AND 2000),
 revision INTEGER NOT NULL DEFAULT 1,
 created_at INTEGER NOT NULL,
 updated_at INTEGER NOT NULL
);
CREATE INDEX pot_memory_pot ON pot_memory(pot_id, created_at);
