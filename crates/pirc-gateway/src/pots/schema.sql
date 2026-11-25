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
 budget_money_month_micros INTEGER NOT NULL DEFAULT 0 CHECK(budget_money_month_micros>=0),
 budget_tokens_day INTEGER NOT NULL DEFAULT 0 CHECK(budget_tokens_day>=0)
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
 -- The direct thread's pot, or a pot DM's two pots in order.
 pot_a TEXT REFERENCES pots(id) ON DELETE CASCADE,
 pot_b TEXT REFERENCES pots(id) ON DELETE CASCADE,
 last_seq INTEGER NOT NULL DEFAULT 0,
 created_at INTEGER NOT NULL,
 updated_at INTEGER NOT NULL,
 CHECK(kind!='direct' OR (pot_a IS NOT NULL AND pot_b IS NULL)),
 CHECK(kind!='pot_dm' OR (pot_a IS NOT NULL AND pot_b IS NOT NULL AND pot_a<pot_b)),
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
 body TEXT NOT NULL CHECK(length(body) BETWEEN 1 AND 32768),
 mentions_json TEXT NOT NULL DEFAULT '[]' CHECK(json_valid(mentions_json)),
 all_mention INTEGER NOT NULL DEFAULT 0 CHECK(all_mention IN (0,1)),
 causal_root TEXT,
 created_at INTEGER NOT NULL,
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
