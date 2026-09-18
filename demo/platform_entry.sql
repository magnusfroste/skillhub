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
 'skillhub_overview',
 'What is here, who is here, what is waiting on you, and whether search by meaning is on. Run it first in a new session; everything else in this list is reachable from what it tells you.'),
('platform','platform','platform', 2, 'Find out whether it is already answered',
 'skillhub_search(''your keywords'')   then skillhub_similar(''a sentence'') when no word matches',
 'Search before you create, and -- this is the one people skip -- before you ANSWER a question from the data. Somebody may have written down how it has to be read. Measured: the same question gave 1,091,957 without a search and 28,638 with one, because sixteen rows out of 5,812 carried sentinel values a colleague had already documented. Duplicates are what make a shared store unusable; a wrong number is what makes it dangerous.'),
('platform','platform','platform', 3, 'Read the rules before you write',
 'skillhub_rules',
 'The placement rule (skill, table or note?), ownership, public against private, and what you may not do without asking. Everything you write is judged against it.'),
('platform','platform','platform', 4, 'Read whole things, not excerpts',
 'skillhub_read(kind, id)   -- and version= for an older version of a skill',
 'A fragment is how a confident wrong answer gets made. A skill also lists every version it has had, so you can say which one you read -- the question an auditor asks first.'),
('platform','platform','platform', 5, 'Follow the house standard for your kind of work',
 'skillhub_help(''<topic>'')   -- the topics are listed by skillhub_help',
 'For loading a file from another system, or for running the store with the admin key, there is a finished procedure. Read it before, not after. This is the shelf to check when you need to know how the piano gets upstairs.'),
('platform','platform','platform', 6, 'Write what you learned where it will be found',
 'skillhub_write_note  ·  skillhub_publish_skill  ·  skillhub_add_rows  ·  skillhub_register_document',
 'A note for an observation, a skill for something others should follow, rows for the same shape over and over, a document record for a file. Publishing never overwrites a colleague: a higher version supersedes, and nothing is ever deleted.'),
('platform','platform','platform', 7, 'Hand over a file of rows instead of retyping it',
 'skillhub_upload_url  ->  run the curl line  ->  skillhub_load_file   (or skillhub_request_structure when no table fits)',
 'Sixty rows typed through a model took 36 calls and stopped at 19. The file goes beside the model, not through it. Say what you noticed about the data in observations: those become the column comments the next agent reads.'),
('platform','platform','platform', 8, 'Ask when the store does not know',
 'skillhub_ask(''what you need, and what you looked at'')   ·   skillhub_answer(ask_id, answer)',
 'A noticeboard, not a call: nobody is notified, and a colleague''s agent sees your question the next time somebody talks to it. If you answer one from your own knowledge, write the answer down as well -- otherwise the next person has to ask again.'),
('platform','platform','platform', 9, 'Tell a person how it is going',
 'skillhub_report(days)   ·   skillhub_activity',
 'Readable text: who did what, what is new, what is waiting. Paste it into the chat when someone asks. And take one item from what needs tidying when you have time -- a shared store dies of old content, not of too little.');

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

-- ---------------------------------------------------------------------------
-- The door onto all of the above, for a person as much as for an agent.
--
-- start_here was written when the store was built and nothing ever read it -- not one
-- function, not one tool. Worse, every step told the reader to run raw SQL, which is the one
-- thing an agent key may not do: the table was written before the tools existed and never
-- caught up. So it was a manual nobody could open, telling its only reader to use a door that
-- had since been closed.
--
-- This is deliberately NOT a second manual. The tour lives in start_here and nowhere else;
-- the topics are the skills tagged house-standard, so a new one becomes a topic the moment
-- somebody publishes it; the tools describe themselves in the client's own tool list, and
-- repeating them here would be two places to keep in step. What was missing was a door.
--
-- It returns TEXT, not jsonb, for the same reason skillhub_report does: the reader may be a
-- person looking at a chat window, and a wall of JSON is exactly what is unreadable there.
create or replace function public.skillhub_help(topic text default null) returns text
language plpgsql stable security definer set search_path = public, platform as $$
declare out_text text := ''; r record; n int := 0; hit record;
begin
  if topic is not null and length(btrim(topic)) > 0 then
    -- man <topic>: the house standard whose slug or name is closest.
    -- Resolve the way man does: the word somebody actually types. "loading" is not a
    -- substring of load-from-source-system, and "csv" and "admin" are in the tags rather than
    -- the name -- so slug, name, tags and trigram similarity all get a say, best score wins,
    -- and a weak best falls through to the list rather than guessing.
    select s.slug, s.name, s.skill_md, s.version into hit
      from platform.v_current_skills s
     cross join lateral (select greatest(
        case when s.slug = btrim(topic) then 1.0 else 0 end,
        case when s.slug ilike '%'||btrim(topic)||'%' or s.name ilike '%'||btrim(topic)||'%' then 0.9 else 0 end,
        case when exists (select 1 from unnest(s.tags) g
                           where g ilike '%'||btrim(topic)||'%' or btrim(topic) ilike '%'||g||'%') then 0.85 else 0 end,
        case when btrim(topic) ilike '%'||split_part(s.slug,'-',1)||'%' then 0.8 else 0 end,
        similarity(s.slug||' '||s.name||' '||coalesce(s.description,''), btrim(topic))) as score) m
     where 'house-standard' = any(s.tags) and s.visibility = 'public' and m.score > 0.2
     order by m.score desc, length(s.slug) limit 1;
    if hit.slug is null then
      out_text := format(E'No topic matches "%s".\n\nThe topics are:\n', btrim(topic));
      for r in select s.slug, s.name from platform.v_current_skills s
                where 'house-standard' = any(s.tags) and s.visibility = 'public' order by s.slug loop
        out_text := out_text || format(E'  %-26s %s\n', r.slug, r.name);
      end loop;
      return out_text || E'\nOr search the whole library: skillhub_search(''your words'').';
    end if;
    return format(E'%s  --  %s (version %s)\n%s\n\n%s\n', hit.slug, hit.name, hit.version,
                  repeat('-', 60), hit.skill_md);
  end if;

  out_text := E'SKILLHUB -- a data store several agents share.\n\n'
    || E'You read everything public, write your own, and cannot overwrite a colleague''s work.\n'
    || E'Every write carries the name the gateway verified from your key. Nothing is deleted;\n'
    || E'things are retired, and retired things stay readable.\n\n'
    || E'WHAT TO DO, IN ORDER\n';
  for r in select step, heading, do_this, why from public.start_here order by step loop
    out_text := out_text || format(E'\n%s. %s\n   %s\n   %s\n', r.step, r.heading, r.do_this, r.why);
  end loop;

  out_text := out_text || E'\nTOPICS -- the finished procedures, read one with skillhub_help(''topic'')\n';
  for r in select s.slug, s.name, s.description from platform.v_current_skills s
            where 'house-standard' = any(s.tags) and s.visibility = 'public' order by s.slug loop
    out_text := out_text || format(E'  %-26s %s\n', r.slug, r.name); n := n + 1;
  end loop;
  if n = 0 then out_text := out_text || E'  (none published yet)\n'; end if;

  return out_text
    || E'\nEverything else you can do is in your client''s own tool list, where the name of each\n'
    || E'tool says what it is for. This is the house, not the buttons.\n';
end $$;
comment on function public.skillhub_help(text) is 'The tour and the topics, as plain text: what to do in order (from start_here) and the house standards. skillhub_help(''loading'') reads one of them. Ask for it whenever somebody wants to know what this store is or what they can do with it.';

