-- Automatic embedding. Run AFTER demo/platform_skillhub.sql.
--
-- The principle, as in AnythingLLM: whoever owns the intake owns the index. There is no
-- app here, so the database and its edge function do the work. Agents do not need to know
-- vectors exist -- they write a note and it becomes findable by meaning shortly after. The
-- alternative, putting the endpoint in every agent's prompt, produces an index that
-- reflects who was diligent rather than what exists, and spreads the key to every laptop.

-- Cutting an object into chunks the embedder accepts. On the object's own headings first;
-- a section over the budget on blank lines; a paragraph over the budget hard. Consecutive
-- pieces are packed back together up to the budget, so a short skill stays one chunk and a
-- long one becomes a handful, each carrying the title so the vector knows what it is part of.
-- head is the first line of the chunk: what a hit reports as "found in section ...".
create or replace function platform.chunk_text(title text, body text, max_chars int default 6000)
returns table (chunk int, head text, content text)
language plpgsql immutable as $$
declare
  t text := coalesce(title, '');
  budget int := greatest(coalesce(max_chars, 6000) - length(t) - 1, 200);
  units text[] := '{}';
  sec text; para text; piece text; u text;
  cur text := ''; n int := 0;
begin
  for sec in select x from regexp_split_to_table(coalesce(body, ''), E'(?n)(?=^#{1,6} )') x loop
    if btrim(sec) = '' then continue; end if;
    if length(sec) <= budget then
      units := units || sec;
    else
      for para in select x from regexp_split_to_table(sec, E'\n[ \t]*\n') x loop
        if btrim(para) = '' then continue; end if;
        if length(para) <= budget then
          units := units || para;
        else
          piece := para;
          while length(piece) > 0 loop
            units := units || substr(piece, 1, budget);
            piece := substr(piece, budget + 1);
          end loop;
        end if;
      end loop;
    end if;
  end loop;
  if coalesce(array_length(units, 1), 0) = 0 then
    chunk := 0; head := left(t, 80); content := t; return next; return;
  end if;
  foreach u in array units loop
    if cur <> '' and length(cur) + 2 + length(u) > budget then
      chunk := n; head := left(split_part(btrim(cur), E'\n', 1), 80); content := t || E'\n' || cur;
      return next; n := n + 1; cur := '';
    end if;
    cur := case when cur = '' then u else cur || E'\n\n' || u end;
  end loop;
  if cur <> '' then
    chunk := n; head := left(split_part(btrim(cur), E'\n', 1), 80); content := t || E'\n' || cur;
    return next;
  end if;
end $$;
comment on function platform.chunk_text(text, text, int) is 'Cuts a text on its headings into chunks of at most max_chars, each prefixed with the title. Short texts stay one chunk.';

-- What is waiting to be embedded: every chunk of every object whose text changed, with the
-- object's hash. max_chars is what the indexer found the endpoint accepts.
-- Private rows are absent by design: nothing private is ever indexed, so a private note
-- cannot be found by meaning -- not by another agent and not by its owner.
drop view if exists platform.v_index_status;
drop function if exists public.embed_candidates(int);
create or replace function public.embed_candidates(max_rows int default 20, max_chars int default 6000) returns jsonb
language plpgsql stable security definer set search_path = public, platform as $$
declare j jsonb;
begin
  with objects as (
    select 'skill' as source, s.slug as id, coalesce(s.name,'') as title,
           left(coalesce(s.description,'')||E'\n\n'||coalesce(s.skill_md,''), 60000) as body,
           md5(coalesce(s.name,'')||coalesce(s.description,'')||coalesce(s.skill_md,'')) as text_hash
    from platform.v_current_skills s
    where not exists (select 1 from platform.embeddings e
                      where e.source='skill' and e.id=s.slug and e.chunk = 0
                        and e.text_hash = md5(coalesce(s.name,'')||coalesce(s.description,'')||coalesce(s.skill_md,'')))
    union all
    select 'note', n.id::text, coalesce(n.title,''), left(coalesce(n.content,''), 60000),
           md5(coalesce(n.title,'')||coalesce(n.content,''))
    from public.notes n
    where n.visibility = 'public' and n.retired_at is null
      and not exists (select 1 from platform.embeddings e
                      where e.source='note' and e.id=n.id::text and e.chunk = 0
                        and e.text_hash = md5(coalesce(n.title,'')||coalesce(n.content,'')))
    union all
    select 'document', d.id::text, coalesce(d.filename,''), coalesce(d.description,''),
           md5(coalesce(d.filename,'')||coalesce(d.description,''))
    from public.documents d
    where d.visibility = 'public' and d.retired_at is null
      and not exists (select 1 from platform.embeddings e
                      where e.source='document' and e.id=d.id::text and e.chunk = 0
                        and e.text_hash = md5(coalesce(d.filename,'')||coalesce(d.description,'')))
    union all
    -- Schema comments. Measured 2026-09-12: the rule that a column carries sentinel values
    -- lived in its comment, and a Swedish question could not reach an English comment --
    -- search('defekter') returned nothing while search('sentinel') found it. Keyword search
    -- cannot cross a language; meaning can. So the comments are indexed too, and the answer
    -- to "how must this data be read" stops depending on the reader guessing the right word
    -- in the right language.
    select 'schema', sc.obj_name, sc.obj_name, sc.cmt, md5(sc.cmt)
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
                      where e.source='schema' and e.id = sc.obj_name and e.chunk = 0
                        and e.text_hash = md5(sc.cmt))
    limit max_rows)
  select coalesce(jsonb_agg(jsonb_build_object('source', o.source, 'id', o.id, 'chunk', c.chunk,
                    'head', c.head, 'text', c.content, 'text_hash', o.text_hash)), '[]'::jsonb) into j
  from objects o cross join lateral platform.chunk_text(o.title, o.body, max_chars) c;
  return j;
end $$;
comment on function public.embed_candidates(int, int) is 'Chunks of objects without a current embedding, max_rows OBJECTS at a time, cut to max_chars. text_hash is the whole object''s, so changed text is embedded again. A document is indexed on its filename and description only -- the contents are not in the store.';

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

-- All chunks of one object in one transaction: what was there for the object goes, what the
-- indexer just computed comes in. p_vectors is a JSON array of arrays, p_heads the chunk
-- heads in the same order. Nothing is saved for an object until every chunk embedded.
create or replace function public.embed_save_chunks(p_source text, p_id text, p_model text, p_vectors jsonb, p_heads jsonb, p_text_hash text)
returns jsonb language plpgsql security definer set search_path = public, platform as $$
declare k int; n int := jsonb_array_length(p_vectors);
begin
  if n = 0 then raise exception 'No vectors to save for %/%.', p_source, p_id; end if;
  delete from platform.embeddings where source = p_source and id = p_id and model = p_model;
  for k in 0 .. n - 1 loop
    insert into platform.embeddings (source, id, model, chunk, head, vector, text_hash)
    values (p_source, p_id, p_model, k, left(p_heads ->> k, 80), (p_vectors -> k #>> '{}')::vector, p_text_hash);
  end loop;
  return jsonb_build_object('source', p_source, 'id', p_id, 'model', p_model, 'chunks', n);
end $$;
comment on function public.embed_save_chunks(text,text,text,jsonb,jsonb,text) is 'Replaces every chunk of one object and model with the vectors given, in one transaction.';

-- ---------------------------------------------------------------------------
-- The embedder, as the store knows it. One row. The indexer probes the endpoint -- which
-- dimension the model returns, how much text it accepts -- and writes what it found here,
-- with the result of each run. skillhub_overview shows it, so "meaning search is off" or
-- "the last run failed on note X" is visible to every agent instead of being a silent cron.
-- ---------------------------------------------------------------------------
create table if not exists platform.embedder (
  id            int primary key default 1 check (id = 1),
  url           text,
  model         text,
  dimension     int,
  max_tokens    int,
  max_chars     int,
  limit_source  text,            -- 'tei /info' | 'vllm /v1/models' | 'probe' | 'env'
  probed_at     timestamptz,
  status        text,            -- 'off' | 'ok' | 'error'
  last_run      timestamptz,
  last_embedded int,
  last_failed   int,
  last_truncated int,           -- chunks cut at the model's limit in the last run
  chars_per_token numeric,      -- measured on this endpoint's tokenizer, not assumed
  last_error    text
);
alter table platform.embedder add column if not exists last_truncated int;
alter table platform.embedder add column if not exists chars_per_token numeric;
comment on table platform.embedder is 'What the indexer found out about the embedding endpoint, and how its last run went. Written by the indexer; read by skillhub_overview.';

create or replace function public.embedder_save(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, platform as $$
begin
  insert into platform.embedder as x (id, url, model, dimension, max_tokens, max_chars, limit_source, probed_at,
                                      status, last_run, last_embedded, last_failed, last_truncated, chars_per_token, last_error)
  values (1, p->>'url', p->>'model', (p->>'dimension')::int, (p->>'max_tokens')::int, (p->>'max_chars')::int,
          p->>'limit_source', (p->>'probed_at')::timestamptz, p->>'status', (p->>'last_run')::timestamptz,
          (p->>'last_embedded')::int, (p->>'last_failed')::int, (p->>'last_truncated')::int,
          (p->>'chars_per_token')::numeric, p->>'last_error')
  on conflict (id) do update set
    url = coalesce(excluded.url, x.url), model = coalesce(excluded.model, x.model),
    dimension = coalesce(excluded.dimension, x.dimension), max_tokens = coalesce(excluded.max_tokens, x.max_tokens),
    max_chars = coalesce(excluded.max_chars, x.max_chars), limit_source = coalesce(excluded.limit_source, x.limit_source),
    probed_at = coalesce(excluded.probed_at, x.probed_at), status = coalesce(excluded.status, x.status),
    last_run = coalesce(excluded.last_run, x.last_run), last_embedded = coalesce(excluded.last_embedded, x.last_embedded),
    last_failed = coalesce(excluded.last_failed, x.last_failed),
    last_truncated = coalesce(excluded.last_truncated, x.last_truncated),
    chars_per_token = coalesce(excluded.chars_per_token, x.chars_per_token),
    last_error = case when p ? 'last_error' then p->>'last_error' else x.last_error end;
  return (select to_jsonb(e) from platform.embedder e where id = 1);
end $$;
revoke execute on function public.embedder_save(jsonb) from public, anon, authenticated;
grant execute on function public.embedder_save(jsonb) to service_role;

-- The row as it is, for the indexer's own use (settings it wrote last time).
create or replace function public.embedder_get() returns jsonb
language sql stable security definer set search_path = public, platform as $$
  select coalesce((select to_jsonb(e) from platform.embedder e where id = 1), '{}'::jsonb);
$$;
revoke execute on function public.embedder_get() from public, anon, authenticated;
grant execute on function public.embedder_get() to service_role;

create or replace function public.embed_set_dim(wanted int) returns text
language sql security definer set search_path = platform, public as $$
  select platform.set_vector_dim(wanted);
$$;
revoke execute on function public.embed_set_dim(int) from public, anon, authenticated;
grant execute on function public.embed_set_dim(int) to service_role;

-- What every agent sees in skillhub_overview. Cheap: one row plus two counts.
create or replace function public.embedder_status() returns jsonb
language sql stable security definer set search_path = public, platform as $$
  select jsonb_build_object(
    'meaning_search', case when e.status = 'ok' then 'on' when e.status = 'error' then 'error' else 'off' end,
    'model', e.model, 'dimension', e.dimension,
    'table_dimension', (select atttypmod from pg_attribute where attrelid = 'platform.embeddings'::regclass and attname = 'vector'),
    'max_chars_per_chunk', e.max_chars, 'limit_from', e.limit_source,
    'objects', (select count(distinct (source, id)) from platform.embeddings),
    'chunks', (select count(*) from platform.embeddings),
    'waiting', jsonb_array_length(public.embed_candidates(1000, 100000)),
    'chars_per_token', e.chars_per_token,
    'last_run', e.last_run::timestamp(0), 'last_embedded', e.last_embedded, 'last_failed', e.last_failed,
    -- Truncation is the quiet failure of this design: on vLLM an over-budget chunk is CUT,
    -- not refused, and a partially indexed rule is worse than an unindexed one because
    -- nothing says so. Any number above zero here means the chunk size is too generous for
    -- this content -- set EMBEDDING_MAX_CHARS lower.
    'last_truncated', e.last_truncated,
    'last_error', e.last_error,
    'note', case when e.status is null or e.status = 'off'
                 then 'EMBEDDING_URL is not set: keyword search works, search by meaning does not, and new content is found only by its words. Set EMBEDDING_URL, EMBEDDING_KEY and EMBEDDING_MODEL; the indexer works out the rest.'
                 when coalesce(e.last_truncated, 0) > 0 then 'The last run CUT ' || e.last_truncated || ' chunk(s) at the model''s input limit: that content is indexed in part, silently. Set EMBEDDING_MAX_CHARS below max_chars_per_chunk and re-run.'
                 when e.status = 'error' then 'The indexer''s last run failed; see last_error. Keyword search is unaffected.'
                 else null end)
  from (select * from platform.embedder where id = 1
        union all select 1, null,null,null,null,null,null,null,'off',null,null,null,null,null,null
        limit 1) e;
$$;
comment on function public.embedder_status() is 'Whether search by meaning is on, which model, and how the last indexing run went. Shown in skillhub_overview.';

-- Per model: objects, chunks, and how many objects are waiting (one row holding an array,
-- hence jsonb_array_length; the cast because a view's column type cannot change in place).
create or replace view platform.v_index_status as
select e.model, count(distinct (e.source, e.id)) as embedded, count(*) as chunks,
       max(e.created_at)::timestamp(0) as last_run,
       (select count(distinct (c->>'source', c->>'id'))
          from jsonb_array_elements(public.embed_candidates(1000, 100000)) c)::bigint as waiting
from platform.embeddings e group by e.model;
comment on view platform.v_index_status is 'How many objects and chunks are embedded per model, and how many objects are waiting.';

grant execute on all functions in schema public to service_role, postgres;

-- ---------------------------------------------------------------------------
-- Rebuilding the index from scratch. The caretaker's call, and the only place in this
-- store where deleting everything is the right answer.
--
-- platform.embeddings is a CACHE, not a record: source and id point at the object, chunk
-- and head come from platform.chunk_text, text_hash from the object's own text, and the
-- vector from the model. Every row is derivable from skill_library, notes, documents and
-- the schema comments, which is why emptying it loses nothing -- and why nothing else in
-- the store may be emptied at all.
--
-- It is needed when the model's dimension changes, because pgvector carries the dimension
-- in the column type: a 4,096 query against 1,536 rows raises "different vector
-- dimensions" on every similarity call, and on the fallback search makes when keywords
-- miss. An empty table raises nothing, so the emptying comes FIRST and the index is dark
-- for a few minutes instead of broken. A new model of the SAME dimension needs none of
-- this: the key is (source, id, model, chunk) and similar() filters on the model name, so
-- the new one indexes alongside the old and EMBEDDING_MODEL decides which is read.
--
-- Doing it by hand is two statements in the right order plus a call, and the order is the
-- part people get wrong -- including here, on 2026-09-16, which is why this exists.
create or replace function platform.reindex(reason text, by_agent text default 'service_role',
  indexer_url text default 'http://functions:9000/embed?batch=100&budget=120&probe=1') returns text
language plpgsql security definer set search_path = platform, public as $$
declare
  n bigint; old_model text; old_dim int; note text := '';
begin
  if reason is null or length(btrim(reason)) < 10 then
    raise exception 'Say why you are rebuilding the index. A model change is exactly the kind of event this store exists to make traceable, and the sentence goes in the change log for whoever asks later why search went quiet for ten minutes.';
  end if;
  select count(*) into n from platform.embeddings;
  select e.model, e.dimension into old_model, old_dim from platform.embedder e where e.id = 1;
  if old_model is null and n > 0 then
    note := ' The store has no record of which model those vectors came from.';
  end if;

  truncate platform.embeddings;

  -- Into the change log, like any other write. The index is the caretaker's to rebuild,
  -- but not silently: skillhub_activity shows this to every agent.
  insert into platform.events (table_name, operation, row_id, agent, visibility, summary)
  values ('platform.embeddings', 'delete', null, by_agent, 'public',
          format('Index rebuilt from scratch: %s (%s vector(s) discarded, model %s at dimension %s)',
                 btrim(reason), n, coalesce(old_model, 'unknown'), coalesce(old_dim::text, '?')));

  -- Fire the indexer. It probes the endpoint again, sets the column to whatever dimension
  -- the model returns, and keeps taking batches until its budget is spent -- so a big
  -- store comes back in minutes rather than one batch per five-minute cron tick.
  begin
    perform net.http_post(url := indexer_url,
      headers := '{"Content-Type":"application/json"}'::jsonb, timeout_milliseconds := 180000);
  exception when others then
    note := note || format(' The indexer could not be called (%s); the five-minute cron will rebuild instead.', sqlerrm);
  end;

  return format('Index emptied: %s vector(s) gone, rebuilding now.%s Watch it with: select public.embedder_status();  -- meaning search is off until "waiting" reaches 0.', n, note);
end $$;
comment on function platform.reindex(text, text, text) is 'Empties platform.embeddings and rebuilds it. For a model whose dimension differs from the current one -- do this BEFORE pointing EMBEDDING_* at it. Requires a reason, which goes in the change log. The index is a cache: nothing is lost.';
revoke execute on function platform.reindex(text, text, text) from public, anon, authenticated;
grant execute on function platform.reindex(text, text, text) to service_role, postgres;

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
    url := 'http://functions:9000/embed?batch=100&budget=120',
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
  -- Eight per request, not twenty. text-embeddings-inference defaults --max-client-batch-size
  -- to 32 but a CPU deployment measured 2026-09-14 ran it at 8, and a request with more
  -- inputs than that is refused outright -- so nothing would have been embedded and the cron
  -- would have retried the same refusal every five minutes. Eight is under every provider's
  -- limit and costs nothing: the nudge and the cron loop until nothing is waiting.
  perform net.http_post(
    url := 'http://functions:9000/embed?batch=8',
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
