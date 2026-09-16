-- Operating the store: what the caretaker needs to see, in one call, with the call to fix it.
--
-- Everything here already had a view. platform.v_index_status, v_embed_queue, v_action_items,
-- v_going_stale, v_abandoned_tables, v_caveats, v_structure_requests, the change log -- the
-- store could answer every operational question a day before this file existed. What it could
-- not do was ASK. Every fault found on 2026-09-16 -- a stale house standard, a silent cron, a
-- skill that grew four sections a boot for two weeks, vectors outliving the objects they
-- pointed at, chunks cut without a number moving -- was found because somebody happened to
-- look. That is not an operating model; it is luck with a good memory.
--
-- So: one function that looks at all of them and says ok, attention or broken, with the exact
-- call for each thing that is wrong. A monitor runs utils/health.sh every few minutes and
-- watches the exit code. A caretaker agent gets the same object inside skillhub_overview,
-- because it holds the service key -- the tool it already runs at the start of a session.

-- ---------------------------------------------------------------------------
-- 1) History. platform.embedder keeps the LAST run, which cannot answer "has this been
--    failing all night and recovering by morning".
-- ---------------------------------------------------------------------------
create table if not exists platform.index_runs (
  id         bigserial primary key,
  at         timestamptz not null default now(),
  model      text,
  dimension  int,
  objects    int,          -- how many were waiting
  embedded   int,          -- how many were saved whole
  chunks     int,
  truncated  int,          -- did not fit, deliberately left unindexed
  failed     int,
  requests   int,          -- upstream calls made
  pruned     int,          -- vectors removed for objects that went private or were retired
  seconds    numeric(8,2),
  error      text
);
create index if not exists index_runs_at_idx on platform.index_runs (at desc);
comment on table platform.index_runs is 'One row per indexing run, kept for seven days. The last run is in platform.embedder; this is whether it has been flapping.';

create or replace function public.index_run_save(p jsonb) returns bigint
language sql security definer set search_path = public, platform as $$
  insert into platform.index_runs (model, dimension, objects, embedded, chunks, truncated, failed, requests, pruned, seconds, error)
  values (p->>'model', (p->>'dimension')::int, (p->>'objects')::int, (p->>'embedded')::int,
          (p->>'chunks')::int, (p->>'truncated')::int, (p->>'failed')::int, (p->>'requests')::int,
          (p->>'pruned')::int, (p->>'seconds')::numeric, p->>'error')
  returning id;
$$;
revoke execute on function public.index_run_save(jsonb) from public, anon, authenticated;
grant execute on function public.index_run_save(jsonb) to service_role;

-- ---------------------------------------------------------------------------
-- 2) Backups. The script exists; nothing recorded that it ran, so the question asked after
--    an incident -- when did we last have one -- had no answer in the store.
-- ---------------------------------------------------------------------------
create table if not exists platform.backups (
  id     bigserial primary key,
  at     timestamptz not null default now(),
  kind   text not null,              -- 'content' | 'full'
  path   text,
  bytes  bigint,
  note   text
);
comment on table platform.backups is 'When a backup was taken and where it went. Written by utils/backup-content.sh; read by platform.health().';

create or replace function public.backup_record(kind text, path text default null, bytes bigint default null, note text default null)
returns bigint language sql security definer set search_path = public, platform as $$
  insert into platform.backups (kind, path, bytes, note) values (kind, path, bytes, note) returning id;
$$;
revoke execute on function public.backup_record(text, text, bigint, text) from public, anon, authenticated;
grant execute on function public.backup_record(text, text, bigint, text) to service_role, postgres;

-- ---------------------------------------------------------------------------
-- 3) The one call.
--
-- Three states, and the difference matters: BROKEN is something a person has to act on now
-- and an agent is getting wrong answers meanwhile; ATTENTION is work waiting that nobody
-- loses sleep over; OK is ok. A monitor exits non-zero only on broken, or it stops being read.
-- ---------------------------------------------------------------------------
create or replace function platform.health() returns jsonb
language plpgsql stable security definer set search_path = platform, public as $$
declare
  cks jsonb := '[]'::jsonb;
  verdict text := 'ok';
  e       record;
  last_boot timestamptz;
  cron_last  timestamptz; cron_status text; cron_active boolean := false;
  open_n int; open_days numeric;
  stale_n int; aband_n int; dupe_n int;
  backup_at timestamptz; backup_days numeric;
  runs_24h int; runs_failed int; runs_trunc int;
  db_size text; emb_rows bigint; net_ok boolean; waiting_n int;
  -- A check is: what it is called, how it stands, what is true, and -- when something
  -- should be done -- the call that does it. Built as jsonb rather than a temp table
  -- because a stable function may not create one, and this has to stay stable to be
  -- callable from inside skillhub_overview.
begin
  select max(at) into last_boot from platform.events where table_name = 'start_here';
  cks := cks || jsonb_build_object('check','store',
    'state', case when last_boot is null then 'broken' else 'ok' end,
    'detail', case when last_boot is null then 'The seed has never run: the store is not built.'
                   else format('Built and re-applied on every boot; last at %s.', last_boot::timestamp(0)) end,
    'run', case when last_boot is null then 'sh utils/seed.sh' end);

  -- Search by meaning fails quietly by design: keyword search keeps working, so nothing
  -- upstream ever notices. This is where it stops being quiet.
  select * into e from platform.embedder where id = 1;
  if e.status is null or e.status = 'off' then
    cks := cks || jsonb_build_object('check','meaning search','state','attention',
      'detail','Off: EMBEDDING_URL is not set. Keyword search is unaffected; nothing is found by meaning, so a question that does not share words with the answer returns nothing.',
      'run','Set EMBEDDING_URL, EMBEDDING_KEY and EMBEDDING_MODEL, then: select platform.reindex(''turning meaning search on'');',
      'changes','Empties the vector index and rebuilds it from the content. Nothing else is touched, and nothing is lost -- but do it once, deliberately, not as a step in a list.');
  elsif e.status = 'error' then
    cks := cks || jsonb_build_object('check','meaning search','state','broken',
      'detail', format('The indexer''s last run failed: %s', left(coalesce(e.last_error,'(no message)'), 300)),
      'run','sh utils/check-embedder.sh <EMBEDDING_URL> <EMBEDDING_MODEL>   -- from the machine that hosts the store');
  elsif coalesce(e.last_truncated,0) > 0 then
    cks := cks || jsonb_build_object('check','meaning search','state','attention',
      'detail', format('%s chunk(s) did not fit the model and were left unindexed on purpose. The chunk size has been lowered to %s characters.', e.last_truncated, e.max_chars),
      'run','Let the next run take them; if it repeats, pin EMBEDDING_MAX_CHARS below ' || e.max_chars);
  else
    cks := cks || jsonb_build_object('check','meaning search','state','ok',
      'detail', format('On: %s, %s dimensions, %s characters per chunk (%s).', e.model, e.dimension, e.max_chars, e.limit_source),
      'run', null);
  end if;

  -- A queue that never empties is the shape of a failure that retries for ever.
  select count(distinct (c->>'source', c->>'id')) into waiting_n
    from jsonb_array_elements(public.embed_candidates(1000, 100000)) c;
  if waiting_n > 0 then
    cks := cks || jsonb_build_object('check','index queue','state','attention',
      'detail', format('%s object(s) waiting. The cron takes them every five minutes; a number that does not fall is a failure repeating.', waiting_n),
      'run','select at, objects, embedded, truncated, failed, left(error,120) from platform.index_runs order by at desc limit 10;');
  end if;

  select count(*), coalesce(sum(failed),0), coalesce(sum(truncated),0) into runs_24h, runs_failed, runs_trunc
    from platform.index_runs where at > now() - interval '24 hours';
  if runs_24h > 0 then
    cks := cks || jsonb_build_object('check','indexing, last 24h',
      'state', case when runs_failed > 0 or runs_trunc > 0 then 'attention' else 'ok' end,
      'detail', format('%s run(s), %s object(s) failed, %s chunk(s) did not fit.', runs_24h, runs_failed, runs_trunc),
      'run', case when runs_failed > 0 or runs_trunc > 0
                  then 'select at, objects, embedded, truncated, failed, left(error,120) from platform.index_runs where at > now() - interval ''24 hours'' order by at desc;' end);
  end if;

  select exists (select 1 from pg_extension where extname = 'pg_net') into net_ok;
  if not net_ok then
    cks := cks || jsonb_build_object('check','index on write','state','attention',
      'detail','pg_net is not enabled, so a write becomes findable on the five-minute cron instead of in about a second.',
      'run','create extension pg_net;   -- then re-run the seed',
      'changes','Enables an extension. Needs a superuser, and the server must have been started with pg_net preloaded.');
  end if;

  -- The seed re-schedules this job on every boot, which gives it a new id and no history,
  -- so "has not run yet" is the normal state for the first five minutes of an instance's
  -- life. A check that cries wolf after every deploy is a check people learn to skip.
  begin
    select max(d.end_time), max(d.status) into cron_last, cron_status
      from cron.job j join cron.job_run_details d on d.jobid = j.jobid where j.jobname = 'embed';
    select exists (select 1 from cron.job where jobname = 'embed' and active) into cron_active;
  exception when others then cron_last := null; cron_status := null; cron_active := false;
  end;
  if cron_last is null and cron_active and last_boot > now() - interval '10 minutes' then
    cks := cks || jsonb_build_object('check','scheduled indexing','state','ok',
      'detail','Scheduled; the first run is due within five minutes of this boot.', 'run', null);
  elsif cron_last is null then
    cks := cks || jsonb_build_object('check','scheduled indexing','state','attention',
      'detail', case when cron_active then 'The embed job is scheduled but has not run. pg_cron may not be scheduling it.'
                     else 'The embed job is not scheduled. Content becomes findable only when something writes (pg_net), or not at all.' end,
      'run','select jobname, schedule, active from cron.job;');
  elsif cron_last < now() - interval '20 minutes' then
    cks := cks || jsonb_build_object('check','scheduled indexing','state','broken',
      'detail', format('The embed job last ran %s (%s). It should run every five minutes.', cron_last::timestamp(0), cron_status),
      'run','select * from platform.v_embed_queue;');
  else
    cks := cks || jsonb_build_object('check','scheduled indexing','state','ok',
      'detail', format('Ran %s, %s.', cron_last::timestamp(0), cron_status), 'run', null);
  end if;

  -- Work waiting on a person. An agent that asked for a table is blocked until this moves,
  -- and it can see that it is blocked, which makes the wait its own kind of cost.
  select count(*), coalesce(max(extract(epoch from (now() - at))/86400), 0)
    into open_n, open_days from platform.structure_requests where status = 'open';
  if open_n > 0 then
    cks := cks || jsonb_build_object('check','requests waiting on you',
      'state', case when open_days > 3 then 'attention' else 'ok' end,
      'detail', format('%s open, the oldest %s day(s). The agent that asked sees this in skillhub_overview and waits.', open_n, round(open_days,1)),
      'run','select id, requested_by, purpose, natural_key, document_id from platform.v_structure_requests where status = ''open'';');
  end if;

  select count(*) into stale_n from platform.v_going_stale;
  select count(*) into aband_n from platform.v_abandoned_tables;
  select count(*) into dupe_n  from platform.v_duplicates;
  if stale_n + aband_n + dupe_n > 0 then
    cks := cks || jsonb_build_object('check','tidying','state','ok',
      'detail', format('%s skill(s) nobody has confirmed in a long time, %s table(s) nothing writes to, %s possible duplicate(s).', stale_n, aband_n, dupe_n),
      'run','select * from platform.v_action_items;');
  end if;

  -- The question asked after an incident, which needs its answer written before one.
  select max(at) into backup_at from platform.backups;
  backup_days := extract(epoch from (now() - backup_at))/86400;
  if backup_at is null then
    cks := cks || jsonb_build_object('check','backup','state','attention',
      'detail','No backup has ever been recorded. The repository rebuilds the house; it cannot rebuild what agents and people put in it.',
      'run','sh utils/backup-content.sh   -- then put it in cron; the caretaker-operations skill has the line',
      'changes','Writes files to disk and records the backup. Safe, and the one on this list worth doing without being asked.');
  elsif backup_days > 2 then
    cks := cks || jsonb_build_object('check','backup','state','attention',
      'detail', format('The last recorded backup was %s day(s) ago (%s).', round(backup_days,1), backup_at::timestamp(0)),
      'run','sh utils/backup-content.sh',
      'changes','Writes files to disk and records the backup. Safe.');
  else
    cks := cks || jsonb_build_object('check','backup','state','ok',
      'detail', format('Last taken %s.', backup_at::timestamp(0)), 'run', null);
  end if;

  select pg_size_pretty(pg_database_size(current_database())) into db_size;
  select count(*) into emb_rows from platform.embeddings;
  cks := cks || jsonb_build_object('check','size','state','ok',
    'detail', format('Database %s, %s vector(s), %s table(s) in public.', db_size, emb_rows,
                     (select count(*) from platform.v_catalog)), 'run', null);

  if exists (select 1 from jsonb_array_elements(cks) c where c->>'state' = 'broken') then verdict := 'broken';
  elsif exists (select 1 from jsonb_array_elements(cks) c where c->>'state' = 'attention') then verdict := 'attention';
  end if;

  return jsonb_build_object(
    'verdict', verdict,
    'at', now()::timestamp(0),
    'meaning', case verdict
      when 'ok' then 'Nothing needs you.'
      when 'attention' then 'Nothing is broken; some things are waiting. Each one carries the call that deals with it.'
      else 'Something is wrong now, and agents are getting worse answers while it is.' end,
    -- Said here because the list below is a list: an agent handed one tends to work
    -- through it. Most of these are SELECTs and cost nothing. The few that change
    -- something carry a "changes" line, and those are a person's decision, not a step.
    'how to use this', 'Read before you act. Run the calls that only look -- they cost nothing and they say which of these is really true. A check carrying "changes" is a decision: say what you found and what you propose, and let the person answer. The house standard is the skill caretaker-operations.',
    'checks', (select jsonb_agg(c order by case c->>'state' when 'broken' then 0 when 'attention' then 1 else 2 end, c->>'check')
               from jsonb_array_elements(cks) c),
    -- Split deliberately. "look" is safe to run now, all of it. "decide" is not a list.
    'look', (select coalesce(jsonb_agg(c->>'run' order by case c->>'state' when 'broken' then 0 else 1 end), '[]'::jsonb)
             from jsonb_array_elements(cks) c where c->>'run' is not null and c->>'changes' is null),
    'decide', (select coalesce(jsonb_agg(jsonb_build_object('about', c->>'check', 'call', c->>'run', 'changes', c->>'changes')), '[]'::jsonb)
             from jsonb_array_elements(cks) c where c->>'changes' is not null));
end $$;
comment on function platform.health() is 'The state of the store in one call: ok, attention or broken, every check with what is true and the call that fixes it. Run it at the start of a caretaker session; utils/health.sh runs it from a monitor.';

create or replace function public.skillhub_health() returns jsonb
language sql stable security definer set search_path = public, platform as $$
  select platform.health();
$$;
revoke execute on function public.skillhub_health() from public, anon, authenticated;
grant execute on function public.skillhub_health() to service_role, postgres;
comment on function public.skillhub_health() is 'platform.health() through the gateway, for the service key only. Agents see the store; the caretaker sees the store AND how it is running.';

-- Seven days of history, pruned like the search log.
do $$ begin perform cron.unschedule('index_runs_prune'); exception when others then null; end $$;
select cron.schedule('index_runs_prune', '23 3 * * *',
  $job$ delete from platform.index_runs where at < now() - interval '7 days'; $job$);

grant select on all tables in schema platform to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4) The house standard for running the store, where the caretaker will find it: in the
--    library, tagged house-standard, alongside the one for loading a source system.
--
--    An agent with an admin key and no instructions improvises, and improvisation against
--    a database is how a store acquires four tables that mean the same thing. The cheapest
--    guard is not a rule that forbids; it is a ready answer for the thing it was about to
--    invent. Same reason load-from-source-system exists.
-- ---------------------------------------------------------------------------
do $do$
begin
  if not exists (select 1 from public.skill_library where slug = 'caretaker-operations' and version = '1.0.0') then
    insert into public.skill_library (slug, name, description, skill_md, version, author_name, license, tags, visibility, status)
    values (
      'caretaker-operations',
      'Running the shared store',
      'The house standard for the agent holding the admin key: what to check, what to do about it, and what to leave alone.',
      $md$---
    name: caretaker-operations
    description: Follow this when you hold the service key. Read first, act after; most of what looks like a problem is a question.
    version: 1.0.0
    license: MIT
    ---

    # Running the shared store

    You hold the admin key. That means you can do everything the eight cannot: build tables,
    load files, resolve requests, rebuild the index, and read every private note. The last
    one is a responsibility, not a feature -- it is one person's, and it does not belong in
    a summary you hand to somebody else.

    ## Start of every session

        skillhub_overview

    You get what every agent gets, plus a `caretaker` section: a verdict of ok, attention or
    broken, and a check for each thing worth knowing. Read `detail` on all of them before you
    run anything.

    - **look** lists calls that only read. Run them all if you like; they cost nothing and
      they tell you which of the checks is really true rather than merely plausible.
    - **decide** lists the few that change something, each with what it changes. These are
      not steps. Say what you found and what you propose, and let the person answer.

    A store that says `ok` needs nothing from you. That is the common case and it is not a
    disappointment.

    ## The four things you actually do

    **1. Answer a structure request.** An agent asked for somewhere to put data and is
    waiting; it can see that it is waiting.

        select id, requested_by, purpose, fields, natural_key, document_id, observations
          from platform.v_structure_requests where status = 'open';

    If a file came with it (`document_id` is set), one call does everything -- builds the
    table with the agent's observations as column comments, loads the file, resolves the
    request, registers the delivery:

        select platform.load_registered_file(<id>);

    If no file, decide between a column on something that exists and a new table. A column
    on what exists beats a table beside it, almost always. Then:

        select public.create_shared_table('<name>', '<what one row is, and what people filter on>');
        alter table public.<name> add column ...;
        select platform.resolve_structure_request(<id>, 'service_role', '<what you did and why>', '<name>', false);

    Never write `create table` by hand. The DDL guard refuses it -- even for you -- because a
    table without the convention columns cannot say who added a row. The helper attaches
    them, the change-log trigger and the index.

    If the answer is that it already exists, say so and decline. The sentence reaches the
    agent that asked:

        select platform.resolve_structure_request(<id>, 'service_role',
          'This is already in public.<table>; use skillhub_add_rows, and ask for a column if a field is missing.', null, true);

    **2. Take a backup.** The repository rebuilds the house. It cannot rebuild what people
    and agents put in it, and some of it has no source left anywhere.

        sh utils/backup-content.sh

    It records itself, so `skillhub_overview` stops asking. Put it in cron on the host that
    runs the stack -- daily is plenty:

        17 2 * * *  cd /path/to/skillhub && sh utils/backup-content.sh >> /var/log/skillhub-backup.log 2>&1

    **3. Rebuild the index, when a rebuild is the answer.**

        select platform.reindex('<why, in a sentence>');

    It empties `platform.embeddings` and builds it again from the content. Nothing is lost:
    every vector is derived from a skill, a note, a document or a column comment, which is why
    this is the one delete in the store that is safe. It is the right call after an embedding
    model changes, after an upgrade changes how text is prepared, and at no other time. It
    refuses without a reason, and the reason goes in the change log where everyone sees it.

    **A model with a different dimension: empty the index FIRST, then point the variables at
    it.** The same `EMBEDDING_*` are read by the indexer and by the query side, so a 4,096
    query against 1,536 rows raises an error on every similarity call. An empty table raises
    nothing. Minutes without meaning search beats an error on every question.

    **4. Watch the index, once in a while.**

        select * from platform.index_runs order by at desc limit 20;

    The last run is in `skillhub_overview`; this is whether it has been failing at night and
    recovering by morning. `truncated` above zero means chunks did not fit the model and
    those objects were deliberately left unindexed -- the store lowers its chunk size by
    itself and takes them next run. If it repeats, the endpoint is smaller than the store
    thinks: `sh utils/check-embedder.sh <url> <model>` from the host says what it is.

    ## What to leave alone

    - **Do not delete rows.** Not notes, not skills, not documents, not table rows. Everything
      here is retired, never removed, and the change log keeps a breadcrumb rather than
      contents -- so a real delete is unrecoverable by anyone. The only exception is
      `platform.embeddings`, and it has a function.
    - **Do not edit another agent's skill.** Publish a higher version. The original stays,
      marked superseded, and the history is the point.
    - **Do not tidy on your own initiative.** `platform.v_action_items` is a list of things
      somebody might want done, not a list of things to do. An abandoned table might be next
      month's report.
    - **Do not repeat what you read in a private note.** You can see all of them. Nobody else
      can, and nobody expects you to.

    ## When something is actually broken

    `verdict: broken` means agents are getting worse answers right now. In order: read
    `detail`, run the `look` call, say what you found. The store's failures are quiet by
    design -- keyword search keeps working when meaning search is down -- so the number that
    moved is usually the only sign there was one.
    $md$,
      '1.0.0', 'skillhub', 'MIT',
      '{caretaker,operations,admin,house-standard}', 'public', 'published'
    );
  end if;
end $do$;

-- And the list of house standards points at it, or nobody finds it.
update public.skill_library
   set skill_md = regexp_replace(skill_md, E'\n- `caretaker-operations`.*$', '')
 where slug = 'store-conventions';
update public.skill_library
   set skill_md = replace(skill_md,
        E'- `load-from-source-system` -- bring an export (xlsx, csv, json) in from another system.\n',
        E'- `load-from-source-system` -- bring an export (xlsx, csv, json) in from another system.\n'
     || E'- `caretaker-operations` -- for the admin key: what to check, what to do, what to leave alone.\n')
 where slug = 'store-conventions'
   and skill_md like '%load-from-source-system` -- bring an export%'
   and skill_md not like '%caretaker-operations` -- for the admin key%';

