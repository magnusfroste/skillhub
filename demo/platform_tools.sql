-- The tool surface: SQL functions in public that the `skillhub` MCP server exposes as tools.
-- Run AFTER demo/platform_entry.sql.
--
-- Why wrappers in public: PostgREST only exposes the schemas in PGRST_DB_SCHEMAS (public,
-- storage, graphql_public). The edge function therefore calls RPC in public, which reads
-- from platform. One extra layer, but no compose changes and no external dependency in the
-- function.
--
-- The agent identity does NOT come from the call but from the gateway: key-auth sets
-- X-Consumer-Username on the way up, so agent_NN tied to the key. The edge function passes
-- it in as `agent`. That is the difference from execute_sql, where owner is whatever the
-- agent claims -- demonstrated 2026-09-11, when one agent wrote a row the change log
-- attributes to another.

-- ---------------------------------------------------------------------------
-- Reading tools
-- ---------------------------------------------------------------------------

-- The entrance board. Ran in every single session measured on 2026-09-11, on every agent,
-- without anyone naming it -- which makes its output the one instruction channel that
-- reaches every machine and can still be changed centrally afterwards. So it answers who
-- else is here before it answers anything about tables: an agent that does not know it
-- shares the store cannot reason about duplicating someone's work.
-- The caller is passed now (2026-09-16). Until then an agent could file a structure
-- request and never learn what became of it: on the demo, agent_04 saw its own request
-- still open, concluded the delivery was done and waiting, and stopped -- correctly, on
-- the only information it had. The caretaker's answer reaches the agent here.
drop function if exists public.skillhub_overview();
create or replace function public.skillhub_overview(agent text default null) returns jsonb
language sql stable security definer set search_path = public, platform as $$
  select jsonb_build_object(
    -- Two lines, not three, and one of them is a pointer rather than a restatement: the tour
    -- lives in start_here and is read with skillhub_help, the placement rule in
    -- skillhub_rules. Saying it all again here was a third copy to keep in step.
    -- Three lines, and they stay three: this is the store's only channel to an agent it did
    -- not install. The caretaker runs from a compose file that seeds these same rules into its
    -- SOUL.md, but the agents on people's own laptops are configured by hand -- they get a key,
    -- an address, and whatever this call tells them. So a rule that matters cannot live only in
    -- a deployment repository. It has to be here, and short enough to be read (2026-09-21).
    'read_this_first', jsonb_build_array(
      'New here, or unsure what this store holds? skillhub_help -- the tour in order, and the finished procedures.',
      -- The narrow version of this line cost five rounds of deliberation on a client install: an
      -- agent asked to research a subject could not tell whether "a question from this data"
      -- covered it, and the reason that did apply -- somebody may have done this already -- was
      -- written nowhere. So the line now names both.
      'Run skillhub_search before you ANSWER a question from this data, and before you RESEARCH anything from scratch. Someone may have written down how the data has to be read -- reading it wrong gives a confident wrong number rather than an error -- or may have done the same investigation last week.',
      -- Measured the same session: the agent planned to save its finished report to a file in its
      -- own workspace and treated writing it here as optional. Every other rule said which KIND
      -- of thing to write, none said that writing it here at all is the point.
      'What you find out belongs in here, not in a file on the machine you are running on -- that one is gone when your session ends, and nobody else can read it meanwhile. A note for what you learned, a skill for a procedure others should follow. Past a few thousand characters, hand it over as a file instead: skillhub_upload_url, the curl line it gives you, then skillhub_load_text.'),
    'numbers', (select jsonb_object_agg(label, value) from platform.overview()),
    'who_is_here', (select coalesce(jsonb_agg(jsonb_build_object('agent', id, 'name', name,
                      'role', role, 'team', team) order by id), '[]'::jsonb)
                    from public.agents where active),
    'tables', (select jsonb_agg(jsonb_build_object('table', table_name, 'rows', rows,
                 'comment', description, 'follows_convention', follows_convention))
               from platform.v_catalog),
    'sources', (select coalesce(jsonb_agg(jsonb_build_object('table', table_name,
                  'system', source_system, 'rows', row_count, 'loaded', last_loaded)), '[]'::jsonb)
                from platform.v_sources),
    'backlog', (select count(*) from platform.v_action_items),
    'stale', (select count(*) from platform.v_going_stale),
    -- What became of what you asked for. Open means the caretaker has not answered yet;
    -- done and declined both carry the answer, and declined usually means it already
    -- exists somewhere -- read the sentence before asking again.
    -- The noticeboard: what colleagues asked, and what came back on your own questions.
    -- Here rather than in a tool of its own, because this is the call an agent already makes
    -- first and nothing notifies anybody (DECISIONS 26).
    'questions', case when skillhub_overview.agent is not null then public.asks_for(skillhub_overview.agent) end,
    'your_requests', (select coalesce(jsonb_agg(jsonb_build_object(
                        'id', r.id, 'asked', r.at::timestamp(0), 'purpose', left(r.purpose, 120),
                        'status', r.status, 'table', r.table_name,
                        'answer', r.resolution, 'answered_by', r.resolved_by) order by r.at desc), '[]'::jsonb)
                      from platform.structure_requests r
                      where skillhub_overview.agent is not null
                        and r.requested_by = skillhub_overview.agent
                        and (r.status = 'open' or r.resolved_at > now() - interval '30 days')),
    -- Whether search by meaning is on, and how the last indexing run went. A silent cron
    -- was the alternative, and its failure mode is "my colleague cannot find what I wrote".
    'index', public.embedder_status(),
    -- The caretaker holds the service key and comes through the same door as everyone else.
    -- Rather than a second tool it has to know about, the operational view arrives inside
    -- the one call every agent makes first. Nobody else sees this key at all.
    'caretaker', case when skillhub_overview.agent = 'service_role'
                      then platform.health() end);
$$;

-- Passes the verified agent through to platform.search so private rows stay private, and
-- records that a search happened -- the gate on publishing needs to know. SECURITY DEFINER
-- because tool_log is not writable by the roles the gateway arrives as.
create or replace function public.skillhub_search(query text, max_hits int default 10, agent text default null)
returns jsonb language plpgsql security definer set search_path = public, platform as $$
declare j jsonb;
begin
  if agent is not null and agent <> '' then
    perform platform.note_search(agent, 'search', query);
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('kind', source, 'id', id, 'title', title,
           'excerpt', excerpt) order by rank desc), '[]'::jsonb) into j
  from platform.search(query, max_hits, agent);
  return j;
end $$;;

create or replace function public.skillhub_rules() returns jsonb
language sql stable security definer set search_path = public, platform as $$
  select jsonb_build_object(
    'placement_rule', platform.placement_rule(),
    'conventions_skill', 'store-conventions',
    'house_standards', (select coalesce(jsonb_agg(jsonb_build_object('slug', slug, 'name', name,
                          'description', description)), '[]'::jsonb)
                        from public.skill_library
                        where 'house-standard' = any(tags) and status = 'published'),
    'caveats', (select jsonb_agg(caveat) from platform.v_caveats));
$$;

-- One tool for fetching any object in full. Whole objects, never fragments: search tells
-- the agent WHICH object, this returns ALL of it, so nothing is answered from a chunk
-- without its context.
--
-- Filters on ownership. Before 2026-09-11 this returned `visibility` as a column and
-- filtered on nothing, so another agent's private note came back in clear text.
-- The version parameter (2026-09-17). Every version of a skill has been its own row since
-- the beginning -- publishing supersedes, it never overwrites -- but nothing could READ an
-- older one: this returned the newest and search shows one row per slug, so "what did the
-- rule say last week" was a question only the caretaker could answer, with SQL. In a
-- regulated shop that is the question an auditor asks first.
drop function if exists public.skillhub_read(text, text, text);
drop function if exists public.skillhub_read(text, text, text, text);
create or replace function public.skillhub_read(kind text, id text, agent text default null, version text default null, pages text default null)
returns jsonb language plpgsql stable security definer set search_path = public, platform as $$
declare j jsonb; pg_from int; pg_to int; pg_all text[]; body text; total_pages int;
begin
  if kind = 'skill' then
    select to_jsonb(x) into j from (
      select 'skill' as kind, s.slug as id, s.name, s.description, s.version, s.author_name as author,
             s.status, s.tags, s.skill_md as content, s.verified_at, s.superseded_by,
             s.updated_at::timestamp(0) as updated,
             -- Every version that exists, newest first, so a reader can ask for one by name
             -- rather than discover the history only when somebody mentions it.
             (select jsonb_agg(jsonb_build_object('version', v.version, 'status', v.status,
                        'published', v.created_at::timestamp(0), 'by', v.author_name,
                        'superseded_by', v.superseded_by)
                      order by string_to_array(v.version,'.')::int[] desc)
                from public.skill_library v
               where v.slug = skillhub_read.id
                 and platform.may_read(v.visibility, v.author_name, skillhub_read.agent)) as versions,
             case when skillhub_read.version is null then 'This is the current version. "versions" lists the others; read one with version=, and cite the version you actually read.'
                  else 'You asked for this version by name. The current one may say something else -- check "versions".' end as note
      from public.skill_library s
      where s.slug = skillhub_read.id
        and platform.may_read(s.visibility, s.author_name, skillhub_read.agent)
        and (skillhub_read.version is null or s.version = skillhub_read.version)
      -- Newest version, by number and not by luck. Measured 2026-09-12: with two versions
      -- present this returned whichever row came first physically, so publishing an
      -- improvement left every colleague reading the old text, silently. Sorting on the
      -- string would put 1.10.0 before 1.9.0, hence the array of integers.
      order by string_to_array(s.version,'.')::int[] desc
      limit 1) x;
    if j is null and skillhub_read.version is not null then
      raise exception 'No version % of "%". The versions that exist: %.', skillhub_read.version, skillhub_read.id,
        coalesce((select string_agg(v.version, ', ' order by string_to_array(v.version,'.')::int[])
                    from public.skill_library v where v.slug = skillhub_read.id), '(no skill with that slug)');
    end if;
  elsif kind = 'note' then
    select to_jsonb(x) into j from (
      select 'note' as kind, n.id::text, n.title, n.content, n.tags,
             n.owner, n.visibility, n.updated_at::timestamp(0) as updated
      from public.notes n
      where n.id::text = skillhub_read.id
        and platform.may_read(n.visibility, n.owner, skillhub_read.agent)) x;
  elsif kind = 'document' then
    select to_jsonb(x) into j from (
      select 'document' as kind, d.id::text, d.filename, d.description,
             d.mime_type, d.bytes, d.sha256, d.bucket, d.path,
             d.source, (d.path is null) as content_missing, d.owner,
             (d.content is null) as text_missing, d.pages, length(d.content) as chars,
             d.content_loaded_at::timestamp(0) as text_loaded
      from public.documents d
      where d.id::text = skillhub_read.id
        and platform.may_read(d.visibility, d.owner, skillhub_read.agent)) x;
    -- The text, when loaded: whole if it is short, otherwise by pages -- a 300-page manual
    -- is not something to hand a model in one piece, and a citation is a page anyway.
    if j is not null and (j->>'text_missing') = 'false' then
      select d.content into body from public.documents d where d.id::text = skillhub_read.id;
      pg_all := regexp_split_to_array(body, E'\n## Page \\d+\n');
      total_pages := coalesce(array_length(pg_all, 1), 1);
      if skillhub_read.pages is not null then
        pg_from := (regexp_match(skillhub_read.pages, '^\s*(\d+)'))[1]::int;
        pg_to := coalesce((regexp_match(skillhub_read.pages, '-\s*(\d+)\s*$'))[1]::int, pg_from);
        if pg_from is null or pg_from < 1 or pg_from > total_pages then
          raise exception 'Pages are 1 to % for this document; "%" is outside that.', total_pages, skillhub_read.pages;
        end if;
        pg_to := least(pg_to, total_pages);
        j := j || jsonb_build_object('pages_returned', format('%s-%s of %s', pg_from, pg_to, total_pages),
               'content', (select string_agg(format(E'## Page %s\n%s', n, pg_all[n]), E'\n')
                             from generate_series(pg_from, pg_to) n));
      elsif length(body) <= 60000 then
        j := j || jsonb_build_object('content', body);
      else
        j := j || jsonb_build_object('content', left(body, 60000),
               'note', format('The text is %s characters over %s pages; this is the first 60,000. Read the rest by page: pages="7-9". A hit from skillhub_similar names the page.', length(body), total_pages));
      end if;
    elsif j is not null and (j->>'text_missing') = 'true' then
      j := j || jsonb_build_object('note', case when (j->>'content_missing') = 'true'
        then 'Registered but never uploaded: a pointer to a file that lives somewhere else. Its text is not in the store and cannot be quoted from here.'
        else 'Uploaded, but its text has not been loaded. The owner can: pdftotext -layout on the file, upload that with the second curl line skillhub_upload_url gives, then skillhub_load_text.' end);
    end if;
  elsif kind = 'table' then
    select jsonb_build_object(
      'kind', 'table', 'id', skillhub_read.id,
      'comment', obj_description(('public.'||skillhub_read.id)::regclass),
      'rows', platform.row_estimate(skillhub_read.id),
      'columns', (select jsonb_agg(jsonb_build_object('name', a.attname,
                    'type', format_type(a.atttypid, a.atttypmod),
                    'comment', col_description(a.attrelid, a.attnum)) order by a.attnum)
                  from pg_attribute a
                  where a.attrelid = ('public.'||skillhub_read.id)::regclass
                    and a.attnum > 0 and not a.attisdropped))
      into j;
  else
    return jsonb_build_object('error', format('Unknown kind "%s". Use skill, note, document or table.', kind));
  end if;
  -- Someone else's private object answers exactly like a missing one. Saying "forbidden"
  -- would confirm that it exists, which is half of what was leaking.
  return coalesce(j, jsonb_build_object('error', format('No %s with id %s', kind, skillhub_read.id)));
exception when others then
  return jsonb_build_object('error', sqlerrm);
end $$;

-- Needs no ownership filter: nothing private is ever embedded, so the index holds only
-- public objects. See embed_candidates.
create or replace function public.skillhub_similar(query_vector jsonb, model text, max_hits int default 5)
returns jsonb language plpgsql stable security definer set search_path = public, platform as $$
declare
  v vector; j jsonb;
  -- How many nearest chunks to take before grouping them into objects. A long object is
  -- several chunks and a retired one is filtered out afterwards, so the candidate set is
  -- wider than the answer: twenty per hit wanted, never fewer than a hundred.
  k int := greatest(coalesce(max_hits, 5) * 20, 100);
begin
  v := (query_vector #>> '{}')::vector;
  -- Two stages, because one was measured at 28 seconds over 25,000 chunks (2026-09-16).
  -- Stage one, platform.similar: the k nearest chunks, in the shape an index can serve.
  -- Stage two, here: drop what may not be returned, keep each object once at its best
  -- chunk, look up titles -- on k rows, not on the table.
  select coalesce(jsonb_agg(x order by x.similarity desc), '[]'::jsonb) into j from (
    select b.source as kind, b.id, b.similarity,
           case b.source
             when 'skill' then (select s.name from platform.v_current_skills s where s.slug = b.id)
             when 'note' then (select n.title from public.notes n where n.id::text = b.id)
             when 'document' then (select d.filename from public.documents d where d.id::text = b.id)
             when 'schema' then b.id
           end as title,
           -- Which section matched, when the object has more than one chunk. That is where
           -- to start reading; skillhub_read still returns the whole object.
           case when b.chunks > 1 then jsonb_build_object('chunk', b.chunk + 1, 'of', b.chunks, 'section', b.head) end as matched,
           -- For a schema hit the comment IS the answer, so it travels with the result. A
           -- pointer would send the agent looking for a reader that does not exist:
           -- skillhub_read handles skill, note, document and table, not a single column.
           case when b.source = 'schema' then
             case when position('.' in b.id) > 0
                  then col_description(('public.'||split_part(b.id,'.',1))::regclass,
                         (select a.attnum from pg_attribute a
                           where a.attrelid = ('public.'||split_part(b.id,'.',1))::regclass
                             and a.attname = split_part(b.id,'.',2)))
                  else obj_description(('public.'||b.id)::regclass)
             end
           end as comment
    from (
      select best.*,
             -- total chunks of the object, not of the candidates: counted on the few rows
             -- that survive, through the primary key
             (select count(*) from platform.embeddings e
               where e.source = best.source and e.id = best.id and e.model = skillhub_similar.model) as chunks
      from (
        select distinct on (c.source, c.id)
               c.source, c.id, c.chunk, c.head, round((1 - c.distance)::numeric, 4) as similarity
        from platform.similar(v, skillhub_similar.model, k) c
        -- A vector outlives its object's visibility: retiring a skill or making a note
        -- private leaves the row behind. embed_prune clears them; this is the guarantee.
        where platform.embedding_visible(c.source, c.id)
        order by c.source, c.id, c.distance) best
      order by best.similarity desc
      limit max_hits) b
    order by b.similarity desc) x;
  return j;
end $$;

-- plpgsql, not sql: a SQL function does not allow a parameter in LIMIT.
-- The caller is passed (2026-09-18), because the change log records the TITLE of what was
-- written, and until now every agent read every title -- a private note's included, and a
-- team's from the day teams existed. The log still holds them; this is the door being told
-- who is asking. The caretaker sees all of it, as with everything else.
drop function if exists public.skillhub_activity(int);
create or replace function public.skillhub_activity(max_rows int default 20, agent text default null) returns jsonb
language plpgsql stable security definer set search_path = public, platform as $$
declare j jsonb;
begin
  select coalesce(jsonb_agg(jsonb_build_object('from', from_at, 'agent', who, 'operation', operation,
           'table', table_name, 'count', n, 'what', what)), '[]'::jsonb) into j
  from (
    select min(e.at)::timestamp(0) as from_at, coalesce(e.agent,'(unknown)') as who, e.operation, e.table_name,
           count(*) as n,
           case when count(*) = 1 then max(coalesce(e.summary,''))
                else left(string_agg(distinct coalesce(e.summary,''), ', '), 120) end as what
    from platform.events e
    where platform.may_read(e.visibility, e.agent, skillhub_activity.agent)
    group by date_trunc('minute', e.at), e.agent, e.operation, e.table_name
    order by 1 desc
    limit max_rows) x;
  return j;
end $$;

create or replace function public.skillhub_report(days int default 1) returns text
language sql stable security definer set search_path = public, platform as $$
  select platform.daily_report(days);
$$;

create or replace function public.skillhub_whoami(agent text) returns jsonb
language sql stable security definer set search_path = public, platform as $$
  select jsonb_build_object(
    'agent', agent,
    'source', 'Verified by the gateway from your API key, not from what you claimed.',
    'registered', coalesce((select jsonb_build_object('name', name, 'role', role, 'team', team)
                            from public.agents where id = agent), '{}'::jsonb),
    'team', platform.team_of(agent),
    'team_note', case when platform.team_of(agent) is null
      then 'No team: you read public rows and your own, and cannot write team rows. The caretaker sets teams in the agents table.'
      else format('Rows with visibility = team are shared with everyone whose team is %s.', platform.team_of(agent)) end,
    'your_writes', (select coalesce(jsonb_object_agg(table_name, n), '{}'::jsonb)
                    from (select table_name, count(*) n from platform.events
                          where platform.events.agent = skillhub_whoami.agent group by table_name) x));
$$;

-- ---------------------------------------------------------------------------
-- Writing tools. Identity is a parameter the edge function fills from the gateway's
-- verified header, never something the agent states -- these fail closed without it.
-- ---------------------------------------------------------------------------
drop function if exists public.skillhub_write_note(text, text, text, text[], boolean);
create or replace function public.skillhub_write_note(
  agent text, title text, content text,
  tags text[] default '{}', private boolean default false, visibility text default null) returns jsonb
language plpgsql security definer set search_path = public, platform as $$
declare new_id uuid; vis text;
begin
  if agent is null or agent = '' then raise exception 'No agent identity from the gateway.'; end if;
  if title is null or btrim(title) = '' then raise exception 'Title is required.'; end if;
  vis := platform.visibility_for(agent, visibility, private);
  insert into public.notes (owner, created_by, updated_by, title, content, tags, visibility)
  values (agent, agent, agent, btrim(title), coalesce(content,''), coalesce(tags,'{}'), vis)
  returning id into new_id;
  return jsonb_build_object('id', new_id, 'title', btrim(title), 'owner', agent, 'visibility', vis,
    'note', case
      when vis = 'private' then 'Private notes are never indexed, so nobody can find this by meaning -- including you.'
      when vis = 'team' then format('Shared with team %s. Team notes are found by their words, not by meaning.', platform.team_of(agent))
      -- Measured 2026-09-19: told "write a note for the team", an agent in team sales wrote
      -- it public. Nothing had said which it was in, or that the other value existed.
      when platform.team_of(agent) is not null then format('Public: every agent reads this. You are in team %s -- if the user meant it for the team, retire this and write it again with visibility = team.', platform.team_of(agent))
      else null end);
end $$;

drop function if exists public.skillhub_publish_skill(text, text, text, text, text, text[], text);
create or replace function public.skillhub_publish_skill(
  agent text, slug text, name text, content text,
  description text default '', tags text[] default '{}', version text default '1.0.0',
  visibility text default 'public') returns jsonb
language plpgsql security definer set search_path = public, platform as $$
declare
  existing_author text;
  newest text;
begin
  if agent is null or agent = '' then raise exception 'No agent identity from the gateway.'; end if;
  if slug !~ '^[a-z0-9][a-z0-9-]{2,}$' then
    raise exception 'Invalid slug "%". Lowercase letters, digits and hyphens, at least three characters.', slug;
  end if;
  if version !~ '^[0-9]+\.[0-9]+\.[0-9]+$' then
    raise exception 'Invalid version "%". Use three numbers, e.g. 1.0.0 or 2.1.0.', version;
  end if;
  if length(coalesce(content,'')) < 200 then
    raise exception 'The content is % characters. A skill under 200 characters helps nobody -- describe the procedure.', length(coalesce(content,''));
  end if;

  -- The gate's second half: you cannot add to the library without having looked at it. The
  -- whole reason the library exists is that the next person inherits what the last one
  -- learned, and on 2026-09-12 two agents produced the identical wrong number while the
  -- answer sat in the store, because nothing made either of them look. This is the one
  -- moment where looking can be required in code rather than requested in a prompt.
  if not platform.searched_recently(agent) then
    raise exception using
      errcode = 'insufficient_privilege',
      message = format(
        'Search the library before adding to it. Run skillhub_search for %L -- or for whatever this skill is about -- and read what comes back. '
        'If something covers it already, improve that instead of publishing a second version of the same thing; if nothing does, publish and this will let you through. '
        'A duplicate is what makes a shared library unusable, and the check looks back fifteen minutes.',
        slug);
  end if;

  -- The gate. A colleague's skill may be IMPROVED but never overwritten: publishing over
  -- someone else's slug at the same version is refused, and the refusal says what to do
  -- instead, because it is the only field that survives the MCP wrapper.
  --
  -- Measured 2026-09-12 before this existed: agent_03 published over another agent's slug,
  -- got back "updated", renamed the skill, and the byline still credited the original
  -- author. The colleague would have been blamed for text they never wrote.
  select s.author_name into existing_author
    from public.skill_library s
   where s.slug = skillhub_publish_skill.slug and s.version = skillhub_publish_skill.version;

  if existing_author is not null and existing_author <> agent then
    select max(s.version) into newest from public.skill_library s where s.slug = skillhub_publish_skill.slug;
    raise exception using
      errcode = 'insufficient_privilege',
      message = format(
        'Version %s of "%s" belongs to %s, and you are %s -- publishing over it would leave their name on your text. '
        'Publish an improvement as a NEW version instead: the highest version now is %s, so use the next one up. '
        'The old version is then marked as superseded by yours and readers get yours. '
        'Read what is there first with skillhub_read.',
        version, slug, existing_author, agent, newest);
  end if;

  insert into public.skill_library (slug, name, description, skill_md, version, author_name, tags, visibility, status)
  values (slug, name, coalesce(description,''), content, version, agent, coalesce(tags,'{}'),
          platform.visibility_for(agent, skillhub_publish_skill.visibility, false), 'published')
  -- ON CONSTRAINT, not (slug, version): the column list resolves against both the table and
  -- this function's parameters, which are called slug and version, and Postgres refuses with
  -- "column reference is ambiguous". This made the tool fail on every call it ever received,
  -- unnoticed, because agents published with raw SQL instead.
  on conflict on constraint skill_library_slug_version_key do update
    set name = excluded.name, description = excluded.description, skill_md = excluded.skill_md,
        tags = excluded.tags, updated_at = now();

  -- Every older version of the slug now points at this one, so a reader who follows a link
  -- from last month's note lands on the current text instead of a dead end.
  update public.skill_library s
     set superseded_by = skillhub_publish_skill.version, updated_at = now()
   where s.slug = skillhub_publish_skill.slug
     and string_to_array(s.version,'.')::int[] < string_to_array(skillhub_publish_skill.version,'.')::int[]
     and coalesce(s.superseded_by,'') <> skillhub_publish_skill.version;

  return jsonb_build_object('slug', slug, 'version', version, 'author', agent,
    'action', case when existing_author = agent then 'updated' else 'published' end,
    'superseded', (select count(*) from public.skill_library s
                    where s.slug = skillhub_publish_skill.slug
                      and s.superseded_by = skillhub_publish_skill.version),
    'hint', 'Confirm a skill you followed with public.confirm_skill, and retire instead of deleting.');
end $$;

-- The five-argument overload is dropped first: create or replace with a new defaulted
-- parameter would leave both, and the tool wrapper resolves by name.
drop function if exists public.skillhub_register_document(text,text,bigint,text,text,text,text);
drop function if exists public.skillhub_register_document(text, text, bigint, text, text, text, text, text);
create or replace function public.skillhub_register_document(
  agent text, filename text, bytes bigint default null, mime_type text default null,
  sha256 text default null, description text default null, source text default null,
  path text default null, visibility text default 'public') returns jsonb
language plpgsql security definer set search_path = public, platform as $$
declare existing_id uuid; new_id uuid; duplicate text; step text;
begin
  -- The same agent registering the same bytes under the same name again is a RETRY, not a
  -- second document (2026-09-22: three rows for one spreadsheet after three failed uploads,
  -- each upload_url call having minted a fresh row). A different agent, or a different name
  -- for the same bytes, is still a new row with duplicate_of set -- that is a real signal.
  if sha256 is not null then
    select d.id into existing_id from public.documents d
     where d.owner = agent and d.sha256 = skillhub_register_document.sha256
       and d.filename = skillhub_register_document.filename and d.retired_at is null
     order by d.created_at desc limit 1;
    if existing_id is not null then
      return jsonb_build_object('id', existing_id, 'filename', filename, 'owner', agent,
        'already_registered', true,
        'note', 'You registered this exact file before; this is that record, not a new one. Upload to it and load its text as usual.');
    end if;
  end if;

  if agent is null or agent = '' then raise exception 'No agent identity from the gateway.'; end if;
  -- Every reference to a parameter that shares a column name is qualified with the function
  -- name. This is the fourth place today where an unqualified one made a tool fail on every
  -- call it ever received -- publish_skill, retire, request_structure, and this. The smoke test
  -- in utils/smoke-test-tools.sh exists because integration is the only thing that finds them.
  select d.filename into duplicate from public.documents d
   where skillhub_register_document.sha256 is not null
     and d.sha256 = skillhub_register_document.sha256 limit 1;
  insert into public.documents (owner, created_by, updated_by, filename, bytes, mime_type, sha256, description, source, visibility, bucket, path)
  values (agent, agent, agent, filename, bytes, mime_type, sha256, description, source,
          platform.visibility_for(agent, skillhub_register_document.visibility, false),
          -- bucket is NOT NULL (default 'shared'); an explicit null is not the default.
          -- Found 2026-09-15 on the demo: every registration without a path failed.
          case when path is not null then 'deliveries' else 'shared' end, path)
  returning id into new_id;
  -- The next_step string is the whole of what the agent hears, so it decides what happens
  -- next. Measured 2026-09-13: the previous wording said the file "must be uploaded to
  -- Storage by a person", and agent_02 stopped there -- twice, including when the user said
  -- outright that they could not upload it and that the point was for colleagues to get
  -- answers from the manual. The second time it went further and claimed that uploading
  -- would make content_missing disappear and the document searchable. Nothing here does
  -- that; no step in this store reads inside a file. So the message was both a dead end and
  -- false, and the agent had write_note, publish_skill and request_structure the entire
  -- time. A success message that ends the work is as costly as a refusal that does not say
  -- what to do instead.
  step := 'The catalogue now holds the name, the size and the hash. It does not hold what the file '
       || 'says, and nothing in this store reads inside a file -- uploading the bytes would not change '
       || 'that. So if colleagues are to get answers FROM this document, put the content in yourself, '
       || 'with the tools you already have: publish each part that carries a rule, a procedure or a '
       || 'checklist as a skill, naming this document and its revision as the source; write shorter '
       || 'observations as public notes; and use skillhub_request_structure when the content is a long '
       || 'list of similar items, such as clauses or requirements, that people will want to filter. '
       || 'Until the content is in, do not answer questions about it from the filename.';
  if duplicate is not null then
    step := 'A file with the same sha256 is already registered as ' || duplicate
         || '. Check whether it is the same revision before putting the same content in twice. ' || step;
  end if;
  return jsonb_build_object('id', new_id, 'filename', filename, 'content_missing', true,
    'next_step', step, 'duplicate_of', duplicate);
end $$;

-- skillhub_query: aggregation through the door.
--
-- Why this takes no SQL text. Raw SQL inside a SECURITY DEFINER function is the same escape
-- hatch measured on 2026-09-12 for the scratch zone: EXECUTE accepts multiple statements, and
-- the function runs as its owner, so a caller who closes a parenthesis reaches a superuser.
-- Validating SQL text with pattern matching is a losing game -- CTEs, function side effects,
-- statement chaining. So the agent never sends SQL. It says what it wants, every identifier
-- is checked against the real catalogue, every value is quoted as a literal, and this function
-- writes the statement.
--
-- Three things it guarantees that raw SQL could not:
--   * the ownership filter is applied, not requested
--   * there is a row cap and a statement timeout
--   * the statement that ran is returned, so the agent and the log see the same thing
create or replace function public.skillhub_query(
  agent       text,
  table_name  text,
  columns     text[] default null,          -- 'status', 'count(*)', 'sum(defect_count)'
  filters     jsonb  default '[]'::jsonb,   -- [["status","=","Completed"],["defect_count","not in",[999999,333]]]
  group_by    text[] default null,
  order_by    text   default null,          -- 'count desc', 'status', 'period'
  row_limit   int    default 100,
  bucket      jsonb  default null           -- {"column":"reg_date","unit":"month"}
) returns jsonb
-- Volatile, not stable: `set local statement_timeout` is refused in a non-volatile
-- function, and a query tool that can hold a connection open is worse than one that
-- cannot be inlined.
language plpgsql security definer set search_path = public, platform as $$
declare
  rel        regclass;
  cols       text[] := '{}';
  wheres     text[] := '{}';
  groups     text[] := '{}';
  f          jsonb;
  col        text;
  op         text;
  val        jsonb;
  expr       text;
  agg        text;
  inner_col  text;
  cap        int := least(greatest(coalesce(row_limit, 100), 1), 1000);
  sql        text;
  result     jsonb;
  has_owner  boolean;
  ord        text := '';

  ok_ops       constant text[] := array['=','<>','!=','<','<=','>','>=','in','not in','like','ilike','is null','is not null'];
  ok_units     constant text[] := array['day','week','month','quarter','year'];
  b_col        text;
  b_unit       text;
  right_col    text;
begin
  if agent is null or agent = '' then
    raise exception 'No agent identity from the gateway.';
  end if;

  -- The table must exist in public and be a table or a view. Nothing reaches pg_catalog,
  -- platform, auth or storage through here.
  select c.oid into rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relname = table_name and c.relkind in ('r','v');
  if rel is null then
    raise exception using errcode = 'undefined_table',
      message = format('No table or view "%s" in public. Run skillhub_overview to see what exists, and skillhub_read with kind=table for its columns.', table_name);
  end if;

  select exists (select 1 from pg_attribute a
                  where a.attrelid = rel and a.attname = 'owner' and a.attnum > 0 and not a.attisdropped)
    into has_owner;

  -- Time buckets. "How has quality developed per month" is one of the two questions a
  -- quality register exists to answer, and it was unanswerable: date_trunc is an expression
  -- and this tool refuses expressions on purpose, because accepting them turns it into a SQL
  -- dialect with a boundary nobody can hold. A bucket is not an expression though -- it is a
  -- DIMENSION, like a column, with a unit from a closed list. That line is the one worth
  -- keeping: dimensions and comparisons yes, computations never.
  if bucket is not null and bucket <> 'null'::jsonb then
    b_col  := lower(btrim(coalesce(bucket->>'column','')));
    b_unit := lower(btrim(coalesce(bucket->>'unit','month')));
    if not (b_unit = any(ok_units)) then
      raise exception using errcode = 'syntax_error',
        message = format('Bucket unit "%s" is not allowed. Use one of: %s.', b_unit, array_to_string(ok_units, ', '));
    end if;
    if not exists (select 1 from pg_attribute a where a.attrelid = rel and a.attname = b_col
                     and a.attnum > 0 and not a.attisdropped) then
      raise exception using errcode = 'undefined_column',
        message = format('Cannot bucket by "%s": no such column in %s. It has to be a date or timestamp column.', coalesce(bucket->>'column','(none)'), table_name);
    end if;
    cols   := cols   || format('date_trunc(%L, %I)::date::text as period', b_unit, b_col)::text;
    groups := groups || format('date_trunc(%L, %I)', b_unit, b_col)::text;
    if order_by is null or btrim(order_by) = '' then order_by := 'period'; end if;
  end if;

  -- Columns. Either a bare column, or one whitelisted aggregate over a column, or count(*).
  if columns is null or cardinality(columns) = 0 then
    columns := array['count(*)'];
  end if;
  foreach expr in array columns loop
    expr := btrim(expr);
    if lower(expr) = 'count(*)' then
      cols := cols || 'count(*)::text as count'::text;
    elsif expr ~* '^(count|sum|avg|min|max)\s*\(\s*[a-z_][a-z0-9_]*\s*\)$' then
      agg := lower(regexp_replace(expr, '^\s*([a-z]+).*$', '\1', 'i'));
      inner_col := lower(regexp_replace(expr, '^[a-z]+\s*\(\s*([a-z_][a-z0-9_]*)\s*\)$', '\1', 'i'));
      if not exists (select 1 from pg_attribute a where a.attrelid = rel and a.attname = inner_col and a.attnum > 0 and not a.attisdropped) then
        raise exception using errcode = 'undefined_column',
          message = format('No column "%s" in %s. Run skillhub_read with kind=table and id=%s to see the columns and their comments -- the comments say how the data has to be read.', inner_col, table_name, table_name);
      end if;
      cols := cols || format('%s(%I)::text as %s', agg, inner_col, agg)::text;
    elsif expr ~* '^[a-z_][a-z0-9_]*$' then
      if not exists (select 1 from pg_attribute a where a.attrelid = rel and a.attname = lower(expr) and a.attnum > 0 and not a.attisdropped) then
        raise exception using errcode = 'undefined_column',
          message = format('No column "%s" in %s. Run skillhub_read with kind=table and id=%s for the column list.', expr, table_name, table_name);
      end if;
      cols := cols || format('%I::text', lower(expr))::text;
    else
      raise exception using errcode = 'syntax_error',
        message = format('Cannot use "%s". A column takes one of three shapes: a column name, count(*), or count/sum/avg/min/max of one column. This tool builds the SQL for you -- it does not accept SQL.', expr);
    end if;
  end loop;

  -- Filters. [column, operator, value]. Values are quoted as literals, never interpolated raw.
  for f in select * from jsonb_array_elements(coalesce(filters, '[]'::jsonb)) loop
    col := lower(btrim(f->>0));
    op  := lower(btrim(f->>1));
    val := f->2;
    if col !~ '^[a-z_][a-z0-9_]*$'
       or not exists (select 1 from pg_attribute a where a.attrelid = rel and a.attname = col and a.attnum > 0 and not a.attisdropped) then
      raise exception using errcode = 'undefined_column',
        message = format('No column "%s" in %s to filter on.', f->>0, table_name);
    end if;
    if not (op = any(ok_ops)) then
      raise exception using errcode = 'syntax_error',
        message = format('Operator "%s" is not allowed. Use one of: %s.', op, array_to_string(ok_ops, ', '));
    end if;
    if op in ('is null','is not null') then
      wheres := wheres || (format('%I %s', col, op))::text;
    elsif op in ('in','not in') then
      if val is null or jsonb_typeof(val) <> 'array' then
        raise exception 'The operator "%s" needs a list of values, e.g. [999999, 333].', op;
      end if;
      wheres := wheres || (format('%I %s (%s)', col, op,
        (select string_agg(quote_nullable(v #>> '{}'), ', ') from jsonb_array_elements(val) v)))::text;
    elsif jsonb_typeof(val) = 'object' and val ? 'column' then
      -- Comparing two columns. "How many are overdue" is the other question the register
      -- exists for, and it needs closed_date against planned_ready_date. An object rather
      -- than a bare string, so a value that happens to match a column name is still a value:
      -- {"column":"planned_ready_date"} says what it means and nothing else can be mistaken
      -- for it. Before this, passing the column name as a literal produced "invalid input
      -- syntax for type date" -- a message that leaked the implementation instead of teaching.
      right_col := lower(btrim(val->>'column'));
      if not exists (select 1 from pg_attribute a where a.attrelid = rel and a.attname = right_col
                       and a.attnum > 0 and not a.attisdropped) then
        raise exception using errcode = 'undefined_column',
          message = format('No column "%s" in %s to compare against.', val->>'column', table_name);
      end if;
      wheres := wheres || (format('%I %s %I', col, op, right_col))::text;
    else
      wheres := wheres || (format('%I %s %s', col, op, quote_nullable(val #>> '{}')))::text;
    end if;
  end loop;

  -- The ownership filter is applied, not requested. This is the difference from raw SQL:
  -- an agent cannot forget it, and cannot choose to leave it out.
  if has_owner then
    wheres := wheres || format('platform.may_read(visibility, owner, %L)', agent)::text;
  end if;

  foreach col in array coalesce(group_by, '{}') loop
    col := lower(btrim(col));
    if not exists (select 1 from pg_attribute a where a.attrelid = rel and a.attname = col and a.attnum > 0 and not a.attisdropped) then
      raise exception using errcode = 'undefined_column',
        message = format('Cannot group by "%s": no such column in %s.', col, table_name);
    end if;
    groups := groups || format('%I', col)::text;
  end loop;

  if order_by is not null and btrim(order_by) <> '' then
    -- 'period' is the alias the bucket produces; everything else must be a real name.
    if order_by !~* '^[a-z_][a-z0-9_]*(\s+(asc|desc))?$' then
      raise exception using errcode = 'syntax_error',
        message = 'order_by takes one column or aggregate name, optionally followed by asc or desc. Example: "count desc".';
    end if;
    ord := ' order by ' || lower(btrim(order_by));
  end if;

  sql := format('select %s from public.%I%s%s%s limit %s',
           array_to_string(cols, ', '),
           table_name,
           case when cardinality(wheres) > 0 then ' where ' || array_to_string(wheres, ' and ') else '' end,
           case when cardinality(groups) > 0 then ' group by ' || array_to_string(groups, ', ') else '' end,
           ord, cap);

  -- A runaway aggregate is a bug, not a reason to hold the connection.
  set local statement_timeout = '20s';
  execute format('select coalesce(jsonb_agg(t), %L::jsonb) from (%s) t', '[]', sql) into result;

  return jsonb_build_object(
    'rows', result,
    'row_count', jsonb_array_length(result),
    'capped_at', case when jsonb_array_length(result) >= cap then cap else null end,
    'sql', sql,
    'note', 'Read-only, row-capped, and the ownership filter is applied for you. Per period: pass bucket, e.g. {"column":"reg_date","unit":"month"}. To compare two columns, give the value as {"column":"other_column"}. If a column''s comment says values must be excluded, pass that as a filter -- skillhub_read with kind=table shows the comments.');
end $$;

comment on function public.skillhub_query(text,text,text[],jsonb,text[],text,int,jsonb) is
  'Aggregation over one table in public, built from validated parts rather than from SQL text. Read-only, capped, ownership filter applied.';

revoke all on function public.skillhub_query(text,text,text[],jsonb,text[],text,int,jsonb) from public;
grant execute on function public.skillhub_query(text,text,text[],jsonb,text[],text,int,jsonb) to service_role, postgres;

-- skillhub_add_rows: fill in a structure somebody else defined.
--
-- The gap this closes, in the words that found it: in SharePoint you do not create new file
-- TYPES, you create new files of existing types, and you fill in lists somebody else defined.
-- Agents could write notes, publish skills and register documents, but if the caretaker made
-- a `suppliers` table nobody could add a supplier. The structure existed and was unusable.
--
-- Built the same way as skillhub_query and for the same reason: the agent sends no SQL. It
-- names a table and gives rows as objects; every column name is checked against the real
-- catalogue and every value goes through quote_nullable.
--
-- What the agent cannot set, ever: owner, created_by and updated_by come from the gateway.
-- That is the whole difference from the raw SQL door that closed today -- there, an agent
-- named its own owner and the change log believed it.
create or replace function public.skillhub_add_rows(
  agent      text,
  table_name text,
  rows       jsonb,
  visibility text default 'public'
) returns jsonb
language plpgsql security definer set search_path = public, platform as $$
declare
  rel        regclass;
  managed    constant text[] := array['id','owner','visibility','created_by','updated_by',
                                      'created_at','updated_at','retired_at','retired_by','retired_reason'];
  cap        constant int := 500;
  n_rows     int;
  first_keys text[];
  keys       text[];
  col        text;
  r          jsonb;
  vals       text[];
  tuples     text[] := '{}';
  sql        text;
  inserted   int;
begin
  if agent is null or agent = '' then raise exception 'No agent identity from the gateway.'; end if;
  visibility := platform.visibility_for(agent, visibility, false);
  if rows is null or jsonb_typeof(rows) <> 'array' or jsonb_array_length(rows) = 0 then
    raise exception 'Give rows as a list of objects, e.g. [{"name":"ACME","city":"Malmo"}].';
  end if;
  n_rows := jsonb_array_length(rows);
  if n_rows > cap then
    raise exception using errcode = 'program_limit_exceeded',
      message = format('%s rows at once, and the limit is %s. Split it, or ask the caretaker -- a load of this size is what the admin key is for, and it registers a delivery so people can see where the data came from.', n_rows, cap);
  end if;

  -- The table has to exist, be a table, follow the convention and be logged. A table without
  -- the change log would make these rows untraceable, which is the thing that was closed today.
  select c.oid into rel
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relname = table_name and c.relkind = 'r';
  if rel is null then
    raise exception using errcode = 'undefined_table',
      message = format('No table "%s" in public. skillhub_overview lists what exists. Creating a new structure is the caretaker''s job -- describe what you need and ask for it.', table_name);
  end if;
  if (select count(*) from pg_attribute a
       where a.attrelid = rel and a.attnum > 0 and not a.attisdropped
         and a.attname in ('owner','visibility','created_by','updated_by')) <> 4 then
    raise exception using errcode = 'invalid_table_definition',
      message = format('%s does not carry the convention columns, so a row added here could not be attributed to you. Ask the caretaker whether this table is meant to take rows from agents at all -- some are deliberately not, and public.agents is one of them: the registry records who holds which key and is written where the key is handed over. Adding the convention columns to a table like that is how the check gets removed by someone trying to be helpful.', table_name);
  end if;
  if not exists (select 1 from pg_trigger t where t.tgrelid = rel and t.tgname = 'platform_log_change') then
    raise exception using errcode = 'invalid_table_definition',
      message = format('%s has no change log, so rows added here would be invisible in the flow view. Ask the caretaker to run platform.attach_change_log(''%s'').', table_name, table_name);
  end if;

  -- Every row has to describe the same columns. The forgiving alternative -- filling the gaps
  -- with null -- turns one mistyped key into a silently empty column, and a store that lies
  -- quietly is the failure mode this whole design is built against.
  select array_agg(k order by k) into first_keys from jsonb_object_keys(rows->0) k;
  if first_keys is null then raise exception 'The first row has no fields.'; end if;

  foreach col in array first_keys loop
    if col = any(managed) then
      raise exception using errcode = 'insufficient_privilege',
        message = format('You cannot set "%s" -- ownership and timestamps come from the gateway, not from you. Leave it out. Use the visibility argument if the rows should be private.', col);
    end if;
    if col !~ '^[a-z_][a-z0-9_]*$'
       or not exists (select 1 from pg_attribute a where a.attrelid = rel and a.attname = col
                        and a.attnum > 0 and not a.attisdropped) then
      raise exception using errcode = 'undefined_column',
        message = format('No column "%s" in %s. Run skillhub_read with kind=table and id=%s for the columns and their comments.', col, table_name, table_name);
    end if;
  end loop;

  for r in select * from jsonb_array_elements(rows) loop
    select array_agg(k order by k) into keys from jsonb_object_keys(r) k;
    if keys is distinct from first_keys then
      raise exception using errcode = 'invalid_parameter_value',
        message = format('Every row must describe the same columns. The first row has [%s] and another has [%s]. A missing key would become an empty column without anyone noticing.',
          array_to_string(first_keys, ', '), array_to_string(coalesce(keys,'{}'), ', '));
    end if;
    vals := '{}';
    foreach col in array first_keys loop
      vals := vals || quote_nullable(r ->> col)::text;
    end loop;
    tuples := tuples || format('(%s, %L, %L, %L, %L)',
      array_to_string(vals, ', '), agent, visibility, agent, agent)::text;
  end loop;

  sql := format('insert into public.%I (%s, owner, visibility, created_by, updated_by) values %s returning id',
           table_name,
           (select string_agg(quote_ident(k), ', ') from unnest(first_keys) k),
           array_to_string(tuples, ', '));

  execute format('with ins as (%s) select count(*) from ins', sql) into inserted;

  return jsonb_build_object(
    'table', table_name, 'inserted', inserted, 'owner', agent, 'visibility', visibility,
    'columns', first_keys,
    'note', 'Ownership and timestamps were set from your key, not from the rows. Every one of these appears in the flow view under your name.');
end $$;

comment on function public.skillhub_add_rows(text,text,jsonb,text) is
  'Add rows to an existing shared table. Columns validated against the catalogue, values quoted, ownership taken from the gateway. Creating a table is the caretaker''s job.';

revoke all on function public.skillhub_add_rows(text,text,jsonb,text) from public;
grant execute on function public.skillhub_add_rows(text,text,jsonb,text) to service_role, postgres;

drop function if exists public.skillhub_request_structure(text,text,jsonb,jsonb,text);
create or replace function public.skillhub_request_structure(
  agent          text,
  purpose        text,
  fields         jsonb,
  sample_rows    jsonb default null,
  suggested_name text default null,
  observations   text[] default null,   -- what you noticed: sentinels, spellings, units
  document_id    text default null,     -- the uploaded file the rows come from
  natural_key    text default null,     -- the column a re-delivery upserts on
  target_table   text default null      -- when you mean an existing table
) returns jsonb
language plpgsql security definer set search_path = public, platform as $$
declare
  near_tables jsonb;
  near_open   jsonb;
  new_id      bigint;
  n_samples   int := coalesce(jsonb_array_length(coalesce(sample_rows,'[]'::jsonb)), 0);
begin
  if agent is null or agent = '' then raise exception 'No agent identity from the gateway.'; end if;
  if skillhub_request_structure.purpose is null or length(btrim(skillhub_request_structure.purpose)) < 20 then
    raise exception 'Say what the data is for, in a sentence. The caretaker decides between a column and a new table on the purpose, not on the field names.';
  end if;
  if fields is null or jsonb_typeof(fields) <> 'array' or jsonb_array_length(fields) = 0 then
    raise exception 'Give the fields as a list, e.g. ["supplier","audit_date","score","deviations","status","auditor"].';
  end if;
  if n_samples > 200 then
    raise exception 'Attach at most 200 sample rows. More than that is a delivery: hand the file to the caretaker and follow the load-from-source-system skill.';
  end if;

  -- What already exists, and what somebody already asked for. Returned to the agent rather than
  -- used to refuse: the agent knows its own case better than a similarity score does.
  select coalesce(jsonb_agg(jsonb_build_object('table', c.table_name, 'rows', c.rows,
           'description', left(coalesce(c.description,''), 140))), '[]'::jsonb)
    into near_tables
  from platform.v_catalog c
  where c.follows_convention
    and (similarity(c.table_name, coalesce(suggested_name, '')) > 0.3
         or to_tsvector('swedish', coalesce(c.description,'')) @@ websearch_to_tsquery('swedish', replace(btrim(purpose), ' ', ' OR ')));

  select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'by', r.requested_by,
           'purpose', left(r.purpose, 140), 'at', r.at::timestamp(0))), '[]'::jsonb)
    into near_open
  from platform.structure_requests r
  where r.status = 'open'
    -- skillhub_request_structure.purpose, not purpose: this query names the table that has
    -- a purpose column too, and Postgres refuses an unqualified reference. The third time this
    -- class of bug appeared in one day, and the second time I wrote it after documenting it.
    and to_tsvector('swedish', r.purpose) @@ websearch_to_tsquery('swedish', replace(btrim(skillhub_request_structure.purpose), ' ', ' OR '));

  insert into platform.structure_requests (requested_by, purpose, suggested_name, fields, sample_rows,
                                           observations, document_id, natural_key, target_table)
  values (agent, btrim(skillhub_request_structure.purpose), suggested_name, fields, sample_rows,
          observations, nullif(document_id,'')::uuid, natural_key, target_table)
  returning id into new_id;

  return jsonb_build_object(
    'request_id', new_id,
    'requested_by', agent,
    'sample_rows_kept', n_samples,
    'existing_tables_worth_checking', near_tables,
    'other_open_requests_on_this', near_open,
    'note', case when near_tables = '[]'::jsonb and near_open = '[]'::jsonb
      then 'Recorded. The caretaker sees it in its daily report and decides whether this is a column on something that exists or a new table. Meanwhile write what you know as a note so the knowledge is not only in this conversation.'
      else 'Recorded -- but look at existing_tables_worth_checking and other_open_requests_on_this first. If one of them is the same kind of thing, say so to the user: a column on what exists beats a table beside it, and two people asking for the same structure should end up with one.'
    end);
end $$;

comment on function public.skillhub_request_structure(text,text,jsonb,jsonb,text,text[],text,text,text) is
  'Ask for somewhere to put structured data. Returns existing tables and other open requests that look related, so duplication is visible before it happens.';

revoke all on function public.skillhub_request_structure(text,text,jsonb,jsonb,text,text[],text,text,text) from public;
grant execute on function public.skillhub_request_structure(text,text,jsonb,jsonb,text,text[],text,text,text) to service_role, postgres;

-- Retire something of your own. The counterpart to publishing: an agent that can add but
-- never remove has to leave its own mistakes standing, and after raw SQL moves behind the
-- admin key that would be the only option left.
--
-- Soft by necessity, not by preference. The change log keeps a breadcrumb and not the row's
-- contents, so a hard delete here is unrecoverable by anyone -- see platform.v_caveats.
create or replace function public.skillhub_retire(
  agent text, kind text, id text, reason text default null, superseded_by text default null) returns jsonb
language plpgsql security definer set search_path = public, platform as $$
declare owner_now text; n int;
begin
  if agent is null or agent = '' then raise exception 'No agent identity from the gateway.'; end if;
  if reason is null or btrim(reason) = '' then
    raise exception 'A reason is required. Whoever finds this next needs to know why it stopped applying.';
  end if;

  if kind = 'skill' then
    -- Ownership is per VERSION, not per slug. Checking only the newest version's author was
    -- wrong in both directions: it let whoever published last retire a colleague's earlier
    -- row (measured 2026-09-14), and it blocked an author from retiring their own version
    -- once someone else had improved on it.
    select s.author_name into owner_now from public.skill_library s
     where s.slug = skillhub_retire.id
     order by string_to_array(s.version,'.')::int[] desc limit 1;
    if owner_now is null then raise exception 'No skill with slug %', id; end if;
    if not exists (select 1 from public.skill_library s
                    where s.slug = skillhub_retire.id and s.author_name = skillhub_retire.agent) then
      raise exception using errcode = 'insufficient_privilege',
        message = format('Every version of "%s" belongs to someone else -- the newest is %s and you are %s. You may publish a better version under your own name, which supersedes theirs; you may not retire their work. Ask an admin if it has to go.', id, owner_now, agent);
    end if;
    perform public.retire_skill(id, reason, superseded_by, agent);
    return jsonb_build_object('kind','skill','id',id,'retired_by',agent,'reason',reason,
      'note','Retired, not deleted: it leaves search but stays readable, so a colleague who cited it still gets an answer.');

  elsif kind = 'note' then
    select n2.owner into owner_now from public.notes n2 where n2.id::text = skillhub_retire.id;
    if owner_now is null then raise exception 'No note with id %', id; end if;
    if owner_now <> agent then
      raise exception using errcode = 'insufficient_privilege',
        message = format('That note belongs to %s and you are %s. Write your own instead.', owner_now, agent);
    end if;
    -- public.notes.id, not id: the column list resolves against both the table and this
    -- function's parameters, one of which is called id, and Postgres refuses with "column
    -- reference is ambiguous". The same mistake made skillhub_publish_skill fail on every call
    -- it ever received, unnoticed -- and it made retire fail here too, found in a simulation.
    update public.notes set retired_at = now(), retired_by = agent, retired_reason = reason,
           updated_by = agent, updated_at = now()
     where public.notes.id::text = skillhub_retire.id;
    get diagnostics n = row_count;
    return jsonb_build_object('kind','note','id',id,'retired_by',agent,'rows',n);

  elsif kind = 'document' then
    select d.owner into owner_now from public.documents d where d.id::text = skillhub_retire.id;
    if owner_now is null then raise exception 'No document with id %', id; end if;
    if owner_now <> agent then
      raise exception using errcode = 'insufficient_privilege',
        message = format('That document record belongs to %s and you are %s.', owner_now, agent);
    end if;
    -- public.documents.id, not id: the column list resolves against both the table and this
    -- function's parameters, one of which is called id, and Postgres refuses with "column
    -- reference is ambiguous". The same mistake made skillhub_publish_skill fail on every call
    -- it ever received, unnoticed -- and it made retire fail here too, found in a simulation.
    update public.documents set retired_at = now(), retired_by = agent, retired_reason = reason,
           updated_by = agent, updated_at = now()
     where public.documents.id::text = skillhub_retire.id;
    get diagnostics n = row_count;
    return jsonb_build_object('kind','document','id',id,'retired_by',agent,'rows',n);
  end if;

  return jsonb_build_object('error', format('Unknown kind "%s". Use skill, note or document. A TABLE is not retired by an agent -- ask an admin.', kind));
end $$;

revoke all on function public.skillhub_retire(text,text,text,text,text) from public;

-- The writing tools are not callable by anon or authenticated: they take an identity as a
-- parameter, and only the edge function knows the verified one.
revoke all on function public.skillhub_write_note(text,text,text,text[],boolean,text) from public;
revoke all on function public.skillhub_publish_skill(text,text,text,text,text,text[],text,text) from public;
revoke all on function public.skillhub_register_document(text,text,bigint,text,text,text,text,text,text) from public;
grant execute on all functions in schema public to service_role, postgres;


-- ---------------------------------------------------------------------------
-- Loading rows from a file, without a language model in the path.
--
-- skillhub_load_rows is what the edge function calls with the parsed rows of an uploaded
-- CSV, in slices. It upserts on the natural key into a table that already exists and follows
-- the convention -- an agent may re-deliver next month's export by itself -- and it never
-- creates a table. Creation is the caretaker's act: platform.load_registered_file builds the
-- table from a request (fields, natural key, the agent's observations as column comments),
-- resolves the request, and asks the edge function to load the file. See DECISIONS.md 20.
-- ---------------------------------------------------------------------------
-- The eight-argument version is dropped rather than replaced: CREATE OR REPLACE cannot
-- remove an old signature, and three overloads of load_registered_file once made the
-- caretaker's single call ambiguous on dev. One signature per function, always.
drop function if exists public.skillhub_load_rows(text,text,text,jsonb,text,text,text,boolean);
create or replace function public.skillhub_load_rows(
  agent text, target_table text, natural_key text, rows jsonb,
  file_sha256 text default null, filename text default null, source_system text default null,
  register boolean default true, visibility text default 'public') returns jsonb
language plpgsql security definer set search_path = public, platform as $$
declare
  rel        regclass;
  cols       text[];
  vis        text;
  have_raw   boolean; have_sha boolean; have_loaded boolean;
  keys       text[];
  r          jsonb;
  ins        bigint := 0; upd bigint := 0;
  existed    boolean;
  col_list   text; val_list text; set_list text;
begin
  if agent is null or agent = '' then raise exception 'No agent identity from the gateway.'; end if;
  -- Loaded rows were always public until 2026-09-19. A department's feed -- purchasing's
  -- order lines, support's tickets -- had nowhere to land but in front of everybody.
  vis := platform.visibility_for(agent, skillhub_load_rows.visibility, false);
  rel := to_regclass('public.' || quote_ident(target_table));
  if rel is null then
    raise exception 'No table "%" in public. Rows are loaded into a table that exists; ask for one with skillhub_request_structure (attach the uploaded file and what you noticed) and the caretaker loads the file when it resolves the request.', target_table;
  end if;
  if (select count(*) from pg_attribute a where a.attrelid = rel and a.attnum > 0 and not a.attisdropped
        and a.attname in ('owner','visibility','created_by','updated_by')) <> 4 then
    raise exception '% does not carry the convention columns, so rows loaded there could not be attributed. It is not a table agents load into.', target_table;
  end if;
  if natural_key is null or not exists (select 1 from pg_attribute a where a.attrelid = rel and a.attname = natural_key and a.attnum > 0) then
    raise exception 'natural_key "%" is not a column of %. Name the column a re-delivery should upsert on.', natural_key, target_table;
  end if;
  if not exists (select 1 from pg_index i join pg_attribute a on a.attrelid = i.indrelid and a.attnum = any(i.indkey)
                  where i.indrelid = rel and i.indisunique and a.attname = natural_key and array_length(i.indkey::int[],1) = 1) then
    execute format('create unique index if not exists %I on public.%I (%I)', target_table||'_'||natural_key||'_key', target_table, natural_key);
  end if;
  select array_agg(a.attname::text) into cols from pg_attribute a where a.attrelid = rel and a.attnum > 0 and not a.attisdropped;
  have_raw := 'raw' = any(cols); have_sha := 'source_sha256' = any(cols); have_loaded := 'loaded_at' = any(cols);

  for r in select * from jsonb_array_elements(rows) loop
    -- only keys that are real columns and not the house's own; everything else stays in raw
    select array_agg(k) into keys from jsonb_object_keys(r) k
     where k = any(cols) and k not in ('id','owner','visibility','created_by','updated_by','created_at','updated_at','raw','source_sha256','loaded_at');
    if keys is null or not (natural_key = any(keys)) then
      raise exception 'A row has no value for the natural key "%". Every row needs one.', natural_key;
    end if;
    col_list := (select string_agg(quote_ident(k), ', ') from unnest(keys) k);
    val_list := (select string_agg(format('nullif(%L, %L)', r->>k, ''), ', ') from unnest(keys) k);
    set_list := (select string_agg(format('%I = excluded.%I', k, k), ', ') from unnest(keys) k where k <> natural_key);
    execute format('select exists(select 1 from public.%I where %I = %L)', target_table, natural_key, r->>natural_key) into existed;
    execute format(
      'insert into public.%1$I (owner, created_by, updated_by, visibility, %2$s%3$s%4$s%5$s) values (%6$L, %6$L, %6$L, %16$L, %7$s%8$s%9$s%10$s) '
      'on conflict (%11$I) do update set updated_by = excluded.updated_by%12$s%13$s%14$s%15$s',
      target_table, col_list,
      case when have_raw then ', raw' else '' end,
      case when have_sha then ', source_sha256' else '' end,
      case when have_loaded then ', loaded_at' else '' end,
      agent, val_list,
      case when have_raw then format(', %L::jsonb', r::text) else '' end,
      case when have_sha then format(', %L', file_sha256) else '' end,
      case when have_loaded then ', now()' else '' end,
      natural_key,
      case when set_list is not null then ', ' || set_list else '' end,
      case when have_raw then ', raw = excluded.raw' else '' end,
      case when have_sha then ', source_sha256 = excluded.source_sha256' else '' end,
      case when have_loaded then ', loaded_at = now()' else '' end,
      vis);
    if existed then upd := upd + 1; else ins := ins + 1; end if;
  end loop;

  if register then
    perform platform.register_delivery(coalesce(source_system, 'file upload'), target_table, agent, filename, file_sha256, ins, upd,
      format('%s rows in the file: %s inserted, %s updated on %s', jsonb_array_length(rows), ins, upd, natural_key));
  end if;
  return jsonb_build_object('table', target_table, 'natural_key', natural_key,
    'rows_in_slice', jsonb_array_length(rows), 'inserted', ins, 'updated', upd,
    'visibility', vis, 'delivery_registered', register);
end $$;
revoke all on function public.skillhub_load_rows(text,text,text,jsonb,text,text,text,boolean,text) from public;
grant execute on function public.skillhub_load_rows(text,text,text,jsonb,text,text,text,boolean,text) to service_role, postgres;

-- The caretaker's act: build the table the request asks for, with the agent's observations
-- as column comments, resolve the request, and hand the file to the loader. Runs as the
-- caretaker (raw SQL door), never as an agent.
-- target_table is the caretaker's decision, and it overrides what the agent suggested: the
-- near-duplicate guard refused "support_tickets_v2" beside "support_tickets" on the first run
-- of this -- correctly -- and the right answer was to load into the one that exists.
-- Earlier iterations of this function took two and three arguments, and CREATE OR REPLACE
-- cannot remove a signature: an instance that lived through them ends up with all three, and
-- the caretaker's own call -- one integer, the rest defaulted -- becomes ambiguous. Found
-- 2026-09-17 on dev, where load_registered_file(13) answered "is not unique" instead of
-- building a table. The same drift the retire_skill and embed_save_chunks signatures had.
drop function if exists platform.load_registered_file(bigint, text);
drop function if exists platform.load_registered_file(bigint, text, text);
create or replace function platform.load_registered_file(request_id bigint, resolved_by text default 'service_role',
  loader_url text default 'http://functions:9000/skillhub', target_table text default null) returns text
language plpgsql security definer set search_path = public, platform as $$
declare
  rq   platform.structure_requests%rowtype;
  d    public.documents%rowtype;
  tname text; f text; ob text; colname text; k int;
begin
  select * into rq from platform.structure_requests where id = request_id;
  if rq.id is null then raise exception 'No request %', request_id; end if;
  if rq.document_id is null then raise exception 'Request % has no uploaded file to load (document_id is null). The agent registers the file with skillhub_upload_url and uploads it first.', request_id; end if;
  select * into d from public.documents where id = rq.document_id;
  if d.path is null then raise exception 'Document % has no Storage path: it was registered but never uploaded.', rq.document_id; end if;
  if rq.natural_key is null then raise exception 'Request % names no natural_key. The loader upserts on it; ask the agent which column identifies a row.', request_id; end if;

  tname := coalesce(load_registered_file.target_table, rq.target_table, rq.suggested_name);
  if tname is null or tname !~ '^[a-z][a-z0-9_]{2,}$' then raise exception 'Request % has no usable table name.', request_id; end if;

  if to_regclass('public.'||quote_ident(tname)) is null then
    perform public.create_shared_table(tname, left(rq.purpose, 500));
    for f in select value #>> '{}' from jsonb_array_elements(rq.fields) loop
      if f ~ '^[a-z][a-z0-9_]*$' and f not in ('id','owner','visibility','created_by','updated_by','created_at','updated_at') then
        execute format('alter table public.%I add column if not exists %I text', tname, f);
      end if;
    end loop;
    execute format('alter table public.%I add column if not exists raw jsonb, add column if not exists source_sha256 text, add column if not exists loaded_at timestamptz', tname);
    execute format('alter table public.%I alter column %I set not null', tname, rq.natural_key);
    execute format('create unique index if not exists %I on public.%I (%I)', tname||'_'||rq.natural_key||'_key', tname, rq.natural_key);
    execute format('comment on column public.%I.raw is %L', tname, 'The original row as delivered, untouched. The typed columns are a reading of it.');
    execute format('comment on column public.%I.source_sha256 is %L', tname, 'Which delivery this row came from: the sha256 of the file. platform.deliveries has the rest.');
  end if;

  -- The agent's observations become column comments where they name a column, and go on the
  -- table comment otherwise. This is the step that was missing when the request carried none.
  if rq.observations is not null then
    foreach ob in array rq.observations loop
      colname := null;
      for f in select value #>> '{}' from jsonb_array_elements(rq.fields) loop
        if position(f in ob) > 0 and f ~ '^[a-z][a-z0-9_]*$' then colname := f; exit; end if;
      end loop;
      if colname is not null then
        execute format('comment on column public.%I.%I is %L', tname, colname, ob);
      else
        execute format('comment on table public.%I is %L', tname, left(rq.purpose,500) || E'\n' || ob);
      end if;
    end loop;
  end if;

  perform platform.resolve_structure_request(request_id, resolved_by,
    format('Built %s from the request and loaded %s (%s). Observations written as column comments.', tname, d.filename, left(coalesce(d.sha256,''),12)), tname, false);

  -- Hand the file to the loader: the edge function reads it from Storage and calls
  -- skillhub_load_rows in slices. Internal call, so the identity is set here.
  perform net.http_post(
    url := loader_url,
    headers := jsonb_build_object('Content-Type','application/json','x-consumer-username', resolved_by),
    body := jsonb_build_object('jsonrpc','2.0','id',1,'method','tools/call','params',
              jsonb_build_object('name','skillhub_load_file','arguments',
                jsonb_build_object('document_id', rq.document_id::text, 'target_table', tname, 'natural_key', rq.natural_key))),
    timeout_milliseconds := 300000);
  return format('%s built and request %s resolved; the loader is reading %s. Check platform.deliveries in a moment.', tname, request_id, d.filename);
end $$;
comment on function platform.load_registered_file(bigint,text,text,text) is 'Caretaker only: build the table a request asks for (observations as column comments), resolve it, and have the loader read the uploaded file into it.';

-- ---------------------------------------------------------------------------
-- Upload tickets: the agent never holds a token (2026-09-22, DECISIONS 35).
--
-- A file goes from the agent's machine straight to Storage -- never through a tool argument,
-- which is a rule with a measurement behind it. Until today the way in was a signed URL, a
-- JWT of some 300 characters that IS the authorisation, and the tool handed it to the agent
-- as text. The only path from a tool result to the agent's shell runs through the model's
-- own output, and a model does not copy a string like that, it generates it again. Measured
-- over two runs on dev: five of twelve uploads failed with "InvalidJWT: signature verification
-- failed", and decoding the tokens the agent sent showed altered payloads -- upsert:'false' as
-- a string, an exp an hour in the past, one that was not base64 at all. The same model copied
-- 36-character document ids correctly every single time.
--
-- So the long string moves from the model's mouth to the store's table. The tool issues a
-- TICKET -- 32 hex characters, single-use, ten minutes, bound to one document and one target
-- -- and the agent PUTs the file to /deliver/<ticket>. The function looks the ticket up,
-- streams the body to the one path the ticket names, and marks it used. Same bearer
-- semantics as the signed URL, stricter in two ways (single-use; the path is never the
-- caller's to choose), and the agent's API key is not involved at any point: it proves
-- itself once, inside the tool call that issues the ticket, and never leaves its MCP config.
-- ---------------------------------------------------------------------------
create table if not exists platform.upload_tickets (
  nonce        text primary key,
  document_id  uuid not null references public.documents(id) on delete cascade,
  agent        text not null,
  target       text not null check (target in ('file','text')),
  path         text not null,             -- the storage object this ticket may write, and nothing else
  issued_at    timestamptz not null default now(),
  expires_at   timestamptz not null,
  redeemed_at  timestamptz,               -- set the moment a PUT claims it; cleared again if the write failed
  done_at      timestamptz,               -- set when the bytes are in Storage
  bytes        bigint,
  ip           text
);
create index if not exists upload_tickets_doc_idx on platform.upload_tickets (document_id, target);
comment on table platform.upload_tickets is 'One row per upload the store has agreed to receive: which document, which object, who asked, and whether the bytes ever arrived. A ticket the agent was given and never used is a document that was registered and never uploaded -- platform.health() names those.';

create or replace function public.upload_ticket_issue(p_document_id uuid, p_agent text, p_target text, p_path text)
returns text language plpgsql security definer set search_path = public, platform as $$
declare n text;
begin
  if p_target not in ('file','text') then raise exception 'target must be file or text'; end if;
  -- 128 bits from the kernel, as hex: 32 characters the model copies as reliably as a uuid.
  n := encode(extensions.gen_random_bytes(16), 'hex');
  insert into platform.upload_tickets (nonce, document_id, agent, target, path, expires_at)
  values (n, p_document_id, p_agent, p_target, p_path, now() + interval '10 minutes');
  return n;
end $$;
comment on function public.upload_ticket_issue is 'Issues a single-use, ten-minute ticket to write one object. Called by the skillhub function inside an authenticated tool call; the ticket is what the agent gets, never a signed URL.';

-- Claims the ticket atomically: two PUTs with the same nonce get exactly one success.
create or replace function public.upload_ticket_redeem(p_nonce text, p_ip text default null)
returns jsonb language plpgsql security definer set search_path = public, platform as $$
declare t platform.upload_tickets%rowtype;
begin
  if p_nonce !~ '^[0-9a-f]{32}$' then return jsonb_build_object('ok', false, 'reason', 'not a ticket'); end if;
  update platform.upload_tickets set redeemed_at = now(), ip = coalesce(p_ip, ip)
   where nonce = p_nonce and redeemed_at is null and expires_at > now()
  returning * into t;
  if t.nonce is null then
    select * into t from platform.upload_tickets where nonce = p_nonce;
    return jsonb_build_object('ok', false, 'reason',
      case when t.nonce is null then 'unknown ticket'
           when t.done_at is not null then 'ticket already used'
           when t.redeemed_at is not null then 'ticket is being used right now'
           else 'ticket expired' end);
  end if;
  return jsonb_build_object('ok', true, 'document_id', t.document_id, 'path', t.path, 'target', t.target, 'agent', t.agent);
end $$;

create or replace function public.upload_ticket_done(p_nonce text, p_bytes bigint)
returns void language sql security definer set search_path = public, platform as $$
  update platform.upload_tickets set done_at = now(), bytes = p_bytes where nonce = p_nonce;
$$;
-- The write to Storage failed after the claim: hand the ticket back so the same curl can be
-- retried, rather than sending the agent for a new one.
create or replace function public.upload_ticket_release(p_nonce text)
returns void language sql security definer set search_path = public, platform as $$
  update platform.upload_tickets set redeemed_at = null where nonce = p_nonce and done_at is null;
$$;
revoke all on function public.upload_ticket_issue(uuid,text,text,text) from public;
revoke all on function public.upload_ticket_redeem(text,text) from public;
revoke all on function public.upload_ticket_done(text,bigint) from public;
revoke all on function public.upload_ticket_release(text) from public;
grant execute on function public.upload_ticket_issue(uuid,text,text,text), public.upload_ticket_redeem(text,text),
  public.upload_ticket_done(text,bigint), public.upload_ticket_release(text) to service_role, postgres;

-- The register, for people: what was promised and what arrived.
create or replace view platform.v_uploads as
select t.issued_at::timestamp(0) as issued, t.agent, d.filename, t.target,
       case when t.done_at is not null then 'arrived' when t.expires_at > now() then 'open' else 'never came' end as state,
       t.bytes, t.done_at::timestamp(0) as arrived_at, t.ip
from platform.upload_tickets t join public.documents d on d.id = t.document_id
order by t.issued_at desc;
comment on view platform.v_uploads is 'Every upload the store agreed to receive, and whether the bytes came. "never came" for a file is a document that exists as a pointer only.';

-- ---------------------------------------------------------------------------
-- Last of all: publish the conventions skill from its sections, as a new version if the text
-- changed and not at all if it did not. Every file has declared its section by now.
-- ---------------------------------------------------------------------------
do $c$ begin raise notice '%', platform.assemble_conventions(); end $c$;

