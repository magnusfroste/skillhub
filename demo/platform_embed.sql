-- Automatic embedding. Run AFTER demo/platform_skillhub.sql.
--
-- The principle, as in AnythingLLM: whoever owns the intake owns the index. There is no
-- app here, so the database and its edge function do the work. Agents do not need to know
-- vectors exist -- they write a note and it becomes findable by meaning shortly after. The
-- alternative, putting the endpoint in every agent's prompt, produces an index that
-- reflects who was diligent rather than what exists, and spreads the key to every laptop.

-- What is waiting to be embedded, with the text and its hash.
-- Private rows are absent by design: nothing private is ever indexed, so a private note
-- cannot be found by meaning -- not by another agent and not by its owner.
create or replace function public.embed_candidates(max_rows int default 20) returns jsonb
language plpgsql stable security definer set search_path = public, platform as $$
declare j jsonb;
begin
  select coalesce(jsonb_agg(x), '[]'::jsonb) into j from (
    select 'skill' as source, s.slug as id,
           left(coalesce(s.name,'')||E'\n'||coalesce(s.description,'')||E'\n'||coalesce(s.skill_md,''), 8000) as text,
           md5(coalesce(s.name,'')||coalesce(s.description,'')||coalesce(s.skill_md,'')) as text_hash
    from public.skill_library s
    where s.status <> 'deprecated'
      and not exists (select 1 from platform.embeddings e
                      where e.source='skill' and e.id=s.slug
                        and e.text_hash = md5(coalesce(s.name,'')||coalesce(s.description,'')||coalesce(s.skill_md,'')))
    union all
    select 'note', n.id::text,
           left(coalesce(n.title,'')||E'\n'||coalesce(n.content,''), 8000),
           md5(coalesce(n.title,'')||coalesce(n.content,''))
    from public.notes n
    where n.visibility = 'public' and n.retired_at is null
      and not exists (select 1 from platform.embeddings e
                      where e.source='note' and e.id=n.id::text
                        and e.text_hash = md5(coalesce(n.title,'')||coalesce(n.content,'')))
    union all
    select 'document', d.id::text,
           left(coalesce(d.filename,'')||E'\n'||coalesce(d.description,''), 8000),
           md5(coalesce(d.filename,'')||coalesce(d.description,''))
    from public.documents d
    where d.visibility = 'public' and d.retired_at is null
      and not exists (select 1 from platform.embeddings e
                      where e.source='document' and e.id=d.id::text
                        and e.text_hash = md5(coalesce(d.filename,'')||coalesce(d.description,'')))
    union all
    -- Schema comments. Measured 2026-09-12: the rule that a column carries sentinel values
    -- lived in its comment, and a Swedish question could not reach an English comment --
    -- search('defekter') returned nothing while search('sentinel') found it. Keyword search
    -- cannot cross a language; meaning can. So the comments are indexed too, and the answer
    -- to "how must this data be read" stops depending on the reader guessing the right word
    -- in the right language.
    select 'schema', sc.obj_name,
           left(sc.obj_name || E'\n' || sc.cmt, 8000),
           md5(sc.cmt)
    from (
      select c.relname::text as obj_name, obj_description(c.oid) as cmt
      from pg_class c join pg_namespace n on n.oid=c.relnamespace
      where n.nspname='public' and c.relkind in ('r','v') and obj_description(c.oid) is not null
      union all
      select c.relname||'.'||a.attname, col_description(c.oid, a.attnum)
      from pg_class c join pg_namespace n on n.oid=c.relnamespace
      join pg_attribute a on a.attrelid=c.oid and a.attnum>0 and not a.attisdropped
      where n.nspname='public' and c.relkind in ('r','v') and col_description(c.oid, a.attnum) is not null
    ) sc
    where not exists (select 1 from platform.embeddings e
                      where e.source='schema' and e.id = sc.obj_name
                        and e.text_hash = md5(sc.cmt))
    limit max_rows) x;
  return j;
end $$;
comment on function public.embed_candidates(int) is 'Objects without a current embedding. text_hash means changed text is embedded again. A document is indexed on its filename and description only -- the contents are not in the store.';

-- Save a vector. jsonb in, vector out, so the edge function never has to know pgvector's
-- wire format. The parameters are prefixed p_ because "source" alone is ambiguous between
-- the plpgsql variable and the column inside ON CONFLICT, and Postgres refuses with
-- "column reference is ambiguous".
drop function if exists public.embed_save(text,text,text,jsonb,text);
create or replace function public.embed_save(p_source text, p_id text, p_model text, p_vector jsonb, p_text_hash text)
returns jsonb language plpgsql security definer set search_path = public, platform as $$
declare v vector;
begin
  begin
    v := (p_vector #>> '{}')::vector;
  exception when others then
    raise exception 'The vector could not be parsed. Send a JSON array of numbers with the right dimension.';
  end;
  insert into platform.embeddings (source, id, model, vector, text_hash)
  values (p_source, p_id, p_model, v, p_text_hash)
  on conflict (source, id, model) do update
    set vector = excluded.vector, text_hash = excluded.text_hash, created_at = now();
  return jsonb_build_object('source', p_source, 'id', p_id, 'model', p_model, 'dimension', vector_dims(v));
end $$;
comment on function public.embed_save(text,text,text,jsonb,text) is 'Writes one embedding. The same object and model is overwritten; different models live side by side.';

-- jsonb_array_length, not count(*): embed_candidates returns ONE row holding an array, so
-- count(*) was always 1 and the view claimed something was waiting even when the queue was
-- empty. The cast to bigint is needed because a view's column type cannot be changed by
-- CREATE OR REPLACE.
create or replace view platform.v_index_status as
select e.model, count(*) as embedded, max(e.created_at)::timestamp(0) as last_run,
       jsonb_array_length(public.embed_candidates(1000))::bigint as waiting
from platform.embeddings e group by e.model;
comment on view platform.v_index_status is 'How many objects are embedded per model, and how many are waiting.';

grant execute on all functions in schema public to service_role, postgres;

-- ---------------------------------------------------------------------------
-- Scheduling: the index should follow the content without anyone asking it to.
-- pg_cron is already in shared_preload_libraries in the supabase/postgres image, and
-- pg_net makes the HTTP call. The function is reached internally, without the gateway
-- and without a key. Requires a superuser.
-- ---------------------------------------------------------------------------
create extension if not exists pg_cron;
-- pg_net is what nudge_embed uses to call the indexer without making the write wait for it.
-- Supabase ships the extension but does not enable it, and nothing here created it -- so on
-- a fresh install the nudge failed silently and indexing fell back to the five-minute cron.
-- The write still succeeded, because the nudge swallows its own failures, which is exactly
-- why nobody would have noticed: something written would simply take up to five minutes to
-- become findable instead of three seconds. Found 2026-09-14 while checking what a new
-- Easypanel instance still needs.
do $pgnet$
begin
  create extension if not exists pg_net;
exception when others then
  -- pg_net needs a background worker, so it cannot be created unless the server was started
  -- with it preloaded. Where that is not the case, say so and carry on: the nudge swallows
  -- its own failures and the five-minute cron still indexes everything. Losing three-second
  -- findability is a degradation, not a reason to refuse to build the store -- but it must
  -- be visible, because the symptom is "I wrote it and my colleague cannot find it yet".
  raise warning 'pg_net could not be enabled (%): index-on-write is off, and new content becomes findable on the five-minute cron instead of in about three seconds. Enable pg_net in the database and re-run the seed to turn it back on.', sqlerrm;
end $pgnet$;

do $$
begin
  perform cron.unschedule('embed');
exception when others then null;
end $$;

select cron.schedule('embed', '*/5 * * * *', $job$
  select net.http_post(
    url := 'http://functions:9000/embed?batch=100',
    headers := '{"Content-Type":"application/json"}'::jsonb,
    timeout_milliseconds := 120000);
$job$);

comment on extension pg_cron is 'In-database scheduling. The "embed" job keeps the vector index in step with the content every five minutes.';

-- The search log exists to answer "did you look before you published", and a log that grows
-- forever is a liability. Seven days is plenty for a fifteen-minute check.
do $$
begin
  perform cron.unschedule('tool_log_prune');
exception when others then null;
end $$;

select cron.schedule('tool_log_prune', '17 3 * * *',
  $job$ delete from platform.tool_log where at < now() - interval '7 days'; $job$);

-- What the job did last, for troubleshooting without digging through logs.
create or replace view platform.v_embed_queue as
select j.jobname, j.schedule, j.active,
       r.status, r.start_time::timestamp(0) as started, r.end_time::timestamp(0) as ended,
       left(coalesce(r.return_message,''), 120) as message
from cron.job j
left join lateral (select * from cron.job_run_details d
                   where d.jobid = j.jobid order by d.start_time desc limit 3) r on true
where j.jobname = 'embed'
order by r.start_time desc nulls last;
comment on view platform.v_embed_queue is 'The last runs of the embedding job. Empty means it has not run yet.';

grant select on all tables in schema platform to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Index on write, not on a schedule.
--
-- This function and its three triggers ran in production from 2026-09-12 and existed in no
-- file until 2026-09-14, when seeding an empty database showed them missing. Indexing on the
-- five-minute cron alone was measured at two minutes nine seconds worst case: an agent writes
-- a rule, a colleague asks about it forty seconds later, and the store says there is nothing.
-- Three seconds with the nudge.
--
-- Two deliberate choices in the body. The call does not wait for the indexer, so a write is
-- never slowed by it; and every failure is swallowed, because an index that is late is a
-- nuisance while a write that fails because the indexer was down is a bug. The cron stays as
-- the net that catches whatever the nudge missed.
-- ---------------------------------------------------------------------------
create or replace function platform.nudge_embed() returns trigger
language plpgsql security definer set search_path = public, platform as $$
begin
  -- Only public content is ever indexed, so a private row has nothing to nudge.
  if coalesce(to_jsonb(new) ->> 'visibility', 'public') <> 'public' then
    return null;
  end if;
  perform net.http_post(
    url := 'http://functions:9000/embed?batch=20',
    headers := '{"Content-Type":"application/json"}'::jsonb,
    timeout_milliseconds := 60000);
  return null;
exception when others then
  -- An index that is late is a nuisance; a write that fails because the indexer was down is
  -- a bug. The scheduled job will pick it up.
  return null;
end $$;

do $nudge$
declare t text;
begin
  foreach t in array array['notes','skill_library','documents'] loop
    if to_regclass('public.'||t) is not null then
      execute format('drop trigger if exists platform_nudge_embed on public.%I', t);
      execute format('create trigger platform_nudge_embed after insert or update on public.%I '
                     'for each row execute function platform.nudge_embed()', t);
    end if;
  end loop;
end $nudge$;
