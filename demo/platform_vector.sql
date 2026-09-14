-- Change the vector dimension. Run this ONLY if your embedding model does not give 1536.
--
-- pgvector carries the dimension in the type, so it cannot be changed afterwards without
-- rebuilding the column. The table is empty until something starts embedding, so it costs
-- nothing now and gets expensive later. Decide the dimension first.
--
-- Common values: text-embedding-3-small = 1536, text-embedding-3-large = 3072,
-- multilingual-e5-small = 384, e5-large / bge-m3 = 1024.
--
-- Run as a superuser:
--   psql -U supabase_admin -d postgres -f demo/platform_vector.sql
-- after setting the dimension on the line below.

-- Set the dimension here, one line:
select set_config('platform.new_dim', '1536', false);

do $$
declare
  wanted  int := current_setting('platform.new_dim', true)::int;
  current_dim int;
  rows_present bigint;
begin
  select atttypmod into current_dim from pg_attribute
   where attrelid = 'platform.embeddings'::regclass and attname = 'vector';
  select count(*) into rows_present from platform.embeddings;

  if wanted is null then
    raise notice 'No dimension given. Run: select set_config(''platform.new_dim'',''1024'',false); before this file.';
    return;
  end if;
  if current_dim = wanted then
    raise notice 'The dimension is already %. Nothing to do.', wanted;
    return;
  end if;
  if rows_present > 0 then
    raise exception 'The table holds % rows. Vectors from different models must never be mixed -- empty it deliberately first: truncate platform.embeddings;', rows_present;
  end if;

  execute 'drop index if exists platform.embeddings_vector_idx';
  execute format('alter table platform.embeddings alter column vector type vector(%s)', wanted);
  -- pgvector's HNSW index takes vector up to 2,000 dimensions and halfvec up to 4,000. Above
  -- that there is no index, and that is fine at this store's scale: an exact cosine scan over
  -- a few thousand rows is milliseconds. Qwen3-Embedding-8B, the first local model this ran
  -- against (2026-09-14), is 4,096 native -- so the third branch is not theoretical. A model
  -- trained with Matryoshka can be truncated to 1,024 in the edge function later if the
  -- table ever grows enough for the index to matter.
  if wanted <= 2000 then
    execute 'create index embeddings_vector_idx on platform.embeddings using hnsw (vector vector_cosine_ops)';
    raise notice 'The vector store is now vector(%) with an HNSW index. Set EMBEDDING_DIM to the same value.', wanted;
  elsif wanted <= 4000 then
    execute format('create index embeddings_vector_idx on platform.embeddings using hnsw ((vector::halfvec(%s)) halfvec_cosine_ops)', wanted);
    raise notice 'The vector store is now vector(%) with a half-precision HNSW index. Set EMBEDDING_DIM to the same value.', wanted;
  else
    raise notice 'The vector store is now vector(%) with NO index: HNSW stops at 4,000 dimensions. Searches are exact scans, which is fine below tens of thousands of rows. Set EMBEDDING_DIM to the same value.', wanted;
  end if;
end $$;

-- The search function has to take the same dimension.
do $$
declare d int;
begin
  select atttypmod into d from pg_attribute
   where attrelid = 'platform.embeddings'::regclass and attname = 'vector';
  execute format($f$
    create or replace function platform.similar(query_vector vector(%1$s), model_name text, max_hits int default 5)
    returns table (source text, id text, distance real)
    language sql stable as $inner$
      select e.source, e.id, (e.vector <=> query_vector)::real
      from platform.embeddings e
      where e.model = model_name
      order by e.vector <=> query_vector
      limit max_hits;
    $inner$;$f$, d);
end $$;
