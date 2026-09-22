-- The overview layer for the shared store.
-- Run AFTER demo/conventions.sql. Everything lands in the `platform` schema so that
-- list_tables on `public` keeps being about the organisation's data.
--
-- The point: make the store self-describing. A new agent should be able to ask ONE
-- question and understand what exists, who owns it and what happened last. A person
-- should see the same without knowing SQL.
--
-- On the text search configuration: 'swedish' throughout, deliberately. The house is
-- English but the content is not -- the organisation writes in Swedish, and stemming
-- matters more for recall on content than it costs on English skill text, which still
-- matches at word level. This is a property of the data, not of the code.

create schema if not exists platform;
comment on schema platform is 'Overview and traceability for the shared store. Read from here, write in public.';

create extension if not exists pg_trgm;

-- ---------------------------------------------------------------------------
-- 1) Change log: every write to a shared table leaves a trace.
-- ---------------------------------------------------------------------------
create table if not exists platform.events (
  id          bigserial primary key,
  at          timestamptz not null default now(),
  table_name  text not null,
  operation   text not null check (operation in ('insert','update','delete')),
  row_id      text,
  agent       text,                 -- from the row's own owner/created_by/updated_by
  visibility  text,
  summary     text
);
create index if not exists events_at_idx on platform.events (at desc);
create index if not exists events_agent_idx on platform.events (agent, at desc);
comment on table platform.events is 'Who wrote what, when. Filled by a trigger on every table made with create_shared_table().';
comment on column platform.events.agent is 'Taken from the row''s own columns (updated_by/created_by/owner). It assumes the agent followed the convention -- see platform.v_caveats.';

create or replace function platform.log_change() returns trigger
language plpgsql security definer set search_path = public, platform as $$
declare
  r record;
  a text;
  vis text;
  rid text;
  txt text;
begin
  -- An update that changed nothing but its own timestamp is not a change. Until 2026-09-16
  -- every boot re-applied the house rules to rows that already held them, and the log
  -- recorded each one: of 242 writes in a day, 223 were the store telling itself what it
  -- already knew. The caretaker, asked how the store was doing, flagged it as a write loop
  -- worth investigating -- correctly -- and that is what a log full of noise costs: real
  -- events read as suspicious and suspicious ones get lost.
  if tg_op = 'UPDATE'
     and (to_jsonb(new) - array['updated_at','updated_by']) = (to_jsonb(old) - array['updated_at','updated_by']) then
    return null;
  end if;
  r := coalesce(new, old);
  begin a := coalesce(to_jsonb(r) ->> 'updated_by', to_jsonb(r) ->> 'created_by', to_jsonb(r) ->> 'owner', to_jsonb(r) ->> 'author_name'); exception when others then a := null; end;
  begin vis := to_jsonb(r) ->> 'visibility'; exception when others then vis := null; end;
  begin rid := to_jsonb(r) ->> 'id'; exception when others then rid := null; end;
  begin
    txt := coalesce(to_jsonb(r) ->> 'title', to_jsonb(r) ->> 'name', to_jsonb(r) ->> 'slug');
  exception when others then txt := null; end;
  insert into platform.events (table_name, operation, row_id, agent, visibility, summary)
  values (tg_table_name, lower(tg_op), rid, a, vis, left(txt, 200));
  return null;
end $$;

-- Attach the change log to an existing table. The name says what it does: it attaches
-- the logging trigger. It does NOT save the row's contents anywhere -- an earlier name
-- ("save history") implied a restore that does not exist, and misled two readers.
create or replace function platform.attach_change_log(table_name text) returns void
language plpgsql as $$
begin
  execute format('drop trigger if exists platform_log_change on public.%I', table_name);
  execute format('create trigger platform_log_change after insert or update or delete on public.%I for each row execute function platform.log_change()', table_name);
end $$;

-- ---------------------------------------------------------------------------
-- 2) The template from conventions.sql now logs automatically.
-- ---------------------------------------------------------------------------
-- A speed bump on creating structures, and an honest label on what it is.
--
-- The worry that produced this: if every missing column becomes a new table, the caretaker
-- adds four hundred of them and the data model we are establishing dies. Measured the same
-- day: nothing constrained table creation beyond the convention columns, and no view showed
-- the count over time.
--
-- What this is NOT. The caretaker holds raw SQL by design, and the DDL guard admits any
-- well-formed table -- demonstrated when a 36,645-row table passed it. So requiring a search
-- here is a speed bump for the caretaker, not a wall, and pretending otherwise would be the
-- same mistake as trusting that agents would use the helper because it was nicer. For the
-- caretaker the real constraints are the rule about grain, written into the placement rule,
-- and the fact that the count is now visible in the daily report.
create or replace function public.create_shared_table(table_name text, description text default null)
returns void language plpgsql as $$
declare caller text := current_setting('platform.agent', true);
begin
  if description is null or btrim(description) = '' then
    raise exception 'A description is required. A table nobody described is a table nobody can find: it is what the next agent reads instead of your session.';
  end if;
  if table_name !~ '^[a-z][a-z0-9_]{2,}$' then
    raise exception 'Invalid table name "%". Lowercase letters, digits and underscores, at least three characters.', table_name;
  end if;

  -- A structure that already nearly exists should gain a column, not a sibling. The grain
  -- decides: a table is defined by what ONE ROW is. Same grain, one more field -> alter the
  -- table. Different grain -> a new one.
  --
  -- One exception, and it is what makes the seed re-runnable: an EXACT name that already
  -- carries the four convention columns is this same table being declared again, not a
  -- near-duplicate of itself. It falls through, and the rest of this function refreshes the
  -- trigger, the index and the comments. Without this, utils/seed.sh could run once and
  -- never again -- including against production, where documents and notes already exist.
  -- Found 2026-09-14 by seeding a scratch database twice.
  if not exists (
        select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
         where n.nspname='public' and c.relkind='r' and c.relname = table_name
           and (select count(*) from pg_attribute a
                 where a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
                   and a.attname in ('owner','visibility','created_by','updated_by')) = 4)
     and exists (select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
              where n.nspname='public' and c.relkind='r'
                and (c.relname = table_name
                     or similarity(c.relname, table_name) > 0.55)) then
    raise exception using
      errcode = 'duplicate_table',
      message = format(
        'There is already a table with a name close to "%s" -- see platform.v_catalog. If one row would mean the SAME KIND OF THING as a row in that table, add a column to it instead: alter table public.<existing> add column ... . '
        'Create a new table only when one row means a different kind of thing. Four hundred near-duplicate tables is how a shared store stops being one.',
        table_name);
  end if;

  execute format($f$
    create table if not exists public.%1$I (
      id          uuid primary key default gen_random_uuid(),
      owner       text not null,
      visibility  text not null default 'public' check (visibility in ('public','team','private')),
      created_by  text not null,
      updated_by  text not null,
      created_at  timestamptz not null default now(),
      updated_at  timestamptz not null default now()
    )$f$, table_name);
  execute format('alter table public.%I enable row level security', table_name);
  execute format('drop trigger if exists set_updated_at on public.%I', table_name);
  execute format('create trigger set_updated_at before update on public.%I for each row execute function public.set_updated_at()', table_name);
  execute format('create index if not exists %I on public.%I (owner, visibility)', table_name || '_owner_visibility_idx', table_name);
  execute format('comment on table public.%I is %L', table_name, description);
  execute format('comment on column public.%I.owner is %L', table_name, 'The agent identifier, agent_NN. Set by the agent on insert.');
  execute format('comment on column public.%I.visibility is %L', table_name, 'public = everyone may read, team = agents in the owner''s team (public.agents.team), private = the owner only. The caretaker reads all three.');
  execute format('comment on column public.%I.created_by is %L', table_name, 'Who created the row. Set by the agent.');
  execute format('comment on column public.%I.updated_by is %L', table_name, 'Who last changed the row. Set by the agent on every update.');
  perform platform.attach_change_log(table_name);
end $$;

-- Tables made before 2026-09-18 carry the two-value check the template had then, and the
-- skill library its own three (unlisted is a library notion, kept). Widened here on every
-- boot: the loop finds nothing once every constraint names team, so a boot over an
-- up-to-date store alters nothing. A constraint is dropped and re-added, which scans the
-- table once -- at this store's scale, milliseconds.
do $$
declare r record; allowed text;
begin
  for r in
    select c.conrelid::regclass as rel, c.conname, c.conrelid::regclass::text as name
    from pg_constraint c join pg_namespace n on n.oid = c.connamespace
    where n.nspname = 'public' and c.contype = 'c'
      and pg_get_constraintdef(c.oid) ilike '%visibility%'
      and pg_get_constraintdef(c.oid) not ilike '%''team''%'
  loop
    allowed := case when r.name = 'skill_library' then '''public'',''team'',''unlisted'',''private'''
                    else '''public'',''team'',''private''' end;
    execute format('alter table %s drop constraint %I', r.rel, r.conname);
    execute format('alter table %s add constraint %I check (visibility in (%s))', r.rel, r.conname, allowed);
    raise notice 'visibility on % now allows team', r.rel;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 3) Catalog: what exists, who owns it, when it last changed.
-- ---------------------------------------------------------------------------
-- reltuples is -1 until a table has been analysed; in a small shared store an exact
-- count is both fast and honest.
create or replace function platform.row_estimate(table_name text) returns bigint
language plpgsql stable as $$
declare n bigint;
begin
  execute format('select count(*) from public.%I', table_name) into n;
  return n;
exception when others then return null;
end $$;

create or replace view platform.v_catalog as
select
  c.relname                                        as table_name,
  obj_description(c.oid)                           as description,
  platform.row_estimate(c.relname)                 as rows,
  pg_size_pretty(pg_total_relation_size(c.oid))    as size,
  c.relrowsecurity                                 as row_security,
  (select count(*) from pg_attribute a
     where a.attrelid = c.oid and a.attname in ('owner','visibility','created_by','updated_by')) = 4
                                                   as follows_convention,
  exists (select 1 from pg_trigger t
     where t.tgrelid = c.oid and t.tgname = 'platform_log_change') as logged,
  (select max(e.at) from platform.events e where e.table_name = c.relname) as last_changed,
  (select count(distinct e.agent) from platform.events e where e.table_name = c.relname) as agents
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind in ('r','v')
order by 1;
comment on view platform.v_catalog is 'One row per table or view in public: description, size, whether it follows the convention and when it last changed.';

-- ---------------------------------------------------------------------------
-- 4) Activity: what happened, and who does what.
-- ---------------------------------------------------------------------------
create or replace view platform.v_activity as
select at, agent, operation, table_name, coalesce(summary,'') as what, visibility
from platform.events
order by at desc;
comment on view platform.v_activity is 'The raw feed, newest first. Prefer v_flow, which survives a bulk load.';

create or replace view platform.v_last_24h as
select date_trunc('day', at)::date as day,
       coalesce(agent,'(unknown)')  as agent,
       count(*) filter (where operation='insert') as inserted,
       count(*) filter (where operation='update') as updated,
       count(*) filter (where operation='delete') as deleted,
       count(distinct table_name)                 as tables
from platform.events
group by 1,2 order by 1 desc, 2;
comment on view platform.v_last_24h is 'Activity per day and agent. Shows who actually contributes.';

-- Merged per minute. Found in testing: an agent writing 350 measurements filled the
-- feed with 350 rows and hid everything else that had happened. The raw log is kept;
-- the feed a person actually reads collapses same agent + table + operation per minute.
create or replace view platform.v_flow as
select min(at)::timestamp(0)        as from_at,
       max(at)::timestamp(0)        as to_at,
       coalesce(agent,'(unknown)')  as agent,
       operation, table_name,
       count(*)                     as rows,
       case when count(*) = 1 then max(coalesce(summary,''))
            else left(string_agg(distinct coalesce(summary,''), ', '), 120) end as what
from platform.events
group by date_trunc('minute', at), agent, operation, table_name
order by 1 desc;
comment on view platform.v_flow is 'Activity collapsed per minute, agent, table and operation. Read this one, not v_activity, when something wrote a lot in a short time.';

-- ---------------------------------------------------------------------------
-- 5) Skills: the library as a package registry, not a pile of files.
-- ---------------------------------------------------------------------------
create or replace view platform.v_skills as
select s.slug, s.name, s.version, s.author_name as author,
       s.visibility, s.status,
       cardinality(s.tags)          as tag_count,
       length(s.skill_md)           as characters,
       s.downloads,
       s.updated_at::timestamp(0)   as updated,
       (now() - s.updated_at) > interval '90 days' as stale,
       case
         when s.description = '' or s.description is null then 'no description'
         when cardinality(s.tags) = 0 then 'no tags'
         when length(s.skill_md) < 200 then 'very short'
         when s.skill_md not like '---%' then 'no frontmatter'
       end                          as remark
from public.skill_library s
order by s.updated_at desc;
comment on view platform.v_skills is 'Skills with quality flags: missing description, tags, frontmatter, or content too short to help.';

-- One row per slug: the newest version that is not deprecated. Every reader of the library
-- that means "the skill" rather than "a row of skill_library" goes through this view.
--
-- Found 2026-09-15 on the demo store, the morning after a colleague improved another agent's
-- skill -- the flow the library exists for. Two published versions of one slug made three
-- things break at once: skillhub_similar failed outright ("more than one row returned by a
-- subquery used as an expression"), keyword search returned the slug twice, and the indexer
-- re-embedded the slug on every run because both versions qualified as candidates and the
-- embedding is keyed by slug. None of it showed in development, where test versions were
-- retired the moment the test ended.
create or replace view platform.v_current_skills as
select distinct on (s.slug) s.*
from public.skill_library s
where s.status <> 'deprecated'
order by s.slug, string_to_array(s.version,'.')::int[] desc;
comment on view platform.v_current_skills is 'The newest non-deprecated version of every skill, one row per slug. Search, similarity and the indexer read this, never skill_library directly.';

-- Possible duplicates, by trigram similarity on name and slug.
create or replace view platform.v_duplicates as
select a.slug as slug_a, b.slug as slug_b,
       round(similarity(a.name, b.name)::numeric, 2) as name_similarity,
       round(similarity(a.slug, b.slug)::numeric, 2) as slug_similarity
from public.skill_library a
join public.skill_library b on a.id < b.id
where similarity(a.name, b.name) > 0.45 or similarity(a.slug, b.slug) > 0.45
order by 3 desc nulls last;
comment on view platform.v_duplicates is 'Skills that resemble each other. Check before publishing a new one.';
-- platform.ddl_log is created here, well above the guard that fills it, because the
-- views below SELECT from it and a view is resolved the moment it is created. The table
-- used to live with the guard near the end of this file: fine on a database where it
-- already existed, a hard failure on an empty one. Found 2026-09-14 by seeding a
-- scratch database. Function bodies referring forward are harmless -- plpgsql is not
-- parsed until it runs -- but views and the statements above are not function bodies.
create table if not exists platform.ddl_log (
  id       bigserial primary key,
  at       timestamptz not null default now(),
  role     text not null,
  command  text not null,
  object   text
);
comment on table platform.ddl_log is 'Every schema change: when, by which database role, which command. Filled by an event trigger.';

-- v_abandoned_tables is defined BEFORE v_action_items because the to-do list selects
-- from it. It used to sit further down: harmless on a database where the view already
-- existed from an earlier run, and a hard failure on an empty one. Found 2026-09-14 by
-- seeding a scratch database, which is the only way a forward reference like this shows.
-- A table that arrived and was never written to again is the signature of a structure created
-- instead of a column added.
create or replace view platform.v_abandoned_tables as
select c.table_name, c.rows, c.description,
       (select min(d.at)::date from platform.ddl_log d
         where d.command = 'CREATE TABLE' and d.object = 'public.'||c.table_name) as created,
       c.last_changed
from platform.v_catalog c
where c.follows_convention
  -- Rows with no logged write are not abandoned: a table can be filled by a restore or by
  -- the caretaker before the log was attached. Empty, or written to and then left, is the signal.
  and (c.rows = 0 or (c.rows > 0 and c.last_changed < now() - interval '30 days'));
comment on view platform.v_abandoned_tables is 'Tables with no rows, or untouched for a month. Usually a structure that should have been a column on something that already existed.';


-- ---------------------------------------------------------------------------
-- 6) Health check: what needs tidying.
-- ---------------------------------------------------------------------------
create or replace view platform.v_action_items as
select 'table without row security' as kind, table_name as object,
       'run: alter table public.'||table_name||' enable row level security' as action
from platform.v_catalog where row_security is false and rows is not null
union all
select 'table without change log', table_name,
       'run: select platform.attach_change_log('''||table_name||''')'
from platform.v_catalog where logged is false and follows_convention
union all
select 'table without description', table_name,
       'run: comment on table public.'||table_name||' is ''...'''
from platform.v_catalog where description is null
union all
select 'skill: '||coalesce(remark,'?'), slug, 'complete the skill'
from platform.v_skills where remark is not null
union all
select 'skill stale (>90 days)', slug, 'verify it or mark it deprecated'
from platform.v_skills where stale
union all
-- A structure created instead of a column added. Cheap to spot, expensive to leave:
-- the store does not die of one bad table, it dies of forty.
select 'table empty or untouched >30 days', table_name,
       'was this a column on something that already existed? see platform.v_abandoned_tables'
from platform.v_abandoned_tables;
comment on view platform.v_action_items is 'The store''s to-do list. An empty list means everything is in order.';

-- Growth, visible. A list of tables says what exists; it does not say that there were seven
-- in September and forty-three now. A number that grows where people look is the cheapest
-- brake there is, and it is the same move as everywhere else today: do not prevent, make
-- visible.
create or replace view platform.v_growth as
with per_month as (
  select date_trunc('month', at)::date as month,
         count(*) filter (where command = 'CREATE TABLE') as tables_created,
         count(*) filter (where command like 'DROP %')    as objects_dropped
  from platform.ddl_log
  group by 1
)
select month, tables_created, objects_dropped,
       sum(tables_created) over (order by month) as tables_total
from per_month order by month desc;
comment on view platform.v_growth is 'Tables created per month, and the running total. Read it when the store starts feeling large: four hundred near-duplicate tables is how a shared store stops being one.';


-- ---------------------------------------------------------------------------
-- 7) One question that answers "what is here?" -- for an agent and for a person.
-- ---------------------------------------------------------------------------
create or replace function platform.overview() returns table (label text, value text)
language sql stable as $$
  select 'tables in public', count(*)::text from platform.v_catalog
  union all select 'of which follow the convention', count(*)::text from platform.v_catalog where follows_convention
  union all select 'skills published', count(*)::text from public.skill_library where status='published'
  union all select 'active agents (30 days)', count(distinct agent)::text from platform.events where at > now() - interval '30 days'
  union all select 'writes in the last day', count(*)::text from platform.events where at > now() - interval '1 day'
  union all select 'last event', coalesce(to_char(max(at),'YYYY-MM-DD HH24:MI'),'--') from platform.events
  union all select 'items to act on', count(*)::text from platform.v_action_items;
$$;
comment on function platform.overview() is 'Seven numbers that summarise the store. Run it first.';

-- ---------------------------------------------------------------------------
-- 8) Caveats: what the log does NOT prove.
-- ---------------------------------------------------------------------------
create or replace view platform.v_caveats as
-- Rewritten 2026-09-14. The previous four caveats all described the world before the raw
-- SQL door moved behind the admin group on the 12th, and they were still telling agents that
-- the owner column is self-declared and that identity is not verifiable. Both were true then
-- and neither is true now. A stale caveat is worse than a missing one: a colleague's agent
-- read the old text, reported identity spoofing as an open risk, and was right about the
-- text and wrong about the system.
select unnest(array[
  'WHO wrote a row is taken from the gateway, not from the caller. Every write tool overwrites the agent argument with the identity Kong resolved from the API key, and there is no other write path for an agent key. Verified 2026-09-14: a write made with one key while claiming another -- in the argument AND in a hand-forged x-consumer-username header -- landed with the calling key in owner, created_by and updated_by, and the change log recorded the same.',
  'What the key does NOT prove is WHO is behind it. It binds a call to agent_NN, not agent_NN to a person: the display name and role in public.agents are rows somebody filled in about themselves, and a key sitting on two machines is one identity in the log. Trace to a person only as far as those two facts allow.',
  'DELETE keeps no contents anywhere -- the log stores table, operation, row id, agent and a summary, never the row. An agent key cannot delete at all; skillhub_retire marks the row and leaves it readable. The caretaker can delete, through raw SQL, and nothing in the database will stop it. That is the one irreversible act in this store.',
  'TEAM is a row in public.agents that the caretaker typed. A team row is shared with whoever has the same word there, and the word proves membership the way a name tag does. Wrong team, wrong readers.',
  'Everything defaults to PUBLIC. Private is a flag the writer has to set, so a forgotten flag is a disclosure to everyone here, not an error. And private means other agents cannot read it -- the caretaker''s key ignores row security entirely, so private is not a place for anything that would matter if an administrator read it.',
  'The key is in clear text in the config file on the device that holds it. Whoever holds the machine holds that agent''s identity and everything public in the store. If a machine goes missing, rotate that slot and recreate the gateway container -- a restart is not enough, because the list of permitted callers is rendered at container creation.'
]) as caveat;
comment on view platform.v_caveats is 'Read this before trusting the numbers. What the log shows and what it does not prove.';

-- ---------------------------------------------------------------------------
-- 9) Privileges, and attaching the log to tables that already exist.
-- ---------------------------------------------------------------------------
grant usage on schema platform to service_role;
alter default privileges in schema platform grant select on tables to service_role;

do $$
declare t text;
begin
  for t in
    select c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relkind='r'
  loop
    perform platform.attach_change_log(t);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 10) Finding things: keyword search now, semantic search once the vectors fill.
-- ---------------------------------------------------------------------------
-- Filters on ownership through platform.may_read: a private note or document belongs to
-- its owner alone, a team one to the owner's team. The third argument is the agent the
-- gateway verified; null means public only, so a caller that forgets to pass an identity
-- sees less and never more.
-- platform.search() is defined in platform_lifecycle.sql: it reads platform.v_current_skills and
-- honours the retire columns. An older copy lived here and won whenever a later file failed.

create index if not exists skill_library_fts_idx on public.skill_library
  using gin (to_tsvector('swedish', coalesce(name,'')||' '||coalesce(description,'')||' '||coalesce(skill_md,'')));
create index if not exists notes_fts_idx on public.notes
  using gin (to_tsvector('swedish', coalesce(title,'')||' '||coalesce(content,'')));

-- Semantic search. The model lives outside the database, so the vectors are written by
-- the embedding job (see platform_embed.sql), not computed here. 1536 matches the common
-- text-embedding models. The model name is stored per row: vectors from different models
-- must NEVER be compared with each other.
create extension if not exists vector;

create table if not exists platform.embeddings (
  source       text not null,              -- 'skill' | 'note' | 'document'
  id           text not null,
  model        text not null,
  vector       vector(1536) not null,
  text_hash    text not null,              -- md5 of the text that was embedded
  created_at   timestamptz not null default now(),
  primary key (source, id, model)
);
-- One vector per CHUNK since 2026-09-16, not per object. A 14,000-character skill was one
-- vector: only what fit the model's context was embedded, and an embedder built for RAG
-- (512-2048 tokens) refused it outright. Chunks are cut on the object's own headings, each
-- prefixed with its title; similarity search returns the object once, at its best chunk,
-- and names the section (head) it matched in.
alter table platform.embeddings add column if not exists chunk int not null default 0;
alter table platform.embeddings add column if not exists head text;
do $pk$
begin
  if not exists (select 1 from pg_constraint c
                  where c.conrelid = 'platform.embeddings'::regclass and c.contype = 'p'
                    and array_length(c.conkey, 1) = 4) then
    alter table platform.embeddings drop constraint if exists embeddings_pkey;
    alter table platform.embeddings add primary key (source, id, model, chunk);
  end if;
end $pk$;
comment on table platform.embeddings is 'One embedding per chunk of an object and model. Filled by the embedding job. text_hash (of the whole object) decides whether it is out of date; head is the first line of the chunk, so a hit can say which section matched.';
-- The index has to match the dimension the column happens to carry, which is not 1,536 on
-- an instance whose model returns something else: HNSW takes vector up to 2,000 and
-- halfvec up to 4,000, and refuses outright above that. Written unconditionally until
-- 2026-09-16, when the seed failed on the first instance running a 4,096-dimension model
-- -- and because platform.sql failed, every file after it was skipped. Same three branches
-- as platform.set_vector_dim(), which owns this from platform_vector.sql onwards.
do $idx$
declare d int;
begin
  if to_regclass('platform.embeddings_vector_idx') is not null then return; end if;
  select atttypmod into d from pg_attribute
   where attrelid = 'platform.embeddings'::regclass and attname = 'vector';
  if d <= 2000 then
    execute 'create index embeddings_vector_idx on platform.embeddings using hnsw (vector vector_cosine_ops)';
  elsif d <= 4000 then
    execute format('create index embeddings_vector_idx on platform.embeddings using hnsw ((vector::halfvec(%s)) halfvec_cosine_ops)', d);
  end if;   -- above 4,000 there is no index; searches are exact scans, which is fine here
end $idx$;

-- platform.similar() is built by platform.rebuild_similar() in platform_vector.sql, because its
-- signature carries the dimension. It used to be defined here too, at vector(1536), and on the
-- second seed run the two definitions collided (2026-09-16).

-- What has no embedding yet, so the job knows what is left.
create or replace view platform.v_not_indexed as
select 'skill' as source, s.slug as id, s.name as title
from public.skill_library s
where not exists (select 1 from platform.embeddings e where e.source='skill' and e.id=s.slug)
union all
select 'note', n.id::text, n.title
from public.notes n
where n.visibility='public'
  and not exists (select 1 from platform.embeddings e where e.source='note' and e.id=n.id::text);
comment on view platform.v_not_indexed is 'Objects without an embedding. Private rows are absent on purpose -- they are never indexed, so they can never be found by meaning.';

-- Reads leave a trace too, narrowly.
--
-- The change log records writes only, which was enough until the gate needed to ask "did you
-- look first?". Measured 2026-09-12: an agent answered a quality question thirty-eight times
-- too high because it never searched, and publishing was the one moment where searching can
-- be required in code rather than requested in a prompt.
--
-- Deliberately narrow. Only the tools that constitute looking are recorded, with the query
-- text so the agent can be told what it searched, and rows older than seven days are dropped
-- by the same job that keeps the index current. This is not a record of everything an agent
-- reads: skillhub_read, query and overview are NOT logged here. That line is a privacy
-- choice on a store shared by eight people, and it is written down rather than assumed.
create table if not exists platform.tool_log (
  id     bigserial primary key,
  at     timestamptz not null default now(),
  agent  text not null,
  tool   text not null,
  query  text
);
create index if not exists tool_log_agent_idx on platform.tool_log (agent, at desc);
comment on table platform.tool_log is 'Searches, per agent. Kept seven days. Exists so publishing can require that a search happened first; it is not a record of everything an agent reads.';

create or replace function platform.note_search(agent text, tool text, query text) returns void
language sql as $$
  insert into platform.tool_log (agent, tool, query) values (agent, tool, left(coalesce(query,''), 300));
$$;



-- Publishing requires that a search happened. This is the gate's second half, and the reason
-- it exists is a single measurement: two agents produced the identical wrong number while the
-- right answer sat in the store, because nothing made either of them look.
--
-- Fifteen minutes, not a session: a session has no boundary the database can see, and an
-- agent that searched half an hour ago and has been writing since is not the case this
-- protects against.
create or replace function platform.searched_recently(agent text) returns boolean
language sql stable as $$
  select exists (select 1 from platform.tool_log l
                  where l.agent = searched_recently.agent
                    and l.tool in ('search','similar')
                    and l.at > now() - interval '15 minutes');
$$;

grant select on platform.tool_log to service_role;
grant select, delete on platform.tool_log to postgres;

-- A channel for "this is the same shape over and over and there is nowhere to put it".
--
-- Found in a simulation on 2026-09-12. An agent was handed three supplier audit results and
-- could not create a table, so it wrote them up as a markdown note -- correctly, by the
-- placement rule, since three records fail the "more than ~20" test. Nobody can now filter on
-- score or group by auditor. Another agent, handed an ERP export, declined to guess and asked
-- for a target table that nobody could give it, so nothing landed at all. Two failures in
-- opposite directions, and in both the need appeared and vanished without anyone seeing it.
--
-- Agents still cannot create structures: that is what keeps the data model deliberate. What
-- they get instead is a way to ASK, and the caretaker gets a queue it can see. The point is not
-- politeness -- it is that the caretaker is the only party that sees every request, so it is the
-- only one that can notice two people asking for the same thing.
create table if not exists platform.structure_requests (
  id             bigserial primary key,
  at             timestamptz not null default now(),
  requested_by   text not null,
  purpose        text not null,
  suggested_name text,
  fields         jsonb not null,
  sample_rows    jsonb,
  status         text not null default 'open' check (status in ('open','done','declined')),
  resolved_at    timestamptz,
  resolved_by    text,
  resolution     text,
  table_name     text
);
create index if not exists structure_requests_status_idx on platform.structure_requests (status, at desc);
comment on table platform.structure_requests is 'Agents asking for somewhere to put structured data. The caretaker resolves each one as a column on an existing table or a new one. It is the only queue that sees every request, which is what makes duplication visible.';
comment on column platform.structure_requests.sample_rows is 'The rows the agent was holding, so the data survives the wait. Samples, not a load: more than a couple of hundred rows is a delivery for the caretaker.';

-- What the caretaker looks at.
-- What an agent noticed about the data travels WITH the request. Measured 2026-09-15: an
-- agent found a sentinel and a casing problem in an export, said both to the user, and the
-- request it filed carried neither -- so the caretaker built the table without them and six
-- sentinel rows were loaded as real hours. observations is where that goes now, and the
-- caretaker's loader writes it into the column comments. document_id points at the uploaded
-- file (the transport for the rows; see DECISIONS.md section 20), natural_key is the column a
-- monthly re-delivery upserts on, target_table is set when the agent means an existing table.
alter table platform.structure_requests add column if not exists observations text[];
alter table platform.structure_requests add column if not exists document_id uuid;
alter table platform.structure_requests add column if not exists natural_key text;
alter table platform.structure_requests add column if not exists target_table text;
comment on column platform.structure_requests.observations is 'What the requesting agent noticed about the data: sentinels, spellings, units. The loader writes these into column comments so the next reader is warned.';
comment on column platform.structure_requests.document_id is 'The registered, uploaded file the rows come from. The loader reads it from Storage; no row passes through a language model.';
comment on column platform.structure_requests.natural_key is 'The column a re-delivery upserts on, e.g. ticket_no.';

-- Dropped first: a view cannot gain columns in the middle through create or replace, and
-- the four new ones sit before status so the caretaker sees them where it reads.
drop view if exists platform.v_structure_requests;
create or replace view platform.v_structure_requests as
select r.id, r.at::timestamp(0) as asked, r.requested_by, r.purpose, r.suggested_name,
       (select string_agg(f #>> '{}', ', ') from jsonb_array_elements(r.fields) f) as fields,
       coalesce(jsonb_array_length(r.sample_rows), 0) as sample_rows,
       r.observations, r.document_id, r.natural_key, r.target_table,
       r.status, r.resolved_by, r.resolved_at::timestamp(0) as resolved, r.resolution, r.table_name
from platform.structure_requests r
order by (r.status = 'open') desc, r.at desc;

-- The bucket uploaded files land in. Private: only the service key reads it, which is the
-- loader. Guarded, because a bare Postgres from the same image has no storage schema until
-- the storage service has run its migrations -- the seed must still pass there.
do $b$
begin
  if to_regclass('storage.buckets') is not null then
    insert into storage.buckets (id, name, public) values ('deliveries', 'deliveries', false)
    on conflict (id) do nothing;
  else
    raise notice 'storage.buckets not present: the deliveries bucket is created on the first seed after the storage service has started.';
  end if;
end $b$;
comment on view platform.v_structure_requests is 'Structure requests, open ones first. Resolve with platform.resolve_structure_request().';

-- SECURITY DEFINER: the caretaker arrives as service_role, which has select on this table and
-- not update. Found when the caretaker did its rounds, created the table the request asked for,
-- and then could not close the request -- leaving an open request whose work was already done,
-- which is worse than no queue at all.
create or replace function platform.resolve_structure_request(
  request_id bigint, resolved_by text, resolution text, table_name text default null,
  declined boolean default false) returns text
language plpgsql security definer set search_path = public, platform as $$
declare n int;
begin
  if resolution is null or length(btrim(resolution)) < 10 then
    raise exception 'Say what you did. The agent that asked will read this, and so will the next person who wonders why the table looks the way it does.';
  end if;
  update platform.structure_requests
     set status = case when declined then 'declined' else 'done' end,
         resolved_at = now(), resolved_by = resolve_structure_request.resolved_by,
         resolution = btrim(resolve_structure_request.resolution),
         table_name = resolve_structure_request.table_name
   where id = request_id and status = 'open';
  get diagnostics n = row_count;
  if n = 0 then raise exception 'No open request with id %.', request_id; end if;
  return format('Request %s marked %s.', request_id, case when declined then 'declined' else 'done' end);
end $$;
comment on function platform.resolve_structure_request is 'Close a structure request. Say what you did: the agent that asked reads it.';

grant select on platform.structure_requests, platform.v_structure_requests to service_role;
grant execute on function platform.resolve_structure_request(bigint,text,text,text,boolean) to service_role, postgres;

-- ---------------------------------------------------------------------------
-- 11) The placement rule: what belongs where.
--
-- The problem it solves: an agent, like an employee, faces "new table, note, skill or
-- file?" and answers differently every time. Free choice produces disorder. The fix is
-- NOT more formats but a closed vocabulary and a decision order the agent reads each
-- time. The vector index is deliberately NOT a fourth option: an embedding is an index
-- over text that already lives somewhere, not a place to put things.
-- ---------------------------------------------------------------------------
create or replace function platform.placement_rule() returns text
language sql immutable as $$
select $t$PLACEMENT RULE -- run platform.search() first, always.

Four places, no more. Decide in this order:

1. DOES IT ALREADY EXIST?  platform.search('your keywords')
   A hit -> extend what is there. Never create a second version of the same thing.
   This also applies before you ANSWER a question from the data, not only before you
   create something: someone may have written down how that data has to be read.

2. IS IT A PROCEDURE another agent should FOLLOW?
   -> skill_library. Instructions, a way of working, "this is how you do X".
   Signs: imperative text, reusable, worthless as a single row.

3. IS IT THE SAME SHAPE OVER AND OVER?
   -> a table. All three must hold:
      a) every record has the same fields,
      b) MORE WILL KEEP ARRIVING -- a monthly export, a quarterly review, a log that
         grows. Not "there are more than twenty today": three supplier audits this
         quarter and three more next quarter is a table, and a one-off list of nine
         things that will never be added to is not.
      c) somebody will filter, group or total across them.
   If not all three: it is text, go to 4.

   That second test used to read "more than ~20 records" and it sent the wrong answer
   back twice in one simulation: an agent holding three quarterly audits followed the
   rule to the letter and wrote them as prose, so nobody could filter on score. The
   question is whether the SHAPE recurs, not how many arrived today.

   YOU CANNOT CREATE A TABLE. That is deliberate -- it keeps the data model decided rather
   than grown. If the answer is a table, run skillhub_request_structure with the purpose,
   the fields and the rows you are holding, and keep working. The caretaker resolves it as a
   column on something that exists or a new table, and it is the only party that sees every
   request, so it is the only one that can notice two people asking for the same thing.
   Writing records as prose because there was nowhere to put them is the failure this
   replaces: the note survives and nobody can count it.

   AND BEFORE A NEW TABLE: THE GRAIN DECIDES. A table is defined by what ONE ROW IS.
   If one row would mean the same kind of thing as a row in a table that already
   exists, it is a COLUMN on that table, not a sibling beside it. Suppliers with one
   more field is one table. Supplier contacts is a different kind of thing, so a
   second one. Four hundred near-duplicate tables is how a shared store stops being
   one, and it happens one reasonable-looking table at a time. See
   platform.v_growth for the count over time and platform.v_abandoned_tables for the
   ones that turned out to be columns.

4. EVERYTHING ELSE IS TEXT -> notes.
   Observations, investigations, meeting notes, "this is how the system works".
   The default. Moving text into a table later is cheaper than clearing out a table
   that never got past three rows.

   The test between 3 and 4 is not how structured the thing feels. It is whether
   somebody will COUNT it or READ it. "ACME, Malmo, contract ends 2027-03-31" gets
   filtered and grouped: a table. "We stopped buying from ACME after three late
   deliveries" gets read: a note. One is a spreadsheet row, the other is a document.

NEVER RETIRE SOMETHING WHOSE CONTENT DID NOT SURVIVE THE MOVE.
   Moving records out of a note and into a table is the right direction, but retired
   content leaves the search index: it stays readable by id and nobody will ever find
   it again. So before you retire a source, check field by field that everything in it
   arrived somewhere findable.

   Measured: an agent moved six supplier audits into a table that had columns for
   supplier, date and score, said out loud that deviations, status and auditor did not
   fit -- and retired the notes anyway. Nothing was deleted and the information became
   unfindable, which in a shared store is the same thing. If fields are missing, ask
   for the columns with skillhub_request_structure and leave the source alone until
   they exist.

PERSONAL DATA IS THE ONE THING YOU STOP AND ASK ABOUT.
   Before you put anything into the store that is ABOUT A NAMED PERSON -- absence,
   sickness, salary, performance, a health note, a disciplinary matter, a private
   address -- stop and ask the user. Do not decide it yourself.

   The reason is that everything here defaults to public and eight people share it.
   A sick-leave register loaded the ordinary way is readable by every colleague, and
   nothing in the database will object. An export from a personnel or time system is
   the usual way this arrives: the rows look like any other rows, and the harm is not
   visible in the data.

   If it has to be here at all, the answer is almost never a shared table. Ask what
   the question actually is. "How much absence did we have per week" needs counts by
   week, not names -- so the useful thing to store is the aggregate, and the names
   stay in the system they came from. Aggregate first, and the problem usually
   disappears.

   And never as a private or a team row either: those mean other agents cannot read it,
   not that it is a lawful place to keep somebody's medical history.

TEXT THAT SOMEONE SHOULD FIND BY MEANING NEVER BELONGS IN A TABLE CELL.
   Notes and skills are embedded, so they can be found by asking for what they mean.
   Table ROWS are not -- only the table's and columns' comments are. Write a paragraph
   of reasoning into a column and it still exists, and nobody will ever find it.

   This is the one place the office-document analogy misleads. A spreadsheet in a
   document library is full-text searchable; a row here is not. So a cell is for a
   value you filter and total, and a narrative belongs in a note that references the
   row -- not in the row.

FILES (pdf, xlsx, images) -> the catalogue keeps a REFERENCE only: name, bytes, sha256,
description. Never base64 in a column. Register it with skillhub_register_document.

   ROWS IN A FILE (a csv or spreadsheet export) are handed over, never retyped: save as
   CSV, skillhub_upload_url, run the curl line, then skillhub_load_file into the table that
   holds this data -- or skillhub_request_structure with document_id, natural_key and your
   observations when no table fits. The house standard is the skill load-from-source-system.

   A DOCUMENT PEOPLE WILL ASK ABOUT (a manual, a policy, a report) is uploaded the same
   way, with its text beside it: skillhub_upload_url, run BOTH curl lines -- the file, and
   the output of pdftotext -layout -- then skillhub_load_text(document_id). The store then
   holds the text verbatim with page numbers: searched by words and by meaning, a hit names
   the page, and a quotation is the document's own words.

   BUT REGISTERING A FILE ALONE SHARES NOTHING. skillhub_register_document keeps a pointer
   -- name, bytes, sha256 -- and nothing reads inside it: such a document is findable by its
   NAME and cannot answer a single question about what it says. So when the text is not
   loaded and you can read the file, THE CONTENT IS YOUR JOB. Register it, then put what it
   says in the ordinary way -- each rule, procedure or checklist as a skill that names the
   document and its revision as its source (the loaded text, if any, is what you condensed
   from and what an auditor opens; the skill is the reading of it); shorter
   observations as notes; a long list of similar items (clauses, requirements, parts) as a
   table via skillhub_request_structure.

   AND KEEP THE SOURCE'S OWN ADDRESSING. Carry over the numbering the document uses --
   clause, section, article, paragraph -- together with the document id and revision, and
   keep its headings rather than inventing better ones. That numbering is how a person
   finds the passage again, how an auditor checks it, and how a colleague tells your
   summary from the manual. A reference nobody can follow back is not a reference.

   WHERE THE BYTES LIVE: A POINTER AND A HASH BY DEFAULT. The catalogue row records
   where the original is (source) and which version was read (sha256). That is enough
   when the original lives somewhere the organisation already trusts -- a document
   system, a shared drive, a source system. Upload the file itself into Storage only when
   the origin cannot be trusted to keep it: somebody's desktop, a laptop, an email.
   Uploading is not free even though disk is: it makes two copies that can drift, and the
   question becomes which one is true. The hash is how that is caught -- the same file
   registered again with a different hash is a new revision, with the same hash a
   duplicate, and register_document says which.

   The test is the source path. "/home/<someone>/Desktop/…" is the case FOR uploading:
   the store's knowledge of the file survives that machine, the file itself does not.
   A path into a document management system is the case against: a pointer is all the
   store needs, and a second copy is drift waiting to happen.

   Said as a picture: the files are books in other buildings. The catalogue says where
   they stand and which edition. The skills are what the librarians learned by reading
   them -- which is why an agent can answer about a drawing it could never open.

   NEVER PUT QUOTATION MARKS AROUND TEXT YOU CONDENSED. Shortening is fine and usually
   right -- presenting the short version as the source's words is not. If it is not
   character for character, write it as your own sentence, or say plainly that it is a
   summary. State once, at the top of what you publish, that the text is condensed and the
   file is the original.

   Measured 2026-09-13/14 on the same quality manual, two failures with one cause. The
   ingest re-headed the document under its own structure and dropped the clause numbers:
   of 8.3.2, 8.3.3, 8.3.5, 8.4, 8.7, 9.2 and 10.2, two survived. Then a colleague's agent
   answered a supplier question correctly from it and presented the condensed sentence in
   quotation marks as the manual's wording. It was not: the manual says "A class A supplier
   with more than three nonconformities in a rolling twelve months is placed under
   increased surveillance and audited within three months", and the stored version had
   become "Class A suppliers with >3 NCRs in rolling 12 months enter increased surveillance
   and audit within three months". Same meaning, and in an audit the auditor opens the
   manual and does not find the sentence. The content survived the move. The citation did
   not, and nobody noticed because the answer was right.

   Measured 2026-09-13: handed a quality manual it could read perfectly -- asked, it quoted
   seven design inputs straight out of it -- an agent registered the file, reported that a
   person had to upload it to Storage, and stopped. It did that three times, including once
   when the user had said outright that they could not upload anything and that the entire
   point was for colleagues to get answers out of the manual. Nothing refused it and nothing
   was broken. It had been told that a file's home is Storage, so it treated the knowledge
   inside the file as somebody else's job.

VECTORS are not a choice. Skills and public notes are embedded automatically so others
find them by meaning and not only by words. Private rows are never embedded.

UNSURE between a table and a note: choose the note.
UNSURE between a note and a skill: a skill if someone should follow it, otherwise a note.$t$;
$$;
comment on function platform.placement_rule() is 'The decision order for where data belongs. Agents read it through the conventions skill; this function is the source.';

-- ---------------------------------------------------------------------------
-- 12) The DDL guard: order becomes mechanism rather than hope.
--     Created by an admin (a superuser). Agents run as `postgres` and can neither
--     remove it nor bypass it by accident.
-- ---------------------------------------------------------------------------
-- (the ddl_log table itself is created earlier, above the views that read it)

create or replace function platform.ddl_guard() returns event_trigger
language plpgsql security definer as $$
declare
  o record;
  missing int;
begin
  for o in select * from pg_event_trigger_ddl_commands() loop
    if o.schema_name in ('public','platform') then
      -- session_user, not current_user: this function is security definer, so
      -- current_user would report the owner (supabase_admin) and hide who actually ran
      -- the command. session_user is the login role -- `postgres` over MCP.
      insert into platform.ddl_log (role, command, object)
      values (session_user, o.command_tag, o.object_identity);
    end if;

    -- A new table in public has to follow the convention. Exempt: superusers (an admin
    -- at a psql prompt) and anyone who deliberately set platform.bypass = 'on'.
    if o.command_tag = 'CREATE TABLE' and o.schema_name = 'public'
       and not (select rolsuper from pg_roles where rolname = session_user)
       and coalesce(current_setting('platform.bypass', true), 'off') <> 'on'
    then
      select 4 - count(*) into missing
        from pg_attribute a
       where a.attrelid = o.objid
         and a.attname in ('owner','visibility','created_by','updated_by');
      if missing > 0 then
        -- The remedy travels in `message`, not in `hint`. Measured 2026-09-11: the MCP
        -- error wrapper forwards message and drops hint, so an agent that tripped this
        -- was told no and never told what to do instead -- the guard's whole purpose.
        raise exception using
          errcode = 'check_violation',
          message = format(
            'Table %s is missing the convention columns (owner, visibility, created_by, updated_by). '
            'Create it like this instead: select public.create_shared_table(''%s'', ''what the table holds''); '
            'then add your own columns with alter table. '
            'Not sure it should be a table at all? Run select platform.placement_rule().',
            o.object_identity, split_part(o.object_identity, '.', 2)),
          hint = 'The same text is in the error message itself -- the MCP wrapper forwards message and drops hint.';
      end if;
    end if;
  end loop;
end $$;

drop event trigger if exists platform_ddl_guard;
create event trigger platform_ddl_guard on ddl_command_end
  when tag in ('CREATE TABLE','ALTER TABLE','CREATE VIEW','CREATE FUNCTION','CREATE INDEX','CREATE SCHEMA')
  execute function platform.ddl_guard();

-- Drops need their own handler. `ddl_command_end` fires for a DROP but
-- pg_event_trigger_ddl_commands() reports nothing usable about it, so listing
-- 'DROP TABLE' among the tags above produced exactly zero rows: a table could leave the
-- store without a trace while its creation sat in the log forever. Measured 2026-09-11.
create or replace function platform.ddl_guard_drop() returns event_trigger
language plpgsql security definer as $$
declare o record;
begin
  for o in select * from pg_event_trigger_dropped_objects() loop
    -- `original` is the object actually named in the DROP statement. Everything else is
    -- collateral -- indexes, constraints, the table's own row type -- and logging it
    -- buries the one event a person cares about under a dozen rows. schema_name is null
    -- for a dropped schema, hence the second branch.
    if o.original and not o.is_temporary
       and (o.schema_name in ('public','platform') or o.object_type = 'schema')
    then
      insert into platform.ddl_log (role, command, object)
      values (session_user, 'DROP '||upper(o.object_type), o.object_identity);
    end if;
  end loop;
end $$;

drop event trigger if exists platform_ddl_guard_drop;
create event trigger platform_ddl_guard_drop on sql_drop
  execute function platform.ddl_guard_drop();

-- Tables added in the last week that are still there. Defined once: an earlier version
-- of this file declared it twice, with a left join first and an inner join after, and
-- only the second one ever took effect.
create or replace view platform.v_new_tables as
select d.at::timestamp(0) as created, d.object, d.role,
       c.description, c.rows, c.follows_convention
from platform.ddl_log d
join platform.v_catalog c on 'public.'||c.table_name = d.object
where d.command = 'CREATE TABLE' and d.at > now() - interval '7 days'
order by d.at desc;
comment on view platform.v_new_tables is 'Tables added in the last week that still exist. Read it, or the store grows without anyone noticing.';

grant select on all tables in schema platform to service_role;

-- ---------------------------------------------------------------------------
-- 13) The rule the agents actually look at: into the conventions skill.
-- ---------------------------------------------------------------------------
-- Strip what this and the later files appended last time, from the placement rule to the
-- end, then append afresh. Until 2026-09-16 the pattern named a heading that did not exist
-- and carried the 'n' flag, under which '.' stops at a newline -- so nothing was stripped
-- and the skill grew by four sections on every boot: 201,433 characters on dev after
-- sixteen boots, found when the chunker produced sixteen chunks headed "## Overview".
-- The conventions skill is assembled from SECTIONS, one row per file that owns one, and
-- written as a new VERSION when the assembled text changes -- never edited in place.
--
-- It was edited in place until 2026-09-17, and that made the one document every agent obeys
-- the only house document with no history: a single row, and what it said last week was gone.
-- Every skill an agent publishes has kept every version since the beginning, so this was
-- inconsistent as well as wrong for anyone who has to show an auditor what a rule said then.
--
-- Sections as rows also retire the text surgery this used to need. Each file replaced its own
-- section inside one long string, bounded by the heading that came next -- so every file had
-- to know what could follow it, and the day a new section was added below, the file above it
-- silently deleted it on every boot (found the same day, two writes per boot for nothing).
-- Ordered rows cannot do that.
create table if not exists platform.convention_sections (
  ord        int primary key,
  name       text not null,
  body       text not null,
  updated_at timestamptz not null default now()
);
comment on table platform.convention_sections is 'The conventions skill, in the pieces the seed files own: ord decides the order, and platform.assemble_conventions() joins them. Changing a body here is what produces a new version of the skill.';

-- The parameters are prefixed, because "ord" and "name" are also the table's columns and
-- Postgres refuses with "column reference is ambiguous" -- the same trap embed_save had.
create or replace function platform.put_conventions_section(p_ord int, p_name text, p_body text) returns void
language plpgsql as $f$
begin
  insert into platform.convention_sections as c (ord, name, body)
  values (p_ord, p_name, p_body)
  on conflict (ord) do update
     set name = excluded.name, body = excluded.body, updated_at = now()
   where c.body is distinct from excluded.body or c.name is distinct from excluded.name;
end $f$;
comment on function platform.put_conventions_section(int, text, text) is 'A seed file declaring its section of the conventions skill. Writes nothing when the text is unchanged.';

-- One version per change, with the previous one marked superseded. Run last, after every file
-- has declared its section.
create or replace function platform.assemble_conventions() returns text
language plpgsql as $f$
declare
  full_md text; cur record; next_version text;
begin
  select string_agg(body, E'\n' order by ord) into full_md from platform.convention_sections;
  if full_md is null then return 'No sections declared; nothing to assemble.'; end if;

  select version, skill_md into cur from platform.v_current_skills where slug = 'store-conventions';
  if cur.version is not null and cur.skill_md = full_md then
    return format('store-conventions %s is current; nothing changed.', cur.version);
  end if;

  -- 2.3.0 -> 2.4.0. The first component stays: a section rewrite is not a new document.
  next_version := case when cur.version is null then '1.0.0'
    else format('%s.%s.0', split_part(cur.version,'.',1), (split_part(cur.version,'.',2))::int + 1) end;

  insert into public.skill_library (slug, name, description, skill_md, version, author_name, license, tags, visibility, status)
  values ('store-conventions', 'Shared store conventions',
          'The rules for every agent that reads and writes in the shared store: identity, ownership, public and private, new tables, migrations and files.',
          full_md, next_version, 'skillhub', 'MIT',
          '{store,conventions,mcp,hermes,shared-data}', 'public', 'published');
  update public.skill_library set superseded_by = next_version, updated_at = now()
   where slug = 'store-conventions' and version <> next_version and superseded_by is null;
  return format('store-conventions %s published%s.', next_version,
                coalesce(', superseding ' || cur.version, ' (first version)'));
end $f$;
comment on function platform.assemble_conventions() is 'Joins platform.convention_sections and publishes it as a new version of store-conventions when the text differs from the current one. Called at the end of the seed.';

create or replace function platform.put_section(md text, start_marker text, next_markers text[], content text)
returns text language plpgsql immutable as $f$
declare st int; en int; p int; m text;
begin
  st := position(start_marker in md);
  if st = 0 then return md || content; end if;
  en := length(md) + 1;
  foreach m in array coalesce(next_markers, '{}'::text[]) loop
    p := position(m in substr(md, st + 1));
    if p > 0 and st + p < en then en := st + p; end if;
  end loop;
  return substr(md, 1, st - 1) || content || substr(md, en);
end $f$;
comment on function platform.put_section(text, text, text[], text) is 'Replace the section of a text that begins with start_marker and runs to the next of next_markers (or the end) -- or append it when absent. The seed assembles the conventions skill with it.';

select platform.put_conventions_section(10, 'placement rule and overview',
  E'\n' || platform.placement_rule() || E'\n\n'
  || E'## Overview\n\n'
  || E'The `platform` schema is readable by every agent and answers "what is here":\n'
  || E'- `select * from platform.overview()` -- seven numbers, run it first in a new session.\n'
  || E'- `select * from platform.search(''keywords'')` -- find before you create, and before you answer.\n'
  || E'- `select * from platform.v_catalog` -- every table, its size, whether it follows the convention.\n'
  || E'- `select * from platform.v_flow limit 20` -- what other agents just did.\n'
  || E'- `select * from platform.v_action_items` -- what needs tidying. Take one when you have time.\n'
  || E'- `select * from platform.v_caveats` -- what the log does not prove.\n\n'
  || E'A DDL guard refuses a new table in public that lacks the convention columns, and the\n'
  || E'error tells you what to run instead. The guard is help, not an accusation: if you hit it,\n'
  || E'you probably thought "table" when the answer was "note".\n');
