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
-- A delivery was file-shaped until 2026-09-20: filename and sha256, because every load so
-- far had been an export somebody uploaded. Then the caretaker was told to mirror a CRM, and
-- a mirror has no file -- it has a model, a run, a watermark, and rows it read but did not
-- need to write. It had nowhere to record any of that, so it wrote the run journal as NOTES:
-- six of them in seventeen minutes, each one embedded, each one crowding real knowledge out
-- of search. And because nothing was registered, the twelve tables it built were invisible to
-- platform.v_sources and to the feeds check -- the store could not say what filled it.
--
-- So the register keeps its grain -- one row per target table per load -- and gains the
-- columns a sync has. Nullable, so every existing row and every file upload stays valid.
alter table platform.deliveries
  add column if not exists source_model text,
  add column if not exists run_id       text,
  add column if not exists rows_read    bigint,
  add column if not exists skipped      bigint,
  add column if not exists errors       bigint,
  add column if not exists watermark    text;
comment on column platform.deliveries.source_model is 'The name the source system gives this data: crm.lead, sale.order, a table name. Null for a plain file upload.';
comment on column platform.deliveries.run_id is 'One identifier for a whole run, so twenty models synchronised together can be read as one pass.';
comment on column platform.deliveries.rows_read is 'How many the source offered. Read minus inserted minus updated is how much work was avoided, which is the number that says the watermark is doing its job.';
comment on column platform.deliveries.skipped is 'Read and deliberately not written, because nothing had changed. A healthy incremental sync skips nearly everything.';
comment on column platform.deliveries.watermark is 'The high-water mark this load reached, as the source states it: the newest write_date, a sequence, a timestamp. The next run asks for what is newer than this.';
create index if not exists deliveries_table_idx on platform.deliveries (target_table, at desc);
create index if not exists deliveries_run_idx on platform.deliveries (run_id) where run_id is not null;
comment on table platform.deliveries is 'One row per load from a source system. Answers "how fresh is this data and where did it come from".';
comment on column platform.deliveries.file_sha256 is 'Checksum of the source file. The same sum again means the same export, so no new data.';

-- The eight-argument version is dropped rather than replaced: one signature per function,
-- since three overloads of load_registered_file once made the caretaker's single call
-- ambiguous on a live store.
drop function if exists platform.register_delivery(text,text,text,text,text,bigint,bigint,text);
create or replace function platform.register_delivery(
  source_system text, target_table text, agent text,
  filename text default null, file_sha256 text default null,
  inserted bigint default null, updated bigint default null, comment text default null,
  source_model text default null, run_id text default null, rows_read bigint default null,
  skipped bigint default null, errors bigint default null, watermark text default null)
returns text language plpgsql as $$
declare n bigint; seen_before timestamptz; prev_wm text;
begin
  if to_regclass('public.'||target_table) is null then
    raise exception 'The table public.% does not exist. Create it first.', target_table;
  end if;
  execute format('select count(*) from public.%I', target_table) into n;
  select max(d.at) into seen_before from platform.deliveries d
   where d.target_table = register_delivery.target_table and d.file_sha256 = register_delivery.file_sha256
     and register_delivery.file_sha256 is not null;
  -- A watermark that has not moved is the honest signal that a sync read and wrote nothing
  -- because there was nothing new -- worth saying out loud, because the alternative reading
  -- of "0 inserted, 0 updated" is that the feed is broken.
  select d.watermark into prev_wm from platform.deliveries d
   where d.target_table = register_delivery.target_table and d.watermark is not null
   order by d.at desc limit 1;
  insert into platform.deliveries (source_system, target_table, filename, file_sha256, row_count,
    inserted, updated, agent, comment, source_model, run_id, rows_read, skipped, errors, watermark)
  values (source_system, target_table, filename, file_sha256, n, inserted, updated, agent, comment,
    source_model, run_id, rows_read, skipped, errors, watermark);
  return format('Registered: %s%s -> public.%s, %s rows in the table%s%s', source_system,
    case when source_model is not null then ' '||source_model else '' end, target_table, n,
    case when seen_before is not null then format(' (NOTE: the same file was already loaded %s)', to_char(seen_before,'YYYY-MM-DD HH24:MI')) else '' end,
    case when watermark is not null and prev_wm = watermark
         then format(' (the watermark has not moved from %s: the source had nothing newer, which is what an idle sync looks like)', watermark)
         when watermark is not null then format(' (watermark now %s)', watermark) else '' end);
end $$;
comment on function platform.register_delivery is 'Run after every load, file or sync. One row per target table per load. Warns if the same source file has been loaded before, and says when a watermark has not moved -- which is what an idle incremental sync looks like, as opposed to a broken one.';

-- ---------------------------------------------------------------------------
-- 1b) The same thing as a tool, because the agent doing the mirroring is the one that
--     knows the numbers.
--
-- Until now a delivery could only be registered by loading a CSV through the loader, or in
-- raw SQL, which agents may not run. So an agent syncing from an API had no way to record
-- what it had done -- and on 2026-09-20 the caretaker, told to mirror a CRM, wrote its run
-- journal as six notes instead. This is the call that journal belongs in.
-- ---------------------------------------------------------------------------
create or replace function public.skillhub_record_sync(
  agent text, source_system text, target_table text,
  source_model text default null, rows_read bigint default null,
  inserted bigint default null, updated bigint default null, skipped bigint default null,
  errors bigint default null, watermark text default null, run_id text default null,
  comment text default null) returns jsonb
language plpgsql security definer set search_path = public, platform as $$
declare msg text; vis boolean;
begin
  if agent is null or agent = '' then raise exception 'No agent identity from the gateway.'; end if;
  if to_regclass('public.'||quote_ident(target_table)) is null then
    raise exception 'No table "%" in public. Record a sync against the table it wrote to; if there is none yet, the rows had nowhere to go and that is the thing to report.', target_table;
  end if;
  -- Only against a table the caller may write to. The register says who filled a table and
  -- anybody reading it takes that as fact, so it is not a place to leave somebody else's name.
  select exists (select 1 from public.agents a where a.id = agent) into vis;
  if not vis then raise exception 'Unknown agent "%".', agent; end if;
  msg := platform.register_delivery(source_system, target_table, agent, null, null,
           inserted, updated, comment, source_model, run_id, rows_read, skipped, errors, watermark);
  return jsonb_build_object('recorded', msg, 'table', target_table, 'source_system', source_system,
    'source_model', source_model, 'run_id', run_id, 'watermark', watermark,
    'next', 'One call per target table per run, so a run over twenty models is twenty rows sharing a run_id. '
         || 'This is where a run journal belongs -- not in a note: platform.v_sources reads it to say how fresh each '
         || 'feed is and platform.health() says when one has gone quiet, and neither can see a note. '
         || 'Write a note for what you LEARNED about the source (a field that lies, a sentinel value, a model that is empty), '
         || 'and a skill if you worked out a procedure the next integration should follow.');
end $$;
comment on function public.skillhub_record_sync is 'Record one load from a source system into one table: read, inserted, updated, skipped, errors, the watermark reached, and a run id shared by the models of one pass. This is what makes a feed visible in platform.v_sources and watched by platform.health().';
revoke all on function public.skillhub_record_sync(text,text,text,text,bigint,bigint,bigint,bigint,bigint,text,text,text) from public;
grant execute on function public.skillhub_record_sync(text,text,text,text,bigint,bigint,bigint,bigint,bigint,text,text,text) to service_role, postgres;

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
-- Dropped first: the column list changed order (source_model sits beside source_system, where
-- a reader looks for it) and CREATE OR REPLACE VIEW may only append. Nothing depends on it --
-- skillhub_overview reads it from a function, not from a view built on top.
drop view if exists platform.v_sources;
create view platform.v_sources as
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
select f.target_table as table_name, f.source_system, d.source_model, d.filename,
       d.row_count, d.agent as loaded_by,
       f.last_at::timestamp(0) as last_loaded,
       (now() - f.last_at) as age,
       f.deliveries, d.run_id as last_run, d.watermark,
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
comment on column platform.v_sources.source_model is 'What the source calls the data in this feed: crm.lead, sale.order. Null for a plain file upload, where the filename says it instead.';
comment on column platform.v_sources.watermark is 'How far the last load got, as the source states it. A watermark that stops moving while loads keep arriving is a feed reading the same thing over and over.';
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
-- 2b) Mirroring a live system, as a house standard.
--
-- Where this came from: on 2026-09-20 the caretaker was told to connect to a CRM and make
-- the store a read-only mirror of it. In one night it connected over JSON-RPC, inventoried
-- twenty models, built twelve tables that all follow the convention, and kept the source's
-- own identifiers. The shape it invented is better than the one this file's CSV standard
-- describes -- odoo_id as the key, the source model named on every row, a run id, an
-- extraction time, the whole payload in raw, write_date as the watermark -- so it is written
-- down here rather than left in one instance's history.
--
-- What it got WRONG is equally instructive and is in the skill too: it wrote its run journal
-- as six notes in seventeen minutes because there was nowhere else to put it, it registered
-- no deliveries so its twelve tables were invisible to the freshness view, and it filed
-- nineteen structure requests to itself and then waited for its own decision. The first two
-- are fixed in the store (skillhub_record_sync); the third is a habit, and this is where the
-- habit is corrected.
-- ---------------------------------------------------------------------------
do $do$
begin
  if not exists (select 1 from public.skill_library where slug = 'mirror-a-live-system' and version = '1.0.0') then
    insert into public.skill_library (slug, name, description, skill_md, version, author_name, license, tags, visibility, status)
    values (
      'mirror-a-live-system',
      'Mirroring a CRM or ERP into the store',
      'Follow this when you are told to connect to a live system and keep a read-only copy of part of it here: what to mirror, the shape of a mirror table, the watermark, and where the run journal goes.',
      $md$---
    name: mirror-a-live-system
    description: Connect to a CRM or an ERP and keep a read-only mirror of part of it in the store. Covers scope, table shape, watermarks, the run journal and the reading rules.
    version: 1.0.0
    license: MIT
    ---

    # Mirroring a live system

    A file export is a photograph; a mirror is a subscription. This is the standard for the
    second kind: an API you can read, on a schedule, into tables here that people and agents
    query without touching the source.

    Proven against an Odoo instance on 2026-09-20: twenty models inventoried, twelve mirrored,
    the source's own identifiers kept throughout.

    ## Read-only means read-only

    Use only the source's read verbs -- list, search, read, export. No create, write, update,
    unlink, however convenient. A mirror that can write is not a mirror, it is a second master,
    and the first time the two disagree nobody will be able to say which was right. Say in your
    run record that no writes were made; that sentence is what an auditor reads.

    ## Choose the scope before you build anything

    Inventory first, decide second, build third. List the models, count the rows, and then pick
    what is worth mirroring. The test is not "can I read it" but **"will somebody ask a question
    this answers"**. A store full of reference tables nobody queries is worse than a store with
    four that get used: every one of them is indexed, costs tokens, and appears in the catalogue
    that agents read to decide where things go.

    Leave out what you were not asked for, and say so. Personal registers -- employees, users,
    contact lists held as personal data -- are out of scope unless somebody asked for them
    specifically, for the reasons in the store's own placement rule.

    A model with no rows is not a table yet. Build it when the data arrives; an empty mirror
    table is indistinguishable from a broken feed.

    ## The shape of a mirror table

    Build it with the house helper, never by hand:

        select public.create_shared_table('crm_leads', 'one row per lead in the CRM, keyed by its own id');

    Then the columns that make it a mirror rather than a copy:

    - **The source's own key**, as its own column and unique: `odoo_id`, `erp_no`, whatever the
      source calls it. Never a key you invented -- a re-read must collide and update, not
      duplicate. This is the same rule the CSV standard has for a business key.
    - **`source_system` and `source_model`** on every row: which system, and what it calls this
      data. Two systems can hold a "lead"; the row has to say whose.
    - **`extracted_at` and a run id**: when this row was read, and in which pass. A row's age is
      not the same as the feed's age, and the difference is how you find the one model that
      quietly stopped.
    - **The source's own change stamp**, kept as data: `write_date`, `modified`, a sequence. This
      is your watermark and it belongs on the row, not only in the register.
    - **`raw` as jsonb**: the whole payload as the source gave it. Parsing is a decision and
      decisions are wrong sometimes; the payload is the only thing that lets a later question be
      answered without a second round trip.

    Then say what the columns mean. `comment on column` is where the reading rules live -- a
    field that is false when it means "unset", a status with three spellings, a currency that
    has no code field. An agent reads those comments before it analyses; what you noticed and
    did not write there is lost.

    ## The watermark, and what an idle sync looks like

    Ask the source for what changed since the highest change stamp you already hold, not for
    everything. Then the second run is cheap, and the numbers tell you whether it worked:

        rows read - inserted - updated = skipped

    A healthy incremental sync skips nearly everything. **Zero inserted and zero updated is a
    success, not a failure**, as long as the watermark is where the source says it should be --
    and that is exactly why the watermark is recorded: without it, an idle feed and a broken one
    produce the same two zeroes.

    Never let a blank or false value from the source become a watermark. If the change stamp is
    missing on a model, say so and re-read that model in full; a silently converted blank is a
    watermark that never moves again.

    ## Where the run journal goes

    One call per table per run:

        skillhub_record_sync(source_system, target_table, source_model, rows_read,
                             inserted, updated, skipped, errors, watermark, run_id)

    Twenty models in one pass are twenty calls sharing one run id. This is not bookkeeping for
    its own sake: `platform.v_sources` reads it to say how fresh each feed is, and
    `platform.health()` uses it to notice when a feed has gone quiet -- which is how a scheduled
    load fails, silently, while nothing errors.

    **Do not write the run journal as a note.** Measured on 2026-09-20: six notes in seventeen
    minutes, each one embedded at a cost, each one competing with real knowledge in search, and
    none of them visible to the freshness view. The numbers belong in the register.

    Notes are for what you LEARNED about the source -- a field that lies, a model that is empty,
    a limit you hit. One note per discovery, not one per run. And when you work out a procedure
    the next integration should follow, publish a skill: that is the difference between a store
    that gets easier to add systems to and one that does not.

    ## If you are the caretaker, decide

    You may be both the agent that needs a table and the only one who can build it. Then
    `skillhub_request_structure` is a queue for your own thinking, which is fine -- but a
    request you filed and did not resolve is not deliberation, it is a stall, and nobody else is
    coming. Decide, build, resolve. Or decline your own request with the reason, which is
    equally good and leaves the reasoning where the next person can read it.

    Measured on 2026-09-20: nineteen open requests, all filed by the caretaker to itself, while
    the approval it was waiting for was written as notes to itself as well.

    ## Before you call it done

    - Every mirrored table registers a delivery on every run.
    - `select table_name, source_system, source_model, last_loaded, watermark, typical_gap, quiet
      from platform.v_sources` shows one row per model, with a rhythm after the third run.
    - The column comments carry what you noticed.
    - No table has zero rows.
    - Nothing was written to the source, and your run record says so.
    $md$,
      '1.0.0', 'skillhub', 'MIT',
      '{integration,mirror,erp,crm,house-standard}', 'public', 'published'
    );
  end if;
end $do$;

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
  || E'- `caretaker-operations` -- for the admin key: what to check, what to do, what to leave alone.\n'
  || E'- `mirror-a-live-system` -- connecting to a CRM or an ERP and keeping a read-only copy here.\n\n'
  || E'If you invent a way of working that works and others will need: write a skill, tag it\n'
  || E'`house-standard`, and add it to the list above. That is how the store learns.\n');
