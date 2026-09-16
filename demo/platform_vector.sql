-- The vector dimension, as a function -- and the search function that has to match it.
--
-- pgvector carries the dimension in the column type, so it cannot change while rows exist.
-- Until 2026-09-16 this file hard-coded 1536 and a person had to edit it for any other
-- model. Now the indexer (volumes/functions/embed) probes the endpoint, reads the dimension
-- the model actually returns, and calls platform.set_vector_dim() itself while the table is
-- empty. Nothing to set. To switch models later: truncate platform.embeddings, and the next
-- run re-probes and rebuilds.
--
-- By hand, as a superuser:   select platform.set_vector_dim(1024);

create or replace function platform.set_vector_dim(wanted int) returns text
language plpgsql security definer set search_path = platform, public as $$
declare
  current_dim int;
  rows_present bigint;
  msg text;
begin
  select atttypmod into current_dim from pg_attribute
   where attrelid = 'platform.embeddings'::regclass and attname = 'vector';
  select count(*) into rows_present from platform.embeddings;

  if wanted is null or wanted < 1 then
    raise exception 'A dimension is a positive integer; got %.', wanted;
  end if;
  if current_dim = wanted then
    return format('The vector store is already vector(%s). Nothing to do.', wanted);
  end if;
  if rows_present > 0 then
    raise exception 'The table holds % vectors of dimension %. Vectors from different models are never mixed -- empty it deliberately first: truncate platform.embeddings; -- and the indexer rebuilds at %.', rows_present, current_dim, wanted;
  end if;

  execute 'drop index if exists platform.embeddings_vector_idx';
  execute format('alter table platform.embeddings alter column vector type vector(%s)', wanted);
  -- pgvector's HNSW index takes vector up to 2,000 dimensions and halfvec up to 4,000. Above
  -- that there is no index, and that is fine at this store's scale: an exact cosine scan over
  -- a few thousand rows is milliseconds. Qwen3-Embedding-8B, the first local model this ran
  -- against (2026-09-14), is 4,096 native -- so the third branch is not theoretical.
  if wanted <= 2000 then
    execute 'create index embeddings_vector_idx on platform.embeddings using hnsw (vector vector_cosine_ops)';
    msg := format('The vector store is now vector(%s) with an HNSW index.', wanted);
  elsif wanted <= 4000 then
    execute format('create index embeddings_vector_idx on platform.embeddings using hnsw ((vector::halfvec(%s)) halfvec_cosine_ops)', wanted);
    msg := format('The vector store is now vector(%s) with a half-precision HNSW index.', wanted);
  else
    msg := format('The vector store is now vector(%s) with NO index: HNSW stops at 4,000 dimensions. Searches are exact scans, fine below tens of thousands of rows.', wanted);
  end if;
  perform platform.rebuild_similar();
  return msg;
end $$;
comment on function platform.set_vector_dim(int) is 'Rebuilds platform.embeddings.vector at a new dimension. Refuses while rows exist. The indexer calls it after probing the model; by hand: select platform.set_vector_dim(1024);';

-- The search function takes a typed vector, so it is regenerated for the current dimension.
-- Objects are returned once, at their best chunk.
create or replace function platform.rebuild_similar() returns void
language plpgsql security definer set search_path = platform, public as $$
declare d int; r record;
begin
  select atttypmod into d from pg_attribute
   where attrelid = 'platform.embeddings'::regclass and attname = 'vector';
  -- The return type changed on 2026-09-16 (chunk and head), and CREATE OR REPLACE refuses a
  -- new return type -- so whatever similar() exists goes first, at any signature.
  for r in select p.oid::regprocedure as sig from pg_proc p
            where p.proname = 'similar' and p.pronamespace = 'platform'::regnamespace loop
    execute 'drop function ' || r.sig;
  end loop;
  execute format($f$
    create or replace function platform.similar(query_vector vector(%1$s), model_name text, max_hits int default 5)
    returns table (source text, id text, chunk int, head text, distance real)
    language sql stable as $inner$
      select source, id, chunk, head, distance from (
        select distinct on (e.source, e.id)
               e.source, e.id, e.chunk, e.head, (e.vector <=> query_vector)::real as distance
        from platform.embeddings e
        where e.model = model_name
        order by e.source, e.id, e.vector <=> query_vector) best
      order by distance
      limit max_hits;
    $inner$;$f$, d);
end $$;

-- Manual path kept: set platform.new_dim before running this file and it applies.
-- The seed runs this file on every boot with nothing set, which only refreshes similar().
do $$
declare wanted text := current_setting('platform.new_dim', true);
begin
  if wanted is not null and wanted <> '' then
    raise notice '%', platform.set_vector_dim(wanted::int);
  else
    perform platform.rebuild_similar();
  end if;
end $$;
