-- Lifecycle and files. Run AFTER demo/platform.sql.
--
-- Why: a shared store does not die of too little content, it dies of too much old
-- content. What actually kills a SharePoint is that nothing is ever retired, so search
-- fills up with things that were true two years ago. Here every skill has a lifecycle,
-- every file has a place that is not a text column, and the organisation gets a daily
-- report it can read without SQL.

-- ---------------------------------------------------------------------------
-- 1) Skills get a lifecycle: draft -> published -> superseded / retired.
-- ---------------------------------------------------------------------------
alter table public.skill_library
  add column if not exists superseded_by text,
  add column if not exists verified_at   timestamptz,
  add column if not exists verified_by   text,
  add column if not exists deprecated_at timestamptz,
  add column if not exists deprecated_reason text;

comment on column public.skill_library.superseded_by is 'Slug of the skill that replaces this one. Set it instead of deleting.';
comment on column public.skill_library.verified_at is 'When someone last confirmed the content still holds.';
comment on column public.skill_library.deprecated_at is 'When it was retired. A retired skill disappears from search but stays for traceability.';

-- The status values came from an agent's own migration and had no 'deprecated'.
-- Extend rather than replace: draft -> published -> deprecated, plus what was there.
do $$
declare def text;
begin
  select pg_get_constraintdef(oid) into def from pg_constraint where conname = 'skill_library_status_check';
  if def is not null and def not like '%deprecated%' then
    alter table public.skill_library drop constraint skill_library_status_check;
    alter table public.skill_library add constraint skill_library_status_check
      check (status in ('draft','published','deprecated','archived'));
  end if;
end $$;

-- Retire instead of deleting: the history is the whole point.
--
-- Note what this function does not do: it does not ask who is calling, so any agent can
-- retire any agent's skill with it. The ownership check belongs in the tool that wraps
-- it, where the gateway's verified identity is available -- see the build order in
-- demo/REFACTOR-EN.md. Calling this directly is an admin action.
-- The three-argument form is dropped first: `create or replace` with a new signature adds
-- an OVERLOAD, and the old one would keep answering three-argument callers as if nothing
-- had changed. This four-argument version ran in production from 2026-09-14 and existed in
-- no file -- applied from a scratch file while the caller in platform_tools.sql was updated
-- in the repo -- so a fresh install had a caller with four arguments and a function with
-- three, and every skill retirement failed with "function does not exist". Found by the
-- smoke test on a virgin instance; the empty-database test now retires a skill so it
-- cannot recur silently.
drop function if exists public.retire_skill(text, text, text);

-- retire_skill with an author scope, and it stops erasing the version chain.
--
-- Ownership in the library is per VERSION. Retire used to check the author of the newest
-- version and then update `where slug = slug_in` -- every row of that slug, whoever wrote
-- it -- so publishing a better version of a colleague's skill quietly made you able to
-- retire theirs. Verified 2026-09-14: agent_01 retired agent_03's v1.0.0, and the
-- superseded_by link on it was overwritten with null in the same statement.
--
-- The caretaker passes only_author => null and retires the whole slug. That is its job.
create or replace function public.retire_skill(
  slug_in text, reason text default null, replaced_by text default null,
  only_author text default null) returns text
language plpgsql security definer set search_path = public, platform as $$
declare n int;
begin
  if replaced_by is not null and not exists (select 1 from public.skill_library where slug = replaced_by) then
    raise exception 'The replacement % does not exist. Publish it first.', replaced_by;
  end if;
  update public.skill_library
     set status = 'deprecated', deprecated_at = now(),
         deprecated_reason = reason,
         -- coalesce, not assignment: a retire with no replacement named must not wipe the
         -- link a later publish already set.
         superseded_by = coalesce(replaced_by, superseded_by),
         updated_at = now()
   where slug = slug_in
     and (only_author is null or author_name = only_author);
  get diagnostics n = row_count;
  if n = 0 then
    if only_author is null then raise exception 'No skill with slug %', slug_in;
    else raise exception 'You have no version of "%" to retire -- every version there belongs to somebody else.', slug_in;
    end if;
  end if;
  return format('%s: %s version(s) retired%s', slug_in, n, coalesce(', replaced by '||replaced_by, ''));
end $$;
comment on function public.retire_skill(text,text,text,text) is 'Mark a skill as superseded or out of date, scoped to the caller''s own versions unless only_author is null (the caretaker). Never delete a skill -- somebody may have followed it.';

-- Confirm a skill still holds. This is what separates a living library from an archive.
create or replace function public.confirm_skill(slug_in text, agent text)
returns text language plpgsql as $$
declare n int;
begin
  update public.skill_library set verified_at = now(), verified_by = agent, updated_at = now()
   where slug = slug_in;
  get diagnostics n = row_count;
  if n = 0 then raise exception 'No skill with slug %', slug_in; end if;
  return format('%s confirmed by %s', slug_in, agent);
end $$;
comment on function public.confirm_skill(text,text) is 'Attest that a skill still holds. Run it after you followed one and it worked.';

-- ---------------------------------------------------------------------------
-- 2) Files: a place that is not a text column.
--
-- Background: an agent base64-encoded a 2.2 MB Excel file in six parts straight into a
-- table. It worked, and it took Studio down with a 502 on every large statement, and
-- left the file impossible to open. The rule is: contents in Storage, metadata here.
--
-- An honest limit: MCP cannot upload bytes. The file itself is uploaded by a person in
-- Studio, or by something holding the service key. The agent registers, searches and
-- references -- it does not carry the contents.
-- ---------------------------------------------------------------------------
select public.create_shared_table('documents', 'Files in the store. The contents live in Storage; this table is the catalogue of them.');
alter table public.documents
  add column if not exists filename    text not null,
  add column if not exists bucket      text not null default 'shared',
  add column if not exists path        text,
  add column if not exists mime_type   text,
  add column if not exists bytes       bigint,
  add column if not exists sha256      text,
  add column if not exists description text,
  add column if not exists source      text;
comment on column public.documents.path is 'Path inside the bucket. Empty until someone uploads the contents.';
comment on column public.documents.source is 'Where the file came from: a system, a sender, a URL.';
comment on column public.documents.sha256 is 'Checksum of the contents, so duplicates can be spotted.';

-- Soft deletion. These three columns are what make skillhub_retire work, and until
-- 2026-09-14 they existed only in the live database -- added by hand and committed to no
-- file. A fresh deploy would have produced a store where retiring anything fails, which is
-- one of the ten criteria this system is measured against. Found by seeding an empty
-- database and diffing its columns against production. Nothing prevents that kind of drift
-- except applying the files as the only way a schema changes.
alter table public.documents
  add column if not exists retired_at     timestamptz,
  add column if not exists retired_by     text,
  add column if not exists retired_reason text;
comment on column public.documents.retired_at is 'When it was retired. Retired rows leave search and stay readable -- nothing here is ever deleted, because the change log keeps no contents.';
comment on column public.documents.retired_by is 'Who retired it. Comes from the gateway, not from the caller.';
comment on column public.documents.retired_reason is 'Why it stopped applying. Required: whoever finds it next needs to know.';

create index if not exists documents_sha_idx on public.documents (sha256);

-- Search now knows about documents. Same ownership filter as the other sources: a
-- private document belongs to its owner alone.
create or replace function platform.search(phrase text, max_hits int default 10, agent text default null)
returns table (source text, id text, title text, excerpt text, rank real)
language sql stable as $$
  with q as (select websearch_to_tsquery('swedish', replace(trim(phrase), ' ', ' OR ')) as tq, phrase as raw)
  select 'skill', s.slug, s.name,
         left(coalesce(s.description,''), 180),
         ts_rank(to_tsvector('swedish', coalesce(s.name,'')||' '||coalesce(s.description,'')||' '||coalesce(s.skill_md,'')), q.tq)
  from platform.v_current_skills s, q
  where true
    and (s.visibility = 'public' or s.author_name = search.agent)
    and (to_tsvector('swedish', coalesce(s.name,'')||' '||coalesce(s.description,'')||' '||coalesce(s.skill_md,'')) @@ q.tq
         or s.slug ilike '%'||q.raw||'%')
  union all
  select 'note', n.id::text, n.title,
         left(coalesce(n.content,''), 180),
         ts_rank(to_tsvector('swedish', coalesce(n.title,'')||' '||coalesce(n.content,'')), q.tq)
  from public.notes n, q
  where (n.visibility = 'public' or n.owner = search.agent)
    and n.retired_at is null
    and to_tsvector('swedish', coalesce(n.title,'')||' '||coalesce(n.content,'')) @@ q.tq
  union all
  select 'document', d.id::text, d.filename,
         left(coalesce(d.description,''), 180),
         ts_rank(to_tsvector('swedish', coalesce(d.filename,'')||' '||coalesce(d.description,'')), q.tq)
  from public.documents d, q
  where (d.visibility = 'public' or d.owner = search.agent)
    and d.retired_at is null
    and to_tsvector('swedish', coalesce(d.filename,'')||' '||coalesce(d.description,'')) @@ q.tq
  union all
  select 'table', c.relname, c.relname, left(coalesce(obj_description(c.oid),''), 180), 0.1::real
  from pg_class c join pg_namespace n on n.oid=c.relnamespace, q
  where n.nspname='public' and c.relkind in ('r','v')
    and (c.relname ilike '%'||q.raw||'%' or coalesce(obj_description(c.oid),'') ilike '%'||q.raw||'%')
  union all
  -- Column comments -- see the note in platform.sql. This is where "how this data has to be
  -- read" actually lives, so search has to reach it.
  select 'column', c.relname||'.'||a.attname, c.relname||'.'||a.attname,
         left(col_description(c.oid, a.attnum), 180), 0.2::real
  from pg_class c
  join pg_namespace n on n.oid=c.relnamespace
  join pg_attribute a on a.attrelid=c.oid and a.attnum > 0 and not a.attisdropped, q
  where n.nspname='public' and c.relkind in ('r','v')
    and col_description(c.oid, a.attnum) is not null
    and (col_description(c.oid, a.attnum) ilike '%'||q.raw||'%'
         or to_tsvector('swedish', col_description(c.oid, a.attnum)) @@ q.tq)
  order by 5 desc, 3
  limit max_hits;
$$;

create or replace view platform.v_documents as
select d.filename, d.bucket, coalesce(d.path,'(not uploaded)') as path,
       pg_size_pretty(coalesce(d.bytes,0)) as size, d.mime_type,
       d.owner as registered_by, d.visibility,
       d.created_at::timestamp(0) as registered,
       (d.path is null) as content_missing
from public.documents d order by d.created_at desc;
comment on view platform.v_documents is 'The file catalogue. content_missing = the record exists but nobody uploaded the file, so its contents are not in the store and cannot be quoted.';

-- ---------------------------------------------------------------------------
-- 3) What is going stale: one list of everything that lost its currency.
-- ---------------------------------------------------------------------------
create or replace view platform.v_going_stale as
select 'skill never confirmed' as kind, s.slug as object,
       (now() - s.created_at)::interval as age,
       'run: select public.confirm_skill('''||s.slug||''', ''your_agent'') if it still holds' as action
from public.skill_library s
where s.status = 'published' and s.verified_at is null and s.created_at < now() - interval '30 days'
union all
select 'skill unconfirmed >90 days', s.slug, now() - s.verified_at,
       'run: select public.confirm_skill('''||s.slug||''', ''your_agent'') or retire_skill'
from public.skill_library s
where s.status = 'published' and s.verified_at < now() - interval '90 days'
union all
select 'note untouched >180 days', left(n.title,60), now() - n.updated_at,
       'read and update it, or remove it if it is out of date'
from public.notes n
where n.updated_at < now() - interval '180 days'
union all
select 'document without contents', d.filename, now() - d.created_at,
       'upload the file to Storage and fill in path, or remove the record'
from public.documents d
where d.path is null and d.created_at < now() - interval '7 days'
union all
select 'table without writes >90 days', c.table_name, now() - c.last_changed,
       'is it needed? if not: drop table'
from platform.v_catalog c
where c.last_changed < now() - interval '90 days'
order by 3 desc;
comment on view platform.v_going_stale is 'What has lost its currency. Go through it once a month, or the store becomes an archive.';

-- ---------------------------------------------------------------------------
-- 4) Daily report: an overview without SQL, in plain text.
-- ---------------------------------------------------------------------------
create or replace function platform.daily_report(days int default 1) returns text
language plpgsql stable as $$
declare
  out_text text := '';
  r  record;
  n  int;
begin
  out_text := format(E'THE STORE -- last %s day(s) (%s)\n\n', days, to_char(now(),'YYYY-MM-DD HH24:MI'));

  select count(*) into n from platform.events where at > now() - (days||' days')::interval;
  if n = 0 then
    out_text := out_text || E'No writes in the period.\n';
  else
    out_text := out_text || format(E'%s writes by %s agents.\n\nWHO DID WHAT\n', n,
           (select count(distinct agent) from platform.events where at > now() - (days||' days')::interval));
    for r in
      select coalesce(agent,'(unknown)') as agent, table_name,
             count(*) filter (where operation='insert') as inserted,
             count(*) filter (where operation='update') as updated,
             count(*) filter (where operation='delete') as deleted
      from platform.events where at > now() - (days||' days')::interval
      group by 1,2 order by 3 desc nulls last, 1
    loop
      out_text := out_text || format(E'  %-12s %-22s %s new, %s changed, %s removed\n',
                    r.agent, r.table_name, r.inserted, r.updated, r.deleted);
    end loop;
  end if;

  out_text := out_text || E'\nNEW IN THE LIBRARY\n';
  n := 0;
  -- One line per slug, at its current version: four versions of one skill in a day is one
  -- new skill, not four (report on the demo, 2026-09-16).
  for r in select s.slug, s.name, s.author_name, s.version,
                  (select count(*) from public.skill_library x where x.slug = s.slug
                     and x.created_at > now() - (days||' days')::interval) as versions
             from platform.v_current_skills s
            where exists (select 1 from public.skill_library x where x.slug = s.slug
                           and x.created_at > now() - (days||' days')::interval)
            order by s.created_at
  loop out_text := out_text || format(E'  %s -- %s (%s%s)\n', r.slug, r.name, r.author_name,
         case when r.versions > 1 then format(', %s versions, now %s', r.versions, r.version) else '' end); n := n + 1; end loop;
  if n = 0 then out_text := out_text || E'  nothing new\n'; end if;

  out_text := out_text || E'\nNEW TABLES\n';
  n := 0;
  for r in select object, role, coalesce(description,'(no description)') as description
             from platform.v_new_tables where created > now() - (days||' days')::interval
  loop out_text := out_text || format(E'  %s -- %s\n', r.object, r.description); n := n + 1; end loop;
  if n = 0 then out_text := out_text || E'  none\n'; end if;

  -- Growth, where somebody will see it. A list of tables says what exists; it does not say
  -- there were seven last month and forty-three now, and a number that grows in front of
  -- people is the cheapest brake there is.
  select coalesce(sum(tables_created), 0) into n from platform.v_growth
   where month >= date_trunc('month', now())::date;
  out_text := out_text || format(E'\nSTRUCTURE: %s tables now, %s created this month\n',
    (select count(*) from platform.v_catalog), n);

  -- The queue the caretaker exists to serve. An agent that needed a structure and could not
  -- get one wrote records as prose instead, and nobody saw the need appear.
  select count(*) into n from platform.structure_requests where status = 'open';
  if n > 0 then
    out_text := out_text || format(E'\nSTRUCTURE REQUESTS: %s open -- select * from platform.v_structure_requests\n', n);
    for r in select id, requested_by, left(purpose, 90) as purpose from platform.structure_requests
              where status = 'open' order by at loop
      out_text := out_text || format(E'  #%s from %s: %s\n', r.id, r.requested_by, r.purpose);
    end loop;
  end if;

  select count(*) into n from platform.v_action_items;
  out_text := out_text || format(E'TO ACT ON: %s items (platform.v_action_items)\n', n);
  select count(*) into n from platform.v_going_stale;
  out_text := out_text || format(E'GOING STALE: %s items (platform.v_going_stale)\n', n);
  return out_text;
end $$;
comment on function platform.daily_report(int) is 'A readable summary of what happened. Run select platform.daily_report(7) for a week.';

grant select on all tables in schema platform to anon, authenticated, service_role;
grant execute on all functions in schema platform to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5) Into the conventions skill, or no agent knows any of this exists.
-- ---------------------------------------------------------------------------
update public.skill_library
   set skill_md = regexp_replace(skill_md, E'\n## Lifecycle and files.*$', '', 'n')
                  || E'\n## Lifecycle and files\n\n'
                  || E'Never delete a skill. If it turned out wrong or went out of date:\n'
                  || E'  select public.retire_skill(''slug'', ''why'', ''replacement-slug'');\n'
                  || E'Retired skills disappear from search but stay for traceability.\n\n'
                  || E'If you followed a skill and it worked -- say so:\n'
                  || E'  select public.confirm_skill(''slug'', ''agent_NN'');\n'
                  || E'That is the difference between a living library and an archive. See\n'
                  || E'platform.v_going_stale for what nobody has confirmed in a long time.\n\n'
                  || E'Files: NEVER put contents (base64) in a column. Register the file in the\n'
                  || E'`documents` table with filename, mime type, bytes, sha256 and a description. The\n'
                  || E'contents are uploaded to Storage by a person -- you cannot upload bytes over MCP.\n'
                  || E'A row without a path means "waiting for upload" and shows in platform.v_documents.\n'
                  || E'It also means the store does not hold what the file SAYS: if you are asked what a\n'
                  || E'document contains and the content is missing, say so rather than guessing from the\n'
                  || E'filename.\n',
       version = '2.1.0', updated_at = now()
 where slug = 'store-conventions';
