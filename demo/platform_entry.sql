-- The entrance: what an agent sees without going looking.
-- Run AFTER demo/platform_loading.sql.
--
-- Measured against the running MCP server 2026-09-10. An agent gets these for free, every
-- session:
--   * the tool list (fixed, cannot be influenced)
--   * list_tables: name, rls_enabled, rows, comment -- and columns in verbose
--   * whatever execute_sql returns
--   * error messages from constraints and triggers
--
-- list_tables does NOT return views, not even in verbose. Every platform.v_* and every
-- function (overview, search, daily_report, placement_rule) is therefore invisible to an
-- agent that does not already know it exists. That makes comments the only place we can
-- say something that is guaranteed to arrive, and a real table the only way to get an
-- entry into the list.
--
-- Hence this table. It holds no business data. It exists to be seen -- the board in the
-- entrance hall that says who lives where, what is in which room, and where to ask how to
-- get the piano to the fourth floor.

select public.create_shared_table('start_here', 'START HERE. The table of contents for the shared store: what exists, how to find it, and the rules that apply. Run: select step, heading, do_this, why from start_here order by step. Views and functions do not appear in list_tables, so this table is the only way to find them.');

alter table public.start_here
  add column if not exists step    int not null default 0,
  add column if not exists heading text not null,
  add column if not exists do_this text,
  add column if not exists why     text;

comment on column public.start_here.do_this is 'The SQL to run, or what to do.';
comment on column public.start_here.why is 'Why the step exists. Do not skip it.';

-- Written only when the steps differ from what is there. Truncate-and-insert on every boot
-- logged nine inserts per boot into the change log, and read as activity.
create temp table if not exists _start_here_seed (owner text, created_by text, updated_by text,
  step int, heading text, do_this text, why text);
truncate _start_here_seed;
insert into _start_here_seed (owner, created_by, updated_by, step, heading, do_this, why) values
('platform','platform','platform', 1, 'See the state',
 'select * from platform.overview();',
 'Seven numbers: how many tables, how many skills, which agents are active, what needs tidying.'),

('platform','platform','platform', 2, 'See who else lives here',
 'select * from agents where active;  select * from platform.v_flow limit 20;',
 'You are not alone in the store. The first query says which identifiers exist and who they belong to; the second says what they just did, collapsed per minute so one bulk load does not drown the rest. Someone may already be working on your question.'),

('platform','platform','platform', 3, 'Read the rules before you write',
 'select skill_md from skill_library where slug = ''store-conventions'';',
 'It holds the placement rule (table, note or skill?), ownership, public against private, and what you may not do without asking. Everything you write is judged against it.'),

('platform','platform','platform', 4, 'Search before you create -- and before you answer',
 'select * from platform.search(''your keywords'');',
 'Keyword search over skills, notes, documents and table descriptions. Duplicates are what make a shared store unusable. And searching before you ANSWER matters just as much: someone may have written down how that data has to be read. Measured -- the same question gave 1,091,957 without a search and 28,638 with one, because sixteen rows out of 5,812 carried sentinel values a colleague had already documented.'),

('platform','platform','platform', 5, 'See what exists and how fresh it is',
 'select * from platform.v_catalog;  select * from platform.v_sources;',
 'The catalogue lists every table with its size and whether it follows the convention. v_sources says where data came from and when it was last loaded.'),

('platform','platform','platform', 6, 'Follow the house standard for your kind of work',
 'select slug, name, description from skill_library where ''house-standard'' = any(tags) and status = ''published'';',
 'If you are loading a file from another system there is a finished procedure. Read it before, not after. This is the shelf to check when you need to know how the piano gets upstairs.'),

('platform','platform','platform', 7, 'Unsure where something belongs?',
 'select platform.placement_rule();',
 'Four places, fixed order: a skill if someone should follow it, a table if it is the same shape over and over, otherwise a note. Files in Storage. When in doubt: a note.'),

('platform','platform','platform', 8, 'Tidy one item when you have time',
 'select * from platform.v_action_items;  select * from platform.v_going_stale;',
 'A shared store dies of old content, not of too little. Take one item per session and nobody has to do a spring clean.'),

('platform','platform','platform', 9, 'Report to a person',
 'select platform.daily_report(1);',
 'Readable text: who did what, new skills, new tables, what is waiting. Paste it into the chat when someone asks how it is going.');

do $sh$
begin
  if exists (select step, heading, do_this, why from _start_here_seed
             except select step, heading, do_this, why from public.start_here)
  or exists (select step, heading, do_this, why from public.start_here
             except select step, heading, do_this, why from _start_here_seed) then
    truncate public.start_here;
    insert into public.start_here (owner, created_by, updated_by, step, heading, do_this, why)
    select owner, created_by, updated_by, step, heading, do_this, why from _start_here_seed;
  end if;
end $sh$;
drop table _start_here_seed;

-- A comment is the only thing that reaches an agent through list_tables, so the rules that
-- matter most are repeated there even though they are also in the skill.
comment on table public.skill_library is 'The shared skill library. Instructions other agents should FOLLOW. Publish with tags, a description and frontmatter. Retire with public.retire_skill(), never delete. Confirm with public.confirm_skill() when you followed one and it worked.';
comment on table public.notes is 'Free text: observations, investigations, anything that is not the same shape over and over. The default place when you are unsure. Fill owner, created_by and updated_by with your agent_NN, and set visibility private only when the user asks. A private note is never indexed, so nobody can find it by meaning -- including you.';
comment on table public.documents is 'The catalogue of files. The contents live in Storage, never as base64 in a column. A row without a path means the file has not been uploaded -- only a person can do that -- and that the store does not hold what the file says. Asked what such a document contains, say it is not here rather than guessing from the filename.';
comment on table public.agents is 'Who is who: agent_NN corresponds to an MCP key slot. Update your own row with your name and role the first time you connect.';
comment on table public.start_here is 'START HERE. The table of contents for the shared store: what exists, how to find it, and the rules that apply. Run: select step, heading, do_this, why from start_here order by step. Views and functions do not appear in list_tables, so this table is the only way to find them.';
