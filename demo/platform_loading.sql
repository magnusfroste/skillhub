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
create or replace view platform.v_sources as
select d.target_table as table_name, d.source_system, d.filename,
       d.row_count, d.agent as loaded_by,
       d.at::timestamp(0) as last_loaded,
       (now() - d.at) as age,
       (select count(*) from platform.deliveries x where x.target_table = d.target_table) as deliveries
from platform.deliveries d
join lateral (select max(at) t from platform.deliveries y where y.target_table = d.target_table) latest
  on latest.t = d.at
order by d.at desc;
comment on view platform.v_sources is 'The latest load per table: from where, how much, how old. Start here when someone asks whether the data is current.';

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
  if not exists (select 1 from public.skill_library where slug = 'load-from-source-system') then
    insert into public.skill_library (slug, name, description, skill_md, version, author_name, license, tags, visibility, status)
    values (
      'load-from-source-system',
      'Load data from a source system',
      'The house standard for bringing an export (xlsx, csv, json) from another system into the store so it can be trusted, updated and traced.',
      $md$---
    name: load-from-source-system
    description: Follow this when you bring a file or export from another system into the store.
    version: 1.0.0
    license: MIT
    ---

    # Load data from a source system

    The pattern comes from a quality register: 5,812 rows out of an xlsx, loaded so they can
    still be trusted a year later. Follow it and the next system will be the same rather than
    slightly different.

    ## Before you start

    0. **A delivery, not a specification.** You start because you are holding an export, not
       because you read an API document. A schema listing describes what could exist in someone
       else's system; a company typically uses a fraction of its ERP -- production but not
       ticketing, say. Designing a table per entity in a specification fills the catalogue with
       structures no data will ever reach, and they will sit in platform.v_abandoned_tables as
       evidence. API or flat file makes no difference: the trigger is the file in your hands.

    1. `select * from platform.search('<the system''s name>')` -- does the data already exist?
    2. `select * from platform.v_sources` -- has it already been loaded, and how fresh is it?
    3. Count the rows in the source file. You need something to compare against afterwards.

    ## The table

    Create it with `select public.create_shared_table('name', 'description');` and add:

    - **One parsed column per field** in the source, with a sensible type: dates as `date`,
      numbers as `numeric`, the rest `text`. Keep one naming style across the whole table.
    - **`raw jsonb not null`** -- the whole original row. This is the most important step. If
      you parse something wrong, everything can be recomputed from `raw` without going back to
      the source system.
    - **`source_sha256 text`** -- the checksum of the file the row came from.
    - **`loaded_at timestamptz default now()`**.

    **Change the primary key to the business's own key** if there is one (case number, order
    number, registration number):

        alter table public.<table> drop constraint <table>_pkey;
        alter table public.<table> add primary key (<natural_key>);

    This is what stops next month's export from duplicating everything. No natural key: put a
    unique constraint on the columns that together identify a row.

    ## The load

    - Empty cells become `null`, never an empty string. Otherwise every `count` and `group by`
      lies.
    - Write in statements of 1,000-2,000 rows. Larger statements drop Studio's connection (502).
    - When updating existing data use `on conflict (<key>) do update` rather than deleting
      first. The history survives and you can see what changed.
    - Index the columns you will filter on: date, status, customer, supplier.

    ## Afterwards, in the same session

    1. Compare: `select count(*)` against the number of rows in the source file. If they differ,
       say so.
    2. Register the delivery:

           select platform.register_delivery(
             'Source system name', '<table>', 'agent_NN',
             'filename.xlsx', '<sha256>', <inserted>, <updated>, 'comment');

       The function warns if the same file has been loaded before.
    3. Register the source file in `documents` with filename, bytes, sha256 and a description.
       The file itself is uploaded to Storage by a person -- you cannot upload bytes.
    4. Comment the table and every column. The next agent reads the comments, not your session.
    5. **Write down how the data has to be read.** Sentinel values, unreliable fields, which
       column is the dependable key, what must be excluded from a total. Put it in the skill for
       that dataset, or in a note. This is the step that pays for itself: a colleague who skips
       it later gets a confident wrong number instead of an error. Measured once at a factor of
       thirty-eight.

    ## What not to do

    - Never put the file's contents as base64 in a column. It works, and it becomes an expensive
      bottleneck.
    - Never delete and reload to "start over". Use `on conflict do update`.
    - Never mix your own analysis results into the source table. Analysis is its own table or a
      note that references the source.
    $md$,
      '1.0.0', 'supabase-easy', 'MIT',
      '{loading,etl,source-system,xlsx,house-standard}', 'public', 'published'
    )
    on conflict (slug, version) do update
      set skill_md = excluded.skill_md, description = excluded.description,
          version = excluded.version, updated_at = now();
  end if;
end $do$;;

grant select on all tables in schema platform to anon, authenticated, service_role;
grant execute on all functions in schema platform to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4) The conventions skill points at the house standards, or nobody finds them.
-- ---------------------------------------------------------------------------
update public.skill_library
   set skill_md = regexp_replace(skill_md, E'\n## House standards.*$', '', 'n')
                  || E'\n## House standards\n\n'
                  || E'Skills tagged `house-standard` describe how a particular kind of work is done here.\n'
                  || E'Find them with:\n'
                  || E'  select slug, name, description from skill_library\n'
                  || E'   where ''house-standard'' = any(tags) and status = ''published'';\n\n'
                  || E'Read the one that covers your work BEFORE you start, not after. Right now there is:\n'
                  || E'- `load-from-source-system` -- bring an export (xlsx, csv, json) in from another system.\n\n'
                  || E'If you invent a way of working that works and others will need: write a skill, tag it\n'
                  || E'`house-standard`, and add it to the list above. That is how the store learns.\n',
       version = '2.2.0', updated_at = now()
 where slug = 'store-conventions';
