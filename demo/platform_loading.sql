-- Loading from a source system. Run AFTER demo/platform_lifecycle.sql.
--
-- The pattern did not come from here: an agent invented it when a quality register had to
-- be brought in. It was good enough to become the house standard, so here it is written
-- down, measurable, and described in a skill so the next system lands the same way.
--
-- What the agent got right, and which is therefore the rule:
--   * parsed columns AND the original row as jsonb beside them -- nothing is lost in parsing
--   * the source file's sha256 on every row -- you can prove which export a row came from
--   * the business's own key (the case number) as the primary key, not a uuid
--     -> a new export cannot duplicate; it collides or updates
--   * empty cells as null, not empty strings -- otherwise every count lies

-- ---------------------------------------------------------------------------
-- 1) Delivery register: when did the data arrive, from where, how much.
-- ---------------------------------------------------------------------------
create table if not exists platform.deliveries (
  id            bigserial primary key,
  source_system text not null,
  target_table  text not null,
  filename      text,
  file_sha256   text,
  row_count     bigint,
  inserted      bigint,
  updated       bigint,
  agent         text not null,
  at            timestamptz not null default now(),
  comment       text
);
create index if not exists deliveries_table_idx on platform.deliveries (target_table, at desc);
comment on table platform.deliveries is 'One row per load from a source system. Answers "how fresh is this data and where did it come from".';
comment on column platform.deliveries.file_sha256 is 'Checksum of the source file. The same sum again means the same export, so no new data.';

create or replace function platform.register_delivery(
  source_system text, target_table text, agent text,
  filename text default null, file_sha256 text default null,
  inserted bigint default null, updated bigint default null, comment text default null)
returns text language plpgsql as $$
declare n bigint; seen_before timestamptz;
begin
  if to_regclass('public.'||target_table) is null then
    raise exception 'The table public.% does not exist. Create it first.', target_table;
  end if;
  execute format('select count(*) from public.%I', target_table) into n;
  select max(d.at) into seen_before from platform.deliveries d
   where d.target_table = register_delivery.target_table and d.file_sha256 = register_delivery.file_sha256;
  insert into platform.deliveries (source_system, target_table, filename, file_sha256, row_count, inserted, updated, agent, comment)
  values (source_system, target_table, filename, file_sha256, n, inserted, updated, agent, comment);
  return format('Registered: %s -> public.%s, %s rows%s', source_system, target_table, n,
    case when seen_before is not null then format(' (NOTE: the same file was already loaded %s)', to_char(seen_before,'YYYY-MM-DD HH24:MI')) else '' end);
end $$;
comment on function platform.register_delivery is 'Run after every load. Warns if the same source file has been loaded before.';

-- ---------------------------------------------------------------------------
-- 2) Freshness: the question the organisation actually asks.
-- ---------------------------------------------------------------------------
-- One row per FEED, and a feed is a source system loading into a table -- not a table.
-- Keyed on both from 2026-09-19: an agent with a cron job against an ERP is one connection,
-- and a store filled by several of them (orders from the ERP, tickets from the case system)
-- collapsed into one row per table would hide exactly the thing the picture is for. Two
-- systems into one table are two rows here, each with its own freshness.
--
-- The cadence columns answer the question nobody asks until it is too late. A feed does not
-- normally break; it goes QUIET, and a report is wrong for a fortnight before anyone
-- notices. So the view infers the rhythm from the deliveries themselves -- nothing is
-- declared, nothing configured, the same posture as the self-configuring indexer -- and
-- says when the next one is overdue.
--
-- Three deliveries is the threshold for having a rhythm at all. Below it this is a FILE
-- somebody loaded once, and calling a one-off import an overdue feed is how an operating
-- surface becomes noise.
create or replace view platform.v_sources as
with gaps as (
  select d.target_table, d.source_system, d.at,
         extract(epoch from (d.at - lag(d.at) over w))/3600 as gap,
         row_number() over (partition by d.target_table, d.source_system order by d.at desc) as recency
  from platform.deliveries d
  window w as (partition by d.target_table, d.source_system order by d.at)
),
per_feed as (
  select g.target_table, g.source_system,
         count(*)      as deliveries,
         max(g.at)     as last_at,
         -- The rhythm, in hours: the MEDIAN of the five most recent gaps.
         --
         -- Not the whole history, because a feed that ran weekly for a year and nightly for a
         -- week would average out at a week, and a stopped nightly feed would then stay quiet
         -- for a fortnight -- precisely the failure this view exists to catch. Judge it on
         -- what it does now.
         --
         -- And the median, not the average, because the five most recent gaps include the
         -- transition: 24, 24, 24, 24 and one of 216 averages to 62 hours, so the check would
         -- wait two and a half days for a nightly feed. The median of the same five is 24.
         -- Same reason a missed run or a backfill burst must not move the rhythm.
         percentile_cont(0.5) within group (order by g.gap)
           filter (where g.recency <= 5) as avg_gap
  from gaps g
  group by g.target_table, g.source_system
)
select f.target_table as table_name, f.source_system, d.filename,
       d.row_count, d.agent as loaded_by,
       f.last_at::timestamp(0) as last_loaded,
       (now() - f.last_at) as age,
       f.deliveries,
       case when f.deliveries >= 3 and f.avg_gap is not null
            then make_interval(secs => round(f.avg_gap * 3600)) end as typical_gap,
       -- Overdue at twice the rhythm: late enough that it is not jitter, early enough to be
       -- worth saying. Null typical_gap (too few deliveries to have one) is never quiet.
       (f.deliveries >= 3 and f.avg_gap is not null
        and now() - f.last_at > make_interval(secs => round(f.avg_gap * 3600 * 2))) as quiet
from per_feed f
join platform.deliveries d
  on d.target_table = f.target_table and d.source_system = f.source_system and d.at = f.last_at
order by f.last_at desc;
comment on view platform.v_sources is 'One row per feed -- a source system loading into a table. From where, how much, how old, how often, and whether the next load is overdue (quiet). Start here when someone asks whether the data is current, or what fills this store. A table loaded fewer than three times is a file, not a feed: it has no rhythm and is never reported quiet.';
comment on column platform.v_sources.typical_gap is 'The average time between this feed''s loads, inferred from the deliveries themselves. Null until there are three.';
comment on column platform.v_sources.quiet is 'True when the last load is more than twice the typical gap old: the feed has stopped without failing. Nothing here can restart it -- the schedule lives in the agent that runs it.';

-- Tables holding source-system data with no registered delivery: someone loaded without
-- saying so.
create or replace view platform.v_unregistered_data as
select c.table_name, c.rows, c.description
from platform.v_catalog c
where c.rows > 500
  and not exists (select 1 from platform.deliveries d where d.target_table = c.table_name)
  and c.table_name not like 'v\_%';
comment on view platform.v_unregistered_data is 'Large tables with no delivery registration. Either they were produced here, or somebody forgot to record where the data came from.';

-- ---------------------------------------------------------------------------
-- 3) The pattern as a skill, so the next system lands the same way.
-- ---------------------------------------------------------------------------
-- Created only when the slug is absent, and wrapped in a DO block so the values clause is
-- untouched. Later files bump this skill's version IN PLACE, so on a second run the original
-- version row is gone; a plain insert would add a SECOND row for the same slug and the next
-- bump would try to set both to the same version, hitting the unique constraint. Found
-- 2026-09-14 by running the seed twice against an empty database -- the first run passed.
do $do$
begin
  -- A new VERSION, never an edit: an existing instance keeps 1.0.0 (marked superseded) and
  -- gets 1.1.0 beside it; a fresh one gets 1.1.0 only. Found 2026-09-15 on the demo: the
  -- seed inserted the skill only when the slug was absent, so no instance ever received a
  -- rewrite -- and 1.0.0 told agents a person uploads the file.
  if not exists (select 1 from public.skill_library where slug = 'load-from-source-system' and version = '1.1.0') then
    insert into public.skill_library (slug, name, description, skill_md, version, author_name, license, tags, visibility, status)
    values (
      'load-from-source-system',
      'Load data from a source system',
      'The house standard for bringing an export (csv, xlsx, json) from another system into the store: the file is handed over and loaded server-side, never retyped; the caretaker builds a table only when none fits.',
      $md$---
    name: load-from-source-system
    description: Follow this when you bring a file or export from another system into the store.
    version: 1.1.0
    license: MIT
    ---

    # Load data from a source system

    You are holding an export -- csv, xlsx, json -- from another system. The rows go in as a
    FILE, never through you: sixty rows retyped through a model took 36 calls and stopped at
    19. There are two cases, and the first thing to find out is which one you are in.

    ## Before you start

    1. `skillhub_search` the system's name and the subject. Does a table for this data exist?
       `skillhub_overview` lists every table and what it holds.
    2. Count the rows in the file. You will compare against it afterwards.
    3. Save a spreadsheet as CSV. The loader reads CSV (comma or semicolon, quotes, BOM); an
       xlsx is only catalogued.
    4. Read the data before you hand it over, and write down what you see: a sentinel value
       (`hours_spent 999` = not recorded), one status in several spellings, blanks that mean
       something, a duplicated key, units. One sentence each, naming the column. These are
       your OBSERVATIONS and they are the most valuable thing you contribute: they become the
       column comments the next agent reads. Said only in chat they are lost, and the next
       agent gets a confident wrong number instead of an error. Measured once at a factor of
       thirty-eight.

    ## Case A: the table exists -- you do it all yourself

    1. `skillhub_upload_url(filename, sha256, description)` registers the file and returns a
       curl line.
    2. Run the curl line from the terminal. The bytes go to Storage beside the model, not
       through it. No key is needed.
    3. `skillhub_load_file(document_id, target_table, natural_key)`: the store reads the file
       server-side and upserts on the key. Next month's export updates the rows that changed
       and adds the new ones; the delivery is registered with file, hash, inserted, updated.
    4. Compare inserted + updated with your row count. If they differ, say so.
    5. Anything new you noticed about the data goes in a note that names the table, or in a
       new version of that dataset's skill.

    ## Case B: no table fits -- you describe it, the caretaker builds it

    1. and 2. as above: upload the file first.
    3. `skillhub_request_structure(purpose, fields, natural_key, document_id, observations,
       suggested_name)`: the purpose in a sentence, the fields as they are in the file, the
       key a re-delivery upserts on, the document id from step 1, and your observations.
       Do NOT paste the rows into sample_rows -- they are in the file.
    4. The caretaker sees every open request, catches "we already have a tickets table", and
       runs one call that builds the table with your observations as column comments, loads
       the file and registers the delivery. Nothing for you to retype.
    5. From then on it is Case A: every later export is yours to load.

    ## What not to do

    - Never type rows into add_rows or sample_rows when they exist in a file. That is the
      19-of-60 path.
    - Never delete and reload to "start over". A load upserts on the key; the history survives.
    - Never put a file's contents as base64 in a column, and never mix your own analysis into
      the source table. Analysis is its own table, or a note that references the source.
    - Never design tables from a system's API documentation. The trigger is the file in your
      hands; a schema listing describes what could exist, and tables no data reaches sit in
      platform.v_abandoned_tables as evidence.

    ## For the caretaker

    `select platform.load_registered_file(<request_id>);` does everything Case B needs:
    create_shared_table with the convention columns, one parsed column per field plus
    `raw jsonb`, `source_sha256` and `loaded_at`, the natural key as primary key, the
    observations as column comments, the request resolved, the file loaded, the delivery
    registered. Pass `target_table` to choose the name when the near-duplicate guard objects.
    Loading by hand instead, keep the same shape: empty cells become null, never an empty
    string; `on conflict (<key>) do update`; statements of 1,000-2,000 rows (larger ones drop
    Studio's connection); index the columns people filter on; `platform.register_delivery(...)`
    afterwards; and comment every column -- the next agent reads the comments, not your session.
    $md$,
      '1.1.0', 'skillhub', 'MIT',
      '{loading,etl,source-system,csv,xlsx,house-standard}', 'public', 'published'
    );
  end if;
  update public.skill_library
     set superseded_by = '1.1.0', updated_at = now()
   where slug = 'load-from-source-system' and version <> '1.1.0' and superseded_by is null;
end $do$;;

grant select on all tables in schema platform to anon, authenticated, service_role;
grant execute on all functions in schema platform to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4) The conventions skill points at the house standards, or nobody finds them.
-- ---------------------------------------------------------------------------
select platform.put_conventions_section(30, 'house standards',
  E'\n## House standards\n\n'
  || E'Skills tagged `house-standard` describe how a particular kind of work is done here.\n'
  || E'Find them with:\n'
  || E'  select slug, name, description from skill_library\n'
  || E'   where ''house-standard'' = any(tags) and status = ''published'';\n\n'
  || E'Read the one that covers your work BEFORE you start, not after. Right now there is:\n'
  || E'- `load-from-source-system` -- bring an export (xlsx, csv, json) in from another system.\n'
  -- The whole list lives here, including the standard platform_ops.sql seeds a moment
  -- later: a second file patching a line into this section rewrote it on every boot.
  || E'- `caretaker-operations` -- for the admin key: what to check, what to do, what to leave alone.\n\n'
  || E'If you invent a way of working that works and others will need: write a skill, tag it\n'
  || E'`house-standard`, and add it to the list above. That is how the store learns.\n');
